"""Read the live kernel refcount of each hidg character device on a GL-RM10 (firmware 1.10.0, kernel 6.1.141).

The kernel keeps one `struct cdev` embedded in each `struct f_hidg`. Its kobject refcount is 1 for the
registration plus 1 per open file. A plain UDC unbind/bind re-initialises the embedded cdev while files stay
open (fixed upstream by commit 81ebd43cc0d6, "usb: gadget: f_hid: don't call cdev_init while cdev in use"),
so a count below 1 + open files means the next close of the last counted file leaves the device registered
but dead, and every open fails with ENXIO until `kvmd-otgconf --reset-gadget`.

Runs on the unit as root (`/dev/mem` is readable there, the Image text at 0x40210000 matches the FIT kernel).
Addresses come from the unit's own kernel image: the `cdev_map` pointer from `cdev_del`, the kobj types from
`cdev_init` and `cdev_alloc`, the struct offsets from `hidg_unbind` and `f_hidg_open`.

    python3 hidg-kref.py            one table: name, minor, cdev, kref, open files, expected
    python3 hidg-kref.py watch 30   20 ms samples for 30 s, printed on change
    python3 hidg-kref.py chain      the raw cdev_map probe chain for major 237
"""

import os
import struct
import sys
import time

KIMG_VA = 0xFFFFFFC008000000
KIMG_PA = 0x40200000
PAGE_OFFSET = 0xFFFFFF8000000000
CDEV_MAP = 0xFFFFFFC008F7AB20
KTYPE = {0xFFFFFFC008EB39D0: "embedded", 0xFFFFFFC008EB3A00: "dynamic"}
HIDG_MAJOR = 237
CDEV_OFFSET_IN_HIDG = 0x378
DEV_OFFSET_IN_HIDG = 0x80

fd = os.open("/dev/mem", os.O_RDONLY)
memstart = 0x40000000


def pa(va):
    if va >= KIMG_VA:
        return va - KIMG_VA + KIMG_PA
    if va >= PAGE_OFFSET:
        return va - PAGE_OFFSET + memstart
    raise ValueError(hex(va))


def rd(va, n):
    return os.pread(fd, n, pa(va))


def q(va):
    return struct.unpack("<Q", rd(va, 8))[0]


def u32(va):
    return struct.unpack("<I", rd(va, 4))[0]


def cstr(va, n=24):
    return rd(va, n).split(b"\0")[0].decode(errors="replace") if va else "?"


def chain():
    kobj_map = q(CDEV_MAP)
    p = q(kobj_map + HIDG_MAJOR * 8)
    out = []
    while p and len(out) < 32:
        out.append((p, u32(p + 8), q(p + 0x10), q(p + 0x30)))
        p = q(p)
    return out


def pick_memstart():
    global memstart
    for ms in (0x40000000, 0x40200000):
        memstart = ms
        try:
            ch = chain()
        except Exception:
            continue
        if ch and any((d >> 20) == HIDG_MAJOR for _, d, _, _ in ch) and all(c == 0 or (d >> 20) % 255 == HIDG_MAJOR for _, d, _, c in ch):
            return ch
    sys.exit("cdev_map chain does not decode")


def holders(node):
    n = 0
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            for f in os.listdir("/proc/%s/fd" % pid):
                if os.readlink("/proc/%s/fd/%s" % (pid, f)).startswith(node):
                    n += 1
        except OSError:
            pass
    return n


def rows():
    out = []
    for dev, cdev in sorted((d, c) for _, d, _, c in chain() if (d >> 20) == HIDG_MAJOR):
        kref = u32(cdev + 0x38)
        ktype = KTYPE.get(q(cdev + 0x28), "?")
        parent = q(cdev + 0x18)
        name = cstr(q(parent)) if parent else "?"
        layout = "ok" if parent - DEV_OFFSET_IN_HIDG == cdev - CDEV_OFFSET_IN_HIDG else "layout?"
        node = "/dev/hidg%d" % (dev & 0xFFFFF)
        try:
            ino = os.stat(node).st_ino
        except OSError:
            ino = 0
        out.append((name, dev & 0xFFFFF, cdev, kref, ktype, layout, ino, holders(node)))
    return out


def main():
    ch = pick_memstart()
    mode = sys.argv[1] if len(sys.argv) > 1 else "snapshot"
    if mode == "chain":
        print("memstart %#x" % memstart)
        for p, d, r, c in ch:
            print("probe %x dev %d:%d range %d cdev %x" % (p, d >> 20, d & 0xFFFFF, r, c))
    elif mode == "watch":
        end = time.time() + float(sys.argv[2])
        last = None
        while time.time() < end:
            try:
                cur = [(r[0], r[2], r[3], r[6]) for r in rows()]
            except Exception as ex:
                cur = [("err", str(ex)[:40])]
            if cur != last:
                print("%.3f %s" % (time.time(), " | ".join("%s cdev=%x kref=%d ino=%d" % c if len(c) == 4 else str(c) for c in cur)), flush=True)
                last = cur
            time.sleep(0.02)
    else:
        print("memstart %#x" % memstart)
        print("name   minor cdev              kref ktype    layout ino  open-files  expected(1+files)")
        for name, minor, cdev, kref, ktype, layout, ino, files in rows():
            flag = "" if kref == 1 + files else "  <-- MISMATCH"
            print("%-6s %-5d %x %4d %-8s %-6s %-4d %-11d %d%s" % (name, minor, cdev, kref, ktype, layout, ino, files, 1 + files, flag))


if __name__ == "__main__":
    main()
