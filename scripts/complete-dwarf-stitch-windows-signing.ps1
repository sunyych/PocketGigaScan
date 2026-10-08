[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$UnsignedPackageZip,

    [Parameter(Mandatory = $true)]
    [string]$SignedPackageZip,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedSignerThumbprint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:PeSignatureTargets = @('PocketGigaScan.exe', 'lumia_gigascan_core.dll')
$script:FinalPackageName = 'PocketGigaScan-Windows-x64.zip'

function Get-NormalizedArchivePath {
    param([Parameter(Mandatory = $true)][string]$EntryName)

    if ([string]::IsNullOrWhiteSpace($EntryName) -or $EntryName.Contains("`0")) {
        throw "ZIP contains an empty or invalid entry name."
    }
    $path = $EntryName.Replace('\', '/')
    if ($path.StartsWith('/') -or $path -match '^[A-Za-z]:' -or $path -match '(^|/)\.\.?(/|$)') {
        throw "ZIP entry escapes its package root: '$EntryName'."
    }
    if ($path -match '(^|/)//' -or $path -match '//') {
        throw "ZIP entry has an ambiguous path: '$EntryName'."
    }

    $isDirectory = $path.EndsWith('/')
    $path = $path.TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($path)) { throw "ZIP entry has no path: '$EntryName'." }
    foreach ($part in $path.Split('/')) {
        if ($part -eq '' -or $part.EndsWith('.') -or $part.EndsWith(' ')) {
            throw "ZIP entry contains a Windows-ambiguous path component: '$EntryName'."
        }
        if ($part -match '[<>:"|?*]') { throw "ZIP entry contains an invalid Windows path component: '$EntryName'." }
        if ($part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
            throw "ZIP entry contains a reserved Windows name: '$EntryName'."
        }
    }
    return [pscustomobject]@{ Path = $path; IsDirectory = $isDirectory }
}

function Get-ArchiveInventory {
    param([Parameter(Mandatory = $true)][string]$ArchivePath)

    $zipPath = [IO.Path]::GetFullPath($ArchivePath)
    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) { throw "Package ZIP does not exist: $zipPath" }
    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $items = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $archive.Entries) {
            $normalized = Get-NormalizedArchivePath $entry.FullName
            $key = $normalized.Path
            if ($items.ContainsKey($key)) { throw "ZIP contains duplicate paths (case-insensitive): '$key'." }

            $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if ($unixType -ne 0 -and $unixType -ne 0x8000 -and $unixType -ne 0x4000) {
                throw "ZIP contains a symbolic link or special file: '$key'."
            }
            $dosAttributes = $entry.ExternalAttributes -band 0xFFFF
            if (($dosAttributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "ZIP contains a reparse-point entry: '$key'."
            }
            $isDirectory = $normalized.IsDirectory -or (($dosAttributes -band [int][IO.FileAttributes]::Directory) -ne 0)
            if ($isDirectory -and $entry.Length -ne 0) { throw "ZIP directory entry contains data: '$key'." }
            $items.Add($key, [pscustomobject]@{
                Path = $key
                IsDirectory = $isDirectory
                Entry = $entry
            })
        }

        foreach ($item in $items.Values) {
            $parts = $item.Path.Split('/')
            for ($i = 1; $i -lt $parts.Length; $i++) {
                $parent = $parts[0..($i - 1)] -join '/'
                if ($items.ContainsKey($parent) -and -not $items[$parent].IsDirectory) {
                    throw "ZIP path conflicts with a file entry: '$parent'."
                }
            }
        }
        return ,$items
    }
    finally { $archive.Dispose() }
}

function Get-SafeDestinationPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
    $destination = [IO.Path]::GetFullPath((Join-Path $rootFull ($RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))))
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $destination.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "ZIP entry resolves outside its extraction root: '$RelativePath'."
    }
    return $destination
}

function Assert-NoReparsePath {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)

    $target = [IO.Path]::GetFullPath($Path)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if ($target.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $target) {
            $rootItem = Get-Item -LiteralPath $target -Force
            if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Extraction root is a reparse point: '$target'."
            }
        }
        return
    }
    if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Path is outside extraction root: '$target'." }
    $cursor = $rootFull
    $relative = $target.Substring($prefix.Length)
    foreach ($part in $relative.Split([IO.Path]::DirectorySeparatorChar, [StringSplitOptions]::RemoveEmptyEntries)) {
        $cursor = Join-Path $cursor $part
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Extraction encountered a reparse point: '$cursor'."
            }
        }
    }
}

function Assert-DirectoryChainHasNoReparsePoints {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $cursor = [IO.Path]::GetPathRoot($fullPath)
    $relative = $fullPath.Substring($cursor.Length)
    foreach ($part in $relative.Split([IO.Path]::DirectorySeparatorChar, [StringSplitOptions]::RemoveEmptyEntries)) {
        $cursor = Join-Path $cursor $part
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to use a directory chain containing a reparse point: '$cursor'."
            }
        }
    }
}

function Expand-ValidatedArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)]$Inventory
    )

    [void](New-Item -ItemType Directory -Path $DestinationRoot -Force)
    $archive = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($ArchivePath))
    try {
        foreach ($entry in $archive.Entries) {
            $item = $Inventory[$(Get-NormalizedArchivePath $entry.FullName).Path]
            $destination = Get-SafeDestinationPath -Root $DestinationRoot -RelativePath $item.Path
            if ($item.IsDirectory) {
                Assert-NoReparsePath -Path $destination -Root $DestinationRoot
                [void](New-Item -ItemType Directory -Path $destination -Force)
                continue
            }

            $parent = Split-Path -Parent $destination
            Assert-NoReparsePath -Path $parent -Root $DestinationRoot
            [void](New-Item -ItemType Directory -Path $parent -Force)
            Assert-NoReparsePath -Path $destination -Root $DestinationRoot
            $inputStream = $entry.Open()
            try {
                $outputStream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $inputStream.CopyTo($outputStream) }
                finally { $outputStream.Dispose() }
            }
            finally { $inputStream.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-InventoriesMatch {
    param($UnsignedInventory, $SignedInventory)

    if ($UnsignedInventory.Count -ne $SignedInventory.Count) {
        throw "Signed ZIP inventory differs from the unsigned package (entry count $($SignedInventory.Count), expected $($UnsignedInventory.Count))."
    }
    foreach ($path in $UnsignedInventory.Keys) {
        if (-not $SignedInventory.ContainsKey($path)) { throw "Signed ZIP is missing package entry '$path'." }
        if ($UnsignedInventory[$path].IsDirectory -ne $SignedInventory[$path].IsDirectory) {
            throw "Signed ZIP changed the entry type for '$path'."
        }
    }
}

function Read-U16 {
    param([byte[]]$Bytes, [int]$Offset)
    return [BitConverter]::ToUInt16($Bytes, $Offset)
}

function Read-U32 {
    param([byte[]]$Bytes, [int]$Offset)
    return [BitConverter]::ToUInt32($Bytes, $Offset)
}

function Get-PeSignatureLayout {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes, [Parameter(Mandatory = $true)][string]$Label)

    if ($Bytes.Length -lt 0x40 -or $Bytes[0] -ne 0x4D -or $Bytes[1] -ne 0x5A) { throw "'$Label' is not a valid PE image (missing MZ header)." }
    $peOffset = [int](Read-U32 $Bytes 0x3C)
    if ($peOffset -lt 0x40 -or $peOffset -gt ($Bytes.Length - 24) -or
        $Bytes[$peOffset] -ne 0x50 -or $Bytes[$peOffset + 1] -ne 0x45 -or
        $Bytes[$peOffset + 2] -ne 0 -or $Bytes[$peOffset + 3] -ne 0) {
        throw "'$Label' is not a valid PE image (missing PE signature)."
    }
    $optionalSize = [int](Read-U16 $Bytes ($peOffset + 20))
    $optionalOffset = $peOffset + 24
    if ($optionalSize -lt 96 -or ($optionalOffset + $optionalSize) -gt $Bytes.Length) { throw "'$Label' has an invalid optional header." }
    $magic = Read-U16 $Bytes $optionalOffset
    if ($magic -eq 0x10B) { $directoryOffset = $optionalOffset + 96 }
    elseif ($magic -eq 0x20B) { $directoryOffset = $optionalOffset + 112 }
    else { throw "'$Label' uses an unsupported PE optional-header format." }
    if (($directoryOffset + (8 * 5)) -gt ($optionalOffset + $optionalSize)) { throw "'$Label' does not contain a security-directory entry." }

    $securityOffset = [long](Read-U32 $Bytes ($directoryOffset + 8 * 4))
    $securitySize = [long](Read-U32 $Bytes ($directoryOffset + 8 * 4 + 4))
    if (($securityOffset -eq 0) -ne ($securitySize -eq 0)) { throw "'$Label' has an inconsistent PE certificate-table directory." }
    if ($securitySize -gt 0 -and ($securityOffset -gt $Bytes.Length -or $securitySize -gt ($Bytes.Length - $securityOffset))) {
        throw "'$Label' has a certificate table outside the file."
    }
    if ($securitySize -gt 0 -and ($securityOffset % 8) -ne 0) {
        throw "'$Label' has an unaligned PE certificate table."
    }
    if ($securitySize -gt 0 -and ($securityOffset + $securitySize) -ne $Bytes.Length) {
        throw "'$Label' has bytes after its PE certificate table; refusing ambiguous signature data."
    }
    return [pscustomobject]@{
        ChecksumOffset = $optionalOffset + 64
        SecurityDirectoryOffset = $directoryOffset + 8 * 4
        CertificateOffset = $securityOffset
        CertificateSize = $securitySize
    }
}

function Assert-PePayloadEquivalent {
    param(
        [Parameter(Mandatory = $true)][string]$UnsignedPath,
        [Parameter(Mandatory = $true)][string]$SignedPath,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    [byte[]]$unsignedBytes = [IO.File]::ReadAllBytes($UnsignedPath)
    [byte[]]$signedBytes = [IO.File]::ReadAllBytes($SignedPath)
    $unsignedLayout = Get-PeSignatureLayout -Bytes $unsignedBytes -Label "$RelativePath (unsigned)"
    $signedLayout = Get-PeSignatureLayout -Bytes $signedBytes -Label "$RelativePath (signed)"
    if ($unsignedLayout.CertificateSize -ne 0) { throw "Unsigned package already has an Authenticode certificate table: '$RelativePath'." }
    if ($signedLayout.CertificateSize -le 0) { throw "Signed package has no PE certificate table: '$RelativePath'." }
    if ($unsignedLayout.CertificateOffset -ne 0) { throw "Unsigned PE has a nonempty security-directory offset: '$RelativePath'." }
    if ($unsignedLayout.ChecksumOffset -ne $signedLayout.ChecksumOffset -or
        $unsignedLayout.SecurityDirectoryOffset -ne $signedLayout.SecurityDirectoryOffset) {
        throw "Signing changed PE header layout: '$RelativePath'."
    }
    $alignmentPadding = $signedLayout.CertificateOffset - $unsignedBytes.Length
    if ($alignmentPadding -lt 0 -or $alignmentPadding -gt 7) {
        throw "Signing changed or removed unsigned PE payload bytes: '$RelativePath'."
    }
    for ($i = $unsignedBytes.Length; $i -lt $signedLayout.CertificateOffset; $i++) {
        if ($signedBytes[$i] -ne 0) { throw "Signing inserted nonzero data before the PE certificate table: '$RelativePath'." }
    }
    $unsignedPrefix = [byte[]]::new($unsignedBytes.Length)
    $signedPrefix = [byte[]]::new($unsignedBytes.Length)
    [Array]::Copy($unsignedBytes, 0, $unsignedPrefix, 0, $unsignedBytes.Length)
    [Array]::Copy($signedBytes, 0, $signedPrefix, 0, $unsignedBytes.Length)
    $checksumStart = [int]$unsignedLayout.ChecksumOffset
    $securityDirectoryStart = [int]$unsignedLayout.SecurityDirectoryOffset
    for ($offset = $checksumStart; $offset -lt ($checksumStart + 4); $offset++) {
        $unsignedPrefix[$offset] = 0
        $signedPrefix[$offset] = 0
    }
    for ($offset = $securityDirectoryStart; $offset -lt ($securityDirectoryStart + 8); $offset++) {
        $unsignedPrefix[$offset] = 0
        $signedPrefix[$offset] = 0
    }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $unsignedHash = ([BitConverter]::ToString($sha256.ComputeHash($unsignedPrefix))).Replace('-', '').ToLowerInvariant()
        $signedHash = ([BitConverter]::ToString($sha256.ComputeHash($signedPrefix))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha256.Dispose() }
    if ($unsignedHash -ne $signedHash) {
        throw "Signing modified PE content outside the checksum, security-directory entry, or appended certificate table: '$RelativePath'."
    }
}

function Get-PeCertificateTableBytes {
    param([Parameter(Mandatory = $true)][string]$Path)
    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    $layout = Get-PeSignatureLayout -Bytes $bytes -Label $Path
    if ($layout.CertificateSize -le 0) { throw "PE image has no certificate table: $Path" }
    $table = [byte[]]::new([int]$layout.CertificateSize)
    [Array]::Copy($bytes, [int]$layout.CertificateOffset, $table, 0, $table.Length)
    return ,$table
}

function Test-Rfc3161TimestampOid {
    param([Parameter(Mandatory = $true)][string]$Path)
    # SPC_RFC3161_OBJID (1.3.6.1.4.1.311.3.3.1) marks an RFC 3161 token in
    # Authenticode. signtool performs cryptographic and chain validation; this
    # checks the timestamp protocol marker.
    [byte[]]$table = Get-PeCertificateTableBytes -Path $Path
    [byte[]]$oid = @(0x06, 0x0A, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x03, 0x03, 0x01)
    for ($start = 0; $start -le ($table.Length - $oid.Length); $start++) {
        $matches = $true
        for ($j = 0; $j -lt $oid.Length; $j++) {
            if ($table[$start + $j] -ne $oid[$j]) { $matches = $false; break }
        }
        if ($matches) { return $true }
    }
    return $false
}

function Get-SignToolPath {
    $command = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $sdkRoot = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Windows Kits/10/bin'
    if (Test-Path -LiteralPath $sdkRoot -PathType Container) {
        $candidate = Get-ChildItem -LiteralPath $sdkRoot -Directory | Sort-Object Name -Descending | ForEach-Object {
            Join-Path $_.FullName 'x64/signtool.exe'
        } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if ($candidate) { return $candidate }
    }
    throw 'signtool.exe was not found on PATH or in the Windows SDK.'
}

function Test-AuthenticodeSignature {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedThumbprint,
        [Parameter(Mandatory = $true)][string]$SignToolPath
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid) {
        throw "Authenticode verification failed for '$Path': $($signature.Status) $($signature.StatusMessage)"
    }
    if (-not $signature.SignerCertificate) { throw "Authenticode signature has no signer certificate: '$Path'." }
    $actualThumbprint = ($signature.SignerCertificate.Thumbprint -replace '\s', '').ToUpperInvariant()
    if ($actualThumbprint -ne $ExpectedThumbprint) {
        throw "Unexpected signer for '$Path': expected $ExpectedThumbprint, got $actualThumbprint."
    }
    if (-not $signature.TimeStamperCertificate) { throw "Authenticode signature has no valid timestamp certificate: '$Path'." }
    if (-not (Test-Rfc3161TimestampOid -Path $Path)) { throw "Authenticode signature does not contain an RFC 3161 timestamp token: '$Path'." }

    $output = @(& $SignToolPath verify /pa /all /tw /v $Path 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "signtool verification failed for '$Path' (exit $exitCode): $($output -join [Environment]::NewLine)"
    }
    return [pscustomobject]@{
        SignerThumbprint = $actualThumbprint
        SignerSubject = $signature.SignerCertificate.Subject
        TimestampThumbprint = ($signature.TimeStamperCertificate.Thumbprint -replace '\s', '').ToUpperInvariant()
    }
}

function Assert-FileBytesEqual {
    param([string]$FirstPath, [string]$SecondPath, [string]$RelativePath)
    $first = Get-Item -LiteralPath $FirstPath
    $second = Get-Item -LiteralPath $SecondPath
    if ($first.Length -ne $second.Length -or (Get-FileSha256 $FirstPath) -ne (Get-FileSha256 $SecondPath)) {
        throw "Signing changed an unsigned package file: '$RelativePath'."
    }
}

function Get-WindowsProductVersion {
    param([Parameter(Mandatory = $true)][string]$ExecutablePath, [Parameter(Mandatory = $true)][string]$CoreLibraryPath)

    $executableInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($ExecutablePath)
    $coreInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($CoreLibraryPath)
    if ($executableInfo.ProductName -ne 'PocketGigaScan' -or $coreInfo.ProductName -ne 'PocketGigaScan') {
        throw "Windows package PE metadata must have ProductName 'PocketGigaScan' (EXE='$($executableInfo.ProductName)', core='$($coreInfo.ProductName)')."
    }
    if ([string]::IsNullOrWhiteSpace($executableInfo.ProductVersion) -or
        $executableInfo.ProductVersion -cne $coreInfo.ProductVersion) {
        throw "Windows package ProductVersion must be present and match exactly (EXE='$($executableInfo.ProductVersion)', core='$($coreInfo.ProductVersion)')."
    }
    return $executableInfo.ProductVersion
}

function Get-TreeInventory {
    param([Parameter(Mandatory = $true)][string]$Root)
    $rootFull = [IO.Path]::GetFullPath($Root)
    $result = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in Get-ChildItem -LiteralPath $rootFull -Force -Recurse) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Extracted package contains a reparse point: '$($entry.FullName)'." }
        $relative = [IO.Path]::GetRelativePath($rootFull, $entry.FullName).Replace('\', '/')
        if ($result.ContainsKey($relative)) { throw "Extracted package contains duplicate paths: '$relative'." }
        $result.Add($relative, [pscustomobject]@{ Path = $relative; IsDirectory = $entry.PSIsContainer; FullName = $entry.FullName })
    }
    return ,$result
}

function Assert-ExtractedTreesMatchArchives {
    param($ArchiveInventory, $TreeInventory, [string]$Label)
    $fileCount = @($ArchiveInventory.Values | Where-Object { -not $_.IsDirectory }).Count
    $treeFileCount = @($TreeInventory.Values | Where-Object { -not $_.IsDirectory }).Count
    if ($fileCount -ne $treeFileCount) { throw "$Label extraction has an unexpected file count." }
    foreach ($path in $ArchiveInventory.Keys) {
        if ($ArchiveInventory[$path].IsDirectory) { continue }
        if (-not $TreeInventory.ContainsKey($path)) { throw "$Label extraction is missing '$path'." }
    }
}

function Assert-SigningBaseline {
    param([Parameter(Mandatory = $true)][string]$PackageRoot, [Parameter(Mandatory = $true)]$ArchiveInventory)

    $baselinePath = Join-Path $PackageRoot 'signing-baseline.json'
    if (-not $ArchiveInventory.ContainsKey('signing-baseline.json') -or $ArchiveInventory['signing-baseline.json'].IsDirectory) {
        throw 'Unsigned package is missing signing-baseline.json.'
    }
    $baseline = Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json -AsHashtable
    if ($baseline.schemaVersion -ne 1 -or $baseline.product -ne 'PocketGigaScan') {
        throw 'signing-baseline.json has an unsupported schema or product.'
    }
    $expectedSignedFiles = @($script:PeSignatureTargets | Sort-Object)
    $actualSignedFiles = @($baseline.signedFiles | ForEach-Object { [string]$_ } | Sort-Object)
    if (($actualSignedFiles -join "`n") -ne ($expectedSignedFiles -join "`n")) {
        throw 'signing-baseline.json does not list exactly the required signed files.'
    }
    if (-not ($baseline.files -is [System.Collections.IEnumerable]) -or $baseline.files -is [string]) {
        throw 'signing-baseline.json has no valid files inventory.'
    }

    $baselineFiles = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $baseline.files) {
        $normalized = Get-NormalizedArchivePath ([string]$record.path)
        if ($normalized.IsDirectory) { throw "Signing baseline contains a directory path: '$($record.path)'." }
        $hash = ([string]$record.sha256).ToLowerInvariant()
        if ($hash -notmatch '^[0-9a-f]{64}$') { throw "Signing baseline has an invalid SHA-256 for '$($record.path)'." }
        if ($baselineFiles.ContainsKey($normalized.Path)) { throw "Signing baseline contains a duplicate path: '$($record.path)'." }
        $baselineFiles.Add($normalized.Path, $hash)
    }

    $packageFiles = @($ArchiveInventory.Values | Where-Object { -not $_.IsDirectory -and $_.Path -ne 'signing-baseline.json' })
    if ($baselineFiles.Count -ne $packageFiles.Count) {
        throw "Signing baseline file count $($baselineFiles.Count) does not match unsigned package file count $($packageFiles.Count)."
    }
    foreach ($packageFile in $packageFiles) {
        if (-not $baselineFiles.ContainsKey($packageFile.Path)) { throw "Signing baseline is missing unsigned package file '$($packageFile.Path)'." }
        $actualHash = Get-FileSha256 (Join-Path $PackageRoot ($packageFile.Path.Replace('/', [IO.Path]::DirectorySeparatorChar)))
        if ($actualHash -ne $baselineFiles[$packageFile.Path]) {
            throw "Unsigned package file does not match signing-baseline.json: '$($packageFile.Path)'."
        }
    }
    return Get-FileSha256 $baselinePath
}

function Write-PackageZip {
    param([Parameter(Mandatory = $true)][string]$SourceRoot, [Parameter(Mandatory = $true)][string]$ZipPath)

    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    $archive = [IO.Compression.ZipFile]::Open($ZipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $rootFull = [IO.Path]::GetFullPath($SourceRoot)
        foreach ($file in (Get-ChildItem -LiteralPath $rootFull -File -Recurse -Force | Sort-Object FullName)) {
            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to package a reparse point: '$($file.FullName)'." }
            $relative = [IO.Path]::GetRelativePath($rootFull, $file.FullName).Replace('\', '/')
            $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
            $inputStream = [IO.File]::OpenRead($file.FullName)
            try {
                $outputStream = $entry.Open()
                try { $inputStream.CopyTo($outputStream) }
                finally { $outputStream.Dispose() }
            }
            finally { $inputStream.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}

function Invoke-WindowsPackageFinalization {
    param(
        [string]$UnsignedPackageZip,
        [string]$SignedPackageZip,
        [string]$OutputDirectory,
        [string]$ExpectedSignerThumbprint
    )

    $unsignedPath = [IO.Path]::GetFullPath($UnsignedPackageZip)
    $signedPath = [IO.Path]::GetFullPath($SignedPackageZip)
    $outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
    $thumbprint = ($ExpectedSignerThumbprint -replace '\s', '').ToUpperInvariant()
    if ($thumbprint -notmatch '^[0-9A-F]{40}$') { throw 'Expected signer thumbprint must contain exactly 40 hexadecimal characters.' }
    if (-not (Test-Path -LiteralPath $unsignedPath -PathType Leaf)) { throw "Unsigned package ZIP does not exist: $unsignedPath" }
    if (-not (Test-Path -LiteralPath $signedPath -PathType Leaf)) { throw "SignPath-signed package ZIP does not exist: $signedPath" }
    Assert-DirectoryChainHasNoReparsePoints $outputRoot
    $finalZip = Join-Path $outputRoot $script:FinalPackageName
    $checksumPath = "$finalZip.sha256"
    $manifestOutput = Join-Path $outputRoot 'build-manifest.json'
    foreach ($outputPath in @($finalZip, $checksumPath, $manifestOutput)) {
        $outputFull = [IO.Path]::GetFullPath($outputPath)
        if ($outputFull.Equals($unsignedPath, [StringComparison]::OrdinalIgnoreCase) -or
            $outputFull.Equals($signedPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Output path overlaps an input ZIP: '$outputFull'."
        }
    }
    [void](New-Item -ItemType Directory -Path $outputRoot -Force)
    Assert-DirectoryChainHasNoReparsePoints $outputRoot

    $unsignedInventory = Get-ArchiveInventory $unsignedPath
    $signedInventory = Get-ArchiveInventory $signedPath
    Assert-InventoriesMatch $unsignedInventory $signedInventory
    foreach ($target in $script:PeSignatureTargets) {
        if (-not $unsignedInventory.ContainsKey($target) -or $unsignedInventory[$target].IsDirectory) {
            throw "Unsigned package is missing required PE signing target '$target'."
        }
    }
    if (-not $unsignedInventory.ContainsKey('build-manifest.json') -or $unsignedInventory['build-manifest.json'].IsDirectory) {
        throw "Unsigned package is missing build-manifest.json."
    }

    $tempRoot = Join-Path $outputRoot ('.signing-finalize-' + [guid]::NewGuid().ToString('N'))
    $unsignedRoot = Join-Path $tempRoot 'unsigned'
    $signedRoot = Join-Path $tempRoot 'signed'
    [void](New-Item -ItemType Directory -Path $tempRoot)
    try {
        Expand-ValidatedArchive -ArchivePath $unsignedPath -DestinationRoot $unsignedRoot -Inventory $unsignedInventory
        Expand-ValidatedArchive -ArchivePath $signedPath -DestinationRoot $signedRoot -Inventory $signedInventory
        $unsignedTree = Get-TreeInventory $unsignedRoot
        $signedTree = Get-TreeInventory $signedRoot
        Assert-ExtractedTreesMatchArchives $unsignedInventory $unsignedTree 'Unsigned'
        Assert-ExtractedTreesMatchArchives $signedInventory $signedTree 'Signed'
        $signingBaselineHash = Assert-SigningBaseline -PackageRoot $unsignedRoot -ArchiveInventory $unsignedInventory
        $productVersion = Get-WindowsProductVersion `
            -ExecutablePath $unsignedTree['PocketGigaScan.exe'].FullName `
            -CoreLibraryPath $unsignedTree['lumia_gigascan_core.dll'].FullName

        foreach ($path in $unsignedInventory.Keys) {
            if ($unsignedInventory[$path].IsDirectory) { continue }
            if ($path -in $script:PeSignatureTargets) {
                Assert-PePayloadEquivalent -UnsignedPath $unsignedTree[$path].FullName -SignedPath $signedTree[$path].FullName -RelativePath $path
            }
            else {
                Assert-FileBytesEqual -FirstPath $unsignedTree[$path].FullName -SecondPath $signedTree[$path].FullName -RelativePath $path
            }
        }

        $signTool = Get-SignToolPath
        $signatures = [ordered]@{}
        foreach ($target in $script:PeSignatureTargets) {
            $signedFile = $signedTree[$target].FullName
            $signatures[$target] = Test-AuthenticodeSignature -Path $signedFile -ExpectedThumbprint $thumbprint -SignToolPath $signTool
        }

        $manifestPath = Join-Path $signedRoot 'build-manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
        if (-not $manifest) { throw 'Unsigned build-manifest.json is empty or invalid JSON.' }
        $manifest.coreLibrarySha256 = Get-FileSha256 (Join-Path $signedRoot 'lumia_gigascan_core.dll')
        $manifest.windowsProductVersion = $productVersion
        $manifest.authenticodeSigning = [ordered]@{
            signingBaselineSha256 = $signingBaselineHash
            productVersion = $productVersion
            signerThumbprint = $thumbprint
            timestampProtocol = 'RFC3161'
            verifiedBy = 'Windows Authenticode and SignTool'
            signedFiles = @($script:PeSignatureTargets)
            timestampSignerThumbprints = @($script:PeSignatureTargets | ForEach-Object { $signatures[$_].TimestampThumbprint } | Select-Object -Unique)
        }
        $manifestJson = $manifest | ConvertTo-Json -Depth 30
        [IO.File]::WriteAllText($manifestPath, $manifestJson + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        Remove-Item -LiteralPath (Join-Path $signedRoot 'signing-baseline.json') -Force

        $stagedZip = Join-Path $tempRoot $script:FinalPackageName
        Write-PackageZip -SourceRoot $signedRoot -ZipPath $stagedZip

        $finalInventory = Get-ArchiveInventory $stagedZip
        $finalTree = Get-TreeInventory $signedRoot
        Assert-ExtractedTreesMatchArchives $finalInventory $finalTree 'Final'
        foreach ($path in $finalInventory.Keys) {
            if ($finalInventory[$path].IsDirectory) { continue }
            $hashFromZip = $null
            $archive = [IO.Compression.ZipFile]::OpenRead($stagedZip)
            try {
                $entry = $archive.GetEntry($path)
                $stream = $entry.Open()
                try {
                    $sha = [Security.Cryptography.SHA256]::Create()
                    try { $hashFromZip = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
                    finally { $sha.Dispose() }
                }
                finally { $stream.Dispose() }
            }
            finally { $archive.Dispose() }
            if ($hashFromZip -ne (Get-FileSha256 $finalTree[$path].FullName)) { throw "Final ZIP content differs from package tree at '$path'." }
        }

        $archiveHash = Get-FileSha256 $stagedZip
        foreach ($outputPath in @($finalZip, $checksumPath, $manifestOutput)) {
            Assert-DirectoryChainHasNoReparsePoints (Split-Path -Parent $outputPath)
            if (Test-Path -LiteralPath $outputPath) {
                $existing = Get-Item -LiteralPath $outputPath -Force
                if (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $existing.PSIsContainer) {
                    throw "Refusing to replace a reparse point or directory: '$outputPath'."
                }
            }
        }
        Copy-Item -LiteralPath $stagedZip -Destination $finalZip -Force
        if ((Get-FileSha256 $finalZip) -ne $archiveHash) { throw 'Copied final ZIP failed its SHA-256 verification.' }
        [IO.File]::WriteAllText($checksumPath, "$archiveHash  $script:FinalPackageName`n", [Text.Encoding]::ASCII)
        Copy-Item -LiteralPath $manifestPath -Destination $manifestOutput -Force
        Write-Host "Final package: $finalZip"
        Write-Host "SHA-256: $archiveHash"
        Write-Host "Manifest: $manifestOutput"
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            $reparse = Get-ChildItem -LiteralPath $tempRoot -Force -Recurse | Where-Object {
                ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            } | Select-Object -First 1
            if ($reparse) { throw "Refusing to remove temporary tree containing a reparse point: '$($reparse.FullName)'." }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-WindowsPackageFinalization -UnsignedPackageZip $UnsignedPackageZip -SignedPackageZip $SignedPackageZip -OutputDirectory $OutputDirectory -ExpectedSignerThumbprint $ExpectedSignerThumbprint
}
