# Crystal Finance GemManager

GemManager is a Windows PowerShell 5.1 backup workflow for Crystal Finance on Windows Server 2022. It must run as the local Administrator from the Administrator Startup context. It is not a service and never runs as SYSTEM.

## Files

- `config.ps1`: tunable data and the editable warning text.
- `GemManager.psm1`: all functions, external commands, destructive operations, logging, RDP drain, archive verification, transport, and GFS retention.
- `Start-GemManager.ps1`: CLI and plain text TUI dispatcher.

All paths in `config.ps1` must be absolute. `SourceDir` and `SevenZip` must exist. Targets must be non-root directories. Mapped drives must be visible to the Administrator account at startup.

## Operations

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-GemManager.ps1 -RunNow
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-GemManager.ps1 -Daemon
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-GemManager.ps1 -Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-GemManager.ps1 -Tail -Lines 30
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-GemManager.ps1 -Stop
```

With no switch, the script opens the numbered TUI. A Startup shortcut can target `powershell.exe -File <path>\Start-GemManager.ps1 -Daemon`; the script only reports a missing shortcut and never creates one.

Each run gets one transcript under `%APPDATA%\GemManagerPS\Logs`, plus `backup-summary.csv` and `last-run.json`. The named mutex prevents daemon and manual overlap. Each destination receives only the verified archive for that run; an unavailable or unwritable destination is recorded and the remaining destinations are still attempted. Mixed target results are marked `PARTIAL`. If every destination fails, the run is `FAILED`.

## Retention and copy behavior

Archives are named `crystal_yyyyMMdd_HHmm.7z`. Retention selects the union of the newest daily, 12 newest ISO weeks (one newest archive per week), nearest-to-first-Sunday monthly, and January yearly survivors. Dates come from filenames, never timestamps. When a new archive is created, older archive files in staging are removed after the new archive passes verification; a same-day archive is reused without recompression.

Transport copies individual archive files and does not delete unrelated destination files. Destination copies are independent and are not a substitute for an offline or otherwise isolated backup against deletion, corruption, or ransomware.

## Safe first test

1. Create a disposable source such as `C:\GemManagerDummy\Crystal Finance` with a few small Latin-named files and nested folders.
2. Install 7-Zip at the configured path, or point `SevenZip` at the installed `7z.exe`.
3. Use two disposable non-root target directories on available volumes. Do not use production E:, H:, or Z:.
4. Set `SourceDir`, `Targets`, `StagingTemp`, and `MinFreeSpaceGB` in `config.ps1` to test values. Set `MinFreeSpaceGB` low enough for the test volume.
5. Run `-RunNow` as Administrator. Confirm the transcript records every external command and exit code, the archive passes `7z t`, each available target receives the archive, and `last-run.json` reports the result.
6. Run `-RunNow` again within the same minute and confirm compression is skipped for the existing deterministic archive.
7. Run `-Status`, disconnect the optional target, and confirm the run is visibly `PARTIAL` while the primary local result remains available.
8. Restore production values only after inspecting the transcript and confirming unavailable-target handling on disposable targets.

Do not first-test against `D:\Crystal Finance`. The RDP drain will notify and eventually log off eligible sessions. Keep those calls disabled while testing over an interactive RDP session.

## Audit expectations

Destructive commands are confined to `GemManager.psm1` and are preceded by a logged exact target: session ID for logoff/msg, path for archive and probe deletion. RDP is restored in `finally` and by the module trap path. If drain verification fails, archiving is aborted.
