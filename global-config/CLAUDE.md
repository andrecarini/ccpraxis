# Global Instructions

## Work Quality & Thoroughness

Work like a careful, experienced senior developer. Prioritize correctness and completeness over speed or brevity — conciseness applies to your communication style, not to implementation depth or analysis rigor. Before starting work, make sure you fully understand what is being asked; when requirements are ambiguous or underspecified, ask clarifying questions rather than making assumptions and jumping straight in. Be vigilant about your tendency to hallucinate facts, APIs, function signatures, and file paths — always verify claims against actual code and documentation before stating them, and provide sources when answering factual questions. When fixing a bug or implementing a feature, proactively identify and fix adjacent problems you encounter (broken code, incorrect error handling, missing edge cases) even if they were not explicitly part of the task. Use professional judgment about error handling, abstractions, and code structure — add error handling at real system boundaries, extract helpers when it genuinely reduces maintenance burden, and always consider edge cases. Do not sacrifice thoroughness of your work for the sake of shorter responses.

## Response Style
- Every message must start with 🤖

## Skill Self-Invocation

A skill's `description:` is a trigger contract, not just discovery metadata. When a description says **"Use proactively when…"** and the current turn matches the condition, invoke the skill yourself — don't wait for the user to type `/name`. Treat **"Skip for…"** and **"ALWAYS confirm…"** clauses as binding parts of the same contract. The descriptions re-evaluate every turn, so a skill that wasn't right at turn 3 may be right at turn 12.

Specifically for the beacon system:
- **`/beacon:on`** — light proactively when the session has substantive ongoing work: a plan, multi-file edits, or a multi-step task. Skip for one-off questions, trivial lookups, or single-file quick fixes. Idempotent — re-invoking just refreshes the activity timestamp.
- **`/beacon:off`** — offer when the user signals the session's work is finished ("done", "shipped", "merged", "deployed", "landed", "committed", "PR opened", "let's call it", "wrapping up", "ship it", "lgtm", "all good", "looks good", "finished", "we're good", "that's it for today"). Skip when the signal is scoped to a sub-task ("done with X, now Y"), to thinking/reading ("done reading"), or when substantive work is clearly still in progress. When invoking proactively, ALWAYS ask first via `AskUserQuestion` BEFORE invoking the skill. A direct user invocation (the user typed `/beacon:off`) needs no confirmation — the slash command is the consent.

## House rules learned across projects

Recurring preferences that surfaced in multiple project memories — promoted here so they apply everywhere, not just where they were first observed.

- **No python/pip on the host — use perl.** Python is not installed on this Windows host. For ad-hoc scripting (parsing JSON/HAR, file munging, one-off transformations) reach for `perl` (Git-for-Windows ships it; `JSON::PP` is core) instead of `python`/`python3`/`pip`. Reserve Bash for actual shell operations. (`pip install` is also a host-side dev-tooling install — see the section below.)
- **Never add `Co-Authored-By` to commits.** Do not append `Co-Authored-By: Claude ...` (or any co-author trailer) to git commit messages. The user does not want Claude credited in the git history.
- **Don't chain `cd` in git/shell commands.** Never write `cd /path && git ...` — chaining forces a fresh approval prompt every time. Run commands from the working directory directly; if a different directory is genuinely needed, `cd` once in its own call, then run subsequent commands separately.
- **Delegate heavy mechanical work to cheaper-model subagents.** When a task will burn lots of tokens in the main context (large WebFetches, full-site mirrors, reading big downloaded files, long-output commands, batch reconnaissance), spawn a subagent overridden to a cheaper, faster model rather than running it inline on the session's large model. Only the subagent's summary returns, so the heavy raw content never lands in the expensive context. Keep synthesis, judgement, edits, and final go/no-go calls on the large model; don't subagent trivial work (the overhead beats the saving).
- **Never conclude a file/dir is missing from a Glob-tool miss alone.** The Glob tool intermittently returns "no files found" for directories that actually exist when their path contains `é` (e.g. `C:\Users\André\...`) — observed repeatedly. Before acting on a path's absence, confirm with Bash `ls` or Grep. A Glob miss under an `é`-path is not proof of absence.
- **Dependency & runtime versions are a deliberate choice.** Default to the latest LTS/stable of every runtime, tool, and library; never a random pin and never an **EOL** version (e.g. Node 20 is EOL). Not bleeding-edge either — the selected version must be **≥7 days old** (supply-chain safety + maturity) and mutually compatible with the rest of the stack and the task. Reviewed, not improvised.

## ⚠️⚠️⚠️ NEVER RUN DEV TOOLING ON THE HOST ⚠️⚠️⚠️

🚨🚨🚨 **CRITICAL SECURITY RULE** 🚨🚨🚨

**NEVER install or run development tooling, SDKs, package managers, or dependencies directly on the host machine.**

This includes but is not limited to:
- ❌ `npm install`, `npm ci`, `npx`
- ❌ `dart`, `flutter`, `pub get`
- ❌ `pip install`, `python`, `cargo`, `go build`
- ❌ `firebase`, `gcloud`, `terraform`
- ❌ ANY build tool, linter, formatter, or compiler

⚠️ **Supply chain attacks in development dependencies are rampant.** Malicious packages can execute arbitrary code during install (npm postinstall hooks, pip setup.py, etc.) and compromise the entire host machine — steal credentials, SSH keys, browser sessions, cryptocurrency wallets, and more.

⚠️ If the user asks you to run a dev tool directly, **warn them about the risks** (supply chain attacks, arbitrary code execution during install) and **ask for explicit confirmation** before proceeding. Do not silently comply, but do not hard-block either — the user has the final say.

🐳 If a project needs dev tooling, **offer to set up a sandbox**: tell the user to exit Claude and run `claude-sandbox` in this project. The launcher detects no sandbox is configured and walks them through bootstrap interactively (image build, git auth, PATH wiring). Do not run it automatically — let the user decide.

## ⚠️ `NUL` is a Windows device name — never redirect to it from Bash

From Bash, redirecting to `NUL` creates a literal file of that name which Explorer cannot delete. Use `/dev/null` from Bash and `$null` from PowerShell.

**This is hook-enforced** — `~/.claude/ccpraxis/scripts/hooks/block-nul-redirect.pl` denies the Bash call before it runs, in every project on this machine, so the mistake is not available to make. Kept as one line only because the *right* form is worth knowing; the rule itself needs no teaching. If a stray `NUL` file already exists, remove it from Bash (`rm -- NUL`) — PowerShell resolves the device name instead of the file.

## ⚠️ Write `.ps1` files as ASCII only

The Write tool saves UTF-8 without a BOM; PowerShell 5.1 reads a BOM-less script as CP1252. A multi-byte character like `—` or `→` decodes into stray bytes — one of them (0x94) is a smart quote, which PowerShell treats as a **string delimiter**. That opens a phantom string, swallows the following braces, and reports `Missing closing '}'` at a line far from the real problem.

Use `--` and `->`. If non-ASCII is genuinely required, prepend a UTF-8 BOM. Check with `perl -nle 'print "L$.: $_" if /[^\x00-\x7f]/' file.ps1` — no output means clean. `.sh` files are unaffected; Git Bash handles UTF-8 fine.

## ⚠️ Path-scoped `Bash(...)` permissions do not work in skill frontmatter

`permissions.allow` entries like `Bash(perl ~/.claude/scripts/*)` match correctly in `settings.json`, but silently fail to match when written into a skill's `allowed-tools:` frontmatter — only the broadest form (`Bash(perl *)`) takes effect there, which is too permissive to want. To pre-approve a specific command a skill invokes, add it to `settings.json` (use the `update-config` skill) and leave the frontmatter as bare `Bash, Read, Write, …`.

## ⚠️ MSYS2 path-conversion mangles `:`-separated args (Git-for-Windows perl + podman)

When Git-for-Windows perl (or any MSYS2-based tool) spawns a **native Windows** binary, MSYS2 silently translates argv elements that look like POSIX paths into Windows paths. For arguments that **contain a colon**, MSYS2 treats them as `:`-separated PATH-style lists, converts each piece independently, and **re-joins them with `;`** (Windows's PATH separator). This silently corrupts:

- `podman run -v HOST:CONTAINER` and `podman create -v HOST:CONTAINER` — mount specs become `C:\host\path;C:\fake\container\path`. Podman then bind-mounts a non-existent path that auto-creates a `;C`-suffixed directory on the host. Mounts silently fail.
- Any `-v`-style flag passed to a native Windows binary from Git-Bash perl.
- Container `--env` values like `FOO=/a/b:/c/d` (any value containing `:`).

**Symptom to look for:** stray directories on disk with names ending in `;C` (e.g. `.claude.json;C`, `.launcher;C`). They appear next to the file the launcher was trying to mount, and the in-container side of the mount comes up empty or wrong (onboarding screens, missing CLAUDE.md, etc.).

**The opposite symptom — a POSIX path reaching a native binary UNCONVERTED:** directories mirroring
POSIX paths at the **drive root**, i.e. `C:\c\Users\...` or `C:\tmp\...`. Windows resolves a leading
`/` against the current drive, so a native binary handed `/c/Users/Public/x` silently creates
`C:\c\Users\Public\x`. This is what over-applying the prevention below causes, and it is as real as
the `;C` bug: on 2026-06-12 it left 576 entries at this machine's drive root, including a working
bare git repo under `C:\c\Users\Public\`.

**Deterministic prevention** (in priority order):

1. **In every perl script that spawns native Windows commands**, set `$ENV{MSYS2_ARG_CONV_EXCL} = '*' if $^O =~ /^(MSWin32|cygwin|msys)$/;` near the top. This disables path translation for the whole process tree. `podman.exe` accepts forward-slash Windows paths (`C:/Users/...`) directly, so nothing downstream needs the MSYS2 layer — we hand-translate POSIX-style host paths to that form ourselves via `winify_path` in the launcher.
2. **For one-off invocations**, scope it: `local $ENV{MSYS2_ARG_CONV_EXCL} = '*'; system(...);`.
3. **⚠️ Do NOT set `MSYS2_ARG_CONV_EXCL=*` shell-wide** — not in PowerShell `$PROFILE`, not in `.bashrc`, not in the Windows user environment.

   This file previously recommended exactly that, as a "belt-and-suspenders safety net" that would "catch third-party scripts that didn't know to set it themselves". **That rationale is backwards.** A script that doesn't know to disable conversion is also a script that doesn't hand-translate its own paths — so it *depends* on the conversion. Disabling it globally does not protect such a script; it is precisely what breaks it. Rules 1 and 2 are safe only because a script that opts out also translates its own paths (`winify_path`, `git_path`). The opt-out and the translation are one technique, and splitting them is the bug.

   Measured on this machine, not hypothetical: with the variable set shell-wide, ccpraxis's own steward suite hands native `git.exe` a POSIX `/c/...` path, which Windows resolves against the current drive. On 2026-06-12 that left 576 entries at the drive root (`C:\c\`, `C:\tmp\`) including a real bare git repo. `plugins/steward/tests/t/09-no-drive-root-strays.t` now runs the vault flow with the variable deliberately set and fails if anything appears at the drive root.

**When NOT to disable conversion:** if a script genuinely needs MSYS2 to translate a POSIX path to a Windows path before passing it to a native command (e.g. piping `find` output to `notepad.exe`), do that translation explicitly with `cygpath -w` or perl logic — don't rely on the implicit MSYS2 magic, because the same magic is what creates the `;C` corruption bug elsewhere.

**Existing ccpraxis files that already have the guard:** `plugins/sandbox/scripts/launcher.pl`, `plugins/sandbox/scripts/bootstrap.pl` (opt out + hand-translate via `winify_path`). Any new perl script under ccpraxis that calls podman or another native Windows binary with multi-path or `-v`-style args must do the same.

**The complementary technique — translate, and stop caring about the variable.** `plugins/steward/scripts/vault-sync.pl`'s `git_path()` rewrites `/c/...` → `C:/...` before every git call. `git.exe` and `podman.exe` both accept that form whether or not MSYS later rewrites it, so the script is correct under *either* conversion state instead of depending on one. Prefer this when you can: it cannot be broken by a caller's environment. Where a harness must control the environment instead, scrub the variable for the child rather than the whole session — see `plugins/steward/tests/lib/StewardTest.pm`'s `_msys_convert_on`.

## ⚠️ Modifying the Windows User PATH

The user's Windows PATH and other registry env vars contain paths with non-ASCII characters (e.g. `C:\Users\André\...`). Mishandling Unicode when reading/writing those vars via PowerShell from perl will scramble every existing entry — a system-breaking class of bug that previously hit this machine and took manual fix-up to recover.

Use the existing helper at `~/.claude/ccpraxis/scripts/_install-bin-helper.pl` (invoked via per-surface `ccpraxis-install.pl` hooks). Do NOT roll your own PATH-modifying code unless absolutely necessary.

If you must write new code that reads/writes Windows registry env vars:
- Round-trip values as opaque **UTF-8 bytes** through base64. PowerShell read: `[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($v))`. PowerShell write: `[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64'))` → `SetEnvironmentVariable`. Perl side: keep as raw UTF-8 bytes; **never call `Encode::encode` on values you received from `decode_base64`** — those are already UTF-8, and re-encoding treats each byte as Latin-1 and produces `Ã©` instead of `é`, accumulating corruption on each run.
- **Round-trip-test on a throwaway variable** (e.g. `CCPRAXIS_ENC_TEST`) containing `André` BEFORE touching PATH/PATHEXT. Verify byte-perfect read-back. Only then operate on the real var.
- **Snapshot the current PATH to a file** before modifying (e.g. `~/.claude/.path-snapshots/<timestamp>.txt`), so the user can restore manually if anything goes wrong.
