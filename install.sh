#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_USER="${SUDO_USER:-$USER}"
INSTALL_UID="$(id -u "$INSTALL_USER")"

if [[ "$EUID" -ne 0 ]]; then
    echo "Run as root: sudo ./install.sh"
    exit 1
fi

echo "Installing chromadapt for user: $INSTALL_USER (uid=$INSTALL_UID)"

# Install main script
install -m 755 "$SCRIPT_DIR/chromadapt" /usr/local/bin/chromadapt

# Install systemd units with user substituted in
sed \
    -e "s/CHROMADAPT_USER/$INSTALL_USER/g" \
    -e "s/CHROMADAPT_UID/$INSTALL_UID/g" \
    "$SCRIPT_DIR/chromadapt.service" \
    > /etc/systemd/system/chromadapt.service

install -m 644 "$SCRIPT_DIR/chromadapt.timer" /etc/systemd/system/chromadapt.timer

systemctl daemon-reload
systemctl enable --now chromadapt.timer

echo ""
echo "Done. chromadapt will run every 60 seconds."
echo ""
echo "Before first use, edit /usr/local/bin/chromadapt and set:"
echo "  BASE      — path to your display's ICC base profile"
echo "  CONNECTOR — your display connector (run: kscreen-doctor -o | grep Output)"
echo "  SENSOR_X / SENSOR_Y / SENSOR_LX — IIO device paths for your sensor"
echo ""
echo "Then clear the state and trigger a first run:"
echo "  rm -f /tmp/chromadapt-last.txt && systemctl start chromadapt.service"
echo ""
echo "Check status:  journalctl -u chromadapt.service -n 10"
