param(
    [switch]$CleanRecheck,
    [ValidateSet('debug', 'release')]
    [string]$Configuration = 'debug'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$packageRoot = Join-Path $repoRoot 'Packages\VispaceCore'

if (-not (Test-Path -LiteralPath (Join-Path $packageRoot 'Package.swift'))) {
    throw 'Packages/VispaceCore/Package.swift was not found.'
}

$dockerCommand = Get-Command docker -ErrorAction SilentlyContinue
$dockerExecutable = if ($dockerCommand) { $dockerCommand.Source } else { $null }
if (-not $dockerExecutable) {
    $dockerCandidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\resources\bin\docker.exe'),
        (Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe')
    )
    $dockerExecutable = $dockerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $dockerExecutable) {
    throw 'Docker CLI was not found. Install Docker Desktop with the Linux container engine, then run this script again.'
}

# Keep Linux artifacts separate from the .build directory used by Xcode/macOS.
$scratchPath = '/workspace/.build/linux-docker'

function Invoke-Swift {
    param([string[]]$SwiftArguments)

    $dockerArguments = @(
        'run', '--rm',
        '--volume', "${packageRoot}:/workspace",
        '--workdir', '/workspace',
        'swift:6.2@sha256:29b983751c605c2d3102d2ab93438c6e0cadf110d9d2aa6e929b6dec9dcb7cbc',
        'swift'
    )
    $dockerArguments += $SwiftArguments
    & $dockerExecutable @dockerArguments
    if ($LASTEXITCODE -ne 0) {
        throw "swift $($SwiftArguments -join ' ') failed."
    }
}

$previousPath = $env:PATH
try {
    # Docker's credential helper must also be discoverable for image pulls.
    $env:PATH = "$(Split-Path -Parent $dockerExecutable);$previousPath"
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 converts native stderr into ErrorRecords.
        $ErrorActionPreference = 'Continue'
        $engineType = & $dockerExecutable info --format '{{.OSType}}' 2>$null
        $engineExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($engineExitCode -ne 0 -or $engineType -ne 'linux') {
        throw 'The Docker Linux engine is unavailable. Start or repair Docker Desktop, then retry. This script does not restart services or modify Docker data.'
    }

    Invoke-Swift -SwiftArguments @('test', '--scratch-path', $scratchPath, '--configuration', $Configuration, '--parallel')

    if ($CleanRecheck) {
        Invoke-Swift -SwiftArguments @('package', '--scratch-path', $scratchPath, 'clean')
        Invoke-Swift -SwiftArguments @('test', '--scratch-path', $scratchPath, '--configuration', $Configuration, '--parallel')
    }
} finally {
    $env:PATH = $previousPath
}

Write-Host "VispaceCore $Configuration verification passed. iOS build and physical-device checks require Xcode separately."
