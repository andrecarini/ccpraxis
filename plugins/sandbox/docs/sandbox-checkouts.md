# The sandbox and your ccpraxis checkouts

How `claude-sandbox` relates to the two checkouts described in
[`docs/working-on-ccpraxis.md`](../../../docs/working-on-ccpraxis.md): the **dev clone** you
develop in and the **live install** (`~/.claude/ccpraxis`) that promotion produces.

## Why in-place is refused

`claude-sandbox` refuses to launch against the live install. Sandboxing `~/.claude/ccpraxis` would
mean editing the tooling while it is running. The previous answer to this was a git *worktree* of
the live repo, which turned out to be unworkable: a worktree shares the live object store and puts
its admin files in the live repo, so creating it was already a write to live, and `/project/.git`
became a pointer to a Windows path meaningless to Linux, killing git in-container entirely. Worse,
the provisioning logic could silently overwrite blueprint ledgers with pristine copies from live.

That model was deleted. See `migration-record.md` for the one-time migration that replaced it, and
the `sandbox-refuse-in-place` blueprint for the full reasoning.

Sandbox the dev clone instead. Inside the container `git -C /project status` works: the clone's
`.git` is a real directory, and the container cannot reach the live install because the live object
store is not there. The isolation is structural, not policy-enforced. The dev clone is not a
registered marketplace, so it is not protected and launches normally; if you ever register it as
one, `claude-sandbox` will start refusing it, by design.

## The launcher serves the checkout it runs from

`launcher.pl`, `bootstrap.pl` and `skills.pl` find their own tooling through
`plugins/sandbox/scripts/SandboxIdentity.pm`, never through a hard-coded `~/.claude/ccpraxis`:

- **`install_root()`** is the checkout the scripts were loaded from. The container template,
  statusline, backpack scripts, custom `skills/` dir, the image-build lock and the `ccpraxis-local`
  plugin tree bind-mounted into the container all come from it. Through the `claude-sandbox` shims
  that is the live install. Run `perl plugins/sandbox/scripts/launcher.pl` straight from a clone and
  you get the clone's tooling. On macOS the binds read a copy of that checkout's `plugins/`,
  `skills/` and `scripts/statusline.pl` instead (`LiveMirror.pm`, refreshed before each container
  create and start, and by promotion for the live install), because the podman machine must not
  share code the Mac runs; each checkout has its own copy, so a clone's launcher never changes what
  the live install's sandboxes see ([`podman-machine.md`](podman-machine.md)).
- **Identity** (`$ID`, `$CONTAINER_PREFIX`) names the image (`claude-sandbox:latest`), the
  containers (`claude-<project>-<hash>`), the in-container hostname and the id presented to
  refusal markers.

This is what lets a **fork** ship a second launcher next to `claude-sandbox`: change the two
identity lines in `SandboxIdentity.pm`, add shims that point at the fork's checkout, and the fork's
command builds its own image, names its own containers and serves the fork's plugins, without
colliding with `claude-sandbox`. The port allocator recognises every family's container names, so
two launchers never hand out the same port block. Both share one Windows Terminal profile
(`WtProfile.pm`), which is harmless: the content is identical.

A fork can also list host names its containers must not reach in `@BLOCKED_HOSTS`; each is pinned
to `0.0.0.0` in the container's `/etc/hosts` at create time (`--add-host`). Entries that are not
plain DNS names are dropped. It is a guardrail, not a wall: root in the container can edit
`/etc/hosts`. ccpraxis itself blocks nothing.

## Gotchas

- **Never copy `.ccpraxis-local-data/claude-home/.launcher/` between project locations.** It holds
  machine- and container-specific identity (`container-name`, `port-base`, `containerfile-hash`).
  A copied `container-name` makes the launcher attach to *another project's* container and mount the
  wrong directory at `/project`. It is derived state: delete it and it regenerates.
- **`.launcher/last-transcript.txt`** is a one-line, best-effort pointer `launcher.pl` writes on every
  launch (immediately after opening the launch transcript), holding the in-container path to that
  launch's raw console transcript (`/root/.claude/sandbox-logs/launch-<id>.transcript.log`).
  `.launcher/` is RO-overlaid inside the container while `sandbox-logs/` is not, so an agent that
  inspects only `.launcher/` and finds no log there would otherwise reasonably (but wrongly) conclude
  none was kept; this pointer redirects it to the real, writable location (BPK-07).
- **The container's Claude Code version tracks the host's; it is not insulated from it.** At build
  time `bootstrap.pl` reads the host's `claude --version` and passes it as `--build-arg
  CLAUDE_VERSION`; the `Containerfile` installs exactly that; `launcher.pl` marks a container stale
  on a version mismatch and rebuilds. So any runtime risk tied to the bundled Claude/Bun version
  reaches the in-container butler fleet too. When comparing reports, remember the container runs
  the Linux build of Bun and the host the Windows or macOS one, so platform-specific symptoms can
  differ.
