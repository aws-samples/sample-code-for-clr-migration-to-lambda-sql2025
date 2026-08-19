/* =====================================================================
   03-sql2025-setup.sql
   On Amazon RDS for SQL Server 2025: verify the external REST endpoint
   feature is enabled, then create the master key and the database scoped
   credential that carries the API Gateway API key.

   Prerequisite: "external rest endpoint enabled" = 1 in a custom
   parameter group attached to the instance (Parameter Group Status = in-sync).

   Replace:
     <API_GATEWAY_BASE_URL>  e.g. abc123.execute-api.us-east-1.amazonaws.com
     <YOUR_API_KEY>          the API key value from API Gateway
   ===================================================================== */
USE ERPDatabase;
GO

-- 1. Verify the feature is on
SELECT name, CAST(value_in_use AS INT) AS value_in_use
FROM sys.configurations
WHERE name = 'external rest endpoint enabled';
-- Expected: value_in_use = 1
GO

-- 2. Master key (once per database)
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'YourStr0ngP@ssword!';
GO

-- 3. Credential. IMPORTANT: the name must match the endpoint base URL as a
--    path-boundary prefix -- INCLUDE THE TRAILING SLASH.
CREATE DATABASE SCOPED CREDENTIAL [https://<API_GATEWAY_BASE_URL>/]
WITH IDENTITY = 'HTTPEndpointHeaders',
     SECRET = '{"x-api-key":"<YOUR_API_KEY>"}';
GO

-- 4. Confirm
SELECT name FROM sys.database_scoped_credentials;
GO
