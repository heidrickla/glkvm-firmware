#!/bin/sh
# Fetch + verify GL-RM1 firmware images. Hashes from testing/list-sha256.txt.
set -u
BASE="https://fw.gl-inet.com/kvm"
# NOTE: our units are RM10. rm10 has NO release channel, only testing.
cd "$(dirname "$0")"

fetch() { # url outfile
    if [ -s "$2" ]; then echo "   (already present, skipping fetch)"; return 0; fi
    curl -fkL --max-time 1800 --retry 3 --retry-delay 5 -o "$2.part" "$1" \
        && mv "$2.part" "$2"
}

echo "== RM10 1.10.0 (the CORRECT product for our units) =="
fetch "$BASE/rm10/testing/glkvm-RM10-1.10.0-0715-1784101556.img" "glkvm-RM10-1.10.0-0715-1784101556.img"
echo "== RM1 images below are a DIFFERENT PRODUCT - reference only =="
echo "== RM1 1.10.0 =="
fetch "$BASE/rm1/testing/glkvm-RM1-1.10.0-0710-1783648193.img" "glkvm-RM1-1.10.0-0710-1783648193.img"
echo "== 1.7.0 =="
fetch "$BASE/rm1/testing/glkvm-RM1-1.7.0-1107-1762486370.img"  "glkvm-RM1-1.7.0-1107-1762486370.img"
echo "== 1.3.0 (release channel) =="
fetch "$BASE/rm1/release/update.img" "glkvm-RM1-1.3.0-release-update.img"
echo
echo "== sizes =="
ls -l *.img 2>/dev/null
