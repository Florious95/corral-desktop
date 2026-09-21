[CmdletBinding(DefaultParameterSetName = 'Create')]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$Distro,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^am-e2e-[a-z0-9-]+$')]
    [string]$Session,

    [Parameter(Mandatory = $true)]
    [ValidateScript({
        if (-not (Test-Path -LiteralPath $_ -PathType Container)) {
            New-Item -ItemType Directory -Path $_ -Force | Out-Null
        }
        $true
    })]
    [string]$ArtifactDir,

    [Parameter(ParameterSetName = 'Create', Mandatory = $true)]
    [switch]$Create,

    [Parameter(ParameterSetName = 'Cleanup', Mandatory = $true)]
    [switch]$Cleanup
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $ArtifactDir -Force | Out-Null
$receiptPath = Join-Path $ArtifactDir "fixture-$Session.json"

function Invoke-WslTmux {
    param([string[]]$Arguments)
    $output = & wsl.exe --distribution $Distro --exec tmux @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "WSL tmux command failed with exit code $LASTEXITCODE"
    }
    @($output)
}

function Get-SessionCount {
    $names = Invoke-WslTmux @('list-sessions', '-F', '#{session_name}')
    @($names | Where-Object { $_ -is [string] -and $_.Trim() }).Count
}

function Has-Session {
    & wsl.exe --distribution $Distro --exec tmux has-session -t $Session 2>$null
    $LASTEXITCODE -eq 0
}

if ($Create) {
    if (Has-Session) {
        throw "Refusing to reuse existing fixture session: $Session"
    }
    & wsl.exe --distribution $Distro --exec tmux new-session -d -s $Session -n agent -- /bin/sh -lc 'while :; do sleep 3600; done' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to create fixture session $Session"
    }
    $receipt = [ordered]@{
        schema = 'agentmirror.windows-5090.fixture.v1'
        distro = $Distro
        session = $Session
        expectedRows = Get-SessionCount
        createdAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
    Write-Output ($receipt | ConvertTo-Json -Compress)
    exit 0
}

if (-not (Has-Session)) {
    throw "Fixture session does not exist: $Session"
}
& wsl.exe --distribution $Distro --exec tmux kill-session -t $Session 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Unable to clean fixture session $Session"
}
$receipt = [ordered]@{
    schema = 'agentmirror.windows-5090.fixture.v1'
    distro = $Distro
    session = $Session
    remainingSessions = Get-SessionCount
    cleanedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
}
$receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
Write-Output ($receipt | ConvertTo-Json -Compress)
