# Detail teknis

Dokumen ini menjelaskan cara kerja internal Faa GameCore. Untuk instalasi dan pemakaian, lihat [README](../README.md).

## Struktur

```
FaaGameCore/
├── module.prop / service.sh / action.sh / uninstall.sh / customize.sh
├── core/  main, event_detector, foreground_monitor, session_controller,
│          policy_engine, process_manager, config_manager, logger, recovery,
│          supervise (penjaga daemon), caps (capability detection),
│          device (detected device info), str (portable string helpers),
│          data_init (persistent storage), fgc-cli
├── config/ config.json, gamelist.json, blacklist.txt, whitelist.txt
├── state/ logs/
├── webroot/ index.html, style.css, app.js, adapters/backend.js
├── bin/ fgc-pm.dex (helper Java opsional)
├── system/bin/fgc (shortcut CLI)
├── tools/version.sh  build.py  tests/  README.md
```

Nama folder wajib `webroot` agar WebUI terdeteksi Magisk.

## WebUI → Core

```
WebUI -> adapters/backend.js (Frontend Adapter) -> core/fgc-cli.sh (Backend Interface)
      -> core/* (policy/session/process) -> pm / am
```

Bridge dideteksi berurutan (yang pertama tersedia dipakai):

| Host | Bridge | Keterangan |
|---|---|---|
| WebUI X / MMRL | `window.ksu.exec` (sync) + `listPackages("user"\|"system")`, `getPackagesInfo`, `moduleInfo` | tercepat: label & tipe langsung dari PackageManager, moduleDir exact |
| KernelSU manager | `window.kernelsu.exec` (Promise) | via `fgc-cli.sh` + `pm` |
| Lainnya | `window.magisk.exec` / `window.fgc.exec` | via `fgc-cli.sh` + `pm` |
| Browser PC | LocalBackend (localStorage, badge preview) | tanpa daftar app palsu |

- WebUI X mengharuskan izin **SHELL** untuk modul — bila ditolak, WebUI tetap jujur: mode pratinjau + alasan + toast, bukan diam-diam mock.
- Header/diag menampilkan bridge aktif + module dir terdeteksi.
- Tab **User App | System App** di Gamelist, Whitelist, dan Blacklist memakai tipe real (`pm -s` / `listPackages`); entri bertipe tak dikenal tampil di kedua tab dengan jujur.
- Daftar hitam/putih **selalu menampilkan daftar aplikasi**: entri yang sudah ada di `blacklist.txt` / `whitelist.txt` selalu tampil (ON = aktif, OFF = penanda `!pkg`), dan aplikasi terinstal lain ikut tampil sebagai kandidat — difilter hanya oleh tab User/System dan kotak cari. Tab kosong tidak pernah berarti "daftar hilang". Satu tap menambahkan ke daftar. Tanpa tombol Add dan tanpa picker. Whitelist ↔ blacklist saling menyembunyikan entri aktif lawannya. Profil per game via dropdown di baris game yang ON.
- Di perangkat: `MagiskBackend` memanggil `sh /data/adb/modules/faagamecore/core/fgc-cli.sh <allowlisted-cmd>` dan `pm list packages` — data package **nyata**, bukan mock.
- Allowlist command: `status|list|add|remove|toggle|set|diag`. Tidak ada arbitrary shell, tidak ada dynamic code execution, package match exact.
- Setiap argumen (termasuk **label game**) di-quote single-quote sebelum masuk shell. Label asli Play Store sering mengandung `(`, `&`, `'`, `$` — tanpa quoting, `sh` mati di `unexpected '('`.
- `fullConfig` membaca config **user** (`/data/adb/fgc/config/config.json` lewat `list config`), bukan salinan bawaan di direktori modul — toggle Settings tidak "kembali ke default" setelah update.
- Bridge `exec(cmd)` pada Kitsune/Magisk mengembalikan **baris terakhir** output saja. Adapter memakai bentuk callback + probe, dan menandai `degraded` bila host hanya mendukung bentuk lama.

## Profil (perilaku nyata, bukan label)

| Profil | Scope cleanup | Keterangan |
|---|---|---|
| 1 Balance | Normal: sesi dipantau, tanpa force-stop/freeze | cocok saat baterai rendah (1–20%) |
| 2 Performance | force-stop semua target aktif, **tanpa** freeze | cocok saat baterai 21–50% |
| 3 Awaken | force-stop + **freeze** (`disable-user`), + sapuan ulang terbatas | unfreeze otomatis saat sesi berakhir; cocok saat baterai 51–100% |
| 4 Auto | baterai 1–20 → 1, 21–50 → 2, 51–100 → 3 | baterai tak terbaca → Balance |

Freeze selalu reversibel (`pm enable`), tidak pernah menyentuh tipe-system / whitelist/proteksi/game-foreground, dilewati saat dry-run. Aplikasi yang sudah di-disable manual tidak disentuh (tercatat `already-disabled`).

Tipe paket yang tak bisa dibuktikan (`state/.syspkgs` hilang/kosong) dijawab `unknown` dan **di-skip** (fail-closed), bukan dianggap user-type.

Urutan prioritas di semua profil: **whitelist > blacklist > proteksi sistem > pengecualian game-foreground**.

## Tiga lapis pengaman freeze

Unfreeze tahan-gagal: `pm enable` diulang, dan bila tetap gagal entry **disimpan** (bukan dibuang) untuk dicoba lagi saat sesi berakhir berikutnya / boot.

1. **Jurnal ditulis sebelum disable** — `frozen.txt` diisi *sebelum* `pm disable-user`. `disable-user` itu persisten, jadi crash di antara perintah dan pencatatan dulu meninggalkan app disabled **tanpa jejak**. Sekarang urutannya write-ahead; kalau disable ternyata gagal, entry dihapus lagi.
2. **Core dijaga tetap hidup** oleh `core/supervise.sh` (dijalankan `service.sh` di latar belakang): restart ~10 detik bila daemon mati/crash. Daemon adalah satu-satunya yang meng-unfreeze saat game ditutup. Restart saat game masih jalan tidak meng-unfreeze apa pun (`recovery.sh` melewati unfreeze bila `session.lock` masih hidup).
   - **Satu supervisor saja**: `supervise.lock` berisi PID yang divalidasi lewat `/proc/<pid>/cmdline`, dan hanya pemilik lock yang menghapusnya (supervisor lama yang telat keluar tidak boleh menghapus lock milik yang baru).
   - **Restart core = ganti daemon, bukan ganti supervisor.** Kalau supervisor hidup, `service.sh` hanya membunuh daemon; supervisor menghidupkannya lagi dari file di disk. Mengganti supervisor tiap restart dulu meninggalkan supervisor ganda (supervisor bisa mem-fork daemon tepat setelah sapuan yang menyimpulkan ia sudah mati).
   - **Kode baru tetap terpakai setelah update**: daemon baru memeriksa `core.epoch` (ditulis `service.sh`) dan pensiun sendiri bila sudah disusupi epoch baru, sehingga daemon yang telat mati (TERM tertunda saat di dalam `pm`/`dumpsys`) tidak berjalan berdampingan. `supervise.sh` membandingkan `mtime+size` dirinya dan `exec` dirinya sendiri bila file berubah (PID & lock dipertahankan).
3. **Titik pemulihan lain** — akhir sesi, `recovery.sh` saat boot, `status` WebUI (bila daemon mati), dan `set enabled false`. Semua jujur: kalau enable tidak terbukti, entry tetap disimpan untuk dicoba lagi (throttle 1×/menit supaya tidak jadi badai `pm`).
   - **Disable yang mendarat terlambat.** Daemon yang di-`SIGKILL` (LMK, atau user menghentikan paksa) saat freeze bisa meninggalkan `pm disable-user` yang masih di jalan. Disable itu mendarat *setelah* pass unfreeze selesai — entry sudah dipensiunkan karena app masih terlihat enabled — sehingga app disabled dengan jurnal **kosong**: satu-satunya keadaan tanpa jalan pulih. `recovery.sh` menyimpan salinan entry yang akan dipensiunkan, lalu menjalankan pass unfreeze yang sama sekali lagi setelah sistem tenang (2 detik). Pass kedua itu idempoten: app yang memang enabled dipensiunkan lagi, paket yang hilang tetap dipensiunkan, dan disable yang telat dibatalkan.
4. **`status` dan `diag` ditulis pretty** (satu key per baris, indentasi 4 spasi) karena dibaca manusia di terminal; WebUI tetap `JSON.parse` byte yang sama. Sub-objek `device`/`caps` dilayout satu key per baris oleh helper `jbody` — nilainya scalar yang sudah disanitasi (tanpa kutip, koma, newline), jadi pemisahan per koma eksak.

Lock `session.lock` divalidasi lewat `/proc/<pid>/cmdline`, jadi PID yang sudah dipakai proses lain tidak dianggap sesi hidup.

## Kejujuran operasi & SELinux

- Modul **tidak pernah** memaksa SELinux ke `permissive` (tidak ada `setenforce` di mana pun) dan tidak mengubah state SELinux global.
- `pm`/`cmd` mencetak hasil ke **stdout**; semua panggilan `pm`/`am` di dalam fungsi yang stdout-nya dipakai CLI di-silence (`>/dev/null 2>&1`) agar balasan `fgc-cli.sh` selalu JSON valid.
- Setiap freeze/unfreeze **diverifikasi ke state nyata** (`pm list packages -d`): disable yang "sukses" tapi tidak men-disable **tidak** dicatat (`not-disabled-after-cmd`), dan enable yang "sukses" tapi app tetap disabled **tidak** dilaporkan sukses — entry dipertahankan untuk retry (`still-disabled-after-cmd`). Operasi gagal tidak pernah dilaporkan berhasil.
- Snapshot `pm list packages -d` yang **kosong** tidak pernah dipercaya: kosong bisa berarti "tidak ada yang disabled" atau "service tidak menjawab". Untuk bukti positif dipakai `pm list packages -e`; paket yang tidak ada di `-d` maupun `-e` berarti tidak terpasang, jadi entry jurnal dipensiunkan (bukan di-retry selamanya).
- Pencocokan nama paket selalu exact (`grep -x -F`), bukan regex — titik pada `com.example.app` bukan wildcard.
- Unfreeze mencoba dua metode bergantian (`pm enable` dan `cmd package enable`); keduanya tidak membutuhkan permissive.
- Freeze dan unfreeze terbukti jalan di SELinux **Enforcing**. Kalau operasi gagal, penyebabnya dicari dulu di logika/parse dan state nyata, bukan langsung dilempar ke SELinux.
- Bila policy sistem tetap memblokir, itu dilaporkan apa adanya di log/Diagnostics (yang juga menampilkan mode SELinux aktif).

## Status & daemon

Status jujur tanpa PID file: `daemon.lock` = daemon hidup; `STARTING` = boot belum selesai; `ERROR` = ada `CORE_ERROR` di 20 baris log terakhir. Tombol **Restart core** di Diagnostics menjalankan ulang `service.sh`; bila supervisor masih hidup ia hanya mengganti daemon (kode di disk langsung dipakai), dan bila tidak ada supervisor ia memulai satu. `service.sh` langsung kembali, jadi bridge WebUI tidak menggantung; supervisor hidup di `core/supervise.sh`.

## Universal compatibility

- Tidak ada brand/model/ROM yang di-hardcode. Proteksi sistem hanya mencakup paket OS-kritis (`android`, `com.android.systemui`, `com.android.phone`, `com.android.shell`); launcher dideteksi saat install dan boot lalu dilindungi dinamis — tidak pernah menebak nama.
- Default whitelist hanya berisi entri universal; game/blacklist/whitelist 100% diatur user.
- Bila `dumpsys` tidak ada, deteksi turun ke IDLE dengan `CORE_ERROR` di log; Diagnostics menampilkan kapabilitas yang tersedia (`pm`, `dumpsys`, `am`, `cmd`, `getprop`).

## Data persisten (aman dari update)

Magisk menghapus `$MODDIR` setiap update — karena itu SEMUA data user tinggal di **`/data/adb/fgc/`** (`config/`, `state/`, `logs/`), BUKAN di folder modul. `core/data_init.sh` (dipanggil `customize.sh` saat install + `recovery.sh` saat boot) menangani seed/impor/migrasi; `core/paths.sh` membuat seluruh core memakai path absolut kanonis (`$FGC_CONFIG/$FGC_STATE/$FGC_LOGS`) sehingga identitas folder modul yang berbeda (mirror path, update dir, salinan manual) tidak pernah memecah state atau menduplikasi daemon.

- Membuat `/data/adb/fgc` bila belum ada.
- **Update dari versi lama**: mengimpor `config.json`, `gamelist.json`, `blacklist.txt`, `whitelist.txt` (+ `session.log`) dari folder modul lama sebelum dihapus — file user tidak pernah dioverwrite.
- Seed hanya bila file BENAR-BENAR tidak ada (terbukti hilang 2× beruntun, bukan sekali baca gagal).
- Backfill key config baru (nilai custom tetap); rescue file korup (backup `.bak` + defaults) **hanya** di boot normaliser, bukan saat install/update.
- Folder modul TIDAK di-symlink dan TIDAK ditulis core — hanya default bawaan untuk dibaca manusia.
- Uninstall TIDAK menghapus `/data/adb/fgc`; reinstall menemukan datanya lagi.

### Format file (mudah dibaca & diedit manual)

`config.json` dan `gamelist.json` ditulis **pretty** (indentasi 4 spasi, satu key per baris):

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

- `gamelist.json` kosong = `{"games": []}`; berisi game = dokumen multi-baris dengan blok `package`/`label`/`profile` per game.
- Penulis & pembaca terpusat: `core/gamelist.sh` dan `core/config_manager.sh` (`fgc_cfg_pretty`/`fgc_cfg_normalize`). Pembaca toleran: file lama satu-baris atau hasil `indent=1` tetap terbaca.
- `fgc_cfg_normalize` meng-upgrade file lama ke bentuk pretty **hanya setelah** membaca ulang dan membandingkan SETIAP nilai; file dengan key tak dikenal dibiarkan apa adanya, dan perbaikan file korup selalu menyimpan `.bak` lebih dulu.

## Label & ikon aplikasi (Java helper, opsional)

Java **bukan syarat**. Semua fitur (daftar app, label, ikon, freeze/unfreeze) jalan penuh tanpa Java; helper hanya mempercepat:

- Tanpa helper: label dari `dumpsys package` per app, ikon diambil dari APK (`unzip`). Benar, tapi ~1 exec per app.
- Dengan helper: satu JVM memberi semua label + ikon sekaligus.

`tools/java/FgcPm.java` → `bin/fgc-pm.dex` (via `tools/build_dex.py`, butuh Android SDK) berjalan on-device sebagai root:

```sh
app_process -Djava.class.path=.../fgc-pm.dex /system/bin FgcPm list|icon|icons|ping
```

- `list` = `pkg<TAB>label<TAB>user|system<TAB>versionCode` satu panggilan; `icon <pkg>` = base64 PNG 144px; `icons <pkg...>` = batch `pkg<TAB>base64` per baris — satu JVM untuk banyak ikon (startup JVM mahal; satu exec per baris bikin baris menunggu lama dan tampak seperti "ikon kadang jadi huruf").
- Ikon di-cache di `state/icons/<pkg>.b64` dengan key `<versionCode>|g3`, jadi update aplikasi meretire bitmap-nya saja.
- Ikon di-crop ke bounding-box alpha lalu di-scale penuh ke 144px (latar transparan) supaya tampil penuh seperti launcher.
- Context diperoleh tanpa ActivityThread: `Looper.prepareMainLooper()` dulu, lalu `systemMain()` dengan fallback berlapis — kegagalan dicetak bersih ke stderr + exit≠0.
- Bila helper gagal (ROM memblokir `app_process`, dsb.): otomatis fallback ke `pm`+`dumpsys`; `caps.javahlp` di `diag` melaporkan `yes`/`no` dengan jujur. WebUI memakai avatar huruf hanya bila ikon benar-benar tak tersedia (maksimal 4 percobaan batch per baris); antrean ikon diambil per-chunk (≤8 package per exec) plus timeout per-exec.
- Kalau `PackageManager` melempar exception saat inflate ikon (khas MIUI/HyperOS tanpa `/data/system/theme_config/theme_compatibility.xml`), helper mengembalikan kosong dan CLI mengambil bitmap **langsung dari APK** (`unzip -l`/`unzip -p`, `ic_launcher`/`app_icon` densitas tertinggi, layer `foreground`/`background` dilewati) — tanpa Java sama sekali.

## Zygisk / LSPosed (companion, opsional)

FGC **tidak** membundel biner Zygisk (`.so`/NDK) atau modul Xposed — core universal tetap murni shell agar bisa diaudit dan jalan di semua ROM. Sebagai gantinya tersedia **contract trigger** untuk framework companion (Zygisk, LSPosed, Tasker, MacroDroid) via root shell:

```sh
su -c "sh /data/adb/modules/faagamecore/core/fgc-cli.sh session-start com.mobile.legends"
su -c "sh /data/adb/modules/faagamecore/core/fgc-cli.sh session-end"
```

`session-start` hanya menerima package yang terdaftar di gamelist (exact-match, selain itu `not-a-game`); `session-end` selalu aman. Deteksi foreground bawaan (`dumpsys`) tetap jalan paralel — trigger companion melengkapi, bukan menggantikan policy.

## Keamanan

Whitelist > blacklist, paket sistem terproteksi, game foreground tidak pernah di-force-stop, satu cleanup per sesi (lock), dry-run tersedia, poll berbasis `sleep` (tanpa busy loop), tidak ada HTTP API, tidak ada shell bebas dari WebUI.

## Catatan portabilitas

Di Android `/system/bin/sh` (mksh) sebuah `|` di dalam `${...}` berarti **alternasi pola**, jadi `${v#GAME|}` mengembalikan string utuh. bash menoleransinya sehingga lolos test lokal — karena itu ada lint statis di `tests/check_syntax.sh` dan `tests/test_webui.py` yang menolak pola tersebut. Shell juga harus POSIX: tanpa `\+`, `\|`, `\{n,m\}` di sed/bre, tanpa `\n` GNU di sed.

## Keterbatasan

- HTTP loopback API tidak disediakan (risiko root API) — komunikasi via exec bridge / CLI. Jika bridge tidak ada, gunakan `fgc-cli.sh` via terminal root atau edit config lalu reboot.
- Deteksi foreground memakai `dumpsys`; pada sebagian ROM perlu permission root. Jika tidak ada, FGC idle secara graceful dan menjelaskannya di Diagnostics.
- Force-stop bersifat destruktif parsial: klaim "pemulihan penuh" tidak dibuat.
- Bila ROM/kebijakan sistem memblokir `pm`/`cmd` enable/disable dari konteks root modul, operasi dilaporkan gagal (bukan sukses palsu) dan entry freeze dipertahankan untuk retry/boot. Modul tidak menurunkan SELinux sebagai workaround.
