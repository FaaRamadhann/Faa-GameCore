# Faa GameCore (FGC)

[![Release](https://img.shields.io/github/v/release/FaaRamadhann/Faa-GameCore?label=release&color=2ea043)](https://github.com/FaaRamadhann/Faa-GameCore/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/FaaRamadhann/Faa-GameCore/total?color=2ea043)](https://github.com/FaaRamadhann/Faa-GameCore/releases)
[![License](https://img.shields.io/github/license/FaaRamadhann/Faa-GameCore?color=blue)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Magisk%20%7C%20KernelSU%20%7C%20Kitsune-6f42c1)](#instalasi)
[![Shell](https://img.shields.io/badge/core-POSIX%20shell-lightgrey)](docs/TEKNIS.md)

Modul **Magisk / KernelSU** untuk mengatur aplikasi latar belakang saat bermain game: blacklist, whitelist, deteksi sesi game otomatis, profil per game, freeze/unfreeze, dan WebUI bertema **Night Blue Sky**.

Tidak ada brand, model, atau ROM yang di-hardcode — semua kemampuan (`pm`, `dumpsys`, `am`, `cmd`) dideteksi saat runtime dengan fallback yang jujur.

---

## Fitur

- **Blacklist** — app yang dihentikan/dibekukan saat game jalan.
- **Whitelist** — app yang selalu dibiarkan hidup (menang atas blacklist).
- **Deteksi game otomatis** — foreground dibaca via `dumpsys`; gamelist menentukan game mana yang memicu sesi.
- **4 profil** — Balance / Performance / Awaken / Auto (berbasis baterai), bisa di-override per game.
- **Freeze reversibel** — `pm disable-user` saat sesi, `pm enable` saat sesi selesai. Tidak pernah permanen.
- **Anti-nyangkut** — jurnal ditulis *sebelum* disable, core dijaga supervisor, dan ada 4 titik pemulihan (akhir sesi, boot, `status`, core dimatikan).
- **WebUI** — kelola game/blacklist/whitelist, lihat log, diagnostics, restart core. Nama app asli + ikon asli.
- **Tanpa permissive** — berjalan di SELinux *Enforcing*; modul tidak pernah menjalankan `setenforce`.
- **Data aman saat update** — semua config user di `/data/adb/fgc/`, tidak pernah ditimpa update modul.

## Instalasi

1. Unduh `faagamecore-vX.Y.Z.zip` dari [Releases](https://github.com/FaaRamadhann/Faa-GameCore/releases/latest).
2. Buka **Magisk / KernelSU / Kitsune** → **Modules** → **Install from storage** → pilih zip.
3. Reboot.

Setelah reboot, buka WebUI modul dari aplikasi manager (atau tekan tombol **Action**), lalu:

1. **Gamelist** → tap game yang ingin dipantau.
2. **Blacklist** → tap app yang ingin dihentikan saat main game.
3. **Settings** → pilih profil default.

Tidak perlu konfigurasi lain. Tanpa game terdaftar, modul hanya idle.

## Profil

| Profil | Yang dilakukan | Cocok saat baterai |
|---|---|---|
| **1 Balance** | Sesi dipantau, tanpa force-stop / freeze | 1–20% |
| **2 Performance** | Force-stop semua target aktif | 21–50% |
| **3 Awaken** | Force-stop + freeze (`disable-user`), di-unfreeze saat sesi berakhir | 51–100% |
| **4 Auto** | Memilih 1/2/3 otomatis dari level baterai | — |

Freeze **selalu** reversibel dan tidak pernah menyentuh app system, whitelist, paket terproteksi, atau game yang sedang foreground. App yang sudah kamu disable sendiri tidak akan disentuh.

## WebUI

| Halaman | Isi |
|---|---|
| **Dashboard** | status core, sesi aktif, profil, tombol start/stop |
| **Gamelist** | semua app terinstal, tab User/System, ikon + label asli |
| **Blacklist / Whitelist** | semua app terinstal, entri aktif ditandai ON |
| **Logs** | `session.log` + tombol clear |
| **Diagnostics** | bridge aktif, kapabilitas ROM, SELinux, versi, restart core |

WebUI memakai bridge manager (`magisk.exec` / `kernelsu.exec` / `ksu.exec`) untuk memanggil `core/fgc-cli.sh` — tanpa HTTP API dan tanpa shell bebas.

## CLI

```sh
su -c 'fgc status'                     # ACTIVE | STARTING | STOPPED | ERROR | DISABLED
su -c 'fgc list games'
su -c 'fgc add blacklist com.example.app'
su -c 'fgc set default_profile 3'
su -c 'fgc session-start com.mobile.legends'
su -c 'fgc session-end'
su -c 'fgc clearlog'
su -c 'fgc diag'                       # JSON: kapabilitas, device, state
```

`session-start` hanya menerima paket yang **terdaftar di gamelist** (selain itu `not-a-game`). `session-end` selalu aman. Berguna untuk trigger eksternal: Tasker, MacroDroid, Zygisk/LSPosed companion.

`status` dan `diag` mencetak JSON **pretty** (satu key per baris) supaya enak dibaca di terminal; WebUI mem-parse byte yang sama, jadi tidak ada format terpisah untuk mesin dan manusia.

## Struktur repo

```
core/       logika: session, policy, process, config, recovery, caps, CLI
config/     default bawaan (disalin sekali saat install)
webroot/    WebUI (index.html, app.js, adapters/backend.js)
system/bin/ shortcut `fgc` (overlay PATH oleh Magisk)
bin/        fgc-pm.dex — helper Java opsional (fast path ikon/label)
tests/      uji host: functional, daemon, POSIX lint, WebUI
build.py    packaging zip rilis
```

Detail arsitektur, aturan keamanan, dan perilaku pemulihan: **[docs/TEKNIS.md](docs/TEKNIS.md)**.

## Build & test

```sh
python build.py                  # -> build/faagamecore-vX.Y.Z.zip
python tests/test_webui.py       # guard WebUI + statis
sh tests/functional.sh           # end-to-end core (stub Android)
sh tests/daemon.sh               # service/supervisor
sh tests/check_syntax.sh         # lint POSIX/mksh
sh tools/version.sh              # bump versi
```

## Troubleshooting

| Gejala | Cek |
|---|---|
| WebUI kosong / "preview" | Buka dari aplikasi manager, bukan browser PC. Bridge butuh izin SHELL. |
| Status `STARTING` | Boot belum selesai (`sys.boot_completed`). Tunggu, lalu refresh. |
| Status `ERROR` | Lihat Diagnostics / `fgc diag`, ada `CORE_ERROR` di log. |
| App tetap aktif saat game | Cek whitelist, tipe paket, dan profil aktif (Balance tidak freeze). |
| Ikon tampil huruf | Ikon dari ROM tidak bisa di-inflate; CLI memakai fallback APK. Lihat `fgc diag`. |

## Lisensi

GNU General Public License v3.0 or later — lihat [LICENSE](LICENSE).
