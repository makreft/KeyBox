<#
.SYNOPSIS
    KeyBox - Entwicklungsumgebung einrichten (Windows)

.DESCRIPTION
    Bevorzugt ueber scripts\setup.cmd aufrufen, das kuemmert sich um die
    ExecutionPolicy:

        scripts\setup.cmd

    Direkt geht auch:

        powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup.ps1

    Installiert PlatformIO Core, laedt die SAMD21-Toolchain samt Bibliotheken,
    installiert die Editor-Extensions und baut das Projekt zur Kontrolle.
    Idempotent - mehrfaches Ausfuehren aktualisiert nur.

.PARAMETER CheckOnly
    Aendert nichts. Prueft nur die Umgebung und gibt einen Bericht aus - der
    erste Schritt, wenn etwas nicht funktioniert.

.PARAMETER SkipEditor
    Keine VSCodium-/VS-Code-Extensions installieren.

.PARAMETER SkipPath
    Den Benutzer-PATH nicht veraendern.

.PARAMETER NoPythonInstall
    Python nicht automatisch per winget nachinstallieren.
#>

param(
    [switch]$CheckOnly,
    [switch]$SkipEditor,
    [switch]$SkipPath,
    [switch]$NoPythonInstall
)

$ErrorActionPreference = 'Stop'

$ProjectDir = Split-Path -Parent $PSScriptRoot
$PioHome    = Join-Path $env:USERPROFILE '.platformio'
$Penv       = Join-Path $PioHome 'penv'
$PenvBin    = Join-Path $Penv 'Scripts'
$PenvPython = Join-Path $PenvBin 'python.exe'
$PioExe     = Join-Path $PenvBin 'pio.exe'

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    + $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    ! $msg" -ForegroundColor Yellow }
function Info($msg) { Write-Host "      $msg" -ForegroundColor DarkGray }
function Die($msg)  { Write-Host "`nFehler: $msg" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# PATH aus der Registry neu einlesen.
#
# Der haeufigste Grund, warum ein frisch installiertes Python nicht gefunden
# wird: das Installationsprogramm schreibt den PATH in die Registry, die
# laufende Shell hat aber noch ihre alte Kopie. Ohne diesen Schritt muesste
# man das Terminal neu oeffnen.
# ---------------------------------------------------------------------------
function Sync-PathFromRegistry {
    try {
        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
        $parts   = @()
        if ($machine) { $parts += $machine }
        if ($user)    { $parts += $user }
        if ($parts.Count -gt 0) { $env:Path = ($parts -join ';') }
    } catch { }
}

# ---------------------------------------------------------------------------
# Prueft eine konkrete python.exe. Gibt "3.12" zurueck oder $null.
# ---------------------------------------------------------------------------
function Test-PythonExe([string]$exe) {
    if ([string]::IsNullOrWhiteSpace($exe)) { return $null }
    if (-not (Test-Path -LiteralPath $exe))  { return $null }

    # Der Microsoft-Store-Stub in WindowsApps startet kein Python, sondern
    # oeffnet den Store. Er sieht auf dem PATH aber wie ein Interpreter aus.
    if ($exe -like '*\WindowsApps\*') { return $null }

    try {
        $out = & $exe -c 'import sys; print(str(sys.version_info[0]) + "." + str(sys.version_info[1]))' 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }

        # Die Ausgabe kann mehrzeilig sein - manche Installationen schreiben
        # vorher noch etwas auf stdout. Deshalb alle Zeilen durchsehen und die
        # erste nehmen, die wie eine Version aussieht, statt blind die erste.
        $m = $null
        foreach ($line in @($out)) {
            if (-not $line) { continue }
            $cand = [regex]::Match(([string]$line).Trim(), '^(\d+)\.(\d+)')
            if ($cand.Success) { $m = $cand; break }
        }
        if (-not $m) { return $null }

        $maj = [int]$m.Groups[1].Value
        $min = [int]$m.Groups[2].Value
        # Untergrenze aus PlatformIOs eigener Metadatenangabe: Requires-Python >=3.6.
        # Bewusst KEINE Obergrenze - neuere Versionen sollen durchgehen.
        if ($maj -lt 3) { return $null }
        if ($maj -eq 3 -and $min -lt 6) { return $null }
        return "$maj.$min"
    } catch { return $null }
}

# ---------------------------------------------------------------------------
# Sammelt alle Python-Kandidaten aus vier Quellen und gibt den mit der
# hoechsten Version zurueck, der wirklich laeuft.
# ---------------------------------------------------------------------------
function Find-Python {
    $cands = New-Object System.Collections.Generic.List[string]

    # 1. py-Launcher fragen. Der kennt auch Installationen, die nicht im PATH
    #    stehen. Wir lassen ihn den echten Interpreterpfad nennen, damit alles
    #    Weitere mit einer normalen exe arbeitet.
    if (Get-Command py -ErrorAction SilentlyContinue) {
        foreach ($flag in @('-3', '')) {
            try {
                if ($flag) { $out = & py $flag -c 'import sys; print(sys.executable)' 2>$null }
                else       { $out = & py       -c 'import sys; print(sys.executable)' 2>$null }
                if ($LASTEXITCODE -eq 0 -and $out) {
                    $p = [string](@($out) | Where-Object { $_ } | Select-Object -First 1)
                    if ($p) { $cands.Add($p.Trim()) }
                }
            } catch { }
        }
    }

    # 2. Alles, was auf dem PATH python heisst. -All, weil oft der Store-Stub
    #    vor der echten Installation liegt.
    foreach ($name in @('python', 'python3')) {
        try {
            Get-Command $name -All -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandType -eq 'Application' -and $_.Source } |
                ForEach-Object { $cands.Add($_.Source) }
        } catch { }
    }

    # 3. Registry. Hier tragen sich alle offiziellen Installer ein, auch die
    #    ohne PATH-Eintrag.
    $regRoots = @(
        'HKCU:\SOFTWARE\Python\PythonCore',
        'HKLM:\SOFTWARE\Python\PythonCore',
        'HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore'
    )
    foreach ($root in $regRoots) {
        try {
            if (-not (Test-Path $root -ErrorAction SilentlyContinue)) { continue }
            foreach ($key in Get-ChildItem $root -ErrorAction SilentlyContinue) {
                $ipKey = Join-Path $key.PSPath 'InstallPath'
                if (-not (Test-Path $ipKey)) { continue }
                $props = Get-ItemProperty $ipKey -ErrorAction SilentlyContinue
                if ($props.ExecutablePath) {
                    $cands.Add([string]$props.ExecutablePath)
                } elseif ($props.'(default)') {
                    $cands.Add((Join-Path ([string]$props.'(default)') 'python.exe'))
                }
            }
        } catch { }
    }

    # 4. Die ueblichen Verzeichnisse, falls sich jemand nirgends eingetragen hat.
    $globs = @()
    if ($env:LOCALAPPDATA)        { $globs += (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python3*\python.exe') }
    if ($env:ProgramFiles)        { $globs += (Join-Path $env:ProgramFiles 'Python3*\python.exe') }
    if (${env:ProgramFiles(x86)}) { $globs += (Join-Path ${env:ProgramFiles(x86)} 'Python3*\python.exe') }
    $globs += 'C:\Python3*\python.exe'
    foreach ($g in $globs) {
        try {
            Get-ChildItem -Path $g -ErrorAction SilentlyContinue |
                ForEach-Object { $cands.Add($_.FullName) }
        } catch { }
    }

    # Kandidaten pruefen, hoechste laufende Version gewinnt
    $working = @()
    foreach ($c in ($cands | Select-Object -Unique)) {
        $v = Test-PythonExe $c
        if ($v) { $working += [pscustomobject]@{ Exe = $c; Version = $v } }
    }
    if ($working.Count -eq 0) { return $null }
    return ($working | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1)
}

# ---------------------------------------------------------------------------
# Rueckfall, wenn winget fehlt: Installer direkt von python.org holen.
#
# Auf verwalteten Rechnern ist der Microsoft Store haeufig gesperrt, und ohne
# Store gibt es kein App-Installer-Paket und damit kein winget. Der offizielle
# Installer laesst sich dagegen ohne Administratorrechte im Benutzerprofil
# installieren.
#
# Vertrauensanker ist HTTPS zu python.org. Eine Pruefsumme verifizieren wir
# nicht - wir muessten sie von derselben Quelle laden, was nichts hinzufuegt.
# ---------------------------------------------------------------------------
function Get-WindowsArchSuffix {
    # Auf 64-Bit-Windows meldet eine 32-Bit-Shell "x86", die echte
    # Architektur steht dann in PROCESSOR_ARCHITEW6432.
    $a = $env:PROCESSOR_ARCHITEW6432
    if (-not $a) { $a = $env:PROCESSOR_ARCHITECTURE }
    switch ($a) {
        'ARM64' { return 'arm64' }
        'AMD64' { return 'amd64' }
        'x86'   { return '' }      # 32 Bit: Datei heisst python-<version>.exe
        default { return 'amd64' }
    }
}

function Get-PythonInstallerUrl {
    $arch = Get-WindowsArchSuffix

    # Verzeichnisliste von python.org auswerten, neueste Version zuerst.
    $versions = @()
    try {
        $listing = Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/' `
                       -UseBasicParsing -TimeoutSec 30
        $versions = [regex]::Matches([string]$listing.Content, 'href="(3\.\d+\.\d+)/"') |
                        ForEach-Object { $_.Groups[1].Value } |
                        Select-Object -Unique |
                        Sort-Object { [version]$_ } -Descending
    } catch {
        Warn 'Verzeichnisliste von python.org nicht erreichbar, nehme bekannte Versionen.'
    }

    # Bekannte Staende als Rueckfall anhaengen, falls die Liste leer blieb.
    $versions = @($versions) + @('3.14.6', '3.13.5', '3.12.10')

    # Wichtig: die Versionsnummer allein genuegt nicht. Fuer noch nicht
    # fertige Versionen existiert das Verzeichnis bereits, enthaelt aber nur
    # Vorabdateien - der reguläre Installer fehlt dann und liefert 404.
    foreach ($v in $versions) {
        $file = if ($arch) { "python-$v-$arch.exe" } else { "python-$v.exe" }
        $url  = "https://www.python.org/ftp/python/$v/$file"
        try {
            $head = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 20
            if ($head.StatusCode -eq 200) {
                return [pscustomobject]@{ Url = $url; File = $file; Version = $v }
            }
        } catch { }
    }
    return $null
}

function Install-PythonFromPythonOrg {
    $sel = Get-PythonInstallerUrl
    if (-not $sel) {
        Warn 'Auf python.org war kein passender Installer auffindbar.'
        return
    }

    Info "Version $($sel.Version) fuer $(Get-WindowsArchSuffix)"
    $target = Join-Path $env:TEMP $sel.File

    try {
        # ProgressPreference bremst Invoke-WebRequest unter PowerShell 5.1 stark.
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $sel.Url -OutFile $target -UseBasicParsing -TimeoutSec 600
        $ProgressPreference = $oldProgress
    } catch {
        Warn "Download fehlgeschlagen: $($_.Exception.Message)"
        return
    }

    Info 'installiere still, nur fuer diesen Benutzer (keine Adminrechte noetig)'
    try {
        $proc = Start-Process -FilePath $target -Wait -PassThru -ArgumentList @(
            '/quiet',
            'InstallAllUsers=0',   # kein Adminrecht erforderlich
            'PrependPath=1',       # traegt sich in den PATH ein
            'Include_pip=1',
            'Include_test=0'
        )
        if ($proc.ExitCode -ne 0) {
            Warn "Installer endete mit Code $($proc.ExitCode)."
        }
    } catch {
        Warn "Installer liess sich nicht starten: $($_.Exception.Message)"
    } finally {
        Remove-Item $target -Force -ErrorAction SilentlyContinue
    }
}

# TLS 1.2 erzwingen - unter PowerShell 5.1 ist der Standard sonst zu alt fuer
# manche Server.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

Write-Host "KeyBox - Einrichtung (Windows)" -ForegroundColor White
Write-Host "Projekt: $ProjectDir"

# OneDrive-Umleitung macht PlatformIO-Builds unzuverlaessig (Dateisperren,
# Synchronisation mitten im Build).
if ($ProjectDir -like '*OneDrive*') {
    Warn 'Das Projekt liegt unter OneDrive. Die Synchronisation kann Builds stoeren.'
    Info 'Besser nach C:\Dev\KeyBox oder aehnlich verschieben.'
}

# ---------------------------------------------------------------- Python ----
Step 'Python suchen'

Sync-PathFromRegistry
$py = Find-Python

if ($py) {
    Ok "Python $($py.Version)"
    Info $py.Exe
} else {
    Warn 'Kein brauchbares Python 3.6+ gefunden.'

    if ($CheckOnly) {
        # im Pruefmodus nichts installieren
    } elseif ($NoPythonInstall) {
        Info 'Automatische Installation per -NoPythonInstall abgeschaltet.'
    } else {

    # Erst winget versuchen, wenn vorhanden.
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Step 'Python per winget installieren'
        Info 'Das dauert ein paar Minuten.'

        # winget fuehrt jede Nebenversion als eigenes Paket. Neueste zuerst
        # versuchen und nach jedem Versuch neu suchen - so ist es unabhaengig
        # davon, welche Kennungen es gerade wirklich gibt.
        #
        # Kommt eine neue Python-Version heraus, hier vorne ergaenzen. Es
        # schadet nichts, wenn eine Kennung nicht existiert: der Versuch
        # scheitert, die Liste laeuft weiter.
        $wingetIds = @(
            'Python.Python.3.14',
            'Python.Python.3.13',
            'Python.Python.3.12'
        )

        foreach ($id in $wingetIds) {
            Info "versuche $id"
            try {
                & winget install --exact --id $id --source winget `
                    --scope user --accept-source-agreements --accept-package-agreements
            } catch {
                Warn "winget brach bei $id ab: $($_.Exception.Message)"
            }
            Sync-PathFromRegistry
            $py = Find-Python
            if ($py) { break }
        }

        if ($py) { Ok "Python $($py.Version) installiert"; Info $py.Exe }
        else     { Warn 'Keine der winget-Kennungen hat funktioniert.' }
    } else {
        Info 'winget ist nicht verfuegbar (Store gesperrt oder aelteres Windows).'
    }

    # Rueckfall: Installer direkt von python.org. Greift, wenn winget fehlt
    # oder alle winget-Versuche erfolglos blieben.
    if (-not $py) {
        Step 'Python direkt von python.org installieren'
        Install-PythonFromPythonOrg
        Sync-PathFromRegistry
        $py = Find-Python
        if ($py) { Ok "Python $($py.Version) installiert"; Info $py.Exe }
    }

    }   # Ende der Installationsversuche
}

if (-not $py -and -not $CheckOnly) {
    Die @"
Python 3.6+ liess sich nicht finden und nicht installieren.

  Von Hand:

    1. https://www.python.org/downloads/  ->  Windows-Installer
    2. Beim Installieren "Add python.exe to PATH" ANKREUZEN
    3. Dieses Skript erneut ausfuehren

  Wichtig: der Python-Eintrag aus dem Microsoft Store funktioniert nicht
  zuverlaessig - das ist nur eine Weiterleitung in den Store, kein Interpreter.
  Dieses Skript ueberspringt ihn deshalb absichtlich.

  Was geprueft wurde: py-Launcher, PATH, Registry (HKCU und HKLM),
  %LOCALAPPDATA%\Programs\Python, Program Files, C:\Python3*.

  Zur Fehlersuche:  scripts\setup.cmd -CheckOnly
"@
}

# venv und ensurepip gehoeren zur Standardinstallation, fehlen aber bei
# manchen abgespeckten Paketen.
if ($py) {
    $venvOk = $false
    try {
        & $py.Exe -c 'import venv, ensurepip' 2>$null | Out-Null
        $venvOk = ($LASTEXITCODE -eq 0)
    } catch { }
    if ($venvOk) {
        Ok 'venv und ensurepip vorhanden'
    } else {
        Warn 'venv oder ensurepip fehlt - Python bitte vollstaendig neu installieren.'
        if (-not $CheckOnly) { Die 'Ohne venv kann PlatformIO nicht installiert werden.' }
    }
}

# ------------------------------------------------------------- CheckOnly ----
if ($CheckOnly) {
    Step 'Weitere Umgebung'

    if (Test-Path $PioExe) { Ok "PlatformIO: $(& $PioExe --version 2>&1)" }
    else                   { Warn "PlatformIO noch nicht installiert ($PioExe)" }

    if (Get-Command winget -ErrorAction SilentlyContinue) { Ok 'winget vorhanden' }
    else { Warn 'winget fehlt - Python muesste von Hand installiert werden' }

    $foundEditor = $false
    foreach ($e in @('codium', 'code')) {
        if (Get-Command $e -ErrorAction SilentlyContinue) { Ok "Editor-CLI: $e"; $foundEditor = $true }
    }
    if (-not $foundEditor) { Warn 'Weder codium noch code auf dem PATH' }

    Step 'Serielle Anschluesse'
    try {
        $ports = [System.IO.Ports.SerialPort]::GetPortNames()
        if ($ports) { foreach ($p in $ports) { Ok $p } } else { Warn 'keine gefunden - Board angesteckt?' }
    } catch { Warn 'konnte nicht abgefragt werden' }

    Write-Host "`nNur geprueft, nichts geaendert." -ForegroundColor White
    exit 0
}

# ------------------------------------------------------- PlatformIO Core ----
Step 'PlatformIO Core installieren'

if (Test-Path $PenvPython) {
    Ok 'virtuelle Umgebung vorhanden'
    Write-Host '    aktualisiere...'
} else {
    Write-Host "    lege virtuelle Umgebung an: $Penv"
    New-Item -ItemType Directory -Force -Path $PioHome | Out-Null
    & $py.Exe -m venv $Penv
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $PenvPython)) {
        Die "venv konnte nicht angelegt werden.`n    Versucht mit: $($py.Exe)"
    }
}

# Ueber "python -m pip" statt pip.exe - der Pfad zu pip.exe existiert nicht
# zwingend, python.exe im venv aber immer.
& $PenvPython -m pip install --quiet --upgrade pip
if ($LASTEXITCODE -ne 0) { Die 'pip-Update fehlgeschlagen (Netzwerk? Virenscanner?).' }
& $PenvPython -m pip install --quiet --upgrade platformio
if ($LASTEXITCODE -ne 0) { Die 'PlatformIO-Installation fehlgeschlagen.' }

# pio.exe sollte jetzt da sein; falls nicht, geht auch der Modulaufruf.
if (Test-Path $PioExe) {
    $Pio = @($PioExe)
} else {
    Warn 'pio.exe nicht gefunden, benutze "python -m platformio"'
    $Pio = @($PenvPython, '-m', 'platformio')
}
function Invoke-Pio { & $Pio[0] @($Pio[1..($Pio.Count-1)] + $args) }

Ok (Invoke-Pio --version 2>&1)

# ------------------------------------------------------------------ PATH ----
if (-not $SkipPath) {
    Step 'PATH ergaenzen'
    $UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $already = $false
    if ($UserPath) {
        foreach ($p in ($UserPath -split ';')) {
            if ($p.TrimEnd('\') -ieq $PenvBin.TrimEnd('\')) { $already = $true; break }
        }
    }
    if ($already) {
        Ok 'bereits enthalten'
    } else {
        $new = if ([string]::IsNullOrEmpty($UserPath)) { $PenvBin } else { "$UserPath;$PenvBin" }
        [Environment]::SetEnvironmentVariable('Path', $new, 'User')
        $env:Path = "$env:Path;$PenvBin"
        Ok "$PenvBin zum Benutzer-PATH hinzugefuegt"
        Warn 'In anderen, schon offenen Terminals gilt das erst nach einem Neustart.'
    }
}

# -------------------------------------------------- Toolchain und Libs ------
Step 'Toolchain, Framework und Bibliotheken laden'
Info 'Rund 200 MB, beim ersten Mal einige Minuten.'

Set-Location $ProjectDir
Invoke-Pio pkg install
if ($LASTEXITCODE -ne 0) { Die 'Abhaengigkeiten konnten nicht geladen werden (Netzwerk? Virenscanner?).' }
Ok 'Pakete vollstaendig'

# ---------------------------------------------------------------- Treiber ---
Step 'USB-Treiber'
Ok 'Der EDBG meldet sich als HID-Geraet, Windows bringt den Treiber mit.'
Info 'Falls der Upload kein Geraet findet: Zadig starten (https://zadig.akeo.ie)'
Info 'und fuer den EDBG-Anteil WinUSB installieren.'

# ------------------------------------------------------------- Editor ------
if (-not $SkipEditor) {
    Step 'Editor-Extensions'

    $EditorCli = $null
    foreach ($cand in @('codium', 'code')) {
        if (Get-Command $cand -ErrorAction SilentlyContinue) { $EditorCli = $cand; break }
    }

    if (-not $EditorCli) {
        Warn 'Weder codium noch code auf dem PATH - uebersprungen'
        Info 'In VSCodium: LordImmaculate.platformio-ide von Hand installieren.'
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
Invoke-Pio run
if ($LASTEXITCODE -ne 0) { Die 'Der Build ist fehlgeschlagen. Ausgabe oben pruefen.' }
Ok 'Build erfolgreich'

Step 'compile_commands.json fuer clangd'
Invoke-Pio run -t compiledb 2>$null | Out-Null
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

 Falls 'pio' nicht gefunden wird: neues Terminal oeffnen.

 Verkabelung steht im README. Das Wichtigste: SDA an D2 und SCL an D3,
 NICHT an die Pins SDA/SCL neben AREF.

"@
