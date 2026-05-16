#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_USER="${SUDO_USER:-$USER}"
INSTALL_UID="$(id -u "$INSTALL_USER")"

# ── What this does ────────────────────────────────────────────────────────────
cat <<'EOF'

chromadapt installer
════════════════════
Reads your laptop's ambient colour sensor every 60 seconds and adjusts the
display ICC profile so colours look consistent under any lighting — warm
indoors, cool in daylight. Runs as a systemd timer with no persistent process.

EOF

if [[ "$EUID" -ne 0 ]]; then
    echo "Please run as root:  sudo ./install.sh"
    exit 1
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────
echo "Checking prerequisites..."

MISSING=()
command -v python3   &>/dev/null || MISSING+=("python3")
command -v systemctl &>/dev/null || MISSING+=("systemd")

HAS_KSCREEN=false; HAS_COLORMGR=false
command -v kscreen-doctor &>/dev/null && HAS_KSCREEN=true
command -v colormgr        &>/dev/null && HAS_COLORMGR=true
$HAS_KSCREEN || $HAS_COLORMGR || MISSING+=("kscreen-doctor (KDE) or colormgr (GNOME)")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo ""; echo "Missing:"; for m in "${MISSING[@]}"; do echo "  ✗ $m"; done; echo ""; exit 1
fi

echo "  ✓ python3  ✓ systemd"
$HAS_KSCREEN  && echo "  ✓ kscreen-doctor (KDE)"
$HAS_COLORMGR && echo "  ✓ colormgr (GNOME)"
echo ""

# ── Helper: ask user to pick from a list ─────────────────────────────────────
pick_from_list() {
    local prompt="$1"; shift
    local -a options=("$@")
    echo "$prompt"
    for i in "${!options[@]}"; do
        echo "  $((i+1))) ${options[$i]}"
    done
    while true; do
        read -rp "  Choice [1-${#options[@]}]: " idx
        if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#options[@]} )); then
            echo "${options[$((idx-1))]}"
            return
        fi
        echo "  Please enter a number between 1 and ${#options[@]}."
    done
}

# ── Detect: internal display connector ───────────────────────────────────────
echo "─── Display connector ───────────────────────────────────────────────────"
CONNECTOR=""

# Prefer eDP (internal panel)
for path in /sys/class/drm/card*-eDP-*/; do
    [[ -d "$path" ]] || continue
    CONNECTOR=$(basename "$path" | sed 's/card[0-9]*-//')
    break
done

# All available connectors (for the options list)
mapfile -t ALL_CONNECTORS < <(
    for p in /sys/class/drm/card*-*/; do
        [[ -d "$p" ]] || continue
        name=$(basename "$p" | sed 's/card[0-9]*-//')
        [[ "$name" == "card"* ]] && continue  # skip card-level entries
        echo "$name"
    done | sort -u
)

if [[ -n "$CONNECTOR" ]]; then
    echo "  Detected: $CONNECTOR"
    read -rp "  Correct? [Y/n] " ok; ok="${ok:-Y}"
    if [[ ! "$ok" =~ ^[Yy]$ ]]; then
        CONNECTOR=$(pick_from_list "  Available connectors:" "${ALL_CONNECTORS[@]}")
    fi
else
    echo "  Could not auto-detect an internal (eDP) display."
    CONNECTOR=$(pick_from_list "  Available connectors:" "${ALL_CONNECTORS[@]}")
fi
echo "  → Using: $CONNECTOR"
echo ""

# ── Detect: IIO colour sensor ─────────────────────────────────────────────────
echo "─── Colour sensor (chromaticity) ────────────────────────────────────────"
SENSOR_DEV=""
for d in /sys/bus/iio/devices/iio:device*; do
    [[ -f "$d/in_chromaticity_x_raw" ]] || continue
    SENSOR_DEV=$(basename "$d")
    break
done

# Build list of all IIO devices with their names
mapfile -t ALL_IIO < <(
    for d in /sys/bus/iio/devices/iio:device*; do
        [[ -d "$d" ]] || continue
        name=$(cat "$d/name" 2>/dev/null || echo "unknown")
        has_chroma=""
        [[ -f "$d/in_chromaticity_x_raw" ]] && has_chroma=" [chromaticity]"
        echo "$(basename $d)  ($name)$has_chroma"
    done
)

if [[ -n "$SENSOR_DEV" ]]; then
    SENSOR_NAME=$(cat "/sys/bus/iio/devices/${SENSOR_DEV}/name" 2>/dev/null || echo "unknown")
    echo "  Detected: $SENSOR_DEV  ($SENSOR_NAME)"
    read -rp "  Correct? [Y/n] " ok; ok="${ok:-Y}"
    if [[ ! "$ok" =~ ^[Yy]$ ]]; then
        choice=$(pick_from_list "  Available IIO devices (need [chromaticity]):" "${ALL_IIO[@]}")
        SENSOR_DEV=$(echo "$choice" | awk '{print $1}')
    fi
else
    echo "  No IIO chromaticity sensor found automatically."
    echo "  Note: a lux-only ALS is not sufficient — need in_chromaticity_x/y_raw."
    if [[ ${#ALL_IIO[@]} -gt 0 ]]; then
        choice=$(pick_from_list "  Available IIO devices:" "${ALL_IIO[@]}")
        SENSOR_DEV=$(echo "$choice" | awk '{print $1}')
    else
        echo "  No IIO devices found at all. chromadapt cannot run on this hardware."; exit 1
    fi
fi
echo "  → Using: $SENSOR_DEV"
echo ""

# ── Detect: illuminance sensor ────────────────────────────────────────────────
echo "─── Illuminance sensor (lux guard) ──────────────────────────────────────"
SENSOR_LX_DEV=""
for d in /sys/bus/iio/devices/iio:device*; do
    [[ -f "$d/in_illuminance_raw" ]] || continue
    SENSOR_LX_DEV=$(basename "$d")
    break
done

if [[ -n "$SENSOR_LX_DEV" ]]; then
    LX_NAME=$(cat "/sys/bus/iio/devices/${SENSOR_LX_DEV}/name" 2>/dev/null || echo "unknown")
    echo "  Detected: $SENSOR_LX_DEV  ($LX_NAME)"
    read -rp "  Correct? [Y/n] " ok; ok="${ok:-Y}"
    if [[ ! "$ok" =~ ^[Yy]$ ]]; then
        mapfile -t LX_IIO < <(
            for d in /sys/bus/iio/devices/iio:device*; do
                [[ -f "$d/in_illuminance_raw" ]] || continue
                name=$(cat "$d/name" 2>/dev/null || echo "unknown")
                echo "$(basename $d)  ($name)"
            done
        )
        choice=$(pick_from_list "  Devices with in_illuminance_raw:" "${LX_IIO[@]}")
        SENSOR_LX_DEV=$(echo "$choice" | awk '{print $1}')
    fi
else
    echo "  No illuminance sensor found — low-light skipping will be disabled."
    SENSOR_LX_DEV="$SENSOR_DEV"  # fallback to colour sensor device
fi
echo "  → Using: $SENSOR_LX_DEV"
echo ""

# ── Detect: desktop environment ───────────────────────────────────────────────
echo "─── Desktop environment ─────────────────────────────────────────────────"
DE=""
if $HAS_KSCREEN && ! $HAS_COLORMGR; then
    DE="kde"
elif $HAS_COLORMGR && ! $HAS_KSCREEN; then
    DE="gnome"
elif $HAS_KSCREEN && $HAS_COLORMGR; then
    DESKTOP=$(su -l "$INSTALL_USER" -c 'echo "$XDG_CURRENT_DESKTOP"' 2>/dev/null || echo "")
    echo "$DESKTOP" | grep -qi kde   && DE="kde"
    echo "$DESKTOP" | grep -qi gnome && DE="gnome"
fi

if [[ -n "$DE" ]]; then
    echo "  Detected: $DE"
    read -rp "  Correct? [Y/n] " ok; ok="${ok:-Y}"
    [[ ! "$ok" =~ ^[Yy]$ ]] && DE=""
fi

if [[ -z "$DE" ]]; then
    DE=$(pick_from_list "  Select desktop environment:" "kde  (KDE Plasma 6+, uses kscreen-doctor)" "gnome  (GNOME 43+, uses colormgr)")
    DE=$(echo "$DE" | awk '{print $1}')
fi
echo "  → Using: $DE"
echo ""

# ── Base ICC profile ──────────────────────────────────────────────────────────
echo "─── Base ICC profile ────────────────────────────────────────────────────"
BASE_ICC=""
for candidate in \
    /usr/share/color/icc/colord/sRGB.icc \
    /usr/share/color/icc/sRGB.icc \
    /usr/share/colord/profiles/sRGB.icc; do
    [[ -f "$candidate" ]] && BASE_ICC="$candidate" && break
done

mapfile -t ALL_ICC < <(find /usr/share/color/icc /usr/share/colord -name "*.icc" 2>/dev/null | sort)

if [[ -n "$BASE_ICC" ]]; then
    echo "  Detected: $BASE_ICC"
    read -rp "  Correct? [Y/n] " ok; ok="${ok:-Y}"
    if [[ ! "$ok" =~ ^[Yy]$ ]]; then
        if [[ ${#ALL_ICC[@]} -gt 0 ]]; then
            BASE_ICC=$(pick_from_list "  System ICC profiles:" "${ALL_ICC[@]}")
        else
            read -rp "  Path to base ICC profile: " BASE_ICC
        fi
    fi
else
    echo "  No system sRGB profile found automatically."
    if [[ ${#ALL_ICC[@]} -gt 0 ]]; then
        BASE_ICC=$(pick_from_list "  System ICC profiles:" "${ALL_ICC[@]}")
    else
        read -rp "  Path to base ICC profile: " BASE_ICC
    fi
fi
echo "  → Using: $BASE_ICC"
echo ""

# ── Install ───────────────────────────────────────────────────────────────────
SENSOR_X_PATH="/sys/bus/iio/devices/${SENSOR_DEV}/in_chromaticity_x_raw"
SENSOR_Y_PATH="/sys/bus/iio/devices/${SENSOR_DEV}/in_chromaticity_y_raw"
SENSOR_LX_PATH="/sys/bus/iio/devices/${SENSOR_LX_DEV}/in_illuminance_raw"

echo "Installing..."

sed \
    -e "s|SENSOR_X  = '.*'|SENSOR_X  = '${SENSOR_X_PATH}'|" \
    -e "s|SENSOR_Y  = '.*'|SENSOR_Y  = '${SENSOR_Y_PATH}'|" \
    -e "s|SENSOR_LX = '.*'|SENSOR_LX = '${SENSOR_LX_PATH}'|" \
    -e "s|BASE      = '.*'|BASE      = '${BASE_ICC}'|" \
    -e "s|CONNECTOR = '.*'|CONNECTOR = '${CONNECTOR}'|" \
    -e "s|DE = '.*'|DE = '${DE}'|" \
    "$SCRIPT_DIR/chromadapt" \
    > /usr/local/bin/chromadapt
chmod 755 /usr/local/bin/chromadapt

sed \
    -e "s/CHROMADAPT_USER/$INSTALL_USER/g" \
    -e "s/CHROMADAPT_UID/$INSTALL_UID/g" \
    "$SCRIPT_DIR/chromadapt.service" \
    > /etc/systemd/system/chromadapt.service

install -m 644 "$SCRIPT_DIR/chromadapt.timer" /etc/systemd/system/chromadapt.timer

systemctl daemon-reload
systemctl enable --now chromadapt.timer

echo "  ✓ /usr/local/bin/chromadapt"
echo "  ✓ /etc/systemd/system/chromadapt.{service,timer}"
echo "  ✓ Timer enabled"
echo ""

rm -f /tmp/chromadapt-last.txt
systemctl start chromadapt.service
echo "First run:"
journalctl -u chromadapt.service -n 3 --no-pager
echo ""
echo "Done. Check anytime with:  journalctl -u chromadapt.service -n 10"
