using System;
using System.Collections;
using System.Data.SqlTypes;
using System.Text;
using Microsoft.SqlServer.Server;

/// <summary>
/// Original SQL CLR table-valued function that parses complex CSV.
/// This is the pre-upgrade code that works on Amazon RDS for SQL Server 2016
/// (PERMISSION_SET = SAFE) but fails after upgrading to 2017+ due to CLR strict security.
///
/// It is included here only as the "before" reference. The AWS Lambda replacement
/// (../lambda/CsvParserLambda/Function.cs) reuses SplitLines and SplitRespectingQuotes
/// verbatim and replaces the [SqlFunction]/FillRow wrapper with a Lambda handler.
///
/// Build (on a machine with .NET Framework):
///   csc /target:library /out:CsvParser.dll CsvParser.cs
/// Convert to hex for CREATE ASSEMBLY on RDS (PowerShell):
///   $bytes = [System.IO.File]::ReadAllBytes("CsvParser.dll")
///   "0x" + [BitConverter]::ToString($bytes).Replace("-","") | Set-Content CsvParser_hex.txt -NoNewline
/// </summary>
public class CsvParser
{
    [SqlFunction(
        FillRowMethodName = "FillRow",
        TableDefinition = "RowNum INT, Col1 NVARCHAR(4000), Col2 NVARCHAR(4000), " +
                          "Col3 NVARCHAR(4000), Col4 NVARCHAR(4000), Col5 NVARCHAR(4000)")]
    public static IEnumerable ParseCSV(SqlString csvData, SqlString delimiter)
    {
        if (csvData.IsNull || csvData.Value.Length == 0)
            yield break;

        string delim = delimiter.IsNull ? "," : delimiter.Value;
        char delimChar = delim[0];
        string[] lines = SplitLines(csvData.Value);

        int rowNum = 0;
        foreach (string line in lines)
        {
            if (string.IsNullOrEmpty(line) || line.Trim().Length == 0) continue;
            rowNum++;
            string[] fields = SplitRespectingQuotes(line.TrimEnd('\r'), delimChar);
            yield return new object[] { rowNum, fields };
        }
    }

    public static void FillRow(object obj, out SqlInt32 rowNum,
        out SqlString col1, out SqlString col2, out SqlString col3,
        out SqlString col4, out SqlString col5)
    {
        object[] row = (object[])obj;
        rowNum = new SqlInt32((int)row[0]);
        string[] fields = (string[])row[1];
        col1 = fields.Length > 0 ? new SqlString(fields[0]) : SqlString.Null;
        col2 = fields.Length > 1 ? new SqlString(fields[1]) : SqlString.Null;
        col3 = fields.Length > 2 ? new SqlString(fields[2]) : SqlString.Null;
        col4 = fields.Length > 3 ? new SqlString(fields[3]) : SqlString.Null;
        col5 = fields.Length > 4 ? new SqlString(fields[4]) : SqlString.Null;
    }

    // ── Business logic reused unchanged by the Lambda replacement ──

    private static string[] SplitLines(string input)
    {
        var lines = new ArrayList();
        var line = new StringBuilder();
        bool inQuotes = false;
        int i = 0;

        while (i < input.Length)
        {
            char c = input[i];
            if (c == '"')
            {
                if (inQuotes && i + 1 < input.Length && input[i + 1] == '"')
                {
                    line.Append('"');
                    line.Append('"');
                    i += 2;
                    continue;
                }
                inQuotes = !inQuotes;
                line.Append(c);
            }
            else if (c == '\n' && !inQuotes)
            {
                lines.Add(line.ToString());
                line.Clear();
            }
            else
            {
                line.Append(c);
            }
            i++;
        }
        if (line.Length > 0)
            lines.Add(line.ToString());
        return (string[])lines.ToArray(typeof(string));
    }

    private static string[] SplitRespectingQuotes(string input, char delimiter)
    {
        var fields = new ArrayList();
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
                    field.Append('"');
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
        return (string[])fields.ToArray(typeof(string));
    }
}
