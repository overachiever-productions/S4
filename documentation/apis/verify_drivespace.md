![](https://assets.overachiever.net/s4/images/s4_main_logo.png)

[S4 Docs Home](/readme.md) > [S4 APIs](/documentation/apis.md) > dbo.verify_drivespace

# dbo.verify_drivespace

## Table of Contents
- [Overview](#overview)
- [Syntax](#syntax)
- [Remarks](#remarks) 
- [Examples](#examples)
- [See Also](#see-also)

## Overview
**APPLIES TO:** :heavy_check_mark: Windows :heavy_check_mark: SQL Server 2008 / 2008 R2 :grey_question: SQL Server 2012+ :o: Linux :grey_question: Azure :grey_question: SQL Server Express / Web

**S4 CONVENTIONS:** [ConventionX](/x/link-here), [ConventionY](etc), and [ConventionB](etc)

[Pro-active monitoring and alerting of available drive-space - to prevent scenarios where dbs run out of disk.]

[TODO: note about how pre-sizing dbs can help mitigate running out of disk space - and/or make mention of this HERE (in intro), but have the 'discussion' down in ... REMARKS section.]

[TODO: similar to the above... point out (and reference/source) recommendation for 'contingency space' and ... provide links to it here?)]

## Syntax

```
    dbo.verify_drivespace [ @objname = ] 'name' [ , [ @columnname = ] computed_column_name ]  

```

### Arguments
`[ @objname = ] 'name'`
 Is the qualified or nonqualified name of a user-defined, schema-scoped object. Quotation marks are required only if a qualified object is specified. If a fully qualified name, including a database name, is provided, the database name must be the name of the current database. The object must be in the current database. *name* is **nvarchar(776)**, with no default.  
  
`[ @columnname = ] 'computed_column_name'`
 Is the name of the computed column for which to display definition information. The table that contains the column must be specified as *name*. *column_name* is **sysname**, with no default.  
 
 [Return to Table of Contents](#table-of-contents)
 
 ### Return Code Values 
  0 (success) or non-0 (failure)  
  
 ## Result Sets  
 
|Column name|Data type|Description|    
| :-------- | :-------|:----------------------  |
|session_id|**smallint**|ID of the session to which this request is related. Is not nullable.| 
|request_id|**int**|ID of the request. Unique in the context of the session. Is not nullable.|  

[Return to Table of Contents](#table-of-contents)

## Remarks

[Return to Table of Contents](#table-of-contents)

## Permissions 


## Examples

### A. Ad-Hoc Execution and Evaluation of Available Disk Space
Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.
```sql

SELECT 'example stuff here';

```

### B. Setting up Pro-Active Alerts

[Outline the entire process of setting/testing via @PrintOnly = 1, then show how to create a job with recurring schedule. And, obviously, don't showcase step-by-step on job creation HERE... link to ... best-practices doc on jobs and specify (here) that body/code/commands for step X (in the best-practices doc) should be set to... whatever it is that was defined above.]


[Return to Table of Contents](#table-of-contents)

## See Also
- [best practices for such and such]()
- [dbo.list_disks] (pending)

[Return to Table of Contents](#table-of-contents)

[S4 Docs Home](/readme.md) > [S4 APIs](/documentation/apis.md) > dbo.verify_drivespace