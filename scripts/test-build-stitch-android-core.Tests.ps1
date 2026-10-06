[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$scriptPath = Join-Path $PSScriptRoot 'build-stitch-android-core.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) "Android core builder parse errors: $($errors -join '; ')"
$elfCheckAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-AndroidElfText'
}, $true)
Assert-True ($null -ne $elfCheckAst) 'Builder must define the ELF alignment validator.'
Invoke-Expression $elfCheckAst.Extent.Text
$source = Get-Content -LiteralPath $scriptPath -Raw

foreach ($required in @(
    'native\core',
    "28.2.13676358",
    "android-`$ApiLevel",
    "`$opencvSha256 = 'edfda20fdf65d0bd45391d168ec5261dd30b600b00279c4d910d7f1c3e020f0f'",
    "03e9be69a30be4011f559da75328b6d7cea8ad921fabfbd551ce10bf45cdc992",
    "0afe09a53c8bad9861c8dd1fc1284308d54f19d2979ba3541cfdcc9b05fe360f",
    "5124b0501c98d9930dbb065bfa1a5bbbd59ce0f12facb7e1e33aaef01a5f1f1a",
    "9bb4b5bba0b7c04f6c2bce9ff713d61e23c9a20c4945161ae16290498ad74627",
    "--no-undefined",
    "max-page-size=16384",
    "libc++_shared.so",
    "build-manifest.json",
    "`$JxlOnly",
    "`$BuildTests",
    "bundledIntoApk=`$false",
    "native-licenses",
    "coreSourceTreeSha256",
    "source archive",
    "Join-Path `$cache 'staging\publish'",
    "Join-Path `$cache 'staging\backups'"
)) {
    Assert-True ($source.Contains($required)) "Android builder is missing contract token: $required"
}
Assert-True ($source -match "'arm64-v8a'\s*=\s*@\{[^}]+Machine='AArch64'") 'ARM64 ABI must be defined and checked.'
Assert-True ($source -match "'x86_64'\s*=\s*@\{[^}]+Machine='Advanced Micro Devices X86-64'") 'Optional x86_64 ABI must be defined and checked.'
Assert-True ($source.Contains("link-arg=-Wl,--no-undefined")) 'Native link must reject unresolved symbols.'
Assert-True ($source.Contains('LOAD\s+')) 'ELF load segments must be inspected for 16 KiB alignment.'
Assert-True ($source -notmatch 'Join-Path\s+\$output\s+.{0,2}\.staging') 'Temporary ABI staging must stay outside Gradle jniLibs.'
Assert-True ($source -notmatch '\$licenseRoot\.previous-|Join-Path\s+\$assetsOwner\s+.{0,2}\.native-licenses-staging') 'Temporary license staging and backups must stay outside Gradle assets.'
Assert-True ($source -match '\$backup\s*=\s*Assert-OwnedPath\s*\(Join-Path\s+\$backupRoot') 'Publish backups must be guarded under the private cache staging tree.'
Assert-True ($source -notmatch 'build-gigascan-android|Apps\\Android|camera') 'New builder must not revive retired camera code.'

$buildRs = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'native\core\build.rs') -Raw
Assert-True ($buildRs.Contains('CARGO_CFG_TARGET_OS')) 'C++ tool flags must follow the Cargo target OS.'
Assert-True ($buildRs.Contains('target_os == "android"')) 'JPEG XL static support must include Android targets.'
Assert-True ($buildRs.Contains('LUMIA_JXL_LINK_PATHS')) 'Android JPEG XL must support per-ABI static-library paths.'

$validHeader = "Machine: AArch64"
$validSegments = @'
  LOAD           0x000000 0x0000000000000000 0x0000000000000000 0x001000 0x001000 R E 0x4000
  LOAD           0x004000 0x0000000000004000 0x0000000000004000 0x001000 0x001000 RW  0x4000
  GNU_RELRO      0x004000 0x0000000000004000 0x0000000000004000 0x000200 0x000200 R   0x1
'@
$valid = Assert-AndroidElfText 'arm64-v8a' $validHeader $validSegments
Assert-True ($valid.loadSegments -eq 2 -and $valid.hasGnuRelro) 'Valid 16 KiB ELF fixture was not accepted.'

function Assert-RejectedElf([string]$Header, [string]$Segments, [string]$Case) {
    $rejected = $false
    try { [void](Assert-AndroidElfText 'arm64-v8a' $Header $Segments) } catch { $rejected = $true }
    Assert-True $rejected "ELF validator accepted invalid fixture: $Case"
}
$badAlignment = $validSegments.Replace('0x4000', '0x1000')
Assert-RejectedElf $validHeader $badAlignment 'wrong alignment'
Assert-RejectedElf $validHeader "  GNU_RELRO 0x0 0x0 0x0 0x0 0x0 R 0x1`n" 'no LOAD segments'
Assert-RejectedElf $validHeader "  LOAD 0x0 0x0`n  GNU_RELRO 0x0 0x0 0x0 0x0 0x0 R 0x1`n" 'malformed LOAD segment'
Assert-RejectedElf $validHeader ($validSegments.Replace('0x004000 0x0000000000004000', '0x004000 0x0000000000005000')) 'incongruent offset and address'
Assert-RejectedElf $validHeader ($validSegments -replace '(?m)^\s*GNU_RELRO.*\r?\n?', '') 'missing GNU_RELRO'
Assert-RejectedElf 'Machine: X86-64' $validSegments 'wrong ABI machine'

Write-Host 'Android core builder contract passed.'
