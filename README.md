# sql-server-index-maintenance

A stored proceedure for Microsoft SQL Server to perform basic index maintenance for all indexes within a database. A report is generated and emailed upon completion.

## proc_RunIndexMaintenance.sql

### Installation

Executing proc_RunIndexMaintenance.sql will install the stored procedure.

You **must** have Database Mail configured. By default, this script expects an account name of **Maintenance Mail Account**. See the EnableDBMail.sql script if you need assistance.

### Execution

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

### Sample Report

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

## proc_RunUpdateStatistics.sql

### Installation

Executing proc_RunUpdateStatistics.sql will install the stored procedure.

You **must** have Database Mail configured. By default, this script expects an account name of **Maintenance Mail Account**. See the EnableDBMail.sql script if you need assistance.

### Execution

````sql
EXECUTE dbo.proc_RunUpdateStatistics
 @p_DatabaseName = 'nameOfDatabase'
,@p_RecipientEmail = 'first.last@email.com'
,@p_MinimumIndexPageCountToUpdate = 1000
,@p_DaysSinceStatsUpdatedToForceUpdate = 30
,@p_IsDebug = 0
````

**@p_DatabaseName**

The name of the database to target

**@p_RecipientEmail**

The email address to deliver the maintenance report to. Target multiple email addresses by passing in a semicolon delimited list. 'first@email.com;second@email.com;third@email.com'

**@p_MinimumIndexPageCountToUpdate**

Specifies how many pages in size an index must be to be considered for updating

**@p_DaysSinceStatsUpdatedToForceUpdate**

Specifies how many days since an index's stats were last updated to be considered in need of updating

**@p_IsDebug**

Valid options are:
* 0 - Do not include additional information about the operation in the email report
* 1 - Include additional information about the operation in the email report

### Sample Report

<pre>Subject: SampServer SampDB Statistics Report
Statistics Maintenance Sproc report for server SampServer on database: SampDB
Finished querying for statistics in need of update. Started At: 2022-03-15 15:15:47 Ended At: 2022-03-15 15:15:47 Took 0 seconds
Updated statistics with full scan: [dbo].[Customer].[IX_Customer_CustomerID]
...was previously updated on 2020-11-04 11:14:21, table had 85573 rows at time of last update, and table now has 100799 rows.
Updated statistics with full scan: [dbo].[Order].[IX_Order_Sku]
...was previously updated on 2022-01-03 14:23:32, table had 7729 rows at time of last update, and table now has 16448 rows.
Started At: 2022-03-15 15:15:47 Ended At: 2022-03-15 15:15:47 Total Execution Time in Minutes: 0
</pre>