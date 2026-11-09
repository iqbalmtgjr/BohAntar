import { useState, useEffect, useMemo } from "react";
import { Download, Share2, X, CheckCircle2, FileText } from "lucide-react";
import { toast, confirmDialog } from "../../components/Feedback";
import { BASE, authFetch } from "../../api";
import { invoiceBlob, invoicePdf } from "./invoiceImage";
import { invoiceCaption, openWhatsApp, rupiah, waktu, nomorDokumen, labelNomor } from "./invoice";

/*
 * Pratinjau invoice/kuitansi PNG dengan dua tombol: Unduh dan Bagikan.
 * Bagikan memakai Web Share API — satu ketukan, lalu penyewa memilih sendiri
 * WhatsApp, Telegram, Instagram, atau email dari lembar berbagi bawaan sistem.
 * Kalau perangkatnya tidak mendukung (umumnya browser desktop), gambarnya
 * diunduh dan chat WhatsApp dibuka supaya tinggal dilampirkan.
 *
 * "Tandai Lunas" sengaja ditaruh di sini, satu tempat untuk Kalender, Pesanan
 * Masuk, dan Laporan: begitu disimpan, pratinjau langsung berganti jadi kuitansi.
 */

const METODE = ["Tunai", "Transfer", "QRIS"];

// Nilai awal <input type="datetime-local">: jam lokal sekarang, "YYYY-MM-DDTHH:MM".
function sekarangLokal() {
  const t = new Date();
  t.setMinutes(t.getMinutes() - t.getTimezoneOffset());
  return t.toISOString().slice(0, 16);
}

// Tombol dokumen di halaman: Invoice dan Kuitansi selalu berdampingan. Modal
// terbuka langsung di dokumen yang diklik; Kuitansi untuk sewa yang belum lunas
// membuka form Tandai Lunas lebih dulu.
export function TombolDokumen({ doc, onBuka, className = "btn btn-ghost btn-sm", style, ikon = 15 }) {
  return (
    <>
      {[["Invoice", "invoice"], ["Kuitansi", "kuitansi"]].map(([nama, pilih]) => (
        <button
          key={pilih}
          type="button"
          className={className}
          style={style}
          title={pilih === "kuitansi" && !doc.lunas ? "Belum lunas — tandai lunas dulu untuk menerbitkan kuitansi" : undefined}
          onClick={() => onBuka({ ...doc, pilih })}
        >
          <FileText size={ikon} /> {nama}
        </button>
      ))}
    </>
  );
}

// Form Tandai Lunas terisi awal: sekarang, dan metode bayar booking bila dikenal.
const formLunasAwal = (d) => ({ waktu: sekarangLokal(), metode: METODE.includes(d?.paymentMethod) ? d.paymentMethod : "Tunai" });

export default function InvoiceModal({ data, onClose, onUbah }) {
  // Hasil "Tandai Lunas" di modal ini, supaya kuitansi tampil tanpa menunggu
  // halaman pemanggil memuat ulang datanya.
  const [lokal, setLokal] = useState(null);
  // Sewa yang sudah lunas tetap bisa dibuatkan invoice-nya (dokumen saat
  // booking). null = ikuti tombol yang diklik di halaman (data.pilih).
  const [pilihan, setPilihan] = useState(null);
  const [formLunas, setFormLunas] = useState(null); // { waktu, metode }
  // Data baru (modal dibuka lagi): buang sisa keadaan modal sebelumnya sebelum
  // menggambar, bukan sesudahnya lewat effect. Tombol Kuitansi pada sewa yang
  // belum lunas langsung membuka form Tandai Lunas.
  const minta = data?.pilih === "kuitansi" && !data?.lunas;
  const [dataLama, setDataLama] = useState(data);
  if (data !== dataLama) {
    setDataLama(data);
    setLokal(null);
    setPilihan(null);
    setFormLunas(minta ? formLunasAwal(data) : null);
  }
  const lihatInvoice = (pilihan ?? data?.pilih) === "invoice";
  const asli = lokal || data;
  const d = useMemo(() => (
    asli?.lunas && lihatInvoice ? { ...asli, jenis: "Invoice", lunas: false } : asli
  ), [asli, lihatInvoice]);
  const [url, setUrl] = useState("");
  const [blob, setBlob] = useState(null);
  const [sharing, setSharing] = useState(false);
  const [menyimpan, setMenyimpan] = useState(false);

  useEffect(() => {
    if (!d) return;
    let alive = true;
    let objectUrl = "";
    setUrl("");
    invoiceBlob(d)
      .then((b) => {
        if (!alive || !b) return;
        objectUrl = URL.createObjectURL(b);
        setBlob(b);
        setUrl(objectUrl);
      })
      .catch(() => alive && toast.error(`Gagal membuat gambar ${d.jenis.toLowerCase()}`));
    return () => {
      alive = false;
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [d]);

  if (!d) return null;

  const namaFile = `${d.jenis}-${nomorDokumen(d)}.png`;

  const simpanBerkas = (href, nama) => {
    const a = document.createElement("a");
    a.href = href;
    a.download = nama;
    a.click();
  };

  const unduh = () => {
    if (!url) return;
    simpanBerkas(url, namaFile);
    toast.success(`${d.jenis} tersimpan di folder unduhan`);
  };

  const unduhPdf = async () => {
    try {
      const pdfUrl = URL.createObjectURL(await invoicePdf(d));
      simpanBerkas(pdfUrl, namaFile.replace(/\.png$/, ".pdf"));
      setTimeout(() => URL.revokeObjectURL(pdfUrl), 10000);
      toast.success(`PDF ${d.jenis.toLowerCase()} tersimpan di folder unduhan`);
    } catch {
      toast.error("Gagal membuat PDF");
    }
  };

  const bagikan = async () => {
    if (!blob) return;
    const caption = invoiceCaption(d);
    const file = new File([blob], namaFile, { type: "image/png" });
    if (navigator.canShare?.({ files: [file] })) {
      setSharing(true);
      try {
        await navigator.share({ files: [file], text: caption });
        return;
      } catch (err) {
        // Pengguna menutup lembar berbagi — bukan kegagalan, jangan ganggu dia.
        if (err.name === "AbortError") return;
      } finally {
        setSharing(false);
      }
    }
    unduh();
    openWhatsApp(d.customerPhone, caption);
    toast.info(`Perangkat ini belum mendukung berbagi gambar langsung — ${d.jenis.toLowerCase()} sudah diunduh, tinggal lampirkan di chat WhatsApp yang terbuka`, 8000);
  };

  const kirimLunas = async (body) => {
    const res = await authFetch(`${BASE}/rental/lunas`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sumber: d.sumber, id: d.id, ...body }),
    });
    const j = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(j.error || "Gagal menyimpan pelunasan");
  };

  const simpanLunas = async (e) => {
    e.preventDefault();
    setMenyimpan(true);
    try {
      const lunasAt = `${formLunas.waktu.replace("T", " ")}:00`;
      await kirimLunas({ waktu: lunasAt, metode: formLunas.metode, nominal: d.total });
      setLokal({
        ...d, jenis: "Kuitansi", lunas: true, ditandaiLunas: true, lunasAt,
        dibayar: d.total, sisa: 0, paymentMethod: formLunas.metode,
      });
      setFormLunas(null);
      setPilihan("kuitansi");
      toast.success("Pelunasan tercatat — kuitansi siap dibagikan");
      onUbah?.();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setMenyimpan(false);
    }
  };

  const batalLunas = async () => {
    const ok = await confirmDialog({
      title: "Batalkan status lunas?",
      message: "Dokumen kembali menjadi invoice dengan sisa tagihan. Pakai ini kalau pelunasan salah dicatat.",
      confirmText: "Ya, batalkan",
    });
    if (!ok) return;
    try {
      await kirimLunas({ batal: true });
      toast.success("Status lunas dibatalkan");
      onUbah?.();
      onClose();
    } catch (err) {
      toast.error(err.message);
    }
  };

  return (
    <div className="invoice-overlay" onClick={onClose}>
      <div className="invoice-sheet" onClick={(e) => e.stopPropagation()}>
        <div className="invoice-sheet-head">
          <div>
            <strong>{d.jenis} Sewa</strong>
            <span>{labelNomor(d)} · {d.customerName || "Penyewa"}</span>
          </div>
          <button type="button" className="invoice-close" onClick={onClose} aria-label={`Tutup ${d.jenis.toLowerCase()}`}>
            <X size={18} />
          </button>
        </div>

        <div className="invoice-preview">
          {url
            ? <img src={url} alt={`${d.jenis} ${d.id}`} />
            : <div className="invoice-loading"><span className="spinner" /><p>Menyiapkan {d.jenis.toLowerCase()}…</p></div>}
        </div>

        {!(d.rentalLogo && d.rentalAddress) && (
          <p style={{ fontSize: 12, color: "var(--text-secondary)", margin: "0 16px 8px" }}>
            Logo dan alamat rental belum lengkap — isi di <a href="#/account" onClick={onClose}>Akun Saya</a> supaya tampil di kop.
          </p>
        )}

        {asli.lunas && (
          <div style={{ display: "flex", gap: 6, margin: "0 16px 8px" }}>
            {[["Invoice", "invoice"], ["Kuitansi", "kuitansi"]].map(([nama, kunci]) => (
              <button
                key={kunci}
                type="button"
                className={(lihatInvoice ? "invoice" : "kuitansi") === kunci ? "btn btn-primary btn-sm" : "btn btn-ghost btn-sm"}
                onClick={() => setPilihan(kunci)}
              >
                {nama}
              </button>
            ))}
          </div>
        )}

        {/* Status bayar: invoice selama belum lunas, kuitansi begitu lunas. */}
        <div style={{ margin: "0 16px 10px", padding: "10px 12px", borderRadius: 10, background: "var(--bg-input)", border: "1px solid var(--border)", fontSize: 13 }}>
          {asli.lunas ? (
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
              <span style={{ color: "#059669", fontWeight: 700, display: "flex", alignItems: "center", gap: 6 }}>
                <CheckCircle2 size={15} /> Lunas {waktu(d.lunasAt)}{d.paymentMethod ? ` · ${d.paymentMethod}` : ""}
              </span>
              {d.ditandaiLunas ? (
                <button type="button" className="btn btn-ghost btn-sm" onClick={batalLunas}>Batalkan lunas</button>
              ) : (
                <span style={{ fontSize: 12, color: "var(--text-muted)" }}>lunas dari pembayaran saat booking</span>
              )}
            </div>
          ) : formLunas ? (
            <form onSubmit={simpanLunas} style={{ display: "flex", gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
              {minta && (
                <div style={{ flexBasis: "100%", fontSize: 12, color: "#B45309", fontWeight: 600 }}>
                  Sewa ini belum lunas (sisa {rupiah(d.sisa)}). Tandai lunas dulu untuk menerbitkan kuitansi.
                </div>
              )}
              <label style={{ display: "flex", flexDirection: "column", gap: 4, fontSize: 12, flex: "1 1 180px" }}>
                Tanggal pelunasan
                <input className="input" type="datetime-local" required max={sekarangLokal()} value={formLunas.waktu}
                  onChange={(e) => setFormLunas({ ...formLunas, waktu: e.target.value })} />
              </label>
              <label style={{ display: "flex", flexDirection: "column", gap: 4, fontSize: 12, flex: "1 1 120px" }}>
                Metode
                <select className="input" value={formLunas.metode} onChange={(e) => setFormLunas({ ...formLunas, metode: e.target.value })}>
                  {METODE.map((m) => <option key={m} value={m}>{m}</option>)}
                </select>
              </label>
              <div style={{ display: "flex", gap: 6 }}>
                <button type="button" className="btn btn-ghost btn-sm" onClick={() => setFormLunas(null)}>Batal</button>
                <button type="submit" className="btn btn-success btn-sm" disabled={menyimpan}>
                  {menyimpan ? "Menyimpan…" : `Lunas ${rupiah(d.total)}`}
                </button>
              </div>
            </form>
          ) : (
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
              <span>
                <strong style={{ color: "#B45309" }}>Belum lunas</strong> · sisa {rupiah(d.sisa)}
                {d.dibayar > 0 ? ` (sudah masuk ${rupiah(d.dibayar)})` : ""}
              </span>
              <button
                type="button"
                className="btn btn-success btn-sm"
                onClick={() => setFormLunas(formLunasAwal(d))}
              >
                <CheckCircle2 size={14} /> Tandai Lunas
              </button>
            </div>
          )}
        </div>

        <div className="invoice-sheet-actions">
          <button type="button" className="btn btn-ghost" onClick={unduh} disabled={!url}>
            <Download size={16} /> Gambar
          </button>
          <button type="button" className="btn btn-ghost" onClick={unduhPdf} disabled={!url}>
            <FileText size={16} /> PDF
          </button>
          <button type="button" className="btn btn-primary" onClick={bagikan} disabled={!blob || sharing}>
            <Share2 size={16} /> {sharing ? "Membuka…" : "Bagikan"}
          </button>
        </div>
      </div>
    </div>
  );
}
