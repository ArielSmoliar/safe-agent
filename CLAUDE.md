# safe-agent

Security skills for AI coding agents. This repo follows the agentskills.io standard.

## Structure

- `skills/skill-verify/` — Skill auditing before installation (from Flare + OWASP)
- `skills/cost-guard/` — Per-session budget tracking and enforcement (from LOCO BudgetManager)
- `skills/tool-guard/` — Tool call authorization and approval gates (from LOCO + Flare)
- `skills/behavior-watch/` — Behavioral anomaly detection on agent actions (from Flare anomaly engine)
- `skills/pre-exec-check/` — Pre-execution safety checks for destructive commands (from Flare heuristics)
- `.claude-plugin/` — Plugin manifests for Claude Code marketplace

## Development

- Skills are Markdown-first. Each skill is a `SKILL.md` file with YAML frontmatter.
- Reference materials go in `references/` subdirectories.
- Keep SKILL.md files under 500 lines / 5,000 tokens for progressive disclosure.
- Test skills by running them against known-good and known-bad examples.
