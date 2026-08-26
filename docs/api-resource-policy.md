# Add a resource policy to restrict the regional API to the NAT egress IP

When the RDS instance is in a private subnet and egresses through a NAT gateway,
add a resource policy to the API so that only your NAT Elastic IP can invoke it.
This is defence-in-depth on top of the API key.

## When to apply

- After Step 3.6 (grant Lambda permission) and before or during Step 3.7
  (deploy). Resource policy changes only take effect after a `create-deployment`.
- Or at any time — apply the policy and then redeploy the stage.

## Steps (AWS CLI)

The commands below use the same shell variables as the main walkthrough
(`$API_ID`, `$REGION`, `$ACCOUNT_ID`). Run them in the same terminal session,
or re-export those variables first.

### 1. Capture the NAT gateway's Elastic IP

```bash
NAT_IP=$(aws ec2 describe-nat-gateways \
  --nat-gateway-ids <YOUR_NAT_GATEWAY_ID> \
  --query 'NatGateways[0].NatGatewayAddresses[0].PublicIp' \
  --output text)

echo "NAT egress IP: $NAT_IP"
```

Replace `<YOUR_NAT_GATEWAY_ID>` with the NAT gateway ID in the RDS VPC (e.g.,
`nat-0cf203810f0605bdf`).

### 2. Build and attach the resource policy

```bash
POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Deny",
      "Principal": "*",
      "Action": "execute-api:Invoke",
      "Resource": "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*",
      "Condition": {
        "NotIpAddress": { "aws:SourceIp": "${NAT_IP}/32" }
      }
    },
    {
      "Effect": "Allow",
      "Principal": "*",
      "Action": "execute-api:Invoke",
      "Resource": "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*"
    }
  ]
}
EOF
)

# Escape inner double quotes for the patch value
ESCAPED_POLICY=$(printf '%s' "$POLICY" | sed 's/"/\\"/g')

aws apigateway update-rest-api \
  --rest-api-id "$API_ID" \
  --patch-operations "op=replace,path=/policy,value=\"$ESCAPED_POLICY\""
```

### 3. Redeploy the stage

```bash
aws apigateway create-deployment \
  --rest-api-id "$API_ID" \
  --stage-name prod
```

Resource policy changes are **not active** until you redeploy.

## How the policy works

The two statements evaluate with "explicit Deny wins":

| Statement | Effect | Condition |
| --- | --- | --- |
| 1 | Deny | Source IP is **not** the NAT EIP |
| 2 | Allow | Everyone |

Net result: only requests arriving from the NAT gateway's Elastic IP pass. All
other source IPs are denied with HTTP 403 before the request reaches the Lambda.
Combined with `--api-key-required` on the method, the endpoint is restricted to
your VPC's egress IP **and** a valid API key.

## Works for public RDS too

The policy restricts by source IP, not by whether the RDS instance is private.
If you have a publicly accessible RDS instance, the same pattern applies — just
use the public IP that RDS egresses from (check with `api.ipify.org` as shown in
[`docs/private-rds-networking.md`](private-rds-networking.md)).

## Operational notes

- **NAT EIP dependency.** The policy pins a specific IP. If the NAT gateway or
  its Elastic IP is deleted and recreated, the egress IP changes. Update the
  policy's `aws:SourceIp` value and redeploy, or RDS receives HTTP 403.
- **Multiple NAT gateways.** If you deploy one NAT per AZ for high availability,
  add both EIPs to the condition using an array:
  ```json
  "aws:SourceIp": ["<NAT_IP_AZ1>/32", "<NAT_IP_AZ2>/32"]
  ```
- **Viewing the policy.** Check the currently deployed policy at any time:
  ```bash
  aws apigateway get-rest-api --rest-api-id "$API_ID" --query 'policy'
  ```
  The returned value is double-escaped JSON. Pipe through
  `sed 's/\\"/"/g; s/\\\\//g'` for readability.
