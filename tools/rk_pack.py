#!/usr/bin/env python3
"""Rebuild a GL.iNet Comet RKFW firmware image, optionally replacing a partition.

Format (measured on glkvm-RM10-1.10.0 — see FINDINGS.md):

    [RKFW hdr 0x66][loader][RKAF blob][RKCRC32 4B LE][Ed25519 sig 64B][MD5 32B ascii]

Two checksums are recomputed:
  * RKCRC32 over the RKAF blob — polynomial 0x04c10db7 (NOT the standard
    0x04c11db7, which produces the wrong value), MSB-first, init 0, no xorout.
  * MD5 over file[:-32] — i.e. INCLUDING the signature — stored as ascii hex.

The 64-byte Ed25519 signature is copied verbatim. It cannot be forged, and does
not need to be: POST /api/upgrade/start?skip_verify=true skips the check that
uses it. The non-skippable gate is check_image_validity, which lives on the
device and is the real oracle for a rebuilt image.

Usage:
    rk_pack.py <src.img> --selftest                 # rebuild unmodified, expect identical
    rk_pack.py <src.img> <out.img> <part> <file>    # replace one partition
"""
import hashlib
import os
import struct
import sys

POLY = 0x04C10DB7
_TBL = []
for _i in range(256):
    _c = _i << 24
    for _ in range(8):
        _c = ((_c << 1) ^ POLY) & 0xFFFFFFFF if _c & 0x80000000 else (_c << 1) & 0xFFFFFFFF
    _TBL.append(_c)

# Vendor images align partition bodies to 2048. Using 512 here silently re-lays
# every partition — rootfs moves EARLIER and the growth is absorbed into another
# partition's padding, which looks plausible and is wrong.
ALIGN = 2048
PAD = bytes([0])


def rkcrc(buf):
    crc = 0
    for b in buf:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ _TBL[((crc >> 24) ^ b) & 0xFF]
    return crc


def parse(path):
    d = open(path, "rb").read()
    ldr_off, ldr_sz, img_off, img_sz = struct.unpack_from("<IIII", d, 0x19)
    rkaf = bytearray(d[img_off:img_off + img_sz - 4])
    sig = d[img_off + img_sz:img_off + img_sz + 64]
    n = struct.unpack_from("<I", rkaf, 136)[0]
    parts = []
    for i in range(n):
        o = 140 + i * 112
        e = rkaf[o:o + 112]
        parts.append({
            "off": o,
            "name": e[0:32].split(b"\x00")[0].decode(),
            "pos": struct.unpack_from("<I", e, 96)[0],
            "size": struct.unpack_from("<I", e, 108)[0],
        })
    return {"d": d, "img_off": img_off, "rkaf": rkaf, "sig": sig, "parts": parts}


def build(src, out, replace=None, verbose=True):
    m = parse(src)
    rkaf, parts = m["rkaf"], m["parts"]

    if replace:
        name, newfile = replace
        newdata = open(newfile, "rb").read()
        tgt = next(p for p in parts if p["name"] == name)
        if verbose:
            print("  replacing %s: %d -> %d bytes" % (name, tgt["size"], len(newdata)))

        # Preserve the original layout: everything BEFORE the target keeps its
        # exact offset; the target and everything after it are re-laid at ALIGN.
        movable = [p for p in parts if p["pos"] != 0xFFFFFFFF]
        after = sorted([p for p in movable if p["pos"] > tgt["pos"]], key=lambda x: x["pos"])

        body = bytearray(rkaf[:tgt["pos"]])
        body += newdata
        body += PAD * ((-len(body)) % ALIGN)
        struct.pack_into("<I", rkaf, tgt["off"] + 108, len(newdata))

        for p in after:
            struct.pack_into("<I", rkaf, p["off"] + 96, len(body))
            body += bytes(rkaf[p["pos"]:p["pos"] + p["size"]])
            body += PAD * ((-len(body)) % ALIGN)

        # header/table were patched in place on the old buffer; copy them over
        body[:tgt["pos"]] = rkaf[:tgt["pos"]]
        rkaf = body

    struct.pack_into("<I", rkaf, 4, len(rkaf))
    crc = rkcrc(bytes(rkaf))

    head = bytearray(m["d"][:m["img_off"]])
    struct.pack_into("<I", head, 0x25, len(rkaf) + 4)

    blob = bytes(head) + bytes(rkaf) + struct.pack("<I", crc) + m["sig"]
    blob += hashlib.md5(blob).hexdigest().encode()
    open(out, "wb").write(blob)

    if verbose:
        print("  RKAF length : %d" % len(rkaf))
        print("  RKCRC32     : 0x%08x" % crc)
        print("  MD5         : %s" % hashlib.md5(blob[:-32]).hexdigest())
        print("  wrote %s (%d bytes)" % (out, os.path.getsize(out)))
    return out


if __name__ == "__main__":
    src = sys.argv[1]
    if sys.argv[2] == "--selftest":
        print("=== SELF-TEST: reassemble unmodified, expect byte-identical ===")
        build(src, "/tmp/selftest.img")
        a = hashlib.sha256(open(src, "rb").read()).hexdigest()
        b = hashlib.sha256(open("/tmp/selftest.img", "rb").read()).hexdigest()
        print("  original : %s" % a)
        print("  rebuilt  : %s" % b)
        print("  IDENTICAL" if a == b else "  DIFFER")
        sys.exit(0 if a == b else 1)
    build(src, sys.argv[2], replace=(sys.argv[3], sys.argv[4]))
