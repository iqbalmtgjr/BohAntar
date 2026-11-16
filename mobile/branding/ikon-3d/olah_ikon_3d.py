"""Ikon 3D rancangan user (Stitch, 16 Nov 2026) -> aset aplikasi.

Sumber: C:/Users/USER/OneDrive/Pictures/bohAntar/stitch_bohantar_ui_redesign
Semua sumber RGB berlatar putih (bukan transparan). Latar yang tersambung ke
tepi gambar diubah jadi transparan dengan "color to alpha" terhadap putih:
bayangan abu-abu di bawah benda tetap ada sebagai bayangan hitam tembus
pandang, jadi ikonnya juga rapi di mode gelap. Bagian putih DI DALAM benda
(kertas papan klip, label harga) tidak tersentuh karena tidak tersambung ke tepi.

Jalankan dari mana saja (tanpa python -I tidak masalah): python olah_ikon_3d.py
"""
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SUMBER = Path(r"C:/Users/USER/OneDrive/Pictures/bohAntar/stitch_bohantar_ui_redesign")
TUJUAN = Path(__file__).resolve().parents[2] / "assets" / "images"
UKURAN = 288  # sama dengan ikon layanan lama
AMBANG = 246  # latar = hampir putih murni; lebih rendah = putih benda ikut bocor

IKON = {
    "layanan_bohride.png": "3d_glossy_clay_render_icon_of_a_scooter_delivery_vehicle_in_exact_bohantar",
    "layanan_bohcar.png": "3d_glossy_clay_render_icon_of_a_delivery_car_van_vehicle_in_exact_bohantar",
    "layanan_bohfood.png": "3d_glossy_clay_render_icon_of_a_food_delivery_bowl_or_takeout_package_with",
    "layanan_bohsend.png": "3d_glossy_clay_render_icon_of_a_courier_delivery_parcel_box_with_secure_ribbon",
    "layanan_bohrental.png": "3d_glossy_clay_render_icon_of_car_keys_and_remote_key_fob_or_car_rental_symbol",
    "layanan_lainnya.png": "3d_glossy_clay_render_icon_of_an_app_grid_or_more_menu_button_with_rounded_dots",
    "nav_beranda.png": "3d_glossy_clay_render_app_icon_of_a_cozy_house_home_building_symbol_for_bottom",
    "nav_aktivitas.png": "3d_glossy_clay_render_app_icon_of_an_order_receipt_document_or_activity",
    "nav_chat.png": "3d_glossy_clay_render_app_icon_of_a_chat_bubble_speech_message_balloon_with",
    "nav_akun.png": "3d_glossy_clay_render_app_icon_of_a_user_profile_avatar_person_bust_symbol_in",
    "promo_tag.png": "3d_glossy_clay_render_app_icon_of_a_discount_promo_shopping_coupon_tag_with",
}


def buang_latar(im: Image.Image) -> Image.Image:
    im = im.convert("RGB")
    w, h = im.size
    r, g, b = im.split()
    mn = ImageChops.darker(ImageChops.darker(r, g), b)
    mx = ImageChops.lighter(ImageChops.lighter(r, g), b)
    sat = ImageChops.subtract(mx, mn)
    # Calon latar: terang dan hampir tanpa warna (putih + bayangan abu-abu).
    calon = ImageChops.multiply(mn.point(lambda v: 255 if v >= AMBANG else 0), sat.point(lambda v: 255 if v <= 8 else 0))
    # Hanya yang tersambung ke tepi gambar.
    for x in range(0, w, 8):
        for y in (0, h - 1):
            if calon.getpixel((x, y)) == 255:
                ImageDraw.floodfill(calon, (x, y), 128)
    for y in range(0, h, 8):
        for x in (0, w - 1):
            if calon.getpixel((x, y)) == 255:
                ImageDraw.floodfill(calon, (x, y), 128)
    latar = calon.point(lambda v: 255 if v == 128 else 0)

    hasil = []
    for (pr, pg, pb), m in zip(im.get_flattened_data(), latar.get_flattened_data()):
        if not m:
            hasil.append((pr, pg, pb, 255))
            continue
        a = 255 - min(pr, pg, pb)  # color to alpha terhadap putih
        if a == 0:
            hasil.append((0, 0, 0, 0))
            continue
        hasil.append(tuple(max(0, 255 - (255 - c) * 255 // a) for c in (pr, pg, pb)) + (a,))
    out = Image.new("RGBA", im.size)
    out.putdata(hasil)
    # Kikis 2 px tepi benda: piksel anti-alias di batasnya bercampur putih latar
    # dan tampak sebagai garis putih tipis di atas banner biru / mode gelap.
    out.putalpha(out.getchannel("A").filter(ImageFilter.MinFilter(5)))
    return out


def bingkai(im: Image.Image) -> Image.Image:
    # Potong ke benda (abaikan bayangan yang sangat tipis), jadikan persegi.
    kotak = im.getchannel("A").point(lambda v: 255 if v > 24 else 0).getbbox()
    im = im.crop(kotak)
    sisi = int(max(im.size) * 1.04)
    kanvas = Image.new("RGBA", (sisi, sisi), (0, 0, 0, 0))
    kanvas.paste(im, ((sisi - im.width) // 2, (sisi - im.height) // 2))
    return kanvas.resize((UKURAN, UKURAN), Image.LANCZOS)


if __name__ == "__main__":
    for nama, folder in IKON.items():
        bingkai(buang_latar(Image.open(SUMBER / folder / "screen.png"))).save(TUJUAN / nama, optimize=True)
        print("ok", nama)
