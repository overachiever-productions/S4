


















- Listing Databases. dbo.list_ databases (which doesn't exist yet - but is just a wrapper that 'consumes + projects' the contents of dob.list_ databases). And show how we can easily exclude and/or prioritize them. 
- loading/iterating over databases. dbo.load_ databases. and why you'd use it... to get around the whole, stupid, insert exec... and .. maybe showcase/explain WHY load_databases even needs anything like this lame-ass work-around. (Truth is MAYBE it's time to 'split' the logic that loads dbs from the FILE system OUT of dbo.list_databases and have dbo.load_databases be the one that does the pull from file system processing.) That would result in WAY better factors. YEah. do this. Just have to see what, inside of dbo.load_databases (today) is necessitating INSERT EXEC stuff... And, another idea/option MIGHT be that dbo.load_databases is ONLY for loading from the file system AND it ONLY allows a PATH as the main argument - no priorities, no excusions, and so on - with the idea that if we're doing someting like dbo.restore_db. and we get [READ_FROM_FILE_SYSTEM] we convert that 'token' into a 'list' of dbs in the form of @serializedOutput, and then that 'list' gets passed into dbo.list_databases... that way i've got the same 'magic' - but WAY better factors and useability - as the only time I'd have to worry about deserializing db names would be from dbo.load_databases.