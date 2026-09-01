<#
.SYNOPSIS
  Apply the KVMD credential from the OpenBao `glkvm` project to a Comet KVM.

.DESCRIPTION
  Reads KVMD-HT-USER / KVMD-HT-PASSWORD (injected as env vars by ob.ps1) and
  writes them to the TWO places that must stay in sync on the device:

    1. kvmd-htpasswd  (the actual login credential)
    2. the right-hand half of /etc/kvmd/ipmipasswd  (admin:admin -> user:pass)

  If only the first is updated, IPMI still completes its RMCP handshake and then
  silently 401s against kvmd — a failure that reads like an IPMI fault rather
  than a stale mapping.

  Values move via stdin only: never on argv, never printed.

.NOTES
  Two traps this guards against, both met for real on 2026-09-01:

  * CR INJECTION — piping from PowerShell into a Linux guest appends \r, which
    silently corrupts the stored password. Everything is normalised to LF on the
    far side and the result is byte-checked.

  * PASSWORD LENGTH — kvmd's SET rule is stricter than its LOGIN rule.
    validators/auth.py: login  ^[\x20-\x7e]{5,63}
                        setting ^[\x20-\x7e]{10,63}
    A 9-char password authenticates but cannot be set, and the error names the
    character class rather than the length. Checked up front here.

.EXAMPLE
  ob.ps1 glkvm -- pwsh -NoProfile -File tools\apply-vaulted-credential.ps1 192.0.2.15
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DeviceIp,
    [string]$KeyPath = "$PSScriptRoot\..\.ssh-glkvm\id_ed25519"
)

$ErrorActionPreference = 'Stop'

if ($DeviceIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
    throw "'$DeviceIp' is not a bare IPv4 address (refusing hostnames — mDNS can hit the wrong unit)"
}

$u  = ${env:KVMD-HT-USER}
$pw = ${env:KVMD-HT-PASSWORD}
if (-not $u -or -not $pw) {
    throw "KVMD-HT-USER / KVMD-HT-PASSWORD not in the environment — run me under: ob.ps1 glkvm -- ..."
}

# Fail loudly on the length rule BEFORE touching the device, so the failure is
# legible instead of arriving as a character-class complaint from kvmd-htpasswd.
if ($pw.Length -lt 10 -or $pw.Length -gt 63) {
    # NOTE the parens: -f binds tighter than +, so formatting a concatenation
    # without them applies -f to the LAST fragment only and leaves {0} literal.
    throw (("vaulted password is {0} chars; kvmd requires 10-63 to SET one " +
            "(validators/auth.py valid_new_passwd). Vault a longer value.") -f $pw.Length)
}
if ($pw -notmatch '^[\x20-\x7e]+$') {
    throw "vaulted password contains non-printable-ASCII characters; kvmd requires [\x20-\x7e]"
}

Write-Host ("  user '{0}', password {1} chars — values not shown" -f $u, $pw.Length)

$sshArgs = @('-i', $KeyPath, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
             '-o', 'StrictHostKeyChecking=accept-new', "root@$DeviceIp")

& ssh @sshArgs 'true'
if ($LASTEXITCODE -ne 0) { throw "cannot ssh to $DeviceIp" }

Write-Host "[1/3] kvmd-htpasswd"
$users = & ssh @sshArgs 'kvmd-htpasswd list'
$verb = if ($users -contains $u) { 'set' } else { 'add' }
$pw | & ssh @sshArgs "kvmd-htpasswd $verb $u -i" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "kvmd-htpasswd $verb failed" }
Write-Host "      $verb '$u' OK"

Write-Host "[2/3] /etc/kvmd/ipmipasswd mapping"
$remote = @'
read -r U; read -r P
U=$(printf '%s' "$U" | tr -d '\r')
P=$(printf '%s' "$P" | tr -d '\r')
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
# prove no CR survived, without ever rendering the secret
if grep -q $'\r' /etc/kvmd/ipmipasswd; then echo "      FAIL: CR present"; exit 1; fi
echo "      mapping written, no CR"
'@
"$u`n$pw" | & ssh @sshArgs $remote

Write-Host "[3/3] verify (masked)"
& ssh @sshArgs 'echo "      users  : $(kvmd-htpasswd list | tr "\n" " ")"; awk "!/^[[:space:]]*#/ && NF {gsub(/[^ :>-]/,\"x\"); print \"      mapping: \" \$0}" /etc/kvmd/ipmipasswd'

Write-Host ""
Write-Host "  done — both places in sync."
Write-Host "  NOTE: auth is currently disabled (kvmd.auth.enabled: false), so this"
Write-Host "        credential is not exercised by the UI/API until that is reverted."
