/*
	Enables the ability to pass 'lists' of results from one sproc/block-of-code to the other (without running into the nasty insert/exec limitation). 
	

*/

USE [admindb];
GO

IF TYPE_ID('dbo.enumeration') IS NOT NULL 
	DROP TYPE dbo.enumeration;
GO

CREATE TYPE dbo.enumeration AS TABLE (
	[id] int IDENTITY(1,1) NOT NULL, 
	[value] nvarchar(500)
); 
GO

IF TYPE_ID('dbo.bigint_enumeration') IS NOT NULL 
	DROP PROCEDURE IF EXISTS dbo.[querystore_variations_by_query_ids];

	EXEC('DROP TYPE dbo.bigint_enumeration;');
GO

CREATE TYPE dbo.bigint_enumeration AS TABLE (
	[id] int IDENTITY(1,1) NOT NULL, 
	[value] bigint NOT NULL
); 
GO