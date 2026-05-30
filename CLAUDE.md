# safe-agent

Security skills for AI coding agents. This repo follows the agentskills.io standard.

## Structure

- `skills/skill-verify/` — Skill auditing before installation (from Flare + OWASP)
- `skills/cost-guard/` — Per-session budget tracking and enforcement (from LOCO BudgetManager)
- `skills/tool-guard/` — Tool call authorization and approval gates (from LOCO + Flare)
- `skills/behavior-watch/` — Behavioral anomaly detection on agent actions (from Flare anomaly engine)
- `skills/pre-exec-check/` — Pre-execution safety checks for destructive commands (from Flare heuristics)
- `tests/fixtures/` — Test skills (safe and malicious) for validating skill-verify
- `hooks/` — Deterministic Claude Code hooks (PreToolUse blocking + PostToolUse session state tracking)
- `.claude-plugin/` — Plugin manifests for Claude Code marketplace

## How the skills compose

The 5 skills form a defense-in-depth stack. Recommended usage order:

1. **Before installing anything**: `/safe-agent:skill-verify` — audit the skill
2. **At session start**: `/safe-agent:tool-guard profile careful` — restrict tool access
3. **At session start**: `/safe-agent:cost-guard $N` — set a spend limit
4. **During work**: `pre-exec-check` activates automatically on dangerous commands
5. **Periodically or at session end**: `/safe-agent:behavior-watch` — audit what happened

Cross-skill references:
- `behavior-watch` suggests `tool-guard` and `cost-guard` actions in its remediation
- `pre-exec-check` complements `tool-guard` (pre-exec-check catches dangerous commands
  even when Bash is allowed; tool-guard gates the tool itself)
- `hooks/pre-exec-check.sh` complements the behavioral `pre-exec-check` skill (hook
  provides deterministic blocking for CRITICAL patterns; skill provides context-aware
  warnings for HIGH/MEDIUM patterns)
- `hooks/post-tool-use.sh` tracks session state and enables cross-tool enforcement
  (e.g., credential read via Read tool blocks subsequent network commands via Bash)
- `hooks/propagation-check.sh` prevents multi-agent propagation (T7) by blocking
  injection patterns written to agent-config files (CLAUDE.md, SKILL.md, settings.json)
- `skill-verify` is standalone — run it before the session, not during

## Development guidelines

- Skills are Markdown-first. Each skill is a `SKILL.md` file with YAML frontmatter.
- Reference materials go in `references/` subdirectories.
- Keep SKILL.md files under 500 lines / 5,000 tokens for progressive disclosure.
- All skills that don't need external tools must declare `allowed-tools: ""` (zero permissions).
- Only `skill-verify` needs tools (`Read Grep Glob Bash`) because it reads external files.

## Testing skills

Run each skill against real scenarios to validate:

```
# Test skill-verify against the included fixtures
/safe-agent:skill-verify tests/fixtures/safe-skill
/safe-agent:skill-verify tests/fixtures/malicious-exfiltration

# Test cost-guard
/safe-agent:cost-guard $1 reject
# ... do some work, verify it stops at the limit

# Test tool-guard
/safe-agent:tool-guard profile readonly
# ... try to edit a file, verify it refuses

# Test behavior-watch
# ... do various tool calls, then:
/safe-agent:behavior-watch

# Test pre-exec-check (behavioral)
# ... ask the agent to run `rm -rf /` or `git push --force origin main`
# ... verify it warns before proceeding

# Test pre-exec-check hook (deterministic)
echo '{"tool_input":{"command":"rm -rf /"}}' | ./hooks/pre-exec-check.sh
# ... should exit 2 with BLOCKED message
echo '{"tool_input":{"command":"npm test"}}' | ./hooks/pre-exec-check.sh
# ... should exit 0 (allowed)
```

## Contributing new threat patterns

To add a new detection pattern to `skill-verify`:

1. Add the pattern to `skills/skill-verify/references/threat-patterns.md` under the
   appropriate category
2. Reference the pattern in `skills/skill-verify/SKILL.md` under the relevant phase
3. Create a test fixture in `tests/fixtures/` demonstrating the pattern
4. Test: run `/safe-agent:skill-verify tests/fixtures/your-new-fixture` and verify detection

Threat patterns should be specific and include real code examples, not vague descriptions.

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool. When in doubt, invoke the skill.

Key routing rules:
- Product ideas/brainstorming → invoke /office-hours
- Strategy/scope → invoke /plan-ceo-review
- Architecture → invoke /plan-eng-review
- Design system/plan review → invoke /design-consultation or /plan-design-review
- Full review pipeline → invoke /autoplan
- Bugs/errors → invoke /investigate
- QA/testing site behavior → invoke /qa or /qa-only
- Code review/diff check → invoke /review
- Visual polish → invoke /design-review
- Ship/deploy/PR → invoke /ship or /land-and-deploy
- Save progress → invoke /context-save
- Resume context → invoke /context-restore
- Author a backlog-ready spec/issue → invoke /spec
