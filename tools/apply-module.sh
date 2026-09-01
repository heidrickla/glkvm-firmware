#!/bin/sh
# apply-module.sh - install a patched or newly-ported Python module into a
# Comet KVM's kvmd tree, and be able to take it back out again.
#
#   ./tools/apply-module.sh <device-ip> patches/kvmd/apps/kvmd/info/__init__.py
#   ./tools/apply-module.sh <device-ip> <same path> --revert
#   ./tools/apply-module.sh <device-ip> --list
#
# The destination is the path with the leading "patches/" stripped, rooted at
# /usr/lib/python3.12/site-packages. So the file above lands at
#   /usr/lib/python3.12/site-packages/kvmd/apps/kvmd/info/__init__.pyc
#
# WHY COMPILE RATHER THAN DROP THE .py IN
#
# The device ships kvmd sourceless - .pyc only, no .py anywhere - and .py
# outranks .pyc in importlib's suffix order, so a stray .py silently wins and
# leaves a mixed tree plus __pycache__ litter that no vendor image has. We
# compile on the device (bytecode is arch-independent but 3.12-specific, and
# the device is the only Python 3.12 we are sure of) and install only the .pyc,
# so the tree stays exactly the shape GL.iNet shipped.
#
# EVERY INSTALL IS REVERSIBLE. The original .pyc is copied to .pyc.orig once
# and never overwritten, so repeated applies cannot lose the vendor original.
# For a module the device did not have, a .absent marker is left instead, and
# --revert deletes the file rather than restoring nothing.
#
# This does NOT restart kvmd. Restart when you have applied everything you
# want, so one restart covers the batch:
#   ssh root@<ip> '/etc/init.d/S98kvmd restart'

set -eu

IP="${1:-}"
SRC="${2:-}"
MODE="${3:-}"

HERE="$(cd "$(dirname "$0")" && pwd)"
KEY="$HERE/../.ssh-glkvm/id_ed25519"
SITE="/usr/lib/python3.12/site-packages"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$IP" ] || die "usage: $0 <device-ip> <patches/...py> [--revert] | <device-ip> --list"
echo "$IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
  || die "'$IP' is not a bare IPv4 address (refusing hostnames - mDNS can hit the wrong unit)"

SSH="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@$IP"
$SSH true 2>/dev/null || die "cannot ssh to $IP"

if [ "$SRC" = "--list" ]; then
    echo ">> modules this repo has installed on $IP"
    $SSH "find $SITE -name '*.pyc.orig' -o -name '*.pyc.absent' 2>/dev/null" \
      | sed "s|$SITE/||; s|\.pyc\.orig$|   (patched, vendor original kept)|; s|\.pyc\.absent$|   (ported, not in vendor image)|" \
      | sed 's/^/   /'
    exit 0
fi

[ -n "$SRC" ] || die "usage: $0 <device-ip> <patches/...py> [--revert]"
[ -f "$SRC" ] || die "no such file: $SRC"

# Strip everything up to and including the patches/ component to get the
# in-tree path. Must handle an ABSOLUTE path too: provision.sh passes results
# straight out of `find "$HERE/../patches"`, so SRC looks like
# /d/repo/tools/../patches/kvmd/apps/kvmd/api/export.py. Matching only a
# LEADING "patches/" left REL as the whole absolute path, and the destination
# became $SITE//d/repo/... -- a junk tree of .pyc files inside site-packages
# while the real module went unpatched. Silent, because everything still
# "succeeded".
REL=$(printf '%s' "$SRC" | sed 's|^\./||; s|.*/patches/||; s|^patches/||')
case "$REL" in
    /*|*..*) die "refusing to derive an in-tree path from '$SRC' (got '$REL')" ;;
esac
case "$REL" in
    *.py) ;;
    *) die "expected a .py file, got: $SRC" ;;
esac
DEST_PY="$SITE/$REL"
DEST_PYC="${DEST_PY%.py}.pyc"

if [ "$MODE" = "--revert" ]; then
    echo ">> reverting $REL on $IP"
    $SSH "set -e
        if [ -f '$DEST_PYC.orig' ]; then
            mv '$DEST_PYC.orig' '$DEST_PYC'
            echo '   vendor original restored'
        elif [ -f '$DEST_PYC.absent' ]; then
            rm -f '$DEST_PYC' '$DEST_PYC.absent'
            echo '   ported module removed'
        else
            echo '   nothing to revert - no .orig or .absent marker'; exit 1
        fi"
else
    echo ">> installing $REL on $IP"
    $SSH "mkdir -p /userdata/modport $(dirname "$DEST_PY")"
    # scp would need its own auth plumbing; a pipe reuses the ssh we already proved.
    $SSH "cat > /userdata/modport/staged.py" < "$SRC"

    $SSH "set -e
        python3 - <<'PY'
import py_compile, sys
try:
    py_compile.compile('/userdata/modport/staged.py',
                       cfile='/userdata/modport/staged.pyc', doraise=True)
except py_compile.PyCompileError as ex:
    sys.stderr.write('   will not compile: %s\n' % ex); raise SystemExit(1)
print('   compiled clean')
PY
        # Record what was here BEFORE, exactly once, so a second apply cannot
        # overwrite the vendor original with our own previous attempt.
        if [ ! -f '$DEST_PYC.orig' ] && [ ! -f '$DEST_PYC.absent' ]; then
            if [ -f '$DEST_PYC' ]; then
                cp '$DEST_PYC' '$DEST_PYC.orig'
                echo '   vendor original saved alongside as .pyc.orig'
            else
                : > '$DEST_PYC.absent'
                echo '   new module (was not in the vendor image)'
            fi
        else
            echo '   prior backup kept'
        fi
        mv /userdata/modport/staged.pyc '$DEST_PYC'
        rm -f /userdata/modport/staged.py
        # A stray .py would outrank the .pyc and defeat the point.
        rm -f '$DEST_PY'
        echo '   installed'"
fi

echo ">> verifying the tree still loads"
$SSH "python3 -c 'import kvmd; print(\"   kvmd\", kvmd.__version__)'" \
  || die "kvmd will not import - revert with: $0 $IP $SRC --revert"
$SSH "kvmd --dump-config >/dev/null 2>&1" \
  && echo "   dump-config exit 0" \
  || die "config no longer validates - revert with: $0 $IP $SRC --revert"

echo ""
echo "   not restarted. When you have applied everything:"
echo "     ssh root@$IP '/etc/init.d/S98kvmd restart'"
