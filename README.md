# Clonezilla Backup Reminder

A small PowerShell reminder tool that checks for a Clonezilla USB drive and an external backup disk, then prompts you to run a backup and optionally reboot the PC.

## Tested on

- Windows 10 22H2
- OS Build 19045.7058

## What it does

- Reads and stores reminder state in `ClonezillaReminder.json`
- Displays a WPF dialog with:
  - Clonezilla USB status
  - External backup drive status and free space
  - Last backup date
  - Next scheduled reminder
  - Backup history (last 5 entries)
- Allows the user to choose:
  - Run now (records the backup and schedules the next reminder)
  - Later
  - Tomorrow
  - One week
  - Custom date
- If "Run now" is chosen and all checks pass, the machine reboots after 60 seconds.

## Files

- `clonezilla_reminder.ps1` — main reminder script
- `ClonezillaReminder.json` — state file containing `LastBackup` and `NextRun`
- `ClonezillaBackupHistory.log` — generated automatically when backups are recorded
- `run_hidden.vbs` — optional helper to launch the PowerShell script hidden

## Default configuration

The script is configured to use:

- `C:\Scripts` as the base path
- `CLONEZILLA` as the USB drive label
- `External` as the backup drive label
- `250 GB` minimum required free space on the backup disk

These values are defined in the top section of `clonezilla_reminder.ps1` and can be customized.

## How to run

1. Place all files in `C:\Scripts`
2. Double-click `run_hidden.vbs` to start the reminder quietly
   - This runs `powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\clonezilla_reminder.ps1"` in hidden mode
3. Or run the PowerShell script directly if you want to see any console output:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\clonezilla_reminder.ps1"
```

## Notes

- The reminder uses a schedule check so it only shows when the current date is on or after the next scheduled reminder.
- If no state file exists, the script creates `ClonezillaReminder.json` and treats the first execution as a first run.
- If the backup drive or Clonezilla USB is not found, the Run button is disabled until both are present and enough free space exists.
- The script includes test variables near the top for local debugging:
  - `$TEST_SkipScheduleCheck`
  - `$TEST_SkipReboot`
  - `$TEST_ForceFirstRun`
  - `$TEST_FakeDevices`

## Custom reminder dates

Use the Custom button to enter a specific date in either:

- `YYYY-MM-DD` format
- `+N` days from today

## Log history

The script appends a history entry to `ClonezillaBackupHistory.log` each time Run now is pressed, including the new next reminder date.

