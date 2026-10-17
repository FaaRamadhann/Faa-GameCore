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
- UX daftar hitam/putih **selalu menampilkan daftar aplikasi**: entri yang
  sudah ada di `blacklist.txt` / `whitelist.txt` selalu tampil (ON = aktif,
  OFF = penanda `!pkg`), dan aplikasi terinstal lain ikut tampil sebagai
  kandidat — difilter hanya oleh tab User/System dan kotak cari. Jadi tab
  kosong tidak pernah berarti "daftar hilang": selalu ada aplikasi yang bisa
  ditap. Satu tap menambahkan ke daftar. Tanpa tombol Add dan tanpa picker.
  Whitelist ↔ blacklist saling menyembunyikan entri aktif lawannya. Profil per
  game via dropdown di baris game yang ON.

- Di perangkat (Magisk/KernelSU WebView dengan bridge `window.fgc.exec` /
  `window.kernelsu.exec` / `window.magisk.exec`): `MagiskBackend` memanggil
  `sh /data/adb/modules/faagamecore/core/fgc-cli.sh <allowlisted-cmd>` dan
  `pm list packages` — data package **nyata**, bukan mock.
- Di browser PC (tanpa bridge): `LocalBackend` (localStorage) dengan badge
  **preview** jujur; tanpa bridge tidak ada daftar aplikasi — buka dari
  aplikasi host untuk data nyata, tidak ada daftar aplikasi palsu.
- Allowlist command: `status|list|add|remove|toggle|set|diag`. Tidak ada
  arbitrary shell, tidak ada dynamic code execution, package match exact.
- Setiap argumen (termasuk **label game**) di-quote single-quote sebelum masuk
  shell. Label asli Play Store sering mengandung `(`, `&`, `'`, `$`
  ("Picsart AI Photo Editor, Video (PicsArt)", "Clean & Boost") — tanpa quoting,
  `sh` mati di `unexpected '('`, add gagal tanpa sebab jelas dan WebUI
  melaporkan backend tidak stabil.
- `fullConfig` membaca config **user** (`/data/adb/fgc/config/config.json` lewat
  `list config`), bukan salinan bawaan di direktori modul — jadi toggle
  Settings tidak "kembali ke default" setelah update.

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

Unfreeze tahan-gagal: `pm enable` diulang, dan bila tetap gagal entry
**disimpan** (bukan dibuang) untuk dicoba lagi saat sesi berakhir berikutnya /
boot — jadi app tak pernah terjebak disabled permanen. Tiga lapis pengaman:

1. **Jurnal ditulis sebelum disable** (`frozen.txt` diisi *sebelum*
   `pm disable-user`). `disable-user` itu persisten, jadi dulu crash/kill di
   antara perintah dan pencatatan meninggalkan app disabled **tanpa jejak**
   (frozen.txt kosong) — tak ada yang bisa memulihkannya. Sekarang urutannya
   write-ahead; kalau disable ternyata gagal, entry dihapus lagi.
2. **Core dijaga tetap hidup** oleh `service.sh` (restart otomatis bila daemon
   mati). Daemon adalah satu-satunya yang meng-unfreeze saat game ditutup.
3. **Titik pemulihan lain**: akhir sesi, `recovery.sh` saat boot, `status`
   WebUI (bila daemon mati), dan `set enabled false`.

Tipe paket yang tak
bisa dibuktikan (`state/.syspkgs` hilang/kosong) dijawab `unknown` dan
**di-skip** (fail-closed), bukan dianggap user-type.

Whitelist > blacklist > proteksi sistem > pengecualian game-foreground
berlaku di semua profil.

### Kejujuran operasi & SELinux

- Modul **tidak pernah** memaksa SELinux ke `permissive` (tidak ada
  `setenforce` di mana pun) dan tidak mengubah state SELinux global.
- `pm`/`cmd` mencetak hasil ke **stdout**; semua panggilan `pm`/`am` di dalam
  fungsi yang stdout-nya dipakai CLI di-silence (`>/dev/null 2>&1`) agar
  balasan `fgc-cli.sh` selalu JSON valid (`JSON.parse` WebUI tidak rusak).
- Setiap freeze/unfreeze **diverifikasi ke state nyata**
  (`pm list packages -d`): disable yang "sukses" tapi tidak men-disable **tidak**
  dicatat (`not-disabled-after-cmd`), dan enable yang "sukses" tapi app tetap
  disabled **tidak** dilaporkan sukses — entry dipertahankan untuk retry
  (`still-disabled-after-cmd`). Operasi gagal tidak pernah dilaporkan berhasil.
- Unfreeze mencoba dua metode bergantian (`pm enable` dan `cmd package enable`);
  keduanya tidak membutuhkan permissive.
- **Tidak butuh permissive.** Freeze (`pm disable-user`) dan unfreeze (`pm enable`)
  terbukti jalan di perangkat dengan SELinux **Enforcing** — permissive *bukan*
  syarat. Kalau operasi gagal, penyebabnya dicari dulu di logika/parse dan
  state nyata, bukan langsung dilempar ke SELinux.
- Bila policy sistem tetap memblokir operasi, itu dilaporkan apa adanya di
  log/Diagnostics — Diagnostics juga menampilkan mode SELinux aktif
  (`enforcing|permissive|disabled|unknown`).

## Perintah `fgc` (terminal root)

Modul memasang shortcut PATH via overlay `system/bin`:

```sh
su -c 'fgc status'        # ACTIVE | STARTING | STOPPED | ERROR | DISABLED
fgc list blacklist
fgc list config          # config user (bukan salinan modul) — dipakai WebUI Settings
fgc session-start com.mobile.legends
fgc clearlog              # kosongkan /data/adb/fgc/logs/session.log (JSON {"ok":true})
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
- Seed hanya bila file BENAR-BENAR tidak ada (terbukti hilang 2× beruntun,
  bukan sekali baca gagal) — update tidak pernah me-replace data.
- Backfill key config yang ditambahkan rilis baru (nilai custom tetap),
  rescue file corrupt (backup `.bak` + defaults). Rescue **hanya** di boot
  normaliser, bukan saat install/update — install/update tidak pernah menulis
  ulang `config.json` user.
- Folder modul TIDAK di-symlink dan TIDAK ditulis core — hanya default bawaan
  untuk dibaca manusia; semua tulis lewat path absolut kanonis.
- Uninstall TIDAK menghapus `/data/adb/fgc`; reinstall menemukan datanya lagi.

### Format file (mudah dibaca & diedit manual)

`config.json` dan `gamelist.json` ditulis **pretty** (indentasi 4 spasi,
satu key per baris) supaya bisa langsung dibaca/diedit tanpa JSON formatter:

```json
{
    "enabled": true,
    "detection_mode": "hybrid",
    "poll_interval_sec": 3,
    "default_profile": 1,
    "cleanup_policy": "balanced",
    "logging": true,
    "dry_run": false,
    "freeze_system": false,
    "auto_profile_rules": {
        "note": "Auto picks Performance when a listed game is foreground, else Balance. No AI claims.",
        "game_foreground": 2,
        "idle": 1
    }
}
```

- `gamelist.json` kosong = `{"games": []}`; berisi game = dokumen multi-baris
  dengan blok `package`/`label`/`profile` per game.
- Penulis & pembaca terpusat: `core/gamelist.sh` (gamelist) dan
  `core/config_manager.sh` (`fgc_cfg_pretty`/`fgc_cfg_normalize`). Pembaca
  toleran format: file lama satu-baris atau hasil `indent=1` tetap terbaca.
- `fgc_cfg_normalize` (dipanggil `recovery.sh` tiap boot) meng-upgrade file
  lama ke bentuk pretty **hanya setelah** membaca ulang dan membandingkan
  SETIAP nilai; file dengan key tak dikenal dibiarkan apa adanya, dan
  perbaikan (file korup) selalu menyimpan `.bak` lebih dulu.

## Label & ikon aplikasi (Java helper)

`dumpsys` tidak menampilkan label di sebagian ROM dan tidak ada API yang
menyediakan bitmap ikon — satu-satunya sumber adalah `PackageManager`:

- `tools/java/FgcPm.java` → `bin/fgc-pm.dex` (via `tools/build_dex.py`,
  butuh Android SDK) berjalan on-device sebagai root:
  `app_process -Djava.class.path=.../fgc-pm.dex /system/bin FgcPm list|icon|icons|ping`
- `list` = `pkg<TAB>label<TAB>user|system<TAB>versionCode` satu panggilan (lebih
  cepat dari N× `dumpsys`); `icon <pkg>` = base64 PNG 144px; `icons <pkg...>` =
  batch `pkg<TAB>base64` per baris — satu JVM untuk banyak ikon (startup JVM
  yang mahal, jadi satu exec per baris bikin baris menunggu lama dan tampak
  seperti "ikon kadang jadi huruf"). Ikon di-cache di `state/icons/<pkg>.b64`
  dengan key `<versionCode>|g3`, jadi update aplikasi meretire bitmap-nya saja.
- Ikon di-crop ke bounding-box alpha lalu di-scale penuh ke 144px (mask
  rounded-square bawaan ROM, latar **transparan** penuh) supaya tampil penuh
  seperti launcher — bukan kotak putih/bermargin. Penanda generasi `|g3` di
  `<pkg>.ver` meretire cache renderer lama sekali saja.
- Context diperoleh tanpa ActivityThread: `Looper.prepareMainLooper()` dulu
  (tanpa ini abort `Can't create handler...`), lalu `systemMain()` dengan
  fallback berlapis — semua kegagalan dicetak bersih ke stderr + exit≠0.
- Bila helper gagal (ROM memblokir `app_process`, dsb.): otomatis fallback ke
  `pm`+`dumpsys`; `caps.javahlp` di `diag` melaporkan `yes`/`no` dengan jujur.
  WebUI memakai avatar huruf hanya bila ikon benar-benar tak tersedia (dibatasi
  4 percobaan batch per baris); antrean ikon diambil per-chunk (≤8 package per
  exec) plus timeout per-exec sehingga satu exec yang menggantung tidak
  membekukan sisa baris.
- Kalau `PackageManager` melempar exception saat inflate ikon (khas MIUI/HyperOS
  tanpa `/data/system/theme_config/theme_compatibility.xml`), helper mengembalikan
  kosong dan CLI mengambil bitmap **langsung dari APK** (`unzip -l`/`unzip -p`,
  `ic_launcher`/`app_icon` densitas tertinggi, layer `foreground`/`background`
  dilewati) — tanpa Java sama sekali. Hasilnya ikon asli, bukan huruf.

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
python3 build.py                 # -> build/faagamecore-v1.3.1.zip
python3 tests/test_webui.py
sh tests/test_core.sh
sh tests/check_syntax.sh         # POSIX syntax + lint mksh: '|' di dalam ${...} dilarang
sh tools/version.sh              # bump patch -> 1.3.1 (132)
```

> Catatan portabilitas: di Android `/system/bin/sh` (mksh) sebuah `|` di dalam
> `${...}` berarti **alternasi pola**, jadi `${v#GAME|}` mengembalikan string utuh.
> bash menoleransinya sehingga lolos test lokal — karena itu ada lint statis di
> `check_syntax.sh` dan `tests/test_webui.py` yang menolak pola tersebut.

## Keterbatasan

- HTTP loopback API tidak disediakan (risiko root API) — komunikasi via exec
  bridge / CLI. Jika bridge tidak ada (Magisk app tanpa WebUI exec), gunakan
  `fgc-cli.sh` via terminal root atau edit config lalu reboot.
- Deteksi foreground memakai `dumpsys` bila tersedia — pada sebagian ROM perlu
  permission root; jika tidak ada, FGC idle secara graceful dan menjelaskannya
  di Diagnostics (bukan klaim kompatibilitas buta).
- Force-stop bersifat destruktif parsial: klaim "pemulihan penuh" tidak dibuat.
- Bila ROM/ kebijakan sistem memblokir `pm`/`cmd` enable/disable dari konteks
  root modul, operasi dilaporkan gagal (bukan sukses palsu) dan entry freeze
  dipertahankan untuk retry/boot. Modul tidak menurunkan SELinux sebagai
  workaround.
