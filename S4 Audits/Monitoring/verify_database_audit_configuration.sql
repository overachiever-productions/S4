

/*

	-- todo: implement. 
		basically very similar to the verify_server_audit_configuration sproc... with a couple of minor twists. 


	AND... here's the deal, set up ONE of these per each db to monitor... 
		AND, if there are multiple specifications... set those up as well. 
			i.e., distinct calls. 

			otherwise, here's the logic:
				create a dynamic statement that'll go to the db in question... and look for the ... targetSpec... and make sure that:
					a) it exists
					b) it's BOUND to the @ParentAudit 
					c) it's turned on. 
					d) OPTIONAL - it matches the specified hash/signature. 
							of course, to pull this off, i now need: dbo.generate_database_audit_signature... that takes in a name and a spec... and... a parent? yeah, probably need the parent as well. 

*/

/*

IF OBJECT_ID('dbo.verify_database_audit_configuration','P') IS NOT NULL
	DROP PROC dbo.verify_database_audit_configuration;
GO

CREATE PROC dbo.verify_database_audit_configuration 
	@TargetDatabase					sysname, 
	--@ParentAudit					sysname,	-- see Todoist comments about NOT using/needing this: https://todoist.com/showTask?id=2773616937
	@TargetSpecification			nvarchar(MAX), 
	@SpecificationHash				bigint = NULL		-- OPTIONAL
AS
	SET NOCOUNT ON; 





	SELECT 'not even close to done yet. well sorta close. it''s copy, paste, tweak to get where I need to be... ';

	RETURN 0;
GO


*/




	--DECLARE @auditID int; 
	--DECLARE @isEnabled bit;

	--SELECT @auditID = audit_id, @isEnabled = is_state_enabled FROM sys.[server_audits] WHERE [name] = @AuditName;


IF OBJECT_ID('dbo.verify_database_audit_configuration','P') IS NOT NULL
	DROP PROC dbo.verify_database_audit_configuration;
GO

CREATE PROC dbo.verify_database_audit_configuration 
	@TargetDatabase					sysname, 
	@TargetSpecification			nvarchar(MAX), 
	@SpecificationHash				bigint = NULL		-- OPTIONAL
AS
	SET NOCOUNT ON; 

	DECLARE @errorMessage nvarchar(MAX);

	DECLARE @errors table (
		error_id int IDENTITY(1,1) NOT NULL, 
		error nvarchar(MAX) NOT NULL
	);

	-- make sure specification exists and is enabled. 
	DECLARE @specificationID int; 
	DECLARE @isEnabled bit;


	SELECT @specificationID = audit_id, @isEnabled = is_state_enabled FROM sys.[server_audits] WHERE [name] = @specificationID;
	IF @specificationID IS NULL BEGIN 
		SELECT @errorMessage = N'WARNING: Server Audit [' + @AuditName + N'] does not currently exist on [' + @@SERVERNAME + N'].';
		INSERT INTO @errors([error]) VALUES (@errorMessage);
		GOTO ALERTS;
	END;

	IF @isEnabled = 0 BEGIN 
		SELECT @errorMessage = N'WARNING: Server Audit [' + @AuditName + N'] on [' + @@SERVERNAME + N'] is currently NOT enabled.';
		INSERT INTO @errors([error]) VALUES (@errorMessage);
	END;
