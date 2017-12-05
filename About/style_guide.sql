

/*------------------------------------------------------------------------------------------------------------------------------------------------------------

	S4 STYLE GUIDE

------------------------------------------------------------------------------------------------------------------------------------------------------------*/



--------------------------------------------
-- Object Names
--------------------------------------------

-- No Hungarian Notation - i.e., no 'tbl' or 'vw' or 'sprc'/'sp' prefixes for code/object types. 
--		however, defaults and other constraints should be named as DF_tableName_<column_name>[_optional_info] or PK_<table_name>


-- Snake Case:
--	e.g.
	dbo.user_details; 
	dbo.load_details_by_user_id;



--------------------------------------------
-- Parameters and Variables
--------------------------------------------

-- Parameters vs Variables:
--		parameters are passed into UDFs and Sprocs. Variables are simple 'holders' for logic/state within a block of code. 



-- Parametes are Pascal Case:
	@ParameterName;


-- variables are Camel Case:
	@variableNameHere;




