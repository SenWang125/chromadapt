# chromadapt

Ambient light colour adaptation for Linux displays.

chromadapt reads chromaticity from a hardware IIO ambient colour sensor, computes a **Bradford chromatic adaptation transform (CAT)** on the **Planckian locus**, and writes a modified ICC profile so display colours appear perceptually consistent under any lighting condition — warm incandescent, cool fluorescent, or neutral daylight.

It runs as a lightweight systemd timer, waking every 60 seconds with no persistent process. When the ambient light hasn't changed significantly it skips immediately (hysteresis). When it does update, a single `kscreen-doctor` call tells KWin to reload the profile — zero per-frame CPU cost at steady state.

---

## How it works

The colour temperature of ambient light shifts throughout the day and varies by environment. Under warm incandescent light (~2700 K) everything has a yellow-orange cast; under overcast daylight (~7000 K) it skews cool blue. The human visual system adapts to this automatically — your brain learns what "white" looks like — but a display with a fixed colour profile does not.

chromadapt bridges that gap:

1. **Sensor read** — Chromaticity coordinates (CIE xy) are read from the IIO colour sensor and converted to correlated colour temperature (CCT) via McCamy's formula.

2. **Planckian locus clamping** — The ambient CCT is clamped to [3000 K, 7500 K] on the Planckian (blackbody) locus. Values outside this range produce numerically unstable Bradford scale factors that push ICC primary XYZ values out of any real display's physical gamut.

3. **Bradford CAT** — A chromatic adaptation transform is computed from the ambient white point to CIE D65 (the standard daylight reference). A blend factor (default 0.65) scales the correction so it matches Windows Adaptive Colour in feel rather than applying a full mathematical correction that can look artificial.

4. **ICC profile write** — The transform is applied to the rXYZ, gXYZ, bXYZ primary tags of the base ICC profile (which live in D50 PCS space, handled correctly via the profile's `chad` round-trip). The result is written to a new ICC file.

5. **KWin reload** — `kscreen-doctor` instructs KWin to apply the updated profile. KWin applies it via its OpenGL compositor pipeline.

The math in brief:

```
M_eff = M_chad × blend(Bradford(W_ambient → D65), I, strength) × M_chad⁻¹
```

Applied to each primary XYZ triplet in the ICC profile.

---

## Requirements

- **Linux kernel** with IIO colour sensor exposing:
  - `in_chromaticity_x_raw` and `in_chromaticity_y_raw`
  - `in_illuminance_raw` (used as a low-light guard)

  > A simple ambient light sensor (ALS) that provides only lux is **not sufficient**. The sensor must expose full chromaticity readings. Check with:
  > ```
  > ls /sys/bus/iio/devices/iio:device*/in_chromaticity_*
  > ```

- **KDE Plasma 6 / KWin 6**
- **Python 3.6+** (no third-party dependencies)
- **kscreen-doctor** (part of `kscreen`, pre-installed with Plasma)
- An **ICC base profile** matching your display's native colour space (v2 ICC with `chad` tag)

---

## Hardware

Tested on: **Lenovo ThinkBook 16p Gen 4**
- Display: CSO MNE507ZA1-1 (sRGB, 120 Hz)
- Colour sensor: ROHM BH1745NUC via `iio:device1`
- Illuminance sensor: `iio:device0`

Likely compatible with any laptop that exposes an IIO chromaticity sensor and runs KDE Plasma 6. Sensor device indices vary by hardware — check yours before configuring.

---

## Installation

```bash
git clone https://github.com/YOUR_USERNAME/chromadapt.git
cd chromadapt
sudo ./install.sh
```

The installer substitutes your username and UID into the systemd service, copies the script to `/usr/local/bin/chromadapt`, and enables the timer.

### Configuration

Open `/usr/local/bin/chromadapt` and edit the `Configuration` block near the top:

| Variable | Default | Description |
|---|---|---|
| `SENSOR_X` | `iio:device1/in_chromaticity_x_raw` | Chromaticity X sensor path |
| `SENSOR_Y` | `iio:device1/in_chromaticity_y_raw` | Chromaticity Y sensor path |
| `SENSOR_LX` | `iio:device0/in_illuminance_raw` | Illuminance sensor path |
| `BASE` | `/usr/share/color/icc/colord/sRGB.icc` | Base ICC profile for your display |
| `CONNECTOR` | `eDP-2` | Display connector name |
| `STRENGTH` | `0.65` | Adaptation strength (0.0 – 1.0) |
| `XY_THRESHOLD` | `0.005` | Minimum xy shift to retrigger (~50–100 K) |
| `CCT_MIN` | `3000` | Lower CCT clamp (K) |
| `CCT_MAX` | `7500` | Upper CCT clamp (K) |
| `LUX_MIN_RAW` | `50` | Skip below this illuminance (≈0.5 lux) |

Find your connector name:
```bash
kscreen-doctor -o | grep Output
```

Find your sensor indices:
```bash
grep -r '' /sys/bus/iio/devices/iio:device*/name 2>/dev/null
```

After editing, force a fresh run:
```bash
rm -f /tmp/chromadapt-last.txt
systemctl start chromadapt.service
journalctl -u chromadapt.service -n 5
```

#### Choosing a base profile

The base profile should represent your display's native colour space. For most sRGB panels the system profile works well:

```
/usr/share/color/icc/colord/sRGB.icc
```

If you have a factory calibration profile for your specific panel, use that instead. The profile must be ICC v2 format and contain a `chad` (chromatic adaptation) tag.

---

## Tuning

**More responsive** (retriggers on smaller lighting changes):
```python
XY_THRESHOLD = 0.003   # was 0.005
```
And in `chromadapt.timer`:
```ini
OnUnitActiveSec=30     # was 60
```

**Subtler effect** (less visible correction):
```python
STRENGTH = 0.45        # was 0.65
```

**Stronger effect** (closer to full mathematical correction):
```python
STRENGTH = 0.85
```

---

## Uninstall

```bash
sudo ./uninstall.sh
```

The generated ICC file (`~/.local/share/icc/chromadapt-output.icc`) is left in place. Remove it manually if needed, then reassign your display's colour profile in **System Settings → Display → Colour Profile**.

---

## Status / debugging

```bash
# Live output from the last run
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

## Licence

MIT
