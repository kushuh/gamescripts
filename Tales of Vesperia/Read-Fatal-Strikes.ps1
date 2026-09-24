#requires -Version 5.1

<#
.SYNOPSIS
    Display saved Tales of Vesperia: Definitive Edition progress.
.DESCRIPTION
    Read-only Windows checker. Finds Steam in the Windows registry and standard
    installation folders, checks every numeric Steam userdata account, and reads
    the newest local save for Steam app 738540. Each delivered script is standalone.
    Requires Windows PowerShell 5.1 or newer; no administrator rights or downloads.
.PARAMETER SaveDirectory
    Optional 738540\remote folder. Limits selection to that folder's newest save.
.PARAMETER SaveFile
    Optional exact save file for an older checkpoint or another playthrough.
    Cannot be combined with SaveDirectory.
.PARAMETER AsJson
    Return structured progress instead of the human-readable terminal table.
.PARAMETER ShowSavePath
    Include the full local save path in the table header or JSON SaveFile field.
    By default, only the filename is shown, keeping account and user folder names
    out of output. This option also enables detailed file-access error messages.
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Read-Fatal-Strikes.ps1
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Read-Fatal-Strikes.ps1 -SaveDirectory "D:\Steam\userdata\ACCOUNT_ID\738540\remote" -ShowSavePath
.NOTES
    Save in game first: unsaved progress is not present on disk. The process-local
    execution-policy option in the launcher does not change Windows policy.
    Exit code 0 means success; 1 means the save could not be found or decoded.
    Saves are opened for reading with sharing enabled. Two bounded reads, hashes,
    and timestamps guard against concurrent writes; no save content is executed.
    The 16 MiB input limit comfortably exceeds the supported PC save size.
#>
[CmdletBinding()]
param(
    [string]$SaveDirectory,
    [string]$SaveFile,
    [switch]$AsJson,
    [switch]$ShowSavePath
)

$ErrorActionPreference = 'Stop'

function Stop-ProgressCheck {
    param([string]$Message)
    # Mark safe, fixed messages separately from system errors, which may contain
    # personal paths. The outer handler prints full system details only on request.
    $exception = [IO.InvalidDataException]::new($Message)
    $exception.Data['ProgressCheckerMessage'] = $Message
    throw $exception
}

function Write-ProgressError {
    param([string]$Context, [Management.Automation.ErrorRecord]$Record)
    $message = 'The save could not be read. Check the selected file and folder, wait for saving to finish, and try again.'
    $exception = $Record.Exception
    while ($null -ne $exception) {
        if ($exception.Data.Contains('ProgressCheckerMessage')) {
            $message = [string]$exception.Data['ProgressCheckerMessage']
            break
        }
        $exception = $exception.InnerException
    }
    if ($ShowSavePath -and $null -eq $exception) { $message = $Record.Exception.Message }
    Write-Host ($Context + ': ' + $message) -ForegroundColor Red
}

function Get-SteamRoots {
    # Read registry/environment values only. Bad or stale installation entries
    # must not prevent another valid Steam installation from being discovered.
    $roots = @()
    foreach ($key in @('HKCU:\Software\Valve\Steam',
                       'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
                       'HKLM:\SOFTWARE\Valve\Steam')) {
        try { $settings = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue }
        catch { continue }
        if ($null -eq $settings) { continue }
        foreach ($property in @('SteamPath', 'InstallPath')) {
            if ($settings.$property) { $roots += [string]$settings.$property }
        }
        if ($settings.SteamExe) {
            try {
                $exe = [Environment]::ExpandEnvironmentVariables(([string]$settings.SteamExe).Trim().Trim('"')).Replace('/', '\')
                $roots += [IO.Path]::GetDirectoryName($exe)
            } catch { <# Ignore malformed registry values. #> }
        }
    }
    foreach ($variable in @('ProgramFiles(x86)', 'ProgramFiles', 'ProgramW6432', 'LOCALAPPDATA')) {
        $folder = [Environment]::GetEnvironmentVariable($variable)
        if ($folder) { $roots += $folder.Trim().Trim('"').TrimEnd('\', '/') + '\Steam' }
    }
    foreach ($candidate in $roots) {
        if (-not $candidate) { continue }
        try {
            $path = [Environment]::ExpandEnvironmentVariables($candidate.Trim().Trim('"')).Replace('/', '\')
            # Automatic discovery is restricted to absolute local drive paths;
            # it never resolves relative paths or probes network shares from the registry.
            if ($path -notmatch '^[A-Za-z]:\\') { continue }
            [IO.Path]::GetFullPath($path)
        } catch { <# Continue with other registry values and fallback folders. #> }
    }
}

function Get-SaveDirectories {
    if ($SaveDirectory) {
        if (-not (Test-Path -LiteralPath $SaveDirectory -PathType Container)) {
            Stop-ProgressCheck 'Save folder not found.'
        }
        $folder = Get-Item -LiteralPath $SaveDirectory
        if ($folder -isnot [IO.DirectoryInfo]) { Stop-ProgressCheck 'Select a filesystem save folder.' }
        return $folder.FullName
    }
    # Saves live under the Steam client, even if the game uses another library.
    # Search numeric account folders, without assuming one particular account.
    $directories = foreach ($root in (Get-SteamRoots | Sort-Object -Unique)) {
        $userdata = [IO.Path]::Combine($root, 'userdata')
        if (-not (Test-Path -LiteralPath $userdata -PathType Container -ErrorAction SilentlyContinue)) { continue }
        foreach ($account in Get-ChildItem -LiteralPath $userdata -Directory -ErrorAction SilentlyContinue) {
            if ($account.Name -notmatch '^\d+$') { continue }
            $remote = [IO.Path]::Combine($account.FullName, '738540\remote')
            if (Test-Path -LiteralPath $remote -PathType Container -ErrorAction SilentlyContinue) { $remote }
        }
    }
    $directories | Sort-Object -Unique
}

function Get-LatestSave {
    # Never combine progress from different files or accounts. Report a damaged
    # newest save instead of silently substituting an older checkpoint.
    if ($SaveFile) {
        if ($SaveDirectory) { Stop-ProgressCheck 'Use either -SaveFile or -SaveDirectory, not both.' }
        if (-not (Test-Path -LiteralPath $SaveFile -PathType Leaf)) {
            Stop-ProgressCheck 'Save file not found.'
        }
        $file = Get-Item -LiteralPath $SaveFile
        if ($file -isnot [IO.FileInfo]) { Stop-ProgressCheck 'Select a filesystem save file.' }
        return $file
    }
    $files = @(foreach ($directory in Get-SaveDirectories) {
        Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^TLSaveData\d+_\d+$' }
    })
    if ($files.Count -eq 0) {
        Stop-ProgressCheck 'No Steam Vesperia saves found. Save in game first, or run this .ps1 with -SaveDirectory pointing to your 738540\remote folder.'
    }
    return $files | Sort-Object LastWriteTimeUtc, FullName -Descending | Select-Object -First 1
}

function Read-UInt32 {
    param([byte[]]$Data, [long]$Offset)
    if ($Offset -lt 0 -or $Offset + 4 -gt $Data.LongLength) {
        Stop-ProgressCheck 'The save is incomplete or has an unsupported format.'
    }
    return [BitConverter]::ToUInt32($Data, [int]$Offset)
}

function Read-BoundedSave {
    param([string]$Path)
    # Bound allocation even for a wrongly selected or damaged file. Open read-only
    # and permit the game to write or replace its file while this checker runs.
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $length = $stream.Length
        if ($length -gt 16MB) { Stop-ProgressCheck 'The selected file is too large to be a supported Vesperia save.' }
        $data = New-Object byte[] ([int]$length)
        $read = 0
        while ($read -lt $length) {
            $count = $stream.Read($data, $read, [int]($length - $read))
            if ($count -eq 0) { Stop-ProgressCheck 'The game is currently saving. Try again after saving finishes.' }
            $read += $count
        }
        if ($stream.Length -ne $length -or $stream.ReadByte() -ne -1) {
            Stop-ProgressCheck 'The game is currently saving. Try again after saving finishes.'
        }
        # Prevent PowerShell from enumerating every byte through the pipeline.
        return ,$data
    } finally { $stream.Dispose() }
}

function Get-BytesHash {
    param([byte[]]$Data)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hasher.ComputeHash($Data)).Replace('-', '') }
    finally { $hasher.Dispose() }
}

function Get-SaveSnapshot {
    # Retry concurrent or temporarily locked saves, comparing two bounded reads.
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $file = Get-LatestSave
            $stamp = $file.LastWriteTimeUtc
            $length = $file.Length
            $data = Read-BoundedSave $file.FullName
            $hash = Get-BytesHash $data
            $afterHash = Get-BytesHash (Read-BoundedSave $file.FullName)
            $after = Get-Item -LiteralPath $file.FullName
            $latest = Get-LatestSave
            if ($data.LongLength -ne $length -or $after.LastWriteTimeUtc -ne $stamp -or
                $after.Length -ne $length -or $hash -ne $afterHash -or
                $latest.FullName -ne $file.FullName) {
                Stop-ProgressCheck 'The game is currently saving. Try again after saving finishes.'
            }
            return [pscustomobject]@{ File = $file; Data = $data; Hash = $hash }
        } catch {
            if ($attempt -eq 2) { throw }
            Start-Sleep -Milliseconds 150
        }
    }
}

function Get-SaveSections {
    param([byte[]]$Data)
    # PC saves wrap TO8SAVE in 0x228 bytes. Read section positions from the
    # directory, checking every range before any checker accesses its contents.
    $base = 0x228
    if ($Data.Length -lt $base + 0x30 -or
        [Text.Encoding]::ASCII.GetString($Data, $base, 7) -ne 'TO8SAVE') {
        Stop-ProgressCheck 'This is not a supported Steam Definitive Edition save.'
    }
    $meta = [long](Read-UInt32 $Data ($base + 0x20))
    $count = Read-UInt32 $Data ($base + 0x24)
    $content = [long](Read-UInt32 $Data ($base + 0x28))
    $strings = [long](Read-UInt32 $Data ($base + 0x2c))
    if ($count -lt 1 -or $count -gt 256 -or $meta -lt 0x30 -or
        $meta + [long]$count * 32 -gt $content -or $content -gt $strings -or
        $base + $strings -ge $Data.LongLength) {
        Stop-ProgressCheck 'Unsupported save section directory.'
    }
    $sections = @{}
    for ($index = 0; $index -lt $count; $index++) {
        $entry = $base + $meta + $index * 32
        $nameAt = $base + $strings + [long](Read-UInt32 $Data $entry)
        $offset = $base + $content + [long](Read-UInt32 $Data ($entry + 4))
        $size = [long](Read-UInt32 $Data ($entry + 8))
        if ($nameAt -ge $Data.LongLength -or $size -lt 1 -or $offset + $size -gt $base + $strings) {
            Stop-ProgressCheck 'The save contains an invalid section.'
        }
        $nameEnd = $nameAt
        while ($nameEnd -lt $Data.LongLength -and $Data[$nameEnd] -ne 0 -and
               $nameEnd - $nameAt -lt 64) { $nameEnd++ }
        if ($nameEnd -ge $Data.LongLength -or $Data[$nameEnd] -ne 0 -or $nameEnd -eq $nameAt) {
            Stop-ProgressCheck 'The save contains an invalid section name.'
        }
        $name = [Text.Encoding]::ASCII.GetString($Data, [int]$nameAt, [int]($nameEnd - $nameAt))
        if ($name -cnotmatch '^[A-Za-z0-9_]{1,63}$') { Stop-ProgressCheck 'The save contains an invalid section name.' }
        if ($sections.ContainsKey($name)) { Stop-ProgressCheck 'The save contains duplicate sections.' }
        $sections[$name] = @{ Offset = $offset; Size = $size }
    }
    $end = $base + $content
    foreach ($section in ($sections.Values | Sort-Object { $_.Offset })) {
        if ($section.Offset -lt $end) { Stop-ProgressCheck 'The save contains overlapping sections.' }
        $end = $section.Offset + $section.Size
    }
    return $sections
}

function Get-DisplaySaveName {
    param($Snapshot)
    if ($ShowSavePath) { return $Snapshot.File.FullName }
    return $Snapshot.File.Name
}

function Show-ProgressHeader {
    param([string]$Name, $Snapshot)
    Write-Host ''
    Write-Host ('Tales of Vesperia: Definitive Edition - ' + $Name)
    Write-Host ('Save file: ' + (Get-DisplaySaveName $Snapshot))
    Write-Host ('Saved: ' + $Snapshot.File.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + ' (local time)')
    if (-not $SaveFile -and -not $SaveDirectory) {
        Write-Host 'Auto-selection uses the newest save across detected Steam accounts.'
    }
    Write-Host ''
}

function Write-ProgressJson {
    param($Snapshot, $Rows)
    $json = [pscustomobject]@{
        SaveFile = Get-DisplaySaveName $Snapshot
        SavedAt = $Snapshot.File.LastWriteTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        SHA256 = $Snapshot.Hash
        Rows = @($Rows)
    } | ConvertTo-Json -Depth 6
    # Escaping Unicode preserves filenames when Windows PowerShell redirects
    # JSON using a legacy terminal code page, including non-Latin user folders.
    [regex]::Replace($json, '[^\x00-\x7f]', {
        param($match)
        '\u{0:x4}' -f [int][char]$match.Value
    })
}

function Show-ProgressTable {
    param(
        [object[]]$Rows,
        [string[]]$Columns,
        [string[]]$RightAlign = @(),
        [string]$StatusColumn,
        [scriptblock]$IsComplete,
        [int]$MaxWidth = 100
    )
    # Paint every border segment separately, including vertical lines in headers
    # and data rows. Cell colors must never leak into the surrounding frame.
    $borderColor = 'DarkCyan'
    $headerColor = 'Cyan'
    $completeColor = 'Green'
    $pendingColor = 'Yellow'
    $vertical = [string][char]0x2502
    $horizontal = [string][char]0x2500

    # Keep tables inside the visible console, with one spare column to avoid
    # automatic wrapping at its right edge. Redirected output uses MaxWidth.
    try {
        $consoleWidth = $Host.UI.RawUI.WindowSize.Width
        if ($consoleWidth -gt 0) { $MaxWidth = [Math]::Min($MaxWidth, $consoleWidth - 1) }
    } catch { }
    $widths = @($Columns | ForEach-Object { $_.Length })
    foreach ($row in $Rows) {
        for ($i = 0; $i -lt $Columns.Count; $i++) {
            $widths[$i] = [Math]::Max($widths[$i], ([string]$row.($Columns[$i])).Length)
        }
    }
    $tableWidth = ($widths | Measure-Object -Sum).Sum + 3 * $Columns.Count + 1
    # Reduce the widest columns first. Wrap content instead of truncating names.
    while ($tableWidth -gt $MaxWidth) {
        $widest = -1
        for ($i = 0; $i -lt $Columns.Count; $i++) {
            if ($widths[$i] -gt [Math]::Max(4, $Columns[$i].Length) -and
                ($widest -eq -1 -or $widths[$i] -gt $widths[$widest])) { $widest = $i }
        }
        if ($widest -eq -1) { break }
        $widths[$widest]--
        $tableWidth--
    }
    $wrap = {
        param([string]$Text, [int]$Width)
        while ($Text.Length -gt $Width) {
            $cut = $Text.LastIndexOf(' ', $Width)
            if ($cut -lt 1) { $cut = $Width }
            $Text.Substring(0, $cut).TrimEnd()
            $Text = $Text.Substring($cut).TrimStart()
        }
        $Text
    }
    $border = {
        param([int]$Left, [int]$Join, [int]$Right)
        $segments = @($widths | ForEach-Object { $horizontal * ($_ + 2) })
        $text = ([string][char]$Left) + ($segments -join ([string][char]$Join)) + ([string][char]$Right)
        Write-Host $text -ForegroundColor $borderColor
    }
    $line = {
        param([object[]]$Values, [bool]$Header, [bool]$Complete)
        # Preserve each column's wrapped lines as an array (even a single line).
        $cells = @{}
        $height = 1
        for ($i = 0; $i -lt $Columns.Count; $i++) {
            $cells[$i] = @(& $wrap ([string]$Values[$i]) $widths[$i])
            $height = [Math]::Max($height, $cells[$i].Count)
        }
        for ($physicalLine = 0; $physicalLine -lt $height; $physicalLine++) {
            Write-Host $vertical -ForegroundColor $borderColor -NoNewline
            for ($i = 0; $i -lt $Columns.Count; $i++) {
                $value = ''
                if ($physicalLine -lt $cells[$i].Count) { $value = $cells[$i][$physicalLine] }
                if (-not $Header -and $Columns[$i] -in $RightAlign) {
                    $cell = ' ' + $value.PadLeft($widths[$i]) + ' '
                } else {
                    $cell = ' ' + $value.PadRight($widths[$i]) + ' '
                }
                if ($Header) {
                    Write-Host $cell -ForegroundColor $headerColor -NoNewline
                } elseif ($Columns[$i] -eq $StatusColumn) {
                    $color = if ($Complete) { $completeColor } else { $pendingColor }
                    Write-Host $cell -ForegroundColor $color -NoNewline
                } else {
                    Write-Host $cell -NoNewline
                }
                Write-Host $vertical -ForegroundColor $borderColor -NoNewline
            }
            Write-Host ''
        }
    }
    & $border 0x250c 0x252c 0x2510
    & $line $Columns $true $false
    & $border 0x251c 0x253c 0x2524
    foreach ($row in $Rows) {
        $values = @($Columns | ForEach-Object { $row.$_ })
        $complete = $false
        if ($null -ne $IsComplete) { $complete = [bool](& $IsComplete $row) }
        & $line $values $false $complete
    }
    & $border 0x2514 0x2534 0x2518
    Write-Host ''
}

try {
    $snapshot = Get-SaveSnapshot
    $data = $snapshot.Data
    $sections = Get-SaveSections $data
    # PC character IDs and title IDs, verified against the game's title data.
    $characters = @(
        @{ Id = 1; Name = 'Yuri';    Title = 25  },
        @{ Id = 2; Name = 'Estelle'; Title = 74  },
        @{ Id = 7; Name = 'Repede';  Title = 315 },
        @{ Id = 3; Name = 'Karol';   Title = 122 },
        @{ Id = 4; Name = 'Rita';    Title = 169 },
        @{ Id = 5; Name = 'Raven';   Title = 218 },
        @{ Id = 6; Name = 'Judith';  Title = 268 },
        @{ Id = 9; Name = 'Patty';   Title = 411 },
        @{ Id = 8; Name = 'Flynn';   Title = 362 }
    )
    $rows = foreach ($character in $characters) {
        $section = $sections['PC_STATUS' + $character.Id]
        if ($null -eq $section -or $section.Size -lt 0x3f20) {
            Stop-ProgressCheck ('Missing character data for ' + $character.Name + '.')
        }
        $offset = $section.Offset
        if ((Read-UInt32 $data ($offset + 0x44)) -ne $character.Id) {
            Stop-ProgressCheck ('Unexpected character layout for ' + $character.Name + '.')
        }
        # Title condition 4 reads this counter and requires >= 100.
        # Verified in PC code: getter 0x1405ce6d0, award check 0x140497bea.
        $count = Read-UInt32 $data ($offset + 0x3f1c)
        $titleByte = $data[$offset + 0x3c90 + [int][Math]::Floor($character.Title / 8)]
        $unlocked = ($titleByte -band (1 -shl ($character.Title % 8))) -ne 0
        [pscustomobject]@{
            Character = $character.Name
            'Fatal Strikes' = "$count / 100"
            Remaining = $(if ($unlocked) { 0 } else { [Math]::Max(0, 100 - [long]$count) })
            Title = $(if ($unlocked) { 'Unlocked' } else { 'Not yet' })
        }
    }

    if ($AsJson) { Write-ProgressJson $snapshot $rows; exit 0 }
    Show-ProgressHeader 'Fatal Strikes' $snapshot
    Show-ProgressTable -Rows $rows -Columns @('Character', 'Fatal Strikes', 'Remaining', 'Title') `
        -RightAlign @('Fatal Strikes', 'Remaining') -StatusColumn 'Title' `
        -IsComplete { param($row) $row.Title -eq 'Unlocked' }
    Write-Host 'Save in game before checking. This command only reads your saves.'
    exit 0
} catch {
    Write-ProgressError 'Could not read Fatal Strike progress' $_
    exit 1
}
