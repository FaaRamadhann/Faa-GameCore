#!/usr/bin/env python3
"""tools/build_dex.py — compile tools/java/FgcPm.java into bin/fgc-pm.dex.

Needs Android SDK (env ANDROID_SDK or C:\\AndroidSDK) with build-tools (d8)
and a platform android.jar (prefers lowest >= 26 for max runtime compat).

Usage:  python tools/build_dex.py
Output: bin/fgc-pm.dex  (shipped inside the module zip)
"""
from __future__ import annotations
import os, pathlib, shutil, subprocess, sys, tempfile

SDK = pathlib.Path(os.environ.get("ANDROID_SDK", r"C:\AndroidSDK"))
MIN_API = 21
JAR_API_PREF = 26  # need AdaptiveIconDrawable (26+); keep lowest available >= 26


def pick_build_tools(sdk: pathlib.Path) -> pathlib.Path:
    bt = sdk / "build-tools"
    cands = sorted([p for p in bt.iterdir() if p.is_dir() and (p / "d8.bat").exists()],
                   key=lambda p: p.name)
    if not cands:
        sys.exit("d8.bat not found under %s" % bt)
    return cands[-1]


def pick_android_jar(sdk: pathlib.Path) -> pathlib.Path:
    plats = []
    for p in (sdk / "platforms").iterdir():
        if not p.is_dir() or not p.name.startswith("android-"):
            continue
        try:
            api = int(p.name.split("-")[1])
        except ValueError:
            continue
        jar = p / "android.jar"
        if jar.exists():
            plats.append((api, jar))
    if not plats:
        sys.exit("no android.jar under %s" % (sdk / "platforms"))
    ok = [(a, j) for a, j in plats if a >= JAR_API_PREF]
    api, jar = min(ok) if ok else min(plats)
    print("android.jar: API %d" % api)
    return jar


def run(cmd, **kw):
    print("+ " + " ".join(str(c) for c in cmd))
    subprocess.run(cmd, check=True, **kw)


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent
    src = root / "tools" / "java" / "FgcPm.java"
    out = root / "bin" / "fgc-pm.dex"
    if not src.exists():
        sys.exit("missing %s" % src)
    javac = shutil.which("javac")
    if not javac:
        sys.exit("javac not on PATH")
    bt = pick_build_tools(SDK)
    jar = pick_android_jar(SDK)
    d8 = str(bt / "d8.bat")
    with tempfile.TemporaryDirectory() as td:
        cls = pathlib.Path(td) / "classes"
        cls.mkdir()
        run([javac, "-source", "8", "-target", "8", "-nowarn",
             "-cp", str(jar), "-d", str(cls), str(src)])
        dexdir = pathlib.Path(td) / "dex"
        dexdir.mkdir()
        run([d8, "--min-api", str(MIN_API), "--lib", str(jar),
             "--output", str(dexdir),
             str(cls / "FgcPm.class")])
        produced = list(dexdir.glob("*.dex"))
        if not produced:
            sys.exit("d8 produced no dex")
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(produced[0].read_bytes())
    print("OK: %s (%.1f KB)" % (out, out.stat().st_size / 1024))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
