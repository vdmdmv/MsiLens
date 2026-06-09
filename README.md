# MsiLens

MsiLens is a portable, read-only PowerShell tool for inspecting Windows Installer
(`.msi`) packages. It can query package metadata, tables, properties, files,
Binary table streams, embedded cabinets, and package-level Authenticode
signatures without installing the package.

The tool supports both one-shot commands for automation and an interactive REPL
for exploration. Data commands emit structured PowerShell objects, so output can
be piped into `Where-Object`, `Format-Table`, `ConvertTo-Json`, `Export-Csv`, and
other standard PowerShell commands.

## Requirements

- Windows PowerShell 5.1 or later
- Windows Installer COM automation support, available on Windows
- An MSI package to inspect

## Quick Start

Show help:

```powershell
.\MsiLens.ps1 help
.\MsiLens.ps1 help table
```

Inspect a package:

```powershell
.\MsiLens.ps1 .\Product.msi info
.\MsiLens.ps1 .\Product.msi tables
.\MsiLens.ps1 .\Product.msi columns Property
.\MsiLens.ps1 .\Product.msi table File -First 10
.\MsiLens.ps1 .\Product.msi properties
.\MsiLens.ps1 .\Product.msi signature | ConvertTo-Json -Depth 5
```

You can also pass the MSI path with `-Path`:

```powershell
.\MsiLens.ps1 -Path .\Product.msi files
```

## Commands

Global commands:

- `help [command]` - show general or command-specific help.
- `version` - return version and runtime information.
- `examples` - show usage examples.

MSI inspection commands:

- `info` - return high-level package information.
- `tables` - list discovered MSI tables.
- `columns <table>` - return column metadata for a table.
- `table <table> [-First <n>]` - return rows from a table.
- `properties` - return all MSI properties.
- `property <name>` - return one MSI property by exact name.
- `files` - return File table metadata.
- `file <id-or-name>` - resolve one File table entry.
- `binaries` and `binary <name>` - inspect Binary table streams.
- `cabinets` and `cabinet <name>` - inspect embedded cabinet metadata.
- `streams` - list understood, safe artifact streams.
- `signature` - inspect the package-level Authenticode signature.

Extraction commands:

- `extract-file <id-or-name> -Out <directory> [-Layout Flat|InstalledTree] [-DryRun] [-Force]`
- `extract-files [-Filter <wildcard> | -All] -Out <directory> [-Layout Flat|InstalledTree] [-DryRun] [-Force]`
- `extract-binary <name> -Out <directory> [-DryRun] [-Force]`
- `extract-binaries [-Filter <wildcard> | -All] -Out <directory> [-DryRun] [-Force]`
- `extract-cabinet <name> -Out <directory> [-DryRun] [-Force]`
- `extract-cabinets [-Filter <wildcard> | -All] -Out <directory> [-DryRun] [-Force]`

Extraction writes payload bytes to a caller-selected output directory. Use
`-DryRun` to preview planned output and `-Force` to overwrite existing files.

## Interactive REPL

Run MsiLens with no command to start the shell:

```powershell
.\MsiLens.ps1
```

Or start with a package already open:

```powershell
.\MsiLens.ps1 .\Product.msi
```

Inside the REPL, use the same inspection commands without repeating the MSI
path:

```powershell
MsiLens Product.msi> info
MsiLens Product.msi> tables
MsiLens Product.msi> properties | Where-Object Property -like Product*
MsiLens Product.msi> signature | Format-List
```

REPL-only commands:

- `open <path>` - open or switch to an MSI package.
- `close` - close the current package context.
- `clear` - clear the console.
- `exit` or `quit` - leave the REPL.

Tab completion is available for commands, options, paths, table names, property
names, file names, Binary streams, and embedded cabinets.

## Safety Model

MsiLens opens MSI databases read-only. It does not invoke `msiexec`, install the
package, execute custom actions, or load package binaries. Signature inspection
is package-level Authenticode inspection only; it does not prove installer
behavior is safe.

## Testing

Run the test script directly:

```powershell
.\tests\MsiLens.Tests.ps1
```

If Pester is available, the test file runs as a Pester suite. If Pester is not
available, it falls back to the bundled smoke tests. The tests create temporary
MSI fixtures using Windows Installer automation.

You can also run the smoke tests explicitly:

```powershell
.\tests\Invoke-MsiLensSmokeTests.ps1
```

## License

This project is licensed under the Apache License 2.0. See `LICENSE` for the
full text.
