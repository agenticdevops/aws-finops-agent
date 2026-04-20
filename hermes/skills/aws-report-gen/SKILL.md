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

Generate a self-contained HTML FinOps dashboard from collected AWS audit and cost data, upload it to S3, and deliver a summary notification to Slack.

## When to Use

- After completing an AWS audit (`aws-finops-audit` skill) and cost analysis (`aws-cost-analysis` skill), to render and distribute findings
- On a weekly scheduled run to produce the standard FinOps report for stakeholders
- To share cloud cost findings with leadership or governance teams via a durable, shareable link
- When a cost anomaly or budget breach requires an ad-hoc report to document findings

## Prerequisites

- `shared/report-template.html` — self-contained HTML template with `{{placeholder}}` variables (must exist before running)
- `shared/slack-notify.sh` — Slack notification helper script
- AWS CLI installed and configured with S3 write access to the report bucket
- Environment variables set:
  - `S3_REPORT_BUCKET` — S3 bucket name where reports are uploaded (e.g., `my-org-finops-reports`)
  - `SLACK_WEBHOOK_URL` — Incoming webhook URL for the target Slack channel
- Input data from prior skill runs:
  - Waste findings JSON from `aws-finops-audit`
  - Cost breakdown JSON from `aws-cost-analysis`

Validate S3 access before running:

```bash
aws s3 ls s3://$S3_REPORT_BUCKET/
```

## SAFETY RULES

This skill performs write operations. Only the following are permitted:

- `aws s3 cp <local-file> s3://$S3_REPORT_BUCKET/...` — upload report to the designated report bucket
- `aws s3 presign s3://$S3_REPORT_BUCKET/...` — generate a pre-signed URL for the uploaded report
- `curl -X POST $SLACK_WEBHOOK_URL` — post notification to the configured Slack webhook
- Local file writes (e.g., creating `finops-report-YYYY-MM-DD.html`)

**NEVER** write to any other S3 path, bucket, or prefix not explicitly set in `S3_REPORT_BUCKET`.

**NEVER** run `aws s3 rm`, `aws s3 rb`, or any destructive S3 operations.

**NEVER** modify IAM policies, credentials, or AWS account settings.

If `S3_REPORT_BUCKET` is not set, do not attempt to guess or construct a bucket name. Abort and prompt the user to set the variable.

## Procedure

### 1. Collect Input Data

Gather the outputs from preceding skill runs. You need:

- Waste findings from `aws-finops-audit` (JSON per profile)
- Cost breakdown from `aws-cost-analysis` (total spend, cost by service, cost by region, Reserved Instance and Savings Plans utilization, S3 findings, budget status)

Validate that both inputs are present before proceeding. If either is missing, run the corresponding skill first or prompt the user to provide the data.

### 2. Calculate Executive Summary

Derive the following values from the collected data:

- **Total Spend**: Sum of all cost data across accounts and services for the reporting period
- **Daily Average**: Total spend divided by number of days in the period
- **Top 3 Savings Opportunities**: The three waste items or rightsizing recommendations with the highest estimated annual savings
- **Health Score**: Classify overall cloud spend efficiency as:
  - `GREEN` — identified waste is less than 5% of total spend
  - `YELLOW` — identified waste is 5%–15% of total spend
  - `RED` — identified waste exceeds 15% of total spend

### 3. Render HTML Report

Read `shared/report-template.html` and replace all `{{placeholder}}` variables with real values. The following placeholders must be substituted:

| Placeholder | Value |
|---|---|
| `{{report_date}}` | Report generation date in `YYYY-MM-DD` format |
| `{{total_spend}}` | Total spend formatted as USD (e.g., `$12,345.67`) |
| `{{daily_average}}` | Daily average spend formatted as USD |
| `{{health_score}}` | `GREEN`, `YELLOW`, or `RED` |
| `{{cost_by_service}}` | HTML table or list of spend broken down by AWS service |
| `{{cost_by_region}}` | HTML table or list of spend broken down by AWS region |
| `{{waste_findings}}` | HTML summary of waste items (stopped EC2, orphaned EBS, unassociated EIPs, idle RDS, unused ELBs, NAT Gateways, unused security groups) |
| `{{rightsizing}}` | HTML summary of rightsizing recommendations |
| `{{ri_utilization}}` | Reserved Instance utilization percentage and coverage |
| `{{sp_utilization}}` | Savings Plans utilization percentage and coverage |
| `{{s3_findings}}` | S3 cost findings (storage class analysis, lifecycle gaps, large buckets) |
| `{{budget_status}}` | Budget alert status per account (within budget / over budget / approaching limit) |
| `{{recommendations}}` | Prioritized recommendations table (see Step 4) |
| `{{accounts_scanned}}` | Number of AWS accounts included in the report |
| `{{profiles_list}}` | Comma-separated list of AWS CLI profiles used |
| `{{errors}}` | Any errors or skipped checks encountered during data collection; leave blank if none |

After substitution, verify that no `{{` or `}}` markers remain in the rendered output. If any do, replace them with a visible placeholder such as `N/A` or `[data not available]`.

### 4. Generate Prioritized Recommendations

Build a recommendations table sorted by estimated annual savings impact. Assign priorities as follows:

| Priority | Threshold |
|---|---|
| Priority 1 | Estimated annual savings > $10,000 |
| Priority 2 | Estimated annual savings > $1,000 |
| Priority 3 | Estimated annual savings > $100 |
| Priority 4 | All remaining items |

Each recommendation row must include:

- **Action** — clear description of what to do (e.g., "Terminate stopped EC2 instance i-0abc123 in us-east-1")
- **Est. Annual Savings** — USD amount (only report confirmed costs; use ranges for compute if exact pricing is unknown)
- **Effort** — `Easy`, `Medium`, or `Hard`
- **Risk** — `Low`, `Medium`, or `High`

Do not include recommendations with zero or unknown savings. If savings cannot be estimated, note the item under `{{errors}}` or in a separate "Needs Review" section.

### 5. Save Locally

Write the rendered HTML to a local file using the naming convention:

```
finops-report-YYYY-MM-DD.html
```

Where `YYYY-MM-DD` is today's date. Example:

```bash
# Report is written to the current working directory
finops-report-2026-04-20.html
```

Confirm the file is non-empty before proceeding to upload.

### 6. Upload to S3 and Notify via Slack

#### Option A — Use the shared helper script (preferred)

```bash
bash shared/slack-notify.sh \
  --bucket "$S3_REPORT_BUCKET" \
  --file "finops-report-$(date +%Y-%m-%d).html" \
  --webhook "$SLACK_WEBHOOK_URL"
```

#### Option B — Manual upload and notification

Upload the report to S3 with the correct content type:

```bash
aws s3 cp "finops-report-$(date +%Y-%m-%d).html" \
  "s3://$S3_REPORT_BUCKET/reports/finops-report-$(date +%Y-%m-%d).html" \
  --content-type "text/html"
```

Generate a pre-signed URL (valid for 7 days):

```bash
aws s3 presign \
  "s3://$S3_REPORT_BUCKET/reports/finops-report-$(date +%Y-%m-%d).html" \
  --expires-in 604800
```

Post a summary notification to Slack using the pre-signed URL from the previous step:

```bash
curl -X POST "$SLACK_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "text": "AWS FinOps Report — '"$(date +%Y-%m-%d)"'",
    "attachments": [{
      "color": "<health-score-color>",
      "fields": [
        {"title": "Total Spend", "value": "<total_spend>", "short": true},
        {"title": "Health Score", "value": "<health_score>", "short": true},
        {"title": "Top Saving", "value": "<top-saving-description>", "short": false}
      ],
      "actions": [{
        "type": "button",
        "text": "View Full Report",
        "url": "<pre-signed-url>"
      }]
    }]
  }'
```

Keep the Slack message compact — summary metrics and the report link only. Do not paste the full report content into the Slack message.

## Pitfalls

1. **Template must be self-contained.** The HTML template must embed all CSS and JavaScript inline. External CDN links will not resolve when the report is opened from S3, and S3 does not serve linked assets from relative paths.

2. **Slack message character limits.** Slack attachment field values are limited to ~300 characters. Include only the top-line summary (total spend, health score, one key saving). The full detail belongs in the HTML report.

3. **Pre-signed URLs expire in 7 days.** Pre-signed URLs generated with `--expires-in 604800` are valid for exactly 7 days from generation time. If recipients need access beyond that, they must re-generate the URL or the bucket must be configured with appropriate access controls.

4. **S3 content-type must be `text/html`.** Without `--content-type "text/html"`, S3 will default to `application/octet-stream` and browsers will download the file instead of rendering it. Always pass the content-type flag explicitly.

5. **If S3 upload fails, save locally and continue.** Do not abort the entire workflow if S3 upload fails. The rendered HTML file is the primary artifact. Save it locally, report the S3 error, and attempt the Slack notification with a note that the report is available locally rather than via a link.

6. **Never guess or construct bucket names.** If `S3_REPORT_BUCKET` is not set or is empty, stop immediately and prompt the user. Writing to the wrong S3 bucket could expose sensitive financial data.
