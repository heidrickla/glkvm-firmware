#!/bin/sh
# Hardened replacement for gl-inet/glkvm's apply_to_glkvm.sh.
#
# Why this exists — the upstream script does two dangerous things:
#   1. `ssh ... "rm $REMOTE_DIR/* -R"` BEFORE the scp. A failed transfer
#      (dropped link, full disk, wrong key) leaves the device with no kvmd.
#   2. Targets the hostname `glkvm.local`. With three units on one LAN, mDNS
#      resolves to whichever answers first — i.e. possibly not the guinea pig.
#
# This version: requires an explicit IP, backs up the remote tree and pulls the
# backup local, uploads to a staging dir, and only then swaps. Rolls back on
# failure. Nothing is deleted until the new tree is in place.
#
# Usage:  ./tools/apply_to_glkvm_safe.sh <device-ip> <path-to-kvmd-dir>
# e.g.    ./tools/apply_to_glkvm_safe.sh 192.0.2.15 ./glkvm/kvmd

set -eu

IP="${1:-}"
LOCAL_DIR="${2:-}"
REMOTE_USER="root"
SSH_PORT=22
REMOTE_DIR="/usr/lib/python3.12/site-packages/kvmd"
STAGE_DIR="/tmp/kvmd.stage.$$"
BACKUP_DIR="/tmp/kvmd.backup.$$"
STAMP="$(date +%Y%m%d-%H%M%S)"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$IP" ] || die "no device IP given.  usage: $0 <device-ip> <kvmd-dir>"
[ -n "$LOCAL_DIR" ] || die "no local kvmd dir given."
[ -d "$LOCAL_DIR" ] || die "'$LOCAL_DIR' is not a directory."
# Accept EITHER a source tree (.py, e.g. the published GPLv3 repo) or a
# byte-compiled one (.pyc). The device itself ships SOURCELESS .pyc only —
# discovered 2026-09-01 — so a restore from a device backup has no .py at all.
if [ ! -f "$LOCAL_DIR/__init__.py" ] && [ ! -f "$LOCAL_DIR/__init__.pyc" ]; then
    die "'$LOCAL_DIR' has neither __init__.py nor __init__.pyc — is that really the kvmd package?"
fi

# Refuse anything that is not a bare IPv4 literal. This is the whole point:
# no hostnames, no mDNS, no ambiguity about which of the three units is hit.
echo "$IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
  || die "'$IP' is not a bare IPv4 address. Refusing hostnames (see header)."

# Prefer the dedicated project keypair if present, else default keys/agent.
KEY="$(dirname "$0")/../.ssh-glkvm/id_ed25519"
if [ -f "$KEY" ]; then
    SSH="ssh -i $KEY -o IdentitiesOnly=yes -p $SSH_PORT -o BatchMode=yes ${REMOTE_USER}@${IP}"
    SCP_KEY="-i $KEY -o IdentitiesOnly=yes"
else
    SSH="ssh -p $SSH_PORT -o BatchMode=yes ${REMOTE_USER}@${IP}"
    SCP_KEY=""
fi

echo ">> target      : ${REMOTE_USER}@${IP}:${REMOTE_DIR}"
echo ">> source      : ${LOCAL_DIR}"
echo ">> remote stage: ${STAGE_DIR}"
echo

$SSH true 2>/dev/null || die "cannot ssh to $IP (key auth only; BatchMode is on)."
$SSH "[ -d '$REMOTE_DIR' ]" || die "$REMOTE_DIR does not exist on $IP."

echo ">> [1/5] backing up remote tree to $BACKUP_DIR ..."
$SSH "cp -a '$REMOTE_DIR' '$BACKUP_DIR'" || die "remote backup failed; nothing changed."

echo ">> [2/5] pulling backup to ./backups/kvmd-${IP}-${STAMP}.tar.gz ..."
mkdir -p backups
$SSH "tar -czf - -C '$(dirname "$BACKUP_DIR")' '$(basename "$BACKUP_DIR")'" \
  > "backups/kvmd-${IP}-${STAMP}.tar.gz" \
  || die "could not pull backup locally; refusing to continue."

echo ">> [3/5] uploading to staging dir ..."
$SSH "rm -rf '$STAGE_DIR' && mkdir -p '$STAGE_DIR'"
if ! scp -q $SCP_KEY -P "$SSH_PORT" -r "$LOCAL_DIR"/* "${REMOTE_USER}@${IP}:${STAGE_DIR}/"; then
    $SSH "rm -rf '$STAGE_DIR'" || true
    die "upload failed. Device untouched — $REMOTE_DIR is still intact."
fi

$SSH "[ -f '$STAGE_DIR/__init__.py' ] || [ -f '$STAGE_DIR/__init__.pyc' ]" \
  || { $SSH "rm -rf '$STAGE_DIR'"; die "staged tree looks wrong (no __init__.py or .pyc). Aborted."; }

echo ">> [4/5] swapping into place ..."
if ! $SSH "rm -rf '${REMOTE_DIR}.old' \
        && mv '$REMOTE_DIR' '${REMOTE_DIR}.old' \
        && mv '$STAGE_DIR' '$REMOTE_DIR'"; then
    echo "!! swap failed — rolling back ..." >&2
    $SSH "[ -d '${REMOTE_DIR}.old' ] && [ ! -d '$REMOTE_DIR' ] && mv '${REMOTE_DIR}.old' '$REMOTE_DIR'" || true
    die "swap failed. Check the device before rebooting it."
fi

echo ">> [5/5] done."
echo
echo "   previous tree : ${REMOTE_DIR}.old   (on device)"
echo "   backup copy   : ${BACKUP_DIR}        (on device)"
echo "   local archive : backups/kvmd-${IP}-${STAMP}.tar.gz"
echo
echo "   Reboot $IP for changes to take effect."
echo "   To roll back before rebooting:"
echo "     ssh root@$IP \"rm -rf '$REMOTE_DIR' && mv '${REMOTE_DIR}.old' '$REMOTE_DIR'\""
