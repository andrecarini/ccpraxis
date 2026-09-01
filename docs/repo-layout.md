# Repo layout

Every file in ccpraxis, with a one-line description. This page is **generated** —
`scripts/gen-readme-tree.pl` writes the block below from what is actually on
disk, so it cannot drift from the tree it documents.

```bash
perl scripts/gen-readme-tree.pl --check   # exit 1 if this page is stale
perl scripts/gen-readme-tree.pl --write   # regenerate it
```

Descriptions come from a `.about` sidecar, a plugin's `plugin.json`, a skill's
`SKILL.md` frontmatter, or the script's own header comment — whichever exists.
To describe an undescribed entry, write the description at its source rather
than editing this file, which is overwritten on every regeneration.

← [Back to the README](../README.md)

<!-- BEGIN-FILE-TREE -->
```
ccpraxis/
├── .gitattributes
├── CLAUDE.md
├── docs/
│   ├── design-conventions.md                  # Design calls: packaging, approval flows, and what gets enforced in code
│   ├── install-protocol.md                    # The fresh-install procedure Claude follows when asked to install ccpraxis
│   ├── reference.md                           # How each surface works: install contract, slash commands, statusline, backup flow, vault sync, sandbox, backpack
│   └── repo-layout.md                         # This page: every tracked file, annotated and generated from disk
├── global-config/
│   ├── CLAUDE.md                              # Global instructions (supply chain rules, response style)
│   ├── known_marketplaces.json                # Marketplace selections (synced across machines)
│   └── settings.json                          # Base settings (env, statusline, plugins, effort level)
├── host-tools/
│   ├── bin/
│   │   └── .gitkeep
│   └── ccpraxis-install.pl                    # host-tools install hook: put `perl` on the user's PATH.
├── install.pl                                 # Top-level setup orchestrator — discovers and runs every surface's ccpraxis-install.pl. Two-phase: bare run = plan only, --confirm = apply.
├── plugins/                                   # Local plugin marketplace ("ccpraxis-local")
│   ├── .claude-plugin/
│   │   └── marketplace.json                   # Lists the plugins below; loaded via extraKnownMarketplaces in settings.json
│   ├── almanac/                               # Almanac plugin — durable project records: ccpraxis bug reports (state machine + write guard) and the guidance notes that replace built-in auto-memory
│   │   ├── .claude-plugin/
│   │   │   └── plugin.json
│   │   ├── hooks/
│   │   │   ├── guard-almanac-write.sh         # PreToolUse guard: denies Edit/Write on bug-reports/*.md so the state machine cannot be bypassed
│   │   │   └── hooks.json                     # Registers the bug-report write guard for any project with almanac enabled
│   │   ├── scripts/
│   │   │   └── almanac-bug.pl                 # Bug-report state machine: file/update/set-status/list/collect/verify. The only sanctioned writer of bug-reports/*.md
│   │   ├── skills/
│   │   │   ├── bug-report/
│   │   │   │   └── SKILL.md                   # File a ccpraxis tooling bug report from whatever project you are working in.
│   │   │   └── bug-triage/
│   │   │       └── SKILL.md                   # Collect and triage ccpraxis bug reports filed from every project on this machin…
│   │   └── tests/
│   │       └── t/
│   │           ├── 01-bug-state-machine.t
│   │           ├── 02-write-guard.t
│   │           ├── 03-frontmatter-injection.t
│   │           └── 04-load-modify-write-race.t
│   ├── backpack/                              # Backpack plugin — declarative tool/runtime/setup manifest for sandbox containers
│   │   ├── .claude-plugin/
│   │   │   └── plugin.json
│   │   ├── hooks/
│   │   │   └── auto-declare.pl                # PostToolUse hook on Bash — detects install commands and proposes /backpack:add
│   │   ├── scripts/
│   │   │   └── backpack.pl                    # Core helper: validate / list / install / add / remove / audit
│   │   ├── skills/
│   │   │   ├── add/
│   │   │   │   └── SKILL.md                   # /backpack:add     — register a new item (with rationale)
│   │   │   ├── audit/
│   │   │   │   └── SKILL.md                   # /backpack:audit   — surface items missing rationale or whose verify no longer passes
│   │   │   ├── install/
│   │   │   │   └── SKILL.md                   # /backpack:install — replay install pass (no container rebuild needed)
│   │   │   ├── list/
│   │   │   │   └── SKILL.md                   # /backpack:list    — show contents grouped by category
│   │   │   └── remove/
│   │   │       └── SKILL.md                   # /backpack:remove  — drop an item
│   │   └── tests/
│   │       ├── run-tests.pl                   # Test runner for plugins/backpack/tests/t/.
│   │       └── t/
│   │           ├── 01-encoding.t
│   │           ├── 02-install-diagnostics.t
│   │           ├── 03-install-declared-reconciliation.t
│   │           ├── 04-install-depends-on-ordering.t
│   │           ├── 05-install-blame-attribution.t
│   │           ├── 06-dependency-audit-table.t
│   │           ├── 07-install-accounting-regressions.t
│   │           ├── 08-bin-dirs-validation.t
│   │           ├── 09-profile-fragment.t
│   │           ├── 10-reinstall-loop.t
│   │           ├── 11-docs-contract.t
│   │           └── 12-bin-dirs-security.t
│   ├── blueprint/                             # Authors and manages durable blueprints (plan-only — no execution or resume ve…
│   │   ├── .claude-plugin/
│   │   │   └── plugin.json                    # Plugin manifest for blueprint (name, version, description, author).
│   │   ├── agents/
│   │   │   └── bp-auditor.md                  # bp-auditor agent - fresh-context completeness auditor; reads only the blueprint files and returns gaps as questions before the blueprint is handed to butler.
│   │   ├── scripts/
│   │   │   ├── bp-init.sh                     # ensure the ccpraxis local data root exists and self-gitignores.
│   │   │   ├── bp-lib.sh                      # shared helpers for the blueprint (authoring) plugin.
│   │   │   └── bp-migrate-plans.pl            # deterministically migrate legacy .claude-plans/*.md
│   │   ├── skills/
│   │   │   ├── authoring-protocol/
│   │   │   │   └── SKILL.md                   # Operating protocol for the blueprint author — the interactive Claude Code ses…
│   │   │   ├── create/
│   │   │   │   └── SKILL.md                   # Create a new blueprint — a durable multi-package initiative with per-package …
│   │   │   └── manage/
│   │   │       └── SKILL.md                   # Manage blueprint lifecycle — list all blueprints with status, view one, re-ru…
│   │   └── templates/
│   │       ├── blueprint.md                   # Template for a blueprint's top-level file (objective, decisions, package status table, package blocks); instantiated by /blueprint:create.
│   │       └── package-ledger.md              # Template for a per-package ledger; its frontmatter (status/model/max_turns/write_set/test_paths) is the contract butler reads at launch.
│   ├── butler/                                # Executes blueprints.
│   │   ├── .claude-plugin/
│   │   │   └── plugin.json                    # Plugin manifest for butler (name, version, description, author).
│   │   ├── agents/
│   │   │   ├── bp-architect.md                # bp-architect worker (opus) - writes the package spec that tests and implementation build from. Report-only.
│   │   │   ├── bp-conformance-judge.md
│   │   │   ├── bp-escalation-resolver.md
│   │   │   ├── bp-feedback-verifier.md        # bp-feedback-verifier agent - fresh-context, tool-enforced read-only diff of a feedback batch's raw files against its decomposition; reports omissions, distortions and modality drift, and cannot fix anything.
│   │   │   ├── bp-harvest-judge.md            # bp-harvest-judge - verifies a finished package's outputs vs done-criteria from disk. Verdict-to-disk, never fixes.
│   │   │   ├── bp-implementer.md              # bp-implementer worker - converges code on the immutable tests within the package write_set. Hook-blocked from test files.
│   │   │   ├── bp-redteam.md                  # bp-redteam worker (opus) - adversarial pass over the package. Report-only.
│   │   │   ├── bp-resolve-judge.md            # bp-resolve-judge - broad-context fix attempt for a stuck package; applies an intent-clear fix (relaunch) or parks with a question.
│   │   │   ├── bp-reviewer.md                 # bp-reviewer worker - spec-conformance and conventions review. Report-only.
│   │   │   ├── bp-scout.md                    # bp-scout worker (haiku) - terrain map with file:line for the package. Report-only.
│   │   │   ├── bp-test-writer.md              # bp-test-writer worker - writes the immutable test oracle from the spec. May only touch the package test_paths.
│   │   │   └── bp-ui-prober.md                # bp-ui-prober worker - finder-based UI scenarios and screenshot reads for packages that touch UI.
│   │   ├── docs/
│   │   │   ├── A0-derisk-findings.md
│   │   │   ├── assumptions.json
│   │   │   └── spend-credentials.md
│   │   ├── hooks/
│   │   │   ├── gate-continuity.sh             # Stop hook for an EXPLICITLY-ARMED continuity session.
│   │   │   ├── gate-drive-loop.sh             # Stop hook inside a /butler:drive-solo DRIVER session.
│   │   │   ├── gate-headless-background.sh    # PreToolUse hook for Bash, deny-when-headless.
│   │   │   ├── gate-shutdown.sh               # PreToolUse graceful-stop gate (Decision #10/#18, package A4).
│   │   │   ├── gate-stop.sh                   # Stop hook inside coordinator sessions.
│   │   │   ├── guard-bash.sh                  # PreToolUse hook for Bash inside coordinator sessions.
│   │   │   ├── guard-blueprint-write.sh       # PreToolUse hook (b43-blueprint-write-api).
│   │   │   ├── guard-git-mutations.sh         # PreToolUse hook denying git working-tree mutations
│   │   │   ├── guard-judge-checks.sh          # PreToolUse hook for Bash, mechanising done
│   │   │   ├── guard-subagent-stall.sh        # refuse to end a turn that dispatched a background
│   │   │   ├── guard-validation-interlock.sh  # PreToolUse hook for Bash.
│   │   │   ├── guard-writes.sh                # PreToolUse hook for Edit|Write|MultiEdit|NotebookEdit.
│   │   │   ├── hooks.json                     # Hook registration for butler: PreToolUse (gate-shutdown/guard-writes on edits, gate-shutdown/track-dispatch on Task, guard-bash on Bash), PostToolUse (log-dispatch), Stop (gate-stop). gate-shutdown is the A4 graceful-stop gate: on a fleet stop signal (runs/.shutdown | runs/.paused | runs/<pkg>.force-stop) it denies new work and lets the coordinator funnel to a clean park.
│   │   │   ├── ledger-guard.sh                # PreToolUse package-ledger write-integrity guard (b12).
│   │   │   ├── lib.sh                         # shared helpers for butler hooks.
│   │   │   ├── log-dispatch.sh                # PostToolUse hook for Task inside coordinator sessions.
│   │   │   ├── mark-wakeup.sh                 # PreToolUse hook for Task, Agent and Bash, in a DRIVE-SOLO
│   │   │   ├── repeat-guard.sh                # PreToolUse mechanical repeat-command guard (b10).
│   │   │   ├── track-dispatch.sh              # PreToolUse hook for Task inside coordinator sessions.
│   │   │   ├── track-worker-solo.sh           # PreToolUse hook for Task|Agent, INTERACTIVE drive-solo
│   │   │   ├── untrack-worker-solo.sh         # PostToolUse hook for Task|Agent, INTERACTIVE
│   │   │   └── wait-shape-guard.sh            # PreToolUse guard for four wait/poll pathologies b10's exact-repeat
│   │   ├── opencode/
│   │   │   ├── bp-architect.md
│   │   │   ├── bp-implementer.md
│   │   │   ├── bp-redteam.md
│   │   │   ├── bp-reviewer.md
│   │   │   ├── bp-scout.md
│   │   │   ├── bp-test-writer.md
│   │   │   ├── bp-ui-prober.md
│   │   │   └── guard-writes-plugin.js
│   │   ├── scripts/
│   │   │   ├── BpState.pm
│   │   │   ├── bp-answer-decision.pl          # the MECHANICAL unblock the reporter performs once a
│   │   │   ├── bp-baseline.pl                 # green-baseline materialization (b40-green-baseline-isolation).
│   │   │   ├── bp-blueprint.pl                # the deterministic blueprint.md write/read API (b43-blueprint-write-api).
│   │   │   ├── bp-cache-state.pl              # b41-cache-state-tracking: the ONE place that decides whether
│   │   │   ├── bp-checkpoint.pl               # durable WIP checkpoint commits (b02, Decisions #2/#17).
│   │   │   ├── bp-checks.pl                   # derive the checks a package's WRITE SET implies, and fail a
│   │   │   ├── bp-containment-audit.pl        # post-step subprocess write-containment audit (b20).
│   │   │   ├── bp-continuity.pl               # explicit continuity arm/disarm/status for THIS session.
│   │   │   ├── bp-contract.pl                 # Anthropic-side + creds CONTRACT validators (Decision #29/#31).
│   │   │   ├── bp-deps-check.pl               # deterministic dependency/version-policy classifier (Decisions #4, #11, #12, #14…
│   │   │   ├── bp-dispatch-log.pl             # the per-dispatch budget record for a driver- or
│   │   │   ├── bp-drive-next.pl               # the mechanical director for /butler:drive-solo.
│   │   │   ├── bp-fast-store.sh               # pnpm store-dir + virtual-store-dir on container-native storage
│   │   │   ├── bp-feedback.pl                 # one-command capture of a single piece of operator feedback
│   │   │   ├── bp-govern.pl                   # the deterministic usage-governance decision functions for the
│   │   │   ├── bp-hooks-selftest.sh           # A8 / Decision #31 startup self-assert.
│   │   │   ├── bp-http.pl                     # the orchestrator/keeper HTTPS transport, via curl.
│   │   │   ├── bp-init.sh                     # ensure the ccpraxis local data root exists and self-gitignores.
│   │   │   ├── bp-jail.pl                     # per-dispatch worker jail isolation (b33-worker-jail-isolation).
│   │   │   ├── bp-judge.pl                    # the DETERMINISTIC decision core for A5 (the judges).
│   │   │   ├── bp-judge.sh                    # fire ONE scoped, throwaway judge for a package and detach it.
│   │   │   ├── bp-keepawake.pl                # the wake-lock, shared by every long-running butler driver.
│   │   │   ├── bp-launch.sh                   # launch (or resume) a headless coordinator session for one package.
│   │   │   ├── bp-ledger.pl                   # the deterministic ledger API (b13-deterministic-ledger-api).
│   │   │   ├── bp-lib.sh                      # butler's copy of the shared base helpers PLUS sandbox-only execution helpers.
│   │   │   ├── bp-lifecycle.pl                # reconcile a blueprint's recorded run-state with what is
│   │   │   ├── bp-log.pl                      # structured, line-flushed, crash-safe run logger (Decision #30).
│   │   │   ├── bp-orchestrate.sh              # start (or report on) the deterministic, token-free
│   │   │   ├── bp-orchestrator.pl             # the deterministic, TOKEN-FREE orchestrator process-management
│   │   │   ├── bp-pin.pl                      # version-pin resolver + drift auditor (b46-version-pin-currency).
│   │   │   ├── bp-preflight.pl                # environment-support assertion (Decisions #29/#31).
│   │   │   ├── bp-progress.pl                 # b11-progress-heuristic-turns-backstop: a semantic liveness check
│   │   │   ├── bp-remediate.pl                # b07-auto-remediation-engine: the DETERMINISTIC decision core
│   │   │   ├── bp-resolve.pl                  # e03-autonomous-resolution: the deterministic apply-step for
│   │   │   ├── bp-resume-sweep.sh             # find interrupted coordinators and resume them economically.
│   │   │   ├── bp-runstate.pl                 # the run-state machine behind the stop gate.
│   │   │   ├── bp-shape-lint.pl               # flag oracle assertions that pin the WHOLE SHAPE of a
│   │   │   ├── bp-spend-auth.pl               # credential UX for the OpenCode Go/Zen spend cookie
│   │   │   ├── bp-spend.pl                    # normalized OpenCode Go + Zen spend reader, plus the composed
│   │   │   ├── bp-status.sh                   # one-line-per-package rollup across blueprints.
│   │   │   ├── bp-statusline.pl               # b37-spend-surfaces C8: the compact spend form for
│   │   │   ├── bp-token-keeper.pl             # the orchestrator's OAuth token-keeper (Decisions #11/#12/#30).
│   │   │   ├── bp-turn-caps.pl                # the canonical turn-cap source, and the drift guard over it.
│   │   │   ├── bp-usage-gate.pl               # ONE host-safe usage-headroom poll for /butler:drive-solo.
│   │   │   ├── bp-validate-dag.pl             # deterministic blueprint-DAG validator.
│   │   │   ├── bp-wait-for-decision.pl        # the reporter's TOKEN-FREE blocking watcher (A7).
│   │   │   ├── bp-watch.pl                    # the general, condition-driven watcher for both interactive
│   │   │   ├── bp-watchdog.pl                 # the drive-solo run's dead-man's switch.
│   │   │   ├── bp-worker-models.pl            # worker model preference resolution + fallback ladder.
│   │   │   ├── bp-worker.pl                   # deterministic non-Task dispatcher for butler workers.
│   │   │   └── bp-write-guard.pl              # BpWrite::guarded_write, the a01-write-integrity-reread-under-lock
│   │   ├── skills/
│   │   │   ├── continuity/
│   │   │   │   └── SKILL.md                   # Toggle or check explicit continuity arming for THIS session — a Stop gate tha…
│   │   │   ├── coordinator-protocol/
│   │   │   │   └── SKILL.md                   # Binding operating protocol for butler coordinators — the headless Claude Code…
│   │   │   ├── dispatch-fleet/
│   │   │   │   └── SKILL.md                   # Execute a blueprint as a headless multi-coordinator FLEET (sandbox-only) — st…
│   │   │   ├── drive-solo/
│   │   │   │   └── SKILL.md                   # The one interactive execute verb — drive one blueprint, a named set, or ALL a…
│   │   │   ├── feedback/
│   │   │   │   └── SKILL.md                   # Turns a batch of raw operator feedback into verified, sourced, basis-marked fin…
│   │   │   ├── orchestrator-protocol/
│   │   │   │   └── SKILL.md                   # Operating doctrine for butler execution — the reporter (the interactive Claud…
│   │   │   ├── reporter/
│   │   │   │   └── SKILL.md                   # Turn THIS Claude session into the reporter for a blueprint run — sync to curr…
│   │   │   └── status/
│   │   │       └── SKILL.md                   # Show the state of one or all blueprints — package statuses, live coordinator …
│   │   ├── templates/
│   │   │   ├── dispatch-prompt.md             # Coordinator bootstrap-prompt template; bp-launch.sh fills the placeholders and feeds it to the detached claude -p coordinator.
│   │   │   ├── judge-escalation-resolve.md
│   │   │   ├── judge-harvest.md
│   │   │   └── judge-resolve.md
│   │   ├── tests/
│   │   │   ├── lib/
│   │   │   │   └── HostCaps.pm
│   │   │   ├── run-tests.pl                   # Test runner for plugins/butler/tests/t/.
│   │   │   └── t/
│   │   │       ├── 00-oracle-hygiene.t
│   │   │       ├── 01-contract.t
│   │   │       ├── 02-preflight.t
│   │   │       ├── 03-govern.t
│   │   │       ├── 04-log.t
│   │   │       ├── 05-keeper.t
│   │   │       ├── 06-orchestrator.t
│   │   │       ├── 07-http.t
│   │   │       ├── 08-orchestrator-scenarios.t
│   │   │       ├── 09-gate.t
│   │   │       ├── 10-judges.t
│   │   │       ├── 100-write-guard-audit.t
│   │   │       ├── 101-guard-writes-specificity.t
│   │   │       ├── 102-set-test-paths.t
│   │   │       ├── 103-add-decision-newline-refusal.t
│   │   │       ├── 104-reporter-skill-note-quoting.t
│   │   │       ├── 105-orchestrator-held-ledger.t
│   │   │       ├── 106-guard-git-mutations-quote-mask.t
│   │   │       ├── 107-locate-table-heading-anchor.t
│   │   │       ├── 108-match-any-divergence.t
│   │   │       ├── 109-ledger-budget-irreducible.t
│   │   │       ├── 11-simulation.t
│   │   │       ├── 110-ledger-budget-fixbatch.t
│   │   │       ├── 111-keepawake-shared.t
│   │   │       ├── 112-subagent-stall-guard.t
│   │   │       ├── 113-oneshot-judge-waiting-discipline.t
│   │   │       ├── 114-accept-settles-harvest.t
│   │   │       ├── 115-escalation-categories.t
│   │   │       ├── 116-escalation-reader-filters.t
│   │   │       ├── 117-keepawake-no-process-storm.t
│   │   │       ├── 118-table-has-no-status.t
│   │   │       ├── 119-gate-headless-background.t
│   │   │       ├── 12-wait-for-decision.t
│   │   │       ├── 120-mark-wakeup-agent-dispatch.t
│   │   │       ├── 121-guard-judge-checks.t
│   │   │       ├── 122-h01-settings-registration.t
│   │   │       ├── 123-h01-prose-qualifiers.t
│   │   │       ├── 124-remediation-attempt-cap.t
│   │   │       ├── 125-resolve-verdict-gates.t
│   │   │       ├── 126-resolve-dispatch-and-guards.t
│   │   │       ├── 127-harvest-error-vs-fail-text.t
│   │   │       ├── 128-pseudo-package-acknowledge.t
│   │   │       ├── 129-decision-validity-terminal-reread.t
│   │   │       ├── 13-answer-decision.t
│   │   │       ├── 130-order-json-prune-stale-blueprint.t
│   │   │       ├── 131-remediation-authoring-validity.t
│   │   │       ├── 132-token-park-doc-honesty.t
│   │   │       ├── 133-bp-watch-decision-core.t
│   │   │       ├── 134-bp-watch-cli.t
│   │   │       ├── 135-bp-watch-doctrine.t
│   │   │       ├── 136-bp-dispatch-log.t
│   │   │       ├── 137-drive-loop-runstate-fold.t
│   │   │       ├── 138-drive-solo-interrupt-doctrine.t
│   │   │       ├── 139-coordinator-protocol-dispatch-doctrine.t
│   │   │       ├── 14-hooks-selftest.t
│   │   │       ├── 140-hooks-reach-non-ccpraxis-project.t
│   │   │       ├── 141-hooks-json-route-registration.t
│   │   │       ├── 142-reporter-registration.t
│   │   │       ├── 143-reporter-stop-gate.t
│   │   │       ├── 144-runstate-surface-separation.t
│   │   │       ├── 145-reporter-gate-regression.t
│   │   │       ├── 146-validation-interlock-hooks.t
│   │   │       ├── 147-worker-tmpdir-isolation.t
│   │   │       ├── 148-registry-runtime-only.t
│   │   │       ├── 149-continuity-toggle.t
│   │   │       ├── 15-orchestrate-shutdown-clear.t
│   │   │       ├── 150-continuity-gate.t
│   │   │       ├── 151-continuity-statusline-badge.t
│   │   │       ├── 152-tooling-bug-filing.t
│   │   │       ├── 153-no-drift-to-repair.t
│   │   │       ├── 154-orchestrator-broken-env-turns.t
│   │   │       ├── 155-worker-backend-dispatcher.t
│   │   │       ├── 156-worker-jail-isolation.t
│   │   │       ├── 157-opencode-worker-runtime.t
│   │   │       ├── 158-worker-model-preference.t
│   │   │       ├── 159-status-read-api.t
│   │   │       ├── 16-oauth-sandbox-preflight.t
│   │   │       ├── 160-status-read-api-regressions.t
│   │   │       ├── 161-lifecycle-derived.t
│   │   │       ├── 162-status-vocabulary-seventh.t
│   │   │       ├── 163-no-duplicate-test-numbers.t
│   │   │       ├── 164-driver-arm-noise-stripping.t
│   │   │       ├── 165-registry-path-one-rule.t
│   │   │       ├── 166-statusline-marker-glyph.t
│   │   │       ├── 167-guard-bash-quote-strip.t
│   │   │       ├── 168-guard-judge-checks-quote-strip.t
│   │   │       ├── 169-wait-shape-guard-quote-strip.t
│   │   │       ├── 17-drive-next.t
│   │   │       ├── 170-guard-git-mutations-heredoc-strip.t
│   │   │       ├── 171-spend-global-and-claude.t
│   │   │       ├── 172-run-continuity-gaps.t
│   │   │       ├── 173-escalation-resolve-wiring.t
│   │   │       ├── 174-empty-scope-is-settled.t
│   │   │       ├── 175-hook-payload-read-bound.t
│   │   │       ├── 18-usage-governor.t
│   │   │       ├── 19-drive-integration.t
│   │   │       ├── 20-deps-check.t
│   │   │       ├── 21-durable-checkpoint-commits.t
│   │   │       ├── 22-checkpoint-hardening.t
│   │   │       ├── 23-keeper-resilience-antispam.t
│   │   │       ├── 24-conformance-gate.t
│   │   │       ├── 25-fast-store.t
│   │   │       ├── 26-auto-remediation-engine.t
│   │   │       ├── 27-preflight-repo-check.t
│   │   │       ├── 60-dag-integrity.t
│   │   │       ├── 61-judge-starvation.t
│   │   │       ├── 62-repeat-guard.t
│   │   │       ├── 63-progress-heuristic.t
│   │   │       ├── 64-ledger-guard.t
│   │   │       ├── 65-ledger-api.t
│   │   │       ├── 66-waiting-discipline.t
│   │   │       ├── 67-wait-shape-guard.t
│   │   │       ├── 68-exit-reason-classification.t
│   │   │       ├── 69-answer-decision-completeness.t
│   │   │       ├── 70-decision-delivery.t
│   │   │       ├── 71-ledger-timestamps.t
│   │   │       ├── 72-subprocess-containment.t
│   │   │       ├── 73-status-recognition.t
│   │   │       ├── 74-soft-ordering.t
│   │   │       ├── 75-effort-and-profiles.t
│   │   │       ├── 76-reporter-autonomy.t
│   │   │       ├── 77-feedback.t
│   │   │       ├── 78-timestamp-authorship.t
│   │   │       ├── 79-contract-idle-window.t
│   │   │       ├── 80-rate-limit-attempt-isolation.t
│   │   │       ├── 81-usage-poll-cadence.t
│   │   │       ├── 82-orphaned-judge-recovery.t
│   │   │       ├── 83-multi-provider-spend.t
│   │   │       ├── 84-green-baseline.t
│   │   │       ├── 85-cache-state.t
│   │   │       ├── 86-blueprint-write-api.t
│   │   │       ├── 87-decision-context-split.t
│   │   │       ├── 88-execution-priority.t
│   │   │       ├── 89-ledger-context-budget.t
│   │   │       ├── 90-version-pin-currency.t
│   │   │       ├── 91-agent-worker-doctrine.t
│   │   │       ├── 92-write-set-implied-checks.t
│   │   │       ├── 93-turn-cap-consistency.t
│   │   │       ├── 94-drive-loop-gate.t
│   │   │       ├── 95-watchdog.t
│   │   │       ├── 96-hook-path-walk-and-scope.t
│   │   │       ├── 97-lifecycle-reconcile.t
│   │   │       ├── 98-write-guard-primitive.t
│   │   │       └── 99-write-guard-sites.t
│   │   └── turn-caps.json
│   ├── sandbox/                               # Sandbox plugin — bundles the claude-sandbox host launcher, the container blueprint, the bootstrap routine, and the /sandbox:setup redirect skill
│   │   ├── .claude-plugin/
│   │   │   └── plugin.json
│   │   ├── bin/                               # User-invoked CLI lives here; shell-native wrappers are required so users can type `claude-sandbox` from any terminal.
│   │   │   ├── claude-sandbox.ps1             # Thin shim — locates Perl + execs launcher.pl (Windows/PowerShell)
│   │   │   └── claude-sandbox.sh              # Thin shim — execs into plugins/sandbox/scripts/launcher.pl (Linux/macOS)
│   │   ├── ccpraxis-install.pl                # Install hook — wires plugins/sandbox/bin/ into user PATH (delegates to _install-bin-helper.pl)
│   │   ├── container/                         # Container blueprint — files that get baked into or mounted into the sandbox container
│   │   │   ├── CLAUDE.md                      # Container-specific instructions (full autonomy)
│   │   │   ├── Containerfile                  # OCI container image: Debian bookworm + Claude Code CLI + dev tools (runs as root; works with Docker or rootless Podman)
│   │   │   ├── claude.json                    # Onboarding bypass for containers
│   │   │   ├── heartbeat.sh                   # the sandbox container's entrypoint keep-alive loop (B6).
│   │   │   └── settings.json                  # Container-specific settings
│   │   ├── docs/
│   │   │   ├── B0-tui-spike-findings.md
│   │   │   ├── b0-tui-probe.pl                # B0 TUI viability spike (Decision #18/#19, package B0).
│   │   │   ├── concurrent-config-safety-spike.md
│   │   │   ├── migration-record.md
│   │   │   ├── protected-paths.md
│   │   │   ├── terminal-minimize-investigation.md
│   │   │   ├── token-schema-inventory.md
│   │   │   ├── tui-adapter-contract.md
│   │   │   └── working-on-ccpraxis.md
│   │   ├── scripts/
│   │   │   ├── BackpackApproval.pm
│   │   │   ├── BackpackOps.pm
│   │   │   ├── BackpackReview.pm
│   │   │   ├── CcpraxisWorkCopy.pm
│   │   │   ├── ClaudeConfig.pm
│   │   │   ├── ConnectorHold.pm
│   │   │   ├── Dashboard.pm                   # the raw-ANSI TUI dashboard framework for `claude-sandbox` (B2).
│   │   │   ├── HotReload.pm
│   │   │   ├── KeepAwake.pm
│   │   │   ├── LaunchLog.pm
│   │   │   ├── MountSpec.pm
│   │   │   ├── PluginSync.pm
│   │   │   ├── PortAlloc.pm
│   │   │   ├── ProtectedPaths.pm
│   │   │   ├── Resources.pm
│   │   │   ├── RunState.pm
│   │   │   ├── SandboxLock.pm
│   │   │   ├── SessionFilter.pm
│   │   │   ├── SpendPanel.pm
│   │   │   ├── Theme.pm
│   │   │   ├── TokenInfo.pm
│   │   │   ├── bootstrap.pl                   # First-launch setup invoked by launcher.pl when .claude-data is missing. 6 steps: verify container blueprint, build image, mkdir .claude-data, append .gitignore, git auth (HTTPS PAT / SSH deploy-key), invoke ccpraxis-install.pl. Fully interactive over the launcher's tty.
│   │   │   ├── keep-awake.ps1                 # hold a Windows wake-lock for as long as THIS process lives,
│   │   │   ├── launcher.pl                    # The actual claude-sandbox launcher: arg parsing, bootstrap detection, lock + dead-PID cleanup, image build, TUI selector orchestration, staleness check, mount assembly, container create-or-reattach. Wrappers in bin/ are tiny shims that exec into this.
│   │   │   ├── select-session.pl              # TUI session picker for the claude-sandbox launcher.
│   │   │   ├── skills.pl                      # Discovery/selection backend for the launcher: enumerates custom + plugin skills + plugins + MCP servers, drives the interactive TUI picker, writes selection state and diff reports the launcher consumes.
│   │   │   └── tui/
│   │   │       ├── BackpackScreen.pm          # tui::BackpackScreen -- the [b] screen (blueprint unified-tui-design-system,
│   │   │       ├── DashboardScreen.pm         # tui::DashboardScreen -- the dashboard's content vocabulary (blueprint
│   │   │       ├── Frame.pm                   # tui::Frame -- row composition, sanitisation and the single SGR emitter for
│   │   │       ├── LaunchScreens.pm           # tui::LaunchScreens -- the launch-phase screens for claude-sandbox
│   │   │       ├── Layout.pm                  # tui::Layout -- measurement, wrapping, and arrangement for the shared TUI
│   │   │       ├── Meter.pm                   # tui::Meter -- meter rows: Decision 4's geometry (label, numbers, bar,
│   │   │       └── Screen.pm                  # tui::Screen -- pure composition + viewport + diff, with a deliberately
│   │   ├── skills/
│   │   │   ├── setup/
│   │   │   │   └── SKILL.md                   # /sandbox:setup — confirms .claude-data state and tells the user to exit Claude and run `claude-sandbox`
│   │   │   └── test/
│   │   │       └── SKILL.md                   # Run the sandbox plugin's verification suite — proves the bind-mount honors O_…
│   │   └── tests/
│   │       ├── lib/
│   │       │   └── TestSandbox.pm
│   │       ├── manual/
│   │       │   └── longrun-freeze-check.sh    # Long-running empirical test: spins up a container with the current bind-mount architecture, drives claude with periodic keystrokes via socat for 8 minutes, and confirms it stayed alive throughout. Destructive — needs a real container runtime. See file header for usage.
│   │       ├── run-tests.pl                   # Test runner for plugins/sandbox/tests/t/.
│   │       └── t/
│   │           ├── 01-bind-honors-append-and-utimensat.t
│   │           ├── 02-launcher-bind-mount-shape.t
│   │           ├── 03-claude-json-file-bind.t
│   │           ├── 04-runtime-detection.t
│   │           ├── 06-launcher-ro-protection.t
│   │           ├── 07-mountspec-volume-vs-bind.t
│   │           ├── 08-launcher-loads-from-any-cwd.t
│   │           ├── 09-no-stdin-after-podman-start.t
│   │           ├── 10-select-session-empty-dir.t
│   │           ├── 100-status-live.t
│   │           ├── 101-claude-json-relocation-migration.t
│   │           ├── 102-tui-output-hygiene.t
│   │           ├── 103-transcript-retention.t
│   │           ├── 104-animation-cadence.t
│   │           ├── 105-banner-placement.t
│   │           ├── 106-panel-grid-borders.t
│   │           ├── 107-container-sampler.t
│   │           ├── 108-reap-orphans.t
│   │           ├── 11-select-session-parses.t
│   │           ├── 12-keepalive-heartbeat.t
│   │           ├── 13-install-pass-heartbeat.t
│   │           ├── 18-multi-session-shared-state.t
│   │           ├── 21-select-session-multiple.t
│   │           ├── 22-mountspec-edge-cases.t
│   │           ├── 23-reap-decision.t
│   │           ├── 24-launch-log.t
│   │           ├── 25-dashboard.t
│   │           ├── 26-backpack-approval.t
│   │           ├── 27-backpack-review.t
│   │           ├── 28-keepawake.t
│   │           ├── 29-select-session-viewport.t
│   │           ├── 30-connector-hold.t
│   │           ├── 31-plugin-merge.t
│   │           ├── 32-plugin-sync.t
│   │           ├── 33-credentials-degrade.t
│   │           ├── 34-claude-json-seed.t
│   │           ├── 35-port-alloc.t
│   │           ├── 36-launcher-port-publish.t
│   │           ├── 37-launch-stage-coverage.t
│   │           ├── 38-global-lock.t
│   │           ├── 39-ccpraxis-workcopy-detect.t
│   │           ├── 40-layout-responsive.t
│   │           ├── 41-panel-semantics.t
│   │           ├── 42-refuse-in-place.t
│   │           ├── 43-token-panel.t
│   │           ├── 44-resources.t
│   │           ├── 45-run-state.t
│   │           ├── 46-lifecycle-stop.t
│   │           ├── 47-lifecycle-relaunch.t
│   │           ├── 48-activity-history.t
│   │           ├── 49-session-filter.t
│   │           ├── 50-input-latency.t
│   │           ├── 51-protected-paths.t
│   │           ├── 52-detector-hardening.t
│   │           ├── 53-refuse-protected-paths.t
│   │           ├── 54-spend-panel.t
│   │           ├── 55-minimize-evidence.t
│   │           ├── 56-launcher-d5-hardening.t
│   │           ├── 57-node-pnpm-toolchain.t
│   │           ├── 58-container-health-detect.t
│   │           ├── 59-fleet-event-source.t
│   │           ├── 60-keepawake-probe.t
│   │           ├── 61-settings-scope-split.t
│   │           ├── 62-tui-adapter-contract.t
│   │           ├── 63-run-panel-truth.t
│   │           ├── 64-theme-tokens.t
│   │           ├── 65-tui-render-library.t
│   │           ├── 66-dashboard-screen.t
│   │           ├── 67-backpack-screen.t
│   │           ├── 68-launcher-screens.t
│   │           ├── 69-statusline-rebuild.t
│   │           ├── 70-launch-prompt-conversion.t
│   │           ├── 71-test-harness-orphan-reaping.t
│   │           ├── 72-log-retention.t
│   │           ├── 73-layout-flex-stability.t
│   │           ├── 74-transcript-pointer.t
│   │           ├── 75-wrap-on-overflow.t
│   │           ├── 76-cold-start-machine-recovery.t
│   │           ├── 77-wrap-width-regressions.t
│   │           ├── 78-resources-spawn-budget.t
│   │           ├── 79-providers-panel.t
│   │           ├── 80-ssh-host-keys.t
│   │           ├── 81-skills-manifest-mounts.t
│   │           ├── 82-skills-prune-orphaned-dirs.t
│   │           ├── 83-skills-reconcile-manifest.t
│   │           ├── 84-plugin-unknown-version-dest-rel.t
│   │           ├── 85-skills-legacy-specimen-removal.t
│   │           ├── 86-skills-legacy-removal-fixbatch.t
│   │           ├── 87-banner-dismiss.t
│   │           ├── 88-banner-wrap-every-surface.t
│   │           ├── 89-tui-render-debt.t
│   │           ├── 90-resources-sampler-visibility.t
│   │           ├── 91-spend-snapshot-adapter.t
│   │           ├── 92-activity-side-column.t
│   │           ├── 93-blueprints-table.t
│   │           ├── 94-no-rendered-colons.t
│   │           ├── 95-needs-you-lifecycle.t
│   │           ├── 96-hot-reload.t
│   │           ├── 97-escalation-ownership.t
│   │           ├── 98-render-spans.t
│   │           └── 99-shared-claude-json-concurrency.t
│   ├── steward/                               # Meta-plugin that maintains ccpraxis and owns its backup, onboarding, and self-e…
│   │   ├── .claude-plugin/
│   │   │   └── plugin.json
│   │   ├── scripts/
│   │   │   ├── ccpraxis-helpers.pl            # Deterministic subcommands for /backup (sync-skills, etc.) — replaces several LLM-driven prose steps with scripted ones; emits JSON the skill consumes
│   │   │   ├── check-plugins.pl               # Detects missing or stale plugins vs settings.json
│   │   │   ├── claude-binary-backup.pl        # Snapshot / list / restore / prune / verify / detect for the Claude Code binary — gives /steward:update a deterministic safety net before any installer runs
│   │   │   ├── filter-diff.pl                 # Filters json-diff output through saved preferences
│   │   │   ├── json-diff.pl                   # Semantic JSON diff (--deep-exclude, structured report)
│   │   │   ├── onboard.pl                     # deterministically prepare a project to use the ccpraxis blueprint
│   │   │   ├── save-preference.pl             # Records "remember this divergence" decisions
│   │   │   ├── sensitive-check.pl             # Scans the public ccpraxis repo for secrets before committing
│   │   │   ├── sync-export.pl                 # Detects drift between live config and this repo
│   │   │   ├── usage-audit-rates.json         # Provider rate card (Anthropic / Z.ai / DeepSeek / Kimi) for usage-audit.pl
│   │   │   ├── usage-audit.pl                 # Token-usage + provider-cost engine for /steward:usage-audit
│   │   │   └── vault-sync.pl                  # Central engine for claude-code-vault project backups.
│   │   ├── skills/
│   │   │   ├── audit/
│   │   │   │   └── SKILL.md                   # Audits the ccpraxis repo itself — fans out read-only subagents (per-system re…
│   │   │   ├── backup/
│   │   │   │   └── SKILL.md                   # Syncs everything personal between the live host and your private repos — ccpr…
│   │   │   ├── ccpraxis-extend/
│   │   │   │   └── SKILL.md                   # THE single entrypoint for changing ccpraxis or adding new functionality to it.
│   │   │   ├── setup-project/
│   │   │   │   └── SKILL.md                   # Onboard the current project to the ccpraxis system — create the local data di…
│   │   │   ├── update/
│   │   │   │   └── SKILL.md                   # Safely updates Claude Code by researching releases before installing.
│   │   │   └── usage-audit/
│   │   │       └── SKILL.md                   # Measures real Claude Code token consumption across every transcript on this mac…
│   │   └── tests/
│   │       ├── lib/
│   │       │   └── StewardTest.pm             # StewardTest — minimal test harness for the steward vault engine.
│   │       ├── run-tests.pl                   # runner for the steward vault test suite.
│   │       └── t/
│   │           ├── 01-encoding.t
│   │           ├── 02-host-memory-roundtrip.t
│   │           ├── 03-second-machine-link.t
│   │           ├── 04-conflict.t
│   │           ├── 05-hard-exclude.t
│   │           ├── 06-refresh-idempotent.t
│   │           ├── 07-vault-metadata-rot.t
│   │           ├── 08-backup-data-migration.t
│   │           ├── 09-no-drive-root-strays.t
│   │           ├── 10-marketplace-preferences.t
│   │           ├── 11-journal-append-only.t
│   │           └── 12-fresh-register-commits.t
│   └── todo/                                  # Personal todo notes synced to your private vault repo.
│       ├── .claude-plugin/
│       │   └── plugin.json
│       └── skills/
│           ├── create/
│           │   └── SKILL.md                   # /todo:create          — save a todo note
│           ├── manage/
│           │   └── SKILL.md                   # /todo:manage          — list / view / edit / delete / done
│           └── resume/
│               └── SKILL.md                   # /todo:resume          — load a todo and work on it
├── references/
│   ├── extending-ccpraxis.md                  # Extension contract — how plugins/skills/standalone surfaces plug into ccpraxis and what each must provide
│   └── skill-writing-guide.md                 # Shared skill authoring guide (folder structure, progressive disclosure, writing tips)
├── scripts/                                   # ccpraxis-wide utility scripts (shared across surfaces)
│   ├── _install-bin-helper.pl                 # Shared PATH/PATHEXT wiring (idempotent). Branches on $^O. Used by per-surface ccpraxis-install.pl hooks.
│   ├── _perl-path.ps1                         # single source of truth for locating perl from PowerShell.
│   ├── gen-readme-tree.pl                     # Generates the file-tree section of README.md from disk, using per-module metadata (.about > plugin.json > SKILL.md > script header). --check mode wires into /backup as a pre-flight; --bootstrap is a one-shot for adopting on an existing README.
│   ├── hooks/                                 # Host-side PreToolUse hooks installed via global-config/settings.json
│   │   ├── block-nonascii-ps1.pl              # PreToolUse guard: refuse to write non-ASCII into a
│   │   ├── block-nul-redirect.pl              # Blocks bash `> nul` redirects on Windows — without this hook, scripts that target /dev/null on Unix create a stray `nul` file in the cwd, polluting the repo
│   │   └── reap-orphans-hook.pl               # SessionStart hook: sweep processes left behind by
│   ├── install-skills.pl                      # Symlinks (Unix) or junctions (Windows: `mklink /J`) every skills/<name>/ into ~/.claude/skills/. plan/apply modes. Called from the install protocol — handles Windows where `ln -s` silently falls back to a file copy.
│   ├── lint-msys2-guard.pl                    # Pre-flight for /backup: walks every .pl that invokes podman natively and asserts the MSYS2_ARG_CONV_EXCL=* guard is set (the bug it prevents: `;C`-suffixed bind-mount targets on Windows)
│   ├── lint-readme-paths.allow                # Allowlist for lint-readme-paths.pl — backtick contents that look like ccpraxis paths but are intentional non-host paths (e.g. container-internal)
│   ├── lint-readme-paths.pl                   # Pre-flight for /backup: verifies every backtick-quoted ccpraxis path in README.md exists on disk
│   ├── reap-orphans.pl                        # find (and optionally kill) processes left behind by a
│   ├── run-tests.pl                           # the repo-wide test runner.
│   ├── statusline.pl                          # Custom two-line status bar (model, context, rate limits)
│   ├── todo-sync.pl                           # Vault todos: list/create/done/sync (git ops scoped to todos/)
│   ├── tui-preview.pl                         # a live, resizable preview of the sandbox dashboard, driven
│   ├── update-bootstrap-monitor.pl            # /steward:update support: versioned archive + drift check for upstream bootstrap.ps1
│   ├── update-install.pl                      # /steward:update support: direct-binary install pipeline (detect / manifest / install / verify)
│   └── update-research.pl                     # /steward:update support: fetches GitHub releases + changelog presence + symptom searches against issues
└── skills/
    ├── carry-over/
    │   └── SKILL.md                           # /carry-over           — hand this session's work to a fresh one (plan-mode handover; not /compact)
    ├── launch-chrome-puppet/                  # /launch-chrome-puppet — CDP browser automation
    │   ├── SKILL.md
    │   └── scripts/
    │       ├── chrome-puppet.pl               # Subcommand dispatcher (launch, navigate, text, etc.)
    │       └── lib/
    │           └── CDPClient.pm               # Pure-Perl WebSocket + CDP client
    └── refresh/
        └── SKILL.md                           # /refresh              — reread CLAUDE.md mid-conversation
```
<!-- END-FILE-TREE -->
