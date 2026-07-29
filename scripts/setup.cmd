@echo off
rem KeyBox - Einrichtung unter Windows
rem
rem   scripts\setup.cmd              alles installieren
rem   scripts\setup.cmd -CheckOnly   nur pruefen, nichts aendern
rem
rem Dieser Wrapper existiert, damit man sich nicht mit der ExecutionPolicy
rem herumschlagen muss. Ein direkter Aufruf von setup.ps1 scheitert auf den
rem meisten Rechnern mit "die Ausfuehrung von Skripts ist deaktiviert".

setlocal
set "PS1=%~dp0setup.ps1"

if not exist "%PS1%" (
    echo Fehler: setup.ps1 nicht gefunden neben dieser Datei.
    exit /b 1
)

rem PowerShell 7 bevorzugen, sonst das mitgelieferte 5.1
where /q pwsh.exe
if %errorlevel%==0 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
)

set "RC=%errorlevel%"
if not "%RC%"=="0" (
    echo.
    echo Die Einrichtung wurde mit Fehlercode %RC% beendet.
    echo Zur Fehlersuche:  scripts\setup.cmd -CheckOnly
)

endlocal & exit /b %RC%
