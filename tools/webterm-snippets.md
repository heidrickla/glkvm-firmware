# Paste-ready snippets for the GL-RM1 web terminal

SSH key auth is **not** configured on `.13`/`.14`/`.15` — all three answer
`Permission denied (publickey,password)`. So every script in `tools/` that uses
`ssh -o BatchMode=yes` cannot run yet.

You do not need SSH. The device runs `ttyd` (`/etc/init.d/S80ttyd`) behind the
normal web login, giving a **root bash shell** in the browser:

```
https://192.0.2.15/extras/webterm/ttyd
```

(the UI's Toolbox → Terminal → Access button goes to the same place)

Everything below is paste-able there. Ordered least to most invasive. Do `.15`
first — it is the guinea pig.

---

## 0. Baseline — answers the last open question

```sh
cat /etc/os-release; echo ---
cat /proc/gl-hw-info/model; echo ---
ls /usr/share/kvmd/glweb/assets/index-*.js; echo ---
pgrep -a rtty; pgrep -a gl-cloud; echo ---
cat /etc/glinet/gl-cloud.conf
```

The `index-*.js` line identifies the build. `.13`/`.14` serve
`index-SI23g4RB.js` and `.15` serves `index-CddyYr6q.js`; neither appears in
vendor images 1.3.0 / 1.7.0 / 1.10.0, so these units are on something GL.iNet
no longer publishes.

## 1. Enable the classic PiKVM UI on :8888

Backs up first, validates, auto-reverts if nginx rejects it.

```sh
CONF=/etc/kvmd/nginx-kvmd.conf
[ -f "$CONF.orig" ] || cp "$CONF" "$CONF.orig"
awk '
/^#[[:space:]]*server[[:space:]]*\{/ && !inblk {
    inblk=1; n=0; hit=0; depth=0; L[n++]=$0
    s=$0; sub(/^#/,"",s); depth += gsub(/\{/,"{",s) - gsub(/\}/,"}",s); next
}
inblk {
    L[n++]=$0
    if ($0 ~ /8888/) hit=1
    s=$0; sub(/^#/,"",s); depth += gsub(/\{/,"{",s) - gsub(/\}/,"}",s)
    if (depth <= 0) { for (i=0;i<n;i++) { l=L[i]; if (hit) sub(/^#/,"",l); print l } inblk=0 }
    next
}
{ print }
' "$CONF" > /tmp/n.new && mv /tmp/n.new "$CONF"

if nginx -t -p /etc/kvmd/nginx -c "$CONF"; then
    /etc/init.d/S99kvmd-nginx restart
    echo "OK -> https://$(hostname -i 2>/dev/null | awk '{print $1}'):8888/"
else
    cp "$CONF.orig" "$CONF"; echo "REVERTED - nginx rejected the config"
fi
```

Undo: `cp /etc/kvmd/nginx-kvmd.conf.orig /etc/kvmd/nginx-kvmd.conf && /etc/init.d/S99kvmd-nginx restart`

## 2. De-cloud

The UI toggle does this, but explicitly:

```sh
cp /etc/glinet/gl-cloud.conf /etc/glinet/gl-cloud.conf.orig
sed -i 's/"enable"[[:space:]]*:[[:space:]]*true/"enable": false/' /etc/glinet/gl-cloud.conf
/etc/init.d/S99gl-cloud stop
/etc/init.d/S99rtty stop
sleep 1
echo "--- should both be empty ---"; pgrep -a gl-cloud; pgrep -a rtty
cat /etc/glinet/gl-cloud.conf
```

`rtty` is a remote **shell** tunnel — confirm it is actually gone, do not trust
the toggle. This does not stop OTA checks (`fw.gl-inet.com`) or STUN
(`stun.l.google.com`); keep the gateway egress rule for those.

## 3. Install an SSH key (unblocks every script in tools/)

Replace the key with your own public key.

```sh
mkdir -p /root/.ssh && chmod 700 /root/.ssh
cat >> /root/.ssh/authorized_keys <<'KEY'
ssh-ed25519 AAAA...your-public-key-here... you@host
KEY
chmod 600 /root/.ssh/authorized_keys
/etc/init.d/S50dropbear restart
```

Then from your machine: `ssh root@192.0.2.15 true` should succeed silently,
and `tools/enable_classic_ui.sh`, `tools/apply_to_glkvm_safe.sh` etc. will work.

## 4. VNC / IPMI (optional, after 3)

Copy `tools/override.yaml.example` to `/etc/kvmd/override.yaml`, copy
`tools/S99kvmd-vnc` and `tools/S99kvmd-ipmi` to `/etc/init.d/`, then:

```sh
chmod +x /etc/init.d/S99kvmd-vnc /etc/init.d/S99kvmd-ipmi
mkdir -p /etc/kvmd/user
touch /etc/kvmd/user/vnc.enable        # gate: omit to leave it off
/etc/init.d/S99kvmd-vnc start
/etc/init.d/S99kvmd-vnc status
```

Add credentials to `/etc/kvmd/vncpasswd` before enabling `vncauth`; both
password files ship with comments only. Do **not** enable IPMI on an untrusted
network — the device's own `ipmipasswd` explains why the protocol is unsafe.

---

## Note on persistence

`/etc/init.d/S22overlayfs` means `/etc` is a writable overlay over a read-only
squashfs. Edits persist across reboots, but `S10atomic_commit.sh` and
`S99_bootcontrol` suggest atomic/A-B update handling — **assume an OTA wipes
all of this** and re-apply after any firmware update.
