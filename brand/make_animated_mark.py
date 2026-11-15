#!/usr/bin/env python3
"""Write the animated OIF mark, "weave to tokens", for light and dark backgrounds.

The story of the mark, played once in about 2.4 s: the two vendors' threads (teal, saffron) drop in, the scheduler's
ink threads weave across them, the crossings lock, and tokens leave the cloth; then the tokens keep flowing.
Pure SVG + CSS, so it plays in a browser, in an <img> tag and on GitHub. With prefers-reduced-motion it shows the
still mark. Run:  python brand/make_animated_mark.py
"""
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
THEMES = {  # README.md colours; the gaps of the weave are the background colour
    "light": {"bg": "#FFFFFF", "teal": "#0E7C86", "saffron": "#E39A2D", "ink": "#16202A"},
    "dark": {"bg": "#121A22", "teal": "#2BA7B1", "saffron": "#F0AE48", "ink": "#E6EBEE"},
}

CSS = """
.a{transform-box:fill-box}
.warp{transform-origin:50% 0;animation:drop .55s cubic-bezier(.2,.8,.2,1) both}
.warp.s{transform-origin:50% 100%;animation-delay:.12s}
.weft{transform-origin:0 50%;animation:weave .6s cubic-bezier(.3,.7,.2,1) .5s both}
.weft.b{animation-delay:.68s}
.cross{transform-origin:50% 50%;animation:lock .3s cubic-bezier(.2,1.6,.4,1) 1.15s both}
.cross.b{animation-delay:1.27s}
.tok{transform-origin:50% 50%;animation:out .45s cubic-bezier(.2,.8,.2,1) both,flow 2.4s ease-in-out infinite}
.t1{animation-delay:1.45s,2.6s}.t2{animation-delay:1.58s,2.8s}.t3{animation-delay:1.71s,3s}
.r2.t1{animation-delay:1.52s,2.7s}.r2.t2{animation-delay:1.65s,2.9s}.r2.t3{animation-delay:1.78s,3.1s}
@keyframes drop{from{transform:scaleY(0)}to{transform:none}}
@keyframes weave{from{transform:scaleX(0)}to{transform:none}}
@keyframes lock{from{transform:scale(.4);opacity:0}to{transform:none;opacity:1}}
@keyframes out{from{transform:translateX(-14px) scale(.3);opacity:0}to{transform:none;opacity:1}}
@keyframes flow{0%,55%,100%{transform:none}25%{transform:translateX(2px) scale(1.14)}}
@media (prefers-reduced-motion:reduce){.a{animation:none!important}}
"""


def svg(c, size=(264, 200), background=True):
    w, h = size
    bg = f'<rect width="132" height="100" fill="{c["bg"]}"/>' if background else ""
    dots = "".join(
        f'<circle class="a tok {row} t{i}" cx="{x}" cy="{y}" r="{r}" fill="{c["ink"]}"/>'
        for row, y in (("r1", 37.5), ("r2", 63.5)) for i, (x, r) in enumerate(((96, 7.5), (113, 5), (125, 3)), 1))
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 132 100" width="{w}" height="{h}" role="img" aria-label="Open Inference Fabric">
<title>Open Inference Fabric</title>
<style>{CSS}</style>
{bg}<rect class="a warp" x="26" y="12" width="15" height="76" rx="7.5" fill="{c["teal"]}"/>
<rect class="a warp s" x="54" y="12" width="15" height="76" rx="7.5" fill="{c["saffron"]}"/>
<g class="a weft"><rect x="8" y="27" width="76" height="21" fill="{c["bg"]}"/><rect x="8" y="30" width="76" height="15" rx="7.5" fill="{c["ink"]}"/></g>
<g class="a weft b"><rect x="8" y="53" width="76" height="21" fill="{c["bg"]}"/><rect x="8" y="56" width="76" height="15" rx="7.5" fill="{c["ink"]}"/></g>
<g class="a cross"><rect x="51" y="29" width="21" height="17" fill="{c["bg"]}"/><rect x="54" y="28" width="15" height="19" fill="{c["saffron"]}"/></g>
<g class="a cross b"><rect x="23" y="55" width="21" height="17" fill="{c["bg"]}"/><rect x="26" y="54" width="15" height="19" fill="{c["teal"]}"/></g>
{dots}
</svg>
"""


for name, colours in THEMES.items():
    out = HERE / f"oif-mark-animated-{name}.svg"
    out.write_text(svg(colours), encoding="utf-8", newline="\n")
    print("wrote", out.name)
