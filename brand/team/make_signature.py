"""Email signature banner and profile photo for an OIF team member, in the brand's colours and type (brand/README.md).

From a square portrait on a white background, writes into the output directory:
  oif-signature-<slug>-1200x360.png   banner for email signatures (insert it at 600 px wide; sharp on HiDPI screens)
  oif-signature-<slug>-600x180.png    the same at 1x, for clients that do not scale images
  oif-profile-<slug>-512.png          round portrait with the OIF mark as a badge (mail, GitHub, Slack, LinkedIn)

Needs Pillow and network access once for IBM Plex Sans (SIL OFL). Without Python on the host:
  docker run --rm -v "$PWD":/w -w /w python:3.12-slim sh -c "pip -q install pillow && python brand/team/make_signature.py \\
    --portrait brand/team/manmohan-brahma-portrait-512.png --name 'Manmohan Brahma' \\
    --role 'Founder & Chief Token Alchemist' --email manmohan@openinferencefabric.us.ci --out brand/team"
"""
import argparse
import os
import re
import tempfile
import urllib.request

from PIL import Image, ImageDraw, ImageFont

TEAL, SAFFRON, INK, MUTED = (14, 124, 134), (227, 154, 45), (22, 32, 42), (90, 102, 112)
PLEX = "https://github.com/IBM/plex/raw/master/packages/plex-sans/fonts/complete/ttf/"
BRAND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def font(name: str, size: int) -> ImageFont.FreeTypeFont:
    path = os.path.join(tempfile.gettempdir(), name)
    if not os.path.exists(path):
        urllib.request.urlretrieve(PLEX + name, path)
    return ImageFont.truetype(path, size)


def circle(img: Image.Image, d: int, ring: int = 0, ring_col=TEAL) -> Image.Image:
    """Round crop at d px, drawn at 4x and scaled down for a smooth edge, with an optional ring."""
    s = 4
    big = img.convert("RGB").resize((d * s, d * s), Image.LANCZOS)
    mask = Image.new("L", big.size, 0)
    ImageDraw.Draw(mask).ellipse((0, 0, d * s - 1, d * s - 1), fill=255)
    out = Image.new("RGBA", big.size, (0, 0, 0, 0))
    out.paste(big, (0, 0), mask)
    if ring:
        h = ring * s // 2
        ImageDraw.Draw(out).ellipse((h, h, d * s - h, d * s - h), outline=ring_col + (255,), width=ring * s)
    return out.resize((d, d), Image.LANCZOS)


def banner(face: Image.Image, name: str, role: str, email: str, link: str) -> Image.Image:
    w, h = 1200, 360
    b = Image.new("RGB", (w, h), "white")
    d = ImageDraw.Draw(b)
    p = circle(face, 280, ring=8)
    b.paste(p, (40, 40), p)
    x = 370
    d.rectangle((x, 62, x + 8, 160), fill=TEAL)      # the logo's two vendor threads
    d.rectangle((x, 160, x + 8, 236), fill=SAFFRON)
    tx = x + 36
    d.text((tx, 52), name, font=font("IBMPlexSans-SemiBold.ttf", 62), fill=INK)
    d.text((tx, 132), role, font=font("IBMPlexSans-Regular.ttf", 34), fill=TEAL)
    d.text((tx, 186), email, font=font("IBMPlexSans-Regular.ttf", 28), fill=MUTED)
    d.text((tx, 224), link, font=font("IBMPlexSans-Regular.ttf", 28), fill=MUTED)
    logo = Image.open(os.path.join(BRAND, "oif-logo-light-1200x400.png")).convert("RGBA")
    lw = 330
    logo = logo.resize((lw, int(logo.height * lw / logo.width)), Image.LANCZOS)
    b.paste(logo, (w - lw - 30, h - logo.height - 18), logo)
    return b


def profile(face: Image.Image) -> Image.Image:
    sq = Image.new("RGBA", (512, 512), (255, 255, 255, 255))
    p = circle(face, 496, ring=10)
    sq.paste(p, (8, 8), p)
    mark = Image.open(os.path.join(BRAND, "oif-avatar-light-512.png")).convert("RGBA")
    bd = 150
    badge = circle(mark, bd, ring=6, ring_col=(255, 255, 255))
    sq.paste(badge, (512 - bd - 10, 512 - bd - 10), badge)
    return sq.convert("RGB")


def main() -> None:
    a = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    a.add_argument("--portrait", required=True, help="square portrait on white (any format Pillow reads)")
    a.add_argument("--name", required=True)
    a.add_argument("--role", required=True)
    a.add_argument("--email", required=True)
    a.add_argument("--link", default="github.com/openinferencefabric")
    a.add_argument("--out", default=".")
    o = a.parse_args()
    slug = re.sub(r"[^a-z0-9]+", "-", o.name.lower()).strip("-")
    face = Image.open(o.portrait).convert("RGB")
    b = banner(face, o.name, o.role, o.email, o.link)
    b.save(os.path.join(o.out, f"oif-signature-{slug}-1200x360.png"), optimize=True)
    b.resize((600, 180), Image.LANCZOS).save(os.path.join(o.out, f"oif-signature-{slug}-600x180.png"), optimize=True)
    profile(face).save(os.path.join(o.out, f"oif-profile-{slug}-512.png"), optimize=True)
    print(f"wrote oif-signature-{slug}-1200x360.png, -600x180.png and oif-profile-{slug}-512.png to {o.out}")


if __name__ == "__main__":
    main()
