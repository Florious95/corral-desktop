[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$InstallerPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('(?i)agentmirror[-_](?:e2e|test)[-_]')]
    [string]$TestInstallRoot,

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

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 10000)]
    [int]$ExpectedRows,

    [ValidateRange(1025, 65535)]
    [int]$DebugPort = 19250,

    [ValidateRange(5000, 120000)]
    [int]$TimeoutMs = 30000,

    [switch]$AllowTestCleanup
)

$ErrorActionPreference = 'Stop'
if (-not $AllowTestCleanup) {
    throw 'Fail-closed: pass -AllowTestCleanup only for the independently packaged test bundle.'
}

$resolvedInstallRoot = [System.IO.Path]::GetFullPath($TestInstallRoot)
$resolvedArtifactDir = [System.IO.Path]::GetFullPath($ArtifactDir)
if ([System.IO.Path]::GetPathRoot($resolvedInstallRoot).TrimEnd('\') -eq $resolvedInstallRoot.TrimEnd('\')) {
    throw "Refusing to use a filesystem root as the test install root: $resolvedInstallRoot"
}
if ($resolvedInstallRoot -match '(?i)\\(?:Program Files|Program Files \(x86\))(?:\\|$)') {
    throw "Refusing to touch a system installation path: $resolvedInstallRoot"
}
New-Item -ItemType Directory -Path $resolvedArtifactDir -Force | Out-Null
$receiptPath = Join-Path $resolvedArtifactDir 'windows-5090-clean-install-timing.json'
$processSnapshotPath = Join-Path $resolvedArtifactDir 'windows-5090-process-snapshot.jsonl'
$serviceTracePath = Join-Path $resolvedArtifactDir 'windows-5090-service-pids.jsonl'

function Write-JsonLine {
    param([string]$Path, [object]$Value)
    ($Value | ConvertTo-Json -Compress -Depth 8) | Add-Content -LiteralPath $Path -Encoding UTF8
}

function Get-ProcessSnapshot {
    # ExecutablePath only: do not collect command lines, environment, or tokens.
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Select-Object Name, ProcessId, ParentProcessId, ExecutablePath, CreationDate)
}

function Get-TestProcesses {
    $root = $resolvedInstallRoot.TrimEnd('\') + '\'
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)
        })
}

function Stop-TestProcesses {
    foreach ($process in Get-TestProcesses) {
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
    }
}

function Remove-ExactPath {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Invoke-ExactUninstaller {
    if (-not (Test-Path -LiteralPath $resolvedInstallRoot -PathType Container)) { return }
    $uninstaller = Get-ChildItem -LiteralPath $resolvedInstallRoot -Filter 'uninstall*.exe' -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($uninstaller) {
        $result = Start-Process -FilePath $uninstaller.FullName -ArgumentList @('/S') -Wait -PassThru
        if ($result.ExitCode -ne 0) {
            throw "Test-bundle uninstaller failed with exit code $($result.ExitCode)"
        }
    }
}

function Get-ServicePids {
    $raw = & wsl.exe --distribution $ServiceDistro --exec pgrep -x $ServiceName 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    @($raw | ForEach-Object {
        $value = 0
        if ([int]::TryParse(([string]$_).Trim(), [ref]$value)) { $value }
    } | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
}

$testAppDataPaths = @(
    (Join-Path $env:APPDATA 'com.agentmirror.desktop.test'),
    (Join-Path $env:LOCALAPPDATA 'com.agentmirror.desktop.test')
)
$runStarted = Get-Date
$runId = $runStarted.ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
$oldWebViewArgs = $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS
$appProcess = $null
$cdpProcess = $null
$final = [ordered]@{
    schema = 'agentmirror.windows-5090.clean-install-timing.v1'
    runId = $runId
    installerPath = [System.IO.Path]::GetFullPath($InstallerPath)
    testInstallRoot = $resolvedInstallRoot
    artifactDir = $resolvedArtifactDir
    serviceDistro = $ServiceDistro
    serviceName = $ServiceName
    expectedRows = $ExpectedRows
    debugPort = $DebugPort
    startedAtUtc = $runStarted.ToUniversalTime().ToString('o')
    verdict = 'NOT-RUN'
}

try {
    Get-ProcessSnapshot | ForEach-Object { Write-JsonLine $processSnapshotPath ([ordered]@{ phase = 'before'; process = $_ }) }
    $preexistingServicePids = @(Get-ServicePids)
    if ($preexistingServicePids.Count -gt 0) {
        throw "Refusing to touch a pre-existing WSL service (PIDs: $($preexistingServicePids -join ',')). Isolate or stop only the test bundle first."
    }
    $occupiedDebugPort = @(Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $DebugPort -ErrorAction SilentlyContinue)
    if ($occupiedDebugPort.Count -gt 0) {
        throw "Refusing to attach to occupied WebView2 debug port $DebugPort"
    }
    Invoke-ExactUninstaller
    Stop-TestProcesses
    Remove-ExactPath $resolvedInstallRoot
    foreach ($path in $testAppDataPaths) { Remove-ExactPath $path }
    Get-ProcessSnapshot | ForEach-Object { Write-JsonLine $processSnapshotPath ([ordered]@{ phase = 'after-clean'; process = $_ }) }

    New-Item -ItemType Directory -Path $resolvedInstallRoot -Force | Out-Null
    $installStarted = [System.Diagnostics.Stopwatch]::GetTimestamp()
    $installer = Start-Process -FilePath ([System.IO.Path]::GetFullPath($InstallerPath)) `
        -ArgumentList @('/S', "/D=$resolvedInstallRoot") -Wait -PassThru
    $installElapsedMs = [math]::Round((([System.Diagnostics.Stopwatch]::GetTimestamp() - $installStarted) * 1000.0) / [System.Diagnostics.Stopwatch]::Frequency, 3)
    $final.install = [ordered]@{ exitCode = $installer.ExitCode; elapsedMs = $installElapsedMs }
    if ($installer.ExitCode -ne 0) { throw "NSIS installer failed with exit code $($installer.ExitCode)" }

    $exe = Get-ChildItem -LiteralPath $resolvedInstallRoot -Filter '*.exe' -File -Recurse |
        Where-Object { $_.Name -notmatch '(?i)uninstall' } |
        Select-Object -First 1
    if (-not $exe) { throw "No test-bundle executable found under $resolvedInstallRoot" }

    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = (($oldWebViewArgs, "--remote-debugging-port=$DebugPort") | Where-Object { $_ }) -join ' '
    $appProcess = Start-Process -FilePath $exe.FullName -WorkingDirectory $resolvedInstallRoot -PassThru
    $processStartUtc = $appProcess.StartTime.ToUniversalTime().ToString('o')
    $final.process = [ordered]@{ pid = $appProcess.Id; executable = $exe.FullName; startUtc = $processStartUtc }

    $cdpReceipt = Join-Path $resolvedArtifactDir 'windows-5090-startup-receipt.json'
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $nodeScript = Join-Path $repoRoot 'scripts/windows-5090-startup-receipt.mjs'
    $cdpProcess = Start-Process -FilePath 'node' -ArgumentList @(
        $nodeScript, '--debug-port', $DebugPort, '--output', $cdpReceipt,
        '--expected-rows', $ExpectedRows, '--timeout-ms', $TimeoutMs,
        '--process-start-utc', $processStartUtc
    ) -PassThru -WorkingDirectory $repoRoot

    $seenServicePids = [System.Collections.Generic.HashSet[int]]::new()
    while (-not $cdpProcess.HasExited) {
        foreach ($pid in Get-ServicePids) {
            [void]$seenServicePids.Add([int]$pid)
            Write-JsonLine $serviceTracePath ([ordered]@{
                atUtc = (Get-Date).ToUniversalTime().ToString('o')
                pid = [int]$pid
            })
        }
        Start-Sleep -Milliseconds 100
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
        throw "Startup gate failed: cdp=$($cdp.verdict), distinct service PIDs=$($seenServicePids.Count)"
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
    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = $oldWebViewArgs
    $final.finishedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $final | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
}
