# AWS FinOps Agent

Weekly AWS FinOps agent that scans multi-account environments, identifies cost optimization opportunities, and generates comprehensive HTML dashboard reports.

Two parallel runtimes:
- **Hermes Agent** — local, cron-scheduled, dedicated profile with guardrails
- **Claude Routine** — Anthropic cloud, zero maintenance

## Features

- **8-section HTML dashboard**: cost overview, waste detection, rightsizing, RI/SP utilization, S3 optimization, budget status, Trusted Advisor, prioritized recommendations
- **Hybrid tooling**: MCP server for structured cost/audit data + AWS CLI for full coverage
- **Multi-account**: iterates all AWS CLI profiles in `~/.aws/credentials`
- **Delivery**: S3 upload + Slack notification with pre-signed URL
- **Read-only**: zero destructive AWS operations, enforced at IAM + guardrail level
- **Dedicated Hermes profile**: isolated config, SOUL, guardrails — doesn't pollute your main agent
- **Dark/light theme**, responsive, print-friendly reports

## Quick Start (Hermes)

### Prerequisites

- [Hermes Agent](https://github.com/NousResearch/hermes-agent) installed
- AWS CLI configured with at least one profile
- `ANTHROPIC_API_KEY` set in `~/.hermes/.env`
- `uv` installed (`curl -LsSf https://astral.sh/uv/install.sh | sh`)

### 1. Clone

```bash
git clone https://github.com/agenticdevops/aws-finops-agent.git
cd aws-finops-agent
```

### 2. Install MCP Server (optional)

The [aws-finops-mcp-server](https://github.com/ravikiranvm/aws-finops-mcp-server) provides structured cost/audit data via MCP. The agent works without it (falls back to AWS CLI), but MCP gives cleaner data for cost overview and basic waste detection.

```bash
git clone https://github.com/ravikiranvm/aws-finops-mcp-server.git
cd aws-finops-mcp-server && uv sync && cd ..
```

### 3. Install Skills (global)

Copy skills to Hermes global skills directory:

```bash
cp -r hermes/skills/aws-finops-audit ~/.hermes/skills/devops/
cp -r hermes/skills/aws-cost-analysis ~/.hermes/skills/devops/
cp -r hermes/skills/aws-report-gen ~/.hermes/skills/devops/
```

Skills are now auto-discovered by all Hermes profiles.

### 4. Create Dedicated Profile

```bash
mkdir -p ~/.hermes/profiles/finops
cp hermes/SOUL.md ~/.hermes/profiles/finops/SOUL.md
cp hermes/config.yaml ~/.hermes/profiles/finops/config.yaml
```

Edit `~/.hermes/profiles/finops/config.yaml` and update the MCP server path:

```yaml
mcp_servers:
  aws-finops:
    command: "/full/path/to/uv"    # Run: which uv
    args: ["run", "--directory", "/full/path/to/aws-finops-agent/aws-finops-mcp-server",
           "python", "-m", "aws_finops_mcp_server.main"]
    timeout: 120
    connect_timeout: 30
```

### 5. Run Interactively

```bash
hermes -p finops
# Ask: "Run a FinOps audit on my AWS accounts"
```

Your main `hermes` agent remains untouched.

### 6. Schedule Weekly

```bash
hermes -p finops cron create --name "aws-finops-weekly" \
  --skill aws-finops-audit \
  --skill aws-cost-analysis \
  --skill aws-report-gen \
  "0 9 * * 1" \
  "Run a complete FinOps audit. Follow shared/prompt.md instructions."
```

Verify:
```bash
hermes -p finops cron list
```

Note: cron jobs require `hermes gateway install` to auto-fire when your machine is on.

## Project Structure

```
aws-finops-agent/
├── shared/                          # Shared artifacts (both runtimes)
│   ├── prompt.md                    # Master agent prompt
│   ├── report-template.html         # HTML dashboard template
│   ├── iam-policy.json              # Least-privilege IAM policy
│   └── slack-notify.sh              # S3 upload + Slack webhook
├── hermes/                          # Hermes Agent runtime
│   ├── config.yaml                  # Profile config (copy to ~/.hermes/profiles/finops/)
│   ├── SOUL.md                      # Agent persona (copy to ~/.hermes/profiles/finops/)
│   └── skills/                      # Hermes skills (copy to ~/.hermes/skills/devops/)
│       ├── aws-finops-audit/        # Waste detection
│       ├── aws-cost-analysis/       # Cost analysis + optimization
│       └── aws-report-gen/          # Report rendering + delivery
├── routines/                        # Claude Routine runtime
│   ├── routine-config.json          # Routine definition
│   └── setup.sh                     # Setup guide
└── docs/superpowers/                # Design spec + implementation plan
# aws-finops-mcp-server/            # Optional — clone separately (see step 2)
```

## Agent Profile

The FinOps agent runs as a dedicated Hermes profile (`finops`), isolated from your main agent.

| Component | Repo File | Installed Location |
|-----------|-----------|-------------------|
| **Persona** | `hermes/SOUL.md` | `~/.hermes/profiles/finops/SOUL.md` |
| **Config** | `hermes/config.yaml` | `~/.hermes/profiles/finops/config.yaml` |
| **Audit Skill** | `hermes/skills/aws-finops-audit/SKILL.md` | `~/.hermes/skills/devops/aws-finops-audit/` |
| **Cost Skill** | `hermes/skills/aws-cost-analysis/SKILL.md` | `~/.hermes/skills/devops/aws-cost-analysis/` |
| **Report Skill** | `hermes/skills/aws-report-gen/SKILL.md` | `~/.hermes/skills/devops/aws-report-gen/` |
| **Master Prompt** | `shared/prompt.md` | Referenced at runtime from project dir |
| **IAM Policy** | `shared/iam-policy.json` | Applied to AWS IAM users/roles |
| **Guardrails** | `hermes/config.yaml` | Smart approval + 11 auto-approve patterns for reads |

### Profile Isolation

```bash
hermes                # Your main agent (unchanged)
hermes -p finops      # FinOps specialist (own SOUL, config, guardrails, memory)
hermes -p finops cron list   # FinOps cron jobs only
```

Each profile gets its own:
- `SOUL.md` (persona)
- `config.yaml` (model, MCP, guardrails)
- Memory and session history
- Cron jobs

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

All operations are read-only. Security enforced at three layers:

1. **IAM Policy** (`shared/iam-policy.json`) — 29 read-only actions + scoped S3 write
2. **Agent Prompt** (`shared/prompt.md`) — explicit safety rules in every instruction
3. **Hermes Guardrails** (`hermes/config.yaml`) — smart approval blocks destructive commands, auto-approves reads

Blocked commands: `delete-*`, `terminate-*`, `stop-*`, `modify-*`, `aws iam *`, `aws organizations *`, `aws sts assume-role`, `rm -rf`, `sudo`, `curl | bash`.

## S3 + Slack Delivery

Set environment variables (in `~/.hermes/profiles/finops/.env` or shell):

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

Note: Claude Routines run in isolated cloud VMs. AWS credentials are passed as environment variables (not `~/.aws/credentials`). For multi-account, either create one routine per account or use cross-account IAM roles.

## License

MIT
