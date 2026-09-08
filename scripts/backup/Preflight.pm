# Preflight.pm -- backup driver phase 02-preflight-and-config (blueprint
# backup-driver).
#
# Absorbs today's SKILL.md Steps 1 (remote integration), 1.2 (README path
# lint + repo-layout tree check) and 1.5 (skills mirror, CLAUDE.md check,
# settings diff, marketplace diff), plus the clone/live divergence report
# Decision 4 requires that no step performs today. See the spec for the full
# contract:
#   .ccpraxis-local-data/blueprints/backup-driver/specs/02-preflight-and-config-spec.md
# including its BINDING coordinator rulings (S8, P1-P5), which supersede
# anything earlier in that document that conflicts.
#
# THIS MODULE WRAPS EXISTING SCRIPTS. It reimplements none of their logic --
# no JSON diffing, no preference matching, no tree generation, no skill
# copying. Its job is ordering, exit-code interpretation, turning
# genuinely-undecided keys into decision records, applying saved
# preferences' effects silently, and checkpointing so an interrupted run
# does not redo finished work.
#
# Three things it deliberately never does (Decision 4, Decision 6):
#   - it never invokes git's stashing subcommand -- a repo hook denies any
#     command whose text mentions it (guard-git-mutations.sh); a clean-tree
#     CHECK replaces it and a dirty tree becomes a decision instead. Every
#     git verb this module constructs is one of: rev-parse, remote, fetch,
#     status, rev-list, merge, merge-base -- nothing that mutates history
#     beyond an explicitly-answered merge/merge --abort.
#   - it never acts on clone/live divergence: no promotion, pull, copy or
#     push, under either answer.
#   - it never runs gen-readme-tree.pl in its write mode or its bootstrap
#     mode. Only the --check flag is ever passed.
#
# Ruling P1 (spec S8): this phase performs exactly two writes, and only for
# an explicitly ANSWERED decision -- never inferred, never defaulted:
#   W1 -- update <home>/.claude/settings.json when a settings_key decision
#         is answered 'use_repo' (diverged) or 'add_to_live' (only_right;
#         ruling P6 renamed this from 'keep_in_repo', which claimed the live file was left unchanged while writing it).
#   W2 -- write the reconciled global-config/known_marketplaces.json after
#         answered marketplace_key decisions, stripping installLocation AND
#         lastUpdated from EVERY entry first (both are machine-specific).
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
#   M4 -- _resolve_clone_dir was two dirnames short of the module's real
#         depth (<clone>/scripts/backup/Preflight.pm needs three) --
#         production could never auto-detect a dev clone.
#   M5/P7 -- --untracked-files=no correctly scopes the clean-tree check, but
#         left untracked files invisible before package 03's `git add -A`.
#         U1 now emits an 'untracked_files' NOTE (never a decision).

package Backup::Phase::Preflight;
use strict;
use warnings;
use JSON::PP;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Temp ();
use Cwd qw(abs_path);

# ===========================================================================
# phase_spec / run_phase -- the contract packages 01+02 share (spec S2.1/S2.2)
# ===========================================================================

sub phase_spec {
    return {
        name      => 'preflight',
        order     => 100,   # spec S8 P2: preflight=100, export=200, vault=300, closeout=400
        resumable => 1,
        title     => 'Preflight: remote integration, docs lint, skills/CLAUDE.md, settings and marketplace diffs',
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

    # ---- U1: remote integration (Decision 6 clean-tree check; Decision 7
    #      ordering -- must complete, unpaused, before ANY of U2-U10 run) ----
    unless ($ctx->{is_done}->('remote_integration')) {
        my $res = _do_u1($ctx, $root);
        if ($res->{pause}) {
            return { status => 'needs_decision', decisions => [ $res->{pause} ] };
        }
        $record_failure->('remote_integration', $res->{failed}) if $res->{failed};
    }

    # ---- U2-U8: gather ONE batch of decisions (spec S2.5 barrier 3) ----
    my @batch;

    unless ($ctx->{is_done}->('clone_live')) {
        my $res = _do_u2($ctx, $root);
        push @batch, $res->{decision} if $res->{decision};
        $record_failure->('clone_live', $res->{failed}) if $res->{failed};
    }

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

    unless ($ctx->{is_done}->('settings_diff')) {
        my $res = _do_u7($ctx, $root, $home_n);
        push @batch, _settings_decisions($ctx, $res->{data}) if $res->{data};
        $record_failure->('settings_diff', $res->{failed}) if $res->{failed};
    }

    unless ($ctx->{is_done}->('marketplace_diff')) {
        my $res = _do_u8($ctx, $root);
        push @batch, _marketplace_decisions($ctx, $res->{data}) if $res->{data};
        $record_failure->('marketplace_diff', $res->{failed}) if $res->{failed};
    }

    if (@batch) {
        return { status => 'needs_decision', decisions => \@batch };
    }

    # ---- treat_as_failure effects for decisions with no dedicated outcome
    #      unit of their own (Decision 4, Decision 3 [docs drift]) ----
    for my $pair (
        [ 'preflight.clone_live_divergence', 'clone/live divergence' ],
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

    unless ($ctx->{is_done}->('settings_outcome')) {
        my $res = _do_u9($ctx, $root, $home_n);
        push @all_prefs_saved, @{ $res->{prefs_saved} // [] };
        $record_failure->('settings_outcome', $res->{failed}) if $res->{failed};
    }

    unless ($ctx->{is_done}->('marketplace_outcome')) {
        my $res = _do_u10($ctx, $root);
        push @all_prefs_saved, @{ $res->{prefs_saved} // [] };
        $record_failure->('marketplace_outcome', $res->{failed}) if $res->{failed};
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
# U1 -- remote integration. Returns one of:
#   { pause => $decision }            -- return needs_decision immediately
#   { failed => $msg }                -- (with done semantics) unit failure
#   {}                                 -- done, no failure
# Checkpoints 'remote_integration' and notes it on every path EXCEPT pause.
# ===========================================================================
sub _do_u1 {
    my ($ctx, $root) = @_;

    my $probe = _git_capture($root, 'rev-parse', '--is-inside-work-tree');
    unless ($probe->{spawned} && $probe->{exit} == 0) {
        my $data = _u1_data($root, 0, 0, 0, undef, 0, undef, 0, 0, 0, undef, undef, 'not a git repository');
        $ctx->{checkpoint}->('remote_integration', $data);
        $ctx->{note}->('remote_integration', $data);
        return {};
    }

    my $head_before = _git_head($root);

    # M5/P7 (MAJOR): a note, unconditionally, whenever this unit actually
    # executes -- regardless of remote/dirty outcome below. --untracked-
    # files=no (further down) correctly scopes the CLEAN-TREE check to
    # tracked changes, but that leaves untracked files with zero operator
    # visibility right before package 03's `git add -A` (SKILL.md:299)
    # sweeps and pushes them. This is report material, not a decision --
    # consent to commit belongs to package 03.
    my $untracked_status = _git_capture($root, 'status', '--porcelain', '--untracked-files=all');
    my @untracked_files;
    for my $line (split /\r?\n/, ($untracked_status->{out} // '')) {
        push @untracked_files, $1 if $line =~ /^\?\?\s+(.*)$/;
    }
    $ctx->{note}->('untracked_files', { count => scalar(@untracked_files), files => \@untracked_files })
        if @untracked_files;

    # Resuming mid-conflict from an earlier attempt in this same run: route
    # straight to conflict resolution, skipping remote/fetch/dirty/ahead --
    # `git status --porcelain` during a live conflict would otherwise look
    # "dirty" and wrongly re-trigger the dirty_worktree question.
    if (-f "$root/.git/MERGE_HEAD") {
        return _u1_resolve_conflict($ctx, $root, $head_before, undef, undef);
    }

    my $remote_list = _git_capture($root, 'remote');
    my $has_origin = 0;
    if ($remote_list->{spawned} && $remote_list->{exit} == 0) {
        $has_origin = 1 if grep { $_ eq 'origin' } split(/\r?\n/, $remote_list->{out} // '');
    }
    unless ($has_origin) {
        my $data = _u1_data($root, 1, 0, 0, undef, 0, undef, 0, 0, 0, $head_before, $head_before, 'no origin remote');
        $ctx->{checkpoint}->('remote_integration', $data);
        $ctx->{note}->('remote_integration', $data);
        return {};
    }

    my $fetch = _git_capture($root, 'fetch', 'origin');
    my $fetched = ($fetch->{spawned} && $fetch->{exit} == 0) ? 1 : 0;
    unless ($fetched) {
        my $fetch_error = length($fetch->{err} // '') ? $fetch->{err}
                         : "git fetch exited " . ($fetch->{exit} // -1);
        # N9 (MINOR): git redacts a URL's password but not its userinfo
        # USERNAME, where a PAT is conventionally placed
        # (https://ghp_...@github.com/o/r.git). This is checkpointed to disk
        # and noted into the driver's stdout JSON -- redact before either.
        $fetch_error =~ s{://[^/\s@]*@}{://REDACTED@}g;
        my $data = _u1_data($root, 1, 1, 0, $fetch_error, 0, undef, 0, 0, 0, $head_before, $head_before, 'fetch failed');
        $ctx->{checkpoint}->('remote_integration', $data);
        $ctx->{note}->('remote_integration', $data);
        return {};
    }

    # --untracked-files=no matches the scope of the blocked shelving command
    # this check replaces (its plain, no-flags form never touches untracked
    # files either) -- a brand-new untracked file is not "uncommitted work"
    # in the sense Decision 6 protects, only a modification to something
    # already tracked is.
    my $status = _git_capture($root, 'status', '--porcelain', '--untracked-files=no');
    my @dirty_lines = grep { length $_ } split /\r?\n/, ($status->{out} // '');
    my $dirty_count = scalar(@dirty_lines);

    my $dirty_answer;
    if ($dirty_count > 0) {
        $dirty_answer = $ctx->{answers}{'preflight.dirty_worktree'};
        unless (defined $dirty_answer) {
            my $dec = $ctx->{decision}->(
                kind    => 'dirty_worktree',
                id      => 'preflight.dirty_worktree',
                title   => "the ccpraxis repo has $dirty_count uncommitted change(s)",
                subject => $root,
                detail  => _clamp($status->{out} // ''),
                data    => { dirty_count => $dirty_count },
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
            my $data = _u1_data($root, 1, 1, 1, undef, $dirty_count, $dirty_answer, 0, 0, 0,
                                 $head_before, $head_before, 'dirty worktree');
            $ctx->{checkpoint}->('remote_integration', $data);
            $ctx->{note}->('remote_integration', $data);
            return {};
        }
        # merge_anyway: fall through to the ahead-check/merge below with the
        # tree still dirty -- git itself refuses if it would clobber local
        # changes, and that refusal becomes the remote_merge_conflict path.
    }

    # M2 (MAJOR): 'origin/main' below is a hard-coded merge target, and
    # nothing checked what branch is actually checked out -- an operator on
    # a feature branch, or left on a detached HEAD, would silently get
    # origin/main merged into whatever they had checked out. Resolve the
    # branch and refuse (skip, don't guess) unless it is genuinely 'main'.
    my $branch = _git_current_branch($root);
    unless (defined $branch && $branch eq 'main') {
        my $reason = defined $branch ? "on branch '$branch', not 'main'" : 'detached HEAD';
        my $data = _u1_data($root, 1, 1, 1, undef, $dirty_count, $dirty_answer, 0, 0, 0,
                             $head_before, $head_before, "$reason -- remote integration skipped");
        $ctx->{checkpoint}->('remote_integration', $data);
        $ctx->{note}->('remote_integration', $data);
        return {};
    }

    my $ahead = _git_capture($root, 'rev-list', '--count', 'HEAD..origin/main');
    my $ahead_count;
    if ($ahead->{spawned} && $ahead->{exit} == 0) {
        (my $n = $ahead->{out} // '0') =~ s/\s+//g;
        # T2 (NIT): guard the numeric coercion -- an unexpected rev-list
        # stdout otherwise warns "Argument isn't numeric" to the driver's
        # real STDERR (Run.pm redirects the phase's STDOUT only, not STDERR).
        $ahead_count = $n + 0 if $n =~ /^\d+\z/;
    }

    if (defined $ahead_count && $ahead_count == 0) {
        my $data = _u1_data($root, 1, 1, 1, undef, $dirty_count, $dirty_answer, 0, 1, 0,
                             $head_before, $head_before, undef);
        $ctx->{checkpoint}->('remote_integration', $data);
        $ctx->{note}->('remote_integration', $data);
        return {};
    }

    unless (defined $ahead_count) {
        # M2 (MAJOR): a failed rev-list (no 'main' on the remote, not yet
        # fetched, ...) left $ahead_count undef, and control fell through to
        # an UNCONDITIONAL merge attempt whose failure was then presented as
        # a remote_merge_conflict that never actually happened. Skip instead.
        my $data = _u1_data($root, 1, 1, 1, undef, $dirty_count, $dirty_answer, 0, 0, 0,
                             $head_before, $head_before, 'cannot determine commits-ahead -- remote integration skipped');
        $ctx->{checkpoint}->('remote_integration', $data);
        $ctx->{note}->('remote_integration', $data);
        return {};
    }

    return _u1_resolve_conflict($ctx, $root, $head_before, $dirty_count, $dirty_answer);
}

# Shared by the fresh-attempt path and the "resuming mid-conflict" path.
sub _u1_resolve_conflict {
    my ($ctx, $root, $head_before, $dirty_count, $dirty_answer) = @_;
    $dirty_count //= 0;

    my $merge_answer = $ctx->{answers}{'preflight.remote_merge_conflict'};
    if (defined $merge_answer) {
        if ($merge_answer eq 'abort_merge') {
            my $abort = _git_capture($root, 'merge', '--abort');
            # N11 (MINOR): the abort's exit was previously discarded, so a
            # refused (not conflicted) merge -- no MERGE_HEAD to abort --
            # was reported as a clean 'merge aborted' when it did nothing.
            my $abort_ok = ($abort->{spawned} && $abort->{exit} == 0) ? 1 : 0;
            my $head_after = _git_head($root);
            my $data = _u1_data($root, 1, 1, 1, undef, $dirty_count, $dirty_answer, 0, 0, 0,
                                 $head_before, $head_after, $abort_ok ? 'merge aborted' : 'merge abort failed');
            $data->{abort_failed} = $abort_ok ? 0 : 1;
            $ctx->{checkpoint}->('remote_integration', $data);
            $ctx->{note}->('remote_integration', $data);
            return {};
        }
        elsif ($merge_answer eq 'keep_conflict') {
            my $data = _u1_data($root, 1, 1, 1, undef, $dirty_count, $dirty_answer, 0, 0, 1,
                                 $head_before, $head_before, undef);
            $ctx->{checkpoint}->('remote_integration', $data);
            $ctx->{note}->('remote_integration', $data);
            return { failed => 'remote_merge_conflict: kept unresolved for manual resolution' };
        }
    }

    my $merge = _git_capture($root, 'merge', 'origin/main', '--no-edit');
    if ($merge->{spawned} && $merge->{exit} == 0) {
        my $head_after = _git_head($root);
        my $data = _u1_data($root, 1, 1, 1, undef, $dirty_count, $dirty_answer, 1, 0, 0,
                             $head_before, $head_after, undef);
        $ctx->{checkpoint}->('remote_integration', $data);
        $ctx->{note}->('remote_integration', $data);
        return {};
    }

    my $dec = $ctx->{decision}->(
        kind    => 'remote_merge_conflict',
        id      => 'preflight.remote_merge_conflict',
        title   => 'merging origin/main into the ccpraxis repo conflicted',
        subject => $root,
        detail  => _clamp(($merge->{err} // '') . ($merge->{out} // '')),
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

# ===========================================================================
# U2 -- clone/live divergence (Decision 4: detect and report, never act).
# ===========================================================================
sub _do_u2 {
    my ($ctx, $root) = @_;

    my $clone_dir = _resolve_clone_dir($root);
    unless (defined $clone_dir) {
        my $data = { checked => 0, clone_dir => undef, clone_head => undef, live_head => undef, relation => undef };
        $ctx->{checkpoint}->('clone_live', $data);
        $ctx->{note}->('clone_live', $data);
        return {};
    }

    my $live_head  = _git_head($root);
    my $clone_head = _git_head($clone_dir);
    unless (defined $live_head && defined $clone_head) {
        my $data = { checked => 1, clone_dir => $clone_dir, clone_head => $clone_head,
                     live_head => $live_head, relation => 'unknown' };
        $ctx->{checkpoint}->('clone_live', $data);
        $ctx->{note}->('clone_live', $data);
        return {};
    }

    my $relation;
    if ($clone_head eq $live_head) {
        $relation = 'identical';
    }
    else {
        my $clone_ahead = _is_ancestor($clone_dir, $live_head, $clone_head);
        my $live_ahead  = _is_ancestor($clone_dir, $clone_head, $live_head);
        $relation = $clone_ahead ? 'clone_ahead' : $live_ahead ? 'live_ahead' : 'unrelated';
    }

    my $data = { checked => 1, clone_dir => $clone_dir, clone_head => $clone_head,
                 live_head => $live_head, relation => $relation };
    $ctx->{checkpoint}->('clone_live', $data);
    $ctx->{note}->('clone_live', $data);

    return {} if $relation eq 'identical';

    my $dec = $ctx->{decision}->(
        kind    => 'clone_live_divergence',
        id      => 'preflight.clone_live_divergence',
        title   => 'the dev clone and the live install are at different commits',
        subject => $clone_dir,
        detail  => "clone HEAD $clone_head vs. live HEAD $live_head (relation: $relation)",
        data    => { checked => 1, clone_dir => $clone_dir, clone_head => $clone_head,
                     live_head => $live_head, relation => $relation },
        choices => [
            { id => 'acknowledge',      label => 'Acknowledge and continue' },
            { id => 'treat_as_failure', label => 'Treat the divergence as a failure' },
        ],
    );
    return { decision => $dec };
}

sub _resolve_clone_dir {
    my ($root) = @_;

    my $env_dir = $ENV{BACKUP_CLONE_DIR};
    if (defined $env_dir && length $env_dir) {
        (my $n = $env_dir) =~ s{\\}{/}g;
        $n =~ s{/+\z}{};
        return $n if -d "$n/.git";
    }

    # M4 (MAJOR): the module lives at <clone>/scripts/backup/Preflight.pm.
    # Two dirnames from the full path (including the filename) land on
    # <clone>/scripts, which never contains .git -- three are needed to
    # reach <clone> itself. With the old two-dirname math this rule-2
    # fallback could never locate a real dev clone in production; only the
    # undocumented BACKUP_CLONE_DIR override worked.
    my $self_dir;
    eval {
        # Normalise separators BEFORE deriving the directory: abs_path can return
        # a backslashed path on Windows and dirname does not split on backslashes.
        # Enforced by plugins/butler/tests/t/93-turn-cap-consistency.t (C9).
        (my $self = __FILE__) =~ s{\\}{/}g;
        my $abs = abs_path($self) // $self;
        $abs =~ s{\\}{/}g;
        $self_dir = dirname(dirname(dirname($abs)));
    };
    if (defined $self_dir && -d "$self_dir/.git") {
        my $norm_root = $root; $norm_root =~ s{/+\z}{};
        return $self_dir if $self_dir ne $norm_root;
    }

    return undef;
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
# U5 -- skills mirror (ccpraxis-helpers.pl sync-skills).
# ===========================================================================
sub _do_u5 {
    my ($ctx, $root) = @_;

    my $r = _run_capture($^X, "$root/plugins/steward/scripts/ccpraxis-helpers.pl", 'sync-skills');
    unless ($r->{spawned}) {
        return { failed => 'ccpraxis-helpers.pl sync-skills failed to spawn' };
    }
    my $j = eval { decode_json($r->{out}) };
    unless (ref($j) eq 'HASH') {
        return { failed => 'ccpraxis-helpers.pl sync-skills produced unparseable output: '
                          . substr($r->{out} // '', 0, 200) };
    }

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
# U6 -- CLAUDE.md check (ccpraxis-helpers.pl check-claude-md). Never a
# failure by itself (spec S2.8): flag prominently, never auto-fix.
# ===========================================================================
sub _do_u6 {
    my ($ctx, $root) = @_;

    my $r = _run_capture($^X, "$root/plugins/steward/scripts/ccpraxis-helpers.pl", 'check-claude-md');
    unless ($r->{spawned}) {
        return { failed => 'ccpraxis-helpers.pl check-claude-md failed to spawn' };
    }
    my $j = eval { decode_json($r->{out}) };
    unless (ref($j) eq 'HASH') {
        return { failed => 'ccpraxis-helpers.pl check-claude-md produced unparseable output: '
                          . substr($r->{out} // '', 0, 200) };
    }

    my $status = $j->{status} // '';
    $ctx->{checkpoint}->('check_claude_md', {
        status => $status, live => $j->{live}, repo => $j->{repo}, target => $j->{target},
    });
    if ($status =~ /^(differs|symlinked_elsewhere|missing_live|missing_repo)$/) {
        $ctx->{note}->('claude_md_status', { status => $status, live => $j->{live}, repo => $j->{repo} });
    }
    return {};
}

# ===========================================================================
# U7 -- settings diff (json-diff.pl piped into filter-diff.pl).
# ===========================================================================
sub _do_u7 {
    my ($ctx, $root, $home_n) = @_;

    my $live_settings = "$home_n/.claude/settings.json";
    my $repo_settings = "$root/global-config/settings.json";

    my $jd = _run_capture($^X, "$root/plugins/steward/scripts/json-diff.pl", $live_settings, $repo_settings);
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

    $ctx->{checkpoint}->('settings_diff', $fd_json);
    my @auto = @{ $fd_json->{auto_applied} // [] };
    $ctx->{note}->('settings_auto_applied', \@auto) if @auto;

    return { data => $fd_json };
}

# ===========================================================================
# U8 -- marketplace diff (ccpraxis-helpers.pl marketplace-diff).
# ===========================================================================
sub _do_u8 {
    my ($ctx, $root) = @_;

    my $r = _run_capture($^X, "$root/plugins/steward/scripts/ccpraxis-helpers.pl", 'marketplace-diff');
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

    $ctx->{checkpoint}->('marketplace_diff', $j);
    my @auto = @{ $j->{auto_applied} // [] };
    $ctx->{note}->('marketplace_auto_applied', \@auto) if @auto;

    return { data => $j };
}

# ===========================================================================
# U9 -- apply answered settings_key decisions. Ruling P1 W1: writes
# <home>/.claude/settings.json ONLY for keys answered 'use_repo' (diverged)
# or 'add_to_live' (only_right).
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
            # B4 (BLOCKER): _write_json_file dies on an I/O failure (locked
            # file, full disk, ...) -- an ordinary environmental condition
            # spec S2.2 forbids escalating to phase_died. Catch and degrade.
            my $ok = eval { _write_json_file($live_path, $live_data); 1 };
            push @failed_msgs, "settings_outcome: cannot write $live_path: $@" unless $ok;
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

# ===========================================================================
# U10 -- apply answered marketplace_key decisions. Ruling P1 W2: writes the
# reconciled global-config/known_marketplaces.json, installLocation stripped
# from EVERY entry. "Remove locally" / "Use repo" (changed source) stay
# instructions -- this module never runs a /plugin marketplace command.
# ===========================================================================
sub _do_u10 {
    my ($ctx, $root) = @_;

    my $diff = $ctx->{get_item}->('marketplace_diff');
    my @decisions = (ref($diff) eq 'HASH') ? _marketplace_decisions($ctx, $diff) : ();

    my (@export_to_repo, @remove_from_repo, @use_live, @keep, @instructions, @prefs_saved, @failed_msgs);
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
        my $known_path = "$root/global-config/known_marketplaces.json";
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
            push @failed_msgs, "marketplace_outcome: cannot write $known_path: $@" unless $ok;
        }
    }

    $ctx->{checkpoint}->('marketplace_outcome', {
        export_to_repo => \@export_to_repo, remove_from_repo => \@remove_from_repo,
        use_live => \@use_live, keep => \@keep, instructions => \@instructions,
        preferences_saved => \@prefs_saved, answers => \%answers_out,
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
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*' if $^O =~ /^(MSWin32|cygwin|msys)$/;

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
    return _run_capture('git', '-C', _native_path($root), @args);
}

sub _git_head {
    my ($dir) = @_;
    my $r = _git_capture($dir, 'rev-parse', 'HEAD');
    return undef unless $r->{spawned} && $r->{exit} == 0;
    (my $h = $r->{out} // '') =~ s/\s+\z//;
    return length($h) ? $h : undef;
}

sub _is_ancestor {
    my ($dir, $ancestor, $descendant) = @_;
    return 0 unless defined $ancestor && defined $descendant;
    my $r = _git_capture($dir, 'merge-base', '--is-ancestor', $ancestor, $descendant);
    return ($r->{spawned} && $r->{exit} == 0) ? 1 : 0;
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
