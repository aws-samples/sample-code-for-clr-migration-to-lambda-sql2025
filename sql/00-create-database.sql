/* =====================================================================
   00-create-database.sql
   Create the DemoDB database used by the rest of the sample scripts,
   only if it does not already exist.

   Runs on: any supported SQL Server version (RDS or on-prem).
   Run this first, before 01-clr-setup-2016.sql.
   ===================================================================== */
IF DB_ID(N'DemoDB') IS NULL
BEGIN
    PRINT 'Creating database DemoDB...';
    CREATE DATABASE DemoDB;
END
ELSE
BEGIN
    PRINT 'Database DemoDB already exists; skipping creation.';
END
GO
