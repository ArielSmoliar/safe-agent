#!/usr/bin/env bash
# safe-agent hook: enforceable tool-guard policy (PreToolUse, matcher "").
#
# The /tool-guard skill is advisory -- it asks the agent to self-restrict. This
# hook makes a team-shared policy deterministic: it runs outside the agent's
# context, so a compromised skill or prompt injection cannot talk its way past
# it. Commit a policy to .safe-agent/policy.json and every developer on the repo
# gets the same enforcement.
#
# Policy file: $SAFE_AGENT_POLICY, else $CLAUDE_PROJECT_DIR/.safe-agent/policy.json,
# else ./.safe-agent/policy.json. If no policy exists, the hook defers (no-op).
#
# Decision precedence (first match wins):
#   1. tool in tools.deny        -> deny
#   2. a patterns.deny rule hits -> deny
#   3. a patterns.gate rule hits -> ask   (so "Bash allowed, rm gated" works)
#   4. tool in tools.gate        -> ask
#   5. tool in tools.allow       -> allow
#   6. policy "default"          -> allow | deny | ask
#
# Output: hookSpecificOutput JSON with permissionDecision (allow/deny/ask/defer)
# on exit 0 -- the modern PreToolUse contract. "ask" shows the user a prompt.
#
# Exit codes:
#   0 = always (decision is carried in the JSON, not the exit code)

set -euo pipefail

# Locate the policy. Defer silently if there's no policy or no jq.
POLICY="${SAFE_AGENT_POLICY:-${CLAUDE_PROJECT_DIR:-$PWD}/.safe-agent/policy.json}"
[ -f "$POLICY" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

TMPINPUT=$(mktemp)
trap 'rm -f "$TMPINPUT"' EXIT
cat > "$TMPINPUT"

TOOL_NAME=$(jq -r '.tool_name // empty' < "$TMPINPUT")
[ -n "$TOOL_NAME" ] || exit 0

# The "subject" is the part of the tool input that pattern rules match against.
case "$TOOL_NAME" in
  Bash)                       SUBJECT=$(jq -r '.tool_input.command // ""'   < "$TMPINPUT") ;;
  Edit|Write|Read|NotebookEdit) SUBJECT=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' < "$TMPINPUT") ;;
  WebFetch)                   SUBJECT=$(jq -r '.tool_input.url // ""'       < "$TMPINPUT") ;;
  *)                          SUBJECT="" ;;
esac

decide() {
  # $1 = decision (allow/deny/ask), $2 = reason
  jq -cn --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  exit 0
}

# in_list <tool> <list-path-in-policy> -> 0 if tool is in that list
in_list() {
  jq -e --arg t "$1" "(.tools[\"$2\"] // []) | index(\$t) != null" "$POLICY" >/dev/null 2>&1
}

# first matching pattern rule for a given bucket (deny|gate); echoes its reason.
# A rule = {tool?: string, match: regex, reason?: string}. A rule with no "tool"
# applies to every tool; otherwise it must match the current tool. "match" is an
# extended regex tested against SUBJECT.
match_pattern() {
  local bucket="$1" rule tool match reason
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    tool=$(jq -r '.tool // ""'   <<<"$rule")
    match=$(jq -r '.match // ""' <<<"$rule")
    reason=$(jq -r '.reason // "matched a '"$bucket"' rule"' <<<"$rule")
    [ -z "$match" ] && continue
    if [ -n "$tool" ] && [ "$tool" != "$TOOL_NAME" ]; then continue; fi
    if printf '%s' "$SUBJECT" | grep -qE "$match"; then
      echo "$reason"; return 0
    fi
  done < <(jq -c --arg b "$bucket" '(.patterns[$b] // [])[]' "$POLICY")
  return 1
}

PROFILE=$(jq -r '.profile // "custom"' "$POLICY")

# 1 + 2: denials
if in_list "$TOOL_NAME" deny; then
  decide deny "tool-guard[$PROFILE]: $TOOL_NAME is denied by policy"
fi
if reason=$(match_pattern deny); then
  decide deny "tool-guard[$PROFILE]: $reason"
fi
# 3 + 4: gates (ask the user)
if reason=$(match_pattern gate); then
  decide ask "tool-guard[$PROFILE]: $reason — approve?"
fi
if in_list "$TOOL_NAME" gate; then
  decide ask "tool-guard[$PROFILE]: $TOOL_NAME is gated by policy — approve?"
fi
# 5: explicit allow
if in_list "$TOOL_NAME" allow; then
  decide allow "tool-guard[$PROFILE]: $TOOL_NAME allowed by policy"
fi
# 6: default
DEFAULT=$(jq -r '.default // "defer"' "$POLICY")
case "$DEFAULT" in
  allow) decide allow "tool-guard[$PROFILE]: default allow" ;;
  deny)  decide deny  "tool-guard[$PROFILE]: $TOOL_NAME not in allowlist (default deny)" ;;
  ask)   decide ask   "tool-guard[$PROFILE]: $TOOL_NAME not explicitly allowed (default ask) — approve?" ;;
  *)     exit 0 ;;  # defer to normal permission flow
esac
