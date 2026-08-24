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

 What each line does

  1. git clone ... — Downloads the sample repository to your machine so you have the .NET Lambda source code (the replacement for the
  old CLR assembly).
  2. cd .../lambda/CsvParserLambda — Moves into the Lambda project folder. This is the .NET project that contains the same CSV parsing
  logic that used to run as the in-database CLR assembly — now rewritten with a Lambda handler as its entry point.
  3. dotnet tool install -g Amazon.Lambda.Tools — Installs the AWS Lambda .NET CLI tooling globally (the # one time comment means you
  only need to do this once per machine, not every build). This adds the dotnet lambda command used in the next step.
  4. dotnet lambda package -o CsvParserLambda.zip — Compiles the .NET project and bundles the compiled code plus its dependencies into a
  deployment ZIP (CsvParserLambda.zip). This is the artifact you'll upload to Lambda in Step 2.

  Why this step exists?

  Before you can run the parsing logic in AWS, you have to turn the .NET source into a deployable package. This step produces the .zip
   that becomes the Lambda function — it's the "build the replacement" stage. The original CLR code lives in the database as a
  compiled assembly; here we produce the equivalent compiled, deployable unit for Lambda instead.

  In short: clone the code → go to the Lambda project → install the build tool (once) → produce CsvParserLambda.zip, the deployable
  package you upload to AWS Lambda next.

See [`lambda/CsvParserLambda/README.md`](lambda/CsvParserLambda/README.md).

### 2. Create the Lambda function

You can create the function either from the **AWS Management Console** or with the
**AWS CLI**. Both produce the same `clr-csv-parser` function from the
`CsvParserLambda.zip` built in Step 1.

#### Option A — Console

1. Lambda console → **Create function** → **Author from scratch**.
2. Name `clr-csv-parser`, choose a .NET runtime, architecture `x86_64`, **Create function**.
3. **Code** tab → **Upload from** → **.zip file** → upload `CsvParserLambda.zip` → **Save**.
4. **Runtime settings** → **Edit** → Handler:
   `CsvParserLambda::CsvParserLambda.Function::FunctionHandler`.
5. **Configuration → General configuration** → Timeout 60s, Memory 512 MB.
6. Verify on the **Test** tab using [`lambda/CsvParserLambda/test-event.json`](lambda/CsvParserLambda/test-event.json).

#### Option B — AWS CLI

The console creates an execution role for you automatically; with the CLI you
create it explicitly first, then create the function.

```bash
# 2.1 Create the Lambda execution role
aws iam create-role \
  --role-name clr-csv-parser-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }]
  }'

# 2.2 Attach the basic execution policy (CloudWatch Logs)
aws iam attach-role-policy \
  --role-name clr-csv-parser-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# 2.3 Create the function from the ZIP built in Step 1
aws lambda create-function \
  --function-name clr-csv-parser \
  --runtime dotnet10 \
  --architectures x86_64 \
  --handler "CsvParserLambda::CsvParserLambda.Function::FunctionHandler" \
  --timeout 60 \
  --memory-size 512 \
  --zip-file fileb://CsvParserLambda.zip \
  --role arn:aws:iam::<ACCOUNT_ID>:role/clr-csv-parser-role
```

Replace `<ACCOUNT_ID>` with the AWS account ID of your environment. To update the
code later, use `aws lambda update-function-code --function-name clr-csv-parser
--zip-file fileb://CsvParserLambda.zip`.

#### Handler format (both options)

The handler tells the .NET Lambda runtime which method to invoke for each request. When you configure a function in .NET Core, the value of the handler takes the form of `assembly::namespace.class-name::method-name`:

- `CsvParserLambda` — the compiled assembly name (from the `.csproj`)
- `CsvParserLambda.Function` — the namespace and class that contains the handler
- `FunctionHandler` — the method the runtime calls, which receives the request and returns the response

#### Verify the function in isolation

Open the **Test** tab in the Lambda console for `clr-csv-parser` and create an
event that mimics an API Gateway proxy request (see also
[`lambda/CsvParserLambda/test-event.json`](lambda/CsvParserLambda/test-event.json)):

```json
{"body":"{\"skipHeader\":true,\"csvData\":\"CustomerName,Address,City\\n\\\"AnyCompany, Inc.\\\",\\\"123 Any St, Suite 1\\nBuilding A\\\",\\\"Anytown\\\"\",\"delimiter\":\",\"}"}
```

A successful response has `"statusCode": 200` and a body containing
`"success":true` with the parsed rows: `AnyCompany, Inc.` stays a single field
(comma preserved), and `123 Any St, Suite 1`⏎`Building A` keeps its internal
newline — the whole reason this Lambda exists, since `BULK INSERT` cannot do it.

### 3. Create the REST API

Amazon API Gateway gives the Lambda function a secure, public HTTPS endpoint that
SQL Server can call. This is necessary because `sp_invoke_external_rest_endpoint`
requires an HTTPS URL with a publicly trusted TLS certificate — it cannot invoke a
Lambda function directly. We create a REST API with a single POST `/parse` method
integrated with the parser function. It uses Lambda proxy integration, so the raw
request body is passed straight through to the handler.

#### Option A — Console

1. API Gateway → **Create API** → **REST API** → **Build**. Name `clr-csv-parser-api`, **Regional**.
2. **Create resource** `parse` → select `/parse` → **Create method** → **POST**.
3. Integration type **Lambda function**; **turn ON "Lambda proxy integration"**
   (required — the handler reads `request.Body`, populated only in proxy mode).
   Select `clr-csv-parser` → **Create method**.
4. Select **POST** → **Method request** → **Edit** → **API key required** = true → **Save**.
5. **Deploy API** → new stage `prod` → **Deploy**. Copy the **Invoke URL**
   (your endpoint is that URL + `/parse`). Redeploy after any integration change.

#### Option B — AWS CLI

The commands chain with shell variables (`$API_ID`, `$ROOT_ID`, `$PARSE_ID`) so
you can paste the block and run it end to end.

```bash
# 3.1 Create the REST API (Regional)
API_ID=$(aws apigateway create-rest-api \
  --name clr-csv-parser-api \
  --endpoint-configuration types=REGIONAL \
  --query 'id' --output text)

# 3.2 Get the root resource id ("/")
ROOT_ID=$(aws apigateway get-resources \
  --rest-api-id "$API_ID" \
  --query 'items[?path==`/`].id' --output text)

# 3.3 Create the /parse resource
PARSE_ID=$(aws apigateway create-resource \
  --rest-api-id "$API_ID" \
  --parent-id "$ROOT_ID" \
  --path-part parse \
  --query 'id' --output text)

# 3.4 Create the POST method with API key required
aws apigateway put-method \
  --rest-api-id "$API_ID" \
  --resource-id "$PARSE_ID" \
  --http-method POST \
  --authorization-type NONE \
  --api-key-required

# 3.5 Wire POST to Lambda using proxy integration (AWS_PROXY)
REGION=$(aws configure get region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws apigateway put-integration \
  --rest-api-id "$API_ID" \
  --resource-id "$PARSE_ID" \
  --http-method POST \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:clr-csv-parser/invocations"

# 3.6 Grant API Gateway permission to invoke the Lambda
aws lambda add-permission \
  --function-name clr-csv-parser \
  --statement-id apigw-invoke \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/POST/parse"

# 3.7 Deploy to the "prod" stage
aws apigateway create-deployment \
  --rest-api-id "$API_ID" \
  --stage-name prod

# 3.8 Your endpoint is:
echo "https://${API_ID}.execute-api.${REGION}.amazonaws.com/prod/parse"
```

Turning on `AWS_PROXY` is the CLI equivalent of the console's "Lambda proxy
integration." Redeploy (`create-deployment`) after any integration change.

### 4. Create an API key and usage plan

The API key authenticates calls from SQL Server, so the endpoint isn't open to
anonymous callers. The usage plan enforces throttling and quota limits to protect
the Lambda function from runaway or excessive requests. When burst or rate limits
are exceeded, API Gateway returns HTTP 429 "Too Many Requests" (or "Limit
Exceeded" for quota) before the request reaches Lambda. T-SQL surfaces the same
429 error code. Together, they give you a managed access-control and
rate-limiting layer in front of the parser. For more information, refer to
[Usage plans and API keys for REST APIs in API Gateway](https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-api-usage-plans.html).

#### Option A — Console

1. **API keys** → **Create API key** `clr-csv-parser-key` → **Show** and copy the value.
2. **Usage plans** → **Create usage plan** `clr-csv-parser-plan`. Set throttling
   (for example, Rate 100 req/sec, Burst 50) and, optionally, a quota.
3. Associate stage `clr-csv-parser-api:prod` and the API key `clr-csv-parser-key`.

#### Option B — AWS CLI

```bash
# 4.1 Create the API key
KEY_ID=$(aws apigateway create-api-key \
  --name clr-csv-parser-key \
  --enabled \
  --query 'id' --output text)

# 4.2 Retrieve the API key VALUE (stored in SQL Server in Step 5)
aws apigateway get-api-key \
  --api-key "$KEY_ID" \
  --include-value \
  --query 'value' --output text

# 4.3 Create a usage plan with throttling + quota, associated to the prod stage
PLAN_ID=$(aws apigateway create-usage-plan \
  --name clr-csv-parser-plan \
  --throttle burstLimit=50,rateLimit=100 \
  --quota limit=100000,period=MONTH \
  --api-stages "apiId=${API_ID},stage=prod" \
  --query 'id' --output text)

# 4.4 Associate the API key with the usage plan
aws apigateway create-usage-plan-key \
  --usage-plan-id "$PLAN_ID" \
  --key-id "$KEY_ID" \
  --key-type API_KEY
```

**Throttling settings.** `rateLimit` is the sustained requests-per-second the API
allows; `burstLimit` is the size of the short spike it will absorb above that rate
(token-bucket model). `quota` caps total calls per period. When burst/rate is
exceeded, API Gateway returns HTTP 429 "Too Many Requests" (or "Limit Exceeded"
for quota) before the request reaches Lambda. From SQL Server,
`sp_invoke_external_rest_endpoint` receives that 429, so `dbo.ParseCSV_Lambda`
raises an error (for example, `CSV Parser Lambda error (HTTP 429)`) instead of
returning a result set. Because each SQL call is one HTTPS round-trip, keep
invocations at the file/batch level to stay under these limits.

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
