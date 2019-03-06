
/*


*/

USE [admindb];
GO


IF OBJECT_ID('dbo.get_vector','P') IS NOT NULL
	DROP PROC dbo.get_vector;
GO

CREATE PROC dbo.get_vector
	@Vector							nvarchar(10)		= NULL, 
	@ParameterName					sysname				= NULL, 
	@AllowedIntervals				sysname				= N's,m,h,d,w,q,y',
	@DatePart						sysname				= N'MILLISECOND',			-- { MILLISECONDS | SECONDS | MINUTES | HOURS | DAYS | WEEKS | QUARTERS | YEARS }
	@Difference						int					= NULL		OUT, 
	@Error							nvarchar(MAX)		= NULL		OUT
AS 
	SET NOCOUNT ON; 

	-- {copyright} 

	-----------------------------------------------------------------------------
	-- Validate Inputs:


	--  make sure @DatePart is a legit 'DATEPART'.... 


	-- cleanup:
	SET @Vector = LTRIM(RTRIM(@Vector));
	SET @ParameterName = REPLACE(LTRIM(RTRIM((@ParameterName))), N'@', N'');

	DECLARE @vectorType nchar(1) = LOWER(RIGHT(@Vector, 1));

	-- Only approved values are allowed: (m[inutes], [h]ours, [d]ays, [b]ackups (a specific count)). 
	IF @vectorType NOT IN (SELECT REPLACE([result], N' ', '') FROM dbo.split_string(@AllowedIntervals, N',', 1)) BEGIN 
		SET @Error = N'Invalid @' + @ParameterName + N' value specified. @' + @ParameterName + N' must take the format of #x - where # is an integer, and x is a SINGLE letter which signifies s[econds], m[inutes], d[ays], w[eeks], q[uarters], y[ears]. Allowed Values Currently Available: [' + @AllowedIntervals + N'].';
		RETURN -10000;	
	END;

	-- a WHOLE lot of negation going on here... but, this is, insanely, right:
	IF NOT EXISTS (SELECT 1 WHERE LEFT(@Vector, LEN(@Vector) - 1) NOT LIKE N'%[^0-9]%') BEGIN 
		SET @Error = N'Invalid @' + @ParameterName + N' value specified (more than one non-integer value present). @' + @ParameterName + N' must take the format of #x - where # is an integer, and x is a SINGLE letter which signifies s[econds], m[inutes], d[ays], w[eeks], q[uarters], y[ears]. Allowed Values Currently Available: [' + @AllowedIntervals + N'].';
		RETURN -10001;
	END;

	-----------------------------------------------------------------------------
	-- Processing: 
	DECLARE @vectorValue int = CAST(LEFT(@Vector, LEN(@Vector) -1) AS int);
	DECLARE @now datetime = GETDATE();

	DECLARE @datetime datetime;
	DECLARE @datePartForVector sysname;

	SELECT @datePartForVector = [datepart] FROM (VALUES  ('s', 'SECOND'), ('m', 'MINUTE'), ('h', 'HOUR'), ('d', 'DAY'), ('w', 'WEEK'), ('q', 'QUARTER'), ('y', 'YEAR') ) x (vector, [datepart]) WHERE x.[vector] = @vectorType;

	BEGIN TRY 

		DECLARE @command nvarchar(400) = N'SELECT @Difference = DATEDIFF(' + @DatePart + ', @now, (DATEADD(' + @datePartForVector + ', ' + CAST(@vectorValue AS sysname) + N', @now)));';
		EXEC sys.[sp_executesql] 
			@command, 
			N'@now datetime, @datetime datetime, @Difference int OUTPUT',
			@now = @now, 
			@datetime = @datetime, 
			@Difference = @Difference OUTPUT;

	END TRY 
	BEGIN CATCH 
		SELECT @Error = N'EXCEPTION: ' + CAST(ERROR_MESSAGE() AS sysname) + N' - ' + ERROR_MESSAGE();
	END CATCH;
		
	RETURN 0;
GO

