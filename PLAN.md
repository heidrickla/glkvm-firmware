# GL-RM1 Comet — firmware modification plan

Three units, two firmware builds, goal is de-clouding and the ability to modify
firmware. Written before any shell access, so everything below is a hypothesis
with a test attached rather than a set of instructions.

> **⚠ PARTLY SUPERSEDED — read [FINDINGS.md](FINDINGS.md) first.**
>
> This document is kept as the original reasoning. Several of its hypotheses
> have since been tested and retired:
>
> - **The vendor image is not encrypted.** It is a stock Rockchip `RKFW`
>   container, opened locally with no keys. The "two decrypters" note below
>   does not apply to it.
> - **No reflash is needed for de-clouding**, or for most changes. GL.iNet
>   publishes `kvmd` under GPLv3 with a supported push script, and the classic
>   PiKVM UI is already installed on the devices — disabled by a comment.
> - **Stage 1 (SSH) is not the way in.** Key auth is unconfigured on all three
>   units; the device's own web terminal gives root instead.
> - Open questions 3 and 4 are answered (buildroot/OpenWrt hybrid; squashfs
>   with a writable overlay). Question 1 is still open — the units run a build
>   GL.iNet no longer distributes.
>
> The parallel de-cloud track at the end still stands unchanged.

## What is known so far

Measured from the LAN, unauthenticated:

| | |
| --- | --- |
| Units | `192.0.2.13`, `192.0.2.14`, `192.0.2.15` |
| Web stack | nginx 1.26.2, HTTP 301 → HTTPS, self-signed cert |
| Front end | Vue SPA, title `GLKVM`, source path `gl-kvm-frontend`, edited Dec 2025 |
| Builds | `.13`/`.14` serve `index-SI23g4RB.js`; `.15` serves `index-CddyYr6q.js` |
| API | `/api/info` exists, returns **401** — auth required |
| SSH | open on all three |

Referenced in the web bundles: `gl-inet.com`/`.cn`, `glkvm.com`/`.cn`,
`docs.gl-inet.com`/`.cn`, `zos.alipayobjects.com`, `my.zerotier.com`,
`login.tailscale.com`. Keyword density suggests an active OTA path
(`ota` ×180, `upgrade` ×199, `firmware` ×64, `heartbeat` ×37).

**Not known:** which build is newer, what the device actually contacts (front-end
references are not backend behaviour), the SoC, the flash layout, or whether the
on-device filesystem is encrypted at rest.

## Governing principle

**The download → modify → re-upload round trip has already been done on this
hardware.** That is the primary path, not a hypothesis. It also means the most
important unknown is already answered: the device **accepts a modified image**,
so the update path either does not verify a signature or the verification was
satisfied.

That is the single biggest risk in any firmware project, and it is retired.

So the work is:

1. Obtain the image
2. Decrypt it — with the **second** decrypter, not the first (see below)
3. Modify
4. Repack and upload through the normal update mechanism

**SSH is still worth having**, but for reconnaissance rather than as the route
in: it tells us which decrypter the updater actually calls, where the endpoints
live, and whether a change can be made live on the filesystem instead of by
reflashing. For de-clouding specifically, a live edit may be the whole answer
and avoids the round trip entirely.

## Roles for the three units

| Unit | Role |
| --- | --- |
| `.15` | **Guinea pig.** Not the one in daily use. Everything destructive happens here. |
| `.13` / `.14` | **Reference and spare.** One stays untouched as a known-good comparison and a source for restoring `.15`. |

Two firmware builds across three units is an advantage: diffing versions of the
same product is often how the packaging scheme becomes obvious, because what
changed between them exposes the structure.

---

## Stage 0 — Recovery first

**Do not modify anything until a restore path exists.** This is the step that
decides whether a mistake costs an hour or a device.

- [ ] Note exact firmware versions from each UI (settle which build is which)
- [ ] Download the vendor firmware images for those versions while they are still published
- [ ] Confirm a factory-reset procedure exists and works (reset button, recovery mode?)
- [ ] Check whether GL.iNet publishes a recovery/uboot flashing tool for this model

Serial console is the usual last resort when a device will not boot, so
identifying the UART pads early is worth the ten minutes even if unused.

## Stage 1 — SSH

```bash
ssh root@192.0.2.15        # try root first, then admin
```

Credentials are commonly the web admin password. If that fails, look for an
"enable SSH" toggle in the UI, and check whether SSH is on a non-standard port
or restricted by interface.

**If this works, stages 2 and 3 are mostly reading files, and the project gets
much easier.**

## Stage 2 — Reconnaissance

With a shell, answer these in order. Capture everything to a file — this is the
baseline you will diff against later.

```bash
# What is this?
uname -a; cat /etc/os-release; cat /proc/cpuinfo | head -20

# How is storage laid out? Tells us what a flash dump would involve.
cat /proc/mtd; cat /proc/partitions; mount; df -h

# What is running, and what talks to the network?
ps w
netstat -tulpn 2>/dev/null || ss -tulpn

# Is this OpenWrt-derived or something else? Changes everything downstream.
which opkg apt uci; ls /etc/init.d/ /etc/config 2>/dev/null
```

Then find the update and cloud machinery:

```bash
# The OTA client and anything that looks like it
find / -xdev \( -iname '*ota*' -o -iname '*upgrade*' -o -iname '*cloud*' \) 2>/dev/null

# Where do the endpoints live? Compare against the web-bundle list.
grep -rIl --exclude-dir=/proc -e 'gl-inet' -e 'glkvm' -e 'alipayobjects' / 2>/dev/null

# What serves /api/info?
netstat -tulpn | grep -E ':80|:443'
```

**Key question for de-clouding:** which process holds the outbound connections,
and is there a config file or init script that disables it cleanly? Turning off
a service is far better than blocking it at the firewall — though we will do
both, belt and braces.

## Stage 3 — Getting the image

Two routes; prefer the first.

**3a. From the running system.** If `/proc/mtd` or `/proc/partitions` shows the
layout, the partitions can be read directly:

```bash
dd if=/dev/mtdblock0 of=/tmp/mtd0.bin        # or the relevant block device
```

Copy off with `scp`. This gives the image **as stored**, which is typically
decrypted — sidestepping the packaging encryption entirely.

**3b. Hardware.** If the running system will not cooperate, read the flash off
the board with a CH341A (SPI) or an eMMC reader. Slower, needs the case open,
but it cannot be prevented in software.

Once an image exists, `binwalk` it and mount the filesystem.

### Prior knowledge from an earlier attempt

Second-hand, from a previous session on this hardware. Treat as a strong hint
about where to look rather than as established fact — but both points change how
stage 3 should be run.

**1. There are TWO decrypters, and the obvious one is the wrong one.**
The earlier attempt reached for the first decrypter it found and got nowhere; a
second one worked. So:

- **Enumerate all of them before trying any.** Do not stop at the first match.
  ```bash
  # anything that could decrypt, not just the obviously-named one
  find / -xdev -type f -perm -u+x 2>/dev/null | xargs -r file 2>/dev/null | grep -i 'ELF' | cut -d: -f1 \
    | xargs -r grep -lEi 'aes|decrypt|cipher|openssl|mbedtls|wolfssl' 2>/dev/null
  ```
- Note **which binary calls which**, and which one the updater actually invokes —
  the one on the real update path is the one that matters. The other may be
  legacy, a different product's leftovers, or for a different partition.
- Record which one works, so this is not rediscovered a third time.

**2. The read changed between attempts — and the images came off the devices
themselves, not from GL.iNet.** That rules out per-download nonce encryption and
points squarely at reading a **live system that is still writing**: logs,
config, state, wear levelling. Do not assume a bad dump.

Get a quiet read rather than fighting the variation:

```bash
sync                                    # flush pending writes first
mount -o remount,ro /                   # if the rootfs is writable, freeze it
/etc/init.d/<noisy-service> stop        # logging, cloud client, anything chatty
```

Prefer reading the **block device** over copying files, and prefer a
**read-only partition** (squashfs rootfs, kernel) where nothing should change at
all. That partition doubles as the control described below.

Also worth noting: pulling files off the device and putting them back implies a
working transfer path already existed — almost certainly SSH/SCP. If so, **Stage 1
is already solved** and the credentials are known.

- **Take at least two dumps and diff them.**
  ```bash
  dd if=/dev/mtdblock0 of=/tmp/a.bin; sync; sleep 30
  dd if=/dev/mtdblock0 of=/tmp/b.bin
  cmp -l /tmp/a.bin /tmp/b.bin | wc -l        # how much moved
  ```
- The regions that differ are **volatile state**; the regions that do not are the
  firmware. That diff is useful in itself — it separates code from data without
  needing to parse anything.
- Prefer dumping a **read-only partition** (squashfs rootfs, kernel) where
  nothing should change between reads. If *that* varies, the problem is the read
  path, not the system — at which point use hardware rather than `dd`.
- Hash every dump (`sha256sum`) and keep them. A dump you cannot identify later
  is worse than no dump.

## Stage 4 — Modification

Only meaningful once stage 3 succeeds and the update mechanism is understood.

The realistic questions:
- Does the updater **verify a signature**, or only decrypt? Decryption alone is
  not integrity — if it does not check a signature, a modified image installs.
- Is there an **unsigned/debug path** (recovery mode, USB update, uboot)?
- Can the change be made **live on the filesystem** instead of by reflashing?
  For de-clouding, disabling a service and editing a config is usually enough,
  and survives without repacking anything.

**Try the live-filesystem route before the reflash route.** It is reversible,
needs no key, and for this goal may be the whole answer.

## Parallel track — de-cloud now, independent of all the above

This does not need firmware access and should not wait for it:

1. Pull the real flow logs for `.13`/`.14`/`.15` — what they actually contact,
   as opposed to what the front end mentions
2. Default-deny WAN egress for all three at the gateway
3. Verify the KVMs still work fully over the LAN
4. Re-check the flows to confirm silence

A firewall rule beats a settings toggle because a firmware update cannot quietly
undo it.

## Things that would change the plan

- **SSH refuses all credentials** → UART becomes the primary route, and stage 1
  turns into a hardware job.
- **Filesystem is read-only squashfs with no writable overlay** → live
  modification is out, and reflashing becomes mandatory.
- **The updater checks signatures** → modified images will not install by the
  normal path, and the target becomes uboot or a recovery mode instead.
- **It is not OpenWrt-derived** → the usual GL.iNet lore does not apply and this
  becomes generic embedded Linux work.

## Open questions to resolve first

1. Which firmware build is on which unit? (read from each UI)
2. Does SSH accept the web admin password?
3. OpenWrt-derived or custom Linux?
4. Is the root filesystem writable?
