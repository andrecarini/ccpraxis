# Preflight.pm -- backup driver phase 02-preflight-and-config (blueprint
# backup-driver).
#
# Absorbs today's SKILL.md Steps 1 (remote integration), 1.2 (README path
# lint + repo-layout tree check) and 1.5 (skills mirror, CLAUDE.md check,
# settings diff, marketplace diff). See the spec for the original contract:
#   .ccpraxis-local-data/blueprints/backup-driver/specs/02-preflight-and-config-spec.md
# including its BINDING coordinator rulings (S8, P1-P5), which supersede
# anything earlier in that document that conflicts -- and the 2026-10-30
# retarget below, which supersedes the spec wherever they disagree.
#
# THE TWO CHECKOUTS (2026-10-30). The live install (<home>/.claude/ccpraxis)
# is produced by scripts/promote.pl and nothing else, and only the dev clone
# talks to GitHub (plugins/steward/scripts/DevClone.pm has the model). So:
#   - the live install is READ ONLY here: its scripts run, its payload is the
#     baseline, its .backup-preferences.json holds this machine's answers. No
#     git verb that changes it is ever run against it.
#   - U0 locates the dev clone once (DevClone::locate: the live install's
#     origin, which promote.pl points at the dev clone) and checkpoints it as
#     'ccpraxis_target'. Not located -> the ccpraxis part of the backup is
#     skipped with a note saying why and how to fix it; the vault still syncs.
#   - U1 integrates origin/main into the DEV CLONE (origin is GitHub there).
#   - U2 decides whether exporting is safe and checkpoints 'export_target',
#     the one item the export phase reads: the dev clone must be on main and
#     its payload (working tree and HEAD) must equal the live install's
#     committed payload, or an export would overwrite payload changes that
#     were never promoted.
#   - the settings and marketplace diffs (U7/U8) and their writes (U9/U10)
#     run only when U2 said ready. W2 writes the dev clone's
#     known_marketplaces.json.
#
# THIS MODULE WRAPS EXISTING SCRIPTS. It reimplements none of their logic --
# no JSON diffing, no preference matching, no tree generation, no skill
# copying. Its job is ordering, exit-code interpretation, turning
# genuinely-undecided keys into decision records, applying saved
# preferences' effects silently, and checkpointing so an interrupted run
# does not redo finished work. The shared modules it needs (DevClone.pm,
# MachineLocalSettings.pm) are loaded from the live install's
# plugins/steward/scripts, the same tree every wrapped script runs from.
#
# Things it deliberately never does (Decision 4, Decision 6):
#   - it never invokes git's stashing subcommand -- a repo hook denies any
#     command whose text mentions it (guard-git-mutations.sh); a clean-tree
#     CHECK replaces it and a dirty tree becomes a decision instead. Every
#     git verb this module constructs is one of: rev-parse, remote, fetch,
#     status, rev-list, ls-tree, merge -- and merge only in the dev clone.
#   - it never aborts a merge it did not start: a merge already in progress
#     in the dev clone is reported and left alone.
#   - it never runs gen-readme-tree.pl in its write mode or its bootstrap
#     mode. Only the --check flag is ever passed.
#
# Ruling P1 (spec S8): this phase performs exactly two writes, and only for
# an explicitly ANSWERED decision -- never inferred, never defaulted:
#   W1 -- update <home>/.claude/settings.json when a settings_key decision
#         is answered 'use_repo' (diverged) or 'add_to_live' (only_right;
#         ruling P6 renamed this from 'keep_in_repo', which claimed the live file was left unchanged while writing it).
#         The payload stores the live install's own path as ${CCPRAXIS_LIVE};
#         W1 expands it through MachineLocalSettings and refuses to write if
#         the token survives anywhere, because Claude Code cannot resolve it
#         and every ccpraxis plugin would vanish.
#   W2 -- write the reconciled global-config/known_marketplaces.json in the
#         dev clone after answered marketplace_key decisions, stripping
#         installLocation AND lastUpdated from EVERY entry first (both are
#         machine-specific).
# Choices whose action is an instruction to a human (`remove_locally`,
# `use_repo` for a changed marketplace source) stay instructions: this
# module reports them for the operator, it never runs a `/plugin
# marketplace ...` command.
#
# MUST NOT use/require Run.pm (spec S2.0): everything this module needs
# arrives through $ctx, so `perl -c` is clean standalone and a test can copy
# this single file into a scratch BACKUP_PHASE_DIR.
#
# Fix-batch (consolidated red-team + reviewer findings, applied in one pass --
# see .ccpraxis-local-data/blueprints/backup-driver/reports/02-preflight-and-config/
# {redteam,reviewer}-step6.md for the full writeups):
#   B1 -- _write_json_file encoded without ->utf8 and printed to a :raw
#         handle, silently transcoding any non-ASCII byte to Latin-1. Fixed
#         by encoding with ->utf8.
#   B2 -- an unreadable/unparseable (as opposed to merely ABSENT) live file
#         was treated as {} and overwritten, destroying every key this run
#         never touched. _read_or_init_json_file now distinguishes the two
#         and a write is refused (unit failure) on the unreadable case.
#   B3 -- json-diff.pl emits dotted parent.child keys for a nested
#         divergence; W1 wrote them as a literal flat top-level key,
#         silently dropping the answered action and polluting the file.
#         _assign_nested now nests on the first '.' when the parent is
#         absent or already a hash.
#   B4 -- _write_json_file's die on an I/O failure had no eval at either
#         call site, escalating an ordinary environmental failure (a locked
#         file, a full disk) to phase_died (exit 1) for the WHOLE run.
#         Both call sites now eval it and degrade to a unit failure.
#   M1/P6 -- the 'use_repo'/'keep_in_repo' labels claimed "live left
#         unchanged" while the code writes live. Relabeled; the only_right
#         choice's canonical id is now 'add_to_live' (SKILL.md's own
#         wording). No alias is kept: this module has never shipped, so no paused run or caller can hold the old id, and registering both would show the operator two identical choices.
#   M2 -- 'origin/main' was hard-coded with no branch check at all, and an
#         undefined ahead-count fell through to an UNCONDITIONAL merge.
#         U1 now resolves the current branch and refuses to merge on a
#         detached HEAD, a non-main branch, or an undetermined ahead-count.
#   M3 -- a marketplace 'source' is an OBJECT in the real file; "$src" on a
#         hashref rendered "HASH(0x...)" into an operator-facing
#         instruction. _render_source now handles the object shape.

package Backup::Phase::Preflight;
use strict;
use warnings;
use JSON::PP;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Temp ();
use Cwd qw(abs_path);
use Encode ();

# ===========================================================================
# phase_spec / run_phase -- the contract packages 01+02 share (spec S2.1/S2.2)
# ===========================================================================

sub phase_spec {
    return {
        name      => 'preflight',
        order     => 100,   # spec S8 P2: preflight=100, export=200, vault=300, closeout=400
        resumable => 1,
        title     => 'Preflight: locate the dev clone, remote integration, docs lint, skills/CLAUDE.md, settings and marketplace diffs',
    };
}

sub run_phase {
    my ($ctx) = @_;

    my $home = $ENV{HOME};
    $home = $ENV{USERPROFILE} unless defined $home && length $home;
    unless (defined $home && length $home) {
        return { status => 'failed',
                 error  => 'ccpraxis install not found: neither HOME nor USERPROFILE is set' };
    }
    (my $home_n = $home) =~ s{\\}{/}g;
    $home_n =~ s{/+\z}{};
    # The live install: what runs, read only. promote.pl's --live default.
    my $root = "$home_n/.claude/ccpraxis";
    unless (-d $root) {
        return { status => 'failed', error => "ccpraxis install not found at $root" };
    }

    my @failed_units;   # [ unit_name, message ]
    my $record_failure = sub {
        my ($unit, $msg) = @_;
        return unless defined $msg;
        push @failed_units, [ $unit, $msg ];
        $ctx->{note}->('unit_failed', { unit => $unit, message => $msg });
    };

    my $load_err = _load_shared($root);

    # ---- U0: locate the dev clone, once (DevClone::locate) ----
    unless ($ctx->{is_done}->('ccpraxis_target')) {
        my $res = _do_u0($ctx, $root, $load_err);
        $record_failure->('ccpraxis_target', $res->{failed}) if $res->{failed};
    }
    my $target = $ctx->{get_item}->('ccpraxis_target');
    $target = {} unless ref($target) eq 'HASH';
    my $clone = $target->{located} ? $target->{dev_clone} : undef;

    # ---- U1: integrate origin/main into the DEV CLONE (Decision 6 clean-
    #      tree check; Decision 7 ordering -- must complete, unpaused, before
    #      ANY of U2-U10 run) ----
    unless ($ctx->{is_done}->('remote_integration')) {
        my $res = _do_u1($ctx, $clone);
        if ($res->{pause}) {
            return { status => 'needs_decision', decisions => [ $res->{pause} ] };
        }
        $record_failure->('remote_integration', $res->{failed}) if $res->{failed};
    }

    # ---- U2: is exporting into the dev clone safe? ----
    unless ($ctx->{is_done}->('export_target')) {
        _do_u2($ctx, $root, $target, $load_err);
    }
    my $export_target = $ctx->{get_item}->('export_target');
    my $ready = (ref($export_target) eq 'HASH' && $export_target->{ready}) ? 1 : 0;

    # ---- U3-U8: gather ONE batch of decisions (spec S2.5 barrier 3) ----
    my @batch;

    unless ($ctx->{is_done}->('readme_paths_lint')) {
        my $res = _do_u3($ctx, $root);
        push @batch, $res->{decision} if $res->{decision};
        $record_failure->('readme_paths_lint', $res->{failed}) if $res->{failed};
    }

    unless ($ctx->{is_done}->('repo_layout_tree')) {
        my $res = _do_u4($ctx, $root);
        push @batch, $res->{decision} if $res->{decision};
        $record_failure->('repo_layout_tree', $res->{failed}) if $res->{failed};
    }

    unless ($ctx->{is_done}->('sync_skills')) {
        my $res = _do_u5($ctx, $root);
        $record_failure->('sync_skills', $res->{failed}) if $res->{failed};
    }

    unless ($ctx->{is_done}->('check_claude_md')) {
        my $res = _do_u6($ctx, $root);
        $record_failure->('check_claude_md', $res->{failed}) if $res->{failed};
    }

    # The settings and marketplace comparisons exist to feed the export (and
    # W1/W2); with no export target they would ask questions nothing acts on.
    if ($ready) {
        unless ($ctx->{is_done}->('settings_diff')) {
            my $res = _do_u7($ctx, $root, $home_n, $clone);
            push @batch, _settings_decisions($ctx, $res->{data}) if $res->{data};
            $record_failure->('settings_diff', $res->{failed}) if $res->{failed};
        }

        unless ($ctx->{is_done}->('marketplace_diff')) {
            my $res = _do_u8($ctx, $root, $clone);
            push @batch, _marketplace_decisions($ctx, $res->{data}) if $res->{data};
            $record_failure->('marketplace_diff', $res->{failed}) if $res->{failed};
        }
    }

    if (@batch) {
        return { status => 'needs_decision', decisions => \@batch };
    }

    # ---- treat_as_failure effects for decisions with no dedicated outcome
    #      unit of their own (Decision 3 [docs drift]) ----
    for my $pair (
        [ 'preflight.readme_paths',          'README.md drift' ],
        [ 'preflight.repo_layout_tree',      'docs/repo-layout.md drift' ],
    ) {
        my ($id, $label) = @$pair;
        my $choice = $ctx->{answers}{$id};
        if (defined $choice && $choice eq 'treat_as_failure') {
            # N12 (MINOR): pushing directly onto @failed_units bypassed
            # $record_failure, so spec S2.7's "one unit_failed note per
            # failed unit" silently had three exceptions -- the failure
            # still reached the final error string, but the operator-facing
            # report material was missing it.
            $record_failure->($id, "$label: treat_as_failure");
        }
    }

    # ---- U9/U10: apply the answered outcomes (ruling P1 -- W1/W2 writes) ----
    my @all_prefs_saved;

    if ($ready) {
        unless ($ctx->{is_done}->('settings_outcome')) {
            my $res = _do_u9($ctx, $root, $home_n);
            push @all_prefs_saved, @{ $res->{prefs_saved} // [] };
            $record_failure->('settings_outcome', $res->{failed}) if $res->{failed};
        }

        unless ($ctx->{is_done}->('marketplace_outcome')) {
            my $res = _do_u10($ctx, $root, $clone);
            push @all_prefs_saved, @{ $res->{prefs_saved} // [] };
            $record_failure->('marketplace_outcome', $res->{failed}) if $res->{failed};
        }
    }

    $ctx->{note}->('preferences_saved', \@all_prefs_saved) if @all_prefs_saved;

    if (@failed_units) {
        my @names = map { $_->[0] } @failed_units;
        my $first = $failed_units[0][1];
        return { status => 'failed',
                 error  => 'preflight: ' . join(', ', @names) . " failed \x{2014} $first" };
    }

    return { status => 'complete' };
}

# ===========================================================================
# Shared modules, loaded from the live install (the tree the wrapped scripts
# run from). Returns undef on success, else why not.
# ===========================================================================
sub _load_shared {
    my ($root) = @_;
    my $dir = "$root/plugins/steward/scripts";
    for my $m (qw(MachineLocalSettings DevClone)) {
        next if $INC{"$m.pm"};
        return "$dir/$m.pm is missing" unless -f "$dir/$m.pm";
        local @INC = ($dir, @INC);
        my $ok = eval { require "$m.pm"; 1 };
        return "cannot load $dir/$m.pm: " . ($@ || 'unknown error') unless $ok;
    }
    return undef;
}

# DevClone's git-runner contract, over this module's own spawner.
sub _git_runner {
    return sub {
        my ($dir, @args) = @_;
        my $r = _git_capture($dir, @args);
        return ($r->{spawned} ? $r->{exit} : -1, $r->{out} // '', $r->{err} // '');
    };
}

# ===========================================================================
# U0 -- locate the dev clone. Never pauses. Checkpoints 'ccpraxis_target':
#   { live_root, dev_clone, located, source, origin, reason, fix }
# ===========================================================================
sub _do_u0 {
    my ($ctx, $root, $load_err) = @_;
    my $data;
    if (defined $load_err) {
        $data = { live_root => $root, dev_clone => undef, located => 0, source => undef, origin => undef,
                  reason => "the live install cannot locate the dev clone: $load_err",
                  fix    => 'promote from the dev clone (perl <dev clone>/scripts/promote.pl) so the live install carries the current backup scripts' };
    }
    else {
        my $loc = DevClone::locate(live_root => $root, override => $ENV{BACKUP_CLONE_DIR}, git => _git_runner());
        $data = { live_root => $root, dev_clone => $loc->{dev_clone},
                  located => defined $loc->{dev_clone} ? 1 : 0,
                  source => $loc->{source}, origin => $loc->{origin},
                  reason => $loc->{reason}, fix => $loc->{fix} };
    }
    $data = _sanitize_utf8($data);
    $ctx->{checkpoint}->('ccpraxis_target', $data);
    $ctx->{note}->('ccpraxis_target', $data);
    unless ($data->{located}) {
        $ctx->{note}->('ccpraxis_skipped', { reason => $data->{reason}, fix => $data->{fix} });
    }
    return defined $load_err ? { failed => $data->{reason} } : {};
}

# ===========================================================================
# U1 -- integrate origin/main into the dev clone. Returns one of:
#   { pause => $decision }            -- return needs_decision immediately
#   { failed => $msg }                -- (with done semantics) unit failure
#   {}                                 -- done, no failure
# Checkpoints 'remote_integration' and notes it on every path EXCEPT pause.
# Never touches the live install. Never touches the developer's uncommitted
# files: a dirty tree is a question, and a merge git refuses because it would
# overwrite them stops here with nothing changed.
# ===========================================================================
sub _do_u1 {
    my ($ctx, $clone) = @_;

    my $done = sub {
        my ($data, $ret) = @_;
        $data = _sanitize_utf8($data);
        $ctx->{checkpoint}->('remote_integration', $data);
        $ctx->{note}->('remote_integration', $data);
        return $ret // {};
    };

    unless (defined $clone) {
        return $done->(_u1_data(undef, 0, 0, 0, undef, 0, undef, 0, 0, 0, undef, undef, 'the dev clone was not located'));
    }

    my $probe = _git_capture($clone, 'rev-parse', '--is-inside-work-tree');
    unless ($probe->{spawned} && $probe->{exit} == 0) {
        return $done->(_u1_data($clone, 0, 0, 0, undef, 0, undef, 0, 0, 0, undef, undef, 'not a git repository'));
    }

    my $head_before = _git_head($clone);

    # A merge in progress. Resolve it only when it is this run's own (its
    # remote_merge_conflict decision has been answered); a merge the
    # developer has in progress is theirs to finish or abort. After a kill
    # mid-run the answer is gone too (R6), and the merge is left alone the
    # same way rather than aborted on a guess.
    if (_merge_in_progress($clone)) {
        if (defined $ctx->{answers}{'preflight.remote_merge_conflict'}) {
            return _u1_resolve_conflict($ctx, $clone, $head_before, undef, undef);
        }
        return $done->(_u1_data($clone, 1, 0, 0, undef, 0, undef, 0, 0, 0, $head_before, $head_before,
                                'a merge is already in progress in the dev clone'),
            { failed => "a merge is already in progress in the dev clone ($clone) that this backup did not start "
                      . '-- finish it or abort it there, then back up again' });
    }

    my $remote_list = _git_capture($clone, 'remote');
    my $has_origin = 0;
    if ($remote_list->{spawned} && $remote_list->{exit} == 0) {
        $has_origin = 1 if grep { $_ eq 'origin' } split(/\r?\n/, $remote_list->{out} // '');
    }
    unless ($has_origin) {
        return $done->(_u1_data($clone, 1, 0, 0, undef, 0, undef, 0, 0, 0, $head_before, $head_before, 'no origin remote'));
    }

    my $fetch = _git_capture($clone, 'fetch', 'origin');
    unless ($fetch->{spawned} && $fetch->{exit} == 0) {
        my $fetch_error = length($fetch->{err} // '') ? $fetch->{err}
                         : "git fetch exited " . ($fetch->{exit} // -1);
        # N9 (MINOR): git redacts a URL's password but not its userinfo
        # USERNAME, where a PAT is conventionally placed
        # (https://ghp_...@github.com/o/r.git). This is checkpointed to disk
        # and noted into the driver's stdout JSON -- redact before either.
        $fetch_error =~ s{://[^/\s@]*@}{://REDACTED@}g;
        return $done->(_u1_data($clone, 1, 1, 0, $fetch_error, 0, undef, 0, 0, 0, $head_before, $head_before, 'fetch failed'));
    }

    # M2 (MAJOR): 'origin/main' below is a hard-coded merge target. Resolve
    # the branch and refuse (skip, don't guess) unless it is genuinely 'main'
    # -- a developer on a feature branch must never get origin/main merged
    # into it by a backup.
    my $branch = _git_current_branch($clone);
    unless (defined $branch && $branch eq 'main') {
        my $reason = defined $branch ? "on branch '$branch', not 'main'" : 'detached HEAD';
        return $done->(_u1_data($clone, 1, 1, 1, undef, 0, undef, 0, 0, 0,
                                $head_before, $head_before, "$reason -- remote integration skipped"));
    }

    my $ahead = _git_capture($clone, 'rev-list', '--count', 'HEAD..origin/main');
    my $ahead_count;
    if ($ahead->{spawned} && $ahead->{exit} == 0) {
        (my $n = $ahead->{out} // '0') =~ s/\s+//g;
        # T2 (NIT): guard the numeric coercion.
        $ahead_count = $n + 0 if $n =~ /^\d+\z/;
    }
    unless (defined $ahead_count) {
        # M2 (MAJOR): a failed rev-list (no 'main' on the remote, ...) must
        # never fall through to an unconditional merge. Skip instead.
        return $done->(_u1_data($clone, 1, 1, 1, undef, 0, undef, 0, 0, 0,
                                $head_before, $head_before, 'cannot determine commits-ahead -- remote integration skipped'));
    }
    if ($ahead_count == 0) {
        return $done->(_u1_data($clone, 1, 1, 1, undef, 0, undef, 0, 1, 0, $head_before, $head_before, undef));
    }

    # Only now, with something to merge, does the dev clone's uncommitted
    # work matter: in a checkout someone develops in, a dirty tree is the
    # normal state, and asking about it when there is nothing to merge would
    # be a question on every backup. --untracked-files=no: an untracked file
    # is not "uncommitted work" a merge could overwrite.
    my $status = _git_capture($clone, 'status', '--porcelain', '--untracked-files=no');
    my @dirty_lines = grep { length $_ } split /\r?\n/, ($status->{out} // '');
    my $dirty_count = scalar(@dirty_lines);

    my $dirty_answer;
    if ($dirty_count > 0) {
        $dirty_answer = $ctx->{answers}{'preflight.dirty_worktree'};
        unless (defined $dirty_answer) {
            my $dec = $ctx->{decision}->(
                kind    => 'dirty_worktree',
                id      => 'preflight.dirty_worktree',
                title   => "the dev clone has $dirty_count uncommitted change(s) and origin/main has $ahead_count new commit(s)",
                subject => $clone,
                detail  => _clamp($status->{out} // ''),
                data    => { dirty_count => $dirty_count, ahead => $ahead_count },
                choices => [
                    { id => 'continue_without_merge',
                      label => 'Continue without merging (leave uncommitted changes untouched)' },
                    { id => 'merge_anyway',
                      label => 'Merge anyway (git refuses if it would overwrite local changes)' },
                ],
            );
            return { pause => $dec };
        }
        if ($dirty_answer eq 'continue_without_merge') {
            return $done->(_u1_data($clone, 1, 1, 1, undef, $dirty_count, $dirty_answer, 0, 0, 0,
                                    $head_before, $head_before, 'dirty worktree'));
        }
        # merge_anyway: fall through -- git itself refuses if the merge would
        # clobber a local change, and that refusal stops cleanly below.
    }

    return _u1_resolve_conflict($ctx, $clone, $head_before, $dirty_count, $dirty_answer);
}

# Shared by the fresh-attempt path and the "resuming mid-conflict" path.
sub _u1_resolve_conflict {
    my ($ctx, $clone, $head_before, $dirty_count, $dirty_answer) = @_;
    $dirty_count //= 0;

    my $done = sub {
        my ($data, $ret) = @_;
        $data = _sanitize_utf8($data);
        $ctx->{checkpoint}->('remote_integration', $data);
        $ctx->{note}->('remote_integration', $data);
        return $ret // {};
    };

    my $merge_answer = $ctx->{answers}{'preflight.remote_merge_conflict'};
    if (defined $merge_answer && _merge_in_progress($clone)) {
        if ($merge_answer eq 'abort_merge') {
            my $abort = _git_capture($clone, 'merge', '--abort');
            # N11 (MINOR): a refused abort must not be reported as a clean one.
            my $abort_ok = ($abort->{spawned} && $abort->{exit} == 0) ? 1 : 0;
            my $head_after = _git_head($clone);
            my $data = _u1_data($clone, 1, 1, 1, undef, $dirty_count, $dirty_answer, 0, 0, 0,
                                $head_before, $head_after, $abort_ok ? 'merge aborted' : 'merge abort failed');
            $data->{abort_failed} = $abort_ok ? 0 : 1;
            return $done->($data);
        }
        elsif ($merge_answer eq 'keep_conflict') {
            return $done->(_u1_data($clone, 1, 1, 1, undef, $dirty_count, $dirty_answer, 0, 0, 1,
                                    $head_before, $head_before, undef),
                { failed => 'remote_merge_conflict: kept unresolved in the dev clone for manual resolution' });
        }
    }

    my $merge = _git_capture($clone, 'merge', 'origin/main', '--no-edit');
    if ($merge->{spawned} && $merge->{exit} == 0) {
        my $head_after = _git_head($clone);
        return $done->(_u1_data($clone, 1, 1, 1, undef, $dirty_count, $dirty_answer, 1, 0, 0,
                                $head_before, $head_after, undef));
    }

    my $git_says = _clamp(($merge->{err} // '') . ($merge->{out} // ''));
    unless (_merge_in_progress($clone)) {
        # Refused before it started (local changes it would overwrite, a
        # staged index, ...): nothing changed, so there is nothing to abort.
        my $data = _u1_data($clone, 1, 1, 1, undef, $dirty_count, $dirty_answer, 0, 0, 0,
                            $head_before, _git_head($clone), 'git refused the merge; nothing was changed');
        $data->{merge_error} = $git_says;
        (my $first = $git_says) =~ s/\n.*//s;
        return $done->($data,
            { failed => "git refused to merge origin/main into the dev clone, nothing was changed: $first" });
    }

    my $dec = $ctx->{decision}->(
        kind    => 'remote_merge_conflict',
        id      => 'preflight.remote_merge_conflict',
        title   => 'merging origin/main into the dev clone conflicted',
        subject => $clone,
        detail  => $git_says,
        data    => { head_before => $head_before },
        choices => [
            { id => 'abort_merge',   label => 'Abort the merge and restore the pre-merge HEAD' },
            { id => 'keep_conflict', label => 'Keep the conflict on disk for manual resolution' },
        ],
    );
    return { pause => $dec };
}

sub _u1_data {
    my ($repo, $is_git_repo, $has_origin, $fetched, $fetch_error, $dirty_count, $dirty_answer,
        $merged, $up_to_date, $conflicted, $head_before, $head_after, $skipped_reason) = @_;
    return {
        repo => $repo, is_git_repo => $is_git_repo, has_origin => $has_origin, fetched => $fetched,
        fetch_error => $fetch_error, dirty_count => $dirty_count, dirty_answer => $dirty_answer,
        merged => $merged, up_to_date => $up_to_date, conflicted => $conflicted,
        head_before => $head_before, head_after => $head_after, skipped_reason => $skipped_reason,
    };
}

sub _merge_in_progress {
    my ($dir) = @_;
    my $r = _git_capture($dir, 'rev-parse', '-q', '--verify', 'MERGE_HEAD');
    return ($r->{spawned} && $r->{exit} == 0) ? 1 : 0;
}

# ===========================================================================
# U2 -- the export precondition. Never pauses, never fails the run: a "no"
# skips the ccpraxis export with a note naming why and the fix. Checkpoints
# 'export_target', the one item the export phase reads:
#   { ready, live_root, dev_clone, branch, payload_equal, differing, reason, fix }
# ===========================================================================
sub _do_u2 {
    my ($ctx, $root, $target, $load_err) = @_;
    my %d = (ready => 0, live_root => $root, dev_clone => $target->{dev_clone}, branch => undef,
             payload_equal => undef, differing => [], reason => undef, fix => undef);

    if (!$target->{located}) {
        $d{reason} = $target->{reason} // ($load_err ? "cannot locate the dev clone: $load_err" : 'the dev clone was not located');
        $d{fix}    = $target->{fix};
    }
    else {
        my $clone = $target->{dev_clone};
        my $branch = _git_current_branch($clone);
        $d{branch} = $branch;
        if (!defined $branch || $branch ne 'main') {
            $d{reason} = 'the dev clone is ' . (defined $branch ? "on branch '$branch'" : 'on a detached HEAD')
                       . ', not main';
            $d{fix}    = "check out main in the dev clone ($clone), then back up again";
        }
        else {
            my $pc = DevClone::payload_check(live_root => $root, dev_clone => $clone, git => _git_runner());
            if (defined $pc->{error}) {
                $d{reason} = $pc->{error};
                $d{fix}    = 'promote first (perl ' . DevClone::git_path($clone) . '/scripts/promote.pl), then back up';
            }
            elsif (!$pc->{equal}) {
                $d{payload_equal} = 0;
                $d{differing}     = $pc->{differing};
                $d{reason} = "the dev clone's payload differs from what the live install was promoted with, so "
                           . 'exporting would overwrite it: '
                           . join('; ', map { "$_->{path} ($_->{why})" } @{ $pc->{differing} });
                $d{fix}    = 'promote first (perl ' . DevClone::git_path($clone) . '/scripts/promote.pl), then back up;'
                           . ' an uncommitted change has to be committed (or discarded) before it can be promoted';
            }
            else {
                $d{payload_equal} = 1;
                $d{ready}         = 1;
            }
        }
    }

    my $data = _sanitize_utf8(\%d);
    $ctx->{checkpoint}->('export_target', $data);
    $ctx->{note}->('export_target', $data);
    # Not located was already noted as skipped by U0.
    if (!$data->{ready} && $target->{located}) {
        $ctx->{note}->('ccpraxis_skipped', { reason => $data->{reason}, fix => $data->{fix} });
    }
    return {};
}

# ===========================================================================
# U3 -- README path lint (README.md, via lint-readme-paths.pl).
# ===========================================================================
sub _do_u3 {
    my ($ctx, $root) = @_;

    my $r = _run_capture($^X, "$root/scripts/lint-readme-paths.pl");
    unless ($r->{spawned}) {
        return { failed => 'lint-readme-paths.pl failed to spawn' };
    }
    if ($r->{exit} == 0) {
        my $data = { exit => 0, drift => 0, file => 'README.md', message => '' };
        $ctx->{checkpoint}->('readme_paths_lint', $data);
        $ctx->{note}->('readme_paths_lint', $data);
        return {};
    }
    if ($r->{exit} == 1) {
        my $detail = _clamp($r->{err} // '');
        my @lines = grep { length $_ } split /\r?\n/, $detail;
        my $n = scalar(@lines);
        my $data = { exit => 1, drift => 1, file => 'README.md', message => $detail };
        $ctx->{checkpoint}->('readme_paths_lint', $data);
        $ctx->{note}->('readme_paths_lint', $data);
        my $dec = $ctx->{decision}->(
            kind    => 'readme_drift',
            id      => 'preflight.readme_paths',
            title   => "README.md references $n path(s) that do not exist on disk",
            subject => 'README.md',
            detail  => "$detail\n\n(lint-readme-paths.pl skips fenced code blocks; drift inside "
                     . "examples is invisible to this check.)",
            data    => { file => 'README.md' },
            choices => [
                { id => 'acknowledge',      label => 'Acknowledge the drift and continue' },
                { id => 'treat_as_failure', label => 'Treat this drift as a failure' },
            ],
        );
        return { decision => $dec };
    }
    return { failed => "lint-readme-paths.pl exited $r->{exit}" };
}

# ===========================================================================
# U4 -- repo-layout tree check (docs/repo-layout.md, via gen-readme-tree.pl
# --check). Never the write mode or the bootstrap mode, on any path.
# ===========================================================================
sub _do_u4 {
    my ($ctx, $root) = @_;

    my $r = _run_capture($^X, "$root/scripts/gen-readme-tree.pl", '--check');
    unless ($r->{spawned}) {
        return { failed => 'gen-readme-tree.pl failed to spawn' };
    }
    if ($r->{exit} == 0) {
        my $data = { exit => 0, drift => 0, file => 'docs/repo-layout.md', message => '' };
        $ctx->{checkpoint}->('repo_layout_tree', $data);
        $ctx->{note}->('repo_layout_tree', $data);
        return {};
    }
    if ($r->{exit} == 1) {
        my $detail = _clamp(($r->{out} // '') . ($r->{err} // ''));
        my $data = { exit => 1, drift => 1, file => 'docs/repo-layout.md', message => $detail };
        $ctx->{checkpoint}->('repo_layout_tree', $data);
        $ctx->{note}->('repo_layout_tree', $data);
        my $dec = $ctx->{decision}->(
            kind    => 'readme_drift',
            id      => 'preflight.repo_layout_tree',
            title   => 'docs/repo-layout.md file tree is stale',
            subject => 'docs/repo-layout.md',
            detail  => $detail,
            data    => { file => 'docs/repo-layout.md' },
            choices => [
                { id => 'acknowledge',      label => 'Acknowledge the drift and continue' },
                { id => 'treat_as_failure', label => 'Treat this drift as a failure' },
            ],
        );
        return { decision => $dec };
    }
    return { failed => "gen-readme-tree.pl exited $r->{exit}" };
}

# ===========================================================================
# U5 -- skills mirror (ccpraxis-helpers.pl sync-skills): the live install's
# skills, the ones that run, mirrored into ~/.claude/skills.
# ===========================================================================
sub _do_u5 {
    my ($ctx, $root) = @_;

    my $r = _run_capture($^X, "$root/plugins/steward/scripts/ccpraxis-helpers.pl", 'sync-skills', '--live-root', $root);
    unless ($r->{spawned}) {
        return { failed => 'ccpraxis-helpers.pl sync-skills failed to spawn' };
    }
    my $j = eval { decode_json($r->{out}) };
    unless (ref($j) eq 'HASH') {
        return { failed => 'ccpraxis-helpers.pl sync-skills produced unparseable output: '
                          . substr($r->{out} // '', 0, 200) };
    }
    $j = _sanitize_utf8($j);

    my $status  = $j->{status} // '';
    my @results = @{ $j->{results} // [] };

    if ($r->{exit} == 0 && $status eq 'ok') {
        my @changed = grep { ($_->{action} // '') ne 'unchanged' } @results;
        $ctx->{checkpoint}->('sync_skills', {
            status => $status, count => $j->{count}, changed => [ map { $_->{name} } @changed ], errors => [],
        });
        $ctx->{note}->('skills_synced', \@changed) if @changed;
        return {};
    }

    my @errors = grep { defined $_->{error} } @results;
    $ctx->{note}->('skills_errors', \@errors) if @errors;
    my $why = $status eq 'partial' ? 'partial sync' : "exited $r->{exit}";
    return { failed => "ccpraxis-helpers.pl sync-skills: $why" };
}

# ===========================================================================
# U6 -- CLAUDE.md check (ccpraxis-helpers.pl check-claude-md): ~/.claude/
# CLAUDE.md against what promote.pl builds for this host from the LIVE
# install's payload. Never a failure by itself (spec S2.8): flag prominently,
# never auto-fix. The export phase is where a difference becomes a question.
# ===========================================================================
sub _do_u6 {
    my ($ctx, $root) = @_;

    my $r = _run_capture($^X, "$root/plugins/steward/scripts/ccpraxis-helpers.pl", 'check-claude-md', '--live-root', $root);
    unless ($r->{spawned}) {
        return { failed => 'ccpraxis-helpers.pl check-claude-md failed to spawn' };
    }
    my $j = eval { decode_json($r->{out}) };
    unless (ref($j) eq 'HASH') {
        return { failed => 'ccpraxis-helpers.pl check-claude-md produced unparseable output: '
                          . substr($r->{out} // '', 0, 200) };
    }
    $j = _sanitize_utf8($j);

    my $status = $j->{status} // '';
    my %item = (status => $status, live => $j->{live}, repo => $j->{repo}, target => $j->{target},
                host_part => $j->{host_part}, reason => $j->{reason}, resolve => $j->{resolve});
    for my $k (qw(extra_lines missing_lines)) {
        my $l = ref($j->{$k}) eq 'ARRAY' ? $j->{$k} : [];
        $item{$k} = [ @$l > 50 ? @{$l}[0 .. 49] : @$l ];
        $item{"${k}_count"} = scalar(@$l);
    }
    $ctx->{checkpoint}->('check_claude_md', \%item);
    if ($status =~ /^(differs|symlinked_elsewhere|missing_live|missing_payload)$/) {
        $ctx->{note}->('claude_md_status', { status => $status, live => $j->{live}, repo => $j->{repo},
                                             extra_lines_count => $item{extra_lines_count} });
    }
    return {};
}

# ===========================================================================
# U7 -- settings diff (json-diff.pl piped into filter-diff.pl).
# ===========================================================================
sub _do_u7 {
    my ($ctx, $root, $home_n, $clone) = @_;

    my $live_settings = "$home_n/.claude/settings.json";
    # The export target's payload. U2 established that it equals the live
    # install's, so this is also what was promoted.
    my $repo_settings = "$clone/global-config/settings.json";

    # --host-live: compare as the payload applies to THIS machine -- its
    # ${CCPRAXIS_LIVE} marketplace path expanded to this live install, other
    # platforms' platform-only keys ignored (MachineLocalSettings.pm). Without
    # it every in-sync machine is asked about its own path on every backup.
    my $jd = _run_capture($^X, "$root/plugins/steward/scripts/json-diff.pl", '--host-live', $root, $live_settings, $repo_settings);
    unless ($jd->{spawned}) {
        return { failed => 'json-diff.pl failed to spawn' };
    }
    unless ($jd->{exit} == 0 || $jd->{exit} == 1) {
        return { failed => "json-diff.pl exited $jd->{exit}" };
    }
    my $jd_check = eval { decode_json($jd->{out}) };
    unless (ref($jd_check) eq 'HASH') {
        return { failed => 'json-diff.pl produced unparseable output: ' . substr($jd->{out} // '', 0, 200) };
    }

    my $prefs_path = "$root/.backup-preferences.json";
    my $fd = _run_with_stdin($jd->{out}, $^X, "$root/plugins/steward/scripts/filter-diff.pl",
        '--prefs', $prefs_path, '--scope', 'live_vs_repo');
    unless ($fd->{spawned}) {
        return { failed => 'filter-diff.pl failed to spawn' };
    }
    unless ($fd->{exit} == 0) {
        return { failed => "filter-diff.pl exited $fd->{exit}" };
    }
    my $fd_json = eval { decode_json($fd->{out}) };
    unless (ref($fd_json) eq 'HASH') {
        return { failed => 'filter-diff.pl produced unparseable output: ' . substr($fd->{out} // '', 0, 200) };
    }

    $fd_json = _sanitize_utf8($fd_json);
    $ctx->{checkpoint}->('settings_diff', $fd_json);
    my @auto = @{ $fd_json->{auto_applied} // [] };
    $ctx->{note}->('settings_auto_applied', \@auto) if @auto;

    return { data => $fd_json };
}

# ===========================================================================
# U8 -- marketplace diff (ccpraxis-helpers.pl marketplace-diff).
# ===========================================================================
sub _do_u8 {
    my ($ctx, $root, $clone) = @_;

    my $r = _run_capture($^X, "$root/plugins/steward/scripts/ccpraxis-helpers.pl", 'marketplace-diff',
        '--live-root', $root, '--repo', "$clone/global-config/known_marketplaces.json");
    unless ($r->{spawned}) {
        return { failed => 'ccpraxis-helpers.pl marketplace-diff failed to spawn' };
    }
    my $j = eval { decode_json($r->{out}) };
    unless (ref($j) eq 'HASH') {
        return { failed => 'ccpraxis-helpers.pl marketplace-diff produced unparseable output: '
                          . substr($r->{out} // '', 0, 200) };
    }
    unless ($r->{exit} == 0) {
        return { failed => "ccpraxis-helpers.pl marketplace-diff exited $r->{exit}" };
    }

    $j = _sanitize_utf8($j);
    $ctx->{checkpoint}->('marketplace_diff', $j);
    my @auto = @{ $j->{auto_applied} // [] };
    $ctx->{note}->('marketplace_auto_applied', \@auto) if @auto;

    return { data => $j };
}

# ===========================================================================
# U9 -- apply answered settings_key decisions. Ruling P1 W1: writes
# <home>/.claude/settings.json ONLY for keys answered 'use_repo' (diverged)
# or 'add_to_live' (only_right), and never with ${CCPRAXIS_LIVE} in it.
# ===========================================================================
sub _do_u9 {
    my ($ctx, $root, $home_n) = @_;

    my $diff = $ctx->{get_item}->('settings_diff');
    my @decisions = (ref($diff) eq 'HASH') ? _settings_decisions($ctx, $diff) : ();

    my (@skip_keys, @prefs_saved, @failed_msgs);
    my %answers_out;
    my %live_writes;
    my $prefs_path = "$root/.backup-preferences.json";

    for my $d (@decisions) {
        my $key    = $d->{data}{key};
        my $rel    = $d->{data}{relation};
        my $choice = $ctx->{answers}{ $d->{id} };
        next unless defined $choice;
        $answers_out{$key} = $choice;

        if ($choice eq 'use_repo' || $choice eq 'skip' || $choice =~ /_remember\z/) {
            push @skip_keys, $key;
        }

        if ($choice =~ /^keep_(different|live_only|repo_only)_remember\z/) {
            my %by_choice = (
                keep_different_remember  => [ 'diverged',   'skip-always' ],
                keep_live_only_remember  => [ 'only_left',  'left-only'   ],
                keep_repo_only_remember  => [ 'only_right', 'right-only'  ],
            );
            my ($category, $action) = @{ $by_choice{$choice} };
            my $sp = _run_capture($^X, "$root/plugins/steward/scripts/save-preference.pl",
                '--prefs', $prefs_path, '--scope', 'live_vs_repo', '--key', $key,
                '--category', $category, '--action', $action);
            if ($sp->{spawned} && $sp->{exit} == 0) {
                push @prefs_saved, { key => $key, category => $category, action => $action };
            }
            else {
                push @failed_msgs, "save-preference.pl for '$key'";
            }
        }

        if ($rel eq 'diverged' && $choice eq 'use_repo') {
            my $v = $d->{data}{value};
            $live_writes{$key} = (ref($v) eq 'HASH') ? ($v->{right} // $v->{repo}) : $v;
        }
        elsif ($rel eq 'only_right' && $choice eq 'add_to_live') {
            $live_writes{$key} = $d->{data}{value};
        }
    }

    if (%live_writes) {
        my $live_path = "$home_n/.claude/settings.json";
        # B2 (BLOCKER): "absent" (never seen a live settings.json) is safe to
        # start from {}; "present but unreadable/unparseable" is NOT the same
        # thing and must never be silently treated as {} -- that overwrote
        # the operator's ENTIRE live settings.json with only this run's
        # answered keys. Refuse the write instead; degrade the unit.
        my ($live_data, $read_err) = _read_or_init_json_file($live_path);
        if (defined $read_err) {
            push @failed_msgs, "settings_outcome: $read_err";
        }
        else {
            # B3 (BLOCKER): json-diff.pl emits dotted parent.child keys for a
            # nested divergence (env.FOO); writing that literally as a flat
            # top-level key both drops the answered action (live->{env}{FOO}
            # never changes) and pollutes the file with a key
            # json-diff.pl's own collision guard then trips on the next run.
            _assign_nested($live_data, $_, $live_writes{$_}) for keys %live_writes;
            # The payload spells the live install's own path ${CCPRAXIS_LIVE};
            # Claude Code cannot resolve that, and a settings.json carrying it
            # loses every ccpraxis plugin. Expand it to this live install, and
            # refuse the write outright if the token survives anywhere.
            my $token_err = _expand_live_token($live_data, $root);
            if (defined $token_err) {
                push @failed_msgs, "settings_outcome: refusing to write $live_path: $token_err";
            }
            else {
                # B4 (BLOCKER): _write_json_file dies on an I/O failure (locked
                # file, full disk, ...) -- an ordinary environmental condition
                # spec S2.2 forbids escalating to phase_died. Catch and degrade.
                my $ok = eval { _write_json_file($live_path, $live_data); 1 };
                push @failed_msgs, "settings_outcome: cannot write $live_path: $@" unless $ok;
            }
        }
    }

    $ctx->{checkpoint}->('settings_outcome', {
        skip_keys => \@skip_keys, preferences_saved => \@prefs_saved, answers => \%answers_out,
    });
    $ctx->{note}->('settings_skip_keys', \@skip_keys) if @skip_keys;

    my $ret = { prefs_saved => \@prefs_saved };
    $ret->{failed} = join('; ', @failed_msgs) if @failed_msgs;
    return $ret;
}

# _expand_live_token($settings, $live_root) -> undef | why the write must not
# happen. Expands ${CCPRAXIS_LIVE} wherever MachineLocalSettings honours it
# (a directory marketplace's path), then looks for the token in every string
# of the object, keys included: anywhere else it is unexpandable.
sub _expand_live_token {
    my ($settings, $root) = @_;
    return 'MachineLocalSettings.pm is not loaded, so ${CCPRAXIS_LIVE} cannot be expanded'
        unless defined &MachineLocalSettings::expand_live_root;
    MachineLocalSettings::expand_live_root($settings, $root);
    my $tok = MachineLocalSettings::LIVE_ROOT_TOKEN();
    my @where;
    my $walk;
    $walk = sub {
        my ($v, $path) = @_;
        if (ref($v) eq 'HASH') {
            for my $k (sort keys %$v) {
                push @where, "$path$k (key)" if index($k, $tok) >= 0;
                $walk->($v->{$k}, "$path$k.");
            }
        }
        elsif (ref($v) eq 'ARRAY') {
            $walk->($v->[$_], "$path$_.") for 0 .. $#$v;
        }
        elsif (defined $v && !ref($v) && index($v, $tok) >= 0) {
            (my $p = $path) =~ s/\.\z//;
            push @where, $p;
        }
    };
    $walk->($settings, '');
    return undef unless @where;
    return "an unexpanded $tok would be written at " . join(', ', @where);
}

# ===========================================================================
# U10 -- apply answered marketplace_key decisions. Ruling P1 W2: writes the
# reconciled global-config/known_marketplaces.json in the DEV CLONE,
# installLocation stripped
# from EVERY entry. "Remove locally" / "Use repo" (changed source) stay
# instructions -- this module never runs a /plugin marketplace command.
# ===========================================================================
sub _do_u10 {
    my ($ctx, $root, $clone) = @_;

    my $diff = $ctx->{get_item}->('marketplace_diff');
    my @decisions = (ref($diff) eq 'HASH') ? _marketplace_decisions($ctx, $diff) : ();

    my (@export_to_repo, @remove_from_repo, @use_live, @keep, @instructions, @prefs_saved, @failed_msgs, @wrote);
    my %answers_out;
    my %write_entries;
    my %remove_names;
    my $need_write = 0;
    my $prefs_path = "$root/.backup-preferences.json";

    my $save_pref = sub {
        my ($key, $category, $action) = @_;
        my $sp = _run_capture($^X, "$root/plugins/steward/scripts/save-preference.pl",
            '--prefs', $prefs_path, '--scope', 'marketplaces', '--key', $key,
            '--category', $category, '--action', $action);
        if ($sp->{spawned} && $sp->{exit} == 0) {
            push @prefs_saved, { key => $key, category => $category, action => $action };
        }
        else {
            push @failed_msgs, "save-preference.pl for '$key'";
        }
    };

    for my $d (@decisions) {
        my $key    = $d->{data}{key};
        my $cat    = $d->{data}{category};
        my $choice = $ctx->{answers}{ $d->{id} };
        next unless defined $choice;
        $answers_out{$key} = $choice;

        if ($cat eq 'live_only') {
            if ($choice eq 'export_to_repo') {
                push @export_to_repo, $key;
                $write_entries{$key} = $d->{data}{entry};
                $need_write = 1;
            }
            elsif ($choice eq 'keep_live_only_remember') {
                $save_pref->($key, 'only_left', 'left-only');
            }
            elsif ($choice eq 'remove_locally') {
                # N14 (MINOR): $key originates in a third party's
                # marketplace.json (via known_marketplaces.json); sanitise
                # before it lands in an instruction the wrapping LLM is told
                # to relay to the operator verbatim.
                my $safe_key = _title_key($key);
                push @instructions, { name => $safe_key, command => "/plugin marketplace remove $safe_key",
                    reason => 'this marketplace exists locally (live) but not in the repo' };
            }
            elsif ($choice eq 'skip') { push @keep, $key; }
        }
        elsif ($cat eq 'repo_only') {
            if ($choice eq 'add_locally') {
                my $src = _render_source($d->{data}{entry} && $d->{data}{entry}{source});
                push @instructions, { name => $key, command => "/plugin marketplace add $src",
                    reason => 'this marketplace exists in the repo but not locally' };
            }
            elsif ($choice eq 'keep_repo_only_remember') {
                $save_pref->($key, 'only_right', 'right-only');
            }
            elsif ($choice eq 'remove_from_repo') {
                push @remove_from_repo, $key;
                $remove_names{$key} = 1;
                $need_write = 1;
            }
            elsif ($choice eq 'skip') { push @keep, $key; }
        }
        else {   # diverged
            if ($choice eq 'use_live') {
                push @use_live, $key;
                $write_entries{$key} = $d->{data}{live};
                $need_write = 1;
            }
            elsif ($choice eq 'use_repo') {
                my $src = _render_source($d->{data}{repo} && $d->{data}{repo}{source});
                push @instructions, { name => $key, command => "/plugin marketplace add $src",
                    reason => 're-add locally to match the repo entry' };
            }
            elsif ($choice eq 'keep_different_remember') {
                $save_pref->($key, 'diverged', 'skip-always');
            }
            elsif ($choice eq 'skip') { push @keep, $key; }
        }
    }

    if ($need_write) {
        # The dev clone's copy: the export target, never the live install.
        my $relpath    = 'global-config/known_marketplaces.json';
        my $known_path = "$clone/$relpath";
        # B2 (BLOCKER): same absent-vs-unreadable distinction as W1 -- an
        # unreadable/unparseable repo file must not be silently replaced
        # with {} and overwritten.
        my ($known, $read_err) = _read_or_init_json_file($known_path);
        if (defined $read_err) {
            push @failed_msgs, "marketplace_outcome: $read_err";
        }
        else {
            for my $name (keys %write_entries) {
                my $e = $write_entries{$name};
                if (ref($e) eq 'HASH') {
                    $known->{$name} = { %$e };
                }
                else {
                    # N15 (MINOR): a malformed entry must never silently
                    # replace a real repo marketplace entry with {} --
                    # fail closed instead (record, skip this one entry).
                    push @failed_msgs, "marketplace_outcome: malformed entry for '$name', not written";
                }
            }
            delete $known->{$_} for keys %remove_names;
            for my $k (keys %$known) {
                next unless ref($known->{$k}) eq 'HASH';
                delete $known->{$k}{installLocation};
                delete $known->{$k}{lastUpdated};   # T1: also machine-specific (a refresh timestamp)
            }
            # B4 (BLOCKER): degrade on a write I/O failure, never die.
            my $ok = eval { _write_json_file($known_path, $known); 1 };
            if ($ok) { push @wrote, $relpath; }
            else     { push @failed_msgs, "marketplace_outcome: cannot write $known_path: $@"; }
        }
    }

    $ctx->{checkpoint}->('marketplace_outcome', {
        export_to_repo => \@export_to_repo, remove_from_repo => \@remove_from_repo,
        use_live => \@use_live, keep => \@keep, instructions => \@instructions,
        preferences_saved => \@prefs_saved, answers => \%answers_out,
        # Repo-relative paths written into the dev clone, so the export phase
        # commits exactly what this run wrote and nothing else.
        wrote => \@wrote,
    });
    $ctx->{note}->('marketplace_instructions', \@instructions) if @instructions;

    my $ret = { prefs_saved => \@prefs_saved };
    $ret->{failed} = join('; ', @failed_msgs) if @failed_msgs;
    return $ret;
}

# ===========================================================================
# Decision builders (settings_key / marketplace_key) -- pure functions of
# the checkpointed diff data, so U9/U10 can regenerate the SAME ids
# deterministically on a later call without re-running the wrapped scripts.
# ===========================================================================

sub _settings_items_ordered {
    my ($diff) = @_;
    my $nd = (ref($diff) eq 'HASH' && ref($diff->{needs_decision}) eq 'HASH') ? $diff->{needs_decision} : {};
    my @items;
    for my $rel (qw(diverged only_left only_right)) {
        my $group = $nd->{$rel};
        next unless ref($group) eq 'HASH';
        for my $k (sort keys %$group) {
            push @items, { key => $k, relation => $rel, value => $group->{$k} };
        }
    }
    return @items;
}

sub _settings_title {
    my ($key, $rel) = @_;
    my $kd = _title_key($key);
    return "settings key '$kd' differs between live and repo"   if $rel eq 'diverged';
    return "settings key '$kd' exists only in live"             if $rel eq 'only_left';
    return "settings key '$kd' exists only in the repo"         if $rel eq 'only_right';
    return "settings key '$kd'";
}

sub _settings_choices {
    my ($rel) = @_;
    # M1/P6 (MAJOR): both these choices' code path writes
    # <home>/.claude/settings.json (U9's W1) -- the OLD labels claimed "live
    # left unchanged", the exact opposite of what answering them does. Both
    # relabeled to say plainly that live IS updated.
    return [
        { id => 'use_live',                label => 'Use the live value' },
        { id => 'use_repo',                label => 'Use the repo value (updates your live settings.json)' },
        { id => 'keep_different_remember', label => 'Keep both different, remember' },
        { id => 'skip',                    label => 'Skip (ask again next run)' },
    ] if $rel eq 'diverged';
    return [
        { id => 'export_to_repo',          label => 'Export the live-only key to the repo' },
        { id => 'keep_live_only_remember', label => 'Keep live-only, remember' },
        { id => 'skip',                    label => 'Skip (ask again next run)' },
    ] if $rel eq 'only_left';
    return [
        # Canonical id, matching SKILL.md's own "Add to live" wording.
        { id => 'add_to_live',             label => 'Add the repo value to your live settings.json' },
        { id => 'keep_repo_only_remember', label => 'Keep repo-only, remember' },
        { id => 'skip',                    label => 'Skip (ask again next run)' },
    ] if $rel eq 'only_right';
    return [];
}

sub _settings_decisions {
    my ($ctx, $diff) = @_;
    my @items = _settings_items_ordered($diff);
    return () unless @items;
    my @pairs = _mint_ids('preflight.settings', map { $_->{key} } @items);
    my @decisions;
    for my $i (0 .. $#items) {
        my ($key, $id) = @{ $pairs[$i] };
        my $it  = $items[$i];
        my $rel = $it->{relation};
        push @decisions, $ctx->{decision}->(
            kind    => 'settings_key',
            id      => $id,
            title   => _settings_title($key, $rel),
            subject => $key,
            detail  => '',
            data    => { key => $key, relation => $rel, value => $it->{value} },
            choices => _settings_choices($rel),
        );
    }
    return @decisions;
}

sub _marketplace_items_ordered {
    my ($diff) = @_;
    return () unless ref($diff) eq 'HASH';
    my @items;
    for my $it (@{ $diff->{live_only} // [] }) {
        push @items, { key => $it->{name}, category => 'live_only', raw => $it };
    }
    for my $it (@{ $diff->{repo_only} // [] }) {
        push @items, { key => $it->{name}, category => 'repo_only', raw => $it };
    }
    for my $it (@{ $diff->{diverged} // [] }) {
        push @items, { key => $it->{name}, category => 'diverged', raw => $it };
    }
    return @items;
}

sub _entry_data {
    my ($item) = @_;
    return {} unless ref($item) eq 'HASH';
    if (ref($item->{entry}) eq 'HASH') {
        return { %{ $item->{entry} } };
    }
    my %d = %$item;
    delete $d{name};
    delete $d{category};
    return \%d;
}

sub _marketplace_decisions {
    my ($ctx, $diff) = @_;
    my @items = _marketplace_items_ordered($diff);
    return () unless @items;
    my @pairs = _mint_ids('preflight.marketplace', map { $_->{key} } @items);
    my @decisions;
    for my $i (0 .. $#items) {
        my ($key, $id) = @{ $pairs[$i] };
        my $it  = $items[$i];
        my $cat = $it->{category};
        my $kd  = _title_key($key);
        my ($title, $choices, $data);
        if ($cat eq 'live_only') {
            $title   = "marketplace '$kd' exists only locally (live), not in the repo";
            $data    = { key => $key, category => $cat, entry => _entry_data($it->{raw}) };
            $choices = [
                { id => 'export_to_repo',          label => 'Export to the repo' },
                { id => 'keep_live_only_remember', label => 'Keep live-only, remember' },
                { id => 'remove_locally',          label => 'Remove it locally' },
                { id => 'skip',                    label => 'Skip' },
            ];
        }
        elsif ($cat eq 'repo_only') {
            $title   = "marketplace '$kd' exists only in the repo, not locally";
            $data    = { key => $key, category => $cat, entry => _entry_data($it->{raw}) };
            $choices = [
                { id => 'add_locally',             label => 'Add it locally' },
                { id => 'keep_repo_only_remember', label => 'Keep repo-only, remember' },
                { id => 'remove_from_repo',        label => 'Remove it from the repo' },
                { id => 'skip',                    label => 'Skip' },
            ];
        }
        else {
            $title   = "marketplace '$kd' differs between live and the repo";
            $data    = { key => $key, category => $cat,
                         live => (ref($it->{raw}{live}) eq 'HASH' ? $it->{raw}{live} : {}),
                         repo => (ref($it->{raw}{repo}) eq 'HASH' ? $it->{raw}{repo} : {}) };
            $choices = [
                { id => 'use_live',                label => 'Use the live entry' },
                { id => 'use_repo',                label => 'Use the repo entry' },
                { id => 'keep_different_remember', label => 'Keep different, remember' },
                { id => 'skip',                    label => 'Skip' },
            ];
        }
        push @decisions, $ctx->{decision}->(
            kind => 'marketplace_key', id => $id, title => $title, subject => $key,
            detail => '', data => $data, choices => $choices,
        );
    }
    return @decisions;
}

# id sanitisation + collision suffixing (spec S2.6): every character outside
# [A-Za-z0-9_.:-] -> '_'; a second colliding id in ascending-input-order gets
# '.2', a third '.3', etc.
sub _mint_ids {
    my ($prefix, @keys) = @_;
    # N7 (MINOR): tracking by BASE id let a minted '.2' suffix collide with a
    # base id minted from a key that itself contains literal ".2" (e.g.
    # "permissions.allow/x" -> "...allow_x.2" collided with the base id for
    # "permissions.allow_x.2"). Track EMITTED ids instead, so a collision on
    # an already-suffixed id keeps incrementing rather than silently
    # reusing one.
    my %used;
    my @out;
    for my $k (@keys) {
        (my $san = $k) =~ s/[^A-Za-z0-9_.:-]/_/g;
        $san = '_' unless length $san;
        my $base_id = "$prefix.$san";
        my $id = $base_id;
        my $n = 1;
        while ($used{$id}++) {
            $n++;
            $id = "$base_id.$n";
        }
        push @out, [ $k, $id ];
    }
    return @out;
}

# Display-only truncation for a title (subject/data.key keep the full,
# unsanitised key). Also collapses whitespace so an embedded newline in a
# key can never make Backup::Run::validate_decision's single-line rule die.
sub _title_key {
    my ($k) = @_;
    my $t = $k;
    $t =~ s/\s+/ /g;
    $t = substr($t, 0, 80) . "\x{2026}" if length($t) > 80;
    return $t;
}

# M3 (MAJOR): a marketplace 'source' is an OBJECT in the real
# known_marketplaces.json (e.g. { repo => "...", source => "github" }),
# never a bare string -- confirmed from this repo's own tracked
# global-config/known_marketplaces.json. "$src" on a hashref interpolates
# "HASH(0x...)" into an instruction the operator is told to run verbatim,
# defeating ruling P1 bound 3 (instructions must stay something the operator
# can actually act on). Prefer the {repo} field (the form
# "/plugin marketplace add owner/repo" actually accepts); fall back to a
# JSON rendering of the whole object for any other shape, so the operator
# at least sees real data instead of a Perl reference.
sub _render_source {
    my ($src) = @_;
    return '' unless defined $src;
    if (ref($src) eq 'HASH') {
        return _title_key($src->{repo}) if defined $src->{repo} && length $src->{repo};
        my $j = eval { encode_json($src) };
        return defined $j ? _title_key($j) : '';
    }
    return _title_key("$src");
}

# ===========================================================================
# Child-spawning helpers (spec S2.4) -- list form only, never a shell
# string, never a pipe. Real File::Temp FILES for stderr/stdin capture,
# never an in-memory scalar (Git-for-Windows "Bad file descriptor").
# MSYS2_ARG_CONV_EXCL is scoped to the single spawn, paired with
# _native_path() hand-translation, per CLAUDE.md's MSYS2 landmine writeup.
# ===========================================================================

sub _native_path {
    my ($p) = @_;
    return $p unless defined $p;
    (my $q = $p) =~ s{\\}{/}g;
    $q =~ s{^/([A-Za-z])/}{\u$1:/};
    return $q;
}

sub _run_capture {
    my (@cmd) = @_;

    my ($efh, $ename) = File::Temp::tempfile(UNLINK => 1);
    close $efh;
    # N8 (MINOR): a STDERR dup/redirect failure is an ORDINARY environmental
    # condition (a exhausted fd table, e.g.), and spec S2.2 forbids letting
    # one die -- that would escape run_phase's eval and abort the whole run
    # (phase_died) instead of degrading this one unit. Degrade to "could not
    # spawn" instead.
    my $saved_stderr;
    unless (open($saved_stderr, '>&', \*STDERR)) {
        unlink $ename;
        return { out => '', err => '', exit => -1, spawned => 0 };
    }
    unless (open(STDERR, '>', $ename)) {
        close $saved_stderr;
        unlink $ename;
        return { out => '', err => '', exit => -1, spawned => 0 };
    }

    my $out = '';
    my $exit = -1;
    my $spawned = 0;
    my $ok = open(my $fh, '-|', @cmd);
    if ($ok) {
        $spawned = 1;
        local $/;
        $out = <$fh>;
        $out = '' unless defined $out;
        close $fh;
        $exit = $? >> 8;
    }

    open(STDERR, '>&', $saved_stderr) or warn "Preflight: cannot restore STDERR: $!\n";
    close $saved_stderr;

    my $err = '';
    if (open my $rfh, '<:raw', $ename) {
        local $/;
        $err = <$rfh> // '';
        close $rfh;
    }
    unlink $ename;

    return { out => $out, err => $err, exit => $exit, spawned => $spawned };
}

sub _run_with_stdin {
    my ($stdin_content, @cmd) = @_;

    my ($ifh, $iname) = File::Temp::tempfile(UNLINK => 1);
    binmode $ifh;
    print {$ifh} $stdin_content;
    close $ifh;

    # N8 (MINOR): same rule as _run_capture above -- degrade, never die.
    my $saved_stdin;
    unless (open($saved_stdin, '<&', \*STDIN)) {
        unlink $iname;
        return { out => '', err => '', exit => -1, spawned => 0 };
    }
    unless (open(STDIN, '<', $iname)) {
        close $saved_stdin;
        unlink $iname;
        return { out => '', err => '', exit => -1, spawned => 0 };
    }

    my $result = _run_capture(@cmd);

    open(STDIN, '<&', $saved_stdin) or warn "Preflight: cannot restore STDIN: $!\n";
    close $saved_stdin;
    unlink $iname;

    return $result;
}

sub _git_capture {
    my ($root, @args) = @_;
    local $ENV{GIT_TERMINAL_PROMPT} = '0';
    # Scoped here, not in the generic _run_capture: this call hands a
    # hand-translated Windows-style path (_native_path) straight to the
    # native git.exe, so disabling MSYS's own POSIX->Windows argv rewrite
    # is correct and paired, per CLAUDE.md's MSYS2 landmine writeup.
    # _run_capture's OTHER callers spawn $^X (a perl SCRIPT), which may
    # itself shell out to git with an unqualified POSIX path relying on
    # that same rewrite (gen-readme-tree.pl's `git -C $REPO_ROOT`, e.g.) --
    # setting the exclusion there too would leak into that grandchild spawn
    # and break it (verified: reproduces the exact "fatal: cannot change to
    # '/c/...': No such file or directory" from bug report 20260922-211319).
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*' if $^O =~ /^(MSWin32|cygwin|msys)$/;
    return _run_capture('git', '-C', _native_path($root), @args);
}

sub _git_head {
    my ($dir) = @_;
    my $r = _git_capture($dir, 'rev-parse', 'HEAD');
    return undef unless $r->{spawned} && $r->{exit} == 0;
    (my $h = $r->{out} // '') =~ s/\s+\z//;
    return length($h) ? $h : undef;
}


# M2 (MAJOR): the branch check that never existed before this fix-batch --
# 'HEAD' means detached (rev-parse --abbrev-ref's own literal answer for
# that case); an unspawned/failed probe returns undef, which the caller
# treats identically to "not main" (skip, never guess).
sub _git_current_branch {
    my ($dir) = @_;
    my $r = _git_capture($dir, 'rev-parse', '--abbrev-ref', 'HEAD');
    return undef unless $r->{spawned} && $r->{exit} == 0;
    (my $b = $r->{out} // '') =~ s/\s+\z//;
    return undef unless length($b);
    return undef if $b eq 'HEAD';
    return $b;
}

# UTF-8 discipline helpers -- duplicated from Export.pm/Closeout.pm VERBATIM,
# as Closeout.pm's header explains (no shared helper module).
#
# decode_json() widens every non-ASCII string it returns, and neither the
# run-state writer (Run.pm) nor backup.pl's stdout encoder uses ->utf8, so a
# widened string reaching $ctx is written as a lone Latin-1 byte. That is how
# U5's skills_synced note put "Andr\xE9" into backup.pl's stdout, which a
# strict UTF-8 reader rejects whole (bug 20261026-020158-c0c2). Every
# decode_json() result that reaches a note or checkpoint is downgraded to raw
# UTF-8 bytes here first.
sub _ensure_utf8_bytes {
    my ($s) = @_;
    return $s unless defined $s;
    return Encode::encode('UTF-8', $s) if utf8::is_utf8($s);
    my $probe = $s;
    return $s if eval { Encode::decode('UTF-8', $probe, Encode::FB_CROAK()); 1 };
    return Encode::encode('UTF-8', Encode::decode('ISO-8859-1', $s));
}

sub _sanitize_utf8 {
    my ($v) = @_;
    my $ref = ref($v);
    if ($ref eq 'HASH')  { return { map { _sanitize_utf8($_) => _sanitize_utf8($v->{$_}) } keys %$v }; }
    if ($ref eq 'ARRAY') { return [ map { _sanitize_utf8($_) } @$v ]; }
    if ($ref eq '')      { return _ensure_utf8_bytes($v); }
    return $v;   # JSON::PP::Boolean or any other blessed ref -- pass through
}

# N10 (MINOR)/N2 (NIT): U3 already clamped its captured detail at 4000
# chars; U1's dirty/conflict detail and U4's did not, so a large repo-layout
# diff or a crafted git/script output was copied unbounded into EVERY
# subsequent checkpoint write. Trim on a byte boundary that cannot split a
# UTF-8 multi-byte sequence (a raw substr can, if the text ever carries
# non-ASCII -- e.g. a path under C:\Users\Andr\x{e9}).
sub _clamp {
    my ($s, $max) = @_;
    $max //= 4000;
    return $s unless defined $s && length($s) > $max;
    my $t = substr($s, 0, $max);
    $t =~ s/[\x80-\xBF]+\z//;
    return $t;
}

# ===========================================================================
# Small JSON file helpers (W1 / W2 writes only -- everything else this
# module reads is read via a wrapped script, never parsed directly by us).
# ===========================================================================

# B2 (BLOCKER): the old _read_json_file returned undef for THREE different
# conditions -- absent, unopenable, unparseable -- and every W1/W2 caller
# could not tell them apart, so it treated all three as "start from {}" and
# then overwrote the file with only this run's keys. Proven: an 80-byte
# settings.json with one stray trailing comma became an 18-byte stub.
# "Absent" (the file has never existed) is the ONLY case safe to start from
# {}; "exists but unreadable/unparseable" must refuse the write entirely.
# Returns ($data, $error): on success $data is always a HASHREF (possibly
# freshly {}) and $error is undef; on failure $data is undef and $error
# names what went wrong, so the caller can degrade the unit instead of
# silently destroying the file.
sub _read_or_init_json_file {
    my ($path) = @_;
    return ({}, undef) unless -f $path;
    open my $fh, '<:raw', $path or return (undef, "cannot open $path: $!");
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $data = eval { decode_json($raw) };
    return (undef, "cannot parse $path as JSON: " . ($@ || 'unknown error')) unless ref($data) eq 'HASH';
    return ($data, undef);
}

# B3 (BLOCKER): json-diff.pl emits dotted parent.child keys for a nested
# hash divergence (json-diff.pl:129-148; ccpraxis-helpers.pl's
# merge_export_level mirrors the same depth-1 model). Writing such a key as
# a literal flat top-level key silently drops the answered action AND
# pollutes the file with a key a later real json-diff.pl run's own
# collision guard then trips on. Nest on the first '.' when the parent slot
# is absent (create it) or already a hash; otherwise fall back to a flat
# write (the collision case the guard describes).
sub _assign_nested {
    my ($data, $key, $value) = @_;
    if ($key =~ /^([^.]+)\.(.+)\z/ && (!exists $data->{$1} || ref($data->{$1}) eq 'HASH')) {
        $data->{$1} = {} unless ref($data->{$1}) eq 'HASH';
        $data->{$1}{$2} = $value;
    }
    else {
        $data->{$key} = $value;
    }
}

sub _write_json_file {
    my ($path, $data) = @_;
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
    # B1 (BLOCKER): JSON::PP::encode WITHOUT ->utf8 returns a CHARACTER
    # string; printing that to a :raw handle serialises every character
    # below U+0100 as a single Latin-1 BYTE. Proven: a live settings.json
    # containing "C:/Users/Andr\x{e9}/x" (this host's OWN home is
    # C:\Users\Andr\x{e9}) came back with 0xE9 as a lone byte -- not valid
    # UTF-8 -- after a single W1 write. ->utf8 makes encode() return
    # well-formed UTF-8 BYTES, which is what a :raw handle is for. Matches
    # the pattern ccpraxis-helpers.pl's write_json_file_atomic already uses.
    my $json = JSON::PP->new->utf8->canonical->pretty->encode($data);
    # T3 (NIT): File::Temp in the SAME directory (rather than a hand-built
    # "$path.tmp.$$") means a kill between open and rename cannot litter the
    # operator's .claude/ with a permanent stray -- File::Temp's own default
    # cleanup (or, at worst, an obviously-named tmp file) applies.
    my ($fh, $tmp) = File::Temp::tempfile('preflight-write-XXXXXXXX', DIR => $dir, UNLINK => 0);
    binmode $fh;
    print {$fh} $json;
    close $fh;
    # B4 (BLOCKER): this used to die with no eval at either W1/W2 call site,
    # so an ordinary environmental write failure (locked file, full disk, a
    # non-empty path occupying the destination) escalated past run_phase's
    # eval to phase_died (exit 1) for the WHOLE run instead of degrading
    # just this one unit. Both call sites now wrap this call in eval; die
    # here still exists (a caller needs a $@ to report), but it is always
    # caught one frame up.
    unless (rename $tmp, $path) {
        my $err = $!;
        unlink $tmp;
        die "Preflight: cannot rename $tmp -> $path: $err\n";
    }
    return 1;
}

1;
