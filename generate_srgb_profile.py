#!/usr/bin/env python3
"""
Generate a minimal valid ICC v2 sRGB display profile.
For use as a chromadapt base profile when no system sRGB profile is available.

Primaries: IEC 61966-2-1 sRGB (D65), adapted to D50 PCS via Bradford CAT.
TRC:       Gamma 2.2 (single-entry 'curv' tag; chromadapt only reads XYZ primaries).
"""
import struct, sys, datetime
from pathlib import Path


def s15f16(v):
    return max(-0x80000000, min(0x7FFFFFFF, round(v * 65536)))

def pack_xyz(x, y, z):
    return b'XYZ ' + b'\x00'*4 + struct.pack('>iii', s15f16(x), s15f16(y), s15f16(z))

def pack_sf32(m):
    return b'sf32' + b'\x00'*4 + struct.pack('>9i',
        *[s15f16(m[r][c]) for r in range(3) for c in range(3)])

def pack_curv_gamma(gamma):
    g = min(0xFFFF, round(gamma * 256))
    return b'curv' + b'\x00'*4 + struct.pack('>IH', 1, g) + b'\x00\x00'

def pack_desc(text):
    s = text.encode('ascii', 'replace') + b'\x00'
    body  = struct.pack('>I', len(s)) + s
    body += b'\x00'*4 + b'\x00'*4   # Unicode language code + count
    body += b'\x00'*2                # Scriptcode
    body += b'\x00'                  # Macintosh count
    body += b'\x00'*67              # Macintosh description
    raw   = b'desc' + b'\x00'*4 + body
    return raw + b'\x00' * ((4 - len(raw) % 4) % 4)

def mv(m, v):
    return [sum(m[i][j] * v[j] for j in range(3)) for i in range(3)]


# Bradford D65→D50 chromatic adaptation (standard sRGB chad)
CHAD = [
    [ 1.0478112,  0.0228866, -0.0501270],
    [ 0.0295424,  0.9904844, -0.0170491],
    [-0.0092345,  0.0150436,  0.7521316],
]

# sRGB primaries in D65 XYZ (IEC 61966-2-1), adapted to D50 PCS
rXYZ = mv(CHAD, [0.4124564, 0.2126729, 0.0193339])
gXYZ = mv(CHAD, [0.3575761, 0.7151522, 0.1191920])
bXYZ = mv(CHAD, [0.1804375, 0.0721750, 0.9503041])


def build():
    T_CHAD = pack_sf32(CHAD)
    T_RXYZ = pack_xyz(*rXYZ)
    T_GXYZ = pack_xyz(*gXYZ)
    T_BXYZ = pack_xyz(*bXYZ)
    T_WTPT = pack_xyz(0.9642957, 1.0, 0.8251046)   # D50
    T_TRC  = pack_curv_gamma(2.2)                   # shared by r/g/bTRC
    T_DESC = pack_desc('sRGB (chromadapt)')
    T_CPRT = pack_desc('Public Domain')

    # 10 tag entries; gTRC/bTRC intentionally share rTRC's offset
    TAG_DEFS = [
        ('chad', T_CHAD), ('rXYZ', T_RXYZ), ('gXYZ', T_GXYZ), ('bXYZ', T_BXYZ),
        ('wtpt', T_WTPT), ('rTRC', T_TRC),  ('gTRC', T_TRC),  ('bTRC', T_TRC),
        ('desc', T_DESC), ('cprt', T_CPRT),
    ]

    N = len(TAG_DEFS)
    DATA_START = 128 + 4 + N * 12   # header + count + table

    # Assign offsets, de-duplicating by object identity (TRC sharing)
    seen, offsets, off = {}, {}, DATA_START
    for sig, blob in TAG_DEFS:
        bid = id(blob)
        if bid not in seen:
            seen[bid] = off
            off += len(blob)
        offsets[sig] = seen[bid]
    total = off

    # Header
    now = datetime.datetime.utcnow()
    hdr = bytearray(128)
    struct.pack_into('>I',   hdr,  0, total)
    hdr[8:12]  = b'\x02\x10\x00\x00'   # ICC v2.1
    hdr[12:16] = b'mntr'
    hdr[16:20] = b'RGB '
    hdr[20:24] = b'XYZ '
    struct.pack_into('>6H', hdr, 24,
        now.year, now.month, now.day, now.hour, now.minute, now.second)
    hdr[36:40] = b'acsp'
    struct.pack_into('>iii', hdr, 68,
        s15f16(0.9642957), s15f16(1.0), s15f16(0.8251046))   # D50 illuminant

    # Assemble
    data = bytes(hdr) + struct.pack('>I', N)
    for sig, blob in TAG_DEFS:
        data += sig.encode() + struct.pack('>II', offsets[sig], len(blob))
    written = set()
    for _, blob in TAG_DEFS:
        if id(blob) not in written:
            data += blob
            written.add(id(blob))

    assert len(data) == total
    return data


if __name__ == '__main__':
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('/tmp/sRGB-chromadapt.icc')
    out.parent.mkdir(parents=True, exist_ok=True)
    profile = build()
    out.write_bytes(profile)
    print(f"Generated: {out}  ({len(profile)} bytes)")
