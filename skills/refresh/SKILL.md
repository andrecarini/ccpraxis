---
name: refresh
description: Rereads all CLAUDE.md guidelines (global + project) and summarizes key rules. Use when Claude seems to have drifted from guidelines mid-conversation, or when the user says "refresh", "reread instructions", "reload guidelines".
user-invocable: true
allowed-tools: Read, Glob
---

Reread all project guidelines and re-anchor on key rules. Do the following:

1. Read the global CLAUDE.md at `~/.claude/CLAUDE.md` (if it exists)
2. Read the project CLAUDE.md at `CLAUDE.md` or `claude.md` in the current working directory (if it exists)
3. Read any `.claude/CLAUDE.md` in the current working directory (if it exists)
4. Acknowledge that you have re-read them and give a brief summary of the key rules
