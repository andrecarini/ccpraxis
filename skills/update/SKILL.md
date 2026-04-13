---
name: update
description: Safely update Claude Code — checks changelog, release age, community issues, then offers version choices
user-invocable: true
host-only: true
allowed-tools: Bash, Read, WebFetch, WebSearch, AskUserQuestion, Skill
---

Research the latest Claude Code releases, assess their risk, and let the user choose which version to install.

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

Search for open issues mentioning the latest version:

```
WebFetch https://api.github.com/search/issues?q=repo:anthropics/claude-code+<latest-version>+state:open&sort=reactions&order=desc&per_page=10
```

Count open issues, note the top ones by reaction count.

## Step 7: Present findings

Display a clear report:

1. **Version summary:** current → latest, how many versions behind
2. **For each newer version** (most recent first):
   - Version number, release age, risk level
   - Changelog highlights (summarize key additions, fixes, and any breaking changes — don't dump the raw list)
3. **Community reports:** number of open GitHub issues for the latest version, top issue titles and reaction counts. If zero issues, say so — that's a good sign.
4. **Undocumented versions:** if any newer GitHub releases lack a changelog entry, list them with a warning that their changes are unknown.
5. **Recommendation:** based on release age, issue count, and changelog availability. Never recommend a version that has no published changelog — prefer the newest version that has one. If the latest is < 48h old with no track record, recommend the newest version that's > 7 days old instead.

## Step 8: Ask user what to do

Use AskUserQuestion. Build the options dynamically:

- **"Update to vX.Y.Z (latest)"** — always present. Add risk label if HIGH or MEDIUM. If changelog is missing, add "⚠️ no changelog".
- **"Update to vA.B.C (newest with changelog)"** — present if the latest version lacks a changelog. This is the newest version that has a published changelog entry.
- For each intermediate version that is > 7 days old (LOW risk) and newer than current, add: **"Update to vA.B.C (X days old, low risk)"**
- **"Stay on vCurrent"** — always present as the last option.

Record the exact version number the user selects — it will be used in Step 9.

## Step 9: Execute update

**IMPORTANT: Always install the exact version the user selected.** Do NOT use `claude update` — it fetches the absolute latest release, which may differ from what the user chose if a new version was published between research and execution.

Always use the version-pinned installer:

```bash
powershell -Command "& ([scriptblock]::Create((irm https://claude.ai/install.ps1))) <VERSION>"
```

Replace `<VERSION>` with the exact version number the user selected in Step 8 (e.g. `2.1.101`).

After the command completes, verify by running `claude --version` again and confirm the installed version matches the selected version. If it doesn't, warn the user.

Tell the user to restart Claude Code for the new version to take effect.
