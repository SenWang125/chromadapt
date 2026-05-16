# chromadapt

Ambient light colour adaptation for Linux displays.

chromadapt reads your laptop's built-in colour sensor and subtly shifts the display's white point to match the ambient lighting — warm indoors, cool in daylight — so colours look natural in any environment. It runs as a systemd timer with no persistent process and skips silently when the light hasn't changed.

---

## Requirements

- Linux kernel with an IIO colour sensor exposing `in_chromaticity_x_raw` / `in_chromaticity_y_raw`
  > A lux-only ALS sensor is **not sufficient** — the sensor must report full chromaticity. Check with:
  > ```bash
  > ls /sys/bus/iio/devices/iio:device*/in_chromaticity_*
  > ```
- Python 3.6+ (no third-party packages)
- systemd
- One of:
  - **KDE Plasma 6+** with `kscreen-doctor`
  - **GNOME 43+** with `colormgr` (part of `colord`)

---

## Install

```bash
git clone https://github.com/SenWang125/chromadapt.git
cd chromadapt
sudo ./install.sh
```

The installer auto-detects your internal display, colour sensor, and desktop environment, shows you what it found, and asks for confirmation before writing anything.

### Uninstall

```bash
sudo ./uninstall.sh
```

The generated ICC file is left in place — remove it manually if needed, then reassign your display's colour profile in your DE's display settings.

---

## Supported environments

| Desktop | Version | Reload method |
|---|---|---|
| KDE Plasma | 6+ | `kscreen-doctor` — KWin applies ICC via its OpenGL compositor pipeline |
| GNOME | 43+ (Wayland + X11) | `colormgr` — colord system daemon, no session bus required |

> KDE Plasma 5 and GNOME versions before 43 are not supported.

---

## Configuration

After installing, the config lives at the top of `/usr/local/bin/chromadapt`:

| Variable | Default | Description |
|---|---|---|
| `STRENGTH` | `0.65` | Adaptation strength — 0.0 none, 1.0 full correction |
| `XY_THRESHOLD` | `0.005` | Minimum chromaticity shift to retrigger (≈50–100 K) |
| `CCT_MIN` | `3000` | Lower CCT clamp in Kelvin |
| `CCT_MAX` | `7500` | Upper CCT clamp in Kelvin |
| `LUX_MIN_RAW` | `50` | Skip below this illuminance (≈0.5 lux) |
| `BASE` | system sRGB | Base ICC profile for your display |
| `CONNECTOR` | auto-detected | Display connector name |
| `DE` | auto-detected | `'kde'` or `'gnome'` |

Timer interval is in `/etc/systemd/system/chromadapt.timer` (`OnUnitActiveSec=60`).

After any change, force an immediate update:
```bash
rm -f /tmp/chromadapt-last.txt && systemctl start chromadapt.service
```

### Choosing a base profile

For most sRGB panels the system profile (`/usr/share/color/icc/colord/sRGB.icc`) is correct. If you have a factory calibration profile for your specific panel, use that instead — it must be ICC v2 format with a `chad` tag.

---

## Tuning

More responsive — retriggers on smaller light changes:
```python
XY_THRESHOLD = 0.003
```
```ini
# chromadapt.timer
OnUnitActiveSec=30
```

Subtler feel:
```python
STRENGTH = 0.45
```

Stronger correction (closer to full mathematical adaptation):
```python
STRENGTH = 0.85
```

---

## Debugging

```bash
# Last run output
journalctl -u chromadapt.service -n 10

# Current ambient reading
python3 -c "
x = int(open('/sys/bus/iio/devices/iio:device1/in_chromaticity_x_raw').read()) / 10000
y = int(open('/sys/bus/iio/devices/iio:device1/in_chromaticity_y_raw').read()) / 10000
n = (x - 0.3320) / (0.1858 - y)
cct = 449*n**3 + 3525*n**2 + 6823.3*n + 5520.33
print(f'xy=({x:.4f},{y:.4f})  CCT={cct:.0f}K')
"

# Timer schedule
systemctl list-timers chromadapt.timer
```

---

## How it works

The colour temperature of ambient light shifts throughout the day. Under warm incandescent (~2700 K) everything has a yellow cast; under overcast sky (~7000 K) it skews cool. Your eyes adapt automatically — a display with a fixed profile does not.

chromadapt closes that gap with standard colorimetric math:

1. **Sensor read** — CIE xy chromaticity is read from the IIO colour sensor and converted to correlated colour temperature (CCT) via McCamy's formula.

2. **Planckian locus clamping** — The CCT is clamped to [3000 K, 7500 K] on the Planckian (blackbody) locus. Values outside this range produce Bradford scale factors that push ICC primary XYZ values outside any real display's physical gamut.

3. **Bradford chromatic adaptation transform** — A CAT is computed from the ambient white point to CIE D65 (the standard daylight reference). A blend factor (STRENGTH) scales the result so the correction feels natural rather than clinical.

4. **ICC profile write** — The transform is applied to the rXYZ, gXYZ, bXYZ primary tags in D50 PCS space, handled correctly via the profile's `chad` round-trip:
   ```
   M_eff = M_chad × blend(Bradford(W_ambient → D65), I, STRENGTH) × M_chad⁻¹
   ```

5. **Compositor reload** — KWin (KDE) or colord (GNOME) is notified to apply the updated profile.

---

## Tested hardware

Lenovo ThinkBook 16p Gen 4 — CSO MNE507ZA1-1 display, ROHM BH1745NUC colour sensor.

Compatible with any Linux laptop that exposes an IIO chromaticity sensor. Sensor IIO device indices vary by hardware — the installer detects them automatically.

---

## Licence

MIT
