package main

import (
	"archive/zip"
	"bytes"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"path"
	"strconv"
	"strings"
)

// Baca/tulis .xlsx secukupnya untuk impor menu, dengan pustaka standar saja:
// .xlsx adalah zip berisi XML. Yang dibaca hanya nilai sel (teks, angka,
// boolean) per lembar; rumus terbaca sebagai hasil terakhirnya, gaya diabaikan.
// .xls lama (biner) tidak didukung — pemakai diminta menyimpan ulang sebagai .xlsx.
//
// ponytail: tanpa excelize. Ganti kalau suatu hari butuh rumus, gabung sel,
// atau tanggal (sel tanggal terbaca sebagai nomor seri Excel).

type barisXLSX struct {
	No  int      // nomor baris di Excel, untuk pesan galat
	Sel []string // A, B, C, ...
}

type lembarXLSX struct {
	Nama  string
	Baris []barisXLSX
}

const batasIsiXLSX = 20 << 20 // per berkas di dalam zip; menahan bom zip

func bacaBerkasZip(z *zip.Reader, nama string) ([]byte, error) {
	for _, f := range z.File {
		if f.Name == nama {
			rc, err := f.Open()
			if err != nil {
				return nil, err
			}
			defer rc.Close()
			isi, err := io.ReadAll(io.LimitReader(rc, batasIsiXLSX+1))
			if len(isi) > batasIsiXLSX {
				return nil, errors.New("isi berkas terlalu besar")
			}
			return isi, err
		}
	}
	return nil, nil
}

// teksKaya: <t> langsung atau gabungan <r><t> (teks berformat).
type teksKaya struct {
	T string `xml:"t"`
	R []struct {
		T string `xml:"t"`
	} `xml:"r"`
}

func (t teksKaya) String() string {
	s := t.T
	for _, r := range t.R {
		s += r.T
	}
	return s
}

// indeksKolom: "A" → 0, "AB" → 27, dari rujukan sel seperti "AB12".
func indeksKolom(ref string) int {
	n := 0
	for _, c := range ref {
		if c < 'A' || c > 'Z' {
			break
		}
		n = n*26 + int(c-'A') + 1
	}
	return n - 1
}

func bacaXLSX(data []byte) ([]lembarXLSX, error) {
	if !bytes.HasPrefix(data, []byte("PK")) {
		return nil, errors.New("bukan berkas .xlsx. Kalau berkasnya .xls atau .csv, buka di Excel lalu Simpan Sebagai \"Excel Workbook (.xlsx)\"")
	}
	z, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, errors.New("berkas .xlsx rusak atau tidak terbaca")
	}

	var shared []string
	if isi, err := bacaBerkasZip(z, "xl/sharedStrings.xml"); err != nil {
		return nil, err
	} else if isi != nil {
		var sst struct {
			SI []teksKaya `xml:"si"`
		}
		if err := xml.Unmarshal(isi, &sst); err != nil {
			return nil, errors.New("daftar teks di berkas .xlsx rusak")
		}
		for _, s := range sst.SI {
			shared = append(shared, s.String())
		}
	}

	isi, err := bacaBerkasZip(z, "xl/workbook.xml")
	if err != nil || isi == nil {
		return nil, errors.New("berkas .xlsx tidak punya lembar kerja")
	}
	var wb struct {
		Sheets []struct {
			Name string `xml:"name,attr"`
			RID  string `xml:"http://schemas.openxmlformats.org/officeDocument/2006/relationships id,attr"`
		} `xml:"sheets>sheet"`
	}
	if err := xml.Unmarshal(isi, &wb); err != nil {
		return nil, errors.New("daftar lembar di berkas .xlsx rusak")
	}
	target := map[string]string{}
	if isi, _ := bacaBerkasZip(z, "xl/_rels/workbook.xml.rels"); isi != nil {
		var rels struct {
			R []struct {
				ID     string `xml:"Id,attr"`
				Target string `xml:"Target,attr"`
			} `xml:"Relationship"`
		}
		xml.Unmarshal(isi, &rels)
		for _, r := range rels.R {
			if strings.HasPrefix(r.Target, "/") {
				target[r.ID] = strings.TrimPrefix(r.Target, "/")
			} else {
				target[r.ID] = path.Join("xl", r.Target)
			}
		}
	}

	var hasil []lembarXLSX
	for i, s := range wb.Sheets {
		nama := target[s.RID]
		if nama == "" {
			nama = fmt.Sprintf("xl/worksheets/sheet%d.xml", i+1)
		}
		isi, err := bacaBerkasZip(z, nama)
		if err != nil {
			return nil, err
		}
		if isi == nil {
			continue
		}
		var ws struct {
			Rows []struct {
				R int `xml:"r,attr"`
				C []struct {
					R  string   `xml:"r,attr"`
					T  string   `xml:"t,attr"`
					V  string   `xml:"v"`
					Is teksKaya `xml:"is"`
				} `xml:"c"`
			} `xml:"sheetData>row"`
		}
		if err := xml.Unmarshal(isi, &ws); err != nil {
			return nil, fmt.Errorf("lembar %s rusak", s.Name)
		}
		l := lembarXLSX{Nama: s.Name}
		for ri, row := range ws.Rows {
			b := barisXLSX{No: row.R}
			if b.No == 0 {
				b.No = ri + 1
			}
			for ci, c := range row.C {
				kol := ci
				if c.R != "" {
					kol = indeksKolom(c.R)
				}
				if kol < 0 || kol > 200 {
					continue
				}
				nilai := c.V
				switch c.T {
				case "s":
					if n, err := strconv.Atoi(c.V); err == nil && n >= 0 && n < len(shared) {
						nilai = shared[n]
					}
				case "inlineStr":
					nilai = c.Is.String()
				}
				for len(b.Sel) <= kol {
					b.Sel = append(b.Sel, "")
				}
				b.Sel[kol] = strings.TrimSpace(nilai)
			}
			l.Baris = append(l.Baris, b)
		}
		hasil = append(hasil, l)
	}
	return hasil, nil
}

// ==================== TULIS ====================

type lembarTulis struct {
	Nama    string
	Lebar   []float64  // lebar kolom A, B, ... dalam satuan karakter
	Baris   [][]string // baris 1 = judul (tebal, berlatar oranye)
	Pilihan []string   // validasi daftar pilihan, mis. `F2:F1000|Aktif,Nonaktif`
}

func namaKolom(i int) string {
	s := ""
	for i++; i > 0; i = (i - 1) / 26 {
		s = string(rune('A'+(i-1)%26)) + s
	}
	return s
}

func tulisXLSX(w io.Writer, lembar []lembarTulis) error {
	z := zip.NewWriter(w)
	tulis := func(nama, isi string) error {
		f, err := z.Create(nama)
		if err != nil {
			return err
		}
		_, err = io.WriteString(f, `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>`+"\n"+isi)
		return err
	}
	esc := func(s string) string {
		var b strings.Builder
		xml.EscapeText(&b, []byte(s))
		return b.String()
	}

	var tipe, sheets, rels strings.Builder
	for i, l := range lembar {
		n := i + 1
		fmt.Fprintf(&tipe, `<Override PartName="/xl/worksheets/sheet%d.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`, n)
		fmt.Fprintf(&sheets, `<sheet name="%s" sheetId="%d" r:id="rId%d"/>`, esc(l.Nama), n, n)
		fmt.Fprintf(&rels, `<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet%d.xml"/>`, n, n)
	}
	berkas := [][2]string{
		{"[Content_Types].xml", `<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">` +
			`<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>` +
			`<Default Extension="xml" ContentType="application/xml"/>` +
			`<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>` +
			`<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>` +
			tipe.String() + `</Types>`},
		{"_rels/.rels", `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
			`<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>`},
		{"xl/workbook.xml", `<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">` +
			`<sheets>` + sheets.String() + `</sheets></workbook>`},
		{"xl/_rels/workbook.xml.rels", `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` + rels.String() +
			`<Relationship Id="rIdGaya" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>`},
		// Gaya 0 = biasa, 1 = judul (tebal putih, latar oranye BohFood), 2 = teks membungkus.
		{"xl/styles.xml", `<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">` +
			`<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font></fonts>` +
			`<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>` +
			`<fill><patternFill patternType="solid"><fgColor rgb="FFD97706"/><bgColor indexed="64"/></patternFill></fill></fills>` +
			`<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>` +
			`<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>` +
			`<cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>` +
			`<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>` +
			`<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment wrapText="1" vertical="top"/></xf></cellXfs>` +
			`<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>`},
	}
	for i, l := range lembar {
		var b strings.Builder
		b.WriteString(`<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">`)
		b.WriteString(`<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>`)
		if len(l.Lebar) > 0 {
			b.WriteString("<cols>")
			for k, lebar := range l.Lebar {
				fmt.Fprintf(&b, `<col min="%d" max="%d" width="%g" customWidth="1"/>`, k+1, k+1, lebar)
			}
			b.WriteString("</cols>")
		}
		b.WriteString("<sheetData>")
		for r, baris := range l.Baris {
			fmt.Fprintf(&b, `<row r="%d">`, r+1)
			for k, sel := range baris {
				if sel == "" {
					continue
				}
				ref := fmt.Sprintf("%s%d", namaKolom(k), r+1)
				gaya := ""
				if r == 0 {
					gaya = ` s="1"`
				} else if len(sel) > 60 {
					gaya = ` s="2"`
				}
				if _, err := strconv.ParseFloat(sel, 64); err == nil && r > 0 {
					fmt.Fprintf(&b, `<c r="%s"%s><v>%s</v></c>`, ref, gaya, sel)
				} else {
					fmt.Fprintf(&b, `<c r="%s"%s t="inlineStr"><is><t xml:space="preserve">%s</t></is></c>`, ref, gaya, esc(sel))
				}
			}
			b.WriteString("</row>")
		}
		b.WriteString("</sheetData>")
		if len(l.Pilihan) > 0 {
			fmt.Fprintf(&b, `<dataValidations count="%d">`, len(l.Pilihan))
			for _, p := range l.Pilihan {
				rentang, daftar, _ := strings.Cut(p, "|")
				fmt.Fprintf(&b, `<dataValidation type="list" allowBlank="1" showErrorMessage="1" sqref="%s"><formula1>"%s"</formula1></dataValidation>`, rentang, esc(daftar))
			}
			b.WriteString("</dataValidations>")
		}
		b.WriteString("</worksheet>")
		berkas = append(berkas, [2]string{fmt.Sprintf("xl/worksheets/sheet%d.xml", i+1), b.String()})
	}
	for _, f := range berkas {
		if err := tulis(f[0], f[1]); err != nil {
			return err
		}
	}
	return z.Close()
}
