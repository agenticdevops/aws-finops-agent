---
name: aws-cost-analysis
description: "Analyze AWS costs, rightsizing recommendations, Reserved Instance utilization, Savings Plans coverage, S3 storage optimization, and Trusted Advisor findings. Uses MCP aws-finops server + AWS CLI. Read-only operations only."
version: 1.0.0
author: gshah
license: MIT
metadata:
  hermes:
    tags: [AWS, FinOps, cost-analysis, rightsizing, reserved-instances, savings-plans, S3, trusted-advisor]
    category: devops
    requires_toolsets: [terminal]
---

# AWS Cost Analysis

## When to Use

Invoke this skill when the user asks about any of the following:

- AWS spending or cost breakdown
- Cost trends or forecasts
- Rightsizing EC2 instances
- Reserved Instance (RI) utilization or coverage
- Savings Plans (SP) utilization or coverage
- S3 storage optimization or lifecycle policies
- Trusted Advisor cost-related findings
- Weekly or monthly cost reports

## Prerequisites

- **AWS CLI** installed and configured (`aws configure` or environment variables)
- **IAM permissions**: `ce:*`, `s3:ListAllMyBuckets`, `s3:GetBucketLifecycleConfiguration`, `support:DescribeTrustedAdvisorChecks`, `support:DescribeTrustedAdvisorCheckResult`
- **Cost Explorer** enabled in the AWS account (Settings > Cost Explorer)
- **MCP aws-finops server** (optional but preferred for richer analysis)

## SAFETY RULES

**NEVER run destructive commands.** This skill is read-only. Only the following AWS CLI operation prefixes are permitted:

- `get-cost-*`
- `get-rightsizing-*`
- `get-reservation-*`
- `get-savings-plans-*`
- `list-*`
- `describe-*`

Do NOT run: `delete-*`, `put-*`, `create-*`, `update-*`, `modify-*`, or any mutating operation.

## Quick Reference

| Analysis Type            | AWS CLI Command / Service                          |
|--------------------------|----------------------------------------------------|
| Cost overview by service | `aws ce get-cost-and-usage` grouped by SERVICE     |
| Cost overview by region  | `aws ce get-cost-and-usage` grouped by REGION      |
| Cost forecast            | `aws ce get-cost-forecast`                         |
| EC2 rightsizing          | `aws ce get-rightsizing-recommendation`            |
| RI utilization           | `aws ce get-reservation-utilization`               |
| Savings Plans            | `aws ce get-savings-plans-utilization-details`     |
| S3 storage optimization  | `aws s3api list-buckets` + lifecycle configuration |
| Trusted Advisor          | `aws support describe-trusted-advisor-checks`      |

## Procedure

### Step 1 — Cost Overview

**Preferred**: Use MCP aws-finops server if available.

**CLI fallback — cost by SERVICE (last 30 days):**

```bash
START_DATE=$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d '30 days ago' +%Y-%m-%d)
END_DATE=$(date +%Y-%m-%d)

aws ce get-cost-and-usage \
  --time-period Start=${START_DATE},End=${END_DATE} \
  --granularity MONTHLY \
  --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE \
  --output json
```

**CLI fallback — cost by REGION (last 30 days):**

```bash
aws ce get-cost-and-usage \
  --time-period Start=${START_DATE},End=${END_DATE} \
  --granularity MONTHLY \
  --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=REGION \
  --output json
```

**Cost forecast (next 30 days):**

```bash
FORECAST_START=$(date +%Y-%m-%d)
FORECAST_END=$(date -v+30d +%Y-%m-%d 2>/dev/null || date -d '30 days' +%Y-%m-%d)

aws ce get-cost-forecast \
  --time-period Start=${FORECAST_START},End=${FORECAST_END} \
  --metric UNBLENDED_COST \
  --granularity MONTHLY \
  --output json
```

### Step 2 — Rightsizing Recommendations

```bash
aws ce get-rightsizing-recommendation \
  --service EC2 \
  --profile <profile-name> --output json
```

Parse and surface:
- Instance ID, current type, recommended type
- Estimated monthly savings
- Modification type (TERMINATE or MODIFY)

### Step 3 — Reserved Instance Utilization

```bash
START_DATE=$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d '30 days ago' +%Y-%m-%d)
END_DATE=$(date +%Y-%m-%d)

aws ce get-reservation-utilization \
  --time-period Start=${START_DATE},End=${END_DATE} \
  --profile <profile-name> --output json
```

Key metrics to extract:
- `UtilizationPercentage` (target: >= 80%)
- `NetRISavings`
- `TotalAmortizedFee`

### Step 4 — Savings Plans Utilization

```bash
START_DATE=$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d '30 days ago' +%Y-%m-%d)
END_DATE=$(date +%Y-%m-%d)

aws ce get-savings-plans-utilization-details \
  --time-period Start=${START_DATE},End=${END_DATE} \
  --profile <profile-name> --output json
```

Key metrics to extract:
- `UtilizationPercentage` (target: >= 80%)
- `NetSavings`
- `OnDemandCostEquivalent`

### Step 5 — S3 Storage Optimization

**List all buckets:**

```bash
aws s3api list-buckets --output json | jq '.Buckets[].Name'
```

**Check lifecycle configuration per bucket:**

```bash
BUCKET_NAME="your-bucket-name"

aws s3api get-bucket-lifecycle-configuration \
  --bucket ${BUCKET_NAME} \
  --output json 2>&1 || echo "No lifecycle policy configured for ${BUCKET_NAME}"
```

**Iterate over all buckets:**

```bash
aws s3api list-buckets --output json \
  | jq -r '.Buckets[].Name' \
  | while read bucket; do
      echo "=== ${bucket} ==="
      aws s3api get-bucket-lifecycle-configuration \
        --bucket "${bucket}" \
        --output json 2>&1 \
        || echo "No lifecycle policy"
    done
```

Flag buckets with no lifecycle policy as optimization candidates.

### Step 6 — Trusted Advisor Findings

> Trusted Advisor requires **us-east-1** region and a **Business or Enterprise** support plan.

```bash
aws support describe-trusted-advisor-checks \
  --language en \
  --region us-east-1 \
  --output json 2>/dev/null \
  || echo "SubscriptionRequiredException: Business/Enterprise support plan required"
```

**Retrieve result for a specific check:**

```bash
CHECK_ID="Qch7DwouX1"  # Example: Low Utilization Amazon EC2 Instances

aws support describe-trusted-advisor-check-result \
  --check-id ${CHECK_ID} \
  --language en \
  --region us-east-1 \
  --output json 2>/dev/null \
  || echo "SubscriptionRequiredException: skipping Trusted Advisor"
```

Catch `SubscriptionRequiredException` gracefully — do not fail the overall analysis if this step is unavailable.

### Step 7 — Output Format

Return findings as a structured JSON object:

```json
{
  "cost_overview": {
    "period": "YYYY-MM-DD to YYYY-MM-DD",
    "total_unblended_cost": "0.00",
    "currency": "USD",
    "top_services": [],
    "top_regions": [],
    "forecast_next_30_days": "0.00"
  },
  "rightsizing": {
    "recommendations_count": 0,
    "estimated_monthly_savings": "0.00",
    "recommendations": []
  },
  "reserved_instances": {
    "utilization_percentage": "0.0",
    "net_ri_savings": "0.00",
    "total_amortized_fee": "0.00"
  },
  "savings_plans": {
    "utilization_percentage": "0.0",
    "net_savings": "0.00",
    "on_demand_cost_equivalent": "0.00"
  },
  "s3_optimization": {
    "total_buckets": 0,
    "buckets_without_lifecycle": [],
    "buckets_with_lifecycle": []
  },
  "trusted_advisor": {
    "available": true,
    "cost_checks": []
  },
  "errors": []
}
```

Populate `errors[]` with any non-fatal failures (e.g., Trusted Advisor not available, individual bucket access denied) instead of aborting the full analysis.

## Pitfalls

- **Cost Explorer API cost**: Each `get-cost-*` API call costs $0.01. Minimize calls; do not loop unnecessarily.
- **Rightsizing data lag**: Rightsizing recommendations require at least 14 days of usage data. If the account is new, this step returns empty results — that is expected.
- **Savings Plans empty response**: `get-savings-plans-utilization-details` may return empty if no Savings Plans are active. Handle gracefully.
- **S3 bucket listing is global**: `list-buckets` returns all buckets across all regions regardless of the configured default region.
- **Trusted Advisor region constraint**: The Support API only works in `us-east-1`. Always specify `--region us-east-1` for Support API calls.
- **Cost Explorer date ranges are exclusive on the end date**: A range of `Start=2026-03-01,End=2026-04-01` covers March only. To include April data through today, set `End` to tomorrow's date.
- **Cost Explorer may be disabled**: Some accounts have Cost Explorer disabled. Catch `AccessDeniedException` and inform the user to enable it in the Billing console.
