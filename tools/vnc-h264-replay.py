# vnc-h264-replay.py - test a VNC viewer's H.264 decoder without the unit.
#
#   ssh root@<unit-ip> 'timeout 3 ustreamer-dump --sink kvmd::ustreamer::h264 --output /tmp/s.h264'
#   scp root@<unit-ip>:/tmp/s.h264 .
#   python tools/vnc-h264-replay.py s.h264 2560 1440 5901 30
#   vncviewer -PreferredEncoding=H.264 -AutoSelect=0 127.0.0.1:5901
#
# Minimal RFB 3.8 server that replays an Annex-B H.264 file to one client as
# Open H.264 rects (encoding 50), framed the way kvmd-vnc frames them: the
# first rect carries flags=1 (reset) and starts at an SPS; one access unit
# per rect; looped three times. If the viewer is black here, the viewer's
# decoder is the problem, not kvmd-vnc. Measured 2026-09-01: TigerVNC 1.16.2
# on Windows renders a 1920x1080 transcode of the unit's stream and stays
# black on 2560x1440, High or Main profile.
#
# Usage: vnc-h264-replay.py <file.h264> <width> <height> <port> [fps] [sps_every]
#   sps_every=1 prepends SPS+PPS to every rect (experiment).
import socket, struct, sys, time, threading

PATH, W, H, PORT = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
FPS = float(sys.argv[5]) if len(sys.argv) > 5 else 30.0
SPS_EVERY = int(sys.argv[6]) if len(sys.argv) > 6 else 0

data = open(PATH, "rb").read()
# split into NAL units on 00 00 01 (keeping 4-byte start codes)
nals = []
i = data.find(b"\x00\x00\x01")
while i >= 0:
    j = data.find(b"\x00\x00\x01", i + 3)
    start = i - 1 if i > 0 and data[i - 1] == 0 else i
    end = (j - 1 if j > 0 and data[j - 1] == 0 else j) if j >= 0 else len(data)
    nals.append(data[start:end]); i = j
def ntype(n):
    k = n.find(b"\x00\x00\x01") + 3
    return n[k] & 0x1f
sps = next(n for n in nals if ntype(n) == 7); pps = next(n for n in nals if ntype(n) == 8)
# group into access units: params + slices; a new AU starts at each slice NAL after a slice
aus, cur = [], b""
for n in nals:
    t = ntype(n)
    if t in (1, 5):
        cur += n; aus.append(cur); cur = b""
    elif t in (7, 8, 6, 9):
        cur += n
    else:
        cur += n
print("nals=%d access_units=%d first_au_types=%s" % (len(nals), len(aus), [ntype(n) for n in nals[:4]]))

srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", PORT)); srv.listen(1)
print("listening on 127.0.0.1:%d" % PORT); sys.stdout.flush()
c, addr = srv.accept(); c.settimeout(30)
def rd(n):
    buf = b""
    while len(buf) < n:
        ch = c.recv(n - len(buf))
        if not ch: raise EOFError
        buf += ch
    return buf
c.sendall(b"RFB 003.008\n"); rd(12)
c.sendall(b"\x01\x01"); assert rd(1) == b"\x01"; c.sendall(struct.pack(">I", 0))
rd(1)  # ClientInit
name = b"h264 replay"
c.sendall(struct.pack(">HH", W, H) + bytes([32, 24, 0, 1]) + struct.pack(">HHHBBB", 255, 255, 255, 16, 8, 0) + b"\x00\x00\x00" + struct.pack(">I", len(name)) + name)

encs = []
got_encodings = threading.Event()
def reader():
    global encs
    try:
        while True:
            t = rd(1)[0]
            if t == 0: rd(19)
            elif t == 2:
                rd(1); n = struct.unpack(">H", rd(2))[0]; encs = list(struct.unpack(">%di" % n, rd(4 * n))); got_encodings.set()
            elif t == 3: rd(9)
            elif t == 4: rd(7)
            elif t == 5: rd(5)
            elif t == 6: rd(3); n = struct.unpack(">I", rd(4))[0]; rd(n)
            elif t == 150: rd(9)
            else: print("unknown client msg", t); return
    except Exception as ex:
        print("reader done:", ex)
threading.Thread(target=reader, daemon=True).start()
got_encodings.wait(10)
print("client encodings:", encs[:12], "... has 50:", 50 in encs); sys.stdout.flush()
if 50 not in encs:
    sys.exit("client did not offer Open H.264")

sent = 0; t0 = time.time()
try:
    for idx in range(3 * len(aus)):
        au = aus[idx % len(aus)]
        first = (idx == 0)
        if idx % len(aus) == 0 and idx > 0:
            pass  # loop: the AU list starts with SPS/PPS/IDR anyway
        payload = au
        if SPS_EVERY and ntype(au[:64] if False else au) != 7 and not au.startswith(sps):
            payload = sps + pps + au
        hdr = struct.pack(">BBH", 0, 0, 1) + struct.pack(">HHHHi", 0, 0, W, H, 50) + struct.pack(">II", len(payload), 1 if first else 0)
        c.sendall(hdr + payload); sent += 1
        time.sleep(1.0 / FPS)
except Exception as ex:
    print("send stopped:", ex)
print("sent %d rects in %.1fs" % (sent, time.time() - t0))
