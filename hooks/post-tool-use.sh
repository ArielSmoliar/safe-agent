#!/usr/bin/env bash
# safe-agent hook: PostToolUse session state tracker.
# Logs tool calls and sets security flags in a session state file.
# The PreToolUse hook reads these flags to enforce cross-tool policies.
#
# Must be fast (<50ms) since it fires after every tool call.
#
# Exit codes:
#   0 = always (PostToolUse hooks are observational, never block)

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')

if [ -z "$TOOL_NAME" ]; then
  exit 0
fi

# Session state file -- shared with PreToolUse hook via PPID
STATE_DIR="/tmp/safe-agent"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/$PPID.jsonl"
FLAGS_FILE="$STATE_DIR/$PPID.flags"

TS=$(date +%s)

# --- Log the tool call ---
echo "{\"ts\":$TS,\"tool\":\"$TOOL_NAME\",\"input\":$TOOL_INPUT}" >> "$STATE_FILE"

# --- Detect red-flag patterns and set flags ---

# Credential file access patterns
CREDENTIAL_PATHS='\.env|\.aws/credentials|\.aws/config|\.ssh/id_|\.ssh/id_rsa|\.ssh/id_ed25519|\.gnupg/|\.netrc|\.npmrc|\.docker/config\.json|\.kube/config'

case "$TOOL_NAME" in
  Read)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    if echo "$FILE_PATH" | grep -qE "$CREDENTIAL_PATHS"; then
      echo "credential_accessed=$TS:$FILE_PATH" >> "$FLAGS_FILE"
    fi
    ;;
  Bash)
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
    # Detect credential reads via shell commands
    if echo "$COMMAND" | grep -qE "(cat|head|tail|less|more|bat)\s+.*(${CREDENTIAL_PATHS})"; then
      echo "credential_accessed=$TS:bash_read" >> "$FLAGS_FILE"
    fi
    # Track Bash call count for frequency anomaly detection
    BASH_COUNT=$(grep -c '"tool":"Bash"' "$STATE_FILE" 2>/dev/null || echo 0)
    if [ "$BASH_COUNT" -ge 50 ]; then
      # Only flag once
      if ! grep -q "excessive_bash" "$FLAGS_FILE" 2>/dev/null; then
        echo "excessive_bash=$TS:count=$BASH_COUNT" >> "$FLAGS_FILE"
      fi
    fi
    ;;
  Edit|Write)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    # Detect writes to agent config (persistence attempt)
    if echo "$FILE_PATH" | grep -qE '\.(claude|cursor|codex)/(settings|config)'; then
      echo "config_write=$TS:$FILE_PATH" >> "$FLAGS_FILE"
    fi
    # Detect writes to shell config (persistence attempt)
    if echo "$FILE_PATH" | grep -qE '(\.bashrc|\.zshrc|\.profile|\.bash_profile)$'; then
      echo "shell_config_write=$TS:$FILE_PATH" >> "$FLAGS_FILE"
    fi
    ;;
esac

# --- Sequence detection: credential access followed by network prep ---
# Check if credentials were accessed recently (within last 60 seconds)
if [ -f "$FLAGS_FILE" ] && [ "$TOOL_NAME" = "Bash" ]; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
  # If this Bash call writes to /tmp, and credentials were recently accessed,
  # flag as potential staging for exfiltration
  if echo "$COMMAND" | grep -qE '>\s*/tmp/' && grep -q "credential_accessed" "$FLAGS_FILE" 2>/dev/null; then
    echo "exfil_staging=$TS:tmp_write_after_cred_read" >> "$FLAGS_FILE"
  fi
fi

exit 0
