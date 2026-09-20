[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallerPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
    throw "NSIS installer was not found: $InstallerPath"
}

$processNames = @('AgentMirror', 'agentmirror-desktop')
$knownResiduePaths = @(
    (Join-Path $env:LOCALAPPDATA 'AgentMirror'),
    (Join-Path $env:LOCALAPPDATA 'Programs\AgentMirror'),
    (Join-Path $env:APPDATA 'AgentMirror'),
    (Join-Path $env:ProgramData 'AgentMirror'),
    (Join-Path $env:ProgramFiles 'AgentMirror'),
    (Join-Path ${env:ProgramFiles(x86)} 'AgentMirror')
) | Where-Object { $_ } | Select-Object -Unique

function Stop-AgentMirrorProcesses {
    Get-Process -Name $processNames -ErrorAction SilentlyContinue |
        Sort-Object -Property Id -Unique |
        ForEach-Object {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
}

function Remove-AgentMirrorResidue {
    Stop-AgentMirrorProcesses
    foreach ($path in $knownResiduePaths) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

Remove-AgentMirrorResidue
$installDir = Join-Path $env:RUNNER_TEMP 'AgentMirror-e2e-install'
if (Test-Path -LiteralPath $installDir) {
    Remove-Item -LiteralPath $installDir -Recurse -Force
}
New-Item -ItemType Directory -Path $installDir -Force | Out-Null

$appProcess = $null
try {
    $installResult = Start-Process -FilePath $InstallerPath `
        -ArgumentList @('/S', "/D=$installDir") `
        -Wait -PassThru
    if ($installResult.ExitCode -ne 0) {
        throw "NSIS installer failed with exit code $($installResult.ExitCode)"
    }

    $exe = @('AgentMirror.exe', 'agentmirror-desktop.exe') |
        ForEach-Object {
            Get-ChildItem -LiteralPath $installDir -Filter $_ -File -Recurse -ErrorAction SilentlyContinue
        } |
        Select-Object -First 1
    if (-not $exe) {
        throw "Installed AgentMirror executable was not found under $installDir"
    }

    $appProcess = Start-Process -FilePath $exe.FullName `
        -WorkingDirectory $installDir -PassThru
    Start-Sleep -Seconds 10
    if ($appProcess.HasExited) {
        throw "Installed AgentMirror exited during the smoke test (code $($appProcess.ExitCode))"
    }

    Write-Host "Windows install and launch smoke test passed: $($exe.FullName)"
}
finally {
    if ($appProcess -and -not $appProcess.HasExited) {
        Stop-Process -Id $appProcess.Id -Force -ErrorAction SilentlyContinue
    }
    Stop-AgentMirrorProcesses
    if (Test-Path -LiteralPath $installDir) {
        Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
