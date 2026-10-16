/* adapters/backend.js — Frontend Adapter -> Backend Interface -> FGC Core.
 *
 * Device bridges probed (in order):
 *  1. window.ksu.exec        — WebUI X (SYNC, returns stdout string) / KsuWebUI (Promise).
 *     Extras when present: listPackages("user"|"system"), getPackagesInfo([...]),
 *     moduleInfo() (= exact moduleDir, no hardcoded paths), toast(), mmrl().
 *     NOTE: WebUI X gates exec behind the SHELL permission — denial is
 *     surfaced honestly instead of silently falling back.
 *  2. window.kernelsu.exec   — KernelSU manager (Promise<{errno,stdout,stderr}> or string).
 *  3. window.magisk.exec / window.fgc.exec — other WebView hosts.
 * Fallback: LocalBackend (localStorage, honest "preview" badge, no fake apps).
 *
 * Backend contract used by app.js: status/listGames/listBlack/listWhite/
 * packages/add/remove/toggle/setConf/setProfile/diag/fullConfig.
 * No arbitrary shell: CLI-side allowlist enforced in fgc-cli.sh. Static code only.
 */
(function () {
  "use strict";

  var FALLBACK_MODDIRS = [
    "/data/adb/modules/faagamecore",
    "/data/adb/modules_update/faagamecore"
  ];

  function toPromise(fn) {
    try {
      var r = fn();
      if (r && typeof r.then === "function") return r;
      return Promise.resolve(r);
    } catch (e) {
      return Promise.reject(e);
    }
  }

  function pickBridge() {
    try {
      if (typeof window.ksu !== "undefined" && window.ksu && typeof window.ksu.exec === "function") {
        var ksu = window.ksu, isWx = false;
        try { isWx = (typeof ksu.mmrl === "function") && !!ksu.mmrl(); } catch (e) { isWx = false; }
        return {
          name: isWx ? "ksu (WebUI X)" : "ksu",
          sync: true, ksu: ksu, isWx: isWx,
          exec: function (cmd) {
            return toPromise(function () { return ksu.exec(cmd); }).then(function (r) {
              if (r == null) return "";
              if (typeof r === "string") return r;
              if (typeof r.stdout === "string") return r.stdout;
              return String(r);
            });
          }
        };
      }
      if (typeof window.kernelsu !== "undefined" && window.kernelsu && typeof window.kernelsu.exec === "function") {
        var kk = window.kernelsu;
        return {
          name: "kernelsu (KernelSU manager)", sync: false, ksu: null,
          exec: function (cmd) {
            return toPromise(function () { return kk.exec(cmd); }).then(function (r) {
              if (r == null) return "";
              if (typeof r === "string") return r;
              if (typeof r.stdout === "string") return r.stdout;
              return String(r);
            });
          }
        };
      }
      if (typeof window.magisk !== "undefined" && window.magisk && typeof window.magisk.exec === "function") {
        var m = window.magisk;
        return { name: "magisk", sync: false, ksu: null, exec: function (cmd) {
          return toPromise(function () { return m.exec(cmd); }).then(function (r) {
            if (r == null) return "";
            if (typeof r === "string") return r;
            if (typeof r.stdout === "string") return r.stdout;
            return String(r);
          });
        } };
      }
      if (typeof window.fgc !== "undefined" && window.fgc && typeof window.fgc.exec === "function") {
        var f = window.fgc;
        return { name: "fgc", sync: false, ksu: null, exec: function (cmd) {
          return toPromise(function () { return f.exec(cmd); }).then(function (r) {
            if (r == null) return "";
            if (typeof r === "string") return r;
            if (typeof r.stdout === "string") return r.stdout;
            return String(r);
          });
        } };
      }
    } catch (e) { /* probing must never throw */ }
    return null;
  }

  function ksuModDir(ksu) {
    try {
      if (ksu && typeof ksu.moduleInfo === "function") {
        var info = JSON.parse(ksu.moduleInfo());
        if (info && typeof info.moduleDir === "string" && info.moduleDir) return info.moduleDir;
      }
    } catch (e) { /* ignore */ }
    return null;
  }

  function ksuToast(ksu, msg) {
    try { if (ksu && typeof ksu.toast === "function") ksu.toast(msg); } catch (e) {}
  }

  var ALLOW = { status: 1, list: 1, add: 1, remove: 1, toggle: 1, set: 1, diag: 1, "session-start": 1, "session-end": 1, icon: 1, icons: 1 };

  function DeviceBackend(bridge, moddir, bridgeInfo) {
    this.mode = "device";
    this.bridge = bridge;
    this.moddir = moddir;
    this.isWx = !!(bridge && bridge.isWx);
    this.bridgeInfo = bridgeInfo || { found: bridge.name, exec: true, moddir: moddir, perm: "granted" };
  }
  DeviceBackend.prototype._run = function (args) {
    var parts = String(args).split(" ");
    if (!ALLOW[parts[0]]) return Promise.reject(new Error("blocked command"));
    var cmd = "sh \"" + this.moddir + "/core/fgc-cli.sh\" " + args;
    return this.bridge.exec(cmd).then(null, function (e) {
      // Client-side exec telemetry: the only record of bridge-level failures.
      try {
        window.__fgcErr = window.__fgcErr || [];
        window.__fgcErr.push({ t: new Date().toISOString().slice(11, 19), op: parts[0], err: String((e && e.message) || e).slice(0, 120) });
        if (window.__fgcErr.length > 8) window.__fgcErr.shift();
      } catch (_) { /* never break on telemetry */ }
      throw e;
    });
  };
  function parseErr(r) {
    if (r && typeof r === "object" && r.error) throw new Error(r.error);
    return r;
  }
  DeviceBackend.prototype.status = function () { return this._run("status").then(JSON.parse); };
  DeviceBackend.prototype.fullConfig = function () {
    var self = this;
    return this.bridge.exec("cat \"" + self.moddir + "/config/config.json\"").then(function (r) {
      try { return JSON.parse(r); } catch (e) { return {}; }
    });
  };
  DeviceBackend.prototype.listGames = function () {
    return this._run("list games").then(function (t) {
      var d;
      try { d = JSON.parse(t); } catch (e) { throw new Error("bad-games"); }
      if (d && d.error) throw new Error(d.error);
      return (d && d.games) || [];
    });
  };
  DeviceBackend.prototype._parsePkgLines = function (t) {
    return String(t).split("\n").map(function (l) { return l.trim(); })
      .filter(Boolean).map(function (l) {
        var on = l.charAt(0) !== "!";
        return { pkg: on ? l : l.slice(1), on: on };
      });
  };
  DeviceBackend.prototype.listBlack = function () { return this._run("list blacklist").then(this._parsePkgLines); };
  DeviceBackend.prototype.listWhite = function () { return this._run("list whitelist").then(this._parsePkgLines); };
  function parseTyped(t) {
    return String(t).split("\n").map(function (l) { return l.trim(); }).filter(Boolean).map(function (l) {
      var p = l.split("\t");
      return { pkg: p[0], label: p[1] || p[0], type: p[2] || "unknown" };
    });
  }
  DeviceBackend.prototype.packages = function () {
    var self = this, k = self.bridge.ksu;
    function viaCli() { return self._run("list packages").then(parseTyped); }
    // Fast path: WebUI X PackageManager APIs (no per-app dumpsys needed).
    // Old hosts may lack getPackagesInfo -> then labels come from CLI merge.
    if (k && typeof k.listPackages === "function") {
      try {
        var users = JSON.parse(k.listPackages("user") || "[]");
        var systems = JSON.parse(k.listPackages("system") || "[]");
        var sysmap = {}, seen = {}, all = [];
        systems.forEach(function (p) { sysmap[p] = 1; if (!seen[p]) { seen[p] = 1; all.push(p); } });
        users.forEach(function (p) { if (!seen[p]) { seen[p] = 1; all.push(p); } });
        var labels = {}, infoList = [];
        if (typeof k.getPackagesInfo === "function") {
          for (var i = 0; i < all.length; i += 150) {
            var infos = [];
            // Host takes a JSON STRING (verified against real host bytecode:
            // getPackagesInfo(String)); a raw array coerces to garbage.
            try { infos = JSON.parse(k.getPackagesInfo(JSON.stringify(all.slice(i, i + 150))) || "[]"); } catch (e) { infos = []; }
            infos.forEach(function (inf) {
              if (!inf || inf.error || !inf.packageName) return;
              if (inf.appLabel && inf.appLabel !== inf.packageName) labels[inf.packageName] = inf.appLabel;
              infoList.push(inf);
            });
          }
        }
        var build = function () {
          var byPkg = {};
          var out = all.map(function (p) {
            var a = { pkg: p, label: labels[p] || p,
              type: sysmap[p] ? "system" : "user",
              isGame: false, version: "" };
            byPkg[p] = a;
            return a;
          });
          infoList.forEach(function (inf) {
            var a = byPkg[inf.packageName];
            if (a) { a.isGame = inf.isGame === true; if (inf.versionName) a.version = inf.versionName; }
          });
          out.sort(function (a, b) { return (a.label || a.pkg).toLowerCase() < (b.label || b.pkg).toLowerCase() ? -1 : 1; });
          return out;
        };
        // CLI merge fills anything still unresolved (old hosts, info errors).
        // Skipped when ksu already covered nearly everything: the java exec
        // costs seconds of blocked UI thread, so don't pay it needlessly.
        // CLI failure alone must not blank the list.
        var missing = 0, j;
        for (j = 0; j < all.length; j++) {
          if (!labels[all[j]]) missing++;
        }
        if (missing * 5 < all.length) {
          return Promise.resolve(build());
        }
        return viaCli().then(function (cli) {
          cli.forEach(function (a) {
            if (a && a.pkg && !labels[a.pkg] && a.label && a.label !== a.pkg) labels[a.pkg] = a.label;
          });
          return build();
        }, function () { return build(); });
      } catch (e) { /* fall through to CLI path */ }
    }
    return viaCli();
  };
  DeviceBackend.prototype.logs = function () {
    return this._run("list logs").then(function (t) {
      return String(t).split("\n").map(function (l) { return l.trim(); }).filter(Boolean).map(function (l) {
        var c = l.split("\t");
        return { ts: c[0] || "", ev: c[1] || "", pkg: c[2] || "", act: c[3] || "", res: c[4] || "", err: c[5] || "" };
      }).reverse();
    });
  };
  DeviceBackend.prototype.add = function (t, pkg, label, prof) {
    return this._run("add " + t + " " + pkg + " " + (label || pkg) + " " + (prof || 0)).then(JSON.parse).then(parseErr);
  };
  DeviceBackend.prototype.remove = function (t, pkg) {
    return this._run("remove " + t + " " + pkg).then(JSON.parse).then(parseErr);
  };
  DeviceBackend.prototype.toggle = function (t, pkg, on) {
    return this._run("toggle " + t + " " + pkg + " " + (on ? "on" : "off")).then(JSON.parse).then(parseErr);
  };
  DeviceBackend.prototype.setConf = function (k, v) { return this._run("set " + k + " " + v).then(JSON.parse).then(parseErr); };
  DeviceBackend.prototype.setProfile = function (p, pkg) {
    return this._run(pkg ? "set profile " + p + " " + pkg : "set default_profile " + p).then(JSON.parse).then(parseErr);
  };
  DeviceBackend.prototype.sessionStart = function (pkg) {
    return this._run("session-start " + pkg).then(JSON.parse).then(parseErr);
  };
  DeviceBackend.prototype.sessionEnd = function () {
    return this._run("session-end").then(JSON.parse).then(parseErr);
  };
  DeviceBackend.prototype.diag = function () { return this._run("diag").then(JSON.parse); };
  DeviceBackend.prototype.restartService = function () {
    // service.sh is idempotent (single-instance guard in main.sh): safe anytime.
    return this.bridge.exec("sh \"" + this.moddir + "/service.sh\"; echo started").then(function (r) {
      return { ok: true, out: String(r || "") };
    });
  };
  DeviceBackend.prototype.icon = function (pkg, ver) {
    return this._run("icon " + pkg + (ver ? " " + ver : "")).then(function (t) {
      t = String(t || "").trim();
      if (!t || t.charAt(0) === "{") return null;
      return "data:image/png;base64," + t;
    });
  };
  DeviceBackend.prototype.icons = function () {
    // Batch: all cached icons in ONE exec (pkg -> data URL map).
    return this._run("icons").then(function (t) {
      var map = {};
      String(t || "").split("\n").forEach(function (l) {
        l = l.trim();
        if (!l) return;
        var i = l.indexOf("\t");
        if (i > 0) map[l.slice(0, i)] = "data:image/png;base64," + l.slice(i + 1);
      });
      return map;
    }).catch(function () { return {}; });
  };

  /* ---- Local preview backend: real JS persistence, no fake installed apps ---- */
  var LS = "fgc.preview.v1";
  function load() {
    try { var d = JSON.parse(localStorage.getItem(LS)); if (d && d.config) return d; } catch (e) {}
    return {
      config: { enabled: true, detection_mode: "hybrid", poll_interval_sec: 3, default_profile: 1, cleanup_policy: "balanced", logging: true, dry_run: false },
      games: [], black: [], white: [
        { pkg: "android", on: true }, { pkg: "com.android.systemui", on: true }, { pkg: "com.android.phone", on: true }
      ],
      logs: []
    };
  }
  function LocalBackend(bridgeInfo) {
    this.mode = "preview";
    this.d = load();
    this.bridgeInfo = bridgeInfo || { found: null, exec: false, moddir: null, perm: "n/a" };
  }
  LocalBackend.prototype._save = function () { try { localStorage.setItem(LS, JSON.stringify(this.d)); } catch (e) {} };
  LocalBackend.prototype.status = function () {
    var en = this.d.config.enabled;
    return Promise.resolve({ core: en ? "ACTIVE" : "DISABLED", daemon_running: en, enabled: en, game: "", profile: this.d.config.default_profile, last_cleanup: this.d.logs.length ? "preview session — no device cleanup" : "", version: "1.2.2",
      device: { manufacturer: "Unknown", model: "Unknown", android: "Unknown", sdk: "Unknown", root: "Not detected" } });
  };
  LocalBackend.prototype.listGames = function () { return Promise.resolve(this.d.games.slice()); };
  LocalBackend.prototype.listBlack = function () { return Promise.resolve(this.d.black.slice()); };
  LocalBackend.prototype.listWhite = function () { return Promise.resolve(this.d.white.slice()); };
  LocalBackend.prototype.packages = function () { return Promise.resolve([]); }; // honest: no fake list
  LocalBackend.prototype.logs = function () { return Promise.resolve(this.d.logs.slice().reverse()); };
  LocalBackend.prototype.add = function (t, pkg, label, prof) {
    if (!/^[A-Za-z0-9._]+$/.test(pkg)) return Promise.resolve({ error: "invalid package" });
    var arr = t === "games" ? this.d.games.map(function (g) { return g.package; }) : this.d[t === "blacklist" ? "black" : "white"].map(function (x) { return x.pkg; });
    if (arr.indexOf(pkg) >= 0) return Promise.resolve({ error: "duplicate" });
    if (t === "games") this.d.games.push({ package: pkg, label: label || pkg, profile: prof || 0 });
    else this.d[t === "blacklist" ? "black" : "white"].push({ pkg: pkg, on: true });
    this._save(); return Promise.resolve({ ok: true });
  };
  LocalBackend.prototype.remove = function (t, pkg) {
    if (t === "games") this.d.games = this.d.games.filter(function (g) { return g.package !== pkg; });
    else { var k = t === "blacklist" ? "black" : "white"; this.d[k] = this.d[k].filter(function (x) { return x.pkg !== pkg; }); }
    this._save(); return Promise.resolve({ ok: true });
  };
  LocalBackend.prototype.toggle = function (t, pkg, on) {
    var k = t === "blacklist" ? "black" : "white";
    this.d[k] = this.d[k].map(function (x) { return x.pkg === pkg ? { pkg: pkg, on: !!on } : x; });
    this._save(); return Promise.resolve({ ok: true });
  };
  LocalBackend.prototype.setConf = function (k, v) {
    var c = this.d.config;
    if (k === "enabled" || k === "logging" || k === "dry_run") c[k] = (v === true || v === "true");
    else if (k === "poll_interval_sec") { v = parseInt(v, 10); if (!(v >= 2 && v <= 60)) return Promise.resolve({ error: "set-failed" }); c[k] = v; }
    else if (k === "default_profile") { v = parseInt(v, 10); if ([1, 2, 3, 4].indexOf(v) < 0) return Promise.resolve({ error: "set-failed" }); c[k] = v; }
    else if (k === "detection_mode" || k === "cleanup_policy") c[k] = v;
    else return Promise.resolve({ error: "set-failed" });
    this._save(); return Promise.resolve({ ok: true });
  };
  LocalBackend.prototype.setProfile = function (p, pkg) {
    p = parseInt(p, 10);
    if ([1, 2, 3, 4].indexOf(p) < 0 && p !== 0) return Promise.resolve({ error: "invalid profile" });
    if (pkg) {
      var found = false;
      this.d.games = this.d.games.map(function (g) {
        if (g.package === pkg) { found = true; return { package: g.package, label: g.label, profile: p }; }
        return g;
      });
      if (!found) return Promise.resolve({ error: "not-a-game" });
    } else {
      if ([1, 2, 3, 4].indexOf(p) < 0) return Promise.resolve({ error: "invalid profile" });
      this.d.config.default_profile = p;
    }
    this._save(); return Promise.resolve({ ok: true });
  };
  LocalBackend.prototype.sessionStart = function () { return Promise.resolve({ error: "preview" }); };
  LocalBackend.prototype.sessionEnd = function () { return Promise.resolve({ ok: true }); };
  LocalBackend.prototype.restartService = function () { return Promise.resolve({ error: "preview" }); };
  LocalBackend.prototype.icon = function () { return Promise.resolve(null); };
  LocalBackend.prototype.icons = function () { return Promise.resolve({}); };
  LocalBackend.prototype.diag = function () {
    return Promise.resolve({ commands: "preview-mode (no device shell)", session_lock: "absent", files: "config:ok core:ok (preview)", boot_completed: "n/a",
      caps: { pm: "no", dumpsys: "no", am: "no", cmd: "no", getprop: "no", foreground: "none", pkg_query: "none", kill: "none", launcher: "" },
      device: { manufacturer: "Unknown", model: "Unknown", android: "Unknown", sdk: "Unknown", root: "Not detected" } });
  };
  LocalBackend.prototype.fullConfig = function () { return Promise.resolve(Object.assign({}, this.d.config)); };

  function create() {
    var bridge = pickBridge();
    if (!bridge) return Promise.resolve(new LocalBackend());
    var dirs = [];
    try {
      var mid = bridge.ksu && ksuModDir(bridge.ksu);
      if (mid) dirs.push(mid);
    } catch (e) { /* ignore */ }
    FALLBACK_MODDIRS.forEach(function (d) { if (dirs.indexOf(d) < 0) dirs.push(d); });
    function preview(reason) {
      var lb = new LocalBackend({ found: bridge.name, exec: false, moddir: dirs[0] || null, perm: reason });
      lb.mode = "preview";
      return lb;
    }
    // 0. exec itself must work (a failure here means permission denial,
    // not a wrong directory).
    return bridge.exec("echo fgc-probe").then(function () {
      // Try each candidate module dir; the first whose CLI answers wins.
      // Never silently assume a fixed directory exists.
      function attempt(i) {
        if (i >= dirs.length) {
          return Promise.resolve(preview("no candidate module dir answered (tried: " + dirs.join(", ") + ")"));
        }
        var be = new DeviceBackend(bridge, dirs[i], { found: bridge.name, exec: true, moddir: dirs[i], perm: "granted" });
        return be._run("status").then(function () { return be; }).catch(function () { return attempt(i + 1); });
      }
      return attempt(0);
    }).catch(function (err) {
      try { ksuToast(bridge.ksu, "FGC: shell permission required"); } catch (e) {}
      return preview("exec denied (" + (err && err.message ? err.message : err) + ") — grant SHELL permission to this module in the WebUI host app");
    });
  }

  window.FGCBackend = { create: create, DeviceBackend: DeviceBackend, MagiskBackend: DeviceBackend, LocalBackend: LocalBackend, pickBridge: pickBridge };
})();
