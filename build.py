#!/usr/bin/env python3
"""build.py — pack FGC module dir into build/faagamecore-v<version>.zip (forward-slash entries, exec bits)."""
from __future__ import annotations
import argparse, pathlib, re, sys, zipfile

APP_NAME = "faagamecore"
REQUIRED = ["module.prop", "customize.sh", "uninstall.sh", "service.sh", "action.sh",
            "META-INF/com/google/android/update-binary",
            "META-INF/com/google/android/updater-script",
            "system/bin/fgc", "system/bin/fgc-cli", "build.py",
            "core/main.sh", "core/fgc-cli.sh", "core/caps.sh", "core/device.sh",
            "core/str.sh", "core/data_init.sh", "webroot/index.html"]
EXECUTABLES = {"customize.sh", "uninstall.sh", "service.sh", "action.sh",
               "META-INF/com/google/android/update-binary",
               "system/bin/fgc", "system/bin/fgc-cli",
               "core/main.sh", "core/fgc-cli.sh", "core/caps.sh", "core/device.sh",
               "core/event_detector.sh",
               "core/foreground_monitor.sh", "core/session_controller.sh",
               "core/policy_engine.sh", "core/process_manager.sh",
               "core/config_manager.sh", "core/logger.sh", "core/recovery.sh",
               "tools/version.sh"}
EXCLUDE_DIRS = {"temp", "__pycache__", ".git", "build", "tests/__pycache__"}
EXCLUDE_FILES = {".DS_Store", "Thumbs.db"}
EXCLUDE_SUFFIXES = {".pyc", ".pyo", ".zip"}
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
            zi.external_attr = ((0o755 if (path.is_dir() or arc in EXECUTABLES) else 0o644) << 16) | (0x10 if path.is_dir() else 0)
            zf.writestr(zi, b"" if path.is_dir() else path.read_bytes())
    with zipfile.ZipFile(out) as zf:
        bad = [n for n in zf.namelist() if "\\" in n]
        if bad: sys.exit("ZIP cacat: %s" % bad[:5])
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
