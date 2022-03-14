--------------------------------------------------------------------------------
--
-- Author: TechSmith Corporation
-- License: MIT
-- Repository: https://github.com/TechSmith/sql-server-index-maintenance
--
-- Creates (or alters) a stored procedure intended to do basic index statistics 
-- maintenance for all indexes in need of maintenance against a given database.
--
-- When the script completes, a report is generated and sent via Database Mail.
-- Database Mail requires configuration before this script can be executed.
--
-- This script has been verified to work on the following versions of SQL Server:
-- 2008R2
--
-- execute the stored procedure with the following command:
-- EXECUTE dbo.proc_RunUpdateStatistics
--     @p_DatabaseName = 'nameOfDatabase'
--    ,@p_RecipientEmail = 'first.last@email.com'
--    ,@p_MinimumTableRowCountToUpdate = 1000
--    ,@p_IsDebug = 0
--
--  Enabling IsDebug will cause additional information to be included in the email report.
--
--------------------------------------------------------------------------------
IF OBJECT_ID( 'dbo.proc_RunUpdateStatistics', 'P' ) IS NULL
   EXECUTE( 'CREATE PROCEDURE dbo.proc_RunUpdateStatistics AS SET NOCOUNT ON;' )
GO

ALTER PROCEDURE dbo.proc_RunUpdateStatistics
    @p_DatabaseName AS SYSNAME
   ,@p_RecipientEmail AS NVARCHAR( 256 )
   ,@p_MinimumTableRowCountToUpdate AS BIGINT
   ,@p_IsDebug AS BIT
AS
DECLARE
    @v_StaleStatisticsCutoffTime DATETIME2(0) = DATEADD(DAY, -30, GETDATE())
   ,@v_GetTablesCmd NVARCHAR(MAX)
   ,@v_GetStaleStatisticsCmd NVARCHAR(MAX)
   ,@v_EmailReport AS NVARCHAR( MAX )
   ,@v_EmailSubject AS NVARCHAR( 255 )
   ,@v_QueriesExecuted AS NVARCHAR( MAX )
   ,@v_NewLine AS CHAR(2) = CHAR(13)+CHAR(10)
   ,@v_OperationStartTime AS DATETIME2(0)
   ,@v_OperationStopTime AS DATETIME2(0);

DECLARE @v_DatabaseTablesTable AS TABLE
   (
      DatabaseTableId INT IDENTITY( 1,1 )
      ,SchemaName SYSNAME
      ,TableName SYSNAME
   );

DECLARE @v_RowCountsTable AS TABLE
   (
      SchemaName SYSNAME
      ,TableName SYSNAME
      ,TableRowCount BIGINT
   );

-- Table variable to store the statistics that are in need of maintenance
DECLARE @v_StaleStatisticsInformationTable AS TABLE
   (  
       StatisticsMaintenanceId INT IDENTITY( 1,1 )
      ,SchemaName SYSNAME
      ,TableName SYSNAME
      ,IndexName SYSNAME NULL -- Heaps do not have an index name
      ,StatsLastUpdatedTime DATETIME2(0)
      ,RowCountOnLastStatsUpdate BIGINT
   );

DECLARE @v_StaleStatisticsInformationWithRowCountTable AS TABLE
   (  
       StatisticsMaintenanceId INT IDENTITY( 1,1 )
      ,SchemaName SYSNAME
      ,TableName SYSNAME
      ,IndexName SYSNAME NULL -- Heaps do not have an index name
      ,StatsLastUpdatedTime DATETIME2(0)
      ,RowCountOnLastStatsUpdate BIGINT
      ,CurrentTableRowCount BIGINT
   );

BEGIN
   SET @v_StartTime = GETDATE();
   SELECT @v_EmailReport = 'Statistics Maintenance Sproc report for server ' + @@SERVERNAME + ' on database: ' + @p_DatabaseName;
   SELECT @v_EmailSubject = @@SERVERNAME + ' ' + @p_DatabaseName + ' Statistics Report';

   -- Enabling debugging mode for additional details in email report
   IF @p_IsDebug <> 1 AND @p_IsDebug <> 0
      SET @p_IsDebug = 0
   SET @v_QueriesExecuted = '';

   -- Before doing anything, validate that the database exists.  This should
   -- prevent any SQL Injection attacks
   IF DB_ID( @p_DatabaseName ) IS NULL
   BEGIN
      SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Database not found: ' + @p_DatabaseName;
      GOTO done;
   END;

   SET @v_GetTablesCmd = '
      SELECT
         t.TABLE_SCHEMA AS SchemaName
         ,t.TABLE_NAME AS TableName
      FROM
         ['+ @p_DatabaseName +'].INFORMATION_SCHEMA.TABLES AS t
      WHERE
         t.TABLE_TYPE = ''BASE TABLE''';

   SET @v_OperationStartTime = GETDATE();

   BEGIN TRY
      INSERT INTO @v_DatabaseTablesTable EXECUTE sp_executesql @v_GetTablesCmd;
   END TRY
   BEGIN CATCH
      SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Failed to query database tables due to exception: ' + @v_NewLine + ERROR_MESSAGE();
      GOTO done;
   END CATCH;

   SET @v_OperationStopTime = GETDATE();

   SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Finished querying for database tables. ' + 'Started At: ' + CAST( @v_OperationStartTime AS VARCHAR(20) ) + ' Ended At: ' + CAST( @v_OperationStopTime AS VARCHAR(20) ) + ' Took ' + CAST( DATEDIFF( SECOND, @v_OperationStartTime, @v_OperationStopTime ) AS VARCHAR(20) )  + ' seconds';
   SELECT @v_QueriesExecuted = @v_QueriesExecuted + @v_NewLine + @v_NewLine + 'Get tables command: ' + @v_GetTablesCmd;

   DECLARE
      @v_CurCountSchema AS SYSNAME
      ,@v_CurCountTable AS SYSNAME
      ,@v_GetRowCountCmd AS NVARCHAR(MAX)
      ,@v_RowCountCounter AS SMALLINT
      ,@v_DatabaseTablesLastRow AS SMALLINT

   SET @v_RowCountCounter = 1;
   SELECT @v_DatabaseTablesLastRow = COUNT(1) FROM @v_DatabaseTablesTable;

   SET @v_OperationStartTime = GETDATE();

   WHILE ( @v_RowCountCounter <= @v_DatabaseTablesLastRow )
   BEGIN
      SELECT
         @v_CurCountSchema = d.SchemaName
         ,@v_CurCountTable = d.TableName
      FROM
         @v_DatabaseTablesTable AS d
      WHERE
         d.DatabaseTableId = @v_RowCountCounter;

      SET @v_GetRowCountCmd = '
         SELECT
            ''' + @v_CurCountSchema + ''' AS SchemaName
            ,''' + @v_CurCountTable + ''' AS TableName
            ,COUNT(1) AS TableRowCount
         FROM
            ['+ @p_DatabaseName +'].['+ @v_CurCountSchema +'].['+ @v_CurCountTable +']';

      BEGIN TRY
         INSERT INTO @v_RowCountsTable EXECUTE sp_executesql @v_GetRowCountCmd;
         SELECT @v_QueriesExecuted = @v_QueriesExecuted + @v_NewLine + @v_NewLine + 'Get table row count command: ' + @v_GetRowCountCmd;
      END TRY
      BEGIN CATCH
         SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Failed to query table row count for ' + @v_CurCountSchema + '.' + @v_CurCountTable + ': ' + @v_NewLine + ERROR_MESSAGE();
         GOTO done;
      END CATCH;

      SET @v_RowCountCounter = @v_RowCountCounter + 1;
   END;

   SET @v_OperationStopTime = GETDATE();

   SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Finished querying for table row counts. ' + 'Started At: ' + CAST( @v_OperationStartTime AS VARCHAR(20) ) + ' Ended At: ' + CAST( @v_OperationStopTime AS VARCHAR(20) ) + ' Took ' + CAST( DATEDIFF( SECOND, @v_OperationStartTime, @v_OperationStopTime ) AS VARCHAR(20) )  + ' seconds';

   SET @v_GetStaleStatisticsCmd = '
      SELECT
         s.name AS SchemaName
         ,o.name AS TableName
         ,i.name AS IndexName
         ,stats_props.last_updated AS StatsLastUpdatedTime
         ,stats_props.unfiltered_rows AS RowCountOnLastStatsUpdate
      FROM
         ['+ @p_DatabaseName +'].sys.stats AS stats
      INNER JOIN
         ['+ @p_DatabaseName +'].sys.objects AS o ON o.object_id = stats.object_id
      INNER JOIN
         ['+ @p_DatabaseName +'].sys.schemas AS s ON s.schema_id = o.schema_id
      INNER JOIN
         ['+ @p_DatabaseName +'].sys.indexes AS i ON i.object_id = o.object_id AND stats.stats_id = i.index_id -- Stats ID corresponds to index ID when stats are for an index
      INNER JOIN
         ['+ @p_DatabaseName +'].INFORMATION_SCHEMA.TABLES AS t ON t.TABLE_SCHEMA = s.name AND t.TABLE_NAME = o.name AND t.TABLE_TYPE = ''BASE TABLE'' -- Remove system tables from list
      CROSS APPLY
         ['+ @p_DatabaseName +'].sys.dm_db_stats_properties(o.object_id, stats.stats_id) AS stats_props
      WHERE
         i.auto_created = 0
      AND
         stats.auto_created = 0
      AND
         (stats_props.last_updated IS NULL
      OR
         stats_props.last_updated <= @v_StaleStatisticsCutoffTime)
      ORDER BY
         stats_props.last_updated
      ASC';

   SET @v_OperationStartTime = GETDATE();

   BEGIN TRY
      INSERT INTO @v_StaleStatisticsInformationTable EXECUTE sp_executesql @v_GetStaleStatisticsCmd
      ,N'@v_StaleStatisticsCutoffTime DATETIME2(0)'
      ,@v_StaleStatisticsCutoffTime = @v_StaleStatisticsCutoffTime;
   END TRY
   BEGIN CATCH
      SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Failed to query statistics in need of update: ' + @v_NewLine + ERROR_MESSAGE();
      GOTO done;
   END CATCH;

   SELECT @v_QueriesExecuted = @v_QueriesExecuted + @v_NewLine + @v_NewLine + 'Get stale statistics info command: ' + @v_GetStaleStatisticsCmd;

   INSERT INTO @v_StaleStatisticsInformationWithRowCountTable
      SELECT
         s.SchemaName
         ,s.TableName
         ,s.IndexName
         ,s.StatsLastUpdatedTime
         ,s.RowCountOnLastStatsUpdate
         ,r.TableRowCount
      FROM
         @v_StaleStatisticsInformationTable AS s
      INNER JOIN
         @v_RowCountsTable AS r ON r.SchemaName = s.SchemaName AND r.TableName = s.TableName
      -- Skip tables that have very few rows, as updated stats will matter much less
      WHERE
         r.TableRowCount >= @p_MinimumTableRowCountToUpdate

   SET @v_OperationStopTime = GETDATE();

   SELECT @v_QueriesExecuted = @v_QueriesExecuted + @v_NewLine + @v_NewLine + 'Joined stale statistics info with table row counts';

   SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Finished querying for statistics in need of update. ' + 'Started At: ' + CAST( @v_OperationStartTime AS VARCHAR(20) ) + ' Ended At: ' + CAST( @v_OperationStopTime AS VARCHAR(20) ) + ' Took ' + CAST( DATEDIFF( SECOND, @v_OperationStartTime, @v_OperationStopTime ) AS VARCHAR(20) )  + ' seconds';

   DECLARE
      @v_CurSchema AS SYSNAME
      ,@v_CurTable AS SYSNAME
      ,@v_CurIndex AS SYSNAME
      ,@v_CurStatsLastUpdatedTime AS DATETIME2(0)
      ,@v_CurRowCountOnLastStatsUpdate AS BIGINT
      ,@v_CurCurrentRowCount AS BIGINT
      ,@v_Counter AS SMALLINT
      ,@v_LastRow AS SMALLINT
      ,@v_UpdateStatisticsCmd AS NVARCHAR(MAX)

   SET @v_Counter = 1;
   SELECT @v_LastRow = COUNT(1) FROM @v_StaleStatisticsInformationWithRowCountTable;

   -- Loop through the statistics and force a full scan
   WHILE ( @v_Counter <= @v_LastRow )
   BEGIN
      SELECT
         @v_CurSchema = '[' + s.SchemaName + ']'
         ,@v_CurTable = '[' + s.TableName + ']'
         ,@v_CurIndex = '[' + s.IndexName + ']'
         ,@v_CurStatsLastUpdatedTime = s.StatsLastUpdatedTime
         ,@v_CurRowCountOnLastStatsUpdate = s.RowCountOnLastStatsUpdate
         ,@v_CurCurrentRowCount = s.CurrentTableRowCount
      FROM
         @v_StaleStatisticsInformationWithRowCountTable AS s
      WHERE
         s.StatisticsMaintenanceId = @v_Counter;

      BEGIN TRY
         SET @v_OperationStartTime = GETDATE();
         SET @v_UpdateStatisticsCmd = 'UPDATE STATISTICS ' + @v_CurSchema + '.' + @v_CurTable + ' ' + @v_CurIndex + ' WITH FULLSCAN';
         EXECUTE sp_executesql @v_UpdateStatisticsCmd;
         SET @v_OperationStopTime = GETDATE();

         SELECT @v_QueriesExecuted = @v_QueriesExecuted + @v_NewLine + @v_UpdateStatisticsCmd;

         SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Updated statistics with full scan: ' + @v_CurSchema + '.' + @v_CurTable + '.' + @v_CurIndex + @v_NewLine + '...was previously updated on ' + CAST( @v_CurStatsLastUpdatedTime AS VARCHAR(20) ) + ', table had ' + CAST( @v_CurRowCountOnLastStatsUpdate AS VARCHAR(20) ) + ' rows at time of last update, and table now has ' + CAST( @v_CurCurrentRowCount AS VARCHAR(20) ) + ' rows.';
      END TRY
      BEGIN CATCH
         SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Failed to execute statistics full scan statement: ' + @v_NewLine + @v_UpdateStatisticsCmd + @v_NewLine + 'Due to exception: ' + @v_NewLine + ERROR_MESSAGE();
      END CATCH

      SET @v_Counter = @v_Counter + 1;
   END;

   -- Assemble the debugging output and append if enabled
   IF @p_IsDebug = 1
   BEGIN
      SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + @v_NewLine + 'Debug Output Enabled' + @v_NewLine + @v_NewLine + '---------------------' + @v_NewLine + @v_NewLine + @v_QueriesExecuted;
   END;

   -- GOTO label to break out of execution on error
   done:

   -- Email sproc results
   SET @v_StopTime = GETDATE();
   SET @v_EmailReport = @v_EmailReport + @v_NewLine + 'Started At: ' + CAST( @v_StartTime AS VARCHAR(20) ) + ' Ended At: ' + CAST( @v_StopTime AS VARCHAR(20) ) + ' Total Execution Time in Minutes: ' + CAST( DATEDIFF( MINUTE, @v_StartTime, @v_StopTime ) AS VARCHAR(20) );
   EXECUTE msdb.dbo.sp_send_dbmail @recipients = @p_RecipientEmail, @subject = @v_EmailSubject, @body = @v_EmailReport, @profile_name = 'Maintenance Mail Profile';
END;
GO