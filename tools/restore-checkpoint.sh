#!/bin/sh
# restore-checkpoint.sh - roll a Comet KVM back to a captured checkpoint.
#
#   ./tools/restore-checkpoint.sh <device-ip> <site-packages.tgz> [--etc <etc-kvmd.tgz>]
#
# WHY THIS EXISTS: `pip install --upgrade` rewrites site-packages in place with
# no transaction. If an upgrade breaks kvmd, the fastest way back is to drop the
# whole tree in from a known-good tar rather than fight pip.
#
# The device stages the archive under /userdata and only swaps once it has fully
# arrived and been sanity-checked, so a transfer that dies midway leaves the
# running tree untouched.
#
# LAST RESORT beyond this: reflash firmware/glkvm-RM10-1.10.0-custom-signed.img
# (POST /api/upgrade/start?skip_verify=true). That wipes the overlay, including
# /root/.ssh/authorized_keys, so SSH needs re-bootstrapping afterwards.

set -eu

IP="${1:-}"
ARCHIVE="${2:-}"
ETC=""
if [ "${3:-}" = "--etc" ]; then ETC="${4:-}"; fi

HERE="$(cd "$(dirname "$0")" && pwd)"
KEY="$HERE/../.ssh-glkvm/id_ed25519"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$IP" ] && [ -n "$ARCHIVE" ] \
  || die "usage: $0 <device-ip> <site-packages.tgz> [--etc <etc-kvmd.tgz>]"
echo "$IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
  || die "'$IP' is not a bare IPv4 address (refusing hostnames - mDNS can hit the wrong unit)"
[ -f "$ARCHIVE" ] || die "no such checkpoint: $ARCHIVE"
gzip -t "$ARCHIVE" 2>/dev/null || die "checkpoint fails its gzip integrity check: $ARCHIVE"

SSH="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@$IP"
$SSH true 2>/dev/null || die "cannot ssh to $IP"

echo ">> restoring site-packages from $(basename "$ARCHIVE") ($(du -h "$ARCHIVE" | cut -f1))"
$SSH 'rm -rf /userdata/restore && mkdir -p /userdata/restore'
gzip -dc "$ARCHIVE" | $SSH 'tar -xf - -C /userdata/restore'

$SSH '[ -f /userdata/restore/site-packages/kvmd/__init__.pyc ] ||
      [ -f /userdata/restore/site-packages/kvmd/__init__.py ]' \
  || die "staged tree contains no kvmd package - refusing to swap"
echo "   staged and sanity-checked"

$SSH 'D=/usr/lib/python3.12/site-packages
      rm -rf "$D.rollback"
      mv "$D" "$D.rollback"
      mv /userdata/restore/site-packages "$D"
      rmdir /userdata/restore 2>/dev/null || true'
echo "   swapped (previous tree kept at site-packages.rollback)"

if [ -n "$ETC" ]; then
    [ -f "$ETC" ] || die "no such etc archive: $ETC"
    gzip -t "$ETC" 2>/dev/null || die "etc archive fails its gzip integrity check"
    echo ">> restoring /etc/kvmd + /etc/glinet from $(basename "$ETC")"
    gzip -dc "$ETC" | $SSH 'tar -xf - -C /'
fi

echo ">> verifying"
$SSH 'python3 -c "import kvmd; print(\"   kvmd\", kvmd.__version__)"' \
  || die "kvmd will not import after restore"
$SSH 'kvmd --dump-config >/dev/null 2>&1' \
  && echo "   dump-config exit 0" \
  || die "config does not validate after restore"

echo ">> restarting the stack"
$SSH '/etc/init.d/S98kvmd restart >/dev/null 2>&1; sleep 12
      /etc/init.d/S99kvmd-nginx restart >/dev/null 2>&1; sleep 4
      if [ -f /etc/kvmd/user/vnc.enable ]; then
          /etc/kvmd/user/scripts/S99kvmd-vnc restart >/dev/null 2>&1
      fi
      sleep 4; sync'

echo ""
for spec in "443:https://$IP/" "8888:https://$IP:8888/login/"; do
    code=$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' "${spec#*:}" 2>/dev/null || echo 000)
    echo "   ${spec%%:*} -> HTTP $code"
done

echo ""
echo ">> done. Previous tree is at /usr/lib/python3.12/site-packages.rollback"
echo "   Remove it once you are happy:"
echo "     ssh root@$IP 'rm -rf /usr/lib/python3.12/site-packages.rollback'"
