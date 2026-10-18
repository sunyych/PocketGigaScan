[CmdletBinding()]
param(
    [string[]]$Abis = @('arm64-v8a'),
    [string]$AndroidSdkRoot = $(if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { 'D:\Android\Sdk' }),
    [int]$ApiLevel = 29,
    [switch]$JxlOnly,
    [switch]$BuildTests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$native = Join-Path $repo 'native\core'
$cache = Join-Path $repo '.local\android-core'
$sourceCache = Join-Path $cache 'source-archives'
$output = Join-Path $repo '.local\flutter-stitch-core\jniLibs'
$ndkVersion = '28.2.13676358'
$ndk = Join-Path $AndroidSdkRoot "ndk\$ndkVersion"
$ndkBin = Join-Path $ndk 'toolchains\llvm\prebuilt\windows-x86_64\bin'
$toolchain = Join-Path $ndk 'build\cmake\android.toolchain.cmake'
$opencvZip = Join-Path $cache 'opencv-4.13.0-android-sdk.zip'
$opencvRoot = Join-Path $cache 'opencv-sdk\OpenCV-android-sdk\sdk\native'
$opencvSha256 = 'edfda20fdf65d0bd45391d168ec5261dd30b600b00279c4d910d7f1c3e020f0f'

$pins = @(
    @{ Name='libjxl'; Revision='v0.12.0'; Archive='libjxl-v0.12.0.tar.gz'; Url='https://github.com/libjxl/libjxl/archive/v0.12.0.tar.gz'; Sha256='03e9be69a30be4011f559da75328b6d7cea8ad921fabfbd551ce10bf45cdc992'; Folder='libjxl-0.12.0' },
    @{ Name='brotli'; Revision='028fb5a23661f123017c060daa546b55cf4bde29'; Archive='brotli-028fb5a23661f123017c060daa546b55cf4bde29.tar.gz'; Url='https://github.com/google/brotli/archive/028fb5a23661f123017c060daa546b55cf4bde29.tar.gz'; Sha256='0afe09a53c8bad9861c8dd1fc1284308d54f19d2979ba3541cfdcc9b05fe360f'; Folder='brotli-028fb5a23661f123017c060daa546b55cf4bde29' },
    @{ Name='highway'; Revision='457c891775a7397bdb0376bb1031e6e027af1c48'; Archive='highway-457c891775a7397bdb0376bb1031e6e027af1c48.tar.gz'; Url='https://github.com/google/highway/archive/457c891775a7397bdb0376bb1031e6e027af1c48.tar.gz'; Sha256='5124b0501c98d9930dbb065bfa1a5bbbd59ce0f12facb7e1e33aaef01a5f1f1a'; Folder='highway-457c891775a7397bdb0376bb1031e6e027af1c48' },
    @{ Name='skcms'; Revision='96d9171c94b937a1b5f0293de7309ac16311b722'; Archive='skcms-96d9171c94b937a1b5f0293de7309ac16311b722.tar.gz'; Url='https://github.com/google/skcms/archive/96d9171c94b937a1b5f0293de7309ac16311b722.tar.gz'; Sha256='9bb4b5bba0b7c04f6c2bce9ff713d61e23c9a20c4945161ae16290498ad74627'; Folder='skcms-96d9171c94b937a1b5f0293de7309ac16311b722' }
)
$targets = @{
    'arm64-v8a' = @{ Triple='aarch64-linux-android'; OpenCvDir='arm64-v8a'; Extra=@('tegra_hal','kleidicv_hal','kleidicv','kleidicv_thread'); Machine='AArch64' }
    'x86_64' = @{ Triple='x86_64-linux-android'; OpenCvDir='x86_64'; Extra=@('ipphal','ippicv','ippiw'); Machine='Advanced Micro Devices X86-64' }
}

function Require-Path([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Label not found: $Path" }
}
function Assert-OwnedPath([string]$Path, [string]$OwnerRoot) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    $owner = [IO.Path]::GetFullPath($OwnerRoot).TrimEnd('\')
    $ownerPrefix = $owner + '\'
    if (-not $fullPath.StartsWith($ownerPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing path outside owned cache root '$owner': $fullPath"
    }
    $current = $fullPath
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing reparse point in owned path: $current"
            }
        }
        if ($current -eq $owner) { break }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { throw "Could not verify owned path ancestry: $fullPath" }
        $current = $parent.FullName
    }
    if ($current -ne $owner) { throw "Path escaped its owned cache root: $fullPath" }
    return $fullPath
}
function Assert-Hash([string]$Path, [string]$Expected) {
    Require-Path $Path 'Pinned input archive'
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected) { throw "SHA-256 mismatch for $Path`: $actual" }
}
function Get-TreeSha256([string]$Root, [string[]]$ExcludeDirectories = @()) {
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $prefix = $rootPath + '\'
    $relativePaths = @(
        Get-ChildItem -LiteralPath $rootPath -File -Recurse | Where-Object {
            $relative = $_.FullName.Substring($prefix.Length).Replace('\', '/')
            $excluded = $false
            foreach ($directory in $ExcludeDirectories) {
                if ($relative.StartsWith("$directory/", [StringComparison]::Ordinal)) { $excluded = $true; break }
            }
            -not $excluded
        } | ForEach-Object { $_.FullName.Substring($prefix.Length).Replace('\', '/') }
    )
    [Array]::Sort($relativePaths, [StringComparer]::Ordinal)
    $rows = foreach ($relative in $relativePaths) {
        $path = Join-Path $rootPath $relative.Replace('/', '\')
        "$relative|$((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant())"
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($rows -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')).ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Expand-Pinned([hashtable]$Pin, [string]$Destination) {
    $archive = Join-Path $sourceCache $Pin.Archive
    Assert-Hash $archive $Pin.Sha256
    $destination = [IO.Path]::GetFullPath($Destination)
    $destination = Assert-OwnedPath $destination $cache
    $expectedRoot = Join-Path $destination $Pin.Folder
    if (-not (Test-Path -LiteralPath $expectedRoot)) {
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        & tar.exe -xzf $archive -C $destination
        if ($LASTEXITCODE -ne 0) { throw "Could not extract pinned $($Pin.Name) source" }
    }
    Require-Path $expectedRoot "$($Pin.Name) source"
    $verifyRoot = Join-Path ([IO.Path]::GetTempPath()) "pocket-android-source-$($Pin.Name)-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $verifyRoot | Out-Null
    try {
        & tar.exe -xzf $archive -C $verifyRoot
        if ($LASTEXITCODE -ne 0) { throw "Could not verify extracted $($Pin.Name) source" }
        $expected = Join-Path $verifyRoot $Pin.Folder
        $excluded = if ($Pin.Name -eq 'libjxl') { @('third_party/brotli','third_party/highway','third_party/skcms') } else { @() }
        $expectedHash = Get-TreeSha256 $expected $excluded
        $actualHash = Get-TreeSha256 $expectedRoot $excluded
        if ($actualHash -ne $expectedHash) {
            throw "Extracted $($Pin.Name) tree does not match its verified source archive (expected $expectedHash, found $actualHash)"
        }
    } finally {
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $fullVerify = [IO.Path]::GetFullPath($verifyRoot)
        if (-not $fullVerify.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove source verification path outside system temp: $fullVerify"
        }
        Remove-Item -LiteralPath $fullVerify -Recurse -Force
    }
    return $expectedRoot
}
function Get-PinnedArchive([hashtable]$Pin) {
    $archive = Join-Path $sourceCache $Pin.Archive
    if (-not (Test-Path -LiteralPath $archive)) {
        New-Item -ItemType Directory -Force -Path $sourceCache | Out-Null
        $provided = Join-Path (Join-Path $repo '.local\android-stitch-validation-20261005\sources') $Pin.Archive
        if (Test-Path -LiteralPath $provided) {
            Assert-Hash $provided $Pin.Sha256
            Copy-Item -LiteralPath $provided -Destination $archive
        } else {
            $partial = "$archive.partial"
            try {
                Invoke-WebRequest -Uri $Pin.Url -OutFile $partial
                Assert-Hash $partial $Pin.Sha256
                Move-Item -LiteralPath $partial -Destination $archive
            } finally {
                if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
            }
        }
    }
    Assert-Hash $archive $Pin.Sha256
    return $archive
}
function Invoke-Checked([string]$Exe, [string[]]$Arguments, [string]$Label) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Label failed with exit code $LASTEXITCODE" }
}
function Assert-AndroidElfText([string]$Abi, [string]$HeaderText, [string]$ProgramHeaders) {
    $expectedMachine = switch ($Abi) {
        'arm64-v8a' { 'AArch64' }
        'x86_64' { 'Advanced Micro Devices X86-64' }
        default { throw "Unsupported Android ABI in ELF check: $Abi" }
    }
    if ($HeaderText -notmatch "(?m)^\s*Machine:\s*$([regex]::Escape($expectedMachine))\s*$") {
        throw "ELF machine does not match $Abi"
    }
    $loadRows = @($ProgramHeaders -split "`r?`n" | Where-Object { $_ -match '^\s*LOAD\s+' })
    if ($loadRows.Count -eq 0) { throw "ELF contains no LOAD segments for $Abi" }
    foreach ($line in $loadRows) {
        $columns = @($line.Trim() -split '\s+')
        if ($columns.Count -lt 8) { throw "Malformed ELF LOAD segment for $Abi`: $line" }
        $offset = [Convert]::ToInt64($columns[1].Substring(2), 16)
        $virtualAddress = [Convert]::ToInt64($columns[2].Substring(2), 16)
        $alignment = [Convert]::ToInt64($columns[-1].Substring(2), 16)
        if ($alignment -lt 0x4000) { throw "ELF LOAD segment is not 16 KiB aligned for $Abi" }
        if (($offset % $alignment) -ne ($virtualAddress % $alignment)) {
            throw "ELF LOAD offset and virtual address are incongruent for $Abi"
        }
    }
    if ($ProgramHeaders -notmatch '(?m)^\s*GNU_RELRO\s+') { throw "ELF has no GNU_RELRO segment for $Abi" }
    return [ordered]@{ machine=$expectedMachine; loadSegments=$loadRows.Count; minimumLoadAlignmentBytes=16384; hasGnuRelro=$true }
}
function Get-CoreSourceSha256 {
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $native -File -Recurse | Where-Object {
            $_.FullName -notmatch '[\\/]target[\\/]' -and $_.FullName -notmatch '[\\/]\.git[\\/]'
        } | Sort-Object FullName) {
            $nativePrefix = $native.TrimEnd('\') + '\'
            $relative = $file.FullName.Substring($nativePrefix.Length).Replace('\', '/')
            $pathBytes = [Text.Encoding]::UTF8.GetBytes($relative + "`0")
            $hasher.AppendData($pathBytes)
            $stream = [IO.File]::OpenRead($file.FullName)
            try {
                $buffer = New-Object byte[] 65536
                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $hasher.AppendData($buffer, 0, $read)
                }
            } finally { $stream.Dispose() }
        }
        return ([BitConverter]::ToString($hasher.GetHashAndReset()).Replace('-', '')).ToLowerInvariant()
    } finally { $hasher.Dispose() }
}
function Copy-AndroidLicenseFile([string]$Source, [string]$Destination, [string]$Name, [System.Collections.ArrayList]$Inventory) {
    Require-Path $Source "License text for $Name"
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    [void]$Inventory.Add([ordered]@{
        name=$Name
        path=$Destination.Substring($script:androidLicenseStageRoot.Length).TrimStart('\').Replace('\','/')
        sha256=(Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    })
}
function Publish-AndroidLicenseStage(
    [string]$StageRoot,
    [string]$AssetsOwner,
    [string]$LicenseRoot,
    [string]$FlutterCoreRoot,
    [string]$PrivateStagingRoot,
    [string]$BackupRoot,
    [string]$CacheRoot
) {
    $assetsOwner = Assert-OwnedPath $AssetsOwner $FlutterCoreRoot
    $licenseRoot = Assert-OwnedPath $LicenseRoot $assetsOwner
    $privateStagingRoot = Assert-OwnedPath $PrivateStagingRoot $CacheRoot
    $backupRoot = Assert-OwnedPath $BackupRoot $CacheRoot
    $stageRoot = Assert-OwnedPath $StageRoot $privateStagingRoot
    New-Item -ItemType Directory -Force -Path $assetsOwner, $backupRoot | Out-Null
    $backup = Assert-OwnedPath (Join-Path $backupRoot "native-licenses-$([guid]::NewGuid().ToString('N'))") $backupRoot
    if (Test-Path -LiteralPath $licenseRoot) { Move-Item -LiteralPath $licenseRoot -Destination $backup }
    try {
        Move-Item -LiteralPath $stageRoot -Destination $licenseRoot
    } catch {
        if ((Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $licenseRoot)) {
            Move-Item -LiteralPath $backup -Destination $licenseRoot
        }
        throw
    }
}
function Stage-AndroidLicenses {
    $assetsOwner = Join-Path $repo '.local\flutter-stitch-core\android-assets'
    $licenseRoot = Join-Path $assetsOwner 'native-licenses'
    $privateStagingRoot = Assert-OwnedPath (Join-Path $cache 'staging\publish') $cache
    $backupRoot = Assert-OwnedPath (Join-Path $cache 'staging\backups') $cache
    New-Item -ItemType Directory -Force -Path $privateStagingRoot, $backupRoot | Out-Null
    $androidLicenseStageRoot = Assert-OwnedPath (Join-Path $privateStagingRoot "native-licenses-$([guid]::NewGuid().ToString('N'))") $privateStagingRoot
    $script:androidLicenseStageRoot = $androidLicenseStageRoot
    New-Item -ItemType Directory -Force -Path $androidLicenseStageRoot | Out-Null
    $inventory = New-Object System.Collections.ArrayList
    $project = Join-Path $androidLicenseStageRoot 'project'
    Copy-AndroidLicenseFile (Join-Path $repo 'LICENSE') (Join-Path $project 'LICENSE') 'PocketGigaScan' $inventory
    Copy-AndroidLicenseFile (Join-Path $repo 'NOTICE') (Join-Path $project 'NOTICE') 'PocketGigaScan historical notice' $inventory
    Copy-AndroidLicenseFile (Join-Path $native 'LICENSE') (Join-Path $project 'native-core\LICENSE') 'Vendored native core' $inventory

    $opencvDistributionRoot = Join-Path $cache 'opencv-sdk\OpenCV-android-sdk'
    $opencvDestination = Join-Path $androidLicenseStageRoot 'opencv'
    Copy-AndroidLicenseFile (Join-Path $opencvDistributionRoot 'LICENSE') (Join-Path $opencvDestination 'LICENSE') 'OpenCV 4.13.0' $inventory
    $opencvLicenses = Join-Path $opencvDistributionRoot 'sdk\etc\licenses'
    Require-Path $opencvLicenses 'OpenCV SDK third-party licenses'
    $opencvLicenseFiles = @(Get-ChildItem -LiteralPath $opencvLicenses -File -Recurse | Sort-Object FullName)
    if ($opencvLicenseFiles.Count -eq 0) { throw 'OpenCV SDK contains no third-party license texts.' }
    foreach ($file in $opencvLicenseFiles) {
        $relative = $file.FullName.Substring($opencvLicenses.Length).TrimStart('\','/')
        Copy-AndroidLicenseFile $file.FullName (Join-Path (Join-Path $opencvDestination 'sdk\etc\licenses') $relative) "OpenCV SDK: $relative" $inventory
    }
    $licenseSources = @(
        @{Name='libjxl 0.12.0'; Root=$jxlSourceRoot},
        @{Name='Brotli'; Root=$deps['brotli']},
        @{Name='Highway'; Root=$deps['highway']},
        @{Name='skcms'; Root=$deps['skcms']}
    )
    foreach ($source in $licenseSources) {
        $destination = Join-Path (Join-Path $androidLicenseStageRoot 'upstream') ($source.Name -replace '[^A-Za-z0-9._-]','-')
        $licenseFiles = @(Get-ChildItem -LiteralPath $source.Root -File -Force | Where-Object { $_.Name -match '^(?i:LICENSE|COPYING|NOTICE)([-_.].*)?$' } | Sort-Object Name)
        if ($licenseFiles.Count -eq 0) { throw "Pinned source has no license text: $($source.Name)" }
        foreach ($file in $licenseFiles) {
            Copy-AndroidLicenseFile $file.FullName (Join-Path $destination $file.Name) $source.Name $inventory
        }
    }

    $metadataLines = & cargo.exe metadata --format-version 1 --manifest-path (Join-Path $native 'Cargo.toml') --locked
    if ($LASTEXITCODE -ne 0) { throw 'Cargo metadata failed while collecting native dependency licenses.' }
    $metadata = ($metadataLines -join "`n") | ConvertFrom-Json
    if (-not $metadata.packages) { throw 'Cargo metadata contained no packages.' }
    foreach ($package in @($metadata.packages | Where-Object { $_.source -like 'registry+*' } | Sort-Object name, version, source)) {
        $manifestPath = [IO.Path]::GetFullPath([string]$package.manifest_path)
        $packageRoot = Split-Path -Parent $manifestPath
        Require-Path $manifestPath "Cargo registry manifest $($package.name)-$($package.version)"
        $licenseFiles = @(Get-ChildItem -LiteralPath $packageRoot -File -Force | Where-Object { $_.Name -match '^(?i:LICENSE|COPYING|NOTICE)([-_.].*)?$' } | Sort-Object Name)
        if ($licenseFiles.Count -eq 0 -and $package.license_file) {
            $declared = [IO.Path]::GetFullPath((Join-Path $packageRoot ([string]$package.license_file)))
            $packagePrefix = $packageRoot.TrimEnd('\','/') + '\'
            if (-not $declared.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Cargo license_file escapes package root: $($package.name)" }
            if (Test-Path -LiteralPath $declared -PathType Leaf) { $licenseFiles = @(Get-Item -LiteralPath $declared) }
        }
        if ($licenseFiles.Count -eq 0) { throw "Cargo registry dependency has no packaged license: $($package.name)-$($package.version)" }
        $destination = Join-Path (Join-Path $androidLicenseStageRoot 'cargo') "$($package.name)-$($package.version)"
        foreach ($file in $licenseFiles) {
            Copy-AndroidLicenseFile $file.FullName (Join-Path $destination $file.Name) "Cargo $($package.name)-$($package.version)" $inventory
        }
    }

    $noticeLines = @(
        '# Native dependency notices',
        '',
        'This package contains the project, Rust, OpenCV, libjxl, Brotli, Highway and skcms license texts copied from the exact build inputs.',
        'See manifest.json for source revisions, archive hashes, file hashes and Cargo registry package identities.',
        ''
    )
    $noticePath = Join-Path $androidLicenseStageRoot 'THIRD_PARTY_NOTICES.md'
    [IO.File]::WriteAllText($noticePath, ($noticeLines -join "`n"), (New-Object System.Text.UTF8Encoding -ArgumentList $false))
    $files = @()
    foreach ($file in Get-ChildItem -LiteralPath $androidLicenseStageRoot -File -Recurse | Where-Object { $_.Name -ne 'manifest.json' } | Sort-Object FullName) {
        $relative = $file.FullName.Substring($androidLicenseStageRoot.Length).TrimStart('\').Replace('\','/')
        $files += [ordered]@{path=$relative; sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    if ($files.Count -lt 8) { throw 'Native license inventory is incomplete.' }
    $provenanceSources = @(
        [ordered]@{name='OpenCV'; version='4.13.0'; sha256=$opencvSha256},
        [ordered]@{name='libjxl'; revision=$pins[0].Revision; sha256=$pins[0].Sha256}
    )
    foreach ($pin in $pins | Select-Object -Skip 1) {
        $provenanceSources += [ordered]@{name=$pin.Name; revision=$pin.Revision; sha256=$pin.Sha256}
    }
    $sourceManifest = [ordered]@{
        schemaVersion=1; complete=$true; product='PocketGigaScan native Android core'
        sources=$provenanceSources
        licenseFiles=$inventory.ToArray(); files=$files
    }
    $manifestPath = Join-Path $androidLicenseStageRoot 'manifest.json'
    [IO.File]::WriteAllText($manifestPath, ($sourceManifest | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding -ArgumentList $false))
    Publish-AndroidLicenseStage `
        $androidLicenseStageRoot `
        $assetsOwner `
        $licenseRoot `
        (Join-Path $repo '.local\flutter-stitch-core') `
        $privateStagingRoot `
        $backupRoot `
        $cache
}

if ($ApiLevel -ne 29) { throw 'This builder pins Android API 29.' }
if ($Abis.Count -eq 0 -or @($Abis | Where-Object { -not $targets.ContainsKey($_) }).Count -gt 0) {
    throw "Supported ABIs are arm64-v8a and x86_64: $($Abis -join ', ')"
}
$output = Assert-OwnedPath $output (Join-Path $repo '.local\flutter-stitch-core')
Require-Path $native 'Vendored native/core'
Require-Path (Join-Path $ndk 'source.properties') "Android NDK $ndkVersion"
Require-Path $toolchain 'NDK CMake toolchain'
Require-Path (Join-Path $ndkBin 'llvm-readelf.exe') 'NDK llvm-readelf'
Require-Path (Join-Path $ndkBin 'llvm-ar.exe') 'NDK llvm-ar'
foreach ($pin in $pins) { [void](Get-PinnedArchive $pin) }

if (-not (Test-Path -LiteralPath $opencvZip)) {
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    $partialOpenCv = "$opencvZip.partial"
    try {
        Invoke-WebRequest -Uri 'https://github.com/opencv/opencv/releases/download/4.13.0/opencv-4.13.0-android-sdk.zip' -OutFile $partialOpenCv
        Assert-Hash $partialOpenCv $opencvSha256
        Move-Item -LiteralPath $partialOpenCv -Destination $opencvZip
    } finally {
        if (Test-Path -LiteralPath $partialOpenCv) { Remove-Item -LiteralPath $partialOpenCv -Force }
    }
}
Assert-Hash $opencvZip $opencvSha256
if (-not (Test-Path -LiteralPath (Join-Path $opencvRoot 'jni\include'))) {
    $opencvExtract = Join-Path $cache 'opencv-sdk'
    New-Item -ItemType Directory -Force -Path $opencvExtract | Out-Null
    Expand-Archive -LiteralPath $opencvZip -DestinationPath $opencvExtract -Force
}

$jxlSourceRoot = Expand-Pinned $pins[0] (Join-Path $cache 'sources')
$deps = @{}
foreach ($pin in $pins | Select-Object -Skip 1) { $deps[$pin.Name] = Expand-Pinned $pin (Join-Path $cache 'sources') }
Stage-AndroidLicenses
foreach ($abi in $Abis) {
    $target = $targets[$abi]
    $jxlPrefix = Join-Path $cache "libjxl-install\$abi"
    $jxlBuild = Join-Path $cache "libjxl-build\$abi"
    $thirdParty = Join-Path $jxlSourceRoot 'third_party'
    $dependencyMarkers = @{
        brotli = 'c\include\brotli\decode.h'
        highway = 'CMakeLists.txt'
        skcms = 'skcms.h'
    }
    foreach ($name in @('brotli','highway','skcms')) {
        $destination = Join-Path $thirdParty $name
        $marker = Join-Path $destination $dependencyMarkers[$name]
        if (-not (Test-Path -LiteralPath $marker)) {
            New-Item -ItemType Directory -Force -Path $destination | Out-Null
            Copy-Item -Path (Join-Path $deps[$name] '*') -Destination $destination -Recurse -Force
            Require-Path $marker "libjxl dependency source marker ($name)"
        }
    }
    New-Item -ItemType Directory -Force -Path $jxlBuild, $jxlPrefix | Out-Null
    $cmakeArgs = @(
        '-S', $jxlSourceRoot, '-B', $jxlBuild, '-G', 'Ninja',
        "-DCMAKE_TOOLCHAIN_FILE=$toolchain", "-DANDROID_ABI=$abi", "-DANDROID_PLATFORM=android-$ApiLevel",
        '-DANDROID_STL=c++_shared', '-DCMAKE_POSITION_INDEPENDENT_CODE=ON', '-DBUILD_SHARED_LIBS=OFF',
        '-DBUILD_TESTING=OFF', '-DJPEGXL_ENABLE_TOOLS=OFF', '-DJPEGXL_ENABLE_JNI=OFF', '-DJPEGXL_ENABLE_SJPEG=OFF',
        '-DJPEGXL_ENABLE_OPENEXR=OFF', '-DJPEGXL_ENABLE_DOXYGEN=OFF', '-DJPEGXL_ENABLE_MANPAGES=OFF',
        '-DJPEGXL_ENABLE_BENCHMARK=OFF', '-DJPEGXL_ENABLE_EXAMPLES=OFF', '-DJPEGXL_ENABLE_FUZZERS=OFF',
        '-DJPEGXL_ENABLE_DEVTOOLS=OFF', '-DJPEGXL_ENABLE_TCMALLOC=OFF', '-DJPEGXL_ENABLE_SKCMS=ON',
        '-DJPEGXL_VERSION=0.12.0',
        '-DCMAKE_POLICY_VERSION_MINIMUM=3.5', '-DCMAKE_BUILD_TYPE=Release', "-DCMAKE_INSTALL_PREFIX=$jxlPrefix",
        '-DCMAKE_INSTALL_LIBDIR=lib'
    )
    Invoke-Checked 'cmake.exe' $cmakeArgs "libjxl Android CMake configure ($abi)"
    Invoke-Checked 'cmake.exe' @('--build', $jxlBuild, '--target', 'install', '--parallel', "$([Math]::Max(2, [Math]::Min(8, [Environment]::ProcessorCount)))") "libjxl Android build ($abi)"
    foreach ($name in @('jxl','jxl_cms','hwy','brotlienc','brotlidec','brotlicommon')) {
        Require-Path (Join-Path $jxlPrefix "lib\lib$name.a") "libjxl static library $name ($abi)"
    }
    if ($JxlOnly) { continue }

    Require-Path $opencvZip 'Verified OpenCV Android SDK archive'
    Assert-Hash $opencvZip $opencvSha256
    Require-Path (Join-Path $opencvRoot 'jni\include') 'OpenCV Android headers'
    $opencvStatic = Join-Path $opencvRoot "staticlibs\$($target.OpenCvDir)"
    $opencvThirdParty = Join-Path $opencvRoot "3rdparty\libs\$($target.OpenCvDir)"
    Require-Path $opencvStatic "OpenCV static libraries ($abi)"
    Require-Path $opencvThirdParty "OpenCV dependency libraries ($abi)"
    $moduleLibs = @('opencv_stitching','opencv_calib3d','opencv_features2d','opencv_flann','opencv_imgcodecs','opencv_imgproc','opencv_photo','opencv_core')
    $commonLibs = @('ade','tbb','ittnotify','libjpeg-turbo','libwebp','libpng','libtiff','libopenjp2','IlmImf','cpufeatures','libprotobuf','z','dl','log','m') + $target.Extra
    $triple = $target.Triple
    $toolPrefix = "$triple$ApiLevel"
    $targetEnv = $triple.Replace('-', '_')
    $clang = Join-Path $ndkBin "$toolPrefix-clang.cmd"
    $clangxx = Join-Path $ndkBin "$toolPrefix-clang++.cmd"
    Set-Item "env:CC_$targetEnv" $clang
    Set-Item "env:CXX_$targetEnv" $clangxx
    Set-Item "env:AR_$targetEnv" (Join-Path $ndkBin 'llvm-ar.exe')
    Set-Item "env:CARGO_TARGET_$($targetEnv.ToUpperInvariant())_LINKER" $clang
    $env:OPENCV_DIR = $opencvRoot
    $env:OPENCV_INCLUDE_PATHS = Join-Path $opencvRoot 'jni\include'
    $env:OPENCV_LINK_PATHS = "$opencvStatic;$opencvThirdParty"
    $env:OPENCV_LINK_LIBS = ($moduleLibs + $commonLibs) -join ';'
    $env:LUMIA_JXL_SDK = $jxlPrefix
    $env:LUMIA_JXL_LINK_PATHS = Join-Path $jxlPrefix 'lib'
    Push-Location $native
    try {
        Invoke-Checked 'cargo.exe' @('rustc','--locked','--release','--lib','--target',$triple,'--','-C','link-arg=-Wl,--no-undefined','-C','link-arg=-Wl,-z,max-page-size=16384','-C','link-arg=-Wl,-z,common-page-size=16384','-C','link-arg=-lc++_shared') "native/core Android link ($abi)"
    } finally { Pop-Location }

    $built = Join-Path $native "target\$triple\release\liblumia_gigascan_core.so"
    Require-Path $built "Android native core ($abi)"
    $abiOut = Join-Path $output $abi
    $abiOut = Assert-OwnedPath $abiOut $output
    $libcxx = Join-Path $ndk "toolchains\llvm\prebuilt\windows-x86_64\sysroot\usr\lib\$triple\libc++_shared.so"
    Require-Path $libcxx "Android libc++_shared ($abi)"
    New-Item -ItemType Directory -Force -Path $output | Out-Null
    $privateStagingRoot = Assert-OwnedPath (Join-Path $cache 'staging\publish') $cache
    $backupRoot = Assert-OwnedPath (Join-Path $cache 'staging\backups') $cache
    New-Item -ItemType Directory -Force -Path $privateStagingRoot, $backupRoot | Out-Null
    $stage = Assert-OwnedPath (Join-Path $privateStagingRoot "abi-$abi-$([guid]::NewGuid().ToString('N'))") $privateStagingRoot
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Copy-Item -LiteralPath $built -Destination (Join-Path $stage 'liblumia_gigascan_core.so')
    Copy-Item -LiteralPath $libcxx -Destination (Join-Path $stage 'libc++_shared.so')
    $readelf = Join-Path $ndkBin 'llvm-readelf.exe'
    $coreSo = Join-Path $stage 'liblumia_gigascan_core.so'
    $dynamic = (& $readelf '-d' $coreSo) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect ELF dynamic section for $abi" }
    foreach ($match in [regex]::Matches($dynamic, 'Shared library: \[(.+?)\]')) {
        if ($match.Groups[1].Value -notin @('libc.so','libm.so','libdl.so','liblog.so','libz.so','libc++_shared.so')) { throw "Unexpected unresolved runtime dependency for $abi`: $($match.Groups[1].Value)" }
    }
    if ($dynamic -notmatch 'Shared library: \[libc\+\+_shared\.so\]') { throw "ELF does not declare the staged libc++_shared runtime dependency for $abi" }
    $coreHeader = (& $readelf '-h' $coreSo) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect core ELF header for $abi" }
    $coreProgramHeaders = (& $readelf '-lW' $coreSo) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect core ELF segments for $abi" }
    $coreElf = Assert-AndroidElfText $abi $coreHeader $coreProgramHeaders
    $runtimeSo = Join-Path $stage 'libc++_shared.so'
    $runtimeHeader = (& $readelf '-h' $runtimeSo) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect libc++ ELF header for $abi" }
    $runtimeProgramHeaders = (& $readelf '-lW' $runtimeSo) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect libc++ ELF segments for $abi" }
    $runtimeElf = Assert-AndroidElfText $abi $runtimeHeader $runtimeProgramHeaders
    $symbols = (& $readelf '--dyn-syms' $coreSo) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect ELF symbols for $abi" }
    foreach ($symbol in @('lumia_gigascan_abi_version','lumia_gigascan_is_available','lumia_gigascan_plan_json','lumia_gigascan_stitch_json','lumia_gigascan_register_json','lumia_gigascan_spherical_json','lumia_gigascan_job_json','lumia_gigascan_free','lumia_gigascan_free_json')) {
        if ($symbols -notmatch "\b$symbol\b") { throw "Missing required FFI export $symbol ($abi)" }
    }
    $testBinaryHash = $null
    $testBinaryPath = $null
    if ($BuildTests) {
        $previousRustFlags = $env:RUSTFLAGS
        $env:RUSTFLAGS = '-C link-arg=-Wl,--no-undefined -C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384 -C link-arg=-lc++_shared'
        Push-Location $native
        try {
            Invoke-Checked 'cargo.exe' @('test','--locked','--release','--lib','--target',$triple,'--no-run') "native/core Android unit-test build ($abi)"
        } finally {
            Pop-Location
            if ($null -eq $previousRustFlags) { Remove-Item Env:RUSTFLAGS -ErrorAction SilentlyContinue }
            else { $env:RUSTFLAGS = $previousRustFlags }
        }
        $testCandidates = @(Get-ChildItem -LiteralPath (Join-Path $native "target\$triple\release\deps") -File | Where-Object {
            $_.Name -like 'lumia_gigascan_core-*' -and $_.Extension -eq ''
        } | Sort-Object LastWriteTime -Descending)
        if ($testCandidates.Count -eq 0) { throw "Cargo did not produce the Android unit-test executable for $abi" }
        $testBinary = $testCandidates[0].FullName
        $testHeader = (& $readelf '-h' $testBinary) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "Could not inspect Android unit-test ELF for $abi" }
        $testProgramHeaders = (& $readelf '-lW' $testBinary) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "Could not inspect Android unit-test segments for $abi" }
        [void](Assert-AndroidElfText $abi $testHeader $testProgramHeaders)
        $testDynamic = (& $readelf '-d' $testBinary) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $testDynamic -notmatch 'Shared library: \[libc\+\+_shared\.so\]') { throw "Android test executable lacks libc++_shared for $abi" }
        $testOutput = Join-Path $cache "android-tests\$abi"
        $testOutput = Assert-OwnedPath $testOutput $cache
        New-Item -ItemType Directory -Force -Path $testOutput | Out-Null
        $testBinaryPath = Join-Path $testOutput 'lumia_gigascan_core_tests'
        Copy-Item -LiteralPath $testBinary -Destination $testBinaryPath -Force
        $testBinaryHash = (Get-FileHash -LiteralPath $testBinaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        [ordered]@{abi=$abi; target=$triple; apiLevel=$ApiLevel; coreSourceTreeSha256=(Get-CoreSourceSha256); testBinarySha256=$testBinaryHash; bundledIntoApk=$false} |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $testOutput 'test-manifest.json') -Encoding utf8
    }
    $manifest = [ordered]@{
        product='PocketGigaScan native core'; abi=$abi; target=$triple; apiLevel=$ApiLevel; ndkVersion=$ndkVersion
        openCvVersion='4.13.0'; openCvArchiveSha256=$opencvSha256
        libjxl=[ordered]@{version='0.12.0'; url=$pins[0].Url; sha256=$pins[0].Sha256}
        dependencies=@($pins | Select-Object -Skip 1 | ForEach-Object { [ordered]@{name=$_.Name; revision=$_.Revision; url=$_.Url; sha256=$_.Sha256} })
        openCvUrl='https://github.com/opencv/opencv/releases/download/4.13.0/opencv-4.13.0-android-sdk.zip'
        noUndefinedSymbols=$true; loadSegments16KiBAligned=$true
        coreElf=$coreElf; libcxxElf=$runtimeElf
        coreSourceCommit=(((& git -c "safe.directory=$repo" -C $repo rev-parse HEAD) | Out-String).Trim())
        coreSourceTreeSha256=(Get-CoreSourceSha256)
        ffiExports=@('lumia_gigascan_abi_version','lumia_gigascan_is_available','lumia_gigascan_plan_json','lumia_gigascan_stitch_json','lumia_gigascan_register_json','lumia_gigascan_spherical_json','lumia_gigascan_job_json','lumia_gigascan_free','lumia_gigascan_free_json')
        coreSha256=(Get-FileHash -LiteralPath $coreSo -Algorithm SHA256).Hash.ToLowerInvariant()
        libcxxSha256=(Get-FileHash -LiteralPath $runtimeSo -Algorithm SHA256).Hash.ToLowerInvariant()
        androidTestBinarySha256=$testBinaryHash; androidTestBinaryPath=$testBinaryPath
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'build-manifest.json') -Encoding utf8
    $backup = Assert-OwnedPath (Join-Path $backupRoot "abi-$abi-$([guid]::NewGuid().ToString('N'))") $backupRoot
    Assert-OwnedPath $stage $privateStagingRoot
    if (Test-Path -LiteralPath $abiOut) { Move-Item -LiteralPath $abiOut -Destination $backup }
    try {
        Move-Item -LiteralPath $stage -Destination $abiOut
    } catch {
        if ((Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $abiOut)) {
            Move-Item -LiteralPath $backup -Destination $abiOut
        }
        throw
    }
}
if ($JxlOnly) { Write-Host 'Pinned Android libjxl dependencies built.' }
else { Write-Host "Android native core staged at $output" }
