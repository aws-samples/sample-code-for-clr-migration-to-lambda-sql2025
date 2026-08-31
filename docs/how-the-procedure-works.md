# How the `dbo.ParseCSV_Lambda` procedure works

`dbo.ParseCSV_Lambda` (in [`../sql/04-create-procedure.sql`](../sql/04-create-procedure.sql))
is the drop-in replacement for the original CLR table-valued function. It has the
**same parameters** as the CLR version (`@csvData`, `@delimiter`, `@skipHeader`),
so existing stored procedures and ETL jobs that call it do not change — only the
implementation behind the name moves from an in-process assembly to a Lambda call.

Internally the procedure does four things: build a JSON request, invoke the
Lambda through API Gateway (retrying transient failures with exponential
backoff), check for errors, and materialize the response as a result set.

## 1. Build the request payload

```sql
DECLARE @payload NVARCHAR(MAX) = (
    SELECT @csvData    AS csvData,
           @delimiter  AS delimiter,
           CAST(@skipHeader AS BIT) AS skipHeader
    FROM (SELECT 1 AS x) d
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
);
```

- `FOR JSON PATH, WITHOUT_ARRAY_WRAPPER` turns the parameters into a single JSON
  object — `{"csvData":"...","delimiter":",","skipHeader":true}` — that the
  Lambda handler deserializes into its `ParseRequest` class.
- `FOR JSON` automatically escapes special characters, including the newlines
  inside multi-line CSV fields (as `\n`) and embedded quotes, so the payload is
  always valid JSON.
- **`CAST(@skipHeader AS BIT)`** matters: `FOR JSON` renders a `BIT` as a real
  JSON boolean (`true`/`false`), which binds to the handler's `bool SkipHeader`.
  Emitting the string `"true"` (for example via `CASE WHEN ... THEN 'true'`)
  fails with *"The JSON value could not be converted to System.Boolean"*.

## 2. Invoke the Lambda through API Gateway

```sql
DECLARE @raw NVARCHAR(MAX);
DECLARE @maxAttempts INT = 4;   -- 1 initial try + 3 retries
DECLARE @attempt     INT = 1;
DECLARE @delaySec    INT = 1;   -- backoff seconds, doubles each retry (1s, 2s, 4s)
DECLARE @delay       CHAR(8);   -- 'HH:MM:SS' string for WAITFOR DELAY (it rejects INT/TIME)
DECLARE @httpCode    INT;
DECLARE @success     NVARCHAR(10);

WHILE @attempt <= @maxAttempts
BEGIN
    BEGIN TRY
        EXEC sp_invoke_external_rest_endpoint
            @url        = N'<API_ENDPOINT_URL>',                   -- .../prod/parse
            @method     = N'POST',
            @credential = [https://<API_GATEWAY_BASE_URL>/],       -- trailing slash
            @payload    = @payload,
            @timeout    = 60,
            @response   = @raw OUTPUT;

        SET @httpCode = TRY_CAST(JSON_VALUE(@raw, '$.response.status.http.code') AS INT);
        SET @success  = JSON_VALUE(@raw, '$.result.success');

        IF @httpCode = 200 AND (@success IS NULL OR @success <> 'false')
            BREAK;                                                 -- success

        IF (@httpCode = 429 OR @httpCode >= 500) AND @attempt < @maxAttempts
        BEGIN
            SET @delay = CONVERT(CHAR(8), DATEADD(SECOND, @delaySec, '00:00:00'), 108);  -- 'HH:MM:SS'
            WAITFOR DELAY @delay;
            SET @delaySec = @delaySec * 2;
            SET @attempt  = @attempt + 1;
            CONTINUE;
        END;

        BREAK;                                                     -- non-transient, or retries exhausted
    END TRY
    BEGIN CATCH
        IF @attempt >= @maxAttempts THROW;                         -- surface the original error
        SET @delay = CONVERT(CHAR(8), DATEADD(SECOND, @delaySec, '00:00:00'), 108);  -- 'HH:MM:SS'
        WAITFOR DELAY @delay;
        SET @delaySec = @delaySec * 2;
        SET @attempt  = @attempt + 1;
    END CATCH;
END;
```

- `sp_invoke_external_rest_endpoint` makes a synchronous HTTPS `POST` to the
  `/parse` endpoint. It requires HTTPS with a publicly trusted TLS certificate,
  which API Gateway provides.
- `@credential` references the `DATABASE SCOPED CREDENTIAL` by name. SQL Server
  injects the stored API key (`x-api-key`) as a request header at call time, so
  the key never appears in the query text, plan cache, or logs. The credential
  name must match the endpoint base URL **including the trailing slash**.
- `@timeout = 60` gives the call headroom for a .NET cold start (the default is
  30 seconds).
- The full HTTP response — status, headers, and the Lambda's body — is returned
  into `@raw`.
- **Retries.** `sp_invoke_external_rest_endpoint` does not retry on its own, so
  the call is wrapped in a bounded loop with exponential backoff (4 attempts;
  1s → 2s → 4s). It retries **only** on transient conditions — HTTP 429
  (usage-plan throttling), 5xx (API Gateway / Lambda), and hard invoke failures
  such as timeouts or network blips (caught in the `CATCH` block). Other 4xx
  errors are client errors, so the loop stops immediately (fail fast). Retrying
  is safe here because the parser is a **pure function** — the same CSV always
  produces the same rows with no side effects, so a retried call is idempotent.
  `WAITFOR DELAY` holds the session for the backoff, which reinforces this as a
  batch/file-level pattern rather than a per-row one; if you stage into a temp
  table, keep the retry loop out of any transaction that holds locks on the
  target table.

## 3. Check for errors

```sql
-- After the retry loop, @httpCode and @success hold the result of the last attempt
IF @httpCode <> 200 OR @success = 'false'
BEGIN
    DECLARE @err NVARCHAR(4000) = JSON_VALUE(@raw, '$.result.error');
    RAISERROR('CSV Parser Lambda error after %d attempt(s) (HTTP %d): %s', 16, 1, @attempt, @httpCode, @err);
    RETURN;
END;
```

- `$.response.status.http.code` is the transport-level HTTP status from
  `sp_invoke_external_rest_endpoint`.
- `$.result.success` / `$.result.error` are the application-level flag and
  message returned by the Lambda itself, surfaced to the caller as a clear error.
- The check runs **after** the retry loop, so the error is raised only once all
  retry attempts for a transient failure have been exhausted; the message
  includes the attempt count.

## 4. Materialize the response as rows

```sql
DECLARE @rows NVARCHAR(MAX) = JSON_QUERY(@raw, '$.result.rows');

SELECT
    JSON_VALUE(r.[value], '$.rowNum')    AS RowNum,
    JSON_VALUE(r.[value], '$.fields[0]') AS Col1,
    JSON_VALUE(r.[value], '$.fields[1]') AS Col2,
    JSON_VALUE(r.[value], '$.fields[2]') AS Col3,
    JSON_VALUE(r.[value], '$.fields[3]') AS Col4,
    JSON_VALUE(r.[value], '$.fields[4]') AS Col5
FROM OPENJSON(@rows) r;
```

- `OPENJSON` turns the JSON array of rows into a table, so callers receive a
  result set exactly as the CLR table-valued function produced.
- Each element has a `rowNum` and a `fields` array; `JSON_VALUE(...,'$.fields[N]')`
  projects each field into a column.

## Response-shape note: proxy vs. non-proxy integration

The JSON path to the rows depends on how the API Gateway method is integrated:

| Integration | Response shape | Rows path |
|-------------|----------------|-----------|
| **Lambda proxy** (recommended) | `"result": { "statusCode": 200, "body": "{...\"rows\":[...]}" }` | rows are inside the escaped `$.result.body` string: `JSON_QUERY(JSON_VALUE(@raw,'$.result.body'),'$.rows')` |
| **Non-proxy** (Lambda integration) | `"result": { "success": true, "rows": [...] }` | `JSON_QUERY(@raw, '$.result.rows')` |

The shipped procedure uses `$.result.rows`. If your integration differs, run
`PRINT @raw;` after the call to inspect the exact shape and adjust the path.

## Backward compatibility with existing callers

The procedure returns a result set, so callers that previously did
`INSERT INTO staging SELECT ... FROM dbo.ParseCSV(...)` switch to
`INSERT INTO staging EXEC dbo.ParseCSV_Lambda(...)`. See
[`../sql/05-tests.sql`](../sql/05-tests.sql) for a staging-table example.
