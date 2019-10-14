### Notes on Setting up Database Mail

For more information on setting up and configuring Database Mail, see the following post: [Configuring and Troubleshooting Database Mail](http://sqlmag.com/blog/configuring-and-troubleshooting-database-mail-sql-server). 

Then, once you've enabled Database Mail (and ensured that your SQL Server Agent - which isn't supported on Express Editions), you'll also need to create a new Operator. To create a new Operator:
- In SSMS, connect to your server. 
- Expand the SQL Server Agent > Operators node. 
- Right click on the Operators node and select the "New Operator..." menu option. 
- Provide a name for the operator (i.e., "Alerts"), then specify an email address (or, ideally, an ALIAS when sending to one or more people) in the "E-mail name" filed, then click OK. (All of the scheduling and time stuff is effectively for Pagers (remember those) - and can be completely ignored). 
- Go back into your SQL Server Agent properties (as per the article linked above), and specify that the Operator you just created will be the Fail Safe Operator - on the "Alerts System" page/tab. 
- 
For more information and best practices on setting up Operator (email addresses), see the following: [Database Mail Tip: Notifying Operators vs Sending Emails](http://sqlmag.com/blog/sql-server-database-mail-notifying-operators-vs-sending-emails).

**NOTE:** *By convention S4 Backups are written to use a Mail Profile name of "General" and an Operator Name of "Alerts" - but you can easily configure backups to use any profile name and/or operator name.*