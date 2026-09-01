#!/bin/sh
# deprovision.sh — revert everything provision.sh did, on one unit.
#
#   Usage:  ./tools/deprovision.sh <device-ip> [--keep-key]
#
# Restores the nginx config and override.yaml from the .orig backups the
# provisioning took, stops and removes the VNC hook, reverts every patched kvmd
# module back to the vendor .pyc, and (unless --keep-key) removes our SSH key.
# Idempotent: safe to re-run.
#
# It does NOT touch anything else on the device. In particular it leaves MSD
# images, the front panel and the WoL list alone — those are on-demand state,
# not things provisioning created.

set -eu
IP="${1:-}"
KEEP_KEY="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
KEY="$HERE/../.ssh-glkvm/id_ed25519"
PUB="$HERE/../.ssh-glkvm/id_ed25519.pub"

die() { echo "ERROR: $*" >&2; exit 1; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
skip(){ printf '  - %s\n' "$*"; }

[ -n "$IP" ] || die "usage: $0 <device-ip> [--keep-key]"
echo "$IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || die "'$IP' is not a bare IPv4 address"

if [ -f "$KEY" ]; then
    SSH="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@$IP"
else
    SSH="ssh -o BatchMode=yes root@$IP"
fi

echo "=== deprovisioning $IP ==="
$SSH true 2>/dev/null || die "cannot ssh to $IP"

echo
echo "[1/4] VNC"
$SSH '
if [ -e /etc/kvmd/user/scripts/S99kvmd-vnc ]; then
    /etc/kvmd/user/scripts/S99kvmd-vnc stop >/dev/null 2>&1 || true
    rm -f /etc/kvmd/user/scripts/S99kvmd-vnc
    echo "  removed user-scripts hook"
else
    echo "  - no user-scripts hook"
fi
[ -e /etc/init.d/S99kvmd-vnc ] && { /etc/init.d/S99kvmd-vnc stop >/dev/null 2>&1 || true; rm -f /etc/init.d/S99kvmd-vnc; echo "  removed stray /etc/init.d copy"; } || true
rm -f /etc/kvmd/user/vnc.enable
# only remove the dir if WE created it and it is now empty
rmdir /etc/kvmd/user/scripts 2>/dev/null || true
'
$SSH 'netstat -ltn 2>/dev/null | grep -q ":5900"' && echo "  ! 5900 still listening" || ok "5900 closed"

echo
echo "[2/4] override.yaml"
if $SSH '[ -f /etc/kvmd/override.yaml.orig ]'; then
    $SSH 'cp /etc/kvmd/override.yaml.orig /etc/kvmd/override.yaml && rm -f /etc/kvmd/override.yaml.orig'
    $SSH 'kvmd --dump-config >/dev/null 2>&1' && ok "restored, validates" || echo "  ! restored but validation failed"
else
    skip "no .orig backup — leaving as-is"
fi

echo
echo "[3/4] classic UI on 8888"
if $SSH '[ -f /etc/kvmd/nginx-kvmd.conf.orig ]'; then
    "$HERE/enable_classic_ui.sh" "$IP" --revert >/dev/null 2>&1 || true
    $SSH 'grep -qE "^[[:space:]]*listen[[:space:]]+8888" /etc/kvmd/nginx-kvmd.conf' \
        && echo "  ! 8888 still enabled" || ok "reverted"
else
    skip "no .orig backup — leaving as-is"
fi

echo
echo "[4/4] patched kvmd modules"
# apply-module.sh --revert restores the vendor .pyc from the .pyc.orig it saved,
# or deletes the file outright for a module the vendor image never had. A module
# that was never applied has no marker and simply reports nothing to revert, so
# failures here are expected and not fatal.
REVERTED=0
if [ -d "$HERE/../patches" ]; then
    TMPL=$(mktemp 2>/dev/null || echo "/tmp/deprov.$$")
    find "$HERE/../patches" -name '*.py' 2>/dev/null | sort > "$TMPL"
    # read loop, not `for x in $LIST` under a changed IFS; and </dev/null on
    # the call because apply-module.sh runs ssh, which would otherwise eat the
    # rest of this list and leave later modules silently un-reverted.
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        rel=$(printf '%s' "$p" | sed 's|.*/patches/||')
        if "$HERE/apply-module.sh" "$IP" "$p" --revert >/dev/null 2>&1 </dev/null; then
            REVERTED=$((REVERTED + 1)); ok "reverted $rel"
        else
            skip "$rel — not applied"
        fi
    done < "$TMPL"
    rm -f "$TMPL"
else
    skip "no patches/ directory"
fi

if [ "$REVERTED" -gt 0 ]; then
    echo "      restarting kvmd ..."
    $SSH '/etc/init.d/S98kvmd restart >/dev/null 2>&1 || true'
    sleep 15
    $SSH 'python3 -c "import kvmd" 2>/dev/null' \
        && ok "kvmd imports cleanly on the vendor modules" \
        || echo "  ! kvmd will not import — restore from a checkpoint"
fi

if [ "$KEEP_KEY" = "--keep-key" ]; then
    echo
    skip "SSH key kept (--keep-key)"
else
    echo
    echo "[extra] SSH key"
    if [ -f "$PUB" ]; then
        FP=$(awk '{print $2}' "$PUB")
        $SSH "if [ -f /root/.ssh/authorized_keys ]; then
                  grep -vF '$FP' /root/.ssh/authorized_keys > /tmp/ak.new 2>/dev/null || true
                  mv /tmp/ak.new /root/.ssh/authorized_keys
                  chmod 600 /root/.ssh/authorized_keys
                  echo '  removed our key from authorized_keys'
              fi" || true
        echo "  (this was the LAST step — further ssh to $IP will now fail)"
    else
        skip "no local public key to match"
    fi
fi

$SSH sync 2>/dev/null || true
echo
echo "=== done ==="
