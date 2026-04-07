#Requires -RunAsAdministrator;

# ==============================================================================================================================================
# 'Public':
# ==============================================================================================================================================	
function New-DataCollector {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[string]$Name,
		[Parameter(Mandatory)]
		[string]$ConfigFilePath,
		[Parameter(Mandatory)]
		[int]$RetentionDays,
		[Switch]$SkipAutoStart = $false,
		[Switch]$Force = $false
	);
	
	begin {
		
	};
	
	process {
		
		if (-not (Test-Path -Path $ConfigFilePath)) {
			throw "Invalid Path or File Not Found for -ConfigFilePath value of [$ConfigFilePath].";
		}
		
		$status = Get-DataCollectorStatus $Name;
		
		if ($status -ne "<EMPTY>") {
			if (-not ($Force)) {
				throw "A Data Collector Set with the name of: [$Name] already exists. Use a different -Name or use the -Force option to overwrite.";
			}
			else {
				Write-Verbose "-Force Enabled. Data Collector Set [$Name] has a Status of: [$status].";
				Remove-DataCollector -Name $Name;
			}
		}
		
		try {
			New-LogManDataCollectorSetFromConfigFile -Name $Name -ConfigFilePath $ConfigFilePath;
			$status = Get-DataCollectorStatus -Name $Name;
			
			if ($status -notin @("running", "stopped")) {
				Write-Verbose "Failed to create Data Collector Set: [$Name]. Code executed WITHOUT any error/Exception, but collector NOT found.";
				Write-Verbose "`tAttempting to create Data Collector Set via COM.";
				
				New-ComPlaDataCollectorSetFromConfigFile -Name $Name -ConfigFilePath $ConfigFilePath;
			}
		}
		catch {
			Write-Error "Failed to create Data Collector Set via logman or COM: $_" -ErrorAction Stop;
		}
		
		if ($status -notin @("running", "stopped")) {
			throw "Failed to create. attempted via logman and via COM - with NO EXCEPTIONS but ... still not created";
		}
		
		# otherwise, the DCS exists and ... we can move on to next steps: 
		try {
			New-DataCollectorSetFileCleanupJob -Name $Name -RetentionDays $RetentionDays;
		}
		catch {
			Write-Error "Failed to create cleanup job for Data Collector Set [$Name]: $_" -ErrorAction Stop;
		}
		
		if (-not $SkipAutoStart) {
			Enable-DataCollectorSetAutoStart -Name $Name;
		}
		else {
			Write-Verbose "Skipping auto-start config.";
		}
		
		try {
			Start-DataCollector -Name $Name;
		}
		catch {
			Write-Error "Failed to start Data Collector Set [$Name]: $_" -ErrorAction Stop;
		}
	};
	
	end {
		
	};
}

function Get-DataCollectorStatus {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[string]$Name
	);
	
	try {
		# Sadly, this is total BS: https://docs.microsoft.com/en-us/powershell/scripting/whats-new/module-compatibility?view=powershell-7.1 
		#$state = Get-SMPerformanceCollector -CollectorName $Name -ErrorAction Stop;
		
		$query = logman query "$Name";
		if ($query -like "Data Collector Set was not found.") {
			return "<EMPTY>";
		}
		
		$regex = New-Object System.Text.RegularExpressions.Regex("Status:\s+(?<status>[^\r]+){1}", [System.Text.RegularExpressions.RegexOptions]::Multiline);
		$regexMatches = $regex.Match($query);
		
		$status = "<EMPTY>";
		if ($regexMatches) {
			$hack = $regexMatches.Groups[1].Value;
			Write-Verbose "Raw Status - via logman.exe: $hack";
			$status = $hack.Substring(0, $hack.IndexOf(" ")).Trim();
		}
		
		return $status;
	}
	catch {
		Write-Error "Failed to retrieve Data Collector Set status for [$Name]: $_" -ErrorAction Stop;
	}
	
	return $state;
}

function Start-DataCollector {
	param (
		[string]$Name
	);
	
	$status = Get-DataCollectorStatus -Name $Name;
	if ("Running" -ne $status) {
		$results = Invoke-Expression "logman.exe start `"$Name`"";
		if ("The command completed successfully." -ne $results) {
			throw "Error STARTING Data Collector Set [$Name]: $results";
		}
	}
}

function Remove-DataCollector {
	[CmdletBinding()]
	param (
		[string]$Name
		# TODO: add a -CleanupFiles switch? that defaults (obviously) to $false
	);
	
	$status = Get-DataCollectorStatus $Name;
	if ($status -eq "<EMPTY>") {
		Write-Verbose "A Data Collector Set with the name: [$Name] does not exist. Terminating";
		return;
	}
	
	try {
		Write-Verbose "`tAttempting to stop (if needed) + DELETE Data Collector Set: [$Name].";
		
		if ($status -eq "Running") {
			Invoke-Expression "logman.exe stop `"$Name`"" | Out-Null;
		}
		
		Invoke-Expression "logman.exe delete `"$Name`"" | Out-Null;
	}
	catch {
		Write-Error "Failed to remove (and/or STOP) Data Collector Set: [$Name]: $_" -ErrorAction Stop;
	}
	
	# TODO: arguably might have to check and see if these tasks are running, stop them, and so on... 
	try {
		# NOTE: removing the DCS typically removes the task as well - i.e., this SHOULD be $null.  
		$task = Get-ScheduledTask -TaskName $Name -TaskPath "\Microsoft\Windows\PLA\" -ErrorAction SilentlyContinue;
		if ($null -ne $task) {
			Write-Verbose "Removing Task from PLA Node within Task Scheduler.";
			
			Unregister-ScheduledTask -TaskName $Name -TaskPath "\Microsoft\Windows\PLA\" -Confirm:$false;
		}
	}
	catch {
		Write-Error "Failed to Remove Startup Task at '\Microsoft\Windows\PLA\$($Name)' within Windows Task Scheduler: $_" -ErrorAction Stop;
	}
	
	try {
		$jobName = "$Name - Cleanup Older Files";
		$task = Get-ScheduledTask -TaskName $jobName -ErrorAction SilentlyContinue;
		
		if ($null -ne $task) {
			Unregister-ScheduledTask -TaskName $jobName -Confirm:$false;
		}
	}
	catch {
		Write-Error "Failed to Remove '$Name - Older Files Cleanup' Task within Windows Task Scheduler: $_" -ErrorAction Stop;
	}
}

# ==============================================================================================================================================
# Internal:
# ==============================================================================================================================================	
filter Get-WindowsServerVersion {
	<#
			# https://en.wikipedia.org/wiki/List_of_Microsoft_Windows_versions#Server_versions
			# https://www.techthoughts.info/windows-version-numbers/

	#>	
	param (
		[System.Version]$Version = [System.Environment]::OSVersion.Version
	)
	
	if ($Version.Major -eq 10) {
		if ($Version.Build -ge 26100) {
			return "Windows2025";
		}
		if ($Version.Build -ge 20348) {
			return "Windows2022";
		}
		if ($Version.Build -ge 17763) {
			return "Windows2019";
		}
		else {
			return "Windows2016";
		}
		
		#$output = $Version.Build -ge 17763 ? "Windows2019" : "Windows2016";
	}
	
	if ($Version.Major -eq 6) {
		switch ($Version.Minor) {
			0 {
				return "Windows2008";
			}
			1 {
				return "Windows2008R2";
			}
			2 {
				return "Windows2012";
			}
			3 {
				return "Windows2012R2";
			}
			default {
				return "UNKNOWN"
			}
		}
	}
}

filter New-LogManDataCollectorSetFromConfigFile {
	param (
		[string]$Name,
		[string]$ConfigFilePath
	);
	
	try {
		Invoke-Expression "logman.exe import `"$Name`" -xml `"$ConfigFilePath`"" | Out-Null;
	}
	catch {
		Write-Error "Failed to import Data Collector Set via logman for [$Name]: $_" -ErrorAction Stop;
	}
}

filter New-ComPlaDataCollectorSetFromConfigFile {
	param (
		[string]$Name,
		[string]$ConfigFilePath
	);
	
	try {
		# Sources - via Gemini: 
		# - https://www.jonathanmedd.net/2010/11/managing-perfmon-data-collector-sets-with-powershell.html/
		# - https://github.com/Skatterbrainz/Garage/blob/master/New-DataCollectorSet.ps1
		$newDcs = New-Object -ComObject PLA.DataCollectorSet;
		$newDcs.SetXml($ConfigFilePath);
		$newDcs.Commit($Name, $null, 0x0003) | Out-Null;
		$newDcs.Start($false);
	}
	catch {
		Write-Error "Failed to create Data Collector Set via COM for [$Name] using config [$ConfigFilePath]: $_" -ErrorAction Stop;
	}
}

#filter New-SmtDataCollectorSetFromConfigFile {
#	param (
#		[string]$Name,
#		[string]$ConfigFilePath
#	);
#	
#	# Honestly. Kind of amazed at how much PowerShell sucks when it comes to BASIC windows Tasks. 
#	# There's a SeverManagerTasks module for WindowsPowershell: 
#	# 	https://learn.microsoft.com/en-us/powershell/module/servermanagertasks/?view=windowsserver2025-ps
#	
#	# which ... we COULD try to load via the following approach: 
#	# i.e., if we're in PowerShell vs Windows PowerShell, we could: 
#	Install-Module -Name WindowsCompatibility -Force;
#	Import-WinModule -Name ServerManagerTasks;
#	
#	# only... when we're all said and done? 
#	# ServerManagerTasks' cmdlets ... don't have a single method/func for CREATING a new Data Collector Set - only for state and ... extraction. 
#	# seriously. fail. 
#}

filter Enable-DataCollectorSetAutoStart {
	param (
		[Parameter(Mandatory)]
		[string]$Name
	);
	
	## assumes same convention used by Data Collector Setup - i.e., a task with the name of the data collector will be found in the \Microsoft\Windows\PLA\ folder. 
	$task = Get-ScheduledTask -TaskName $Name -TaskPath "\Microsoft\Windows\PLA\";
	$trigger = New-ScheduledTaskTrigger -AtStartup -RandomDelay 00:00:05;
	
	if ((Get-WindowsServerVersion) -in @("Windows2019", "Windows2022")) {
		## Implementation of work-around listed here: https://docs.microsoft.com/en-us/troubleshoot/windows-server/performance/user-defined-dcs-doesnt-run-as-scheduled
		$newAction = New-ScheduledTaskAction -Execute "C:\windows\system32\rundll32.exe" -Argument "C:\windows\system32\pla.dll,PlaHost `"$Name`" `"`$(Arg0)`"";
		
		Set-ScheduledTask -TaskName $Name -TaskPath "\Microsoft\Windows\PLA\" -Action $newAction -Trigger $trigger | Out-Null;
	}
	else {
		Set-ScheduledTask -TaskName $Name -TaskPath "\Microsoft\Windows\PLA\" -Trigger $trigger | Out-Null;
	}
}

filter New-DataCollectorSetFileCleanupJob {
	param (
		[Parameter(Mandatory)]
		[string]$Name,
		[Parameter(Mandatory)]
		[int]$RetentionDays
	);
	
	# TODO: verify that the cleanup func/code is present. possibly drop it (to disk/etc.) if not. 
	# 		and. lol. if I'm going to drop it to disk a) the dropped version has to be signed. so, b) i'd have to sign the version 
	# 		of the code that ...drops said script (i.e., this script would need signing of the signature).
	
	$jobName = "$Name - Cleanup Older Files";
	$task = Get-ScheduledTask -TaskName $jobName -ErrorAction SilentlyContinue;
	
	if ($task -eq $null) {
		$trigger = New-ScheduledTaskTrigger -At 2am -Daily;
		$runAsUser = "NT AUTHORITY\SYSTEM";
		$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5);
		
		$action = New-ScheduledTaskAction -Execute "Powershell.exe" -Argument "-ExecutionPolicy BYPASS -NonInteractive -NoProfile -File C:\PerfLogs\RemoveOldCollectorSetFiles.ps1 -Name $Name -RetentionDays $RetentionDays ";
		$task = Register-ScheduledTask -TaskName $jobName -Trigger $trigger -Action $action -User $runAsUser -Settings $settings -RunLevel Highest -Description "Regular cleanup of Data Collector Set files (> $RetentionDays days old) for `"$Name`" Data Collecctor.";
	}
}