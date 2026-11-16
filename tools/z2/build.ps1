[CmdletBinding()]
param(
    [ValidateSet('Refresh', 'Verify', 'Export')][string]$Mode = 'Export',
    [Parameter(Mandatory = $true)][string]$GodotExe,
    [Parameter(Mandatory = $true)][string]$BuildRoot,
    [string]$OutputPck = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$projectCandidates = @('Godot/GraytailGodot', 'game') | ForEach-Object {
    $candidate = Join-Path $repoRoot $_
    if (Test-Path -LiteralPath (Join-Path $candidate 'project.godot') -PathType Leaf) { $candidate }
}
if (@($projectCandidates).Count -ne 1) {
    throw 'Expected exactly one Godot project under Godot/GraytailGodot or game.'
}
$projectRoot = [string]@($projectCandidates)[0]
$buildBase = [IO.Path]::GetFullPath($BuildRoot)
$sourcePrefix = [IO.Path]::GetFullPath($projectRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if (($buildBase + [IO.Path]::DirectorySeparatorChar).StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'BuildRoot must be outside the source Godot project.'
}
$engineSource = (Resolve-Path -LiteralPath $GodotExe).Path
$job = Join-Path $buildBase ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$mirror = Join-Path $job 'project'
$engineDir = Join-Path $job 'runtime'
$empty = Join-Path $job 'packed-run'
$relativeDigest = 'data/z2/rule_source_digest.json'
$sourceDigest = Join-Path $projectRoot $relativeDigest
$mirrorDigest = Join-Path $mirror $relativeDigest
$driver = Join-Path $PSScriptRoot 'rule_digest.gd'
$savedEnvironment = @{}

function Get-SourceInventory {
    $lines = Get-ChildItem -LiteralPath (Join-Path $projectRoot 'scripts') -Recurse -File -Filter '*.gd' |
        Sort-Object FullName | ForEach-Object {
            $_.FullName.Substring($projectRoot.Length) + '=' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    return ($lines -join "`n")
}

function Invoke-Godot([string]$Label, [string[]]$Arguments) {
    $log = Join-Path $job ($Label + '.log')
    Push-Location $empty
    try {
        # Console executable may launch its companion; both live in an isolated
        # directory without the portable-mode _sc_ marker from a local install.
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $engine @Arguments > $log 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousPreference
    } finally { Pop-Location }
    if ($exitCode -ne 0 -or (Select-String -LiteralPath $log -Pattern '^SCRIPT ERROR:|^ERROR:' -Quiet)) {
        Get-Content -LiteralPath $log -Tail 20 | Write-Host
        throw "$Label failed (exit $exitCode); see $log"
    }
    Write-Host "$Label OK: $log"
}

try {
    foreach ($directory in @($mirror, $engineDir, $empty)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    foreach ($name in @('APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP')) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        $directory = Join-Path $job $name.ToLowerInvariant()
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
        [Environment]::SetEnvironmentVariable($name, $directory, 'Process')
    }
    $savedEnvironment['Z2_EXPORT_QA_HOME'] = [Environment]::GetEnvironmentVariable('Z2_EXPORT_QA_HOME', 'Process')
    [Environment]::SetEnvironmentVariable('Z2_EXPORT_QA_HOME', $job, 'Process')
    $before = Get-SourceInventory
    [IO.File]::WriteAllText((Join-Path $job 'source-inventory.txt'), $before)
    & robocopy $projectRoot $mirror /E /XD .godot /R:1 /W:1 /NFL /NDL /NJH /NJS > (Join-Path $job 'copy.log')
    if ($LASTEXITCODE -ge 8) { throw 'Project mirror copy failed.' }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'pck_export_preset.cfg') -Destination (Join-Path $mirror 'export_presets.cfg')
    # The asset registry is CSV data, not a translation resource. A non-resource
    # include filter alone cannot override the automatic CSV translation importer.
    # Apply Keep File only in the build mirror; no source import metadata changes.
    [IO.File]::WriteAllText((Join-Path $mirror 'data/assets/asset_manifest.csv.import'), "[remap]`n`nimporter=`"keep`"`n")
    Copy-Item -LiteralPath $engineSource -Destination $engineDir
    $companion = $engineSource -replace '_console\.exe$', '.exe'
    if ($companion -ne $engineSource -and (Test-Path -LiteralPath $companion)) {
        Copy-Item -LiteralPath $companion -Destination $engineDir
    }
    $engine = Join-Path $engineDir (Split-Path $engineSource -Leaf)
    New-Item -ItemType Directory -Force -Path (Split-Path $mirrorDigest) | Out-Null
    Invoke-Godot 'import' @('--headless', '--path', $mirror, '--editor', '--import')
    if ($Mode -eq 'Refresh') {
        $revision = (& git -C $repoRoot rev-parse HEAD).Trim()
        Invoke-Godot 'draft' @('--headless', '--path', $mirror, '--script', $driver, '--', 'draft', $mirrorDigest, $revision)
        $draftPck = Join-Path $job 'draft.pck'
        Invoke-Godot 'export-draft' @('--headless', '--path', $mirror, '--export-pack', 'Z2 Windows PCK', $draftPck)
        $sealed = Join-Path $job 'sealed-digest.json'
        Invoke-Godot 'seal' @('--headless', '--main-pack', $draftPck, '--script', $driver, '--', 'seal', $sealed)
        Copy-Item -LiteralPath $sealed -Destination $mirrorDigest
    }
    Invoke-Godot 'verify-source' @('--headless', '--path', $mirror, '--script', $driver, '--', 'verify', $mirrorDigest)
    if ($Mode -eq 'Export') {
        $pck = Join-Path $job 'z2.pck'
        Invoke-Godot 'export' @('--headless', '--path', $mirror, '--export-pack', 'Z2 Windows PCK', $pck)
        Invoke-Godot 'verify-pack' @('--headless', '--main-pack', $pck, '--script', $driver, '--', 'pack-check', (Join-Path $job 'pack-identity.json'))
        $sessionProbe = Join-Path $mirror 'tests/z2_export_session_runner.gd'
        Invoke-Godot 'main-new' @('--headless', '--main-pack', $pck, '--script', $sessionProbe, '--', '--record')
        Invoke-Godot 'main-restore' @('--headless', '--main-pack', $pck, '--script', $sessionProbe, '--', '--restore')
    }
    if ($before -cne (Get-SourceInventory)) {
        throw 'Source changed during this job; no digest/package published. Freeze sources and retry.'
    }
    if ($Mode -eq 'Refresh') {
        New-Item -ItemType Directory -Force -Path (Split-Path $sourceDigest) | Out-Null
        Copy-Item -LiteralPath $mirrorDigest -Destination $sourceDigest
        Write-Host "Refreshed $sourceDigest; refresh again after any source change."
    }
    if ($Mode -eq 'Export' -and $OutputPck) {
        $output = [IO.Path]::GetFullPath($OutputPck)
        if ($output.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'OutputPck must be outside the source project.' }
        New-Item -ItemType Directory -Force -Path (Split-Path $output) | Out-Null
        Copy-Item -LiteralPath $pck -Destination $output
        Write-Host "Verified compressed PCK: $output"
    }
    Write-Host "Z2_BUILD=$Mode OK evidence=$job"
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
}
