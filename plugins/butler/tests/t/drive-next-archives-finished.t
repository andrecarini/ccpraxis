#!/usr/bin/env perl
# platform: windows
# Oracle for blueprint director-archives-finished, package 01
# (specs/01-archive-on-blueprint-done-spec.md AC1-AC9). Tests only, blind to
# the implementation of bp-drive-next.pl.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Basename qw(basename dirname);
use Cwd qw(abs_path);
use Fcntl qw(:flock);

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
my $LOADED = do { local $@; eval { require $SCRIPT }; !$@ };

my $NOW = 1_830_297_600; # fixed epoch, 2028-01-01 UTC
my $J = JSON::PP->new->canonical;

# ── fixture helpers ─────────────────────────────────────────────────────────

sub write_file {
    my ($path, $content) = @_;
    make_path(dirname($path)) unless -d dirname($path);
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh $content;
    close $fh;
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub write_json {
    my ($path, $data) = @_;
    write_file($path, $J->encode($data));
}

sub read_json {
    my ($path) = @_;
    my $txt = slurp($path);
    return undef unless defined $txt;
    return eval { $J->decode($txt) };
}

# make_bp_dir($data, $name, \@pkgs, %opts)
# Each pkg: { key=>'p1', status=>'done' }. %opts: bp_status => 'audited'|'drafting'|...
sub make_bp_dir {
    my ($data, $name, $pkgs, %opts) = @_;
    my $bp_status = $opts{bp_status} // 'audited';
    my $bp = "$data/blueprints/$name";
    make_path("$bp/packages");

    my $rows = '';
    for my $p (@$pkgs) {
        $rows .= "| $p->{key} | thing | — | sonnet |\n";
    }
    my $md = <<"MD";
# $name

\`\`\`
blueprint: $name
created: 2028-01-01
last_updated: 2028-01-01T00:00:00Z
status: $bp_status        # drafting | audited | running | done | archived
\`\`\`

## Objective

Test fixture.

## Package status

| pkg | deliverable | depends_on | model |
|-----|-------------|------------|-------|
$rows
## Harvest log

## Incidents

MD
    write_file("$bp/blueprint.md", $md);

    for my $p (@$pkgs) {
        write_file("$bp/packages/$p->{key}.md",
            "---\npackage: $p->{key}\nblueprint: $name\nstatus: $p->{status}\n"
          . "last_updated: 2028-01-01T00:00:00Z\n---\n\n# $p->{key}\n\n## Next action\n\nNone.\n");
    }
    if (exists $opts{marker}) {
        make_path("$bp/runs");
        write_file("$bp/runs/.orchestrator", $opts{marker});
    }
    return $bp;
}

sub bp_status_of {
    my ($file) = @_;
    my $c = slurp($file) // '';
    return $1 if $c =~ /^status:[ \t]*([a-z]+)/m;
    return undef;
}

# recursively list files (relative paths) under a dir, sorted
sub list_files_rel {
    my ($dir) = @_;
    my @out;
    my @stack = ($dir);
    while (my $d = shift @stack) {
        opendir(my $dh, $d) or next;
        for my $e (sort readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $full = "$d/$e";
            if (-d $full) { push @stack, $full; }
            else {
                (my $rel = $full) =~ s{^\Q$dir\E[\\/]?}{};
                $rel =~ s{\\}{/}g;
                push @out, $rel;
            }
        }
    }
    return sort @out;
}

# ── capture STDOUT/STDERR through real temp files (never in-memory scalars) ─

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
    my ($ofh, $opath) = tempfile('anf-outXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $epath) = tempfile('anf-errXXXXXX', TMPDIR => 1); close $efh;
    open my $oldout, '>&STDOUT' or die "dup STDOUT: $!";
    open my $olderr, '>&STDERR' or die "dup STDERR: $!";
    open STDOUT, '>:raw', $opath or do { open STDOUT, '>&', $oldout; die "reopen STDOUT: $!" };
    open STDERR, '>:raw', $epath or do { open STDERR, '>&', $olderr; die "reopen STDERR: $!" };
    $| = 1;
    my $rc  = eval { run_director($argv, $opts) };
    my $err = $@;
    open STDOUT, '>&', $oldout or die "restore STDOUT: $!"; close $oldout;
    open STDERR, '>&', $olderr or die "restore STDERR: $!"; close $olderr;
    my $out  = slurp($opath) // '';
    my $eout = slurp($epath) // '';
    unlink $opath, $epath;
    die $err if $err;
    return ($rc, $out, $eout);
}

sub decode_line {
    my ($out) = @_;
    chomp(my $line = $out);
    return eval { $J->decode($line) };
}

# ── fresh fixture data root per test block; never the real data dir ────────
sub fresh_data {
    my $data = tempdir(CLEANUP => 1);
    ok(index($data, '.ccpraxis-local-data') < 0,
        'fixture data root is not the real .ccpraxis-local-data');
    return $data;
}

# =============================================================================
# AC1 (DC1): settled, unblocked, single package done -> archived at emission.
# =============================================================================
{
    my $data = fresh_data();
    make_bp_dir($data, 'B', [ { key => 'p1', status => 'done' } ]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['B'], recorded_at => $NOW });

    my ($rc, $out) = capture_run(['next', '--scope', 'B'], { data_dir => $data });
    is($rc, 0, 'AC1: next exits 0');
    my $act = decode_line($out);
    ok(defined $act, 'AC1: stdout is valid JSON');
    is($act->{action}, 'blueprint-done', 'AC1: action is blueprint-done');
    is($act->{blueprint}, 'B', 'AC1: blueprint is B');
    ok(JSON::PP::is_bool($act->{archived}), 'AC1: archived is a JSON boolean');
    ok($act->{archived}, 'AC1: archived is true');
    like($act->{archive_detail} // '', qr{^archived to _archive/B},
        'AC1: archive_detail names the destination');

    ok(!-e "$data/blueprints/B", 'AC1: blueprints/B no longer exists');
    ok(-f "$data/blueprints/_archive/B/blueprint.md",
        'AC1: blueprints/_archive/B/blueprint.md exists');
    is(bp_status_of("$data/blueprints/_archive/B/blueprint.md"), 'archived',
        'AC1: the archived blueprint.md now reads status: archived');

    my $order = read_json("$dsdir/order.json");
    ok(!(grep { $_ eq 'B' } @{ $order->{order} || [] }),
        'AC1: B removed from order.json');

    my $run_md = slurp("$dsdir/run.md") // '';
    like($run_md, qr/ARCHIVE B archived/, 'AC1: run.md has ARCHIVE B archived');
    like($run_md, qr/ORDER-DROP-ARCHIVED B/, 'AC1: run.md has ORDER-DROP-ARCHIVED B');
}

# =============================================================================
# AC2 (DC2): parked or blocked package -> never archived, not all delivered.
# =============================================================================
for my $case ( { key => 'p2', status => 'parked' }, { key => 'p2', status => 'blocked' } ) {
    my $data = fresh_data();
    make_bp_dir($data, 'B', [
        { key => 'p1', status => 'done' },
        { key => $case->{key}, status => $case->{status} },
    ]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['B'], recorded_at => $NOW });

    my ($rc, $out) = capture_run(['next', '--scope', 'B'], { data_dir => $data });
    my $act = decode_line($out);
    is($act->{action}, 'blueprint-done',
        "AC2($case->{status}): action is blueprint-done");
    ok(JSON::PP::is_bool($act->{archived}) && !$act->{archived},
        "AC2($case->{status}): archived is a false JSON boolean");
    is($act->{archive_detail}, "not all delivered: p2=$case->{status}",
        "AC2($case->{status}): archive_detail names the undelivered package");

    ok(-d "$data/blueprints/B", "AC2($case->{status}): blueprints/B still present");
    ok(!-e "$data/blueprints/_archive/B", "AC2($case->{status}): no _archive/B");
    my $order = read_json("$dsdir/order.json");
    ok((grep { $_ eq 'B' } @{ $order->{order} || [] }),
        "AC2($case->{status}): order.json still names B");

    # a second next does not archive it either
    my ($rc2, $out2) = capture_run(['next', '--scope', 'B'], { data_dir => $data });
    ok(-d "$data/blueprints/B",
        "AC2($case->{status}): after a second next, B is still not archived");
}

# =============================================================================
# AC3a (DC3, in-flight): defers, then archives once the in-flight entry clears.
# =============================================================================
{
    my $data = fresh_data();
    make_bp_dir($data, 'B', [ { key => 'p1', status => 'done' } ]);
    make_bp_dir($data, 'C', [ { key => 'q1', status => 'pending' } ]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['B', 'C'], recorded_at => $NOW });
    write_json("$dsdir/inflight.json", {
        packages => [ { blueprint => 'B', package => 'p1', ledger => 'x', since => $NOW } ],
    });

    my ($rc, $out) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    my $act = decode_line($out);
    is($act->{action}, 'blueprint-done', 'AC3a: action is blueprint-done');
    ok(!$act->{archived}, 'AC3a: archived is false while in-flight');
    like($act->{archive_detail} // '', qr{^deferred: in-flight p1},
        'AC3a: archive_detail names the deferral cause');
    ok(-d "$data/blueprints/B", 'AC3a: B not moved while deferred');
    my $ann = read_json("$dsdir/announced.json");
    ok((grep { $_ eq 'B' } @{ $ann->{announced} || [] }), 'AC3a: B in announced.json');

    # clear the blocker, then a later next both archives B and returns C's work
    write_json("$dsdir/inflight.json", { packages => [] });
    my ($rc2, $out2) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    my $act2 = decode_line($out2);
    is($act2->{action}, 'run-package', 'AC3a(retry): next call returns run-package for C');
    is($act2->{blueprint}, 'C', 'AC3a(retry): blueprint is C');
    ok(-d "$data/blueprints/_archive/B", 'AC3a(retry): B is now archived');
    my $order = read_json("$dsdir/order.json");
    ok(!(grep { $_ eq 'B' } @{ $order->{order} || [] }),
        'AC3a(retry): B dropped from order.json');
    my $run_md = slurp("$dsdir/run.md") // '';
    like($run_md, qr/ARCHIVE B archived/, 'AC3a(retry): run.md logs ARCHIVE B archived');
    my @done_lines = ($run_md =~ /(BLUEPRINT-DONE B )/g);
    is(scalar @done_lines, 1, 'AC3a(retry): blueprint-done was never re-emitted for B');
}

# =============================================================================
# AC3b (DC3, live worker marker bound to one of B's ledgers).
# =============================================================================
{
    my $data = fresh_data();
    make_bp_dir($data, 'B', [ { key => 'p1', status => 'done' } ]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['B'], recorded_at => $NOW });

    make_path("$dsdir/workers");
    make_path("$dsdir/bindings");
    write_file("$dsdir/workers/T1", "toolu_T1\n");
    write_json("$dsdir/bindings/T1.json", { blueprint => 'B', package => 'p1' });

    # controls: another blueprint's marker, and a stale (181-minute-old) marker
    write_file("$dsdir/workers/T2", "toolu_T2\n");
    write_json("$dsdir/bindings/T2.json", { blueprint => 'other', package => 'x' });
    write_file("$dsdir/workers/T3", "toolu_T3\n");
    write_json("$dsdir/bindings/T3.json", { blueprint => 'B', package => 'p1' });
    my $stale_t = time() - (181 * 60);
    utime($stale_t, $stale_t, "$dsdir/workers/T3") or die "utime T3: $!";

    my ($rc, $out) = capture_run(['next', '--scope', 'B'], { data_dir => $data });
    my $act = decode_line($out);
    is($act->{action}, 'blueprint-done', 'AC3b: action is blueprint-done');
    ok(!$act->{archived}, 'AC3b: archived is false while a live worker marker is bound');
    like($act->{archive_detail} // '', qr/live worker T1/,
        'AC3b: archive_detail names the live worker');
    unlike($act->{archive_detail} // '', qr/T2/,
        'AC3b: a marker bound to another blueprint does not appear');
    unlike($act->{archive_detail} // '', qr/T3/,
        'AC3b: a stale (181-minute) marker does not appear');
    ok(-d "$data/blueprints/B", 'AC3b: B not moved while a live worker is bound');

    unlink("$dsdir/workers/T1");
    my ($rc2, $out2) = capture_run(['next', '--scope', 'B'], { data_dir => $data });
    ok(-d "$data/blueprints/_archive/B",
        'AC3b(retry): after unlinking T1, a later next archives B');
}

# =============================================================================
# AC3c (DC3, open dispatch-log entry).
# =============================================================================
{
    my $data = fresh_data();
    make_bp_dir($data, 'B', [ { key => 'p1', status => 'done' } ]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['B'], recorded_at => $NOW });

    make_path("$data/.dispatch-log");
    write_json("$data/.dispatch-log/d1.json", {
        id => 'd1', worker_type => 'bp-implementer', status => 'running',
        started_at => $NOW - 60, budget_seconds => 1800,
        blueprint => 'B', package => 'p1',
    });
    # controls: done status, stale (> 4x budget), and another blueprint
    write_json("$data/.dispatch-log/d2.json", {
        id => 'd2', worker_type => 'bp-implementer', status => 'done',
        started_at => $NOW - 60, budget_seconds => 1800,
        blueprint => 'B', package => 'p1',
    });
    write_json("$data/.dispatch-log/d3.json", {
        id => 'd3', worker_type => 'bp-implementer', status => 'running',
        started_at => $NOW - (4 * 1800 + 100), budget_seconds => 1800,
        blueprint => 'B', package => 'p1',
    });
    write_json("$data/.dispatch-log/d4.json", {
        id => 'd4', worker_type => 'bp-implementer', status => 'running',
        started_at => $NOW - 60, budget_seconds => 1800,
        blueprint => 'other', package => 'x',
    });

    my ($rc, $out) = capture_run(['next', '--scope', 'B'],
        { data_dir => $data, now => sub { $NOW } });
    my $act = decode_line($out);
    is($act->{action}, 'blueprint-done', 'AC3c: action is blueprint-done');
    ok(!$act->{archived}, 'AC3c: archived is false while an open dispatch entry exists');
    like($act->{archive_detail} // '', qr/open dispatch d1/,
        'AC3c: archive_detail names the open dispatch id');
    unlike($act->{archive_detail} // '', qr/\bd2\b/, 'AC3c: a done-status record does not appear');
    unlike($act->{archive_detail} // '', qr/\bd3\b/, 'AC3c: a stale record does not appear');
    unlike($act->{archive_detail} // '', qr/\bd4\b/, 'AC3c: a record for another blueprint does not appear');
    ok(-d "$data/blueprints/B", 'AC3c: B not moved while dispatch is open');

    write_json("$data/.dispatch-log/d1.json", {
        id => 'd1', worker_type => 'bp-implementer', status => 'done',
        started_at => $NOW - 60, budget_seconds => 1800,
        blueprint => 'B', package => 'p1',
    });
    my ($rc2, $out2) = capture_run(['next', '--scope', 'B'],
        { data_dir => $data, now => sub { $NOW } });
    ok(-d "$data/blueprints/_archive/B",
        'AC3c(retry): after marking d1 done, a later next archives B');
}

# =============================================================================
# AC4 (DC4): dropped counts as delivered.
# =============================================================================
{
    my $data = fresh_data();
    make_bp_dir($data, 'B', [
        { key => 'p1', status => 'done' },
        { key => 'p2', status => 'dropped' },
    ]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['B'], recorded_at => $NOW });

    my ($rc, $out) = capture_run(['next', '--scope', 'B'], { data_dir => $data });
    my $act = decode_line($out);
    ok($act->{archived}, 'AC4: a dropped package counts as delivered -> archived true');
    ok(-d "$data/blueprints/_archive/B", 'AC4: B is under _archive/');
}

# =============================================================================
# AC5a (DC5): real reconcile failure (pre-existing destination) -> failed,
# never blocks the run.
# =============================================================================
{
    my $data = fresh_data();
    make_bp_dir($data, 'B', [ { key => 'p1', status => 'done' } ]);
    make_bp_dir($data, 'C', [ { key => 'q1', status => 'pending' } ]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['B', 'C'], recorded_at => $NOW });

    make_path("$data/blueprints/_archive/B");
    write_file("$data/blueprints/_archive/B/sentinel.txt", "pre-existing\n");

    my ($rc, $out) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    is($rc, 0, 'AC5a: exits 0 even though the archive attempt fails');
    my $act = decode_line($out);
    is($act->{action}, 'blueprint-done', 'AC5a: action is blueprint-done');
    ok(!$act->{archived}, 'AC5a: archived is false');
    is($act->{archive_detail},
        'archive failed: _archive/B already exists (reconcile not run)',
        'AC5a: archive_detail names the reconcile failure');
    ok(-f "$data/blueprints/B/blueprint.md", 'AC5a: blueprints/B is intact');
    is(bp_status_of("$data/blueprints/B/blueprint.md"), 'audited',
        'AC5a: blueprint.md still reads audited (untouched)');
    ok(-f "$data/blueprints/_archive/B/sentinel.txt", 'AC5a: the sentinel file survives untouched');
    my $order = read_json("$dsdir/order.json");
    ok((grep { $_ eq 'B' } @{ $order->{order} || [] }), 'AC5a: order.json still names B');

    my ($rc2, $out2) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    is($rc2, 0, 'AC5a(retry): next call also exits 0');
    my $act2 = decode_line($out2);
    is($act2->{action}, 'run-package', 'AC5a(retry): returns run-package for C');
    is($act2->{blueprint}, 'C', 'AC5a(retry): blueprint is C');
    my $run_md = slurp("$dsdir/run.md") // '';
    my @fail_lines = ($run_md =~ /(ARCHIVE B failed)/g);
    is(scalar @fail_lines, 2, 'AC5a(retry): run.md gains a second ARCHIVE B failed line');
}

# =============================================================================
# AC5b (DC5): crashing reconcile via the lifecycle_script test seam.
# =============================================================================
{
    my $data = fresh_data();
    make_bp_dir($data, 'B', [ { key => 'p1', status => 'done' } ]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['B'], recorded_at => $NOW });

    my $fake = "$data/fake-lifecycle.pl";
    write_file($fake, "#!$^X\nprint \"garbage\\n\"; exit 3;\n");
    chmod 0755, $fake;

    my ($rc, $out) = capture_run(['next', '--scope', 'B'],
        { data_dir => $data, lifecycle_script => $fake });
    is($rc, 0, 'AC5b: exits 0 despite a crashing reconcile subprocess');
    my $act = decode_line($out);
    ok(!$act->{archived}, 'AC5b: archived is false');
    like($act->{archive_detail} // '', qr/^archive failed: reconcile exit 3/,
        'AC5b: archive_detail names the exit code');
    ok(-d "$data/blueprints/B", 'AC5b: B is not moved');
}

# =============================================================================
# AC6 (DC6): single-blueprint scope reaches done, never need-order, with no
# ORDER-PRUNE line -- both when unblocked and when deferred to the run-done
# sweep.
# =============================================================================
{   # (i) no blockers
    my $data = fresh_data();
    make_bp_dir($data, 'B', [ { key => 'p1', status => 'done' } ]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['B'], recorded_at => $NOW });

    my ($rc1, $out1) = capture_run(['next', '--scope', 'B'], { data_dir => $data });
    my $act1 = decode_line($out1);
    is($act1->{action}, 'blueprint-done', 'AC6(i) call1: blueprint-done');
    ok($act1->{archived}, 'AC6(i) call1: archived true');

    my ($rc2, $out2) = capture_run(['next', '--scope', 'B'], { data_dir => $data });
    my $act2 = decode_line($out2);
    is($act2->{action}, 'done', 'AC6(i) call2: done');

    my ($rc3, $out3) = capture_run(['next', '--scope', 'B'], { data_dir => $data });
    my $act3 = decode_line($out3);
    is($act3->{action}, 'done', 'AC6(i) call3: done');

    my $run_md = slurp("$dsdir/run.md") // '';
    unlike($run_md, qr/ORDER-PRUNE/, 'AC6(i): run.md contains no ORDER-PRUNE line');
}

{   # (ii) in-flight entry present and never cleared: run-done sweep archives it
    my $data = fresh_data();
    make_bp_dir($data, 'B', [ { key => 'p1', status => 'done' } ]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['B'], recorded_at => $NOW });
    write_json("$dsdir/inflight.json", {
        packages => [ { blueprint => 'B', package => 'p1', ledger => 'x', since => $NOW } ],
    });

    my ($rc1, $out1) = capture_run(['next', '--scope', 'B'], { data_dir => $data });
    my $act1 = decode_line($out1);
    is($act1->{action}, 'blueprint-done', 'AC6(ii) call1: blueprint-done');
    ok(!$act1->{archived}, 'AC6(ii) call1: deferred (archived false)');

    my ($rc2, $out2) = capture_run(['next', '--scope', 'B'], { data_dir => $data });
    my $act2 = decode_line($out2);
    is($act2->{action}, 'done', 'AC6(ii) call2: done, not need-order');
    ok(-d "$data/blueprints/_archive/B", 'AC6(ii) call2: B is under _archive/ via the run-done sweep');
    my $order = read_json("$dsdir/order.json");
    ok(!(grep { $_ eq 'B' } @{ $order->{order} || [] }),
        'AC6(ii) call2: order.json no longer names B');
    my $run_md = slurp("$dsdir/run.md") // '';
    like($run_md, qr/ARCHIVE B archived -- by the run-done sweep/,
        'AC6(ii) call2: run.md logs the run-done-sweep archive line');
    unlike($run_md, qr/ORDER-PRUNE/, 'AC6(ii): run.md contains no ORDER-PRUNE line');

    my ($rc3, $out3) = capture_run(['next', '--scope', 'B'], { data_dir => $data });
    my $act3 = decode_line($out3);
    is($act3->{action}, 'done', 'AC6(ii) call3: done');
}

{   # (iii) a second blueprint parked and out of order -> after B archives,
    # a scope=all next returns done, not need-order.
    my $data = fresh_data();
    make_bp_dir($data, 'B', [ { key => 'p1', status => 'done' } ]);
    make_bp_dir($data, 'P', [ { key => 'z1', status => 'pending' } ]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['B'], recorded_at => $NOW });
    write_json("$dsdir/parks.json", [ { blueprint => 'P', reason => 'moot', at => $NOW } ]);

    my ($rc1, $out1) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    my $act1 = decode_line($out1);
    is($act1->{action}, 'blueprint-done', 'AC6(iii) call1: blueprint-done');
    ok($act1->{archived}, 'AC6(iii) call1: archived true');

    my ($rc2, $out2) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    my $act2 = decode_line($out2);
    is($act2->{action}, 'done',
        'AC6(iii) call2: done, not need-order, despite the parked out-of-order P');
}

# =============================================================================
# AC7 (DC7): the archive is a move -- the relative file set is preserved and
# every file except blueprint.md is byte-identical.
# =============================================================================
{
    my $data = fresh_data();
    my $bp = make_bp_dir($data, 'B', [ { key => 'p1', status => 'done' } ]);
    write_file("$bp/reports/r.md", "report content\n");
    write_file("$bp/specs/s.md", "spec content\n");
    write_file("$bp/runs/x.log", "run log\n");
    write_file("$bp/reports/sub/deep.txt", "deep content\n");
    write_file("$bp/reports/André.md", "non-ascii-named file\n");

    my @before = list_files_rel($bp);
    my %before_content = map { $_ => slurp("$bp/$_") } @before;

    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['B'], recorded_at => $NOW });

    my ($rc, $out) = capture_run(['next', '--scope', 'B'], { data_dir => $data });
    my $act = decode_line($out);
    ok($act->{archived}, 'AC7: archived true');

    my $archived_bp = "$data/blueprints/_archive/B";
    # ignore *.lock artefacts (e.g. blueprint.md.lock, bp-blueprint.pl's flock
    # artefact) created by the reconcile call itself during the archive --
    # they are not part of the moved file set.
    my @after = grep { !/\.lock$/ } list_files_rel($archived_bp);
    is_deeply(\@after, \@before,
        'AC7: the sorted relative file list is preserved (ignoring *.lock artefacts)');
    for my $rel (@after) {
        next if $rel eq 'blueprint.md';
        is(slurp("$archived_bp/$rel"), $before_content{$rel},
            "AC7: $rel is byte-identical after the move");
    }
}

# =============================================================================
# AC8: source/regression guards.
# =============================================================================
{
    my $src = slurp($SCRIPT) // '';
    like($src, qr/'reconcile',\s*'--all',/,
        'AC8: bp-drive-next.pl still contains the B6 --all reconcile call');
    like($src, qr/'--data-dir',\s*\$data,\s*'--archive',\s*'--quiet'/,
        'AC8: bp-drive-next.pl still contains the B6 --data-dir/--archive/--quiet call text');
    like($src, qr/'reconcile',\s*'--blueprint'/,
        'AC8: bp-drive-next.pl contains a list-form single-blueprint reconcile call');

    # Real backtick / qx// command substitution only -- a backtick-delimited
    # span on one (non-comment) line that contains the lifecycle call, or a
    # qx// containing it. Comment lines (leading '#') are excluded so prose
    # mentioning `reconcile --blueprint` in a code span, or an interposed
    # comment between two unrelated list-form calls, cannot false-trigger
    # this. List-form system()/open() calls have no backtick or qx at all.
    my @code_lines = grep { !/^\s*#/ } split /\n/, $src;
    my $code = join("\n", @code_lines);
    unlike($code,
        qr/(`[^`\n]*reconcile[^`\n]*--blueprint[^`\n]*`)|(\bqx\b[^\n]*reconcile[^\n]*--blueprint)/,
        'AC8: the single-blueprint reconcile call is never backtick or qx// shell capture');

    my ($rc, $out) = capture_run(['--help'], {});
    is($rc, 0, 'AC8: --help exits 0');
    like($out, qr/\barchived\b/, 'AC8: --help documents the archived key');
    like($out, qr/\barchive_detail\b/, 'AC8: --help documents the archive_detail key');
}

# ── AC8: named regression files must stay green (this file's own guard) ────
for my $f (qw(
    drive-next.t drive-next-inflight-set.t empty-scope-is-settled.t
    order-json-prune-stale-blueprint.t director-external-waits.t
    drive-integration.t lifecycle-derived.t drafting-blueprint-not-driven.t
)) {
    ok(-f "$Bin/$f", "AC8: regression file $f exists in the suite");
}

# =============================================================================
# M1a (review 01-review.md, Decision 5): a held $dsdir/archive.lock defers the
# archive attempted at blueprint-done emission (archived false, detail
# "deferred: ..."), without moving the blueprint; once the lock is released, a
# later next archives it.
# =============================================================================
{
    my $data = fresh_data();
    make_bp_dir($data, 'B', [ { key => 'p1', status => 'done' } ]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['B'], recorded_at => $NOW });

    my $lockfile = "$dsdir/archive.lock";
    open(my $test_lockfh, '>>', $lockfile) or die "open $lockfile: $!";
    flock($test_lockfh, LOCK_EX) or die "flock (test holder): $!";

    my ($rc, $out) = capture_run(['next', '--scope', 'B'], { data_dir => $data });
    is($rc, 0, 'M1a: next exits 0 while the test process holds archive.lock');
    my $act = decode_line($out);
    ok(defined $act, 'M1a: stdout is valid JSON while the lock is held');
    is($act->{action}, 'blueprint-done', 'M1a: action is blueprint-done while the lock is held');
    ok(JSON::PP::is_bool($act->{archived}),
        'M1a: archived is a JSON boolean while the lock is held');
    ok(!$act->{archived}, 'M1a: archived is false while the lock is held');
    like($act->{archive_detail} // '', qr/^deferred:/,
        'M1a: archive_detail starts with "deferred:" while the lock is held');
    like($act->{archive_detail} // '', qr/^deferred: archive in progress/,
        'M1a: archive_detail starts with "deferred: archive in progress" for a busy archive.lock');
    ok(-d "$data/blueprints/B", 'M1a: blueprints/B is NOT moved while the lock is held');
    ok(!-e "$data/blueprints/_archive/B", 'M1a: no _archive/B is created while the lock is held');

    flock($test_lockfh, LOCK_UN);
    close $test_lockfh;

    my ($rc2, $out2) = capture_run(['next', '--scope', 'B'], { data_dir => $data });
    is($rc2, 0, 'M1a: next exits 0 after the lock is released');
    ok(!-e "$data/blueprints/B", 'M1a: after the lock is released, blueprints/B no longer exists');
    ok(-d "$data/blueprints/_archive/B",
        'M1a: after the lock is released, a later next archives B');
}

# =============================================================================
# M1b (review 01-review.md, Decision 5): a pre-existing _archive/<b> while
# blueprints/<b> is still present must not be clobbered or altered by a
# further archive attempt, and that attempt must not invoke bp-lifecycle.pl
# at all (proven via the lifecycle_script test seam recording whether it ran).
# =============================================================================
{
    my $data = fresh_data();
    make_bp_dir($data, 'B', [ { key => 'p1', status => 'done' } ]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['B'], recorded_at => $NOW });

    make_path("$data/blueprints/_archive/B");
    write_file("$data/blueprints/_archive/B/sentinel.txt", "pre-existing archive contents\n");
    my $before_sentinel = slurp("$data/blueprints/_archive/B/sentinel.txt");
    my @before_archive_files = list_files_rel("$data/blueprints/_archive/B");

    # A fake lifecycle script that, if invoked at all, leaves unmistakable
    # evidence -- a marker file -- so the test can prove the reconcile
    # subprocess was never spawned, independent of any particular
    # archive_detail wording.
    my $ran_marker = "$data/lifecycle-ran.marker";
    my $fake = "$data/fake-lifecycle-m1b.pl";
    write_file($fake,
        "#!$^X\nopen(my \$fh, '>', '$ran_marker') or die; close \$fh; print \"garbage\\n\"; exit 2;\n");
    chmod 0755, $fake;

    my ($rc, $out) = capture_run(['next', '--scope', 'B'],
        { data_dir => $data, lifecycle_script => $fake });
    is($rc, 0, 'M1b: next exits 0 with a pre-existing _archive/B');
    my $act = decode_line($out);
    ok(defined $act, 'M1b: stdout is valid JSON');
    is($act->{action}, 'blueprint-done', 'M1b: action is blueprint-done');
    ok(JSON::PP::is_bool($act->{archived}), 'M1b: archived is a JSON boolean');
    ok(!$act->{archived}, 'M1b: archived is false when the destination already exists');
    is($act->{archive_detail},
        'archive failed: _archive/B already exists (reconcile not run)',
        'M1b: archive_detail is exactly the pre-existing-destination text (Decision 6)');

    ok(!-e $ran_marker,
        'M1b: the attempt never invoked bp-lifecycle.pl (no marker left by the fake script)');

    ok(-d "$data/blueprints/B", 'M1b: blueprints/B is still present, untouched');
    is(slurp("$data/blueprints/_archive/B/sentinel.txt"), $before_sentinel,
        'M1b: the pre-existing _archive/B/sentinel.txt is byte-identical afterward');
    is_deeply([ list_files_rel("$data/blueprints/_archive/B") ], \@before_archive_files,
        'M1b: the pre-existing _archive/B file set is unchanged');
}

# =============================================================================
# M1c (review 01-review.md, Decision 5): the B6 --all run-done backstop also
# takes the same archive.lock, so a lock held by another process defers the
# backstop's archive attempt too, without moving the blueprint.
# =============================================================================
{
    my $data = fresh_data();
    make_bp_dir($data, 'B', [ { key => 'p1', status => 'done' } ]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['B'], recorded_at => $NOW });
    write_json("$dsdir/inflight.json", {
        packages => [ { blueprint => 'B', package => 'p1', ledger => 'x', since => $NOW } ],
    });

    # Call 1: blueprint-done fires and defers (in-flight), same as AC6(ii).
    my ($rc1, $out1) = capture_run(['next', '--scope', 'B'], { data_dir => $data });
    my $act1 = decode_line($out1);
    is($act1->{action}, 'blueprint-done', 'M1c call1: blueprint-done');
    ok(!$act1->{archived}, 'M1c call1: deferred (archived false)');
    ok(-d "$data/blueprints/B", 'M1c call1: B not moved');

    # Call 2 reaches the B6 --all backstop (the in-flight entry is left
    # uncleared, exactly as AC6(ii) does, so B6 is the only path left that
    # will attempt the archive). While the test process holds archive.lock,
    # the backstop must defer rather than archive.
    my $lockfile = "$dsdir/archive.lock";
    open(my $test_lockfh, '>>', $lockfile) or die "open $lockfile: $!";
    flock($test_lockfh, LOCK_EX) or die "flock (test holder): $!";

    my ($rc2, $out2) = capture_run(['next', '--scope', 'B'], { data_dir => $data });
    is($rc2, 0, 'M1c call2: next exits 0 while the lock is held');
    my $act2 = decode_line($out2);
    is($act2->{action}, 'done', 'M1c call2: action is done (a failed/deferred archive never blocks the run)');
    ok(-d "$data/blueprints/B", 'M1c call2: B is NOT moved while the lock is held during the B6 backstop');
    ok(!-e "$data/blueprints/_archive/B", 'M1c call2: no _archive/B while the lock is held');

    flock($test_lockfh, LOCK_UN);
    close $test_lockfh;

    # Call 3, lock released: the B6 backstop now succeeds.
    my ($rc3, $out3) = capture_run(['next', '--scope', 'B'], { data_dir => $data });
    is($rc3, 0, 'M1c call3: next exits 0 after the lock is released');
    my $act3 = decode_line($out3);
    is($act3->{action}, 'done', 'M1c call3: action is done');
    ok(!-e "$data/blueprints/B", 'M1c call3: blueprints/B no longer exists');
    ok(-d "$data/blueprints/_archive/B",
        'M1c call3: after the lock is released, the B6 backstop archives B');
}

# =============================================================================
# AC9 (Decision 2, prose): drive-solo/SKILL.md and authoring-protocol/SKILL.md.
# =============================================================================
{
    my $drive_solo_skill = "$Bin/../../skills/drive-solo/SKILL.md";
    my $authoring_skill  = "$Bin/../../../blueprint/skills/authoring-protocol/SKILL.md";

    ok(-f $drive_solo_skill, 'AC9: drive-solo/SKILL.md exists');
    ok(-f $authoring_skill,  'AC9: authoring-protocol/SKILL.md exists');

    my $ds = slurp($drive_solo_skill) // '';
    like($ds, qr/blueprint-done/, 'AC9: drive-solo/SKILL.md still mentions blueprint-done');
    like($ds, qr/`?archived`?/, 'AC9: drive-solo/SKILL.md mentions archived');
    like($ds, qr/`?archive_detail`?/, 'AC9: drive-solo/SKILL.md mentions archive_detail');

    my $auth = slurp($authoring_skill) // '';
    like($auth, qr/\bdropped\b/, 'AC9: authoring-protocol/SKILL.md mentions dropped');
    like($auth, qr/\bparked\b/, 'AC9: authoring-protocol/SKILL.md mentions parked');
    ok($auth =~ /dropped/ && $auth =~ /parked/
        && do { my ($l) = ($auth =~ /^(.*\bdropped\b.*\bparked\b.*)$/m); defined $l }
       || do { my ($l) = ($auth =~ /^(.*\bparked\b.*\bdropped\b.*)$/m); defined $l },
        'AC9: dropped and parked appear together on one line');
    unlike($auth, qr/set\b[^\n]{0,40}status[^\n]{0,20}\b(done|running)\b/i,
        'AC9: authoring-protocol/SKILL.md still avoids "set ... status ... done/running" (lifecycle-derived.t AC8 guard)');
}

done_testing();
