# Networking for private-subnet RDS with `sp_invoke_external_rest_endpoint`

When your Amazon RDS for SQL Server 2025 instance is in a **private subnet**
(no public IP, `PubliclyAccessible = false`), `sp_invoke_external_rest_endpoint`
requires outbound internet access to reach the regional API Gateway endpoint.
This page covers the required networking setup and documents a known limitation
with private API Gateway endpoints.

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

## Why a private API Gateway endpoint does NOT work

You might expect to use a **private** API Gateway endpoint (endpoint type
`PRIVATE`) with an interface VPC endpoint (`com.amazonaws.<region>.execute-api`)
to keep all traffic inside the VPC. This **does not work** with
`sp_invoke_external_rest_endpoint` on Amazon RDS.

### What was tested

| Test | Result |
| --- | --- |
| Private API + VPCe private DNS enabled, standard hostname from RDS | `0x80072ee7` NAME_NOT_RESOLVED |
| Private API + VPCe hostname with `Host` / `x-apigw-api-id` header from RDS | HTTP 403 ForbiddenException (`aws:sourceVpce` not populated) |
| Same private API + VPCe, called from Linux EC2 in the same subnet | HTTP 200 (success) |
| Regional API via NAT from RDS | HTTP 200 (success) |
| Public endpoint (`api.ipify.org`) via NAT from RDS | HTTP 200 (success) |

### Root cause

The managed RDS engine's `sp_invoke_external_rest_endpoint` implementation:

1. **Does not resolve the API hostname to the VPC endpoint's private ENI IPs**,
   even when VPCe private DNS is enabled and functioning for other workloads
   (EC2) in the same subnet.
2. **Does not populate `aws:sourceVpce`** in the request context when it does
   reach API Gateway (e.g., via the VPCe-specific hostname), so a private API's
   resource policy condition `StringNotEquals: aws:sourceVpce` always denies.

An EC2 instance in the same VPC and subnet, using the same security group,
successfully resolves to the VPCe and receives HTTP 200 — proving the VPCe
setup is correct and the limitation is specific to the managed RDS engine.

### Recommendation

Use a **regional** (public) API Gateway endpoint and restrict access with:

- A **resource policy** that allows only the NAT gateway's Elastic IP
  (`aws:SourceIp`). See [`docs/api-resource-policy.md`](api-resource-policy.md).
- The **API key** (already required by the method and stored in the
  `DATABASE SCOPED CREDENTIAL`).

This gives you IP-level network restriction plus application-level
authentication, while avoiding the VPCe path that RDS cannot use.

## DNS caching note

If the API hostname was previously associated with a private hosted zone (via
VPCe private DNS), the RDS engine may cache stale/negative DNS answers for up to
~15 minutes after the override is removed. During this window,
`sp_invoke_external_rest_endpoint` returns `0x80072ee7`. The fix is time — let
the TTL expire. Rebooting the RDS instance can also clear the engine's DNS cache,
but only after the VPC resolver itself has propagated the correct (public)
answer.
