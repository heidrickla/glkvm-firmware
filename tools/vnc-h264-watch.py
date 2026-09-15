#!/usr/bin/env python3
"""vnc-h264-watch.py - what does kvmd-vnc send an Open H.264 viewer, rect by rect?

    ./tools/vnc-h264-watch.py <device-ip> [seconds]

Negotiates RFB 3.8 with security None, advertises Open H.264 (50) + Tight (7)
+ ExtendedDesktopSize (-223), then requests updates for a few seconds and
prints every rect: time, encoding, byte count, the H.264 flags word (bit 0 =
"reset decoder", which kvmd-vnc sets on the rect that carries a key frame),
and the NAL unit types found in it (7 SPS, 8 PPS, 5 IDR, 1 non-IDR slice).

A viewer that never receives a rect containing an IDR slice (type 5) shows
black forever, whatever its decoder does: that is what to look for.
"""
import socket
import struct
import sys
import time


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    host = sys.argv[1]
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 8.0
    s = socket.create_connection((host, 5900), timeout=10)

    def rd(n: int) -> bytes:
        b = b""
        while len(b) < n:
            c = s.recv(n - len(b))
            if not c:
                raise EOFError("server closed")
            b += c
        return b

    rd(12)
    s.sendall(b"RFB 003.008\n")
    n = rd(1)[0]
    types = rd(n)
    if 1 not in types:
        print("server offers no None security (%r); auth is on" % list(types))
        return 1
    s.sendall(b"\x01")
    if struct.unpack(">I", rd(4))[0] != 0:
        print("security handshake failed")
        return 1
    s.sendall(b"\x01")
    w, h = struct.unpack(">HH", rd(4))
    rd(16)
    rd(struct.unpack(">I", rd(4))[0])
    encs = [50, 7, -26, -223, 0]
    s.sendall(struct.pack(">BxH", 2, len(encs)) + b"".join(struct.pack(">i", e) for e in encs))

    def req(incr: int) -> None:
        s.sendall(struct.pack(">BBHHHH", 3, incr, 0, 0, w, h))

    req(0)
    s.settimeout(secs + 2)
    t0 = time.time()
    rects = []
    try:
        while time.time() - t0 < secs:
            mt = rd(1)[0]
            if mt != 0:
                rects.append((round(time.time() - t0, 2), "msg%d" % mt, 0, 0, []))
                break
            rd(1)
            nr = struct.unpack(">H", rd(2))[0]
            for _ in range(nr):
                x, y, rw, rh, enc = struct.unpack(">HHHHi", rd(12))
                if enc == 50:
                    ln, flags = struct.unpack(">II", rd(8))
                    data = rd(ln)
                    nals = []
                    p = 0
                    while len(nals) < 8:
                        k = data.find(b"\x00\x00\x01", p)
                        if k < 0:
                            break
                        nals.append(data[k + 3] & 0x1F)
                        p = k + 3
                    rects.append((round(time.time() - t0, 2), "H264", ln, flags, nals))
                elif enc == -223:
                    ns = rd(4)[0]
                    rd(3 + 16 * ns)
                    rects.append((round(time.time() - t0, 2), "resize", rw, rh, []))
                    w, h = rw, rh
                else:
                    rects.append((round(time.time() - t0, 2), "enc%d" % enc, rw, rh, []))
                    raise EOFError("unexpected encoding %d; stopping" % enc)
            req(1)
    except Exception as ex:  # pylint: disable=broad-except
        rects.append((round(time.time() - t0, 2), "end: %s" % str(ex)[:50], 0, 0, []))
    s.close()

    print("rects in %.0fs: %d" % (secs, len(rects)))
    for r in rects[:12]:
        print("  t=%-6s %-8s bytes=%-7s flags=%-3s nals=%s" % r)
    if len(rects) > 12:
        print("  ...")
    h264 = [r for r in rects if r[1] == "H264"]
    idr = [r for r in h264 if 5 in r[4]]
    flagged = [r for r in h264 if r[3] & 1]
    print("H264 rects: %d   with IDR slice: %d   with reset flag: %d" % (len(h264), len(idr), len(flagged)))
    if h264 and not idr:
        print("VERDICT: no key frame delivered - every viewer shows black")
        return 1
    if idr:
        print("first key frame at t=%s" % idr[0][0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
