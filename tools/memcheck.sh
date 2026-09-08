#!/bin/sh
# memcheck.sh - look for memory growth in the long-running processes on a unit
# while exercising the paths this repo touches.
#
#   ./tools/memcheck.sh <device-ip> [rounds]        (default 3 rounds)
#
# Each round: VNC sessions on the JPEG and the H.264 path (tools/vnc-probe.py,
# connect / a few frames / disconnect), a burst of /api/streamer/snapshot
# GETs (what Home Assistant's camera does), a few OCR region reads, and live
# h264_bitrate flips. RSS of kvmd, its HID workers, kvmd-vnc, ustreamer,
# janus and gl-pion is sampled before the run, after every round, and after
# a settle pause. The verdict compares the last two samples: a process still
# growing after the first round is the signal; growth during the first round
# is usually allocator warm-up.
#
# Read-only apart from the traffic itself; the bitrate is put back at the end.
# Needs a live HDMI signal for the picture paths.

set -eu

IP="${1:-}"; ROUNDS="${2:-3}"
[ -n "$IP" ] || { echo "usage: $0 <device-ip> [rounds]" >&2; exit 1; }
echo "$IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || { echo "'$IP' is not a bare IPv4 address" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
KEY="$HERE/../.ssh-glkvm/id_ed25519"
SSH="ssh -n -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 root@$IP"
PY=$(command -v python3 || command -v python)
[ -n "$PY" ] || { echo "no python" >&2; exit 1; }
B="https://$IP/api"

$SSH true 2>/dev/null || { echo "cannot ssh to $IP" >&2; exit 1; }

TMP=$(mktemp -d 2>/dev/null) || TMP="${TMPDIR:-/tmp}/memcheck.$$"
mkdir -p "$TMP"; trap 'rm -rf "$TMP"' EXIT INT TERM

# one line per tracked process: "<label> <rss_kb>"
sample() {
    $SSH 'for p in /proc/[0-9]*; do
              c=$(tr "\0" " " < $p/cmdline 2>/dev/null | cut -c1-40); [ -n "$c" ] || continue
              rss=$(awk "/VmRSS/{print \$2}" $p/status 2>/dev/null); [ -n "$rss" ] || continue
              case "$c" in
                  "kvmd/main:"*)      l=kvmd-main ;;
                  "kvmd/hid-keyboard"*) l=kvmd-hid-kbd ;;
                  "kvmd/streamer:"*)  l=ustreamer ;;
                  *"kvmd-vnc --run"*) l=kvmd-vnc ;;
                  "/usr/bin/janus"*)  l=janus ;;
                  "/usr/bin/gl-pion"*) l=gl-pion ;;
                  *"kvmd-media --run"*) l=kvmd-media ;;
                  *) continue ;;
              esac
              echo "$l $rss"
          done | sort -k1,1 -k2,2nr | awk "!seen[\$1]++"' 2>/dev/null
}
# (largest RSS per label: the kvmd-vnc label also matches its 2 MB sh wrapper)

memavail() { $SSH 'awk "/MemAvailable/{print int(\$2/1024)}" /proc/meminfo' 2>/dev/null; }

signal=$(curl -sk --max-time 10 "$B/streamer" 2>/dev/null | "$PY" -c 'import sys,json; s=json.load(sys.stdin)["result"]["streamer"]; print("yes" if s.get("hdmi",{}).get("signal") else "no")' 2>/dev/null || echo unknown)
rate0=$(curl -sk --max-time 10 "$B/streamer" 2>/dev/null | "$PY" -c 'import sys,json; print(json.load(sys.stdin)["result"]["params"]["h264_bitrate"])' 2>/dev/null || echo 20000)
echo "=== memcheck $IP: $ROUNDS round(s), HDMI signal: $signal, bitrate now $rate0 kbps ==="

# Warm-up first. kvmd's OCR path grows for its first ~10-15 calls (each
# worker thread's malloc arena takes a decoded frame and tesseract state,
# measured 2026-09-08: 174 -> 202 MB, then flat for 30 more calls). A verdict
# taken inside that ramp reads as a leak; take the baseline after it.
if [ "$signal" = "yes" ]; then
    printf '  warm-up: 15 OCR reads ...'
    k=0; while [ $k -lt 15 ]; do curl -sk --max-time 40 -o /dev/null "$B/streamer/snapshot?ocr=1&ocr_left=0&ocr_top=0&ocr_right=640&ocr_bottom=200" 2>/dev/null || true; k=$((k+1)); done
    echo " done"
fi
sample > "$TMP/s0"; echo "MemAvailable=$(memavail)M" >> "$TMP/s0"
labels=$(awk '!/^MemAvailable=/ {print $1}' "$TMP/s0")

round() {
    printf '  round %s: ' "$1"
    k=0
    while [ $k -lt 8 ]; do
        "$PY" "$HERE/vnc-probe.py" "$IP" 5900 7,-26,-223,0 >/dev/null 2>&1 || true
        "$PY" "$HERE/vnc-probe.py" "$IP" 5900 50,7,-26,-223,0 >/dev/null 2>&1 || true
        k=$((k+1))
    done; printf 'vnc x16 '
    k=0; while [ $k -lt 60 ]; do curl -sk --max-time 10 -o /dev/null "$B/streamer/snapshot" 2>/dev/null || true; k=$((k+1)); done; printf 'snapshot x60 '
    if [ "$signal" = "yes" ]; then
        k=0; while [ $k -lt 4 ]; do curl -sk --max-time 40 -o /dev/null "$B/streamer/snapshot?ocr=1&ocr_left=0&ocr_top=0&ocr_right=640&ocr_bottom=200" 2>/dev/null || true; k=$((k+1)); done; printf 'ocr x4 '
    fi
    for r in 5000 20000 8000 20000; do curl -sk --max-time 10 -o /dev/null -X POST "$B/streamer/set_params?h264_bitrate=$r" 2>/dev/null || true; sleep 1; done; printf 'bitrate x4\n'
}

n=1
while [ $n -le "$ROUNDS" ]; do
    round "$n"
    sample > "$TMP/s$n"; echo "MemAvailable=$(memavail)M" >> "$TMP/s$n"
    n=$((n+1))
done
curl -sk --max-time 10 -o /dev/null -X POST "$B/streamer/set_params?h264_bitrate=$rate0" 2>/dev/null || true
printf '  settling 30 s ...\n'; sleep 30
sample > "$TMP/sf"; echo "MemAvailable=$(memavail)M" >> "$TMP/sf"

echo
printf '  %-14s %9s' "process" "before"
i=1; while [ $i -le "$ROUNDS" ]; do printf ' %9s' "round$i"; i=$((i+1)); done; printf ' %9s   %s\n' "settled" "verdict"
BAD=0
for l in $labels; do
    printf '  %-14s' "$l"
    v0=$(awk -v l="$l" '$1==l{print int($2/1024)}' "$TMP/s0"); printf ' %8sM' "${v0:-?}"
    n=1
    while [ $n -le "$ROUNDS" ]; do
        v=$(awk -v l="$l" '$1==l{print int($2/1024)}' "$TMP/s$n"); printf ' %8sM' "${v:-?}"
        n=$((n+1))
    done
    vf=$(awk -v l="$l" '$1==l{print int($2/1024)}' "$TMP/sf"); printf ' %8sM' "${vf:-?}"
    # verdict: growth from the end of round 1 to the settled sample, in MB
    v1=$(awk -v l="$l" '$1==l{print int($2/1024)}' "$TMP/s1")
    if [ -n "$v1" ] && [ -n "$vf" ]; then
        d=$((vf - v1))
        if [ "$d" -gt 8 ]; then printf '   GROWING +%dM after warm-up\n' "$d"; BAD=$((BAD+1))
        elif [ "$d" -gt 3 ]; then printf '   +%dM (watch)\n' "$d"
        else printf '   flat (%+dM)\n' "$d"; fi
    else printf '   (not seen every time)\n'; fi
done
printf '  %-14s' "MemAvailable"; for f in s0 $(n=1; while [ $n -le "$ROUNDS" ]; do printf 's%d ' $n; n=$((n+1)); done) sf; do printf ' %9s' "$(sed -n 's/^MemAvailable=//p' "$TMP/$f")"; done; echo
echo
if [ "$BAD" -gt 0 ]; then echo "RESULT: $BAD process(es) still growing after warm-up - look at them"; exit 1; fi
echo "RESULT: no process grew more than 8 MB after the first round"
