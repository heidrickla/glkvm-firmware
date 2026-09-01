#!/bin/sh
# verify-gates.sh - prove selftest.sh's checks can actually fail.
#
#   ./tools/verify-gates.sh
#
# Exit 0 only if EVERY injected violation makes selftest fail, AND an
# unmodified copy still passes.
#
# WHY
#
# A gate that cannot fail is decoration, and every check that has failed in this
# estate failed silently: it could not fail, or it checked something weaker than
# its name, or it skipped and returned success, or it enumerated nothing and
# called that agreement. Watching selftest print PASS proves none of that.
#
# So this breaks each thing selftest claims to check, one at a time, and asserts
# selftest goes red. The clean-copy run at the end is the positive control: a
# suite that fails on everything is as useless as one that fails on nothing.
#
# Work happens on a COPY under a scratch directory. The real repo is never
# modified — an earlier version of this idea that patched files in place and
# restored them afterwards is one interrupted run away from leaving the repo
# broken.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

WORK=$(mktemp -d 2>/dev/null) || WORK="${TMPDIR:-/tmp}/verify-gates.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT INT TERM

FIRED=0
MISSED=0

reset_copy() {
    rm -rf "$WORK/tools" "$WORK/patches"
    cp -r "$ROOT/tools" "$WORK/tools"
    [ -d "$ROOT/patches" ] && cp -r "$ROOT/patches" "$WORK/patches"
}

# expect_fail <description> ... command that breaks something ...
#
# The harness needs its own floor. A malformed sed leaves the copy untouched,
# selftest passes because nothing was broken, and that is indistinguishable
# from a gate that does not work — it already happened once here. So checksum
# the tree before and after and refuse to interpret a run where the injection
# changed nothing.
expect_fail() {
    _desc="$1"; shift
    reset_copy
    _before=$(find "$WORK/tools" "$WORK/patches" -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum)
    "$@" >/dev/null 2>&1 || true
    _after=$(find "$WORK/tools" "$WORK/patches" -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum)

    if [ "$_before" = "$_after" ]; then
        MISSED=$((MISSED + 1))
        printf '  \033[31mINJECTION DID NOTHING\033[0m  %s\n' "$_desc"
        printf '        the test is broken, not necessarily the gate\n'
        return
    fi

    if ( cd "$WORK" && ./tools/selftest.sh ) >"$WORK/out" 2>&1; then
        MISSED=$((MISSED + 1))
        printf '  \033[31mGATE DID NOT FIRE\033[0m  %s\n' "$_desc"
    else
        FIRED=$((FIRED + 1))
        printf '  \033[32mfired\033[0m  %s\n' "$_desc"
    fi
}

echo "=== injecting violations; each must make selftest fail ==="

# Enumeration floors. Without them a rename or a moved directory turns every
# loop into zero iterations, and zero assertions all pass.
expect_fail "floor: tool scripts disappear" \
    rm -f "$WORK/tools/msd.sh" "$WORK/tools/panel.sh" "$WORK/tools/drift.sh" "$WORK/tools/checkpoint.sh"
expect_fail "floor: patches/ is empty" \
    rm -rf "$WORK/patches"

# The three bugs that shipped silently, each now guarded.
# @ as the sed delimiter: the text being removed is itself full of | characters.
expect_fail "apply-module.sh stops stripping absolute paths" \
    sed -i 's@; s|\.\*/patches/||@@' "$WORK/tools/apply-module.sh"
expect_fail "drift.sh loses 'ssh -n' and eats its own loop input" \
    sed -i 's/ssh -n -i/ssh -i/' "$WORK/tools/drift.sh"
expect_fail "provision.sh goes back to discarding apply-module.sh output" \
    sed -i 's|if out=$("$HERE/apply-module.sh" "$IP" "$p" 2>&1 </dev/null); then|if "$HERE/apply-module.sh" "$IP" "$p" >/dev/null 2>\&1; then|' \
        "$WORK/tools/provision.sh"

# The override.yaml.example security assertion.
expect_fail "override.yaml.example stops stating kvmd.auth.enabled" \
    sed -i '/^    auth:$/,+2d' "$WORK/tools/override.yaml.example"

echo
echo "=== positive control: an unmodified copy must still pass ==="
reset_copy
if ( cd "$WORK" && ./tools/selftest.sh ) >"$WORK/out" 2>&1; then
    echo "  clean copy passes - the suite is not simply failing on everything"
    CONTROL=0
else
    echo "  PROBLEM: clean copy FAILS. The suite is red regardless of input, so"
    echo "  none of the results above mean anything."
    sed 's/^/      /' "$WORK/out" | grep -E 'FAIL' | head -8 || true
    CONTROL=1
fi

echo
echo "=== $FIRED fired, $MISSED did not ==="
if [ "$MISSED" -gt 0 ] || [ "$CONTROL" -ne 0 ]; then
    echo "RESULT: FAILED"
    exit 1
fi
echo "RESULT: OK - every gate above has been watched failing"
exit 0
