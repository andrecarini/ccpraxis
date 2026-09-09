#!/usr/bin/env perl
# t/182 -- the dispatch-log store must SHRINK, and the over-cap path must heal.
#
# Bug 20260908-225444-b9db. The store only ever grew: `start` wrote one record
# per dispatch and nothing removed one. Hook-written worker records are never
# `finish`ed at all -- track-dispatch.sh's PostToolUse side has no correlation
# key by which it could identify which record to close -- so they sit at
# `running` forever, age into `stale`, and stay.
#
# Two consumers then went silently dark at DIFFERENT thresholds, the lower one
# first:
#
#   store >  512  the dashboard renders no agent detail at all
#                 ($RunState::MAX_DISPATCH_RECORDS)
#   store > 2000  track-dispatch.sh stops recording entirely (its scan cap)
#
# Neither cap is wrong on its own; both are the correct local answer to an
# unbounded store. So the fix is retention in the writer, and this file pins the
# three decisions that make it a fix rather than a gesture:
#
#   1. STALE `running` records are PRUNABLE. Unfinished `running` records are
#      the entire population that fills this directory. Protecting all of them
#      would make retention a no-op that still looks like a fix -- so only
#      is_live records are protected, and those unconditionally.
#   2. The keep target is under the 512 READER cap, not merely under the 2000
#      writer cap. Sizing to the higher number would leave the visible failure
#      (a blank agent panel) exactly where it was.
#   3. The hook's over-cap branch RUNS THE PRUNE. Standing aside alone was a
#      one-way door: past 2000 the hook stopped calling the logger, and the
#      logger's `start` is the only thing that can shrink the store.
#
# No test sleeps; every timestamp is injected through the --now test seam or
# passed straight to a pure function.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;

my $SCRIPT     = "$Bin/../../scripts/bp-dispatch-log.pl";
my $HOOK       = "$Bin/../../hooks/track-dispatch.sh";
my $RUNSTATE   = "$Bin/../../../sandbox/scripts/RunState.pm";

my $REQUIRE_ERROR = '';
my $LOADED = do { local $@; eval { require $SCRIPT }; $REQUIRE_ERROR = $@; !$@ };
ok($LOADED, 'harness: bp-dispatch-log.pl requires cleanly')
    or BAIL_OUT("require died with: $REQUIRE_ERROR");

for my $sub (qw(prune_plan prune_records note_alarm alarm_path)) {
    ok(defined &{"BpDispatchLog::$sub"}, "BpDispatchLog::$sub is defined");
}

# --- helpers ---------------------------------------------------------------

sub mk_root {
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/.ccpraxis-local-data/.dispatch-log");
    return $root;
}
sub log_dir { return "$_[0]/.ccpraxis-local-data/.dispatch-log" }

# write_rec($root, $id, %fields) -- one record file, plus the .lock sibling
# BpWrite::guarded_write leaves behind in production.
sub write_rec {
    my ($root, $id, %f) = @_;
    my $dir = log_dir($root);
    my %rec = (id => $id, worker_type => 'bp-implementer', status => 'running',
               started_at => 1000, budget_seconds => 1800, %f);
    my @pairs;
    for my $k (sort keys %rec) {
        next unless defined $rec{$k};
        my $v = $rec{$k};
        push @pairs, "\"$k\":" . (($v =~ /^-?\d+\z/) ? $v : "\"$v\"");
    }
    open my $fh, '>', "$dir/$id.json" or die "$dir/$id.json: $!";
    print {$fh} '{' . join(',', @pairs) . '}';
    close $fh;
    open my $lk, '>', "$dir/$id.json.lock" or die $!;
    close $lk;
    return "$dir/$id.json";
}

sub ls_records { my @f = glob(log_dir($_[0]) . '/*.json'); return scalar @f }
sub ls_locks   { my @f = glob(log_dir($_[0]) . '/*.json.lock'); return scalar @f }

sub slurp { open my $f, '<', $_[0] or return undef; local $/; my $t = <$f>; close $f; return $t }

# run($root, @args) -> ($stdout, $stderr, $exit). --now is honoured only with
# the test-seam env marker set, exactly as production requires.
sub run_cli {
    my ($root, @args) = @_;
    my $out = File::Spec->catfile($root, 'o.txt');
    my $err = File::Spec->catfile($root, 'e.txt');
    local $ENV{CCPRAXIS_DISPATCH_LOG_TEST_NOW} = '1';
    my $cmd = join(' ', 'perl', "\"$SCRIPT\"", @args, "> \"$out\"", "2> \"$err\"");
    my $rc  = system($cmd);
    my $exit = ($rc & 127) ? (128 + ($rc & 127)) : ($rc >> 8);
    return (slurp($out) // '', slurp($err) // '', $exit);
}

# ===========================================================================
# A. prune_plan -- PURE. The classification is the whole design.
# ===========================================================================
{
    my $now = 1_000_000;
    is_deeply(BpDispatchLog::prune_plan([], $now, 10), [], 'A1: empty input prunes nothing');
    is_deeply(BpDispatchLog::prune_plan(undef, $now, 10), [], 'A1: undef input prunes nothing');

    my @under = map { { id => "r$_", rec => { worker_type => 'w', status => 'running',
                                              started_at => $_ } } } (1 .. 5);
    is_deeply(BpDispatchLog::prune_plan(\@under, $now, 10), [],
              'A2: a store at or under keep prunes nothing');

    # Six stale records, keep 2 -> the four OLDEST go. started_at 1..6, and
    # $now is far enough past all of them that every one is stale.
    my @over = map { { id => sprintf('r%02d', $_),
                       rec => { worker_type => 'w', status => 'running', started_at => $_,
                                budget_seconds => 1800 } } } (1 .. 6);
    is_deeply([ sort @{ BpDispatchLog::prune_plan(\@over, $now, 2) } ],
              [ qw(r01 r02 r03 r04) ],
              'A3: over keep, the OLDEST records are the ones pruned');

    # Decision 1, load-bearing: STALE running records are prunable. If they
    # were not, retention would be a no-op -- they are the whole population.
    my $stale_only = [ map { { id => "s$_", rec => { worker_type => 'w', status => 'running',
                                                     started_at => 1, budget_seconds => 1800 } } }
                       (1 .. 4) ];
    is(scalar @{ BpDispatchLog::prune_plan($stale_only, $now, 1) }, 3,
       'A4: STALE running records are prunable -- otherwise retention deletes nothing at all');

    # LIVE records are protected unconditionally, whatever the count.
    my $live_only = [ map { { id => "l$_", rec => { worker_type => 'w', status => 'running',
                                                    started_at => $now, budget_seconds => 1800 } } }
                      (1 .. 40) ];
    is_deeply(BpDispatchLog::prune_plan($live_only, $now, 0), [],
              'A5: LIVE records are never pruned, even with keep = 0');

    # Mixed: the live one survives a keep of 0; the stale ones do not.
    my $mixed = [
        { id => 'live',  rec => { worker_type => 'w', status => 'running', started_at => $now,
                                  budget_seconds => 1800 } },
        { id => 'stale', rec => { worker_type => 'w', status => 'running', started_at => 1,
                                  budget_seconds => 1800 } },
        { id => 'done',  rec => { worker_type => 'w', status => 'done', started_at => 1 } },
    ];
    is_deeply([ sort @{ BpDispatchLog::prune_plan($mixed, $now, 0) } ], [ qw(done stale) ],
              'A6: keep = 0 prunes the finished and the stale, and still spares the live one');

    # Not ours -> left alone entirely. `start` requires --worker-type, so a
    # record without one was written by something else, and deleting it would
    # be this function exceeding its remit.
    my $foreign = [
        { id => 'foreign', rec => { some => 'other', shape => 1 } },
        { id => 'nothash', rec => undef },
        { id => 'arr',     rec => [] },
        { id => 'mine',    rec => { worker_type => 'w', status => 'done', started_at => 1 } },
    ];
    is_deeply(BpDispatchLog::prune_plan($foreign, $now, 0), [ 'mine' ],
              'A7: a file with no worker_type is never pruned -- it is not this writer\'s');

    # An unevaluable started_at sorts OLDEST: `elapsed` and `list` both already
    # refuse to report on such a record, so it informs no consumer.
    my $unev = [
        { id => 'good', rec => { worker_type => 'w', status => 'done', started_at => 500 } },
        { id => 'nostart', rec => { worker_type => 'w', status => 'done' } },
        { id => 'texty', rec => { worker_type => 'w', status => 'done', started_at => 'soon' } },
    ];
    is_deeply([ sort @{ BpDispatchLog::prune_plan($unev, $now, 1) } ], [ qw(nostart texty) ],
              'A8: records with no usable started_at are pruned before ones that have it');

    # Determinism: equal keys break on id, so the plan never depends on
    # readdir order. A prune that did would be untestable.
    my $ties = [ map { { id => "t$_", rec => { worker_type => 'w', status => 'done',
                                               started_at => 7 } } } (1 .. 5) ];
    is_deeply(BpDispatchLog::prune_plan($ties, $now, 2),
              BpDispatchLog::prune_plan([ reverse @$ties ], $now, 2),
              'A9: the plan is identical for the same records in a different order');

    # A negative/garbage keep falls back to the default rather than pruning
    # everything -- the failure direction matters here.
    is_deeply(BpDispatchLog::prune_plan(\@over, $now, 'lots'), [],
              'A10: a non-numeric keep falls back to the default, and does not prune the store flat');
}

# ===========================================================================
# B. prune_records -- IMPURE. Gate, deletion, locks, and what it must not touch.
# ===========================================================================
{
    my $root = mk_root();
    write_rec($root, "u$_", started_at => 1) for (1 .. 5);
    my $sum = BpDispatchLog::prune_records($root, 1_000_000);
    is($sum->{skipped}, 1, 'B1: under the high-water mark the pass is skipped');
    is($sum->{pruned}, 0,  'B1: nothing is pruned while skipped');
    is(ls_records($root), 5, 'B1: every record survives');
}

{
    my $root = mk_root();
    write_rec($root, sprintf('s%03d', $_), started_at => $_) for (1 .. 20);
    write_rec($root, 'liveone', started_at => 999_000, budget_seconds => 1800);

    # history.jsonl and a foreign file must both survive.
    open my $h, '>', log_dir($root) . '/history.jsonl' or die $!;
    print {$h} qq({"worker_type":"w","duration_seconds":5,"ended_at":9}\n);
    close $h;
    open my $fo, '>', log_dir($root) . '/not-ours.json' or die $!;
    print {$fo} '{"something":"else"}';
    close $fo;

    # An orphaned lock: a write that never produced a record, or a record
    # removed by hand. It protects nothing.
    open my $ol, '>', log_dir($root) . '/ghost.json.lock' or die $!;
    close $ol;

    my $sum = BpDispatchLog::prune_records($root, 999_000, keep => 5, force => 1);
    is($sum->{skipped}, 0, 'B2: force runs the pass regardless of the high-water mark');
    is($sum->{pruned}, 15, 'B2: 20 stale records, keep 5 -> 15 pruned');
    is($sum->{failed}, 0,  'B2: no unlink failed');

    ok(-f log_dir($root) . '/liveone.json', 'B3: the LIVE record survives a keep it would not fit in');
    ok(-f log_dir($root) . '/history.jsonl', 'B4: history.jsonl is never a prune candidate');
    ok(-f log_dir($root) . '/not-ours.json', 'B5: a foreign *.json with no worker_type survives');

    ok(!-f log_dir($root) . '/s001.json',      'B6: the oldest record is gone');
    ok(!-f log_dir($root) . '/s001.json.lock', 'B6: and so is its lock file');
    ok(-f log_dir($root) . '/s020.json',       'B6: the newest kept record is still there');
    ok(!-f log_dir($root) . '/ghost.json.lock', 'B7: an orphaned lock with no record is swept');

    # 21 records + not-ours.json = 22 on disk; 15 pruned leaves 7.
    is(ls_records($root), 7, 'B8: the store is left at keep + live + foreign');
    is(ls_locks($root), 6,   'B8: exactly the surviving records keep their locks');
}

# ===========================================================================
# C. The alarm -- a cap reached silently is a permanent stop nobody can find.
# ===========================================================================
{
    my $root = mk_root();
    # Every record LIVE, so the prune cannot help: remaining stays over the
    # reader cap and the alarm is the only thing that says so. READER_CAP is
    # localised so the mechanism is exercised without writing 513 files; the
    # real number is pinned separately in section E.
    local $BpDispatchLog::READER_CAP = 4;
    write_rec($root, "c$_", started_at => 999_000, budget_seconds => 1800) for (1 .. 10);

    my $sum = BpDispatchLog::prune_records($root, 999_000, keep => 0, force => 1);
    is($sum->{pruned}, 0, 'C1: nothing prunable -- every record is live');
    is($sum->{remaining}, 10, 'C1: so the store is still over the reader cap');

    my $alarm = BpDispatchLog::alarm_path($root);
    ok(-f $alarm, 'C2: an alarm line is on disk');
    my $txt = slurp($alarm) // '';
    like($txt, qr/\b10\b/, 'C2: the alarm names the actual store size');
    like($txt, qr/\b4\b/,  'C2: and the cap it is over');

    # The alarm file must not become part of the thing it is warning about.
    is(ls_records($root), 10, 'C3: the alarm file is not counted as a record');
    ok(BpDispatchLog::alarm_path($root) !~ /\.json\z/, 'C3: and cannot be, by its name');

    # Bounded: past the ceiling it is truncated, not grown forever.
    local $BpDispatchLog::ALARM_MAX_BYTES = 32;
    BpDispatchLog::note_alarm($root, 'x' x 200, 5);
    BpDispatchLog::note_alarm($root, 'second line', 6);
    my $after = slurp($alarm) // '';
    ok(length($after) < 400, 'C4: the alarm file is truncated past its ceiling, not appended forever')
        or diag("alarm file is " . length($after) . " bytes");
    like($after, qr/second line/, 'C4: and the newest line is the one kept');
}

{
    # A prune that succeeds says nothing -- silence is the healthy state.
    my $root = mk_root();
    write_rec($root, sprintf('q%03d', $_), started_at => $_) for (1 .. 20);
    BpDispatchLog::prune_records($root, 999_000, keep => 2, force => 1);
    ok(!-f BpDispatchLog::alarm_path($root),
       'C5: a prune that brings the store under the cap writes no alarm');
}

# ===========================================================================
# D. The CLI -- the prune verb, its guards, and start's automatic pass.
# ===========================================================================
{
    my $root = mk_root();
    write_rec($root, sprintf('d%03d', $_), started_at => $_) for (1 .. 12);
    my ($out, $err, $exit) = run_cli($root, 'prune', '--root', "\"$root\"", '--keep', '3',
                                     '--now', '999000');
    is($exit, 0, 'D1: prune exits 0');
    like($out, qr/^scanned: 12$/m,  'D1: it reports what it scanned');
    like($out, qr/^pruned: 9$/m,    'D1: what it pruned');
    like($out, qr/^remaining: 3$/m, 'D1: and what is left');
    is(ls_records($root), 3, 'D1: the disk agrees with the report');
}

{
    my $root = mk_root();
    my ($out, $err, $exit) = run_cli($root, 'start', '--id', 'x1', '--worker-type', 'bp-implementer',
                                     '--root', "\"$root\"", '--keep', '3');
    is($exit, 2, 'D2: --keep on a non-prune command is a usage error');
    like($err, qr/only valid with the prune command/, 'D2: and says which command owns it');
}

{
    my $root = mk_root();
    my ($out, $err, $exit) = run_cli($root, 'prune', '--root', "\"$root\"", '--keep', 'many');
    is($exit, 2, 'D3: a non-numeric --keep is a usage error');
    like($err, qr/non-negative integer/, 'D3: naming what it expected');
}

{
    # Under the high-water mark, `start` leaves the store alone.
    my $root = mk_root();
    write_rec($root, sprintf('e%03d', $_), started_at => $_) for (1 .. 10);
    my ($out, $err, $exit) = run_cli($root, 'start', '--id', 'fresh', '--worker-type', 'bp-scout',
                                     '--root', "\"$root\"", '--now', '999000');
    is($exit, 0, 'D4: start succeeds');
    is(ls_records($root), 11, 'D4: and prunes nothing under the high-water mark');
    unlike($err, qr/retention pruned/, 'D4: reporting nothing, because nothing happened');
}

{
    # Over it, `start` prunes -- and still records the dispatch it was called
    # for, which is the job. The record it just wrote is live, so it survives.
    my $n = $BpDispatchLog::RETENTION_HIGH_WATER + 1;
    my $root = mk_root();
    write_rec($root, sprintf('f%04d', $_), started_at => $_) for (1 .. $n);
    my ($out, $err, $exit) = run_cli($root, 'start', '--id', 'newest', '--worker-type', 'bp-scout',
                                     '--root', "\"$root\"", '--now', '999000');
    is($exit, 0, 'D5: start still succeeds over the high-water mark');
    like($out, qr/^started newest /m, 'D5: and records the dispatch it was called for');
    ok(-f log_dir($root) . '/newest.json', 'D5: the new record is on disk');
    is(ls_records($root), $BpDispatchLog::RETENTION_KEEP + 1,
       'D5: the store is trimmed to keep + the live record just written');
    like($err, qr/retention pruned \d+ record\(s\)/, 'D5: and says so, once, on stderr');
}

# ===========================================================================
# E. The constants, and the cross-plugin duplication they depend on.
# ===========================================================================
{
    cmp_ok($BpDispatchLog::RETENTION_KEEP, '<', $BpDispatchLog::RETENTION_HIGH_WATER,
           'E1: keep is below the high-water mark, or the pass would run on every start');
    cmp_ok($BpDispatchLog::RETENTION_KEEP, '<', $BpDispatchLog::READER_CAP,
           'E2: keep is below the READER cap -- Decision 2: the panel goes blank at 512, '
         . 'so sizing to the 2000 writer cap would leave the visible failure in place');

  SKIP: {
        skip('RunState.pm not present from this tree', 1) unless -f $RUNSTATE;
        my $src = slurp($RUNSTATE) // '';
        my ($n) = $src =~ /\$MAX_DISPATCH_RECORDS\s*=\s*(\d+)/;
        is($n, $BpDispatchLog::READER_CAP,
           'E3: $BpDispatchLog::READER_CAP still equals $RunState::MAX_DISPATCH_RECORDS -- '
         . 'the number is duplicated across a plugin boundary on purpose, so the drift is '
         . 'guarded here rather than left to be noticed when the panel goes blank');
    }
}

# ===========================================================================
# F. The hook's over-cap path. Source-level, and labelled as such: exercising
#    track-dispatch.sh end to end needs a live Claude Code hook payload, so what
#    is checked here is that the branch calls the prune at all -- the behaviour
#    of that prune is covered above.
# ===========================================================================
{
  SKIP: {
        skip('track-dispatch.sh not present', 3) unless -f $HOOK;
        my $src = slurp($HOOK) // '';
        my ($branch) = $src =~ /-gt 2000 \]; then(.*?)\n          fi/s;
        ok(defined $branch, 'F1: the over-cap branch is still recognisable in the hook');
      SKIP: {
            skip('over-cap branch not found', 2) unless defined $branch;
            like($branch, qr/bp-dispatch-log\.pl"?\s+prune\b/,
                 'F2: over cap the hook RUNS THE PRUNE -- standing aside alone was the one-way '
               . 'door: past 2000 it stopped calling the only thing that could shrink the store');
            like($branch, qr/retention-alarm\.log/,
                 'F3: and leaves a line saying the dispatch went unrecorded');
        }
    }
}

done_testing();
