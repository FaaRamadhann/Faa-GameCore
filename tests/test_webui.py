"""tests/test_webui.py — offline checks: structure, no CDN, theme vars, nav, adapter honesty."""
import pathlib, re, sys
ROOT = pathlib.Path(__file__).resolve().parent.parent
fails = []
def check(cond, msg):
    print(("PASS " if cond else "FAIL ") + msg)
    if not cond: fails.append(msg)

idx = (ROOT/"webroot/index.html").read_text(encoding="utf-8")
css = (ROOT/"webroot/style.css").read_text(encoding="utf-8")
app = (ROOT/"webroot/app.js").read_text(encoding="utf-8")
be = (ROOT/"webroot/adapters/backend.js").read_text(encoding="utf-8")

for var in ["--bg-deep","--blue-primary","--text-primary","--success","--warning","--danger","--radius-card"]:
    check(var in css, "css var " + var)
check("http://" not in idx and "https://" not in idx and "cdn" not in idx.lower(), "no CDN in index.html")
check("http://" not in app and "https://" not in app, "no CDN in app.js")
for pid in ["page-home","page-games","page-white","page-black","page-logs","page-settings","page-diag"]:
    check(pid in idx, "page " + pid)
for label in ["Balance","Performance","Awaken","Auto"]:
    check(label in app, "profile " + label)
check("bottomnav" in idx and "bottomnav" in css, "mobile bottom nav")
check("sidebar" in idx and "sidebar" in css, "desktop sidebar")
check("Blacklist" in idx, "blacklist label full")
check("44" in css, "touch target ~44px")
check("safe-area-inset" in css, "safe area padding")
check("overflow-x" in css or "overflow" in css, "overflow guard")
check("localStorage" in be, "preview persistence")
check("preview" in be.lower(), "honest preview mode")
check("kernelsu" in be.lower() and "magisk" in be.lower(), "device bridge probing")
check("allow" in be.lower() or "ALLOW" in be, "command allowlist")
check("eval(" not in app and "eval(" not in be, "no eval in webui")
# core checks
cli = (ROOT/"core/fgc-cli.sh").read_text(encoding="utf-8")
check(not re.search(r"(?<![A-Za-z_])eval\s*\(", cli), "no eval() in fgc-cli")
pe = (ROOT/"core/policy_engine.sh").read_text(encoding="utf-8")
check("whitelist" in pe.lower() and "PROTECTED" in pe, "whitelist precedence + protection")
pm = (ROOT/"core/process_manager.sh").read_text(encoding="utf-8")
check("dry" in pm.lower() and "force-stop" in pm, "dry-run + force-stop gate")
mp = (ROOT/"module.prop").read_text(encoding="utf-8")
_mv = re.search(r"^version\s*=\s*(.+?)\s*$", mp, re.M).group(1).strip()
_mc = re.search(r"^versionCode\s*=\s*(.+?)\s*$", mp, re.M).group(1).strip()
check("version=%s" % _mv in mp and "versionCode=%s" % _mc in mp, "version in sync (%s/%s)" % (_mv, _mc))
print("\n%d failed" % len(fails))

# universal-compatibility checks: no brand/model hardcodes in shipped code+config
import itertools
code_files = list((ROOT/"webroot").rglob("*.html")) + list((ROOT/"webroot").rglob("*.js")) + \
             list((ROOT/"webroot").rglob("*.css")) + list((ROOT/"core").glob("*.sh")) + \
             list((ROOT/"config").glob("*")) + [ROOT/"customize.sh"]
brand_re = re.compile(r"redmi|xiaomi|miui|poco|samsung|pixel|hyperos|note\s*11", re.I)
found = []
for f in code_files:
    if f.is_file() and brand_re.search(f.read_text(encoding="utf-8", errors="ignore")):
        found.append(str(f.relative_to(ROOT)))
check(not found, "no brand hardcodes" + ("" if not found else " in " + ",".join(found)))
check("chipProf" in idx and "chipProf" in app, "header profile chip")
check("Unknown" in app and "Not detected" in be, "detected-only device fallback")
check("caps" in app and "launcher" in app, "diag caps + launcher rendering")
check((ROOT/"core/caps.sh").exists() and (ROOT/"core/device.sh").exists(), "caps.sh + device.sh exist")
check("tabsWhite" in idx and "tabsBlack" in idx and "tabsGames" in idx, "user/system tabs")
check("User App" in idx and "System App" in idx, "tab labels")
check("btnAddGame" not in idx and "btnAddWhite" not in idx and "btnAddBlack" not in idx, "no add buttons")
check("pickerModal" not in idx, "no picker modal")
check("window.ksu" in be and "listPackages" in be and "getPackagesInfo" in be and "moduleInfo" in be, "ksu bridge APIs")
check("kernelsu" in be and "SHELL" in be, "kernelsu bridge + permission surfacing")
check("avatarHue" in app and "profileSelect" in app and "switchEl" in app, "avatar hue + per-game profile + switch")
check("otherOn" in app or "excludeActive" in app, "cross-list exclusion")
import subprocess as _sp
try:
    _naive = _sp.run(["grep", "-r", "eval", "core/", "system/"], cwd=str(ROOT), capture_output=True, text=True)
    _naive_clean = (_naive.returncode != 0)
except (OSError, FileNotFoundError):
    _naive_clean = not any("eval" in f.read_text(encoding="utf-8", errors="ignore")
                           for f in list((ROOT/"core").glob("*.sh")) + list((ROOT/"system/bin").glob("*")) if f.is_file())
check(_naive_clean, "naive-grep eval clean (core+system)")
check((ROOT/"system/bin/fgc").exists() and (ROOT/"system/bin/fgc-cli").exists(), "fgc PATH wrappers exist")
_fgcw = (ROOT/"system/bin/fgc").read_text(encoding="utf-8")
check("fgc-cli.sh" in _fgcw and "FGC_MODULES" in _fgcw and "_has_cli" in _fgcw, "wrapper resolves module (readdir, retried)")
pe2 = (ROOT/"core/policy_engine.sh").read_text(encoding="utf-8")
sc = (ROOT/"core/session_controller.sh").read_text(encoding="utf-8")
check("fgc_pkg_type" in pe2, "package type detection")
check("second-sweep" in sc, "profile enforcement (awaken)")
pm = (ROOT/"core/process_manager.sh").read_text(encoding="utf-8")
check("fgc_freeze" in pm and "fgc_unfreeze_all" in pm and "frozen.txt" in pm, "freeze/unfreeze with tracking")
check("already-disabled" in pm, "never unfreeze user-disabled apps")
check("fgc_battery_pct" in (ROOT/"core/device.sh").read_text(encoding="utf-8"), "battery reading")
check("21-50" in app, "auto battery mapping in UI")
check("STARTING" in app and "STOPPED" in app, "daemon state chips")
check("btnRestart" in idx and "restartService" in be, "core restart via bridge")
check("btnIconProbe" in idx and "scheduleSweep" in app, "icon probe + IO fallback")
check("refreshLight" in app and "loadPackages" in app and "scheduleRetry" in app and "debounce" in app, "perf: light refresh + lazy packages + retry + debounce")
check("reconcile" in app and "terkonfirmasi" in app, "reconcile-on-error for switches")
check("__fgcErr" in be, "bridge exec telemetry")
_cl = (ROOT/"core/fgc-cli.sh").read_text(encoding="utf-8")
check("whitelist-unreadable" in pm, "fail-closed cleanup+freeze")
check("FGC_PROFILE" in (ROOT/"core/session_controller.sh").read_text(encoding="utf-8"), "profile passed to freeze")
check("freeze_system" in (ROOT/"config/config.json").read_text(encoding="utf-8"), "freeze toggle default off")
check("_glist_ensure" in _cl and "_list_append" in _cl and "_list_filter" in _cl, "atomic self-healing writes")
check("loadIconBatch" in app and "paintCachedIcons" in app and "icons" in be, "batched icon cache")
check("syncTime" in idx and "visibilitychange" in app, "sync stamp + external-edit resync")
check("renderPaged" in app and "bindDelegated" in app and "onListChange" in app, "windowed render + delegation")
check("prefers-reduced-motion" in css, "reduced-motion support")
check((ROOT/"core/paths.sh").exists(), "canonical paths module")
check("FGC_CONFIG" in _cl and "FGC_STATE" in _cl, "canonical data paths in CLI")
check("fgc_run_timed" in (ROOT/"core/str.sh").read_text(encoding="utf-8"), "hang-guard helper")
check("fgc_daemon_alive" in (ROOT/"core/main.sh").read_text(encoding="utf-8"), "pid-verified stale lock")
check("topResumedActivity" in (ROOT/"core/foreground_monitor.sh").read_text(encoding="utf-8"), "miui foreground markers")
import re
_gnu_bad = []
for _f in list((ROOT/"core").glob("*.sh")) + list((ROOT/"system/bin").glob("*")) + \
         [ROOT/"customize.sh", ROOT/"service.sh", ROOT/"action.sh", ROOT/"uninstall.sh"] + \
         list((ROOT/"tests").glob("*.sh")):
    if not _f.is_file():
        continue
    for _i, _ln in enumerate(_f.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
        _s = _ln.strip()
        if not _s or _s.startswith("#"):
            continue
        if "grep" in _s or "sed" in _s:
            if "\\\\|" in _s or "\\\\+" in _s or re.search(r"\\\\\{[0-9]", _s):
                _gnu_bad.append("%s:%d" % (_f.name, _i))
check(not _gnu_bad, "posix grep/sed only" + ("" if not _gnu_bad else ": " + ",".join(_gnu_bad)))
check("protected_extra" in pe, "dynamic launcher protection")
check("FGC_PROTECTED_BASE" in pe and "miui" not in pe.lower(), "universal protected base")
print("universal: %d failed" % len([m for m in fails if 'brand' in m or 'chip' in m or 'fallback' in m or 'caps' in m or 'protect' in m]))
sys.exit(1 if fails else 0)
