[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$repo = Split-Path $PSScriptRoot -Parent
$builderPath = Join-Path $PSScriptRoot 'build-dwarf-stitch-windows.ps1'
$tokens = $null
$parseErrors = $null
$builderAst = [System.Management.Automation.Language.Parser]::ParseFile($builderPath, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) "Builder PowerShell parse errors: $($parseErrors -join '; ')"
$ownedPathAst = $builderAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-OwnedPath'
}, $true)
Assert-True ($null -ne $ownedPathAst) 'Builder must guard recursive and move paths.'
Invoke-Expression $ownedPathAst.Extent.Text
$jxlRootAst = $builderAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Find-JxlSdkRoot'
}, $true)
Assert-True ($null -ne $jxlRootAst) 'Builder must locate the official libjxl SDK directory.'
Invoke-Expression $jxlRootAst.Extent.Text
$vsVersionAst = $builderAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-Vs18ToolchainVersion'
}, $true)
Assert-True ($null -ne $vsVersionAst) 'Builder must fail fast on incompatible Visual Studio/MSVC toolsets.'
Invoke-Expression $vsVersionAst.Extent.Text
Assert-Vs18ToolchainVersion '18.0' '14.50.35717'
Assert-Vs18ToolchainVersion '18.0' '14.51.36217'
$wrongVsRejected = $false
try { Assert-Vs18ToolchainVersion '17.14' '14.51.36217' } catch { $wrongVsRejected = $true }
Assert-True $wrongVsRejected 'Toolchain preflight accepted Visual Studio 17.'
$oldMsvcRejected = $false
try { Assert-Vs18ToolchainVersion '18.0' '14.44.35207' } catch { $oldMsvcRejected = $true }
Assert-True $oldMsvcRejected 'Toolchain preflight accepted the VS2026 MSVC 14.44 compatibility toolset.'
$rustLicenseAst = $builderAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-RustRegistryLicenses'
}, $true)
Assert-True ($null -ne $rustLicenseAst) 'Builder must collect Cargo registry dependency license texts.'
Invoke-Expression $rustLicenseAst.Extent.Text
$zipGuardAst = $builderAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-ZipMatchesPackage'
}, $true)
Assert-True ($null -ne $zipGuardAst) 'Builder must validate the final archive against the package directory.'
Invoke-Expression $zipGuardAst.Extent.Text

$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$jxlTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('pocket-jxl-sdk-test-' + [guid]::NewGuid().ToString('N'))
$jxlTestRoot = [IO.Path]::GetFullPath($jxlTestRoot)
Assert-True ($jxlTestRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetFileName($jxlTestRoot) -match '^pocket-jxl-sdk-test-[0-9a-f]{32}$') 'Refusing unsafe libjxl SDK fixture path.'
$nestedSdk = Join-Path $jxlTestRoot 'official-sdk/libjxl-0.12.0-windows-x64'
New-Item -ItemType Directory -Force -Path (Join-Path $nestedSdk 'include/jxl'), (Join-Path $nestedSdk 'lib') | Out-Null
Set-Content -LiteralPath (Join-Path $nestedSdk 'include/jxl/encode.h') -Value 'header fixture' -Encoding ascii
Set-Content -LiteralPath (Join-Path $nestedSdk 'lib/jxl.lib') -Value 'library fixture' -Encoding ascii
Assert-True ((Find-JxlSdkRoot $jxlTestRoot) -eq [IO.Path]::GetFullPath($nestedSdk)) 'Builder failed to locate a nested official libjxl SDK layout.'
Remove-Item -LiteralPath $jxlTestRoot -Recurse -Force

$cargoLicenseTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('pocket-cargo-license-test-' + [guid]::NewGuid().ToString('N'))
$cargoLicenseTestRoot = [IO.Path]::GetFullPath($cargoLicenseTestRoot)
Assert-True ($cargoLicenseTestRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetFileName($cargoLicenseTestRoot) -match '^pocket-cargo-license-test-[0-9a-f]{32}$') 'Refusing unsafe Cargo license fixture path.'
$mitRoot = Join-Path $cargoLicenseTestRoot 'registry/mit-crate-1.2.3'
$fileRoot = Join-Path $cargoLicenseTestRoot 'registry/file-crate-2.0.0'
$localRoot = Join-Path $cargoLicenseTestRoot 'workspace/local-crate'
$missingRoot = Join-Path $cargoLicenseTestRoot 'registry/missing-crate-0.1.0'
New-Item -ItemType Directory -Force -Path $mitRoot, $fileRoot, $localRoot, $missingRoot | Out-Null
Set-Content -LiteralPath (Join-Path $mitRoot 'Cargo.toml') -Value '[package]' -Encoding ascii
Set-Content -LiteralPath (Join-Path $mitRoot 'LICENSE-MIT') -Value 'MIT license fixture' -Encoding ascii
Set-Content -LiteralPath (Join-Path $fileRoot 'Cargo.toml') -Value '[package]' -Encoding ascii
Set-Content -LiteralPath (Join-Path $fileRoot 'COPYRIGHT-TEXT') -Value 'Custom declared license fixture' -Encoding ascii
Set-Content -LiteralPath (Join-Path $localRoot 'Cargo.toml') -Value '[package]' -Encoding ascii
Set-Content -LiteralPath (Join-Path $missingRoot 'Cargo.toml') -Value '[package]' -Encoding ascii
$cargoFixture = @{
    packages = @(
        @{ id = 'registry+https://example.invalid#index#mit-crate@1.2.3'; name = 'mit-crate'; version = '1.2.3'; source = 'registry+https://example.invalid/index'; manifest_path = (Join-Path $mitRoot 'Cargo.toml'); license = 'MIT'; license_file = $null },
        @{ id = 'registry+https://example.invalid#index#file-crate@2.0.0'; name = 'file-crate'; version = '2.0.0'; source = 'registry+https://example.invalid/index'; manifest_path = (Join-Path $fileRoot 'Cargo.toml'); license = 'MIT OR Apache-2.0'; license_file = 'COPYRIGHT-TEXT' },
        @{ id = 'path+file:///workspace#local-crate@0.1.0'; name = 'local-crate'; version = '0.1.0'; source = $null; manifest_path = (Join-Path $localRoot 'Cargo.toml'); license = $null; license_file = $null }
    )
} | ConvertTo-Json -Depth 6
$licenseOutput = Join-Path $cargoLicenseTestRoot 'output/rust'
$licenseInventory = Copy-RustRegistryLicenses $cargoFixture $licenseOutput
Assert-True (@($licenseInventory).Count -eq 2) 'Cargo license collector did not include exactly the registry dependencies.'
Assert-True (Test-Path -LiteralPath (Join-Path $licenseOutput 'mit-crate-1.2.3/LICENSE-MIT')) 'Collector omitted a package LICENSE file.'
Assert-True (Test-Path -LiteralPath (Join-Path $licenseOutput 'file-crate-2.0.0/COPYRIGHT-TEXT')) 'Collector did not fall back to Cargo license_file.'
Assert-True ($licenseInventory[0].files[0].sha256 -match '^[0-9a-f]{64}$') 'Cargo license inventory omitted the copied file SHA-256.'
$missingFixture = @{
    packages = @(@{ id = 'registry+https://example.invalid#index#missing-crate@0.1.0'; name = 'missing-crate'; version = '0.1.0'; source = 'registry+https://example.invalid/index'; manifest_path = (Join-Path $missingRoot 'Cargo.toml'); license = 'MIT'; license_file = $null })
} | ConvertTo-Json -Depth 6
$missingLicenseRejected = $false
try { Copy-RustRegistryLicenses $missingFixture (Join-Path $cargoLicenseTestRoot 'output/missing') } catch { $missingLicenseRejected = $true }
Assert-True $missingLicenseRejected 'Cargo license collector accepted a registry dependency without license text.'
Remove-Item -LiteralPath $cargoLicenseTestRoot -Recurse -Force

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('pocket-build-path-test-' + [guid]::NewGuid().ToString('N'))
$testRoot = [IO.Path]::GetFullPath($testRoot)
Assert-True ($testRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetFileName($testRoot) -match '^pocket-build-path-test-[0-9a-f]{32}$') 'Refusing unsafe test fixture path.'
$ownedRoot = Join-Path $testRoot 'owned'
$scopeRoot = Join-Path $ownedRoot 'scope'
$outsideRoot = Join-Path $testRoot 'outside'
$junctionPath = Join-Path $scopeRoot 'redirect'
New-Item -ItemType Directory -Force -Path $ownedRoot, $scopeRoot, $outsideRoot | Out-Null
Assert-OwnedPath (Join-Path $ownedRoot 'safe-child') $ownedRoot
$escapedRejected = $false
try { Assert-OwnedPath (Join-Path $outsideRoot 'child') $ownedRoot } catch { $escapedRejected = $true }
Assert-True $escapedRejected 'Builder path guard accepted a path outside its owned directory.'
New-Item -ItemType Junction -Path $junctionPath -Target $outsideRoot | Out-Null
$junctionRejected = $false
try { Assert-OwnedPath (Join-Path $junctionPath 'child') $ownedRoot } catch { $junctionRejected = $true }
Assert-True $junctionRejected 'Builder path guard accepted a junction escape.'
$treeJunctionRejected = $false
try { Assert-OwnedPath $scopeRoot $ownedRoot -InspectTree } catch { $treeJunctionRejected = $true }
Assert-True $treeJunctionRejected 'Builder recursive-delete guard accepted a nested junction.'
Remove-Item -LiteralPath $junctionPath -Force
Remove-Item -LiteralPath $testRoot -Recurse -Force

$zipTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('pocket-zip-test-' + [guid]::NewGuid().ToString('N'))
$zipTestRoot = [IO.Path]::GetFullPath($zipTestRoot)
Assert-True ($zipTestRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetFileName($zipTestRoot) -match '^pocket-zip-test-[0-9a-f]{32}$') 'Refusing unsafe ZIP test fixture path.'
$fixtureDir = Join-Path $zipTestRoot 'package'
$zipFixture = Join-Path $zipTestRoot 'package.zip'
New-Item -ItemType Directory -Force -Path (Join-Path $fixtureDir 'licenses') | Out-Null
Set-Content -LiteralPath (Join-Path $fixtureDir 'PocketGigaScan.exe') -Value 'executable fixture' -Encoding ascii
Set-Content -LiteralPath (Join-Path $fixtureDir 'licenses/LICENSE.libjxl') -Value 'license fixture' -Encoding ascii
[IO.Compression.ZipFile]::CreateFromDirectory($fixtureDir, $zipFixture)
Assert-ZipMatchesPackage $zipFixture $fixtureDir
Set-Content -LiteralPath (Join-Path $fixtureDir 'PocketGigaScan.exe') -Value 'tampered fixture' -Encoding ascii
$archiveMismatchRejected = $false
try { Assert-ZipMatchesPackage $zipFixture $fixtureDir } catch { $archiveMismatchRejected = $true }
Assert-True $archiveMismatchRejected 'ZIP validator accepted package contents that differ from the archive.'
Set-Content -LiteralPath (Join-Path $fixtureDir 'PocketGigaScan.exe') -Value 'executable fixture' -Encoding ascii
Remove-Item -LiteralPath (Join-Path $fixtureDir 'licenses/LICENSE.libjxl') -Force
$missingNestedEntryRejected = $false
try { Assert-ZipMatchesPackage $zipFixture $fixtureDir } catch { $missingNestedEntryRejected = $true }
Assert-True $missingNestedEntryRejected 'ZIP validator accepted a missing nested package entry.'
Remove-Item -LiteralPath $zipTestRoot -Recurse -Force

$plan = (& $builderPath -PlanOnly | ConvertFrom-Json)
Assert-True ($plan.product -eq 'PocketGigaScan' -and $plan.subtitle -eq 'DWARF Stitch') 'Plan product branding changed unexpectedly.'
Assert-True ($plan.flutterVersion -eq '3.44.2') 'Flutter pin changed unexpectedly.'
Assert-True ($plan.flutterCommit -eq 'c9a6c484230f8b5e408ec57be1ef71dee1e77020') 'Flutter commit pin changed unexpectedly.'
Assert-True ($plan.rustVersion -eq '1.88.0') 'Rust pin changed unexpectedly.'
Assert-True ($plan.minimumVisualStudioVersion -eq '18.0' -and $plan.minimumMsvcToolsetVersion -eq '14.50') 'Plan does not require the libjxl-compatible VS 18 / MSVC 14.50 toolchain.'
Assert-True ($plan.openCvVersion -eq '4.13.0' -and $plan.openCvSha256 -eq '1d40ca017ea51c533cf9fd5cbde5b5fe7ae248291ddf2af99d4c17cf8e13017d') 'OpenCV source pin or checksum changed unexpectedly.'
Assert-True ($plan.libjxlVersion -eq '0.12.0' -and $plan.libjxlSha256 -eq '3025d7e308390796d20492322e606bc92decaee7b6bc99d3f7547870ae5db7de') 'libjxl SDK pin or checksum changed unexpectedly.'
Assert-True ($plan.djxlSha256 -eq '6970ce73de51e046b39bd5f28fc7bc5da64e9f6505c11194319f43d8849d2bf4') 'Independent djxl verification tool pin changed unexpectedly.'
Assert-True (@($plan.nativeOutputs) -join ',' -eq 'png,tiff,jxl') 'Build plan does not retain PNG, TIFF, and JPEG XL formats.'
Assert-True ([IO.Path]::GetFileName($plan.releaseExecutable) -eq 'PocketGigaScan.exe') 'Windows executable name changed unexpectedly.'
Assert-True ([IO.Path]::GetFileName($plan.zip) -eq 'PocketGigaScan-Windows-x64.zip') 'Windows ZIP name changed unexpectedly.'

$cmake = Get-Content -LiteralPath (Join-Path $repo 'Apps/Flutter/stitch_app/windows/CMakeLists.txt') -Raw
$builderText = Get-Content -LiteralPath $builderPath -Raw
$runner = Get-Content -LiteralPath (Join-Path $repo 'Apps/Flutter/stitch_app/windows/runner/CMakeLists.txt') -Raw
Assert-True ($builderText -match '\$vswhereOutput = @\(& \$vswhere' -and
    $builderText -match '\$installationPath = \$vswhereOutput \| Select-Object -First 1') 'vswhere output must be captured before reading its native exit code.'
Assert-True ($cmake -match 'set\(BINARY_NAME "PocketGigaScan"\)') 'CMake binary target is not PocketGigaScan.'
Assert-True ($cmake -match 'native/core/target/release/lumia_gigascan_core\.dll') 'CMake does not stage the vendored core build.'
Assert-True ($cmake -notmatch '\.local[/\\]flutter-stitch-core') 'Windows CMake still depends on a machine-local core DLL.'
Assert-True ($builderText -match "generator = 'Visual Studio 18 2026'") 'OpenCV source build is not configured for Visual Studio 18.'
Assert-True ($builderText -match '\$vsGenerator = \$vsToolchain\.generator') 'OpenCV build does not use the selected VS 18 generator.'
Assert-True ($runner -match 'native/core/target/release/lumia_gigascan_core\.dll') 'Runner debug launch does not stage the vendored core.'
$resource = Get-Content -LiteralPath (Join-Path $repo 'Apps/Flutter/stitch_app/windows/runner/Runner.rc') -Raw
Assert-True ($resource -match 'VALUE "ProductName", "PocketGigaScan"') 'Windows product metadata is not branded PocketGigaScan.'

$workflow = Get-Content -LiteralPath (Join-Path $repo '.github/workflows/windows-build.yml') -Raw
Assert-True ($workflow -match 'pull_request:' -and $workflow -match 'push:') 'Workflow must verify both pushes and pull requests.'
Assert-True ($workflow -match 'actions/upload-artifact@') 'Workflow does not publish per-run build artifacts.'
Assert-True ($workflow -match 'actions/cache@caa296126883cff596d87d8935842f9db880ef25') 'Workflow does not cache pinned build dependencies.'
Assert-True ($workflow -match 'runs-on: windows-2025-vs2026') 'Workflow must use the compatible VS 2026 hosted image.'
Assert-True ($workflow -match 'windows-2025-vs2026-vs18-msvc-14\.50') 'Dependency cache key must encode the compatible MSVC toolchain.'
Assert-True ($workflow -match 'opencv-1d40ca017ea51c533cf9fd5cbde5b5fe7ae248291ddf2af99d4c17cf8e13017d') 'Dependency cache key must include the OpenCV source hash.'
Assert-True ($workflow -notmatch 'native/core/target') 'Workflow must not cache generated native DLL or Cargo target output.'
Assert-True ($workflow -match "github\.event_name == 'push'") 'Prerelease publication is not limited to push events.'
Assert-True ($workflow -match "github\.repository == 'sunyych/PocketGigaScan'") 'Prerelease publication is not restricted to the canonical repository.'
Assert-True ($workflow -match 'GH_REPO: \$\{\{ github\.repository \}\}') 'GitHub CLI release commands must explicitly target the current canonical repository.'
Assert-True ($workflow -match 'github\.event\.repository\.default_branch') 'Prerelease publication is not restricted to the default branch.'
Assert-True ($workflow -notmatch 'event\.repository\.fork') 'Fork metadata must not disable releases from the canonical fork.'

$icon = [IO.File]::ReadAllBytes((Join-Path $repo 'Apps/Flutter/stitch_app/windows/runner/resources/app_icon.ico'))
Assert-True ($icon.Length -gt 64 -and $icon[0] -eq 0 -and $icon[1] -eq 0 -and $icon[2] -eq 1 -and $icon[3] -eq 0) 'Windows application icon is not a valid ICO.'
Assert-True ($icon[4] -ge 5) 'Windows icon is missing multi-resolution images.'
Assert-True (Test-Path -LiteralPath (Join-Path $repo 'branding/dwarf-stitch-icon.svg')) 'Editable SVG icon source is missing.'
Assert-True (Test-Path -LiteralPath (Join-Path $repo 'branding/generate_app_icon.py')) 'Reproducible icon generator is missing.'

Write-Host 'Windows builder plan, vendored core paths, release safety, and app icon tests passed.'
