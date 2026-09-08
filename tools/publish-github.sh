#!/bin/sh
# publish-github.sh - publish this repo to GitHub as a SCRUBBED mirror.
#
#   ./tools/publish-github.sh              # clone the forge, rewrite, prove, push
#   ./tools/publish-github.sh --dry-run    # everything except the push
#   ./tools/publish-github.sh --force      # push --force; only after tools/publish/ changed
#
# WHY A MIRROR AND NOT A SECOND REMOTE
#
# The forge history carries the lab's real addresses and hostnames, a device
# config captured with its cloud credential, and a vendor private key lifted
# from a firmware image. GitHub gets a REWRITE of that history: every commit is
# re-created with tools/publish/replacements.txt applied to file contents and
# commit messages, and the paths in tools/publish/drop-paths.txt (plus
# tools/publish/ itself) removed from every commit. The rewrite is
# deterministic, so after new forge commits the old ones come out with the
# same SHAs and the push is a fast-forward. The SHAs still differ from the
# forge's by design:
#
#   * never push the forge history to GitHub directly
#   * never merge or pull GitHub into the forge
#   * tools/publish/ never leaves the forge
#
# It publishes what the FORGE has, not the working tree: a commit that is not
# on the forge has not been through CI.
#
# FAILS LOUDLY. A leftover match for any map entry anywhere in the rewritten
# objects is a FAIL, not a warning; so is a dropped path that survives, a map
# line without '==>' (git filter-repo would replace that text with
# ***REMOVED*** everywhere), an empty map, or a GitHub branch the rewrite does
# not descend from (that needs --force, and a reason).
#
# Map format (tools/publish/replacements.txt), one rule per line, NO comments:
#   literal==>replacement
#   regex:pattern==>replacement      Python re; \1 is the first group
# Keep regex character classes grep-compatible ([0-9], not \d): the same
# left-hand side is fed to grep -E to prove nothing survived.
#
# Needs git-filter-repo (pip install git-filter-repo) and ssh access to both
# forges. PUBLISH_GITHUB_URL overrides the destination.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MAP="$ROOT/tools/publish/replacements.txt"
DROP="$ROOT/tools/publish/drop-paths.txt"
GITHUB_URL="${PUBLISH_GITHUB_URL:-git@github.com:heidrickla/$(basename "$ROOT").git}"

DRY=0; FORCE=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --force)   FORCE=1 ;;
        *) echo "usage: $0 [--dry-run] [--force]" >&2; exit 2 ;;
    esac
done

die() { printf 'FAIL  %s\n' "$*" >&2; exit 1; }
ok()  { printf 'ok    %s\n' "$*"; }

git filter-repo --version >/dev/null 2>&1 \
    || die "git-filter-repo is not installed (pip install git-filter-repo)"
[ -s "$MAP" ] || die "no map at $MAP - nothing would be scrubbed"

WORK=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$WORK"' EXIT INT TERM
SRC="$WORK/src"

# ------------------------------------------------------------------ the map
# Read through CR-stripped copies: a CRLF checkout would otherwise leave a
# carriage return on every dropped path, the drop would miss, and the proof
# below would pass vacuously.
MAPC="$WORK/replacements.txt"; DROPC="$WORK/drop-paths.txt"
tr -d '\r' < "$MAP" > "$MAPC"
if [ -s "$DROP" ]; then tr -d '\r' < "$DROP" > "$DROPC"; else : > "$DROPC"; fi
NRULES=0
while IFS= read -r rule || [ -n "$rule" ]; do
    [ -n "$rule" ] || continue
    case "$rule" in
        *'==>'*) NRULES=$((NRULES + 1)) ;;
        *) die "map line without '==>' (filter-repo would turn every occurrence into ***REMOVED***): $rule" ;;
    esac
done < "$MAPC"
[ "$NRULES" -ge 1 ] || die "map has no rules"

# --------------------------------------------------------------- the source
FORGE_URL=$(git -C "$ROOT" remote get-url gitea 2>/dev/null \
         || git -C "$ROOT" remote get-url origin 2>/dev/null) \
    || die "no 'gitea' or 'origin' remote to clone the forge from"
BRANCH=$(git -C "$ROOT" symbolic-ref --short HEAD) \
    || die "detached HEAD - check out the branch to publish"

git clone --quiet --no-local --branch "$BRANCH" --single-branch "$FORGE_URL" "$SRC" \
    || die "clone of $FORGE_URL ($BRANCH) failed"
FORGE_HEAD=$(git -C "$SRC" rev-parse HEAD)
NFORGE=$(git -C "$SRC" rev-list --count HEAD)
ok "forge $BRANCH is $FORGE_HEAD ($NFORGE commits)"
if [ "$(git -C "$ROOT" rev-parse HEAD)" != "$FORGE_HEAD" ]; then
    printf 'note  working tree HEAD %s is not the forge HEAD - publishing the forge\n' \
        "$(git -C "$ROOT" rev-parse --short HEAD)"
fi
git -C "$SRC" ls-tree -r HEAD > "$WORK/before.txt"

# -------------------------------------------------------------- the rewrite
set -- --replace-text "$MAPC" --replace-message "$MAPC" --invert-paths --path tools/publish
NDROP=0
if [ -s "$DROPC" ]; then
    while IFS= read -r p || [ -n "$p" ]; do
        case "$p" in ''|'#'*) continue ;; esac
        set -- "$@" --path "$p"
        NDROP=$((NDROP + 1))
    done < "$DROPC"
fi
ok "$NRULES replacement rules, $NDROP dropped paths (plus tools/publish/)"

if (cd "$SRC" && git filter-repo "$@") > "$WORK/filter.log" 2>&1; then
    tail -2 "$WORK/filter.log" | sed 's/^/      /'
else
    cat "$WORK/filter.log" >&2
    die "git filter-repo failed"
fi
NPUB=$(git -C "$SRC" rev-list --count HEAD)
[ "$NPUB" -ge 1 ] || die "the rewrite produced no commits"
git -C "$SRC" ls-tree -r HEAD > "$WORK/after.txt"

# What changed at HEAD, so the effect is visible rather than assumed.
awk -F'\t' '
    NR == FNR { before[$2] = $1; next }
    { after[$2] = $1 }
    END {
        for (p in before) {
            if (!(p in after))              { d++; printf "      dropped  %s\n", p }
            else if (before[p] != after[p]) { c++; printf "      changed  %s\n", p }
        }
        for (p in after) if (!(p in before)) { a++; printf "      added    %s\n", p }
        printf "      %d changed, %d dropped, %d added at HEAD\n", c, d, a
    }' "$WORK/before.txt" "$WORK/after.txt"

# ---------------------------------------------------------------- the proof
# Every object in the rewritten history (blobs, trees, commits, tags), scanned
# for the left-hand side of every rule and for every dropped path.
git -C "$SRC" rev-list --all --objects | cut -d' ' -f1 \
    | git -C "$SRC" cat-file --batch > "$WORK/objects.bin"
NBYTES=$(wc -c < "$WORK/objects.bin" | tr -d ' ')
[ "$NBYTES" -gt 0 ] || die "the object dump is empty - the proof would be vacuous"

LEFT=0
while IFS= read -r rule || [ -n "$rule" ]; do
    [ -n "$rule" ] || continue
    lhs=${rule%%==>*}
    case "$lhs" in
        regex:*) n=$(grep -a -c -E -e "${lhs#regex:}" "$WORK/objects.bin" || true) ;;
        *)       n=$(grep -a -c -F -e "$lhs" "$WORK/objects.bin" || true) ;;
    esac
    case "$n" in
        ''|*[!0-9]*) die "grep could not evaluate this rule: $lhs" ;;
    esac
    if [ "$n" -gt 0 ]; then
        LEFT=$((LEFT + 1))
        printf 'FAIL  %s object line(s) still match: %s\n' "$n" "$lhs" >&2
    fi
done < "$MAPC"
if [ -s "$DROPC" ]; then
    while IFS= read -r p || [ -n "$p" ]; do
        case "$p" in ''|'#'*) continue ;; esac
        n=$(git -C "$SRC" log --all --format= --name-only -- "$p" | grep -c . || true)
        if [ "$n" -gt 0 ]; then
            LEFT=$((LEFT + 1))
            printf 'FAIL  dropped path still present in %s commit(s): %s\n' "$n" "$p" >&2
        fi
    done < "$DROPC"
fi
n=$(git -C "$SRC" log --all --format= --name-only -- tools/publish | grep -c . || true)
if [ "$n" -gt 0 ]; then
    LEFT=$((LEFT + 1))
    printf 'FAIL  tools/publish/ survives in %s commit(s)\n' "$n" >&2
fi
[ "$LEFT" -eq 0 ] || die "$LEFT rule(s) survive the rewrite - not publishing"
ok "no rule survives anywhere in the rewritten history ($NPUB commits, $NBYTES bytes of objects scanned)"

# ----------------------------------------------------------------- the push
NEW_HEAD=$(git -C "$SRC" rev-parse HEAD)
REMOTE_HEAD=$(git ls-remote "$GITHUB_URL" "refs/heads/$BRANCH" 2>/dev/null | cut -f1 || true)
if [ -n "$REMOTE_HEAD" ]; then
    if git -C "$SRC" merge-base --is-ancestor "$REMOTE_HEAD" HEAD 2>/dev/null; then
        ok "GitHub $BRANCH ($REMOTE_HEAD) is an ancestor of the rewrite - fast-forward"
    elif [ "$FORCE" = 1 ]; then
        printf 'note  GitHub %s (%s) is NOT an ancestor of the rewrite; --force given\n' "$BRANCH" "$REMOTE_HEAD"
    else
        die "GitHub $BRANCH ($REMOTE_HEAD) is not an ancestor of the rewrite: the map or the forge history changed. Re-run with --force only if you have read this"
    fi
else
    ok "GitHub has no $BRANCH yet"
fi
if [ "$DRY" = 1 ]; then
    ok "dry run: would push $NEW_HEAD ($NPUB commits) to $GITHUB_URL $BRANCH"
    exit 0
fi
if [ "$FORCE" = 1 ]; then
    git -C "$SRC" push --force "$GITHUB_URL" "HEAD:refs/heads/$BRANCH"
else
    git -C "$SRC" push "$GITHUB_URL" "HEAD:refs/heads/$BRANCH"
fi
NOW=$(git ls-remote "$GITHUB_URL" "refs/heads/$BRANCH" | cut -f1)
[ "$NOW" = "$NEW_HEAD" ] || die "GitHub $BRANCH is $NOW after the push, expected $NEW_HEAD"
ok "GitHub $BRANCH is $NOW ($NPUB commits), published from forge $FORGE_HEAD"
