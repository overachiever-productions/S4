/*

    EXISTS _PRIMARILY_ as an abstraction around the fact that DATALENGTH of 'empty'/null XML MIGHT change from 5 to something else. 
        in which case... (i..e, if it does), this FN can then abstract-away those problems for ALL callers. 


    SAMPLES/TESTS: 

        -- expect 1 (i.e., is empty);
        
                    DECLARE @input xml = NULL;
                    SELECT dbo.is_xml_empty(@input);
                    GO

        -- expect 1 (i.e., is empty);

                    DECLARE @input xml = '';
                    SELECT dbo.is_xml_empty(@input);
                    GO

        -- expect 0 - NOT empty... 

                    DECLARE @input xml = ';';
                    SELECT dbo.is_xml_empty(@input);
                    GO

        -- expect 0 - NOT empty... 

                    DECLARE @input xml = '<default/>';
                    SELECT dbo.is_xml_empty(@input);
                    GO


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.is_xml_empty','FN') IS NOT NULL
	DROP FUNCTION dbo.[is_xml_empty];
GO

CREATE FUNCTION dbo.[is_xml_empty] (@input xml)
RETURNS bit
	--WITH RETURNS NULL ON NULL INPUT  -- note, this WORKS ... but... uh, busts functionality cuz we don't want NULL if empty, we want 1... 
AS
    
	-- {copyright}
    
    BEGIN; 
    	
    	DECLARE @output bit = 0;

        IF @input IS NULL   
            SET @output = 1;
    	
        IF DATALENGTH(@input) <= 5
    	    SET @output = 1;
    	
    	RETURN @output;
    END;
GO