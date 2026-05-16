#!/usr/bin/env bash
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "Run as root: sudo ./uninstall.sh"
    exit 1
fi

systemctl disable --now chromadapt.timer chromadapt.service 2>/dev/null || true

rm -f /etc/systemd/system/chromadapt.service
rm -f /etc/systemd/system/chromadapt.timer
rm -f /usr/local/bin/chromadapt
rm -f /tmp/chromadapt-last.txt

systemctl daemon-reload

echo "chromadapt removed."
echo ""
echo "The generated ICC profile (~/.local/share/icc/chromadapt-output.icc) was"
echo "left in place. Remove it manually if needed, then reassign your display's"
echo "colour profile in System Settings → Display → Colour Profile."
