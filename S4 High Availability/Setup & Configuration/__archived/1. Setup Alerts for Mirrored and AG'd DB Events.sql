

/*
	NOTES:
		- By setting message 1480 to use the WITH_LOG argument/option, we drastically simplify the detection of mirroring failover operations.
			Because, now, the SQL Server Agent can detect (trap) and report on a Role Change occuring on both the Principal and Secondary servers
				(meaning that we can run code on both servers to enable/disable jobs and verify that a newly promoted Principal database is 
					totally ready to run/operate).

*/




-- Modify ErrorID 1480 so that it is written to the SQL Server Logs whenever it happens (so that we can set up an alert for it):
EXEC master..sp_altermessage
	@message_id = 1480, 
    @parameter = 'WITH_LOG', 
    @parameter_value = TRUE;
GO

-- HARD-CODED for english:
SELECT * FROM master.sys.messages WHERE language_id = 1033 AND message_id IN (1440, 1480);
GO
