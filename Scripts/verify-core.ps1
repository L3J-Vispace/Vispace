param(
    [switch]$CleanRecheck
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$packageRoot = Join-Path $repoRoot 'Packages\VispaceCore'

if (-not (Test-Path -LiteralPath (Join-Path $packageRoot 'Package.swift'))) {
    throw 'Packages/VispaceCore/Package.swift was not found.'
}

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
    & docker @dockerArguments
    if ($LASTEXITCODE -ne 0) {
        throw "swift $($SwiftArguments -join ' ') failed."
    }
}

Invoke-Swift -SwiftArguments @('test', '--parallel')

if ($CleanRecheck) {
    Invoke-Swift -SwiftArguments @('package', 'clean')
    Invoke-Swift -SwiftArguments @('test', '--parallel')
}

Write-Host 'VispaceCore verification passed.'
