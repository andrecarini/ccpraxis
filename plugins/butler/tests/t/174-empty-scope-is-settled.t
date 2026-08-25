#!/usr/bin/env perl
# Two writer/reader defects that together let the director ask an UNANSWERABLE
# question and then block the driver's stop on it. Both observed live on
# 2026-08-25, on this machine, in that order.
#
# ---------------------------------------------------------------------------
# PART 1 (reader) — need-order over ZERO candidates.
#
# `_cmd_next`'s B2 branch fires whenever no order is recorded, and it emits
#     {"action":"need-order","candidates":[...]}
# with whatever `resolve_scope` returned -- INCLUDING the empty list. That
# prompt cannot be answered: `record-order` refuses an empty argument list
# ("at least one blueprint name required"), so the session has no way to
# satisfy it, and every subsequent `next` re-emits it.
#
# It is not merely a stall. gate-drive-loop.sh allows a driver's turn to end
# only for action `done` or `pause`; `need-order` is neither, so the stop is
# BLOCKED and the driver is told to "do the next thing NOW" over zero
# blueprints. Meanwhile B2 calls keepawake_apply('active'), holding the
# machine awake for a run that contains no work at all.
#
# Reproduced exactly: blueprints/ held only _archive/, so @candidates was
# empty, and the driver could not end its turn.
#
# The correct report is `done` -- "every in-scope blueprint is done-or-parked"
# is vacuously true of an empty scope -- together with keep-awake SETTLED.
#
# ---------------------------------------------------------------------------
# PART 2 (writer) — record-order persists anything, including a flag.
#
# `_cmd_record_order` validates OMISSIONS exhaustively (it refuses an order
# that drops a blueprint still holding non-terminal packages) and validated
# INCLUSIONS not at all. Every element of @argv was written straight into
# order.json as a blueprint name.
#
# This machine's real order.json, written by an earlier session:
#     {"order":["--order","tui-operator-feedback"],"recorded_at":1787159942}
#
# The failure is SILENT, which is why it survived: the B3 walk looks for a
# blueprint literally named "--order", finds no blueprint.md, and
# blueprint_settled({},{},0) is trivially TRUE -- so the bogus entry reports
# itself settled and the walk moves on. That is the same false-settled class
# t/130 fixed from the READER side (pruning dead names out of order.json);
# this is the WRITER side, which is how the dead name got in.
#
# ---------------------------------------------------------------------------
# VACUITY GUARDS
#   * Part 1 pairs the empty-scope assertion with a POSITIVE control: a scope
#     holding one genuinely pending blueprint must STILL produce need-order.
#     A fix that returns `done` unconditionally passes the first and fails the
#     control.
#   * Part 1 asserts keep-awake was actuated as SETTLED, not merely that the
#     action string changed -- an implementation that reports done while
#     leaving the machine awake fixes the gate and not the defect.
#   * Part 2 pairs its rejection assertion with a POSITIVE control: a real
#     blueprint name must still be accepted and written. It also asserts
#     order.json was NOT created by the rejected call, so "refuse" means
#     refuse rather than warn-and-write.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $SCRIPT = "$Bin/../../scripts/bp-drive-next.pl";
require $SCRIPT;

my $NOW = 1_830_297_600;
my $J = JSON::PP->new->canonical;

sub write_file {
    my ($p, $c) = @_;
    (my $d = $p) =~ s{[\\/][^\\/]+$}{};
    make_path($d) unless -d $d;
    open my $fh, '>:raw', $p or die "write $p: $!";
    print $fh $c; close $fh;
}
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return ''; local $/; my $c = <$fh>; close $fh; $c }

sub mk_bp_dir {
    my ($data, $name, $pkgs) = @_;
    my $bp = "$data/blueprints/$name";
    make_path("$bp/packages");
    my $md = "# $name\n\n## Package status\n\n"
           . "| pkg | deliverable | depends_on | model | status |\n"
           . "|-----|-------------|------------|-------|--------|\n";
    for my $p (@$pkgs) {
        $md .= "| $p->{key} | thing | - | sonnet | $p->{status} |\n";
    }
    write_file("$bp/blueprint.md", $md);
    for my $p (@$pkgs) {
        write_file("$bp/packages/$p->{key}.md",
            "---\npackage: $p->{key}\nblueprint: $name\nstatus: $p->{status}\n"
          . "model: sonnet\nmax_turns: 80\nwrite_set: bp/$name/$p->{key}/\n"
          . "test_paths: bp/$name/$p->{key}/\nlast_updated: 2028-01-01T00:00:00Z\n---\n\n# $p->{key}\n");
    }
    return $bp;
}

# Records every keep-awake actuation so the test can assert the SIDE EFFECT,
# not just the printed action.
my @KEEPAWAKE;

sub run_director {
    my ($argv, $opts) = @_;
    $opts //= {};
    $opts->{now}                  //= sub { $NOW };
    $opts->{verdict}              //= sub { { action => 'ok' } };
    $opts->{spawn}                //= sub { push @KEEPAWAKE, 'spawn' };
    $opts->{kill_pid}             //= sub { push @KEEPAWAKE, 'kill' };
    $opts->{powershell_available} //= sub { 1 };
    BpDrive::run($argv, $opts);
}

# STDOUT/STDERR are redirected to real temp FILES, never to in-memory scalars:
# Git-for-Windows perl fails that with "Bad file descriptor", surfacing as a
# bare "Died at ... line N". Same shape as t/130.
sub capture_run {
    my ($argv, $opts) = @_;
    my ($ofh, $opath) = File::Temp::tempfile('t174-outXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $epath) = File::Temp::tempfile('t174-errXXXXXX', TMPDIR => 1); close $efh;
    open my $oldout, '>&STDOUT' or die "dup STDOUT: $!";
    open my $olderr, '>&STDERR' or die "dup STDERR: $!";
    open STDOUT, '>:raw', $opath or do { open STDOUT, '>&', $oldout; die "reopen STDOUT: $!" };
    open STDERR, '>:raw', $epath or do { open STDERR, '>&', $olderr; die "reopen STDERR: $!" };
    $| = 1;
    my $rc  = eval { run_director($argv, $opts) };
    my $err = $@;
    open STDOUT, '>&', $oldout or die "restore STDOUT: $!"; close $oldout;
    open STDERR, '>&', $olderr or die "restore STDERR: $!"; close $olderr;
    my $out  = do { open my $r, '<:raw', $opath or die "read out: $!"; local $/; my $x = <$r>; close $r; defined $x ? $x : '' };
    my $eout = do { open my $r, '<:raw', $epath or die "read err: $!"; local $/; my $x = <$r>; close $r; defined $x ? $x : '' };
    unlink $opath, $epath;
    die $err if $err;
    return ($rc, $out, $eout);
}

# ===========================================================================
# PART 1a - THE REPRO: blueprints/ exists but holds nothing orderable.
# ===========================================================================
{
    my $data = tempdir(CLEANUP => 1);
    # The exact live shape: a blueprints/ dir containing only _archive/, which
    # has no blueprint.md of its own and so matches no candidate.
    make_path("$data/blueprints/_archive/some-finished-initiative");
    write_file("$data/blueprints/_archive/some-finished-initiative/blueprint.md", "# archived\n");

    @KEEPAWAKE = ();
    my ($rc, $out, $err) = capture_run(['next', '--scope', 'all'], { data_dir => $data });

    is($rc, 0, 'P1a: next exits 0 over an empty scope');
    my $d = eval { $J->decode($out) };
    ok(defined $d, 'P1a: stdout is one parseable JSON action') or diag($out);

    isnt(($d->{action} // ''), 'need-order',
        'P1a: action is NOT need-order over zero candidates (fails today: exactly this fires)')
        or diag($out);
    is(($d->{action} // ''), 'done',
        'P1a: an empty scope is reported settled - "done" is vacuously true of zero blueprints')
        or diag($out);

    # The side effect, not just the string: an empty scope must SETTLE
    # keep-awake. B2 called keepawake_apply('active'), which is how a run with
    # no work in it held the machine awake.
    ok(!grep({ $_ eq 'spawn' } @KEEPAWAKE),
        'P1a: keep-awake is not armed for a scope with no work in it')
        or diag("keepawake actuations: @KEEPAWAKE");

    my $log = slurp("$data/.drive-solo/run.md");
    like($log, qr/DONE \(nothing in scope/,
        'P1a: the empty-scope decision is recorded in run.md, not taken silently');
}

# ===========================================================================
# PART 1b - THE BOUNDARY, asserted so the fix above cannot creep past it.
#
# A MISSING blueprints/ directory is deliberately NOT an empty scope: it is a
# hard error, because it nearly always means the data dir resolved to the
# wrong place, and silently reporting `done` for a mis-resolved root would
# hide that. An EMPTY blueprints/ (P1a) is a genuine answer to a
# correctly-resolved root; an ABSENT one is a question about the root itself.
#
# Pinned here because the two look identical from inside `_cmd_next` -- both
# yield zero candidates -- and the natural over-generalisation of P1a's fix is
# to swallow this error too.
# ===========================================================================
{
    my $data = tempdir(CLEANUP => 1);
    @KEEPAWAKE = ();
    my ($rc, $out, $err) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    isnt($rc, 0, 'P1b: a MISSING blueprints/ dir stays a hard error, not a silent done');
    like($err, qr{no blueprints/},
        'P1b: and the error still explains that the data dir may have mis-resolved');
    unlike(($out // ''), qr/"action"/,
        'P1b: no action is printed for an unresolvable root');
}

# ===========================================================================
# PART 1b2 - MALFORMED IS NOT EMPTY, and this is the dangerous direction.
#
# Candidate discovery requires blueprint.md, so a directory under blueprints/
# that HAS package ledgers but no blueprint.md is silently skipped and arrives
# at the empty-scope branch looking exactly like "nothing is there".
#
# Reporting `done` over it is a FALSE-SETTLED bug, not a cosmetic one:
# bp-watchdog.pl treats `done` as absolute ("The director reports no remaining
# work. Do not re-arm."), so a ledger sitting at status: running would be
# declared settled and the run's dead-man's switch disarmed on top of it.
# 95-watchdog.t's own fixture is precisely this shape -- packages/p1.md with
# no blueprint.md -- and it went red the moment the empty-scope fix landed
# without this distinction. Pinned here so the two cases can never re-merge.
# ===========================================================================
{
    my $data = tempdir(CLEANUP => 1);
    make_path("$data/blueprints/half-created/packages");
    write_file("$data/blueprints/half-created/packages/p1.md",
        "---\npackage: p1\nstatus: running\n---\n\nbody\n");

    @KEEPAWAKE = ();
    my ($rc, $out, $err) = capture_run(['next', '--scope', 'all'], { data_dir => $data });

    unlike(($out // ''), qr/"action"\s*:\s*"done"/,
        'P1b2: a blueprints/ dir with packages but no blueprint.md is NOT reported settled')
        or diag($out);
    isnt($rc, 0, 'P1b2: it is a hard error about the tree, not an action about the work');
    like($err, qr/half-created/, 'P1b2: and the error names the malformed directory');
    ok(!grep({ $_ eq 'spawn' } @KEEPAWAKE),
        'P1b2: no keep-awake is armed for a tree that cannot be driven');
}

# ===========================================================================
# PART 1c - POSITIVE CONTROL. One real, pending blueprint and no order:
# need-order is the CORRECT report and must still fire. A fix that returns
# `done` whenever no order exists would pass 1a/1b and fail here.
# ===========================================================================
{
    my $data = tempdir(CLEANUP => 1);
    mk_bp_dir($data, 'real-bp', [{ key => 'p1', status => 'pending' }]);

    @KEEPAWAKE = ();
    my ($rc, $out) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    is($rc, 0, 'P1c: next exits 0');
    my $d = eval { $J->decode($out) };
    is(($d->{action} // ''), 'need-order',
        'P1c: CONTROL - a non-empty scope with no order still asks for one')
        or diag($out);
    is_deeply(($d->{candidates} // []), ['real-bp'],
        'P1c: CONTROL - and names the candidate it wants ordered');
}

# ===========================================================================
# PART 2a - record-order REFUSES a name that is not a blueprint.
# Uses the literal string from this machine's corrupted order.json.
# ===========================================================================
{
    my $data = tempdir(CLEANUP => 1);
    mk_bp_dir($data, 'tui-operator-feedback', [{ key => 'p1', status => 'pending' }]);

    my ($rc, $out, $err) = capture_run(
        ['record-order', '--order', 'tui-operator-feedback'], { data_dir => $data });

    isnt($rc, 0, 'P2a: record-order refuses a flag as a blueprint name (fails today: it is stored)')
        or diag("out=$out err=$err");
    like($err, qr/--order/,
        'P2a: and the refusal names the offending argument');
    ok(!-e "$data/.drive-solo/order.json",
        'P2a: refuse means refuse - order.json is not written at all')
        or diag(slurp("$data/.drive-solo/order.json"));
}

# ===========================================================================
# PART 2b - POSITIVE CONTROL: a real blueprint name is still accepted and
# written. A fix that refuses everything passes 2a and fails here.
# ===========================================================================
{
    my $data = tempdir(CLEANUP => 1);
    mk_bp_dir($data, 'tui-operator-feedback', [{ key => 'p1', status => 'pending' }]);

    my ($rc, $out, $err) = capture_run(
        ['record-order', 'tui-operator-feedback'], { data_dir => $data });

    is($rc, 0, 'P2b: CONTROL - a real blueprint name is accepted') or diag("err=$err");
    my $order = eval { $J->decode(slurp("$data/.drive-solo/order.json")) };
    is_deeply(($order->{order} // []), ['tui-operator-feedback'],
        'P2b: CONTROL - and is what gets persisted');
}

# ===========================================================================
# PART 2c - a name that is merely MISSPELLED (no flag involved) is refused
# too. The defect is "unvalidated inclusion", not "flags specifically".
# ===========================================================================
{
    my $data = tempdir(CLEANUP => 1);
    mk_bp_dir($data, 'real-bp', [{ key => 'p1', status => 'pending' }]);

    my ($rc, $out, $err) = capture_run(
        ['record-order', 'real-bp', 'reel-bp'], { data_dir => $data });

    isnt($rc, 0, 'P2c: a misspelled blueprint name is refused, not silently ordered');
    like($err, qr/reel-bp/, 'P2c: and the refusal names it');
    ok(!-e "$data/.drive-solo/order.json", 'P2c: nothing is persisted');
}

done_testing();
