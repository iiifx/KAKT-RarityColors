#!/usr/bin/env python3
"""Builds the KAKT-RarityColors mod files from the original game files.

Requirements: Python 3, numpy, Pillow and ImageMagick (the `convert` command).

Examples:
    # build the mod into a separate folder
    python3 build.py --game "/path/to/King Arthur Knight's Tale" --out build

    # same layout as the repository: prefixes go to Optional/TierPrefixes
    python3 build.py --game "/path/to/King Arthur Knight's Tale" --out . \\
        --prefix-out Optional/TierPrefixes

The source files must be the unmodified game files. Use --originals to read them from a
backup when the game folder already has the mod installed.
"""
import argparse, glob, os, re, struct, subprocess, sys, tempfile
import numpy as np
from PIL import Image

PALETTE = {"C": (136, 136, 255), "U": (255, 255, 119), "R": (175, 96, 37)}
STYLE_KEYS = {"C": "CommonColor", "U": "UncommonColor", "R": "RelicColor"}
VANILLA_COMMON_COLOR = "ffa3cd71"
NAME = {"C": "common", "U": "uncommon", "R": "relic"}
# hue windows (degrees) of the original rarity colour
WINDOW = {"C": (45, 160), "U": (180, 265), "R": (5, 55)}
TARGET_HUE = {"C": 240, "U": 60, "R": 18}
# saturation and value multipliers applied to recoloured pixels
ADJUST = {"C": (1.0, 1.15), "U": (0.95, 1.35), "R": (1.4, 1.05)}
PREFIX_RE = re.compile(r"\[T[0123EL]\] ")


def rgb2hsv(a):
    a = a / 255.0
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    mx = a.max(-1); mn = a.min(-1); d = mx - mn
    h = np.zeros_like(mx); m = d > 1e-6
    rc = (mx == r) & m; gc = (mx == g) & m & ~rc; bc = m & ~rc & ~gc
    h[rc] = ((g - b)[rc] / d[rc]) % 6
    h[gc] = ((b - r)[gc] / d[gc]) + 2
    h[bc] = ((r - g)[bc] / d[bc]) + 4
    return h / 6, np.where(mx > 0, d / np.maximum(mx, 1e-6), 0), mx


def hsv2rgb(h, s, v):
    i = np.floor(h * 6) % 6; f = h * 6 - np.floor(h * 6)
    p = v * (1 - s); q = v * (1 - f * s); t = v * (1 - (1 - f) * s)
    out = np.zeros(h.shape + (3,))
    for k, (R, G_, B_) in enumerate([(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)]):
        m = i == k
        out[m, 0] = R[m]; out[m, 1] = G_[m]; out[m, 2] = B_[m]
    return (out * 255).clip(0, 255)


def hue_window(h, s, rarity):
    lo, hi = WINDOW[rarity]
    deg = h * 360
    soft = 12.0
    w = np.clip((deg - (lo - soft)) / soft, 0, 1) * np.clip(((hi + soft) - deg) / soft, 0, 1)
    return w * np.clip((s - 0.08) / 0.15, 0, 1)


def recolor(rgb, rarity, weight):
    h, s, v = rgb2hsv(rgb)
    target = TARGET_HUE[rarity] / 360.0
    d = ((target - h + 0.5) % 1) - 0.5
    ks, kv = ADJUST[rarity]
    h2 = (h + d * weight) % 1
    s2 = s * (1 + (ks - 1) * weight)
    v2 = v * (1 + (kv - 1) * weight)
    return hsv2rgb(h2, np.clip(s2, 0, 1), np.clip(v2, 0, 1))


def dds_info(path):
    d = open(path, "rb").read(128)
    return d[84:88].decode(), struct.unpack("<I", d[28:32])[0]


def save_dds(img, like, out):
    fourcc, mips = dds_info(like)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
        img.save(tmp.name)
    subprocess.run(["convert", tmp.name, "-define", "dds:compression=" + fourcc.lower(),
                    "-define", "dds:mipmaps=%d" % max(mips - 1, 0), out], check=True)
    os.unlink(tmp.name)
    assert dds_info(out)[0] == fourcc, (out, fourcc)


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w", encoding="utf-8", newline="").write(text)


def build_styles(src, out):
    rel = "Cfg/GUI/Styles.xml"
    t = open(os.path.join(src, rel), encoding="utf-8", newline="").read()
    if VANILLA_COMMON_COLOR not in t:
        sys.exit("%s is not the original file; point --originals to unmodified game files" % rel)
    for r, key in STYLE_KEYS.items():
        t, k = re.subn(r'(<%s Type="string" Value=")[0-9a-fA-F]{8}(")' % key,
                       r"\g<1>ff%02x%02x%02x\2" % PALETTE[r], t)
        assert k == 1, key
    write_text(os.path.join(out, rel), t)
    print("styles: 3")


def build_backgrounds(src, out):
    n = 0
    for pat in ("UI/Inventory/ItemPopup/Itempopup_%s_bg.dds", "UI/BattleUI/LootPopup/Lootpopup_bg_%s.dds"):
        for r in "CUR":
            rel = pat % NAME[r]
            a = np.array(Image.open(os.path.join(src, rel)).convert("RGBA")).astype(float)
            h, s, _ = rgb2hsv(a[..., :3])
            rgb = recolor(a[..., :3], r, hue_window(h, s, r))
            img = Image.fromarray(np.dstack([rgb, a[..., 3]]).astype(np.uint8), "RGBA")
            save_dds(img, os.path.join(src, rel), os.path.join(out, rel))
            n += 1
    print("backgrounds:", n)


def build_icons(src, out):
    folder = os.path.join(src, "UI/Items")
    files = sorted(f for f in os.listdir(folder) if re.search(r"_[CUR]_[1-6]\.dds$", f))
    load = lambda f: np.array(Image.open(os.path.join(folder, f)).convert("RGB")).astype(float)
    # all icons of one rarity (and one group) share a background texture:
    # the per-pixel median over those icons reconstructs it
    group = lambda f: ("_Base" in f, re.search(r"_([CUR])_[1-6]\.dds$", f).group(1))
    ref = {}
    for key in set(map(group, files)):
        ref[key] = np.median(np.stack([load(f) for f in files if group(f) == key]), 0)
    for f in files:
        fam, rarity, tier = re.match(r"(.*)_([CUR])_([1-6])\.dds$", f).groups()
        me = load(f)
        h, s, _ = rgb2hsv(me)
        r0 = ref[group(f)]
        bg = np.clip((35 - np.abs(me - r0).sum(-1)) / 20.0, 0, 1)
        # shadows cast on the background: same colour direction as the reference, only darker
        n_me = np.linalg.norm(me, axis=-1); n_r0 = np.linalg.norm(r0, axis=-1)
        cos = (me * r0).sum(-1) / np.maximum(n_me * n_r0, 1e-6)
        shadow = np.clip((cos - 0.985) / 0.01, 0, 1) * (n_me <= n_r0 * 1.05)
        bg = np.maximum(bg, shadow)
        runes = np.zeros(me.shape[:2])
        if "_Base" in fam:
            # same object art in every rarity, only runes and background differ
            for other in "CUR":
                o = "%s_%s_%s.dds" % (fam, other, tier)
                if other != rarity and os.path.exists(os.path.join(folder, o)):
                    runes = np.maximum(runes, np.abs(me - load(o)).sum(-1))
            runes = np.clip(runes / 40.0, 0, 1) * hue_window(h, s, rarity)
        weight = np.maximum(bg, runes)
        img = Image.fromarray(recolor(me, rarity, weight).astype(np.uint8), "RGB")
        save_dds(img, os.path.join(folder, f), os.path.join(out, "UI/Items", f))
    print("icons:", len(files))


def item_tiers(game):
    # 0 basic (hand-made items.cfg gear), 1 common, 2 uncommon, 3 relic, E endgame season relic, L lar
    res = {}
    for cfg in ("generatedItems.cfg", "items.cfg"):
        t = open(os.path.join(game, "Cfg/Items", cfg), encoding="utf-8-sig", errors="replace").read()
        for name, body in re.findall(r"^(\w+)\s*\n\{(.*?)^\}", t, re.S | re.M):
            get = lambda k: (re.search(r"^\s*" + k + r"=(.*?)\s*$", body, re.M) or [None, None])[1]
            key = (get("NameID") or "").split(".", 1)[-1].lower()
            rarity = (get("Rarity") or "").lower()
            if name.startswith("EGS1_"):
                tier = "E"
            elif rarity == "relic":
                tier = "3"
            elif rarity == "uncommon":
                tier = "2"
            elif (get("ItemType") or "").lower() == "lar":
                tier = "L"
            elif cfg == "generatedItems.cfg":
                tier = "1"
            else:
                tier = "0"
            if key:
                res[key] = tier
    return res


def build_prefixes(game, src, out, langs):
    tiers = item_tiers(game)
    total = {}
    langs = langs or sorted(os.listdir(os.path.join(src, "Strings")))
    for lang in langs:
        for path in sorted(glob.glob(os.path.join(src, "Strings", lang, "Langs", "Lang_ItemNames*.xml"))):
            t = open(path, encoding="utf-8", newline="").read()
            if PREFIX_RE.search(t):
                sys.exit("%s already has tier prefixes; point --originals to unmodified game files" % path)

            def sub(m):
                tier = tiers.get(m.group(1).lower())
                if not tier:
                    return m.group(0)
                total[tier] = total.get(tier, 0) + 1
                return "<%s>%s%s[T%s] %s%s" % (m.group(1), m.group(2) or "", m.group(3), tier, m.group(5), m.group(6))
            # the name may come before or after an optional <desc> block
            t = re.sub(r"<([\w.]+)>(\s*<desc>.*?</desc>)?(\s*<(\w+)>)([^<]*)(</\4>(?:\s*<desc>.*?</desc>)?\s*</\1>)",
                       sub, t, flags=re.S)
            write_text(os.path.join(out, os.path.relpath(path, src)), t)
    print("prefixes:", dict(sorted(total.items())))


def main():
    ap = argparse.ArgumentParser(description="Build the KAKT-RarityColors mod files.")
    ap.add_argument("--game", required=True, help="game folder (item data is read from here)")
    ap.add_argument("--originals", help="folder with the unmodified files to recolour (default: --game)")
    ap.add_argument("--out", required=True, help="output folder for the colour files")
    ap.add_argument("--prefix-out", help="output folder for the tier prefixes (default: --out)")
    ap.add_argument("--langs", help="comma-separated language folders for prefixes (default: all)")
    ap.add_argument("--no-colours", action="store_true", help="skip the colour files")
    ap.add_argument("--no-prefixes", action="store_true", help="skip the tier prefixes")
    args = ap.parse_args()
    src = args.originals or args.game
    if not args.no_colours:
        build_styles(src, args.out)
        build_backgrounds(src, args.out)
        build_icons(src, args.out)
    if not args.no_prefixes:
        langs = args.langs.split(",") if args.langs else None
        build_prefixes(args.game, src, args.prefix_out or args.out, langs)


if __name__ == "__main__":
    main()
