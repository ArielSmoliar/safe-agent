# v0.3 Manual Verification Checklist

End-to-end checks for the parts of v0.3 that cannot be verified by piping JSON
to a script — the ones that depend on Claude Code loading the updated plugin and
honoring hook decisions. The standalone scripts (`skill-lock.sh`, the hooks'
output JSON) are already unit-verified; this checklist confirms the *harness*
behaves as designed.

## Prerequisites (do these first — the checklist is meaningless without them)

- [ ] **Restart Claude Code.** Skill changes (the MCP audit in skill-verify) load
      from the plugin cache, which the running session holds in memory. Confirm
      the version: `claude plugin list | grep -A1 safe-agent` should show
      **0.3.2** (or later).
- [ ] **Wire the hooks** into the project's `.claude/settings.json` by merging
      `hooks/settings.example.json` (PreToolUse: `pre-exec-check.sh`,
      `propagation-check.sh`, `tool-guard.sh`; PostToolUse: `post-tool-use.sh`).
- [ ] **`jq` is installed** (`jq --version`). Without it the hooks fail open.
- [ ] Do destructive-command tests in a **throwaway repo or branch**, never a
      repo you care about.

---

## 1. MCP server audit (skill-verify, item 13)

Runs only after restart (loads from plugin cache).

- [ ] `/safe-agent:skill-verify tests/fixtures/vulnerable-mcp-config`
      → **DANGEROUS**. Findings name all three servers: filesystem server scoped
      to `/`, the shell server, and the remote SSE server handed `AWS_SECRET_ACCESS_KEY`
      / `GITHUB_TOKEN` via `env`. Report should frame it as a *permission /
      trust-boundary* finding, not "malware detected."
- [ ] `/safe-agent:skill-verify tests/fixtures/safe-skill`
      → **SAFE**, no MCP findings (no false positive).

## 2. Indirect prompt injection (skill-verify, item 14)

- [ ] `/safe-agent:skill-verify tests/fixtures/vulnerable-untrusted-input`
      → **CAUTION**. One HIGH finding: fetched web content treated as authoritative
      + referenced files read, no `<untrusted_data>` isolation, paired with Edit.
      Items 1–7 stay clean (the discriminator works).

## 3. Team profiles — tool-guard hook enforcement

This is the key "does the harness honor `ask`/`deny`" check. Activate a profile,
then drive tool calls and watch what actually happens.

### 3a. readonly (deny mutations + shell)
```bash
mkdir -p .safe-agent && cp profiles/readonly.json .safe-agent/policy.json
```
- [ ] Ask Claude to **read** a file → allowed, no prompt.
- [ ] Ask Claude to run a Bash command (e.g. `ls`) → **blocked**, reason cites
      `tool-guard[readonly]: Bash is denied by policy`.
- [ ] Ask Claude to **edit/write** a file → **blocked** similarly.

### 3b. careful (gate mutations, deny destructive, defer unlisted)
```bash
cp profiles/careful.json .safe-agent/policy.json
```
- [ ] Ask Claude to edit a file → **approval prompt appears** (permissionDecision
      `ask`). This is the make-or-break check that the harness honors `ask`.
- [ ] Ask Claude to run `npm test` → approval prompt.
- [ ] Ask Claude to run `rm -rf build` → **blocked** (deny pattern), reason cites
      "destructive command."
- [ ] Ask Claude to `git push --force-with-lease origin main` → **prompt, NOT a
      hard block** (confirms the 0.3.1 fix — the safe alternative isn't denied).
- [ ] Ask Claude to use an unlisted tool (e.g. WebFetch) → normal permission flow
      (no tool-guard allow/deny/ask line; `default: defer`).

### 3c. no policy → no-op
```bash
rm .safe-agent/policy.json
```
- [ ] Any tool call behaves as if the hook weren't there (defers to normal rules).

## 4. pre-exec-check force-push fix (0.3.2)

Avoid a real push. Confirm deterministically instead:
```bash
echo '{"tool_input":{"command":"git push --force-with-lease origin main"}}' | ./hooks/pre-exec-check.sh; echo "exit=$?"  # expect 0 (allowed)
echo '{"tool_input":{"command":"git push --force origin main"}}'            | ./hooks/pre-exec-check.sh; echo "exit=$?"  # expect 2 (blocked)
```
- [ ] `--force-with-lease` → exit 0; `--force` to main → exit 2.

## 5. Supply chain integrity (smoke)
```bash
export SAFE_AGENT_LOCKFILE=$(mktemp -d)/lock.json
./scripts/skill-lock.sh lock   tests/fixtures/safe-skill   # exit 0
./scripts/skill-lock.sh verify tests/fixtures/safe-skill   # OK, exit 0
```
- [ ] Lock then verify clean → exit 0. (Modify a file and re-verify → drift, exit 1.)

---

## If anything fails

- `ask`/`deny` not honored → confirm the hook is wired under `PreToolUse` with
  matcher `""` and is executable (`chmod +x hooks/tool-guard.sh`); check
  `claude --debug` for hook output.
- skill-verify still runs the old methodology → the restart didn't pick up the
  new version; re-run `claude plugin update safe-agent@safe-agent` and restart.
- Hooks silently allow everything → `jq` is probably missing (hooks fail open).
