#!/usr/bin/env python3
"""Typographic covers for the demo library. Writes covers-html/<slug>.html and renders ../covers/<slug>.jpg (1200x1200)
with headless Chrome. Only macOS system fonts are used (referenced by PostScript name via local())."""
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HTML_DIR = os.path.join(HERE, "covers-html")
OUT_DIR = os.path.join(HERE, "..", "covers")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

FONTS = {
    "Didot": "Didot", "DidotBold": "Didot-Bold", "DidotItalic": "Didot-Italic",
    "Bodoni": "BodoniSvtyTwoITCTT-Book", "BodoniItalic": "BodoniSvtyTwoITCTT-BookIta", "BodoniBold": "BodoniSvtyTwoITCTT-Bold",
    "FuturaMedium": "Futura-Medium", "FuturaBold": "Futura-Bold", "FuturaCondXB": "Futura-CondensedExtraBold",
    "FuturaCondMedium": "Futura-CondensedMedium",
    "Baskerville": "Baskerville", "BaskervilleItalic": "Baskerville-Italic", "BaskervilleSemi": "Baskerville-SemiBold",
    "BigCaslon": "BigCaslon-Medium",
    "Hoefler": "HoeflerText-Regular", "HoeflerItalic": "HoeflerText-Italic", "HoeflerBlack": "HoeflerText-Black",
    "GillLight": "GillSans-Light", "Gill": "GillSans", "GillSemi": "GillSans-SemiBold",
    "Optima": "Optima-Regular", "OptimaBold": "Optima-Bold",
    "Cochin": "Cochin", "CochinItalic": "Cochin-Italic",
    "Copperplate": "Copperplate", "CopperplateBold": "Copperplate-Bold",
    "Clarendon": "SuperClarendon-Black", "ClarendonBold": "SuperClarendon-Bold",
    "DINCond": "DINCondensed-Bold",
    "AvenirHeavy": "AvenirNext-Heavy", "AvenirDemi": "AvenirNext-DemiBold", "AvenirMedium": "AvenirNext-Medium",
    "AvenirCondDemi": "AvenirNextCondensed-DemiBold", "AvenirCondHeavy": "AvenirNextCondensed-Heavy",
    "Iowan": "IowanOldStyle-Roman", "IowanBold": "IowanOldStyle-Bold", "IowanItalic": "IowanOldStyle-Italic",
    "IowanBoldItalic": "IowanOldStyle-BoldItalic",
}

BASE = """<!doctype html><html><head><meta charset="utf-8"><style>
%s
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:1200px;height:1200px;overflow:hidden}
body{position:relative;-webkit-font-smoothing:antialiased;text-rendering:geometricPrecision}
.abs{position:absolute}
.center{left:0;right:0;text-align:center}
svg{position:absolute;left:0;top:0}
%s
</style></head><body>%s</body></html>"""

FACES = "\n".join(f'@font-face{{font-family:"{alias}";src:local("{ps}")}}' for alias, ps in FONTS.items())

# Paper grain overlay shared by the "printed" covers.
GRAIN = """<svg width="1200" height="1200" style="mix-blend-mode:multiply;opacity:.16"><filter id="g"><feTurbulence type="fractalNoise" baseFrequency=".9" numOctaves="3" stitchTiles="stitch"/><feColorMatrix values="0 0 0 0 .5  0 0 0 0 .45  0 0 0 0 .4  0 0 0 .55 0"/></filter><rect width="1200" height="1200" filter="url(#g)"/></svg>"""


def ticks(cx, cy, r1, r2, count, every=5, r2_major=None, width=3, major_width=6, color="#fff"):
    out = []
    for i in range(count):
        a = 2 * math.pi * i / count
        major = i % every == 0
        inner = r2_major if (major and r2_major) else r2
        x1, y1 = cx + r1 * math.sin(a), cy - r1 * math.cos(a)
        x2, y2 = cx + inner * math.sin(a), cy - inner * math.cos(a)
        out.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="{color}" stroke-width="{major_width if major else width}"/>')
    return "".join(out)


def waves(y0, count, gap, amp, color, opacity_from=0.9, opacity_to=0.25, width=3, wavelength=150):
    out = []
    for i in range(count):
        y = y0 + i * gap
        d = f"M -50 {y}"
        x = -50
        phase = (i % 2) * wavelength / 2
        while x < 1250:
            d += f" q {wavelength / 4} {-amp} {wavelength / 2} 0 t {wavelength / 2} 0"
            x += wavelength
        op = opacity_from + (opacity_to - opacity_from) * i / max(1, count - 1)
        out.append(f'<path d="{d}" transform="translate({-phase} 0)" fill="none" stroke="{color}" stroke-width="{width}" opacity="{op:.2f}"/>')
    return "".join(out)


BAT = "M0 12 C8 2 16 2 22 9 C25 4 28 3 30 6 C32 3 35 4 38 9 C44 2 52 2 60 12 C52 9 48 12 45 17 C41 13 35 14 30 19 C25 14 19 13 15 17 C12 12 8 9 0 12Z"


def bat(x, y, s, rot=0):
    return f'<path d="{BAT}" fill="#120204" transform="translate({x} {y}) rotate({rot}) scale({s})"/>'


COVERS = {}

# --- Jane Austen: three distinct but related "Lantern Classics" moods --------------------------------------------
COVERS["pride-and-prejudice"] = ("""
body{background:#efe5d0}
.frame{position:absolute;inset:54px;border:4px solid #6b1d2a}
.frame2{position:absolute;inset:70px;border:1.5px solid #6b1d2a}
.kicker{top:150px;font:600 30px/1 "Didot";letter-spacing:.5em;color:#6b1d2a;text-indent:.5em}
.t1{top:300px;font:400 230px/1 "Didot";color:#2a1a1c;letter-spacing:-.01em}
.and{top:520px;font:400 110px/1 "DidotItalic";color:#6b1d2a}
.t2{top:640px;font:400 190px/1 "Didot";color:#2a1a1c;letter-spacing:-.02em}
.rule{top:900px;left:430px;width:340px;height:2px;background:#6b1d2a}
.dia{top:892px;left:591px;width:18px;height:18px;background:#efe5d0;border:2px solid #6b1d2a;transform:rotate(45deg)}
.author{top:960px;font:400 46px/1 "Didot";letter-spacing:.42em;text-indent:.42em;color:#6b1d2a}
""", """
<div class="frame"></div><div class="frame2"></div>
<div class="abs center kicker">A NOVEL</div>
<div class="abs center t1">Pride</div>
<div class="abs center and">and</div>
<div class="abs center t2">Prejudice</div>
<div class="abs rule"></div><div class="abs dia"></div>
<div class="abs center author">JANE AUSTEN</div>
""" + GRAIN)

COVERS["emma"] = ("""
body{background:#c8d5c0}
.sun{left:520px;top:150px;width:560px;height:560px;border-radius:50%;background:#d8a943}
.vline{left:150px;top:0;width:2px;height:1200px;background:#2e4a3b;opacity:.5}
.author{left:118px;top:120px;transform-origin:left top;transform:rotate(90deg) translate(0,-100%);font:500 34px/1 "FuturaMedium";letter-spacing:.5em;color:#2e4a3b;white-space:nowrap}
.title{left:180px;top:590px;font:400 385px/1 "BodoniItalic";color:#233a2e;letter-spacing:-.03em}
.sub{left:220px;top:1040px;font:500 28px/1 "FuturaMedium";letter-spacing:.42em;color:#2e4a3b}
""", """
<div class="abs sun"></div><div class="abs vline"></div>
<div class="abs author">JANE AUSTEN</div>
<div class="abs title">Emma</div>
<div class="abs sub">A COMEDY OF MATCHMAKING</div>
""" + GRAIN)

COVERS["persuasion"] = ("""
body{background:#13304e}
.author{top:150px;font:400 34px/1 "Gill";letter-spacing:.55em;text-indent:.55em;color:#d9c7a0}
.title{top:250px;font:400 190px/1 "BaskervilleItalic";color:#f3e8cf}
.line{top:500px;left:560px;width:80px;height:2px;background:#d9c7a0}
.moon{left:540px;top:560px;width:120px;height:120px;border-radius:50%;background:#f3e8cf;opacity:.92}
""", """
<div class="abs center author">JANE AUSTEN</div>
<div class="abs center title">Persuasion</div>
<div class="abs line"></div><div class="abs moon"></div>
<svg width="1200" height="1200">""" + waves(720, 14, 34, 22, "#d9c7a0", .95, .2, 3, 160) + """</svg>
""" + GRAIN)

# --- Horror ---------------------------------------------------------------------------------------------------
COVERS["frankenstein"] = ("""
body{background:#101211}
.t{left:66px;font:400 268px/.82 "FuturaCondXB";letter-spacing:-.01em}
.a{top:150px;color:#d7e85a}
.b{top:640px;color:#ece8de}
.sub{left:76px;top:470px;font:400 44px/1 "BaskervilleItalic";color:#ece8de;opacity:.8}
.author{left:78px;top:1080px;font:400 40px/1 "AvenirCondDemi";letter-spacing:.42em;color:#d7e85a}
.volt{right:80px;top:1066px;font:400 30px/1 "AvenirCondDemi";letter-spacing:.3em;color:#ece8de;opacity:.6}
""", """
<div class="abs t a">FRANKEN</div>
<div class="abs sub">or, The Modern Prometheus</div>
<svg width="1200" height="1200"><line x1="60" y1="595" x2="1140" y2="595" stroke="#d7e85a" stroke-width="5"/>""" +
    "".join(f'<line x1="{x}" y1="575" x2="{x + 10}" y2="615" stroke="#d7e85a" stroke-width="5"/>' for x in range(90, 1140, 60)) + """</svg>
<div class="abs t b">STEIN</div>
<div class="abs author">MARY SHELLEY</div>
<div class="abs volt">1818</div>
""")

COVERS["dracula"] = ("""
body{background:radial-gradient(circle at 50% 38%,#8d1119 0%,#5e0a10 55%,#320306 100%)}
.author{top:84px;font:400 36px/1 "Didot";letter-spacing:.6em;text-indent:.6em;color:#efdcc0}
.title{top:930px;font:700 168px/1 "DidotBold";letter-spacing:.16em;text-indent:.16em;color:#f4e6cf}
.tag{top:1110px;font:400 30px/1 "DidotItalic";color:#efdcc0;opacity:.75}
""", """
<div class="abs center author">BRAM STOKER</div>
<svg width="1200" height="1200">
<path d="M330 880 L330 400 Q330 170 600 150 Q870 170 870 400 L870 880 Z" fill="#0d0203" stroke="#efdcc0" stroke-width="5"/>
<path d="M352 866 L352 404 Q352 192 600 172 Q848 192 848 404 L848 866 Z" fill="none" stroke="#efdcc0" stroke-width="1.5" opacity=".6"/>
<circle cx="600" cy="390" r="120" fill="#f1e2c4"/>
<circle cx="640" cy="372" r="120" fill="#0d0203" opacity=".08"/>
""" + bat(520, 520, 2.2, -8) + bat(690, 470, 1.4, 10) + bat(430, 600, 1.1, -14) + bat(620, 640, 1.6, 4) + bat(740, 700, 0.9, -6) + """
<path d="M330 880 L870 880" stroke="#efdcc0" stroke-width="5"/>
</svg>
<div class="abs center title">DRACULA</div>
<div class="abs center tag">a novel in letters &amp; diaries</div>
""" + GRAIN)

# --- Sea ------------------------------------------------------------------------------------------------------
COVERS["moby-dick"] = ("""
body{background:#f1ebdd}
.title{top:120px;font:400 148px/1 "Clarendon";color:#1b3550;letter-spacing:-.01em}
.sub{top:300px;font:400 46px/1 "BaskervilleItalic";color:#1b3550}
.sea{left:0;top:760px;width:1200px;height:440px;background:#1b3550}
.author{top:1080px;font:400 38px/1 "ClarendonBold";letter-spacing:.38em;text-indent:.38em;color:#f1ebdd}
""", """
<div class="abs center title">MOBY-DICK</div>
<div class="abs center sub">or, The Whale</div>
<div class="abs sea"></div>
<svg width="1200" height="1200">
<path d="M560 790 C566 720 572 668 582 630 C530 618 455 585 380 505 C440 532 512 545 568 566 C586 572 598 584 600 600 C602 584 614 572 632 566 C688 545 760 532 820 505 C745 585 670 618 618 630 C628 668 634 720 640 790 Z" fill="#1b3550"/>
""" + waves(760, 5, 26, 10, "#f1ebdd", .9, .15, 3, 120) + """
</svg>
<div class="abs center author">HERMAN MELVILLE</div>
""" + GRAIN)

# --- Brontës --------------------------------------------------------------------------------------------------
COVERS["jane-eyre"] = ("""
body{background:#3b2838}
.oval{left:280px;top:120px;width:640px;height:820px;border-radius:50%;background:#ece0cd;border:10px solid #c9a66b;box-shadow:0 0 0 14px #3b2838,0 0 0 16px #c9a66b}
.kicker{top:330px;font:400 34px/1 "HoeflerItalic";color:#7b5a6e}
.t1{top:400px;font:400 190px/1 "HoeflerItalic";color:#3b2838}
.t2{top:580px;font:400 190px/1 "HoeflerItalic";color:#3b2838}
.star{top:800px;font:400 40px/1 "Hoefler";color:#c9a66b}
.author{top:1040px;font:400 40px/1 "Optima";letter-spacing:.42em;text-indent:.42em;color:#c9a66b}
""", """
<div class="abs oval"></div>
<div class="abs center kicker">an autobiography</div>
<div class="abs center t1">Jane</div>
<div class="abs center t2">Eyre</div>
<div class="abs center star">&#10022;</div>
<div class="abs center author">CHARLOTTE BRONTË</div>
""" + GRAIN)

COVERS["wuthering-heights"] = ("""
body{background:linear-gradient(#7d8197 0%,#b9aead 45%,#e2c9b0 62%)}
.title{top:120px;font:300 104px/1.08 "GillLight";letter-spacing:.32em;text-indent:.32em;color:#fbf7f1}
.author{top:1090px;font:400 34px/1 "Gill";letter-spacing:.55em;text-indent:.55em;color:#e9e0d6}
""", """
<div class="abs center title">WUTHERING<br>HEIGHTS</div>
<svg width="1200" height="1200">
<circle cx="840" cy="560" r="70" fill="#f4e3c9" opacity=".85"/>
<path d="M0 700 C200 640 360 690 520 650 C700 600 860 660 1200 610 L1200 1200 L0 1200Z" fill="#6c6380"/>
<path d="M0 790 C180 740 420 800 620 740 C800 690 980 760 1200 720 L1200 1200 L0 1200Z" fill="#4f4763"/>
<path d="M760 742 L762 640 M762 690 L730 650 M762 668 L800 630 M761 710 L790 690" stroke="#2c2738" stroke-width="7" stroke-linecap="round" fill="none"/>
<path d="M0 880 C260 840 460 900 700 850 C900 810 1050 860 1200 840 L1200 1200 L0 1200Z" fill="#3a3449"/>
<path d="M0 980 C300 950 520 1000 800 960 C960 940 1100 970 1200 960 L1200 1200 L0 1200Z" fill="#26222f"/>
</svg>
<div class="abs center author">EMILY BRONTË</div>
""")

# --- Dickens / Alcott -----------------------------------------------------------------------------------------
COVERS["great-expectations"] = ("""
body{background:#1e4c4d}
.t1{top:860px;font:700 92px/1 "FuturaBold";letter-spacing:.42em;text-indent:.42em;color:#f2e6cc}
.t2{top:962px;font:500 64px/1 "FuturaMedium";letter-spacing:.3em;text-indent:.3em;color:#e3ab3c}
.author{top:1090px;font:500 30px/1 "FuturaMedium";letter-spacing:.6em;text-indent:.6em;color:#f2e6cc;opacity:.85}
""", """
<svg width="1200" height="1200">
<circle cx="600" cy="420" r="330" fill="#e3ab3c"/>
<circle cx="600" cy="420" r="300" fill="none" stroke="#1e4c4d" stroke-width="3"/>
""" + ticks(600, 420, 290, 272, 60, 5, 240, 3, 9, "#1e4c4d") + """
<line x1="600" y1="420" x2="%.1f" y2="%.1f" stroke="#1e4c4d" stroke-width="14" stroke-linecap="round"/>
<line x1="600" y1="420" x2="%.1f" y2="%.1f" stroke="#1e4c4d" stroke-width="8" stroke-linecap="round"/>
<circle cx="600" cy="420" r="18" fill="#1e4c4d"/>
</svg>
<div class="abs center t1">GREAT</div>
<div class="abs center t2">EXPECTATIONS</div>
<div class="abs center author">CHARLES DICKENS</div>
""" % (600 + 160 * math.sin(math.radians(260)), 420 - 160 * math.cos(math.radians(260)),
       600 + 230 * math.sin(math.radians(240)), 420 - 230 * math.cos(math.radians(240))))

COVERS["little-women"] = ("""
body{background:#f4dcd0}
.title{top:120px;font:400 168px/1 "Cochin";color:#3a2626;letter-spacing:-.01em}
.author{top:330px;font:600 32px/1 "AvenirDemi";letter-spacing:.5em;text-indent:.5em;color:#a5453d}
.names{top:1088px;font:400 34px/1 "CochinItalic";color:#3a2626;word-spacing:.4em}
""", """
<div class="abs center title">Little Women</div>
<div class="abs center author">LOUISA MAY ALCOTT</div>
<svg width="1200" height="1200">
<path d="M140 1040 L140 640 A90 90 0 0 1 320 640 L320 1040Z" fill="#7f9a86"/>
<path d="M370 1040 L370 560 A90 90 0 0 1 550 560 L550 1040Z" fill="#c4544a"/>
<path d="M650 1040 L650 700 A90 90 0 0 1 830 700 L830 1040Z" fill="#6f80a8"/>
<path d="M880 1040 L880 620 A90 90 0 0 1 1060 620 L1060 1040Z" fill="#e0ad48"/>
<line x1="100" y1="1040" x2="1100" y2="1040" stroke="#3a2626" stroke-width="3"/>
</svg>
<div class="abs center names">Meg · Jo · Beth · Amy</div>
""" + GRAIN)

# --- H. G. Wells ----------------------------------------------------------------------------------------------
COVERS["the-time-machine"] = ("""
body{background:#0b1324}
.t{left:90px;font:700 120px/1.02 "FuturaBold";letter-spacing:.1em;color:#ecc66a}
.t1{top:120px;font-size:64px;letter-spacing:.5em;color:#f3ead7}
.t2{top:200px}
.t3{top:325px}
.author{left:96px;top:1080px;font:500 34px/1 "FuturaMedium";letter-spacing:.5em;color:#f3ead7}
.year{right:120px;top:1080px;font:500 30px/1 "FuturaMedium";letter-spacing:.3em;color:#ecc66a}
""", """
<svg width="1200" height="1200">
<g fill="none" stroke="#ecc66a">
<circle cx="760" cy="760" r="380" stroke-width="2" opacity=".35"/>
<circle cx="760" cy="760" r="320" stroke-width="3" opacity=".6"/>
<circle cx="760" cy="760" r="230" stroke-width="10"/>
<circle cx="760" cy="760" r="150" stroke-width="2" opacity=".6"/>
<circle cx="760" cy="760" r="60" stroke-width="6"/>
</g>
""" + ticks(760, 760, 320, 296, 60, 5, 280, 2, 5, "#ecc66a") + """
<line x1="760" y1="760" x2="760" y2="430" stroke="#f3ead7" stroke-width="5"/>
<line x1="760" y1="760" x2="1010" y2="900" stroke="#f3ead7" stroke-width="9" stroke-linecap="round"/>
<circle cx="760" cy="760" r="14" fill="#f3ead7"/>
</svg>
<div class="abs t t1">THE</div>
<div class="abs t t2">TIME</div>
<div class="abs t t3">MACHINE</div>
<div class="abs author">H. G. WELLS</div>
<div class="abs year">AD 802,701</div>
""")

COVERS["the-war-of-the-worlds"] = ("""
body{background:#d8471d}
.t{left:80px;font:400 200px/.86 "DINCond";color:#1a0d08;letter-spacing:.005em}
.t1{top:90px;font-size:110px;color:#f6dfc0}
.t2{top:190px}
.t3{top:360px;font-size:110px;color:#f6dfc0}
.t4{top:460px}
.author{left:84px;top:1092px;font:400 46px/1 "DINCond";letter-spacing:.3em;color:#f6dfc0}
""", """
<div class="abs t t1">THE</div>
<div class="abs t t2">WAR</div>
<div class="abs t t3">OF THE</div>
<div class="abs t t4">WORLDS</div>
<svg width="1200" height="1200">
<circle cx="980" cy="230" r="110" fill="#f6b35c" opacity=".9"/>
<path d="M610 1200 L840 300 L1180 640 L1200 1200Z" fill="#f6dfc0" opacity=".22"/>
<g stroke="#1a0d08" stroke-width="16" stroke-linecap="round" fill="none">
<path d="M820 360 L700 720 L620 1060"/><path d="M880 370 L960 740 L1030 1060"/><path d="M850 380 L860 760 L840 1060"/>
</g>
<path d="M710 330 Q850 190 990 330 Q850 400 710 330Z" fill="#1a0d08"/>
<rect x="760" y="335" width="180" height="40" rx="12" fill="#1a0d08"/>
<circle cx="840" cy="300" r="12" fill="#f6dfc0"/>
<path d="M0 1060 L1200 1060 L1200 1200 L0 1200Z" fill="#1a0d08"/>
</svg>
<div class="abs author">H. G. WELLS</div>
""")


# --- Sherlock Holmes series: shared Victorian label layout, one colour + motif per volume ---------------------------
def holmes(bg, accent, numeral, title_lines, motif):
    title = "".join(f'<div>{line}</div>' for line in title_lines)
    return ("""
body{background:%(bg)s}
.f1{position:absolute;inset:50px;border:3px solid %(ac)s}
.f2{position:absolute;inset:64px;border:1px solid %(ac)s;opacity:.7}
.series{top:128px;font:700 40px/1 "CopperplateBold";letter-spacing:.34em;text-indent:.34em;color:%(ac)s}
.no{left:540px;top:190px;width:120px;height:120px;border-radius:50%%;border:2px solid %(ac)s;font:400 54px/112px "BigCaslon";color:%(ac)s;text-align:center}
.title{top:730px;font:400 104px/1.04 "BigCaslon";color:#f3e9d4}
.author{top:1050px;font:400 36px/1 "Copperplate";letter-spacing:.32em;text-indent:.32em;color:%(ac)s}
""" % {"bg": bg, "ac": accent}, f"""
<div class="f1"></div><div class="f2"></div>
<div class="abs center series">SHERLOCK HOLMES</div>
<div class="abs no">{numeral}</div>
<svg width="1200" height="1200">{motif}</svg>
<div class="abs center title">{title}</div>
<div class="abs center author">ARTHUR CONAN DOYLE</div>
""" + GRAIN)


COVERS["a-study-in-scarlet"] = holmes("#8e1a1d", "#e9c98f", "I", ["A Study", "in Scarlet"], """
<g fill="none" stroke="#e9c98f">
<circle cx="560" cy="500" r="120" stroke-width="16"/><circle cx="560" cy="500" r="96" stroke-width="2" opacity=".6"/>
<line x1="645" y1="585" x2="760" y2="700" stroke-width="30" stroke-linecap="round"/>
</g>""")
COVERS["the-sign-of-the-four"] = holmes("#1f2b55", "#e3c27a", "II", ["The Sign", "of the Four"], "".join(
    f'<g transform="translate({x} {y})" stroke="#e3c27a" stroke-width="12" stroke-linecap="round"><line x1="-42" y1="0" x2="42" y2="0"/><line x1="0" y1="-42" x2="0" y2="42"/></g>'
    for x, y in [(480, 440), (720, 440), (480, 600), (720, 600)]) + '<rect x="420" y="380" width="360" height="280" fill="none" stroke="#e3c27a" stroke-width="2" opacity=".6"/>')
COVERS["the-hound-of-the-baskervilles"] = holmes("#1d3a2c", "#e0b85a", "III", ["The Hound of", "the Baskervilles"], """
<defs><linearGradient id="moor" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#10241a"/><stop offset="1" stop-color="#1d3a2c"/></linearGradient></defs><path d="M64 640 C240 560 420 610 600 560 C780 510 950 580 1136 540 L1136 700 L64 700Z" fill="url(#moor)"/>
<circle cx="540" cy="470" r="22" fill="#f2d36b"/><circle cx="660" cy="470" r="22" fill="#f2d36b"/>
<circle cx="540" cy="470" r="44" fill="#f2d36b" opacity=".18"/><circle cx="660" cy="470" r="44" fill="#f2d36b" opacity=".18"/>
<circle cx="900" cy="410" r="50" fill="#e0b85a" opacity=".85"/>""")

# --- Podcasts -------------------------------------------------------------------------------------------------
COVERS["the-reading-room"] = ("""
body{background:#e4673a}
.t{left:90px;font:400 138px/.95 "AvenirHeavy";color:#fff3e2;letter-spacing:-.02em}
.t1{top:680px}.t2{top:815px}
.kicker{left:96px;top:1080px;font:600 30px/1 "AvenirDemi";letter-spacing:.32em;color:#3b1c12}
.badge{right:90px;top:90px;font:600 28px/1 "AvenirDemi";letter-spacing:.3em;color:#3b1c12}
""", """
<svg width="1200" height="1200">
<g fill="none" stroke="#fff3e2" stroke-width="10" stroke-linecap="round">
""" + "".join(f'<path d="M600 {520 - i * 46} C520 {470 - i * 46} 300 {470 - i * 46} 140 {500 - i * 46}"/><path d="M600 {520 - i * 46} C680 {470 - i * 46} 900 {470 - i * 46} 1060 {500 - i * 46}"/>' for i in range(8)) + """
</g>
<line x1="600" y1="200" x2="600" y2="540" stroke="#3b1c12" stroke-width="10" stroke-linecap="round"/>
</svg>
<div class="abs badge">PODCAST</div>
<div class="abs t t1">THE READING</div>
<div class="abs t t2">ROOM</div>
<div class="abs kicker">CLASSIC BOOKS, CLOSE READING</div>
""")

COVERS["slow-history"] = ("""
body{background:#efe4cf}
.t1{left:90px;top:120px;font:400 250px/1 "IowanBoldItalic";color:#1f4b3e;letter-spacing:-.03em}
.t2{left:96px;top:370px;font:400 132px/1 "Iowan";color:#1f4b3e;letter-spacing:.02em}
.host{left:100px;top:1070px;font:500 32px/1 "AvenirMedium";letter-spacing:.3em;color:#1f4b3e}
""", """
<div class="abs t1">Slow</div>
<div class="abs t2">History</div>
<svg width="1200" height="1200">
<g transform="translate(860 740)">
<path d="M-170 -330 L170 -330 M-170 330 L170 330" stroke="#1f4b3e" stroke-width="18" stroke-linecap="round"/>
<path d="M-140 -320 C-140 -140 -26 -60 -26 0 C-26 60 -140 140 -140 320 L140 320 C140 140 26 60 26 0 C26 -60 140 -140 140 -320Z" fill="none" stroke="#1f4b3e" stroke-width="10"/>
<path d="M-96 -180 L96 -180 C70 -110 20 -60 0 -20 C-20 -60 -70 -110 -96 -180Z" fill="#c7843f"/>
<path d="M0 -20 L0 230" stroke="#c7843f" stroke-width="5" stroke-dasharray="4 14"/>
<path d="M-128 314 C-110 230 -40 200 0 200 C40 200 110 230 128 314Z" fill="#c7843f"/>
</g>
</svg>
<div class="abs host">WITH MARTIN ELLERY</div>
""" + GRAIN)


def render(slug, css, body):
    os.makedirs(HTML_DIR, exist_ok=True)
    os.makedirs(OUT_DIR, exist_ok=True)
    html = os.path.join(HTML_DIR, f"{slug}.html")
    with open(html, "w") as f:
        f.write(BASE % (FACES, css, body))
    png = f"/tmp/cover-{slug}.png"
    subprocess.run([CHROME, "--headless", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                    f"--screenshot={png}", "--window-size=1200,1200", "--virtual-time-budget=2000", f"file://{html}"],
                   check=True, capture_output=True)
    jpg = os.path.join(OUT_DIR, f"{slug}.jpg")
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "90", png, "--out", jpg], check=True,
                   capture_output=True)
    print(jpg)


if __name__ == "__main__":
    only = sys.argv[1:]
    for slug, (css, body) in COVERS.items():
        if not only or slug in only:
            render(slug, css, body)
