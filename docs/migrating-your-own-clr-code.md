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

Each `[SqlFunction]` parameter becomes a property on a JSON request class:

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

Compare [`clr-reference/CsvParser.cs`](../clr-reference/CsvParser.cs) (before) with
[`lambda/CsvParserLambda/Function.cs`](../lambda/CsvParserLambda/Function.cs) (after).
`SplitLines` and `SplitRespectingQuotes` are identical in both; only the wrapper differs.
