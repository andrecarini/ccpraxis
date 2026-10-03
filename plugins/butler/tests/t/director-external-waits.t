#!/usr/bin/env perl
# platform: windows
# Companion oracle for cross-blueprint dependency tokens of the shape
# <blueprint>/<package> in the package-status table's depends_on column
# (hook-continuity-remake package 30). Covers AC-1..AC-19 from
# .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 30-director-cross-blueprint-waits-spec.md, Decision 107.
#
# WRITTEN BLIND TO THE IMPLEMENTATION: bp-drive-next.pl and bp-blueprint.pl
# do not yet resolve a slash token, so every assertion below is expected to
# fail on MISSING BEHAVIOUR, never on a bug in this file. The director half
# is driven in-process, the same BpDrive::run/capture idiom as
# drive-next-inflight-set.t (require, injected now/verdict/spawn/kill_pid/
# powershell_available, STDOUT/STDERR captured via File::Temp, never an
# in-memory scalar). The writer half runs bp-blueprint.pl as a real $^X
# subprocess against File::Temp fixtures, the blueprint-write-api.t idiom.
#
# Every fixture lives under a File::Temp tempdir; CCPRAXIS_DATA_DIR is
# localised per call. The real .ccpraxis-local-data and .drive-solo are
# never read or written by this file.

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Basename qw(basename dirname);
use Digest::MD5 qw(md5_hex);

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

my $BUTLER    = "$Bin/../..";
my $DRIVE_SCRIPT = "$BUTLER/scripts/bp-drive-next.pl";
my $BP_SCRIPT    = "$BUTLER/scripts/bp-blueprint.pl";
my $ORCH_SCRIPT  = "$BUTLER/scripts/bp-orchestrator.pl";
my $VAL_SCRIPT   = "$BUTLER/scripts/bp-validate-dag.pl";

require $DRIVE_SCRIPT;     # also pulls in BpOrch:: (parse_dag etc.) for AC-19
my $HAVE_VAL = (-f $VAL_SCRIPT) ? (eval { require $VAL_SCRIPT; 1 } ? 1 : 0) : 0;

my $NOW = 1_830_297_600; # fixed epoch, 2028-01-01T00:00:00Z, same convention as sibling oracles.
my $J = JSON::PP->new->canonical;

# ═══════════════════════════════════════════════════════════════════════════
# Fixture helpers (director half)
# ═══════════════════════════════════════════════════════════════════════════

sub write_pkg_ledger {
    my ($bp_dir, $bp_name, $key, $status, $write_set) = @_;
    open my $fh, '>:raw', "$bp_dir/packages/$key.md" or die "write ledger $key: $!";
    print $fh "---\npackage: $key\nblueprint: $bp_name\nstatus: $status\n"
             . "model: sonnet\nmax_turns: 80\nwrite_set: $write_set\n"
             . "test_paths: $write_set\nlast_updated: 2028-01-01T00:00:00Z\n---\n\n# $key\n";
    close $fh;
}

# make_bp_dir($data, $name, \@pkgs)
# Each pkg: { key, status, write_set, deps => [ 'local-tok', 'B/q', ... ] }
sub make_bp_dir {
    my ($data, $name, $pkgs, %opt) = @_;
    my $bp = "$data/blueprints/$name";
    make_path("$bp/packages");

    my $bp_status = $opt{bp_status} // 'active';
    my $md = "---\nstatus: $bp_status\n---\n\n# $name\n\n## Package status\n\n"
           . "| pkg | deliverable | depends_on | model | status |\n"
           . "|-----|-------------|------------|-------|--------|\n";
    for my $p (@$pkgs) {
        my $deps = (ref $p->{deps} eq 'ARRAY' && @{ $p->{deps} })
                 ? join(', ', @{ $p->{deps} }) : '—';
        $md .= "| $p->{key} | thing | $deps | sonnet | $p->{status} |\n";
    }
    open my $bfh, '>:raw', "$bp/blueprint.md" or die "cannot write blueprint.md: $!";
    print $bfh $md;
    close $bfh;

    for my $p (@$pkgs) {
        next if $p->{no_ledger};
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

# Append a FENCED ``` metadata block (distinct from this file's own
# "---\nstatus: ...\n---" frontmatter convention above, which is a local,
# unrelated shape) so BpState::bp_meta_get -- the one reader the director's
# new _bp_parked() helper uses (spec 08-blueprint-parks §2.1/§2.5) -- can see
# an authored status: parked. parks.json is no longer a source of truth.
sub write_bp_status_fence {
    my ($bp_dir, $status, $reason) = @_;
    open my $fh, '>>:raw', "$bp_dir/blueprint.md" or die "append fence $bp_dir/blueprint.md: $!";
    print $fh "\n```\nstatus: $status\n";
    print $fh "parked_reason: $reason\n" if defined $reason;
    print $fh "```\n";
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
    my ($ofh, $opath) = tempfile('extwXoutXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $epath) = tempfile('extwXerrXXXXXX', TMPDIR => 1); close $efh;
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

sub run_next {
    my ($data, $argv, $opts) = @_;
    local $ENV{CCPRAXIS_DATA_DIR} = $data;
    return capture_run($argv, $opts);
}

sub ext_state {
    # Guarded call: BpDrive::external_dep_state does not exist until this
    # package is implemented. A missing sub must fail the assertion that
    # reads its result, never abort the rest of the file with a fatal
    # "Undefined subroutine".
    my ($data, $tok) = @_;
    return undef unless defined &BpDrive::external_dep_state;
    my $r = eval { BpDrive::external_dep_state($data, $tok) };
    return $r;
}

sub decode_line {
    my ($out) = @_;
    (my $line = $out) =~ s/\n\z//;
    return eval { $J->decode($line) };
}

sub setup_order {
    my ($data, @order) = @_;
    my $ds = "$data/.drive-solo";
    make_path($ds);
    write_json("$ds/order.json", { order => [@order], recorded_at => $NOW });
    return $ds;
}

# ═══════════════════════════════════════════════════════════════════════════
# Fixture helpers (writer half — subprocess)
# ═══════════════════════════════════════════════════════════════════════════

my $BP_ROOT_PN = 0;

sub run_bp {
    my (@args) = @_;
    my $n = ++$BP_ROOT_PN;
    my $tmp = tempdir(CLEANUP => 1);
    my $outf = "$tmp/out.$n";
    my $errf = "$tmp/err.$n";
    open my $ofh, '>:raw', $outf or die $!; close $ofh;
    open my $efh, '>:raw', $errf or die $!; close $efh;
    local %ENV = %ENV;
    delete $ENV{$_} for grep { /^BP_/ } keys %ENV;
    $ENV{EXTW_SCRIPT} = $BP_SCRIPT;
    $ENV{EXTW_OUT}    = $outf;
    $ENV{EXTW_ERR}    = $errf;
    my $rc = system('bash', '-c',
        'timeout 30 perl "$EXTW_SCRIPT" "$@" > "$EXTW_OUT" 2> "$EXTW_ERR"',
        'bp-blueprint', @args);
    return ($rc >> 8, read_file($outf), read_file($errf));
}

sub write_bytes {
    my ($path, $bytes) = @_;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh $bytes;
    close $fh;
}

sub digest_of { md5_hex(read_file($_[0])) }

# A minimal own-blueprint fixture: pkg p0 (no deps), pkg p1 (no deps yet, the
# row set-deps/add-package will edit), matching the shared table shape.
sub own_bp_fixture {
    my ($name) = @_;
    return join("\n",
        "# Blueprint: $name",
        '',
        '## Packages',
        '',
        '| pkg | deliverable | depends_on | model |',
        '|---|---|---|---|',
        '| p0 | first thing | — | sonnet |',
        '| p1 | second thing | — | sonnet |',
        '',
    );
}

# A referent blueprint fixture with one or two resolvable packages.
sub referent_bp_fixture {
    my (@pkgs) = @_;
    my @rows = map { "| $_ | thing | — | sonnet |" } @pkgs;
    return join("\n",
        '# Blueprint: referent',
        '',
        '## Packages',
        '',
        '| pkg | deliverable | depends_on | model |',
        '|---|---|---|---|',
        @rows,
        '',
    );
}

sub stage_writer_fixture {
    # Returns ($base, $a_file, $b_file) with $base/A/blueprint.md (own) and
    # $base/B/blueprint.md (referent, packages q-thing + r-other). The
    # sibling deliberately does NOT share q-thing's prefix -- short id "q"
    # must resolve unambiguously here; AC-16's own ambiguous-package case
    # builds its own two-q-prefixed fixture instead of relying on this one.
    my $base = tempdir(CLEANUP => 1);
    make_path("$base/A");
    make_path("$base/B");
    write_bytes("$base/A/blueprint.md", own_bp_fixture('A'));
    write_bytes("$base/B/blueprint.md", referent_bp_fixture('q-thing', 'r-other'));
    return ($base, "$base/A/blueprint.md", "$base/B/blueprint.md");
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-1 / AC-1b (B1): pending external dep — no hand-out; in-flight with the
# exact external_waits structure; entries sorted by package.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'A', [
        { key => 'p', status => 'pending', write_set => 'a/', deps => ['B/q'] },
    ]);
    make_bp_dir($data, 'B', [
        { key => 'q', status => 'pending', write_set => 'b/' },
    ]);
    # scope A, not "all": B/q is itself ready (pending, no deps), so a scope
    # of "all" would let B10/AC-11's own walk hand it out and never test what
    # this AC is about (A waiting on it). B stays off the walk, exactly as
    # AC-10 keeps its referent off the walk.
    setup_order($data, 'A');

    my ($rc, $out) = run_next($data, ['next', '--scope', 'A']);
    is($rc, 0, 'AC-1: exits 0');
    my $act = decode_line($out);
    is(ref $act eq 'HASH' ? $act->{action} : undef, 'in-flight', 'AC-1: A/p is not handed out; action is in-flight');
    is($act->{blueprint}, 'A', 'AC-1: in-flight names blueprint A');
    is_deeply($act->{external_waits},
        [ { package => 'p', deps => [ { ref => 'B/q', state => 'pending' } ] } ],
        'AC-1 (done criterion 1): external_waits has the exact structure for a pending external dep');
}

{
    # AC-1b: two waiting packages, entries sorted by package (spec 2.3).
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'A', [
        { key => 'z-late',  status => 'pending', write_set => 'z/', deps => ['B/q'] },
        { key => 'a-early', status => 'pending', write_set => 'y/', deps => ['B/q'] },
    ]);
    make_bp_dir($data, 'B', [ { key => 'q', status => 'pending', write_set => 'b/' } ]);
    setup_order($data, 'A'); # B kept off the walk -- see AC-1's comment

    my ($rc, $out) = run_next($data, ['next', '--scope', 'A']);
    is($rc, 0, 'AC-1b: exits 0');
    my $act = decode_line($out);
    is_deeply([ map { $_->{package} } @{ $act->{external_waits} // [] } ], ['a-early', 'z-late'],
        'AC-1b: external_waits entries are sorted by package');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-2 (B1): running external dep — same shape, state running.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'A', [
        { key => 'p', status => 'pending', write_set => 'a/', deps => ['B/q'] },
    ]);
    make_bp_dir($data, 'B', [
        { key => 'q', status => 'running', write_set => 'b/' },
    ]);
    setup_order($data, 'A', 'B');

    my ($rc, $out) = run_next($data, ['next', '--scope', 'all']);
    is($rc, 0, 'AC-2: exits 0');
    my $act = decode_line($out);
    is($act->{action}, 'in-flight', 'AC-2: A/p is not handed out while B/q is running');
    is_deeply($act->{external_waits},
        [ { package => 'p', deps => [ { ref => 'B/q', state => 'running' } ] } ],
        'AC-2: external_waits reports state running');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-3 (B2): B/q flips to done — the next call hands out A/p.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $data = tempdir(CLEANUP => 1);
    my $bpA = make_bp_dir($data, 'A', [
        { key => 'p', status => 'pending', write_set => 'a/', deps => ['B/q'] },
    ]);
    my $bpB = make_bp_dir($data, 'B', [
        { key => 'q', status => 'pending', write_set => 'b/' },
    ]);
    # scope A: B/q is itself ready while pending, so scope "all" would hand
    # it out via B10/AC-11 instead of exercising A's wait on it.
    setup_order($data, 'A');

    my ($rc1, $out1) = run_next($data, ['next', '--scope', 'A']);
    is(decode_line($out1)->{action}, 'in-flight', 'AC-3: still waiting while B/q is pending');

    write_pkg_ledger($bpB, 'B', 'q', 'done', 'b/');
    my ($rc2, $out2) = run_next($data, ['next', '--scope', 'A'], { now => sub { $NOW + 10 } });
    is($rc2, 0, 'AC-3: exits 0 after B/q flips to done');
    my $act2 = decode_line($out2);
    is_deeply($act2, { action => 'run-package', blueprint => 'A', package => 'p' },
        'AC-3 (done criterion 1): the next call returns exactly {"action":"run-package","blueprint":"A","package":"p"}');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-4 (B3): B/q blocked dead-ends A/p exactly as an equivalent local dep
# would dead-end its own dependent — same action shape, never settling.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $dataX = tempdir(CLEANUP => 1);
    make_bp_dir($dataX, 'A', [
        { key => 'p', status => 'pending', write_set => 'a/', deps => ['B/q'] },
    ]);
    make_bp_dir($dataX, 'B', [
        { key => 'q', status => 'blocked', write_set => 'b/' },
    ]);
    setup_order($dataX, 'A', 'B');

    my $dataY = tempdir(CLEANUP => 1);
    make_bp_dir($dataY, 'A2', [
        { key => 'p2', status => 'pending', write_set => 'a2/', deps => ['q2'] },
        { key => 'q2', status => 'blocked', write_set => 'q2/' },
    ]);
    setup_order($dataY, 'A2');

    my ($rcX, $outX) = run_next($dataX, ['next', '--scope', 'all']);
    my $actX = decode_line($outX);
    my ($rcY, $outY) = run_next($dataY, ['next', '--scope', 'all']);
    my $actY = decode_line($outY);

    # A blocked dependency is terminal-but-not-done, so it dead-ends its
    # dependent (spec 2.2): the dependent can never become ready, which
    # means it can never become progressable either, so the whole
    # blueprint settles as blueprint-done -- confirmed here for the LOCAL
    # control fixture, which already exercises this path today. B3 requires
    # the external-blocked fixture to settle A the exact same way.
    isnt($actX->{action}, 'run-package', 'AC-4: A/p is never handed out while its external dep is blocked');
    is($actY->{action}, 'blueprint-done',
        'AC-4: control fixture (local blocked dep) sanity check -- a locally-blocked dependency already settles its blueprint today');
    is($actX->{action}, 'blueprint-done',
        'AC-4 (done criterion 1): an externally-blocked dependency settles A exactly as the equivalent local one settles A2');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-5 (B4): missing blueprint — no hand-out; run.md gains the exact
# EXTERNAL-MISSING line; in-flight state missing-blueprint; A never announced.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'A', [
        { key => 'p', status => 'pending', write_set => 'a/', deps => ['B/q'] },
    ]);
    my $ds = setup_order($data, 'A'); # B is not created anywhere

    my ($rc, $out) = run_next($data, ['next', '--scope', 'all']);
    is($rc, 0, 'AC-5: exits 0');
    my $act = decode_line($out);
    isnt($act->{action}, 'run-package', 'AC-5: A/p is never handed out');
    isnt($act->{action}, 'blueprint-done', 'AC-5: A is not treated as settled');
    isnt($act->{action}, 'done', 'AC-5: no "done" action either');
    is($act->{action}, 'in-flight', 'AC-5: the action is in-flight');
    is_deeply($act->{external_waits},
        [ { package => 'p', deps => [ { ref => 'B/q', state => 'missing-blueprint' } ] } ],
        'AC-5: external_waits carries state missing-blueprint');

    my $run_md = read_file("$ds/run.md");
    like($run_md, qr/EXTERNAL-MISSING A\/p waits on B\/q \(missing-blueprint\)/,
        'AC-5: run.md contains the exact EXTERNAL-MISSING line');

    my $announced = read_json("$ds/announced.json");
    my @list = (ref $announced eq 'HASH' && ref $announced->{announced} eq 'ARRAY')
             ? @{ $announced->{announced} } : ();
    ok(!(grep { $_ eq 'A' } @list), 'AC-5: announced.json never lists A');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-6 (B5): missing package — same as AC-5 with state missing-package.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'A', [
        { key => 'p', status => 'pending', write_set => 'a/', deps => ['B/q'] },
    ]);
    # B exists but has no package q. B's own package "other" is itself ready,
    # so scope stays A -- a scope of "all" would let the walk hand out
    # B/other via B10/AC-11 instead of exercising A's missing-package wait.
    make_bp_dir($data, 'B', [
        { key => 'other', status => 'pending', write_set => 'b/' },
    ]);
    my $ds = setup_order($data, 'A');

    my ($rc, $out) = run_next($data, ['next', '--scope', 'A']);
    is($rc, 0, 'AC-6: exits 0');
    my $act = decode_line($out);
    isnt($act->{action}, 'run-package', 'AC-6: A/p is never handed out');
    is_deeply($act->{external_waits},
        [ { package => 'p', deps => [ { ref => 'B/q', state => 'missing-package' } ] } ],
        'AC-6: external_waits carries state missing-package');

    my $run_md = read_file("$ds/run.md");
    like($run_md, qr/EXTERNAL-MISSING A\/p waits on B\/q \(missing-package\)/,
        'AC-6: run.md contains the exact EXTERNAL-MISSING line');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-7 (B6): malformed slash token — state malformed, plus the run.md line.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'A', [
        { key => 'p', status => 'pending', write_set => 'a/', deps => ['B/q/r'] },
    ]);
    my $ds = setup_order($data, 'A');

    my ($rc, $out) = run_next($data, ['next', '--scope', 'all']);
    is($rc, 0, 'AC-7: exits 0');
    my $act = decode_line($out);
    isnt($act->{action}, 'run-package', 'AC-7: A/p is never handed out for a malformed token');
    is_deeply($act->{external_waits},
        [ { package => 'p', deps => [ { ref => 'B/q/r', state => 'malformed' } ] } ],
        'AC-7: external_waits carries state malformed');

    my $run_md = read_file("$ds/run.md");
    like($run_md, qr/EXTERNAL-MISSING A\/p waits on B\/q\/r \(malformed\)/,
        'AC-7: run.md contains the exact EXTERNAL-MISSING line for the malformed token');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-8 (B7): a referent that lives only under blueprints/_archive/ and is
# done means the dep is met — hand-out fires.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'A', [
        { key => 'p', status => 'pending', write_set => 'a/', deps => ['B/q'] },
    ]);
    make_path("$data/blueprints/_archive");
    # make_bp_dir writes under "<data>/blueprints/<name>" — build the archive
    # path directly instead of reusing that helper's fixed prefix.
    {
        my $arch = "$data/blueprints/_archive/B";
        make_path("$arch/packages");
        my $md = "# B\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n"
               . "|-----|-------------|------------|-------|--------|\n| q | thing | — | sonnet | done |\n";
        open my $fh, '>:raw', "$arch/blueprint.md" or die $!;
        print $fh $md; close $fh;
        write_pkg_ledger($arch, 'B', 'q', 'done', 'b/');
    }
    setup_order($data, 'A');

    my ($rc, $out) = run_next($data, ['next', '--scope', 'all']);
    is($rc, 0, 'AC-8: exits 0');
    my $act = decode_line($out);
    is_deeply($act, { action => 'run-package', blueprint => 'A', package => 'p' },
        'AC-8 (done criterion 1): an archived, done referent counts as met — A/p is handed out');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-9 (B8): local and external deps combine conjunctively.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $data = tempdir(CLEANUP => 1);
    my $bpA = make_bp_dir($data, 'A', [
        { key => 'p0', status => 'done',    write_set => 'a0/' },
        { key => 'p',  status => 'pending', write_set => 'a/', deps => ['p0', 'B/q'] },
    ]);
    my $bpB = make_bp_dir($data, 'B', [
        { key => 'q', status => 'pending', write_set => 'b/' },
    ]);
    # scope A: while B/q is pending it is itself ready, so scope "all" would
    # let the walk hand it out via B10/AC-11 instead of exercising A's
    # conjunctive-deps check. Once B/q is done below it is terminal, so scope
    # no longer matters for it -- kept at A throughout for consistency.
    setup_order($data, 'A');

    my ($rc1, $out1) = run_next($data, ['next', '--scope', 'A']);
    isnt(decode_line($out1)->{action}, 'run-package', 'AC-9: local done + external pending -> no hand-out');

    write_pkg_ledger($bpA, 'A', 'p0', 'pending', 'a0/');
    write_pkg_ledger($bpB, 'B', 'q',  'done',    'b/');
    my ($rc2, $out2) = run_next($data, ['next', '--scope', 'A'], { now => sub { $NOW + 10 } });
    my $act2 = decode_line($out2);
    ok(!($act2->{action} eq 'run-package' && $act2->{package} eq 'p'),
        'AC-9: local pending + external done -> no hand-out for p');

    write_pkg_ledger($bpA, 'A', 'p0', 'done', 'a0/');
    my ($rc3, $out3) = run_next($data, ['next', '--scope', 'A'], { now => sub { $NOW + 20 } });
    is($rc3, 0, 'AC-9: exits 0 once both are done');
    is_deeply(decode_line($out3), { action => 'run-package', blueprint => 'A', package => 'p' },
        'AC-9 (done criterion 1): both done -> p is handed out');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-10 (B9): the referent's ledger status decides regardless of whether the
# referent blueprint is out of scope, parked, or drafting.
# ═══════════════════════════════════════════════════════════════════════════
sub ac10_case {
    my ($label, $setup_referent) = @_;
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'A', [
        { key => 'p', status => 'pending', write_set => 'a/', deps => ['B/q'] },
    ]);
    my $bpB = $setup_referent->($data);
    my $ds = setup_order($data, 'A'); # B deliberately never in the order

    # scope A, not "all": B is deliberately never in order.json, and a scope
    # of "all" would otherwise force a need-order action over the discovered-
    # but-unordered B -- unrelated to what B9 is testing (the referent's
    # ledger status, read independently of scope).
    my ($rc1, $out1) = run_next($data, ['next', '--scope', 'A']);
    is($rc1, 0, "AC-10($label): exits 0 while B/q is pending");
    isnt(decode_line($out1)->{action}, 'run-package', "AC-10($label): pending referent -> no hand-out");

    write_pkg_ledger($bpB, 'B', 'q', 'done', 'b/');
    my ($rc2, $out2) = run_next($data, ['next', '--scope', 'A'], { now => sub { $NOW + 10 } });
    is($rc2, 0, "AC-10($label): exits 0 once B/q is done");
    is_deeply(decode_line($out2), { action => 'run-package', blueprint => 'A', package => 'p' },
        "AC-10($label): done referent -> hand-out, even though B is $label");
}

ac10_case('out-of-scope', sub {
    my ($data) = @_;
    return make_bp_dir($data, 'B', [ { key => 'q', status => 'pending', write_set => 'b/' } ]);
});

ac10_case('parked', sub {
    my ($data) = @_;
    my $bp = make_bp_dir($data, 'B', [ { key => 'q', status => 'pending', write_set => 'b/' } ]);
    write_bp_status_fence($bp, 'parked', 'stale');
    return $bp;
});

ac10_case('drafting', sub {
    my ($data) = @_;
    return make_bp_dir($data, 'B', [ { key => 'q', status => 'pending', write_set => 'b/' } ], bp_status => 'drafting');
});

# ═══════════════════════════════════════════════════════════════════════════
# AC-11 (B10): order [A, B]; A/p waits on B/q, B/q ready — the call hands out
# B/q (walk continues past A once A dead-ends for this call).
# ═══════════════════════════════════════════════════════════════════════════
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'A', [
        { key => 'p', status => 'pending', write_set => 'a/', deps => ['B/q'] },
    ]);
    make_bp_dir($data, 'B', [
        { key => 'q', status => 'pending', write_set => 'b/' },
    ]);
    setup_order($data, 'A', 'B');

    my ($rc, $out) = run_next($data, ['next', '--scope', 'all']);
    is($rc, 0, 'AC-11: exits 0');
    is_deeply(decode_line($out), { action => 'run-package', blueprint => 'B', package => 'q' },
        'AC-11 (done criterion 1): the call returns run-package B/q');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-12 (B11): reclaim never hands out a pending inflight.json entry whose
# external dependency is unmet, even though it is old enough and unbound.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'A', [
        { key => 'p', status => 'pending', write_set => 'a/', deps => ['B/q'] },
    ]);
    make_bp_dir($data, 'B', [
        { key => 'q', status => 'pending', write_set => 'b/' },
    ]);
    my $ds = setup_order($data, 'A', 'B');
    write_json("$ds/inflight.json", { packages => [
        { blueprint => 'A', package => 'p',
          ledger => 'blueprints/A/packages/p.md', since => $NOW - 1800 },
    ], updated_at => $NOW - 1800 });
    my $before = read_file("$ds/inflight.json");

    my ($rc, $out) = run_next($data, ['next', '--scope', 'all']);
    is($rc, 0, 'AC-12: exits 0');
    my $act = decode_line($out);
    ok(!($act->{action} eq 'run-package' && $act->{package} eq 'p'),
        'AC-12 (done criterion 1): the reclaim-eligible A/p entry is not handed out while its external dep is unmet');

    my $after = read_file("$ds/inflight.json");
    my $set = read_json("$ds/inflight.json");
    my ($entry) = grep { $_->{package} eq 'p' } @{ $set->{packages} // [] };
    ok(defined $entry, 'AC-12: the entry stays in the set');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-13 (B12): no cross tokens -> byte-identical actions and run.md, i.e.
# no external_waits key and no EXTERNAL- run.md line.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bpx', [
        { key => 'p1', status => 'pending', write_set => 'a/' },
        { key => 'p2', status => 'pending', write_set => 'b/', deps => ['p1'] },
    ]);
    my $ds = setup_order($data, 'bpx');

    my ($rc, $out) = run_next($data, ['next', '--scope', 'all']);
    is($rc, 0, 'AC-13: exits 0');
    my $act = decode_line($out);
    is($act->{action}, 'run-package', 'AC-13: an ordinary local-only fixture still hands out p1');
    ok(!exists $act->{external_waits}, 'AC-13: no external_waits key when there are no cross tokens');

    my $run_md = read_file("$ds/run.md");
    unlike($run_md, qr/EXTERNAL-/, 'AC-13: run.md has no EXTERNAL- line for a fixture with no cross tokens');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-14: BpDrive::parse_dag tokenising, and BpDrive::external_dep_state's
# five state kinds.
# ═══════════════════════════════════════════════════════════════════════════
{
    is_deeply(BpDrive::parse_dag("| pkg | depends_on |\n|---|---|\n| p1 | p0, B/q, x/y/z |\n"),
        { p1 => ['p0', 'B/q', 'x/y/z'] },
        'AC-14: parse_dag keeps a well-formed cross token and a malformed one, verbatim, in cell order');
    is_deeply(BpDrive::parse_dag("| pkg | depends_on |\n|---|---|\n| p1 | — |\n"),
        { p1 => [] },
        'AC-14: parse_dag still returns [] for an em-dash cell');
}

{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'A', [ { key => 'p', status => 'pending', write_set => 'a/' } ]);
    make_bp_dir($data, 'B', [ { key => 'q', status => 'done',    write_set => 'b/' } ]);

    is(ext_state($data, 'B/q'), 'done', 'AC-14: external_dep_state resolves a done referent');

    my $bpB = "$data/blueprints/B";
    write_pkg_ledger($bpB, 'B', 'q', 'pending', 'b/');
    is(ext_state($data, 'B/q'), 'pending', 'AC-14: external_dep_state resolves a pending referent');

    is(ext_state($data, 'Z/q'), 'missing-blueprint',
        'AC-14: external_dep_state reports missing-blueprint for an absent blueprint dir');
    is(ext_state($data, 'B/nope'), 'missing-package',
        'AC-14: external_dep_state reports missing-package for an absent ledger file');
    is(ext_state($data, 'B/q/r'), 'malformed',
        'AC-14: external_dep_state reports malformed for a non-EXTREF slash token');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-15 (B13/B14/B18): set-deps canonicalises a short id, preserves input
# order, and deps prints tokens in cell order.
# ═══════════════════════════════════════════════════════════════════════════
{
    my ($base, $a_file, $b_file) = stage_writer_fixture();

    my ($rc1, $out1, $err1) = run_bp('set-deps', '--file', $a_file, '--pkg', 'p1', '--deps', 'B/q');
    is($rc1, 0, 'AC-15(B13): set-deps with a short cross id exits 0');
    my $after1 = read_file($a_file);
    like($after1, qr/\|\s*p1\s*\|\s*second thing\s*\|\s*B\/q-thing\s*\|/,
        'AC-15(B13): the cell becomes the canonical B/q-thing');

    my ($rc2, $out2, $err2) = run_bp('set-deps', '--file', $a_file, '--pkg', 'p1', '--deps', 'p0, B/q-thing');
    is($rc2, 0, 'AC-15(B14): set-deps with a mixed local+cross list exits 0');
    my $after2 = read_file($a_file);
    like($after2, qr/\|\s*p1\s*\|\s*second thing\s*\|\s*p0, B\/q-thing\s*\|/,
        'AC-15(B14): the cell is "p0, B/q-thing", in input order');

    my ($rc3, $out3, $err3) = run_bp('deps', '--file', $a_file, '--pkg', 'p1');
    is($rc3, 0, 'AC-15(B18): deps read verb exits 0');
    (my $lines3 = $out3) =~ s/\r\n/\n/g;
    is_deeply([ grep { length } split /\n/, $lines3 ], ['p0', 'B/q-thing'],
        'AC-15(B18): deps prints each token on its own line, in cell order');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-16 (B15): each refusal case exits 2, file byte-identical, token in
# stderr.
# ═══════════════════════════════════════════════════════════════════════════
{
    my @cases = (
        ['missing-blueprint',  'Z/q'],
        ['missing-package',    'B/nope'],
        ['ambiguous-package',  'B/q'],   # token reset below once B carries two same-prefix packages
        ['self-blueprint',     'A/p0'],
        ['malformed',          'B/q/r'],
        ['case-mismatch',      'b/q-thing'],
    );

    for my $c (@cases) {
        my ($label, $tok) = @$c;
        my ($base, $a_file, $b_file) = stage_writer_fixture();
        if ($label eq 'ambiguous-package') {
            # Replace B with two packages sharing the short id "q": q-alpha, q-beta.
            write_bytes($b_file, referent_bp_fixture('q-alpha', 'q-beta'));
            $tok = 'B/q';
        }
        my $before = digest_of($a_file);
        my ($rc, $out, $err) = run_bp('set-deps', '--file', $a_file, '--pkg', 'p1', '--deps', $tok);
        isnt($rc, 0, "AC-16($label): set-deps refuses -- exits non-zero");
        is($rc, 2, "AC-16($label): exit code is exactly 2");
        is(digest_of($a_file), $before, "AC-16($label): the file stays byte-identical");
        like($err, qr/\Q$tok\E/, "AC-16($label): stderr names the offending token ($tok)");
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-17 (B16): set-deps resolves a referent that lives only under _archive/.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $base = tempdir(CLEANUP => 1);
    make_path("$base/A");
    make_path("$base/_archive/B");
    write_bytes("$base/A/blueprint.md", own_bp_fixture('A'));
    write_bytes("$base/_archive/B/blueprint.md", referent_bp_fixture('q-thing'));

    my ($rc, $out, $err) = run_bp('set-deps', '--file', "$base/A/blueprint.md", '--pkg', 'p1', '--deps', 'B/q');
    is($rc, 0, 'AC-17: set-deps resolves an _archive/ referent, exits 0');
    like(read_file("$base/A/blueprint.md"), qr/\|\s*p1\s*\|\s*second thing\s*\|\s*B\/q-thing\s*\|/,
        'AC-17: the cell becomes the canonical B/q-thing even though B is archived');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-18 (B17): add-package --deps follows B13..B16 for a NEW row; a missing
# blueprint leaves the file byte-identical.
# ═══════════════════════════════════════════════════════════════════════════
{
    my ($base, $a_file, $b_file) = stage_writer_fixture();
    my ($rc1, $out1, $err1) = run_bp('add-package', '--file', $a_file, '--pkg', 'p2',
        '--deliverable', 'third thing', '--deps', 'B/q');
    is($rc1, 0, 'AC-18: add-package with a cross token exits 0');
    like(read_file($a_file), qr/\|\s*p2\s*\|\s*third thing\s*\|\s*B\/q-thing\s*\|/,
        'AC-18: the new row carries the canonical B/q-thing cell');

    my ($base2, $a_file2, $b_file2) = stage_writer_fixture();
    my $before2 = digest_of($a_file2);
    my ($rc2, $out2, $err2) = run_bp('add-package', '--file', $a_file2, '--pkg', 'p3',
        '--deliverable', 'fourth thing', '--deps', 'Ghost/q');
    isnt($rc2, 0, 'AC-18: add-package with a missing blueprint refuses -- exits non-zero');
    is($rc2, 2, 'AC-18: exit code is exactly 2');
    is(digest_of($a_file2), $before2, 'AC-18: the file stays byte-identical -- no row is added');
}

# ═══════════════════════════════════════════════════════════════════════════
# AC-19: BpValidateDag::validate() reports no finding mentioning a cross
# token, and BpOrch::parse_dag still omits it (the "other readers ignore it"
# contract, §5).
# ═══════════════════════════════════════════════════════════════════════════
{
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/packages");
    my $md = "# fixture\n\n## Package status\n\n"
           . "| pkg | deliverable | depends_on | model | status |\n"
           . "|-----|-------------|------------|-------|--------|\n"
           . "| p0  | thing | — | sonnet | done |\n"
           . "| p1  | thing | p0, almanac-records/08-pending-decisions | sonnet | pending |\n";
    open my $fh, '>:raw', "$dir/blueprint.md" or die $!;
    print $fh $md; close $fh;
    write_pkg_ledger($dir, 'fixture', 'p0', 'done',    'p0/');
    write_pkg_ledger($dir, 'fixture', 'p1', 'pending', 'p1/');

    my $dag = BpOrch::parse_dag($md);
    is_deeply($dag->{p1}, ['p0'], 'AC-19: BpOrch::parse_dag omits the cross token entirely');

  SKIP: {
        skip 'AC-19: bp-validate-dag.pl not requirable', 1 unless $HAVE_VAL;
        my $result = eval {
            defined &main::validate ? main::validate($dir) : BpValidateDag::validate($dir);
        };
        ok(defined $result, 'AC-19: validate() returns a defined result on a fixture with a cross token');
      SKIP: {
            skip 'AC-19: validate() unavailable', 1 unless defined $result;
            my @hits = grep { defined $_->{message} && $_->{message} =~ /almanac-records\/08-pending-decisions/ }
                       @{ $result->{findings} // [] };
            is(scalar(@hits), 0, 'AC-19: no finding message mentions the cross token');
        }
    }
}

done_testing();
