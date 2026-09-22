[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ExecutablePath,

    [string]$ResourcesPath,

    [Parameter(Mandatory = $true)]
    [ValidateScript({
        if (-not (Test-Path -LiteralPath $_ -PathType Container)) {
            New-Item -ItemType Directory -Path $_ -Force | Out-Null
        }
        $true
    })]
    [string]$TestRunRoot,

    [Parameter(Mandatory = $true)]
    [ValidateScript({
        if (-not (Test-Path -LiteralPath $_ -PathType Container)) {
            New-Item -ItemType Directory -Path $_ -Force | Out-Null
        }
        $true
    })]
    [string]$ArtifactDir,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$ServiceDistro,

    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$ServiceName = 'agentmirrord',

    [ValidateRange(1, 10000)]
    [int]$ExpectedRows = 1,

    [ValidateRange(1025, 65535)]
    [int]$DebugPort = 19251,

    [ValidateRange(5000, 120000)]
    [int]$TimeoutMs = 30000,

    [switch]$AllowTestCleanup
)

$ErrorActionPreference = 'Stop'
if (-not $AllowTestCleanup) {
    throw 'Fail-closed: pass -AllowTestCleanup only for the independently packaged test bundle.'
}

$sourceExe = [System.IO.Path]::GetFullPath($ExecutablePath)
$resolvedRoot = [System.IO.Path]::GetFullPath($TestRunRoot).TrimEnd('\') + '\'
$resolvedArtifacts = [System.IO.Path]::GetFullPath($ArtifactDir)
$repoRoot = Split-Path -Parent $PSScriptRoot
if ($resolvedRoot -notmatch '(?i)agentmirror[-_](?:e2e|test)[-_]') {
    throw "Refusing a non-disposable test root: $resolvedRoot"
}
if ($resolvedRoot -match '(?i)\\(?:Program Files|Program Files \(x86\))(?:\\|$)') {
    throw "Refusing to use a system installation path: $resolvedRoot"
}
if ($sourceExe -match '(?i)\\(?:Program Files|Program Files \(x86\))(?:\\|$)') {
    throw "Refusing a system executable source: $sourceExe"
}
$resourceCandidates = @()
if ($ResourcesPath) {
    $resourceCandidates += [System.IO.Path]::GetFullPath($ResourcesPath)
}
$resourceCandidates += @(
    (Join-Path (Split-Path -Parent $sourceExe) 'resources'),
    (Join-Path $repoRoot 'src-tauri\resources'),
    (Join-Path (Split-Path -Parent (Split-Path -Parent $sourceExe)) 'resources')
)
$sourceResources = $resourceCandidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
    Select-Object -First 1
if (-not $sourceResources) {
    throw 'Tauri resources directory not found beside the executable, repository, or build output.'
}
$portableExe = Join-Path $resolvedRoot (Split-Path -Leaf $sourceExe)
$portableResources = Join-Path $resolvedRoot 'resources'
$sourceExeIsPortable = $sourceExe.Equals($portableExe, [System.StringComparison]::OrdinalIgnoreCase)
$resourcesArePortable = $sourceResources.Equals($portableResources, [System.StringComparison]::OrdinalIgnoreCase)
New-Item -ItemType Directory -Path $resolvedArtifacts -Force | Out-Null
$receiptPath = Join-Path $resolvedArtifacts 'windows-5090-hot-runner.json'
$cdpReceipt = Join-Path $resolvedArtifacts 'windows-5090-startup-receipt.json'
$serviceTracePath = Join-Path $resolvedArtifacts 'windows-5090-hot-service-pids.jsonl'

function Write-JsonLine {
    param([string]$Path, [object]$Value)
    ($Value | ConvertTo-Json -Compress -Depth 8) | Add-Content -LiteralPath $Path -Encoding UTF8
}

function Get-ServicePids {
    $raw = & wsl.exe --distribution $ServiceDistro --exec pgrep -x $ServiceName 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    @($raw | ForEach-Object {
        $value = 0
        if ([int]::TryParse(([string]$_).Trim(), [ref]$value)) { $value }
    } | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
}

function Stop-ExactServicePids {
    param([int[]]$Pids)
    foreach ($servicePid in @($Pids | Sort-Object -Unique)) {
        if ((Get-ServicePids) -contains $servicePid) {
            & wsl.exe --distribution $ServiceDistro --exec kill -TERM ([string]$servicePid) 2>$null | Out-Null
        }
    }
}

$runStarted = Get-Date
$runId = $runStarted.ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
$oldWebViewArgs = $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS
$oldWebViewData = $env:WEBVIEW2_USER_DATA_FOLDER
$appProcess = $null
$cdpProcess = $null
$seenServicePids = [System.Collections.Generic.HashSet[int]]::new()
$preexistingServicePids = @()
$final = [ordered]@{
    schema = 'agentmirror.windows-5090.hot-runner.v1'
    runId = $runId
    sourceExecutablePath = $sourceExe
    portableExecutablePath = $portableExe
    sourceResourcesPath = $sourceResources
    portableResourcesPath = $portableResources
    testRunRoot = $resolvedRoot.TrimEnd('\')
    artifactDir = $resolvedArtifacts
    serviceDistro = $ServiceDistro
    serviceName = $ServiceName
    expectedRows = $ExpectedRows
    debugPort = $DebugPort
    timeoutMs = $TimeoutMs
    verdict = 'NOT-RUN'
    tokenValuesOmitted = $true
}

try {
    if (@(Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $DebugPort -ErrorAction SilentlyContinue).Count -gt 0) {
        throw "Refusing to attach to occupied WebView2 debug port $DebugPort"
    }
    $preexistingServicePids = @(Get-ServicePids)
    if ($preexistingServicePids.Count -gt 0) {
        throw "Refusing to touch a pre-existing WSL service (PIDs: $($preexistingServicePids -join ','))."
    }

    # Stage the executable and Tauri resources side by side. Tauri resolves
    # `resources/*` relative to the executable's resource directory.
    if (-not $resourcesArePortable) {
        if (Test-Path -LiteralPath $portableResources) {
            Remove-Item -LiteralPath $portableResources -Recurse -Force
        }
        New-Item -ItemType Directory -Path $portableResources -Force | Out-Null
        Get-ChildItem -LiteralPath $sourceResources -Force |
            Copy-Item -Destination $portableResources -Recurse -Force
    }
    if (-not $sourceExeIsPortable) {
        Copy-Item -LiteralPath $sourceExe -Destination $portableExe -Force
    }

    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = (($oldWebViewArgs, "--remote-debugging-port=$DebugPort") | Where-Object { $_ }) -join ' '
    $env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $resolvedRoot 'webview2'
    $appProcess = Start-Process -FilePath $portableExe -WorkingDirectory $resolvedRoot -PassThru
    $processStartUtc = $appProcess.StartTime.ToUniversalTime().ToString('o')
    $final.process = [ordered]@{ pid = $appProcess.Id; startUtc = $processStartUtc }

    $nodeScript = Join-Path $repoRoot 'scripts/windows-5090-startup-receipt.mjs'
    $cdpProcess = Start-Process -FilePath 'node' -ArgumentList @(
        $nodeScript, '--debug-port', $DebugPort, '--output', $cdpReceipt,
        '--expected-rows', $ExpectedRows, '--timeout-ms', $TimeoutMs,
        '--process-start-utc', $processStartUtc
    ) -PassThru -WorkingDirectory $repoRoot

    while (-not $cdpProcess.HasExited) {
        foreach ($servicePid in Get-ServicePids) {
            [void]$seenServicePids.Add([int]$servicePid)
            Write-JsonLine $serviceTracePath ([ordered]@{ atUtc = (Get-Date).ToUniversalTime().ToString('o'); pid = [int]$servicePid })
        }
        Start-Sleep -Milliseconds 50
    }
    $cdpProcess.WaitForExit()
    if (-not (Test-Path -LiteralPath $cdpReceipt -PathType Leaf)) { throw 'CDP receipt was not written' }
    $cdp = Get-Content -LiteralPath $cdpReceipt -Raw | ConvertFrom-Json
    $final.cdp = $cdp
    $final.service = [ordered]@{
        preexistingPids = @($preexistingServicePids)
        distinctPids = @($seenServicePids | Sort-Object)
        pidChanges = [math]::Max(0, $seenServicePids.Count - 1)
        zeroRestart = ($seenServicePids.Count -eq 1)
    }
    if ($cdp.verdict -ne 'PASS' -or $seenServicePids.Count -ne 1) {
        throw "Hot startup gate failed: cdp=$($cdp.verdict), distinct service PIDs=$($seenServicePids.Count)"
    }
    $final.verdict = 'PASS'
}
catch {
    $final.verdict = if ($final.process) { 'FAIL' } else { 'NOT-RUN' }
    $final.reason = $_.Exception.Message
    throw
}
finally {
    if ($null -ne $cdpProcess -and -not $cdpProcess.HasExited) {
        Stop-Process -Id $cdpProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $appProcess -and -not $appProcess.HasExited) {
        Stop-Process -Id $appProcess.Id -Force -ErrorAction SilentlyContinue
    }
    Stop-ExactServicePids @($seenServicePids)
    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = $oldWebViewArgs
    $env:WEBVIEW2_USER_DATA_FOLDER = $oldWebViewData
    $final.finishedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $final | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
}
