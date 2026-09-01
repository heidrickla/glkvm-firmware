# GL-RM1 — findings from published source

Established by reading GL.iNet's own GPLv3 source, not by touching the devices.
Source: https://github.com/gl-inet/glkvm @ `3e8dd23` (v1.10.0, 2026-08-11).
Local shallow clone: `<scratchpad>/glkvm` (7.2 MB).

Everything here is *source-derived*. Nothing below has been confirmed against
`.13`/`.14`/`.15` yet — see "Verify on .15" at the end.

## The headline: no decrypt/repack needed for kvmd changes

The stock software is a **GPLv3 fork of PiKVM's `kvmd`**, published in full.
`apply_to_glkvm.sh` in that repo pushes a locally-modified tree to the device:

```sh
REMOTE_HOST="glkvm.local"
REMOTE_DIR="/usr/lib/python3.12/site-packages/kvmd"
REMOTE_USER="root"
SSH_PORT=22
ssh root@glkvm.local "rm $REMOTE_DIR/* -R"    # <-- destructive, see warning
scp -r -P 22 kvmd/* root@glkvm.local:$REMOTE_DIR/
```

**Warning:** the script `rm -R`s the remote kvmd directory *before* copying. If
the scp then fails (network drop, full disk, wrong key), the device is left with
no kvmd. Back up `/usr/lib/python3.12/site-packages/kvmd` first, and edit the
script to use a staging dir + atomic swap before running it against anything but
`.15`.

Also note it targets `glkvm.local` by hostname — with three units on the LAN,
mDNS will resolve to whichever answers first. **Change `REMOTE_HOST` to an
explicit IP before every run.** This is the single easiest way to modify the
wrong device.

This retires the download → decrypt → repack → reflash track for anything
inside kvmd. Image-level work is only needed for what lives outside it: the
init scripts, the `gl-cloud`/`rtty` binaries, u-boot.

## Platform, as revealed by the source

| | |
| --- | --- |
| Init | buildroot-style `/etc/init.d/S<NN><name>`, not procd |
| But also | `ubus call gl-cloud unbind` — OpenWrt's ubus is present |
| Config | `/etc/glinet/*.conf` |
| SSH | dropbear 2025.89 on all three (measured) |
| Python | 3.12, kvmd in `site-packages` |
| Video SoC | Rockchip — `S99rkipc` is the Rockchip IPC media daemon |
| HDMI bridge | LT6911C or GSV1127X depending on board rev, over i2c-0/i2c-1 |
| WebRTC | `S99gl-pion` (pion = Go WebRTC stack) |
| Hardware info | `/proc/gl-hw-info/{model,device_mac,device_sn,device_ddns}` |

So: a GL.iNet hybrid — OpenWrt userspace pieces on a buildroot init. PLAN.md
open question 3 ("OpenWrt-derived or custom Linux?") is answered as "both, sort
of", which mainly means **don't assume `uci`/`opkg` work.**

## The cloud stack, fully enumerated

GL.iNet's cloud is internally called **astrowarp**. From
`kvmd/apps/kvmd/api/astrowarp.py`:

| Path | What it is |
| --- | --- |
| `/etc/init.d/S99gl-cloud` | the cloud daemon |
| `/etc/glinet/gl-cloud.conf` | its config, JSON, has an `enable` key |
| `/etc/init.d/S99rtty` | **rtty — GL.iNet's remote shell tunnel** |
| `/var/run/cloud/bindinfo` | bind state (`{"bindtime","email","username"}`) |
| `/var/run/cloud/bindlink` | pairing link |
| `/var/run/cloud/dynamic_code` | pairing code |

`GET /api/astrowarp/enable?enable=false` does exactly this:

1. sets `enable: false` in `/etc/glinet/gl-cloud.conf`
2. `S99gl-cloud stop`
3. `S99rtty stop`

**That is the whole de-cloud, and it is a supported UI toggle.** No firmware
work of any kind. `POST /api/astrowarp/unbind` additionally runs
`ubus call gl-cloud unbind` to drop the account binding.

`rtty` is worth calling out separately: it is a remote *shell* tunnel, not just
video relay. It only stops when the cloud is disabled. Confirm it is actually
down rather than trusting the toggle.

Other outbound paths that are NOT covered by that toggle:

- **OTA** — `kvmd/apps/kvmd/api/upgrade.py`:
  `https://fw.gl-inet.com/kvm/{model}/release` and `.../testing`
- **STUN** — `kvmd/apps/__init__.py:952`: default `stun.l.google.com`
  (`stun.gl-inet.cn` if the country code is CN)

Both need the gateway rule regardless. The egress deny in PLAN.md stays.

## Five built-in alternatives to the vendor cloud

Already shipped, each with its own API module and init script — no modification
required to use any of them:

| Service | Module | Init script |
| --- | --- | --- |
| Tailscale | `api/tailscale.py` | `S99tailscale` |
| NetBird | `api/netbird.py`, `netbird_daemon.py` | `S99netbird` |
| ZeroTier | `api/zerotier.py` | `S99zerotier` |
| Cloudflare Tunnel | `api/cloudflare.py` | `S99cloudflare` |
| GLKVM-Cloud (self-hosted) | — | https://github.com/gl-inet/glkvm-cloud |

GLKVM-Cloud is GL.iNet's own relay, self-hostable via Docker (x86_64 only),
per-device subdomains. That is "replace their cloud with your cloud" rather
than "no cloud" — the better fit if remote access off-LAN is actually wanted.

Also present: `S80ttyd` (web terminal, driven by `api/system.py`) — that is the
"Terminal → Access" button in the UI, and it is the path of least resistance to
a shell on `.15`.

## Alternative software stacks, assessed

- **Upstream PiKVM** — no. Assumes a Raspberry Pi; the RM1's video path is
  `rkipc` on Rockchip with an LT6911C/GSV1127X bridge. Nothing to port onto.
- **One-KVM** — supports OneCloud, OEC/OECT, Phicomm N1, VMs. No RV-class
  Rockchip, no RM1. Porting means rewriting exactly the video/HID glue GL.iNet
  already published under GPLv3.
- **Modified GLKVM** — the realistic option, and it is the vendor's own workflow.

If the goal is "different vendor" rather than "different software", that is a
hardware swap: JetKVM (~$103, Go, fully open), PiKVM V4 Mini (~$270, GPLv3,
IPMI/Redfish), Sipeed NanoKVM (~$70, check its security history), BliKVM v4.

## Verify on .15

In this order, all read-only except the last:

1. Web UI → Toolbox → Terminal → Access (gets a shell without touching SSH keys)
2. `cat /etc/glinet/gl-cloud.conf` — confirm the `enable` key exists as expected
3. `ls /etc/init.d/` — confirm the S99 names match the list above
4. `pgrep -a rtty; pgrep -a gl-cloud` — baseline what is running
5. `cat /proc/gl-hw-info/model` — settles which board rev, and which HDMI bridge
6. `diff` the on-device `site-packages/kvmd` against the v1.10.0 clone — tells
   you whether `.13`/`.14`/`.15` are on 1.10.0 and what, if anything, ships
   differently from the published tree
7. Then, and only then, toggle the cloud off and re-check 4

---

## OTA channel — queryable without a device, and it answers Stage 0

`api/upgrade.py` builds these from `model` (read from `/proc/gl-hw-info/model`,
value is `rm1`, lowercase — `RM1`/`gl-rm1` 404):

| URL | Content |
| --- | --- |
| `.../kvm/rm1/release/version` | plain-text version stanza |
| `.../kvm/rm1/release/update.img` | the release image |
| `.../kvm/rm1/testing/list-sha256.txt` | **beta index, with sha256 + size** |
| `.../kvm/rm1/testing/metadata_{version}` | per-version metadata |

`https://fw.gl-inet.com/kvm/rm1/release/version` returns:

```
RK_MODEL=RM1
RK_VERSION=V1.3.0 release1
RK_OTA_HOST=172.16.21.205:8080
```

Three things fall out of that:

1. **`RK_*` is Rockchip's OTA format.** Confirms the SoC family and tells us the
   image is a Rockchip `update.img` container — a known format with existing
   tooling (`rkdeveloptool`, `imgRePackerRK`), not a bespoke GL.iNet blob.
   That is a much better starting point than "unknown encrypted image".
2. **`RK_OTA_HOST=172.16.21.205:8080` is an RFC1918 address** — GL.iNet's
   internal build server, leaked into the public release channel. Harmless to
   us, unreachable, but it confirms the file is emitted by their build system
   rather than hand-written.
3. **The release channel is stale.** V1.3.0, `update.img` last modified
   2025-07-02. Beta is far ahead.

### Available images (from `testing/list-sha256.txt`)

| Version | File | Size | sha256 |
| --- | --- | --- | --- |
| 1.10.0 | `glkvm-RM1-1.10.0-0710-1783648193.img` | 189,694,488 (181 MB) | `8a46739a36b4c8bc6b8f195697fca725dd291ee88793e68cc9dfbc2c9a75ba49` |
| 1.7.0 | `glkvm-RM1-1.7.0-1107-1762486370.img` | 274,010,584 (261 MB) | `6857bfc86cd850269bc8f6db12ffd707312c7161705e72bcad0c24889cd3f9d3` |
| 1.3.0 | `release/update.img` | 232,298,968 (222 MB) | not published |

Trailing number is an epoch: 1.10.0 = 2026-07-10, 1.7.0 = 2025-11-07.
Firmware version tracks the kvmd version — the GitHub repo's HEAD is 1.10.0,
matching the newest beta image.

Note 1.10.0 is **72 MB smaller** than 1.7.0. Worth knowing before diffing them;
that is a packaging or content change, not noise.

**Published sha256s change Stage 0 for the better** — a downloaded image can be
verified against the vendor's own hash, so "is this dump good?" stops being a
question for the vendor images at least.

### Which build is on which unit — still open

The unauthenticated endpoints leak no version. All three units answer
byte-identically on `/api/init/is_inited` (`is_inited: true`, empty
`country_code`), `/api/redfish/v1`, and `/api/2fa/is_enabled` (2FA off
everywhere). `/api/info` is 401 as before, `/api/init/init` is Forbidden.

The only discriminator remains the web bundle hash, re-confirmed 2026-09-01:

| Units | Bundle |
| --- | --- |
| `.13`, `.14` | `index-SI23g4RB.js` |
| `.15` | `index-CddyYr6q.js` |

Reading the version from each UI (or the terminal) is still the way to settle
it. Downloading 1.7.0 and 1.10.0 and comparing their bundle hashes against the
two observed would settle it *without* logging in — that is the cheap
experiment if UI access is inconvenient.

### Minor security observation

`/api/redfish/v1` is served unauthenticated on all three. It only exposes the
service root, and `/redfish/v1/Systems` requires auth, so the exposure is
version-fingerprinting rather than control. Still, it is reachable from anything
that can see the LAN address, and it is the kind of thing to close if these
ever face a less-trusted network.

---

## GLKVM vs upstream PiKVM — what was actually changed

Compared `gl-inet/glkvm@3e8dd23` against `pikvm/kvmd@387846d` (2026-08-31).

**Fork point: kvmd `4.82`.** Upstream is now `4.213` — 131 releases ahead.
That drift, not deliberate removal, explains almost every gap.

### GL.iNet added a lot; they removed almost nothing

23 new API modules on top of upstream's 12:

```
ap  astrowarp  cloudflare  common  config_utils  custom_screen  fingerbot
init  modem  netbird  netbird_daemon  recorder  redfish  repeater  rndis
serial  system  tailscale  turn  twofa  upgrade  wol  zerotier
```

Several are lifted straight from GL.iNet's router stack (`ap`, `modem`,
`repeater`, `rndis`). Plugin-side additions: `atx/glatx.py` (their ATX board)
and `hid/otg/touch.py` (touchscreen HID).

Missing versus upstream — all of it plausibly post-4.82 upstream work rather
than anything GL.iNet stripped:

```
apps/nbd  apps/override  apps/_scheme.py  apps/_logging.py
plugins/auth/onetime.py  plugins/msd/otg/fs.py
plugins/ugpio/amt.py  plugins/ugpio/noop.py
```

**Conclusion: GLKVM is PiKVM 4.82 plus a large GL.iNet layer, not a cut-down
PiKVM.** The upstream backend is essentially all still there.

### Which means the interesting features are present but unexposed

Still in the shipped tree, almost certainly not surfaced by GL.iNet's Vue UI:

| Capability | Where |
| --- | --- |
| **VNC server** | `kvmd/apps/vnc/`, `/etc/kvmd/vncpasswd`, SSL under `/etc/kvmd/vnc/ssl/` |
| **IPMI server** (ipmitool-compatible) | `kvmd/apps/ipmi/`, `/etc/kvmd/ipmipasswd` |
| **LDAP / PAM / RADIUS auth** | `plugins/auth/{ldap,pam,radius}.py` |
| **~20 ugpio power/switch drivers** | `plugins/ugpio/` — tesmart, extron, ezcoo, hue, anelpwr, wol, ipmi… |
| **TOTP 2FA** | `plugins/…`, `/etc/kvmd/user/totp.secret` |

### The lever: `/etc/kvmd/override.yaml` survived

The PiKVM override mechanism is intact. `PKGBUILD:145,197` installs both
`/etc/kvmd/override.yaml` and `/etc/kvmd/override.d/`, and
`kvmd/apps/__init__.py:205` merges the `override` section after all other
configs and `!include`s, before validation. GL.iNet's own shipped
`override.yaml` still carries the upstream comment block pointing at
`docs.pikvm.org`, with a **VNC example** in it.

So the third alternative — alongside "modify kvmd" and "swap hardware" — is:

> **Keep the stock firmware entirely and just write `/etc/kvmd/override.yaml`.**

No code changes, no reflash, no `apply_to_glkvm.sh`, survives as a plain config
file. Standard PiKVM documentation applies, with the caveat that it describes
4.213 and these units run a 4.82 base — check each option exists in the local
tree before relying on it.

### One notable gap in what's published

`configs/kvmd/main/` contains **only upstream's Raspberry Pi platform files**
(`v0`–`v4plus` × `rpi2/3/4/zero2w`). There is no RM1 platform YAML in the repo.
The RM1's real `main.yaml` — the file that describes its actual HID, streamer
and ATX wiring — ships only inside the firmware image.

That is the strongest remaining reason to pull an image: not to modify it, but
to read one config file that was left out of the source release.

---

## The classic PiKVM UI: in the source, not on the device

The repo's `web/` is upstream PiKVM's classic interface, essentially unchanged —
identical top-level structure to `pikvm/kvmd@387846d` (`base.pug`, `index.pug`,
`kvm/`, `vnc/`, `ipmi/`, `login/`, `share/`).

nginx serves it from `root /usr/share/kvmd/web` at `location /`
(`configs/nginx/*.conf:15`). But on `.15`, every classic path 404s:

```
/            HTTP 200  len=1043    <- Vue SPA shell
/kvm/        HTTP 404
/vnc/        HTTP 404
/ipmi/       HTTP 404
/login/      HTTP 404
/share/      HTTP 404
```

So GL.iNet **replaced the contents of `/usr/share/kvmd/web` with their Vue
build** rather than mounting it elsewhere. The classic UI is published under
GPLv3 but is not installed.

Restoring it is therefore a build-and-deploy job, not a toggle: the `web/` tree
is pug templates needing a build step, and it would collide with the Vue app at
`location /`, so it wants its own nginx location. Feasible, not free.

Two consequences:

- The Vue frontend (`gl-kvm-frontend`) is **not** in the GPL release, so the
  observed bundle hashes (`index-SI23g4RB.js` / `index-CddyYr6q.js`) cannot be
  matched against source. Settling which build is on which unit still needs
  either the UI/terminal or a downloaded image.
- `/redfish` and `/streamer` have their own nginx locations
  (`:118`, `:127`) — consistent with the unauthenticated Redfish root observed
  on all three units.

---

## Artifacts now in the repo (2026-09-01)

```
firmware/    3 images, 665 MB, + SHA256SUMS + fetch.sh
vendor/      glkvm @3e8dd23 (1.10.0) and pikvm-kvmd @387846d (v4.213)
tools/       apply_to_glkvm_safe.sh, override.yaml.example
```

Both beta images verified against the vendor's own `list-sha256.txt` at
download time — `sha256sum -c` passes. The release-channel image publishes no
hash; its digest is recorded in `SHA256SUMS` so future pulls can be compared
against this copy.

**Stage 0 recovery is now satisfied**: three known-good, hash-verified vendor
images are held locally, covering 1.3.0, 1.7.0 and 1.10.0.

### Correction: VNC does not need memsink

An earlier note in `tools/override.yaml.example` claimed VNC might show no
video without `vnc.memsink.*.sink` values from the unpublished `main.yaml`.
That was wrong. `kvmd/apps/vnc/__init__.py:47-56`:

```python
streamers = list(filter(None, [
    make_memsink_streamer("h264", StreamerFormats.H264),   # None if sink == ""
    make_memsink_streamer("jpeg", StreamerFormats.JPEG),   # None if sink == ""
    HttpStreamerClient(name="JPEG", ..., **config.streamer._unpack()),
]))
```

The `HttpStreamerClient` is appended **unconditionally** and defaults to
`/run/kvmd/ustreamer.sock`. Memsink entries simply drop out of the list when
unset. So VNC works with no memsink config; memsink is an H.264/zero-copy
optimisation, not a prerequisite.

This removes the main reason to think enabling VNC by config alone would fail.
The remaining unknown is CAVEAT 1 — whether anything on a buildroot-init device
actually *starts* `kvmd-vnc`, since the repo ships systemd units the RM1 will
not use.

---

# Image opened. Most of PLAN.md's open questions are now closed.

Unpacked `glkvm-RM1-1.10.0-0710-1783648193.img` locally — no device access, no
decrypter, **no encryption at all**. It is a stock Rockchip `RKFW` container.

## Container structure

```
0x0000000  RKFW header (0x66 bytes)
0x0000066  BOOT / loader
0x00469b4  RKAF embedded update image   model=RM1 id=007 manufacturer=RV1126
0x008e9b4  PARM  partition table (plain text)
0x01d251b4 rootfs — squashfs v4.0, zstd, 13089 inodes, 128K blocks
```

`tools/rkfw_scan.py` reproduces this on any of the three images.

**The "two decrypters" problem in PLAN.md does not exist for this image.** There
was nothing to decrypt. Whatever the earlier attempt hit, it was not packaging
encryption on the vendor `update.img`.

## SoC confirmed: Rockchip RV1126

From the RKAF header and `PARM`: `MANUFACTURER: RV1126`, `MACHINE_MODEL: RM1`,
`FIRMWARE_VER: 8.1`, `TYPE: GPT`. Not a guess any more.

### Partition map

| Partition | Image | Flash off | Size |
| --- | --- | --- | --- |
| bootloader | `MiniLoaderAll.bin` | — | 288 KB |
| parameter | `parameter.txt` | 0x0 | 557 B |
| uboot | `uboot.img` | 0x4000 | 4 MB |
| misc | `misc.img` | 0x6000 | 48 KB |
| boot | `boot.img` | 0x8000 | 8.3 MB |
| recovery | `recovery.img` | 0x18000 | 16.3 MB |
| **rootfs** | `rootfs.img` | 0x38000 | **147 MB** |
| oem | `oem.img` | 0xb8000 | 6 MB |
| userdata | `userdata.img` | 0x118000 | 5 MB |

Offsets in `firmware/partitions-1.10.0.json`; extracted rootfs in
`extracted/rootfs-1.10.0.squashfs`, configs in `extracted/rootfs-1.10.0/`.

## PLAN.md open questions — answered

**3. OpenWrt-derived or custom Linux?** Neither, exactly: buildroot with
GL.iNet's OpenWrt pieces bolted on (`S81ubus`, `/etc/glinet/`). Busybox init.

**4. Is the root filesystem writable?** rootfs is read-only squashfs, **but
`/etc/init.d/S22overlayfs` exists** — there is a writable overlay. Live edits
are viable, which is what the plan hoped for. `S10atomic_commit.sh` and
`S99_bootcontrol` suggest atomic/A-B update handling, so verify how an overlay
change survives an OTA before relying on it.

## `/etc/kvmd/main.yaml` — the file that was not published

```yaml
override: !include [override.d, user/boot.yaml, override.yaml]
kvmd:
    hid:  {type: otg, mouse_alt: {device: /dev/hidg2}}
    atx:  {type: glatx}
    msd:  {type: otg}
    streamer:
        cmd: [/usr/bin/ustreamer, --device=/dev/video0, -r 1920x1080, ...]
vnc:
    memsink:
        jpeg:   {sink: "kvmd::ustreamer::jpeg"}
        h264:   {sink: "kvmd::ustreamer::h264"}
        rv1126: {sink: "kvmd::ustreamer::rv1126"}
```

Its own header: *"Don't touch this file otherwise your device may stop working.
Use override.yaml to modify required settings."*

Two things follow:

1. **The override route is confirmed live** — `override.yaml` is included by
   main.yaml, exactly as hoped.
2. **The VNC memsink caveat is dead.** The sinks are already wired, including an
   `rv1126` one. VNC gets hardware-encoded video with no configuration from us.

`/etc/glinet/gl-cloud.conf` ships as `{"enable": true, "log_level": "INFO"}` —
the cloud is on out of the box, and the toggle writes exactly this file.

## VNC and IPMI: present, but nothing starts them

On the device:

```
/usr/bin/kvmd-vnc      Python wrapper -> kvmd.apps.vnc:main
/usr/bin/kvmd-ipmi     Python wrapper -> kvmd.apps.ipmi:main
/usr/bin/ipmitool      the client, too
/etc/kvmd/vncpasswd    ships, comments only (so VNCAuth is inert)
/etc/kvmd/ipmipasswd   ships, comments only
```

But `/etc/init.d/` has **no `S99kvmd-vnc` and no `S99kvmd-ipmi`**. That is the
only thing standing between the stock firmware and a working VNC/IPMI server.

`tools/S99kvmd-vnc` and `tools/S99kvmd-ipmi` supply the missing scripts, in the
house style of `S98kvmd`, each gated on a flag file so a reboot cannot surprise
you with a new listener.

### Full `/etc/init.d/` inventory (1.10.0)

Cloud/remote: `S99gl-cloud` `S99rtty` `S99tailscale` `S99netbird` `S99zerotier`
`S99cloudflare` `S99gl-pion` `S99gl-route-monitor`
KVM core: `S98kvmd` `S98kvmd-media` `S99kvmd-janus` `S99kvmd-nginx`
`S50kvmd-otg` `S97kvmd-rndis` `S46kvmd-network`
Access: `S50dropbear` `S80ttyd` `S81ubus` `S79mdnsd` `S80mDNSResponder`
Also present: `S59snmpd`, `S22overlayfs`, `S10atomic_commit.sh`,
`S99_bootcontrol`, `S99_auto_reboot`, `S24glhwinfo`, `S23hdmi`.

`S59snmpd` is worth a look on its own — an SNMP daemon nobody mentions.

## Revised recommendation

For "alternative options", the answer is now concrete and needs no reflashing:

1. Drop `tools/override.yaml.example` at `/etc/kvmd/override.yaml`
2. Install `tools/S99kvmd-vnc` / `tools/S99kvmd-ipmi`, `touch` their gate files
3. Add credentials to `/etc/kvmd/vncpasswd` / `ipmipasswd`
4. Disable the cloud via the UI toggle, verify `rtty` is down, keep the egress rule

That yields VNC + IPMI + a de-clouded unit on stock firmware, all reversible,
with three hash-verified vendor images held locally if anything goes wrong.

---

# Correction, and the best finding of the lot

## I was wrong: both front ends ship, side by side

Earlier this file said GL.iNet "replaced the contents of `/usr/share/kvmd/web`
with their Vue build". **That is wrong.** The rootfs contains both:

```
/usr/share/kvmd/web      classic PiKVM UI  (base.pug, kvm/, vnc/, ipmi/, login/)
/usr/share/kvmd/glweb    GL.iNet Vue app   (assets/index-*.js)
```

and both nginx server contexts to serve them:

```
/etc/kvmd/nginx/kvmd.ctx-server.conf   root /usr/share/kvmd/web
/etc/kvmd/nginx/gl.ctx-server.conf     root /usr/share/kvmd/glweb
```

The classic paths 404 on the live device only because the active nginx config
does not include that context — not because the files are absent.

## The classic PiKVM UI is shipped, commented out, on port 8888

nginx runs as `nginx -p /etc/kvmd/nginx -c /etc/kvmd/nginx-kvmd.conf`
(`S99kvmd-nginx:58`). That file contains, verbatim:

```nginx
#        server {
#                listen 8888 ssl;
#                listen [::]:8888 ssl;
#                http2 on;
#                include /etc/kvmd/nginx/ssl.conf;
#                include /etc/kvmd/nginx/kvmd.ctx-server.conf;
#                include /usr/share/kvmd/extras/*/nginx.ctx-server.conf;
#                location /connect { return 301 /; }
#        }

        server {
                listen 443 ssl;
                ...
                include /etc/kvmd/nginx/gl.ctx-server.conf;
        }
```

GL.iNet left the entire classic-UI server block in place and simply commented
it out. **Uncommenting eight lines exposes the full PiKVM interface on 8888,
with the Vue app untouched on 443.**

That is the cleanest answer to "are there alternative options" in the whole
investigation: the alternative interface is already installed, already
configured, and disabled by a `#`.

`tools/enable_classic_ui.sh <ip>` does it — backs up the file first, edits with
awk (idempotent), runs `nginx -t`, restores the backup if validation fails, and
supports `--revert`.

Note the classic UI has its own `/vnc/` and `/ipmi/` pages, which pair with the
VNC/IPMI daemons that `tools/S99kvmd-{vnc,ipmi}` start.

## Which build is on which unit: still unresolved, now with evidence

Compared the `glweb` bundle names in all three vendor images against what the
units actually serve:

| Image | bundles |
| --- | --- |
| 1.3.0 | `index-B8Luf3Jz.js` `index-BSr0T-4M.js` `index-CZ82wUA8.js` |
| 1.7.0 | `index-BitRlry9.js` `index-COsSr8yH.js` `index-OsZ6zXfv.js` |
| 1.10.0 | `index-DoTFM32C.js` `index-eqq7oJ5H.js` `index-ufafOX6U.js` |
| **observed** | `index-SI23g4RB.js` (`.13`/`.14`), `index-CddyYr6q.js` (`.15`) |

**No match.** All three units run a build that is none of 1.3.0, 1.7.0 or
1.10.0 — i.e. something in the gaps (1.4–1.6, 1.8–1.9), which the testing
channel no longer lists. The vendor only publishes two betas at a time.

So this question cannot be closed from the vendor images. It needs the UI or a
shell — one `cat /etc/os-release` or the About page settles it.

Consequence worth noting: **both units are on firmware GL.iNet no longer
distributes.** The three local images are therefore not exact restore points
for the current state; they are recovery targets that would move the units to a
different version. Pull each unit's own `rootfs` via `dd` before modifying it if
byte-exact rollback matters.

---

## Verification of `enable_classic_ui.sh` (and a bug it caught)

The first draft of the script keyed block termination on
`/^#[[:space:]]*\}[[:space:]]*$/`. Tested against the real 1.10.0
`nginx-kvmd.conf`, that **terminated on the inner `location /connect {` closing
brace**, uncommenting lines 1–11 of the block but leaving the server block's own
`#        }` commented — an unclosed `server {`. `nginx -t` would have rejected
it and the script's own rollback would have fired, so it was fail-safe, but the
feature would simply not have worked.

Fixed to track **brace balance of the stripped text**. Verified end-to-end
against the exact copy embedded in the shipped script:

```
braces balanced : True (16/16)
8888 live       : True
443 still live  : True
second run      : no-op (idempotent)
```

Two supporting checks:

- **The classic UI is genuinely built**, not pug-only —
  `/usr/share/kvmd/web` holds 5 `.html` (root, `kvm/`, `ipmi/`, …), 35 `.js`,
  25 `.css`, 30 `.svg`, 5 `.png`, a `.webmanifest` and a favicon. The 24 `.pug`
  files are sources shipped alongside the built output. `index.html` opens with
  PiKVM's own header comment.
- **All 30 `include` directives** in `kvmd.ctx-server.conf` resolve to files
  that exist in the rootfs (`loc-login`, `loc-proxy`, `loc-websocket`,
  `loc-bigpost`, `loc-nobuffering`, `loc-nocache`, `loc-cors`).

So the block is safe to enable, and there is a working UI behind it.

### Still untested

Everything above is verified against the *extracted 1.10.0 image*. None of it
has been run against `.13`/`.14`/`.15`, which are on an unidentified build that
is **not** 1.3.0, 1.7.0 or 1.10.0. Their `nginx-kvmd.conf` may differ. The
script backs up, validates with `nginx -t`, and restores on failure, so a
mismatch should be non-destructive — but it is a real possibility, not a
theoretical one.

Also unverified: whether SSH key auth is set up for `root@` on these units. Every
script here uses `BatchMode=yes` (key only, never a password prompt).

---

## Hard blocker found: SSH key auth is not set up

Tested against `.15` and `.13`:

```
root@192.0.2.15: Permission denied (publickey,password).
root@192.0.2.13: Permission denied (publickey,password).
```

Password auth is offered, but every script in `tools/` uses
`ssh -o BatchMode=yes` (key only, never a password prompt), so **none of them
can run until a key is installed**.

### The device hands you a root shell anyway

`/etc/init.d/S80ttyd` runs `ttyd` on a unix socket, proxied by nginx at:

```
/extras/webterm/ttyd        ->  https://<unit-ip>/extras/webterm/ttyd
```

behind `loc-login.conf`, i.e. gated by the normal KVMD login. The ttyd command
line ends in `bash`, running as root. That is the same thing the UI's
Toolbox → Terminal → Access button opens.

So SSH is a convenience, not a prerequisite. `tools/webterm-snippets.md` holds
paste-ready blocks for that terminal, covering: baseline capture (which settles
the build question), enabling the classic UI, de-clouding, installing an SSH
key, and starting VNC/IPMI.

The awk in those snippets was extracted back out of the markdown and re-run
against the real 1.10.0 config — byte-identical output to the tested version in
`enable_classic_ui.sh`.

## Persistence caveat

`S22overlayfs` gives `/etc` a writable overlay over the read-only squashfs, so
edits survive reboots. But `S10atomic_commit.sh` and `S99_bootcontrol` point at
atomic/A-B update handling — **assume an OTA discards all of it** and plan to
re-apply after any firmware update. That, not the config edits themselves, is
the argument for eventually going the image-modification route.

---

# Stage 4 answered: signed since 1.10.0, with a supported bypass

PLAN.md's decisive question was *"Does the updater verify a signature, or only
decrypt? If it does not check a signature, a modified image installs."*

## Signing was introduced between 1.7.0 and 1.10.0

The `ED25` (Ed25519) marker in the RKFW header, at offset 41:

| Image | `ED25` at 0x29 |
| --- | --- |
| 1.3.0 | **absent** |
| 1.7.0 | **absent** |
| 1.10.0 | **present** (`45 44 32 35 01 00 00 00`) |

So GL.iNet added firmware signing in that window. Anything written assuming the
older unsigned images still applies to 1.3.0/1.7.0 but not to current builds.

## How it is checked

`POST /api/upgrade/start` (`api/upgrade.py:721+`) runs two independent gates
before flashing:

```python
signature_result = await self.__update_engine.verify_firmware_signature()
validation_result = await self.__update_engine.validate_firmware()
if not signature_valid or not firmware_valid:
    return ... "Upgrade failed"
```

- **`verify_firmware_signature()`** (`:1212`) shells out to
  `fwtools verify /userdata/update.img /etc/firmware/key/public.raw`
  — Ed25519 against an on-device public key. Returns `error` (not `invalid`)
  if either the image or the key file is missing.
- **`validate_firmware()`** (`:1281`) shells out to
  `check_image_validity /userdata/update.img` — a Rockchip structural/CRC
  check, **not** cryptographic.

## The bypass is a query parameter

`api/upgrade.py:729-743`:

```python
skip_verify = request.query.get("skip_verify")
should_skip_verify = str(skip_verify).lower() in ["true", "1"]
...
if should_skip_verify:
    get_logger(0).warning("Skipping firmware signature verification as requested")
else:
    signature_result = await self.__update_engine.verify_firmware_signature()
```

So:

```
POST /api/upgrade/start?skip_verify=true
```

skips the Ed25519 check entirely, logging a warning and nothing more. It is an
ordinary authenticated endpoint — admin credentials, no debug mode, no recovery
boot, no hardware access.

`validate_firmware()` still runs and is **not** skippable. But it is a structural
check, which a correctly repacked RKFW image satisfies by construction.

There is also a blanket exemption a few lines above: `if self.__model == "rmq1":
pass` skips both gates for that model. Not RM1, but it shows the checks are
treated as advisory rather than load-bearing.

## What this means for the project

**A modified image installs through the normal update path**, provided it is
repacked into a structurally valid RKFW container. The signing added in 1.10.0
does not close the modification route — the bypass ships in the same release.

That retires the last risk in PLAN.md's Stage 4. The remaining work for the
image route is purely mechanical: repack RKFW/RKAF with a correct partition
table and CRCs so `check_image_validity` passes.

Ranked against the alternatives, though, this is still the *last* resort:

| Route | Cost | Survives OTA |
| --- | --- | --- |
| `override.yaml` + init scripts | minutes, reversible | no — re-apply |
| nginx uncomment (classic UI) | seconds, reversible | no — re-apply |
| `apply_to_glkvm_safe.sh` (kvmd code) | minutes, reversible | no — re-apply |
| **repack + `skip_verify=true`** | hours | **yes** |

The image route is the only one that survives a firmware update, which is
exactly the argument `S10atomic_commit.sh` / `S99_bootcontrol` raised earlier.
Worth doing eventually; not worth doing first.

---

## Version diff: 1.7.0 → 1.10.0

| | 1.3.0 | 1.7.0 | 1.10.0 |
| --- | --- | --- | --- |
| files | 10,256 | 10,785 | 12,385 |
| uncompressed | 512 MB | 608 MB | 420 MB |
| image | 222 MB | 262 MB | 181 MB |

More files, much smaller image. The 72 MB image drop is **binary stripping**,
not feature removal — net −262 MB across files present in both:

```
-20.8 MB  /usr/lib/libpython3.12.so.1.0
-15.7 MB  /usr/lib/librkaiq.so
-15.4 MB  /lib/libc-2.28.so
-11.5 MB  /usr/sbin/cloudflared
-11.2 MB  /usr/bin/perf
-11.2 MB  /usr/bin/trace
-10.5 MB  /usr/lib/libstdc++.so.6.0.25
 -7.4 MB  /usr/lib/valgrind/memcheck-arm-linux
```

1.7.0 shipped unstripped libraries plus `perf`, `trace` and valgrind. 1.10.0
strips them — a hardening/cleanup pass, and a reminder that **older firmware is
the friendlier reversing target** if symbols ever matter.

Also removed in 1.10.0: the `FactoryTest-*` binaries (audioplay, ircut, key,
lan, mic, sdcard), `/etc/ssh/ssh_host_dsa_key{,.pub}`, `S50fcgiwrap`, `S51n4`.
Added: 1,518 files under `/usr/lib/python3.12`, and 3 new `/etc/kvmd/nginx`
configs — consistent with `gl.ctx-server.conf` arriving in this window.

### Independent confirmation of the signing timeline

```
1.3.0   /etc/firmware/key  ABSENT
1.7.0   /etc/firmware/key  ABSENT
1.10.0  /etc/firmware/key/public.raw
```

The Ed25519 public key that `fwtools verify` checks against appears in exactly
the release where the `ED25` header marker appears. Two independent signals,
same conclusion: **signing arrived in 1.10.0**, and `?skip_verify=true` arrived
with it.
