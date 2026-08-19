# Migrate SQL CLR assemblies to AWS Lambda on Amazon RDS for SQL Server 2025

Sample code that shows how to replace an unsupported SQL Common Language Runtime
(CLR) assembly on Amazon RDS for SQL Server with an AWS Lambda function invoked
natively from Transact-SQL through `sp_invoke_external_rest_endpoint`.

This repository is the hands-on companion to the AWS Database Blog post
[Addressing CLR assembly deprecation in Amazon RDS for SQL Server](https://aws.amazon.com/blogs/database/addressing-clr-assembly-deprecation-in-amazon-rds-for-sql-server/),
implementing **Option A** (external REST endpoint invocation) for CLR logic that
has no native T-SQL equivalent.

## Background

Microsoft SQL Server 2016 reaches end of extended support on July 14, 2026.
User-defined CLR assemblies are not supported on Amazon RDS for SQL Server 2017
and later, because CLR strict security treats every assembly as `UNSAFE` and the
sysadmin permissions needed to work around it are unavailable on the managed
platform. When you upgrade from 2016, CLR calls begin to fail with
`System.IO.FileLoadException ... (Exception from HRESULT: 0x8013150A)`.

Use native features first: SQL Server 2025 adds `REGEXP_*` for regex, and S3
integration with `BULK INSERT ... FORMAT='CSV'` handles standard CSV loads. The
Lambda pattern in this repo is for logic with **no** native equivalent. The
running example is a CSV parser that handles **multi-line quoted fields**
(newlines inside quotes) — something `BULK INSERT` cannot do.

## Architecture

```
Amazon RDS for SQL Server 2025
  --> sp_invoke_external_rest_endpoint (HTTPS POST; API key in a DATABASE SCOPED CREDENTIAL)
    --> Amazon API Gateway (REST API, Lambda proxy integration, API key + usage plan)
      --> AWS Lambda (.NET; same parsing logic as the original CLR)
        --> JSON response --> OPENJSON() materializes rows in T-SQL
```

The migration keeps the proven parsing logic and rewrites only the entry-point
wrapper: the `[SqlFunction]`/`FillRow` shell becomes a Lambda handler.

## Repository layout

```
.
├── lambda/CsvParserLambda/    # .NET Lambda project (the replacement)
├── clr-reference/             # Original CLR source (the "before" code), reference only
├── sql/                       # Ordered T-SQL scripts (setup, failure, 2025 config, tests, cleanup)
├── sample-data/               # CSV test files with multi-line fields
└── docs/                      # Additional documentation
```

## Prerequisites

- An Amazon RDS for SQL Server 2025 instance with `external rest endpoint enabled = 1`
  in a custom parameter group (Parameter Group Status `in-sync`)
- SSMS connected as the master user
- The .NET SDK and `Amazon.Lambda.Tools` to build the Lambda package
- (Optional) An RDS SQL Server 2016 instance to reproduce the "before" state
- (Optional) Amazon S3 integration enabled on the instance to test file ingestion

## Walkthrough

### 1. Build the Lambda package

```bash
git clone https://github.com/aws-samples/sample-code-for-clr-migration-to-lambda-sql2025
cd sample-code-for-clr-migration-to-lambda-sql2025/lambda/CsvParserLambda
dotnet tool install -g Amazon.Lambda.Tools   # one time
dotnet lambda package -o CsvParserLambda.zip
```

See [`lambda/CsvParserLambda/README.md`](lambda/CsvParserLambda/README.md).

### 2. Create the Lambda function (console)

1. Lambda console → **Create function** → **Author from scratch**.
2. Name `clr-csv-parser`, choose a .NET runtime, architecture `x86_64`, **Create function**.
3. **Code** tab → **Upload from** → **.zip file** → upload `CsvParserLambda.zip` → **Save**.
4. **Runtime settings** → **Edit** → Handler:
   `CsvParserLambda::CsvParserLambda.Function::FunctionHandler`.
5. **Configuration → General configuration** → Timeout 60s, Memory 512 MB.
6. Verify on the **Test** tab using [`lambda/CsvParserLambda/test-event.json`](lambda/CsvParserLambda/test-event.json).

### 3. Create the REST API (console)

1. API Gateway → **Create API** → **REST API** → **Build**. Name `clr-csv-parser-api`, **Regional**.
2. **Create resource** `parse` → select `/parse` → **Create method** → **POST**.
3. Integration type **Lambda function**; **turn ON "Lambda proxy integration"**
   (required — the handler reads `request.Body`, populated only in proxy mode).
   Select `clr-csv-parser` → **Create method**.
4. Select **POST** → **Method request** → **Edit** → **API key required** = true → **Save**.
5. **Deploy API** → new stage `prod` → **Deploy**. Copy the **Invoke URL**
   (your endpoint is that URL + `/parse`). Redeploy after any integration change.

### 4. Create an API key and usage plan (console)

1. **API keys** → **Create API key** `clr-csv-parser-key` → **Show** and copy the value.
2. **Usage plans** → **Create usage plan** `clr-csv-parser-plan` with throttling/quota.
3. Associate stage `clr-csv-parser-api:prod` and the API key `clr-csv-parser-key`.

### 5. Configure and invoke from SQL Server 2025

Run the scripts in [`sql/`](sql/README.md), replacing the placeholders:

```
sql/03-sql2025-setup.sql   -- master key + DATABASE SCOPED CREDENTIAL (note trailing slash)
sql/04-create-procedure.sql -- dbo.ParseCSV_Lambda (mirrors the CLR signature)
sql/05-tests.sql            -- inline test, S3 file read, staging load, latency, BULK INSERT contrast
```

For a line-by-line explanation of how `dbo.ParseCSV_Lambda` builds the request, invokes the Lambda, handles errors, and materializes rows, see [How the procedure works](docs/how-the-procedure-works.md).

Quick test:

```sql
DECLARE @csv NVARCHAR(MAX) = N'CustomerName,Address
"Acme, Inc.","123 Main St
Building A"';
EXEC dbo.ParseCSV_Lambda @csv, N',', 1;
-- One row; "Acme, Inc." stays a single field and the multi-line address is preserved.
```

## Common gotchas

- **Credential name needs a trailing slash** (`https://<host>/`) or SQL Server
  reports the credential cannot be found.
- **`skipHeader` must be a JSON boolean** — the procedure uses
  `CAST(@skipHeader AS BIT)`. A string `"true"` fails to bind in the Lambda.
- **Enable Lambda proxy integration and redeploy the stage**, or the function
  returns `csvData is required` on an HTTP 200 response.
- **Response path** is `$.result.rows` with proxy integration; for non-proxy it
  is inside an escaped `$.result.body` string. Use `PRINT @raw` to confirm.

## Performance and cost

Each call is a network round-trip, so this pattern suits batch/file-level
operations, not per-row calls in a hot query. In testing, parsing a 1,000-row
multi-line file took ~235 ms end-to-end on a warm function; the first (cold)
call runs 1–3 seconds. `sp_invoke_external_rest_endpoint` allows up to a 100 MB
payload; the practical ceiling is Lambda's 6 MB synchronous response, so have the
Lambda read very large files directly from Amazon S3. For batch ETL, Lambda and
API Gateway costs are typically well under $1/month.

## Clean up

Run [`sql/06-cleanup.sql`](sql/06-cleanup.sql) and delete the Lambda function,
the API Gateway API (stage, usage plan, API key), and any test RDS instances to
avoid ongoing charges.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.
