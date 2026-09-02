#!/bin/sh
# checkpoint.sh - capture a restorable snapshot of a Comet KVM.
#
#   ./tools/checkpoint.sh <device-ip> <label>
#
# Run this AFTER a milestone lands and is verified - ideally after a reboot has
# proved it sticks. The valuable artefact is the known-good state you want to
# roll back TO, not the state you were in before you started.
#
# Captures into checkpoints/<label>-<ip>-<timestamp>/:
#   site-packages.tgz   the whole Python tree (pip upgrades are not transactional)
#   etc-kvmd.tgz        /etc/kvmd + /etc/glinet
#   pip-freeze.txt      exact package pins
#   services.txt        what was running and listening at capture time
#
# Restore with tools/restore-checkpoint.sh. Last resort beyond that is
# reflashing firmware/glkvm-RM10-1.10.0-custom-signed.img, which wipes the
# overlay including /root/.ssh/authorized_keys.

set -eu

IP="${1:-}"
LABEL="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
KEY="$HERE/../.ssh-glkvm/id_ed25519"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$IP" ] && [ -n "$LABEL" ] || die "usage: $0 <device-ip> <label>"
echo "$IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
  || die "'$IP' is not a bare IPv4 address"
echo "$LABEL" | grep -qE '^[A-Za-z0-9._-]+$' \
  || die "label must match [A-Za-z0-9._-]"

SSH="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@$IP"
$SSH true 2>/dev/null || die "cannot ssh to $IP"

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$HERE/../checkpoints/${LABEL}-${IP}-${STAMP}"
mkdir -p "$OUT"

echo ">> checkpoint '$LABEL' from $IP"

echo "   site-packages ..."
$SSH 'tar -czf - -C /usr/lib/python3.12 site-packages 2>/dev/null' > "$OUT/site-packages.tgz"

echo "   /etc/kvmd + /etc/glinet ..."
$SSH 'tar -czf - -C / etc/kvmd etc/glinet 2>/dev/null' > "$OUT/etc-kvmd.tgz"

echo "   pip freeze ..."
$SSH 'pip freeze --disable-pip-version-check 2>/dev/null' > "$OUT/pip-freeze.txt"

echo "   running services ..."
# First line is the firmware VERSION, on its own, so drift.sh and
# restore-checkpoint.sh can refuse to use this checkpoint against a unit on a
# different firmware. A 1.8.1 site-packages restored onto a 1.10.0 kvmd is
# 1.8.1 bytecode under a 1.10.0 daemon; the check has to be mechanical.
$SSH 'printf "# firmware: %s\n" "$(grep -E "^VERSION=" /etc/os-release | cut -d= -f2 | tr -d "\"")"
      echo "# uptime"; uptime
      echo "# listening"; netstat -ltnu 2>/dev/null | grep LISTEN
      echo "# kvmd"; python3 -c "import kvmd; print(kvmd.__version__)" 2>/dev/null
      echo "# os"; head -3 /etc/os-release 2>/dev/null' > "$OUT/services.txt" 2>/dev/null || true

# A checkpoint you cannot read back is not a checkpoint.
for f in site-packages.tgz etc-kvmd.tgz; do
    gzip -t "$OUT/$f" 2>/dev/null || die "$f failed its gzip integrity check"
done

echo ""
echo ">> $OUT"
for f in "$OUT"/*; do
    printf '   %-20s %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
done
echo ""
echo "   restore: tools/restore-checkpoint.sh $IP \\"
echo "              $OUT/site-packages.tgz --etc $OUT/etc-kvmd.tgz"
