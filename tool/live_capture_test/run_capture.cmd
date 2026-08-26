@echo off
rem Launches `umacapture_cli capture` from the native build directory; its config paths are
rem ../../-relative. %~dp0 is tool\live_capture_test\.
cd /d "%~dp0..\..\native\cmake-build-release"
".\umacapture_cli.exe" capture %*
