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

    -- Retry on transient failures. sp_invoke_external_rest_endpoint does NOT
    -- retry automatically, so we wrap it in a bounded loop with exponential
    -- backoff. We retry only on HTTP 429 (usage-plan throttling), 5xx, and hard
    -- invoke failures (timeouts / network blips caught in CATCH). A 4xx other
    -- than 429 is a client error, so we fail fast. The parser is a pure function
    -- (same input -> same output, no side effects), so retries are idempotent.
    DECLARE @raw NVARCHAR(MAX);
    DECLARE @maxAttempts INT = 4;    -- 1 initial try + 3 retries
    DECLARE @attempt     INT = 1;
    DECLARE @delaySec    INT = 1;    -- backoff seconds, doubles each retry (1s, 2s, 4s)
    DECLARE @delay       CHAR(8);    -- 'HH:MM:SS' string for WAITFOR DELAY (it rejects INT/TIME)
    DECLARE @httpCode    INT;
    DECLARE @success     NVARCHAR(10);

    WHILE @attempt <= @maxAttempts
    BEGIN
        BEGIN TRY
            EXEC sp_invoke_external_rest_endpoint
                @url        = N'<API_ENDPOINT_URL>',
                @method     = N'POST',
                @credential = [https://<API_GATEWAY_BASE_URL>/],   -- trailing slash
                @payload    = @payload,
                @timeout    = 60,
                @response   = @raw OUTPUT;

            SET @httpCode = TRY_CAST(JSON_VALUE(@raw, '$.response.status.http.code') AS INT);
            SET @success  = JSON_VALUE(@raw, '$.result.success');

            -- Success: stop retrying
            IF @httpCode = 200 AND (@success IS NULL OR @success <> 'false')
                BREAK;

            -- Transient status (429 rate limit, 5xx): retry with exponential backoff
            IF (@httpCode = 429 OR @httpCode >= 500) AND @attempt < @maxAttempts
            BEGIN
                SET @delay = CONVERT(CHAR(8), DATEADD(SECOND, @delaySec, '00:00:00'), 108);  -- 'HH:MM:SS'
                WAITFOR DELAY @delay;
                SET @delaySec = @delaySec * 2;
                SET @attempt  = @attempt + 1;
                CONTINUE;
            END;

            -- Non-transient error, or retries exhausted: stop and report below
            BREAK;
        END TRY
        BEGIN CATCH
            -- Hard failure invoking the endpoint (timeout, network blip). Retry if attempts remain.
            IF @attempt >= @maxAttempts
                THROW;   -- exhausted retries; surface the original error
            SET @delay = CONVERT(CHAR(8), DATEADD(SECOND, @delaySec, '00:00:00'), 108);  -- 'HH:MM:SS'
            WAITFOR DELAY @delay;
            SET @delaySec = @delaySec * 2;
            SET @attempt  = @attempt + 1;
        END CATCH;
    END;

    -- Surface transport + application-level errors after the retry loop
    IF @httpCode <> 200 OR @success = 'false'
    BEGIN
        DECLARE @err NVARCHAR(4000) = JSON_VALUE(@raw, '$.result.error');
        RAISERROR('CSV Parser Lambda error after %d attempt(s) (HTTP %d): %s', 16, 1, @attempt, @httpCode, @err);
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
