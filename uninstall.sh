#!/usr/bin/env bash
set -euo pipefail

INSTALL_USER="${SUDO_USER:-$USER}"
INSTALL_UID="$(id -u "$INSTALL_USER")"

if [[ "$EUID" -ne 0 ]]; then
    echo "Run as root: sudo ./uninstall.sh"
    exit 1
fi

_user_ctl() {
    sudo -u "$INSTALL_USER" \
        XDG_RUNTIME_DIR="/run/user/${INSTALL_UID}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${INSTALL_UID}/bus" \
        systemctl --user "$@" 2>/dev/null || true
}

# Stop and disable user service
_user_ctl disable --now chromadapt

# Remove user service file
rm -f "/home/${INSTALL_USER}/.config/systemd/user/chromadapt.service"
_user_ctl daemon-reload

# Remove system files
rm -f /usr/lib/systemd/system-sleep/chromadapt
rm -f /usr/local/bin/chromadapt
rm -f /usr/local/lib/chromadapt-generate-profile.py
rm -f /tmp/chromadapt-last.txt

# Remove old system-level service if somehow still present
systemctl disable --now chromadapt.timer chromadapt.service 2>/dev/null || true
rm -f /etc/systemd/system/chromadapt.{service,timer}

systemctl daemon-reload

echo "chromadapt removed."
echo ""
echo "The generated ICC profile (~/.local/share/icc/chromadapt-output.icc) was"
echo "left in place. Remove it manually if needed, then reassign your display's"
echo "colour profile in System Settings → Display → Colour Profile."
