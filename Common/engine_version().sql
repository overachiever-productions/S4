/*


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[engine_version]',  N'FN') IS NOT NULL
	DROP FUNCTION dbo.[engine_version];
GO

CREATE FUNCTION dbo.[engine_version] (@scope sysname = NULL)
RETURNS decimal(6,4)
AS
    
	-- {copyright}
    
    BEGIN; 

    	SET @scope = NULLIF(@scope, N'');
        
        -- Actual / Current (DEFAULT): 
        DECLARE @output decimal(6,4) = (
            SELECT CAST(PARSENAME(CAST(SERVERPROPERTY(N'ProductVersion') AS sysname), 4) + N'.' + PARSENAME(CAST(SERVERPROPERTY(N'ProductVersion') AS sysname), 2) AS decimal(6,4))
        );

        IF UPPER(@scope) = N'RTM' BEGIN
            SET @output = CASE (SELECT CAST(SERVERPROPERTY(N'ProductMajorVersion') AS int)) 
                WHEN 7 THEN 7.623
                WHEN 8 THEN 8.194
                WHEN 9 THEN 9.1399
                WHEN 10 THEN CASE (SELECT CAST(SERVERPROPERTY(N'ProductMinorVersion') AS int)) WHEN 0 THEN 8.1600 ELSE 5.1600 END -- magic numbers ... 10.5 is ... 5.xxxx
                WHEN 11 THEN 11.2100
                WHEN 12 THEN 12.2000
                WHEN 13 THEN 13.1601
                WHEN 14 THEN 14.1000
                WHEN 15 THEN 15.2000
                WHEN 16 THEN 16.1000
                WHEN 17 THEN 17.1000
                ELSE @output
            END;
        END;

        -- TODO: based on various @scope 'options' ... treat some versions as if they were greater. 
        --      e.g., if a DMV or setting/feature was released in 2016SP1 AND 2017... then ... for @scope of 'xxx_dmv' ... bump to 2017. etc. 

    	RETURN @output;
    END;
GO