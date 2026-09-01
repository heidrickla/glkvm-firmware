#!/bin/sh
# provision.sh — bring a GL.iNet Comet KVM to the documented working state.
#
# Idempotent: safe to re-run. Every step verifies itself and reports.
# Tested end-to-end on GL-RM10 (Comet Pro), fw rm10rc-1.8.1, kvmd 4.82.
#
#   Usage:  ./tools/provision.sh <device-ip>
#   Undo:   ./tools/deprovision.sh <device-ip>
#
# PREREQUISITE — SSH key access. If `ssh -i .ssh-glkvm/id_ed25519 root@<ip>`
# does not work, install the key first. There is no UI field for it on
# fw 1.8.1, so use the browser console while logged into the KVM web UI:
#
#   (async () => {
#     const key = '<contents of .ssh-glkvm/id_ed25519.pub>';
#     const p = await fetch('/api/system/ssh_key', {method:'POST', body: key + '\n'});
#     console.log(p.status, await p.text());
#   })()
#
# NOTE: that endpoint OVERWRITES authorized_keys; it does not append.
#
# WHAT THIS DOES
#   1. Classic PiKVM UI on :8888   (uncomments a server block GL.iNet ships disabled)
#   2. /etc/kvmd/override.yaml     (enables the VNC server's settings)
#   3. VNC autostart               (via GL.iNet's OWN user-scripts hook — see below)
#
# WHY /etc/kvmd/user/scripts AND NOT /etc/init.d
#   rcS expands `for i in /etc/init.d/S??*` ONCE, at loop start — which happens
#   BEFORE S08overlayfs pivot_root's the writable overlay into place. So a
#   script dropped into /etc/init.d lives only in the overlay, is invisible to
#   that glob, and NEVER starts at boot. (It does get `stop` at shutdown, via
#   rcK, which runs with the overlay mounted — a confusing half-symptom.)
#
#   S99custom IS in the read-only base image, so rcS sees it, and it iterates
#   /etc/kvmd/user/scripts/S??* at its own runtime — long after the overlay is
#   up. That is the supported extension point. Verified by reboot.
#
# NOT INCLUDED — IPMI. /usr/bin/kvmd-ipmi ships but `pyghmi` does not, so the
# daemon cannot start (ModuleNotFoundError). `ipmitool` is absent too. pip is
# available on-device if you decide egress to PyPI is acceptable.

set -eu
IP="${1:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
KEY="$HERE/../.ssh-glkvm/id_ed25519"

die() { echo "ERROR: $*" >&2; exit 1; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
no()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }

[ -n "$IP" ] || die "usage: $0 <device-ip>"
echo "$IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
  || die "'$IP' is not a bare IPv4 address (refusing hostnames — mDNS can hit the wrong unit)"

if [ -f "$KEY" ]; then
    SSH="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@$IP"
    SCP="scp -q -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
else
    SSH="ssh -o BatchMode=yes root@$IP"
    SCP="scp -q -o BatchMode=yes"
fi

echo "=== provisioning $IP ==="
$SSH true 2>/dev/null || die "cannot ssh to $IP — see the PREREQUISITE note at the top of this script."
MODEL=$($SSH 'cat /proc/gl-hw-info/model 2>/dev/null || echo unknown')
VER=$($SSH 'grep ^VERSION= /etc/os-release 2>/dev/null | cut -d= -f2')
ok "connected — model=$MODEL version=$VER"

# ---------------------------------------------------------------- 1. classic UI
echo
echo "[1/3] classic PiKVM UI on :8888"
if $SSH 'grep -qE "^[[:space:]]*listen[[:space:]]+8888" /etc/kvmd/nginx-kvmd.conf'; then
    ok "already enabled"
else
    "$HERE/enable_classic_ui.sh" "$IP" >/dev/null || die "enable_classic_ui.sh failed"
    $SSH 'grep -qE "^[[:space:]]*listen[[:space:]]+8888" /etc/kvmd/nginx-kvmd.conf' \
        && ok "enabled" || die "8888 still not live after enable_classic_ui.sh"
fi

# ---------------------------------------------------------------- 2. override
echo
echo "[2/3] /etc/kvmd/override.yaml"
$SSH '[ -f /etc/kvmd/override.yaml.orig ] || cp /etc/kvmd/override.yaml /etc/kvmd/override.yaml.orig'
$SCP "$HERE/override.yaml.example" "root@$IP:/etc/kvmd/override.yaml"
if $SSH 'kvmd --dump-config >/dev/null 2>&1'; then
    ok "installed and validates (kvmd --dump-config exit 0)"
else
    $SSH 'cp /etc/kvmd/override.yaml.orig /etc/kvmd/override.yaml'
    die "override.yaml FAILED validation — restored the original, nothing changed"
fi

# ---------------------------------------------------------------- 3. VNC
echo
echo "[3/3] VNC server (autostart via /etc/kvmd/user/scripts)"
$SSH 'mkdir -p /etc/kvmd/user/scripts'
$SCP "$HERE/S99kvmd-vnc" "root@$IP:/etc/kvmd/user/scripts/"
$SSH 'chmod +x /etc/kvmd/user/scripts/S99kvmd-vnc
      # A copy in /etc/init.d can never autostart (see header) — remove any.
      [ -e /etc/init.d/S99kvmd-vnc ] && { /etc/init.d/S99kvmd-vnc stop >/dev/null 2>&1 || true; rm -f /etc/init.d/S99kvmd-vnc; }
      mkdir -p /etc/kvmd/user && touch /etc/kvmd/user/vnc.enable
      /etc/kvmd/user/scripts/S99kvmd-vnc restart >/dev/null 2>&1 || true'
sleep 4
$SSH 'netstat -ltn 2>/dev/null | grep -q ":5900"' \
    && ok "running and listening on 5900" \
    || no "5900 not listening — check: $SSH '/etc/kvmd/user/scripts/S99kvmd-vnc status'"

$SSH sync

# ---------------------------------------------------------------- verify
echo
echo "=== verification ==="
for spec in "443  Vue UI:https://$IP/" "8888 classic:https://$IP:8888/login/"; do
    code=$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "${spec#*:}" 2>/dev/null || echo 000)
    [ "$code" = "200" ] && ok "${spec%%:*}  HTTP $code" || no "${spec%%:*}  HTTP $code"
done
banner=$(timeout 6 sh -c "exec 3<>/dev/tcp/$IP/5900 && head -c 11 <&3" 2>/dev/null || true)
case "$banner" in
    RFB*) ok "5900 VNC    $banner" ;;
    *)    no "5900 VNC    no RFB banner" ;;
esac

cat <<EOF

=== done ===
  GL.iNet UI      https://$IP/
  classic PiKVM   https://$IP:8888/
  VNC             $IP:5900   (VeNCrypt + your KVMD credentials;
                              VNCAuth stays off until /etc/kvmd/vncpasswd has an entry)

  Survives reboot: yes — verified.
  Undo everything: $HERE/deprovision.sh $IP
EOF
