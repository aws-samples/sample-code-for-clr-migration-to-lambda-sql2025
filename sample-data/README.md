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
logical records.

## Loading large CSV files via RDS S3 integration

The inline string tests in [`../sql/05-tests.sql`](../sql/05-tests.sql) are the
simplest way to try the parser, but they are only practical for small snippets.
To test with **real files** — such as `sample_multiline_1000.csv` — load the
file from Amazon S3 into SQL Server instead of pasting it inline.

On Amazon RDS for SQL Server this is done with **S3 integration**:

1. Enable S3 integration on the RDS instance and attach an IAM role that grants
   access to your S3 bucket (see the AWS docs:
   [Integrating an RDS for SQL Server DB instance with Amazon S3](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/User.SQLServer.Options.S3-integration.html)).
2. Upload the CSV to your bucket.
3. Download it onto the instance with `msdb.dbo.rds_download_from_s3`:

   ```sql
   EXEC msdb.dbo.rds_download_from_s3
       @s3_arn_of_file = 'arn:aws:s3:::YOUR-BUCKET/sample_multiline_1000.csv',
       @rds_file_path  = 'D:\S3\sample_multiline_1000.csv',
       @overwrite_file = 1;
   ```

4. Read the downloaded file with `OPENROWSET(BULK ..., SINGLE_CLOB)` and pass it
   to the parser (use `SINGLE_CLOB` for UTF-8, `SINGLE_NCLOB` for UTF-16;
   requires `ADMINISTER BULK OPERATIONS`).

Sections B–E of [`../sql/05-tests.sql`](../sql/05-tests.sql) show this end to
end. If you only want to try the inline examples (section A), you can skip the
S3 integration and IAM role setup entirely.
