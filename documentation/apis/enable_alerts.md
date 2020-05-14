![](https://assets.overachiever.net/s4/images/s4_main_logo.png)

[S4 Docs Home](/readme.md) > [S4 APIs](/documentation/apis.md) > dbo.enable_alerts
# dbo.enable_alerts

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

Setup/Configuration script designed to make setup and configuration of Severity 17+ and IO/Corruption (623, 823, 824, 825) alerts trivial... 

]

## Syntax

```
    dbo.enable_alerts 
        @OperatorName = N'Alerts', 
        @AlertTypes = N'{ SEVERITY | IO | SEVERITY_AND_IO }', 
        @PrintOnly = { 0 | 1 }
    ;

```

### Arguments
*[DOCUMENTATION PENDING.]* 
 
 [Return to Table of Contents](#table-of-contents)
 
 ### Return Code Values 
  0 (success) or non-0 (failure)  
  
## Remarks

[Return to Table of Contents](#table-of-contents)

## Permissions 


## Examples

*[DOCUMENTATION PENDING.]* 

[Return to Table of Contents](#table-of-contents)

## See Also
*[DOCUMENTATION PENDING.]* 

[Return to Table of Contents](#table-of-contents)

[S4 Docs Home](/readme.md) > [S4 APIs](/documentation/apis.md) > dbo.enable_alerts