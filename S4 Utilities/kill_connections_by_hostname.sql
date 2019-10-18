
/*


	EXEC kill_connections_by_hostname
		@HostName = 'UNITYVPN', 
		@PrintOnly = 1;

*/

USE [admindb];
GO


IF OBJECT_ID('dbo.kill_connections_by_hostname','P') IS NOT NULL
	DROP PROC dbo.kill_connections_by_hostname;
GO

CREATE PROC dbo.kill_connections_by_hostname
	@HostName				sysname, 
	@Interval				sysname			= '3 seconds', 
	@MaxIterations			int				= 5, 

-- TODO: Add error-handling AND reporting... along with options to 'run silent' and so on... 
--		as in, there are going to be some cases where we automate this, and it should raise errors if it can't kill all spids owned by @HostName... 
--			and, at other times... we won't necessarily care... (and just want the tool to do 'ad hoc' kills of a single host-name - without having to have all of the 'plumbing' needed for Mail Profiles, Operators, Etc... 
	@PrintOnly				int				= 0
AS 
	SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Validate Inputs:
	IF UPPER(HOST_NAME()) = UPPER(@HostName) BEGIN 
		RAISERROR('Invalid HostName - You can''t KILL spids owned by the host running this stored procedure.', 16, 1);
		RETURN -1;
	END;

	DECLARE @waitFor sysname
	DECLARE @error nvarchar(MAX);

	EXEC dbo.[translate_vector_delay]
	    @Vector = @Interval,
	    @ParameterName = N'@Interval',
	    @Output = @waitFor OUTPUT,
	    @Error = @error OUTPUT;
	
	IF @error IS NOT NULL BEGIN 
		RAISERROR(@error, 16, 1);
		RETURN -10;
	END;

	-----------------------------------------------------------------------------
	-- Processing: 	
	DECLARE @statement nvarchar(MAX) = N'';
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);

	DECLARE @currentIteration int = 0; 
	WHILE (@currentIteration < @MaxIterations) BEGIN
		
		SET @statement = N''; 

		SELECT 
			@statement = @statement + N'KILL ' + CAST(session_id AS sysname) + N';'  + @crlf
		FROM 
			[master].sys.[dm_exec_sessions] 
		WHERE 
			[host_name] = @HostName;
		
		IF @PrintOnly = 1 BEGIN 
			PRINT N'--------------------------------------';
			PRINT @statement; 
			PRINT @crlf;
			PRINT N'WAITFOR DELAY ' + @waitFor; 
			PRINT @crlf;
			PRINT @crlf;
		  END; 
		ELSE BEGIN 
			EXEC (@statement);
			WAITFOR DELAY @waitFor;
		END;

		SET @currentIteration += 1;
	END; 

	-- then... report on any problems/errors.

	RETURN 0;
GO	