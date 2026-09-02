#!/bin/sh
# msd.sh - drive the Comet KVM's virtual media (Mass Storage Device).
#
#   ./tools/msd.sh <device-ip> status
#   ./tools/msd.sh <device-ip> list
#   ./tools/msd.sh <device-ip> upload <file> [name]
#   ./tools/msd.sh <device-ip> attach <name> [--disk]   # default: cdrom
#   ./tools/msd.sh <device-ip> detach
#   ./tools/msd.sh <device-ip> remove <name>
#   ./tools/msd.sh <device-ip> mount  <file> [--disk]   # upload + attach, one shot
#   ./tools/msd.sh <device-ip> stick  on|off            # writable USB stick
#
# Presents an ISO to the attached machine as a USB CD-ROM (or a raw disk with
# --disk), so it can boot installers and rescue media with nobody in the room.
#
# Storage is /userdata/media - a 27 GB exfat partition on /dev/mmcblk0p10,
# separate from the overlay, so images survive a config rollback but NOT a
# reflash.
#
# `stick` is the other direction: it hands the WHOLE 27 GB partition to the
# attached machine as a writable USB drive, so you can copy logs or a crash
# dump OFF a box with no network. The gadget has a second, normally idle LUN
# (mass_storage.1/lun.0, ro=0 cdrom=0) for exactly this.
#
# `stick off` also sweeps what the host left on the storage root (Windows'
# "System Volume Information", "$RECYCLE.BIN", desktop.ini, Thumbs.db, macOS'
# .Trashes/.Spotlight-V100/.fseventsd) — kvmd would otherwise list them as
# images to every client — and waits for kvmd's listing to catch up.
#
# ⚠ `stick on` UNMOUNTS /userdata/media on the KVM and exports the raw block
# device. That is correct -- two writers on one filesystem corrupts it -- but it
# means the ISO storage is GONE while the stick is connected: `list` shows no
# images and `upload` has nowhere to go. `stick off` remounts and everything
# returns. The two modes are mutually exclusive in practice.
#
# TRAPS THIS GUARDS AGAINST, all measured on 2026-09-01 against 192.0.2.15:
#
#  * MINIMUM SIZE. The kernel gadget counts 2048-byte sectors in cdrom mode and
#    refuses anything under 300 of them. Measured exactly: 612352 bytes (299)
#    fails, 614400 bytes (300) works. The failure is ugly and misleading --
#    set_connected returns a bare HTTP 500 "Server got itself in trouble", and
#    the only real explanation is "file too small" in dmesg. Checked up front
#    here so you get told the actual reason.
#
#  * ATTACHED MEANS LOCKED. write/remove fail while the image is connected.
#    Every mutating path below detaches first.
#
#  * NAME COLLISIONS. write refuses an existing name with MsdImageExistsError
#    rather than overwriting. `upload` removes the old one deliberately.
#
# Auth is disabled on .15 today. Set KVMD_USER / KVMD_PASSWD and this keeps
# working once it is re-enabled.

set -eu

IP="${1:-}"
CMD="${2:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    sed -n '4,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

[ -n "$IP" ] && [ -n "$CMD" ] || usage
echo "$IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
  || die "'$IP' is not a bare IPv4 address (refusing hostnames - mDNS can hit the wrong unit)"

PY=python3; command -v python3 >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || die "need python for JSON parsing"

API="https://$IP/api/msd"
AUTH=""
if [ -n "${KVMD_USER:-}" ]; then
    AUTH="-H X-KVMD-User:${KVMD_USER} -H X-KVMD-Passwd:${KVMD_PASSWD:-}"
fi

# Every kvmd reply is {"ok":bool,"result":{...}}; a failure carries error_msg.
# Report that rather than a bare status code, which is rarely the real story.
call() {
    _m="$1"; shift
    _out=$(curl -sk --max-time 300 -X "$_m" $AUTH "$@" 2>/dev/null) || die "curl to $IP failed"
    printf '%s' "$_out" | "$PY" -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except ValueError:
    sys.stderr.write("unparseable reply: %s\n" % raw[:200]); raise SystemExit(1)
if not d.get("ok"):
    r = d.get("result") or {}
    sys.stderr.write("  %s: %s\n" % (r.get("error", "error"), r.get("error_msg", raw[:120])))
    raise SystemExit(1)
print(json.dumps(d.get("result") or {}))
'
}

show_status() {
    call GET "$API" | "$PY" -c '
import json, sys
r = json.load(sys.stdin)
d = r.get("drive") or {}
img = d.get("image") or {}
part = (r.get("storage") or {}).get("parts", {}).get("", {})
print("  online    : %s" % r.get("online"))
print("  busy      : %s" % r.get("busy"))
print("  connected : %s" % d.get("connected"))
print("  image     : %s%s" % (img.get("name") or "-",
      "  %.1f MB" % (img["size"] / 1048576.0) if img.get("size") else ""))
print("  mode      : %s" % ("cdrom" if d.get("cdrom") else "disk"))
if part:
    print("  storage   : %.1f GB free of %.1f GB"
          % (part.get("free", 0) / 1e9, part.get("size", 0) / 1e9))
'
}

list_images() {
    call GET "$API" | "$PY" -c '
import json, sys
imgs = (json.load(sys.stdin).get("storage") or {}).get("images") or {}
if not imgs:
    print("  (no images)")
for n, i in sorted(imgs.items()):
    print("  %-40s %9.1f MB  %s" % (n, i.get("size", 0) / 1048576.0,
          "complete" if i.get("complete") else "INCOMPLETE"))
'
}

detach() { call POST "$API/set_connected?connected=0" >/dev/null 2>&1 || true; }

do_upload() {
    src="$1"; name="${2:-$(basename "$src")}"
    [ -f "$src" ] || die "no such file: $src"

    sz=$(wc -c < "$src" | tr -d ' ')
    # 300 sectors x 2048. Catch it here: the device-side failure is a bare 500.
    if [ "$sz" -lt 614400 ]; then
        die "$(basename "$src") is $sz bytes; the USB gadget rejects cdrom images
       under 614400 (300 x 2048-byte sectors) with 'file too small' in dmesg,
       surfacing as an opaque HTTP 500 on attach. Pad it or use a real image."
    fi

    echo ">> uploading $(basename "$src") as '$name' ($((sz / 1048576)) MB)"
    detach
    call POST "$API/remove?image=$name" >/dev/null 2>&1 || true
    # kvmd rescans /userdata/media on a timer rather than on demand, so for a
    # few seconds after a remove the API still lists the image and write fails
    # with MsdImageExistsError. Wait for its view to catch up, not the disk's.
    _n=0
    while [ $_n -lt 20 ]; do
        list_images | grep -qF " $name " || break
        _n=$((_n + 1)); sleep 1
    done
    call POST --data-binary "@$src" -H 'Content-Type: application/octet-stream' \
         "$API/write?image=$name" | "$PY" -c '
import json, sys
i = json.load(sys.stdin).get("image") or {}
if i.get("written") != i.get("size"):
    sys.stderr.write("  short write: %s of %s\n" % (i.get("written"), i.get("size")))
    raise SystemExit(1)
print("   wrote %d bytes" % i.get("size", 0))
'
}

do_attach() {
    name="$1"; mode="${2:-}"
    cd=1; [ "$mode" = "--disk" ] && cd=0
    detach
    call POST "$API/set_params?image=$name&cdrom=$cd" >/dev/null
    call POST "$API/set_connected?connected=1" >/dev/null \
      || die "attach failed - check 'dmesg | grep \"too small\"' on the device"
    echo "   attached '$name' as $([ $cd = 1 ] && echo cdrom || echo disk)"
}

do_stick() {
    # These two are GET, not POST. Posting them returns 405, which reads like a
    # missing route rather than a wrong verb.
    case "${1:-}" in
        on)
            detach            # the cdrom LUN and the partition should not both be live
            call GET "$API/partition_connect" >/dev/null \
              || die "partition_connect failed"
            echo "   /userdata/media unmounted on the KVM and exported as a writable USB drive"
            echo "   ISO storage is unavailable until: $0 $IP stick off"
            ;;
        off)
            call GET "$API/partition_disconnect" >/dev/null \
              || die "partition_disconnect failed"
            # The host had the storage root as a drive. Windows leaves its
            # indexer/recycle folders there, and kvmd then lists them as
            # "images" to every client (seen 2026-09-02: "System Volume
            # Information/IndexerVolumeGuid" in /api/msd). Wait for the
            # remount, then sweep the usual suspects.
            n=0
            until call GET "$API" 2>/dev/null | grep -q '"images"'; do
                sleep 2; n=$((n+1)); [ $n -ge 15 ] && break
            done
            here=$(cd "$(dirname "$0")" && pwd)
            swept=$(ssh -n -i "$here/../.ssh-glkvm/id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes \
                        -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "root@$IP" \
                        'cd /userdata/media 2>/dev/null || exit 0
                         for j in "System Volume Information" "\$RECYCLE.BIN" desktop.ini Thumbs.db .Trashes .Spotlight-V100 .fseventsd; do
                             [ -e "$j" ] || continue
                             rm -rf -- "$j" && printf "%s\n" "$j"
                         done' 2>/dev/null)
            if [ -n "$swept" ]; then
                echo "   swept host litter from the storage root:"
                printf '%s\n' "$swept" | sed 's/^/      /'
                # kvmd rescans the storage every few seconds; do not hand back
                # a `list` that still shows what was just deleted.
                first=$(printf '%s\n' "$swept" | head -1)
                n=0
                while call GET "$API" 2>/dev/null | grep -qF "$first"; do
                    sleep 2; n=$((n+1)); [ $n -ge 15 ] && { echo "   (kvmd's image list has not caught up after 30 s)"; break; }
                done
            fi
            echo "   partition released and remounted; ISO storage is back"
            ;;
        *)  die "usage: stick on|off" ;;
    esac
}

case "$CMD" in
    status) show_status ;;
    list)   list_images ;;
    stick)  do_stick "${3:-}" ;;
    upload) do_upload "${3:?usage: upload <file> [name]}" "${4:-}" ;;
    attach) do_attach "${3:?usage: attach <name> [--disk]}" "${4:-}" ;;
    detach) detach; echo "   detached"; ;;
    remove) detach; call POST "$API/remove?image=${3:?usage: remove <name>}" >/dev/null
            echo "   removed '$3'" ;;
    mount)  src="${3:?usage: mount <file> [--disk]}"
            do_upload "$src"
            do_attach "$(basename "$src")" "${4:-}"
            echo ""; show_status ;;
    *)      usage ;;
esac
