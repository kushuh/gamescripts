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
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Read-Save-Points.ps1
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Read-Save-Points.ps1 -SaveDirectory "D:\Steam\userdata\ACCOUNT_ID\738540\remote"
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
    $section = $sections['SavePoint']
    if ($null -eq $section -or $section.Size -ne 0x400) {
        throw 'Missing or unsupported save-point data.'
    }
    # SavePoint uses one byte per registration, not packed bits.
    # Layout: HyoutaTools SaveDataBlockSavePoint.cs; first 44 guide mappings
    # independently checked against this player's earlier snapshots.
    # https://github.com/AdmiralCurtiss/HyoutaTools/blob/master/HyoutaToolsLib/Tales/Vesperia/SaveData/SaveDataBlockSavePoint.cs
    # Guide IDs differ from storage indexes; the CSV preserves guide labels.
    # Shared registrations: 33/37 -> flag 2; 41/42 -> flag 38.
    # Grotto mapping: Four Isles/Nordopolica=62, shared chamber=63,
    # Ilyccia/Zaphias=60, Tolbyccia/Heliord=61, Yurzorea/Yumanju=59.
    $points = @'
Guide,Flag,Location,Shared
1,5,"Zaphias, Lower Quarter",
2,7,"Zaphias, castle prison !",
3,9,"Zaphias, upper castle hall !",
4,6,"Zaphias, Royal Quarter",
5,20,"Deidon Hold",
6,25,"Quoi Woods",
7,14,"Halure",
8,49,"Aspio !",
9,45,"Shaikos Ruins",
10,27,"Ehmead Hill",
11,43,"Capua Nor",
12,57,"Magistrate's Palace !",
13,42,"Behind the palace !",
14,44,"Capua Torim",
15,24,"Caer Bocram",
16,51,"Heliord",
17,26,"Dahngrest",
18,3,"Keiv Moc, middle",
19,4,"Keiv Moc, pre-boss !",
20,56,"Dahngrest sewers, middle",
21,58,"Dahngrest sewers, exit",
22,15,"Ghasfarost, confinement room",
23,16,"Ghasfarost, upper tower",
24,0,"Fiertia, before choosing the Atherum boarding party !",
25,1,"Atherum, inside",
26,50,"Nordopolica",
27,12,"Cados, aer area",
28,13,"Cados, pre-boss !",
29,39,"Mantaic",
30,53,"Kogorh, oasis",
31,54,"Kogorh, pre-boss !",
32,52,"Yormgen, first visit !",
33,2,"Fiertia after Belius, before exiting the cabin !",33/37
34,34,"Manor of the Wicked",
35,18,"Mt. Temza, ruins",
36,19,"Mt. Temza, summit !",
37,2,"Fiertia after Tison/Nan, before speaking to Judith !",33/37
38,55,"Egothor Forest",
39,17,"Myorzo",
40,37,"Baction, B1F",
41,38,"Baction, B2F",41/42
42,38,"Baction, pre-boss",41/42
43,31,"Heracles, outside the Control Room before Zagi !",
44,30,"Heracles, engine-room area",
45,32,"Zopheir, before approaching the aer krene / Baitojoh !",
46,8,"Zaphias, dining room !",
47,11,"Zaphias, audience/back room",
48,10,"Zaphias, Sword Stair entrance !",
49,46,"Zaude, exterior",
50,48,"Zaude, before Yeager !",
51,47,"Zaude, before Alexei !",
52,33,"Zopheir, return/Undine visit",
53,28,"Erealumen, middle",
54,29,"Erealumen, lake/pre-boss !",
55,40,"Relewiese, middle",
56,41,"Relewiese, outside Khroma's cave at the bottom",
57,21,"Northeast Hypionia camp, before leaving for the negotiations !",
58,22,"Newly founded Aurnion, before completing its development !",
59,62,"Four Isles, Sunken Grotto",
60,63,"Shared Sword Dancer chamber",
61,60,"Ilyccia, Sunken Grotto",
62,61,"Tolbyccia, Sunken Grotto",
63,59,"Yurzorea, Sunken Grotto",
64,23,"Fully developed Aurnion",
65,35,"Tarqaron, 4F before the final Zagi fight !",
66,36,"Tarqaron, final ascent/6F",
67,65,"Firmament 3F",
68,66,"Firmament 6F",
69,67,"Firmament 9F",
70,68,"Firmament bottom",
71,64,"City of the Waning Moon, left outer edge of the arrival platform",
72,69,"Existence 2F",
73,70,"Existence 5F",
74,71,"Existence 8F",
75,72,"Existence bottom",
76,73,"Hegemony 3F",
77,74,"Hegemony 6F",
78,75,"Hegemony 9F",
79,76,"Hegemony bottom",
80,77,"Fauna 3F",
81,78,"Fauna 6F",
82,79,"Fauna 9F",
83,80,"Fauna bottom",
84,81,"Fatality 3F",
85,82,"Fatality 6F",
86,83,"Fatality 9F",
87,84,"Fatality bottom",
88,85,"Abysm 3F",
89,86,"Abysm 6F",
90,87,"Abysm 9F",
91,88,"Abysm bottom",
'@ | ConvertFrom-Csv
    for ($flag = 0; $flag -lt 89; $flag++) {
        if ($data[$section.Offset + $flag] -gt 1) { throw 'Unexpected save-point flag value.' }
    }
    $registered = 0
    for ($flag = 0; $flag -lt 89; $flag++) {
        if ($data[$section.Offset + $flag] -eq 1) { $registered++ }
    }
    $rows = @(foreach ($point in $points) {
        $used = $data[$section.Offset + [int]$point.Flag] -eq 1
        $status = if ($used) { 'Used' } else { 'Not used yet' }
        if ($point.Shared) { $status += ' *' }
        [pscustomobject]@{
            Guide = [int]$point.Guide
            Status = $status
            Location = $point.Location
            Used = $used
            SharedWith = $point.Shared
            Flag = [int]$point.Flag
        }
    })
    if ($AsJson) { Write-ProgressJson $snapshot $rows; exit 0 }
    Show-ProgressHeader 'Save Points' $snapshot
    Write-Host ("Registered flags in this save: $registered / 89 (91 guide entries).")
    Write-Host 'Numbers match the guide. ! = temporary or time-sensitive location.'
    Write-Host ''
    # Short groups make the 91-entry checklist easier to scan without changing order.
    $groups = @(
        @{ Name = 'Act I'; First = 1; Last = 23 },
        @{ Name = 'Act II'; First = 24; Last = 51 },
        @{ Name = 'Act III and optional areas'; First = 52; Last = 66 },
        @{ Name = 'Necropolis'; First = 67; Last = 91 }
    )
    foreach ($group in $groups) {
        Write-Host ('  ' + $group.Name + ' | ' + $group.First + '-' + $group.Last) -ForegroundColor Cyan
        $groupRows = @($rows | Where-Object { $_.Guide -ge $group.First -and $_.Guide -le $group.Last })
        Show-ProgressTable -Rows $groupRows -Columns @('Guide', 'Status', 'Location') `
            -RightAlign @('Guide') -StatusColumn 'Status' -IsComplete { param($row) $row.Used }
    }
    Write-Host '* 33/37 share one flag; 41/42 share another. Each pair shows the same status.'
    Write-Host 'A used shared flag does not identify which individual appearance you visited.'
    Write-Host 'Not used yet does not distinguish future locations from missed locations.'
    Write-Host 'Save in game before checking. This command only reads your saves.'
    exit 0
} catch {
    Write-Host ('Could not read save-point progress: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
