#!/usr/bin/env python3
"""Builds the archman GRUB theme (assets/grub/archman): GRUB's menu, shown
next to Windows (phases/chroot.sh's configure_grub_menu), as one of the
installer's screens at 1920x1080 (config.sh's GRUB_MENU_GFXMODE), where
the console has the 12x22 font: the logo and tagline on top, a title, the
entries as the installer's menu (lib/prompt.sh's: a block centred, the
current entry black on the accent) and its key hint under them, and the
countdown.

Everything is drawn with the patched 12x22 console font, as on the
console: logo.png from logo-hd.txt, and archman-22.pf2, GRUB's font,
made by grub-mkfont from a BDF copy of it. The colours and tagline come
from config.sh (CONSOLE_PALETTE, TAGLINE), in the roles lib/ui.sh gives
them.

Run it again after changing the logo, the fonts, the palette or the
tagline (after tools/make-console-fonts.py); it needs grub (grub-mkfont).
The output is committed:
  tools/make-grub-theme.py
"""
import importlib.util
import pathlib
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True   # no __pycache__ from importing the other tools

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "grub" / "archman"


def tool(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fonts = tool("fonts", "make-console-fonts.py")
sddm = tool("sddm", "make-sddm-theme.py")   # its png, render and config

FONT = "sun12x22"
FONT_NAME = "ARCHMAN Regular 22"
LAYOUT_WIDTH = 79          # lib/ui.sh's: the logo's width, in cells
# The entries grub-mkconfig writes next to Windows, the widest setting the
# menu's: GRUB_DISTRIBUTOR's, the Windows one (/etc/grub.d/15_windows) and
# the firmware's.
ENTRIES = ("ARCHMAN Linux", "Advanced options for ARCHMAN Linux", "Windows", "UEFI Firmware Settings")
MENU_ROWS = len(ENTRIES)
TITLE = "Choose what to start"
HINT = "↑↓ choose · Enter start"
COUNTDOWN = "Starting ARCHMAN in %d s"


def bdf(font, path):
    """The font as a BDF, every character it maps but the private ones (the
    logo's cells and the like, which only the console draws), its baseline
    under the capital O."""
    w, h = font["width"], font["height"]
    descent = h - 1 - fonts.cap_rows(font)[1]
    chars = {}
    for glyph, entry in zip(font["glyphs"], font["table"]):
        for char in fonts.chars_of(entry):
            if not 0xE000 <= ord(char) <= 0xF8FF:
                chars.setdefault(ord(char), glyph)
    # At 72 dpi, so its size in points is its height in pixels, the size
    # grub-mkfont asks FreeType for.
    lines = ["STARTFONT 2.1", f"FONT -archman-ARCHMAN-Regular-R-Normal--{h}-{h * 10}-72-72-C-{w * 10}-ISO10646-1",
             f"SIZE {h} 72 72", f"FONTBOUNDINGBOX {w} {h} 0 {-descent}",
             "STARTPROPERTIES 7", 'FAMILY_NAME "ARCHMAN"', 'WEIGHT_NAME "Regular"', f"PIXEL_SIZE {h}",
             "RESOLUTION_X 72", "RESOLUTION_Y 72",
             f"FONT_ASCENT {h - descent}", f"FONT_DESCENT {descent}", "ENDPROPERTIES",
             f"CHARS {len(chars)}"]
    row_bytes = (w + 7) // 8
    for code, glyph in sorted(chars.items()):
        lines += [f"STARTCHAR U+{code:04X}", f"ENCODING {code}", f"SWIDTH {w * 1000 // h} 0", f"DWIDTH {w} 0",
                  f"BBX {w} {h} 0 {-descent}", "BITMAP"]
        lines += [glyph[y * row_bytes:(y + 1) * row_bytes].hex().upper() for y in range(h)]
        lines.append("ENDCHAR")
    lines.append("ENDFONT")
    path.write_text("\n".join(lines) + "\n")


def main():
    font = fonts.load(fonts.OUT / f"{FONT}.psfu.gz")
    w, h = font["width"], font["height"]
    palette = sddm.config("${CONSOLE_PALETTE[*]}").split()
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.iterdir():
        old.unlink()

    logo = (ROOT / "assets" / "logo" / "logo-hd.txt").read_text().rstrip("\n").split("\n")
    colours = (ROOT / "assets" / "logo" / "logo-hd.colors").read_text().rstrip("\n").split("\n")
    sddm.png(OUT / "logo.png", sddm.render(font, logo, colours, palette))
    # The current entry's box: the accent, stretched across it.
    sddm.png(OUT / "select_c.png", [[palette[6]]])

    with tempfile.TemporaryDirectory() as tmp:
        source = pathlib.Path(tmp) / f"{FONT}.bdf"
        bdf(font, source)
        subprocess.run(["grub-mkfont", "-s", str(h), "-n", FONT_NAME, "-o", OUT / "archman-22.pf2", source], check=True)

    # The rows of lib/ui.sh's header: two blank, the logo, a blank, the
    # tagline, a blank, the progress bar's (blank before the steps), a
    # blank, the title, two blank; then the menu, a blank, its hint.
    logo_top = 2
    tagline = logo_top + len(logo) + 1
    title = tagline + 4
    menu = title + 3
    hint = menu + MENU_ROWS + 1
    countdown = hint + 2
    # lib/prompt.sh's menu: the widest entry and a space each side, centred.
    menu_cols = max(map(len, ENTRIES)) + 2
    logo_px = LAYOUT_WIDTH * w

    def label(row, text, colour, ident=None):
        ident = f'\n  id = "{ident}"' if ident else ""
        return f"""+ label {{{ident}
  left = 0
  top = {row * h}
  width = 100%
  height = {h}
  align = "center"
  font = "{FONT_NAME}"
  color = "#{colour}"
  text = "{text}"
}}
"""

    # The roles lib/ui.sh gives the palette's slots: 0 background, 6 the
    # selected item's box, 7 the list's items, 8 hints, 13 the tagline,
    # 15 text.
    (OUT / "theme.txt").write_text(f"""# The archman GRUB theme, made by tools/make-grub-theme.py: one of the
# installer's screens at 1920x1080, in its {w}x{h} font.
title-text: ""
desktop-color: "#{palette[0]}"
terminal-font: "{FONT_NAME}"

+ image {{
  left = 50%-{logo_px // 2}
  top = {logo_top * h}
  file = "logo.png"
}}

{label(tagline, sddm.config("$TAGLINE"), palette[13])}
{label(title, TITLE, palette[15])}
+ boot_menu {{
  left = 50%-{menu_cols * w // 2}
  top = {menu * h}
  width = {menu_cols * w}
  height = {MENU_ROWS * h}
  item_font = "{FONT_NAME}"
  selected_item_font = "{FONT_NAME}"
  item_color = "#{palette[7]}"
  selected_item_color = "#{palette[0]}"
  item_height = {h}
  item_padding = 0
  item_spacing = 0
  icon_width = 0
  icon_height = 0
  item_icon_space = {w}
  selected_item_pixmap_style = "select_*.png"
  scrollbar = false
}}

{label(hint, HINT, palette[8])}
{label(countdown, COUNTDOWN, palette[7], "__timeout__")}""")
    print(f"{OUT.relative_to(ROOT)}: theme.txt, logo.png, select_c.png, archman-22.pf2")


if __name__ == "__main__":
    main()
