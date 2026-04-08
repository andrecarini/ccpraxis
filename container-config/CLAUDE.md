# Global Instructions

## Response Style
- Every message must start with 🤖

## ✅ YOU ARE INSIDE A SANDBOXED CONTAINER — FULL AUTONOMY

You are running inside an isolated Docker container. The project folder is at `/project`.
You have full autonomy. No permission prompts. Go fast.

**You CAN and SHOULD install and run dev tooling directly:**
- ✅ `npm install`, `npm ci`, `npx`
- ✅ `dart`, `flutter`, `pub get`
- ✅ `pip install`, `python`, `cargo`, `go build`
- ✅ `firebase`, `gcloud`, `terraform`
- ✅ ANY build tool, linter, formatter, or compiler
- ✅ `apt-get install` for additional system packages and runtimes (Node.js, Python, etc.)

There is no host machine to protect — this container IS the sandbox.
Worst case, the container gets recreated. Project files are bind-mounted and git-recoverable.

## ⚠️ SUPPLY CHAIN SECURITY (still applies inside the container)

Even inside a container, supply chain attacks can exfiltrate project source code and credentials. Minimize the attack surface:

- **`npm_config_ignore_scripts=true` is set as an environment variable.** This blocks npm postinstall hooks globally. Do NOT override it with `--ignore-scripts=false` unless explicitly told to by the user. If a package requires postinstall scripts to function, inform the user and let them decide.
- **When installing any package manager**, set its equivalent security protections (e.g. pip `--no-build-isolation` where appropriate).
- **Never pull packages published < 7 days ago** — applies to fresh installs from a lockfile AND when upgrading/adding dependencies to a lockfile. If you notice a dependency was published very recently, flag it.
- **Prefer well-established packages** with many downloads, known maintainers, and active maintenance over obscure alternatives.
- Same caution applies to `pip install`, `cargo install`, `pub get`, etc.

## Git

- Local git operations (add, commit, diff, log, status, branch, etc.) work normally
- For push/pull to private repos: if a deploy key exists in the project folder, use:
  `GIT_SSH_COMMAND="ssh -i /project/deploy_key -o StrictHostKeyChecking=no" git push`
- If `$GIT_SSH_COMMAND` or `$GIT_ASKPASS` is already set in the environment, git push/pull should just work

## Network / Ports

Ports **9000–9009** are mapped 1:1 to the host. When serving anything that needs to be accessed from the host browser (web apps, dev servers, emulators, etc.), **bind to one of these ports**. The user can then open `http://localhost:9000` (or whichever port you chose) on the host.

Example: to serve a Flutter web build, use port 9000:
```bash
dhttpd --port 9000 --path build/web
```

## Persistence

- **This container is persistent** — it survives between sessions. Installed packages (apt, npm global, pip global, runtimes) persist across sessions.
- File changes in `/project` persist (bind-mounted to host)
- Your memories, conversation history, and plans persist in `/project/.claude-data/`
- Auth tokens are read-only from the host — do not try to modify them
- The container may be rebuilt if it becomes stale (Claude Code version mismatch or > 7 days old). When that happens, you'll need to reinstall project-specific runtimes and tools.
