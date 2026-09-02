# vnc-churn.py - reproduce TigerVNC's "Auto select" re-negotiation storm.
#
#   python tools/vnc-churn.py <unit-ip> 5900 8
#   ssh root@<unit-ip> 'grep -c "Started streamer" /var/log/kvmd.log'   # before and after
#
# Connects as an Open H.264 client, then re-sends SetEncodings every second
# with the Tight JPEG quality flipping 70 <-> 90 while reading whatever the
# server sends. Reports H.264 rects, key resets and bytes. Vendor kvmd-vnc
# re-applied streamer params on every SetEncodings, and on this firmware a
# quality change restarts ustreamer: 8 rounds = 8 restarts, 126 rects. With
# patches/kvmd/apps/vnc/server.py: 0 restarts, 471 rects, 1 key reset.
import socket, struct, sys, time, threading

HOST, PORT, ROUNDS = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
s = socket.create_connection((HOST, PORT), timeout=20)
def rd(n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk: raise EOFError("closed")
        buf += chunk
    return buf

rd(12); s.sendall(b"RFB 003.008\n")
ntypes = rd(1)[0]; types = list(rd(ntypes)); assert 1 in types; s.sendall(b"\x01")
assert struct.unpack(">I", rd(4))[0] == 0; s.sendall(b"\x01")
w, h = struct.unpack(">HH", rd(4)); rd(16); rd(struct.unpack(">I", rd(4))[0])

def set_encodings(quality_enc):
    encs = [50, 7, quality_enc, -223, 0]
    s.sendall(struct.pack(">BBH", 2, 0, len(encs)) + b"".join(struct.pack(">i", e) for e in encs))
def request(inc):
    s.sendall(struct.pack(">BBHHHH", 3, inc, 0, 0, w, h))

stats = {"h264": 0, "resets": 0, "jpeg": 0, "bytes": 0, "other": 0}
stop = False
def reader():
    global w, h
    try:
        while not stop:
            mtype = rd(1)[0]
            if mtype != 0:
                continue
            rd(1); nrects = struct.unpack(">H", rd(2))[0]
            for _ in range(nrects):
                x, y, rw, rh, enc = struct.unpack(">HHHHi", rd(12))
                if enc == 50:
                    length, flags = struct.unpack(">II", rd(8)); rd(length)
                    stats["h264"] += 1; stats["bytes"] += length; stats["resets"] += (flags & 1)
                elif enc == -223:
                    w, h = rw, rh
                elif enc == 7:
                    ctl = rd(1)[0]
                    if (ctl >> 4) == 9:
                        n = 0; shift = 0
                        while True:
                            b = rd(1)[0]; n |= (b & 0x7f) << shift; shift += 7
                            if not (b & 0x80): break
                        rd(n); stats["jpeg"] += 1
                    else:
                        stats["other"] += 1; return
                else:
                    stats["other"] += 1; return
            request(1)
    except Exception as ex:
        stats["error"] = repr(ex)

set_encodings(-26); request(0)
t = threading.Thread(target=reader, daemon=True); t.start()
for i in range(ROUNDS):
    time.sleep(1.0)
    set_encodings(-24 if i % 2 == 0 else -26)   # 90 <-> 70, like Auto select
stop = True; time.sleep(0.5)
print("rounds=%d  h264_rects=%d  key_resets=%d  h264_bytes=%d  jpeg_rects=%d  other=%d  error=%s" % (
    ROUNDS, stats["h264"], stats["resets"], stats["bytes"], stats["jpeg"], stats["other"], stats.get("error")))
s.close()
