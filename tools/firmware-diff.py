#!/usr/bin/env python3
"""Diff two GL-RM10 firmware trees and say what changed, and how.

    firmware-diff.py --old <site-packages> --new <site-packages> \
                     [--old-etc <etc/kvmd>] [--new-etc <etc/kvmd>] [--report out.md]

RUN ON THE BUILD VM: it loads .pyc with marshal, so it needs the same CPython
(3.12) that produced them. Bytecode is arch-independent, so x86 is fine.

WHY THIS EXISTS
---------------
The device ships kvmd sourceless (.pyc only) and GL.iNet does not bump the
version string between firmwares -- 1.8.1 and 1.10.0 both say kvmd 4.82. After
flashing 1.10.0 onto a unit provisioned on 1.8.1, four behaviours changed (MSD
gadget functions unlinked at boot, MSD remount default broken, health
registered natively, ustreamer refusing to capture without an HDMI signal) and
each was chased one symptom at a time. Lewis: "Couldn't you just diff the two
firmwares to see what they fixed and how?" Yes. This is that diff, kept so the
next firmware gets it up front.

WHAT IT REPORTS
---------------
1. kvmd modules added / removed / changed / identical, comparing .pyc bodies
   with the 16-byte header (mtime, size) skipped.
2. For every CHANGED module: which string constants, referenced names and
   function names appeared or disappeared. That is not a decompile, but it is
   usually enough to name the change -- "start_cdrom" appearing in
   apps/__init__.pyc IS the new MSD gadget switch; "${mode}" appearing in the
   msd plugin IS the broken remount default; "rknn" appearing in ocr IS the NPU
   backend. Function-name changes show restructuring.
3. /etc/kvmd: files added / removed, and a unified diff of changed text files.
   NOTE the "old" etc tree from a checkpoint carries our own provisioning
   (override.yaml, nginx 8888, user/scripts); the vendor originals are the
   .orig files beside them, and those are compared too when present.
"""

import argparse
import difflib
import hashlib
import marshal
import os
import re
import sys
import types

PYC_HEADER = 16
NOISE = re.compile(r"^[\W_]*$")

# Files whose CONTENTS must never appear in a report, matched on the relative
# path. The first run of this tool printed /etc/kvmd/ipmipasswd -- which maps
# the IPMI login onto the real KVMD admin password in plaintext -- and the
# htpasswd hash beside it, into a chat transcript. That credential had to be
# rotated. A diff tool sees everything; it must know what not to show.
SECRET_PATHS = re.compile(
    r"(^|/)(ipmipasswd|htpasswd|vncpasswd|totp\.secret|tailscaled\.state|"
    r"tailscale\.json|authorized_keys|.*\.key|.*\.crt|.*\.pem|.*\.psk\.config|"
    r"settings)$|(^|/)(ssl|tailscale|connman|netbird)/"
)


def is_secret(rel):
    return bool(SECRET_PATHS.search(rel))


def walk_files(root):
    out = {}
    for dirpath, dirnames, files in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != "__pycache__"]
        for fn in files:
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            try:
                out[rel] = open(full, "rb").read()
            except OSError:
                pass
    return out


def pyc_body(data):
    return data[PYC_HEADER:] if len(data) > PYC_HEADER else data


def code_facts(data):
    """(strings, names, funcs) for every code object reachable from a .pyc."""
    strings, names, funcs = set(), set(), set()
    try:
        top = marshal.loads(pyc_body(data))
    except Exception as ex:  # noqa: BLE001 - report, never crash the diff
        return {"<unmarshal failed: %s>" % ex}, set(), set()

    def walk(c):
        yield c
        for k in c.co_consts:
            if isinstance(k, types.CodeType):
                yield from walk(k)

    for c in walk(top):
        if c.co_name != "<module>":
            funcs.add(c.co_name)
        names.update(c.co_names)
        for k in c.co_consts:
            if isinstance(k, str) and 3 < len(k) < 120 and not NOISE.match(k):
                strings.add(k)
    return strings, names, funcs


def show_set_diff(title, old, new, cap=30):
    added = sorted(new - old)
    gone = sorted(old - new)
    lines = []
    if added:
        lines.append("  + %s (%d): %s%s" % (title, len(added), ", ".join(repr(x) for x in added[:cap]),
                                             " ..." if len(added) > cap else ""))
    if gone:
        lines.append("  - %s (%d): %s%s" % (title, len(gone), ", ".join(repr(x) for x in gone[:cap]),
                                             " ..." if len(gone) > cap else ""))
    return lines


def diff_pyc_trees(old, new, out):
    o = {k: v for k, v in old.items() if k.endswith(".pyc")}
    n = {k: v for k, v in new.items() if k.endswith(".pyc")}
    added = sorted(set(n) - set(o))
    removed = sorted(set(o) - set(n))
    common = sorted(set(o) & set(n))
    changed = [k for k in common if hashlib.sha256(pyc_body(o[k])).digest()
               != hashlib.sha256(pyc_body(n[k])).digest()]
    same = len(common) - len(changed)

    out.append("## kvmd bytecode: %d added, %d removed, %d changed, %d identical\n"
               % (len(added), len(removed), len(changed), same))
    if added:
        out.append("### Added modules\n")
        out.extend("- `%s` (%d B)" % (k, len(n[k])) for k in added)
        out.append("")
    if removed:
        out.append("### Removed modules\n")
        out.extend("- `%s` (%d B)" % (k, len(o[k])) for k in removed)
        out.append("")
    if changed:
        out.append("### Changed modules — what appeared (+) and vanished (-)\n")
        for k in changed:
            os_, on, of = code_facts(o[k])
            ns, nn, nf = code_facts(n[k])
            out.append("#### `%s`  (%d → %d B)" % (k, len(o[k]), len(n[k])))
            body = []
            body += show_set_diff("functions", of, nf)
            body += show_set_diff("names", on, nn)
            body += show_set_diff("strings", os_, ns)
            out.extend(body if body else ["  (bytes differ; no constant/name/function changes — line numbers or ordering only)"])
            out.append("")


def diff_etc_trees(old, new, out):
    added = sorted(set(new) - set(old))
    removed = sorted(set(old) - set(new))
    common = sorted(set(old) & set(new))
    changed = [k for k in common if old[k] != new[k]]

    # Where the old tree carries our provisioning, the vendor's own file sits
    # beside it as .orig -- compare THAT to the new vendor file as well.
    vendor_pairs = []
    for k in common:
        if k + ".orig" in old:
            vendor_pairs.append(k)

    out.append("## /etc/kvmd: %d added, %d removed, %d changed, %d identical\n"
               % (len(added), len(removed), len(changed), len(common) - len(changed)))
    if added:
        out.append("### Added\n")
        out.extend("- `%s` (%d B)" % (k, len(new[k])) for k in added)
        out.append("")
    if removed:
        out.append("### Removed (includes our own provisioning artefacts on the old side)\n")
        out.extend("- `%s` (%d B)" % (k, len(old[k])) for k in removed)
        out.append("")

    def textdiff(a, b, label_a, label_b, cap=80, rel=""):
        if is_secret(rel):
            return ["  (credential file: contents redacted; %d → %d bytes)" % (len(a), len(b))]
        try:
            ta = a.decode("utf-8").splitlines()
            tb = b.decode("utf-8").splitlines()
        except UnicodeDecodeError:
            return ["  (binary; %d → %d bytes)" % (len(a), len(b))]
        d = list(difflib.unified_diff(ta, tb, label_a, label_b, lineterm="", n=1))
        if len(d) > cap:
            d = d[:cap] + ["  ... (%d more lines)" % (len(d) - cap)]
        return ["```diff"] + d + ["```"]

    if vendor_pairs:
        out.append("### Vendor-to-vendor: old `.orig` vs new file\n")
        for k in vendor_pairs:
            if old[k + ".orig"] == new[k]:
                out.append("- `%s`: vendor file **unchanged** between firmwares" % k)
            else:
                out.append("- `%s`: vendor file changed:" % k)
                out.extend(textdiff(old[k + ".orig"], new[k], "1.8.1 vendor", "1.10.0 vendor", rel=k))
        out.append("")
    if changed:
        out.append("### Changed (old side may carry our provisioning)\n")
        for k in changed:
            if k in vendor_pairs:
                continue
            out.append("- `%s`:" % k)
            out.extend(textdiff(old[k], new[k], "old", "new", rel=k))
        out.append("")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--old", required=True, help="old site-packages dir (contains kvmd/)")
    ap.add_argument("--new", required=True, help="new site-packages dir (contains kvmd/)")
    ap.add_argument("--old-etc", help="old etc/kvmd dir")
    ap.add_argument("--new-etc", help="new etc/kvmd dir")
    ap.add_argument("--report", help="write markdown here instead of stdout")
    a = ap.parse_args()

    out = ["# Firmware diff\n", "old: `%s`  \nnew: `%s`\n" % (a.old, a.new)]
    old = walk_files(os.path.join(a.old, "kvmd"))
    new = walk_files(os.path.join(a.new, "kvmd"))
    if not old or not new:
        sys.exit("no kvmd/ tree under one of the site-packages paths")
    diff_pyc_trees(old, new, out)
    if a.old_etc and a.new_etc:
        diff_etc_trees(walk_files(a.old_etc), walk_files(a.new_etc), out)

    text = "\n".join(out) + "\n"
    if a.report:
        open(a.report, "w", encoding="utf-8").write(text)
        print("wrote %s (%d lines)" % (a.report, text.count("\n")))
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
