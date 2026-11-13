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

function Get-SupportedConfigFields {
    # Keep these names synchronized with the Config fields consumed by New-RunArguments.
    return @('Hostname', 'Domainname', 'MacAddress', 'User', 'WorkingDir', 'Tty', 'OpenStdin', 'Env', 'Labels', 'ExposedPorts', 'Entrypoint', 'Cmd', 'StopSignal', 'StopTimeout')
}

function Get-SupportedHostConfigFields {
    # Keep these names synchronized with the HostConfig fields consumed by New-RunArguments.
    return @(
        'Privileged', 'ReadonlyRootfs', 'AutoRemove', 'Init', 'InitPath', 'PublishAllPorts',
        'RestartPolicy', 'LogConfig', 'NetworkMode', 'IpcMode', 'PidMode', 'CgroupnsMode',
        'UsernsMode', 'Runtime', 'Isolation', 'UTSMode', 'CgroupParent', 'ShmSize', 'Memory',
        'MemorySwap', 'NanoCpus', 'CpuShares', 'CpuQuota', 'CpuPeriod', 'CpusetCpus', 'CpusetMems',
        'MemoryReservation', 'MemorySwappiness', 'PidsLimit', 'OomKillDisable', 'OomScoreAdj',
        'PortBindings', 'Dns', 'DnsOptions', 'DnsSearch', 'ExtraHosts', 'GroupAdd', 'CapAdd', 'CapDrop',
        'SecurityOpt', 'Devices', 'DeviceCgroupRules', 'Tmpfs', 'Ulimits', 'Sysctls'
    )
}

function Test-EquivalentValue {
    param($Left, $Right)
    if ($null -eq $Left -or $null -eq $Right) {
        if ($null -eq $Left -and $null -eq $Right) { return $true }
        $other = if ($null -eq $Left) { $Right } else { $Left }
        return (Test-EffectiveDefaultValue '' $other)
    }
    if ($Left -is [string] -or $Right -is [string]) { return ($Left -is [string] -and $Right -is [string] -and $Left -ceq $Right) }
    if ($Left -is [ValueType] -or $Right -is [ValueType]) {
        return ($Left -eq $Right)
    }
    if ($Left -is [System.Collections.IDictionary] -or $Right -is [System.Collections.IDictionary]) {
        if (-not ($Left -is [System.Collections.IDictionary]) -or -not ($Right -is [System.Collections.IDictionary])) { return $false }
        $leftKeys = @($Left.Keys | ForEach-Object { [string]$_ } | Sort-Object)
        $rightKeys = @($Right.Keys | ForEach-Object { [string]$_ } | Sort-Object)
        if (-not (Test-EquivalentValue $leftKeys $rightKeys)) { return $false }
        foreach ($key in $leftKeys) { if (-not (Test-EquivalentValue $Left[$key] $Right[$key])) { return $false } }
        return $true
    }
    if ($Left -is [System.Collections.IEnumerable] -and $Left -isnot [string]) {
        if (-not ($Right -is [System.Collections.IEnumerable]) -or $Right -is [string]) { return $false }
        $leftItems = @($Left); $rightItems = @($Right)
        if ($leftItems.Count -ne $rightItems.Count) { return $false }
        for ($i = 0; $i -lt $leftItems.Count; $i++) {
            if (-not (Test-EquivalentValue $leftItems[$i] $rightItems[$i])) { return $false }
        }
        return $true
    }
    $leftProperties = @($Left.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty', 'Property') } | Sort-Object Name)
    $rightProperties = @($Right.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty', 'Property') } | Sort-Object Name)
    if ($leftProperties.Count -ne $rightProperties.Count) { return $false }
    for ($i = 0; $i -lt $leftProperties.Count; $i++) {
        if ($leftProperties[$i].Name -ne $rightProperties[$i].Name) { return $false }
        if (-not (Test-EquivalentValue $leftProperties[$i].Value $rightProperties[$i].Value)) { return $false }
    }
    return $true
}

function Test-EffectiveDefaultValue {
    param([string] $Name, $Value)
    if ($null -eq $Value) { return $true }
    if ($Value -is [bool]) { return (-not $Value) }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
        if ($Name -eq 'Isolation' -and $Value -eq 'default') { return $true }
        return $false
    }
    if ($Value -is [ValueType]) {
        if ($Name -eq 'MemorySwappiness' -and $Value -eq -1) { return $true }
        return ($Value -eq 0)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) { return $true }
        foreach ($key in $Value.Keys) {
            if (-not (Test-EffectiveDefaultValue ([string]$key) $Value[$key])) { return $false }
        }
        return $true
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return $true }
        if ($Name -eq 'ConsoleSize' -and $items.Count -eq 2 -and $items[0] -eq 0 -and $items[1] -eq 0) { return $true }
        return $false
    }
    $properties = @($Value.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty', 'Property') })
    if ($properties.Count -eq 0) { return $true }
    foreach ($property in $properties) {
        if (-not (Test-EffectiveDefaultValue $property.Name $property.Value)) { return $false }
    }
    return $true
}

function Get-UnsupportedContainerSettings {
    param($Inspection, $ImageConfig, [string] $ContainerName = 'seerr')
    $unsupported = [System.Collections.Generic.List[string]]::new()
    $supportedConfig = @(Get-SupportedConfigFields)
    foreach ($property in $Inspection.Config.PSObject.Properties) {
        if ($property.Name -in $supportedConfig -or $property.Name -eq 'Image') { continue }
        $imageProperty = if ($ImageConfig) { $ImageConfig.PSObject.Properties[$property.Name] } else { $null }
        $matchesImageDefault = if ($imageProperty) {
            Test-EquivalentValue $property.Value $imageProperty.Value
        } else {
            Test-EffectiveDefaultValue $property.Name $property.Value
        }
        if (-not $matchesImageDefault) { $unsupported.Add("Config.$($property.Name)") }
    }

    $supportedHost = @(Get-SupportedHostConfigFields)
    # Binds and mount specifications are checked against the resolved top-level Mounts list below.
    # MaskedPaths/ReadonlyPaths are daemon-generated runtime paths, not create-time settings.
    $resolvedByMountInspection = @('Binds', 'Mounts', 'MaskedPaths', 'ReadonlyPaths')
    foreach ($property in $Inspection.HostConfig.PSObject.Properties) {
        if ($property.Name -in $supportedHost -or $property.Name -in $resolvedByMountInspection) { continue }
        if (-not (Test-EffectiveDefaultValue $property.Name $property.Value)) { $unsupported.Add("HostConfig.$($property.Name)") }
    }
    $initEnabled = Get-PropertyValue $Inspection.HostConfig 'Init' $false
    $initPath = Get-PropertyValue $Inspection.HostConfig 'InitPath'
    if (-not $initEnabled -and -not (Test-EffectiveDefaultValue 'InitPath' $initPath)) {
        $unsupported.Add('HostConfig.InitPath (custom path requires Init to be explicitly enabled)')
    }
    $restartPolicy = Get-PropertyValue $Inspection.HostConfig 'RestartPolicy'
    $retryCount = Get-PropertyValue $restartPolicy 'MaximumRetryCount' 0
    if ($retryCount -gt 0 -and (Get-PropertyValue $restartPolicy 'Name') -ne 'on-failure') {
        $unsupported.Add('HostConfig.RestartPolicy.MaximumRetryCount')
    }

    $networkMode = [string](Get-PropertyValue $Inspection.HostConfig 'NetworkMode' '')
    $referenceModes = @(
        @{ Name = 'NetworkMode'; Value = $networkMode },
        @{ Name = 'IpcMode'; Value = [string](Get-PropertyValue $Inspection.HostConfig 'IpcMode' '') },
        @{ Name = 'PidMode'; Value = [string](Get-PropertyValue $Inspection.HostConfig 'PidMode' '') }
    )
    foreach ($mode in $referenceModes) {
        if ($mode.Value -match '^container:(.+)$') {
            $target = $Matches[1]
            if ($target -eq $ContainerName -or $target -eq [string]$Inspection.Id -or ($Inspection.Id -and $target -eq ([string]$Inspection.Id).Substring(0, [math]::Min(12, ([string]$Inspection.Id).Length)))) {
                $unsupported.Add("HostConfig.$($mode.Name) references the container being replaced")
            }
        }
    }

    $networkSettings = Get-PropertyValue $Inspection 'NetworkSettings'
    $networks = Get-PropertyValue $networkSettings 'Networks'
    $networkProperties = if ($networks) { @($networks.PSObject.Properties) } else { @() }
    if ($networkProperties.Count -gt 1) { $unsupported.Add('NetworkSettings.Networks (multiple attached networks are not recreated)') }
    foreach ($networkProperty in $networkProperties) {
        $network = $networkProperty.Value
        $ipam = Get-PropertyValue $network 'IPAMConfig'
        foreach ($ipField in @('IPv4Address', 'IPv6Address')) {
            $ip = Get-PropertyValue $ipam $ipField
            if ($ip) { $unsupported.Add("NetworkSettings.Networks.$($networkProperty.Name).IPAMConfig.$ipField") }
        }
        $driverOptions = Get-PropertyValue $network 'DriverOpts'
        if (-not (Test-EffectiveDefaultValue 'DriverOpts' $driverOptions)) { $unsupported.Add("NetworkSettings.Networks.$($networkProperty.Name).DriverOpts") }
        $links = Get-PropertyValue $network 'Links'
        if (-not (Test-EffectiveDefaultValue 'Links' $links)) { $unsupported.Add("NetworkSettings.Networks.$($networkProperty.Name).Links") }
        $containerId = [string](Get-PropertyValue $Inspection 'Id' '')
        $autoAliases = @($ContainerName, [string](Get-PropertyValue $Inspection 'Name' '').TrimStart('/'), $containerId)
        if ($containerId.Length -gt 12) { $autoAliases += $containerId.Substring(0, 12) }
        $aliases = @(Get-PropertyValue $network 'Aliases' @())
        $customAliases = @($aliases | Where-Object { $_ -and $_ -notin $autoAliases })
        if ($customAliases.Count -gt 0 -and ($networkMode -in @('', 'default', 'bridge', 'host', 'none') -or $networkProperty.Name -ne $networkMode)) {
            $unsupported.Add("NetworkSettings.Networks.$($networkProperty.Name).Aliases")
        }
    }

    $mounts = @(Get-PropertyValue $Inspection 'Mounts' @())
    for ($i = 0; $i -lt $mounts.Count; $i++) {
        $mount = $mounts[$i]
        if ($mount.Type -notin @('volume', 'bind')) { $unsupported.Add("Mounts[$i].Type=$($mount.Type)"); continue }
        $mode = [string](Get-PropertyValue $mount 'Mode' '')
        $allowedMode = if ($mount.RW) { @('', 'rw') } else { @('', 'ro') }
        if ($mode -notin $allowedMode) { $unsupported.Add("Mounts[$i].Mode=$mode") }
        if ($mount.Type -eq 'volume') {
            $driver = [string](Get-PropertyValue $mount 'Driver' '')
            if ($driver -and $driver -ne 'local') { $unsupported.Add("Mounts[$i].Driver=$driver") }
            $propagation = [string](Get-PropertyValue $mount 'Propagation' '')
            if ($propagation) { $unsupported.Add("Mounts[$i].Propagation=$propagation") }
            foreach ($optionName in @('Options', 'VolumeOptions')) {
                $options = Get-PropertyValue $mount $optionName
                if (-not (Test-EffectiveDefaultValue $optionName $options)) { $unsupported.Add("Mounts[$i].$optionName") }
            }
        } else {
            $nonRecursive = Get-PropertyValue $mount 'NonRecursive' $false
            $readOnlyNonRecursive = Get-PropertyValue $mount 'ReadOnlyNonRecursive' $false
            $readOnlyForceRecursive = Get-PropertyValue $mount 'ReadOnlyForceRecursive' $false
            if ($nonRecursive -or $readOnlyNonRecursive -or $readOnlyForceRecursive) { $unsupported.Add("Mounts[$i] has unsupported bind mount options") }
        }
    }
    $mountSpecs = @(Get-PropertyValue $Inspection.HostConfig 'Mounts' @())
    for ($i = 0; $i -lt $mountSpecs.Count; $i++) {
        $spec = $mountSpecs[$i]
        $bindOptions = Get-PropertyValue $spec 'BindOptions'
        foreach ($optionName in @('NonRecursive', 'ReadOnlyNonRecursive', 'ReadOnlyForceRecursive', 'CreateMountpoint')) {
            if (Get-PropertyValue $bindOptions $optionName $false) { $unsupported.Add("HostConfig.Mounts[$i].BindOptions.$optionName") }
        }
        $volumeOptions = Get-PropertyValue $spec 'VolumeOptions'
        foreach ($optionName in @('NoCopy', 'Subpath')) {
            $optionValue = Get-PropertyValue $volumeOptions $optionName
            if (-not (Test-EffectiveDefaultValue $optionName $optionValue)) { $unsupported.Add("HostConfig.Mounts[$i].VolumeOptions.$optionName") }
        }
        $driverConfig = Get-PropertyValue $volumeOptions 'DriverConfig'
        if (-not (Test-EffectiveDefaultValue 'DriverConfig' $driverConfig)) { $unsupported.Add("HostConfig.Mounts[$i].VolumeOptions.DriverConfig") }
    }
    return $unsupported.ToArray()
}

function Assert-SupportedContainerConfiguration {
    param($Inspection, $ImageConfig, [string] $ContainerName = 'seerr')
    $unsupported = @(Get-UnsupportedContainerSettings $Inspection $ImageConfig $ContainerName)
    if ($unsupported.Count -gt 0) {
        throw "Safety check failed: unsupported non-default Docker configuration: $($unsupported -join ', '). No backup or container changes were made."
    }
}

function Get-ContainerReplacementPlan {
    param([bool] $WasRunning)
    return [pscustomobject]@{
        CreateAction = 'create'
        StartAfterCreate = $WasRunning
        CheckHttp = $WasRunning
        ExpectedRunning = $WasRunning
    }
}

function Get-SavedContainerRunningState {
    param($MaintenanceRecord)
    $wasRunningProperty = if ($null -ne $MaintenanceRecord) { $MaintenanceRecord.PSObject.Properties['WasRunning'] } else { $null }
    $previousInspection = Get-PropertyValue $MaintenanceRecord 'PreviousInspection'
    $previousState = Get-PropertyValue $previousInspection 'State'
    $previousRunningProperty = if ($null -ne $previousState) { $previousState.PSObject.Properties['Running'] } else { $null }

    if ($previousRunningProperty) {
        if ($previousRunningProperty.Value -isnot [bool]) {
            throw 'Maintenance record PreviousInspection.State.Running must be a Boolean.'
        }
        $previousRunning = $previousRunningProperty.Value
    }

    if ($wasRunningProperty) {
        if ($wasRunningProperty.Value -isnot [bool]) {
            throw 'Maintenance record WasRunning must be a Boolean.'
        }
        $wasRunning = $wasRunningProperty.Value
        if ($previousRunningProperty -and $wasRunning -ne $previousRunning) {
            throw 'Maintenance record WasRunning conflicts with PreviousInspection.State.Running.'
        }
        return $wasRunning
    }

    if (-not $previousRunningProperty) {
        throw 'Maintenance record does not contain a valid previous container running state.'
    }
    return $previousRunning
}

function Test-ExpectedContainerRunningState {
    param($Inspection, [bool] $ExpectedRunning)
    return ([bool]$Inspection.State.Running -eq $ExpectedRunning)
}

function Get-ImageConfiguration {
    param([Parameter(Mandatory)][string] $ImageId)
    $raw = Invoke-Docker @('image', 'inspect', '--format', '{{json .Config}}', $ImageId)
    return (($raw -join [Environment]::NewLine) | ConvertFrom-Json)
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
    Add-Option $a '--domainname' (Get-PropertyValue $c 'Domainname')
    Add-Option $a '--mac-address' (Get-PropertyValue $c 'MacAddress')
    Add-Option $a '--user' (Get-PropertyValue $c 'User')
    Add-Option $a '--workdir' (Get-PropertyValue $c 'WorkingDir')
    if (Get-PropertyValue $c 'Tty' $false) { $a.Add('--tty') }
    if (Get-PropertyValue $c 'OpenStdin' $false) { $a.Add('--interactive') }
    if (Get-PropertyValue $h 'Privileged' $false) { $a.Add('--privileged') }
    if (Get-PropertyValue $h 'ReadonlyRootfs' $false) { $a.Add('--read-only') }
    if (Get-PropertyValue $h 'AutoRemove' $false) { $a.Add('--rm') }
    if (Get-PropertyValue $h 'Init' $false) {
        $a.Add('--init')
        Add-Option $a '--init-path' (Get-PropertyValue $h 'InitPath')
    }
    Add-Option $a '--stop-signal' (Get-PropertyValue $c 'StopSignal')
    $stopTimeout = Get-PropertyValue $c 'StopTimeout'
    if ($null -ne $stopTimeout) { Add-Option $a '--stop-timeout' $stopTimeout }
    if (Get-PropertyValue $h 'PublishAllPorts' $false) { $a.Add('--publish-all') }
    $restartName = [string](Get-PropertyValue $restartPolicy 'Name')
    $retryCount = Get-PropertyValue $restartPolicy 'MaximumRetryCount' 0
    $restartValue = if ($restartName -eq 'on-failure' -and $retryCount -gt 0) { "on-failure:$retryCount" } else { $restartName }
    Add-Option $a '--restart' $restartValue
    Add-Option $a '--log-driver' (Get-PropertyValue $logConfig 'Type')
    if ($logOptions) { foreach ($logOption in $logOptions.PSObject.Properties) { Add-Option $a '--log-opt' "$($logOption.Name)=$($logOption.Value)" } }
    $networkMode = Get-PropertyValue $h 'NetworkMode'
    if ($networkMode -and $networkMode -ne 'default') { Add-Option $a '--network' $networkMode }
    if ($networkMode -and $networkMode -notin @('default', 'bridge', 'host', 'none') -and $networkMode -notmatch '^container:') {
        $networkSettings = Get-PropertyValue $Inspection 'NetworkSettings'
        $networks = Get-PropertyValue $networkSettings 'Networks'
        $networkProperty = if ($networks) { $networks.PSObject.Properties[$networkMode] } else { $null }
        if ($networkProperty) {
            $autoAliases = @($Name, [string](Get-PropertyValue $Inspection 'Name' '').TrimStart('/'), [string](Get-PropertyValue $Inspection 'Id' ''))
            $containerId = [string](Get-PropertyValue $Inspection 'Id' '')
            if ($containerId.Length -gt 12) { $autoAliases += $containerId.Substring(0, 12) }
            $aliases = @(Get-PropertyValue $networkProperty.Value 'Aliases' @())
            foreach ($alias in $aliases) {
                if ($alias -and $alias -notin $autoAliases) { Add-Option $a '--network-alias' $alias }
            }
        }
    }
    $ipcMode = Get-PropertyValue $h 'IpcMode'
    if ($ipcMode -and $ipcMode -ne 'private') { Add-Option $a '--ipc' $ipcMode }
    Add-Option $a '--pid' (Get-PropertyValue $h 'PidMode')
    foreach ($property in @(
        @{ Name = 'ShmSize'; Flag = '--shm-size' }, @{ Name = 'Memory'; Flag = '--memory' },
        @{ Name = 'MemorySwap'; Flag = '--memory-swap' }, @{ Name = 'MemoryReservation'; Flag = '--memory-reservation' },
        @{ Name = 'CpuShares'; Flag = '--cpu-shares' }, @{ Name = 'CpuQuota'; Flag = '--cpu-quota' },
        @{ Name = 'CpuPeriod'; Flag = '--cpu-period' }, @{ Name = 'OomScoreAdj'; Flag = '--oom-score-adj' },
        @{ Name = 'PidsLimit'; Flag = '--pids-limit' }
    )) {
        $value = Get-PropertyValue $h $property.Name 0
        if ($null -ne $value -and $value -ne 0 -and ($property.Name -in @('MemorySwap', 'PidsLimit') -or $value -gt 0)) { Add-Option $a $property.Flag $value }
    }
    foreach ($property in @(@{ Name = 'CpusetCpus'; Flag = '--cpuset-cpus' }, @{ Name = 'CpusetMems'; Flag = '--cpuset-mems' }, @{ Name = 'CgroupParent'; Flag = '--cgroup-parent' }, @{ Name = 'CgroupnsMode'; Flag = '--cgroupns' }, @{ Name = 'UsernsMode'; Flag = '--userns' }, @{ Name = 'Runtime'; Flag = '--runtime' }, @{ Name = 'Isolation'; Flag = '--isolation' }, @{ Name = 'UTSMode'; Flag = '--uts' })) {
        Add-Option $a $property.Flag (Get-PropertyValue $h $property.Name)
    }
    $memorySwappiness = Get-PropertyValue $h 'MemorySwappiness' -1
    if ($null -ne $memorySwappiness -and $memorySwappiness -ne -1) { Add-Option $a '--memory-swappiness' $memorySwappiness }
    if (Get-PropertyValue $h 'OomKillDisable' $false) { $a.Add('--oom-kill-disable') }
    foreach ($property in @(@{ Name = 'DnsOptions'; Flag = '--dns-option' }, @{ Name = 'DnsSearch'; Flag = '--dns-search' }, @{ Name = 'GroupAdd'; Flag = '--group-add' }, @{ Name = 'DeviceCgroupRules'; Flag = '--device-cgroup-rule' })) {
        foreach ($value in @(Get-PropertyValue $h $property.Name @())) { Add-Option $a $property.Flag $value }
    }
    $nanoCpus = Get-PropertyValue $h 'NanoCpus' 0
    if ($nanoCpus -gt 0) { Add-Option $a '--cpus' ([string]([double]$nanoCpus / 1000000000)) }
    foreach ($ulimit in @(Get-PropertyValue $h 'Ulimits' @())) {
        Add-Option $a '--ulimit' "$($ulimit.Name)=$($ulimit.Soft):$($ulimit.Hard)"
    }
    $sysctls = Get-PropertyValue $h 'Sysctls'
    if ($sysctls) { foreach ($sysctl in $sysctls.PSObject.Properties) { Add-Option $a '--sysctl' "$($sysctl.Name)=$($sysctl.Value)" } }
    foreach ($envVar in $environment) { Add-Option $a '--env' $envVar }
    if ($labels) { foreach ($label in $labels.PSObject.Properties) { Add-Option $a '--label' "$($label.Name)=$($label.Value)" } }
    foreach ($mount in $mounts) {
        if ($mount.Type -eq 'volume') {
            $readOnly = if ($mount.RW) { '' } else { ',readonly' }
            Add-Option $a '--mount' "type=volume,source=$($mount.Name),target=$($mount.Destination)$readOnly"
        } elseif ($mount.Type -eq 'bind') {
            $readOnly = if ($mount.RW) { '' } else { ',readonly' }
            $propagation = [string](Get-PropertyValue $mount 'Propagation' '')
            $propagationOption = if ($propagation -and $propagation -ne 'rprivate') { ",bind-propagation=$propagation" } else { '' }
            Add-Option $a '--mount' "type=bind,source=$($mount.Source),target=$($mount.Destination)$readOnly$propagationOption"
        } else {
            throw "Cannot safely recreate unsupported mount type '$($mount.Type)'."
        }
    }
    foreach ($port in @($exposedPorts.PSObject.Properties.Name)) {
        $bindingProperty = if ($portBindings) { $portBindings.PSObject.Properties[$port] } else { $null }
        $bindings = if ($bindingProperty) { @($bindingProperty.Value) } else { @() }
        if ($bindings.Count -eq 0) { Add-Option $a '--expose' $port }
        foreach ($binding in $bindings) {
            $ip = ''
            if ($binding.HostIp) {
                $parsedAddress = $null
                if ([System.Net.IPAddress]::TryParse([string]$binding.HostIp, [ref]$parsedAddress) -and $parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
                    $ip = "[$($binding.HostIp)]:"
                } else {
                    $ip = "$($binding.HostIp):"
                }
            }
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
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400)
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
    $wasRunning = Get-SavedContainerRunningState $saved
    $replacementPlan = Get-ContainerReplacementPlan $wasRunning
    Assert-SavedExpectedVolume $saved.PreviousInspection
    $verifiedImageId = ((Invoke-Docker @('image', 'inspect', '--format', '{{.Id}}', [string]$saved.PreviousImageId)) -join '').Trim()
    if ($verifiedImageId -ne [string]$saved.PreviousImageId) {
        throw "Saved rollback image ID did not match the locally inspected image: $verifiedImageId"
    }
    $savedImageConfig = Get-ImageConfiguration $verifiedImageId
    Assert-SupportedContainerConfiguration $saved.PreviousInspection $savedImageConfig $ContainerName

    # Stage a replacement before removing anything. If Docker cannot create it,
    # the current container remains untouched. A staged container is never started
    # until the old Seerr container has been removed.
    $existing = Get-OptionalContainerInspection
    $stageName = if ($existing) { "$ContainerName-rollback-$([Guid]::NewGuid().ToString('N'))" } else { $ContainerName }
    $createArgs = New-RunArguments $saved.PreviousInspection ([string]$saved.PreviousImageId) $stageName $replacementPlan.CreateAction
    $null = Invoke-Docker $createArgs
    $oldContainerRemoved = $false
    $stageRenamed = $false
    try {
        if ($existing) {
            if ($existing.State.Running) { $null = Invoke-Docker @('stop', $ContainerName) }
            $null = Invoke-Docker @('rm', $ContainerName)
            $oldContainerRemoved = $true
            $null = Invoke-Docker @('rename', $stageName, $ContainerName)
            $stageRenamed = $true
        }
        $afterRollback = Get-ContainerInspection
        if ([string]$afterRollback.Image -ne [string]$saved.PreviousImageId) { throw 'Rollback replacement has the wrong image ID.' }
        Assert-ExpectedVolume $afterRollback
        if ($replacementPlan.StartAfterCreate) {
            $null = Invoke-Docker @('start', $ContainerName)
            $rollbackHealthy = $false
            $rollbackDeadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
            while ((Get-Date) -lt $rollbackDeadline) {
                $afterRollback = Get-ContainerInspection
                if ((Test-ExpectedContainerRunningState $afterRollback $true) -and [string]$afterRollback.Image -eq [string]$saved.PreviousImageId -and (Test-HttpEndpoint 'http://localhost:5055')) {
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
        } else {
            if (-not (Test-ExpectedContainerRunningState $afterRollback $false)) {
                throw 'Rollback replacement should remain stopped, but Docker reports it running.'
            }
            Write-Host "Rollback complete. Image: $verifiedImageId; status: stopped; HTTP check skipped because the previous container was stopped."
        }
    } catch {
        $rollbackFailure = $_
        $recoveryNotes = [System.Collections.Generic.List[string]]::new()
        if ($existing -and -not $oldContainerRemoved) {
            # The original Seerr container is still present; remove only the staged
            # container created by this attempt so the original can keep running.
            try {
                $stagedNames = @(Invoke-Docker @('container', 'ls', '-a', '--format', '{{.Names}}')) | ForEach-Object { "$($_)".Trim() }
                if ($stagedNames -contains $stageName) { $null = Invoke-Docker @('rm', $stageName) }
            } catch {
                $recoveryNotes.Add("Staging-container cleanup failed: $_")
            }
            if ($existing.State.Running) {
                try {
                    $stillThere = Get-OptionalContainerInspection
                    if ($stillThere -and -not $stillThere.State.Running) { $null = Invoke-Docker @('start', $ContainerName) }
                } catch {
                    $recoveryNotes.Add("Restarting the original Seerr container failed: $_")
                }
            }
        }
        $recoveryDetail = if ($recoveryNotes.Count -gt 0) { ' Recovery actions: ' + ($recoveryNotes -join ' ') } else { '' }
        if ($oldContainerRemoved) {
            $recoveryName = if ($stageRenamed) { $ContainerName } else { $stageName }
            throw "Rollback recreation failed after removing the previous Seerr container. The saved image and configuration remain available; inspect '$recoveryName' if it exists, then retry: .\Update-Seerr.ps1 -Rollback -ApplyRollback. Details: $rollbackFailure$recoveryDetail"
        }
        if ($existing) {
            throw "Rollback failed before removing the previous Seerr container; it remains in place. Details: $rollbackFailure$recoveryDetail"
        }
        throw "Rollback could not start or verify the recreated Seerr container. Inspect its state with 'docker ps -a --filter name=$ContainerName', then retry: .\Update-Seerr.ps1 -Rollback -ApplyRollback. Details: $rollbackFailure$recoveryDetail"
    }
    return
}

$inspection = Get-ContainerInspection
Assert-ExpectedVolume $inspection
$currentImageId = [string]$inspection.Image
$currentImageConfig = Get-ImageConfiguration $currentImageId
Assert-SupportedContainerConfiguration $inspection $currentImageConfig $ContainerName
$wasRunning = [bool]$inspection.State.Running
$replacementPlan = Get-ContainerReplacementPlan $wasRunning
$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($backupRoot))
if ($drive.AvailableFreeSpace -lt ($MinimumFreeSpaceGB * 1GB)) {
    throw "Insufficient free space on $($drive.Name): need at least $MinimumFreeSpaceGB GiB."
}

$backupUsable = Test-Path -LiteralPath $backupRoot -PathType Container
$plan = [ordered]@{
    Context = (& docker context show)
    Container = $ContainerName
    CurrentStatus = $inspection.State.Status
    ReplacementStatus = if ($replacementPlan.ExpectedRunning) { 'running' } else { 'stopped' }
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
$tempPath = Join-Path $env:TEMP "seerr-config-$timestamp-$([Guid]::NewGuid().ToString('N'))"
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
        $record = [ordered]@{ Created = (Get-Date).ToString('o'); ContainerName = $ContainerName; Image = $Image; PreviousImageId = $currentImageId; NewImageId = $newImageId; WasRunning = $wasRunning; PreviousInspection = $inspection; BackupPath = $backupPath }
        $record | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $recordPath -Encoding utf8NoBOM
        # Build arguments before removing the existing container so unsupported
        # inspected settings fail while the original container is still present.
        $runArgs = New-RunArguments $inspection $newImageId $ContainerName $replacementPlan.CreateAction
    } catch {
        if ($inspection.State.Running) { $null = Invoke-Docker @('start', $ContainerName) }
        throw "Image pull, maintenance record, or replacement configuration preparation failed. Original Seerr container was restarted if it had been running. Details: $_"
    }

    try {
        if ($inspection.State.Running) { $null = Invoke-Docker @('stop', $ContainerName) }
        $null = Invoke-Docker @('rm', $ContainerName)
        $null = Invoke-Docker $runArgs
        if ($replacementPlan.StartAfterCreate) { $null = Invoke-Docker @('start', $ContainerName) }
    } catch {
        throw "Seerr container replacement failed. The original container may be stopped or removed; the backup and maintenance record remain available. Inspect Docker state, then roll back with: .\Update-Seerr.ps1 -Rollback -ApplyRollback. Details: $_"
    }

    $healthy = $false
    if ($replacementPlan.CheckHttp) {
        $deadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            $after = Get-ContainerInspection
            if ((Test-ExpectedContainerRunningState $after $true) -and [string]$after.Image -eq [string]$newImageId -and (Test-HttpEndpoint 'http://localhost:5055')) {
                Assert-ExpectedVolume $after
                $healthy = $true
                break
            }
            Start-Sleep -Seconds 3
        }
    } else {
        $after = Get-ContainerInspection
        if ([string]$after.Image -eq [string]$newImageId -and (Test-ExpectedContainerRunningState $after $false)) {
            Assert-ExpectedVolume $after
            $healthy = $true
        }
    }
    if ($replacementPlan.CheckHttp) { $after = Get-ContainerInspection }
    if (-not $healthy) {
        $checkDescription = if ($replacementPlan.CheckHttp) { "running, correct image, volume, and HTTP checks within $HealthTimeoutSeconds seconds" } else { 'stopped state, correct image, and volume checks' }
        Write-Error "Seerr replacement did not pass $checkDescription. Container status: $($after.State.Status). Backup: $backupPath. Roll back with: .\Update-Seerr.ps1 -Rollback -ApplyRollback"
        return
    }
    $healthSummary = if ($replacementPlan.CheckHttp) { 'HTTP check passed' } else { 'HTTP check skipped because Seerr was stopped before the update' }
    Write-Host "Update complete. Image: $newImageId; status: $($after.State.Status); $healthSummary. Backup: $backupPath; record: $recordPath"
} finally {
    if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Recurse -Force }
}
