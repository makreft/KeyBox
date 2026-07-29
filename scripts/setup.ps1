<#
.SYNOPSIS
    KeyBox - Entwicklungsumgebung einrichten (Windows)

.DESCRIPTION
    Installiert PlatformIO Core, laedt die SAMD21-Toolchain und die
    Bibliotheken, ergaenzt den PATH und baut das Projekt zur Kontrolle.

    Aufruf aus dem Projektverzeichnis:

        powershell -ExecutionPolicy Bypass -File scripts\setup.ps1

    Das Skript ist idempotent: mehrfaches Ausfuehren schadet nicht.

.PARAMETER SkipEditor
    Keine VSCodium-/VS-Code-Extensions installieren.

.PARAMETER SkipPath
    Den Benutzer-PATH nicht veraendern.
#>

param(
    [switch]$SkipEditor,
    [switch]$SkipPath
)

$ErrorActionPreference = 'Stop'

$ProjectDir = Split-Path -Parent $PSScriptRoot
$PioHome    = Join-Path $env:USERPROFILE '.platformio'
$Penv       = Join-Path $PioHome 'penv'
$PioExe     = Join-Path $Penv 'Scripts\pio.exe'
$PipExe     = Join-Path $Penv 'Scripts\pip.exe'

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    + $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    ! $msg" -ForegroundColor Yellow }
function Die($msg)  { Write-Host "`nFehler: $msg" -ForegroundColor Red; exit 1 }

Write-Host "KeyBox - Einrichtung (Windows)" -ForegroundColor White
Write-Host "Projekt: $ProjectDir"

# ---------------------------------------------------------------- Python ----
Step 'Python pruefen'

$Python = $null
foreach ($cand in @('python', 'py')) {
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if (-not $cmd) { continue }
    # Windows legt Platzhalter-Stubs an, die den Store oeffnen statt zu starten
    try {
        $ver = & $cand -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>$null
        if ($LASTEXITCODE -eq 0 -and $ver) {
            $parts = $ver.Split('.')
            if ([int]$parts[0] -ge 3 -and [int]$parts[1] -ge 6) { $Python = $cand; break }
        }
    } catch { }
}

if (-not $Python) {
    Die @"
Python 3.6+ nicht gefunden.

    Von https://www.python.org/downloads/ installieren und dabei
    'Add Python to PATH' ankreuzen. Danach ein NEUES Terminal oeffnen.

    Der Python-Stub aus dem Microsoft Store funktioniert nicht zuverlaessig.
"@
}
Ok (& $Python --version 2>&1)

# ------------------------------------------------------- PlatformIO Core ----
Step 'PlatformIO Core installieren'

if (Test-Path $PioExe) {
    Ok "vorhanden: $(& $PioExe --version 2>&1)"
    Write-Host '    aktualisiere...'
} else {
    Write-Host "    lege virtuelle Umgebung an: $Penv"
    New-Item -ItemType Directory -Force -Path $PioHome | Out-Null
    & $Python -m venv $Penv
    if ($LASTEXITCODE -ne 0) { Die 'venv konnte nicht angelegt werden.' }
}

& $PipExe install --quiet --upgrade pip
if ($LASTEXITCODE -ne 0) { Die 'pip-Update fehlgeschlagen.' }
& $PipExe install --quiet --upgrade platformio
if ($LASTEXITCODE -ne 0) { Die 'PlatformIO-Installation fehlgeschlagen.' }
Ok (& $PioExe --version 2>&1)

# ------------------------------------------------------------------ PATH ----
if (-not $SkipPath) {
    Step 'PATH ergaenzen'
    $Scripts  = Join-Path $Penv 'Scripts'
    $UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($UserPath -and ($UserPath -split ';' | Where-Object { $_ -eq $Scripts })) {
        Ok 'bereits enthalten'
    } else {
        $new = if ([string]::IsNullOrEmpty($UserPath)) { $Scripts } else { "$UserPath;$Scripts" }
        [Environment]::SetEnvironmentVariable('Path', $new, 'User')
        Ok "$Scripts zum Benutzer-PATH hinzugefuegt"
        Warn 'Gilt erst in einem NEUEN Terminal.'
    }
}

# -------------------------------------------------- Toolchain und Libs ------
Step 'Toolchain, Framework und Bibliotheken laden'
Write-Host '    Das sind rund 200 MB und dauert beim ersten Mal einige Minuten.'

Set-Location $ProjectDir
& $PioExe pkg install
if ($LASTEXITCODE -ne 0) { Die 'Abhaengigkeiten konnten nicht geladen werden (Netzwerk?).' }
Ok 'Pakete vollstaendig'

# ---------------------------------------------------------------- Treiber ---
Step 'USB-Treiber'
Ok 'Der EDBG meldet sich als HID-Geraet, Windows bringt den Treiber mit.'
Write-Host '    Falls der Upload spaeter kein Geraet findet: Zadig starten und'
Write-Host '    fuer den EDBG-Anteil WinUSB installieren (https://zadig.akeo.ie).'

# ------------------------------------------------------------- Editor ------
if (-not $SkipEditor) {
    Step 'Editor-Extensions'

    $EditorCli = $null
    foreach ($cand in @('codium', 'code')) {
        if (Get-Command $cand -ErrorAction SilentlyContinue) { $EditorCli = $cand; break }
    }

    if (-not $EditorCli) {
        Warn 'Weder codium noch code gefunden - uebersprungen'
    } else {
        # VSCodium benutzt Open VSX, dort liegt die offizielle
        # platformio.platformio-ide nicht. Der angepasste Port heisst anders.
        $PioExt = if ($EditorCli -eq 'codium') { 'LordImmaculate.platformio-ide' }
                  else { 'platformio.platformio-ide' }

        foreach ($ext in @($PioExt, 'llvm-vs-code-extensions.vscode-clangd')) {
            & $EditorCli --install-extension $ext 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { Ok $ext } else { Warn "$ext liess sich nicht installieren" }
        }
    }
}

# ------------------------------------------------------ Gegenprobe ---------
Step 'Gegenprobe: Projekt bauen'
& $PioExe run
if ($LASTEXITCODE -ne 0) { Die 'Der Build ist fehlgeschlagen. Ausgabe oben pruefen.' }
Ok 'Build erfolgreich'

Step 'compile_commands.json fuer clangd'
& $PioExe run -t compiledb 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { Ok 'erzeugt' } else { Warn 'fehlgeschlagen (unkritisch)' }

# ------------------------------------------------------------ Abschluss ----
Write-Host ''
Write-Host ' Fertig.' -ForegroundColor White
Write-Host @"

 Naechste Schritte:

   1. Board am Programming-Port anstecken (die USB-Buchse naeher am Reset-Knopf)
   2. Flashen:   pio run -t upload
   3. WICHTIG:   USB einmal abziehen und wieder anstecken
                 Ohne das startet die Firmware nicht - siehe README
   4. Monitor:   pio device monitor

 Verkabelung steht im README. Das Wichtigste: SDA an D2 und SCL an D3,
 NICHT an die Pins SDA/SCL neben AREF.

"@
