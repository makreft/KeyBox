/*
 * KeyBox - RFID-Karte auslesen
 *
 * Hardware: Arduino M0 Pro (SAMD21, 3.3 V) + M5Stack Unit RFID2 (WS1850S, I2C)
 *
 * Der WS1850S ist registerkompatibel zum NXP MFRC522, deshalb funktioniert
 * die MFRC522_I2C-Bibliothek damit.
 *
 * Verkabelung (Grove-Kabel -> M0 Pro):
 *   5V   -> 5V    (4. Pin der Stromleiste)
 *   GND  -> GND   (5. Pin)
 *   SDA  -> D2
 *   SCL  -> D3
 *
 * ACHTUNG - NICHT die Pins SDA/SCL neben AREF benutzen!
 *
 * Auf dem M0 Pro haengt der EDBG-Debugchip an denselben SAMD21-Pins wie die
 * Header-Pins SDA/SCL (beides PA22/PA23) und belegt dort ausgerechnet die
 * Adresse 0x28 - dieselbe wie das Unit RFID2. Zwei Slaves auf einer Adresse
 * ergeben Datenmuell: der Bus-Scan meldet brav ein Gerät auf 0x28, jedes
 * Register liest aber 0x00, und man sucht den Fehler stundenlang in der
 * Software.
 *
 * Deshalb laeuft das Unit hier auf einem zweiten I2C-Bus: D2/D3 liegen auf
 * SERCOM2, das in der Variante arduino_mzero unbenutzt ist, und der EDBG hat
 * dort keine Verbindung.
 */

#include <Arduino.h>
#include <Wire.h>
#include <string.h>
#include <MFRC522_I2C.h>
#include "wiring_private.h"   // pinPeripheral()

/*
 * Auf dem M0 Pro sind es zwei verschiedene USB-Buchsen:
 *   Serial     = Programming-/Debug-Port (EDBG)
 *   SerialUSB  = Native-USB-Port
 * Das Build-Environment m0pro_native setzt KEYBOX_USE_NATIVE_USB.
 */
#if defined(KEYBOX_USE_NATIVE_USB)
#define LOG SerialUSB
#else
#define LOG Serial
#endif

// I2C-Adresse des Unit RFID2. Falls der Scanner etwas anderes findet: hier anpassen.
static const uint8_t RFID2_I2C_ADDR = 0x28;

// Das Grove-Kabel fuehrt keine Reset-Leitung heraus -> -1 heisst "nicht angeschlossen",
// die Bibliothek macht dann einen Software-Reset.
static const int8_t RFID2_RESET_PIN = -1;

// Zweiter I2C-Bus auf D2/D3, siehe Kommentar am Dateianfang.
static const uint8_t RFID2_SDA = 2;   // PA08, SERCOM2/PAD[0]
static const uint8_t RFID2_SCL = 3;   // PA09, SERCOM2/PAD[1]

TwoWire rfidWire(&sercom2, RFID2_SDA, RFID2_SCL);

// SERCOM2 wird in der Variante von nichts belegt, der Handler ist frei.
extern "C" void SERCOM2_Handler(void) {
    rfidWire.onService();
}

// Die Bibliothek nimmt die Wire-Instanz als dritten Parameter.
MFRC522_I2C mfrc522(RFID2_I2C_ADDR, RFID2_RESET_PIN, &rfidWire);

// Eine UID hat maximal 10 Bytes -> 10 * 2 Hex-Zeichen + Nullbyte
static char lastUid[21] = "";
static uint32_t lastSeenMs = 0;

// Solange dieselbe Karte am Leser liegt, nicht dauernd neu melden.
static const uint32_t REREAD_BLOCK_MS = 1500;

// In einer .cpp muss die Funktion vor der Benutzung deklariert sein
// (in einer .ino erledigt die Arduino-IDE das automatisch).
void onCardDetected(const char *uid);

// Wird nur true, wenn die Busleitungen im Ruhezustand HIGH sind. Ohne diese
// Sperre wuerde loop() weiterlaufen und in Wire haengen, obwohl setup()
// bereits abgebrochen hat.
static bool busOk = false;

// UID-Bytes in einen Hex-String wandeln, z. B. "04A2B7C1"
static void uidToHex(const uint8_t *uidBytes, uint8_t len, char *out, size_t outLen) {
    static const char hexDigits[] = "0123456789ABCDEF";
    size_t pos = 0;
    for (uint8_t i = 0; i < len && pos + 3 <= outLen; i++) {
        out[pos++] = hexDigits[uidBytes[i] >> 4];
        out[pos++] = hexDigits[uidBytes[i] & 0x0F];
    }
    out[pos] = '\0';
}

// Firmware-Version auslesen - der zuverlaessigste Test, ob die I2C-Verbindung steht.
static void showReaderDetails() {
    byte v = mfrc522.PCD_ReadRegister(mfrc522.VersionReg);
    LOG.print(F("Reader VersionReg: 0x"));
    LOG.println(v, HEX);

    /*
     * Erwartete Werte:
     *   0x15         WS1850S (der Clone im Unit RFID2) - das ist unser Fall
     *   0x91 / 0x92  echter NXP MFRC522 v1.0 / v2.0
     *   0x00 / 0xFF  keine Kommunikation
     *
     * Auf 0x91/0x92 zu pruefen waere falsch: der WS1850S meldet 0x15, und das
     * ist voellig in Ordnung.
     */
    if (v == 0x00 || v == 0xFF) {
        LOG.print(F("FEHLER: keine Antwort auf Adresse 0x"));
        LOG.println(RFID2_I2C_ADDR, HEX);

        // Nachsehen, was sonst auf dem Bus liegt.
        LOG.println(F("  suche den Bus ab..."));
        uint8_t found = 0;
        for (uint8_t addr = 0x08; addr <= 0x77; addr++) {
            rfidWire.beginTransmission(addr);
            if (rfidWire.endTransmission() == 0) {
                found++;
                LOG.print(F("  Geraet auf 0x"));
                if (addr < 0x10) {
                    LOG.print('0');
                }
                LOG.print(addr, HEX);
                if (addr == RFID2_I2C_ADDR) {
                    LOG.println(F("  (das ist die konfigurierte Adresse)"));
                } else {
                    LOG.println(F("  <== RFID2_I2C_ADDR im Code darauf setzen!"));
                }
            }
        }
        if (found == 0) {
            LOG.println(F("  Nichts auf dem Bus. Sitzen SDA an D2 und SCL an D3?"));
        }
    } else if (v == 0x15) {
        LOG.println(F("Leser antwortet (WS1850S)."));
    } else {
        LOG.println(F("Leser antwortet."));
    }
}

void setup() {
    LOG.begin(115200);

    // Auf den seriellen Monitor warten, aber nicht endlos blockieren
    // (ohne angeschlossenen PC soll die Box trotzdem starten).
    uint32_t start = millis();
    while (!LOG && (millis() - start) < 3000) {
        ;
    }

    LOG.println();
    LOG.println(F("=== KeyBox: RFID-Leser ==="));

    /*
     * Busleitungen zuerst als reine GPIOs pruefen.
     *
     * Wire blockiert auf dem SAMD21 endlos, wenn SDA oder SCL dauerhaft LOW
     * ist - dann haengt setup() ohne jede Ausgabe. Im Ruhezustand muessen
     * beide Leitungen HIGH sein.
     *
     * Auf D2/D3 hat das Board keine eigenen Pull-ups, die kommen vom Unit.
     * Damit ist dieser Test gleichzeitig ein Versorgungstest: HIGH gibt es nur,
     * wenn das Unit Spannung hat.
     */
    pinMode(RFID2_SDA, INPUT);      // bewusst ohne INPUT_PULLUP
    pinMode(RFID2_SCL, INPUT);
    delay(10);
    bool sdaHigh = digitalRead(RFID2_SDA);
    bool sclHigh = digitalRead(RFID2_SCL);

    LOG.print(F("Bus D2/D3 im Ruhezustand:  SDA="));
    LOG.print(sdaHigh ? F("HIGH") : F("LOW"));
    LOG.print(F("  SCL="));
    LOG.println(sclHigh ? F("HIGH") : F("LOW"));

    if (!sdaHigh || !sclHigh) {
        LOG.println(F("FEHLER: Bus liegt auf LOW - I2C kann nicht arbeiten."));
        LOG.println(F("  Auf D2/D3 kommen die Pull-ups vom Unit, HIGH gibt es"));
        LOG.println(F("  also nur mit Spannung. Pruefen:"));
        LOG.println(F("   1. 5V am 4. Pin der Stromleiste, GND am 5.?"));
        LOG.println(F("   2. SDA an D2, SCL an D3, alle Adern mit Kontakt?"));
        LOG.println(F("  Wire wird uebersprungen, sonst haengt das Programm hier."));
        return;   // Wire gar nicht erst anfassen
    }

    busOk = true;

    // Zweiten I2C-Bus starten. Nach begin() muessen die Pins per
    // pinPeripheral() auf SERCOM2 (Peripheriefunktion D) umgelegt werden -
    // begin() allein setzt nur den Standard-Mux.
    rfidWire.begin();
    pinPeripheral(RFID2_SDA, PIO_SERCOM_ALT);
    pinPeripheral(RFID2_SCL, PIO_SERCOM_ALT);

    mfrc522.PCD_Init();    // WS1850S initialisieren

    showReaderDetails();
    LOG.println(F("Karte an den Leser halten..."));
}

void loop() {
    // Bus war beim Start nicht in Ordnung -> nicht auf Wire zugreifen.
    if (!busOk) {
        delay(1000);
        return;
    }

    // PICC_IsNewCardPresent() sendet REQA, PICC_ReadCardSerial() macht die
    // Antikollision und legt die UID in mfrc522.uid ab.
    if (!mfrc522.PICC_IsNewCardPresent() || !mfrc522.PICC_ReadCardSerial()) {
        delay(50);
        return;
    }

    char uid[sizeof(lastUid)];
    uidToHex(mfrc522.uid.uidByte, mfrc522.uid.size, uid, sizeof(uid));

    // Gleiche Karte kurz nacheinander -> ignorieren
    uint32_t now = millis();
    if (strcmp(uid, lastUid) == 0 && (now - lastSeenMs) < REREAD_BLOCK_MS) {
        lastSeenMs = now;
        return;
    }

    strncpy(lastUid, uid, sizeof(lastUid) - 1);
    lastUid[sizeof(lastUid) - 1] = '\0';
    lastSeenMs = now;

    LOG.print(F("Karte erkannt  UID="));
    LOG.print(uid);
    LOG.print(F("  ("));
    LOG.print(mfrc522.uid.size);
    LOG.print(F(" Bytes, SAK=0x"));
    LOG.print(mfrc522.uid.sak, HEX);
    LOG.println(F(")"));

    // Ab hier kommt spaeter die eigentliche KeyBox-Logik:
    // UID gegen eine Liste erlaubter Karten pruefen und das Schloss ansteuern.
    onCardDetected(uid);
}

// Platzhalter fuer die KeyBox-Logik.
void onCardDetected(const char *uid) {
    (void)uid;
    // TODO: erlaubte UIDs pruefen, Servo/Relais schalten, Ereignis protokollieren
}
