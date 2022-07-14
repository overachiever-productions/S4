/*


	vNEXT: 'Error Handling' - i.e., can't throw or indicate errors by means of 'side effects' but can ensure this thing doesn't bomb/crash.

	
		SELECT * FROM dbo.extract_matches(N'this is a string with the literal values ''is a'' in it.', N'is a', 10, N'')


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.extract_matches','TF') IS NOT NULL
	DROP FUNCTION dbo.extract_matches;
GO

CREATE FUNCTION dbo.extract_matches(@Input nvarchar(MAX), @Match nvarchar(MAX), @PaddingCharsCount int, @MatchWrapper nvarchar(MAX))
RETURNS @Matches table (match_id int IDENTITY NOT NULL, match_position int NOT NULL, [match] nvarchar(MAX) NOT NULL)
AS 
	BEGIN 
		
		SET @PaddingCharsCount = ISNULL(@PaddingCharsCount, 10);
		SET @MatchWrapper = ISNULL(@MatchWrapper, N'');

		DECLARE @start int; 
		DECLARE @end int; 
		DECLARE @matchLen int = LEN(@Match);
		DECLARE @currentMatch nvarchar(MAX);

		DECLARE @matchPosition int = 0;

		WHILE 1 = 1 BEGIN

			SELECT @matchPosition = CHARINDEX(@Match, @Input, @matchPosition);

			IF @matchPosition < 1 
				BREAK;
	
			SET @start = @matchPosition - @PaddingCharsCount;
			IF @start < 0 
				SET @start = 0;

			SET @end = @matchPosition + @matchLen + @PaddingCharsCount;
			IF @end > LEN(@Input) 
				SET @end = LEN(@Input);

			SELECT @currentMatch = SUBSTRING(@Input, @start, @end);

			INSERT INTO @Matches (
				[match_position],
				[match]
			)
			VALUES	(
				@matchPosition,
				@currentMatch
			)

			SET @matchPosition = @matchPosition + 1;

		END;

		IF NULLIF(@MatchWrapper, N'') IS NOT NULL BEGIN
			SET @MatchWrapper = REPLACE(@MatchWrapper, N'{0}', @Match); 

			UPDATE @Matches
			SET 
				[match] = REPLACE([match], @Match, @MatchWrapper)
			WHERE 
				[match] IS NOT NULL;

		END;

		RETURN;
	END; 
GO