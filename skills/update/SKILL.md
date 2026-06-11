---
name: update
description: Safely updates Claude Code by researching releases before installing. Checks changelog, release age, and community issues, then offers version choices. Use when the user wants to update Claude Code, check for new versions, or says "update", "upgrade", "new version".
user-invocable: true
host-only: true
allowed-tools: Bash, Read, WebFetch, WebSearch, AskUserQuestion, Skill
---

Research the latest Claude Code releases, assess their risk, snapshot the current binary as a safety net, and let the user choose which version to install. If the install breaks the binary, the user can revert in one command.

## Step 1: Get current version

```bash
claude --version
```

Parse the version number (e.g. `2.1.91` from `2.1.91 (Claude Code)`).

## Step 2: Detect install method

```bash
which claude 2>/dev/null || where claude 2>/dev/null
uname -s 2>/dev/null || echo "Windows"
```

Classify based on binary location and OS:
- Binary at `~/.local/bin/claude` or `~/.local/bin/claude.exe` → **native install**
- Binary in a path containing `node_modules` → **npm**
- Binary under a Homebrew prefix (e.g. `/opt/homebrew/`, `/usr/local/Cellar/`) → **brew**
- Otherwise → **unknown**

Combine with OS: `windows-native`, `macos-native`, `linux-native`, `npm`, `brew`, `unknown`.

**If method is NOT `windows-native`:** explain what was detected (install method, OS, binary path) and invoke `/create-skill` to extend this skill with update logic for that method:

```
/create-skill update Add an update code path for <detected-method> on <OS>. Binary is at <path>. The skill currently only handles windows-native. Add a conditional branch for this method. For reference — macOS/Linux native: `curl -fsSL https://claude.ai/install.sh | bash -s <VERSION>`, npm: `npm install -g @anthropic-ai/claude-code@<VERSION>`, brew: no version pinning. Test the new code path before finishing.
```

Then exit — do not continue with the steps below.

## Step 3: Get changelog and available versions

The local cache at `~/.claude/cache/changelog.md` only covers the installed version and older. Fetch the official changelog for newer versions:

```
WebFetch https://code.claude.com/docs/en/changelog
```

Parse version headers (e.g. `## 2.1.92`) and their changelogs. Build a list of versions newer than the current one, sorted newest first.

If the current version is already the latest, tell the user "You're up to date on vX.Y.Z" and exit.

## Step 4: Get publish dates from GitHub releases and cross-reference with changelog

```
WebFetch https://api.github.com/repos/anthropics/claude-code/releases?per_page=20
```

Match releases by tag name (e.g. `v2.1.92`) to get `published_at` timestamps.

Cross-reference: identify any GitHub releases that do **not** have a corresponding changelog entry. These are "undocumented" versions — flag them in the report (Step 7) and factor into recommendations.

## Step 5: Calculate release age and risk

For each version newer than current, compute age from `published_at`:

| Age | Risk | Label |
|-----|------|-------|
| < 48 hours | **HIGH** | "Very new — not enough community feedback yet" |
| 48h – 7 days | **MEDIUM** | "Recent — some feedback may exist" |
| > 7 days | **LOW** | "Established release" |

## Step 6: Check GitHub issues for problems

**Searching only for the version string is not enough** — runtime/Bun crashes often aren't tagged with the version number. You MUST run BOTH kinds of searches, in parallel:

**6a. Version-string search** (catches version-specific reports):

```
WebFetch https://api.github.com/search/issues?q=repo:anthropics/claude-code+<latest-version>+state:open&sort=reactions&order=desc&per_page=10
```

**6b. Symptom searches** (catches the broad pattern of runtime crashes). Run ALL of these in parallel:

```
WebFetch https://api.github.com/search/issues?q=repo:anthropics/claude-code+%22stack+overflow%22+state:open&sort=created&order=desc&per_page=10
WebFetch https://api.github.com/search/issues?q=repo:anthropics/claude-code+%22panic%22+Bun+state:open&sort=created&order=desc&per_page=10
WebFetch https://api.github.com/search/issues?q=repo:anthropics/claude-code+%22illegal+instruction%22+state:open&sort=created&order=desc&per_page=10
WebFetch https://api.github.com/search/issues?q=repo:anthropics/claude-code+segfault+state:open&sort=created&order=desc&per_page=10
WebFetch https://api.github.com/search/issues?q=repo:anthropics/claude-code+%22crashes+on+startup%22+state:open&sort=created&order=desc&per_page=10
```

**Hard-stop signals** — if ANY of the symptom searches return issues created in the last 7 days that describe:
- The binary crashing on `--version`, `--help`, or other trivial invocations
- "starts and exits in N seconds" patterns
- Bun panics / segfaults / illegal instructions on startup
- A bundled-runtime version (e.g. "Bun 1.3.14") appearing in multiple recent crash reports

…then the most recent Claude Code versions are likely affected by a bundled-runtime regression. Identify roughly when the crash pattern started (look at issue creation dates) and treat all versions from that point forward as **🔴 RUNTIME-RISK**. Do NOT recommend any of them. Flag them prominently in the report.

Also scan the top issues from 6a for trivial-invocation crash signals like "starts and exits in N seconds" — these are hard stops too, even if reaction counts look low.

## Step 7: Present findings

Display a clear report:

1. **Version summary:** current → latest, how many versions behind.

2. **Full per-version table.** **One row per version. Never collapse multiple versions into a single row, even for boring patches — the user wants to see every single version.** Columns: Version, Released, Age, Risk, Changes. Risk is 🟢 LOW / 🟡 MEDIUM / 🔴 HIGH / 🔴 RUNTIME-RISK / ⚠️ NO CHANGELOG. For the "Changes" column, list the actual changelog bullets compactly — don't summarize away the detail, and don't drop entries. If a version has no changelog entry, give it its own row with ⚠️ **NO CHANGELOG** and put it in approximate chronological position.

3. **Community reports:** number of open issues from the version-string search, plus a separate "Runtime/crash issues" section listing the recent symptom-search hits (title, number, date, reactions). If symptom searches found fresh hard-stop signals, lead with those — they override everything else.

4. **Undocumented versions:** if any GitHub releases lack a changelog entry, list them with a warning.

5. **Recommendation:** based on release age, issue count, changelog availability, AND the symptom-search results. Rules:
   - Never recommend a 🔴 RUNTIME-RISK version, regardless of age.
   - Never recommend a version with no published changelog.
   - If the latest is < 48h old with no track record, recommend the newest version that's > 7 days old instead.
   - If symptom searches show a recent crash pattern, recommend the newest version that pre-dates the crash pattern.

## Step 8: Ask user what to do

Use AskUserQuestion. Build the options dynamically:

- **"Update to vX.Y.Z (latest)"** — always present. Add risk label if HIGH or MEDIUM. If changelog is missing, add "⚠️ no changelog".
- **"Update to vA.B.C (newest with changelog)"** — present if the latest version lacks a changelog. This is the newest version that has a published changelog entry.
- For each intermediate version that is > 7 days old (LOW risk) and newer than current, add: **"Update to vA.B.C (X days old, low risk)"**
- **"Stay on vCurrent"** — always present as the last option.

Record the exact version number the user selects — it will be used in the install steps below.

If the user picks "Stay on vCurrent", exit — no further steps.

## Step 9: Snapshot current binary (REQUIRED safety net)

**Before** invoking any installer, snapshot the live Claude Code binary. This guarantees the user can revert if the installer leaves a broken binary in place (which has happened on real installs — see the Bun 1.3.14 regression of May 2026).

```bash
perl ~/.claude/ccpraxis/plugins/steward/scripts/claude-binary-backup.pl snapshot --reason "pre-install of v<SELECTED-VERSION>" --mark pre-install
```

Replace `<SELECTED-VERSION>` with the user's choice from Step 8.

**Check the exit code.** If it is non-zero, STOP — do NOT proceed to the installer. Surface the JSON error to the user. The snapshot must succeed; without it, a botched install has no revert path.

Then prune old snapshots so the backup dir doesn't grow without bound. The script keeps the 4 newest by default:

```bash
perl ~/.claude/ccpraxis/plugins/steward/scripts/claude-binary-backup.pl prune --keep 4
```

Surface the `snapshot.id` returned by Step 9 to the user — they may want to remember it.

## Step 10: Execute install

**IMPORTANT: Always install the exact version the user selected.** Do NOT use `claude update` — it fetches the absolute latest release, which may differ from what the user chose if a new version was published between research and execution.

Always use the version-pinned installer:

```bash
powershell -Command "& ([scriptblock]::Create((irm https://claude.ai/install.ps1))) <SELECTED-VERSION>"
```

Replace `<SELECTED-VERSION>` with the exact version number from Step 8 (e.g. `2.1.141`).

## Step 11: Verify install and offer revert if broken

Verify by running `claude --version` again. If `claude --version` succeeds AND the output matches the selected version: ✅ tell the user the install succeeded. Mention the pre-install snapshot id (from Step 9) so they know how to revert manually later if anything goes wrong.

If `claude --version` fails (non-zero exit, no output, crash, hang, or panic) OR the reported version doesn't match what was selected:

1. **The install is broken.** Surface the exact error to the user.
2. List available snapshots so the user can see what's there:
   ```bash
   perl ~/.claude/ccpraxis/plugins/steward/scripts/claude-binary-backup.pl list
   ```
3. Offer to revert to the pre-install snapshot. Use AskUserQuestion with two options:
   - **"Revert to pre-install snapshot (Recommended)"** — runs the restore command below.
   - **"Leave broken install in place"** — do nothing; user will fix manually.
4. If user picks revert, run:
   ```bash
   perl ~/.claude/ccpraxis/plugins/steward/scripts/claude-binary-backup.pl restore --latest
   ```
   Then verify `claude --version` works again. Tell the user to restart Claude Code.

In all success cases, tell the user to restart Claude Code for the new version to take effect.

## Manual revert (any time, outside this skill)

Even outside `/update`, the user can revert at any time:

```bash
# List available snapshots:
perl ~/.claude/ccpraxis/plugins/steward/scripts/claude-binary-backup.pl list

# Revert to the most recent snapshot:
perl ~/.claude/ccpraxis/plugins/steward/scripts/claude-binary-backup.pl restore --latest

# Revert to a specific snapshot by id:
perl ~/.claude/ccpraxis/plugins/steward/scripts/claude-binary-backup.pl restore --snapshot <id>
```

Snapshots live under `~/.claude/backups/claude-code/`. The script keeps the 4 newest by default and takes a fresh "pre-restore" snapshot before any restore op, so restores are themselves reversible.
