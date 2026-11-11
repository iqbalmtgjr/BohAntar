import { useEffect, useRef, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { ArrowLeft, MessageCircle, Send } from "lucide-react";
import { BASE, authFetch } from "../../api";

/* Chat penyewa, meniru tab Chat di aplikasi.
   /chat       → daftar: satu baris per sewa yang sudah ada pesannya, terbaru di
                 atas. Ringkasannya (chat_terakhir dkk.) ikut di /rental/bookings.
   /chat/{id}  → percakapan satu sewa (backend: chat_sewa.go). Tombol "Chat
                 Penyewa" di Pesanan Masuk langsung ke sini. */

const BULAN = ["Jan", "Feb", "Mar", "Apr", "Mei", "Jun", "Jul", "Agu", "Sep", "Okt", "Nov", "Des"];
const tgl = (s) => new Date(String(s).replace(" ", "T"));
const waktu = (s) => {
  const t = tgl(s);
  if (isNaN(t)) return "";
  const hari = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate());
  const selisih = Math.round((hari(new Date()) - hari(t)) / 86400000);
  if (selisih === 0) return `${String(t.getHours()).padStart(2, "0")}.${String(t.getMinutes()).padStart(2, "0")}`;
  if (selisih === 1) return "Kemarin";
  return `${t.getDate()} ${BULAN[t.getMonth()]}`;
};
const jam = (s) => {
  const t = tgl(s);
  return isNaN(t) ? "" : t.toLocaleString("id-ID", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" });
};

const STATUS = { pending: "Menunggu", confirmed: "Disetujui", ongoing: "Berjalan", completed: "Selesai", cancelled: "Dibatalkan", rejected: "Ditolak" };

export default function RentalChat({ ownerPhone }) {
  const { id } = useParams();
  return id ? <Percakapan key={id} id={id} ownerPhone={ownerPhone} /> : <DaftarChat ownerPhone={ownerPhone} />;
}

function DaftarChat({ ownerPhone }) {
  const [daftar, setDaftar] = useState(null);
  const [galat, setGalat] = useState(false);
  const [hanyaBelum, setHanyaBelum] = useState(false);

  const muat = async () => {
    try {
      const r = await authFetch(`${BASE}/rental/bookings?owner_phone=${encodeURIComponent(ownerPhone)}`);
      const data = await r.json();
      if (!r.ok || !Array.isArray(data)) throw new Error();
      // Bookings juga memuat sewaan mitra sendiri sebagai penyewa; daftar ini khusus armadanya.
      setDaftar(data.filter(b => b.chat_terakhir && b.owner_phone === ownerPhone)
        .sort((a, b) => b.chat_waktu.localeCompare(a.chat_waktu)));
      setGalat(false);
    } catch {
      setGalat(true);
    }
  };

  // ponytail: tanya ulang tiap 10 dtk selama halaman terbuka; WebSocket kalau ramai.
  useEffect(() => {
    muat();
    const t = setInterval(() => !document.hidden && muat(), 10000);
    return () => clearInterval(t);
  }, [ownerPhone]);

  const tampil = (daftar || []).filter(b => !hanyaBelum || b.chat_belum > 0);
  const chip = (label, nilai) => (
    <button
      type="button"
      onClick={() => setHanyaBelum(nilai)}
      style={{
        padding: "6px 14px", borderRadius: 999, fontSize: 13, cursor: "pointer",
        fontWeight: hanyaBelum === nilai ? 700 : 500,
        border: `1px solid ${hanyaBelum === nilai ? "var(--primary)" : "var(--border)"}`,
        background: hanyaBelum === nilai ? "rgba(37, 99, 235, 0.10)" : "transparent",
        color: hanyaBelum === nilai ? "var(--primary)" : "var(--text-secondary)"
      }}
    >
      {label}
    </button>
  );

  return (
    <div className="page">
      <div className="page-header">
        <div>
          <h1>Chat</h1>
          <p style={{ color: "var(--text-secondary)", fontSize: 13, margin: 0 }}>Obrolan dengan penyewa armadamu</p>
        </div>
      </div>

      <div style={{ display: "flex", gap: 8, marginBottom: 12 }}>
        {chip("Semua chat", false)}
        {chip("Belum dibaca", true)}
      </div>

      <div className="card" style={{ padding: 0, overflow: "hidden" }}>
        {daftar === null ? (
          galat ? (
            <div style={{ padding: 40, textAlign: "center" }}>
              <p style={{ color: "var(--text-secondary)" }}>Chat belum bisa dimuat. Cek koneksi internetmu.</p>
              <button className="btn btn-primary btn-sm" onClick={muat}>Coba lagi</button>
            </div>
          ) : <div className="spinner" style={{ margin: "60px auto" }}></div>
        ) : tampil.length === 0 ? (
          <div style={{ padding: "48px 24px", textAlign: "center", color: "var(--text-secondary)" }}>
            <MessageCircle size={40} style={{ opacity: 0.35, marginBottom: 10 }} />
            <div style={{ fontWeight: 800, color: "var(--text-primary)", marginBottom: 4 }}>
              {hanyaBelum ? "Semua chat sudah dibaca" : "Belum ada chat"}
            </div>
            <div style={{ fontSize: 13 }}>
              Chat penyewa muncul di sini. Untuk menyapa duluan, tekan Chat Penyewa di <Link to="/orders">Pesanan Masuk</Link>.
            </div>
          </div>
        ) : tampil.map((b, i) => {
          const nama = b.customer_name || "Penyewa";
          const belum = b.chat_belum > 0;
          return (
            <Link
              key={b.id}
              to={`/chat/${b.id}`}
              style={{
                display: "flex", alignItems: "center", gap: 14, padding: "12px 18px",
                textDecoration: "none", color: "inherit",
                borderTop: i ? "1px solid var(--border)" : "none"
              }}
            >
              <div style={{
                width: 48, height: 48, borderRadius: "50%", flexShrink: 0,
                background: "rgba(37, 99, 235, 0.12)", color: "var(--primary)",
                display: "flex", alignItems: "center", justifyContent: "center", fontSize: 18, fontWeight: 800
              }}>
                {nama[0].toUpperCase()}
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ display: "flex", gap: 8, alignItems: "baseline" }}>
                  <span style={{ flex: 1, fontWeight: 800, fontSize: 14.5, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{nama}</span>
                  <span style={{ fontSize: 11.5, color: belum ? "var(--primary)" : "var(--text-muted)", fontWeight: belum ? 700 : 400 }}>{waktu(b.chat_waktu)}</span>
                </div>
                <div style={{ fontSize: 11.5, color: "var(--text-muted)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                  {b.car_name} · {STATUS[b.status] || b.status}
                </div>
                <div style={{ display: "flex", gap: 8, alignItems: "center", marginTop: 3 }}>
                  <span style={{
                    flex: 1, fontSize: 13, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis",
                    color: belum ? "var(--text-primary)" : "var(--text-secondary)", fontWeight: belum ? 600 : 400
                  }}>
                    {b.chat_dari_saya ? "Kamu: " : ""}{b.chat_terakhir}
                  </span>
                  {belum && (
                    <span style={{
                      minWidth: 20, height: 20, padding: "0 6px", borderRadius: 999, background: "#EF4444", color: "#fff",
                      fontSize: 11, fontWeight: 800, lineHeight: "20px", textAlign: "center"
                    }}>
                      {b.chat_belum > 99 ? "99+" : b.chat_belum}
                    </span>
                  )}
                </div>
              </div>
            </Link>
          );
        })}
      </div>
    </div>
  );
}

/* Satu percakapan. Ditanya tiap 4 detik selama terbuka; membuka = membaca
   semua pesan penyewa (lencana padam). */
function Percakapan({ id, ownerPhone }) {
  const [data, setData] = useState(null); // { messages, penyewa, kendaraan }
  const [isi, setIsi] = useState("");
  const [galat, setGalat] = useState("");
  const [mengirim, setMengirim] = useState(false);
  const kotak = useRef(null);
  const jumlah = useRef(-1);

  const muat = async () => {
    try {
      const r = await authFetch(`${BASE}/rental/chat/${id}`);
      const j = await r.json();
      if (!r.ok) throw new Error(j.error || "Chat gagal dimuat");
      setData({ ...j, messages: j.messages || [] });
      setGalat("");
    } catch (e) {
      setGalat(e.message || "Chat gagal dimuat");
    }
  };

  useEffect(() => {
    muat();
    const t = setInterval(() => !document.hidden && muat(), 4000);
    return () => clearInterval(t);
  }, [id]);

  // Gulir ke bawah hanya saat ada pesan baru, bukan tiap kali ditanya ulang.
  // Yang digulir kotak pesannya saja: scrollIntoView ikut menggeser halaman.
  const pesan = data?.messages;
  useEffect(() => {
    if (pesan && pesan.length !== jumlah.current) {
      jumlah.current = pesan.length;
      if (kotak.current) kotak.current.scrollTop = kotak.current.scrollHeight;
    }
  }, [pesan]);

  const kirim = async (e) => {
    e.preventDefault();
    const teks = isi.trim();
    if (!teks || mengirim) return;
    setMengirim(true);
    try {
      const r = await authFetch(`${BASE}/rental/chat/${id}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ content: teks })
      });
      const j = await r.json();
      if (!r.ok) throw new Error(j.error || "Pesan gagal dikirim");
      setIsi("");
      await muat();
    } catch (e) {
      setGalat(e.message || "Pesan gagal dikirim");
    } finally {
      setMengirim(false);
    }
  };

  return (
    <div className="page">
      <div className="card chat-room" style={{ display: "flex", flexDirection: "column", padding: 0, overflow: "hidden", maxWidth: 820, margin: "0 auto" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "12px 14px", borderBottom: "1px solid var(--border)" }}>
          <Link to="/chat" className="btn btn-ghost btn-sm" aria-label="Kembali ke daftar chat"><ArrowLeft size={18} /></Link>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontWeight: 800 }}>{data?.penyewa || "Penyewa"}</div>
            <div style={{ fontSize: 12, color: "var(--text-secondary)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
              {data?.kendaraan && `${data.kendaraan} · `}<span style={{ fontFamily: "monospace" }}>#{id}</span>
            </div>
          </div>
        </div>

        <div ref={kotak} style={{ flex: 1, overflowY: "auto", padding: 16, display: "flex", flexDirection: "column", gap: 8 }}>
          {!pesan ? (
            galat ? <p style={{ color: "var(--danger)", textAlign: "center" }}>{galat}</p> : <div className="spinner" style={{ margin: "40px auto" }}></div>
          ) : pesan.length === 0 ? (
            <p style={{ color: "var(--text-muted)", textAlign: "center", fontSize: 13, margin: "auto 0" }}>
              Belum ada pesan. Sapa penyewa untuk memastikan jadwal ambil, syarat dokumen, atau lokasi antar.
            </p>
          ) : pesan.map(m => {
            const saya = m.sender_phone === ownerPhone;
            return (
              <div key={m.id} style={{ alignSelf: saya ? "flex-end" : "flex-start", maxWidth: "78%" }}>
                <div style={{
                  padding: "8px 12px", borderRadius: 14, fontSize: 14, lineHeight: 1.45, whiteSpace: "pre-wrap", wordBreak: "break-word",
                  background: saya ? "var(--primary)" : "var(--bg-input)", color: saya ? "#fff" : "var(--text-primary)",
                  borderBottomRightRadius: saya ? 4 : 14, borderBottomLeftRadius: saya ? 14 : 4
                }}>
                  {m.content}
                </div>
                <div style={{ fontSize: 10.5, color: "var(--text-muted)", marginTop: 3, textAlign: saya ? "right" : "left" }}>{jam(m.timestamp)}</div>
              </div>
            );
          })}
        </div>

        {galat && pesan && (
          <div style={{ fontSize: 12, color: "var(--danger)", padding: "6px 16px 0" }}>{galat}</div>
        )}
        <form onSubmit={kirim} style={{ display: "flex", gap: 8, padding: 12, borderTop: "1px solid var(--border)" }}>
          <input
            className="input"
            style={{ flex: 1, marginBottom: 0 }}
            placeholder="Tulis pesan untuk penyewa"
            maxLength={1000}
            value={isi}
            onChange={e => setIsi(e.target.value)}
            // Di HP keyboard langsung naik menutupi pesan yang baru mau dibaca.
            autoFocus={!window.matchMedia("(pointer: coarse)").matches}
          />
          <button type="submit" className="btn btn-primary" disabled={mengirim || !isi.trim()} aria-label="Kirim">
            <Send size={16} />
          </button>
        </form>
      </div>
    </div>
  );
}
