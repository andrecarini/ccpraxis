#!/usr/bin/env perl
# platform: any
# IMMUTABLE ORACLE for package 14-guards-remake batch 4 (blueprint
# hook-continuity-remake), TD-1..TD-12 and the applicable SH-1..SH-9 of
# specs/14-guards-remake-spec.md sec 3.6/4.3/4.9: the track-dispatch
# successor (TrackDispatch), which absorbs log-dispatch, track-worker-solo
# and untrack-worker-solo, running on the package-03 hook core.
#
# hooks/track-dispatch.sh and BpHook/Guards/TrackDispatch.pm DO
# NOT EXIST YET. Every in-process case goes through GuardHarness::run_module()
# (batch 1's harness, plugins/butler/tests/lib/GuardHarness.pm), which
# mirrors BpHook::main()'s own require-and-call contract, so a missing
# module fails open (rc 0) exactly as the real wrapper would -- legibly,
# never a crash in this file. Every [wrapper]/[shim] case spawns the real
# bash file at that path and gets a plain "No such file or directory" until
# the implementer writes it.
#
# WRITTEN BLIND TO THE IMPLEMENTATION: derived only from the spec text
# above (sec 2.5 for the 2.5 marker shape, sec 3.6 for TrackDispatch's own
# contract) and the CASES (never the source bash/perl) of the five source
# files this batch's oracle absorbs -- never from reading track-dispatch.sh,
# the old separate log-dispatch hook, bp-dispatch-log.pl or the retired
# .drive-solo/.active-worker mechanism itself.
#
# NOT RE-EXPRESSED (per spec sec 4.9 "Not:" list and sec 4.2's codes):
#   old file / assertion label                                        | code
#   ------------------------------------------------------------------ | ----
#   old dispatch-tracking-hook file, AC10 (bash -n / perl -c on the     | SRC (this file's own SH-1/SH-2
#     OLD hook and CLI as source-text checks)                         |   re-express the shape check
#                                                                       |   against the NEW successor instead)
#   old dispatch-tracking-hook file, AC11-AC27                         | OTHER (bp-dispatch-log.pl's own CLI
#                                                                       |   verbs -- resolve/outstanding/list/
#                                                                       |   finish/prune/elapsed -- are a
#                                                                       |   sibling component's contract, not
#                                                                       |   this hook's; this file only
#                                                                       |   exercises the in-process subs the
#                                                                       |   hook itself calls, per spec sec 2.2's
#                                                                       |   "require ... in-process" rule)
#   old dispatch-tracking-hook file, AC28                              | REG (hooks.json registration,
#                                                                       |   package 16's concern)
#   old dispatch-tracking-hook file, AC29                              | OTHER (coordinator-protocol/SKILL.md
#                                                                       |   documentation, not the hook)
#   old dispatch-write-path file, sibling-floor assertions             | D11 (a sibling package's own re-run
#                                                                       |   floor, not this hook's contract)
#   old dispatch-write-path file, source-text greps                   | SRC
#   the rest of the old dispatch-log-retention file (CLI-level prune/  | OTHER (BpDispatchLog:: pure subs are
#     outstanding accounting not reached through the hook)            |   exercised directly where TD-3/TD-4
#                                                                       |   need them; the CLI wrapper around
#                                                                       |   them is a sibling component)
#   the rest of the old worker-backend-dispatcher file (bp-orchestrator| OTHER (a different component's own
#     .pl / dashboard-facing assertions)                              |   contract)
#   old validation-interlock-hooks file, section F's sidecar-less      | D3 (the retired project-wide
#     ".drive-solo/"-only marker case                                 |   .active-worker/.session sidecar
#                                                                       |   format is replaced outright by the
#                                                                       |   2.5 per-dispatch marker; there is
#                                                                       |   no successor case to re-express)
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Spec ();
use JSON::PP ();
use Cwd ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

# ---------------------------------------------------------------------------
# Ambient isolation for the WHOLE file, up front, before any fixture or
# arm() call runs (binding lesson: isolate_env()/fresh_state() before ANY
# arm). Every individual test block below still relies on GuardHarness::
# run_module()'s own "local %ENV = %ENV" overlay for its env => {} options,
# so nothing leaks across blocks that way either.
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;
GuardHarness::isolate_env();

my $BUTLER_DIR = dirname(__FILE__) . '/../..';

# ===========================================================================
# SAFETY NET (TD-11) -- never touch the real .ccpraxis-local-data/.dispatch-
# log. Snapshot at start, compare at the very end (mirrors the old
# dispatch-tracking-hook.t AC30 pattern).
# ===========================================================================
(my $REAL_LOGDIR = "$BUTLER_DIR/../../.ccpraxis-local-data/.dispatch-log") =~ s{\\}{/}g;
sub real_logdir_snapshot {
    return {} unless -d $REAL_LOGDIR;
    my %seen;
    for my $f (glob("$REAL_LOGDIR/*.json")) {
        my @st = stat $f;
        $seen{$f} = ($st[9] // 0) . ':' . ($st[7] // 0);
    }
    return \%seen;
}
my $REAL_SNAPSHOT_BEFORE = real_logdir_snapshot();

# ---------------------------------------------------------------------------
# Byte I/O helpers.
# ---------------------------------------------------------------------------
sub read_bytes {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub write_bytes {
    my ($p, $bytes) = @_;
    (my $dir = $p) =~ s{[/\\][^/\\]*\z}{};
    make_path($dir) if length($dir) && !-d $dir;
    open(my $fh, '>:raw', $p) or die "cannot write $p: $!";
    print {$fh} $bytes;
    close $fh;
}
sub read_json {
    my ($p) = @_;
    my $raw = read_bytes($p);
    return undef unless defined $raw;
    return eval { JSON::PP->new->utf8->decode($raw) };
}

# ---------------------------------------------------------------------------
# Dispatch-log store helpers (spec sec 3.6).
# ---------------------------------------------------------------------------
sub logdir_of  { my ($proj) = @_; return "$proj/.ccpraxis-local-data/.dispatch-log" }
sub history_of { my ($proj) = @_; return logdir_of($proj) . '/history.jsonl' }
sub alarm_of   { my ($proj) = @_; return logdir_of($proj) . '/retention-alarm.log' }

sub json_record_files {
    my ($logdir) = @_;
    my @files = -d $logdir ? (sort grep { $_ !~ /history\.jsonl\z/ } glob("$logdir/*.json")) : ();
    return wantarray ? @files : scalar(@files);
}
sub history_lines {
    my ($proj) = @_;
    my $raw = read_bytes(history_of($proj));
    my @lines = defined $raw ? (grep { length } split /\n/, $raw) : ();
    return wantarray ? @lines : scalar(@lines);
}
sub plant_rec {
    my ($logdir, $id, %fields) = @_;
    make_path($logdir) unless -d $logdir;
    write_bytes("$logdir/$id.json", JSON::PP->new->canonical->encode({ id => $id, %fields }));
}
sub plant_rec_raw {
    my ($logdir, $id, $raw) = @_;
    make_path($logdir) unless -d $logdir;
    write_bytes("$logdir/$id.json", $raw);
}

# ---------------------------------------------------------------------------
# fresh_coord_env(%extra) -- a coordinator-shaped env: BP_LEDGER (a package
# ledger file path, not yet created -- append creates it), BP_DIR (with a
# runs/ subdirectory already present, matching every real coordinator
# invocation), BP_PROJECT_ROOT, BP_BLUEPRINT, BP_PACKAGE.
# ---------------------------------------------------------------------------
my $envN = 0;
sub fresh_coord_env {
    my (%extra) = @_;
    $envN++;
    my $t = tempdir(CLEANUP => 1);
    (my $bp_dir = "$t/bpdir") =~ s{\\}{/}g;
    make_path("$bp_dir/runs");
    (my $proj = "$t/proj") =~ s{\\}{/}g;
    make_path($proj);
    my %env = (
        BP_LEDGER       => "$bp_dir/packages/p.md",
        BP_DIR          => $bp_dir,
        BP_PROJECT_ROOT => $proj,
        BP_BLUEPRINT    => 'hook-continuity-remake',
        BP_PACKAGE      => "p14n$envN",
        %extra,
    );
    return (\%env, $bp_dir, $proj);
}

sub marker_of {
    my ($bp_dir, $pkg) = @_;
    return "$bp_dir/runs/$pkg.active-worker";
}

# ---------------------------------------------------------------------------
# write_driver_marker($data_dir, $tool_use_id, %f) -- the spec sec 2.5
# per-dispatch driver marker shape, planted directly (never through
# TrackDispatch itself) so TD-9/TD-10's Post-side removal rules can be
# tested against a known-good fixture.
# ---------------------------------------------------------------------------
sub write_driver_marker {
    my ($data_dir, $tool_use_id, %f) = @_;
    make_path("$data_dir/.drive-solo/workers");
    my $rec = {
        at            => ($f{at} // 1000),
        session_id    => $f{session_id},
        subagent_type => $f{subagent_type},
        tool_use_id   => $tool_use_id,
    };
    my $path = "$data_dir/.drive-solo/workers/$tool_use_id";
    write_bytes($path, JSON::PP->new->utf8->canonical->encode($rec) . "\n");
    return $path;
}

# ---------------------------------------------------------------------------
# spec_dispatch_key(DESC) -- independent PURE reference implementation of
# spec sec 3.6's dispatch_key algorithm, derived from the spec text alone.
# ---------------------------------------------------------------------------
sub spec_dispatch_key {
    my ($d) = @_;
    $d = defined $d ? $d : '';
    $d = lc($d);
    $d =~ s/[^a-z0-9]/-/g;
    $d =~ s/-+/-/g;
    $d =~ s/^-+//;
    $d =~ s/-+\z//;
    $d = substr($d, 0, 48);
    $d =~ s/-+\z//;
    return $d;
}

# ---------------------------------------------------------------------------
# payload(%o) -- a Task tool_input payload. %o: event (PreToolUse/
# PostToolUse, default PreToolUse), subagent_type, description, prompt,
# run_in_background, session_id, agent_id, tool_use_id, cwd, tool_response,
# no_event_name (omit hook_event_name entirely, for the absent+tool_response
# Post-detection case).
# ---------------------------------------------------------------------------
sub payload {
    my (%o) = @_;
    my $ti = {};
    $ti->{subagent_type}     = $o{subagent_type}     if exists $o{subagent_type};
    $ti->{description}       = $o{description}       if exists $o{description};
    $ti->{prompt}            = $o{prompt}             if exists $o{prompt};
    $ti->{run_in_background} = $o{run_in_background} if exists $o{run_in_background};
    my $p = { tool_name => 'Task', tool_input => $ti };
    $p->{hook_event_name} = $o{event} // 'PreToolUse' unless $o{no_event_name};
    $p->{tool_response}   = $o{tool_response} if exists $o{tool_response};
    $p->{session_id}      = $o{session_id}    if exists $o{session_id};
    $p->{agent_id}        = $o{agent_id}       if exists $o{agent_id};
    $p->{tool_use_id}     = $o{tool_use_id}    if exists $o{tool_use_id};
    $p->{cwd}             = $o{cwd}            if exists $o{cwd};
    return $p;
}
sub pre  { my (%o) = @_; return payload(%o, event => 'PreToolUse') }
sub post { my (%o) = @_; return payload(%o, event => 'PostToolUse') }

# ---------------------------------------------------------------------------
# td($payload, %opts) -- GuardHarness::run_module for Guards::TrackDispatch.
# ---------------------------------------------------------------------------
sub td {
    my ($p, %opts) = @_;
    return GuardHarness::run_module('Guards::TrackDispatch', $p,
        env => ($opts{env} // {}), args => ($opts{args} // []));
}

# ===========================================================================
# SH-1/SH-2 -- static shape.
# ===========================================================================
{
    my $wrapper = "$BUTLER_DIR/hooks/track-dispatch.sh";
    my $module  = "$BUTLER_DIR/scripts/BpHook/Guards/TrackDispatch.pm";
    ok(-f $wrapper, 'SH-1 precondition: track-dispatch.sh exists on disk')
        or diag("missing: $wrapper (package 14 has not written it yet)");
  SKIP: {
        skip 'SH-1: wrapper missing', 2 unless -f $wrapper;
        my $rc = system('bash', '-n', $wrapper);
        is($rc, 0, 'SH-1: bash -n on track-dispatch.sh passes');
        my $src = read_bytes($wrapper) // '';
        like($src, qr/Guards::TrackDispatch/, 'SH-1: the wrapper names the Guards::TrackDispatch module');
    }
    ok(-f $module, 'SH-2 precondition: BpHook/Guards/TrackDispatch.pm exists on disk')
        or diag("missing: $module (package 14 has not written it yet)");
  SKIP: {
        skip 'SH-2: module missing', 2 unless -f $module;
        my $rc = system('perl', "-I$BUTLER_DIR/scripts", '-c', $module);
        is($rc, 0, 'SH-2: perl -c on TrackDispatch.pm passes');
        my $src = read_bytes($module) // '';
        $src =~ s/^\s*#.*$//mg;
        unlike($src, qr/\bsystem\s*\(|\bexec\s*\(|\bexec\s+\S|`|\bqx\b|open\s*\([^)]*\|/,
               'SH-2: the module source never spawns (no system/exec/backtick/qx/pipe-open)');
    }
}

# ===========================================================================
# TD-1 -- Coordinator Pre, butler:bp-implementer: marker bytes exactly
# "butler:bp-implementer"; one running record with the 3.6 fields.
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_coord_env();
    my $logdir = logdir_of($proj);
    my $res = td(pre(subagent_type => 'butler:bp-implementer', description => 'Review Package 01'), env => $env);
    is($res->{rc}, 0, 'TD-1: exit 0');
    is($res->{out}, '', 'TD-1: stdout empty');

    my $mk = marker_of($bp_dir, $env->{BP_PACKAGE});
    ok(-f $mk, 'TD-1: coordinator marker written');
    is(read_bytes($mk), 'butler:bp-implementer', 'TD-1: marker bytes exactly the raw subagent_type');

    my @files = json_record_files($logdir);
    is(scalar(@files), 1, 'TD-1: exactly one running record file');
  SKIP: {
        skip 'TD-1: no record to inspect', 7 unless @files == 1;
        my $rec = read_json($files[0]);
        ok(ref $rec eq 'HASH', 'TD-1: record decodes as a JSON object');
        is($rec->{status}, 'running', 'TD-1: status:running');
        is($rec->{worker_type}, 'bp-implementer', 'TD-1: worker_type is TYPE after its last colon');
        is($rec->{role}, 'worker', 'TD-1: role:worker');
        is($rec->{dispatch_key}, spec_dispatch_key('Review Package 01'), 'TD-1: dispatch_key from the description');
        is($rec->{blueprint}, 'hook-continuity-remake', 'TD-1: blueprint present (env set)');
        is($rec->{package}, $env->{BP_PACKAGE}, 'TD-1: package present (env set)');
        (my $base = $files[0]) =~ s{^.*/}{};
        like($base, qr/^hk-/, 'TD-1: id is hk--prefixed');
    }
}

# ===========================================================================
# TD-2 -- A second writer while the marker holds a writer denies with the
# exact 1-line text; a read-only type is never denied and writes no marker.
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_coord_env();
    my $mk = marker_of($bp_dir, $env->{BP_PACKAGE});
    write_bytes($mk, 'butler:bp-implementer');

    my $res = td(pre(subagent_type => 'butler:bp-test-writer', description => 'second'), env => $env);
    is($res->{rc}, 2, 'TD-2: a second writer while the marker holds a writer denies');
    is($res->{err},
        "BLOCKED: a write-capable worker (butler:bp-implementer) is already in flight; at most one runs at a time, so dispatch butler:bp-test-writer after it returns.\n",
        'TD-2: the exact 1-line deny text');
    is(read_bytes($mk), 'butler:bp-implementer', 'TD-2: the marker is byte-unchanged by the deny');

    my $res_ro = td(pre(subagent_type => 'butler:bp-scout', description => 'read only'), env => $env);
    is($res_ro->{rc}, 0, 'TD-2: a read-only type is never denied');
    is(read_bytes($mk), 'butler:bp-implementer', 'TD-2: the read-only dispatch never overwrites the writer marker');
}

# ===========================================================================
# TD-3 -- Dedup: same base/package/key within 120s -> still one record;
# different descriptions -> two; a planted malformed neighbour neither
# errors nor prints.
# ===========================================================================
{
    my ($env, undef, $proj) = fresh_coord_env();
    my $logdir = logdir_of($proj);
    td(pre(subagent_type => 'butler:bp-scout', description => 'same one'), env => $env);
    td(pre(subagent_type => 'butler:bp-scout', description => 'same one'), env => $env);
    is(scalar(json_record_files($logdir)), 1, 'TD-3: identical description twice dedups to one record');
}
{
    my ($env, undef, $proj) = fresh_coord_env();
    my $logdir = logdir_of($proj);
    td(pre(subagent_type => 'butler:bp-scout', description => 'review a'), env => $env);
    td(pre(subagent_type => 'butler:bp-scout', description => 'review b'), env => $env);
    is(scalar(json_record_files($logdir)), 2, 'TD-3: differing descriptions -> two distinct records');
}
{
    my ($env, undef, $proj) = fresh_coord_env();
    my $logdir = logdir_of($proj);
    # Exact reproduction of the source-file red-team fixture: a leading-zero
    # started_at that is not a valid octal literal (8 is not an octal digit).
    plant_rec_raw($logdir, 'plant',
        '{"budget_seconds":1800,"id":"plant","started_at":0128,"status":"running","worker_type":"bp-scout"}');
    my $res = td(pre(subagent_type => 'butler:bp-scout', description => 'after plant'), env => $env);
    is($res->{rc}, 0, 'TD-3: a planted malformed neighbour -> hook still exits 0');
    is($res->{out}, '', 'TD-3: stdout still empty with the malformed neighbour present');
    is($res->{err}, '', 'TD-3: stderr still empty (no arithmetic/parse error) with the malformed neighbour present');
    my @files = json_record_files($logdir);
    is(scalar(@files), 2, 'TD-3: the scan was not aborted -- the planted file plus one new record');
    my @non_plant = grep { $_ !~ /plant\.json\z/ } @files;
    is(scalar(@non_plant), 1, 'TD-3: exactly one genuine record was written despite the malformed neighbour');
  SKIP: {
        skip 'TD-3: no genuine record to inspect', 1 unless @non_plant == 1;
        my $rec = read_json($non_plant[0]);
        is(ref $rec eq 'HASH' ? $rec->{worker_type} : undef, 'bp-scout', 'TD-3: the new record is well-formed');
    }
}

# ===========================================================================
# TD-4 -- Over 2000 record files: no new record, one alarm line,
# prune_records ran (store shrinks); the next dispatch records normally.
# ===========================================================================
{
    my ($env, undef, $proj) = fresh_coord_env();
    my $logdir = logdir_of($proj);
    make_path($logdir);
    for my $i (1 .. 2001) {
        plant_rec($logdir, "old$i", worker_type => 'bp-scout', role => 'worker',
            status => 'running', started_at => 1);
    }
    my @before = json_record_files($logdir);
    is(scalar(@before), 2001, 'TD-4 setup: 2001 record files planted');

    my $res = td(pre(subagent_type => 'butler:bp-scout', description => 'trigger dispatch'), env => $env);
    is($res->{rc}, 0, 'TD-4: exit 0 despite the over-cap store');
    is($res->{out}, '', 'TD-4: stdout empty');
    is($res->{err}, '', 'TD-4: stderr empty (the alarm goes to retention-alarm.log, never to stderr)');

    my @after = json_record_files($logdir);
    my @has_trigger = grep {
        my $r = read_json($_);
        ref $r eq 'HASH' && defined $r->{dispatch_key} && $r->{dispatch_key} eq 'trigger-dispatch'
    } @after;
    is(scalar(@has_trigger), 0, 'TD-4: no new record was written for the over-cap dispatch (treated as claimed)');
    cmp_ok(scalar(@after), '<', scalar(@before), 'TD-4: the store shrank -- prune_records ran');

    my $alarm_path = alarm_of($proj);
    ok(-f $alarm_path, 'TD-4: retention-alarm.log was written');
    like(read_bytes($alarm_path),
        qr/track-dispatch\.sh stood aside: over 2000 records, this dispatch went unrecorded; running a prune/,
        'TD-4: the alarm line matches the spec text');

    my $res2 = td(pre(subagent_type => 'butler:bp-scout', description => 'now normal'), env => $env);
    is($res2->{rc}, 0, 'TD-4: the next dispatch exits 0');
    my @has_normal = grep {
        my $r = read_json($_);
        ref $r eq 'HASH' && defined $r->{dispatch_key} && $r->{dispatch_key} eq 'now-normal'
    } json_record_files($logdir);
    is(scalar(@has_normal), 1, 'TD-4: the next dispatch records normally, now that the store is under cap');
}

# ===========================================================================
# TD-5 -- Coordinator Post: the matching record becomes done with a
# duration and one history line; run_in_background:true resolves nothing; a
# non-bp type resolves nothing; exit 0, no output.
# ===========================================================================
{
    my ($env, undef, $proj) = fresh_coord_env();
    my $logdir = logdir_of($proj);
    td(pre(subagent_type => 'butler:bp-implementer', description => 'close me'), env => $env);
    my @files = json_record_files($logdir);
    is(scalar(@files), 1, 'TD-5 setup: one running record exists');
  SKIP: {
        skip 'TD-5: no running record to resolve', 5 unless @files == 1;
        my $res = td(post(subagent_type => 'butler:bp-implementer', description => 'close me'), env => $env);
        is($res->{rc}, 0, 'TD-5: PostToolUse exit 0');
        is($res->{out}, '', 'TD-5: PostToolUse stdout empty');
        is($res->{err}, '', 'TD-5: PostToolUse stderr empty');
        my $rec = read_json($files[0]);
        is(ref $rec eq 'HASH' ? $rec->{status} : undef, 'done', 'TD-5: record flips to status:done');
        ok(ref $rec eq 'HASH' && defined $rec->{duration_seconds} && $rec->{duration_seconds} =~ /^\d+\z/,
            'TD-5: duration_seconds is a defined integer');
        is(scalar(history_lines($proj)), 1, 'TD-5: exactly one history.jsonl line appended');
    }
}
{
    my ($env, undef, $proj) = fresh_coord_env();
    my $logdir = logdir_of($proj);
    td(pre(subagent_type => 'butler:bp-implementer', description => 'bg'), env => $env);
    my @files = json_record_files($logdir);
    is(scalar(@files), 1, 'TD-5 (bg) setup: one running record exists');
  SKIP: {
        skip 'TD-5 (bg): no running record', 3 unless @files == 1;
        my $res = td(post(subagent_type => 'butler:bp-implementer', description => 'bg',
            run_in_background => JSON::PP::true()), env => $env);
        is($res->{rc}, 0, 'TD-5 (bg): exit 0');
        is($res->{out} . $res->{err}, '', 'TD-5 (bg): no output');
        my $rec = read_json($files[0]);
        is(ref $rec eq 'HASH' ? $rec->{status} : undef, 'running',
            'TD-5 (bg): run_in_background:true resolves nothing -- the record is still running');
    }
}
{
    my ($env, undef, $proj) = fresh_coord_env();
    my $logdir = logdir_of($proj);
    is(scalar(json_record_files($logdir)), 0, 'TD-5 (non-bp) setup: no record exists for a non-bp-* type');
    my $res = td(post(subagent_type => 'not-a-bp-worker', description => 'x'), env => $env);
    is($res->{rc}, 0, 'TD-5 (non-bp): exit 0');
    is($res->{out} . $res->{err}, '', 'TD-5 (non-bp): no output');
    is(scalar(json_record_files($logdir)), 0, 'TD-5 (non-bp): a non-bp-* type resolves nothing (still no record)');
}

# ===========================================================================
# TD-6 -- Coordinator Post: the ledger gains the header once and the
# "- <ISO Z> · <TYPE> · <DESC>" bullet (DESC = description, else first
# prompt line, cut to 100 chars); the marker is removed only when its
# content equals TYPE exactly.
# ===========================================================================
{
    my ($env, undef, $proj) = fresh_coord_env();
    write_bytes($env->{BP_LEDGER}, "# Package\n\nsome text\n");

    td(pre(subagent_type => 'butler:bp-reviewer', description => 'Review Package 01'), env => $env);
    my $res = td(post(subagent_type => 'butler:bp-reviewer', description => 'Review Package 01'), env => $env);
    is($res->{rc}, 0, 'TD-6: PostToolUse exit 0');

    my $ledger = read_bytes($env->{BP_LEDGER}) // '';
    my $header_count = () = $ledger =~ /## Dispatch log \(auto\)/g;
    is($header_count, 1, 'TD-6: the header appears exactly once');
    like($ledger, qr/- \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z · butler:bp-reviewer · Review Package 01\n/,
        'TD-6: the bullet line matches the ISO-Z/TYPE/DESC shape exactly');

    td(pre(subagent_type => 'butler:bp-reviewer', description => 'Second dispatch'), env => $env);
    td(post(subagent_type => 'butler:bp-reviewer', description => 'Second dispatch'), env => $env);
    my $ledger2 = read_bytes($env->{BP_LEDGER}) // '';
    my $header_count2 = () = $ledger2 =~ /## Dispatch log \(auto\)/g;
    is($header_count2, 1, 'TD-6: the header is not duplicated on a second dispatch');
    like($ledger2, qr/· Second dispatch\n/, 'TD-6: the second bullet is appended too');
}
{
    my ($env, undef, $proj) = fresh_coord_env();
    write_bytes($env->{BP_LEDGER}, "# Package\n");
    td(pre(subagent_type => 'butler:bp-reviewer', prompt => "first prompt line\nsecond line"), env => $env);
    td(post(subagent_type => 'butler:bp-reviewer', prompt => "first prompt line\nsecond line"), env => $env);
    my $ledger = read_bytes($env->{BP_LEDGER}) // '';
    like($ledger, qr/· first prompt line\n/,
        'TD-6: DESC falls back to the first prompt line when description is absent');
}
{
    my ($env, undef, $proj) = fresh_coord_env();
    write_bytes($env->{BP_LEDGER}, "# Package\n");
    my $long = 'x' x 150;
    td(pre(subagent_type => 'butler:bp-reviewer', description => $long), env => $env);
    td(post(subagent_type => 'butler:bp-reviewer', description => $long), env => $env);
    my $ledger = read_bytes($env->{BP_LEDGER}) // '';
    my $cut = 'x' x 100;
    like($ledger, qr/· \Q$cut\E\n/, 'TD-6: a 150-char description is cut to 100 chars in the bullet');
    unlike($ledger, qr/x{101}/, 'TD-6: no run of 101 or more x characters survives in the ledger');
}
{
    # marker removed ONLY when its content equals TYPE exactly.
    my ($env, $bp_dir, $proj) = fresh_coord_env();
    my $mk = marker_of($bp_dir, $env->{BP_PACKAGE});
    td(pre(subagent_type => 'butler:bp-implementer', description => 'a'), env => $env);
    is(read_bytes($mk), 'butler:bp-implementer', 'TD-6 setup: marker equals TYPE after Pre (a writer type; only writers get a marker)');
    write_bytes($mk, 'something-else');
    td(post(subagent_type => 'butler:bp-implementer', description => 'a'), env => $env);
    is(read_bytes($mk), 'something-else', 'TD-6: a marker NOT equal to TYPE is left untouched by Post');
}
{
    my ($env, $bp_dir, $proj) = fresh_coord_env();
    my $mk = marker_of($bp_dir, $env->{BP_PACKAGE});
    td(pre(subagent_type => 'butler:bp-implementer', description => 'b'), env => $env);
    is(read_bytes($mk), 'butler:bp-implementer', 'TD-6 setup: marker equals TYPE after Pre (a writer type; only writers get a marker)');
    td(post(subagent_type => 'butler:bp-implementer', description => 'b'), env => $env);
    ok(!-e $mk, 'TD-6: a marker equal to TYPE exactly is removed by Post');
}

# ===========================================================================
# TD-7 -- Stop signal active: Pre writes nothing and allows;
# BP_DISPATCH_LOG_OFF=1: no record, marker rules unchanged; judges write
# nothing.
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_coord_env();
    write_bytes("$bp_dir/runs/.shutdown", '');
    my $mk = marker_of($bp_dir, $env->{BP_PACKAGE});
    my $res = td(pre(subagent_type => 'butler:bp-implementer', description => 'x'), env => $env);
    is($res->{rc}, 0, 'TD-7 (stop signal): exit 0');
    is($res->{out} . $res->{err}, '', 'TD-7 (stop signal): no output');
    ok(!-e $mk, 'TD-7 (stop signal): no marker written');
    is(scalar(json_record_files(logdir_of($proj))), 0, 'TD-7 (stop signal): no record written');
}
{
    # BP_DISPATCH_LOG_OFF=1: the single-writer interlock still fires...
    my ($env, $bp_dir, $proj) = fresh_coord_env(BP_DISPATCH_LOG_OFF => '1');
    my $mk = marker_of($bp_dir, $env->{BP_PACKAGE});
    write_bytes($mk, 'butler:bp-implementer');
    my $res = td(pre(subagent_type => 'butler:bp-test-writer', description => 'x'), env => $env);
    is($res->{rc}, 2, 'TD-7 (log off): the single-writer interlock still denies with the flag set');
}
{
    # ...and a fresh writer dispatch still gets its marker, but no log record.
    my ($env, $bp_dir, $proj) = fresh_coord_env(BP_DISPATCH_LOG_OFF => '1');
    my $mk = marker_of($bp_dir, $env->{BP_PACKAGE});
    my $res = td(pre(subagent_type => 'butler:bp-implementer', description => 'x'), env => $env);
    is($res->{rc}, 0, 'TD-7 (log off): exit 0');
    is(read_bytes($mk), 'butler:bp-implementer', 'TD-7 (log off): marker rules are unchanged by the flag');
    ok(!-d logdir_of($proj) || scalar(json_record_files(logdir_of($proj))) == 0,
        'TD-7 (log off): no dispatch-log record is written');
}
{
    my ($env, undef, $proj) = fresh_coord_env(BP_ROLE => 'harvest-judge');
    my $res = td(pre(subagent_type => 'butler:bp-implementer', description => 'x'), env => $env);
    is($res->{rc}, 0, 'TD-7 (judge): exit 0');
    is($res->{out} . $res->{err}, '', 'TD-7 (judge): no output');
    ok(!-d logdir_of($proj), 'TD-7 (judge): no store created at all');
}

# ===========================================================================
# TD-8 -- Driver Pre (S armed driver, main thread, .drive-solo/ present): a
# writer dispatch writes the 2.5 marker for its tool_use_id; the description
# fallback works when subagent_type is empty; a read-only dispatch writes
# nothing; no .drive-solo/ dir -> nothing; never denies.
# ===========================================================================
{
    GuardHarness::fresh_state();
    my $sid = 'td8-sid';
    ok(GuardHarness::arm($sid, 'driver'), 'TD-8 setup: session armed driver');

    my $data = tempdir(CLEANUP => 1);
    (my $data_n = $data) =~ s{\\}{/}g;
    make_path("$data_n/.drive-solo");
    my %env = (CCPRAXIS_DATA_DIR => $data_n);

    my $res = td(pre(subagent_type => 'bp-implementer', session_id => $sid, tool_use_id => 'T1'), env => \%env);
    is($res->{rc}, 0, 'TD-8: a writer dispatch never denies');
    my $mk1 = "$data_n/.drive-solo/workers/T1";
    ok(-f $mk1, 'TD-8: the 2.5 marker is written for the tool_use_id');
    my $rec1 = read_json($mk1);
    is(ref $rec1 eq 'HASH' ? $rec1->{subagent_type} : undef, 'bp-implementer', 'TD-8: marker subagent_type = TYPE');
    is(ref $rec1 eq 'HASH' ? $rec1->{session_id} : undef, $sid, 'TD-8: marker carries this session_id');

    # description fallback when subagent_type is empty.
    my $res2 = td(pre(subagent_type => '', description => 'a bp-implementer job',
        session_id => $sid, tool_use_id => 'T2'), env => \%env);
    is($res2->{rc}, 0, 'TD-8 (fallback): never denies');
    my $mk2 = "$data_n/.drive-solo/workers/T2";
    ok(-f $mk2, 'TD-8 (fallback): the marker is written via the description fallback');
    my $rec2 = read_json($mk2);
    is(ref $rec2 eq 'HASH' ? $rec2->{subagent_type} : undef, 'bp-implementer',
        'TD-8 (fallback): marker subagent_type is the writer role found in the description, not the raw text');

    # read-only dispatch writes nothing.
    my $res3 = td(pre(subagent_type => 'bp-scout', session_id => $sid, tool_use_id => 'T3'), env => \%env);
    is($res3->{rc}, 0, 'TD-8 (read-only): never denies');
    ok(!-e "$data_n/.drive-solo/workers/T3", 'TD-8 (read-only): no marker written for a read-only dispatch');

    # no .drive-solo/ dir at all -> nothing.
    my $data_nodir = tempdir(CLEANUP => 1);
    (my $data_nodir_n = $data_nodir) =~ s{\\}{/}g;
    my $res4 = td(pre(subagent_type => 'bp-implementer', session_id => $sid, tool_use_id => 'T4'),
        env => { CCPRAXIS_DATA_DIR => $data_nodir_n });
    is($res4->{rc}, 0, 'TD-8 (no dir): never denies');
    ok(!-e "$data_nodir_n/.drive-solo/workers/T4", 'TD-8 (no dir): no marker written when .drive-solo/ does not exist');
}

# ===========================================================================
# TD-9 -- Driver Post: removes only its own tool_use_id's marker; two
# concurrent writers T1, T2 -> T1's return leaves T2's marker; a read-only
# return clears nothing.
# ===========================================================================
{
    GuardHarness::fresh_state();
    my $sid = 'td9-sid';
    ok(GuardHarness::arm($sid, 'driver'), 'TD-9 setup: session armed driver');

    my $data = tempdir(CLEANUP => 1);
    (my $data_n = $data) =~ s{\\}{/}g;
    make_path("$data_n/.drive-solo");
    write_driver_marker($data_n, 'T1', session_id => $sid, subagent_type => 'bp-implementer');
    write_driver_marker($data_n, 'T2', session_id => $sid, subagent_type => 'bp-test-writer');
    my %env = (CCPRAXIS_DATA_DIR => $data_n);

    my $res = td(post(subagent_type => 'bp-implementer', session_id => $sid, tool_use_id => 'T1'), env => \%env);
    is($res->{rc}, 0, 'TD-9: PostToolUse never denies');
    ok(!-e "$data_n/.drive-solo/workers/T1", 'TD-9: its own tool_use_id marker (T1) is removed');
    ok(-f "$data_n/.drive-solo/workers/T2", 'TD-9: the other concurrent writer marker (T2) is left in place');

    # a read-only return (never wrote a marker in Pre) clears nothing.
    my $res_ro = td(post(subagent_type => 'bp-scout', session_id => $sid, tool_use_id => 'T3'), env => \%env);
    is($res_ro->{rc}, 0, 'TD-9 (read-only): PostToolUse never denies');
    ok(!-e "$data_n/.drive-solo/workers/T3", 'TD-9 (read-only): no marker ever existed at T3, and none is created');
    ok(-f "$data_n/.drive-solo/workers/T2", 'TD-9 (read-only): the unrelated T2 marker is still untouched');
}

# ===========================================================================
# TD-10 -- Decision 3: an unarmed session, or a subagent payload in an armed
# session, writes no marker; a Post from session B with T1's tool_use_id
# does not remove S's T1 marker.
# ===========================================================================
{
    GuardHarness::fresh_state();
    my $sidU = 'td10-unarmed';
    my $data = tempdir(CLEANUP => 1);
    (my $data_n = $data) =~ s{\\}{/}g;
    make_path("$data_n/.drive-solo");
    my $res = td(pre(subagent_type => 'bp-implementer', session_id => $sidU, tool_use_id => 'T4'),
        env => { CCPRAXIS_DATA_DIR => $data_n });
    is($res->{rc}, 0, 'TD-10 (unarmed): never denies');
    ok(!-e "$data_n/.drive-solo/workers/T4", 'TD-10 (unarmed): a never-armed session writes no marker');
}
{
    GuardHarness::fresh_state();
    my $sidS = 'td10-subagent';
    ok(GuardHarness::arm($sidS, 'driver'), 'TD-10 (subagent) setup: session armed driver');
    my $data = tempdir(CLEANUP => 1);
    (my $data_n = $data) =~ s{\\}{/}g;
    make_path("$data_n/.drive-solo");
    my $res = td(pre(subagent_type => 'bp-implementer', session_id => $sidS, agent_id => 'a1', tool_use_id => 'T5'),
        env => { CCPRAXIS_DATA_DIR => $data_n });
    is($res->{rc}, 0, 'TD-10 (subagent): never denies');
    ok(!-e "$data_n/.drive-solo/workers/T5",
        'TD-10 (subagent): a subagent payload (agent_id defined) in an armed driver session writes no marker '
      . '-- the driver branch is main-thread only');
}
{
    GuardHarness::fresh_state();
    my $sidS = 'td10-s';
    my $sidB = 'td10-b';
    ok(GuardHarness::arm($sidS, 'driver'), 'TD-10 (cross-session) setup: session S armed driver');
    ok(GuardHarness::arm($sidB, 'driver'), 'TD-10 (cross-session) setup: session B armed driver');
    my $data = tempdir(CLEANUP => 1);
    (my $data_n = $data) =~ s{\\}{/}g;
    make_path("$data_n/.drive-solo");
    write_driver_marker($data_n, 'T1', session_id => $sidS, subagent_type => 'bp-implementer');
    my $res = td(post(subagent_type => 'bp-implementer', session_id => $sidB, tool_use_id => 'T1'),
        env => { CCPRAXIS_DATA_DIR => $data_n });
    is($res->{rc}, 0, 'TD-10 (cross-session): PostToolUse never denies');
    ok(-f "$data_n/.drive-solo/workers/T1",
        "TD-10 (cross-session): session B's Post carrying S's T1 tool_use_id does not remove S's marker");
    my $rec = read_json("$data_n/.drive-solo/workers/T1");
    is(ref $rec eq 'HASH' ? $rec->{session_id} : undef, $sidS, 'TD-10 (cross-session): the marker still names session S');
}

# ===========================================================================
# TD-12 (part 1) -- the remaining shared ACs run in-process.
# ===========================================================================

# SH-5 -- parse_count unchanged, on TD-2's deny path and on an allow path.
{
    my ($env, $bp_dir) = fresh_coord_env();
    write_bytes(marker_of($bp_dir, $env->{BP_PACKAGE}), 'butler:bp-implementer');
    my $res_deny = td(pre(subagent_type => 'butler:bp-test-writer', description => 'x'), env => $env);
    is($res_deny->{parse_delta}, 0, 'SH-5: parse_count unchanged on a deny path');
}
{
    my ($env) = fresh_coord_env();
    my $res_allow = td(pre(subagent_type => 'butler:bp-scout', description => 'x'), env => $env);
    is($res_allow->{parse_delta}, 0, 'SH-5: parse_count unchanged on an allow path');
}

# SH-6 -- the sole deny's budget (1 line), length, and forbidden vocabulary.
{
    my ($env, $bp_dir) = fresh_coord_env();
    write_bytes(marker_of($bp_dir, $env->{BP_PACKAGE}), 'butler:bp-implementer');
    my $res = td(pre(subagent_type => 'butler:bp-test-writer', description => 'x'), env => $env);
    is($res->{rc}, 2, 'SH-6 setup: the fixture is really a deny');
  SKIP: {
        skip 'SH-6: fixture is not a deny', 4 unless $res->{rc} == 2;
        my @lines = split /\n/, $res->{err};
        pop @lines while @lines && $lines[-1] eq '';
        cmp_ok(scalar(@lines), '<=', 1, 'SH-6: the deny has at most the track-dispatch budget of 1 line');
        for my $l (@lines) {
            cmp_ok(length($l), '<=', 160, 'SH-6: line length <= 160');
            unlike($l, qr/\.run-finished|\.subagent-guard\/force-stop|CCPRAXIS_[A-Z_]*_STOP_OK|MAX_BLOCKS|bp-watch|bp-continuity\.pl|bp-runstate/,
                   'SH-6: the line names no retired mechanism');
            unlike($l, qr/BP_[A-Z_]*_ACTION|_OFF\b|threshold/i, 'SH-6: the line names no disable-a-guard hatch');
        }
    }
    is($res->{out}, '', 'SH-6: stdout is empty');
}

# SH-7 -- bad JSON, a BP_PAYLOAD_TRUNCATED=1 payload, and {} -> exit 0, no output.
{
    my ($env) = fresh_coord_env();
    for my $c (
        ['{}'                           => 'empty object'],
        ['not json at all'              => 'malformed JSON'],
        ['{"tool_name":"Task","tool_i'  => 'truncated JSON'],
    ) {
        my ($raw, $label) = @$c;
        my %e = %$env;
        $e{BP_PAYLOAD_TRUNCATED} = 1 if $label eq 'truncated JSON';
        my $res = td($raw, env => \%e);
        is($res->{rc}, 0, "SH-7: $label -> exit 0");
        is($res->{out}, '', "SH-7: $label -> empty stdout");
        is($res->{err}, '', "SH-7: $label -> empty stderr");
    }
}

# SH-9 -- opt-in timing block, gated, never asserted (Decision 33).
{
  SKIP: {
        skip 'SH-9: opt-in timing run (set GUARDS_REMAKE_TIME=1 and run this file alone)', 1
            unless $ENV{GUARDS_REMAKE_TIME};
        pass('SH-9: opt-in timing harness placeholder -- run this file alone with '
           . 'GUARDS_REMAKE_TIME=1 to record medians against the package-01 item (g) '
           . 'floor + 100ms; wall time itself is never asserted here');
    }
}

# ===========================================================================
# TD-12 (part 2) -- [wrapper]/[shim] cases. SH-3 (not-applies: a Bash tool
# call, which the tool-filter allows before any perl runs), SH-4 (applies:
# coordinator Pre for a bp-* type -- the path that used to spawn
# bp-dispatch-log.pl -- exactly 1 perl launch), SH-8 (one deny case end to
# end through the real wrapper, same stderr as in-process).
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_coord_env();
    my $res_not_applies = GuardHarness::run_shim('track-dispatch.sh',
        # Not-applies is the prefilter (--pre ledger,driver): no BP_LEDGER and a session that is not an
        # armed driver. The hook is registered on Task|Agent only, so the call is a real Task dispatch.
        { hook_event_name => 'PreToolUse', tool_name => 'Task',
          tool_input => { subagent_type => 'butler:bp-implementer', description => 'x', prompt => 'p' },
          session_id => 'td-shim-notapplies' },
        env => {});
    is($res_not_applies->{rc}, 0, 'SH-3: a non-coordinator, unarmed session -> exit 0');
    is($res_not_applies->{out}, '', 'SH-3: empty stdout');
    is($res_not_applies->{err}, '', 'SH-3: empty stderr');
    is(GuardHarness::count_lines($res_not_applies->{shim_log}, 'perl'), 0,
       'SH-3: 0 perl launches (the ledger,driver prefilter fails in bash)');

    my $res_applies = GuardHarness::run_shim('track-dispatch.sh',
        pre(subagent_type => 'butler:bp-scout', description => 'shim applies', session_id => 'td-shim-applies'),
        env => $env);
    is($res_applies->{rc}, 0, 'SH-4: coordinator Pre for a bp-* type reaches perl and allows');
    is(GuardHarness::count_lines($res_applies->{shim_log}, 'perl'), 1, 'SH-4: exactly 1 perl launch');
}
{
    my ($env, $bp_dir, $proj) = fresh_coord_env();
    write_bytes(marker_of($bp_dir, $env->{BP_PACKAGE}), 'butler:bp-implementer');
    my $res_wrapper = GuardHarness::run_wrapper('track-dispatch.sh',
        pre(subagent_type => 'butler:bp-test-writer', description => 'x', session_id => 'td-sh8'),
        env => $env);
    is($res_wrapper->{rc}, 2, 'SH-8: one deny case end to end through the real wrapper');
    is($res_wrapper->{err},
        "BLOCKED: a write-capable worker (butler:bp-implementer) is already in flight; at most one runs at a time, so dispatch butler:bp-test-writer after it returns.\n",
        'SH-8: the wrapper stderr is identical to the in-process TD-2 text');
}

# ===========================================================================
# Harness self-check -- confirms GuardHarness itself works, against a real
# EXISTING successor (stop-gate.sh, package 06), not TrackDispatch. Proves a
# red result above is track-dispatch's absence, not a harness defect.
# Repeats batch 1's own self-check independently, since this file must
# stand on its own when the runner parallelises files.
# ===========================================================================
{
    GuardHarness::fresh_state();
    my $stopgate = "$BUTLER_DIR/hooks/stop-gate.sh";
    ok(-f $stopgate, 'self-check precondition: stop-gate.sh (package 06) exists on disk');

    my $res_shim = GuardHarness::run_shim($stopgate,
        { session_id => 'tdselfcheck-1', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_shim->{rc}, 0, 'self-check: run_shim against the real stop-gate.sh (unarmed) allows');
    is(GuardHarness::count_lines($res_shim->{shim_log}, 'perl'), 0,
       'self-check: run_shim reports 0 perl launches on stop-gate.sh\'s not-applies path (unarmed)');

    ok(GuardHarness::arm('tdselfcheck-2', 'manual'), 'self-check: GuardHarness::arm() armed a session');
    my $res_shim_armed = GuardHarness::run_shim($stopgate,
        { session_id => 'tdselfcheck-2', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_shim_armed->{rc}, 2, 'self-check: run_shim against stop-gate.sh, now armed -> denies (applies path)');
    is(GuardHarness::count_lines($res_shim_armed->{shim_log}, 'perl'), 1, 'self-check: ...with exactly 1 perl launch');

    my $res_module_armed = GuardHarness::run_module('StopGate',
        { session_id => 'tdselfcheck-2', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_module_armed->{rc}, 2,
       'self-check: run_module("StopGate", ...) against the real StopGate.pm, armed -> denies '
     . '(proves run_module really requires BpHook/StopGate.pm by relative path and calls its run(), '
     . 'rather than failing open silently)');

    my $res_module_unarmed = GuardHarness::run_module('StopGate',
        { session_id => 'tdselfcheck-never-armed', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_module_unarmed->{rc}, 0,
       'self-check: run_module("StopGate", ...) against the real StopGate.pm, a DIFFERENT and never-armed '
     . 'session -> allows');
}

# ===========================================================================
# TD-11 -- FINAL SAFETY CHECK. Must be the last thing this file does before
# done_testing().
# ===========================================================================
{
    my $after = real_logdir_snapshot();
    is_deeply($after, $REAL_SNAPSHOT_BEFORE,
        'TD-11: the real .ccpraxis-local-data/.dispatch-log is byte-for-byte untouched by this whole file');
}

# ===========================================================================
# R9-B2/TM4 (review B2, redteam M4): a non-ASCII description ("—" U+2014
# plus "é" U+00E9) must land in BP_LEDGER as VALID UTF-8, byte-exact. The
# current code builds the "· " separator from a raw BYTE string ($dot =
# "\xC2\xB7") concatenated with a decoded CHARACTER string, printed to a
# ":raw" handle -- upgrading the byte string and corrupting the separator
# into mojibake whenever the description carries any character above
# U+00FF, and writing a lone invalid byte when it stays in Latin-1 range.
# ===========================================================================
{
    my ($env, undef, $proj) = fresh_coord_env();
    write_bytes($env->{BP_LEDGER}, "# Package\n");
    my $desc = "fix the guard \x{2014} caf\x{00e9} path"; # em dash + e-acute
    td(pre(subagent_type => 'butler:bp-reviewer', description => $desc), env => $env);
    td(post(subagent_type => 'butler:bp-reviewer', description => $desc), env => $env);
    my $ledger_bytes = read_bytes($env->{BP_LEDGER}) // '';
    # Decode ONCE to Perl characters and assert on CHARACTERS, not bytes --
    # a byte-level regex for the dot (c2 b7) can accidentally match INSIDE
    # the mojibake sequence (c3 82 c2 b7 contains c2 b7 as its last two
    # bytes), which is exactly the false-pass trap this bug creates.
    my $copy = $ledger_bytes;
    my $decode_ok = utf8::decode($copy);
    ok($decode_ok, 'R9-B2/TM4: the ledger, after a non-ASCII (em dash + e-acute) dispatch description, decodes as valid UTF-8');
  SKIP: {
        skip 'R9-B2/TM4: ledger is not valid UTF-8, cannot check decoded characters', 1 unless $decode_ok;
        my $expected_bullet = "\x{B7} butler:bp-reviewer \x{B7} fix the guard \x{2014} caf\x{00e9} path\n";
        like($copy, qr/\Q$expected_bullet\E/,
            'R9-B2/TM4: decoded, the bullet is the single real MIDDLE DOT (U+00B7) around TYPE and the exact description characters (em dash, e-acute) -- never a doubled/mojibake dot');
    }
}
{
    # the Latin-1-only half of M4: a description whose only non-ASCII
    # character is in Latin-1 range must still be valid UTF-8 in the ledger
    # (today it is written as the single invalid byte 0xE9).
    my ($env, undef, $proj) = fresh_coord_env();
    write_bytes($env->{BP_LEDGER}, "# Package\n");
    my $desc = "caf\x{00e9} fix";
    td(pre(subagent_type => 'butler:bp-reviewer', description => $desc), env => $env);
    td(post(subagent_type => 'butler:bp-reviewer', description => $desc), env => $env);
    my $ledger_bytes = read_bytes($env->{BP_LEDGER}) // '';
    my $copy = $ledger_bytes;
    my $decode_ok = utf8::decode($copy);
    ok($decode_ok, 'R9-B2/TM4 (Latin-1 case): a description holding only "é" still decodes as valid UTF-8 in the ledger');
  SKIP: {
        skip 'R9-B2/TM4 (Latin-1 case): ledger is not valid UTF-8, cannot check decoded characters', 1 unless $decode_ok;
        like($copy, qr/caf\x{00e9} fix/, 'R9-B2/TM4 (Latin-1 case): decoded, "é" is the real character U+00E9 (valid UTF-8), never a raw invalid byte');
    }
}

# ===========================================================================
# R9-TH1 (redteam H1, and TM6): Claude Code 2.1.280 auto-backgrounds an
# Agent dispatch with no background key (harness-facts.md (e3)/(c)): its
# PostToolUse fires ~176ms after PreToolUse with
# tool_response:{isAsync:true,status:"async_launched"}, while the worker is
# still running. Neither the coordinator marker nor the per-dispatch driver
# marker may be cleared on that Post -- only on the matching SubagentStop
# (harness-facts.md: SubagentStop carries agent_id/agent_transcript_path;
# package 14's own binding technique, already used by GB-11's meta.json
# fixture, maps agent_id -> tool_use_id). A marker older than the staleness
# TTL (this file's own STALE_MIN convention: CCPRAXIS_VALIDATION_STALE_MIN,
# default 180 minutes, the same constant GuardBash::_stale_min uses) must no
# longer block a fresh writer dispatch (TM6, and the M6 half of this fix).
# ===========================================================================
{
    # driver marker: an async Post (isAsync/async_launched) must NOT clear it.
    GuardHarness::fresh_state();
    my $sid = 'r9th1-driver-sid';
    ok(GuardHarness::arm($sid, 'driver'), 'R9-TH1 setup: session armed driver');
    my $data = tempdir(CLEANUP => 1);
    (my $data_n = $data) =~ s{\\}{/}g;
    make_path("$data_n/.drive-solo");
    write_driver_marker($data_n, 'T1', session_id => $sid, subagent_type => 'bp-implementer');
    my %env = (CCPRAXIS_DATA_DIR => $data_n);

    my $async_post = {
        hook_event_name => 'PostToolUse', tool_name => 'Agent', session_id => $sid,
        tool_use_id => 'T1', tool_input => { subagent_type => 'bp-implementer' },
        tool_response => { isAsync => JSON::PP::true(), status => 'async_launched' },
    };
    my $res = td($async_post, env => \%env);
    is($res->{rc}, 0, 'R9-TH1: an async Agent PostToolUse never denies');
    ok(-f "$data_n/.drive-solo/workers/T1",
        'R9-TH1: ...and does NOT clear the driver marker -- the worker is still running');
}
{
    # driver marker: a SubagentStop for that same dispatch DOES clear it.
    GuardHarness::fresh_state();
    my $sid = 'r9th1-driver-stop-sid';
    ok(GuardHarness::arm($sid, 'driver'), 'R9-TH1 setup: session armed driver');
    my $data = tempdir(CLEANUP => 1);
    (my $data_n = $data) =~ s{\\}{/}g;
    make_path("$data_n/.drive-solo");
    write_driver_marker($data_n, 'T1', session_id => $sid, subagent_type => 'bp-implementer');
    my $tp = "$data_n/transcript.jsonl";
    write_bytes($tp, ''); # write_meta_json below only needs dirname($tp)
    my $subdir = dirname($tp) . "/$sid/subagents";
    make_path($subdir);
    write_bytes("$subdir/agent-a1.meta.json", JSON::PP->new->canonical->encode({ toolUseId => 'T1' }));
    my %env = (CCPRAXIS_DATA_DIR => $data_n);

    my $subagent_stop = {
        hook_event_name => 'SubagentStop', session_id => $sid, agent_id => 'a1',
        agent_type => 'general-purpose', transcript_path => $tp,
        agent_transcript_path => "$subdir/agent-a1.jsonl", stop_hook_active => JSON::PP::false(),
    };
    my $res = td($subagent_stop, env => \%env);
    is($res->{rc}, 0, 'R9-TH1: SubagentStop never denies');
    ok(!-e "$data_n/.drive-solo/workers/T1",
        'R9-TH1: ...and DOES clear the driver marker for the dispatch it completed');
}
{
    # coordinator marker: an async Post must not resolve/clear it either.
    my ($env, $bp_dir, $proj) = fresh_coord_env();
    my $mk = marker_of($bp_dir, $env->{BP_PACKAGE});
    td(pre(subagent_type => 'butler:bp-implementer', description => 'r9th1 coord'), env => $env);
    is(read_bytes($mk), 'butler:bp-implementer', 'R9-TH1 (coordinator) setup: marker written by Pre');
    my $async_post = post(subagent_type => 'butler:bp-implementer', description => 'r9th1 coord',
        tool_response => { isAsync => JSON::PP::true(), status => 'async_launched' });
    my $res = td($async_post, env => $env);
    is($res->{rc}, 0, 'R9-TH1 (coordinator): an async Post never denies');
    is(read_bytes($mk), 'butler:bp-implementer',
        'R9-TH1 (coordinator): ...and the coordinator marker is left in place -- the worker is still running');
}
# Bug 20261012-013358-1404: the coordinator half of R9-TH1 had no completion
# path at all. _handle_subagent_stop returned at once whenever BP_LEDGER was
# set, so a backgrounded writer's runs/<pkg>.active-worker outlived the worker
# and refused every later test run in the package (and, through the shared-tree
# interlock, in its siblings) until the 180-minute age-out.
{
    my $coord_stop = sub {
        my (%o) = @_;   # marker, meta (hashref), payload_type
        my ($env, $bp_dir) = fresh_coord_env();
        my $mk = marker_of($bp_dir, $env->{BP_PACKAGE});
        write_bytes($mk, $o{marker});
        my $tp = "$bp_dir/transcript.jsonl";
        write_bytes($tp, '');
        my $sid = 'r9th1-coord-stop-sid';
        my $subdir = dirname($tp) . "/$sid/subagents";
        make_path($subdir);
        write_bytes("$subdir/agent-c1.meta.json", JSON::PP->new->canonical->encode($o{meta}));
        my $res = td({
            hook_event_name => 'SubagentStop', session_id => $sid, agent_id => 'c1',
            agent_type => $o{payload_type} // $o{meta}{agentType}, transcript_path => $tp,
            agent_transcript_path => "$subdir/agent-c1.jsonl", stop_hook_active => JSON::PP::false(),
        }, env => $env);
        return ($res, $mk);
    };

    my ($res, $mk) = $coord_stop->(marker => 'butler:bp-implementer',
        meta => { agentType => 'butler:bp-implementer', toolUseId => 'C1', spawnDepth => 1 });
    is($res->{rc}, 0, 'R9-TH1 (coordinator): SubagentStop never denies');
    ok(!-e $mk, 'R9-TH1 (coordinator): the SubagentStop of the backgrounded writer clears its marker');

    ($res, $mk) = $coord_stop->(marker => 'butler:bp-implementer',
        meta => { agentType => 'butler:bp-reviewer', toolUseId => 'C2', spawnDepth => 1 });
    is(read_bytes($mk), 'butler:bp-implementer',
        'R9-TH1 (coordinator): a different worker finishing leaves the writer\'s marker in place');

    ($res, $mk) = $coord_stop->(marker => 'butler:bp-implementer',
        meta => { agentType => 'butler:bp-implementer', toolUseId => 'C3', spawnDepth => 2 });
    is(read_bytes($mk), 'butler:bp-implementer',
        'R9-TH1 (coordinator): a nested subagent of the same type finishing does not clear it');
}
{
    # TM6 (and the M6 half): a coordinator marker older than the staleness
    # TTL no longer blocks a fresh writer dispatch.
    my $STALE_MIN = 180;
    my $STALE_SECS = $STALE_MIN * 60;
    my ($env, $bp_dir, $proj) = fresh_coord_env();
    my $mk = marker_of($bp_dir, $env->{BP_PACKAGE});
    write_bytes($mk, 'bp-implementer');
    utime(time() - $STALE_SECS - 60, time() - $STALE_SECS - 60, $mk);
    my $res = td(pre(subagent_type => 'bp-test-writer', description => 'r9tm6'), env => $env);
    is($res->{rc}, 0, 'R9-TM6: a coordinator marker older than STALE_MIN no longer blocks a second writer dispatch');
}

# ---------------------------------------------------------------------------
# R9-TM7 (redteam M7): the single-writer check is check-then-write (a plain
# "-f" test, then a plain ">" open with no O_EXCL claim), which is a real
# race under concurrent PreToolUse calls. NOT independently testable here:
# this harness runs every call in-process and sequentially (GuardHarness::
# run_module never spawns two overlapping calls), so it cannot exercise two
# PreToolUse hooks racing against the same marker file -- the redteam report
# itself notes this is a static finding, unverified by its own in-process
# probes. Left untested per the task's own allowance ("only if you can
# prove it hermetically and cheaply; otherwise note it").
# ---------------------------------------------------------------------------

$? = 0;
done_testing();
