/* =====================================================================
   01-clr-setup-2016.sql
   Reproduce the "before" state: deploy the CLR CSV parser on
   Amazon RDS for SQL Server 2016 (PERMISSION_SET = SAFE).

   Prerequisites:
     - RDS SQL Server 2016 instance
     - "clr enabled" = 1 in a custom parameter group
     - Compile clr-reference/CsvParser.cs to CsvParser.dll and convert
       to hex (see clr-reference/README.md), then paste the hex below.
   ===================================================================== */
USE DemoDB;   -- replace with your database
GO

-- Create the assembly from the hex of CsvParser.dll (PERMISSION_SET must be SAFE on RDS)
CREATE ASSEMBLY [CsvParserAssembly]
FROM 0x4D5A90000300000004000000FFFF0000...   -- replace with your full hex string
WITH PERMISSION_SET = SAFE;
GO

-- Table-valued function wrapper
CREATE FUNCTION dbo.ParseCSV(
    @csvData   NVARCHAR(MAX),
    @delimiter NVARCHAR(10)
)
RETURNS TABLE (
    RowNum INT,
    Col1 NVARCHAR(4000), Col2 NVARCHAR(4000), Col3 NVARCHAR(4000),
    Col4 NVARCHAR(4000), Col5 NVARCHAR(4000)
)
AS EXTERNAL NAME [CsvParserAssembly].[CsvParser].[ParseCSV];
GO

-- Verify (embedded comma stays a single field)
DECLARE @csv NVARCHAR(MAX) = N'CustomerName,Address,City,State,Amount
"AnyCompany, Inc.","123 Any St, Suite 1
Building A","Anytown","NY","50000.00"';
SELECT * FROM dbo.ParseCSV(@csv, N',');
-- Col1 should be: AnyCompany, Inc.
GO
