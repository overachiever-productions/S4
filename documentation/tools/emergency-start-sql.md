![](https://assets.overachiever.net/s4/images/s4_main_logo.png)

[S4 Docs Home](/readme.md) > emergency-start-sql.ps1

# emergency-start-sql.ps1

## Table of Contents
- [Section Name Here](#section-name-here)
- [Another Section Name](#another-section-name)
- [Sample Table](#sample-table) 

## [Documentation Here]
Intro details here about ... why this exists and how it can be beneficial ... 

<section style="visibility:hidden; display:none;">

TODO: look at integrating TF 3608 as an option for startup - i.e., instead of 'just' -m and -f ... look at -3608 as well. 

rough fodder:
https://www.mssqltips.com/sqlservertip/6237/how-to-restore-model-database-in-sql-server/

</section>

[Return to Table of Contents](#table-of-contents)

## Current Body of the Script (Rough Draft)
In the absence of documentation... code is a form of documentation... and, the code is really what we're after for the most part anyhow. (That said: code is still a bit rough around the edges.)

```PowerShell


# FODDER: 
#           https://docs.microsoft.com/en-us/sql/database-engine/configure-windows/database-engine-service-startup-options?view=sql-server-ver15
#           https://www.business.com/articles/powershell-interactive-menu/

#           https://sqlcommunity.com/hacking-sa-password-in-sql-server/

#Requires -RunAsAdministrator

function ShowMenu {
    Clear-Host;
    Write-Host "=================SELECT SQL SERVER VERSION TO START================="
    Write-Host "`t`t1. SQL Server 2019 (150).";
    Write-Host "`t`t2. SQL Server 2017 (140).";
    Write-Host "`t`t3. SQL Server 2016 (130).";
    Write-Host "`t`t4. SQL Server 2014 (120).";
    Write-Host "`t`t5. SQL Server 2012 (110).";
    Write-Host "`t`tQ. QUIT / Abort."
}

ShowMenu; 
$version = Read-Host "Please Make a Selection... ";

if($version -eq "Q"){
    return;
}

$versions = @{};
$versions.Add('1', @{name='SQL Server 2019 (150)'; major='15'});
$versions.Add('2', @{name='SQL Server 2017 (140)'; major='14'});
$versions.Add('3', @{name='SQL Server 2016 (130)'; major='13'});
$versions.Add('4', @{name='SQL Server 2014 (120)'; major='12'});
$versions.Add('5', @{name='SQL Server 2012 (110)'; major='11'});

#Write-Host $versions[$version].name;

$sqlservrExe = "C:\Program Files\Microsoft SQL Server\MSSQL$($versions[$version].major).MSSQLSERVER\MSSQL\Binn\sqlservr.exe";

$registryKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQLServer\Parameters";
$dSwitch = (Get-ItemProperty -Path $registryKey -Name "SQLArg0").SQLArg0;
$eSwitch = (Get-ItemProperty -Path $registryKey -Name "SQLArg1").SQLArg1;
$lSwitch = (Get-ItemProperty -Path $registryKey -Name "SQLArg2").SQLArg2;

# translate switches: 
$dSwitch = $dSwitch -replace "-d", "";
$eSwitch = $eSwitch -replace "-e", "";
$lSwitch = $lSwitch -replace "-l", "";

$sql = Get-Service MSSQLSERVER; 

if(($sql).Status -eq "Running"){
    Write-Host "SQL Server is currently running. Terminate? Y(es) or N(o)?"
    $terminate = Read-Host;

    if($terminate -ne "Y") {
        Write-Host "Exciting execution...";
        return;
    }

    Write-Host "Stopping SQL Server...";
    Stop-Service $sql -Force;
    $sql.WaitForStatus('stopped', '00:00:30');
}

# switches to use: 
# c - always. speeds up start-up time by skipping services stuff. 
# f - minimal config ... good option for some DR and other scenarios. 
# m - single-user mode ... 
# m"ClientAppName" as above... but limits to a specific app name e.g., ... -m"SQLCMD" ... 

# TODO: Prompt for other options - i.e., for -f or -m and ... if -m, then prompt also for an optional AppName... 
#$startupCommand = "'$sqlservrExe' -c -m -d'$dSwitch' -e'$eSwitch' -l'$lSwitch'";

$argD = "-d`"$dSwitch`"";
$argE = "-e`"$eSwitch`"";
$argL = "-l`"$lSwitch`"";

$args = @(
    $argD,
    $argE,
    $argL,
    '-c', 
    '-m'
);

Write-Host $args;

Write-Host "Hack Starting SQL Server..... "
#Invoke-Expression $startupCommand;
#Write-Host ""
#Write-Host $startupCommand;

& $sqlservrExe $args;


<#
    then... once the SQL Server is started: 

    IN a DIFFERENT process/window/command-shell/whatever: 

        > SQLCMD -S. 

        and then you can run stuff like: 

            > CREATE LOGIN [DOMAIN\UserOrGroup] FROM WINDOWS
            > GO 

        and then: 

            > ALTER SERVER ROLE [SysAdmin] ADD MEMBER [DOMAIN\UserOrGroup];
            > GO 

        and then... 
            
            > SHUTDOWN; 
            > GO

        and... then restart the SQL Server via the normal services... 



#>

```

[Return to Table of Contents](#table-of-contents)

## Remarks ... etc.


[Return to Table of Contents](#table-of-contents)

[S4 Docs Home](/readme.md)