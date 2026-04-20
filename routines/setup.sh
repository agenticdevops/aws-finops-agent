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
