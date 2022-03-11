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

DECLARE TableCursor CURSOR READ_ONLY FOR
SELECT
    TABLE_SCHEMA + '.' + TABLE_NAME
FROM 
    INFORMATION_SCHEMA.TABLES
WHERE
    TABLE_TYPE = 'BASE TABLE';

OPEN TableCursor;
FETCH NEXT FROM TableCursor INTO @TableName;

WHILE @@fetch_status = 0
BEGIN
    SET @sql = 'UPDATE STATISTICS ' + @TableName + ' WITH FULLSCAN';
    EXEC sp_executesql @sql;
    FETCH NEXT FROM TableCursor INTO @TableName;
END
 
CLOSE TableCursor;
DEALLOCATE TableCursor;

GO