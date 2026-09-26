# ai-disclosure-crosscheck

A read-only, cross-repo linter that checks whether a server-side call to an
external AI API (OpenAI, Anthropic, Gemini, Mistral, and others) is actually
disclosed to the user — either in the client app's UI or in the public
privacy policy — before you submit to app review.

## The gap this tool closes

Most App Store pre-submission scanners are **single-repo, client-only**
tools: they scan an iOS/Android client's source for AI SDK usage and check
whether the client itself surfaces a disclosure string. That works when the
AI call is made directly from the client.

It stops working the moment the AI call moves to your **backend**. A very
common architecture sends user input to your own server, which then calls
OpenAI/Anthropic/etc. on the client's behalf. A client-only scanner never
sees that server-side call — there is nothing to find in the client repo —
so it reports a clean pass while the app may still be undisclosed AI
processing under App Store Review Guideline 5.1.1 / 5.1.2(i).

This tool was built after confirming that gap on a real project: a
client-only scanner passed cleanly on the client repo while the server repo
made an undisclosed call to an external AI API. That is the specific
failure mode this tool exists to catch — it is not a hypothetical.

`ai-disclosure-crosscheck` closes the gap by taking **three inputs** instead
of one:

| Signal | What it looks at | Source |
|---|---|---|
| A — server AI call | Does the server code call a known AI provider's SDK or endpoint? | `--server-dir` |
| B — client disclosure | Does any client-facing string name that provider? | `--client-dir` |
| C — policy disclosure | Does the public privacy policy name that provider in the same sentence/block as an AI/machine-learning keyword? | `--policy-file` (optional) |

It then reconciles the three into a single verdict per the matrix below.

## Verdict matrix

| Server call (A) | Client discloses (B) | Policy discloses (C) | Verdict |
|---|---|---|---|
| no | – | – | (no finding — rule doesn't fire) |
| yes | yes | – | **PASS** |
| yes | no | yes | **WARN** — policy-only disclosure; Apple's 2026 review practice may treat this as insufficient without an in-app consent screen |
| yes | no | no (policy file given) | **FAIL** — no consent surface names the provider anywhere |
| yes | no | not checked (no `--policy-file`) | **WARN** — inconclusive, re-run with `--policy-file` |

## Install

```bash
npx ai-disclosure-crosscheck --client-dir <path> --server-dir <path> --policy-file <path>
```

Requires `bash`, `grep`, and `find` on `PATH`. No credentials, no network
access, no telemetry — everything runs locally against your own source
trees.

## Usage

```bash
ai-disclosure-crosscheck \
  --client-dir  ./ios/App \
  --server-dir  ./backend \
  --policy-file ./legal/privacy-policy.html \
  [--format text|json] \
  [--fail-on warn|fail] \
  [--config .ai-disclosure-crosscheck.json]
```

Example (WARN case — server calls OpenAI, policy discloses it, but no
client string names the provider):

```
WARN: cross-repo-ai-consent-mismatch — OpenAI endpoint/SDK present in --server-dir
(backend/client.js); the public policy document discloses OpenAI, but no
client-facing string under --client-dir names the provider. Apple 5.1.1/5.1.2(i)
2026 review practice may treat policy-only disclosure as insufficient without
an in-app consent screen naming the provider.
      policy evidence: legal/privacy-policy.html:2
      server evidence: backend/client.js
SUMMARY: fail=0 warn=1 pass=0 suppressed=0
```

`--format json` emits a structured envelope instead:

```json
{
  "tool": "ai-disclosure-crosscheck",
  "version": "0.1.0",
  "findings": [{
    "rule_id": "cross-repo-ai-consent-mismatch",
    "severity": "warn",
    "guideline": "5.1.1 / 5.1.2(i)",
    "provider": "OpenAI",
    "evidence": {
      "server_ai_call": {"file": "backend/client.js", "line": null},
      "client_ui_disclosure": null,
      "policy_disclosure": {"file": "legal/privacy-policy.html", "line": 2}
    },
    "suppressed": false
  }],
  "verdict": "WARN",
  "summary": {"fail": 0, "warn": 1, "pass": 0, "suppressed": 0}
}
```

### Options

| Flag | Meaning |
|---|---|
| `--client-dir <path>` | Client/UI source directory (required, or via `--config`) |
| `--server-dir <path>` | Server source directory to scan for AI API calls (required, or via `--config`) |
| `--policy-file <path>` | Public privacy-policy document (HTML or Markdown), optional but strongly recommended |
| `--format <fmt>` | `text` (default) or `json` |
| `--fail-on <level>` | `warn` or `fail` (default `fail`) — exit code 1 at or past this severity |
| `--config <path>` | Path to a `.ai-disclosure-crosscheck.json` (auto-detected in cwd if present) |

`--config` example (`.ai-disclosure-crosscheck.json`):

```json
{
  "clientDir": "ios/App",
  "serverDir": "backend",
  "policyFile": "legal/privacy-policy.html"
}
```

CLI flags always win over the config file; the config only fills in values
the CLI omitted. This is meant for CI, so you don't have to repeat the same
three paths on every run.

### Suppressing a finding

A `.precheck-ignore` file in the working directory supports:

```
# comment
cross-repo-ai-consent-mismatch                 # suppress the rule everywhere
cross-repo-ai-consent-mismatch  path/glob/**    # suppress only under this path
path/glob/**                                    # exclude this path from scanning entirely
```

### Exit codes

`0` ok · `1` verdict at or past `--fail-on` · `64` bad usage · `70` environment
error (bash or the bundled scanner missing).

## Supported providers

Detection is signature-based (SDK import specifier or API host), defined in
[`scripts/lib/providers.conf`](scripts/lib/providers.conf): OpenAI,
Anthropic, Gemini, Mistral, OpenRouter, Groq, Perplexity, Together. Adding a
provider is a one-line, tab-separated addition to that file — no changes to
`scan.sh` required. Pull requests for additional providers welcome.

Current scope is Node.js/JavaScript/TypeScript server code (`require()` /
`import` specifiers and endpoint literals). Contributions extending
server-side detection to other languages/runtimes are welcome — see
`scripts/lib/prune.sh` for the include-filter pattern to extend.

## Design notes

- **No dependencies beyond bash/grep/find.** No `jq`, no `python3`, no
  Node.js required to run the core scan (`bin/cli.js` is only a thin `npx`
  convenience wrapper; you can call `scripts/scan.sh` directly).
- **Read-only.** The tool never modifies your source, makes no network
  calls, and sends nothing anywhere.
- **Single responsibility.** This tool answers one question — is the AI
  provider disclosed *somewhere* for a server-side call it found — and
  leaves broader App Store review linting to other tools. It is designed to
  run alongside a client-only scanner, not replace one.

## Testing

```bash
npm test
```

29 black-box tests cover argument parsing, config-file merging, the PASS/
WARN/FAIL matrix across all signal combinations, `.precheck-ignore`
suppression, and the CLI wrapper's exit-code propagation.

## License

MIT — see [LICENSE](LICENSE).
