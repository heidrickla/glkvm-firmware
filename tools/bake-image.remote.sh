#!/bin/sh
# bake-image.remote.sh - apply this repo's provisioning to an extracted GL-RM10
# rootfs and repack it as squashfs. RUNS ON THE BUILD VM, AS ROOT.
#
#   sudo sh bake-image.remote.sh <bake-dir>
#
# Driven by tools/bake-image.sh; not meant to be run by hand. Expects:
#   <bake-dir>/root/    pristine rootfs from `unsquashfs` (never modified)
#   <bake-dir>/in/      inputs staged by the orchestrator:
#                         uncomment-8888.awk  override.yaml  S99kvmd-vnc
#                         export.py  authorized_keys  signing.pub  manifest.txt
# Produces:
#   <bake-dir>/rootfs-provisioned.squashfs
#
# EVERY STEP ASSERTS ITS EFFECT, not its exit code. A `cp` that succeeded into
# the wrong path, an awk that matched nothing, a py_compile that produced 3.10
# bytecode -- each of those exits 0 and ships a broken image. So each step
# reads the tree back and checks the property it was supposed to establish.
#
# WORKS ON A COPY. root/ stays pristine so a bake is reproducible and a botched
# run costs a `cp -a`, not a 140 MB upload and a fresh unsquashfs.
#
# WHY THE .orig FILES ARE BAKED IN TOO: deprovision.sh reverts by restoring
# `<file>.orig`, and apply-module.sh --revert restores `<module>.pyc.orig`. A
# unit flashed from this image should still be walkable back to true vendor
# state with the same tools, so the backups those tools expect are shipped.

set -eu

BAKE="${1:?usage: sudo sh $0 <bake-dir>}"
PRISTINE="$BAKE/root"
IN="$BAKE/in"
WORK="$BAKE/work"
OUT="$BAKE/rootfs-provisioned.squashfs"

# On-flash rootfs partition, from the image's own parameter block:
#   mtdparts ... 0x200000@0x00038000(rootfs)  = 0x200000 sectors x 512 = 1 GiB
# The vendor squashfs is 223,961,088 bytes (213.6 MiB); an earlier note called
# that "224 MB" and it was mistaken for the partition size. Measured, not
# assumed: tools/bake-image.sh's development read the mtdparts string out of
# glkvm-RM10-1.10.0-0715-1784101556.img directly.
ROOTFS_MAX=1073741824
# CPython 3.12 pyc magic, big-endian bytes as they appear in the file header.
PYC_MAGIC_312="cb0d0d0a"

die() { echo "FAIL: $*" >&2; exit 1; }
ok()  { printf '  ok   %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root (file ownership inside the image)"
[ -d "$PRISTINE/etc/kvmd" ] || die "no pristine rootfs at $PRISTINE"
for f in uncomment-8888.awk override.yaml S99kvmd-vnc S24glkvm-config patches/MANIFEST patches/kvmd/apps/kvmd/api/export.py authorized_keys signing.pub manifest.txt; do
    [ -s "$IN/$f" ] || die "missing or empty input: $IN/$f"
done
command -v mksquashfs >/dev/null 2>&1 || die "mksquashfs not installed"
command -v python3    >/dev/null 2>&1 || die "python3 not installed"

echo ">> fresh working copy"
rm -rf "$WORK"
cp -a "$PRISTINE" "$WORK"
ok "copied $(du -sh "$WORK" | cut -f1)"

# PRODUCT IDENTITY, checked from inside the tree. /etc/rm10-gui holds the
# front-LCD assets and exists only on the RM10; the RM1 has no panel. The RM1
# 1.10.0 rootfs passed every other check in this script once -- it has the same
# kvmd, the same nginx block, the same key path -- and only the LCD assets
# distinguish it. The orchestrator hashes the squashfs against the RM10 image;
# this is the independent second check the estate's lessons ask for.
[ -d "$WORK/etc/rm10-gui" ] \
    || die "tree has no /etc/rm10-gui - this is not an RM10 rootfs (RM1's looks identical everywhere else)"
[ -f "$WORK/usr/sbin/gl_kvm_gui" ] \
    || die "tree has no gl_kvm_gui - not an RM10 rootfs"
ok "RM10 rootfs confirmed (LCD assets and gl_kvm_gui present)"

# ---------------------------------------------------------------- 1. signing key
echo ">> 1. firmware signing key"
K="$WORK/etc/firmware/key"
[ -f "$K/public.raw" ] || die "$K/public.raw absent - not an RM10 rootfs?"
[ "$(wc -c < "$IN/signing.pub" | tr -d ' ')" -eq 32 ] || die "signing.pub is not 32 bytes"
[ -f "$K/public.raw.glinet" ] || cp -p "$K/public.raw" "$K/public.raw.glinet"
cp "$IN/signing.pub" "$K/public.raw"
chmod 644 "$K/public.raw"
cmp -s "$K/public.raw" "$IN/signing.pub"        || die "public.raw does not match our key after copy"
! cmp -s "$K/public.raw" "$K/public.raw.glinet"  || die "our key is identical to GL.iNet's - wrong file staged?"
ok "public.raw = ours; vendor kept as public.raw.glinet"

# ---------------------------------------------------------------- 2. classic UI
echo ">> 2. classic PiKVM UI on :8888"
CONF="$WORK/etc/kvmd/nginx-kvmd.conf"
[ -f "$CONF.orig" ] || cp -p "$CONF" "$CONF.orig"
awk -f "$IN/uncomment-8888.awk" "$CONF.orig" > "$CONF.new"
grep -qE '^[[:space:]]*listen[[:space:]]+8888' "$CONF.new" \
    || die "awk produced no live 'listen 8888' line - comment style not recognised?"
# Brace balance of the whole file must be unchanged by uncommenting.
b_orig=$(tr -cd '{}' < "$CONF.orig" | awk '{o=gsub(/\{/,"");c=gsub(/\}/,"");print o-c}')
b_new=$(tr -cd '{}' < "$CONF.new"  | awk '{o=gsub(/\{/,"");c=gsub(/\}/,"");print o-c}')
[ "$b_orig" = "$b_new" ] || die "brace balance changed ($b_orig -> $b_new) - block left unclosed"
mv "$CONF.new" "$CONF"
chmod --reference="$CONF.orig" "$CONF"
ok "8888 server block live; braces balanced; vendor conf kept as .orig"

# ---------------------------------------------------------------- 3. override.yaml
echo ">> 3. /etc/kvmd/override.yaml"
OV="$WORK/etc/kvmd/override.yaml"
[ -f "$OV.orig" ] || cp -p "$OV" "$OV.orig"
cp "$IN/override.yaml" "$OV"
chmod 644 "$OV"
cmp -s "$OV" "$IN/override.yaml" || die "override.yaml differs from staged input"
grep -qE '^[[:space:]]+enabled:[[:space:]]+false' "$OV" \
    || die "override.yaml has no 'enabled: false' - the passwordless posture is missing"
grep -qE '^[[:space:]]+forever:[[:space:]]+true' "$OV" \
    || die "override.yaml has no 'forever: true' - kvmd's streamer would never start (default since 2026-09-01)"
[ "$(grep -c '^kvmd:' "$OV")" = 1 ] \
    || die "override.yaml must have exactly one top-level kvmd: block (a second one silently replaces the first)"
ok "installed; vendor kept as .orig"

# ---------------------------------------------------------------- 4. VNC autostart
echo ">> 4. VNC autostart hook"
US="$WORK/etc/kvmd/user/scripts"
mkdir -p "$US"
cp "$IN/S99kvmd-vnc" "$US/S99kvmd-vnc"
chmod 755 "$US/S99kvmd-vnc"
: > "$WORK/etc/kvmd/user/vnc.enable"
[ -x "$US/S99kvmd-vnc" ] || die "S99kvmd-vnc not executable"
[ -f "$WORK/etc/kvmd/user/vnc.enable" ] || die "vnc.enable not created"
head -c 2 "$US/S99kvmd-vnc" | grep -q '#!' || die "S99kvmd-vnc has no shebang"
! grep -q "$(printf '\r')" "$US/S99kvmd-vnc" || die "S99kvmd-vnc has CRLF line endings - busybox would fail to exec it"
ok "S99kvmd-vnc installed (755, LF); vnc.enable present"

# ---------------------------------------------------------------- 4b. first-boot re-apply
# GL.iNet's S23config copies the OLD unit's override.yaml, /etc/kvmd/user,
# /root/.ssh, shadow and hostname back over the fresh overlay on the first
# boot after a flash (from /userdata/backup_config). Measured 2026-09-08:
# that replaced the baked override.yaml with the vendor's empty one. A rootfs
# init script that sorts after S23 puts ours back from baked copies.
echo ">> 4b. /etc/init.d/S24glkvm-config (re-apply after GL.iNet's restore)"
grep -q "glkvm-firmware: managed by tools/override.yaml.example" "$OV" \
    || die "override.yaml lacks the marker line S24glkvm-config looks for"
cp "$IN/override.yaml" "$WORK/etc/kvmd/override.yaml.glkvm"; chmod 644 "$WORK/etc/kvmd/override.yaml.glkvm"
cp "$IN/authorized_keys" "$WORK/etc/glkvm-authorized_key"; chmod 644 "$WORK/etc/glkvm-authorized_key"
cp "$IN/S99kvmd-vnc" "$WORK/etc/glkvm-S99kvmd-vnc"; chmod 755 "$WORK/etc/glkvm-S99kvmd-vnc"
cp "$IN/S24glkvm-config" "$WORK/etc/init.d/S24glkvm-config"; chmod 755 "$WORK/etc/init.d/S24glkvm-config"
head -c 2 "$WORK/etc/init.d/S24glkvm-config" | grep -q '#!' || die "S24glkvm-config has no shebang"
! grep -q "$(printf '\r')" "$WORK/etc/init.d/S24glkvm-config" || die "S24glkvm-config has CRLF line endings"
[ -f "$WORK/etc/init.d/S23config" ] || die "no S23config in this rootfs - the restore mechanism changed; re-read it before baking"
sh -n "$WORK/etc/init.d/S24glkvm-config" || die "S24glkvm-config does not parse"
ok "S24glkvm-config installed after S23config; baked copies of override.yaml, the SSH key and the VNC hook alongside"

# ---------------------------------------------------------------- 5. patches
echo ">> 5. patched kvmd modules (every patch the manifest says applies to this image)"
IMG_FW=$(sed -n 's/^VERSION=//p' "$WORK/etc/os-release" | tr -d '"' | head -1)
[ -n "$IMG_FW" ] || die "cannot read VERSION from the image's /etc/os-release"
echo "  image firmware: $IMG_FW"
[ -s "$IN/patches/MANIFEST" ] || die "no patches/MANIFEST staged"
applied=0
find "$IN/patches" -name '*.py' -type f | sort > "$BAKE/patchlist"
while IFS= read -r src; do
    rel=${src#"$IN/patches/"}
    glob=$(awk -v r="$rel" '$1 == r { print $2; exit }' "$IN/patches/MANIFEST")
    [ -n "$glob" ] || glob='*'
    # shellcheck disable=SC2254  # the manifest glob is meant to expand as a pattern
    case "$IMG_FW" in
        $glob) ;;
        *) echo "  --   $rel: manifest says $glob, not this image - skipped"; continue ;;
    esac
    PYC="$WORK/usr/lib/python3.12/site-packages/${rel%.py}.pyc"
    [ -f "$PYC" ] || die "$rel: vendor module absent at $PYC"
    python3 - "$src" "$BAKE/patch.pyc.new" <<'PY'
import py_compile, sys
py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)
PY
    magic=$(head -c 4 "$BAKE/patch.pyc.new" | od -An -tx1 | tr -d ' \n')
    [ "$magic" = "$PYC_MAGIC_312" ] \
        || die "$rel: compiled bytecode magic is $magic, not 3.12's $PYC_MAGIC_312 - wrong python on this VM"
    [ -f "$PYC.orig" ] || cp -p "$PYC" "$PYC.orig"
    cp "$BAKE/patch.pyc.new" "$PYC"; chmod 644 "$PYC"; rm -f "$BAKE/patch.pyc.new"
    ! cmp -s "$PYC" "$PYC.orig" || die "$rel: .pyc unchanged after patch"
    case "$rel" in
        kvmd/apps/kvmd/api/export.py)
            # The whole point of that patch: no hard-coded request for 'fan'.
            python3 - "$PYC" <<'PY'
import marshal, sys, types
code = marshal.loads(open(sys.argv[1], "rb").read()[16:])
def walk(c):
    yield c
    for k in c.co_consts:
        if isinstance(k, types.CodeType):
            yield from walk(k)
gp = next(c for c in walk(code) if c.co_name == "__get_prometheus_metrics")
assert "get_subs" in gp.co_names, "patched export.pyc does not call get_subs() - wrong source?"
PY
            ;;
        kvmd/apps/kvmd/ocr.py)
            # The whole point of that patch: _tess_api is a context manager again.
            python3 - "$PYC" <<'PY'
import marshal, sys
code = marshal.loads(open(sys.argv[1], "rb").read()[16:])
assert "contextmanager" in code.co_names, "patched ocr.pyc has no contextmanager - wrong source?"
PY
            ;;
        kvmd/apps/kvmd/api/streamer.py)
            # The whole point of that patch: the OCR answer is text/plain again.
            python3 - "$PYC" <<'PY'
import marshal, sys, types
code = marshal.loads(open(sys.argv[1], "rb").read()[16:])
def walk(c):
    yield c
    for k in c.co_consts:
        if isinstance(k, types.CodeType):
            yield from walk(k)
h = next(c for c in walk(code) if c.co_name == "__take_snapshot_handler")
assert "text/plain" in h.co_consts, "patched api/streamer.pyc does not answer OCR as text/plain - wrong source?"
PY
            ;;
        kvmd/apps/vnc/__init__.py)
            # The whole point of that patch: a JPEG source that polls /snapshot.
            python3 - "$PYC" <<'PY'
import marshal, sys
code = marshal.loads(open(sys.argv[1], "rb").read()[16:])
assert "SnapshotStreamerClient" in code.co_names, "patched vnc/__init__.pyc has no SnapshotStreamerClient - wrong source?"
PY
            ;;
        kvmd/apps/vnc/server.py)
            # The whole point of that patch: streamer params applied once per connection.
            python3 - "$PYC" <<'PY'
import marshal, sys, types
code = marshal.loads(open(sys.argv[1], "rb").read()[16:])
def walk(c):
    yield c
    for k in c.co_consts:
        if isinstance(k, types.CodeType):
            yield from walk(k)
h = next(c for c in walk(code) if c.co_name == "_on_set_encodings")
assert "_Client__streamer_params_applied" in h.co_names, "patched vnc/server.pyc does not gate set_params - wrong source?"
PY
            ;;
        kvmd/plugins/atx/glatx.py)
            # The whole point of that patch: leds.power follows the board's reading.
            python3 - "$PYC" <<'PY'
import marshal, sys, types
code = marshal.loads(open(sys.argv[1], "rb").read()[16:])
def walk(c):
    yield c
    for k in c.co_consts:
        if isinstance(k, types.CodeType):
            yield from walk(k)
g = next(c for c in walk(code) if c.co_name == "get_state")
assert "on" in g.co_consts, "patched glatx.pyc never compares power_state to 'on' - wrong source?"
PY
            ;;
    esac
    ok "$rel installed; vendor kept as .pyc.orig"
    applied=$((applied + 1))
done < "$BAKE/patchlist"
rm -f "$BAKE/patchlist"
[ "$applied" -ge 1 ] || die "no patch applied - export.py at least must apply to every firmware"
ok "$applied patch(es) applied"

# ---------------------------------------------------------------- 5b. tesseract
echo ">> 5b. tesseract OCR runtime"
if [ -s "$IN/ocr-payload.tar.gz" ]; then
    # Same rule as tools/ocr.sh on a live unit: add only sonames the tree lacks,
    # never overwrite a Buildroot library. The on-image manifest lets
    # `ocr.sh remove` take exactly this out again after a flash.
    OCRT="$BAKE/ocr-tmp"; rm -rf "$OCRT"; mkdir -p "$OCRT"
    tar -xzf "$IN/ocr-payload.tar.gz" -C "$OCRT"
    mkdir -p "$WORK/etc/kvmd/user" "$WORK/usr/share/tessdata"
    OM="$WORK/etc/kvmd/user/ocr-installed.txt"; : > "$OM"
    n=0
    for f in "$OCRT"/lib/*; do
        b=$(basename "$f")
        if [ -e "$WORK/usr/lib/$b" ] || [ -e "$WORK/lib/$b" ]; then continue; fi
        cp -a "$f" "$WORK/usr/lib/$b"; chown 0:0 "$WORK/usr/lib/$b" 2>/dev/null || true
        echo "/usr/lib/$b" >> "$OM"; n=$((n + 1))
    done
    for f in "$OCRT"/tessdata/*; do
        b=$(basename "$f")
        cp "$f" "$WORK/usr/share/tessdata/$b"; chmod 644 "$WORK/usr/share/tessdata/$b"
        echo "/usr/share/tessdata/$b" >> "$OM"; n=$((n + 1))
    done
    chmod 644 "$OM"; rm -rf "$OCRT"
    [ -e "$WORK/usr/lib/libtesseract.so.5" ] || die "libtesseract.so.5 not in the tree after staging"
    [ -s "$WORK/usr/share/tessdata/eng.traineddata" ] || die "eng.traineddata not in the tree"
    # Cannot ctypes-load an aarch64 library on this x86 VM; the binary format
    # can still be checked. This is what would catch an amd64 payload.
    arch=$(readelf -h "$WORK/usr/lib/libtesseract.so.5" 2>/dev/null | awk -F': *' '/Machine/{print $2}')
    [ "$arch" = "AArch64" ] || die "libtesseract.so.5 is '$arch', not AArch64"
    ok "$n files staged (aarch64 ELF confirmed); manifest at /etc/kvmd/user/ocr-installed.txt"
else
    ok "no ocr-payload.tar.gz staged - image built without tesseract"
fi

# ---------------------------------------------------------------- 6. ssh key
echo ">> 6. root authorized_keys"
SSHD="$WORK/root/.ssh"
mkdir -p "$SSHD"; chmod 700 "$SSHD"
cp "$IN/authorized_keys" "$SSHD/authorized_keys"; chmod 600 "$SSHD/authorized_keys"
chown -R 0:0 "$WORK/root"
grep -qE '^ssh-ed25519 ' "$SSHD/authorized_keys" || die "authorized_keys has no ssh-ed25519 line"
[ "$(stat -c %a "$SSHD")" = "700" ] || die "root/.ssh mode is $(stat -c %a "$SSHD"), dropbear needs 700"
ok "authorized_keys installed (700/600, root:root)"

# ---------------------------------------------------------------- 7. manifest
echo ">> 7. bake manifest"
cp "$IN/manifest.txt" "$WORK/etc/glkvm-bake.txt"; chmod 644 "$WORK/etc/glkvm-bake.txt"
ok "/etc/glkvm-bake.txt: $(head -1 "$WORK/etc/glkvm-bake.txt")"

# ---------------------------------------------------------------- 8. squashfs
echo ">> 8. mksquashfs (gzip, 128 KiB blocks - the vendor's parameters)"
rm -f "$OUT"
mksquashfs "$WORK" "$OUT" -comp gzip -b 131072 -noappend -quiet -no-progress >/dev/null
[ -s "$OUT" ] || die "mksquashfs produced nothing"
size=$(wc -c < "$OUT" | tr -d ' ')
[ "$size" -lt "$ROOTFS_MAX" ] || die "squashfs is $size bytes, over the 224 MiB rootfs partition"
# unsquashfs -s reads the superblock; a corrupt image fails here, not on flash.
unsquashfs -s "$OUT" >/dev/null 2>&1 || die "unsquashfs cannot read the superblock of $OUT"
# unsquashfs -s prints "Compression gzip" -- a space, no colon. The first
# version of this line split on ':' and read an empty string, failing a good
# image. Anchor the field, not the separator.
comp=$(unsquashfs -s "$OUT" 2>/dev/null | awk '/^Compression/{print $2}')
[ "$comp" = "gzip" ] || die "compression is '$comp', expected gzip (RM10 kernel reads gzip; zstd is RM1)"
ok "$OUT  $size bytes  ($((size / 1048576)) MiB of $((ROOTFS_MAX / 1048576)) MiB partition)  compression=$comp"

echo
echo ">> baked. sha256:"
sha256sum "$OUT" | cut -c1-64 | sed 's/^/   /'
