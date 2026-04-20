# Changelog

## [0.1.0] - 2026-04-20

### Added
- Master agent prompt with 8-section FinOps analysis (shared/prompt.md)
- HTML dashboard report template with dark/light theme, 8 sections, inline CSS/JS (shared/report-template.html)
- Least-privilege IAM policy for read-only AWS access + S3 report upload (shared/iam-policy.json)
- S3 upload and Slack notification script with safe JSON construction via jq (shared/slack-notify.sh)
- Hermes skill: aws-finops-audit — waste detection (stopped EC2, orphaned EBS, idle RDS, unused ELBs, NAT Gateways, unused SGs)
- Hermes skill: aws-cost-analysis — cost overview, rightsizing, RI/SP utilization, S3 optimization, Trusted Advisor
- Hermes skill: aws-report-gen — HTML rendering, S3 delivery, Slack notification
- Hermes agent configuration with smart approval guardrails and MCP server integration
- Hermes SOUL persona for AWS FinOps Analyst
- Claude Routine configuration for weekly cloud-hosted execution
- Claude Routine setup script with placeholder validation
- Optional aws-finops-mcp-server integration (clone separately, read-only, 2 tools: get_cost, run_finops_audit)
- Dedicated Hermes profile (`hermes -p finops`) — isolated from main agent
- Skills installed globally at `~/.hermes/skills/devops/`

### Security
- All AWS operations read-only (describe, list, get) except S3 report upload
- Explicit guardrail patterns blocking destructive AWS commands
- Smart approval mode with auto-approve for known-safe read commands
- IAM policy enforces least-privilege with scoped S3 write access
