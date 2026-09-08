# Export.pm -- backup driver phase 03-export-and-push (blueprint
# backup-driver).
#
# Absorbs today's SKILL.md Steps 2 (detect differences), 3 (handle each
# file + settings merge), 3.5 (container settings sync), 4 (sensitive-data
# scan) and 5 (commit and push). See the spec for the full contract:
#   .ccpraxis-local-data/blueprints/backup-driver/specs/03-export-and-push-spec.md
# including its BINDING coordinator rulings (S8, P10-P12), which supersede
# anything earlier in that document that conflicts.
#
# THIS MODULE WRAPS EXISTING SCRIPTS. It reimplements none of their logic --
# no JSON diffing, no preference matching, no merge algorithm, no secret
# scanning. Its job is ordering, exit-code interpretation, turning
# genuinely-undecided things into decision records, applying answered
# choices, checkpointing so an interrupted run does not redo finished work,
# and making a mid-push death safe.
#
# THE REPOSITORY EVERY GIT OPERATION TARGETS is <home>/.claude/ccpraxis (the
# live install / export repo) -- never the dev clone. Decision 4 forbids
# this module from touching the clone/live relationship at all.
#
# Decision 4 + ruling R6 (01-driver-skeleton-spec.md S8): the push NEVER
# happens without an explicitly answered push_confirmation, and R6 wipes a
# phase's stored answers/items on re-entry after a "running" (mid-execution
# kill) prior status -- so consent can never be silently replayed. Because
# R6 wipes checkpoints too, this module never trusts its own state to know
# whether a push already happened after a crash; it asks GIT: a clean
# worktree with 0 unpushed commits means the push already completed (no
# second push, no decision asked); N > 0 unpushed means it died between
# commit and push (ask again); a dirty worktree means it died before the
# commit (ask again with the full pending set). See _do_commit_review /
# _do_push_confirmation_and_push.
#
# Ruling P10 (spec S8): sync-export.pl's real emitted status set is
# {export_only, identical, linked, live_only, missing, not_linked,
# settings_changed, tracked} -- NOT the SKILL.md-documented set (which
# includes three statuses -- conflict, container_settings_diverged,
# marketplace_changed -- that are never actually emitted). This module
# branches on the REAL set; an unrecognised status is a reported unit
# failure, never silently ignored. file_conflict decisions are driven by
# not_linked (a live regular file that differs from the repo copy) rather
# than the never-emitted 'conflict' (handled generically too, in case a
# future sync-export.pl version emits it).
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
# four kinds: file_conflict, container_settings_key, sensitive_finding,
# push_confirmation.
#
# Decision 7 barriers, enforced in code (not prose):
#   B1 -- the container diff (U5/U6) does not run unless settings_merge
#         (U4) checkpointed (on either its success path or its
#         nothing-to-merge path). A failed U4 leaves the key unset, so U5/U6
#         are skipped this pass.
#   B2 -- no git verb of any kind is spawned until sensitive_scan (U7)
#         checkpoints clean. U8/U9 are both gated on is_done('sensitive_scan').
#   B3 -- sensitive_finding is never batched with anything else (returned
#         alone, immediately); push_confirmation is likewise always the
#         sole decision in its needs_decision return.
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

# ===========================================================================
# phase_spec / run_phase -- the contract package 01 (Run.pm) requires.
# ===========================================================================

sub phase_spec {
    return {
        name      => 'export',
        order     => 200,   # spec S8 P2: preflight=100, export=200, vault=300, closeout=400
        resumable => 1,
        title     => 'Export: file differences, settings merge, container settings, sensitive scan, commit and push',
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
    # checkpoint this module builds embeds $root somewhere (subject, title,
    # path fields), so normalise ONCE here and everything downstream
    # inherits guaranteed-valid UTF-8 bytes.
    $home_n = _ensure_utf8_bytes($home_n);
    my $root = "$home_n/.claude/ccpraxis";
    unless (-d $root) {
        return { status => 'failed', error => "ccpraxis install not found at $root" };
    }

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
    my @failed_units;   # [ unit_name, message ] -- still used for the
                         # push_confirmation warning text (THIS invocation
                         # only; unchanged behaviour).
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
        my $res = _do_file_status($ctx, $root);
        if ($res->{failed}) { $record_failure->('file_status', $res->{failed}); }
        else                 { $record_success->('file_status'); }
    }

    # U2/U3 depend on U1 having reached a definite conclusion (spec S2.9:
    # "U1 failed -> U2/U3 skipped; U4 onward still run").
    if ($ctx->{is_done}->('file_status')) {
        # ---- U2: file_conflicts (Step 3, may pause as a batch) ----
        unless ($ctx->{is_done}->('file_conflicts')) {
            my $res = _do_file_conflicts($ctx, $root, $home_n);
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

        # ---- U3: file_outcome (apply answered file_conflict choices) ----
        if ($ctx->{is_done}->('file_conflicts')) {
            unless ($ctx->{is_done}->('file_outcome')) {
                my $res = _do_file_outcome($ctx, $root, $home_n);
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
        my $res = _do_settings_merge($ctx, $root);
        if ($res->{failed}) { $record_failure->('settings_merge', $res->{failed}); }
        else                 { $record_success->('settings_merge'); }
    }

    # ---- U5/U6: container settings sync (Step 3.5) -- BARRIER B1: gated on
    #      settings_merge having checkpointed (either success or the
    #      nothing-to-merge path). A failed U4 leaves this unset. ----
    if ($ctx->{is_done}->('settings_merge')) {
        unless ($ctx->{is_done}->('container_diff')) {
            my $res = _do_container_diff($ctx, $root, $home_n);
            if ($res->{decisions}) {
                $record_success->('container_diff');   # see file_conflicts' identical comment above
                return { status => 'needs_decision', decisions => $res->{decisions} };
            }
            if ($res->{failed}) { $record_failure->('container_diff', $res->{failed}); }
            else                 { $record_success->('container_diff'); }
        }

        if ($ctx->{is_done}->('container_diff')) {
            unless ($ctx->{is_done}->('container_outcome')) {
                my $res = _do_container_outcome($ctx, $root);
                if ($res->{failed}) { $record_failure->('container_outcome', $res->{failed}); }
                else                 { $record_success->('container_outcome'); }
            }
        }
    }

    # ---- U7: sensitive_scan (Step 4) -- BARRIER B3: always alone. ----
    unless ($ctx->{is_done}->('sensitive_scan')) {
        my $res = _do_sensitive_scan($ctx, $root);
        if ($res->{pause}) {
            $record_success->('sensitive_scan');   # see file_conflicts' identical comment above
            return { status => 'needs_decision', decisions => [ $res->{pause} ] };
        }
        if ($res->{failed}) { $record_failure->('sensitive_scan', $res->{failed}); }
        else                 { $record_success->('sensitive_scan'); }
    }

    # ---- U8/U9: commit review + push (Step 5) -- BARRIER B2: no git verb
    #      of any kind may be spawned until sensitive_scan checkpointed
    #      clean. ----
    if ($ctx->{is_done}->('sensitive_scan')) {
        unless ($ctx->{is_done}->('commit_review')) {
            my $res = _do_commit_review($ctx, $root);
            if ($res->{failed}) { $record_failure->('commit_review', $res->{failed}); }
            else                 { $record_success->('commit_review'); }
        }

        if ($ctx->{is_done}->('commit_review')) {
            unless ($ctx->{is_done}->('pushed')) {
                my $res = _do_push_confirmation_and_push($ctx, $root, \@failed_units, $load_failures);
                if ($res->{pause}) {
                    $record_success->('pushed');   # see file_conflicts' identical comment above
                    return { status => 'needs_decision', decisions => [ $res->{pause} ] };
                }
                if ($res->{failed}) { $record_failure->('pushed', $res->{failed}); }
                else                 { $record_success->('pushed'); }
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

# ===========================================================================
# U1 -- file_status (sync-export.pl). Never pauses.
# ===========================================================================
sub _do_file_status {
    my ($ctx, $root) = @_;

    my $r = _run_capture($^X, "$root/plugins/steward/scripts/sync-export.pl");
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
# U2 -- file_conflicts (Step 3). Ruling P10: branch on the REAL status set;
# not_linked (live regular file differing from the repo copy) is the
# both-sides-differ signal on this Windows host; a live DIRECTORY is a note,
# never a decision. An unrecognised status is a reported unit failure.
# ===========================================================================
sub _do_file_conflicts {
    my ($ctx, $root, $home_n) = @_;

    my $status_arr = $ctx->{get_item}->('file_status');
    $status_arr = [] unless ref($status_arr) eq 'ARRAY';

    my @conflict_items;
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
        elsif ($status eq 'not_linked' || $status eq 'conflict') {
            my $live_path = "$home_n/.claude/$file";
            my $repo_path = "$root/$file";
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
            push @conflict_items, { file => $file, live_path => $live_path, repo_path => $repo_path,
                                     live_text => $live_text, repo_text => $repo_text };
        }
        else {
            return { failed => "sync-export.pl reported an unrecognized status '$status' for '$file'" };
        }
    }

    unless (@conflict_items) {
        $ctx->{checkpoint}->('file_conflicts', []);
        return {};
    }

    my @pairs = _mint_ids('export.file_conflict', map { $_->{file} } @conflict_items);
    my @decisions;
    for my $i (0 .. $#conflict_items) {
        my ($file, $id) = @{ $pairs[$i] };
        my $it = $conflict_items[$i];
        my ($lt, $lt_trunc) = _clamp_text($it->{live_text});
        my ($rt, $rt_trunc) = _clamp_text($it->{repo_text});
        push @decisions, $ctx->{decision}->(
            kind    => 'file_conflict',
            id      => $id,
            title   => "file '" . _title_key($file) . "' differs between live and the repo",
            subject => $file,
            detail  => '',
            data    => { file => $file, live_path => $it->{live_path}, repo_path => $it->{repo_path},
                         live_text => $lt, repo_text => $rt,
                         live_bytes => length($it->{live_text}), repo_bytes => length($it->{repo_text}),
                         truncated => ($lt_trunc || $rt_trunc) ? 1 : 0 },
            choices => [
                { id => 'use_live',       label => 'Use the live version (copy live over the repo copy)' },
                { id => 'use_export',     label => 'Use the export/repo version (copy repo over the live copy)' },
                { id => 'merge_manually', label => 'Merge manually (write nothing; report both paths)' },
            ],
        );
    }

    # Checkpoint just the paths (not the bulky text) -- U3 only needs these
    # to perform the byte-copy; the text was only needed transiently to
    # build the decision's data payload.
    my @inventory = map { { file => $_->{file}, live_path => $_->{live_path}, repo_path => $_->{repo_path} } }
                    @conflict_items;
    $ctx->{checkpoint}->('file_conflicts', \@inventory);

    return { decisions => \@decisions };
}

# ===========================================================================
# U3 -- file_outcome: apply answered file_conflict choices. use_live/
# use_export byte-copy; merge_manually writes nothing (ruling P12) and
# records an instruction note naming both paths.
# ===========================================================================
sub _do_file_outcome {
    my ($ctx, $root, $home_n) = @_;

    my $inventory = $ctx->{get_item}->('file_conflicts');
    $inventory = [] unless ref($inventory) eq 'ARRAY';
    return {} unless @$inventory;

    my @pairs = _mint_ids('export.file_conflict', map { $_->{file} } @$inventory);
    my (@resolved, @instructions, @failed_msgs);

    for my $i (0 .. $#$inventory) {
        my ($file, $id) = @{ $pairs[$i] };
        my $it     = $inventory->[$i];
        my $choice = $ctx->{answers}{$id};
        next unless defined $choice;

        if ($choice eq 'use_live') {
            my $ok = eval { _copy_file_bytes($it->{live_path}, $it->{repo_path}); 1 };
            if ($ok) { push @resolved, { file => $file, choice => $choice }; }
            else      { push @failed_msgs, "file_conflict '$file': cannot copy live->repo: $@"; }
        }
        elsif ($choice eq 'use_export') {
            my $ok = eval { _copy_file_bytes($it->{repo_path}, $it->{live_path}); 1 };
            if ($ok) { push @resolved, { file => $file, choice => $choice }; }
            else      { push @failed_msgs, "file_conflict '$file': cannot copy repo->live: $@"; }
        }
        elsif ($choice eq 'merge_manually') {
            push @instructions, { file => $file, live_path => $it->{live_path}, repo_path => $it->{repo_path} };
        }
    }

    $ctx->{note}->('file_conflicts_resolved', \@resolved) if @resolved;
    $ctx->{note}->('file_conflict_merge_manually', \@instructions) if @instructions;
    $ctx->{checkpoint}->('file_outcome', { resolved => \@resolved, instructions => \@instructions });

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
    my ($ctx, $root) = @_;

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

    my @args = ('settings-export-merge');
    push @args, ('--skip-key', $_) for @$skip_keys;
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
    my ($ctx, $root, $home_n) = @_;

    my $container_path = "$root/plugins/sandbox/container/settings.json";
    my $global_path     = "$root/global-config/settings.json";

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
    my ($ctx, $root) = @_;

    my $diff = $ctx->{get_item}->('container_diff');
    my @decisions = (ref($diff) eq 'HASH') ? _container_decisions($ctx, $diff) : ();
    return {} unless @decisions;

    my $container_path = "$root/plugins/sandbox/container/settings.json";
    my $prefs_path      = "$root/.backup-preferences.json";
    my (@applied, @removed, @prefs_saved, @failed_msgs);
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
            my $v = $d->{data}{value};
            $writes{$key} = (ref($v) eq 'HASH') ? $v->{left} : $v;
            $need_write = 1;
            push @applied, $key;
        }
        elsif ($rel eq 'only_left' && $choice eq 'add_to_container') {
            $writes{$key} = $d->{data}{value};
            $need_write = 1;
            push @applied, $key;
        }
        elsif ($rel eq 'only_right' && $choice eq 'remove_from_container') {
            $deletes{$key} = 1;
            $need_write = 1;
            push @removed, $key;
        }
    }

    if ($need_write) {
        my ($data, $read_err) = _read_or_init_json_file($container_path);
        if (defined $read_err) {
            push @failed_msgs, "container_outcome: $read_err";
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
            # consistent with this.
            _assign_nested($data, $_, _widen_utf8($writes{$_})) for keys %writes;
            _delete_nested($data, $_) for keys %deletes;
            my $ok = eval { _write_json_file($container_path, $data); 1 };
            push @failed_msgs, "container_outcome: cannot write $container_path: $@" unless $ok;
        }
    }

    $ctx->{checkpoint}->('container_outcome', { applied => \@applied, removed => \@removed,
                                                  preferences_saved => \@prefs_saved });
    $ctx->{note}->('container_preferences_saved', \@prefs_saved) if @prefs_saved;

    my $ret = {};
    $ret->{failed} = join('; ', @failed_msgs) if @failed_msgs;
    return $ret;
}

# ===========================================================================
# Container decision builders -- pure functions of the checkpointed diff
# data, so U6 can regenerate the SAME ids deterministically without
# re-running json-diff.pl/filter-diff.pl.
# ===========================================================================
sub _container_items_ordered {
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
    my ($ctx, $root) = @_;

    my $attempt = _sensitive_attempt($ctx);
    my $id      = "export.sensitive_finding.$attempt";
    my $answer  = $ctx->{answers}{$id};
    if (defined $answer && $answer eq 'abort') {
        return { failed => 'sensitive scan: aborted by operator (findings not resolved)' };
    }

    my $r = _run_capture($^X, "$root/plugins/steward/scripts/sensitive-check.pl", $root);
    unless ($r->{spawned}) {
        return { failed => 'sensitive-check.pl failed to spawn' };
    }
    if ($r->{exit} == 0) {
        $ctx->{checkpoint}->('sensitive_scan', { attempt => $attempt, clean => 1 });
        $ctx->{note}->('sensitive_scan', { attempt => $attempt, clean => 1 });
        return {};
    }
    if ($r->{exit} == 1) {
        my ($detail, $data) = _parse_sensitive_findings($r->{out});
        my $dec = $ctx->{decision}->(
            kind    => 'sensitive_finding',
            id      => $id,
            title   => "the sensitive-data scan found $data->{count} match(es) in $data->{file_count} file(s)",
            subject => $root,
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
# U8 -- commit_review (Step 5, part 1). Ruling P4: refuse while MERGE_HEAD
# exists. Read-only: computes the pending change set and unpushed-commit
# count without staging anything. Recomputed fresh whenever this unit is
# not yet checkpointed -- which, after an R6/R1 clear, is what makes the
# post-crash "ask git" behaviour (S2.6) work without any special-casing.
# ===========================================================================
sub _do_commit_review {
    my ($ctx, $root) = @_;

    # MAJOR (redteam/reviewer): `-f "$root/.git/MERGE_HEAD"` is a pure
    # filesystem probe that silently never fires when $root/.git is not a
    # directory -- exactly the case for a linked worktree or a submodule,
    # where .git is a FILE containing "gitdir: <path elsewhere>". Ruling
    # P4 then never fires and a merge-in-progress (conflict markers and
    # all) is committed and pushed into the only backup. Resolve the REAL
    # git-dir first (a plain one-line file read -- no git spawn needed,
    # and none would help: a redirect file written with a POSIX-style
    # target, as any /c/... style root produces, is NOT something git.exe
    # itself can resolve via `-C`, so a `git rev-parse` here would fail
    # with "not a git repository" for reasons unrelated to MERGE_HEAD).
    my $git_dir = _resolve_git_dir($root);
    if (defined $git_dir && -f "$git_dir/MERGE_HEAD") {
        return { failed => 'a merge is in progress (MERGE_HEAD present) -- resolve it before committing' };
    }

    # MAJOR (redteam/reviewer): `--is-inside-work-tree` succeeds from a
    # SUBDIRECTORY of a repo too (git walks up to find one) -- it does not
    # prove $root IS the top level. A ccpraxis install that is a plain
    # directory (a copy, not a clone) sitting inside an ancestor repo
    # (e.g. ~/.claude itself a repo) would silently target that ancestor:
    # `git add -A` (no pathspec) sweeps the WHOLE ancestor worktree, and
    # sensitive-check.pl only ever scanned $root, so anything outside it
    # (~/.claude/.credentials*.json) reaches the remote unscanned. Compare
    # against --show-toplevel instead.
    my $top = _git_capture($root, 'rev-parse', '--show-toplevel');
    unless ($top->{spawned} && $top->{exit} == 0) {
        return { failed => 'not a git repository' };
    }
    (my $t = $top->{out} // '') =~ s/\s+\z//;
    # HARDEN item4a-followup: this used to compare $t and $root as plain
    # STRINGS. A directory has many spellings that all name the exact same
    # entry (an 8.3 short name, a doubled separator embedded mid-path, `\`
    # vs `/`, a symlink hop) -- git always answers --show-toplevel in its
    # own canonical spelling, which need not match whatever spelling $root
    # happens to carry, so a textual compare rejects real matches for a
    # reason that has nothing to do with the thing this check exists to
    # catch (a $root that is a genuine SUBDIRECTORY of the real top level).
    # Resolve both sides to their real, canonical path first and compare
    # THAT -- Cwd::abs_path (realpath) collapses exactly this class of
    # spelling difference while still distinguishing a true ancestor/
    # descendant pair, which is what item4a (above) still needs refused.
    my $root_real = abs_path(_native_path($root));
    my $top_real  = abs_path(_native_path($t));
    # abs_path returns undef when it cannot resolve a path at all (a
    # missing component, a permission error, a broken link) rather than
    # for a mere spelling difference. $root is already known to exist --
    # run_phase's own `-d $root` check ran before this unit could be
    # reached -- so a resolution failure here is a genuinely exceptional
    # filesystem condition, not the common case this fix targets. Refuse
    # (the safe direction: this check exists to stop unscanned content
    # outside $root reaching the remote via an unqualified `git add -A`),
    # but keep the message narrow and name both raw paths so the operator
    # can act on it rather than guess.
    unless (defined $root_real && defined $top_real) {
        return { failed => "cannot resolve '$root' or the reported top level '$t' to a canonical path -- refusing to assume they name the same directory" };
    }
    unless (_native_path($root_real) eq _native_path($top_real)) {
        return { failed => "$root is not the top level of its git repository (that is " . _clamp($t, 300) . ")" };
    }

    # core.quotePath=false: git's default quotes any path containing
    # non-ASCII bytes as a C-style-escaped string ("caf\303\251.txt")
    # rather than the real filename -- harmless while this list was only
    # ever DISPLAYED, but MAJOR-5's fix below stages exactly these paths
    # via `git add --`, where the quoted form is not a real pathspec and
    # `git add` fails outright on any non-ASCII filename.
    my $status = _git_capture($root, '-c', 'core.quotePath=false', 'status', '--porcelain', '--untracked-files=all');
    unless ($status->{spawned} && $status->{exit} == 0) {
        return { failed => 'git status failed: ' . _clamp($status->{err} // '') };
    }

    my (@added, @modified, @deleted, @untracked, @files);
    for my $line (split /\r?\n/, ($status->{out} // '')) {
        next unless length $line;
        next unless $line =~ /^(..)\s(.*)$/;
        my ($code, $path) = ($1, $2);
        push @files, "$code $path";
        if    ($code eq '??') { push @untracked, $path; }
        elsif ($code =~ /D/)  { push @deleted, $path; }
        elsif ($code =~ /A/)  { push @added, $path; }
        else                   { push @modified, $path; }
    }

    my $branch = _git_current_branch($root);
    my $remote_list = _git_capture($root, 'remote');
    my $has_origin = 0;
    if ($remote_list->{spawned} && $remote_list->{exit} == 0) {
        $has_origin = 1 if grep { $_ eq 'origin' } split(/\r?\n/, $remote_list->{out} // '');
    }

    my $unpushed;
    if ($has_origin && defined($branch) && $branch eq 'main') {
        my $rl = _git_capture($root, 'rev-list', '--count', 'origin/main..HEAD');
        if ($rl->{spawned} && $rl->{exit} == 0) {
            (my $n = $rl->{out} // '0') =~ s/\s+//g;
            $unpushed = $n + 0 if $n =~ /^\d+$/;
        }
    }

    my $data = {
        has_origin => $has_origin, branch => $branch,
        added => scalar(@added), modified => scalar(@modified),
        deleted => scalar(@deleted), untracked => scalar(@untracked),
        files => \@files, unpushed_commits => $unpushed,
    };
    $ctx->{checkpoint}->('commit_review', $data);
    return {};
}

# ===========================================================================
# U9 -- push_confirmation + stage/commit/push (Step 5, part 2). Decision 4:
# the push never happens without an explicitly answered push_confirmation.
# Nothing is staged before consent (U8 only reads). Checkpoints staged /
# committed / pushed the instant each git call returns, so a mid-push kill
# leaves an accurate record for the NEXT invocation's git-truth check.
# ===========================================================================
sub _do_push_confirmation_and_push {
    my ($ctx, $root, $failed_units_ref, $load_failures_ref) = @_;

    my $review = $ctx->{get_item}->('commit_review');
    return { failed => 'commit_review data missing' } unless ref($review) eq 'HASH';

    my $n_changes = ($review->{added} // 0) + ($review->{modified} // 0)
                   + ($review->{deleted} // 0) + ($review->{untracked} // 0);
    my $unpushed        = $review->{unpushed_commits};
    my $nothing_pending  = ($n_changes == 0);

    # MAJOR (redteam MAJOR-3): "already in sync" and "no remote configured"
    # are DIFFERENT facts and must not collapse into one note/reason. "In
    # sync" asserts there IS a remote and it is confirmed caught up; with
    # no origin at all there is nothing to be in sync WITH, and reporting
    # it anyway tells the operator they are backed up when there has never
    # been an off-machine copy.
    if ($nothing_pending && !$review->{has_origin}) {
        $ctx->{checkpoint}->('staged', { staged => 0 });
        $ctx->{checkpoint}->('committed', { committed => 0 });
        $ctx->{checkpoint}->('pushed', { pushed => 0, reason => 'no remote configured' });
        $ctx->{note}->('no_remote_configured', { root => $root });
        return {};
    }
    # An unresolvable ahead-count (fresh remote, never fetched) must ask
    # rather than assume synced (spec S5 edge case) -- only a CONFIRMED
    # unpushed == 0 short-circuits here.
    if ($nothing_pending && defined($unpushed) && $unpushed == 0) {
        $ctx->{checkpoint}->('staged', { staged => 0 });
        $ctx->{checkpoint}->('committed', { committed => 0 });
        $ctx->{checkpoint}->('pushed', { pushed => 0, reason => 'already in sync' });
        $ctx->{note}->('already_in_sync', { root => $root });
        return {};
    }

    my $id     = 'export.push_confirmation';
    my $answer = $ctx->{answers}{$id};

    # MAJOR (redteam MAJOR-4 / reviewer M1): $offer_push is false for THREE
    # distinct reasons (no origin at all, detached HEAD, non-main branch)
    # that a single hard-coded "no remote is configured" label collapsed
    # into one -- factually false in the second and third cases, telling
    # the operator to do something (configure a remote) that is already
    # done. Compute and surface the REAL reason.
    my $push_reason;
    if    (!$review->{has_origin})            { $push_reason = 'no remote is configured'; }
    elsif (!defined($review->{branch}))        { $push_reason = 'HEAD is detached (not on any branch)'; }
    elsif ($review->{branch} ne 'main')        { $push_reason = "the current branch is '" . _title_key($review->{branch}) . "', not main"; }
    my $offer_push = !defined($push_reason);

    # MAJOR (redteam MAJOR-7): the decision never named WHERE the push
    # goes -- $root/subject/title are all the SOURCE. The operator
    # consents to publish their whole config tree without being shown the
    # destination. `remote` is on AC37's allowed-verb list.
    my $remote_url;
    if ($review->{has_origin}) {
        my $ru = _git_capture($root, 'remote', 'get-url', 'origin');
        if ($ru->{spawned} && $ru->{exit} == 0) {
            ($remote_url = $ru->{out} // '') =~ s/\s+\z//;
            # Displayed paths throughout this module stay in the SAME
            # POSIX-style form $root is kept in (never the native
            # drive-letter form git hands back for a local-path remote) --
            # inverse of _native_path, a no-op for a genuine URL scheme.
            $remote_url =~ s{\\}{/}g;
            $remote_url =~ s{^([A-Za-z]):/}{'/' . lc($1) . '/'}e;
            $remote_url = _redact_credentials($remote_url);
        }
    }

    unless (defined $answer) {
        my @choices = $offer_push
            ? ( { id => 'push',   label => 'Push it (commit and push to origin main)' },
                { id => 'abort',  label => 'Abort (nothing staged, nothing committed, nothing pushed)' } )
            : ( { id => 'commit_only', label => "Commit only ($push_reason -- push not offered)" },
                { id => 'abort',       label => 'Abort (nothing staged, nothing committed)' } );

        my @lines;
        push @lines, sprintf('modified: %d, deleted: %d, added: %d, untracked: %d',
            $review->{modified} // 0, $review->{deleted} // 0, $review->{added} // 0, $review->{untracked} // 0);
        push @lines, 'remote: ' . $remote_url if defined $remote_url;
        my @files = sort @{ $review->{files} // [] };
        my $shown = 0;
        for my $f (@files) {
            last if $shown >= 200;
            push @lines, $f;
            $shown++;
        }
        push @lines, '... and ' . (scalar(@files) - 200) . ' more' if scalar(@files) > 200;
        push @lines, 'unpushed commits: ' . (defined $unpushed ? $unpushed : 'unknown');

        my $settings_merge = $ctx->{get_item}->('settings_merge');
        my $skip_unmatched = (ref($settings_merge) eq 'HASH' && ref($settings_merge->{skip_keys_unmatched}) eq 'ARRAY')
            ? $settings_merge->{skip_keys_unmatched} : [];
        if (@$skip_unmatched) {
            push @lines, 'WARNING: ' . scalar(@$skip_unmatched) . ' skip-key(s) matched nothing: '
                       . join(', ', @$skip_unmatched);
        }
        # MAJOR (redteam MAJOR-2): the durable unit_failures record (P13),
        # NOT the per-invocation @failed_units lexical -- a unit that
        # failed and checkpointed anyway (U3/U6, "never retried") on an
        # EARLIER invocation must still show here on a LATER one, or
        # consent is given blind to a merge that never happened.
        my $durable_failures = $load_failures_ref->();
        my (%seen_unit, @failed_names);
        for my $pair (@$failed_units_ref) {
            my $u = $pair->[0];
            next unless exists $durable_failures->{$u};
            next if $seen_unit{$u}++;
            push @failed_names, $u;
        }
        for my $u (sort keys %$durable_failures) {
            next if $seen_unit{$u}++;
            push @failed_names, $u;
        }
        if (@failed_names) {
            push @lines, 'WARNING: ' . scalar(@failed_names) . ' earlier step(s) failed: ' . join(', ', @failed_names);
        }
        if (!$offer_push) {
            $ctx->{note}->('push_not_offered', { reason => $push_reason, branch => $review->{branch}, has_origin => $review->{has_origin} });
        }

        my $dec = $ctx->{decision}->(
            kind    => 'push_confirmation',
            id      => $id,
            # MINOR (redteam): Run.pm's validate_decision rejects a title
            # over 200 chars and $ctx->{decision} DIES on rejection -- a
            # long $root (a redirected/roaming HOME, a deep test scratch
            # root) would abort the whole run on a purely environmental
            # condition. Clamp the title; $root stays intact in subject/data.
            title   => 'commit and push ' . $n_changes . ' change(s) to ' . _title_key($root) . '?',
            subject => $root,
            detail  => join("\n", @lines),
            data    => { modified => $review->{modified}, deleted => $review->{deleted},
                         added => $review->{added}, untracked => $review->{untracked},
                         files => \@files, unpushed_commits => $unpushed,
                         remote_url => $remote_url },
            choices => \@choices,
        );
        return { pause => $dec };
    }

    if ($answer eq 'abort') {
        $ctx->{checkpoint}->('pushed', { pushed => 0, reason => 'aborted by operator' });
        $ctx->{note}->('push_aborted', { root => $root });
        return {};
    }

    unless ($nothing_pending) {
        # MAJOR (redteam MAJOR-5): commit_review snapshots the pending set
        # ONCE, checkpointed; an unbounded human pause sits between that
        # and this `git add`, and merge_manually (P12) actively invites an
        # edit in that very window. `git add -A` would sweep the LIVE
        # worktree -- anything that appeared during the pause (never
        # reviewed, never scanned for secrets) alongside it. Stage exactly
        # the reviewed set instead.
        my @paths;
        for my $f (@{ $review->{files} // [] }) {
            (my $p = $f) =~ s/^..\s//;
            next unless length $p;
            # $review came back through $ctx->{get_item} -- Run.pm's own
            # read (NO ->utf8, per _widen_utf8's doc comment above) sets
            # the utf8 flag on every decoded string WITHOUT transcoding,
            # so a non-ASCII path survives the checkpoint round-trip
            # flagged-but-unwidened. Passed straight to `git add --` as
            # argv, that mis-flagging silently mangles the bytes (proven:
            # AC24's non-ASCII fixture) and `git add` fails outright with
            # "pathspec did not match any files". Re-widen exactly like
            # the container-settings write path already does.
            push @paths, _widen_utf8($p);
        }
        my $add = @paths ? _git_capture($root, 'add', '--', @paths)
                          : _git_capture($root, 'add', '-A');
        unless ($add->{spawned} && $add->{exit} == 0) {
            return { failed => 'git add failed: ' . _clamp($add->{err} // '') };
        }
        $ctx->{checkpoint}->('staged', { staged => 1, files => $n_changes });
        $ctx->{note}->('staged_files', { count => $n_changes });

        my $subject = "backup: sync ccpraxis config ($n_changes file(s))";
        my $commit = _git_capture($root, 'commit', '-m', $subject, '-m', "run: $ctx->{run_id}");
        unless ($commit->{spawned} && $commit->{exit} == 0) {
            return { failed => 'git commit failed: ' . _clamp($commit->{err} // '') };
        }
        my $new_head = _git_head($root);
        $ctx->{checkpoint}->('committed', { sha => $new_head, subject => $subject });
        $ctx->{note}->('commit', { sha => $new_head, subject => $subject });
    }
    else {
        $ctx->{checkpoint}->('staged', { staged => 0 })       unless $ctx->{is_done}->('staged');
        $ctx->{checkpoint}->('committed', { committed => 0 }) unless $ctx->{is_done}->('committed');
    }

    if ($answer eq 'commit_only') {
        $ctx->{checkpoint}->('pushed', { pushed => 0, reason => ($push_reason // 'no remote configured') });
        $ctx->{note}->('commit_only', { root => $root });
        return {};
    }

    my $push = _git_capture($root, 'push', 'origin', 'main');
    # MAJOR (redteam MAJOR-6): git prints the configured remote URL,
    # userinfo included, in transport/auth failure text -- redact BEFORE
    # this reaches the checkpoint, notes or a failure message, all three
    # of which land in the on-disk state file / package 05's report.
    my $push_err = _redact_credentials($push->{err} // '');
    my ($verdict, $warnings) = _classify_push($push->{exit}, $push_err);
    if ($verdict eq 'pushed') {
        # BLOCKER (coordinator hardening, item 1 effect B): `git` here is
        # whatever _git_bin() resolves to -- on this host that is
        # frequently a wrapper spawned through a native shell (spec
        # S2.11's BACKUP_GIT_BIN test seam is exactly this shape). Windows
        # process exit codes carry no signal bit, and the POSIX-style
        # wait-status this module (and Perl's own $?) computes for a
        # foreign child only ever keeps the LOW byte of that code -- a
        # push client killed by a signal one hop down can leave the exit
        # code this module observes looking exactly like a clean 0. Do
        # not trust "exit 0" alone for something this consequential:
        # confirm independently, by asking the REMOTE itself (read-only,
        # `ls-remote`, already local-only in every test scenario) that it
        # actually advanced to the commit just made, before recording a
        # durable pushed => 1.
        my $new_head = _git_head($root);
        if (defined $new_head && length $new_head) {
            my $confirm = _git_capture($root, 'ls-remote', 'origin', 'refs/heads/main');
            if ($confirm->{spawned} && $confirm->{exit} == 0) {
                (my $remote_sha) = split /\s+/, ($confirm->{out} // '');
                if (!defined($remote_sha) || $remote_sha ne $new_head) {
                    return { failed => 'git push reported success (exit ' . $push->{exit}
                        . ') but origin/main does not reflect the new commit -- the exit code'
                        . ' cannot be trusted here (e.g. a signal-killed push client); treating'
                        . ' this as a failed push rather than recording a false pushed:1' };
                }
            }
        }
        $ctx->{checkpoint}->('pushed', { pushed => 1, exit => $push->{exit}, warnings => $warnings });
        $ctx->{note}->('push_warnings', $warnings) if @$warnings;
        return {};
    }
    return { failed => "git push rejected (exit $push->{exit}): " . _clamp($push_err) };
}

# Exit-code-only verdict (spec S2.6): exit 0 is ALWAYS 'pushed', regardless
# of stderr content -- a protected-ref bypass warning with exit 0 is a
# documented SUCCESS (.ccpraxis-local-data/guidance/push-straight-to-main.md),
# never scanned for words like "rejected"/"protected".
sub _classify_push {
    my ($exit, $stderr) = @_;
    my @warnings = grep { length $_ } split /\r?\n/, ($stderr // '');
    return ($exit == 0) ? ('pushed', \@warnings) : ('rejected', \@warnings);
}

# MAJOR (redteam MAJOR-6): one redaction applied everywhere `git push`
# stderr is captured -- a credential-bearing transport/auth-failure URL
# (`https://user:TOKEN@host/...`) must never survive verbatim into the
# state file, notes or stdout. Mirrors the spec's own rule for decision
# `detail` one section earlier (S5): only the shape survives, not the
# secret.
sub _redact_credentials {
    my ($s) = @_;
    return $s unless defined $s;
    $s =~ s{(://)[^/@\s]+@}{$1<redacted>@}g;
    return $s;
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
    if ($ref eq 'HASH')  { return { map { $_ => _widen_utf8($s->{$_}) } keys %$s }; }
    if ($ref eq 'ARRAY') { return [ map { _widen_utf8($_) } @$s ]; }
    return $s if $ref;   # JSON::PP::Boolean or any other blessed ref
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
