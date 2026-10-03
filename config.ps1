Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Config = [pscustomobject]@{
    SourceDir       = 'W:\Crystal Finance'
    StagingTemp     = Join-Path $env:LOCALAPPDATA 'Temp\GemManagerPS'
    Targets    = @('X:\ArchivesCrystal', 'Y:\ArchivesCrystal', 'Z:\ArchivesCrystal')
    SevenZip        = 'C:\Program Files\7-Zip\7z.exe'
    ProtectedAdmin  = 'Administrator'
    WarnOffsetsMin  = @(10, 5, 2, 1)
    LogDir          = Join-Path $env:APPDATA 'GemManagerPS\Logs\backup_<stamp>.log'
    Retention       = @{ d = 30; w = 12; m = 12; y = 5 }
    TriggerTimes    = '01:00'
    MinFreeSpaceGB  = 60
    RobocopyArgs    = @('/R:2', '/W:5', '/MT:16', '/NP', '/NFL', '/NDL', '/XJ')
    WarningMessage  = @'
Crystal Finance backup starts at {0}. You WILL be disconnected at {0}. Please save your work now. Idle or absent users will be signed out regardless.
'@
    MutexName       = 'Global\CrystalFinanceGemManager'
    StopFileName    = 'gemmanager.stop'
    SummaryCsvName  = 'backup-summary.csv'
    StatusJsonName  = 'last-run.json'
}
