import { useEffect, useRef, useState } from "react";
import L from "leaflet";
import "leaflet/dist/leaflet.css";
import { RefreshCw, Send, Search } from "lucide-react";
import { api } from "../api";
import Topbar from "../components/Topbar";
import PetaTitik from "../components/PetaTitik";
import { toast, Alert } from "../components/Feedback";

/* Pantau driver online + pesanan manual untuk pelanggan yang menelepon/WA admin.
   Pesanan manual adalah pesanan biasa yang hanya ditawarkan ke driver pilihan
   (backend/dispatch.go): driver tetap menekan Terima di aplikasinya, dan
   kedaluwarsa 15 menit seperti pesanan lain. Kosongkan driver = siarkan. */

const SINTANG = [0.0785, 111.494];
const WARNA = { siaga: "#10B981", mengantar: "#F59E0B", nonaktif: "#94A3B8" };
const LABEL = { siaga: "Siaga", mengantar: "Mengantar", nonaktif: "Dinonaktifkan" };
const BADGE = { siaga: "badge-success", mengantar: "badge-warning", nonaktif: "badge-muted" };
const statusDriver = (d) => (d.pesanan ? "mengantar" : d.aktif ? "siaga" : "nonaktif");
const lalu = (s) => (s < 60 ? `${s} dtk lalu` : `${Math.floor(s / 60)} mnt lalu`);
const rp = (n) => "Rp" + Math.round(n || 0).toLocaleString("id-ID");
// Salinan cocokKendaraan di backend/main.go.
const cocok = (layanan, kendaraan) => (layanan === "BohCar" ? kendaraan === "mobil" : layanan === "BohRide" ? kendaraan !== "mobil" : true);
const jarakKM = (a, b) => {
  const r = Math.PI / 180;
  const x = Math.sin(((b.lat - a.lat) * r) / 2) ** 2 + Math.cos(a.lat * r) * Math.cos(b.lat * r) * Math.sin(((b.lng - a.lng) * r) / 2) ** 2;
  return 12742 * Math.asin(Math.sqrt(x));
};
const KOSONG = {
  nama: "", hp: "", layanan: "BohRide", kelas: "", jemput: { alamat: "", lat: "", lng: "" }, tujuan: { alamat: "", lat: "", lng: "" }, driver: "",
  paket: "Dokumen", catatan: "", penerima: "", hpPenerima: "", warung: "", pilihan: {},
};
// Semua layanan antar; BohRental bukan pesanan antar. [layanan, kelas, label]
const LAYANAN = [
  ["BohRide", "", "BohRide (motor)"],
  ["BohCar", "", "BohCar (mobil sedang)"],
  ["BohCar", "besar", "BohCar besar (mobil 6-7 kursi)"],
  ["BohSend", "", "BohSend (kirim barang)"],
  ["BohFood", "", "BohFood (pesan makanan)"],
];
const hargaItem = (m, opsi = {}) => m.price + (m.option_groups || []).flatMap((g) => g.options.filter((o) => (opsi[g.id] || []).includes(o.id))).reduce((s, o) => s + o.price, 0);

// Menu warung untuk BohFood. pilihan = { menuId: { qty, opsi: { grupId: [opsiId] } } }.
// ponytail: satu baris per menu, jadi satu menu dengan dua varian berbeda tidak
// bisa dipesan sekaligus; buat dua pesanan atau tambah baris kalau sering diminta.
function MenuWarung({ menu, pilihan, ubah }) {
  const set = (id, v) => ubah({ ...pilihan, [id]: { qty: 0, opsi: {}, ...pilihan[id], ...v } });
  if (!menu) return <div style={{ fontSize: 12, color: "var(--text-muted)" }}>Memuat menu…</div>;
  if (!menu.length) return <div style={{ fontSize: 12, color: "var(--warning)" }}>Warung ini belum punya menu yang bisa dipesan.</div>;
  return (
    <div style={{ maxHeight: 360, overflowY: "auto", border: "1px solid var(--border)", borderRadius: 10, padding: 8 }}>
      {menu.map((m) => {
        const p = pilihan[m.id] || { qty: 0, opsi: {} };
        return (
          <div key={m.id} style={{ padding: "6px 4px", borderBottom: "1px solid var(--border)", opacity: m.is_available ? 1 : 0.5 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <div style={{ flex: 1 }}><b>{m.name}</b> <span style={{ color: "var(--text-muted)", fontSize: 12 }}>{m.is_available ? rp(m.price) : "habis"}</span></div>
              <input className="input" type="number" min={0} max={50} value={p.qty || ""} placeholder="0" disabled={!m.is_available}
                aria-label={`Jumlah ${m.name}`} style={{ width: 70 }} onChange={(e) => set(m.id, { qty: Math.max(0, Math.min(50, +e.target.value || 0)) })} />
            </div>
            {p.qty > 0 && (m.option_groups || []).map((g) => {
              const dipilih = p.opsi[g.id] || [];
              const pasang = (ids) => set(m.id, { opsi: { ...p.opsi, [g.id]: ids } });
              return g.type === "single" ? (
                <select key={g.id} className="input" style={{ marginTop: 6 }} value={dipilih[0] || ""} onChange={(e) => pasang(e.target.value ? [e.target.value] : [])}>
                  <option value="">{g.required ? `Pilih ${g.name}…` : `Tanpa ${g.name}`}</option>
                  {g.options.map((o) => <option key={o.id} value={o.id}>{o.name}{o.price ? ` (+${rp(o.price)})` : ""}</option>)}
                </select>
              ) : (
                <div key={g.id} style={{ fontSize: 13, marginTop: 6 }}>
                  {g.name}{g.required ? " (wajib)" : ""}:{" "}
                  {g.options.map((o) => (
                    <label key={o.id} style={{ marginRight: 10, whiteSpace: "nowrap" }}>
                      <input type="checkbox" checked={dipilih.includes(o.id)}
                        onChange={(e) => pasang(e.target.checked ? [...dipilih, o.id] : dipilih.filter((x) => x !== o.id))} /> {o.name}{o.price ? ` +${rp(o.price)}` : ""}
                    </label>
                  ))}
                </div>
              );
            })}
          </div>
        );
      })}
    </div>
  );
}

function PetaDriver({ drivers }) {
  const wadah = useRef(null);
  const peta = useRef(null);
  const lapis = useRef(null);
  const sudahPas = useRef(false);

  useEffect(() => {
    const m = L.map(wadah.current).setView(SINTANG, 13);
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", { maxZoom: 19, attribution: "© OpenStreetMap" }).addTo(m);
    lapis.current = L.layerGroup().addTo(m);
    peta.current = m;
    return () => m.remove();
  }, []);

  useEffect(() => {
    lapis.current.clearLayers();
    drivers.forEach((d) => {
      const s = statusDriver(d);
      L.circleMarker([d.lat, d.lng], { radius: 9, color: "#fff", weight: 2, fillColor: WARNA[s], fillOpacity: 1 })
        .bindTooltip(`${d.name} · ${d.kendaraan} · ${LABEL[s]}`)
        .addTo(lapis.current);
    });
    // Sekali saja, supaya peta tidak melompat tiap 15 detik saat sedang digeser.
    if (drivers.length && !sudahPas.current) {
      sudahPas.current = true;
      peta.current.fitBounds(drivers.map((d) => [d.lat, d.lng]), { padding: [30, 30], maxZoom: 15 });
    }
  }, [drivers]);

  return <div ref={wadah} style={{ height: 380, borderRadius: 12, overflow: "hidden", border: "1px solid var(--border)" }} />;
}

function TitikAlamat({ judul, nilai, ubah }) {
  const [q, setQ] = useState("");
  const [saran, setSaran] = useState([]);
  const sesi = useRef(crypto.randomUUID());

  const cari = async () => {
    if (q.trim().length < 3) return toast.warning("Ketik minimal 3 huruf");
    const res = await api.cariAlamat(q.trim(), sesi.current).catch(() => null);
    setSaran(res?.suggestions || []);
    if (!res?.suggestions?.length) toast.info("Tidak ketemu. Geser peta ke titiknya, lalu tulis alamatnya.");
  };
  const pilih = async (s) => {
    const res = await api.detailTempat(s.place_id, sesi.current).catch(() => null);
    sesi.current = crypto.randomUUID();
    setSaran([]);
    if (res?.status !== "success") return toast.error("Gagal membaca titik tempat itu");
    ubah({ alamat: [s.name, s.address].filter(Boolean).join(", "), lat: res.lat.toFixed(6), lng: res.lng.toFixed(6) });
  };

  return (
    <div className="input-group">
      <label>{judul}</label>
      {/* Bukan <form>: komponen ini berada di dalam form pesanan, dan Enter
          di sini tidak boleh ikut mengirim pesanannya. */}
      <div style={{ display: "flex", gap: 8, marginBottom: 8 }}>
        <input className="input" placeholder="Cari tempat…" value={q} onChange={(e) => setQ(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); cari(); } }} />
        <button type="button" className="btn" aria-label="Cari" onClick={cari}><Search size={16} /></button>
      </div>
      {saran.map((s) => (
        <button key={s.place_id} type="button" className="btn" onClick={() => pilih(s)}
          style={{ display: "block", width: "100%", textAlign: "left", marginBottom: 4, whiteSpace: "normal" }}>
          <b>{s.name}</b> <span style={{ color: "var(--text-muted)" }}>{s.address}</span>
        </button>
      ))}
      <input className="input" placeholder="Alamat / patokan untuk driver" value={nilai.alamat}
        onChange={(e) => ubah({ ...nilai, alamat: e.target.value })} style={{ marginBottom: 8 }} />
      <PetaTitik lat={nilai.lat} lng={nilai.lng} tinggi={200} onChange={(lat, lng) => ubah({ ...nilai, lat, lng })} />
      {!nilai.lat && <div style={{ fontSize: 12, color: "var(--text-muted)", marginTop: 4 }}>Cari tempat atau geser peta sampai pin tepat di titiknya.</div>}
    </div>
  );
}

export default function DriverOnlinePage() {
  const [data, setData] = useState(null);
  const [menunggu, setMenunggu] = useState([]);
  const [galat, setGalat] = useState("");
  const [form, setForm] = useState(KOSONG);
  const [estimasi, setEstimasi] = useState(null);
  const [kirim, setKirim] = useState(false);
  const [alih, setAlih] = useState({});
  const formRef = useRef(null);

  const muat = () => {
    api.getDriverOnline()
      .then((res) => (res.status === "success" ? (setData(res), setGalat("")) : setGalat(res.error || "Gagal memuat")))
      .catch(() => setGalat("Gagal memuat"));
    api.getOrders({ status: "pending", limit: 50 }).then((res) => setMenunggu(res.orders || [])).catch(() => {});
  };
  useEffect(() => {
    muat();
    const t = setInterval(() => !document.hidden && muat(), 15000);
    return () => clearInterval(t);
  }, []);

  const [warungList, setWarungList] = useState(null);
  const [menu, setMenu] = useState(null);
  const { tujuan, layanan, kelas } = form;
  const makanan = layanan === "BohFood";
  useEffect(() => {
    if (makanan && !warungList) api.daftarWarung().then((res) => setWarungList(res.merchants || [])).catch(() => setWarungList([]));
  }, [makanan]);
  useEffect(() => {
    setMenu(null);
    if (form.warung) api.menuWarung(form.warung).then((res) => setMenu(Array.isArray(res) ? res : [])).catch(() => setMenu([]));
  }, [form.warung]);
  const warung = makanan ? (warungList || []).find((w) => w.id === form.warung) : null;
  // BohFood dijemput di warung: server menulis ulang titik jemputnya ke lokasi warung.
  const jemput = makanan ? (warung ? { alamat: warung.restaurant_name, lat: warung.lat, lng: warung.lng } : { alamat: "", lat: "", lng: "" }) : form.jemput;
  const subtotal = makanan && menu ? menu.reduce((s, m) => s + (form.pilihan[m.id]?.qty || 0) * hargaItem(m, form.pilihan[m.id]?.opsi), 0) : 0;

  useEffect(() => {
    if (!jemput.lat || !tujuan.lat) return setEstimasi(null);
    api.estimasiTarif(layanan, jemput, tujuan, kelas).then((res) => setEstimasi(res.rincian || null)).catch(() => setEstimasi(null));
  }, [layanan, kelas, jemput.lat, jemput.lng, tujuan.lat, tujuan.lng]);

  const drivers = data?.drivers || [];
  const nama = Object.fromEntries(drivers.map((d) => [d.phone, d.name]));
  // Calon untuk layanan ini: siaga, kendaraan cocok, terdekat dari titik jemput.
  // Ukuran mobil (BohCar besar) tidak ada di daftar ini; server yang menolak.
  const calon = drivers
    .filter((d) => statusDriver(d) === "siaga" && cocok(layanan, d.kendaraan))
    .map((d) => ({ ...d, km: jemput.lat ? jarakKM({ lat: +jemput.lat, lng: +jemput.lng }, d) : null }))
    .sort((a, b) => (a.km ?? 0) - (b.km ?? 0));
  const set = (k, v) => setForm((f) => ({ ...f, [k]: v }));

  const buat = async (e) => {
    e.preventDefault();
    const items = Object.entries(form.pilihan).filter(([, p]) => p.qty > 0)
      .map(([id, p]) => ({ menu_id: id, qty: p.qty, options: Object.values(p.opsi || {}).flat() }));
    if (makanan && !form.warung) return toast.warning("Pilih warungnya dulu");
    if (makanan && !items.length) return toast.warning("Isi jumlah minimal satu menu");
    setKirim(true);
    const res = await api.buatPesananManual({
      nama: form.nama, hp: form.hp, layanan, kelas,
      jemput: jemput.alamat, jemput_lat: +jemput.lat, jemput_lng: +jemput.lng,
      tujuan: tujuan.alamat, tujuan_lat: +tujuan.lat, tujuan_lng: +tujuan.lng,
      driver_phone: form.driver,
      ...(layanan === "BohSend" && { package_type: form.paket, package_notes: form.catatan, receiver_name: form.penerima, receiver_phone: form.hpPenerima }),
      ...(makanan && { merchant_id: form.warung, items, package_notes: form.catatan }),
    }).catch(() => ({ error: "Gagal menghubungi server" }));
    setKirim(false);
    if (res.status !== "success") return toast.error(res.error || "Gagal membuat pesanan");
    toast.success(`Pesanan dibuat · ${rp(res.order.fare + res.order.biaya_jasa + (res.order.food_total || 0))} · ${form.driver ? "menunggu " + (nama[form.driver] || "driver") + " menerima" : "disiarkan ke driver"}`, 8000);
    setForm(KOSONG);
    muat();
  };

  const alihkan = async (o) => {
    const res = await api.tujukanPesanan(o.id, alih[o.id] ?? "").catch(() => ({ error: "Gagal menghubungi server" }));
    if (res.status !== "success") return toast.error(res.error || "Gagal mengalihkan");
    toast.success("Pesanan dialihkan");
    muat();
  };

  const r = data?.ringkasan || {};
  return (
    <>
      <Topbar title="Driver Online" />
      <div className="page">
        <div className="page-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 12 }}>
          <div>
            <h1>Driver Online</h1>
            <p>Driver yang mengirim posisi dalam 10 menit terakhir. Diperbarui tiap 15 detik.</p>
          </div>
          <button className="btn" onClick={muat} aria-label="Muat ulang"><RefreshCw size={16} /></button>
        </div>

        <Alert type="error" style={{ marginBottom: 16 }}>{galat}</Alert>

        <div className="stats-grid">
          {[
            { label: "Online", value: r.online, warna: "var(--primary)" },
            { label: "Siaga (bisa diberi order)", value: r.siaga, warna: WARNA.siaga },
            { label: "Sedang mengantar", value: r.mengantar, warna: WARNA.mengantar },
          ].map((s) => (
            <div key={s.label} className="stat-card">
              <div><div className="stat-value" style={{ color: s.warna }}>{s.value ?? "-"}</div><div className="stat-label">{s.label}</div></div>
            </div>
          ))}
        </div>

        <div className="grid-2" style={{ marginBottom: 20, alignItems: "start" }}>
          <div className="card">
            <div className="card-title" style={{ marginBottom: 12 }}>Peta driver</div>
            <PetaDriver drivers={drivers} />
            <div style={{ display: "flex", gap: 14, fontSize: 12, marginTop: 8, flexWrap: "wrap" }}>
              {Object.keys(WARNA).map((s) => (
                <span key={s}><span style={{ display: "inline-block", width: 10, height: 10, borderRadius: 5, background: WARNA[s], marginRight: 4 }} />{LABEL[s]}</span>
              ))}
            </div>
          </div>

          <div className="card" ref={formRef}>
            <div className="card-title" style={{ marginBottom: 12 }}>Pesanan manual</div>
            <form onSubmit={buat}>
              <div className="input-group">
                <label>Nama pelanggan</label>
                <input className="input" value={form.nama} onChange={(e) => set("nama", e.target.value)} maxLength={60} required />
              </div>
              <div className="input-group">
                <label>Nomor HP pelanggan</label>
                <input className="input" type="tel" placeholder="0812…" value={form.hp} onChange={(e) => set("hp", e.target.value)} required />
                <div style={{ fontSize: 12, color: "var(--text-muted)", marginTop: 4 }}>Kalau nomornya punya akun BohAntar, pesanan masuk ke akunnya dan ia bisa melacak driver.</div>
              </div>
              <div className="input-group">
                <label>Layanan</label>
                <select className="input" value={`${layanan}|${kelas}`}
                  onChange={(e) => { const [l, k] = e.target.value.split("|"); setForm((f) => ({ ...f, layanan: l, kelas: k, driver: "" })); }}>
                  {LAYANAN.map(([l, k, label]) => <option key={l + k} value={`${l}|${k}`}>{label}</option>)}
                </select>
              </div>
              {makanan ? (
                <div className="input-group">
                  <label>Warung</label>
                  <select className="input" value={form.warung} onChange={(e) => setForm((f) => ({ ...f, warung: e.target.value, pilihan: {} }))} style={{ marginBottom: 8 }}>
                    <option value="">{warungList ? "Pilih warung…" : "Memuat warung…"}</option>
                    {(warungList || []).map((w) => <option key={w.id} value={w.id} disabled={!w.is_open}>{w.restaurant_name}{w.is_open ? "" : " (tutup)"}</option>)}
                  </select>
                  {form.warung && <MenuWarung menu={menu} pilihan={form.pilihan} ubah={(v) => set("pilihan", v)} />}
                  {subtotal > 0 && <div style={{ fontSize: 13, marginTop: 6 }}>Harga makanan <b>{rp(subtotal)}</b></div>}
                </div>
              ) : (
                <TitikAlamat judul="Jemput" nilai={form.jemput} ubah={(v) => set("jemput", v)} />
              )}
              <TitikAlamat judul={makanan || layanan === "BohSend" ? "Antar ke" : "Tujuan"} nilai={tujuan} ubah={(v) => set("tujuan", v)} />
              {layanan === "BohSend" && (
                <>
                  <div className="input-group">
                    <label>Isi paket</label>
                    <select className="input" value={form.paket} onChange={(e) => set("paket", e.target.value)}>
                      {["Dokumen", "Makanan", "Pakaian", "Elektronik", "Lainnya"].map((p) => <option key={p}>{p}</option>)}
                    </select>
                  </div>
                  <div className="input-group">
                    <label>Penerima</label>
                    <div style={{ display: "flex", gap: 8 }}>
                      <input className="input" placeholder="Nama penerima" value={form.penerima} maxLength={100} onChange={(e) => set("penerima", e.target.value)} />
                      <input className="input" type="tel" placeholder="HP penerima" value={form.hpPenerima} maxLength={20} onChange={(e) => set("hpPenerima", e.target.value)} />
                    </div>
                  </div>
                </>
              )}
              {(makanan || layanan === "BohSend") && (
                <div className="input-group">
                  <label>Catatan untuk driver</label>
                  <input className="input" placeholder={makanan ? "Mis. sambal dipisah" : "Mis. barang mudah pecah"} value={form.catatan} maxLength={500} onChange={(e) => set("catatan", e.target.value)} />
                </div>
              )}
              <div className="input-group">
                <label>Driver</label>
                <select className="input" value={form.driver} onChange={(e) => set("driver", e.target.value)}>
                  <option value="">Siarkan ke semua driver terdekat</option>
                  {calon.map((d) => (
                    <option key={d.phone} value={d.phone}>{d.name}{d.km != null ? ` · ${d.km.toFixed(1)} km dari jemput` : ""}</option>
                  ))}
                </select>
                {!calon.length && <div style={{ fontSize: 12, color: "var(--warning)", marginTop: 4 }}>Tidak ada driver {layanan} yang siaga saat ini.</div>}
              </div>
              {estimasi && (
                <div style={{ background: "var(--primary-glow)", borderRadius: 10, padding: 12, marginBottom: 16, fontSize: 13 }}>
                  <b style={{ fontSize: 16 }}>{rp(estimasi.total + subtotal)}</b> dibayar tunai ke driver{subtotal > 0 && ` (makanan ${rp(subtotal)} + ongkir ${rp(estimasi.total)})`} · {estimasi.km.toFixed(1)} km · driver terima {rp(estimasi.driver)}
                </div>
              )}
              <button type="submit" className="btn btn-primary" disabled={kirim} style={{ width: "100%", justifyContent: "center", padding: 12 }}>
                {kirim ? <span className="spinner" /> : <><Send size={16} /> Buat pesanan</>}
              </button>
            </form>
          </div>
        </div>

        <div className="table-wrap" style={{ marginBottom: 20 }}>
          <div className="table-header"><h3>Driver online ({drivers.length})</h3></div>
          <table>
            <thead><tr><th>Driver</th><th>Kendaraan</th><th>Status</th><th>Posisi terakhir</th><th></th></tr></thead>
            <tbody>
              {drivers.map((d) => {
                const s = statusDriver(d);
                return (
                  <tr key={d.phone}>
                    <td><b>{d.name}</b><div style={{ fontSize: 12, color: "var(--text-muted)" }}>{d.phone}</div></td>
                    <td>{d.kendaraan}</td>
                    <td>
                      <span className={`badge ${BADGE[s]}`}>{LABEL[s]}</span>
                      {d.pesanan && <div style={{ fontSize: 12, color: "var(--text-muted)", marginTop: 4 }}>{d.pesanan.service}: {d.pesanan.pickup} → {d.pesanan.dropoff}</div>}
                    </td>
                    <td>{lalu(d.detik_lalu)}</td>
                    <td>
                      {s === "siaga" && (
                        <button className="btn" onClick={() => {
                          // Layanan yang sedang dipilih dipertahankan kalau kendaraannya cocok (BohSend/BohFood boleh keduanya).
                          setForm((f) => ({ ...f, driver: d.phone, ...(cocok(f.layanan, d.kendaraan) ? {} : { layanan: d.kendaraan === "mobil" ? "BohCar" : "BohRide", kelas: "" }) }));
                          formRef.current?.scrollIntoView({ behavior: "smooth" });
                        }}>Tugaskan</button>
                      )}
                    </td>
                  </tr>
                );
              })}
              {!drivers.length && <tr><td colSpan={5} style={{ textAlign: "center", color: "var(--text-muted)" }}>Belum ada driver online.</td></tr>}
            </tbody>
          </table>
        </div>

        <div className="table-wrap">
          <div className="table-header"><h3>Menunggu driver ({menunggu.length})</h3></div>
          <table>
            <thead><tr><th>Pemesan</th><th>Rute</th><th>Ditujukan ke</th><th>Alihkan</th></tr></thead>
            <tbody>
              {menunggu.map((o) => (
                <tr key={o.id}>
                  <td><b>{o.rider_name || "-"}</b><div style={{ fontSize: 12, color: "var(--text-muted)" }}>{o.service} · {new Date(o.created_at).toLocaleTimeString("id-ID", { hour: "2-digit", minute: "2-digit" })}</div></td>
                  <td style={{ fontSize: 13 }}>{o.pickup} → {o.dropoff}</td>
                  <td>{o.driver_tujuan ? nama[o.driver_tujuan] || o.driver_tujuan : <span style={{ color: "var(--text-muted)" }}>Semua driver</span>}</td>
                  <td style={{ display: "flex", gap: 6 }}>
                    <select className="input" value={alih[o.id] ?? ""} onChange={(e) => setAlih((a) => ({ ...a, [o.id]: e.target.value }))}>
                      <option value="">Semua driver</option>
                      {drivers.filter((d) => statusDriver(d) === "siaga" && cocok(o.service, d.kendaraan)).map((d) => (
                        <option key={d.phone} value={d.phone}>{d.name}</option>
                      ))}
                    </select>
                    <button className="btn" onClick={() => alihkan(o)}>Alihkan</button>
                  </td>
                </tr>
              ))}
              {!menunggu.length && <tr><td colSpan={4} style={{ textAlign: "center", color: "var(--text-muted)" }}>Tidak ada pesanan yang menunggu.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
    </>
  );
}
