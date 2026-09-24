# Vesperia progress checkers for Windows

## Files

| Double-click launcher | Reader code | What it shows |
|---|---|---|
| `Check-Fatal-Strikes.bat` | `Read-Fatal-Strikes.ps1` | All nine characters' Fatal Strike counters, remaining strikes, and title status |
| `Check-Save-Points.bat` | `Read-Save-Points.ps1` | All 91 guide entries in guide-number order, with **Used / Not used yet** status |
| `Check-Secret-Missions.bat` | `Read-Secret-Missions.ps1` | All 25 Definitive Edition missions, with **Done / Not done** status |

Each `.bat` opens its matching `.ps1` reader. Keep each pair in the same folder. The guide is not needed to run them, but save-point numbering matches its checklist.

## Requirements

- Windows 10/11 with Windows PowerShell 5.1 or newer.
- A local **Steam version** save of **Tales of Vesperia: Definitive Edition**. A Steam Cloud save must already be downloaded onto this computer.

No WSL, Python, downloads, installation, administrator rights, or running game is required. Console and non-Steam save formats are not supported.

## Normal use

1. Save your progress in the game and wait for saving to finish.
2. Double-click the desired `Check-*.bat`.
3. Check the displayed save path and timestamp, then read the table. Scroll up for earlier rows.
4. Press a key to close the window; rerun the checker after your next in-game save.

Each checker finds Steam through its Windows registry entries and standard installation folders, checks its local Steam accounts, and selects the **most recently saved file**. No user name, Steam account ID, drive letter, or installation path is hardcoded. If multiple accounts or playthroughs are present, check the printed path or select an exact file as explained below.

Copy all six scripts, or just a matching `.bat`/`.ps1` pair, to another Windows PC. They can run from the Desktop or any folder. **Game files and saves are never modified.** The launcher's execution-policy option applies only to that PowerShell process; it does not change the computer's policy.

## Terminal use

Open a terminal in the scripts' folder. To run without the final keypress:

```bat
cmd.exe /d /c "Check-Fatal-Strikes.bat --no-pause"
cmd.exe /d /c "Check-Save-Points.bat --no-pause"
cmd.exe /d /c "Check-Secret-Missions.bat --no-pause"
```

## Choose a folder or an exact save

For a particular account, an unusual portable Steam installation, or an older checkpoint, run the corresponding `.ps1` directly with either `-SaveDirectory` or `-SaveFile`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Read-Save-Points.ps1 -SaveDirectory "D:\Steam\userdata\ACCOUNT_ID\738540\remote"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Read-Secret-Missions.ps1 -SaveFile "D:\Steam\userdata\ACCOUNT_ID\738540\remote\TLSaveData0_02"
```

Replace these example paths with your own. All three readers accept these options. A folder selects its newest checkpoint; an exact file reads only that checkpoint. The options cannot be combined.

For structured output, add `-AsJson`, for example:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Read-Fatal-Strikes.ps1 -AsJson
```

## Reading the results

**Save points:** entries **33/37** (Fiertia cabin) share a registration, as do **41/42** (Baction B2F). Both members of each pair show the same status, marked `*`; the save cannot distinguish which individual appearance you visited. The 91 guide entries cover **89 distinct stored flags**, so the summary counts flags. `!` identifies a temporary or time-sensitive point. An unset flag does not distinguish a future location from a missed one.

**Secret Missions:** the checker reads the selected save's individual completion flags, independent of Steam achievement history. It uses Definitive Edition numbering, including the two Cursed Wanderer missions.

**Fatal Strikes:** a joined-border table aligns numeric values; unlocked-title rows appear green. `Title` reports the actual unlocked flag. If a title was carried into NG+, `Remaining` stays zero even if that run's counter is below 100.

All results describe the selected saved checkpoint. Unsaved play is not included, and unrelated save files are never combined.

## Troubleshooting

- **No saves found:** save once on this computer and check that Steam Cloud has downloaded your local saves. For an unregistered portable Steam location, supply `-SaveDirectory`.
- **Wrong playthrough/account:** check the printed path and timestamp; use `-SaveDirectory` or `-SaveFile` to select the intended one.
- **Progress looks old:** save in game again, wait for it to finish, then rerun the checker.
- **Game is currently saving:** retry once the save operation finishes.
- **Unsupported/incomplete save:** select a complete Steam Definitive Edition save. These scripts do not repair or edit saves.
- **The `.ps1` opens in an editor:** double-click the `.bat` instead.

The scripts return exit code `0` on success and `1` on failure. Their comments explain Steam discovery, stable read-only snapshots, section decoding, and the verified progress fields/mappings. For parameter help, use `Get-Help .\Read-Save-Points.ps1 -Full` in PowerShell, substituting another reader's name as needed.
