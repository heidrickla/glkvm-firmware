#!/bin/sh
# Fetch + verify GL-RM1 firmware images against SHA256SUMS in this directory.
# Hashes there came from the vendor's testing/list-sha256.txt.
# GLKVM_FW_BASE overrides the download base (a mirror, or file:// in selftest);
# every image is still checked against SHA256SUMS.
set -u
BASE="${GLKVM_FW_BASE:-https://fw.gl-inet.com/kvm}"
# NOTE: our units are RM10. rm10 has NO release channel, only testing.
cd "$(dirname "$0")" || exit 1

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# The hash SHA256SUMS records for a file name ("<hex> *<name>" or "<hex>  <name>").
expected_sha256() {
    awk -v n="$1" '$1 ~ /^[0-9a-f]{64}$/ { f = $2; sub(/^\*/, "", f); if (f == n) { print $1; exit } }' SHA256SUMS
}

verify() { # file [name-in-SHA256SUMS]
    want=$(expected_sha256 "${2:-$1}")
    if [ -z "$want" ]; then
        echo "FAIL: no SHA256SUMS entry for ${2:-$1}" >&2
        return 1
    fi
    got=$(sha256_of "$1")
    if [ "$got" != "$want" ]; then
        echo "FAIL: $1 sha256 $got, SHA256SUMS says $want" >&2
        return 1
    fi
    echo "   sha256 ok"
}

fetch() { # url outfile
    if [ -s "$2" ]; then
        echo "   (already present, skipping fetch)"
        verify "$2"
        return
    fi
    rm -f "$2.part"
    curl -fL --proto '=https,file' --proto-redir '=https' --max-time 1800 --retry 3 --retry-delay 5 -o "$2.part" "$1" \
        || { rm -f "$2.part"; return 1; }
    if verify "$2.part" "$2"; then
        mv "$2.part" "$2"
    else
        rm -f "$2.part"
        return 1
    fi
}

rc=0
echo "== RM10 1.10.0 (the CORRECT product for our units) =="
fetch "$BASE/rm10/testing/glkvm-RM10-1.10.0-0715-1784101556.img" "glkvm-RM10-1.10.0-0715-1784101556.img" || rc=1
echo "== RM1 images below are a DIFFERENT PRODUCT - reference only =="
echo "== RM1 1.10.0 =="
fetch "$BASE/rm1/testing/glkvm-RM1-1.10.0-0710-1783648193.img" "glkvm-RM1-1.10.0-0710-1783648193.img" || rc=1
echo "== 1.7.0 =="
fetch "$BASE/rm1/testing/glkvm-RM1-1.7.0-1107-1762486370.img"  "glkvm-RM1-1.7.0-1107-1762486370.img" || rc=1
echo "== 1.3.0 (release channel) =="
fetch "$BASE/rm1/release/update.img" "glkvm-RM1-1.3.0-release-update.img" || rc=1
echo
echo "== sizes =="
ls -l ./*.img 2>/dev/null
[ "$rc" -eq 0 ] || echo "RESULT: FAILED - an image did not match SHA256SUMS or could not be fetched" >&2
exit "$rc"
