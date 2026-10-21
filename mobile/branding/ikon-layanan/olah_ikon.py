# Bersihkan ikon layanan buatan AI (latar kotak-kotak tercetak, label nama,
# watermark) dan gambar ikon BohCar yang senada. Keluaran: PNG transparan
# 288x288 per layanan.
#   python olah_ikon.py <folder-keluaran>
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SRC = r'C:\Users\USER\OneDrive\Pictures\bohAntar\icon_menu'
OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
UKURAN = 288
ISI = 0.86  # bagian kanvas yang diisi ikon; sisanya ruang napas


def jumlah_beda(im, warna):
    """Selisih |R|+|G|+|B| tiap piksel terhadap satu warna (dipotong di 255)."""
    r, g, b = ImageChops.difference(im, Image.new('RGB', im.size, warna)).split()
    return ImageChops.add(ImageChops.add(r, g), b)


def rentang_ilustrasi(im):
    """Kotak ilustrasi saja: berhenti di celah kosong pertama di bawahnya,
    supaya label nama dan watermark di bawah tidak ikut."""
    tinta = jumlah_beda(im, (255, 255, 255)).point(lambda v: 255 if v > 70 else 0)
    W, H = tinta.size
    mulai, kosong = None, 0
    for y in range(H):
        ada = tinta.crop((0, y, W, y + 1)).getbbox() is not None
        if mulai is None:
            if ada:
                mulai = y
            continue
        kosong = 0 if ada else kosong + 1
        if kosong >= 40:
            akhir = y - kosong
            break
    else:
        akhir = H - 1
    kotak = tinta.crop((0, mulai, W, akhir + 1)).getbbox()
    return (kotak[0], mulai, kotak[2], akhir + 1)


def lambung_cembung(alfa):
    """Mask poligon cembung yang membungkus semua piksel isi (monotone chain)."""
    kecil = alfa.resize((alfa.width // 4, alfa.height // 4), Image.NEAREST)
    px = kecil.load()
    titik = sorted({(x * 4, y * 4) for y in range(kecil.height) for x in range(kecil.width) if px[x, y] > 128})

    def silang(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    bawah, atas = [], []
    for p in titik:
        while len(bawah) >= 2 and silang(bawah[-2], bawah[-1], p) <= 0:
            bawah.pop()
        bawah.append(p)
    for p in reversed(titik):
        while len(atas) >= 2 and silang(atas[-2], atas[-1], p) <= 0:
            atas.pop()
        atas.append(p)
    mask = Image.new('L', alfa.size, 0)
    ImageDraw.Draw(mask).polygon(bawah[:-1] + atas[:-1], fill=255)
    return mask


def buang_latar(potong, ambang, benih=(), cembung_dari=None):
    """Alfa dari flood-fill latar yang tersambung ke tepi. Bagian putih di
    dalam ikon (pin, tutup roda) tidak tersambung, jadi tetap utuh.
    benih: titik tambahan (koordinat potongan) untuk latar yang terkurung,
    mis. lubang pegangan tas. cembung_dari: mulai baris ini siluetnya pasti
    cembung (badan kotak/tas), jadi bagian putih yang ikut terbuang karena
    menyentuh tepi siluet — selotip, label harga — dikembalikan."""
    W, H = potong.size
    kanvas = Image.new('RGB', (W + 8, H + 8), (255, 255, 255))
    kanvas.paste(potong, (4, 4))
    for x, y in [(-4, -4), *benih]:
        ImageDraw.floodfill(kanvas, (x + 4, y + 4), (255, 0, 255), thresh=ambang)
    kanvas = kanvas.crop((4, 4, W + 4, H + 4))
    alfa = jumlah_beda(kanvas, (255, 0, 255)).point(lambda v: 255 if v > 0 else 0)
    if cembung_dari is not None:
        bagian = alfa.copy()
        ImageDraw.Draw(bagian).rectangle((0, 0, W, max(0, cembung_dari)), fill=0)
        alfa = ImageChops.lighter(alfa, lambung_cembung(bagian))
    # Tepi hasil antialias masih bercampur putih: kikis 2 px, lalu lembutkan.
    return alfa.filter(ImageFilter.MinFilter(5)).filter(ImageFilter.GaussianBlur(1.2))


def ke_kotak(rgba):
    """Pangkas ke isi, taruh di tengah kanvas persegi, kecilkan ke UKURAN.
    Diubah dalam mode RGBa (premultiplied) supaya tepinya tidak berpendar putih."""
    kotak = rgba.getchannel('A').point(lambda v: 255 if v > 8 else 0).getbbox()
    rgba = rgba.crop(kotak)
    w, h = rgba.size
    sisi = int(max(w, h) / ISI)
    kanvas = Image.new('RGBa', (sisi, sisi), (0, 0, 0, 0))
    kanvas.paste(rgba.convert('RGBa'), ((sisi - w) // 2, (sisi - h) // 2))
    return kanvas.resize((UKURAN, UKURAN), Image.LANCZOS).convert('RGBA')


def bersihkan(nama, keluar, ambang=60, benih=(), cembung_dari=None):
    """benih dan cembung_dari dalam koordinat gambar sumber 2048 px."""
    im = Image.open(os.path.join(SRC, nama)).convert('RGB')
    x0, y0, x1, y1 = rentang_ilustrasi(im)
    m = 30
    kiri, atas = max(0, x0 - m), max(0, y0 - m)
    potong = im.crop((kiri, atas, min(im.width, x1 + m), min(im.height, y1 + m)))
    rgba = potong.convert('RGBA')
    rgba.putalpha(buang_latar(potong, ambang, [(x - kiri, y - atas) for x, y in benih],
                              None if cembung_dari is None else cembung_dari - atas))
    ke_kotak(rgba).save(os.path.join(OUT, keluar), optimize=True)
    print(keluar, 'dari', nama, 'ilustrasi', (x0, y0, x1, y1))


# ---------- BohCar: digambar, gaya datar seperti ikon BohRide ----------

def poligon_bulat(titik, r, langkah=12):
    """Sudut poligon dibulatkan dengan kurva Bezier kuadrat."""
    hasil = []
    n = len(titik)

    def geser(a, b, jarak):
        dx, dy = b[0] - a[0], b[1] - a[1]
        L = (dx * dx + dy * dy) ** 0.5
        t = min(jarak, L / 2) / L
        return (a[0] + dx * t, a[1] + dy * t)

    for i in range(n):
        p0, p1, p2 = titik[i - 1], titik[i], titik[(i + 1) % n]
        jari = r[i] if isinstance(r, (list, tuple)) else r
        a, b = geser(p1, p0, jari), geser(p1, p2, jari)
        for k in range(langkah + 1):
            t = k / langkah
            hasil.append(((1 - t) ** 2 * a[0] + 2 * (1 - t) * t * p1[0] + t * t * b[0],
                          (1 - t) ** 2 * a[1] + 2 * (1 - t) * t * p1[1] + t * t * b[1]))
    return hasil


def gradasi(ukuran, atas, bawah, y0, y1):
    g = Image.new('RGBA', ukuran)
    d = ImageDraw.Draw(g)
    for y in range(ukuran[1]):
        t = min(1, max(0, (y - y0) / max(1, y1 - y0)))
        d.line([(0, y), (ukuran[0], y)], fill=tuple(int(atas[i] + (bawah[i] - atas[i]) * t) for i in range(3)) + (255,))
    return g


def lukis_mobil():
    S = (1400, 1000)
    im = Image.new('RGBA', S, (0, 0, 0, 0))
    NAVY = (0, 58, 125, 255)
    ABU = (148, 154, 168, 255)
    roda = [(395, 800), (1015, 800)]

    # Garis jalan putus-putus, pola yang sama dengan BohRide.
    d = ImageDraw.Draw(im)
    for xa, xb in [(150, 560), (650, 900), (965, 985), (1040, 1230)]:
        d.rounded_rectangle((xa, 896, xb, 918), radius=11, fill=ABU)

    # Badan: kap pendek di depan (kiri), kabin, bagasi. Lengkung roda dipotong
    # longgar supaya ada celah seperti antara badan dan roda di BohRide.
    badan = poligon_bulat([(165, 840), (165, 660), (240, 600), (480, 572), (620, 372), (985, 372),
                           (1125, 575), (1235, 612), (1235, 840)],
                          [40, 70, 60, 70, 80, 80, 70, 60, 40])
    mask = Image.new('L', S, 0)
    md = ImageDraw.Draw(mask)
    md.polygon(badan, fill=255)
    for cx, cy in roda:
        md.ellipse((cx - 132, cy - 132, cx + 132, cy + 132), fill=0)
    im.paste(gradasi(S, (78, 180, 255), (12, 128, 238), 372, 840), (0, 0), mask)

    # Kaca gelap navy, senada dengan jok BohRide, dengan kilau miring.
    d = ImageDraw.Draw(im)
    kaca_depan = poligon_bulat([(515, 572), (650, 425), (795, 425), (795, 572)], 26)
    kaca_belakang = poligon_bulat([(835, 425), (958, 425), (1065, 572), (835, 572)], 26)
    for kaca in (kaca_depan, kaca_belakang):
        d.polygon(kaca, fill=NAVY)
    kilau = Image.new('L', S, 0)
    ImageDraw.Draw(kilau).polygon([(690, 425), (745, 425), (640, 572), (585, 572)], fill=110)
    ImageDraw.Draw(kilau).polygon([(885, 425), (915, 425), (860, 572), (830, 572)], fill=80)
    potong_kaca = Image.new('L', S, 0)
    ImageDraw.Draw(potong_kaca).polygon(kaca_depan, fill=255)
    ImageDraw.Draw(potong_kaca).polygon(kaca_belakang, fill=255)
    im.paste(Image.new('RGBA', S, (255, 255, 255, 255)), (0, 0), ImageChops.multiply(kilau, potong_kaca))

    # Garis pintu, gagang, spion, lampu depan & belakang.
    d.rounded_rectangle((808, 600, 822, 790), radius=7, fill=(10, 112, 222, 255))
    d.rounded_rectangle((865, 628, 935, 650), radius=11, fill=NAVY)
    d.rounded_rectangle((470, 548, 540, 590), radius=18, fill=NAVY)
    d.rounded_rectangle((170, 662, 262, 704), radius=20, fill=(255, 238, 160, 255))
    d.rounded_rectangle((1206, 636, 1238, 690), radius=12, fill=(255, 112, 104, 255))

    # Roda: ban navy, tutup putih — persis BohRide.
    for cx, cy in roda:
        d.ellipse((cx - 106, cy - 106, cx + 106, cy + 106), fill=NAVY)
        d.ellipse((cx - 46, cy - 46, cx + 46, cy + 46), fill=(255, 255, 255, 255))
    return im


def gambar_mobil(keluar):
    ke_kotak(lukis_mobil()).save(os.path.join(OUT, keluar), optimize=True)
    print(keluar, 'digambar')


# ---------- BohRental: mobil yang sama + kunci di depannya ----------

def lukis_kunci():
    S = (440, 940)
    k = Image.new('RGBA', S, (0, 0, 0, 0))
    d = ImageDraw.Draw(k)
    NAVY = (0, 58, 125, 255)
    # Gantungan, bilah logam bergerigi, lalu remot di atasnya.
    d.ellipse((140, 10, 300, 170), outline=(148, 154, 168, 255), width=30)
    bilah = [(175, 520), (265, 520), (265, 600), (300, 600), (300, 660), (265, 660), (265, 720),
             (300, 720), (300, 790), (265, 790), (265, 880), (220, 925), (175, 880)]
    d.polygon(bilah, fill=(196, 202, 214, 255))
    d.rectangle((205, 540, 222, 880), fill=(160, 168, 182, 255))
    remot = Image.new('L', S, 0)
    ImageDraw.Draw(remot).rounded_rectangle((70, 130, 370, 570), radius=130, fill=255)
    k.paste(Image.new('RGBA', S, NAVY), (0, 0), remot)
    for cy in (270, 420):
        d.ellipse((165, cy - 55, 275, cy + 55), fill=(78, 180, 255, 255))
        d.ellipse((205, cy - 15, 235, cy + 15), fill=(255, 255, 255, 255))
    return k


def gambar_rental(keluar):
    S = (1500, 1180)
    im = Image.new('RGBA', S, (0, 0, 0, 0))
    im.alpha_composite(lukis_mobil().resize((1120, 800), Image.LANCZOS), (0, 0))
    kunci = lukis_kunci().rotate(-38, expand=True, resample=Image.BICUBIC)
    pos = (S[0] - kunci.width, S[1] - kunci.height)
    # Celah bening di sekeliling kunci, bukan garis putih: ubinnya bisa gelap.
    celah = Image.new('L', S, 0)
    celah.paste(kunci.split()[3].filter(ImageFilter.MaxFilter(41)), pos)
    im.putalpha(ImageChops.subtract(im.split()[3], celah))
    im.alpha_composite(kunci, pos)
    ke_kotak(im).save(os.path.join(OUT, keluar), optimize=True)
    print(keluar, 'digambar')


bersihkan('bohRide.png', 'layanan_bohride.png')
gambar_mobil('layanan_bohcar.png')
gambar_rental('layanan_bohrental.png')
bersihkan('bohFood.png', 'layanan_bohfood.png')
bersihkan('bohAntar.png', 'layanan_bohsend.png', cembung_dari=0)  # kotak + pin: arahan user, untuk BohSend
# Pendar biru di bawah tas ikut dibuang (ambang lebih longgar); lubang di dalam
# pegangan adalah latar yang terkurung, jadi diberi benih sendiri — yang lalu
# merambat lewat tali putih ke label harga, jadi badan tas (di bawah tepi
# atasnya, y 745) dikembalikan utuh.
bersihkan('bohMart.png', 'layanan_bohmart.png', ambang=110, benih=[(1020, 660)], cembung_dari=745)
bersihkan('lainnya.png', 'layanan_lainnya.png')
