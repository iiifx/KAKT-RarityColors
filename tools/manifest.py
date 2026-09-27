#!/usr/bin/env python3
"""Generates installer/manifest.txt: the list of mod files with their SHA-256 hashes.

    python3 tools/manifest.py --originals "/path/to/unmodified/game/files"

Header lines come from installer/mod.txt. Every file tracked by git that is part of the
mod is listed (commit or `git add` new mod files first); files under Optional/<Component>/ belong to that optional component and are
installed without the Optional/<Component>/ prefix.
"""
import argparse, hashlib, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOT_MOD = {"README.md", "LICENSE", ".gitignore", ".gitattributes", "install.sh", "uninstall.sh",
           "install.bat", "uninstall.bat"}
NOT_MOD_DIRS = {".git", ".github", "tools", "tests", "installer"}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def mod_files():
    # only files tracked by git, so stray local files never end up in the game
    tracked = subprocess.run(["git", "-C", ROOT, "ls-files", "-z"], check=True,
                             stdout=subprocess.PIPE).stdout.decode("utf-8").split("\0")
    for path in sorted(p for p in tracked if p):
        if path in NOT_MOD or path.split("/")[0] in NOT_MOD_DIRS:
            continue
        yield path


def main():
    ap = argparse.ArgumentParser(description="Generate installer/manifest.txt")
    ap.add_argument("--originals", required=True, help="folder with the unmodified game files")
    args = ap.parse_args()
    lines = [l.rstrip("\n") for l in open(os.path.join(ROOT, "installer", "mod.txt"), encoding="utf-8") if l.strip()]
    n = 0
    for src in mod_files():
        parts = src.split("/")
        if parts[0] == "Optional":
            component, target = parts[1], "/".join(parts[2:])
        else:
            component, target = "core", src
        original = os.path.join(args.originals, target)
        vanilla = sha256(original) if os.path.isfile(original) else "-"
        if vanilla == "-":
            print("warning: no original for %s; the installer will treat it as a new file" % target)
        if "\t" in src or " " in component:
            sys.exit("unsupported file name: " + src)
        lines.append("\t".join(["file", component, src, target, vanilla, sha256(os.path.join(ROOT, src))]))
        n += 1
    with open(os.path.join(ROOT, "installer", "manifest.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("manifest: %d files" % n)


if __name__ == "__main__":
    main()
