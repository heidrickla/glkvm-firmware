#!/bin/sh
# flash.sh - flash a Comet KVM with an image built by tools/bake-image.sh.
#
#   ./tools/flash.sh <device-ip> firmware/glkvm-RM10-1.10.0-provisioned.img
#
# THIS IS THE IRREVERSIBLE STEP. It wipes the overlay (`updateEngine --n`),
# which is every change ever made on the running unit that is not inside the
# image. Only run it on a unit Lewis has named, with an image the device has
# already accepted through `check_image_validity` and `fwtools verify`.
#
# What happens, in order, on the device's own API (measured against the
# 1.8.1 handler constants and the 1.10.0 source, which agree):
#
#   1. POST /api/upgrade/upload   multipart field "file" -> /userdata/update.img
#      (the filename is ignored; needs Content-Length; refuses if /userdata is
#      short of space -- a stale 291 MB staging copy once sat there)
#   2. POST /api/upgrade/start?skip_verify=true
#      skip_verify skips ONLY the Ed25519 signature check, because a stock
#      unit still carries GL.iNet's public key. check_image_validity still
#      runs. On "Upgrade started" the device syncs and reboots itself ~1 s
#      later; the update is applied from the misc-partition flag on that boot
#      and the unit reboots again into the new system.
#   3. GET /api/upgrade/status is a stub ({"enabled": true}) -- there is no
#      progress API. Progress is: the unit disappears, then answers ssh again.
#
# AFTER THE FLASH, THE OLD CHECKPOINTS ARE POISON. Every checkpoint taken on
# 1.8.1 holds a 1.8.1 site-packages tree; restoring one onto a 1.10.0 base
# would put 1.8.1 bytecode under a 1.10.0 kvmd. Take a fresh checkpoint on the
# new base and use only that.
#
# SSH comes back on its own: the baked image carries our public key in
# /root/.ssh/authorized_keys, so no browser-console bootstrap is needed.

set -eu

IP="${1:-}"
IMG="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
KEY="$ROOT/.ssh-glkvm/id_ed25519"

die() { echo "FAIL: $*" >&2; exit 1; }
ok()  { printf '  ok   %s\n' "$*"; }

[ -n "$IP" ] && [ -n "$IMG" ] || die "usage: $0 <device-ip> <image.img>"
echo "$IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || die "'$IP' is not a bare IPv4 address"
[ -f "$IMG" ] || die "no such image: $IMG"

SSH="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 root@$IP"
API="https://$IP/api"

# ---------------------------------------------------------------- preflight
echo "=== preflight on $IP ==="
$SSH -n true 2>/dev/null || die "cannot ssh to $IP"
model=$($SSH -n 'cat /proc/gl-hw-info/model 2>/dev/null' | tr -d '\r\n')
[ "$model" = "rm10" ] || die "device reports model '$model', not rm10 - refusing"
before=$($SSH -n 'grep -E "^VERSION=" /etc/os-release | cut -d= -f2' | tr -d '\r\n"')
ok "model rm10, running $before"

size=$(wc -c < "$IMG" | tr -d ' ')
free=$($SSH -n 'df -k /userdata | awk "NR==2{print \$4*1024}"' | tr -d '\r\n')
[ "$free" -gt $((size + 20 * 1048576)) ] \
    || die "/userdata has $free bytes free; image is $size bytes. Clear it first (a stale update.img or signed.img is the usual culprit)."
ok "/userdata free $((free / 1048576)) MB for a $((size / 1048576)) MB image"

# The image must already have passed the device's gates; refuse to be the
# first place that finds out otherwise. Stage on the media partition (27 GB),
# not /userdata, so this check cannot itself consume the upload's space.
lsha=$(sha256sum "$IMG" | cut -c1-64)
rsha=$($SSH 'mkdir -p /userdata/media/.flashcheck && cat > /userdata/media/.flashcheck/img && sha256sum /userdata/media/.flashcheck/img | cut -c1-64' < "$IMG" | tr -d '\r\n')
[ "$lsha" = "$rsha" ] || die "staging upload corrupted"
verdict=$($SSH -n 'cd /userdata/media/.flashcheck && check_image_validity img 2>&1; echo "exit=$?"; cd / && rm -rf /userdata/media/.flashcheck' | tr '\n' ' ')
case "$verdict" in
    *Valid*exit=0*) ok "check_image_validity: Valid" ;;
    *) die "check_image_validity said: $verdict" ;;
esac

manifest=$("$ROOT/tools/rkfw_scan.py" "$IMG" 2>/dev/null | head -3 | tr '\n' ' ' || true)
[ -n "$manifest" ] && echo "  image: $manifest"
echo "  image sha256 $lsha"
echo ""
echo "  About to flash $IP ($before -> the image above)."
echo "  The overlay will be wiped. Continuing in 5 seconds; Ctrl-C to abort."
sleep 5

# ---------------------------------------------------------------- upload
echo "=== upload ==="
resp=$(curl -sk --max-time 900 -F "file=@$IMG;filename=update.img" "$API/upgrade/upload" 2>/dev/null) || die "upload request failed"
up_size=$(printf '%s' "$resp" | sed -n 's/.*"size":[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
[ "$up_size" = "$size" ] || die "device stored $up_size bytes, sent $size: $resp"
ok "device holds /userdata/update.img, $up_size bytes"

# ---------------------------------------------------------------- start
echo "=== start (skip_verify=true: our key is not installed yet; validity still checked) ==="
resp=$(curl -sk --max-time 120 -X POST "$API/upgrade/start?skip_verify=true" 2>/dev/null) || die "start request failed"
printf '%s\n' "$resp" | sed 's/^/  /'
printf '%s' "$resp" | grep -q '"Upgrade started"' || die "device did not start the upgrade"
ok "upgrade started; the device reboots itself now"

# ---------------------------------------------------------------- wait
echo "=== waiting for the unit to go away and come back (update applies on the reboot) ==="
gone=0
n=0
while [ $n -lt 60 ]; do
    sleep 10; n=$((n + 1))
    if [ $gone -eq 0 ]; then
        if ! $SSH -n true 2>/dev/null; then gone=1; echo "  $((n * 10))s: down - applying"; fi
    else
        if $SSH -n true 2>/dev/null; then echo "  $((n * 10))s: back"; break; fi
    fi
done
[ $gone -eq 1 ] || die "the unit never went down - did the upgrade start?"
$SSH -n true 2>/dev/null || die "the unit did not come back within $((n * 10))s"
sleep 20   # let kvmd and nginx finish starting

# ---------------------------------------------------------------- verify
echo "=== after ==="
$SSH -n 'printf "  version   : %s\n" "$(grep -E "^VERSION=" /etc/os-release | cut -d= -f2)"
         printf "  bake      : %s\n" "$(head -1 /etc/glkvm-bake.txt 2>/dev/null || echo MISSING - not our image?)"
         printf "  signing   : %s\n" "$( [ -f /etc/firmware/key/public.raw.glinet ] && echo "our key installed, vendor kept" || echo "vendor key only")"
         printf "  vnc hook  : %s\n" "$( [ -x /etc/kvmd/user/scripts/S99kvmd-vnc ] && echo present || echo MISSING)"
         printf "  tesseract : %s\n" "$(python3 -c "import ctypes; ctypes.CDLL(\"/usr/lib/libtesseract.so.5\"); print(\"loads\")" 2>&1 | tail -1)"
         printf "  overlay   : %s free\n" "$(df -h /userdata | awk "NR==2{print \$4}")"'
for spec in "443:https://$IP/" "8888:https://$IP:8888/login/" "prometheus:https://$IP/api/export/prometheus/metrics" "msd:https://$IP/api/msd"; do
    code=$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' "${spec#*:}" 2>/dev/null || echo 000)
    printf '  %-10s HTTP %s\n' "${spec%%:*}" "$code"
done
banner=$(timeout 6 sh -c "exec 3<>/dev/tcp/$IP/5900 && head -c 11 <&3" 2>/dev/null || true)
printf '  %-10s %s\n' "vnc" "${banner:-no RFB banner}"

echo ""
echo "  Done. Take a NEW checkpoint on this base and never restore a pre-flash one:"
echo "    $ROOT/tools/checkpoint.sh $IP flashed-1.10.0"
