/* =====================================================================
   04-create-procedure.sql
   Create the stored procedure that invokes the Lambda function via
   sp_invoke_external_rest_endpoint. It mirrors the original CLR function
   signature so downstream code needs no changes.

   Replace:
     <API_ENDPOINT_URL>      full URL, e.g.
                             https://abc123.execute-api.us-east-1.amazonaws.com/prod/parse
     <API_GATEWAY_BASE_URL>  base host, e.g.
                             abc123.execute-api.us-east-1.amazonaws.com
   (credential name must include the trailing slash, matching 03-sql2025-setup.sql)
   ===================================================================== */
USE DemoDB;
GO

CREATE OR ALTER PROCEDURE dbo.ParseCSV_Lambda
    @csvData    NVARCHAR(MAX),
    @delimiter  NVARCHAR(10) = N',',
    @skipHeader BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- Build JSON payload. CAST(... AS BIT) renders skipHeader as JSON true/false.
    -- Sending the string 'true' would fail to bind to the handler's bool.
    DECLARE @payload NVARCHAR(MAX) = (
        SELECT @csvData AS csvData,
               @delimiter AS delimiter,
               CAST(@skipHeader AS BIT) AS skipHeader
        FROM (SELECT 1 AS x) d
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    DECLARE @raw NVARCHAR(MAX);
    EXEC sp_invoke_external_rest_endpoint
        @url        = N'<API_ENDPOINT_URL>',
        @method     = N'POST',
        @credential = [https://<API_GATEWAY_BASE_URL>/],   -- trailing slash
        @payload    = @payload,
        @timeout    = 60,
        @response   = @raw OUTPUT;

    -- Surface transport + application-level errors
    DECLARE @httpCode INT = TRY_CAST(JSON_VALUE(@raw, '$.response.status.http.code') AS INT);
    DECLARE @success  NVARCHAR(10) = JSON_VALUE(@raw, '$.result.success');
    IF @httpCode <> 200 OR @success = 'false'
    BEGIN
        DECLARE @err NVARCHAR(4000) = JSON_VALUE(@raw, '$.result.error');
        RAISERROR('CSV Parser Lambda error (HTTP %d): %s', 16, 1, @httpCode, @err);
        RETURN;
    END;

    -- With Lambda proxy integration, rows are at $.result.rows.
    -- If you use a non-proxy integration, the rows are inside an escaped
    -- $.result.body string; PRINT @raw to confirm your shape and adjust.
    DECLARE @rows NVARCHAR(MAX) = JSON_QUERY(@raw, '$.result.rows');

    SELECT
        JSON_VALUE(r.[value], '$.rowNum')    AS RowNum,
        JSON_VALUE(r.[value], '$.fields[0]') AS Col1,
        JSON_VALUE(r.[value], '$.fields[1]') AS Col2,
        JSON_VALUE(r.[value], '$.fields[2]') AS Col3,
        JSON_VALUE(r.[value], '$.fields[3]') AS Col4,
        JSON_VALUE(r.[value], '$.fields[4]') AS Col5
    FROM OPENJSON(@rows) r;
END;
GO
