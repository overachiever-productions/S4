

/*


DECLARE @ReturnValue int; 
DECLARE @OutputDate datetime;
DECLARE @Error nvarchar(max);

EXEC @ReturnValue = dbo.get_time_vector
	@Vector = N'1h', 
	@ParameterName = N'@Retention', 
	@Mode = N'Add',
	@Output = @OutputDate OUTPUT, 
	@Error = @Error OUTPUT;


SELECT @ReturnValue [ReturnValue], @OutputDate [date], @Error [Error];



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.get_time_vector','P') IS NOT NULL
	DROP PROC dbo.get_time_vector;
GO

CREATE PROC dbo.get_time_vector 
	@Vector					nvarchar(10)	= NULL, 
	@ParameterName			sysname			= NULL, 
	@AllowedIntervals		sysname			= N's,m,h,d,w,q,y',		-- s[econds], m[inutes], h[ours], d[ays], w[eeks], q[uarters], y[ears]  (NOTE: the concept of b[ackups] applies to backups only and is handled in dbo.remove_backup_files. Only time values are handled here.)
	@Mode					sysname			= N'SUBTRACT',			-- ADD | SUBTRACT
	@Output					datetime		= NULL		OUT, 
	@Error					nvarchar(MAX)	= NULL		OUT
AS 
	SET NOCOUNT ON; 

	-- {copyright}

	-- cleanup:
	SET @Vector = LTRIM(RTRIM(@Vector));
	SET @ParameterName = REPLACE(LTRIM(RTRIM((@ParameterName))), N'@', N'');

	DECLARE @vectorType nchar(1) = LOWER(RIGHT(@Vector, 1));

	-- Only approved values are allowed: (m[inutes], [h]ours, [d]ays, [b]ackups (a specific count)). 
	IF @vectorType NOT IN (SELECT [result] FROM dbo.split_string(@AllowedIntervals, N',')) BEGIN 
		SET @Error = N'Invalid @' + @ParameterName + N' value specified. @' + @ParameterName + N' must take the format of #x - where # is an integer, and x is a SINGLE letter which signifies s[econds], m[inutes], d[ays], w[eeks], q[uarters], y[ears]. Allowed Values Currently Available: [' + @AllowedIntervals + N'].';
		RETURN -10000;	
	END 

	-- a WHOLE lot of negation going on here... but, this is, insanely, right:
	IF NOT EXISTS (SELECT 1 WHERE LEFT(@Vector, LEN(@Vector) - 1) NOT LIKE N'%[^0-9]%') BEGIN 
		SET @Error = N'Invalid @' + @ParameterName + N' value specified (more than one non-integer value present). @' + @ParameterName + N' must take the format of #x - where # is an integer, and x is a SINGLE letter which signifies s[econds], m[inutes], d[ays], w[eeks], q[uarters], y[ears]. Allowed Values Currently Available: [' + @AllowedIntervals + N'].';
		RETURN -10001;
	END
	
	DECLARE @vectorValue int = CAST(LEFT(@Vector, LEN(@Vector) -1) AS int);

	IF @Mode = N'SUBTRACT' BEGIN
		IF @vectorType = 's'
			SET @Output = DATEADD(SECOND, 0 - @vectorValue, GETDATE());
		
		IF @vectorType = 'm'
			SET @Output = DATEADD(MINUTE, 0 - @vectorValue, GETDATE());

		IF @vectorType = 'h'
			SET @Output = DATEADD(HOUR, 0 - @vectorValue, GETDATE());

		IF @vectorType = 'd'
			SET @Output = DATEADD(DAY, 0 - @vectorValue, GETDATE());

		IF @vectorType = 'w'
			SET @Output = DATEADD(WEEK, 0 - @vectorValue, GETDATE());

		IF @vectorType = 'q'
			SET @Output = DATEADD(QUARTER, 0 - @vectorValue, GETDATE());

		IF @vectorType = 'y'
			SET @Output = DATEADD(YEAR, 0 - @vectorValue, GETDATE());
		
		IF @Output >= GETDATE() BEGIN; 
				SET @Error = N'Invalid @' + @ParameterName + N' specification. Specified value is in the future.';
				RETURN -10002;
		END;		
	  END;
	ELSE BEGIN

		IF @vectorType = 's'
			SET @Output = DATEADD(SECOND, @vectorValue, GETDATE());
		
		IF @vectorType = 'm'
			SET @Output = DATEADD(MINUTE, @vectorValue, GETDATE());

		IF @vectorType = 'h'
			SET @Output = DATEADD(HOUR, @vectorValue, GETDATE());

		IF @vectorType = 'd'
			SET @Output = DATEADD(DAY, @vectorValue, GETDATE());

		IF @vectorType = 'w'
			SET @Output = DATEADD(WEEK, @vectorValue, GETDATE());

		IF @vectorType = 'q'
			SET @Output = DATEADD(QUARTER, @vectorValue, GETDATE());

		IF @vectorType = 'y'
			SET @Output = DATEADD(YEAR, @vectorValue, GETDATE());

		IF @Output <= GETDATE() BEGIN; 
				SET @Error = N'Invalid @' + @ParameterName + N' specification. Specified value is in the past.';
				RETURN -10003;
		END;	

	END;

	RETURN 0;
GO