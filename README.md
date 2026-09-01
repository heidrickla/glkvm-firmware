# glkvm-firmware

Modifying three GL.iNet **Comet Pro (GL-RM10)** KVM units at `192.0.2.13/.14/.15`.

Everything here changes the units in place. Full technical detail — with every
claim tagged `[measured]` / `[source]` / `[untested]` — is in
[FINDINGS.md](FINDINGS.md).

## Status

| Unit | State |
| --- | --- |
| `.15` | **Provisioned and verified.** Classic PiKVM UI, VNC, SSH key. Survives reboot. |
| `.13` | Untouched |
| `.14` | Untouched |

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

## What does not work

- **IPMI.** `/usr/bin/kvmd-ipmi` ships, but `pyghmi` does not and neither does
  `ipmitool`, so the daemon cannot start. `pip` is on the device if you decide
  egress to PyPI is acceptable.
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
