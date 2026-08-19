# How the `dbo.ParseCSV_Lambda` procedure works

`dbo.ParseCSV_Lambda` (in [`../sql/04-create-procedure.sql`](../sql/04-create-procedure.sql))
is the drop-in replacement for the original CLR table-valued function. It has the
**same parameters** as the CLR version (`@csvData`, `@delimiter`, `@skipHeader`),
so existing stored procedures and ETL jobs that call it do not change — only the
implementation behind the name moves from an in-process assembly to a Lambda call.

Internally the procedure does four things: build a JSON request, invoke the
Lambda through API Gateway, check for errors, and materialize the response as a
result set.

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
EXEC sp_invoke_external_rest_endpoint
    @url        = N'<API_ENDPOINT_URL>',                       -- .../prod/parse
    @method     = N'POST',
    @credential = [https://<API_GATEWAY_BASE_URL>/],           -- trailing slash
    @payload    = @payload,
    @timeout    = 60,
    @response   = @raw OUTPUT;
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

## 3. Check for errors

```sql
DECLARE @httpCode INT      = TRY_CAST(JSON_VALUE(@raw, '$.response.status.http.code') AS INT);
DECLARE @success  NVARCHAR(10) = JSON_VALUE(@raw, '$.result.success');
IF @httpCode <> 200 OR @success = 'false'
BEGIN
    DECLARE @err NVARCHAR(4000) = JSON_VALUE(@raw, '$.result.error');
    RAISERROR('CSV Parser Lambda error (HTTP %d): %s', 16, 1, @httpCode, @err);
    RETURN;
END;
```

- `$.response.status.http.code` is the transport-level HTTP status from
  `sp_invoke_external_rest_endpoint`.
- `$.result.success` / `$.result.error` are the application-level flag and
  message returned by the Lambda itself, surfaced to the caller as a clear error.

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
