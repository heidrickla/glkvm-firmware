#!/bin/sh
# verify-publish-gates.sh - prove tools/publish-github.sh goes RED on an
# injected violation.
#
#   ./tools/verify-publish-gates.sh
#
# A guard is not verified until it has failed. Each case runs
# publish-github.sh --dry-run (nothing is pushed) against a tampered copy of
# the map or the drop list and asserts the run fails for the stated reason;
# the unmodified map is the positive control and must pass. Every run clones
# the forge, so this needs the same access as a publish and takes a while.
#
# What it cannot prove: a rule that was never written. The proof inside
# publish-github.sh checks the rules it is given, so a missing rule is
# invisible to it. That is what the private-key invariant and a full-history
# sweep before a first publish are for.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PUB="$HERE/publish-github.sh"
MAP="$ROOT/tools/publish/replacements.txt"
DROP="$ROOT/tools/publish/drop-paths.txt"

PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '  \033[33mSKIP\033[0m  %s\n' "$*"; }

[ -f "$PUB" ] || { fail "no $PUB"; exit 1; }
[ -s "$MAP" ] || { fail "no map at $MAP"; exit 1; }

TMPD=$(mktemp -d) || exit 1
trap 'rm -rf "$TMPD"' EXIT INT TERM

# run <label> <want-exit> <want-text> [VAR=value ...]
#
# A dry-run publish under the given environment. Both the exit status AND a
# line of output are asserted, so a run that fails for the WRONG reason does
# not count as the guard firing.
run() {
    _label="$1"; _rc="$2"; _want="$3"; shift 3
    if env "$@" sh "$PUB" --dry-run > "$TMPD/out" 2>&1; then _got=0; else _got=$?; fi
    if [ "$_got" -eq "$_rc" ] && grep -q -F -e "$_want" "$TMPD/out"; then
        pass "$_label (exit $_got, saw \"$_want\")"
    else
        fail "$_label: exit $_got (want $_rc), expected to see \"$_want\""
        sed 's/^/          /' "$TMPD/out" | tail -8
    fi
}

printf '\n\033[1m[1] positive control\033[0m\n'
run "the real map publishes" 0 "no rule survives"

printf '\n\033[1m[2] a rule that changes nothing must be caught\033[0m\n'
# The last literal rule is rewritten to replace itself with itself. The text
# it names then survives the rewrite, and the proof must say so by name.
NOOP=$(grep -v -e '^regex:' -e '^$' "$MAP" | tail -1)
if [ -z "$NOOP" ]; then
    fail "no literal rule in the map to tamper with"
else
    LHS=${NOOP%%==>*}
    { grep -v -F -x -e "$NOOP" "$MAP"; printf '%s==>%s\n' "$LHS" "$LHS"; } > "$TMPD/noop.txt"
    run "a no-op rule for '$LHS' is reported" 1 "still match: $LHS" "PUBLISH_MAP=$TMPD/noop.txt"
fi

printf '\n\033[1m[3] a forgotten drop must be caught\033[0m\n'
if [ -s "$DROP" ] && grep -q -v -e '^#' -e '^$' "$DROP"; then
    : > "$TMPD/empty.txt"
    run "an empty drop list trips the private-key invariant" 1 "private key header" "PUBLISH_DROP=$TMPD/empty.txt"
else
    skip "no drop paths in this repo - the private-key invariant has nothing to catch here"
fi

printf '\n\033[1m[4] a malformed map must be refused\033[0m\n'
{ cat "$MAP"; printf 'this line has no arrow\n'; } > "$TMPD/malformed.txt"
run "a line without ==> is refused before any rewrite" 1 "map line without" "PUBLISH_MAP=$TMPD/malformed.txt"

printf '\n\033[1m[5] a CRLF map must still work\033[0m\n'
sed 's/$/\r/' "$MAP" > "$TMPD/crlf.txt"
run "a CRLF map publishes like the LF one" 0 "no rule survives" "PUBLISH_MAP=$TMPD/crlf.txt"

printf '\n\033[1m=== %d passed, %d failed, %d skipped ===\033[0m\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -eq 0 ]; then
    echo "RESULT: OK - the publish guard fires"
    exit 0
fi
echo "RESULT: FAIL"
exit 1
