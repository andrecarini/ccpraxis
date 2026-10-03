---
name: inbox
description: File anything that needs the operator -- a manual check, a taste call, a question -- keep working, and record the answer when it comes. Each one is an inbox item and shows as the statusline flag in every session of the project until answered. Use when the choice is genuinely the operator's (scope, priorities, user-visible behaviour, spending a limited budget) and other work can continue meanwhile, and use when the operator answers one or asks what is in the inbox. Skip for technical questions you can settle from the code, the docs or a measurement, and decide those yourself with the assumption stated.
allowed-tools: Bash, Read
---

# The operator's inbox

A product call (scope, priorities, user-visible behaviour, spending a limited budget) goes here.
An implementation call, settled from the code, the docs or a measurement, does not; decide that
yourself and state the assumption.

Filing returns immediately. Carry on with other work rather than waiting on an answer.

## See what's waiting

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" inbox list
```

## File one

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" inbox file --title "one line" --body "the choice and why it's the operator's"
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" inbox file --title "one line" --link <blueprint>/<package> --choices accept,drop
```

## Work it

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" inbox show <id>
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" inbox answer <id> --answer "..."
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" inbox answer <id> --choice accept --note "..."
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" inbox blocks <id>
```

An item filed with `--choices` is answered with `--choice` (one of them) and an optional `--note`;
any other item with `--answer`. A task waiting on an inbox item carries `--blocked-on <inbox-id>`
(see /almanac:task); `answer` lists the tasks it unblocks.
