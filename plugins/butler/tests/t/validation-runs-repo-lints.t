#!/usr/bin/env perl
# platform: any
# Oracle for blueprint tooling-fixes, package 07 (ledger-scoped validation
# also runs the three repo-wide lints). Derived from
# .ccpraxis-local-data/blueprints/tooling-fixes/specs/
# 07-validation-runs-repo-lints-spec.md sections 2-4 and the package
# ledger's done criteria (Decisions 15, 17, 29). None of the lint-mode
# behaviour under test (@REPO_LINTS, _lint_root(), the collection/HEAD-
# comparison/report logic) exists yet in scripts/run-tests.pl at write time:
# every lint-mode assertion below is expected to fail for that reason
# (missing behaviour, not a harness defect) until the implementer lands it.
#
# Every runner invocation goes through RunnerStateHarness::run_runner_bounded
# against a File::Temp fixture tree AND a separate File::Temp git repo (the
# "lint root", pointed at via CCPRAXIS_TEST_LINT_ROOT) -- never the real repo
# tree. Lint fixtures are raw TAP printed with print+exit, in the same style
# as RunnerStateHarness::red_source, with an absolute counter-file path baked
# in as a literal string (never derived from the fixture's own __FILE__).
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec ();
use File::Temp qw(tempdir);
use Config;

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use RunnerStateHarness qw(
    repo_root
    make_fixture_tree green_source
    state_file_path write_state_file read_state_file slurp_raw
    relpath_from_root
    run_runner_bounded
);

my $BOUND = 150;   # seconds; spec requires at least 120s per invocation

my @LINT_BASENAMES = qw(
    test-naming-hygiene.t
    tests-never-run-tests.t
    turn-cap-consistency.t
);

# ---------------------------------------------------------------------------
# generic fixture / git helpers
# ---------------------------------------------------------------------------

# tempdir_n() -- a fresh tempdir with forward-slash separators, matching the
# convention CCPRAXIS_TEST_LINT_ROOT/CCPRAXIS_TEST_STATE_DIR are used with
# elsewhere in this suite (runner-ledger-flag.t's tempdir_n()).
sub tempdir_n {
    my $t = tempdir(CLEANUP => 1);
    (my $n = $t) =~ s{\\}{/}g;
    return $n;
}

sub fwd { my ($p) = @_; (my $n = $p) =~ s{\\}{/}g; return $n }

sub git_init_commit {
    my ($root) = @_;
    system('git', '-C', $root, 'init', '-q') == 0
        or die "git init failed in $root";
    system('git', '-C', $root, 'add', '-A') == 0
        or die "git add failed in $root";
    system('git', '-C', $root, '-c', 'user.name=t', '-c', 'user.email=t@t',
           'commit', '-qm', 'base') == 0
        or die "git commit failed in $root";
}

sub git_capture {
    my ($root, @args) = @_;
    open(my $fh, '-|', 'git', '-C', $root, @args) or die "cannot run git: $!";
    local $/;
    my $out = <$fh>;
    close $fh;
    return defined($out) ? $out : '';
}

sub write_lint_file {
    my ($root, $name, $content) = @_;
    my $dir = "$root/plugins/butler/tests/t";
    make_path($dir);
    my $path = "$dir/$name";
    open(my $fh, '>:raw', $path) or die "cannot write $path: $!";
    print {$fh} $content;
    close $fh;
    return $path;
}

sub lint_path_for { my ($root, $name) = @_; return "$root/plugins/butler/tests/t/$name" }

# lint_src(%o) -- raw TAP fixture source, in red_source()'s own style
# (print+exit, deterministic rc/notok). counter => an absolute path outside
# the lint root; the fixture appends "$0\n" to it at runtime (never derives
# a directory from its own __FILE__). env_probe_counter => a second, mutually
# exclusive absolute path the fixture writes
# "defined $ENV{CCPRAXIS_TEST_LINT_ROOT} ? 1 : 0" to (AC-17).
sub lint_src {
    my (%o) = @_;
    my $src = "#!/usr/bin/env perl\n# platform: any\n";
    if (defined $o{counter}) {
        my $esc = fwd($o{counter});
        $esc =~ s/(['\\])/\\$1/g;
        $src .= "open(my \$fh, '>>', '$esc') or die \$!; print {\$fh} \"\$0\\n\"; close \$fh;\n";
    }
    if (defined $o{env_probe_counter}) {
        my $esc = fwd($o{env_probe_counter});
        $esc =~ s/(['\\])/\\$1/g;
        $src .= "open(my \$fh2, '>>', '$esc') or die \$!; "
              . "print {\$fh2} ((defined \$ENV{CCPRAXIS_TEST_LINT_ROOT}) ? \"1\\n\" : \"0\\n\"); close \$fh2;\n";
    }
    my @lines = @{ $o{lines} // ['ok 1 - fixture pass'] };
    for my $l (@lines) {
        $src .= 'print "' . $l . '\n";' . "\n";
    }
    $src .= 'exit ' . (defined $o{exit} ? $o{exit} : 0) . ";\n";
    return $src;
}

# make_lint_root_with($counters_dir, %overrides) -> $root
# A committed git repo holding all three lints, green by default; %overrides
# maps a basename to a lint_src()-style hashref (minus "counter", which is
# supplied automatically) for the ones that should differ.
sub make_lint_root_with {
    my ($counters_dir, %overrides) = @_;
    my $root = tempdir_n();
    for my $name (@LINT_BASENAMES) {
        my $counter = "$counters_dir/$name.counter";
        my $args = $overrides{$name} // { lines => ['ok 1 - fixture pass'], exit => 0 };
        write_lint_file($root, $name, lint_src(%$args, counter => $counter));
    }
    git_init_commit($root);
    return $root;
}

sub counter_lines {
    my ($path) = @_;
    return 0 unless -f $path;
    my $raw = slurp_raw($path) // '';
    return 0 unless length $raw;
    return scalar(split /\n/, $raw);
}

# line_after_match($out, $needle) -- the line immediately following the
# first line of $out that contains $needle as a plain substring.
sub line_after_match {
    my ($out, $needle) = @_;
    my @lines = split /\n/, $out;
    for my $i (0 .. $#lines) {
        return $lines[$i + 1] if index($lines[$i], $needle) >= 0;
    }
    return undef;
}

# a ready target + ledger pair: one green fixture .t, used as both the
# runner's positional target and its --ledger value (same convention as
# runner-ledger-flag.t AC-1 -- the value only needs to exist as a file).
sub green_target {
    my $fixture = make_fixture_tree('quick-green.t' => green_source());
    my $ledger_path = File::Spec->catfile($fixture, 'tests', 't', 'quick-green.t');
    return ($fixture, $ledger_path);
}

# =============================================================================
# AC-1 -- three green lints, --ledger L <target>: rc 0, 4 files, one repo
# lints line (naming all three basenames, in order, with the root) after the
# ledger line; each counter holds exactly one line.
# =============================================================================
{
    my $counters_dir = tempdir_n();
    my $lint_root = make_lint_root_with($counters_dir);
    my ($fixture, $ledger_path) = green_target();
    my $state_dir = tempdir(CLEANUP => 1);

    my $res = run_runner_bounded(
        args    => ['--ledger', $ledger_path, $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC-1: three green lints, --ledger L <target> -> rc 0') or diag($res->{out} . $res->{err});
    like($res->{out}, qr/^4 files/m, 'AC-1: N files is 4 (target + three lints)');

    my $expected_line = 'repo lints: ' . join(' ', @LINT_BASENAMES) . " (root: $lint_root)";
    my @matches = grep { $_ eq $expected_line } split /\n/, $res->{out};
    is(scalar(@matches), 1, 'AC-1: exactly one repo lints line, naming the basenames in order and the lint root')
        or diag($res->{out});

    my $ledger_idx = index($res->{out}, "ledger: $ledger_path");
    my $lints_idx  = index($res->{out}, $expected_line);
    ok($ledger_idx >= 0 && $lints_idx > $ledger_idx, 'AC-1: the repo lints line comes after the ledger: line');

    for my $name (@LINT_BASENAMES) {
        is(counter_lines("$counters_dir/$name.counter"), 1, "AC-1: $name ran exactly once");
    }
}

# =============================================================================
# AC-2 -- as AC-1, plus the absolute path of one fixture lint as a second
# target: still 4 files (no duplicate), that lint's counter still holds 1
# line.
# =============================================================================
{
    my $counters_dir = tempdir_n();
    my $lint_root = make_lint_root_with($counters_dir);
    my ($fixture, $ledger_path) = green_target();
    my $state_dir = tempdir(CLEANUP => 1);
    my $one_lint = lint_path_for($lint_root, $LINT_BASENAMES[0]);

    my $res = run_runner_bounded(
        args    => ['--ledger', $ledger_path, $fixture, $one_lint],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC-2: rc 0') or diag($res->{out} . $res->{err});
    like($res->{out}, qr/^4 files/m, 'AC-2: an explicit duplicate target does not add a 5th file');
    is(counter_lines("$counters_dir/$LINT_BASENAMES[0].counter"), 1, 'AC-2: the duplicated lint still ran exactly once');
}

# =============================================================================
# AC-3 -- as AC-1, plus the lint root's plugins/butler directory as a second
# target (selecting all three lints already): still 4 files, each counter
# holds 1 line.
# =============================================================================
{
    my $counters_dir = tempdir_n();
    my $lint_root = make_lint_root_with($counters_dir);
    my ($fixture, $ledger_path) = green_target();
    my $state_dir = tempdir(CLEANUP => 1);
    my $plugin_dir = "$lint_root/plugins/butler";

    my $res = run_runner_bounded(
        args    => ['--ledger', $ledger_path, $fixture, $plugin_dir],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC-3: rc 0') or diag($res->{out} . $res->{err});
    like($res->{out}, qr/^4 files/m, 'AC-3: a directory target already selecting all three lints still yields 4 files');
    for my $name (@LINT_BASENAMES) {
        is(counter_lines("$counters_dir/$name.counter"), 1, "AC-3: $name ran exactly once despite the dir-target overlap");
    }
}

# =============================================================================
# AC-4 -- the AC-1 fixture without --ledger: rc 0, 1 files, no repo lints
# line, every counter empty.
# =============================================================================
{
    my $counters_dir = tempdir_n();
    my $lint_root = make_lint_root_with($counters_dir);
    my ($fixture, undef) = green_target();
    my $state_dir = tempdir(CLEANUP => 1);

    my $res = run_runner_bounded(
        args    => [$fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC-4: no --ledger -> rc 0') or diag($res->{out} . $res->{err});
    like($res->{out}, qr/^1 files/m, 'AC-4: no --ledger -> only the one target runs');
    unlike($res->{out}, qr/^repo lints:/m, 'AC-4: no repo lints line without --ledger');
    for my $name (@LINT_BASENAMES) {
        is(counter_lines("$counters_dir/$name.counter"), 0, "AC-4: $name never ran");
    }
}

# =============================================================================
# AC-5 -- the AC-4 run with BP_VALIDATE_LEDGER set in the env (no --ledger
# flag): identical to AC-4 -- the env var alone has no effect.
# =============================================================================
{
    my $counters_dir = tempdir_n();
    my $lint_root = make_lint_root_with($counters_dir);
    my ($fixture, $ledger_path) = green_target();
    my $state_dir = tempdir(CLEANUP => 1);

    my $res = run_runner_bounded(
        args    => [$fixture],
        env     => {
            CCPRAXIS_TEST_STATE_DIR => $state_dir,
            CCPRAXIS_TEST_LINT_ROOT => $lint_root,
            BP_VALIDATE_LEDGER      => $ledger_path,
        },
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC-5: BP_VALIDATE_LEDGER in env, no --ledger -> rc 0') or diag($res->{out} . $res->{err});
    like($res->{out}, qr/^1 files/m, 'AC-5: BP_VALIDATE_LEDGER alone still runs only the one target');
    unlike($res->{out}, qr/^repo lints:/m, 'AC-5: BP_VALIDATE_LEDGER alone triggers no repo lints line');
    for my $name (@LINT_BASENAMES) {
        is(counter_lines("$counters_dir/$name.counter"), 0, "AC-5: $name never ran");
    }
}

# =============================================================================
# AC-6 -- a lint green at HEAD, red in the working tree (uncommitted edit):
# rc 1; RED list names it; next line is the "not red at HEAD" attribution;
# no "pre-existing" text anywhere.
# =============================================================================
{
    my $counters_dir = tempdir_n();
    my $lint_root = make_lint_root_with($counters_dir);
    my $target_name = $LINT_BASENAMES[0];
    my $lint_path = lint_path_for($lint_root, $target_name);
    my $counter = "$counters_dir/$target_name.counter";
    open(my $fh, '>:raw', $lint_path) or die $!;
    print {$fh} lint_src(counter => $counter, lines => ['not ok 1 - R1 fixture', '# offender: alpha'], exit => 1);
    close $fh;

    my ($fixture, $ledger_path) = green_target();
    my $state_dir = tempdir(CLEANUP => 1);
    my $res = run_runner_bounded(
        args    => ['--ledger', $ledger_path, $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 1, 'AC-6: lint green at HEAD, red in the working tree -> rc 1') or diag($res->{out} . $res->{err});
    like($res->{out}, qr/\Q$lint_path\E/, 'AC-6: the RED list names the lint');
    is(line_after_match($res->{out}, $lint_path),
        'repo lint: attributed to this change (not red at HEAD)', 'AC-6: attributed, not red at HEAD');
    unlike($res->{out}, qr/pre-existing/i, 'AC-6: no pre-existing text anywhere');
}

# =============================================================================
# AC-7 -- a lint red at HEAD and unchanged: rc 0; the pre-existing
# annotation; the pre-existing-count summary line; no "all green".
# =============================================================================
{
    my $counters_dir = tempdir_n();
    my $target_name = $LINT_BASENAMES[1];
    my $lint_root = make_lint_root_with($counters_dir,
        $target_name => { lines => ['not ok 1 - R1 fixture', '# offender: alpha'], exit => 1 });
    my $lint_path = lint_path_for($lint_root, $target_name);

    my ($fixture, $ledger_path) = green_target();
    my $state_dir = tempdir(CLEANUP => 1);
    my $res = run_runner_bounded(
        args    => ['--ledger', $ledger_path, $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC-7: a pre-existing red lint does not count in the exit code') or diag($res->{out} . $res->{err});
    is(line_after_match($res->{out}, $lint_path),
        'repo lint: pre-existing (fails identically at HEAD); not counted', 'AC-7: pre-existing annotation line');
    like($res->{out}, qr/^pre-existing lint reds: 1 \(not counted in the exit code\)$/m, 'AC-7: pre-existing summary line');
    unlike($res->{out}, qr/^all green$/m, 'AC-7: "all green" is absent');
}

# =============================================================================
# AC-8 -- HEAD red with "alpha" only; working tree red with "alpha" plus a
# new "beta" line: rc 1; attributed (new failure lines vs HEAD); beta printed
# as a new-vs-HEAD line; alpha is not.
# =============================================================================
{
    my $counters_dir = tempdir_n();
    my $target_name = $LINT_BASENAMES[2];
    my $lint_root = make_lint_root_with($counters_dir,
        $target_name => { lines => ['not ok 1 - R1 fixture', '# offender: alpha'], exit => 1 });
    my $lint_path = lint_path_for($lint_root, $target_name);
    my $counter = "$counters_dir/$target_name.counter";
    open(my $fh, '>:raw', $lint_path) or die $!;
    print {$fh} lint_src(counter => $counter,
        lines => ['not ok 1 - R1 fixture', '# offender: alpha', '# offender: beta'], exit => 1);
    close $fh;

    my ($fixture, $ledger_path) = green_target();
    my $state_dir = tempdir(CLEANUP => 1);
    my $res = run_runner_bounded(
        args    => ['--ledger', $ledger_path, $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 1, 'AC-8: a new failure line vs HEAD -> attributed, rc 1') or diag($res->{out} . $res->{err});
    my $next = line_after_match($res->{out}, $lint_path);
    like(defined($next) ? $next : '', qr/^repo lint: attributed to this change \(new failure lines vs HEAD\)$/,
        'AC-8: attributed with the new-failure-lines reason');
    like($res->{out}, qr/new vs HEAD: # offender: beta/, 'AC-8: beta is printed as a new line vs HEAD');
    unlike($res->{out}, qr/new vs HEAD: # offender: alpha/, 'AC-8: alpha is not printed as new (it already existed at HEAD)');
}

# =============================================================================
# AC-9 -- HEAD red with alpha+beta and a 2-of-2 "Looks like" line; working
# tree red with alpha only, renumbered, 1-of-1 "Looks like" line: a subset ->
# pre-existing, rc 0.
# =============================================================================
{
    my $counters_dir = tempdir_n();
    my $target_name = $LINT_BASENAMES[0];
    my $lint_root = make_lint_root_with($counters_dir,
        $target_name => { lines => [
            'not ok 1 - R1 fixture', '# offender: alpha',
            'not ok 2 - R1 fixture', '# offender: beta',
            '# Looks like you failed 2 tests of 2.',
        ], exit => 1 });
    my $lint_path = lint_path_for($lint_root, $target_name);
    my $counter = "$counters_dir/$target_name.counter";
    open(my $fh, '>:raw', $lint_path) or die $!;
    print {$fh} lint_src(counter => $counter, lines => [
        'not ok 7 - R1 fixture', '# offender: alpha',
        '# Looks like you failed 1 test of 1.',
    ], exit => 1);
    close $fh;

    my ($fixture, $ledger_path) = green_target();
    my $state_dir = tempdir(CLEANUP => 1);
    my $res = run_runner_bounded(
        args    => ['--ledger', $ledger_path, $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC-9: a smaller failure subset of HEAD -> pre-existing, rc 0') or diag($res->{out} . $res->{err});
    is(line_after_match($res->{out}, $lint_path),
        'repo lint: pre-existing (fails identically at HEAD); not counted', 'AC-9: pre-existing annotation');
}

# =============================================================================
# AC-10 -- HEAD and working-tree lint both print "# at $0" and are otherwise
# identical and red: pre-existing, rc 0 (root normalisation -- the two runs'
# absolute $0 values differ only by root).
# =============================================================================
{
    my $counters_dir = tempdir_n();
    my $target_name = $LINT_BASENAMES[1];
    my $lint_root = make_lint_root_with($counters_dir,
        $target_name => { lines => ['not ok 1 - R1 fixture', '# at $0'], exit => 1 });
    my $lint_path = lint_path_for($lint_root, $target_name);
    # no working-tree edit: content is identical at HEAD and in the working
    # tree; only the interpolated $0 differs, by construction, between the
    # working-tree run and the HEAD-snapshot run.

    my ($fixture, $ledger_path) = green_target();
    my $state_dir = tempdir(CLEANUP => 1);
    my $res = run_runner_bounded(
        args    => ['--ledger', $ledger_path, $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC-10: $0 differing only by root is normalised away -> pre-existing, rc 0')
        or diag($res->{out} . $res->{err});
    is(line_after_match($res->{out}, $lint_path),
        'repo lint: pre-existing (fails identically at HEAD); not counted',
        'AC-10: pre-existing despite each run printing its own root-qualified $0');
}

# =============================================================================
# AC-11 -- lint root is a plain directory, not a git repo, one lint red: rc
# 1; the "HEAD comparison unavailable:" attribution prefix.
# =============================================================================
{
    my $counters_dir = tempdir_n();
    my $lint_root = tempdir_n();   # deliberately: no git init
    for my $name (@LINT_BASENAMES) {
        my $counter = "$counters_dir/$name.counter";
        if ($name eq $LINT_BASENAMES[0]) {
            write_lint_file($lint_root, $name,
                lint_src(counter => $counter, lines => ['not ok 1 - R1 fixture', '# offender: alpha'], exit => 1));
        } else {
            write_lint_file($lint_root, $name, lint_src(counter => $counter, lines => ['ok 1 - fixture pass'], exit => 0));
        }
    }
    my $lint_path = lint_path_for($lint_root, $LINT_BASENAMES[0]);

    my ($fixture, $ledger_path) = green_target();
    my $state_dir = tempdir(CLEANUP => 1);
    my $res = run_runner_bounded(
        args    => ['--ledger', $ledger_path, $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 1, 'AC-11: lint root is not a git repo, one lint red -> rc 1') or diag($res->{out} . $res->{err});
    my $next = line_after_match($res->{out}, $lint_path);
    like(defined($next) ? $next : '', qr/^repo lint: attributed to this change \(HEAD comparison unavailable: /,
        'AC-11: HEAD-unavailable attribution prefix');
}

# =============================================================================
# AC-12 -- one red lint untracked in the lint root (the other two
# committed): rc 1; attributed (not present at HEAD).
# =============================================================================
{
    my $counters_dir = tempdir_n();
    my $target_name = $LINT_BASENAMES[2];
    my $lint_root = tempdir_n();
    for my $name (@LINT_BASENAMES) {
        next if $name eq $target_name;
        write_lint_file($lint_root, $name,
            lint_src(counter => "$counters_dir/$name.counter", lines => ['ok 1 - fixture pass'], exit => 0));
    }
    git_init_commit($lint_root);
    # added AFTER the base commit, never git-added: untracked at HEAD.
    write_lint_file($lint_root, $target_name,
        lint_src(counter => "$counters_dir/$target_name.counter",
            lines => ['not ok 1 - R1 fixture', '# offender: alpha'], exit => 1));
    my $lint_path = lint_path_for($lint_root, $target_name);

    my ($fixture, $ledger_path) = green_target();
    my $state_dir = tempdir(CLEANUP => 1);
    my $res = run_runner_bounded(
        args    => ['--ledger', $ledger_path, $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 1, 'AC-12: untracked red lint -> rc 1') or diag($res->{out} . $res->{err});
    is(line_after_match($res->{out}, $lint_path),
        'repo lint: attributed to this change (not present at HEAD)', 'AC-12: not-present-at-HEAD attribution');
}

# =============================================================================
# AC-13 -- one lint file absent from the lint root entirely: rc >= 1; the
# missing-lint diagnostic; 4 files; the other two counters each hold 1 line.
# =============================================================================
{
    my $counters_dir = tempdir_n();
    my $missing_name = $LINT_BASENAMES[0];
    my $lint_root = tempdir_n();
    for my $name (@LINT_BASENAMES) {
        next if $name eq $missing_name;   # deliberately never written
        write_lint_file($lint_root, $name,
            lint_src(counter => "$counters_dir/$name.counter", lines => ['ok 1 - fixture pass'], exit => 0));
    }
    git_init_commit($lint_root);

    my ($fixture, $ledger_path) = green_target();
    my $state_dir = tempdir(CLEANUP => 1);
    my $res = run_runner_bounded(
        args    => ['--ledger', $ledger_path, $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    ok($res->{rc} >= 1, 'AC-13: a missing lint -> rc >= 1') or diag($res->{out} . $res->{err});
    like($res->{out}, qr/REPO LINT MISSING: plugins\/butler\/tests\/t\/\Q$missing_name\E/,
        'AC-13: the missing-lint diagnostic names the relpath');
    like($res->{out}, qr/^4 files/m, 'AC-13: the missing lint still counts as a file');
    for my $name (@LINT_BASENAMES) {
        next if $name eq $missing_name;
        is(counter_lines("$counters_dir/$name.counter"), 1, "AC-13: $name still ran once");
    }
}

# =============================================================================
# AC-14 -- around an AC-7-shaped run: the lint root's git status/HEAD are
# byte-identical before and after; .git/worktrees does not exist afterwards.
# =============================================================================
{
    my $counters_dir = tempdir_n();
    my $target_name = $LINT_BASENAMES[1];
    my $lint_root = make_lint_root_with($counters_dir,
        $target_name => { lines => ['not ok 1 - R1 fixture', '# offender: alpha'], exit => 1 });

    my $status_before = git_capture($lint_root, 'status', '--porcelain');
    my $head_before    = git_capture($lint_root, 'rev-parse', 'HEAD');

    my ($fixture, $ledger_path) = green_target();
    my $state_dir = tempdir(CLEANUP => 1);
    my $res = run_runner_bounded(
        args    => ['--ledger', $ledger_path, $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC-14 setup: pre-existing red lint, rc 0') or diag($res->{out} . $res->{err});

    my $status_after = git_capture($lint_root, 'status', '--porcelain');
    my $head_after    = git_capture($lint_root, 'rev-parse', 'HEAD');
    is($status_after, $status_before, 'AC-14: git status --porcelain is byte-identical before/after the HEAD comparison');
    is($head_after, $head_before, 'AC-14: HEAD is byte-identical before/after');
    ok(!-d "$lint_root/.git/worktrees", 'AC-14: .git/worktrees does not exist afterwards');
}

# =============================================================================
# AC-15 -- around the AC-7 shape: last-failures.txt names the red lint; its
# counter holds exactly 2 lines (working-tree run + HEAD-snapshot run), only
# one of which is under the lint root; neither last-failures.txt nor
# durations.tsv names the other (HEAD-snapshot) path.
# =============================================================================
{
    my $counters_dir = tempdir_n();
    my $target_name = $LINT_BASENAMES[2];
    my $lint_root = make_lint_root_with($counters_dir,
        $target_name => { lines => ['not ok 1 - R1 fixture', '# offender: alpha'], exit => 1 });

    my ($fixture, $ledger_path) = green_target();
    my $state_dir = tempdir(CLEANUP => 1);
    my $res = run_runner_bounded(
        args    => ['--ledger', $ledger_path, $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC-15 setup: pre-existing red lint, rc 0') or diag($res->{out} . $res->{err});

    my @entries = read_state_file($state_dir);
    ok((grep { /plugins\/butler\/tests\/t\/\Q$target_name\E$/ } @entries),
        q{AC-15: last-failures.txt has an entry ending in the red lint's relpath});

    my $counter = "$counters_dir/$target_name.counter";
    my @lines = split /\n/, (slurp_raw($counter) // '');
    is(scalar(@lines), 2, 'AC-15: the red lint ran exactly twice (working tree + HEAD copy)');
    my @under_root = grep { index($_, $lint_root) == 0 } @lines;
    my @not_under  = grep { index($_, $lint_root) != 0 } @lines;
    is(scalar(@under_root), 1, 'AC-15: exactly one counter line is under the lint root (the working-tree run)')
        or diag(join("\n", @lines));
    is(scalar(@not_under), 1, 'AC-15: exactly one counter line is NOT under the lint root (the HEAD-snapshot run)')
        or diag(join("\n", @lines));

    SKIP: {
        skip('AC-15: no distinct HEAD-snapshot counter line to check against state files', 2)
            unless @not_under == 1;
        my $other_path = $not_under[0];
        my $tsv = slurp_raw("$state_dir/durations.tsv") // '';
        unlike($tsv, qr/\Q$other_path\E/, 'AC-15: durations.tsv never names the HEAD-snapshot path');
        my $last_failures_raw = slurp_raw(state_file_path($state_dir)) // '';
        unlike($last_failures_raw, qr/\Q$other_path\E/, 'AC-15: last-failures.txt never names the HEAD-snapshot path');
    }
}

# =============================================================================
# AC-16 -- --state=failed --ledger L also appends the lints (pre-seeded state
# -> 4 files); an empty state file still exits 0 with "no recorded failures"
# and runs no lint.
# =============================================================================
{
    my $counters_dir = tempdir_n();
    my $lint_root = make_lint_root_with($counters_dir);
    my ($fixture, $ledger_path) = green_target();
    my $target_path = File::Spec->catfile($fixture, 'tests', 't', 'quick-green.t');
    my $state_dir = tempdir(CLEANUP => 1);
    write_state_file($state_dir, relpath_from_root($target_path));

    my $res = run_runner_bounded(
        args    => ['--state=failed', '--ledger', $ledger_path],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC-16: pre-seeded state + --state=failed --ledger, green lints -> rc 0')
        or diag($res->{out} . $res->{err});
    like($res->{out}, qr/^4 files/m, 'AC-16: --state=failed also appends the lints');
}
{
    my $counters_dir = tempdir_n();
    my $lint_root = make_lint_root_with($counters_dir);
    my (undef, $ledger_path) = green_target();
    my $state_dir = tempdir(CLEANUP => 1);
    # deliberately no state file written: empty recorded state.

    my $res = run_runner_bounded(
        args    => ['--state=failed', '--ledger', $ledger_path],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC-16: empty state + --state=failed --ledger -> rc 0') or diag($res->{out} . $res->{err});
    like($res->{out}, qr/no recorded failures/, 'AC-16: "no recorded failures" early exit, before lints are considered');
    for my $name (@LINT_BASENAMES) {
        is(counter_lines("$counters_dir/$name.counter"), 0, "AC-16 (empty state): $name never ran");
    }
}

# =============================================================================
# AC-17 -- a fixture lint writes "defined $ENV{CCPRAXIS_TEST_LINT_ROOT} ? 1 :
# 0" to its counter: value is "0" -- the lint child never inherits the
# lint-root override.
# =============================================================================
{
    my $counters_dir = tempdir_n();
    my $probe_name = $LINT_BASENAMES[0];
    my $probe_counter = "$counters_dir/$probe_name.env-probe";
    my $lint_root = tempdir_n();
    for my $name (@LINT_BASENAMES) {
        if ($name eq $probe_name) {
            write_lint_file($lint_root, $name,
                lint_src(env_probe_counter => $probe_counter, lines => ['ok 1 - fixture pass'], exit => 0));
        } else {
            write_lint_file($lint_root, $name,
                lint_src(counter => "$counters_dir/$name.counter", lines => ['ok 1 - fixture pass'], exit => 0));
        }
    }
    git_init_commit($lint_root);

    my ($fixture, $ledger_path) = green_target();
    my $state_dir = tempdir(CLEANUP => 1);
    my $res = run_runner_bounded(
        args    => ['--ledger', $ledger_path, $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC-17 setup: all-green run, rc 0') or diag($res->{out} . $res->{err});
    my $probed = slurp_raw($probe_counter) // '';
    $probed =~ s/\s+\z//;
    is($probed, '0', 'AC-17: the lint child never sees CCPRAXIS_TEST_LINT_ROOT');
}

# =============================================================================
# AC-18 -- source check of scripts/run-tests.pl (read as text, never run):
# each of the three lint relpaths occurs exactly once outside comments; so
# does "our @REPO_LINTS".
# =============================================================================
{
    my $script_path = RunnerStateHarness::runner_script();
    ok(-f $script_path, 'AC-18 setup: scripts/run-tests.pl exists on disk');
    open(my $fh, '<', $script_path) or die "cannot read $script_path: $!";
    local $/;
    my $src = <$fh>;
    close $fh;
    my @kept = grep { !/^\s*#/ } split /\n/, $src;
    my $body = join("\n", @kept);
    for my $name (@LINT_BASENAMES) {
        my @hits = ($body =~ /\Qplugins\/butler\/tests\/t\/$name\E/g);
        is(scalar(@hits), 1, "AC-18: plugins/butler/tests/t/$name appears exactly once outside comments");
    }
    my @decl_hits = ($body =~ /\bour \@REPO_LINTS\b/g);
    is(scalar(@decl_hits), 1, 'AC-18: our @REPO_LINTS appears exactly once outside comments');
}

# =============================================================================
# AC-19 -- fix-batch H1 (red-team, step 7): under dispatch-fleet, a `wip(pkg):`
# checkpoint commit lands in the lint root's HEAD BEFORE this package's own
# lint comparison runs, so the comparison must resolve its baseline from
# refs/butler/baseline/<blueprint> (parsed off --ledger's own
# ".../blueprints/<bp>/packages/..." path shape) when that ref exists,
# falling back to walking HEAD back past wip(<pkg>): commits otherwise. Both
# halves are pinned here against a lint root where: (1) a commit is green and
# either ref-tagged as the baseline or is the sole non-wip ancestor, and (2) a
# `wip(...)`-prefixed commit ON TOP makes a lint red -- i.e. the regression is
# already committed into HEAD by the time the comparison fires, which is
# exactly the shape a bare-HEAD comparison could not tell apart from a
# genuinely pre-existing red. Before this fix, both cases below would compare
# the (red) working tree against bare HEAD -- itself the same red wip commit,
# with no uncommitted edits on top -- so the signatures would match and the
# regression would be misclassified "pre-existing" with exit code 0.
# =============================================================================

# ledger_path_for_blueprint($bp) -> $path -- a real file (so run-tests.pl's
# own `-f $LEDGER_PATH` gate accepts it) living under a
# ".../blueprints/<bp>/packages/..." directory shape, which is the only thing
# _ledger_blueprint() in run-tests.pl parses off a --ledger path.
sub ledger_path_for_blueprint {
    my ($bp) = @_;
    my $dir = tempdir_n();
    my $pkg_dir = "$dir/blueprints/$bp/packages";
    make_path($pkg_dir);
    my $path = "$pkg_dir/07-fixture.md";
    open(my $fh, '>', $path) or die "cannot write $path: $!";
    print {$fh} "fixture ledger, never read for content\n";
    close $fh;
    return $path;
}

# make_h1_lint_root($counters_dir, $target_name, $bp, $with_baseline_ref) ->
# $root -- a committed git repo: base commit has all three lints green; if
# $with_baseline_ref is true, refs/butler/baseline/$bp is pointed at that base
# commit; then a SECOND commit, subject "wip(testpkg): checkpoint" (matching
# bp-checkpoint.pl's own `wip(<pkg>): ...` shape), overwrites $target_name
# with a red fixture and is committed on top -- that second commit is HEAD,
# and the working tree matches it exactly (no further uncommitted edit).
sub make_h1_lint_root {
    my ($counters_dir, $target_name, $bp, $with_baseline_ref) = @_;
    my $root = tempdir_n();
    for my $name (@LINT_BASENAMES) {
        write_lint_file($root, $name,
            lint_src(counter => "$counters_dir/$name.counter", lines => ['ok 1 - fixture pass'], exit => 0));
    }
    git_init_commit($root);   # base commit: all three green
    my $baseline_sha = git_capture($root, 'rev-parse', 'HEAD');
    $baseline_sha =~ s/\s+\z//;
    if ($with_baseline_ref) {
        system('git', '-C', $root, 'update-ref', "refs/butler/baseline/$bp", $baseline_sha) == 0
            or die "update-ref failed in $root";
    }
    write_lint_file($root, $target_name,
        lint_src(counter => "$counters_dir/$target_name.counter",
            lines => ['not ok 1 - R1 fixture', '# offender: alpha'], exit => 1));
    system('git', '-C', $root, 'add', '-A') == 0 or die "git add failed in $root";
    system('git', '-C', $root, '-c', 'user.name=t', '-c', 'user.email=t@t',
           'commit', '-qm', 'wip(testpkg): checkpoint') == 0
        or die "git commit (wip) failed in $root";
    return $root;
}

# --- AC-19a: refs/butler/baseline/<bp> pre-seeded at the green base commit --
{
    my $counters_dir = tempdir_n();
    my $target_name  = $LINT_BASENAMES[0];
    my $bp           = 'fixtureA-with-ref';
    my $lint_root    = make_h1_lint_root($counters_dir, $target_name, $bp, 1);
    my $lint_path    = lint_path_for($lint_root, $target_name);
    my $ledger_path  = ledger_path_for_blueprint($bp);
    my ($fixture, undef) = green_target();
    my $state_dir = tempdir(CLEANUP => 1);

    my $res = run_runner_bounded(
        args    => ['--ledger', $ledger_path, $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 1,
        'AC-19a: baseline-ref present at the green base commit -> the wip-committed regression is rc 1, not hidden')
        or diag($res->{out} . $res->{err});
    is(line_after_match($res->{out}, $lint_path),
        'repo lint: attributed to this change (not red at HEAD)',
        'AC-19a: attributed against the baseline ref (green), never classified pre-existing');
    unlike($res->{out}, qr/pre-existing/i, 'AC-19a: no pre-existing text anywhere');
}

# --- AC-19b: same regression, NO refs/butler/baseline/<bp> ref -- fallback --
{
    my $counters_dir = tempdir_n();
    my $target_name  = $LINT_BASENAMES[1];
    my $bp           = 'fixtureA-no-ref';
    my $lint_root    = make_h1_lint_root($counters_dir, $target_name, $bp, 0);
    my $lint_path    = lint_path_for($lint_root, $target_name);
    my $ledger_path  = ledger_path_for_blueprint($bp);
    my ($fixture, undef) = green_target();
    my $state_dir = tempdir(CLEANUP => 1);

    my $res = run_runner_bounded(
        args    => ['--ledger', $ledger_path, $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir, CCPRAXIS_TEST_LINT_ROOT => $lint_root },
        timeout => $BOUND,
    );
    is($res->{rc}, 1,
        'AC-19b: no baseline ref -- walk-back-past-wip-commits still finds the green commit before the wip commit, rc 1')
        or diag($res->{out} . $res->{err});
    is(line_after_match($res->{out}, $lint_path),
        'repo lint: attributed to this change (not red at HEAD)',
        'AC-19b: attributed against the walked-back green commit, never classified pre-existing');
    unlike($res->{out}, qr/pre-existing/i, 'AC-19b: no pre-existing text anywhere');
}

# =============================================================================
# AC-20 -- fix-batch M2 (red-team, step 7): with
# CCPRAXIS_CONTAINER_LANE_ENABLED set, the 3 repo lints (all `# platform:
# any`) must still be force-routed to the host lane, never the container
# lane, regardless of the flag -- otherwise they would be compared against a
# CONTAINER's copy of a git ref instead of the real working tree, hiding a
# working-tree-only regression. The run's own positional target is written
# with `# platform: windows` (never container-eligible by marker alone) so
# the only container-eligible files in the whole selection are the 3 lints
# themselves -- the summary's "0 container" is unambiguous proof that none of
# them were routed there, not an accident of some OTHER file filling the
# container-count headline while the lints slip through unnoticed. Each
# lint's counter is also checked at exactly 1 (it genuinely executed; an
# infra-failure synthesis, e.g. from being routed to an unavailable container
# lane, would leave it at 0).
# =============================================================================
{
    my $counters_dir = tempdir_n();
    my $lint_root = make_lint_root_with($counters_dir);
    my $win_src = "#!/usr/bin/env perl\n# platform: windows\nprint \"ok 1 - fixture pass\\n\";\nexit 0;\n";
    my $fixture = make_fixture_tree('quick-green-win.t' => $win_src);
    my $ledger_path = File::Spec->catfile($fixture, 'tests', 't', 'quick-green-win.t');
    my $state_dir = tempdir(CLEANUP => 1);

    my $res = run_runner_bounded(
        args    => ['--ledger', $ledger_path, $fixture],
        env     => {
            CCPRAXIS_TEST_STATE_DIR => $state_dir,
            CCPRAXIS_TEST_LINT_ROOT => $lint_root,
            CCPRAXIS_CONTAINER_LANE_ENABLED => '1',
        },
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC-20: all-green run with the container lane enabled -> rc 0') or diag($res->{out} . $res->{err});
    like($res->{out}, qr/\(\d+ parallel at -j\d+, \d+ serial, 0 container\)/,
        'AC-20: the summary line shows 0 container files -- the 3 repo lints never reached the container lane');
    for my $name (@LINT_BASENAMES) {
        is(counter_lines("$counters_dir/$name.counter"), 1,
            "AC-20: $name genuinely executed once (not synthesized as a container-infra result)");
    }
}

done_testing();
