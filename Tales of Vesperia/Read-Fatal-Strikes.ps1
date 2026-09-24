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
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Read-Fatal-Strikes.ps1
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Read-Fatal-Strikes.ps1 -SaveDirectory "D:\Steam\userdata\ACCOUNT_ID\738540\remote"
.NOTES
    Save in game first: unsaved progress is not present on disk. The process-local
    execution-policy option in the launcher does not change Windows policy.
    Exit code 0 means success; 1 means the save could not be found or decoded.
    All save access uses read-only operations. Concurrent game saves trigger retries.
#>
[CmdletBinding()]
param(
    [string]$SaveDirectory,
    [string]$SaveFile,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'

function Get-SteamRoots {
    # Steam registry values support custom drives; environment-based fallbacks
    # avoid hardcoded drive letters or Windows users.
    $roots = @()
    foreach ($key in @('HKCU:\Software\Valve\Steam',
                       'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
                       'HKLM:\SOFTWARE\Valve\Steam')) {
        $settings = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($null -eq $settings) { continue }
        foreach ($property in @('SteamPath', 'InstallPath')) {
            if ($settings.$property) { $roots += [string]$settings.$property }
        }
        if ($settings.SteamExe) {
            $roots += Split-Path -Parent ([string]$settings.SteamExe).Trim('"')
        }
    }
    foreach ($variable in @('ProgramFiles(x86)', 'ProgramFiles', 'ProgramW6432', 'LOCALAPPDATA')) {
        $folder = [Environment]::GetEnvironmentVariable($variable)
        if ($folder) { $roots += Join-Path $folder 'Steam' }
    }
    $roots | Where-Object { $_ } | ForEach-Object {
        [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($_).Replace('/', '\'))
    } | Sort-Object -Unique
}

function Get-SaveDirectories {
    if ($SaveDirectory) {
        if (-not (Test-Path -LiteralPath $SaveDirectory -PathType Container)) {
            throw "Save folder not found: $SaveDirectory"
        }
        return (Get-Item -LiteralPath $SaveDirectory).FullName
    }
    # Saves live under the Steam client, even if the game uses another library.
    # Search all numeric account folders instead of assuming one Steam account.
    $directories = foreach ($root in Get-SteamRoots) {
        $userdata = Join-Path $root 'userdata'
        if (-not (Test-Path -LiteralPath $userdata -PathType Container)) { continue }
        foreach ($account in Get-ChildItem -LiteralPath $userdata -Directory -ErrorAction SilentlyContinue) {
            if ($account.Name -notmatch '^\d+$') { continue }
            $remote = Join-Path $account.FullName '738540\remote'
            if (Test-Path -LiteralPath $remote -PathType Container) { $remote }
        }
    }
    $directories | Sort-Object -Unique
}

function Get-LatestSave {
    # An explicit file wins. Otherwise choose the newest checkpoint in scope.
    # Never combine progress from different files or Steam accounts.
    if ($SaveFile) {
        if ($SaveDirectory) { throw 'Use either -SaveFile or -SaveDirectory, not both.' }
        if (-not (Test-Path -LiteralPath $SaveFile -PathType Leaf)) {
            throw "Save file not found: $SaveFile"
        }
        return Get-Item -LiteralPath $SaveFile
    }
    $files = @(foreach ($directory in Get-SaveDirectories) {
        Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^TLSaveData\d+_\d+$' }
    })
    if ($files.Count -eq 0) {
        throw 'No Steam Vesperia saves found. Save in game first, or run this .ps1 with -SaveDirectory pointing to your 738540\remote folder.'
    }
    return $files | Sort-Object LastWriteTimeUtc, FullName -Descending | Select-Object -First 1
}

function Read-UInt32 {
    param([byte[]]$Data, [long]$Offset)
    if ($Offset -lt 0 -or $Offset + 4 -gt $Data.LongLength) {
        throw 'The save is incomplete or has an unsupported format.'
    }
    return [BitConverter]::ToUInt32($Data, [int]$Offset)
}

function Get-SaveSnapshot {
    # Retry a concurrent save instead of reporting partially written data.
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $file = Get-LatestSave
            $stamp = $file.LastWriteTimeUtc
            $length = $file.Length
            $data = [IO.File]::ReadAllBytes($file.FullName)
            $hasher = [Security.Cryptography.SHA256]::Create()
            try {
                $hash = [BitConverter]::ToString($hasher.ComputeHash($data)).Replace('-', '')
            } finally { $hasher.Dispose() }
            $after = Get-Item -LiteralPath $file.FullName
            $afterHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            $latest = Get-LatestSave
            if ($after.LastWriteTimeUtc -ne $stamp -or $after.Length -ne $length -or
                $hash -ne $afterHash -or $latest.FullName -ne $file.FullName) {
                throw 'The game is currently saving. Try again after saving finishes.'
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
    # PC saves wrap TO8SAVE in 0x228 bytes. Its directory supplies section
    # positions; character, save-point, and Scenario offsets are not hardcoded.
    $base = 0x228
    if ($Data.Length -lt $base + 0x30 -or
        [Text.Encoding]::ASCII.GetString($Data, $base, 7) -ne 'TO8SAVE') {
        throw 'This is not a supported Steam Definitive Edition save.'
    }
    $meta = [long](Read-UInt32 $Data ($base + 0x20))
    $count = Read-UInt32 $Data ($base + 0x24)
    $content = [long](Read-UInt32 $Data ($base + 0x28))
    $strings = [long](Read-UInt32 $Data ($base + 0x2c))
    if ($count -lt 1 -or $count -gt 256) { throw 'Unsupported save section directory.' }
    $sections = @{}
    for ($index = 0; $index -lt $count; $index++) {
        $entry = $base + $meta + $index * 32
        $nameAt = $base + $strings + [long](Read-UInt32 $Data $entry)
        $offset = $base + $content + [long](Read-UInt32 $Data ($entry + 4))
        $size = [long](Read-UInt32 $Data ($entry + 8))
        if ($nameAt -ge $Data.LongLength -or $offset + $size -gt $Data.LongLength) {
            throw 'The save contains an invalid section.'
        }
        $nameEnd = $nameAt
        while ($nameEnd -lt $Data.LongLength -and $Data[$nameEnd] -ne 0 -and
               $nameEnd - $nameAt -lt 64) { $nameEnd++ }
        if ($nameEnd -ge $Data.LongLength -or $Data[$nameEnd] -ne 0 -or $nameEnd -eq $nameAt) {
            throw 'The save contains an invalid section name.'
        }
        $name = [Text.Encoding]::ASCII.GetString($Data, [int]$nameAt, [int]($nameEnd - $nameAt))
        if ($sections.ContainsKey($name)) { throw 'The save contains duplicate sections.' }
        $sections[$name] = @{ Offset = $offset; Size = $size }
    }
    return $sections
}

function Show-ProgressHeader {
    param([string]$Name, $Snapshot)
    Write-Host ''
    Write-Host ('Tales of Vesperia: Definitive Edition - ' + $Name)
    Write-Host ('Save file: ' + $Snapshot.File.FullName)
    Write-Host ('Saved: ' + $Snapshot.File.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + ' (local time)')
    if (-not $SaveFile -and -not $SaveDirectory) {
        Write-Host 'Auto-selection uses the newest save across detected Steam accounts.'
    }
    Write-Host ''
}

function Write-ProgressJson {
    param($Snapshot, $Rows)
    [pscustomobject]@{
        SaveFile = $Snapshot.File.FullName
        SavedAt = $Snapshot.File.LastWriteTime.ToString('o')
        SHA256 = $Snapshot.Hash
        Rows = @($Rows)
    } | ConvertTo-Json -Depth 6
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
            throw ('Missing character data for ' + $character.Name + '.')
        }
        $offset = $section.Offset
        if ((Read-UInt32 $data ($offset + 0x44)) -ne $character.Id) {
            throw ('Unexpected character layout for ' + $character.Name + '.')
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
    Write-Host ('Could not read Fatal Strike progress: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
