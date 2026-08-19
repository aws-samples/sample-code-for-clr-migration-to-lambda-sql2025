# CsvParserLambda (.NET)

AWS Lambda replacement for a SQL CLR CSV table-valued function. The handler
accepts a JSON request, parses CSV that is RFC 4180 compliant (quoted fields,
embedded delimiters, escaped quotes `""`, and multi-line quoted values), and
returns rows as a JSON array.

The parsing methods (`SplitLines`, `SplitRespectingQuotes`) are copied verbatim
from the original CLR assembly in [`../../clr-reference/CsvParser.cs`](../../clr-reference/CsvParser.cs).
Only the entry-point wrapper changed.

## Request / response contract

Request body (JSON):

```json
{ "csvData": "a,b,c\n\"x, y\",\"z\",\"w\"", "delimiter": ",", "skipHeader": true }
```

Response body (JSON):

```json
{ "success": true, "rowCount": 1, "rows": [ { "rowNum": 1, "fields": ["x, y", "z", "w"] } ] }
```

## Build

Requires the .NET SDK and the Amazon.Lambda.Tools global tool.

```bash
git clone https://github.com/aws-samples/sample-code-for-clr-migration-to-lambda-sql2025
cd sample-code-for-clr-migration-to-lambda-sql2025/lambda/CsvParserLambda
dotnet tool install -g Amazon.Lambda.Tools   # one time
dotnet lambda package -o CsvParserLambda.zip
```

Handler: `CsvParserLambda::CsvParserLambda.Function::FunctionHandler`

## Test locally

```bash
dotnet lambda invoke-function --payload file://test-event.json
```

Or use the console **Test** tab with `test-event.json` (an API Gateway proxy event).

## Notes

- `TargetFramework` is `net10.0` (the current default .NET runtime on AWS Lambda).
  To target another supported Lambda .NET runtime, update the `.csproj` and
  `aws-lambda-tools-defaults.json` (`function-runtime`).
- Different builds of the same source produce different bytes (MVID/timestamp);
  that is expected and does not affect behavior.
