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

