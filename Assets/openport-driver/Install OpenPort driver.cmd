@echo off
rem Puts a plugged-in Tactrix OpenPort 2.0 on Windows' own USB serial driver, so it gets a COM port.
rem It runs install-openport-driver.ps1 next to it, which asks for administrator rights. See README.txt.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-openport-driver.ps1"
echo.
pause
