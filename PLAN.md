# Plan: Servo-Schloss mit Anlernmodus

Stand: 28.07.2026. Das RFID-Lesen läuft, UIDs kommen sauber rein. Als Nächstes
kommt die eigentliche Schlossfunktion. Entschieden ist:

- **Aktor:** Servo dreht einen Riegel
- **Kartenverwaltung:** Anlernmodus, UIDs dauerhaft im Flash

Einhängepunkt ist `onCardDetected()` in `src/main.cpp`, dort landet die UID
bereits als Hex-String.

## Betriebsarten

```
NORMAL      Karte auflegen -> UID gegen Liste prüfen
              bekannt    -> Servo öffnet, nach 3 s wieder zu
              unbekannt  -> kurzes Signal, bleibt zu

ANLERNEN    Taster halten + Karte auflegen -> UID wird gespeichert
              schon bekannt -> Hinweis, nichts gespeichert
              Liste voll    -> Hinweis

LÖSCHEN     Taster 5 s halten (ohne Karte) -> ganze Liste leeren
```

Vor dem Löschen eine Rückfrage über Serial oder ein deutliches Blinkmuster,
sonst ist die Liste zu leicht versehentlich weg.

## Hardware, die noch dazukommt

| Teil | Anschluss | Anmerkung |
|---|---|---|
| Servo (z. B. SG90) | Signal an **D9** | Versorgung siehe unten |
| Taster | **D5** nach GND | `INPUT_PULLUP`, kein Widerstand nötig |
| Status-LED | **D13** onboard | für den Anfang genug |

Pin-Belegung im Überblick — `D2`/`D3` sind durch I2C belegt und dürfen nicht
angefasst werden:

```
D2, D3   I2C zum Unit RFID2 (SERCOM2)   <- belegt, nicht anfassen
D5       Taster
D9       Servo-Signal
D13      Status-LED (onboard)
```

### Servo-Stromversorgung — der wichtigste Punkt

Ein SG90 zieht im Anlauf und beim Blockieren **mehrere hundert Milliampere**.
Das kann die 5-V-Schiene des M0 Pro nicht liefern; der Spannungseinbruch setzt
im schlimmsten Fall den Arduino zurück, und man sucht den Fehler dann wieder in
der Software.

Also: **Servo aus einem eigenen 5-V-Netzteil versorgen, GND mit dem Arduino
verbinden.** Nur die Signalleitung geht an D9. Ein Elko (470 µF) parallel zur
Servo-Versorgung dämpft die Stromspitzen.

Das Servosignal ist beim M0 Pro 3,3 V. Die meisten Hobbyservos nehmen das an,
aber es ist knapp — falls der Servo zuckt oder nicht reagiert, ist ein
Pegelwandler auf 5 V der nächste Schritt, nicht die Software.

## Bibliotheken

In `platformio.ini` unter `lib_deps` ergänzen:

```ini
lib_deps =
	https://github.com/kkloesener/MFRC522_I2C.git
	arduino-libraries/Servo
	cmaglie/FlashStorage
```

Beide müssen noch gegen SAMD21 geprüft werden — `Servo` unterstützt SAMD,
`FlashStorage` ist speziell dafür gemacht.

## Speicherung der UIDs

Der SAMD21 hat **kein echtes EEPROM**. `FlashStorage` emuliert eines im
Programmflash. Datenstruktur, die 4- *und* 7-Byte-UIDs aufnimmt:

```cpp
struct StoredUid {
    uint8_t len;         // 4, 7 oder 10
    uint8_t bytes[10];
};

struct KeyStore {
    uint32_t magic;      // Kennung, um leeren Flash zu erkennen
    uint8_t  count;
    StoredUid uids[16];
};
```

Das `magic` ist wichtig: frischer Flash ist mit `0xFF` gefüllt, ohne Kennung
hält man Müll für gültige Daten.

### Zwei Fallen dabei

**Nur beim Anlernen schreiben, nie im `loop()`.** Eine Flash-Seite überlebt
grob 10.000 Löschzyklen. Ein versehentliches `write()` im Hauptloop zerstört
den Speicher in Minuten.

**Beim Flashen eines neuen Sketches können die gelernten Karten verschwinden.**
Der Upload schreibt Programmflash, und der Speicherbereich liegt im selben
Flash. Beim Testen also damit rechnen und nicht nach einem Softwarefehler
suchen.

## Karten für den Test

Aus dem Log vom 28.07.:

| UID | SAK | Typ | Als Testkarte |
|---|---|---|---|
| `A1B2C3D4` | `0x08` | MIFARE Classic 1K | geeignet |
| `E5F6A7B8` | `0x08` | MIFARE Classic 1K | geeignet |
| `04AABBCCDDEE80` | `0x20` | DESFire / MIFARE Plus | geeignet, 7 Byte |
| `0411223344556F` | `0x20` | DESFire / MIFARE Plus | geeignet, 7 Byte |
| `08AABBCC` | `0x20` | **Zufalls-UID** | **nicht benutzen** |

Die letzte Karte beginnt mit `08`, was bei einer 4-Byte-UID laut ISO 14443-3
eine zufällig erzeugte Kennung bedeutet — sie ist bei jedem Auflegen anders und
über die UID grundsätzlich nicht identifizierbar.

Mindestens eine 4-Byte- und eine 7-Byte-Karte anlernen, damit der
Längenvergleich wirklich getestet ist.

## Zum Sicherheitsniveau

Die UID ist kein Geheimnis: sie geht unverschlüsselt über die Luft und lässt
sich mit „Magic"-Karten frei setzen. Eine UID-Prüfung ist damit ungefähr so
sicher wie ein Schlüssel, dessen Form außen aufgedruckt ist — für ein
Schulprojekt völlig in Ordnung, für eine echte Tür nicht.

Wer weitergehen will: die vorhandenen `SAK=0x20`-Karten (DESFire, MIFARE Plus)
können echte Kryptografie, dann authentifiziert man gegen einen Schlüssel im
Kartenspeicher statt gegen die UID. Das ist ein eigenes Thema und ein guter
zweiter Projektschritt.

## Offene Fragen für morgen

1. Welcher Servo, und ist ein separates 5-V-Netzteil da?
2. Taster vorhanden, oder erst mal per Serial-Kommando anlernen?
3. Wie viele Karten soll die Liste halten? (16 als Vorschlag)
4. Einzelne Karte löschen, oder reicht „alles löschen"?
5. Rückmeldung nur über LED, oder soll ein Piezo dazu?
