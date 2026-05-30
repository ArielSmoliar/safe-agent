#!/usr/bin/env bash
# safe-agent hook: multi-agent propagation detection (T7).
# Prevents a compromised agent from writing malicious instructions into
# files that other agents will read and follow -- CLAUDE.md, SKILL.md,
# settings.json, hooks.
#
# Wired via Claude Code PreToolUse hook on Edit|Write calls.
# Only checks writes to agent-config files; all other writes pass through.
#
# Exit codes:
#   0 = allow (normal permission flow)
#   2 = block (stderr message sent to agent as feedback)

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "safe-agent: propagation-check hook requires jq but it's not installed." >&2
  exit 0
fi

# Read stdin to a temp file so jq can parse it reliably.
# Direct echo piping breaks when JSON contains literal newlines in values.
TMPINPUT=$(mktemp)
trap 'rm -f "$TMPINPUT"' EXIT
cat > "$TMPINPUT"

TOOL_NAME=$(jq -r '.tool_name // empty' < "$TMPINPUT")
FILE_PATH=$(jq -r '.tool_input.file_path // empty' < "$TMPINPUT")

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

block() {
  echo "BLOCKED by safe-agent propagation-check hook: $1" >&2
  echo "Why: $2" >&2
  exit 2
}

# --- Scope: only check agent-config files ---
# Skip everything else to avoid false positives on normal code.
# Also skip test fixtures -- they intentionally contain malicious patterns.

IS_AGENT_CONFIG=false

case "$FILE_PATH" in
  */CLAUDE.md|*/claude.md)           IS_AGENT_CONFIG=true ;;
  */SKILL.md|*/skill.md)             IS_AGENT_CONFIG=true ;;
  */.claude/settings*.json)          IS_AGENT_CONFIG=true ;;
  */.claude/hooks/*)                 IS_AGENT_CONFIG=true ;;
  */.cursor/settings*.json)          IS_AGENT_CONFIG=true ;;
  */.codex/settings*.json)           IS_AGENT_CONFIG=true ;;
  */.antigravity/settings*.json)     IS_AGENT_CONFIG=true ;;
esac

# Exclude test fixtures
case "$FILE_PATH" in
  */tests/fixtures/*|*/test/fixtures/*|*/test-fixtures/*) IS_AGENT_CONFIG=false ;;
esac

if [ "$IS_AGENT_CONFIG" = "false" ]; then
  exit 0
fi

# --- Extract content to check ---
# Edit tool: new_string is the content being written
# Write tool: content is the full file content

if [ "$TOOL_NAME" = "Edit" ]; then
  CONTENT=$(jq -r '.tool_input.new_string // empty' < "$TMPINPUT")
elif [ "$TOOL_NAME" = "Write" ]; then
  CONTENT=$(jq -r '.tool_input.content // empty' < "$TMPINPUT")
else
  exit 0
fi

if [ -z "$CONTENT" ]; then
  exit 0
fi

# --- Check 1: Prompt injection into agent instructions ---
# These phrases override agent behavior when read by another agent session.

if echo "$CONTENT" | grep -qiE '(ignore|disregard|forget)\s+(all\s+)?(previous|prior|above)\s+(instructions|rules|guidelines)'; then
  block "Prompt injection: instruction override written to agent config file ($FILE_PATH)." \
        "This phrase would cause other agents reading this file to ignore their safety instructions."
fi

if echo "$CONTENT" | grep -qiE 'SYSTEM\s*(:|OVERRIDE|PROMPT|MESSAGE)'; then
  block "Prompt injection: SYSTEM override written to agent config file ($FILE_PATH)." \
        "This pattern impersonates system-level instructions to hijack agent behavior."
fi

if echo "$CONTENT" | grep -qiE '(you are now|switch to|enter)\s+(in\s+)?(admin|unrestricted|root|god)\s*(mode|access)'; then
  block "Prompt injection: authority escalation written to agent config file ($FILE_PATH)." \
        "This pattern attempts to elevate agent privileges beyond its intended scope."
fi

if echo "$CONTENT" | grep -qiE 'as\s+an?\s+(administrator|admin|root),?\s+(I\s+)?(authorize|grant|allow|permit)'; then
  block "Prompt injection: fake authorization written to agent config file ($FILE_PATH)." \
        "This pattern fabricates authorization to bypass safety checks."
fi

if echo "$CONTENT" | grep -qiE '(from now on|henceforth|going forward),?\s+(you will|you must|always|never)'; then
  block "Prompt injection: persistent behavior override written to agent config file ($FILE_PATH)." \
        "This pattern attempts to permanently alter agent behavior for all future sessions."
fi

# --- Check 2: Settings.json hook/MCP injection ---
# Adding hooks or MCP servers to settings files enables code execution.

if echo "$FILE_PATH" | grep -qE 'settings.*\.json$'; then
  if echo "$CONTENT" | grep -qE '"hooks"\s*:'; then
    block "Hook injection: adding hooks to agent settings ($FILE_PATH)." \
          "Hooks execute arbitrary code outside the agent's context. A compromised agent should not modify hook configuration."
  fi

  if echo "$CONTENT" | grep -qE '"mcpServers"\s*:'; then
    block "MCP server injection: adding MCP servers to agent settings ($FILE_PATH)." \
          "MCP servers grant tool access. A compromised agent should not modify MCP configuration."
  fi

  if echo "$CONTENT" | grep -qE '"permissions"\s*:.*"allow"'; then
    block "Permission escalation: modifying agent permissions ($FILE_PATH)." \
          "A compromised agent should not grant itself additional permissions."
  fi
fi

# --- Check 3: Excessive tool permissions in SKILL.md ---
# A skill claiming to be a formatter shouldn't request Bash access.

if echo "$FILE_PATH" | grep -qiE 'SKILL\.md$'; then
  if echo "$CONTENT" | grep -qE 'allowed-tools:\s*.*Bash'; then
    # Only flag if the content also contains injection-like patterns
    if echo "$CONTENT" | grep -qiE '(curl|wget|fetch|eval|exec|base64)'; then
      block "Suspicious skill: requests Bash access and contains network/eval patterns ($FILE_PATH)." \
            "Skills with Bash access and network commands are a common exfiltration vector."
    fi
  fi
fi

# --- Check 4: Obfuscated payloads ---
# Base64-encoded content with execution is a known attack pattern.

if echo "$CONTENT" | grep -qE '(base64\s*(-d|--decode)|atob)\s*.*\|\s*(sh|bash|eval|exec)'; then
  block "Obfuscated payload: base64-decode piped to execution in agent config ($FILE_PATH)." \
        "This pattern hides malicious commands from review."
fi

if echo "$CONTENT" | grep -qE 'echo\s+["\x27][A-Za-z0-9+/=]{20,}["\x27]\s*\|\s*(base64|decode)'; then
  block "Obfuscated payload: long base64 string decoded in agent config ($FILE_PATH)." \
        "This pattern hides malicious commands from review."
fi

# --- Check 5: Zero-width characters ---
# Used to hide instructions that are invisible in editors but read by agents.

if echo "$CONTENT" | grep -qP '[\x{200B}\x{200C}\x{200D}\x{FEFF}\x{2060}]' 2>/dev/null; then
  block "Hidden instructions: zero-width characters detected in agent config ($FILE_PATH)." \
        "Zero-width characters can hide instructions that are invisible in editors but executed by agents."
fi

# --- Pass: no propagation patterns detected ---
exit 0
