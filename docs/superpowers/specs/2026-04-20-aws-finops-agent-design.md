# AWS FinOps Agent — Design Specification

**Date:** 2026-04-20
**Status:** Draft
**Author:** Claude + gshah

## Overview

Weekly AWS FinOps agent that scans multi-account environments, generates comprehensive HTML dashboard reports, uploads to S3, and notifies via Slack. Built as two parallel implementations sharing common artifacts:

1. **Hermes Agent** — local Mac, Hermes cron scheduler, full guardrails
2. **Claude Routine** — Anthropic cloud, weekly schedule, zero maintenance

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Tool strategy | Hybrid: MCP + AWS CLI | MCP covers cost/audit (~20%), CLI fills gaps (rightsizing, RI/SP, S3, RDS, Trusted Advisor) |
| Report scope | All 8 sections | Full FinOps coverage: cost, waste, rightsizing, RI/SP, S3, budgets, recommendations, Trusted Advisor |
| AWS accounts | Multi-account via profiles | Iterates all profiles in ~/.aws/credentials |
| Report delivery | S3 + Slack | Upload HTML to S3, post pre-signed URL to Slack |
| IAM strategy | Existing profiles as-is | User manages IAM externally |
| Hermes deployment | Local Mac | Hermes cron on Mac, must be awake |
| Report comparison | Standalone snapshot | No week-over-week tracking |
| Build order | Parallel | Both runtimes + Hermes skills built simultaneously |
| Model | Haiku 4.5 | anthropic/claude-haiku-4-5 via Anthropic provider |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    SHARED ARTIFACTS                         │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │  Agent Prompt │  │  HTML Report │  │  IAM Policy      │  │
│  │  (SOUL.md /   │  │  Template    │  │  (read-only +    │  │
│  │   system msg) │  │  (Jinja2)    │  │   s3:PutObject)  │  │
│  └──────┬───────┘  └──────┬───────┘  └──────────────────┘  │
│         │                 │                                  │
│  ┌──────┴─────────────────┴────────────────────────────┐   │
│  │              Hermes Skills (reusable)                │   │
│  │  ┌─────────────┐ ┌──────────────┐ ┌──────────────┐  │   │
│  │  │ aws-finops/  │ │ aws-cost/    │ │ aws-report/  │  │   │
│  │  │ audit       │ │ analysis     │ │ generator    │  │   │
│  │  │ SKILL.md    │ │ SKILL.md     │ │ SKILL.md     │  │   │
│  │  └─────────────┘ └──────────────┘ └──────────────┘  │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
         │                                     │
         ▼                                     ▼
┌─────────────────────────┐    ┌──────────────────────────────┐
│  HERMES AGENT (Local)   │    │  CLAUDE ROUTINE (Cloud)      │
│                         │    │                              │
│  ~/.hermes/config.yaml  │    │  claude.ai/code/routines     │
│  ├─ model: haiku-4.5    │    │  ├─ model: haiku-4.5         │
│  ├─ terminal: local     │    │  ├─ schedule: weekly         │
│  ├─ mcp: finops-server  │    │  ├─ env: AWS_* credentials   │
│  ├─ approval: smart     │    │  ├─ repo: this project       │
│  ├─ cron: weekly        │    │  └─ connectors: slack        │
│  └─ guardrails: on      │    │                              │
└─────────────────────────┘    └──────────────────────────────┘
```

## Project Structure

```
capstone/
├── aws-finops-mcp-server/          # Existing MCP server (as-is, read-only)
├── shared/
│   ├── prompt.md                   # Master agent prompt (8-section analysis)
│   ├── report-template.html        # Jinja2 HTML dashboard template
│   ├── iam-policy.json             # Least-privilege IAM policy
│   └── slack-notify.sh             # S3 upload + Slack webhook script
├── hermes/
│   ├── config.yaml                 # Hermes config (model, MCP, terminal, cron)
│   ├── SOUL.md                     # Agent persona
│   └── skills/
│       ├── aws-finops-audit/
│       │   └── SKILL.md            # Waste detection skill
│       ├── aws-cost-analysis/
│       │   └── SKILL.md            # Cost analysis skill
│       └── aws-report-gen/
│           └── SKILL.md            # Report generation skill
├── routines/
│   ├── routine-config.json         # Claude Routine definition
│   └── setup.sh                    # Script to create/update routine via CLI
└── docs/
    └── superpowers/specs/
        └── 2026-04-20-aws-finops-agent-design.md
```

## Component Details

### 1. Master Agent Prompt (shared/prompt.md)

The core instruction set used by both Hermes SOUL.md and Claude Routine prompt.

**Role:** AWS FinOps Analyst with read-only access.
**Persona:** Conservative, data-driven, prioritizes savings by estimated dollar impact.

**Instructions:**
- NEVER run destructive commands (no delete, terminate, modify, stop, create beyond report upload)
- Use MCP tools first for cost/audit data, fall back to CLI for gaps
- Iterate all configured AWS profiles
- Collect all 8 sections of data
- Handle failures gracefully — partial report with error notes beats no report
- Render HTML report from template
- Upload to S3 bucket, notify Slack with pre-signed URL

**Execution order:**
1. Discover and validate AWS profiles
2. Per profile, collect data via MCP + CLI
3. Aggregate across all profiles
4. Render HTML report
5. Upload to S3
6. Post Slack notification

### 2. Hermes Skills

#### aws-finops-audit (Waste Detection)

**Purpose:** Identify unused/idle resources across all profiles and regions.

**Data sources:**
- MCP `run_finops_audit` — stopped EC2, orphaned EBS, unassociated EIPs, budget status
- CLI `aws rds describe-db-instances` — idle RDS (check connections, CPU)
- CLI `aws elbv2 describe-load-balancers` + `describe-target-health` — idle ALBs/NLBs
- CLI `aws ec2 describe-nat-gateways` — NAT Gateways with low traffic
- CLI `aws ec2 describe-security-groups` — unused security groups (no attached ENIs)

**Output:** JSON object with waste findings per profile/region, estimated monthly cost per item.

#### aws-cost-analysis (Cost & Optimization Signals)

**Purpose:** Collect cost data and optimization recommendations.

**Data sources:**
- MCP `get_cost` — cost by service, region, account for last 7 days
- CLI `aws ce get-rightsizing-recommendation` — EC2 rightsizing
- CLI `aws ce get-reservation-utilization` — RI utilization %
- CLI `aws ce get-savings-plans-utilization-details` — SP coverage and utilization
- CLI `aws s3api list-buckets` + `get-bucket-lifecycle-configuration` — S3 lifecycle gaps
- CLI `aws s3 ls s3://bucket --summarize` — bucket sizes
- CLI `aws support describe-trusted-advisor-checks` + `describe-trusted-advisor-check-result` — AWS recommendations (requires Business/Enterprise support)

**Output:** JSON object with cost breakdowns, rightsizing recommendations, RI/SP utilization, S3 optimization opportunities, Trusted Advisor findings.

#### aws-report-gen (Render & Deliver)

**Purpose:** Render collected data into HTML report, upload to S3, notify Slack.

**Steps:**
1. Load report-template.html
2. Inject collected JSON data into template sections
3. Save rendered HTML locally
4. `aws s3 cp report.html s3://$S3_REPORT_BUCKET/finops/YYYY-MM-DD.html`
5. `aws s3 presign s3://$S3_REPORT_BUCKET/finops/YYYY-MM-DD.html --expires-in 604800` (7 days)
6. `curl -X POST $SLACK_WEBHOOK_URL -H 'Content-type: application/json' -d '{"text": "..."}'`

**Output:** HTML file in S3, Slack message with pre-signed URL.

### 3. Hermes Configuration

```yaml
# ~/.hermes/config.yaml (or capstone/hermes/config.yaml)
model:
  default: "anthropic/claude-haiku-4-5"
  provider: "anthropic"

terminal:
  backend: "local"
  cwd: "/Users/gshah/trainings/agentic/devops/2026/apr-16/capstone"
  timeout: 300

approval:
  mode: "smart"
  auto_approve_patterns:
    - "^aws\\s+\\S+\\s+describe-"
    - "^aws\\s+\\S+\\s+list-"
    - "^aws\\s+\\S+\\s+get-"
    - "^aws\\s+ce\\s+get-"
    - "^aws\\s+s3\\s+cp\\s+.*\\s+s3://"
    - "^aws\\s+s3\\s+presign"
    - "^aws\\s+sts\\s+get-caller-identity"
    - "^jq\\s+"

mcp_servers:
  aws-finops:
    command: "uv"
    args: ["run", "--directory", "./aws-finops-mcp-server", "aws-finops-mcp-server"]
    timeout: 120

agent:
  max_turns: 60
  reasoning_effort: "medium"

memory:
  memory_enabled: true
  user_profile_enabled: false

skills:
  external_dirs:
    - ./hermes/skills
```

**Guardrails — blocked command patterns (in approval config):**

```
aws .* delete-.*
aws .* terminate-.*
aws .* stop-.*
aws .* modify-.*
aws .* update-.*
aws .* create-.* (except presign)
aws .* put-.* (except s3 cp to report bucket)
aws iam .*
aws organizations .*
aws sts assume-role.*
rm -rf .*
chmod .*
sudo .*
curl .* \| .*bash
```

**Allowed write exceptions:**

```
aws s3 cp .* s3://$S3_REPORT_BUCKET/finops/.*
aws s3 presign .*
curl -X POST $SLACK_WEBHOOK_URL .*
```

### 4. Claude Routine Configuration

```json
{
  "name": "aws-finops-weekly",
  "description": "Weekly AWS FinOps analysis and reporting",
  "schedule": "weekly",
  "model": "claude-haiku-4-5-20251001",
  "prompt": "Read shared/prompt.md and follow instructions exactly. Use the aws-finops-mcp-server MCP tools and AWS CLI to collect data across all profiles. Generate HTML report, upload to S3, notify Slack.",
  "repositories": ["<user-repo-url>"],
  "environment": {
    "network": "trusted",
    "env_vars": {
      "AWS_ACCESS_KEY_ID": "<from-secrets>",
      "AWS_SECRET_ACCESS_KEY": "<from-secrets>",
      "AWS_DEFAULT_REGION": "us-east-1",
      "S3_REPORT_BUCKET": "<bucket-name>",
      "SLACK_WEBHOOK_URL": "<webhook-url>"
    },
    "setup_script": "pip install awscli && cd aws-finops-mcp-server && uv sync"
  },
  "connectors": ["slack"]
}
```

**Note:** Multi-profile not natively supported in Routines (no ~/.aws/credentials). Options:
- Pass multiple sets of credentials as env vars (AWS_PROFILE_1_*, AWS_PROFILE_2_*)
- Use cross-account IAM roles with a single set of base credentials
- Scope Routine to single account, run multiple routines for multi-account

### 5. HTML Report Template

Single-file HTML dashboard with inline CSS. No external dependencies.

**Sections:**
1. **Executive Summary** — total spend, top 3 savings opportunities, health score (red/yellow/green)
2. **Cost Overview** — spend by service (CSS bar chart), by region, by account, daily burn rate
3. **Waste Detection** — table: resource type, resource ID, region, profile, estimated monthly cost, recommendation
4. **Rightsizing** — table: instance ID, current type, recommended type, estimated monthly savings
5. **RI & Savings Plans** — utilization %, coverage %, expiring commitments, purchase recommendations
6. **S3 & Storage** — buckets without lifecycle, storage class recommendations, old snapshots
7. **Budget Status** — budget name, limit, actual, forecast, status (under/over/forecasted)
8. **Recommendations** — prioritized table: action, estimated annual savings, effort (easy/medium/hard), risk (low/medium/high)

**Style:** Professional dashboard, dark/light mode toggle, responsive, print-friendly via `@media print`.

**Rendering:** Agent populates template by replacing placeholder variables or using Jinja2-style `{{ variable }}` blocks. Template includes sample data structure comments so the agent knows the expected JSON shape.

### 6. IAM Policy (shared/iam-policy.json)

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
        "ec2:DescribeInstances",
        "ec2:DescribeVolumes",
        "ec2:DescribeAddresses",
        "ec2:DescribeNatGateways",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeNetworkInterfaces",
        "rds:DescribeDBInstances",
        "elasticloadbalancing:DescribeLoadBalancers",
        "elasticloadbalancing:DescribeTargetHealth",
        "s3:ListAllMyBuckets",
        "s3:GetBucketLocation",
        "s3:GetLifecycleConfiguration",
        "budgets:ViewBudget",
        "support:DescribeTrustedAdvisorChecks",
        "support:DescribeTrustedAdvisorCheckResult",
        "sts:GetCallerIdentity",
        "cloudwatch:GetMetricStatistics"
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

## Error Handling

| Failure | Behavior |
|---------|----------|
| AWS profile auth fails | Skip profile, log error in report, continue others |
| MCP server unreachable | Fall back to CLI equivalents for cost/audit |
| API rate limit / throttle | Note in report section, partial data OK |
| Trusted Advisor not available | Skip section, note "requires Business/Enterprise support" |
| S3 upload fails | Save report locally, skip Slack, log error |
| Slack webhook fails | Report already in S3, log error, don't retry |
| Guardrail blocks command | Skip data point, note in report as "blocked by policy" |

**Principle:** Never fail completely. Partial report with error notes > no report.

## Security Boundaries

**ALLOWED (green list):**
- All `describe-*`, `list-*`, `get-*` AWS API calls for supported services
- `aws s3 cp` to designated report bucket only
- `aws s3 presign` for generating read URLs
- `curl` to Slack webhook URL only
- `jq`, `cat`, `echo` for data processing

**BLOCKED (red list):**
- All `delete-*`, `terminate-*`, `stop-*`, `modify-*`, `update-*`, `create-*` (except presign)
- All `aws iam *` and `aws organizations *` operations
- `aws sts assume-role` (no privilege escalation)
- `rm -rf`, `chmod`, `sudo`
- `curl | bash`, `wget | sh` (pipe-to-shell)
- Environment variable exfiltration
- `ssh`, `scp`, `nc` (no network pivoting)

## Testing Strategy

**Level 1 — Dry Run (no AWS calls):**
- Verify prompt loads correctly in both Hermes and Routine
- Verify HTML template renders with sample JSON data
- Verify guardrails block destructive commands
- Verify MCP server starts and responds to tool list

**Level 2 — Single Profile Test:**
- Run against one AWS profile, verify all 8 sections populate
- Verify S3 upload works, Slack notification arrives
- Verify report HTML is valid and readable

**Level 3 — Multi-Profile Test:**
- Run against all profiles, verify aggregation across accounts
- Verify one failing profile doesn't break others

## MCP Server Assessment

The `aws-finops-mcp-server` was audited and found:
- **Safe:** 100% read-only, zero destructive operations, `readOnlyHint: True` annotations
- **Current:** boto3 1.38.29, MCP SDK 1.9.2, Python 3.13
- **Limited:** Only 2 tools (get_cost, run_finops_audit) — covers ~20% of FinOps needs
- **No tests:** No automated test suite
- **Recommendation:** Use as-is for structured cost/audit data, supplement with CLI for full coverage

## Environment Variables

| Variable | Used By | Purpose |
|----------|---------|---------|
| `ANTHROPIC_API_KEY` | Hermes | Haiku 4.5 API access |
| `AWS_ACCESS_KEY_ID` | Routine | AWS auth (cloud) |
| `AWS_SECRET_ACCESS_KEY` | Routine | AWS auth (cloud) |
| `AWS_DEFAULT_REGION` | Both | Default region for global services |
| `S3_REPORT_BUCKET` | Both | Bucket for HTML report upload |
| `SLACK_WEBHOOK_URL` | Both | Slack incoming webhook URL |
