#!/bin/sh
# ocr.sh - read text off the attached machine's screen, from your workstation.
#
#   ./tools/ocr.sh <device-ip> install --vm <build-vm-ip>   # one-time: tesseract onto the unit
#   ./tools/ocr.sh <device-ip> status
#   ./tools/ocr.sh <device-ip> read [--crop L,T,R,B] [--keep /local.jpg]
#   ./tools/ocr.sh <device-ip> read --file </path/on/device.jpg>
#   ./tools/ocr.sh <device-ip> remove                        # exactly what install added
#
# WHAT IS ACTUALLY GOING ON, because three assumptions here were wrong once
#
# * GL.iNet's 1.10.0 kvmd is wired for OCR on the Rockchip NPU via an
#   `ocr_service` daemon over /run/kvmd/ocr-service.sock. That daemon exists in
#   NO shipped firmware (checked 1.8.1 on the device and the 1.10.0 rootfs).
#   The NPU and librknnrt.so are there; the service is not. So tesseract it is.
#
# * The device is aarch64 glibc 2.41 (Buildroot), measured two ways, so Ubuntu
#   noble's prebuilt arm64 libtesseract5 loads as-is. No cross-compile. The
#   dependency closure (23 packages) is resolved from the real package index by
#   tools/ocr-fetch.py on the build VM, and the device-side installer copies in
#   ONLY sonames the unit lacks -- it never overwrites a Buildroot library.
#
# * kvmd's own OCR endpoint, GET /api/streamer/snapshot?ocr=1, needs a snapshot
#   from kvmd's streamer -- and on 1.8.1 that streamer NEVER RUNS. GL.iNet
#   stripped the executable out of streamer.cmd; video goes through their own
#   rv1126 -> janus path, which produces no JPEG anyone can fetch, and no
#   memsink exists in /dev/shm. So `read` grabs a frame itself: it starts the
#   shipped (GL.iNet-patched) ustreamer on /dev/video0 for a few seconds, asks
#   its unix socket for /snapshot, and stops it. Measured: auto-negotiated
#   format, ~49 KB JPEG, ~4 s. It refuses if something else already holds
#   /dev/video0, rather than fight the vendor pipeline while someone is watching.
#
#   That ustreamer IGNORES SIGTERM. A plain kill followed by wait hangs forever
#   -- it cost a 10-minute timeout to learn. It gets SIGKILL.
#
# Everything installed is listed in /etc/kvmd/user/ocr-installed.txt on the
# unit, so `remove` takes out exactly that and nothing else.

set -eu

IP="${1:-}"
CMD="${2:-}"
shift 2 2>/dev/null || true

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
KEY="$ROOT/.ssh-glkvm/id_ed25519"
VMKEY="$ROOT/.ssh-buildvm/id_ed25519"
PAYLOAD="$ROOT/wheels/ocr-payload.tar.gz"
MANIFEST=/etc/kvmd/user/ocr-installed.txt

die() { echo "ERROR: $*" >&2; exit 1; }
ok()  { printf '  ok   %s\n' "$*"; }

[ -n "$IP" ] && [ -n "$CMD" ] || die "usage: $0 <device-ip> install|status|read|remove ..."
echo "$IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || die "'$IP' is not a bare IPv4 address"

SSH="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@$IP"
$SSH -n true 2>/dev/null || die "cannot ssh to $IP"

# On-device OCR of one JPEG, through the same C API kvmd's ocr.py uses.
# Sent over ssh as a script on stdin so nothing here depends on kvmd internals
# that differ between 1.8.1 and 1.10.0.
ocr_py() {
    cat <<'PY'
import ctypes, sys
from ctypes import c_int, c_char_p, c_void_p, POINTER, c_char
from PIL import Image
path = sys.argv[1]
crop = sys.argv[2] if len(sys.argv) > 2 else ""
lib = ctypes.CDLL("/usr/lib/libtesseract.so.5")
lib.TessBaseAPICreate.restype = c_void_p
lib.TessBaseAPIInit3.argtypes = [c_void_p, c_char_p, c_char_p]; lib.TessBaseAPIInit3.restype = c_int
lib.TessBaseAPISetVariable.argtypes = [c_void_p, c_char_p, c_char_p]
lib.TessBaseAPISetImage.argtypes = [c_void_p, c_void_p, c_int, c_int, c_int, c_int]
lib.TessBaseAPIGetUTF8Text.argtypes = [c_void_p]; lib.TessBaseAPIGetUTF8Text.restype = POINTER(c_char)
lib.TessBaseAPIDelete.argtypes = [c_void_p]
lib.TessDeleteText.argtypes = [c_void_p]
api = lib.TessBaseAPICreate()
if lib.TessBaseAPIInit3(api, b"/usr/share/tessdata", b"eng") != 0:
    sys.exit("tesseract init failed - is /usr/share/tessdata/eng.traineddata present?")
lib.TessBaseAPISetVariable(api, b"debug_file", b"/dev/null")
im = Image.open(path).convert("RGB")
if crop:
    l, t, r, b = (int(v) for v in crop.split(","))
    im = im.crop((max(l, 0), max(t, 0), min(r, im.width) if r >= 0 else im.width,
                  min(b, im.height) if b >= 0 else im.height))
# Screens are not documents. Tesseract is trained on dark text on light paper;
# a console, a BIOS, or the capture bridge's own "NO LIVE VIDEO" splash is the
# opposite, in a pixel font, at native resolution. Measured on that splash:
# raw frame read "WO LIVE VIDEO". So: grayscale, invert when the frame is
# mostly dark, upscale 2x, and threshold to clean bilevel before handing over.
from PIL import ImageOps
g = ImageOps.grayscale(im)
if sum(g.histogram()[i] * i for i in range(256)) / max(1, g.width * g.height) < 128:
    g = ImageOps.invert(g)
# autocontrast first: after inversion the splash text sat at ~165 on a 255
# background, and a fixed threshold of 140 pushed it INTO the background --
# the first run of this returned no text at all. Stretching to full range
# puts text at ~0 and background at 255, so a midpoint threshold is safe.
g = ImageOps.autocontrast(g, cutoff=1)
g = g.resize((g.width * 2, g.height * 2), Image.LANCZOS)
g = g.point(lambda v: 255 if v > 128 else 0)
w, h = g.size
buf = g.tobytes()
lib.TessBaseAPISetImage(api, buf, w, h, 1, w)
p = lib.TessBaseAPIGetUTF8Text(api)
text = ctypes.string_at(p).decode("utf-8", "replace")
lib.TessDeleteText(p); lib.TessBaseAPIDelete(api)
sys.stdout.write(text)
PY
}

case "$CMD" in
# ---------------------------------------------------------------- install
install)
    VM=""
    [ "${1:-}" = "--vm" ] && VM="${2:-}"
    if [ ! -f "$PAYLOAD" ]; then
        [ -n "$VM" ] || die "no $PAYLOAD - pass --vm <build-vm-ip> to fetch it"
        VSSH="ssh -i $VMKEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new claude@$VM"
        $VSSH -n true 2>/dev/null || die "cannot ssh to build VM $VM"
        if ! $VSSH -n 'test -s ~/ocr/ocr-payload.tar.gz'; then
            echo ">> resolving the tesseract package closure on $VM"
            $VSSH 'mkdir -p ~/ocr && cat > ~/ocr/ocr-fetch.py' < "$HERE/ocr-fetch.py"
            $VSSH -n 'cd ~/ocr && python3 ocr-fetch.py ~/ocr' | grep -v '^  index:'
        fi
        mkdir -p "$ROOT/wheels"
        $VSSH -n 'cat ~/ocr/ocr-payload.tar.gz' > "$PAYLOAD"
        rsha=$($VSSH -n 'sha256sum ~/ocr/ocr-payload.tar.gz | cut -c1-64')
        [ "$(sha256sum "$PAYLOAD" | cut -c1-64)" = "$rsha" ] || die "payload pull corrupted"
        ok "payload pulled: $(wc -c < "$PAYLOAD" | tr -d ' ') bytes"
    fi

    echo ">> pushing payload to $IP"
    $SSH 'rm -rf /userdata/ocr-stage && mkdir -p /userdata/ocr-stage && cat > /userdata/ocr-stage/p.tgz' < "$PAYLOAD"
    echo ">> installing (only sonames the unit lacks; nothing is overwritten)"
    $SSH -n "set -e
        cd /userdata/ocr-stage && tar -xzf p.tgz
        mkdir -p /etc/kvmd/user /usr/share/tessdata
        touch $MANIFEST
        added=0; skipped=0; bytes=0
        for f in lib/*; do
            n=\$(basename \"\$f\")
            if [ -e \"/usr/lib/\$n\" ] || [ -e \"/lib/\$n\" ]; then skipped=\$((skipped+1)); continue; fi
            cp -a \"\$f\" /usr/lib/\"\$n\"
            echo \"/usr/lib/\$n\" >> $MANIFEST
            added=\$((added+1)); bytes=\$((bytes + \$(stat -c %s \"\$f\")))
        done
        for f in tessdata/*; do
            n=\$(basename \"\$f\")
            [ -e \"/usr/share/tessdata/\$n\" ] && continue
            cp \"\$f\" /usr/share/tessdata/\"\$n\"; echo \"/usr/share/tessdata/\$n\" >> $MANIFEST
            added=\$((added+1)); bytes=\$((bytes + \$(stat -c %s \"\$f\")))
        done
        # kvmd's own loader on 1.8.1: ctypes.util.find_library() returns None
        # here (no ldconfig binary), and its hard-coded fallback list is ONLY
        # /usr/lib/libtesseract.so.3.0.5 -- tesseract-3 era. 1.10.0 adds .so.5.
        # Every C symbol it binds exists in 5.x, so a symlink at the old name
        # lets kvmd report ocr enabled=true on 1.8.1 without touching its .pyc.
        if [ ! -e /usr/lib/libtesseract.so.3.0.5 ] && [ -e /usr/lib/libtesseract.so.5 ]; then
            ln -s libtesseract.so.5 /usr/lib/libtesseract.so.3.0.5
            echo /usr/lib/libtesseract.so.3.0.5 >> $MANIFEST
            added=\$((added+1))
        fi
        sort -u $MANIFEST -o $MANIFEST
        echo \"  added \$added files (\$((bytes/1048576)) MB), skipped \$skipped already present\"
        cd / && rm -rf /userdata/ocr-stage
        printf '  load test: '
        python3 -c 'import ctypes; ctypes.CDLL(\"/usr/lib/libtesseract.so.5\"); print(\"libtesseract.so.5 loads with all dependencies\")'"

    echo ">> functional test: OCR a synthetic image rendered on the device"
    $SSH 'python3 - <<PY
from PIL import Image, ImageDraw, ImageFont
im = Image.new("RGB", (640, 140), "white")
try:
    f = ImageFont.truetype("/etc/rm10-gui/fonts/IBMPlexSans-Medium.ttf", 56)
except Exception:
    f = ImageFont.load_default()
ImageDraw.Draw(im).text((20, 30), "GLKVM 12345", fill="black", font=f)
im.save("/tmp/ocr-test.jpg", quality=92)
PY'
    got=$(ocr_py | $SSH 'cat > /tmp/ocr.py && python3 /tmp/ocr.py /tmp/ocr-test.jpg; rm -f /tmp/ocr.py /tmp/ocr-test.jpg' | tr -d '\r' | tr '\n' ' ')
    case "$got" in
        *GLKVM*12345*) ok "read back: '$(echo "$got" | sed 's/  */ /g;s/ *$//')'" ;;
        *) die "tesseract ran but read '$got' - expected GLKVM 12345" ;;
    esac

    echo ">> restarting kvmd so its ocr module picks the library up"
    $SSH -n '/etc/init.d/S98kvmd restart >/dev/null 2>&1; sleep 14'
    curl -sk --max-time 15 "https://$IP/api/streamer/ocr" 2>/dev/null | sed 's/^/  /' | head -12
    echo "  (kvmd reports it; its own snapshot path still needs a running streamer - use 'read')"
    ;;

# ---------------------------------------------------------------- status
status)
    $SSH -n "printf '  manifest      : %s files\n' \"\$(wc -l < $MANIFEST 2>/dev/null || echo 0)\"
             printf '  libtesseract  : '; python3 -c 'import ctypes; ctypes.CDLL(\"/usr/lib/libtesseract.so.5\"); print(\"loads\")' 2>&1 | tail -1
             printf '  tessdata      : %s\n' \"\$(ls /usr/share/tessdata 2>/dev/null | tr '\n' ' ')\"
             printf '  /dev/video0   : %s\n' \"\$(for p in /proc/[0-9]*; do for fd in \$p/fd/*; do t=\$(readlink \"\$fd\" 2>/dev/null); case \"\$t\" in /dev/video0) echo \"held by pid \${p#/proc/}\";; esac; done; done 2>/dev/null | sort -u | head -1)\"; echo"
    printf '  kvmd ocr api  : '; curl -sk --max-time 12 "https://$IP/api/streamer/ocr" 2>/dev/null | tr -d ' \n' | cut -c1-120; echo
    ;;

# ---------------------------------------------------------------- read
read)
    FILE=""; CROP=""; KEEP=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --file) FILE="${2:?}"; shift 2 ;;
            --crop) CROP="${2:?}"; shift 2 ;;
            --keep) KEEP="${2:?}"; shift 2 ;;
            *) die "unknown option $1" ;;
        esac
    done
    if [ -z "$FILE" ]; then
        # Grab a frame ourselves. Refuse to open the capture node under
        # whatever is already using it -- that is the vendor video path with a
        # viewer attached, and two readers on one CIF node is not a test worth
        # running on someone's live session.
        if $SSH -n 'for p in /proc/[0-9]*; do for fd in $p/fd/*; do t=$(readlink "$fd" 2>/dev/null); case "$t" in /dev/video0) exit 0;; esac; done; done 2>/dev/null; exit 1'; then
            die "/dev/video0 is in use (someone is viewing the stream) - try again later or pass --file"
        fi
        # The 1.8.1 ustreamer build returned the bridge's own "NO LIVE VIDEO"
        # splash when the host was silent; the 1.10.0 build logs "waiting for
        # HDMI signal" and never serves a frame. So a failure here is usually
        # the host not outputting video -- say so, with the streamer's own words.
        $SSH -n 'rm -f /tmp/ocr-us.sock /tmp/ocr-frame.jpg /tmp/ocr-us.log
            ustreamer --device=/dev/video0 --unix=/tmp/ocr-us.sock --unix-rm --device-timeout=2 --workers=1 --quality=90 --log-level=1 >/tmp/ocr-us.log 2>&1 &
            pid=$!
            code=000; n=0
            while [ $n -lt 12 ]; do
                sleep 1; n=$((n+1))
                [ -S /tmp/ocr-us.sock ] || continue
                # -w prints 000 itself when the request fails; no fallback echo,
                # which once produced "HTTP 000000".
                code=$(curl -s --max-time 4 --unix-socket /tmp/ocr-us.sock -o /tmp/ocr-frame.jpg -w "%{http_code}" http://localhost/snapshot 2>/dev/null)
                [ "$code" = "200" ] && break
            done
            # SIGTERM is ignored by this build; SIGKILL, then reap.
            kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null; rm -f /tmp/ocr-us.sock
            if [ "$code" != "200" ] || [ ! -s /tmp/ocr-frame.jpg ]; then
                reason=$(grep -iE "waiting for HDMI|no signal|error" /tmp/ocr-us.log | tail -1 | sed "s/.*-- //")
                echo "no frame after ${n}s (HTTP ${code:-000})${reason:+: $reason}" >&2
                rm -f /tmp/ocr-us.log; exit 1
            fi
            rm -f /tmp/ocr-us.log
            printf "  frame: %s bytes\n" "$(wc -c < /tmp/ocr-frame.jpg)"' || die "could not capture a frame (on 1.10.0 the capture needs a live HDMI signal from the host)"
        FILE=/tmp/ocr-frame.jpg
        [ -n "$KEEP" ] && { $SSH -n 'cat /tmp/ocr-frame.jpg' > "$KEEP"; ok "frame saved to $KEEP"; }
    fi
    echo "  --- text ---"
    ocr_py | $SSH "cat > /tmp/ocr.py && python3 /tmp/ocr.py '$FILE' '$CROP'; rc=\$?; rm -f /tmp/ocr.py; [ '$FILE' = /tmp/ocr-frame.jpg ] && rm -f /tmp/ocr-frame.jpg; exit \$rc" | tr -d '\r'
    ;;

# ---------------------------------------------------------------- remove
remove)
    $SSH -n "if [ ! -s $MANIFEST ]; then echo '  nothing installed'; exit 0; fi
             n=0; while IFS= read -r f; do rm -f \"\$f\" && n=\$((n+1)); done < $MANIFEST
             rm -f $MANIFEST; rmdir /usr/share/tessdata 2>/dev/null || true
             echo \"  removed \$n files listed in the manifest\"
             /etc/init.d/S98kvmd restart >/dev/null 2>&1; sleep 14"
    printf '  kvmd ocr api now: '; curl -sk --max-time 12 "https://$IP/api/streamer/ocr" 2>/dev/null | tr -d ' \n' | cut -c1-100; echo
    ;;

*) die "unknown command '$CMD' (install|status|read|remove)" ;;
esac
