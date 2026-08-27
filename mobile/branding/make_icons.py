"""Membuat aset ikon & splash dari assets/images/logo.png.

Jalankan dari folder `mobile/`:

    python branding/make_icons.py
    dart run flutter_launcher_icons
    dart run flutter_native_splash:create

Berkas di folder ini sengaja di luar `assets/` supaya tidak ikut dibungkus ke
dalam APK — ini bahan build, bukan gambar yang dibaca aplikasi saat berjalan.

logo.png adalah wordmark 3:1. Dipakai apa adanya sebagai ikon peluncur ia jadi
sesobek tipis di tengah kotak, jadi lambangnya (jempol + pin) dipotong terpisah.
Wordmark utuh tetap dipakai untuk splash, tempat rasio lebar memang cocok.
"""

import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "assets", "images", "logo.png")

img = Image.open(SRC).convert("RGBA")
print("sumber:", img.size)

# Lambang berada di sepertiga kiri, sebelum huruf "b". 30% lebar aman.
mark = img.crop((0, 0, int(img.width * 0.30), img.height))
mark = mark.crop(mark.getchannel("A").getbbox())

# Jadikan persegi dengan menambah ruang kosong, bukan meregangkan.
side = max(mark.size)
square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
square.paste(mark, ((side - mark.width) // 2, (side - mark.height) // 2), mark)


def write(name, scale, background, canvas=1024):
    """Lambang di tengah kanvas persegi, menempati `scale` bagian dari sisinya."""
    target = int(canvas * scale)
    art = square.resize((target, target), Image.LANCZOS)
    out = Image.new("RGBA", (canvas, canvas), background)
    off = (canvas - target) // 2
    out.paste(art, (off, off), art)
    path = os.path.join(HERE, name)
    out.save(path)
    print("tulis:", name, out.size)


# Tiap slot memangkas dengan aturan berbeda, jadi tiga ukuran:
#
# - adaptive: flutter_launcher_icons masih membungkusnya dengan inset 16%, jadi
#   0.75 di sini berakhir ~51% dari kanvas 108dp — masih di dalam zona aman 61%
#   tapi mengisi ~76% lingkaran yang terlihat. Kalau disamakan dengan splash,
#   lambangnya mengambang kekecilan di laci aplikasi.
# - splash: ikon splash Android 12 dimasker ke lingkaran 768px dari kanvas
#   1152px, jadi isi wajib di bawah 66% atau tepinya terpotong.
# - icon: ikon lawas & iOS tidak dimasker dan tidak boleh transparan.
write("logo_icon_adaptive.png", 0.75, (0, 0, 0, 0))
write("logo_icon_splash.png", 0.60, (0, 0, 0, 0), canvas=1152)
write("logo_icon.png", 0.78, (255, 255, 255, 255))

# Wordmark untuk splash. flutter_native_splash memperlakukan berkas sumber
# sebagai aset 4x, jadi logo.png yang 2172px berarti 543dp — lebih lebar dari
# layar HP mana pun dan terpotong di kiri-kanan. 800px = 200dp, muat di layar
# tersempit sekalipun.
SPLASH_WIDTH = 800
wide = img.crop(img.getchannel("A").getbbox())
wide = wide.resize(
    (SPLASH_WIDTH, round(wide.height * SPLASH_WIDTH / wide.width)), Image.LANCZOS
)
wide.save(os.path.join(HERE, "logo_splash.png"))
print("tulis: logo_splash.png", wide.size)
