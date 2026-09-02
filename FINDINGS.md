# GL-RM10 (Comet Pro) — what the units are, and how to change them

Three units: `192.0.2.13`, `.14`, `.15`. Goal: de-cloud, and be able to modify
the software.

> **⚠ PRODUCT CORRECTION (2026-09-01).** These units are **GL-RM10 (Comet
> Pro)**, not GL-RM1. Confirmed on `.15` by `/proc/gl-hw-info/model` = `rm10`
> and `/etc/os-release` = `rm10rc-1.8.1-release1-6-gfa876ddece`; the user
> confirms all three are the same model. Most of this document was derived from
> **RM1** firmware images before shell access existed. The structural findings
> (Routes 1-4, the override mechanism, the cloud stack) were re-verified on the
> live RM10 and hold. The hardware specifics did not — see "Corrections".
>
> **The three firmware images under `firmware/` are RM1. Do not flash them
> here.**

Established from GL.iNet's published GPLv3 source, from firmware images
unpacked locally, and — since 2026-09-01 — from a root shell on `.15`.

Claims are marked:

- **[measured]** — observed directly against a unit or a local image
- **[source]** — read out of published code, with file:line
- **[untested]** — follows from the above but has not been run

---

## Bottom line

The stock software is a GPLv3 fork of PiKVM's `kvmd`. Three things follow, in
the order worth doing them:

1. **The classic PiKVM web UI is already installed on the devices and disabled
   by a comment** in the nginx config. Uncommenting one server block exposes it
   on port 8888, leaving GL.iNet's UI untouched on 443.
2. **VNC and IPMI daemons ship too**, fully wired, missing only an init script.
3. **De-clouding is a supported toggle** — no firmware work at all.

Firmware modification remains possible (signing was added in 1.10.0 but ships
with a bypass), and it is the only route that survives an OTA — but it is the
last resort, not the first.

---

## The platform

| | | |
| --- | --- | --- |
| Product | **GL-RM10 (Comet Pro)** | [measured] `/proc/gl-hw-info/model` = `rm10` |
| SoC | **Rockchip RV1126B+, aarch64** | [measured] `RK_BUILD_INFO=rockchip_rv1126bp_gl_rm10`; `uname -m` = aarch64 |
| Firmware | `rm10rc-1.8.1-release1-6-gfa876ddece` | [measured] `/etc/os-release` |
| Kernel | Linux 6.1.141 SMP | [measured] `uname -a` |
| kvmd | **4.82** | [measured] on-device — confirms the fork-point finding |
| Init | buildroot `/etc/init.d/S<NN><name>` | [measured] from the unpacked rootfs |
| …but also | OpenWrt's `ubus`, `/etc/glinet/` | [source] `ubus call gl-cloud unbind` |
| SSH | dropbear 2025.89, port 22 | [measured] banner on all three |
| Python | 3.12, kvmd in `site-packages` | [source] `apply_to_glkvm.sh` |
| rootfs | squashfs `/rom` ro + overlay rw | [measured] `overlay:/overlay on / ... upperdir=/userdata/overlay/upper` |
| Capture bridge | **GSV1127X** | [source] `upgrade.py:876` maps `rm10rc` → GSV1127X |
| HDMI loop-out | LT86102SXE splitter | [source] `main.yaml` pre/post-start cmds |
| Streamer | `ustreamer` on `/dev/video0` | [source] `main.yaml` |

Not OpenWrt, not plain buildroot — a GL.iNet hybrid. **Do not assume `uci` or
`opkg` work.**

On the capture bridge: `upgrade.py:876-881` maps `rm10rc`/`rm4pe` → GSV1127X,
`rmq1` → GSV1127, and defaults to LT6911C. The device reports itself as
`rm10rc`, so **these units take the GSV1127X path** — not the LT6911C that an
RM1 would use.

### Partition map [source]

From the `PARM` block of the 1.10.0 image:

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

Also from `PARM`: `FIRMWARE_VER: 8.1`, `TYPE: GPT`.

---

## Route 1 — the classic PiKVM UI (start here)

**Both front ends ship on the device** [measured]:

```
/usr/share/kvmd/web      classic PiKVM UI   — index.html, kvm/, vnc/, ipmi/, login/
/usr/share/kvmd/glweb    GL.iNet's Vue app  — assets/index-*.js
```

and both nginx server contexts to serve them [measured]:

```
/etc/kvmd/nginx/kvmd.ctx-server.conf   root /usr/share/kvmd/web
/etc/kvmd/nginx/gl.ctx-server.conf     root /usr/share/kvmd/glweb
```

The classic paths 404 on a live unit [measured] — but **not** because the files
are missing. nginx runs `-c /etc/kvmd/nginx-kvmd.conf` (`S99kvmd-nginx:58`),
which serves `gl.ctx-server.conf` on 443 and carries this, commented out:

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
```

Uncommenting it puts the full classic UI on 8888 with the Vue app untouched
on 443.

The UI is **genuinely built**, not source-only [measured]: `/usr/share/kvmd/web`
holds 5 `.html`, 35 `.js`, 25 `.css`, 30 `.svg`, 5 `.png`, a `.webmanifest` and
a favicon; `index.html` opens with PiKVM's own header. The 24 `.pug` files are
sources shipped alongside the built output. All 30 `include` directives in
`kvmd.ctx-server.conf` resolve to files present in the rootfs [measured].

`tools/enable_classic_ui.sh <ip>` does it: backs up, edits with awk, runs
`nginx -t`, restores the backup on failure, `--revert` to undo. The awk was
tested against the real 1.10.0 config — braces balance 16/16, 8888 live, 443
untouched, second run a no-op. **[untested] against the units**, which run a
different build.

---

## Route 2 — VNC and IPMI by config

Present on the device, unexposed [measured]:

```
/usr/bin/kvmd-vnc      Python wrapper -> kvmd.apps.vnc:main
/usr/bin/kvmd-ipmi     Python wrapper -> kvmd.apps.ipmi:main
/usr/bin/ipmitool      the client too
/etc/kvmd/vncpasswd    ships, comments only (so VNCAuth is inert)
/etc/kvmd/ipmipasswd   ships, comments only
```

**The only thing missing is an init script** — `/etc/init.d/` contains no
`S99kvmd-vnc` and no `S99kvmd-ipmi` [measured]. `tools/S99kvmd-vnc` and
`tools/S99kvmd-ipmi` supply them in the house style of `S98kvmd`, each gated on
`/etc/kvmd/user/{vnc,ipmi}.enable` so a reboot cannot surprise you.

The override mechanism is live. `/etc/kvmd/main.yaml` opens with [measured]:

```yaml
override: !include [override.d, user/boot.yaml, override.yaml]
```

and its own header says *"Don't touch this file otherwise your device may stop
working. Use override.yaml to modify required settings."* `PKGBUILD:145,197`
installs both `override.yaml` and `override.d/`; the merge happens at
`kvmd/apps/__init__.py:205`, after all other configs and `!include`s.

**VNC needs no memsink configuration from you** — `main.yaml` already sets
them [measured]:

```yaml
vnc:
    memsink:
        jpeg:   {sink: "kvmd::ustreamer::jpeg"}
        h264:   {sink: "kvmd::ustreamer::h264"}
        rv1126: {sink: "kvmd::ustreamer::rv1126"}
```

So VNC gets hardware-encoded video out of the box. Independently,
`kvmd/apps/vnc/__init__.py:47-56` appends an `HttpStreamerClient`
unconditionally, so it would still get JPEG over `/run/kvmd/ustreamer.sock`
even with no memsink at all.

`tools/override.yaml.example` is a starter using only options verified present
in this 4.82-era tree.

**On IPMI:** the device's own `/etc/kvmd/ipmipasswd` warns that the protocol is
unsafe by design — the server sends a hash of the requested user's password to
the client *before* the client authenticates. Enable only on a trusted network,
never with a reused password.

### What else is in there but unexposed

GLKVM forked PiKVM `kvmd` at **4.82**; upstream is now **4.213** [source].
GL.iNet **added** 23 API modules and removed essentially nothing — the gaps
(`apps/nbd`, `apps/override`, `auth/onetime.py`, `ugpio/amt.py`,
`msd/otg/fs.py`) are all post-4.82 upstream work. So also present:

| Capability | Where |
| --- | --- |
| LDAP / PAM / RADIUS auth | `plugins/auth/{ldap,pam,radius}.py` |
| ~20 power/switch drivers | `plugins/ugpio/` — tesmart, extron, ezcoo, hue, anelpwr, wol, ipmi… |
| TOTP 2FA | `/etc/kvmd/user/totp.secret` |

GL.iNet's own additions include `ap`, `modem`, `repeater`, `rndis` (lifted from
their router stack), plus `astrowarp`, `recorder`, `custom_screen`, `twofa`,
`upgrade`, and clients for Tailscale / NetBird / ZeroTier / Cloudflare.

---

## Route 3 — modify kvmd itself

GL.iNet publishes the daemon at <https://github.com/gl-inet/glkvm> (GPLv3), with
`apply_to_glkvm.sh` to push a modified tree [source]:

```sh
REMOTE_HOST="glkvm.local"
REMOTE_DIR="/usr/lib/python3.12/site-packages/kvmd"
ssh root@glkvm.local "rm $REMOTE_DIR/* -R"     # destructive, runs BEFORE the copy
scp -r -P 22 kvmd/* root@glkvm.local:$REMOTE_DIR/
```

Two hazards:

- It `rm -R`s the remote directory **before** copying. A failed scp leaves the
  device with no kvmd.
- It targets `glkvm.local` **by hostname**. With three units on one LAN, mDNS
  resolves to whichever answers first.

`tools/apply_to_glkvm_safe.sh` replaces it: refuses anything but a bare IPv4
literal, backs the remote tree up and pulls the archive locally, stages the
upload, and only then swaps — with rollback. **[untested] against the units.**

---

## Route 4 — modify the firmware image

**The vendor image is not encrypted** [measured]. It is a stock Rockchip `RKFW`
container, opened locally with plain parsing and no keys:

```
0x0000000  RKFW header (0x66 bytes)
0x0000066  BOOT / loader
0x00469b4  RKAF   model=RM1 id=007 manufacturer=RV1126
0x008e9b4  PARM   partition table (plain text)
0x01d251b4 rootfs — squashfs v4.0, zstd, 13089 inodes, 128K blocks
```

`tools/rkfw_scan.py` reproduces this on any of the three images.

PLAN.md's "two decrypters, the second one works" does not apply to the vendor
`update.img`. Whatever that earlier attempt hit, it was not packaging encryption
on this file.

### Signing: added in 1.10.0, with a bypass in the same release

| Image | `ED25` in RKFW header | `/etc/firmware/key/public.raw` |
| --- | --- | --- |
| 1.3.0 | absent | absent |
| 1.7.0 | absent | absent |
| 1.10.0 | **present** (offset 0x29) | **present** |

Two independent signals, same conclusion [measured].

`POST /api/upgrade/start` runs two gates [source, `api/upgrade.py:721+`]:

1. `verify_firmware_signature()` (`:1212`) → `fwtools verify /userdata/update.img
   /etc/firmware/key/public.raw` — Ed25519 against an on-device public key
2. `validate_firmware()` (`:1281`) → `check_image_validity <img>` — a Rockchip
   structural/CRC check, **not** cryptographic

And the bypass, `api/upgrade.py:729-743`:

```python
skip_verify = request.query.get("skip_verify")
should_skip_verify = str(skip_verify).lower() in ["true", "1"]
...
if should_skip_verify:
    get_logger(0).warning("Skipping firmware signature verification as requested")
```

So `POST /api/upgrade/start?skip_verify=true` skips gate 1 entirely, logging a
warning. Ordinary authenticated endpoint — no debug mode, recovery boot, or
hardware access. Gate 2 still runs and is not skippable, but a correctly
repacked RKFW image satisfies it by construction. (`if self.__model == "rmq1":
pass` skips both gates for that model — not RM1.)

**A modified image installs by the normal path.** Signing did not close this.

---

## De-clouding

GL.iNet's cloud is internally **astrowarp** [source, `api/astrowarp.py`]:

| Path | What it is |
| --- | --- |
| `/etc/init.d/S99gl-cloud` | the cloud daemon |
| `/etc/glinet/gl-cloud.conf` | JSON, `enable` key — ships as `{"enable": true, "log_level": "INFO"}` [measured] |
| `/etc/init.d/S99rtty` | **rtty — a remote *shell* tunnel** |
| `/var/run/cloud/{bindinfo,bindlink,dynamic_code}` | pairing state |

`GET /api/astrowarp/enable?enable=false` sets `enable: false`, then stops
`S99gl-cloud` and `S99rtty`. `POST /api/astrowarp/unbind` runs
`ubus call gl-cloud unbind`.

**That is the whole de-cloud, and it is a supported UI toggle.** Verify `rtty`
is actually down (`pgrep -a rtty`) rather than trusting it.

Not covered by that toggle, so **keep the gateway egress rule**:

- OTA — `https://fw.gl-inet.com/kvm/{model}/release` and `/testing`
  (`api/upgrade.py:38-39`)
- STUN — default `stun.l.google.com` (`apps/__init__.py:952`; `stun.gl-inet.cn`
  if the country code is CN)

### Built-in alternatives to the vendor cloud

Each already shipped, with its own API module and init script:

| Service | Module | Init script |
| --- | --- | --- |
| Tailscale | `api/tailscale.py` | `S99tailscale` |
| NetBird | `api/netbird.py` | `S99netbird` |
| ZeroTier | `api/zerotier.py` | `S99zerotier` |
| Cloudflare Tunnel | `api/cloudflare.py` | `S99cloudflare` |
| GLKVM-Cloud (self-hosted) | — | <https://github.com/gl-inet/glkvm-cloud> (Docker, x86_64) |

---

## Getting a shell

**SSH key auth is not configured** [measured] — `.15` and `.13` both answer
`Permission denied (publickey,password)`. Every script in `tools/` uses
`ssh -o BatchMode=yes`, so none can run until a key is installed.

No SSH is needed to get root. `S80ttyd` runs ttyd on a unix socket, proxied by
nginx at `/extras/webterm/ttyd` behind the normal KVMD login, with `bash` as
root — the same thing the UI's Toolbox → Terminal → Access button opens:

```
https://<unit-ip>/extras/webterm/ttyd
```

`tools/webterm-snippets.md` has paste-ready blocks for it, ordered least to most
invasive, including installing an SSH key (which unblocks everything in `tools/`).

### `/etc/init.d/` inventory (1.10.0) [measured]

Cloud/remote: `S99gl-cloud` `S99rtty` `S99tailscale` `S99netbird` `S99zerotier`
`S99cloudflare` `S99gl-pion` `S99gl-route-monitor`

KVM core: `S98kvmd` `S98kvmd-media` `S99kvmd-janus` `S99kvmd-nginx`
`S50kvmd-otg` `S97kvmd-rndis` `S46kvmd-network`

Access: `S50dropbear` `S80ttyd` `S81ubus` `S79mdnsd` `S80mDNSResponder`

Also: `S59snmpd`, `S22overlayfs`, `S10atomic_commit.sh`, `S99_bootcontrol`,
`S99_auto_reboot`, `S24glhwinfo`, `S23hdmi`.

`S59snmpd` — an SNMP daemon nobody mentions — is worth a look on its own.

---

## Firmware images held locally

| Version | File | Size | sha256 |
| --- | --- | --- | --- |
| 1.10.0 | `glkvm-RM1-1.10.0-0710-1783648193.img` | 181 MB | `8a46739a…ba49` **verified** |
| 1.7.0 | `glkvm-RM1-1.7.0-1107-1762486370.img` | 262 MB | `6857bfc8…f9d3` **verified** |
| 1.3.0 | `glkvm-RM1-1.3.0-release-update.img` | 222 MB | `32df0ec4…0d84` (no vendor hash published) |

The two beta hashes were checked against the vendor's own
`testing/list-sha256.txt` at download time; `sha256sum -c` passes. The trailing
number in each filename is an epoch: 1.10.0 = 2026-07-10, 1.7.0 = 2025-11-07.

The OTA channel is queryable without a device:

```
.../kvm/rm1/release/version          plain-text version stanza
.../kvm/rm1/release/update.img       the release image
.../kvm/rm1/testing/list-sha256.txt  beta index, with sha256 + size
```

`release/version` returns `RK_MODEL=RM1 / RK_VERSION=V1.3.0 release1 /
RK_OTA_HOST=172.16.21.205:8080` — that last being GL.iNet's internal build
server leaked into a public file. The release channel is stale (`update.img`
last modified 2025-07-02); only two betas are listed at a time.

### Version diff, 1.7.0 → 1.10.0

| | 1.3.0 | 1.7.0 | 1.10.0 |
| --- | --- | --- | --- |
| files | 10,256 | 10,785 | 12,385 |
| uncompressed | 512 MB | 608 MB | 420 MB |

More files, smaller image: the 72 MB drop is **binary stripping**, not feature
removal — net −262 MB across files present in both (`libpython3.12.so` −20.8 MB,
`librkaiq.so` −15.7 MB, `libc` −15.4 MB, plus `perf`, `trace` and valgrind
removed entirely). 1.7.0 shipped unstripped libraries and full debug tooling.

Practical consequence: **older firmware is the friendlier reversing target** if
symbols ever matter.

---

## Route 10 — the firmware image format, fully decoded

All measured on `glkvm-RM10-1.10.0-0715-1784101556.img` (2026-09-01).

### Container layout

```
offset            contents
----------------  --------------------------------------------------------
0x00000000        RKFW header, 0x66 bytes
0x00000066        loader (MiniLoaderAll), 451,008 bytes
0x0006e226        RKAF blob, 304,125,952 bytes  (= header@4 "length")
0x12277a26        RKCRC32 over the RKAF blob, 4 bytes, LITTLE-endian
0x12277a2a        Ed25519 signature, 64 bytes
0x12277a6a        MD5 of everything above, as 32 ASCII hex chars
0x12277a8a        EOF (304,577,162)
```

**RKFW header fields** (all `<u32` unless noted):

| Offset | Value here | Meaning |
| --- | --- | --- |
| `0x00` | `RKFW` | magic |
| `0x04` | `0x66` (u16) | header size |
| `0x19` | `0x66` | loader offset |
| `0x1d` | `451008` | loader size |
| `0x21` | `0x6e226` | image (RKAF) offset |
| `0x25` | `304125956` | image size = RKAF length **+ 4** (the CRC) |
| `0x29` | `ED25` | signature-type marker |

**RKAF header**: `RKAF` magic, `<u32 length` @4, `model[34]` @8, `id[30]` @42,
`manufacturer[56]` @72, `<u32 version` @132, `<u32 num_parts` @136, then
`num_parts` × 112-byte entries from @140. Each entry: `name[32]`,
`filename[60]`, `<u32 pos` @96 (offset within the RKAF blob), `<u32 flash_offset`
@100, `<u32 size` @108.

### ⭐ The two checksums — both identified by measurement

1. **RKCRC32 over the RKAF blob**, 4 bytes little-endian, immediately after it.
   **Polynomial `0x04c10db7`** — note `0DB7`, *not* the standard CRC-32
   `0x04c11db7` — MSB-first, `init 0`, no final XOR, no reflection. Verified:
   computes `0x416f610c`, which is exactly the stored value. The standard
   polynomial gives `0x3e6e1346` and is wrong.
2. **MD5 of `file[:-32]`** — i.e. everything including the signature — stored as
   32 lowercase ASCII hex characters at the very end. Verified: computes
   `398fbb3780e4470e7d041131997a7ac2`, matching the stored tail exactly.

The 64-byte Ed25519 signature cannot be forged without GL.iNet's key. It does
not need to be: `POST /api/upgrade/start?skip_verify=true` skips
`fwtools verify` entirely, and the non-skippable gate is `check_image_validity`,
which is on-device and can be used as an oracle for a rebuilt image.

### ⭐ The rootfs rebuild is bit-for-bit reproducible

`mksquashfs 4.6.1 -comp gzip -b 131072` (defaults otherwise) rebuilds GL.iNet's
rootfs so that **exactly 3 bytes of 224 MB differ** — offsets 9, 10, 11, which
are the `mkfs_time` field (offset 8 matched by coincidence):

```
vendor : mkfs_time=1784101549  2026-07-15 07:45:49
ours   : mkfs_time=1788283700  2026-09-01 17:28:20
```

`bytes_used` (223,958,876) and the 2,212-byte tail padding match exactly. Pass
`-mkfs-time 1784101549` and the rebuild is byte-identical. So our packing
options are provably the same ones GL.iNet used, and a *modified* repack is
structurally indistinguishable from vendor output.

Note the **RM10 rootfs is gzip**, not zstd — the RM1 1.10.0 image was zstd.
Superblock: squashfs v4.0, 13,550 inodes, 128 KiB block, 974 fragments,
flags `0xc0` (= `DUPLICATES | EXPORTABLE`, i.e. mksquashfs defaults).

### Baking provisioning into the image — and why `/etc/init.d` works there

A modified rootfs was built with the classic-UI nginx block uncommented,
`override.yaml` installed, and `S99kvmd-vnc` placed in **`/etc/init.d/`**.

⭐ **In a rebuilt base image, `/etc/init.d` is the correct location** — the
overlay trap does not apply. `rcS` globs `/etc/init.d/S??*` from the read-only
squashfs, so a script baked into the image *is* seen; it is only overlay-added
scripts that are invisible. This is the one context where the rule inverts.

Result: 223,965,184 bytes, one 4 KiB block larger than stock, against a rootfs
partition of 1 GiB (`0x38000`→`0x238000` sectors) — ample headroom.

### The build VM

Repacking needs `mksquashfs`, which exists on neither Workstation nor the KVM.
Built a throwaway VM rather than cluttering the desktop:

| | |
| --- | --- |
| Name | `glkvm-build` (`vm-1263`), 192.0.2.160 |
| Template | `Ubuntu-2404-template` (`vm-1212`) — **not** `ubuntu-2604-template` |
| Host / datastore | 198.51.100.15 (esxi-host) |
| Seeded by | NoCloud ISO, volume id `CIDATA`, per [[ubuntu-2404-template]] |
| Toolchain | squashfs-tools 4.6.1 (gzip/lzo/lz4/xz/zstd/lzma), zstd, python3 |
| Disk | **IndependentNonPersistent** — every power-on is a clean box |
| CD | detached: `RemotePassthroughBackingInfo`, `startConnected=False` |

⚠ **The disk is non-persistent by design**: work done on it is discarded at
power-off. The toolchain survives because it was installed *before* the flip.
Copy anything you want to keep off the VM before powering it down.

Provisioned with PowerCLI under `ob.ps1 esxi` (OpenBao injects vCenter creds as
env vars — never printed, never on argv).

## Routes 4 and 5 COMPLETE — IPMI works, auth is passwordless

### Route 5 — passwordless

`kvmd.auth.enabled: false` in `/etc/kvmd/override.yaml`. Measured effect: the
REST API returns **200 unauthenticated** where it returned 401 all session
(`/api/info`, `/api/atx`). Applies to the web UI, the API, and VNC's VeNCrypt
path. Revert by deleting that block and restarting kvmd.

### ⭐ Route 4 RESOLVED — use Redfish, not IPMI

**kvmd already implements Redfish, the industry successor to IPMI, and it works
where IPMI does not.** Verified live on `.15`:

```
GET  /redfish/v1                      -> ServiceRoot, RedfishVersion 1.6.0
GET  /redfish/v1/Systems              -> 1 member
GET  /redfish/v1/Systems/0            -> PowerState: Off
POST .../Actions/ComputerSystem.Reset -> validates ResetType, rejects bad input
```

Reachable from another host on the LAN. No RAKP handshake, no `pyghmi`, no
UDP — plain HTTPS/JSON.

**It is strictly better than the IPMI path:**

| | IPMI (`kvmd-ipmi`) | Redfish |
| --- | --- | --- |
| Works here | no — flaky, three different errors per run | **yes** |
| Power actions | 4 | **6** |
| Extra dependency | `pyghmi` via pip | none — already in kvmd |
| Transport | UDP 623 + RAKP | HTTPS |
| Protocol security | leaks a password hash pre-auth by design | normal TLS + kvmd auth |

Actions (`api/redfish.py:58-63`): `On`, `ForceOff`, `GracefulShutdown`,
`ForceRestart`, `ForceOn`, `PushPowerButton` — note IPMI had no graceful/forced
distinction.

Example:

```sh
curl -sk https://<ip>/redfish/v1/Systems/0 | jq -r .PowerState
curl -sk -X POST -H 'Content-Type: application/json' \
     -d '{"ResetType":"GracefulShutdown"}' \
     https://<ip>/redfish/v1/Systems/0/Actions/ComputerSystem.Reset
```

Tooling: `redfishtool`, Ansible `community.general.redfish_command`, and most
modern DC automation speak Redfish natively.

**`kvmd-ipmi` has been disabled** (gate file removed; the init script is kept,
so re-enabling is one `touch`). Upstream kvmd 4.213 was checked first — it uses
**the same pyghmi** with only cosmetic changes, so there was no fix to backport.

⚠ **SECURITY, given passwordless is on:** `kvmd.auth.enabled: false` means these
Redfish calls need **no credentials**. Anyone on the LAN can read power state
and power-cycle the attached machine. That is the direct consequence of route 5,
and it is worth deciding on deliberately — either keep the egress/segment
controls tight, or re-enable auth now that the credential is vaulted and in sync.

### Route 4 — IPMI — ⚠ REVISED: UNRELIABLE

**The earlier "working" claim does not hold up.** With `pyghmi` installed the
daemon starts and binds udp/623, but does not serve dependably: the same
`ipmitool` command returns three different failures across consecutive runs —
`no response from RAKP 1`, `Unable to establish IPMI v2 / RMCP+ session`, and
`Set Session Privilege Level to ADMINISTRATOR failed` (the last meaning RAKP
*succeeded* and only privilege escalation failed). The daemon logs nothing for
any of them, including when run in the foreground.

Two things muddied the original result:

1. **An orphaned instance was squatting the port.** `ps w | grep kvmd-ipmi`
   reported nothing while `netstat` showed `3620/python` on udp/623 — busybox
   `ps` truncates the command column, so every `ps`-based check missed it.
2. **The daemon had loaded the ORIGINAL template credentials** and kept serving
   from memory after `ipmipasswd` was rewritten underneath it without a restart.
   The reboot was the first time it ever loaded a real credential.

Ruled out: firewall (INPUT policy ACCEPT, nothing on 623), `bindv6only` (0),
malformed `ipmipasswd` (exactly 1 active entry, parses cleanly), password
charset/length (20 chars printable ASCII, inside IPMI's 20-byte limit), and
duplicate listeners (exactly one after cleanup).

**Recommendation: leave IPMI off unless you have existing IPMI tooling to point
at these units.** It buys only ATX power control, which the REST API and both
web UIs already provide — the same conclusion reached before it was enabled.

### Route 4 — IPMI (as originally recorded)

`pip install pyghmi` on-device fixed the `ModuleNotFoundError` that made
`kvmd-ipmi` unstartable. **Note pip also upgraded `cffi` 1.16.0 → 2.1.1 and
pulled in `cryptography`** on a live system — kvmd was re-checked afterwards
(imports, `--dump-config` exit 0, all services healthy).

Working end to end from another host:

```
ipmitool -I lanplus -H 192.0.2.15 -U admin -P admin power status
  -> Chassis Power is off
```

⛔ **Two findings worth keeping:**

1. **The shipped `admin:admin` IPMI entry authenticates.** Before any change,
   the daemon log showed the RAKP handshake completing and reaching
   `Performing request atx.get_state() from IPMI user 'admin'`. It only failed
   at the second hop (`401`) because the template's KVMD-side password was
   stale. Anyone on the LAN could complete IPMI auth against a stock unit.
2. **Disabling auth silently completed the IPMI chain.** The same call that
   returned 401 started returning `Chassis Power is off` once
   `kvmd.auth.enabled: false` was set — because the KVMD API stopped checking.
   So route 5 changed route 4's behaviour without either being touched.

### The KVMD credential

A 28-character random password was generated and set with
`kvmd-htpasswd set admin -i` (stdin, never on argv). `/etc/kvmd/ipmipasswd` now
maps `admin:admin -> admin:<that password>`, mode `0600`.

⚠ **Not yet vaulted.** Both on-disk OpenBao rw tokens
(`%LOCALAPPDATA%\mainloop\openbao_rw.token`, `D:\stage\ob_rw.token`) return
**403 on every operation their own policy grants** — `read` on
`secret/data/agentvault/*`, `lookup-self`, `renew-self` — while the ro token
succeeds over the identical SSH-to-appliance transport
(`ttl=2374695s renewable=True policies=openbao-ro`). Both rw copies are 26-char
`s.`-prefixed and decode cleanly from UTF-16-BOM.

⭐ **Two traps met on the way, both mine:** a 403 on `lookup-self` says nothing
about validity in a hardened container, and `openbao_run.py` falls back to the
env var literally named `OPENBAO_ROOT_TOKEN` — passing `--token-env` alone can
mean no token is sent at all, which looks exactly like a permissions failure.

The password is recoverable from `/etc/kvmd/ipmipasswd` on `.15` until it is
vaulted, so nothing is lost. Target: `secret/agentvault/glkvm`, key
`KVMD_ADMIN_PASSWORD` — its own project, per Lewis.

## Route 10 COMPLETE — we can build, modify AND sign firmware

Verified end to end on `.15` with the device's own tools:

```
check_image_validity signed.img   ->  Valid, exit=0     (non-skippable gate)
fwtools verify signed.img OURKEY  ->  Signature: OK
fwtools verify signed.img GLKEY   ->  Signature: FAIL
fwtools info                      ->  MD5 check: OK
```

### The signing scheme

`fwtools` exposes `sign` / `verify` / `pack` / `extract` / `info`, and takes
**raw 32-byte** Ed25519 keys. The signature covers **`file[:-96]`** — header +
loader + RKAF + CRC, i.e. everything before the signature itself. Determined by
verifying GL.iNet's own signature against candidate ranges using their public
key (`f7e69e17…`), not by guessing.

`tools/rk_sign.py` signs an image and recomputes the trailing MD5 (which covers
`file[:-32]` and therefore *includes* the signature — sign first, then MD5).

### Stripping the vendor trust anchor

`/etc/firmware/key/public.raw` is a plain 32-byte file in the rootfs. Our build
replaces it with our own public key and keeps GL.iNet's alongside as
`public.raw.glinet`, so the change is reversible from inside the image.

**The bootstrap chain:** the first flash still needs `?skip_verify=true`, because
the *currently installed* key is GL.iNet's. After that our key is in place and
every subsequent image we sign verifies natively — no bypass flag, and no
dependence on GL.iNet leaving `skip_verify` in place.

Keys live on the build VM only (`glkvm-signing.priv` / `.pub`, non-persistent
disk). **The private key is not in this repo and is lost on VM power-off** — if
that matters, vault it before powering down.

## Route 8 COMPLETE — self-hosted relay

`glkvm-relay` (`vm-1264`), **192.0.2.140**, built from `Ubuntu-2404-template`
exactly like the dev box (NoCloud `CIDATA` seed, PowerCLI under `ob.ps1 esxi`).

| | |
| --- | --- |
| Stack | `gl-inet/glkvm-cloud` @`be821d4`, Docker Compose |
| Containers | `glkvm_cloud`, `glkvm_coturn` — both running |
| Ports | 443 web UI, 10443 ws proxy, 5912 device, 3478 TURN (TCP+UDP) |
| Secrets | generated into `~/glkvm-cloud/docker-compose/.env` (0600), **not** in this repo |
| Disk | **Persistent** — deliberately unlike the dev box; a relay holds state |
| CD | detached, seed deleted from the datastore |

⚠ The shipped compose defaults are placeholder secrets
(`DeviceTokenYouCanChangeMe`, `StrongP@ssw0rd`, `AnotherS3cret`). They were
replaced with generated values. Read them on the VM to log in, and vault them.

Correction to an earlier note: glkvm-cloud supports **arm64 as well as x86_64** —
"x86_64 only" came from a stale search result, not the repo.

## Virtual media (MSD) — works, with one sharp edge

[measured] 2026-09-01 on `.15`. Nothing had to be enabled — `main.yaml` already
carried `msd: {type: otg}`.

| | |
| --- | --- |
| Backing store | `/dev/block/by-name/media` → `/dev/mmcblk0p10`, **27 GB exfat**, mounted at `/userdata/media` |
| Free | 28.78 GB of 28.80 GB |
| Gadget LUN | `/sys/kernel/config/usb_gadget/rockchip/functions/mass_storage.0/lun.0` |
| Second LUN | `mass_storage.1/lun.0` exists, **empty, `ro=0 cdrom=0`** — a writable stick available alongside the CD |

Full cycle proven end to end: upload → select as cdrom → connect, after which
the LUN's `file` is the uploaded image with `ro=1 cdrom=1`.

Images live on their own partition, **outside the overlay** — so they survive a
config rollback or a `restore-checkpoint.sh`, but not a reflash.

### The sharp edge — minimum image size

The kernel gadget counts 2048-byte sectors in cdrom mode and refuses fewer than
300 of them. Bracketed exactly [measured]:

| bytes | sectors | `set_connected=1` |
| --- | --- | --- |
| 612352 | 299 | **HTTP 500** |
| 614400 | 300 | HTTP 200 |

The 500 body is only `Server got itself in trouble`. The actual reason appears
nowhere in the API — just `mass_storage.0/lun.0: file too small` in `dmesg`.
This is worth knowing because the obvious way to test MSD is with a tiny
hand-rolled ISO, which fails and looks like a broken feature rather than an
undersized file. `tools/msd.sh` checks the size locally and says so.

### The storage list lags

kvmd rescans `/userdata/media` on a timer rather than on demand, so for a few
seconds after `remove` the API still lists the image and `write` fails with
`MsdImageExistsError` against a file that is already gone from disk.
`msd.sh upload` waits for the API's view to catch up, not the disk's.

### Usage

```
tools/msd.sh 192.0.2.15 mount ubuntu.iso     # upload + attach as cdrom
tools/msd.sh 192.0.2.15 mount disk.img --disk
tools/msd.sh 192.0.2.15 status
tools/msd.sh 192.0.2.15 detach
```

Honest limit: this is verified **device-side**. That the gadget accepts, backs
and exposes the image is measured; that an attached machine actually boots it
needs a real target and a real installer image, which has not been done.

## Modifying kvmd modules — the mechanism, and the trap under it

### The version string is a lie

`.15` runs firmware **1.8.1**. The GPLv3 source we hold (`vendor/glkvm`
@3e8dd23) is **1.10.0**. Both declare `kvmd.__version__ == "4.82"`.

They are not the same code. Compiling the source on the device and comparing
bytecode — skipping the 16-byte header, which carries only mtime and size —
shows every module differs [measured]:

| module | source | device |
| --- | --- | --- |
| `api/export.py` | 4128 B | 4166 B |
| `info/__init__.py` | 5172 B | 5020 B |
| `info/health.py` | 7190 B | 8042 B |
| `api/msd.py` | 20810 B | 20106 B |

GL.iNet never bumped the kvmd version between firmware releases, so the one
identifier you would normally gate a port on is worthless here. Dropping
1.10.0's `info/__init__.py` straight onto the device crashed kvmd at startup:
1.8.1's `HealthInfoSubmanager` takes `(vcgencmd_cmd, ignore_past, state_poll)`,
1.10.0's takes `(state_poll)`.

**Always prove provenance first.** Bytecode is architecture-independent, so
this works from any Python 3.12:

```python
py_compile.compile(src, cfile=tmp, doraise=True)
open(tmp, "rb").read()[16:] == open(device_pyc, "rb").read()[16:]
```

When it differs, recover the real shape from the device rather than guessing —
`marshal.loads(pyc[16:])` gives a code object whose `co_consts` and `co_names`
expose the actual constants, and `inspect.signature` on an imported class gives
the actual signature. That is how the two facts above were established.

### The mechanism

`patches/` mirrors the site-packages tree. `tools/apply-module.sh` installs one
file, compiling it **on the device** and keeping the vendor `.pyc` alongside as
`.pyc.orig` — written exactly once, so repeated applies can never lose the
original.

```
tools/apply-module.sh 192.0.2.15 patches/kvmd/apps/kvmd/api/export.py
tools/apply-module.sh 192.0.2.15 patches/kvmd/apps/kvmd/api/export.py --revert
tools/apply-module.sh 192.0.2.15 --list
```

It compiles rather than dropping the `.py` in because the device ships kvmd
sourceless and `.py` outranks `.pyc` in importlib's suffix order — a stray `.py`
silently wins and leaves a mixed tree plus `__pycache__` no vendor image has.

It deliberately does **not** restart kvmd, so a batch of modules costs one
restart: `ssh root@<ip> '/etc/init.d/S98kvmd restart'`, then ~15 s.

## Prometheus and hardware telemetry — both were dead, both now work

[measured] 2026-09-01 on `.15`. Two separate faults, both shipped:

**1. The Prometheus endpoint had never worked.** `GET /api/export/prometheus/
metrics` returned HTTP 500 on a stock unit:

```
File ".../kvmd/apps/kvmd/info/__init__.py", line 65, in get_state
KeyError: 'fan'
```

GL.iNet commented the `fan` submanager out of `InfoManager.__subs` but left
`api/export.py` asking `get_state(["health", "fan"])` for it. Nothing else in
the product touches that path, so it went unnoticed.

**2. Health telemetry was collected by nothing.** Disassembling the device's
`info/__init__.pyc` shows `InfoManager.__init__` registers only `system`,
`auth`, `meta`, `extras`. `health.pyc` ships in the image and is never
registered — so CPU temperature, load and memory were unreachable from both
UIs and the API. `/api/info?fields=health` returned a validator error.

Fixed with three patched modules:

| patch | what it does |
| --- | --- |
| `api/export.py` | asks `InfoManager` only for submanagers it actually registered, so a disabled one costs a missing metric rather than the whole endpoint |
| `info/health.py` | ported from 1.10.0 — drops the Raspberry-Pi `vcgencmd get_throttled` probe that failed every 5 s forever on RV1126, and adds network rate counters |
| `info/__init__.py` | registers `health`, passing `state_poll` explicitly (the device config still carries an `ignore_past` option the ported health no longer takes) |

`fan` is deliberately left unregistered: `kvmd.info.fan.unix` is `''` and there
is no `kvmd-fan` daemon, so it could only ever report
`{"monitored": false, "state": null}`.

Result — `GET /api/export/prometheus/metrics` now returns 200:

```
pikvm_atx_enabled 1
pikvm_atx_power 0
pikvm_gpio_output_online_demo_button 0
pikvm_hw_cpu_percent 7
pikvm_hw_mem_available 698966016
pikvm_hw_mem_percent 32.4
pikvm_hw_mem_total 1034514432
pikvm_hw_net_bytes_recv 47419647
pikvm_hw_net_rx_rate 2388
pikvm_hw_net_tx_rate 3164
pikvm_hw_temp_cpu 45.03
```

`/api/info?fields=health` now works too, so both UIs can show it. Log is clean —
zero errors after the change, against 13 in 60 lines before.

Note `kvmd.prometheus.auth.enabled` defaults to **true**; the endpoint is open
today only because auth is globally disabled. Re-enabling auth closes it.

## How deep does the vendor glue actually go?

Worth knowing before planning to replace any of it. Classifying the 36 source
files GL.iNet added that upstream PiKVM does not have, by what each reaches out
to [measured, by scanning the 1.10.0 source]:

| tier | files | verdict |
| --- | --- | --- |
| **Pure Python** — no ubus, no GL binaries, no hardware | `api/serial.py` (22 KB), `api/turn.py`, `api/cloudflare.py`, `api/redfish.py`, `api/init.py`, `api/twofa.py`, `api/netbird_daemon.py`, `switch/sysfs_chain.py`, `hid/otg/touch.py`, `otg/hid/touch.py`, `utils.py`, `hid_otg_lifecycle.py`, `janus/pystun3.py` | 13 files. Ordinary Python we hold under GPLv3. Rewritable outright. |
| **Subprocess wrappers** around OpenWrt/GL services | `api/tailscale.py`, `api/zerotier.py`, `api/netbird.py`, `api/fingerbot.py`, `api/wol.py`, `api/recorder.py`, `api/common.py`, `api/config_utils.py`, `api/rndis.py`, `streamer.py`, `plugins/atx/glatx.py`, `otg/mtp.py`, `switch/lib.py`, `init.py` | Replaceable, but you would be reimplementing their shell-outs. `glatx.py` — the power-control glue — is only **6.5 KB**. |
| **ubus / `/etc/glinet` entangled** | `api/upgrade.py` (61 KB), `api/astrowarp.py`, `api/custom_screen.py`, `api/modem.py`, `api/repeater.py`, `api/ap.py` | Genuine OpenWrt integration. Mostly device management, not KVM function. |
| **The monster** | `api/system.py` — **116 KB**, hits `/etc/glinet`, GL binaries and configfs | The one piece it would really hurt to reimplement. |

The practical read: for **KVM function** we depend on `glatx.py` (6.5 KB),
`streamer.py` (26 KB), `hid/otg` and `msd/otg` (both largely upstream). That is
a small, tractable surface. The 116 KB of `system.py` is network and device
administration — the GL.iNet product wrapper, not the KVM.

So "rewrite the glue for more control" is a choice rather than a necessity: we
hold the source for all of it. The friction is not the glue, it is that the
device runs **1.8.1 while the source we hold is 1.10.0**, so each port needs
the provenance check above. Closing that gap — running a firmware whose source
we hold exactly — would make every module patchable without that step.

## The front panel — what it really is, and drawing on it

[measured] 2026-09-01 on `.15`.

### It is not an OLED, and `kvmd-oled` cannot drive it

The `kvmd-oled` entry point ships, and `/dev/i2c-1|3|5` exist, so this looks
like the PiKVM OLED feature. It is not. `kvmd-oled` drives monochrome SSD1306 /
SH1106 panels over i2c through `luma`, and:

- **there is no i2c OLED.** A scan of buses 1 and 5 finds no display — only
  `0x2c`/`0x44` on bus 1 and one busy address on bus 5. Bus 3 is held by
  `/usr/sbin/lt86102sxe_setup`, the HDMI repeater, not a screen.
- **`luma.core` is unimportable**, so `kvmd-oled` cannot even start:
  `ModuleNotFoundError: No module named 'luma.core'`.

⚠ That second point is easy to get wrong in both directions. `pip freeze` and
`importlib.metadata.version()` both report `luma.core==2.6.0`, because
`luma_core-2.6.0.dist-info` is present — but `site-packages/luma/` contains
only `oled/`; the `core/` package files are absent. GL.iNet registered the
distribution and shipped none of it.

This predates anything we did: `luma/core/` has **0 files** in the
pre-upgrade site-packages snapshot as well as every checkpoint since, so our
package upgrade did not cause it. Checked because the directory's mtime falls
inside our working window and looked incriminating.

The RM10's panel is a **colour DSI LCD on the Rockchip display controller**:

| | |
| --- | --- |
| Device | `/dev/fb0` (`rockchipdrmfb`) and `/dev/dri/card0` |
| Framebuffer | **180×456 portrait**, 32 bpp, stride 720 |
| As mounted | **456×180 landscape** — the panel is rotated |
| Pixel order | **BGRA**. Swapped, the blue UI turns orange |
| Owner | `/usr/sbin/gl_kvm_gui`, from `/etc/init.d/S39gl-kvm-gui` |

So the framebuffer is the transpose of what the user sees: compose landscape,
rotate 90° counter-clockwise on the way out. Getting that backwards still
"works" and produces a sideways clipped mess.

### Taking the panel needs two stops, not one

`/usr/bin/gl_kvm_monitor` — Lua 5.4 bytecode, started by
`/etc/init.d/S99gl_kvm_monitor` and running under `eco` — polls
`pidof gl_kvm_gui` and runs `/etc/init.d/S39gl-kvm-gui start` the moment it
disappears. Stop only the GUI and it returns within seconds and repaints over
your work, which reads as a failed blit rather than a watchdog.

That watchdog also supervises `connman`, `repeater`, `gl_kvm_ap`,
`gl-kvm-modem` and `kvmd-rndis`, so it should not be left stopped for long.

### Their assets are on the device

`/etc/rm10-gui` — 18 MB, 6 fonts and 137 PNGs across 17 screens:

```
fonts/    DMSans-Medium, IBMPlexSans-{Regular,Medium,MediumItalic},
          IBMPlexSansSC-{Regular,Medium}
picture/  home (41)  net_info (22)  wifi (20)  welcome (13)  keyboard (6)
          cloud_service (5)  dev_info (4)  hdmi_video (4)  hiboard (4) ...
```

`picture/home/internet_background.png` is the 456×180 planet backdrop;
card icons are 30×30 (`{usb,km,hdmi_in,hdmi_out}_{connect,disconnect}.png`),
status icons 22×22. We use them **in place** rather than copying them into this
repo — they are GL.iNet artwork, and reading them off the device we are drawing
on avoids redistributing them.

### Their layout, measured

Captured their own home screen (`dd if=/dev/fb0`, rotate) and found the
luminance steps, so ours lines up:

| element | y | detail |
| --- | --- | --- |
| status row | 8–26 | 22×22 icons, clock right-aligned |
| headline | 40–68 | IBM Plex Sans Medium ~34 px, white |
| subtitle | 82–93 | IBM Plex Sans Regular ~13 px, grey `#9aa3ad` |
| card row | 104–166 | 4 cards, w=105, `x = 8 + i*111` |
| └ icon | +13 | 30×30, centred |
| └ label | +44 | ~13 px, centred |

The cards are a *hint* of a plate, not a panel — interiors sit only ~8
luminance above the backdrop, so alpha ≈ 30/255.

⚠ `Image.paste(src, box, mask)` **ignores `src`'s own alpha** when a mask is
given. Pasting an alpha-30 white plate through a solid rounded-rect mask paints
opaque white and loses the planet behind it. The alpha has to live in the mask.

### kvmd's API from on the device

kvmd binds **no TCP port** — `server.unix = /run/kvmd/kvmd.sock`. nginx on :80
answers `301` to https, so the obvious `http://127.0.0.1/api/...` returns a
redirect rather than data. Go straight to the socket, and note nginx strips the
`/api` prefix before proxying: kvmd itself sees `/hid`, not `/api/hid`.

### Result

`tools/panel.py` renders in their visual language from their own assets;
`tools/panel.sh` drives it from the workstation.

```
tools/panel.sh 192.0.2.15 preview kvmd   # PNG only - panel untouched
tools/panel.sh 192.0.2.15 capture        # what is on screen right now
tools/panel.sh 192.0.2.15 show kvmd      # take the panel, draw once
tools/panel.sh 192.0.2.15 run  kvmd 5    # take it and refresh every 5s
tools/panel.sh 192.0.2.15 restore        # hand it back to GL.iNet
```

Two screens exist: `home` reproduces theirs (IP, Ethernet label, K&M / HD-IN /
HD-OUT / USB cards driven by real kvmd state), and `kvmd` shows what their
screen does not — CPU temperature as the headline, with CPU, memory, MSD media
state and ATX power in the cards.

Verified end to end: drew the `kvmd` screen to `/dev/fb0`, read the framebuffer
back, and the read-back matches the render exactly — so rotation and BGRA order
are both right. The panel was then handed back to `gl_kvm_gui`.

## Three more features, tested and reversible

[measured] 2026-09-01 on `.15`. All three were exercised end to end and the
device was left exactly as found.

### Wake-on-LAN — works, no setup needed

| endpoint | verb | note |
| --- | --- | --- |
| `/api/wol/scan` | GET | ARP sweep via `gl-arp-scan -i <iface>` over eth0 and wlan0 |
| `/api/wol/list` | GET | reads `/etc/kvmd/user/wol_list.json` |
| `/api/wol/wake` | POST | `mac=` — sends via `/usr/sbin/ether-wake -i <iface>` |
| `/api/wol/add` | POST | `mac=` required, `ip=` and `name=` optional |
| `/api/wol/remove` | POST | `mac=` |

Both binaries are present. A scan found **18 devices** on the LAN. Add → list →
wake → remove ran clean, and `wol_list.json` was byte-identical (same MD5)
before and after, so the whole cycle is non-destructive.

Free power-on for anything on the LAN with no ATX wiring — the cheapest useful
capability on the box.

### MSD writable-stick mode — better designed than expected

`/api/msd/partition_connect` and `partition_disconnect` are **GET, not POST**;
posting them returns `405`, which reads like a missing route rather than a
wrong verb.

`partition_connect` **unmounts `/userdata/media` on the KVM** and attaches the
raw block device to the gadget's second, normally idle LUN:

```
mass_storage.1/lun.0   file=/dev/mmcblk0p10   ro=0   cdrom=0
```

That unmount is the right call — two writers on one filesystem corrupts it —
and it means GL.iNet already solved the problem the obvious naive
implementation would have created. `partition_disconnect` detaches and
remounts; 27 GB came back intact.

⚠ The consequence is that the two MSD modes are **mutually exclusive**: while
the stick is connected the ISO storage is gone, so `list` shows no images and
`upload` has nowhere to write. While connected, the MSD API even reports the
*rootfs* (1 GB) as its storage, because the media mount is absent and it falls
back to the parent filesystem.

Note the handlers also shell out to `/usr/bin/reset_udc`, **which does not
exist on this device**. It evidently is not reached on the working path, but it
is a landmine in the vendor code worth knowing about.

Exposed as `tools/msd.sh <ip> stick on|off`.

### TOTP two-factor — works, and needs nothing installed

`pyotp 2.10.0` and `qrcode 8.2` are already on the device. All routes are
**GET**:

| endpoint | params | behaviour |
| --- | --- | --- |
| `/api/2fa/create` | — | returns a fresh 32-char base32 `secret` + `uri`. Does **not** persist it |
| `/api/2fa/init` | `secret`, `key` | enrols — `key` must be a valid current code **for that secret** |
| `/api/2fa/show` | — | `otpauth://` URI, issuer `GLKVM`, scannable by any authenticator |
| `/api/2fa/verify` | `code` | correct → ok; wrong → `ForbiddenError` |
| `/api/2fa/is_enabled` / `/api/2fa/delete` | — | state, and disable |

The enrolment handshake is the standard one and worth spelling out, because
getting it wrong looks like a broken endpoint: `create` hands you a secret but
saves nothing, and `init` refuses with a bare **403 ForbiddenError** unless you
send back a code you derived from that secret. Passing only `secret` — the
obvious first guess — gives that same 403, which reads like an auth-gate
problem rather than a missing proof-of-possession.

Enrolment state is `/etc/kvmd/user/totp.secret` (0 bytes = disabled).

Verified through the full cycle and then **deleted** — TOTP is left OFF, so
there is no way this has locked anything.

### Two that are NOT available, and why

**Snapshots and OCR.** `/api/streamer/snapshot` and `/api/streamer/ocr` both
`503`. The missing `libtesseract` (logged at every kvmd startup) is only the
second problem; the first is that `/api/streamer` reports `"streamer": null`
because **GL.iNet replaced ustreamer with Janus/WebRTC** — `kvmd-janus`,
`janusRestAPIServer.py` (127.0.0.1:8081) and `janus` itself loading the
ustreamer Janus plugin. kvmd's snapshot and OCR paths want a ustreamer instance
that is never started.

Going round it via V4L2 is not a shortcut. There are 40 `/dev/video*` nodes,
all Rockchip CIF/ISP pipeline stages; `/dev/video0` reports 0×0 with no format
and `/dev/video4` is a 40×30 Bayer ISP scaler. HDMI-in is configured by
GL.iNet's own capture stack, so a frame grab means reproducing their
media-ctl/ISP graph — and getting that wrong risks the video path the KVM
exists to provide. `ustreamer`, `ffmpeg` and `v4l2-ctl` are all present, so it
is doable; it is a project, not a switch.

**SNMP.** NET-SNMP 5.9.3 and the `snmp` user ship, but there is **no
`snmpd.conf` anywhere** — not in `/etc/snmp`, `/usr/share/snmp`,
`/usr/lib/snmp` or `/root/.snmp`. Run in the foreground it says so plainly:

```
Warning: no access control information configured.
  It's unlikely this agent can serve any useful purpose in this state.
```

`/etc/init.d/S59snmpd start` therefore prints nothing and leaves nothing
listening, which looks like a broken init script rather than a missing config.
`SNMPDOPTS` also binds `127.0.0.1` only. Low value now that Prometheus works.

### One deliberately not tested

`/api/hid/print` types text into the attached machine. The USB device
controller reports `state=configured, speed=high-speed` and the host is
returning keyboard LED state, so **a real machine is attached to `.15`**.
Typing into a host we cannot see is not ours to decide — left for Lewis.

## Reproducing a unit — and the regression hiding in provisioning

`provision.sh` now has four steps, not three: classic UI, `override.yaml`, VNC,
and **every module under `patches/`** (applied with `apply-module.sh`, then one
kvmd restart for the whole batch). `deprovision.sh` gained the matching revert.

Two things fell out of wiring that up.

### A routine re-run would have silently switched auth back on

Step 2 overwrites the live `/etc/kvmd/override.yaml` with the repo copy. `.15`
carries `kvmd.auth.enabled: false` — deliberate, passwordless while the build
settles — and `tools/override.yaml.example` **does not**. So re-running the
provisioning script, the safest-looking thing in the repo, would have quietly
re-enabled authentication on a unit whose whole point right now is that it is
open.

This is the failure mode worth naming: *provisioning is only idempotent with
respect to the repo, not with respect to the device.* Any setting that exists
on the unit but not in the repo copy is silently destroyed by a "no-op" run.

Step 2 now diffs the two — comments and blank lines stripped, since those churn
constantly — and **aborts** if the device holds lines the repo lacks, printing
them. `--force` overrides. Verified against `.15`: it correctly refuses and
names `enabled: false`.

### override.yaml never took effect until a reboot

The old script installed `override.yaml`, validated it with `kvmd --dump-config`,
and never restarted kvmd. `--dump-config` proves the file *parses*, not that the
running daemon has *loaded* it, so the config sat inert until something else
happened to restart the stack. The new step 4 restart covers it.

### Resolution, and the reboot test

`tools/override.yaml.example` now carries `kvmd.auth.enabled: false` under a
prominent banner, so the repo reproduces `.15` exactly rather than silently
diverging. The banner spells out what "open" means here — both UIs, the whole
REST API including MSD and HID, Redfish power control and the Prometheus
endpoint all answer with no credentials — and how to close it (delete two
lines; the credential is already vaulted and in sync).

Verified end to end on `.15` [measured]:

| check | result |
| --- | --- |
| `provision.sh` full run | all 4 steps ✓ |
| Second run immediately after | identical, no changes — genuinely idempotent |
| Vendor `.pyc.orig` after repeated applies | still distinct from live, so the originals were never overwritten |
| **Reboot** | back in ~75 s; 443, 8888, 5900, MSD, ATX, Redfish and Prometheus all up |
| Patches after reboot | all three still installed; health metrics and 13 Prometheus series live |

So the claim in the script header — *survives reboot* — now covers the patched
modules too, not just the UI and VNC.

## The baked image — provisioning inside the firmware, accepted by the device

[measured] 2026-09-01. `tools/bake-image.sh 192.0.2.160` produces
`firmware/glkvm-RM10-1.10.0-provisioned.img` (304,581,258 bytes,
sha256 `c3fa2985…1edd3`). **Built and verified, not flashed.**

| gate | result |
| --- | --- |
| squashfs base is the RM10 image's rootfs, byte for byte | ✓ (223,961,088 B, gzip) |
| `/etc/rm10-gui` + `gl_kvm_gui` present in the tree | ✓ — RM10 confirmed from inside |
| all 7 provisioning steps assert their effect | ✓ |
| new rootfs: 223,965,184 B, gzip, 128 KiB blocks, superblock readable | ✓ |
| 7 partitions before rootfs byte-identical to vendor | ✓ |
| signature replaced; trailing MD5 covers `file[:-32]` | ✓ |
| **on `.15`: `check_image_validity`** | **`Valid`, exit 0** |
| **on `.15`: `fwtools verify` with our key** | **`Signature: OK`** |
| on `.15`: `fwtools verify` with GL.iNet's key | `FAIL` — correct, it is our signature |

What is inside, applied to the vendor 1.10.0 rootfs: our signing public key
(vendor's kept as `public.raw.glinet`), the classic UI on :8888, `override.yaml`
(**auth disabled** — see its banner), VNC autostart via `/etc/kvmd/user/scripts`,
the patched `api/export.pyc`, our SSH key in `/root/.ssh/authorized_keys`,
`/etc/glkvm-bake.txt` naming the git revision, and every `.orig` that
`deprovision.sh` and `apply-module.sh --revert` expect — so a unit flashed from
this image can still be walked back to vendor state with the same tools.

Only `export.py` of the three patches is baked. Disassembling the **real**
1.10.0 `info/__init__.pyc` shows it already registers `health` with
`HealthInfoSubmanager(self, state_poll)`; the other two patches exist to do
that on 1.8.1. The `fan` request in `export.py` is present on both, so
Prometheus is broken on stock 1.10.0 too.

### The trap this build walked into, and the gate that now stops it

`extracted/rootfs-1.10.0.squashfs` was the **RM1** rootfs — byte-identical to
the RM1 1.10.0 image's partition, zstd, no LCD assets. The first bake went all
the way to `mksquashfs` on it. Every check passed, because the RM1 and RM10
rootfs are the same kvmd, the same nginx block, the same key path; only the
LCD assets (`/etc/rm10-gui`) and `gl_kvm_gui` differ. Nothing had asked *which
hardware* the base was for.

Two independent gates now do. The orchestrator hashes the squashfs against the
rootfs partition of the hash-verified RM10 image; the VM side refuses a tree
without `/etc/rm10-gui`. The file is renamed `rootfs-RM1-1.10.0.squashfs`, and
the RM10 one is `rootfs-RM10-1.10.0.squashfs`, extracted straight from the
image by `rk_pack.parse` rather than trusted from a directory listing.

### Flashing, when that decision is made

It wipes the overlay — including the SSH key on the *current* system — and
the first flash of a stock unit needs `POST /api/upgrade/start?skip_verify=true`
because the installed key is GL.iNet's. After that our key is in place. The
image carries its own `authorized_keys`, so SSH comes back without the
browser-console bootstrap.

## CI — on the forgehost Gitea runner, built to fail loudly

GitHub Actions is halted on a spend cap; `.github/workflows/ci.yml` is parked
on `workflow_dispatch`. `.gitea/workflows/validate.yml` on the self-hosted
runner is the pipeline that gates the repo. [measured] 2026-09-01: run #16
green on push; `verify-gates` (dispatch-only) run #17 green on the runner.

| job | when | what |
| --- | --- | --- |
| `Tooling selftest` | every push | `tools/selftest.sh --ci` — shell syntax, shellcheck (pinned, via `shellcheck-py`), Python compile, `override.yaml.example` validation, the firmware packer selftest, regression checks for the three silent bugs, exec bits in git |
| `Prove the gates can fail` | `workflow_dispatch` | `tools/verify-gates.sh` — breaks each thing selftest checks and asserts it goes red, with an unmodified copy as positive control |

Design rules, each earned:

- **`--ci` turns a skipped check into a failure.** A check that could not run
  has verified nothing, and a runner can install whatever it needs. Only two
  skips survive: gitignored build artifacts, and the absence of a real KVM.
- **Every enumeration has a floor.** `for f in tools/*.sh` after a rename
  iterates zero times and every assertion inside passes.
- **Nothing suppresses a child's output**, and every `run` uses
  `set -euo pipefail` under an explicitly declared `bash` — the runner's
  default shell rejects `pipefail`, and every other workflow in the estate
  avoids it rather than declaring a shell.
- **One fast job on push.** The runner is shared with capacity 1.
- **`actions/checkout@v3`**, not v4 — v4 is not supported by this runner.

### The failure that took six runs to see

Every `tools/*.sh` was committed as mode `100644`. The repo is authored on
Windows, where `core.fileMode` is false and `chmod +x` never reaches git's
index, so on the Linux runner the first command of every job —
`./tools/selftest.sh` — was `Permission denied`. The step died before printing
anything, which looked exactly like a broken runner. It was the repo.

This Gitea (1.24.7) exposes no job logs to the API — `/actions/runs` 404s,
`/actions/jobs/{id}/logs` 404s, the artifacts list returns nothing, and the web
route wants a CSRF token — so the only signal a run sends back is per-job
status. The diagnosis came from **encoding one question per job** (does pip
exist, can it install the pins, is shellcheck on PATH, does selftest pass, are
the files executable) and reading which squares went red. `selftest.sh` now
asserts the exec bit is set in git for every script, and that gate was watched
firing in a scratch clone before it was committed.

## `.15` is on 1.10.0 — the flash, and what the firmware diff says changed

[measured] 2026-09-01. `tools/flash.sh 192.0.2.15 firmware/glkvm-RM10-1.10.0-provisioned.img`:
upload → `POST /api/upgrade/start?skip_verify=true` → `updateEngine` wrote
`parameter` + `recovery`, marked the misc partition, rebooted, applied the
rootfs from recovery, rebooted again. **Back in ~30 s** running
`rm10-1.10.0-beta1-3-gbe73e30c64` with `/etc/glkvm-bake.txt` present, our key
installed, VNC hook present, tesseract loading, 905 MB of fresh overlay.
`.15`'s address survived because it is a DHCP reservation, not overlay config.

⚠ **Every checkpoint taken on 1.8.1 is now poison for this unit** — a 1.8.1
`site-packages` under a 1.10.0 kvmd. And that stopped being a prose warning
the same evening: `drift.sh` chose its "newest" checkpoint by sorting whole
names, so `provisioned-reboot-verified-…` (1.8.1) outranked
`flashed-1.10.0-final-…`, the 1.10.0 unit was compared against 1.8.1, and the
1.8.1 tree was offered as a restore target. Now `checkpoint.sh` records the
firmware on the first line of `services.txt`, `drift.sh` picks by timestamp and
**refuses** a checkpoint from another firmware, and `restore-checkpoint.sh`
refuses the same before a byte moves (`--force` to override). All three
behaviours were watched firing [measured].

### Diff first, then debug — `tools/firmware-diff.py`

Four behaviours changed after the flash and each was chased one symptom at a
time before Lewis asked the obvious question: *why not diff the two
firmwares?* The 1.8.1 side is the pre-flash checkpoint (full bytecode tree +
`/etc/kvmd`); the 1.10.0 side is the pristine rootfs. The tool compares `.pyc`
bodies and, for each changed module, lists which constants, names and
functions appeared or vanished — not a decompile, but enough to name every
change. Full report: [docs/firmware-diff-1.8.1-to-1.10.0.md](docs/firmware-diff-1.8.1-to-1.10.0.md).

**kvmd: 7 modules added, 0 removed, 50 changed, 172 identical.** Added:
`api/serial`, `api/recorder`, `api/custom_screen`, `api/netbird`,
`api/common`, and HID touch (`plugins/hid/otg/touch`, `otg/hid/touch`).

| change on 1.10.0 | evidence in the diff | effect on us |
| --- | --- | --- |
| **MSD gadget functions unlinked at boot** | `apps/otg`: `+ start_cdrom`, `+ start_flash`; `apps/otgconf`: `+ __find_dwc3`, bind/unbind | `otg.devices.msd.start_cdrom/start_flash` default **false**; MSD `online: false` until set. Now in `override.yaml.example`; provision.sh links live via `kvmd-otgconf` |
| **MSD remount default broken** | `plugins/msd/otg`: `+ _Plugin__remount_cmd`, `+ switch_partition`, `+ get_storage_root` | new code; default `remount,${mode}` never substitutes. GL.iNet also dropped the per-write RW remount, so a *correct* command leaves the media RO and writes die (`Errno 30`). Override pins `remount,rw` |
| **Health registered natively** | `info/__init__`: `+ _unpack`, `- state_poll`; `health.pyc` byte-only change | the two 1.8.1-only patches are unnecessary — `patches/MANIFEST` now scopes them |
| **OCR gains an NPU backend** | `ocr`: `+ _use_rknn`, `+ __rknn_recognize`, `rknn_socket`; `- libtesseract.so.3.0.5` → `_STATIC_LIBTESSERACT_PATHS` | `ocr_service` ships in **no** firmware; tesseract path is real and finds `.so.5` natively now |
| **Capture requires a live HDMI signal** | `streamer`: `+ venc_mode`, `need_ustreamer=1 ignored: webrtc_client adaptive mode`; main.yaml `--venc-mode`, `pre_start_cmd` USR1/USR2 to `lt86102sxe_setup` | 1.8.1's ustreamer served the bridge splash; 1.10.0's waits for a signal. `ocr.sh read` says so |
| **Password complexity + lockout counters** | `validators/auth`: `+ valid_new_passwd`, classes `[A-Z] [a-z] [0-9] [^A-Za-z0-9]`, 10–63; `auth`: `+ failed_since_last_success`, `+ refresh_token_expiry` | new passwords must carry all four classes — the rotation tooling enforces it |
| **Touch HID** | `plugins/hid/otg`: `+ _send_touch_event`, hybrid/touch modes, `/dev/hidg3` | `hid.usb3` exists, disabled; kvmd logs `Missing HID-touch device: /dev/hidg3` at boot — harmless |
| **nginx: TURN REST served by nginx** | vendor `nginx-kvmd.conf`: new `server { listen 127.0.0.1:8081 … /turnserver.json }` | replaces a resident Python process; no action |
| **nginx: serial websocket, custom-screen upload** | `gl.ctx-server.conf`: `/api/serial/ws`, `/api/custom_screen/update_background`, `client_max_body_size 0` | the new features' plumbing |
| `export.py` fan bug | `export`: `+ pikvm_fan`, `- get_subs` | **still present** — the patch stays universal |
| `yamlconf/loader` | `+ __safe_merge`, "Skipping config file … due to parse error" | a broken override is now skipped with a warning rather than fatal — which is also why an unknown key (`otg.devices.msd.enabled`) was accepted silently |

`/etc/kvmd` vendor-to-vendor: `override.yaml` unchanged; `main.yaml` gains
`venc_mode`, the `lt86102sxe_setup` signal hooks and drops `h264_bitrate`
10000 → 2000; `janus.plugin.ustreamer.jcfg` acap `hw:0,0` → `multi_hdmi_input`.

### Correction: the classic UI on :8888 is controls-only as shipped

Earlier sections call the classic PiKVM UI "live" on the strength of a 200
from its login page. Its **video** comes from kvmd's own streamer, and on both
firmwares that streamer never runs: GL.iNet's 1.10.0 streamer manager starts
ustreamer only on its own `need_ustreamer` demand (their Vue UI / WebRTC path
raises it; the classic UI does not), so `:8888/streamer/state` and
`/streamer/snapshot` answer **502** — no backend behind nginx. Keyboard, mouse,
ATX, MSD and the rest of the classic UI work; the picture does not.

Measured 2026-09-01 on 1.10.0 with `kvmd.streamer.forever: true` set *inside
the existing `kvmd:` block* of `override.yaml`:

| | |
| --- | --- |
| ustreamer | started by kvmd (`/usr/bin/ustreamer --device=/dev/video0 -r 1920x1080 … --jpeg-sink=kvmd::ustreamer::jpeg --h264-sink=kvmd::ustreamer::h264`) |
| `:8888/streamer/state` | **200** — `source.online=True`, 1920×1080, 0 fps (the attached host was not outputting video) |
| `/api/streamer/snapshot?ocr=1` | reachable; 503 only for want of a frame |
| janus | logged `Memsink /dev/shm/kvmd::ustreamer::h264 is ready` |
| auth | stayed off; load average unchanged (~10.6, GL.iNet's pipeline dominates either way) |

So `forever: true` gives the classic UI its video, kvmd snapshots, and kvmd's
own OCR endpoint on 1.10.0. It was reverted after this first test pending
Lewis's call — whether kvmd's ustreamer should run permanently alongside
GL.iNet's adaptive WebRTC pipeline (which the log says can "ignore"
`need_ustreamer` in adaptive mode) — and re-measured with HDMI in connected
(next section). **Decided 2026-09-01: it is the default.**

**A trap found on the way.** The first attempt appended a *second* top-level
`kvmd:` block to `override.yaml`. PyYAML keeps the last duplicate key, so the
appended block silently **replaced** the first — `auth.enabled: false`, the MSD
fixes and the GPIO scheme all vanished, auth came on, and every `/streamer`
call returned 401. That looked exactly like a 1.10.0 auth change and cost a
round of investigation. It is the same family as the silently-accepted unknown
key earlier: `override.yaml` mistakes do not error. `selftest.sh` now refuses
an example with duplicate top-level keys, and `verify-gates.sh` proves that
check fires.

### With HDMI in connected: the streamer, kvmd's own OCR, and HID — all measured

The attached host is a Windows 11 workstation whose **secondary** monitor feeds
`.15`'s HDMI in (2560×1440@60). Everything below was measured against that.

**`kvmd.streamer.forever: true`** (inside the `kvmd:` block): kvmd's ustreamer
runs at 2560×1440, 60 captured fps; `:8888/streamer/snapshot` returns a 138 KB
JPEG of the desktop — the classic UI has its picture; janus attaches to the
h264 memsink; `gl_kvm_gui` and janus stay up; load ~9.3. **Default since
2026-09-01** (Lewis: "leave streamer.forever: true as the default"):
`override.yaml.example` carries it inside the `kvmd:` block, the bake asserts
it is in the baked file, and `.15` was re-provisioned from the example.

**Measured with Lewis watching in the Vue UI (its default WebRTC mode):** one
capture process only — kvmd's ustreamer — with janus and `gl-pion` attached to
its h264 memsink (`sinks.h264.has_clients=true`), `gl_kvm_gui` up, load +0.3.
When the UI connected, kvmd restarted its streamer once (0.7 s) as the UI
pushed its stream parameters, exactly as it would have *started* it on vendor
firmware; after that the picture is shared. The remaining case is the UI's
**GL WebRTC ("adaptive") mode**: `server.py` handles it explicitly —
`__enter_adaptive_mode` force-stops kvmd's streamer and kills janus before
starting `webrtc_client`, and the stream controller computes
`internal_need = (... or stream_forever) and not adaptive_mode`, so `forever`
is masked while adaptive mode is on and the full restart path runs on exit.
GL.iNet wrote the `stream_forever` term into that expression themselves.

**Watched live, 2026-09-01.** Lewis switched the UI's Mode through every
option and back to WebRTC. From `kvmd.log` (device time):

| | |
| --- | --- |
| 07:36:30.9 | `Entering adaptive mode` → `/tmp/kvmd_janus_disable` written → `Stopping streamer immediately` |
| 07:36:31.9 | janus SIGTERM, exited on its own; `webrtc_client` started at :32.4 |
| 07:36:30–:48 | **no** `Started streamer` line — `forever` stayed masked for the whole adaptive window; no fight, no `Unexpected streamer error` |
| 07:36:48.3 | `Exiting adaptive mode` → `webrtc_client` stopped → flag removed at :48.7 → kvmd's ustreamer back at :49.0 (0.3 s later) |
| 07:36:57, 07:37:13 | Direct H.264 and FlexFEC: one 0.9 s parameter restart each, same as vendor firmware would do |

Afterwards: one ustreamer, janus restarted (new pid), `gl-pion` attached,
`kvmd_janus_disable` gone, source online at 2560×1440/60, load unchanged. The
only warning in the window was `webrtc_client`'s own `netlink bind failed`,
which is its logging, not ours. The default holds in every mode the UI offers.

**kvmd's own OCR endpoint had a vendor bug.** `GET /api/streamer/snapshot?ocr=1`
returned 500: `TypeError: 'generator' object does not support the context
manager protocol` — 1.10.0 dropped `@contextlib.contextmanager` from
`_tess_api()` when the RKNN backend was added (the firmware diff shows
`contextmanager` vanishing from `ocr.pyc`), and the NPU service it was meant to
be replaced by ships in no firmware. `patches/kvmd/apps/kvmd/ocr.py` restores
the decorator, nothing else; provenance checked (structure identical to the
device's bytecode; `_tess_api` compiled with `CO_GENERATOR`). Patched: **200**,
629 characters of the secondary monitor's text. Scoped to `rm10-1.10.*` in the
manifest.

**HID.** kvmd reported `keyboard.online=false, mouse.online=false` while every
`send_key`/`print` call returned 200 — kvmd queues events regardless. The
plugin log showed `HID-keyboard is busy/unplugged (write select)` from
**06:31 device time, 32 minutes after boot** — during the streamer experiments'
kvmd restarts, not at the flash — and a zero-length keyboard report to
`/dev/hidg0` never became writable: the host had stopped polling the HID
endpoints while the gadget stayed `configured`. `kvmd-otgconf --reset-gadget`
(a virtual replug) restored it; the `online` flag is **lazy** and only flips
back on the next successful write, so a harmless `ShiftLeft` press/release
turned the keyboard online and a relative-mouse move turned the mouse online.
After the reset all three HID endpoints are polled. Everything typed *before*
the reset never reached the host.

**Reading typed text back was blocked by geometry, not by the tools.** Windows
opens Start on the monitor holding the pointer and keeps the pointer on the
primary; the capture sees the secondary. Sweeping the pointer ±10 000 px with
the relative mouse never put it on the captured display. Lewis then set the
host to *duplicate* displays, and the loop closed on 2026-09-01: Win+R over
kvmd's keyboard (`send_key` MetaLeft+KeyR), `POST /api/hid/print` with the
marker `GLKVM HID OCR 4271`, then kvmd's own OCR restricted to the Run box
(`/api/streamer/snapshot?ocr=1&ocr_left=0&ocr_top=980&ocr_right=430&ocr_bottom=1210`)
returned `Open: GLKVM HID OCR 4271` — exact — and Esc closed the box; nothing
ran. One gotcha cost a round: **`/hid/print` takes the text as the request
body** (`curl --data-binary`), not a query parameter; a `?text=` request
returns 200 and types nothing. Restricting OCR to a region also keeps the
rest of someone's desktop out of the transcript — the first full-frame read
returned every window on the mirrored screen.

**`ocr.sh read` now takes its frame from kvmd's streamer.** With
`streamer.forever: true` the capture node is always held, so the transient
ustreamer path it used to spin up would refuse forever. It now asks
`/run/kvmd/ustreamer.sock` for a snapshot first (2560×1440, ~350 KB, under a
second) and only falls back to the transient path when that socket is absent
(forever off, vendor firmware). Verified: `read --crop 1300,1180,1720,1215`
returned the GL UI's own status line, `WebRTC H.264 - 2560x1440 / 1765 kbps /
60 fps dynamic`.

### The credential leak in that diff

The first run of the diff tool printed `/etc/kvmd/ipmipasswd` — which maps
`admin:admin` onto the real KVMD admin password in plaintext — and the
`htpasswd` hash. Nothing targeted a secret; a diff tool shows everything.
Per the standing rule the credential was **rotated the same hour**: a new
value meeting 1.10.0's complexity rules, written to the vault
(`glkvm/KVMD-HT-PASSWORD`), applied and verified in both places by
`tools/apply-vaulted-credential.sh --from-vault`. The tool now redacts
credential files by name (`SECRET_PATHS`), and the committed report is the
scrubbed one. The PowerShell applier, driven from Git Bash through `ob.ps1`,
had its inner quotes stripped by the nested `powershell -File` and left the
two places out of sync — hence the shell twin.

Also true after any flash: the overlay wipe resets `htpasswd` to **GL.iNet's
default admin credential** and `ipmipasswd` to `admin:admin -> admin:admin`.
The image deliberately carries no secrets, so re-applying the vaulted
credential is a post-flash step (auth is off, so it is not yet exercised).

## The 10 routes — status on `.15`

| # | Route | Status | Note |
| --- | --- | --- | --- |
| 1 | Classic PiKVM UI on :8888 | ✅ **live** | 200 + `PiKVM Login`; autostarts |
| 2 | De-cloud | ✅ **already off** | `enable:false`; `gl-cloud`/`rtty` not running |
| 3 | VNC | ✅ **live** | `RFB 003.008`; autostarts |
| 4 | IPMI | ⛔ **disabled on purpose** | `pyghmi` was installed and the daemon ran, but the RAKP handshake is unreliable. **Superseded by Redfish** — 6 power actions over HTTPS instead of 4 over UDP. |
| 5 | LDAP / PAM / RADIUS auth | ◐ **validated, not activated** | Both configs pass `kvmd --dump-config`. LDAP needs a server; PAM would change who can log in. Auth itself is currently **passwordless** (`kvmd.auth.enabled: false`). |
| 6 | Power/switch drivers (ugpio) | ✅ **live** | `cmd` driver loaded — kvmd logged `Running User-GPIO driver: demo`. `__wol__` is auto-injected by kvmd. |
| 7 | Remote access (Tailscale/NetBird/ZeroTier/Cloudflare) | ✅ **already in use** | `.15` = `gl-rm10-workstation` 100.64.0.62; **netbird, zerotier AND cloudflared all running** |
| 8 | Self-hosted relay (glkvm-cloud) | ✅ **built** | `glkvm-relay` at **192.0.2.140**; both containers up. No devices onboarded yet. |
| 9 | Patch kvmd in place | ✅ **verified** | Round-tripped the device's own tree; on-device `diff -rq` clean |
| 10 | Repack the firmware image | ✅ **complete** | `rk_pack.py --selftest` reproduces the vendor image byte-for-byte; a modified image passes the device's own `check_image_validity`, and `rk_sign.py` gives `Signature: OK` under our key. Not yet flashed. |

### Note for route 2

`cloudflared`, `netbird` and `zerotier` are all running on `.15` alongside
Tailscale. Each is an outbound tunnel. De-clouding removed GL.iNet's own cloud,
but these remain — worth deciding which you actually want.

### Correct firmware for these units

`glkvm-RM10-1.10.0-0715-1784101556.img` (291 MB, sha256 `842760f4…922b`,
verified against the vendor list). RM10 has **no release channel** — testing
only, one version listed. The device runs **1.8.1**, so this image is an
upgrade, not a like-for-like restore.

RM10 partition layout differs from RM1. From the image's own `parameter`
block (`mtdparts=rk29xxnand:…`), sectors × 512 [measured]:

| partition | flash offset | size | vendor payload |
| --- | --- | --- | --- |
| boot | `0x8000` | 32 MiB | 8.3 MiB |
| recovery | `0x18000` | 32 MiB | 16.3 MiB |
| **rootfs** | `0x38000` | **1 GiB** | **213.6 MiB** squashfs (223,961,088 B) |
| oem | `0x238000` | 192 MiB | 6 MiB |
| userdata | `0x298000` | 1 GiB | — |
| media | `0x498800` | 27,467 MiB | — (the MSD partition) |

An earlier draft of this file said "rootfs 224 MB" — that was the vendor
squashfs *file* size (223,961,088 B ≈ 224 MB decimal) misread as the partition
limit. There is ~810 MiB of headroom in the rootfs partition, which matters for
baking anything substantial into an image.

## LIVE TEST — 2026-09-01, on `.15` (GL-RM10, fw 1.8.1)

Root shell obtained after the SSH key was installed via the browser console
(`POST /api/system/ssh_key`, using the operator's existing session). All routes
below were **run on the device**, not simulated.

### Route 1 — classic PiKVM UI on :8888 — ✅ WORKS

```
>> confirming the block actually went live ...
>> validating nginx config ...
nginx: configuration file /etc/kvmd/nginx-kvmd.conf test is successful
>> restarting nginx ... Stopping kvmd-nginx: OK / Starting kvmd-nginx: OK
```

Verified from another machine:

| URL | Result |
| --- | --- |
| `https://192.0.2.15:8888/login/` | **200**, `<title>PiKVM Login</title>` |
| `https://192.0.2.15:8888/kvm/`, `/vnc/`, `/ipmi/` | 302 → login (exist, auth-gated) |
| `https://192.0.2.15/` | **200**, unchanged |

The commented 8888 block was present on the RM10 at the same line numbers as in
the RM1 1.10.0 image, so the transform applied cleanly.

### Route 2 — VNC — ✅ WORKS

`kvmd --dump-config` **exit 0** with our `override.yaml` — this is the
validation that could not be done off-device, and it passed on the real unit.

```
kvmd-vnc status: running (pid:2051 2053)
tcp  :::5900  LISTEN
kvmd.apps.vnc.server  INFO --- Listening VNC on TCP [::]:5900 ...
```

RFB handshake from another machine returned `RFB 003.008
` — a real VNC
server, not just an open socket.

### De-cloud — already done on this unit

`/etc/glinet/gl-cloud.conf` reads `"enable": false` (with a stale `token` and
`uuid` from a previous binding), and neither `gl-cloud` nor `rtty` is running.
Nothing to change. Note `tailscaled` **is** running (100.64.0.62).

### Two bugs in my init script, found only by running it

1. **Missing `--run`.** `kvmd-vnc` refuses to start without it — *"to prevent
   accidental startup"* — exactly as `S98kvmd` passes `--run` to `kvmd`. The
   daemon started and instantly exited; `status` said `stopped`.
2. **`pgrep -f 'kvmd-vnc'` killed its own caller.** The invoking shell's argv
   contains `S99kvmd-vnc`, so `stop` matched and killed the SSH session running
   it (exit 255). Now matched on `"$DAEMON $DAEMON_ARGS"` with `$$`/`$PPID`
   excluded. The same flaw broke `status`, which reported FAIL for a healthy
   daemon.

Also hit: files edited on Windows picked up **CRLF**, making `#!/bin/sh
` an
invalid interpreter (`cannot execute: required file not found`). All shell
deliverables are now written with explicit LF.

### Route 3 — `apply_to_glkvm_safe.sh` — ✅ WORKS

Tested by pulling the device's own kvmd tree and pushing it back unchanged —
exercises backup / stage / atomic-swap with zero behavioural change.

```
>> [1/5] backing up remote tree ...
>> [2/5] pulling backup to ./backups/kvmd-192.0.2.15-20260901-112551.tar.gz ...
>> [3/5] uploading to staging dir ...
>> [4/5] swapping into place ...
>> [5/5] done.
```

After the swap: 226 files, `import kvmd` OK (4.82), `kvmd --dump-config` exit 0,
kvmd/nginx/janus all running, 443 + 8888 + 5900 all still serving. On-device
`diff -rq kvmd.old kvmd` reported **no content and no permission differences** —
byte-faithful.

(An apparent hash mismatch turned out to be my own error: comparing a
Windows-computed aggregate hash against a busybox-computed one. The on-device
`diff -rq` is the authoritative check, and it is clean.)

Two more bugs found by running it:

3. **The guard rejected the device's own tree.** It required `__init__.py`, but
   the device ships **sourceless `.pyc` only** (`__init__.pyc`, `aiogp.pyc`, …)
   — so a restore from a device backup was refused. Now accepts either.
4. **It ignored the dedicated keypair.** I had added key preference to
   `enable_classic_ui.sh` but not here, so it fell back to default keys and
   could not connect at all.

### Route 2 (IPMI half) — ❌ DOES NOT WORK on these units

```
ModuleNotFoundError: No module named 'pyghmi'
  File "/usr/lib/python3.12/site-packages/kvmd/apps/ipmi/server.py", line 34
```

`/usr/bin/kvmd-ipmi` ships, but **`pyghmi` does not**, and neither does
`ipmitool`. The daemon cannot start. My local dry-run *stubbed* `pyghmi`, so it
could never have caught this — a case where the local harness was too generous.

`pip 24.2` is on the device with 838 MB free, so `pip install pyghmi` would
likely make it viable — but that needs egress to PyPI, which cuts against the
de-clouding goal. Left uninstalled; flagged as a decision.

The failed attempt was cleaned up (`/etc/init.d/S99kvmd-ipmi` and
`/etc/kvmd/user/ipmi.enable` removed).

### The device ships sourceless bytecode

`/usr/lib/python3.12/site-packages/kvmd` contains **only `.pyc`** — no `.py`
anywhere. You cannot read kvmd's code on the device; the published GPLv3 repo
is the only source. It also means GL.iNet's own `apply_to_glkvm.sh` works by
letting pushed `.py` files shadow the `.pyc`, since CPython prefers a source
file when both are present.

### ⚠ The boot-order trap: init scripts in `/etc/init.d` NEVER autostart

The single most important operational finding, and it fails **silently**.

`/etc/init.d/rcS` (run from `/etc/inittab` at `::sysinit`) is stock buildroot:

```sh
for i in /etc/init.d/S??* ;do ... $i start ... done
```

The glob is expanded **once, at loop start**. But the writable overlay is not
mounted until `S08overlayfs`, which does a `pivot_root`. So at glob time the
root filesystem is the **read-only squashfs**, and any script you added lives
only in the overlay — invisible.

Proof on the device:

```
/rom/etc/init.d/S99kvmd-vnc : ABSENT   (overlay-only — never globbed)
/rom/etc/init.d/S98kvmd     : present  (base image — globbed, starts fine)
```

The symptom is confusing: a boot marker showed **`ENTER argv=stop` and nothing
else**. `rcK` runs at *shutdown*, with the overlay mounted, so it happily stops
a service that was never started. Files persist across reboot; the service just
never comes up.

### The supported extension point: `/etc/kvmd/user/scripts/`

`S99custom` **is** in the base image, so `rcS` sees it — and it iterates
`/etc/kvmd/user/scripts/S??*` at *its own* runtime, long after the overlay is
up:

```sh
start() { for i in /etc/kvmd/user/scripts/S??* ; do ... $i start ... done }
```

So the correct install path for anything of ours is
**`/etc/kvmd/user/scripts/`**, not `/etc/init.d/`. Verified by reboot: VNC came
back on its own, `Listening VNC on TCP [::]:5900` in the boot log.

### Full round trip — verified

The build path was exercised end to end, not just forwards:

```
provision → deprovision → provision → reboot → verify
```

- **`deprovision.sh --keep-key`** restored `/etc/kvmd/nginx-kvmd.conf`
  **byte-identical to the baseline captured before any change was made**
  (`diff` against `baseline/15-nginx-kvmd.conf.orig`: identical). `override.yaml`
  back to stock, hook and gate removed, no stray `/etc/init.d` copy, 8888 and
  5900 closed, 443 unaffected, `kvmd --dump-config` still exit 0.
- **`provision.sh` re-run from that reverted state** brought everything back —
  so the path works from stock, not merely idempotently on an already-configured
  unit.
- **A reboot after that** left 443, 8888, 5900 and SSH all serving.

The undo path is therefore proven, not assumed — which matters, since five of
the bugs in this session were found only by running things.

### Reboot persistence — verified

Three reboots. Everything survives (overlay is on `/userdata`, `mmcblk0p8`):

| Item | Survives reboot | Autostarts |
| --- | --- | --- |
| `/root/.ssh/authorized_keys` | ✅ | n/a |
| nginx 8888 block uncommented | ✅ | ✅ (nginx reads config at boot) |
| `/etc/kvmd/override.yaml` | ✅ | n/a |
| VNC via `/etc/kvmd/user/scripts/` | ✅ | ✅ |
| VNC via `/etc/init.d/` | ✅ (file) | ❌ **never** |

Note this proves persistence across **reboot**, not across an **OTA**. Assume an
update discards it and re-run `tools/provision.sh`.

### Correction: the `/etc/init.d/` inventory above is the RM1 image, not these units

`S22overlayfs`, `S10atomic_commit.sh` and `S99_bootcontrol` do **not exist** on
the RM10. The real list includes `S05async-commit.sh`, `S08overlayfs`,
`S09re-mountall.sh`, `S52lt86102_setup`, `S99custom`, `S99gl_kvm_monitor`,
`S99repeater`, `S99rkipc`, `S99test_cold_boot`, `S99test_mqtt`,
`S99test_plugin`. Treat the earlier list as RM1-only.

### Deviations from the RM1-derived expectations

| Expectation (from RM1 images) | Reality on RM10 |
| --- | --- |
| `ipmitool` present | **ABSENT** — so Route 2's IPMI half has no on-device client |
| LT6911C capture bridge | GSV1127X (`rm10rc` is in the cmd_map) |
| RV1126, armv7 | RV1126B+, **aarch64** |

Everything structural — both front ends present, the commented 8888 block, the
override wiring, `kvmd-vnc`/`kvmd-ipmi` present with no init scripts — held
exactly as predicted.

### Current state of `.15`

Left **enabled** (all reversible):

- classic PiKVM UI on 8888 — revert: `./tools/enable_classic_ui.sh 192.0.2.15 --revert`
- `/etc/kvmd/override.yaml` — revert: `cp /etc/kvmd/override.yaml.orig /etc/kvmd/override.yaml`
- `/etc/init.d/S99kvmd-vnc` + `/etc/kvmd/user/vnc.enable` — revert: delete both
- the SSH key in `/root/.ssh/authorized_keys`

Untouched originals are in `baseline/` and in `*.orig` files on the device.

---

## Verification status of the tooling

Nothing in `tools/` has run against a unit — SSH key auth is still unconfigured.
What HAS been verified, locally, against the real shipped files:

| Route | Check | Result |
| --- | --- | --- |
| 1 — classic UI | awk transform vs the real `nginx-kvmd.conf` of **all three** versions | braces balanced, 8888 live, 443 preserved, exactly one live `[::]:443`, idempotent |
| 2 — override | merge run through **kvmd's own loader** (`yamlconf.loader` + `yamlconf.merger.yaml_merge`, exactly as `apps/__init__.py:205`) against the real 1.10.0 `main.yaml` | override applied (vnc 5900, ipmi 623); **memsinks survived**; `hid.type=otg`, `atx.type=glatx`, `msd.type=otg`, 21-arg streamer cmd all preserved |
| De-cloud | `sed` vs the real `gl-cloud.conf` of all three versions | valid JSON out, `enable=false` |
| All scripts | POSIX `sh -n`, bashism scan | clean (the `function`/`==` hits are awk, inside a quoted program) |

Two defects were caught this way, both of which would have failed on hardware:

1. The awk anchored `#` to column 1. **1.3.0 indents the marker**
   (`        # server {`) — so on a 1.3.0-era config it silently did nothing.
   Since the units run an unidentified build, that mattered.
2. **1.3.0 writes `listen [::]:443 ssl;` inside the 8888 block** — a GL.iNet
   typo. Uncommented verbatim it binds a second server to `:443` beside the
   real one. Now rewritten to 8888 and reported.

**Full startup validation could NOT be completed off-device.** `_init_config`
imports and runs, but kvmd's validators assert that absolute Linux paths exist
(`/usr/share/kvmd/extras`, `/etc/kvmd/meta.yaml`, keymaps…), which on Windows
resolve to `D:\...`. Staging a fake tree got past `meta.yaml` and then stalled;
the attempt is not worth repeating. **So "the override merges correctly" is
proven; "kvmd will start with it" is not.** That matters: a config that merges
but fails validation stops kvmd, and with no SSH that means no web UI. Apply the
override on `.15` only, and be ready to revert via the web terminal.

The other thing that cannot be checked off-device: the units run **busybox awk**,
and the only ARM busybox available is inside the extracted rootfs. Mitigated by
design rather than by testing — `enable_classic_ui.sh` asserts `listen 8888`
actually went live, then runs `nginx -t`, and restores its backup if either
fails. A busybox-awk incompatibility surfaces as a clean no-op revert.

### Installing the key without a shell

`POST /api/system/ssh_key` (`api/system.py:1672`) writes
`/root/.ssh/authorized_keys` — `os.makedirs(ssh_dir, mode=0o700)`,
`chmod 0o600`, then `sync`. The web UI exposes this as an SSH-key field, so no
terminal is needed to bootstrap access.

**It opens the file with `"w"` — it overwrites rather than appends.** Any key
already there is replaced.

---

## Open questions

**Which build is on which unit — unresolved.** The units serve bundles that
appear in none of the three vendor images [measured]:

| Image | glweb bundles |
| --- | --- |
| 1.3.0 | `index-B8Luf3Jz.js` `index-BSr0T-4M.js` `index-CZ82wUA8.js` |
| 1.7.0 | `index-BitRlry9.js` `index-COsSr8yH.js` `index-OsZ6zXfv.js` |
| 1.10.0 | `index-DoTFM32C.js` `index-eqq7oJ5H.js` `index-ufafOX6U.js` |
| **observed** | `index-SI23g4RB.js` (`.13`/`.14`), `index-CddyYr6q.js` (`.15`) |

So all three units run firmware GL.iNet no longer distributes. Two consequences:

- The held images are recovery **targets**, not byte-exact restore points —
  flashing one moves a unit to a different version. `dd` each unit's own rootfs
  before modifying it if exact rollback matters.
- Everything marked [untested] was verified against 1.10.0, not against what the
  units actually run. Their configs may differ.

Settling it needs one shell: `cat /etc/os-release`, or the UI's About page.

**Does an OTA discard live changes?** `S22overlayfs` gives `/etc` a writable
overlay, so edits survive reboots. But `S10atomic_commit.sh` and
`S99_bootcontrol` point at atomic/A-B update handling. Assume an OTA wipes
config changes and plan to re-apply — that, not any difficulty in making the
changes, is the real argument for the image route.

---

## Third-party KVM stacks on this hardware — not a route

Asked and answered so it does not get re-investigated: **you cannot swap the
whole stack for a different open KVM project on an RM1.**

- **Upstream PiKVM** assumes a Raspberry Pi. The RM1's capture path is
  `rkipc` on an RV1126 behind an LT6911C — there is no Pi-shaped hardware for
  it to bind to.
- **[One-KVM](https://github.com/mofeng-git/One-KVM)** supports OneCloud,
  OEC/OECT, Phicomm N1 and VMs. No RV-class Rockchip, no RM1.

Porting either means rewriting exactly the video and HID glue GL.iNet already
publishes under GPLv3 — i.e. reimplementing the thing you already have the
source to. Modify the stock stack instead; that is what Routes 1-4 above are.

---

## Security observations

- `/api/redfish/v1` is served **unauthenticated** on all three units [measured].
  Service root only — `/redfish/v1/Systems` requires auth — so the exposure is
  version-fingerprinting, not control. Worth closing if these ever face a less
  trusted network.
- 2FA is **off** on all three [measured].
- The firmware ships `/etc/kvmd/vnc/ssl/server.key`. A TLS private key baked
  into a public firmware image is identical on every unit unless regenerated at
  first boot — worth checking on a real device before relying on VNC's VeNCrypt.
  That file, with the shipped `vncpasswd` / `ipmipasswd` / `htpasswd` templates,
  is under `extracted/` and therefore in this repo's git history. It is public
  vendor content, not a local secret, and this repo has no remote — but strip
  those paths before pushing anywhere.

---

## Corrections to earlier drafts of this file

Recorded because both were stated as fact here before being disproved, and
because the first changed the recommended route entirely.

1. **"GL.iNet replaced the contents of `/usr/share/kvmd/web` with their Vue
   build."** False. Both front ends ship in separate directories; the classic
   paths 404 only because that nginx context is not included. This is what
   turned "build the pug templates and deploy them" into "remove a comment."
2. **"VNC may show no video without memsink values from the unpublished
   main.yaml."** False. `main.yaml` already wires all three sinks, and the HTTP
   JPEG client is appended unconditionally regardless.
3. **"HDMI bridge: LT6911C or GSV1127X depending on board rev."** Imprecise.
   `upgrade.py:876-881` selects GSV1127X for `rm10rc`/`rm4pe` and GSV1127 for
   `rmq1`, defaulting to LT6911C — and `rm1` is not in the map, so the RM1 takes
   LT6911C.
4. **A bug in `tools/enable_classic_ui.sh`**, caught by testing before release:
   the transform keyed on `/^#\s*\}\s*$/` and terminated on the inner
   `location /connect {` brace, leaving the server block unclosed. Now tracks
   brace balance.

---

## Repository layout

```
firmware/    3 images (gitignored) + SHA256SUMS + fetch.sh + partitions-1.10.0.json
extracted/   3 rootfs squashfs (gitignored) + 110 config files from 1.10.0
vendor/      glkvm @3e8dd23 (1.10.0), pikvm-kvmd @387846d (v4.213) — gitignored
tools/       provision.sh, deprovision.sh, drift.sh, checkpoint.sh,
             restore-checkpoint.sh, apply-module.sh, msd.sh, panel.sh,
             panel.py, bake-image.sh, bake-image.remote.sh,
             uncomment-8888.awk, rk_pack.py, rk_sign.py, rkfw_scan.py,
             enable_classic_ui.sh, S99kvmd-{vnc,ipmi}, override.yaml.example,
             selftest.sh, verify-gates.sh, apply-vaulted-credential.ps1,
             apply_to_glkvm_safe.sh, webterm-snippets.md
patches/     modified kvmd modules, mirroring site-packages
extracted/   rootfs-RM10-1.10.0.squashfs (the bake base, from the RM10 image),
             rootfs-RM1-{1.3.0,1.7.0,1.10.0}.squashfs (RM1 — wrong product,
             kept for reference), rootfs-1.10.0/ config files (gitignored)
firmware/    vendor images + glkvm-RM10-1.10.0-provisioned.img (gitignored)
checkpoints/ restorable snapshots (gitignored)
wheels/      cross-built aarch64 wheels (gitignored)
```
