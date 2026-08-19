# Sample data

CSV files used to test the parser, including cases that native
`BULK INSERT ... FORMAT='CSV'` cannot handle.

| File | Columns | Rows | Notable content |
|------|---------|------|-----------------|
| `sample_multiline_small.csv` | 4 | 3 | Multi-line quoted fields, embedded commas, escaped quotes |
| `sample_multiline_1000.csv` | 5 | 1000 | Multi-line fields in Address/Notes; ~2667 physical newlines for 1000 logical records |

The 5-column `sample_multiline_1000.csv` matches the 5-output-column CLR
function and the `dbo.ParseCSV_Lambda` procedure (Col1–Col5 =
CustomerName, Address, City, State, Notes).

## Why these files matter

Each file contains newlines **inside quoted fields**. Native
`BULK INSERT FORMAT='CSV'` treats embedded newlines as row terminators and
misaligns or errors, while the CLR/Lambda parser correctly reassembles the
logical records. Upload a file to Amazon S3 and download it to the instance
with `msdb.dbo.rds_download_from_s3` to test the S3 flow (see
[`../sql/05-tests.sql`](../sql/05-tests.sql)).
