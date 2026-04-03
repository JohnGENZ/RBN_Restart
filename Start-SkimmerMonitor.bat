@echo off
:: Start-SkimmerMonitor.bat
:: Place this file in your Startup folder:
::   %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
::
:: Launches the Skimmer & Aggregator monitoring script in a minimised window.

start "Skimmer Monitor" /min powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Minimized -File "C:\Scripts\Monitor-Skimmer.ps1"
