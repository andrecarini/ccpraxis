#!/usr/bin/env perl
# t/17-drive-next.t — immutable oracle for bp-drive-next.pl (01-director-core).
# Tests EVERY AC-1..AC-9 + AC-11 from the spec §6.
# AC-10 is structural: the suite runs with zero network/powershell/real-clock by design.
# Script does NOT exist yet → tests must FAIL because functions/script are undefined.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(basename);

# ── require the not-yet-existing script ─────────────────────────────────────
# If it doesn't exist this is a compile-time die → caught with eval.
my $SCRIPT = "$Bin/../../scripts/bp-drive-next.pl";
my $LOADED = do {
    local $@;
    eval { require $SCRIPT };
    !$@;
};
# We'll call pure functions via BpDrive:: if the file loads; if not, every
# test that tries to call a function will fail with "Undefined subroutine".

# Fixed epoch for all injected clocks (2028-01-01 00:00:00 UTC = 1830297600).
my $NOW = 1_830_297_600;

my $J = JSON::PP->new->canonical;

# ── Fixture helpers ──────────────────────────────────────────────────────────

sub make_bp_dir {
    # make_bp_dir($data, $name, \@pkgs, [$dag_extra_text])
    # Each pkg: { key=>'p1', status=>'pending', write_set=>'x/', deps=>['p0'] }
    my ($data, $name, $pkgs, $dag_extra) = @_;
    my $bp = "$data/blueprints/$name";
    make_path("$bp/packages");

    # Build the blueprint.md status table (this is where deps live — spec §4 / E-1)
    my $md = "# $name\n\n## Package status\n\n"
           . "| pkg | deliverable | depends_on | model | status |\n"
           . "|-----|-------------|------------|-------|--------|\n";
    for my $p (@$pkgs) {
        my $deps = (ref $p->{deps} eq 'ARRAY' && @{$p->{deps}})
                 ? join(', ', @{$p->{deps}}) : '—';
        $md .= "| $p->{key} | thing | $deps | sonnet | $p->{status} |\n";
    }
    $md .= "\n" . ($dag_extra // '');

    open my $bfh, '>:raw', "$bp/blueprint.md" or die "cannot write blueprint.md: $!";
    print $bfh $md;
    close $bfh;

    # Write per-package ledger files (status + write_set in frontmatter; NO depends_on)
    for my $p (@$pkgs) {
        my $ws = $p->{write_set} // "blueprints/$name/$p->{key}/";
        open my $lfh, '>:raw', "$bp/packages/$p->{key}.md" or die "cannot write ledger: $!";
        print $lfh "---\npackage: $p->{key}\nblueprint: $name\nstatus: $p->{status}\n"
                 . "model: sonnet\nmax_turns: 80\nwrite_set: $ws\n"
                 . "test_paths: $ws\nlast_updated: 2028-01-01T00:00:00Z\n---\n\n# $p->{key}\n";
        close $lfh;
    }
    return $bp;
}

sub write_json {
    my ($path, $data) = @_;
    open my $fh, '>:raw', $path or die "write_json $path: $!";
    print $fh $J->encode($data);
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

# run() seam signature assumed (§4):
#   run(\@argv, {
#     data_dir          => $dir,
#     now               => sub { $epoch },
#     verdict           => sub { $verdict_hash },
#     spawn             => sub { ... },    # no-op fake
#     kill_pid          => sub { ... },    # no-op fake
#     powershell_available => sub { 0 },
#   })
# Returns: exit code (0 = success).

sub run_director {
    my ($argv, $opts) = @_;
    $opts //= {};
    # Inject safe defaults for every seam so tests never touch real resources.
    $opts->{now}                  //= sub { $NOW };
    $opts->{verdict}              //= sub { { action => 'ok' } };
    $opts->{spawn}                //= sub { };
    $opts->{kill_pid}             //= sub { };
    $opts->{powershell_available} //= sub { 0 };
    # run() returns the exit code per spec §4; if not loaded, die propagates.
    BpDrive::run($argv, $opts);
}

# ── Capture stdout (+stderr) from run() ─────────────────────────────────────
# run() must print to STDOUT; we capture it. NOTE: reopening STDOUT/STDERR onto
# in-memory scalar filehandles fails on Git-for-Windows perl ("Bad file
# descriptor"), so we redirect each to a real temp file (fd-backed, works
# cross-platform) and read the exact bytes back via :raw. Returns
# ($rc, $stdout, $stderr); callers that only want ($rc,$out) ignore the third.
sub capture_run {
    my ($argv, $opts) = @_;
    my ($ofh, $opath) = File::Temp::tempfile('t17-outXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $epath) = File::Temp::tempfile('t17-errXXXXXX', TMPDIR => 1); close $efh;
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

# ── AC-1: ready_packages — deps-met + write-set disjoint ────────────────────
{
    my $meta = {
        p1 => { deps => [],        write_set => 'pkg/p1/' },
        p2 => { deps => ['p1'],    write_set => 'pkg/p2/' },
        p3 => { deps => [],        write_set => 'pkg/p3/' },
        p4 => { deps => [],        write_set => 'pkg/p1/sub/' },  # overlaps p1
    };
    # All pending, running=[]: p1, p3, p4 ready (p4 overlaps p1 but no running)
    my @r = BpDrive::ready_packages($meta, {p1=>'pending',p2=>'pending',p3=>'pending',p4=>'pending'}, []);
    is_deeply([sort @r], ['p1','p3','p4'],
        'AC-1: ready_packages: pending+deps-met returned (p2 excluded, dep p1 not done)');

    # p1 done → p2 now ready; done packages excluded
    my @r2 = BpDrive::ready_packages($meta, {p1=>'done',p2=>'pending',p3=>'done',p4=>'pending'}, []);
    is_deeply([sort @r2], ['p2','p4'],
        'AC-1: ready_packages: p2 ready after p1 done; done packages excluded');

    # Non-empty $running proves disjointness clause is live:
    # p1 running → p4 (overlap) excluded; p3 (disjoint) still ready
    my @r3 = BpDrive::ready_packages($meta, {p1=>'running',p2=>'pending',p3=>'pending',p4=>'pending'}, ['p1']);
    is_deeply([sort @r3], ['p3'],
        'AC-1: ready_packages with non-empty $running: p4 excluded (write-set clashes with running p1)');
}

# ── AC-1 (deps_met / write_sets_overlap mirrors) ────────────────────────────
{
    is(BpDrive::deps_met([], {}), 1,
        'AC-1: deps_met: empty deps always met');
    is(BpDrive::deps_met(['a','b'], {a=>'done',b=>'done'}), 1,
        'AC-1: deps_met: all done -> met');
    is(BpDrive::deps_met(['a','b'], {a=>'done',b=>'running'}), 0,
        'AC-1: deps_met: one not done -> unmet');
    is(BpDrive::deps_met(['a'], {}), 0,
        'AC-1: deps_met: missing status -> unmet');

    ok( BpDrive::write_sets_overlap('pkg/a/', 'pkg/a/sub/'),
        'AC-1: write_sets_overlap: dir prefix of sub -> overlap');
    ok(!BpDrive::write_sets_overlap('pkg/a/', 'pkg/b/'),
        'AC-1: write_sets_overlap: sibling dirs -> disjoint');
    ok( BpDrive::write_sets_overlap('pkg/x.pl', 'pkg/x.pl'),
        'AC-1: write_sets_overlap: identical path -> overlap');
    # Mirror BpOrch faithfully (Decision #9). An empty-STRING write-set yields NO
    # prefixes, so the overlap loop never runs and returns 0 (disjoint) — matching
    # bp-orchestrator.pl exactly. The REAL Landmine #4 is a bare-glob write-set that
    # COLLAPSES to an empty PREFIX (e.g. '*' -> ''), which then matches anything.
    ok(!BpDrive::write_sets_overlap('', 'anything/'),
        'AC-1: write_sets_overlap: empty-string write-set -> no prefixes -> disjoint (mirrors BpOrch)');
    ok( BpDrive::write_sets_overlap('pkg/*', 'pkg/a/'),
        'AC-1: write_sets_overlap: glob collapses to a real ancestor prefix -> overlap');
    ok( BpDrive::write_sets_overlap('*', 'anything/'),
        'AC-1: write_sets_overlap: bare-glob collapses to empty PREFIX -> matches anything (real Landmine #4)');
}

# ── AC-2: need-order when no order.json ─────────────────────────────────────
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bp-alpha', [
        {key=>'p1', status=>'pending', write_set=>'bpa/p1/'},
    ]);
    make_bp_dir($data, 'bp-beta', [
        {key=>'q1', status=>'pending', write_set=>'bpb/q1/'},
    ]);

    my ($rc, $out) = capture_run(
        ['next', '--scope', 'bp-alpha,bp-beta'],
        { data_dir => $data }
    );
    is($rc, 0, 'AC-2: next --scope exits 0 when no order.json');
    chomp(my $line = $out);
    my $act = eval { $J->decode($line) };
    ok(defined $act, 'AC-2: stdout is valid JSON');
    is($act->{action}, 'need-order', 'AC-2: action is need-order');
    ok(ref $act->{candidates} eq 'ARRAY' && @{$act->{candidates}} > 0,
        'AC-2: candidates array is non-empty');
    ok((grep { $_ eq 'bp-alpha' } @{$act->{candidates}}),
        'AC-2: bp-alpha in candidates');
    ok((grep { $_ eq 'bp-beta' } @{$act->{candidates}}),
        'AC-2: bp-beta in candidates');
}

# ── AC-3: run-package = first ready pkg of first not-done blueprint ──────────
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bp-one', [
        {key=>'p0', status=>'done',    write_set=>'one/p0/'},
        {key=>'p1', status=>'pending', write_set=>'one/p1/', deps=>['p0']},
        {key=>'p2', status=>'pending', write_set=>'one/p2/', deps=>['p0']},
    ]);
    make_bp_dir($data, 'bp-two', [
        {key=>'q1', status=>'pending', write_set=>'two/q1/'},
    ]);

    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bp-one','bp-two'], recorded_at => $NOW });

    my ($rc, $out) = capture_run(
        ['next', '--scope', 'bp-one,bp-two'],
        { data_dir => $data }
    );
    is($rc, 0, 'AC-3: next exits 0');
    chomp(my $line = $out);
    my $act = eval { $J->decode($line) };
    ok(defined $act, 'AC-3: stdout is valid JSON');
    is($act->{action}, 'run-package', 'AC-3: action is run-package');
    is($act->{blueprint}, 'bp-one', 'AC-3: selects first not-done blueprint (bp-one)');
    # p1 and p2 both ready (deps met); sorted → p1 first
    is($act->{package}, 'p1', 'AC-3: selects first ready package sorted by key (p1)');
}

{   # AC-3 variant: bp-one fully done → skip to bp-two
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bp-one', [
        {key=>'p1', status=>'done', write_set=>'one/p1/'},
    ]);
    make_bp_dir($data, 'bp-two', [
        {key=>'q1', status=>'pending', write_set=>'two/q1/'},
    ]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bp-one','bp-two'], recorded_at => $NOW });
    # bp-one is settled; mark it announced so director skips to bp-two
    write_json("$dsdir/announced.json", { announced => ['bp-one'] });

    my ($rc, $out) = capture_run(
        ['next', '--scope', 'all'],
        { data_dir => $data }
    );
    is($rc, 0, 'AC-3(skip): exits 0');
    chomp(my $line = $out);
    my $act = eval { $J->decode($line) };
    is($act->{action}, 'run-package', 'AC-3(skip): action is run-package');
    is($act->{blueprint}, 'bp-two', 'AC-3(skip): skips fully-done bp-one to bp-two');
    is($act->{package}, 'q1', 'AC-3(skip): first ready pkg of bp-two is q1');
}

# ── AC-4: pause-usage / pause-token / unavailable×3 → degrade-proceed ───────
{   # pause-usage
    my $EPOCH = $NOW + 3600;
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bp-x', [{key=>'p1',status=>'pending',write_set=>'x/p1/'}]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bp-x'], recorded_at => $NOW });

    my ($rc, $out) = capture_run(
        ['next', '--scope', 'bp-x'],
        { data_dir => $data,
          verdict  => sub { { action=>'pause-usage', until_epoch=>$EPOCH, reason=>'five_hour' } } }
    );
    is($rc, 0, 'AC-4(pause-usage): exits 0');
    chomp(my $line = $out);
    my $act = eval { $J->decode($line) };
    ok(defined $act, 'AC-4(pause-usage): valid JSON');
    is($act->{action}, 'pause', 'AC-4(pause-usage): action=pause');
    is($act->{reason}, 'usage', 'AC-4(pause-usage): reason=usage');
    is($act->{until_epoch}, $EPOCH,
        'AC-4(pause-usage): until_epoch carries the exact injected epoch');
    # until_epoch must be a JSON number (not null) for usage pauses
    like($out, qr/"until_epoch"\s*:\s*[0-9]+/,
        'AC-4(pause-usage): until_epoch is numeric JSON (Decision #12)');
}

{   # pause-token
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bp-x', [{key=>'p1',status=>'pending',write_set=>'x/p1/'}]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bp-x'], recorded_at => $NOW });

    my ($rc, $out) = capture_run(
        ['next', '--scope', 'bp-x'],
        { data_dir => $data,
          verdict  => sub { { action=>'pause-token', until_epoch=>undef, reason=>'token' } } }
    );
    is($rc, 0, 'AC-4(pause-token): exits 0');
    chomp(my $line = $out);
    my $act = eval { $J->decode($line) };
    is($act->{action}, 'pause', 'AC-4(pause-token): action=pause');
    is($act->{reason}, 'token', 'AC-4(pause-token): reason=token');
    ok(!defined $act->{until_epoch},
        'AC-4(pause-token): until_epoch is JSON null (terminal relogin, Decision #15)');
    like($out, qr/"until_epoch"\s*:\s*null/,
        'AC-4(pause-token): until_epoch is literal JSON null in the output');
}

{   # unavailable ×3 → degrade-and-proceed; counting fake asserts retry bound
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bp-x', [{key=>'p1',status=>'pending',write_set=>'x/p1/'}]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json", { order => ['bp-x'], recorded_at => $NOW });

    my $call_count = 0;
    my ($rc, $out) = capture_run(
        ['next', '--scope', 'bp-x'],
        { data_dir => $data,
          verdict  => sub { $call_count++; { action=>'unavailable' } } }
    );
    is($rc, 0, 'AC-4(unavailable): exits 0 after degrade-and-proceed');
    chomp(my $line = $out);
    my $act = eval { $J->decode($line) };
    is($act->{action}, 'run-package',
        'AC-4(unavailable): degrade-and-proceed yields run-package (not a halt)');
    is($call_count, 3,
        'AC-4(unavailable): verdict seam called exactly 3 times (retry bound = 3, Decision #14/§2.5)');

    my $run_md = read_file("$dsdir/run.md");
    like($run_md, qr/governance degraded/i,
        'AC-4(unavailable): "governance degraded" warning line written to run.md');
}

# ── AC-5: blueprint-done fires once; re-invoke skips to B2 ──────────────────
{
    my $data = tempdir(CLEANUP => 1);
    # B1: all packages terminal (done)
    make_bp_dir($data, 'bp-one', [
        {key=>'p1', status=>'done', write_set=>'one/p1/'},
    ]);
    # B2: pending work
    make_bp_dir($data, 'bp-two', [
        {key=>'q1', status=>'pending', write_set=>'two/q1/'},
    ]);
    # B3: parked — must be excluded from pending list
    make_bp_dir($data, 'bp-three', [
        {key=>'r1', status=>'pending', write_set=>'three/r1/'},
    ]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json",
        { order => ['bp-one','bp-two','bp-three'], recorded_at => $NOW });
    write_json("$dsdir/parks.json",
        [{ blueprint=>'bp-three', reason=>'stale', at=>$NOW }]);
    # B1 not yet in announced.json
    write_json("$dsdir/announced.json", { announced => [] });

    my ($rc, $out) = capture_run(
        ['next', '--scope', 'all'],
        { data_dir => $data }
    );
    is($rc, 0, 'AC-5: first next exits 0');
    chomp(my $line = $out);
    my $act = eval { $J->decode($line) };
    is($act->{action}, 'blueprint-done',
        'AC-5: action is blueprint-done for settled B1');
    is($act->{blueprint}, 'bp-one', 'AC-5: blueprint = bp-one');
    ok(ref $act->{pending} eq 'ARRAY', 'AC-5: pending is an array');
    ok((grep { $_ eq 'bp-two' } @{$act->{pending}}),
        'AC-5: pending contains bp-two (not-done)');
    ok(!(grep { $_ eq 'bp-three' } @{$act->{pending}}),
        'AC-5: parked bp-three excluded from pending (Decision #17)');
    ok(!(grep { $_ eq 'bp-one' } @{$act->{pending}}),
        'AC-5: bp-one itself not in its own pending list');

    # Fire-once idempotence: now bp-one IS in announced.json
    my $ann = read_json("$dsdir/announced.json");
    ok((grep { $_ eq 'bp-one' } @{$ann->{announced}}),
        'AC-5: bp-one written to announced.json after blueprint-done fires');

    # Second next → must NOT re-announce bp-one; proceeds to bp-two
    my ($rc2, $out2) = capture_run(
        ['next', '--scope', 'all'],
        { data_dir => $data }
    );
    is($rc2, 0, 'AC-5(re-invoke): second next exits 0');
    chomp(my $line2 = $out2);
    my $act2 = eval { $J->decode($line2) };
    isnt($act2->{action}, 'blueprint-done',
        'AC-5(re-invoke): blueprint-done does NOT re-fire for bp-one (fire-once idempotence)');
    is($act2->{action}, 'run-package',
        'AC-5(re-invoke): proceeds to run-package for bp-two');
    is($act2->{blueprint}, 'bp-two', 'AC-5(re-invoke): blueprint is bp-two');
}

# ── AC-6: done when all in-scope blueprints are done-or-parked ──────────────
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bp-a', [{key=>'p1',status=>'done',write_set=>'a/p1/'}]);
    make_bp_dir($data, 'bp-b', [{key=>'p1',status=>'pending',write_set=>'b/p1/'}]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);
    write_json("$dsdir/order.json",
        { order => ['bp-a','bp-b'], recorded_at => $NOW });
    # bp-a announced; bp-b parked
    write_json("$dsdir/announced.json", { announced => ['bp-a'] });
    write_json("$dsdir/parks.json",
        [{ blueprint=>'bp-b', reason=>'out of scope', at=>$NOW }]);

    my ($rc, $out) = capture_run(
        ['next', '--scope', 'all'],
        { data_dir => $data }
    );
    is($rc, 0, 'AC-6: done exits 0');
    chomp(my $line = $out);
    my $act = eval { $J->decode($line) };
    is($act->{action}, 'done',
        'AC-6: all in-scope blueprints done-or-parked → action=done');
}

# ── AC-7: park — idempotent, one entry, run.md logged ───────────────────────
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bp-stale', [{key=>'p1',status=>'pending',write_set=>'s/p1/'}]);
    my $dsdir = "$data/.drive-solo"; make_path($dsdir);

    my ($rc1) = capture_run(
        ['park', 'bp-stale', 'stale — superseded'],
        { data_dir => $data }
    );
    is($rc1, 0, 'AC-7: first park exits 0');

    my $parks = read_json("$dsdir/parks.json");
    ok(ref $parks eq 'ARRAY', 'AC-7: parks.json is an array');
    my @bp_entries = grep { $_->{blueprint} eq 'bp-stale' } @$parks;
    is(scalar @bp_entries, 1, 'AC-7: exactly one entry for bp-stale in parks.json');
    is($bp_entries[0]{reason}, 'stale — superseded',
        'AC-7: reason preserved verbatim');
    ok(defined $bp_entries[0]{at}, 'AC-7: at field present');

    my $run_md = read_file("$dsdir/run.md");
    like($run_md, qr/PARK\s+bp-stale/,
        'AC-7: PARK line written to run.md');

    # Second park — structural idempotence
    my ($rc2) = capture_run(
        ['park', 'bp-stale', 'second attempt'],
        { data_dir => $data }
    );
    is($rc2, 0, 'AC-7(idempotent): second park exits 0');

    my $parks2 = read_json("$dsdir/parks.json");
    my @bp_entries2 = grep { $_->{blueprint} eq 'bp-stale' } @$parks2;
    is(scalar @bp_entries2, 1,
        'AC-7(idempotent): still exactly one entry (no dup appended)');
    is($bp_entries2[0]{reason}, 'stale — superseded',
        'AC-7(idempotent): original reason preserved (first at/reason wins, spec EC-2)');
}

# ── AC-8: keepawake_should_be_on — pure, zero spawn ─────────────────────────
{
    is(BpDrive::keepawake_should_be_on('active'),
        1, 'AC-8: active phase → keepawake ON');
    is(BpDrive::keepawake_should_be_on('pause-pending'),
        1, 'AC-8: pause-pending (timed usage pause) → keepawake ON');
    is(BpDrive::keepawake_should_be_on('settled'),
        0, 'AC-8: settled phase → keepawake OFF');
}

# ── AC-8: verdict_to_action mapping (pure) ───────────────────────────────────
{
    my $ok_v = BpDrive::verdict_to_action({ action=>'ok' }, $NOW);
    ok($ok_v->{ok}, 'AC-8/verdict: ok -> proceed signal');

    my $EPOCH = $NOW + 7200;
    my $pu_v  = BpDrive::verdict_to_action(
        { action=>'pause-usage', until_epoch=>$EPOCH }, $NOW);
    ok(!$pu_v->{ok} && !$pu_v->{unavailable},
        'AC-8/verdict: pause-usage -> pause action (not ok/unavailable)');
    is($pu_v->{until_epoch}, $EPOCH,
        'AC-8/verdict: pause-usage carries until_epoch');

    my $pt_v  = BpDrive::verdict_to_action(
        { action=>'pause-token', until_epoch=>undef }, $NOW);
    ok(!defined $pt_v->{until_epoch},
        'AC-8/verdict: pause-token -> until_epoch=undef (null)');

    my $un_v  = BpDrive::verdict_to_action({ action=>'unavailable' }, $NOW);
    ok($un_v->{unavailable},
        'AC-8/verdict: unavailable -> distinguished {unavailable=>1} for retry logic');
}

# ── AC-8: blueprint_settled (pure) ──────────────────────────────────────────
{
    my $meta = { p1=>{deps=>[]}, p2=>{deps=>['p1']} };
    ok( BpDrive::blueprint_settled($meta, {p1=>'done',p2=>'done'}, 0),
        'AC-8/settled: all done -> settled');
    ok( BpDrive::blueprint_settled($meta, {p1=>'pending',p2=>'pending'}, 1),
        'AC-8/settled: parked_bool wins unconditionally');
    ok(!BpDrive::blueprint_settled($meta, {p1=>'done',p2=>'pending'}, 0),
        'AC-8/settled: pending+met dep -> not settled');
    ok( BpDrive::blueprint_settled($meta, {p1=>'blocked',p2=>'pending'}, 0),
        'AC-8/settled: blocked dep makes p2 dead-ended -> settled (no progressable work)');
}

# ── AC-8: pending_blueprints (pure) ─────────────────────────────────────────
{
    my @order = ('bp-a','bp-b','bp-c','bp-d');
    my %done_or_parked = (q(bp-a)=>1, q(bp-c)=>1);  # b and d are remaining
    my @pending = BpDrive::pending_blueprints(\@order, \%done_or_parked);
    is_deeply(\@pending, ['bp-b','bp-d'],
        'AC-8/pending: returns later-in-order blueprints that are neither done nor parked');
}

# ── AC-9: every emitted action is single-line JSON with correct required keys ─
# (The JSON validity of each action was already asserted above; this group does
# the structural checks in one place as the spec's explicit AC-9 coverage.)
{
    # Helper: assert one-line valid JSON + required keys for each action shape.
    sub assert_json_shape {
        my ($label, $raw, $required_keys) = @_;
        # Must contain exactly one newline and it must be trailing
        my @nl = ($raw =~ /\n/g);
        is(scalar @nl, 1, "AC-9($label): exactly one trailing newline, no embedded newlines");
        my $line = $raw; $line =~ s/\n$//;
        my $decoded = eval { $J->decode($line) };
        ok(defined $decoded && !$@, "AC-9($label): valid JSON");
        for my $k (@$required_keys) {
            ok(exists $decoded->{$k}, "AC-9($label): required key '$k' present");
        }
        return $decoded;
    }

    # need-order shape
    {
        my $data = tempdir(CLEANUP => 1);
        make_bp_dir($data,'bx',[{key=>'p1',status=>'pending',write_set=>'bx/p1/'}]);
        my (undef,$out) = capture_run(['next','--scope','bx'],{data_dir=>$data});
        assert_json_shape('need-order', $out, ['action','candidates']);
    }

    # run-package shape
    {
        my $data = tempdir(CLEANUP => 1);
        make_bp_dir($data,'bx',[{key=>'p1',status=>'pending',write_set=>'bx/p1/'}]);
        my $ds = "$data/.drive-solo"; make_path($ds);
        write_json("$ds/order.json", {order=>['bx'],recorded_at=>$NOW});
        my (undef,$out) = capture_run(['next','--scope','bx'],{data_dir=>$data});
        assert_json_shape('run-package', $out, ['action','blueprint','package']);
    }

    # pause-usage shape
    {
        my $data = tempdir(CLEANUP => 1);
        make_bp_dir($data,'bx',[{key=>'p1',status=>'pending',write_set=>'bx/p1/'}]);
        my $ds = "$data/.drive-solo"; make_path($ds);
        write_json("$ds/order.json", {order=>['bx'],recorded_at=>$NOW});
        my (undef,$out) = capture_run(
            ['next','--scope','bx'],
            { data_dir=>$data,
              verdict=>sub{ {action=>'pause-usage',until_epoch=>$NOW+3600,reason=>'x'} } });
        my $d = assert_json_shape('pause-usage', $out, ['action','until_epoch','reason']);
        ok($d->{until_epoch} =~ /^[0-9]+$/ || $d->{until_epoch} > 0,
            'AC-9(pause-usage): until_epoch is numeric');
    }

    # pause-token shape
    {
        my $data = tempdir(CLEANUP => 1);
        make_bp_dir($data,'bx',[{key=>'p1',status=>'pending',write_set=>'bx/p1/'}]);
        my $ds = "$data/.drive-solo"; make_path($ds);
        write_json("$ds/order.json", {order=>['bx'],recorded_at=>$NOW});
        my (undef,$out) = capture_run(
            ['next','--scope','bx'],
            { data_dir=>$data,
              verdict=>sub{ {action=>'pause-token',until_epoch=>undef,reason=>'x'} } });
        my $d = assert_json_shape('pause-token', $out, ['action','until_epoch','reason']);
        ok(!defined $d->{until_epoch},
            'AC-9(pause-token): until_epoch is JSON null (undef in perl)');
    }

    # blueprint-done shape
    {
        my $data = tempdir(CLEANUP => 1);
        make_bp_dir($data,'b1',[{key=>'p1',status=>'done',write_set=>'b1/p1/'}]);
        make_bp_dir($data,'b2',[{key=>'q1',status=>'pending',write_set=>'b2/q1/'}]);
        my $ds = "$data/.drive-solo"; make_path($ds);
        write_json("$ds/order.json", {order=>['b1','b2'],recorded_at=>$NOW});
        write_json("$ds/announced.json", {announced=>[]});
        my (undef,$out) = capture_run(['next','--scope','all'],{data_dir=>$data});
        assert_json_shape('blueprint-done', $out, ['action','blueprint','pending']);
    }

    # done shape
    {
        my $data = tempdir(CLEANUP => 1);
        make_bp_dir($data,'b1',[{key=>'p1',status=>'done',write_set=>'b1/p1/'}]);
        my $ds = "$data/.drive-solo"; make_path($ds);
        write_json("$ds/order.json", {order=>['b1'],recorded_at=>$NOW});
        write_json("$ds/announced.json", {announced=>['b1']});
        my (undef,$out) = capture_run(['next','--scope','all'],{data_dir=>$data});
        assert_json_shape('done', $out, ['action']);
    }
}

# ── AC-11: --help output contains all required blocks ────────────────────────
{
    my ($rc, $out) = capture_run(['--help'], {});
    is($rc, 0, 'AC-11: --help exits 0');

    # Every subcommand must appear
    like($out, qr/next\s+--scope/, 'AC-11: --help contains "next --scope" subcommand');
    like($out, qr/record-order/,   'AC-11: --help contains "record-order" subcommand');
    like($out, qr/park/,           'AC-11: --help contains "park" subcommand');

    # Every action-JSON shape
    like($out, qr/need-order/,     'AC-11: --help contains need-order action shape');
    like($out, qr/run-package/,    'AC-11: --help contains run-package action shape');
    like($out, qr/blueprint-done/, 'AC-11: --help contains blueprint-done action shape');
    like($out, qr/pause.*usage/s,  'AC-11: --help contains pause/usage action shape');
    like($out, qr/pause.*token/s,  'AC-11: --help contains pause/token action shape');
    like($out, qr/"action"\s*:\s*"done"/, 'AC-11: --help contains done action shape');

    # Governor-verdict shape (pkg-03 handoff)
    like($out, qr/ok.*pause-usage.*pause-token.*unavailable/s,
        'AC-11: --help contains governor verdict shape with all four action values');
    like($out, qr/until_epoch/,    'AC-11: --help documents until_epoch field');
    like($out, qr/bp-usage-gate/,  'AC-11: --help names bp-usage-gate.pl as verdict source');

    # State dir
    like($out, qr/\.drive-solo/,   'AC-11: --help documents .drive-solo/ state dir');
}

# ── AC-11: -h alias ──────────────────────────────────────────────────────────
{
    my ($rc, $out) = capture_run(['-h'], {});
    is($rc, 0, 'AC-11: -h alias exits 0');
    like($out, qr/bp-drive-next/, 'AC-11: -h produces the same help output');
}

# ── Edge: unknown subcommand → nonzero exit, nothing to stdout ───────────────
{
    my ($rc, $out) = eval { capture_run(['bogus-subcommand'], {}) };
    ok($rc != 0, 'Edge: unknown subcommand exits nonzero');
    is($out, '', 'Edge: unknown subcommand produces no stdout');
}

# ── Edge: record-order with zero blueprints → nonzero exit ───────────────────
{
    my $data = tempdir(CLEANUP => 1);
    my ($rc, $out) = eval { capture_run(['record-order'], { data_dir=>$data }) };
    ok($rc != 0, 'Edge(record-order): zero blueprints exits nonzero (spec §2.1)');
}

# ── Edge: record-order writes order.json and run.md entry ────────────────────
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data,'bp-a',[{key=>'p1',status=>'pending',write_set=>'a/p1/'}]);
    make_bp_dir($data,'bp-b',[{key=>'p1',status=>'pending',write_set=>'b/p1/'}]);

    my ($rc) = capture_run(
        ['record-order', 'bp-a', 'bp-b'],
        { data_dir=>$data }
    );
    is($rc, 0, 'Edge(record-order): exits 0 on success');
    my $order = read_json("$data/.drive-solo/order.json");
    is_deeply($order->{order}, ['bp-a','bp-b'],
        'Edge(record-order): order.json order = argv list');
    ok(defined $order->{recorded_at}, 'Edge(record-order): recorded_at present');
    my $run_md = read_file("$data/.drive-solo/run.md");
    like($run_md, qr/order recorded/i,
        'Edge(record-order): "order recorded" line appended to run.md');
}

# ── resolve_scope (pure) ──────────────────────────────────────────────────────
{
    my @all = qw(alpha beta gamma);
    my @r1 = BpDrive::resolve_scope('all', \@all);
    is_deeply(\@r1, \@all, 'resolve_scope: "all" -> whole list');

    my @r2 = BpDrive::resolve_scope('', \@all);
    is_deeply(\@r2, \@all, 'resolve_scope: empty -> whole list');

    my @r3 = BpDrive::resolve_scope('alpha,gamma', \@all);
    is_deeply(\@r3, ['alpha','gamma'], 'resolve_scope: comma list -> ordered subset');

    my @r4 = BpDrive::resolve_scope('alpha gamma', \@all);
    is_deeply(\@r4, ['alpha','gamma'], 'resolve_scope: space-separated -> ordered subset');

    # Name not in all_bp_names is silently dropped
    my @r5 = BpDrive::resolve_scope('alpha,missing', \@all);
    is_deeply(\@r5, ['alpha'], 'resolve_scope: name absent from all_bp_names is dropped');

    # Dedupe: first-seen order preserved
    my @r6 = BpDrive::resolve_scope('alpha,alpha,beta', \@all);
    is_deeply(\@r6, ['alpha','beta'], 'resolve_scope: deduplication preserves first-seen order');
}

done_testing();
