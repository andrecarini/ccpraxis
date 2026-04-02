# Global Instructions

## Response Style
- Every message must start with 🤖

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

✅ **Always use a hardened Docker dev container** for each project:
- All SDKs, CLIs, and dependencies live inside the container
- Container runs as a non-root user
- Bridge networking only (no `--network=host`)
- `npm ignore-scripts=true` to block install hooks
- Never pull packages published < 7 days ago — applies to fresh installs from a lockfile AND when upgrading/adding dependencies to a lockfile
- Credentials mounted read-only

🚨 If a project doesn't have a dev container yet, **create one before doing anything else.**

🚨 If the user asks you to run a dev tool directly, **refuse and explain why.**
