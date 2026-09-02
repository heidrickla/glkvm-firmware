# Feature ideas for the Comet KVMs

A running list of things we *could* add, compiled as we go. Anything below the
"Done" section is still just an idea — see [FINDINGS.md](FINDINGS.md) for the
measured detail on what has actually been built.

All work so far is on `.15`. `.13` and `.14` are untouched.

---

## Done

### ✅ Mass Storage Device (virtual CD/USB) — `msd`
**Working, with `tools/msd.sh` to drive it.** Needed no configuration —
`main.yaml` already carried `msd: {type: otg}`. Upload an ISO and the attached
machine sees a USB CD-ROM, so OS installs and rescue media no longer need
somebody to walk a stick over.

```
tools/msd.sh 192.0.2.15 mount ubuntu.iso
```

27 GB of exfat on its own partition, outside the overlay. Two gotchas, both
written up in [FINDINGS.md](FINDINGS.md): images under 614,400 bytes are
rejected by the kernel with an opaque HTTP 500, and the storage list lags a few
seconds behind disk. Booting a real installer on a real target is still
unproven — everything so far is device-side.

### ✅ Prometheus metrics — `api/export.py`
**Had never worked on a stock unit** (HTTP 500, `KeyError: 'fan'`). Fixed by a
patched module; `GET /api/export/prometheus/metrics` now returns 200 with ATX,
GPIO and hardware series. Drops straight into an existing Prometheus/Grafana
setup. Note it is unauthenticated *only* because auth is globally off.

### ✅ Hardware telemetry — `info/health.py`
CPU temperature, CPU load, memory and per-interface network rates. `health.pyc`
shipped in the image but was **never registered**, so it was collected by
nothing and invisible to both UIs. Now live in `/api/info?fields=health` and in
the Prometheus output. Also removed a Raspberry-Pi `vcgencmd` probe that had
been failing every 5 seconds forever.

### ✅ Wake-on-LAN
Works with no setup. `scan` (ARP sweep via `gl-arp-scan`) found 18 devices on
the LAN; `add` / `list` / `wake` / `remove` all clean, with `wol_list.json`
byte-identical before and after. `ether-wake` and `gl-arp-scan` both ship.
Free power-on for anything on the LAN, no ATX wiring. Note `wake` is **POST**
while `scan` and `list` are GET.

### ✅ MSD writable-stick mode — a drop box off an airgapped machine
`tools/msd.sh <ip> stick on|off`. Hands the whole 27 GB partition to the
attached machine as a **writable** USB drive via the gadget's second LUN, so
you can copy logs or a crash dump *off* a box with no network.

GL.iNet got this right: `partition_connect` **unmounts** `/userdata/media` on
the KVM first, so there are never two writers on one filesystem. The
consequence is that stick mode and ISO mode are mutually exclusive — while the
stick is attached, ISO storage is gone. `stick off` restores everything.

### ✅ The front panel — drawing on it, in their visual language
The RM10 has a **456×180 colour DSI LCD**, not the i2c OLED `kvmd-oled`
expects — that tool cannot drive this hardware (`luma.core` isn't installed and
an i2c scan finds no display). It is a framebuffer at `/dev/fb0`, so we can
draw anything.

`tools/panel.py` renders using **GL.iNet's own fonts and icons** from
`/etc/rm10-gui` (18 MB, 6 fonts, 137 PNGs), laid out to measurements taken from
a capture of their own home screen. `tools/panel.sh` drives it:

```
tools/panel.sh 192.0.2.15 preview kvmd   # PNG only - panel untouched
tools/panel.sh 192.0.2.15 show kvmd      # take the panel
tools/panel.sh 192.0.2.15 restore        # hand it back
```

Two screens: `home` reproduces theirs from live kvmd state; `kvmd` shows what
theirs cannot — CPU temperature as the headline, with CPU, memory, MSD media
state and ATX power in the cards. Verified by drawing to `/dev/fb0` and reading
the framebuffer back.

**Follow-ons:** a screen showing MSD image name while an ISO is mounted; an
alert screen on high temperature; cycling screens on the built-in button; and
`picture/` has 137 assets we have barely touched (wifi, net_info, keyboard,
welcome) if a richer UI is wanted.

### ✅ A repeatable way to change kvmd — `tools/apply-module.sh`
`patches/` mirrors the site-packages tree; the tool compiles on-device, keeps
the vendor `.pyc` as a one-time backup, and reverts cleanly. This is what makes
everything below tractable rather than a pile of one-off hacks.

---

## Already on the device, just switched off

These need configuration, not code.

### TOTP two-factor — proven, deliberately left OFF
Not a "someday" item any more: the full enrolment cycle was tested and works —
`create` → `init` → `show` (scannable `otpauth://`, issuer `GLKVM`) → `verify`
(correct code ok, wrong code Forbidden) → `delete`. **`pyotp` 2.10.0 and
`qrcode` 8.2 are already installed**, so nothing needs fetching. An earlier
note here claimed pyotp was missing; that was a bad probe on
`pyotp.__version__`, which the package does not define.

Left **disabled** on purpose — turning it on belongs with re-enabling auth, in
the security pass, not before it. See the enrolment handshake in FINDINGS: it
403s unless you send back a code derived from the secret `create` gave you.

### OCR and snapshots — blocked by a different video stack, not by tesseract
`/api/streamer/ocr` and `/api/streamer/snapshot` both **503**, and the missing
`libtesseract` is only the second problem. The first is architectural:
`/api/streamer` reports `"streamer": null` because **GL.iNet replaced ustreamer
with Janus/WebRTC** (`kvmd-janus`, `janusRestAPIServer.py`, `janus` with the
ustreamer Janus plugin). kvmd's snapshot and OCR paths expect a ustreamer
instance that simply is not running.

Grabbing a frame straight from V4L2 is not a shortcut either: `/dev/video0`
reports 0×0 with no format, and the rest of the 40 nodes are Rockchip CIF/ISP
pipeline stages in Bayer formats. HDMI-in is configured by GL.iNet's own
capture stack, so a frame grab means replicating their media-ctl/ISP setup —
and getting that wrong risks the video path the KVM exists to provide.

`ustreamer`, `ffmpeg` and `v4l2-ctl` are all on the device, so this is doable;
it is just a real piece of work rather than a switch to flip.

### MSD partition formatting — `/api/msd/partition_format`
The one partition verb not exercised. ⚠ It wipes the 27 GB media partition —
only worth touching deliberately, e.g. to switch the filesystem the attached
host sees from exfat to something else.

### Type text into the target — `/api/hid/print`
Paste a command, a licence key or a config blob into a machine with no network.
Already routed, and the path is live: the USB device controller reports
`state=configured, speed=high-speed` and the keyboard's LED state comes back
from the host, so **something real is plugged into `.15` right now**.

Deliberately **not** tested — it would type keystrokes into a machine we cannot
see. Needs Lewis to say what is attached and that it is safe to type at it.

### Fingerbot — `api/fingerbot.py`
`/api/fingerbot/click|battery|upgrade|upload`. A physical button-pusher for
machines with no ATX header at all. Only worth it if you own the hardware.

### SNMP — `S59snmpd` — probably not worth it now
NET-SNMP 5.9.3 and the `snmp` user both ship, but there is **no `snmpd.conf`
anywhere** on the device, so the daemon starts and immediately warns *"no
access control information configured… unlikely this agent can serve any
useful purpose"*, and `S59snmpd start` silently achieves nothing. It also binds
`127.0.0.1` only.

Making it useful means authoring a config and picking a community string.
Since the Prometheus endpoint now works and carries better data, this is only
worth doing if something in the estate speaks SNMP and nothing else.

### The classic UI's own extras
Live on `:8888`: macros, paste-to-target, keyboard shortcuts, health panel.
**But no picture on vendor firmware** — see the next item.

### Classic UI video, kvmd snapshots and kvmd's own OCR endpoint — shipped as the default
kvmd's streamer never runs on either vendor firmware (GL.iNet's manager starts
ustreamer only on its own `need_ustreamer` demand), so as the vendor ships it
`:8888` has controls and no video, and `/api/streamer/snapshot` is always 503.
`kvmd.streamer.forever: true` (inside the `kvmd:` block) fixes all three:
measured on 1.10.0 with HDMI in connected, kvmd's ustreamer runs at 2560×1440
and 60 fps, `:8888/streamer/snapshot` returns the desktop, janus attaches to
the h264 memsink, auth stays off, load is unchanged. **Default since
2026-09-01** — in `override.yaml.example` and the baked image. Measured with
a viewer in the Vue UI's default WebRTC mode: one shared ustreamer, load +0.3.
The UI's GL WebRTC ("adaptive") mode force-stops kvmd's streamer by design
(`server.py` masks the `forever` term while adaptive mode is on) and brings it
back 0.3 s after exit — watched live through every Mode the UI offers. Nothing
left to measure here.

---

## Needs a port — source exists, module is not on this device

The 1.10.0 source tree has these; firmware 1.8.1 does not ship them. Porting
means a provenance check first — see the version-drift warning in FINDINGS.

### Session recording — `api/recorder.py` (7 KB, subprocess)
Capture a session as evidence of what was done to a machine. Useful for
anything audited. *(Earlier drafts of this file claimed the module was already
on the device. It is not — it exists only in the 1.10.0 source.)*

### Serial console — `api/serial.py` (22 KB, **pure Python**)
The device has `/dev/ttyS2`. Combined with a UART to the host this is a real
out-of-band console — what IPMI's SOL was supposed to give us. It is the
largest pure-Python module in the fork, so the port is mechanical.

### Custom screen — `api/custom_screen.py` (14 KB, ubus)
Display arbitrary content on the device. Entangled with ubus.

### From upstream PiKVM 4.213 (we are on 4.82)
`info/uptime.py`, `info/node.py`, `auth/onetime.py` (one-time login links),
`ugpio/amt.py` (Intel AMT power control), `ugpio/noop.py`.

---

## Small builds on top of what we have

### EDID spoofing
`kvmd-edidconf` ships and `/etc/kvmd/switch-edid.hex` exists, but there is **no
`/etc/kvmd/edid.json`** — an earlier draft of this file claimed otherwise and
was wrong. EDID is managed through `/api/switch/edids/create|change|remove`,
and `/api/switch` currently 404s (no switch hardware). Worth it to force a
resolution, or make a headless server believe a display is attached.

### Power control from real hardware — `ugpio`
~20 drivers ship: `tesmart`, `extron`, `ezcoo`, `hue`, `anelpwr`, `wol`,
`ipmi`, `cmd`, `cmdret`, `pway`, `xh_hk4401`, `servo`, `pwm`. We proved the
mechanism with a `cmd` driver. Wire a real smart plug or KVM switch and the
buttons appear in both UIs.

### Redfish automation
Works today. Slots into Ansible (`community.general.redfish_command`), Zabbix,
or a Home Assistant switch — power control for the attached host next to
everything else in the house.

### Grafana dashboard
Now that Prometheus works, three units on one board is a short job.

---

## Bigger, but the groundwork is done

### ✅ Close the source/firmware gap — done, with a caveat
`.15` now runs the provisioned 1.10.0, the base whose source we hold, with
`recorder`, `serial`, `custom_screen` and `netbird` present. The caveat stands:
1.10.0's bytecode is still not byte-identical to the published source
(`health.pyc` 7245 B on the image vs 7190 B compiled), so the provenance check
before any port stays — and `tools/firmware-diff.py` now makes the comparison
against a *previous firmware* a one-command job for the next release.

### ✅ Bake provisioning into firmware — built, verified, **and flashed onto `.15`**
`tools/bake-image.sh` produces `firmware/glkvm-RM10-1.10.0-provisioned.img`:
the vendor 1.10.0 rootfs with the classic UI, `override.yaml`, VNC autostart,
the `export.py` patch, tesseract, our SSH key and our signing key inside, plus
the `.orig` files the revert tools expect. `tools/flash.sh` put it on `.15`
(2026-09-01): back in ~30 s, SSH straight back on the baked key, everything up.

What the flash then taught (all in FINDINGS, found by **diffing the two
firmwares** rather than chasing symptoms): 1.10.0 leaves the MSD gadget
functions unlinked at boot (`otg.devices.msd.start_cdrom/start_flash` now in
the override), ships a broken MSD remount default (override pins `remount,rw`),
registers `health` itself (so `patches/MANIFEST` scopes two patches to 1.8.1),
and its ustreamer will not capture without a live HDMI signal.

The build walked into the RM1-rootfs trap once; two independent
product-identity gates now stop it.

### ✅ OCR — tesseract on the unit, `tools/ocr.sh`
GL.iNet's 1.10.0 OCR is wired for an NPU `ocr_service` that ships in **no**
firmware, so tesseract is the real path: Ubuntu noble's arm64 packages load
as-is on the unit's glibc 2.41 (closure resolved from the package index by
`ocr-fetch.py`, 23 packages, only missing sonames installed). Proven by
reading "GLKVM 12345" off a device-rendered image, and the bridge's own
"NO LIVE VIDEO" splash off a captured frame. `ocr.sh read` takes its frame
from kvmd's permanently running streamer (`/run/kvmd/ustreamer.sock`, under a
second) and only spins up a transient ustreamer on `/dev/video0` when that
socket is absent — on 1.10.0 either path needs the attached host to actually
be outputting video. With HDMI in connected it read the desktop's app text;
`--crop L,T,R,B` keeps the read to one window. Baked into the image.

The classic UI's Text → OCR button works too, after a second one-line
vendor fix: 1.10.0 answered `?ocr=1` as JSON while the (upstream) UI copies
the body to the clipboard verbatim; `patches/kvmd/apps/kvmd/api/streamer.py`
restores upstream's `text/plain`. Small text (a browser address bar) still
misreads. Measured on the unit with synthetic ~11 px text, dark and light
backgrounds: the vendor pipeline (2× bicubic, grayscale call discarded),
grayscale assigned, 3× upscale, `ocr.sh`'s autocontrast + threshold, and an
adaptive upscale all score the same (similarity 0.98–0.99, one of three
lines exact). Tesseract grayscales internally; preprocessing is not the
lever. Closed — bigger source text or a different engine would be.

kvmd's **own** OCR endpoint (`/api/streamer/snapshot?ocr=1`) was broken on
1.10.0 by a vendor bug — a dropped `@contextlib.contextmanager` — fixed by
`patches/kvmd/apps/kvmd/ocr.py` (1.10.x only, manifest-scoped, baked): 200
with the screen's text, given a running streamer.

### ✅ HID — proven end to end, type and read back
After a gadget rebuild the host had stopped polling the HID endpoints while
kvmd kept accepting events with 200s; `kvmd-otgconf --reset-gadget` fixed it,
and kvmd's `online` flag only updates on the next successful write. Keyboard
and both mouse outputs deliver. The loop is closed: Win+R over the KVM
keyboard, a marker typed with `POST /api/hid/print` (text in the request
BODY), and kvmd's OCR restricted to the Run box read it back exactly, on a
host set to duplicate displays. `ocr.sh read --crop L,T,R,B` does the same
from the workstation, from kvmd's own streamer frames.

### ✅ Firmware diff — `tools/firmware-diff.py`
Compares two kvmd trees at the bytecode level and names what changed in each
module (constants, names, functions that appeared or vanished), plus
`/etc/kvmd`. Credential files are redacted by name — the first run was not,
and cost a rotation. Report for 1.8.1 → 1.10.0 in `docs/`.

### Rewrite the vendor glue
Surveyed in FINDINGS. 13 of the 36 GL.iNet-only files are pure Python; the KVM
function we actually depend on is `glatx.py` (6.5 KB), `streamer.py` (26 KB),
and `hid/otg` + `msd/otg` (both largely upstream). The 116 KB `api/system.py`
is network and device administration, not KVM.

### Fleet provisioning and drift detection
`provision.sh` now reproduces `.15` completely — classic UI, override.yaml, VNC
and all three patched modules — and is verified idempotent and reboot-proof, so
extending it to a loop over an inventory is the only work left for fleet
rollout. It also refuses to overwrite an `override.yaml` carrying settings the
repo lacks, which is what stops a "no-op" re-run from silently regressing a
unit.

Drift detection is still open: checkpoints plus a `pip freeze` give a
known-good baseline to diff against, worth having since `updateEngine` runs
with `--n` (format overlay) and will revert everything on OTA.

### Central relay
`glkvm-relay` is up at 192.0.2.140. No devices onboarded yet.

---

## Security hardening (deferred until the build settles)

Listed here so it is not forgotten — Lewis: *"we will tighten security when we
are done."*

- **Re-enable auth.** `kvmd.auth.enabled: false` currently means the API, both
  UIs, Redfish and now the Prometheus endpoint need **no credentials** on the
  LAN. The credential is vaulted and in sync, so this is a one-line revert.
- **Close unauthenticated Redfish.** Anyone on the LAN can power-cycle the
  attached machine today.
- **Delete the default IPMI entry** (`admin:admin`) — it authenticates on a
  stock unit.
- **Trim the tunnels.** Tailscale, NetBird, ZeroTier and Cloudflare are all
  running; each is outbound. Pick one.
- **Egress deny at the gateway** — OTA (`fw.gl-inet.com`) and STUN
  (`stun.l.google.com`) are not covered by the de-cloud toggle.
- **Rotate the signing key** if the build VM is ever shared.
