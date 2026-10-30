#!/usr/bin/env perl
# platform: host
# The oracle for the throwaway, capped run-mode that executes .t files inside
# the EXISTING sandbox image on the container's own overlay filesystem,
# rather than the launcher's bind mount. Spec:
#   .ccpraxis-local-data/blueprints/test-platform-split/specs/05-container-lane-spec.md
# Ledger done criteria: scripts/run-tests-container.pl (the implementation,
# not yet written when this file is authored) reuses the existing image
# without ever building; passes explicit --cpus/--memory caps; lands the
# tree on the container's own storage, not a bind mount; disposes of every
# container it creates (Decision 14's three separate obligations); preserves
# TAP/exit-code fidelity; and routes every container-side path through
# `sh -c`, never as a bare leading-slash argv element next to a native
# binary -- the MSYS2 rewrite that blinded the sandbox busy-lease probe for
# three weeks (see plugins/sandbox/tests/t/busy-lease-path-conversion.t).
#
# STRUCTURE (mirrors the spec's own Part A/B/C split):
#   Part A -- pure value-level assertions against the builder/rule subs.
#             Zero podman/container cost, zero cost even with no CLI at all.
#   Part B -- podman_bin()/image_present() probes only. Real subprocess,
#             never a container, never a build.
#   Part C -- live, in-container assertions. Opt-in only, behind
#             CCPRAXIS_CONTAINER_LANE_LIVE=1, so no unattended sweep (this
#             file runs under at least three different harnesses with no
#             shared "routine sweep" flag) ever touches podman by accident.
#
# Requiring the implementation file below runs no code beyond constant/sub
# definitions and %SIG/END registration (its own top-level statements are
# constants, use, and sub definitions only, per spec section 2.0) -- so this
# whole file, including Part A and B, costs nothing beyond a --version probe
# even when it runs under a harness with no --fast-equivalent exclusion at
# all (plugins/butler/tests/run-tests.pl).
#
# CLASSIFICATION (why this file is safe to leave un-tagged): calling
# podman_bin() below (Part B) puts the literal substring "podman_bin" in
# this file's own source, genuinely -- not decoratively -- which is what
# scripts/run-tests.pl's classifier keys on to route this file into the
# serial lane, away from the 6-way parallel lane where it would contend
# against one podman machine.
#
# MANDATORY VACUITY GATE (this blueprint's standing rule -- a wrong
# implementation has passed a whole oracle before, with both defects living
# in the oracle, not the code under test):
#   - The bare-leading-slash-outside-"sh -c" detector (criterion 6) is
#     exercised against a fabricated violating line AND a fabricated
#     already-safe line AND the one legitimate exception the spec names
#     (materialize_tree's host-side `exec('git', ...)` call).
#   - The "no quoted 'build' argv literal anywhere" detector (criterion 1)
#     is exercised against a fabricated violating line.
#   - orphan_container_names() carries its own built-in counter-fixture
#     shape: A15 is the case that fires, A16-A20 are five different reasons
#     it must NOT fire, so the rule cannot pass by never triggering.
#   - The A11-A13 sweep over build_extract_argv/build_test_exec_argv demands
#     exactly two arrays were actually swept, so it cannot pass over an
#     empty set.
#
# ORACLE TABLE (spec section 3.1/3.2/3.3), mapped to done criteria:
#   AC1 (reuse, never build)     -> the quoted-'build'-literal scan + its
#                                    counter-fixture, B2 (image_present on a
#                                    bogus tag), and the main()-source-order
#                                    check (image_present before
#                                    build_run_argv).
#   AC2 (caps, exact argv)       -> A6 (full is_deeply + explicit indices),
#                                    C2 (live -- caps actually applied).
#   AC3 (container-native fs)    -> C4/C5 (live, positive-and-negative pair).
#   AC4 (disposal, Decision 14)  -> A23 (handlers installed), C1+C10 (create-
#                                    then-remove, live), C11 (live -- a real
#                                    SIGTERM to a separate process actually
#                                    removes its container), A15-A21 plus the
#                                    main()-source-order check (the orphan
#                                    sweep runs before this run's own
#                                    container is created).
#   AC5 (TAP/exit fidelity)      -> A8/A13 (the sh -c payload shape), C7/C9
#                                    (live -- a genuinely green and a
#                                    genuinely red .t file round-trip).
#   AC6 (sh -c, never bare path) -> A7/A8/A11/A12/A13 (value-level) plus the
#                                    source-scan detector and its
#                                    counter-fixtures.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use POSIX ();
use Cwd qw(abs_path);
use File::Temp ();

use lib "$Bin/../lib";
use RunnerStateHarness qw(green_source red_source);

# ---------------------------------------------------------------------------
# The implementation does not exist yet at the time this oracle is written.
# Every assertion below is expected to fail for exactly this reason -- not a
# fixture fault -- until scripts/run-tests-container.pl is written from this
# file and the spec.
# ---------------------------------------------------------------------------
my $IMPL = "$Bin/../../../../scripts/run-tests-container.pl";
ok(-f $IMPL, 'scripts/run-tests-container.pl exists (the implementation this file is the oracle for)')
    or BAIL_OUT("$IMPL does not exist -- nothing else in this file can run until it is written");

my $SRC = do { local (@ARGV, $/) = ($IMPL); <> };

require $IMPL;

# Both this file and the required implementation are package main:: (neither
# declares `package`), so its `our` globals need re-declaring here under
# strict vars -- this is what the spec means by "calls build_run_argv(...),
# $CONTAINER_LANE_CPUS, etc. directly, unqualified, with no import step".
our ($IMAGE, $CONTAINER_LANE_CPUS, $CONTAINER_LANE_MEMORY, $CONTAINER_NAME_PREFIX, $NATIVE_TREE_ROOT);
our ($ACTIVE_CONTAINER_NAME, $ACTIVE_PODMAN_BIN);

my $REPO_ROOT = abs_path("$Bin/../../../..");

# =============================================================================
# PART A -- pure value-level assertions. Zero podman/container cost.
# =============================================================================

# --- A1-A5: the named constants ---------------------------------------------
is($IMAGE,                 'claude-sandbox:latest',       'A1: $IMAGE');
is($CONTAINER_LANE_CPUS,   '2',                           'A2: $CONTAINER_LANE_CPUS');
is($CONTAINER_LANE_MEMORY, '1536m',                       'A3: $CONTAINER_LANE_MEMORY');
is($CONTAINER_NAME_PREFIX, 'ccpraxis-container-lane-',    'A4: $CONTAINER_NAME_PREFIX');
is($NATIVE_TREE_ROOT,      '/root/ccpraxis-container-lane', 'A5: $NATIVE_TREE_ROOT');

# --- A6: build_run_argv -- the exact 13-element argv, caps at fixed indices -
# Criterion 2 is explicit: asserted by INSPECTING the argv, not by trusting a
# flag exists somewhere. is_deeply already does element-by-element exact
# matching; the explicit indexed checks below are redundant with it on
# purpose, so a future refactor that keeps is_deeply green but reorders
# elements (e.g. moving --entrypoint before --memory) cannot slip through
# unnoticed.
{
    my @argv = build_run_argv('podman', 'ccpraxis-container-lane-999-1');
    is_deeply(\@argv, [
        'podman', 'run', '-d', '--name', 'ccpraxis-container-lane-999-1',
        '--cpus', '2', '--memory', '1536m',
        '--entrypoint', 'sleep',
        'claude-sandbox:latest', 'infinity',
    ], 'A6: build_run_argv returns the exact 13-element argv, in order');
    is(scalar(@argv), 13, 'A6: build_run_argv returns exactly 13 elements');
    is($argv[5],  '--cpus',      'A6 (criterion 2): --cpus flag at index 5');
    is($argv[6],  '2',           'A6 (criterion 2): --cpus value "2" at index 6');
    is($argv[7],  '--memory',    'A6 (criterion 2): --memory flag at index 7');
    is($argv[8],  '1536m',       'A6 (criterion 2): --memory value "1536m" at index 8');
    is($argv[9],  '--entrypoint','A6: --entrypoint flag at index 9');
    is($argv[10], 'sleep',
        'A6: --entrypoint value is "sleep" -- pinned so a bare trailing '
      . '"sleep infinity" cannot regress silently. The image ENTRYPOINT is '
      . '/usr/local/bin/sandbox-heartbeat (Containerfile:288); without this '
      . 'override, "sleep infinity" would be passed as ARGUMENTS to the '
      . 'heartbeat, not run as a command -- a runtime break, not a review one.');
    is($argv[11], 'claude-sandbox:latest', 'A6: image at index 11');
    is($argv[12], 'infinity',              'A6: trailing "infinity" at index 12');
}

# --- A7/A8/A9/A10: the other pure builders -----------------------------------
my @extract_argv   = build_extract_argv('podman', 'ctr-1');
my @test_exec_argv = build_test_exec_argv('podman', 'ctr-1', 'plugins/butler/tests/t/foo.t');

is_deeply(\@extract_argv, [
    'podman', 'exec', '-i', 'ctr-1', 'sh', '-c',
    "mkdir -p '/root/ccpraxis-container-lane' && tar -x -C '/root/ccpraxis-container-lane'",
], 'A7: build_extract_argv returns the exact 7-element argv');
is(scalar(@extract_argv), 7, 'A7: build_extract_argv returns exactly 7 elements');

is_deeply(\@test_exec_argv, [
    'podman', 'exec', 'ctr-1', 'sh', '-c',
    "cd '/root/ccpraxis-container-lane' && perl 'plugins/butler/tests/t/foo.t' 2>&1",
], 'A8: build_test_exec_argv returns the exact 6-element argv');
is(scalar(@test_exec_argv), 6, 'A8: build_test_exec_argv returns exactly 6 elements');

is_deeply([build_rm_argv('podman', 'ctr-1')], ['podman', 'rm', '-f', 'ctr-1'],
    'A9: build_rm_argv returns the exact argv');

is_deeply([build_ps_argv('podman')], ['podman', 'ps', '-a', '--format', '{{.Names}}'],
    'A10: build_ps_argv returns the exact argv');

# --- A11-A13: swept over BOTH podman-exec-argv builders, not asserted twice
# by hand -- and the sweep itself demands it actually covered two arrays, so
# it cannot pass by iterating over nothing.
{
    my %argv_by_label = (
        'build_extract_argv'   => \@extract_argv,
        'build_test_exec_argv' => \@test_exec_argv,
    );
    my $swept = 0;
    for my $label (sort keys %argv_by_label) {
        $swept++;
        my @argv = @{ $argv_by_label{$label} };
        is($argv[-3], q{sh}, "A11: $label -- third-from-last element is sh");
        is($argv[-2], q{-c}, "A11: $label -- second-from-last element is -c");
        my @bad = grep { m{^/(?:tmp|root|home|etc|var|proc)/} } @argv[0 .. $#argv - 1];
        is(scalar(@bad), 0,
            "A12: $label -- no element except the last is a bare container-side path");
        like($argv[-1], qr{/root/ccpraxis-container-lane},
            "A13: $label -- the last element contains the native-tree-root literal "
          . "(proving the path is genuinely passed, just correctly embedded inside sh -c)");
    }
    is($swept, 2,
        'A11-A13 non-vacuity: both build_extract_argv and build_test_exec_argv were actually swept');
}

# --- A14: new_container_name() ----------------------------------------------
{
    my $n1 = new_container_name();
    like($n1, qr/\Accpraxis-container-lane-\Q$$\E-\d+\z/,
        'A14: new_container_name() matches the documented <prefix><pid>-<counter> shape');
    my $n2 = new_container_name();
    isnt($n1, $n2, 'A14: successive calls never collide (the counter increments)');
}

# --- A15-A21: orphan_container_names() -- the pure sweep rule ---------------
# A15 is the ONE case the rule must fire on; A16-A20 are five independent
# reasons it must NOT fire -- together this is its own counter-fixture,
# without which "always returns []" would trivially pass A16-A20 alone.
{
    my $P = $CONTAINER_NAME_PREFIX;

    is_deeply([orphan_container_names(["${P}12345-1"], sub { 0 })], ["${P}12345-1"],
        'A15: a dead-PID-named container of ours IS an orphan (the rule fires)');
    is_deeply([orphan_container_names(["${P}12345-1"], sub { 1 })], [],
        'A16: a live-PID-named container of ours is never reaped');
    is_deeply([orphan_container_names(["${P}$$-1"], sub { 0 })], [],
        'A17: our OWN pid is excluded even when the alive-probe claims it is dead');
    is_deeply([orphan_container_names(['claude-sandbox-test-1-1'], sub { 0 })], [],
        "A18: a different lane's own prefix (claude-sandbox-test-) is never touched");
    is_deeply([orphan_container_names(["${P}notapid-1"], sub { 0 })], [],
        'A19: a non-numeric pid segment does not match the pattern');
    is_deeply([orphan_container_names(["${P}123"], sub { 0 })], [],
        'A20: a pid with no trailing -<counter> suffix does not match the pattern');
    is_deeply([orphan_container_names([], sub { 0 })], [],
        'A21a: an empty names list produces no orphans and does not die');
    is_deeply([orphan_container_names(undef, sub { 0 })], [],
        'A21b: an undef names list produces no orphans and does not die');
}

# --- A22: sweep_orphan_containers() never dies, even against dead infra ------
{
    my @result = eval { sweep_orphan_containers('a-binary-that-certainly-does-not-exist-anywhere') };
    is($@, '', 'A22: sweep_orphan_containers never dies, even when the podman binary itself is bogus');
    is_deeply(\@result, [], 'A22: ... and returns an empty list when the underlying podman call fails');
}

# --- A23: signal handlers installed at require-time -------------------------
for my $sig (qw(INT TERM HUP)) {
    is(ref $SIG{$sig}, 'CODE', "A23: \$SIG{$sig} is a CODE ref immediately after require, before main() ever runs");
}

# --- A24: the structural sh-c regression guard (criterion 6) ----------------
# Refactored into a named sub, not inlined, specifically so the SAME detector
# can be run against the real source AND against fabricated counter-fixture
# lines below -- the non-vacuity requirement this blueprint treats as
# non-negotiable.
sub find_suspect_podman_exec_lines {
    my ($text) = @_;
    my @suspect;
    for my $line (split /\n/, $text) {
        next unless $line =~ /\bexec\s*\(/;             # a Perl exec(...) call
        next unless $line =~ /['"]exec['"]/;             # ...building a podman/docker "exec" subcommand argv
        next if $line =~ /'sh',\s*'-c'/ || $line =~ /"sh",\s*"-c"/;  # already wrapped
        push @suspect, $line if $line =~ m{['"]/(?:tmp|root|home|etc|var|proc)/};
    }
    return @suspect;
}

{
    my @suspect = find_suspect_podman_exec_lines($SRC);
    is(scalar(@suspect), 0,
        'A24: no podman-exec call site in the implementation passes a bare container-side path outside sh -c')
        or diag("conversion-vulnerable call site(s):\n  " . join("\n  ", @suspect));
}

# A24 counter-fixtures -- prove the detector is a real predicate, not a
# tautology that would "pass" over any input.
{
    my @fires_on_violation = find_suspect_podman_exec_lines(
        q{    exec($podman, 'exec', $name, '/tmp/evil-bare-path');}
    );
    is(scalar(@fires_on_violation), 1,
        'A24 counter-fixture: the detector DOES fire on a fabricated bare leading-slash argv element');

    my @silent_on_wrapped = find_suspect_podman_exec_lines(
        q{    exec($podman, 'exec', '-i', $name, 'sh', '-c', "mkdir -p '/root/x'");}
    );
    is(scalar(@silent_on_wrapped), 0,
        'A24 counter-fixture: a properly sh -c-wrapped call site is correctly NOT flagged');

    # The one legitimate exception the spec names by name: materialize_tree's
    # HOST-side `exec('git', ...)` line has no quoted 'exec' SUBCOMMAND
    # literal in it (it is Perl's exec() builtin invoking git-archive on the
    # host, never a podman/docker exec argv), so the second filter excludes
    # it correctly rather than by accident.
    my @git_exec_excluded = find_suspect_podman_exec_lines(
        q{        exec('git', '-C', $project_root, 'archive', $ref) or POSIX::_exit(127);}
    );
    is(scalar(@git_exec_excluded), 0,
        "A24 counter-fixture: materialize_tree's host-side exec('git', ...) line is correctly excluded, not a false positive");
}

# --- Criterion 1 (AC1): no podman build call, ever --------------------------
# A source-wide scan for the exact quoted string literal 'build' or "build"
# (an argv element, not English prose) -- deliberately narrower than a bare
# \bbuild\b scan, which would also flag the spec's own justification prose
# (borrowed into this file's comments/diagnostics) and sub names like
# build_run_argv. Refactored into a sub for the same non-vacuity reason as
# A24 above.
sub find_quoted_build_literals {
    my ($text) = @_;
    my @hits = ($text =~ /(['"])build\1/g);
    return scalar(@hits);
}

is(find_quoted_build_literals($SRC), 0,
    q{AC1: no quoted 'build' string literal appears anywhere in the implementation -- }
  . 'podman build is never constructed as an argv element, not even conditionally');

is(find_quoted_build_literals(q{ my @a = ($PODMAN, 'build', '-t', $IMAGE, $CTX); }), 1,
    "AC1 counter-fixture: the quoted-'build'-literal detector DOES fire on a fabricated podman-build call");

is(find_quoted_build_literals(q{ push @args, '--build-arg', "X=1"; }), 0,
    "AC1 counter-fixture: '--build-arg' (a different, longer string) does not false-positive as a bare 'build' literal");

# --- Criterion 1/4c: main()'s own source ORDER, not just presence -----------
# The pure rules above (orphan_container_names, image_present via B2 below)
# only matter if main() actually wires them in, in the right order, before
# doing anything irreversible. This is the only way to assert "the sweep
# runs before this run's own container is created" and "the image-present
# check gates before any container action" without ever killing a real VM.
{
    my ($main_body) = ($SRC =~ /sub\s+main\b.*?\{(.*)\z/s);
    ok(defined $main_body, 'sub main is present in the implementation')
        or diag('could not locate "sub main" in the implementation source -- ordering checks below are skipped');

    SKIP: {
        skip 'sub main not found; cannot check call order', 3 unless defined $main_body;

        like($main_body, qr/\bimage_present\s*\(/,
            'AC1: main() calls image_present() somewhere in its body');
        like($main_body, qr/\bsweep_orphan_containers\s*\(/,
            'AC4/criterion-4c: main() calls sweep_orphan_containers() somewhere in its body');

        my $image_present_pos = ($main_body =~ /\bimage_present\s*\(/) ? $-[0] : undef;
        my $sweep_pos          = ($main_body =~ /\bsweep_orphan_containers\s*\(/) ? $-[0] : undef;
        my $run_argv_pos       = ($main_body =~ /\bbuild_run_argv\s*\(/) ? $-[0] : undef;

        my $order_ok =
            defined($image_present_pos) && defined($sweep_pos) && defined($run_argv_pos)
            && $image_present_pos < $run_argv_pos
            && $sweep_pos < $run_argv_pos;
        ok($order_ok,
            'AC1/AC4c: both image_present() and sweep_orphan_containers() are called, in source order, '
          . "BEFORE build_run_argv() creates this run's own container -- the sweep is what recovers a "
          . 'VM-kill-class orphan on the NEXT run, and it must run unconditionally ahead of anything new');
    }
}

# =============================================================================
# FIX-BATCH (step 7) authorised additions -- Part C of the dispatch, folded
# into Part A because every assertion below is pure validation: it runs
# BEFORE main() ever touches podman_bin()/image_present(), so calling main()
# directly with a bad argument costs nothing beyond the function call itself.
# =============================================================================

# --- helper: call main() and capture what it printed to STDERR, without
# reopening STDERR onto an in-memory scalar (fails with "Bad file descriptor"
# on this host's Git-for-Windows perl -- CLAUDE.md). Uses a real temp file,
# same discipline as the implementation's own _podman_capture.
sub _main_stderr {
    my (@argv) = @_;
    my ($fh, $tmp) = File::Temp::tempfile();
    close $fh;
    open(my $saved_stderr, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDERR, '>', $tmp) or die "redirect STDERR: $!";
    my $rc = main(@argv);
    open(STDERR, '>&', $saved_stderr) or die "restore STDERR: $!";
    close $saved_stderr;
    open my $rfh, '<', $tmp or die "open $tmp: $!";
    local $/; my $text = <$rfh>; close $rfh; unlink $tmp;
    return ($rc, $text // '');
}

# --- A25 (fix-batch A1): the file-argument allow-list -- refuse a single
# quote, refuse a bare -e, refuse a .. segment, each with a non-zero exit,
# AND a counter-fixture proving an ordinary path is still accepted (so this
# cannot pass by refusing everything). main() validates every file argument
# BEFORE calling podman_bin() (see the source-order check above's sibling
# property), so each of these calls is genuinely zero podman/container cost.
{
    my ($rc, $err) = _main_stderr("plugins/butler/tests/t/foo'; touch /tmp/PWNED; echo '.t");
    isnt($rc, 0, "A25 (fix-batch A1): a filename containing a single quote is refused (non-zero exit, $rc)");
    like($err, qr/invalid test file argument/, 'A25: ... with a clear refusal message on STDERR');

    ($rc, $err) = _main_stderr('-e');
    isnt($rc, 0, "A25 (fix-batch A1): a filename of '-e' is refused (non-zero exit, $rc)");
    like($err, qr/invalid test file argument/, 'A25: ... with a clear refusal message on STDERR');

    ($rc, $err) = _main_stderr('plugins/butler/tests/t/../../../etc/passwd.t');
    isnt($rc, 0, "A25 (fix-batch A1): a filename containing a '..' segment is refused (non-zero exit, $rc)");
    like($err, qr/invalid test file argument/, 'A25: ... with a clear refusal message on STDERR');

    ok(_is_valid_test_file('plugins/butler/tests/t/foo.t'),
        'A25 counter-fixture: an ordinary plugins/butler/tests/t/foo.t-shaped path is still accepted '
      . '(the allow-list cannot pass by refusing everything)');
}

# --- A26 (fix-batch A2): a UNC path is refused on the documented
# absolute-path path (same message/exit tier as the POSIX/drive-letter forms
# already covered, not the allow-list's generic message).
{
    ok(_is_absolute_path('\\\\server\\share\\foo.t'),
        'A26 (fix-batch A2): _is_absolute_path() recognises a UNC path as absolute');
    my ($rc, $err) = _main_stderr('\\\\server\\share\\foo.t');
    isnt($rc, 0, "A26: a UNC path argument is refused by main() (non-zero exit, $rc)");
    like($err, qr/absolute path not allowed/,
        'A26: ... refused on the documented absolute-path path specifically, not the generic allow-list message');
}

# --- A27 (fix-batch A3): an implausible --ref is refused -----------------
{
    ok(!_is_valid_git_ref('--remote=ext::false'), 'A27 (fix-batch A3): a leading-dash --ref value is rejected by the pure rule');
    ok(_is_valid_git_ref('HEAD'), 'A27: an ordinary ref (HEAD) is still accepted');
    ok(_is_valid_git_ref('refs/heads/main'), 'A27: an ordinary branch ref is still accepted');

    my ($rc, $err) = _main_stderr('--ref', '--remote=ext::false', 'plugins/butler/tests/t/foo.t');
    isnt($rc, 0, "A27: main() refuses an implausible --ref value (non-zero exit, $rc)");
    like($err, qr/invalid --ref value/, 'A27: ... with a clear refusal message on STDERR');
}

# --- A28 (fix-batch A5): the pre-flight notice names the container count --
{
    like(_preflight_notice_text(3), qr/\b3\b.*container/,
        'A28 (fix-batch A5): the pre-flight notice text names an explicit container count');
    like(_preflight_notice_text(3), qr/--cpus\s+\Q$CONTAINER_LANE_CPUS\E\s+--memory\s+\Q$CONTAINER_LANE_MEMORY\E/,
        "A28: ... and this lane's own --cpus/--memory caps, not hardcoded numbers");
    like(_preflight_notice_text(undef), qr/unknown/,
        'A28: an undef count (podman ps itself failed) is reported as unknown, never fabricated');
}

# =============================================================================
# PART B -- real subprocess, never a container, never a build.
# =============================================================================

# --- B1: podman_bin() is cached and never dies -------------------------------
my $first_podman_bin  = eval { podman_bin() };
ok(!$@, 'B1: podman_bin() does not die on its first call') or diag("died: $@");
my $second_podman_bin = eval { podman_bin() };
ok(!$@, 'B1: podman_bin() does not die on a second call') or diag("died: $@");
is($second_podman_bin, $first_podman_bin, 'B1: podman_bin() caches its answer across calls');

# --- B2 (criterion 1): image_present() correctly says NO for a tag that can
# never exist -- the detection half of "refuse, never build". Cheap (a
# single `image inspect` against a bogus tag): no container, no build, so
# this runs unconditionally whenever a CLI is present at all, matching the
# spec's "Part B: cheap, real subprocess, never a container or image build".
SKIP: {
    my $podman = podman_bin();
    skip 'no docker/podman CLI on PATH for the image_present() bogus-tag check', 1 unless $podman;
    my $present = image_present($podman, 'ccpraxis-oracle-image-that-does-not-exist:no-such-tag');
    ok(!$present,
        'B2 (criterion 1): image_present() returns false for a tag guaranteed not to exist locally');
}

# =============================================================================
# PART C -- live, in-container assertions. Opt-in only.
# =============================================================================
{
    my $PART_C_TEST_COUNT = 17; # C1,C2,C3a,C3b,C4,C5,C6,C7x3,C8,C9x3,C10,C11-setup,C11

    SKIP: {
        my $reason;
        if (!$ENV{CCPRAXIS_CONTAINER_LANE_LIVE}) {
            $reason = 'set CCPRAXIS_CONTAINER_LANE_LIVE=1 to run Part C (live, in-container) assertions; '
                    . 'skipped by default so no unattended sweep ever touches podman';
        }
        my $podman;
        if (!$reason) {
            $podman = podman_bin();
            $reason = 'no docker/podman CLI on PATH' unless $podman;
        }
        if (!$reason && !image_present($podman, $IMAGE)) {
            $reason = "image '$IMAGE' is not present locally -- Part C needs a real image to run against";
        }
        skip $reason, $PART_C_TEST_COUNT if $reason;

        # --- test-local helper: write content into the container over a pipe,
        # via fork+exec (no outer shell), same shape as materialize_tree's own
        # pipe/fork/exec, and same sh -c wrapping discipline as criterion 6
        # requires of every podman-exec call site.
        my $write_canary = sub {
            my ($podman, $name, $dest_path, $content) = @_;
            pipe(my $rd, my $wr) or die "pipe: $!";
            my $writer_pid = fork();
            die "fork (canary writer): $!" unless defined $writer_pid;
            if ($writer_pid == 0) {
                close $rd;
                print {$wr} $content;
                close $wr;
                POSIX::_exit(0);
            }
            close $wr;
            my $exec_pid = fork();
            die "fork (canary exec): $!" unless defined $exec_pid;
            if ($exec_pid == 0) {
                open(STDIN, '<&', $rd) or POSIX::_exit(126);
                close $rd;
                exec($podman, 'exec', '-i', $name, 'sh', '-c', "cat > '$dest_path'") or POSIX::_exit(127);
            }
            close $rd;
            waitpid($writer_pid, 0);
            waitpid($exec_pid, 0);
            return $? >> 8;
        };

        my $name = new_container_name();
        my $ok = eval {
            local $SIG{ALRM} = sub { die "container-lane Part C timed out after 120 seconds\n" };
            alarm(120);

            my ($run_rc) = _podman_capture(build_run_argv($podman, $name));
            is($run_rc, 0, 'C1: podman run for the live canary container exits 0');
            $ACTIVE_CONTAINER_NAME = $name;
            $ACTIVE_PODMAN_BIN     = $podman;

            my (undef, $inspect_out) = _podman_capture(
                $podman, 'inspect', $name, '--format', '{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}'
            );
            (my $trimmed = $inspect_out // '') =~ s/\s+\z//;
            is($trimmed, '2000000000 1610612736',
                'C2: podman actually APPLIED the --cpus/--memory caps (not merely that the flags were sent)');

            my ($git_rc, $extract_rc) = materialize_tree($podman, $name, 'HEAD', $REPO_ROOT);
            is($git_rc,     0, 'C3a: the git-archive side of materialize_tree exits 0');
            is($extract_rc, 0, 'C3b: the tar-extract side of materialize_tree exits 0');

            my (undef, $project_check) = _podman_capture(
                $podman, 'exec', $name, 'sh', '-c', q{test -f '/project/CLAUDE.md' && echo YES || echo NO}
            );
            (my $pc = $project_check // '') =~ s/\s+\z//;
            is($pc, 'NO', 'C4: /project/CLAUDE.md is ABSENT inside the container -- no bind mount exists here');

            my (undef, $native_check) = _podman_capture(
                $podman, 'exec', $name, 'sh', '-c',
                "test -f '$NATIVE_TREE_ROOT/CLAUDE.md' && echo YES || echo NO"
            );
            (my $nc = $native_check // '') =~ s/\s+\z//;
            is($nc, 'YES',
                'C5: CLAUDE.md IS present under the native tree root -- the archive genuinely landed on '
              . "container-native storage, not the bind mount");

            my $green_rc = $write_canary->(
                $podman, $name, "$NATIVE_TREE_ROOT/container-lane-canary-green.t", green_source()
            );
            is($green_rc, 0, 'C6: writing the green canary .t file into the container exits 0');

            my $green_result = run_one_in_container($podman, $name, 'container-lane-canary-green.t');
            is($green_result->{rc},    0, 'C7: the green canary comes back rc == 0');
            is($green_result->{notok}, 0, 'C7: the green canary comes back notok == 0');
            like($green_result->{out}, qr/ok 1 - fixture pass/,
                "C7: the green canary's own TAP line comes back unmodified");

            my $red_rc = $write_canary->(
                $podman, $name, "$NATIVE_TREE_ROOT/container-lane-canary-red.t",
                red_source('container lane red canary')
            );
            is($red_rc, 0, 'C8: writing the red canary .t file into the container exits 0');

            my $red_result = run_one_in_container($podman, $name, 'container-lane-canary-red.t');
            is($red_result->{rc},    1, 'C9: the red canary comes back rc == 1');
            is($red_result->{notok}, 1, 'C9: the red canary comes back notok == 1');
            like($red_result->{out}, qr/not ok 1 - container lane red canary/,
                "C9: the red canary's own not-ok TAP line comes back unmodified");

            _cleanup_active_container();
            my (undef, $ps_after) = _podman_capture(build_ps_argv($podman));
            unlike($ps_after // '', qr/\Q$name\E/,
                'C10 (criterion 4a): after cleanup, the container name no longer appears in `podman ps -a`');

            # --- C11 (extra, beyond the spec's C1-C10 table): criterion 4b,
            # tested directly rather than only via handler-installation (A23).
            # Runs as a genuinely separate PROCESS specifically so the SIGTERM
            # sent below cannot touch THIS test process's own %SIG handlers.
            my $child_name = new_container_name();
            my $child_pid = fork();
            die "fork (signal-cleanup child): $!" unless defined $child_pid;
            if ($child_pid == 0) {
                my ($child_run_rc) = _podman_capture(build_run_argv($podman, $child_name));
                if ($child_run_rc != 0) { POSIX::_exit(97) }
                $ACTIVE_CONTAINER_NAME = $child_name;
                $ACTIVE_PODMAN_BIN     = $podman;
                sleep(60);
                POSIX::_exit(98); # unreachable -- the parent signals first
            }
            my $seen = 0;
            for (1 .. 30) {
                my (undef, $ps_out) = _podman_capture(build_ps_argv($podman));
                if (($ps_out // '') =~ /\Q$child_name\E/) { $seen = 1; last }
                select(undef, undef, undef, 0.5);
            }
            ok($seen, 'C11 setup: the signal-cleanup child\'s container became visible before it was signalled')
                or diag("container $child_name never appeared -- cannot test interrupted-run cleanup");
            kill('TERM', $child_pid);
            waitpid($child_pid, 0);
            my $removed = 0;
            for (1 .. 20) {
                my (undef, $ps_out) = _podman_capture(build_ps_argv($podman));
                if (($ps_out // '') !~ /\Q$child_name\E/) { $removed = 1; last }
                select(undef, undef, undef, 0.5);
            }
            ok($removed,
                'C11 (criterion 4b): SIGTERM to a run mid-flight removes ITS OWN container before the process exits');
            _podman_capture(build_rm_argv($podman, $child_name)) unless $removed; # best-effort if the test itself failed

            alarm(0);
            1;
        };
        my $err = $@;
        alarm(0);
        unless ($ok) {
            _cleanup_active_container();
            fail("Part C aborted before completing (forced cleanup attempted): $err");
        }
    }
}

done_testing();
