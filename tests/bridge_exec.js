/* node tests/bridge_exec.js — regression for the Kitsune/Magisk/KernelSU bridge.
 *
 * The native WebView interface answers exec(cmd) with ShellUtils.fastCmd, which
 * returns ONLY THE LAST LINE of stdout. That silently truncated gamelist JSON,
 * the whitelist/blacklist reads and 7 of every 8 icons. The full-output form is
 * exec(cmd, cbName), where the host calls cbName(code, stdout, stderr).
 *
 * This test fakes both forms and asserts the adapter returns the FULL output.
 */
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const src = fs.readFileSync(path.join(__dirname, "..", "webroot", "adapters", "backend.js"), "utf8");

let fails = 0;
function check(cond, msg) {
  console.log((cond ? "PASS " : "FAIL ") + msg);
  if (!cond) fails++;
}

const GAMELIST = '{\n    "games": [\n        {\n            "package": "com.mobile.legends",\n            "label": "ML",\n            "profile": 3\n        }\n    ]\n}';
const WHITE = "android\ncom.android.systemui\ncom.google.android.inputmethod.latin\ncom.github.anrimian.musicplayer";

function realOutput(cmd) {
  if (/list games/.test(cmd)) return GAMELIST;
  if (/list whitelist/.test(cmd)) return WHITE;
  if (/printf 'fgc/.test(cmd)) return "fgc\na";
  return '{"ok":true}';
}

// Build a sandbox whose window.ksu behaves like the native bridge.
function run({ callbackForm = true, out = realOutput, calls = [] } = {}) {
  const sandbox = { Promise, setTimeout, clearTimeout, console, JSON, String, parseInt };
  // In a browser `window` IS the global object, so `window[id] = fn` makes `id`
  // callable as a bare identifier by the host's loadUrl() reply. Mirror that.
  sandbox.window = sandbox;
  sandbox.ksu = {
    calls,
    exec(cmd, cb) {
      calls.push(cmd);
      const text = String(out(cmd));
      if (cb && callbackForm) {
        // Mirrors WebViewInterface.exec(cmd, cbName): reply via loadUrl().
        setTimeout(() => {
          const fn = sandbox[cb];
          if (typeof fn === "function") fn(0, text, "");
        }, 0);
        return undefined;
      }
      // fastCmd: last line only.
      const lines = text.replace(/\n+$/, "").split("\n");
      return lines[lines.length - 1];
    }
  };
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox);
  return { bridge: sandbox.window.FGCBackend.pickBridge(), sandbox };
}

(async () => {
  // 1) callback form available: full multi-line output must survive.
  const calls = [];
  let { bridge } = run({ calls });
  const games = await bridge.exec("sh /x/core/fgc-cli.sh list games");
  check(games === GAMELIST, "multi-line output arrives intact (not just the last line)");
  check(games.trim().slice(0, 1) === "{", "gamelist JSON parses from the first byte");
  const white = await bridge.exec("sh /x/core/fgc-cli.sh list whitelist");
  check(white.split("\n").length === 4, "whitelist keeps all 4 entries");
  check(bridge.degraded === false, "bridge not flagged degraded when the callback form works");

  // 2) probe must run once, not per call.
  await bridge.exec("sh /x/core/fgc-cli.sh list games");
  const probes = calls.filter((c) => /printf 'fgc/.test(c)).length;
  check(probes === 1, "capability probe runs exactly once");

  // 3) host without the callback form: still answers (degraded), never hangs.
  const t0 = Date.now();
  ({ bridge } = run({ callbackForm: false }));
  const one = await bridge.exec("sh /x/core/fgc-cli.sh list games");
  check(typeof one === "string" && one.length > 0, "callback-less host still returns output");
  check(bridge.degraded === true, "callback-less host is reported as degraded");
  check(Date.now() - t0 < 4000, "no hang while probing a callback-less host");

  // 4) a real failure (no stdout, non-zero code) must reject, not fake success.
  // The probe still answers, so the adapter is on the full-output path; only the
  // actual command fails.
  const bad = run({ out: () => "" });
  bad.sandbox.ksu.exec = function (cmd, cb) {
    const isProbe = /printf 'fgc/.test(cmd);
    setTimeout(() => {
      const fn = bad.sandbox[cb];
      if (typeof fn !== "function") return;
      if (isProbe) fn(0, "fgc\na", "");
      else fn(1, "", "sh: not found");
    }, 0);
  };
  const b2 = bad.sandbox.FGCBackend.pickBridge();
  let msg = "";
  try { await b2.exec("boom"); } catch (e) { msg = String(e.message); }
  check(/not found/.test(msg), "silent failure rejects with the stderr text (never reports success)");

  console.log("\n" + fails + " failed");
  process.exit(fails ? 1 : 0);
})();
