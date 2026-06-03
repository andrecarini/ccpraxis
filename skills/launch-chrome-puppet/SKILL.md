---
name: launch-chrome-puppet
description: >-
  Launches a headed Chrome instance with Chrome DevTools Protocol (CDP) enabled
  for browser automation, then provides subcommands for navigation, DOM extraction,
  screenshots, clicking, typing, and JS evaluation. Handles first-time setup
  (creates .chrome-puppet/ dir, gitignores it), detects already-running instances,
  finds a free port. Use when the user says "launch chrome", "start chrome puppet",
  "open browser", or needs to automate a real browser for scraping or testing.
user-invocable: true
host-only: true
allowed-tools:
  - Bash
---

# Chrome Puppet

Browser automation via Chrome DevTools Protocol. A Perl script handles all
deterministic work — launching Chrome, WebSocket framing, CDP commands. You
only interpret results and decide what to do next.

## Quick start

```bash
perl "${CLAUDE_SKILL_DIR}/scripts/chrome-puppet.pl" launch
```

All subcommands output JSON. Parse the `ok` field to check success.

## Available subcommands

**Lifecycle:**

| Command | Example | What it does |
|---------|---------|-------------|
| `launch` | `launch` | Setup + launch Chrome + verify CDP |
| `tabs` | `tabs` | List open tabs |
| `tab-new` | `tab-new https://example.com` | Open new tab |
| `tab-close` | `tab-close <id>` | Close a tab |
| `status` | `status` | Check if CDP is alive |

**Page interaction:**

| Command | Example | What it does |
|---------|---------|-------------|
| `navigate` | `navigate https://example.com` | Go to URL, wait for load |
| `html` | `html ".job-listing"` | Get outer HTML (page or selector) |
| `text` | `text ".job-listing"` | Get inner text (page or selector) |
| `screenshot` | `screenshot jobs.png` | Capture viewport as PNG |
| `click` | `click "button.submit"` | Click an element |
| `type` | `type "#search" "engineer"` | Type into a field |
| `eval` | `eval "document.title"` | Run arbitrary JavaScript |
| `wait` | `wait ".results" or wait 3` | Wait for selector or seconds |

**Common options:** `--port PORT` and `--tab ID` override auto-detection.
When omitted, the script finds the running instance and first page tab automatically.

## Usage pattern

```bash
# Launch (once per session)
perl "${CLAUDE_SKILL_DIR}/scripts/chrome-puppet.pl" launch

# Then drive it
perl "${CLAUDE_SKILL_DIR}/scripts/chrome-puppet.pl" navigate "https://arbetsformedlingen.se/platsbanken"
perl "${CLAUDE_SKILL_DIR}/scripts/chrome-puppet.pl" wait ".search-results"
perl "${CLAUDE_SKILL_DIR}/scripts/chrome-puppet.pl" text ".search-results"
perl "${CLAUDE_SKILL_DIR}/scripts/chrome-puppet.pl" screenshot results.png
```

## Notes

- The `eval` subcommand is the escape hatch — for anything the built-in commands
  don't cover, write JavaScript and run it via eval.
- The profile persists at `.chrome-puppet/profile/` in the project directory,
  so cookies and sessions survive across relaunches.
- If Chrome is already running with this project's profile, `launch` reports the
  existing instance instead of starting a second one.
- Screenshots are saved relative to the current working directory.
