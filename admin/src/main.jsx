import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import "./index.css"
import App from "./App.jsx"
import { Toaster, ConfirmHost } from "./components/Feedback.jsx"

// Toaster & ConfirmHost dipasang di luar App supaya tetap hidup di kedua cabang
// rute (sudah login / belum login) dan tidak ikut ter-unmount saat portal berganti.
createRoot(document.getElementById("root")).render(
  <StrictMode>
    <App />
    <Toaster />
    <ConfirmHost />
  </StrictMode>
)
