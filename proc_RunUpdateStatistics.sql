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
--    ,@p_MinimumIndexPageCountToUpdate = 1000
--    ,@p_DaysSinceStatsUpdatedToForceUpdate = 30
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
   ,@p_MinimumIndexPageCountToUpdate AS BIGINT
   ,@p_DaysSinceStatsUpdatedToForceUpdate AS SMALLINT
   ,@p_IsDebug AS BIT
AS
DECLARE
    @v_StartTime AS DATETIME2(0)
   ,@v_StopTime AS DATETIME2(0)
   ,@v_OperationStartTime AS DATETIME2(0)
   ,@v_OperationStopTime AS DATETIME2(0)
   ,@v_EmailReport AS NVARCHAR(MAX)
   ,@v_EmailSubject AS NVARCHAR(255)
   ,@v_QueriesExecuted AS NVARCHAR(MAX)
   ,@v_NewLine AS CHAR(2) = CHAR(13)+CHAR(10)
   ,@v_StaleStatisticsCutoffTime DATETIME2(0);

-- Table variable to store the statistics that are in need of maintenance
DECLARE @v_StaleStatisticsInformationTable AS TABLE
   (  
       StatisticsMaintenanceId INT IDENTITY( 1,1 )
      ,SchemaName SYSNAME
      ,TableId INT
      ,TableName SYSNAME
      ,IndexId INT
      ,IndexName SYSNAME NULL -- Heaps do not have an index name
      ,StatsLastUpdatedTime DATETIME2(0)
      ,RowCountOnLastStatsUpdate BIGINT
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

   IF @p_DaysSinceStatsUpdatedToForceUpdate < 0
   BEGIN
      SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'p_DaysSinceStatsUpdatedToForceUpdate must be greater than or equal to 0. Was ' + @p_DaysSinceStatsUpdatedToForceUpdate;
      GOTO done;
   END

   SET @v_StaleStatisticsCutoffTime = DATEADD(DAY, -@p_DaysSinceStatsUpdatedToForceUpdate, GETDATE());

   -- Find statistics that need to be updated
   DECLARE @v_GetStaleStatisticsCmd NVARCHAR(MAX);
   SET @v_GetStaleStatisticsCmd = '
      SELECT
          s.name AS SchemaName
         ,o.object_id AS TableId
         ,o.name AS TableName
         ,i.index_id AS IndexId
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
         sys.dm_db_stats_properties(o.object_id, stats.stats_id) AS stats_props
      CROSS APPLY
         sys.dm_db_index_physical_stats( DB_ID( '''+ @p_DatabaseName + ''' ) , o.object_id, i.index_id, NULL, ''LIMITED'') AS phys_stats
      WHERE
         i.auto_created = 0
      AND
         stats.auto_created = 0
      AND
         (stats_props.last_updated IS NULL
      OR
         stats_props.last_updated <= @v_StaleStatisticsCutoffTime)
      AND
         -- Indexes with less than the specified number of page files are not big enough to worry about
         phys_stats.page_count >= ' + CAST( @p_MinimumIndexPageCountToUpdate AS VARCHAR(20) ) + '
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

   SET @v_OperationStopTime = GETDATE();

   SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Finished querying for statistics in need of update. ' + 'Started At: ' + CAST( @v_OperationStartTime AS VARCHAR(20) ) + ' Ended At: ' + CAST( @v_OperationStopTime AS VARCHAR(20) ) + ' Took ' + CAST( DATEDIFF( SECOND, @v_OperationStartTime, @v_OperationStopTime ) AS VARCHAR(20) )  + ' seconds';

   DECLARE
       @v_CurSchema AS SYSNAME
      ,@v_CurTableId AS INT
      ,@v_CurTableName AS SYSNAME
      ,@v_CurIndexId AS INT
      ,@v_CurIndexName AS SYSNAME
      ,@v_CurStatsLastUpdatedTime AS DATETIME2(0)
      ,@v_CurRowCountOnLastStatsUpdate AS BIGINT
      ,@v_CurCurrentRowCount AS BIGINT
      ,@v_Counter AS SMALLINT
      ,@v_LastRow AS SMALLINT
      ,@v_UpdateStatisticsCmd AS NVARCHAR(MAX)

   SET @v_Counter = 1;
   SELECT @v_LastRow = COUNT(1) FROM @v_StaleStatisticsInformationTable;

   -- Loop through the statistics and force a full scan
   WHILE ( @v_Counter <= @v_LastRow )
   BEGIN
      SELECT
          @v_CurSchema = '[' + s.SchemaName + ']'
         ,@v_CurTableId = s.TableId
         ,@v_CurTableName = '[' + s.TableName + ']'
         ,@v_CurIndexId = s.IndexId
         ,@v_CurIndexName = '[' + s.IndexName + ']'
         ,@v_CurStatsLastUpdatedTime = s.StatsLastUpdatedTime
         ,@v_CurRowCountOnLastStatsUpdate = s.RowCountOnLastStatsUpdate
      FROM
         @v_StaleStatisticsInformationTable AS s
      WHERE
         s.StatisticsMaintenanceId = @v_Counter;

      BEGIN TRY
         SET @v_OperationStartTime = GETDATE();
         SET @v_UpdateStatisticsCmd = 'UPDATE STATISTICS ' + @v_CurSchema + '.' + @v_CurTableName + ' ' + @v_CurIndexName + ' WITH FULLSCAN';
         EXECUTE sp_executesql @v_UpdateStatisticsCmd;
         SET @v_OperationStopTime = GETDATE();

         SELECT @v_QueriesExecuted = @v_QueriesExecuted + @v_NewLine + @v_UpdateStatisticsCmd;

         SELECT @v_CurCurrentRowCount = stats_props.unfiltered_rows
         FROM sys.dm_db_stats_properties(@v_CurTableId, @v_CurIndexId) AS stats_props

         IF @v_CurCurrentRowCount IS NULL
         BEGIN
            SET @v_CurCurrentRowCount = 0
         END

         SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Updated statistics with full scan: ' + @v_CurSchema + '.' + @v_CurTableName + '.' + @v_CurIndexName + @v_NewLine + '...was previously updated on ' + CASE WHEN @v_CurStatsLastUpdatedTime IS NULL THEN 'NEVER' ELSE CAST( @v_CurStatsLastUpdatedTime AS VARCHAR(20) ) END + ', table had ' + CASE WHEN @v_CurRowCountOnLastStatsUpdate IS NULL THEN '0' ELSE CAST( @v_CurRowCountOnLastStatsUpdate AS VARCHAR(20) ) END + ' rows at time of last update, and table now has ' + CAST( @v_CurCurrentRowCount AS VARCHAR(20) ) + ' rows.';
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