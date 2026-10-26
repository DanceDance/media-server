#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$PROJECT_DIR/update_stack.sh"
JOB="0 4 * * 1 /bin/bash \"$SCRIPT_PATH\" >> \"$PROJECT_DIR/update.log\" 2>&1"

if [[ ! -x "$SCRIPT_PATH" ]]; then
  echo "Update script is missing or not executable: $SCRIPT_PATH" >&2
  exit 1
fi

existing_crontab=$(crontab -l 2>/dev/null || true)
if ! grep -Fq "$SCRIPT_PATH" <<< "$existing_crontab"; then
  { printf '%s\n' "$existing_crontab"; printf '%s\n' "$JOB"; } | crontab -
  echo "Scheduled weekly update with backup for Monday at 4:00 AM."
else
  echo "Weekly update job is already scheduled."
fi
