$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..\Update-Seerr.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $scriptPath), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "Update-Seerr.ps1 has parser errors: $($parseErrors -join '; ')" }

# Load only production function definitions. The updater's top-level Docker workflow is never run.
$functionNames = @(
    'Add-Option', 'Get-PropertyValue', 'Get-SupportedConfigFields', 'Get-SupportedHostConfigFields',
    'Test-EquivalentValue', 'Test-EffectiveDefaultValue', 'Get-UnsupportedContainerSettings',
    'Assert-SupportedContainerConfiguration', 'Get-ContainerReplacementPlan', 'Get-SavedContainerRunningState',
    'Test-ExpectedContainerRunningState', 'New-RunArguments'
)
$functionNodes = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$builderNode = $functionNodes | Where-Object Name -eq 'New-RunArguments' | Select-Object -First 1
if (-not $builderNode) { throw 'New-RunArguments was not found.' }
$builderText = $builderNode.Extent.Text
foreach ($functionNode in $functionNodes) {
    if ($functionNode.Name -in $functionNames) { Invoke-Expression $functionNode.Extent.Text }
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock] $Script, [string] $Message)
    $threw = $false
    try { & $Script } catch { $threw = $true }
    Assert-True $threw $Message
}

$imageConfig = ConvertFrom-Json @'
{
  "Env": ["NODE_ENV=production"],
  "Labels": {},
  "ExposedPorts": { "5055/tcp": {} },
  "Entrypoint": ["node"],
  "Cmd": ["server.js"],
  "Healthcheck": { "Test": ["CMD-SHELL", "node healthcheck.js"] },
  "StopSignal": "SIGTERM"
}
'@

$inspection = ConvertFrom-Json @'
{
  "Id": "abcdef1234567890",
  "Name": "/seerr",
  "Config": {
    "Image": "ghcr.io/seerr-team/seerr:latest",
    "Hostname": "seerr",
    "Domainname": "",
    "MacAddress": "",
    "User": "",
    "WorkingDir": "/app",
    "Tty": false,
    "OpenStdin": false,
    "Env": ["NODE_ENV=production"],
    "Labels": {},
    "ExposedPorts": { "5055/tcp": {} },
    "Entrypoint": ["node"],
    "Cmd": ["server.js"],
    "Healthcheck": { "Test": ["CMD-SHELL", "node healthcheck.js"] },
    "StopSignal": "SIGTERM",
    "StopTimeout": null
  },
  "HostConfig": {
    "Privileged": false,
    "ReadonlyRootfs": false,
    "AutoRemove": false,
    "Init": false,
    "InitPath": "",
    "PublishAllPorts": false,
    "RestartPolicy": { "Name": "on-failure", "MaximumRetryCount": 3 },
    "LogConfig": { "Type": "json-file", "Config": {} },
    "NetworkMode": "mynet",
    "IpcMode": "private",
    "PidMode": "",
    "CgroupnsMode": "private",
    "UsernsMode": "",
    "Runtime": "",
    "Isolation": "default",
    "UTSMode": "",
    "CgroupParent": "",
    "ShmSize": 67108864,
    "Memory": 0,
    "MemorySwap": -1,
    "NanoCpus": 0,
    "CpuShares": 0,
    "CpuQuota": 0,
    "CpuPeriod": 0,
    "CpusetCpus": "",
    "CpusetMems": "",
    "MemoryReservation": 0,
    "MemorySwappiness": -1,
    "PidsLimit": 0,
    "OomKillDisable": false,
    "OomScoreAdj": 0,
    "PortBindings": {
      "5055/tcp": [{ "HostIp": "::1", "HostPort": "5055" }]
    },
    "Dns": [],
    "DnsOptions": [],
    "DnsSearch": [],
    "ExtraHosts": [],
    "GroupAdd": [],
    "CapAdd": [],
    "CapDrop": [],
    "SecurityOpt": [],
    "Devices": [],
    "DeviceCgroupRules": [],
    "Tmpfs": {},
    "Ulimits": [],
    "Sysctls": {},
    "Binds": [],
    "Mounts": [],
    "ConsoleSize": [0, 0],
    "Links": [],
    "DeviceRequests": [],
    "StorageOpt": {}
  },
  "Mounts": [
    { "Type": "volume", "Name": "seerr-data", "Source": "seerr-data", "Destination": "/app/config", "Driver": "local", "Mode": "rw", "RW": true, "Propagation": "" },
    { "Type": "bind", "Name": "", "Source": "C:/Seerr/cache", "Destination": "/app/cache", "Driver": "", "Mode": "rw", "RW": true, "Propagation": "rshared", "NonRecursive": false }
  ],
  "NetworkSettings": {
    "Networks": {
      "mynet": {
        "Aliases": ["seerr", "abcdef123456", "stable-seerr"],
        "IPAMConfig": { "IPv4Address": "", "IPv6Address": "" },
        "DriverOpts": {},
        "Links": []
      }
    }
  },
  "State": { "Running": true }
}
'@

$unsupported = @(Get-UnsupportedContainerSettings $inspection $imageConfig 'seerr')
Assert-True ($unsupported.Count -eq 0) "Default/image-inherited settings were incorrectly flagged: $($unsupported -join ', ')"
Assert-True (Test-EffectiveDefaultValue 'GeneratedDefaults' ([pscustomobject]@{ Count = 0; Enabled = $false })) 'Nested Docker-generated defaults were not treated as default values.'
foreach ($field in @(Get-SupportedConfigFields) + @(Get-SupportedHostConfigFields)) {
    Assert-True ($builderText -match "\b$field\b") "Supported-setting list contains $field, but New-RunArguments does not reference it."
}

$inspection.HostConfig.DeviceRequests = @(@{ Driver = 'nvidia'; Count = 1; Capabilities = @(@('gpu')) })
$unsupported = @(Get-UnsupportedContainerSettings $inspection $imageConfig 'seerr')
Assert-True ($unsupported -contains 'HostConfig.DeviceRequests') 'A non-default unsupported device request was not detected.'
$threw = $false
try { Assert-SupportedContainerConfiguration $inspection $imageConfig 'seerr' } catch { $threw = $_.Exception.Message -match 'HostConfig.DeviceRequests' }
Assert-True $threw 'The preflight validator did not stop with the unsupported setting name.'
$inspection.HostConfig.DeviceRequests = @()

$inspection.HostConfig.Init = $false
$inspection.HostConfig.InitPath = '/custom/docker-init'
$unsupported = @(Get-UnsupportedContainerSettings $inspection $imageConfig 'seerr')
Assert-True ($unsupported -contains 'HostConfig.InitPath (custom path requires Init to be explicitly enabled)') 'A custom InitPath with Init disabled was not rejected by preflight.'
$inspection.HostConfig.InitPath = ''

$inspection.Config.Healthcheck = @{ Test = @('CMD-SHELL', 'custom-check') }
$unsupported = @(Get-UnsupportedContainerSettings $inspection $imageConfig 'seerr')
Assert-True ($unsupported -contains 'Config.Healthcheck') 'A custom unsupported health check was not detected against the image default.'
$inspection.Config.Healthcheck = $imageConfig.Healthcheck

$inspection.Mounts[0].Mode = 'rw,z'
$unsupported = @(Get-UnsupportedContainerSettings $inspection $imageConfig 'seerr')
Assert-True ($unsupported -contains 'Mounts[0].Mode=rw,z') 'An unsupported volume mount mode was not detected.'
$inspection.Mounts[0].Mode = 'rw'

$planRunning = Get-ContainerReplacementPlan $true
$planStopped = Get-ContainerReplacementPlan $false
Assert-True ($planRunning.CreateAction -eq 'create' -and $planRunning.StartAfterCreate -and $planRunning.CheckHttp -and $planRunning.ExpectedRunning) 'Running-state replacement plan is incorrect.'
Assert-True ($planStopped.CreateAction -eq 'create' -and -not $planStopped.StartAfterCreate -and -not $planStopped.CheckHttp -and -not $planStopped.ExpectedRunning) 'Stopped-state replacement plan is incorrect.'
$inspection.State.Running = $true
Assert-True (Test-ExpectedContainerRunningState $inspection $true) 'Running state was not recognized.'
$inspection.State.Running = $false
Assert-True (Test-ExpectedContainerRunningState $inspection $false) 'Stopped state was not recognized.'
$runningInspection = [pscustomobject]@{ State = [pscustomobject]@{ Running = $true } }
$stoppedInspection = [pscustomobject]@{ State = [pscustomobject]@{ Running = $false } }
Assert-True (Get-SavedContainerRunningState ([pscustomobject]@{ WasRunning = $true; PreviousInspection = $runningInspection })) 'A matching explicit running state was not accepted.'
Assert-True (-not (Get-SavedContainerRunningState ([pscustomobject]@{ WasRunning = $false; PreviousInspection = $stoppedInspection }))) 'A matching explicit stopped state was not accepted.'

# These records deliberately contain WasRunning with a null or invalid type; they are not legacy records.
Assert-Throws { Get-SavedContainerRunningState ([pscustomobject]@{ WasRunning = $null; PreviousInspection = $stoppedInspection }) } 'A null WasRunning value was accepted.'
Assert-Throws { Get-SavedContainerRunningState ([pscustomobject]@{ WasRunning = 'false'; PreviousInspection = $stoppedInspection }) } 'A string WasRunning value of false was accepted.'
Assert-Throws { Get-SavedContainerRunningState ([pscustomobject]@{ WasRunning = 'true'; PreviousInspection = $runningInspection }) } 'A string WasRunning value of true was accepted.'
Assert-Throws { Get-SavedContainerRunningState ([pscustomobject]@{ WasRunning = 1; PreviousInspection = $runningInspection }) } 'A numeric WasRunning value was accepted.'
Assert-Throws { Get-SavedContainerRunningState ([pscustomobject]@{ WasRunning = $true; PreviousInspection = $stoppedInspection }) } 'A WasRunning value that conflicts with inspection state was accepted.'
Assert-Throws { Get-SavedContainerRunningState ([pscustomobject]@{ WasRunning = $false; PreviousInspection = $runningInspection }) } 'A stopped WasRunning value that conflicts with inspection state was accepted.'

# Legacy records are identified by the absence of the WasRunning property.
$legacyRunningRecord = [pscustomobject]@{ PreviousInspection = $runningInspection }
$legacyStoppedRecord = [pscustomobject]@{ PreviousInspection = $stoppedInspection }
Assert-True (Get-SavedContainerRunningState $legacyRunningRecord) 'A legacy running record did not use its inspection state.'
Assert-True (-not (Get-SavedContainerRunningState $legacyStoppedRecord)) 'A legacy stopped record did not use its inspection state.'
Assert-Throws { Get-SavedContainerRunningState ([pscustomobject]@{ PreviousInspection = [pscustomobject]@{ State = [pscustomobject]@{} } }) } 'A legacy record with missing inspection state was accepted.'
Assert-Throws { Get-SavedContainerRunningState ([pscustomobject]@{ PreviousInspection = [pscustomobject]@{ State = [pscustomobject]@{ Running = 'false' } } }) } 'A legacy record with malformed inspection state was accepted.'

$arguments = @(New-RunArguments $inspection 'sha256:new-image' 'seerr' 'create')
$joinedArguments = $arguments -join ' '
Assert-True ($joinedArguments.Contains('--restart on-failure:3')) 'Restart-policy retry count was not preserved.'
Assert-True ($joinedArguments.Contains('--memory-swap -1')) 'Negative MemorySwap was not preserved.'
Assert-True ($joinedArguments.Contains('[::1]:5055:5055')) 'IPv6 host binding was not bracketed.'
Assert-True ($joinedArguments.Contains('--network-alias stable-seerr')) 'Custom network alias was not preserved.'
Assert-True ($joinedArguments.Contains('bind-propagation=rshared')) 'Bind propagation was not preserved.'

Write-Output 'All Seerr preflight, run-argument, and state-plan checks passed.'
