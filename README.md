# KeyBox

Schlüsselbox mit Arduino M0 Pro und M5Stack Unit RFID2 (WS1850S).

## Einrichtung

Ein Befehl, dann ist die komplette Umgebung da:

```bash
# Linux und macOS
./scripts/setup.sh
```

```bat
REM Windows
scripts\setup.cmd
```

Das Skript installiert PlatformIO Core in `~/.platformio/penv`, lädt die
SAMD21-Toolchain samt Bibliotheken (rund 200 MB, dauert beim ersten Mal ein
paar Minuten), richtet unter Linux die udev-Regeln für den Debugger ein,
installiert die Editor-Extensions und baut das Projekt einmal zur Kontrolle.
Mehrfaches Ausführen schadet nicht — es aktualisiert dann nur.

| Option | Wirkung |
|---|---|
| `--skip-udev` | udev-Regeln nicht anfassen (Linux) |
| `--skip-editor` / `-SkipEditor` | keine Editor-Extensions installieren |
| `-SkipPath` | Benutzer-PATH nicht verändern (Windows) |
| `-CheckOnly` | nur prüfen und berichten, nichts ändern (Windows) |
| `-NoPythonInstall` | Python nicht per winget nachinstallieren (Windows) |

### Wenn etwas nicht klappt

**Windows, zuerst immer:**

```bat
scripts\setup.cmd -CheckOnly
```

Das ändert nichts und zeigt, was gefunden wurde — Python samt Pfad, ob
PlatformIO schon da ist, ob `winget` und eine Editor-CLI existieren und welche
COM-Ports belegt sind. Die Ausgabe reicht meist zur Diagnose.

`scripts\setup.cmd` statt `setup.ps1` direkt aufzurufen ist wichtig: der
Wrapper setzt `-ExecutionPolicy Bypass`, sonst bricht Windows mit „die
Ausführung von Skripts ist deaktiviert" ab.

**„Python nicht gefunden", obwohl Python installiert ist.** Vier Ursachen, das
Skript deckt inzwischen alle ab:

| Ursache | Was das Skript tut |
|---|---|
| PATH der offenen Shell ist veraltet | liest den PATH aus der Registry neu ein |
| Microsoft-Store-Stub in `WindowsApps` | erkennt und überspringt ihn — das ist kein Interpreter, nur eine Weiterleitung in den Store |
| ohne „Add to PATH" installiert | sucht in Registry (HKCU und HKLM), `%LOCALAPPDATA%\Programs\Python`, Program Files, `C:\Python3*` |
| gar kein Python | installiert es per `winget` und sucht erneut |

Bleibt es dabei: Python von [python.org](https://www.python.org/downloads/)
installieren und **„Add python.exe to PATH" ankreuzen**. Die Store-Version
funktioniert nicht zuverlässig.

**Welche Python-Version?** Mindestens 3.6 — das ist PlatformIOs eigene
Anforderung (`Requires-Python: >=3.6` in den Paketmetadaten). Nach oben gibt es
**keine Grenze**: neuere Versionen werden akzeptiert, egal wie neu. Findet das
Skript mehrere Installationen, nimmt es die höchste, die wirklich startet.

Muss Python unter Windows nachinstalliert werden, probiert das Skript die
winget-Kennungen von neu nach alt (`Python.Python.3.14`, `.3.13`, `.3.12`) und
sucht nach jedem Versuch neu. Kommt eine neue Version heraus, kann man sie in
`scripts/setup.ps1` vorne in die Liste eintragen — fehlende Kennungen sind
unschädlich, der Versuch scheitert und die Liste läuft weiter.

**Linux: venv fehlt.** Unter Debian und Ubuntu ist das ein eigenes Paket. Das
Skript prüft es vorab und nennt den Befehl (`sudo apt install python3-venv`).

**Linux: udev-Regeln.** Die brauchen Root. Läuft `sudo` nicht ohne Rückfrage,
gibt das Skript den Befehl zum Kopieren aus, statt auf eine Passworteingabe zu
warten.

**`pio` wird nach dem Setup nicht gefunden.** Neues Terminal öffnen — der
PATH-Eintrag gilt in bereits offenen Fenstern nicht.

## Hardware

| Teil | Detail |
|------|--------|
| Controller | Arduino M0 Pro (SAMD21G18, 3,3 V Logik) |
| RFID-Leser | M5Stack Unit RFID2, Chip WS1850S, I2C-Adresse `0x28` |
| Karten | ISO/IEC 14443 Type A — MIFARE Classic, MIFARE Ultralight, NTAG |
| Lesedistanz | < 20 mm |

Der WS1850S ist registerkompatibel zum NXP MFRC522. Deshalb läuft die
MFRC522-Bibliothek direkt damit — es gibt keinen eigenen WS1850S-Treiber.

## Verkabelung

Grove-Kabel des Unit RFID2 → M0 Pro:

| Unit RFID2 | M0 Pro | Hinweis |
|------------|--------|---------|
| 5V | **5V** | 4. Pin der Stromleiste, nicht 3V3 |
| GND | **GND** | 5. Pin, direkt neben 5V |
| SDA | **D2** | *nicht* der SDA-Pin neben AREF! |
| SCL | **D3** | *nicht* der SCL-Pin neben AREF! |

Stromleiste von links: `1 IOREF · 2 RESET · 3 3V3 · 4 5V · 5 GND · 6 GND · 7 Vin`.
Die zwei benachbarten GND-Pins verleiten dazu, den ersten für 5V zu nehmen.

### Die entscheidende Falle: SDA/SCL neben AREF sind unbenutzbar

**Auf dem M0 Pro hängt der EDBG-Debugchip an denselben SAMD21-Pins wie die
Header-Pins SDA/SCL** — beide sind PA22/PA23. Und der EDBG belegt dort
ausgerechnet **Adresse 0x28**, dieselbe wie das Unit RFID2.

Zwei Slaves auf einer Adresse ergeben Datenmüll, und das Fehlerbild ist
besonders tückisch, weil alles funktionsfähig *aussieht*:

```
Geraet gefunden bei 0x28  <- Unit RFID2 (WS1850S)     (in Wahrheit der EDBG)
Reader VersionReg: 0x00                                (jedes Register liest 0)
```

Der I2C-Scanner meldet brav ein Gerät auf der erwarteten Adresse, jedes
Register liest aber `0x00` — und man sucht den Fehler in der Software. Der
Beweis ist trivial, wenn man ihn kennt: **Unit abziehen und erneut scannen.**
Bleibt `0x28` stehen, redet man mit dem Debugchip.

Deshalb läuft das Unit hier auf einem **zweiten I2C-Bus**: `D2`/`D3` liegen auf
`SERCOM2`, das in der Variante `arduino_mzero` unbenutzt ist, und der EDBG hat
dort keine Verbindung. In `src/main.cpp`:

```cpp
TwoWire rfidWire(&sercom2, 2, 3);                       // D2 = SDA, D3 = SCL
extern "C" void SERCOM2_Handler(void) { rfidWire.onService(); }
MFRC522_I2C mfrc522(0x28, -1, &rfidWire);               // Bus als 3. Parameter

// in setup(), nach begin() zwingend erforderlich:
rfidWire.begin();
pinPeripheral(2, PIO_SERCOM_ALT);                       // SERCOM2 = Funktion D
pinPeripheral(3, PIO_SERCOM_ALT);
```

Angenehmer Nebeneffekt: auf `D2`/`D3` hat das Board keine eigenen Pull-ups, die
kommen vom Unit. Ein `digitalRead()` auf beide Leitungen ohne internen Pull-up
ist damit ein **Versorgungstest** — HIGH gibt es nur, wenn das Unit Spannung
hat. Auf SDA/SCL ist das unmöglich, dort erzeugen die Board-Pull-ups für den
EDBG immer HIGH.

### `VersionReg` ist beim WS1850S 0x15, nicht 0x91

| Wert | Bedeutung |
|---|---|
| `0x15` | WS1850S — der Clone im Unit RFID2, **unser Fall** |
| `0x91` / `0x92` | echter NXP MFRC522 v1.0 / v2.0 |
| `0x00` / `0xFF` | keine Kommunikation |

Alle verbreiteten Beispiele prüfen auf `0x91`/`0x92` und melden für das
Unit RFID2 „unknown". Das ist ein Fehlalarm.

### Weitere Fallen

**1. Die Farben des Grove-Kabels lügen.** Üblich ist gelb = SDA und weiß = SCL —
bei diesem Aufbau war es umgekehrt. Vertauschte Signaladern ergeben exakt
dasselbe Bild wie ein fehlender Leser: `VersionReg` liest `0x00`, weil nie ein
ACK zurückkommt. Wenn nichts geht, **zuerst SDA und SCL gegeneinander
tauschen** — das ist die billigste Hypothese und war hier die Lösung.

**2. A4/A5 sind beim M0 Pro kein I2C.** Beim Uno ja, hier nicht. SDA und SCL
gibt es ausschließlich auf den beiden dedizierten Pins neben AREF. Adern auf
A4/A5 liegen auf zwei Analogeingängen, und man sucht den Fehler in der Software.

**3. Kein Level-Shifter nötig.** Das Unit ist für M5Stacks ESP32-Controller
gebaut, die I2C-Leitungen arbeiten also mit 3,3 V — passend zum M0 Pro. Nur die
Versorgung will 5 V. Wer hier einen Shifter einbaut, macht es kaputt statt heil.

Bleibt der Bus auch nach dem Tauschen stumm, wären externe Pull-ups der nächste
Kandidat: 4,7 kΩ von SDA und SCL nach **3,3 V** (nicht 5 V). Bei M5-Units sitzen
die normalerweise auf der Unit-Platine.

Eine Reset-Leitung führt das Grove-Kabel nicht heraus. Deshalb steht im Code
`RFID2_RESET_PIN = -1`; die Bibliothek macht dann einen Software-Reset.

## Entwicklungsumgebung (VSCodium)

VSCodium funktioniert, aber mit einer Einschränkung: es benutzt Open VSX statt
des Microsoft-Marketplace, und die offizielle PlatformIO-Extension
(`platformio.platformio-ide`) liegt **nur** im Marketplace.

Auf Open VSX gibt es dafür einen angepassten Port:

```
LordImmaculate.platformio-ide   ("PlatformIO IDE for VSCodium/Cursor")
```

Beides erledigt `scripts/setup.sh` bereits — der Abschnitt hier erklärt nur,
was dabei passiert und warum.

Die Extension bringt kein eigenes PlatformIO mit, sie bedient eine
Core-Installation in `~/.platformio/penv`, findet die vorhandene und benutzt
sie weiter. Es wird nichts doppelt installiert.

Auch ganz ohne Extension arbeitsfähig — CLI plus clangd für die
Editor-Intelligenz:

```bash
pio run -t compiledb     # compile_commands.json für clangd erzeugen
```

Die Microsoft-C/C++-Extension (`ms-vscode.cpptools`) ist ebenfalls nicht auf
Open VSX und ihre Lizenz erlaubt den Einsatz außerhalb echter VS Code sowieso
nicht — clangd ist hier der richtige Weg.

## Warum udev-Regeln nötig sind

Ohne diesen Schritt bricht der Upload ab:

```
CURRENT: upload_protocol = cmsis-dap
Error: unable to open CMSIS-DAP device 0x3eb:0x2111
Error: unable to find a matching CMSIS-DAP device
** OpenOCD init failed **
```

Der Grund ist keine fehlende Bibliothek und kein falsches Board, sondern eine
Dateiberechtigung. Es hilft, zwei Dinge auseinanderzuhalten, die beide über
dasselbe USB-Kabel laufen:

| | Gerät | Rechte per Default | Wofür |
|---|---|---|---|
| serieller Port | `/dev/ttyACM0` | `root:dialout`, `crw-rw----` | Serial Monitor |
| Debugger | `/dev/hidraw*` + `/dev/bus/usb/...` | `root:root`, `crw-------` | Flashen, Debuggen |

**Der serielle Port ist unproblematisch.** Für ihn existiert die Gruppe
`dialout`, und in der bist du normalerweise schon — der Serial Monitor
funktioniert deshalb auch ohne jede Regel.

**Der Debugger ist das Problem.** Der M0 Pro hat einen zweiten Chip an Bord,
den Atmel EDBG. Der Upload über den Programming-Port geht *nicht* über die
serielle Schnittstelle, sondern PlatformIO startet OpenOCD, und OpenOCD spricht
den EDBG über CMSIS-DAP an — als USB-HID-Gerät. Für rohe USB- und HID-Knoten
gibt es unter Linux aber keine Standardgruppe wie `dialout`: sie gehören
`root:root` mit Mode `0600`. OpenOCD läuft als normaler Nutzerprozess, kann das
Gerät also nicht öffnen. Genau das meldet die Fehlermeldung oben.

Eine udev-Regel setzt die Rechte an diesem Knoten neu, sobald das Gerät
auftaucht. Das ist der ganze Trick.

Zwei Punkte, die man leicht falsch erwartet:

- **Die VSCodium-Extension löst das nicht.** Sie ist eine Oberfläche über
  demselben PlatformIO Core und damit demselben OpenOCD. Rechte entscheidet der
  Kernel, nicht die GUI — der Upload-Button scheitert identisch.
- **`sudo pio run -t upload` ist keine Lösung.** Es funktioniert, hinterlässt
  aber root-eigene Dateien in `.pio/`, die dir beim nächsten normalen Build um
  die Ohren fliegen.

### Regeln installieren

Die Regeln liegen im Repo unter [`tools/99-keybox-udev.rules`](tools/99-keybox-udev.rules)
— kommentiert, und auf genau dieses Board zugeschnitten statt der 187 Zeilen
aus PlatformIOs Sammeldatei für hunderte fremde Boards.

```bash
sudo install -m 644 tools/99-keybox-udev.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

`udevadm trigger` wendet die Regeln auf das bereits angesteckte Gerät an, ein
Ab- und Anstecken ist normalerweise nicht nötig.

### Kontrollieren, ob's gegriffen hat

Welcher `hidraw`-Knoten zum EDBG gehört, ist nicht vorhersagbar — die Nummer
hängt davon ab, was sonst an HID-Geräten am Rechner hängt. So findest du ihn:

```bash
for h in /sys/class/hidraw/*; do
  p=$(readlink -f $h/device)
  while [ "$p" != "/" ]; do
    if [ -f "$p/idVendor" ]; then
      echo "$(basename $h) -> $(cat $p/idVendor):$(cat $p/idProduct) '$(cat $p/product)'"
      break
    fi
    p=$(dirname $p)
  done
done
```

Gesucht ist die Zeile mit `03eb:2111 'EDBG CMSIS-DAP'`. Der zugehörige Knoten
muss danach `crw-rw-rw-` sein:

```bash
ls -l /dev/hidraw5     # Nummer aus der Ausgabe oben einsetzen
```

### Alternative: PlatformIOs Sammeldatei

Wer öfter mit anderen Boards arbeitet, nimmt statt der Projektdatei besser
PlatformIOs offizielle Regeln, die viele Debugger und Bootloader abdecken:

```bash
curl -fsSL https://raw.githubusercontent.com/platformio/platformio-core/develop/platformio/assets/system/99-platformio-udev.rules \
  | sudo tee /etc/udev/rules.d/99-platformio-udev.rules
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Die decken den EDBG ebenfalls ab, allerdings nicht über seine USB-ID, sondern
über eine generische Regel auf den Produkt-String:

```
ATTRS{product}=="*CMSIS-DAP*", MODE="0666", ...
```

Diese Regel hat bewusst keine `SUBSYSTEM`-Einschränkung. `ATTRS{}` durchsucht
bei udev auch die Elternkette eines Geräts, und weil der EDBG sich als
`EDBG CMSIS-DAP` meldet, greift sie sowohl für den USB- als auch für den
hidraw-Knoten. Beide Wege führen zum Ziel; die Projektdatei ist nur
nachvollziehbarer.

## Build-Environments

```bash
pio run -t upload        # flasht m0pro (default_envs)
pio device monitor
```

| Environment | Zweck | Flash | RAM |
|-------------|-------|-------|-----|
| `m0pro` | Hauptprogramm, Programming-/Debug-Port | 17384 B (6,6 %) | 4180 B (12,8 %) |
| `m0pro_native` | Hauptprogramm, Native-USB-Port | — | — |

In `platformio.ini` steht `default_envs = m0pro`. Ohne das würde ein pauschales
`pio run -t upload` — und genauso der Upload-Button der Extension — *beide*
Environments nacheinander abarbeiten. Einzelne Environments laufen über `-e`,
in der Extension über *PlatformIO → Project Tasks*, wo jedes Environment eigene
Build- und Upload-Einträge hat.

Diagnose-Sketches gibt es keine mehr — was sie geleistet haben, steckt in
`main.cpp`: der Test der Busleitungen beim Start und ein Scan des Busses, falls
die konfigurierte Adresse nicht antwortet.

Der M0 Pro hat zwei USB-Buchsen, und das wirkt sich auf den Code aus:

- **Programming-Port** (EDBG): `Serial` ist diese Buchse. Upload über OpenOCD.
- **Native-USB-Port**: `SerialUSB` ist diese Buchse, `Serial` bleibt der
  Programming-Port. Upload über den Bootloader (bossac), ggf. Reset zweimal
  kurz drücken.

`src/main.cpp` löst das über ein Makro: das Environment `m0pro_native` setzt
`-D KEYBOX_USE_NATIVE_USB`, und `LOG` zeigt dann auf `SerialUSB`.

## Erwartete Ausgabe

```
=== KeyBox: RFID-Leser ===
Bus D2/D3 im Ruhezustand:  SDA=HIGH  SCL=HIGH
Reader VersionReg: 0x15
Leser antwortet (WS1850S).
Karte an den Leser halten...
Karte erkannt  UID=A1B2C3D4  (4 Bytes, SAK=0x8)
Karte erkannt  UID=04AABBCCDDEE80  (7 Bytes, SAK=0x20)
```

Die ersten drei Zeilen sind die Diagnose:

- **`SDA=HIGH SCL=HIGH`** — auf `D2`/`D3` kommen die Pull-ups vom Unit, HIGH
  gibt es also nur mit Spannung. Ein `LOW` heißt Versorgung oder Kontakt, nicht
  Software.
- **`VersionReg: 0x15`** — der Leser antwortet. `0x00` oder `0xFF` heißt, es
  kommt kein Byte durch; dann scannt das Programm selbst den Bus und nennt die
  gefundene Adresse.

UIDs sind 4 oder 7 Byte lang, je nach Kartentyp. Eine 4-Byte-UID, die mit `08`
beginnt, ist laut ISO 14443-3 eine **Zufallskennung** und bei jedem Auflegen
anders — solche Karten lassen sich über die UID nicht wiedererkennen.

## Nächste Schritte

Siehe [PLAN.md](PLAN.md): Servo-Schloss an `D9`, Anlernmodus mit UID-Speicherung
im Flash. Einhängepunkt ist `onCardDetected()` in `src/main.cpp`, dort liegt die
UID bereits als Hex-String vor.

Ein Hinweis zur Sicherheit, falls die Box mehr als ein Bastelprojekt werden
soll: die UID ist **kein** Geheimnis. Sie wird unverschlüsselt übertragen und
lässt sich mit „Magic"-Karten frei setzen, UID-Prüfung allein ist also leicht
zu umgehen. Wer das ernsthaft absichern will, authentifiziert gegen einen
Schlüssel im Kartenspeicher (MIFARE Classic Sector-Auth, besser NTAG mit
Passwort oder DESFire).

## Quellen

- [Unit RFID2 — M5Stack Docs](https://docs.m5stack.com/en/unit/rfid2)
- [Unit RFID / RFID2 Arduino Tutorial](https://docs.m5stack.com/en/arduino/projects/unit/unit_rfid)
- [kkloesener/MFRC522_I2C](https://github.com/kkloesener/MFRC522_I2C) — die verwendete Bibliothek
- [PlatformIO: Arduino M0 Pro (Programming Port)](https://docs.platformio.org/en/latest/boards/atmelsam/mzeropro.html)
- [PlatformIO: Arduino M0 Pro (Native USB)](https://docs.platformio.org/en/latest/boards/atmelsam/mzeroproUSB.html)
