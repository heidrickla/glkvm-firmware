#!/bin/sh
# Enable the classic PiKVM web UI on a GL-RM1, alongside GL.iNet's Vue app.
#
# BACKGROUND
#   The RM1 ships BOTH front ends:
#       /usr/share/kvmd/web     classic PiKVM UI  — VERIFIED BUILT, not just
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

SSH="ssh -o BatchMode=yes root@${IP}"

if [ "$MODE" = "--revert" ]; then
    echo ">> reverting $CONF on $IP ..."
    $SSH "[ -f '${CONF}.orig' ]" || { echo "ERROR: no ${CONF}.orig on device." >&2; exit 1; }
    $SSH "cp '${CONF}.orig' '$CONF' && /etc/init.d/S99kvmd-nginx restart"
    echo ">> reverted."
    exit 0
fi

# Uncomment the commented-out server block containing "8888".
#
# Terminates on BRACE BALANCE of the stripped text, not on the first "#}".
# An earlier version keyed on /^#\s*\}\s*$/ and terminated on the inner
# `location /connect {` closing brace, leaving the server block's own "#  }"
# still commented — producing an unclosed block. Verified against the real
# 1.10.0 nginx-kvmd.conf: braces balance 16/16, and a second run is a no-op.
AWK_PROG='
/^#[[:space:]]*server[[:space:]]*\{/ && !inblk {
    inblk=1; n=0; hit=0; depth=0
    L[n++]=$0
    s=$0; sub(/^#/,"",s)
    depth += gsub(/\{/,"{",s) - gsub(/\}/,"}",s)
    next
}
inblk {
    L[n++]=$0
    if ($0 ~ /8888/) hit=1
    s=$0; sub(/^#/,"",s)
    depth += gsub(/\{/,"{",s) - gsub(/\}/,"}",s)
    if (depth <= 0) {
        for (i=0;i<n;i++) { l=L[i]; if (hit) sub(/^#/,"",l); print l }
        inblk=0
    }
    next
}
{ print }
'

echo ">> backing up $CONF -> ${CONF}.orig (only if absent) ..."
$SSH "[ -f '${CONF}.orig' ] || cp '$CONF' '${CONF}.orig'"

echo ">> uncommenting the 8888 server block ..."
printf '%s\n' "$AWK_PROG" | $SSH \
    "cat > /tmp/glkvm_fix.awk \
     && awk -f /tmp/glkvm_fix.awk '$CONF' > /tmp/glkvm_new \
     && mv /tmp/glkvm_new '$CONF' \
     && rm -f /tmp/glkvm_fix.awk"

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
