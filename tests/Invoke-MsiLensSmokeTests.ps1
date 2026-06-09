param(
    [string] $MsiLensPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'MsiLens.ps1')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Invoke-MsiLensForTest {
    param(
        [string[]] $Arguments
    )

    $previous = $env:MSILENS_SUPPRESS_EXIT
    $env:MSILENS_SUPPRESS_EXIT = '1'
    try {
        $output = & $MsiLensPath @Arguments 2>&1
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

function Assert-True {
    param(
        [bool] $Condition,
        [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-ExitCode {
    param(
        [object] $Result,
        [int] $Expected,
        [string] $Name
    )

    Assert-True ($Result.ExitCode -eq $Expected) ("{0}: expected exit code {1}, got {2}. Output: {3}" -f $Name, $Expected, $Result.ExitCode, ($Result.Output | Out-String))
}

function Assert-PSTypeName {
    param(
        [object] $Object,
        [string] $Expected,
        [string] $Name
    )

    Assert-True ($null -ne $Object) ("{0}: expected an object." -f $Name)
    Assert-True ($Object.PSObject.TypeNames[0] -eq $Expected) ("{0}: expected PSTypeName {1}, got {2}." -f $Name, $Expected, $Object.PSObject.TypeNames[0])
}

function Assert-NoProperty {
    param(
        [object] $Object,
        [string] $Property,
        [string] $Name
    )

    Assert-True ($null -eq $Object.PSObject.Properties[$Property]) ("{0}: expected no {1} property." -f $Name, $Property)
}

function Invoke-MsiLensReplForTest {
    param(
        [string[]] $Arguments,
        [string[]] $InputLines
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $allArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MsiLensPath) + $Arguments
    $escapedArguments = @()
    foreach ($argument in $allArguments) {
        $escapedArguments += ('"{0}"' -f ($argument -replace '"', '\"'))
    }
    $psi.Arguments = $escapedArguments -join ' '
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::Start($psi)
    foreach ($line in $InputLines) {
        $process.StandardInput.WriteLine($line)
    }
    $process.StandardInput.Close()

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit(30000) | Out-Null
    if (-not $process.HasExited) {
        $process.Kill()
        throw 'REPL process did not exit.'
    }

    [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

$fixture = $null
if ($env:MSILENS_TEST_UNSIGNED_MSI) {
    $fixture = [pscustomobject]@{
        Path   = $env:MSILENS_TEST_UNSIGNED_MSI
        FileId = 'TestFile'
    }
} else {
    $fixture = @(& (Join-Path $PSScriptRoot 'New-MsiLensTestFixture.ps1'))[-1]
}

$msi = $fixture.Path

$result = Invoke-MsiLensForTest @('help')
Assert-ExitCode $result 0 'help'
Assert-True (($result.Output | Out-String) -match 'MsiLens') 'help should write human-readable help.'

$result = Invoke-MsiLensForTest @('help', 'info')
Assert-ExitCode $result 0 'help info'
Assert-True (($result.Output | Out-String) -match 'PackageInfo') 'help info should describe the output object.'
Assert-True (($result.Output | Out-String) -notmatch 'MVP command') 'help info should not use placeholder text.'

$result = Invoke-MsiLensForTest @('version')
Assert-ExitCode $result 0 'version'
Assert-PSTypeName $result.Output[0] 'MsiLens.Version' 'version'

$result = Invoke-MsiLensForTest @('examples')
Assert-ExitCode $result 0 'examples'
Assert-True (($result.Output | Out-String) -match 'tables') 'examples should include MVP examples.'

$result = Invoke-MsiLensForTest @('bogus')
Assert-ExitCode $result 2 'unknown command'

$result = Invoke-MsiLensForTest @('-Path', $msi, 'tables')
Assert-ExitCode $result 0 '-Path tables'
Assert-PSTypeName $result.Output[0] 'MsiLens.TableInfo' '-Path tables'

$missing = Join-Path ([System.IO.Path]::GetTempPath()) ("missing-{0}.msi" -f ([guid]::NewGuid().ToString('N')))
$result = Invoke-MsiLensForTest @($missing, 'tables')
Assert-ExitCode $result 3 'missing MSI'

$result = Invoke-MsiLensForTest @($missing, 'bogus')
Assert-ExitCode $result 3 'missing MSI with bogus command'

$result = Invoke-MsiLensForTest @('-Path', $missing, 'bogus')
Assert-ExitCode $result 3 'missing named MSI with bogus command'

$result = Invoke-MsiLensForTest @($msi, 'table', 'Property', '-NoSuchOption')
Assert-ExitCode $result 2 'unsupported option'

$result = Invoke-MsiLensForTest @($msi, 'properties', 'extra')
Assert-ExitCode $result 2 'extra positional'

$missingInvalid = Join-Path ([System.IO.Path]::GetTempPath()) ("missing-{0}.msi" -f ([guid]::NewGuid().ToString('N')))
$result = Invoke-MsiLensForTest @($missingInvalid, 'properties', 'extra')
Assert-ExitCode $result 3 'missing MSI before extra positional validation'

$result = Invoke-MsiLensForTest @($msi, 'info')
Assert-ExitCode $result 0 'info'
Assert-PSTypeName $result.Output[0] 'MsiLens.PackageInfo' 'info'
Assert-NoProperty $result.Output[0] 'MsiPath' 'info'
Assert-True ($result.Output[0].ProductName -eq 'MsiLens Test Product') 'info should read ProductName.'

$result = Invoke-MsiLensForTest @($msi, 'tables')
Assert-ExitCode $result 0 'tables'
Assert-NoProperty $result.Output[0] 'MsiPath' 'tables'
$tableNames = @($result.Output | ForEach-Object { $_.Table })
Assert-True (($tableNames -join "`n") -eq ((@($tableNames | Sort-Object)) -join "`n")) 'tables should be sorted by table name.'
Assert-True (@($result.Output | Where-Object { $_.Table -eq 'Property' }).Count -eq 1) 'tables should include Property.'

$result = Invoke-MsiLensForTest @($msi, 'columns', 'Property')
Assert-ExitCode $result 0 'columns Property'
Assert-PSTypeName $result.Output[0] 'MsiLens.ColumnInfo' 'columns Property'
Assert-NoProperty $result.Output[0] 'MsiPath' 'columns Property'

$result = Invoke-MsiLensForTest @($msi, 'properties')
Assert-ExitCode $result 0 'properties'
Assert-PSTypeName $result.Output[0] 'MsiLens.Property' 'properties'
Assert-NoProperty $result.Output[0] 'MsiPath' 'properties'
$propertyNames = @($result.Output | ForEach-Object { $_.Property })
Assert-True (($propertyNames -join "`n") -eq ((@($propertyNames | Sort-Object)) -join "`n")) 'properties should be sorted by property name.'

$result = Invoke-MsiLensForTest @($msi, 'property', 'ProductName')
Assert-ExitCode $result 0 'property ProductName'
Assert-True ($result.Output[0].Value -eq 'MsiLens Test Product') 'property should return known value.'

$result = Invoke-MsiLensForTest @($msi, 'table', 'Property', '-First', '1')
Assert-ExitCode $result 0 'table Property -First 1'
Assert-PSTypeName $result.Output[0] 'MsiLens.TableRow' 'table Property'
Assert-NoProperty $result.Output[0] 'MsiPath' 'table Property'
Assert-NoProperty $result.Output[0] 'Data' 'table Property'
Assert-True ($result.Output[0].Value -eq 'MsiLens Test Product') 'table Property should expose MSI Value as Value.'
Assert-True (@($result.Output).Count -eq 1) 'table -First should limit rows.'

$result = Invoke-MsiLensForTest @($msi, 'files')
Assert-ExitCode $result 0 'files'
Assert-PSTypeName $result.Output[0] 'MsiLens.FileInfo' 'files'
Assert-NoProperty $result.Output[0] 'MsiPath' 'files'
Assert-True ($result.Output[0].FileName -eq 'TestFile.txt') 'files should normalize long filename.'
$shortOnly = $result.Output | Where-Object { $_.File -eq 'ShortOnly' }
Assert-True ($shortOnly.FileName -eq 'SHORTO~1.DLL') 'short-only file should use raw name as canonical FileName.'
Assert-True ($shortOnly.ShortFileName -eq 'SHORTO~1.DLL') 'short-only file should expose ShortFileName.'
Assert-True ($null -eq $shortOnly.LongFileName) 'short-only file should not expose LongFileName.'

$result = Invoke-MsiLensForTest @($msi, 'table', 'File', '-First', '1')
Assert-ExitCode $result 0 'table File -First 1'
Assert-PSTypeName $result.Output[0] 'MsiLens.TableRow' 'table File'
Assert-NoProperty $result.Output[0] 'Data' 'table File'

$result = Invoke-MsiLensForTest @($msi, 'file', $fixture.FileId)
Assert-ExitCode $result 0 'file by id'
Assert-PSTypeName $result.Output[0] 'MsiLens.FileInfo' 'file by id'
Assert-NoProperty $result.Output[0] 'MsiPath' 'file by id'

$result = Invoke-MsiLensForTest @($msi, 'table', 'Binary')
Assert-ExitCode $result 0 'table Binary'
Assert-True (($result.Output[0].MsiColumn_Data -eq '<binary>') -or ($result.Output[0].Data['Data'] -eq '<binary>')) 'Binary.Data should not expose raw payload bytes.'

$result = Invoke-MsiLensForTest @($msi, 'binaries')
Assert-ExitCode $result 0 'binaries'
Assert-PSTypeName $result.Output[0] 'MsiLens.BinaryInfo' 'binaries'
Assert-True ($result.Output[0].Name -eq 'TinyBinary') 'binaries should list TinyBinary.'
Assert-True ($null -eq $result.Output[0].PSObject.Properties['Data']) 'binaries should not expose raw stream bytes.'
Assert-True ($result.Output[0].Size -eq 5) 'binaries Size should come from DataSize metadata (5 bytes), not a byte read.'

$result = Invoke-MsiLensForTest @($msi, 'cabinets')
Assert-ExitCode $result 0 'cabinets'
Assert-PSTypeName $result.Output[0] 'MsiLens.CabinetInfo' 'cabinets'
Assert-True ($result.Output[0].StreamName -eq 'embedded.cab') 'cabinets should list embedded cabinet stream names.'

$result = Invoke-MsiLensForTest @($msi, 'streams')
Assert-ExitCode $result 0 'streams'
Assert-PSTypeName $result.Output[0] 'MsiLens.StreamInfo' 'streams'
Assert-True (@($result.Output | Where-Object { $_.Scope -eq 'BinaryTable' }).Count -eq 1) 'streams should include Binary table streams.'
Assert-True (@($result.Output | Where-Object { $_.Scope -eq 'EmbeddedCabinet' }).Count -eq 1) 'streams should include embedded cabinet streams.'

$artifactOut = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensArtifactSmoke-{0}" -f ([guid]::NewGuid().ToString('N')))
try {
    $result = Invoke-MsiLensForTest @($msi, 'extract-binary', 'TinyBinary', '-Out', $artifactOut)
    Assert-ExitCode $result 0 'extract-binary'
    Assert-PSTypeName $result.Output[0] 'MsiLens.ArtifactExtractionResult' 'extract-binary'
    Assert-True (($result.Output[0].Status -eq 'Extracted') -and (Test-Path -LiteralPath (Join-Path $artifactOut 'TinyBinary'))) 'extract-binary should write the stream bytes.'
    Assert-True (($result.Output[0].BytesWritten -eq 5) -and ($result.Output[0].Verified -eq $true)) 'extract-binary should verify DataSize against bytes written.'

    $result = Invoke-MsiLensForTest @($msi, 'extract-cabinet', 'embedded.cab', '-Out', $artifactOut)
    Assert-ExitCode $result 0 'extract-cabinet'
    Assert-True (($result.Output[0].Status -eq 'Extracted') -and (Test-Path -LiteralPath (Join-Path $artifactOut 'embedded.cab'))) 'extract-cabinet should export raw cabinet bytes.'
    Assert-True ($result.Output[0].Verified -eq $true) 'extract-cabinet should verify the _Streams DataSize against bytes written.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $artifactOut 'EmbeddedPayload.exe'))) 'extract-cabinet should not expand cabinet contents.'
} finally {
    Remove-Item -LiteralPath $artifactOut -Recurse -Force -ErrorAction SilentlyContinue
}

$result = Invoke-MsiLensForTest @($msi, 'signature')
Assert-ExitCode $result 0 'signature unsigned'
Assert-PSTypeName $result.Output[0] 'MsiLens.Signature' 'signature'
Assert-NoProperty $result.Output[0] 'MsiPath' 'signature'
Assert-True ($result.Output[0].Scope -eq 'PackageAuthenticode') 'signature scope should be package Authenticode.'
Assert-True ($result.Output[0].TrustScope -eq 'PackageSignature') 'signature trust scope should be package signature.'
Assert-True ($result.Output[0].Status -eq 'NotSigned') "unsigned fixture should report NotSigned, got $($result.Output[0].Status)."
Assert-True ($result.Output[0].IsSigned -eq $false) 'unsigned fixture should set IsSigned false.'
Assert-True ($result.Output[0].IsValid -eq $false) 'unsigned fixture should set IsValid false.'
Assert-True (@($result.Output).Count -eq 1) 'signature should emit exactly one success object.'

$invalidMsi = Join-Path ([System.IO.Path]::GetTempPath()) ("MsiLensInvalidDatabase-{0}.msi" -f ([guid]::NewGuid().ToString('N')))
try {
    Set-Content -LiteralPath $invalidMsi -Value 'not an msi database' -NoNewline -Encoding ASCII
    $result = Invoke-MsiLensForTest @($invalidMsi, 'signature')
    Assert-ExitCode $result 0 'signature invalid MSI database'
    Assert-PSTypeName $result.Output[0] 'MsiLens.Signature' 'signature invalid MSI database'
    Assert-True ($result.Output[0].Scope -eq 'PackageAuthenticode') 'signature invalid MSI database should inspect package Authenticode.'
} finally {
    Remove-Item -LiteralPath $invalidMsi -Force -ErrorAction SilentlyContinue
}

$result = Invoke-MsiLensForTest @($msi, 'info')
Assert-ExitCode $result 0 'info signature status'
Assert-True ($result.Output[0].SignatureStatus -eq 'NotSigned') 'info should use signature helper status.'
Assert-True ($result.Output[0].IsSigned -eq $false) 'info should use signature helper IsSigned.'

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($MsiLensPath, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'MsiLens.ps1 should parse cleanly.'
$argumentsParameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Arguments' }
$completionAttributes = @($argumentsParameter.Attributes |
    Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] } |
    ForEach-Object { $_.TypeName.GetReflectionAttributeType().Name })
Assert-True ($completionAttributes -contains 'ArgumentCompleterAttribute') 'one-shot Arguments parameter should expose command completion metadata.'

$escapedMsiLensPath = $MsiLensPath -replace "'", "''"
$completionLine = "& '$escapedMsiLensPath' help t"
$completion = [System.Management.Automation.CommandCompletion]::CompleteInput($completionLine, $completionLine.Length, $null)
Assert-True (@($completion.CompletionMatches | ForEach-Object { $_.ListItemText }) -contains 'table') 'one-shot help completion should include command names for typed prefixes.'
$completionLine = "& '$escapedMsiLensPath' help "
$completion = [System.Management.Automation.CommandCompletion]::CompleteInput($completionLine, $completionLine.Length, $null)
Assert-True (@($completion.CompletionMatches | ForEach-Object { $_.ListItemText }) -contains 'signature') 'one-shot help completion should include command names after a trailing space.'
Assert-True (@($completion.CompletionMatches | ForEach-Object { $_.ListItemText }) -notcontains 'MsiLens.ps1') 'one-shot help completion should not fall back to filesystem paths.'
$actualOneShotHelpCommands = @($completion.CompletionMatches | ForEach-Object { $_.ListItemText } | Sort-Object)

$previousDotSource = $env:MSILENS_DOT_SOURCE_ONLY
$env:MSILENS_DOT_SOURCE_ONLY = '1'
try {
    . $MsiLensPath
} finally {
    if ($null -eq $previousDotSource) {
        Remove-Item Env:\MSILENS_DOT_SOURCE_ONLY -ErrorAction SilentlyContinue
    } else {
        $env:MSILENS_DOT_SOURCE_ONLY = $previousDotSource
    }
}

$expectedHelpCommands = @((Get-MsiLensGlobalCommands) + (Get-MsiLensScopedCommands) | Sort-Object)
Assert-True (($actualOneShotHelpCommands -join '|') -eq ($expectedHelpCommands -join '|')) 'one-shot help completion should include every supported help command.'

$completion = @(Complete-MsiLensReplInput -Line 'table P' -CursorIndex 7 -CurrentPath $msi)
Assert-True (@($completion | ForEach-Object { $_.ListItemText }) -contains 'Property') 'REPL completion should include table names from the open MSI.'

$completion = @(Complete-MsiLensReplInput -Line 'help t' -CursorIndex 6)
Assert-True (@($completion | ForEach-Object { $_.ListItemText }) -contains 'table') 'REPL help completion should include command names for typed prefixes.'
$completion = @(Complete-MsiLensReplInput -Line 'help ' -CursorIndex 5)
Assert-True (@($completion | ForEach-Object { $_.ListItemText }) -contains 'signature') 'REPL help completion should include command names after a trailing space.'
Assert-True (@($completion | ForEach-Object { $_.ListItemText }) -notcontains 'MsiLens.ps1') 'REPL help completion should not fall back to filesystem paths.'
$actualHelpCommands = @($completion | ForEach-Object { $_.ListItemText } | Sort-Object)
Assert-True (($actualHelpCommands -join '|') -eq ($expectedHelpCommands -join '|')) 'REPL help completion should include every supported help command.'

$completion = @(Complete-MsiLensReplInput -Line 'property Product' -CursorIndex 16 -CurrentPath $msi)
Assert-True (@($completion | ForEach-Object { $_.ListItemText }) -contains 'ProductName') 'REPL completion should include property names from the open MSI.'

$completion = @(Complete-MsiLensReplInput -Line 'table Property -' -CursorIndex 16 -CurrentPath $msi)
Assert-True (@($completion | ForEach-Object { $_.ListItemText }) -contains '-First') 'REPL completion should include table command options.'

$completion = @(Complete-MsiLensReplInput -Line 'file Test' -CursorIndex 9 -CurrentPath $msi)
Assert-True (@($completion | ForEach-Object { $_.ListItemText }) -contains 'TestFile') 'REPL completion should include File table identifiers.'
Assert-True (@($completion | ForEach-Object { $_.ListItemText }) -contains 'TestFile.txt') 'REPL completion should include File table names.'

Initialize-MsiLensReplHistory
Add-MsiLensReplHistory 'info'
Add-MsiLensReplHistory 'tables'
Add-MsiLensReplHistory 'tables'
Assert-True (($script:MsiLensReplHistory -join '|') -eq 'info|tables') 'REPL should maintain separate in-memory history without adjacent duplicates.'

if (Get-Module PSReadLine -ListAvailable) {
    Assert-True (Import-MsiLensPsReadLine) 'PSReadLine should import when available.'
    $originalHistoryHandler = [Microsoft.PowerShell.PSConsoleReadLine]::GetOptions().AddToHistoryHandler
    $previousHistoryHandler = Set-MsiLensPsReadLineHistorySuppression
    try {
        $currentHistoryHandler = [Microsoft.PowerShell.PSConsoleReadLine]::GetOptions().AddToHistoryHandler
        Assert-True (($currentHistoryHandler.Invoke('info')) -eq [Microsoft.PowerShell.AddToHistoryOption]::SkipAdding) 'REPL PSReadLine input should suppress parent-session history.'
    } finally {
        Restore-MsiLensPsReadLineHistoryHandler -PreviousHandler $previousHistoryHandler
    }
    $restoredHistoryHandler = [Microsoft.PowerShell.PSConsoleReadLine]::GetOptions().AddToHistoryHandler
    Assert-True (($null -eq $restoredHistoryHandler -and $null -eq $originalHistoryHandler) -or [object]::ReferenceEquals($restoredHistoryHandler, $originalHistoryHandler)) 'REPL history suppression should restore the previous PSReadLine handler.'
}

if ($env:MSILENS_TEST_SIGNED_MSI) {
    $result = Invoke-MsiLensForTest @($env:MSILENS_TEST_SIGNED_MSI, 'signature')
    Assert-ExitCode $result 0 'signature signed fixture'
    Assert-PSTypeName $result.Output[0] 'MsiLens.Signature' 'signature signed fixture'
    Assert-True ($null -ne $result.Output[0].Status) 'signed fixture should report a status.'
}

if ($env:MSILENS_TEST_TAMPERED_SIGNED_MSI) {
    $result = Invoke-MsiLensForTest @($env:MSILENS_TEST_TAMPERED_SIGNED_MSI, 'signature')
    Assert-ExitCode $result 0 'signature tampered signed fixture'
    Assert-PSTypeName $result.Output[0] 'MsiLens.Signature' 'signature tampered signed fixture'
    Assert-True ($result.Output[0].IsValid -eq $false) 'tampered signed fixture should not be valid.'
}

$repl = Invoke-MsiLensReplForTest @() @('help', 'exit')
Assert-True ($repl.ExitCode -eq 0) "empty REPL should exit 0. StdErr: $($repl.StdErr)"
Assert-True ($repl.StdOut -match 'MsiLens>') 'empty REPL should show empty prompt.'
Assert-True ($repl.StdOut -match 'Commands:') 'REPL help should use shared help output.'
Assert-True ($repl.StdErr -notmatch 'REPL input must start with a MsiLens command') 'REPL exit should not be rejected by the parser.'

$repl = Invoke-MsiLensReplForTest @() @('exit', 'help')
Assert-True ($repl.ExitCode -eq 0) "REPL exit should exit 0. StdErr: $($repl.StdErr)"
Assert-True ($repl.StdOut -notmatch 'Commands:') 'REPL exit should stop before later input.'
Assert-True ($repl.StdErr -notmatch 'InvalidArgument') 'REPL exit should not write an argument error.'

$repl = Invoke-MsiLensReplForTest @() @('quit', 'help')
Assert-True ($repl.ExitCode -eq 0) "REPL quit should exit 0. StdErr: $($repl.StdErr)"
Assert-True ($repl.StdOut -notmatch 'Commands:') 'REPL quit should stop before later input.'

$repl = Invoke-MsiLensReplForTest @($msi) @('tables', 'exit')
Assert-True ($repl.ExitCode -eq 0) "path startup REPL should exit 0. StdErr: $($repl.StdErr)"
Assert-True ($repl.StdOut -match 'MsiLens .*\.msi>') 'path startup REPL should show file prompt.'
Assert-True ($repl.StdOut -match 'Property') 'path startup REPL should dispatch tables.'

$repl = Invoke-MsiLensReplForTest @($msi) @('info', 'exit')
Assert-True ($repl.ExitCode -eq 0) "REPL info should exit 0. StdErr: $($repl.StdErr)"
Assert-True ($repl.StdOut -match 'ProductVersion\s+:') 'REPL should use default PowerShell formatting for single objects.'
Assert-True ($repl.StdOut -notmatch 'ProductVersion\s+Manufacturer') 'REPL should not force table formatting for single objects.'

$repl = Invoke-MsiLensReplForTest @($msi) @('info | Select-Object -ExpandProperty ProductName', 'exit')
Assert-True ($repl.ExitCode -eq 0) "REPL pipeline should exit 0. StdErr: $($repl.StdErr)"
Assert-True ($repl.StdOut -match 'MsiLens Test Product') 'REPL should pipe command output into trailing PowerShell commands.'
Assert-True ($repl.StdErr -notmatch 'does not accept extra arguments') 'REPL pipeline should not be parsed as command arguments.'

$repl = Invoke-MsiLensReplForTest @($msi) @('info; Write-Output continuation-ok', 'exit')
Assert-True ($repl.ExitCode -eq 0) "REPL continuation should exit 0. StdErr: $($repl.StdErr)"
Assert-True ($repl.StdOut -match 'ProductVersion\s+:') 'REPL should render command output before statement continuations.'
Assert-True ($repl.StdOut -match 'continuation-ok') 'REPL should run trailing PowerShell statement continuations.'
Assert-True ($repl.StdErr -notmatch 'does not accept extra arguments') 'REPL continuation should not be parsed as command arguments.'

$spaceFixturePath = Join-Path ([System.IO.Path]::GetTempPath()) 'MsiLens Fixture With Spaces.msi'
$spaceFixture = @(& (Join-Path $PSScriptRoot 'New-MsiLensTestFixture.ps1') -Path $spaceFixturePath)[-1]
$repl = Invoke-MsiLensReplForTest @() @(("open ""{0}""" -f $spaceFixture.Path), 'property ProductName', 'close', 'info', 'exit')
Assert-True ($repl.ExitCode -eq 0) "quoted open REPL should exit 0. StdErr: $($repl.StdErr)"
Assert-True ($repl.StdOut -match 'Opened') 'REPL open should write a concise status.'
Assert-True ($repl.StdOut -match 'MsiLens Test Product') 'REPL should dispatch scoped commands after open.'
Assert-True ($repl.StdOut -match 'Closed') 'REPL close should write a concise status.'
Assert-True ($repl.StdErr -match 'NoOpenPackage') 'REPL scoped command without open MSI should write an error.'

Write-Output "MsiLens smoke tests passed."
