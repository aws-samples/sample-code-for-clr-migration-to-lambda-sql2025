# CLR reference (the "before" code)

`CsvParser.cs` is the original SQL CLR table-valued function this sample
replaces. It is provided so you can reproduce the pre-upgrade state on
Amazon RDS for SQL Server 2016 and observe the failure after upgrading to
2017 or later.

You do **not** need this to run the Lambda solution — it is reference only.

## Build the DLL

On a machine with the .NET Framework compiler:

```bat
csc /target:library /out:CsvParser.dll CsvParser.cs
```

(The .NET Framework `csc` is typically at
`C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`.)


"C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /target:library /out:CsvParser.dll CsvParser.cs


## Convert the DLL to hex for CREATE ASSEMBLY on RDS

RDS has no file system access, so `CREATE ASSEMBLY` uses the binary as hex.

PowerShell:

```powershell
$bytes = [System.IO.File]::ReadAllBytes("CsvParser.dll")
$hex   = "0x" + [BitConverter]::ToString($bytes).Replace("-","")
$hex | Set-Content -Path "CsvParser_hex.txt" -NoNewline
"Hex length: $($hex.Length)"   # should equal (DLL bytes * 2) + 2
```

Paste the resulting `0x...` string into
[`../sql/01-clr-setup-2016.sql`](../sql/01-clr-setup-2016.sql).

## Relationship to the Lambda

`SplitLines` and `SplitRespectingQuotes` are identical to the versions in the
Lambda's [`Function.cs`](../lambda/CsvParserLambda/Function.cs). The migration
removes the `[SqlFunction]` attribute, the `FillRow` method, and the `SqlString`
types, and adds a Lambda handler that returns JSON.
