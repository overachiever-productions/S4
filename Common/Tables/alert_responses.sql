/*

	vNEXT: Currently the only 'response' is '[IGNORE]'... but eventually there will at least 2 more types of responses: 
		- '[EXECUTE]: statement' (where we execute the statement defined in 'statement') - which could be something like 'dump the output of this DMV into a such and such... or run such and such sproc which will do some other stuff, and so on... 
		- '[ALLOW # in (span)]' ... where we could specifiy something like 2 in 2m or whatever... and if it goes > than that... we raise an alert. (this'll take state management of some sorts and... logic around when to alert and when alerts have been sent).


		

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.alert_responses','U') IS NULL BEGIN

	CREATE TABLE dbo.alert_responses (
		alert_id int IDENTITY(1,1) NOT NULL, 
		message_id int NOT NULL, 
		response nvarchar(2000) NOT NULL, 
		is_s4_response bit NOT NULL CONSTRAINT DF_alert_responses_s4_response DEFAULT (0),
		is_enabled bit NOT NULL CONSTRAINT DF_alert_responses_is_enabled DEFAULT (1),
		notes nvarchar(1000) NULL, 
		CONSTRAINT PK_alert_responses PRIMARY KEY NONCLUSTERED ([alert_id])
	);

	CREATE CLUSTERED INDEX CLIX_alert_responses_by_message_id ON dbo.[alert_responses] ([message_id]);

	SET NOCOUNT ON;

	INSERT INTO [dbo].[alert_responses] ([message_id], [response], [is_s4_response], [notes])
	VALUES 
	(7886, N'[IGNORE]', 1, N'A read operation on a large object failed while sending data to the client. Example of a common-ish error you MAY wish to ignore, etc. '), 
	(17806, N'[IGNORE]', 1, N'SSPI handshake failure '),  -- TODO: configure for '[ALLOW # in (span)]'
	(18056, N'[IGNORE]', 1, N'The client was unable to reuse a session with SPID ###, which had been reset for connection pooling. The failure ID is 8. ');			-- TODO: configure for '[ALLOW # in (span)]'
END;
GO

IF NOT EXISTS (SELECT NULL FROM [dbo].[alert_responses] WHERE [message_id] = 4014)
	INSERT INTO [dbo].[alert_responses] ([message_id], [response], [is_s4_response], [is_enabled], [notes])
	VALUES	(4014, N'[IGNORE]', 1, 1, N'A fatal error occurred while reading the input stream from the network. The session will be terminated.');

--IF NOT EXISTS (SELECT NULL FROM [dbo].[alert_responses] WHERE [message_id] = 17828)
--	INSERT INTO [dbo].[alert_responses] ([message_id], [response], [is_s4_response], [is_enabled], [notes])
--	VALUES	(17810, N'[IGNORE]', 1, 1, N'Could not connect because the maximum number of '1' dedicated administrator connections already exists. Before a new connection can be made, the existing dedicated administrator connection must be dropped, either by logging off or ending the process.');

IF NOT EXISTS (SELECT NULL FROM [dbo].[alert_responses] WHERE [message_id] = 17828)
	INSERT INTO [dbo].[alert_responses] ([message_id], [response], [is_s4_response], [is_enabled], [notes])
	VALUES	(17828, N'[IGNORE]', 1, 1, N'The prelogin packet used to open the connection is structurally invalid; the connection has been closed. Please contact the vendor of the client library.');

IF NOT EXISTS (SELECT NULL FROM [dbo].[alert_responses] WHERE [message_id] = 17836)
	INSERT INTO [dbo].[alert_responses] ([message_id], [response], [is_s4_response], [is_enabled], [notes])
	VALUES	(17832, N'[IGNORE]', 1, 1, N'The login packet used to open the connection is structurally invalid; the connection has been closed. Please contact the vendor of the client library. ');

IF NOT EXISTS (SELECT NULL FROM [dbo].[alert_responses] WHERE [message_id] = 17836)
	INSERT INTO [dbo].[alert_responses] ([message_id], [response], [is_s4_response], [is_enabled], [notes])
	VALUES	(17836, N'[IGNORE]', 1, 1, N'Length specified in network packet payload did not match number of bytes read; the connection has been closed. Please contact the vendor of the client library.');

IF NOT EXISTS (SELECT NULL FROM [dbo].[alert_responses] WHERE [message_id] = 17835)
	INSERT INTO [dbo].[alert_responses] ([message_id], [response], [is_s4_response], [is_enabled], [notes])
	VALUES	(17835, N'[IGNORE]', 1, 1, N'Encryption is required to connect to this server but the client library does not support encryption; the connection has been closed. Please upgrade your client library.');

GO