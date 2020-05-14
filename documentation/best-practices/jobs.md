![](https://assets.overachiever.net/s4/images/s4_main_logo.png)

[S4 Docs Home](/readme.md) > S4 and SQL Server Agent Jobs

# S4 and SQL Server Agent Jobs

<section style="visibility:hidden; display:none;">

    [NOTE TO SELF: I need to drop in some detailed (i.e., best practices) info on how to create SQL Server Agent Jobs. Specifically: why (to automate stuff) - and why S4 uses them (because they;re powerful and solid), how (owners, naming, categories, scheduling, steps and handling... (and advanced options/recommendations) and ... ALERTS/NOTIFICATIONS...  and so on. ARGUABLY, I _MIGHT_ want to document the absolute hell out of agent jobs on totalsql.com ... ]

</section>


## Table of Contents
- [Section Name Here](#section-name-here)
- [Another Section Name](#another-section-name)
- [Sample Table](#sample-table) 

## Section Name Here
Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Vulputate ut pharetra sit amet. Tortor posuere ac ut consequat. Interdum velit euismod in pellentesque. Duis at consectetur lorem donec massa. Lacus vel facilisis volutpat est. Molestie a iaculis at erat pellentesque adipiscing. Non quam lacus suspendisse faucibus. 

[Return to Table of Contents](#table-of-contents)

## Another Section Name
Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Vulputate ut pharetra sit amet. Tortor posuere ac ut consequat. Interdum velit euismod in pellentesque. Duis at consectetur lorem donec massa. Lacus vel facilisis volutpat est. Molestie a iaculis at erat pellentesque adipiscing. Non quam lacus suspendisse faucibus. 
1. Grab the `admindb_latest.sql` deployment script from the S4 [latest release](https://github.com/overachiever-productions/s4/releases/latest) page.
2. Execute the contents of the `admindb_latest.sql` file against your target server. 
3. The script will do everything necessary to create a new database, the `admindb`, and populate it with all S4 entities and code needed.

[Return to Table of Contents](#table-of-contents)

## Sample Table
If needed: 
 
|Column name|Data type|Description|    
| :-------- | :-------|:----------------------  |
|session_id|**smallint**|ID of the session to which this request is related. Is not nullable.| 
|request_id|**int**|ID of the request. Unique in the context of the session. Is not nullable.|  

[Return to Table of Contents](#table-of-contents)

[S4 Docs Home](/readme.md)