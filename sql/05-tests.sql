/* =====================================================================
   05-tests.sql
   Validate the Lambda-backed parser on SQL Server 2025:
     A) inline tests, B) read a real file from S3, C) load a staging
     table, D) measure latency, E) contrast with native BULK INSERT.
   ===================================================================== */
USE DemoDB;
GO

/* ---- A) Inline: embedded commas + escaped quotes ---- */
DECLARE @csv1 NVARCHAR(MAX) = N'CustomerName,Address,City,State,Amount
"Acme, Inc.","123 Main St, Suite 5","New York","NY","50000.00"
"O""Brien Corp","789 Pine Rd","Chicago","IL","99999.99"';
EXEC dbo.ParseCSV_Lambda @csv1, N',', 1;
-- Expected: 2 rows; Col1 = 'Acme, Inc.' and 'O"Brien Corp'
GO

/* ---- B) Read a real multi-line file downloaded from S3 to D:\S3 ----
   First download it (requires S3 integration + IAM role):
     EXEC msdb.dbo.rds_download_from_s3
        @s3_arn_of_file = 'arn:aws:s3:::YOUR-BUCKET/sample_multiline_1000.csv',
        @rds_file_path  = 'D:\S3\sample_multiline_1000.csv',
        @overwrite_file = 1;
*/
DECLARE @csv VARCHAR(MAX);
SELECT @csv = BulkColumn
FROM OPENROWSET(BULK 'D:\S3\sample_multiline_1000.csv', SINGLE_CLOB) AS x;  -- UTF-8 file
EXEC dbo.ParseCSV_Lambda @csv, N',', 1;
-- Expected: 1000 rows even though the file has ~2667 physical newlines
GO

/* ---- C) Load parsed rows into a staging table (INSERT ... EXEC) ---- */
DECLARE @csv VARCHAR(MAX);
SELECT @csv = BulkColumn
FROM OPENROWSET(BULK 'D:\S3\sample_multiline_1000.csv', SINGLE_CLOB) AS x;

IF OBJECT_ID('tempdb..#ERP_Staging') IS NOT NULL DROP TABLE #ERP_Staging;
CREATE TABLE #ERP_Staging (
    RowNum INT, CustomerName NVARCHAR(200), Address NVARCHAR(500),
    City NVARCHAR(100), State NVARCHAR(50), Notes NVARCHAR(MAX)
);
INSERT INTO #ERP_Staging (RowNum, CustomerName, Address, City, State, Notes)
EXEC dbo.ParseCSV_Lambda @csv, N',', 1;

SELECT COUNT(*) AS RowsLoaded FROM #ERP_Staging;  -- Expect 1000
SELECT TOP 10 CustomerName, Address, Notes
FROM #ERP_Staging
WHERE Address LIKE '%' + CHAR(10) + '%' OR Notes LIKE '%' + CHAR(10) + '%';
DROP TABLE #ERP_Staging;
GO

/* ---- D) Phased latency measurement ---- */
DECLARE @t0 DATETIME2(7) = SYSDATETIME();
DECLARE @csv VARCHAR(MAX);
SELECT @csv = BulkColumn FROM OPENROWSET(BULK 'D:\S3\sample_multiline_1000.csv', SINGLE_CLOB) AS x;
DECLARE @t1 DATETIME2(7) = SYSDATETIME();
DECLARE @payload NVARCHAR(MAX) = (
    SELECT CAST(@csv AS NVARCHAR(MAX)) AS csvData, N',' AS delimiter, CAST(1 AS BIT) AS skipHeader
    FROM (SELECT 1 x) d FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
DECLARE @t2 DATETIME2(7) = SYSDATETIME();
DECLARE @raw NVARCHAR(MAX);
EXEC sp_invoke_external_rest_endpoint
    @url = N'<API_ENDPOINT_URL>', @method = N'POST',
    @credential = [https://<API_GATEWAY_BASE_URL>/],
    @payload = @payload, @timeout = 60, @response = @raw OUTPUT;
DECLARE @t3 DATETIME2(7) = SYSDATETIME();
DECLARE @rows NVARCHAR(MAX) = JSON_QUERY(@raw, '$.result.rows');
DECLARE @cnt INT = (SELECT COUNT(*) FROM OPENJSON(@rows));
DECLARE @t4 DATETIME2(7) = SYSDATETIME();
SELECT DATEDIFF(MILLISECOND,@t0,@t1) AS FileRead_ms,
       DATEDIFF(MILLISECOND,@t1,@t2) AS BuildPayload_ms,
       DATEDIFF(MILLISECOND,@t2,@t3) AS LambdaRoundTrip_ms,
       DATEDIFF(MILLISECOND,@t3,@t4) AS ParseResponse_ms,
       DATEDIFF(MILLISECOND,@t0,@t4) AS Total_ms, @cnt AS RowsParsed;
GO

/* ---- E) Contrast: native BULK INSERT fails on multi-line fields ----
   FORMAT='CSV' does not support embedded row terminators (newlines in quotes),
   so this misaligns or errors -- the justification for the Lambda approach.
*/
IF OBJECT_ID('tempdb..#NativeAttempt') IS NOT NULL DROP TABLE #NativeAttempt;
CREATE TABLE #NativeAttempt (
    CustomerName NVARCHAR(200), Address NVARCHAR(500),
    City NVARCHAR(100), State NVARCHAR(50), Notes NVARCHAR(MAX)
);
BEGIN TRY
    BULK INSERT #NativeAttempt
    FROM 'D:\S3\sample_multiline_1000.csv'
    WITH (FORMAT='CSV', FIELDQUOTE='"', FIELDTERMINATOR=',', ROWTERMINATOR='0x0a', FIRSTROW=2);
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrNum, ERROR_MESSAGE() AS ErrMsg;
END CATCH;
DROP TABLE #NativeAttempt;
GO
