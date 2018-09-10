


/*
	NOTES:
		- For instructions on using SQL Server Template Language (i.e, the <angle bracket code in this script>, see the following video:
			http://www.sqlservervideos.com/video/using-sql-server-templates/

		- Creating Linked servers via T-SQL is the easiest way to get the initial setup/options correct. 

		- Make sure to run this on BOTH servers (i.e., on SERVERA, PARTNER becomes SERVERB, whereas on SERVERB, PARTNER is SERVERA). 

		- The Reason for using the alias 'PARTNER' instead of something like SQL1/SQL2 or SERVERA, SERVERB, etc. is because using the alias PARTNER
			lets us run code on EITHER server (pointed at the OTHER server) without having to a) customize code for these server names and b) we don't have to 
			account for minor 'subtleties' like "SELECT someDetail FROM SERVERB.master.dbo.X" telling  us that our JOBS or CODE is out of sync from one server
			to the other because SERVERA != SERVERB (whereas "SELECT someDetail FROM PARTNER.master.dbo.X" can be the same on both servers). 

	PARAMETERS:
		<TargetServerName, sysname, SQLA> = Name of the server that will be aliased as 'PARTNER'. 


	DEPENDENCIES:

-- todo, document:
			- need to document dependencies - which are that ... can't be using LOCAL machine accounts - has to be network service at a bare minimum
			but... better is ... domain account (least priv) or ... an NTLM account (same login/pwd on both servers).

			- likewise that service account needs to have a login - which needs to be sysadmin on both boxes. 


*/


EXEC sys.sp_addlinkedserver
	@server = 'PARTNER',
    @srvproduct = N'', 
    @provider = N'SQLNCLI', -- by NOT specifying a version (and specifying SQLNCLI instead), SQL Server will redirect to the most recent version installed. (As per BOL.) 
    @datasrc = N'tcp:<TargetServerName, sysname, SQLXX>', 
    @catalog = 'master'
GO
