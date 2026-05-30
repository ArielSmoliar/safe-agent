<p align="center">
  <img src="assets/hero.svg" alt="safe-agent - Security skills that make AI agents safe to run" width="900"/>
</p>

<p align="center">
  <strong>Security skills that make AI coding agents safe to run.</strong>
</p>

<p align="center">
  <a href="#install">Install</a> &middot;
  <a href="#skills">Skills</a> &middot;
  <a href="#usage">Usage</a> &middot;
  <a href="#roadmap">Roadmap</a>
</p>

---

Not another "make your agent do security" tool. safe-agent protects you *from* your agent - catching malicious skills before you install them and dangerous commands before they execute.

## The Problem

Snyk's ToxicSkills research found that **36.82% of AI agent skills** have at least one security flaw - including prompt injection, credential theft, and data exfiltration. OWASP now tracks agentic skills as a first-class attack surface.

Every time you run `/plugin install` or `npx skills add`, you're trusting someone else's instructions inside your codebase, your shell, and your cloud credentials.

safe-agent adds a verification step.

## Threat Coverage

safe-agent maps to the threat taxonomy from [*Towards Secure Agent Skills: Architecture, Threat Taxonomy, and Security Analysis*](https://arxiv.org/abs/2604.02837) (Li et al., 2026) - the first comprehensive academic security analysis of the Agent Skills framework, covering 7 threat categories and 17 attack scenarios across 3 layers:

| Layer | Category | safe-agent coverage |
|---|---|---|
| 1: Delivery & Trust | T1: Supply chain (typosquatting, repo hijacking) | `/skill-verify` |
| | T2: Consent abuse (persistent permissions, post-install modification) | `/skill-verify` |
| 2: Runtime Attack | T3: Prompt injection (direct + indirect) | `/skill-verify` |
| | T4: Code execution (malicious scripts, remote code fetch) | `/skill-verify` + `pre-exec-check` |
| | T5: Data exfiltration (credentials, env vars, codebase) | `/skill-verify` + `/behavior-watch` |
| 3: Persistent & Lateral | T6: Persistence (memory poisoning, config injection) | `/skill-verify` + `/behavior-watch` |
| | T7: Multi-agent propagation | `/behavior-watch` + multi-agent detection (roadmap: v0.2) |

## Skills

| Skill | What it does | Lineage |
|---|---|---|
| `/skill-verify` | Audit any skill for prompt injection, exfiltration, and malicious patterns before you install it | Flare + OWASP |
| `/cost-guard` | Per-session token/dollar budget with reject/alert/downgrade modes | LOCO BudgetManager |
| `/tool-guard` | Allowlist/denylist for tool calls, approval gates for destructive ops, preset profiles | LOCO + Flare |
| `/behavior-watch` | Anomaly scoring on agent actions - flags unusual tool sequences, scope creep, first-seen patterns | Flare anomaly engine |
| `pre-exec-check` | Teaches the agent to pause and verify before destructive commands (rm -rf, force-push, DROP TABLE) | Flare heuristics |

## Install

**Claude Code:**
```
/plugin marketplace add ArielSmoliar/safe-agent
/plugin install safe-agent
```

**Antigravity / Cursor / Codex:**
```bash
git clone https://github.com/ArielSmoliar/safe-agent.git
cp -r safe-agent/skills/* .antigravity/skills/  # Antigravity
cp -r safe-agent/skills/* .cursor/skills/       # Cursor
cp -r safe-agent/skills/* .codex/skills/        # Codex
```

Skills use the universal SKILL.md format (agentskills.io standard) - they work with any compatible agent.

## Usage

### Verify a skill before installing

```
/skill-verify path/to/skill-directory
```

Or verify a GitHub repo:
```
/skill-verify https://github.com/someone/cool-skills
```

Or audit all currently installed skills:
```
/skill-verify
```

You get a structured report:

```
## Skill Verify Report: cool-skill

Verdict: CAUTION
Risk Score: 42/100

### Findings
- [HIGH] Credential harvesting
  File: scripts/setup.sh, line 14
  What: Reads ~/.aws/credentials and stores in variable
  Why: Combined with the curl on line 22, credentials could be exfiltrated
  Evidence: `AWS_CREDS=$(cat ~/.aws/credentials)`

- [MEDIUM] Excessive permissions
  File: SKILL.md, line 3
  What: allowed-tools includes Bash but skill description is "code formatter"
  Why: A formatter should not need shell access

### Summary
Files scanned: 4
Issues found: 2 (0 critical, 1 high, 1 medium, 0 low)
Recommendation: Install with modifications (remove scripts/setup.sh)
```

### Set a session budget

```
/cost-guard $5
/cost-guard 200k tokens alert
```

Tracks estimated spend and warns at 50%, 80%, and 100%. Three modes:
- **reject** - stop work at the limit
- **alert** - warn but continue (default)
- **downgrade** - suggest cheaper approaches as you approach the limit

### Restrict tool access

```
/tool-guard profile readonly          # only Read, Grep, Glob allowed
/tool-guard profile careful           # everything gated
/tool-guard deny Bash                 # block shell access
/tool-guard gate Edit,Write           # approve each file mutation
```

### Audit agent behavior

```
/behavior-watch
```

Produces a session activity report with anomaly scoring - flags scope creep, unusual tool call frequencies, access to sensitive files, and suspicious sequences (e.g., read credentials then make a network call).

### Pre-execution safety

`pre-exec-check` activates automatically. When the agent is about to run something risky, it checks against known danger patterns and warns you:

```
⚠ This command `git push --force origin main` force-pushes to main,
  which overwrites remote history and affects all collaborators.
  Safer alternative: `git push --force-with-lease origin main`
  Proceed? (y/n)
```

This is behavioral guidance, not runtime interception - Claude consults the skill's rubric when it recognizes a potentially dangerous command. For hard enforcement (blocking commands at the shell level), see the roadmap below.

## What This Is (and Isn't)

**This is** behavioral guidance for your AI coding agent - instructions that teach it to check for threats and pause before dangerous operations. It works because modern agents (Claude, Codex, Gemini) follow well-structured instructions reliably.

**This is not** a runtime enforcement engine. It cannot *prevent* a determined attacker from bypassing it, just as a code review cannot prevent all bugs. It catches the common cases - the 36.82% - and makes you aware before damage is done.

## Built on Real Security Expertise

safe-agent isn't another weekend prompt engineering project. The threat patterns and detection heuristics come from:

- **[Flare](https://www.tryflare.ai/)** - AI-powered anomaly detection for cloud audit logs, where we built and battle-tested Claude-based security analysis that scores anomalies 0-100 with baseline tracking and false-positive filtering
- **[LOCO](https://github.com/ArielSmoliar/loco-agent)** - Load-aware scheduling for multi-agent systems, where we learned how agents compete for resources and where budget/authorization guardrails matter most

## Roadmap

**v0.2 - Cross-skill coordination**
- [ ] Unified policy engine - behavior-watch detection triggers tool-guard restrictions automatically
- [ ] Multi-command exfiltration detection - catch split `cat .env > /tmp/x && curl -d @/tmp/x` across separate commands
- [ ] Multi-agent propagation detection - detect when a compromised agent attempts to inject instructions into other agents' contexts (T7 coverage)
- [ ] Hook-based enforcement - Shell scripts + Claude Code hooks for hard blocking of dangerous commands (deterministic, not behavioral)

**v0.3 - Deeper coverage**
- [ ] MCP server audit - extend skill-verify to scan MCP server configurations for trust boundary violations
- [ ] Pre-exec-check user-intent awareness - distinguish "user asked for force-push" from "agent decided to force-push" (experimental - requires agent introspection)
- [ ] Resource exhaustion detection - catch infinite loops, memory bombs, bandwidth abuse within single commands
- [ ] Output/response tampering detection - detect if a malicious skill modifies tool output
- [ ] Supply chain integrity - hash pinning and provenance checking for installed skills, detect post-install modification

**v0.4 - Persistence and teams**
- [ ] Cross-session memory - track behavior baselines across sessions to detect drift over time
- [ ] Team profiles - shareable tool-guard presets for org-wide security policies

## License

MIT

## Contributing

Issues and PRs welcome. If you find a threat pattern we don't catch, open an issue - that's the most valuable contribution.
