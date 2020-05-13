![](https://assets.overachiever.net/s4/images/s4_main_logo.png)

[S4 Docs Home](/readme.md) > [S4 APIs](/documentation/apis.md) > `dbo.check_database_consistency`

# dbo.check_database_consistency

## Table of Contents
- [Overview](#overview)
- [Syntax](#syntax)
- [Remarks](#remarks) 
- [Examples](#examples)
- [See Also](#see-also)

## Overview

<section style="visibility:hidden; display:none;">

**APPLIES TO:** :heavy_check_mark: Windows :heavy_check_mark: SQL Server 2008 / 2008 R2 :grey_question: SQL Server 2012+ :o: Linux :grey_question: Azure :grey_question: SQL Server Express / Web

:warning: Requires S4 Advanced Error Handling 

**S4 CONVENTIONS:** [ConventionX](/x/link-here), [ConventionY](etc), and [ConventionB](etc)

</section>

[Simple 'wrapper' for DBCC CHECKDB() - but provides 3x main benefits over 'raw' usage of DBCC CHECKDB: 


- It enables easy execution and targetting of all and/or specific databases. 
- It is correctly optimized to include the `WITH` `NO_INFOMSGS` and `ALL_ERRORMSGS` flags (which are critical to being able to properly 'size-up'/evaluate and respond to corruption when it occurs)
- It CAPTURES all outputs of DBCC CHECKDB while it is being executed and sends those details out as part of the alerts it will raise/send when it detects corruption. 


]



## Syntax

```

    dbo.check_database_consistency 
        @Targets
        @Exclusions
        @Priorities
        @IncludeExtendedLogicalChecks
        @OperatorName
        @MailProfileName
        @EmailSubjectPrefix
        @PrintOnly

```

<section style="visibility:hidden; display:none;">

### Arguments
`[ @objname = ] 'name'`
 Is the qualified or nonqualified name of a user-defined, schema-scoped object. Quotation marks are required only if a qualified object is specified. If a fully qualified name, including a database name, is provided, the database name must be the name of the current database. The object must be in the current database. *name* is **nvarchar(776)**, with no default.  
  
`[ @columnname = ] 'computed_column_name'`
 Is the name of the computed column for which to display definition information. The table that contains the column must be specified as *name*. *column_name* is **sysname**, with no default.  
 
 [Return to Table of Contents](#table-of-contents)
 
 ### Return Code Values 
  0 (success) or non-0 (failure)  
  
 ## Result Sets  
 

[Return to Table of Contents](#table-of-contents)

## Remarks

[Return to Table of Contents](#table-of-contents)

## Permissions 


## Examples

### A. Doing such and such
Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.
```sql

SELECT 'example stuff here';

```

### B. Doing blah blah

Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.
```sql

SELECT 'example stuff here';

```
Lacus vel facilisis volutpat est. Molestie a iaculis at erat pellentesque adipiscing. Non quam lacus suspendisse faucibus.


[Return to Table of Contents](#table-of-contents)

## See Also
- [best practices for such and such]()
- [related code/functionality]()

</section>

[Return to Table of Contents](#table-of-contents)

[S4 Docs Home](/readme.md) > [S4 APIs](/documentation/apis.md) > dbo.check_database_consistency