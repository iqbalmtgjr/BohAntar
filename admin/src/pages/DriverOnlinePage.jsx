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
const KOSONG = { nama: "", hp: "", layanan: "BohRide", jemput: { alamat: "", lat: "", lng: "" }, tujuan: { alamat: "", lat: "", lng: "" }, driver: "" };

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

  const { jemput, tujuan, layanan } = form;
  useEffect(() => {
    if (!jemput.lat || !tujuan.lat) return setEstimasi(null);
    api.estimasiTarif(layanan, jemput, tujuan).then((res) => setEstimasi(res.rincian || null)).catch(() => setEstimasi(null));
  }, [layanan, jemput.lat, jemput.lng, tujuan.lat, tujuan.lng]);

  const drivers = data?.drivers || [];
  const nama = Object.fromEntries(drivers.map((d) => [d.phone, d.name]));
  // Calon untuk layanan ini: siaga, kendaraan cocok, terdekat dari titik jemput.
  const calon = drivers
    .filter((d) => statusDriver(d) === "siaga" && cocok(layanan, d.kendaraan))
    .map((d) => ({ ...d, km: jemput.lat ? jarakKM({ lat: +jemput.lat, lng: +jemput.lng }, d) : null }))
    .sort((a, b) => (a.km ?? 0) - (b.km ?? 0));
  const set = (k, v) => setForm((f) => ({ ...f, [k]: v }));

  const buat = async (e) => {
    e.preventDefault();
    setKirim(true);
    const res = await api.buatPesananManual({
      nama: form.nama, hp: form.hp, layanan,
      jemput: jemput.alamat, jemput_lat: +jemput.lat, jemput_lng: +jemput.lng,
      tujuan: tujuan.alamat, tujuan_lat: +tujuan.lat, tujuan_lng: +tujuan.lng,
      driver_phone: form.driver,
    }).catch(() => ({ error: "Gagal menghubungi server" }));
    setKirim(false);
    if (res.status !== "success") return toast.error(res.error || "Gagal membuat pesanan");
    toast.success(`Pesanan dibuat · ${rp(res.order.fare + res.order.biaya_jasa)} · ${form.driver ? "menunggu " + (nama[form.driver] || "driver") + " menerima" : "disiarkan ke driver"}`, 8000);
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
                <select className="input" value={layanan} onChange={(e) => setForm((f) => ({ ...f, layanan: e.target.value, driver: "" }))}>
                  <option value="BohRide">BohRide (motor)</option>
                  <option value="BohCar">BohCar (mobil)</option>
                </select>
              </div>
              <TitikAlamat judul="Jemput" nilai={jemput} ubah={(v) => set("jemput", v)} />
              <TitikAlamat judul="Tujuan" nilai={tujuan} ubah={(v) => set("tujuan", v)} />
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
                  <b style={{ fontSize: 16 }}>{rp(estimasi.total)}</b> dibayar tunai ke driver · {estimasi.km.toFixed(1)} km · driver terima {rp(estimasi.driver)}
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
                          setForm((f) => ({ ...f, driver: d.phone, layanan: d.kendaraan === "mobil" ? "BohCar" : "BohRide" }));
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
