[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('on', 'off', 'status')][string]$Action = 'status',
    [string]$ConfigFile = ''
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigFile) { $ConfigFile = Join-Path $PSScriptRoot 'config.local.json' }

function ConvertTo-NativeArgument([string]$Value) {
    '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-Program {
    param([string]$Name, [string[]]$Arguments, [string]$InputText, [switch]$Display, [switch]$AllowFailure)
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = (Get-Command $Name -ErrorAction Stop).Source
    $start.Arguments = ($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['AWS_PAGER'] = ''
    $start.EnvironmentVariables['AWS_CLI_AUTO_PROMPT'] = 'off'
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stderr = $process.StandardError.ReadToEndAsync()
        $stdout = $null
        if (-not $Display) { $stdout = $process.StandardOutput.ReadToEndAsync() }
        if ($InputText) {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($InputText)
            $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        }
        $process.StandardInput.Close()
        if ($Display) {
            while (-not $process.StandardOutput.EndOfStream) { Write-Host $process.StandardOutput.ReadLine() }
        }
        $process.WaitForExit()
        $output = if ($stdout) { $stdout.Result } else { '' }
        $errorText = $stderr.Result
        $code = $process.ExitCode
        if ($code -and -not $AllowFailure) { throw "$Name failed ($code). $errorText" }
        [pscustomobject]@{ Code = $code; Output = $output; Error = $errorText }
    } finally {
        $process.Dispose()
    }
}

function Invoke-Aws {
    param([string[]]$Command, [switch]$AllowMissing)
    $result = Invoke-Program aws.exe ($Command + @('--profile', $script:Config.awsProfile, '--region', 'us-east-2', '--output', 'json')) -AllowFailure
    if ($result.Code) {
        if ($AllowMissing -and $result.Error -match 'ResourceNotFoundException|InvalidVpnConnectionID.NotFound') { return $null }
        throw "AWS request failed. $($result.Error)"
    }
    if ($result.Output.Trim()) { return ($result.Output | ConvertFrom-Json) }
}

function Invoke-Manager {
    param([string]$Operation, [hashtable]$Values = @{}, $Kubeconfig, $Gpu)
    $request = @{ operation = $Operation; config = $script:Config; token = $script:OperationId; values = $Values }
    if ($Kubeconfig) { $request.kubeconfig = $Kubeconfig }
    if ($Gpu) {
        $request.gpu = $Gpu
        $request.remoteRbac = [string](Get-Content -LiteralPath (Join-Path $script:Repo 'ansible/roles/multikueue-remote/files/rbac.yaml') -Raw)
    }
    $request._source = [string](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'cluster.py') -Raw)
    $command = 'python3 -c ''import json,sys; r=json.load(sys.stdin); scope={"__name__":"infra_runtime"}; exec(r.pop("_source"),scope); print(json.dumps(scope["dispatch"](r)))'''
    $result = Invoke-Program ssh.exe @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10', $script:Config.managerSshHost, $command) -InputText ($request | ConvertTo-Json -Depth 70 -Compress)
    $result.Output | ConvertFrom-Json
}

function Invoke-PfSense {
    param([string]$Operation, [object[]]$Tunnels = @())
    $body = @{ operation = $Operation; config = $script:Config; tunnels = $Tunnels } | ConvertTo-Json -Depth 30 -Compress
    $result = Invoke-Program python.exe @((Join-Path $PSScriptRoot 'pfsense.py')) -InputText $body
    $result.Output | ConvertFrom-Json
}

function Get-Cluster {
    $result = Invoke-Aws @('eks', 'describe-cluster', '--name', $script:Config.clusterName) -AllowMissing
    if ($null -eq $result) { return $null }
    $cluster = $result.cluster
    if ($cluster.arn -ne "arn:aws:eks:us-east-2:354363695096:cluster/$($script:Config.clusterName)") {
        throw 'Unexpected EKS identity.'
    }
    $cluster
}

function New-WorkerKubeconfig($Cluster) {
    if ($Cluster.status -ne 'ACTIVE' -or -not $Cluster.resourcesVpcConfig.endpointPrivateAccess -or $Cluster.resourcesVpcConfig.endpointPublicAccess) {
        throw 'EKS must be ACTIVE and use its private API endpoint.'
    }
    $token = Invoke-Aws @('eks', 'get-token', '--cluster-name', $script:Config.clusterName)
    @{
        apiVersion = 'v1'; kind = 'Config'
        clusters = @(@{ name = $script:Config.clusterName; cluster = @{ server = $Cluster.endpoint; 'certificate-authority-data' = $Cluster.certificateAuthority.data } })
        users = @(@{ name = 'operator'; user = @{ token = $token.status.token } })
        contexts = @(@{ name = $script:Config.clusterName; context = @{ cluster = $script:Config.clusterName; user = 'operator' } })
        'current-context' = $script:Config.clusterName
    }
}

function Get-GpuInstances {
    $result = Invoke-Aws @('ec2', 'describe-instances', '--filters',
        "Name=tag:Project,Values=$($script:Config.project)", 'Name=tag:Environment,Values=prod',
        "Name=tag:karpenter.sh/nodepool,Values=$($script:Config.gpuNodePool)",
        'Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down')
    @($result.Reservations | ForEach-Object { $_.Instances }) | Where-Object { $null -ne $_ }
}

function Assert-NetworkPlan($Plan, [bool]$Destroy) {
    $changes = @($Plan.resource_changes | Where-Object { $_.mode -eq 'managed' })
    foreach ($change in $changes) {
        if ($change.type -match '^aws_(s3_|dynamodb_|rolesanywhere_)') { throw "Protected data/identity resource in network plan: $($change.address)" }
        $actions = $change.change.actions -join ','
        if ($Destroy -and $actions -notin @('delete', 'no-op')) { throw "Unexpected teardown action on $($change.address)" }
        if (-not $Destroy -and $change.change.actions -contains 'delete') { throw "ON would replace or delete $($change.address). Review the plan separately." }
        foreach ($state in @($change.change.before, $change.change.after)) {
            if ($state -and $state.name -match '^devoops-prod-onprem-') { throw 'Persistent identity role in network plan.' }
        }
    }
}

function Initialize-Terraform {
    $backend = Join-Path $script:Repo 'terraform/backends/prod/network.s3.tfbackend'
    Invoke-Program terraform.exe @("-chdir=$script:Network", 'init', '-input=false', '-no-color', "-backend-config=$backend") -Display | Out-Null
    $cache = Get-Content -LiteralPath (Join-Path $script:Network '.terraform/terraform.tfstate') -Raw | ConvertFrom-Json
    if ($cache.backend.type -ne 's3' -or $cache.backend.config.bucket -ne 'devoops-prod-tfstate-354363695096-us-east-2' -or
        $cache.backend.config.key -ne 'prod/network/terraform.tfstate' -or -not $cache.backend.config.use_lockfile) {
        throw 'Unexpected network backend. Teardown is blocked.'
    }
}

function New-NetworkPlan([bool]$Destroy, [string]$PublicIp) {
    $path = Join-Path $script:RunDirectory 'network.tfplan'
    $args = @("-chdir=$script:Network", 'plan', '-input=false', '-no-color', '-lock-timeout=30s', "-out=$path")
    if ($Destroy) { $args += '-destroy' }
    $localVars = Join-Path $script:Network 'terraform.local.tfvars'
    if (Test-Path -LiteralPath $localVars) { $args += "-var-file=$localVars" }
    $args += @('-var', "customer_gateway_ip=$PublicIp")
    Invoke-Program terraform.exe $args -Display | Out-Null
    $result = Invoke-Program terraform.exe @("-chdir=$script:Network", 'show', '-json', $path)
    Assert-NetworkPlan ($result.Output | ConvertFrom-Json) $Destroy
    $path
}

function Wait-GpuTermination {
    $deadline = [DateTime]::UtcNow.AddSeconds($script:Config.timeoutSeconds)
    while (@(Get-GpuInstances).Count) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'GPU EC2 instances still exist. EKS and Karpenter are retained for investigation.' }
        Write-Host 'Waiting for GPU EC2 termination...'
        Start-Sleep -Seconds 10
    }
}

function Sync-Vpn {
    $outputs = (Invoke-Program terraform.exe @("-chdir=$script:Network", 'output', '-json', 'lifecycle')).Output | ConvertFrom-Json
    $vpn = Invoke-Aws @('ec2', 'describe-vpn-connections', '--vpn-connection-ids', $outputs.vpn_connection_id)
    [xml]$xml = $vpn.VpnConnections[0].CustomerGatewayConfiguration
    $tunnels = @(foreach ($t in $xml.vpn_connection.ipsec_tunnel) {
        @{
            outside = [string]$t.vpn_gateway.tunnel_outside_address.ip_address
            public = [string]$t.customer_gateway.tunnel_outside_address.ip_address
            local = [string]$t.customer_gateway.tunnel_inside_address.ip_address
            peer = [string]$t.vpn_gateway.tunnel_inside_address.ip_address
            psk = [string]$t.ike.pre_shared_key
        }
    })
    Invoke-PfSense configure $tunnels | Out-Host
    $deadline = [DateTime]::UtcNow.AddMinutes(8)
    do {
        $vpn = Invoke-Aws @('ec2', 'describe-vpn-connections', '--vpn-connection-ids', $outputs.vpn_connection_id)
        $telemetry = @($vpn.VpnConnections[0].VgwTelemetry)
        if ($telemetry.Count -eq 2 -and -not ($telemetry | Where-Object { $_.Status -ne 'UP' -or $_.AcceptedRouteCount -lt 1 })) { return }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Both VPN/BGP paths are not ready. Queues remain held.' }
        Write-Host 'Waiting for both VPN tunnels and BGP routes...'
        Start-Sleep -Seconds 10
    } while ($true)
}

function Get-Status {
    $cluster = Get-Cluster
    $cpu = $null
    if ($cluster) {
        $cpu = Invoke-Aws @('eks', 'describe-nodegroup', '--cluster-name', $script:Config.clusterName,
            '--nodegroup-name', "$($script:Config.clusterName)-cpu") -AllowMissing
    }
    $managerState = $null
    $managerError = $null
    try { $managerState = Invoke-Manager status } catch { $managerError = $_.Exception.Message }
    [pscustomobject]@{
        Cluster = if ($cluster) { $cluster.status } else { 'ABSENT' }
        CpuDesired = if ($cpu) { $cpu.nodegroup.scalingConfig.desiredSize } else { 0 }
        GpuInstances = @(Get-GpuInstances).Count
        Lifecycle = $managerState
        ManagerError = $managerError
    } | ConvertTo-Json -Depth 8 | Write-Host
}

function Invoke-Lifecycle {
    $script:Config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
    $script:Repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    $script:Network = Join-Path $script:Repo 'terraform/environments/prod/network'
    $script:OperationId = [guid]::NewGuid().ToString('N')
    if ($script:Config.clusterName -ne 'devoops-prod-eks-a' -or $script:Config.project -ne 'devoops' -or
        $script:Config.workerAlias -ne 'eks-a' -or $script:Config.timeoutSeconds -lt 60 -or $script:Config.timeoutSeconds -gt 3600) {
        throw 'Unexpected project configuration.'
    }
    $account = Invoke-Aws @('sts', 'get-caller-identity')
    if ($account.Account -ne '354363695096') { throw 'AWS account differs from the prod account.' }
    if ($Action -eq 'status') { Get-Status; return }
    # Read-only checks happen before any queue, AWS or pfSense change.
    Invoke-Manager preflight | Out-Null
    Invoke-PfSense check | Out-Null
    Invoke-Aws @('s3api', 'head-bucket', '--bucket', 'devoops-prod-ckpt-354363695096-us-east-2', '--expected-bucket-owner', '354363695096') | Out-Null
    foreach ($root in @('bootstrap', 'data', 'identity')) {
        Invoke-Aws @('s3api', 'head-object', '--bucket', 'devoops-prod-tfstate-354363695096-us-east-2', '--key', "prod/$root/terraform.tfstate") | Out-Null
    }
    if (-not $PSCmdlet.ShouldProcess('devoops-prod-eks-a network stack', $Action)) { return }
    $script:RunDirectory = Join-Path $env:LOCALAPPDATA ("DevOops/infra-runtime/" + $script:OperationId)
    New-Item -ItemType Directory -Path $script:RunDirectory -Force | Out-Null
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Invoke-Program icacls.exe @($script:RunDirectory, '/inheritance:r', '/grant:r', "*$($sid):(OI)(CI)F", '*S-1-5-18:(OI)(CI)F') | Out-Null
    $locked = $false
    $disruptiveChangeStarted = $false
    $restoreOnFailure = $false
    try {
        $journal = Invoke-Manager lock
        $locked = $true
        # Preserve an earlier OFF/failed-ON hold. Only undo a hold introduced now.
        $restoreOnFailure = (-not $journal.queuePolicies -or @($journal.queuePolicies.PSObject.Properties).Count -eq 0)
        Invoke-Manager hold | Out-Null
        Invoke-Manager manager_check | Out-Null
        Invoke-Manager checkpoint @{ phase = if ($Action -eq 'on') { 'Starting' } else { 'Stopping' } } | Out-Null
        $ipResult = Invoke-Program ssh.exe @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10',
            $script:Config.jumpHost, 'curl -4fsS --connect-timeout 5 --max-time 10 https://checkip.amazonaws.com')
        $publicIp = $ipResult.Output.Trim()
        $parsedIp = $null
        if (-not [Net.IPAddress]::TryParse($publicIp, [ref]$parsedIp) -or $parsedIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
            throw 'Cannot identify the on-premises public IPv4 address.'
        }
        Initialize-Terraform
        if ($Action -eq 'on') {
            $plan = New-NetworkPlan $false $publicIp
            $disruptiveChangeStarted = $true
            Invoke-Program terraform.exe @("-chdir=$script:Network", 'apply', '-input=false', '-no-color', $plan) -Display | Out-Null
            Invoke-Manager checkpoint @{ phase = 'NetworkCreated' } | Out-Null
            Sync-Vpn
            $cluster = Get-Cluster
            $gpu = (Invoke-Program terraform.exe @("-chdir=$script:Network", 'output', '-json', 'karpenter_gpu')).Output | ConvertFrom-Json
            Invoke-Manager worker_bootstrap -Kubeconfig (New-WorkerKubeconfig $cluster) -Gpu $gpu | Out-Host
            Invoke-Manager release | Out-Null
            Invoke-Manager checkpoint @{ phase = 'Ready'; generation = [string]$cluster.createdAt; cleanedGeneration = '' } | Out-Null
            Write-Host 'READY. Manager queues were restored to their original admission policies.'
        } else {
            $cluster = Get-Cluster
            if ($cluster) {
                $workerConfig = New-WorkerKubeconfig $cluster
                Invoke-Manager worker_check -Kubeconfig $workerConfig | Out-Null
            } elseif (-not $journal.cleanedGeneration) {
                throw 'EKS is absent without a recorded cleanup. Review orphan resources before teardown.'
            }
            $plan = New-NetworkPlan $true $publicIp
            $disruptiveChangeStarted = $true
            if ($cluster) {
                Invoke-Manager worker_cleanup -Kubeconfig (New-WorkerKubeconfig $cluster) | Out-Null
            }
            Wait-GpuTermination
            Invoke-Manager manager_check | Out-Null
            Invoke-Manager checkpoint @{ phase = 'WorkerCleaned'; cleanedGeneration = if ($cluster) { [string]$cluster.createdAt } else { $journal.cleanedGeneration } } | Out-Null
            Invoke-PfSense disable | Out-Host
            Invoke-Program terraform.exe @("-chdir=$script:Network", 'apply', '-input=false', '-no-color', $plan) -Display | Out-Null
            if (Get-Cluster) { throw 'EKS still exists after teardown.' }
            Wait-GpuTermination
            Invoke-Manager checkpoint @{ phase = 'Off' } | Out-Null
            Write-Host 'OFF. Data, state and persistent identity stacks are retained. Manager queues remain held.'
        }
    } catch {
        if ($locked) {
            if (-not $disruptiveChangeStarted -and $restoreOnFailure) {
                try { Invoke-Manager release | Out-Null } catch { Write-Warning 'Could not restore queue policies; inspect the lifecycle journal before retrying.' }
            }
            try { Invoke-Manager checkpoint @{ phase = if ($Action -eq 'on') { 'StartFailed' } else { 'StopFailed' } } | Out-Null } catch { Write-Warning 'Could not record the failure in the manager journal.' }
        }
        throw
    } finally {
        if ($locked) {
            try { Invoke-Manager unlock | Out-Null } catch { Write-Warning 'Lifecycle lock remains; verify no process is running before manual recovery.' }
        }
        $planPath = Join-Path $script:RunDirectory 'network.tfplan'
        if (Test-Path -LiteralPath $planPath) { Remove-Item -LiteralPath $planPath }
    }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-Lifecycle }
