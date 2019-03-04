# sql-server-index-maintenance

A stored proceedure for Microsoft SQL Server to perform basic index maintenance for all indexes within a database. A report is generated and emailed upon completion.

## Installation

Executing proc_RunIndexMaintenance.sql will install the stored procedure.

You **must** have Database Mail configured. By default, this script expects an account name of **Maintenance Mail Account**. See the EnableDBMail.sql script if you need assistance.

## Execution

````sql
EXECUTE dbo.proc_RunIndexMaintenance
 @p_DatabaseName = 'nameOfDatabase'
,@p_RecipientEmail = 'first.last@email.com'
,@p_RebuildMode = 'Mixed'
,@p_IsDebug = 0
````

**@p_DatabaseName**

The name of the database to target

**@p_RecipientEmail**

The email address to deliver the maintenance report to. Target multiple email addresses by passing in a semicolon delimited list. 'first@email.com;second@email.com;third@email.com'

**@p_RebuildMode**

Specifies how indexes should be rebuilt with regard to availablility. Valid options are
* OnlineOnly - Only maintain indexes which can be rebuilt with online mode
* OfflineOnly - Rebuild all indexes offline, even if they can be rebuilt online
* Mixed - Rebuild indexes online which can be rebuilt online, all others are rebuilt offline. This is the recommended mode.

**@p_IsDebug**

Valid options are:
* 0 - Do not include additional information about the operation in the email report
* 1 - Include additional information about the operation in the email report

## Sample Report

<pre>Subject: SampServer SampDB Index Report
Index Maintenance Sproc report for server SampServer on database: SampDB
Finished querying for index information. Started At: 2019-03-03 02:00:00 Ended At: 2019-03-03 02:02:32 Took 2 seconds
Rebuilt Index: [dbo].[Customer].[IX_Customer_CustomerID]
...was 45.1696 percent fragmented.
Reorganized Index: [dbo].[Contact].[IX_Contact_Email]
...was 7.96653 percent fragmented.
Reorganized Index: [dbo].[Order].[IX_Order_Sku]
...was 5.01085 percent fragmented.
Started At: 2019-03-03 02:00:00. Ended At: 2019-03-03 02:04:24. Total Execution Time in Minutes: 4</pre>