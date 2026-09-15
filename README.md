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
  is kept; auto-restores the original if validation fails. It carries
  `kvmd.streamer.forever: true`, so kvmd's own streamer runs permanently and
  the classic UI, `/api/streamer/snapshot` and kvmd's OCR endpoint have a
  picture (vendor firmware never starts it).
- **VNC** on `:5900`, autostarting across reboots. H.264 for TigerVNC ≥ 1.13
  (keep the UI's video format on H.264; TigerVNC's Windows decoder only
  renders it up to 1080p), JPEG for everything else; both need the two
  `patches/kvmd/apps/vnc/` modules, because GL.iNet's ustreamer never writes
  the JPEG sink and their kvmd-vnc restarted the streamer on every
  re-negotiation.
- **Patched kvmd modules** — everything under `patches/`, then one kvmd restart
  for the whole batch.

⚠ Step 2 **aborts** if the device's `override.yaml` holds settings the repo copy
does not, listing them, rather than silently overwriting. Provisioning is
idempotent with respect to *the repo*, not the device — without that guard a
"no-op" re-run destroys any on-unit setting the repo never learned about. Pass
`--force` to overwrite anyway.

### 2. Undo

```sh
./tools/deprovision.sh 192.0.2.15
```

Restores from the `.orig` backups the provisioning made, and reverts each
patched module to its vendor `.pyc`. `--keep-key` leaves SSH access in place.

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
tools/
  provision.sh / deprovision.sh    apply or undo the whole config, idempotent
  msd.sh                           virtual media: upload / attach / detach an ISO
  apply-module.sh                  install / revert a patched or ported kvmd module
  panel.sh / panel.py              draw on the front LCD in GL.iNet's own style
  drift.sh                         read-only diff of a unit against a checkpoint
  checkpoint.sh / restore-...      snapshot + roll back site-packages and /etc/kvmd
  bake-image.sh (+ .remote.sh)     build a signed image with provisioning inside
  flash.sh                         flash a unit with it (irreversible; wipes the overlay); --from-vault for a stock unit, --check to prove the login first
  S24glkvm-config                  baked init script: re-applies our override, SSH key and VNC hook after GL.iNet's first-boot config restore
  memcheck.sh                      drive the VNC, snapshot, OCR and bitrate paths and watch each process's RSS for growth
  firmware-diff.py                 what changed between two firmwares, module by module
  ocr.sh / ocr-fetch.py            tesseract on the unit; read the attached host's screen
  vnc-probe.py / vnc-churn.py      what kvmd-vnc really sends; TigerVNC's re-negotiation storm
  vnc-h264-replay.py               replay a captured H.264 stream to a viewer: is the decoder at fault?
  vnc-h264-watch.py                what kvmd-vnc sends an H.264 viewer, rect by rect: key frames, flags, NAL types
  build-tigervnc-h264.sh           TigerVNC for Windows that decodes the unit's 1440p H.264 (contrib/ has the patch)
  edid.sh                          list / get / set the EDID the unit presents to the host (GL.iNet's presets, incl. 4K30)
  apply-vaulted-credential.sh      push the vaulted KVMD credential (Git Bash; one shell layer)
  uncomment-8888.awk               the classic-UI enable, shared by live + bake
  rk_pack.py / rk_sign.py          rebuild and sign a firmware image
  selftest.sh / verify-gates.sh    the CI checks, and proof they can fail
  publish-github.sh                the GitHub mirror: clone the forge, scrub with tools/publish/, prove, push
  verify-publish-gates.sh          proof the publish guard can fail: dry runs against a tampered map
  rkfw_scan.py                     inspect an RKFW container
  enable_classic_ui.sh             uncomment the :8888 server block
  S99kvmd-vnc / S99kvmd-ipmi       init scripts for the extra daemons
  apply-vaulted-credential.ps1     push the OpenBao credential to a device
  apply_to_glkvm_safe.sh           cherry-pick upstream kvmd changes
  override.yaml.example            the config we apply
patches/     modified kvmd modules, mirroring the site-packages tree; each
             file carries a banner saying what it changes and why; MANIFEST
             scopes each one to the firmware it applies to
contrib/     tigervnc-windows-h264/ — the TigerVNC decoder fix sent upstream as
             TigerVNC/tigervnc#2153, its regression test, and the build notes
docs/        firmware-diff-1.8.1-to-1.10.0.md — the measured delta (credentials redacted)
baseline/    pre-change state captured from .15
backups/     kvmd trees pulled off devices
checkpoints/ restorable snapshots (gitignored)
wheels/      cross-built aarch64 wheels (gitignored)
firmware/    RM1 + RM10 images, our signed build, SHA256SUMS, fetch.sh (gitignored)
extracted/   unpacked rootfs squashfs + config files (gitignored)
vendor/      gl-inet/glkvm and pikvm/kvmd source clones (gitignored)
```

`firmware/` holds both products. The RM1 images are historical — from before
shell access proved these units are **RM10**. The one to use is
`glkvm-RM10-1.10.0-0715-1784101556.img`; `glkvm-RM10-1.10.0-custom-signed.img`
is our own rebuild, signed with our key and accepted by the device's own
`check_image_validity`.

## GitHub mirror

[github.com/heidrickla/glkvm-firmware](https://github.com/heidrickla/glkvm-firmware)
is a scrubbed rewrite of the forge history, produced by `tools/publish-github.sh`:
lab addresses become RFC 5737 documentation ranges, hosts get generic names, a
captured device credential is redacted and a vendor private key from the
firmware image is dropped. Its SHAs differ from the forge's by design. Read the
script header before pushing anything to GitHub by hand.

## License

MIT for this repository's own code and documentation ([LICENSE](LICENSE)).
Third-party material keeps its own terms: `patches/kvmd` is GL.iNet's GPLv3
fork of PiKVM's `kvmd`, `contrib/tigervnc-windows-h264` is TigerVNC
(GPL-2.0-or-later), `extracted/` holds configuration files from GL.iNet's
firmware image, and `wheels/` carries prebuilt aarch64 wheels and Ubuntu arm64
libraries under their upstream licenses.