#!/usr/bin/env bash
# safe-agent: supply chain integrity for installed skills.
#
# "Verify before install" is incomplete if the installed artifact can change
# afterward. This tool records a content hash of every file in a skill, then
# detects post-install modification (repo hijack, silent update, swapped file).
#
# Usage:
#   skill-lock.sh lock   <skill-dir>   Record hashes into the lockfile
#   skill-lock.sh verify <skill-dir>   Recompute and diff against the lockfile
#   skill-lock.sh update <skill-dir>   Re-lock after an intentional change
#   skill-lock.sh verify-all           Verify every locked skill
#   skill-lock.sh list                 Show locked skills
#
# Lockfile: $SAFE_AGENT_LOCKFILE or ./safe-agent.lock.json
#
# Exit codes:
#   0 = ok (lock/update succeeded, or verify found no drift)
#   1 = drift detected (verify) — files added, removed, or modified
#   2 = usage / environment error

set -euo pipefail

LOCKFILE="${SAFE_AGENT_LOCKFILE:-$PWD/safe-agent.lock.json}"

err() { echo "skill-lock: $*" >&2; }

if ! command -v jq >/dev/null 2>&1; then
  err "jq is required but not installed. Install: https://jqlang.github.io/jq/download/"
  exit 2
fi

# Pick a sha256 tool (macOS ships shasum; most Linux ship sha256sum).
if command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | awk '{print $1}'; }
else
  err "need shasum or sha256sum to hash files; neither found"
  exit 2
fi

# Emit a JSON object {relpath: sha256, ...} for every file under a dir,
# sorted by path for stable output. Paths are relative to the skill dir so the
# lock is portable across machines.
hash_dir() {
  local dir="$1"
  local out="{}"
  local rel hash
  # -print0 + read -d handles spaces/newlines in filenames.
  while IFS= read -r -d '' f; do
    rel="${f#"$dir"/}"
    hash="$(sha256 "$f")"
    out="$(jq --arg k "$rel" --arg v "$hash" '.[$k]=$v' <<<"$out")"
  done < <(find "$dir" -type f -print0 | sort -z)
  echo "$out"
}

ensure_lockfile() {
  [ -f "$LOCKFILE" ] || echo '{"version":1,"skills":{}}' > "$LOCKFILE"
}

# Resolve a stable key for a skill dir: its basename. If two different paths
# share a basename, the second lock warns rather than silently clobbering.
skill_key() { basename "$(cd "$1" && pwd)"; }

cmd_lock() {
  local dir="$1" mode="${2:-lock}"
  [ -d "$dir" ] || { err "not a directory: $dir"; exit 2; }
  ensure_lockfile
  local key files now existing
  key="$(skill_key "$dir")"
  existing="$(jq -r --arg k "$key" '.skills[$k] // empty' "$LOCKFILE")"
  if [ -n "$existing" ] && [ "$mode" = "lock" ]; then
    err "'$key' is already locked. Use 'update' to re-lock after an intentional change, or 'verify' to check it."
    exit 2
  fi
  files="$(hash_dir "$dir")"
  # Timestamp comes from the environment, not hashed content, so re-locking
  # identical content still records when it was reviewed.
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq --arg k "$key" --arg p "$dir" --arg t "$now" --argjson f "$files" \
    '.skills[$k]={path:$p, locked_at:$t, files:$f}' "$LOCKFILE" > "$LOCKFILE.tmp"
  mv "$LOCKFILE.tmp" "$LOCKFILE"
  local n verb
  n="$(jq -r --arg k "$key" '.skills[$k].files|length' "$LOCKFILE")"
  [ "$mode" = "update" ] && verb="updated" || verb="locked"
  echo "$verb '$key' ($n files) -> $LOCKFILE"
}

cmd_verify() {
  local dir="$1"
  [ -d "$dir" ] || { err "not a directory: $dir"; exit 2; }
  [ -f "$LOCKFILE" ] || { err "no lockfile at $LOCKFILE — run 'lock' first"; exit 2; }
  local key locked
  key="$(skill_key "$dir")"
  locked="$(jq -r --arg k "$key" '.skills[$k] // empty' "$LOCKFILE")"
  if [ -z "$locked" ]; then
    err "'$key' is not in the lockfile — run 'lock $dir' first"
    exit 2
  fi

  local current expected drift=0
  current="$(hash_dir "$dir")"
  expected="$(jq -c --arg k "$key" '.skills[$k].files' "$LOCKFILE")"

  # Modified: key in both, hash differs. Removed: in lock, not on disk.
  # Added: on disk, not in lock.
  local modified removed added
  modified="$(jq -rn --argjson a "$expected" --argjson b "$current" \
    '$a|to_entries[]|select($b[.key] and $b[.key]!=.value)|.key')"
  removed="$(jq -rn --argjson a "$expected" --argjson b "$current" \
    '$a|to_entries[]|select($b[.key]==null)|.key')"
  added="$(jq -rn --argjson a "$expected" --argjson b "$current" \
    '$b|to_entries[]|select($a[.key]==null)|.key')"

  if [ -n "$modified" ]; then drift=1; while IFS= read -r f; do echo "  MODIFIED: $f"; done <<<"$modified"; fi
  if [ -n "$removed" ];  then drift=1; while IFS= read -r f; do echo "  REMOVED:  $f"; done <<<"$removed";  fi
  if [ -n "$added" ];    then drift=1; while IFS= read -r f; do echo "  ADDED:    $f"; done <<<"$added";    fi

  if [ "$drift" -eq 0 ]; then
    echo "OK: '$key' matches lock (locked $(jq -r --arg k "$key" '.skills[$k].locked_at' "$LOCKFILE"))"
    exit 0
  fi
  err "DRIFT: '$key' has been modified since it was locked. If this change is expected, run: skill-lock.sh update $dir"
  exit 1
}

cmd_verify_all() {
  [ -f "$LOCKFILE" ] || { err "no lockfile at $LOCKFILE"; exit 2; }
  local keys any_drift=0 k p
  keys="$(jq -r '.skills|keys[]' "$LOCKFILE")"
  [ -n "$keys" ] || { echo "no skills locked"; exit 0; }
  while IFS= read -r k; do
    p="$(jq -r --arg k "$k" '.skills[$k].path' "$LOCKFILE")"
    if [ ! -d "$p" ]; then
      err "MISSING: '$k' locked at $p but directory is gone"; any_drift=1; continue
    fi
    if ! cmd_verify "$p"; then any_drift=1; fi
  done <<<"$keys"
  exit "$any_drift"
}

cmd_list() {
  [ -f "$LOCKFILE" ] || { echo "no lockfile at $LOCKFILE"; exit 0; }
  jq -r '.skills|to_entries[]|"\(.key)  (\(.value.files|length) files, locked \(.value.locked_at))  \(.value.path)"' "$LOCKFILE"
}

case "${1:-}" in
  lock)       [ $# -ge 2 ] || { err "usage: skill-lock.sh lock <skill-dir>"; exit 2; };   cmd_lock "$2" lock ;;
  update)     [ $# -ge 2 ] || { err "usage: skill-lock.sh update <skill-dir>"; exit 2; }; cmd_lock "$2" update ;;
  verify)     [ $# -ge 2 ] || { err "usage: skill-lock.sh verify <skill-dir>"; exit 2; }; cmd_verify "$2" ;;
  verify-all) cmd_verify_all ;;
  list)       cmd_list ;;
  ""|-h|--help|help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) err "unknown command: $1"; exit 2 ;;
esac
