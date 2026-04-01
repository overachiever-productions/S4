/*

		vNEXT: 
			MAY make sense to move this away from a dependency upon the admindb.
			i.e., get rid of the call to load_id_for_normalized_name and ... put in some better/more-specific (context-aware) errors. 
				e.g., run this and not the error (it's ... caller confuse): 
						DECLARE @TargetTable SYSNAME;
						DECLARE @outcome int;
						EXEC @outcome = [admindb].dbo.[eventstore_get_target_by_key]
							@EventStoreKey = N'PIGGLY',
							@TargetTable = @TargetTable OUTPUT;

						SELECT @outcome, @TargetTable;
			
			likewise, not sure I want any hard-dependencies upon admindb this/that/the-other.
			



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_get_target_by_key]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_get_target_by_key];
GO

CREATE PROC dbo.[eventstore_get_target_by_key]
	@EventStoreKey				sysname, 
	@TargetTable				sysname			OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	DECLARE @eventStoreTarget sysname = (SELECT [target_table] FROM [dbo].[eventstore_settings] WHERE [event_store_key] = @EventStoreKey); 
	DECLARE @outputID int;
	DECLARE @outcome int = 0;

	EXEC @outcome = dbo.[load_id_for_normalized_name]
		@TargetName = @eventStoreTarget,
		@ParameterNameForTarget = N'@eventStoreTarget',
		@NormalizedName = @TargetTable OUTPUT, 
		@ObjectID = @outputID OUTPUT;

	IF @outcome <> 0 
		RETURN @outcome; 

	IF @outputID IS NULL BEGIN
		RAISERROR(N'Specified [target_table] in dbo.eventstore_settings for [event_store_key] of [%] is invalid or could NOT be found.', 16, 1, @EventStoreKey);
		RETURN -100;
	END;

	RETURN 0;
GO
	