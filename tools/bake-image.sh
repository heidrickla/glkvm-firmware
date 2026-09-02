#!/bin/sh
# bake-image.sh - build a signed GL-RM10 firmware image with this repo's
# provisioning already inside it.
#
#   ./tools/bake-image.sh <build-vm-ip> [--out firmware/<name>.img]
#
# BUILDS ONLY. It never touches a KVM. Flashing is a separate, deliberate step
# that wipes the overlay (including /root/.ssh/authorized_keys) and needs
# `?skip_verify=true` the first time, because the key currently installed on a
# stock unit is GL.iNet's, not ours.
#
# WHAT GOES INTO THE IMAGE (all applied to the vendor 1.10.0 rootfs):
#   * our firmware signing public key   (vendor's kept as public.raw.glinet)
#   * classic PiKVM UI server block on :8888
#   * tools/override.yaml.example as /etc/kvmd/override.yaml  -- NOTE this
#     carries kvmd.auth.enabled: false (see the banner in that file) and
#     kvmd.streamer.forever: true (kvmd's own streamer permanently on)
#   * VNC autostart via /etc/kvmd/user/scripts (the only hook that runs)
#   * every patch under patches/ that MANIFEST scopes to this firmware,
#     compiled to 3.12 bytecode
#   * our SSH public key in /root/.ssh/authorized_keys
#   * /etc/glkvm-bake.txt recording what was baked, from which git revision
#   * the .orig backups deprovision.sh and apply-module.sh --revert expect
#
# Which patches go in is decided by patches/MANIFEST against the image's own
# /etc/os-release on the VM: the two health patches are 1.8.1-only (1.10.0
# registers health itself, proved by disassembling its info/__init__.pyc), the
# export.py fan fix applies everywhere, and the ocr.py contextmanager fix is
# 1.10.x-only. Until this was manifest-driven only export.py was baked, so a
# re-flash would have silently dropped the OCR fix.
#
# HOW THE WORK IS SPLIT: mksquashfs exists on neither Windows nor the KVM, so
# the rootfs is rebuilt on the build VM. rk_pack.py and rk_sign.py are pure
# Python and run here, which avoids shipping the 304 MB vendor image anywhere.
#
# Every stage verifies its effect (sizes, hashes, the partition table of the
# result) rather than trusting an exit code; see the FAIL: lines for why each
# check exists.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

VM="${1:-}"
OUT="$ROOT/firmware/glkvm-RM10-1.10.0-provisioned.img"
[ "${2:-}" = "--out" ] && OUT="${3:?--out needs a path}"

VENDOR="$ROOT/firmware/glkvm-RM10-1.10.0-0715-1784101556.img"
# Product is in the filename on purpose. extracted/rootfs-1.10.0.squashfs was
# the RM1 rootfs (zstd, no LCD assets, byte-identical to the RM1 image's
# partition) and one bake went all the way to mksquashfs on it before anything
# noticed. The preflight below now proves this file IS the rootfs inside the
# RM10 image; the name is just the first line of defence.
SQFS="$ROOT/extracted/rootfs-RM10-1.10.0.squashfs"
VMKEY="$ROOT/.ssh-buildvm/id_ed25519"
PRIV="$ROOT/.signing-key/glkvm-signing.priv"
PUB="$ROOT/.signing-key/glkvm-signing.pub"
SSHPUB="$ROOT/.ssh-glkvm/id_ed25519.pub"
PATCH="$ROOT/patches/kvmd/apps/kvmd/api/export.py"

die() { echo "FAIL: $*" >&2; exit 1; }
ok()  { printf '  ok   %s\n' "$*"; }

[ -n "$VM" ] || die "usage: $0 <build-vm-ip> [--out <path>]"
echo "$VM" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || die "'$VM' is not a bare IPv4 address"

PY=python3; command -v python3 >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || die "no python for rk_pack/rk_sign"

# ---------------------------------------------------------------- preflight
echo "=== preflight ==="
[ -f "$VENDOR" ] || die "vendor image missing: $VENDOR (run firmware/fetch.sh)"
[ -f "$SQFS" ]   || die "vendor rootfs squashfs missing: $SQFS"
[ -f "$PATCH" ]  || die "patch missing: $PATCH"
[ -f "$SSHPUB" ] || die "device ssh public key missing: $SSHPUB"
for k in "$PRIV" "$PUB"; do
    [ -f "$k" ] || die "signing key missing: $k"
    # Raw Ed25519 keys are exactly 32 bytes. Size is the only property checked;
    # the bytes are never read into a variable or printed.
    n=$(wc -c < "$k" | tr -d ' ')
    [ "$n" -eq 32 ] || die "$(basename "$k") is $n bytes, expected a raw 32-byte Ed25519 key"
done
ok "inputs present; both signing keys are raw 32-byte"

# PRODUCT IDENTITY. The squashfs must be the rootfs partition of the RM10
# vendor image, byte for byte. This is the check that was missing when the RM1
# rootfs (zstd, wrong SoC, no LCD) went through every other gate and reached
# mksquashfs. A filename cannot prove which hardware a rootfs is for; a hash
# against the hash-verified vendor image can.
"$PY" - "$VENDOR" "$SQFS" "$HERE" <<'PY' || exit 1
import hashlib, sys
sys.path.insert(0, sys.argv[3])
import rk_pack
m = rk_pack.parse(sys.argv[1])
p = next(x for x in m["parts"] if x["name"] == "rootfs")
inside = bytes(m["rkaf"][p["pos"]:p["pos"] + p["size"]])
ours = open(sys.argv[2], "rb").read()
if hashlib.sha256(inside).digest() != hashlib.sha256(ours).digest():
    sys.stderr.write("FAIL: %s is NOT the rootfs inside %s (%d vs %d bytes) - wrong product?\n"
                     % (sys.argv[2], sys.argv[1], len(ours), len(inside)))
    raise SystemExit(1)
comp = {1: "gzip", 2: "lzma", 3: "lzo", 4: "xz", 5: "lz4", 6: "zstd"}.get(int.from_bytes(ours[20:22], "little"), "?")
print("  ok   squashfs is byte-identical to the RM10 image's rootfs partition (%d bytes, %s)" % (len(ours), comp))
PY

SSH="ssh -i $VMKEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new claude@$VM"
$SSH -n true 2>/dev/null || die "cannot ssh to claude@$VM"
$SSH -n 'command -v mksquashfs >/dev/null && command -v unsquashfs >/dev/null' \
    || die "build VM lacks squashfs-tools"
ok "build VM reachable with squashfs-tools"

# ---------------------------------------------------------------- pristine tree
echo "=== pristine rootfs on the build VM ==="
if $SSH -n 'test -d ~/bake/root/etc/kvmd'; then
    ok "already unpacked at ~/bake/root (reused; it is never modified)"
else
    echo "  uploading $(du -h "$SQFS" | cut -f1) rootfs squashfs and unpacking ..."
    lsha=$(sha256sum "$SQFS" | cut -c1-64)
    rsha=$($SSH 'mkdir -p ~/bake && cat > ~/bake/rootfs-1.10.0.squashfs && sha256sum ~/bake/rootfs-1.10.0.squashfs | cut -c1-64' < "$SQFS")
    [ "$lsha" = "$rsha" ] || die "squashfs upload corrupted (sha256 mismatch)"
    $SSH -n 'cd ~/bake && sudo rm -rf root && sudo unsquashfs -q -d root rootfs-1.10.0.squashfs >/dev/null 2>&1 && sudo test -d root/etc/kvmd' \
        || die "unsquashfs failed on the VM"
    ok "uploaded (sha256 verified) and unpacked"
fi

# ---------------------------------------------------------------- stage inputs
echo "=== staging inputs ==="
STAGE=$(mktemp -d 2>/dev/null) || STAGE="${TMPDIR:-/tmp}/bake.$$"
mkdir -p "$STAGE/in"
trap 'rm -rf "$STAGE"' EXIT INT TERM

# Text inputs go through tr -d '\r'. .gitattributes already forces LF for all
# of them, but a stray CR in S99kvmd-vnc makes busybox report "required file
# not found" on the device, so it is cheap insurance and the remote side
# asserts it anyway.
tr -d '\r' < "$HERE/uncomment-8888.awk"    > "$STAGE/in/uncomment-8888.awk"
tr -d '\r' < "$HERE/override.yaml.example" > "$STAGE/in/override.yaml"
tr -d '\r' < "$HERE/S99kvmd-vnc"           > "$STAGE/in/S99kvmd-vnc"
# Every patch, plus the manifest. The remote side decides which apply to the
# image's own firmware (it has the rootfs, so it has /etc/os-release); this
# side does not guess. Until this change only export.py was baked, so the
# 1.10.0-only ocr.py fix would not have survived a re-flash.
mkdir -p "$STAGE/in/patches"
( cd "$ROOT/patches" && find . -name '*.py' -type f ) | while IFS= read -r rel; do
    mkdir -p "$STAGE/in/patches/$(dirname "$rel")"
    tr -d '\r' < "$ROOT/patches/$rel" > "$STAGE/in/patches/$rel"
done
tr -d '\r' < "$ROOT/patches/MANIFEST"      > "$STAGE/in/patches/MANIFEST"
[ -s "$STAGE/in/patches/kvmd/apps/kvmd/api/export.py" ] || die "export.py did not stage"
tr -d '\r' < "$SSHPUB"                     > "$STAGE/in/authorized_keys"
cp "$PUB" "$STAGE/in/signing.pub"

# Tesseract goes in when the payload exists (tools/ocr.sh install --vm builds
# it). Optional on purpose: an image without OCR is still a valid image, and
# the remote side says plainly which it built.
OCR_NOTE="no-tesseract"
if [ -s "$ROOT/wheels/ocr-payload.tar.gz" ]; then
    cp "$ROOT/wheels/ocr-payload.tar.gz" "$STAGE/in/ocr-payload.tar.gz"
    OCR_NOTE="tesseract-5.3.4(+eng)"
fi

GITREV=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
GITDIRTY=$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
{
    echo "glkvm-firmware bake $(date -u +%Y-%m-%dT%H:%M:%SZ) git=$GITREV dirty-files=$GITDIRTY"
    echo "base: $(basename "$VENDOR") sha256=$(sha256sum "$VENDOR" | cut -c1-16)"
    echo "contents: signing-key classic-ui-8888 override.yaml streamer-forever vnc-autostart patches:MANIFEST ssh-authorized-keys $OCR_NOTE"
    echo "auth: kvmd.auth.enabled=false (deliberate, temporary - see override.yaml banner)"
    echo "streamer: kvmd.streamer.forever=true (default since 2026-09-01)"
    echo "revert: tools/deprovision.sh restores the .orig files shipped alongside"
} > "$STAGE/in/manifest.txt"
cp "$HERE/bake-image.remote.sh" "$STAGE/bake-image.remote.sh"
tr -d '\r' < "$HERE/bake-image.remote.sh" > "$STAGE/bake-image.remote.sh"
ok "7 inputs + remote script staged ($GITREV, $GITDIRTY uncommitted files)"

( cd "$STAGE" && tar -czf - in bake-image.remote.sh ) \
    | $SSH 'rm -rf ~/bake/in ~/bake/bake-image.remote.sh && tar -xzf - -C ~/bake' \
    || die "push to VM failed"
ok "pushed"

# ---------------------------------------------------------------- bake
echo "=== baking on $VM (output shown in full; nothing is suppressed) ==="
LOG="$STAGE/remote.log"
if $SSH -n 'sudo sh ~/bake/bake-image.remote.sh ~/bake' 2>&1 | tee "$LOG"; then :; else
    die "remote bake failed - see the FAIL: line above"
fi
grep -q '^>> baked' "$LOG" || die "remote bake did not reach the end"
RSHA=$(awk '/^>> baked/{getline; gsub(/ /,""); print}' "$LOG")
[ "${#RSHA}" -eq 64 ] || die "could not read the remote sha256 from the log"

# ---------------------------------------------------------------- pull
echo "=== pulling the new rootfs ==="
NEWSQFS="$STAGE/rootfs-provisioned.squashfs"
$SSH -n 'cat ~/bake/rootfs-provisioned.squashfs' > "$NEWSQFS"
LSHA=$(sha256sum "$NEWSQFS" | cut -c1-64)
[ "$LSHA" = "$RSHA" ] || die "pull corrupted: local $LSHA != remote $RSHA"
ok "$(wc -c < "$NEWSQFS" | tr -d ' ') bytes, sha256 matches the VM"

# ---------------------------------------------------------------- pack + sign
echo "=== packing rootfs into the vendor container ==="
"$PY" "$HERE/rk_pack.py" "$VENDOR" "$OUT" rootfs "$NEWSQFS" | sed 's/^/  /'
[ -s "$OUT" ] || die "rk_pack produced nothing"

echo "=== signing ==="
"$PY" "$HERE/rk_sign.py" "$OUT" "$PRIV" | sed 's/^/  /'

# ---------------------------------------------------------------- verify
echo "=== verifying the result ==="
"$PY" - "$VENDOR" "$OUT" "$NEWSQFS" "$HERE" <<'PY'
import hashlib, sys
vendor, out, sqfs, tools = sys.argv[1:5]
sys.path.insert(0, tools)
import rk_pack

v = rk_pack.parse(vendor)
o = rk_pack.parse(out)
new_len = len(open(sqfs, "rb").read())

def part(m, name):
    return next(p for p in m["parts"] if p["name"] == name)

# 1. rootfs entry now describes the new squashfs exactly.
ro = part(o, "rootfs")
assert ro["size"] == new_len, "rootfs size in table %d != squashfs %d" % (ro["size"], new_len)
body = o["rkaf"][ro["pos"]:ro["pos"] + ro["size"]]
assert hashlib.sha256(bytes(body)).hexdigest() == hashlib.sha256(open(sqfs, "rb").read()).hexdigest(), \
    "rootfs bytes inside the image differ from the squashfs that was packed"
print("  ok   rootfs partition: %d bytes, bytes match the packed squashfs" % new_len)

# 2. Every partition BEFORE rootfs is untouched (same offset, same bytes).
rv = part(v, "rootfs")
moved = []
for pv in v["parts"]:
    if pv["pos"] == 0xFFFFFFFF or pv["pos"] >= rv["pos"]:
        continue
    po = part(o, pv["name"])
    same = (po["pos"] == pv["pos"] and po["size"] == pv["size"] and
            o["rkaf"][po["pos"]:po["pos"]+po["size"]] == v["rkaf"][pv["pos"]:pv["pos"]+pv["size"]])
    if not same:
        moved.append(pv["name"])
assert not moved, "partitions before rootfs changed: %s" % moved
print("  ok   %d partitions before rootfs are byte-identical to the vendor image"
      % sum(1 for p in v["parts"] if p["pos"] not in (0xFFFFFFFF,) and p["pos"] < rv["pos"]))

# 3. Signature was actually replaced, and the trailing MD5 covers everything before it.
data = open(out, "rb").read()
sig = data[-96:-32]
assert sig != v["sig"], "signature is still GL.iNet's - rk_sign did not run"
assert sig != b"\0" * 64, "signature is all zeros"
assert data[-32:] == hashlib.md5(data[:-32]).hexdigest().encode(), "trailing MD5 does not cover file[:-32]"
print("  ok   signature replaced (differs from vendor); trailing MD5 valid")

print("  sha256 %s" % hashlib.sha256(data).hexdigest())
print("  size   %d bytes (vendor %d)" % (len(data), len(open(vendor, "rb").read())))
PY

echo
echo "=== built: $OUT ==="
echo "  NOT flashed. To prove the device would accept it WITHOUT flashing, push it"
echo "  and run the device's own gate (read-only):"
echo "    scp -i .ssh-glkvm/id_ed25519 $OUT root@192.0.2.15:/userdata/"
echo "    ssh root@192.0.2.15 'check_image_validity /userdata/$(basename "$OUT")'"
echo "  First flash of a stock unit needs ?skip_verify=true (its installed key is GL.iNet's)."
