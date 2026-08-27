import React, { useEffect, useRef, useSyncExternalStore } from "react";
import { CheckCircle2, XCircle, AlertTriangle, Info, X } from "lucide-react";

/*
 * Satu pintu untuk semua umpan balik di portal admin & mitra:
 *
 *   toast.success("Tersimpan")            notifikasi melayang, hilang sendiri
 *   await confirmDialog("Hapus menu?")    modal konfirmasi, mengembalikan true/false
 *   <Alert type="error">...</Alert>       pesan menetap di dalam form
 *
 * Aturan pakainya: hasil aksi yang sudah selesai (simpan/hapus/kirim) pakai toast,
 * kesalahan yang harus tetap terlihat sambil pengguna memperbaiki isian pakai Alert.
 * <Toaster /> dan <ConfirmHost /> cukup dipasang sekali di main.jsx.
 */

const ICONS = { success: CheckCircle2, error: XCircle, warning: AlertTriangle, info: Info };

/* ---------------- Toast ---------------- */

let toasts = [];
const toastListeners = new Set();
const emitToasts = () => toastListeners.forEach((l) => l());
const toastStore = {
  subscribe(l) { toastListeners.add(l); return () => toastListeners.delete(l); },
  // useSyncExternalStore butuh referensi yang stabil selama isinya tidak berubah,
  // jadi `toasts` hanya diganti (bukan dimutasi) saat ada perubahan nyata.
  get: () => toasts,
};

let toastSeq = 0;

function dismissToast(id) {
  const next = toasts.filter((t) => t.id !== id);
  if (next.length === toasts.length) return;
  toasts = next;
  emitToasts();
}

function pushToast(type, text, ms) {
  if (!text) return;
  const t = { id: ++toastSeq, type, text: String(text) };
  // Maksimal 4 di layar; yang paling lama terdorong keluar supaya tidak menumpuk.
  toasts = [...toasts, t].slice(-4);
  emitToasts();
  // Error diberi waktu baca lebih lama karena biasanya memuat instruksi.
  setTimeout(() => dismissToast(t.id), ms ?? (type === "error" ? 6000 : 4000));
}

export const toast = {
  success: (text, ms) => pushToast("success", text, ms),
  error: (text, ms) => pushToast("error", text, ms),
  warning: (text, ms) => pushToast("warning", text, ms),
  info: (text, ms) => pushToast("info", text, ms),
};

export function Toaster() {
  const list = useSyncExternalStore(toastStore.subscribe, toastStore.get);
  return (
    <div className="toaster" role="status" aria-live="polite" aria-atomic="false">
      {list.map((t) => {
        const Icon = ICONS[t.type] || Info;
        return (
          <div key={t.id} className={`toast toast-${t.type}`}>
            <Icon size={18} className="toast-icon" />
            <span className="toast-text">{t.text}</span>
            <button type="button" className="toast-close" onClick={() => dismissToast(t.id)} aria-label="Tutup notifikasi">
              <X size={14} />
            </button>
          </div>
        );
      })}
    </div>
  );
}

/* ---------------- Modal konfirmasi ---------------- */

let pending = null;
const confirmListeners = new Set();
const confirmStore = {
  subscribe(l) { confirmListeners.add(l); return () => confirmListeners.delete(l); },
  get: () => pending,
};

/**
 * Pengganti window.confirm. Terima string pendek atau objek
 * { title, message, confirmText, cancelText, tone: "danger" | "primary" }.
 */
export function confirmDialog(opts) {
  const cfg = typeof opts === "string" ? { message: opts } : opts || {};
  // Hanya satu dialog yang muat di layar: permintaan lama dibatalkan supaya
  // promise-nya tidak menggantung selamanya.
  settle(false);
  return new Promise((resolve) => {
    pending = {
      title: cfg.title || "Konfirmasi",
      message: cfg.message || "",
      confirmText: cfg.confirmText || "Ya, lanjutkan",
      cancelText: cfg.cancelText || "Batal",
      tone: cfg.tone || "danger",
      resolve,
      done: false,
    };
    confirmListeners.forEach((l) => l());
  });
}

// Dipanggil dari tombol, ESC, maupun klik backdrop; hanya jawaban pertama yang dipakai.
function settle(value) {
  const req = pending;
  if (!req || req.done) return;
  req.done = true;
  pending = null;
  confirmListeners.forEach((l) => l());
  req.resolve(value);
}

export function ConfirmHost() {
  const req = useSyncExternalStore(confirmStore.subscribe, confirmStore.get);
  const ref = useRef(null);

  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    // <dialog> native sudah membawa focus trap, tutup-dengan-ESC, dan top layer,
    // jadi tidak perlu overlay + penjebak fokus buatan sendiri.
    if (req && !d.open) d.showModal();
    else if (!req && d.open) d.close();
  }, [req]);

  const Icon = req && req.tone === "danger" ? AlertTriangle : Info;

  return (
    <dialog
      ref={ref}
      className="confirm"
      onClose={() => settle(false)}
      // Padding ada di .confirm-body, jadi target dialog itu sendiri = klik backdrop.
      onClick={(e) => { if (e.target === ref.current) settle(false); }}
    >
      {req && (
        <div className="confirm-body">
          <div className={`confirm-icon confirm-icon-${req.tone}`}><Icon size={22} /></div>
          <h2>{req.title}</h2>
          {req.message && <p>{req.message}</p>}
          <div className="confirm-actions">
            <button type="button" className="btn btn-ghost" onClick={() => settle(false)}>
              {req.cancelText}
            </button>
            <button
              type="button"
              // Aksi merusak sengaja tidak difokuskan lebih dulu supaya Enter refleks tidak menghapus data.
              autoFocus={req.tone !== "danger"}
              className={`btn ${req.tone === "danger" ? "btn-danger" : "btn-primary"}`}
              onClick={() => settle(true)}
            >
              {req.confirmText}
            </button>
          </div>
        </div>
      )}
    </dialog>
  );
}

/* ---------------- Alert menetap ---------------- */

export function Alert({ type = "error", children, onClose, style }) {
  if (!children) return null;
  const Icon = ICONS[type] || Info;
  return (
    <div className={`alert alert-${type}`} role={type === "error" ? "alert" : "status"} style={style}>
      <Icon size={16} className="alert-icon" />
      <span>{children}</span>
      {onClose && (
        <button type="button" className="alert-close" onClick={onClose} aria-label="Tutup pesan">
          <X size={14} />
        </button>
      )}
    </div>
  );
}
