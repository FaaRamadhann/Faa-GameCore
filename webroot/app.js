/* app.js — FGC WebUI controller. No CDN. Honest states only. */
(function () {
  "use strict";
  var backend = null;
  var state = { page: "home", status: null, games: [], black: [], white: [], logs: [], config: {}, busy: {}, pkgs: [], pkgTypes: {}, tabGames: "user", tabWhite: "user", tabBlack: "user" };
  var PROFILES = [
    { id: 1, name: "Balance", desc: "Konservatif: hanya target tipe-user" },
    { id: 2, name: "Performance", desc: "Standar: seluruh blacklist aktif" },
    { id: 3, name: "Awaken", desc: "Agresif: + satu sapuan ulang terbatas" },
    { id: 4, name: "Auto", desc: "Aturan: game→Perf, idle→Balance" }
  ];
  var PAGES = [
    { id: "home", label: "Home", icon: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none"><path d="M4 11 12 4l8 7v8a1 1 0 0 1-1 1h-5v-6h-4v6H5a1 1 0 0 1-1-1v-8Z" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/></svg>', sub: "Ringkasan status dan sesi game" },
    { id: "games", label: "Gamelist", icon: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none"><rect x="3" y="7" width="18" height="11" rx="5" stroke="currentColor" stroke-width="1.8"/><circle cx="9" cy="12.5" r="1.2" fill="currentColor"/><circle cx="15" cy="12.5" r="1.2" fill="currentColor"/></svg>', sub: "Game terdaftar dan profil per game" },
    { id: "white", label: "Whitelist", icon: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none"><path d="M12 3 5 6v5c0 5 3 8 7 10 4-2 7-5 7-10V6l-7-3Z" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/><path d="m9.5 12 2 2 3.5-4" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>', sub: "Aplikasi yang tidak disentuh FGC" },
    { id: "black", label: "Blacklist", icon: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="8" stroke="currentColor" stroke-width="1.8"/><path d="M8 8l8 8" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>', sub: "Target cleanup saat sesi game" },
    { id: "logs", label: "Session Logs", icon: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none"><path d="M5 5h14v14H5z" stroke="currentColor" stroke-width="1.8"/><path d="M8 9h8M8 12.5h8M8 16h5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>', sub: "Event sesi dari backend", adv: 1 },
    { id: "settings", label: "Settings", icon: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="3" stroke="currentColor" stroke-width="1.8"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M19.1 4.9 17 7M7 17l-2.1 2.1" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>', sub: "Konfigurasi core", adv: 1 },
    { id: "diag", label: "Diagnostics", icon: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none"><path d="M4 17c4-8 6-12 8-12s4 4 8 12" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><circle cx="12" cy="17" r="1.4" fill="currentColor"/></svg>', sub: "Pemeriksaan nyata backend", adv: 1 }
  ];

  function $(id) { return document.getElementById(id); }
  function esc(s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
  function toast(msg, kind) {
    var box = $("toast"); var d = document.createElement("div");
    d.className = kind || ""; d.textContent = msg; box.appendChild(d);
    setTimeout(function () { d.remove(); }, 3200);
  }
  function setBusy(key, on) {
    state.busy[key] = on;
    document.querySelectorAll("[data-busy='" + key + "']").forEach(function (b) { b.disabled = !!on; });
  }

  /* ---------- navigation ---------- */
  function buildNav() {
    var s1 = $("sideNav"), s2 = $("sideNav2"), bot = $("botNav");
    s1.innerHTML = ""; s2.innerHTML = ""; bot.innerHTML = "";
    var mains = PAGES.filter(function (p) { return !p.adv; }).slice(0, 4);
    PAGES.forEach(function (p) {
      var b = document.createElement("button");
      b.innerHTML = p.icon + "<span>" + p.label + "</span>";
      b.dataset.page = p.id;
      b.addEventListener("click", function () { nav(p.id); });
      (p.adv ? s2 : s1).appendChild(b);
    });
    mains.forEach(function (p) {
      var b = document.createElement("button");
      b.innerHTML = p.icon + "<span>" + (p.id === "black" ? "Blacklist" : p.label) + "</span>";
      b.dataset.page = p.id;
      b.addEventListener("click", function () { nav(p.id); });
      bot.appendChild(b);
    });
    document.querySelectorAll("[data-nav]").forEach(function (b) {
      b.addEventListener("click", function () { nav(b.dataset.nav); });
    });
    $("fabAdv").addEventListener("click", function () {
      var order = ["logs", "settings", "diag"];
      var cur = order.indexOf(state.page);
      nav(order[(cur + 1) % order.length]);
    });
  }
  function nav(id) {
    state.page = id;
    document.querySelectorAll(".page").forEach(function (s) { s.classList.remove("active"); });
    var pg = $("page-" + id); if (pg) pg.classList.add("active");
    var meta = PAGES.filter(function (p) { return p.id === id; })[0];
    if (meta) { $("pageTitle").textContent = meta.label; $("pageSub").textContent = meta.sub; }
    document.querySelectorAll("[data-page]").forEach(function (b) {
      b.classList.toggle("active", b.dataset.page === id);
    });
    render();
  }

  /* ---------- renderers ---------- */
  function badge(ev) {
    if (/SUCCESS|STARTED|DETECTED/.test(ev)) return "b-green";
    if (/SKIPPED|RECOVERY/.test(ev)) return "b-yellow";
    if (/FAILED|ERROR/.test(ev)) return "b-red";
    return "b-blue";
  }
  function profileName(id) {
    var p = PROFILES.filter(function (x) { return x.id === Number(id); })[0];
    return p ? p.id + " - " + p.name : String(id);
  }
  function render() {
    renderChips(); renderHome(); renderGames(); renderLists(); renderLogs(); renderSettings();
  }
  function renderChips() {
    var s = state.status;
    var chip = $("chipCore"), tx = $("chipCoreTx");
    chip.className = "chip";
    if (!s) { tx.textContent = "Memuat…"; return; }
    var map = { ACTIVE: "ok", STARTING: "info", DISABLED: "warn", STOPPED: "warn", ERROR: "err" };
    chip.classList.add(map[s.core] || "info");
    tx.textContent = "STATUS: " + s.core;
    $("chipVer").textContent = "v" + (s.version || "1.0.0");
    $("chipProf").textContent = "PROFILE: " + profileName(s.profile);
    $("devVer").textContent = "v" + (s.version || "1.0.0");
    var d = s.device || {};
    $("devModel").textContent = d.model || "Unknown";
    $("devSub").textContent = (d.manufacturer || "Unknown") + " • Android " + (d.android || "Unknown");
    $("devRootTx").textContent = "Root: " + (d.root || "Not detected");
    var bi = (backend && backend.bridgeInfo) || {};
    if (backend.mode === "preview") {
      $("backendBadge").textContent = bi.found ? "preview (bridge " + bi.found + " denied)" : "preview (browser)";
    } else {
      $("backendBadge").textContent = "device: " + (bi.found || backend.mode);
    }
  }
  function renderHome() {
    var s = state.status;
    if (!s) { $("sessBox").innerHTML = '<div class="skel" style="height:60px"></div>'; return; }
    $("sessBox").innerHTML =
      '<div class="kv"><span>Game</span><b class="mono">' + (s.game ? esc(s.game) : "Tidak aktif") + "</b></div>" +
      '<div class="kv"><span>Profile</span><b>' + esc(profileName(s.profile)) + "</b></div>" +
      '<div class="kv"><span>Last cleanup</span><b>' + (s.last_cleanup ? esc(s.last_cleanup) : "Belum ada") + "</b></div>" +
      (!s.game ? '<div class="empty"><div class="big">Menunggu game terdeteksi</div>Mulai salah satu game di Gamelist untuk memulai sesi cleanup.</div>' : "");
    $("coreBox").innerHTML =
      '<div class="kv"><span>Status</span><b>' + esc(s.core) + "</b></div>" +
      '<div class="kv"><span>Daemon</span><b>' + (s.daemon_running ? "Berjalan" : "Berhenti") + "</b></div>" +
      '<div class="kv"><span>Enabled</span><b>' + (s.enabled ? "Ya" : "Tidak") + "</b></div>";
    $("detBox").innerHTML =
      '<div class="kv"><span>Mode</span><b class="mono">' + esc(state.config.detection_mode || "hybrid") + "</b></div>" +
      '<div class="kv"><span>Poll interval</span><b class="mono">' + esc(state.config.poll_interval_sec || 3) + "s</b></div>" +
      '<div class="kv"><span>Policy</span><b class="mono">' + esc(state.config.cleanup_policy || "balanced") + "</b></div>";
    var pr = $("profRow"); pr.innerHTML = "";
    PROFILES.forEach(function (p) {
      var b = document.createElement("button");
      b.className = "profile" + (Number(s.profile) === p.id ? " active" : "");
      b.dataset.busy = "profile";
      b.innerHTML = "<b>" + p.id + ". " + esc(p.name) + "</b><small>" + esc(p.desc) + "</small>";
      b.addEventListener("click", function () { setProfile(p.id); });
      pr.appendChild(b);
    });
    var logs = state.logs.slice(0, 5);
    $("recentBox").innerHTML = logs.length
      ? '<table><tr><th>Waktu</th><th>Event</th><th>Package</th><th>Hasil</th></tr>' + logs.map(function (l) {
          return "<tr><td class='mono'>" + esc(l.ts) + "</td><td><span class='badge " + badge(l.ev) + "'>" + esc(l.ev) + "</span></td><td class='mono'>" + esc(l.pkg || "—") + "</td><td>" + esc(l.res || "") + "</td></tr>";
        }).join("") + "</table>"
      : '<div class="empty"><div class="big">Belum ada aktivitas</div>Log masih kosong — bukan data palsu, sesi akan tercatat di sini.</div>';
  }
  function initials(label) {
    var s = String(label == null ? "?" : label).trim();
    return (s.charAt(0) || "?").toUpperCase();
  }
  function avatarHue(pkg) {
    var h = 0, i;
    pkg = String(pkg || "?");
    for (i = 0; i < pkg.length; i++) h = (h * 31 + pkg.charCodeAt(i)) % 360;
    return "linear-gradient(135deg,hsl(" + h + ",55%,32%),hsl(" + ((h + 40) % 360) + ",70%,48%))";
  }
  var iconCache = {}, iconQueue = [], iconBusy = false, iconObs = null, iconSweepT = null;
  function queueIcon(img) {
    // Lazy: only fetch when the row scrolls into view; one fetch at a time.
    // Plus a viewport sweep fallback: some WebViews never fire IntersectionObserver.
    if ("IntersectionObserver" in window) {
      if (!iconObs) {
        iconObs = new IntersectionObserver(function (entries) {
          entries.forEach(function (en) {
            if (en.isIntersecting) { iconObs.unobserve(en.target); fetchIcon(en.target); }
          });
        }, { rootMargin: "200px" });
      }
      iconObs.observe(img);
      scheduleSweep();
    } else {
      fetchIcon(img);
    }
  }
  function scheduleSweep() {
    if (iconSweepT) return;
    iconSweepT = setTimeout(function () {
      iconSweepT = null;
      var imgs = document.querySelectorAll(".appicon img[data-pkg]:not([data-done])");
      for (var i = 0; i < imgs.length; i++) {
        try {
          var r = imgs[i].getBoundingClientRect();
          if (r.top < window.innerHeight + 400 && r.bottom > -400) fetchIcon(imgs[i]);
        } catch (e) { /* ignore */ }
      }
      if (document.querySelector(".appicon img[data-pkg]:not([data-done])")) scheduleSweep();
    }, 1500);
  }
  function fetchIcon(img) {
    var pkg = img.dataset.pkg;
    if (!pkg || img.dataset.done) return;
    img.dataset.done = "1";
    if (iconCache[pkg]) { showIcon(img, iconCache[pkg]); return; }
    iconQueue.push(img);
    pumpIcons();
  }
  function pumpIcons() {
    if (iconBusy) return;
    var img = iconQueue.shift();
    if (!img) return;
    iconBusy = true;
    // Macrotask yield: on sync bridges each fetch blocks the thread for a
    // second or more — without this the UI freezes through the whole queue.
    setTimeout(function () {
      backend.icon(img.dataset.pkg).then(function (url) {
        iconBusy = false;
        if (url) { iconCache[img.dataset.pkg] = url; showIcon(img, url); }
        pumpIcons();
      }).catch(function () { iconBusy = false; pumpIcons(); });
    }, 30);
  }
  function paintCachedIcons() {
    // Show everything already in memory cache without new execs.
    var imgs = document.querySelectorAll(".appicon img[data-pkg]:not([data-done])");
    for (var i = 0; i < imgs.length; i++) {
      var u = iconCache[imgs[i].dataset.pkg];
      if (u) { imgs[i].dataset.done = "1"; showIcon(imgs[i], u); }
    }
  }
  function loadIconBatch() {
    // One exec for the whole disk cache; individual fetch covers the rest.
    return backend.icons().then(function (map) {
      var changed = false, k;
      for (k in map) {
        if (map.hasOwnProperty(k) && map[k] && !iconCache[k]) { iconCache[k] = map[k]; changed = true; }
      }
      if (changed) paintCachedIcons();
    }).catch(function () {});
  }
  function showIcon(img, url) {
    img.src = url;
    img.style.display = "block";
    var letter = img.parentNode.querySelector("span");
    if (letter) letter.style.display = "none";
  }
  function appRow(name, pkg, extra, rightEl) {
    var row = document.createElement("div"); row.className = "appitem";
    var ic = document.createElement("div"); ic.className = "appicon";
    var letter = document.createElement("span"); letter.textContent = initials(name);
    ic.appendChild(letter);
    try { ic.style.background = avatarHue(pkg); } catch (e) {}
    if (backend && backend.mode === "device") {
      var img = document.createElement("img");
      img.alt = ""; img.loading = "lazy";
      img.style.cssText = "width:100%;height:100%;object-fit:cover;border-radius:12px;display:none";
      img.dataset.pkg = pkg;
      ic.appendChild(img);
      queueIcon(img);
    }
    var meta = document.createElement("div"); meta.className = "appmeta";
    var b = document.createElement("b"); b.textContent = name;
    var p = document.createElement("div"); p.className = "pkg mono"; p.textContent = pkg;
    meta.appendChild(b); meta.appendChild(p);
    if (extra) { var t = document.createElement("div"); t.className = "tag"; t.textContent = extra; meta.appendChild(t); }
    row.appendChild(ic); row.appendChild(meta); row.appendChild(rightEl);
    return row;
  }
  /* ---------- UI capabilities: adapt to host, screen and device ---------- */
  var UI = {
    observer: ("IntersectionObserver" in window),
    storageOK: (function () {
      try {
        var k = "__fgc_probe";
        localStorage.setItem(k, "1");
        localStorage.removeItem(k);
        return true;
      } catch (e) { return false; }
    })(),
    memoryGB: (typeof navigator !== "undefined" && navigator.deviceMemory) || 0,
    reducedMotion: (typeof window.matchMedia === "function" && window.matchMedia("(prefers-reduced-motion: reduce)").matches) || false,
    touch: ("ontouchstart" in window),
    pageSize: 60
  };
  UI.pageSize = (UI.memoryGB && UI.memoryGB <= 2) ? 40 : (UI.memoryGB >= 6 ? 100 : 60);
  function renderPaged(box, rows, makeRow, emptyHTML) {
    // Windowed rendering: only the first page lands in the DOM; a sentinel
    // appends more on scroll. Hundreds of rows no longer rebuild at once.
    // Without IntersectionObserver: render everything (graceful fallback).
    if (box._sentObs) { try { box._sentObs.disconnect(); } catch (e) {} box._sentObs = null; }
    box.innerHTML = "";
    if (!rows.length) { box.innerHTML = emptyHTML; return; }
    var frag = document.createDocumentFragment();
    var first = UI.observer ? rows.slice(0, UI.pageSize) : rows;
    first.forEach(function (r) { frag.appendChild(makeRow(r)); });
    box.appendChild(frag);
    box._rows = rows; box._shown = first.length; box._makeRow = makeRow;
    if (UI.observer && rows.length > first.length) {
      var sent = document.createElement("div");
      sent.className = "sentinel"; sent.style.cssText = "height:8px";
      box.appendChild(sent);
      var obs = new IntersectionObserver(function (ents) {
        if (ents[0] && ents[0].isIntersecting) growList(box);
      }, { rootMargin: "600px" });
      obs.observe(sent);
      box._sentObs = obs;
    }
  }
  function growList(box) {
    var rows = box._rows || [], shown = box._shown || 0;
    if (shown >= rows.length || typeof box._makeRow !== "function") return;
    var frag = document.createDocumentFragment();
    rows.slice(shown, shown + UI.pageSize).forEach(function (r) { frag.appendChild(box._makeRow(r)); });
    var sent = box.querySelector(".sentinel");
    if (sent) box.insertBefore(frag, sent); else box.appendChild(frag);
    box._shown = shown + UI.pageSize;
    if (box._shown >= rows.length) {
      if (box._sentObs) { try { box._sentObs.disconnect(); } catch (e) {} box._sentObs = null; }
      var s2 = box.querySelector(".sentinel");
      if (s2) s2.remove();
    }
  }
  function bindDelegated(box, handler) {
    // One listener per list container (survives innerHTML rebuilds),
    // instead of hundreds of per-row listeners.
    if (!box || box.dataset.delegated) return;
    box.addEventListener("change", handler);
    box.dataset.delegated = "1";
  }
  function onListChange(ev) {
    var el = ev && ev.target;
    if (!el || !el.dataset) return;
    if (el.dataset.flip) handleFlip(el);
    else if (el.dataset.prof !== undefined && el.tagName === "SELECT") handleProfile(el);
  }
  function handleFlip(inp) {
    var want = inp.checked, pkg = inp.dataset.pkg, kind = inp.dataset.flip;
    var label = inp.dataset.label || pkg;
    inp.disabled = true;
    var op, msgs, check;
    if (kind === "games") {
      op = function () { return want ? backend.add("games", pkg, label, 0) : backend.remove("games", pkg); };
      msgs = ["Game ditambahkan", "Game dihapus", "Gagal mengubah gamelist"];
      check = function () {
        var g = state.games.filter(function (x) { return x.package === pkg; })[0];
        return want ? !!g : !g;
      };
    } else {
      var cfgName = kind === "whitelist" ? "Whitelist" : "Blacklist";
      var extra = kind === "whitelist" ? "dikecualikan dari cleanup" : "memenuhi syarat cleanup";
      op = function () { return want ? backend.add(kind, pkg) : backend.remove(kind, pkg); };
      msgs = [cfgName + " ON — " + extra, cfgName + " OFF", "Gagal mengubah " + kind];
      check = function () {
        var list = kind === "whitelist" ? state.white : state.black;
        var e = list.filter(function (x) { return x.pkg === pkg; })[0];
        return want ? !!(e && e.on) : (!e || !e.on);
      };
    }
    function doneOk(msg) { toast(msg, "ok"); refreshLight(); inp.disabled = false; }
    function doneFail(msg) { inp.checked = !want; toast(msg, "err"); refreshLight(); inp.disabled = false; }
    function reconcile(errMsg) {
      refreshLight().then(function () {
        var okNow = false;
        try { okNow = !!check(); } catch (e) { okNow = false; }
        if (okNow) doneOk(msgs[want ? 0 : 1] + " (terkonfirmasi)");
        else doneFail(errMsg);
      }).catch(function () { doneFail(errMsg); });
    }
    op().then(function (r) {
      if (r && (r.ok || !r.error)) { doneOk(msgs[want ? 0 : 1]); }
      else reconcile((r && r.error) || msgs[2]);
    }).catch(function (e) {
      var why = e && e.message ? ": " + e.message : "";
      reconcile(msgs[2] + why);
    });
  }
  function handleProfile(el) {
    var pkg = el.dataset.pkg, pv = parseInt(el.value, 10);
    el.disabled = true;
    backend.setProfile(pv, pkg).then(function (r) {
      el.disabled = false;
      if (r && r.ok) { toast("Profil game disimpan", "ok"); refreshLight(); }
      else toast("Gagal menyimpan profil", "err");
    }).catch(function () { el.disabled = false; toast("Backend error", "err"); });
  }
  function switchEl(pkg, on, kind, label) {
    // Listener-free factory: the container's delegated handler does the work.
    var w = document.createElement("label"); w.className = "switch";
    var inp = document.createElement("input"); inp.type = "checkbox"; inp.checked = !!on;
    inp.setAttribute("aria-label", "Toggle " + pkg);
    inp.dataset.flip = kind; inp.dataset.pkg = pkg; inp.dataset.label = label || pkg;
    var tr = document.createElement("span"); tr.className = "track";
    w.appendChild(inp); w.appendChild(tr);
    return w;
  }
  function labelOf(pkg, fallback) {
    var a = (state.pkgs || []).filter(function (x) { return x.pkg === pkg; })[0];
    if (a && a.label && a.label !== a.pkg) return a.label;
    return fallback || pkg;
  }
  function universe(members, excludeActive) {
    // Union: anggota (ON dulu) + aplikasi terinstal, minus anggota aktif daftar lawan.
    var byPkg = {};
    (state.pkgs || []).forEach(function (a) { byPkg[a.pkg] = a; });
    var seen = {}, rows = [];
    members.forEach(function (m) {
      if (excludeActive && excludeActive[m.pkg]) return;
      seen[m.pkg] = 1;
      rows.push({ pkg: m.pkg, on: m.on !== false, member: m, info: byPkg[m.pkg] || null });
    });
    (state.pkgs || []).forEach(function (a) {
      if (seen[a.pkg]) return;
      if (excludeActive && excludeActive[a.pkg]) return;
      seen[a.pkg] = 1;
      rows.push({ pkg: a.pkg, on: false, info: a });
    });
    return rows;
  }
  function rowLabel(r) {
    if (r.member && r.member.label && r.member.label !== r.pkg) return r.member.label;
    if (r.info && r.info.label) return r.info.label;
    return r.pkg;
  }
  function matchTerm(r, term) {
    if (!term) return true;
    var lb = (r.member && r.member.label) || (r.info && r.info.label) || "";
    return r.pkg.toLowerCase().indexOf(term) >= 0 || lb.toLowerCase().indexOf(term) >= 0;
  }
  function sortMembersFirst(rows) {
    rows.sort(function (a, b) {
      if (!!b.on !== !!a.on) return b.on ? 1 : -1;
      var la = (((a.member && a.member.label) || (a.info && a.info.label) || a.pkg) + "").toLowerCase();
      var lb = (((b.member && b.member.label) || (b.info && b.info.label) || b.pkg) + "").toLowerCase();
      return la < lb ? -1 : 1;
    });
    return rows;
  }
  function profileSelect(pkg, current) {
    var s = document.createElement("select");
    s.setAttribute("aria-label", "Profil per game " + pkg);
    s.dataset.prof = "1"; s.dataset.pkg = pkg;
    s.style.minHeight = "44px";
    [["0", "Default"], ["1", "1 Balance"], ["2", "2 Perf."], ["3", "3 Awaken"], ["4", "4 Auto"]].forEach(function (o) {
      var op = document.createElement("option");
      op.value = o[0]; op.textContent = o[1];
      if (String(current || 0) === o[0]) op.selected = true;
      s.appendChild(op);
    });
    return s;
  }
  function renderGames() {
    var box = $("gamesList");
    var term = ($("qGames").value || "").toLowerCase();
    var members = state.games.map(function (g) { return { pkg: g.package, label: g.label, on: true, profile: g.profile || 0 }; });
    var rows = sortMembersFirst(universe(members, null).filter(function (r) {
      return inTab(r.pkg, state.tabGames) && matchTerm(r, term);
    }));
    if (!rows.length) {
      if (box._sentObs) { try { box._sentObs.disconnect(); } catch (e) {} box._sentObs = null; }
      box.innerHTML = '<div class="empty"><div class="big">Tidak ada aplikasi</div>' +
        (backend.mode === "preview" && !state.games.length ? "Mode pratinjau: buka WebUI dari aplikasi host untuk daftar aplikasi perangkat." : "Tidak ada yang cocok di tab ini.") + "</div>";
      return;
    }
    var active = state.status && state.status.game;
    renderPaged(box, rows, function (r) {
      var label = (r.member && r.member.label) || (r.info && r.info.label) || r.pkg;
      var right = document.createElement("div");
      right.style.display = "flex"; right.style.flexDirection = "column"; right.style.gap = "8px"; right.style.alignItems = "stretch";
      var tags = [];
      if (active === r.pkg) tags.push("AKTIF");
      if (r.info && r.info.isGame) tags.push("GAME");
      if (r.info && r.info.version) tags.push("v" + r.info.version);
      right.appendChild(switchEl(r.pkg, r.on, "games", label));
      if (r.on && r.member) right.appendChild(profileSelect(r.pkg, r.member.profile));
      return appRow(label, r.pkg, tags.join(" • "), right);
    });
  }
  function typeOf(pkg) { return state.pkgTypes[pkg] || "unknown"; }
  function inTab(pkg, tab) {
    var t = typeOf(pkg);
    return t === tab || t === "unknown" || t === "other";
  }
  function renderLists() {
    // Eksklusi silang: app yang AKTIF di daftar lawan tidak muncul di sini.
    var whiteOn = {}, blackOn = {};
    state.white.forEach(function (x) { if (x.on) whiteOn[x.pkg] = 1; });
    state.black.forEach(function (x) { if (x.on) blackOn[x.pkg] = 1; });
    [["whiteList", "qWhite", state.white, "whitelist", state.tabWhite, blackOn],
     ["blackList", "qBlack", state.black, "blacklist", state.tabBlack, whiteOn]].forEach(function (cfg) {
      var box = $(cfg[0]); var term = ($(cfg[1]).value || "").toLowerCase();
      var members = cfg[2].map(function (x) { return { pkg: x.pkg, on: x.on }; });
      var rows = sortMembersFirst(universe(members, cfg[5]).filter(function (r) {
        return inTab(r.pkg, cfg[4]) && matchTerm(r, term);
      }));
      if (!rows.length) {
        if (box._sentObs) { try { box._sentObs.disconnect(); } catch (e) {} box._sentObs = null; }
        box.innerHTML = '<div class="empty"><div class="big">Tidak ada aplikasi</div>' +
          (backend.mode === "preview" && !members.length ? "Mode pratinjau: buka WebUI dari aplikasi host untuk daftar aplikasi perangkat." : "Tidak ada yang cocok (entri aktif daftar lawan disembunyikan).") + "</div>";
        return;
      }
      renderPaged(box, rows, function (r) {
        var label = labelOf(r.pkg);
        var right = document.createElement("div");
        right.style.display = "flex"; right.style.gap = "8px"; right.style.alignItems = "center";
        right.appendChild(switchEl(r.pkg, r.on, cfg[3], label));
        var t = typeOf(r.pkg);
        var tag = (r.on ? "ON" : "OFF") + (t !== "unknown" ? " • " + t : "") + (!r.info ? " • tidak terinstal" : "");
        return appRow(label, r.pkg, tag, right);
      });
    });
  }
  function renderLogs() {
    var box = $("logsBox");
    var term = ($("qLogs").value || "").toLowerCase();
    var f = $("fLogs").value;
    var items = state.logs.filter(function (l) {
      if (f && l.ev !== f) return false;
      if (!term) return true;
      return (l.pkg || "").toLowerCase().indexOf(term) >= 0 || (l.ev || "").toLowerCase().indexOf(term) >= 0 || (l.res || "").toLowerCase().indexOf(term) >= 0;
    });
    if (!items.length) { box.innerHTML = '<div class="empty"><div class="big">Belum ada log</div>Tidak ada data yang dikarang — log sesi akan muncul di sini.</div>'; return; }
    box.innerHTML = '<table><tr><th>Timestamp</th><th>Event</th><th>Package</th><th>Action</th><th>Result</th></tr>' +
      items.slice(0, 200).map(function (l) {
        return "<tr><td class='mono'>" + esc(l.ts) + "</td><td><span class='badge " + badge(l.ev) + "'>" + esc(l.ev) + "</span></td><td class='mono'>" + esc(l.pkg || "—") + "</td><td class='mono'>" + esc(l.act || "") + "</td><td>" + esc(l.res || "") + (l.err ? " <span class='mono' style='color:var(--danger)'>" + esc(l.err) + "</span>" : "") + "</td></tr>";
      }).join("") + "</table>";
  }
  function renderSettings() {
    var c = state.config; var box = $("setBox");
    function sel(id, opts, val) {
      return '<select id="' + id + '" data-busy-x>' + opts.map(function (o) {
        return '<option value="' + o[0] + '"' + (String(val) === String(o[0]) ? " selected" : "") + ">" + o[1] + "</option>";
      }).join("") + "</select>";
    }
    box.innerHTML =
      row("FGC Enabled", "Master switch core", sel("sEnabled", [["true", "ON"], ["false", "OFF"]], c.enabled)) +
      row("Detection mode", "hybrid = gamelist + foreground", sel("sMode", [["hybrid", "Hybrid"], ["foreground", "Foreground"], ["gamelist", "Gamelist"]], c.detection_mode)) +
      row("Poll interval", "Detik antar pemindaian (2–60)", sel("sPoll", [["2", "2s"], ["3", "3s"], ["5", "5s"], ["10", "10s"]], c.poll_interval_sec)) +
      row("Default profile", "Dipakai saat game tanpa profil khusus", sel("sProf", [["1", "1 - Balance"], ["2", "2 - Performance"], ["3", "3 - Awaken"], ["4", "4 - Auto"]], c.default_profile)) +
      row("Cleanup policy", "Seberapa agresif cleanup", sel("sPol", [["conservative", "Conservative"], ["balanced", "Balanced"], ["aggressive", "Aggressive"]], c.cleanup_policy)) +
      row("Logging", "Tulis session.log", sel("sLog", [["true", "ON"], ["false", "OFF"]], c.logging)) +
      row("Dry-run", "Uji policy tanpa force-stop", sel("sDry", [["false", "OFF"], ["true", "ON"]], c.dry_run)) +
      '<div class="row-actions"><button class="btn" id="btnSaveSet">Simpan Settings</button></div>' +
      '<p style="color:var(--text-muted);font-size:12px;margin-top:10px">Dry-run menguji policy tanpa menghentikan aplikasi. Perubahan hanya tampil sukses setelah backend konfirmasi.</p>';
    function row(t, d, ctrl) {
      return '<div class="setrow"><div class="lab"><b>' + t + "</b><small>" + d + "</small></div><div>" + ctrl + "</div></div>";
    }
    $("btnSaveSet").addEventListener("click", function () {
      var vals = {
        enabled: $("sEnabled").value, detection_mode: $("sMode").value,
        poll_interval_sec: $("sPoll").value, default_profile: $("sProf").value,
        cleanup_policy: $("sPol").value, logging: $("sLog").value, dry_run: $("sDry").value
      };
      setBusy("settings", true);
      var chain = Promise.resolve(true);
      Object.keys(vals).forEach(function (k) {
        chain = chain.then(function (ok) {
          if (!ok) return false;
          return backend.setConf(k, vals[k]).then(function (r) { return !!(r && r.ok); }).catch(function () { return false; });
        });
      });
      chain.then(function (ok) {
        setBusy("settings", false);
        if (ok) { toast("Settings tersimpan", "ok"); refreshLight(); }
        else toast("Sebagian/gagal tersimpan — periksa nilai", "err");
      });
    });
  }

  /* ---------- mutations ---------- */
  function mutate(key, fn, okMsg, errMsg) {
    if (state.busy[key]) return;
    setBusy(key, true);
    fn().then(function (r) {
      setBusy(key, false);
      if (r && (r.ok || !r.error)) { toast(okMsg, "ok"); refreshLight(); }
      else toast((r && r.error) || errMsg, "err");
    }).catch(function () { setBusy(key, false); toast(errMsg, "err"); });
  }
  function setProfile(id) {
    mutate("profile", function () { return backend.setProfile(id); }, "Profile → " + profileName(id), "Gagal ganti profile");
  }

  /* ---------- data ---------- */
  function loadPackages() {
    // Slow path (pm/dumpsys per app, blocking sync exec): NOT on every refresh.
    return backend.packages().then(function (pkgs) {
      state.pkgs = pkgs || [];
      state.pkgTypes = {};
      state.pkgs.forEach(function (a) { if (a && a.pkg) state.pkgTypes[a.pkg] = a.type || "unknown"; });
      if (state.page === "games") renderGames();
      if (state.page === "white" || state.page === "black") renderLists();
    }).catch(function () {
      state.pkgs = []; state.pkgTypes = {};
      scheduleRetry("packages");
    });
  }
  var retryTimer = null, retryCount = 0;
  function scheduleRetry(what) {
    // One automatic retry for transient backend failures (flaky exec/host).
    // Persistent failure surfaces one honest toast instead of fake-empty UI.
    if (retryCount >= 1) {
      toast("Backend tidak stabil (" + what + ") — tekan Refresh.", "err");
      return;
    }
    retryCount++;
    if (retryTimer) return;
    retryTimer = setTimeout(function () {
      retryTimer = null;
      if (what === "packages") loadPackages();
      else refreshLight();
    }, 1500);
  }
  function noteOk() { retryCount = 0; }
  function fastJobs(failed) {
    function guard(p, name) {
      return p.catch(function () { failed.push(name); });
    }
    return [
      guard(backend.status().then(function (s) { state.status = s; }), "status"),
      guard(backend.listGames().then(function (g) { state.games = g; }), "games"),
      guard(backend.listBlack().then(function (b) { state.black = b; }), "blacklist"),
      guard(backend.listWhite().then(function (w) { state.white = w; }), "whitelist"),
      guard(backend.logs().then(function (l) { state.logs = l; }), "logs"),
      guard(backend.fullConfig().then(function (c) { state.config = c; }), "config")
    ];
  }
  function refresh(full) {
    var failed = [];
    return Promise.all(fastJobs(failed)).then(function () {
      render();
      if (failed.length) scheduleRetry("refresh"); else noteOk();
      if (full) return loadPackages().then(loadIconBatch);
    });
  }
  function refreshLight() {
    // After toggles/profile changes: fast lists only, reuse package cache.
    // (packages() can block the WebView thread for seconds — never here.)
    var failed = [];
    return Promise.all(fastJobs(failed)).then(function () {
      render();
      if (failed.length) scheduleRetry("refresh"); else noteOk();
    });
  }
  function runDiag() {
    $("diagBox").innerHTML = '<div class="skel" style="height:120px"></div>';
    $("diagDevBox").innerHTML = "";
    backend.diag().then(function (d) {
      var dev = d.device || {};
      var caps = d.caps || {};
      var bi = (backend && backend.bridgeInfo) || {};
      var capRows = ["pm", "dumpsys", "am", "cmd", "getprop"].map(function (k) {
        var v = caps[k] || "?";
        var cls = v === "yes" ? "b-green" : "b-red";
        return '<div class="kv"><span class="mono">' + esc(k) + '</span><b><span class="badge ' + cls + '">' + esc(v) + "</span></b></div>";
      }).join("");
      var fgNote = { none: "deteksi dinonaktifkan (graceful)", activity: "ok", window: "ok (fallback)" }[caps.foreground] || esc(caps.foreground || "?");
      $("diagDevBox").innerHTML =
        '<div class="kv"><span>Manufacturer</span><b>' + esc(dev.manufacturer || "Unknown") + "</b></div>" +
        '<div class="kv"><span>Model</span><b>' + esc(dev.model || "Unknown") + "</b></div>" +
        '<div class="kv"><span>Android</span><b>' + esc(dev.android || "Unknown") + " (SDK " + esc(dev.sdk || "?") + ")</b></div>" +
        '<div class="kv"><span>Root manager</span><b>' + esc(dev.root || "Not detected") + "</b></div>" +
        '<div class="kv"><span>Detected launcher</span><b class="mono">' + esc(caps.launcher || "Not detected") + "</b></div>" +
        '<div class="kv"><span>Foreground source</span><b>' + fgNote + "</b></div>" +
        '<div class="kv"><span>Package query</span><b class="mono">' + esc(caps.pkg_query || "?") + "</b></div>" +
        '<div class="kv"><span>Kill method</span><b class="mono">' + esc(caps.kill || "?") + "</b></div>";
      $("diagBox").innerHTML = capRows +
        '<div class="kv"><span>WebView bridge</span><b class="mono">' + esc(bi.found || "none (preview)") + "</b></div>" +
        '<div class="kv"><span>Bridge exec</span><b>' + (bi.found ? (bi.exec ? "granted" : "DENIED") : "n/a") + "</b></div>" +
        '<div class="kv"><span>Module dir</span><b class="mono">' + esc(bi.moddir || "n/a") + "</b></div>" +
        (bi.found && !bi.exec ? '<div class="kv"><span>Permission</span><b>' + esc(bi.perm || "") + "</b></div>" : "") +
        '<div class="kv"><span>Session lock</span><b class="mono">' + esc(d.session_lock) + "</b></div>" +
        '<div class="kv"><span>Files</span><b class="mono">' + esc(d.files) + "</b></div>" +
        '<div class="kv"><span>Boot completed</span><b class="mono">' + esc(d.boot_completed) + "</b></div>" +
        '<div class="kv"><span>Cached icons</span><b class="mono">' + esc(d.icons_cached == null ? "?" : d.icons_cached) + "</b></div>" +
        '<div class="kv"><span>Backend</span><b class="mono">' + esc(backend.mode) + "</b></div>";
    }).catch(function () { $("diagBox").innerHTML = '<div class="empty">Diagnostic gagal — backend tidak merespons.</div>'; });
  }

  /* ---------- boot ---------- */
  document.addEventListener("DOMContentLoaded", function () {
    buildNav();
    // Global UI error boundary: surfaces instead of silent death.
    window.addEventListener("error", function (ev) {
      try { toast("UI error: " + ((ev && ev.message) || "unknown"), "err"); } catch (e) {}
    });
    bindDelegated($("gamesList"), onListChange);
    bindDelegated($("whiteList"), onListChange);
    bindDelegated($("blackList"), onListChange);
    // Debounced, targeted rendering: typing must not rebuild every page.
    function debounce(fn, ms) {
      var t = null;
      return function () { clearTimeout(t); t = setTimeout(fn, ms || 180); };
    }
    $("qGames").addEventListener("input", debounce(renderGames));
    $("qWhite").addEventListener("input", debounce(renderLists));
    $("qBlack").addEventListener("input", debounce(renderLists));
    $("qLogs").addEventListener("input", debounce(renderLogs));
    $("fLogs").addEventListener("change", render);
    $("btnRefresh").addEventListener("click", function () { refresh(true); });
    $("btnDiag").addEventListener("click", runDiag);
    $("btnRestart").addEventListener("click", function () {
      var b = $("btnRestart");
      b.disabled = true;
      backend.restartService().then(function (r) {
        b.disabled = false;
        if (r && r.ok) { toast("Core (re)start diminta — tunggu boot/daemon lalu Refresh", "ok"); setTimeout(function () { refreshLight(); }, 4000); }
        else toast("Restart gagal (mode pratinjau?)", "err");
      }).catch(function () { b.disabled = false; toast("Restart gagal", "err"); });
    });
    $("btnIconProbe").addEventListener("click", function () {
      // One-tap icon pipeline probe with visible result (for bug reports).
      var box = $("iconProbeBox");
      var target = ((state.games[0] && state.games[0].package) || ((state.pkgs[0] && state.pkgs[0].pkg)) || "");
      if (!target) { box.innerHTML = '<div class="empty">Tidak ada package untuk diuji.</div>'; return; }
      box.innerHTML = '<div class="skel" style="height:60px"></div>';
      var t0 = Date.now();
      backend.icon(target).then(function (url) {
        var ms = Date.now() - t0;
        if (url) {
          box.innerHTML = '<div class="kv"><span>Icon probe</span><b>' + esc(target) + " • " + ms + 'ms</b></div><div style="margin:8px 0"><img alt="probe" style="width:72px;height:72px;border-radius:16px"></div>';
          box.querySelector("img").src = url;
        } else {
          box.innerHTML = '<div class="empty"><div class="big">Icon null</div>Backend mengembalikan kosong untuk ' + esc(target) + " (" + ms + "ms) — helper Java mungkin gagal render ikon ini.</div>";
        }
      }).catch(function (e) {
        box.innerHTML = '<div class="empty"><div class="big">Icon exec gagal</div>' + esc(String((e && e.message) || e)) + "</div>";
      });
    });
    [["tabsGames", "tabGames", "renderGames"], ["tabsWhite", "tabWhite", "renderLists"], ["tabsBlack", "tabBlack", "renderLists"]].forEach(function (pair) {
      $(pair[0]).querySelectorAll(".tab").forEach(function (b) {
        b.addEventListener("click", function () {
          state[pair[1]] = b.dataset.t;
          $(pair[0]).querySelectorAll(".tab").forEach(function (x) { x.classList.toggle("active", x === b); });
          if (pair[2] === "renderGames") renderGames(); else renderLists();
        });
      });
    });
    window.FGCBackend.create().then(function (b) {
      backend = b;
      var bi = (backend && backend.bridgeInfo) || {};
      if (bi.found && !bi.exec) {
        toast("Bridge " + bi.found + ": exec ditolak — beri izin SHELL ke modul, lalu Refresh.", "err");
      }
      return refresh(true);
    }).then(function () { nav("home"); runDiag(); });
  });
})();
