#!/usr/bin/env perl
# platform: windows
# Companion oracle for bp-drive-next.pl's project-level in-flight set
# (package 11, hook-continuity-remake). Covers spec AC-1..AC-12 for
# inflight.json: concurrent hand-out behind BUTLER_CONCURRENCY=1, the load/
# repair/prune cycle, the inflight.lock critical section, and byte-identical
# switch-off behaviour. AC-13 (the sibling director-core oracle stays green)
# is verified by direct invocation, not embedded here.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Basename qw(basename);
use Fcntl qw(:flock);
use Time::HiRes qw(time);

# AC15 (08-blueprint-parks fix-batch, SF-3): pin HOME/USERPROFILE/
# ALMANAC_HOME to an isolated tempdir before any production code loads, so
# a fixture call that is ever unticketed cannot reach the operator's real
# vault (Decision 29). Pure hardening -- this file names none of these vars
# today.
BEGIN {
    my $env_pin = File::Temp::tempdir(CLEANUP => 1);
    $ENV{HOME}         = $env_pin;
    $ENV{USERPROFILE}  = $env_pin;
    $ENV{ALMANAC_HOME} = $env_pin;
}

my $SCRIPT = "$Bin/../../scripts/bp-drive-next.pl";
require $SCRIPT;

# Fixed epoch for all injected clocks (2028-01-01 00:00:00 UTC = 1830297600).
my $NOW = 1_830_297_600;

my $J = JSON::PP->new->canonical;

# ── Fixture helpers ──────────────────────────────────────────────────────────

sub write_pkg_ledger {
    my ($bp_dir, $bp_name, $key, $status, $write_set) = @_;
    open my $fh, '>:raw', "$bp_dir/packages/$key.md" or die "write ledger $key: $!";
    print $fh "---\npackage: $key\nblueprint: $bp_name\nstatus: $status\n"
             . "model: sonnet\nmax_turns: 80\nwrite_set: $write_set\n"
             . "test_paths: $write_set\nlast_updated: 2028-01-01T00:00:00Z\n---\n\n# $key\n";
    close $fh;
}

sub make_bp_dir {
    # make_bp_dir($data, $name, \@pkgs)
    # Each pkg: { key=>'p1', status=>'pending', write_set=>'x/', deps=>['p0'] }
    my ($data, $name, $pkgs) = @_;
    my $bp = "$data/blueprints/$name";
    make_path("$bp/packages");

    my $md = "# $name\n\n## Package status\n\n"
           . "| pkg | deliverable | depends_on | model | status |\n"
           . "|-----|-------------|------------|-------|--------|\n";
    for my $p (@$pkgs) {
        my $deps = (ref $p->{deps} eq 'ARRAY' && @{$p->{deps}})
                 ? join(', ', @{$p->{deps}}) : '—';
        $md .= "| $p->{key} | thing | $deps | sonnet | $p->{status} |\n";
    }
    open my $bfh, '>:raw', "$bp/blueprint.md" or die "cannot write blueprint.md: $!";
    print $bfh $md;
    close $bfh;

    for my $p (@$pkgs) {
        my $ws = $p->{write_set} // "blueprints/$name/$p->{key}/";
        write_pkg_ledger($bp, $name, $p->{key}, $p->{status}, $ws);
    }
    return $bp;
}

sub write_json {
    my ($path, $data) = @_;
    open my $fh, '>:raw', $path or die "write_json $path: $!";
    print $fh $J->encode($data);
    close $fh;
}

sub write_bp_status_fence {
    my ($bp_dir, $status, $reason) = @_;
    open my $fh, '>>:raw', "$bp_dir/blueprint.md" or die "append fence $bp_dir/blueprint.md: $!";
    print $fh "\n```\nstatus: $status\n";
    print $fh "parked_reason: $reason\n" if defined $reason;
    print $fh "```\n";
    close $fh;
}

sub write_raw {
    my ($path, $text) = @_;
    open my $fh, '>:raw', $path or die "write_raw $path: $!";
    print $fh $text;
    close $fh;
}

sub read_json {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/; my $txt = <$fh>; close $fh;
    eval { $J->decode($txt) };
}

sub read_file {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    local $/; my $r = <$fh>; close $fh; $r // '';
}

# ── run() / capture harness (drive-next.t idiom, never STDOUT-onto-scalar) ──

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
    my ($ofh, $opath) = tempfile('t18-outXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $epath) = tempfile('t18-errXXXXXX', TMPDIR => 1); close $efh;
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

# Sets $ENV{CCPRAXIS_DATA_DIR} for the duration of one run() call only (spec
# §4: "no data_dir opt needed"). `local` on a hash-element restores it when
# this sub returns, so it never leaks into the next scenario.
sub run_next {
    my ($data, $argv, $opts) = @_;
    local $ENV{CCPRAXIS_DATA_DIR} = $data;
    return capture_run($argv, $opts);
}

sub decode_line {
    my ($out) = @_;
    (my $line = $out) =~ s/\n\z//;
    return eval { $J->decode($line) };
}

sub arrf {
    # Safe array-ref accessor: never dereferences an undef/non-hash/non-array
    # value, so a not-yet-implemented feature (missing inflight.json, a
    # different action shape) produces a failing assertion rather than a
    # fatal "Can't use an undefined value as an ARRAY reference" that would
    # kill the rest of the file.
    my ($h, $key) = @_;
    $key //= 'packages';
    return (ref $h eq 'HASH' && ref $h->{$key} eq 'ARRAY') ? $h->{$key} : [];
}

sub ledger_prefix {
    # <L>/blueprints/<bp>/packages/<pkg>.md where <L> = basename($data)
    my ($data, $bp, $pkg) = @_;
    my $b = $data; $b =~ s{[\\/]+$}{};
    my $L = basename($b);
    return "$L/blueprints/$bp/packages/$pkg.md";
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-1 & AC-6: switch on, two disjoint ready packages both handed out and
# both in the set; schema; `since` frozen once set, `updated_at` follows NOW.
# ═══════════════════════════════════════════════════════════════════════════
my ($data1, $dsdir1);
{
    $data1 = tempdir(CLEANUP => 1);
    make_bp_dir($data1, 'bpx', [
        { key => 'p1-a', status => 'pending', write_set => 'a/' },
        { key => 'p2-b', status => 'pending', write_set => 'b/' },
        { key => 'p3-c', status => 'pending', write_set => 'a/sub/' },
    ]);
    $dsdir1 = "$data1/.drive-solo";
    make_path($dsdir1);
    write_json("$dsdir1/order.json", { order => ['bpx'], recorded_at => $NOW });

    local $ENV{BUTLER_CONCURRENCY} = '1';

    my $NOW2 = $NOW + 50;
    my ($rc1, $out1) = run_next($data1, ['next', '--scope', 'all'], { now => sub { $NOW } });
    is($rc1, 0, 'AC-1: switch-on call 1 exits 0');
    my $a1 = decode_line($out1);
    is($a1->{action}, 'run-package', 'AC-1: call 1 action is run-package');
    is($a1->{package}, 'p1-a', 'AC-1: call 1 hands out p1-a');

    ok(-e "$dsdir1/inflight.lock", 'AC-10: .drive-solo/inflight.lock exists after any next call');

    my $set1 = read_json("$dsdir1/inflight.json");
    ok(defined $set1, 'AC-1: inflight.json is valid JSON after call 1');
    is_deeply([map { $_->{package} } @{ arrf($set1) }], ['p1-a'],
        'AC-1: set holds exactly p1-a after call 1');

    my ($rc2, $out2) = run_next($data1, ['next', '--scope', 'all'], { now => sub { $NOW2 } });
    is($rc2, 0, 'AC-1: switch-on call 2 exits 0');
    my $a2 = decode_line($out2);
    is($a2->{action}, 'run-package', 'AC-1: call 2 action is run-package');
    is($a2->{package}, 'p2-b', 'AC-1: call 2 hands out disjoint p2-b (p1-a still in flight)');

    my $set2 = read_json("$dsdir1/inflight.json");
    is_deeply([map { $_->{package} } @{ arrf($set2) }], ['p1-a', 'p2-b'],
        'AC-1 (done criterion 1): both disjoint packages appear in the set, in order');

    # AC-1 (DEL, C-2): current.json no longer exists; the director never
    # creates it, so there is nothing to read here any more.
    ok(!-e "$dsdir1/current.json", 'AC-1 (-> C-2): current.json is never created');

    # ── AC-6: schema ─────────────────────────────────────────────────────────
    is_deeply([sort keys %$set2], [qw(packages updated_at)],
        'AC-6: top-level keys are exactly {packages, updated_at}');
    for my $e (@{ arrf($set2) }) {
        is_deeply([sort keys %$e], [qw(blueprint ledger package since)],
            "AC-6: entry for $e->{package} has exactly {blueprint, ledger, package, since}");
    }
    my ($p1e) = grep { $_->{package} eq 'p1-a' } @{ arrf($set2) };
    my ($p2e) = grep { $_->{package} eq 'p2-b' } @{ arrf($set2) };
    is($p1e->{ledger}, ledger_prefix($data1, 'bpx', 'p1-a'), 'AC-6: p1-a ledger path is <L>/blueprints/bpx/packages/p1-a.md');
    is($p1e->{since}, $NOW, 'AC-6: p1-a since = NOW at the call that added it');
    is($p2e->{since}, $NOW2, 'AC-6: p2-b since = NOW at the call that added it (later clock)');
    is($set2->{updated_at}, $NOW2, 'AC-6: updated_at = the injected clock at the write');
    is($p1e->{since}, $NOW, 'AC-6: p1-a since is UNCHANGED by the second call even though NOW advanced');
    my @tmp_leftover = glob("$dsdir1/inflight.json.tmp.*");
    is(scalar(@tmp_leftover), 0, 'AC-6: no inflight.json.tmp.* survives a successful write');

    # ═══════════════════════════════════════════════════════════════════════
    # AC-2: overlapping package not handed out while its conflict is in flight
    # ═══════════════════════════════════════════════════════════════════════
    my $NOW3 = $NOW2 + 50;
    my ($rc3, $out3) = run_next($data1, ['next', '--scope', 'all'], { now => sub { $NOW3 } });
    is($rc3, 0, 'AC-2: call 3 exits 0');
    my $a3 = decode_line($out3);
    is($a3->{action}, 'in-flight', 'AC-2 (done criterion 1): overlapping p3-c is not handed out; action is in-flight');
    is($a3->{blueprint}, 'bpx', 'AC-2: in-flight blueprint is bpx');
    is_deeply([sort @{ arrf($a3) }], ['p1-a', 'p2-b', 'p3-c'], 'AC-2: packages lists every non-terminal package');
    is_deeply($a3->{running}, [], 'AC-2: running is empty (nothing marked running)');
    is_deeply([sort map { $_->{package} } @{ arrf($a3, "inflight") }], ['p1-a', 'p2-b'],
        'AC-2: the inflight key carries the two in-flight entries verbatim');

    my $set3 = read_json("$dsdir1/inflight.json");
    is_deeply([map { $_->{package} } @{ arrf($set3) }], ['p1-a', 'p2-b'],
        'AC-2: the set is unchanged by an in-flight call');
    ok(!-e "$dsdir1/current.json", 'AC-2 (DEL, C-2): current.json is still never created');

    my ($rc4, $out4) = run_next($data1, ['next', '--scope', 'all'], { now => sub { $NOW3 } });
    is($rc4, 0, 'AC-2: repeated call 4 exits 0');
    is($out4, $out3, 'AC-2: a repeated call with the same clock returns the same bytes');
    unlike($out4, qr/"action"\s*:\s*"run-package"/,
        'AC-2: the repeated call never re-issues run-package for p1-a, p2-b or p3-c');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-3: a terminal ledger leaves the set on the very next call, and p3-c is
# then handed out. B5: a `running` ledger keeps its entry.
# ═══════════════════════════════════════════════════════════════════════════
sub ac3_case {
    my ($status_word) = @_;
    my $data = tempdir(CLEANUP => 1);
    my $bp = make_bp_dir($data, 'bpx', [
        { key => 'p1-a', status => 'pending', write_set => 'a/' },
        { key => 'p2-b', status => 'pending', write_set => 'b/' },
        { key => 'p3-c', status => 'pending', write_set => 'a/sub/' },
    ]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW });

    local $ENV{BUTLER_CONCURRENCY} = '1';
    run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW } });      # hands p1-a
    run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW + 10 } }); # hands p2-b

    write_pkg_ledger($bp, 'bpx', 'p1-a', $status_word, 'a/');

    my ($rc, $out) = run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW + 20 } });
    is($rc, 0, "AC-3($status_word): exits 0");
    my $act = decode_line($out);
    is($act->{action}, 'run-package', "AC-3($status_word): run-package fires once p1-a is terminal");
    is($act->{package}, 'p3-c', "AC-3($status_word) (done criterion 1): p3-c handed out once p1-a leaves");

    my $set = read_json("$dsdir/inflight.json");
    is_deeply([sort map { $_->{package} } @{ arrf($set) }], ['p2-b', 'p3-c'],
        "AC-3($status_word): p1-a removed from the set on that very next call");
}
ac3_case('done');
ac3_case('dropped');
ac3_case('blocked');
ac3_case('parked');

{   # B5: running does not remove the entry
    my $data = tempdir(CLEANUP => 1);
    my $bp = make_bp_dir($data, 'bpx', [
        { key => 'p1-a', status => 'pending', write_set => 'a/' },
        { key => 'p2-b', status => 'pending', write_set => 'b/' },
        { key => 'p3-c', status => 'pending', write_set => 'a/sub/' },
    ]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW });

    local $ENV{BUTLER_CONCURRENCY} = '1';
    run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW } });
    run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW + 10 } });

    write_pkg_ledger($bp, 'bpx', 'p1-a', 'running', 'a/');

    my ($rc, $out) = run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW + 20 } });
    is($rc, 0, 'AC-3(B5): exits 0');
    my $act = decode_line($out);
    is($act->{action}, 'in-flight', 'AC-3(B5): a running p1-a keeps blocking p3-c, so no hand-out');
    is_deeply($act->{running}, ['p1-a'], 'AC-3(B5): running lists p1-a');

    my $set = read_json("$dsdir/inflight.json");
    is_deeply([sort map { $_->{package} } @{ arrf($set) }], ['p1-a', 'p2-b'],
        'AC-3(B5): a running ledger does NOT remove its entry');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-4 (B6): the set survives a new session id, with no BP_* env carried over,
# and mentions no session anywhere.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $data = tempdir(CLEANUP => 1);
    my $bp = make_bp_dir($data, 'bpx', [
        { key => 'p1-a', status => 'pending', write_set => 'a/' },
        { key => 'p2-b', status => 'pending', write_set => 'b/' },
        { key => 'p3-c', status => 'pending', write_set => 'a/sub/' },
    ]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW });

    local $ENV{BUTLER_CONCURRENCY} = '1';

    {
        local $ENV{CLAUDE_CODE_SESSION_ID} = 'sess-a';
        run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW } });
        run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW + 10 } });
    }

    my ($rc3, $out3);
    {
        local %ENV = %ENV;
        delete $ENV{$_} for grep { /^BP_/ } keys %ENV;
        local $ENV{CLAUDE_CODE_SESSION_ID} = 'sess-b';
        ($rc3, $out3) = run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW + 20 } });
    }
    is($rc3, 0, 'AC-4: sess-b call exits 0');
    my $act3 = decode_line($out3);
    is($act3->{action}, 'in-flight', 'AC-4 (done criterion 1): the set survives a new session id');
    is_deeply([sort map { $_->{package} } @{ arrf($act3, "inflight") }], ['p1-a', 'p2-b'],
        'AC-4: reproduces the same in-flight result under a new session id');

    my $raw_after3 = read_file("$dsdir/inflight.json");
    unlike($raw_after3, qr/session/i, 'AC-4: no session mention anywhere in inflight.json (after sess-b call)');

    write_pkg_ledger($bp, 'bpx', 'p1-a', 'done', 'a/');
    my ($rc4, $out4);
    {
        local $ENV{CLAUDE_CODE_SESSION_ID} = 'sess-c';
        ($rc4, $out4) = run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW + 30 } });
    }
    is($rc4, 0, 'AC-4: sess-c call exits 0');
    my $act4 = decode_line($out4);
    is($act4->{action}, 'run-package', 'AC-4: sess-c call removes terminal p1-a and hands p3-c');
    is($act4->{package}, 'p3-c', 'AC-4: p3-c is the handed package');

    my $raw_final = read_file("$dsdir/inflight.json");
    unlike($raw_final, qr/session/i, 'AC-4: still no session mention anywhere in inflight.json');
    my $set_final = read_json("$dsdir/inflight.json");
    ok(!(grep { $_ eq 'session' } map { keys %$_ } @{ arrf($set_final) }),
        'AC-4: no entry key is a session field');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-5 (batch C, spec 16-cutover C-1, reason SW): the switch is gone --
# BUTLER_CONCURRENCY unset, '0', 'true', '' or '1' all give the SAME
# concurrent-hand-out result. Two disjoint ready packages are both handed out
# and both land in the set, regardless of the variable's value.
# ═══════════════════════════════════════════════════════════════════════════
for my $conc_value (undef, '0', 'true', '', '1') {
    my $label = defined $conc_value ? "'$conc_value'" : 'unset';
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bpx', [
        { key => 'p1-a', status => 'pending', write_set => 'a/' },
        { key => 'p2-b', status => 'pending', write_set => 'b/' },
        { key => 'p3-c', status => 'pending', write_set => 'a/sub/' },
    ]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW });

    local $ENV{BUTLER_CONCURRENCY};
    if (defined $conc_value) { $ENV{BUTLER_CONCURRENCY} = $conc_value; }
    else                     { delete $ENV{BUTLER_CONCURRENCY}; }

    my ($rc1, $out1) = run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW } });
    is($rc1, 0, "SW(conc=$label): call 1 exits 0");
    my $a1 = decode_line($out1);
    is($a1->{action}, 'run-package', "SW(conc=$label): call 1 hands out p1-a");
    is($a1->{package}, 'p1-a', "SW(conc=$label): call 1 package is p1-a");

    my ($rc2, $out2) = run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW + 37 } });
    is($rc2, 0, "SW(conc=$label): call 2 exits 0");
    my $a2 = decode_line($out2);
    is($a2->{action}, 'run-package', "SW(conc=$label) (-> C-1): a SECOND disjoint ready package is handed "
        . 'regardless of BUTLER_CONCURRENCY\'s value');
    is($a2->{package}, 'p2-b', "SW(conc=$label): call 2 hands the disjoint p2-b, not a re-issue of p1-a");

    my $set = read_json("$dsdir/inflight.json");
    is(scalar(@{ arrf($set) }), 2, "SW(conc=$label): both disjoint packages land in the set");
    is_deeply([sort map { $_->{package} } @{ arrf($set) }], ['p1-a', 'p2-b'],
        "SW(conc=$label): the set holds exactly p1-a and p2-b");
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-7 (B11): cross-blueprint disjointness — bpy/q1 overlaps bpx's in-flight
# p1-a and is skipped; bpy/q2 is disjoint and handed instead.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bpx', [
        { key => 'p1-a', status => 'pending', write_set => 'a/' },
    ]);
    make_bp_dir($data, 'bpy', [
        { key => 'q1', status => 'pending', write_set => 'a/x/' },
        { key => 'q2', status => 'pending', write_set => 'z/' },
    ]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bpx', 'bpy'], recorded_at => $NOW });

    local $ENV{BUTLER_CONCURRENCY} = '1';
    my ($rc1, $out1) = run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW } });
    is($rc1, 0, 'AC-7: call 1 exits 0');
    my $a1 = decode_line($out1);
    is($a1->{blueprint}, 'bpx', 'AC-7: call 1 hands out from bpx');
    is($a1->{package}, 'p1-a', 'AC-7: call 1 hands out p1-a');

    my ($rc2, $out2) = run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW + 10 } });
    is($rc2, 0, 'AC-7: call 2 exits 0');
    my $a2 = decode_line($out2);
    is($a2->{action}, 'run-package', 'AC-7 (done criterion 1): a disjoint package from a DIFFERENT blueprint is handed');
    is($a2->{blueprint}, 'bpy', 'AC-7: call 2 hands out from bpy');
    is($a2->{package}, 'q2', 'AC-7: q2 (disjoint) is handed, never q1 (overlaps bpx/p1-a)');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-8 (batch C, spec 16-cutover 1.3 departure #10, reason DEL): a corrupt
# file (B12) and a missing file (B13) are rebuilt from SCRATCH -- the
# current.json seeding path is removed outright (not kept as a migration
# path), so a pre-existing current.json is simply ignored and the first
# ready package (sorted) is handed instead of whatever current.json named.
# ═══════════════════════════════════════════════════════════════════════════
{   # B12: corrupt inflight.json, current.json present but IGNORED
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bpx', [
        { key => 'p1-a', status => 'pending', write_set => 'a/' },
        { key => 'p2-b', status => 'pending', write_set => 'b/' },
    ]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW });
    my $R = $NOW - 500;
    write_json("$dsdir/current.json", { blueprint => 'bpx', package => 'p1-a', recorded_at => $R });
    write_raw("$dsdir/inflight.json", "{not json");

    my ($rc, $out) = run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW } });
    is($rc, 0, 'AC-8(B12): exits 0 despite a corrupt inflight.json');
    my $act = decode_line($out);
    is($act->{action}, 'run-package', 'AC-8(B12) (DEL, C-9): a fresh ready package is handed -- current.json is never consulted');
    is($act->{package}, 'p1-a', 'AC-8(B12) (DEL): p1-a is handed as the first ready package, not "seeded"');

    my $run_md = read_file("$dsdir/run.md");
    like($run_md, qr/WARN malformed JSON in .*inflight\.json/, 'AC-8(B12): run.md gains the existing malformed-JSON WARN line');

    my $set = read_json("$dsdir/inflight.json");
    ok(defined $set, 'AC-8(B12): inflight.json is rewritten as valid JSON');
    my ($p1e) = grep { $_->{package} eq 'p1-a' } @{ arrf($set) };
    ok(defined $p1e, 'AC-8(B12): p1-a is present as the freshly-handed entry');
    is($p1e->{since}, $NOW, 'AC-8(B12) (DEL): since is the CURRENT call\'s clock, not current.json\'s stale recorded_at');
}

{   # B13a: missing inflight.json, current.json present but IGNORED
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bpx', [
        { key => 'p1-a', status => 'pending', write_set => 'a/' },
        { key => 'p2-b', status => 'pending', write_set => 'b/' },
    ]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW });
    my $R = $NOW - 300;
    write_json("$dsdir/current.json", { blueprint => 'bpx', package => 'p1-a', recorded_at => $R });

    my ($rc, $out) = run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW } });
    is($rc, 0, 'AC-8(B13a): exits 0 with no prior inflight.json');
    my $act = decode_line($out);
    is($act->{action}, 'run-package', 'AC-8(B13a) (DEL): p1-a handed as the first ready package');
    is($act->{package}, 'p1-a', 'AC-8(B13a) (DEL): p1-a handed');

    my $set = read_json("$dsdir/inflight.json");
    my ($p1e) = grep { $_->{package} eq 'p1-a' } @{ arrf($set) };
    ok(defined $p1e, 'AC-8(B13a): p1-a present');
    is($p1e->{since}, $NOW, 'AC-8(B13a) (DEL, C-9): since = this call\'s clock, current.json\'s recorded_at is never consulted');
}

{   # B13b: missing inflight.json, no current.json, no hand-out this call
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bpx', [
        { key => 'p1-a', status => 'pending', write_set => 'a/' },
    ]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    # deliberately no order.json -> need-order, no run-package

    my ($rc, $out) = run_next($data, ['next', '--scope', 'bpx'], { now => sub { $NOW } });
    is($rc, 0, 'AC-8(B13b): exits 0');
    my $act = decode_line($out);
    is($act->{action}, 'need-order', 'AC-8(B13b): a call with nothing to seed and no run-package is need-order');
    ok(!-e "$dsdir/inflight.json", 'AC-8(B13b): no inflight.json is created when nothing was seeded and nothing was handed');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-9: robustness — a write failure is non-fatal (B14); invalid entries are
# dropped on load (B15); missing-ledger and parked-blueprint entries are
# pruned (B16).
# ═══════════════════════════════════════════════════════════════════════════
{   # B14: inflight.json exists as a directory
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bpx', [
        { key => 'p1-a', status => 'pending', write_set => 'a/' },
    ]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW });
    make_path("$dsdir/inflight.json"); # a directory, not a file

    local $ENV{BUTLER_CONCURRENCY} = '1';
    my ($rc, $out) = run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW } });
    is($rc, 0, 'AC-9(B14): exits 0 despite an unwritable inflight.json');
    my $act = decode_line($out);
    is($act->{action}, 'run-package', 'AC-9(B14): the action is unaffected by the write failure');
    is($act->{package}, 'p1-a', 'AC-9(B14): p1-a still handed');

    ok(!-e "$dsdir/current.json", 'AC-9(B14) (DEL, C-2): current.json is never written');
    my $run_md = read_file("$dsdir/run.md");
    like($run_md, qr/WARN inflight\.json write failed/, 'AC-9(B14): run.md gains the write-failure WARN line');
}

{   # B15: invalid entries (bad name) are dropped on load
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bpx', [
        { key => 'p1-a', status => 'pending', write_set => 'a/' },
    ]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW });
    write_json("$dsdir/inflight.json", { packages => [
        { blueprint => 'bpx', package => 'p1-a', ledger => ledger_prefix($data, 'bpx', 'p1-a'), since => $NOW - 10 },
        { blueprint => '../x', package => 'p2-b', ledger => 'bogus', since => $NOW - 10 },
    ], updated_at => $NOW - 10 });

    local $ENV{BUTLER_CONCURRENCY} = '1';
    my ($rc, $out) = run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW } });
    is($rc, 0, 'AC-9(B15): exits 0');
    my $act = decode_line($out);
    is($act->{action}, 'in-flight', 'AC-9(B15): p1-a is already in flight and pending, so no re-hand-out');

    my $set = read_json("$dsdir/inflight.json");
    is_deeply([map { $_->{package} } @{ arrf($set) }], ['p1-a'],
        'AC-9(B15): the invalid entry is dropped; the valid one survives');
    is($set->{packages}[0]{since}, $NOW - 10, 'AC-9(B15): the surviving entry keeps its original since');
}

{   # B16: missing-ledger and parked-blueprint entries are removed
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bpx', [
        { key => 'p1-a', status => 'pending', write_set => 'a/' },
    ]);
    my $bpy = make_bp_dir($data, 'bpy', [
        { key => 'q1', status => 'pending', write_set => 'q/' },
    ]);
    # Authored directly in blueprint.md (spec 08-blueprint-parks §2.1), not
    # parks.json: the director's only source of parkedness is the
    # blueprint's own status now.
    write_bp_status_fence($bpy, 'parked', 'stale');
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bpx', 'bpy'], recorded_at => $NOW });
    write_json("$dsdir/inflight.json", { packages => [
        { blueprint => 'bpx', package => 'p1-a', ledger => ledger_prefix($data, 'bpx', 'p1-a'), since => $NOW - 20 },
        { blueprint => 'ghost-bp', package => 'p9', ledger => ledger_prefix($data, 'ghost-bp', 'p9'), since => $NOW - 20 },
        { blueprint => 'bpy', package => 'q1', ledger => ledger_prefix($data, 'bpy', 'q1'), since => $NOW - 20 },
    ], updated_at => $NOW - 20 });

    local $ENV{BUTLER_CONCURRENCY} = '1';
    my ($rc, $out) = run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW } });
    is($rc, 0, 'AC-9(B16): exits 0');

    my $set = read_json("$dsdir/inflight.json");
    is_deeply([map { $_->{package} } @{ arrf($set) }], ['p1-a'],
        'AC-9(B16): the ghost (missing ledger) and the parked-blueprint entry are both removed');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-10 (B17): lock timeout degrades with a WARN and the normal action.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bpx', [
        { key => 'p1-a', status => 'pending', write_set => 'a/' },
    ]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW });

    my $lockfile = "$dsdir/inflight.lock";
    open my $h1, '>>', $lockfile or die "open lock h1: $!";
    open my $h2, '>>', $lockfile or die "open lock h2: $!";
    my $h1_locked = flock($h1, LOCK_EX | LOCK_NB);
    my $h2_conflicts = !flock($h2, LOCK_EX | LOCK_NB);
    flock($h2, LOCK_UN);
    close $h2;

  SKIP: {
        skip('AC-10: two handles opened by ONE process do not conflict under flock on this platform', 4)
            unless $h1_locked && $h2_conflicts;

        local $ENV{BUTLER_CONCURRENCY} = '1';
        my $t0 = time();
        my ($rc, $out) = run_next($data, ['next', '--scope', 'all'],
            { now => sub { $NOW }, inflight_lock_timeout => 1 });
        my $elapsed = time() - $t0;

        is($rc, 0, 'AC-10(B17): exits 0 despite the lock being held elsewhere');
        ok($elapsed >= 0.8, "AC-10(B17): waited roughly the 1s timeout (elapsed=${elapsed}s)");
        my $act = decode_line($out);
        is($act->{action}, 'run-package', 'AC-10(B17): the normal action still fires after the lock degrades');

        my $run_md = read_file("$dsdir/run.md");
        like($run_md, qr/WARN inflight\.lock/, 'AC-10(B17): run.md gains a WARN inflight.lock line');
    }
    flock($h1, LOCK_UN);
    close $h1;
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-11 (B18) (batch C, spec 16-cutover C-2, reason DEL): a pre-existing
# current.json is left byte-identical by `stop` -- the director never reads
# or removes it any more -- and inflight.json entries are left exactly as
# they were (entries leave only via prune).
# ═══════════════════════════════════════════════════════════════════════════
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bpx', [
        { key => 'p1-a', status => 'pending', write_set => 'a/' },
    ]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW });
    write_json("$dsdir/current.json", { blueprint => 'bpx', package => 'p1-a', recorded_at => $NOW - 10 });
    write_json("$dsdir/inflight.json", { packages => [
        { blueprint => 'bpx', package => 'p1-a', ledger => ledger_prefix($data, 'bpx', 'p1-a'), since => $NOW - 10 },
    ], updated_at => $NOW - 10 });
    my $before = read_file("$dsdir/inflight.json");
    my $current_before = read_file("$dsdir/current.json");

    my ($rc, $out) = run_next($data, ['next', '--scope', 'all'], {
        now      => sub { $NOW },
        verdict  => sub { { action => 'pause-token', until_epoch => undef, reason => 'token' } },
        refresh  => sub { { action => 'pause-auth', detail => 'refresh returned 400' } },
    });
    is($rc, 0, 'AC-11(B18): exits 0');
    my $act = decode_line($out);
    is($act->{action}, 'stop', 'AC-11(B18): a failed token refresh stops the run');

    is(read_file("$dsdir/current.json"), $current_before,
        'AC-11(B18) (DEL, C-2): a pre-existing current.json is left byte-identical -- the director never removes it');
    my $after = read_file("$dsdir/inflight.json");
    is($after, $before, 'AC-11: inflight.json entries are untouched by stop');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-12: --help documents inflight.json and BUTLER_CONCURRENCY, and keeps
# every string drive-next.t's own --help AC asserts.
# ═══════════════════════════════════════════════════════════════════════════
{
    my ($rc, $out) = capture_run(['--help'], {});
    is($rc, 0, 'AC-12: --help exits 0');

    like($out, qr/inflight\.json/, 'AC-12: --help documents inflight.json');
    unlike($out, qr/BUTLER_CONCURRENCY/,
        'AC-12 (DEL, batch C): --help no longer documents BUTLER_CONCURRENCY -- concurrent hand-out is unconditional');
    unlike($out, qr/current\.json/,
        'AC-12 (DEL, batch C): --help no longer documents current.json -- it is gone');

    like($out, qr/next\s+--scope/, 'AC-12: --help still contains "next --scope" subcommand');
    like($out, qr/record-order/,   'AC-12: --help still contains "record-order" subcommand');
    like($out, qr/park/,           'AC-12: --help still contains "park" subcommand');
    like($out, qr/need-order/,     'AC-12: --help still contains need-order action shape');
    like($out, qr/run-package/,    'AC-12: --help still contains run-package action shape');
    like($out, qr/blueprint-done/, 'AC-12: --help still contains blueprint-done action shape');
    like($out, qr/pause.*usage/s,  'AC-12: --help still contains pause/usage action shape');
    like($out, qr/pause.*token/s,  'AC-12: --help still contains pause/token action shape');
    like($out, qr/"action"\s*:\s*"done"/, 'AC-12: --help still contains done action shape');
    like($out, qr/ok.*pause-usage.*pause-token.*unavailable/s,
        'AC-12: --help still contains the governor verdict shape');
    like($out, qr/until_epoch/,    'AC-12: --help still documents until_epoch');
    like($out, qr/bp-usage-gate/,  'AC-12: --help still names bp-usage-gate.pl');
    like($out, qr/\.drive-solo/,   'AC-12: --help still documents .drive-solo/');
}

# ═══════════════════════════════════════════════════════════════════════════
# R9 — fix-batch regression tests (hook-continuity-remake, package 11).
# Traceability: review.md M1/M3, redteam.md H1/M2/M3
# (reports/11-director-inflight-set/{review,redteam}.md). Written against the
# spec + the driver's fix-batch decision recorded in the ledger's attempt log,
# BEFORE the fix lands, so each case must fail for a missing behaviour, not a
# harness bug. Never weakens or removes an existing AC-1..AC-12 assertion.
# ═══════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────
# R9-RM1 (review M1): prune must run even when load() was already dirty (here,
# because an invalid entry was dropped). A `done` entry alongside the invalid
# one must still be pruned on THIS call, and the next ready package handed out.
# ─────────────────────────────────────────────────────────────────────────────
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bpx', [
        { key => 'p1-a', status => 'done',    write_set => 'a/' },
        { key => 'p3-c', status => 'pending', write_set => 'a/sub/' },
    ]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW });
    # One valid (but now-terminal) entry, one entry with an invalid blueprint
    # name — load_inflight() drops the second and marks dirty=1 for THAT
    # reason alone; prune must not be skipped as a result.
    write_json("$dsdir/inflight.json", { packages => [
        { blueprint => 'bpx',   package => 'p1-a', ledger => ledger_prefix($data, 'bpx', 'p1-a'), since => $NOW - 10 },
        { blueprint => '../x',  package => 'bad',  ledger => 'bogus',                             since => $NOW - 10 },
    ], updated_at => $NOW - 10 });

    local $ENV{BUTLER_CONCURRENCY} = '1';
    my ($rc, $out) = run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW } });
    is($rc, 0, 'R9-RM1: exits 0');
    my $act = decode_line($out);
    is($act->{action}, 'run-package', 'R9-RM1: prune runs despite the dirty load, so p3-c is no longer blocked');
    is($act->{package}, 'p3-c', 'R9-RM1: p3-c is handed out once the done p1-a is pruned on this same call');

    my $set = read_json("$dsdir/inflight.json");
    ok(!(grep { $_->{package} eq 'p1-a' } @{ arrf($set) }),
        'R9-RM1: the done p1-a entry does not survive in the written set');
}

# ─────────────────────────────────────────────────────────────────────────────
# R9-H1 (red-team H1 / review M2): switch on. A package whose LEDGER status is
# `running` but which is ABSENT from inflight.json must still count as in
# flight for the disjointness check — both within one blueprint and across
# two in-scope blueprints.
# ─────────────────────────────────────────────────────────────────────────────
{   # same-blueprint: p1-a is running but untracked; p3-c overlaps it (a/ vs a/sub/)
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bpx', [
        { key => 'p1-a', status => 'running', write_set => 'a/' },
        { key => 'p3-c', status => 'pending', write_set => 'a/sub/' },
    ]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW });
    # Deliberately no inflight.json at all: p1-a's running status is the ONLY
    # record of it being in flight.

    local $ENV{BUTLER_CONCURRENCY} = '1';
    my ($rc, $out) = run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW } });
    is($rc, 0, 'R9-H1(same-bp): exits 0');
    my $act = decode_line($out);
    is($act->{action}, 'in-flight',
        'R9-H1(same-bp): the overlapping ready p3-c is NOT handed out while untracked-but-running p1-a blocks it');
    unlike($out, qr/"action"\s*:\s*"run-package"\s*,\s*"package"\s*:\s*"p3-c"|"package"\s*:\s*"p3-c".*"action"\s*:\s*"run-package"/,
        'R9-H1(same-bp): p3-c never appears as a handed-out package in this stdout');
    ok(!($act->{action} eq 'run-package' && $act->{package} eq 'p1-a'),
        'R9-H1(same-bp): the running package itself (p1-a) is never re-handed');
}

{   # cross-blueprint: bpa/r1 is running but untracked; bpb/q1 overlaps it
    # (shared/ vs shared/sub/) — must be blocked across the blueprint boundary.
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bpa', [
        { key => 'r1', status => 'running', write_set => 'shared/' },
    ]);
    make_bp_dir($data, 'bpb', [
        { key => 'q1', status => 'pending', write_set => 'shared/sub/' },
    ]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bpa', 'bpb'], recorded_at => $NOW });
    # Deliberately no inflight.json: bpa/r1's running status is the only
    # record of it being in flight, and it must still block bpb/q1.

    local $ENV{BUTLER_CONCURRENCY} = '1';
    my ($rc, $out) = run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW } });
    is($rc, 0, 'R9-H1(cross-bp): exits 0');
    my $act = decode_line($out);
    unlike($out, qr/"package"\s*:\s*"q1"/,
        'R9-H1(cross-bp): bpb/q1 is NEVER handed out while bpa/r1 (running, untracked) overlaps it');
    ok(!($act->{action} eq 'run-package' && $act->{package} eq 'r1'),
        'R9-H1(cross-bp): the running package itself (bpa/r1) is never re-handed');
}

# ─────────────────────────────────────────────────────────────────────────────
# R9-RM3 (review M3): a non-contention flock/lock failure must proceed within
# about 2s, not the full timeout, with exactly one WARN.
#
# PROVEN here: the "cannot open the lock file" branch (spec §2.4's "or an
# unopenable lock"), reproduced hermetically by replacing inflight.lock with a
# directory. This already returns immediately in the pre-fix code too — it is
# included as a REGRESSION PIN for the fix-batch (M3's real target, a `flock`
# call that returns false for a reason OTHER than contention, e.g. ENOLCK/
# EINVAL/ENOSYS), so the fix must not accidentally start retrying this branch
# as if it were contention.
#
# NOT PROVEN: a genuine non-contention `flock()` failure. bp-drive-next.pl is
# `require`d once at the top of this file, so its `_acquire_inflight_lock`
# already has `flock` bound to `CORE::flock` at compile time; there is no
# `flock_fn`-style seam in $opts to substitute a fake failing flock, and a
# process-wide `*CORE::GLOBAL::flock` override made now would not apply
# retroactively to code already compiled. The reviewer's own finding says the
# same ("the reviewer has not measured it"). This case is left exactly as
# risky as the spec found it; only the "unopenable" half is exercised.
# ─────────────────────────────────────────────────────────────────────────────
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bpx', [
        { key => 'p1-a', status => 'pending', write_set => 'a/' },
    ]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW });
    make_path("$dsdir/inflight.lock"); # a directory, not a file -> open() fails

    local $ENV{BUTLER_CONCURRENCY} = '1';
    my $t0 = time();
    # Default timeout (30s) deliberately NOT shortened via inflight_lock_timeout,
    # so a pass here means the call did not fall back to polling for the timeout.
    my ($rc, $out) = run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW } });
    my $elapsed = time() - $t0;
    is($rc, 0, 'R9-RM3: exits 0 despite an unopenable lock file');
    ok($elapsed < 2, "R9-RM3: proceeds within ~2s, not the 30s default timeout (elapsed=${elapsed}s)");
    my $act = decode_line($out);
    is($act->{action}, 'run-package', 'R9-RM3: the normal action still fires');
    is($act->{package}, 'p1-a', 'R9-RM3: p1-a is still handed');

    my $run_md = read_file("$dsdir/run.md");
    like($run_md, qr/WARN inflight\.lock/, 'R9-RM3: run.md gains exactly one WARN inflight.lock line');
    my @warn_lines = grep { /WARN inflight\.lock/ } split /\n/, $run_md;
    is(scalar(@warn_lines), 1, 'R9-RM3: exactly one WARN inflight.lock line, not a retry storm');
}

# ─────────────────────────────────────────────────────────────────────────────
# R9-TM2 (red-team M2): the inflight.lock must NOT be held while the usage/
# governor verdict is fetched. Hermetic in-process probe: from inside the
# verdict seam (called synchronously, still within _cmd_next's own call),
# open a SECOND handle on the real inflight.lock path and attempt a
# non-blocking exclusive flock. If the director's own lock handle is still
# held at that point (the bug), the probe cannot acquire it. Reuses the
# same-process flock-contention capability the file already probes for
# AC-10; skipped with a stated reason if this platform's flock does not
# make two in-process handles contend.
# ─────────────────────────────────────────────────────────────────────────────
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bpx', [
        { key => 'p1-a', status => 'pending', write_set => 'a/' },
    ]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW });

    my $problock = "$dsdir/_r9tm2_probe.lock";
    open my $ph1, '>>', $problock or die "open ph1: $!";
    open my $ph2, '>>', $problock or die "open ph2: $!";
    my $ph1_locked   = flock($ph1, LOCK_EX | LOCK_NB);
    my $ph2_conflict = !flock($ph2, LOCK_EX | LOCK_NB);
    flock($ph1, LOCK_UN) if $ph1_locked;
    close $ph1; close $ph2;
    unlink $problock;

  SKIP: {
        skip('R9-TM2: two handles opened by ONE process do not conflict under flock on this platform', 2)
            unless $ph1_locked && $ph2_conflict;

        my $probe_locked;
        my ($rc, $out) = run_next($data, ['next', '--scope', 'all'], {
            now     => sub { $NOW },
            verdict => sub {
                my $lockfile = "$dsdir/inflight.lock";
                open my $probe_fh, '>>', $lockfile or die "open probe fh: $!";
                $probe_locked = flock($probe_fh, LOCK_EX | LOCK_NB);
                flock($probe_fh, LOCK_UN) if $probe_locked;
                close $probe_fh;
                return { action => 'ok' };
            },
        });
        is($rc, 0, 'R9-TM2: exits 0');
        ok($probe_locked,
            'R9-TM2: a second handle can take inflight.lock WHILE the verdict fetch runs -- the director does '
          . 'not hold its own lock across the usage/governor verdict call (red-team M2). Proven only in-process, '
          . 'synchronously, inside the verdict seam; a real cross-process race under network latency is not '
          . 'exercised here.');
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# R9-TM3 (red-team M3): a set entry whose blueprint's blueprint.md is missing,
# or whose blueprint status is `drafting`, is pruned.
# ─────────────────────────────────────────────────────────────────────────────
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bpx', [
        { key => 'p1-a', status => 'running', write_set => 'a/' },
        { key => 'p2-b', status => 'pending', write_set => 'b/' },
    ]);

    # ghostbp: the PACKAGE ledger file exists, but the blueprint itself has no
    # blueprint.md at all (distinct from B16, which is about a missing ledger
    # file for the package itself).
    make_path("$data/blueprints/ghostbp/packages");
    write_pkg_ledger("$data/blueprints/ghostbp", 'ghostbp', 'gp1', 'pending', 'z/');

    # draftbp: blueprint.md exists, and its status is `drafting`.
    make_path("$data/blueprints/draftbp/packages");
    open my $dfh, '>:raw', "$data/blueprints/draftbp/blueprint.md" or die "write draftbp/blueprint.md: $!";
    print $dfh "---\nstatus: drafting\n---\n\n# draftbp\n\n## Package status\n\n"
             . "| pkg | deliverable | depends_on | model | status |\n"
             . "|-----|-------------|------------|-------|--------|\n"
             . "| dz1 | thing | - | sonnet | pending |\n";
    close $dfh;
    write_pkg_ledger("$data/blueprints/draftbp", 'draftbp', 'dz1', 'pending', 'q/');

    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW });
    write_json("$dsdir/inflight.json", { packages => [
        { blueprint => 'bpx',      package => 'p1-a', ledger => ledger_prefix($data, 'bpx', 'p1-a'),      since => $NOW - 30 },
        { blueprint => 'ghostbp',  package => 'gp1',  ledger => ledger_prefix($data, 'ghostbp', 'gp1'),   since => $NOW - 30 },
        { blueprint => 'draftbp',  package => 'dz1',  ledger => ledger_prefix($data, 'draftbp', 'dz1'),   since => $NOW - 30 },
    ], updated_at => $NOW - 30 });

    local $ENV{BUTLER_CONCURRENCY} = '1';
    my ($rc, $out) = run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW } });
    is($rc, 0, 'R9-TM3: exits 0');

    my $set = read_json("$dsdir/inflight.json");
    is_deeply([sort map { $_->{package} } @{ arrf($set) }], ['p1-a', 'p2-b'],
        'R9-TM3: the missing-blueprint.md entry (ghostbp/gp1) and the drafting-blueprint entry '
      . '(draftbp/dz1) are both pruned; only the live bpx entries remain');
}

done_testing();
