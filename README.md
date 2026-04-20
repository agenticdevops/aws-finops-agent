# AWS FinOps Agent

Weekly AWS FinOps agent that scans multi-account environments, identifies cost optimization opportunities, and generates comprehensive HTML dashboard reports.

Two parallel runtimes:
- **Hermes Agent** — local, cron-scheduled, full guardrails
- **Claude Routine** — Anthropic cloud, zero maintenance

## Features

- **8-section HTML dashboard**: cost overview, waste detection, rightsizing, RI/SP utilization, S3 optimization, budget status, Trusted Advisor, prioritized recommendations
- **Hybrid tooling**: MCP server for structured cost/audit data + AWS CLI for full coverage
- **Multi-account**: iterates all AWS CLI profiles in `~/.aws/credentials`
- **Delivery**: S3 upload + Slack notification with pre-signed URL
- **Read-only**: zero destructive AWS operations, enforced at IAM + guardrail level
- **Dark/light theme**, responsive, print-friendly reports

## Quick Start

### Prerequisites

- [Hermes Agent](https://github.com/NousResearch/hermes-agent) installed
- AWS CLI configured with at least one profile
- `ANTHROPIC_API_KEY` set in `~/.hermes/.env`

### 1. Clone

```bash
git clone --recurse-submodules https://github.com/agenticdevops/aws-finops-agent.git
cd aws-finops-agent
```

### 2. Install MCP Server

```bash
cd aws-finops-mcp-server && uv sync && cd ..
```

### 3. Configure Hermes

Add to your `~/.hermes/config.yaml`:

```yaml
# Skills
skills:
  external_dirs:
    - /path/to/aws-finops-agent/hermes/skills

# MCP Server
mcp_servers:
  aws-finops:
    command: "uv"
    args: ["run", "--directory", "/path/to/aws-finops-agent/aws-finops-mcp-server", "aws-finops-mcp-server"]
    timeout: 120

# Guardrails (auto-approve read-only AWS commands)
approvals:
  mode: "smart"
  auto_approve_patterns:
    - "^aws\\s+\\S+\\s+describe-"
    - "^aws\\s+\\S+\\s+list-"
    - "^aws\\s+\\S+\\s+get-"
    - "^aws\\s+ce\\s+get-"
    - "^aws\\s+s3api\\s+get-"
    - "^aws\\s+s3api\\s+list-"
    - "^aws\\s+sts\\s+get-caller-identity"
    - "^aws\\s+configure\\s+list-profiles"
    - "^jq\\s+"
```

### 4. Run Interactively

```bash
hermes
# Ask: "Run a FinOps audit on my AWS accounts"
```

### 5. Schedule Weekly

```bash
hermes cron create --name "aws-finops-weekly" \
  --skill aws-finops-audit \
  --skill aws-cost-analysis \
  --skill aws-report-gen \
  "0 9 * * 1" \
  "Run a complete FinOps audit. Follow shared/prompt.md instructions."
```

## Project Structure

```
aws-finops-agent/
├── shared/                          # Shared artifacts (both runtimes)
│   ├── prompt.md                    # Master agent prompt
│   ├── report-template.html         # HTML dashboard template
│   ├── iam-policy.json              # Least-privilege IAM policy
│   └── slack-notify.sh              # S3 upload + Slack webhook
├── hermes/                          # Hermes Agent runtime
│   ├── config.yaml                  # Model, MCP, guardrails config
│   ├── SOUL.md                      # Agent persona
│   └── skills/                      # Hermes skills
│       ├── aws-finops-audit/        # Waste detection
│       ├── aws-cost-analysis/       # Cost analysis + optimization
│       └── aws-report-gen/          # Report rendering + delivery
├── routines/                        # Claude Routine runtime
│   ├── routine-config.json          # Routine definition
│   └── setup.sh                     # Setup guide
├── aws-finops-mcp-server/           # MCP server (submodule)
└── docs/superpowers/                # Design spec + implementation plan
```

## Agent Profile

| Component | File | Purpose |
|-----------|------|---------|
| **Persona** | `hermes/SOUL.md` | Agent identity, personality, workflow |
| **Config** | `hermes/config.yaml` | Model (Haiku 4.5), MCP, guardrails, approval patterns |
| **Master Prompt** | `shared/prompt.md` | Full instructions with safety rules, execution phases, CLI commands |
| **Guardrails** | `hermes/config.yaml` (approvals section) | Smart approval + auto-approve patterns for read-only commands |
| **Audit Skill** | `hermes/skills/aws-finops-audit/SKILL.md` | Waste detection procedures |
| **Cost Skill** | `hermes/skills/aws-cost-analysis/SKILL.md` | Cost analysis procedures |
| **Report Skill** | `hermes/skills/aws-report-gen/SKILL.md` | Report generation + delivery |
| **IAM Policy** | `shared/iam-policy.json` | AWS permissions (29 read-only + S3 write) |

## Report Sections

1. **Executive Summary** — health score, total spend, top savings opportunities
2. **Cost Overview** — spend by service/region/account, daily burn rate
3. **Waste Detection** — stopped EC2, orphaned EBS, idle RDS, unused ELBs, NAT Gateways, unused SGs
4. **Rightsizing** — EC2 instance type recommendations
5. **RI & Savings Plans** — utilization %, coverage gaps, expiring commitments
6. **S3 & Storage** — buckets without lifecycle policies, storage class optimization
7. **Budget Status** — budget vs actual vs forecast
8. **Recommendations** — prioritized by savings, with effort and risk ratings

## Security

All operations are read-only. Security is enforced at three layers:

1. **IAM Policy** (`shared/iam-policy.json`) — 29 read-only actions + scoped S3 write
2. **Agent Prompt** (`shared/prompt.md`) — explicit safety rules in every instruction
3. **Hermes Guardrails** (`hermes/config.yaml`) — smart approval blocks destructive commands

Blocked commands include: `delete-*`, `terminate-*`, `stop-*`, `modify-*`, `aws iam *`, `aws organizations *`, `aws sts assume-role`, `rm -rf`, `sudo`, `curl | bash`.

## S3 + Slack Delivery

Set environment variables:

```bash
export S3_REPORT_BUCKET=my-finops-reports
export SLACK_WEBHOOK_URL=https://hooks.slack.com/services/T.../B.../xxx
```

The agent uploads the HTML report to `s3://bucket/finops/YYYY-MM-DD.html`, generates a 7-day pre-signed URL, and posts to Slack.

## Claude Routine (Cloud)

For cloud-hosted execution without a local machine:

1. Edit `routines/routine-config.json` — replace all `REPLACE_WITH_*` placeholders
2. Run `routines/setup.sh` for guided setup
3. Or use Claude Code: `/schedule` to create the routine

## License

MIT
