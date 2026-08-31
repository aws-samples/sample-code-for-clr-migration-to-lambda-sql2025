/* =====================================================================
   02-reproduce-failure.sql
   After upgrading the instance to SQL Server 2017/2019/2022/2025,
   the same CLR call fails because CLR strict security treats the
   assembly as UNSAFE and RDS does not allow the workarounds.
   ===================================================================== */
USE DemoDB;
GO

DECLARE @csv NVARCHAR(MAX) = N'"Acme, Inc.","123 Main St","NY"';
SELECT * FROM dbo.ParseCSV(@csv, N',');
GO

/* Expected error:
   Msg 6517 ... System.IO.FileLoadException: Could not load file or assembly
   'CsvParserAssembly ...' An error relating to security occurred.
   (Exception from HRESULT: 0x8013150A)

   On Amazon RDS you cannot disable clr strict security, grant UNSAFE
   ASSEMBLY, or sign the assembly (no sysadmin). Proceed to the Lambda
   replacement in the 03/04/05 scripts on SQL Server 2025.
*/
