# Networking for private-subnet RDS with `sp_invoke_external_rest_endpoint`

When your Amazon RDS for SQL Server 2025 instance is in a **private subnet**
(no public IP, `PubliclyAccessible = false`), `sp_invoke_external_rest_endpoint`
requires outbound internet access to reach the regional API Gateway endpoint.
This page covers the required networking setup, and explains how to use a
**private** API Gateway endpoint from RDS (via the VPC endpoint hostname).

## What you need (NAT gateway)

`sp_invoke_external_rest_endpoint` resolves the API hostname via **public DNS**
and makes an outbound HTTPS call over the internet. A private-subnet RDS instance
has no internet path by default, so you must provide one:

1. **Create a public subnet** in the same VPC with a route to an internet gateway.
2. **Create a NAT gateway** in that public subnet (requires an Elastic IP).
3. **Add a default route** (`0.0.0.0/0 → NAT gateway`) to the route table used
   by the RDS subnets.

After this, outbound traffic from the RDS subnets exits via the NAT gateway's
Elastic IP. RDS stays private (no inbound path from the internet).

### Verify the egress IP

From SQL Server, confirm the NAT path works and note the egress IP:

```sql
DECLARE @ret INT, @response NVARCHAR(MAX);
EXEC @ret = sp_invoke_external_rest_endpoint
    @url = N'https://api.ipify.org?format=json',
    @method = 'GET',
    @timeout = 30,
    @response = @response OUTPUT;
SELECT @ret AS ReturnCode, @response AS Response;
-- The "ip" field in the result is the public IP API Gateway sees.
```

The returned IP is what you allowlist in the API Gateway resource policy (see
[`docs/api-resource-policy.md`](api-resource-policy.md)).

### Without the NAT gateway

If there is no outbound route, `sp_invoke_external_rest_endpoint` fails with:

```
Msg 31608, Level 16, State 24 ...
An error occurred, failed to communicate with the external rest endpoint.
HRESULT: 0x80072ee7.
```

`0x80072ee7` is WinHTTP `ERROR_WINHTTP_NAME_NOT_RESOLVED` — DNS resolution
failed because the engine had no path to a public resolver or endpoint.

## Using a private API Gateway endpoint (VPCe hostname method)

You **can** use a **private** API Gateway endpoint (endpoint type `PRIVATE`) with
an interface VPC endpoint (`com.amazonaws.<region>.execute-api`) to keep all
traffic inside the VPC — **but you must call the VPC endpoint's own hostname**,
not the standard API hostname.

### Why the standard hostname fails

| From RDS `sp_invoke_external_rest_endpoint` | Result |
| --- | --- |
| **Standard hostname** `https://<api-id>.execute-api.<region>.amazonaws.com/...` | ❌ `403 Forbidden` — or `0x80072ee7` if DNS is stale |
| **VPCe hostname** `https://<vpce-id>-<hash>.execute-api.<region>.vpce.amazonaws.com/...` | ✅ `200 OK` |
| Same private API + VPCe, called from Linux EC2 in the same subnet | ✅ `200 OK` |
| Regional API via NAT from RDS | ✅ `200 OK` |
| Public endpoint (`api.ipify.org`) via NAT from RDS | ✅ `200 OK` |

The managed RDS engine's `sp_invoke_external_rest_endpoint` implementation:

1. Does not honor the VPCe **private-DNS override** for the standard
   `execute-api` hostname — when DNS hasn't propagated to the engine, the call
   fails with `0x80072ee7` (`NAME_NOT_RESOLVED`). When it does resolve (via the
   VPCe private-DNS records), the request still does not populate
   `aws:sourceVpce` in the API Gateway authorization context, so a resource
   policy with `StringEquals: aws:sourceVpce` denies with **403**.
2. **Does** resolve and populate `aws:sourceVpce` correctly when you use the
   **VPC endpoint's own hostname** (`vpce-<id>-<hash>.execute-api...vpce.amazonaws.com`).
   This hostname resolves to the interface endpoint's private ENIs via ordinary
   public DNS (no private-DNS override needed).

An EC2 instance in the same VPC and subnet, using the same security group,
successfully resolves the *standard* hostname to the VPCe and receives HTTP 200 —
proving the VPCe setup is correct and the DNS/sourceVpce limitation is specific
to the managed RDS engine.

### What you need

1. A **private** REST API (`EndpointConfiguration.Types = [PRIVATE]`).
2. An **`execute-api` interface VPC endpoint** in the RDS VPC, with:
   - Private DNS enabled
   - A security group allowing TCP 443 from the RDS security group (or VPC CIDR)
3. The VPC endpoint **attached to the API**
   (`endpointConfiguration.vpcEndpointIds`). Referencing it only in the resource
   policy is not enough — it must also be attached.
4. A **resource policy** that allows on `aws:SourceVpce`:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": "*",
       "Action": "execute-api:Invoke",
       "Resource": "execute-api:/*",
       "Condition": { "StringEquals": { "aws:SourceVpce": "<vpce-id>" } }
     }]
   }
   ```
5. The API **redeployed** to its stage after any endpoint/policy change.

### Get the VPC endpoint hostname

```bash
aws ec2 describe-vpc-endpoints --vpc-endpoint-ids <vpce-id> --region <region> \
  --query "VpcEndpoints[0].DnsEntries[].DnsName"
```

Use the **regional** entry (no AZ suffix), e.g.
`vpce-0abc123-8wo3uku7.execute-api.us-east-1.vpce.amazonaws.com`.

### Set up the SQL Server credential

The VPCe hostname does not carry the API ID, so API Gateway needs it in the
`x-apigw-api-id` header. If the method requires an API key, add `x-api-key` too.
Both are delivered through a `DATABASE SCOPED CREDENTIAL` whose **name must
exactly match** the VPCe host URL (scheme + host, no path).

```sql
-- Use a database where your login is a real user (not master/guest).
USE <your_database>;
GO
-- A Database Master Key is required before a scoped credential with a secret.
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<strong passphrase>';
GO
CREATE DATABASE SCOPED CREDENTIAL
    [https://<vpce-host>.execute-api.<region>.vpce.amazonaws.com]
  WITH IDENTITY = 'HTTPEndpointHeaders',
       SECRET   = '{"x-apigw-api-id":"<api-id>","x-api-key":"<api-key-if-required>"}';
GO
```

### Make the call

```sql
DECLARE @resp NVARCHAR(MAX), @ret INT;
EXEC @ret = sys.sp_invoke_external_rest_endpoint
    @url        = N'https://<vpce-host>.execute-api.<region>.vpce.amazonaws.com/<stage>/<resource>',
    @method     = N'POST',
    @credential = [https://<vpce-host>.execute-api.<region>.vpce.amazonaws.com],
    @headers    = N'{"Content-Type":"application/json"}',
    @payload    = N'{ ... }',
    @timeout    = 30,
    @response   = @resp OUTPUT;
SELECT @ret AS ReturnCode, @resp AS Response;
GO
```

Expected: `ReturnCode = 0` and HTTP `200` in the response body.

### Recommendation

**For private-subnet RDS, two options now work:**

- **Option A (PrivateLink, recommended):** Use a **private** API Gateway endpoint
  with the VPCe hostname method described above. All traffic stays inside the
  VPC; no NAT gateway or internet egress is needed for the API call.
- **Option B (regional + NAT):** Use a **regional** (public) API Gateway endpoint
  and restrict access with a resource policy that allows only the NAT gateway's
  Elastic IP (`aws:SourceIp`). See
  [`docs/api-resource-policy.md`](api-resource-policy.md). This requires a NAT
  gateway and internet gateway in the VPC.

Both options provide network restriction plus application-level authentication
(API key).

## DNS caching note

If the API hostname was previously associated with a private hosted zone (via
VPCe private DNS), the RDS engine may cache stale/negative DNS answers for up to
~15 minutes after the override is removed. During this window,
`sp_invoke_external_rest_endpoint` returns `0x80072ee7`. The fix is time — let
the TTL expire. Rebooting the RDS instance can also clear the engine's DNS cache,
but only after the VPC resolver itself has propagated the correct (public)
answer.
