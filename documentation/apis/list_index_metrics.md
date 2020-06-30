[README](/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedPath=README.md) > [S4 APIs](/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedPath=Documentation%2FAPIS.md) > `dbo.list_index_metrics`

## dbo.list_index_metrics

### Table of Contents <a name="table-of-contents"></a>
- [Application](#application)
- [Syntax](#syntax)
- [Remarks](#remarks)
- [Examples](#examples)
- [See Also](#see-also)


### Application 

| Platforms | SQL Server Versions | 
| :-------- | :-----------------  |
| :heavy_check_mark: Windows | :heavy_check_mark: SQL Server 2008 / 2008 R2 |
| :grey_question: Linux | :heavy_check_mark: SQL Server 2012+ |
| :grey_question: Azure |  :grey_question: SQL Server Express / Web |

:warning: Requires Advanced S4 Error Handling 

#### Conventions
- ~~Implements [S4 Caching](link-to-caching).~~
- Implements [Implied Context Targeting](link-to-convention) for `@TargetDatabase`.
- Implements [Wildcards](link-to-wildcards) for `@TargetTables` and `@ExcludedTables`.

[Return to Table of Contents](#table-of-contents)

### Syntax <a name="syntax"></a>
```sql

    EXEC [admindb].dbo.[list_index_metrics]
    	@TargetDatabase = NULL,
    	@TargetTables = N'',
    	@ExcludedTables = N'',
    	@ExcludeSystemTables = NULL,
    	@IncludeFragmentationMetrics = NULL,
    	@MinRequiredTableRowCount = 0,
    	@OrderBy = NULL

```

[Return to Table of Contents](#table-of-contents)

#### Arguments
**@TargetDatabase** `= NULL | N'name-of-database-to-run-against'`  
The database to process against. Can be left NULL/empty - in which case the admindb will determine/extract calling context - e.g., if you are connected to the `widgets` database and executed `admindb.dbo.list_index_metrics` without specifying a value for `@TargetDatabase`, the `@TargetDatabase` will be set/defined as the `widgets` database by virtue of S4's support for the [implied context targeting](link-to-convention) convention.  
`DEFAULT = NULL`.

**@TargetTables** `= NULL | N'names, of, tables, to, include, supports, wildc%rds`  
Can be used to filter/restrict results by the name of a single specified table, or a list of comma-delimited tables. Wildcards (for single or as part of multi-table limitations) are supported.     
When specified/populated - only tables MATCHING `@TargetTables` values will be displayed. 
When left NULL/empty, `dbo.list_index_metrics` will list metrics for all tables in the `@TargetDatabase` that are not, otherwise, removed by further parameters (such as `@MinRequiredTableRowCount` or `@ExcludeSystemTables`, etc.).  
`DEFAULT = NULL`.

**@ExcludedTables** `= NULL | N'names, of, tables, to, exclude`  
Inverse of `@TargetTables` - any tables (or lists/wildcards) of tables specified will be explicitly EXCLUDED.  
`DEFAULT = NULL`.

**@ExcludeSystemTables** `= 0 | 1 `  
Defines whether System tables should be excluded or not.  
`DEFAULT = 1` (true). 

**@IncludeFramentationMetrics** `= 0 | 1 `  
`DEFAULT = 0` (false).

**@MinRequiredTableRowCount** `= 0`  
**Integer.** When specified, only indexes/tables with RowCounts >= @MinRequiredTableRowCount will be displayed in the result set. 
`DEFAULT = 0`.

**@OrderBy** `= N' { ROW_COUNT | FRAGMENTATION | SIZE | BUFFER_SIZE | READS | WRITES } '`  
Specifies (DESCENDING) Sort Order for results set.  
`DEFAULT = N'ROW_COUNT'`

### Return Code Values 
  0 (success) or non-0 (failure)  
  
## Result Sets  
 
|Column name|Data type|Description|    
| :-------- | :-------|:----------------------  |
|table_name|**sysname**|Table-name for owner of specified index.| 
|index_name|**sysname**|Index name (if non-HEAP).|
|index_id|**int**|ID of Index - from `sys.indexes`|
|row_count|**int**|Total number of rows within IX or HEAP|
|definition|**nvarchar(MAX)**|Columns and [Included],[Columns] defining the IX|
|reads|**int**|Total number of reads aggregated from `sys.dm_index_usage_stats`.|
|writes|**int**|Total number of writes aggregated from `sys.dm_index_usage_stats`.|
|ratio|**decimal**|Ratio of `reads` / `writes` - higher numbers indicate more heavily beneficial indexes.|
|oprational_metrics|**xml**|vNEXT: will include metrics for `avg/max row_lock, page_lock, io_latch`, etc. metrics from `sys.dm_index_operational_stats` - currently 3x rows|
|[fragmentation_%]|**decimal**|Total percentage of IX fragmentation - from `sys.dm_db_index_physical_stats`.|
|[fragmentation_count]|**int**|Total fragment count - from `sys.dm_db_index_physical_stats`.|
|allocated_mb|**decimal**|Allocated size - in MBs.|
|used_mb|**decmial**|Size of space actively used by Index/Heap - in MBs.|
|cached_mb|**decimal**|Amount of IX/Heap (in MBs) currently in buffer cache.|
|seeks|**decimal**|Aggregated number of `user_seeks` - from `sys.dm_index_usage_stats`.|
|scans|**decimal**|Aggregated number of `user_scans` - from `sys.dm_index_usage_stats`.|
|lookups|**decimal**|Aggregated number of `user_lookups` - from `sys.dm_index_usage_stats`.|
|seek_ratio|**decimal**|Percentage of total `user` reads implemented as seeks.|


[Return to Table of Contents](#table-of-contents)

### Remarks <a name="remarks"></a>
#### Point 1

#### Point 2

[Return to Table of Contents](#table-of-contents)

### Examples <a name="examples"></a>
#### Example 1
#### Example 2

[Return to Table of Contents](#table-of-contents)

### See Also <a name="see-also"></a>
- [best practices for such and such]()
- [related code/functionality]()

[Return to Table of Contents](#table-of-contents)

[Return to README](/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedPath=README.md)

<style>
    div.stub { display: none; }
</style>
