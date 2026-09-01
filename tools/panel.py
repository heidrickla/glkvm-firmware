#!/usr/bin/env python3
"""Draw to the GL-RM10's front panel, in GL.iNet's own visual language.

RUNS ON THE DEVICE. Push it with tools/panel.sh, or copy it anywhere and run
`python3 panel.py --out /tmp/preview.png` to render without touching the panel.

WHAT THE PANEL ACTUALLY IS
--------------------------
Not the SSD1306 i2c OLED that `kvmd-oled` expects -- that tool is wrong for
this hardware and `luma.core` is not even installed. The RM10 has a colour DSI
LCD on the Rockchip display controller:

    /dev/fb0    rockchipdrmfb, virtual_size 180x456, 32 bpp, stride 720
    /dev/dri/card0  connector DSI-1, mode 180x456

The framebuffer is PORTRAIT 180x456; the panel is mounted rotated, so the
picture the user sees is LANDSCAPE 456x180. We compose landscape and rotate 90
degrees counter-clockwise on the way out. Get that backwards and you get a
sideways, clipped mess that still "works", which is a slow thing to debug.

Pixel order is BGRA, not RGBA. Swapped, the blue UI turns orange.

WHO OWNS THE PANEL
------------------
/usr/sbin/gl_kvm_gui (started by /etc/init.d/S39gl-kvm-gui) holds /dev/fb0 and
/dev/dri/card0 and repaints on its own schedule. Anything we draw while it runs
gets painted over within seconds. Stop it first to take the panel over:

    /etc/init.d/S39gl-kvm-gui stop        # panel is ours
    /etc/init.d/S39gl-kvm-gui start       # give it back

ASSETS
------
GL.iNet's own, used in place from /etc/rm10-gui -- 6 fonts and 137 PNGs. We
deliberately do not copy them into the repo: they are GL.iNet artwork, and
reading them off the device we are drawing on avoids redistributing them.

    picture/home/internet_background.png   456x180 backdrop
    picture/home/{usb,km,hdmi_in,hdmi_out}_{connect,disconnect}.png   30x30
    picture/home/{eth_status,cloud_disable,wifi_status_4}.png         22x22
    fonts/IBMPlexSans-{Medium,Regular}.ttf

LAYOUT
------
Measured off a capture of their own home screen (read /dev/fb0, rotate, then
find luminance steps), so ours lines up with theirs:

    status row      y   8..26     22x22 icons, clock right-aligned
    headline        y  40..68     IBM Plex Sans Medium ~34px, white
    subtitle        y  82..93     IBM Plex Sans Regular ~13px, grey
    card row        y 104..166    4 cards, w=105, x = 8 + i*111
      icon                        30x30, centred, y+13
      label                       ~13px, centred, y+46
"""

import argparse
import http.client
import json
import os
import socket
import subprocess
import sys
import time

from PIL import Image, ImageDraw, ImageFont

KVMD_SOCK = "/run/kvmd/kvmd.sock"

GUI_ROOT = "/etc/rm10-gui"
PIC = os.path.join(GUI_ROOT, "picture")
FONTS = os.path.join(GUI_ROOT, "fonts")

FB = "/dev/fb0"
FB_SYS = "/sys/class/graphics/fb0"

# Landscape, as the user sees it. The framebuffer is the transpose of this.
W, H = 456, 180

CARD_Y, CARD_H, CARD_W, CARD_X0, CARD_DX = 104, 62, 105, 8, 111

# Measured against their own screen: card interiors sit only ~8 luminance above
# the backdrop, so the plate is a hint, not a panel.
CARD_ALPHA = 30

WHITE = (255, 255, 255)
GREY = (154, 163, 173)
ACCENT = (61, 132, 255)


# ---------------------------------------------------------------- assets ---

def font(name, size):
    return ImageFont.truetype(os.path.join(FONTS, name), size)


def pic(rel):
    """Load an asset, or None. Missing art must degrade, never crash the panel."""
    path = os.path.join(PIC, rel)
    try:
        return Image.open(path).convert("RGBA")
    except Exception:
        return None


def backdrop():
    im = pic("home/internet_background.png")
    if im is None:
        im = Image.new("RGBA", (W, H), (6, 10, 18, 255))
    return im.resize((W, H)) if im.size != (W, H) else im.copy()


# ------------------------------------------------------------------ data ---

class _UnixHTTP(http.client.HTTPConnection):
    """HTTPConnection over an AF_UNIX socket."""

    def __init__(self, path, timeout):
        super().__init__("localhost", timeout=timeout)
        self._unix_path = path

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self._unix_path)
        self.sock = s


def api(path, timeout=4):
    """kvmd over its own unix socket.

    Not over loopback HTTP: kvmd binds no TCP port at all (server.unix =
    /run/kvmd/kvmd.sock), and nginx on :80 answers 301 to https, so the obvious
    http://127.0.0.1/api/... returns a redirect rather than data. Going direct
    also skips TLS and the certificate question.

    Note nginx strips the /api prefix before proxying, so kvmd itself sees
    '/hid', not '/api/hid' -- pass paths without it.

    Returns None on any failure, including a 401 once auth is re-enabled;
    every caller degrades to a placeholder rather than crashing the panel.
    """
    try:
        conn = _UnixHTTP(KVMD_SOCK, timeout)
        try:
            conn.request("GET", path)
            body = conn.getresponse().read().decode()
        finally:
            conn.close()
        d = json.loads(body)
        return d.get("result") if d.get("ok") else None
    except Exception:
        return None


def primary_ip():
    try:
        out = subprocess.run(["ip", "-4", "-o", "addr", "show"],
                             capture_output=True, text=True, timeout=4).stdout
        for line in out.splitlines():
            parts = line.split()
            if len(parts) > 3 and parts[1] != "lo" and not parts[1].startswith("tailscale"):
                return parts[3].split("/")[0]
    except Exception:
        pass
    return "0.0.0.0"


def cpu_temp():
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            return int(f.read().strip()) / 1000.0
    except Exception:
        return None


def gather():
    """Everything the screens can show. One pass, so a slow API call cannot
    make different parts of one frame disagree with each other."""
    hid = api("/hid") or {}
    msd = api("/msd") or {}
    atx = api("/atx") or {}
    health = (api("/info?fields=health") or {}).get("health") or {}
    drive = msd.get("drive") or {}
    image = drive.get("image") or {}
    return {
        "ip": primary_ip(),
        "clock": time.strftime("%H:%M"),
        "hid_online": bool(hid.get("online")),
        "msd_online": bool(msd.get("online")),
        "msd_connected": bool(drive.get("connected")),
        "msd_image": image.get("name"),
        "atx_power": (atx.get("leds") or {}).get("power"),
        "temp": (health.get("temp") or {}).get("cpu") or cpu_temp(),
        "cpu": (health.get("cpu") or {}).get("percent"),
        "mem": (health.get("mem") or {}).get("percent"),
    }


# ----------------------------------------------------------------- paint ---

def centred(d, text, fnt, cx, y, fill):
    w = d.textbbox((0, 0), text, font=fnt)[2]
    d.text((cx - w / 2, y), text, font=fnt, fill=fill)


def card(base, d, i, icon, label, ok):
    x = CARD_X0 + i * CARD_DX
    # Their cards are a soft translucent plate, not a solid fill. The alpha has
    # to live in the MASK: Image.paste ignores the source's own alpha channel
    # when a mask is supplied, so pasting an alpha-20 white plate through a
    # solid mask paints opaque white and loses the planet behind it.
    plate = Image.new("RGBA", (CARD_W, CARD_H), (255, 255, 255, 255))
    mask = Image.new("L", (CARD_W, CARD_H), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, CARD_W - 1, CARD_H - 1],
                                           radius=10, fill=CARD_ALPHA)
    base.paste(plate, (x, CARD_Y), mask)

    if icon is not None:
        base.paste(icon, (x + (CARD_W - icon.width) // 2, CARD_Y + 13), icon)
    centred(d, label, font("IBMPlexSans-Regular.ttf", 13),
            x + CARD_W / 2, CARD_Y + 44, WHITE if ok else GREY)


def status_row(base, d, s):
    left = pic("home/eth_status.png")
    if left is not None:
        base.paste(left, (8, 6), left)
    cloud = pic("home/cloud_disable.png")
    fnt = font("IBMPlexSans-Medium.ttf", 15)
    tw = d.textbbox((0, 0), s["clock"], font=fnt)[2]
    d.text((W - 10 - tw, 7), s["clock"], font=fnt, fill=WHITE)
    if cloud is not None:
        base.paste(cloud, (W - 10 - tw - 26, 6), cloud)


def screen_home(s):
    """Their home screen, rebuilt from their assets."""
    base = backdrop()
    d = ImageDraw.Draw(base)
    status_row(base, d, s)

    centred(d, s["ip"], font("IBMPlexSans-Medium.ttf", 34), W / 2, 34, WHITE)
    centred(d, "Ethernet IP Address", font("IBMPlexSans-Regular.ttf", 13), W / 2, 80, GREY)

    def ic(stem, ok):
        return pic("home/%s_%s.png" % (stem, "connect" if ok else "disconnect"))

    km, usb = s["hid_online"], s["msd_online"]
    for i, (stem, label, ok) in enumerate([
        ("km", "K&M", km),
        ("hdmi_in", "HD-IN", True),
        ("hdmi_out", "HD-OUT", True),
        ("usb", "USB", usb),
    ]):
        card(base, d, i, ic(stem, ok), label, ok)
    return base


def screen_kvmd(s):
    """The same visual language, showing what GL.iNet's own screen does not:
    kvmd's view of the machine. This is the point of the exercise."""
    base = backdrop()
    d = ImageDraw.Draw(base)
    status_row(base, d, s)

    temp = "--" if s["temp"] is None else "%.1f°C" % s["temp"]
    centred(d, temp, font("IBMPlexSans-Medium.ttf", 34), W / 2, 34, WHITE)
    centred(d, "System Temperature", font("IBMPlexSans-Regular.ttf", 13), W / 2, 80, GREY)

    msd_label = "MEDIA" if s["msd_connected"] else "NO MEDIA"
    power = s["atx_power"]
    for i, (stem, label, ok) in enumerate([
        ("km", "CPU %s" % ("--" if s["cpu"] is None else "%d%%" % s["cpu"]), True),
        ("hdmi_in", "MEM %s" % ("--" if s["mem"] is None else "%d%%" % s["mem"]), True),
        ("usb", msd_label, s["msd_connected"]),
        ("hdmi_out", "PWR %s" % ("ON" if power else "OFF"), bool(power)),
    ]):
        icon = pic("home/%s_%s.png" % (stem, "connect" if ok else "disconnect"))
        card(base, d, i, icon, label, ok)
    return base


SCREENS = {"home": screen_home, "kvmd": screen_kvmd}


# -------------------------------------------------------------- fb output ---

def fb_geometry():
    try:
        with open(os.path.join(FB_SYS, "virtual_size")) as f:
            w, h = (int(v) for v in f.read().strip().split(","))
        with open(os.path.join(FB_SYS, "bits_per_pixel")) as f:
            bpp = int(f.read().strip())
        return w, h, bpp
    except Exception:
        return 180, 456, 32


def blit(img):
    fw, fh, bpp = fb_geometry()
    if bpp != 32:
        raise SystemExit("panel: expected 32 bpp, got %d" % bpp)
    # Landscape composition -> portrait framebuffer.
    out = img.convert("RGBA").rotate(90, expand=True)
    if out.size != (fw, fh):
        out = out.resize((fw, fh))
    with open(FB, "wb") as f:
        f.write(out.tobytes("raw", "BGRA"))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--screen", choices=sorted(SCREENS), default="home")
    ap.add_argument("--out", help="write a PNG instead of the panel (safe: does "
                                  "not touch /dev/fb0 or disturb gl_kvm_gui)")
    ap.add_argument("--interval", type=float, default=0.0,
                    help="redraw every N seconds instead of once")
    ap.add_argument("--rotate", type=int, default=90, choices=[0, 90, 180, 270],
                    help="override the landscape->framebuffer rotation")
    args = ap.parse_args()

    if not os.path.isdir(GUI_ROOT):
        raise SystemExit("panel: %s not found - is this an RM10?" % GUI_ROOT)

    while True:
        img = SCREENS[args.screen](gather())
        if args.out:
            img.save(args.out)
            print("wrote %s (%dx%d)" % (args.out, img.width, img.height))
        else:
            if args.rotate != 90:
                fw, fh, _ = fb_geometry()
                out = img.convert("RGBA").rotate(args.rotate, expand=True)
                if out.size != (fw, fh):
                    out = out.resize((fw, fh))
                with open(FB, "wb") as f:
                    f.write(out.tobytes("raw", "BGRA"))
            else:
                blit(img)
        if args.interval <= 0:
            return
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
