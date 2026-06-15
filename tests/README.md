# Test Fixtures

Test skills for validating `/skill-verify` detection accuracy.

## Fixtures

| Fixture | Expected Verdict | Expected Findings |
|---|---|---|
| `safe-skill/` | SAFE (score 0-10) | No issues |
| `malicious-exfiltration/` | DANGEROUS (score 85+) | CRITICAL: SSH key read + base64 encode, CRITICAL: .env file collection + curl to external URL, HIGH: excessive allowed-tools for a "formatter" |
| `malicious-injection/` | DANGEROUS (score 90+) | CRITICAL: HTML comment prompt injection ("admin mode"), CRITICAL: base64-encoded eval payload, CRITICAL: credential file reads (.aws, .ssh, .netrc), HIGH: persistence attempt (~/.local/bin), HIGH: hidden zero-width character instructions, MEDIUM: excessive allowed-tools |
| `malicious-credential-harvest/` | DANGEROUS (score 85+) | CRITICAL: reads credentials from AWS/GCP/Azure/SSH, CRITICAL: writes creds to world-readable /tmp file, CRITICAL: background exfiltration loop via nohup + curl, HIGH: excessive allowed-tools for a "deploy helper" |
| `vulnerable-untrusted-input/` | CAUTION (score ~50) | HIGH: indirect prompt injection (item 14) — fetched web content treated as authoritative and its referenced files read, no `<untrusted_data>` isolation, paired with Edit. Items 1-7 stay clean (honest discriminator) |
| `vulnerable-mcp-config/` | DANGEROUS (score ~80) | item 13 MCP audit fires on all three servers: root-`/` filesystem server, shell server, remote SSE server handed AWS/GitHub secrets via env. A "table formatter" granting this is egregious scope mismatch; skill prose itself is clean |

## Running Tests

```
/safe-agent:skill-verify tests/fixtures/safe-skill
/safe-agent:skill-verify tests/fixtures/malicious-exfiltration
/safe-agent:skill-verify tests/fixtures/malicious-injection
/safe-agent:skill-verify tests/fixtures/malicious-credential-harvest
/safe-agent:skill-verify tests/fixtures/vulnerable-untrusted-input
/safe-agent:skill-verify tests/fixtures/vulnerable-mcp-config
```

Each result should be compared against the expected verdicts and findings above.

For end-to-end verification of v0.3 enforcement (requires a restarted session and
wired hooks), see `manual-checklist.md`.
