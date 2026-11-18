$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'clean-disk-space.ps1'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('\','/'))
$fixtureName = "pocketgigascan-retention-$([guid]::NewGuid().ToString('N'))"
$fixture = [IO.Path]::GetFullPath((Join-Path $tempRoot $fixtureName))
if (-not [string]::Equals((Split-Path -Parent $fixture), $tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path -Leaf $fixture) -notmatch '^pocketgigascan-retention-[0-9a-f]{32}$') {
    throw "Refusing to create or remove unexpected test fixture path: $fixture"
}
New-Item -ItemType Directory -Path $fixture | Out-Null
function Add-CompleteBuild([string]$Name, [datetime]$Timestamp) {
    $package = Join-Path $fixture "$Name/package"
    New-Item -ItemType Directory -Path $package -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $package 'PocketGigaScan.exe') -Value 'fixture'
    '{"product":"PocketGigaScan","architecture":"windows-x64"}' | Set-Content -LiteralPath (Join-Path $package 'build-manifest.json')
    (Get-Item -LiteralPath (Join-Path $package 'build-manifest.json')).LastWriteTimeUtc = $Timestamp
}
try {
    $builder = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'build-dwarf-stitch-windows.ps1') -Raw
    if ([regex]::Matches($builder, '(?m)^\s*Invoke-BuildRetention\s*$').Count -ne 3) { throw 'Retention hook must cover plain, signing-ZIP, and directory-only success paths.' }
    if ($builder -notmatch 'outputParent,\s*\$retentionRoot') { throw 'Retention hook must require a direct .build child.' }
    if ($builder -notmatch '(?s)if \(\$PlanOnly\).*?return.*?Invoke-BuildRetention') { throw 'PlanOnly must return before any retention hook call.' }

    Add-CompleteBuild 'dwarf-stitch-windows-old' ([datetime]'2026-01-01Z')
    Add-CompleteBuild 'dwarf-stitch-windows-middle' ([datetime]'2026-01-02Z')
    Add-CompleteBuild 'dwarf-stitch-windows-new' ([datetime]'2026-01-03Z')
    $incomplete = Join-Path $fixture 'dwarf-stitch-windows-interrupted/aot'
    New-Item -ItemType Directory -Path $incomplete -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixture 'unrecognized') | Out-Null
    Set-Content -LiteralPath (Join-Path $fixture 'unrecognized/keep.txt') -Value 'untouched'

    $preview = @(& $scriptPath -BuildRoot $fixture)
    if ($preview -notcontains "KEEP  $(Join-Path $fixture 'dwarf-stitch-windows-new')") { throw 'Preview did not keep the newest manifest timestamp.' }
    if ($preview -notcontains "KEEP  $(Join-Path $fixture 'dwarf-stitch-windows-middle')") { throw 'Preview did not keep the second newest complete build.' }
    if ($preview -notcontains "PREVIEW $(Join-Path $fixture 'dwarf-stitch-windows-old')") { throw 'Preview missed the old complete build.' }
    if ($preview -notcontains "PREVIEW $(Join-Path $fixture 'dwarf-stitch-windows-interrupted')") { throw 'Preview missed the recognized incomplete build.' }
    if ($preview -contains "PREVIEW $(Join-Path $fixture 'unrecognized')") { throw 'Preview included an unrecognized directory.' }
    if (-not (Test-Path -LiteralPath (Join-Path $fixture 'dwarf-stitch-windows-old'))) { throw 'Preview modified the fixture.' }

    & $scriptPath -BuildRoot $fixture -Execute -ProtectPath (Join-Path $fixture 'dwarf-stitch-windows-old') | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $fixture 'dwarf-stitch-windows-old'))) { throw 'Protected build was removed.' }
    if (Test-Path -LiteralPath (Join-Path $fixture 'dwarf-stitch-windows-interrupted')) { throw 'Recognized incomplete build was not removed.' }
    if (-not (Test-Path -LiteralPath (Join-Path $fixture 'dwarf-stitch-windows-middle'))) { throw 'Second newest complete build should remain.' }
    & $scriptPath -BuildRoot $fixture -Execute | Out-Null
    if (Test-Path -LiteralPath (Join-Path $fixture 'dwarf-stitch-windows-old')) { throw 'Oldest complete build was not removed.' }
    if (-not (Test-Path -LiteralPath (Join-Path $fixture 'dwarf-stitch-windows-middle')) -or
        -not (Test-Path -LiteralPath (Join-Path $fixture 'dwarf-stitch-windows-new'))) { throw 'The two newest complete builds were not retained.' }
    if (-not (Test-Path -LiteralPath (Join-Path $fixture 'unrecognized/keep.txt'))) { throw 'Unrecognized content was removed.' }
    Write-Output 'Build retention fixture checks passed.'
}
finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
