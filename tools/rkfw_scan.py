#!/usr/bin/env python3
"""Scan a Rockchip RKFW/RKAF firmware container: header fields + magic map."""
import sys, struct, collections

MAGICS = {
    b"RKFW": "RKFW container header",
    b"RKAF": "RKAF embedded update image",
    b"BOOT": "boot/loader section",
    b"LDR ": "loader",
    b"KRNL": "kernel blob",
    b"PARM": "parameter/partition table",
    b"RKNS": "RKNS",
    b"hsqs": "squashfs (LE)",
    b"sqsh": "squashfs (BE)",
    b"\x1f\x8b\x08": "gzip",
    b"\xfd7zXZ\x00": "xz",
    b"\x28\xb5\x2f\xfd": "zstd",
    b"ANDROID!": "android boot image",
    b"UBI#": "UBI",
    b"CrAU": "chromeos update",
}

def scan(path, limit=None):
    data = open(path, "rb").read()
    print(f"file : {path}")
    print(f"size : {len(data):,} bytes\n")

    if data[:4] == b"RKFW":
        hdr_size = struct.unpack_from("<H", data, 4)[0]
        print(f"RKFW header size : 0x{hdr_size:x} ({hdr_size})")
        # Locate the embedded RKAF by magic rather than trusting offsets.
        print(f"raw header       : {data[:hdr_size].hex()}\n")

    print("magic map (first 40 hits):")
    hits = []
    for magic, name in MAGICS.items():
        start = 0
        while True:
            i = data.find(magic, start)
            if i < 0:
                break
            hits.append((i, magic, name))
            start = i + 1
            if len(hits) > 4000:
                break
    hits.sort()
    seen = collections.Counter()
    shown = 0
    for off, magic, name in hits:
        seen[name] += 1
        # only show the first few of each kind to keep output readable
        if seen[name] <= 3 and shown < 40:
            print(f"  0x{off:010x}  {magic!r:12} {name}")
            shown += 1
    print("\ntotals by type:")
    for name, n in seen.most_common():
        print(f"  {n:6}  {name}")

if __name__ == "__main__":
    scan(sys.argv[1])
