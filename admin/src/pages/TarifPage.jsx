import { useEffect, useState } from "react";
import { Percent, Save } from "lucide-react";
import { api } from "../api";
import Topbar from "../components/Topbar";

/* Ongkos dan bagi hasil per layanan. Angkanya dulu konstanta di dalam binary Go,
   jadi menaikkan tarif karena BBM naik menuntut build ulang dan deploy. Sekarang
   tersimpan di tabel `tarif` dan berlaku untuk pesanan berikutnya.

   Pesanan yang sudah dibuat tidak ikut berubah: komisinya dikunci di baris
   pesanan masing-masing, supaya laporan pendapatan bulan lalu tetap utuh. */

// Jarak contoh untuk pratinjau. Tanpa ini super admin tidak punya cara melihat
// akibat dari mengubah per_km selain menunggu pesanan sungguhan masuk.
const CONTOH_KM = 5;

const rupiah = (n) => "Rp " + Math.round(n || 0).toLocaleString("id-ID");

// Baris tarif yang bukan layanan antar: cuma menyimpan persen potongan
// pembayaran QR di tempat (warung dan rental). Ditampilkan terpisah karena
// kolom ongkos dan jarak tidak berarti apa-apa untuknya.
const TAGIHAN_QR = "TagihanQR";

// Angka yang dikirim ke server, baik untuk disimpan maupun untuk dihitung
// contohnya. Input HTML selalu menyerahkan string, dan backend menolak JSON yang
// tipenya tidak cocok.
const bentukTarif = (r) => ({
  layanan: r.layanan,
  base: Number(r.base) || 0,
  per_km: Number(r.per_km) || 0,
  jarak_dasar_km: Number(r.jarak_dasar_km) || 0,
  pembulatan: Number(r.pembulatan) || 0,
  pembulatan_ke_atas: !!r.pembulatan_ke_atas,
  komisi_persen: Number(r.komisi_persen) || 0,
  biaya_jasa: Number(r.biaya_jasa) || 0,
});

// Penjelasan rumus untuk satu layanan, mengikuti pengaturannya sendiri —
// bukan kalimat tetap "dibulatkan ke ratusan terdekat" yang dulu ada di bawah
// tabel dan jadi salah begitu bohRide memakai kelipatan seribu ke atas.
const kalimatRumus = (r) => {
  const dasar = Number(r.jarak_dasar_km) || 0;
  const arah = r.pembulatan_ke_atas ? "ke atas" : "terdekat";
  const awal = dasar > 0
    ? `${rupiah(r.base)} sampai ${dasar} km, lalu ${rupiah(r.per_km)}/km`
    : `${rupiah(r.base)} + ${rupiah(r.per_km)}/km`;
  return `${awal}, dibulatkan ${arah} ke kelipatan ${rupiah(r.pembulatan)}`;
};

/* Kolom contoh. Angkanya dihitung backend dengan fungsi yang sama dengan yang
   dipakai saat pesanan sungguhan dibuat — halaman ini sengaja tidak punya
   rumusnya sendiri lagi, karena salinan yang ketiga itulah yang dulu diam-diam
   melenceng dari server.

   Yang dikirim adalah angka di layar, termasuk yang belum disimpan, supaya
   mencari harga yang pas tidak menuntut menerbitkan tarif percobaan dulu. */
function ContohTarif({ row }) {
  const [hasil, setHasil] = useState(null);
  const [galat, setGalat] = useState("");
  const kirim = JSON.stringify(bentukTarif(row));

  useEffect(() => {
    let batal = false;
    const tunda = setTimeout(async () => {
      const res = await api.contohTarif({ ...JSON.parse(kirim), km: CONTOH_KM });
      if (batal) return;
      setHasil(res.status === "success" ? res.rincian : null);
      setGalat(res.status === "success" ? "" : res.error || "Angka ini belum bisa dihitung");
    }, 300);
    return () => { batal = true; clearTimeout(tunda); };
  }, [kirim]);

  if (galat) return <div style={{ fontSize: 12, color: "var(--danger, #EF4444)" }}>{galat}</div>;
  if (!hasil) return <div style={{ fontSize: 12, color: "var(--text-muted)" }}>Menghitung...</div>;
  return (
    <>
      <div style={{ fontWeight: 700 }}>{rupiah(hasil.total)}</div>
      <div style={{ fontSize: 12, color: "var(--text-muted)" }}>
        ongkos {rupiah(hasil.ongkos)} + jasa {rupiah(hasil.biaya_jasa)}
      </div>
      <div style={{ fontSize: 12, color: "var(--text-muted)" }}>
        driver {rupiah(hasil.driver)} &middot; bohAntar {rupiah(hasil.platform)}
      </div>
    </>
  );
}

export default function TarifPage() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState("");
  const [pesan, setPesan] = useState(null);

  useEffect(() => {
    api.getTarif().then(d => {
      if (d.status === "success") setRows(d.tarif || []);
      setLoading(false);
    });
  }, []);

  const ubah = (layanan, field, nilai) =>
    setRows(rows.map(r => r.layanan === layanan ? { ...r, [field]: nilai, dirty: true } : r));

  const simpan = async (row) => {
    const isi = bentukTarif(row);
    if (isi.jarak_dasar_km < 0) {
      setPesan({ tipe: "error", teks: "Jarak dasar tidak boleh negatif" });
      return;
    }
    if (isi.pembulatan < 1) {
      setPesan({ tipe: "error", teks: "Pembulatan minimal 1 rupiah" });
      return;
    }
    setSaving(row.layanan);
    setPesan(null);
    const res = await api.saveTarif(isi);
    setSaving("");
    if (res.status === "success") {
      setRows(rows.map(r => r.layanan === row.layanan ? { ...res.tarif, dirty: false } : r));
      setPesan({ tipe: "ok", teks: `Tarif ${row.layanan} tersimpan. Berlaku untuk pesanan berikutnya.` });
    } else {
      setPesan({ tipe: "error", teks: res.error || "Gagal menyimpan tarif" });
    }
  };

  if (loading) return (<><Topbar title="Tarif & Bagi Hasil" /><div className="loading-overlay"><div className="spinner" /><p>Memuat tarif...</p></div></>);

  const layanan = rows.filter(r => r.layanan !== TAGIHAN_QR);
  const qr = rows.find(r => r.layanan === TAGIHAN_QR);

  return (
    <>
      <Topbar title="Tarif & Bagi Hasil" />
      <div className="page">
        <div className="page-header">
          <h1>Tarif &amp; Bagi Hasil</h1>
          <p>Ongkos per layanan dan pembagian antara driver dan bohAntar</p>
        </div>

        {pesan && (
          <div className="card" style={{ marginBottom: 16, borderLeft: `4px solid ${pesan.tipe === "ok" ? "var(--success)" : "var(--danger, #EF4444)"}` }}>
            {pesan.teks}
          </div>
        )}

        <div className="card">
          <div className="card-title" style={{ marginBottom: 16 }}>Daftar Layanan</div>
          <table style={{ width: "100%" }}>
            <thead>
              <tr>
                <th>Layanan</th>
                <th>Buka Pintu</th>
                <th>Jarak Dasar</th>
                <th>Per Km</th>
                <th>Pembulatan</th>
                <th>Komisi bohAntar</th>
                <th>Biaya Jasa</th>
                <th>Contoh {CONTOH_KM} km</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {layanan.length === 0 ? (
                <tr>
                  <td colSpan={9}>
                    <div className="empty-state">
                      <div className="icon" style={{ display: "flex", justifyContent: "center", marginBottom: 12 }}>
                        <Percent size={40} style={{ color: "var(--text-muted)", opacity: 0.5 }} />
                      </div>
                      <h3>Belum ada tarif</h3>
                      <p>Tabel tarif diisi otomatis saat backend dijalankan</p>
                    </div>
                  </td>
                </tr>
              ) : layanan.map(r => (
                <tr key={r.layanan}>
                  <td data-label="Layanan">
                    <div style={{ fontWeight: 700 }}>{r.layanan}</div>
                    <div style={{ fontSize: 12, color: "var(--text-muted)", maxWidth: 230 }}>{kalimatRumus(r)}</div>
                  </td>
                  <td data-label="Buka Pintu">
                    <input
                      type="number" min="0" step="500" value={r.base}
                      onChange={e => ubah(r.layanan, "base", e.target.value)}
                      style={{ width: 110 }}
                    />
                  </td>
                  <td data-label="Jarak Dasar">
                    <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                      <input
                        type="number" min="0" step="1" value={r.jarak_dasar_km ?? 0}
                        onChange={e => ubah(r.layanan, "jarak_dasar_km", e.target.value)}
                        style={{ width: 70 }}
                      />
                      <span style={{ color: "var(--text-muted)" }}>km</span>
                    </div>
                  </td>
                  <td data-label="Per Km">
                    <input
                      type="number" min="0" step="100" value={r.per_km}
                      onChange={e => ubah(r.layanan, "per_km", e.target.value)}
                      style={{ width: 110 }}
                    />
                  </td>
                  <td data-label="Pembulatan">
                    <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                      <input
                        type="number" min="1" step="100" value={r.pembulatan ?? 100}
                        onChange={e => ubah(r.layanan, "pembulatan", e.target.value)}
                        style={{ width: 90 }}
                      />
                      <select
                        value={r.pembulatan_ke_atas ? "atas" : "terdekat"}
                        onChange={e => ubah(r.layanan, "pembulatan_ke_atas", e.target.value === "atas")}
                      >
                        <option value="terdekat">terdekat</option>
                        <option value="atas">ke atas</option>
                      </select>
                    </div>
                  </td>
                  <td data-label="Komisi">
                    <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                      <input
                        type="number" min="0" max="100" step="1" value={r.komisi_persen}
                        onChange={e => ubah(r.layanan, "komisi_persen", e.target.value)}
                        style={{ width: 80 }}
                      />
                      <span style={{ color: "var(--text-muted)" }}>%</span>
                    </div>
                  </td>
                  <td data-label="Biaya Jasa">
                    <input
                      type="number" min="0" step="500" value={r.biaya_jasa ?? 0}
                      onChange={e => ubah(r.layanan, "biaya_jasa", e.target.value)}
                      style={{ width: 110 }}
                    />
                  </td>
                  <td data-label={`Contoh ${CONTOH_KM} km`}>
                    <ContohTarif row={r} />
                  </td>
                  <td data-label="">
                    <button
                      className="btn btn-primary"
                      disabled={!r.dirty || saving === r.layanan}
                      onClick={() => simpan(r)}
                      style={{ display: "flex", alignItems: "center", gap: 6 }}
                    >
                      <Save size={15} />
                      {saving === r.layanan ? "Menyimpan..." : "Simpan"}
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {qr && (
          <div className="card" style={{ marginTop: 16, display: "flex", justifyContent: "space-between", alignItems: "center", gap: 16, flexWrap: "wrap" }}>
            <div style={{ maxWidth: 520 }}>
              <div className="card-title">Potongan pembayaran QR di tempat</div>
              <div style={{ fontSize: 13, color: "var(--text-secondary)", marginTop: 4, lineHeight: 1.6 }}>
                Dipotong dari tagihan QR yang dibuat warung dan mitra rental. Pelanggan membayar penuh; mitra menerima
                sisanya, dan angkanya sudah ditampilkan ke mitra sebelum QR disodorkan. Tagihan yang sudah dibuat tidak
                ikut berubah.
              </div>
            </div>
            <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
              <input
                type="number" min="0" max="100" step="0.5" value={qr.komisi_persen}
                onChange={e => ubah(qr.layanan, "komisi_persen", e.target.value)}
                style={{ width: 80 }}
              />
              <span style={{ color: "var(--text-muted)" }}>%</span>
              <button
                className="btn btn-primary"
                disabled={!qr.dirty || saving === qr.layanan}
                onClick={() => simpan(qr)}
                style={{ display: "flex", alignItems: "center", gap: 6 }}
              >
                <Save size={15} />
                {saving === qr.layanan ? "Menyimpan..." : "Simpan"}
              </button>
            </div>
          </div>
        )}

        <div className="card" style={{ marginTop: 16, color: "var(--text-secondary)", fontSize: 13, lineHeight: 1.7 }}>
          <strong>Cara angkanya bekerja</strong>
          <div>Buka pintu sudah mencakup jarak dasar. Kilometer di luar itu dikalikan tarif per km, lalu dibulatkan sesuai pengaturan layanannya — kalimat lengkapnya ada di bawah nama tiap layanan.</div>
          <div>Jarak dasar 0 km berarti per km dihitung sejak meter pertama, seperti sebelum kolom ini ada.</div>
          <div>Jarak perjalanan dibulatkan ke 100 m terdekat dulu untuk layanan yang membulatkan ongkos ke atas, supaya selisih beberapa meter tidak menaikkan satu langkah tarif penuh.</div>
          <div>Komisi dipotong dari ongkos, bukan ditambahkan di atasnya — driver menerima sisanya.</div>
          <div>Biaya jasa aplikasi <strong>ditambahkan di atas ongkos</strong> dan masuk utuh ke bohAntar. Bagian driver tidak berkurang karenanya.</div>
          <div>Pendapatan bohAntar per pesanan = komisi + biaya jasa. Pada pesanan tunai keduanya dipotong dari saldo driver, karena penumpang membayar ke tangan driver.</div>
          <div>Perubahan hanya berlaku untuk pesanan baru. Pesanan yang sudah berjalan memakai komisi yang terkunci saat dibuat.</div>
        </div>
      </div>
    </>
  );
}
