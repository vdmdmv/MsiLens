param(
    [string] $Path,
    [switch] $NoPropertyTable,
    [switch] $NoFileTable,
    [switch] $NoBinaryTable,
    [string] $ExternalCabinetName = 'external.cab',
    [string] $ExternalPayloadFileName = 'CABPAY~1.DLL|CabPayload.dll',
    [int] $ExternalPayloadAttributes = 0,
    [string] $ExternalCabinetEntryName = 'CABPAY~1.DLL',
    [string] $EmbeddedCabinetEntryName = 'EMBED~1.EXE',
    [switch] $AddSecondEmbeddedPayload,
    [switch] $NoEmbeddedCabinetStream,
    [switch] $EmbeddedCabinetStreamHasWrongPayload,
    [string] $ExternalMediaDiskPrompt = '',
    [string] $ExternalMediaVolumeLabel = '',
    [string] $ExternalMediaSource = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensFixture-{0}.msi" -f ([guid]::NewGuid().ToString('N')))
}

$fullPath = [System.IO.Path]::GetFullPath($Path)
$directory = Split-Path -Parent $fullPath
if (-not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory | Out-Null
}
if (Test-Path -LiteralPath $fullPath) {
    Remove-Item -LiteralPath $fullPath -Force
}

$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $installer.OpenDatabase($fullPath, 3)

function Invoke-FixtureSql {
    param(
        [object] $Database,
        [string] $Sql,
        [object] $Record = $null
    )

    try {
        $view = $Database.OpenView($Sql)
    } catch {
        $lastError = $installer.LastErrorRecord()
        $detail = ''
        if ($null -ne $lastError) {
            $parts = @()
            $fieldCount = $lastError.FieldCount()
            for ($i = 1; $i -le $fieldCount; $i++) {
                $parts += $lastError.StringData($i)
            }
            $detail = $parts -join ' '
        }
        throw ("Failed to open fixture SQL view: {0} {1}" -f $Sql, $detail)
    }
    try {
        if ($null -eq $Record) {
            $null = $view.Execute()
        } else {
            $null = $view.Execute($Record)
        }
    } finally {
        $null = $view.Close()
    }
}

if (-not $NoPropertyTable) {
    Invoke-FixtureSql $database "CREATE TABLE ``Property`` (``Property`` CHAR(72) NOT NULL, ``Value`` LONGCHAR LOCALIZABLE PRIMARY KEY ``Property``)"
}
if (-not $NoFileTable) {
    Invoke-FixtureSql $database "CREATE TABLE ``File`` (``File`` CHAR(72) NOT NULL, ``Component_`` CHAR(72) NOT NULL, ``FileName`` CHAR(255) NOT NULL LOCALIZABLE, ``FileSize`` LONG NOT NULL, ``Version`` CHAR(72), ``Language`` CHAR(20), ``Attributes`` SHORT, ``Sequence`` SHORT NOT NULL PRIMARY KEY ``File``)"
    Invoke-FixtureSql $database "CREATE TABLE ``Directory`` (``Directory`` CHAR(72) NOT NULL, ``Directory_Parent`` CHAR(72), ``DefaultDir`` CHAR(255) LOCALIZABLE PRIMARY KEY ``Directory``)"
    Invoke-FixtureSql $database "CREATE TABLE ``Component`` (``Component`` CHAR(72) NOT NULL, ``ComponentId`` CHAR(38), ``Directory_`` CHAR(72) NOT NULL, ``Attributes`` SHORT NOT NULL, ``Condition`` CHAR(255), ``KeyPath`` CHAR(72) PRIMARY KEY ``Component``)"
    Invoke-FixtureSql $database "CREATE TABLE ``Media`` (``DiskId`` SHORT NOT NULL, ``LastSequence`` LONG NOT NULL, ``DiskPrompt`` CHAR(64) LOCALIZABLE, ``Cabinet`` CHAR(255), ``VolumeLabel`` CHAR(32), ``Source`` CHAR(72) PRIMARY KEY ``DiskId``)"
}
if (-not $NoBinaryTable) {
    Invoke-FixtureSql $database "CREATE TABLE ``Binary`` (``Name`` CHAR(72) NOT NULL, ``Data`` OBJECT LOCALIZABLE PRIMARY KEY ``Name``)"
}

function New-FixtureBytes {
    param([int] $Length)

    $bytes = New-Object byte[] $Length
    for ($i = 0; $i -lt $Length; $i++) {
        $bytes[$i] = [byte](65 + ($i % 26))
    }
    $bytes
}

function New-FixtureCabinet {
    param(
        [string] $SourcePath,
        [string] $CabinetPath,
        [string] $EntryName = $null
    )

    $makecab = Get-Command makecab.exe -ErrorAction SilentlyContinue
    if ($null -eq $makecab) {
        throw 'makecab.exe is required for extraction fixture generation.'
    }
    if (Test-Path -LiteralPath $CabinetPath) {
        Remove-Item -LiteralPath $CabinetPath -Force
    }
    $cabinetSourcePath = $SourcePath
    $cabinetSourceDirectory = $null
    if (-not [string]::IsNullOrWhiteSpace($EntryName)) {
        $cabinetSourceDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensCabSource-{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $cabinetSourceDirectory | Out-Null
        $cabinetSourcePath = Join-Path $cabinetSourceDirectory $EntryName
        Copy-Item -LiteralPath $SourcePath -Destination $cabinetSourcePath -Force
    }
    try {
        $output = & $makecab.Source /D CompressionType=MSZIP $cabinetSourcePath $CabinetPath 2>&1
    } finally {
        if ($null -ne $cabinetSourceDirectory -and (Test-Path -LiteralPath $cabinetSourceDirectory)) {
            Remove-Item -LiteralPath $cabinetSourceDirectory -Recurse -Force
        }
    }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $CabinetPath)) {
        throw ("makecab.exe failed: {0}" -f ($output | Out-String).Trim())
    }
}

function New-FixtureCabinetSet {
    param(
        [object[]] $Entries,
        [string] $CabinetPath
    )

    $makecab = Get-Command makecab.exe -ErrorAction SilentlyContinue
    if ($null -eq $makecab) {
        throw 'makecab.exe is required for extraction fixture generation.'
    }
    if (Test-Path -LiteralPath $CabinetPath) {
        Remove-Item -LiteralPath $CabinetPath -Force
    }

    $cabinetDirectory = Split-Path -Parent $CabinetPath
    $cabinetName = Split-Path -Leaf $CabinetPath
    $ddfPath = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensCabinet-{0}.ddf" -f ([guid]::NewGuid().ToString('N')))
    $makecabWork = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensMakeCab-{0}" -f ([guid]::NewGuid().ToString('N')))
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('.OPTION EXPLICIT')
    [void]$lines.Add((".Set CabinetNameTemplate={0}" -f $cabinetName))
    [void]$lines.Add((".Set DiskDirectoryTemplate={0}" -f $cabinetDirectory))
    [void]$lines.Add('.Set CompressionType=MSZIP')
    [void]$lines.Add('.Set Cabinet=on')
    [void]$lines.Add('.Set Compress=on')
    [void]$lines.Add('.Set MaxDiskSize=0')
    foreach ($entry in $Entries) {
        [void]$lines.Add(('"{0}" "{1}"' -f $entry.SourcePath, $entry.EntryName))
    }

    $pushedLocation = $false
    try {
        [void](New-Item -ItemType Directory -Path $makecabWork -Force)
        Set-Content -LiteralPath $ddfPath -Value ([string[]]$lines.ToArray([string])) -Encoding ASCII
        Push-Location -LiteralPath $makecabWork
        $pushedLocation = $true
        $output = & $makecab.Source /F $ddfPath 2>&1
    } finally {
        if ($pushedLocation) {
            Pop-Location
        }
        Remove-Item -LiteralPath $ddfPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $makecabWork -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $CabinetPath)) {
        throw ("makecab.exe failed: {0}" -f ($output | Out-String).Trim())
    }
}

if (-not $NoPropertyTable) {
    $properties = @(
        @('ProductName', 'MsiLens Test Product'),
        @('ProductVersion', '1.0.0'),
        @('ProductCode', '{11111111-1111-1111-1111-111111111111}'),
        @('Manufacturer', 'MsiLens Tests')
    )

    foreach ($property in $properties) {
        $record = $installer.CreateRecord(2)
        $record.StringData(1) = $property[0]
        $record.StringData(2) = $property[1]
        Invoke-FixtureSql $database "INSERT INTO ``Property`` (``Property``, ``Value``) VALUES (?, ?)" $record
    }
}

if (-not $NoFileTable) {
    $installDirectory = Join-Path $directory 'APPDIR'
    if (-not (Test-Path -LiteralPath $installDirectory)) {
        New-Item -ItemType Directory -Path $installDirectory | Out-Null
    }
    [System.IO.File]::WriteAllBytes((Join-Path $installDirectory 'TESTFI~1.TXT'), (New-FixtureBytes 12))
    [System.IO.File]::WriteAllBytes((Join-Path $installDirectory 'SHORTO~1.DLL'), (New-FixtureBytes 34))
    [System.IO.File]::WriteAllBytes((Join-Path $installDirectory 'CABPAY~1.DLL'), (New-FixtureBytes 20))
    [System.IO.File]::WriteAllBytes((Join-Path $installDirectory 'SAFECO~1.TXT'), (New-FixtureBytes 1))

    $cabSource = Join-Path $directory 'CABPAY~1.DLL'
    $externalCabinet = Join-Path $directory 'external.cab'
    [System.IO.File]::WriteAllBytes($cabSource, (New-FixtureBytes 20))
    New-FixtureCabinet -SourcePath $cabSource -CabinetPath $externalCabinet -EntryName $ExternalCabinetEntryName

    $embeddedSource = Join-Path $directory 'EMBED~1.EXE'
    $embeddedCabinet = Join-Path $directory 'embedded.cab'
    [System.IO.File]::WriteAllBytes($embeddedSource, (New-FixtureBytes 16))
    if ($AddSecondEmbeddedPayload) {
        $secondEmbeddedSource = Join-Path $directory 'EMBED~2.EXE'
        [System.IO.File]::WriteAllBytes($secondEmbeddedSource, (New-FixtureBytes 18))
        New-FixtureCabinetSet -CabinetPath $embeddedCabinet -Entries @(
            [pscustomobject]@{ SourcePath = $embeddedSource; EntryName = $EmbeddedCabinetEntryName },
            [pscustomobject]@{ SourcePath = $secondEmbeddedSource; EntryName = 'EMBED~2.EXE' }
        )
    } else {
        New-FixtureCabinet -SourcePath $embeddedSource -CabinetPath $embeddedCabinet -EntryName $EmbeddedCabinetEntryName
    }
    $embeddedStreamCabinet = $embeddedCabinet
    if ($EmbeddedCabinetStreamHasWrongPayload) {
        $wrongEmbeddedSource = Join-Path $directory 'WRONG~1.EXE'
        $wrongEmbeddedCabinet = Join-Path $directory 'embedded-wrong.cab'
        [System.IO.File]::WriteAllBytes($wrongEmbeddedSource, (New-FixtureBytes 16))
        New-FixtureCabinet -SourcePath $wrongEmbeddedSource -CabinetPath $wrongEmbeddedCabinet -EntryName 'WrongPayload'
        $embeddedStreamCabinet = $wrongEmbeddedCabinet
    }

    foreach ($directoryRow in @(
        @('TARGETDIR', '', 'SourceDir'),
        @('INSTALLDIR', 'TARGETDIR', 'AppDir:APPDIR')
    )) {
        $record = $installer.CreateRecord(3)
        $record.StringData(1) = $directoryRow[0]
        $record.StringData(2) = $directoryRow[1]
        $record.StringData(3) = $directoryRow[2]
        Invoke-FixtureSql $database "INSERT INTO ``Directory`` (``Directory``, ``Directory_Parent``, ``DefaultDir``) VALUES (?, ?, ?)" $record
    }

    foreach ($componentRow in @(
        @('MainComponent', 'INSTALLDIR'),
        @('CabComponent', 'INSTALLDIR')
    )) {
        $record = $installer.CreateRecord(6)
        $record.StringData(1) = $componentRow[0]
        $record.StringData(2) = ''
        $record.StringData(3) = $componentRow[1]
        $record.IntegerData(4) = 0
        $record.StringData(5) = ''
        $record.StringData(6) = ''
        Invoke-FixtureSql $database "INSERT INTO ``Component`` (``Component``, ``ComponentId``, ``Directory_``, ``Attributes``, ``Condition``, ``KeyPath``) VALUES (?, ?, ?, ?, ?, ?)" $record
    }

    $embeddedLastSequence = if ($AddSecondEmbeddedPayload) { 5 } else { 4 }
    $reservedSequence = if ($AddSecondEmbeddedPayload) { 6 } else { 5 }
    foreach ($mediaRow in @(
        @(1, 2, '', '', '', ''),
        @(2, 3, $ExternalMediaDiskPrompt, $ExternalCabinetName, $ExternalMediaVolumeLabel, $ExternalMediaSource),
        @(3, $embeddedLastSequence, '', '#embedded.cab', '', ''),
        @(4, $reservedSequence, '', '', '', '')
    )) {
        $record = $installer.CreateRecord(6)
        $record.IntegerData(1) = $mediaRow[0]
        $record.IntegerData(2) = $mediaRow[1]
        $record.StringData(3) = $mediaRow[2]
        $record.StringData(4) = $mediaRow[3]
        $record.StringData(5) = $mediaRow[4]
        $record.StringData(6) = $mediaRow[5]
        Invoke-FixtureSql $database "INSERT INTO ``Media`` (``DiskId``, ``LastSequence``, ``DiskPrompt``, ``Cabinet``, ``VolumeLabel``, ``Source``) VALUES (?, ?, ?, ?, ?, ?)" $record
    }

    $fileRecord = $installer.CreateRecord(8)
    $fileRecord.StringData(1) = 'TestFile'
    $fileRecord.StringData(2) = 'MainComponent'
    $fileRecord.StringData(3) = 'TESTFI~1.TXT|TestFile.txt'
    $fileRecord.IntegerData(4) = 12
    $fileRecord.StringData(5) = ''
    $fileRecord.StringData(6) = ''
    $fileRecord.IntegerData(7) = 0
    $fileRecord.IntegerData(8) = 1
    Invoke-FixtureSql $database "INSERT INTO ``File`` (``File``, ``Component_``, ``FileName``, ``FileSize``, ``Version``, ``Language``, ``Attributes``, ``Sequence``) VALUES (?, ?, ?, ?, ?, ?, ?, ?)" $fileRecord

    $shortFileRecord = $installer.CreateRecord(8)
    $shortFileRecord.StringData(1) = 'ShortOnly'
    $shortFileRecord.StringData(2) = 'MainComponent'
    $shortFileRecord.StringData(3) = 'SHORTO~1.DLL'
    $shortFileRecord.IntegerData(4) = 34
    $shortFileRecord.StringData(5) = ''
    $shortFileRecord.StringData(6) = ''
    $shortFileRecord.IntegerData(7) = 0
    $shortFileRecord.IntegerData(8) = 2
    Invoke-FixtureSql $database "INSERT INTO ``File`` (``File``, ``Component_``, ``FileName``, ``FileSize``, ``Version``, ``Language``, ``Attributes``, ``Sequence``) VALUES (?, ?, ?, ?, ?, ?, ?, ?)" $shortFileRecord

    $extraFiles = New-Object System.Collections.ArrayList
    [void]$extraFiles.Add(@('ExternalPayload', 'CabComponent', $ExternalPayloadFileName, 20, 3, $ExternalPayloadAttributes))
    [void]$extraFiles.Add(@('EmbeddedPayload', 'CabComponent', 'EMBED~1.EXE|EmbeddedPayload.exe', 16, 4))
    if ($AddSecondEmbeddedPayload) {
        [void]$extraFiles.Add(@('EmbeddedPayloadTwo', 'CabComponent', 'EMBED~2.EXE|EmbeddedPayloadTwo.exe', 18, 5))
    }
    [void]$extraFiles.Add(@('ReservedName', 'MainComponent', 'SAFECO~1.TXT|CON.txt', 1, $reservedSequence))
    foreach ($extraFile in $extraFiles) {
        $record = $installer.CreateRecord(8)
        $record.StringData(1) = $extraFile[0]
        $record.StringData(2) = $extraFile[1]
        $record.StringData(3) = $extraFile[2]
        $record.IntegerData(4) = $extraFile[3]
        $record.StringData(5) = ''
        $record.StringData(6) = ''
        if ($extraFile.Count -ge 6) {
            $record.IntegerData(7) = $extraFile[5]
        } else {
            $record.IntegerData(7) = 0
        }
        $record.IntegerData(8) = $extraFile[4]
        Invoke-FixtureSql $database "INSERT INTO ``File`` (``File``, ``Component_``, ``FileName``, ``FileSize``, ``Version``, ``Language``, ``Attributes``, ``Sequence``) VALUES (?, ?, ?, ?, ?, ?, ?, ?)" $record
    }

    if (-not $NoEmbeddedCabinetStream) {
        $cabRecord = $installer.CreateRecord(2)
        $cabRecord.StringData(1) = 'embedded.cab'
        $cabRecord.SetStream(2, $embeddedStreamCabinet)
        Invoke-FixtureSql $database "INSERT INTO ``_Streams`` (``Name``, ``Data``) VALUES (?, ?)" $cabRecord
    }
}

if (-not $NoBinaryTable) {
    $streamPath = Join-Path $directory ("MsiLensBinary-{0}.bin" -f ([guid]::NewGuid().ToString('N')))
    [System.IO.File]::WriteAllBytes($streamPath, ([byte[]](1, 2, 3, 4, 5)))
    try {
        $binaryRecord = $installer.CreateRecord(2)
        $binaryRecord.StringData(1) = 'TinyBinary'
        $binaryRecord.SetStream(2, $streamPath)
        Invoke-FixtureSql $database "INSERT INTO ``Binary`` (``Name``, ``Data``) VALUES (?, ?)" $binaryRecord
    } finally {
        if (Test-Path -LiteralPath $streamPath) {
            Remove-Item -LiteralPath $streamPath -Force
        }
    }
}

$summary = $database.SummaryInformation(20)
$summary.Property(1) = 2
$summary.Property(2) = 'Installation Database'
$summary.Property(3) = 'MsiLens Test Product'
$summary.Property(4) = 'MsiLens Tests'
$summary.Property(9) = '{22222222-2222-2222-2222-222222222222}'
$null = $summary.Persist()

$null = $database.Commit()

[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($summary)
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($database)
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

[pscustomobject]@{
    PSTypeName = 'MsiLens.TestFixture'
    Path       = $fullPath
    FileId     = 'TestFile'
    Product    = 'MsiLens Test Product'
}
