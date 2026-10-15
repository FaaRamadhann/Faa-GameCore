@echo off
rem install.bat — push + install modul FGC ke perangkat via adb.
rem   install.bat [nama-zip]     (default: faagamecore-v*.zip terbaru di build\)
rem Reboot TETAP manual sesuai permintaan (adb reboot / tombol power).
setlocal EnableDelayedExpansion
cd /d "%~dp0.."
set ADB=C:\AndroidSDK\platform-tools\adb.exe
if defined ANDROID_SERIAL set DEV=-s %ANDROID_SERIAL%

if not "%~1"=="" (
  set ZIP=%~1
) else (
  set ZIP=
  for /f "delims=" %%f in ('dir /b /o-d "build\faagamecore-v*.zip" 2^>nul') do (
    if not defined ZIP set ZIP=%%f
  )
)
if not defined ZIP (
  echo [FGC] tidak ada build\faagamecore-v*.zip -- jalankan: python build.py
  exit /b 1
)
if not exist "build\%ZIP%" (
  echo [FGC] file tidak ketemu: build\%ZIP%
  exit /b 1
)
echo [FGC] zip : build\%ZIP%
%ADB% %DEV% push "build\%ZIP%" /sdcard/Download/%ZIP% || exit /b 1
echo [FGC] install module...
%ADB% %DEV% shell su -c 'magisk --install-module "/sdcard/Download/%ZIP%"' || exit /b 1
echo.
echo [FGC] SELESAI. Reboot MANUAL sekarang: adb reboot
echo [FGC] Setelah boot: buka WebUI / jalankan: adb shell su -c fgc status
