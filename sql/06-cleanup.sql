/* =====================================================================
   06-cleanup.sql
   Remove the objects created by this sample.
   ===================================================================== */
USE ERPDatabase;
GO

-- Lambda-backed procedure
DROP PROCEDURE IF EXISTS dbo.ParseCSV_Lambda;
GO

-- Credential + master key (drop the credential; keep the master key if other
-- credentials depend on it)
IF EXISTS (SELECT 1 FROM sys.database_scoped_credentials
           WHERE name LIKE 'https://%execute-api%')
BEGIN
    DECLARE @cred SYSNAME = (SELECT TOP 1 name FROM sys.database_scoped_credentials
                             WHERE name LIKE 'https://%execute-api%');
    EXEC('DROP DATABASE SCOPED CREDENTIAL [' + @cred + ']');
END
GO

-- Old CLR objects (if present on a pre-2017 instance)
DROP FUNCTION IF EXISTS dbo.ParseCSV;
GO
DROP ASSEMBLY IF EXISTS [CsvParserAssembly];
GO

/* Also remember to delete AWS resources to avoid charges:
     - Lambda function: clr-csv-parser
     - API Gateway API: clr-csv-parser-api (+ stage, usage plan, API key)
     - Any test RDS instances
*/
