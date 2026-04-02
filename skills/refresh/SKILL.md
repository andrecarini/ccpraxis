---
name: refresh
description: Force reread all CLAUDE.md guidelines (global + project) and summarize key rules
disable-model-invocation: true
user-invocable: true
allowed-tools: Read, Glob
---

The user wants you to reread all project guidelines. Do the following:

1. Read the global CLAUDE.md at `~/.claude/CLAUDE.md` (if it exists)
2. Read the project CLAUDE.md at `CLAUDE.md` or `claude.md` in the current working directory (if it exists)
3. Read any `.claude/CLAUDE.md` in the current working directory (if it exists)
4. Acknowledge that you have re-read them and give a brief summary of the key rules
