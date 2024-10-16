/*
	WARN: this is currently JUST a placeholder. 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_translate_error_token]','TF') IS NOT NULL
	DROP FUNCTION dbo.[eventstore_translate_error_token];
GO

CREATE FUNCTION dbo.[eventstore_translate_error_token] (@TokenName sysname)
RETURNS @output table (
	[error_id] int
) 
AS 
	-- {copyright}
    
    BEGIN; 
    	
		DECLARE @lookupString nvarchar(MAX) = N'1222, 1205, 1999';

		-- WARN: this is currently just a placeholder. 
    	
		-- either I can serialize the IDs out into a string and then SPLIT them (i.e., the @lookupString would be a query to look them up)
		--	or... i could pull "SELECT error_id FROM dbo.eventstore_error_token_ids WHERE token_name = @TokenName" and ... be done with things. 
    	INSERT INTO @output ([error_id])
    	SELECT CAST([result] AS int) FROM dbo.[split_string](@lookupString, N',', 1);
		
		RETURN;
    END;
GO