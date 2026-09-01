# glkvm-firmware

Modifying three GL.iNet **Comet Pro (GL-RM10)** KVM units at `192.0.2.13/.14/.15`.

Everything here changes the units in place. Full technical detail — with every
claim tagged `[measured]` / `[source]` / `[untested]` — is in
[FINDINGS.md](FINDINGS.md).

## Status

| Unit | State |
| --- | --- |
| `.15` | **All 10 routes done.** Classic UI, VNC, IPMI, passwordless auth, ugpio, custom signed firmware built. Survives reboot. |
| `.13` | Untouched — **kept stock as the baseline reference** |
| `.14` | Untouched, available |

### Supporting machines

| Host | Purpose |
| --- | --- |
| `glkvm-build` 192.0.2.160 | firmware repack toolchain (squashfs-tools). **Non-persistent disk** — work is discarded at power-off |
| `glkvm-relay` 192.0.2.140 | self-hosted `glkvm-cloud` relay. Persistent disk. Web UI on 443 |

Both are Ubuntu 24.04 clones of `Ubuntu-2404-template`, seeded with a NoCloud
`CIDATA` ISO and built via PowerCLI under `ob.ps1 esxi`.

## The build path

### 0. One-time: SSH key

The units use dropbear with **no key configured** out of the box, and fw 1.8.1's
web UI has **no SSH-key field**. Bootstrap it from the browser console while
logged into the KVM UI (this uses your existing session — no password is handled
by any tooling):

```js
(async () => {
  const key = '<paste .ssh-glkvm/id_ed25519.pub here>';
  const p = await fetch('/api/system/ssh_key', {method:'POST', body: key + '\n'});
  console.log(p.status, await p.text());
})()
```

`POST /api/system/ssh_key` **overwrites** `authorized_keys` — it does not append.

The keypair lives in `.ssh-glkvm/` (gitignored). Regenerate with
`ssh-keygen -t ed25519 -N "" -f .ssh-glkvm/id_ed25519`.

### 1. Provision

```sh
./tools/provision.sh 192.0.2.15
```

Idempotent, verifies every step, and refuses hostnames (mDNS can hit the wrong
unit). It enables:

- **Classic PiKVM UI** on `:8888` — GL.iNet ships it installed but commented out
  in nginx. The Vue UI is untouched on `:443`.
- **`/etc/kvmd/override.yaml`** — validated with `kvmd --dump-config` before it
  is kept; auto-restores the original if validation fails.
- **VNC** on `:5900`, autostarting across reboots.

### 2. Undo

```sh
./tools/deprovision.sh 192.0.2.15
```

Restores from the `.orig` backups the provisioning made. `--keep-key` leaves SSH
access in place.

## The one trap worth knowing

**An init script in `/etc/init.d/` will never start at boot.** `rcS` expands
`for i in /etc/init.d/S??*` *once*, before `S08overlayfs` mounts the writable
overlay — so anything you add is invisible to it. It still gets `stop` at
shutdown via `rcK`, which is a maddening half-symptom.

Install into **`/etc/kvmd/user/scripts/`** instead. `S99custom` is in the
read-only base image and iterates that directory at its own runtime. That is
GL.iNet's supported extension point, and `provision.sh` uses it.

## Building custom firmware

The whole RKFW container is decoded and we hold our own signing key, so custom
images verify natively on the device.

```sh
# on glkvm-build (192.0.2.160), which has mksquashfs:
python3 rk_pack.py rm10.img out.img rootfs rootfs-mod.bin   # repack
python3 rk_sign.py out.img glkvm-signing.priv               # sign + fix MD5
```

`tools/rk_pack.py --selftest` reassembles the vendor image **byte-for-byte**, so
the packer is verified against ground truth before you trust it with changes.

Verified on-device: `check_image_validity` → `Valid`, and
`fwtools verify <img> <our pubkey>` → `Signature: OK`.

**Keys** are in `.signing-key/` (gitignored). The image carries our public key at
`/etc/firmware/key/public.raw`, with GL.iNet's kept as `public.raw.glinet`.

⚠ **Bootstrap:** the *first* flash still needs `?skip_verify=true`, because the
key currently installed on the device is GL.iNet's. After that, ours is in place.

⚠ **A flash wipes the overlay** (`updateEngine` runs with `--n`), including
`/root/.ssh/authorized_keys` — you would re-bootstrap SSH via the browser
console afterwards.

## What does not work

- **IPMI is running but incomplete.** `pyghmi` was installed and the daemon
  listens on UDP 623, but `/etc/kvmd/ipmipasswd` still holds the shipped
  template entry, whose KVMD-side password is stale — so calls reach kvmd and
  get `401`. Completing it needs the real KVMD admin password.
  ⚠ The shipped `admin:admin` entry **does** pass IPMI authentication. Delete it
  once the real entry is in place.
- **Replacing the stack** with upstream PiKVM or One-KVM — neither supports this
  SoC. Modify the shipped GPLv3 `kvmd` instead.

## Layout

```
tools/       provision.sh, deprovision.sh, enable_classic_ui.sh,
             S99kvmd-vnc, override.yaml.example, apply_to_glkvm_safe.sh,
             rkfw_scan.py, webterm-snippets.md
baseline/    pre-change state captured from .15
backups/     kvmd trees pulled off devices
firmware/    ⚠ RM1 images — WRONG PRODUCT for these units. Do not flash.
vendor/      gl-inet/glkvm and pikvm/kvmd source clones (gitignored)
extracted/   unpacked RM1 rootfs + its config files
```

`firmware/` and `extracted/` are RM1, from before shell access proved these are
RM10s. They remain useful for reading GL.iNet's code, not for flashing.
