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
DECLARE @TableName NVARCHAR(257);
DECLARE @sql NVARCHAR(MAX);
DECLARE @v_StaleStatisticsCutoffTime DATETIME2(0) = DATEADD(DAY, -30, GETDATE());
DECLARE @v_GetTablesCmd NVARCHAR(MAX);
DECLARE @v_GetStaleStatisticsCmd NVARCHAR(MAX);

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
   SET @v_GetTablesCmd = '
      SELECT
         t.TABLE_SCHEMA AS SchemaName
         ,t.TABLE_NAME AS TableName
      FROM
         ['+ @p_DatabaseName +'].INFORMATION_SCHEMA.TABLES AS t
      WHERE
         t.TABLE_TYPE = ''BASE TABLE''';

   BEGIN TRY
      INSERT INTO @v_DatabaseTablesTable EXECUTE sp_executesql @v_GetTablesCmd;
   END TRY
   BEGIN CATCH
      GOTO done;
   END CATCH;

   DECLARE
      @v_CurCountSchema AS SYSNAME
      ,@v_CurCountTable AS SYSNAME
      ,@v_GetRowCountCmd AS NVARCHAR(MAX)
      ,@v_RowCountCounter AS SMALLINT
      ,@v_DatabaseTablesLastRow AS SMALLINT

   SET @v_RowCountCounter = 1;
   SELECT @v_DatabaseTablesLastRow = COUNT(1) FROM @v_DatabaseTablesTable;

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
      END TRY
      BEGIN CATCH
         GOTO done;
      END CATCH;

      SET @v_RowCountCounter = @v_RowCountCounter + 1;
   END;

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

   BEGIN TRY
      INSERT INTO @v_StaleStatisticsInformationTable EXECUTE sp_executesql @v_GetStaleStatisticsCmd
      ,N'@v_StaleStatisticsCutoffTime DATETIME2(0)'
      ,@v_StaleStatisticsCutoffTime = @v_StaleStatisticsCutoffTime;
   END TRY
   BEGIN CATCH
      GOTO done;
   END CATCH;

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

      SET @v_UpdateStatisticsCmd = 'UPDATE STATISTICS ' + @v_CurSchema + '.' + @v_CurTable + ' ' + @v_CurIndex + ' WITH FULLSCAN';
      EXECUTE sp_executesql @v_UpdateStatisticsCmd;

      SET @v_Counter = @v_Counter + 1;
   END;

   -- GOTO label to break out of execution on error
   done:
END;
GO