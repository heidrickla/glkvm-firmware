# Feature ideas for the Comet KVMs

A running list of things we *could* add, compiled as we go. Nothing here is
done — see [FINDINGS.md](FINDINGS.md) for what actually is.

Each item notes what it costs and whether the pieces are already on the device,
because a surprising amount of this ships disabled rather than absent.

---

## Already on the device, just switched off

These need configuration, not code. Highest value per hour.

### Mass Storage Device (virtual CD/USB) — `msd`
`main.yaml` already sets `msd: {type: otg}`. Lets you mount an ISO over USB and
boot the attached machine from it — OS installs and rescue media without
physically walking a USB stick over. Arguably the single most useful KVM
feature we are not using.

### EDID spoofing — `kvmd-edidconf`
`/etc/kvmd/edid.json` and `switch-edid.hex` ship, and `api/upgrade.py` knows how
to flash the capture bridge's EDID. Lets you lie to the host about the attached
monitor — force a resolution, stop a headless server dropping to 640×480, or
make a machine believe a display is present at boot.

### Session recording — `api/recorder.py`
A recorder module is present. Capturing a session as evidence of what was done
to a machine is genuinely useful for anything audited.

### TOTP two-factor — `api/twofa.py`
`/etc/kvmd/user/totp.secret` exists and `two_step_login` is in the resolved
config. Worth having *before* re-enabling auth.

### Wake-on-LAN
kvmd auto-injects a `__wol__` GPIO driver (`apps/__init__.py:249-257`) and
`/etc/kvmd/user/wol_list.json` exists. Free power-on for anything on the LAN,
no ATX wiring needed.

### The classic UI's own extras
Now that it is live on `:8888`: macros, text paste into the target, keyboard
shortcuts, and a health panel. All shipped, none surfaced by GL.iNet's UI.

### OLED front panel — `kvmd-oled`
`/usr/bin/kvmd-oled` ships. If the RM10 has a panel, it can show IP, power
state, and load.

### Fan control
`/etc/kvmd/fan` exists. Worth a look if these ever sit somewhere warm.

---

## Small builds on top of what we have

### Power control from real hardware — `ugpio`
~20 drivers ship: `tesmart`, `extron`, `ezcoo`, `hue`, `anelpwr`, `wol`,
`ipmi`, `cmd`, `cmdret`, `pway`, `xh_hk4401`, `tesmart`, `servo`, `pwm`. We
proved the mechanism with a `cmd` driver. Wire a real smart plug or KVM switch
and the buttons appear in both UIs.

### Multi-port switch support — `api/switch.py`
kvmd models a downstream KVM switch. Three units plus a switch could front many
more machines than three.

### Redfish automation
Now that Redfish works, it slots straight into Ansible
(`community.general.redfish_command`), Zabbix, or a Home Assistant switch. A
one-line HA integration gives you power control for the attached host next to
everything else in the house.

### Serial console — `api/serial.py` + SOL
A `serial` API module ships. Combined with a UART to the host, that is a real
out-of-band console — the thing IPMI's SOL was supposed to give us.

### SNMP — `S59snmpd`
An SNMP daemon is running and nobody mentions it. Free monitoring integration
if Zabbix already speaks SNMP in your estate.

---

## Bigger, but the groundwork is done

### Bake provisioning into firmware
We can build and sign images the device verifies. A custom image could ship the
classic UI, VNC, our SSH key and config **already enabled** — so a factory reset
or OTA lands in the desired state instead of stock. This is the only route that
survives an OTA.

### Fleet provisioning
`provision.sh` is idempotent and takes an IP. Trivially extends to a loop over
an inventory, so new units join fully configured.

### Config drift detection
We hold checkpoints and a `pip freeze`. A scheduled diff against a known-good
checkpoint would catch an OTA quietly reverting our changes — which we know it
will, since `updateEngine` runs with `--n` (format overlay).

### Central relay
`glkvm-relay` is up. Onboarding all three units gives one pane of glass, and it
also accepts generic Linux hosts, not just Comets.

### Upstream kvmd features we do not have
We are on the 4.82 fork; upstream is 4.213. Post-fork additions include
`nbd` (network block device MSD), `ugpio/amt.py` (Intel AMT), and
`auth/onetime.py`. Cherry-picking is plausible via `apply_to_glkvm_safe.sh`,
though GL.iNet's hardware glue would need care.

---

## Security hardening (deferred until the build settles)

Listed here so it is not forgotten — Lewis: *"we will tighten security when we
are done."*

- **Re-enable auth.** `kvmd.auth.enabled: false` currently means the API,
  both UIs, and Redfish power control need **no credentials** on the LAN. The
  credential is vaulted and in sync, so this is a one-line revert.
- **Close unauthenticated Redfish.** Anyone on the LAN can power-cycle the
  attached machine today.
- **Delete the default IPMI entry** (`admin:admin`) — it authenticates on a
  stock unit.
- **Trim the tunnels.** Tailscale, NetBird, ZeroTier and Cloudflare are all
  running; each is outbound. Pick one.
- **Egress deny at the gateway** — OTA (`fw.gl-inet.com`) and STUN
  (`stun.l.google.com`) are not covered by the de-cloud toggle.
- **Rotate the signing key** if the build VM is ever shared.
