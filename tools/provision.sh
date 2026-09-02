#!/bin/sh
# provision.sh — bring a GL.iNet Comet KVM to the documented working state.
#
# Idempotent: safe to re-run. Every step verifies itself and reports.
# Tested end-to-end on GL-RM10 (Comet Pro), fw rm10rc-1.8.1, kvmd 4.82.
#
#   Usage:  ./tools/provision.sh <device-ip> [--force]
#   Undo:   ./tools/deprovision.sh <device-ip>
#
#   --force overwrites override.yaml even when the device carries settings the
#   repo copy lacks. Without it, that case aborts rather than silently
#   regressing the unit — see step 2.
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
#   4. Patched kvmd modules        (everything under patches/, via apply-module.sh)
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
# NOT INCLUDED — IPMI. `pyghmi` was later installed and the daemon did run, but
# the RAKP handshake proved unreliable, so IPMI is deliberately left off.
# Redfish supersedes it: 6 power actions over HTTPS instead of 4 over UDP, and
# it needs no extra daemon. See FINDINGS.md.
#
# NOT INCLUDED — the front panel (tools/panel.sh) and virtual media
# (tools/msd.sh). Both are on-demand tools, not boot state: the panel is owned
# by GL.iNet's gl_kvm_gui until you deliberately take it, and MSD holds no
# image by default. Neither belongs in a provisioning run.

set -eu
IP="${1:-}"
FORCE="no"
[ "${2:-}" = "--force" ] && FORCE="yes"
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
echo "[1/5] classic PiKVM UI on :8888"
if $SSH 'grep -qE "^[[:space:]]*listen[[:space:]]+8888" /etc/kvmd/nginx-kvmd.conf'; then
    ok "already enabled"
else
    "$HERE/enable_classic_ui.sh" "$IP" >/dev/null || die "enable_classic_ui.sh failed"
    $SSH 'grep -qE "^[[:space:]]*listen[[:space:]]+8888" /etc/kvmd/nginx-kvmd.conf' \
        && ok "enabled" || die "8888 still not live after enable_classic_ui.sh"
fi

# ---------------------------------------------------------------- 2. override
echo
echo "[2/5] /etc/kvmd/override.yaml"

# DO NOT CLOBBER SILENTLY. This step overwrites the live override.yaml with the
# repo copy. If the device carries settings the repo copy lacks, that is a
# REGRESSION, not a provision — and a silent one. Real example, 2026-09-01:
# `.15` had `kvmd.auth.enabled: false` (deliberate, passwordless while the
# build settles) which override.yaml.example does not carry, so a routine
# re-run would have quietly switched authentication back on.
#
# So: diff the meaningful lines first and refuse unless --force is given.
TMPD=$(mktemp -d 2>/dev/null || echo "/tmp/prov.$$")
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT INT TERM

if $SSH 'cat /etc/kvmd/override.yaml' > "$TMPD/device.yaml" 2>/dev/null; then
    # Comments and blanks differ constantly and mean nothing; compare content.
    strip() { sed 's/#.*$//' "$1" | sed 's/[[:space:]]*$//' | grep -v '^[[:space:]]*$' | sort -u; }
    strip "$TMPD/device.yaml"          > "$TMPD/dev.txt"
    strip "$HERE/override.yaml.example" > "$TMPD/repo.txt"
    LOST=$(comm -23 "$TMPD/dev.txt" "$TMPD/repo.txt" 2>/dev/null || true)
    if [ -n "$LOST" ] && [ "$FORCE" != "yes" ]; then
        no "the device's override.yaml has settings this repo copy does NOT:"
        printf '%s\n' "$LOST" | sed 's/^/        /'
        die "refusing to overwrite and lose them.
       Either fold these into tools/override.yaml.example, or re-run with:
           $0 $IP --force"
    fi
    [ -n "$LOST" ] && no "--force given: overwriting anyway, losing the lines above"
fi

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
echo "[3/5] VNC server (autostart via /etc/kvmd/user/scripts)"
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

# ---------------------------------------------------------------- 4. patches
echo
echo "[4/5] patched kvmd modules"
# Everything under patches/ mirrors the site-packages tree. apply-module.sh
# keeps the vendor .pyc as .pyc.orig the FIRST time only, so re-running this
# whole script cannot lose the original or stack patches on patches.
PATCHED=0
FAILED=0
if [ -d "$HERE/../patches" ]; then
    # `find | while read` would run the loop in a subshell and lose the
    # counters, so drive it from a here-doc-free for over a newline-safe list.
    PATCH_LIST=$(find "$HERE/../patches" -name '*.py' 2>/dev/null | sort)
    if [ -z "$PATCH_LIST" ]; then
        ok "no patches to apply"
    else
        # NEVER discard apply-module.sh's output. Suppressing it is how the
        # absolute-path bug stayed invisible: every module reported "applied"
        # while writing a junk .pyc tree into site-packages and patching
        # nothing. On failure the tool's own diagnosis is the only clue there
        # is, so print it.
        #
        # Iterate with read, not `for p in $PATCH_LIST` under a changed IFS —
        # that idiom breaks unquoted command expansion inside the loop body.
        # Which firmware is this? patches/MANIFEST says which patches apply to
        # which VERSION. After .15 moved from 1.8.1 to 1.10.0, two of the three
        # patches became unnecessary (1.10.0 registers health itself), and
        # applying them anyway would put .orig markers on modules that were
        # never wrong. A patch absent from the manifest applies everywhere.
        DEV_VERSION=$($SSH 'grep -E "^VERSION=" /etc/os-release | cut -d= -f2 | tr -d "\"\r\n"' 2>/dev/null || echo unknown)
        echo "      firmware: $DEV_VERSION"
        printf '%s\n' "$PATCH_LIST" > "$TMPD/patchlist"
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            rel=$(printf '%s' "$p" | sed 's|.*/patches/||')
            glob=$(awk -v r="$rel" '$1 == r { print $2; exit }' "$HERE/../patches/MANIFEST" 2>/dev/null)
            [ -n "$glob" ] || glob='*'
            # shellcheck disable=SC2254  # the glob is meant to expand as a pattern
            case "$DEV_VERSION" in
                $glob) ;;
                *) ok "skipped $rel (manifest: applies to $glob, not this firmware)"; continue ;;
            esac
            # </dev/null is load-bearing: apply-module.sh runs ssh, ssh reads
            # stdin by default, and stdin here IS the patch list. Without it
            # the first module consumes the rest of the loop's input and the
            # run reports success having applied exactly one of them.
            if out=$("$HERE/apply-module.sh" "$IP" "$p" 2>&1 </dev/null); then
                PATCHED=$((PATCHED + 1)); ok "applied $rel"
            else
                FAILED=$((FAILED + 1)); no "FAILED $rel"
                printf '%s\n' "$out" | sed 's/^/          /' | head -12
            fi
        done < "$TMPD/patchlist"
    fi
else
    ok "no patches/ directory"
fi
[ "$FAILED" -eq 0 ] || die "$FAILED module(s) failed to apply — device left running the vendor originals for those"

if [ "$PATCHED" -gt 0 ]; then
    # One restart covers the whole batch AND picks up the override.yaml from
    # step 2, which otherwise would not take effect until a reboot.
    echo "      restarting kvmd to load them ..."
    $SSH '/etc/init.d/S98kvmd restart >/dev/null 2>&1 || true'
    sleep 15
    $SSH 'python3 -c "import kvmd" 2>/dev/null' \
        && ok "kvmd imports cleanly after restart" \
        || no "kvmd will not import — revert with: $HERE/apply-module.sh $IP <patch> --revert"
fi

# ---------------------------------------------------------------- 5. msd gadget
echo
echo "[5/5] mass-storage functions in the USB gadget"
# Firmware 1.10.0 defaults otg.devices.msd.enabled to false, so kvmd-otg
# creates mass_storage.0/.1 at boot but never links them into configs/b.1 and
# /api/msd reports online: false. override.yaml carries the boot-time fix; this
# links them NOW so the unit does not need a reboot to have virtual media.
# kvmd-otgconf unbinds and rebinds the UDC to do it: the attached host sees a
# brief USB re-enumeration, the same as plugging the cable.
if $SSH 'command -v kvmd-otgconf >/dev/null 2>&1'; then
    MISSING=$($SSH 'kvmd-otgconf --list-functions 2>/dev/null | awk "/^- mass_storage/{print \$2}"' | tr '\r\n' '  ')
    if [ -n "$(printf '%s' "$MISSING" | tr -d ' ')" ]; then
        # shellcheck disable=SC2086  # MISSING is a deliberate word list
        $SSH "kvmd-otgconf --enable-function $MISSING >/dev/null 2>&1"
        sleep 3
        STILL=$($SSH 'kvmd-otgconf --list-functions 2>/dev/null | awk "/^- mass_storage/{print \$2}"' | tr -d '\r\n ')
        [ -z "$STILL" ] && ok "enabled:$MISSING" || no "still disabled: $STILL"
    else
        ok "already linked into the gadget"
    fi
else
    ok "no kvmd-otgconf on this firmware (1.8.1 links MSD by default)"
fi

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
