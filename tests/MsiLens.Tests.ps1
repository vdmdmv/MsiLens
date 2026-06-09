Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Describe -ErrorAction SilentlyContinue)) {
    $smoke = Join-Path $PSScriptRoot 'Invoke-MsiLensSmokeTests.ps1'
    & $smoke
    return
}

BeforeAll {
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'

    $global:MsiLensPesterRepoRoot = Split-Path -Parent $PSScriptRoot
    $global:MsiLensPesterScriptPath = Join-Path $global:MsiLensPesterRepoRoot 'MsiLens.ps1'
    $global:MsiLensPesterFixtureScript = Join-Path $PSScriptRoot 'New-MsiLensTestFixture.ps1'

    function Invoke-MsiLensForTest {
        param(
            [string[]] $Arguments
        )

        $previous = $env:MSILENS_SUPPRESS_EXIT
        $env:MSILENS_SUPPRESS_EXIT = '1'
        try {
            $output = & $global:MsiLensPesterScriptPath @Arguments 3>&1 2>&1
            [pscustomobject]@{
                Output   = @($output)
                ExitCode = $global:LASTEXITCODE
            }
        } finally {
            if ($null -eq $previous) {
                Remove-Item Env:\MSILENS_SUPPRESS_EXIT -ErrorAction SilentlyContinue
            } else {
                $env:MSILENS_SUPPRESS_EXIT = $previous
            }
        }
    }

    function Invoke-MsiLensProcessForTest {
        param(
            [string[]] $Arguments,
            [string] $InputText = $null,
            [string] $Command = $null
        )

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        if (-not [string]::IsNullOrEmpty($Command)) {
            $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "{0}"' -f ($Command -replace '"', '\"')
        } else {
            $allArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $global:MsiLensPesterScriptPath) + $Arguments
            $escapedArguments = foreach ($argument in $allArguments) {
                '"{0}"' -f ($argument -replace '"', '\"')
            }
            $psi.Arguments = $escapedArguments -join ' '
        }

        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false

        $process = [System.Diagnostics.Process]::Start($psi)
        if ($null -ne $InputText) {
            $process.StandardInput.Write($InputText)
        }
        $process.StandardInput.Close()

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        [void]$process.WaitForExit(30000)
        if (-not $process.HasExited) {
            $process.Kill()
            throw 'MsiLens process did not exit.'
        }

        [pscustomobject]@{
            ExitCode  = $process.ExitCode
            AllOutput = ($stdout + $stderr)
        }
    }

    function Should-HavePSTypeName {
        param(
            [object] $Object,
            [string] $Expected
        )

        $Object | Should -Not -BeNullOrEmpty
        $Object.PSObject.TypeNames[0] | Should -Be $Expected
    }

    function Should-HaveProperties {
        param(
            [object] $Object,
            [string[]] $Properties
        )

        foreach ($property in $Properties) {
            $Object.PSObject.Properties[$property] | Should -Not -BeNullOrEmpty
        }
    }

    function Should-NotHaveProperty {
        param(
            [object] $Object,
            [string] $Property
        )

        $Object.PSObject.Properties[$Property] | Should -BeNullOrEmpty
    }

    function Get-MsiLensErrorIds {
        # Error codes are carried on each ErrorRecord's FullyQualifiedErrorId,
        # not in the rendered message. Asserting against the rendered string is
        # brittle: PowerShell's ConciseView only echoes the literal code when a
        # call site passes it inline, so codes supplied via a variable never
        # appear. Read the stable id instead.
        param([object[]] $Output)

        @($Output |
            Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
            ForEach-Object { $_.FullyQualifiedErrorId }) -join ';'
    }

    if ($env:MSILENS_TEST_UNSIGNED_MSI) {
        $Fixture = [pscustomobject]@{
            Path   = $env:MSILENS_TEST_UNSIGNED_MSI
            FileId = 'TestFile'
        }
    } else {
        $Fixture = @(& $global:MsiLensPesterFixtureScript)[-1]
    }
    $global:MsiLensPesterFixture = $Fixture
    $global:MsiLensPesterMsiPath = $Fixture.Path
}

Describe 'MsiLens parser and global commands' {
    It 'returns human-readable help without data object noise' {
        $result = Invoke-MsiLensForTest @('help')
        $result.ExitCode | Should -Be 0
        ($result.Output | Out-String) | Should -Match 'MsiLens'
        ($result.Output | Out-String) | Should -Match 'Commands:'
    }

    It 'returns useful command-specific help for MVP commands' {
        $result = Invoke-MsiLensForTest @('help', 'info')
        $result.ExitCode | Should -Be 0
        $text = $result.Output | Out-String
        $text | Should -Match 'PackageInfo'
        $text | Should -Match 'ProductName'
        $text | Should -Not -Match 'MVP command'

        $result = Invoke-MsiLensForTest @('help', 'columns')
        $result.ExitCode | Should -Be 0
        $text = $result.Output | Out-String
        $text | Should -Match 'columns <table>'
        $text | Should -Match 'PrimaryKey'
        $text | Should -Not -Match 'MVP command'

        $result = Invoke-MsiLensForTest @('help', 'signature')
        $result.ExitCode | Should -Be 0
        $text = $result.Output | Out-String
        $text | Should -Match 'package-level Authenticode'
        $text | Should -Match 'TrustLimitations'
        $text | Should -Not -Match 'MVP command'
    }

    It 'returns a stable version object contract' {
        $result = Invoke-MsiLensForTest @('version')
        $result.ExitCode | Should -Be 0
        Should-HavePSTypeName $result.Output[0] 'MsiLens.Version'
        Should-HaveProperties $result.Output[0] @('Name', 'Version', 'ProjectUrl', 'ScriptPath', 'PowerShellVersion', 'Platform')
    }

    It 'returns MVP-only examples' {
        $result = Invoke-MsiLensForTest @('examples')
        $result.ExitCode | Should -Be 0
        $text = $result.Output | Out-String
        $text | Should -Match 'tables'
        $text | Should -Not -Match 'query'
    }

    It 'rejects unknown commands with exit code 2' {
        $result = Invoke-MsiLensForTest @('bogus')
        $result.ExitCode | Should -Be 2
        ($result.Output | Out-String) | Should -Match 'InvalidArgument'
    }

    It 'rejects command-before-path grammar with exit code 2' {
        $result = Invoke-MsiLensForTest @('signature', $global:MsiLensPesterMsiPath)
        $result.ExitCode | Should -Be 2
    }

    It 'treats missing path-like MSI arguments as file-not-found' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("missing-{0}.msi" -f ([guid]::NewGuid().ToString('N')))
        $result = Invoke-MsiLensForTest @($missing, 'tables')
        $result.ExitCode | Should -Be 3
    }

    It 'supports the named -Path invocation form' {
        $result = Invoke-MsiLensForTest @('-Path', $global:MsiLensPesterMsiPath, 'tables')
        $result.ExitCode | Should -Be 0
        Should-HavePSTypeName $result.Output[0] 'MsiLens.TableInfo'
    }

    It 'rejects unsupported options and extra positional arguments for existing MSI paths' {
        $result = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'table', 'Property', '-NoSuchOption')
        $result.ExitCode | Should -Be 2

        $result = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'properties', 'extra')
        $result.ExitCode | Should -Be 2
    }

    It 'reports missing path-like MSI arguments before scoped command validation' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("missing-{0}.msi" -f ([guid]::NewGuid().ToString('N')))
        $result = Invoke-MsiLensForTest @($missing, 'properties', 'extra')
        $result.ExitCode | Should -Be 3

        $result = Invoke-MsiLensForTest @($missing, 'bogus')
        $result.ExitCode | Should -Be 3

        $result = Invoke-MsiLensForTest @('-Path', $missing, 'bogus')
        $result.ExitCode | Should -Be 3
    }
}

Describe 'MsiLens MSI database inspection' {
    It 'returns package info from Property and Summary Information metadata' {
        $result = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'info')
        $result.ExitCode | Should -Be 0
        Should-HavePSTypeName $result.Output[0] 'MsiLens.PackageInfo'
        Should-HaveProperties $result.Output[0] @('ProductName', 'ProductVersion', 'ProductCode', 'Manufacturer', 'PackageCode', 'TableCount', 'IsSigned', 'SignatureStatus')
        Should-NotHaveProperty $result.Output[0] 'MsiPath'
        $result.Output[0].ProductName | Should -Be 'MsiLens Test Product'
        $result.Output[0].SignatureStatus | Should -Be 'NotSigned'
    }

    It 'discovers tables from _Tables' {
        $result = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'tables')
        $result.ExitCode | Should -Be 0
        Should-HavePSTypeName $result.Output[0] 'MsiLens.TableInfo'
        Should-NotHaveProperty $result.Output[0] 'MsiPath'
        $tableNames = @($result.Output | ForEach-Object { $_.Table })
        $tableNames | Should -Be @($tableNames | Sort-Object)
        @($result.Output | Where-Object { $_.Table -eq 'Property' }).Count | Should -Be 1
        @($result.Output | Where-Object { $_.Table -eq 'Binary' }).Count | Should -Be 1
    }

    It 'returns column metadata with type strings, nullability, and primary keys' {
        $result = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'columns', 'Property')
        $result.ExitCode | Should -Be 0
        Should-HavePSTypeName $result.Output[0] 'MsiLens.ColumnInfo'
        Should-HaveProperties $result.Output[0] @('Table', 'Column', 'Number', 'Type', 'Nullable', 'PrimaryKey')
        Should-NotHaveProperty $result.Output[0] 'MsiPath'

        $propertyColumn = $result.Output | Where-Object { $_.Column -eq 'Property' }
        $propertyColumn.Type | Should -BeOfType ([string])
        $propertyColumn.Type | Should -Match '^[sS]'
        $propertyColumn.PrimaryKey | Should -BeTrue
        $propertyColumn.Nullable | Should -BeFalse

        $valueColumn = $result.Output | Where-Object { $_.Column -eq 'Value' }
        $valueColumn.PrimaryKey | Should -BeFalse
        $valueColumn.Nullable | Should -BeTrue
    }

    It 'returns table rows with MSI columns as top-level properties and respects -First' {
        $result = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'table', 'Property', '-First', '1')
        $result.ExitCode | Should -Be 0
        @($result.Output).Count | Should -Be 1
        Should-HavePSTypeName $result.Output[0] 'MsiLens.TableRow'
        Should-HaveProperties $result.Output[0] @('Row', 'Property', 'Value')
        Should-NotHaveProperty $result.Output[0] 'Data'
        Should-NotHaveProperty $result.Output[0] 'MsiPath'
        Should-NotHaveProperty $result.Output[0] 'Table'
        $result.Output[0].Value | Should -Be 'MsiLens Test Product'
    }

    It 'adds deterministic suffixes for colliding sanitized table row property names' {
        $previous = $env:MSILENS_DOT_SOURCE_ONLY
        $env:MSILENS_DOT_SOURCE_ONLY = '1'
        try {
            . $global:MsiLensPesterScriptPath
        } finally {
            if ($null -eq $previous) {
                Remove-Item Env:\MSILENS_DOT_SOURCE_ONLY -ErrorAction SilentlyContinue
            } else {
                $env:MSILENS_DOT_SOURCE_ONLY = $previous
            }
        }

        $row = [pscustomobject]@{
            'A-B' = 'dash'
            'A B' = 'space'
        }
        $result = New-MsiLensTableRow -Table 'Collision' -RowNumber 1 -Row $row -Columns @('A-B', 'A B')

        $result.MsiColumn_A_B | Should -Be 'dash'
        $result.MsiColumn_A_B_2 | Should -Be 'space'
        Should-NotHaveProperty $result 'MsiPath'
        $result.Data['A-B'] | Should -Be 'dash'
        $result.Data['A B'] | Should -Be 'space'
    }

    It 'preserves empty MSI string values when the record field is not null' {
        $previous = $env:MSILENS_DOT_SOURCE_ONLY
        $env:MSILENS_DOT_SOURCE_ONLY = '1'
        try {
            . $global:MsiLensPesterScriptPath
        } finally {
            if ($null -eq $previous) {
                Remove-Item Env:\MSILENS_DOT_SOURCE_ONLY -ErrorAction SilentlyContinue
            } else {
                $env:MSILENS_DOT_SOURCE_ONLY = $previous
            }
        }

        $typeInfo = New-Object psobject
        $typeInfo | Add-Member -MemberType ScriptMethod -Name StringData -Value { param($index) 's72' }

        $row = New-Object psobject
        $row | Add-Member -MemberType ScriptMethod -Name IsNull -Value { param($index) $false }
        $row | Add-Member -MemberType ScriptMethod -Name StringData -Value { param($index) '' }

        $view = New-Object psobject
        $view | Add-Member -MemberType NoteProperty -Name Fetched -Value $false
        $view | Add-Member -MemberType ScriptMethod -Name Execute -Value { }
        $view | Add-Member -MemberType ScriptMethod -Name ColumnInfo -Value ({ param($kind) $typeInfo }.GetNewClosure())
        $view | Add-Member -MemberType ScriptMethod -Name Fetch -Value ({
            if ($this.Fetched) {
                return $null
            }
            $this.Fetched = $true
            return $row
        }.GetNewClosure())
        $view | Add-Member -MemberType ScriptMethod -Name Close -Value { }

        $database = New-Object psobject
        $database | Add-Member -MemberType ScriptMethod -Name OpenView -Value ({ param($sql) $view }.GetNewClosure())
        $connection = [pscustomobject]@{ Database = $database }

        $result = @(Invoke-MsiLensSqlQuery -Connection $connection -Sql 'SELECT ``EmptyText`` FROM ``Fake``' -Columns @('EmptyText'))

        $result[0].EmptyText | Should -Be ''
        $result[0].EmptyText | Should -BeOfType ([string])
    }

    It 'emits integer MSI columns as integers and string columns as strings' {
        $result = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'table', 'File', '-First', '1')
        $result.ExitCode | Should -Be 0
        Should-HavePSTypeName $result.Output[0] 'MsiLens.TableRow'
        $result.Output[0].FileSize | Should -Be 12
        $result.Output[0].Attributes | Should -Be 0
        $result.Output[0].Sequence | Should -Be 1
        $result.Output[0].FileSize | Should -BeOfType ([int])
        $result.Output[0].Attributes | Should -BeOfType ([int])
        $result.Output[0].Sequence | Should -BeOfType ([int])
        $result.Output[0].File | Should -BeOfType ([string])
        Should-NotHaveProperty $result.Output[0] 'Data'
    }

    It 'does not expose Binary stream bytes through table output' {
        $result = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'table', 'Binary')
        $result.ExitCode | Should -Be 0
        Should-HavePSTypeName $result.Output[0] 'MsiLens.TableRow'
        $result.Output[0].MsiColumn_Data | Should -Be '<binary>'
    }

    It 'lists Binary table streams, embedded cabinets, and understood streams without raw bytes' {
        $binaries = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'binaries')
        $binaries.ExitCode | Should -Be 0
        Should-HavePSTypeName $binaries.Output[0] 'MsiLens.BinaryInfo'
        Should-HaveProperties $binaries.Output[0] @('Name', 'Table', 'SourceKind', 'Size', 'CanExtract', 'Warnings', 'AmbiguousMatch')
        $binaries.Output[0].Name | Should -Be 'TinyBinary'
        $binaries.Output[0].PSObject.Properties['Data'] | Should -BeNullOrEmpty
        # Size is resolved from Record.DataSize metadata, not by reading bytes.
        $binaries.Output[0].Size | Should -Be 5

        $binary = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'binary', 'tinybinary')
        $binary.ExitCode | Should -Be 0
        $binary.Output[0].Name | Should -Be 'TinyBinary'

        $cabinets = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'cabinets')
        $cabinets.ExitCode | Should -Be 0
        Should-HavePSTypeName $cabinets.Output[0] 'MsiLens.CabinetInfo'
        $cabinets.Output[0].Cabinet | Should -Be '#embedded.cab'
        $cabinets.Output[0].StreamName | Should -Be 'embedded.cab'
        $cabinets.Output[0].Size | Should -BeGreaterThan 0
        @($cabinets.Output | Where-Object { $_.Cabinet -eq 'external.cab' }).Count | Should -Be 0

        $cabinet = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'cabinet', '#embedded.cab')
        $cabinet.ExitCode | Should -Be 0
        $cabinet.Output[0].StreamName | Should -Be 'embedded.cab'

        $streams = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'streams')
        $streams.ExitCode | Should -Be 0
        @($streams.Output | ForEach-Object { $_.Scope }) | Should -Contain 'BinaryTable'
        @($streams.Output | ForEach-Object { $_.Scope }) | Should -Contain 'EmbeddedCabinet'
        @($streams.Output | Where-Object { $_.Name -eq 'external.cab' }).Count | Should -Be 0
    }

    It 'extracts Binary streams and raw embedded cabinets with dry-run, filter, all, and overwrite behavior' {
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensArtifacts-{0}" -f ([guid]::NewGuid().ToString('N')))
        try {
            $dry = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'extract-binaries', '-Filter', 'Tiny*', '-Out', $out, '-DryRun')
            $dry.ExitCode | Should -Be 0
            Should-HavePSTypeName $dry.Output[0] 'MsiLens.ArtifactExtractionResult'
            $dry.Output[0].Status | Should -Be 'Planned'
            Test-Path -LiteralPath $out | Should -BeFalse

            $binary = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'extract-binary', 'tinybinary', '-Out', $out)
            $binary.ExitCode | Should -Be 0
            $binary.Output[0].Status | Should -Be 'Extracted'
            $binary.Output[0].ArtifactKind | Should -Be 'BinaryStream'
            [System.IO.File]::ReadAllBytes((Join-Path $out 'TinyBinary')) | Should -Be ([byte[]](1, 2, 3, 4, 5))
            # BytesWritten must agree with the DataSize-derived Size, and that
            # agreement is what makes Verified a real check rather than vacuous.
            $binary.Output[0].BytesWritten | Should -Be 5
            $binary.Output[0].Verified | Should -BeTrue

            $conflict = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'extract-binary', 'TinyBinary', '-Out', $out)
            $conflict.ExitCode | Should -Be 5
            $conflict.Output[0].Status | Should -Be 'Conflict'
            $conflict.Output[0].WouldOverwrite | Should -BeTrue

            $force = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'extract-binaries', '-All', '-Out', $out, '-Force')
            $force.ExitCode | Should -Be 0
            $force.Output[0].Status | Should -Be 'Extracted'

            $cabinet = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'extract-cabinet', 'embedded.cab', '-Out', $out)
            $cabinet.ExitCode | Should -Be 0
            $cabinet.Output[0].Status | Should -Be 'Extracted'
            $cabinet.Output[0].ArtifactKind | Should -Be 'EmbeddedCabinet'
            $cabinetPath = Join-Path $out 'embedded.cab'
            Test-Path -LiteralPath $cabinetPath | Should -BeTrue
            @([System.IO.File]::ReadAllBytes($cabinetPath)[0..3]) | Should -Be ([byte[]][char[]]'MSCF')
            Test-Path -LiteralPath (Join-Path $out 'EmbeddedPayload.exe') | Should -BeFalse
            # Exercises the _Streams DataSize path: metadata size matches the
            # raw bytes exported, so the cabinet export verifies too.
            $cabinet.Output[0].BytesWritten | Should -BeGreaterThan 0
            $cabinet.Output[0].Verified | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports no-match and missing embedded cabinet streams as artifact results' {
        $noMatch = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'extract-binary', 'NoSuchBinary', '-Out', ([System.IO.Path]::GetTempPath()))
        $noMatch.ExitCode | Should -Be 5
        Get-MsiLensErrorIds $noMatch.Output | Should -Match 'NoMatchingBinaries'

        $fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensMissingCabinet-{0}" -f ([guid]::NewGuid().ToString('N')))
        try {
            $fixture = @(& $global:MsiLensPesterFixtureScript -Path (Join-Path $fixtureDir 'fixture.msi') -NoEmbeddedCabinetStream)[-1]
            $cabinets = Invoke-MsiLensForTest @($fixture.Path, 'cabinets')
            $cabinets.Output[0].CanExtract | Should -BeFalse
            $cabinets.Output[0].Warnings | Should -Contain 'MissingSource'

            $extract = Invoke-MsiLensForTest @($fixture.Path, 'extract-cabinet', 'embedded.cab', '-Out', (Join-Path $fixtureDir 'out'))
            $extract.ExitCode | Should -Be 5
            $extract.Output[0].Status | Should -Be 'MissingSource'
            $extract.Output[0].Warnings | Should -Contain 'MissingSource'
        } finally {
            Remove-Item -LiteralPath $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'treats absent optional Binary and Media tables as empty artifact sets' {
        $fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensAbsentArtifacts-{0}" -f ([guid]::NewGuid().ToString('N')))
        try {
            $fixture = @(& $global:MsiLensPesterFixtureScript -Path (Join-Path $fixtureDir 'fixture.msi') -NoBinaryTable -NoFileTable)[-1]

            $binaries = Invoke-MsiLensForTest @($fixture.Path, 'binaries')
            $binaries.ExitCode | Should -Be 0
            @($binaries.Output).Count | Should -Be 0

            $cabinets = Invoke-MsiLensForTest @($fixture.Path, 'cabinets')
            $cabinets.ExitCode | Should -Be 0
            @($cabinets.Output).Count | Should -Be 0

            $binaryExtract = Invoke-MsiLensForTest @($fixture.Path, 'extract-binaries', '-Out', (Join-Path $fixtureDir 'out'))
            $binaryExtract.ExitCode | Should -Be 5
            Get-MsiLensErrorIds $binaryExtract.Output | Should -Match 'NoMatchingBinaries'

            $cabinetExtract = Invoke-MsiLensForTest @($fixture.Path, 'extract-cabinets', '-Out', (Join-Path $fixtureDir 'out'))
            $cabinetExtract.ExitCode | Should -Be 5
            Get-MsiLensErrorIds $cabinetExtract.Output | Should -Match 'NoMatchingCabinets'
        } finally {
            Remove-Item -LiteralPath $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'plans artifact output paths with hard blocks and local sanitization' {
        $previous = $env:MSILENS_DOT_SOURCE_ONLY
        $env:MSILENS_DOT_SOURCE_ONLY = '1'
        try {
            . $global:MsiLensPesterScriptPath
        } finally {
            if ($null -eq $previous) {
                Remove-Item Env:\MSILENS_DOT_SOURCE_ONLY -ErrorAction SilentlyContinue
            } else {
                $env:MSILENS_DOT_SOURCE_ONLY = $previous
            }
        }

        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensArtifactPath-{0}" -f ([guid]::NewGuid().ToString('N')))
        $blocked = Resolve-MsiLensArtifactOutputPath -OutputName '..\escape.bin' -OutputRoot $root
        $blocked.Safe | Should -BeFalse
        $blocked.Warning | Should -Be 'UnsafeOutputPath'

        $sanitized = Resolve-MsiLensArtifactOutputPath -OutputName 'CON.' -OutputRoot $root
        $sanitized.Safe | Should -BeTrue
        $sanitized.Sanitized | Should -BeTrue
        $sanitized.Warnings | Should -Contain 'TrailingCharacterSanitized'
        $sanitized.Warnings | Should -Contain 'ReservedNameSanitized'
    }

    It 'returns all properties and warns without failing for missing properties' {
        $result = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'properties')
        $result.ExitCode | Should -Be 0
        Should-HavePSTypeName $result.Output[0] 'MsiLens.Property'
        Should-NotHaveProperty $result.Output[0] 'MsiPath'
        @($result.Output[0].PSObject.Properties.Name)[0..1] | Should -Be @('Property', 'Value')
        $propertyNames = @($result.Output | ForEach-Object { $_.Property })
        $propertyNames | Should -Be @($propertyNames | Sort-Object)
        @($result.Output | Where-Object { $_.Property -eq 'ProductName' }).Count | Should -Be 1

        $result = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'property', 'NoSuchProperty')
        $result.ExitCode | Should -Be 0
        ($result.Output | Out-String) | Should -Match '\[PropertyNotFound\]'
    }

    It 'returns normalized File table metadata and resolves a file by identifier' {
        $result = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'files')
        $result.ExitCode | Should -Be 0
        Should-HavePSTypeName $result.Output[0] 'MsiLens.FileInfo'
        Should-HaveProperties $result.Output[0] @('File', 'Component', 'RawFileName', 'FileName', 'ShortFileName', 'LongFileName', 'FileSize', 'Version', 'Language', 'Attributes', 'Sequence')
        Should-NotHaveProperty $result.Output[0] 'MsiPath'
        $result.Output[0].FileName | Should -Be 'TestFile.txt'
        $result.Output[0].FileSize | Should -Be 12
        $result.Output[0].Attributes | Should -Be 0
        $result.Output[0].Sequence | Should -Be 1
        $result.Output[0].FileSize | Should -BeOfType ([int])
        $result.Output[0].Attributes | Should -BeOfType ([int])
        $result.Output[0].Sequence | Should -BeOfType ([int])

        $shortOnly = $result.Output | Where-Object { $_.File -eq 'ShortOnly' }
        $shortOnly.FileName | Should -Be 'SHORTO~1.DLL'
        $shortOnly.ShortFileName | Should -Be 'SHORTO~1.DLL'
        $shortOnly.LongFileName | Should -BeNullOrEmpty

        $result = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'file', $global:MsiLensPesterFixture.FileId)
        $result.ExitCode | Should -Be 0
        Should-HavePSTypeName $result.Output[0] 'MsiLens.FileInfo'
        Should-NotHaveProperty $result.Output[0] 'MsiPath'
        $result.Output[0].File | Should -Be $global:MsiLensPesterFixture.FileId

        $result = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'file', 'NoSuchFile.dll')
        $result.ExitCode | Should -Be 0
        ($result.Output | Out-String) | Should -Match '\[FileNotFound\]'
    }

    It 'extracts uncompressed files with flat and installed-tree layouts' {
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensExtract-{0}" -f ([guid]::NewGuid().ToString('N')))
        try {
            $result = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'extract-file', 'TestFile', '-Out', $out)
            $result.ExitCode | Should -Be 0
            Should-HavePSTypeName $result.Output[0] 'MsiLens.ExtractionResult'
            $result.Output[0].Status | Should -Be 'Extracted'
            $result.Output[0].SourceKind | Should -Be 'Uncompressed'
            $result.Output[0].RelativePath | Should -Be 'TestFile.txt'
            $result.Output[0].Verified | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $out 'TestFile.txt') | Should -BeTrue

            $treeOut = Join-Path $out 'tree'
            $tree = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'extract-file', 'TestFile', '-Out', $treeOut, '-Layout', 'InstalledTree')
            $tree.ExitCode | Should -Be 0
            $tree.Output[0].RelativePath | Should -Be (Join-Path 'AppDir' 'TestFile.txt')
            Test-Path -LiteralPath (Join-Path $treeOut (Join-Path 'AppDir' 'TestFile.txt')) | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'supports dry-run, filtering, all extraction, and overwrite protection' {
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensExtract-{0}" -f ([guid]::NewGuid().ToString('N')))
        try {
            $dry = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'extract-files', '-Filter', '*.dll', '-Out', $out, '-DryRun')
            $dry.ExitCode | Should -Be 0
            @($dry.Output | Where-Object { $_.Status -eq 'Planned' }).Count | Should -BeGreaterThan 0
            Test-Path -LiteralPath $out | Should -BeFalse

            $all = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'extract-files', '-Out', $out)
            $all.ExitCode | Should -Be 0
            @($all.Output | Where-Object { $_.Status -eq 'Extracted' }).Count | Should -BeGreaterThan 0
            @($all.Output | Where-Object { $_.Status -eq 'MissingSource' }).Count | Should -Be 0
            @($all.Output | ForEach-Object { $_.Layout } | Select-Object -Unique) | Should -Be @('InstalledTree')
            Test-Path -LiteralPath (Join-Path $out (Join-Path 'AppDir' 'TestFile.txt')) | Should -BeTrue

            $conflict = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'extract-file', 'TestFile', '-Out', $out, '-Layout', 'InstalledTree')
            $conflict.ExitCode | Should -Be 5
            $conflict.Output[0].Status | Should -Be 'Conflict'
            $conflict.Output[0].WouldOverwrite | Should -BeTrue

            $force = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'extract-file', 'TestFile', '-Out', $out, '-Layout', 'InstalledTree', '-Force')
            $force.ExitCode | Should -Be 0
            $force.Output[0].Status | Should -Be 'Extracted'
            $force.Output[0].WouldOverwrite | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'dry-run reports existing output conflicts and missing resolvable sources' {
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensDryRun-{0}" -f ([guid]::NewGuid().ToString('N')))
        $fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensDryRunFixture-{0}" -f ([guid]::NewGuid().ToString('N')))
        try {
            New-Item -ItemType Directory -Path $out | Out-Null
            Set-Content -LiteralPath (Join-Path $out 'TestFile.txt') -Value 'existing'

            $conflict = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'extract-file', 'TestFile', '-Out', $out, '-DryRun')
            $conflict.ExitCode | Should -Be 5
            $conflict.Output[0].Status | Should -Be 'Conflict'
            $conflict.Output[0].WouldOverwrite | Should -BeTrue

            $forcedPlan = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'extract-file', 'TestFile', '-Out', $out, '-DryRun', '-Force')
            $forcedPlan.ExitCode | Should -Be 0
            $forcedPlan.Output[0].Status | Should -Be 'Planned'
            $forcedPlan.Output[0].WouldOverwrite | Should -BeTrue

            $fixturePath = Join-Path $fixtureDir 'fixture.msi'
            $fixture = @(& $global:MsiLensPesterFixtureScript -Path $fixturePath -ExternalCabinetName 'missing.cab')[-1]
            $missing = Invoke-MsiLensForTest @($fixture.Path, 'extract-file', 'ExternalPayload', '-Out', (Join-Path $fixtureDir 'out'), '-DryRun')
            $missing.ExitCode | Should -Be 5
            $missing.Output[0].Status | Should -Be 'MissingSource'
            $missing.Output[0].Warnings | Should -Contain 'MissingSource'
        } finally {
            Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'honors File table compression attributes when resolving sources' {
        $fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensCompressionAttributes-{0}" -f ([guid]::NewGuid().ToString('N')))
        $fixturePath = Join-Path $fixtureDir 'fixture.msi'
        try {
            $noncompressed = @(& $global:MsiLensPesterFixtureScript -Path $fixturePath -ExternalPayloadAttributes 8192)[-1]
            $out = Join-Path $fixtureDir 'out'
            $result = Invoke-MsiLensForTest @($noncompressed.Path, 'extract-file', 'ExternalPayload', '-Out', $out)
            $result.ExitCode | Should -Be 0
            $result.Output[0].Status | Should -Be 'Extracted'
            $result.Output[0].SourceKind | Should -Be 'Uncompressed'
            Test-Path -LiteralPath (Join-Path $out 'CabPayload.dll') | Should -BeTrue

            Remove-Item -LiteralPath $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $fixtureDir | Out-Null
            $compressedNoCabinet = @(& $global:MsiLensPesterFixtureScript -Path $fixturePath -ExternalCabinetName '' -ExternalPayloadAttributes 16384)[-1]
            $unsupported = Invoke-MsiLensForTest @($compressedNoCabinet.Path, 'extract-file', 'ExternalPayload', '-Out', (Join-Path $fixtureDir 'out'), '-DryRun')
            $unsupported.ExitCode | Should -Be 5
            $unsupported.Output[0].Status | Should -Be 'Unsupported'
            $unsupported.Output[0].Warnings | Should -Contain 'UnsupportedMediaLayout'
        } finally {
            Remove-Item -LiteralPath $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'extracts external and embedded cabinet payloads without installer execution' {
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensExtract-{0}" -f ([guid]::NewGuid().ToString('N')))
        try {
            $external = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'extract-file', 'ExternalPayload', '-Out', $out)
            $external.ExitCode | Should -Be 0
            $external.Output[0].Status | Should -Be 'Extracted'
            $external.Output[0].SourceKind | Should -Be 'ExternalCabinet'
            Test-Path -LiteralPath (Join-Path $out 'CabPayload.dll') | Should -BeTrue

            $embedded = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'extract-file', 'EmbeddedPayload', '-Out', $out)
            $embedded.ExitCode | Should -Be 0
            $embedded.Output[0].Status | Should -Be 'Extracted'
            $embedded.Output[0].SourceKind | Should -Be 'EmbeddedCabinet'
            Test-Path -LiteralPath (Join-Path $out 'EmbeddedPayload.exe') | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'extracts cabinet payloads keyed by File table identifiers' {
        $fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensFileKeyCabinet-{0}" -f ([guid]::NewGuid().ToString('N')))
        $fixturePath = Join-Path $fixtureDir 'fixture.msi'
        try {
            $fixture = @(& $global:MsiLensPesterFixtureScript -Path $fixturePath -ExternalCabinetEntryName 'ExternalPayload' -EmbeddedCabinetEntryName 'EmbeddedPayload')[-1]
            $out = Join-Path $fixtureDir 'out'

            $external = Invoke-MsiLensForTest @($fixture.Path, 'extract-file', 'ExternalPayload', '-Out', $out)
            $external.ExitCode | Should -Be 0
            $external.Output[0].Status | Should -Be 'Extracted'
            $external.Output[0].Verified | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $out 'CabPayload.dll') | Should -BeTrue

            $embedded = Invoke-MsiLensForTest @($fixture.Path, 'extract-file', 'EmbeddedPayload', '-Out', $out)
            $embedded.ExitCode | Should -Be 0
            $embedded.Output[0].Status | Should -Be 'Extracted'
            $embedded.Output[0].Verified | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $out 'EmbeddedPayload.exe') | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'extracts multiple selected payloads from one embedded cabinet' {
        $fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensGroupedCabinet-{0}" -f ([guid]::NewGuid().ToString('N')))
        $fixturePath = Join-Path $fixtureDir 'fixture.msi'
        try {
            $fixture = @(& $global:MsiLensPesterFixtureScript -Path $fixturePath -AddSecondEmbeddedPayload)[-1]
            $out = Join-Path $fixtureDir 'out'

            $result = Invoke-MsiLensForTest @($fixture.Path, 'extract-files', '-Filter', 'EmbeddedPayload*', '-Out', $out, '-Layout', 'InstalledTree')

            $result.ExitCode | Should -Be 0
            @($result.Output | Where-Object { $_.Status -eq 'Extracted' }).Count | Should -Be 2
            @($result.Output | ForEach-Object { $_.SourceKind } | Select-Object -Unique) | Should -Be @('EmbeddedCabinet')
            @($result.Output | ForEach-Object { $_.Verified }) | Should -Be @($true, $true)
            Test-Path -LiteralPath (Join-Path $out (Join-Path 'AppDir' 'EmbeddedPayload.exe')) | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $out (Join-Path 'AppDir' 'EmbeddedPayloadTwo.exe')) | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $out (Join-Path 'AppDir' 'CabPayload.dll')) | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'uses whole-cabinet expansion only through the grouped extraction helper' {
        $script = Get-Content -LiteralPath $global:MsiLensPesterScriptPath -Raw
        $script | Should -Match 'function Expand-MsiLensCabinetDirectory'
        $script | Should -Match "'-F:\*'"
    }

    It 'rejects unsafe external cabinet names before path splitting' {
        foreach ($cabinet in @(
            '\\server\share\external.cab',
            '\external.cab',
            'C:\external.cab',
            '..\external.cab',
            'external.cab:stream'
        )) {
            $fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensUnsafeCabinet-{0}" -f ([guid]::NewGuid().ToString('N')))
            $fixturePath = Join-Path $fixtureDir 'fixture.msi'
            try {
                $fixture = @(& $global:MsiLensPesterFixtureScript -Path $fixturePath -ExternalCabinetName $cabinet)[-1]
                $out = Join-Path $fixtureDir 'out'

                $result = Invoke-MsiLensForTest @($fixture.Path, 'extract-file', 'ExternalPayload', '-Out', $out, '-DryRun')

                $result.ExitCode | Should -Be 5
                $result.Output[0].Status | Should -Be 'Unsupported'
                $result.Output[0].SourceKind | Should -Be 'ExternalCabinet'
                $result.Output[0].Cabinet | Should -Be $cabinet
                $result.Output[0].Warnings | Should -Contain 'UnsafeSourcePath'
            } finally {
                Remove-Item -LiteralPath $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'does not use cabinet payload lookup names outside the extraction temp directory' {
        $fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensCabinetEscape-{0}" -f ([guid]::NewGuid().ToString('N')))
        $escapeName = "MsiLensEscape-{0}.dll" -f ([guid]::NewGuid().ToString('N'))
        $outsidePath = Join-Path ([System.IO.Path]::GetTempPath()) $escapeName
        $outsideBytes = New-Object byte[] 20
        for ($i = 0; $i -lt $outsideBytes.Length; $i++) {
            $outsideBytes[$i] = 90
        }
        try {
            [System.IO.File]::WriteAllBytes($outsidePath, $outsideBytes)
            $fixturePath = Join-Path $fixtureDir 'fixture.msi'
            $fixture = @(& $global:MsiLensPesterFixtureScript -Path $fixturePath -ExternalPayloadFileName ("..\{0}|CabPayload.dll" -f $escapeName))[-1]
            $out = Join-Path $fixtureDir 'out'

            $result = Invoke-MsiLensForTest @($fixture.Path, 'extract-file', 'ExternalPayload', '-Out', $out)

            $result.ExitCode | Should -Be 5
            $result.Output[0].Status | Should -Be 'MissingSource'
            $result.Output[0].Warnings | Should -Contain 'MissingSource'
            Test-Path -LiteralPath (Join-Path $out 'CabPayload.dll') | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $outsidePath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports missing external cabinets as missing sources' {
        $fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensMissingCabinet-{0}" -f ([guid]::NewGuid().ToString('N')))
        $fixturePath = Join-Path $fixtureDir 'fixture.msi'
        try {
            $fixture = @(& $global:MsiLensPesterFixtureScript -Path $fixturePath -ExternalCabinetName 'missing.cab')[-1]
            $out = Join-Path $fixtureDir 'out'

            $result = Invoke-MsiLensForTest @($fixture.Path, 'extract-file', 'ExternalPayload', '-Out', $out)

            $result.ExitCode | Should -Be 5
            $result.Output[0].Status | Should -Be 'MissingSource'
            $result.Output[0].SourceKind | Should -Be 'ExternalCabinet'
            $result.Output[0].Warnings | Should -Contain 'MissingSource'
        } finally {
            Remove-Item -LiteralPath $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not fall back to same-named external cabinets for missing embedded streams' {
        $fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensMissingEmbeddedCabinet-{0}" -f ([guid]::NewGuid().ToString('N')))
        $fixturePath = Join-Path $fixtureDir 'fixture.msi'
        try {
            $fixture = @(& $global:MsiLensPesterFixtureScript -Path $fixturePath -NoEmbeddedCabinetStream)[-1]
            $out = Join-Path $fixtureDir 'out'

            $result = Invoke-MsiLensForTest @($fixture.Path, 'extract-file', 'EmbeddedPayload', '-Out', $out)

            $result.ExitCode | Should -Be 5
            $result.Output[0].Status | Should -Be 'MissingSource'
            $result.Output[0].SourceKind | Should -Be 'EmbeddedCabinet'
            $result.Output[0].Warnings | Should -Contain 'MissingSource'
            Test-Path -LiteralPath (Join-Path $out 'EmbeddedPayload.exe') | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not fall back to same-named external cabinets when embedded payload is wrong' {
        $fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensWrongEmbeddedCabinet-{0}" -f ([guid]::NewGuid().ToString('N')))
        $fixturePath = Join-Path $fixtureDir 'fixture.msi'
        try {
            $fixture = @(& $global:MsiLensPesterFixtureScript -Path $fixturePath -EmbeddedCabinetStreamHasWrongPayload)[-1]
            $out = Join-Path $fixtureDir 'out'

            $result = Invoke-MsiLensForTest @($fixture.Path, 'extract-file', 'EmbeddedPayload', '-Out', $out)

            $result.ExitCode | Should -Be 5
            $result.Output[0].Status | Should -Be 'MissingSource'
            $result.Output[0].SourceKind | Should -Be 'EmbeddedCabinet'
            $result.Output[0].Warnings | Should -Contain 'MissingSource'
            Test-Path -LiteralPath (Join-Path $out 'EmbeddedPayload.exe') | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'treats media prompts labels and sources as unsupported layouts' {
        foreach ($case in @(
            @{ Name = 'DiskPrompt'; Argument = 'ExternalMediaDiskPrompt'; Value = 'Insert disk 2' },
            @{ Name = 'VolumeLabel'; Argument = 'ExternalMediaVolumeLabel'; Value = 'DISK2' },
            @{ Name = 'Source'; Argument = 'ExternalMediaSource'; Value = 'disk2' }
        )) {
            $fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensUnsupportedMedia-{0}-{1}" -f $case['Name'], ([guid]::NewGuid().ToString('N')))
            $fixturePath = Join-Path $fixtureDir 'fixture.msi'
            try {
                $fixtureArguments = @{ Path = $fixturePath }
                $fixtureArguments[$case['Argument']] = $case['Value']
                $fixture = @(& $global:MsiLensPesterFixtureScript @fixtureArguments)[-1]
                $out = Join-Path $fixtureDir 'out'

                $result = Invoke-MsiLensForTest @($fixture.Path, 'extract-file', 'ExternalPayload', '-Out', $out, '-DryRun')

                $result.ExitCode | Should -Be 5
                $result.Output[0].Status | Should -Be 'Unsupported'
                $result.Output[0].Warnings | Should -Contain 'UnsupportedMediaLayout'
                $result.Output[0].Message | Should -Be 'File sequence could not be mapped to a supported Media row.'
            } finally {
                Remove-Item -LiteralPath $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'treats existing directories at output paths as conflicts even with force' {
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensExtract-{0}" -f ([guid]::NewGuid().ToString('N')))
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $out 'TestFile.txt') -Force)

            $result = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'extract-file', 'TestFile', '-Out', $out, '-Force')

            $result.ExitCode | Should -Be 5
            $result.Output[0].Status | Should -Be 'Conflict'
            $result.Output[0].Warnings | Should -Contain 'OutputConflict'
            $result.Output[0].Message | Should -Be 'Output path is an existing directory.'
        } finally {
            Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'sanitizes local output hazards and keeps paths under Out' {
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensExtract-{0}" -f ([guid]::NewGuid().ToString('N')))
        try {
            $result = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'extract-file', 'ReservedName', '-Out', $out, '-DryRun')
            $result.ExitCode | Should -Be 0
            $result.Output[0].Status | Should -Be 'Planned'
            $result.Output[0].Sanitized | Should -BeTrue
            $result.Output[0].Warnings | Should -Contain 'ReservedNameSanitized'
            $result.Output[0].OutputPath.StartsWith([System.IO.Path]::GetFullPath($out), [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'treats absent Property and File tables as empty metadata for semantic commands' {
        $missingTablesPath = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensMissingTables-{0}.msi" -f ([guid]::NewGuid().ToString('N')))
        $missingTablesFixture = @(& $global:MsiLensPesterFixtureScript -Path $missingTablesPath -NoPropertyTable -NoFileTable)[-1]
        try {
            $result = Invoke-MsiLensForTest @($missingTablesFixture.Path, 'info')
            $result.ExitCode | Should -Be 0
            @($result.Output).Count | Should -Be 1
            Should-HavePSTypeName $result.Output[0] 'MsiLens.PackageInfo'
            $result.Output[0].ProductName | Should -BeNullOrEmpty
            $result.Output[0].ProductVersion | Should -BeNullOrEmpty
            $result.Output[0].ProductCode | Should -BeNullOrEmpty
            $result.Output[0].Manufacturer | Should -BeNullOrEmpty

            $result = Invoke-MsiLensForTest @($missingTablesFixture.Path, 'properties')
            $result.ExitCode | Should -Be 0
            @($result.Output).Count | Should -Be 0

            $result = Invoke-MsiLensForTest @($missingTablesFixture.Path, 'property', 'ProductName')
            $result.ExitCode | Should -Be 0
            ($result.Output | Out-String) | Should -Match '\[PropertyNotFound\]'

            $result = Invoke-MsiLensForTest @($missingTablesFixture.Path, 'files')
            $result.ExitCode | Should -Be 0
            @($result.Output).Count | Should -Be 0

            $result = Invoke-MsiLensForTest @($missingTablesFixture.Path, 'file', 'NoSuchFile.dll')
            $result.ExitCode | Should -Be 0
            ($result.Output | Out-String) | Should -Match '\[FileNotFound\]'

            $result = Invoke-MsiLensForTest @($missingTablesFixture.Path, 'table', 'Property')
            $result.ExitCode | Should -Be 4

            $result = Invoke-MsiLensForTest @($missingTablesFixture.Path, 'columns', 'File')
            $result.ExitCode | Should -Be 4
        } finally {
            Remove-Item -LiteralPath $missingTablesFixture.Path -Force -ErrorAction SilentlyContinue
        }
    }

    It 'releases the MSI file handle after in-process inspection commands' {
        $lockPath = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensLock-{0}.msi" -f ([guid]::NewGuid().ToString('N')))
        $lockFixture = @(& $global:MsiLensPesterFixtureScript -Path $lockPath)[-1]
        try {
            foreach ($cmd in @(@('tables'), @('table', 'File', '-First', '1'), @('files'), @('table', 'Binary'))) {
                $null = Invoke-MsiLensForTest (@($lockFixture.Path) + $cmd)
            }
            # An exclusive open only succeeds if no lingering COM handle holds the file.
            {
                $stream = [System.IO.File]::Open($lockFixture.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                $stream.Close()
            } | Should -Not -Throw
        } finally {
            Remove-Item -LiteralPath $lockFixture.Path -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'MsiLens signature inspection' {
    It 'returns package-level Authenticode status for an unsigned MSI' {
        $result = Invoke-MsiLensForTest @($global:MsiLensPesterMsiPath, 'signature')
        $result.ExitCode | Should -Be 0
        @($result.Output).Count | Should -Be 1
        Should-HavePSTypeName $result.Output[0] 'MsiLens.Signature'
        Should-HaveProperties $result.Output[0] @('Scope', 'TrustScope', 'TrustLimitations', 'IsSigned', 'IsValid', 'Status', 'StatusMessage', 'SignerSubject', 'SignerIssuer', 'SignerSerialNumber', 'SignerThumbprint', 'SignerNotBefore', 'SignerNotAfter', 'SignerEnhancedKeyUsages', 'TimestampSubject', 'TimestampTime')
        Should-NotHaveProperty $result.Output[0] 'MsiPath'
        $result.Output[0].Scope | Should -Be 'PackageAuthenticode'
        $result.Output[0].TrustScope | Should -Be 'PackageSignature'
        $result.Output[0].Status | Should -Be 'NotSigned'
        $result.Output[0].IsSigned | Should -BeFalse
        $result.Output[0].IsValid | Should -BeFalse
        $result.Output[0].PSObject.Properties['InspectionFailed'] | Should -BeNullOrEmpty
    }

    It 'inspects Authenticode signature without opening the MSI database' {
        $invalidMsiPath = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensInvalidDatabase-{0}.msi" -f ([guid]::NewGuid().ToString('N')))
        try {
            Set-Content -LiteralPath $invalidMsiPath -Value 'not an msi database' -NoNewline -Encoding ASCII

            $result = Invoke-MsiLensForTest @($invalidMsiPath, 'signature')
            $result.ExitCode | Should -Be 0
            @($result.Output).Count | Should -Be 1
            Should-HavePSTypeName $result.Output[0] 'MsiLens.Signature'
            $result.Output[0].Scope | Should -Be 'PackageAuthenticode'
        } finally {
            Remove-Item -LiteralPath $invalidMsiPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports optional signed fixture status when MSILENS_TEST_SIGNED_MSI is set' -Skip:(-not $env:MSILENS_TEST_SIGNED_MSI) {
        $result = Invoke-MsiLensForTest @($env:MSILENS_TEST_SIGNED_MSI, 'signature')
        $result.ExitCode | Should -Be 0
        Should-HavePSTypeName $result.Output[0] 'MsiLens.Signature'
        $result.Output[0].Status | Should -Not -BeNullOrEmpty
    }

    It 'reports optional tampered signed fixture as invalid when MSILENS_TEST_TAMPERED_SIGNED_MSI is set' -Skip:(-not $env:MSILENS_TEST_TAMPERED_SIGNED_MSI) {
        $result = Invoke-MsiLensForTest @($env:MSILENS_TEST_TAMPERED_SIGNED_MSI, 'signature')
        $result.ExitCode | Should -Be 0
        Should-HavePSTypeName $result.Output[0] 'MsiLens.Signature'
        $result.Output[0].IsValid | Should -BeFalse
    }
}

Describe 'MsiLens completion' {
    BeforeAll {
        $previous = $env:MSILENS_DOT_SOURCE_ONLY
        $env:MSILENS_DOT_SOURCE_ONLY = '1'
        try {
            . $global:MsiLensPesterScriptPath
        } finally {
            if ($null -eq $previous) {
                Remove-Item Env:\MSILENS_DOT_SOURCE_ONLY -ErrorAction SilentlyContinue
            } else {
                $env:MSILENS_DOT_SOURCE_ONLY = $previous
            }
        }
    }

    It 'exposes one-shot top-level command completion metadata' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($global:MsiLensPesterScriptPath, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0

        $argumentsParameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Arguments' }
        $argumentsParameter | Should -Not -BeNullOrEmpty

        $attributeNames = @($argumentsParameter.Attributes |
            Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] } |
            ForEach-Object { $_.TypeName.GetReflectionAttributeType().Name })
        $attributeNames | Should -Contain 'ArgumentCompleterAttribute'
    }

    It 'completes command names for one-shot help arguments' {
        $escapedScriptPath = $global:MsiLensPesterScriptPath -replace "'", "''"

        $line = "& '$escapedScriptPath' help t"
        $result = [System.Management.Automation.CommandCompletion]::CompleteInput($line, $line.Length, $null)
        @($result.CompletionMatches | ForEach-Object { $_.ListItemText }) | Should -Contain 'table'
        @($result.CompletionMatches | ForEach-Object { $_.ListItemText }) | Should -Contain 'tables'

        $line = "& '$escapedScriptPath' help "
        $result = [System.Management.Automation.CommandCompletion]::CompleteInput($line, $line.Length, $null)
        @($result.CompletionMatches | ForEach-Object { $_.ListItemText }) | Should -Contain 'signature'
        @($result.CompletionMatches | ForEach-Object { $_.ListItemText }) | Should -Not -Contain 'MsiLens.ps1'
        @($result.CompletionMatches | ForEach-Object { $_.ListItemText } | Sort-Object) | Should -Be @(((Get-MsiLensGlobalCommands) + (Get-MsiLensScopedCommands)) | Sort-Object)
    }

    It 'completes REPL command names without short aliases' {
        $result = @(Complete-MsiLensReplInput -Line 'ta' -CursorIndex 2)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'table'
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'tables'
        @($result | ForEach-Object { $_.ListItemText }) | Should -Not -Contain 'tbl'

        $result = @(Complete-MsiLensReplInput -Line 'si' -CursorIndex 2)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'signature'
        @($result | ForEach-Object { $_.ListItemText }) | Should -Not -Contain 'sig'

        @(Complete-MsiLensReplInput -Line 'pr' -CursorIndex 2 | ForEach-Object { $_.ListItemText }) | Should -Not -Contain 'prop'
    }

    It 'completes command names for REPL help arguments' {
        $result = @(Complete-MsiLensReplInput -Line 'help t' -CursorIndex 6)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'table'
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'tables'

        $result = @(Complete-MsiLensReplInput -Line 'help ' -CursorIndex 5)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'signature'
        @($result | ForEach-Object { $_.ListItemText }) | Should -Not -Contain 'MsiLens.ps1'
        @($result | ForEach-Object { $_.ListItemText } | Sort-Object) | Should -Be @(((Get-MsiLensGlobalCommands) + (Get-MsiLensScopedCommands)) | Sort-Object)
    }

    It 'completes supported REPL options' {
        $result = @(Complete-MsiLensReplInput -Line 'table Property -' -CursorIndex 16 -CurrentPath $global:MsiLensPesterMsiPath)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Be @('-First')
    }

    It 'completes table names from the open MSI' {
        $result = @(Complete-MsiLensReplInput -Line 'table P' -CursorIndex 7 -CurrentPath $global:MsiLensPesterMsiPath)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'Property'

        $result = @(Complete-MsiLensReplInput -Line 'columns F' -CursorIndex 9 -CurrentPath $global:MsiLensPesterMsiPath)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'File'
    }

    It 'completes property names from the open MSI' {
        $result = @(Complete-MsiLensReplInput -Line 'property Product' -CursorIndex 16 -CurrentPath $global:MsiLensPesterMsiPath)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'ProductName'
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'ProductVersion'
    }

    It 'completes file identifiers and names from the open MSI' {
        $result = @(Complete-MsiLensReplInput -Line 'file Test' -CursorIndex 9 -CurrentPath $global:MsiLensPesterMsiPath)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'TestFile'
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'TestFile.txt'

        $result = @(Complete-MsiLensReplInput -Line 'file SHORT' -CursorIndex 10 -CurrentPath $global:MsiLensPesterMsiPath)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'SHORTO~1.DLL'
    }

    It 'completes extraction file names and options from the open MSI' {
        $result = @(Complete-MsiLensReplInput -Line 'extract-file Test' -CursorIndex 17 -CurrentPath $global:MsiLensPesterMsiPath)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'TestFile'
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'TestFile.txt'

        $result = @(Complete-MsiLensReplInput -Line 'extract-files -' -CursorIndex 15 -CurrentPath $global:MsiLensPesterMsiPath)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain '-Filter'
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain '-All'
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain '-Out'
    }

    It 'completes PowerShell command names after REPL pipeline separators' {
        $result = @(Complete-MsiLensReplInput -Line 'properties | w' -CursorIndex 14 -CurrentPath $global:MsiLensPesterMsiPath)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'Where-Object'
        @($result | Where-Object { $_.ListItemText -eq 'Where-Object' } | Select-Object -First 1).ReplacementIndex | Should -Be 13

        $result = @(Complete-MsiLensReplInput -Line 'properties; w' -CursorIndex 13 -CurrentPath $global:MsiLensPesterMsiPath)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'Where-Object'
    }

    It 'completes REPL output property names for PowerShell property parameters' {
        $result = @(Complete-MsiLensReplInput -Line 'properties | where-object P' -CursorIndex 27 -CurrentPath $global:MsiLensPesterMsiPath)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Be @('Property')
        $result[0].ReplacementIndex | Should -Be 26
        $result[0].ReplacementLength | Should -Be 1

        $result = @(Complete-MsiLensReplInput -Line 'properties | Where-Object' -CursorIndex 25 -CurrentPath $global:MsiLensPesterMsiPath)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'Property'
        @($result | ForEach-Object { $_.CompletionText }) | Should -Contain ' Property'

        $result = @(Complete-MsiLensReplInput -Line 'properties | where P' -CursorIndex 20 -CurrentPath $global:MsiLensPesterMsiPath)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Be @('Property')

        $result = @(Complete-MsiLensReplInput -Line 'properties | ? P' -CursorIndex 16 -CurrentPath $global:MsiLensPesterMsiPath)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Be @('Property')

        $result = @(Complete-MsiLensReplInput -Line 'properties | sort P' -CursorIndex 19 -CurrentPath $global:MsiLensPesterMsiPath)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Be @('Property')

        $result = @(Complete-MsiLensReplInput -Line 'properties | select -ExpandProperty P' -CursorIndex 37 -CurrentPath $global:MsiLensPesterMsiPath)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Be @('Property')

        $result = @(Complete-MsiLensReplInput -Line 'properties | ft P' -CursorIndex 17 -CurrentPath $global:MsiLensPesterMsiPath)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Be @('Property')

        $result = @(Complete-MsiLensReplInput -Line 'table Property | where-object V' -CursorIndex 31 -CurrentPath $global:MsiLensPesterMsiPath)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'Value'

        $result = @(Complete-MsiLensReplInput -Line 'files | where-object S' -CursorIndex 22 -CurrentPath $global:MsiLensPesterMsiPath)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'ShortFileName'
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'Sequence'

        $result = @(Complete-MsiLensReplInput -Line 'version | where-object P' -CursorIndex 24)
        @($result | ForEach-Object { $_.ListItemText }) | Should -Contain 'Platform'
    }

    It 'caches MSI-backed REPL completion candidates per path' {
        $script:MsiLensCompletionCache = @{}
        $global:MsiLensPesterCompletionOpenCount = 0
        $global:MsiLensPesterOriginalOpenDatabase = ${function:Open-MsiLensDatabase}
        try {
            Set-Item -Path Function:\Open-MsiLensDatabase -Value {
                param([string] $MsiPath)

                $global:MsiLensPesterCompletionOpenCount++
                & $global:MsiLensPesterOriginalOpenDatabase $MsiPath
            }

            [void]@(Complete-MsiLensReplInput -Line 'table P' -CursorIndex 7 -CurrentPath $global:MsiLensPesterMsiPath)
            [void]@(Complete-MsiLensReplInput -Line 'columns Pr' -CursorIndex 10 -CurrentPath $global:MsiLensPesterMsiPath)
            $global:MsiLensPesterCompletionOpenCount | Should -Be 1

            [void]@(Complete-MsiLensReplInput -Line 'property Product' -CursorIndex 16 -CurrentPath $global:MsiLensPesterMsiPath)
            [void]@(Complete-MsiLensReplInput -Line 'property ProductV' -CursorIndex 17 -CurrentPath $global:MsiLensPesterMsiPath)
            $global:MsiLensPesterCompletionOpenCount | Should -Be 2

            [void]@(Complete-MsiLensReplInput -Line 'file Test' -CursorIndex 9 -CurrentPath $global:MsiLensPesterMsiPath)
            [void]@(Complete-MsiLensReplInput -Line 'file TestF' -CursorIndex 10 -CurrentPath $global:MsiLensPesterMsiPath)
            $global:MsiLensPesterCompletionOpenCount | Should -Be 3
        } finally {
            Set-Item -Path Function:\Open-MsiLensDatabase -Value $global:MsiLensPesterOriginalOpenDatabase
            Remove-Variable -Name MsiLensPesterCompletionOpenCount -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable -Name MsiLensPesterOriginalOpenDatabase -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'completes filesystem paths for open' {
        $directory = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensCompletion-{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $directory | Out-Null
        $path = Join-Path $directory 'Package One.msi'
        New-Item -ItemType File -Path $path | Out-Null
        try {
            $prefix = Join-Path $directory 'Pack'
            $line = 'open "' + $prefix
            $result = @(Complete-MsiLensReplInput -Line $line -CursorIndex $line.Length)
            @($result | ForEach-Object { [System.IO.Path]::GetFileName($_.ListItemText) }) | Should -Contain 'Package One.msi'
            @($result | ForEach-Object { $_.CompletionText })[0] | Should -Match '^"'
        } finally {
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns no table or property candidates without an open MSI' {
        @(Complete-MsiLensReplInput -Line 'table P' -CursorIndex 7).Count | Should -Be 0
        @(Complete-MsiLensReplInput -Line 'property Product' -CursorIndex 16).Count | Should -Be 0
        @(Complete-MsiLensReplInput -Line 'file Test' -CursorIndex 9).Count | Should -Be 0
    }

    It 'suppresses PSReadLine parent-session history while reading REPL input' -Skip:(-not (Get-Module PSReadLine -ListAvailable)) {
        Import-MsiLensPsReadLine | Should -BeTrue

        $originalHandler = [Microsoft.PowerShell.PSConsoleReadLine]::GetOptions().AddToHistoryHandler
        $previousHandler = Set-MsiLensPsReadLineHistorySuppression
        try {
            $previousHandler | Should -Be $originalHandler
            $currentHandler = [Microsoft.PowerShell.PSConsoleReadLine]::GetOptions().AddToHistoryHandler
            $currentHandler.Invoke('info') | Should -Be ([Microsoft.PowerShell.AddToHistoryOption]::SkipAdding)
        } finally {
            Restore-MsiLensPsReadLineHistoryHandler -PreviousHandler $previousHandler
        }

        [Microsoft.PowerShell.PSConsoleReadLine]::GetOptions().AddToHistoryHandler | Should -Be $originalHandler
    }

    It 'maintains REPL history separately from parent PSReadLine history' {
        Initialize-MsiLensReplHistory

        Add-MsiLensReplHistory 'info'
        Add-MsiLensReplHistory 'tables'
        Add-MsiLensReplHistory 'tables'

        $script:MsiLensReplHistory | Should -Be @('info', 'tables')
        $script:MsiLensReplHistoryIndex | Should -BeNullOrEmpty
        $script:MsiLensReplHistoryDraft | Should -Be ''
    }
}

Describe 'MsiLens REPL' {
    It 'starts empty, dispatches help, and exits cleanly' {
        $result = Invoke-MsiLensProcessForTest -Arguments @() -InputText "help`r`nexit`r`n"
        $result.ExitCode | Should -Be 0
        $result.AllOutput | Should -Match 'MsiLens>'
        $result.AllOutput | Should -Match 'Commands:'
        $result.AllOutput | Should -Not -Match 'REPL input must start with a MsiLens command'
        $result.AllOutput | Should -Not -Match 'InvalidArgument'
    }

    It 'supports both exit and quit commands' {
        $exitResult = Invoke-MsiLensProcessForTest -Arguments @() -InputText "exit`r`nhelp`r`n"
        $quitResult = Invoke-MsiLensProcessForTest -Arguments @() -InputText "quit`r`nhelp`r`n"

        $exitResult.ExitCode | Should -Be 0
        $exitResult.AllOutput | Should -Not -Match 'Commands:'
        $exitResult.AllOutput | Should -Not -Match 'REPL input must start with a MsiLens command'
        $exitResult.AllOutput | Should -Not -Match 'InvalidArgument'

        $quitResult.ExitCode | Should -Be 0
        $quitResult.AllOutput | Should -Not -Match 'Commands:'
        $quitResult.AllOutput | Should -Not -Match 'InvalidArgument'
    }

    It 'starts with an MSI path and dispatches scoped commands against it' {
        $result = Invoke-MsiLensProcessForTest -Arguments @($global:MsiLensPesterMsiPath) -InputText "tables`r`nexit`r`n"
        $result.ExitCode | Should -Be 0
        $result.AllOutput | Should -Match 'MsiLens .*\.msi>'
        $result.AllOutput | Should -Match 'Property'
    }

    It 'uses default PowerShell formatting for REPL output to match one-shot mode' {
        $oneShot = Invoke-MsiLensProcessForTest -Arguments @($global:MsiLensPesterMsiPath, 'info')
        $repl = Invoke-MsiLensProcessForTest -Arguments @($global:MsiLensPesterMsiPath) -InputText "info`r`nexit`r`n"

        $oneShot.ExitCode | Should -Be 0
        $repl.ExitCode | Should -Be 0
        $oneShot.AllOutput | Should -Match 'ProductVersion\s+:'
        $repl.AllOutput | Should -Match 'ProductVersion\s+:'
        $repl.AllOutput | Should -Not -Match 'ProductVersion\s+Manufacturer'
    }

    It 'pipes REPL command output through a trailing PowerShell pipeline' {
        $result = Invoke-MsiLensProcessForTest -Arguments @($global:MsiLensPesterMsiPath) -InputText "info | Select-Object -ExpandProperty ProductName`r`nexit`r`n"

        $result.ExitCode | Should -Be 0
        $result.AllOutput | Should -Match 'MsiLens Test Product'
        $result.AllOutput | Should -Not -Match 'does not accept extra arguments'
    }

    It 'supports format aliases in REPL pipelines' {
        $result = Invoke-MsiLensProcessForTest -Arguments @($global:MsiLensPesterMsiPath) -InputText "info | ft`r`nexit`r`n"

        $result.ExitCode | Should -Be 0
        $result.AllOutput | Should -Match 'ProductName\s+ProductVersion'
        $result.AllOutput | Should -Not -Match 'does not accept extra arguments'
    }

    It 'runs PowerShell statement continuations after REPL command output' {
        $result = Invoke-MsiLensProcessForTest -Arguments @($global:MsiLensPesterMsiPath) -InputText "info; Write-Output continuation-ok`r`nexit`r`n"

        $result.ExitCode | Should -Be 0
        $result.AllOutput | Should -Match 'ProductVersion\s+:'
        $result.AllOutput | Should -Match 'continuation-ok'
        $result.AllOutput | Should -Not -Match 'does not accept extra arguments'
    }

    It 'opens quoted paths, preserves context, closes context, and errors without an open package' {
        $spaceFixturePath = Join-Path ([System.IO.Path]::GetTempPath()) 'MsiLens Pester Fixture With Spaces.msi'
        $spaceFixture = @(& $global:MsiLensPesterFixtureScript -Path $spaceFixturePath)[-1]
        $inputText = ("open ""{0}""`r`nproperty ProductName`r`nclose`r`ninfo`r`nexit`r`n" -f $spaceFixture.Path)
        $result = Invoke-MsiLensProcessForTest -Arguments @() -InputText $inputText

        $result.ExitCode | Should -Be 0
        $result.AllOutput | Should -Match 'Opened'
        $result.AllOutput | Should -Match 'MsiLens Test Product'
        $result.AllOutput | Should -Match 'Closed'
        $result.AllOutput | Should -Match 'NoOpenPackage'
        # REPL-only commands must not fall through the switch to the unknown-command dispatcher.
        $result.AllOutput | Should -Not -Match "Unknown command 'open'"
        $result.AllOutput | Should -Not -Match "Unknown command 'close'"
    }

    It 'rejects unmatched quotes without changing MSI context' {
        $inputText = "open ""$global:MsiLensPesterMsiPath`r`ntables`r`nexit`r`n"
        $result = Invoke-MsiLensProcessForTest -Arguments @() -InputText $inputText

        $result.ExitCode | Should -Be 0
        $result.AllOutput | Should -Match 'InvalidArgument'
        $result.AllOutput | Should -Match 'NoOpenPackage'
    }

    It 'switches the active package when open is issued for a different MSI' {
        $secondPath = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensReplSwitch-{0}.msi" -f ([guid]::NewGuid().ToString('N')))
        $secondFixture = @(& $global:MsiLensPesterFixtureScript -Path $secondPath)[-1]
        try {
            $secondName = [System.IO.Path]::GetFileName($secondFixture.Path)
            $inputText = ("open ""{0}""`r`nopen ""{1}""`r`nexit`r`n" -f $global:MsiLensPesterMsiPath, $secondFixture.Path)
            $result = Invoke-MsiLensProcessForTest -Arguments @() -InputText $inputText

            $result.ExitCode | Should -Be 0
            # Both opens succeed; the second open replaces the first as the active context.
            $result.AllOutput | Should -Match ([regex]::Escape("Opened $($global:MsiLensPesterMsiPath)"))
            $result.AllOutput | Should -Match ([regex]::Escape("Opened $($secondFixture.Path)"))
            # The prompt context follows the most recently opened MSI, not the first.
            $result.AllOutput | Should -Match ([regex]::Escape("MsiLens $secondName>"))
            $result.AllOutput | Should -Not -Match "Unknown command"
            # The previously opened MSI must not stay locked after switching to another.
            $stream = [System.IO.File]::Open($global:MsiLensPesterMsiPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $stream.Close()
        } finally {
            if (Test-Path -LiteralPath $secondFixture.Path) {
                Remove-Item -LiteralPath $secondFixture.Path -Force
            }
        }
    }
}

Describe 'MsiLens process exit and serialization' {
    It 'returns a real process exit code for parser errors' {
        $result = Invoke-MsiLensProcessForTest -Arguments @('bogus')
        $result.ExitCode | Should -Be 2
    }

    It 'serializes structured signature output through ConvertTo-Json' {
        $escapedScriptPath = $global:MsiLensPesterScriptPath -replace "'", "''"
        $escapedMsiPath = $global:MsiLensPesterMsiPath -replace "'", "''"
        $command = "`$env:MSILENS_SUPPRESS_EXIT='1'; & '$escapedScriptPath' '$escapedMsiPath' signature | ConvertTo-Json -Depth 5"
        $result = Invoke-MsiLensProcessForTest -Command $command
        $result.ExitCode | Should -Be 0
        $result.AllOutput | Should -Match '"Status"'
        $signature = $result.AllOutput | ConvertFrom-Json
        @('NotSigned', 'Unsupported') | Should -Contain $signature.Status
    }
}
