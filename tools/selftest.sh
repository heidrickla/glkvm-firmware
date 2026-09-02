#!/bin/sh
# selftest.sh - validate this repo's tooling. Runs in CI and locally.
#
#   ./tools/selftest.sh                     # offline checks only
#   ./tools/selftest.sh --with-device <ip>  # adds live read-only checks
#
# EXIT 0 only when every check PASSED or was explicitly, loudly SKIPPED for a
# reason printed in the output. Any FAIL exits 1.
#
# WHY THIS EXISTS, and why it is noisy on purpose
#
# The bugs that actually cost time in this repo were all SILENT:
#
#   * provision.sh called apply-module.sh with `>/dev/null 2>&1`, so when it
#     passed an absolute path that the destination logic could not strip, every
#     module "succeeded" while writing a junk .pyc tree into site-packages and
#     patching nothing. Green output, zero effect.
#   * drift.sh iterated with `for x in $LIST` under `IFS=$'\n'`, which stops an
#     unquoted $SSH from word-splitting. Every remote probe failed identically,
#     which the script cheerfully rendered as "could not determine state" for
#     all three modules -- indistinguishable from a real OTA revert.
#   * ssh inside a `while read` loop ate the loop's stdin, so only the first
#     item was ever checked and the run still reported success.
#
# The common thread is not a logic error, it is suppressed output plus a
# success-shaped result. So: this script never hides a command's stderr, and a
# check that cannot run says SKIP loudly rather than quietly counting as a pass.
# A silent green is treated as a bug in the test, not a property of the code.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

DEVICE=""
CI=0
while [ $# -gt 0 ]; do
    case "$1" in
        --with-device) DEVICE="${2:-}"; shift 2 ;;
        --ci)          CI=1; shift ;;
        *)             shift ;;
    esac
done

PASS=0; FAIL=0; SKIP=0

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }

# skip <message> [structural]
#
# A skipped check is an UNVERIFIED check. Under --ci that is a failure, because
# a pipeline can install whatever the check needs — letting it skip turns the
# build green while proving nothing, which is the exact failure mode this
# script exists to prevent.
#
# Pass "structural" for the two skips CI genuinely cannot resolve: build
# artifacts are gitignored, and there is no KVM on a GitHub runner. Those stay
# skips even under --ci, and are still printed.
skip() {
    _msg="$1"; _kind="${2:-}"
    if [ "$CI" = "1" ] && [ "$_kind" != "structural" ]; then
        FAIL=$((FAIL + 1))
        printf '  \033[31mFAIL\033[0m  (skip not allowed under --ci) %s\n' "$_msg"
    else
        SKIP=$((SKIP + 1)); printf '  \033[33mSKIP\033[0m  %s\n' "$_msg"
    fi
}
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Private scratch. NOT a fixed /tmp path: those are shared between sessions, so
# two runs stamp on each other and the loser silently reads the winner's data.
TMPD=$(mktemp -d 2>/dev/null) || TMPD="${TMPDIR:-/tmp}/selftest.$$"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT INT TERM

# floor <label> <count> <minimum>
#
# An enumerating check that finds nothing passes vacuously: `for f in *.sh`
# after a rename or a moved directory iterates zero times and every assertion
# inside it is trivially satisfied. 0 == 0 counts as agreement. So every
# enumeration states how many items it MUST have found.
floor() {
    _label="$1"; _count="$2"; _min="$3"
    if [ "$_count" -lt "$_min" ]; then
        fail "$_label: found $_count, expected at least $_min - the enumeration is broken, not the code"
    else
        pass "$_label: enumerated $_count"
    fi
}

# Run a command; on failure print its OUTPUT, never swallow it.
try() {
    _desc="$1"; shift
    if _out=$("$@" 2>&1); then
        pass "$_desc"
    else
        fail "$_desc"
        printf '%s\n' "$_out" | sed 's/^/          /' | head -15
    fi
}

# ---------------------------------------------------------------- shell syntax
head_ "[1] shell scripts parse"
NSH=0
for f in "$HERE"/*.sh; do
    [ -f "$f" ] || continue
    NSH=$((NSH + 1))
    try "sh -n $(basename "$f")" sh -n "$f"
done
floor "shell scripts" "$NSH" 8

# ---------------------------------------------------------------- shellcheck
head_ "[2] shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
    NSC=0
    for f in "$HERE"/*.sh; do
        [ -f "$f" ] || continue
        NSC=$((NSC + 1))
        # SC2029 (client-side expansion in ssh) is intentional throughout:
        # we build remote commands from local variables deliberately.
        try "shellcheck $(basename "$f")" shellcheck -S warning -e SC2029 "$f"
    done
    floor "shellcheck targets" "$NSC" 8
else
    skip "shellcheck not installed - shell bugs like unquoted \$SSH under a changed IFS will NOT be caught here"
fi

# ---------------------------------------------------------------- python
head_ "[3] python sources compile"
PY=python3; command -v python3 >/dev/null 2>&1 || PY=python
if command -v "$PY" >/dev/null 2>&1; then
    NPY=0
    for f in "$HERE"/*.py; do
        [ -f "$f" ] || continue
        NPY=$((NPY + 1))
        try "compile $(basename "$f")" "$PY" -m py_compile "$f"
    done
    floor "python tools" "$NPY" 4
    if [ -d "$ROOT/patches" ]; then
        NPATCH=0
        find "$ROOT/patches" -name '*.py' > "$TMPD/patches" 2>/dev/null || true
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            NPATCH=$((NPATCH + 1))
            try "compile patches/$(printf '%s' "$p" | sed 's|.*/patches/||')" "$PY" -m py_compile "$p"
        done < "$TMPD/patches"
        # If patches/ exists at all it must hold every module we ship:
        # export, info/__init__, info/health, ocr, api/streamer, vnc/__init__,
        # vnc/server.
        floor "patched modules" "$NPATCH" 7
    else
        fail "patches/ is missing - provision.sh would apply nothing and still report success"
    fi
else
    fail "no python interpreter - cannot validate any of the Python tooling"
fi

# ---------------------------------------------------------------- config
head_ "[4] override.yaml.example"
if command -v "$PY" >/dev/null 2>&1; then
    if "$PY" -c "import yaml" >/dev/null 2>&1; then
        _out=$("$PY" - "$ROOT/tools/override.yaml.example" <<'PY' 2>&1
import sys, yaml

# PyYAML keeps the LAST duplicate mapping key and says nothing. A second
# top-level `kvmd:` block appended to override.yaml therefore REPLACED the
# first -- auth.enabled: false, the MSD fixes and the GPIO scheme vanished,
# auth came on, and every /streamer call returned 401 in a way that looked
# exactly like a firmware change. Refuse duplicates at any depth.
class Strict(yaml.SafeLoader):
    pass

def no_dupes(loader, node, deep=False):
    seen = set()
    for k_node, _ in node.value:
        k = loader.construct_object(k_node, deep=deep)
        if k in seen:
            raise ValueError("duplicate key %r at line %d - the later one silently wins in kvmd" % (k, k_node.start_mark.line + 1))
        seen.add(k)
    return yaml.SafeLoader.construct_mapping(loader, node, deep)

Strict.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_dupes)
d = yaml.load(open(sys.argv[1], encoding="utf-8"), Loader=Strict)
assert isinstance(d, dict), "not a mapping"
missing = [k for k in ("kvmd", "vnc") if k not in d]
assert not missing, "missing top-level keys: %s" % missing
# auth.enabled is deliberately false today; assert it is EXPLICIT either way so
# nobody flips the security posture of every provisioned unit by accident.
auth = (d.get("kvmd") or {}).get("auth", {})
assert "enabled" in auth, "kvmd.auth.enabled is not stated explicitly"
# kvmd's own streamer never starts on vendor firmware (GL.iNet's manager only
# raises it on demand), so without this line the classic UI has no picture,
# /api/streamer/snapshot is 503 and kvmd's OCR endpoint has nothing to read.
# Default since 2026-09-01 (Lewis). It must live INSIDE the one kvmd: block.
streamer = (d.get("kvmd") or {}).get("streamer", {})
assert streamer.get("forever") is True, "kvmd.streamer.forever is not true"
print("auth.enabled=%s streamer.forever=%s" % (auth["enabled"], streamer["forever"]))
PY
        ) && _rc=0 || _rc=$?
        if [ "$_rc" -eq 0 ]; then pass "valid YAML, required keys present ($_out)"
        else fail "override.yaml.example invalid"; printf '%s\n' "$_out" | sed 's/^/          /'; fi
    else
        skip "pyyaml not installed - override.yaml.example NOT validated"
    fi
fi

# ---------------------------------------------------------------- regressions
head_ "[5] regression tests for bugs that shipped silently"

# apply-module.sh must map BOTH a relative and an absolute patch path to the
# same in-tree destination. When it did not, provisioning wrote a junk tree
# into site-packages and reported success for every module.
derive() {
    printf '%s' "$1" | sed 's|^\./||; s|.*/patches/||; s|^patches/||'
}
EXPECT="kvmd/apps/kvmd/api/export.py"
NDERIVE=0
for input in \
    "patches/kvmd/apps/kvmd/api/export.py" \
    "./patches/kvmd/apps/kvmd/api/export.py" \
    "/d/PersonalProjects/glkvm-firmware/patches/kvmd/apps/kvmd/api/export.py" \
    "/d/repo/tools/../patches/kvmd/apps/kvmd/api/export.py"
do
    NDERIVE=$((NDERIVE + 1))
    got=$(derive "$input")
    if [ "$got" = "$EXPECT" ]; then
        pass "path derivation: $(printf '%s' "$input" | tail -c 46)"
    else
        fail "path derivation gave '$got' (want '$EXPECT') for '$input'"
    fi
done
floor "path-derivation cases" "$NDERIVE" 4

# The real script must agree with the model above.
if grep -q 's|.\*/patches/||' "$HERE/apply-module.sh" 2>/dev/null; then
    pass "apply-module.sh strips any leading path before patches/"
else
    fail "apply-module.sh no longer strips absolute paths - the junk-tree bug can recur"
fi

# The executable bit must be recorded IN GIT, not just on this filesystem.
#
# This repo is authored on Windows, where chmod +x does not reach git's index.
# Every tools/*.sh was committed 100644, so on a Linux CI runner the very first
# command -- ./tools/selftest.sh -- was "Permission denied". Six CI runs failed
# that way, each producing no output at all, which looked like a broken runner
# and was entirely this repo's doing.
#
# Fix is `git update-index --chmod=+x <file>`. Checked here so it cannot recur.
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    NOEXEC=$(git -C "$ROOT" ls-files -s tools/ 2>/dev/null \
             | awk '$1 == "100644" { print $4 }' \
             | grep -E '\.(sh|py)$|/S99' || true)
    if [ -n "$NOEXEC" ]; then
        fail "these are committed WITHOUT the executable bit - CI cannot run them:"
        printf '%s\n' "$NOEXEC" | sed 's/^/          /'
        printf '          fix: git update-index --chmod=+x <file>\n'
    else
        pass "every script under tools/ carries the exec bit in git"
    fi
else
    skip "not a git checkout - exec bits NOT verified"
fi

# ssh inside a read loop must not eat stdin.
if grep -q 'ssh -n ' "$HERE/drift.sh" 2>/dev/null; then
    pass "drift.sh uses ssh -n (will not swallow its own loop input)"
else
    fail "drift.sh lost 'ssh -n' - it will silently check only the first module"
fi

# provision.sh must not hide apply-module.sh output on failure.
if grep -q 'apply-module.sh" "\$IP" "\$p" >/dev/null 2>&1' "$HERE/provision.sh" 2>/dev/null; then
    fail "provision.sh still discards apply-module.sh output - failures will be invisible"
else
    pass "provision.sh surfaces apply-module.sh output"
fi

# Anything calling apply-module.sh from inside a `while read` loop must give it
# </dev/null. apply-module.sh runs ssh, ssh reads stdin, and stdin there is the
# patch list — so without it the first module eats the rest and the run reports
# success having applied exactly one. This shipped twice.
for caller in provision.sh deprovision.sh; do
    if grep -q 'while IFS= read -r p' "$HERE/$caller" 2>/dev/null; then
        if grep -q 'apply-module.sh".*</dev/null' "$HERE/$caller" 2>/dev/null; then
            pass "$caller feeds apply-module.sh </dev/null inside its read loop"
        else
            fail "$caller calls apply-module.sh in a read loop WITHOUT </dev/null - only the first module will be processed"
        fi
    else
        skip "$caller has no read loop to check"
    fi
done

# ---------------------------------------------------------------- firmware
head_ "[6] firmware packer"
# Glob + case rather than `ls | grep` (SC2010): parsing ls breaks on unusual
# filenames, and the vendor image is the one WITHOUT "custom" in its name --
# our own signed build must not be used to selftest the packer against.
IMG=""
for _f in "$ROOT"/firmware/glkvm-RM10-*.img; do
    [ -f "$_f" ] || continue
    case "$_f" in *custom*) continue ;; esac
    IMG="$_f"; break
done
if [ -z "$IMG" ]; then
    skip "no RM10 image in firmware/ (gitignored) - rk_pack.py --selftest NOT run" structural
elif ! command -v "$PY" >/dev/null 2>&1; then
    skip "no python - rk_pack.py --selftest NOT run"
else
    try "rk_pack.py --selftest reproduces the vendor image byte-for-byte" \
        "$PY" "$HERE/rk_pack.py" "$IMG" --selftest
fi

# ---------------------------------------------------------------- device
head_ "[7] live device (read-only)"
if [ -z "$DEVICE" ]; then
    skip "no --with-device <ip> given - nothing was checked against real hardware" structural
else
    if ssh -n -i "$ROOT/.ssh-glkvm/id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes \
           -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "root@$DEVICE" true 2>/dev/null; then
        pass "ssh to $DEVICE"
        for spec in "443:https://$DEVICE/" "8888:https://$DEVICE:8888/login/" \
                    "prometheus:https://$DEVICE/api/export/prometheus/metrics"; do
            code=$(curl -sk --max-time 12 -o /dev/null -w '%{http_code}' "${spec#*:}" 2>/dev/null || echo 000)
            [ "$code" = "200" ] && pass "${spec%%:*} HTTP $code" || fail "${spec%%:*} HTTP $code"
        done
        if "$HERE/drift.sh" "$DEVICE" >/tmp/.st_drift 2>&1; then
            pass "drift.sh reports no drift"
        else
            fail "drift.sh reports drift"
            sed 's/^/          /' /tmp/.st_drift | head -20
        fi
        rm -f /tmp/.st_drift

        # VNC regressions for the two patched kvmd-vnc modules. Vendor 1.10.0
        # gave every client a black screen (JPEG sink never written, H.264
        # rejected when the sink is HEVC) and restarted ustreamer on every
        # TigerVNC re-negotiation. Each check below was red on the vendor
        # code and is green with patches/kvmd/apps/vnc/. They need a live
        # HDMI signal and the streamer in H.264 mode.
        if command -v "$PY" >/dev/null 2>&1; then
            _ssh() { ssh -n -i "$ROOT/.ssh-glkvm/id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes \
                         -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "root@$DEVICE" "$@" 2>/dev/null; }
            _probe=$("$PY" "$HERE/vnc-probe.py" "$DEVICE" 5900 7,-26,-223,0 2>&1 | grep -E '^update' | head -3)
            _jpeg=$(printf '%s\n' "$_probe" | grep -oE 'TightJPEG +bytes=[0-9]+' | grep -oE '[0-9]+$' | sort -n | tail -1)
            if [ -n "$_jpeg" ] && [ "$_jpeg" -gt 20000 ]; then
                pass "kvmd-vnc JPEG path: Tight JPEG frame of $_jpeg bytes (a 9.5 KB frame would be the 'Waiting for stream' placeholder)"
            else
                fail "kvmd-vnc JPEG path: no real Tight JPEG frame - SnapshotStreamerClient missing or no HDMI signal"
                printf '%s\n' "$_probe" | sed 's/^/          /'
            fi
            _probe=$("$PY" "$HERE/vnc-probe.py" "$DEVICE" 5900 50,7,-26,-223,0 2>&1 | grep -E '^update' | head -3)
            if printf '%s\n' "$_probe" | grep -q 'H264 '; then
                pass "kvmd-vnc H.264 path: Open H.264 rects delivered"
            else
                fail "kvmd-vnc H.264 path: no H.264 rect - streamer in H.265 mode, or the H.264 memsink is not feeding"
                printf '%s\n' "$_probe" | sed 's/^/          /'
            fi
            _before=$(_ssh 'grep -c "Started streamer" /var/log/kvmd.log')
            "$PY" "$HERE/vnc-churn.py" "$DEVICE" 5900 4 >/dev/null 2>&1
            _after=$(_ssh 'grep -c "Started streamer" /var/log/kvmd.log')
            if [ -n "$_before" ] && [ -n "$_after" ] && [ "$_after" -eq "$_before" ]; then
                pass "kvmd-vnc re-negotiation churn: 4 quality flips, 0 ustreamer restarts (vendor: 1 per flip)"
            else
                fail "kvmd-vnc re-negotiation churn restarted ustreamer $((${_after:-0} - ${_before:-0})) times in 4 flips"
            fi
        else
            skip "no python interpreter - the VNC regressions were NOT run"
        fi
    else
        fail "cannot ssh to $DEVICE (asked for --with-device, so this is a failure, not a skip)"
    fi
fi

# ---------------------------------------------------------------- summary
printf '\n\033[1m=== %d passed, %d failed, %d skipped ===\033[0m\n' "$PASS" "$FAIL" "$SKIP"
if [ "$SKIP" -gt 0 ]; then
    echo "NOTE: skipped checks are NOT passes. Each one above says what went unverified."
fi
if [ "$FAIL" -gt 0 ]; then
    echo "RESULT: FAILED"
    exit 1
fi
echo "RESULT: OK"
exit 0
