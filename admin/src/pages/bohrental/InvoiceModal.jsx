import { useState, useEffect } from "react";
import { Download, Share2, X } from "lucide-react";
import { toast } from "../../components/Feedback";
import { invoiceBlob } from "./invoiceImage";
import { invoiceCaption, openWhatsApp } from "./invoice";

/*
 * Pratinjau invoice PNG dengan dua tombol: Unduh dan Bagikan.
 * Bagikan memakai Web Share API — satu ketukan, lalu penyewa memilih sendiri
 * WhatsApp, Telegram, Instagram, atau email dari lembar berbagi bawaan sistem.
 * Kalau perangkatnya tidak mendukung (umumnya browser desktop), gambarnya
 * diunduh dan chat WhatsApp dibuka supaya tinggal dilampirkan.
 */
export default function InvoiceModal({ data, onClose }) {
  const [url, setUrl] = useState("");
  const [blob, setBlob] = useState(null);
  const [sharing, setSharing] = useState(false);

  useEffect(() => {
    if (!data) return;
    let alive = true;
    let objectUrl = "";
    invoiceBlob(data)
      .then((b) => {
        if (!alive || !b) return;
        objectUrl = URL.createObjectURL(b);
        setBlob(b);
        setUrl(objectUrl);
      })
      .catch(() => alive && toast.error("Gagal membuat gambar invoice"));
    return () => {
      alive = false;
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [data]);

  if (!data) return null;

  const namaFile = `Invoice-${data.id}.png`;

  const unduh = () => {
    if (!url) return;
    const a = document.createElement("a");
    a.href = url;
    a.download = namaFile;
    a.click();
    toast.success("Invoice tersimpan di folder unduhan");
  };

  const bagikan = async () => {
    if (!blob) return;
    const caption = invoiceCaption(data);
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
    openWhatsApp(data.customerPhone, caption);
    toast.info("Perangkat ini belum mendukung berbagi gambar langsung — invoice sudah diunduh, tinggal lampirkan di chat WhatsApp yang terbuka", 8000);
  };

  return (
    <div className="invoice-overlay" onClick={onClose}>
      <div className="invoice-sheet" onClick={(e) => e.stopPropagation()}>
        <div className="invoice-sheet-head">
          <div>
            <strong>Invoice Sewa</strong>
            <span>No. {data.id} · {data.customerName || "Penyewa"}</span>
          </div>
          <button type="button" className="invoice-close" onClick={onClose} aria-label="Tutup invoice">
            <X size={18} />
          </button>
        </div>

        <div className="invoice-preview">
          {url
            ? <img src={url} alt={`Invoice ${data.id}`} />
            : <div className="invoice-loading"><span className="spinner" /><p>Menyiapkan invoice…</p></div>}
        </div>

        <div className="invoice-sheet-actions">
          <button type="button" className="btn btn-ghost" onClick={unduh} disabled={!url}>
            <Download size={16} /> Unduh Gambar
          </button>
          <button type="button" className="btn btn-primary" onClick={bagikan} disabled={!blob || sharing}>
            <Share2 size={16} /> {sharing ? "Membuka…" : "Bagikan"}
          </button>
        </div>
      </div>
    </div>
  );
}
