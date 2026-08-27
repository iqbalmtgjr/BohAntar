import { useState, useEffect } from "react";
import { Sun, Moon } from "lucide-react";

/* Tombol ganti mode terang/gelap.
   Sumber kebenarannya atribut data-theme di <html> + localStorage "admin_theme",
   sama seperti yang dipakai Topbar Super Admin, jadi pilihannya konsisten
   di seluruh aplikasi. */
export default function ThemeToggle({ size = 18, className = "" }) {
  const [theme, setTheme] = useState(
    () => document.documentElement.getAttribute("data-theme") || "dark"
  );

  useEffect(() => {
    const observer = new MutationObserver(() => {
      setTheme(document.documentElement.getAttribute("data-theme") || "dark");
    });
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    return () => observer.disconnect();
  }, []);

  const toggle = () => {
    const next = theme === "dark" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    localStorage.setItem("admin_theme", next);
    setTheme(next);
  };

  return (
    <button
      onClick={toggle}
      className={className}
      aria-label={theme === "dark" ? "Ganti ke mode terang" : "Ganti ke mode gelap"}
      title={theme === "dark" ? "Mode terang" : "Mode gelap"}
      style={{
        background: "none",
        border: "none",
        cursor: "pointer",
        color: "var(--text-secondary)",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        padding: 8,
        borderRadius: "50%"
      }}
    >
      {theme === "dark" ? <Sun size={size} /> : <Moon size={size} />}
    </button>
  );
}
