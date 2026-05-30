#!/usr/bin/env bash
# safe-agent hook: deterministic pre-execution check for Bash commands.
# Blocks CRITICAL-tier patterns that are never safe regardless of context.
# Wired via Claude Code PreToolUse hook on Bash calls.
#
# Behavioral pre-exec-check (skills/pre-exec-check/SKILL.md) still handles
# HIGH/MEDIUM context-aware warnings. This hook handles hard stops only.
#
# Exit codes:
#   0 = allow (normal permission flow)
#   2 = block (stderr message sent to agent as feedback)

set -euo pipefail

# jq is required to parse hook input JSON. Without it, the hook cannot
# inspect commands and would silently fail open (non-0/non-2 exit = no block).
if ! command -v jq >/dev/null 2>&1; then
  echo "safe-agent: pre-exec-check hook requires jq but it's not installed. Commands are NOT being checked." >&2
  echo "Install jq: https://jqlang.github.io/jq/download/" >&2
  exit 0
fi

TMPINPUT=$(mktemp)
trap 'rm -f "$TMPINPUT"' EXIT
cat > "$TMPINPUT"

COMMAND=$(jq -r '.tool_input.command // empty' < "$TMPINPUT")

if [ -z "$COMMAND" ]; then
  exit 0
fi

block() {
  echo "BLOCKED by safe-agent pre-exec-check hook: $1" >&2
  echo "Suggestion: $2" >&2
  exit 2
}

# --- CRITICAL: Catastrophic file deletion ---

# rm -rf on root, home, or current directory
# Match only bare / ~ . as targets, not paths like dist/ or /tmp/foo
if echo "$COMMAND" | grep -qE 'rm\s+-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*\s+(/|~|\.)\s*$' ||
   echo "$COMMAND" | grep -qE 'rm\s+-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*\s+(/|~|\.)\s*$' ||
   echo "$COMMAND" | grep -qE 'rm\s+-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*\s+(/|~|\.)\s' ||
   echo "$COMMAND" | grep -qE 'rm\s+-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*\s+(/|~|\.)\s'; then
  block "Recursive forced delete on root, home, or current directory." \
        "Specify the exact path to delete instead of / ~ or ."
fi

# rm -rf with path traversal (..)
if echo "$COMMAND" | grep -qE 'rm\s+.*-[a-zA-Z]*r[a-zA-Z]*\s+.*\.\.' ||
   echo "$COMMAND" | grep -qE 'rm\s+.*-[a-zA-Z]*f[a-zA-Z]*\s+.*\.\.'; then
  block "Recursive delete with '..' path traversal." \
        "Use an absolute path to the target directory."
fi

# --- CRITICAL: Destructive git on protected branches ---

# git push --force to main/master/production
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*--force\b' ||
   echo "$COMMAND" | grep -qE 'git\s+push\s+.*-f\b'; then
  if echo "$COMMAND" | grep -qE '\b(main|master|production|prod|release)\b'; then
    block "Force-push to protected branch (main/master/production)." \
          "Use 'git push --force-with-lease' on a feature branch instead."
  fi
fi

# git clean -fd or -fdx (deletes untracked files irreversibly)
if echo "$COMMAND" | grep -qE 'git\s+clean\s+.*-[a-zA-Z]*f[a-zA-Z]*d' ||
   echo "$COMMAND" | grep -qE 'git\s+clean\s+.*-[a-zA-Z]*d[a-zA-Z]*f'; then
  block "git clean -fd deletes all untracked files and directories irreversibly." \
        "Use 'git clean -nd' (dry run) first to see what would be deleted."
fi

# --- CRITICAL: Database destruction ---

# DROP TABLE / DROP DATABASE / TRUNCATE TABLE
if echo "$COMMAND" | grep -qiE '\b(DROP\s+TABLE|DROP\s+DATABASE|TRUNCATE\s+TABLE)\b'; then
  block "Destructive database operation (DROP/TRUNCATE)." \
        "Create a backup first, or use a migration framework."
fi

# DELETE FROM without WHERE
if echo "$COMMAND" | grep -qiE '\bDELETE\s+FROM\s+\w+\s*;' ||
   echo "$COMMAND" | grep -qiE '\bDELETE\s+FROM\s+\w+\s*$'; then
  if ! echo "$COMMAND" | grep -qiE '\bWHERE\b'; then
    block "DELETE FROM without WHERE clause deletes all rows." \
          "Add a WHERE clause to target specific rows."
  fi
fi

# --- CRITICAL: System-level damage ---

# chmod -R 777 or chmod -R 000 (recursive permission nuke)
if echo "$COMMAND" | grep -qE 'chmod\s+(-R|--recursive)\s+(777|000)\b'; then
  block "Recursive chmod 777/000 on directory tree." \
        "Set permissions on specific files, not recursively."
fi

# chown -R on system directories
if echo "$COMMAND" | grep -qE 'chown\s+(-R|--recursive)\s+.*\s+/(etc|usr|var|bin|sbin|lib|boot|sys|proc)\b'; then
  block "Recursive chown on system directory." \
        "Only chown files you own, in your project directory."
fi

# Writing to system paths
if echo "$COMMAND" | grep -qE '>\s*/(etc|usr|bin|sbin|boot|sys|proc)/'; then
  block "Write redirect to system path." \
        "Write to your project directory or /tmp instead."
fi

# --- CRITICAL: Credential exposure ---

# cat/read of known credential files
if echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat)\s+.*~?/?\.(env|env\.[a-zA-Z]+)\b' ||
   echo "$COMMAND" | grep -qE '(cat|head|tail|less|more|bat)\s+.*(\.aws/credentials|\.ssh/id_|\.ssh/id_rsa|\.ssh/id_ed25519|\.gnupg/|\.netrc|\.npmrc|\.docker/config\.json|\.kube/config)'; then
  block "Reading credential or secret file." \
        "If you need to verify credentials exist, use 'test -f' or 'ls' instead of reading contents."
fi

# Credentials piped to network commands
if echo "$COMMAND" | grep -qE '(\.env|\.aws/credentials|\.ssh/id_|\.netrc|\.npmrc).*\|\s*(curl|wget|nc|ncat)' ||
   echo "$COMMAND" | grep -qE '(curl|wget)\s+.*\$\(cat\s+.*\.(env|aws|ssh|netrc|npmrc)'; then
  block "Credential file piped to network command (exfiltration pattern)." \
        "Never send credential files over the network."
fi

# curl/wget with credentials in URL
if echo "$COMMAND" | grep -qE '(curl|wget)\s+.*[?&](api_key|apikey|token|secret|password|auth)='; then
  block "Credentials visible in URL query parameters." \
        "Use headers (-H 'Authorization: Bearer ...') instead of URL parameters."
fi

# --- CRITICAL: Dangerous process operations ---

# pkill / killall on broad patterns
if echo "$COMMAND" | grep -qE '\b(pkill|killall)\s+-9\b'; then
  block "Force-killing processes by name with SIGKILL." \
        "Use 'pkill -15' (SIGTERM) to allow graceful shutdown, or target a specific PID."
fi

# --- POLICY ENGINE: cross-tool enforcement via session state ---
# PostToolUse hook (post-tool-use.sh) sets flags when it detects red-flag
# patterns (credential access, config writes, etc.). This section reads
# those flags and blocks commands that would complete an attack chain.

STATE_DIR="/tmp/safe-agent"
FLAGS_FILE="$STATE_DIR/$PPID.flags"

if [ -f "$FLAGS_FILE" ]; then

  # Block network egress after credential access (exfiltration prevention)
  if grep -q "credential_accessed" "$FLAGS_FILE" 2>/dev/null; then
    if echo "$COMMAND" | grep -qE '\b(curl|wget|nc|ncat|ssh|scp|rsync|ftp|sftp)\b'; then
      block "Network command after credential file access (exfiltration risk). A credential file was read earlier in this session -- network commands are blocked until the session ends." \
            "If this is legitimate, start a new session without reading credential files first."
    fi
  fi

  # Block network egress after exfiltration staging detected
  if grep -q "exfil_staging" "$FLAGS_FILE" 2>/dev/null; then
    if echo "$COMMAND" | grep -qE '\b(curl|wget|nc|ncat)\b'; then
      block "Network command after data was staged to /tmp following credential access. This matches a known exfiltration pattern: read credentials, write to /tmp, then upload." \
            "If this is legitimate, start a new session."
    fi
  fi

  # Block shell execution after shell config was modified (persistence prevention)
  if grep -q "shell_config_write" "$FLAGS_FILE" 2>/dev/null; then
    if echo "$COMMAND" | grep -qE '(source|\.)\s+.*(\.bashrc|\.zshrc|\.profile)'; then
      block "Sourcing shell config after it was modified in this session. This matches a persistence pattern: write to .bashrc, then source it to activate." \
            "Review the changes to your shell config before sourcing it."
    fi
  fi

fi

# --- Pass: no patterns matched ---
exit 0
