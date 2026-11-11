$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../infra.ps1') -ConfigFile unused

function Assert-Rejected($Plan, [bool]$Destroy) {
    $rejected = $false
    try { Assert-NetworkPlan $Plan $Destroy } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe plan was accepted.' }
}

function Plan([string]$Type, [string[]]$Actions, [string]$ResourceName = 'temporary') {
    @{ resource_changes = @(@{ mode = 'managed'; type = $Type; address = 'test.resource';
        change = @{ actions = $Actions; before = @{ name = $ResourceName }; after = $null } }) }
}

Assert-Rejected (Plan 'aws_s3_bucket' @('delete')) $true
Assert-Rejected (Plan 'aws_dynamodb_table' @('delete')) $true
Assert-Rejected (Plan 'aws_iam_role' @('delete') 'devoops-prod-onprem-backend') $true
Assert-Rejected (Plan 'aws_eks_cluster' @('delete', 'create')) $false
Assert-Rejected (Plan 'aws_eks_cluster' @('create')) $true
Assert-NetworkPlan (Plan 'aws_eks_cluster' @('delete')) $true
Assert-NetworkPlan (Plan 'aws_eks_cluster' @('create')) $false

# Reproduce the earlier UTF-8 BOM / native quoting issue using stdin and argv.
$payload = [string]('{"value":"quote\" and path C:\\temp\\"}')
$native = Invoke-Program python.exe @('-c', 'import json,sys; r=json.load(sys.stdin); print(json.dumps([r,sys.argv[1:]]))', 'space quote" backslash\') -InputText $payload
$decoded = $native.Output | ConvertFrom-Json
if ($decoded[0].value -ne 'quote" and path C:\temp\' -or $decoded[1][0] -ne 'space quote" backslash\') {
    throw 'UTF-8 stdin or native argument roundtrip failed.'
}
Write-Output 'PASS: protected resources, unsafe actions, native quoting and BOM-free stdin.'
