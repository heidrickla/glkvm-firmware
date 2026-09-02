#!/bin/sh
# edid.sh - switch the EDID the unit presents to the attached host, from the
# workstation, using GL.iNet's own presets and API.
#
#   ./tools/edid.sh <device-ip> list                 # presets in /etc/kvmd/edid.json
#   ./tools/edid.sh <device-ip> get                  # what is applied now (preset key if it matches)
#   ./tools/edid.sh <device-ip> set <preset-key>     # e.g. E3840x2160, then wait for the new signal
#   ./tools/edid.sh <device-ip> default              # back to the factory preset (E2560x1440)
#
# WHAT HAPPENS ON `set` (measured 2026-09-01 on 1.10.0):
#   POST /api/upgrade/edid writes the hex to /etc/kvmd/user/edid.txt, programs
#   the HDMI bridge (LT6911C-class at i2c 1-002b on the RM10: `lt6911c_upgrade`
#   then a bridge reset) and the host sees a hot-plug. The host then picks a
#   mode from the NEW EDID -- if your desktop is duplicated onto the KVM, your
#   own screen changes mode too. `set` polls the streamer until the source
#   comes back and prints what it negotiated, then leaves it there. Nothing
#   here is persistent beyond the unit's own user file; `default` puts the
#   factory EDID back and waits the same way.
#
# The capture path tops out at 2560x1440 (v4l2 says so), so a 4K EDID is a
# test of the bridge's scaling and of the host's behaviour, not a 4K stream.

set -eu

IP="${1:-}"; CMD="${2:-}"; ARG="${3:-}"
[ -n "$IP" ] && [ -n "$CMD" ] || { echo "usage: $0 <device-ip> list|get|set <key>|default" >&2; exit 1; }
echo "$IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || { echo "'$IP' is not a bare IPv4 address" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
KEY="$HERE/../.ssh-glkvm/id_ed25519"
SSH="ssh -n -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@$IP"
B="https://127.0.0.1:8888/api"

die() { echo "ERROR: $*" >&2; exit 1; }
ok()  { printf '  ok   %s\n' "$*"; }

$SSH true 2>/dev/null || die "cannot ssh to $IP"

py_presets='
import json, sys
d = json.load(open("/etc/kvmd/edid.json"))
for x in d:
    print("%-16s %-28s %s" % (x["key"], x["label"], "(default)" if x.get("is_default") else ""))
'

state() {
    $SSH "curl -sk -m 5 $B/streamer 2>/dev/null" | python3 -c '
import sys, json
try:
    r = json.load(sys.stdin)["result"]
    s = r.get("streamer") or {}
    src = s.get("source") or {}
    print("%s %dx%d fps=%s hdmi=%s" % ("online" if src.get("online") else "offline", src.get("resolution", {}).get("width", 0), src.get("resolution", {}).get("height", 0), src.get("captured_fps"), s.get("hdmi")))
except Exception as ex:
    print("unknown (%s)" % ex)
'
}

wait_signal() {
    # after a bridge reset the host re-plugs; give it up to 60 s to come back
    n=0
    while [ $n -lt 30 ]; do
        sleep 2; n=$((n+1))
        st=$(state)
        case "$st" in online*) echo "  source: $st  (after $((n*2)) s)"; return 0;; esac
    done
    echo "  source still offline after 60 s: $st" >&2
    return 1
}

case "$CMD" in
list)
    $SSH "python3 -c '$py_presets'"
    ;;
get)
    $SSH "python3 - <<'PY'
import json
cur = open('/etc/kvmd/user/edid.txt').read().replace(' ', '').replace('\n', '').replace('\r', '').lower()
for x in json.load(open('/etc/kvmd/edid.json')):
    if x['content'].lower() == cur:
        print('applied: %s  %s' % (x['key'], x['label'])); break
else:
    print('applied: custom EDID (%d hex chars, not a shipped preset)' % len(cur))
PY"
    echo "  source: $(state)"
    ;;
set|default)
    [ "$CMD" = "default" ] && ARG="E2560x1440"
    [ -n "$ARG" ] || die "set needs a preset key (see list)"
    echo ">> before: $(state)"
    $SSH "python3 - '$ARG' <<'PY'
import json, sys, subprocess
key = sys.argv[1]
presets = {x['key']: x for x in json.load(open('/etc/kvmd/edid.json'))}
if key not in presets:
    sys.exit('no such preset: %s' % key)
p = subprocess.run(['curl', '-sk', '-m', '40', '-X', 'POST', '--data-urlencode', 'edid=' + presets[key]['content'], '$B/upgrade/edid'], capture_output=True, text=True)
print('  api:', p.stdout.strip()[:160])
sys.exit(0 if '\"ok\": true' in p.stdout else 1)
PY" || die "the unit refused the EDID (see api line above)"
    ok "$ARG applied to the bridge; waiting for the host to re-plug ..."
    wait_signal || die "no signal after the switch - the host may not accept a mode from this EDID; run: $0 $IP default"
    ;;
*) die "unknown command '$CMD'" ;;
esac
