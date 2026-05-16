#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_USER="${SUDO_USER:-$USER}"
INSTALL_UID="$(id -u "$INSTALL_USER")"

# ── Intro ─────────────────────────────────────────────────────────────────────
cat <<'EOF'

chromadapt installer
════════════════════
An ambient colour-adaptive display system.

Reads your laptop's ambient colour sensor every 60 seconds and adjusts the
display ICC profile so colours look consistent under any lighting — warm
indoors, cool in daylight. Runs as a systemd timer with no persistent process.

Prerequisites:
  • Python 3.6+
  • systemd
  • KDE Plasma 6+  →  kscreen-doctor (usually pre-installed)
  • GNOME 43+      →  colormgr  (install: colord package)
  • An IIO colour sensor with in_chromaticity_x/y_raw  (not just lux)

EOF

if [[ "$EUID" -ne 0 ]]; then
    echo "Please run as root:  sudo ./install.sh"; exit 1
fi

# ── Prerequisite check ────────────────────────────────────────────────────────
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
$HAS_KSCREEN  && echo "  ✓ kscreen-doctor"
$HAS_COLORMGR && echo "  ✓ colormgr"

# Warn about old installation that will be replaced
if [[ -f /etc/systemd/system/adaptive-color.service ]]; then
    echo ""
    echo "  Note: existing 'adaptive-color' service detected — will be replaced."
fi
echo ""

# ── Helper: always-visible numbered picker ────────────────────────────────────
# Usage: pick "prompt" default_index "opt1" "opt2" ...
# Sets global PICKED to the chosen option string.
pick() {
    local prompt="$1" default="$2"; shift 2
    local -a opts=("$@")
    echo "  $prompt"
    for i in "${!opts[@]}"; do
        local n=$((i+1))
        [[ $n -eq $default ]] \
            && echo "    $n) ${opts[$i]}  [default]" \
            || echo "    $n) ${opts[$i]}"
    done
    while true; do
        read -rp "  Choice [$default]: " c; c="${c:-$default}"
        if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#opts[@]} )); then
            PICKED="${opts[$((c-1))]}"; return
        fi
        echo "  Please enter a number between 1 and ${#opts[@]}."
    done
}

# ── Display connector ─────────────────────────────────────────────────────────
echo "─── Display connector ───────────────────────────────────────────────────"

mapfile -t ALL_CONN < <(
    for p in /sys/class/drm/card*-*/; do
        [[ -d "$p" ]] || continue
        n=$(basename "$p" | sed 's/card[0-9]*-//')
        [[ "$n" == "card"* ]] && continue
        echo "$n"
    done | sort -u
)

DEFAULT_CONN=1
DETECTED_CONN=""

# KDE: read directly from KWin's output config — most reliable source
KWIN_CONF="/home/${INSTALL_USER}/.config/kwinoutputconfig.json"
if [[ -f "$KWIN_CONF" ]]; then
    DETECTED_CONN=$(python3 - <<PYEOF
import json
try:
    cfg = json.load(open("$KWIN_CONF"))
    for s in cfg:
        if s.get("name") == "outputs":
            for o in s["data"]:
                c = o.get("connectorName", "")
                if c.startswith("eDP"):
                    print(c); exit()
except: pass
PYEOF
)
fi

# Fallback: first eDP port with non-empty EDID (physically connected)
if [[ -z "$DETECTED_CONN" ]]; then
    for p in /sys/class/drm/card*-eDP-*/; do
        [[ -s "$p/edid" ]] && DETECTED_CONN=$(basename "$p" | sed 's/card[0-9]*-//') && break
    done
fi

for i in "${!ALL_CONN[@]}"; do
    [[ "${ALL_CONN[$i]}" == "$DETECTED_CONN" ]] && DEFAULT_CONN=$((i+1)) && break
done

if [[ ${#ALL_CONN[@]} -eq 0 ]]; then
    echo "  No DRM connectors found."; read -rp "  Enter connector name: " CONNECTOR
else
    pick "Select display connector (internal panel recommended):" "$DEFAULT_CONN" "${ALL_CONN[@]}"
    CONNECTOR="$PICKED"
fi
echo "  → $CONNECTOR"; echo ""

# ── Colour sensor (chromaticity) ──────────────────────────────────────────────
echo "─── Colour sensor ───────────────────────────────────────────────────────"
echo "  Needs in_chromaticity_x/y_raw — a lux-only ALS is not sufficient."
echo ""

mapfile -t ALL_IIO < <(
    for d in /sys/bus/iio/devices/iio:device*; do
        [[ -d "$d" ]] || continue
        name=$(cat "$d/name" 2>/dev/null || echo "unknown")
        tag=""
        [[ -f "$d/in_chromaticity_x_raw" ]] && tag=" ✓ chromaticity"
        echo "$(basename $d)  ($name)$tag"
    done
)

DEFAULT_SENS=1
DETECTED_SENS=""
for d in /sys/bus/iio/devices/iio:device*; do
    [[ -f "$d/in_chromaticity_x_raw" ]] && DETECTED_SENS=$(basename "$d") && break
done
for i in "${!ALL_IIO[@]}"; do
    [[ "${ALL_IIO[$i]}" == "$DETECTED_SENS"* ]] && DEFAULT_SENS=$((i+1)) && break
done

if [[ ${#ALL_IIO[@]} -eq 0 ]]; then
    echo "  No IIO devices found. chromadapt cannot run on this hardware."; exit 1
fi

pick "Select colour sensor (choose one marked ✓ chromaticity):" "$DEFAULT_SENS" "${ALL_IIO[@]}"
SENSOR_DEV=$(echo "$PICKED" | awk '{print $1}')
echo "  → $SENSOR_DEV"; echo ""

# ── Illuminance sensor (lux guard) ────────────────────────────────────────────
echo "─── Illuminance sensor ──────────────────────────────────────────────────"
echo "  Used to skip adaptation in near-darkness (unreliable readings < ~0.5 lux)."
echo ""

mapfile -t ALL_LX < <(
    for d in /sys/bus/iio/devices/iio:device*; do
        [[ -d "$d" ]] || continue
        name=$(cat "$d/name" 2>/dev/null || echo "unknown")
        tag=""
        [[ -f "$d/in_illuminance_raw" ]] && tag=" ✓ illuminance"
        echo "$(basename $d)  ($name)$tag"
    done
)

DEFAULT_LX=1
DETECTED_LX=""
for d in /sys/bus/iio/devices/iio:device*; do
    [[ -f "$d/in_illuminance_raw" ]] && DETECTED_LX=$(basename "$d") && break
done
for i in "${!ALL_LX[@]}"; do
    [[ "${ALL_LX[$i]}" == "$DETECTED_LX"* ]] && DEFAULT_LX=$((i+1)) && break
done

pick "Select illuminance sensor (choose one marked ✓ illuminance):" "$DEFAULT_LX" "${ALL_LX[@]}"
SENSOR_LX_DEV=$(echo "$PICKED" | awk '{print $1}')
echo "  → $SENSOR_LX_DEV"; echo ""

# ── Desktop environment ───────────────────────────────────────────────────────
echo "─── Desktop environment ─────────────────────────────────────────────────"

DE_OPTS=()
$HAS_KSCREEN  && DE_OPTS+=("kde   — KDE Plasma 6+  (kscreen-doctor)")
$HAS_COLORMGR && DE_OPTS+=("gnome — GNOME 43+       (colormgr / colord)")
[[ ${#DE_OPTS[@]} -eq 0 ]] && DE_OPTS=("kde   — KDE Plasma 6+  (kscreen-doctor)" "gnome — GNOME 43+       (colormgr / colord)")

DESKTOP=$(su -l "$INSTALL_USER" -c 'echo "$XDG_CURRENT_DESKTOP"' 2>/dev/null || echo "")
DEFAULT_DE=1
echo "$DESKTOP" | grep -qi gnome && DEFAULT_DE=2

pick "Select desktop environment:" "$DEFAULT_DE" "${DE_OPTS[@]}"
DE=$(echo "$PICKED" | awk '{print $1}')
echo "  → $DE"; echo ""

# ── Base ICC profile ──────────────────────────────────────────────────────────
echo "─── Base ICC profile ────────────────────────────────────────────────────"
echo "  Must be a v2 ICC profile with a 'chad' tag."
echo "  For most sRGB panels the system profile is correct."
echo "  For wide-gamut panels, use your display's factory calibration profile."
echo ""

mapfile -t SYS_ICC < <(
    find /usr/share/color/icc /usr/share/colord -name "*.icc" 2>/dev/null \
    | grep -i 'srgb\|sRGB' | sort
)
mapfile -t ALL_ICC < <(
    find /usr/share/color/icc /usr/share/colord -name "*.icc" 2>/dev/null | sort
)
# Prefer sRGB hits; fall back to all profiles; add generate option
ICC_OPTS=()
[[ ${#SYS_ICC[@]} -gt 0 ]] && ICC_OPTS+=("${SYS_ICC[@]}") || ICC_OPTS+=("${ALL_ICC[@]}")
ICC_OPTS+=("[ Generate minimal sRGB profile → ~/.local/share/icc/sRGB-chromadapt.icc ]")
ICC_OPTS+=("[ Enter path manually ]")

DEFAULT_ICC=1

pick "Select base ICC profile:" "$DEFAULT_ICC" "${ICC_OPTS[@]}"
BASE_ICC="$PICKED"

if [[ "$BASE_ICC" == "[ Generate"* ]]; then
    GENERATED_ICC="/home/${INSTALL_USER}/.local/share/icc/sRGB-chromadapt.icc"
    echo "  Generating sRGB profile..."
    su -l "$INSTALL_USER" -c "python3 '$SCRIPT_DIR/generate_srgb_profile.py' '$GENERATED_ICC'"
    BASE_ICC="$GENERATED_ICC"
elif [[ "$BASE_ICC" == "[ Enter"* ]]; then
    read -rp "  Path: " BASE_ICC
fi

echo "  → $BASE_ICC"; echo ""

# ── Install ───────────────────────────────────────────────────────────────────
SENSOR_X_PATH="/sys/bus/iio/devices/${SENSOR_DEV}/in_chromaticity_x_raw"
SENSOR_Y_PATH="/sys/bus/iio/devices/${SENSOR_DEV}/in_chromaticity_y_raw"
SENSOR_LX_PATH="/sys/bus/iio/devices/${SENSOR_LX_DEV}/in_illuminance_raw"

echo "Installing..."

# Migrate away from old service name if present
if [[ -f /etc/systemd/system/adaptive-color.service ]]; then
    systemctl disable --now adaptive-color.timer adaptive-color.service 2>/dev/null || true
    rm -f /etc/systemd/system/adaptive-color.{service,timer}
    rm -f /usr/local/bin/adaptive-color.py
    echo "  ✓ Removed old adaptive-color service"
fi

# Patch config into script and install
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

install -m 644 "$SCRIPT_DIR/generate_srgb_profile.py" /usr/local/lib/chromadapt-generate-profile.py

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
RUN_SINCE=$(date --iso-8601=seconds)
systemctl start chromadapt.service
echo "First run:"
journalctl -u chromadapt.service --since "$RUN_SINCE" --no-pager
echo ""
echo "Done. Check anytime:  journalctl -u chromadapt.service -n 10"
