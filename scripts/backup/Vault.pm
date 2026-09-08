# Vault.pm -- backup driver phase 04-vault-and-todos (blueprint
# backup-driver).
#
# Absorbs today's SKILL.md Steps 5.4 (sync todos) and 5.5 (sync each
# registered vault project, sub-steps 5.5.a/b/c). See the spec for the full
# contract:
#   .ccpraxis-local-data/blueprints/backup-driver/specs/04-vault-and-todos-spec.md
# including its BINDING coordinator rulings (S0.1, S0.2, S2.9), which
# supersede anything earlier in that document that conflicts.
#
# THIS MODULE WRAPS EXISTING SCRIPTS. It never runs git against the vault,
# never copies a file into the vault, never computes a hash, and never
# re-implements a merge. `todo-sync.pl` and `vault-sync.pl` keep owning
# every git operation, every hash, every merge, every file move. This module
# only sequences their invocations, interprets exit codes, turns a genuine
# conflict into a decision record, and checkpoints per-project progress.
#
# S0.1 (coordinator ruling P14) -- the d667 premise, corrected: bug report
# .ccpraxis-local-data/bug-reports/20260901-025445-d667.md documents a real
# incident where a fresh registration's ops journal decoded a path through
# `Andr\xE9` with a bare `JSON::PP->new->decode` (utf8-FLAGGED, not
# transcoded), so every push rolled back while `commit-and-push` reported
# success, and the next sync then staged `delete_local` for every file.
# `rolled_back_nothing_stored` is therefore a FAILURE for that project,
# never folded into success -- not because the cause is unknown, but because
# it is the documented signature of a utf8-flag-vs-bytes handoff defect that
# has now shipped three times in this initiative (package 02's whole-file
# corruption, package 03's nested double-encoding, d667's journal), every
# time under a green suite. `sensitive_blocked` and
# `sensitive_blocked_post_rename` are reported under their OWN status
# strings -- they are blocks, not rollbacks: nothing was stored and the
# vault was never touched (or was restored from HEAD), and conflating them
# with a rollback would tell the operator to do the wrong thing.
#
# Decision 5's motivating incident: a vault sync killed at 90 minutes lost
# all of its progress. This module checkpoints per PROJECT (not per whole
# phase), and declares `crash_preserves_items` on its phase_spec (package 01
# p16 contract amendment) so a mid-execution death does not erase completed
# projects' checkpoints. The safety condition that flag imposes: a
# consequential success (`committed_and_pushed`) is never trusted from the
# child's own report alone -- S2.7's `list-projects` re-check (this
# module's analogue of Export.pm's `ls-remote`) confirms it against the
# vault's own record before recording success, because on Windows a signal
# death behind a wrapper is invisible to `$?`.
#
# S2.9 (BINDING ruling V1) -- what R6 actually clears: `Run.pm` wipes BOTH
# a phase's answers AND its items/scratch on a "running" (mid-execution
# kill) re-entry, unless the phase opts into `crash_preserves_items` (which
# only rescues items/scratch -- answers are ALWAYS cleared, unconditionally,
# so a stale "yes" is never silently replayed). Consequence for this module:
# after a hard kill, a project whose `session.<tok>` survived is trusted
# (no `sync-project` respawn, no fresh session minted) but any of its
# conflicts that were pending an answer are RE-ASKED under the SAME
# decision id (a pure function of tok+path), because the answer that was
# given is gone. This is the CRASH1/CRASH2 behaviour the oracle exercises.
#
# MINOR 12 (red-team step 6) -- the honest limit of that trust: a preserved
# `session.<tok>` has no freshness bound. A resume days later replays a
# `session_id` whose journal may since have been cleared server-side
# (`vault-sync.pl`'s H2 defence then reads as a false `commit_failed`), and
# a crash landing between a genuinely successful `commit-and-push` and this
# module's own terminal checkpoint re-runs `commit-and-push` with an
# already-consumed session id -- reporting a pushed project as failed.
# Neither is destructive (no data loss, no silently-replayed consent), but
# it is worth stating plainly because it narrows the safety argument S2.9's
# spec text makes ("absence of session.<tok> is how a half-resolved project
# is detected") -- here the session SURVIVES and IS reused, unbounded.
#
# This module must never depend on package 01's engine module or its
# siblings Preflight.pm/Export.pm/Closeout.pm (spec S1.1): everything it
# needs arrives through $ctx, so `perl -c` is clean standalone and a test
# can copy this single file into a scratch BACKUP_PHASE_DIR. The helpers
# below (_run_capture, _sanitize_utf8, _widen_utf8, _ensure_utf8_bytes,
# _clamp, _clamp_text, _mint_ids, _title_key, _read_file_raw) are
# duplicated from Export.pm DELIBERATELY -- Decision 9 makes the write sets
# disjoint, and a shared helper module is nobody's to create.
#
# The four earlier blockers, and how this module avoids each (spec S2.10):
#   1. Latin-1 JSON corruption -- this module writes no JSON file at all;
#      the only writer of the run-state file is Run.pm. Everything handed
#      to $ctx goes through _sanitize_utf8 first (raw UTF-8 bytes), because
#      backup.pl's stdout encoder (JSON::PP->new->canonical->encode) has no
#      ->utf8 and cannot carry anything else without corrupting it.
#   2. Absent vs unreadable vs unparseable collapsed into one undef --
#      _interpret_response/_interpret_todo_sync keep "did not spawn",
#      "spawned, non-zero exit" and "spawned, exit 0, unparseable" as three
#      distinct outcomes (S1.7); none of the three is ever read as "empty".
#   3. `$? >> 8` reporting a signal-killed child as exit 0 -- _run_capture
#      copies Export.pm's reap form verbatim: `(st & 127) ? 128+(st&127) :
#      st>>8`. AC21 proves a signal-killed vault-sync.pl is not exit 0.
#   4. `die` on an environmental condition -- no environmental path here
#      dies; a missing HOME/root/vault, an unspawnable child or an
#      unparseable response each returns/records a `failed` unit or a
#      degraded project, never an exception. `die` would only ever fire on
#      an invalid decision record we constructed ourselves (a programming
#      error), via $ctx->{decision}'s own validation.
#
# The fifth, specific to this package -- non-ASCII must survive in
# FILENAMES, not just content (P15, ruling in spec S0.2): every string this
# module hands to $ctx (checkpoint/note/decision) is passed through
# _sanitize_utf8 (narrow, raw UTF-8 bytes); every string pulled back OUT of
# $ctx (get_item, answers) and about to become a child's ARGV is passed
# through _widen_utf8 first. Skipping the widen step on the way back out is
# exactly d667's Defect B, one process boundary over: Run.pm's own read
# (JSON::PP->new->decode, no ->utf8) sets the utf8 flag on every decoded
# string WITHOUT transcoding, so a non-ASCII path or slug would reach a
# child's argv double-encoded and simply not exist on disk.

package Backup::Phase::Vault;
use strict;
use warnings;
use JSON::PP;
use File::Temp ();
use Encode ();

# ===========================================================================
# phase_spec / run_phase -- the contract package 01 (Run.pm) requires.
# ===========================================================================

sub phase_spec {
    return {
        name      => 'vault',
        order     => 300,   # spec S1.1 / P2: preflight=100, export=200, vault=300, closeout=400
        resumable => 1,
        # p16 contract amendment (Run.pm): a per-project checkpoint here is
        # a durable record of expensive, externally-verifiable work (a full
        # vault sync), not a cheap freely-repeatable claim -- Decision 5's
        # whole point. See this file's header for the safety condition this
        # imposes (S2.7's confirmation-against-reality).
        crash_preserves_items => 1,
        title     => 'Vault: todos, then each registered project sequentially',
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
    # backup.pl's own stdout JSON encoder has no ->utf8 (spec S1.4); every
    # string reaching $ctx must already be valid UTF-8 bytes.
    $home_n = _ensure_utf8_bytes($home_n);
    my $root = "$home_n/.claude/ccpraxis";
    unless (-d $root) {
        return { status => 'failed', error => "ccpraxis install not found at $root" };
    }
    my $vault = "$home_n/.claude/claude-code-vault";

    my $failure_key = 'unit_failures';
    my $load_failures = sub {
        my $h = $ctx->{get_item}->($failure_key);
        return (ref($h) eq 'HASH') ? { %$h } : {};
    };
    my $record_failure = sub {
        my ($unit, $msg) = @_;
        return unless defined $msg;
        my $durable = $load_failures->();
        $durable->{$unit} = $msg;
        $ctx->{checkpoint}->($failure_key, $durable);
    };
    my $record_success = sub {
        my ($unit) = @_;
        my $durable = $load_failures->();
        return unless exists $durable->{$unit};
        delete $durable->{$unit};
        $ctx->{checkpoint}->($failure_key, $durable);
    };

    # ---- U1: vault_check (S2.1) ----
    unless ($ctx->{is_done}->('vault_check')) {
        if (-d "$vault/.git") {
            $ctx->{checkpoint}->('vault_check', { present => 1, path => $vault });
        }
        else {
            $ctx->{note}->('vault_missing', { path => $vault });
            $ctx->{checkpoint}->('vault_check', { present => 0, path => $vault });
            return { status => 'complete' };
        }
    }
    else {
        my $vc = $ctx->{get_item}->('vault_check');
        return { status => 'complete' } if ref($vc) eq 'HASH' && !$vc->{present};
    }

    # ---- U2: todos (SKILL.md Step 5.4) -- always checkpoints exactly once,
    #      on every path including failure (S2.2's ordering barrier). ----
    unless ($ctx->{is_done}->('todos')) {
        my $r = _run_capture($^X, "$root/scripts/todo-sync.pl", 'sync', 'backup: sync todos');
        my ($kv, $errmsg) = _interpret_todo_sync($r);
        $kv = _sanitize_utf8($kv);
        if (defined $errmsg) {
            $ctx->{note}->('todos_failed', { status => $kv->{STATUS}, error => $errmsg });
            $record_failure->('todos', $errmsg);
        }
        else {
            $ctx->{note}->('todos', { status => $kv->{STATUS}, pulled => $kv->{PULLED},
                                       committed => $kv->{COMMITTED}, pushed => $kv->{PUSHED} });
        }
        $ctx->{checkpoint}->('todos', { status => $kv->{STATUS}, pulled => $kv->{PULLED},
                                         committed => $kv->{COMMITTED}, pushed => $kv->{PUSHED},
                                         error => $errmsg });
    }

    # ---- U3: project_list (S2.3) -- gated on todos (Decision 7 barrier,
    #      enforced in code: no sync-project may spawn before todo-sync.pl
    #      has run to completion, because SKILL.md's reason is that the
    #      todo sync must leave the vault working tree clean first). ----
    if ($ctx->{is_done}->('todos')) {
        unless ($ctx->{is_done}->('project_list')) {
            my $r = _run_capture($^X, "$root/plugins/steward/scripts/vault-sync.pl", 'list-projects');
            my ($ok, $j, $err) = _interpret_response($r, 'vault-sync.pl list-projects');
            if ($ok && !(ref($j) eq 'HASH' && ref($j->{projects}) eq 'ARRAY')) {
                $ok  = 0;
                $err = 'vault-sync.pl list-projects produced unexpected shape (no projects array): '
                     . _clamp(($r->{out} // ''), 200);
            }
            if ($ok) {
                $j = _sanitize_utf8($j);
                # MAJOR 4 (red-team step 6): the shape check above only
                # verifies `projects` is an ARRAY; its elements are then
                # dereferenced as hashes below. A junk element (string,
                # number, arrayref) used to be a strict-refs `die` that
                # propagated out of run_phase as phase_died (exit 1, no
                # closeout) -- a whole-run abort for one malformed registry
                # entry. Filter and degrade to "one entry dropped", never a
                # crash -- _confirm_push already applies the same guard to
                # the sibling `projects` array it reads.
                my @all_projects = @{ $j->{projects} };
                my @projects = grep { ref($_) eq 'HASH' } @all_projects;
                my $dropped = scalar(@all_projects) - scalar(@projects);
                $ctx->{note}->('project_list_malformed_entries', { count => $dropped }) if $dropped;
                if (!@projects) {
                    $ctx->{note}->('projects_listed', { count => 0 });
                    $ctx->{checkpoint}->('project_list', []);
                }
                else {
                    # S2.3: tok is the slug sanitised the SAME way _mint_ids
                    # sanitises everywhere else, minted ONCE up front so a
                    # non-ASCII/punctuation slug can never produce a
                    # malformed decision id or a non-ASCII checkpoint key.
                    my @pairs = _mint_ids('', map { $_->{slug} // '' } @projects);
                    my @frozen;
                    for my $i (0 .. $#projects) {
                        my $p = $projects[$i];
                        push @frozen, {
                            slug               => $p->{slug},
                            path               => $p->{path},
                            project_exists     => ($p->{project_exists} ? 1 : 0),
                            tok                => $pairs[$i][1],
                            # MAJOR 3 (red-team step 6): frozen BEFORE any
                            # commit-and-push for this project runs, so
                            # S2.7's confirmation has an independent
                            # baseline to advance against -- see the
                            # strict-advance check in _process_project.
                            last_synced_before => $p->{last_synced_at},
                        };
                    }
                    $ctx->{note}->('projects_listed', { count => scalar(@frozen) });
                    $ctx->{checkpoint}->('project_list', \@frozen);
                }
                $record_success->('project_list');
            }
            else {
                # S2.3: no checkpoint on failure. NIT 14 correction: within
                # THIS run there is no retry -- Run.pm advances past a
                # phase that returns 'failed' -- the "no checkpoint" choice
                # only means a re-entry via the pause path (not a plain
                # retry) would re-attempt this call. Zero sync-project
                # spawns this pass either way.
                $record_failure->('project_list', $err);
            }
        }
    }

    # ---- U4.k: one project at a time, in frozen order (S2.4). Strictly
    #      sequential (Decision 7/S2.6): one foreach over the frozen list by
    #      ascending index; every child is a blocking open/close; nothing
    #      here forks a worker, spawns a background job, or runs two
    #      children's calls concurrently -- so index k+1 is never touched
    #      until index k has a terminal project.<tok>. ----
    if ($ctx->{is_done}->('project_list')) {
        my $list = $ctx->{get_item}->('project_list');
        $list = [] unless ref($list) eq 'ARRAY';
        for my $entry (@$list) {
            my $tok = $entry->{tok};
            next if $ctx->{is_done}->("project.$tok");
            my $res = _process_project($ctx, $root, $entry, $record_failure);
            if (ref($res) eq 'HASH' && ref($res->{decisions}) eq 'ARRAY') {
                return { status => 'needs_decision', decisions => $res->{decisions} };
            }
            # otherwise the project reached a terminal state (checkpointed
            # by _process_project) -- fall through to the next entry.
        }
    }

    # ---- S2.8: terminal status of the phase ----
    my $durable = $load_failures->();
    if (%$durable) {
        my @names = sort keys %$durable;
        my $first = $durable->{$names[0]};
        return { status => 'failed', error => 'vault: ' . join(', ', @names) . " -- $first" };
    }
    return { status => 'complete' };
}

# ===========================================================================
# _process_project -- one project's 5.5.a/b/c. Returns {} to continue the
# loop (a terminal checkpoint was written), or { decisions => [...] } to
# pause the whole phase.
# ===========================================================================
sub _process_project {
    my ($ctx, $root, $entry, $record_failure) = @_;

    my $tok  = $entry->{tok};
    my $slug = $entry->{slug};
    my $path = $entry->{path};

    # (a) stale entry / an entry whose path is empty-or-undef (S5 edge
    # case): neither is spawnable, and neither is a failure -- SKILL.md
    # itself only surfaces it and skips.
    my $exists = $entry->{project_exists} ? 1 : 0;
    unless ($exists && defined($path) && length($path)) {
        $ctx->{note}->('stale_project_entry', {
            slug => $slug, path => $path,
            hint => "project '" . (defined $slug ? $slug : '') . "' no longer resolves to a real path"
                  . " -- run 'vault-sync.pl unregister --slug " . (defined $slug ? $slug : '') . "' to remove it",
        });
        $ctx->{checkpoint}->("project.$tok", { slug => $slug, status => 'stale_entry' });
        return {};
    }

    # S5 edge case: a slug carrying a newline/NUL/leading '-' is rejected
    # before any spawn -- nothing is ever passed to a child.
    unless (defined $slug && length $slug && $slug !~ /[\r\n\x00]/ && $slug !~ /^-/) {
        my $msg = 'project entry has an invalid or unusable slug';
        $ctx->{note}->('project_error', { slug => ($slug // ''), error => $msg });
        $ctx->{checkpoint}->("project.$tok", { slug => ($slug // ''), status => 'error', error => $msg });
        $record_failure->("project.$tok", $msg);
        return {};
    }

    my $session = $ctx->{get_item}->("session.$tok");

    unless (ref($session) eq 'HASH') {
        my $slug_arg = _widen_utf8($slug);

        # (b) refresh default-tracked -- informational and idempotent; a
        # failure here must not cost the project its backup (S2.4(b)).
        my $rr = _run_capture($^X, "$root/plugins/steward/scripts/vault-sync.pl",
            'refresh-default-tracked', '--slug', $slug_arg);
        my ($rok, $rj, $rerr) = _interpret_response($rr, 'vault-sync.pl refresh-default-tracked');
        if ($rok) {
            $rj = _sanitize_utf8($rj);
            $ctx->{note}->('refresh_default_tracked', { slug => $slug, added => ($rj->{added} // []) });
        }
        else {
            $ctx->{note}->('refresh_failed', { slug => $slug, error => $rerr });
        }

        # (c) sync-project
        my $sr = _run_capture($^X, "$root/plugins/steward/scripts/vault-sync.pl",
            'sync-project', '--slug', $slug_arg);
        my ($sok, $sj, $serr) = _interpret_response($sr, 'vault-sync.pl sync-project');
        unless ($sok) {
            $ctx->{note}->('project_error', { slug => $slug, error => $serr });
            $ctx->{checkpoint}->("project.$tok", { slug => $slug, status => 'error', error => $serr });
            $record_failure->("project.$tok", $serr);
            return {};
        }
        $sj = _sanitize_utf8($sj);
        my $status = $sj->{status} // '';

        if ($status eq 'drift') {
            my $dirty = (ref($sj->{dirty_files}) eq 'ARRAY') ? $sj->{dirty_files} : [];
            my @clamped = _clamp_list($dirty);
            $ctx->{note}->('project_drift', { slug => $slug, dirty_files => \@clamped, count => scalar(@$dirty) });
            $ctx->{checkpoint}->("project.$tok", { slug => $slug, status => 'drift', dirty_files => scalar(@$dirty) });
            $record_failure->("project.$tok", "project '$slug' has local drift (" . scalar(@$dirty) . ' file(s))');
            return {};
        }
        if ($status ne 'synced') {
            my $msg = "sync-project reported unrecognized status '" . $status . "'"
                    . (defined $sj->{error} ? ": $sj->{error}" : '');
            $ctx->{note}->('project_error', { slug => $slug, error => $msg });
            $ctx->{checkpoint}->("project.$tok", { slug => $slug, status => 'error', error => $msg });
            $record_failure->("project.$tok", $msg);
            return {};
        }

        # status: synced -- S2.4(c): session_id is captured HERE and only
        # here; a missing/malformed value forfeits both resolve-conflict
        # and commit-and-push entirely (H2 defence / a leading '-' would
        # otherwise be parsed as an option).
        my $session_id = $sj->{session_id};
        unless (defined $session_id && length $session_id
                && $session_id !~ /[\r\n\x00]/ && $session_id !~ /^-/) {
            $ctx->{checkpoint}->("project.$tok", { slug => $slug, status => 'session_missing' });
            $ctx->{note}->('project_error', { slug => $slug, error => 'sync-project returned no usable session_id' });
            $record_failure->("project.$tok", "project '$slug': sync-project returned no usable session_id");
            return {};
        }

        my $deletes = (ref($sj->{deletes_local}) eq 'ARRAY') ? $sj->{deletes_local} : [];
        if (@$deletes) {
            my @cl = _clamp_list($deletes);
            $ctx->{note}->('deletes_local_staged', { slug => $slug, count => scalar(@$deletes), paths => \@cl });
        }
        my @symlinks  = (ref($sj->{skipped_symlinks})  eq 'ARRAY') ? @{ $sj->{skipped_symlinks} }  : ();
        my @bad_paths = (ref($sj->{skipped_bad_paths}) eq 'ARRAY') ? @{ $sj->{skipped_bad_paths} } : ();
        if (@symlinks || @bad_paths) {
            # MINOR 7: clamp like deletes_local above -- these are
            # per-path lists that can grow with the project's tree size.
            my @cl_sym = _clamp_list(\@symlinks);
            my @cl_bad = _clamp_list(\@bad_paths);
            $ctx->{note}->('sync_skipped_paths', {
                slug => $slug, symlinks => \@cl_sym, bad_paths => \@cl_bad,
                symlinks_count => scalar(@symlinks), bad_paths_count => scalar(@bad_paths),
            });
        }
        $ctx->{note}->('sync_counts', {
            slug => $slug, applied => ($sj->{applied} // 0),
            action_counts => ($sj->{action_counts} // {}), cache_repaired => ($sj->{cache_repaired} // []),
        });

        # MAJOR 4 (same defect class one level down): filter, never
        # dereference blindly -- _confirm_push already guards this exact
        # array shape ("next unless ref($p) eq 'HASH'").
        my @conflicts_raw = (ref($sj->{conflicts}) eq 'ARRAY')
            ? grep { ref($_) eq 'HASH' } @{ $sj->{conflicts} } : ();
        $session = { slug => $slug, session_id => $session_id,
                     conflicts => \@conflicts_raw, resolved => [], stage => 'awaiting_resolution' };
        # session.<tok> is documented as "(in progress)" (S2.3's table) --
        # it exists to survive a pause/crash while conflicts are still
        # unresolved. A project with ZERO conflicts proceeds straight to
        # commit-and-push in this same call and never needs a durable
        # session record: if a crash lands between here and that call, the
        # absence of session.<tok> correctly causes a fresh, idempotent
        # sync-project on restart (S2.9), and $ctx exposes no way to ever
        # remove a checkpoint once written -- so checkpointing one that
        # will never again be read would just be permanent clutter left
        # behind after this project turns terminal.
        $ctx->{checkpoint}->("session.$tok", $session) if @conflicts_raw;
    }
    # else: a session already exists -- from THIS invocation's pause/resume
    # or preserved across a crash (S2.9). Never re-derive it: no
    # refresh-default-tracked, no sync-project respawn. The preserved
    # inventory is trusted; only ANSWERS were ever cleared.

    my @conflicts = (ref($session->{conflicts}) eq 'ARRAY')
        ? grep { ref($_) eq 'HASH' } @{ $session->{conflicts} } : ();
    my %resolved_set = map { $_ => 1 } @{ (ref($session->{resolved}) eq 'ARRAY' ? $session->{resolved} : []) };
    my @unresolved = grep { !$resolved_set{ $_->{path} // '' } } @conflicts;

    if (@unresolved) {
        # S2.5 / MINOR 9 (reviewer M2, red-team's own MINOR 9): ids are a
        # pure function of (tok, path) over the FULL frozen conflict list,
        # never of whichever subset remains unresolved at THIS moment.
        # Minting over @unresolved let a sanitisation collision's suffix
        # (".2") shift onto a different conflict once a crash shrank the
        # list mid-resolution -- a re-ask no longer presented the SAME id
        # S2.5 requires. @conflicts never shrinks across resolve-conflict
        # calls (only @unresolved does), so minting over it every time is
        # stable, and raw (unsanitised) paths are the lookup key -- they
        # cannot collide with each other even when their SANITISED forms
        # do.
        my @pairs_full = _mint_ids("vault.conflict.$tok", map { $_->{path} // '' } @conflicts);
        my %id_by_path;
        for my $i (0 .. $#conflicts) {
            my $p = $conflicts[$i]->{path} // '';
            $id_by_path{$p} = $pairs_full[$i][1] unless exists $id_by_path{$p};
        }
        my @still_pending;

        for my $c (@unresolved) {
            my $id = $id_by_path{ $c->{path} // '' };
            my $answer = $ctx->{answers}{$id};
            unless (defined $answer) {
                push @still_pending, [ $c, $id ];
                next;
            }

            if ($answer eq 'abort_project') {
                my $discarded = scalar(@{ (ref($session->{resolved}) eq 'ARRAY' ? $session->{resolved} : []) });
                $ctx->{note}->('project_aborted', { slug => $slug, discarded => $discarded });
                $ctx->{checkpoint}->("project.$tok", { slug => $slug, status => 'aborted', discarded => $discarded });
                return {};
            }

            my $action = $answer eq 'use_local'  ? 'use-local'
                       : $answer eq 'use_vault'   ? 'use-vault'
                       : $answer eq 'use_merged'  ? 'use-merged'
                       : undef;
            unless (defined $action) {
                # Run.pm's own answer validation already rejects any choice
                # not among this decision's own choices, so this is
                # unreachable in practice; treat defensively as unanswered.
                push @still_pending, [ $c, $id ];
                next;
            }

            my @args = ('resolve-conflict', '--slug', _widen_utf8($slug), '--path', _widen_utf8($c->{path}),
                        '--action', $action, '--session-id', _widen_utf8($session->{session_id}));
            if ($action eq 'use-merged') {
                my $mtp = (ref($c->{merge_result}) eq 'HASH') ? $c->{merge_result}{tmp_path} : undef;
                push @args, ('--merged-file', _widen_utf8($mtp));
            }
            my $rc = _run_capture($^X, "$root/plugins/steward/scripts/vault-sync.pl", @args);
            my ($rcok, $rcj, $rcerr) = _interpret_response($rc, 'vault-sync.pl resolve-conflict');
            unless ($rcok) {
                $ctx->{checkpoint}->("project.$tok", { slug => $slug, status => 'resolve_failed',
                                                          path => $c->{path}, error => $rcerr });
                $ctx->{note}->('project_error', { slug => $slug,
                    error => "resolve-conflict for '" . ($c->{path} // '') . "': $rcerr" });
                $record_failure->("project.$tok", $rcerr);
                return {};
            }
            push @{ $session->{resolved} }, $c->{path};
            $ctx->{checkpoint}->("session.$tok", $session);
        }

        if (@still_pending) {
            my @decisions;
            for my $pair (@still_pending) {
                my ($c, $id) = @$pair;
                push @decisions, _conflict_decision($ctx, $slug, $c, $id);
            }
            return { decisions => \@decisions };
        }

        # All conflicts now resolved (S2.4(d) leaves this unreachable via
        # 'unanswered_conflict' under this module's own design: an
        # unanswered conflict is always re-asked, per S2.9's binding ruling
        # that consent is never silently replayed after a mid-execution
        # kill -- there is no code path here that fabricates consent).
    }

    # (e) commit-and-push (S2.4(e))
    my $cp = _run_capture($^X, "$root/plugins/steward/scripts/vault-sync.pl",
        'commit-and-push', '--slug', _widen_utf8($slug), '--session-id', _widen_utf8($session->{session_id}));
    my ($cok, $cj, $cerr) = _interpret_response($cp, 'vault-sync.pl commit-and-push');
    unless ($cok) {
        $ctx->{checkpoint}->("project.$tok", { slug => $slug, status => 'commit_failed', error => $cerr });
        $ctx->{note}->('project_error', { slug => $slug, error => $cerr });
        $record_failure->("project.$tok", $cerr);
        return {};
    }
    $cj = _sanitize_utf8($cj);
    my $cstatus = $cj->{status} // '';

    if ($cstatus eq 'committed_and_pushed') {
        my $reported = $cj->{last_synced_at};
        # MAJOR 3 (red-team step 6): comparing $observed (the confirmation
        # re-read) against $reported (what the SAME commit-and-push child
        # just claimed) is tautological -- both numbers come from the one
        # local metadata.json file the child just wrote, so a lying or
        # no-op child satisfies "$observed ge $reported" by construction.
        # Compare instead against $entry->{last_synced_before}, frozen at
        # U3 BEFORE this project's commit-and-push ever ran -- an
        # independent pre-push baseline -- and require a STRICT advance
        # (gt, not ge) so a no-op push is never mistaken for a real one.
        my $before = $entry->{last_synced_before};
        my ($confirmed, $observed) = _confirm_push($root, $slug);
        if ($confirmed && defined($observed) && (!defined($before) || $observed gt $before)) {
            $ctx->{checkpoint}->("project.$tok", { slug => $slug, status => 'committed_and_pushed',
                                                      last_synced_at => $observed });
            $ctx->{note}->('project_committed', {
                slug => $slug, last_synced_at => $observed,
                conflicts => scalar(@conflicts),
                resolved  => scalar(@{ (ref($session->{resolved}) eq 'ARRAY' ? $session->{resolved} : []) }),
            });
            if (ref($cj->{rolled_back_during_sync}) eq 'ARRAY' && @{ $cj->{rolled_back_during_sync} }) {
                my @clamped_rb = _clamp_list($cj->{rolled_back_during_sync});
                $ctx->{note}->('rolled_back_during_sync', {
                    slug => $slug, paths => \@clamped_rb, count => scalar(@{ $cj->{rolled_back_during_sync} }) });
            }
            return {};
        }
        # S2.7: an unconfirmed "success" is never recorded as one -- an
        # exit code cannot be trusted here (Windows signal death behind a
        # wrapper is invisible to $?).
        $ctx->{checkpoint}->("project.$tok", { slug => $slug, status => 'push_unconfirmed',
                                                  reported => $reported, observed => $observed, before => $before });
        $ctx->{note}->('push_unconfirmed', { slug => $slug, reported => $reported, observed => $observed, before => $before });
        $record_failure->("project.$tok",
            "commit-and-push reported success for '$slug' but the vault's own record does not confirm it");
        return {};
    }

    if ($cstatus eq 'rolled_back_nothing_stored') {
        # S0.1: NEVER folded into success -- the documented signature of
        # d667's defect class. vault-sync.pl's own rollback_reasons is a
        # small reason->count HASH (`%why` at vault-sync.pl:1448), not a
        # per-path list, so unlike rolled_back_during_sync/findings there
        # is no unbounded-growth risk here to clamp against.
        $ctx->{checkpoint}->("project.$tok", { slug => $slug, status => 'rolled_back_nothing_stored',
                                                  rollback_reasons => $cj->{rollback_reasons} });
        $ctx->{note}->('rolled_back_nothing_stored', { slug => $slug, rollback_reasons => $cj->{rollback_reasons} });
        $record_failure->("project.$tok", "commit-and-push rolled back everything for '$slug' -- nothing was stored");
        return {};
    }

    if ($cstatus eq 'sensitive_blocked' || $cstatus eq 'sensitive_blocked_post_rename') {
        # Distinct status string from rolled_back_nothing_stored -- a
        # sensitive block is not a rollback (S0.1). findings are surfaced
        # as file/line/pattern only; the matched text itself is never
        # copied here (vault-sync.pl's own responsibility not to emit it).
        # MINOR 7: clamp, same reasoning as rollback_reasons above.
        my $findings = (ref($cj->{findings}) eq 'ARRAY') ? $cj->{findings} : [];
        my @clamped_findings = _clamp_list($findings);
        $ctx->{checkpoint}->("project.$tok", { slug => $slug, status => $cstatus, findings => \@clamped_findings, findings_count => scalar(@$findings) });
        $ctx->{note}->($cstatus, { slug => $slug, findings => \@clamped_findings, count => scalar(@$findings) });
        $record_failure->("project.$tok", "commit-and-push blocked by the sensitive-data scan for '$slug' ($cstatus)");
        return {};
    }

    my $msg = "commit-and-push reported status '$cstatus'" . (defined $cj->{error} ? ": $cj->{error}" : '');
    $ctx->{checkpoint}->("project.$tok", { slug => $slug, status => 'commit_failed', error => $msg });
    $ctx->{note}->('project_error', { slug => $slug, error => $msg });
    $record_failure->("project.$tok", $msg);
    return {};
}

# ===========================================================================
# _confirm_push -- S2.7's read-only re-check. Returns ($confirmed_call_ok,
# $observed_last_synced_at | undef).
# ===========================================================================
sub _confirm_push {
    my ($root, $slug) = @_;
    my $r = _run_capture($^X, "$root/plugins/steward/scripts/vault-sync.pl", 'list-projects');
    my ($ok, $j, $err) = _interpret_response($r, 'vault-sync.pl list-projects (push confirmation)');
    return (0, undef) unless $ok;
    return (0, undef) unless ref($j) eq 'HASH' && ref($j->{projects}) eq 'ARRAY';
    # MAJOR 2 (red-team step 6): $slug may be a FRESH child-reported value
    # (already raw UTF-8 bytes -- _widen_utf8 is then a safe no-op) OR a
    # value resumed through $ctx->{get_item} after a pause/resume, which
    # comes back utf8-FLAGGED WITHOUT transcoding (Run.pm's decode has no
    # ->utf8). _ensure_utf8_bytes alone double-encodes that third
    # representation, so a project with a non-ASCII slug that genuinely
    # pushed successfully across a resume was compared against the wrong
    # bytes here and NEVER matched -- falsely recording push_unconfirmed,
    # the exact d667 alarm, on a run that fully succeeded. Widen first so
    # every representation lands on the same real characters before
    # re-encoding to bytes.
    my $slug_bytes = _ensure_utf8_bytes(_widen_utf8($slug));
    for my $p (@{ $j->{projects} }) {
        next unless ref($p) eq 'HASH';
        next unless defined $p->{slug};
        next unless _ensure_utf8_bytes($p->{slug}) eq $slug_bytes;
        my $v = $p->{last_synced_at};
        return (1, defined($v) ? _ensure_utf8_bytes($v) : undef);
    }
    return (1, undef);   # the call worked, but the slug is absent
}

# ===========================================================================
# _conflict_decision -- S2.5. The merge tmp is read READ-ONLY and clamped;
# absent/unreadable never suppresses the decision and never fails the
# project (S1.7's discipline applied to this one read).
# ===========================================================================
sub _conflict_decision {
    my ($ctx, $slug, $c, $id) = @_;

    my $path    = $c->{path} // '';
    my $is_text = $c->{is_text} ? 1 : 0;
    my $mr      = (ref($c->{merge_result}) eq 'HASH') ? $c->{merge_result} : undef;

    my ($merge_exit_code, $merge_tmp_path, $preview, $preview_trunc, $preview_unavail);

    if ($is_text && defined $mr) {
        $merge_exit_code = $mr->{exit_code};
        $merge_tmp_path  = $mr->{tmp_path};
        if (defined $merge_tmp_path && length $merge_tmp_path) {
            # BLOCKER fix (coordinator step-6 red-team finding 1): on a
            # crash re-ask, $merge_tmp_path arrives back through
            # $ctx->{get_item} -- Run.pm's own state read has no ->utf8, so
            # it is utf8-FLAGGED WITHOUT transcoding (d667's Defect B, one
            # process boundary over). Handing that straight to `open`
            # double-encodes the path and the open silently fails on any
            # non-ASCII path component. On the operator's real machine
            # $VAULT_DIR sits under their non-ASCII HOME (Andre-with-an-
            # acute-e), so EVERY re-asked conflict after a crash would show
            # no diff plus a false "No such file or directory" -- and a
            # blind use_vault on that false premise overwrites the
            # operator's local work. _widen_utf8 is a no-op on a path that
            # is already correct (fresh, same-invocation bytes), so this is
            # safe on both the fresh and the resumed path.
            my ($text, $rerr) = _read_file_raw(_widen_utf8($merge_tmp_path));
            if (defined $rerr) { $preview_unavail = "merge preview unreadable: $rerr"; }
            else {
                # reviewer M1: this is the ONE value handed to $ctx that did
                # not go through _ensure_utf8_bytes -- unlike every other
                # field, it is on-disk file content (a Latin-1/CP1252 source
                # file is entirely plausible), and backup.pl's stdout
                # encoder has no ->utf8 (S1.8). Sanitise BEFORE clamping so
                # the boundary trim below operates on valid UTF-8.
                $text = _ensure_utf8_bytes($text);
                ($preview, $preview_trunc) = _clamp_text($text);
            }
        }
        else {
            $preview_unavail = 'no merge preview path was reported';
        }
    }
    elsif (!$is_text) {
        $preview_unavail = 'binary file -- diff and merged views are unavailable';
    }
    else {
        $preview_unavail = 'no merge result was reported for this conflict';
    }

    my @choices = (
        { id => 'use_local', label => 'Use the local version' },
        { id => 'use_vault', label => 'Use the vault version' },
    );
    if ($is_text && defined($merge_exit_code) && $merge_exit_code == 0) {
        push @choices, { id => 'use_merged', label => 'Use the merged result (clean auto-merge)' };
    }
    push @choices, { id => 'abort_project', label => 'Abort this project (already-resolved conflicts are discarded)' };

    my $detail = defined($preview) ? $preview : $preview_unavail;

    return $ctx->{decision}->(
        kind    => 'vault_conflict',
        id      => $id,
        title   => "conflict on '" . _title_key($path) . "' in project '" . _title_key($slug) . "'",
        subject => "$slug/$path",
        detail  => $detail,
        data    => {
            slug => $slug, path => $path,
            is_text => ($is_text ? JSON::PP::true : JSON::PP::false),
            merge_exit_code => $merge_exit_code,
            merge_tmp_path  => $merge_tmp_path,
            merge_preview   => $preview,
            merge_preview_truncated   => ($preview_trunc ? JSON::PP::true : JSON::PP::false),
            merge_preview_unavailable => $preview_unavail,
            local => $c->{local}, vault => $c->{vault}, base => $c->{base},
        },
        choices => \@choices,
    );
}

# ===========================================================================
# _interpret_response -- S1.7's three cases for a vault-sync.pl JSON child:
# did-not-spawn / spawned-nonzero-exit / spawned-exit0-unparseable. None may
# ever be read as an empty or benign result.
# ===========================================================================
# MINOR 11 (red-team step 6 / reviewer N1): $r->{err} (the child's captured
# stderr) is collected at real cost by _run_capture and used to be read
# NOWHERE. When a child dies uncontrolled (a Perl exception, not a
# deliberate emit_error) the diagnostic lands on stderr, and stdout is
# typically empty -- so the old messages degraded to an unhelpful empty
# snippet. Fall back to stderr only when stdout has nothing useful to say.
sub _stdout_or_stderr_snippet {
    my ($r) = @_;
    my $out_snip = _clamp(($r->{out} // ''), 200);
    return $out_snip if length $out_snip;
    my $err_snip = _clamp(($r->{err} // ''), 200);
    return length($err_snip) ? "(stdout empty) stderr: $err_snip" : $out_snip;
}

sub _interpret_response {
    my ($r, $label) = @_;
    unless ($r->{spawned}) {
        return (0, undef, "$label failed to spawn");
    }
    my $j = eval { decode_json($r->{out}) };
    if ($r->{exit} != 0) {
        if (ref($j) eq 'HASH') {
            my $body_err = $j->{error};
            my $msg = "$label exited $r->{exit}";
            $msg .= ": $body_err" if defined $body_err && length "$body_err";
            return (0, $j, $msg);
        }
        return (0, undef, "$label exited $r->{exit}: " . _stdout_or_stderr_snippet($r));
    }
    unless (ref($j) eq 'HASH') {
        return (0, undef, "$label produced unparseable output: " . _stdout_or_stderr_snippet($r));
    }
    return (1, $j, undef);
}

# _interpret_todo_sync -- todo-sync.pl emits `KEY: value` lines, not JSON
# (spec S2.2). `scripts/todo-sync.pl`'s cmd_sync is authoritative over
# SKILL.md: it emits STATUS: ok (never the SKILL.md-documented STATUS:
# synced); both are accepted as success, anything else is a failure.
sub _interpret_todo_sync {
    my ($r) = @_;
    unless ($r->{spawned}) {
        return ({}, 'todo-sync.pl failed to spawn');
    }
    my %kv;
    for my $line (split /\r?\n/, ($r->{out} // '')) {
        if ($line =~ /^([A-Z_]+): (.*)$/) { $kv{$1} = $2; }
    }
    my $status = $kv{STATUS};
    if ($r->{exit} != 0) {
        my $msg = "todo-sync.pl exited $r->{exit}";
        if (defined $kv{ERROR} && length $kv{ERROR}) { $msg .= ": $kv{ERROR}"; }
        elsif (defined $r->{err} && length $r->{err}) { $msg .= ': (stdout had no ERROR: line) stderr: ' . _clamp($r->{err}, 200); }
        return (\%kv, $msg);
    }
    unless (defined $status && ($status eq 'ok' || $status eq 'synced')) {
        my $msg = "todo-sync.pl reported status '" . (defined $status ? $status : '(none)') . "'";
        if (defined $kv{ERROR} && length $kv{ERROR}) { $msg .= ": $kv{ERROR}"; }
        elsif (defined $r->{err} && length $r->{err}) { $msg .= ': (stdout had no ERROR: line) stderr: ' . _clamp($r->{err}, 200); }
        return (\%kv, $msg);
    }
    return (\%kv, undef);
}

# ===========================================================================
# Child-spawning helper -- list form only, never a shell string, never a
# pipe; a blocking open/close (the reap happens before the next spawn --
# S2.6's ordering guarantee); real File::Temp FILE for stderr (never an
# in-memory scalar -- Git-for-Windows "Bad file descriptor").
# Duplicated from Export.pm VERBATIM (spec S1.1/S2.10 point 3): a bare
# `$? >> 8` reports a signal-killed child as exit 0, the worst defect this
# initiative has found.
# ===========================================================================
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
        my $st = $?;
        $exit = ($st & 127) ? (128 + ($st & 127)) : ($st >> 8);
    }

    open(STDERR, '>&', $saved_stderr) or warn "Vault: cannot restore STDERR: $!\n";
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

# ===========================================================================
# UTF-8 discipline helpers -- duplicated from Export.pm VERBATIM (spec
# S1.4/S1.8). See that module's header comments for the full rationale of
# each; repeated here only where this module's own logic depends on it.
# ===========================================================================

sub _ensure_utf8_bytes {
    my ($s) = @_;
    return $s unless defined $s;
    return Encode::encode('UTF-8', $s) if utf8::is_utf8($s);
    my $probe = $s;
    return $s if eval { Encode::decode('UTF-8', $probe, Encode::FB_CROAK()); 1 };
    return Encode::encode('UTF-8', Encode::decode('ISO-8859-1', $s));
}

# NIT 16: this direction ONLY -- narrowing a fresh child response (or
# anything else about to be handed to $ctx) to raw UTF-8 bytes. Applying
# this to a value already read back OUT of $ctx (utf8-flagged-with-byte-
# codepoints, per this file's header) double-encodes it -- the same defect
# class as BLOCKER 1 / MAJOR 2. Values coming back out of $ctx go through
# _widen_utf8 instead (see the header's boundary-crossing rule); never mix
# the two directions on the same value.
sub _sanitize_utf8 {
    my ($v) = @_;
    my $ref = ref($v);
    if ($ref eq 'HASH') {
        return { map { _sanitize_utf8($_) => _sanitize_utf8($v->{$_}) } keys %$v };
    }
    if ($ref eq 'ARRAY') {
        return [ map { _sanitize_utf8($_) } @$v ];
    }
    if ($ref eq '') {
        return _ensure_utf8_bytes($v);
    }
    return $v;   # JSON::PP::Boolean or any other blessed ref -- pass through
}

sub _widen_utf8 {
    my ($s) = @_;
    return $s unless defined $s;
    my $ref = ref($s);
    if ($ref eq 'HASH')  { return { map { $_ => _widen_utf8($s->{$_}) } keys %$s }; }
    if ($ref eq 'ARRAY') { return [ map { _widen_utf8($_) } @$s ]; }
    return $s if $ref;
    utf8::downgrade($s, 1);   # FAIL_OK: a genuinely-wide string is a no-op here
    my $probe = $s;
    my $widened = eval { Encode::decode('UTF-8', $probe, Encode::FB_CROAK()) };
    return defined $widened ? $widened : $s;
}

# ===========================================================================
# Small text helpers -- duplicated from Export.pm.
# ===========================================================================

# MAJOR 5 (red-team step 6): the OLD trim (`s/[\x80-\xBF]+\z//`) strips
# every trailing CONTINUATION byte unconditionally -- including the ones
# that COMPLETE a valid character just inside the cut -- and never strips a
# dangling LEAD byte that has zero/partial continuation bytes past the cut.
# Measured invalid at all four boundary shapes (lead-byte-alone,
# lead+partial-continuation, a clean complete-sequence cut, and a bare
# 4-byte lead). One invalid boundary anywhere makes backup.pl's ENTIRE
# stdout JSON undecodable (its encoder has no ->utf8, S1.8) -- losing the
# needs_decision payload AND the resume_token together, not just one field.
# Strip ONLY a genuinely incomplete trailing sequence; a complete sequence
# at the cut is left untouched.
sub _trim_utf8_tail {
    my ($t) = @_;
    $t =~ s/(?:[\xC2-\xDF]|[\xE0-\xEF][\x80-\xBF]{0,1}|[\xF0-\xF4][\x80-\xBF]{0,2})\z//;
    return $t;
}

sub _clamp {
    my ($s, $max) = @_;
    $max //= 4000;
    return $s unless defined $s && length($s) > $max;
    my $t = substr($s, 0, $max);
    return _trim_utf8_tail($t);
}

sub _clamp_text {
    my ($s) = @_;
    $s = '' unless defined $s;
    my $max = 4000;
    return ($s, 0) if length($s) <= $max;
    my $t = substr($s, 0, $max);
    $t = _trim_utf8_tail($t);
    return ($t, 1);
}

sub _clamp_list {
    my ($arr, $max) = @_;
    $max //= 200;
    return @$arr if scalar(@$arr) <= $max;
    return @{$arr}[0 .. $max - 1];
}

sub _read_file_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return (undef, "cannot open $path: $!");
    local $/;
    my $data = <$fh>;
    close $fh;
    return (defined $data ? $data : '', undef);
}

# id/tok sanitisation + collision suffixing (matches Preflight.pm/Export.pm's
# _mint_ids exactly). An empty prefix mints a bare tok (S2.3); a non-empty
# prefix mints "prefix.tok" (S2.5's decision ids).
sub _mint_ids {
    my ($prefix, @keys) = @_;
    my %used;
    my @out;
    for my $k (@keys) {
        (my $san = $k) =~ s/[^A-Za-z0-9_.:-]/_/g;
        $san = '_' unless length $san;
        my $base_id = length($prefix) ? "$prefix.$san" : $san;
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

# Display-only truncation for a title (subject/data.path/data.slug keep the
# full, unsanitised value).
sub _title_key {
    my ($k) = @_;
    my $t = $k;
    $t = '' unless defined $t;
    $t =~ s/\s+/ /g;
    # MAJOR 5: this used to have NO boundary-safety trim at all -- an 80th
    # byte landing inside a multi-byte character produced an invalid title
    # immediately followed by a valid 3-byte ellipsis, corrupting stdout
    # the same way _clamp/_clamp_text did.
    $t = _trim_utf8_tail(substr($t, 0, 80)) . "\xE2\x80\xA6" if length($t) > 80;   # raw UTF-8 bytes of an ellipsis
    return $t;
}

1;
