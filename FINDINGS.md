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
tools/       enable_classic_ui.sh, S99kvmd-{vnc,ipmi}, override.yaml.example,
             apply_to_glkvm_safe.sh, rkfw_scan.py, webterm-snippets.md
```
