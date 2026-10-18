#!/usr/bin/env python3
"""build.py — pack FGC module dir into build/faagamecore-v<version>.zip (forward-slash entries, exec bits)."""
from __future__ import annotations
import argparse, pathlib, re, sys, zipfile

APP_NAME = "faagamecore"
REQUIRED = ["module.prop", "customize.sh", "uninstall.sh", "service.sh", "action.sh",
            "META-INF/com/google/android/update-binary",
            "META-INF/com/google/android/updater-script",
            "system/bin/fgc", "system/bin/fgc-cli", "bin/fgc-pm.dex",
            "config/config.json", "config/gamelist.json",
            "config/blacklist.txt", "config/whitelist.txt",
            "webroot/index.html", "webroot/app.js", "webroot/style.css",
            "webroot/adapters/backend.js"]
EXECUTABLES = {"customize.sh", "uninstall.sh", "service.sh", "action.sh",
               "META-INF/com/google/android/update-binary",
               "system/bin/fgc", "system/bin/fgc-cli"}
# What ships is the module, nothing else. Dev-only trees (tests/tools/docs) and
# build inputs must never reach the zip: they are dead weight on the device and
# the Magisk installer has no use for them.
EXCLUDE_DIRS = {"temp", "tests", "tools", "docs", "build", "__pycache__", ".git",
                ".github", "logs", "state"}
EXCLUDE_FILES = {".DS_Store", "Thumbs.db", ".gitignore", ".gitattributes",
                 "build.py", "README.md"}
EXCLUDE_SUFFIXES = {".pyc", ".pyo", ".zip"}
# Guard: everything under these trees is runtime code and MUST be in the zip.
KEEP_DIRS = ("core", "webroot", "config", "system", "bin", "META-INF")
ROOT = pathlib.Path(__file__).resolve().parent.parent if pathlib.Path(__file__).name == "build.py" and pathlib.Path(__file__).parent.name == "tools" else pathlib.Path(__file__).resolve().parent

def read_version(d):
    try: t = (d / "module.prop").read_text(encoding="utf-8")
    except OSError: return "1.0.0"
    m = re.search(r"^version\s*=\s*(.+?)\s*$", t, re.M)
    return (m.group(1).lstrip("v").strip() if m else "1.0.0") or "1.0.0"

def skip(p, base):
    rel = p.relative_to(base)
    if any(part in EXCLUDE_DIRS for part in rel.parts): return True
    if p.is_file():
        if p.name in EXCLUDE_FILES or p.suffix in EXCLUDE_SUFFIXES: return True
    return False

def mode_of(arc, is_dir):
    """0755 for anything the device executes, 0644 otherwise."""
    if is_dir or arc in EXECUTABLES: return 0o755
    if arc.startswith("core/") and arc.endswith(".sh"): return 0o755
    return 0o644

def build(mod, out):
    missing = [f for f in REQUIRED if not (mod / f).exists()]
    if missing: sys.exit("File wajib hilang: " + ", ".join(missing))
    out = out.resolve()
    files = [p for p in sorted(mod.rglob("*")) if p.resolve() != out and not skip(p, mod)]
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists(): out.unlink()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in files:
            arc = path.relative_to(mod).as_posix()
            zi = zipfile.ZipInfo(filename=arc + ("/" if path.is_dir() else ""))
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = (mode_of(arc, path.is_dir()) << 16) | (0x10 if path.is_dir() else 0)
            zf.writestr(zi, b"" if path.is_dir() else path.read_bytes())
    with zipfile.ZipFile(out) as zf:
        names = set(zf.namelist())
        bad = [n for n in names if "\\" in n]
        if bad: sys.exit("ZIP cacat: %s" % bad[:5])
        # A too-broad exclude must fail the build, not ship a module that boots
        # into "core file missing" on a user's phone.
        lost = [p.relative_to(mod).as_posix() for d in KEEP_DIRS
                for p in (mod / d).rglob("*") if p.is_file()
                and p.relative_to(mod).as_posix() not in names]
        if lost: sys.exit("ZIP kehilangan file runtime: " + ", ".join(lost[:5]))
    return out

def main(argv=None):
    ap = argparse.ArgumentParser(); ap.add_argument("path", nargs="?", default=".")
    ap.add_argument("-o", "--output", default=None); ap.add_argument("--no-version", action="store_true")
    a = ap.parse_args(argv)
    mod = pathlib.Path(a.path).resolve()
    if a.path == ".": mod = pathlib.Path.cwd().resolve()
    outdir = mod / "build"; outdir.mkdir(parents=True, exist_ok=True)
    v = read_version(mod)
    out = outdir / ("%s.zip" % APP_NAME if a.no_version else "%s-v%s.zip" % (APP_NAME, v))
    if a.output: out = outdir / pathlib.Path(a.output).name
    r = build(mod, out)
    print("OK: %s (%.1f KB)" % (r.name, r.stat().st_size / 1024))
    return 0

if __name__ == "__main__": raise SystemExit(main())
