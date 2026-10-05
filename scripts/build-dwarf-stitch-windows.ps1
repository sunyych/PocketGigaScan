[CmdletBinding()]
param(
    [string]$OpenCvDir,
    [string]$JxlSdk,
    [string]$DjxlExecutable,
    [string]$FlutterPath,
    [string]$OutputDirectory,
    [switch]$PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path $PSScriptRoot -Parent
$app = Join-Path $repo 'Apps/Flutter/stitch_app'
$native = Join-Path $repo 'native/core'
$pin = [ordered]@{
    openCvVersion = '4.13.0'
    openCvUrl = 'https://github.com/opencv/opencv/archive/refs/tags/4.13.0.tar.gz'
    openCvSha256 = '1d40ca017ea51c533cf9fd5cbde5b5fe7ae248291ddf2af99d4c17cf8e13017d'
    jxlVersion = '0.12.0'
    jxlUrl = 'https://github.com/libjxl/libjxl/releases/download/v0.12.0/jxl-x64-windows-static.zip'
    jxlSha256 = '3025d7e308390796d20492322e606bc92decaee7b6bc99d3f7547870ae5db7de'
    djxlSha256 = '6970ce73de51e046b39bd5f28fc7bc5da64e9f6505c11194319f43d8849d2bf4'
    flutterVersion = '3.44.2'
    flutterCommit = 'c9a6c484230f8b5e408ec57be1ef71dee1e77020'
    flutterUrl = 'https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.44.2-stable.zip'
    flutterSha256 = 'd79ae99807ba744b843e54f048308c629061456fdc7b0753251fb96eb5346a0e'
    rustVersion = '1.88.0'
}

if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo '.build/dwarf-stitch-windows' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$cache = Join-Path $OutputDirectory 'dependencies'
$opencvSource = Join-Path $cache "opencv-$($pin.openCvVersion)"
$opencvBuild = Join-Path $cache "opencv-$($pin.openCvVersion)-build"
$opencvInstall = Join-Path $cache "opencv-$($pin.openCvVersion)-install"
$jxlRoot = Join-Path $cache "libjxl-$($pin.jxlVersion)"
$flutterRoot = Join-Path $cache "flutter-$($pin.flutterVersion)"
$releaseDir = Join-Path $app 'build/windows/x64/runner/Release'
$packageDir = Join-Path $OutputDirectory 'package'
$archivePath = Join-Path $OutputDirectory 'PocketGigaScan-Windows-x64.zip'
$checksumPath = "$archivePath.sha256"
$manifestOutputPath = Join-Path $OutputDirectory 'build-manifest.json'

function Assert-OwnedPath([string]$Path, [string]$OwnerRoot, [switch]$InspectTree) {
    $target = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetFullPath($OwnerRoot).TrimEnd([char[]]@('\', '/'))
    $rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing file operation outside its owned directory: '$target' is not below '$root'."
    }

    $cursor = [IO.Path]::GetPathRoot($target)
    $relative = $target.Substring($cursor.Length)
    foreach ($part in $relative.Split([IO.Path]::DirectorySeparatorChar, [StringSplitOptions]::RemoveEmptyEntries)) {
        $cursor = Join-Path $cursor $part
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing file operation through a reparse point: $cursor"
            }
        }
    }
    if ($InspectTree -and (Test-Path -LiteralPath $target -PathType Container)) {
        $reparseEntry = Get-ChildItem -LiteralPath $target -Force -Recurse | Where-Object {
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        } | Select-Object -First 1
        if ($reparseEntry) { throw "Refusing recursive file operation through a nested reparse point: $($reparseEntry.FullName)" }
    }
}

function Find-JxlSdkRoot([string]$Root) {
    $directories = @()
    if (Test-Path -LiteralPath $Root -PathType Container) {
        $directories += Get-Item -LiteralPath $Root
        $directories += Get-ChildItem -LiteralPath $Root -Directory -Recurse
    }
    $candidate = $directories | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName 'include/jxl/encode.h')) -and
        (Test-Path -LiteralPath (Join-Path $_.FullName 'lib/jxl.lib'))
    } | Select-Object -First 1
    if ($candidate) { return $candidate.FullName }
    return $null
}

function Assert-Vs18ToolchainVersion([string]$VisualStudioVersion, [string]$VCToolsVersion) {
    if ($VisualStudioVersion -notmatch '^18(?:\.|$)') {
        throw "Visual Studio 18 is required to link against the pinned libjxl SDK; found '$VisualStudioVersion'."
    }
    $toolsetMatch = [regex]::Match($VCToolsVersion, '^(\d+\.\d+(?:\.\d+){0,2})')
    if (-not $toolsetMatch.Success -or [version]$toolsetMatch.Groups[1].Value -lt [version]'14.50') {
        throw "MSVC 14.50 or newer is required to link against the pinned libjxl SDK; found '$VCToolsVersion'."
    }
}

function Initialize-Vs18Environment {
    $installerDirectory = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Microsoft Visual Studio/Installer'
    $vswhere = Join-Path $installerDirectory 'vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw "Visual Studio locator is missing: $vswhere" }
    $vswhereOutput = @(& $vswhere -latest -products '*' -version '[18.0,19.0)' -property installationPath)
    if ($LASTEXITCODE -ne 0) { throw 'Visual Studio locator failed while searching for Visual Studio 18.' }
    $installationPath = $vswhereOutput | Select-Object -First 1
    if (-not $installationPath) { throw 'Visual Studio 18 with an x64 C++ toolchain is required.' }
    $installationPath = [IO.Path]::GetFullPath($installationPath.Trim())
    $devCmd = Join-Path $installationPath 'Common7/Tools/VsDevCmd.bat'
    if (-not (Test-Path -LiteralPath $devCmd -PathType Leaf)) { throw "VS 18 developer environment script is missing: $devCmd" }

    $commandLine = 'call "{0}" -no_logo -arch=x64 -host_arch=x64 >nul && set' -f $devCmd
    $environmentLines = & $env:ComSpec /d /c $commandLine
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the Visual Studio 18 x64 developer environment.' }
    foreach ($line in $environmentLines) {
        $separator = $line.IndexOf('=')
        if ($separator -gt 0) {
            $name = $line.Substring(0, $separator)
            Set-Item -Path "Env:$name" -Value $line.Substring($separator + 1)
        }
    }
    Assert-Vs18ToolchainVersion $env:VisualStudioVersion $env:VCToolsVersion
    $link = Get-Command link.exe -ErrorAction Stop
    $cl = Get-Command cl.exe -ErrorAction Stop
    $installPrefix = $installationPath.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
    foreach ($compiler in @($link, $cl)) {
        if (-not ([IO.Path]::GetFullPath($compiler.Source)).StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The selected $($compiler.Name) is outside the VS 18 installation: $($compiler.Source)"
        }
    }
    $redistRoot = $env:VCToolsRedistDir
    if (-not $redistRoot) { $redistRoot = Join-Path $installationPath "VC/Redist/MSVC/$env:VCToolsVersion" }
    $redistRoot = [IO.Path]::GetFullPath($redistRoot)
    if (-not $redistRoot.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The selected VC runtime directory is outside the VS 18 installation: $redistRoot"
    }
    $x64RuntimeRoot = Join-Path $redistRoot 'x64'
    $crtDirectories = @(Get-ChildItem -LiteralPath $x64RuntimeRoot -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^Microsoft\.VC\d+\.CRT$' -and $_.FullName -notmatch '(?i)debug'
    })
    if ($crtDirectories.Count -ne 1) {
        throw "Expected one x64 Release Microsoft.VC*.CRT directory under $x64RuntimeRoot, found $($crtDirectories.Count)."
    }
    Write-Host "MSVC toolchain: Visual Studio $env:VisualStudioVersion, MSVC $env:VCToolsVersion, linker $($link.Source)"
    return [pscustomobject]@{
        visualStudioVersion = $env:VisualStudioVersion
        msvcToolsetVersion = $env:VCToolsVersion
        linkerPath = $link.Source
        generator = 'Visual Studio 18 2026'
        visualStudioInstallPath = $installationPath
        vcRuntimeDirectory = $crtDirectories[0].FullName
    }
}

function Get-PeMachine([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -lt 0x40) { throw "Not a valid PE file: $Path" }
        $reader = New-Object IO.BinaryReader($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Missing DOS MZ signature: $Path" }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0x40 -or $peOffset -gt ($stream.Length - 6)) { throw "Invalid PE header offset: $Path" }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "Missing PE signature: $Path" }
        $machine = $reader.ReadUInt16()
        switch ($machine) {
            0x8664 { return 'x64' }
            0x014c { return 'x86' }
            0xAA64 { return 'arm64' }
            default { return ('unknown-0x{0:X4}' -f $machine) }
        }
    } finally { $stream.Dispose() }
}

function Copy-VcRuntime([string]$RuntimeDirectory, [string]$TargetDirectory) {
    $runtimeDirectory = [IO.Path]::GetFullPath($RuntimeDirectory)
    if ((Split-Path $runtimeDirectory -Leaf) -notmatch '^Microsoft\.VC\d+\.CRT$' -or
        (Split-Path (Split-Path $runtimeDirectory -Parent) -Leaf) -ne 'x64' -or
        $runtimeDirectory -match '(?i)debug_nonredist') {
        throw "Expected the x64 Release Microsoft.VC*.CRT app-local runtime directory, got: $runtimeDirectory"
    }
    $runtimeItem = Get-Item -LiteralPath $runtimeDirectory -Force -ErrorAction Stop
    if (($runtimeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing a reparse point as the VC runtime source: $runtimeDirectory"
    }
    $files = @(Get-ChildItem -LiteralPath $runtimeDirectory -File -Force | Where-Object {
        $_.Extension -in @('.dll', '.manifest')
    } | Sort-Object Name)
    $requiredNames = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
    $presentNames = @($files | ForEach-Object Name)
    foreach ($requiredName in $requiredNames) {
        if ($requiredName -notin $presentNames) { throw "Required x64 Visual C++ runtime file is missing: $requiredName ($runtimeDirectory)" }
    }
    if ($files.Count -eq 0) { throw "No redistributable DLL or manifest files found under $runtimeDirectory" }
    New-Item -ItemType Directory -Force -Path $TargetDirectory | Out-Null
    $inventory = @()
    foreach ($file in $files) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing a reparse point in the VC runtime directory: $($file.FullName)" }
        if ($file.Extension -eq '.dll') {
            $machine = Get-PeMachine $file.FullName
            if ($machine -ne 'x64') { throw "VC runtime DLL is not x64 ($machine): $($file.Name)" }
        }
        $destination = Join-Path $TargetDirectory $file.Name
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        $inventory += [pscustomobject]@{
            name = $file.Name
            architecture = if ($file.Extension -eq '.dll') { 'x64' } else { 'metadata' }
            fileVersion = if ($file.Extension -eq '.dll') { [Diagnostics.FileVersionInfo]::GetVersionInfo($destination).FileVersion } else { $null }
            sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return ,$inventory
}

function Copy-RustRegistryLicenses([string]$MetadataJson, [string]$DestinationRoot) {
    $metadata = $MetadataJson | ConvertFrom-Json
    if (-not $metadata.packages) { throw 'Cargo metadata did not contain packages.' }
    New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null
    $inventory = @()
    $seenDestinations = @{}
    foreach ($package in @($metadata.packages | Where-Object { $_.source -like 'registry+*' } | Sort-Object name, version, source)) {
        $manifestPath = [IO.Path]::GetFullPath([string]$package.manifest_path)
        $packageRoot = Split-Path $manifestPath -Parent
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Cargo registry manifest is missing for $($package.name)-$($package.version): $manifestPath"
        }
        $destinationName = "$($package.name)-$($package.version)"
        if ($seenDestinations.ContainsKey($destinationName) -and $seenDestinations[$destinationName] -ne $package.id) {
            throw "Multiple Cargo registry package identities map to the same license folder: $destinationName"
        }
        $seenDestinations[$destinationName] = $package.id

        $licenseFiles = @(Get-ChildItem -LiteralPath $packageRoot -File -Force | Where-Object {
            $_.Name -match '^(?i:LICENSE|COPYING|NOTICE)([-_.].*)?$'
        } | Sort-Object Name)
        if ($licenseFiles.Count -eq 0 -and $package.license_file) {
            $declaredLicenseFile = [IO.Path]::GetFullPath((Join-Path $packageRoot ([string]$package.license_file)))
            $packagePrefix = $packageRoot.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
            if (-not $declaredLicenseFile.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Cargo license_file escapes package root for ${destinationName}: $($package.license_file)"
            }
            if (Test-Path -LiteralPath $declaredLicenseFile -PathType Leaf) {
                $licenseFiles = @(Get-Item -LiteralPath $declaredLicenseFile)
            }
        }
        if ($licenseFiles.Count -eq 0) {
            throw "Cargo registry dependency has no packaged LICENSE/COPYING/NOTICE text: $destinationName (license='$($package.license)', license_file='$($package.license_file)')"
        }

        $destination = Join-Path $DestinationRoot $destinationName
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        $copiedFiles = @()
        foreach ($licenseFile in $licenseFiles) {
            $destinationFile = Join-Path $destination $licenseFile.Name
            Copy-Item -LiteralPath $licenseFile.FullName -Destination $destinationFile -Force
            $relativePath = $licenseFile.FullName.Substring($packageRoot.Length).TrimStart('\', '/')
            $copiedFiles += [pscustomobject]@{
                path = $relativePath.Replace('\', '/')
                sha256 = (Get-FileHash -LiteralPath $destinationFile -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
        $inventory += [pscustomobject]@{
            name = $package.name
            version = $package.version
            source = $package.source
            declaredLicense = $package.license
            declaredLicenseFile = $package.license_file
            files = $copiedFiles
        }
    }
    return ,$inventory
}

function Get-BuildPlan {
    [pscustomobject]@{
        product = 'PocketGigaScan'
        subtitle = 'DWARF Stitch'
        app = $app
        coreManifest = Join-Path $native 'Cargo.toml'
        opencvVersion = $pin.openCvVersion
        opencvSha256 = $pin.openCvSha256
        libjxlVersion = $pin.jxlVersion
        libjxlSha256 = $pin.jxlSha256
        djxlSha256 = $pin.djxlSha256
        flutterVersion = $pin.flutterVersion
        flutterCommit = $pin.flutterCommit
        rustVersion = $pin.rustVersion
        minimumVisualStudioVersion = '18.0'
        minimumMsvcToolsetVersion = '14.50'
        nativeOutputs = @('png', 'tiff', 'jxl')
        releaseExecutable = Join-Path $releaseDir 'PocketGigaScan.exe'
        zip = $archivePath
        checksum = $checksumPath
        manifest = $manifestOutputPath
    }
}

if ($PlanOnly) {
    Get-BuildPlan | ConvertTo-Json -Depth 5
    exit 0
}

if (-not (Test-Path -LiteralPath (Join-Path $native 'Cargo.toml'))) {
    throw "Vendored Rust core is missing: $native"
}
if (-not (Get-Command cargo.exe -ErrorAction SilentlyContinue)) { throw 'Rust/Cargo is required; install the pinned Rust toolchain 1.88.0.' }
$vsToolchain = Initialize-Vs18Environment
if (-not (Get-Command cmake.exe -ErrorAction SilentlyContinue)) { throw 'CMake is required (Visual Studio 2026 C++ workload must be installed).' }

Assert-OwnedPath $cache $OutputDirectory
New-Item -ItemType Directory -Force -Path $cache, $OutputDirectory | Out-Null
Assert-OwnedPath $cache $OutputDirectory
Assert-OwnedPath $packageDir $OutputDirectory
Assert-OwnedPath $archivePath $OutputDirectory
Assert-OwnedPath $checksumPath $OutputDirectory
Assert-OwnedPath $manifestOutputPath $OutputDirectory
Assert-OwnedPath $opencvSource $cache
Assert-OwnedPath $opencvBuild $cache
Assert-OwnedPath $opencvInstall $cache
Assert-OwnedPath $jxlRoot $cache
Assert-OwnedPath $flutterRoot $cache

function Invoke-Checked([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory) {
    Write-Host "> $Executable $($Arguments -join ' ')"
    Push-Location $WorkingDirectory
    try {
        & $Executable @Arguments
        if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Executable $($Arguments -join ' ')" }
    } finally { Pop-Location }
}

function Save-VerifiedArchive([string]$Url, [string]$Destination, [string]$ExpectedSha256) {
    Assert-OwnedPath $Destination $cache
    if (-not (Test-Path -LiteralPath $Destination)) {
        Write-Host "Downloading pinned dependency: $Url"
        Invoke-WebRequest -Uri $Url -OutFile $Destination
    }
    $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedSha256) {
        throw "Dependency SHA-256 mismatch for $Destination (expected $ExpectedSha256, got $actual)."
    }
}

function Get-CoreCapabilities([string]$DllDirectory) {
    $probeSource = @'
using System;
using System.Runtime.InteropServices;
public static class PocketGigaScanCoreProbe {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetDllDirectory(string path);
    [DllImport("lumia_gigascan_core.dll", EntryPoint = "lumia_gigascan_job_json", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr JobJson([MarshalAs(UnmanagedType.LPUTF8Str)] string request);
    [DllImport("lumia_gigascan_core.dll", EntryPoint = "lumia_gigascan_free", CallingConvention = CallingConvention.Cdecl)]
    public static extern void Free(IntPtr value);
}
'@
    Add-Type -TypeDefinition $probeSource
    if (-not [PocketGigaScanCoreProbe]::SetDllDirectory($DllDirectory)) {
        throw "Unable to configure native DLL lookup for $DllDirectory"
    }
    $responsePointer = [IntPtr]::Zero
    try {
        $responsePointer = [PocketGigaScanCoreProbe]::JobJson('{"command":"capabilities"}')
        if ($responsePointer -eq [IntPtr]::Zero) { throw 'Rust core returned a null capabilities response.' }
        $responseText = [Runtime.InteropServices.Marshal]::PtrToStringUTF8($responsePointer)
        $response = $responseText | ConvertFrom-Json
        if ($response.ok -ne $true) { throw "Rust core capabilities request failed: $responseText" }
        $formats = $response.capabilities.exportFormats
        if ($formats.png -ne $true -or $formats.tiff -ne $true -or $formats.jxl -ne $true -or
            $response.capabilities.jpegXlAvailable -ne $true) {
            throw "Release core lacks PNG/TIFF/JPEG XL capabilities: $responseText"
        }
        return $response.capabilities
    } finally {
        if ($responsePointer -ne [IntPtr]::Zero) { [PocketGigaScanCoreProbe]::Free($responsePointer) }
        [void][PocketGigaScanCoreProbe]::SetDllDirectory($null)
    }
}

function Assert-ZipMatchesPackage([string]$ZipPath, [string]$Directory) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $expected = @(Get-ChildItem -LiteralPath $Directory -File -Recurse | ForEach-Object {
            [pscustomobject]@{ path = $_.FullName.Substring($Directory.Length).TrimStart('\').Replace('\', '/'); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
        })
        $entries = @($zip.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
        if ($entries.Count -ne $expected.Count) { throw "ZIP file count mismatch: expected $($expected.Count), found $($entries.Count)." }
        $expectedByPath = @{}
        foreach ($item in $expected) { $expectedByPath[$item.path] = $item.sha256 }
        foreach ($entry in $entries) {
            if (-not $expectedByPath.ContainsKey($entry.FullName)) { throw "Unexpected ZIP entry: $($entry.FullName)" }
            $stream = $entry.Open()
            try {
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $actual = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
                finally { $sha.Dispose() }
            } finally { $stream.Dispose() }
            if ($actual -ne $expectedByPath[$entry.FullName]) { throw "ZIP content checksum mismatch: $($entry.FullName)" }
            $expectedByPath.Remove($entry.FullName)
        }
        if ($expectedByPath.Count -ne 0) { throw "ZIP is missing entries: $($expectedByPath.Keys -join ', ')" }
    } finally { $zip.Dispose() }
}

if (-not $OpenCvDir) {
    $sourceArchive = Join-Path $cache "opencv-$($pin.openCvVersion).tar.gz"
    Assert-OwnedPath $sourceArchive $cache
    Save-VerifiedArchive $pin.openCvUrl $sourceArchive $pin.openCvSha256
    if (-not (Test-Path -LiteralPath (Join-Path $opencvSource 'CMakeLists.txt'))) {
        if (Test-Path -LiteralPath $opencvSource) {
            Assert-OwnedPath $opencvSource $cache -InspectTree
            Remove-Item -LiteralPath $opencvSource -Recurse -Force
        }
        Assert-OwnedPath $opencvSource $cache
        New-Item -ItemType Directory -Force -Path $opencvSource | Out-Null
        Invoke-Checked 'tar.exe' @('-xzf', $sourceArchive, '--strip-components=1', '-C', $opencvSource) $cache
    }
    $vsGenerator = $vsToolchain.generator
    $cmakeArgs = @(
        '-S', $opencvSource, '-B', $opencvBuild, '-G', $vsGenerator, '-A', 'x64',
        "-DCMAKE_INSTALL_PREFIX=$opencvInstall",
        '-DBUILD_LIST=core,imgproc,imgcodecs,calib3d,features2d,flann,photo,stitching',
        '-DBUILD_SHARED_LIBS=OFF', '-DBUILD_opencv_apps=OFF', '-DBUILD_opencv_world=OFF',
        '-DBUILD_TESTS=OFF', '-DBUILD_PERF_TESTS=OFF', '-DBUILD_EXAMPLES=OFF',
        '-DBUILD_DOCS=OFF', '-DBUILD_JAVA=OFF', '-DBUILD_opencv_python3=OFF',
        '-DWITH_JPEG=ON', '-DWITH_PNG=ON', '-DWITH_TIFF=ON', '-DWITH_OPENJPEG=ON', '-DWITH_WEBP=ON',
        '-DBUILD_ZLIB=ON', '-DBUILD_JPEG=ON', '-DBUILD_PNG=ON', '-DBUILD_TIFF=ON', '-DBUILD_OPENJPEG=ON',
        '-DWITH_IPP=OFF', '-DWITH_TBB=OFF', '-DWITH_ITT=OFF', '-DWITH_OPENCL=OFF', '-DWITH_CUDA=OFF',
        '-DWITH_FFMPEG=OFF', '-DWITH_MSMF=OFF', '-DWITH_OPENEXR=OFF', '-DWITH_PROTOBUF=OFF',
        '-DOPENCV_FORCE_3RDPARTY_BUILD=ON', '-DOPENCV_GENERATE_PKGCONFIG=OFF', '-DBUILD_WITH_STATIC_CRT=ON'
    )
    Invoke-Checked 'cmake.exe' $cmakeArgs $repo
    $parallel = [Math]::Max(2, [Math]::Min(6, [Environment]::ProcessorCount))
    Invoke-Checked 'cmake.exe' @('--build', $opencvBuild, '--config', 'Release', '--target', 'INSTALL', '--parallel', "$parallel") $repo
    $OpenCvDir = $opencvInstall
}

$OpenCvDir = [IO.Path]::GetFullPath($OpenCvDir)
if (-not (Test-Path -LiteralPath (Join-Path $OpenCvDir 'include/opencv2/core.hpp'))) {
    throw "OpenCV include files not found under $OpenCvDir"
}
$opencvVersionHeader = Get-Content -LiteralPath (Join-Path $OpenCvDir 'include/opencv2/core/version.hpp') -Raw
if ($opencvVersionHeader -notmatch '(?m)^\s*#\s*define\s+CV_VERSION_MAJOR\s+4\s*$' -or
    $opencvVersionHeader -notmatch '(?m)^\s*#\s*define\s+CV_VERSION_MINOR\s+13\s*$' -or
    $opencvVersionHeader -notmatch '(?m)^\s*#\s*define\s+CV_VERSION_REVISION\s+0\s*$') {
    throw "OpenCV must be pinned to version 4.13.0: $OpenCvDir"
}
$opencvLib = Get-ChildItem -LiteralPath $OpenCvDir -Filter 'opencv_stitching4130.lib' -File -Recurse | Select-Object -First 1
if (-not $opencvLib) { throw "Static OpenCV 4.13 libraries were not found under $OpenCvDir" }
$env:OPENCV_DIR = $OpenCvDir
$env:OPENCV_LINK_PATHS = $opencvLib.DirectoryName
$env:OPENCV_LINK_LIBS = 'opencv_stitching4130;opencv_calib3d4130;opencv_features2d4130;opencv_flann4130;opencv_imgcodecs4130;opencv_imgproc4130;opencv_core4130;opencv_photo4130;libjpeg-turbo;libopenjp2;libpng;libtiff;libwebp;zlib'

if (-not $JxlSdk) {
    $jxlArchive = Join-Path $cache "libjxl-$($pin.jxlVersion)-windows-static.zip"
    Assert-OwnedPath $jxlArchive $cache
    Save-VerifiedArchive $pin.jxlUrl $jxlArchive $pin.jxlSha256
    if (-not (Test-Path -LiteralPath (Join-Path $jxlRoot 'include/jxl/encode.h'))) {
        if (Test-Path -LiteralPath $jxlRoot) {
            Assert-OwnedPath $jxlRoot $cache -InspectTree
            Remove-Item -LiteralPath $jxlRoot -Recurse -Force
        }
        Assert-OwnedPath $jxlRoot $cache
        New-Item -ItemType Directory -Force -Path $jxlRoot | Out-Null
        Expand-Archive -LiteralPath $jxlArchive -DestinationPath $jxlRoot -Force
    }
    $candidate = Find-JxlSdkRoot $jxlRoot
    if ($candidate) { $JxlSdk = $candidate } else { $JxlSdk = $jxlRoot }
}
$JxlSdk = [IO.Path]::GetFullPath($JxlSdk)
if (-not (Test-Path -LiteralPath (Join-Path $JxlSdk 'include/jxl/encode.h'))) { throw "libjxl headers missing in $JxlSdk" }
$env:LUMIA_JXL_SDK = $JxlSdk
Remove-Item Env:LUMIA_JXL_TEST_HELPERS -ErrorAction SilentlyContinue

Invoke-Checked 'rustup.exe' @('toolchain', 'install', $pin.rustVersion, '--profile', 'minimal', '--no-self-update') $repo

$djxlPath = $DjxlExecutable
if (-not $djxlPath) {
    $djxl = Get-ChildItem -LiteralPath $jxlRoot -Filter 'djxl.exe' -File -Recurse | Select-Object -First 1
    if (-not $djxl) {
        $djxl = Get-ChildItem -LiteralPath $JxlSdk -Filter 'djxl.exe' -File -Recurse | Select-Object -First 1
    }
    if (-not $djxl) {
        $localDjxl = Join-Path $repo '.local/flutter-stitch-core/windows/tools/djxl.exe'
        if (Test-Path -LiteralPath $localDjxl) { $djxl = Get-Item -LiteralPath $localDjxl }
    }
    if ($djxl) { $djxlPath = $djxl.FullName }
}
if (-not $djxlPath -or -not (Test-Path -LiteralPath $djxlPath -PathType Leaf)) { throw 'The verified official libjxl archive must provide djxl.exe for the independent JPEG XL tests.' }
if ((Get-FileHash -LiteralPath $djxlPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pin.djxlSha256) {
    throw "djxl.exe does not match the verified libjxl 0.12.0 release binary: $djxlPath"
}
$env:LUMIA_JXL_TEST_HELPERS = '1'
$env:LUMIA_DJXL_PATH = [IO.Path]::GetFullPath($djxlPath)
Invoke-Checked 'cargo.exe' @("+$($pin.rustVersion)", 'test', '--locked', '--manifest-path', (Join-Path $native 'Cargo.toml')) $repo
Remove-Item Env:LUMIA_JXL_TEST_HELPERS -ErrorAction SilentlyContinue
Remove-Item Env:LUMIA_DJXL_PATH -ErrorAction SilentlyContinue
Invoke-Checked 'cargo.exe' @("+$($pin.rustVersion)", 'build', '--release', '--locked', '--manifest-path', (Join-Path $native 'Cargo.toml')) $repo
$cargoMetadataJson = & cargo.exe "+$($pin.rustVersion)" metadata --format-version 1 --locked --manifest-path (Join-Path $native 'Cargo.toml')
if ($LASTEXITCODE -ne 0) { throw "Cargo metadata failed ($LASTEXITCODE)." }

if (-not $FlutterPath) {
    $flutterArchive = Join-Path $cache "flutter-$($pin.flutterVersion)-windows.zip"
    Assert-OwnedPath $flutterArchive $cache
    Save-VerifiedArchive $pin.flutterUrl $flutterArchive $pin.flutterSha256
    if (-not (Test-Path -LiteralPath (Join-Path $flutterRoot 'bin/flutter.bat'))) {
        if (Test-Path -LiteralPath $flutterRoot) {
            Assert-OwnedPath $flutterRoot $cache -InspectTree
            Remove-Item -LiteralPath $flutterRoot -Recurse -Force
        }
        $extractRoot = Join-Path $cache ("flutter-extract-" + [guid]::NewGuid().ToString('N'))
        Assert-OwnedPath $extractRoot $cache
        Expand-Archive -LiteralPath $flutterArchive -DestinationPath $extractRoot -Force
        $extracted = Join-Path $extractRoot 'flutter'
        if (-not (Test-Path -LiteralPath (Join-Path $extracted 'bin/flutter.bat'))) { throw 'Pinned Flutter archive has an unexpected directory layout.' }
        Assert-OwnedPath $extracted $cache
        Assert-OwnedPath $flutterRoot $cache
        Move-Item -LiteralPath $extracted -Destination $flutterRoot
        Assert-OwnedPath $extractRoot $cache
        Remove-Item -LiteralPath $extractRoot -Force
    }
    $FlutterPath = Join-Path $flutterRoot 'bin/flutter.bat'
} elseif (Test-Path -LiteralPath (Join-Path $FlutterPath 'bin/flutter.bat')) {
    $FlutterPath = Join-Path $FlutterPath 'bin/flutter.bat'
} elseif (Test-Path -LiteralPath $FlutterPath -PathType Container) {
    $FlutterPath = Join-Path $FlutterPath 'flutter.bat'
}
if (-not (Test-Path -LiteralPath $FlutterPath -PathType Leaf)) { throw "Flutter executable not found: $FlutterPath" }
$FlutterPath = [IO.Path]::GetFullPath($FlutterPath)
Invoke-Checked $FlutterPath @('--version') $repo
$flutterVersionOutput = & $FlutterPath '--version' '--machine'
if ($LASTEXITCODE -ne 0) { throw 'Could not query Flutter version.' }
$flutterVersionInfo = ($flutterVersionOutput -join [Environment]::NewLine) | ConvertFrom-Json
if ($flutterVersionInfo.frameworkVersion -ne $pin.flutterVersion -or $flutterVersionInfo.frameworkRevision -ne $pin.flutterCommit) {
    throw "Flutter override does not match the pinned SDK $($pin.flutterVersion) / $($pin.flutterCommit)."
}
Invoke-Checked $FlutterPath @('precache', '--windows') $repo
Invoke-Checked $FlutterPath @('clean') $app
Invoke-Checked $FlutterPath @('pub', 'get', '--enforce-lockfile') $app
Invoke-Checked $FlutterPath @('analyze') $app
Invoke-Checked $FlutterPath @('test', '--reporter', 'expanded') $app
Invoke-Checked $FlutterPath @('build', 'windows', '--release', '--target', 'lib/main.dart') $app

$exe = Join-Path $releaseDir 'PocketGigaScan.exe'
$coreDll = Join-Path $releaseDir 'lumia_gigascan_core.dll'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Expected executable not found: $exe" }
if (-not (Test-Path -LiteralPath $coreDll -PathType Leaf)) { throw "Expected Rust core DLL not found beside executable: $coreDll" }
$executables = @(Get-ChildItem -LiteralPath $releaseDir -Filter '*.exe' -File -Recurse | ForEach-Object Name | Sort-Object -Unique)
if ($executables.Count -ne 1 -or $executables[0] -ne 'PocketGigaScan.exe') {
    throw "Unexpected Windows executable set in the release directory: $($executables -join ', ')"
}
$capabilities = Get-CoreCapabilities $releaseDir

if (Test-Path -LiteralPath $packageDir) {
    Assert-OwnedPath $packageDir $OutputDirectory -InspectTree
    Remove-Item -LiteralPath $packageDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $packageDir | Out-Null
Get-ChildItem -LiteralPath $releaseDir -Force | Copy-Item -Destination $packageDir -Recurse -Force
$vcRuntimeInventory = Copy-VcRuntime $vsToolchain.vcRuntimeDirectory $packageDir
Copy-Item -LiteralPath (Join-Path $repo 'LICENSE'), (Join-Path $repo 'NOTICE') -Destination $packageDir
Copy-Item -LiteralPath (Join-Path $repo 'third_party/licenses') -Destination (Join-Path $packageDir 'licenses') -Recurse -Force
$rustLicenseInventory = Copy-RustRegistryLicenses ($cargoMetadataJson -join [Environment]::NewLine) (Join-Path $packageDir 'licenses/rust')
$manifest = [ordered]@{
    product = 'PocketGigaScan'
    subtitle = 'DWARF Stitch'
    architecture = 'windows-x64'
    flutterVersion = $pin.flutterVersion
    rustVersion = $pin.rustVersion
    openCvVersion = $pin.openCvVersion
    openCvSourceSha256 = $pin.openCvSha256
    libjxlVersion = $pin.jxlVersion
    libjxlSdkSha256 = $pin.jxlSha256
    flutterCommit = $pin.flutterCommit
    visualStudioVersion = $vsToolchain.visualStudioVersion
    msvcToolsetVersion = $vsToolchain.msvcToolsetVersion
    cmakeGenerator = $vsToolchain.generator
    linkerPath = $vsToolchain.linkerPath
    microsoftVcRuntime = [ordered]@{
        architecture = 'x64'
        source = [IO.Path]::GetRelativePath($vsToolchain.visualStudioInstallPath, $vsToolchain.vcRuntimeDirectory).Replace('\', '/')
        redistributionTerms = 'https://learn.microsoft.com/en-us/visualstudio/releases/2026/redistribution'
        files = $vcRuntimeInventory
    }
    flutterArchiveSha256 = $pin.flutterSha256
    formats = @('PNG', 'TIFF', 'JPEG XL')
    capabilities = $capabilities
    rustRegistryLicenseInventory = $rustLicenseInventory
    sourceCommit = (git -c "safe.directory=$repo" -C $repo rev-parse HEAD).Trim()
    githubSha = if ($env:GITHUB_SHA) { $env:GITHUB_SHA } else { (git -c "safe.directory=$repo" -C $repo rev-parse HEAD).Trim() }
    coreLibrarySha256 = (Get-FileHash -LiteralPath (Join-Path $packageDir 'lumia_gigascan_core.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
}
$manifestJson = $manifest | ConvertTo-Json -Depth 5
$manifestJson | Set-Content -LiteralPath (Join-Path $packageDir 'build-manifest.json') -Encoding utf8
$manifestJson | Set-Content -LiteralPath $manifestOutputPath -Encoding utf8
if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
Compress-Archive -Path (Join-Path $packageDir '*') -DestinationPath $archivePath -CompressionLevel Optimal
$archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $checksumPath -Value "$archiveHash  PocketGigaScan-Windows-x64.zip" -Encoding ascii
Assert-ZipMatchesPackage $archivePath $packageDir
Write-Host "Build package: $archivePath"
Write-Host "SHA-256: $archiveHash"
