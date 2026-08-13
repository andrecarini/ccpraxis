#!/usr/bin/env perl
# e04-honest-terminal-reporting, AC4 (-> DC4): an order.json entry naming a
# blueprint absent from disk must be pruned in memory before the B3 walk --
# never reaching a false {"action":"blueprint-done",...} (or {"action":"done"})
# for work that was never touched this run. Spec §2.4/§3(4)/§4 AC4/§7 edge
# case 4.
#
# TODAY'S WRONG REPORT (confirmed live by reading bp-drive-next.pl's
# _cmd_next: $order is read at ~:565 and handed DIRECTLY to B2/B2a/B3 with no
# prune step anywhere in between -- grepped clean for "ORDER-PRUNE" and any
# `%exists`/`@all_bps` filter on $order before the walk): an order.json
# listing BOTH a dead blueprint name (its directory/blueprint.md no longer on
# disk) and a live, correctly-covered one is walked in full. The dead name is
# visited FIRST (array order), its (empty) meta trivially "has no
# progressable work" (BpDrive::blueprint_settled({},{},0) == 1), it was never
# parked/announced -- so `next` emits a false
# {"action":"blueprint-done","blueprint":"<dead-name>","pending":[...]}
# for a blueprint that was never touched this run, EXACTLY the shape spec
# §2.4 names as the residual gap (its own worked example:
# order=["archived-bp","real-bp"], candidates=["real-bp"]).
#
# Written BLIND to the eventual fix (no ORDER-PRUNE log line, no %exists
# filter step exists anywhere in the file today).
#
# VACUITY GUARDS:
#   - the primary repro asserts BOTH that action is not "blueprint-done" for
#     the dead name (negative) AND separately greps run.md for an ORDER-PRUNE
#     line naming it (positive) -- a fix that merely changes WHICH wrong
#     action fires (e.g. silently skipping without logging) would fail the
#     positive half.
#   - the "genuinely finished" scenario is a paired POSITIVE control: after
#     pruning, if the real remaining work in the order is ACTUALLY settled
#     and announced, {"action":"done"} is the CORRECT report and must still
#     fire -- proving the fix does not overcorrect into never reporting
#     completion at all.
#   - order.json on disk is asserted BYTE-UNCHANGED after `next` (spec §7 edge
#     case 4: "in-memory only ... order.json on disk is never rewritten by
#     next") -- catches an implementation that "fixes" the order by rewriting
#     the file instead of pruning in memory each call.
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
sub write_json { my ($p, $d) = @_; write_file($p, $J->encode($d)); }
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return ''; local $/; my $c = <$fh>; close $fh; $c }

sub mk_bp_dir {
    # mk_bp_dir($data, $name, \@pkgs)
    my ($data, $name, $pkgs) = @_;
    my $bp = "$data/blueprints/$name";
    make_path("$bp/packages");
    my $md = "# $name\n\n## Package status\n\n"
           . "| pkg | deliverable | depends_on | model | status |\n"
           . "|-----|-------------|------------|-------|--------|\n";
    for my $p (@$pkgs) {
        $md .= "| $p->{key} | thing | — | sonnet | $p->{status} |\n";
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

sub run_director {
    my ($argv, $opts) = @_;
    $opts //= {};
    $opts->{now}                  //= sub { $NOW };
    $opts->{verdict}              //= sub { { action => 'ok' } };
    $opts->{spawn}                //= sub { };
    $opts->{kill_pid}             //= sub { };
    $opts->{powershell_available} //= sub { 0 };
    BpDrive::run($argv, $opts);
}
sub capture_run {
    my ($argv, $opts) = @_;
    my ($ofh, $opath) = File::Temp::tempfile('t130-outXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $epath) = File::Temp::tempfile('t130-errXXXXXX', TMPDIR => 1); close $efh;
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

# ═══════════════════════════════════════════════════════════════════════════
# Scenario A — the spec's OWN worked example: order=["archived-bp","real-bp"],
# real-bp exists on disk with a still-pending package. archived-bp does NOT
# exist on disk at all.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $data = tempdir(CLEANUP => 1);
    mk_bp_dir($data, 'real-bp', [{ key => 'p1', status => 'pending' }]);
    my $order_json = { order => ['archived-bp', 'real-bp'], recorded_at => $NOW - 1000 };
    write_json("$data/.drive-solo/order.json", $order_json);
    my $order_bytes_before = slurp("$data/.drive-solo/order.json");

    my ($rc, $out, $err) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    is($rc, 0, 'AC4/A: next exits 0');
    my $decoded = eval { $J->decode($out) };
    ok(defined $decoded, 'AC4/A: stdout is one parseable JSON action') or diag($out);

    my $wrongly_archived = defined $decoded
        && $decoded->{action} eq 'blueprint-done'
        && ($decoded->{blueprint} // '') eq 'archived-bp';
    ok(!$wrongly_archived,
        "AC4/A: action is NOT blueprint-done for 'archived-bp' (fails today: exactly this false report fires)")
        or diag($out);

    my $run_log = slurp("$data/.drive-solo/run.md");
    like($run_log, qr/ORDER-PRUNE.*archived-bp/,
        'AC4/A: run.md logs the prune, naming archived-bp (no such log line exists at all today)');

    is(slurp("$data/.drive-solo/order.json"), $order_bytes_before,
        'AC4/A: order.json on disk is byte-unchanged (prune is in-memory only, spec §7 edge case 4)');

    my $announced = eval { $J->decode(slurp("$data/.drive-solo/announced.json") || '{}') } // {};
    my @ann_list = (ref $announced eq 'HASH' && ref $announced->{announced} eq 'ARRAY') ? @{ $announced->{announced} } : ();
    ok(!(grep { $_ eq 'archived-bp' } @ann_list),
        'AC4/A: archived-bp is never written to announced.json (it was never actually settled by this run)');
}

# ═══════════════════════════════════════════════════════════════════════════
# Scenario B — POSITIVE control: after pruning the dead name, the REMAINING
# real blueprint genuinely IS done and already announced -> {"action":"done"}
# must still fire (a fix must not overcorrect into perpetual need-order/never-
# done). This also demonstrates the CORRECT terminal report the false one in
# Scenario A was standing in for.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $data = tempdir(CLEANUP => 1);
    mk_bp_dir($data, 'real-bp', [{ key => 'p1', status => 'done' }]);
    write_json("$data/.drive-solo/order.json", { order => ['archived-bp', 'real-bp'], recorded_at => $NOW - 1000 });
    write_json("$data/.drive-solo/announced.json", { announced => ['real-bp'] });

    my ($rc, $out) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    is($rc, 0, 'AC4/B: next exits 0');
    my $decoded = eval { $J->decode($out) };
    ok(defined $decoded, 'AC4/B: stdout is one parseable JSON action') or diag($out);
    is($decoded->{action}, 'done',
        'AC4/B: once the dead name is pruned, a genuinely-finished remaining order correctly reports done '
      . '(fails today for the WRONG reason: it reports blueprint-done for archived-bp first instead)')
        if defined $decoded;
}

# ═══════════════════════════════════════════════════════════════════════════
# Scenario C — control: pruning must not disturb the ALREADY-CORRECT B2a
# "scope extends order" mechanism. order names only the dead blueprint; a
# real, uncovered candidate exists on disk -> need-order must still fire
# (this already works today; asserted so a fix cannot regress it).
# ═══════════════════════════════════════════════════════════════════════════
{
    my $data = tempdir(CLEANUP => 1);
    mk_bp_dir($data, 'real-bp', [{ key => 'p1', status => 'pending' }]);
    write_json("$data/.drive-solo/order.json", { order => ['archived-bp'], recorded_at => $NOW - 1000 });

    my ($rc, $out) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    is($rc, 0, 'AC4/C: next exits 0');
    my $decoded = eval { $J->decode($out) };
    is($decoded->{action}, 'need-order',
        'AC4/C control: order pruned to empty (only a dead name) -> need-order, never done/blueprint-done')
        if defined $decoded;
}

done_testing();
