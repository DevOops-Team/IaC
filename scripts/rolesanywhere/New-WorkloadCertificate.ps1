[CmdletBinding()]
param(
    [ValidateSet('backend', 'recovery', 'relocator', 'multikueue', 'db-backup')]
    [string]$Workload,
    [string]$PkiDirectory = (Join-Path $env:USERPROFILE '.devoops/rolesanywhere/prod'),
    [string]$OpenSsl = 'C:/Program Files/Git/usr/bin/openssl.exe'
)
$ErrorActionPreference = 'Stop'
$pkiPath = [IO.Path]::GetFullPath($PkiDirectory)
$repoPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')).TrimEnd('\', '/')
if ($pkiPath.StartsWith($repoPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $pkiPath -eq $repoPath) {
    throw 'Private keys must be stored outside the repository.'
}
if (-not (Test-Path -LiteralPath $OpenSsl)) { throw 'OpenSSL executable not found.' }
New-Item -ItemType Directory -Path $pkiPath -Force | Out-Null
# Restrict access before writing any private key. Never print a key or session.
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
$userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
foreach ($sid in @($userSid, $systemSid)) {
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $pkiPath -AclObject $acl

function Invoke-OpenSsl {
    param([string[]]$Arguments)
    & $OpenSsl @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'OpenSSL failed; existing files were not overwritten intentionally. Inspect partial output before retrying.' }
}

$caKey = Join-Path $pkiPath 'ca.key'
$caCert = Join-Path $pkiPath 'ca.pem'
if ((Test-Path -LiteralPath $caKey) -xor (Test-Path -LiteralPath $caCert)) {
    throw 'Incomplete CA files exist. Restore/inspect them rather than replacing the CA.'
}
if (-not (Test-Path -LiteralPath $caCert)) {
    Invoke-OpenSsl -Arguments @('req', '-x509', '-newkey', 'rsa:3072', '-nodes', '-sha256',
        '-days', '730', '-subj', '/O=DevOops/CN=DevOops-Prod-Workload-CA',
        '-addext', 'basicConstraints=critical,CA:TRUE,pathlen:0',
        '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
        '-keyout', $caKey, '-out', $caCert)
}
Invoke-OpenSsl -Arguments @('x509', '-in', $caCert, '-checkend', '2592000', '-noout')

if ($Workload) {
    $workloadPath = Join-Path $pkiPath $Workload
    New-Item -ItemType Directory -Path $workloadPath -Force | Out-Null
    $key = Join-Path $workloadPath 'client.key'
    $cert = Join-Path $workloadPath 'client.pem'
    $csr = Join-Path $workloadPath 'client.csr'
    if ((Test-Path -LiteralPath $key) -or (Test-Path -LiteralPath $cert) -or (Test-Path -LiteralPath $csr)) {
        throw 'Workload identity already exists. Use a new PkiDirectory with a restored copy of the same CA for an explicit renewal; do not silently replace deployed credentials.'
    }
    $extensions = Join-Path $workloadPath 'client.ext'
    @'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
'@ | Set-Content -LiteralPath $extensions -Encoding ascii
    Invoke-OpenSsl -Arguments @('req', '-new', '-newkey', 'rsa:3072', '-nodes', '-sha256',
        '-subj', "/O=DevOops/CN=devoops-prod-$Workload", '-keyout', $key, '-out', $csr)
    $serial = (& $OpenSsl rand -hex 16).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not generate certificate serial.' }
    Invoke-OpenSsl -Arguments @('x509', '-req', '-in', $csr, '-CA', $caCert, '-CAkey', $caKey,
        '-set_serial', "0x$serial", '-days', '30', '-sha256', '-extfile', $extensions, '-out', $cert)
    Invoke-OpenSsl -Arguments @('verify', '-CAfile', $caCert, $cert)
    Write-Output "Issued 30-day certificate for $Workload. Private files remain in $workloadPath; do not commit them."
}
Write-Output "Public CA certificate: $caCert"
