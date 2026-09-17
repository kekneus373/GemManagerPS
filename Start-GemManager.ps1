[CmdletBinding()]
param(
    [switch]$RunNow,
    [switch]$Tail,
    [int]$Lines = 30,
    [switch]$Status,
    [switch]$Stop,
    [switch]$Menu,
    [switch]$Daemon
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSCommandPath
. (Join-Path $root 'config.ps1')
Import-Module (Join-Path $root 'GemManager.psm1') -Force

function Get-GemStartupNotice {
    <# Returns a one-time operator hint when no startup shortcut is present. #>
    [CmdletBinding()]
    param()
    $startup = [Environment]::GetFolderPath('Startup')
    $shortcut = Get-ChildItem -LiteralPath $startup -Filter '*.lnk' -File | Where-Object { $_.Name -match 'GemManager|Crystal' } | Select-Object -First 1
    if ($null -eq $shortcut) {
        return "Startup shortcut not found in $startup. You may add one for auto-start, targeting powershell.exe -File `"$PSCommandPath`" -Daemon."
    }
    return $null
}

function Show-GemMenu {
    <# Runs the plain numbered, Read-Host-driven operator menu. #>
    [CmdletBinding()]
    param()
    $notice = Get-GemStartupNotice
    if ($null -ne $notice) { Write-Output $notice }
    do {
        Write-Host ''
        Write-Host '[1] Run backup now'
        Write-Host '[2] Tail last 30 log lines'
        Write-Host '[3] Stop daemon'
        Write-Host '[4] Show status'
        Write-Host '[Q] Quit'
        $choice = (Read-Host 'Select').Trim().ToUpperInvariant()
        try {
            switch ($choice) {
                '1' { Invoke-GemManager | Out-Host }
                '2' { Show-GemTail -Count 30 }
                '3' { Stop-GemManager | Out-Host }
                '4' { Show-GemStatus }
                'Q' { return }
                default { Write-Output 'Unknown selection.' }
            }
        } catch {
            Write-Output ('Operation failed: ' + $_.Exception.Message)
        }
    } while ($true)
}

function Show-GemTail {
    <# Displays the requested number of lines from the newest transcript. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$Count)
    $logDirectory = Split-Path -Parent $Config.LogDir
    $log = Get-ChildItem -LiteralPath $logDirectory -Filter 'backup_*.log' -File | Sort-Object Name -Descending | Select-Object -First 1
    if ($null -eq $log) { Write-Output 'No backup transcript exists yet.'; return }
    Get-Content -LiteralPath $log.FullName -Tail $Count
}

function Show-GemStatus {
    <# Displays last-run state and target availability without requiring every target online. #>
    [CmdletBinding()]
    param()
    $status = Get-CrystalStatus
    $status.LastRun | Format-List | Out-Host
    $status.Targets | Format-Table -AutoSize | Out-Host
    Write-Output ('Stop requested: ' + $status.StopRequested)
}

$selected = @($RunNow, $Tail, $Status, $Stop, $Menu, $Daemon | Where-Object { $_ }).Count
if ($selected -gt 1) { throw 'Choose only one action switch.' }
if ($RunNow) { Invoke-GemManager; return }
if ($Tail) { Show-GemTail -Count $Lines; return }
if ($Status) { Show-GemStatus; return }
if ($Stop) { Stop-GemManager; return }
if ($Daemon) { Invoke-GemManager -Daemon; return }
Show-GemMenu
