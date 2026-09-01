#!/bin/sh
# panel.sh - drive the GL-RM10's front LCD from your workstation.
#
#   ./tools/panel.sh <device-ip> preview [home|kvmd]   # PNG only, panel untouched
#   ./tools/panel.sh <device-ip> show    [home|kvmd]   # take the panel, draw once
#   ./tools/panel.sh <device-ip> run     [home|kvmd] [interval]
#   ./tools/panel.sh <device-ip> restore               # give it back to GL.iNet
#   ./tools/panel.sh <device-ip> capture               # what is on screen right now
#
# The panel is a 456x180 colour DSI LCD on /dev/fb0 (framebuffer is portrait
# 180x456; the panel is mounted rotated). It is NOT the i2c OLED that
# `kvmd-oled` drives -- that tool cannot work on this hardware.
#
# TAKING THE PANEL NEEDS TWO STOPS, NOT ONE
#
# /usr/sbin/gl_kvm_gui owns /dev/fb0, and /usr/bin/gl_kvm_monitor (a Lua
# watchdog, /etc/init.d/S99gl_kvm_monitor) polls `pidof gl_kvm_gui` and runs
# `/etc/init.d/S39gl-kvm-gui start` the moment it disappears. Stop only the GUI
# and it is back within seconds, repainting over whatever you drew -- which
# looks like your blit silently failed. Stop the monitor FIRST.
#
# That same watchdog also supervises connman, repeater, gl_kvm_ap,
# gl-kvm-modem and kvmd-rndis, so leave it stopped no longer than you need to.
# `restore` always puts both back, in the right order.
#
# `preview` needs none of this: it renders to a PNG on the device and pulls it
# back, so you can iterate on the design without ever disturbing the display.

set -eu

IP="${1:-}"
CMD="${2:-}"
ARG="${3:-}"
ARG2="${4:-}"

HERE="$(cd "$(dirname "$0")" && pwd)"
KEY="$HERE/../.ssh-glkvm/id_ed25519"
REMOTE=/userdata/panel

GUI=/etc/init.d/S39gl-kvm-gui
MON=/etc/init.d/S99gl_kvm_monitor

die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$IP" ] && [ -n "$CMD" ] \
  || die "usage: $0 <device-ip> preview|show|run|restore|capture [screen] [interval]"
echo "$IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
  || die "'$IP' is not a bare IPv4 address (refusing hostnames - mDNS can hit the wrong unit)"

SSH="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@$IP"
$SSH true 2>/dev/null || die "cannot ssh to $IP"

SCREEN="${ARG:-home}"

push() {
    $SSH "mkdir -p $REMOTE"
    $SSH "cat > $REMOTE/panel.py" < "$HERE/panel.py"
}

# Pull a PNG back as base64 - a raw binary stream through this shell layer is
# not trustworthy, and base64 costs nothing at this size.
pull_png() {
    _remote="$1"; _local="$2"
    $SSH "base64 -w0 '$_remote'" | python -c "
import base64, sys
sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))
" > "$_local"
    echo "   wrote $_local"
}

take_panel() {
    echo ">> taking the panel (stopping the watchdog first, then the GUI)"
    $SSH "$MON stop >/dev/null 2>&1 || true; sleep 1; $GUI stop >/dev/null 2>&1 || true; sleep 1"
}

case "$CMD" in
    preview)
        push
        echo ">> rendering '$SCREEN' to a PNG (panel untouched)"
        $SSH "cd $REMOTE && python3 panel.py --screen '$SCREEN' --out $REMOTE/preview.png" \
          | sed 's/^/   /'
        pull_png "$REMOTE/preview.png" "$HERE/../panel-preview-$SCREEN.png"
        ;;

    show)
        push
        take_panel
        $SSH "cd $REMOTE && python3 panel.py --screen '$SCREEN'"
        echo "   drew '$SCREEN'"
        echo ""
        echo "   the panel is yours until you run: $0 $IP restore"
        ;;

    run)
        push
        take_panel
        _int="${ARG2:-5}"
        $SSH "cd $REMOTE && (setsid python3 panel.py --screen '$SCREEN' --interval '$_int' \
                 >$REMOTE/panel.log 2>&1 &) ; sleep 2; echo '   started, refreshing every ${_int}s'"
        echo ""
        echo "   stop and hand back with: $0 $IP restore"
        ;;

    restore)
        echo ">> stopping any panel loop of ours"
        # Match on the script path, never a bare name - a pattern that also
        # matches this ssh command's own argv kills the session running it.
        $SSH "for p in /proc/[0-9]*; do
                  if grep -qa '$REMOTE/panel.py' \$p/cmdline 2>/dev/null; then
                      kill \${p#/proc/} 2>/dev/null || true
                  fi
              done; sleep 1"
        echo ">> restarting GL.iNet's GUI and watchdog"
        $SSH "$GUI start >/dev/null 2>&1 || true; sleep 2; $MON start >/dev/null 2>&1 || true; sleep 2"
        $SSH "$GUI status 2>&1" | sed 's/^/   /'
        ;;

    capture)
        echo ">> reading /dev/fb0 as it is right now"
        # Convert on the DEVICE: it has PIL, and this way the only local
        # dependency is base64 from the standard library.
        $SSH "mkdir -p $REMOTE && python3 - <<'PY'
from PIL import Image
raw = open('/dev/fb0', 'rb').read(180 * 456 * 4)
img = Image.frombytes('RGBA', (180, 456), raw, 'raw', 'BGRA').convert('RGB')
# Framebuffer is portrait; the panel is mounted rotated, so turn it to
# landscape to see it the way it actually reads on the device.
img.rotate(-90, expand=True).save('$REMOTE/capture.png')
print('   %d bytes -> 456x180' % len(raw))
PY"
        pull_png "$REMOTE/capture.png" "$HERE/../panel-capture.png"
        ;;

    *)
        die "unknown command '$CMD' (preview|show|run|restore|capture)"
        ;;
esac
