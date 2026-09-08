#!/bin/sh
# apply-vaulted-credential.sh - put the vaulted KVMD credential onto a unit.
#
#   ./tools/apply-vaulted-credential.sh <device-ip> --from-vault
#   printf '%s\n%s\n' "$USER" "$PASS" | ./tools/apply-vaulted-credential.sh <device-ip>
#
# Writes the TWO places that must agree:
#   1. kvmd-htpasswd  (the login credential, stored {SSHA512})
#   2. the right-hand side of /etc/kvmd/ipmipasswd  (admin:admin -> user:pass)
# then re-derives the hash on the device and compares -- the only check that
# proves both places hold the same value.
#
# WHY A SHELL TWIN OF apply-vaulted-credential.ps1
#
# The PowerShell one is correct when run from PowerShell. Invoked from Git Bash
# through ob.ps1 (bash -> powershell.exe -> ob.ps1 -> powershell -File) the
# double quotes inside its remote here-string were stripped on the way through,
# the verification Python arrived as `open(/etc/kvmd/user/htpasswd)` and
# failed to parse, and the run stopped with htpasswd written but ipmipasswd
# not -- the exact out-of-sync state the tool exists to prevent. This version
# has one shell layer and sends every remote script as a quoted heredoc.
#
# --from-vault reads KVMD-HT-USER / KVMD-HT-PASSWORD from the OpenBao mirror
# on 192.0.2.161 via `sudo openbao-get`, which prints one value to stdout.
# The values travel pipe-to-pipe and are never echoed, logged or put on argv.
#
# THE VALUE NEVER APPEARS IN OUTPUT. Lengths, booleans and the hash scheme are
# all this prints. A leak means a rotation.

set -eu

IP="${1:-}"
MODE="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
KEY="$HERE/../.ssh-glkvm/id_ed25519"
VAULT_HOST="claude@192.0.2.161"
PROJECT="glkvm"

die() { echo "ERROR: $*" >&2; exit 1; }
ok()  { printf '  ok   %s\n' "$*"; }

[ -n "$IP" ] || die "usage: $0 <device-ip> [--from-vault]"
echo "$IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || die "'$IP' is not a bare IPv4 address"

SSH="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@$IP"
$SSH -n true 2>/dev/null || die "cannot ssh to $IP"

# ---------------------------------------------------------------- obtain
TMP=$(mktemp 2>/dev/null) || TMP="${TMPDIR:-/tmp}/cred.$$"
chmod 600 "$TMP" 2>/dev/null || true
trap 'rm -f "$TMP"' EXIT INT TERM

if [ "$MODE" = "--from-vault" ]; then
    for k in KVMD-HT-USER KVMD-HT-PASSWORD; do
        # One value per call, straight into the temp file, CR stripped in case
        # anything upstream ever runs through a Windows pipe.
        ssh -n -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$VAULT_HOST" \
            "sudo openbao-get $PROJECT $k" 2>/dev/null | tr -d '\r' | head -1 >> "$TMP" \
            || die "could not read $PROJECT/$k from the vault"
    done
    ok "read $PROJECT/KVMD-HT-USER and KVMD-HT-PASSWORD from the vault (values not shown)"
else
    tr -d '\r' | head -2 > "$TMP"
fi

U=$(sed -n 1p "$TMP"); P=$(sed -n 2p "$TMP")
[ -n "$U" ] && [ -n "$P" ] || die "need a user on line 1 and a password on line 2"
plen=${#P}
[ "$plen" -ge 10 ] && [ "$plen" -le 63 ] \
    || die "password is $plen chars; kvmd requires 10-63 to SET one (login accepts 5+)"
printf '%s' "$P" | grep -qE '^[ -~]+$' || die "password is not printable ASCII"
# Firmware 1.10.0 adds complexity rules in validators/auth.valid_new_passwd.
for cls in '[A-Z]' '[a-z]' '[0-9]' '[^A-Za-z0-9]'; do
    printf '%s' "$P" | grep -q "$cls" || die "password lacks a character class 1.10.0 requires: $cls"
done
echo "  user '$U', password $plen chars, all four classes present"

# ---------------------------------------------------------------- apply
# One remote script does both writes so they cannot drift apart. The values
# go over stdin; the script text carries no secret.
echo ">> writing both places on $IP"
printf '%s\n%s\n' "$U" "$P" | $SSH 'read -r U; read -r P
U=$(printf "%s" "$U" | tr -d "\r"); P=$(printf "%s" "$P" | tr -d "\r")
if printf "%s" "$P" | kvmd-htpasswd set "$U" -i >/dev/null 2>&1 \
   || printf "%s" "$P" | kvmd-htpasswd add "$U" -i >/dev/null 2>&1; then
    echo "  ok   kvmd-htpasswd written"
else
    echo "  FAIL kvmd-htpasswd rejected the password" >&2; exit 1
fi
cp /etc/kvmd/ipmipasswd /etc/kvmd/ipmipasswd.bak
python3 - "$U" "$P" <<PY
import sys
u, p = sys.argv[1], sys.argv[2]
path = "/etc/kvmd/ipmipasswd"
out = []
for line in open(path):
    if line.strip() and not line.lstrip().startswith("#"):
        out.append("admin:admin -> %s:%s\n" % (u, p))
    else:
        out.append(line)
open(path, "w", newline="\n").write("".join(out))
PY
chmod 600 /etc/kvmd/ipmipasswd
echo "  ok   ipmipasswd mapping written"' || die "apply failed on the device"

# ---------------------------------------------------------------- verify
echo ">> verifying on the device (hash re-derived, never the value)"
printf '%s\n%s\n' "$U" "$P" | $SSH 'read -r U; read -r P
python3 - "$U" "$P" <<PY
import sys, base64, hashlib
u, p = sys.argv[1], sys.argv[2]
line = [l for l in open("/etc/kvmd/user/htpasswd") if l.startswith(u + ":")][0].strip()
h = line.split(":", 1)[1]
# kvmd stores {SSHA512}: base64(sha512(password + salt) + salt), 8-byte salt.
if not h.startswith("{SSHA512}"):
    print("  FAIL unknown hash scheme %s" % h[:10]); raise SystemExit(1)
raw = base64.b64decode(h[9:]); digest, salt = raw[:64], raw[64:]
ok_ht = hashlib.sha512(p.encode() + salt).digest() == digest
m = [l for l in open("/etc/kvmd/ipmipasswd") if l.strip() and not l.lstrip().startswith("#")][0].rstrip("\n")
ok_ip = m.endswith(":" + p) and "\r" not in m
print("  htpasswd {SSHA512} matches : %s" % ok_ht)
print("  ipmipasswd matches         : %s" % ok_ip)
raise SystemExit(0 if (ok_ht and ok_ip) else 1)
PY' || die "VERIFICATION FAILED - the two places may disagree"

echo ""
echo "  done - both places verified in sync."
# Say whether the credential is actually in force: an anonymous
# /api/auth/check answers 200 only when kvmd.auth.enabled is false.
anon=$($SSH -n 'curl -sk -m 8 -o /dev/null -w "%{http_code}" https://127.0.0.1/api/auth/check' 2>/dev/null | tr -d '\r\n')
case "$anon" in
    200) echo "  NOTE: auth is disabled on this unit (kvmd.auth.enabled: false), so the"
         echo "        credential is not exercised by the UI/API until that is reverted." ;;
    401|403) echo "  auth is enabled on this unit: the UI and API now require this credential." ;;
    *) echo "  (could not tell whether auth is enabled: anonymous /api/auth/check gave HTTP ${anon:-none})" ;;
esac
