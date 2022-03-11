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
   ,@p_IsDebug AS BIT
AS
DECLARE @TableName NVARCHAR(257);
DECLARE @sql NVARCHAR(MAX);
DECLARE @v_StaleStatisticsCutoffTime DATETIME2(0) = DATEADD(DAY, -30, GETDATE());

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


-- GOTO label to break out of execution on error
done:

GO