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
if ! PRESIGNED_URL=$(aws s3 presign \
  "s3://${S3_REPORT_BUCKET}/${S3_KEY}" \
  --expires-in 604800 \
  ${AWS_PROFILE_FLAG} 2>/dev/null); then
  echo "ERROR: Failed to generate presigned URL" >&2
  exit 1
fi

echo "Report URL: ${PRESIGNED_URL}"

# Post to Slack (if webhook configured)
if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
  echo "Notifying Slack..."
  jq -n --arg date "$DATE" --arg url "$PRESIGNED_URL" \
    '{text: "Weekly AWS FinOps Report Ready — \($date)", blocks: [{type: "section", text: {type: "mrkdwn", text: "*Weekly AWS FinOps Report* — \($date)\n\n<\($url)|View Full Report>"}}]}' \
  | curl -sf -X POST "${SLACK_WEBHOOK_URL}" \
      -H 'Content-type: application/json' \
      -d @-
  echo ""
  echo "Slack notification sent."
else
  echo "SLACK_WEBHOOK_URL not set — skipping notification."
fi
