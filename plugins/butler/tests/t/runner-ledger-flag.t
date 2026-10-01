#!/usr/bin/env perl
# platform: any
# Oracle for blueprint never-halt, package 03 (runner --ledger and a
# shape-proof validation interlock, bug 8288). Derived from
# .ccpraxis-local-data/blueprints/never-halt/specs/
# 03-runner-ledger-and-interlock-shapes-spec.md sections 2-5 and the
# package ledger's done criteria, plus Decision 35 Q2 (the same one-line
# _is_full_sweep_runner fix also drops --jobs's value). Neither
# scripts/run-tests.pl's --ledger argv grammar, nor GuardBash's flag-reading
# and shape-normalising predicate, exist yet at write time: every AC below
# is expected to fail for that reason (missing behaviour, not a harness
# defect) until the implementer lands it.
#
# Section 1 (AC-1..AC-6) drives the real scripts/run-tests.pl through
# RunnerStateHarness::run_runner_bounded against a tiny File::Temp fixture
# tree only -- never the repo's real plugins/*/tests/t/ tree -- exactly the
# convention runner-state-cli-grammar.t already uses, per this package's own
# "never let a real sweep run inside a test" hazard.
#
# Section 2 (AC-7..AC-24, AC-26) drives BpHook::Guards::GuardBash in-process
# via GuardHarness::run_module, on hermetic tempdir fixtures. Fixture SHAPES
# (worker marker JSON, binding JSON, ledger frontmatter, coordinator marker,
# inflight.json, PKG A/B/C, assert_live_writer_precondition) are copied
# verbatim from driver-validation-scope.t and interlock-write-set-scope.t,
# which the spec's own "Shorthand used below" section names explicitly as
# the fixture convention to follow -- never derived from GuardBash.pm's
# source, which this file's harness never reads.
#
# AC-25 (the regression check that driver-validation-scope.t,
# interlock-runner-redirects.t, interlock-write-set-scope.t and
# transcript-retention.t stay/become green) is run by the validation step,
# not by this file: tests-never-run-tests.t forbids a test spawning a
# sibling .t file.
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Basename qw(dirname basename);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec ();
use JSON::PP ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib "$Bin/../lib";
use RunnerStateHarness qw(
    make_fixture_tree green_source
    state_file_path
    run_runner_bounded
);
use GuardHarness;

my $BUTLER_DIR = dirname(__FILE__) . '/../..';
my $GUARDBASH_MODULE = "$BUTLER_DIR/scripts/BpHook/Guards/GuardBash.pm";
my $REPO_ROOT = RunnerStateHarness::repo_root();

my $BOUND = 20;   # seconds; every runner fixture below is 1 near-instant file

# ---------------------------------------------------------------------------
# make_green_lint_root() -- a committed git repo fixture holding three green
# plugins/butler/tests/t/<name> lints, for CCPRAXIS_TEST_LINT_ROOT. Needed
# because tooling-fixes 07 makes a --ledger run also run the three repo
# lints: without this, AC-1/AC-2 below would run the real repo lints and
# their file count/redness would depend on the real tree's state. See
# .ccpraxis-local-data/blueprints/tooling-fixes/specs/
# 07-validation-runs-repo-lints-spec.md section 4 "Regression".
# ---------------------------------------------------------------------------
my @LEDGER_FLAG_LINT_BASENAMES = qw(
    test-naming-hygiene.t
    tests-never-run-tests.t
    turn-cap-consistency.t
);

sub make_green_lint_root {
    my $root = tempdir(CLEANUP => 1);
    (my $root_n = $root) =~ s{\\}{/}g;
    my $dir = "$root_n/plugins/butler/tests/t";
    make_path($dir);
    for my $name (@LEDGER_FLAG_LINT_BASENAMES) {
        open(my $fh, '>:raw', "$dir/$name") or die "cannot write $dir/$name: $!";
        print {$fh} "#!/usr/bin/env perl\n# platform: any\nprint \"ok 1 - fixture pass\\n\";\nexit 0;\n";
        close $fh;
    }
    system('git', '-C', $root_n, 'init', '-q') == 0 or die "git init failed in $root_n";
    system('git', '-C', $root_n, 'add', '-A') == 0 or die "git add failed in $root_n";
    system('git', '-C', $root_n, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base') == 0
        or die "git commit failed in $root_n";
    return $root_n;
}

# =============================================================================
# SECTION 1 -- scripts/run-tests.pl --ledger argv grammar (AC-1..AC-6)
# =============================================================================

# ---------------------------------------------------------------------------
# AC-1 -- `--ledger <existing file> <fixture dir>` runs the fixture exactly
# as it would without the flag, prints one `ledger: <path>` line, and the
# summary reports 1 file (the ledger path itself was not treated as a
# target).
# ---------------------------------------------------------------------------
{
    my $fixture = make_fixture_tree('quick-green.t' => green_source());
    my $ledger_path = File::Spec->catfile($fixture, 'tests', 't', 'quick-green.t');
    my $state_dir = tempdir(CLEANUP => 1);
    my $lint_root = make_green_lint_root();

    my $res = run_runner_bounded(
        args    => ['--ledger', $ledger_path, $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC-1: --ledger <existing file> <fixture dir> -> rc 0') or diag($res->{err});
    my @ledger_lines = grep { /^ledger: /m } split /\n/, $res->{out};
    is(scalar(@ledger_lines), 1, 'AC-1: exactly one "ledger: " line on stdout');
    like($res->{out}, qr/^ledger: \Q$ledger_path\E$/m, 'AC-1: the ledger line names the exact --ledger path');
    like($res->{out}, qr/^4 files/m,
        'AC-1: summary reports 4 files (the target plus the three repo lints tooling-fixes 07 adds; '
      . 'the ledger path itself was not treated as a target)');
}

# ---------------------------------------------------------------------------
# AC-2 -- the `--ledger=<path>` form behaves identically to AC-1.
# ---------------------------------------------------------------------------
{
    my $fixture = make_fixture_tree('quick-green.t' => green_source());
    my $ledger_path = File::Spec->catfile($fixture, 'tests', 't', 'quick-green.t');
    my $state_dir = tempdir(CLEANUP => 1);
    my $lint_root = make_green_lint_root();

    my $res = run_runner_bounded(
        args    => ["--ledger=$ledger_path", $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC-2: --ledger=<existing file> <fixture dir> -> rc 0') or diag($res->{err});
    like($res->{out}, qr/^ledger: \Q$ledger_path\E$/m, 'AC-2: the ledger line names the exact --ledger= path');
    like($res->{out}, qr/^4 files/m,
        'AC-2: summary reports 4 files (the target plus the three repo lints tooling-fixes 07 adds)');
}

# ---------------------------------------------------------------------------
# AC-3 -- a missing or directory --ledger path exits 2 in both forms, before
# any collection/execution/state write.
# ---------------------------------------------------------------------------
{
    my $fixture = make_fixture_tree('quick-green.t' => green_source());
    my $state_dir = tempdir(CLEANUP => 1);
    my $missing = File::Spec->catfile($fixture, 'does-not-exist-xyz.md');

    my $res = run_runner_bounded(
        args    => ['--ledger', $missing, $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir },
        timeout => $BOUND,
    );
    is($res->{rc}, 2, 'AC-3: --ledger <missing path> exits 2');
    like($res->{err}, qr/--ledger/, 'AC-3: stderr names --ledger');
    like($res->{err}, qr/\Q$missing\E/, 'AC-3: stderr names the missing path');
    unlike($res->{out}, qr/^\d+ files/m, 'AC-3: no "N files" summary line -- collection never ran');
    ok(!-f state_file_path($state_dir), 'AC-3: no state file was written for the refused invocation');
}
{
    my $fixture = make_fixture_tree('quick-green.t' => green_source());
    my $state_dir = tempdir(CLEANUP => 1);
    my $missing_eq = File::Spec->catfile($fixture, 'also-missing-xyz.md');

    my $res = run_runner_bounded(
        args    => ["--ledger=$missing_eq", $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir },
        timeout => $BOUND,
    );
    is($res->{rc}, 2, 'AC-3: --ledger=<missing path> exits 2');
    like($res->{err}, qr/--ledger/, 'AC-3: stderr names --ledger (= form)');
}
{
    my $fixture = make_fixture_tree('quick-green.t' => green_source());
    my $state_dir = tempdir(CLEANUP => 1);

    my $res = run_runner_bounded(
        args    => ['--ledger', $fixture, $fixture],   # a directory, not a file
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir },
        timeout => $BOUND,
    );
    is($res->{rc}, 2, 'AC-3: --ledger <a directory> exits 2');
    like($res->{err}, qr/--ledger/, 'AC-3: stderr names --ledger (directory case)');
}

# ---------------------------------------------------------------------------
# AC-4 -- a trailing --ledger, an empty --ledger=, and a repeated --ledger
# (even with the same path) each exit 2 with no side effect.
# ---------------------------------------------------------------------------
{
    my $res = run_runner_bounded(args => ['--ledger'], env => {}, timeout => $BOUND);
    is($res->{rc}, 2, 'AC-4: trailing --ledger with no value exits 2');
    like($res->{err}, qr/--ledger/, 'AC-4: stderr names --ledger (trailing)');
}
{
    my $res = run_runner_bounded(args => ['--ledger='], env => {}, timeout => $BOUND);
    is($res->{rc}, 2, 'AC-4: --ledger= (empty value) exits 2');
    like($res->{err}, qr/--ledger/, 'AC-4: stderr names --ledger (empty =)');
}
{
    my $fixture = make_fixture_tree('quick-green.t' => green_source());
    my $ledger_path = File::Spec->catfile($fixture, 'tests', 't', 'quick-green.t');
    my $res = run_runner_bounded(
        args => ['--ledger', $ledger_path, "--ledger=$ledger_path"], env => {}, timeout => $BOUND,
    );
    is($res->{rc}, 2, 'AC-4: --ledger A --ledger=A (same path, given twice) exits 2');
    like($res->{err}, qr/--ledger/, 'AC-4: stderr names --ledger (duplicate)');
}

# ---------------------------------------------------------------------------
# AC-5 -- `--ledger <missing> --help` exits 0 with usage; the help text
# documents --ledger. Help is handled in-loop, so validation never runs.
# ---------------------------------------------------------------------------
{
    my $res = run_runner_bounded(
        args => ['--ledger', '/definitely/not/a/real/path-xyz.md', '--help'],
        env  => {}, timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC-5: --ledger <missing> --help exits 0 (validation never ran)');
    like($res->{out}, qr/--ledger/, 'AC-5: --help output documents --ledger');
}

# ---------------------------------------------------------------------------
# AC-6 -- BP_VALIDATE_LEDGER in the runner's OWN environment has no effect on
# the runner: no exit 2, no "ledger:" line, even naming a path that does not
# exist.
# ---------------------------------------------------------------------------
{
    my $fixture = make_fixture_tree('quick-green.t' => green_source());
    my $state_dir = tempdir(CLEANUP => 1);

    my $res = run_runner_bounded(
        args => [$fixture],
        env  => {
            CCPRAXIS_TEST_STATE_DIR => $state_dir,
            BP_VALIDATE_LEDGER      => '/definitely/not/a/real/path-xyz.md',
        },
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC-6: BP_VALIDATE_LEDGER in env, naming a missing path -> still rc 0 (runner ignores it)');
    unlike($res->{out}, qr/^ledger: /m, 'AC-6: no "ledger: " line -- the env var is never read by the runner');
}

# =============================================================================
# SECTION 2 -- GuardBash: --ledger scoping and the shape-normalising
# predicate (AC-7..AC-24, AC-26)
# =============================================================================

# ---------------------------------------------------------------------------
# fixture packages -- copied verbatim (same bp/pkg/write_set shapes) from
# driver-validation-scope.t. A and C overlap via plugins/fx/alpha/; B is
# disjoint from both.
# ---------------------------------------------------------------------------
my %PKG = (
    A => { bp => 'fx-bp', pkg => 'pa-alpha', ws => 'plugins/fx/alpha/:plugins/fx/tests/t/alpha.t' },
    B => { bp => 'fx-bp', pkg => 'pb-beta',  ws => 'plugins/fx/beta.pm' },
    C => { bp => 'fx-bp', pkg => 'pc-gamma', ws => 'plugins/fx/alpha/x.pm' },
);
my $ALPHA_T = 'plugins/fx/tests/t/alpha.t';

sub tempdir_n {
    my $t = tempdir(CLEANUP => 1);
    (my $n = $t) =~ s{\\}{/}g;
    return $n;
}

sub payload {
    my (%o) = @_;
    my $p = { tool_name => 'Bash', tool_input => { command => $o{cmd} } };
    $p->{session_id}      = $o{session_id}      if exists $o{session_id};
    $p->{agent_id}        = $o{agent_id}         if exists $o{agent_id};
    $p->{transcript_path} = $o{transcript_path}  if exists $o{transcript_path};
    return $p;
}

sub gb {
    my ($p, %env) = @_;
    return GuardHarness::run_module('Guards::GuardBash', $p, env => \%env);
}

sub write_worker_marker {
    my ($data_n, $tuid, %f) = @_;
    make_path("$data_n/.drive-solo/workers");
    my $rec = {
        at            => ($f{at} // time()),
        session_id    => $f{session_id},
        subagent_type => $f{subagent_type},
        tool_use_id   => $tuid,
    };
    my $path = "$data_n/.drive-solo/workers/$tuid";
    open(my $fh, '>:raw', $path) or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode($rec) . "\n";
    close $fh;
    if (exists $f{mtime}) { utime($f{mtime}, $f{mtime}, $path) }
    return $path;
}

sub write_binding {
    my ($data_n, $tuid, %f) = @_;
    make_path("$data_n/.drive-solo/bindings");
    my $rec = {
        at            => ($f{at} // time()),
        blueprint     => $f{blueprint},
        package       => $f{package},
        session_id    => $f{session_id},
        source        => 'bind-dispatch',
        subagent_type => ($f{subagent_type} // 'bp-test-writer'),
        tool_use_id   => $tuid,
    };
    open(my $fh, '>:raw', "$data_n/.drive-solo/bindings/$tuid.json") or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode($rec) . "\n";
    close $fh;
}

sub write_ledger {
    my ($data_n, $bp, $pkg, $ws_line) = @_;
    make_path("$data_n/blueprints/$bp/packages");
    my $wsline = defined($ws_line) ? "write_set: $ws_line\n" : '';
    my $content = "---\npackage: $pkg\nblueprint: $bp\nstatus: running\n${wsline}---\n\n# x\n";
    open(my $fh, '>:raw', "$data_n/blueprints/$bp/packages/$pkg.md") or die $!;
    print {$fh} $content;
    close $fh;
}

# write_ledger_tp($data_n, $bp, $pkg, $ws_line, $tp_line) -- package
# 09-gb-h-residuals, spec sec 2.2/3.13 (Decision 36 N6): write_ledger() with
# an ADDITIONAL test_paths: frontmatter line, needed by AC-40's A' fixture
# (_ledger_scope_paths reads write_set AND test_paths; a missing test_paths:
# key contributes nothing).
sub write_ledger_tp {
    my ($data_n, $bp, $pkg, $ws_line, $tp_line) = @_;
    make_path("$data_n/blueprints/$bp/packages");
    my $wsline = defined($ws_line) ? "write_set: $ws_line\n" : '';
    my $tpline = defined($tp_line) ? "test_paths: $tp_line\n" : '';
    my $content = "---\npackage: $pkg\nblueprint: $bp\nstatus: running\n${wsline}${tpline}---\n\n# x\n";
    open(my $fh, '>:raw', "$data_n/blueprints/$bp/packages/$pkg.md") or die $!;
    print {$fh} $content;
    close $fh;
}

sub write_coordinator_marker {
    my ($bp_dir, $pkg, $content) = @_;
    make_path("$bp_dir/runs");
    open(my $fh, '>:raw', "$bp_dir/runs/$pkg.active-worker") or die $!;
    print {$fh} $content;
    close $fh;
}

sub write_inflight {
    my ($data_n, $pairs) = @_;
    make_path("$data_n/.drive-solo");
    my @entries = map {
        my ($bp, $pkg) = @$_;
        { blueprint => $bp, package => $pkg, ledger => "$bp/packages/$pkg.md", since => time() }
    } @$pairs;
    my $rec = { packages => \@entries, updated_at => time() };
    open(my $fh, '>:raw', "$data_n/.drive-solo/inflight.json") or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode($rec) . "\n";
    close $fh;
}

sub setup_pkg_ledger {
    my ($data_n, $key) = @_;
    my $p = $PKG{$key};
    write_ledger($data_n, $p->{bp}, $p->{pkg}, $p->{ws});
}

sub setup_a_inflight {
    my ($data_n) = @_;
    setup_pkg_ledger($data_n, 'A');
    write_inflight($data_n, [[$PKG{A}{bp}, $PKG{A}{pkg}]]);
}

# ledger_val($data_n, $key) -- the relative BP_VALIDATE_LEDGER/--ledger value
# naming package $key (default A).
sub ledger_val {
    my ($data_n, $key) = @_;
    $key //= 'A';
    return basename($data_n) . "/blueprints/$PKG{$key}{bp}/packages/$PKG{$key}{pkg}.md";
}

# named_a_cmd($data_n, $rest) -- the prefix-form default command (unchanged
# convention from driver-validation-scope.t).
sub named_a_cmd {
    my ($data_n, $rest) = @_;
    $rest //= $ALPHA_T;
    my $rel = ledger_val($data_n, 'A');
    return "BP_VALIDATE_LEDGER=$rel perl $rest";
}

# flag_cmd($data_n, %o) -- the flag-form default command: perl
# scripts/run-tests.pl --ledger <val> <rest>, or --ledger=<val> when
# form => 'eq'. rest => '' omits the operand entirely (a full-sweep shape).
sub flag_cmd {
    my ($data_n, %o) = @_;
    my $rest = exists $o{rest} ? $o{rest} : $ALPHA_T;
    my $val  = $o{val} // ledger_val($data_n, $o{key} // 'A');
    my $flag = (($o{form} // 'space') eq 'eq') ? "--ledger=$val" : "--ledger $val";
    my $tail = length($rest) ? " $rest" : '';
    return "perl scripts/run-tests.pl $flag$tail";
}

sub deny_lines {
    my ($err) = @_;
    my @lines = split /\n/, $err;
    pop @lines while @lines && $lines[-1] eq '';
    return @lines;
}

sub assert_live_writer_precondition {
    my ($data_n, $sid, $label, %o) = @_;
    my $ctrl_cmd = $o{cmd} // "perl $ALPHA_T";
    my %p = (cmd => $ctrl_cmd, session_id => $sid);
    $p{agent_id}        = $o{agent_id}        if exists $o{agent_id};
    $p{transcript_path} = $o{transcript_path} if exists $o{transcript_path};
    my $res = gb(payload(%p), CCPRAXIS_DATA_DIR => $data_n);
    Test::More::is($res->{rc}, 2,
        "$label precondition: same fixture, plain command, no ledger naming -> deny under "
      . "TODAY's code (the fixture's live writer really is recognised as live)")
        or Test::More::diag("precondition failed -- rc was $res->{rc}, err was: $res->{err}");
    return $res;
}

# generic writer-B setup used by most of section 2's ACs: A in flight, B's
# ledger present, a live writer bound to B (disjoint from A).
sub setup_disjoint_b {
    my ($sid) = @_;
    my $data_n = tempdir_n();
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), "$sid setup: session armed driver");
    setup_a_inflight($data_n);
    setup_pkg_ledger($data_n, 'B');
    my $worker_tuid = "WORKERB-$sid";
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');
    return $data_n;
}

# ===========================================================================
# AC-7 -- `--ledger relA <ALPHA_T>` scopes the interlock exactly as the
# prefix does: disjoint live writer B -> rc 0.
# ===========================================================================
{
    my $sid = 'ac7-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-7');

    my $res = gb(payload(cmd => flag_cmd($data_n), session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 0, 'AC-7: --ledger relA plugins/.../alpha.t, disjoint live writer B -> allow');
}

# ===========================================================================
# AC-8 -- the `--ledger=relA` form behaves the same as AC-7.
# ===========================================================================
{
    my $sid = 'ac8-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-8');

    my $res = gb(
        payload(cmd => flag_cmd($data_n, form => 'eq'), session_id => $sid),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res->{rc}, 0, 'AC-8: --ledger=relA plugins/.../alpha.t, disjoint live writer B -> allow');
}

# ===========================================================================
# AC-9 -- `--ledger relA <ALPHA_T>` with an OVERLAPPING live writer (bound to
# C) -> rc 2, message names pc-gamma.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac9-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-9 setup: session armed driver');
    setup_a_inflight($data_n);
    setup_pkg_ledger($data_n, 'C');
    my $worker_tuid = 'AC9WORKERC';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{C}{bp}, package => $PKG{C}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');
    assert_live_writer_precondition($data_n, $sid, 'AC-9');

    my $res = gb(payload(cmd => flag_cmd($data_n), session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 2, 'AC-9: --ledger relA, overlapping live writer C -> deny');
    like($res->{err}, qr/pc-gamma/, 'AC-9: message names the overlapping package pc-gamma');
}

# ===========================================================================
# AC-10 -- a full-sweep runner invocation (no operand, or --fast), prefixed
# with --ledger relA, disjoint B live -> rc 2 for each (a full sweep denies
# while any writer is live, named or not).
# ===========================================================================
{
    my $sid = 'ac10-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-10');

    for my $rest ('', '--fast') {
        my $res = gb(
            payload(cmd => flag_cmd($data_n, rest => $rest), session_id => $sid),
            CCPRAXIS_DATA_DIR => $data_n,
        );
        my $label = length($rest) ? $rest : '(no operand)';
        is($res->{rc}, 2, "AC-10: --ledger relA, full sweep '$label' -> deny");
    }
}

# ===========================================================================
# AC-11 -- the value forms that resolve under the prefix also resolve under
# the flag: absolute, single-quoted, double-quoted, single-quoted backslash
# absolute, and (only on a drive-letter-absolute data dir) /c/ absolute.
# ===========================================================================
{
    my $sid = 'ac11-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-11');

    my $rel = ledger_val($data_n, 'A');
    my $abs = "$data_n/blueprints/$PKG{A}{bp}/packages/$PKG{A}{pkg}.md";
    (my $bs_abs = $abs) =~ s{/}{\\}g;

    my @cases = (
        [ "perl scripts/run-tests.pl --ledger $abs $ALPHA_T"        => 'absolute unquoted form' ],
        [ "perl scripts/run-tests.pl --ledger '$rel' $ALPHA_T"      => 'single-quoted value' ],
        [ qq{perl scripts/run-tests.pl --ledger "$rel" $ALPHA_T}    => 'double-quoted value' ],
        [ "perl scripts/run-tests.pl --ledger '$bs_abs' $ALPHA_T"   => 'backslash-separated absolute (single-quoted)' ],
    );
    for my $c (@cases) {
        my ($cmd, $label) = @$c;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 0, "AC-11 ($label): --ledger resolves to A, disjoint B live -> allow") or diag("cmd: $cmd");
    }

    SKIP: {
        skip('AC-11: data dir is not drive-letter-absolute on this host', 1)
            unless $data_n =~ m{^([A-Za-z]):/};
        my $letter = lc($1);
        (my $rest = $data_n) =~ s{^[A-Za-z]:}{};
        my $val = "/$letter$rest/blueprints/$PKG{A}{bp}/packages/$PKG{A}{pkg}.md";
        my $cmd = "perl scripts/run-tests.pl --ledger $val $ALPHA_T";
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 0, 'AC-11 (/c/ absolute form): resolves -> allow') or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-12 -- the flag is read only from the leading runner invocation: after
# "true &&", or on a .t rather than on the runner itself, is unscoped.
# ===========================================================================
{
    my $sid = 'ac12-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-12');

    my $rel = ledger_val($data_n, 'A');
    for my $c (
        [ "true && perl scripts/run-tests.pl --ledger $rel $ALPHA_T" => 'non-leading runner invocation' ],
        [ "perl $ALPHA_T --ledger $rel"                              => 'flag on the .t itself, not the runner' ],
    ) {
        my ($cmd, $label) = @$c;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 2, "AC-12 ($label): unscoped -> deny") or diag("cmd: $cmd");
        like($res->{err}, qr/a write-capable worker \(/, "AC-12 ($label): fallback text");
    }
}

# ===========================================================================
# AC-13 -- prefix and flag both present: same path -> rc 0; different paths
# -> unscoped deny; a doubled --ledger flag -> unscoped deny.
# ===========================================================================
{
    my $sid = 'ac13-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-13');

    my $rel   = ledger_val($data_n, 'A');
    my $rel_b = ledger_val($data_n, 'B');

    my $res_same = gb(
        payload(cmd => "BP_VALIDATE_LEDGER=$rel perl scripts/run-tests.pl --ledger $rel $ALPHA_T", session_id => $sid),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res_same->{rc}, 0, 'AC-13: prefix and flag name the same path -> allow');

    my $res_diff = gb(
        payload(cmd => "BP_VALIDATE_LEDGER=$rel perl scripts/run-tests.pl --ledger $rel_b $ALPHA_T", session_id => $sid),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res_diff->{rc}, 2, 'AC-13: prefix and flag name different paths -> unscoped deny');

    my $res_dup = gb(
        payload(cmd => "perl scripts/run-tests.pl --ledger $rel --ledger $rel $ALPHA_T", session_id => $sid),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res_dup->{rc}, 2, 'AC-13: two --ledger flags -> unscoped deny');
}

# ===========================================================================
# AC-14 -- each unresolvable --ledger flag value gives an unscoped deny with
# a live writer present, and rc 0 with no workers dir at all.
# ===========================================================================
sub ac14_case {
    my (%o) = @_;
    my $data_n = tempdir_n();
    my $sid = "ac14-$o{label}-sid";
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), "AC-14 ($o{label}) setup: session armed driver");

    $o{setup}->($data_n) if $o{setup};
    my $cmd = $o{cmd}->($data_n);

    setup_pkg_ledger($data_n, 'B');
    my $worker_tuid = "AC14WORKER-$o{label}";
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');
    assert_live_writer_precondition($data_n, $sid, "AC-14 ($o{label})");

    my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 2, "AC-14 ($o{label}): unresolvable flag value, live writer -> deny");
}
ac14_case(
    label => 'outside-data-dir',
    setup => \&setup_a_inflight,
    cmd   => sub {
        my ($data_n) = @_;
        my $other = tempdir_n();
        return "perl scripts/run-tests.pl --ledger $other/blueprints/$PKG{A}{bp}/packages/$PKG{A}{pkg}.md $ALPHA_T";
    },
);
ac14_case(
    label => 'ledger-missing',
    setup => sub {
        my ($data_n) = @_;
        write_inflight($data_n, [[$PKG{A}{bp}, $PKG{A}{pkg}]]);
        # deliberately no ledger file written for fx-bp/pa-alpha.
    },
    cmd => sub { my ($data_n) = @_; return flag_cmd($data_n) },
);
ac14_case(
    label => 'HOME-expansion-value',
    setup => \&setup_a_inflight,
    cmd   => sub { return "perl scripts/run-tests.pl --ledger \$HOME/x.md $ALPHA_T" },
);
ac14_case(
    label => 'not-in-inflight',
    setup => sub {
        my ($data_n) = @_;
        write_ledger($data_n, 'fx-bp', 'pz-zeta', 'plugins/fx/zeta.pm');
        setup_a_inflight($data_n);
    },
    cmd => sub {
        my ($data_n) = @_;
        my $rel = basename($data_n) . '/blueprints/fx-bp/packages/pz-zeta.md';
        return "perl scripts/run-tests.pl --ledger $rel $ALPHA_T";
    },
);

# non-vacuity half of AC-14: no workers dir at all -> allow, for one of the
# unresolvable shapes above.
{
    my $data_n = tempdir_n();
    my $sid = 'ac14-novacuity-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-14 (non-vacuity) setup: session armed driver');
    setup_a_inflight($data_n);
    # deliberately no .drive-solo/workers dir at all.
    my $other = tempdir_n();
    my $cmd = "perl scripts/run-tests.pl --ledger $other/blueprints/$PKG{A}{bp}/packages/$PKG{A}{pkg}.md $ALPHA_T";
    my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 0, 'AC-14 (non-vacuity): unresolvable flag value, no workers dir -> allow');
}

# ===========================================================================
# AC-15 -- a subagent bound to A, whose command's --ledger names B (B in
# flight), with a live writer overlapping A but disjoint from B -> rc 2.
# Its own binding governs; --ledger cannot rescope it.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac15-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-15 setup: session armed driver');

    setup_pkg_ledger($data_n, 'A');
    setup_pkg_ledger($data_n, 'B');
    setup_pkg_ledger($data_n, 'C');
    write_inflight($data_n, [[$PKG{A}{bp}, $PKG{A}{pkg}], [$PKG{B}{bp}, $PKG{B}{pkg}]]);

    my $caller_tuid = 'AC15CALLER';
    write_binding($data_n, $caller_tuid, blueprint => $PKG{A}{bp}, package => $PKG{A}{pkg}, session_id => $sid);

    my $worker_tuid = 'AC15WORKERC';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{C}{bp}, package => $PKG{C}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');

    my $transcript = "$data_n/transcript.jsonl";
    my $meta_dir = dirname($transcript) . "/$sid/subagents";
    make_path($meta_dir);
    open(my $fh, '>:raw', "$meta_dir/agent-AC15AID.meta.json") or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode({ toolUseId => $caller_tuid });
    close $fh;

    assert_live_writer_precondition($data_n, $sid, 'AC-15', agent_id => 'AC15AID', transcript_path => $transcript);

    my $rel_b = ledger_val($data_n, 'B');
    my $cmd = "perl scripts/run-tests.pl --ledger $rel_b $ALPHA_T";
    my $res = gb(
        payload(cmd => $cmd, session_id => $sid, agent_id => 'AC15AID', transcript_path => $transcript),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res->{rc}, 2, 'AC-15: subagent bound to A, --ledger names B, but its own binding (overlapping C) governs -> deny');
}

# ===========================================================================
# AC-16 -- the prefix form still works (unaffected by the flag's addition):
# both a prefixed runner invocation and a prefixed bare .t invocation give
# rc 0 against a disjoint live writer B.
# ===========================================================================
{
    my $sid = 'ac16-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-16');

    my $rel = ledger_val($data_n, 'A');
    for my $c (
        [ "BP_VALIDATE_LEDGER=$rel perl scripts/run-tests.pl $ALPHA_T" => 'prefixed runner invocation' ],
        [ "BP_VALIDATE_LEDGER=$rel perl $ALPHA_T"                      => 'prefixed bare .t invocation' ],
    ) {
        my ($cmd, $label) = @$c;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 0, "AC-16 ($label): prefix form still resolves -> allow") or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-17 -- with a live writer present (driver-main, no ledger named), every
# listed shape is recognised as a test run -> unscoped deny.
# ===========================================================================
{
    my $sid = 'ac17-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-17');

    my @rows = (
        [ 'perl plugins/fx/tests/t/alpha.t'                                             => 'forward slash' ],
        [ 'perl plugins\fx\tests\t\alpha.t'                                             => 'backslash, unquoted' ],
        [ q{perl 'plugins\fx\tests\t\alpha.t'}                                          => 'backslash, single-quoted' ],
        [ 'perl C:/Development/ccpraxis/plugins/fx/tests/t/alpha.t'                     => 'C:/ absolute' ],
        [ 'perl /c/Development/ccpraxis/plugins/fx/tests/t/alpha.t'                     => '/c/ absolute' ],
        [ 'perl.exe plugins/fx/tests/t/alpha.t'                                         => 'perl.exe' ],
        [ '/usr/bin/perl plugins/fx/tests/t/alpha.t'                                    => 'absolute /usr/bin/perl' ],
        [ 'C:/Strawberry/perl/bin/perl.exe plugins/fx/tests/t/alpha.t'                  => 'absolute perl.exe path' ],
        [ q{perl "plugins/fx/tests/t/alpha.t"}                                          => 'double-quoted path' ],
        [ q{perl 'plugins/fx/tests/t/alpha.t'}                                          => 'single-quoted path' ],
        [ q{"C:/Program Files/Git/usr/bin/perl.exe" "plugins/fx/tests/t/alpha.t"}       => 'quoted perl.exe, quoted path' ],
        [ 'FOO=1 perl plugins/fx/tests/t/alpha.t'                                       => 'unrelated leading env assignment' ],
        [ 'BUTLER_STATE_DIR=/tmp/x perl plugins/fx/tests/t/alpha.t'                     => 'BUTLER_STATE_DIR leading assignment' ],
        [ 'perl -Ilib plugins/fx/tests/t/alpha.t'                                       => 'glued -Ilib' ],
        [ 'perl -I lib plugins/fx/tests/t/alpha.t'                                      => 'separate -I lib' ],
        [ 'perl -I plugins/butler/tests/lib -w plugins/fx/tests/t/alpha.t'              => '-I dir plus -w' ],
        [ 'timeout 60 perl.exe plugins/fx/tests/t/alpha.t'                              => 'timeout-wrapped' ],
        [ q{bash -c 'perl.exe plugins/fx/tests/t/alpha.t'}                              => 'bash -c body' ],
        [ 'perl plugins/fx/tests/t/alpha.t 2>&1'                                        => 'trailing redirect' ],
    );
    for my $r (@rows) {
        my ($cmd, $label) = @$r;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 2, "AC-17 ($label): recognised as a test run -> unscoped deny") or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-18 -- the runner variants are unscoped denies too.
# ===========================================================================
{
    my $sid = 'ac18-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-18');

    my @rows = (
        [ 'perl.exe scripts/run-tests.pl plugins/fx/tests/t/alpha.t'          => 'perl.exe run-tests.pl' ],
        [ q{perl "scripts/run-tests.pl" plugins/fx/tests/t/alpha.t}          => 'quoted run-tests.pl' ],
        [ '/usr/bin/perl scripts/run-tests.pl plugins/fx/tests/t/alpha.t'     => 'absolute /usr/bin/perl run-tests.pl' ],
    );
    for my $r (@rows) {
        my ($cmd, $label) = @$r;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 2, "AC-18 ($label): runner variant recognised -> unscoped deny") or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-19 -- on Windows-family perls only, case-insensitive command name and
# .T extension are still recognised. Skipped elsewhere with a stated reason.
# ===========================================================================
SKIP: {
    my $is_windows_family = ($^O =~ /^(?:MSWin32|msys|cygwin)$/) ? 1 : 0;
    skip('AC-19: case-insensitive perl/.t matching is a Windows-family-only rule; this host is not one', 2)
        unless $is_windows_family;

    my $sid = 'ac19-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-19');

    for my $r (
        [ 'PERL.EXE plugins/fx/tests/t/alpha.t'      => 'uppercase PERL.EXE' ],
        [ 'Perl plugins/fx/tests/t/ALPHA.T'          => 'mixed-case Perl, uppercase .T' ],
    ) {
        my ($cmd, $label) = @$r;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 2, "AC-19 ($label): case-insensitive match on Windows-family perl -> deny") or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-20 -- the coordinator branch (BP_LEDGER, BP_DIR, BP_PACKAGE set, a
# fresh runs/<pkg>.active-worker bp-implementer marker) also recognises both
# shapes -> rc 2 with "BLOCKED (validation interlock)".
# ===========================================================================
{
    my $tmp = tempdir_n();
    my $bp_dir = "$tmp/bp";
    make_path($bp_dir);
    write_coordinator_marker($bp_dir, 'pkg1', 'bp-implementer');
    my %env = (BP_LEDGER => '/x/ledger.md', BP_DIR => $bp_dir, BP_PACKAGE => 'pkg1');

    for my $r (
        [ 'perl.exe plugins/fx/tests/t/alpha.t'          => 'perl.exe' ],
        [ q{perl "plugins/fx/tests/t/alpha.t"}           => 'quoted path' ],
    ) {
        my ($cmd, $label) = @$r;
        my $res = gb(payload(cmd => $cmd), %env);
        is($res->{rc}, 2, "AC-20 ($label): coordinator branch recognises the shape -> deny") or diag("cmd: $cmd");
        like($res->{err}, qr/BLOCKED \(validation interlock\)/, "AC-20 ($label): message carries the validation-interlock label");
    }
}

# ===========================================================================
# AC-21 -- false-positive set: every row below stays rc 0 with a live writer
# present (the predicate is purely additive; none of these are perl-runs-
# a-.t shapes).
# ===========================================================================
{
    my $sid = 'ac21-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-21');

    my @rows = (
        'perl -c plugins/fx/tests/t/alpha.t',
        'perl -wc plugins/fx/tests/t/alpha.t',
        q{perl.exe -c "plugins/fx/tests/t/alpha.t"},
        'perl -I lib -c plugins/fx/tests/t/alpha.t',
        'grep -n ok plugins/fx/tests/t/alpha.t',
        'cat plugins/fx/tests/t/alpha.t',
        'head -n 5 plugins/fx/tests/t/alpha.t',
        'sed -n 1,5p plugins/fx/tests/t/alpha.t',
        'wc -l plugins/fx/tests/t/alpha.t',
        'ls plugins/fx/tests/t/',
        'git diff -- plugins/fx/tests/t/alpha.t',
        'git log -p plugins/fx/tests/t/alpha.t',
        q{echo "perl plugins/fx/tests/t/alpha.t"},
        q{git commit -m "fix perl.exe plugins/fx/tests/t/alpha.t"},
        'perl plugins/fx/scripts/tool.pl plugins/fx/tests/t/alpha.t',
        "cat <<'EOF'\nperl.exe plugins/fx/tests/t/alpha.t\nEOF",
        'perl -c scripts/run-tests.pl',
    );
    for my $cmd (@rows) {
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 0, "AC-21 (false positive): '$cmd' stays allow") or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-22 -- non-vacuity: with NO live writer, every AC-17 shape is rc 0.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac22-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-22 setup: session armed driver');
    setup_a_inflight($data_n);
    # deliberately no .drive-solo/workers dir at all.

    my @rows = (
        'perl plugins/fx/tests/t/alpha.t',
        'perl plugins\fx\tests\t\alpha.t',
        'perl.exe plugins/fx/tests/t/alpha.t',
        'perl -Ilib plugins/fx/tests/t/alpha.t',
        'FOO=1 perl plugins/fx/tests/t/alpha.t',
        'perl scripts/run-tests.pl plugins/fx/tests/t/alpha.t',
    );
    for my $cmd (@rows) {
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 0, "AC-22 (non-vacuity): '$cmd', no live writer -> allow") or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-23 -- global-config/settings.json parses, keeps the plain runner rule,
# and no entry starts with the dropped mid-wildcard prefix.
# ===========================================================================
{
    my $settings_path = "$REPO_ROOT/global-config/settings.json";
    ok(-f $settings_path, "AC-23 setup: $settings_path exists on disk");
    my $raw = do {
        open(my $fh, '<:raw', $settings_path) or die "cannot read $settings_path: $!";
        local $/;
        <$fh>;
    };
    my $data = eval { JSON::PP->new->utf8->decode($raw) };
    ok(defined $data, 'AC-23: global-config/settings.json parses as valid JSON') or diag($@);
    my $allow = $data->{permissions}{allow} // [];
    ok((grep { $_ eq 'Bash(perl scripts/run-tests.pl *)' } @$allow),
        'AC-23: permissions.allow keeps Bash(perl scripts/run-tests.pl *)');
    ok(!(grep { /^Bash\(BP_VALIDATE_LEDGER=/ } @$allow),
        'AC-23: no permissions.allow entry starts with Bash(BP_VALIDATE_LEDGER=');
}

# ===========================================================================
# AC-24 -- source pin: GuardBash.pm still never reads $ENV{BP_VALIDATE_LEDGER}.
# ===========================================================================
{
    ok(-f $GUARDBASH_MODULE, "AC-24 setup: $GUARDBASH_MODULE exists on disk");
    open(my $fh, '<', $GUARDBASH_MODULE) or die "cannot read $GUARDBASH_MODULE: $!";
    local $/;
    my $src = <$fh>;
    close $fh;
    unlike($src, qr/\$ENV\{\s*['"]?BP_VALIDATE_LEDGER['"]?\s*\}/,
        'AC-24: GuardBash.pm source contains no $ENV{BP_VALIDATE_LEDGER} read');
}

# ===========================================================================
# AC-26 -- Decision 35 Q2: _is_full_sweep_runner skips the VALUE of every
# value-taking runner flag, not just --ledger. `--jobs 4 x.t` is a single-
# file run, not a full sweep.
# ===========================================================================
{
    my $sid = 'ac26-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-26');

    my $res_jobs_only = gb(
        payload(cmd => "perl scripts/run-tests.pl --jobs 4 $ALPHA_T", session_id => $sid),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res_jobs_only->{rc}, 2, 'AC-26: --jobs 4 x.t, unnamed, disjoint live writer -> deny (still just one operand)');

    my $rel = ledger_val($data_n, 'A');
    my $res_named = gb(
        payload(cmd => "BP_VALIDATE_LEDGER=$rel perl scripts/run-tests.pl --jobs 4 $ALPHA_T", session_id => $sid),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res_named->{rc}, 0, 'AC-26: named A, --jobs 4 x.t counted as ONE operand -> allow (not treated as a full sweep)');

    my $res_named_sweep = gb(
        payload(cmd => "BP_VALIDATE_LEDGER=$rel perl scripts/run-tests.pl --jobs 4", session_id => $sid),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res_named_sweep->{rc}, 2, 'AC-26: named A, --jobs 4 with NO path operand is still a full sweep -> deny');
}

# =============================================================================
# SECTION 3 -- red-team 03 regressions (reports/03-redteam.md) and review
# SHOULD-FIX 1 (reports/03-review.md), per Decision 36 (ONE fix-batch; this
# test-writer pass goes first). Every AC below pins a ruling the driver took.
# Deny rows are RED today for M1-M3/S1-S5/N4 (missing behaviour: the false
# negative the finding describes); allow rows are RED today for S6/S7/N1
# (missing behaviour: the false denial the finding describes). N5 has no test
# seam and is reported, not tested (see the handback report).
# =============================================================================

# ---------------------------------------------------------------------------
# AC-27 (M1) -- a for-loop, a variable script word, a bare perl.exe glob,
# xargs perl and find -exec perl all count as a test run while a writer is
# live -> unscoped deny. Paired with a no-live-writer control (non-vacuity).
# ---------------------------------------------------------------------------
{
    my $sid = 'ac27-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-27');

    my @rows = (
        [ q{for f in plugins/fx/tests/t/*.t; do perl "$f"; done}         => 'for-loop over a glob, quoted var script' ],
        [ q{for f in plugins/fx/tests/t/alpha.t; do perl.exe $f; done}   => 'for-loop, perl.exe, unquoted var script' ],
        [ "T=$ALPHA_T; perl \$T"                                        => 'variable assignment then bare $T' ],
        [ qq{T=$ALPHA_T; perl "\$T"}                                    => 'variable assignment then quoted "$T"' ],
        [ "perl.exe plugins/fx/tests/t/*.t"                             => 'perl.exe with a bare glob operand' ],
        [ qq{echo $ALPHA_T | xargs perl}                                => 'xargs perl, piped filename' ],
        [ 'ls plugins/fx/tests/t | xargs -n1 /usr/bin/perl'             => 'xargs -n1 /usr/bin/perl' ],
        [ q{find plugins/fx/tests/t -name '*.t' -exec perl {} \;}       => 'find -exec perl' ],
    );
    for my $r (@rows) {
        my ($cmd, $label) = @$r;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 2, "AC-27 M1 ($label): recognised as a test run, writer live -> unscoped deny") or diag("cmd: $cmd");
    }
}
{
    my $data_n = tempdir_n();
    my $sid = 'ac27-novacuity-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-27 (non-vacuity) setup: session armed driver');
    setup_a_inflight($data_n);

    my @rows = (
        q{for f in plugins/fx/tests/t/*.t; do perl "$f"; done},
        q{for f in plugins/fx/tests/t/alpha.t; do perl.exe $f; done},
        "T=$ALPHA_T; perl \$T",
        "perl.exe plugins/fx/tests/t/*.t",
        qq{echo $ALPHA_T | xargs perl},
        q{find plugins/fx/tests/t -name '*.t' -exec perl {} \;},
    );
    for my $cmd (@rows) {
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 0, "AC-27 (non-vacuity): '$cmd', no live writer -> allow") or diag("cmd: $cmd");
    }
}

# ---------------------------------------------------------------------------
# AC-28 (M2) -- a quoted/backslashed runner word, or a quoted flag value,
# must not turn a full sweep into "one file": each is still a full sweep
# (no real path operand) and must deny while ANY writer is live, exactly as
# the unquoted form (AC-10) does. Paired with a no-writer control.
# ---------------------------------------------------------------------------
{
    my $sid = 'ac28-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-28');

    my $rel = ledger_val($data_n, 'A');
    my @rows = (
        [ qq{perl "scripts/run-tests.pl" --ledger $rel}       => 'quoted runner word, no operand' ],
        [ qq{perl 'scripts/run-tests.pl' --ledger $rel}       => 'single-quoted runner word, no operand' ],
        [ "perl scripts\\run-tests.pl --ledger $rel"          => 'backslash-separated runner word' ],
        [ qq{perl scripts/run-tests.pl --ledger $rel '--fast'}   => q{quoted '--fast' flag} ],
        [ qq{perl scripts/run-tests.pl --ledger $rel "--nice"}   => q{double-quoted "--nice" flag} ],
        [ qq{perl scripts/run-tests.pl --ledger $rel '--state=failed'} => q{quoted '--state=failed' flag} ],
    );
    for my $r (@rows) {
        my ($cmd, $label) = @$r;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 2, "AC-28 M2 ($label): still a full sweep, writer live -> deny") or diag("cmd: $cmd");
    }
}
{
    my $data_n = tempdir_n();
    my $sid = 'ac28-novacuity-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-28 (non-vacuity) setup: session armed driver');
    setup_a_inflight($data_n);
    my $rel = ledger_val($data_n, 'A');

    my $res = gb(
        payload(cmd => qq{perl "scripts/run-tests.pl" --ledger $rel}, session_id => $sid),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res->{rc}, 0, 'AC-28 (non-vacuity): quoted runner word, no operand, NO live writer -> allow');
}

# ---------------------------------------------------------------------------
# AC-29 (M3) -- a directory operand or a glob operand is many files, not
# "one file": each must deny while a writer is live, exactly like a
# no-operand full sweep. Paired with a no-writer control.
# ---------------------------------------------------------------------------
{
    my $sid = 'ac29-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-29');

    my $rel = ledger_val($data_n, 'A');
    my @rows = (
        [ "perl scripts/run-tests.pl --ledger $rel plugins/butler"                 => 'directory operand' ],
        [ qq{perl scripts/run-tests.pl --ledger $rel 'plugins/*/tests/t/*.t'}      => 'quoted glob operand' ],
        [ "perl scripts/run-tests.pl --ledger $rel plugins/*/tests/t/*.t"          => 'bare glob operand' ],
    );
    for my $r (@rows) {
        my ($cmd, $label) = @$r;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 2, "AC-29 M3 ($label): many files, not one -- writer live -> deny") or diag("cmd: $cmd");
    }
}
{
    my $data_n = tempdir_n();
    my $sid = 'ac29-novacuity-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-29 (non-vacuity) setup: session armed driver');
    setup_a_inflight($data_n);
    my $rel = ledger_val($data_n, 'A');

    my $res = gb(
        payload(cmd => "perl scripts/run-tests.pl --ledger $rel plugins/butler", session_id => $sid),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res->{rc}, 0, 'AC-29 (non-vacuity): directory operand, NO live writer -> allow');
}

# ---------------------------------------------------------------------------
# AC-30 (S1) -- wrappers the predicate does not unwrap, combined with a
# non-bare perl, must not evade: setsid, ionice, watch, script -qc, env -S.
# Paired with a no-writer control.
# ---------------------------------------------------------------------------
{
    my $sid = 'ac30-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-30');

    my @rows = (
        [ "setsid perl.exe $ALPHA_T"                          => 'setsid perl.exe' ],
        [ "ionice -c3 perl -I lib $ALPHA_T"                   => 'ionice -c3 perl -I lib' ],
        [ "watch -n1 perl.exe $ALPHA_T"                       => 'watch -n1 perl.exe' ],
        [ qq{script -qc 'perl.exe $ALPHA_T' /dev/null}        => 'script -qc' ],
        [ qq{env -S 'perl.exe $ALPHA_T'}                      => 'env -S' ],
    );
    for my $r (@rows) {
        my ($cmd, $label) = @$r;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 2, "AC-30 S1 ($label): wrapped perl.exe recognised, writer live -> deny") or diag("cmd: $cmd");
    }
}
{
    my $data_n = tempdir_n();
    my $sid = 'ac30-novacuity-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-30 (non-vacuity) setup: session armed driver');
    setup_a_inflight($data_n);

    my $res = gb(payload(cmd => "setsid perl.exe $ALPHA_T", session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 0, 'AC-30 (non-vacuity): setsid perl.exe, NO live writer -> allow');
}

# ---------------------------------------------------------------------------
# AC-31 (S2) -- perl reading the test from stdin, a `<` redirect, or via
# `-e'do ...'`/`-e'do shift'`/`-E`/`-MTest::Harness -e 'runtests @ARGV'`,
# must not evade.
# ---------------------------------------------------------------------------
{
    my $sid = 'ac31-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-31');

    my @rows = (
        [ "perl < $ALPHA_T"                                            => 'perl < x.t' ],
        [ "perl - < $ALPHA_T"                                          => 'perl - < x.t' ],
        [ "cat $ALPHA_T | perl"                                        => 'cat x.t | perl' ],
        [ "cat $ALPHA_T | perl -"                                      => 'cat x.t | perl -' ],
        [ qq{perl -e 'do "plugins/fx/tests/t/alpha.t"'}                => q{perl -e 'do "x.t"'} ],
        [ "perl -e 'do shift' $ALPHA_T"                                => q{perl -e 'do shift' x.t} ],
        [ qq{perl -E 'do "plugins/fx/tests/t/alpha.t"'}                => q{perl -E 'do "x.t"'} ],
        [ q{perl -Iplugins/fx/tests/t -e 'do q(alpha.t)'}              => q{perl -Iplugins/fx/tests/t -e 'do q(alpha.t)'} ],
        [ qq{perl -e 'do "scripts/run-tests.pl"'}                      => q{perl -e 'do "scripts/run-tests.pl"'} ],
        [ "perl -e 'do shift' scripts/run-tests.pl $ALPHA_T"           => q{perl -e 'do shift' scripts/run-tests.pl x.t} ],
        [ "perl -MTest::Harness -e 'runtests \@ARGV' $ALPHA_T"         => q{perl -MTest::Harness -e 'runtests @ARGV' x.t} ],
    );
    for my $r (@rows) {
        my ($cmd, $label) = @$r;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 2, "AC-31 S2 ($label): stdin/-e/-E form recognised, writer live -> deny") or diag("cmd: $cmd");
    }
}

# ---------------------------------------------------------------------------
# AC-32 (S3) -- `prove` must be caught beyond a bare word: an absolute path,
# a perl-launched prove, and a quoted "prove". Paired with a no-writer
# control.
# ---------------------------------------------------------------------------
{
    my $sid = 'ac32-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-32');

    my @rows = (
        [ "/usr/bin/prove $ALPHA_T"                 => 'absolute /usr/bin/prove' ],
        [ "/usr/bin/core_perl/prove $ALPHA_T"       => 'absolute .../core_perl/prove' ],
        [ "perl /usr/bin/prove $ALPHA_T"            => 'perl /usr/bin/prove' ],
        [ "perl.exe /usr/bin/prove $ALPHA_T"        => 'perl.exe /usr/bin/prove' ],
        [ qq{"prove" $ALPHA_T}                      => 'quoted "prove"' ],
    );
    for my $r (@rows) {
        my ($cmd, $label) = @$r;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 2, "AC-32 S3 ($label): prove recognised beyond a bare word, writer live -> deny") or diag("cmd: $cmd");
    }
}
{
    my $data_n = tempdir_n();
    my $sid = 'ac32-novacuity-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-32 (non-vacuity) setup: session armed driver');
    setup_a_inflight($data_n);

    my $res = gb(payload(cmd => "/usr/bin/prove $ALPHA_T", session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 0, 'AC-32 (non-vacuity): /usr/bin/prove, NO live writer -> allow');
}

# ---------------------------------------------------------------------------
# AC-33 (S4) -- the runner or a .t reached by direct exec/shebang, or by a
# thin wrapper, must not evade. Paired with a no-writer control.
# ---------------------------------------------------------------------------
{
    my $sid = 'ac33-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-33');

    my @rows = (
        [ $ALPHA_T                                          => 'direct exec, bare relative path' ],
        [ "./$ALPHA_T"                                      => 'direct exec, ./ prefixed' ],
        [ "timeout 60 ./$ALPHA_T"                            => 'timeout-wrapped direct exec' ],
        [ "timeout 60 scripts/run-tests.pl $ALPHA_T"        => 'timeout-wrapped runner' ],
        [ "env ./scripts/run-tests.pl $ALPHA_T"             => 'env-wrapped ./scripts/run-tests.pl' ],
        [ qq{bash -c 'scripts/run-tests.pl $ALPHA_T'}       => 'bash -c body, bare runner' ],
    );
    for my $r (@rows) {
        my ($cmd, $label) = @$r;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 2, "AC-33 S4 ($label): direct-exec/wrapper form recognised, writer live -> deny") or diag("cmd: $cmd");
    }
}
{
    my $data_n = tempdir_n();
    my $sid = 'ac33-novacuity-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-33 (non-vacuity) setup: session armed driver');
    setup_a_inflight($data_n);

    my $res = gb(payload(cmd => $ALPHA_T, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 0, 'AC-33 (non-vacuity): direct exec, NO live writer -> allow');
}

# ---------------------------------------------------------------------------
# AC-34 (S4, 8.3 alias) -- on Windows-family perls, a script or command
# basename in the ~N.pl/~N.t 8.3-alias shape is judged lexically as the
# runner/a .t file -- WITHOUT depending on a real 8.3 alias existing on
# disk. Skipped elsewhere with a stated reason.
# ---------------------------------------------------------------------------
SKIP: {
    my $is_windows_family = ($^O =~ /^(?:MSWin32|msys|cygwin)$/) ? 1 : 0;
    skip('AC-34: the 8.3-alias lexical rule is a Windows-family-only rule; this host is not one', 3)
        unless $is_windows_family;

    my $sid = 'ac34-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-34');

    my @rows = (
        [ "perl scripts/RUN-TE~1.PL $ALPHA_T" => '8.3-alias runner name, with an operand' ],
        [ 'perl scripts/RUN-TE~1.PL'          => '8.3-alias runner name, no operand (full sweep)' ],
        [ 'perl plugins/fx/tests/t/ALPHA~1.T' => '8.3-alias .t basename' ],
    );
    for my $r (@rows) {
        my ($cmd, $label) = @$r;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 2, "AC-34 S4 ($label): 8.3 alias judged lexically, writer live -> deny") or diag("cmd: $cmd");
    }
}

# ---------------------------------------------------------------------------
# AC-35 (S5) -- a scoped command whose later segment is itself
# validation-shaped is unscoped as a whole: the scope from segment 0 does
# not cover a later `&&`/`;`-joined segment.
# ---------------------------------------------------------------------------
{
    my $sid = 'ac35-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-35');

    my $rel = ledger_val($data_n, 'A');
    my @rows = (
        [ "perl scripts/run-tests.pl --ledger $rel $ALPHA_T && perl.exe plugins/fx/tests/t/beta.t"
            => 'later && segment is itself a perl-runs-a-.t shape' ],
        [ "perl scripts/run-tests.pl --ledger $rel $ALPHA_T; prove -r plugins"
            => 'later ; segment is a prove invocation' ],
        [ "perl scripts/run-tests.pl --ledger $rel $ALPHA_T; perl scripts/run-tests.pl plugins/fx"
            => 'later ; segment is another (unscoped) runner invocation' ],
    );
    for my $r (@rows) {
        my ($cmd, $label) = @$r;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 2, "AC-35 S5 ($label): whole command unscoped, writer live -> deny") or diag("cmd: $cmd");
    }
}

# ---------------------------------------------------------------------------
# AC-36 (S6 + review SHOULD-FIX 1) -- a glued -e/-E cluster, or -MO=Deparse,
# runs NO script file: these are NOT test runs, on both bare perl and
# perl.exe, and must stay allowed even while a writer is live (false
# denials to fix).
# ---------------------------------------------------------------------------
{
    my $sid = 'ac36-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-36');

    my @rows = (
        [ "perl.exe -ne'print' $ALPHA_T"          => q{perl.exe -ne'print' x.t} ],
        [ "perl -ne'print' $ALPHA_T"              => q{perl -ne'print' x.t} ],
        [ "perl.exe -e1 $ALPHA_T"                 => 'perl.exe -e1 x.t' ],
        [ "perl -e1 $ALPHA_T"                     => 'perl -e1 x.t' ],
        [ "perl.exe -pi -e's/a/b/' $ALPHA_T"      => q{perl.exe -pi -e's/a/b/' x.t} ],
        [ "perl -pi -e's/a/b/' $ALPHA_T"          => q{perl -pi -e's/a/b/' x.t} ],
        [ "perl.exe -ln0777e'print' $ALPHA_T"     => q{perl.exe -ln0777e'print' x.t} ],
        [ "perl -ln0777e'print' $ALPHA_T"         => q{perl -ln0777e'print' x.t} ],
        [ qq{perl -E"say 1" $ALPHA_T}             => q{perl -E"say 1" x.t} ],
        [ qq{perl.exe -E"say 1" $ALPHA_T}         => q{perl.exe -E"say 1" x.t} ],
        [ "perl.exe -MO=Deparse $ALPHA_T"         => 'perl.exe -MO=Deparse x.t' ],
        [ "perl -MO=Deparse $ALPHA_T"             => 'perl -MO=Deparse x.t' ],
    );
    for my $r (@rows) {
        my ($cmd, $label) = @$r;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 0, "AC-36 S6 ($label): code-on-command-line/compile-only, NOT a test run -> allow") or diag("cmd: $cmd");
    }
}

# ---------------------------------------------------------------------------
# AC-37 (S7) -- old-regex false denials that must stay allowed: grep/rg/echo
# naming perl and a .t, and the standard `git commit -m "$(cat <<'EOF' ...
# EOF)"` form whose heredoc body names a test or starts a line with
# scripts/run-tests.pl.
# ---------------------------------------------------------------------------
{
    my $sid = 'ac37-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-37');

    my $cmd_commit1 = "git commit -m \"\$(cat <<'EOF'\nfix perl $ALPHA_T\nEOF\n)\"";
    my $cmd_commit2 = "git commit -m \"\$(cat <<'EOF'\nscripts/run-tests.pl --fast was red\nEOF\n)\"";

    my @rows = (
        [ "grep perl $ALPHA_T"     => 'grep perl x.t' ],
        [ "grep -l perl $ALPHA_T"  => 'grep -l perl x.t' ],
        [ "rg perl $ALPHA_T"       => 'rg perl x.t' ],
        [ "echo perl $ALPHA_T"     => 'echo perl x.t' ],
        [ $cmd_commit1             => q{git commit heredoc body naming a test} ],
        [ $cmd_commit2             => q{git commit heredoc body starting with scripts/run-tests.pl} ],
    );
    for my $r (@rows) {
        my ($cmd, $label) = @$r;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 0, "AC-37 S7 ($label): not a perl-runs-a-.t shape -> allow") or diag("cmd: $cmd");
    }
}

# ---------------------------------------------------------------------------
# AC-38 (N1) -- a wrapped scoped run must not be over-denied: `timeout 600`
# ahead of a validly-scoped runner invocation still resolves the scope.
# ---------------------------------------------------------------------------
{
    my $sid = 'ac38-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-38');

    my $rel = ledger_val($data_n, 'A');
    my $cmd = "timeout 600 perl scripts/run-tests.pl --ledger $rel $ALPHA_T";
    my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 0, 'AC-38 N1: timeout-wrapped scoped runner call still resolves to A -> allow') or diag("cmd: $cmd");
}

# ---------------------------------------------------------------------------
# AC-39 (N4) -- versioned/suffixed perl binary names are missed: perl5.x,
# /usr/bin/perl5 and wperl.exe. Paired with a no-writer control.
# ---------------------------------------------------------------------------
{
    my $sid = 'ac39-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-39');

    my @rows = (
        [ "perl5.36.0 $ALPHA_T"       => 'perl5.36.0' ],
        [ "/usr/bin/perl5 $ALPHA_T"   => '/usr/bin/perl5' ],
        [ "wperl.exe $ALPHA_T"        => 'wperl.exe' ],
    );
    for my $r (@rows) {
        my ($cmd, $label) = @$r;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 2, "AC-39 N4 ($label): versioned/suffixed perl binary recognised, writer live -> deny") or diag("cmd: $cmd");
    }
}
{
    my $data_n = tempdir_n();
    my $sid = 'ac39-novacuity-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-39 (non-vacuity) setup: session armed driver');
    setup_a_inflight($data_n);

    my $res = gb(payload(cmd => "perl5.36.0 $ALPHA_T", session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 0, 'AC-39 (non-vacuity): perl5.36.0, NO live writer -> allow');
}

# =============================================================================
# Package 09-gb-h-residuals (specs/09-gb-h-residuals-spec.md). AC-40 onward.
# WRITTEN BLIND TO THE IMPLEMENTATION, same convention as section 2 above:
# _scoped_test_operand, _ledger_scope_paths, the lower-only
# BP_GUARD_DEADLINE_SECONDS seam on _perl_test_run's OWN deadline, and the
# D38 "mention alone" fix DO NOT EXIST YET at the time this block is
# written -- every row below is expected RED until the implementer lands
# it, EXCEPT where a comment says otherwise. This file's own running AC-N
# numbering continues from AC-39; the spec's OWN "AC-13".."AC-15" labels
# (specs/09-gb-h-residuals-spec.md sec 4) are cited alongside each AC-NN.
# =============================================================================

# ===========================================================================
# AC-40 (spec AC-14, sec 3.13, Decision 36 N6) -- a scoped runner/bare-.t
# operand must itself be a member of the NAMED package's test_paths or
# write_set; naming A does not scope an operand belonging to some other
# package.
# ===========================================================================
{
    my $sid = 'ac40-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-40');

    my $rel = ledger_val($data_n, 'A');
    my $pkg = $PKG{A}{pkg};
    # Role is pinned, not left open-ended: setup_disjoint_b() always writes
    # the live-writer marker/binding with subagent_type => 'bp-implementer'
    # (see write_worker_marker/write_binding calls above), so the role token
    # inside the parens is predictable here. The regex is anchored through
    # end-of-line so it also pins the ") is in flight." tail -- a looser
    # prefix-only match would pass even if the tail text drifted.
    my $msg_re = qr/^BLOCKED \(validation interlock\): this test file is outside package \Q$pkg\E's test_paths\/write_set; a write-capable worker \(bp-implementer\) is in flight\.$/;

    my $cmd1 = "perl scripts/run-tests.pl --ledger $rel plugins/fx/tests/t/beta.t";
    my $res1 = gb(payload(cmd => $cmd1, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res1->{rc}, 2, 'AC-40 (spec AC-14, sec 3.13 row 1): --ledger relA names an operand outside A -> deny (today rc 0)') or diag("cmd: $cmd1");
    my @l1 = deny_lines($res1->{err});
    like($l1[0] // '', $msg_re,
        'AC-40 (spec AC-14, sec 3.13 row 1): line 1 is the new N6 scoping message') or diag("err: $res1->{err}");
    like($l1[1] // '', qr/^Not run: /,
        'AC-40 (spec AC-14, sec 3.13 row 1): line 2 starts with "Not run: " (the existing retry line)') or diag("err: $res1->{err}");

    my $cmd2 = "BP_VALIDATE_LEDGER=$rel perl plugins/fx/tests/t/beta.t";
    my $res2 = gb(payload(cmd => $cmd2, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res2->{rc}, 2, 'AC-40 (spec AC-14, sec 3.13 row 2): BP_VALIDATE_LEDGER=relA perl beta.t -> deny (today rc 0)') or diag("cmd: $cmd2");
    my @l2 = deny_lines($res2->{err});
    like($l2[0] // '', $msg_re,
        'AC-40 (spec AC-14, sec 3.13 row 2): line 1 is the new N6 scoping message') or diag("err: $res2->{err}");
    like($l2[1] // '', qr/^Not run: /,
        'AC-40 (spec AC-14, sec 3.13 row 2): line 2 starts with "Not run: " (the existing retry line)') or diag("err: $res2->{err}");

    my $cmd3 = "perl scripts/run-tests.pl --ledger $rel plugins/fx/alpha/t/x.t";
    my $res3 = gb(payload(cmd => $cmd3, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res3->{rc}, 0, 'AC-40 (spec AC-14, sec 3.13 row 3): operand under a write_set DIRECTORY -> allow') or diag("cmd: $cmd3");

    # row 4 -- an A' fixture whose write_set does NOT list the operand, but
    # whose test_paths does. A' must be in-flight too (same convention
    # setup_a_inflight() already uses for A: named-ledger resolution needs
    # the NAMED package listed in inflight.json), so this re-writes
    # inflight.json to carry BOTH A and A' (B's own live-writer binding does
    # not depend on inflight.json, so it is unaffected).
    write_ledger_tp($data_n, 'fx-bp', 'pap-alpha2', 'plugins/fx/alpha/', 'plugins/fx/tests/t/alpha2.t');
    write_inflight($data_n, [[$PKG{A}{bp}, $PKG{A}{pkg}], ['fx-bp', 'pap-alpha2']]);
    my $rel_ap = basename($data_n) . '/blueprints/fx-bp/packages/pap-alpha2.md';
    my $cmd4 = "perl scripts/run-tests.pl --ledger $rel_ap plugins/fx/tests/t/alpha2.t";
    my $res4 = gb(payload(cmd => $cmd4, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res4->{rc}, 0, "AC-40 (spec AC-14, sec 3.13 row 4): operand is in A'" . "'s test_paths, not its write_set -> allow") or diag("cmd: $cmd4");

    # row 5 -- the scoped operand itself given as an absolute path, under
    # the root (dirname($data_n)).
    my $root = dirname($data_n);
    my $cmd5 = "perl scripts/run-tests.pl --ledger $rel $root/$ALPHA_T";
    my $res5 = gb(payload(cmd => $cmd5, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res5->{rc}, 0, 'AC-40 (spec AC-14, sec 3.13 row 5): absolute operand under the root, naming A -> allow') or diag("cmd: $cmd5");
}

# ===========================================================================
# AC-41 (spec AC-13, sec 3.2, Decision 36 N5) -- _perl_test_run's own
# deadline, via _hyg_deadline_at(2), is lower-only (BP_GUARD_DEADLINE_SECONDS
# can only shrink it) and fails CLOSED on expiry. Through run(), a deadline
# hit with a live writer present is then denied by the validation interlock
# (the command becomes "a test run" only because the deadline expired).
# ===========================================================================
{
    require BpHook::Guards::GuardBash;
    my $cmd = 'cat notes.t' . ('; :' x 2000);

    {
        local %ENV = %ENV;
        delete $ENV{BP_GUARD_DEADLINE_SECONDS};
        my $r0 = BpHook::Guards::GuardBash::_perl_test_run($cmd);
        is($r0, 0, 'AC-41 (spec AC-13, sec 3.2 item 2): cat notes.t + 2000 "; :" segments, no seam -> _perl_test_run returns 0');
    }
    {
        local %ENV = %ENV;
        $ENV{BP_GUARD_DEADLINE_SECONDS} = '0.000001';
        my $r1 = BpHook::Guards::GuardBash::_perl_test_run($cmd);
        is($r1, 1, 'AC-41 (spec AC-13, sec 3.2 item 2): same command, tiny BP_GUARD_DEADLINE_SECONDS -> _perl_test_run returns 1 (fail closed; today: 0)');
    }

    my $sid = 'ac41-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-41');

    my $res_seam = gb(payload(cmd => $cmd, session_id => $sid),
        CCPRAXIS_DATA_DIR => $data_n, BP_GUARD_DEADLINE_SECONDS => '0.000001');
    is($res_seam->{rc}, 2, 'AC-41 (spec AC-13, sec 3.2 item 3): with the seam and a live writer -> deny through the interlock (today: allow)')
        or diag("err: $res_seam->{err}");
    like($res_seam->{err}, qr/validation interlock/, 'AC-41 (spec AC-13, sec 3.2 item 3): the deny names the validation interlock');

    my $res_noseam = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res_noseam->{rc}, 0, 'AC-41 (spec AC-13, sec 3.2 item 3): without the seam, the same command and live writer -> allow');
}

# ===========================================================================
# AC-42 (spec AC-15, sec 3.14, Decision 38) -- an expansion script word whose
# OWN raw text does not end in .t and is not exactly $NAME/${NAME} resolved
# to a .t-/runner-shaped value must not count as a test run merely because
# the command mentions ".t" somewhere else (e.g. inside a --text value).
# ===========================================================================
{
    my $sid = 'ac42-sid';
    my $data_n = setup_disjoint_b($sid);
    assert_live_writer_precondition($data_n, $sid, 'AC-42');

    my @allow_rows = (
        [ q{perl "$S" add-decision --file X --text "see plugins/butler/tests/t/foo.t"} => q{quoted $S with no NAME=value for S anywhere; the .t text is only inside --text} ],
        [ q{perl $S note --text plugins/butler/tests/t/foo.t}                          => q{bare $S with no NAME=value for S anywhere; the .t text is only a later operand} ],
        [ q{S=plugins/butler/scripts/bp-blueprint.pl; perl "$S" note --text "x.t"}     => q{NAME=value gives S a non-.t-/non-runner-shaped value (bp-blueprint.pl)} ],
    );
    for my $r (@allow_rows) {
        my ($cmd, $label) = @$r;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 0, "AC-42 (spec AC-15, sec 3.14): $label -> allow (today: denied by mention alone)") or diag("cmd: $cmd");
    }

    my @deny_rows = (
        [ q{D=plugins/fx/tests/t; perl "$D/alpha.t"}                        => q{the script word's OWN raw text "$D/alpha.t" ends in .t (quotes stripped), independent of D's value -> rule (a)} ],
        [ q{R=scripts/run-tests.pl; perl "$R" plugins/fx/tests/t/alpha.t}   => q{script word is exactly "$R"; NAME=value gives R a runner-shaped value -> rule (b)} ],
        # New pin (never-halt 09-gb-h-residuals, SHOULD-FIX): a segment's
        # leading-assignment walk must check EVERY leading "NAME=value" word,
        # not just the first. Here "X=1" is the first leading assignment and
        # "S=plugins/fx/tests/t/a.t" is the second; before the fix only X=1
        # was checked (and X has no bearing on the script word "$S"), so S's
        # value was never consulted and this slipped through as allowed.
        [ q{X=1 S=plugins/fx/tests/t/a.t; perl "$S"}                        => q{second leading NAME=value word (S) gives the script word "$S" a .t-shaped value -> rule (b)} ],
    );
    for my $r (@deny_rows) {
        my ($cmd, $label) = @$r;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 2, "AC-42 (spec AC-15, sec 3.14): $label -> deny (still a recognised test run)") or diag("cmd: $cmd");
    }
}

done_testing();
