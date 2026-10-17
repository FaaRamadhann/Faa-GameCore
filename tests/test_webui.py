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
# Every CLI call the adapter makes must be in the allowlist. A missing entry is
# not a security failure but a silent dead button (v1.2.5: "clear log" did
# nothing because `clearlog` was never added to ALLOW).
_allow = set(re.findall(r'"?([A-Za-z-]+)"?:\s*1', re.search(r"var ALLOW = \{(.*?)\};", be, re.S).group(1)))
_called = set(re.findall(r'_run\("([a-z-]+)', be))
check(_called <= _allow, "allowlist covers adapter calls" + ("" if _called <= _allow else " missing " + ",".join(sorted(_called - _allow))))
check("eval(" not in app and "eval(" not in be, "no eval in webui")
# App labels are FREE TEXT from the package manager ("Picsart AI Photo Editor,
# Video (PicsArt)", "Clean & Boost", "Faa's Game"). The adapter used to build
# the CLI command by concatenation, so "(" killed the shell and the add failed
# with the WebUI reporting an unstable backend. Prove the quoting helper turns
# every such label back into exactly ONE shell argument (round-trip via bash).
import subprocess, shutil, json, os
_qm = re.search(r"function q\(s\) \{(.*?)\n  \}", be, re.S)
check(bool(_qm), "shell-quoting helper present")
if _qm:
    _node = shutil.which("node")
    _bash = shutil.which("bash") or r"C:\Program Files\Git\bin\bash.exe"
    if not _node or not os.path.exists(_bash):
        print("SKIP shell quoting (node/bash unavailable)")
    else:
        _labels = ["Plain", "Picsart AI Photo Editor, Video (PicsArt)", "Clean & Boost",
                   "Faa's Game", 'He said "hi"', "$HOME", "back\\slash", "a;b|c>d", "tab\there"]
        _ok = True
        for _lab in _labels:
            _src = "function q(s){" + _qm.group(1) + "}\nprocess.stdout.write(q(" + json.dumps(_lab) + "));"
            _quoted = subprocess.run([_node, "-e", _src], capture_output=True, text=True).stdout
            _back = subprocess.run([_bash, "-c", "printf '%s' " + _quoted],
                                   capture_output=True, text=True).stdout
            if _back != _lab:
                _ok = False
                print("  quoting round-trip failed for %r -> %r" % (_lab, _back))
        check(_ok, "shell quoting survives metachar labels")
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
# v1.3.0: the native Kitsune/Magisk/KernelSU bridge answers exec(cmd) with
# ShellUtils.fastCmd = LAST LINE ONLY, which silently truncated gamelist JSON,
# the whitelist/blacklist reads and 7 of every 8 icons. Multi-line reads must go
# through exec(cmd, cbName); the probe falls back honestly when it is missing.
check("nativeBridge" in be and "exec(cmd, id)" in be and "ShellUtils" in be,
      "full-output bridge (exec with callback) instead of last-line fastCmd")
check("br.degraded" in be and "degraded: false" in be, "1-line bridge reported as degraded")
check("__fgcExec" in be and "__fgcProbe" in be, "callback exec + one-shot capability probe")
check("(1-line bridge)" in app, "diagnostics shows a degraded bridge")
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
check("ln -s" not in (ROOT/"core/data_init.sh").read_text(encoding="utf-8"), "no symlinks in storage")
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
# v1.2.4: config-faithful list rendering, honest pm toggling, read-only SELinux report
# v1.2.9 tried "the page IS the file" (members only) and that hid the whole app
# list, which users read as "my apps are gone". v1.3.0 restores the full universe:
# configured entries ON, everything else OFF to add, and the type tab filters
# EVERY row (members included) so "User App" / "System App" really differ.
check("return inTab(r.pkg, state.tabGames) && matchTerm(r, term)" in app
      and "return inTab(r.pkg, cfg[4]) && matchTerm(r, term)" in app
      and "Full app list, always" in app,
      "full app list rendered, type tab filters every row")
check("Cari / tambah" in idx, "search-to-add hint")
_caps_src = (ROOT/"core/caps.sh").read_text(encoding="utf-8")
check("fgc_selinux_mode" in _caps_src and "getenforce" in _caps_src, "selinux mode detected (read-only)")
check("SELinux" in app, "selinux shown in diagnostics")
_sel_bad = []
for _f in code_files:
    if not _f.is_file():
        continue
    for _i, _ln in enumerate(_f.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
        _s = _ln.strip()
        if not _s or _s.startswith("#"):
            continue
        if "setenforce" in _s:
            _sel_bad.append("%s:%d" % (_f.name, _i))
check(not _sel_bad, "never forces SELinux permissive" + ("" if not _sel_bad else ": " + ",".join(_sel_bad)))
check("fgc_pkg_disabled" in pm, "live-state verification helper present")
check("still-disabled-after-cmd" in pm and "not-disabled-after-cmd" in pm, "failed toggles never reported as success")
check(">/dev/null 2>&1" in pm, "pm/am chatter silenced (CLI stays valid JSON)")
# v1.2.5: mksh portability — a bare '|' inside ${...} is PATTERN ALTERNATION on
# Android's /system/bin/sh (a #/% strip then silently returns the string
# unchanged, e.g. ${v#GAME|} -> "GAME|com.x"). bash tolerates it, so this class
# of bug MUST be caught statically; the bash test run can never see it.
_msh_bad = []
for _f in list((ROOT/"core").glob("*.sh")) + list((ROOT/"system/bin").glob("*")) + \
         [ROOT/"customize.sh", ROOT/"service.sh", ROOT/"action.sh", ROOT/"uninstall.sh"]:
    if not _f.is_file():
        continue
    for _i, _ln in enumerate(_f.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
        _s = _ln.strip()
        if not _s or _s.startswith("#"):
            continue
        if re.search(r"\$\{[^}]*\|", _s):
            _msh_bad.append("%s:%d" % (_f.name, _i))
check(not _msh_bad, "mksh-safe ${...} expansions" + ("" if not _msh_bad else ": " + ",".join(_msh_bad)))
# v1.2.5: clear-log feature across CLI + adapter + UI, honest (file verified empty)
check("cmd_clearlog" in _cl and "clearlog" in _cl, "clear-log CLI command")
check("DeviceBackend.prototype.clearLog" in be, "clear-log adapter method")
check("LocalBackend.prototype.clearLog" in be, "clear-log preview parity")
check("btnClearLog" in idx and "btnClearLog" in app and "backend.clearLog" in app, "clear-log UI wired")
# v1.2.6: readable file formats (pretty config.json + gamelist.json), icon batch,
# plus the three field reports: "lists show no apps", "icons show letters
# sometimes", "updating reset my config".
gl = (ROOT/"core/gamelist.sh").read_text(encoding="utf-8")
check("fgc_glist_pretty" in gl and "fgc_glist_dump" in gl and "fgc_glist_write" in gl and "fgc_glist_profile" in gl, "gamelist format has one home")
check("fgc_glist_write" in _cl and "python3" not in _cl, "gamelist writes are pure shell (no python on device)")
check("fgc_pkg_ok" in gl and "fgc_pkg_ok" in _cl, "package validation shared, not duplicated")
_cm = (ROOT/"core/config_manager.sh").read_text(encoding="utf-8")
check("fgc_cfg_pretty" in _cm and "fgc_cfg_normalize" in _cm, "config pretty writer + data-preserving normaliser")
check("fgc_cfg_normalize" in (ROOT/"core/recovery.sh").read_text(encoding="utf-8"), "config normalised to pretty at boot")
check("kept-as-is" in (ROOT/"core/data_init.sh").read_text(encoding="utf-8"), "migrate never overwrites user config")
_cf_txt = (ROOT/"config/config.json").read_text(encoding="utf-8")
check('{\n    "enabled": ' in _cf_txt and '"auto_profile_rules": {\n' in _cf_txt, "shipped config.json is pretty (4-space)")
check((ROOT/"config/gamelist.json").read_text(encoding="utf-8") == '{"games": []}\n', "shipped gamelist.json empty form")
check("version: p[3] || \"\"" in be, "list packages parses the versionCode column")
check("ICON_BATCH" in app and "backend.icons(tokens)" in app and "requeueLater" in app, "icons resolved one exec per chunk (not per row)")
check("pkg[=ver]" in _cl and "(=[A-Za-z0-9._]*)?" in be, "pkg=ver tokens reach the batch helper")
check("backend.icon(target, (state.pkgVers" in app and "state.pkgVers[p]" in app, "icon requests are version aware")
# v1.2.9: prefer the host's native icon scheme (WebUI X serves ksu://icon/<pkg>)
# and keep the CLI base64 batch as the fallback for hosts without it.
check('"ksu://icon/"' in be and "this.iconSrc" in be, "native icon scheme used when the host provides it")
check("backend.iconSrc" in app and 'img.dataset.native' in app and "queueIcon(img)" in app, "native icon falls back to the CLI batch once")
check("cfg_games" in _cl and "cfg_white" in _cl and "(core) &nbsp;vs&nbsp;" in app, "diagnostics compares core config counts with the UI")
print("universal: %d failed" % len([m for m in fails if 'brand' in m or 'chip' in m or 'fallback' in m or 'caps' in m or 'protect' in m]))
sys.exit(1 if fails else 0)
