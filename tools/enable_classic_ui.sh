#!/bin/sh
# Enable the classic PiKVM web UI on a GL-RM1, alongside GL.iNet's Vue app.
#
# BACKGROUND
#   The RM1 ships BOTH front ends:
#       /usr/share/kvmd/web     classic PiKVM UI — VERIFIED BUILT, not just
#                               sources: 5 .html, 35 .js, 25 .css, 30 .svg
#                               (the .pug files are sources shipped alongside)
#       /usr/share/kvmd/glweb   GL.iNet's Vue app (assets/index-*.js)
#   and both nginx server contexts:
#       /etc/kvmd/nginx/kvmd.ctx-server.conf  -> /usr/share/kvmd/web
#       /etc/kvmd/nginx/gl.ctx-server.conf    -> /usr/share/kvmd/glweb
#
#   nginx runs as: nginx -p /etc/kvmd/nginx -c /etc/kvmd/nginx-kvmd.conf
#   That file serves gl.ctx-server.conf on 443 and carries a COMMENTED-OUT
#   server block that would serve kvmd.ctx-server.conf on 8888. GL.iNet left
#   it in, just disabled. This uncomments it.
#
#   Result: Vue app stays on 443, classic PiKVM UI appears on 8888.
#   Nothing is replaced or removed.
#
#   Verified present and commented out in ALL THREE published firmware
#   versions (1.3.0 / 1.7.0 / 1.10.0, July 2025 - July 2026), so it is very
#   likely present on any build in that range.
#
# Usage:  ./tools/enable_classic_ui.sh <device-ip>            # apply
#         ./tools/enable_classic_ui.sh <device-ip> --revert   # restore backup
#
# Run against .15 first.

set -eu
IP="${1:-}"
MODE="${2:-apply}"
CONF="/etc/kvmd/nginx-kvmd.conf"

[ -n "$IP" ] || { echo "usage: $0 <device-ip> [--revert]" >&2; exit 1; }
echo "$IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
  || { echo "ERROR: '$IP' is not a bare IPv4 address (no hostnames — three units)." >&2; exit 1; }

# Use the dedicated project keypair if it exists, else the default agent/keys.
KEY="$(dirname "$0")/../.ssh-glkvm/id_ed25519"
if [ -f "$KEY" ]; then
    SSH="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes root@${IP}"
else
    SSH="ssh -o BatchMode=yes root@${IP}"
fi

if [ "$MODE" = "--revert" ]; then
    echo ">> reverting $CONF on $IP ..."
    $SSH "[ -f '${CONF}.orig' ]" || { echo "ERROR: no ${CONF}.orig on device." >&2; exit 1; }
    $SSH "cp '${CONF}.orig' '$CONF' && /etc/init.d/S99kvmd-nginx restart"
    echo ">> reverted."
    exit 0
fi

# Uncomment the commented-out server block containing "8888".
#
# Handles BOTH marker styles found in shipped configs:
#   1.10.0 / 1.7.0 :  "#        server {"   -- # at column 1
#   1.3.0          :  "        # server {"   -- # indented
# An earlier version anchored # to column 1 and silently did nothing on a
# 1.3.0-era config. Since the units run an UNIDENTIFIED build, both forms
# must work.
#
# Terminates on BRACE BALANCE of the uncommented text, so an inner
# "location ... {" does not end the block early (an earlier version keyed on
# /^#\s*\}\s*$/ and left the server block unclosed).
#
# Also repairs a GL.iNet typo: 1.3.0 writes "listen [::]:443 ssl;" INSIDE the
# 8888 block. Uncommented verbatim that binds a SECOND server to :443
# alongside the real one. Corrected to 8888, and reported when it fires.
# The program itself lives in uncomment-8888.awk, shared with the firmware
# bake so the two cannot drift. Read it here; missing file is a hard error
# rather than an empty program that silently changes nothing.
AWK_FILE="$(cd "$(dirname "$0")" && pwd)/uncomment-8888.awk"
[ -s "$AWK_FILE" ] || { echo "ERROR: $AWK_FILE missing or empty" >&2; exit 1; }
AWK_PROG=$(cat "$AWK_FILE")

echo ">> target : root@${IP}:${CONF}"
$SSH true 2>/dev/null || { echo "ERROR: cannot ssh to $IP (key auth only)." >&2; exit 1; }

echo ">> backing up $CONF -> ${CONF}.orig (only if absent) ..."
$SSH "[ -f '${CONF}.orig' ] || cp '$CONF' '${CONF}.orig'"

echo ">> uncommenting the 8888 server block ..."
printf '%s\n' "$AWK_PROG" | $SSH \
    "cat > /tmp/glkvm_fix.awk \
     && awk -f /tmp/glkvm_fix.awk '$CONF' > /tmp/glkvm_new \
     && mv /tmp/glkvm_new '$CONF' \
     && rm -f /tmp/glkvm_fix.awk"

echo ">> confirming the block actually went live ..."
if ! $SSH "grep -qE '^[[:space:]]*listen[[:space:]]+8888' '$CONF'"; then
    echo "!! 8888 is still not live — restoring backup, no change made" >&2
    $SSH "cp '${CONF}.orig' '$CONF'"
    exit 1
fi

echo ">> validating nginx config ..."
if ! $SSH "/usr/sbin/nginx -t -p /etc/kvmd/nginx -c '$CONF'"; then
    echo "!! nginx -t failed — restoring backup, no change made" >&2
    $SSH "cp '${CONF}.orig' '$CONF'"
    exit 1
fi

echo ">> restarting nginx ..."
$SSH "/etc/init.d/S99kvmd-nginx restart"

echo
echo ">> done."
echo "   classic PiKVM UI : https://${IP}:8888/"
echo "   GL.iNet Vue app  : https://${IP}/     (unchanged)"
echo "   revert           : $0 $IP --revert"
