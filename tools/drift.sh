#!/bin/sh
# drift.sh - report how a Comet KVM has drifted from a known-good checkpoint.
#
#   ./tools/drift.sh <device-ip> [checkpoint-dir]
#
# With no checkpoint given, uses the newest one in checkpoints/ for that IP.
#
# READ-ONLY. It changes nothing on the device; it only looks and reports.
# Exit status is 0 when clean, 1 when drift was found, so it can gate CI or a
# cron check.
#
# WHY THIS EXISTS
#
# `updateEngine` runs with `--n` (format overlay), so an OTA wipes every change
# we make: the patched kvmd modules, override.yaml, the VNC hook, our SSH key.
# Nothing announces that. The unit keeps working, just as GL.iNet shipped it,
# and the first sign is a feature quietly missing weeks later.
#
# It also catches the smaller version of the same thing: someone re-running
# provisioning against a newer repo, a pip upgrade, or a hand edit on the box.
#
# WHAT IT COMPARES, and why not everything
#
#   1. Patched modules  - the .pyc we installed vs what is on the device now.
#                         This is the one that matters most: it is exactly what
#                         an OTA reverts.
#   2. /etc/kvmd        - every file's hash against the checkpoint's tarball.
#   3. pip freeze       - package set and versions.
#   4. Live state       - the ports and endpoints provisioning is supposed to
#                         leave working.
#
# It deliberately does NOT hash all of site-packages. That is ~67 MB and
# thousands of files; hashing it on a 1 GB RV1126B takes minutes and the useful
# signal is already covered by pip freeze plus the patched-module check.

set -eu

IP="${1:-}"
CP="${2:-}"

HERE="$(cd "$(dirname "$0")" && pwd)"
KEY="$HERE/../.ssh-glkvm/id_ed25519"
SITE="/usr/lib/python3.12/site-packages"

die()  { echo "ERROR: $*" >&2; exit 2; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

DRIFT=0

[ -n "$IP" ] || die "usage: $0 <device-ip> [checkpoint-dir]"
echo "$IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
  || die "'$IP' is not a bare IPv4 address (refusing hostnames - mDNS can hit the wrong unit)"

if [ -z "$CP" ]; then
    # Newest checkpoint for THIS ip. Names are <label>-<ip>-<YYYYmmdd-HHMMSS>,
    # so a lexical sort is chronological.
    CP=$(ls -d "$HERE/../checkpoints/"*-"$IP"-* 2>/dev/null | sort | tail -1 || true)
    [ -n "$CP" ] || die "no checkpoint found for $IP in checkpoints/ - run tools/checkpoint.sh first"
fi
[ -d "$CP" ] || die "not a checkpoint directory: $CP"

# -n matters: ssh reads stdin by default, so calling it inside a `while read`
# loop swallows the remaining lines and the loop silently processes only the
# first item. Nothing here feeds ssh on stdin, so -n is safe throughout.
SSH="ssh -n -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@$IP"
$SSH true 2>/dev/null || die "cannot ssh to $IP"

echo "=== drift: $IP vs $(basename "$CP") ==="

TMPD=$(mktemp -d 2>/dev/null || echo "/tmp/drift.$$")
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT INT TERM

# ------------------------------------------------------------ 1. our patches
echo
echo "[1/4] patched kvmd modules"
if [ -d "$HERE/../patches" ]; then
    PATCH_LIST=$(find "$HERE/../patches" -name '*.py' 2>/dev/null | sort)
    if [ -z "$PATCH_LIST" ]; then
        note "no patches in this repo"
    else
        # Iterate via read, NOT `for p in $PATCH_LIST` with IFS set to newline.
        # That idiom stops unquoted $SSH from word-splitting, so the whole ssh
        # command line becomes a single argument, every call fails, and every
        # module reports "could not determine state" -- a convincing fake OTA
        # revert. read keeps IFS untouched.
        printf '%s\n' "$PATCH_LIST" > "$TMPD/patchlist"
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            rel=$(printf '%s' "$p" | sed 's|.*/patches/||')
            pyc="$SITE/${rel%.py}.pyc"
            # An OTA restores the vendor module AND removes our .orig marker,
            # so the marker's absence is the strongest single drift signal.
            # Keep this on ONE line. Embedded newlines in a remote command
            # arrive as separate statements and the test silently misreports.
            state=$($SSH "if [ ! -f '$pyc' ]; then echo missing; elif [ -f '$pyc.orig' ]; then echo patched; elif [ -f '$pyc.absent' ]; then echo ported; else echo VENDOR; fi" 2>/dev/null || echo unknown)
            case "$state" in
                patched|ported) ok "$rel  ($state)" ;;
                VENDOR)  bad "$rel  - REVERTED to the vendor module (our backup marker is gone)"
                         DRIFT=1 ;;
                missing) bad "$rel  - module file is gone entirely"; DRIFT=1 ;;
                *)       bad "$rel  - could not determine state"; DRIFT=1 ;;
            esac
        done < "$TMPD/patchlist"
    fi
else
    note "no patches/ directory"
fi

# ------------------------------------------------------------ 2. /etc/kvmd
echo
echo "[2/4] /etc/kvmd"
if [ -f "$CP/etc-kvmd.tgz" ]; then
    mkdir -p "$TMPD/cp"
    gzip -dc "$CP/etc-kvmd.tgz" | tar -xf - -C "$TMPD/cp" 2>/dev/null || true
    if [ -d "$TMPD/cp/etc/kvmd" ]; then
        # Normalise BOTH sides to "<hash> /abs/path". Git Bash's md5sum writes
        # "<hash> *path" in binary mode -- one space and an asterisk, not the
        # two spaces GNU coreutils uses on the device. Comparing the two raw
        # marks every single file as both removed and added.
        norm() { sed 's|^\([0-9a-f]\{32\}\)[ \t]*[*]\{0,1\}|\1 |' | sed 's|^\([0-9a-f]\{32\}\) /\{0,1\}|\1 /|'; }
        ( cd "$TMPD/cp" && find etc/kvmd -type f -exec md5sum {} + 2>/dev/null ) \
            | norm | sort -k2 > "$TMPD/want.txt"
        $SSH 'find /etc/kvmd -type f -exec md5sum {} + 2>/dev/null' \
            | norm | sort -k2 > "$TMPD/have.txt"

        awk '{print $2}' "$TMPD/want.txt" | sort > "$TMPD/wantf.txt"
        awk '{print $2}' "$TMPD/have.txt" | sort > "$TMPD/havef.txt"

        GONE=$(comm -23 "$TMPD/wantf.txt" "$TMPD/havef.txt" || true)
        NEW=$(comm -13 "$TMPD/wantf.txt" "$TMPD/havef.txt" || true)
        CHANGED=$(join -j 2 "$TMPD/want.txt" "$TMPD/have.txt" 2>/dev/null \
                  | awk '$2 != $3 {print $1}' || true)

        [ -z "$GONE" ]    || { bad "files removed:";  printf '%s\n' "$GONE"    | sed 's/^/      /'; DRIFT=1; }
        [ -z "$NEW" ]     || { bad "files added:";    printf '%s\n' "$NEW"     | sed 's/^/      /'; DRIFT=1; }
        [ -z "$CHANGED" ] || { bad "files changed:";  printf '%s\n' "$CHANGED" | sed 's/^/      /'; DRIFT=1; }
        [ -n "$GONE$NEW$CHANGED" ] || ok "identical to the checkpoint"
    else
        note "checkpoint has no etc/kvmd tree"
    fi
else
    note "checkpoint has no etc-kvmd.tgz"
fi

# ------------------------------------------------------------ 3. pip freeze
echo
echo "[3/4] python packages"
if [ -f "$CP/pip-freeze.txt" ]; then
    $SSH 'pip freeze --disable-pip-version-check 2>/dev/null' | tr -d '\r' | sort > "$TMPD/pip.now"
    tr -d '\r' < "$CP/pip-freeze.txt" | sort > "$TMPD/pip.was"
    if diff -q "$TMPD/pip.was" "$TMPD/pip.now" >/dev/null 2>&1; then
        ok "$(wc -l < "$TMPD/pip.now" | tr -d ' ') packages, unchanged"
    else
        bad "package set differs:"
        diff "$TMPD/pip.was" "$TMPD/pip.now" | grep -E '^[<>]' | sed 's/^</      removed: /; s/^>/      added:   /' | head -25
        DRIFT=1
    fi
else
    note "checkpoint has no pip-freeze.txt"
fi

# ------------------------------------------------------------ 4. live state
echo
echo "[4/4] live state"
for spec in "443 Vue UI:https://$IP/" "8888 classic:https://$IP:8888/login/" "Prometheus:https://$IP/api/export/prometheus/metrics"; do
    label=${spec%%:*}; url=${spec#*:}
    code=$(curl -sk --max-time 12 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)
    if [ "$code" = "200" ]; then ok "$label  HTTP $code"; else bad "$label  HTTP $code"; DRIFT=1; fi
done
banner=$(timeout 6 sh -c "exec 3<>/dev/tcp/$IP/5900 && head -c 11 <&3" 2>/dev/null || true)
case "$banner" in
    RFB*) ok "5900 VNC  $banner" ;;
    *)    bad "5900 VNC  no RFB banner"; DRIFT=1 ;;
esac

echo
if [ "$DRIFT" -eq 0 ]; then
    echo "=== no drift ==="
else
    echo "=== DRIFT FOUND ==="
    echo "  If an OTA reverted the unit, re-apply with:"
    echo "    $HERE/provision.sh $IP"
    echo "  To roll the whole tree back to this checkpoint instead:"
    echo "    $HERE/restore-checkpoint.sh $IP $CP/site-packages.tgz --etc $CP/etc-kvmd.tgz"
fi
exit "$DRIFT"
