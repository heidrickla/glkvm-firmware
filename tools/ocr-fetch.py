#!/usr/bin/env python3
"""Fetch a tesseract runtime for the GL-RM10 from Ubuntu's arm64 archive.

RUNS ON THE BUILD VM (needs dpkg-deb and outbound HTTP). Driven by
tools/ocr.sh; produces <outdir>/ocr-payload.tar.gz and a manifest.

    python3 ocr-fetch.py <outdir>

WHY PREBUILT PACKAGES, NOT A CROSS-COMPILE
------------------------------------------
The device is aarch64 with glibc 2.41 (Buildroot 2024.02), measured two ways.
Ubuntu noble's arm64 libtesseract5 (5.3.4) is built against glibc 2.39, so it
loads there as-is. Compiling tesseract + leptonica under qemu-user would take
an hour and produce the same binary interface.

WHY A RESOLVER, NOT A HAND-WRITTEN LIST
---------------------------------------
libtesseract5 -> liblept5 -> {gif, jpeg8, openjp2, png16, tiff6, webp, webpmux}
and libtesseract5 -> libarchive13 -> {xml2 -> icu, nettle, lz4, ...}. The
device already has some of these (libjpeg.so.62, libcurl.so.4, libz, liblzma,
libbz2, libstdc++) and lacks others. Guessing the closure is how a library
"installs" and then fails at first use with one missing soname. So: parse the
real Packages index, walk Depends, download everything, and let the DEVICE-side
installer keep only the sonames it lacks -- it never overwrites an existing
library, because replacing a Buildroot libstdc++ with Ubuntu's could break
every other binary on the box.

Alternatives (a | b) take the first option. Version constraints are ignored:
the whole closure comes from one release pocket, so it is self-consistent.
"""

import gzip
import io
import os
import re
import subprocess
import sys
import tarfile
import urllib.request

MIRROR = "http://ports.ubuntu.com/ubuntu-ports"
SUITES = ("noble", "noble-updates")
COMPONENTS = ("main", "universe")
ARCH = "arm64"

ROOTS = ["libtesseract5", "liblept5", "tesseract-ocr-eng"]

# Provided by the device's own Buildroot system. Never shipped.
EXCLUDE = {
    "libc6", "libgcc-s1", "libstdc++6", "zlib1g", "liblzma5", "libbz2-1.0",
    "libcurl4t64", "libcurl4", "gcc-14-base", "gcc-13-base", "libc6-dev",
    # tesseract-ocr-eng depends on the tesseract-ocr binary package, which
    # pulls the CLI and its whole tool chain; we only want the language data.
    "tesseract-ocr",
}


def fetch(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read()


def load_index():
    """Return {package: {"Version","Filename","Depends","Priority"}} across all
    suites/components, newest suite last so updates override release."""
    index = {}
    for suite in SUITES:
        for comp in COMPONENTS:
            url = f"{MIRROR}/dists/{suite}/{comp}/binary-{ARCH}/Packages.gz"
            try:
                raw = gzip.decompress(fetch(url)).decode("utf-8", "replace")
            except Exception as ex:
                print(f"  ! {url}: {ex}", file=sys.stderr)
                continue
            for para in raw.split("\n\n"):
                fields = {}
                key = None
                for line in para.split("\n"):
                    if not line:
                        continue
                    if line[0] in " \t" and key:
                        fields[key] += " " + line.strip()
                    elif ":" in line:
                        key, _, val = line.partition(":")
                        fields[key] = val.strip()
                if "Package" in fields and "Filename" in fields:
                    index[fields["Package"]] = fields
            print(f"  index: {suite}/{comp} ({len(index)} packages so far)")
    # Arch-independent packages (tesseract-ocr-eng) live in the same index
    # under Architecture: all, so nothing extra is needed for them.
    return index


def deps_of(fields):
    out = []
    for dep in fields.get("Depends", "").split(","):
        dep = dep.strip()
        if not dep:
            continue
        first = dep.split("|")[0].strip()
        name = re.split(r"[\s(:]", first, 1)[0]
        if name:
            out.append(name)
    return out


def resolve(index):
    want, seen, order = list(ROOTS), set(), []
    while want:
        name = want.pop(0)
        if name in seen or name in EXCLUDE:
            continue
        seen.add(name)
        fields = index.get(name)
        if not fields:
            print(f"  ! not in index: {name}", file=sys.stderr)
            continue
        order.append(name)
        want.extend(d for d in deps_of(fields) if d not in seen and d not in EXCLUDE)
    return order


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    debs = os.path.join(outdir, "debs")
    root = os.path.join(outdir, "root")
    os.makedirs(debs, exist_ok=True)
    if os.path.isdir(root):
        subprocess.run(["rm", "-rf", root], check=True)
    os.makedirs(root)

    print(">> reading package indices")
    index = load_index()
    print(">> resolving the dependency closure of", ", ".join(ROOTS))
    closure = resolve(index)
    manifest = []
    for name in closure:
        f = index[name]
        url = f"{MIRROR}/{f['Filename']}"
        path = os.path.join(debs, os.path.basename(f["Filename"]))
        if not os.path.exists(path):
            open(path, "wb").write(fetch(url))
        subprocess.run(["dpkg-deb", "-x", path, root], check=True)
        manifest.append(f"{name} {f['Version']}")
        print(f"  {name:22s} {f['Version']}")

    print(">> collecting shared objects and language data")
    payload = os.path.join(outdir, "ocr-payload.tar.gz")
    n = 0
    with tarfile.open(payload, "w:gz") as tar:
        for dirpath, _, files in os.walk(root):
            for fn in files:
                full = os.path.join(dirpath, fn)
                rel = os.path.relpath(full, root)
                if re.search(r"\.so(\.\d+)*$", fn) and "/lib/" in "/" + rel:
                    # Flatten the multiarch dir: the device uses plain /usr/lib.
                    tar.add(full, arcname="lib/" + fn)
                    n += 1
                elif fn.endswith(".traineddata"):
                    tar.add(full, arcname="tessdata/" + fn)
                    n += 1
        mf = "\n".join(manifest) + "\n"
        info = tarfile.TarInfo("MANIFEST")
        info.size = len(mf)
        tar.addfile(info, io.BytesIO(mf.encode()))
    print(f">> {payload}: {n} files, {os.path.getsize(payload)} bytes, {len(closure)} packages")


if __name__ == "__main__":
    main()
