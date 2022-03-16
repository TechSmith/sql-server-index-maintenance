--------------------------------------------------------------------------------
--
-- Author: TechSmith Corporation
-- License: MIT
-- Repository: https://github.com/TechSmith/sql-server-index-maintenance
--
-- Creates (or alters) a stored procedure intended to do basic index 
-- maintenance for all indexes in need of maintenance against a given database.
--
-- When the script completes, a report is generated and sent via Database Mail.
-- Database Mail requires configuration before this script can be executed.
--
-- This script has been verified to work on the following versions of SQL Server:
-- 2008, 2008R2, 2012
--
-- execute the stored procedure with the following command:
-- EXECUTE dbo.proc_RunIndexMaintenance
--     @p_DatabaseName = 'nameOfDatabase'
--    ,@p_RecipientEmail = 'first.last@email.com'
--    ,@p_RebuildMode = 'Mixed'
--    ,@p_IsDebug = 0
--
--  Valid options for RebuildMode are:
--    OnlineOnly - Only rebuild indexes which can be rebuilt online
--    OfflineOnly - Rebuild all indexes offline, even if they could be rebuilt online
--    Mixed - Rebuild indexes online which can be rebuilt online, all others are rebuilt offline
--
--  Enabling IsDebug will cause additional information to be included in the email report.
--
--------------------------------------------------------------------------------
IF OBJECT_ID( 'dbo.proc_RunIndexMaintenance', 'P' ) IS NULL
   EXECUTE( 'CREATE PROCEDURE dbo.proc_RunIndexMaintenance AS SET NOCOUNT ON;' )
GO

ALTER PROCEDURE dbo.proc_RunIndexMaintenance
    @p_DatabaseName AS SYSNAME
   ,@p_RecipientEmail AS NVARCHAR( 256 )
   ,@p_RebuildMode AS VARCHAR( 12 )
   ,@p_IsDebug AS BIT
AS
DECLARE
    @v_GetIndexesCmd AS NVARCHAR( MAX )
   ,@v_StartTime AS DATETIME2
   ,@v_StopTime AS DATETIME2
   ,@v_EmailReport AS NVARCHAR( MAX )
   ,@v_EmailSubject AS NVARCHAR( 255 )
   ,@v_QueriesExecuted AS NVARCHAR( MAX )
   ,@v_IsOnlineRebuildSupported AS BIT
   ,@v_DBCompatibilityLevel AS TINYINT
   ,@v_LobColumnTypesClause AS VARCHAR( MAX )
   ,@v_EngineEditionName AS VARCHAR( 50 )
   ,@v_NewLine AS CHAR(2) = CHAR(13)+CHAR(10)
   ,@v_OperationStartTime AS DATETIME2(0)
   ,@v_OperationStopTime AS DATETIME2(0);

-- Table variable to store the indexes in need of maintenance
DECLARE @v_IndexInformationTable AS TABLE
   (  
       IndexMaintenanceId INT IDENTITY( 1,1 )
      ,SchemaName SYSNAME
      ,TableName SYSNAME
      ,IndexName SYSNAME NULL -- Heaps do not have an index name
      ,ArePageLocksEnabled BIT
      ,DoesContainLob BIT
      ,AverageFragmentationPercent FLOAT
   );

BEGIN
   SET @v_StartTime = GETDATE();
   SELECT @v_EmailReport = 'Index Maintenance Sproc report for server ' + @@SERVERNAME + ' on database: ' + @p_DatabaseName;
   SELECT @v_EmailSubject = @@SERVERNAME + ' ' + @p_DatabaseName + ' Index Report';

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

   SET @p_RebuildMode = LOWER( @p_RebuildMode );
   IF ( @p_RebuildMode <> 'onlineonly' AND @p_RebuildMode <> 'offlineonly' AND @p_RebuildMode <> 'mixed' )
   BEGIN
      SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Execution aborted. Invalid RebuildMode parameter: ''' + @p_RebuildMode + ''' Valid parameters are OnlineOnly, OfflineOnly, Mixed.' + @v_NewLine
      GOTO done;
   END

  SET @v_EngineEditionName =
     CASE SERVERPROPERTY( 'EngineEdition' )
        WHEN 3 THEN 'Enterprise' -- Enterprise
        WHEN 5 THEN 'SQL Azure' -- SQL Azure
        ELSE 'Unknown'
     END;
  -- Determine if server supports rebuilding of indexes online
  SET @v_IsOnlineRebuildSupported =
     CASE @v_EngineEditionName
        WHEN 'Enterprise' THEN 1
        WHEN 'SQL Azure' THEN 1
        ELSE 0
     END;
   
   -- Check for rebuild online with an edition of SQL Server that doesn't support online rebuilds
   IF ( @v_IsOnlineRebuildSupported = 0 AND @p_RebuildMode <> 'offlineonly' )
   BEGIN
      SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Execution aborted. Invalid RebuildMode parameter: ''' + @p_RebuildMode + '''. Online rebuilds are not supported by this edition of SQL Server.' + @v_NewLine
      GOTO done;
   END

   SELECT @v_DBCompatibilityLevel = d.compatibility_level FROM sys.databases AS d WHERE d.name = @p_DatabaseName;

   -- Define Large Object Data (LOB) types for this DB compatibility level
   -- This is a string concatenated with a query later on in the sproc.
   -- 100 is SQL Server 2008 and 2008R2.
   -- SQL Azure currently displays a compatibility level of 100, but can
   -- can actually rebuild varbinary, varchar, and nvarchar online
   IF @v_DBCompatibilityLevel = 100 AND @v_EngineEditionName <> 'SQL Azure'
   BEGIN
      SET @v_LobColumnTypesClause = '( 34 /*image*/, 35  /*text*/, 99 /*ntext*/,241 /*xml*/ )
               OR (
                     c.system_type_id IN ( 165 /*varbinary*/, 167 /*varchar*/, 231 /*nvarchar*/ )
                  AND
                     c.max_length = -1 --Reflects datatypes with MAX size
                  )'
   END;
   -- 110 is SQL Server 2012, 120 is 2014 
   ELSE IF @v_DBCompatibilityLevel >= 110 OR @v_EngineEditionName = 'SQL Azure'
   BEGIN
      SET @v_LobColumnTypesClause = '( 34 /*image*/, 35 /*text*/,99 /*ntext*/ )'
   END;
   ELSE
   BEGIN
      SET @v_LobColumnTypesClause = NULL;
   END;

      -- If the LOB column type id's is null, the version of SQL server is not supported
      IF @v_LobColumnTypesClause IS NULL
      BEGIN
         SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Execution aborted. Unsupported/Untested Database Compatibility Mode: ' + CAST ( @v_DBCompatibilityLevel AS NVARCHAR( 3 ) ) + @v_NewLine;  
         GOTO done;
      END;

   -- Get the list of databases in need of maintenance
   -- Because the sys views depend on the current database context, this needs
   -- to be dynamic SQL
   SET @v_GetIndexesCmd = '
      SELECT
          s.name AS SchemaName
         ,o.name AS TableName
         ,i.name AS IndexName
         -- LOBs are important because (some) cannot be rebuilt online
         ,i.allow_page_locks AS ArePageLocksEnabled
         ,COALESCE( ( SELECT
            TOP(1) 1
               FROM
                   ['+ @p_DatabaseName +'].sys.tables AS t
               INNER JOIN
                   ['+ @p_DatabaseName +'].sys.columns AS c ON c.object_id = stats.object_id
               WHERE
                  t.object_id = stats.object_id
               AND
                  c.system_type_id IN '+ @v_LobColumnTypesClause +'
           ), 0 ) AS DoesContainLob
         ,stats.avg_fragmentation_in_percent AS AverageFragmentationPercent
      FROM
         sys.dm_db_index_physical_stats( DB_ID( '''+ @p_DatabaseName + ''' ) , NULL, NULL, NULL, ''LIMITED'') AS stats
      INNER JOIN
         ['+ @p_DatabaseName +'].sys.indexes AS i ON i.object_id = stats.object_id AND i.index_id = stats.index_id
      INNER JOIN
         ['+ @p_DatabaseName +'].sys.objects AS o ON o.object_id = stats.object_id
      INNER JOIN
         ['+ @p_DatabaseName +'].sys.schemas AS s ON s.schema_id = o.schema_id
      WHERE
          -- Indexes with less than 1,000 page files are not big enough to worry about
          stats.page_count >= 1000
      AND
         -- Best practices say to start reorganizing at 5% fragmentation
         stats.avg_fragmentation_in_percent >= 5
      AND
         -- Ensures that there is only one row returned per index
         stats.alloc_unit_type_desc = ''IN_ROW_DATA''
      ORDER BY
         -- Order from worst to best which is how optimization will take place
         stats.avg_fragmentation_in_percent
      DESC';
   
   SET @v_OperationStartTime = GETDATE();

   --Read the results into the table variable
   BEGIN TRY
      INSERT INTO @v_IndexInformationTable EXECUTE sp_executesql @v_GetIndexesCmd;
   END TRY
   BEGIN CATCH
      SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Failed to query indexes due to exception: ' + @v_NewLine + ERROR_MESSAGE();
      GOTO done;
   END CATCH;

   SET @v_OperationStopTime = GETDATE();

   SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Finished querying for index information. ' + 'Started At: ' + CAST( @v_OperationStartTime AS VARCHAR(20) ) + ' Ended At: ' + CAST( @v_OperationStopTime AS VARCHAR(20) ) + ' Took ' + CAST( DATEDIFF( SECOND, @v_OperationStartTime, @v_OperationStopTime ) AS VARCHAR(20) )  + ' seconds';

   DECLARE
       @v_CurSchema AS SYSNAME
      ,@v_CurTable AS SYSNAME
      ,@v_CurIndex AS SYSNAME
      ,@v_CurIndexIsHeap AS BIT
      ,@v_CurArePageLocksEnabled AS BIT
      ,@v_CurDoesContainLob AS BIT
      ,@v_CurFragmentation AS FLOAT
      ,@v_Counter AS SMALLINT
      ,@v_LastRow AS SMALLINT
      ,@v_SqlRebuildHints AS NVARCHAR(50)
      ,@v_SqlRebuildHeap AS NVARCHAR(MAX)
      ,@v_SqlReorganizeIndex AS NVARCHAR(MAX)
      ,@v_SqlRebuildIndex AS NVARCHAR(MAX);

   SET @v_Counter = 1;
   SELECT @v_LastRow = COUNT(1) FROM @v_IndexInformationTable;

   -- Loop through the indexes and reorganize or rebuild as appropriate
   WHILE ( @v_Counter <= @v_LastRow )
   BEGIN
      SELECT
          @v_CurSchema = '[' + i.SchemaName + ']'
         ,@v_CurTable = '[' + i.TableName + ']'
         ,@v_CurIndex = '[' + i.IndexName + ']'
          -- Heaps are tables not indexes, so the name joined from sys.indexes will be null
         ,@v_CurIndexIsHeap = CASE 
            WHEN i.IndexName IS NULL THEN 1
            ELSE 0
          END
         ,@v_CurArePageLocksEnabled = i.ArePageLocksEnabled
         ,@v_CurDoesContainLob = i.DoesContainLob
         ,@v_CurFragmentation = i.AverageFragmentationPercent
      FROM
         @v_IndexInformationTable AS i
      WHERE
         i.IndexMaintenanceId = @v_Counter;

      -- Hint rebuild queries in appropriate fashion for the server/index/script settings
      IF ( @p_RebuildMode <> 'offlineonly' AND @v_IsOnlineRebuildSupported = 1 AND @v_CurDoesContainLob = 0 )
      BEGIN
         IF ( @v_CurArePageLocksEnabled = 0 )
            SET @v_SqlRebuildHints = ' WITH ( ONLINE = ON, MAXDOP = 1 )';
         ELSE
            SET @v_SqlRebuildHints = ' WITH ( ONLINE = ON )';
      END
      ELSE IF ( @p_RebuildMode = 'offlineonly' )
         SET @v_SqlRebuildHints = ' WITH ( ONLINE = OFF )';
      ELSE
         SET @v_SqlRebuildHints = '';

      -- If the index needs to be skipped, log that in the email body and continue to the next index      
      IF ( @p_RebuildMode = 'onlineonly' AND @v_CurFragmentation >= 30 AND ( @v_IsOnlineRebuildSupported = 0 OR @v_CurDoesContainLob = 1 ) )
      BEGIN
         IF ( @v_CurIndexIsHeap = 1 )
            SET @v_CurIndex = '(heap)';
         SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Skipped Index: ' + @v_CurSchema + '.' + @v_CurTable + '.' + @v_CurIndex + @v_NewLine + '...was ' + CAST( @v_CurFragmentation AS VARCHAR(20) ) + ' percent fragmented, but contains LOB.';
         SET @v_Counter = @v_Counter + 1;
         CONTINUE;
      END

      -- Rebuilding a heap is different than a typical index
      IF ( @v_CurIndexIsHeap = 1 AND @v_CurFragmentation >= 30 )
         BEGIN TRY
            SELECT @v_SqlRebuildHeap = 'ALTER TABLE [' + @p_Databasename + '].' + @v_CurSchema + '.' + @v_CurTable + ' REBUILD' + @v_SqlRebuildHints;
            SET @v_OperationStartTime = GETDATE();
            EXECUTE sp_executesql @v_SqlRebuildHeap;
            SET @v_OperationStopTime = GETDATE();
            SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Rebuilt Heap: ' + @v_CurSchema + '.' + @v_CurTable + @v_NewLine + '...was ' + CAST( @v_CurFragmentation AS VARCHAR(20) ) + ' percent fragmented.'
            SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Started At: ' + CAST( @v_OperationStartTime AS VARCHAR(20) ) + ' Ended At: ' + CAST( @v_OperationStopTime AS VARCHAR(20) ) + ' Total Execution Time in Minutes: ' + CAST( DATEDIFF( MINUTE, @v_OperationStartTime, @v_OperationStopTime ) AS VARCHAR(20) );
            SELECT @v_QueriesExecuted = @v_QueriesExecuted + @v_NewLine + @v_SqlRebuildHeap;
         END TRY
         BEGIN CATCH
            SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Failed to execute rebuild heap statement: ' + @v_NewLine + @v_SqlRebuildHeap + @v_NewLine + 'Due to exception: ' + @v_NewLine + ERROR_MESSAGE();
         END CATCH;
      ELSE IF (  @v_CurIndex IS NOT NULL AND @v_CurFragmentation >= 30 )
         BEGIN TRY
            SELECT @v_SqlRebuildIndex = 'ALTER INDEX ' + @v_CurIndex + ' ON [' + @p_DatabaseName + '].' + @v_CurSchema + '.' + @v_CurTable + ' REBUILD' + @v_SqlRebuildHints;
            SET @v_OperationStartTime = GETDATE();
            EXECUTE sp_executesql @v_SqlRebuildIndex;
            SET @v_OperationStopTime = GETDATE();
            SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Rebuilt Index: ' + @v_CurSchema + '.' + @v_CurTable + '.' + @v_CurIndex + @v_NewLine + '...was ' + CAST( @v_CurFragmentation AS VARCHAR(20) ) + ' percent fragmented.';
            SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Started At: ' + CAST( @v_OperationStartTime AS VARCHAR(20) ) + ' Ended At: ' + CAST( @v_OperationStopTime AS VARCHAR(20) ) + ' Total Execution Time in Minutes: ' + CAST( DATEDIFF( MINUTE, @v_OperationStartTime, @v_OperationStopTime ) AS VARCHAR(20) );
            SELECT @v_QueriesExecuted = @v_QueriesExecuted + @v_NewLine + @v_SqlRebuildIndex;
         END TRY
         BEGIN CATCH
            SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Failed to execute rebuild statement: ' + @v_NewLine + @v_SqlRebuildIndex + @v_NewLine + 'Due to exception: ' + @v_NewLine + ERROR_MESSAGE();
         END CATCH;
      ELSE IF (  @v_CurIndex IS NOT NULL
                    AND @v_CurArePageLocksEnabled = 1  -- Only indexes w/ Page Locking can be reorganized
                    AND @v_CurFragmentation >= 5 )
         BEGIN TRY
            SET @v_SqlReorganizeIndex = 'ALTER INDEX ' + @v_CurIndex + ' ON [' + @p_DatabaseName + '].' + @v_CurSchema + '.' + @v_CurTable + ' REORGANIZE';
            SET @v_OperationStartTime = GETDATE();
            EXECUTE sp_executesql @v_SqlReorganizeIndex;
            SET @v_OperationStopTime = GETDATE();
            SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Reorganized Index: ' + @v_CurSchema + '.' + @v_CurTable + '.' + @v_CurIndex  + @v_NewLine + '...was ' + CAST( @v_CurFragmentation AS VARCHAR(20) ) + ' percent fragmented.';
            SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Started At: ' + CAST( @v_OperationStartTime AS VARCHAR(20) ) + ' Ended At: ' + CAST( @v_OperationStopTime AS VARCHAR(20) ) + ' Total Execution Time in Minutes: ' + CAST( DATEDIFF( MINUTE, @v_OperationStartTime, @v_OperationStopTime ) AS VARCHAR(20) );
            SELECT @v_QueriesExecuted = @v_QueriesExecuted + @v_NewLine + @v_SqlReorganizeIndex;
         END TRY
         BEGIN CATCH
            SELECT @v_EmailReport = @v_EmailReport + @v_NewLine + 'Failed to execute reorganize statement: ' + @v_NewLine + @v_SqlReorganizeIndex + @v_NewLine + 'Due to exception: ' + @v_NewLine + ERROR_MESSAGE();
         END CATCH;
      SET @v_Counter = @v_Counter + 1;
   END;

   -- Assemble the debugging output and append if enabled
   IF @p_IsDebug = 1
   BEGIN
      SELECT @v_QueriesExecuted = 'Get indexes command: ' + @v_GetIndexesCmd + @v_NewLine + @v_NewLine + 'Maintenance commands executed:'  + @v_NewLine + @v_NewLine +  @v_QueriesExecuted; 
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