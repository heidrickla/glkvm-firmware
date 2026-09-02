<#
.SYNOPSIS
  Apply the KVMD credential from the OpenBao `glkvm` project to a Comet KVM.

.DESCRIPTION
  Reads KVMD-HT-USER / KVMD-HT-PASSWORD (injected as env vars by ob.ps1) and
  writes them to the TWO places that must stay in sync on the device:

    1. kvmd-htpasswd  (the actual login credential)
    2. the right-hand half of /etc/kvmd/ipmipasswd  (admin:admin -> user:pass)

  If only one is updated, IPMI still completes its RMCP handshake and then
  silently 401s against kvmd -- a failure that reads like an IPMI fault rather
  than a stale mapping.

  Values move via stdin only: never on argv, never printed.

.NOTES
  Traps this guards against, all met for real on 2026-09-01:

  * CR INJECTION. PowerShell appends a carriage return to anything it pipes.
    CR is 0x0D, outside the printable-ASCII class kvmd requires, so
    kvmd-htpasswd rejects the password as "not a valid passwd characters" --
    which reads as a charset problem rather than a line-ending one. BOTH writes
    go through one here-string that strips CR on the FAR side, where quoting is
    safe. Do not "simplify" either back into a direct PowerShell pipe.

  * PASSWORD LENGTH. kvmd's SET rule is stricter than its LOGIN rule.
    validators/auth.py: login 5-63 chars, setting 10-63. A 9-char password
    authenticates but cannot be set. Checked up front so the failure is legible.

  * VERIFY, DO NOT TRUST THE EXIT CODE. An earlier version reported success
    while writing a corrupted password, because a mangled `tr -d` still exited
    zero. The last step re-derives the hash and compares -- the only check that
    actually proves both places agree.

.EXAMPLE
  ob.ps1 glkvm -- pwsh -NoProfile -File tools\apply-vaulted-credential.ps1 192.0.2.15
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DeviceIp,
    [string]$KeyPath = ""
)

$ErrorActionPreference = 'Stop'

# RUN THIS FROM POWERSHELL, NOT THROUGH GIT BASH. Invoked as
#   bash -> powershell.exe -Command -> ob.ps1 -> powershell -File <this>
# two things went wrong on 2026-09-01: $PSScriptRoot was empty (the key path
# became "\..\.ssh-glkvm\id_ed25519"), and the double quotes inside the remote
# here-string below were stripped in transit, so the verification Python
# arrived as open(/etc/kvmd/user/htpasswd) and failed to parse -- AFTER the
# htpasswd write and BEFORE the ipmipasswd write, leaving the two places out of
# sync. From Git Bash use tools/apply-vaulted-credential.sh --from-vault, which
# has a single shell layer. The key path below no longer depends on
# $PSScriptRoot, and an empty one is a hard error rather than a relative guess.
if (-not $KeyPath) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $KeyPath = Join-Path $scriptDir '..\.ssh-glkvm\id_ed25519'
}
if (-not (Test-Path $KeyPath)) { throw "ssh key not found at '$KeyPath' - pass -KeyPath explicitly" }

if ($DeviceIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
    throw "'$DeviceIp' is not a bare IPv4 address (refusing hostnames - mDNS can hit the wrong unit)"
}

$u  = ${env:KVMD-HT-USER}
$pw = ${env:KVMD-HT-PASSWORD}
if (-not $u -or -not $pw) {
    throw "KVMD-HT-USER / KVMD-HT-PASSWORD not in the environment - run me under: ob.ps1 glkvm -- ..."
}

if ($pw.Length -lt 10 -or $pw.Length -gt 63) {
    throw (("vaulted password is {0} chars; kvmd requires 10-63 to SET one " +
            "(validators/auth.py valid_new_passwd). Vault a longer value.") -f $pw.Length)
}
if ($pw -notmatch '^[\x20-\x7e]+$') {
    throw "vaulted password is not printable ASCII; kvmd requires it"
}

Write-Host ("  user '{0}', password {1} chars - values not shown" -f $u, $pw.Length)

$sshArgs = @('-i', $KeyPath, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
             '-o', 'StrictHostKeyChecking=accept-new', "root@$DeviceIp")

& ssh @sshArgs 'true'
if ($LASTEXITCODE -ne 0) { throw "cannot ssh to $DeviceIp" }

# ONE remote script does both writes, so they cannot drift apart.
$remote = @'
read -r U; read -r P
U=$(printf '%s' "$U" | tr -d '\r')
P=$(printf '%s' "$P" | tr -d '\r')

printf '%s' "$P" | kvmd-htpasswd set "$U" -i >/dev/null 2>&1 \
  || printf '%s' "$P" | kvmd-htpasswd add "$U" -i >/dev/null 2>&1 \
  || { echo "      FAIL: kvmd-htpasswd rejected the password"; exit 1; }
echo "      kvmd-htpasswd written"

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
echo "      ipmipasswd mapping written"

python3 - "$U" "$P" <<PY
import sys, base64, hashlib
u, p = sys.argv[1], sys.argv[2]
line = [l for l in open("/etc/kvmd/user/htpasswd") if l.startswith(u + ":")][0].strip()
h = line.split(":", 1)[1]
# kvmd stores {SSHA512}: base64(sha512(password + salt) + salt), 8-byte salt.
# NOT crypt and NOT bcrypt -- verifying with crypt.crypt() returns a confident
# False for a perfectly good password, which cost real time on 2026-09-01.
if not h.startswith("{SSHA512}"):
    print("      VERIFY unknown hash scheme   : %s" % h[:10]); raise SystemExit(1)
raw = base64.b64decode(h[9:])
digest, salt = raw[:64], raw[64:]
ok_ht = hashlib.sha512(p.encode() + salt).digest() == digest
m = [l for l in open("/etc/kvmd/ipmipasswd")
     if l.strip() and not l.lstrip().startswith("#")][0].rstrip("\n")
ok_ip = m.endswith(":" + p) and "\r" not in m
print("      VERIFY htpasswd {SSHA512}    : %s" % ok_ht)
print("      VERIFY ipmipasswd matches    : %s" % ok_ip)
raise SystemExit(0 if (ok_ht and ok_ip) else 1)
PY
'@

"$u`n$pw" | & ssh @sshArgs $remote
if ($LASTEXITCODE -ne 0) {
    throw "credential apply FAILED verification - the two places may disagree"
}

Write-Host ""
Write-Host "  done - both places verified in sync."
Write-Host "  NOTE: auth is currently disabled (kvmd.auth.enabled: false), so this"
Write-Host "        credential is not exercised by the UI/API until that is reverted."
