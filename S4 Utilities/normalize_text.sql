/*

	
	Fodder/Inspiration: 
		https://blogs.msdn.microsoft.com/khen1234/2006/10/22/normalizing-query-text/

		and... as awesome as THAT is, I just can't believe that this piglet is FULL-ON _DOCUMENTED_
			https://docs.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-get-query-template-transact-sql?view=sql-server-2017

			AND, of course, the whole reason it's documented is because it's REALLY needed for something pretty much unrelated to what I'm doing here: 
				https://docs.microsoft.com/en-us/sql/relational-databases/performance/create-a-plan-guide-for-parameterized-queries?view=sql-server-2017

					more fodder: 
						http://colleenmorrow.com/2011/02/09/plan-guides-and-parameterization/
						https://www.mssqltips.com/sqlservertip/2935/sql-server-simple-and-forced-parameterization/
						https://dba.stackexchange.com/questions/156212/sql-guide-plan-not-being-used
						https://www.red-gate.com/simple-talk/sql/performance/fixing-cache-bloat-problems-with-guide-plans-and-forced-parameterization/





	Sadly, 
		this thing is, effectively, useless. 
			It won't normalize: 
				- simple statements without WHERE clauses (not a big loss - those rarely cause problems - and when they do, they're easy enough to 'aggregate' on their own). 
				- Parameterized queries - i.e., anything that's already parameterized. This is huge/pointless. 
				- sproc calls - e.g., sp_executesql ... game over. (don't really care about 'other' sprocs - just that one)




*/


USE [admindb];
GO

IF OBJECT_ID('dbo.[normalize_text]', 'P') IS NOT NULL 
	DROP PROC dbo.[normalize_text];
GO

CREATE PROC dbo.[normalize_text]
	@InputStatement			nvarchar(MAX)		= NULL, 
	@NormalizedOutput		nvarchar(MAX)		OUTPUT, 
	@ParametersOutput		nvarchar(MAX)		OUTPUT, 
	@ErrorInfo				nvarchar(MAX)		OUTPUT
AS 
	SET NOCOUNT ON; 

	-- {copyright}

	-- effectively, just putting a wrapper around sp_get_query_template - to account for the scenarios/situations where it throws an error or has problems.

	/*
		Problem Scenarios: 
			a. multi-statement batches... 
					b. requires current/accurate schema  - meaning that it HAS to be run (effectively) in the same db as where the statement was defined... (or a close enough proxy). 
						ACTUALLY, i think this might have been a limitation of the SQL Server 2005 version - pretty sure it doesn't cause problems (at all) on 2016 (and... likely 2008+)... 

					YEAH, this is NO longer valid... 
					specifically, note the 2x remarks/limitations listed in the docs (for what throws an error): 
						https://docs.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-get-query-template-transact-sql?view=sql-server-2017


			c. statements without any parameters - i.e., those without a WHERE clause... 

			d. implied: sprocs or other EXEC operations (or so I'd 100% expect). 
				CORRECT - as per this 'example': 

						DECLARE @normalized nvarchar(max), @params nvarchar(max); 
						EXEC sp_get_query_template    
							N'EXEC Billing.dbo.AddDayOff N''2018-11-13'', ''te3st day'';', 
							@normalized OUTPUT, 
							@params OUTPUT; 

						SELECT @normalized, @params;

				totally throws an excption - as expected... 



		So, just account for those concerns and provide fixes/work-arounds/hacks for all of those... 
			
	
	*/

	SET @InputStatement = ISNULL(LTRIM(RTRIM(@InputStatement)), '');
	DECLARE @multiStatement bit = 0;
	DECLARE @noParams bit = 0; 
	DECLARE @isExec bit = 0; 

	-- check for multi-statement batches (using SIMPLE/BASIC batch scheme checks - i.e., NOT worth getting carried away on all POTENTIAL permutations of how this could work). 
	IF (@InputStatement LIKE N'% GO %') OR (@InputStatement LIKE N';' AND @InputStatement NOT LIKE N'%sp_executesql%;%') 
		SET @multiStatement = 1; 

	-- TODO: if it's multi-statement, then 'split' on the terminator, parameterize the first statement, then the next, and so on... then 'chain' those together... as the output. 
	--		well, make this an option/switch... (i.e., an input parameter).


	-- again, looking for BASIC (non edge-case) confirmations here: 
	IF @InputStatement NOT LIKE N'%WHERE%' 
		SET @noParams = 1; 

	
	IF (@InputStatement LIKE N'Proc [Database%') OR (@InputStatement LIKE 'EXEC%') 
		SET @isExec = 1; 


	-- damn... this (exclusion logic) might be one of the smartest things i've done in a while... (here's hoping that it WORKS)... 
	IF COALESCE(@multiStatement, @noParams, @isExec, 0) = 0 BEGIN 
		
		DECLARE @errorMessage nvarchar(MAX);

		BEGIN TRY 
			SET @NormalizedOutput = NULL; 
			SET @ParametersOutput = NULL;
			SET @ErrorInfo = NULL;

			EXEC sp_get_query_template
				@InputStatement, 
				@NormalizedOutput OUTPUT, 
				@ParametersOutput OUTPUT;

		END TRY 
		BEGIN CATCH 
			
			SELECT @errorMessage = N'Error Number: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N'. Message: ' + ERROR_MESSAGE();
			SELECT @NormalizedOutput = @InputStatement, @ErrorInfo = @errorMessage;
		END CATCH

	END; 

	RETURN 0;
GO