[CmdletBinding()]
param(
    [string]$BuildRoot,
    [switch]$Execute,
    [string]$ProtectPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not $BuildRoot) { $BuildRoot = Join-Path $repo '.build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$repo = [IO.Path]::GetFullPath($repo)
$protected = if ($ProtectPath) { [IO.Path]::GetFullPath($ProtectPath) } else { $null }

function Assert-SafeTree([string]$Path) {
    $root = [IO.Path]::GetFullPath($BuildRoot).TrimEnd([char[]]@('\','/'))
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing path outside build root: $full"
    }
    $cursor = [IO.Path]::GetPathRoot($full)
    foreach ($part in $full.Substring($cursor.Length).Split([IO.Path]::DirectorySeparatorChar, [StringSplitOptions]::RemoveEmptyEntries)) {
        $cursor = Join-Path $cursor $part
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point in candidate path: $cursor" }
        }
    }
    foreach ($entry in Get-ChildItem -LiteralPath $full -Force -Recurse) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Nested reparse point in candidate: $($entry.FullName)" }
    }
    $relative = [IO.Path]::GetRelativePath($repo, $full).Replace('\','/') + '/'
    if (-not $relative.StartsWith('../')) {
        $tracked = @(& git -c "safe.directory=$repo" -C $repo ls-files -- $relative 2>$null)
        if ($LASTEXITCODE -ne 0) { throw "git ls-files failed while checking candidate: $full" }
        $tracked = @($tracked | Where-Object { $_.StartsWith($relative, [StringComparison]::OrdinalIgnoreCase) })
        if ($tracked.Count) { throw "Tracked file found in candidate: $($tracked[0])" }
    }
}

if (-not (Test-Path -LiteralPath $BuildRoot -PathType Container)) { throw "Build root not found: $BuildRoot" }
$rootItem = Get-Item -LiteralPath $BuildRoot -Force
if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Build root is a reparse point: $BuildRoot" }

$complete = [Collections.Generic.List[object]]::new()
$incomplete = [Collections.Generic.List[object]]::new()
foreach ($dir in Get-ChildItem -LiteralPath $BuildRoot -Directory -Force) {
    if ($dir.Name -notlike 'dwarf-stitch-windows*') { continue }
    Assert-SafeTree $dir.FullName
    $manifest = Join-Path $dir.FullName 'package/build-manifest.json'
    $exe = Join-Path $dir.FullName 'package/PocketGigaScan.exe'
    if ((Test-Path -LiteralPath $manifest -PathType Leaf) -and (Test-Path -LiteralPath $exe -PathType Leaf)) {
        try { $data = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($data.product -ne 'PocketGigaScan' -or $data.architecture -ne 'windows-x64') { continue }
        $complete.Add([pscustomobject]@{ Directory = $dir; Timestamp = (Get-Item -LiteralPath $manifest).LastWriteTimeUtc })
    } elseif ((Test-Path -LiteralPath (Join-Path $dir.FullName 'aot') -PathType Container) -or
              (Test-Path -LiteralPath (Join-Path $dir.FullName 'flutter_assets') -PathType Container) -or
              (Test-Path -LiteralPath (Join-Path $dir.FullName 'build-environment.txt') -PathType Leaf)) {
        $incomplete.Add($dir)
    }
}
$keepRecords = @($complete | Sort-Object Timestamp -Descending | Select-Object -First 2)
$keep = @($keepRecords | ForEach-Object { $_.Directory })
$keepPaths = @($keep | ForEach-Object { [IO.Path]::GetFullPath($_.FullName) })
$remove = @($incomplete) + @($complete | Where-Object { [IO.Path]::GetFullPath($_.Directory.FullName) -notin $keepPaths } | ForEach-Object { $_.Directory })
if ($protected) { $remove = @($remove | Where-Object { -not [string]::Equals([IO.Path]::GetFullPath($_.FullName), $protected, [StringComparison]::OrdinalIgnoreCase) }) }

foreach ($dir in $remove) { Assert-SafeTree $dir.FullName }
if ($Execute -and $remove.Count) {
    $busyNames = @('cargo','rustc','cmake','ninja','MSBuild','flutter','PocketGigaScan')
    $busy = @(Get-Process -Name $busyNames -ErrorAction SilentlyContinue)
    if ($busy.Count) { throw "Build or product process is running: $($busy[0].ProcessName) (PID $($busy[0].Id)); refusing cleanup." }
}

foreach ($record in $keepRecords) { Write-Output "KEEP  $($record.Directory.FullName)" }
foreach ($dir in $remove) {
    Write-Output "$(if ($Execute) {'DELETE'} else {'PREVIEW'}) $($dir.FullName)"
    if ($Execute) { Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop }
}
