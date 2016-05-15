Function Copy-SqlServerAgent
{
<#
.SYNOPSIS
Copies *all* ProxyAccounts, JobSchedule, SharedSchedules, AlertSystem, JobCategories, 
OperatorCategories AlertCategories, Alerts, TargetServerGroups, TargetServers, 
Operators, Jobs, Mail and general SQL Agent settings from one SQL Server Agent 
to another. $sourceserver and $destserver are SMO server objects. 

Ignores -force: does not drop and recreate.

.DESCRIPTION
This function could use some refining, as *all* job objects are copied. 

THIS CODE IS PROVIDED "AS IS", WITH NO WARRANTIES.

.PARAMETER Source
Source SQL Server.You must have sysadmin access and server version must be SQL Server version 2000 or greater.

.PARAMETER Destination
Destination Sql Server. You must have sysadmin access and server version must be SQL Server version 2000 or greater.

.PARAMETER SourceSqlCredential
Allows you to login to servers using SQL Logins as opposed to Windows Auth/Integrated/Trusted. To use:

$scred = Get-Credential, then pass $scred object to the -SourceSqlCredential parameter. 

Windows Authentication will be used if DestinationSqlCredential is not specified. SQL Server does not accept Windows credentials being passed as credentials. 	
To connect as a different Windows user, run PowerShell as that user.

.PARAMETER DestinationSqlCredential
Allows you to login to servers using SQL Logins as opposed to Windows Auth/Integrated/Trusted. To use:

$dcred = Get-Credential, then pass this $dcred to the -DestinationSqlCredential parameter. 

Windows Authentication will be used if DestinationSqlCredential is not specified. SQL Server does not accept Windows credentials being passed as credentials. 	
To connect as a different Windows user, run PowerShell as that user.

.PARAMETER DisableJobsOnDestination
When this flag is set, copy all jobs as Enabled=0

.NOTES 
Author: Chrissy LeMaire (@cl), netnerds.net
Requires: sysadmin access on SQL Servers

dbatools PowerShell module (https://dbatools.io, clemaire@gmail.com)
Copyright (C) 2016 Chrissy LeMaire

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

.LINK
https://dbatools.io/Copy-SqlServerAgent

.EXAMPLE   
Copy-SqlServerAgent -Source sqlserver2014a -Destination sqlcluster

Copies all job server objects from sqlserver2014a to sqlcluster, using Windows credentials. If job objects with the same name exist on sqlcluster, they will be skipped.

.EXAMPLE   
Copy-SqlServerAgent -Source sqlserver2014a -Destination sqlcluster -SourceSqlCredential $cred

Copies all job objects from sqlserver2014a to sqlcluster, using SQL credentials for sqlserver2014a
and Windows credentials for sqlcluster.

.EXAMPLE   
Copy-SqlServerTrigger -Source sqlserver2014a -Destination sqlcluster -WhatIf

Shows what would happen if the command were executed.
#>
	
	[cmdletbinding(SupportsShouldProcess = $true)]
	param (
		[parameter(Mandatory = $true)]
		[object]$Source,
		[parameter(Mandatory = $true)]
		[object]$Destination,
		[System.Management.Automation.PSCredential]$SourceSqlCredential,
		[System.Management.Automation.PSCredential]$DestinationSqlCredential,
		[Switch]$DisableJobsOnDestination
		
	)
	
	BEGIN  {
		$sourceserver = Connect-SqlServer -SqlServer $Source -SqlCredential $SourceSqlCredential
		$destserver = Connect-SqlServer -SqlServer $Destination -SqlCredential $DestinationSqlCredential
		
		Invoke-SmoCheck -SqlServer $sourceserver
		Invoke-SmoCheck -SqlServer $destserver
		
		$source = $sourceserver.DomainInstanceName
		$destination = $destserver.DomainInstanceName
		
		$sourceagent = $sourceserver.jobserver
	}
	
	PROCESS
	{
	
		
		$jobobjects = "ProxyAccounts", "JobSchedule", "SharedSchedules", "AlertSystem", "JobCategories", "OperatorCategories"
		$jobobjects += "AlertCategories", "Alerts", "TargetServerGroups", "TargetServers", "Operators", "Jobs", "Mail"
		
		$errorcount = 0
		foreach ($jobobject in $jobobjects)
		{
			foreach ($agent in $sourceagent.($jobobject))
			{
				if ($jobobject -eq "Jobs")
				{
					$dbnames = $agent.JobSteps.Databasename.Where{ $_.length -gt 0 }
					$missingdb = $dbnames.Where{ $destserver.Databases.Name -notcontains $_ }
					if ($missingdb.count -gt 0 -and $dbnames.count -gt 0)
					{
						Write-Warning "Database $missingdb doesn't exist on destination. Skipping."
						continue
					}
					
					$missinglogin = $agent.OwnerLoginName.Where{ $destserver.Logins.Name -notcontains $_ }
					if ($missinglogin.count -gt 0)
					{
						Write-Warning "Login $missinglogin doesn't exist on destination. Skipping."
						continue
					}
					
					$proxynames = $agent.JobSteps.ProxyName.Where{ $_.length -gt 0 }
					$missingproxy = $proxynames.Where{ $destserver.JobServer.ProxyAccounts.Name -notcontains $_ }
					if ($missingproxy.count -gt 0 -and $proxynames.count -gt 0)
					{
						Write-Warning "Proxy Account $($proxynames[0]) doesn't exist on destination. Skipping."
						continue
					}
				}
				
				$agentname = $agent.name
				If ($Pscmdlet.ShouldProcess($destination, "Adding $jobobject $agentname"))
				{
					try
					{
						if ($DisableJobsOnDestination -and ($jobobject -eq "Jobs"))
						{
							$agent.IsEnabled = $False
						}
						$sql = $agent.Script() | Out-String
						$sql = $sql -replace [regex]::Escape("@server=N'$source'"), "@server=N'$destination'"
						$null = $destserver.ConnectionContext.ExecuteNonQuery($sql)
						Write-Output "$agentname successfully migrated "
					}
					catch
					{
						if ($_.Exception -like '*duplicate*' -or $_.Exception -like '*already exists*')
						{
							Write-Output "$agentname exists at destination"
						}
						else
						{
							Write-Error "$jobobject : $agentname : $($_.Exception.InnerException.InnerException.Message)"
						}
					}
				}
			}
		}
	}
	
	END
	{
		$sourceserver.ConnectionContext.Disconnect()
		$destserver.ConnectionContext.Disconnect()
		If ($Pscmdlet.ShouldProcess("console", "Showing finished message")) { Write-Output "Job server migration finished" }
	}
}