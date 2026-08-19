using System.Text;
using System.Text.Json;
using Amazon.Lambda.Core;
using Amazon.Lambda.APIGatewayEvents;

// Use the System.Text.Json Lambda serializer.
[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace CsvParserLambda;

/// <summary>
/// AWS Lambda replacement for a SQL CLR CSV table-valued function.
///
/// The core parsing logic (SplitLines + SplitRespectingQuotes) is copied
/// verbatim from the original CLR assembly (see ../../clr-reference/CsvParser.cs).
/// Only the entry-point wrapper changed: a Lambda handler that accepts a JSON
/// request and returns rows as a JSON array.
/// </summary>
public class Function
{
    public APIGatewayProxyResponse FunctionHandler(
        APIGatewayProxyRequest request, ILambdaContext context)
    {
        try
        {
            var body = JsonSerializer.Deserialize<ParseRequest>(
                request.Body ?? "{}",
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true }
            );

            if (string.IsNullOrEmpty(body?.CsvData))
            {
                return CreateResponse(400, new { success = false, error = "csvData is required" });
            }

            string delimiter = string.IsNullOrEmpty(body.Delimiter) ? "," : body.Delimiter;
            char delimChar = delimiter[0];
            bool skipHeader = body.SkipHeader;

            var rows = new List<ParsedRow>();
            string[] lines = SplitLines(body.CsvData);
            int rowNum = 0;
            bool isFirst = true;

            foreach (string line in lines)
            {
                if (string.IsNullOrWhiteSpace(line)) continue;

                if (isFirst && skipHeader)
                {
                    isFirst = false;
                    continue;
                }
                isFirst = false;

                rowNum++;
                string[] fields = SplitRespectingQuotes(line.TrimEnd('\r'), delimChar);
                rows.Add(new ParsedRow { RowNum = rowNum, Fields = fields });
            }

            var result = new { success = true, rowCount = rows.Count, rows };
            return CreateResponse(200, result);
        }
        catch (JsonException ex)
        {
            context.Logger.LogError($"JSON parse error: {ex.Message}");
            return CreateResponse(400, new { success = false, error = "Invalid JSON in request body" });
        }
        catch (Exception ex)
        {
            context.Logger.LogError($"Unhandled error: {ex.Message}");
            return CreateResponse(500, new { success = false, error = "Internal server error" });
        }
    }

    /// <summary>
    /// RFC 4180 compliant CSV field splitter.
    /// Handles quoted fields, embedded delimiters, and escaped quotes ("").
    /// COPIED VERBATIM FROM THE CLR ASSEMBLY.
    /// </summary>
    private static string[] SplitRespectingQuotes(string input, char delimiter)
    {
        var fields = new List<string>();
        var field = new StringBuilder();
        bool inQuotes = false;
        int i = 0;

        while (i < input.Length)
        {
            char c = input[i];
            if (c == '"')
            {
                if (inQuotes && i + 1 < input.Length && input[i + 1] == '"')
                {
                    field.Append('"'); // escaped quote -> literal quote
                    i += 2;
                    continue;
                }
                inQuotes = !inQuotes;
            }
            else if (c == delimiter && !inQuotes)
            {
                fields.Add(field.ToString());
                field.Clear();
            }
            else
            {
                field.Append(c);
            }
            i++;
        }
        fields.Add(field.ToString());
        return fields.ToArray();
    }

    /// <summary>
    /// Splits into logical records, respecting quotes so that a newline inside a
    /// quoted field does NOT start a new record. Quote characters are preserved
    /// so the field-level splitter can use them.
    /// COPIED VERBATIM FROM THE CLR ASSEMBLY.
    /// </summary>
    private static string[] SplitLines(string input)
    {
        var lines = new List<string>();
        var currentLine = new StringBuilder();
        bool inQuotes = false;

        for (int i = 0; i < input.Length; i++)
        {
            char c = input[i];
            if (c == '"')
            {
                if (inQuotes && i + 1 < input.Length && input[i + 1] == '"')
                {
                    currentLine.Append('"');
                    currentLine.Append('"');
                    i++;
                    continue;
                }
                inQuotes = !inQuotes;
                currentLine.Append(c);
            }
            else if (c == '\n' && !inQuotes)
            {
                lines.Add(currentLine.ToString());
                currentLine.Clear();
            }
            else if (c == '\r' && !inQuotes)
            {
                continue;
            }
            else
            {
                currentLine.Append(c);
            }
        }

        if (currentLine.Length > 0)
            lines.Add(currentLine.ToString());

        return lines.ToArray();
    }

    private static APIGatewayProxyResponse CreateResponse(int statusCode, object body)
    {
        return new APIGatewayProxyResponse
        {
            StatusCode = statusCode,
            Headers = new Dictionary<string, string> { { "Content-Type", "application/json" } },
            Body = JsonSerializer.Serialize(body, new JsonSerializerOptions
            {
                PropertyNamingPolicy = JsonNamingPolicy.CamelCase
            })
        };
    }
}

public class ParseRequest
{
    public string CsvData { get; set; } = "";
    public string Delimiter { get; set; } = ",";
    public bool SkipHeader { get; set; } = false;
}

public class ParsedRow
{
    public int RowNum { get; set; }
    public string[] Fields { get; set; } = Array.Empty<string>();
}
