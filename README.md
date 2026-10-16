# Faa GameCore (FGC)

Universal Magisk module game booster: blacklist / whitelist / game detection / profiles / WebUI (Night Blue Sky).

> **License:** GNU General Public License v3.0 or later — see [LICENSE](LICENSE).

Works on any compatible rooted Android device — no manufacturer, model, or ROM is hardcoded. Capabilities (package query, foreground detection, process control) are probed at runtime (`core/caps.sh`) with graceful fallbacks; device info shown in the UI is detected-only (`Unknown` / `Not detected` when unavailable).

## Struktur

```
FaaGameCore/
├── module.prop / service.sh / action.sh / uninstall.sh / customize.sh
├── core/  main, event_detector, foreground_monitor, session_controller,
│          policy_engine, process_manager, config_manager, logger, recovery,
│          caps (capability detection), device (detected device info),
│          str (portable string helpers), data_init (persistent storage),
│          fgc-cli
├── config/ config.json, gamelist.json, blacklist.txt, whitelist.txt
├── state/ logs/
├── webroot/ index.html, style.css, app.js, adapters/backend.js  (nama folder wajib `webroot` agar WebUI terdeteksi Magisk)
├── tools/version.sh  build.py  tests/  README.md
```

## WebUI → Core

```
WebUI -> adapters/backend.js (Frontend Adapter) -> core/fgc-cli.sh (Backend Interface)
      -> core/* (policy/session/process) -> pm / am
```

Device bridge dideteksi berurutan (yang pertama tersedia dipakai):

| Host | Bridge | Keterangan |
|---|---|---|
| WebUI X / MMRL | `window.ksu.exec` (sync) + `listPackages("user"\|"system")`, `getPackagesInfo`, `moduleInfo` | tercepat: label & tipe langsung dari PackageManager, moduleDir exact |
| KernelSU manager | `window.kernelsu.exec` (Promise) | via `fgc-cli.sh` + `pm` |
| Lainnya | `window.magisk.exec` / `window.fgc.exec` | via `fgc-cli.sh` + `pm` |
| Browser PC | LocalBackend (localStorage, badge preview) | tanpa daftar app palsu |

- WebUI X mengharuskan izin **SHELL** untuk modul — bila ditolak, WebUI tetap
  jujur: mode pratinjau + alasan + toast, bukan diam-diam mock.
- Header/diag menampilkan bridge aktif + module dir terdeteksi.
- Tab **User App | System App** di Gamelist, Whitelist, dan Blacklist memakai
  tipe real (`pm -s` / `listPackages`); entri bertipe tak dikenal tampil di
  kedua tab dengan jujur.
- UX daftar: universe aplikasi terinstal + switch (kanan ON = add/aktif,
  kiri OFF = remove/nonaktif), tanpa tombol Add dan tanpa picker.
  Whitelist ↔ blacklist saling menyembunyikan entri aktif lawannya.
  Profil per game via dropdown di baris game yang ON.

- Di perangkat (Magisk/KernelSU WebView dengan bridge `window.fgc.exec` /
  `window.kernelsu.exec` / `window.magisk.exec`): `MagiskBackend` memanggil
  `sh /data/adb/modules/faagamecore/core/fgc-cli.sh <allowlisted-cmd>` dan
  `pm list packages` — data package **nyata**, bukan mock.
- Di browser PC (tanpa bridge): `LocalBackend` (localStorage) dengan badge
  **preview** jujur; tanpa bridge tidak ada daftar aplikasi — buka dari
  aplikasi host untuk data nyata, tidak ada daftar aplikasi palsu.
- Allowlist command: `status|list|add|remove|toggle|set|diag`. Tidak ada
  arbitrary shell, tidak ada dynamic code execution, package match exact.

## Profiles (perilaku nyata, bukan label)

| Profil | Scope cleanup | Keterangan |
|---|---|---|
| 1 Balance | Normal: sesi dipantau, tanpa force-stop/freeze | cocok saat baterai rendah (1–20%) |
| 2 Performance | force-stop semua target aktif, **tanpa** freeze | cocok saat baterai 21–50% |
| 3 Awaken | force-stop + **freeze** (`disable-user`), + sapuan ulang terbatas | unfreeze otomatis saat sesi berakhir; cocok saat baterai 51–100% |
| 4 Auto | baterai 1–20 → 1, 21–50 → 2, 51–100 → 3 | baterai tak terbaca → Balance |

Freeze selalu reversibel (`pm enable`), tidak pernah menyentuh tipe-system /
whitelist/proteksi/game-foreground, dilewati saat dry-run, dan daftar
`frozen.txt` dipulihkan saat boot bila sesi crash sebelumnya. Aplikasi yang
sudah Anda disable manual tidak disentuh (tercatat `already-disabled`).

Whitelist > blacklist > proteksi sistem > pengecualian game-foreground
berlaku di semua profil.

## Perintah `fgc` (terminal root)

Modul memasang shortcut PATH via overlay `system/bin`:

```sh
su -c 'fgc status'        # ACTIVE | STARTING | STOPPED | ERROR | DISABLED
fgc list blacklist
fgc session-start com.mobile.legends
```

Status jujur tanpa PID file: `daemon.lock` = daemon hidup; `STARTING` =
boot belum selesai; `ERROR` = ada `CORE_ERROR` di 20 baris log terakhir.
Tombol **Restart core** di Diagnostics menjalankan ulang `service.sh`
(idempoten — tidak menduplikasi daemon).

(`fgc-cli` tersedia sebagai alias yang sama.)

## Universal compatibility

- No brand/model/ROM hardcoded. System protection covers only OS-critical
  packages (`android`, `com.android.systemui`, `com.android.phone`,
  `com.android.shell`); the current launcher is **detected at install and boot**
  and protected dynamically — never by name-assumption.
- Default whitelist ships only universal entries; game/blacklist/whitelist are
  100% user-configurable, nothing device-specific is prepopulated.
- If `dumpsys` is unavailable, detection degrades to IDLE with a logged
  `CORE_ERROR` instead of failing; diagnostics shows exactly which
  capabilities (`pm`, `dumpsys`, `am`, `cmd`, `getprop`) the ROM provides.

## Data persisten (aman dari update)

Magisk menghapus `$MODDIR` setiap update — karena itu SEMUA data user tinggal
di **`/data/adb/fgc/`** (`config/`, `state/`, `logs/`), BUKAN di folder modul.
`core/data_init.sh` (dipanggil `customize.sh` saat install + `recovery.sh`
saat boot) menangani seed/impor/migrasi; `core/paths.sh` membuat seluruh core
 memakai path absolut kanonis (`$FGC_CONFIG/$FGC_STATE/$FGC_LOGS`) sehingga
identitas folder modul yang berbeda (mirror path, update dir, salinan manual)
tidak pernah memecah state atau menduplikasi daemon.

- Membuat `/data/adb/fgc` bila belum ada.
- **Update dari versi lama**: mengimpor `config.json`, `gamelist.json`,
  `blacklist.txt`, `whitelist.txt` (+ `session.log`) dari folder modul lama
  sebelum dihapus — file user tidak pernah dioverwrite.
- Backfill key config yang ditambahkan rilis baru (nilai custom tetap),
  rescue file corrupt (backup `.bak` + reseed).
- Mengganti `config/`, `state/`, `logs/` di folder modul dengan symlink ke
  data — seluruh core bekerja tanpa perubahan path.
- Uninstall TIDAK menghapus `/data/adb/fgc`; reinstall menemukan datanya lagi.

## Label & ikon aplikasi (Java helper)

`dumpsys` tidak menampilkan label di sebagian ROM dan tidak ada API yang
menyediakan bitmap ikon — satu-satunya sumber adalah `PackageManager`:

- `tools/java/FgcPm.java` → `bin/fgc-pm.dex` (via `tools/build_dex.py`,
  butuh Android SDK) berjalan on-device sebagai root:
  `app_process -Djava.class.path=.../fgc-pm.dex /system/bin FgcPm list|icon|ping`
- `list` = `pkg<TAB>label<TAB>user|system` satu panggilan (lebih cepat dari
  N× `dumpsys`); `icon <pkg>` = base64 PNG 144px, di-cache di
  `state/icons/<pkg>.b64`.
- Context diperoleh tanpa ActivityThread: `Looper.prepareMainLooper()` dulu
  (tanpa ini abort `Can't create handler...`), lalu `systemMain()` dengan
  fallback berlapis — semua kegagalan dicetak bersih ke stderr + exit≠0.
- Bila helper gagal (ROM memblokir `app_process`, dsb.): otomatis fallback ke
  `pm`+`dumpsys`; `caps.javahlp` di `diag` melaporkan `yes`/`no` dengan jujur.
  WebUI memakai avatar huruf bila ikon tak tersedia.

## Zygisk / LSPosed (companion, opsional)

FGC **tidak** membundel biner Zygisk (`.so`/NDK) atau modul Xposed — core
universal tetap murni shell agar bisa diaudit dan jalan di semua ROM.
Sebagai gantinya FGC menyediakan **contract trigger** yang bisa dipanggil
framework companion (Zygisk, LSPosed, Tasker, MacroDroid) via root shell:

```sh
su -c "sh /data/adb/modules/faagamecore/core/fgc-cli.sh session-start com.mobile.legends"
su -c "sh /data/adb/modules/faagamecore/core/fgc-cli.sh session-end"
```

Aturan: `session-start` hanya menerima package yang **terdaftar di gamelist**
(verifikasi exact-match, selain itu `not-a-game`); `session-end` selalu aman
(hanya menghapus lock). Deteksi foreground bawaan (`dumpsys`) tetap jalan
paralel — trigger companion bersifat melengkapi, bukan menggantikan policy
(whitelist > blacklist > proteksi sistem tetap berlaku).

## Keamanan

Whitelist > blacklist, system packages protected, tidak force-stop game
foreground, satu cleanup per sesi (lock), dry-run tersedia, sleep-based poll
(tanpa busy loop).

## Build / test

```sh
python3 build.py                 # -> build/faagamecore-v1.0.0.zip
python3 tests/test_webui.py
sh tests/test_core.sh
sh tools/version.sh              # bump patch -> 1.0.1 (101)
```

## Keterbatasan

- HTTP loopback API tidak disediakan (risiko root API) — komunikasi via exec
  bridge / CLI. Jika bridge tidak ada (Magisk app tanpa WebUI exec), gunakan
  `fgc-cli.sh` via terminal root atau edit config lalu reboot.
- Deteksi foreground memakai `dumpsys` bila tersedia — pada sebagian ROM perlu
  permission root; jika tidak ada, FGC idle secara graceful dan menjelaskannya
  di Diagnostics (bukan klaim kompatibilitas buta).
- Force-stop bersifat destruktif parsial: klaim "pemulihan penuh" tidak dibuat.
