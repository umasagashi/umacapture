@echo off
rem Launches the mimic player from the native build directory, which is where it (like the CLI)
rem resolves its ../../-relative config paths from. %~dp0 is tool\live_capture_test\.
cd /d "%~dp0..\..\native\cmake-build-release"
".\umacapture_mimic_player.exe" %*
