# AWS FinOps Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a weekly AWS FinOps agent with two parallel runtimes (Hermes + Claude Routines) that scans multi-account AWS environments, generates HTML dashboard reports, uploads to S3, and notifies via Slack.

**Architecture:** Shared artifacts (prompt, HTML template, IAM policy, skills) consumed by two runtime configurations: Hermes Agent (local Mac, cron, guardrails) and Claude Routine (Anthropic cloud, weekly schedule). Hybrid tooling — MCP server for structured cost/audit data, AWS CLI for full FinOps coverage.

**Tech Stack:** Hermes Agent framework, Claude Routines API, AWS CLI, aws-finops-mcp-server (Python/MCP), Jinja2-style HTML templating, Slack webhooks, S3

**Spec:** `docs/superpowers/specs/2026-04-20-aws-finops-agent-design.md`

---

## File Map

| File | Responsibility |
|------|---------------|
| `shared/prompt.md` | Master agent prompt — role, persona, execution order, guardrails |
| `shared/iam-policy.json` | Least-privilege IAM policy for all AWS API calls + S3 report upload |
| `shared/report-template.html` | Single-file HTML dashboard with 8 sections, inline CSS, dark/light toggle |
| `shared/slack-notify.sh` | S3 upload + Slack webhook notification script |
| `hermes/config.yaml` | Hermes config — model, MCP, terminal, approval, cron |
| `hermes/SOUL.md` | Hermes agent persona (wraps shared/prompt.md) |
| `hermes/skills/aws-finops-audit/SKILL.md` | Waste detection skill — MCP audit + CLI for RDS, ELB, NAT, SGs |
| `hermes/skills/aws-cost-analysis/SKILL.md` | Cost analysis skill — MCP cost + CLI for rightsizing, RI/SP, S3, Trusted Advisor |
| `hermes/skills/aws-report-gen/SKILL.md` | Report generation skill — render HTML, upload S3, notify Slack |
| `routines/routine-config.json` | Claude Routine definition — schedule, env, setup script |
| `routines/setup.sh` | Script to create/update routine via Claude CLI |

---

### Task 1: IAM Policy

**Files:**
- Create: `shared/iam-policy.json`

- [ ] **Step 1: Create IAM policy file**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "FinOpsReadOnly",
      "Effect": "Allow",
      "Action": [
        "ce:GetCostAndUsage",
        "ce:GetRightsizingRecommendation",
        "ce:GetReservationUtilization",
        "ce:GetSavingsPlansUtilizationDetails",
        "ce:GetCostForecast",
        "ec2:DescribeInstances",
        "ec2:DescribeVolumes",
        "ec2:DescribeAddresses",
        "ec2:DescribeNatGateways",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeNetworkInterfaces",
        "rds:DescribeDBInstances",
        "elasticloadbalancing:DescribeLoadBalancers",
        "elasticloadbalancing:DescribeTargetHealth",
        "elasticloadbalancing:DescribeTargetGroups",
        "s3:ListAllMyBuckets",
        "s3:GetBucketLocation",
        "s3:GetLifecycleConfiguration",
        "budgets:ViewBudget",
        "budgets:DescribeBudgets",
        "support:DescribeTrustedAdvisorChecks",
        "support:DescribeTrustedAdvisorCheckResult",
        "support:RefreshTrustedAdvisorCheck",
        "sts:GetCallerIdentity",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:GetMetricData"
      ],
      "Resource": "*"
    },
    {
      "Sid": "FinOpsReportUpload",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3:::REPORT_BUCKET_NAME/finops/*"
    }
  ]
}
```

- [ ] **Step 2: Validate JSON syntax**

Run: `cat shared/iam-policy.json | jq .`
Expected: Valid JSON output, no errors

- [ ] **Step 3: Commit**

```bash
git add shared/iam-policy.json
git commit -m "feat: add least-privilege IAM policy for FinOps agent"
```

---

### Task 2: Master Agent Prompt

**Files:**
- Create: `shared/prompt.md`

- [ ] **Step 1: Create the master prompt**

```markdown
# AWS FinOps Agent — System Prompt

You are an AWS FinOps Analyst agent with **read-only** access to AWS accounts. Your job is to analyze cloud spending, identify waste, and produce a comprehensive HTML dashboard report.

## CRITICAL SAFETY RULES

1. **NEVER** run destructive AWS commands: no `delete-*`, `terminate-*`, `stop-*`, `modify-*`, `update-*`, `create-*`
2. **NEVER** run `aws iam *` or `aws organizations *` commands
3. **NEVER** run `aws sts assume-role`
4. **NEVER** run `rm -rf`, `chmod`, `sudo`, or pipe to shell (`curl | bash`)
5. **ONLY** allowed write operations:
   - `aws s3 cp <local-file> s3://$S3_REPORT_BUCKET/finops/` (report upload)
   - `aws s3 presign` (generate read URLs)
   - `curl -X POST $SLACK_WEBHOOK_URL` (Slack notification)

If you are unsure whether a command is safe, **do not run it**.

## Execution Order

### Phase 1: Discovery
1. List all available AWS profiles: `aws configure list-profiles`
2. For each profile, validate access: `aws sts get-caller-identity --profile <name>`
3. Skip any profile that fails validation. Log the error.

### Phase 2: Data Collection (per profile)

Use MCP tools first when available. Fall back to CLI if MCP fails.

#### 2a. Cost Overview (MCP preferred)
- **MCP:** Call `get_cost` with the profile, `time_range_days=7`, `group_by=SERVICE`
- **CLI fallback:**
```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date -v-7d +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --granularity DAILY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --profile <name> --output json
```

#### 2b. Waste Detection (MCP preferred)
- **MCP:** Call `run_finops_audit` with the profile and all regions
- **CLI fallback (stopped EC2):**
```bash
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Type:InstanceType,State:State.Name,LaunchTime:LaunchTime,Name:Tags[?Key==`Name`]|[0].Value}' \
  --profile <name> --output json
```

#### 2c. Additional Waste (CLI only)
- **Idle RDS instances:**
```bash
aws rds describe-db-instances \
  --query 'DBInstances[].{ID:DBInstanceIdentifier,Class:DBInstanceClass,Engine:Engine,Status:DBInstanceStatus,MultiAZ:MultiAZ}' \
  --profile <name> --output json
```
Then check CloudWatch for low connections:
```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS --metric-name DatabaseConnections \
  --dimensions Name=DBInstanceIdentifier,Value=<id> \
  --start-time $(date -v-7d -u +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 86400 --statistics Average \
  --profile <name> --output json
```
Flag instances with average connections < 1 as idle.

- **Unused ELBs:**
```bash
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[].{ARN:LoadBalancerArn,Name:LoadBalancerName,Type:Type,State:State.Code}' \
  --profile <name> --output json
```
Check target groups for healthy targets. Flag ELBs with zero healthy targets.

- **NAT Gateways:**
```bash
aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available" \
  --query 'NatGateways[].{ID:NatGatewayId,SubnetId:SubnetId,VpcId:VpcId,State:State}' \
  --profile <name> --output json
```

- **Unused Security Groups:**
```bash
aws ec2 describe-security-groups \
  --query 'SecurityGroups[?GroupName!=`default`].{ID:GroupId,Name:GroupName,VpcId:VpcId}' \
  --profile <name> --output json
```
Cross-reference with ENIs to find unattached groups:
```bash
aws ec2 describe-network-interfaces \
  --query 'NetworkInterfaces[].Groups[].GroupId' \
  --profile <name> --output json
```
Security groups not in the ENI list are unused.

#### 2d. Rightsizing Recommendations
```bash
aws ce get-rightsizing-recommendation \
  --service EC2 \
  --configuration '{"RecommendationTarget":"SAME_INSTANCE_FAMILY","BenefitsConsidered":true}' \
  --profile <name> --output json
```

#### 2e. Reserved Instance Utilization
```bash
aws ce get-reservation-utilization \
  --time-period Start=$(date -v-30d +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --profile <name> --output json
```

#### 2f. Savings Plans Utilization
```bash
aws ce get-savings-plans-utilization-details \
  --time-period Start=$(date -v-30d +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --profile <name> --output json
```

#### 2g. S3 Storage Optimization
```bash
aws s3api list-buckets --query 'Buckets[].Name' --profile <name> --output json
```
For each bucket:
```bash
aws s3api get-bucket-lifecycle-configuration --bucket <name> --profile <name> --output json 2>/dev/null || echo '{"status":"no_lifecycle"}'
```
Flag buckets without lifecycle policies.

#### 2h. Budget Status
```bash
aws budgets describe-budgets \
  --account-id <account-id> \
  --query 'Budgets[].{Name:BudgetName,Limit:BudgetLimit,Actual:CalculatedSpend.ActualSpend,Forecast:CalculatedSpend.ForecastedSpend}' \
  --profile <name> --output json
```

#### 2i. Trusted Advisor (requires Business/Enterprise support)
```bash
aws support describe-trusted-advisor-checks \
  --language en \
  --query 'checks[?category==`cost_optimizing`].{id:id,name:name}' \
  --region us-east-1 --profile <name> --output json
```
If this fails with "SubscriptionRequiredException", skip and note in report.

For each check:
```bash
aws support describe-trusted-advisor-check-result \
  --check-id <id> \
  --region us-east-1 --profile <name> --output json
```

### Phase 3: Report Generation
1. Load `shared/report-template.html`
2. Populate each section with collected data
3. Calculate executive summary: total spend, top 3 savings, health score
4. Save as `finops-report-YYYY-MM-DD.html`

### Phase 4: Delivery
1. Upload to S3:
```bash
aws s3 cp finops-report-YYYY-MM-DD.html \
  s3://$S3_REPORT_BUCKET/finops/$(date +%Y-%m-%d).html \
  --content-type "text/html"
```

2. Generate pre-signed URL:
```bash
aws s3 presign \
  s3://$S3_REPORT_BUCKET/finops/$(date +%Y-%m-%d).html \
  --expires-in 604800
```

3. Notify Slack:
```bash
curl -X POST "$SLACK_WEBHOOK_URL" \
  -H 'Content-type: application/json' \
  -d "{
    \"text\": \"📊 Weekly AWS FinOps Report Ready\",
    \"blocks\": [{
      \"type\": \"section\",
      \"text\": {
        \"type\": \"mrkdwn\",
        \"text\": \"*Weekly AWS FinOps Report* — $(date +%Y-%m-%d)\n\nTotal Spend: \$TOTAL_SPEND\nPotential Savings: \$TOTAL_SAVINGS\nHealth Score: HEALTH_SCORE\n\n<PRESIGNED_URL|View Full Report>\"
      }
    }]
  }"
```

## Error Handling

- If a profile fails auth: skip it, log error, continue with others
- If MCP server is unavailable: use CLI equivalents
- If an API returns an error: note in that report section, continue
- If Trusted Advisor is unavailable: skip section, note "requires Business/Enterprise support"
- If S3 upload fails: save report locally, log error
- If Slack notification fails: report is already in S3, log error
- **NEVER** fail completely. Partial report > no report.

## Environment Variables

- `S3_REPORT_BUCKET` — S3 bucket for report upload
- `SLACK_WEBHOOK_URL` — Slack incoming webhook URL
```

- [ ] **Step 2: Verify prompt renders correctly**

Run: `wc -l shared/prompt.md && head -5 shared/prompt.md`
Expected: ~170 lines, starts with "# AWS FinOps Agent"

- [ ] **Step 3: Commit**

```bash
git add shared/prompt.md
git commit -m "feat: add master agent prompt with 8-section FinOps analysis"
```

---

### Task 3: HTML Report Template

**Files:**
- Create: `shared/report-template.html`

- [ ] **Step 1: Create the HTML report template**

Create a single-file HTML dashboard with inline CSS. The template uses `<!-- SECTION: name -->` comment markers and `{{variable}}` placeholders that the agent will replace with actual data. Include:

1. Executive Summary section with health score indicator (red/yellow/green circle), total spend, top 3 savings opportunities
2. Cost Overview section with CSS-only horizontal bar chart for spend by service, tables for by-region and by-account
3. Waste Detection section with sortable table: resource type, resource ID, region, profile, estimated monthly cost, recommendation
4. Rightsizing section with table: instance ID, current type, recommended type, estimated monthly savings
5. RI & Savings Plans section with utilization gauge (CSS), coverage %, expiring commitments table
6. S3 & Storage section with table of buckets without lifecycle, storage class recommendations
7. Budget Status section with budget cards: name, limit bar, actual/forecast indicators
8. Recommendations section with prioritized table: action, estimated annual savings, effort badge, risk badge

Style requirements:
- Dark theme by default with light mode toggle via CSS `prefers-color-scheme` + JS toggle button
- Color palette: dark bg `#0f172a`, cards `#1e293b`, accent green `#10b981`, warning amber `#f59e0b`, danger red `#ef4444`
- Responsive grid layout using CSS Grid
- Print-friendly `@media print` styles (white bg, no toggle)
- No external dependencies — all CSS inline in `<style>`, all JS inline in `<script>`
- Header with report date, account summary, generation timestamp
- Footer with "Generated by AWS FinOps Agent" and IAM policy note
- Each section wrapped in `<section id="section-name">` with anchor navigation
- Sticky nav bar with section links

The template should include JSON shape comments so the agent knows what data structure to inject. Example:

```html
<!-- SECTION: cost-overview
     Expected data shape:
     {
       "by_service": [{"service": "EC2", "cost": 1234.56}, ...],
       "by_region": [{"region": "us-east-1", "cost": 567.89}, ...],
       "by_account": [{"account": "prod-123456", "cost": 2345.67}, ...],
       "total": 5678.90,
       "daily_average": 811.27
     }
-->
```

- [ ] **Step 2: Verify template is valid HTML**

Run: `head -20 shared/report-template.html && echo "---" && wc -l shared/report-template.html`
Expected: Starts with `<!DOCTYPE html>`, 400-600 lines

- [ ] **Step 3: Open in browser for visual check**

Run: `open shared/report-template.html`
Expected: Dashboard renders with placeholder data, dark theme, sections visible

- [ ] **Step 4: Commit**

```bash
git add shared/report-template.html
git commit -m "feat: add HTML dashboard report template with 8 FinOps sections"
```

---

### Task 4: Slack Notification Script

**Files:**
- Create: `shared/slack-notify.sh`

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Usage: ./slack-notify.sh <report-file> [profile]
# Requires: S3_REPORT_BUCKET, SLACK_WEBHOOK_URL environment variables

REPORT_FILE="${1:?Usage: $0 <report-file> [profile]}"
AWS_PROFILE_FLAG="${2:+--profile $2}"
DATE=$(date +%Y-%m-%d)
S3_KEY="finops/${DATE}.html"

if [[ -z "${S3_REPORT_BUCKET:-}" ]]; then
  echo "ERROR: S3_REPORT_BUCKET not set" >&2
  exit 1
fi

# Upload to S3
echo "Uploading report to s3://${S3_REPORT_BUCKET}/${S3_KEY}..."
aws s3 cp "${REPORT_FILE}" \
  "s3://${S3_REPORT_BUCKET}/${S3_KEY}" \
  --content-type "text/html" \
  ${AWS_PROFILE_FLAG} 2>&1

# Generate pre-signed URL (7 day expiry)
PRESIGNED_URL=$(aws s3 presign \
  "s3://${S3_REPORT_BUCKET}/${S3_KEY}" \
  --expires-in 604800 \
  ${AWS_PROFILE_FLAG} 2>&1)

echo "Report URL: ${PRESIGNED_URL}"

# Post to Slack (if webhook configured)
if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
  echo "Notifying Slack..."
  curl -sf -X POST "${SLACK_WEBHOOK_URL}" \
    -H 'Content-type: application/json' \
    -d "{
      \"text\": \"Weekly AWS FinOps Report Ready — ${DATE}\",
      \"blocks\": [{
        \"type\": \"section\",
        \"text\": {
          \"type\": \"mrkdwn\",
          \"text\": \"*Weekly AWS FinOps Report* — ${DATE}\n\n<${PRESIGNED_URL}|View Full Report>\"
        }
      }]
    }" 2>&1
  echo "Slack notification sent."
else
  echo "SLACK_WEBHOOK_URL not set — skipping notification."
fi
```

- [ ] **Step 2: Make executable and verify syntax**

Run: `chmod +x shared/slack-notify.sh && bash -n shared/slack-notify.sh && echo "syntax OK"`
Expected: "syntax OK"

- [ ] **Step 3: Commit**

```bash
git add shared/slack-notify.sh
git commit -m "feat: add S3 upload and Slack notification script"
```

---

### Task 5: Hermes Skill — aws-finops-audit

**Files:**
- Create: `hermes/skills/aws-finops-audit/SKILL.md`

- [ ] **Step 1: Create the skill file**

```markdown
---
name: aws-finops-audit
description: "Detect AWS resource waste — stopped EC2, orphaned EBS, unassociated EIPs, idle RDS, unused ELBs, NAT Gateways, unused security groups. Uses MCP aws-finops server + AWS CLI. Read-only operations only."
version: 1.0.0
author: gshah
license: MIT
metadata:
  hermes:
    tags: [AWS, FinOps, cost-optimization, waste-detection, cloud, devops]
    category: devops
    requires_toolsets: [terminal]
---

# AWS FinOps Audit — Waste Detection

Identify unused and idle AWS resources across multiple accounts and regions. All operations are **read-only** — this skill never modifies, deletes, or creates resources.

## When to Use

- User asks to find unused AWS resources
- User wants to identify cloud waste or cost savings
- Weekly FinOps audit runs
- User asks about stopped instances, orphaned volumes, idle databases

## Prerequisites

- AWS CLI installed and configured (`aws configure list-profiles`)
- At least one valid AWS profile in `~/.aws/credentials`
- IAM permissions from `shared/iam-policy.json` attached to each profile
- Optional: aws-finops-mcp-server running (provides `run_finops_audit` tool)

Check setup:
```bash
aws sts get-caller-identity --profile <name>
```

## SAFETY RULES

**NEVER run any of these commands:**
- `aws * delete-*`, `aws * terminate-*`, `aws * stop-*`
- `aws * modify-*`, `aws * update-*`, `aws * create-*`
- `aws iam *`, `aws organizations *`
- `rm -rf`, `sudo`, `chmod`

**ONLY read operations allowed:** `describe-*`, `list-*`, `get-*`

## Quick Reference

| Check | Command |
|-------|---------|
| Stopped EC2 | `aws ec2 describe-instances --filters "Name=instance-state-name,Values=stopped"` |
| Orphaned EBS | `aws ec2 describe-volumes --filters "Name=status,Values=available"` |
| Unassociated EIPs | `aws ec2 describe-addresses --filters "Name=association-id,Values="` — filter for no association |
| Idle RDS | `aws rds describe-db-instances` + CloudWatch `DatabaseConnections` |
| Unused ELBs | `aws elbv2 describe-load-balancers` + `describe-target-health` |
| NAT Gateways | `aws ec2 describe-nat-gateways --filter "Name=state,Values=available"` |
| Unused SGs | Cross-reference `describe-security-groups` with `describe-network-interfaces` |

## Procedure

### 1. Discover profiles and regions

```bash
aws configure list-profiles
```

For each profile, validate:
```bash
aws sts get-caller-identity --profile <name> --output json
```

Get accessible regions:
```bash
aws ec2 describe-regions --query 'Regions[].RegionName' --profile <name> --output json
```

### 2. Try MCP first (if available)

If the `run_finops_audit` MCP tool is available, call it:
- Provide the profile name(s)
- It returns stopped EC2, orphaned EBS, unassociated EIPs, and budget status
- Continue to CLI checks for additional waste types

### 3. CLI waste checks (per profile, per region)

**Stopped EC2 instances:**
```bash
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Type:InstanceType,Name:Tags[?Key==`Name`]|[0].Value,StoppedSince:StateTransitionReason}' \
  --profile <name> --region <region> --output json
```

**Orphaned EBS volumes (unattached):**
```bash
aws ec2 describe-volumes \
  --filters "Name=status,Values=available" \
  --query 'Volumes[].{ID:VolumeId,Size:Size,Type:VolumeType,Created:CreateTime}' \
  --profile <name> --region <region> --output json
```

**Unassociated Elastic IPs:**
```bash
aws ec2 describe-addresses \
  --query 'Addresses[?AssociationId==null].{IP:PublicIp,AllocationId:AllocationId}' \
  --profile <name> --region <region> --output json
```

**Idle RDS instances (average connections < 1 over 7 days):**
```bash
aws rds describe-db-instances \
  --query 'DBInstances[].{ID:DBInstanceIdentifier,Class:DBInstanceClass,Engine:Engine,Status:DBInstanceStatus}' \
  --profile <name> --region <region> --output json
```
Then for each instance:
```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS --metric-name DatabaseConnections \
  --dimensions Name=DBInstanceIdentifier,Value=<id> \
  --start-time $(date -v-7d -u +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 86400 --statistics Average \
  --profile <name> --region <region> --output json
```

**Unused load balancers (no healthy targets):**
```bash
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[].{ARN:LoadBalancerArn,Name:LoadBalancerName,Type:Type}' \
  --profile <name> --region <region> --output json
```
For each, check target groups:
```bash
aws elbv2 describe-target-groups \
  --load-balancer-arn <arn> \
  --query 'TargetGroups[].TargetGroupArn' \
  --profile <name> --region <region> --output json
```
Then check health:
```bash
aws elbv2 describe-target-health \
  --target-group-arn <tg-arn> \
  --profile <name> --region <region> --output json
```

**NAT Gateways:**
```bash
aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available" \
  --query 'NatGateways[].{ID:NatGatewayId,SubnetId:SubnetId,VpcId:VpcId}' \
  --profile <name> --region <region> --output json
```

**Unused security groups:**
```bash
# Get all non-default SGs
aws ec2 describe-security-groups \
  --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
  --profile <name> --region <region> --output json
```
```bash
# Get all SGs attached to ENIs
aws ec2 describe-network-interfaces \
  --query 'NetworkInterfaces[].Groups[].GroupId' \
  --profile <name> --region <region> --output json
```
SGs in first list but not in second are unused.

### 4. Output format

Produce a JSON object per profile:
```json
{
  "profile": "prod",
  "account_id": "123456789012",
  "findings": {
    "stopped_ec2": [...],
    "orphaned_ebs": [...],
    "unassociated_eips": [...],
    "idle_rds": [...],
    "unused_elbs": [...],
    "nat_gateways": [...],
    "unused_security_groups": [...]
  },
  "estimated_monthly_waste": 1234.56,
  "errors": ["RDS check failed in ap-southeast-1: AccessDenied"]
}
```

## Pitfalls

1. **Never guess instance costs** — use known pricing (e.g., stopped m5.xlarge still costs EBS). Note estimates as approximate.
2. **CloudWatch requires 7+ days of data** — if an instance was just created, skip the idle check.
3. **Trusted Advisor requires Business/Enterprise support** — catch `SubscriptionRequiredException` and skip.
4. **Some regions may be disabled** — catch AccessDenied per region and continue.
5. **EIP cost is $3.60/month when unassociated** — this is a known AWS charge.
6. **NAT Gateway is ~$32/month minimum** — flag all of them for awareness even if in use.
```

- [ ] **Step 2: Verify SKILL.md frontmatter is valid**

Run: `head -15 hermes/skills/aws-finops-audit/SKILL.md`
Expected: Valid YAML frontmatter with name, description, version, metadata

- [ ] **Step 3: Commit**

```bash
git add hermes/skills/aws-finops-audit/SKILL.md
git commit -m "feat: add Hermes skill for AWS waste detection audit"
```

---

### Task 6: Hermes Skill — aws-cost-analysis

**Files:**
- Create: `hermes/skills/aws-cost-analysis/SKILL.md`

- [ ] **Step 1: Create the skill file**

```markdown
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

Analyze AWS spending patterns, rightsizing opportunities, commitment utilization, storage optimization, and AWS-native recommendations. All operations are **read-only**.

## When to Use

- User asks about AWS spending or costs
- User wants rightsizing recommendations
- User asks about Reserved Instance or Savings Plans utilization
- User wants S3 storage optimization advice
- User asks about Trusted Advisor cost recommendations
- Weekly FinOps report generation

## Prerequisites

- AWS CLI installed and configured
- IAM permissions from `shared/iam-policy.json`
- Cost Explorer enabled in the AWS account (it is by default)
- Optional: aws-finops-mcp-server running (provides `get_cost` tool)

## SAFETY RULES

**NEVER run any of these commands:**
- `aws * delete-*`, `aws * terminate-*`, `aws * stop-*`
- `aws * modify-*`, `aws * update-*`, `aws * create-*`
- `aws iam *`, `aws organizations *`

**ONLY read operations allowed:** `get-cost-*`, `get-rightsizing-*`, `get-reservation-*`, `get-savings-plans-*`, `list-*`, `describe-*`

## Quick Reference

| Analysis | Command |
|----------|---------|
| Cost by service | `aws ce get-cost-and-usage --group-by Type=DIMENSION,Key=SERVICE` |
| Cost by region | `aws ce get-cost-and-usage --group-by Type=DIMENSION,Key=REGION` |
| Rightsizing | `aws ce get-rightsizing-recommendation --service EC2` |
| RI utilization | `aws ce get-reservation-utilization` |
| SP utilization | `aws ce get-savings-plans-utilization-details` |
| S3 lifecycle | `aws s3api get-bucket-lifecycle-configuration --bucket <name>` |
| Trusted Advisor | `aws support describe-trusted-advisor-checks --language en` |

## Procedure

### 1. Cost Overview (MCP preferred)

If `get_cost` MCP tool is available:
- Call with profile, `time_range_days=7`, `group_by=SERVICE`
- This returns cost by service and total

CLI fallback — cost by service (last 7 days):
```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date -v-7d +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --granularity DAILY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --profile <name> --output json
```

Cost by region:
```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date -v-7d +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --granularity DAILY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=REGION \
  --profile <name> --output json
```

Cost forecast:
```bash
aws ce get-cost-forecast \
  --time-period Start=$(date +%Y-%m-%d),End=$(date -v+30d +%Y-%m-%d) \
  --granularity MONTHLY \
  --metric UNBLENDED_COST \
  --profile <name> --output json
```

### 2. Rightsizing Recommendations

```bash
aws ce get-rightsizing-recommendation \
  --service EC2 \
  --configuration '{"RecommendationTarget":"SAME_INSTANCE_FAMILY","BenefitsConsidered":true}' \
  --profile <name> --output json
```

Parse recommendations:
- `RightsizingRecommendations[].CurrentInstance` — what they have now
- `RightsizingRecommendations[].ModifyRecommendationDetail` — what to change to
- `RightsizingRecommendations[].RightsizingType` — MODIFY or TERMINATE

### 3. Reserved Instance Utilization

```bash
aws ce get-reservation-utilization \
  --time-period Start=$(date -v-30d +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --profile <name> --output json
```

Key metrics:
- `Total.UtilizationPercentage` — target 80%+
- `UtilizationsByTime[].Groups[].Utilization` — per-RI breakdown

### 4. Savings Plans Utilization

```bash
aws ce get-savings-plans-utilization-details \
  --time-period Start=$(date -v-30d +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --profile <name> --output json
```

Key metrics:
- `SavingsPlansUtilizationDetails[].Utilization.UtilizationPercentage`
- `SavingsPlansUtilizationDetails[].Savings.NetSavings`

### 5. S3 Storage Optimization

List all buckets:
```bash
aws s3api list-buckets --query 'Buckets[].Name' --profile <name> --output json
```

For each bucket, check lifecycle:
```bash
aws s3api get-bucket-lifecycle-configuration \
  --bucket <bucket-name> \
  --profile <name> --output json 2>/dev/null
```
If this returns an error (NoSuchLifecycleConfiguration), flag the bucket.

Get bucket location (for regional grouping):
```bash
aws s3api get-bucket-location --bucket <bucket-name> --profile <name> --output json
```

### 6. Trusted Advisor (Business/Enterprise support required)

```bash
aws support describe-trusted-advisor-checks \
  --language en \
  --query 'checks[?category==`cost_optimizing`].{id:id,name:name}' \
  --region us-east-1 --profile <name> --output json
```

If this returns `SubscriptionRequiredException`, skip and note in output.

For each cost optimization check:
```bash
aws support describe-trusted-advisor-check-result \
  --check-id <check-id> \
  --region us-east-1 --profile <name> --output json
```

### 7. Output format

```json
{
  "profile": "prod",
  "account_id": "123456789012",
  "cost_overview": {
    "total_7d": 5678.90,
    "daily_average": 811.27,
    "by_service": [...],
    "by_region": [...],
    "forecast_30d": 24567.00
  },
  "rightsizing": {
    "recommendations": [...],
    "potential_monthly_savings": 456.78
  },
  "reserved_instances": {
    "overall_utilization_pct": 85.2,
    "details": [...]
  },
  "savings_plans": {
    "overall_utilization_pct": 92.1,
    "net_savings": 1234.56,
    "details": [...]
  },
  "s3_optimization": {
    "buckets_without_lifecycle": [...],
    "total_buckets": 42
  },
  "trusted_advisor": {
    "available": true,
    "findings": [...]
  },
  "errors": []
}
```

## Pitfalls

1. **Cost Explorer API costs $0.01 per call** — each `get-cost-and-usage` call is billed. Minimize redundant calls.
2. **Rightsizing requires 14+ days of data** — new accounts may have no recommendations.
3. **Savings Plans API may return empty** — if no SPs purchased, that's expected.
4. **S3 bucket listing is global** — only call once per profile, not per region.
5. **Trusted Advisor is us-east-1 only** — always specify `--region us-east-1`.
6. **Cost Explorer date ranges are exclusive** — End date is exclusive, so add 1 day.
7. **Some accounts have Cost Explorer disabled** — catch `DataUnavailableException`.
```

- [ ] **Step 2: Verify SKILL.md frontmatter**

Run: `head -15 hermes/skills/aws-cost-analysis/SKILL.md`
Expected: Valid YAML frontmatter

- [ ] **Step 3: Commit**

```bash
git add hermes/skills/aws-cost-analysis/SKILL.md
git commit -m "feat: add Hermes skill for AWS cost analysis and optimization"
```

---

### Task 7: Hermes Skill — aws-report-gen

**Files:**
- Create: `hermes/skills/aws-report-gen/SKILL.md`

- [ ] **Step 1: Create the skill file**

```markdown
---
name: aws-report-gen
description: "Generate HTML FinOps dashboard report from collected AWS data, upload to S3, and notify via Slack. Renders shared/report-template.html with audit and cost data."
version: 1.0.0
author: gshah
license: MIT
metadata:
  hermes:
    tags: [AWS, FinOps, reporting, HTML, S3, Slack, dashboard]
    category: devops
    requires_toolsets: [terminal]
---

# AWS FinOps Report Generator

Generate a comprehensive HTML dashboard report from AWS FinOps data, upload to S3, and post a Slack notification with the report link.

## When to Use

- After running aws-finops-audit and aws-cost-analysis skills
- User asks to generate a FinOps report or dashboard
- Weekly scheduled report generation
- User wants to share AWS cost findings with team

## Prerequisites

- `shared/report-template.html` exists in the project
- `shared/slack-notify.sh` exists and is executable
- AWS CLI configured with S3 write access to report bucket
- Environment variables: `S3_REPORT_BUCKET`, `SLACK_WEBHOOK_URL` (optional)

## SAFETY RULES

**The ONLY write operations allowed are:**
- `aws s3 cp <local-file> s3://$S3_REPORT_BUCKET/finops/` — upload report
- `aws s3 presign` — generate read URL
- `curl -X POST $SLACK_WEBHOOK_URL` — Slack notification
- Writing files to the local project directory

**NEVER** write to any other S3 path or AWS service.

## Procedure

### 1. Collect input data

You should have JSON data from the audit and cost analysis skills:
- Waste findings (from aws-finops-audit)
- Cost data (from aws-cost-analysis)

If data is missing for a section, include the section with a "No data available" message rather than omitting it.

### 2. Calculate executive summary

From the collected data, compute:
- **Total spend** (last 7 days): sum of all cost data
- **Top 3 savings opportunities**: sort all findings by estimated savings descending, take top 3
- **Health score**: 
  - GREEN if potential savings < 5% of total spend
  - YELLOW if potential savings 5-15% of total spend
  - RED if potential savings > 15% of total spend

### 3. Render the HTML report

Read `shared/report-template.html` and replace all `{{placeholder}}` variables with actual data. Key replacements:

| Placeholder | Value |
|-------------|-------|
| `{{report_date}}` | Today's date (YYYY-MM-DD) |
| `{{total_spend}}` | Total 7-day spend formatted as currency |
| `{{daily_average}}` | Daily average spend |
| `{{health_score}}` | GREEN, YELLOW, or RED |
| `{{cost_by_service}}` | JSON array of service costs |
| `{{cost_by_region}}` | JSON array of region costs |
| `{{waste_findings}}` | JSON array of waste items |
| `{{rightsizing}}` | JSON array of rightsizing recs |
| `{{ri_utilization}}` | RI utilization percentage |
| `{{sp_utilization}}` | SP utilization percentage |
| `{{s3_findings}}` | JSON array of S3 optimization items |
| `{{budget_status}}` | JSON array of budget items |
| `{{recommendations}}` | JSON array of prioritized recommendations |
| `{{accounts_scanned}}` | Number of AWS accounts scanned |
| `{{profiles_list}}` | Comma-separated profile names |
| `{{errors}}` | JSON array of any errors encountered |

### 4. Generate prioritized recommendations

Consolidate all findings into a recommendations table:

| Priority | Source | Rule |
|----------|--------|------|
| 1 (Critical) | Any | Estimated annual savings > $10,000 |
| 2 (High) | Any | Estimated annual savings > $1,000 |
| 3 (Medium) | Any | Estimated annual savings > $100 |
| 4 (Low) | Any | All other findings |

For each recommendation, include:
- **Action**: what to do (e.g., "Terminate stopped instance i-abc123")
- **Estimated annual savings**: monthly * 12
- **Effort**: Easy (one CLI command), Medium (config change), Hard (architecture change)
- **Risk**: Low (no impact), Medium (brief downtime), High (data loss possible)

### 5. Save report locally

Save to project directory:
```bash
# filename format: finops-report-YYYY-MM-DD.html
```

### 6. Upload and notify

Use the slack-notify.sh script:
```bash
S3_REPORT_BUCKET="$S3_REPORT_BUCKET" \
SLACK_WEBHOOK_URL="$SLACK_WEBHOOK_URL" \
./shared/slack-notify.sh finops-report-$(date +%Y-%m-%d).html
```

Or manually:
```bash
# Upload
aws s3 cp finops-report-$(date +%Y-%m-%d).html \
  s3://$S3_REPORT_BUCKET/finops/$(date +%Y-%m-%d).html \
  --content-type "text/html"

# Pre-sign
aws s3 presign s3://$S3_REPORT_BUCKET/finops/$(date +%Y-%m-%d).html --expires-in 604800

# Slack
curl -X POST "$SLACK_WEBHOOK_URL" \
  -H 'Content-type: application/json' \
  -d '{"text": "Weekly AWS FinOps Report — <URL|View Report>"}'
```

## Pitfalls

1. **Template must be self-contained** — all CSS/JS inline, no CDN links
2. **Large reports may exceed Slack message limits** — keep Slack message as summary + link only
3. **Pre-signed URLs expire in 7 days** — include generation date in the report itself
4. **S3 content-type must be text/html** — otherwise browser downloads instead of renders
5. **If S3 upload fails, still save locally** — never lose the report
```

- [ ] **Step 2: Verify SKILL.md**

Run: `head -15 hermes/skills/aws-report-gen/SKILL.md`
Expected: Valid frontmatter

- [ ] **Step 3: Commit**

```bash
git add hermes/skills/aws-report-gen/SKILL.md
git commit -m "feat: add Hermes skill for FinOps report generation and delivery"
```

---

### Task 8: Hermes Agent Configuration

**Files:**
- Create: `hermes/config.yaml`
- Create: `hermes/SOUL.md`

- [ ] **Step 1: Create Hermes config.yaml**

```yaml
# AWS FinOps Agent — Hermes Configuration
# Copy to ~/.hermes/config.yaml or use with: hermes --config ./hermes/config.yaml

# =============================================================================
# Model
# =============================================================================
model:
  default: "anthropic/claude-haiku-4-5"
  provider: "anthropic"

# =============================================================================
# Terminal (where agent executes aws cli commands)
# =============================================================================
terminal:
  backend: "local"
  cwd: "."
  timeout: 300
  lifetime_seconds: 600

# =============================================================================
# Approval & Guardrails
# =============================================================================
# Mode: "smart" uses auxiliary LLM to auto-approve safe commands
# Built-in DANGEROUS_PATTERNS in Hermes already block rm -rf, chmod 777, etc.
approvals:
  mode: "smart"
  timeout: 30

# =============================================================================
# MCP Servers
# =============================================================================
mcp_servers:
  aws-finops:
    command: "uv"
    args: ["run", "--directory", "./aws-finops-mcp-server", "aws-finops-mcp-server"]
    timeout: 120
    connect_timeout: 30

# =============================================================================
# Agent Behavior
# =============================================================================
agent:
  max_turns: 80
  reasoning_effort: "medium"

# =============================================================================
# Memory
# =============================================================================
memory:
  memory_enabled: true
  user_profile_enabled: false
  memory_char_limit: 2200

# =============================================================================
# Skills
# =============================================================================
skills:
  external_dirs:
    - ./hermes/skills

# =============================================================================
# Context Compression
# =============================================================================
compression:
  enabled: true
  threshold: 0.50
  target_ratio: 0.20
  protect_last_n: 20

# =============================================================================
# Display
# =============================================================================
display:
  compact: false
  tool_progress: "all"
  streaming: true
```

- [ ] **Step 2: Create Hermes SOUL.md**

```markdown
# AWS FinOps Analyst

You are an AWS FinOps Analyst agent. Your mission is to analyze cloud spending across multiple AWS accounts, identify waste and optimization opportunities, and produce a comprehensive HTML dashboard report.

## Your Personality

- **Conservative**: When in doubt, don't run the command. Safety first.
- **Data-driven**: Back every recommendation with numbers — estimated savings, utilization percentages, resource counts.
- **Thorough**: Check all 8 analysis areas. A partial report with error notes is better than skipping sections.
- **Prioritized**: Always sort recommendations by estimated dollar impact. The biggest savings come first.

## How You Work

1. Use your **aws-finops-audit** skill to detect waste (stopped EC2, orphaned EBS, idle RDS, etc.)
2. Use your **aws-cost-analysis** skill to analyze spending patterns, rightsizing, RI/SP utilization
3. Use your **aws-report-gen** skill to render the HTML dashboard and deliver via S3 + Slack

Prefer MCP tools when available (`get_cost`, `run_finops_audit`). Fall back to AWS CLI commands.

## Critical Rules

Read the full safety rules in `shared/prompt.md`. The short version:
- **NEVER** run destructive AWS commands
- **ONLY** write to the designated S3 report bucket
- **ALWAYS** continue on errors — partial data is fine
- **ALWAYS** validate each AWS profile before querying it

## Environment Variables You Need

- `S3_REPORT_BUCKET` — where to upload the HTML report
- `SLACK_WEBHOOK_URL` — where to post the notification (optional)
- `ANTHROPIC_API_KEY` — your API key (set in ~/.hermes/.env)
```

- [ ] **Step 3: Verify YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('hermes/config.yaml'))" && echo "YAML valid"`
Expected: "YAML valid"

- [ ] **Step 4: Commit**

```bash
git add hermes/config.yaml hermes/SOUL.md
git commit -m "feat: add Hermes agent config with guardrails and SOUL persona"
```

---

### Task 9: Claude Routine Configuration

**Files:**
- Create: `routines/routine-config.json`
- Create: `routines/setup.sh`

- [ ] **Step 1: Create routine config**

```json
{
  "name": "aws-finops-weekly",
  "description": "Weekly AWS FinOps analysis — scans all accounts, generates HTML dashboard, uploads to S3, notifies Slack",
  "schedule": {
    "type": "weekly",
    "day": "monday",
    "time": "09:00",
    "timezone": "UTC"
  },
  "model": "claude-haiku-4-5-20251001",
  "prompt_file": "shared/prompt.md",
  "prompt_prefix": "You are running as a Claude Routine (cloud-hosted agent). Read shared/prompt.md for your full instructions. The report template is at shared/report-template.html. The notification script is at shared/slack-notify.sh. Execute all phases: discovery, data collection, report generation, delivery. AWS credentials are in environment variables. This is a single-account run (one set of credentials).",
  "environment": {
    "network": "trusted",
    "env_vars": {
      "AWS_ACCESS_KEY_ID": "REPLACE_WITH_YOUR_KEY",
      "AWS_SECRET_ACCESS_KEY": "REPLACE_WITH_YOUR_SECRET",
      "AWS_DEFAULT_REGION": "us-east-1",
      "S3_REPORT_BUCKET": "REPLACE_WITH_BUCKET_NAME",
      "SLACK_WEBHOOK_URL": "REPLACE_WITH_WEBHOOK_URL"
    },
    "setup_script": "pip install awscli jinja2 && cd aws-finops-mcp-server && pip install uv && uv sync"
  },
  "repositories": [
    "REPLACE_WITH_YOUR_REPO_URL"
  ],
  "connectors": ["slack"],
  "notes": {
    "multi_account": "Claude Routines run in isolated environments without ~/.aws/credentials. For multi-account: (a) create one routine per account, (b) use cross-account IAM roles with STS, or (c) pass multiple credential sets as env vars (AWS_PROFILE_1_KEY, etc.).",
    "mcp_server": "The MCP server must be installed per run via setup_script. It runs as a subprocess via uv.",
    "costs": "Each run uses Haiku 4.5 tokens + AWS Cost Explorer API calls (~$0.02). Estimated total: $0.10-0.50 per weekly run."
  }
}
```

- [ ] **Step 2: Create setup script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Setup script for creating/updating the Claude Routine
# Requires: Claude Code CLI with /schedule skill, authenticated to claude.ai

CONFIG_FILE="routines/routine-config.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: $CONFIG_FILE not found. Run from project root." >&2
  exit 1
fi

echo "=== AWS FinOps Weekly Routine Setup ==="
echo ""
echo "This script helps you create the Claude Routine."
echo "You'll need to configure it interactively via Claude Code."
echo ""
echo "Prerequisites:"
echo "  1. Claude Code CLI installed and authenticated"
echo "  2. AWS credentials ready (access key + secret)"
echo "  3. S3 bucket created for reports"
echo "  4. Slack webhook URL (optional)"
echo ""
echo "Steps:"
echo "  1. Open Claude Code: claude"
echo "  2. Run: /schedule"
echo "  3. Describe: 'Create a weekly routine that runs every Monday at 9am UTC'"
echo "  4. Set the prompt from shared/prompt.md"
echo "  5. Add this repository"
echo "  6. Configure environment variables from routine-config.json"
echo "  7. Enable trusted network access"
echo "  8. Add Slack connector"
echo ""
echo "Alternatively, use the API (research preview):"
echo "  claude schedule create --config $CONFIG_FILE"
echo ""
echo "Review routine-config.json and replace all REPLACE_WITH_* values first."
echo ""

# Validate config has no unreplaced placeholders
if grep -q "REPLACE_WITH" "$CONFIG_FILE"; then
  echo "WARNING: routine-config.json still contains REPLACE_WITH_* placeholders."
  echo "Edit the file and replace these values before creating the routine."
  grep "REPLACE_WITH" "$CONFIG_FILE" | sed 's/^/  /'
  exit 1
fi

echo "Config looks ready. Use Claude Code /schedule to create the routine."
```

- [ ] **Step 3: Make setup.sh executable and verify**

Run: `chmod +x routines/setup.sh && bash -n routines/setup.sh && echo "syntax OK"`
Expected: "syntax OK"

- [ ] **Step 4: Validate JSON**

Run: `cat routines/routine-config.json | jq .`
Expected: Valid JSON, no errors

- [ ] **Step 5: Commit**

```bash
git add routines/routine-config.json routines/setup.sh
git commit -m "feat: add Claude Routine config and setup script for weekly FinOps"
```

---

### Task 10: Verify MCP Server Integration

**Files:**
- None created (verification only)

- [ ] **Step 1: Verify MCP server can start**

Run: `cd aws-finops-mcp-server && uv sync 2>&1 | tail -3`
Expected: Dependencies installed successfully

- [ ] **Step 2: Verify MCP server lists tools**

Run: `cd aws-finops-mcp-server && echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | uv run aws-finops-mcp-server 2>/dev/null | head -5`
Expected: JSON response listing `get_cost` and `run_finops_audit` tools

- [ ] **Step 3: Verify Hermes config references MCP correctly**

Run: `python3 -c "import yaml; c=yaml.safe_load(open('hermes/config.yaml')); print(c['mcp_servers']['aws-finops'])" `
Expected: Dict with command=uv, args containing aws-finops-mcp-server

- [ ] **Step 4: Commit (no changes, verification only)**

No commit needed — verification task.

---

### Task 11: End-to-End Dry Run Verification

**Files:**
- None created (verification only)

- [ ] **Step 1: Verify all files exist**

Run:
```bash
for f in shared/prompt.md shared/iam-policy.json shared/report-template.html shared/slack-notify.sh \
         hermes/config.yaml hermes/SOUL.md \
         hermes/skills/aws-finops-audit/SKILL.md \
         hermes/skills/aws-cost-analysis/SKILL.md \
         hermes/skills/aws-report-gen/SKILL.md \
         routines/routine-config.json routines/setup.sh; do
  if [[ -f "$f" ]]; then echo "OK: $f"; else echo "MISSING: $f"; fi
done
```
Expected: All files show "OK"

- [ ] **Step 2: Verify HTML template renders in browser**

Run: `open shared/report-template.html`
Expected: Dashboard opens in browser with placeholder content, all 8 sections visible

- [ ] **Step 3: Verify guardrails concept**

Run:
```bash
# The Hermes approval system has built-in DANGEROUS_PATTERNS.
# Our config uses "smart" mode which auto-approves reads.
# Verify our config is valid YAML:
python3 -c "
import yaml
c = yaml.safe_load(open('hermes/config.yaml'))
assert c['approvals']['mode'] == 'smart', 'approval mode not smart'
assert 'aws-finops' in c['mcp_servers'], 'MCP server not configured'
assert c['model']['default'] == 'anthropic/claude-haiku-4-5', 'wrong model'
print('All config assertions passed')
"
```
Expected: "All config assertions passed"

- [ ] **Step 4: Verify JSON files are valid**

Run:
```bash
jq . shared/iam-policy.json > /dev/null && echo "IAM policy: valid" && \
jq . routines/routine-config.json > /dev/null && echo "Routine config: valid"
```
Expected: Both files valid

- [ ] **Step 5: Final commit with .gitignore**

Create `.gitignore`:
```
.superpowers/
*.pyc
__pycache__/
.env
finops-report-*.html
```

```bash
git add .gitignore
git commit -m "chore: add .gitignore for generated reports and build artifacts"
```

---

## Summary

| Task | Component | Files |
|------|-----------|-------|
| 1 | IAM Policy | `shared/iam-policy.json` |
| 2 | Master Prompt | `shared/prompt.md` |
| 3 | HTML Template | `shared/report-template.html` |
| 4 | Slack Script | `shared/slack-notify.sh` |
| 5 | Hermes Skill: Audit | `hermes/skills/aws-finops-audit/SKILL.md` |
| 6 | Hermes Skill: Cost | `hermes/skills/aws-cost-analysis/SKILL.md` |
| 7 | Hermes Skill: Report | `hermes/skills/aws-report-gen/SKILL.md` |
| 8 | Hermes Config + SOUL | `hermes/config.yaml`, `hermes/SOUL.md` |
| 9 | Claude Routine | `routines/routine-config.json`, `routines/setup.sh` |
| 10 | MCP Verification | (verification only) |
| 11 | E2E Dry Run | `.gitignore` |

**Dependencies:** Tasks 1-4 (shared artifacts) can run in parallel. Tasks 5-7 (skills) can run in parallel. Task 8 depends on MCP path from Task 10. Task 9 is independent. Task 11 depends on all others.
