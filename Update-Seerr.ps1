[CmdletBinding(DefaultParameterSetName = 'Update')]
param(
    [Parameter(ParameterSetName = 'Update')]
    [switch] $Apply,

    [Parameter(ParameterSetName = 'Rollback', Mandatory = $true)]
    [switch] $Rollback,

    [Parameter(ParameterSetName = 'Rollback', Mandatory = $true)]
    [switch] $ApplyRollback,

    [string] $ContainerName = 'seerr',
    [string] $Image = 'ghcr.io/seerr-team/seerr:latest',
    [string] $VolumeName = 'seerr-data',
    [string] $ConfigPath = '/app/config',
    [string] $BackupDirectory = (Join-Path $env:USERPROFILE 'SeerrBackup'),
    [int] $HealthTimeoutSeconds = 180,
    [int] $MinimumFreeSpaceGB = 2
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Docker {
    param([Parameter(Mandatory)][string[]] $DockerArgs)
    $output = & docker @DockerArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($DockerArgs -join ' ') failed (exit $LASTEXITCODE): $($output -join [Environment]::NewLine)"
    }
    return ,$output
}

function Get-ContainerInspection {
    $raw = Invoke-Docker @('inspect', $ContainerName)
    return (($raw -join [Environment]::NewLine) | ConvertFrom-Json)[0]
}

function Get-OptionalContainerInspection {
    $names = @(Invoke-Docker @('container', 'ls', '-a', '--format', '{{.Names}}')) | ForEach-Object { "$($_)".Trim() }
    if ($names -notcontains $ContainerName) { return $null }
    return Get-ContainerInspection
}

function Get-VolumeInspection {
    $raw = Invoke-Docker @('volume', 'inspect', $VolumeName)
    return (($raw -join [Environment]::NewLine) | ConvertFrom-Json)[0]
}

function Assert-ExpectedVolume {
    param($Inspection)
    $mount = @($Inspection.Mounts | Where-Object {
        $_.Type -eq 'volume' -and $_.Name -eq $VolumeName -and $_.Destination -eq $ConfigPath -and $_.RW
    })
    if ($mount.Count -ne 1) {
        throw "Safety check failed: named volume '$VolumeName' is not mounted read/write at '$ConfigPath'. No update will continue."
    }
    $null = Get-VolumeInspection
}

function Assert-SavedExpectedVolume {
    param($Inspection)
    if (-not $Inspection -or -not $Inspection.Config -or -not $Inspection.HostConfig) {
        throw 'Rollback record does not contain a complete saved container inspection.'
    }
    $mount = @($Inspection.Mounts | Where-Object {
        $_.Type -eq 'volume' -and $_.Name -eq $VolumeName -and $_.Destination -eq $ConfigPath -and $_.RW
    })
    if ($mount.Count -ne 1) {
        throw "Safety check failed: saved configuration does not mount '$VolumeName' read/write at '$ConfigPath'. Rollback stopped."
    }
    $null = Get-VolumeInspection
}

function Add-Option {
    param([System.Collections.Generic.List[string]] $ArgsList, [string] $Flag, $Value)
    if ($null -ne $Value -and "$Value" -ne '') {
        $ArgsList.Add($Flag); $ArgsList.Add([string]$Value)
    }
}

function Get-PropertyValue {
    param($InputObject, [Parameter(Mandatory)][string] $Name, $Default = $null)
    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function New-RunArguments {
    param($Inspection, [string] $ImageId, [string] $Name, [ValidateSet('run', 'create')][string] $Action = 'run')
    $c = $Inspection.Config
    $h = $Inspection.HostConfig
    $entrypoint = @(Get-PropertyValue $c 'Entrypoint' @())
    $environment = @(Get-PropertyValue $c 'Env' @())
    $labels = Get-PropertyValue $c 'Labels'
    $mounts = @(Get-PropertyValue $Inspection 'Mounts' @())
    $exposedPorts = Get-PropertyValue $c 'ExposedPorts'
    $portBindings = Get-PropertyValue $h 'PortBindings'
    $logConfig = Get-PropertyValue $h 'LogConfig'
    $logOptions = Get-PropertyValue $logConfig 'Config'
    $restartPolicy = Get-PropertyValue $h 'RestartPolicy'
    $tmpfsOptions = Get-PropertyValue $h 'Tmpfs'
    $a = [System.Collections.Generic.List[string]]::new()
    $a.Add($Action)
    if ($Action -eq 'run') { $a.Add('-d') }
    $a.Add('--name'); $a.Add($Name)
    Add-Option $a '--hostname' (Get-PropertyValue $c 'Hostname')
    Add-Option $a '--user' (Get-PropertyValue $c 'User')
    Add-Option $a '--workdir' (Get-PropertyValue $c 'WorkingDir')
    if (Get-PropertyValue $c 'Tty' $false) { $a.Add('--tty') }
    if (Get-PropertyValue $c 'OpenStdin' $false) { $a.Add('--interactive') }
    if (Get-PropertyValue $h 'Privileged' $false) { $a.Add('--privileged') }
    if (Get-PropertyValue $h 'ReadonlyRootfs' $false) { $a.Add('--read-only') }
    if (Get-PropertyValue $h 'AutoRemove' $false) { $a.Add('--rm') }
    if (Get-PropertyValue $h 'Init' $false) { $a.Add('--init') }
    if (Get-PropertyValue $h 'PublishAllPorts' $false) { $a.Add('--publish-all') }
    Add-Option $a '--restart' (Get-PropertyValue $restartPolicy 'Name')
    Add-Option $a '--log-driver' (Get-PropertyValue $logConfig 'Type')
    if ($logOptions) { foreach ($logOption in $logOptions.PSObject.Properties) { Add-Option $a '--log-opt' "$($logOption.Name)=$($logOption.Value)" } }
    $networkMode = Get-PropertyValue $h 'NetworkMode'
    if ($networkMode -and $networkMode -ne 'default') { Add-Option $a '--network' $networkMode }
    $ipcMode = Get-PropertyValue $h 'IpcMode'
    if ($ipcMode -and $ipcMode -ne 'private') { Add-Option $a '--ipc' $ipcMode }
    Add-Option $a '--pid' (Get-PropertyValue $h 'PidMode')
    foreach ($property in @(@{ Name = 'ShmSize'; Flag = '--shm-size' }, @{ Name = 'Memory'; Flag = '--memory' }, @{ Name = 'MemorySwap'; Flag = '--memory-swap' })) {
        $value = Get-PropertyValue $h $property.Name 0
        if ($value -gt 0) { Add-Option $a $property.Flag $value }
    }
    $nanoCpus = Get-PropertyValue $h 'NanoCpus' 0
    if ($nanoCpus -gt 0) { Add-Option $a '--cpus' ([string]([double]$nanoCpus / 1000000000)) }
    foreach ($envVar in $environment) { Add-Option $a '--env' $envVar }
    if ($labels) { foreach ($label in $labels.PSObject.Properties) { Add-Option $a '--label' "$($label.Name)=$($label.Value)" } }
    foreach ($mount in $mounts) {
        if ($mount.Type -eq 'volume') {
            $readOnly = if ($mount.RW) { '' } else { ',readonly' }
            Add-Option $a '--mount' "type=volume,source=$($mount.Name),target=$($mount.Destination)$readOnly"
        } elseif ($mount.Type -eq 'bind') {
            $readOnly = if ($mount.RW) { '' } else { ',readonly' }
            Add-Option $a '--mount' "type=bind,source=$($mount.Source),target=$($mount.Destination)$readOnly"
        } else {
            throw "Cannot safely recreate unsupported mount type '$($mount.Type)'."
        }
    }
    foreach ($port in @($exposedPorts.PSObject.Properties.Name)) {
        $bindingProperty = if ($portBindings) { $portBindings.PSObject.Properties[$port] } else { $null }
        $bindings = if ($bindingProperty) { @($bindingProperty.Value) } else { @() }
        if ($bindings.Count -eq 0) { Add-Option $a '--expose' $port }
        foreach ($binding in $bindings) {
            $ip = if ($binding.HostIp) { "$($binding.HostIp):" } else { '' }
            Add-Option $a '--publish' "$ip$($binding.HostPort):$port"
        }
    }
    foreach ($dns in @(Get-PropertyValue $h 'Dns' @())) { Add-Option $a '--dns' $dns }
    foreach ($hostEntry in @(Get-PropertyValue $h 'ExtraHosts' @())) { Add-Option $a '--add-host' $hostEntry }
    foreach ($cap in @(Get-PropertyValue $h 'CapAdd' @())) { Add-Option $a '--cap-add' $cap }
    foreach ($cap in @(Get-PropertyValue $h 'CapDrop' @())) { Add-Option $a '--cap-drop' $cap }
    foreach ($security in @(Get-PropertyValue $h 'SecurityOpt' @())) { Add-Option $a '--security-opt' $security }
    foreach ($device in @(Get-PropertyValue $h 'Devices' @())) { Add-Option $a '--device' "$($device.PathOnHost):$($device.PathInContainer):$($device.CgroupPermissions)" }
    if ($tmpfsOptions) { foreach ($tmpfs in $tmpfsOptions.PSObject.Properties) { Add-Option $a '--tmpfs' "$($tmpfs.Name):$($tmpfs.Value)" } }
    if ($entrypoint.Count -gt 0) { Add-Option $a '--entrypoint' ([string]$entrypoint[0]) }
    $a.Add($ImageId)
    foreach ($entry in @($entrypoint | Select-Object -Skip 1)) { $a.Add($entry) }
    foreach ($cmd in @(Get-PropertyValue $c 'Cmd' @())) { $a.Add($cmd) }
    return $a.ToArray()
}

function Test-HttpEndpoint {
    param([string] $Uri)
    try {
        $response = Invoke-WebRequest -Uri $Uri -TimeoutSec 8 -MaximumRedirection 5 -SkipHttpErrorCheck
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500)
    } catch {
        return $false
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker CLI was not found in PATH.' }
$null = Invoke-Docker @('info', '--format', '{{.ServerVersion}}')
$null = Invoke-Docker @('context', 'show')
$backupRoot = [IO.Path]::GetFullPath($BackupDirectory)
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$backupPath = Join-Path $backupRoot "seerr-data-$timestamp.tar.gz"
$recordPath = Join-Path $backupRoot "seerr-maintenance-$timestamp.json"

if ($Rollback) {
    if (-not $ApplyRollback) { throw 'Rollback is destructive. Re-run with -Rollback -ApplyRollback to confirm.' }
    # Read and validate the rollback source before querying the current container.
    $record = Get-ChildItem -LiteralPath $backupRoot -Filter 'seerr-maintenance-*.json' -File |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $record) { throw "No maintenance record found in '$backupRoot'." }
    $saved = Get-Content -LiteralPath $record.FullName -Raw | ConvertFrom-Json
    if (-not $saved.PreviousImageId -or -not $saved.PreviousInspection) { throw 'Rollback record is incomplete.' }
    if ($saved.ContainerName -and $saved.ContainerName -ne $ContainerName) {
        throw "Rollback record is for container '$($saved.ContainerName)', not '$ContainerName'."
    }
    Assert-SavedExpectedVolume $saved.PreviousInspection
    $verifiedImageId = ((Invoke-Docker @('image', 'inspect', '--format', '{{.Id}}', [string]$saved.PreviousImageId)) -join '').Trim()
    if ($verifiedImageId -ne [string]$saved.PreviousImageId) {
        throw "Saved rollback image ID did not match the locally inspected image: $verifiedImageId"
    }

    # Stage a replacement before removing anything. If Docker cannot create it,
    # the current container remains untouched. A staged container is never started
    # until the old Seerr container has been removed.
    $existing = Get-OptionalContainerInspection
    $stageName = if ($existing) { "$ContainerName-rollback-$([Guid]::NewGuid().ToString('N'))" } else { $ContainerName }
    $createArgs = New-RunArguments $saved.PreviousInspection ([string]$saved.PreviousImageId) $stageName 'create'
    $null = Invoke-Docker $createArgs
    $oldContainerRemoved = $false
    try {
        if ($existing) {
            if ($existing.State.Running) { $null = Invoke-Docker @('stop', $ContainerName) }
            $null = Invoke-Docker @('rm', $ContainerName)
            $oldContainerRemoved = $true
            $null = Invoke-Docker @('rename', $stageName, $ContainerName)
        }
        $null = Invoke-Docker @('start', $ContainerName)

        $rollbackHealthy = $false
        $rollbackDeadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
        while ((Get-Date) -lt $rollbackDeadline) {
            $afterRollback = Get-ContainerInspection
            if ($afterRollback.State.Status -eq 'running' -and [string]$afterRollback.Image -eq [string]$saved.PreviousImageId -and (Test-HttpEndpoint 'http://localhost:5055')) {
                Assert-ExpectedVolume $afterRollback
                $rollbackHealthy = $true
                break
            }
            Start-Sleep -Seconds 3
        }
        if (-not $rollbackHealthy) {
            throw "Rollback container did not pass running, image, volume, and HTTP checks within $HealthTimeoutSeconds seconds."
        }
        Write-Host "Rollback complete. Image: $verifiedImageId; status: running; HTTP check passed."
    } catch {
        if ($existing -and -not $oldContainerRemoved) {
            # The original Seerr container is still present; remove only the staged
            # container created by this attempt so the original can keep running.
            $stagedNames = @(Invoke-Docker @('container', 'ls', '-a', '--format', '{{.Names}}')) | ForEach-Object { "$($_)".Trim() }
            if ($stagedNames -contains $stageName) { $null = Invoke-Docker @('rm', $stageName) }
            if ($existing.State.Running) {
                try {
                    $stillThere = Get-OptionalContainerInspection
                    if ($stillThere -and -not $stillThere.State.Running) { $null = Invoke-Docker @('start', $ContainerName) }
                } catch { }
            }
        }
        if ($oldContainerRemoved) {
            throw "Rollback recreation failed after removing the previous Seerr container. The saved image and configuration remain available; inspect '$stageName' if it still exists, then retry: .\Update-Seerr.ps1 -Rollback -ApplyRollback. Details: $_"
        }
        if ($existing) {
            throw "Rollback failed before removing the previous Seerr container; it remains in place and was restarted if it had been running. Details: $_"
        }
        throw "Rollback could not start or verify the recreated Seerr container. Inspect its state with 'docker ps -a --filter name=$ContainerName', then retry: .\Update-Seerr.ps1 -Rollback -ApplyRollback. Details: $_"
    }
    return
}

$inspection = Get-ContainerInspection
Assert-ExpectedVolume $inspection
$currentImageId = [string]$inspection.Image
$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($backupRoot))
if ($drive.AvailableFreeSpace -lt ($MinimumFreeSpaceGB * 1GB)) {
    throw "Insufficient free space on $($drive.Name): need at least $MinimumFreeSpaceGB GiB."
}

$backupUsable = Test-Path -LiteralPath $backupRoot -PathType Container
$plan = [ordered]@{
    Context = (& docker context show)
    Container = $ContainerName
    CurrentStatus = $inspection.State.Status
    CurrentImageId = $currentImageId
    TargetImage = $Image
    Volume = $VolumeName
    Mount = "$VolumeName`:$ConfigPath"
    BackupPath = $backupPath
    BackupDirectoryExists = $backupUsable
    FreeSpaceGB = [math]::Round($drive.AvailableFreeSpace / 1GB, 2)
    HttpCheck = 'http://localhost:5055'
}
Write-Host 'Seerr maintenance plan:'
$plan | Format-List | Out-Host
if (-not $Apply) {
    Write-Host 'Dry run only. No container, image, or volume changes were made. Use -Apply to execute.'
    return
}

if (Test-Path -LiteralPath $backupPath) { throw "Backup already exists; refusing to overwrite: $backupPath" }
if (Test-Path -LiteralPath $recordPath) { throw "Maintenance record already exists; refusing to overwrite: $recordPath" }
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$tempPath = Join-Path $env:TEMP "seerr-config-$timestamp"
$tempArchive = Join-Path $tempPath 'backup.tar.gz'
try {
    New-Item -ItemType Directory -Path $tempPath -ErrorAction Stop | Out-Null
    if ($inspection.State.Running) { $null = Invoke-Docker @('stop', $ContainerName) }
    try {
        New-Item -ItemType Directory -Path (Join-Path $tempPath 'config') -ErrorAction Stop | Out-Null
        $null = Invoke-Docker @('cp', "$ContainerName`:$ConfigPath/.", (Join-Path $tempPath 'config'))
        $tar = Join-Path $env:WINDIR 'System32\tar.exe'
        if (-not (Test-Path -LiteralPath $tar)) { throw 'Windows tar.exe was not found; cannot create the required tar.gz backup.' }
        & $tar -czf $tempArchive -C (Join-Path $tempPath 'config') .
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tempArchive) -or (Get-Item -LiteralPath $tempArchive).Length -eq 0) {
            throw 'Backup archive creation failed.'
        }
        & $tar -tzf $tempArchive *> $null
        if ($LASTEXITCODE -ne 0) { throw 'Backup archive integrity check failed.' }
        # File.Move fails if the destination already exists, so a timestamp collision
        # cannot overwrite an existing backup.
        [IO.File]::Move($tempArchive, $backupPath)
    } catch {
        if ($inspection.State.Running) { $null = Invoke-Docker @('start', $ContainerName) }
        throw "Backup failed; update stopped. Original container was restarted if it had been running. Details: $_"
    }

    try {
        $null = Invoke-Docker @('pull', $Image)
        $newImageId = ((Invoke-Docker @('image', 'inspect', '--format', '{{.Id}}', $Image)) -join '').Trim()
        $record = [ordered]@{ Created = (Get-Date).ToString('o'); ContainerName = $ContainerName; Image = $Image; PreviousImageId = $currentImageId; NewImageId = $newImageId; PreviousInspection = $inspection; BackupPath = $backupPath }
        $record | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $recordPath -Encoding utf8NoBOM
    } catch {
        if ($inspection.State.Running) { $null = Invoke-Docker @('start', $ContainerName) }
        throw "Image pull or maintenance record failed. Original Seerr container was restarted. Details: $_"
    }

    if ($inspection.State.Running) { $null = Invoke-Docker @('stop', $ContainerName) }
    $null = Invoke-Docker @('rm', $ContainerName)
    $runArgs = New-RunArguments $inspection $newImageId $ContainerName
    $null = Invoke-Docker $runArgs

    $healthy = $false
    $deadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $after = Get-ContainerInspection
        if ($after.State.Status -eq 'running' -and (Test-HttpEndpoint 'http://localhost:5055')) { $healthy = $true; break }
        Start-Sleep -Seconds 3
    }
    $after = Get-ContainerInspection
    if (-not $healthy) {
        Write-Error "Seerr did not become responsive within $HealthTimeoutSeconds seconds. Container status: $($after.State.Status). Backup: $backupPath. Roll back with: .\Update-Seerr.ps1 -Rollback -ApplyRollback"
        return
    }
    Write-Host "Update complete. Image: $newImageId; status: $($after.State.Status); HTTP check passed. Backup: $backupPath; record: $recordPath"
} finally {
    if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Recurse -Force }
}
