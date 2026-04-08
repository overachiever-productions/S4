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
			Write-Host "Invalid Path or File Not Found for -ConfigFilePath value of [$ConfigFilePath]." -ForegroundColor Red;
			return;
		}
		
		$status = Get-DataCollectorStatus $Name;
		
		if ($status -ne "<EMPTY>") {
			if (-not ($Force)) {
				Write-Host "A Data Collector Set with the name of: [$Name] already exists. Use a different -Name or use the -Force option to overwrite." -ForegroundColor Red;
				return;
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
			throw "Failed to create Data Collector Set. Attempted both logman and COM creation methods. No Exceptions - but Data Collector NOT created.";
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

function Stop-DataCollector {
	param (
		[string]$Name
	);
	
	$status = Get-DataCollectorStatus -Name $Name;
	if ("Running" -ne $status) {
		$results = Invoke-Expression "logman.exe stop `"$Name`"";
		if ("The command completed successfully." -ne $results) {
			throw "Error STOPPING Data Collector Set [$Name]: $results";
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
	
	$trigger = New-ScheduledTaskTrigger -AtStartup -RandomDelay 00:00:04;
	
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
	
	# variable as ... I may end up changing this and ... need to pass it into other funcs/etc.,
	$removeOlderCollectorFilesPath = 'C:\PerfLogs\RemoveOldCollectorSetFiles.ps1';
	
	if (-not (Test-Path -Path $removeOlderCollectorFilesPath)) {
		Write-Verbose "dumping xxx to disk at path: $removeOlderCollectorFilesPath";
		
		try {
			Write-RemoveOldCollectorSetFilesScriptToDisk -Path $removeOlderCollectorFilesPath;
		}
		catch {
			Write-Error "Failed to Write RemoveOldCollectorSetFiles.ps1 to $($removeOlderCollectorFilesPath): $_" -ErrorAction Stop;
		}
	}
	
	$jobName = "$Name - Cleanup Older Files";
	$task = Get-ScheduledTask -TaskName $jobName -ErrorAction SilentlyContinue;
	
	if ($null -eq $task) {
		$trigger = New-ScheduledTaskTrigger -At 2am -Daily;
		$runAsUser = "NT AUTHORITY\SYSTEM";
		$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5);
		
		$action = New-ScheduledTaskAction -Execute "Powershell.exe" -Argument "-ExecutionPolicy BYPASS -NonInteractive -NoProfile -File C:\PerfLogs\RemoveOldCollectorSetFiles.ps1 -Name $Name -RetentionDays $RetentionDays ";
		$task = Register-ScheduledTask -TaskName $jobName -Trigger $trigger -Action $action -User $runAsUser -Settings $settings -RunLevel Highest -Description "Regular cleanup of Data Collector Set files (> $RetentionDays days old) for `"$Name`" Data Collecctor.";
	}
}

filter Write-RemoveOldCollectorSetFilesScriptToDisk {
	param (
		[Parameter(Mandatory)]
		[string]$Path	
	);
	
	$nestedFile = @'
Set-StrictMode -Version 1.0;

function Remove-OldDataCollectorFiles {
	param (
		[Parameter(Mandatory)]
		[string]$DataCollectorName,
		[int]$DaysWorthOfLogsToKeep = 45,
		[string]$RootFilePath = "C:\PerfLogs\"
	);
	
	$threshold = (Get-Date).AddDays(0 - $DaysWorthOfLogsToKeep);
	$directory = Join-Path -Path $RootFilePath -ChildPath $DataCollectorName;
	
	Get-ChildItem $directory | Where-Object CreationTime -lt $threshold | Remove-Item -Force;
}
'@
	
	if (($PSVersionTable).PSVersion.Major -ne 5) {
		Set-Content -Path $Path -Value $nestedFile -Encoding UTF8BOM;
	}
	else {
		Set-Content -Path $Path -Value $nestedFile;
	}
}

# SIG # Begin signature block
# MIIqlAYJKoZIhvcNAQcCoIIqhTCCKoECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAgmk4OifhTE6dl
# VTiVi2Ujyip5Tffc0wijwlY/74cWHaCCJQ4wggWDMIIDa6ADAgECAg5F5rsDgzPD
# hWVI5v9FUTANBgkqhkiG9w0BAQwFADBMMSAwHgYDVQQLExdHbG9iYWxTaWduIFJv
# b3QgQ0EgLSBSNjETMBEGA1UEChMKR2xvYmFsU2lnbjETMBEGA1UEAxMKR2xvYmFs
# U2lnbjAeFw0xNDEyMTAwMDAwMDBaFw0zNDEyMTAwMDAwMDBaMEwxIDAeBgNVBAsT
# F0dsb2JhbFNpZ24gUm9vdCBDQSAtIFI2MRMwEQYDVQQKEwpHbG9iYWxTaWduMRMw
# EQYDVQQDEwpHbG9iYWxTaWduMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKC
# AgEAlQfoc8pm+ewUyns89w0I8bRFCyyCtEjG61s8roO4QZIzFKRvf+kqzMawiGvF
# tonRxrL/FM5RFCHsSt0bWsbWh+5NOhUG7WRmC5KAykTec5RO86eJf094YwjIElBt
# QmYvTbl5KE1SGooagLcZgQ5+xIq8ZEwhHENo1z08isWyZtWQmrcxBsW+4m0yBqYe
# +bnrqqO4v76CY1DQ8BiJ3+QPefXqoh8q0nAue+e8k7ttU+JIfIwQBzj/ZrJ3YX7g
# 6ow8qrSk9vOVShIHbf2MsonP0KBhd8hYdLDUIzr3XTrKotudCd5dRC2Q8YHNV5L6
# frxQBGM032uTGL5rNrI55KwkNrfw77YcE1eTtt6y+OKFt3OiuDWqRfLgnTahb1SK
# 8XJWbi6IxVFCRBWU7qPFOJabTk5aC0fzBjZJdzC8cTflpuwhCHX85mEWP3fV2ZGX
# hAps1AJNdMAU7f05+4PyXhShBLAL6f7uj+FuC7IIs2FmCWqxBjplllnA8DX9ydoo
# jRoRh3CBCqiadR2eOoYFAJ7bgNYl+dwFnidZTHY5W+r5paHYgw/R/98wEfmFzzNI
# 9cptZBQselhP00sIScWVZBpjDnk99bOMylitnEJFeW4OhxlcVLFltr+Mm9wT6Q1v
# uC7cZ27JixG1hBSKABlwg3mRl5HUGie/Nx4yB9gUYzwoTK8CAwEAAaNjMGEwDgYD
# VR0PAQH/BAQDAgEGMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFK5sBaOTE+Ki
# 5+LXHNbH8H/IZ1OgMB8GA1UdIwQYMBaAFK5sBaOTE+Ki5+LXHNbH8H/IZ1OgMA0G
# CSqGSIb3DQEBDAUAA4ICAQCDJe3o0f2VUs2ewASgkWnmXNCE3tytok/oR3jWZZip
# W6g8h3wCitFutxZz5l/AVJjVdL7BzeIRka0jGD3d4XJElrSVXsB7jpl4FkMTVlez
# orM7tXfcQHKso+ubNT6xCCGh58RDN3kyvrXnnCxMvEMpmY4w06wh4OMd+tgHM3ZU
# ACIquU0gLnBo2uVT/INc053y/0QMRGby0uO9RgAabQK6JV2NoTFR3VRGHE3bmZbv
# GhwEXKYV73jgef5d2z6qTFX9mhWpb+Gm+99wMOnD7kJG7cKTBYn6fWN7P9BxgXwA
# 6JiuDng0wyX7rwqfIGvdOxOPEoziQRpIenOgd2nHtlx/gsge/lgbKCuobK1ebcAF
# 0nu364D+JTf+AptorEJdw+71zNzwUHXSNmmc5nsE324GabbeCglIWYfrexRgemSq
# aUPvkcdM7BjdbO9TLYyZ4V7ycj7PVMi9Z+ykD0xF/9O5MCMHTI8Qv4aW2ZlatJlX
# HKTMuxWJU7osBQ/kxJ4ZsRg01Uyduu33H68klQR4qAO77oHl2l98i0qhkHQlp7M+
# S8gsVr3HyO844lyS8Hn3nIS6dC1hASB+ftHyTwdZX4stQ1LrRgyU4fVmR3l31VRb
# H60kN8tFWk6gREjI2LCZxRWECfbWSUnAZbjmGnFuoKjxguhFPmzWAtcKZ4MFWsmk
# EDCCBeEwggPJoAMCAQICEHnDaVGKA+cX41fLJ4FUPvkwDQYJKoZIhvcNAQELBQAw
# ezELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9u
# MREwDwYDVQQKDAhTU0wgQ29ycDE3MDUGA1UEAwwuU1NMLmNvbSBFViBDb2RlIFNp
# Z25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBSMzAeFw0yNDEyMTkwNTMzMDFaFw0y
# NzA3MjIxODA3NDZaMIHtMQswCQYDVQQGEwJVUzETMBEGA1UECAwKV2FzaGluZ3Rv
# bjEQMA4GA1UEBwwHU3Bva2FuZTEnMCUGA1UECgweT3ZlckFjaGlldmVyIFByb2R1
# Y3Rpb25zLCBMTEMuMRQwEgYDVQQFEws2MDMgMDMxIDEzMjEnMCUGA1UEAwweT3Zl
# ckFjaGlldmVyIFByb2R1Y3Rpb25zLCBMTEMuMR0wGwYDVQQPDBRQcml2YXRlIE9y
# Z2FuaXphdGlvbjEbMBkGCysGAQQBgjc8AgECDApXYXNoaW5ndG9uMRMwEQYLKwYB
# BAGCNzwCAQMTAlVTMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERpPaIcvHYfuqW6GO
# 5FA3htIGsQN00WlsqfjNgmXVBOxI9AZdUyld+a47fRBcTwGP3skosxwcST3R6phy
# Guk4LE7fnKFJMXdXMqn++NOoNae1Mi2FOkkfAlO1wGEc9lGBo4IBmjCCAZYwDAYD
# VR0TAQH/BAIwADAfBgNVHSMEGDAWgBQ2vUn/MSzrr2pA/pnAFu26/EjdXzB9Bggr
# BgEFBQcBAQRxMG8wSwYIKwYBBQUHMAKGP2h0dHA6Ly9jZXJ0LnNzbC5jb20vU1NM
# Y29tLVN1YkNBLUVWLUNvZGVTaWduaW5nLVJTQS00MDk2LVIzLmNlcjAgBggrBgEF
# BQcwAYYUaHR0cDovL29jc3BzLnNzbC5jb20wUAYDVR0gBEkwRzAHBgVngQwBAzA8
# BgwrBgEEAYKpMAEDAwIwLDAqBggrBgEFBQcCARYeaHR0cHM6Ly93d3cuc3NsLmNv
# bS9yZXBvc2l0b3J5MBMGA1UdJQQMMAoGCCsGAQUFBwMDMFAGA1UdHwRJMEcwRaBD
# oEGGP2h0dHA6Ly9jcmxzLnNzbC5jb20vU1NMY29tLVN1YkNBLUVWLUNvZGVTaWdu
# aW5nLVJTQS00MDk2LVIzLmNybDAdBgNVHQ4EFgQUzXsB1QtKcPLv7e/YFnDLYrq6
# eD0wDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQB23+9fXt0zJprV
# MiPNLU432HO9nW3480ripp/flVQN4OZ6h53nNiPOSH044w88oEVd89v4rODLHvQ0
# gOvCf6BbAr13ZalSxZlxADkv5Gyx86s7ilt1rLSsYLerSo6YVpfXD3FAfzPDtBvO
# C9YEqXdVZ86ANJQBe3GR3uZz3Y7qYhqgg4s4Cm6rz4lR9fnyxnq4pGAu5uZ0OgtW
# 9JBAWcRsdj3zQqVYzs+fLeQOFmfZPLCaa67yi/uozJGfoBCeVy3Tz1Jo8RMoM8KU
# fdE1SCzU4sgfDkYstlNyYWZp4gJO4x8NyLsyZRLgvdtjFxtXuWeCXkjHHufS0QpL
# C/XiSnt4lFAdQQp6Xgy4o2zPvF0SduGPMrmeUnLBSDq+ZGedflMGALxYeutrsEJ9
# UlmL+zYfcfDhXZ7JeJ45rLM61a8eT3G/umR7U/WT8IIsXMIDuPK7/pZEm1xqwIzC
# V2vw8udpe/xpRFMYF5CU8XgHc2aOy6kOCHUXGgk6WDYsJyXDcz+l5r2ChPwTAVSZ
# E51olp2NKrLd75DlZEP/4040hyWo8NalyhJzIDlDOYHo5H88oT3d6FgQ7gM2CjbB
# G5+wKT1jhbU2kfi7JuNqAZNvd9vOrIZ3oGNP+7K+xeU4aKEWfy+zu+5Q7OL1iGm6
# /3P5FjswnFSfHyaKYqj2wHCgHxrnNjCCBeswggPToAMCAQICCFa2Kc00vHj2MA0G
# CSqGSIb3DQEBCwUAMIGCMQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAO
# BgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjE3MDUGA1UE
# AwwuU1NMLmNvbSBFViBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQSBS
# MjAeFw0xNzA1MzExODE0MzdaFw00MjA1MzAxODE0MzdaMIGCMQswCQYDVQQGEwJV
# UzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NT
# TCBDb3Jwb3JhdGlvbjE3MDUGA1UEAwwuU1NMLmNvbSBFViBSb290IENlcnRpZmlj
# YXRpb24gQXV0aG9yaXR5IFJTQSBSMjCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAI82ZUDh1k3A17TpRtpr6jNHzUz5fX2+vS098Nt44Yal2boJV2jtVz6g
# 0AhBg+coQSQf43IV0AEa+15wI7LLnznjz8VOxpJtJsZ7u7PaJ50KhumBNwX+8HFx
# 7MMc6WOiFxSd7xtn04VVAgLWScnMWuGx928yn8nUO4hBqJy9y6vbbXsJH6JMcpDa
# Kwj8zzxUzmcPqM9dlhkLxONy663RfR0n75LrEL9b6zuvz4DdwdKWBFt6fqSpPDh2
# pGKOoDle6nfPXQBZj2YsPgeiowUmEWmX6oW3D5YLS8hA4VC6LorL9w+aIud/mjcT
# zfJNE2sh0cDMIvKhRvZEaZzKYTUHAG/WYQgR6rq49umzYOVNueyfFGbJV1jbzYdp
# +IqGEgNHv2YTdqx3fTQkhYPN16qckBqfISx/eLdkuNjopvR4s1XLhNIyxHiuo49h
# 3c4IU63siPwV5JoN5p8ad85Mj7gUFT1inIY4BgBmEuRZdlpTwAKYohAraER7jnnO
# M0p2qluBFhu1itjQAHteYrQJ1oZjDqYFlUm6KIuIk7I0HNikVW63HNDemVU7I/Qi
# 4PkpZibsIFB320oLj77lAmBwQV7UrlA5IhQmy7I7c3RVRwd5gTmoMBNE5QSKrpYT
# JUIPuVPEm/zN5BzePPqr1gZKH2emmDAc3Szb3BiVV2bG/1yLVvV3AgMBAAGjYzBh
# MA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU+WC71OPVNPa49QaAJadz20Zp
# qJ4wHQYDVR0OBBYEFPlgu9Tj1TT2uPUGgCWnc9tGaaieMA4GA1UdDwEB/wQEAwIB
# hjANBgkqhkiG9w0BAQsFAAOCAgEAVrOOywqdSY6/pMSRu2YXBVGYdfvlUCx6nvEU
# +qvTij7/kSmPY4vYtKlUAQ2+k4Yv+Uptx171V/nKVRwSvkcPNsXfarfbdcJHJX+5
# 8WP4aC1VBNHyjbCkz7w8Xh9456WgIHCwBMW393Kn3iINvTMlRoxkkibjPi5jltqb
# jD34GAnXA8x9hoLgygQHUVDX/5LVDO/ahp+Z1+u3r2jiOSaUumi3v4PT6npnPWJn
# riXlcuji5OyuEvZLKzyf6bBA8zhUs/23aMjaxo9RPLL7kdwc55ud4bcNco/ipMSp
# ePnrFKzGQwXCZTkoGALDgrKdBb5l7ZZfZXQ8+wk1LnucE/0bD13HbYE6Vg/MO+Gv
# Ai8irEbKRjygHEzWRLReLlwVZgnhJin+xlJhurFz/8MMnOVsapQ/FMpAFpWE81mp
# rF9MYZNt0TvMopUMIqZnZ0QuudnSikGzZgta+30jpfIasP/em4OULtE/35K3ka8F
# O2XHoGyxzWISw5Ab4yXONLxvd3axEMP3BRrA1q90YkgXd5JpkGEc3pWAdFSPGBzD
# 8wPQv6RDdYZTGHoKLgkcNp+R/YKKIkvRDlAl3csDDBfJgwAITjVNiovt8AKUZixE
# f8uVJ5YXrQkwrLZxF26LF/YcCdQtO5ilcdNUE9lg8/VLZk/68e4gEo20rFexRWOh
# rHapwvswggZZMIIEQaADAgECAg0B7BySQN79LkBdfEd0MA0GCSqGSIb3DQEBDAUA
# MEwxIDAeBgNVBAsTF0dsb2JhbFNpZ24gUm9vdCBDQSAtIFI2MRMwEQYDVQQKEwpH
# bG9iYWxTaWduMRMwEQYDVQQDEwpHbG9iYWxTaWduMB4XDTE4MDYyMDAwMDAwMFoX
# DTM0MTIxMDAwMDAwMFowWzELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNp
# Z24gbnYtc2ExMTAvBgNVBAMTKEdsb2JhbFNpZ24gVGltZXN0YW1waW5nIENBIC0g
# U0hBMzg0IC0gRzQwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDwAuIw
# I/rgG+GadLOvdYNfqUdSx2E6Y3w5I3ltdPwx5HQSGZb6zidiW64HiifuV6PENe2z
# NMeswwzrgGZt0ShKwSy7uXDycq6M95laXXauv0SofEEkjo+6xU//NkGrpy39eE5D
# iP6TGRfZ7jHPvIo7bmrEiPDul/bc8xigS5kcDoenJuGIyaDlmeKe9JxMP11b7Lbv
# 0mXPRQtUPbFUUweLmW64VJmKqDGSO/J6ffwOWN+BauGwbB5lgirUIceU/kKWO/EL
# sX9/RpgOhz16ZevRVqkuvftYPbWF+lOZTVt07XJLog2CNxkM0KvqWsHvD9WZuT/0
# TzXxnA/TNxNS2SU07Zbv+GfqCL6PSXr/kLHU9ykV1/kNXdaHQx50xHAotIB7vSqb
# u4ThDqxvDbm19m1W/oodCT4kDmcmx/yyDaCUsLKUzHvmZ/6mWLLU2EESwVX9bpHF
# u7FMCEue1EIGbxsY1TbqZK7O/fUF5uJm0A4FIayxEQYjGeT7BTRE6giunUlnEYuC
# 5a1ahqdm/TMDAd6ZJflxbumcXQJMYDzPAo8B/XLukvGnEt5CEk3sqSbldwKsDlcM
# CdFhniaI/MiyTdtk8EWfusE/VKPYdgKVbGqNyiJc9gwE4yn6S7Ac0zd0hNkdZqs0
# c48efXxeltY9GbCX6oxQkW2vV4Z+EDcdaxoU3wIDAQABo4IBKTCCASUwDgYDVR0P
# AQH/BAQDAgGGMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYEFOoWxmnn48tX
# RTkzpPBAvtDDvWWWMB8GA1UdIwQYMBaAFK5sBaOTE+Ki5+LXHNbH8H/IZ1OgMD4G
# CCsGAQUFBwEBBDIwMDAuBggrBgEFBQcwAYYiaHR0cDovL29jc3AyLmdsb2JhbHNp
# Z24uY29tL3Jvb3RyNjA2BgNVHR8ELzAtMCugKaAnhiVodHRwOi8vY3JsLmdsb2Jh
# bHNpZ24uY29tL3Jvb3QtcjYuY3JsMEcGA1UdIARAMD4wPAYEVR0gADA0MDIGCCsG
# AQUFBwIBFiZodHRwczovL3d3dy5nbG9iYWxzaWduLmNvbS9yZXBvc2l0b3J5LzAN
# BgkqhkiG9w0BAQwFAAOCAgEAf+KI2VdnK0JfgacJC7rEuygYVtZMv9sbB3DG+wsJ
# rQA6YDMfOcYWaxlASSUIHuSb99akDY8elvKGohfeQb9P4byrze7AI4zGhf5LFST5
# GETsH8KkrNCyz+zCVmUdvX/23oLIt59h07VGSJiXAmd6FpVK22LG0LMCzDRIRVXd
# 7OlKn14U7XIQcXZw0g+W8+o3V5SRGK/cjZk4GVjCqaF+om4VJuq0+X8q5+dIZGkv
# 0pqhcvb3JEt0Wn1yhjWzAlcfi5z8u6xM3vreU0yD/RKxtklVT3WdrG9KyC5qucqI
# wxIwTrIIc59eodaZzul9S5YszBZrGM3kWTeGCSziRdayzW6CdaXajR63Wy+ILj19
# 8fKRMAWcznt8oMWsr1EG8BHHHTDFUVZg6HyVPSLj1QokUyeXgPpIiScseeI85Zse
# 46qEgok+wEr1If5iEO0dMPz2zOpIJ3yLdUJ/a8vzpWuVHwRYNAqJ7YJQ5NF7qMnm
# vkiqK1XZjbclIA4bUaDUY6qD6mxyYUrJ+kPExlfFnbY8sIuwuRwx773vFNgUQGwg
# HcIt6AvGjW2MtnHtUiH+PvafnzkarqzSL3ogsfSsqh3iLRSd+pZqHcY8yvPZHL9T
# TaRHWXyVxENB+SXiLBB+gfkNlKd98rUJ9dhgckBQlSDUQ0S++qCV5yBZtnjGpGqq
# IpswggZvMIIEV6ADAgECAhABXMCK85u0U3OWiccagp0yMA0GCSqGSIb3DQEBDAUA
# MFsxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTEwLwYD
# VQQDEyhHbG9iYWxTaWduIFRpbWVzdGFtcGluZyBDQSAtIFNIQTM4NCAtIEc0MB4X
# DTI1MDUxNTA4MzAwMFoXDTM0MTIxMDAwMDAwMFowajELMAkGA1UEBhMCQkUxGTAX
# BgNVBAoMEEdsb2JhbFNpZ24gbnYtc2ExQDA+BgNVBAMMN0dsb2JhbHNpZ24gVFNB
# IGZvciBNUyBBdXRoZW50aWNvZGUgQWR2YW5jZWQgLSBHNCAtIDIwMjUwggGiMA0G
# CSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCPTxsZdPqLrp/G8sMHvYYd4KunisUz
# Qa+FjoK2KfZH6lQ1UB7WvGZV1X8jJywqaZKNfQhHLFbxbA4rOu/naMSSqX5/TOXJ
# d+FLJ+lE+9Q8hyF9FKJ353W3tPLC+O7KeAoAb80vt0uGRXs4NoQNG5dYMZHBif6I
# RUDdhZtufFTxWJr5cRIWbsRC24UAwbK5TQIokg43huUPeXj2qKZukuasKQ5tUTCr
# UhmYR3IFpHkyVpdu+cdBcEPw4K9N53himASqRHej4nz/2gGsH6OvLFIpJawYbSwi
# V8m6DcpHVxT3plxDj9nCU88wTVgipzsda+pI5vvhht42IG/n4e1BUY+fqph6EJM7
# bs3CSR6htAmDsn4esE7iMdQm/+mkVow2OnBzk8GLg2guEEENAWgh83OlWBGTvzwG
# mKaY+FI9maDrqvGnEuj8QzjbY3Kq38D4jsFgrQjiLAeI8z02gltITWqatYDqanYk
# rSny8k05oEHPHEZSAXA2+SiXVFPKfUw5xosCAwEAAaOCAZ4wggGaMA4GA1UdDwEB
# /wQEAwIHgDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAdBgNVHQ4EFgQU1zj7uMf7
# PJwuwEpTcZtKNo8+rbMwTAYDVR0gBEUwQzBBBgkrBgEEAaAyAR4wNDAyBggrBgEF
# BQcCARYmaHR0cHM6Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVwb3NpdG9yeS8wDAYD
# VR0TAQH/BAIwADCBkAYIKwYBBQUHAQEEgYMwgYAwOQYIKwYBBQUHMAGGLWh0dHA6
# Ly9vY3NwLmdsb2JhbHNpZ24uY29tL2NhL2dzdHNhY2FzaGEzODRnNDBDBggrBgEF
# BQcwAoY3aHR0cDovL3NlY3VyZS5nbG9iYWxzaWduLmNvbS9jYWNlcnQvZ3N0c2Fj
# YXNoYTM4NGc0LmNydDAfBgNVHSMEGDAWgBTqFsZp5+PLV0U5M6TwQL7Qw71lljBB
# BgNVHR8EOjA4MDagNKAyhjBodHRwOi8vY3JsLmdsb2JhbHNpZ24uY29tL2NhL2dz
# dHNhY2FzaGEzODRnNC5jcmwwDQYJKoZIhvcNAQEMBQADggIBAArKwhvg0yjAbbXM
# 8cNYCGjDhogTZTteS3WJ4Sn6m2aH9j023Z0mnqJtwEANLzxtIGfzwbnXTbTYZ7gW
# m9Hug6SNE7zitwSI3poJB1pcuOEl3DOzTQy2t/P5Nb3PwP+gLyk++Ic6zYmI34Sf
# iKYeEG+UrMtdG4BiX5VouvUYrPZo+o52QA60ZF24+2cYgooB+CJolTUqXaCfjIdi
# DFm1Gn1oVi/FrTD+0qF6WRp4YXz4nF/rhdnh/PXp546gIK5mKcu8kt/kn69fG8mL
# jMiPF3VbJ5AmGPwE3G8v5hbLPQUWHZKpolFyym8GDMh4cTS7fg0KBZreaFveo/by
# 2ogbRwv0JZGarnRcgQl5E9UQbJ2otaj7J6BvhoFz4zdL1BkhkIFcANlx/3iDLW6S
# r9xwZ2e7z6XMU8TVbfdBod12ovzS6XooCOb0ma7kxlseO7wLgudYo50YAj3QZYct
# b7ZzLUplRz+XdETxJc5eYllIhBVxoBFku2e9+5ICKMnOSBoFBfqXnBIYUhQ2gYGO
# 1kEkMuE0SIE63yHnQGvrTrMNc/vQfYPPOAEkhNrT+vym4dYBlaaLD0OOlg4RP01w
# uFVXzsfD4J3D1sAKYNFTAGa8IXonjCrvEZnunef1+tjRwG+4XMwyLwrYvnu4IAxd
# j6OWZ59W4aNTjxkXBeiECM/cMkjnMIIG3zCCBMegAwIBAgIQQktqU87HZhQcKmOx
# pRxBBDANBgkqhkiG9w0BAQsFADCBgjELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRl
# eGFzMRAwDgYDVQQHDAdIb3VzdG9uMRgwFgYDVQQKDA9TU0wgQ29ycG9yYXRpb24x
# NzA1BgNVBAMMLlNTTC5jb20gRVYgUm9vdCBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0
# eSBSU0EgUjIwHhcNMTkwMzI2MTc0NDIzWhcNMzQwMzIyMTc0NDIzWjB7MQswCQYD
# VQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAPBgNV
# BAoMCFNTTCBDb3JwMTcwNQYDVQQDDC5TU0wuY29tIEVWIENvZGUgU2lnbmluZyBJ
# bnRlcm1lZGlhdGUgQ0EgUlNBIFIzMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEA8Ko39yshkSBnOjmOFeUhuloTKo1R0HM9va4BjBN71n74ZmPt9HsrkvG+
# Y2v3qDdldg18NKdSsdh48F/pn3d6YT6DZuxmzrekPX0ala8dXX/FlUmg2Oq9I+aU
# P5luJUY4xFWYODyp9OWuedr7dW4AHxA/sY8C/0Kukvz101oJJVJjiN1f9JEoFhWr
# VC6c8d7g29IyaSFnRm1XX5vK0Td/p2knHq47al6yxgqgPWAefHbFHKMCZXOEMWXt
# /lVom6wh0Z2EfuoBz+TnS0wYXWSBdzZoxwP4ysQ29p8SbN1EGQvpYH4JK9uaPDbP
# jqEcAfd1tfZvhwsDWs+Y18soUJelofKoIRz7sUw16hhbFsdFXAAgeW+I01BvcPfF
# 0kMfF5J+MZapQbpD8rnRjcZokuCbioDWedYpX+bAgYryyw5NGDYLdapJNu0jzhfO
# UYcp0NgMoqJm/9vnkxOLfJTJa1GNUtY774oN5L3+OKFaaFnYB+e1NbCQODxbLSIQ
# lwc7srIyYGHGOBVssLq1foP5PLIqHr+tzVinj287bDffrogsR98RHajXFLRlr0/2
# okmyYXAK/tlOF3hXXokl0sQeStOec+oUaCkCIlH9zxQELv8e85SUnXNQrKqpK0Nx
# IY52MpYoEFkr7D8g6S7m0+NmJRE4nGlD6tMkpP+iJeoIDihYnOkCAwEAAaOCAVUw
# ggFRMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU+WC71OPVNPa49QaA
# Jadz20ZpqJ4wfAYIKwYBBQUHAQEEcDBuMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3
# LnNzbC5jb20vcmVwb3NpdG9yeS9TU0xjb20tUm9vdENBLUVWLVJTQS00MDk2LVIy
# LmNydDAgBggrBgEFBQcwAYYUaHR0cDovL29jc3BzLnNzbC5jb20wEQYDVR0gBAow
# CDAGBgRVHSAAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMEUGA1UdHwQ+MDwwOqA4oDaG
# NGh0dHA6Ly9jcmxzLnNzbC5jb20vU1NMY29tLVJvb3RDQS1FVi1SU0EtNDA5Ni1S
# Mi5jcmwwHQYDVR0OBBYEFDa9Sf8xLOuvakD+mcAW7br8SN1fMA4GA1UdDwEB/wQE
# AwIBhjANBgkqhkiG9w0BAQsFAAOCAgEAco/6gUiCkeJggyVbe48vlA+DWM6IJPqZ
# Qk4tTjeJ+J+xHq50QHn53sv3/ywlEFKYQI9UOP9d0SqpWua3ArvIf+4q0/9/zDY8
# VSlDXTZJliZdcOfyKwVnR0yZWBkI9rHGT2DS/Di+Aqwl0YgNpSzh3dN9V89qwxlg
# 0m2qXXtE6Fpbg9vIGzYKfgr1ClI2eOKa+xNUzJzJR79iTjWvPuG6D8mT7tUgt5a3
# UHZSNXqdoTsmZDcfzrwDe8RhgVKJzHv+WgUaR67kEsqOVONan7DBivL5X0Zoua/H
# 2T6E0SslEjg9u5oB6t/MZqi2xR9qk0ewzgaShK1Dg2qGOVxM4gJLeHOuSyjmpPhh
# aYDM/zTosC9kAkkNjS4ffeuhhgUP7V5wNOUYAgDrY751Jm2nHJBXB66ZpY430qfD
# WGyl9OdSIjWnW7tu60jbmnLeqlpiSQmekCsSD8g6269oc53Z43nKmPloHermWC6p
# GGzNmTqazSZwROZmmJwlHhlqx9jz5/+mNXf79X27jILHb31UMrvqmQs56CBRFS+J
# 4yrhxSDzenhOPa8XYpJUjSeMkDfc4ynoQpO2+DsrC5lQuOQ0Bpgj7urftVS7rtvx
# 6t1y+UXtsdpDO4D8b2zf3JFtuKXU73XNZUxkLFnfEy4CG0v6BJPAuzcdH7Ig008z
# rxahHMCqqIgxggTcMIIE2AIBATCBjzB7MQswCQYDVQQGEwJVUzEOMAwGA1UECAwF
# VGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAPBgNVBAoMCFNTTCBDb3JwMTcwNQYD
# VQQDDC5TU0wuY29tIEVWIENvZGUgU2lnbmluZyBJbnRlcm1lZGlhdGUgQ0EgUlNB
# IFIzAhB5w2lRigPnF+NXyyeBVD75MA0GCWCGSAFlAwQCAQUAoEwwGQYJKoZIhvcN
# AQkDMQwGCisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIMwxhKKD+fIpe4OcneJf
# er1N+H/Qa0TXiBOamYhY2ZCmMAsGByqGSM49AgEFAARnMGUCMQDzxaxLUJ/hv9oO
# RS1akqqGpv45De3yrFgKYhzpAHhFLLlPClG2OPewMOkbpgXqe2ICMFLl8Cmc4paQ
# nn0PKKWWddTMEsmPGJeoFs3sIBJxjm4HCnn0CQ7bemmHLm8XLTHquqGCA2wwggNo
# BgkqhkiG9w0BCQYxggNZMIIDVQIBATBvMFsxCzAJBgNVBAYTAkJFMRkwFwYDVQQK
# ExBHbG9iYWxTaWduIG52LXNhMTEwLwYDVQQDEyhHbG9iYWxTaWduIFRpbWVzdGFt
# cGluZyBDQSAtIFNIQTM4NCAtIEc0AhABXMCK85u0U3OWiccagp0yMAsGCWCGSAFl
# AwQCAaCCAT0wGAYJKoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUx
# DxcNMjYwNDA4MTkxOTQ2WjArBgkqhkiG9w0BCTQxHjAcMAsGCWCGSAFlAwQCAaEN
# BgkqhkiG9w0BAQsFADAvBgkqhkiG9w0BCQQxIgQgf0gJ6TQ5ljiwvxnLs7vKfCPW
# w2RExgkKxRSo69+g0RYwgaQGCyqGSIb3DQEJEAIMMYGUMIGRMIGOMIGLBBRwX9qC
# VDLz9Ycr7b8jrKAkuqNbVTBzMF+kXTBbMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQ
# R2xvYmFsU2lnbiBudi1zYTExMC8GA1UEAxMoR2xvYmFsU2lnbiBUaW1lc3RhbXBp
# bmcgQ0EgLSBTSEEzODQgLSBHNAIQAVzAivObtFNzlonHGoKdMjANBgkqhkiG9w0B
# AQsFAASCAYBmun1Xmp3oPG5PEnnoUYgilp+WK85AmleqCPhpy519TXrCxaXWzLX8
# xoqRzj4jupgjeW/7ZQ/74SVAmolLVQ3IfS7kOFCFwibbvZvYesRqg/lO1Z8MaZMh
# 9QQzJ8HCjKwYPmXqQz7z+iiSQ1WgDRG8GgCFcJEkMuBo4T8p9XK8jYOyWI5h2Ek3
# SG5m+CVM2twXt+nu7V7v88899ERYV9GzIOon/npj+6YSpPE3Mvg4pacKdcgmuiow
# 4UFcxSTmmCZlqc5xJADP2vNhl3/94Vlm/ZUNIfpzNYMc/Ky8Wa3YWCfFUISAT24w
# LoMsKpQ0cw3h6nrMhJW2gXeg1iUf7ffkdb0cM8KonlFmLJX3VKs7YVkJH6bFV+x5
# EgkP9sU3reFTiei+MC8jExVAW+7J18jtTA0V+u6c3NlgGndGa7jOFk8spEG6vBd2
# GFiPSz+0YDAF4N0iVn/PDyRTJhbb1cbLPpv8XVf/bVBOGAzQ9+P4aLmqqts4oZ/I
# 0ex+pbA27CQ=
# SIG # End signature block
