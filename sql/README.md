# SQL scripts

Run these in order with SQL Server Management Studio (SSMS). Replace the
placeholders (`ERPDatabase`, `<API_ENDPOINT_URL>`, `<API_GATEWAY_BASE_URL>`,
`<YOUR_API_KEY>`, and the CLR hex) with your values.

| Script | Runs on | Purpose |
|--------|---------|---------|
| `01-clr-setup-2016.sql` | RDS SQL Server 2016 | Deploy the CLR CSV parser (the working "before" state) |
| `02-reproduce-failure.sql` | 2017 / 2019 / 2022 / 2025 | Show the CLR failure after upgrade (HRESULT 0x8013150A) |
| `03-sql2025-setup.sql` | RDS SQL Server 2025 | Verify the REST endpoint feature; create master key + credential |
| `04-create-procedure.sql` | RDS SQL Server 2025 | Create `dbo.ParseCSV_Lambda` (invokes the Lambda). See [How the procedure works](../docs/how-the-procedure-works.md) for a line-by-line explanation. |
| `05-tests.sql` | RDS SQL Server 2025 | Inline tests, S3 file read, staging load, latency, native-BULK-INSERT contrast |
| `06-cleanup.sql` | any | Drop the objects created by this sample |

## Key gotchas (baked into the scripts)

- **Credential name needs a trailing slash** to match the endpoint base URL
  (`https://<host>/`). Without it: "Cannot find the credential ...".
- **`skipHeader` must be a JSON boolean** — the procedure uses
  `CAST(@skipHeader AS BIT)`. A string `"true"` fails to bind in the Lambda.
- **API Gateway response path** — with Lambda proxy integration the rows are at
  `$.result.rows`. For non-proxy integration they are inside an escaped
  `$.result.body` string; `PRINT @raw` to confirm and adjust the path.
- **`OPENROWSET(BULK ... SINGLE_CLOB)`** — use `SINGLE_CLOB` for UTF-8 files,
  `SINGLE_NCLOB` for UTF-16. Requires `ADMINISTER BULK OPERATIONS`.
