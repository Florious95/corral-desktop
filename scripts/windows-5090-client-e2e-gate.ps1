[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$InstallerPath,

    [string]$TestRunRoot = "$env:USERPROFILE\AgentMirror-e2e-client-v011",
    [string]$ArtifactDir = "$env:USERPROFILE\agentmirror-client-e2e-v011",
    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$ServiceDistro = 'Ubuntu-24.04',
    [ValidateRange(1, 10000)]
    [int]$ExpectedRows = 1,
    [ValidateRange(1025, 65535)]
    [int]$DebugPort = 19751,
    [ValidateRange(5000, 120000)]
    [int]$TimeoutMs = 60000,
    [switch]$AllowTestCleanup
)

$ErrorActionPreference = 'Stop'
if (-not $AllowTestCleanup) {
    throw 'Fail-closed: pass -AllowTestCleanup only for the disposable client e2e bundle.'
}

$installer = [IO.Path]::GetFullPath($InstallerPath)
$root = [IO.Path]::GetFullPath($TestRunRoot).TrimEnd('\')
$artifacts = [IO.Path]::GetFullPath($ArtifactDir)
$repoRoot = Split-Path -Parent $PSScriptRoot
if ($root -notmatch '(?i)agentmirror[-_](?:e2e|test)[-_]') {
    throw "Refusing a non-disposable test root: $root"
}
if ($root -match '(?i)\\(?:Program Files|Program Files \(x86\))(?:\\|$)') {
    throw "Refusing a system installation path: $root"
}
New-Item -ItemType Directory -Force -Path $artifacts | Out-Null
$receiptPath = Join-Path $artifacts 'windows-5090-client-e2e.json'
$cdpReceipt = Join-Path $artifacts 'windows-5090-startup-receipt.json'
$serviceTrace = Join-Path $artifacts 'windows-5090-service-pids.jsonl'

$targetConsoleNames = @('conhost.exe', 'cmd.exe', 'wsl.exe', 'WindowsTerminal.exe', 'wt.exe', 'OpenConsole.exe')
function Invoke-Wsl {
    param([string[]]$Arguments)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @(& wsl.exe --distribution $ServiceDistro --exec @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $saved
    [PSCustomObject]@{ Output = @($output); ExitCode = $exitCode }
}
function Get-ServicePids {
    $result = Invoke-Wsl @('ps', '-eo', 'pid=,comm=')
    @($result.Output | ForEach-Object {
        $parts = ([string]$_).Trim() -split '\s+'
        for ($i = 0; $i -lt $parts.Count; $i++) {
            if ($parts[$i] -eq 'agentmirrord') {
                for ($j = $i - 1; $j -ge 0; $j--) {
                    $pidValue = 0
                    if ([int]::TryParse($parts[$j], [ref]$pidValue)) { $pidValue; break }
                }
            }
        }
    } | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
}
function Stop-ExactServicePids {
    param([int[]]$Pids)
    foreach ($pidValue in @($Pids | Sort-Object -Unique)) {
        & wsl.exe --distribution $ServiceDistro --exec kill -TERM ([string]$pidValue) 2>$null | Out-Null
    }
}
function Get-ConsoleSnapshot {
    $atUtc = (Get-Date).ToUniversalTime().ToString('o')
    $rows = @()
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        if ($targetConsoleNames -notcontains [string]$process.Name) { continue }
        $view = Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
        $handle = 0L
        $title = ''
        if ($null -ne $view) {
            $handle = $view.MainWindowHandle.ToInt64()
            $title = [string]$view.MainWindowTitle
        }
        $rows += [PSCustomObject]@{
            atUtc = $atUtc; name = [string]$process.Name; pid = [int]$process.ProcessId
            parentPid = [int]$process.ParentProcessId; windowHandle = $handle; windowTitle = $title
        }
    }
    @($rows)
}
function Write-JsonLine {
    param([string]$Path, [object]$Value)
    ($Value | ConvertTo-Json -Compress -Depth 10) | Add-Content -LiteralPath $Path -Encoding UTF8
}

$oldWebViewArgs = $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS
$oldWebViewData = $env:WEBVIEW2_USER_DATA_FOLDER
$appProcess = $null
$cdpProcess = $null
$seenServicePids = [Collections.Generic.HashSet[int]]::new()
$preexistingServicePids = @()
$baselineConsole = @()
$consoleEvents = @()
$seenConsolePids = @{}
$run = [ordered]@{
    schema = 'agentmirror.windows-5090.client-e2e.v1'
    installerPath = $installer
    testRunRoot = $root
    artifactDir = $artifacts
    debugPort = $DebugPort
    expectedRows = $ExpectedRows
    timeoutMs = $TimeoutMs
    verdict = 'NOT-RUN'
    tokenValuesOmitted = $true
}

try {
    if (@(Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $DebugPort -ErrorAction SilentlyContinue).Count) {
        throw "Refusing occupied WebView2 debug port $DebugPort"
    }
    $preexistingServicePids = @(Get-ServicePids)
    if ($preexistingServicePids.Count) {
        throw "Refusing to touch pre-existing WSL service: $($preexistingServicePids -join ',')"
    }
    $existingApps = @(Get-Process -Name agentmirror-desktop -ErrorAction SilentlyContinue)
    if ($existingApps.Count) { throw 'Refusing to touch a pre-existing AgentMirror process' }

    # Clean only the disposable root and this app's known per-user config.
    $uninstaller = Join-Path $root 'uninstall.exe'
    if (Test-Path -LiteralPath $uninstaller) {
        $uninstall = Start-Process -FilePath $uninstaller -ArgumentList @('/S') -Wait -PassThru -WindowStyle Hidden
        $run.uninstallExit = $uninstall.ExitCode
    }
    foreach ($path in @($root, "$env:LOCALAPPDATA\com.agentmirror.desktop", "$env:APPDATA\com.agentmirror.desktop")) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }

    $install = Start-Process -FilePath $installer -ArgumentList @('/S', "/D=$root") -Wait -PassThru -WindowStyle Hidden
    $run.installExit = $install.ExitCode
    if ($install.ExitCode -ne 0) { throw "Installer failed with exit code $($install.ExitCode)" }
    $executable = Join-Path $root 'agentmirror-desktop.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Installed executable is missing' }

    $baselineConsole = @(Get-ConsoleSnapshot)
    foreach ($row in $baselineConsole) { $seenConsolePids[[string]$row.pid] = $true }
    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = (($oldWebViewArgs, "--remote-debugging-port=$DebugPort") | Where-Object { $_ }) -join ' '
    $env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $root 'webview2'
    $appProcess = Start-Process -FilePath $executable -Verb Open -WorkingDirectory $root -PassThru
    $processStartUtc = $appProcess.StartTime.ToUniversalTime().ToString('o')
    $run.process = [ordered]@{ pid = $appProcess.Id; startUtc = $processStartUtc }

    $nodeScript = Join-Path $repoRoot 'scripts/windows-5090-startup-receipt.mjs'
    $cdpProcess = Start-Process -FilePath 'node' -ArgumentList @(
        $nodeScript, '--debug-port', $DebugPort, '--output', $cdpReceipt,
        '--expected-rows', $ExpectedRows, '--timeout-ms', $TimeoutMs,
        '--process-start-utc', $processStartUtc
    ) -PassThru -WorkingDirectory $repoRoot -WindowStyle Hidden

    while (-not $cdpProcess.HasExited) {
        foreach ($row in @(Get-ConsoleSnapshot)) {
            if (-not $seenConsolePids.ContainsKey([string]$row.pid)) {
                $seenConsolePids[[string]$row.pid] = $true
                $consoleEvents += $row
            }
        }
        foreach ($servicePid in @(Get-ServicePids)) {
            [void]$seenServicePids.Add([int]$servicePid)
            Write-JsonLine $serviceTrace ([ordered]@{ atUtc = (Get-Date).ToUniversalTime().ToString('o'); pid = [int]$servicePid })
        }
        $view = Get-Process -Id $appProcess.Id -ErrorAction SilentlyContinue
        if ($null -ne $view -and -not $view.Responding) {
            $run.notRespondingObserved = $true
        }
        Start-Sleep -Milliseconds 50
    }
    $cdpProcess.WaitForExit()
    if (-not (Test-Path -LiteralPath $cdpReceipt -PathType Leaf)) { throw 'CDP receipt was not written' }
    $cdp = Get-Content -LiteralPath $cdpReceipt -Raw | ConvertFrom-Json
    $visibleConsole = @($consoleEvents | Where-Object { $_.windowHandle -ne 0 })
    $run.cdp = $cdp
    $run.console = [ordered]@{
        baseline = $baselineConsole; newProcessEvents = $consoleEvents
        visibleNewWindows = $visibleConsole; visibleCount = $visibleConsole.Count
        noVisibleConsoleWindows = ($visibleConsole.Count -eq 0)
    }
    $run.service = [ordered]@{
        preexistingPids = @($preexistingServicePids)
        distinctPids = @($seenServicePids | Sort-Object)
        pidChanges = [math]::Max(0, $seenServicePids.Count - 1)
        zeroRestart = ($seenServicePids.Count -eq 1)
    }
    $run.notRespondingObserved = [bool]$run.notRespondingObserved
    $run.verdict = if (
        $cdp.verdict -eq 'PASS' -and
        $run.console.noVisibleConsoleWindows -and
        -not $run.notRespondingObserved -and
        $run.service.zeroRestart
    ) { 'PASS' } else { 'FAIL' }
    if ($run.verdict -ne 'PASS') { throw 'Client e2e gate failed' }
}
catch {
    $run.verdict = if ($run.process) { 'FAIL' } else { 'NOT-RUN' }
    $run.reason = $_.Exception.Message
    throw
}
finally {
    if ($null -ne $cdpProcess -and -not $cdpProcess.HasExited) { Stop-Process -Id $cdpProcess.Id -Force -ErrorAction SilentlyContinue }
    if ($null -ne $appProcess -and -not $appProcess.HasExited) { Stop-Process -Id $appProcess.Id -Force -ErrorAction SilentlyContinue }
    Stop-ExactServicePids @($seenServicePids)
    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = $oldWebViewArgs
    $env:WEBVIEW2_USER_DATA_FOLDER = $oldWebViewData
    $run.finishedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $run | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
    # One-key gate leaves no installed test bundle behind, including on failure.
    $finalUninstaller = Join-Path $root 'uninstall.exe'
    if (Test-Path -LiteralPath $finalUninstaller) {
        Start-Process -FilePath $finalUninstaller -ArgumentList @('/S') -Wait -WindowStyle Hidden | Out-Null
    }
    foreach ($path in @($root, "$env:LOCALAPPDATA\com.agentmirror.desktop", "$env:APPDATA\com.agentmirror.desktop")) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$receiptPath
