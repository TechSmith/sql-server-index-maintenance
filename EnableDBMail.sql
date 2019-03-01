--------------------------------------------------------------------------------
--
-- Author: TechSmith Corporation
-- License: MIT
-- Repository: https://github.com/TechSmith/sql-server-index-maintenance
--
-- SQL Script which configures SQL Server Settings for Database Mail.
-- The settings baked into this script are designed to be used by maintenance
-- scripts, but variables should be easily configurable to be used for other
-- email purposes.
--
-- BE AWARE THAT THIS WILL CHANGE SERVER SETTINGS!
-- Review this script before execution to familiarize yourself with it's actions.
--
-- This script has been verified to work on the following versions of SQL Server:
-- 2008, 2008R2, 2012
--
-- IMPORTANT: Using database mail causes log entries to build up within SQL Server.
-- These log files can be cleaned up with the stored procedures (included with
-- SQL Server): sysmail_delete_mailitems_sp, sysmail_delete_log_sp
--
--------------------------------------------------------------------------------
USE master;

DECLARE
    @v_AccountName AS SYSNAME
   ,@v_AccountDescription AS NVARCHAR(256)
   ,@v_AccountSmtpServer AS SYSNAME
   ,@v_AccountEmailFromAddress NVARCHAR(128)
   ,@v_AccountEmailDisplayName NVARCHAR(128)
   ,@v_ProfileName AS SYSNAME
   ,@v_ProfileDescription AS NVARCHAR(256);

--
-- Setup mail account variables
--
SET @v_AccountName = 'Maintenance Mail Account';
SET @v_AccountDescription = 'Account to be used by maintenance scripts.';
SET @v_AccountSmtpServer = 'somesmtpserver.yourdomain.tld';
SET @v_AccountEmailFromAddress = 'noreply@yourdomain.tld';
SET @v_AccountEmailDisplayName =  @@SERVERNAME + ' DB Server Maintenance';

--
-- Setup mail profile variables
--
SET @v_ProfileName = 'Maintenance Mail Profile';
SET @v_ProfileDescription = 'Profile to used by maintenance scripts.';

--------------------------------------------------------------------------------
-- You should not need to modify values below this point
--------------------------------------------------------------------------------

--
-- Check and configure SQL Server Settings
--
PRINT 'Enabling ''show advanced options''';
EXECUTE sp_configure 'show advanced options', 1;
PRINT 'Issuing RECONFIGURE command...'
RECONFIGURE WITH OVERRIDE;
PRINT 'Done.' + CHAR(13)+CHAR(10);

PRINT 'Enabling ''database mail xps''';
EXECUTE sp_configure 'Database Mail XPs', 1;
PRINT 'Issuing RECONFIGURE command...'
RECONFIGURE WITH OVERRIDE;
PRINT 'Done.' + CHAR(13)+CHAR(10);

-- Check For Service Broker
-- If it isn't turned on, mail will queue but never send
IF (SELECT d.is_broker_enabled FROM sys.databases AS d WHERE name = 'msdb') = 0
BEGIN
   RAISERROR( 'Service Broker is disabled but required for Database Mail. Please stop the SQL Server Agent (Windows Service) for this instance, execute the command ''ALTER DATABASE msdb SET ENABLE_BROKER'' as sysadmin and then restart the SQL Server Agent ONLY if it was already running.', 16, 1 );
   GOTO done;
END;
ELSE
   PRINT 'Service Broker is enabled. Required for database mail.' + CHAR(13)+CHAR(10);

--
-- Check for profiles / accounts 
--
IF EXISTS ( SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = @v_ProfileName )
BEGIN
   RAISERROR( 'The specified Database Mail profile already exists. Drop with "msdb.dbo.sysmail_delete_profile_sp @profile_name = ''profile_name_here''"', 16, 1 );
   GOTO done;
END;

IF EXISTS ( SELECT 1 FROM msdb.dbo.sysmail_account WHERE name = @v_AccountName )
BEGIN
   RAISERROR( 'The specified Database Mail account already exists. Drop with "msdb.dbo.sysmail_delete_account_sp @account_name = ''account_name_here''"', 16, 1 );
   GOTO done;
END;

--
-- Actually create the mail account, mail profile and the association
--

-- Start a transaction before adding the account and the profile
BEGIN TRANSACTION;

   DECLARE @v_ReturnValue INT;

   PRINT 'Creating Database Mail account...'
   EXECUTE @v_ReturnValue = msdb.dbo.sysmail_add_account_sp
       @account_name = @v_AccountName
      ,@description = @v_AccountDescription
      ,@email_address = @v_AccountEmailFromAddress
      ,@display_name = @v_AccountEmailDisplayName
      ,@mailserver_name = @v_AccountSmtpServer;

   IF @v_ReturnValue <> 0
   BEGIN
      RAISERROR( 'Failed to create the specified Database Mail account.', 16, 1 );
      ROLLBACK TRANSACTION; --Nothing to rollback, but the transaction needs to be closed
      GOTO done;
   END;
   PRINT 'Done.' + CHAR(13)+CHAR(10)

   PRINT 'Creating Database Mail profile...'
   EXECUTE @v_ReturnValue = msdb.dbo.sysmail_add_profile_sp
       @profile_name = @v_ProfileName
      ,@description = @v_ProfileDescription;

   IF @v_ReturnValue <> 0
   BEGIN
      RAISERROR( 'Failed to create the specified Database Mail profile.', 16, 1 );
      ROLLBACK TRANSACTION;
      GOTO done;
   END
   PRINT 'Done.' + CHAR(13)+CHAR(10);

   -- Associate the account with the profile
   -- Be aware that you can associate multiple accounts with a single profile,
   -- this is related to the priority (sequence_number).  When you send an email
   -- with multiple accounts linked to a single profile, Database Mail will randomly
   -- select which account is used.
   PRINT 'Associating email account with email profile...'
   EXECUTE @v_ReturnValue = msdb.dbo.sysmail_add_profileaccount_sp
       @profile_name = @v_ProfileName
      ,@account_name = @v_AccountName
      ,@sequence_number = 1

   IF @v_ReturnValue <> 0
   BEGIN
      RAISERROR( 'Failed to create the specified Database Mail profile.', 16, 1 );
      ROLLBACK TRANSACTION;
      GOTO done;
   END;
   PRINT 'Done.' + CHAR(13)+CHAR(10);

COMMIT TRANSACTION;

PRINT 'The script appears to have completed successfully.' + CHAR(13)+CHAR(10);

-- GOTO label to break out of execution on error
done:
GO