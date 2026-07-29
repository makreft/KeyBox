#!/usr/bin/env bash
#
# KeyBox - Entwicklungsumgebung einrichten (Linux und macOS)
#
#   ./scripts/setup.sh
#
# Installiert PlatformIO Core, laedt die SAMD21-Toolchain und die Bibliotheken,
# richtet unter Linux die udev-Regeln fuer den Debugger ein und baut das Projekt
# einmal zur Kontrolle.
#
# Optionen:
#   --skip-udev    udev-Regeln nicht anfassen (Linux)
#   --skip-editor  keine VSCodium-/VS-Code-Extensions installieren
#   --help
#
# Das Skript ist idempotent: mehrfaches Ausfuehren schadet nicht.

set -euo pipefail

# bash 3.2 auf macOS kann kein ${var^^} und keine assoziativen Arrays -
# deshalb hier bewusst nur einfache Konstrukte.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIO_HOME="$HOME/.platformio"
PENV="$PIO_HOME/penv"
PIO="$PENV/bin/pio"
UDEV_TARGET="/etc/udev/rules.d/99-keybox-udev.rules"

SKIP_UDEV=0
SKIP_EDITOR=0

if [ -t 1 ]; then
    B="$(printf '\033[1m')"; G="$(printf '\033[32m')"
    Y="$(printf '\033[33m')"; R="$(printf '\033[31m')"; N="$(printf '\033[0m')"
else
    B=""; G=""; Y=""; R=""; N=""
fi

step() { printf '\n%s==> %s%s\n' "$B" "$1" "$N"; }
ok()   { printf '    %s+%s %s\n' "$G" "$N" "$1"; }
warn() { printf '    %s!%s %s\n' "$Y" "$N" "$1"; }
die()  { printf '\n%sFehler:%s %s\n' "$R" "$N" "$1" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-udev)   SKIP_UDEV=1 ;;
        --skip-editor) SKIP_EDITOR=1 ;;
        --help|-h)     sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             die "Unbekannte Option: $1" ;;
    esac
    shift
done

case "$(uname -s)" in
    Linux)  OS=linux  ;;
    Darwin) OS=macos  ;;
    *)      die "Nicht unterstuetzt: $(uname -s). Fuer Windows scripts/setup.ps1 benutzen." ;;
esac

printf '%sKeyBox - Einrichtung (%s)%s\n' "$B" "$OS" "$N"
printf 'Projekt: %s\n' "$PROJECT_DIR"

# ---------------------------------------------------------------- Python ----
step "Python pruefen"

PYTHON=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
        if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3,6) else 1)' 2>/dev/null; then
            PYTHON="$candidate"
            break
        fi
    fi
done

[ -n "$PYTHON" ] || die "Python 3.6+ nicht gefunden.
    Linux:  sudo apt install python3 python3-venv
    macOS:  brew install python3"

ok "$("$PYTHON" --version 2>&1)"

# venv wird gebraucht - auf Debian/Ubuntu ist das ein eigenes Paket und fehlt oft
if ! "$PYTHON" -c 'import venv, ensurepip' >/dev/null 2>&1; then
    die "Das venv-Modul fehlt.
    Debian/Ubuntu:  sudo apt install python3-venv
    Fedora:         sudo dnf install python3-virtualenv"
fi
ok "venv und ensurepip vorhanden"

# ------------------------------------------------------- PlatformIO Core ----
step "PlatformIO Core installieren"

if [ -x "$PIO" ]; then
    ok "vorhanden: $("$PIO" --version 2>&1)"
    printf '    aktualisiere...\n'
else
    printf '    lege virtuelle Umgebung an: %s\n' "$PENV"
    mkdir -p "$PIO_HOME"
    "$PYTHON" -m venv "$PENV" || die "venv konnte nicht angelegt werden."
fi

"$PENV/bin/pip" install --quiet --upgrade pip     || die "pip-Update fehlgeschlagen."
"$PENV/bin/pip" install --quiet --upgrade platformio || die "PlatformIO-Installation fehlgeschlagen."
ok "$("$PIO" --version 2>&1)"

# pio auf den PATH holen, wenn ~/.local/bin existiert und benutzt wird.
# PIO_SHOW ist der Name, den die Schlussmeldung anzeigt - kurz wenn moeglich.
LINK_DIR="$HOME/.local/bin"
PIO_SHOW="$PIO"
if [ -d "$LINK_DIR" ]; then
    ln -sf "$PENV/bin/pio" "$LINK_DIR/pio"
    ln -sf "$PENV/bin/platformio" "$LINK_DIR/platformio"
    case ":$PATH:" in
        *":$LINK_DIR:"*) ok "pio liegt im PATH ($LINK_DIR)"; PIO_SHOW="pio" ;;
        *) warn "$LINK_DIR ist nicht im PATH. Ergaenze in ~/.bashrc oder ~/.zshrc:
        export PATH=\"\$HOME/.local/bin:\$PATH\"
    Danach genuegt 'pio' statt des vollen Pfades." ;;
    esac
else
    warn "$LINK_DIR existiert nicht - benutze den vollen Pfad: $PIO"
fi

# -------------------------------------------------- Toolchain und Libs ------
step "Toolchain, Framework und Bibliotheken laden"
printf '    Das sind rund 200 MB und dauert beim ersten Mal einige Minuten.\n'

cd "$PROJECT_DIR"
"$PIO" pkg install || die "Abhaengigkeiten konnten nicht geladen werden (Netzwerk?)."
ok "Pakete vollstaendig"

# --------------------------------------------------------- udev (Linux) ----
if [ "$OS" = linux ] && [ "$SKIP_UDEV" -eq 0 ]; then
    step "udev-Regeln fuer den Debugger"

    RULES_SRC="$PROJECT_DIR/tools/99-keybox-udev.rules"
    [ -f "$RULES_SRC" ] || die "Regeldatei fehlt: $RULES_SRC"

    if [ -f "$UDEV_TARGET" ] && cmp -s "$RULES_SRC" "$UDEV_TARGET"; then
        ok "bereits installiert und aktuell"
    else
        # Ohne diese Regeln darf OpenOCD nicht auf den EDBG-Debugchip zugreifen,
        # der Upload scheitert mit "unable to open CMSIS-DAP device".
        if sudo -n true 2>/dev/null; then
            sudo install -m 644 "$RULES_SRC" "$UDEV_TARGET"
            sudo udevadm control --reload-rules
            sudo udevadm trigger
            ok "installiert nach $UDEV_TARGET"
        else
            warn "Braucht Root-Rechte. Bitte einmal ausfuehren:

        sudo install -m 644 $RULES_SRC $UDEV_TARGET
        sudo udevadm control --reload-rules && sudo udevadm trigger

    Ohne das scheitert der Upload mit 'unable to open CMSIS-DAP device'."
        fi
    fi
elif [ "$OS" = macos ]; then
    step "udev-Regeln"
    ok "unter macOS nicht noetig - CMSIS-DAP laeuft dort ohne Zusatzrechte"
fi

# ------------------------------------------------------------- Editor ------
if [ "$SKIP_EDITOR" -eq 0 ]; then
    step "Editor-Extensions"

    EDITOR_CLI=""
    for candidate in codium code; do
        if command -v "$candidate" >/dev/null 2>&1; then
            EDITOR_CLI="$candidate"
            break
        fi
    done

    if [ -z "$EDITOR_CLI" ]; then
        warn "Weder codium noch code gefunden - uebersprungen"
    else
        # VSCodium benutzt Open VSX, dort liegt die offizielle
        # platformio.platformio-ide nicht. Der angepasste Port heisst anders.
        if [ "$EDITOR_CLI" = codium ]; then
            PIO_EXT="LordImmaculate.platformio-ide"
        else
            PIO_EXT="platformio.platformio-ide"
        fi

        for ext in "$PIO_EXT" llvm-vs-code-extensions.vscode-clangd; do
            if "$EDITOR_CLI" --install-extension "$ext" >/dev/null 2>&1; then
                ok "$ext"
            else
                warn "$ext liess sich nicht installieren (evtl. schon vorhanden)"
            fi
        done
    fi
fi

# ------------------------------------------------------ Gegenprobe ---------
step "Gegenprobe: Projekt bauen"
"$PIO" run || die "Der Build ist fehlgeschlagen. Ausgabe oben pruefen."
ok "Build erfolgreich"

step "compile_commands.json fuer clangd"
"$PIO" run -t compiledb >/dev/null 2>&1 && ok "erzeugt" || warn "fehlgeschlagen (unkritisch)"

# ------------------------------------------------------------ Abschluss ----
cat <<EOF

$B Fertig.$N

 Naechste Schritte:

   1. Board am Programming-Port anstecken (die USB-Buchse naeher am Reset-Knopf)
   2. Flashen:   $PIO_SHOW run -t upload
   3. WICHTIG:   USB einmal abziehen und wieder anstecken
                 Ohne das startet die Firmware nicht - siehe README
   4. Monitor:   $PIO_SHOW device monitor

 Verkabelung steht im README. Das Wichtigste: SDA an D2 und SCL an D3,
 NICHT an die Pins SDA/SCL neben AREF.

EOF
