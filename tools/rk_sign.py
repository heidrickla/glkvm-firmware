#!/usr/bin/env python3
"""Sign a rebuilt GL.iNet Comet RKFW image with a raw 32-byte Ed25519 key.

The signature covers file[:-96] — header + loader + RKAF + CRC, i.e. everything
before the signature itself. Determined by verifying GL.iNet's own signature
against candidate ranges with their public key.

Afterwards the trailing MD5 (over file[:-32], which INCLUDES the signature) is
recomputed, or the image fails fwtools' MD5 check.
"""
import hashlib
import sys

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

img, keyfile = sys.argv[1], sys.argv[2]
out = sys.argv[3] if len(sys.argv) > 3 else img

d = bytearray(open(img, "rb").read())
key = Ed25519PrivateKey.from_private_bytes(open(keyfile, "rb").read())

signed_range = bytes(d[:-96])
sig = key.sign(signed_range)
assert len(sig) == 64, len(sig)
d[-96:-32] = sig
d[-32:] = hashlib.md5(bytes(d[:-32])).hexdigest().encode()

open(out, "wb").write(bytes(d))
print("  signed %d bytes" % len(signed_range))
print("  sig    : %s..." % sig.hex()[:32])
print("  md5    : %s" % hashlib.md5(bytes(d[:-32])).hexdigest())
print("  wrote  : %s" % out)
