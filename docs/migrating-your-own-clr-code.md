# Migrating your own CLR code to AWS Lambda

This sample uses a CSV parser, but the method applies to any CLR assembly.
The principle: **keep your business logic, replace only the SQL host plumbing.**

## Step 1: Separate logic from plumbing

Open your CLR `.cs` file and classify each part:

| In your CLR `.cs`, find… | Action |
|---|---|
| Private helper methods (parsing, calculations, transformations) | **Copy unchanged** |
| `using Microsoft.SqlServer.Server;` | Replace with `Amazon.Lambda.Core;` + `Amazon.Lambda.APIGatewayEvents;` |
| `[SqlFunction(...)]` / `[SqlProcedure]` | Replace with a Lambda handler method |
| `SqlString`, `SqlInt32`, `SqlBoolean` | Replace with plain `string`, `int`, `bool` + a request/response DTO |
| `.IsNull` / `SqlString.Null` | Standard C# null checks (`?`, `is null`) |
| `FillRow(...)` + `IEnumerable` | Build a `List<>` and serialize to JSON |
| `SqlContext`, `SqlPipe` | HTTP response object |

Any method containing none of these markers is pure logic — copy it verbatim.

## Step 2: Map the inputs

Each `[SqlFunction]` parameter becomes a property on a JSON request class. Lambda
deserializes the incoming JSON event into your class using a serializer such as
`Amazon.Lambda.Serialization.SystemTextJson` (see
[Define Lambda function handler in C#](https://docs.aws.amazon.com/lambda/latest/dg/csharp-handler.html)
for the input/output model and serialization options):

```csharp
// CLR:    public static SqlString Foo(SqlString input, SqlString pattern)
// Lambda: request body { "input": "...", "pattern": "..." } -> a DTO
public class ParseRequest
{
    public string Input { get; set; } = "";
    public string Pattern { get; set; } = "";
}
```

## Step 3: Map the outputs

| CLR return type | Lambda equivalent |
|-----------------|-------------------|
| Scalar function (`SqlString`/`SqlBit`) | A single JSON value in the response body |
| Table-valued function (`FillRow` + `IEnumerable`) | A JSON array; T-SQL uses `OPENJSON()` to materialize rows |

## Cases that need more than a wrapper swap

| CLR pattern | Why it needs rework |
|-------------|---------------------|
| `DataAccessKind.Read` (queries SQL tables via the context connection) | Lambda has no in-process SQL connection; it needs a separate connection string, changing the security/latency profile |
| Streaming very large result sets via `FillRow` | `FillRow` streams row-by-row; Lambda returns one JSON payload (6 MB cap) — chunk or hand off via S3 |
| `PERMISSION_SET = EXTERNAL_ACCESS` / `UNSAFE` (file/network access) | Often easier in Lambda, but the surrounding code and IAM permissions change |

## Worked example

Compare [`clr-reference/CsvParser.cs`](../clr-reference/CsvParser.cs) (which is working in SQL 2016) with
[`lambda/CsvParserLambda/Function.cs`](../lambda/CsvParserLambda/Function.cs) (which will work in SQL Server 2025).
`SplitLines` and `SplitRespectingQuotes` are identical in both; only the wrapper differs.

## Public documentation references

The conversion approach in this guide (separating business logic from the SQL
host wrapper) is specific to this migration and is not documented elsewhere.
The building blocks it relies on, however, are covered by official documentation:

**AWS Lambda (.NET)**

- [Define Lambda function handler in C#](https://docs.aws.amazon.com/lambda/latest/dg/csharp-handler.html) — handler signature, input/output types, and JSON serialization
- [Building Lambda functions with C#](https://docs.aws.amazon.com/lambda/latest/dg/lambda-csharp.html) — overview of the .NET programming model
- [Deploy .NET Lambda functions with .zip file archives](https://docs.aws.amazon.com/lambda/latest/dg/csharp-package.html) — packaging
- [Using the .NET Lambda Global CLI](https://docs.aws.amazon.com/lambda/latest/dg/csharp-package-cli.html) — `Amazon.Lambda.Tools`, `dotnet lambda package`

**Amazon RDS for SQL Server 2025 integration**

- [sp_invoke_external_rest_endpoint (Microsoft Learn)](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-invoke-external-rest-endpoint-transact-sql) — the stored procedure that invokes the REST endpoint
- [Invoke AWS services directly from Amazon RDS for SQL Server 2025](https://aws.amazon.com/blogs/database/invoke-aws-services-directly-from-amazon-rds-for-sql-server-2025/) — feature walkthrough
- [Addressing CLR assembly deprecation in Amazon RDS for SQL Server](https://aws.amazon.com/blogs/database/addressing-clr-assembly-deprecation-in-amazon-rds-for-sql-server/) — the parent post and the four replacement options

**SQL CLR background (Microsoft Learn)**

- [CLR strict security](https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/clr-strict-security) — why CLR assemblies fail on SQL Server 2017 and later
- [OPENJSON (Transact-SQL)](https://learn.microsoft.com/en-us/sql/t-sql/functions/openjson-transact-sql) and [FOR JSON (Transact-SQL)](https://learn.microsoft.com/en-us/sql/relational-databases/json/format-query-results-as-json-with-for-json-sql-server) — building the request and materializing the response in T-SQL
