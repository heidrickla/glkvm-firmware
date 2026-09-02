# vnc-probe.py - prove what kvmd-vnc actually sends, without a GUI viewer.
#
#   python tools/vnc-probe.py <unit-ip> 5900 50,7,-26,-223,0    # an Open H.264 viewer
#   python tools/vnc-probe.py <unit-ip> 5900 7,-26,-223,0       # a Tight-only viewer (TightVNC)
#
# Minimal RFB 3.8 client: connect, security None (kvmd auth off), advertise the
# encodings a given viewer would, request updates and report the first three
# rects: "H264" with the Open H.264 length/flags, or "TightJPEG" with the JPEG
# length. No pixels are rendered. kvmd-vnc insists on a Tight JPEG quality
# pseudo-encoding (-32..-23) and closes the connection without one, so keep
# -26 in the list. A 9.5 KB TightJPEG that never changes size is kvmd-vnc's
# "Waiting for stream" placeholder, not video.
import socket, struct, sys, time

HOST, PORT = sys.argv[1], int(sys.argv[2])
ENCODINGS = [int(e) for e in sys.argv[3].split(",")]  # e.g. "50,7" or "7"

s = socket.create_connection((HOST, PORT), timeout=15)
def rd(n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise EOFError("server closed after %d/%d bytes" % (len(buf), n))
        buf += chunk
    return buf

ver = rd(12); print("server version:", ver.decode().strip())
s.sendall(b"RFB 003.008\n")
ntypes = rd(1)[0]
types = list(rd(ntypes)); print("security types offered:", types)
if 1 not in types:
    sys.exit("security type None (1) not offered - this probe only speaks None")
s.sendall(b"\x01")
result = struct.unpack(">I", rd(4))[0]; print("security result:", "OK" if result == 0 else result)
s.sendall(b"\x01")  # ClientInit, shared
w, h = struct.unpack(">HH", rd(4)); rd(16); nlen = struct.unpack(">I", rd(4))[0]; name = rd(nlen)
print("framebuffer: %dx%d  name=%r" % (w, h, name.decode(errors="replace")))
s.sendall(struct.pack(">BBH", 2, 0, len(ENCODINGS)) + b"".join(struct.pack(">i", e) for e in ENCODINGS))
print("advertised encodings:", ENCODINGS)

def request(incremental):
    s.sendall(struct.pack(">BBHHHH", 3, incremental, 0, 0, w, h))

deadline = time.time() + 12
seen = []
request(0)
while time.time() < deadline and len(seen) < 3:
    mtype = rd(1)[0]
    if mtype != 0:
        print("server message type", mtype, "(not an update) - skipping"); continue
    rd(1); nrects = struct.unpack(">H", rd(2))[0]
    for _ in range(nrects):
        x, y, rw, rh, enc = struct.unpack(">HHHHi", rd(12))
        if enc == 50:
            length, flags = struct.unpack(">II", rd(8)); data = rd(length)
            seen.append(("H264", length, flags, data[:4].hex()))
        elif enc == 7:
            # Tight: read control byte, then JPEG (0x90) length + data
            ctl = rd(1)[0]
            if (ctl >> 4) == 9:
                n = 0; shift = 0
                while True:
                    b = rd(1)[0]; n |= (b & 0x7f) << shift; shift += 7
                    if not (b & 0x80): break
                data = rd(n); seen.append(("TightJPEG", n, ctl, data[:2].hex()))
            else:
                seen.append(("Tight-other", ctl, 0, "")); break
        else:
            seen.append(("enc%d" % enc, rw, rh, "")); break
    request(1)
for i, item in enumerate(seen):
    print("update %d: %s  bytes=%s flags/ctl=%s head=%s" % (i + 1, *item))
if not seen:
    print("no framebuffer update arrived within 12 s")
s.close()
