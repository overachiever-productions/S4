![](https://assets.overachiever.net/s4/images/s4_main_logo.png)

[S4 Docs Home](/readme.md) > [S4 APIs](/documentation/apis.md) > dbo.configure_instance(search and replace)

# dbo.configure_instance

## Table of Contents
- [Overview](#overview)
- [Syntax](#syntax)
- [Remarks](#remarks) 
- [Examples](#examples)
- [See Also](#see-also)

## Overview
**APPLIES TO:** :heavy_check_mark: Windows :heavy_check_mark: SQL Server 2008 / 2008 R2 :grey_question: SQL Server 2012+ :o: Linux :grey_question: Azure :grey_question: SQL Server Express / Web

**S4 CONVENTIONS:** [ConventionX](/x/link-here), [ConventionY](etc), and [ConventionB](etc)

[
S4 functionality aimed at helping to easily administer key SQL Server instance settings/configuration settings - i.e., `sys.configurations` / `sp_configure` settings.

Features that `dbo.configure_instance` will tackle/address: 
- It **ALWAYS** enables the DAC. 
- OPTIONAL: Allows for changing `cost threshold for parallelism`
- OPTIONAL: Allows for changing `max server memory` - in GBs 
- OPTIONAL: Allows for changing `optimize for ad hoc workloads`

] 

## Syntax

```
    dbo.configure_instance 
        [@MaxDOP = int, ]
        [@CostThresholdForParallelism = int, ]
        [@MaxServerMemoryGBs = int, ]
        [@OptimizeForAdhocWorkloads = bit ]
    ;  

```

### Arguments
*[DOCUMENTATION PENDING.]*
 
 [Return to Table of Contents](#table-of-contents)
 
 ### Return Code Values 
  0 (success) or non-0 (failure)  

## Remarks
[Always enabled DAC.]  

[Otherwise, only sets other specified values IF a) they're defined/provided as part of execution, and b) if they're NOT already set to the value specified. ]

[ONLY runs RECONFIGURE up to 1x (max) per execution.]

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

[Return to Table of Contents](#table-of-contents)

[S4 Docs Home](/readme.md) > [S4 APIs](/documentation/apis.md) > dbo.configure_instance