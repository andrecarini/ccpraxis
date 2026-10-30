# Export.pm -- backup driver phase 03-export-and-push (blueprint
# backup-driver).
#
# Absorbs today's SKILL.md Steps 2 (detect differences), 3 (handle each
# file + settings merge), 3.5 (container settings sync), 4 (sensitive-data
# scan) and 5 (commit; the push moved to /steward:upstream-sync on
# 2026-10-30). See the spec for the original contract:
#   .ccpraxis-local-data/blueprints/backup-driver/specs/03-export-and-push-spec.md
# including its BINDING coordinator rulings (S8, P10-P12), which supersede
# anything earlier in that document that conflicts -- and the 2026-10-30
# retarget below, which supersedes the spec wherever they disagree.
#
# THIS MODULE WRAPS EXISTING SCRIPTS. It reimplements none of their logic --
# no JSON diffing, no preference matching, no merge algorithm, no secret
# scanning. Its job is ordering, exit-code interpretation, turning
# genuinely-undecided things into decision records, applying answered
# choices, checkpointing so an interrupted run does not redo finished work,
# and making a mid-commit death safe.
#
# THE TWO CHECKOUTS (2026-10-30; plugins/steward/scripts/DevClone.pm has the
# model). The live install (<home>/.claude/ccpraxis) is produced by promote.pl
# alone and is only READ here: the wrapped scripts run from it, and its
# .backup-preferences.json holds this machine's answers. EVERY WRITE AND EVERY
# GIT OPERATION TARGETS THE DEV CLONE: the export goes into its working tree,
# and only the files this run wrote are committed there (never `git add -A`,
# never the developer's other changes or untracked files). Then the dev
# clone's promote.pl fast-forwards the live install to that commit, so a run
# ends with the live install at the dev clone's main and ~/.claude consistent
# with the payload. Nothing here talks to a remote: fetching, integrating and
# pushing are /steward:upstream-sync's. Which dev clone, and whether exporting
# into it is safe at all, is decided ONCE by the preflight phase and read here
# from its 'export_target' checkpoint; anything but a ready target skips this
# whole phase (status 'skipped') with the reason.
#
# Ruling R6 (01-driver-skeleton-spec.md S8) wipes a phase's stored
# answers/items on re-entry after a "running" (mid-execution kill) prior
# status. So this module never trusts its own state to know whether the
# commit already happened after a crash; it asks GIT, in the dev clone: the
# units re-run (each is idempotent: the merge writes the same file again),
# nothing is pending, and the export commit the interrupted run made is what
# U9 finds between the live install and the dev clone's main -- and promotes.
# See _do_commit / _do_promote_after_commit.
#
# Ruling P10 (spec S8): sync-export.pl's real emitted status set is
# {claude_md_differs, export_only, identical, linked, live_only, missing,
# not_linked, settings_changed, tracked}. This module branches on the REAL
# set; an unrecognised status is a reported unit failure, never silently
# ignored. ~/.claude/CLAUDE.md is built by promote.pl from the live install's
# payload, so a difference there (claude_md_differs) cannot be exported -- a
# line carries no record of which part it came from -- and becomes a
# claude_md_drift decision: rebuild it (after a backup copy) or leave it, with
# the differing lines shown and the instruction to fold them into the dev
# clone's payload by hand. Any other differing regular file (not_linked, or
# the never-emitted 'conflict') is a file_conflict decision.
#
# Ruling P11: the skip-keys handoff from package 02 is read via
# $ctx->{get_phase_item}->('preflight', 'settings_outcome') -- never by
# parsing the run-state file directly (Decision 10). Three defensive cases
# (the accessor missing from $ctx, returning undef, or returning a
# malformed skip_keys) all fail closed: the merge is not run, and the unit
# degrades rather than silently passing zero skip-keys (SKILL.md:209 -- a
# silently-empty skip-key list would push an only_left key into the repo,
# or overwrite a diverged one with the live value).
#
# Ruling P12 records that Step 3's "Merge" choice is deliberately narrowed:
# a deterministic driver cannot fabricate a merged file, so the third
# choice becomes merge_manually -- the driver writes nothing and reports
# both paths for a human to reconcile. See reports/parity/03-export-and-push.md.
#
# Decision 10: the decision-kind enum is CLOSED. This module emits exactly
# four kinds: file_conflict, claude_md_drift, container_settings_key,
# sensitive_finding. The commit and the promotion after it are deterministic
# and ask nothing.
#
# Decision 7 barriers, enforced in code (not prose):
#   B1 -- the container diff (U5/U6) does not run unless settings_merge
#         (U4) checkpointed (on either its success path or its
#         nothing-to-merge path). A failed U4 leaves the key unset, so U5/U6
#         are skipped this pass.
#   B2 -- no git verb of any kind is spawned until sensitive_scan (U7)
#         checkpoints clean. U8/U9 are both gated on is_done('sensitive_scan').
#   B3 -- sensitive_finding is never batched with anything else (returned
#         alone, immediately).
#
# This module must never depend on package 01's engine module or its
# sibling (spec S2.0): everything this
# module needs arrives through $ctx, so `perl -c` is clean standalone and a
# test can copy this single file into a scratch BACKUP_PHASE_DIR. The small
# helpers below duplicated from Preflight.pm (_native_path, _run_capture,
# _run_with_stdin, _read_or_init_json_file, _assign_nested, _write_json_file,
# _clamp, _mint_ids, _title_key) are duplicated DELIBERATELY -- Decision 9
# makes the write sets disjoint, and a shared helper module is not in
# anyone's write set.
#
# The four blockers package 02 shipped with, and how this module avoids
# each (full detail: spec S2.10):
#   1. Latin-1 JSON corruption -- every JSON file THIS module writes
#      (container settings.json) goes through _write_json_file, which
#      encodes with ->utf8->canonical->pretty and prints to a binmode
#      handle, then File::Temp + rename in the destination directory.
#   2. Absent vs unreadable vs unparseable -- _read_or_init_json_file
#      distinguishes them; only "absent" may seed an empty structure. A
#      write is refused (the unit degrades) on any read error, so a
#      malformed container settings.json is never overwritten.
#   3. Dotted keys -- json-diff.pl/filter-diff.pl emit parent.child keys;
#      writes use _assign_nested (nest on first '.'), deletes use the
#      mirror-image _delete_nested (remove only the leaf, never the whole
#      parent object).
#   4. die on an environmental condition -- nothing in this module dies on
#      a spawn failure, a read failure or a write failure; every such path
#      returns { failed => $msg } and the run_phase loop degrades that one
#      unit rather than aborting the whole run. die is reserved for a
#      programming error ($ctx misuse), which package 01 turns into
#      phase_died correctly.

package Backup::Phase::Export;
use strict;
use warnings;
use JSON::PP;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Temp ();
use Cwd qw(abs_path);
use Encode ();
use B ();

# ===========================================================================
# phase_spec / run_phase -- the contract package 01 (Run.pm) requires.
# ===========================================================================

sub phase_spec {
    return {
        name      => 'export',
        order     => 200,   # spec S8 P2: preflight=100, export=200, vault=300, closeout=400
        resumable => 1,
        title     => 'Export: into the dev clone -- file differences, settings merge, container settings, sensitive scan, commit, promote',
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
    # backup.pl's own stdout JSON encoder (Run.pm's contract, spec S2.6) is
    # JSON::PP->new->canonical->encode WITHOUT ->utf8 -- it cannot carry
    # anything but valid UTF-8 bytes without corrupting the output. A
    # single-byte-per-character source (a \x{e9}-style Perl literal, which
    # Perl stores unwidened because the codepoint fits in one byte, and
    # which survives an env-var handoff to a child process as that same
    # single byte) is NOT valid UTF-8 on its own. Every decision/note/
    # checkpoint this module builds embeds a path somewhere (subject, title,
    # path fields), so normalise ONCE here and everything downstream
    # inherits guaranteed-valid UTF-8 bytes.
    $home_n = _ensure_utf8_bytes($home_n);
    # The live install: the scripts run from here; nothing is written here.
    my $root = "$home_n/.claude/ccpraxis";
    unless (-d $root) {
        return { status => 'failed', error => "ccpraxis install not found at $root" };
    }

    # ---- the export target, decided once by the preflight phase ----
    unless (exists $ctx->{get_phase_item}) {
        return { status => 'failed',
                 error  => "export target handoff unavailable: \$ctx->{get_phase_item} is missing" };
    }
    my $target = $ctx->{get_phase_item}->('preflight', 'export_target');
    unless (ref($target) eq 'HASH' && $target->{ready}) {
        my $reason = ref($target) eq 'HASH'
            ? ($target->{reason} // 'the export target is not ready')
            : 'preflight established no export target';
        my $fix = ref($target) eq 'HASH' ? $target->{fix} : undef;
        $ctx->{note}->('ccpraxis_export_skipped', { reason => _item_bytes($reason), fix => _item_bytes($fix) });
        return { status => 'skipped', reason => _item_bytes($reason) };
    }
    my $repo = _item_bytes($target->{dev_clone});
    unless (defined $repo && length $repo && -d _native_path($repo)) {
        return { status => 'failed',
                 error  => 'the dev clone preflight chose is not a directory: ' . ($repo // '(none)') };
    }
    $repo =~ s{\\}{/}g;
    $repo =~ s{(?<=.)/+\z}{};

    # WHY a durable record, not just this lexical: @failed_units is a
    # per-INVOCATION list. Every unit below is gated by
    # `unless ($ctx->{is_done}->('<unit>'))`, so a unit that already
    # checkpointed on a PRIOR invocation (including one that checkpointed
    # despite failing, e.g. U3/U6 which always checkpoint so they are never
    # retried) is silently skipped here, and its failure -- recorded only in
    # this lexical, which resets to empty on every fresh call -- evaporates.
    # A phase that pauses for a decision (needs_decision) and is later
    # resumed is EXACTLY that: a second invocation, same run, real earlier
    # failure, empty @failed_units. Spec S2.9 is unconditional ("if any unit
    # failed, run_phase returns failed"), so the terminal status must be
    # read from something that survives the pause/resume boundary --
    # $ctx->{checkpoint}/$ctx->{get_item}, which is durable per-run state,
    # not a variable reinitialised at the top of this sub. Order names by
    # the order failures were first observed within THIS invocation for
    # units that ran here, then any pre-existing durable entries, so the
    # emitted names/first message stay deterministic.
    my @failed_units;   # [ unit_name, message ] -- THIS invocation only;
                         # orders the names in the final error.
    my $failure_key = 'unit_failures';
    my $load_failures = sub {
        my $h = $ctx->{get_item}->($failure_key);
        return (ref($h) eq 'HASH') ? { %$h } : {};
    };
    my $record_failure = sub {
        my ($unit, $msg) = @_;
        return unless defined $msg;
        push @failed_units, [ $unit, $msg ];
        $ctx->{note}->('unit_failed', { unit => $unit, message => $msg });
        my $durable = $load_failures->();
        $durable->{$unit} = $msg;
        $ctx->{checkpoint}->($failure_key, $durable);
    };
    # A unit that failed on an earlier invocation and is retried (only
    # possible for a unit whose failure path did NOT checkpoint, so
    # is_done() still lets it run again) and now succeeds must stop
    # counting -- clear its durable entry rather than merely not adding to
    # it, or a since-fixed unit would still fail the whole run forever.
    my $record_success = sub {
        my ($unit) = @_;
        my $durable = $load_failures->();
        return unless exists $durable->{$unit};
        delete $durable->{$unit};
        $ctx->{checkpoint}->($failure_key, $durable);
    };

    # ---- U1: file_status (SKILL.md Step 2) ----
    unless ($ctx->{is_done}->('file_status')) {
        my $res = _do_file_status($ctx, $root, $repo);
        if ($res->{failed}) { $record_failure->('file_status', $res->{failed}); }
        else                 { $record_success->('file_status'); }
    }

    # U2/U3 depend on U1 having reached a definite conclusion (spec S2.9:
    # "U1 failed -> U2/U3 skipped; U4 onward still run").
    if ($ctx->{is_done}->('file_status')) {
        # ---- U2: file_conflicts (Step 3, may pause as a batch) ----
        unless ($ctx->{is_done}->('file_conflicts')) {
            my $res = _do_file_conflicts($ctx, $root, $repo, $home_n);
            if ($res->{decisions}) {
                # MAJOR (reviewer B1): reaching a decisions/pause branch IS
                # the unit doing its job correctly this invocation (it
                # found a real, current thing to ask about) -- a stale
                # unit_failures entry from an earlier invocation that did
                # NOT checkpoint must be cleared here too, or a fully
                # resolved run reports 'failed' forever over a hiccup that
                # already resolved itself.
                $record_success->('file_conflicts');
                return { status => 'needs_decision', decisions => $res->{decisions} };
            }
            if ($res->{failed}) { $record_failure->('file_conflicts', $res->{failed}); }
            else                 { $record_success->('file_conflicts'); }
        }

        # ---- U3: file_outcome (apply answered file_conflict / claude_md_drift choices) ----
        if ($ctx->{is_done}->('file_conflicts')) {
            unless ($ctx->{is_done}->('file_outcome')) {
                my $res = _do_file_outcome($ctx, $root, $repo);
                if ($res->{failed}) { $record_failure->('file_outcome', $res->{failed}); }
                else                 { $record_success->('file_outcome'); }
            }
        }
    }

    # ---- U4: settings_merge (Step 3 -- P3/P11 skip-keys handoff) ----
    # Unconditional: always attempted regardless of file_status's own
    # outcome or content (AC6/AC11 exercise this with an EMPTY sync-export
    # report and still expect the merge to run exactly once).
    unless ($ctx->{is_done}->('settings_merge')) {
        my $res = _do_settings_merge($ctx, $root, $repo);
        if ($res->{failed}) { $record_failure->('settings_merge', $res->{failed}); }
        else                 { $record_success->('settings_merge'); }
    }

    # ---- U5/U6: container settings sync (Step 3.5) -- BARRIER B1: gated on
    #      settings_merge having checkpointed (either success or the
    #      nothing-to-merge path). A failed U4 leaves this unset. ----
    if ($ctx->{is_done}->('settings_merge')) {
        unless ($ctx->{is_done}->('container_diff')) {
            my $res = _do_container_diff($ctx, $root, $repo);
            if ($res->{decisions}) {
                $record_success->('container_diff');   # see file_conflicts' identical comment above
                return { status => 'needs_decision', decisions => $res->{decisions} };
            }
            if ($res->{failed}) { $record_failure->('container_diff', $res->{failed}); }
            else                 { $record_success->('container_diff'); }
        }

        if ($ctx->{is_done}->('container_diff')) {
            unless ($ctx->{is_done}->('container_outcome')) {
                my $res = _do_container_outcome($ctx, $root, $repo);
                if ($res->{failed}) { $record_failure->('container_outcome', $res->{failed}); }
                else                 { $record_success->('container_outcome'); }
            }
        }
    }

    # ---- U7: sensitive_scan (Step 4) -- BARRIER B3: always alone. ----
    unless ($ctx->{is_done}->('sensitive_scan')) {
        my $res = _do_sensitive_scan($ctx, $root, $repo);
        if ($res->{pause}) {
            $record_success->('sensitive_scan');   # see file_conflicts' identical comment above
            return { status => 'needs_decision', decisions => [ $res->{pause} ] };
        }
        if ($res->{failed}) { $record_failure->('sensitive_scan', $res->{failed}); }
        else                 { $record_success->('sensitive_scan'); }
    }

    # ---- U8/U9: commit the export, then promote it (Step 5, local since
    #      2026-10-30) -- BARRIER B2: no git verb of any kind may be spawned
    #      until sensitive_scan checkpointed clean. ----
    if ($ctx->{is_done}->('sensitive_scan')) {
        unless ($ctx->{is_done}->('committed')) {
            my $res = _do_commit($ctx, $repo);
            if ($res->{failed}) { $record_failure->('committed', $res->{failed}); }
            else                 { $record_success->('committed'); }
        }

        if ($ctx->{is_done}->('committed')) {
            unless ($ctx->{is_done}->('promote_after_commit')) {
                my $res = _do_promote_after_commit($ctx, $root, $home_n, $repo);
                if ($res->{failed}) { $record_failure->('promote_after_commit', $res->{failed}); }
                else                 { $record_success->('promote_after_commit'); }
            }
        }
    }

    my $durable_failures = $load_failures->();
    if (%$durable_failures) {
        # Prefer THIS invocation's own observed order (matches prior
        # behaviour when everything failed in one pass); fall back to a
        # sorted walk of the durable set for any unit that failed on an
        # earlier invocation and was skipped (is_done) on this one, so the
        # emitted list/first message are still deterministic either way.
        my %seen;
        my @names;
        my $first;
        for my $pair (@failed_units) {
            my ($unit, $msg) = @$pair;
            next unless exists $durable_failures->{$unit};
            next if $seen{$unit}++;
            push @names, $unit;
            $first = $msg unless defined $first;
        }
        for my $unit (sort keys %$durable_failures) {
            next if $seen{$unit}++;
            push @names, $unit;
            $first = $durable_failures->{$unit} unless defined $first;
        }
        return { status => 'failed',
                 error  => 'export: ' . join(', ', @names) . " failed -- $first" };
    }

    return { status => 'complete' };
}

# A string read back out of the run-state file (get_item / get_phase_item)
# as the raw bytes it was checkpointed as. Run.pm's reader (JSON::PP without
# ->utf8) can hand such a string back utf8-FLAGGED without transcoding; used
# as a path or a child's argv that flag would double-encode a non-ASCII
# byte. Every character is < 256 there, so downgrading is lossless.
sub _item_bytes {
    my ($s) = @_;
    return $s unless defined $s && !ref $s;
    my $c = $s;
    utf8::downgrade($c, 1) or $c = Encode::encode('UTF-8', $c);
    return $c;
}

# ===========================================================================
# U1 -- file_status (sync-export.pl). Never pauses.
# ===========================================================================
sub _do_file_status {
    my ($ctx, $root, $repo) = @_;

    my $r = _run_capture($^X, "$root/plugins/steward/scripts/sync-export.pl",
        '--live-root', $root, '--repo-root', $repo);
    unless ($r->{spawned}) {
        return { failed => 'sync-export.pl failed to spawn' };
    }
    unless ($r->{exit} == 0) {
        return { failed => "sync-export.pl exited $r->{exit}" };
    }
    my $arr = eval { decode_json($r->{out}) };
    unless (ref($arr) eq 'ARRAY') {
        return { failed => 'sync-export.pl produced non-array output: ' . substr($r->{out} // '', 0, 200) };
    }
    $arr = _sanitize_utf8($arr);

    $ctx->{checkpoint}->('file_status', $arr);
    my %counts;
    for my $item (@$arr) {
        next unless ref($item) eq 'HASH';
        $counts{ $item->{status} // 'unknown' }++;
    }
    $ctx->{note}->('file_status_counts', \%counts);
    return {};
}

# ===========================================================================
# U2 -- file_conflicts (Step 3). Ruling P10: branch on the REAL status set.
# claude_md_differs becomes the claude_md_drift decision; not_linked (a live
# regular file differing from its counterpart) a file_conflict decision; a
# live DIRECTORY is a note, never a decision. An unrecognised status is a
# reported unit failure.
# ===========================================================================
use constant CLAUDE_MD_DRIFT_ID => 'export.claude_md_drift';

sub _lines_text {
    my ($label, $lines, $max) = @_;
    $max //= 40;
    my @l = ref($lines) eq 'ARRAY' ? @$lines : ();
    return () unless @l;
    my @out = ($label);
    for my $i (0 .. $#l) {
        last if $i >= $max;
        my $e = $l[$i];
        push @out, '  L' . (ref($e) eq 'HASH' ? ($e->{n} // '?') : '?') . ': '
                 . (ref($e) eq 'HASH' ? ($e->{text} // '') : '');
    }
    push @out, '  ... and ' . (scalar(@l) - $max) . ' more' if @l > $max;
    return @out;
}

sub _do_file_conflicts {
    my ($ctx, $root, $repo, $home_n) = @_;

    my $status_arr = $ctx->{get_item}->('file_status');
    $status_arr = [] unless ref($status_arr) eq 'ARRAY';

    my @conflict_items;
    my $claude_md;
    for my $item (@$status_arr) {
        next unless ref($item) eq 'HASH';
        my $file   = $item->{file};
        my $status = $item->{status} // '';
        next unless defined $file && length $file;

        if ($status =~ /^(?:identical|linked|tracked)$/) {
            next;
        }
        elsif ($status eq 'missing') {
            $ctx->{note}->('missing_files', { file => $file, note => $item->{note} });
        }
        elsif ($status =~ /^(?:live_only|export_only|marketplace_changed)$/) {
            # Ruling P10 / spec S5: these only ever apply to
            # known_marketplaces.json, which package 02 already reconciled.
            $ctx->{note}->('marketplace_files_skipped', { file => $file, status => $status });
        }
        elsif ($status eq 'settings_changed') {
            # U4 always runs the merge unconditionally; this is report
            # material only.
            $ctx->{note}->('settings_changed_detected', { file => $file });
        }
        elsif ($status eq 'container_settings_diverged') {
            # Handled generically by U5's own json-diff/filter-diff run --
            # no per-file action here even on the rare chance this status
            # is ever emitted.
        }
        elsif ($status eq 'claude_md_differs') {
            # ~/.claude/CLAUDE.md is built from the live install's payload;
            # a difference cannot be exported, only rebuilt away or folded
            # into the payload by hand. A link to some other file cannot be
            # rebuilt over safely (install-claude-md refuses it, as promote
            # does), so it is reported, not asked.
            if (($item->{claude_md_status} // 'differs') eq 'differs') {
                $claude_md = $item;
            }
            else {
                $ctx->{note}->('claude_md_symlinked_elsewhere', { file => $file, target => $item->{target},
                                                                  note => $item->{note} });
            }
        }
        elsif ($status eq 'not_linked' || $status eq 'conflict') {
            # Pair by the item's own identity, never by basename alone:
            # sync-export.pl's repo_file is the repo-relative path this live
            # $file is mapped to (bug report 20260922-211416-1b92). Fall back
            # to $file only for older sync-export.pl output without it.
            my $repo_file = $item->{repo_file} // $file;
            my $live_path = "$home_n/.claude/$file";
            my $repo_path = "$repo/$repo_file";
            if (-d $live_path) {
                $ctx->{note}->('file_status_directory', { file => $file, note => $item->{note} });
                next;
            }
            unless (-f $live_path) {
                $ctx->{note}->('file_status_missing_live', { file => $file, note => $item->{note} });
                next;
            }
            unless (-f $repo_path) {
                $ctx->{note}->('file_status_missing_repo', { file => $file, note => $item->{note} });
                next;
            }
            my ($live_text, $live_err) = _read_file_raw($live_path);
            my ($repo_text, $repo_err) = _read_file_raw($repo_path);
            if (defined $live_err || defined $repo_err) {
                return { failed => "cannot read '$file': " . ($live_err // $repo_err) };
            }
            next if $live_text eq $repo_text;   # not actually differing
            push @conflict_items, { file => $file, repo_file => $repo_file, live_path => $live_path,
                                     repo_path => $repo_path, live_text => $live_text, repo_text => $repo_text };
        }
        else {
            return { failed => "sync-export.pl reported an unrecognized status '$status' for '$file'" };
        }
    }

    unless (@conflict_items || $claude_md) {
        $ctx->{checkpoint}->('file_conflicts', []);
        return {};
    }

    my @decisions;
    my @inventory;

    if ($claude_md) {
        my $extra   = ref($claude_md->{extra_lines})   eq 'ARRAY' ? $claude_md->{extra_lines}   : [];
        my $missing = ref($claude_md->{missing_lines}) eq 'ARRAY' ? $claude_md->{missing_lines} : [];
        my $resolve = $claude_md->{resolve} // '';
        my @detail  = (
            "~/.claude/CLAUDE.md is not what promote.pl builds for this host from the live install's payload"
            . (defined $claude_md->{note} ? " ($claude_md->{note})" : '') . '.',
            _lines_text('only in ~/.claude/CLAUDE.md:', $extra),
            _lines_text("only in the build (global-config/CLAUDE.md + this host's part):", $missing),
        );
        push @detail, "A difference is never exported: a line carries no record of which part it belongs to. "
                    . "To keep a line, $resolve" if @$extra;
        push @decisions, $ctx->{decision}->(
            kind    => 'claude_md_drift',
            id      => CLAUDE_MD_DRIFT_ID,
            title   => '~/.claude/CLAUDE.md differs from its build from the live install ('
                     . scalar(@$extra) . ' line(s) only there, ' . scalar(@$missing) . ' missing)',
            subject => 'CLAUDE.md',
            detail  => join("\n", @detail),
            data    => { file => 'CLAUDE.md', live_path => "$home_n/.claude/CLAUDE.md",
                         host_part => $claude_md->{host_part}, extra_lines => $extra,
                         missing_lines => $missing, resolve => $resolve },
            choices => [
                { id => 'rerender', label => 'Rebuild ~/.claude/CLAUDE.md from the live install (the current file is backed up to ~/.claude/.promotion-backups/ first)' },
                { id => 'leave',    label => 'Leave it as it is (fold the lines into the dev clone\'s payload and promote)' },
            ],
        );
        push @inventory, { kind => 'claude_md', file => 'CLAUDE.md', live_path => "$home_n/.claude/CLAUDE.md",
                           extra_lines_count => scalar(@$extra), resolve => $resolve };
    }

    my @pairs = _mint_ids('export.file_conflict', map { $_->{file} } @conflict_items);
    for my $i (0 .. $#conflict_items) {
        my ($file, $id) = @{ $pairs[$i] };
        my $it = $conflict_items[$i];
        # HARDEN item9b: live_text/repo_text are RAW file bytes -- unlike
        # every other value this module hands to $ctx, they never passed
        # through _ensure_utf8_bytes; a genuinely invalid byte reaching
        # backup.pl's non-utf8 stdout encoder makes the whole object
        # unparseable (and loses the resume token). Repair the same way as
        # $home_n: valid UTF-8 untouched, an invalid byte Latin-1-
        # reinterpreted rather than replaced with U+FFFD, which would LOOK
        # like faithful content while not being the file's real bytes.
        my $live_repaired = _ensure_utf8_bytes($it->{live_text});
        my $repo_repaired = _ensure_utf8_bytes($it->{repo_text});
        my ($lt, $lt_trunc) = _clamp_text($live_repaired);
        my ($rt, $rt_trunc) = _clamp_text($repo_repaired);
        push @decisions, $ctx->{decision}->(
            kind    => 'file_conflict',
            id      => $id,
            title   => "file '" . _title_key($file) . "' differs between live and the dev clone",
            subject => $file,
            detail  => '',
            data    => { file => $file, live_path => $it->{live_path}, repo_path => $it->{repo_path},
                         live_text => $lt, repo_text => $rt,
                         live_bytes => length($it->{live_text}), repo_bytes => length($it->{repo_text}),
                         truncated => ($lt_trunc || $rt_trunc) ? 1 : 0 },
            choices => [
                { id => 'use_live',       label => 'Use the live version (copy it over the dev clone\'s copy)' },
                { id => 'use_export',     label => 'Use the dev clone\'s version (copy it over the live copy)' },
                { id => 'merge_manually', label => 'Merge manually (write nothing; report both paths)' },
            ],
        );
        # Just the paths (not the bulky text) -- U3 only needs these.
        push @inventory, { kind => 'file', file => $file, repo_file => $it->{repo_file},
                           live_path => $it->{live_path}, repo_path => $it->{repo_path} };
    }

    $ctx->{checkpoint}->('file_conflicts', \@inventory);
    return { decisions => \@decisions };
}

# ===========================================================================
# U3 -- file_outcome: apply answered choices. file_conflict: use_live /
# use_export byte-copy; merge_manually writes nothing (ruling P12) and
# records an instruction note naming both paths. claude_md_drift: rerender
# runs ccpraxis-helpers.pl install-claude-md (backup copy, then the build of
# the live payload); leave writes nothing and notes where the lines go.
# Checkpoints 'wrote': the dev-clone files this unit changed.
# ===========================================================================
sub _do_file_outcome {
    my ($ctx, $root, $repo) = @_;

    my $inventory = $ctx->{get_item}->('file_conflicts');
    $inventory = [] unless ref($inventory) eq 'ARRAY';
    return {} unless @$inventory;

    my @files = grep { ref($_) eq 'HASH' && ($_->{kind} // 'file') eq 'file' } @$inventory;
    my ($cm)  = grep { ref($_) eq 'HASH' && ($_->{kind} // '') eq 'claude_md' } @$inventory;
    my @pairs = _mint_ids('export.file_conflict', map { $_->{file} } @files);
    my (@resolved, @instructions, @failed_msgs, @wrote);
    my $claude_md_outcome;

    if ($cm) {
        my $choice = $ctx->{answers}{ CLAUDE_MD_DRIFT_ID() };
        if (defined $choice && $choice eq 'rerender') {
            my $r = _run_capture($^X, "$root/plugins/steward/scripts/ccpraxis-helpers.pl",
                'install-claude-md', '--live-root', $root);
            my $j = $r->{spawned} ? eval { decode_json($r->{out}) } : undef;
            if ($r->{spawned} && $r->{exit} == 0 && ref($j) eq 'HASH') {
                $j = _sanitize_utf8($j);
                $claude_md_outcome = { choice => $choice, status => $j->{status}, backup => $j->{backup} };
                $ctx->{note}->('claude_md_rerendered', { backup => $j->{backup}, status => $j->{status} });
            }
            else {
                my $why = ref($j) eq 'HASH' ? ($j->{error} // "exited $r->{exit}")
                        : $r->{spawned} ? "exited $r->{exit}" : 'failed to spawn';
                push @failed_msgs, 'claude_md_drift: install-claude-md ' . _sanitize_utf8($why);
                $claude_md_outcome = { choice => $choice, status => 'failed' };
            }
        }
        elsif (defined $choice && $choice eq 'leave') {
            $claude_md_outcome = { choice => $choice };
            $ctx->{note}->('claude_md_left', { extra_lines_count => $cm->{extra_lines_count},
                                               resolve => $cm->{resolve} });
        }
    }

    for my $i (0 .. $#files) {
        my ($file, $id) = @{ $pairs[$i] };
        my $it     = $files[$i];
        my $choice = $ctx->{answers}{$id};
        next unless defined $choice;
        my $live_path = _item_bytes($it->{live_path});
        my $repo_path = _item_bytes($it->{repo_path});

        if ($choice eq 'use_live') {
            my $ok = eval { _copy_file_bytes($live_path, $repo_path); 1 };
            if ($ok) {
                push @resolved, { file => $file, choice => $choice };
                push @wrote, $it->{repo_file} // $file;
            }
            else { push @failed_msgs, "file_conflict '$file': cannot copy live->dev clone: $@"; }
        }
        elsif ($choice eq 'use_export') {
            my $ok = eval { _copy_file_bytes($repo_path, $live_path); 1 };
            if ($ok) { push @resolved, { file => $file, choice => $choice }; }
            else      { push @failed_msgs, "file_conflict '$file': cannot copy dev clone->live: $@"; }
        }
        elsif ($choice eq 'merge_manually') {
            push @instructions, { file => $file, live_path => $it->{live_path}, repo_path => $it->{repo_path} };
        }
    }

    $ctx->{note}->('file_conflicts_resolved', \@resolved) if @resolved;
    $ctx->{note}->('file_conflict_merge_manually', \@instructions) if @instructions;
    $ctx->{checkpoint}->('file_outcome', { resolved => \@resolved, instructions => \@instructions,
                                           claude_md => $claude_md_outcome, wrote => \@wrote });

    my $ret = {};
    $ret->{failed} = join('; ', @failed_msgs) if @failed_msgs;
    return $ret;
}

# ===========================================================================
# U4 -- settings_merge (Step 3, P3/P11 skip-keys handoff). Three defensive
# fail-closed cases (spec S2.2), none of which may silently pass zero
# skip-keys.
# ===========================================================================
sub _do_settings_merge {
    my ($ctx, $root, $repo) = @_;

    unless (exists $ctx->{get_phase_item}) {
        return { failed => "skip-keys handoff unavailable: \$ctx->{get_phase_item} is missing" };
    }
    my $outcome = $ctx->{get_phase_item}->('preflight', 'settings_outcome');
    unless (defined $outcome) {
        return { failed => 'skip-keys handoff missing: preflight recorded no settings_outcome' };
    }
    unless (ref($outcome) eq 'HASH') {
        return { failed => 'skip-keys handoff malformed: settings_outcome is not a hashref' };
    }
    my $skip_keys = $outcome->{skip_keys};
    unless (ref($skip_keys) eq 'ARRAY') {
        return { failed => 'skip-keys handoff malformed: skip_keys is absent or not an array' };
    }
    for my $k (@$skip_keys) {
        unless (defined $k && !ref($k) && length $k) {
            return { failed => 'skip-keys handoff malformed: skip_keys contains a non-scalar or empty element' };
        }
    }

    # What goes to the payload is exactly what the operator (per key, in the
    # preflight) sent there: to_payload takes the ~/.claude value,
    # remove_from_payload drops the key. An older settings_outcome without the
    # lists carries the same facts in its answers (use_live / export_to_repo /
    # remove_from_repo occur for one relation each).
    my $answers = ref($outcome->{answers}) eq 'HASH' ? $outcome->{answers} : {};
    my @to_payload = ref($outcome->{to_payload}) eq 'ARRAY' ? @{ $outcome->{to_payload} }
                   : sort grep { my $c = $answers->{$_} // ''; $c eq 'use_live' || $c eq 'export_to_repo' } keys %$answers;
    my @remove_from_payload = ref($outcome->{remove_from_payload}) eq 'ARRAY' ? @{ $outcome->{remove_from_payload} }
                   : sort grep { ($answers->{$_} // '') eq 'remove_from_repo' } keys %$answers;
    for my $k (@to_payload, @remove_from_payload) {
        return { failed => 'settings handoff malformed: a to-payload key is a non-scalar or empty element' }
            unless defined $k && !ref($k) && length $k;
    }
    $_ = _item_bytes($_) for @to_payload, @remove_from_payload;

    # Nothing sent to the payload: nothing is merged, and the payload file is
    # not even rewritten (a rewrite alone could reformat it into a commit).
    unless (@to_payload || @remove_from_payload) {
        $ctx->{checkpoint}->('settings_merge', { status => 'nothing_to_export', wrote => [],
            preferences_applied => [], preferences_ignored => [], skip_keys_unmatched => [] });
        $ctx->{note}->('settings_merge', { status => 'nothing_to_export' });
        return {};
    }

    # --live-root: the directory ${CCPRAXIS_LIVE} stands for (collapse
    # against it); --repo-root: the dev clone, the only thing written.
    # --only-key / --remove-key make the merge selective: no other unit moves.
    my @args = ('settings-export-merge', '--live-root', $root, '--repo-root', $repo);
    push @args, ('--skip-key', $_)   for @$skip_keys;
    push @args, ('--only-key', $_)   for @to_payload;
    push @args, ('--remove-key', $_) for @remove_from_payload;
    my $r = _run_capture($^X, "$root/plugins/steward/scripts/ccpraxis-helpers.pl", @args);
    unless ($r->{spawned}) {
        return { failed => 'ccpraxis-helpers.pl settings-export-merge failed to spawn' };
    }
    my $j = eval { decode_json($r->{out}) };
    unless (ref($j) eq 'HASH') {
        return { failed => 'ccpraxis-helpers.pl settings-export-merge produced unparseable output: '
                          . substr($r->{out} // '', 0, 200) };
    }
    if ($r->{exit} != 0 || (($j->{status} // '') eq 'error')) {
        my $msg = ref($j->{error}) eq 'HASH' ? ($j->{error}{message} // 'unknown error')
                : (defined $j->{error} ? "$j->{error}" : "exited $r->{exit}");
        return { failed => "settings-export-merge: $msg" };
    }
    $j = _sanitize_utf8($j);
    # settings-export-merge rewrote the dev clone's settings.json; the commit
    # takes it only if that changed anything.
    $j->{wrote} = [ 'global-config/settings.json' ];
    $j->{to_payload} = [ @to_payload ];
    $j->{remove_from_payload} = [ @remove_from_payload ];

    $ctx->{checkpoint}->('settings_merge', $j);
    $ctx->{note}->('settings_merge', { status => $j->{status}, merge_rule => $j->{merge_rule} });
    $ctx->{note}->('preferences_applied', $j->{preferences_applied}) if @{ $j->{preferences_applied} // [] };
    $ctx->{note}->('preferences_ignored', $j->{preferences_ignored}) if @{ $j->{preferences_ignored} // [] };
    $ctx->{note}->('skip_keys_unmatched', $j->{skip_keys_unmatched}) if @{ $j->{skip_keys_unmatched} // [] };
    $ctx->{note}->('skip_keys_passed', $skip_keys) if @$skip_keys;
    return {};
}

# ===========================================================================
# U5 -- container_diff (Step 3.5). BARRIER B1 enforced by run_phase's own
# gating (this sub is only called once settings_merge has checkpointed).
# ===========================================================================
sub _do_container_diff {
    my ($ctx, $root, $repo) = @_;

    # Both files are the dev clone's: the export target, just merged into.
    my $container_path = "$repo/plugins/sandbox/container/settings.json";
    my $global_path     = "$repo/global-config/settings.json";

    # -e (not -f): a path OCCUPIED by something odd (e.g. a directory
    # blocking a later write, AC33's fixture) must still reach json-diff.pl
    # -- only a GENUINELY missing path (AC15) short-circuits here. The write
    # side (_write_json_file's rename) is what actually detects "occupied
    # and unwritable", and degrades that unit -- not this read-only probe.
    unless (-e $container_path) {
        $ctx->{note}->('container_absent', { path => $container_path });
        $ctx->{checkpoint}->('container_diff', { status => 'absent' });
        return {};
    }

    my $jd = _run_capture($^X, "$root/plugins/steward/scripts/json-diff.pl", $global_path, $container_path);
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
        '--prefs', $prefs_path, '--scope', 'global_vs_container');
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

    $fd_json->{followed_global} = _container_follow_candidates($ctx, $fd_json, $prefs_path);
    $ctx->{checkpoint}->('container_diff', $fd_json);
    my @auto = @{ $fd_json->{auto_applied} // [] };
    $ctx->{note}->('container_auto_applied', \@auto) if @auto;

    return {} if (($fd_json->{status} // '') eq 'identical');

    my @decisions = _container_decisions($ctx, $fd_json);
    return {} unless @decisions;
    return { decisions => \@decisions };
}

# ===========================================================================
# U6 -- container_outcome: apply answered container_settings_key choices.
# Ruling: dotted keys nest (_assign_nested) / delete only the leaf
# (_delete_nested) -- never a literal flat "env.X" top-level key.
# ===========================================================================
sub _do_container_outcome {
    my ($ctx, $root, $repo) = @_;

    my $diff = $ctx->{get_item}->('container_diff');
    my @decisions = (ref($diff) eq 'HASH') ? _container_decisions($ctx, $diff) : ();
    my @followed  = (ref($diff) eq 'HASH') ? _container_followed_list($diff)   : ();
    return {} unless @decisions || @followed;

    my $container_rel  = 'plugins/sandbox/container/settings.json';
    my $container_path = "$repo/$container_rel";
    my $prefs_path      = "$root/.backup-preferences.json";
    my (@applied, @removed, @prefs_saved, @failed_msgs, @wrote);
    my (%writes, %deletes);
    my $need_write = 0;

    my %remember_map = (
        keep_different_remember      => [ 'diverged',   'skip-always' ],
        keep_global_only_remember    => [ 'only_left',  'left-only'   ],
        keep_container_only_remember => [ 'only_right', 'right-only'  ],
    );

    for my $d (@decisions) {
        my $key    = $d->{data}{key};
        my $rel    = $d->{data}{relation};
        my $choice = $ctx->{answers}{ $d->{id} };
        next unless defined $choice;

        if (my $pair = $remember_map{$choice}) {
            my ($category, $action) = @$pair;
            my $sp = _run_capture($^X, "$root/plugins/steward/scripts/save-preference.pl",
                '--prefs', $prefs_path, '--scope', 'global_vs_container', '--key', $key,
                '--category', $category, '--action', $action);
            if ($sp->{spawned} && $sp->{exit} == 0) {
                push @prefs_saved, { key => $key, category => $category, action => $action };
            }
            else {
                push @failed_msgs, "save-preference.pl for '$key'";
            }
        }

        if ($rel eq 'diverged' && $choice eq 'propagate_to_container') {
            $writes{$key} = _container_write_value($rel, $d->{data}{value});
            $need_write = 1;
            push @applied, $key;
        }
        elsif ($rel eq 'only_left' && $choice eq 'add_to_container') {
            $writes{$key} = _container_write_value($rel, $d->{data}{value});
            $need_write = 1;
            push @applied, $key;
        }
        elsif ($rel eq 'only_right' && $choice eq 'remove_from_container') {
            $deletes{$key} = 1;
            $need_write = 1;
            push @removed, $key;
        }
    }

    my @followed_out;
    for my $f (@followed) {
        my $v = $diff->{needs_decision}{ $f->{relation} }{ $f->{key} };
        $writes{ $f->{key} } = _container_write_value($f->{relation}, $v);
        $need_write = 1;
        push @followed_out, { key => $f->{key}, relation => $f->{relation}, answer => $f->{answer} };
    }

    my $write_ok = 1;
    if ($need_write) {
        my ($data, $read_err) = _read_or_init_json_file($container_path);
        if (defined $read_err) {
            push @failed_msgs, "container_outcome: $read_err";
            $write_ok = 0;
        }
        else {
            # $writes{$_} came off a checkpointed decision, already
            # downgraded to raw UTF-8 bytes by _sanitize_utf8 (so it could
            # safely reach backup.pl's non-utf8-aware stdout encoder).
            # _write_json_file's ->utf8 encoder needs the OPPOSITE
            # representation -- a properly widened Perl string -- or a
            # multi-byte character here would be double-encoded. Re-widen
            # right before the write; _read_or_init_json_file's own
            # decode_json (which widens) already makes the REST of $data
            # consistent with this. The KEY must be widened too (MEDIUM-2 /
            # S1): a non-ASCII key off a checkpoint is raw UTF-8 bytes same
            # as the value, and _assign_nested/_delete_nested use it as a
            # literal hash key -- an unwidened key reaches _write_json_file's
            # ->utf8 encoder and gets double-encoded, same defect class as
            # the value one, matching Closeout.pm's own key-widening fix.
            _assign_nested($data, _widen_utf8($_), _widen_utf8($writes{$_})) for keys %writes;
            _delete_nested($data, _widen_utf8($_)) for keys %deletes;
            my $ok = eval { _write_json_file($container_path, $data); 1 };
            if ($ok) { push @wrote, $container_rel; }
            else {
                push @failed_msgs, "container_outcome: cannot write $container_path: $@";
                $write_ok = 0;
            }
        }
    }

    # LOW-1 (red-team): a followed key is only reported/checkpointed as
    # followed if the write actually landed -- otherwise the note would
    # claim success on a write that failed.
    @followed_out = () unless $write_ok;

    $ctx->{note}->('container_followed_global', \@followed_out) if @followed_out;
    $ctx->{checkpoint}->('container_outcome', { applied => \@applied, removed => \@removed,
                                                  preferences_saved => \@prefs_saved,
                                                  followed_global => \@followed_out,
                                                  wrote => \@wrote });
    $ctx->{note}->('container_preferences_saved', \@prefs_saved) if @prefs_saved;

    my $ret = {};
    $ret->{failed} = join('; ', @failed_msgs) if @failed_msgs;
    return $ret;
}

# Determines which container needs_decision items "follow" this run's
# preflight settings_outcome answer instead of becoming a decision. Called
# ONLY by _do_container_diff -- never by _do_container_outcome, which must
# rebuild the followed set from the checkpoint alone.
#
# HIGH-1 (red-team): a key with ANY saved global_vs_container preference
# entry -- regardless of whether its stored category still matches the
# current diff -- must never be followed. Once global-config gains a key
# that was previously container-only (e.g. a keep_container_only_remember
# preference), the preference's category ("only_right") no longer matches
# the new relation ("diverged"), so filter-diff.pl's own category check
# leaves it in needs_decision. Following it anyway would silently overwrite
# a value the operator explicitly asked to keep. Skipping it here lets it
# fall through to the normal container_settings_key decision path instead,
# where the operator is asked again.
sub _container_follow_candidates {
    my ($ctx, $fd_json, $prefs_path) = @_;
    my $so = exists $ctx->{get_phase_item}
           ? $ctx->{get_phase_item}->('preflight', 'settings_outcome') : undef;
    my $answers = (ref($so) eq 'HASH' && ref($so->{answers}) eq 'HASH') ? $so->{answers} : {};
    my $prefs = _container_preference_keys($prefs_path);
    my $nd = ref($fd_json->{needs_decision}) eq 'HASH' ? $fd_json->{needs_decision} : {};
    my @out;
    for my $rel (qw(diverged only_left)) {
        my $group = $nd->{$rel};
        next unless ref($group) eq 'HASH';
        for my $k (sort keys %$group) {
            my $ans = $answers->{$k};
            next unless defined $ans && !ref($ans) && ($ans eq 'use_live' || $ans eq 'export_to_repo');
            next if $prefs->{$k};
            push @out, { key => $k, relation => $rel, answer => $ans };
        }
    }
    return \@out;
}

# Reads .backup-preferences.json's global_vs_container scope directly (the
# same file filter-diff.pl consults) and returns a {key => 1} set of every
# key that has ANY saved preference entry there, independent of category.
# Used only by _container_follow_candidates (HIGH-1) -- filter-diff.pl's own
# category-matched check still governs auto_applied/needs_decision.
sub _container_preference_keys {
    my ($prefs_path) = @_;
    return {} unless defined $prefs_path && -f $prefs_path;
    my $raw = eval {
        open my $fh, '<', $prefs_path or die "open failed: $!";
        local $/;
        <$fh>;
    };
    return {} unless defined $raw;
    my $json = eval { decode_json($raw) };
    return {} unless ref($json) eq 'HASH';
    my $scope = $json->{global_vs_container};
    return {} unless ref($scope) eq 'HASH';
    return { map { $_ => 1 } keys %$scope };
}

# ===========================================================================
# Container decision builders -- pure functions of the checkpointed diff
# data, so U6 can regenerate the SAME ids deterministically without
# re-running json-diff.pl/filter-diff.pl.
# ===========================================================================
sub _container_write_value {
    my ($rel, $v) = @_;
    return (ref($v) eq 'HASH') ? $v->{left} : $v if $rel eq 'diverged';
    return $v;
}

# Pure function of a container_diff checkpoint hash: validated
# followed_global entries, in stored order. Single source of truth used by
# both the decision-exclusion (_container_items_ordered) and the write
# application (_do_container_outcome), so an item is always either
# excluded-and-applied or included-and-asked -- never both, never neither.
sub _container_followed_list {
    my ($diff) = @_;
    return () unless ref($diff) eq 'HASH';
    my $list = $diff->{followed_global};
    return () unless ref($list) eq 'ARRAY';
    my $nd = ref($diff->{needs_decision}) eq 'HASH' ? $diff->{needs_decision} : {};
    my @out;
    for my $e (@$list) {
        next unless ref($e) eq 'HASH';
        my ($key, $rel, $answer) = @{$e}{qw(key relation answer)};
        next unless defined $key && !ref($key) && length $key;
        next unless defined $rel && ($rel eq 'diverged' || $rel eq 'only_left');
        next unless defined $answer && ($answer eq 'use_live' || $answer eq 'export_to_repo');
        next unless ref($nd->{$rel}) eq 'HASH' && exists $nd->{$rel}{$key};
        push @out, { key => $key, relation => $rel, answer => $answer };
    }
    return @out;
}

sub _container_items_ordered {
    my ($diff) = @_;
    my $nd = (ref($diff) eq 'HASH' && ref($diff->{needs_decision}) eq 'HASH') ? $diff->{needs_decision} : {};
    my %followed = map { ("$_->{relation}\0$_->{key}" => 1) } _container_followed_list($diff);
    my @items;
    for my $rel (qw(diverged only_left only_right)) {
        my $group = $nd->{$rel};
        next unless ref($group) eq 'HASH';
        for my $k (sort keys %$group) {
            next if $followed{"$rel\0$k"};
            push @items, { key => $k, relation => $rel, value => $group->{$k} };
        }
    }
    return @items;
}

sub _container_title {
    my ($key, $rel) = @_;
    my $kd = _title_key($key);
    return "container settings key '$kd' differs from global-config" if $rel eq 'diverged';
    return "settings key '$kd' exists only in global-config"          if $rel eq 'only_left';
    return "settings key '$kd' exists only in the container settings" if $rel eq 'only_right';
    return "container settings key '$kd'";
}

sub _container_choices {
    my ($rel) = @_;
    return [
        { id => 'propagate_to_container',    label => 'Propagate to container (update container settings to match global-config)' },
        { id => 'keep_container',            label => 'Keep the container value (one-time)' },
        { id => 'keep_different_remember',   label => 'Keep both different, remember' },
        { id => 'skip',                      label => 'Skip (ask again next run)' },
    ] if $rel eq 'diverged';
    return [
        { id => 'add_to_container',          label => 'Add to container settings' },
        { id => 'keep_global_only_remember', label => 'Keep global-only, remember' },
        { id => 'skip',                      label => 'Skip (ask again next run)' },
    ] if $rel eq 'only_left';
    return [
        { id => 'remove_from_container',       label => 'Remove from container settings' },
        { id => 'keep_container_only_remember', label => 'Keep container-only, remember' },
        { id => 'skip',                         label => 'Skip (ask again next run)' },
    ] if $rel eq 'only_right';
    return [];
}

sub _container_decisions {
    my ($ctx, $diff) = @_;
    my @items = _container_items_ordered($diff);
    return () unless @items;
    my @pairs = _mint_ids('export.container', map { $_->{key} } @items);
    my @decisions;
    for my $i (0 .. $#items) {
        my ($key, $id) = @{ $pairs[$i] };
        my $it  = $items[$i];
        my $rel = $it->{relation};
        push @decisions, $ctx->{decision}->(
            kind    => 'container_settings_key',
            id      => $id,
            title   => _container_title($key, $rel),
            subject => $key,
            detail  => '',
            data    => { key => $key, relation => $rel, value => $it->{value} },
            choices => _container_choices($rel),
        );
    }
    return @decisions;
}

# ===========================================================================
# U7 -- sensitive_scan (Step 4). BARRIER B2/B3: gates every git operation;
# always returned alone. <attempt> is derived from the contiguous run of
# 'rescan' answers (spec S2.5), so a still-dirty rescan mints a fresh id.
# ===========================================================================
sub _sensitive_attempt {
    my ($ctx) = @_;
    my $answers = $ctx->{answers} // {};
    my $n = 1;
    while ((($answers->{"export.sensitive_finding.$n"}) // '') eq 'rescan') {
        $n++;
    }
    return $n;
}

sub _parse_sensitive_findings {
    my ($stdout) = @_;
    my @lines = split /\r?\n/, ($stdout // '');
    my (@detail_lines, @patterns, @hits);
    my $current_label;
    for my $line (@lines) {
        if ($line =~ /^\s*Pattern:\s*(.+?)\s*$/) {
            $current_label = $1;
            push @patterns, $current_label;
            push @detail_lines, "Pattern: $current_label";
        }
        elsif (defined $current_label && $line =~ /^\s{2,}(.+?):(\d+):.*$/) {
            my ($path, $lineno) = ($1, $2);
            push @detail_lines, "  $path:$lineno";
            push @hits, "$path:$lineno";
        }
    }
    my $count = scalar(@hits);
    my %by_file;
    for my $h (@hits) {
        $by_file{$1} = 1 if $h =~ /^(.*):(\d+)$/;
    }
    my $file_count = scalar(keys %by_file);
    my $detail = join("\n", @detail_lines);
    my $data = { count => $count, file_count => $file_count, patterns => \@patterns, hits => \@hits };
    return ($detail, $data);
}

sub _do_sensitive_scan {
    my ($ctx, $root, $repo) = @_;

    my $attempt = _sensitive_attempt($ctx);
    my $id      = "export.sensitive_finding.$attempt";
    my $answer  = $ctx->{answers}{$id};
    if (defined $answer && $answer eq 'abort') {
        return { failed => 'sensitive scan: aborted by operator (findings not resolved)' };
    }

    # Exactly the files the export commit can contain -- the ones this run
    # wrote into the dev clone (the commit takes those of them git sees as
    # changed, and nothing else). The developer's untracked work in progress
    # is not the backup's to commit, so it is not the backup's to scan:
    # /steward:upstream-sync scans what a push actually sends.
    my @files = grep { -f "$repo/$_" } _written_paths($ctx);
    unless (@files) {
        $ctx->{checkpoint}->('sensitive_scan', { attempt => $attempt, clean => 1, files => [] });
        $ctx->{note}->('sensitive_scan', { attempt => $attempt, clean => 1, files => [] });
        return {};
    }
    my $r = _run_capture($^X, "$root/plugins/steward/scripts/sensitive-check.pl", $repo, map { ('--file', $_) } @files);
    unless ($r->{spawned}) {
        return { failed => 'sensitive-check.pl failed to spawn' };
    }
    if ($r->{exit} == 0) {
        $ctx->{checkpoint}->('sensitive_scan', { attempt => $attempt, clean => 1, files => [ @files ] });
        $ctx->{note}->('sensitive_scan', { attempt => $attempt, clean => 1, files => [ @files ] });
        return {};
    }
    if ($r->{exit} == 1) {
        my ($detail, $data) = _parse_sensitive_findings($r->{out});
        my $dec = $ctx->{decision}->(
            kind    => 'sensitive_finding',
            id      => $id,
            title   => "the sensitive-data scan found $data->{count} match(es) in $data->{file_count} file(s)",
            subject => $repo,
            detail  => $detail,
            data    => $data,
            choices => [
                { id => 'abort',  label => 'Abort (do not commit or push until resolved)' },
                { id => 'rescan', label => 'I removed them -- rescan' },
            ],
        );
        return { pause => $dec };
    }
    return { failed => "sensitive-check.pl exited $r->{exit}" };
}

# ===========================================================================
# U8 -- commit, in the DEV CLONE. Ruling P4: refuse while MERGE_HEAD exists.
# Commits the files this run WROTE that git sees as changed -- nothing else:
# never `git add -A`, never the developer's other edits or untracked files,
# and (through the commit's pathspec) never anything they had staged. No
# question: the scan above was the gate, and this commit is local -- it
# reaches GitHub only through /steward:upstream-sync, which shows every
# outgoing commit before it pushes. Checkpoints 'committed'.
#
# Crash safety asks git, not this module's state: after an R6 clear the units
# re-run, the merge writes the same content again, nothing is pending, and
# the commit an interrupted run already made is found by U9 instead.
# ===========================================================================

use constant EXPORT_SUBJECT_RE => qr/^backup: sync ccpraxis config \(\d+ file\(s\)\)\z/;

# Repo-relative paths written into the dev clone by this run: the
# preflight's W2 (marketplace_outcome.wrote) and this phase's own units.
sub _written_paths {
    my ($ctx) = @_;
    my %w;
    my @sources = ( $ctx->{get_phase_item}->('preflight', 'marketplace_outcome'),
                    map { $ctx->{get_item}->($_) } qw(file_outcome settings_merge container_outcome) );
    for my $it (@sources) {
        next unless ref($it) eq 'HASH' && ref($it->{wrote}) eq 'ARRAY';
        for my $p (@{ $it->{wrote} }) {
            next unless defined $p && !ref($p) && length $p;
            my $b = _item_bytes($p);
            $b =~ s{\\}{/}g;
            # Only ever a path inside the dev clone.
            next if $b =~ m{^/} || $b =~ m{^[A-Za-z]:} || $b =~ m{(?:^|/)\.\.(?:/|\z)};
            $w{$b} = 1;
        }
    }
    return sort keys %w;
}

sub _do_commit {
    my ($ctx, $repo) = @_;

    # MAJOR (redteam/reviewer): `-f "$repo/.git/MERGE_HEAD"` silently never
    # fires when .git is a FILE (a linked worktree -- a dev clone can be
    # one). Resolve the REAL git-dir first, so a merge in progress, conflict
    # markers and all, is never committed (ruling P4).
    my $git_dir = _resolve_git_dir($repo);
    if (defined $git_dir && -f "$git_dir/MERGE_HEAD") {
        return { failed => 'a merge is in progress in the dev clone (MERGE_HEAD present) -- resolve it before the export can be committed' };
    }

    # MAJOR (redteam/reviewer): `--is-inside-work-tree` succeeds from a
    # SUBDIRECTORY too. The staged paths are relative to the dev clone, so
    # it must BE the top level: compare canonical paths (HARDEN
    # item4a-followup -- a textual compare rejects a mere respelling).
    my $top = _git_capture($repo, 'rev-parse', '--show-toplevel');
    unless ($top->{spawned} && $top->{exit} == 0) {
        return { failed => 'the dev clone is not a git repository' };
    }
    (my $t = $top->{out} // '') =~ s/\s+\z//;
    my $repo_real = abs_path(_native_path($repo));
    my $top_real  = abs_path(_native_path($t));
    unless (defined $repo_real && defined $top_real) {
        return { failed => "cannot resolve '$repo' or the reported top level '$t' to a canonical path -- refusing to assume they name the same directory" };
    }
    unless (_native_path($repo_real) eq _native_path($top_real)) {
        return { failed => "$repo is not the top level of its git repository (that is " . _clamp($t, 300) . ")" };
    }

    # The preflight checked main; a checkout since then would put the
    # export commit on some other branch.
    my $branch = _git_current_branch($repo);
    unless (defined $branch && $branch eq 'main') {
        return { failed => 'the dev clone is ' . (defined $branch ? "on branch '" . _title_key($branch) . "'" : 'on a detached HEAD')
                         . ', not main: the exported files were written but nothing is committed' };
    }

    # core.quotePath=false: these exact paths are staged via `git add --`,
    # where git's C-quoted form of a non-ASCII name is not a pathspec.
    my @written = _written_paths($ctx);
    my (@added, @modified, @deleted, @untracked, @files, @paths);
    if (@written) {
        my $status = _git_capture($repo, '-c', 'core.quotePath=false', 'status', '--porcelain',
                                  '--untracked-files=all', '--', @written);
        unless ($status->{spawned} && $status->{exit} == 0) {
            return { failed => 'git status failed in the dev clone: ' . _clamp($status->{err} // '') };
        }
        for my $line (split /\r?\n/, ($status->{out} // '')) {
            next unless length $line;
            next unless $line =~ /^(..)\s(.*)$/;
            my ($code, $path) = ($1, $2);
            push @files, "$code $path";
            push @paths, $path;
            if    ($code eq '??') { push @untracked, $path; }
            elsif ($code =~ /D/)  { push @deleted, $path; }
            elsif ($code =~ /A/)  { push @added, $path; }
            else                   { push @modified, $path; }
        }
    }

    my %counts = (added => scalar(@added), modified => scalar(@modified),
                  deleted => scalar(@deleted), untracked => scalar(@untracked));
    unless (@paths) {
        $ctx->{checkpoint}->('committed', { committed => 0, written => [ @written ], %counts, files => [] });
        $ctx->{note}->('nothing_to_commit', { repo => $repo, written => [ @written ] });
        return {};
    }

    my $n = scalar(@paths);
    my $subject = "backup: sync ccpraxis config ($n file(s))";
    my $add = _git_capture($repo, 'add', '--', @paths);
    unless ($add->{spawned} && $add->{exit} == 0) {
        return { failed => 'git add failed: ' . _clamp($add->{err} // '') };
    }
    my $commit = _git_capture($repo, 'commit', '-m', $subject, '-m', "run: $ctx->{run_id}", '--', @paths);
    unless ($commit->{spawned} && $commit->{exit} == 0) {
        return { failed => 'git commit failed: ' . _clamp($commit->{err} // '') };
    }
    my $new_head = _git_head($repo);
    $ctx->{checkpoint}->('committed', { committed => 1, sha => $new_head, subject => $subject,
                                        files => [ sort @files ], written => [ @written ], %counts });
    $ctx->{note}->('commit', { sha => $new_head, subject => $subject, files => [ sort @files ] });
    return {};
}

# ===========================================================================
# U9 -- promote_after_commit: run the dev clone's promote.pl so the live
# install fast-forwards to include the export commit, and ~/.claude stays
# what the payload says. No question: it promotes ONLY when every commit the
# live install lacks is a backup export commit. Anything else on main -- a
# promotion the operator skipped this run, a commit made during a pause --
# is never promoted silently; it is reported. Checkpoints
# 'promote_after_commit': { needed, ran, exit, output, commits, reason, fix }.
# ===========================================================================
sub _do_promote_after_commit {
    my ($ctx, $root, $home_n, $repo) = @_;

    my $load_err = _load_shared($root);
    return { failed => "promote_after_commit: $load_err" } if defined $load_err;

    my $rel = DevClone::relation(live_root => $root, dev_clone => $repo, git => _git_runner());
    my %d = (needed => 0, ran => 0, exit => undef, output => undef, commits => [], reason => undef, fix => undef,
             live_head => $rel->{live_head}, clone_main => $rel->{clone_main}, keep_keys => [], refusals => []);
    my $done = sub {
        my ($ret) = @_;
        my $data = _sanitize_utf8(\%d);
        $ctx->{checkpoint}->('promote_after_commit', $data);
        return $ret // {};
    };

    if (defined $rel->{error}) {
        $d{reason} = $rel->{error};
        return $done->({ failed => "promote_after_commit: $rel->{error}" });
    }
    return $done->() if $rel->{state} eq 'same';
    if ($rel->{state} eq 'live_has_own') {
        $d{reason} = 'the live install has commits the dev clone does not';
        $d{fix}    = $rel->{fix};
        $ctx->{note}->('promote_not_run', { reason => $d{reason}, fix => $d{fix} });
        return $done->();
    }

    my @commits = map { substr($_->{sha}, 0, 7) . ' ' . $_->{subject} } @{ $rel->{commits} };
    $d{commits} = \@commits;
    $d{needed}  = 1;
    my @foreign = grep { ($_->{subject} // '') !~ EXPORT_SUBJECT_RE } @{ $rel->{commits} };
    if (@foreign) {
        $d{reason} = "the dev clone's main has " . scalar(@foreign) . ' commit(s) the live install lacks that are not '
                   . 'backup exports; they are promoted only when the operator says so (promote_pending, or promote.pl)';
        $d{fix}    = 'perl ' . DevClone::git_path($repo) . '/scripts/promote.pl';
        $ctx->{note}->('promote_not_run', { reason => $d{reason}, fix => $d{fix}, commits => \@commits });
        return $done->();
    }

    # The settings units the operator answered "skip" this run: the promotion
    # must leave them exactly as ~/.claude has them (promote.pl --keep-key).
    # The remembered answers reach promote.pl through .backup-preferences.json.
    my $outcome = $ctx->{get_phase_item}->('preflight', 'settings_outcome');
    my $answers = (ref($outcome) eq 'HASH' && ref($outcome->{answers}) eq 'HASH') ? $outcome->{answers} : {};
    my @keep = map { _item_bytes($_) } sort grep { ($answers->{$_} // '') eq 'skip' } keys %$answers;
    $d{keep_keys} = \@keep;

    my $r = _run_capture(DevClone::promote_argv(dev_clone => $repo, live_root => $root, home => $home_n, keep_keys => \@keep));
    $d{ran}    = 1;
    $d{exit}   = $r->{spawned} ? $r->{exit} : -1;
    $d{output} = _clamp(join('', $r->{out} // '', (length($r->{err} // '') ? $r->{err} : '')), 8000);
    my $po = DevClone::promote_outcome(exit => $d{exit}, output => $d{output},
                                       live_head_after => _git_head($root), target => $rel->{clone_main});
    $d{refusals} = $po->{refusals};
    unless ($po->{ok}) {
        $d{reason} = $po->{reason};
        return $done->({ failed => "promote_after_commit: $d{reason}; its output is in the report" });
    }
    # Exit 1 after the fast-forward (a refused payload file): the live
    # install has the commit; the refusal lines go to the report.
    $d{reason} = $po->{reason};
    $ctx->{note}->('promote_refusals', { lines => $po->{refusals}, reason => $po->{reason} }) if defined $po->{reason};
    $ctx->{note}->('promoted_after_commit', { commits => \@commits });
    return $done->();
}

# Shared modules, loaded from the live install (the tree every wrapped script
# runs from). Returns undef on success, else why not.
sub _load_shared {
    my ($root) = @_;
    my $dir = "$root/plugins/steward/scripts";
    for my $m (qw(DevClone)) {
        next if $INC{"$m.pm"};
        return "$dir/$m.pm is missing" unless -f "$dir/$m.pm";
        local @INC = ($dir, @INC);
        my $ok = eval { require "$m.pm"; 1 };
        return "cannot load $dir/$m.pm: " . ($@ || 'unknown error') unless $ok;
    }
    return undef;
}

# DevClone's git-runner contract, over this module's own spawner (so the
# BACKUP_GIT_BIN test seam sees these calls too).
sub _git_runner {
    return sub {
        my ($dir, @args) = @_;
        my $r = _git_capture($dir, @args);
        return ($r->{spawned} ? $r->{exit} : -1, $r->{out} // '', $r->{err} // '');
    };
}

# ===========================================================================
# Child-spawning helpers (duplicated from Preflight.pm, deliberately --
# spec S2.0). List form only, never a shell string, never a pipe. Real
# File::Temp FILES for stderr/stdin capture, never an in-memory scalar
# (Git-for-Windows "Bad file descriptor"). MSYS2_ARG_CONV_EXCL is scoped to
# the single spawn, paired with _native_path() hand-translation of any path
# handed to git (CLAUDE.md's MSYS2 landmine writeup) -- never process-wide.
# ===========================================================================

sub _native_path {
    my ($p) = @_;
    return $p unless defined $p;
    (my $q = $p) =~ s{\\}{/}g;
    $q =~ s{^/([A-Za-z])/}{\u$1:/};
    return $q;
}

# MAJOR (redteam/reviewer): resolves $root's REAL git metadata directory,
# handling the "$root/.git is a FILE" layout (a linked worktree or a
# submodule redirect: "gitdir: <path>", the path possibly relative to
# $root). A plain one-line read -- deliberately NOT a git spawn: a
# redirect file whose target is a POSIX-style path (any /X/... root, as
# produced throughout this test suite) is not something git.exe's own
# `-C`-based resolution can parse either, so a git-based check would fail
# with "not a git repository" for a reason having nothing to do with
# MERGE_HEAD. Returns undef if $root has no .git at all.
sub _resolve_git_dir {
    my ($root) = @_;
    my $dotgit = "$root/.git";
    return $dotgit if -d $dotgit;
    return undef unless -f $dotgit;
    my ($text) = _read_file_raw($dotgit);
    return undef unless defined $text;
    return undef unless $text =~ /^\s*gitdir:\s*(.+?)\s*$/m;
    my $target = _native_path($1);
    # A relative gitdir target (permitted by the format) is relative to
    # the directory containing the .git file, i.e. $root.
    $target = "$root/$target" unless $target =~ m{^[A-Za-z]:/} || $target =~ m{^/};
    return $target;
}

# Ensures $s is valid UTF-8 bytes, however it arrived. backup.pl's own
# stdout JSON encoder (Run.pm's shipped contract) has no ->utf8 and cannot
# carry anything else without corrupting it into invalid UTF-8 -- see the
# call site in run_phase. Three cases, handled in order:
#   1. WIDENED (utf8-flagged) -- re-encode to bytes (CLAUDE.md: never
#      re-encode something already decoded in the OTHER direction; this is
#      the correct direction, narrowing a real Perl string to bytes).
#   2. Already valid UTF-8 bytes (the ordinary case for a real $ENV{HOME}
#      on this host) -- left untouched.
#   3. Neither -- a single-byte/Latin-1-shaped sequence, which is what a
#      bare \x{e9}-style literal produces when Perl doesn't need to widen
#      it (the codepoint fits in one byte, so the utf8 flag never gets
#      set). Reinterpreted as Latin-1 and re-encoded, since leaving it
#      alone would put a lone invalid byte into JSON output no downstream
#      consumer's UTF-8 decoder can parse.
sub _ensure_utf8_bytes {
    my ($s) = @_;
    return $s unless defined $s;
    return Encode::encode('UTF-8', $s) if utf8::is_utf8($s);
    # Encode::decode() empties its SOURCE string in place as a side effect
    # unless Encode::LEAVE_SRC is OR'd into the check flag -- validate on a
    # throwaway copy so $s itself is never touched by the probe.
    my $probe = $s;
    return $s if eval { Encode::decode('UTF-8', $probe, Encode::FB_CROAK()); 1 };
    return Encode::encode('UTF-8', Encode::decode('ISO-8859-1', $s));
}

# decode_json() (the plain function, used throughout for subprocess JSON
# output) is ->utf8 internally: any non-ASCII string value it produces
# comes back WIDENED. That is fine as long as it flows through Run.pm's
# checkpoint round-trip (both sides consistently skip ->utf8, preserving
# the logical codepoint), but the SAME decision/note payload can also be
# serialised DIRECTLY by backup.pl's stdout encoder within the very
# invocation that built it (no round-trip in between) -- and that encoder
# has no ->utf8 either, so a still-widened string corrupts on the spot
# (AC31's non-ASCII only_left key, embedded straight into a
# container_settings_key decision's data.value). Recursively downgrade
# every string in a decode_json() result to raw UTF-8 bytes IMMEDIATELY
# after parsing, so nothing widened ever reaches $ctx.
sub _sanitize_utf8 {
    my ($v) = @_;
    my $ref = ref($v);
    if ($ref eq 'HASH') {
        # MINOR (redteam): keys need the same treatment as values --
        # decode_json() widens non-ASCII keys too (a container settings
        # key or a marketplace name), and an unsanitised key reaches $ctx
        # (decision data/subject, checkpoints) still widened.
        return { map { _sanitize_utf8($_) => _sanitize_utf8($v->{$_}) } keys %$v };
    }
    if ($ref eq 'ARRAY') {
        return [ map { _sanitize_utf8($_) } @$v ];
    }
    if ($ref eq '') {
        return _ensure_utf8_bytes($v);
    }
    # JSON::PP::Boolean or any other blessed ref -- pass through unchanged.
    return $v;
}

# Mirror image of _sanitize_utf8/_ensure_utf8_bytes: widens a raw-UTF-8-byte
# scalar back to a proper Perl string. Needed only where a value that was
# downgraded for $ctx (decision/note/checkpoint) is later handed to
# _write_json_file, whose ->utf8 encoder expects widened input -- see
# _do_container_outcome's write path.
sub _widen_utf8 {
    my ($s) = @_;
    return $s unless defined $s;
    # BLOCKER (coordinator hardening, item 2): the original body bailed out
    # here on ANY ref ("return $s if ref($s)"), so a container-settings
    # value that is a hashref/arrayref (e.g. a diverged `env` object or an
    # `permissions.allow` array) was handed to _write_json_file's ->utf8
    # encoder still holding the raw-UTF-8 BYTES _sanitize_utf8 downgraded
    # it to -- double-encoding every non-ASCII string nested inside it,
    # silently, while the top-level-scalar case (AC31's fixture) stayed
    # correct. Recurse into HASH/ARRAY exactly like _sanitize_utf8 does, so
    # every leaf string is re-widened regardless of nesting depth.
    my $ref = ref($s);
    # MEDIUM-2 (red-team) / S1 (review): widen KEYS too, matching
    # Closeout.pm:987's identical fix. A key reached through a checkpoint is
    # raw UTF-8 bytes same as any value; skipping the widen on it double-
    # encodes it when _write_json_file's ->utf8 encoder runs.
    if ($ref eq 'HASH')  { return { map { _widen_utf8($_) => _widen_utf8($s->{$_}) } keys %$s }; }
    if ($ref eq 'ARRAY') { return [ map { _widen_utf8($_) } @$s ]; }
    return $s if $ref;   # JSON::PP::Boolean or any other blessed ref
    # A genuine JSON number must never be retyped as a string here (same
    # defect/fix as Closeout.pm's _widen_utf8): the Encode::decode() dance
    # below always returns a PV, discarding the IV/NV, so a followed/applied
    # object value carrying a real number (e.g. AC2's modelSettings => {a=>1})
    # would otherwise come back quoted. _json_number distinguishes a genuine
    # number (IOK/NOK, no POK) from a numeric-looking string (POK).
    return $s + 0 if _json_number($s);
    # JSON::PP->new->decode() (NO ->utf8 -- Run.pm's own read, which is
    # what get_item()/get_phase_item() ultimately return through) sets the
    # utf8 flag on EVERY decoded string regardless, WITHOUT transcoding --
    # proven empirically: decoding a value whose on-disk bytes are the
    # 2-byte UTF-8 sequence C3 A9 yields a 2-"character" string (codepoints
    # 0xC3, 0xA9 individually) with the flag already on. Trusting that flag
    # here (as _ensure_utf8_bytes correctly does for decode_json() output,
    # which DOES transcode) skips the decode step below and leaves the raw
    # bytes flagged-but-unwidened; Encode::encode() then treats each byte
    # as its OWN codepoint and double-encodes. utf8::downgrade() strips
    # that misleading flag WITHOUT touching the bytes (safe: every
    # character here is <256), so the decode step always runs against the
    # true underlying bytes.
    utf8::downgrade($s, 1);   # FAIL_OK: a genuinely-wide string is a no-op here
    my $probe = $s;
    my $widened = eval { Encode::decode('UTF-8', $probe, Encode::FB_CROAK()) };
    return defined $widened ? $widened : $s;
}

sub _json_number {
    my $f = B::svref_2object(\$_[0])->FLAGS;
    return (($f & (B::SVf_IOK | B::SVf_NOK)) && !($f & B::SVf_POK)) ? 1 : 0;
}

sub _run_capture {
    my (@cmd) = @_;
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*' if $^O =~ /^(MSWin32|cygwin|msys)$/;

    my ($efh, $ename) = File::Temp::tempfile(UNLINK => 1);
    close $efh;
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
        # BLOCKER (coordinator hardening, item 1): plain `$? >> 8` discards
        # the signal byte -- a child killed by a signal (antivirus/EDR,
        # taskkill, OOM) has raw $? == <signal number> but $?>>8 == 0,
        # INDISTINGUISHABLE FROM A CLEAN EXIT. That defeats two guarantees
        # this module exists to provide: a signal-killed sensitive-check.pl
        # would checkpoint sensitive_scan clean => 1 and open the git
        # barrier on an unscanned tree, and a signal-killed `git push`
        # would checkpoint pushed => 1 over a push that never reached the
        # remote. A non-zero signal is ALWAYS a failure and must produce a
        # non-zero $exit, distinguishable from a genuine clean exit 0.
        my $st = $?;
        $exit = ($st & 127) ? (128 + ($st & 127)) : ($st >> 8);
    }

    open(STDERR, '>&', $saved_stderr) or warn "Export: cannot restore STDERR: $!\n";
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

    open(STDIN, '<&', $saved_stdin) or warn "Export: cannot restore STDIN: $!\n";
    close $saved_stdin;
    unlink $iname;

    return $result;
}

# _git_bin -- test seam (spec S2.11): BACKUP_GIT_BIN if set/non-empty,
# else 'git'.
sub _git_bin {
    my $bin = $ENV{BACKUP_GIT_BIN};
    return (defined $bin && length $bin) ? $bin : 'git';
}

sub _git_capture {
    my ($root, @args) = @_;
    local $ENV{GIT_TERMINAL_PROMPT} = '0';
    return _run_capture(_git_bin(), '-C', _native_path($root), @args);
}

sub _git_head {
    my ($dir) = @_;
    my $r = _git_capture($dir, 'rev-parse', 'HEAD');
    return undef unless $r->{spawned} && $r->{exit} == 0;
    (my $h = $r->{out} // '') =~ s/\s+\z//;
    return length($h) ? $h : undef;
}

sub _git_current_branch {
    my ($dir) = @_;
    my $r = _git_capture($dir, 'rev-parse', '--abbrev-ref', 'HEAD');
    return undef unless $r->{spawned} && $r->{exit} == 0;
    (my $b = $r->{out} // '') =~ s/\s+\z//;
    return undef unless length($b);
    return undef if $b eq 'HEAD';
    return $b;
}

# Byte-clamp for a git status/stderr blob dropped into a failure message or
# a decision's detail -- trims on a boundary that cannot split a UTF-8
# multi-byte sequence.
sub _clamp {
    my ($s, $max) = @_;
    $max //= 4000;
    return $s unless defined $s && length($s) > $max;
    my $t = substr($s, 0, $max);
    $t =~ s/[\x80-\xBF]+\z//;
    return $t;
}

# Text clamp for a file_conflict decision's live_text/repo_text -- returns
# (possibly-truncated text, truncated flag).
sub _clamp_text {
    my ($s) = @_;
    $s = '' unless defined $s;
    my $max = 4000;
    return ($s, 0) if length($s) <= $max;
    my $t = substr($s, 0, $max);
    $t =~ s/[\x80-\xBF]+\z//;
    return ($t, 1);
}

sub _read_file_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return (undef, "cannot open $path: $!");
    local $/;
    my $data = <$fh>;
    close $fh;
    return (defined $data ? $data : '', undef);
}

sub _copy_file_bytes {
    my ($src, $dst) = @_;
    open my $ifh, '<:raw', $src or die "cannot open $src: $!";
    local $/;
    my $data = <$ifh>;
    close $ifh;
    my $dir = dirname($dst);
    make_path($dir) unless -d $dir;
    open my $ofh, '>:raw', $dst or die "cannot open $dst for write: $!";
    print {$ofh} (defined $data ? $data : '');
    close $ofh;
    return 1;
}

# id sanitisation + collision suffixing (matches Preflight.pm's _mint_ids
# exactly -- see its header comment for the emitted-vs-base-id rationale).
sub _mint_ids {
    my ($prefix, @keys) = @_;
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
# unsanitised key).
sub _title_key {
    my ($k) = @_;
    my $t = $k;
    $t =~ s/\s+/ /g;
    # MINOR (redteam): "\x{2026}" (a Perl string literal for U+2026) forces
    # the utf8 flag ON; concatenating it onto raw-UTF-8-byte $t (a
    # non-ASCII path/filename, the ordinary representation everywhere else
    # in this module) upgrades those bytes as Latin-1 -- backup.pl's
    # non-utf8 stdout encoder then mojibakes the title. Use the raw UTF-8
    # BYTES of the ellipsis instead, matching every other string this
    # module hands to $ctx.
    $t = substr($t, 0, 80) . "\xE2\x80\xA6" if length($t) > 80;
    return $t;
}

# ===========================================================================
# Small JSON file helpers (container settings.json read/write ONLY --
# everything else this module reads is read via a wrapped script, never
# parsed directly by us). Matches Preflight.pm's B1/B2/B3 fixes exactly.
# ===========================================================================

# ($data, $err): absent -> ({}, undef); unopenable/unparseable -> (undef,
# $error). Only "absent" may seed an empty structure -- a write is refused
# on any $err so an unreadable/unparseable file is never overwritten.
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

# Nests a dotted parent.child key on the first '.' when the parent slot is
# absent or already a hash; otherwise falls back to a flat write.
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

# Mirror image of _assign_nested: removes only the leaf, never the whole
# parent object -- {"env":{"A":1,"B":2}} minus "env.B" leaves
# {"env":{"A":1}}. Returns 0 when the key was not present.
sub _delete_nested {
    my ($data, $key) = @_;
    if ($key =~ /^([^.]+)\.(.+)\z/ && ref($data->{$1}) eq 'HASH') {
        my ($parent, $child) = ($1, $2);
        return 0 unless exists $data->{$parent}{$child};
        delete $data->{$parent}{$child};
        delete $data->{$parent} unless %{ $data->{$parent} };
        return 1;
    }
    else {
        return 0 unless exists $data->{$key};
        delete $data->{$key};
        return 1;
    }
}

sub _write_json_file {
    my ($path, $data) = @_;
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
    # ->utf8 makes encode() return well-formed UTF-8 BYTES for a :raw
    # handle -- a bare encode() without it would serialise a widened
    # non-ASCII character as a single Latin-1 byte (package 02's blocker
    # B1; this host's own home is C:\Users\Andr\x{e9}).
    my $json = JSON::PP->new->utf8->canonical->pretty->encode($data);
    my ($fh, $tmp) = File::Temp::tempfile('export-write-XXXXXXXX', DIR => $dir, UNLINK => 0);
    binmode $fh;
    print {$fh} $json;
    close $fh;
    unless (rename $tmp, $path) {
        my $err = $!;
        unlink $tmp;
        die "Export: cannot rename $tmp -> $path: $err\n";
    }
    return 1;
}

1;
