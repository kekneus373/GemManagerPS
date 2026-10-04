Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleRoot = Split-Path -Parent $PSCommandPath
. (Join-Path $script:ModuleRoot 'config.ps1')
$script:LogPath = $null
$script:LastRun = $null

#region Logging & Primitives
function Write-GemLog {
	<# Writes a timestamped line to the active run transcript. #>
	[CmdletBinding()]
	param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Message = '<No message provided>',
        
        [ValidateSet('INFO','WARN','ERROR','CRITICAL')]
        [string]$Level = 'INFO'
    )
	
	$line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
	if ($null -ne $script:LogPath) {
		Add-Content -LiteralPath $script:LogPath -Value $line
	}
}

function Get-GemLogDirectory {
	<# Returns the configured log directory. #>
	[CmdletBinding()]
	param()
	return (Split-Path -Parent $Config.LogDir)
}

function Assert-GemConfiguration {
	<# Validates required paths and rejects unsafe target roots. #>
	[CmdletBinding()]
	param()
	$pathValues = @($Config.SourceDir, $Config.StagingTemp, $Config.SevenZip) + @($Config.Targets)
	foreach ($pathValue in $pathValues) {
		if ([string]::IsNullOrWhiteSpace([string]$pathValue) -or -not [System.IO.Path]::IsPathRooted([string]$pathValue)) {
			throw "Configuration path is not absolute and non-empty: '$pathValue'."
		}
	}
	if (-not (Test-Path -LiteralPath $Config.SourceDir -PathType Container)) {
		throw "SourceDir is missing or inaccessible: $($Config.SourceDir)"
	}
	if (-not (Test-Path -LiteralPath $Config.SevenZip -PathType Leaf)) {
		throw "SevenZip is missing: $($Config.SevenZip)"
	}
	foreach ($target in @($Config.Targets)) {
		$root = [System.IO.Path]::GetPathRoot($target).TrimEnd('\')
		if ($target.TrimEnd('\') -eq $root) {
			throw "A drive root is not a valid archive target: $target"
		}
	}
	if ($Config.WarnOffsetsMin.Count -ne 4) {
		throw 'WarnOffsetsMin must contain exactly four offsets.'
	}
}

function Initialize-GemRun {
	<# Creates the run transcript directory and initializes status paths. #>
	[CmdletBinding()]
	param()
	$directory = Get-GemLogDirectory
	if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
		New-Item -ItemType Directory -Path $directory -Force | Out-Null
	}
	$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
	$script:LogPath = Join-Path $directory ('backup_{0}.log' -f $stamp)
	New-Item -ItemType File -Path $script:LogPath -Force | Out-Null
	Write-GemLog -Message 'Run initialized.'
}

function Invoke-GemExternal {
	<# Executes an external program, logs all output, and returns its exit code. #>
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)][string]$FilePath,
		  [Parameter(Mandatory = $true)][string[]]$ArgumentList)
	Write-GemLog -Message ('EXEC {0} {1}' -f $FilePath, ($ArgumentList -join ' '))
	$previousErrorActionPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = 'Continue'
		$output = @(& $FilePath @ArgumentList 2>&1)
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $previousErrorActionPreference
	}
	foreach ($line in $output) { Write-GemLog -Message ('  ' + [string]$line) }
	Write-GemLog -Message ('EXIT {0}: {1}' -f $exitCode, $FilePath)
	return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Get-GemStatusPath {
	<# Returns the machine-readable status JSON path. #>
	[CmdletBinding()]
	param()
	return (Join-Path (Get-GemLogDirectory) $Config.StatusJsonName)
}

function Set-GemStatus {
	<# Writes the current run state as JSON for the TUI and operators. #>
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)][hashtable]$Status)
	$directory = Get-GemLogDirectory
	if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
		New-Item -ItemType Directory -Path $directory -Force | Out-Null
	}
	$Status | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Get-GemStatusPath)
}

function Get-GemLastStatus {
	<# Reads the last machine-readable run state, if available. #>
	[CmdletBinding()]
	param()
	$path = Get-GemStatusPath
	if (Test-Path -LiteralPath $path -PathType Leaf) {
		return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
	}
	return $null
}

function Get-GemMutex {
	<# Creates the named process mutex used to serialize backup runs. #>
	[CmdletBinding()]
	param()
	return (New-Object System.Threading.Mutex($false, $Config.MutexName))
}

function Test-GemStopRequested {
	<# Checks the daemon stop request marker. #>
	[CmdletBinding()]
	param()
	return (Test-Path -LiteralPath (Join-Path (Get-GemLogDirectory) $Config.StopFileName))
}

function Clear-GemStopRequest {
	<# Removes a previously handled daemon stop request. #>
	[CmdletBinding()]
	param()
	$path = Join-Path (Get-GemLogDirectory) $Config.StopFileName
	if (Test-Path -LiteralPath $path -PathType Leaf) {
		Write-GemLog -Message ('DELETE handled daemon stop request target: ' + $path)
		Remove-Item -LiteralPath $path -Force
	}
}

function Get-GemNextTrigger {
	<# Computes the next configured daily trigger time. #>
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)][datetime]$Now)
	$parts = $Config.TriggerTimes.Split(':')
	$candidate = Get-Date -Year $Now.Year -Month $Now.Month -Day $Now.Day -Hour ([int]$parts[0]) -Minute ([int]$parts[1]) -Second 0
	if ($candidate -le $Now) { $candidate = $candidate.AddDays(1) }
	return $candidate
}

#endregion
#region RDP Drain & Lockdown
function Get-GemUserSessions {
	<# Enumerates query-user sessions into typed session records. #>
	[CmdletBinding()]
	param()
	$result = Invoke-GemExternal -FilePath 'query.exe' -ArgumentList @('user')
	$sessions = @()
	foreach ($lineObject in $result.Output) {
		$line = ([string]$lineObject).TrimEnd()
		if ($line -match '^\s*(?:>\s*)?(\S+)\s+(\S+)\s+(\d+)\s+(\S+)') {
			$sessions += [pscustomobject]@{ SessionName = $matches[2]; Username = $matches[1]; Id = [int]$matches[3]; State = $matches[4] }
		} elseif ($line -match '^\s*(?:>\s*)?(\S+)\s+(\d+)\s+(\S+)') {
			$sessions += [pscustomobject]@{ SessionName = ''; Username = $matches[1]; Id = [int]$matches[2]; State = $matches[3] }
		}
	}
	return @($sessions | Where-Object { $_.Id -ne 0 -and $_.SessionName -ne 'console' -and $_.Username -ne $Config.ProtectedAdmin })
}

function Test-GemChangeLogonState {
	<# Checks the change-logon output for its effective state, falling back to exit code. #>
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)][pscustomobject]$Result,
		  [Parameter(Mandatory = $true)][ValidateSet('ENABLED', 'DISABLED')][string]$ExpectedState)
	$outputText = [string]::Join("`n", @($Result.Output | ForEach-Object { [string]$_ }))
	$stateMatch = [regex]::Match($outputText, '(?im)Session logins are currently\s+(ENABLED|DISABLED)')
	if ($stateMatch.Success) { return ($stateMatch.Groups[1].Value -eq $ExpectedState) }
	return ($Result.ExitCode -eq 0)
}

function Restore-GemRdp {
	<# Idempotently re-enables new RDP logons. #>
	[CmdletBinding()]
	param()
	try {
		Write-GemLog -Message 'RESTORE target RDP logon state: change logon /enable.'
		$restore = Invoke-GemExternal -FilePath 'change.exe' -ArgumentList @('logon', '/enable')
		if (Test-GemChangeLogonState -Result $restore -ExpectedState 'ENABLED') {
			Write-GemLog -Message 'RDP logon state confirmed ENABLED.'
		} else {
			Write-GemLog -Level CRITICAL -Message ('RDP restore did not confirm ENABLED; exit code {0}.' -f $restore.ExitCode)
		}
	} catch {
		Write-GemLog -Level CRITICAL -Message ('RDP restore failed: ' + $_.Exception.Message)
	}
}

function Send-GemWarning {
	<# Sends one expiring warning to every eligible session by session ID. #>
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)][object[]]$Sessions,
		  [Parameter(Mandatory = $true)][datetime]$DisconnectAt,
		  [Parameter(Mandatory = $true)][int]$TimeSeconds)
	$text = $Config.WarningMessage -f $DisconnectAt.ToString('HH:mm')
	foreach ($session in $Sessions) {
		Write-GemLog -Message ('NOTIFY session {0}: {1}' -f $session.Id, $text.Replace("`r`n", ' '))
		$notify = Invoke-GemExternal -FilePath 'msg.exe' -ArgumentList @([string]$session.Id, ('/TIME:{0}' -f $TimeSeconds), $text)
		if ($notify.ExitCode -ge 1) { Write-GemLog -Level WARN -Message ('Notification failed for session ' + $session.Id) }
	}
}

function Invoke-GemRdpDrain {
	<# Drains eligible users, verifies logoff, and disables new RDP logons. #>
	[CmdletBinding()]
	param()
	$disconnectAt = (Get-Date).AddMinutes([double]($Config.WarnOffsetsMin | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum))
	$warningOffsets = @($Config.WarnOffsetsMin | Sort-Object -Descending)
	foreach ($offset in $warningOffsets) {
		$warningAt = $disconnectAt.AddMinutes(-1 * [double]$offset)
		while ((Get-Date) -lt $warningAt) {
			if (@(Get-GemUserSessions).Count -eq 0) { break }
			$sleepSeconds = [Math]::Min(15, [int][Math]::Ceiling(($warningAt - (Get-Date)).TotalSeconds))
			if ($sleepSeconds -gt 0) { Start-Sleep -Seconds $sleepSeconds }
		}
		$sessions = @(Get-GemUserSessions)
		if ($sessions.Count -eq 0) { Write-GemLog -Message 'All non-admin RDP sessions have left; skipping remaining waits.'; break }
		if ((Get-Date) -ge $warningAt) {
			Send-GemWarning -Sessions $sessions -DisconnectAt $disconnectAt -TimeSeconds ([int][Math]::Ceiling(($disconnectAt - (Get-Date)).TotalSeconds))
		}
	}
	while ((Get-Date) -lt $disconnectAt) {
		if (@(Get-GemUserSessions).Count -eq 0) { break }
		$sleepSeconds = [Math]::Min(15, [int][Math]::Ceiling(($disconnectAt - (Get-Date)).TotalSeconds))
		if ($sleepSeconds -gt 0) { Start-Sleep -Seconds $sleepSeconds }
	}
	$remainingSessions = @(Get-GemUserSessions)
	foreach ($session in $remainingSessions) {
		Write-GemLog -Message ('LOGOFF target session {0} ({1}).' -f $session.Id, $session.Username)
		Invoke-GemExternal -FilePath 'logoff.exe' -ArgumentList @([string]$session.Id) | Out-Null
	}
	for ($attempt = 1; $attempt -le 3; $attempt++) {
		if (@(Get-GemUserSessions).Count -eq 0) { break }
		if ($attempt -lt 3) { Start-Sleep -Seconds 15 }
	}
	if (@(Get-GemUserSessions).Count -gt 0) {
		throw 'RDP drain failed: non-admin sessions remain after three verification attempts.'
	}
	Write-GemLog -Message 'LOCKDOWN target: new RDP logons via change logon /disable.'
	$disable = Invoke-GemExternal -FilePath 'change.exe' -ArgumentList @('logon', '/disable')
	if (-not (Test-GemChangeLogonState -Result $disable -ExpectedState 'DISABLED')) {
		throw ('Could not confirm RDP logons disabled; change.exe exit code {0}.' -f $disable.ExitCode)
	}
}

#endregion
#region Archive & Verify
function Get-GemArchivePath {
	<# Returns the deterministic archive path for the current day and minute. #>
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)][datetime]$When)
	return (Join-Path $Config.StagingTemp ('crystal_{0}.7z' -f $When.ToString('yyyyMMdd_HHmm')))
}

function Get-GemLastArchiveSize {
	<# Finds the newest staged archive size for free-space forecasting. #>
	[CmdletBinding()]
	param()
	$archives = @(Get-ChildItem -LiteralPath $Config.StagingTemp -Filter 'crystal_*.7z' -File)
	if ($archives.Count -eq 0) { return [int64]0 }
	return [int64]($archives | Sort-Object Name -Descending | Select-Object -First 1).Length
}

function Invoke-GemArchive {
	<# Creates or reuses the deterministic staged archive and verifies it with 7-Zip. #>
	[CmdletBinding()]
	param()
	if (-not (Test-Path -LiteralPath $Config.StagingTemp -PathType Container)) {
		New-Item -ItemType Directory -Path $Config.StagingTemp -Force | Out-Null
	}
	$lastSize = Get-GemLastArchiveSize
	$free = (Get-Item -LiteralPath $Config.StagingTemp).PSDrive.Free
	if ($lastSize -gt 0 -and $free -lt [int64]($lastSize * 1.2)) { Write-GemLog -Level WARN -Message 'Staging free space is below 1.2 times the last archive size.' }
	$archive = Get-GemArchivePath -When (Get-Date)
	$createdNewArchive = $false
	if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
		$sameDay = @(Get-ChildItem -LiteralPath $Config.StagingTemp -Filter ('crystal_{0}_*.7z' -f (Get-Date -Format 'yyyyMMdd')) -File | Sort-Object Name -Descending)
		if ($sameDay.Count -gt 0) { $archive = $sameDay[0].FullName }
	}
	if (Test-Path -LiteralPath $archive -PathType Leaf) {
		Write-GemLog -Message ('Existing archive found; skipping compression: ' + $archive)
	} else {
		$archiveArgs = @($Config.SevenZipCreateArgs) + @($archive, (Join-Path $Config.SourceDir '*'))
		$created = Invoke-GemExternal -FilePath $Config.SevenZip -ArgumentList $archiveArgs
		if ($created.ExitCode -ne 0) { throw '7-Zip archive creation failed.' }
		$createdNewArchive = $true
	}
	$verified = Invoke-GemExternal -FilePath $Config.SevenZip -ArgumentList (@($Config.SevenZipTestArgs) + @($archive))
	if ($verified.ExitCode -ne 0) {
		Write-GemLog -Level WARN -Message "Archive verification failed ($archive). Removing corrupted file..."
		Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
		throw '7-Zip verification failed; corrupted archive was removed.'
	}
	if ($createdNewArchive) {
		$staleArchives = @(Get-ChildItem -LiteralPath $Config.StagingTemp -Filter 'crystal_*.7z' -File | Where-Object { $_.FullName -ne $archive })
		foreach ($staleArchive in $staleArchives) {
			Write-GemLog -Message ('DELETE stale staging archive target: ' + $staleArchive.FullName)
			Remove-Item -LiteralPath $staleArchive.FullName -Force
		}
	}
	return (Get-Item -LiteralPath $archive)
}

#endregion
#region Transport (robocopy)
function Test-GemDestination {
	<# Validates destination reachability, writability, and free space. #>
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)][string]$Path,
		  [Parameter(Mandatory = $true)][int64]$RequiredBytes)
	if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Write-GemLog -Level WARN -Message ('Destination unavailable: ' + $Path); return $false }
	$probe = Join-Path $Path ('.gemmanager_probe_{0}.tmp' -f ([guid]::NewGuid().ToString('N')))
	Write-GemLog -Message ('CREATE probe target: ' + $probe)
	New-Item -ItemType File -Path $probe -Force | Out-Null
	Write-GemLog -Message ('DELETE probe target: ' + $probe)
	Remove-Item -LiteralPath $probe -Force
	$free = (Get-Item -LiteralPath $Path).PSDrive.Free
	if ($free -lt $RequiredBytes) { Write-GemLog -Level WARN -Message ('Insufficient free space at ' + $Path); return $false }
	return $true
}

function Invoke-GemRobocopy {
	<# Copies one named archive with robocopy and accepts bitmask codes zero through seven. #>
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)][string]$Source,
		  [Parameter(Mandatory = $true)][string]$Destination,
		  [Parameter(Mandatory = $true)][string]$FileName)
	$arguments = @($Source, $Destination, $FileName) + @($Config.RobocopyArgs)
	$result = Invoke-GemExternal -FilePath 'robocopy.exe' -ArgumentList $arguments
	if ($result.ExitCode -ge 8) { throw ('Robocopy failed ({0}) for {1}' -f $result.ExitCode, $Destination) }
	return $result.ExitCode
}

function Invoke-GemTransport {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)][System.IO.FileInfo]$Archive)
	$year = $Archive.Name.Substring(8, 4)
	$required = [int64]($Archive.Length + ($Config.MinFreeSpaceGB * 1GB))
	$results = @()
	foreach ($targetRoot in @($Config.Targets)) {
		try {
			$target = Join-Path $targetRoot $year
			if (-not (Test-Path -LiteralPath $target -PathType Container) -and (Test-Path -LiteralPath $targetRoot -PathType Container)) {
				New-Item -ItemType Directory -Path $target -Force | Out-Null
			}
			if (-not (Test-GemDestination -Path $target -RequiredBytes $required)) {
				throw ('Destination unavailable or insufficient space: ' + $target)
			}
			$code = Invoke-GemRobocopy -Source $Archive.DirectoryName -Destination $target -FileName $Archive.Name
			$results += [pscustomobject]@{ Target = $targetRoot; OK = $true; ExitCode = $code; Error = $null }
		} catch {
			Write-GemLog -Level WARN -Message ('Destination failed; continuing to next target: {0}; {1}' -f $targetRoot, $_.Exception.Message)
			$results += [pscustomobject]@{ Target = $targetRoot; OK = $false; ExitCode = 16; Error = $_.Exception.Message }
		}
	}
	$successfulTargets = @($results | Where-Object { $_.OK })
	if ($successfulTargets.Count -eq 0) { throw 'Archive transport failed for every configured destination.' }
	$partial = @($results | Where-Object { -not $_.OK }).Count -gt 0
	return [pscustomobject]@{ Local = $results; Partial = $partial; Year = $year }
}

#endregion
#region Retention (GFS prune)
function Get-GemArchiveDate {
	<# Parses an archive date from its filename, never from filesystem timestamps. #>
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)][string]$Name)
	if ($Name -match '^crystal_(\d{8})_(\d{4})\.7z$') { return [datetime]::ParseExact(($matches[1] + $matches[2]), 'yyyyMMddHHmm', $null) }
	return $null
}

function Get-GemIsoWeekKey {
	<# Returns an ISO-like year/week key using .NET Framework-compatible arithmetic. #>
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)][datetime]$Date)
	$thursday = $Date.AddDays(4 - [int]$Date.DayOfWeek)
	$firstThursday = (Get-Date -Year $thursday.Year -Month 1 -Day 4).Date
	$week = [int](1 + [Math]::Floor((($thursday.Date - $firstThursday).TotalDays) / 7))
	return '{0:D4}-{1:D2}' -f $thursday.Year, $week
}

function Remove-CrystalArchive {
	<# Prunes archives using the union of daily, weekly, monthly, and yearly survivors. #>
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	param([Parameter(Mandatory = $true)][string]$TargetRoot)
	$files = @(Get-ChildItem -LiteralPath $TargetRoot -Recurse -Filter 'crystal_*.7z' -File)
	$dated = @($files | ForEach-Object { $date = Get-GemArchiveDate -Name $_.Name; if ($null -ne $date) { [pscustomobject]@{ File = $_; Date = $date } } })
	$keep = @{}
	foreach ($item in @($dated | Sort-Object Date -Descending | Select-Object -First $Config.Retention.d)) { $keep[$item.File.FullName] = $true }
	$weekly = @(
		$dated |
		Group-Object { Get-GemIsoWeekKey -Date $_.Date } |
		ForEach-Object { $_.Group | Sort-Object Date -Descending | Select-Object -First 1 } |
		Sort-Object Date -Descending |
		Select-Object -First $Config.Retention.w
	)
	foreach ($item in $weekly) { if (-not $keep.ContainsKey($item.File.FullName)) { $keep[$item.File.FullName] = $true } }
	$monthly = @($dated | Group-Object { '{0:yyyy-MM}' -f $_.Date } | ForEach-Object {
		$monthDate = $_.Group[0].Date
		$firstDay = Get-Date -Year $monthDate.Year -Month $monthDate.Month -Day 1
		$daysToSunday = (7 - [int]$firstDay.DayOfWeek) % 7
		$firstSunday = $firstDay.AddDays($daysToSunday)
		$_.Group | Sort-Object { [Math]::Abs(($_.Date - $firstSunday).TotalSeconds) } | Select-Object -First 1
	})
	foreach ($item in @($monthly | Sort-Object Date -Descending | Select-Object -First $Config.Retention.m)) { $keep[$item.File.FullName] = $true }
	foreach ($item in @($dated | Group-Object { $_.Date.Year } | Sort-Object Name -Descending | Select-Object -First $Config.Retention.y)) { $newest = $item.Group | Sort-Object Date -Descending | Select-Object -First 1; $keep[$newest.File.FullName] = $true }
	$delete = @($dated | Where-Object { -not $keep.ContainsKey($_.File.FullName) })
	$bytes = [int64]0
	foreach ($item in $delete) { $bytes += $item.File.Length }
	Write-GemLog -Message ('RETENTION target {0}: retained={1}, deleted={2}, bytes-reclaimed={3}' -f $TargetRoot, $keep.Count, $delete.Count, $bytes)
	if ($delete.Count -gt 0) {
		$delete | Select-Object @{n='Path';e={$_.File.FullName}}, @{n='Bytes';e={$_.File.Length}} | Format-Table -AutoSize | Out-String | ForEach-Object { Write-GemLog -Message $_.TrimEnd() }
	} else {
		Write-GemLog -Message 'Retention has no archives eligible for deletion.'
	}
	foreach ($item in $delete) {
		if ($PSCmdlet.ShouldProcess($item.File.FullName, 'Delete expired Crystal archive')) {
			Write-GemLog -Message ('DELETE archive target: ' + $item.File.FullName)
			Remove-Item -LiteralPath $item.File.FullName -Force
		}
	}
}

#endregion
#region Public orchestration
function Invoke-GemManager {
	<# Runs one serialized Crystal Finance backup with guaranteed RDP restoration. #>
	[CmdletBinding()]
	param([switch]$Daemon)
	if ($Daemon) {
		Assert-GemConfiguration
		Initialize-GemRun
		Clear-GemStopRequest
		while (-not (Test-GemStopRequested)) {
			. (Join-Path $script:ModuleRoot 'config.ps1')
			$next = Get-GemNextTrigger -Now (Get-Date)
			Write-GemLog -Message ('HEARTBEAT daemon tick; next run ' + $next.ToString('o'))
			while ((Get-Date) -lt $next -and -not (Test-GemStopRequested)) {
				Start-Sleep -Seconds 60
				$next = Get-GemNextTrigger -Now (Get-Date)
			}
			if (-not (Test-GemStopRequested)) { Invoke-GemManager | Out-Null }
		}
		return 'STOPPED'
	}
	Assert-GemConfiguration
	Initialize-GemRun
	$mutex = Get-GemMutex
	$acquired = $false
	$started = Get-Date
	try {
		$acquired = $mutex.WaitOne(0)
		if (-not $acquired) { Write-GemLog -Level WARN -Message 'Another backup run is already active.'; return }
		trap { Write-GemLog -Level CRITICAL -Message ('Unhandled backup error: ' + $_.Exception.Message); Restore-GemRdp; throw }
		Set-GemStatus -Status @{ Result = 'RUNNING'; Started = $started.ToString('o'); Archive = $null }
		Invoke-GemRdpDrain
		$archive = Invoke-GemArchive
		$transport = Invoke-GemTransport -Archive $archive
		foreach ($targetResult in @($transport.Local | Where-Object { $_.OK })) {
			try {
				Remove-CrystalArchive -TargetRoot (Join-Path $targetResult.Target $transport.Year) -Confirm:$false
			} catch {
				Write-GemLog -Level WARN -Message ('Retention failed at {0}: {1}' -f $targetResult.Target, $_.Exception.Message)
				$targetResult.OK = $false
				$targetResult.Error = 'Retention failed: ' + $_.Exception.Message
			}
		}
		$transport.Partial = $transport.Partial -or (@($transport.Local | Where-Object { -not $_.OK }).Count -gt 0)
		$result = 'SUCCESS'
		if ($transport.Partial) { $result = 'PARTIAL' }
		$duration = ((Get-Date) - $started).TotalSeconds
		$targetStatus = ($transport.Local | ForEach-Object { '{0}:{1}' -f $_.Target, $(if ($_.OK) { 'OK' } else { 'FAIL' }) }) -join ';'
		$exitCode = 0
		if ($transport.Partial) { $exitCode = 2 }
		$summary = '{0},{1},{2},{3},{4},{5},{6}' -f $started.ToString('o'), $duration, $archive.Name, $archive.Length, $targetStatus, $result, $exitCode
		$csv = Join-Path (Get-GemLogDirectory) $Config.SummaryCsvName
		if (-not (Test-Path -LiteralPath $csv)) { Add-Content -LiteralPath $csv -Value 'Timestamp,DurationSeconds,Archive,SizeBytes,Targets,Result,ExitCode' }
		Add-Content -LiteralPath $csv -Value $summary
		Set-GemStatus -Status @{ Result = $result; Started = $started.ToString('o'); Finished = (Get-Date).ToString('o'); Archive = $archive.Name; SizeBytes = $archive.Length; Targets = $transport.Local; NextRun = (Get-GemNextTrigger -Now (Get-Date)).ToString('o') }
		Write-GemLog -Message ('Backup completed: ' + $result)
		return $result
	} catch {
		$duration = ((Get-Date) - $started).TotalSeconds
		Write-GemLog -Level CRITICAL -Message ('Backup aborted: ' + $_.Exception.Message)
		Set-GemStatus -Status @{ Result = 'FAILED'; Started = $started.ToString('o'); Finished = (Get-Date).ToString('o'); Error = $_.Exception.Message; DurationSeconds = $duration }
		throw
	} finally {
		Restore-GemRdp
		if ($acquired) { $mutex.ReleaseMutex() }
		$mutex.Dispose()
	}
}

function Get-CrystalStatus {
	<# Returns last-run status and live destination health information. #>
	[CmdletBinding()]
	param()
	$last = Get-GemLastStatus
	$targets = @($Config.Targets) | ForEach-Object { [pscustomobject]@{ Path = $_; Available = (Test-Path -LiteralPath $_ -PathType Container) } }
	return [pscustomobject]@{ LastRun = $last; Targets = $targets; NextRun = (Get-GemNextTrigger -Now (Get-Date)); StopRequested = (Test-GemStopRequested) }
}

function Stop-GemManager {
	<# Requests a running daemon to stop at its next safe loop boundary. #>
	[CmdletBinding()]
	param()
	$directory = Get-GemLogDirectory
	if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
	$stopPath = Join-Path $directory $Config.StopFileName
	Write-GemLog -Message ('CREATE daemon stop request target: ' + $stopPath)
	New-Item -ItemType File -Path $stopPath -Force | Out-Null
	return $true
}

Export-ModuleMember -Function Invoke-GemManager, Get-CrystalStatus, Stop-GemManager, Remove-CrystalArchive