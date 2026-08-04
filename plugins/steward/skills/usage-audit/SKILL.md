---
name: usage-audit
description: Measures real Claude Code token consumption across every transcript on this machine — host plus every per-project sandbox home, including nested subagent transcripts — then splits it into interactive vs headless-fleet spend and prices it against Anthropic list rates, Z.ai GLM credit plans, DeepSeek pay-per-token, and Kimi request metering. Writes a dated report into the vault. Use when the user asks how much they are actually spending or consuming, whether a cheaper provider or smaller plan would fit, whether to offload butler/fleet work elsewhere, or says "usage audit", "crunch the usage numbers", "how many tokens am I using", "would plan X be enough".
user-invocable: true
host-only: true
allowed-tools: Bash, Read, AskUserQuestion
---

# /steward:usage-audit

Answers "what am I actually consuming, and would provider X or plan Y cover it?" from measured
data rather than estimates. All arithmetic lives in `scripts/usage-audit.pl`; this skill runs it
and interprets the result.

## Why the script exists rather than doing this inline

Three details make a hand-rolled scan wrong by roughly 7x, and all three are easy to miss:

1. **Sandbox sessions don't write to `~/.claude`.** Each sandboxed project has its own home at
   `<project>/.ccpraxis-local-data/claude-home/projects/`, bound to `/root/.claude` in the
   container. Those roots must be discovered.
2. **Subagent transcripts nest one level deeper**, at
   `<project>/<session-uuid>/subagents/agent-*.jsonl`. A one-level glob silently drops every
   subagent — on this machine that was 123 of 156 host files.
3. **Records repeat.** Resumed sessions and backup copies duplicate usage records, so
   deduplication by `requestId` is required before any total means anything.

## Run it

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/usage-audit.pl"
```

Takes several minutes — it parses every transcript line on the machine. It prints a short summary
and writes the full Markdown report to
`~/.claude/claude-code-vault/reports/usage/<ISO-date>.md`.

Useful flags:

| Flag | Effect |
|---|---|
| `--list-roots` | Print discovered transcript roots and exit. Run this first if coverage looks wrong. |
| `--weeks N` | Restrict the tables to the last N weeks. |
| `--no-vault` | Print the report to stdout; write nothing. |
| `--out PATH` | Write somewhere other than the vault. |
| `--root DIR` | Use an explicit projects-root (repeatable); skips discovery entirely. |
| `--scan-root DIR` | Add a directory to the discovery scan (repeatable). |
| `--rates PATH` | Use a different rate card. |

## Read the output with these in mind

- **Interactive vs headless is the load-bearing split.** It comes from each record's `entrypoint`
  field: `sdk-cli` means an orchestrator spawned the session (the butler fleet), `cli` means a real
  terminal. Use it to answer "what would I still consume if the fleet ran elsewhere?"
- **Coordinators dominate, not workers.** Headless main sessions carry roughly 3x the context per
  request that subagent workers do. Any "move the workers off Claude" plan should be checked
  against the `HEADLESS/main` vs `HEADLESS/sub` rows before it's costed — the two differ by a lot.
- **Cache read is normally 60–70% of cost and output under 20%.** If someone proposes saving money
  by cutting thinking tokens, the output row is the hard ceiling on that idea. The real levers are
  context size and cache-miss rate.
- **A high cache-write share means cache misses.** Every resume after a gap longer than the cache
  lifetime reprocesses the whole context at 1.25x input rate. Above ~15% is worth investigating.
- **The 5-hour rolling peak is usually the binding constraint**, not the weekly total — plan caps
  bite there first. The report gives peak windows in both credits and raw request count, because
  Z.ai meters tokens and Kimi meters requests.
- **The current week is labelled `(partial)`.** Don't average it in.

## Maintaining the rate card

Provider pricing moves. Rates live in `scripts/usage-audit-rates.json`, separate from the logic,
with a `rates_verified` date and a `_source` URL per provider. Before presenting numbers that
someone will spend money on, check whether `rates_verified` is stale; if it is, fetch each
`_source`, update the file, and bump the date. Adding a model is a JSON edit, not a code change.

## Caveats worth repeating to the user

- **Transcripts are deleted on a 30-day rolling window** by Claude Code's `cleanupPeriodDays`
  (default 30). Weeks older than that are already partial and understate. If a usage baseline
  matters, snapshot the JSONL files or raise the setting — this data is not recoverable later.
- **There is no API alternative.** Anthropic's Admin API usage and cost endpoints are unavailable
  to individual accounts and cover only organization API-key usage, never Pro/Max subscription
  usage. Local transcripts are the only complete source.
- **Cross-provider figures assume the measured cache hit rate carries over.** DeepSeek's cache-miss
  price is 50–120x its cache-hit price, so a provider whose caching behaves differently changes the
  answer by more than an order of magnitude. Say so whenever quoting those numbers.
- **Anthropic list rates price notional API value**, not what a subscription actually charges. Use
  them to compare components against each other, not to predict a bill.
