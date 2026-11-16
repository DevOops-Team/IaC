[CmdletBinding()]
param(
    [ValidateSet('plan', 'apply')][string]$Mode = 'plan',
    [ValidateSet('172.30.0.2', '172.30.0.3')][string]$Firewall = '172.30.0.2',
    [string]$JumpHost = 'pve4',
    [string]$IdentityFile = "$HOME/.ssh/id_ed25519_devoops",
    # Primary key was previously verified through the console. Verify backup separately.
    [string]$HostKeyFingerprint = 'SHA256:Dfo3cNAC4fczgUrap5OcFNGLjdHgvWI1Z7zAHXZrMFQ',
    [string]$ExpectedConfigSha256,
    [switch]$ConfirmApply
)
$ErrorActionPreference = 'Stop'
if ($JumpHost -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Invalid SSH jump host.' }
if ($Mode -eq 'apply' -and (!$ConfirmApply -or $ExpectedConfigSha256 -notmatch '^[0-9a-f]{64}$')) {
    throw 'Review plan first. Apply requires -ConfirmApply and -ExpectedConfigSha256 from that plan.'
}
$options = @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10')
# Fetch a public key through the trusted jump host, then compare with the pinned fingerprint.
$scan = & ssh @options $JumpHost "ssh-keyscan -T 5 -t ed25519 $Firewall 2>/dev/null"
if ($LASTEXITCODE -ne 0) { throw 'Cannot read firewall SSH public key.' }
$keys = @($scan | Where-Object { $_ -match "^$([regex]::Escape($Firewall)) ssh-ed25519 " })
if ($keys.Count -ne 1) { throw 'Expected exactly one firewall host key.' }
$sha = [System.Security.Cryptography.SHA256]::Create()
try { $digest = [Convert]::ToBase64String($sha.ComputeHash([Convert]::FromBase64String(($keys[0] -split ' ')[2]))).TrimEnd('=') }
finally { $sha.Dispose() }
if ("SHA256:$digest" -cne $HostKeyFingerprint) { throw 'Firewall host key differs from the verified fingerprint.' }
$knownHosts = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($knownHosts, $keys[0] + "`n", [System.Text.Encoding]::ASCII)
    $request = @{mode=$Mode; host=$Firewall; expected_config_sha256=$ExpectedConfigSha256} | ConvertTo-Json -Compress
    $policy = Get-Content -LiteralPath "$PSScriptRoot/vpn-inbound-policy.json" -Raw
    $php = Get-Content -LiteralPath "$PSScriptRoot/vpn-inbound.php" -Raw
    $php = $php.Replace('__REQUEST__', [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($request)))
    $php = $php.Replace('__POLICY__', [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($policy)))
    # ASCII source/base64 payload avoids PowerShell 5.1 pipe encoding problems. No local secrets.
    $php | & ssh @options -J $JumpHost -o HostKeyAlgorithms=ssh-ed25519 -o "UserKnownHostsFile=$knownHosts" -o IdentitiesOnly=yes -i $IdentityFile "root@$Firewall" php
    if ($LASTEXITCODE -ne 0) { throw 'Firewall policy operation failed.' }
} finally {
    Remove-Item -LiteralPath $knownHosts -ErrorAction SilentlyContinue
}
