
<#PSScriptInfo

.VERSION 0.1.2

.GUID C0D3600D-79DA-41EA-962F-EB139F9A2A47

.AUTHOR Vadim Dmitriev

.COMPANYNAME

.COPYRIGHT 2026 Vadim Dmitriev

.TAGS msi windows-installer inspection powershell cli

.LICENSEURI https://github.com/vdmdmv/MsiLens/blob/main/LICENSE

.PROJECTURI https://github.com/vdmdmv/MsiLens

.ICONURI

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS

.EXTERNALSCRIPTDEPENDENCIES

.RELEASENOTES


.PRIVATEDATA

#>

<# 

.DESCRIPTION 
 Read-only PowerShell tool for inspecting Windows Installer (MSI) packages. Query tables, properties, files, streams, cabinets, binaries, and signatures; extract file, binary, and cabinet payloads; and automate via one-shot commands or an interactive REPL 

#> 

#Requires -Version 5.1

<#
.SYNOPSIS
Inspects Windows Installer MSI packages without installing or extracting them.

.DESCRIPTION
MsiLens is a portable, read-only MSI inspection utility. It supports one-shot
subcommands and an interactive shell. Data-producing commands emit structured
PowerShell objects so callers can pipe results to ConvertTo-Json, Export-Csv,
Where-Object, and other standard PowerShell commands.

Commands:
  help [command]      Show global or command-specific help.
  version             Return version information.
  examples            Show usage examples.
  info                Return high-level package information.
  tables              List discovered MSI table names.
  columns <table>     Return column metadata for a table.
  table <table>       Return table rows. Supports -First <n>.
  properties          Return all MSI properties.
  property <name>     Return a single MSI property.
  files               Return File table metadata.
  file <id-or-name>   Return a single resolved File table entry.
  binaries            Return Binary table stream metadata.
  binary <name>       Return Binary table stream metadata by name.
  cabinets            Return embedded cabinet metadata.
  cabinet <name>      Return embedded cabinet metadata by authored or stream name.
  streams             Return understood safe artifact streams.
  extract-file        Extract matching File table payloads.
  extract-files       Extract filtered or all File table payloads.
  extract-binary      Extract one Binary table stream.
  extract-binaries    Extract filtered or all Binary table streams.
  extract-cabinet     Export one raw embedded cabinet stream.
  extract-cabinets    Export filtered or all raw embedded cabinet streams.
  signature           Inspect the package-level Authenticode signature.

Interactive REPL: run with no command (optionally with an MSI path) to start a
shell. REPL adds open <path>, close, and clear alongside the inspection
commands; type exit or quit to leave. Press Tab in the REPL to complete
commands, options, paths, table names, and property names.

Data commands return objects, not formatted text. Pipe to Format-Table,
ConvertTo-Json, Export-Csv, or other PowerShell commands to format or serialize.
The interactive REPL accepts trailing PowerShell syntax after a MsiLens command,
such as info | Format-Table or info; Get-Date.

.EXAMPLE
.\MsiLens.ps1 .\Product.msi tables

.EXAMPLE
.\MsiLens.ps1 -Path .\Product.msi table File -First 5

.EXAMPLE
.\MsiLens.ps1 .\Product.msi signature | ConvertTo-Json -Depth 5

.EXAMPLE
.\MsiLens.ps1 .\Product.msi
Starts the interactive REPL with Product.msi already open.

.NOTES
MVP security model: MSI databases are opened read-only. MsiLens does not invoke
msiexec, execute custom actions, or load package binaries. Extraction commands
copy package payload bytes only to caller-selected output directories.
Signature inspection is package-level Authenticode inspection only; it does not
prove installer behavior is safe.
#>

param(
    [string] $Path,
    [string] $Out,
    [string] $Layout,
    [switch] $DryRun,
    [switch] $Force,

    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [ArgumentCompleter({
        param($CommandName, $ParameterName, $WordToComplete, $CommandAst, $FakeBoundParameters)

        function Test-MsiLensCompleterPathLike {
            param([string] $Value)

            if ([string]::IsNullOrWhiteSpace($Value)) {
                return $false
            }

            $text = $Value.Trim("'`"")
            return ($text.EndsWith('.msi', [System.StringComparison]::OrdinalIgnoreCase) -or
                $text.Contains('\') -or
                $text.Contains('/') -or
                [System.IO.File]::Exists($text) -or
                [System.IO.Directory]::Exists($text))
        }

        $commandElements = @($CommandAst.CommandElements)
        $argumentTexts = @()
        for ($index = 1; $index -lt $commandElements.Count; $index++) {
            $argumentTexts += [string]$commandElements[$index].Extent.Text
        }

        if (-not [string]::IsNullOrEmpty($WordToComplete) -and
            $argumentTexts.Count -gt 0 -and
            $argumentTexts[$argumentTexts.Count - 1].Trim("'`"").StartsWith($WordToComplete, [System.StringComparison]::OrdinalIgnoreCase)) {
            $argumentTexts = @($argumentTexts | Select-Object -First ($argumentTexts.Count - 1))
        }

        $remaining = New-Object System.Collections.Generic.List[string]
        for ($index = 0; $index -lt $argumentTexts.Count; $index++) {
            $argument = $argumentTexts[$index]
            if ($argument -ieq '-Path') {
                if (($index + 1) -lt $argumentTexts.Count) {
                    $index++
                }
                continue
            }

            $remaining.Add($argument)
        }

        if ($remaining.Count -gt 0 -and (Test-MsiLensCompleterPathLike $remaining[0])) {
            $remaining.RemoveAt(0)
        }

        $commands = @('help', 'version', 'examples', 'info', 'tables', 'columns', 'table', 'properties', 'property', 'files', 'file', 'binaries', 'binary', 'cabinets', 'cabinet', 'streams', 'extract-file', 'extract-files', 'extract-binary', 'extract-binaries', 'extract-cabinet', 'extract-cabinets', 'signature')
        if ($remaining.Count -eq 1 -and $remaining[0].Trim("'`"") -ieq 'help') {
            foreach ($command in $commands) {
                if ([string]::IsNullOrEmpty($WordToComplete) -or $command.StartsWith($WordToComplete, [System.StringComparison]::OrdinalIgnoreCase)) {
                    New-Object System.Management.Automation.CompletionResult $command, $command, ([System.Management.Automation.CompletionResultType]::ParameterValue), $command
                }
            }
            return
        }

        if ($remaining.Count -gt 0) {
            return
        }

        foreach ($command in $commands) {
            if ([string]::IsNullOrEmpty($WordToComplete) -or $command.StartsWith($WordToComplete, [System.StringComparison]::OrdinalIgnoreCase)) {
                New-Object System.Management.Automation.CompletionResult $command, $command, ([System.Management.Automation.CompletionResultType]::ParameterValue), $command
            }
        }
    })]
    [string[]] $Arguments
)

Set-StrictMode -Version 2.0

$script:MsiLensVersion = '0.1.2'
$script:MsiLensProjectUrl = 'https://github.com/vdmdmv/MsiLens'
$script:MsiLensPathWasNamed = $PSBoundParameters.ContainsKey('Path')
$script:MsiLensPassThroughOptions = @()
if ($PSBoundParameters.ContainsKey('Out')) { $script:MsiLensPassThroughOptions += @('-Out', $Out) }
if ($PSBoundParameters.ContainsKey('Layout')) { $script:MsiLensPassThroughOptions += @('-Layout', $Layout) }
if ($PSBoundParameters.ContainsKey('DryRun')) { $script:MsiLensPassThroughOptions += @('-DryRun') }
if ($PSBoundParameters.ContainsKey('Force')) { $script:MsiLensPassThroughOptions += @('-Force') }
$script:MsiLensExitCode = 0
$script:MsiLensCompletionCurrentPath = $null
$script:MsiLensCompletionCycle = $null
$script:MsiLensCompletionCache = @{}

function Set-MsiLensExitCode {
    param([int] $ExitCode)
    $script:MsiLensExitCode = $ExitCode
}

function New-MsiLensObject {
    param(
        [string] $TypeName,
        [System.Collections.IDictionary] $Properties
    )

    $object = New-Object psobject
    $object.PSObject.TypeNames.Insert(0, $TypeName)
    foreach ($key in $Properties.Keys) {
        $null = $object | Add-Member -MemberType NoteProperty -Name $key -Value $Properties[$key]
    }
    $object
}

function New-MsiLensPlainObject {
    param([System.Collections.IDictionary] $Properties)

    $object = New-Object psobject
    foreach ($key in $Properties.Keys) {
        $null = $object | Add-Member -MemberType NoteProperty -Name $key -Value $Properties[$key]
    }
    $object
}

function Write-MsiLensError {
    param(
        [string] $Code,
        [string] $Message,
        [System.Management.Automation.ErrorCategory] $Category = [System.Management.Automation.ErrorCategory]::InvalidOperation
    )

    Write-Error -Message $Message -ErrorId $Code -Category $Category -ErrorAction Continue
}

function Test-MsiLensPathLike {
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    if ($Value -match '(?i)\.msi$') {
        return $true
    }
    if ($Value -match '[\\/]') {
        return $true
    }
    return (Test-Path -LiteralPath $Value)
}

function Resolve-MsiLensAlias {
    param([string] $Command)

    switch -Regex ($Command) {
        '^(?i)quit$' { 'exit'; return }
        default { $Command.ToLowerInvariant() }
    }
}

function Get-MsiLensGlobalCommands {
    @('help', 'version', 'examples')
}

function Get-MsiLensScopedCommands {
    @('info', 'tables', 'columns', 'table', 'properties', 'property', 'files', 'file', 'binaries', 'binary', 'cabinets', 'cabinet', 'streams', 'extract-file', 'extract-files', 'extract-binary', 'extract-binaries', 'extract-cabinet', 'extract-cabinets', 'signature')
}

function Test-MsiLensGlobalCommand {
    param([string] $Command)
    (Get-MsiLensGlobalCommands) -contains (Resolve-MsiLensAlias $Command)
}

function Resolve-MsiLensPath {
    param([string] $InputPath)

    if (-not (Test-Path -LiteralPath $InputPath)) {
        return $null
    }
    (Resolve-Path -LiteralPath $InputPath).ProviderPath
}

function Open-MsiLensDatabase {
    param([string] $MsiPath)

    $resolved = Resolve-MsiLensPath $MsiPath
    if ($null -eq $resolved) {
        throw (New-Object System.IO.FileNotFoundException("MSI path was not found.", $MsiPath))
    }

    $installer = New-Object -ComObject WindowsInstaller.Installer
    try {
        $database = $installer.OpenDatabase($resolved, 0)
    } catch {
        Remove-MsiLensComObject $installer
        throw
    }
    [pscustomobject]@{
        Installer = $installer
        Database  = $database
        Path      = $resolved
    }
}

function Remove-MsiLensComObject {
    param([object] $ComObject)

    if ($null -eq $ComObject) {
        return
    }
    try {
        if ([System.Runtime.InteropServices.Marshal]::IsComObject($ComObject)) {
            $null = [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ComObject)
        }
    } catch {
        Write-Verbose ("COM release failed: {0}" -f $_.Exception.Message)
    }
}

function Close-MsiLensDatabase {
    param([object] $Connection)

    if ($null -eq $Connection) {
        return
    }
    # Release the database handle before the installer so the underlying MSI
    # file lock is dropped promptly.
    foreach ($name in @('Database', 'Installer')) {
        $member = $Connection.PSObject.Properties[$name]
        if ($null -ne $member) {
            Remove-MsiLensComObject $member.Value
        }
    }
}

function Invoke-MsiLensSqlQuery {
    param(
        [object] $Connection,
        [string] $Sql,
        [string[]] $Columns,
        [Nullable[int]] $First = $null
    )

    $view = $Connection.Database.OpenView($Sql)
    try {
        $null = $view.Execute()

        # Classify result columns from MSI column metadata. The type string from
        # the View.ColumnInfo(MSICOLINFO_TYPES = 1) record starts with 'i'/'I' for
        # integer columns and 'v'/'V' for binary/stream columns ('s'/'S' string,
        # 'l'/'L' localizable string). Integers are emitted as [int]; stream
        # payloads are never read and are replaced with a '<binary>' placeholder.
        # Column ordinals align with the selected $Columns.
        $integerColumns = @{}
        $streamColumns = @{}
        $typeInfo = $null
        try {
            $typeInfo = $view.ColumnInfo(1)
            for ($typeIndex = 1; $typeIndex -le $Columns.Count; $typeIndex++) {
                $typeString = [string]$typeInfo.StringData($typeIndex)
                if ($typeString.Length -gt 0) {
                    $firstChar = $typeString[0]
                    if ('iI'.IndexOf($firstChar) -ge 0) {
                        $integerColumns[$typeIndex] = $true
                    } elseif ('vV'.IndexOf($firstChar) -ge 0) {
                        $streamColumns[$typeIndex] = $true
                    }
                }
            }
        } catch {
            $integerColumns = @{}
            $streamColumns = @{}
        } finally {
            Remove-MsiLensComObject $typeInfo
        }

        $emitted = 0
        while ($true) {
            if ($null -ne $First -and $emitted -ge [int]$First) {
                break
            }
            $row = $view.Fetch()
            if ($null -eq $row) {
                break
            }

            try {
                $values = [ordered]@{}
                for ($index = 1; $index -le $Columns.Count; $index++) {
                    $column = $Columns[$index - 1]
                    if ($streamColumns.ContainsKey($index)) {
                        $values[$column] = '<binary>'
                    } elseif ($row.IsNull($index)) {
                        $values[$column] = $null
                    } elseif ($integerColumns.ContainsKey($index)) {
                        $values[$column] = [int]$row.IntegerData($index)
                    } else {
                        # StringData throws on stream fields; if a column slipped
                        # past type classification, fall back to the placeholder
                        # so payload bytes are never emitted.
                        try {
                            $values[$column] = $row.StringData($index)
                        } catch {
                            $values[$column] = '<binary>'
                        }
                    }
                }
                New-MsiLensPlainObject $values
                $emitted++
            } finally {
                Remove-MsiLensComObject $row
            }
        }
    } finally {
        if ($null -ne $view) {
            try { $null = $view.Close() } catch { Write-Verbose ("View close failed: {0}" -f $_.Exception.Message) }
            Remove-MsiLensComObject $view
        }
    }
}

function Get-MsiLensTablesFromConnection {
    param([object] $Connection)

    Invoke-MsiLensSqlQuery -Connection $Connection -Sql "SELECT ``Name`` FROM ``_Tables``" -Columns @('Name') |
        Where-Object { $null -ne $_ } |
        ForEach-Object { $_.Name } |
        Sort-Object
}

function Resolve-MsiLensTableName {
    param(
        [object] $Connection,
        [string] $Table
    )

    $candidates = @(Get-MsiLensTablesFromConnection $Connection | Where-Object { $_ -ieq $Table })
    if ($candidates.Count -eq 0) {
        throw "Table '$Table' was not found."
    }
    if ($candidates.Count -gt 1) {
        throw ("Table name '{0}' is ambiguous. Candidates: {1}." -f $Table, ($candidates -join ', '))
    }
    $candidates[0]
}

function Resolve-MsiLensOptionalTableName {
    param(
        [object] $Connection,
        [string] $Table
    )

    $candidates = @(Get-MsiLensTablesFromConnection $Connection | Where-Object { $_ -ieq $Table })
    if ($candidates.Count -eq 0) {
        return $null
    }
    if ($candidates.Count -gt 1) {
        throw ("Table name '{0}' is ambiguous. Candidates: {1}." -f $Table, ($candidates -join ', '))
    }
    $candidates[0]
}

function Format-MsiLensSqlIdentifier {
    param([string] $Identifier)

    if ($Identifier -match '`') {
        throw "Invalid MSI identifier '$Identifier'."
    }
    '`{0}`' -f $Identifier
}

function Get-MsiLensColumnsFromConnection {
    param(
        [object] $Connection,
        [string] $Table
    )

    # Primary-key membership comes from Database.PrimaryKeys; column types come
    # from the view's MSICOLINFO_TYPES record. Both are derived from MSI metadata
    # rather than parsed out of the raw _Columns.Type bitmask.
    $primaryKeys = @{}
    $pkRecord = $null
    try {
        $pkRecord = $Connection.Database.PrimaryKeys($Table)
        for ($pkIndex = 1; $pkIndex -le $pkRecord.FieldCount(); $pkIndex++) {
            $primaryKeys[[string]$pkRecord.StringData($pkIndex)] = $true
        }
    } catch {
        Write-Verbose ("PrimaryKeys lookup failed for '{0}': {1}" -f $Table, $_.Exception.Message)
    } finally {
        Remove-MsiLensComObject $pkRecord
    }

    $quoted = Format-MsiLensSqlIdentifier $Table
    $view = $Connection.Database.OpenView("SELECT * FROM $quoted")
    $names = $null
    $types = $null
    try {
        $null = $view.Execute()
        $names = $view.ColumnInfo(0)
        $types = $view.ColumnInfo(1)
        for ($index = 1; $index -le $names.FieldCount(); $index++) {
            $columnName = [string]$names.StringData($index)
            $typeString = [string]$types.StringData($index)
            # An uppercase leading type letter (for example S, I, V) marks a
            # nullable column; lowercase (s, i, v) marks a required column.
            $nullable = ($typeString.Length -gt 0) -and [char]::IsUpper($typeString[0])
            [pscustomobject]@{
                Name       = $columnName
                Number     = $index
                Type       = $typeString
                Nullable   = $nullable
                PrimaryKey = $primaryKeys.ContainsKey($columnName)
            }
        }
    } finally {
        Remove-MsiLensComObject $names
        Remove-MsiLensComObject $types
        if ($null -ne $view) {
            try { $null = $view.Close() } catch { Write-Verbose ("View close failed: {0}" -f $_.Exception.Message) }
            Remove-MsiLensComObject $view
        }
    }
}

function ConvertTo-MsiLensColumnMetadata {
    param(
        [string] $Table,
        [object] $Column
    )

    New-MsiLensObject 'MsiLens.ColumnInfo' ([ordered]@{
        Table      = $Table
        Column     = $Column.Name
        Number     = [int]$Column.Number
        Type       = $Column.Type
        Nullable   = $Column.Nullable
        PrimaryKey = $Column.PrimaryKey
    })
}

function Get-MsiLensSafeColumnPropertyName {
    param([string] $Column)

    $reserved = @('PSTypeName', 'MsiPath', 'Row', 'Data')
    if (($Column -match '^[A-Za-z_][A-Za-z0-9_]*$') -and ($reserved -notcontains $Column)) {
        return $Column
    }

    $sanitized = [regex]::Replace($Column, '[^A-Za-z0-9_]', '_')
    if ($sanitized -notmatch '^[A-Za-z_]') {
        $sanitized = '_' + $sanitized
    }
    'MsiColumn_{0}' -f $sanitized
}

function Get-MsiLensUniquePropertyName {
    param(
        [string] $PropertyName,
        [hashtable] $Emitted
    )

    $candidate = $PropertyName
    $suffix = 2
    while ($Emitted.ContainsKey($candidate)) {
        $candidate = '{0}_{1}' -f $PropertyName, $suffix
        $suffix++
    }

    $Emitted[$candidate] = $true
    $candidate
}

function New-MsiLensTableRow {
    param(
        [int] $RowNumber,
        [object] $Row,
        [string[]] $Columns
    )

    $data = [ordered]@{}
    $properties = [ordered]@{
        Row = $RowNumber
    }
    $emittedProperties = @{}
    foreach ($propertyName in $properties.Keys) {
        $emittedProperties[$propertyName] = $true
    }
    $includeData = $false

    foreach ($column in $Columns) {
        $property = $Row.PSObject.Properties[$column]
        if ($null -eq $property) {
            $value = $null
        } else {
            $value = $property.Value
        }
        $data[$column] = $value
        $propertyName = Get-MsiLensUniquePropertyName -PropertyName (Get-MsiLensSafeColumnPropertyName $column) -Emitted $emittedProperties
        if ($propertyName -ne $column) {
            $includeData = $true
        }
        $properties[$propertyName] = $value
    }

    if ($includeData) {
        $properties['Data'] = $data
    }
    New-MsiLensObject 'MsiLens.TableRow' $properties
}

function Get-MsiLensTableRowsFromConnection {
    param(
        [object] $Connection,
        [string] $Table,
        [Nullable[int]] $First
    )

    $resolvedTable = Resolve-MsiLensTableName -Connection $Connection -Table $Table
    $columns = @(Get-MsiLensColumnsFromConnection -Connection $Connection -Table $resolvedTable)
    $columnNames = @($columns | ForEach-Object { $_.Name })

    # Binary/stream columns are detected from MSI column types inside
    # Invoke-MsiLensSqlQuery, so no table is special-cased here.
    $quoted = Format-MsiLensSqlIdentifier $resolvedTable
    $quotedColumns = @($columnNames | ForEach-Object { Format-MsiLensSqlIdentifier $_ }) -join ', '
    $rows = Invoke-MsiLensSqlQuery -Connection $Connection -Sql "SELECT $quotedColumns FROM $quoted" -Columns $columnNames -First $First
    $rowNumber = 0
    foreach ($row in $rows) {
        $rowNumber++
        New-MsiLensTableRow -RowNumber $rowNumber -Row $row -Columns $columnNames
    }
}

function Get-MsiLensPropertiesFromConnection {
    param([object] $Connection)

    $table = Resolve-MsiLensOptionalTableName -Connection $Connection -Table 'Property'
    if ($null -eq $table) {
        return
    }

    $quoted = Format-MsiLensSqlIdentifier $table
    $rows = Invoke-MsiLensSqlQuery -Connection $Connection -Sql "SELECT ``Property``, ``Value`` FROM $quoted" -Columns @('Property', 'Value')
    foreach ($row in ($rows | Sort-Object -Property Property)) {
        New-MsiLensObject 'MsiLens.Property' ([ordered]@{
            Property = $row.Property
            Value    = $row.Value
        })
    }
}

function Get-MsiLensPropertyMap {
    param([object] $Connection)

    $map = @{}
    foreach ($property in Get-MsiLensPropertiesFromConnection $Connection) {
        $map[$property.Property] = $property.Value
    }
    $map
}

function Get-MsiLensPackageCode {
    param([object] $Connection)

    $summary = $null
    try {
        $summary = $Connection.Database.SummaryInformation(0)
        $revision = $summary.Property(9)
        if ([string]::IsNullOrWhiteSpace($revision)) {
            return $null
        }
        $revision
    } catch {
        $null
    } finally {
        Remove-MsiLensComObject $summary
    }
}

function Get-MsiLensCertificateEnhancedKeyUsages {
    param([object] $Certificate)

    if ($null -eq $Certificate) {
        return @()
    }

    try {
        $items = @()
        foreach ($usage in $Certificate.EnhancedKeyUsageList) {
            if (-not [string]::IsNullOrWhiteSpace($usage.FriendlyName)) {
                $items += $usage.FriendlyName
            } elseif (-not [string]::IsNullOrWhiteSpace($usage.ObjectId.Value)) {
                $items += $usage.ObjectId.Value
            }
        }
        return $items
    } catch {
        return @()
    }
}

function New-MsiLensSignatureObject {
    param(
        [Nullable[bool]] $IsSigned,
        [Nullable[bool]] $IsValid,
        [string] $Status,
        [string] $StatusMessage,
        [object] $SignerCertificate,
        [object] $TimestampCertificate,
        [object] $TimestampTime = $null
    )

    New-MsiLensObject 'MsiLens.Signature' ([ordered]@{
        Scope                    = 'PackageAuthenticode'
        TrustScope               = 'PackageSignature'
        TrustLimitations         = 'Package-level signature validation does not prove installer behavior is safe.'
        IsSigned                 = $IsSigned
        IsValid                  = $IsValid
        Status                   = $Status
        StatusMessage            = $StatusMessage
        SignerSubject            = if ($null -ne $SignerCertificate) { $SignerCertificate.Subject } else { $null }
        SignerIssuer             = if ($null -ne $SignerCertificate) { $SignerCertificate.Issuer } else { $null }
        SignerSerialNumber       = if ($null -ne $SignerCertificate) { $SignerCertificate.SerialNumber } else { $null }
        SignerThumbprint         = if ($null -ne $SignerCertificate) { $SignerCertificate.Thumbprint } else { $null }
        SignerNotBefore          = if ($null -ne $SignerCertificate) { $SignerCertificate.NotBefore } else { $null }
        SignerNotAfter           = if ($null -ne $SignerCertificate) { $SignerCertificate.NotAfter } else { $null }
        SignerEnhancedKeyUsages  = @(Get-MsiLensCertificateEnhancedKeyUsages $SignerCertificate)
        TimestampSubject         = if ($null -ne $TimestampCertificate) { $TimestampCertificate.Subject } else { $null }
        TimestampTime            = $TimestampTime
    })
}

function Get-MsiLensSignature {
    param([string] $MsiPath)

    if ($null -eq (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) {
        $unsupported = New-MsiLensSignatureObject -IsSigned $null -IsValid $null -Status 'Unsupported' -StatusMessage 'Get-AuthenticodeSignature is not available.' -SignerCertificate $null -TimestampCertificate $null
        return [pscustomobject]@{ Signature = $unsupported; InspectionFailed = $false }
    }

    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $MsiPath
    } catch {
        # A thrown error is an unexpected inspection failure (exit 6), distinct
        # from a returned 'UnknownError' status, which is a data result (exit 0).
        $failed = New-MsiLensSignatureObject -IsSigned $null -IsValid $null -Status 'UnknownError' -StatusMessage $_.Exception.Message -SignerCertificate $null -TimestampCertificate $null
        return [pscustomobject]@{ Signature = $failed; InspectionFailed = $true }
    }

    $status = [string]$signature.Status
    $signer = $signature.SignerCertificate
    $timestamp = $signature.TimeStamperCertificate
    $statusMessage = [string]$signature.StatusMessage

    $isSigned = $null
    $isValid = $null

    switch ($status) {
        'Valid' {
            $isSigned = $true
            $isValid = $true
        }
        'NotSigned' {
            $isSigned = $false
            $isValid = $false
        }
        'HashMismatch' {
            $isSigned = $true
            $isValid = $false
        }
        'NotTrusted' {
            $isSigned = $true
            $isValid = $false
        }
        default {
            $isSigned = ($null -ne $signer)
            $isValid = $false
        }
    }

    $object = New-MsiLensSignatureObject -IsSigned $isSigned -IsValid $isValid -Status $status -StatusMessage $statusMessage -SignerCertificate $signer -TimestampCertificate $timestamp
    [pscustomobject]@{ Signature = $object; InspectionFailed = $false }
}

function Get-MsiLensSignatureSummary {
    param([string] $MsiPath)

    $result = Get-MsiLensSignature $MsiPath
    [pscustomobject]@{
        IsSigned = $result.Signature.IsSigned
        Status   = $result.Signature.Status
    }
}

function Get-MsiLensInfo {
    param([object] $Connection)

    $properties = Get-MsiLensPropertyMap $Connection
    $tables = @(Get-MsiLensTablesFromConnection $Connection)
    $signature = Get-MsiLensSignatureSummary $Connection.Path

    New-MsiLensObject 'MsiLens.PackageInfo' ([ordered]@{
        ProductName      = $properties['ProductName']
        ProductVersion   = $properties['ProductVersion']
        ProductCode      = $properties['ProductCode']
        Manufacturer     = $properties['Manufacturer']
        PackageCode      = Get-MsiLensPackageCode $Connection
        TableCount       = $tables.Count
        IsSigned         = $signature.IsSigned
        SignatureStatus  = $signature.Status
    })
}

function Split-MsiLensFileName {
    param([string] $RawFileName)

    if ($null -eq $RawFileName) {
        return [pscustomobject]@{ Short = $null; Long = $null; Canonical = $null }
    }

    $separator = $RawFileName.IndexOf('|')
    if ($separator -ge 0) {
        $short = $RawFileName.Substring(0, $separator)
        $long = $RawFileName.Substring($separator + 1)
        if ($long -eq '') {
            $long = $null
        }
        $canonical = if ($null -ne $long) { $long } else { $short }
        return [pscustomobject]@{ Short = $short; Long = $long; Canonical = $canonical }
    }

    [pscustomobject]@{ Short = $RawFileName; Long = $null; Canonical = $RawFileName }
}

function ConvertTo-MsiLensFileInfo {
    param(
        [object] $Row
    )

    $names = Split-MsiLensFileName $Row.FileName
    New-MsiLensObject 'MsiLens.FileInfo' ([ordered]@{
        File          = $Row.File
        Component     = $Row.Component_
        RawFileName   = $Row.FileName
        FileName      = $names.Canonical
        ShortFileName = $names.Short
        LongFileName  = $names.Long
        FileSize      = $Row.FileSize
        Version       = $Row.Version
        Language      = $Row.Language
        Attributes    = $Row.Attributes
        Sequence      = $Row.Sequence
    })
}

function Get-MsiLensFilesFromConnection {
    param([object] $Connection)

    $table = Resolve-MsiLensOptionalTableName -Connection $Connection -Table 'File'
    if ($null -eq $table) {
        return
    }

    $quoted = Format-MsiLensSqlIdentifier $table
    $rows = Invoke-MsiLensSqlQuery -Connection $Connection -Sql "SELECT ``File``, ``Component_``, ``FileName``, ``FileSize``, ``Version``, ``Language``, ``Attributes``, ``Sequence`` FROM $quoted ORDER BY ``Sequence``" -Columns @('File', 'Component_', 'FileName', 'FileSize', 'Version', 'Language', 'Attributes', 'Sequence')
    foreach ($row in $rows) {
        ConvertTo-MsiLensFileInfo -Row $row
    }
}

function Resolve-MsiLensFile {
    param(
        [object[]] $Files,
        [string] $Query
    )

    $steps = @(
        { param($f, $q) $f.File -ieq $q },
        { param($f, $q) $f.LongFileName -ieq $q },
        { param($f, $q) $f.ShortFileName -ieq $q },
        { param($f, $q) $f.RawFileName -ieq $q },
        { param($f, $q) $f.FileName -ieq $q }
    )

    foreach ($step in $steps) {
        $candidates = @($Files | Where-Object { & $step $_ $Query })
        if ($candidates.Count -eq 1) {
            return [pscustomobject]@{ Status = 'Match'; File = $candidates[0]; Candidates = @() }
        }
        if ($candidates.Count -gt 1) {
            return [pscustomobject]@{ Status = 'Ambiguous'; File = $null; Candidates = @($candidates | ForEach-Object { $_.File }) }
        }
    }

    [pscustomobject]@{ Status = 'NotFound'; File = $null; Candidates = @() }
}

function Test-MsiLensTableColumns {
    param(
        [object] $Connection,
        [string] $Table,
        [string[]] $RequiredColumns
    )

    $columns = @(Get-MsiLensColumnsFromConnection -Connection $Connection -Table $Table | ForEach-Object { $_.Name })
    foreach ($required in $RequiredColumns) {
        if (@($columns | Where-Object { $_ -ieq $required }).Count -eq 0) {
            throw (New-Object System.InvalidOperationException("Missing required column '$required' in table '$Table'."))
        }
    }
}

function Get-MsiLensStreamSize {
    param(
        [object] $Connection,
        [string] $Table,
        [string] $KeyColumn,
        [string] $DataColumn,
        [string] $Key
    )

    $record = $Connection.Installer.CreateRecord(1)
    $record.StringData(1) = $Key
    $view = $null
    $row = $null
    try {
        $quotedTable = Format-MsiLensSqlIdentifier $Table
        $quotedKey = Format-MsiLensSqlIdentifier $KeyColumn
        $quotedData = Format-MsiLensSqlIdentifier $DataColumn
        $view = $Connection.Database.OpenView("SELECT $quotedData FROM $quotedTable WHERE $quotedKey = ?")
        $null = $view.Execute($record)
        $row = $view.Fetch()
        if ($null -eq $row) {
            return $null
        }
        # Use Record.DataSize for a cheap metadata size lookup. Listing,
        # metadata, and completion commands depend on this NEVER materializing
        # payload bytes (binary/cabinet spec: streams are not read for listing,
        # and completion must not read raw stream bytes). Do not replace this
        # with a ReadStream loop.
        return [int64]$row.DataSize(1)
    } catch {
        return $null
    } finally {
        Remove-MsiLensComObject $row
        Remove-MsiLensComObject $record
        if ($null -ne $view) {
            try { $null = $view.Close() } catch { Write-Verbose ("View close failed: {0}" -f $_.Exception.Message) }
            Remove-MsiLensComObject $view
        }
    }
}

function Get-MsiLensBinaryRecords {
    param([object] $Connection)

    $table = Resolve-MsiLensOptionalTableName -Connection $Connection -Table 'Binary'
    if ($null -eq $table) {
        return
    }
    Test-MsiLensTableColumns -Connection $Connection -Table $table -RequiredColumns @('Name', 'Data')

    $quoted = Format-MsiLensSqlIdentifier $table
    $rows = Invoke-MsiLensSqlQuery -Connection $Connection -Sql "SELECT ``Name`` FROM $quoted ORDER BY ``Name``" -Columns @('Name')
    foreach ($row in $rows) {
        $name = [string]$row.Name
        New-MsiLensObject 'MsiLens.BinaryInfo' ([ordered]@{
            Name           = $name
            Table          = 'Binary'
            SourceKind     = 'BinaryTable'
            Size           = Get-MsiLensStreamSize -Connection $Connection -Table $table -KeyColumn 'Name' -DataColumn 'Data' -Key $name
            CanExtract     = $true
            Warnings       = @()
            AmbiguousMatch = $false
        })
    }
}

function Get-MsiLensEmbeddedCabinetRecords {
    param([object] $Connection)

    $table = Resolve-MsiLensOptionalTableName -Connection $Connection -Table 'Media'
    if ($null -eq $table) {
        return
    }
    Test-MsiLensTableColumns -Connection $Connection -Table $table -RequiredColumns @('DiskId', 'LastSequence', 'Cabinet')

    $quoted = Format-MsiLensSqlIdentifier $table
    $rows = Invoke-MsiLensSqlQuery -Connection $Connection -Sql "SELECT ``DiskId``, ``LastSequence``, ``Cabinet`` FROM $quoted ORDER BY ``DiskId``" -Columns @('DiskId', 'LastSequence', 'Cabinet')
    foreach ($row in $rows) {
        $cabinet = [string]$row.Cabinet
        if ([string]::IsNullOrWhiteSpace($cabinet) -or -not $cabinet.StartsWith('#', [System.StringComparison]::Ordinal)) {
            continue
        }
        $streamName = $cabinet.Substring(1)
        $exists = Test-MsiLensEmbeddedCabinetStream -Connection $Connection -StreamName $streamName
        $warnings = @()
        if (-not $exists) {
            $warnings += 'MissingSource'
        }
        New-MsiLensObject 'MsiLens.CabinetInfo' ([ordered]@{
            Cabinet        = $cabinet
            StreamName     = $streamName
            SourceKind     = 'EmbeddedCabinet'
            DiskId         = $row.DiskId
            LastSequence   = $row.LastSequence
            Size           = if ($exists) { Get-MsiLensStreamSize -Connection $Connection -Table '_Streams' -KeyColumn 'Name' -DataColumn 'Data' -Key $streamName } else { $null }
            CanExtract     = [bool]$exists
            Warnings       = @($warnings)
            AmbiguousMatch = $false
        })
    }
}

function Get-MsiLensBinaryMatchFields {
    param(
        [object] $Binary,
        [string] $Pattern,
        [switch] $Wildcard
    )

    if ($Wildcard) {
        if ($Binary.Name -like $Pattern) { return @('Name') }
        return @()
    }
    if ($Binary.Name -ieq $Pattern) { return @('Name') }
    @()
}

function Get-MsiLensCabinetMatchFields {
    param(
        [object] $Cabinet,
        [string] $Pattern,
        [switch] $Wildcard
    )

    $fields = New-Object System.Collections.ArrayList
    if ($Wildcard) {
        if ($Cabinet.Cabinet -like $Pattern) { [void]$fields.Add('Cabinet') }
        if ($Cabinet.StreamName -like $Pattern) { [void]$fields.Add('StreamName') }
    } else {
        if ($Cabinet.Cabinet -ieq $Pattern) { [void]$fields.Add('Cabinet') }
        if ($Cabinet.StreamName -ieq $Pattern) { [void]$fields.Add('StreamName') }
    }
    [string[]]$fields.ToArray([string])
}

function Resolve-MsiLensArtifactSelection {
    param(
        [object[]] $Artifacts,
        [hashtable] $Options,
        [string] $Kind
    )

    $items = New-Object System.Collections.ArrayList
    if ($Options.Mode -eq 'All') {
        foreach ($artifact in $Artifacts) {
            [void]$items.Add([pscustomobject]@{ Artifact = $artifact; MatchedFields = @('All') })
        }
        return [pscustomobject]@{ Items = @($items.ToArray()); Ambiguous = $false }
    }

    foreach ($artifact in $Artifacts) {
        $fields = if ($Kind -eq 'Binary') {
            @(Get-MsiLensBinaryMatchFields -Binary $artifact -Pattern $(if ($Options.Mode -eq 'Filter') { $Options.Filter } else { $Options.Query }) -Wildcard:($Options.Mode -eq 'Filter'))
        } else {
            @(Get-MsiLensCabinetMatchFields -Cabinet $artifact -Pattern $(if ($Options.Mode -eq 'Filter') { $Options.Filter } else { $Options.Query }) -Wildcard:($Options.Mode -eq 'Filter'))
        }
        $fieldList = @($fields)
        if ($fieldList.Count -gt 0) {
            [void]$items.Add([pscustomobject]@{ Artifact = $artifact; MatchedFields = $fieldList })
        }
    }
    [pscustomobject]@{ Items = @($items.ToArray()); Ambiguous = ($Options.Mode -eq 'Single' -and $items.Count -gt 1) }
}

function Get-MsiLensRequiredExtractionTable {
    param(
        [object] $Connection,
        [string] $Table
    )

    $resolved = Resolve-MsiLensOptionalTableName -Connection $Connection -Table $Table
    if ($null -eq $resolved) {
        throw (New-Object System.InvalidOperationException("Missing required extraction table '$Table'."))
    }
    $resolved
}

function Get-MsiLensExtractionComponents {
    param([object] $Connection)

    $table = Get-MsiLensRequiredExtractionTable -Connection $Connection -Table 'Component'
    $quoted = Format-MsiLensSqlIdentifier $table
    $rows = Invoke-MsiLensSqlQuery -Connection $Connection -Sql "SELECT ``Component``, ``Directory_`` FROM $quoted" -Columns @('Component', 'Directory_')
    $map = @{}
    foreach ($row in $rows) {
        $map[[string]$row.Component] = $row
    }
    $map
}

function Get-MsiLensExtractionDirectories {
    param([object] $Connection)

    $table = Get-MsiLensRequiredExtractionTable -Connection $Connection -Table 'Directory'
    $quoted = Format-MsiLensSqlIdentifier $table
    $rows = Invoke-MsiLensSqlQuery -Connection $Connection -Sql "SELECT ``Directory``, ``Directory_Parent``, ``DefaultDir`` FROM $quoted" -Columns @('Directory', 'Directory_Parent', 'DefaultDir')
    $map = @{}
    foreach ($row in $rows) {
        $map[[string]$row.Directory] = $row
    }
    $map
}

function Get-MsiLensExtractionMediaRows {
    param([object] $Connection)

    $table = Get-MsiLensRequiredExtractionTable -Connection $Connection -Table 'Media'
    $quoted = Format-MsiLensSqlIdentifier $table
    @(Invoke-MsiLensSqlQuery -Connection $Connection -Sql "SELECT ``DiskId``, ``LastSequence``, ``DiskPrompt``, ``Cabinet``, ``VolumeLabel``, ``Source`` FROM $quoted ORDER BY ``DiskId``" -Columns @('DiskId', 'LastSequence', 'DiskPrompt', 'Cabinet', 'VolumeLabel', 'Source'))
}

function Get-MsiLensFileMatchFields {
    param(
        [object] $File,
        [string] $Pattern,
        [switch] $Wildcard
    )

    $fields = New-Object System.Collections.ArrayList
    foreach ($name in @('File', 'FileName', 'ShortFileName', 'LongFileName', 'RawFileName')) {
        $property = $File.PSObject.Properties[$name]
        if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            continue
        }
        $value = [string]$property.Value
        if (($Wildcard -and ($value -like $Pattern)) -or ((-not $Wildcard) -and ($value -ieq $Pattern))) {
            [void]$fields.Add($name)
        }
    }
    [string[]]$fields.ToArray([string])
}

function Resolve-MsiLensExtractionSelection {
    param(
        [object[]] $Files,
        [hashtable] $Options
    )

    $selected = New-Object System.Collections.ArrayList
    if ($Options.Mode -eq 'Single') {
        foreach ($file in $Files) {
            $fields = @(Get-MsiLensFileMatchFields -File $file -Pattern $Options.Query)
            if ($fields.Count -gt 0) {
                [void]$selected.Add([pscustomobject]@{ File = $file; MatchedFields = $fields })
            }
        }
        return [pscustomobject]@{ Items = @($selected.ToArray()); Ambiguous = ($selected.Count -gt 1) }
    }

    if ($Options.Mode -eq 'Filter') {
        foreach ($file in $Files) {
            $fields = @(Get-MsiLensFileMatchFields -File $file -Pattern $Options.Filter -Wildcard)
            if ($fields.Count -gt 0) {
                [void]$selected.Add([pscustomobject]@{ File = $file; MatchedFields = $fields })
            }
        }
        return [pscustomobject]@{ Items = @($selected.ToArray()); Ambiguous = $false }
    }

    foreach ($file in $Files) {
        [void]$selected.Add([pscustomobject]@{ File = $file; MatchedFields = @('All') })
    }
    [pscustomobject]@{ Items = @($selected.ToArray()); Ambiguous = $false }
}

function Split-MsiLensDirectoryName {
    param(
        [string] $DefaultDir,
        [switch] $SourceName
    )

    if ([string]::IsNullOrWhiteSpace($DefaultDir) -or $DefaultDir -eq '.') {
        return $null
    }
    $parts = $DefaultDir -split ':', 2
    $namePart = if ($SourceName -and $parts.Count -eq 2) { $parts[1] } else { $parts[0] }
    $names = Split-MsiLensFileName $namePart
    $names.Canonical
}

function Resolve-MsiLensDirectorySegments {
    param(
        [string] $DirectoryId,
        [hashtable] $Directories,
        [switch] $SourceName
    )

    $segments = New-Object System.Collections.ArrayList
    $seen = @{}
    $current = $DirectoryId
    while (-not [string]::IsNullOrWhiteSpace($current) -and $Directories.ContainsKey($current) -and -not $seen.ContainsKey($current)) {
        $seen[$current] = $true
        $row = $Directories[$current]
        $name = Split-MsiLensDirectoryName -DefaultDir $row.DefaultDir -SourceName:$SourceName
        if (-not [string]::IsNullOrWhiteSpace($name) -and $name -ne 'SourceDir') {
            [void]$segments.Insert(0, $name)
        }
        $current = [string]$row.Directory_Parent
    }
    [string[]]$segments.ToArray([string])
}

function Test-MsiLensRootedOrTraversalSegment {
    param([string] $Segment)

    if ([string]::IsNullOrWhiteSpace($Segment)) {
        return $false
    }
    if ([System.IO.Path]::IsPathRooted($Segment) -or $Segment -match '^[A-Za-z]:') {
        return $true
    }
    if ($Segment -match '(^|[\\/])\.\.($|[\\/])' -or $Segment -eq '..') {
        return $true
    }
    if ($Segment -match '^[^\\/]+:') {
        return $true
    }
    $false
}

function Test-MsiLensUnsafeRelativePathText {
    param([string] $PathText)

    if ([string]::IsNullOrWhiteSpace($PathText)) {
        return $true
    }
    if ($PathText.StartsWith('\\', [System.StringComparison]::Ordinal) -or
        $PathText.StartsWith('//', [System.StringComparison]::Ordinal) -or
        [System.IO.Path]::IsPathRooted($PathText)) {
        return $true
    }
    if ($PathText -match ':' -or $PathText -eq '..' -or $PathText -match '(^|[\\/])\.\.($|[\\/])') {
        return $true
    }
    $false
}

function ConvertTo-MsiLensSafePathSegment {
    param([string] $Segment)

    $warnings = New-Object System.Collections.ArrayList
    $original = $Segment
    if ([string]::IsNullOrWhiteSpace($Segment) -or $Segment -eq '.' -or $Segment -eq '..') {
        $Segment = '_'
        [void]$warnings.Add('EmptySegmentSanitized')
    }

    $invalid = [regex]::Escape((-join [System.IO.Path]::GetInvalidFileNameChars()))
    $clean = [regex]::Replace($Segment, "[$invalid]", '_')
    if ($clean -ne $Segment) {
        [void]$warnings.Add('InvalidCharacterSanitized')
    }
    $trimmed = $clean.TrimEnd(' ', '.')
    if ($trimmed -ne $clean) {
        [void]$warnings.Add('TrailingCharacterSanitized')
    }
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        $trimmed = '_'
        [void]$warnings.Add('EmptySegmentSanitized')
    }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($trimmed)
    if ($base -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        $trimmed = "_$trimmed"
        [void]$warnings.Add('ReservedNameSanitized')
    }

    [pscustomobject]@{
        Original  = $original
        Safe      = $trimmed
        Changed   = ($original -ne $trimmed)
        Warnings  = [string[]]$warnings.ToArray([string])
    }
}

function Resolve-MsiLensSafeRelativePath {
    param(
        [string[]] $Segments,
        [string] $OutputRoot
    )

    $warnings = New-Object System.Collections.ArrayList
    $changed = New-Object System.Collections.ArrayList
    $safeSegments = New-Object System.Collections.ArrayList
    foreach ($segment in $Segments) {
        if (Test-MsiLensRootedOrTraversalSegment $segment) {
            return [pscustomobject]@{ Safe = $false; Warning = 'UnsafeOutputPath' }
        }
        $safe = ConvertTo-MsiLensSafePathSegment $segment
        [void]$safeSegments.Add($safe.Safe)
        foreach ($warning in $safe.Warnings) { [void]$warnings.Add($warning) }
        if ($safe.Changed) {
            [void]$changed.Add([pscustomobject]@{ Original = $safe.Original; Sanitized = $safe.Safe })
        }
    }

    $relative = [System.IO.Path]::Combine([string[]]$safeSegments.ToArray([string]))
    $root = [System.IO.Path]::GetFullPath($OutputRoot)
    $output = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $relative))
    $rootWithSlash = $root.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not ($output.StartsWith($rootWithSlash, [System.StringComparison]::OrdinalIgnoreCase) -or $output -ieq $root)) {
        return [pscustomobject]@{ Safe = $false; Warning = 'UnsafeOutputPath' }
    }

    [pscustomobject]@{
        Safe                = $true
        RelativePath        = $relative
        OutputPath          = $output
        Sanitized           = ($changed.Count -gt 0)
        ChangedPathSegments = @($changed.ToArray())
        Warnings            = [string[]]$warnings.ToArray([string])
    }
}

function Resolve-MsiLensArtifactOutputPath {
    param(
        [string] $OutputName,
        [string] $OutputRoot
    )

    if ($null -ne $OutputName -and $OutputName -match '[\\/]') {
        return [pscustomobject]@{ Safe = $false; Warning = 'UnsafeOutputPath' }
    }
    $pathInfo = Resolve-MsiLensSafeRelativePath -Segments @($OutputName) -OutputRoot $OutputRoot
    if ($pathInfo.Safe) {
        $pathInfo | Add-Member -MemberType NoteProperty -Name OriginalSegments -Value @($OutputName)
    }
    $pathInfo
}

function Resolve-MsiLensMediaForFile {
    param(
        [object] $File,
        [object[]] $MediaRows
    )

    $sequence = 0
    if ($null -eq $File.Sequence -or -not [int]::TryParse([string]$File.Sequence, [ref]$sequence) -or $sequence -lt 1) {
        return [pscustomobject]@{ Status = 'Unsupported'; Warning = 'UnsupportedMediaLayout' }
    }
    $previous = 0
    foreach ($media in ($MediaRows | Sort-Object -Property DiskId)) {
        $last = 0
        if (-not [int]::TryParse([string]$media.LastSequence, [ref]$last) -or $last -le $previous) {
            return [pscustomobject]@{ Status = 'Unsupported'; Warning = 'UnsupportedMediaLayout' }
        }
        if ($sequence -gt $previous -and $sequence -le $last) {
            foreach ($field in @('DiskPrompt', 'VolumeLabel', 'Source')) {
                $property = $media.PSObject.Properties[$field]
                if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    return [pscustomobject]@{ Status = 'Unsupported'; Warning = 'UnsupportedMediaLayout' }
                }
            }
            return [pscustomobject]@{ Status = 'Match'; Media = $media }
        }
        $previous = $last
    }
    [pscustomobject]@{ Status = 'Unsupported'; Warning = 'UnsupportedMediaLayout' }
}

function Resolve-MsiLensContainedPath {
    param(
        [string] $Root,
        [string[]] $Segments
    )

    foreach ($segment in $Segments) {
        if (Test-MsiLensRootedOrTraversalSegment $segment) {
            return $null
        }
    }
    $rootPath = [System.IO.Path]::GetFullPath($Root)
    $combinedRaw = $rootPath
    foreach ($segment in $Segments) {
        $combinedRaw = [System.IO.Path]::Combine($combinedRaw, $segment)
    }
    $combined = [System.IO.Path]::GetFullPath($combinedRaw)
    $rootWithSlash = $rootPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if ($combined.StartsWith($rootWithSlash, [System.StringComparison]::OrdinalIgnoreCase) -or $combined -ieq $rootPath) {
        return $combined
    }
    $null
}

function Resolve-MsiLensExtractionSource {
    param(
        [string] $MsiPath,
        [object] $File,
        [object] $Media,
        [hashtable] $Components,
        [hashtable] $Directories
    )

    $msiDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($MsiPath))
    $cabinetProperty = $Media.PSObject.Properties['Cabinet']
    $cabinet = if ($null -ne $cabinetProperty) { [string]$cabinetProperty.Value } else { '' }
    $sourceName = (Split-MsiLensFileName $File.RawFileName).Short
    $attributes = 0
    [void][int]::TryParse([string]$File.Attributes, [ref]$attributes)
    $forceNoncompressed = (($attributes -band 8192) -ne 0)
    $forceCompressed = (($attributes -band 16384) -ne 0)
    if ($forceNoncompressed -and $forceCompressed) {
        return [pscustomobject]@{ Status = 'Unsupported'; SourceKind = 'Unknown'; Cabinet = $cabinet; Warning = 'UnsupportedMediaLayout'; SourceName = $sourceName }
    }

    if ($forceNoncompressed -or ((-not $forceCompressed) -and [string]::IsNullOrWhiteSpace($cabinet))) {
        if (-not $Components.ContainsKey($File.Component)) {
            return [pscustomobject]@{ Status = 'Unsupported'; SourceKind = 'Uncompressed'; Cabinet = $null; Warning = 'UnsupportedMediaLayout'; SourceName = $sourceName }
        }
        $directoryId = [string]$Components[$File.Component].Directory_
        $segments = @(Resolve-MsiLensDirectorySegments -DirectoryId $directoryId -Directories $Directories -SourceName)
        $path = Resolve-MsiLensContainedPath -Root $msiDirectory -Segments (@($segments) + @($sourceName))
        if ($null -eq $path) {
            return [pscustomobject]@{ Status = 'Unsupported'; SourceKind = 'Uncompressed'; Cabinet = $null; Warning = 'UnsafeSourcePath'; SourceName = $sourceName }
        }
        return [pscustomobject]@{ Status = 'Match'; SourceKind = 'Uncompressed'; Cabinet = $null; Path = $path; SourceName = $sourceName }
    }

    if ($forceCompressed -and [string]::IsNullOrWhiteSpace($cabinet)) {
        return [pscustomobject]@{ Status = 'Unsupported'; SourceKind = 'Unknown'; Cabinet = $null; Warning = 'UnsupportedMediaLayout'; SourceName = $sourceName }
    }

    if ($cabinet.StartsWith('#', [System.StringComparison]::Ordinal)) {
        $streamName = $cabinet.Substring(1)
        return [pscustomobject]@{ Status = 'Match'; SourceKind = 'EmbeddedCabinet'; Cabinet = $streamName; Path = $null; SourceName = $sourceName }
    }

    if (Test-MsiLensUnsafeRelativePathText $cabinet) {
        return [pscustomobject]@{ Status = 'Unsupported'; SourceKind = 'ExternalCabinet'; Cabinet = $cabinet; Warning = 'UnsafeSourcePath'; SourceName = $sourceName }
    }
    $cabinetSegments = @($cabinet -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $path = Resolve-MsiLensContainedPath -Root $msiDirectory -Segments $cabinetSegments
    if ($null -eq $path) {
        return [pscustomobject]@{ Status = 'Unsupported'; SourceKind = 'ExternalCabinet'; Cabinet = $cabinet; Warning = 'UnsafeSourcePath'; SourceName = $sourceName }
    }
    [pscustomobject]@{ Status = 'Match'; SourceKind = 'ExternalCabinet'; Cabinet = $cabinet; Path = $path; SourceName = $sourceName }
}

function Test-MsiLensEmbeddedCabinetStream {
    param(
        [object] $Connection,
        [string] $StreamName
    )

    $record = $Connection.Installer.CreateRecord(1)
    $record.StringData(1) = $StreamName
    $view = $null
    $row = $null
    try {
        $view = $Connection.Database.OpenView("SELECT ``Name`` FROM ``_Streams`` WHERE ``Name`` = ?")
        $null = $view.Execute($record)
        $row = $view.Fetch()
        return ($null -ne $row)
    } finally {
        Remove-MsiLensComObject $row
        Remove-MsiLensComObject $record
        if ($null -ne $view) {
            try { $null = $view.Close() } catch { }
            Remove-MsiLensComObject $view
        }
    }
}

function Add-MsiLensNativeMsiApi {
    if ('MsiLens.NativeMsi' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;

namespace MsiLens {
    public static class NativeMsi {
        private const uint ERROR_SUCCESS = 0;
        private const uint ERROR_NO_MORE_ITEMS = 259;

        [DllImport("msi.dll", CharSet = CharSet.Unicode)]
        private static extern uint MsiOpenDatabase(string databasePath, IntPtr persist, out IntPtr database);

        [DllImport("msi.dll", CharSet = CharSet.Unicode)]
        private static extern uint MsiDatabaseOpenView(IntPtr database, string query, out IntPtr view);

        [DllImport("msi.dll")]
        private static extern uint MsiViewExecute(IntPtr view, IntPtr record);

        [DllImport("msi.dll")]
        private static extern uint MsiViewFetch(IntPtr view, out IntPtr record);

        [DllImport("msi.dll")]
        private static extern uint MsiViewClose(IntPtr view);

        [DllImport("msi.dll")]
        private static extern IntPtr MsiCreateRecord(uint fieldCount);

        [DllImport("msi.dll", CharSet = CharSet.Unicode)]
        private static extern uint MsiRecordSetString(IntPtr record, uint field, string value);

        [DllImport("msi.dll")]
        private static extern uint MsiRecordReadStream(IntPtr record, uint field, byte[] buffer, ref uint bufferSize);

        [DllImport("msi.dll")]
        private static extern uint MsiCloseHandle(IntPtr handle);

        public static long ExportStream(string databasePath, string query, string key, uint streamField, string destinationPath, int bufferSize) {
            IntPtr database = IntPtr.Zero;
            IntPtr view = IntPtr.Zero;
            IntPtr parameterRecord = IntPtr.Zero;
            IntPtr rowRecord = IntPtr.Zero;
            FileStream output = null;
            try {
                Check(MsiOpenDatabase(databasePath, IntPtr.Zero, out database), "MsiOpenDatabase");
                Check(MsiDatabaseOpenView(database, query, out view), "MsiDatabaseOpenView");
                parameterRecord = MsiCreateRecord(1);
                if (parameterRecord == IntPtr.Zero) {
                    throw new InvalidOperationException("MsiCreateRecord failed.");
                }
                Check(MsiRecordSetString(parameterRecord, 1, key), "MsiRecordSetString");
                Check(MsiViewExecute(view, parameterRecord), "MsiViewExecute");
                uint fetchResult = MsiViewFetch(view, out rowRecord);
                if (fetchResult == ERROR_NO_MORE_ITEMS || rowRecord == IntPtr.Zero) {
                    return -1;
                }
                Check(fetchResult, "MsiViewFetch");

                byte[] buffer = new byte[bufferSize];
                long written = 0;
                output = File.Open(destinationPath, FileMode.Create, FileAccess.Write, FileShare.None);
                while (true) {
                    uint bytesToRead = (uint)buffer.Length;
                    uint readResult = MsiRecordReadStream(rowRecord, streamField, buffer, ref bytesToRead);
                    Check(readResult, "MsiRecordReadStream");
                    if (bytesToRead == 0) {
                        break;
                    }
                    output.Write(buffer, 0, (int)bytesToRead);
                    written += bytesToRead;
                }
                return written;
            } finally {
                if (output != null) {
                    output.Dispose();
                }
                if (rowRecord != IntPtr.Zero) {
                    MsiCloseHandle(rowRecord);
                }
                if (view != IntPtr.Zero) {
                    MsiViewClose(view);
                    MsiCloseHandle(view);
                }
                if (parameterRecord != IntPtr.Zero) {
                    MsiCloseHandle(parameterRecord);
                }
                if (database != IntPtr.Zero) {
                    MsiCloseHandle(database);
                }
            }
        }

        private static void Check(uint result, string operation) {
            if (result != ERROR_SUCCESS) {
                throw new InvalidOperationException(operation + " failed with Windows Installer error " + result + ".");
            }
        }
    }
}
'@
}

function ConvertTo-MsiLensStreamBytes {
    param([object] $Value)

    if ($null -eq $Value) {
        return (New-Object byte[] 0)
    }
    if ($Value -is [byte[]]) {
        return [byte[]]$Value
    }
    $text = [string]$Value
    $bytes = New-Object byte[] $text.Length
    for ($index = 0; $index -lt $text.Length; $index++) {
        $bytes[$index] = [byte]([int][char]$text[$index] -band 0xff)
    }
    $bytes
}

function Export-MsiLensEmbeddedCabinet {
    param(
        [object] $Connection,
        [string] $StreamName,
        [string] $DestinationPath
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    Add-MsiLensNativeMsiApi
    $written = [MsiLens.NativeMsi]::ExportStream(
        $Connection.Path,
        'SELECT `Data` FROM `_Streams` WHERE `Name` = ?',
        $StreamName,
        1,
        $DestinationPath,
        1048576)
    if ($written -lt 0) {
        Write-Verbose ("Embedded cabinet stream '{0}' was not found after {1:n3}s." -f $StreamName, $timer.Elapsed.TotalSeconds)
        return $false
    }
    Write-Verbose ("Exported embedded cabinet stream '{0}' to '{1}' ({2:n0} bytes) in {3:n3}s using native MSI stream I/O." -f $StreamName, $DestinationPath, $written, $timer.Elapsed.TotalSeconds)
    $true
}

function Export-MsiLensDatabaseStream {
    param(
        [object] $Connection,
        [string] $Table,
        [string] $KeyColumn,
        [string] $DataColumn,
        [string] $Key,
        [string] $DestinationPath
    )

    Add-MsiLensNativeMsiApi
    $quotedTable = Format-MsiLensSqlIdentifier $Table
    $quotedKey = Format-MsiLensSqlIdentifier $KeyColumn
    $quotedData = Format-MsiLensSqlIdentifier $DataColumn
    $written = [MsiLens.NativeMsi]::ExportStream(
        $Connection.Path,
        "SELECT $quotedData FROM $quotedTable WHERE $quotedKey = ?",
        $Key,
        1,
        $DestinationPath,
        1048576)
    if ($written -lt 0) {
        return $null
    }
    $written
}

function New-MsiLensArtifactExtractionResult {
    param(
        [string] $Status,
        [string] $MsiPath,
        [string] $ArtifactKind,
        [object] $Artifact,
        [object] $PathInfo,
        [Nullable[int64]] $BytesWritten = $null,
        [Nullable[bool]] $Verified = $null,
        [string[]] $VerificationWarnings = @(),
        [string[]] $Warnings = @(),
        [bool] $WouldOverwrite = $false,
        [bool] $AmbiguousMatch = $false,
        [string[]] $MatchedFields = @(),
        [string] $Message = ''
    )

    $name = if ($ArtifactKind -eq 'BinaryStream') { $Artifact.Name } else { $Artifact.StreamName }
    $sourceTable = if ($ArtifactKind -eq 'BinaryStream') { 'Binary' } else { 'Media' }
    $sourceKey = if ($ArtifactKind -eq 'BinaryStream') { $Artifact.Name } else { ("{0}:{1}" -f $Artifact.DiskId, $Artifact.Cabinet) }

    New-MsiLensObject 'MsiLens.ArtifactExtractionResult' ([ordered]@{
        Status               = $Status
        MsiPath              = $MsiPath
        ArtifactKind         = $ArtifactKind
        Name                 = $name
        SourceTable          = $sourceTable
        SourceKey            = $sourceKey
        OriginalOutputName   = if ($PathInfo -and $PathInfo.Sanitized) { $name } else { $null }
        RelativePath         = if ($PathInfo) { $PathInfo.RelativePath } else { $null }
        ChangedPathSegments  = if ($PathInfo) { @($PathInfo.ChangedPathSegments) } else { @() }
        OutputPath           = if ($PathInfo) { $PathInfo.OutputPath } else { $null }
        BytesWritten         = $BytesWritten
        Verified             = $Verified
        VerificationWarnings = @($VerificationWarnings)
        Warnings             = @($Warnings)
        Sanitized            = if ($PathInfo) { [bool]$PathInfo.Sanitized } else { $false }
        WouldOverwrite       = $WouldOverwrite
        AmbiguousMatch       = $AmbiguousMatch
        MatchedFields        = @($MatchedFields)
        Message              = $Message
    })
}

function Invoke-MsiLensArtifactExtraction {
    param(
        [object] $Connection,
        [string] $MsiPath,
        [hashtable] $Options,
        [string] $Kind
    )

    $artifacts = if ($Kind -eq 'Binary') { @(Get-MsiLensBinaryRecords $Connection) } else { @(Get-MsiLensEmbeddedCabinetRecords $Connection) }
    $selection = Resolve-MsiLensArtifactSelection -Artifacts $artifacts -Options $Options -Kind $Kind
    $selectedItems = @($selection.Items)
    if ($selectedItems.Count -eq 0) {
        $code = if ($Kind -eq 'Binary') { 'NoMatchingBinaries' } else { 'NoMatchingCabinets' }
        Write-MsiLensError -Code $code -Message ("No {0} artifacts matched the extraction request." -f $Kind.ToLowerInvariant()) -Category ObjectNotFound
        Set-MsiLensExitCode 5
        return
    }

    $root = [System.IO.Path]::GetFullPath($Options.Out)
    if (-not $Options.DryRun -and -not (Test-Path -LiteralPath $root)) {
        [void](New-Item -ItemType Directory -Path $root -Force)
    }

    $planned = New-Object System.Collections.ArrayList
    $pathCounts = @{}
    foreach ($item in $selectedItems) {
        $artifact = $item.Artifact
        $outputName = if ($Kind -eq 'Binary') { $artifact.Name } else { $artifact.StreamName }
        $pathInfo = Resolve-MsiLensArtifactOutputPath -OutputName $outputName -OutputRoot $root
        if ($pathInfo.Safe) {
            $key = $pathInfo.OutputPath.ToLowerInvariant()
            if (-not $pathCounts.ContainsKey($key)) { $pathCounts[$key] = 0 }
            $pathCounts[$key]++
        }
        [void]$planned.Add([pscustomobject]@{ Item = $item; PathInfo = $pathInfo })
    }

    $success = 0
    $failures = 0
    foreach ($plan in $planned) {
        $artifact = $plan.Item.Artifact
        $artifactKind = if ($Kind -eq 'Binary') { 'BinaryStream' } else { 'EmbeddedCabinet' }
        if (-not $plan.PathInfo.Safe) {
            $failures++
            New-MsiLensArtifactExtractionResult -Status 'Failed' -MsiPath $MsiPath -ArtifactKind $artifactKind -Artifact $artifact -PathInfo $null -Warnings @('UnsafeOutputPath') -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Output path was blocked by safety checks.'
            continue
        }

        $warnings = New-Object System.Collections.ArrayList
        foreach ($warning in $plan.PathInfo.Warnings) { [void]$warnings.Add($warning) }
        $pathKey = $plan.PathInfo.OutputPath.ToLowerInvariant()
        if ($pathCounts[$pathKey] -gt 1) {
            [void]$warnings.Add('OutputConflict')
            $failures++
            New-MsiLensArtifactExtractionResult -Status 'Conflict' -MsiPath $MsiPath -ArtifactKind $artifactKind -Artifact $artifact -PathInfo $plan.PathInfo -Warnings ([string[]]$warnings.ToArray([string])) -WouldOverwrite $true -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Multiple selected artifacts would write the same output path.'
            continue
        }

        $existingDirectory = Test-Path -LiteralPath $plan.PathInfo.OutputPath -PathType Container
        if ($existingDirectory) {
            $failures++
            New-MsiLensArtifactExtractionResult -Status 'Conflict' -MsiPath $MsiPath -ArtifactKind $artifactKind -Artifact $artifact -PathInfo $plan.PathInfo -Warnings ((@($warnings.ToArray([string])) + @('OutputConflict'))) -WouldOverwrite $false -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Output path is an existing directory.'
            continue
        }
        $exists = Test-Path -LiteralPath $plan.PathInfo.OutputPath -PathType Leaf
        if ($exists -and -not $Options.Force) {
            $failures++
            New-MsiLensArtifactExtractionResult -Status 'Conflict' -MsiPath $MsiPath -ArtifactKind $artifactKind -Artifact $artifact -PathInfo $plan.PathInfo -Warnings ((@($warnings.ToArray([string])) + @('OutputConflict'))) -WouldOverwrite $true -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Output file exists; use -Force to overwrite.'
            continue
        }

        if ($Kind -eq 'Cabinet' -and -not $artifact.CanExtract) {
            $failures++
            New-MsiLensArtifactExtractionResult -Status 'MissingSource' -MsiPath $MsiPath -ArtifactKind $artifactKind -Artifact $artifact -PathInfo $plan.PathInfo -Warnings ((@($warnings.ToArray([string])) + @('MissingSource'))) -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Embedded cabinet stream was not found.'
            continue
        }

        if ($Options.DryRun) {
            $success++
            New-MsiLensArtifactExtractionResult -Status 'Planned' -MsiPath $MsiPath -ArtifactKind $artifactKind -Artifact $artifact -PathInfo $plan.PathInfo -Verified $null -Warnings ([string[]]$warnings.ToArray([string])) -WouldOverwrite $exists -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Extraction planned; no bytes written.'
            continue
        }

        try {
            $outputDirectory = Split-Path -Parent $plan.PathInfo.OutputPath
            if (-not (Test-Path -LiteralPath $outputDirectory)) {
                [void](New-Item -ItemType Directory -Path $outputDirectory -Force)
            }

            $written = if ($Kind -eq 'Binary') {
                Export-MsiLensDatabaseStream -Connection $Connection -Table 'Binary' -KeyColumn 'Name' -DataColumn 'Data' -Key $artifact.Name -DestinationPath $plan.PathInfo.OutputPath
            } else {
                Export-MsiLensDatabaseStream -Connection $Connection -Table '_Streams' -KeyColumn 'Name' -DataColumn 'Data' -Key $artifact.StreamName -DestinationPath $plan.PathInfo.OutputPath
            }
            if ($null -eq $written) {
                $failures++
                New-MsiLensArtifactExtractionResult -Status 'MissingSource' -MsiPath $MsiPath -ArtifactKind $artifactKind -Artifact $artifact -PathInfo $plan.PathInfo -Warnings ((@($warnings.ToArray([string])) + @('MissingSource'))) -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Source stream was not found.'
                continue
            }

            # Size comes from Record.DataSize metadata, so this is a real
            # cross-check of the declared stream size against bytes actually
            # written. With no size available, report Verified = $null rather
            # than claiming a check that did not happen.
            $verification = @()
            $verified = $null
            if ($null -ne $artifact.Size) {
                $verified = ([int64]$artifact.Size -eq [int64]$written)
                if (-not $verified) {
                    $verification += 'SizeMismatch'
                }
            }
            $success++
            New-MsiLensArtifactExtractionResult -Status 'Extracted' -MsiPath $MsiPath -ArtifactKind $artifactKind -Artifact $artifact -PathInfo $plan.PathInfo -BytesWritten ([int64]$written) -Verified $verified -VerificationWarnings $verification -Warnings ([string[]]$warnings.ToArray([string])) -WouldOverwrite $exists -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Artifact extracted.'
        } catch {
            $failures++
            New-MsiLensArtifactExtractionResult -Status 'Failed' -MsiPath $MsiPath -ArtifactKind $artifactKind -Artifact $artifact -PathInfo $plan.PathInfo -Warnings ((@($warnings.ToArray([string])) + @('ExtractionFailed'))) -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message $_.Exception.Message
        }
    }

    if ($failures -gt 0) {
        Set-MsiLensExitCode 5
    } else {
        Set-MsiLensExitCode 0
    }
}

function Find-MsiLensSelectedExpandedPayload {
    param(
        [string] $Directory,
        [string] $Name
    )

    if ([string]::IsNullOrWhiteSpace($Name) -or (Test-MsiLensUnsafeRelativePathText $Name)) {
        return $null
    }
    $nameSegments = @($Name -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $candidate = Resolve-MsiLensContainedPath -Root $Directory -Segments $nameSegments
    if ($null -ne $candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $candidate).ProviderPath
    }

    $leafName = [System.IO.Path]::GetFileName($Name)
    if ([string]::IsNullOrWhiteSpace($leafName)) {
        return $null
    }
    $match = @(Get-ChildItem -LiteralPath $Directory -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $leafName } | Select-Object -First 1)
    if ($match.Count -gt 0) {
        return $match[0].FullName
    }
    $null
}

function Get-MsiLensCabinetPayloadNames {
    param(
        [string] $CabinetPath
    )

    $expand = Get-Command expand.exe -ErrorAction SilentlyContinue
    if ($null -eq $expand) {
        throw 'expand.exe was not found.'
    }

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $output = & $expand.Source -D $CabinetPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Verbose ("Listed cabinet '{0}' in {1:n3}s with exit code {2}; no payload names were parsed." -f $CabinetPath, $timer.Elapsed.TotalSeconds, $LASTEXITCODE)
        return @()
    }
    $names = New-Object System.Collections.ArrayList
    foreach ($line in @($output)) {
        $text = [string]$line
        $separator = $text.LastIndexOf(': ')
        if ($separator -lt 0) {
            continue
        }
        $name = $text.Substring($separator + 2).Trim()
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            [void]$names.Add($name)
        }
    }
    $payloadNames = [string[]]$names.ToArray([string])
    Write-Verbose ("Listed cabinet '{0}' ({1} payload names) in {2:n3}s." -f $CabinetPath, $payloadNames.Count, $timer.Elapsed.TotalSeconds)
    $payloadNames
}

function Expand-MsiLensCabinetFile {
    param(
        [string] $CabinetPath,
        [string] $DestinationDirectory,
        [string[]] $Names,
        [string[]] $ListedNames = $null
    )

    if (-not (Test-Path -LiteralPath $CabinetPath)) {
        return $false
    }
    $expand = Get-Command expand.exe -ErrorAction SilentlyContinue
    if ($null -eq $expand) {
        throw 'expand.exe was not found.'
    }
    $safeNames = @($Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not (Test-MsiLensUnsafeRelativePathText $_) } | Select-Object -Unique)
    if ($safeNames.Count -eq 0) {
        return $false
    }

    $listedNames = if ($null -ne $ListedNames) { @($ListedNames) } else { @(Get-MsiLensCabinetPayloadNames -CabinetPath $CabinetPath) }
    $listedNameLookup = @{}
    foreach ($listedName in $listedNames) {
        if (-not [string]::IsNullOrWhiteSpace($listedName) -and -not $listedNameLookup.ContainsKey($listedName)) {
            $listedNameLookup[$listedName] = $true
        }
    }
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($name in $safeNames) {
        $attemptDirectory = Join-Path $DestinationDirectory ("cab-{0}" -f ([guid]::NewGuid().ToString('N')))
        [void](New-Item -ItemType Directory -Path $attemptDirectory -Force)
        $null = & $expand.Source $CabinetPath ("-F:{0}" -f $name) $attemptDirectory 2>&1
        $selectedPayload = if ($LASTEXITCODE -eq 0) { Find-MsiLensSelectedExpandedPayload -Directory $attemptDirectory -Name $name } else { $null }
        if ($null -ne $selectedPayload) {
            Move-Item -LiteralPath $selectedPayload -Destination (Join-Path $DestinationDirectory ([System.IO.Path]::GetFileName($name))) -Force
            Remove-Item -LiteralPath $attemptDirectory -Recurse -Force -ErrorAction SilentlyContinue
            Write-Verbose ("Extracted selected cabinet payload from '{0}' using {1} candidate name(s) in {2:n3}s." -f $CabinetPath, $safeNames.Count, $timer.Elapsed.TotalSeconds)
            return $true
        }
        Remove-Item -LiteralPath $attemptDirectory -Recurse -Force -ErrorAction SilentlyContinue

        if (-not $listedNameLookup.ContainsKey($name)) {
            continue
        }

        $nameSegments = @($name -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $destinationPath = Resolve-MsiLensContainedPath -Root $DestinationDirectory -Segments $nameSegments
        if ($null -eq $destinationPath) {
            continue
        }
        $destinationParent = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $destinationParent)) {
            [void](New-Item -ItemType Directory -Path $destinationParent -Force)
        }
        $null = & $expand.Source $CabinetPath $destinationPath 2>&1
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
            Write-Verbose ("Extracted selected cabinet payload from '{0}' using {1} candidate name(s) in {2:n3}s." -f $CabinetPath, $safeNames.Count, $timer.Elapsed.TotalSeconds)
            return $true
        }
    }

    Write-Verbose ("Selected cabinet payload was not found in '{0}' after trying {1} candidate name(s) in {2:n3}s." -f $CabinetPath, $safeNames.Count, $timer.Elapsed.TotalSeconds)
    $false
}

function Expand-MsiLensCabinetDirectory {
    param(
        [string] $CabinetPath,
        [string] $DestinationDirectory
    )

    if (-not (Test-Path -LiteralPath $CabinetPath)) {
        return $false
    }
    $expand = Get-Command expand.exe -ErrorAction SilentlyContinue
    if ($null -eq $expand) {
        throw 'expand.exe was not found.'
    }
    if (-not (Test-Path -LiteralPath $DestinationDirectory)) {
        [void](New-Item -ItemType Directory -Path $DestinationDirectory -Force)
    }

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $null = & $expand.Source $CabinetPath '-F:*' $DestinationDirectory 2>&1
    $succeeded = ($LASTEXITCODE -eq 0)
    Write-Verbose ("Expanded cabinet '{0}' to '{1}' with -F:* in {2:n3}s (success: {3})." -f $CabinetPath, $DestinationDirectory, $timer.Elapsed.TotalSeconds, $succeeded)
    $succeeded
}

function Find-MsiLensExpandedPayload {
    param(
        [string] $Directory,
        [string[]] $Names
    )

    foreach ($name in $Names) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        if (Test-MsiLensUnsafeRelativePathText $name) {
            continue
        }
        $nameSegments = @($name -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $candidate = Resolve-MsiLensContainedPath -Root $Directory -Segments $nameSegments
        if ($null -eq $candidate) {
            continue
        }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).ProviderPath
        }
    }
    $all = @(Get-ChildItem -LiteralPath $Directory -File -Recurse -ErrorAction SilentlyContinue)
    foreach ($name in $Names) {
        if ([string]::IsNullOrWhiteSpace($name) -or (Test-MsiLensUnsafeRelativePathText $name)) {
            continue
        }
        $leafName = [System.IO.Path]::GetFileName($name)
        $match = @($all | Where-Object { $_.Name -ieq $leafName } | Select-Object -First 1)
        if ($match.Count -gt 0) {
            return $match[0].FullName
        }
    }
    if ($all.Count -eq 1) {
        return $all[0].FullName
    }
    $null
}

function New-MsiLensExtractionResult {
    param(
        [string] $Status,
        [string] $MsiPath,
        [object] $File,
        [string] $Directory,
        [object] $PathInfo,
        [string] $Layout,
        [string] $SourceKind = 'Unknown',
        [string] $Cabinet = $null,
        [object] $DiskId = $null,
        [Nullable[int]] $BytesWritten = $null,
        [Nullable[bool]] $Verified = $null,
        [string[]] $VerificationWarnings = @(),
        [string[]] $Warnings = @(),
        [bool] $WouldOverwrite = $false,
        [bool] $AmbiguousMatch = $false,
        [string[]] $MatchedFields = @(),
        [string] $Message = ''
    )

    New-MsiLensObject 'MsiLens.ExtractionResult' ([ordered]@{
        Status               = $Status
        MsiPath              = $MsiPath
        File                 = $File.File
        Component            = $File.Component
        Directory            = $Directory
        RawFileName          = $File.RawFileName
        FileName             = $File.FileName
        ShortFileName        = $File.ShortFileName
        LongFileName         = $File.LongFileName
        OriginalOutputName   = if ($PathInfo -and $PathInfo.Sanitized) { $File.FileName } else { $null }
        OriginalRelativePath = if ($PathInfo -and $PathInfo.Sanitized) { (($PathInfo.OriginalSegments) -join [System.IO.Path]::DirectorySeparatorChar) } else { $null }
        RelativePath         = if ($PathInfo) { $PathInfo.RelativePath } else { $null }
        ChangedPathSegments  = if ($PathInfo) { @($PathInfo.ChangedPathSegments) } else { @() }
        OutputPath           = if ($PathInfo) { $PathInfo.OutputPath } else { $null }
        Layout               = $Layout
        SourceKind           = $SourceKind
        Cabinet              = $Cabinet
        DiskId               = $DiskId
        Sequence             = $File.Sequence
        FileSize             = $File.FileSize
        BytesWritten         = $BytesWritten
        Verified             = $Verified
        VerificationWarnings = @($VerificationWarnings)
        Warnings             = @($Warnings)
        Sanitized            = if ($PathInfo) { [bool]$PathInfo.Sanitized } else { $false }
        WouldOverwrite       = $WouldOverwrite
        AmbiguousMatch       = $AmbiguousMatch
        MatchedFields        = @($MatchedFields)
        Message              = $Message
    })
}

function Invoke-MsiLensExtraction {
    param(
        [object] $Connection,
        [string] $MsiPath,
        [hashtable] $Options
    )

    $files = @(Get-MsiLensFilesFromConnection $Connection)
    $selection = Resolve-MsiLensExtractionSelection -Files $files -Options $Options
    if ($selection.Items.Count -eq 0) {
        Write-MsiLensError -Code 'NoMatchingFiles' -Message 'No File table rows matched the extraction request.' -Category ObjectNotFound
        Set-MsiLensExitCode 5
        return
    }

    $components = Get-MsiLensExtractionComponents $Connection
    $directories = Get-MsiLensExtractionDirectories $Connection
    $mediaRows = @(Get-MsiLensExtractionMediaRows $Connection)
    $root = [System.IO.Path]::GetFullPath($Options.Out)
    if (-not $Options.DryRun -and -not (Test-Path -LiteralPath $root)) {
        [void](New-Item -ItemType Directory -Path $root -Force)
    }

    $planned = New-Object System.Collections.ArrayList
    $pathCounts = @{}
    foreach ($item in $selection.Items) {
        $file = $item.File
        $directoryId = $null
        if ($components.ContainsKey($file.Component)) {
            $directoryId = [string]$components[$file.Component].Directory_
        }
        $segments = if ($Options.Layout -eq 'InstalledTree') {
            @(Resolve-MsiLensDirectorySegments -DirectoryId $directoryId -Directories $directories) + @($file.FileName)
        } else {
            @($file.FileName)
        }
        $pathInfo = Resolve-MsiLensSafeRelativePath -Segments $segments -OutputRoot $root
        if ($pathInfo.Safe) {
            $pathInfo | Add-Member -MemberType NoteProperty -Name OriginalSegments -Value $segments
            $key = $pathInfo.OutputPath.ToLowerInvariant()
            if (-not $pathCounts.ContainsKey($key)) { $pathCounts[$key] = 0 }
            $pathCounts[$key]++
        }
        [void]$planned.Add([pscustomobject]@{ Item = $item; Directory = $directoryId; PathInfo = $pathInfo })
    }

    $sourceGroupCounts = @{}
    foreach ($plan in $planned) {
        $file = $plan.Item.File
        $media = Resolve-MsiLensMediaForFile -File $file -MediaRows $mediaRows
        $plan | Add-Member -MemberType NoteProperty -Name MediaResolution -Value $media

        $source = $null
        if ($media.Status -eq 'Match') {
            $source = Resolve-MsiLensExtractionSource -MsiPath $MsiPath -File $file -Media $media.Media -Components $components -Directories $directories
        }
        $plan | Add-Member -MemberType NoteProperty -Name SourceResolution -Value $source

        if ($null -ne $source -and $source.Status -eq 'Match' -and @('EmbeddedCabinet', 'ExternalCabinet') -contains $source.SourceKind) {
            $sourceKey = if ($source.SourceKind -eq 'EmbeddedCabinet') { "Embedded|$($source.Cabinet)" } else { "External|$($source.Path)" }
            $plan | Add-Member -MemberType NoteProperty -Name SourceGroupKey -Value $sourceKey
            if (-not $sourceGroupCounts.ContainsKey($sourceKey)) {
                $sourceGroupCounts[$sourceKey] = 0
            }
            $sourceGroupCounts[$sourceKey]++
        } else {
            $plan | Add-Member -MemberType NoteProperty -Name SourceGroupKey -Value $null
        }
    }

    $success = 0
    $failures = 0
    $commandTemp = $null
    $cabinetCache = @{}
    foreach ($plan in $planned) {
        $file = $plan.Item.File
        if (-not $plan.PathInfo.Safe) {
            $failures++
            New-MsiLensExtractionResult -Status 'Failed' -MsiPath $MsiPath -File $file -Directory $plan.Directory -PathInfo $null -Layout $Options.Layout -Warnings @('UnsafeOutputPath') -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Output path was blocked by safety checks.'
            continue
        }

        $warnings = New-Object System.Collections.ArrayList
        foreach ($warning in $plan.PathInfo.Warnings) { [void]$warnings.Add($warning) }
        $pathKey = $plan.PathInfo.OutputPath.ToLowerInvariant()
        if ($pathCounts[$pathKey] -gt 1) {
            [void]$warnings.Add('OutputConflict')
            $failures++
            New-MsiLensExtractionResult -Status 'Conflict' -MsiPath $MsiPath -File $file -Directory $plan.Directory -PathInfo $plan.PathInfo -Layout $Options.Layout -Warnings ([string[]]$warnings.ToArray([string])) -WouldOverwrite $true -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Multiple selected files would write the same output path.'
            continue
        }

        $media = $plan.MediaResolution
        if ($media.Status -ne 'Match') {
            $failures++
            New-MsiLensExtractionResult -Status 'Unsupported' -MsiPath $MsiPath -File $file -Directory $plan.Directory -PathInfo $plan.PathInfo -Layout $Options.Layout -Warnings @($media.Warning) -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'File sequence could not be mapped to a supported Media row.'
            continue
        }

        $source = $plan.SourceResolution
        if ($source.Status -eq 'Unsupported') {
            $failures++
            New-MsiLensExtractionResult -Status 'Unsupported' -MsiPath $MsiPath -File $file -Directory $plan.Directory -PathInfo $plan.PathInfo -Layout $Options.Layout -SourceKind $source.SourceKind -Cabinet $source.Cabinet -DiskId $media.Media.DiskId -Warnings @($source.Warning) -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Source path was unsupported.'
            continue
        }

        $existingDirectory = Test-Path -LiteralPath $plan.PathInfo.OutputPath -PathType Container
        if ($existingDirectory) {
            $failures++
            New-MsiLensExtractionResult -Status 'Conflict' -MsiPath $MsiPath -File $file -Directory $plan.Directory -PathInfo $plan.PathInfo -Layout $Options.Layout -SourceKind $source.SourceKind -Cabinet $source.Cabinet -DiskId $media.Media.DiskId -Warnings ((@($warnings.ToArray([string])) + @('OutputConflict'))) -WouldOverwrite $false -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Output path is an existing directory.'
            continue
        }
        $exists = Test-Path -LiteralPath $plan.PathInfo.OutputPath -PathType Leaf
        if ($exists -and -not $Options.Force) {
            $failures++
            New-MsiLensExtractionResult -Status 'Conflict' -MsiPath $MsiPath -File $file -Directory $plan.Directory -PathInfo $plan.PathInfo -Layout $Options.Layout -SourceKind $source.SourceKind -Cabinet $source.Cabinet -DiskId $media.Media.DiskId -Warnings ((@($warnings.ToArray([string])) + @('OutputConflict'))) -WouldOverwrite $true -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Output file exists; use -Force to overwrite.'
            continue
        }

        if ($Options.DryRun) {
            if ($source.SourceKind -eq 'Uncompressed' -and -not (Test-Path -LiteralPath $source.Path -PathType Leaf)) {
                $failures++
                New-MsiLensExtractionResult -Status 'MissingSource' -MsiPath $MsiPath -File $file -Directory $plan.Directory -PathInfo $plan.PathInfo -Layout $Options.Layout -SourceKind $source.SourceKind -DiskId $media.Media.DiskId -Warnings ((@($warnings.ToArray([string])) + @('MissingSource'))) -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Source file was not found.'
                continue
            }
            if ($source.SourceKind -eq 'ExternalCabinet' -and -not (Test-Path -LiteralPath $source.Path -PathType Leaf)) {
                $failures++
                New-MsiLensExtractionResult -Status 'MissingSource' -MsiPath $MsiPath -File $file -Directory $plan.Directory -PathInfo $plan.PathInfo -Layout $Options.Layout -SourceKind $source.SourceKind -Cabinet $source.Cabinet -DiskId $media.Media.DiskId -Warnings ((@($warnings.ToArray([string])) + @('MissingSource'))) -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Cabinet file was not found.'
                continue
            }
            if ($source.SourceKind -eq 'EmbeddedCabinet' -and -not (Test-MsiLensEmbeddedCabinetStream -Connection $Connection -StreamName $source.Cabinet)) {
                $failures++
                New-MsiLensExtractionResult -Status 'MissingSource' -MsiPath $MsiPath -File $file -Directory $plan.Directory -PathInfo $plan.PathInfo -Layout $Options.Layout -SourceKind $source.SourceKind -Cabinet $source.Cabinet -DiskId $media.Media.DiskId -Warnings ((@($warnings.ToArray([string])) + @('MissingSource'))) -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Embedded cabinet stream was not found.'
                continue
            }

            $success++
            New-MsiLensExtractionResult -Status 'Planned' -MsiPath $MsiPath -File $file -Directory $plan.Directory -PathInfo $plan.PathInfo -Layout $Options.Layout -SourceKind $source.SourceKind -Cabinet $source.Cabinet -DiskId $media.Media.DiskId -Verified $null -Warnings ([string[]]$warnings.ToArray([string])) -WouldOverwrite $exists -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Extraction planned; no bytes written.'
            continue
        }

        $sourcePath = $null
        $temp = $null
        try {
            if ($source.SourceKind -eq 'Uncompressed') {
                if (-not (Test-Path -LiteralPath $source.Path -PathType Leaf)) {
                    $failures++
                    New-MsiLensExtractionResult -Status 'MissingSource' -MsiPath $MsiPath -File $file -Directory $plan.Directory -PathInfo $plan.PathInfo -Layout $Options.Layout -SourceKind $source.SourceKind -DiskId $media.Media.DiskId -Warnings ((@($warnings.ToArray([string])) + @('MissingSource'))) -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Source file was not found.'
                    continue
                }
                $sourcePath = $source.Path
            } else {
                if ($null -eq $commandTemp) {
                    $commandTemp = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensExtract-{0}" -f ([guid]::NewGuid().ToString('N')))
                    [void](New-Item -ItemType Directory -Path $commandTemp -Force)
                }

                $cacheKey = $plan.SourceGroupKey
                if (-not $cabinetCache.ContainsKey($cacheKey)) {
                    $cabinetPath = $source.Path
                    $cacheStatus = 'Match'
                    if ($source.SourceKind -eq 'EmbeddedCabinet') {
                        $cabinetPath = Join-Path $commandTemp ("embedded-{0}.cab" -f ([guid]::NewGuid().ToString('N')))
                        Write-Verbose ("Preparing embedded cabinet '{0}' for {1} selected file(s)." -f $source.Cabinet, $sourceGroupCounts[$cacheKey])
                        if (-not (Export-MsiLensEmbeddedCabinet -Connection $Connection -StreamName $source.Cabinet -DestinationPath $cabinetPath)) {
                            $cacheStatus = 'MissingEmbedded'
                        }
                    } elseif (-not (Test-Path -LiteralPath $cabinetPath -PathType Leaf)) {
                        $cacheStatus = 'MissingExternal'
                    } else {
                        Write-Verbose ("Preparing external cabinet '{0}' for {1} selected file(s)." -f $cabinetPath, $sourceGroupCounts[$cacheKey])
                    }

                    $listedNames = @()
                    if ($cacheStatus -eq 'Match') {
                        $listedNames = @(Get-MsiLensCabinetPayloadNames -CabinetPath $cabinetPath)
                    }

                    $expandedDirectory = $null
                    $useBulkExpansion = ($Options.Mode -ne 'Single' -and $sourceGroupCounts.ContainsKey($cacheKey) -and $sourceGroupCounts[$cacheKey] -gt 1)
                    if ($cacheStatus -eq 'Match' -and $useBulkExpansion) {
                        Write-Verbose ("Using grouped whole-cabinet expansion for {0} selected file(s) from '{1}'." -f $sourceGroupCounts[$cacheKey], $cabinetPath)
                        $expandedDirectory = Join-Path $commandTemp ("cab-all-{0}" -f ([guid]::NewGuid().ToString('N')))
                        if (-not (Expand-MsiLensCabinetDirectory -CabinetPath $cabinetPath -DestinationDirectory $expandedDirectory)) {
                            Remove-Item -LiteralPath $expandedDirectory -Recurse -Force -ErrorAction SilentlyContinue
                            $expandedDirectory = $null
                        }
                    } elseif ($cacheStatus -eq 'Match') {
                        Write-Verbose ("Using targeted cabinet extraction for {0} selected file(s) from '{1}'." -f $sourceGroupCounts[$cacheKey], $cabinetPath)
                    }

                    $cabinetCache[$cacheKey] = [pscustomobject]@{
                        Status            = $cacheStatus
                        CabinetPath       = $cabinetPath
                        ListedNames       = $listedNames
                        ExpandedDirectory = $expandedDirectory
                    }
                }

                $cabinetContext = $cabinetCache[$cacheKey]
                if ($cabinetContext.Status -eq 'MissingEmbedded') {
                    $failures++
                    New-MsiLensExtractionResult -Status 'MissingSource' -MsiPath $MsiPath -File $file -Directory $plan.Directory -PathInfo $plan.PathInfo -Layout $Options.Layout -SourceKind $source.SourceKind -Cabinet $source.Cabinet -DiskId $media.Media.DiskId -Warnings ((@($warnings.ToArray([string])) + @('MissingSource'))) -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Embedded cabinet stream was not found.'
                    continue
                }
                if ($cabinetContext.Status -eq 'MissingExternal') {
                    $failures++
                    New-MsiLensExtractionResult -Status 'MissingSource' -MsiPath $MsiPath -File $file -Directory $plan.Directory -PathInfo $plan.PathInfo -Layout $Options.Layout -SourceKind $source.SourceKind -Cabinet $source.Cabinet -DiskId $media.Media.DiskId -Warnings ((@($warnings.ToArray([string])) + @('MissingSource'))) -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Cabinet file was not found.'
                    continue
                }

                $cabinetNames = @($file.File, $source.SourceName, $file.ShortFileName, $file.LongFileName, $file.FileName)
                if ($null -ne $cabinetContext.ExpandedDirectory) {
                    $sourcePath = Find-MsiLensExpandedPayload -Directory $cabinetContext.ExpandedDirectory -Names $cabinetNames
                } else {
                    $temp = Join-Path $commandTemp ("payload-{0}" -f ([guid]::NewGuid().ToString('N')))
                    [void](New-Item -ItemType Directory -Path $temp -Force)
                    [void](Expand-MsiLensCabinetFile -CabinetPath $cabinetContext.CabinetPath -DestinationDirectory $temp -Names $cabinetNames -ListedNames $cabinetContext.ListedNames)
                    $sourcePath = Find-MsiLensExpandedPayload -Directory $temp -Names $cabinetNames
                }
                if ($null -eq $sourcePath) {
                    $failures++
                    New-MsiLensExtractionResult -Status 'MissingSource' -MsiPath $MsiPath -File $file -Directory $plan.Directory -PathInfo $plan.PathInfo -Layout $Options.Layout -SourceKind $source.SourceKind -Cabinet $source.Cabinet -DiskId $media.Media.DiskId -Warnings ((@($warnings.ToArray([string])) + @('MissingSource'))) -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'Selected payload was not found in the cabinet.'
                    continue
                }
            }

            $outputDirectory = Split-Path -Parent $plan.PathInfo.OutputPath
            if (-not (Test-Path -LiteralPath $outputDirectory)) {
                [void](New-Item -ItemType Directory -Path $outputDirectory -Force)
            }
            $copyTimer = [System.Diagnostics.Stopwatch]::StartNew()
            Copy-Item -LiteralPath $sourcePath -Destination $plan.PathInfo.OutputPath -Force:$Options.Force
            $written = (Get-Item -LiteralPath $plan.PathInfo.OutputPath).Length
            Write-Verbose ("Copied extracted file '{0}' to '{1}' ({2:n0} bytes) in {3:n3}s." -f $sourcePath, $plan.PathInfo.OutputPath, $written, $copyTimer.Elapsed.TotalSeconds)
            $verification = @()
            $verified = $true
            if ($null -ne $file.FileSize -and [int64]$file.FileSize -ne [int64]$written) {
                $verified = $false
                $verification += 'SizeMismatch'
            }
            $success++
            New-MsiLensExtractionResult -Status 'Extracted' -MsiPath $MsiPath -File $file -Directory $plan.Directory -PathInfo $plan.PathInfo -Layout $Options.Layout -SourceKind $source.SourceKind -Cabinet $source.Cabinet -DiskId $media.Media.DiskId -BytesWritten ([int64]$written) -Verified $verified -VerificationWarnings $verification -Warnings ([string[]]$warnings.ToArray([string])) -WouldOverwrite $exists -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message 'File extracted.'
        } catch {
            $failures++
            New-MsiLensExtractionResult -Status 'Failed' -MsiPath $MsiPath -File $file -Directory $plan.Directory -PathInfo $plan.PathInfo -Layout $Options.Layout -SourceKind $source.SourceKind -Cabinet $source.Cabinet -DiskId $media.Media.DiskId -Warnings ((@($warnings.ToArray([string])) + @('ExtractionFailed'))) -AmbiguousMatch $selection.Ambiguous -MatchedFields $plan.Item.MatchedFields -Message $_.Exception.Message
        } finally {
            if ($null -ne $temp -and (Test-Path -LiteralPath $temp)) {
                Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($null -ne $commandTemp -and (Test-Path -LiteralPath $commandTemp)) {
        Remove-Item -LiteralPath $commandTemp -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($failures -gt 0) {
        Set-MsiLensExitCode 5
    } else {
        Set-MsiLensExitCode 0
    }
}

function Show-MsiLensHelp {
    param([string] $Command)

    if ([string]::IsNullOrWhiteSpace($Command)) {
        @'
MsiLens - read-only MSI inspection

Usage:
  .\MsiLens.ps1 [<msi-path>] [<command>] [arguments]
  .\MsiLens.ps1 -Path <msi-path> <command> [arguments]

Commands:
  help [command]     Show help.
  version            Return version object.
  examples           Show MVP examples.
  info               Return package metadata.
  tables             List MSI tables.
  columns <table>    List column metadata.
  table <table>      Return table rows. Supports -First <n>.
  properties         Return Property table rows.
  property <name>    Return one property.
  files              Return File table metadata.
  file <id-or-name>  Return one File table entry.
  binaries           List Binary table stream metadata.
  binary <name>      Return one Binary table stream metadata match.
  cabinets           List embedded cabinet metadata.
  cabinet <name>     Return one embedded cabinet metadata match.
  streams            List understood safe artifact streams.
  extract-file       Extract matching File table payloads.
  extract-files      Extract filtered or all File table payloads.
  extract-binary     Extract one Binary table stream.
  extract-binaries   Extract filtered or all Binary table streams.
  extract-cabinet    Export one raw embedded cabinet stream.
  extract-cabinets   Export filtered or all raw embedded cabinet streams.
  signature          Inspect package-level Authenticode signature.

Data commands return PowerShell objects. Use PowerShell pipelines such as
Format-Table, ConvertTo-Json, or Export-Csv for formatting and serialization.
The REPL accepts trailing PowerShell syntax, for example: info | ft
The REPL Tab key completes commands, options, paths, table names, and properties.
'@
        Set-MsiLensExitCode 0
        return
    }

    $normalized = Resolve-MsiLensAlias $Command
    $known = (Get-MsiLensGlobalCommands) + (Get-MsiLensScopedCommands)
    if ($known -notcontains $normalized) {
        Write-MsiLensError -Code 'InvalidArgument' -Message ("Unknown help command '{0}'." -f $Command) -Category InvalidArgument
        Set-MsiLensExitCode 2
        return
    }

    switch ($normalized) {
        'help' {
            @'
help [command]

Shows global help or command-specific help.

Usage:
  .\MsiLens.ps1 help
  .\MsiLens.ps1 help table

In the REPL:
  MsiLens> help
  MsiLens Product.msi> help signature
'@
        }
        'version' {
            @'
version

Returns one structured MsiLens.Version object describing this script and the
current PowerShell runtime.

Usage:
  .\MsiLens.ps1 version

Output:
  Name, Version, ProjectUrl, ScriptPath, PowerShellVersion, Platform
'@
        }
        'examples' {
            @'
examples

Shows common MVP usage examples. The examples are human-readable help text, not
data objects.

Usage:
  .\MsiLens.ps1 examples
'@
        }
        'info' {
            @'
info

Returns high-level package metadata from the Property table, Summary
Information, and package-level Authenticode inspection.

Usage:
  .\MsiLens.ps1 .\Product.msi info
  .\MsiLens.ps1 -Path .\Product.msi info

In the REPL:
  MsiLens Product.msi> info
  MsiLens Product.msi> info | Format-Table

Output:
  MsiLens.PackageInfo with ProductName, ProductVersion, ProductCode,
  Manufacturer, PackageCode, TableCount, IsSigned, and SignatureStatus.
'@
        }
        'tables' {
            @'
tables

Lists table names discovered from the MSI _Tables table.

Usage:
  .\MsiLens.ps1 .\Product.msi tables

In the REPL:
  MsiLens Product.msi> tables

Output:
  One MsiLens.TableInfo object per table, with Table.
'@
        }
        'columns' {
            @'
columns <table>

Returns schema metadata for a table, including column order, MSI type string,
nullability, and primary-key membership where available.

Usage:
  .\MsiLens.ps1 .\Product.msi columns File
  .\MsiLens.ps1 .\Product.msi columns Property

In the REPL:
  MsiLens Product.msi> columns File

Output:
  MsiLens.ColumnInfo objects with Table, Column, Number, Type, Nullable, and
  PrimaryKey.
'@
        }
        'table' {
            @'
table <table> [-First <n>]

Returns rows from the specified MSI table. MSI columns are exposed as top-level
properties where possible. Binary/stream columns are not emitted as payload
bytes; they are represented by a safe placeholder.

Usage:
  .\MsiLens.ps1 .\Product.msi table File
  .\MsiLens.ps1 .\Product.msi table Property -First 10

In the REPL:
  MsiLens Product.msi> table File -First 10
  MsiLens Product.msi> table File | Where-Object FileName -like *.dll

Output:
  MsiLens.TableRow objects with Row, MSI column properties, and Data.
'@
        }
        'properties' {
            @'
properties

Returns all rows from the MSI Property table as structured name/value objects.

Usage:
  .\MsiLens.ps1 .\Product.msi properties

In the REPL:
  MsiLens Product.msi> properties
  MsiLens Product.msi> properties | Where-Object Property -like Product*

Output:
  MsiLens.Property objects with Property and Value.
'@
        }
        'property' {
            @'
property <name>

Returns one MSI property by exact property name. Missing properties are reported
as a warning and do not cause a non-zero exit code.

Usage:
  .\MsiLens.ps1 .\Product.msi property ProductName
  .\MsiLens.ps1 .\Product.msi property ProductCode

In the REPL:
  MsiLens Product.msi> property ProductName

Output:
  One MsiLens.Property object with Property and Value when found.
'@
        }
        'files' {
            @'
files

Returns File table metadata without extracting payloads. File names are
normalized from MSI short|long filename syntax.

Usage:
  .\MsiLens.ps1 .\Product.msi files

In the REPL:
  MsiLens Product.msi> files
  MsiLens Product.msi> files | Where-Object FileName -like *.dll

Output:
  MsiLens.FileInfo objects with File, Component, RawFileName, FileName,
  ShortFileName, LongFileName, FileSize, Version, Language, Attributes, and
  Sequence.
'@
        }
        'file' {
            @'
file <id-or-name>

Resolves one File table entry without extracting payloads. Matching checks the
File table identifier first, then exact long, short, raw, and canonical file
names. Ambiguous matches are reported as argument errors.

Usage:
  .\MsiLens.ps1 .\Product.msi file MyFile.exe
  .\MsiLens.ps1 .\Product.msi file FileTableIdentifier

In the REPL:
  MsiLens Product.msi> file MyFile.exe

Output:
  One MsiLens.FileInfo object when a unique match is found.
'@
        }
        'extract-file' {
            @'
extract-file <id-or-name> -Out <directory> [-Layout Flat|InstalledTree] [-DryRun] [-Force]

Extracts every File table row whose identifier or filename matches the request.
If more than one row matches, all rows are reported with AmbiguousMatch set.

Output paths are always contained under -Out. The default layout is Flat;
InstalledTree recreates a safe approximation of the authored Directory tree.
Existing files are not overwritten unless -Force is supplied.

Supported sources:
  Embedded cabinets, external cabinets beside the MSI, and uncompressed
  source-layout files beside the MSI.

Output:
  MsiLens.ExtractionResult objects.
'@
        }
        'extract-files' {
            @'
extract-files [-Filter <wildcard> | -All] -Out <directory> [-Layout Flat|InstalledTree] [-DryRun] [-Force]

Extracts File table rows selected by a PowerShell wildcard filter or all rows.
When neither -Filter nor -All is specified, -All is assumed.
Dry-run mode resolves matches, source media, and output paths without writing
bytes.

Output paths are always contained under -Out. The default layout is
InstalledTree, which recreates a safe approximation of the authored Directory
tree. Use -Layout Flat to write directly under -Out.
Existing files are not overwritten unless -Force is supplied.

Output:
  MsiLens.ExtractionResult objects.
'@
        }
        { @('binaries', 'binary', 'cabinets', 'cabinet', 'streams', 'extract-binary', 'extract-binaries', 'extract-cabinet', 'extract-cabinets') -contains $_ } {
            @'
Binary and cabinet artifact commands

Lists, inspects, and extracts only understood safe MSI artifacts: Binary table
streams and Media table embedded cabinet references whose Cabinet value starts
with #. The streams command is an allowlist view, not a raw OLE stream dump.

Usage:
  .\MsiLens.ps1 .\Product.msi binaries
  .\MsiLens.ps1 .\Product.msi binary TinyBinary
  .\MsiLens.ps1 .\Product.msi cabinets
  .\MsiLens.ps1 .\Product.msi cabinet cab1.cab
  .\MsiLens.ps1 .\Product.msi streams
  .\MsiLens.ps1 .\Product.msi extract-binary TinyBinary -Out .\out [-DryRun] [-Force]
  .\MsiLens.ps1 .\Product.msi extract-binaries [-Filter <wildcard> | -All] -Out .\out [-DryRun] [-Force]
  .\MsiLens.ps1 .\Product.msi extract-cabinet cab1.cab -Out .\out [-DryRun] [-Force]
  .\MsiLens.ps1 .\Product.msi extract-cabinets [-Filter <wildcard> | -All] -Out .\out [-DryRun] [-Force]

Cabinet extraction exports raw embedded cabinet bytes without expanding cabinet
contents. For multi-extract commands, when neither -Filter nor -All is
specified, -All is assumed. Extraction never invokes msiexec or executes
package content. Output is flat under -Out, dry-run writes no bytes, and
existing files require -Force.

Output:
  MsiLens.BinaryInfo, MsiLens.CabinetInfo, MsiLens.StreamInfo, or
  MsiLens.ArtifactExtractionResult objects.
'@
        }
        'signature' {
            @'
signature

Inspects the package-level Authenticode signature for the MSI. Invalid,
unsigned, or untrusted signatures are returned as data results when inspection
succeeds.

Usage:
  .\MsiLens.ps1 .\Product.msi signature
  .\MsiLens.ps1 .\Product.msi signature | ConvertTo-Json -Depth 5

In the REPL:
  MsiLens Product.msi> signature
  MsiLens Product.msi> signature | Format-List

Output:
  One MsiLens.Signature object with Scope, TrustScope, TrustLimitations,
  IsSigned, IsValid, Status, StatusMessage, signer certificate fields, and
  timestamp certificate fields where available.

Trust scope:
  This is package-level Authenticode inspection only. It does not validate
  MSI-native signature tables, external cabinets, or installer behavior.
'@
        }
    }
    Set-MsiLensExitCode 0
}

function Show-MsiLensExamples {
    @'
.\MsiLens.ps1 .\Product.msi info
.\MsiLens.ps1 .\Product.msi tables
.\MsiLens.ps1 .\Product.msi columns Property
.\MsiLens.ps1 .\Product.msi table File -First 10
.\MsiLens.ps1 .\Product.msi properties
.\MsiLens.ps1 .\Product.msi property ProductName
.\MsiLens.ps1 .\Product.msi files
.\MsiLens.ps1 .\Product.msi file MyFile.exe
.\MsiLens.ps1 .\Product.msi extract-file MyFile.exe -Out .\out
.\MsiLens.ps1 .\Product.msi extract-files -Out .\out -DryRun
.\MsiLens.ps1 .\Product.msi signature | ConvertTo-Json -Depth 5
'@
    Set-MsiLensExitCode 0
}

function Get-MsiLensVersion {
    New-MsiLensObject 'MsiLens.Version' ([ordered]@{
        Name              = 'MsiLens'
        Version           = $script:MsiLensVersion
        ProjectUrl        = $script:MsiLensProjectUrl
        ScriptPath        = $PSCommandPath
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        Platform          = if ($PSVersionTable.ContainsKey('Platform')) { [string]$PSVersionTable.Platform } else { 'Win32NT' }
    })
}

function Test-MsiLensNoArguments {
    param(
        [string] $Command,
        [string[]] $CommandArguments
    )

    if ($CommandArguments.Count -ne 0) {
        Write-MsiLensError -Code 'InvalidArgument' -Message ("Command '{0}' does not accept extra arguments." -f $Command) -Category InvalidArgument
        Set-MsiLensExitCode 2
        return $false
    }
    return $true
}

function ConvertTo-MsiLensExtractionOptions {
    param(
        [string] $Command,
        [string[]] $CommandArguments
    )

    $options = @{
        Mode   = $null
        Query  = $null
        Filter = $null
        All    = $false
        Out    = $null
        Layout = if ($Command -eq 'extract-files') { 'InstalledTree' } else { 'Flat' }
        DryRun = $false
        Force  = $false
    }

    $singleCommands = @('extract-file', 'extract-binary', 'extract-cabinet')
    $multiCommands = @('extract-files', 'extract-binaries', 'extract-cabinets')

    $index = 0
    if ($singleCommands -contains $Command) {
        if ($CommandArguments.Count -lt 1 -or $CommandArguments[0].StartsWith('-', [System.StringComparison]::Ordinal)) {
            throw ("{0} requires a name." -f $Command)
        }
        $options.Mode = 'Single'
        $options.Query = $CommandArguments[0]
        $index = 1
    } else {
        $options.Mode = 'Multi'
    }

    while ($index -lt $CommandArguments.Count) {
        $argument = $CommandArguments[$index]
        switch ($argument) {
            '-Out' {
                $index++
                if ($index -ge $CommandArguments.Count -or $CommandArguments[$index].StartsWith('-', [System.StringComparison]::Ordinal)) {
                    throw '-Out requires a directory.'
                }
                $options.Out = $CommandArguments[$index]
            }
            '-Layout' {
                if (@('extract-file', 'extract-files') -notcontains $Command) {
                    throw '-Layout is only supported by File table extraction.'
                }
                $index++
                if ($index -ge $CommandArguments.Count) {
                    throw '-Layout requires Flat or InstalledTree.'
                }
                if (@('Flat', 'InstalledTree') -notcontains $CommandArguments[$index]) {
                    throw '-Layout must be Flat or InstalledTree.'
                }
                $options.Layout = $CommandArguments[$index]
            }
            '-DryRun' {
                $options.DryRun = $true
            }
            '-Force' {
                $options.Force = $true
            }
            '-Filter' {
                if ($multiCommands -notcontains $Command) {
                    throw ("-Filter is only supported by {0}." -f ($multiCommands -join ', '))
                }
                $index++
                if ($index -ge $CommandArguments.Count -or $CommandArguments[$index].StartsWith('-', [System.StringComparison]::Ordinal)) {
                    throw '-Filter requires a wildcard.'
                }
                $options.Filter = $CommandArguments[$index]
                $options.Mode = 'Filter'
            }
            '-All' {
                if ($multiCommands -notcontains $Command) {
                    throw ("-All is only supported by {0}." -f ($multiCommands -join ', '))
                }
                $options.All = $true
                $options.Mode = 'All'
            }
            default {
                throw ("Unsupported extraction option or argument '{0}'." -f $argument)
            }
        }
        $index++
    }

    if ([string]::IsNullOrWhiteSpace($options.Out)) {
        throw '-Out is required.'
    }
    if ($multiCommands -contains $Command) {
        if ($options.All -and -not [string]::IsNullOrWhiteSpace($options.Filter)) {
            throw ("{0} accepts only one of -Filter or -All." -f $Command)
        }
        if (-not $options.All -and [string]::IsNullOrWhiteSpace($options.Filter)) {
            $options.All = $true
            $options.Mode = 'All'
        }
    }

    $options
}

function Test-MsiLensScopedCommandArguments {
    param(
        [string] $Command,
        [string[]] $CommandArguments
    )

    switch ($Command) {
        { @('info', 'tables', 'properties', 'files', 'binaries', 'cabinets', 'streams', 'signature') -contains $_ } {
            return (Test-MsiLensNoArguments $Command $CommandArguments)
        }
        'columns' {
            if ($CommandArguments.Count -ne 1) {
                Write-MsiLensError -Code 'InvalidArgument' -Message 'columns requires exactly one table name.' -Category InvalidArgument
                Set-MsiLensExitCode 2
                return $false
            }
            return $true
        }
        'table' {
            if ($CommandArguments.Count -lt 1) {
                Write-MsiLensError -Code 'InvalidArgument' -Message 'table requires a table name.' -Category InvalidArgument
                Set-MsiLensExitCode 2
                return $false
            }
            $remaining = @($CommandArguments | Select-Object -Skip 1)
            if ($remaining.Count -gt 0) {
                if ($remaining.Count -ne 2 -or $remaining[0] -ne '-First') {
                    Write-MsiLensError -Code 'InvalidArgument' -Message 'table supports only -First <n>.' -Category InvalidArgument
                    Set-MsiLensExitCode 2
                    return $false
                }
                $parsed = 0
                if (-not [int]::TryParse($remaining[1], [ref]$parsed) -or $parsed -lt 1) {
                    Write-MsiLensError -Code 'InvalidArgument' -Message '-First requires a positive integer.' -Category InvalidArgument
                    Set-MsiLensExitCode 2
                    return $false
                }
            }
            return $true
        }
        'property' {
            if ($CommandArguments.Count -ne 1) {
                Write-MsiLensError -Code 'InvalidArgument' -Message 'property requires exactly one property name.' -Category InvalidArgument
                Set-MsiLensExitCode 2
                return $false
            }
            return $true
        }
        'file' {
            if ($CommandArguments.Count -ne 1) {
                Write-MsiLensError -Code 'InvalidArgument' -Message 'file requires exactly one file id or name.' -Category InvalidArgument
                Set-MsiLensExitCode 2
                return $false
            }
            return $true
        }
        { @('binary', 'cabinet') -contains $_ } {
            if ($CommandArguments.Count -ne 1) {
                Write-MsiLensError -Code 'InvalidArgument' -Message ("{0} requires exactly one name." -f $Command) -Category InvalidArgument
                Set-MsiLensExitCode 2
                return $false
            }
            return $true
        }
        { @('extract-file', 'extract-files', 'extract-binary', 'extract-binaries', 'extract-cabinet', 'extract-cabinets') -contains $_ } {
            try {
                [void](ConvertTo-MsiLensExtractionOptions -Command $Command -CommandArguments $CommandArguments)
                return $true
            } catch {
                Write-MsiLensError -Code 'InvalidArgument' -Message $_.Exception.Message -Category InvalidArgument
                Set-MsiLensExitCode 2
                return $false
            }
        }
    }

    Write-MsiLensError -Code 'UnknownCommand' -Message ("Unknown command '{0}'." -f $Command) -Category InvalidArgument
    Set-MsiLensExitCode 2
    return $false
}

function Invoke-MsiLensScopedCommand {
    param(
        [string] $MsiPath,
        [string] $Command,
        [string[]] $CommandArguments
    )

    $normalized = Resolve-MsiLensAlias $Command
    if (-not (Test-Path -LiteralPath $MsiPath)) {
        Write-MsiLensError -Code 'FileNotFound' -Message ("MSI path '{0}' was not found." -f $MsiPath) -Category ObjectNotFound
        Set-MsiLensExitCode 3
        return
    }

    if ((Get-MsiLensScopedCommands) -notcontains $normalized) {
        Write-MsiLensError -Code 'UnknownCommand' -Message ("Unknown command '{0}'." -f $Command) -Category InvalidArgument
        Set-MsiLensExitCode 2
        return
    }

    if (-not (Test-MsiLensScopedCommandArguments -Command $normalized -CommandArguments $CommandArguments)) {
        return
    }

    if ($normalized -eq 'signature') {
        $signatureResult = Get-MsiLensSignature $MsiPath
        $signatureResult.Signature
        if ($signatureResult.InspectionFailed) {
            Set-MsiLensExitCode 6
        } else {
            Set-MsiLensExitCode 0
        }
        return
    }

    try {
        $connection = Open-MsiLensDatabase $MsiPath
    } catch [System.IO.FileNotFoundException] {
        Write-MsiLensError -Code 'FileNotFound' -Message $_.Exception.Message -Category ObjectNotFound
        Set-MsiLensExitCode 3
        return
    } catch {
        Write-MsiLensError -Code 'MsiOpenFailed' -Message ("Failed to open MSI read-only: {0}" -f $_.Exception.Message)
        Set-MsiLensExitCode 4
        return
    }

    try {
        switch ($normalized) {
            'info' {
                Get-MsiLensInfo $connection
                Set-MsiLensExitCode 0
                return
            }
            'tables' {
                foreach ($table in Get-MsiLensTablesFromConnection $connection) {
                    New-MsiLensObject 'MsiLens.TableInfo' ([ordered]@{ Table = $table })
                }
                Set-MsiLensExitCode 0
                return
            }
            'columns' {
                $table = Resolve-MsiLensTableName -Connection $connection -Table $CommandArguments[0]
                foreach ($column in Get-MsiLensColumnsFromConnection -Connection $connection -Table $table) {
                    ConvertTo-MsiLensColumnMetadata -Table $table -Column $column
                }
                Set-MsiLensExitCode 0
                return
            }
            'table' {
                $table = $CommandArguments[0]
                $first = $null
                if ($CommandArguments.Count -gt 1) {
                    $first = [int]$CommandArguments[2]
                }
                Get-MsiLensTableRowsFromConnection -Connection $connection -Table $table -First $first
                Set-MsiLensExitCode 0
                return
            }
            'properties' {
                Get-MsiLensPropertiesFromConnection $connection
                Set-MsiLensExitCode 0
                return
            }
            'property' {
                $properties = @(Get-MsiLensPropertiesFromConnection $connection | Where-Object { $_.Property -ceq $CommandArguments[0] })
                if ($properties.Count -eq 0) {
                    Write-Warning ("[PropertyNotFound] Property '{0}' was not found." -f $CommandArguments[0])
                    Set-MsiLensExitCode 0
                    return
                }
                $properties[0]
                Set-MsiLensExitCode 0
                return
            }
            'files' {
                Get-MsiLensFilesFromConnection $connection
                Set-MsiLensExitCode 0
                return
            }
            'file' {
                $files = @(Get-MsiLensFilesFromConnection $connection)
                $resolution = Resolve-MsiLensFile -Files $files -Query $CommandArguments[0]
                if ($resolution.Status -eq 'Ambiguous') {
                    Write-MsiLensError -Code 'AmbiguousFile' -Message ("Ambiguous file match. Candidates: {0}" -f ($resolution.Candidates -join ', ')) -Category InvalidArgument
                    Set-MsiLensExitCode 2
                    return
                }
                if ($resolution.Status -eq 'NotFound') {
                    Write-Warning ("[FileNotFound] File '{0}' was not found." -f $CommandArguments[0])
                    Set-MsiLensExitCode 0
                    return
                }
                $resolution.File
                Set-MsiLensExitCode 0
                return
            }
            'binaries' {
                Get-MsiLensBinaryRecords $connection
                Set-MsiLensExitCode 0
                return
            }
            'binary' {
                $matchResults = @(Get-MsiLensBinaryRecords $connection | Where-Object { $_.Name -ieq $CommandArguments[0] })
                foreach ($match in $matchResults) {
                    $match.AmbiguousMatch = ($matchResults.Count -gt 1)
                    $match
                }
                Set-MsiLensExitCode 0
                return
            }
            'cabinets' {
                Get-MsiLensEmbeddedCabinetRecords $connection
                Set-MsiLensExitCode 0
                return
            }
            'cabinet' {
                $matchResults = @(Get-MsiLensEmbeddedCabinetRecords $connection | Where-Object { $_.Cabinet -ieq $CommandArguments[0] -or $_.StreamName -ieq $CommandArguments[0] })
                foreach ($match in $matchResults) {
                    $match.AmbiguousMatch = ($matchResults.Count -gt 1)
                    $match
                }
                Set-MsiLensExitCode 0
                return
            }
            'streams' {
                foreach ($binary in Get-MsiLensBinaryRecords $connection) {
                    New-MsiLensObject 'MsiLens.StreamInfo' ([ordered]@{
                        Name        = $binary.Name
                        Scope       = 'BinaryTable'
                        SourceTable = 'Binary'
                        SourceKey   = $binary.Name
                        Size        = $binary.Size
                        CanExtract  = $binary.CanExtract
                        Warnings    = @($binary.Warnings)
                    })
                }
                foreach ($cabinet in Get-MsiLensEmbeddedCabinetRecords $connection) {
                    New-MsiLensObject 'MsiLens.StreamInfo' ([ordered]@{
                        Name        = $cabinet.StreamName
                        Scope       = 'EmbeddedCabinet'
                        SourceTable = 'Media'
                        SourceKey   = ("{0}:{1}" -f $cabinet.DiskId, $cabinet.Cabinet)
                        Size        = $cabinet.Size
                        CanExtract  = $cabinet.CanExtract
                        Warnings    = @($cabinet.Warnings)
                    })
                }
                Set-MsiLensExitCode 0
                return
            }
            { @('extract-file', 'extract-files') -contains $_ } {
                $options = ConvertTo-MsiLensExtractionOptions -Command $normalized -CommandArguments $CommandArguments
                Invoke-MsiLensExtraction -Connection $connection -MsiPath $MsiPath -Options $options
                return
            }
            { @('extract-binary', 'extract-binaries') -contains $_ } {
                $options = ConvertTo-MsiLensExtractionOptions -Command $normalized -CommandArguments $CommandArguments
                Invoke-MsiLensArtifactExtraction -Connection $connection -MsiPath $MsiPath -Options $options -Kind 'Binary'
                return
            }
            { @('extract-cabinet', 'extract-cabinets') -contains $_ } {
                $options = ConvertTo-MsiLensExtractionOptions -Command $normalized -CommandArguments $CommandArguments
                Invoke-MsiLensArtifactExtraction -Connection $connection -MsiPath $MsiPath -Options $options -Kind 'Cabinet'
                return
            }
        }
    } catch {
        if ($_.Exception.Message -like 'Missing required column *') {
            Write-MsiLensError -Code 'MissingRequiredTable' -Message $_.Exception.Message
            Set-MsiLensExitCode 5
        } else {
            Write-MsiLensError -Code 'MsiQueryFailed' -Message $_.Exception.Message
            Set-MsiLensExitCode 4
        }
        return
    } finally {
        Close-MsiLensDatabase $connection
    }
}

function Invoke-MsiLensGlobalCommand {
    param(
        [string] $Command,
        [string[]] $CommandArguments
    )

    $normalized = Resolve-MsiLensAlias $Command
    switch ($normalized) {
        'help' {
            if ($CommandArguments.Count -gt 1) {
                Write-MsiLensError -Code 'InvalidArgument' -Message 'help accepts zero or one command name.' -Category InvalidArgument
                Set-MsiLensExitCode 2
                return
            }
            if ($CommandArguments.Count -eq 1) {
                Show-MsiLensHelp $CommandArguments[0]
                return
            }
            Show-MsiLensHelp
            return
        }
        'version' {
            if (-not (Test-MsiLensNoArguments $normalized $CommandArguments)) { return }
            Get-MsiLensVersion
            Set-MsiLensExitCode 0
            return
        }
        'examples' {
            if (-not (Test-MsiLensNoArguments $normalized $CommandArguments)) { return }
            Show-MsiLensExamples
            return
        }
        default {
            Write-MsiLensError -Code 'UnknownCommand' -Message ("Unknown command '{0}'." -f $Command) -Category InvalidArgument
            Set-MsiLensExitCode 2
            return
        }
    }
}

function Split-MsiLensCommandLine {
    param([string] $Line)

    $tokens = New-Object System.Collections.ArrayList
    $builder = New-Object System.Text.StringBuilder
    $quote = $null
    $inToken = $false

    for ($index = 0; $index -lt $Line.Length; $index++) {
        $char = $Line[$index]

        if ($char -eq '`') {
            if ($index + 1 -lt $Line.Length) {
                $null = $builder.Append($Line[$index + 1])
                $inToken = $true
                $index++
                continue
            }
            $null = $builder.Append($char)
            $inToken = $true
            continue
        }

        if ($null -ne $quote) {
            if ($char -eq $quote) {
                $quote = $null
            } else {
                $null = $builder.Append($char)
            }
            $inToken = $true
            continue
        }

        if ($char -eq '"' -or $char -eq "'") {
            $quote = $char
            $inToken = $true
            continue
        }

        if ([char]::IsWhiteSpace($char)) {
            if ($inToken) {
                [void]$tokens.Add($builder.ToString())
                $null = $builder.Clear()
                $inToken = $false
            }
            continue
        }

        $null = $builder.Append($char)
        $inToken = $true
    }

    if ($null -ne $quote) {
        throw 'Unmatched quote in command line.'
    }

    if ($inToken) {
        [void]$tokens.Add($builder.ToString())
    }

    [string[]]$tokens.ToArray([string])
}

function Split-MsiLensReplInput {
    param([string] $Line)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Line, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw $parseErrors[0].Message
    }

    if ($null -eq $ast.EndBlock -or $ast.EndBlock.Statements.Count -eq 0) {
        return [pscustomobject]@{
            CommandLine  = ''
            Continuation = $null
        }
    }

    $firstStatement = $ast.EndBlock.Statements[0]
    if ($firstStatement -is [System.Management.Automation.Language.ExitStatementAst]) {
        return [pscustomobject]@{
            CommandLine  = $firstStatement.Extent.Text.Trim()
            Continuation = $Line.Substring($firstStatement.Extent.EndOffset).TrimStart()
        }
    }

    if (-not ($firstStatement -is [System.Management.Automation.Language.PipelineAst]) -or $firstStatement.PipelineElements.Count -eq 0) {
        throw 'REPL input must start with a MsiLens command.'
    }

    $firstCommand = $firstStatement.PipelineElements[0]
    if (-not ($firstCommand -is [System.Management.Automation.Language.CommandAst])) {
        throw 'REPL input must start with a MsiLens command.'
    }

    $commandLine = $firstCommand.Extent.Text.Trim()
    $continuation = $Line.Substring($firstCommand.Extent.EndOffset).TrimStart()

    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        throw 'REPL input must start with a MsiLens command.'
    }

    [pscustomobject]@{
        CommandLine  = $commandLine
        Continuation = $continuation
    }
}

function Get-MsiLensReplCommands {
    @('open', 'close', 'clear', 'exit', 'quit') + (Get-MsiLensGlobalCommands) + (Get-MsiLensScopedCommands) |
        Sort-Object -Unique
}

function New-MsiLensCompletionCandidate {
    param(
        [string] $CompletionText,
        [string] $ListItemText,
        [int] $ReplacementIndex,
        [int] $ReplacementLength
    )

    if ([string]::IsNullOrEmpty($ListItemText)) {
        $ListItemText = $CompletionText
    }

    [pscustomobject]@{
        CompletionText    = $CompletionText
        ListItemText      = $ListItemText
        ReplacementIndex  = $ReplacementIndex
        ReplacementLength = $ReplacementLength
    }
}

function Protect-MsiLensCompletionText {
    param([string] $Text)

    if ($Text -match '[\s''"]') {
        return ('"{0}"' -f ($Text -replace '`', '``' -replace '"', '`"'))
    }
    $Text
}

function Get-MsiLensCompletionTokens {
    param(
        [string] $Line,
        [int] $CursorIndex
    )

    if ($null -eq $Line) {
        $Line = ''
    }
    if ($CursorIndex -lt 0) {
        $CursorIndex = 0
    }
    if ($CursorIndex -gt $Line.Length) {
        $CursorIndex = $Line.Length
    }

    $tokens = New-Object System.Collections.ArrayList
    $builder = New-Object System.Text.StringBuilder
    $quote = $null
    $tokenStart = -1
    $inToken = $false
    $currentToken = $null

    for ($index = 0; $index -lt $Line.Length; $index++) {
        $char = $Line[$index]

        if ($char -eq '`') {
            if (-not $inToken) {
                $inToken = $true
                $tokenStart = $index
            }
            if ($index + 1 -lt $Line.Length) {
                $null = $builder.Append($Line[$index + 1])
                $index++
            } else {
                $null = $builder.Append($char)
            }
            continue
        }

        if ($null -ne $quote) {
            if ($char -eq $quote) {
                $quote = $null
            } else {
                $null = $builder.Append($char)
            }
            continue
        }

        if ($char -eq '"' -or $char -eq "'") {
            if (-not $inToken) {
                $inToken = $true
                $tokenStart = $index
            }
            $quote = $char
            continue
        }

        if ([char]::IsWhiteSpace($char)) {
            if ($inToken) {
                $token = [pscustomobject]@{
                    Text  = $builder.ToString()
                    Start = $tokenStart
                    End   = $index
                }
                [void]$tokens.Add($token)
                if ($CursorIndex -ge $token.Start -and $CursorIndex -le $token.End) {
                    $currentToken = $token
                }
                $null = $builder.Clear()
                $inToken = $false
                $tokenStart = -1
            }
            continue
        }

        if (-not $inToken) {
            $inToken = $true
            $tokenStart = $index
        }
        $null = $builder.Append($char)
    }

    if ($inToken) {
        $token = [pscustomobject]@{
            Text  = $builder.ToString()
            Start = $tokenStart
            End   = $Line.Length
        }
        [void]$tokens.Add($token)
        if ($CursorIndex -ge $token.Start -and $CursorIndex -le $token.End) {
            $currentToken = $token
        }
    }

    $tokenIndex = -1
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        if ($tokens[$index] -eq $currentToken) {
            $tokenIndex = $index
            break
        }
    }

    if ($null -eq $currentToken) {
        $currentToken = [pscustomobject]@{
            Text  = ''
            Start = $CursorIndex
            End   = $CursorIndex
        }
        $tokenIndex = $tokens.Count
    }

    [pscustomobject]@{
        Tokens       = @($tokens.ToArray())
        CurrentToken = $currentToken
        TokenIndex   = $tokenIndex
    }
}

function Find-MsiLensMatchingCompletions {
    param(
        [string[]] $Candidates,
        [string] $Prefix,
        [int] $ReplacementIndex,
        [int] $ReplacementLength
    )

    foreach ($candidate in ($Candidates | Sort-Object -Unique)) {
        if ([string]::IsNullOrEmpty($Prefix) -or $candidate.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            New-MsiLensCompletionCandidate -CompletionText (Protect-MsiLensCompletionText $candidate) -ListItemText $candidate -ReplacementIndex $ReplacementIndex -ReplacementLength $ReplacementLength
        }
    }
}

function Complete-MsiLensPath {
    param(
        [string] $Prefix,
        [int] $ReplacementIndex,
        [int] $ReplacementLength
    )

    $pathPrefix = if ($null -eq $Prefix) { '' } else { $Prefix }
    $parent = ''
    $leafPrefix = $pathPrefix

    if (-not [string]::IsNullOrEmpty($pathPrefix)) {
        $lastSlash = $pathPrefix.LastIndexOfAny([char[]]@('\', '/'))
        if ($lastSlash -ge 0) {
            $parent = $pathPrefix.Substring(0, $lastSlash + 1)
            $leafPrefix = $pathPrefix.Substring($lastSlash + 1)
        }
    }

    $searchRoot = if ([string]::IsNullOrEmpty($parent)) { '.' } else { $parent }
    if (-not (Test-Path -LiteralPath $searchRoot)) {
        return
    }

    try {
        foreach ($item in Get-ChildItem -LiteralPath $searchRoot -ErrorAction Stop) {
            if (-not [string]::IsNullOrEmpty($leafPrefix) -and -not $item.Name.StartsWith($leafPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            if ([string]::IsNullOrEmpty($parent)) {
                $completion = $item.Name
            } else {
                $completion = Join-Path $parent $item.Name
            }
            if ($item.PSIsContainer) {
                $completion = $completion.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
            }

            New-MsiLensCompletionCandidate -CompletionText (Protect-MsiLensCompletionText $completion) -ListItemText $completion -ReplacementIndex $ReplacementIndex -ReplacementLength $ReplacementLength
        }
    } catch {
        return
    }
}

function Get-MsiLensTableNameCompletions {
    param(
        [string] $CurrentPath,
        [string] $Prefix,
        [int] $ReplacementIndex,
        [int] $ReplacementLength
    )

    $tables = @(Get-MsiLensCachedTableNames -CurrentPath $CurrentPath)
    Find-MsiLensMatchingCompletions -Candidates $tables -Prefix $Prefix -ReplacementIndex $ReplacementIndex -ReplacementLength $ReplacementLength
}

function Get-MsiLensPropertyNameCompletions {
    param(
        [string] $CurrentPath,
        [string] $Prefix,
        [int] $ReplacementIndex,
        [int] $ReplacementLength
    )

    $properties = @(Get-MsiLensCachedPropertyNames -CurrentPath $CurrentPath)
    Find-MsiLensMatchingCompletions -Candidates $properties -Prefix $Prefix -ReplacementIndex $ReplacementIndex -ReplacementLength $ReplacementLength
}

function Get-MsiLensFileNameCompletions {
    param(
        [string] $CurrentPath,
        [string] $Prefix,
        [int] $ReplacementIndex,
        [int] $ReplacementLength
    )

    $candidates = @(Get-MsiLensCachedFileCompletionNames -CurrentPath $CurrentPath)
    Find-MsiLensMatchingCompletions -Candidates $candidates -Prefix $Prefix -ReplacementIndex $ReplacementIndex -ReplacementLength $ReplacementLength
}

function Get-MsiLensReplCompletionCommandEnd {
    param([string] $Line)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Line, [ref]$tokens, [ref]$parseErrors)
    if ($null -eq $ast.EndBlock -or $ast.EndBlock.Statements.Count -eq 0) {
        return $null
    }

    $firstStatement = $ast.EndBlock.Statements[0]
    if ($firstStatement -is [System.Management.Automation.Language.ExitStatementAst]) {
        return $firstStatement.Extent.EndOffset
    }
    if (-not ($firstStatement -is [System.Management.Automation.Language.PipelineAst]) -or $firstStatement.PipelineElements.Count -eq 0) {
        return $null
    }

    $firstCommand = $firstStatement.PipelineElements[0]
    if (-not ($firstCommand -is [System.Management.Automation.Language.CommandAst])) {
        return $null
    }

    $firstCommand.Extent.EndOffset
}

function Get-MsiLensTableCommandPropertyNames {
    param(
        [string[]] $Tokens,
        [string] $CurrentPath
    )

    if ($Tokens.Count -lt 2 -or [string]::IsNullOrWhiteSpace($CurrentPath)) {
        return
    }

    $connection = $null
    try {
        $connection = Open-MsiLensDatabase $CurrentPath
        $table = Resolve-MsiLensTableName -Connection $connection -Table $Tokens[1]
        $columns = @(Get-MsiLensColumnsFromConnection -Connection $connection -Table $table)
        $names = New-Object System.Collections.ArrayList
        [void]$names.Add('Row')
        foreach ($column in $columns) {
            [void]$names.Add((Get-MsiLensSafeColumnPropertyName $column.Name))
        }
        return [string[]]$names.ToArray([string])
    } catch {
        return
    } finally {
        Close-MsiLensDatabase $connection
    }
}

function Get-MsiLensKnownCommandPropertyNames {
    param([string] $Command)

    switch ($Command) {
        'version' { return @('Name', 'Version', 'ProjectUrl', 'ScriptPath', 'PowerShellVersion', 'Platform') }
        'info' { return @('ProductName', 'ProductVersion', 'ProductCode', 'Manufacturer', 'PackageCode', 'TableCount', 'IsSigned', 'SignatureStatus') }
        'tables' { return @('Table') }
        'columns' { return @('Table', 'Column', 'Number', 'Type', 'Nullable', 'PrimaryKey') }
        'properties' { return @('Property', 'Value') }
        'property' { return @('Property', 'Value') }
        'files' { return @('File', 'Component', 'RawFileName', 'FileName', 'ShortFileName', 'LongFileName', 'FileSize', 'Version', 'Language', 'Attributes', 'Sequence') }
        'file' { return @('File', 'Component', 'RawFileName', 'FileName', 'ShortFileName', 'LongFileName', 'FileSize', 'Version', 'Language', 'Attributes', 'Sequence') }
        'binaries' { return @('Name', 'Table', 'SourceKind', 'Size', 'CanExtract', 'Warnings', 'AmbiguousMatch') }
        'binary' { return @('Name', 'Table', 'SourceKind', 'Size', 'CanExtract', 'Warnings', 'AmbiguousMatch') }
        'cabinets' { return @('Cabinet', 'StreamName', 'SourceKind', 'DiskId', 'LastSequence', 'Size', 'CanExtract', 'Warnings', 'AmbiguousMatch') }
        'cabinet' { return @('Cabinet', 'StreamName', 'SourceKind', 'DiskId', 'LastSequence', 'Size', 'CanExtract', 'Warnings', 'AmbiguousMatch') }
        'streams' { return @('Name', 'Scope', 'SourceTable', 'SourceKey', 'Size', 'CanExtract', 'Warnings') }
        'extract-file' { return @('Status', 'MsiPath', 'File', 'Component', 'Directory', 'RawFileName', 'FileName', 'ShortFileName', 'LongFileName', 'OriginalOutputName', 'OriginalRelativePath', 'RelativePath', 'ChangedPathSegments', 'OutputPath', 'Layout', 'SourceKind', 'Cabinet', 'DiskId', 'Sequence', 'FileSize', 'BytesWritten', 'Verified', 'VerificationWarnings', 'Warnings', 'Sanitized', 'WouldOverwrite', 'AmbiguousMatch', 'MatchedFields', 'Message') }
        'extract-files' { return @('Status', 'MsiPath', 'File', 'Component', 'Directory', 'RawFileName', 'FileName', 'ShortFileName', 'LongFileName', 'OriginalOutputName', 'OriginalRelativePath', 'RelativePath', 'ChangedPathSegments', 'OutputPath', 'Layout', 'SourceKind', 'Cabinet', 'DiskId', 'Sequence', 'FileSize', 'BytesWritten', 'Verified', 'VerificationWarnings', 'Warnings', 'Sanitized', 'WouldOverwrite', 'AmbiguousMatch', 'MatchedFields', 'Message') }
        { @('extract-binary', 'extract-binaries', 'extract-cabinet', 'extract-cabinets') -contains $_ } { return @('Status', 'MsiPath', 'ArtifactKind', 'Name', 'SourceTable', 'SourceKey', 'OriginalOutputName', 'RelativePath', 'ChangedPathSegments', 'OutputPath', 'BytesWritten', 'Verified', 'VerificationWarnings', 'Warnings', 'Sanitized', 'WouldOverwrite', 'AmbiguousMatch', 'MatchedFields', 'Message') }
        'signature' { return @('Scope', 'TrustScope', 'TrustLimitations', 'IsSigned', 'IsValid', 'Status', 'StatusMessage', 'SignerSubject', 'SignerIssuer', 'SignerSerialNumber', 'SignerThumbprint', 'SignerNotBefore', 'SignerNotAfter', 'SignerEnhancedKeyUsages', 'TimestampSubject', 'TimestampTime') }
    }
}

function Get-MsiLensReplCommandPropertyNames {
    param(
        [string] $CommandLine,
        [string] $CurrentPath
    )

    try {
        $tokens = @(Split-MsiLensCommandLine $CommandLine)
    } catch {
        return
    }
    if ($tokens.Count -eq 0) {
        return
    }

    $command = Resolve-MsiLensAlias $tokens[0]
    if ($command -eq 'table') {
        return Get-MsiLensTableCommandPropertyNames -Tokens $tokens -CurrentPath $CurrentPath
    }

    Get-MsiLensKnownCommandPropertyNames -Command $command
}

function Resolve-MsiLensPowerShellCommandInfo {
    param([string] $CommandName)

    if ([string]::IsNullOrWhiteSpace($CommandName)) {
        return $null
    }

    $aliases = @(Get-Alias -Name $CommandName -ErrorAction SilentlyContinue)
    foreach ($alias in $aliases) {
        if ($alias.Name -eq $CommandName) {
            return $alias.ResolvedCommand
        }
    }
    if ($aliases.Count -gt 0) {
        return $aliases[0].ResolvedCommand
    }

    $commands = @(Get-Command -Name $CommandName -ErrorAction SilentlyContinue)
    foreach ($command in $commands) {
        if ($command.Name -eq $CommandName) {
            return $command
        }
    }
    if ($commands.Count -gt 0) {
        return $commands[0]
    }

    $null
}

function Resolve-MsiLensPowerShellParameterInfo {
    param(
        [object] $CommandInfo,
        [string] $ParameterName
    )

    if ($null -eq $CommandInfo -or $null -eq $CommandInfo.Parameters -or [string]::IsNullOrWhiteSpace($ParameterName)) {
        return $null
    }

    $parameters = @($CommandInfo.Parameters.Values)
    foreach ($parameter in $parameters) {
        if ($parameter.Name -eq $ParameterName) {
            return $parameter
        }
        if (@($parameter.Aliases) -contains $ParameterName) {
            return $parameter
        }
    }

    $foundMatches = @($parameters | Where-Object {
        $_.Name.StartsWith($ParameterName, [System.StringComparison]::OrdinalIgnoreCase) -or
            (@($_.Aliases) | Where-Object { $_.StartsWith($ParameterName, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    })
    if ($foundMatches.Count -eq 1) {
        return $foundMatches[0]
    }

    $null
}

function Test-MsiLensPowerShellParameterRequiresValue {
    param([object] $ParameterInfo)

    if ($null -eq $ParameterInfo -or $null -eq $ParameterInfo.ParameterType) {
        return $false
    }

    $ParameterInfo.ParameterType.FullName -ne 'System.Management.Automation.SwitchParameter'
}

function Test-MsiLensPowerShellPropertyParameter {
    param([object] $ParameterInfo)

    if ($null -eq $ParameterInfo) {
        return $false
    }

    $name = $ParameterInfo.Name
    $name -eq 'Property' -or
        $name.EndsWith('Property', [System.StringComparison]::OrdinalIgnoreCase) -or
        $name -eq 'GroupBy'
}

function Get-MsiLensPowerShellPositionalParameterInfo {
    param(
        [object] $CommandInfo,
        [int] $Position
    )

    if ($null -eq $CommandInfo -or $null -eq $CommandInfo.ParameterSets) {
        return $null
    }

    $seen = @{}
    $foundMatches = New-Object System.Collections.ArrayList
    foreach ($parameterSet in $CommandInfo.ParameterSets) {
        foreach ($parameter in $parameterSet.Parameters) {
            if ($parameter.Position -ne $Position -or $seen.ContainsKey($parameter.Name)) {
                continue
            }

            $seen[$parameter.Name] = $true
            $parameterInfo = Resolve-MsiLensPowerShellParameterInfo -CommandInfo $CommandInfo -ParameterName $parameter.Name
            if ($null -ne $parameterInfo) {
                [void]$foundMatches.Add($parameterInfo)
            }
        }
    }

    foreach ($match in $foundMatches) {
        if (Test-MsiLensPowerShellPropertyParameter $match) {
            return $match
        }
    }

    if ($foundMatches.Count -eq 1) {
        return $foundMatches[0]
    }

    $null
}

function Find-MsiLensPowerShellCommandAstAtCursor {
    param(
        [System.Management.Automation.Language.Ast] $Ast,
        [int] $CursorIndex
    )

    $commands = @($Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true) | Sort-Object { $_.Extent.StartOffset }, { $_.Extent.EndOffset })

    $containing = @($commands | Where-Object {
            $_.Extent.StartOffset -le $CursorIndex -and $_.Extent.EndOffset -ge $CursorIndex
        } | Select-Object -Last 1)
    if ($containing.Count -gt 0) {
        return $containing[0]
    }

    $beforeCursor = @($commands | Where-Object { $_.Extent.EndOffset -le $CursorIndex } | Select-Object -Last 1)
    if ($beforeCursor.Count -gt 0) {
        return $beforeCursor[0]
    }

    $null
}

function Get-MsiLensPowerShellPropertyArgumentContext {
    param(
        [string] $Line,
        [int] $CursorIndex,
        [int] $CommandEnd
    )

    if ($CursorIndex -le $CommandEnd) {
        return
    }

    $continuation = $Line.Substring($CommandEnd)
    $relativeCursor = $CursorIndex - $CommandEnd
    $prefixScript = if ($continuation.TrimStart().StartsWith('|', [System.StringComparison]::Ordinal)) {
        '$InputObject '
    } else {
        'Write-Output $null '
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(($prefixScript + $continuation), [ref]$tokens, [ref]$parseErrors)
    $prefixedCursor = $prefixScript.Length + $relativeCursor
    $commandAst = Find-MsiLensPowerShellCommandAstAtCursor -Ast $ast -CursorIndex $prefixedCursor
    if ($null -eq $commandAst) {
        return
    }

    $commandName = $commandAst.GetCommandName()
    $commandInfo = Resolve-MsiLensPowerShellCommandInfo -CommandName $commandName
    if ($null -eq $commandInfo -or $null -eq $commandInfo.Parameters) {
        return
    }

    $elements = @($commandAst.CommandElements)
    $pendingParameter = $null
    $position = 0
    $lastElement = $elements[0]
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]

        if ($prefixedCursor -lt $element.Extent.StartOffset) {
            if ($null -ne $pendingParameter) {
                $parameterInfo = $pendingParameter
            } else {
                $parameterInfo = Get-MsiLensPowerShellPositionalParameterInfo -CommandInfo $commandInfo -Position $position
            }

            return [pscustomobject]@{
                ParameterInfo     = $parameterInfo
                ReplacementIndex  = $CommandEnd + ($prefixedCursor - $prefixScript.Length)
                ReplacementLength = 0
                Prefix            = ''
                NeedsLeadingSpace = ($prefixedCursor -eq $lastElement.Extent.EndOffset)
            }
        }

        if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
            $parameterInfo = Resolve-MsiLensPowerShellParameterInfo -CommandInfo $commandInfo -ParameterName $element.ParameterName
            if ($prefixedCursor -le $element.Extent.EndOffset) {
                if ($prefixedCursor -eq $element.Extent.EndOffset -and
                    $null -ne $parameterInfo -and
                    $parameterInfo.Name -eq $element.ParameterName) {
                    return [pscustomobject]@{
                        ParameterInfo     = $parameterInfo
                        ReplacementIndex  = $CommandEnd + ($prefixedCursor - $prefixScript.Length)
                        ReplacementLength = 0
                        Prefix            = ''
                        NeedsLeadingSpace = $true
                    }
                }
                return
            }

            if ($null -ne $parameterInfo -and (Test-MsiLensPowerShellParameterRequiresValue $parameterInfo)) {
                $pendingParameter = $parameterInfo
            } else {
                $pendingParameter = $null
            }
            $lastElement = $element
            continue
        }

        if ($prefixedCursor -le $element.Extent.EndOffset) {
            if ($null -ne $pendingParameter) {
                $parameterInfo = $pendingParameter
            } else {
                $parameterInfo = Get-MsiLensPowerShellPositionalParameterInfo -CommandInfo $commandInfo -Position $position
            }

            $prefixLength = $prefixedCursor - $element.Extent.StartOffset
            return [pscustomobject]@{
                ParameterInfo     = $parameterInfo
                ReplacementIndex  = $CommandEnd + ($element.Extent.StartOffset - $prefixScript.Length)
                ReplacementLength = $prefixLength
                Prefix            = $Line.Substring(($CommandEnd + ($element.Extent.StartOffset - $prefixScript.Length)), $prefixLength)
                NeedsLeadingSpace = $false
            }
        }

        if ($null -ne $pendingParameter) {
            $pendingParameter = $null
        } else {
            $position++
        }
        $lastElement = $element
    }

    if ($null -ne $pendingParameter) {
        $parameterInfo = $pendingParameter
    } else {
        $parameterInfo = Get-MsiLensPowerShellPositionalParameterInfo -CommandInfo $commandInfo -Position $position
    }

    [pscustomobject]@{
        ParameterInfo     = $parameterInfo
        ReplacementIndex  = $CommandEnd + ($prefixedCursor - $prefixScript.Length)
        ReplacementLength = 0
        Prefix            = ''
        NeedsLeadingSpace = ($prefixedCursor -eq $lastElement.Extent.EndOffset)
    }
}

function Complete-MsiLensPowerShellPropertyArgument {
    param(
        [string] $Line,
        [int] $CursorIndex,
        [string] $CommandLine,
        [int] $CommandEnd,
        [string] $CurrentPath
    )

    $context = Get-MsiLensPowerShellPropertyArgumentContext -Line $Line -CursorIndex $CursorIndex -CommandEnd $CommandEnd
    if ($null -eq $context -or -not (Test-MsiLensPowerShellPropertyParameter $context.ParameterInfo)) {
        return
    }

    $properties = @(Get-MsiLensReplCommandPropertyNames -CommandLine $CommandLine -CurrentPath $CurrentPath)
    $completions = @(Find-MsiLensMatchingCompletions -Candidates $properties -Prefix $context.Prefix -ReplacementIndex $context.ReplacementIndex -ReplacementLength $context.ReplacementLength)
    if (-not $context.NeedsLeadingSpace) {
        return $completions
    }

    foreach ($completion in $completions) {
        New-MsiLensCompletionCandidate -CompletionText (' {0}' -f $completion.CompletionText) -ListItemText $completion.ListItemText -ReplacementIndex $completion.ReplacementIndex -ReplacementLength $completion.ReplacementLength
    }
}

function Complete-MsiLensPowerShellContinuation {
    param(
        [string] $Line,
        [int] $CursorIndex,
        [int] $CommandEnd
    )

    if ($CursorIndex -le $CommandEnd) {
        return
    }

    $continuation = $Line.Substring($CommandEnd)
    $relativeCursor = $CursorIndex - $CommandEnd
    if ($relativeCursor -lt 0) {
        $relativeCursor = 0
    }
    if ($relativeCursor -gt $continuation.Length) {
        $relativeCursor = $continuation.Length
    }

    $prefixScript = if ($continuation.TrimStart().StartsWith('|', [System.StringComparison]::Ordinal)) {
        '$InputObject '
    } else {
        'Write-Output $null '
    }

    try {
        $completion = [System.Management.Automation.CommandCompletion]::CompleteInput(
            ($prefixScript + $continuation),
            ($prefixScript.Length + $relativeCursor),
            $null)
    } catch {
        return
    }

    $replacementIndex = $CommandEnd + ($completion.ReplacementIndex - $prefixScript.Length)
    if ($replacementIndex -lt $CommandEnd) {
        $replacementIndex = $CommandEnd
    }

    foreach ($match in $completion.CompletionMatches) {
        New-MsiLensCompletionCandidate -CompletionText $match.CompletionText -ListItemText $match.ListItemText -ReplacementIndex $replacementIndex -ReplacementLength $completion.ReplacementLength
    }
}

function Get-MsiLensCompletionCacheEntry {
    param([string] $CurrentPath)

    if ([string]::IsNullOrWhiteSpace($CurrentPath)) {
        return $null
    }

    try {
        $resolved = Resolve-MsiLensPath $CurrentPath
        if ($null -eq $resolved) {
            return $null
        }

        $item = Get-Item -LiteralPath $resolved -ErrorAction Stop
    } catch {
        return $null
    }

    $key = $resolved.ToLowerInvariant()
    $lastWriteTimeUtcTicks = $item.LastWriteTimeUtc.Ticks
    $length = $item.Length

    if ($script:MsiLensCompletionCache.ContainsKey($key)) {
        $entry = $script:MsiLensCompletionCache[$key]
        if ($entry.LastWriteTimeUtcTicks -eq $lastWriteTimeUtcTicks -and $entry.Length -eq $length) {
            return $entry
        }
    }

    $entry = [pscustomobject]@{
        Path                  = $resolved
        LastWriteTimeUtcTicks = $lastWriteTimeUtcTicks
        Length                = $length
        Tables                = $null
        Properties            = $null
        Files                 = $null
        Binaries              = $null
        Cabinets              = $null
    }
    $script:MsiLensCompletionCache[$key] = $entry
    $entry
}

function Get-MsiLensCachedTableNames {
    param([string] $CurrentPath)

    $entry = Get-MsiLensCompletionCacheEntry -CurrentPath $CurrentPath
    if ($null -eq $entry) {
        return
    }

    if ($null -ne $entry.Tables) {
        return $entry.Tables
    }

    $connection = $null
    try {
        $connection = Open-MsiLensDatabase $entry.Path
        $entry.Tables = @(Get-MsiLensTablesFromConnection $connection)
        return $entry.Tables
    } catch {
        $entry.Tables = @()
        return
    } finally {
        Close-MsiLensDatabase $connection
    }
}

function Get-MsiLensCachedPropertyNames {
    param([string] $CurrentPath)

    $entry = Get-MsiLensCompletionCacheEntry -CurrentPath $CurrentPath
    if ($null -eq $entry) {
        return
    }

    if ($null -ne $entry.Properties) {
        return $entry.Properties
    }

    $connection = $null
    try {
        $connection = Open-MsiLensDatabase $entry.Path
        $entry.Properties = @(Get-MsiLensPropertiesFromConnection $connection | ForEach-Object { $_.Property })
        return $entry.Properties
    } catch {
        $entry.Properties = @()
        return
    } finally {
        Close-MsiLensDatabase $connection
    }
}

function Get-MsiLensCachedFileCompletionNames {
    param([string] $CurrentPath)

    $entry = Get-MsiLensCompletionCacheEntry -CurrentPath $CurrentPath
    if ($null -eq $entry) {
        return
    }

    if ($null -ne $entry.Files) {
        return $entry.Files
    }

    $connection = $null
    try {
        $connection = Open-MsiLensDatabase $entry.Path
        $files = @(Get-MsiLensFilesFromConnection $connection)
        $candidates = New-Object System.Collections.ArrayList
        foreach ($file in $files) {
            foreach ($candidate in @($file.File, $file.FileName, $file.ShortFileName, $file.LongFileName, $file.RawFileName)) {
                if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                    [void]$candidates.Add([string]$candidate)
                }
            }
        }
        $entry.Files = [string[]]$candidates.ToArray([string])
        return $entry.Files
    } catch {
        $entry.Files = @()
        return
    } finally {
        Close-MsiLensDatabase $connection
    }
}

function Get-MsiLensCachedBinaryCompletionNames {
    param([string] $CurrentPath)

    $entry = Get-MsiLensCompletionCacheEntry -CurrentPath $CurrentPath
    if ($null -eq $entry) { return }
    if ($null -ne $entry.Binaries) { return $entry.Binaries }

    $connection = $null
    try {
        $connection = Open-MsiLensDatabase $entry.Path
        $entry.Binaries = @(Get-MsiLensBinaryRecords $connection | ForEach-Object { $_.Name })
        return $entry.Binaries
    } catch {
        $entry.Binaries = @()
        return
    } finally {
        Close-MsiLensDatabase $connection
    }
}

function Get-MsiLensCachedCabinetCompletionNames {
    param([string] $CurrentPath)

    $entry = Get-MsiLensCompletionCacheEntry -CurrentPath $CurrentPath
    if ($null -eq $entry) { return }
    if ($null -ne $entry.Cabinets) { return $entry.Cabinets }

    $connection = $null
    try {
        $connection = Open-MsiLensDatabase $entry.Path
        $candidates = New-Object System.Collections.ArrayList
        foreach ($cabinet in Get-MsiLensEmbeddedCabinetRecords $connection) {
            [void]$candidates.Add($cabinet.Cabinet)
            [void]$candidates.Add($cabinet.StreamName)
        }
        $entry.Cabinets = [string[]]$candidates.ToArray([string])
        return $entry.Cabinets
    } catch {
        $entry.Cabinets = @()
        return
    } finally {
        Close-MsiLensDatabase $connection
    }
}

function Get-MsiLensBinaryNameCompletions {
    param(
        [string] $CurrentPath,
        [string] $Prefix,
        [int] $ReplacementIndex,
        [int] $ReplacementLength
    )

    Find-MsiLensMatchingCompletions -Candidates @(Get-MsiLensCachedBinaryCompletionNames -CurrentPath $CurrentPath) -Prefix $Prefix -ReplacementIndex $ReplacementIndex -ReplacementLength $ReplacementLength
}

function Get-MsiLensCabinetNameCompletions {
    param(
        [string] $CurrentPath,
        [string] $Prefix,
        [int] $ReplacementIndex,
        [int] $ReplacementLength
    )

    Find-MsiLensMatchingCompletions -Candidates @(Get-MsiLensCachedCabinetCompletionNames -CurrentPath $CurrentPath) -Prefix $Prefix -ReplacementIndex $ReplacementIndex -ReplacementLength $ReplacementLength
}

function Complete-MsiLensReplInput {
    param(
        [string] $Line,
        [int] $CursorIndex,
        [string] $CurrentPath
    )

    $commandEnd = Get-MsiLensReplCompletionCommandEnd -Line $Line
    $continuationToCursor = ''
    if ($null -ne $commandEnd -and $CursorIndex -gt $commandEnd) {
        $continuationToCursor = $Line.Substring($commandEnd, ($CursorIndex - $commandEnd))
    }
    if ($null -ne $commandEnd -and $CursorIndex -gt $commandEnd -and -not [string]::IsNullOrWhiteSpace($continuationToCursor)) {
        $commandLine = $Line.Substring(0, $commandEnd).Trim()
        $propertyCompletions = @(Complete-MsiLensPowerShellPropertyArgument -Line $Line -CursorIndex $CursorIndex -CommandLine $commandLine -CommandEnd $commandEnd -CurrentPath $CurrentPath)
        if ($propertyCompletions.Count -gt 0) {
            return $propertyCompletions
        }

        return Complete-MsiLensPowerShellContinuation -Line $Line -CursorIndex $CursorIndex -CommandEnd $commandEnd
    }

    $context = Get-MsiLensCompletionTokens -Line $Line -CursorIndex $CursorIndex
    $tokens = @($context.Tokens)
    $current = $context.CurrentToken
    $prefix = $current.Text
    $replacementIndex = $current.Start
    $replacementLength = $current.End - $current.Start

    if ($context.TokenIndex -eq 0 -or $tokens.Count -eq 0) {
        return Find-MsiLensMatchingCompletions -Candidates (Get-MsiLensReplCommands) -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
    }

    $command = Resolve-MsiLensAlias $tokens[0].Text
    $argumentIndex = $context.TokenIndex - 1

    switch ($command) {
        'help' {
            if ($argumentIndex -eq 0) {
                return Find-MsiLensMatchingCompletions -Candidates ((Get-MsiLensGlobalCommands) + (Get-MsiLensScopedCommands)) -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
        }
        'open' {
            if ($argumentIndex -eq 0) {
                return Complete-MsiLensPath -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
        }
        { @('columns', 'table') -contains $_ } {
            if ($prefix.StartsWith('-', [System.StringComparison]::Ordinal)) {
                if ($command -eq 'table') {
                    return Find-MsiLensMatchingCompletions -Candidates @('-First') -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
                }
                return
            }
            if ($argumentIndex -eq 0) {
                return Get-MsiLensTableNameCompletions -CurrentPath $CurrentPath -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
            if ($command -eq 'table' -and $argumentIndex -ge 1) {
                return Find-MsiLensMatchingCompletions -Candidates @('-First') -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
        }
        'property' {
            if ($argumentIndex -eq 0) {
                return Get-MsiLensPropertyNameCompletions -CurrentPath $CurrentPath -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
        }
        'file' {
            if ($argumentIndex -eq 0) {
                return Get-MsiLensFileNameCompletions -CurrentPath $CurrentPath -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
        }
        'binary' {
            if ($argumentIndex -eq 0) {
                return Get-MsiLensBinaryNameCompletions -CurrentPath $CurrentPath -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
        }
        'cabinet' {
            if ($argumentIndex -eq 0) {
                return Get-MsiLensCabinetNameCompletions -CurrentPath $CurrentPath -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
        }
        'extract-file' {
            if ($prefix.StartsWith('-', [System.StringComparison]::Ordinal)) {
                return Find-MsiLensMatchingCompletions -Candidates @('-Out', '-Layout', '-DryRun', '-Force') -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
            if ($argumentIndex -eq 0) {
                return Get-MsiLensFileNameCompletions -CurrentPath $CurrentPath -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
            if ($tokens.Count -ge 2 -and $tokens[$tokens.Count - 2].Text -eq '-Out') {
                return Complete-MsiLensPath -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
            if ($tokens.Count -ge 2 -and $tokens[$tokens.Count - 2].Text -eq '-Layout') {
                return Find-MsiLensMatchingCompletions -Candidates @('Flat', 'InstalledTree') -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
            return Find-MsiLensMatchingCompletions -Candidates @('-Out', '-Layout', '-DryRun', '-Force') -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
        }
        'extract-binary' {
            if ($tokens.Count -ge 2 -and $tokens[$tokens.Count - 2].Text -eq '-Out') {
                return Complete-MsiLensPath -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
            if ($prefix.StartsWith('-', [System.StringComparison]::Ordinal)) {
                return Find-MsiLensMatchingCompletions -Candidates @('-Out', '-DryRun', '-Force') -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
            if ($argumentIndex -eq 0) {
                return Get-MsiLensBinaryNameCompletions -CurrentPath $CurrentPath -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
            return Find-MsiLensMatchingCompletions -Candidates @('-Out', '-DryRun', '-Force') -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
        }
        'extract-cabinet' {
            if ($tokens.Count -ge 2 -and $tokens[$tokens.Count - 2].Text -eq '-Out') {
                return Complete-MsiLensPath -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
            if ($prefix.StartsWith('-', [System.StringComparison]::Ordinal)) {
                return Find-MsiLensMatchingCompletions -Candidates @('-Out', '-DryRun', '-Force') -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
            if ($argumentIndex -eq 0) {
                return Get-MsiLensCabinetNameCompletions -CurrentPath $CurrentPath -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
            return Find-MsiLensMatchingCompletions -Candidates @('-Out', '-DryRun', '-Force') -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
        }
        'extract-files' {
            if ($tokens.Count -ge 2 -and $tokens[$tokens.Count - 2].Text -eq '-Out') {
                return Complete-MsiLensPath -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
            if ($tokens.Count -ge 2 -and $tokens[$tokens.Count - 2].Text -eq '-Layout') {
                return Find-MsiLensMatchingCompletions -Candidates @('Flat', 'InstalledTree') -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
            return Find-MsiLensMatchingCompletions -Candidates @('-Filter', '-All', '-Out', '-Layout', '-DryRun', '-Force') -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
        }
        { @('extract-binaries', 'extract-cabinets') -contains $_ } {
            if ($tokens.Count -ge 2 -and $tokens[$tokens.Count - 2].Text -eq '-Out') {
                return Complete-MsiLensPath -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
            }
            return Find-MsiLensMatchingCompletions -Candidates @('-Filter', '-All', '-Out', '-DryRun', '-Force') -Prefix $prefix -ReplacementIndex $replacementIndex -ReplacementLength $replacementLength
        }
    }
}

function Get-MsiLensCommonPrefix {
    param([string[]] $Values)

    if ($null -eq $Values -or $Values.Count -eq 0) {
        return ''
    }

    $prefix = $Values[0]
    foreach ($value in $Values) {
        while ($prefix.Length -gt 0 -and -not $value.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $prefix = $prefix.Substring(0, $prefix.Length - 1)
        }
    }
    $prefix
}

function Set-MsiLensPsReadLineCompletionText {
    param(
        [string] $Line,
        [int] $ReplacementIndex,
        [int] $ReplacementLength,
        [string] $Replacement
    )

    [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($ReplacementIndex)
    if ($ReplacementLength -gt 0) {
        [Microsoft.PowerShell.PSConsoleReadLine]::Delete($ReplacementIndex, $ReplacementLength)
    }
    [Microsoft.PowerShell.PSConsoleReadLine]::Insert($Replacement)

    $suffixStart = $ReplacementIndex + $ReplacementLength
    if ($suffixStart -gt $Line.Length) {
        $suffixStart = $Line.Length
    }

    $Line.Substring(0, $ReplacementIndex) + $Replacement + $Line.Substring($suffixStart)
}

function Invoke-MsiLensPsReadLineCompletion {
    param(
        [ValidateSet('Next', 'Previous')]
        [string] $Direction = 'Next'
    )

    $line = $null
    $cursorIndex = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursorIndex)

    $cycle = $script:MsiLensCompletionCycle
    if ($null -ne $cycle -and
        $line -eq $cycle.Line -and
        $cursorIndex -eq ($cycle.ReplacementIndex + $cycle.CurrentText.Length) -and
        $cycle.Candidates.Count -gt 1) {
        if ($Direction -eq 'Previous') {
            $nextIndex = ($cycle.Index - 1 + $cycle.Candidates.Count) % $cycle.Candidates.Count
        } else {
            $nextIndex = ($cycle.Index + 1) % $cycle.Candidates.Count
        }
        $replacement = $cycle.Candidates[$nextIndex]
        $updatedLine = Set-MsiLensPsReadLineCompletionText -Line $line -ReplacementIndex $cycle.ReplacementIndex -ReplacementLength $cycle.CurrentText.Length -Replacement $replacement
        $script:MsiLensCompletionCycle = [pscustomobject]@{
            Line             = $updatedLine
            ReplacementIndex = $cycle.ReplacementIndex
            CurrentText      = $replacement
            Candidates       = $cycle.Candidates
            Index            = $nextIndex
        }
        return
    }

    $completions = @(Complete-MsiLensReplInput -Line $line -CursorIndex $cursorIndex -CurrentPath $script:MsiLensCompletionCurrentPath)
    if ($completions.Count -eq 0) {
        $script:MsiLensCompletionCycle = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::Ding()
        return
    }

    $candidateTexts = @($completions | ForEach-Object { $_.CompletionText })
    $candidateIndex = if ($Direction -eq 'Previous' -and $candidateTexts.Count -gt 1) { $candidateTexts.Count - 1 } else { 0 }
    $replacement = $candidateTexts[$candidateIndex]
    $updatedLine = Set-MsiLensPsReadLineCompletionText -Line $line -ReplacementIndex $completions[0].ReplacementIndex -ReplacementLength $completions[0].ReplacementLength -Replacement $replacement

    if ($candidateTexts.Count -gt 1) {
        $script:MsiLensCompletionCycle = [pscustomobject]@{
            Line             = $updatedLine
            ReplacementIndex = $completions[0].ReplacementIndex
            CurrentText      = $replacement
            Candidates       = $candidateTexts
            Index            = $candidateIndex
        }
    } else {
        $script:MsiLensCompletionCycle = $null
    }
}

function Initialize-MsiLensReplHistory {
    $script:MsiLensReplHistory = @()
    $script:MsiLensReplHistoryIndex = $null
    $script:MsiLensReplHistoryDraft = ''
}

function Add-MsiLensReplHistory {
    param([string] $Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return
    }

    if ($script:MsiLensReplHistory.Count -eq 0 -or $script:MsiLensReplHistory[-1] -ne $Line) {
        $script:MsiLensReplHistory = @($script:MsiLensReplHistory) + $Line
    }
    $script:MsiLensReplHistoryIndex = $null
    $script:MsiLensReplHistoryDraft = ''
}

function Set-MsiLensPsReadLineBuffer {
    param([string] $Text)

    $line = $null
    $cursorIndex = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursorIndex)
    [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition(0)
    if ($line.Length -gt 0) {
        [Microsoft.PowerShell.PSConsoleReadLine]::Delete(0, $line.Length)
    }
    [Microsoft.PowerShell.PSConsoleReadLine]::Insert($Text)
}

function Invoke-MsiLensPsReadLineHistory {
    param([string] $Direction)

    if ($null -eq $script:MsiLensReplHistory) {
        Initialize-MsiLensReplHistory
    }

    if ($script:MsiLensReplHistory.Count -eq 0) {
        [Microsoft.PowerShell.PSConsoleReadLine]::Ding()
        return
    }

    $line = $null
    $cursorIndex = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursorIndex)

    if ($Direction -eq 'Previous') {
        if ($null -eq $script:MsiLensReplHistoryIndex) {
            $script:MsiLensReplHistoryDraft = $line
            $script:MsiLensReplHistoryIndex = $script:MsiLensReplHistory.Count - 1
        } elseif ($script:MsiLensReplHistoryIndex -gt 0) {
            $script:MsiLensReplHistoryIndex--
        } else {
            [Microsoft.PowerShell.PSConsoleReadLine]::Ding()
            return
        }

        Set-MsiLensPsReadLineBuffer $script:MsiLensReplHistory[$script:MsiLensReplHistoryIndex]
        return
    }

    if ($null -eq $script:MsiLensReplHistoryIndex) {
        [Microsoft.PowerShell.PSConsoleReadLine]::Ding()
        return
    }

    if ($script:MsiLensReplHistoryIndex -lt ($script:MsiLensReplHistory.Count - 1)) {
        $script:MsiLensReplHistoryIndex++
        Set-MsiLensPsReadLineBuffer $script:MsiLensReplHistory[$script:MsiLensReplHistoryIndex]
        return
    }

    Set-MsiLensPsReadLineBuffer $script:MsiLensReplHistoryDraft
    $script:MsiLensReplHistoryIndex = $null
    $script:MsiLensReplHistoryDraft = ''
}

function Import-MsiLensPsReadLine {
    if ($null -eq (Get-Module PSReadLine)) {
        Import-Module PSReadLine -ErrorAction Stop
    }
    $null -ne ('Microsoft.PowerShell.PSConsoleReadLine' -as [type])
}

function Restore-MsiLensPsReadLineKeyHandler {
    param(
        [string] $Chord,
        [object] $PreviousHandler
    )

    if ($null -eq (Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue)) {
        return
    }

    if ($null -ne $PreviousHandler) {
        $scriptBlockProperty = $PreviousHandler.PSObject.Properties['ScriptBlock']
        $scriptBlock = $null
        if ($null -ne $scriptBlockProperty) {
            $scriptBlock = $scriptBlockProperty.Value
        }

        if ($null -ne $scriptBlock) {
            $parameters = @{
                Chord       = $Chord
                ScriptBlock = $scriptBlock
            }

            $briefDescriptionProperty = $PreviousHandler.PSObject.Properties['BriefDescription']
            if ($null -ne $briefDescriptionProperty -and -not [string]::IsNullOrWhiteSpace([string]$briefDescriptionProperty.Value)) {
                $parameters.BriefDescription = [string]$briefDescriptionProperty.Value
            }

            $descriptionProperty = $PreviousHandler.PSObject.Properties['Description']
            if ($null -ne $descriptionProperty -and -not [string]::IsNullOrWhiteSpace([string]$descriptionProperty.Value)) {
                $parameters.Description = [string]$descriptionProperty.Value
            }

            try {
                Set-PSReadLineKeyHandler @parameters -ErrorAction Stop
                return
            } catch {
                Write-Verbose ("Unable to restore PSReadLine scriptblock handler for {0}: {1}" -f $Chord, $_.Exception.Message)
            }
        }

        $functionProperty = $PreviousHandler.PSObject.Properties['Function']
        if ($null -ne $functionProperty -and -not [string]::IsNullOrWhiteSpace([string]$functionProperty.Value)) {
            try {
                Set-PSReadLineKeyHandler -Chord $Chord -Function ([string]$functionProperty.Value) -ErrorAction Stop
                return
            } catch {
                Write-Verbose ("Unable to restore PSReadLine function handler for {0}: {1}" -f $Chord, $_.Exception.Message)
            }
        }
    }

    if ($null -ne (Get-Command Remove-PSReadLineKeyHandler -ErrorAction SilentlyContinue)) {
        Remove-PSReadLineKeyHandler -Chord $Chord -ErrorAction SilentlyContinue
    }
}

function Set-MsiLensPsReadLineHistorySuppression {
    if ($null -eq (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue)) {
        return $null
    }

    $previousHandler = [Microsoft.PowerShell.PSConsoleReadLine]::GetOptions().AddToHistoryHandler
    Set-PSReadLineOption -AddToHistoryHandler { param($line) [Microsoft.PowerShell.AddToHistoryOption]::SkipAdding }
    $previousHandler
}

function Restore-MsiLensPsReadLineHistoryHandler {
    param([object] $PreviousHandler)

    if ($null -eq (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue)) {
        return
    }

    try {
        Set-PSReadLineOption -AddToHistoryHandler $PreviousHandler -ErrorAction Stop
    } catch {
        Write-Verbose ("Unable to restore PSReadLine history handler: {0}" -f $_.Exception.Message)
    }
}

function Read-MsiLensPsConsoleLine {
    param([object] $ExecutionContextValue)

    $readLineMethods = @([Microsoft.PowerShell.PSConsoleReadLine].GetMethods() | Where-Object { $_.Name -eq 'ReadLine' })
    $twoArgumentMethod = $readLineMethods | Where-Object { $_.GetParameters().Count -eq 2 } | Select-Object -First 1
    if ($null -ne $twoArgumentMethod) {
        return [Microsoft.PowerShell.PSConsoleReadLine]::ReadLine([runspace]::DefaultRunspace, $ExecutionContextValue)
    }

    $threeArgumentMethod = $readLineMethods | Where-Object {
        $parameters = $_.GetParameters()
        $parameters.Count -eq 3 -and $parameters[2].ParameterType.FullName -like 'System.Nullable*'
    } | Select-Object -First 1
    if ($null -ne $threeArgumentMethod) {
        return [Microsoft.PowerShell.PSConsoleReadLine]::ReadLine([runspace]::DefaultRunspace, $ExecutionContextValue, $null)
    }

    throw 'No compatible PSReadLine ReadLine overload was found.'
}

function Read-MsiLensInputLine {
    param(
        [string] $Prompt,
        [string] $CurrentPath
    )

    $Host.UI.Write($Prompt)

    # [Console]::ReadLine handles redirected stdin (REPL automation and tests).
    if ([Console]::IsInputRedirected) {
        return [Console]::ReadLine()
    }

    if (Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue) {
        try {
            if (Import-MsiLensPsReadLine) {
                $previousTabHandler = @(Get-PSReadLineKeyHandler -Bound -Unbound | Where-Object { $_.Key -eq 'Tab' } | Select-Object -First 1)[0]
                $previousShiftTabHandler = @(Get-PSReadLineKeyHandler -Bound -Unbound | Where-Object { $_.Key -eq 'Shift+Tab' } | Select-Object -First 1)[0]
                $previousUpHandler = @(Get-PSReadLineKeyHandler -Bound -Unbound | Where-Object { $_.Key -eq 'UpArrow' } | Select-Object -First 1)[0]
                $previousDownHandler = @(Get-PSReadLineKeyHandler -Bound -Unbound | Where-Object { $_.Key -eq 'DownArrow' } | Select-Object -First 1)[0]
                $previousHistoryHandler = Set-MsiLensPsReadLineHistorySuppression
                $script:MsiLensCompletionCurrentPath = $CurrentPath
                $script:MsiLensCompletionCycle = $null

                $completionCommand = ${function:Invoke-MsiLensPsReadLineCompletion}
                $historyCommand = ${function:Invoke-MsiLensPsReadLineHistory}
                $completionHandler = { param($key, $arg) & $completionCommand -Direction Next }.GetNewClosure()
                $previousCompletionHandler = { param($key, $arg) & $completionCommand -Direction Previous }.GetNewClosure()
                $previousHistoryKeyHandler = { param($key, $arg) & $historyCommand -Direction Previous }.GetNewClosure()
                $nextHistoryKeyHandler = { param($key, $arg) & $historyCommand -Direction Next }.GetNewClosure()

                Set-PSReadLineKeyHandler -Chord Tab -ScriptBlock $completionHandler -BriefDescription 'MsiLensComplete' -Description 'Complete MsiLens REPL input'
                Set-PSReadLineKeyHandler -Chord Shift+Tab -ScriptBlock $previousCompletionHandler -BriefDescription 'MsiLensPreviousCompletion' -Description 'Show the previous MsiLens REPL completion'
                Set-PSReadLineKeyHandler -Chord UpArrow -ScriptBlock $previousHistoryKeyHandler -BriefDescription 'MsiLensPreviousHistory' -Description 'Show the previous MsiLens REPL input'
                Set-PSReadLineKeyHandler -Chord DownArrow -ScriptBlock $nextHistoryKeyHandler -BriefDescription 'MsiLensNextHistory' -Description 'Show the next MsiLens REPL input'
                try {
                    return Read-MsiLensPsConsoleLine -ExecutionContextValue $ExecutionContext
                } finally {
                    try {
                        Restore-MsiLensPsReadLineKeyHandler -Chord Tab -PreviousHandler $previousTabHandler
                        Restore-MsiLensPsReadLineKeyHandler -Chord Shift+Tab -PreviousHandler $previousShiftTabHandler
                        Restore-MsiLensPsReadLineKeyHandler -Chord UpArrow -PreviousHandler $previousUpHandler
                        Restore-MsiLensPsReadLineKeyHandler -Chord DownArrow -PreviousHandler $previousDownHandler
                        Restore-MsiLensPsReadLineHistoryHandler -PreviousHandler $previousHistoryHandler
                    } finally {
                        $script:MsiLensCompletionCurrentPath = $null
                        $script:MsiLensCompletionCycle = $null
                    }
                }
            }
        } catch {
            Write-Verbose ("PSReadLine input is unavailable; using host input: {0}" -f $_.Exception.Message)
        }
    }

    return $Host.UI.ReadLine()
}

function Write-MsiLensReplOutput {
    param(
        [object[]] $Output,
        [string] $Continuation
    )

    if ([string]::IsNullOrWhiteSpace($Continuation)) {
        if ($null -eq $Output -or $Output.Count -eq 0) {
            return
        }
        $Output | Out-Default
        return
    }

    if ($null -eq $Output) {
        $Output = @()
    }

    try {
        if ($Continuation.TrimStart().StartsWith('|')) {
            $scriptText = 'param([object[]] $InputObject) $InputObject {0}' -f $Continuation
        } else {
            $scriptText = 'param([object[]] $InputObject) $InputObject | Out-Default {0}' -f $Continuation
        }
        $pipelineScript = [scriptblock]::Create($scriptText)
        & $pipelineScript $Output | Out-Default
    } catch {
        Write-MsiLensError -Code 'InvalidArgument' -Message ("PowerShell continuation failed: {0}" -f $_.Exception.Message) -Category InvalidArgument
    }
}

function Start-MsiLensRepl {
    param([string] $InitialPath)

    $currentPath = $null
    Initialize-MsiLensReplHistory

    if (-not [string]::IsNullOrWhiteSpace($InitialPath)) {
        if (-not (Test-Path -LiteralPath $InitialPath)) {
            Write-MsiLensError -Code 'FileNotFound' -Message ("MSI path '{0}' was not found." -f $InitialPath) -Category ObjectNotFound
            Set-MsiLensExitCode 3
            return
        }

        $connection = $null
        try {
            $connection = Open-MsiLensDatabase $InitialPath
            $currentPath = $connection.Path
        } catch {
            Write-MsiLensError -Code 'MsiOpenFailed' -Message ("Failed to open MSI read-only: {0}" -f $_.Exception.Message)
            Set-MsiLensExitCode 4
            return
        } finally {
            # The REPL re-opens the database per scoped command, so the validation
            # connection is released here once the resolved path is captured.
            Close-MsiLensDatabase $connection
        }
    }

    :repl while ($true) {
        if ([string]::IsNullOrWhiteSpace($currentPath)) {
            $prompt = 'MsiLens> '
        } else {
            $prompt = 'MsiLens {0}> ' -f ([System.IO.Path]::GetFileName($currentPath))
        }

        $line = Read-MsiLensInputLine -Prompt $prompt -CurrentPath $currentPath
        if ($null -eq $line) {
            Set-MsiLensExitCode 0
            return
        }
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        Add-MsiLensReplHistory $line

        try {
            $replInput = Split-MsiLensReplInput $line
            $tokens = @(Split-MsiLensCommandLine $replInput.CommandLine)
        } catch {
            Write-MsiLensError -Code 'InvalidArgument' -Message $_.Exception.Message -Category InvalidArgument
            continue
        }

        if ($tokens.Count -eq 0) {
            continue
        }

        $command = Resolve-MsiLensAlias $tokens[0]
        $commandArguments = @($tokens | Select-Object -Skip 1)

        switch ($command) {
            'exit' {
                Set-MsiLensExitCode 0
                return
            }
            'open' {
                if ($commandArguments.Count -ne 1) {
                    Write-MsiLensError -Code 'InvalidArgument' -Message 'open requires exactly one MSI path.' -Category InvalidArgument
                    continue repl
                }
                if (-not (Test-Path -LiteralPath $commandArguments[0])) {
                    Write-MsiLensError -Code 'FileNotFound' -Message ("MSI path '{0}' was not found." -f $commandArguments[0]) -Category ObjectNotFound
                    continue repl
                }
                $connection = $null
                try {
                    $connection = Open-MsiLensDatabase $commandArguments[0]
                    $currentPath = $connection.Path
                    $Host.UI.WriteLine("Opened {0}" -f $currentPath)
                } catch {
                    Write-MsiLensError -Code 'MsiOpenFailed' -Message ("Failed to open MSI read-only: {0}" -f $_.Exception.Message)
                } finally {
                    Close-MsiLensDatabase $connection
                }
                continue repl
            }
            'close' {
                if ($commandArguments.Count -ne 0) {
                    Write-MsiLensError -Code 'InvalidArgument' -Message 'close does not accept arguments.' -Category InvalidArgument
                    continue repl
                }
                $currentPath = $null
                $Host.UI.WriteLine('Closed')
                continue repl
            }
            'clear' {
                if ($commandArguments.Count -ne 0) {
                    Write-MsiLensError -Code 'InvalidArgument' -Message 'clear does not accept arguments.' -Category InvalidArgument
                    continue repl
                }
                try {
                    Clear-Host
                } catch {
                    Write-Verbose ("Clear-Host is not supported by this host: {0}" -f $_.Exception.Message)
                }
                continue repl
            }
        }

        if (Test-MsiLensGlobalCommand $command) {
            $script:MsiLensExitCode = 0
            $output = @(Invoke-MsiLensGlobalCommand -Command $command -CommandArguments $commandArguments)
            Write-MsiLensReplOutput -Output $output -Continuation $replInput.Continuation
            continue
        }

        if ((Get-MsiLensScopedCommands) -contains $command) {
            if ([string]::IsNullOrWhiteSpace($currentPath)) {
                Write-MsiLensError -Code 'NoOpenPackage' -Message ("Command '{0}' requires an open MSI. Use open <path> first." -f $command) -Category InvalidOperation
                continue
            }
            $script:MsiLensExitCode = 0
            $output = @(Invoke-MsiLensScopedCommand -MsiPath $currentPath -Command $command -CommandArguments $commandArguments)
            Write-MsiLensReplOutput -Output $output -Continuation $replInput.Continuation
            continue
        }

        Write-MsiLensError -Code 'UnknownCommand' -Message ("Unknown command '{0}'." -f $tokens[0]) -Category InvalidArgument
    }
}

function Invoke-MsiLensMain {
    param(
        [bool] $NamedPathPresent,
        [string] $NamedPath,
        [string[]] $InputArguments
    )

    if ($null -eq $InputArguments) {
        $InputArguments = @()
    }
    if ($script:MsiLensPassThroughOptions.Count -gt 0) {
        $InputArguments = @($InputArguments) + @($script:MsiLensPassThroughOptions)
    }

    # When arguments are splatted as an array (& $script @args) PowerShell binds
    # every element positionally, so a leading -Path lands here instead of the
    # $Path parameter. Direct shell invocation binds -Path via the param block.
    if (-not $NamedPathPresent -and $InputArguments.Count -gt 0 -and $InputArguments[0] -eq '-Path') {
        if ($InputArguments.Count -lt 2) {
            Write-MsiLensError -Code 'InvalidArgument' -Message '-Path requires a value.' -Category InvalidArgument
            Set-MsiLensExitCode 2
            return
        }
        $NamedPathPresent = $true
        $NamedPath = $InputArguments[1]
        $InputArguments = @($InputArguments | Select-Object -Skip 2)
    }

    if ($NamedPathPresent) {
        if ([string]::IsNullOrWhiteSpace($NamedPath)) {
            Write-MsiLensError -Code 'InvalidArgument' -Message '-Path requires a value.' -Category InvalidArgument
            Set-MsiLensExitCode 2
            return
        }
        if ($InputArguments.Count -eq 0) {
            if (-not (Test-Path -LiteralPath $NamedPath)) {
                Write-MsiLensError -Code 'FileNotFound' -Message ("MSI path '{0}' was not found." -f $NamedPath) -Category ObjectNotFound
                Set-MsiLensExitCode 3
                return
            }
            Start-MsiLensRepl -InitialPath $NamedPath
            return
        }
        Invoke-MsiLensScopedCommand -MsiPath $NamedPath -Command $InputArguments[0] -CommandArguments @($InputArguments | Select-Object -Skip 1)
        return
    }

    if ($InputArguments.Count -eq 0) {
        Start-MsiLensRepl
        return
    }

    $first = $InputArguments[0]
    if (Test-MsiLensGlobalCommand $first) {
        Invoke-MsiLensGlobalCommand -Command $first -CommandArguments @($InputArguments | Select-Object -Skip 1)
        return
    }

    if (Test-MsiLensPathLike $first) {
        if (-not (Test-Path -LiteralPath $first)) {
            Write-MsiLensError -Code 'FileNotFound' -Message ("MSI path '{0}' was not found." -f $first) -Category ObjectNotFound
            Set-MsiLensExitCode 3
            return
        }
        if ($InputArguments.Count -eq 1) {
            Start-MsiLensRepl -InitialPath $first
            return
        }
        Invoke-MsiLensScopedCommand -MsiPath $first -Command $InputArguments[1] -CommandArguments @($InputArguments | Select-Object -Skip 2)
        return
    }

    Write-MsiLensError -Code 'InvalidArgument' -Message ("Unknown command or non-path argument '{0}'." -f $first) -Category InvalidArgument
    Set-MsiLensExitCode 2
    return
}

if ($env:MSILENS_DOT_SOURCE_ONLY -ne '1') {
    $script:MsiLensExitCode = 0
    Invoke-MsiLensMain -NamedPathPresent $script:MsiLensPathWasNamed -NamedPath $Path -InputArguments $Arguments
    $global:LASTEXITCODE = $script:MsiLensExitCode
    if ($env:MSILENS_SUPPRESS_EXIT -ne '1') {
        exit $script:MsiLensExitCode
    }
}
