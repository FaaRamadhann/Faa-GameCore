"""tests/test_build.py — the zip ships the module and nothing else."""
import pathlib, re, subprocess, sys, zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
fails, total = [], [0]
def check(cond, msg):
    total[0] += 1
    print(("PASS " if cond else "FAIL ") + msg)
    if not cond: fails.append(msg)

r = subprocess.run([sys.executable, "build.py"], cwd=ROOT, capture_output=True, text=True)
check(r.returncode == 0, "build.py succeeds" + ("" if r.returncode == 0 else ": " + r.stderr.strip()))
# Validate the zip for THIS version. Globbing picks whatever build sits in
# build/ first and silently passes an obsolete artefact after a version bump.
want = re.search(r"^version\s*=\s*(.+?)\s*$", (ROOT / "module.prop").read_text(encoding="utf-8"), re.M).group(1).strip()
zip_path = ROOT / "build" / ("faagamecore-v%s.zip" % want)
check(zip_path.exists(), "zip for module.prop version " + want)
if not zip_path.exists(): sys.exit(1)

zf = zipfile.ZipFile(zip_path)
names = set(zf.namelist())
files = {n for n in names if not n.endswith("/")}

# Dev-only trees and build inputs: dead weight on the device.
for bad in ["tests/", "tools/", "docs/", "temp/", "build/", ".git", "logs/", "state/"]:
    check(not any(n.startswith(bad) for n in names), "no " + bad + " in zip")
for bad in [".gitignore", ".gitattributes", "build.py", "README.md"]:
    check(bad not in files, "no " + bad + " in zip")

# Every runtime file in the repo must be in the zip, with the right mode.
for d in ("core", "webroot", "config", "system", "bin", "META-INF"):
    for p in (ROOT / d).rglob("*"):
        if p.is_file():
            rel = p.relative_to(ROOT).as_posix()
            check(rel in files, "shipped " + rel)
for n in sorted(files):
    if n.startswith("core/") and n.endswith(".sh"):
        check((zf.getinfo(n).external_attr >> 16) & 0o777 == 0o755, "exec bit " + n)
check(not any("\\" in n for n in names), "forward-slash entries only")
for n in ["module.prop", "customize.sh", "service.sh", "uninstall.sh", "action.sh"]:
    check(n in files, "installer file " + n)
print("--- %d pass, %d fail ---" % (total[0] - len(fails), len(fails)))
sys.exit(1 if fails else 0)
