#!/usr/bin/env python3
"""Fetch a tesseract runtime for the GL-RM10 from Ubuntu's arm64 archive.

RUNS ON THE BUILD VM (needs dpkg-deb, gpgv or sqv, the ubuntu-keyring
package and outbound HTTPS). Driven by
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

TRUST CHAIN
-----------
Each suite's Release is checked against Release.gpg with gpgv (or sqv) and the
Ubuntu archive keyring; each Packages.gz against the SHA256 in that Release;
each .deb, cached or fresh, against the SHA256 in its index entry. Any mismatch
stops the run before anything is extracted. UBUNTU_ARCHIVE_KEYRING overrides
the keyring path.

    python3 ocr-fetch.py --selftest     # offline checks of the parsers
"""

import gzip
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

MIRROR = "https://ports.ubuntu.com/ubuntu-ports"
KEYRING = os.environ.get(
    "UBUNTU_ARCHIVE_KEYRING", "/usr/share/keyrings/ubuntu-archive-keyring.gpg"
)
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


class VerifyError(Exception):
    """A signature or hash did not match. Never caught: the run stops."""


def fetch(url):
    if not url.startswith("https://"):
        raise VerifyError(f"refusing a non-https URL: {url}")
    with urllib.request.urlopen(url, timeout=60) as r:
        if not r.geturl().startswith("https://"):
            raise VerifyError(f"{url} redirected off https to {r.geturl()}")
        return r.read()


def check_sha256(data, want, what):
    got = hashlib.sha256(data).hexdigest()
    if not want or got != want.strip().lower():
        raise VerifyError(f"{what}: sha256 {got}, expected {want or '<none>'}")


def release_sha256(text):
    """{path: sha256} from the SHA256 section of a Release file."""
    out, in_section = {}, False
    for line in text.splitlines():
        if not line[:1].isspace():
            in_section = line.strip() == "SHA256:"
            continue
        if in_section:
            parts = line.split()
            if len(parts) == 3 and re.fullmatch(r"[0-9a-f]{64}", parts[0]):
                out[parts[2]] = parts[0]
    return out


def release_field(text, name):
    for line in text.splitlines():
        if line.startswith(name + ":"):
            return line.partition(":")[2].strip()
    return None


def verify_signature(release, signature):
    """Check a detached Release.gpg against the Ubuntu archive keyring."""
    if not os.path.isfile(KEYRING):
        raise VerifyError(f"archive keyring missing: {KEYRING} (apt install ubuntu-keyring)")
    with tempfile.TemporaryDirectory() as d:
        rel, sig = os.path.join(d, "Release"), os.path.join(d, "Release.gpg")
        with open(rel, "wb") as fh:
            fh.write(release)
        with open(sig, "wb") as fh:
            fh.write(signature)
        if shutil.which("gpgv"):
            cmd = ["gpgv", "--keyring", KEYRING, sig, rel]
        elif shutil.which("sqv"):
            cmd = ["sqv", "--keyring", KEYRING, sig, rel]
        else:
            raise VerifyError("neither gpgv nor sqv is installed")
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            raise VerifyError(f"Release signature rejected by {cmd[0]}: {r.stderr.strip()}")


def load_release(suite):
    base = f"{MIRROR}/dists/{suite}"
    release = fetch(f"{base}/Release")
    verify_signature(release, fetch(f"{base}/Release.gpg"))
    text = release.decode("utf-8", "replace")
    got = release_field(text, "Suite")
    if got != suite:
        raise VerifyError(f"{base}/Release is signed for suite {got!r}, not {suite!r}")
    return release_sha256(text)


def load_index():
    """Return {package: {"Version","Filename","Depends","SHA256",...}} across
    all suites/components, newest suite last so updates override release."""
    index = {}
    for suite in SUITES:
        try:
            hashes = load_release(suite)
        except VerifyError:
            raise
        except Exception as ex:
            print(f"  ! {suite} Release: {ex}", file=sys.stderr)
            continue
        print(f"  release: {suite} signature ok")
        for comp in COMPONENTS:
            rel = f"{comp}/binary-{ARCH}/Packages.gz"
            url = f"{MIRROR}/dists/{suite}/{rel}"
            try:
                data = fetch(url)
            except VerifyError:
                raise
            except Exception as ex:
                print(f"  ! {url}: {ex}", file=sys.stderr)
                continue
            check_sha256(data, hashes.get(rel), url)
            raw = gzip.decompress(data).decode("utf-8", "replace")
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


def fetch_deb(name, fields, path):
    """The .deb at path, matching its index SHA256; a cached copy that does
    not match is fetched again."""
    want = fields.get("SHA256")
    if os.path.exists(path):
        with open(path, "rb") as fh:
            data = fh.read()
        try:
            check_sha256(data, want, path)
            return
        except VerifyError as ex:
            print(f"  ! cached {ex}; fetching again", file=sys.stderr)
            os.remove(path)
    data = fetch(f"{MIRROR}/{fields['Filename']}")
    check_sha256(data, want, name)
    with open(path + ".part", "wb") as fh:
        fh.write(data)
    os.replace(path + ".part", path)


def _with_stubs(fake_fetch, fake_verify, fn):
    """Run fn with the network and the signature check replaced."""
    global fetch, verify_signature
    real = fetch, verify_signature
    fetch, verify_signature = fake_fetch, fake_verify
    try:
        return fn()
    finally:
        fetch, verify_signature = real


def _selftest_index(refuses):
    para = b"Package: libfake1\nVersion: 1\nFilename: pool/f/libfake1_1_arm64.deb\nSHA256: " + b"b" * 64 + b"\n"
    good_gz = gzip.compress(para, mtime=0)

    def mirror(suite_field=None, gz=good_gz):
        def fake_fetch(url):
            for suite in SUITES:
                if url.endswith(f"/dists/{suite}/Release"):
                    lines = [f"Suite: {suite_field or suite}", "SHA256:"]
                    lines += [f" {hashlib.sha256(good_gz).hexdigest()} {len(good_gz)} "
                              f"{c}/binary-{ARCH}/Packages.gz" for c in COMPONENTS]
                    return ("\n".join(lines) + "\n").encode()
            if url.endswith("/Release.gpg"):
                return b"sig"
            if url.endswith("/Packages.gz"):
                return gz
            raise AssertionError(url)
        return fake_fetch

    def sig_ok(release, signature):
        return None

    def sig_bad(release, signature):
        raise VerifyError("bad signature")

    def loads(fake_fetch, fake_verify):
        return _with_stubs(fake_fetch, fake_verify, load_index)

    return [
        ("signed index with matching hashes loads",
         "libfake1" in _with_stubs(mirror(), sig_ok, load_index)),
        ("rejected Release signature stops the run", refuses(loads, mirror(), sig_bad)),
        ("Release for another suite refused", refuses(loads, mirror(suite_field="jammy"), sig_ok)),
        ("altered Packages.gz refused",
         refuses(loads, mirror(gz=gzip.compress(para + b"X", mtime=0)), sig_ok)),
    ]


def _selftest_debs(refuses):
    good, bad = b"genuine deb", b"substituted deb"
    fields = {"Filename": "pool/f/x.deb", "SHA256": hashlib.sha256(good).hexdigest()}
    out = []
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "x.deb")

        def serve(data):
            return lambda url: data

        def no_network(url):
            raise AssertionError("fetched although the cache matched")

        def run(fake_fetch):
            return _with_stubs(fake_fetch, None, lambda: fetch_deb("x", fields, path))

        out.append(("fresh deb with matching hash written",
                    not refuses(run, serve(good)) and open(path, "rb").read() == good))
        out.append(("matching cached deb kept without a fetch", not refuses(run, no_network)))
        with open(path, "wb") as fh:
            fh.write(bad)
        out.append(("tampered cached deb refetched", not refuses(run, serve(good))
                    and open(path, "rb").read() == good))
        os.remove(path)
        out.append(("substituted deb refused", refuses(run, serve(bad))))
        out.append(("substituted deb not written", not os.path.exists(path)))
    return out


def selftest():
    """Offline checks that each verification step refuses what it must."""
    sample = (
        "Origin: Ubuntu\nSuite: noble\nMD5Sum:\n"
        " " + "0" * 32 + " 10 main/binary-arm64/Packages.gz\n"
        "SHA256:\n"
        " " + hashlib.sha256(b"index").hexdigest() + " 5 main/binary-arm64/Packages.gz\n"
        " " + "a" * 64 + " 7 universe/binary-arm64/Packages.gz\n"
        "Acquire-By-Hash: yes\n"
    )
    hashes = release_sha256(sample)
    cases = [
        ("SHA256 section parsed", len(hashes) == 2),
        ("MD5Sum section ignored", "0" * 32 not in hashes.values()),
        ("Suite field read", release_field(sample, "Suite") == "noble"),
    ]

    def refuses(fn, *args):
        try:
            fn(*args)
        except VerifyError:
            return True
        return False

    cases += [
        ("matching hash accepted",
         not refuses(check_sha256, b"index", hashes["main/binary-arm64/Packages.gz"], "x")),
        ("altered data refused",
         refuses(check_sha256, b"indeX", hashes["main/binary-arm64/Packages.gz"], "x")),
        ("missing hash refused", refuses(check_sha256, b"index", None, "x")),
        ("plain http refused", refuses(fetch, "http://ports.ubuntu.com/ubuntu-ports/")),
        ("mirror is https", MIRROR.startswith("https://")),
    ]
    cases += _selftest_index(refuses) + _selftest_debs(refuses)
    bad = [n for n, ok in cases if not ok]
    for n, ok in cases:
        print(f"  {'ok  ' if ok else 'FAIL'} {n}")
    if bad:
        raise SystemExit(1)


def main():
    if sys.argv[1:2] == ["--selftest"]:
        selftest()
        return
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
        path = os.path.join(debs, os.path.basename(f["Filename"]))
        fetch_deb(name, f, path)
        subprocess.run(["dpkg-deb", "-x", path, root], check=True)
        manifest.append(f"{name} {f['Version']}")
        print(f"  {name:22s} {f['Version']}")

    print(">> collecting shared objects and language data")
    payload = os.path.join(outdir, "ocr-payload.tar.gz")
    n = 0
    with tarfile.open(payload + ".part", "w:gz") as tar:
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
    os.replace(payload + ".part", payload)
    print(f">> {payload}: {n} files, {os.path.getsize(payload)} bytes, {len(closure)} packages")


if __name__ == "__main__":
    main()
