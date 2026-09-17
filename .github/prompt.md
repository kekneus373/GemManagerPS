# ROLE

You are a senior Windows Server / PowerShell automation engineer. Build a production-grade
backup automation for a mission-critical CMS ("Crystal Finance") on Windows Server 2022.
PowerShell 5.1 only (.NET Framework). No PS7-only syntax, no PSCustomObject::new(), no ternary.
Run-as: local Administrator via Startup folder (NOT a service, NOT SYSTEM).

# DELIVERABLES

1. config.ps1          All tunables. Pure data, zero logic. Dot-sourced by both other files.
2. GemManager.psm1  PowerShell script MODULE containing every function, grouped with
                       '#region' banners in execution order:
                         #region Logging & Primitives
                         #region RDP Drain & Lockdown
                         #region Archive & Verify
                         #region Transport (robocopy)
                         #region Retention (GFS prune)
                       Export-ModuleMember ONLY these: Invoke-GemManager, Get-CrystalStatus,
                       Stop-GemManager, Remove-CrystalArchive -WhatIf.
                       Everything else stays private/internal.
3. Start-GemManager.ps1  Entry point: Import-Module .\GemManager.psm1 -Force, then either
                       run the daemon loop or parse CLI switches:
                         -RunNow | -Tail [-Lines 30] | -Status | -Stop | -Menu
                       With no args -> interactive numbered TUI.
4. README.md
Audit rule: any destructive call (/MIR, Remove-Item, logoff, registry write, service stop) MUST
sit inside GemManager.psm1 and be preceded by a logged line naming the exact target path/session.
No destructive operation may appear in config.ps1 or Start-GemManager.ps1.

Every file: `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, comment-based
help on each function, `[CmdletBinding()]`, explicit param types, no Write-Host outside the TUI.

# CONFIG BLOCK (base looks like this, values are mine)

```powershell
$Config = [pscustomobject]@{
    SourceDir      = 'D:\Crystal Finance'
    StagingTemp    = Join-Path $env:LOCALAPPDATA 'Temp\GemManagerPS'
    LocalTargets   = @('E:\ArchivesCrystal', 'H:\ArchivesCrystal')  # year subfolder added at runtime
    SambaTarget    = 'Z:\Crystal_Mirror'
    SevenZip       = 'C:\Program Files\7-Zip\7z.exe'
    ProtectedAdmin = 'Administrator'          # never notified, never logged off
    WarnOffsetsMin = @(10, 5, 2, 1)           # minutes remaining when each popup fires
    LogDir         = Join-Path $env:APPDATA 'GemManagerPS\Logs\backup_<stamp>.log'
    Retention      = @{ d = 30; w = 12; m = 12; y = 5 }
    TriggerTimes   = '01:00'
    MinFreeSpaceGB = 60                        # required free space on EVERY destination
    RobocopyArgs   = @('/MIR','/R:2','/W:5','/MT:16','/NP','/NFL','/NDL','/XJ')
}
```

All paths must be validated as absolute and non-empty at startup; fail fast with a clear message
if SourceDir or SevenZip is missing. Never accept a drive root ('D:\', 'E:\') as any target.

# STAGE 1 — RDP USER DRAIN (highest priority, get this exactly right)

- Enumerate sessions with `query user`; parse to objects {SessionName, Username, Id, State}.
- Exclude: session 0/Services, the console session, and $Config.ProtectedAdmin.
- Notify every other session using msg.exe per-session-id: `msg <id> /TIME:<secs> <text>`
  (per-id targeting avoids msg.exe Error 2147500058 on the console session, and /TIME so stale
  popups expire and are replaced rather than stacking).[2]
- Fire exactly 4 warnings, at T-10, T-5, T-2, T-1 minutes. Message text states the exact wall-clock
  time they WILL be disconnected, says saving work now, and that idle/absent users are signed out
  regardless. Make the text a here-string constant in config.ps1 so I can edit it.
- Between warnings, re-enumerate. If all non-admin sessions are gone, skip remaining waits and
  continue immediately (don't burn 10 minutes for nothing).
- At T-0: force logoff remaining sessions (`logoff <id>`), then verify zero non-admin sessions
  remain. Retry up to 3x with 15s gaps. If users still linger, ABORT the backup, restore RDP,
  log CRITICAL, notify — do not archive while the app is mid-write.
- Then lock the door: Run `change logon /disable` to stop new connections.
  Falling back to stopping TermService is acceptable but MUST be paired with guaranteed restart.
- Restore RDP access on ALL exit paths — success, failure, exception, Ctrl+C. Implement this with
  try/finally + trap, and make the restore function idempotent so double-calling is harmless.
  Leaving workers locked out after a crash is the worst possible outcome in this script.

# STAGE 2 — ARCHIVE + VERIFY

- Name: `crystal_<yyyyMMdd>_<hhmm>.7z`
- Build into StagingTemp first, never write archives straight to E:/H:/Z:.
- Command shape: `7z.exe a -t7z -mx=3 -mmt=on -ms=on '<archive>' '<SourceDir>\*'`
- Must handle spaces in 'D:\Crystal Finance' correctly (use --% / the call operator + arg array,
  never string interpolation into a shell).
- Verify with `7z t <archive>` and treat NONZERO exit as corruption → abort, restore RDP, alert.
  Do not trust "file exists and size > 0" as verification.
- Guard against runaway growth: if staging temp free space < 1.2 x last archive size, warn early.

# STAGE 3 — TRANSPORT (robocopy.exe only, never Copy-Item)

- Fan out the verified archive to `E:\ArchivesCrystal\<year>\` and `H:\ArchivesCrystal\<year>\`.
  These two are mirrors of each other: use /MIR, sourced from the LOCAL staging copy.
- Then sync the resulting backup folder to Z:\Crystal_Mirror with /MIR.
- robocopy returns a BITMASK, not 0/1: codes 0–7 are success, >=8 is failure. Assert
  `$LASTEXITCODE -lt 8`. A single `if ($LASTEXITCODE -ne 0)` check is a bug — don't write that.
- Before copying, check each destination: path resolvable, writable (test-create/delete a probe
  file), and free space >= archive size + MinFreeSpaceGB. If H: or Z: is down, DO NOT fail the
  whole run: keep E: result, mark the run PARTIAL, log loudly, surface it in the TUI next launch.
- Quote paths defensively; beware trailing backslash inside quotes breaking argument parsing.
- Add /XJ to avoid following junctions into recursion.

# STAGE 4 — RETENTION (Grandfather-Father-Son)

- Parse dates from filenames (`crystal_yyyyMMdd_<hhmm>.7z`), never from LastWriteTime (robocopy/COPYALL
  preserves timestamps and would corrupt bucketing).
- Buckets: newest 30 daily, newest 12 weekly (one per ISO week), newest 12 monthly (first Sunday
  of month), newest 5 yearly (January). Keep the union of survivors; delete everything else.
- Prune on first local target copy, after transport succeeds, so the resulting prune will be
  mirrored along. Do not prune each target individually!
- Print a table before deleting: retained count, deleted count, bytes reclaimed.

# STAGE 5 — DAEMON + TUI

- Daemon = loop with due-time computation against TriggerTimes, sleeping in <=60s slices so it
  reacts to config edits and stop requests; writes a heartbeat line to the log each tick.
- On start: detect whether the shortcut already exists in
  [Environment]::GetFolderPath('Startup'); if absent, print a one-time instruction telling me I can
  drop it there for auto-start (do not silently create it).
- TUI: plain numbered menu, arrow-key-free, no GUI libs. Options:
  [1] Run backup now   [2] Tail last 30 log lines   [3] Stop daemon
  [4] Show status (last run result, targets health, next scheduled run)   [Q] Quit
  Read-Host driven, ~60 lines max, must survive a target being offline.

# CROSS-CUTTING REQUIREMENTS

- Single transcript log per run: Join-Path $env:APPDATA 'GemManagerPS\Logs\backup_<stamp>.log',
  plus an append-only summary CSV (timestamp, duration, archive, size, targets OK/FAIL, exit code).
- Every external exe invocation logs its full output and exit code.
- Machine-readable status JSON in the log dir so the TUI can read last-run state cheaply.
- Idempotent: a second run within the same day must detect the existing archive and skip cleanly
  rather than double-compressing.
- Concurrency lock: a named Mutex so the daemon and a manual TUI run cannot overlap.
- NO silent catches anywhere. No `catch {}`, no `-ErrorAction SilentlyContinue` except where you
  add a comment justifying it.
- Long-path aware; assume paths may exceed 260 chars.

# DEFINITION OF DONE — also write these tests in README

- Document explicitly: /MIR DELETES destination extras, and this mirror is NOT a backup against
  source-side deletion — say so in README.
- Provide a safe first-test procedure on a dummy source dir before pointing it at D:\Crystal Finance.
- Ask me clarifying questions BEFORE coding if anything about the environment is ambiguous

# COMMON QUESTIONS

1. **Configuration location:** Should `config.ps1`, `GemManager.psm1`, `Start-GemManager.ps1`, and `README.md` all live in `GemManagerPS`?
 Yes, this is a base project dir.

2. **Startup execution:** Will the Startup entry launch `Start-GemManager.ps1` through a shortcut targeting `powershell.exe -File ...`, or should the README recommend a specific shortcut command?
 We can recommend a command but this is all up to the deployer - they may want to do it their way, so let's keep it as a tiny tip.

3. **Mapped drives:** Are `E:`, `H:`, and `Z:` guaranteed to be mapped and visible to the Administrator account at Startup? Mapped drives often do not exist in elevated or Startup contexts. Should the script support UNC paths as the production configuration?
 Yes, they are automatically mapped at startup. Although, there is a catch: drive H: is external (USB) and might get disconnected at some point - we should log that and silently continue (it's not a big deal).

4. **Console session:** Should the active console session be identified using `query session` / session ID comparison, excluding whichever session is marked `console`, or do you have a fixed console session ID?
 Yes, this command contains `console` in output. Althought, it's much more clear when `quser` or `query user` is run - gives exact USERNAME and SESSIONNAME.

5. **Retention bucket interpretation:** For weekly retention, should “one per ISO week” retain the newest archive in each ISO week? For monthly retention, should “first Sunday of month” mean retain the newest archive occurring on or after the first Sunday, or retain the archive nearest to that Sunday?
 5.1. Yes, newest archive in each week is fine.
 5.2. Best is nearest to Sunday - logic more reliable.

6. **Notifications:** What should the abort/failure notification text be, and should it use `msg.exe` to eligible sessions only, email, or both?
 I mean, we do not want to disrupt users with various "failures" - I don't want to get calls :D. Let's keep the warning message only.

7. **TermService fallback:** If `change logon /disable` fails, should the script stop and restart `TermService`, or should it abort rather than risk disrupting unrelated RDP state?
 Aborting is the best case. I don't trust any big system changes - one try is enough.

8. **Long paths:** Is the source/application known to support Windows long-path prefixes (`\\?\`), or should long-path handling be limited to archive and filesystem validation?
 The application is legacy and uses mostly DOS-style filenames. Everything is Latin.
