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
$cleanOutputsAst = $builderAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Clear-OwnedFlutterWindowsBuildOutputs'
}, $true)
Assert-True ($null -ne $cleanOutputsAst) 'Builder must clear owned Flutter assets and stale Release outputs before packaging.'
Invoke-Expression $cleanOutputsAst.Extent.Text
$releaseAssetsAst = $builderAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-WindowsReleaseAssets'
}, $true)
Assert-True ($null -ne $releaseAssetsAst) 'Builder must reject incomplete, debug, or integration-test Release assets.'
Invoke-Expression $releaseAssetsAst.Extent.Text
$productMetadataAst = $builderAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-WindowsProductVersionMetadata'
}, $true)
Assert-True ($null -ne $productMetadataAst) 'Builder must verify product name and version metadata before signing.'
Invoke-Expression $productMetadataAst.Extent.Text
$verifiedCoreCopyAst = $builderAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-VerifiedNativeCoreDll'
}, $true)
Assert-True ($null -ne $verifiedCoreCopyAst) 'Builder must verify and safely stage the freshly built native core DLL.'
Invoke-Expression $verifiedCoreCopyAst.Extent.Text
$coreExportCapabilitiesAst = $builderAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-CoreExportCapabilities'
}, $true)
Assert-True ($null -ne $coreExportCapabilitiesAst) 'Builder must require every declared native export format.'
Invoke-Expression $coreExportCapabilitiesAst.Extent.Text
$saveVerifiedArchiveAst = $builderAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-VerifiedArchive'
}, $true)
Assert-True ($null -ne $saveVerifiedArchiveAst) 'Builder must validate downloaded model archives against their pinned SHA-256.'
Invoke-Expression $saveVerifiedArchiveAst.Extent.Text
$sceneModelAssertAst = $builderAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-SceneModel'
}, $true)
Assert-True ($null -ne $sceneModelAssertAst) 'Builder must check the model manifest and actual ONNX size/SHA-256.'
Invoke-Expression $sceneModelAssertAst.Extent.Text
$sceneModelResolverAst = $builderAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-SceneModelPath'
}, $true)
Assert-True ($null -ne $sceneModelResolverAst) 'Builder must resolve the frozen model asset or caller-provided override.'
Invoke-Expression $sceneModelResolverAst.Extent.Text
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
$peMachineAst = $builderAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-PeMachine'
}, $true)
Assert-True ($null -ne $peMachineAst) 'Builder must inspect the architecture of redistributable runtime DLLs.'
Invoke-Expression $peMachineAst.Extent.Text
$vcRuntimeAst = $builderAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-VcRuntime'
}, $true)
Assert-True ($null -ne $vcRuntimeAst) 'Builder must package the selected app-local VC runtime.'
Invoke-Expression $vcRuntimeAst.Extent.Text

$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$releaseAssetsTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('pocket-release-assets-test-' + [guid]::NewGuid().ToString('N'))
$releaseAssetsTestRoot = [IO.Path]::GetFullPath($releaseAssetsTestRoot)
Assert-True ($releaseAssetsTestRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetFileName($releaseAssetsTestRoot) -match '^pocket-release-assets-test-[0-9a-f]{32}$') 'Refusing unsafe Release asset fixture path.'
$validRelease = Join-Path $releaseAssetsTestRoot 'valid/Release'
New-Item -ItemType Directory -Force -Path (Join-Path $validRelease 'data') | Out-Null
Set-Content -LiteralPath (Join-Path $validRelease 'data/app.so') -Value 'AOT fixture' -Encoding ascii
Set-Content -LiteralPath (Join-Path $validRelease 'data/icudtl.dat') -Value 'runtime data fixture' -Encoding ascii
Assert-WindowsReleaseAssets $validRelease
$missingAotRejected = $false
try { Assert-WindowsReleaseAssets (Join-Path $releaseAssetsTestRoot 'missing/Release') } catch { $missingAotRejected = $true }
Assert-True $missingAotRejected 'Release asset guard accepted a missing output directory/AOT app.so.'
$debugMixedRelease = Join-Path $releaseAssetsTestRoot 'debug-mixed/Release'
New-Item -ItemType Directory -Force -Path (Join-Path $debugMixedRelease 'data/flutter_assets') | Out-Null
Set-Content -LiteralPath (Join-Path $debugMixedRelease 'data/app.so') -Value 'AOT fixture' -Encoding ascii
Set-Content -LiteralPath (Join-Path $debugMixedRelease 'data/flutter_assets/kernel_blob.bin') -Value 'debug kernel fixture' -Encoding ascii
$debugAssetsRejected = $false
try { Assert-WindowsReleaseAssets $debugMixedRelease } catch { $debugAssetsRejected = $true }
Assert-True $debugAssetsRejected 'Release asset guard accepted a mixed AOT/debug Flutter bundle.'
$integrationTestRelease = Join-Path $releaseAssetsTestRoot 'integration/Release'
New-Item -ItemType Directory -Force -Path (Join-Path $integrationTestRelease 'data') | Out-Null
Set-Content -LiteralPath (Join-Path $integrationTestRelease 'data/app.so') -Value 'AOT fixture' -Encoding ascii
Set-Content -LiteralPath (Join-Path $integrationTestRelease 'integration_test_plugin.dll') -Value 'test plugin fixture' -Encoding ascii
$integrationPluginRejected = $false
try { Assert-WindowsReleaseAssets $integrationTestRelease } catch { $integrationPluginRejected = $true }
Assert-True $integrationPluginRejected 'Release asset guard accepted integration_test_plugin.dll.'
Remove-Item -LiteralPath $releaseAssetsTestRoot -Recurse -Force

$cleanOutputsTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('pocket-clean-flutter-outputs-test-' + [guid]::NewGuid().ToString('N'))
$cleanOutputsTestRoot = [IO.Path]::GetFullPath($cleanOutputsTestRoot)
Assert-True ($cleanOutputsTestRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetFileName($cleanOutputsTestRoot) -match '^pocket-clean-flutter-outputs-test-[0-9a-f]{32}$') 'Refusing unsafe clean-output fixture path.'
$cleanOwner = Join-Path $cleanOutputsTestRoot 'app'
$ownedAssets = Join-Path $cleanOwner 'build/flutter_assets'
$ownedRelease = Join-Path $cleanOwner 'build/windows/x64/runner/Release'
$preservedBuildOutput = Join-Path $cleanOwner 'build/windows/x64/runner/Debug/keep.bin'
New-Item -ItemType Directory -Force -Path $ownedAssets, $ownedRelease, (Split-Path $preservedBuildOutput -Parent) | Out-Null
Set-Content -LiteralPath (Join-Path $ownedAssets 'stale-fixture.bin') -Value 'stale fixture' -Encoding ascii
Set-Content -LiteralPath (Join-Path $ownedRelease 'stale-fixture.dll') -Value 'stale fixture' -Encoding ascii
Set-Content -LiteralPath $preservedBuildOutput -Value 'preserve unrelated configuration' -Encoding ascii
Clear-OwnedFlutterWindowsBuildOutputs $ownedAssets $ownedRelease $cleanOwner
Assert-True (-not (Test-Path -LiteralPath $ownedAssets) -and -not (Test-Path -LiteralPath $ownedRelease)) 'Build output cleanup left stale Flutter assets or Release files.'
Assert-True (Test-Path -LiteralPath $preservedBuildOutput -PathType Leaf) 'Build output cleanup removed unrelated generated files.'
$escapeAssets = Join-Path $cleanOwner 'build/flutter_assets'
$outsideRelease = Join-Path $cleanOutputsTestRoot 'outside/Release'
New-Item -ItemType Directory -Force -Path $escapeAssets, $outsideRelease | Out-Null
Set-Content -LiteralPath (Join-Path $escapeAssets 'keep.bin') -Value 'keep fixture' -Encoding ascii
$escapeCleanupRejected = $false
try { Clear-OwnedFlutterWindowsBuildOutputs $escapeAssets $outsideRelease $cleanOwner } catch { $escapeCleanupRejected = $true }
Assert-True $escapeCleanupRejected 'Build output cleanup accepted a Release path outside the owned app directory.'
Assert-True (Test-Path -LiteralPath (Join-Path $escapeAssets 'keep.bin') -PathType Leaf) 'Cleanup partially ran before rejecting an unowned path.'
Remove-Item -LiteralPath $cleanOutputsTestRoot -Recurse -Force

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

$vcRuntimeTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('pocket-vc-runtime-test-' + [guid]::NewGuid().ToString('N'))
$vcRuntimeTestRoot = [IO.Path]::GetFullPath($vcRuntimeTestRoot)
Assert-True ($vcRuntimeTestRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetFileName($vcRuntimeTestRoot) -match '^pocket-vc-runtime-test-[0-9a-f]{32}$') 'Refusing unsafe VC runtime fixture path.'
$crtFixture = Join-Path $vcRuntimeTestRoot 'VC/Redist/MSVC/14.51.36231/x64/Microsoft.VC145.CRT'
$crtPackage = Join-Path $vcRuntimeTestRoot 'package'
New-Item -ItemType Directory -Force -Path $crtFixture | Out-Null
function Write-TestPe([string]$Path, [int]$Machine) {
    $bytes = New-Object byte[] 160
    $bytes[0] = 0x4D; $bytes[1] = 0x5A
    [BitConverter]::GetBytes([int]0x80).CopyTo($bytes, 0x3C)
    $bytes[0x80] = 0x50; $bytes[0x81] = 0x45
    [BitConverter]::GetBytes([uint16]$Machine).CopyTo($bytes, 0x84)
    [IO.File]::WriteAllBytes($Path, $bytes)
}
foreach ($runtimeDll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    Write-TestPe (Join-Path $crtFixture $runtimeDll) 0x8664
}
Set-Content -LiteralPath (Join-Path $crtFixture 'Microsoft.VC145.CRT.manifest') -Value '<assembly />' -Encoding ascii
$runtimeInventory = Copy-VcRuntime $crtFixture $crtPackage
Assert-True (@($runtimeInventory | Where-Object { $_.architecture -eq 'x64' }).Count -eq 3) 'Runtime package inventory did not identify all x64 DLLs.'
$invalidRuntimeHashes = @($runtimeInventory | Where-Object { $_.sha256 -notmatch '^[0-9a-f]{64}$' })
Assert-True ($invalidRuntimeHashes.Count -eq 0) 'Runtime package inventory omitted file SHA-256 hashes.'
foreach ($runtimeDll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    Assert-True (Test-Path -LiteralPath (Join-Path $crtPackage $runtimeDll) -PathType Leaf) "VC runtime DLL was not copied: $runtimeDll"
}
Remove-Item -LiteralPath (Join-Path $crtFixture 'vcruntime140_1.dll') -Force
$missingRuntimeRejected = $false
try { Copy-VcRuntime $crtFixture (Join-Path $vcRuntimeTestRoot 'missing-package') } catch { $missingRuntimeRejected = $true }
Assert-True $missingRuntimeRejected 'VC runtime copier accepted a missing required runtime DLL.'
Write-TestPe (Join-Path $crtFixture 'vcruntime140_1.dll') 0x014c
$wrongArchitectureRejected = $false
try { Copy-VcRuntime $crtFixture (Join-Path $vcRuntimeTestRoot 'wrong-architecture-package') } catch { $wrongArchitectureRejected = $true }
Assert-True $wrongArchitectureRejected 'VC runtime copier accepted an x86 DLL in the x64 runtime folder.'
Remove-Item -LiteralPath $vcRuntimeTestRoot -Recurse -Force

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
try {
    New-Item -ItemType Junction -Path $junctionPath -Target $outsideRoot -ErrorAction Stop | Out-Null
    $junctionRejected = $false
    try { Assert-OwnedPath (Join-Path $junctionPath 'child') $ownedRoot } catch { $junctionRejected = $true }
    Assert-True $junctionRejected 'Builder path guard accepted a junction escape.'
    $treeJunctionRejected = $false
    try { Assert-OwnedPath $scopeRoot $ownedRoot -InspectTree } catch { $treeJunctionRejected = $true }
    Assert-True $treeJunctionRejected 'Builder recursive-delete guard accepted a nested junction.'
    Remove-Item -LiteralPath $junctionPath -Force
} catch {
    if ($_.Exception.Message -match 'Access is denied|denied|privilege') {
        Write-Warning 'Junction escape checks skipped because this Windows account cannot create junctions.'
    } else {
        throw
    }
}
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
$validCoreFormats = [pscustomobject]@{
    exportFormats = [pscustomobject]@{ png = $true; tiff = $true; jpeg = $true; jxl = $true }
    jpegXlAvailable = $true
}
Assert-True ((Assert-CoreExportCapabilities $validCoreFormats).exportFormats.jpeg -eq $true) 'Core export contract rejected the current PNG/TIFF/JPEG/JPEG XL capability set.'
$missingJpegRejected = $false
try {
    Assert-CoreExportCapabilities ([pscustomobject]@{
        exportFormats = [pscustomobject]@{ png = $true; tiff = $true; jpeg = $false; jxl = $true }
        jpegXlAvailable = $true
    }) | Out-Null
} catch { $missingJpegRejected = $_.Exception.Message -match 'JPEG' }
Assert-True $missingJpegRejected 'Core export contract accepted a missing JPEG capability.'
Assert-True ($plan.product -eq 'PocketGigaScan' -and $plan.subtitle -eq 'DWARF Stitch') 'Plan product branding changed unexpectedly.'
Assert-True ($plan.flutterVersion -eq '3.44.2') 'Flutter pin changed unexpectedly.'
Assert-True ($plan.flutterCommit -eq 'c9a6c484230f8b5e408ec57be1ef71dee1e77020') 'Flutter commit pin changed unexpectedly.'
Assert-True ($plan.rustVersion -eq '1.88.0') 'Rust pin changed unexpectedly.'
Assert-True ($plan.minimumVisualStudioVersion -eq '18.0' -and $plan.minimumMsvcToolsetVersion -eq '14.50') 'Plan does not require the libjxl-compatible VS 18 / MSVC 14.50 toolchain.'
Assert-True ($plan.openCvVersion -eq '4.13.0' -and $plan.openCvSha256 -eq '1d40ca017ea51c533cf9fd5cbde5b5fe7ae248291ddf2af99d4c17cf8e13017d') 'OpenCV source pin or checksum changed unexpectedly.'
Assert-True ($plan.libjxlVersion -eq '0.12.0' -and $plan.libjxlSha256 -eq '3025d7e308390796d20492322e606bc92decaee7b6bc99d3f7547870ae5db7de') 'libjxl SDK pin or checksum changed unexpectedly.'
Assert-True ($plan.onnxRuntimeVersion -eq '1.31.0' -and $plan.onnxRuntimeSha256 -eq '3958d8a44984160692c1b4ffd0de3cb48f8c39f9d34bb31e433db06e30b82195') 'ONNX Runtime SDK pin or checksum changed unexpectedly.'
Assert-True ($plan.sceneModelId -eq 'openmmlab/upernet-convnext-tiny@876ffc56b819a829448f7e81e9f8606deef6fb65') 'Scene model revision changed unexpectedly.'
Assert-True ($plan.djxlSha256 -eq '6970ce73de51e046b39bd5f28fc7bc5da64e9f6505c11194319f43d8849d2bf4') 'Independent djxl verification tool pin changed unexpectedly.'
Assert-True (@($plan.nativeOutputs) -join ',' -eq 'png,tiff,jpeg,jxl') 'Build plan does not retain PNG, TIFF, JPEG, and JPEG XL formats.'
Assert-True ([IO.Path]::GetFileName($plan.releaseExecutable) -eq 'PocketGigaScan.exe') 'Windows executable name changed unexpectedly.'
Assert-True ([IO.Path]::GetFileName($plan.zip) -eq 'PocketGigaScan-Windows-x64.zip') 'Windows ZIP name changed unexpectedly.'

$cmake = Get-Content -LiteralPath (Join-Path $repo 'Apps/Flutter/stitch_app/windows/CMakeLists.txt') -Raw
$builderText = Get-Content -LiteralPath $builderPath -Raw
Assert-True ($builderText -match "formats = @\('PNG', 'TIFF', 'JPEG', 'JPEG XL'\)") 'Windows package manifest does not list standard JPEG export.'
Assert-True ($builderText -match 'Assert-CoreExportCapabilities \$response\.capabilities') 'Windows capability probe does not validate native JPEG support.'
$runner = Get-Content -LiteralPath (Join-Path $repo 'Apps/Flutter/stitch_app/windows/runner/CMakeLists.txt') -Raw
Assert-True ($builderText -match "'VERSION_NUMBER'" -and $builderText -match '\$ortSdkVersionPath.*ortVersion') 'Builder does not verify the extracted ONNX Runtime SDK version.'
Assert-True ($builderText -match '\$vswhereOutput = @\(& \$vswhere' -and
    $builderText -match '\$installationPath = \$vswhereOutput \| Select-Object -First 1') 'vswhere output must be captured before reading its native exit code.'
$flutterWarmupIndex = $builderText.IndexOf("Invoke-Checked `$FlutterPath @('--version') `$repo", [StringComparison]::Ordinal)
$flutterMachineIndex = $builderText.IndexOf("`$flutterVersionOutput = & `$FlutterPath '--version' '--machine'", [StringComparison]::Ordinal)
Assert-True ($flutterWarmupIndex -ge 0 -and $flutterMachineIndex -gt $flutterWarmupIndex) 'Flutter must finish cold-start output before the strict machine-readable version query.'
Assert-True ($cmake -match 'set\(BINARY_NAME "PocketGigaScan"\)') 'CMake binary target is not PocketGigaScan.'
Assert-True ($cmake -match 'native/core/target/release/lumia_gigascan_core\.dll') 'CMake does not stage the vendored core build.'
Assert-True ($cmake -match 'LUMIA_ORT_SDK' -and $cmake -match 'onnxruntime\.dll') 'CMake does not install the pinned ONNX Runtime DLL beside the native core.'
Assert-True ($cmake -match '\$\{LUMIA_ORT_SDK_DIR\}/lib/onnxruntime\.dll' -and $cmake -match '\$\{LUMIA_ORT_SDK_DIR\}/lib/onnxruntime_providers_shared\.dll') 'CMake must install both runtime DLLs from the normalized official SDK lib directory.'
$ortPathNormalization = $cmake.IndexOf('file(TO_CMAKE_PATH "$ENV{LUMIA_ORT_SDK}" LUMIA_ORT_SDK_DIR)', [StringComparison]::Ordinal)
$ortPathUse = $cmake.IndexOf('set(LUMIA_ORT_DLL "${LUMIA_ORT_SDK_DIR}/lib/onnxruntime.dll")', [StringComparison]::Ordinal)
$ortInstall = $cmake.IndexOf('install(FILES "${LUMIA_ORT_DLL}" "${LUMIA_ORT_PROVIDERS_DLL}"', [StringComparison]::Ordinal)
Assert-True ($ortPathNormalization -ge 0 -and $ortPathUse -gt $ortPathNormalization -and $ortInstall -gt $ortPathUse) 'CMake must normalize the Windows ONNX Runtime SDK environment path before composing or installing DLL paths.'
Assert-True ($builderText -match 'onnxruntime_providers_shared\.dll' -and $builderText -match 'onnxRuntimeProvidersSharedDllSha256') 'Windows package does not include and inventory the ONNX Runtime shared provider DLL.'
Assert-True ($cmake -match 'native/core/target/release/scene-model-v1\.onnx') 'CMake does not install the verified bundled scene model.'
Assert-True ($builderText -match '\$sceneModelInfo\.path -Destination \(Join-Path \$nativeRelease') 'Builder does not stage the verified model before Flutter configuration.'
Assert-True ($builderText -match "'LICENSE', 'ThirdPartyNotices\.txt', 'Privacy\.md'") 'Windows package does not include the ONNX Runtime license and notices.'
Assert-True ($builderText -match 'onnxRuntimeDllSha256' -and $builderText -match 'onnxRuntimeThirdPartyNotices' -and $builderText -match 'sceneModelSha256 = \$sceneModelInfo\.sha256') 'Build manifest does not record the packaged runtime and model hashes/notices.'
Assert-True ($builderText -match '\$stagedModelSha -ne \$sceneModelInfo\.sha256') 'Builder does not verify the staged scene model against its locked SHA-256.'
Assert-True ($builderText -match '\$freshTargetDirectory = \[IO\.Path\]::GetFullPath\(\$cargoMetadata\.target_directory\)' -and
    $builderText -match 'Copy-VerifiedNativeCoreDll \$freshCoreDll \(Join-Path \$nativeRelease ''lumia_gigascan_core\.dll''\)') 'Builder does not stage Cargo''s freshly built release core DLL through the verified copy helper.'
Assert-True ($cmake -notmatch '\.local[/\\]flutter-stitch-core') 'Windows CMake still depends on a machine-local core DLL.'
Assert-True ($builderText -match "generator = 'Visual Studio 18 2026'") 'OpenCV source build is not configured for Visual Studio 18.'
Assert-True ($builderText -match '\$vsGenerator = \$vsToolchain\.generator') 'OpenCV build does not use the selected VS 18 generator.'
Assert-True ($runner -match 'native/core/target/release/lumia_gigascan_core\.dll') 'Runner debug launch does not stage the vendored core.'
$resource = Get-Content -LiteralPath (Join-Path $repo 'Apps/Flutter/stitch_app/windows/runner/Runner.rc') -Raw
Assert-True ($resource -match 'VALUE "ProductName", "PocketGigaScan"') 'Windows product metadata is not branded PocketGigaScan.'

$workflow = Get-Content -LiteralPath (Join-Path $repo '.github/workflows/windows-build.yml') -Raw
Assert-True ($workflow -match 'pull_request:' -and $workflow -match 'push:') 'Workflow must verify both pushes and pull requests.'
Assert-True ($workflow -match 'actions/upload-artifact@') 'Workflow does not publish per-run build artifacts.'
Assert-True ($workflow -match '(?s)name: Upload Flutter test failure screenshots\s+if: failure\(\).*?path: Apps/Flutter/stitch_app/test/failures/\*\.png\s+if-no-files-found: ignore\s+retention-days: 7') 'Workflow must preserve failure-only Flutter screenshot diagnostics with bounded retention.'
Assert-True ($workflow -match 'actions/cache@caa296126883cff596d87d8935842f9db880ef25') 'Workflow does not cache pinned build dependencies.'
Assert-True ($workflow -match 'runs-on: windows-2025-vs2026') 'Workflow must use the compatible VS 2026 hosted image.'
Assert-True ($workflow -match 'windows-2025-vs2026-vs18-msvc-14\.50') 'Dependency cache key must encode the compatible MSVC toolchain.'
Assert-True ($workflow -match 'opencv-1d40ca017ea51c533cf9fd5cbde5b5fe7ae248291ddf2af99d4c17cf8e13017d') 'Dependency cache key must include the OpenCV source hash.'
Assert-True ($workflow -notmatch 'native/core/target') 'Workflow must not cache generated native DLL or Cargo target output.'
Assert-True ($workflow -match "github\.event_name == 'push'") 'Prerelease publication is not limited to push events.'
Assert-True ($workflow -match "github\.repository == 'sunyych/PocketGigaScan'") 'Prerelease publication is not restricted to the canonical repository.'
Assert-True ($workflow -match 'GH_REPO: \$\{\{ github\.repository \}\}') 'GitHub CLI release commands must explicitly target the current canonical repository.'
Assert-True ($workflow -match 'github\.event\.repository\.default_branch') 'Prerelease publication is not restricted to the default branch.'
Assert-True ($workflow -notmatch 'event\.repository\.fork') 'Fork metadata must not disable releases from the canonical repository.'

$icon = [IO.File]::ReadAllBytes((Join-Path $repo 'Apps/Flutter/stitch_app/windows/runner/resources/app_icon.ico'))
Assert-True ($icon.Length -gt 64 -and $icon[0] -eq 0 -and $icon[1] -eq 0 -and $icon[2] -eq 1 -and $icon[3] -eq 0) 'Windows application icon is not a valid ICO.'
Assert-True ($icon[4] -ge 5) 'Windows icon is missing multi-resolution images.'
Assert-True (Test-Path -LiteralPath (Join-Path $repo 'branding/dwarf-stitch-icon.svg')) 'Editable SVG icon source is missing.'
Assert-True (Test-Path -LiteralPath (Join-Path $repo 'branding/generate_app_icon.py')) 'Reproducible icon generator is missing.'
foreach ($dependencyLicense in @('LICENSE.libtiff', 'LICENSE.openjpeg')) {
    $dependencyLicensePath = Join-Path $repo "third_party/licenses/$dependencyLicense"
    Assert-True (Test-Path -LiteralPath $dependencyLicensePath -PathType Leaf) "Static OpenCV dependency license is missing: $dependencyLicense"
    Assert-True ((Get-Item -LiteralPath $dependencyLicensePath).Length -gt 1000) "Static OpenCV dependency license is unexpectedly incomplete: $dependencyLicense"
}

$metadataTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('pocket-metadata-test-' + [guid]::NewGuid().ToString('N'))
$metadataTestRoot = [IO.Path]::GetFullPath($metadataTestRoot)
Assert-True ($metadataTestRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetFileName($metadataTestRoot) -match '^pocket-metadata-test-[0-9a-f]{32}$') 'Refusing unsafe metadata test fixture path.'
New-Item -ItemType Directory -Force -Path $metadataTestRoot | Out-Null
$metadataExe = Join-Path $metadataTestRoot 'PocketGigaScan.exe'
$metadataCore = Join-Path $metadataTestRoot 'lumia_gigascan_core.dll'
Set-Content -LiteralPath $metadataExe -Value 'EXE fixture' -Encoding ascii
Set-Content -LiteralPath $metadataCore -Value 'DLL fixture' -Encoding ascii
$script:VersionInfoByPath = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
$script:VersionInfoByPath[$metadataExe] = [pscustomobject]@{ ProductName = 'PocketGigaScan'; FileVersion = '1.4.4+23'; ProductVersion = '1.4.4+23' }
$script:VersionInfoByPath[$metadataCore] = [pscustomobject]@{ ProductName = 'PocketGigaScan'; FileVersion = '1.4.4+23'; ProductVersion = '1.4.4+23' }
function Get-Item {
    param([string]$LiteralPath)
    return [pscustomobject]@{ VersionInfo = $script:VersionInfoByPath[$LiteralPath] }
}
try {
    Assert-WindowsProductVersionMetadata @($metadataExe, $metadataCore) '1.4.4+23'
    $wrongMetadataRejected = $false
    $script:VersionInfoByPath[$metadataCore].ProductVersion = '1.4.3+22'
    try { Assert-WindowsProductVersionMetadata @($metadataExe, $metadataCore) '1.4.4+23' } catch { $wrongMetadataRejected = $true }
    Assert-True $wrongMetadataRejected 'Builder metadata check accepted mismatched EXE/core versions.'
    $wrongProductRejected = $false
    $script:VersionInfoByPath[$metadataCore].ProductVersion = '1.4.4+23'
    $script:VersionInfoByPath[$metadataCore].ProductName = 'Other Product'
    try { Assert-WindowsProductVersionMetadata @($metadataExe, $metadataCore) '1.4.4+23' } catch { $wrongProductRejected = $true }
    Assert-True $wrongProductRejected 'Builder metadata check accepted a non-product-owned DLL.'
}
finally {
    Remove-Item -LiteralPath Function:\Get-Item -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $metadataTestRoot) { Remove-Item -LiteralPath $metadataTestRoot -Recurse -Force }
}

$coreCopyTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('pocket-core-copy-test-' + [guid]::NewGuid().ToString('N'))
$coreCopyTestRoot = [IO.Path]::GetFullPath($coreCopyTestRoot)
Assert-True ($coreCopyTestRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetFileName($coreCopyTestRoot) -match '^pocket-core-copy-test-[0-9a-f]{32}$') 'Refusing unsafe native core copy test fixture path.'
try {
    $samePathCore = Join-Path $coreCopyTestRoot 'default-target/release/lumia_gigascan_core.dll'
    New-Item -ItemType Directory -Force -Path (Split-Path $samePathCore -Parent) | Out-Null
    [IO.File]::WriteAllText($samePathCore, 'fresh native core fixture')
    $samePathHash = (Get-FileHash -LiteralPath $samePathCore -Algorithm SHA256).Hash.ToLowerInvariant()
    $normalizedSamePath = Join-Path (Split-Path $samePathCore -Parent) '.\lumia_gigascan_core.dll'
    Copy-VerifiedNativeCoreDll $samePathCore $normalizedSamePath
    Assert-True ((Get-FileHash -LiteralPath $samePathCore -Algorithm SHA256).Hash.ToLowerInvariant() -eq $samePathHash) 'Default Cargo target same-path staging changed the freshly built DLL.'

    $externalTargetCore = Join-Path $coreCopyTestRoot 'external-target/release/lumia_gigascan_core.dll'
    Copy-VerifiedNativeCoreDll $samePathCore $externalTargetCore
    Assert-True (Test-Path -LiteralPath $externalTargetCore -PathType Leaf) 'External Cargo target DLL was not copied to the stable staging path.'
    Assert-True ((Get-FileHash -LiteralPath $externalTargetCore -Algorithm SHA256).Hash.ToLowerInvariant() -eq $samePathHash) 'External Cargo target copy does not match the freshly built DLL.'
}
finally {
    if (Test-Path -LiteralPath $coreCopyTestRoot) { Remove-Item -LiteralPath $coreCopyTestRoot -Recurse -Force }
}

Assert-True ($plan.onnxRuntimeVersion -eq '1.31.0' -and $plan.onnxRuntimeSha256 -eq '3958d8a44984160692c1b4ffd0de3cb48f8c39f9d34bb31e433db06e30b82195') 'ONNX Runtime SDK pin or checksum changed unexpectedly.'
Assert-True ($plan.sceneModelId -eq 'openmmlab/upernet-convnext-tiny@876ffc56b819a829448f7e81e9f8606deef6fb65') 'Scene model revision changed unexpectedly.'
Assert-True ($plan.sceneModelAssetUrl -match 'github\.com/sunyych/PocketGigaScan/releases/download/scene-model-v1/') 'Build plan does not expose the pinned public scene model release asset.'
Assert-True ($plan.sceneModelAssetSha256 -match '^[0-9a-f]{64}$' -and $plan.sceneModelPath -match 'dependencies[\\/]scene-model-v1[\\/]scene-model-v1\.onnx$') 'Build plan does not point to the cached frozen model asset and its archive SHA.'
$sceneModelLock = Get-Content -LiteralPath (Join-Path $repo 'scripts/scene-model-export.lock.json') -Raw | ConvertFrom-Json
Assert-True ($plan.sceneModelAssetUrl -eq $sceneModelLock.releaseAsset.url -and $plan.sceneModelAssetSha256 -eq $sceneModelLock.releaseAsset.sha256) 'Builder model asset pin differs from the shared export lock.'
Assert-True ($builderText -match '\$sceneModelAsset\.sizeBytes' -and $builderText -match 'Save-VerifiedArchive \$sceneModelAsset\.url \$sceneModelArchive \$sceneModelAsset\.sha256') 'Builder does not verify the frozen ZIP size and SHA before extraction.'
Assert-True ($builderText -match "'scene-model-README\.md'" -and $builderText -match "'scene-model-NOTICE\.txt'") 'Builder does not require and package the model asset notices.'
Assert-True ($builderText -notmatch 'export-scene-model\.py|scene-export-venv|huggingface-cache|Python is required to produce the bundled pinned scene model') 'A clean Windows package build must not export or download model weights through Python.'
Assert-True ($builderText -match "'VERSION_NUMBER'" -and $builderText -match '\$ortSdkVersionPath.*ortVersion') 'Builder does not verify the extracted ONNX Runtime SDK version.'
Assert-True ($cmake -match 'LUMIA_ORT_SDK' -and $cmake -match 'onnxruntime\.dll') 'CMake does not install the pinned ONNX Runtime DLL beside the native core.'
Assert-True ($cmake -match '\$\{LUMIA_ORT_SDK_DIR\}/lib/onnxruntime\.dll' -and $cmake -match '\$\{LUMIA_ORT_SDK_DIR\}/lib/onnxruntime_providers_shared\.dll') 'CMake must install both runtime DLLs from the normalized official SDK lib directory.'
$ortPathNormalization = $cmake.IndexOf('file(TO_CMAKE_PATH "$ENV{LUMIA_ORT_SDK}" LUMIA_ORT_SDK_DIR)', [StringComparison]::Ordinal)
$ortPathUse = $cmake.IndexOf('set(LUMIA_ORT_DLL "${LUMIA_ORT_SDK_DIR}/lib/onnxruntime.dll")', [StringComparison]::Ordinal)
$ortInstall = $cmake.IndexOf('install(FILES "${LUMIA_ORT_DLL}" "${LUMIA_ORT_PROVIDERS_DLL}"', [StringComparison]::Ordinal)
Assert-True ($ortPathNormalization -ge 0 -and $ortPathUse -gt $ortPathNormalization -and $ortInstall -gt $ortPathUse) 'CMake must normalize the Windows ONNX Runtime SDK environment path before composing or installing DLL paths.'
Assert-True ($builderText -match 'onnxruntime_providers_shared\.dll' -and $builderText -match 'onnxRuntimeProvidersSharedDllSha256') 'Windows package does not include and inventory the ONNX Runtime shared provider DLL.'
Assert-True ($builderText -match '\$sceneModelInfo\.path -Destination \(Join-Path \$nativeRelease') 'Builder does not stage the verified model before Flutter configuration.'
Assert-True ($builderText -match "'LICENSE', 'ThirdPartyNotices\.txt', 'Privacy\.md'") 'Windows package does not include the ONNX Runtime license and notices.'
Assert-True ($builderText -match 'onnxRuntimeDllSha256' -and $builderText -match 'onnxRuntimeThirdPartyNotices' -and $builderText -match 'sceneModelSha256 = \$sceneModelInfo\.sha256') 'Build manifest does not record the packaged runtime and model hashes/notices.'
Assert-True ($builderText -match '\$stagedModelSha -ne \$sceneModelInfo\.sha256') 'Builder does not verify the staged scene model against its locked SHA-256.'

$sceneModelTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('pocket-scene-model-asset-test-' + [guid]::NewGuid().ToString('N'))
$sceneModelTestRoot = [IO.Path]::GetFullPath($sceneModelTestRoot)
Assert-True ($sceneModelTestRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetFileName($sceneModelTestRoot) -match '^pocket-scene-model-asset-test-[0-9a-f]{32}$') 'Refusing unsafe scene model asset test fixture path.'
try {
    $cache = Join-Path $sceneModelTestRoot 'dependencies'
    $assetSource = Join-Path $sceneModelTestRoot 'asset-source'
    $sceneModelAssetRoot = Join-Path $cache 'scene-model-v1'
    New-Item -ItemType Directory -Force -Path $cache, $assetSource | Out-Null
    $modelFixture = Join-Path $assetSource 'scene-model-v1.onnx'
    [IO.File]::WriteAllBytes($modelFixture, [Text.Encoding]::ASCII.GetBytes('canonical ONNX fixture'))
    $modelFixtureSha = (Get-FileHash -LiteralPath $modelFixture -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifestFixture = [ordered]@{
        schemaVersion = 1
        modelId = 'fixture/model@revision'
        onnxFile = 'scene-model-v1.onnx'
        sizeBytes = (Get-Item -LiteralPath $modelFixture).Length
        sha256 = $modelFixtureSha
    }
    $manifestFixture | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $assetSource 'scene-model-v1.manifest.json') -Encoding utf8
    Set-Content -LiteralPath (Join-Path $assetSource 'scene-model-README.md') -Value 'Model card fixture' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $assetSource 'scene-model-NOTICE.txt') -Value 'License notice fixture' -Encoding utf8
    $sceneModelArchive = Join-Path $cache 'scene-model-fixture.zip'
    Compress-Archive -Path (Join-Path $assetSource '*') -DestinationPath $sceneModelArchive
    $sceneModelAsset = [pscustomobject]@{
        url = 'https://example.invalid/fixture.zip'
        sha256 = (Get-FileHash -LiteralPath $sceneModelArchive -Algorithm SHA256).Hash.ToLowerInvariant()
        sizeBytes = (Get-Item -LiteralPath $sceneModelArchive).Length
        fileName = [IO.Path]::GetFileName($sceneModelArchive)
    }
    $pin = [pscustomobject]@{ sceneModelId = 'fixture/model@revision' }
    $sceneModelLock = [pscustomobject]@{
        expectedSizeBytes = (Get-Item -LiteralPath $modelFixture).Length
        expectedSha256 = $modelFixtureSha
    }

    $resolvedSceneModel = Resolve-SceneModelPath ''
    Assert-True (Test-Path -LiteralPath $resolvedSceneModel -PathType Leaf) 'Frozen model asset was not extracted from the verified archive.'
    $verifiedSceneModel = Assert-SceneModel $resolvedSceneModel
    Assert-True ($verifiedSceneModel.sha256 -eq $modelFixtureSha -and $verifiedSceneModel.readmePath -and $verifiedSceneModel.noticePath) 'Extracted model metadata or bundled notices were not verified.'

    $overridePath = Join-Path $sceneModelTestRoot 'caller-model.onnx'
    Assert-True ((Resolve-SceneModelPath $overridePath) -eq [IO.Path]::GetFullPath($overridePath)) 'Caller-provided SceneModel override was not preserved.'

    [IO.File]::AppendAllText($sceneModelArchive, 'tampered')
    $tamperedArchiveRejected = $false
    try { Resolve-SceneModelPath '' | Out-Null } catch { $tamperedArchiveRejected = $true }
    Assert-True $tamperedArchiveRejected 'Scene model archive SHA mismatch was not rejected before reuse.'

    [IO.File]::AppendAllText($resolvedSceneModel, 'tampered')
    $tamperedModelRejected = $false
    try { Assert-SceneModel $resolvedSceneModel } catch { $tamperedModelRejected = $true }
    Assert-True $tamperedModelRejected 'Model metadata accepted an ONNX file whose actual SHA-256 changed.'
}
finally {
    if (Test-Path -LiteralPath $sceneModelTestRoot) { Remove-Item -LiteralPath $sceneModelTestRoot -Recurse -Force }
}
Write-Host 'Windows builder plan, signing metadata, vendored core paths, release safety, and app icon tests passed.'
