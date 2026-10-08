[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$repo = Split-Path $PSScriptRoot -Parent
$finalizerPath = Join-Path $PSScriptRoot 'complete-dwarf-stitch-windows-signing.ps1'
$tokens = $null
$parseErrors = $null
$finalizerAst = [System.Management.Automation.Language.Parser]::ParseFile($finalizerPath, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) "Finalizer parse errors: $($parseErrors -join '; ')"
$script:PeSignatureTargets = @('PocketGigaScan.exe', 'lumia_gigascan_core.dll')
$script:FinalPackageName = 'PocketGigaScan-Windows-x64.zip'
foreach ($functionName in @(
    'Get-NormalizedArchivePath', 'Get-ArchiveInventory', 'Get-SafeDestinationPath', 'Assert-NoReparsePath',
    'Assert-DirectoryChainHasNoReparsePoints', 'Expand-ValidatedArchive', 'Get-FileSha256',
    'Assert-InventoriesMatch', 'Read-U16', 'Read-U32', 'Get-PeSignatureLayout', 'Assert-PePayloadEquivalent',
    'Get-PeCertificateTableBytes', 'Test-Rfc3161TimestampOid', 'Get-SignToolPath',
    'Test-AuthenticodeSignature', 'Assert-FileBytesEqual', 'Get-WindowsProductVersion', 'Get-TreeInventory',
    'Assert-ExtractedTreesMatchArchives', 'Assert-SigningBaseline', 'Write-PackageZip', 'Invoke-WindowsPackageFinalization'
)) {
    $functionAst = $finalizerAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    Assert-True ($null -ne $functionAst) "Finalizer is missing $functionName."
    Invoke-Expression $functionAst.Extent.Text
}

$unsafeEntries = @('../outside', 'folder/../../outside', 'C:/outside', '\\server\share\file')
foreach ($entry in $unsafeEntries) {
    $rejected = $false
    try { Get-NormalizedArchivePath $entry | Out-Null } catch { $rejected = $true }
    Assert-True $rejected "Archive path validation accepted '$entry'."
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('pocket-signing-test-' + [guid]::NewGuid().ToString('N'))
$tempRoot = [IO.Path]::GetFullPath($tempRoot)
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
Assert-True ($tempRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetFileName($tempRoot) -match '^pocket-signing-test-[0-9a-f]{32}$') 'Refusing unsafe signing test fixture path.'
$null = New-Item -ItemType Directory -Path $tempRoot
try {
    $unsignedPath = Join-Path $tempRoot 'unsigned.dll'
    $signedPath = Join-Path $tempRoot 'signed.dll'
    $tamperedPath = Join-Path $tempRoot 'tampered.dll'
    $paddingPath = Join-Path $tempRoot 'padding.dll'
    $unalignedPath = Join-Path $tempRoot 'unaligned.dll'
    $signToolPath = Join-Path $tempRoot 'verify.cmd'

    # A minimal PE32+ header with an empty certificate directory. The test
    # exercises byte-preservation rules only; no fake signature is treated as trusted.
    [byte[]]$unsigned = [byte[]]::new(513)
    $unsigned[0] = 0x4D
    $unsigned[1] = 0x5A
    [Array]::Copy([BitConverter]::GetBytes([uint32]64), 0, $unsigned, 0x3C, 4)
    $unsigned[64] = 0x50
    $unsigned[65] = 0x45
    [Array]::Copy([BitConverter]::GetBytes([uint16]240), 0, $unsigned, 84, 2)
    [Array]::Copy([BitConverter]::GetBytes([uint16]0x20B), 0, $unsigned, 88, 2)
    $unsigned[200] = 0x5A
    [IO.File]::WriteAllBytes($unsignedPath, $unsigned)

    $certificateOffset = 520
    $certificateSize = 16
    [byte[]]$signed = [byte[]]::new($certificateOffset + $certificateSize)
    [Array]::Copy($unsigned, 0, $signed, 0, $unsigned.Length)
    [Array]::Copy([BitConverter]::GetBytes([uint32]0x12345678), 0, $signed, 152, 4)
    $securityDirectoryOffset = 88 + 112 + (8 * 4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$certificateOffset), 0, $signed, $securityDirectoryOffset, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$certificateSize), 0, $signed, $securityDirectoryOffset + 4, 4)
    [byte[]]$timestampMarker = @(0x06, 0x0A, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x03, 0x03, 0x01)
    [Array]::Copy($timestampMarker, 0, $signed, $certificateOffset, $timestampMarker.Length)
    [IO.File]::WriteAllBytes($signedPath, $signed)
    Assert-PePayloadEquivalent -UnsignedPath $unsignedPath -SignedPath $signedPath -RelativePath 'fixture.dll'

    [byte[]]$tampered = $signed.Clone()
    $tampered[200] = $tampered[200] -bxor 1
    [IO.File]::WriteAllBytes($tamperedPath, $tampered)
    $payloadMutationRejected = $false
    try { Assert-PePayloadEquivalent -UnsignedPath $unsignedPath -SignedPath $tamperedPath -RelativePath 'fixture.dll' } catch { $payloadMutationRejected = $true }
    Assert-True $payloadMutationRejected 'PE comparison accepted a payload byte changed outside the Authenticode fields.'

    [byte[]]$badPadding = $signed.Clone()
    $badPadding[515] = 0x7F
    [IO.File]::WriteAllBytes($paddingPath, $badPadding)
    $paddingMutationRejected = $false
    try { Assert-PePayloadEquivalent -UnsignedPath $unsignedPath -SignedPath $paddingPath -RelativePath 'fixture.dll' } catch { $paddingMutationRejected = $true }
    Assert-True $paddingMutationRejected 'PE comparison accepted nonzero alignment padding before the certificate table.'

    [byte[]]$unaligned = $signed.Clone()
    [Array]::Copy([BitConverter]::GetBytes([uint32]521), 0, $unaligned, $securityDirectoryOffset, 4)
    [IO.File]::WriteAllBytes($unalignedPath, $unaligned)
    $unalignedRejected = $false
    try { Get-PeSignatureLayout -Bytes $unaligned -Label 'unaligned fixture' | Out-Null } catch { $unalignedRejected = $true }
    Assert-True $unalignedRejected 'PE layout validation accepted an unaligned certificate table.'

    Set-Content -LiteralPath $signToolPath -Value '@exit /b 0' -Encoding ascii
    $script:MockSignature = [pscustomobject]@{
        Status = [Management.Automation.SignatureStatus]::Valid
        StatusMessage = 'Mocked valid result for contract testing'
        SignerCertificate = [pscustomobject]@{ Thumbprint = ('A' * 40); Subject = 'CN=PocketGigaScan test signer' }
        TimeStamperCertificate = [pscustomobject]@{ Thumbprint = ('B' * 40) }
    }
    function Get-AuthenticodeSignature {
        param([string]$LiteralPath)
        return $script:MockSignature
    }

    $mockedValid = Test-AuthenticodeSignature -Path $signedPath -ExpectedThumbprint ('A' * 40) -SignToolPath $signToolPath
    Assert-True ($mockedValid.SignerThumbprint -eq ('A' * 40)) 'Valid mocked Authenticode result was not accepted.'

    $script:MockSignature.Status = [Management.Automation.SignatureStatus]::NotSigned
    $unsignedRejected = $false
    try { Test-AuthenticodeSignature -Path $signedPath -ExpectedThumbprint ('A' * 40) -SignToolPath $signToolPath | Out-Null } catch { $unsignedRejected = $true }
    Assert-True $unsignedRejected 'Signature verification accepted an unsigned file.'

    $script:MockSignature.Status = [Management.Automation.SignatureStatus]::Valid
    $wrongSignerRejected = $false
    try { Test-AuthenticodeSignature -Path $signedPath -ExpectedThumbprint ('C' * 40) -SignToolPath $signToolPath | Out-Null } catch { $wrongSignerRejected = $true }
    Assert-True $wrongSignerRejected 'Signature verification accepted an unexpected signer thumbprint.'

    $script:MockSignature.SignerCertificate.Thumbprint = ('A' * 40)
    $script:MockSignature.TimeStamperCertificate = $null
    $missingTimestampRejected = $false
    try { Test-AuthenticodeSignature -Path $signedPath -ExpectedThumbprint ('A' * 40) -SignToolPath $signToolPath | Out-Null } catch { $missingTimestampRejected = $true }
    Assert-True $missingTimestampRejected 'Signature verification accepted a missing timestamp certificate.'

    $script:MockSignature.TimeStamperCertificate = [pscustomobject]@{ Thumbprint = ('B' * 40) }
    Set-Content -LiteralPath $signToolPath -Value '@exit /b 1' -Encoding ascii
    $signtoolFailureRejected = $false
    try { Test-AuthenticodeSignature -Path $signedPath -ExpectedThumbprint ('A' * 40) -SignToolPath $signToolPath | Out-Null } catch { $signtoolFailureRejected = $true }
    Assert-True $signtoolFailureRejected 'Signature verification accepted a failing SignTool chain/timestamp result.'

    # Exercise safe extraction, the immutable baseline, PE comparison, manifest
    # regeneration, and final ZIP validation together. Only trust and Windows
    # version-resource reading are mocked; archive and hash checks remain real.
    function New-TestPeImage([switch]$Signed) {
        [byte[]]$bytes = [byte[]]::new($(if ($Signed) { 552 } else { 513 }))
        $bytes[0] = 0x4D
        $bytes[1] = 0x5A
        [Array]::Copy([BitConverter]::GetBytes([uint32]64), 0, $bytes, 0x3C, 4)
        $bytes[64] = 0x50
        $bytes[65] = 0x45
        [Array]::Copy([BitConverter]::GetBytes([uint16]240), 0, $bytes, 84, 2)
        [Array]::Copy([BitConverter]::GetBytes([uint16]0x20B), 0, $bytes, 88, 2)
        $bytes[200] = 0x5A
        if ($Signed) {
            $certificateOffset = 520
            $certificateSize = 32
            [Array]::Copy([BitConverter]::GetBytes([uint32]0x12345678), 0, $bytes, 152, 4)
            $securityDirectoryOffset = 88 + 112 + (8 * 4)
            [Array]::Copy([BitConverter]::GetBytes([uint32]$certificateOffset), 0, $bytes, $securityDirectoryOffset, 4)
            [Array]::Copy([BitConverter]::GetBytes([uint32]$certificateSize), 0, $bytes, $securityDirectoryOffset + 4, 4)
            [Array]::Copy([BitConverter]::GetBytes([uint32]$certificateSize), 0, $bytes, $certificateOffset, 4)
            [Array]::Copy([BitConverter]::GetBytes([uint16]0x0200), 0, $bytes, $certificateOffset + 4, 2)
            [Array]::Copy([BitConverter]::GetBytes([uint16]0x0002), 0, $bytes, $certificateOffset + 6, 2)
            [byte[]]$timestampMarker = @(0x06, 0x0A, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x03, 0x03, 0x01)
            [Array]::Copy($timestampMarker, 0, $bytes, $certificateOffset + 8, $timestampMarker.Length)
        }
        return ,$bytes
    }

    $unsignedTree = Join-Path $tempRoot 'unsigned-package'
    $signedTree = Join-Path $tempRoot 'signed-package'
    $finalOutput = Join-Path $tempRoot 'final-output'
    $unsignedZip = Join-Path $tempRoot 'unsigned-package.zip'
    $signedZip = Join-Path $tempRoot 'signed-package.zip'
    $badSignedZip = Join-Path $tempRoot 'signed-package-with-traversal.zip'
    $null = New-Item -ItemType Directory -Path $unsignedTree, $signedTree
    [IO.File]::WriteAllBytes((Join-Path $unsignedTree 'PocketGigaScan.exe'), (New-TestPeImage))
    [IO.File]::WriteAllBytes((Join-Path $unsignedTree 'lumia_gigascan_core.dll'), (New-TestPeImage))
    [IO.File]::WriteAllText((Join-Path $unsignedTree 'licenses-vendor.txt'), 'immutable third-party file')
    [IO.File]::WriteAllText((Join-Path $unsignedTree 'build-manifest.json'), '{"product":"PocketGigaScan","coreLibrarySha256":"stale"}')
    $baselineFiles = @(Get-ChildItem -LiteralPath $unsignedTree -File -Recurse | ForEach-Object {
        [pscustomobject]@{
            path = [IO.Path]::GetRelativePath($unsignedTree, $_.FullName).Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    } | Sort-Object path)
    $baseline = [ordered]@{
        schemaVersion = 1
        product = 'PocketGigaScan'
        signedFiles = @('PocketGigaScan.exe', 'lumia_gigascan_core.dll')
        files = $baselineFiles
    }
    [IO.File]::WriteAllText((Join-Path $unsignedTree 'signing-baseline.json'), (($baseline | ConvertTo-Json -Depth 5) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

    foreach ($name in @('PocketGigaScan.exe', 'lumia_gigascan_core.dll')) {
        [IO.File]::WriteAllBytes((Join-Path $signedTree $name), (New-TestPeImage -Signed))
    }
    foreach ($name in @('licenses-vendor.txt', 'build-manifest.json', 'signing-baseline.json')) {
        Copy-Item -LiteralPath (Join-Path $unsignedTree $name) -Destination (Join-Path $signedTree $name)
    }
    [IO.Compression.ZipFile]::CreateFromDirectory($unsignedTree, $unsignedZip)
    [IO.Compression.ZipFile]::CreateFromDirectory($signedTree, $signedZip)

    function Get-SignToolPath { return 'mocked-sign-tool.exe' }
    function Get-WindowsProductVersion {
        param([string]$ExecutablePath, [string]$CoreLibraryPath)
        return '1.2.3+4'
    }
    function Test-AuthenticodeSignature {
        param([string]$Path, [string]$ExpectedThumbprint, [string]$SignToolPath)
        return [pscustomobject]@{
            SignerThumbprint = $ExpectedThumbprint
            SignerSubject = 'CN=Mock PocketGigaScan signer'
            TimestampThumbprint = ('B' * 40)
        }
    }
    Invoke-WindowsPackageFinalization `
        -UnsignedPackageZip $unsignedZip `
        -SignedPackageZip $signedZip `
        -OutputDirectory $finalOutput `
        -ExpectedSignerThumbprint ('A' * 40)

    $finalZip = Join-Path $finalOutput $script:FinalPackageName
    Assert-True (Test-Path -LiteralPath $finalZip -PathType Leaf) 'Successful mocked finalization did not write its ZIP.'
    $finalInventory = Get-ArchiveInventory $finalZip
    Assert-True (-not $finalInventory.ContainsKey('signing-baseline.json')) 'Final distributable retained signing-baseline.json.'
    foreach ($requiredPath in @('PocketGigaScan.exe', 'lumia_gigascan_core.dll', 'build-manifest.json', 'licenses-vendor.txt')) {
        Assert-True ($finalInventory.ContainsKey($requiredPath)) "Final ZIP is missing '$requiredPath'."
    }
    $finalArchive = [IO.Compression.ZipFile]::OpenRead($finalZip)
    try {
        $manifestEntry = $finalArchive.GetEntry('build-manifest.json')
        $manifestStream = $manifestEntry.Open()
        try {
            $reader = [IO.StreamReader]::new($manifestStream)
            try { $finalManifest = $reader.ReadToEnd() | ConvertFrom-Json }
            finally { $reader.Dispose() }
        }
        finally { $manifestStream.Dispose() }
        $coreEntry = $finalArchive.GetEntry('lumia_gigascan_core.dll')
        $coreStream = $coreEntry.Open()
        try {
            $sha256 = [Security.Cryptography.SHA256]::Create()
            try { $finalCoreHash = ([BitConverter]::ToString($sha256.ComputeHash($coreStream))).Replace('-', '').ToLowerInvariant() }
            finally { $sha256.Dispose() }
        }
        finally { $coreStream.Dispose() }
    }
    finally { $finalArchive.Dispose() }
    Assert-True ($finalManifest.coreLibrarySha256 -eq $finalCoreHash) 'Final manifest core hash does not match the DLL stored in the final ZIP.'
    Assert-True ($finalManifest.windowsProductVersion -eq '1.2.3+4') 'Final manifest is missing the verified Windows product version.'
    Assert-True ($finalManifest.authenticodeSigning.signerThumbprint -eq ('A' * 40)) 'Final manifest is missing the expected signer thumbprint.'
    $checksum = (Get-Content -LiteralPath "$finalZip.sha256" -Raw).Trim()
    $archiveHash = (Get-FileHash -LiteralPath $finalZip -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ($checksum -eq "$archiveHash  $script:FinalPackageName") 'Final checksum does not match the final ZIP.'

    $sameArchiveOutput = Join-Path $tempRoot 'same-archive-output'
    $sameArchiveRejected = $false
    try {
        Invoke-WindowsPackageFinalization -UnsignedPackageZip $unsignedZip -SignedPackageZip $unsignedZip -OutputDirectory $sameArchiveOutput -ExpectedSignerThumbprint ('A' * 40)
    } catch { $sameArchiveRejected = $true }
    Assert-True $sameArchiveRejected 'Finalization accepted the unsigned archive as its signed input.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $sameArchiveOutput $script:FinalPackageName))) 'Rejected unsigned archive left a final package behind.'

    Copy-Item -LiteralPath $signedZip -Destination $badSignedZip
    $badArchive = [IO.Compression.ZipFile]::Open($badSignedZip, [IO.Compression.ZipArchiveMode]::Update)
    try { $null = $badArchive.CreateEntry('../escape.txt') }
    finally { $badArchive.Dispose() }
    $traversalOutput = Join-Path $tempRoot 'traversal-output'
    $traversalRejected = $false
    try {
        Invoke-WindowsPackageFinalization -UnsignedPackageZip $unsignedZip -SignedPackageZip $badSignedZip -OutputDirectory $traversalOutput -ExpectedSignerThumbprint ('A' * 40)
    } catch { $traversalRejected = $true }
    Assert-True $traversalRejected 'Finalization accepted a ZIP containing a traversal entry.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $traversalOutput $script:FinalPackageName))) 'Rejected traversal archive left a final package behind.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Host 'Windows signing finalizer archive-path, PE preservation, and mocked Authenticode contract checks passed.'
