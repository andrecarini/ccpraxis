#!/usr/bin/env perl
# A7 watcher: bp-wait-for-decision.pl — the reporter's token-free blocking watcher
# over runs/needs-you/. Part 1 exhausts the pure decision core (decision_id /
# parse_seen / fresh_decisions). Part 2 drives the blocking wait_loop with injected
# now/sleep/scan seams (immediate-return, block-then-return, seen-filtering,
# timeout, announce-ordering, infinite-block) — no real sleeping, no real claude.
# Part 3 exercises the real scan() against a temp dir (malformed/dotfile/missing).
# Part 4 smoke-tests the CLI exit codes + JSON output + dir resolution.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $script = "$Bin/../../scripts/bp-wait-for-decision.pl";
require $script;

my $J = JSON::PP->new->canonical;

# ===========================================================================
# PART 1 — pure decisions
# ===========================================================================

# ---- decision_id: filename is the stable identity --------------------------
is(BpWait::decision_id('solo--1a2b3c.json'),          'solo--1a2b3c', 'decision_id: strips .json');
is(BpWait::decision_id('/a/b/runs/needs-you/solo--1a2b3c.json'), 'solo--1a2b3c', 'decision_id: strips unix dir');
is(BpWait::decision_id('C:\\runs\\needs-you\\solo--1a2b3c.json'), 'solo--1a2b3c', 'decision_id: strips windows dir');
is(BpWait::decision_id('pkg--DEAD.JSON'),             'pkg--DEAD',    'decision_id: .JSON case-insensitive');
is(BpWait::decision_id(undef),                         '',            'decision_id: undef -> empty');

# ---- parse_seen: the reporter's already-announced set ----------------------
is_deeply(BpWait::parse_seen(undef), {}, 'parse_seen: undef -> empty set');
is_deeply(BpWait::parse_seen(''),    {}, 'parse_seen: empty -> empty set');
is_deeply(BpWait::parse_seen('a--1, b--2 ,, c--3 '),
          { 'a--1'=>1, 'b--2'=>1, 'c--3'=>1 },
          'parse_seen: trims, splits, drops empties');

# ---- fresh_decisions: filter by seen, order oldest-first -------------------
{
    my @d = (
        { id=>'b--2', created_at=>200 },
        { id=>'a--1', created_at=>100 },
        { id=>'c--3', created_at=>300 },
    );
    my $f = BpWait::fresh_decisions(\@d, {});
    is_deeply([map { $_->{id} } @$f], ['a--1','b--2','c--3'],
        'fresh_decisions: none seen -> all, ordered by created_at');

    my $f2 = BpWait::fresh_decisions(\@d, { 'a--1'=>1, 'c--3'=>1 });
    is_deeply([map { $_->{id} } @$f2], ['b--2'],
        'fresh_decisions: drops already-announced ids');

    is_deeply(BpWait::fresh_decisions(\@d, { 'a--1'=>1,'b--2'=>1,'c--3'=>1 }), [],
        'fresh_decisions: all seen -> empty');
    is_deeply(BpWait::fresh_decisions([], {}), [], 'fresh_decisions: empty queue -> empty');
    is_deeply(BpWait::fresh_decisions(undef, undef), [], 'fresh_decisions: undef args -> empty');
}
# tie-break on id when created_at equal (deterministic announce order)
{
    my @d = ( { id=>'z--9', created_at=>50 }, { id=>'a--9', created_at=>50 } );
    my $f = BpWait::fresh_decisions(\@d, {});
    is_deeply([map { $_->{id} } @$f], ['a--9','z--9'], 'fresh_decisions: equal created_at tie-broken by id');
}

# ===========================================================================
# PART 2 — wait_loop with injected now/sleep/scan seams
# ===========================================================================

# A scriptable seam harness: scan() returns the next snapshot from @$snaps each
# call (sticking on the last); now()/sleep() drive a fake clock; sleeps recorded.
sub harness {
    my (%o) = @_;
    my $snaps = $o{snaps};
    my @sleeps;
    my $clock = 1000;
    my $i = 0;
    return (
        scans   => \$i,
        sleeps  => \@sleeps,
        opts    => {
            seen    => $o{seen} || {},
            timeout => $o{timeout},
            poll    => $o{poll},
            now     => sub { $clock },
            sleep   => sub { push @sleeps, $_[0]; $clock += $_[0]; },
            scan    => sub { my $s = $snaps->[$i < $#$snaps ? $i : $#$snaps]; $i++; return $s; },
        },
    );
}

# W1: a fresh decision already present -> return immediately, never sleep.
{
    my %h = harness(snaps => [ [ { id=>'solo--1', created_at=>10 } ] ]);
    my $r = BpWait::wait_loop($h{opts});
    is($r->{status}, 'decision', 'W1: returns a decision');
    is(scalar @{$r->{decisions}}, 1, 'W1: one fresh decision');
    is($r->{decisions}[0]{id}, 'solo--1', 'W1: the right decision');
    is(scalar @{$h{sleeps}}, 0, 'W1: never slept (decision already waiting)');
    is(${$h{scans}}, 1, 'W1: scanned exactly once');
}

# W2: empty, empty, then a decision -> blocks two polls, then returns it.
{
    my %h = harness(snaps => [ [], [], [ { id=>'solo--7', created_at=>20 } ] ], poll => 5);
    my $r = BpWait::wait_loop($h{opts});
    is($r->{status}, 'decision', 'W2: eventually returns a decision');
    is($r->{decisions}[0]{id}, 'solo--7', 'W2: the decision that appeared');
    is_deeply($h{sleeps}, [5,5], 'W2: slept twice at the poll cadence before it appeared');
}

# W3: the only queued decision is already-seen -> never re-announced (times out).
{
    my %h = harness(
        snaps   => [ [ { id=>'solo--1', created_at=>10 } ] ],
        seen    => { 'solo--1'=>1 },
        timeout => 30, poll => 10,
    );
    my $r = BpWait::wait_loop($h{opts});
    is($r->{status}, 'timeout', 'W3: an already-announced decision is not re-announced');
    cmp_ok($r->{waited}, '>=', 30, 'W3: waited past the timeout');
}

# W4: nothing ever appears -> timeout with the elapsed time; bounded sleeps.
{
    my %h = harness(snaps => [ [] ], timeout => 30, poll => 10);
    my $r = BpWait::wait_loop($h{opts});
    is($r->{status}, 'timeout', 'W4: times out when nothing fresh appears');
    cmp_ok($r->{waited}, '>=', 30, 'W4: waited at least the timeout');
    # checks at t=0(<30, sleep), t=10(<30, sleep), t=20(<30, sleep), t=30(>=30, return)
    is_deeply($h{sleeps}, [10,10,10], 'W4: slept exactly to the deadline, no further');
}

# W5: several queued, one already seen -> fresh set excludes seen, oldest-first.
{
    my %h = harness(
        snaps => [ [
            { id=>'c--3', created_at=>300 },
            { id=>'a--1', created_at=>100 },
            { id=>'b--2', created_at=>200 },
        ] ],
        seen => { 'b--2'=>1 },
    );
    my $r = BpWait::wait_loop($h{opts});
    is_deeply([map { $_->{id} } @{$r->{decisions}}], ['a--1','c--3'],
        'W5: returns all fresh (minus seen), ordered oldest-first');
}

# W6: timeout 0 = block forever -> does not time out even past a would-be deadline.
{
    my %h = harness(snaps => [ [], [], [], [ { id=>'late--1', created_at=>9 } ] ],
                    timeout => 0, poll => 1000);
    my $r = BpWait::wait_loop($h{opts});
    is($r->{status}, 'decision', 'W6: timeout=0 blocks indefinitely until a decision (never times out)');
    is($r->{decisions}[0]{id}, 'late--1', 'W6: returns the eventual decision');
}

# ===========================================================================
# PART 3 — real scan() against a temp needs-you dir (the I/O seam)
# ===========================================================================

sub write_file { my ($p,$c)=@_; open my $fh,'>:raw',$p or die "$p: $!"; print $fh $c; close $fh; }

{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = "$root/needs-you";
    make_path($dir);

    write_file("$dir/alpha--aa11.json",
        $J->encode({ package=>'alpha', blueprint=>'bp', kind=>'stuck-package',
                     question=>'Re-scope alpha?', context=>'looped', created_at=>111 }));
    write_file("$dir/beta--bb22.json",
        $J->encode({ package=>'beta', blueprint=>'bp', kind=>'harvest-failure',
                     question=>'Harvest failed', context=>'criteria', created_at=>222 }));
    write_file("$dir/.cursor.json", '{"not":"a decision"}');   # dotfile: ignored
    write_file("$dir/gamma--cc33.json", '{ this is not json ');  # malformed: skipped
    write_file("$dir/notes.txt", 'ignore me');                   # non-json: skipped

    my $got = BpWait::scan($dir);
    is(scalar @$got, 2, 'scan: only the two well-formed decisions (dotfile/malformed/txt skipped)');
    my %by = map { $_->{id} => $_ } @$got;
    ok($by{'alpha--aa11'}, 'scan: alpha present by id');
    is($by{'alpha--aa11'}{kind}, 'stuck-package', 'scan: alpha kind parsed');
    is($by{'alpha--aa11'}{question}, 'Re-scope alpha?', 'scan: alpha question parsed');
    is($by{'beta--bb22'}{created_at}, 222, 'scan: beta created_at parsed');
    like($by{'beta--bb22'}{path}, qr/beta--bb22\.json$/, 'scan: path recorded');

    # malformed becomes well-formed later -> picked up on the next scan (no poisoning)
    write_file("$dir/gamma--cc33.json",
        $J->encode({ package=>'gamma', blueprint=>'bp', kind=>'stuck-package',
                     question=>'?', context=>'', created_at=>333 }));
    is(scalar @{ BpWait::scan($dir) }, 3, 'scan: a half-written file is picked up once complete');
}

is_deeply(BpWait::scan("$Bin/does-not-exist-xyz"), [], 'scan: missing dir -> [] (orchestrator makes it lazily)');

# ===========================================================================
# PART 4 — CLI smoke: exit codes, JSON output, dir resolution
# ===========================================================================

# usage error when no target given
{
    my $out = `"$^X" "$script" 2>&1`;
    is($? >> 8, 2, 'CLI: no args -> exit 2 (usage)');
}

# --runs form, a fresh decision present -> exit 0 + status decision (immediate)
{
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/needs-you");
    write_file("$root/needs-you/solo--ff00.json",
        $J->encode({ package=>'solo', blueprint=>'bp', kind=>'stuck-package',
                     question=>'Decide?', context=>'x', created_at=>1 }));
    my $out = `"$^X" "$script" --runs "$root" --timeout 5 2>&1`;
    my $rc  = $? >> 8;
    is($rc, 0, 'CLI: --runs with a fresh decision -> exit 0') or diag($out);
    my $res = eval { JSON::PP->new->decode($out) };
    is($res->{status}, 'decision', 'CLI: prints status=decision');
    is($res->{decisions}[0]{package}, 'solo', 'CLI: emits the decision payload');

    # the same decision marked seen -> nothing fresh -> times out (exit 3)
    my $out2 = `"$^X" "$script" --runs "$root" --seen solo--ff00 --timeout 1 --poll 1 2>&1`;
    is($? >> 8, 3, 'CLI: an already-seen decision yields a timeout (exit 3)') or diag($out2);
    my $res2 = eval { JSON::PP->new->decode($out2) };
    is($res2->{status}, 'timeout', 'CLI: prints status=timeout when nothing fresh');
}

# blueprint + --bp-dir form resolves runs/needs-you under the bp dir
{
    my $root = tempdir(CLEANUP => 1);
    my $bpdir = "$root/bp";
    make_path("$bpdir/runs/needs-you");
    write_file("$bpdir/runs/needs-you/k--ab12.json",
        $J->encode({ package=>'k', blueprint=>'mybp', kind=>'harvest-failure',
                     question=>'?', context=>'', created_at=>2 }));
    my $out = `"$^X" "$script" mybp --bp-dir "$bpdir" --timeout 5 2>&1`;
    my $rc  = $? >> 8;
    is($rc, 0, 'CLI: blueprint + --bp-dir resolves <bpdir>/runs/needs-you') or diag($out);
    my $res = eval { JSON::PP->new->decode($out) };
    is($res->{decisions}[0]{package}, 'k', 'CLI: found the decision under the bp dir');
}

# ===========================================================================
# PART 5 — regression: red-team fixes
# ===========================================================================

# C1: poll >> timeout must NOT oversleep past the deadline (clamp to remaining).
{
    my %h = harness(snaps => [ [] ], timeout => 1, poll => 300);
    my $r = BpWait::wait_loop($h{opts});
    is($r->{status}, 'timeout', 'C1: still times out with poll >> timeout');
    is_deeply($h{sleeps}, [1], 'C1: slept only the time remaining (1), not the full poll (300)');
}

# C1b: a decision arriving right at a clamped deadline is still detected.
{
    my %h = harness(snaps => [ [], [ { id=>'edge--1', created_at=>5 } ] ], timeout => 1, poll => 300);
    my $r = BpWait::wait_loop($h{opts});
    is($r->{status}, 'decision', 'C1b: decision at the deadline is caught by the final scan');
    is($r->{decisions}[0]{id}, 'edge--1', 'C1b: the right decision');
}

# collision: two decisions with identical created_at -> both returned, stable order.
{
    my %h = harness(snaps => [ [
        { id=>'z--5', created_at=>50 },
        { id=>'a--5', created_at=>50 },
    ] ]);
    my $r = BpWait::wait_loop($h{opts});
    is_deeply([map { $_->{id} } @{$r->{decisions}}], ['a--5','z--5'],
        'collision: same created_at -> both announced, ordered by id');
}

# stale/phantom seen ids (answered+deleted long ago) never suppress a fresh one.
{
    my %h = harness(
        snaps => [ [ { id=>'fresh--1', created_at=>10 } ] ],
        seen  => { 'gone--1'=>1, 'gone--2'=>1, 'gone--3'=>1 },
    );
    my $r = BpWait::wait_loop($h{opts});
    is_deeply([map { $_->{id} } @{$r->{decisions}}], ['fresh--1'],
        'stale-seen: phantom ids ignored, the one fresh decision returned');
}

# scan: a partial mid-write JSON (valid prefix, truncated) is skipped, never crashes.
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = "$root/needs-you";
    make_path($dir);
    write_file("$dir/part--p1.json", '{"package":"sol","kind":"stuck-pa');  # truncated
    write_file("$dir/ok--o1.json",
        $J->encode({ package=>'ok', blueprint=>'bp', kind=>'stuck-package',
                     question=>'?', context=>'', created_at=>1 }));
    my $got = BpWait::scan($dir);
    is(scalar @$got, 1, 'scan: truncated mid-write JSON skipped (only the complete file)');
    is($got->[0]{id}, 'ok--o1', 'scan: the complete decision survives');
}

# CLI H1: an option whose value is itself a flag -> usage error, not silent eat.
{
    my $out = `"$^X" "$script" --runs --timeout 5 2>&1`;
    is($? >> 8, 2, 'CLI H1: --runs with a flag as its value -> exit 2');
    like($out, qr/requires a value/, 'CLI H1: explains the missing value');
}

# CLI H2: a negative / non-numeric timeout -> usage error, not a silent infinite block.
{
    my $root = tempdir(CLEANUP => 1); make_path("$root/needs-you");
    my $out = `"$^X" "$script" --runs "$root" --timeout -5 2>&1`;
    is($? >> 8, 2, 'CLI H2: negative timeout -> exit 2 (not silent infinite block)');
    my $out2 = `"$^X" "$script" --runs "$root" --timeout abc 2>&1`;
    is($? >> 8, 2, 'CLI H2: non-numeric timeout -> exit 2');
}

done_testing();
