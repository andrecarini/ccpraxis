# ccpraxis design conventions and host landmines

Doctrine and hard-won facts for working on ccpraxis. Read when making a design call
(packaging, approval flows, enforcement) or when hitting a Windows/Perl oddity that smells
environmental. `CLAUDE.md` carries only what every session needs; this is the rest.

Recovered from 20 entries in Claude Code's built-in per-project memory before that feature
was disabled machine-wide (2026-08-13).

**Working conventions:**
- Commit/push directly to `main` for André's own solo work here — branches/PRs are only for
  eventual external contributors. A `Bypassed rule violations` notice on push is expected (admin
  bypass) and not a problem to flag.
- Gate support/compatibility claims on what's been **explicitly confirmed working**, not the bare
  technical minimum that "might work."
- On open design decisions (naming, architecture, packaging boundaries), discuss conversationally
  in prose with 2-3 grounded options and a recommendation. Reserve `AskUserQuestion` for choices
  the user has already framed as binary/finite.
- Mechanical constraints ("sandbox-only", "never edit from host") must be enforced by actual code
  (a bash/perl guard at the top of the script) — CLAUDE.md prose can reinforce but is never the
  gate.
- Plan deliverables only if their outcome changes what ships in *this* repo; drop probes whose
  value is purely informational or accrues to an upstream/other party.
- When a system would auto-record an implicit signal (e.g. "agent ran an install"), prefer
  detect-and-propose (surface a pre-filled action, let the next turn decide) over auto-write —
  provided a missed detection is cheap to retry. See `plugins/backpack`'s auto-declare hook.
- Repeated-approval flows (e.g. backpack items that run as root): persist per-item decisions keyed
  by identity + content-hash so unchanged items are never re-asked; show all items but require a
  decision only on pending/changed ones; surface the actual decision-relevant detail (verify
  command + rationale), not just a name.
- A tool with 2+ distinct operations → package as a plugin with one skill/slash-command per verb,
  not one skill parsing subcommand args. New domain-*maintenance* verbs fold into the plugin that
  already owns that domain (e.g. steward) rather than spawning a new plugin. Prefer long
  self-documenting slash-command names over coined jargon.
- After landing a non-trivial or file-mutating deliverable, consider a "red team" pass: a
  `feature-dev:code-reviewer` (or `bp-redteam`) subagent scoped to edge cases, robustness, data
  corruption, idempotency, and concurrency, then triage and fix high-priority findings.
- Any TUI/CLI that displays untrusted content as part of a human approval/review decision must
  strip C0 control/escape chars before display (and reject them at validation) — a raw ANSI
  escape in a hostile field can redraw the screen and spoof what's being approved.
- Skills wrapping a destructive/irreversible action (delete/remove/push/send): put the
  confirmation requirement in the skill's `description:` ("ALWAYS confirm via AskUserQuestion when
  invoked proactively"). The skill body itself runs directly — a typed slash command IS the
  user's consent, so don't also gate the body on a confirmation prompt.

**Windows/Perl landmines (beyond the ones already listed above):**
- Claude Code hook registration on Windows: use **shell form** (`"command": "perl \"path\""`), not
  exec form (`command` + `args`) — libuv's `uv_spawn` doesn't enumerate `PATHEXT` on Windows, so a
  bare `perl`/`node` in exec form fails ENOENT even though it's on PATH.
- perl `chdir` into a non-ASCII path (`C:/Users/André/...`) followed by `exec` is unreliable when
  the parent perl was launched from PowerShell (works fine from Git Bash). Delegate to PowerShell
  instead: `exec 'powershell.exe','-NoProfile','-Command',"Set-Location -LiteralPath '<path>'; & <cmd>"`.
- The Edit/Write tools normalize a literal `\uXXXX` token in the text you send into its actual
  character (and can inject a raw ESC/control byte). To put a literal backslash-u escape into
  source, build it at runtime instead of typing the token (Perl: `chr(92)."u001b"`), and
  byte-verify afterward.
- Native Windows OpenSSH (`ssh`/`ssh-keygen` under `System32\OpenSSH`) leaves the console in
  raw/VT mode on exit, so the next perl `<STDIN>` read in the parent hangs on Enter. Detach the
  child's stdin from the console (reopen fd 0 to `/dev/null` around the `system()` call) before
  running it.
- Windows directory rename/move `EACCES`: check, in order, a stopped-but-not-removed podman
  container (`podman rm -f` it), orphaned Claude Code host processes, the WSL2/podman VM, open
  Explorer windows, and editors/IDEs with the folder open (a recursive file-watcher, e.g. Sublime
  Text, was the actual culprit once). Windows Restart Manager (`rstrtmgr.dll`) finds file-level
  locks but not directory-handle-only holders.

**Repo facts:**
- Root `.gitattributes` forces LF for `*.sh/.pl/.pm/.t/.ps1`/`Containerfile` — load-bearing, do not
  remove. A `git checkout`/`merge` round-trip on this host once re-smudged the working tree to
  CRLF and broke every sandbox bash hook (`$'\r': command not found`). Recovery: find offenders
  with `git ls-files --eol | grep 'w/crlf'` (git-authoritative), delete + recreate those
  working-tree files, then `git checkout-index -f -a`.
- `butler:bp-scout` and `butler:bp-reviewer` subagents have repeatedly returned truncated (report
  file never written) during long, tool-heavy `drive-solo` runs. For their scouting/review steps,
  prefer doing the work directly via Grep/Read; `bp-redteam` reliably completes and is worth
  keeping as a real dispatched agent.
- Sandbox HTTPS git auth: the Bash tool scrubs `GIT_ASKPASS`/`SSH_ASKPASS` from subprocess env, so
  auth relies on a git **credential helper** file, not the env var — see `launcher.pl`'s
  `ensure_git_credential_helper()`. Container runs as root (`HOME=/root`); `gh` is not baked into
  the image, install it via the backpack if a project needs it.
- This host is Modern-Standby-only (S0, no S3): a keep-awake needs `ES_DISPLAY_REQUIRED` (not just
  `ES_SYSTEM_REQUIRED`) to actually block connected standby; keep on AC with the lid open for long
  unattended runs. The host and the WSL2/podman VM are separate power domains that don't suspend
  simultaneously (the VM can keep running several minutes after the host goes quiet) — never
  compute a lease/mtime age across the host/container clock boundary, compute both sides inside
  the same clock domain.
- `podman machine set --memory` is unsupported on this host's WSL2-backend machine; the configured
  `Resources.Memory` value is cosmetic. Actual container RAM is capped by `~/.wslconfig`'s
  `[wsl2] memory=`. To change the podman-reported config value, hand-edit
  `%USERPROFILE%\.config\containers\podman\machine\wsl\podman-machine-default.json` while the
  machine is stopped.
