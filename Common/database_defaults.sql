/*


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[database_defaults]', N'IF') IS NOT NULL
	DROP FUNCTION dbo.[database_defaults];
GO

CREATE FUNCTION dbo.[database_defaults] (@database_id int = 3)
RETURNS table
AS RETURN

	-- {copyright}

	WITH core AS ( 
		SELECT 
			[x].[database_id],
			[x].[version],
			[x].[default_name],
			[x].[default_value]
		FROM 
			(VALUES 
				(1, 17.1000, N'owner_sid', N'0x01'), 
				(1, 17.1000, N'compatibility_level', (SELECT CAST(SERVERPROPERTY(N'ProductMajorVersion') AS sysname)) + N'0'), 
				(1, 17.1000, N'collation_name', N'SQL_Latin1_General_CP1_CI_AS'), 
				(1, 17.1000, N'is_read_only', N'0'), 
				(1, 17.1000, N'is_auto_close_on', N'0'), 
				(1, 17.1000, N'is_auto_shrink_on', N'0'), 
				(1, 17.1000, N'is_supplemental_logging_enabled', N'0'), 
				(1, 17.1000, N'snapshot_isolation_state_desc', N'ON'), 
				(1, 17.1000, N'is_read_committed_snapshot_on', N'0'), 
				(1, 17.1000, N'recovery_model_desc', N'SIMPLE'), 
				(1, 17.1000, N'page_verify_option_desc', N'CHECKSUM'), 
				(1, 17.1000, N'is_auto_create_stats_on', N'1'), 
				(1, 17.1000, N'is_auto_create_stats_incremental_on', N'0'), 
				(1, 17.1000, N'is_auto_update_stats_on', N'1'), 
				(1, 17.1000, N'is_auto_update_stats_async_on', N'0'), 
				(1, 17.1000, N'is_ansi_null_default_on', N'0'), 
				(1, 17.1000, N'is_ansi_nulls_on', N'0'), 
				(1, 17.1000, N'is_ansi_padding_on', N'0'), 
				(1, 17.1000, N'is_ansi_warnings_on', N'0'), 
				(1, 17.1000, N'is_arithabort_on', N'0'), 
				(1, 17.1000, N'is_concat_null_yields_null_on', N'0'), 
				(1, 17.1000, N'is_numeric_roundabort_on', N'0'), 
				(1, 17.1000, N'is_quoted_identifier_on', N'0'), 
				(1, 17.1000, N'is_recursive_triggers_on', N'0'), 
				(1, 17.1000, N'is_cursor_close_on_commit_on', N'0'), 
				(1, 17.1000, N'is_local_cursor_default', N'0'), 
				(1, 17.1000, N'is_fulltext_enabled', N'0'), 
				(1, 17.1000, N'is_trustworthy_on', N'0'), 
				(1, 17.1000, N'is_db_chaining_on', N'1'), 
				(1, 17.1000, N'is_parameterization_forced', N'0'), 
				(1, 17.1000, N'is_master_key_encrypted_by_server', N'0'), 
				(1, 17.1000, N'is_query_store_on', N'0'), 
				(1, 17.1000, N'is_published', N'0'), 
				(1, 17.1000, N'is_subscribed', N'0'), 
				(1, 17.1000, N'is_merge_published', N'0'), 
				(1, 17.1000, N'is_distributor', N'0'), 
				(1, 17.1000, N'is_sync_with_backup', N'0'), 
				(1, 17.1000, N'is_broker_enabled', N'0'), 
				(1, 17.1000, N'log_reuse_wait_desc', N'NOTHING'), 
				(1, 17.1000, N'is_date_correlation_on', N'0'), 
				(1, 17.1000, N'is_cdc_enabled', N'0'), 
				(1, 17.1000, N'is_encrypted', N'0'), 
				(1, 17.1000, N'is_honor_broker_priority_on', N'0'), 
				(1, 17.1000, N'containment_desc', N'NONE'), 
				(1, 17.1000, N'target_recovery_time_in_seconds', N'0'), 
				(1, 17.1000, N'delayed_durability_desc', N'DISABLED'), 
				(1, 17.1000, N'is_memory_optimized_elevate_to_snapshot_on', N'0'), 
				(1, 17.1000, N'is_federation_member', N'0'), 
				(1, 17.1000, N'is_remote_data_archive_enabled', N'0'), 
				(1, 17.1000, N'is_mixed_page_allocation_on', N'1'), 
				(1, 17.1000, N'is_temporal_history_retention_enabled', N'1'), 
				(1, 17.1000, N'catalog_collation_type_desc', N'DATABASE_DEFAULT'), 
				(1, 17.1000, N'is_result_set_caching_on', N'0'), 
				(1, 17.1000, N'is_accelerated_database_recovery_on', N'0'), 
				(1, 17.1000, N'is_tempdb_spill_to_remote_store', N'0'), 
				(1, 17.1000, N'is_stale_page_detection_on', N'0'), 
				(1, 17.1000, N'is_memory_optimized_enabled', N'1'), 
				(1, 17.1000, N'is_data_retention_enabled', N'0'), 
				(1, 17.1000, N'is_ledger_on', N'0'), 
				(1, 17.1000, N'is_change_feed_enabled', N'0'), 
				(1, 17.1000, N'is_data_lake_replication_enabled', N'0'), 
				(1, 17.1000, N'is_event_stream_enabled', N'0'), 
				(1, 17.1000, N'data_compaction_desc', N'UNSUPPORTED'), 
				(1, 17.1000, N'data_lake_log_publishing_desc', N'UNSUPPORTED'), 
				(1, 17.1000, N'is_vorder_enabled', N'0'), 
				(1, 17.1000, N'is_proactive_statistics_refresh_on', N'0'), 
				(1, 17.1000, N'is_optimized_locking_on', N'0')
			) [x]([database_id], [version], [default_name], [default_value])
		
		UNION ALL

		SELECT 
			[x].[database_id],
			[x].[version],
			[x].[default_name],
			[x].[default_value]
		FROM (VALUES 
			(2, 17.1000, N'owner_sid', N'0x01'), 
			(2, 17.1000, N'compatibility_level', (SELECT CAST(SERVERPROPERTY(N'ProductMajorVersion') AS sysname)) + N'0'), 
			(2, 17.1000, N'collation_name', N'SQL_Latin1_General_CP1_CI_AS'), 
			(2, 17.1000, N'is_read_only', N'0'), 
			(2, 17.1000, N'is_auto_close_on', N'0'), 
			(2, 17.1000, N'is_auto_shrink_on', N'0'), 
			(2, 17.1000, N'is_supplemental_logging_enabled', N'0'), 
			(2, 17.1000, N'snapshot_isolation_state_desc', N'OFF'), 
			(2, 17.1000, N'is_read_committed_snapshot_on', N'0'), 
			(2, 17.1000, N'recovery_model_desc', N'SIMPLE'), 
			(2, 17.1000, N'page_verify_option_desc', N'CHECKSUM'), 
			(2, 17.1000, N'is_auto_create_stats_on', N'1'), 
			(2, 17.1000, N'is_auto_create_stats_incremental_on', N'0'), 
			(2, 17.1000, N'is_auto_update_stats_on', N'1'), 
			(2, 17.1000, N'is_auto_update_stats_async_on', N'0'), 
			(2, 17.1000, N'is_ansi_null_default_on', N'0'), 
			(2, 17.1000, N'is_ansi_nulls_on', N'0'), 
			(2, 17.1000, N'is_ansi_padding_on', N'0'), 
			(2, 17.1000, N'is_ansi_warnings_on', N'0'), 
			(2, 17.1000, N'is_arithabort_on', N'0'), 
			(2, 17.1000, N'is_concat_null_yields_null_on', N'0'), 
			(2, 17.1000, N'is_numeric_roundabort_on', N'0'), 
			(2, 17.1000, N'is_quoted_identifier_on', N'0'), 
			(2, 17.1000, N'is_recursive_triggers_on', N'0'), 
			(2, 17.1000, N'is_cursor_close_on_commit_on', N'0'), 
			(2, 17.1000, N'is_local_cursor_default', N'0'), 
			(2, 17.1000, N'is_fulltext_enabled', N'0'), 
			(2, 17.1000, N'is_trustworthy_on', N'0'), 
			(2, 17.1000, N'is_db_chaining_on', N'1'), 
			(2, 17.1000, N'is_parameterization_forced', N'0'), 
			(2, 17.1000, N'is_master_key_encrypted_by_server', N'0'), 
			(2, 17.1000, N'is_query_store_on', N'0'), 
			(2, 17.1000, N'is_published', N'0'), 
			(2, 17.1000, N'is_subscribed', N'0'), 
			(2, 17.1000, N'is_merge_published', N'0'), 
			(2, 17.1000, N'is_distributor', N'0'), 
			(2, 17.1000, N'is_sync_with_backup', N'0'), 
			(2, 17.1000, N'is_broker_enabled', N'1'), 
			(2, 17.1000, N'log_reuse_wait_desc', N'NOTHING'), 
			(2, 17.1000, N'is_date_correlation_on', N'0'), 
			(2, 17.1000, N'is_cdc_enabled', N'0'), 
			(2, 17.1000, N'is_encrypted', N'0'), 
			(2, 17.1000, N'is_honor_broker_priority_on', N'0'), 
			(2, 17.1000, N'containment_desc', N'NONE'), 
			(2, 17.1000, N'target_recovery_time_in_seconds', N'60'), 
			(2, 17.1000, N'delayed_durability_desc', N'DISABLED'), 
			(2, 17.1000, N'is_memory_optimized_elevate_to_snapshot_on', N'0'), 
			(2, 17.1000, N'is_federation_member', N'0'), 
			(2, 17.1000, N'is_remote_data_archive_enabled', N'0'), 
			(2, 17.1000, N'is_mixed_page_allocation_on', N'0'), 
			(2, 17.1000, N'is_temporal_history_retention_enabled', N'1'), 
			(2, 17.1000, N'catalog_collation_type_desc', N'DATABASE_DEFAULT'), 
			(2, 17.1000, N'is_result_set_caching_on', N'0'), 
			(2, 17.1000, N'is_accelerated_database_recovery_on', N'0'), 
			(2, 17.1000, N'is_tempdb_spill_to_remote_store', N'0'), 
			(2, 17.1000, N'is_stale_page_detection_on', N'0'), 
			(2, 17.1000, N'is_memory_optimized_enabled', N'1'), 
			(2, 17.1000, N'is_data_retention_enabled', N'0'), 
			(2, 17.1000, N'is_ledger_on', N'0'), 
			(2, 17.1000, N'is_change_feed_enabled', N'0'), 
			(2, 17.1000, N'is_data_lake_replication_enabled', N'0'), 
			(2, 17.1000, N'is_event_stream_enabled', N'0'), 
			(2, 17.1000, N'data_compaction_desc', N'UNSUPPORTED'), 
			(2, 17.1000, N'data_lake_log_publishing_desc', N'UNSUPPORTED'), 
			(2, 17.1000, N'is_vorder_enabled', N'0'), 
			(2, 17.1000, N'is_proactive_statistics_refresh_on', N'0'), 
			(2, 17.1000, N'is_optimized_locking_on', N'0')
		) [x]([database_id], [version], [default_name], [default_value])
		
		UNION ALL 
		
		SELECT 
			[x].[database_id],
			[x].[version],
			[x].[default_name],
			[x].[default_value]
		FROM (VALUES 
			(3, 17.1000, N'owner_sid', N'0x01'), 
			(3, 17.1000, N'compatibility_level', (SELECT CAST(SERVERPROPERTY(N'ProductMajorVersion') AS sysname)) + N'0'), 
			(3, 17.1000, N'collation_name', N'SQL_Latin1_General_CP1_CI_AS'), 
			(3, 17.1000, N'is_read_only', N'0'), 
			(3, 17.1000, N'is_auto_close_on', N'0'), 
			(3, 17.1000, N'is_auto_shrink_on', N'0'), 
			(3, 17.1000, N'is_supplemental_logging_enabled', N'0'), 
			(3, 17.1000, N'snapshot_isolation_state_desc', N'OFF'), 
			(3, 17.1000, N'is_read_committed_snapshot_on', N'0'), 
			(3, 17.1000, N'recovery_model_desc', N'FULL'), 
			(3, 17.1000, N'page_verify_option_desc', N'CHECKSUM'), 
			(3, 17.1000, N'is_auto_create_stats_on', N'1'), 
			(3, 17.1000, N'is_auto_create_stats_incremental_on', N'0'), 
			(3, 17.1000, N'is_auto_update_stats_on', N'1'), 
			(3, 17.1000, N'is_auto_update_stats_async_on', N'0'), 
			(3, 17.1000, N'is_ansi_null_default_on', N'0'), 
			(3, 17.1000, N'is_ansi_nulls_on', N'0'), 
			(3, 17.1000, N'is_ansi_padding_on', N'0'), 
			(3, 17.1000, N'is_ansi_warnings_on', N'0'), 
			(3, 17.1000, N'is_arithabort_on', N'0'), 
			(3, 17.1000, N'is_concat_null_yields_null_on', N'0'), 
			(3, 17.1000, N'is_numeric_roundabort_on', N'0'), 
			(3, 17.1000, N'is_quoted_identifier_on', N'0'), 
			(3, 17.1000, N'is_recursive_triggers_on', N'0'), 
			(3, 17.1000, N'is_cursor_close_on_commit_on', N'0'), 
			(3, 17.1000, N'is_local_cursor_default', N'0'), 
			(3, 17.1000, N'is_fulltext_enabled', N'0'), 
			(3, 17.1000, N'is_trustworthy_on', N'0'), 
			(3, 17.1000, N'is_db_chaining_on', N'0'), 
			(3, 17.1000, N'is_parameterization_forced', N'0'), 
			(3, 17.1000, N'is_master_key_encrypted_by_server', N'0'), 
			(3, 17.1000, N'is_query_store_on', N'1'), 
			(3, 17.1000, N'is_published', N'0'), 
			(3, 17.1000, N'is_subscribed', N'0'), 
			(3, 17.1000, N'is_merge_published', N'0'), 
			(3, 17.1000, N'is_distributor', N'0'), 
			(3, 17.1000, N'is_sync_with_backup', N'0'), 
			(3, 17.1000, N'is_broker_enabled', N'0'), 
			(3, 17.1000, N'log_reuse_wait_desc', N'NOTHING'), 
			(3, 17.1000, N'is_date_correlation_on', N'0'), 
			(3, 17.1000, N'is_cdc_enabled', N'0'), 
			(3, 17.1000, N'is_encrypted', N'0'), 
			(3, 17.1000, N'is_honor_broker_priority_on', N'0'), 
			(3, 17.1000, N'containment_desc', N'NONE'), 
			(3, 17.1000, N'target_recovery_time_in_seconds', N'60'), 
			(3, 17.1000, N'delayed_durability_desc', N'DISABLED'), 
			(3, 17.1000, N'is_memory_optimized_elevate_to_snapshot_on', N'0'), 
			(3, 17.1000, N'is_federation_member', N'0'), 
			(3, 17.1000, N'is_remote_data_archive_enabled', N'0'), 
			(3, 17.1000, N'is_mixed_page_allocation_on', N'1'), 
			(3, 17.1000, N'is_temporal_history_retention_enabled', N'1'), 
			(3, 17.1000, N'catalog_collation_type_desc', N'DATABASE_DEFAULT'), 
			(3, 17.1000, N'is_result_set_caching_on', N'0'), 
			(3, 17.1000, N'is_accelerated_database_recovery_on', N'0'), 
			(3, 17.1000, N'is_tempdb_spill_to_remote_store', N'0'), 
			(3, 17.1000, N'is_stale_page_detection_on', N'0'), 
			(3, 17.1000, N'is_memory_optimized_enabled', N'1'), 
			(3, 17.1000, N'is_data_retention_enabled', N'0'), 
			(3, 17.1000, N'is_ledger_on', N'0'), 
			(3, 17.1000, N'is_change_feed_enabled', N'0'), 
			(3, 17.1000, N'is_data_lake_replication_enabled', N'0'), 
			(3, 17.1000, N'is_event_stream_enabled', N'0'), 
			(3, 17.1000, N'data_compaction_desc', N'UNSUPPORTED'), 
			(3, 17.1000, N'data_lake_log_publishing_desc', N'UNSUPPORTED'), 
			(3, 17.1000, N'is_vorder_enabled', N'0'), 
			(3, 17.1000, N'is_proactive_statistics_refresh_on', N'0'), 
			(3, 17.1000, N'is_optimized_locking_on', N'0')
		) [x]([database_id], [version], [default_name], [default_value])
	) 

	SELECT 
		[default_name],
		[default_value] 
	FROM 
		[core]
	WHERE
		[database_id] = CASE 
			WHEN @database_id IS NULL THEN 3 
			WHEN @database_id > 3 THEN 3
			ELSE @database_id 
		END
		AND [version] <= dbo.[engine_version](N'RTM');
GO