# The protected-path guard

## 1. What this guard does

`claude-sandbox` refuses to open a project directory that overlaps anything Claude Code has
installed on this machine, because the sandbox bind-mounts the target directory read-write into the
container. Two holes this guard closes: `~/.claude` (Claude Code's own configuration home) and
`~/.claude/ccpraxis/plugins` (the marketplace directory the live ccpraxis install is loaded from).
Before this guard existed, sandboxing either of those handed the container write access to
credentials, session transcripts and the running plugin tree.

## 2. Where the protected roots come from

Four sources contribute protected roots, plus one user-editable list:

| # | source | contributes |
|---|---|---|
| a | every `installLocation` recorded in `known_marketplaces.json` | `marketplace-install` roots |
| b | every `source.path` of a `directory`-source entry in the same registry | `marketplace-source` roots |
| c | the Claude home: `CLAUDE_CONFIG_DIR`, `$HOME/.claude` and `$USERPROFILE/.claude` — **all three
    unioned**, never a precedence chain | `claude-home` roots |
| d | the ccpraxis live install anchor, derived from the running launcher's own path | the
    `ccpraxis-install` root |
| e | the user-configured extra list (see section 6 below) | `user-configured` roots |

The registry file the launcher reads is pinned to `$HOME/.claude/plugins/known_marketplaces.json` —
the same file the launcher treats as authoritative everywhere else, so this guard and the rest of
the launcher can never disagree about what is installed. Passing `CLAUDE_CONFIG_DIR` does not change
which registry file is read.

The Claude home is a **union**, not a precedence chain: if `CLAUDE_CONFIG_DIR`, `$HOME/.claude` and
`$USERPROFILE/.claude` all resolve to different paths, all three are protected. A chain would let
`CLAUDE_CONFIG_DIR=/tmp/decoy` remove the real `~/.claude` from the protected set entirely — exactly
the kind of environment-variable-shaped escape hatch this guard forbids (see section 8).

A bare filesystem root (`/`, `C:/`) or a bare drive is **never accepted as a protected root** — it is
rejected with a `root-bare-rejected` warning wherever it would otherwise be added as one. Targeting a
bare root or the user's home directory itself is instead handled directly as a `drive-root` /
`user-home` reason code (see section 4).

## 3. The three relations (plus "unrelated")

Every protected root is compared against the target path and classified as one of:

- **exact** — the path you gave IS this protected root. Example: target `/home/u/.claude`, root
  `/home/u/.claude`.
- **descendant** — the path you gave is INSIDE this protected root. Example: target
  `/home/u/.claude/plugins`, root `/home/u/.claude`.
- **ancestor** — the path you gave CONTAINS this protected root. Example: target `/opt`, root
  `/opt/ext-install`.
- **unrelated** — neither path contains the other. A target that is `unrelated` to every protected
  root launches normally; this is the common case for ordinary projects.

`ancestor` matters because `~/.claude` contains every installed marketplace: without an `ancestor`
relation, a rule that only checked `exact`/`descendant` would leave the single highest-value target
— `~/.claude` itself, when reached indirectly via a parent directory — unprotected.

## 4. Reason codes

| reason code | what it means | what to do instead |
|---|---|---|
| `ccpraxis-install` | the target is (or is inside) the live ccpraxis installation | work in a separate clone, `git clone --no-hardlinks` |
| `claude-home` | the target is (or is inside) Claude Code's configuration home | open the specific project directory you meant to work in |
| `marketplace-install` | the target is (or is inside) an installed plugin marketplace's `installLocation` | open the specific project directory, or clone the repository containing it |
| `marketplace-source` | the target is (or is inside) a `directory`-source marketplace's source path | open the specific project directory, or clone the repository containing it |
| `user-configured` | the target is (or is inside) an entry in the user's extra protected-paths list | open the specific project directory, or remove the entry from the list |
| `drive-root` | the target is a bare filesystem root | open the specific project directory you meant to work in |
| `user-home` | the target IS the user's home directory | open the specific project directory you meant to work in |

`drive-root` and `user-home` are self-codes: they describe the target itself, not a collision with
an installed root, so they get their own wording rather than being reported as "contains a
marketplace" (which is nearly always technically true for `/` and `$HOME`, but useless advice).

## 5. Which reason you get when several match

When more than one protected root relates to the target, the guard picks exactly one `(reason,
root, relation)` triple, in this order:

1. **Self-codes beat everything.** If the target itself is a bare filesystem root or the user's home
   directory, that fires immediately — `drive-root` or `user-home` — regardless of what marketplaces
   or configuration happen to live underneath it.
2. **Among the roots that do match, the lowest relation class wins:** `exact` beats `descendant`
   beats `ancestor`. "You are inside X" is a stronger, more honest statement than "you contain Y".
3. **Within a relation class, the module's own root order wins** — ascending reason rank
   (`ccpraxis-install` < `claude-home` < `marketplace-install` < `marketplace-source` <
   `user-configured`), then ascending path order.

Two worked examples:

- Target `~/.claude`: this is `exact` against the `claude-home` root, but only `ancestor` against
  the `ccpraxis-install` root (since `~/.claude/ccpraxis` is underneath it). Rule 2 picks the
  `exact` relation, so the reason is `claude-home`, not `ccpraxis-install`.
- Target `~/.claude/ccpraxis/plugins/sandbox`: this is `descendant` of all three of
  `ccpraxis-install`, `claude-home` and `marketplace-install` roots that contain it. Rule 3 breaks
  the tie by reason rank, so the reason is `ccpraxis-install` (rank 0), the lowest of the three.

## 6. When a source is broken

If a source cannot be read or parsed (missing registry file, malformed JSON, wrong shape, a
hostile/dying registry entry), the guard prints one line per problem to STDERR:

```
claude-sandbox: WARNING: protected-path source [<code>]: <detail>
```

capped at 10 lines, with one overflow line if there are more than 10 problems, followed by exactly
one final line naming how many protected roots the guard is still enforcing. A broken source **never
shrinks a refusal**: every root that did resolve is still matched and enforced exactly as if the
broken source did not exist. Conversely, a broken source **alone is never fatal** — a machine with no
`known_marketplaces.json` (a fresh Claude Code install with no marketplace registered) still launches
normally for an ordinary project; it just loses the `marketplace-*` and `ccpraxis-install` roots that
source would have contributed, and says so loudly.

## 7. Using the extra list

You can protect additional paths yourself by listing them at:

```
${CLAUDE_CONFIG_DIR:-~/.claude}/ccpraxis-protected-paths.json
```

The file, if present, must be a **JSON array of absolute path strings**, for example:

```json
[
  "/home/u/work/some-shared-checkout",
  "C:/Development/company-secrets"
]
```

Every entry becomes a `user-configured` protected root. An **absent file is an empty list and not an
error** — nothing to configure means nothing extra is protected. A **malformed file (not valid JSON,
or not a JSON array) is an error**, surfaced as a `claude-sandbox: WARNING: ...` line same as any
other broken source (see section 6); it does not block the launch of an unrelated project, and it
does not relax any refusal already in effect. The list is machine-scoped (keyed off
`CLAUDE_CONFIG_DIR`/`~/.claude`, not per-project), so one list serves every project on the machine.
An entry that resolves to a bare filesystem root is rejected with a `root-bare-rejected` warning
rather than being accepted as a protected root.

## 8. There is no override

No flag, no environment variable, no interactive prompt bypasses this guard. If a refusal is wrong,
the fix is to correct the detector
(`plugins/sandbox/scripts/ProtectedPaths.pm`) and its oracles
(`plugins/sandbox/tests/t/51-protected-paths.t`,
`plugins/sandbox/tests/t/53-refuse-protected-paths.t`) — never to teach the launcher a bypass.

## 9. Relationship to the in-place refusal

An older, narrower check (`CcpraxisWorkCopy::workcopy_route`) still runs immediately after this
guard, as a fail-safe. It also consults the launcher's own `__FILE__`-derived anchor for the live
ccpraxis install, so it still refuses to sandbox the live install in place even on a machine where
the marketplace registry cannot be read and this guard's `ccpraxis-install` root is therefore
missing. See `plugins/sandbox/docs/working-on-ccpraxis.md` for the clone workflow that refusal
points you to.
