#!/bin/sh
# apply-file.sh - install one file from rootfs/ onto a Comet KVM, reversibly.
#
#   ./tools/apply-file.sh <device-ip> rootfs/usr/sbin/reset_uvc_udc
#   ./tools/apply-file.sh <device-ip> rootfs/usr/sbin/reset_uvc_udc --revert
#   ./tools/apply-file.sh <device-ip> rootfs/usr/sbin/reset_uvc_udc --status
#
# The destination is the path with the leading "rootfs/" stripped. The vendor
# file is copied to <path>.orig once and never overwritten, so repeated applies
# cannot lose the original; --revert puts it back. Mode bits follow the vendor
# file. A patch banner naming "md5 <32 hex>" pins the vendor file it was made
# from: the install refuses when the device's vendor copy hashes differently,
# so a firmware with a changed script gets a new patch instead of a blind
# overwrite. The device root is an overlay on /userdata, so the change survives
# a reboot; a firmware flash restores the vendor file, and provision.sh applies
# the patch again.

set -eu

IP="${1:-}"
SRC="${2:-}"
MODE="${3:-}"

HERE="$(cd "$(dirname "$0")" && pwd)"
KEY="$HERE/../.ssh-glkvm/id_ed25519"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$IP" ] || die "usage: $0 <device-ip> rootfs/<path> [--revert|--status]"
echo "$IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
  || die "'$IP' is not a bare IPv4 address (refusing hostnames - mDNS can hit the wrong unit)"
[ -n "$SRC" ] || die "no source file given"
case "$SRC" in rootfs/*) ;; *) die "source must live under rootfs/";; esac
[ -f "$HERE/../$SRC" ] || die "no such file: $SRC"
[ -f "$KEY" ] || die "device key missing: $KEY"

DEST="/${SRC#rootfs/}"
SSH="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 root@$IP"

case "$MODE" in
  --status)
    $SSH "for f in '$DEST' '$DEST.orig'; do [ -e \"\$f\" ] && md5sum \"\$f\" || echo \"absent \$f\"; done"
    ;;
  --revert)
    $SSH "[ -f '$DEST.orig' ] || { echo 'no $DEST.orig on the device, nothing to revert' >&2; exit 1; }
          cp -p '$DEST.orig' '$DEST' && rm -f '$DEST.orig' && echo 'reverted $DEST from .orig'"
    ;;
  "")
    BASE="$(grep -o -m1 'md5 [0-9a-f]\{32\}' "$HERE/../$SRC" | cut -c5- || true)"
    tr -d '\r' < "$HERE/../$SRC" | $SSH "set -e
          [ -f '$DEST' ] || { echo 'the device has no $DEST; refusing to create a file the vendor did not ship' >&2; exit 1; }
          vendor='$DEST'; [ -f '$DEST.orig' ] && vendor='$DEST.orig'
          have=\$(md5sum < \"\$vendor\" | cut -c1-32)
          if [ -n '$BASE' ] && [ \"\$have\" != '$BASE' ]; then
              echo \"vendor file \$vendor hashes \$have, the patch was made from $BASE; refusing\" >&2
              cat > /dev/null
              exit 1
          fi
          [ -f '$DEST.orig' ] || cp -p '$DEST' '$DEST.orig'
          cat > '$DEST.new'
          chmod --reference='$DEST' '$DEST.new' 2>/dev/null || chmod 755 '$DEST.new'
          interp=\$(head -n 1 '$DEST.new' | sed -n 's/^#!//; s/ .*//p')
          [ -x \"\$interp\" ] || interp=/bin/sh
          \"\$interp\" -n '$DEST.new'
          mv '$DEST.new' '$DEST'
          echo \"installed $DEST (\$(md5sum < '$DEST' | cut -c1-32)), vendor copy at $DEST.orig\""
    ;;
  *)
    die "unknown mode: $MODE"
    ;;
esac
