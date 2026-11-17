#!/usr/bin/env perl
# platform: any
# Oracle for blueprint package 06-route-by-marker (blueprint test-platform-split).
# Derived from
# .ccpraxis-local-data/blueprints/test-platform-split/specs/06-route-by-marker-spec.md
# AND from the package ledger's "STEP 2 GATE" entry
# (.ccpraxis-local-data/blueprints/test-platform-split/packages/06-route-by-marker.md),
# which the ledger instructs takes precedence wherever the two disagree. NOT
# derived from any implementation: scripts/run-tests.pl does not yet define
# classify_file/_run_container_batch/_container_infra_result/run_sweep at the
# time this file is written (verified: no such subs, no "unless caller()"
# guard -- confirmed by a plain `grep -n '^sub '` over the real file, never by
# reading its logic), and this file must never add that behaviour itself.
#
# ======================================================================
# WHERE THIS FILE DEPARTS FROM THE SPEC TEXT, AND WHY THE LEDGER WINS
# ======================================================================
# 1. CRITERION 5 IS DEFERRED (ledger Decision 17, STEP 2 GATE, 2026-09-17).
#    The spec's own section 4 ("Criterion 5 -- measurement protocol") and
#    its AC-5 are NOT implemented by anything below, deliberately -- not as
#    a weaker/placeholder assertion, but as NO assertion at all, per this
#    package's explicit rescoping brief: "Criterion 5 (measurably faster)
#    is DEFERRED -- do not write assertions for it, and do not write a
#    placeholder that asserts something weaker in its name."
# 2. DC-6 IS THE LEDGER'S CORRECTED FORM, not the spec's literal text. The
#    spec's own section 0.3 already corrects DC-6 to "(host-marked
#    files) UNION (serial-classified files, regardless of marker)" and the
#    ledger's STEP 2 GATE entry independently re-derives and pins the same
#    correction ("DC-6 AS LITERALLY WRITTEN IS FALSE"). Both agree here;
#    Part D below asserts the corrected set.
# 3. A REAL, UNRESOLVED CONTRADICTION, flagged rather than silently picked:
#    the spec's own section 7 ("Out of scope") says routing-configurability
#    via "env var/flag to disable container routing" is "explicitly
#    forbidden by the ledger." The ledger's Decision 17/18 (dated the SAME
#    day, 2026-09-17, and recorded in this package's own STEP 2 GATE entry)
#    says the opposite: the container lane must be reachable "by an
#    explicit flag rather than by default," and Decision 18 spells out a
#    lane-AVAILABILITY capability gate ("with the flag off, every file runs
#    on the host as today") that is squarely an "env var/flag" by the
#    spec's own section 7 wording. Per this oracle's brief ("if the spec
#    contradicts the ledger's STEP 2 GATE entry, the ledger wins"), the
#    CAPABILITY GATE'S EXISTENCE is taken as required. Its concrete
#    mechanism (flag name, CLI form, env var) is NOT specified anywhere --
#    neither the spec nor the ledger names one -- so this file does not
#    invent one. What IS both specified and directly testable, and is
#    asserted below (the "Decision 18 purity" block, before Part A), is the
#    interface-agnostic half of Decision 18's own property: "no flag,
#    environment variable or argument can send a host file to the
#    container or pull an any file back to the host" -- proven by showing
#    classify_file's own source takes exactly one parameter (the file path)
#    and never consults $ENV or @ARGV, so its per-file verdict cannot vary
#    with any external state by construction. STATED PLAINLY SO IT NEEDS NO
#    INFERENCE: the WIRING-level half of Decision 18 -- what run_sweep does
#    with @container when the lane-availability capability is OFF (does it
#    run those files on the host instead? does it use a different result
#    shape than section 2.5's container_infra?) -- IS LEFT COMPLETELY
#    UNPINNED BY THIS ORACLE. Not weakly covered, not implied by another
#    assertion -- UNPINNED. Reason: section 2.2.1 of the spec forbids this
#    file from ever calling run_sweep() (it would either run a real ~1000s
#    sweep in-process or hit a bare exit() that kills the test process), and
#    DC-6's own "enumerate, never sweep" mandate rules out proving it by
#    spawning a real, flag-toggled sweep instead. A reviewer/implementer
#    must treat the capability gate's wiring-level behaviour as an open
#    design question this package still owes an answer to, not as something
#    this file has already checked. Reported as untestable-as-specified
#    rather than invented.
#
# ======================================================================
# THE PRECEDENCE FIGURES THIS FILE'S CASE TABLE AND PART D DEPEND ON --
# MEASURED FROM DISK AT AUTHORING TIME, NEVER FROM scripts/run-tests.pl's
# OWN LOGIC (a fresh `grep -lE` over plugins/*/tests/t/*.t, independent of
# any implementation):
#   350 total .t files; 108 marked host; 242 marked any; 0 marked linux.
#   15 files match the serial heuristic (TestSandbox|podman_run_capture|
#   podman_bin|probe_image); of those 15, exactly 10 are marked `any` and 5
#   are marked `host` -- CONFIRMS the spec/ledger's own "10 of 15" claim
#   exactly, re-derived independently rather than trusted.
# Part D re-derives its own expected sets fresh at assertion time and never
# hardcodes these counts (beyond a floor); they are recorded here only as
# the authoring-time evidence for the case table's row 4-6 design and the
# report this file's own header is required to give.
#
# ======================================================================
# WHAT IS EXPECTED TO FAIL TODAY, AND WHY (not a fixture fault):
#   - The safety-gate check ("section 2.2: ... defines run_sweep() and
#     guards ...") is expected to FAIL and BAIL_OUT the rest of this file.
#     scripts/run-tests.pl today executes its entire body -- argv parsing,
#     glob, the real fork/waitpid execution phases, and a bare top-level
#     `exit scalar(@red);` -- merely by being `require`d. Actually
#     `require`ing it today would run a real, unbounded, ~1000s sweep
#     inside THIS process and then hard-exit the whole test process before
#     a single assertion below could run -- exactly the hazard spec section
#     2.2 names and exists to close. This oracle refuses to attempt the
#     real `require` until that structural change is verified present,
#     mirroring container-lane.t's own `ok(-f $IMPL) or BAIL_OUT(...)`
#     idiom for "the file this oracle needs is not yet safe to load."
#   - Consequently EVERY assertion in Parts A, B, C and D, and the AC-4 live
#     subprocess regression guard, currently reports as not-run (BAIL_OUT
#     stops the file before done_testing()) -- this is the correct,
#     expected shape for an oracle whose target module does not yet exist
#     in usable form, identical in kind to container-lane.t's own original
#     all-Parts-unreached state when run-tests-container.pl did not exist.
#     The SELF-CHECK block (before AC-8, described below) exists precisely
#     because that unreached state would otherwise leave Part A's and
#     Part D's own assertion shapes unproven until step 5.
#
# WHAT IS EXPECTED TO PASS TODAY, AND WHY THAT IS NOT VACUOUS:
#   - The SELF-CHECK block, in full: it runs Part A's ten-row case table and
#     Part D's enumeration/is_deeply logic against a SYNTHETIC, require-safe
#     stub (classify_file copied verbatim from spec section 2.1) that this
#     file builds itself under File::Temp -- proving those two blocks'
#     assertions are satisfiable by a correct implementation (the "correct
#     stub" half) AND that they would actually catch a specific, named
#     regression -- an inverted marker-vs-serial precedence -- if one
#     existed (the "mutated stub" half, isnt()-based, never a native
#     is_deeply "not ok"). This is scaffolding this file is entitled to
#     write; it never touches scripts/run-tests.pl and is clearly labelled
#     "SELF-CHECK" in every test name so it cannot be mistaken for a green
#     real-file result. See the dedicated SELF-CHECK header comment below
#     for the full separation statement.
#   - The AC-8 `perl -c` checks (both files already parse as valid Perl).
#   - The AC-1 source-scan (scripts/run-tests.pl's only "backfill" mention
#     today is inside a comment, so the executable-reference count is
#     already 0) -- expected green today, and STAYS green after
#     implementation only because the implementer must not add an
#     executable reference; a regression guard, not a placeholder.
#   - The AC-7 source-scan (no `sub main` exists in scripts/run-tests.pl
#     today at all) -- also a forward-looking regression guard.
#   - The safety-gate check's own counter-fixture proves the detector CAN
#     pass (fed a fabricated already-safe source snippet), so its failure
#     against the real file is a real finding, not a tautology.
#
# ======================================================================
# AC -> block mapping (spec section 5, corrected per the header above):
#   AC-1 (DC-1)  -> "AC-1 source-scan" block (backfill never referenced
#                   executably) + Part A rows 9-10 (backfill-signal-in-body
#                   has no effect on the lane).
#   AC-2 (DC-2)  -> Part D's container-set is_deeply; Part C (opt-in, live).
#   AC-3 (DC-3)  -> Part A rows 4-6 (the collision, generalised) + row 8
#                   (marker-gate-first ordering); Part D's host-serial-set
#                   is_deeply.
#   AC-4 (DC-4)  -> Part A row 7 (classify_file refuses); the "AC-4 live
#                   regression guard" block (real run-tests.pl subprocess).
#   AC-5 (DC-5)  -> DEFERRED. No assertion anywhere in this file (see above).
#   AC-6 (DC-6, scoped) -> Part D's host-parallel-set is_deeply, combined
#                   with AC-3's host-serial-set is_deeply.
#   AC-7 (regression guard) -> "AC-7 source-scan" block (no sub main).
#   AC-8 (regression guard) -> "AC-8: perl -c" block, both files.
#   Decision 18 (lane-availability, not routing) -> "Decision 18 purity"
#                   block, structural, before Part A (see header note 3).
#   SELF-CHECK (step-3 gate addition, bug 20260916-110812-2d94) -> proves
#                   Part A's case table and Part D's enumeration/is_deeply
#                   logic are non-vacuous, against a synthetic stub, BEFORE
#                   the real BAIL_OUT would otherwise leave them unreached.
#
# MANDATORY VACUITY GATE (this blueprint's own standing rule -- a wrong
# implementation has passed a whole oracle here before, with the defect
# living in the oracle rather than the code under test):
#   - Every detector this file defines locally (the backfill-reference
#     scanner, the run_sweep/unless-caller safety-gate scanner, the
#     classify_file-purity extractor) is exercised against a fabricated
#     POSITIVE fixture (proving it fires) as well as being run against the
#     real source (which may or may not fire, depending on implementation
#     state) -- so none of them could pass by never triggering.
#   - The case table's row 4-6 collision and row 9-10 invariance are a
#     matched positive/negative pair by construction: rows 1-3 prove the
#     marker value alone decides when nothing is serial-classified; rows
#     4-6 prove the serial heuristic overrides that same marker value when
#     it fires; rows 9-10 prove a backfill-style signal in the body, absent
#     the serial-heuristic substrings, changes nothing.
#   - Part D's real-tree sweep asserts a floor (>= 300) on the file count
#     it iterates, so it cannot pass by iterating over nothing, and computes
#     its "expected" sets via an INDEPENDENT re-derivation (TestPlatform.pm
#     + the same regex, written out again here) rather than ever comparing
#     classify_file against itself.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Basename ();
use File::Temp qw(tempdir);
use POSIX ();
use Cwd qw(abs_path);
use Config ();

use lib "$Bin/../lib";
use TestPlatform ();
use RunnerStateHarness ();

my $REPO_ROOT = abs_path("$Bin/../../../..");

# Built at runtime from separate string pieces, deliberately, so THIS FILE'S
# OWN static source text never contains the contiguous substring
# "TestSandbox::" (package 01-container-lane-is-a-property's
# _loads_test_sandbox() text-scans a file's raw bytes with no quote/string
# masking -- spec section 5 -- so a literal "TestSandbox::" sitting inside
# one of this oracle's own fixture-body string literals would make
# classify_file() misclassify lane-routing.t itself as host-serial, which it
# must never be: it is one of the seven files in spec section 2.3). Fixture
# bodies below use $TSNS to spell a genuine, load-shaped reference that is
# real code once WRITTEN TO A SEPARATE FIXTURE FILE on disk, without ever
# appearing as contiguous trigger text in this file's own source.
my $TSNS = join('', 'Test', 'Sandbox', '::');

# =============================================================================
# PART 0 -- helpers
# =============================================================================

sub write_fixture {
    my ($dir, $name, $content) = @_;
    my $path = File::Spec->catfile($dir, $name);
    open my $fh, '>:raw', $path or die "cannot write fixture $path: $!";
    print {$fh} $content;
    close $fh;
    return $path;
}

# _spawn_child_perl($script_source, \@argv, \%env_overrides) -> { rc, out }
# Fork+exec(LIST) + a genuine temp file for captured combined stdout/stderr --
# same shape as _perl_dash_c below, generalised to run an arbitrary script
# with its own argv and environment overrides. Used by the fix-batch step-7
# amendments (A2/A3) that need a fresh, isolated process in which to force a
# fork()/podman_bin() failure BEFORE scripts/run-tests.pl is required --
# something this file's own already-loaded copy cannot reproduce.
sub _spawn_child_perl {
    my ($script_source, $argv, $env_overrides) = @_;
    $argv          //= [];
    $env_overrides //= {};
    my $dir = tempdir(CLEANUP => 1);
    my $child_path = write_fixture($dir, 'child.pl', $script_source);
    my ($out_fh, $out_tmp) = File::Temp::tempfile();
    close $out_fh;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        for my $k (keys %$env_overrides) { $ENV{$k} = $env_overrides->{$k} }
        open(STDOUT, '>', $out_tmp) or POSIX::_exit(126);
        open(STDERR, '>&', \*STDOUT) or POSIX::_exit(126);
        exec($^X, $child_path, @$argv) or POSIX::_exit(127);
    }
    waitpid($pid, 0);
    my $rc = $? >> 8;
    open my $rfh, '<', $out_tmp or return { rc => $rc, out => '' };
    local $/; my $out = <$rfh>; close $rfh; unlink $out_tmp;
    return { rc => $rc, out => $out // '' };
}

# _perl_dash_c($file) -> ($rc, $combined_output)
# Real fork+exec(LIST) + a genuine temp file for captured output -- never
# reopening this process's own STDOUT/STDERR onto an in-memory scalar
# (fails with "Bad file descriptor" on this host's perl, per CLAUDE.md).
sub _perl_dash_c {
    my ($file) = @_;
    my ($fh, $tmp) = File::Temp::tempfile();
    close $fh;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDOUT, '>', $tmp) or POSIX::_exit(126);
        open(STDERR, '>&', \*STDOUT) or POSIX::_exit(126);
        exec($^X, '-c', $file) or POSIX::_exit(127);
    }
    waitpid($pid, 0);
    my $rc = $? >> 8;
    open my $rfh, '<', $tmp or return ($rc, '');
    local $/; my $out = <$rfh>; close $rfh; unlink $tmp;
    return ($rc, $out // '');
}

# _executable_backfill_hits($src) -> @lines
# AC-1's own source-scan detector: a line counts only if the text BEFORE its
# first '#' (i.e. the non-comment portion) contains "backfill" case-
# insensitively. A whole-line comment (leading '#') never counts.
sub _executable_backfill_hits {
    my ($src) = @_;
    my @hits;
    for my $line (split /\n/, $src) {
        (my $code = $line) =~ s/#.*$//;
        push @hits, $line if $code =~ /backfill/i;
    }
    return @hits;
}

# _is_require_safe($src) -> bool
# Section 2.2's own structural requirement: a sub literally named run_sweep,
# and the file's own execution guarded by
# "exit run_sweep(@ARGV) unless caller();" (whitespace-tolerant).
sub _is_require_safe {
    my ($src) = @_;
    return 0 unless $src =~ /^[ \t]*sub[ \t]+run_sweep\b/m;
    return 0 unless $src =~ /exit\s+run_sweep\s*\(\s*\@ARGV\s*\)\s*unless\s+caller\s*\(\s*\)\s*;/;
    return 1;
}

# _extract_sub_body($src, $name) -> $body | undef
# Brace-counting extraction (not a "match to next closing brace", which
# would stop early at the first nested block's own '}') -- good enough for
# this repo's own consistently-formatted source, same pragmatic scanning
# class as container-lane.t's find_suspect_podman_exec_lines/A24.
sub _extract_sub_body {
    my ($src, $name) = @_;
    return undef unless $src =~ /^[ \t]*sub[ \t]+\Q$name\E\b[^{]*\{/m;
    my $start = $+[0];
    my $depth = 1;
    my $pos   = $start;
    my $len   = length($src);
    while ($pos < $len && $depth > 0) {
        my $c = substr($src, $pos, 1);
        $depth++ if $c eq '{';
        $depth-- if $c eq '}';
        $pos++;
    }
    return substr($src, $start, $pos - $start - 1);
}

# =============================================================================
# SELF-CHECK -- added per step-3 gate feedback, citing bug
# 20260916-110812-2d94: "five subtests passing is indistinguishable from
# twenty passing unless somebody counts." Parts A and D further below
# CANNOT execute today (scripts/run-tests.pl is not yet require-safe, and
# the BAIL_OUT that stops this file there is correct and stays exactly
# where it is). That leaves those two blocks' own assertions genuinely
# unproven: a typo or a wrong is_deeply shape in either one would sit
# silently in this immutable file until step 5, in a package the
# implementer is forbidden to fix it in.
#
# This block proves those two blocks' ASSERTION SHAPES are live and
# non-vacuous *right now*, by running the identical case-table rows and
# enumeration/is_deeply logic against a SYNTHETIC, require-safe stub this
# file builds itself -- never against scripts/run-tests.pl.
#
# THE STUB'S classify_file IS COPIED VERBATIM FROM SPEC SECTION 2.1 -- not
# improvised, not simplified, not "the same idea." $CLASSIFY_BODY below is
# that exact body, byte-for-byte modulo comment trimming, wrapped in the
# run_sweep()/"exit ... unless caller()" shape section 2.2 requires so the
# stub is require-safe by construction (proving THAT shape is achievable
# too, not asserting it about the real file, which the gate above already
# does correctly).
#
# ---------------------------------------------------------------------
# SEPARATION -- stated as plainly as the gate feedback asked for: every
# assertion in this SELF-CHECK section exercises THIS FILE'S OWN
# ASSERTIONS against a stub OF THIS FILE'S OWN CONSTRUCTION. It is NOT,
# and must never be read as, a substitute for Parts A/B/C/D or the AC-4
# guard below, which test the REAL scripts/run-tests.pl and remain gated
# behind the real safety-gate BAIL_OUT, unchanged. A green SELF-CHECK
# proves this oracle WOULD catch the bug it claims to catch; it says
# nothing whatsoever about whether scripts/run-tests.pl exists yet or is
# correct. Every test label in this section is prefixed "SELF-CHECK" for
# exactly this reason -- so a later reader scanning TAP output cannot
# mistake a green self-check line for a green implementation line.
#
# SCOPE: this proves Part A's case table and Part D's enumeration/
# is_deeply logic only -- the two blocks the step-3 gate named, and the
# two most likely to hide a wrong-shape assertion. Part B
# (RunTestsContainerLane hermetic monkeypatches), Part C (opt-in live),
# and the AC-4 live-subprocess guard are NOT re-proven here: they exercise
# interfaces (_run_container_batch, a real subprocess) this self-check
# does not stub, and the gate feedback did not name them.
# ---------------------------------------------------------------------
my $CLASSIFY_BODY = <<'BODY';
    my ($f) = @_;
    open my $fh, '<', $f or return undef;   # unchanged silent-skip precedent, see spec section 5.2
    my $src = do { local $/; <$fh> };
    close $fh;

    my $marker = TestPlatform::parse_marker($src);
    if ($marker->{outcome} ne 'legal') {
        return { lane => 'refused', marker => $marker, serial => undef };
    }

    # PRECEDENCE (pinned, spec section 0.1): the serial heuristic outranks
    # the marker value. Serial is decided by _loads_test_sandbox() (package
    # 01-container-lane-is-a-property, spec section 2.1): whole-line comments
    # stripped, then a genuine `use`/`require TestSandbox` or word-bounded
    # `TestSandbox::` reference -- never a raw mention of podman_bin/
    # podman_run_capture/probe_image alone.
    my $code = join "\n", grep { !/^\s*#/ } split /\n/, $src, -1;
    my $serial = ($code =~ /\b(?:use|require)\s+TestSandbox\b/ || $code =~ /\bTestSandbox::/) ? 1 : 0;
    if ($serial) {
        return { lane => 'host-serial', marker => $marker, serial => 1 };
    }
    if ($marker->{value} eq 'host') {
        return { lane => 'host-parallel', marker => $marker, serial => 0 };
    }
    # 'any' or 'linux', not serial-classified.
    return { lane => 'container', marker => $marker, serial => 0 };
BODY

# MUTATED (deliberate, for non-vacuity ONLY -- never a candidate reading of
# the spec): marker value decided BEFORE the serial heuristic, the exact
# inverted precedence spec section 2.1/0.1 forbids. Everything else is
# byte-identical to $CLASSIFY_BODY above.
my $MUTATED_CLASSIFY_BODY = <<'BODY';
    my ($f) = @_;
    open my $fh, '<', $f or return undef;
    my $src = do { local $/; <$fh> };
    close $fh;

    my $marker = TestPlatform::parse_marker($src);
    if ($marker->{outcome} ne 'legal') {
        return { lane => 'refused', marker => $marker, serial => undef };
    }

    my $code = join "\n", grep { !/^\s*#/ } split /\n/, $src, -1;
    my $serial = ($code =~ /\b(?:use|require)\s+TestSandbox\b/ || $code =~ /\bTestSandbox::/) ? 1 : 0;
    if ($marker->{value} eq 'host') {
        return { lane => 'host-parallel', marker => $marker, serial => $serial };
    }
    # 'any' or 'linux': marker decides FIRST under this mutation, so the
    # serial heuristic never gets a say for these two values -- the
    # inversion the step-3 gate asked for.
    return { lane => 'container', marker => $marker, serial => $serial };
BODY

my $SELF_CHECK_LIB = File::Spec->catdir($REPO_ROOT, qw(plugins butler tests lib));
(my $self_check_lib_fwd = $SELF_CHECK_LIB) =~ s{\\}{/}g;

sub _write_stub {
    my ($classify_body) = @_;
    my $src = "use strict;\nuse warnings;\nuse lib '$self_check_lib_fwd';\nuse TestPlatform ();\n"
            . "sub classify_file {\n$classify_body}\n"
            . "sub run_sweep {\n    my \@argv = \@_;\n    return 0;\n}\n"
            . "exit run_sweep(\@ARGV) unless caller();\n";
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'stub-run-tests.pl');
    open my $fh, '>', $path or die "cannot write self-check stub $path: $!";
    print {$fh} $src;
    close $fh;
    return $path;
}

my $CORRECT_STUB = _write_stub($CLASSIFY_BODY);
my $MUTATED_STUB = _write_stub($MUTATED_CLASSIFY_BODY);

package RouteByMarkerSelfCheckCorrect;
require $CORRECT_STUB;
package main;

package RouteByMarkerSelfCheckMutated;
require $MUTATED_STUB;
package main;

# The SAME ten rows Part A exercises against the real file, reused here
# verbatim (name, fixture content, expected lane) so both blocks are
# provably testing the same cases.
my @SELF_CHECK_ROWS = (
    [ 'row1-host-plain',
      "#!/usr/bin/env perl\n# platform: host\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n",
      'host-parallel' ],
    [ 'row2-any-plain',
      "#!/usr/bin/env perl\n# platform: any\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n",
      'container' ],
    [ 'row3-linux-plain',
      "#!/usr/bin/env perl\n# platform: linux\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n",
      'container' ],
    [ 'row4-any-serial-collision',
      "#!/usr/bin/env perl\n# platform: any\n${TSNS}podman_run_capture(); # a genuine "
    . "${TSNS} reference, not a comment mention, trips the serial heuristic\n"
    . "print \"ok 1 - fixture pass\\n\"; exit 0;\n",
      'host-serial' ],
    [ 'row5-host-serial',
      "#!/usr/bin/env perl\n# platform: host\n${TSNS}podman_bin(); # calls podman_bin() via "
    . "${TSNS}, a genuine load-shaped reference\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n",
      'host-serial' ],
    [ 'row6-linux-serial',
      "#!/usr/bin/env perl\n# platform: linux\n${TSNS}probe_image(); # calls probe_image() via "
    . "${TSNS}, a genuine load-shaped reference\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n",
      'host-serial' ],
    [ 'row7-unmarked',
      "#!/usr/bin/env perl\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n",
      'refused' ],
    [ 'row8-illegal-marker-serial-shaped',
      "#!/usr/bin/env perl\n# platform: macos\n# calls TestSandbox internally\n"
    . "print \"ok 1 - fixture pass\\n\"; exit 0;\n",
      'refused' ],
    [ 'row9-any-backfill-signal-only',
      "#!/usr/bin/env perl\n# platform: any\n# mentions MSYS2_ARG_CONV_EXCL, a backfill-scanner signal, "
    . "not a serial-heuristic substring\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n",
      'container' ],
    [ 'row10-host-backfill-signal-only',
      "#!/usr/bin/env perl\n# platform: host\n# mentions cygpath and podman machine, backfill-scanner "
    . "signals with no underscore-joined serial-heuristic substring anywhere in this line\n"
    . "print \"ok 1 - fixture pass\\n\"; exit 0;\n",
      'host-parallel' ],
);

my $SELF_CHECK_DIR = tempdir(CLEANUP => 1);
my %self_check_path_for;
for my $row (@SELF_CHECK_ROWS) {
    my ($name, $content) = @$row;
    $self_check_path_for{$name} = write_fixture($SELF_CHECK_DIR, "$name.t", $content);
}

# --- SELF-CHECK, CORRECT stub: every row matches Part A's own expectation,
# proving the case table's assertion shape is satisfiable by a spec-
# faithful implementation (i.e. it is not pinning something impossible). --
for my $row (@SELF_CHECK_ROWS) {
    my ($name, undef, $expected) = @$row;
    my $d = RouteByMarkerSelfCheckCorrect::classify_file($self_check_path_for{$name});
    is($d->{lane}, $expected,
        "SELF-CHECK (correct stub) $name: classify_file -> '$expected', matching Part A's own "
      . 'expectation for this exact row, against a spec-faithful implementation');
}

# --- SELF-CHECK, MUTATED stub (non-vacuity): precedence inverted. The rows
# that MUST flip are exactly the serial-classified ones (4, 5, 6) -- row 4
# (an any-marked, serial-classified file) is THE collision spec section 0.1
# exists to resolve. Every other row is asserted UNCHANGED, so this proves
# the mutation's effect is narrowly scoped to the collision, not "the whole
# table went red" (which would prove nothing about precedence specifically).
# --------------------------------------------------------------------------
my %expect_flip = map { $_ => 1 } qw(row4-any-serial-collision row5-host-serial row6-linux-serial);
my %actually_flipped;
for my $row (@SELF_CHECK_ROWS) {
    my ($name, undef, $expected) = @$row;
    my $d   = RouteByMarkerSelfCheckMutated::classify_file($self_check_path_for{$name});
    my $got = defined($d->{lane}) ? $d->{lane} : '<undef>';
    $actually_flipped{$name} = ($got ne $expected) ? 1 : 0;
    if ($expect_flip{$name}) {
        isnt($got, $expected,
            "SELF-CHECK (mutated stub, non-vacuity) $name: inverting precedence (marker value decided "
          . "before the serial heuristic) changes this row's verdict away from '$expected' (got '$got') "
          . '-- Part A\'s own assertion for this row would have caught this exact regression');
    } else {
        is($got, $expected,
            "SELF-CHECK (mutated stub) $name: NOT a serial-classified row, so the precedence inversion "
          . "leaves its verdict unchanged at '$expected' -- the mutation's effect is scoped to the "
          . 'collision rows, not a global break that would prove nothing specific');
    }
}
ok($actually_flipped{'row4-any-serial-collision'},
    'SELF-CHECK non-vacuity, NAMED (step-3 gate requirement): row4-any-serial-collision -- an any-marked, '
  . 'serial-classified file, THE collision spec section 0.1 exists to resolve -- is CONFIRMED, '
  . 'dynamically, to flip under the inverted-precedence mutation');

# --- SELF-CHECK, Part D shape (enumeration + is_deeply), same fixture set,
# CORRECT stub first: proves Part D's independent-re-derivation-plus-
# is_deeply logic is satisfiable against a spec-faithful implementation. ---
{
    my @paths = map { $self_check_path_for{$_->[0]} } @SELF_CHECK_ROWS;

    my (@expect_hp, @expect_c, @expect_hs, @expect_refused);
    for my $f (@paths) {
        open my $fh, '<', $f or next;
        my $src = do { local $/; <$fh> };
        close $fh;
        my $m = TestPlatform::parse_marker($src);
        if ($m->{outcome} ne 'legal') { push @expect_refused, $f; next }
        my $code = join "\n", grep { !/^\s*#/ } split /\n/, $src, -1;
        my $serial = ($code =~ /\b(?:use|require)\s+TestSandbox\b/ || $code =~ /\bTestSandbox::/) ? 1 : 0;
        if    ($serial)                  { push @expect_hs, $f }
        elsif ($m->{value} eq 'host') { push @expect_hp, $f }
        else                              { push @expect_c,  $f }
    }

    my (@by_correct_hp, @by_correct_c, @by_correct_hs);
    for my $f (@paths) {
        my $d = RouteByMarkerSelfCheckCorrect::classify_file($f) or next;
        push @by_correct_hp, $f if $d->{lane} eq 'host-parallel';
        push @by_correct_c,  $f if $d->{lane} eq 'container';
        push @by_correct_hs, $f if $d->{lane} eq 'host-serial';
    }
    is_deeply([sort @by_correct_hp], [sort @expect_hp],
        'SELF-CHECK (correct stub, Part D shape): host-parallel set matches the independent re-derivation');
    is_deeply([sort @by_correct_c], [sort @expect_c],
        'SELF-CHECK (correct stub, Part D shape): container set matches the independent re-derivation');
    is_deeply([sort @by_correct_hs], [sort @expect_hs],
        'SELF-CHECK (correct stub, Part D shape): host-serial set matches the independent re-derivation');

    # --- MUTATED stub: Part D's is_deeply logic must ALSO diverge. Proven
    # via string-join isnt() rather than is_deeply() itself, deliberately --
    # so the intentionally-wrong mutation never emits a native is_deeply
    # "not ok" into this file's own permanent TAP output; the divergence
    # itself is the (positive) property under test.
    my (@by_mut_hp, @by_mut_c, @by_mut_hs);
    for my $f (@paths) {
        my $d = RouteByMarkerSelfCheckMutated::classify_file($f) or next;
        push @by_mut_hp, $f if $d->{lane} eq 'host-parallel';
        push @by_mut_c,  $f if $d->{lane} eq 'container';
        push @by_mut_hs, $f if $d->{lane} eq 'host-serial';
    }
    isnt(join(',', sort @by_mut_hs), join(',', sort @expect_hs),
        'SELF-CHECK (mutated stub, Part D non-vacuity): the host-serial set computed under the '
      . 'inverted-precedence mutation DIFFERS from the independent re-derivation -- Part D\'s own '
      . 'is_deeply assertion on the real file would have caught this exact regression too');
    ok((grep { $_ eq $self_check_path_for{'row4-any-serial-collision'} } @by_mut_c) ? 1 : 0,
        'SELF-CHECK (mutated stub, Part D non-vacuity, NAMED): row4-any-serial-collision is pulled INTO '
      . 'the mutated container set (it belongs ONLY in host-serial) -- the same mechanism Part A\'s '
      . 'row-level check also catches, now shown at the enumerated-set level Part D actually asserts');
}

# =============================================================================
# AC-8 (regression guard): perl -c on both files exits 0. Safe and cheap --
# -c never executes either file's main body, only compiles it.
# =============================================================================
my $IMPL = "$Bin/../../../../scripts/run-tests.pl";
my $SELF = "$Bin/lane-routing.t";
{
    my ($rc, $out) = _perl_dash_c($IMPL);
    is($rc, 0, "AC-8: perl -c scripts/run-tests.pl exits 0") or diag($out);
}
{
    my ($rc, $out) = _perl_dash_c($SELF);
    is($rc, 0, "AC-8: perl -c plugins/butler/tests/t/lane-routing.t (this file) exits 0") or diag($out);
}

# =============================================================================
# The implementation file must exist before anything else here can even be
# attempted (mirrors container-lane.t's own ok(-f $IMPL) or BAIL_OUT).
# =============================================================================
ok(-f $IMPL, 'scripts/run-tests.pl exists (the implementation this file is the oracle for)')
    or BAIL_OUT("$IMPL does not exist -- nothing else in this file can run until it is written");

my $SRC = do { local (@ARGV, $/) = ($IMPL); <> };

# =============================================================================
# AC-1 (DC-1): the backfill scanner is never consulted at run time -- proven
# as a source-scan over the REQUIRED file's own text, with a counter-fixture
# pair proving the detector is a real predicate.
# =============================================================================
{
    my @hits = _executable_backfill_hits($SRC);
    is(scalar(@hits), 0,
        'AC-1: scripts/run-tests.pl contains zero NON-COMMENT lines mentioning "backfill" -- the '
      . 'backfill scanner (scripts/backfill-test-platform.pl) is never referenced executably')
        or diag("executable backfill reference(s):\n  " . join("\n  ", @hits));

    is(scalar(_executable_backfill_hits("require 'scripts/backfill-test-platform.pl';\n")), 1,
        'AC-1 counter-fixture: the detector DOES fire on a fabricated executable backfill reference');
    is(scalar(_executable_backfill_hits("# scripts/backfill-test-platform.pl is a comment mention only\n")), 0,
        'AC-1 counter-fixture: a comment-only mention of "backfill" is correctly NOT flagged');
}

# =============================================================================
# AC-7 (regression guard): no sub literally named `main` in scripts/run-
# tests.pl -- closes the RunTestsContainerLane `require`-time name-collision
# structurally (section 2.3), so a future rename to the obvious `main` cannot
# silently reintroduce it without this test noticing.
# =============================================================================
{
    unlike($SRC, qr/^[ \t]*sub[ \t]+main\b/m,
        'AC-7: scripts/run-tests.pl defines no sub literally named "main" (it defines run_sweep) -- '
      . "would otherwise collide with RunTestsContainerLane::main once namespaced (section 2.3)");
    like("sub main {\n}\n", qr/^[ \t]*sub[ \t]+main\b/m,
        'AC-7 counter-fixture: the detector DOES fire on a fabricated "sub main"');
}

# =============================================================================
# Decision 18 purity (lane-availability is not a routing switch): the
# interface-agnostic half of "no flag, environment variable or argument can
# send a host file to the container or pull an any file back to the
# host" -- proven structurally, since classify_file's own pinned signature
# (spec section 2.1) takes exactly one parameter and consults nothing else.
# The WIRING-level half (what run_sweep does with @container when a lane-
# availability capability is off) is untestable by this file: section 2.2.1
# forbids calling run_sweep() here, and DC-6 forbids proving it via a real
# sweep instead -- see this file's header, note 3.
# =============================================================================
{
    my $body = _extract_sub_body($SRC, 'classify_file');
    ok(defined $body, 'Decision 18: classify_file() is present in scripts/run-tests.pl (extractable sub body)');
  SKIP: {
        skip 'classify_file not found -- purity checks below need its body', 3 unless defined $body;
        like($body, qr/^\s*my\s*\(\s*\$\w+\s*\)\s*=\s*\@_;/,
            'Decision 18: classify_file() unpacks exactly one scalar parameter (the file path) from @_');
        unlike($body, qr/\$ENV\{/,
            'Decision 18: classify_file() never reads $ENV{...} -- its verdict cannot depend on any '
          . 'environment variable');
        unlike($body, qr/\@ARGV\b/,
            'Decision 18: classify_file() never reads @ARGV -- its verdict cannot depend on any CLI flag');
    }
    # Counter-fixture: the same three checks DO fire on a fabricated
    # classify_file that takes two parameters and consults $ENV/@ARGV, so
    # this is a real predicate, not a tautology.
    my $fake = "sub classify_file {\n    my (\$f, \$mode) = \@_;\n"
             . "    return 'container' if \$ENV{LIVE} || grep { /--live/ } \@ARGV;\n    return 'host';\n}\n";
    my $fake_body = _extract_sub_body($fake, 'classify_file');
    ok(defined $fake_body, 'Decision 18 counter-fixture: extractor finds the fabricated sub body');
    unlike($fake_body, qr/^\s*my\s*\(\s*\$\w+\s*\)\s*=\s*\@_;/,
        'Decision 18 counter-fixture: the arity-1 check correctly does NOT match a two-parameter unpack');
    like($fake_body, qr/\$ENV\{/, 'Decision 18 counter-fixture: the $ENV{} check correctly DOES fire');
    like($fake_body, qr/\@ARGV\b/, 'Decision 18 counter-fixture: the @ARGV check correctly DOES fire');
}

# =============================================================================
# THE SAFETY GATE (section 2.2's own structural requirement). This is a
# real, first-class assertion of a real done-criterion precondition -- NOT a
# softened check -- but its failure must BAIL_OUT rather than let the rest
# of this file attempt the actual `require`, which would otherwise run a
# real ~1000s sweep inside this process and then hard-exit it via
# scripts/run-tests.pl's own bare top-level `exit scalar(@red);` before a
# single assertion below could run. See this file's header for the full
# hazard and container-lane.t's own precedent for this exact idiom.
# =============================================================================
{
    ok(_is_require_safe($SRC),
        'section 2.2: scripts/run-tests.pl defines run_sweep() and guards its own top-level execution '
      . 'with "exit run_sweep(@ARGV) unless caller();" -- required before this file can safely `require` '
      . 'it at all')
        or BAIL_OUT("scripts/run-tests.pl is not yet require-safe (spec section 2.2) -- requiring it as "
                  . "it stands today would run a real, unbounded sweep inside this test process and then "
                  . "call exit() before any assertion below could run. Nothing else in this file (Parts "
                  . "A/B/C/D, the AC-4 live regression guard) can run until the run_sweep()/'unless "
                  . "caller()' structural change lands.");

    ok(_is_require_safe("sub run_sweep {\n    my \@argv = \@_;\n    return 0;\n}\n"
                       . "exit run_sweep(\@ARGV) unless caller();\n"),
        'safety-gate counter-fixture: the detector DOES pass a fabricated already-safe source, '
      . 'proving its failure above is a real finding, not a tautology');
    ok(!_is_require_safe("sub run_sweep { return 0 }\nexit run_sweep(\@ARGV);\n"),
        'safety-gate counter-fixture: a run_sweep with no "unless caller()" guard at all is correctly '
      . 'still flagged unsafe');
}

# =============================================================================
# FIX-BATCH AMENDMENT A1 (CRITICAL C1, ORACLE AMENDMENT AUTHORISATION item 1)
# + A4-F (H3 wiring mutation coverage, "executing at require time"). Runs in
# an ISOLATED CHILD PROCESS, deliberately never in-process (this file's own
# `require $IMPL;` two lines below already happened once by the time any
# in-process check could run, and re-requiring in the same process cannot
# reproduce "was MSYS2_ARG_CONV_EXCL unset before a FIRST require" at all).
# MEASURED, per the authorisation's own instruction ("measure the variable
# before and after a require in a child process; do not read source"):
#   (a) the child process starts with MSYS2_ARG_CONV_EXCL deliberately
#       deleted, then requires scripts/run-tests.pl and reports what the
#       variable is afterward;
#   (b) the child's CWD is a freshly-created, otherwise-empty directory, so
#       ANY file written as a require-time side effect (the shape of the
#       red-team's mutation F: "a real system($^X, ...) that writes a file,
#       added at require time", measured passing the oracle 88/88 before
#       this amendment) is directly observable afterward, with no need to
#       guess where such a mutation might write.
# =============================================================================
{
    my $cwd_dir = tempdir(CLEANUP => 1);
    my $child_script = <<'CHILD';
use strict;
use warnings;
delete $ENV{MSYS2_ARG_CONV_EXCL};
require $ENV{LANE_ROUTING_REQUIRE_TARGET};
print "MSYS_AFTER=" . (exists $ENV{MSYS2_ARG_CONV_EXCL} ? $ENV{MSYS2_ARG_CONV_EXCL} : '<unset>') . "\n";
CHILD
    my $child_path = write_fixture($cwd_dir, 'require-only-child.pl', $child_script);

    my ($out_fh, $out_tmp) = File::Temp::tempfile();
    close $out_fh;
    local $ENV{LANE_ROUTING_REQUIRE_TARGET} = $IMPL;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        chdir($cwd_dir) or POSIX::_exit(125);
        open(STDOUT, '>', $out_tmp) or POSIX::_exit(126);
        open(STDERR, '>&', \*STDOUT) or POSIX::_exit(126);
        exec($^X, $child_path) or POSIX::_exit(127);
    }
    waitpid($pid, 0);
    my $rc = $? >> 8;
    open my $rfh, '<', $out_tmp or die "open $out_tmp: $!";
    local $/; my $out = <$rfh>; close $rfh; unlink $out_tmp;
    $out = '' unless defined $out;

    is($rc, 0, 'A1/A4-F: an isolated child process requiring scripts/run-tests.pl (never this file\'s '
      . 'own already-loaded copy) exits 0');
    like($out, qr/^MSYS_AFTER=<unset>\n?\z/,
        'A1 (C1 regression, MEASURED not read from source): requiring scripts/run-tests.pl in a fresh '
      . 'child process where MSYS2_ARG_CONV_EXCL was unset beforehand leaves it unset afterward -- the '
      . 'require of run-tests-container.pl must never leak that mutation into the requiring process, '
      . 'which every one of the ~350 swept test children would otherwise inherit');

    opendir(my $dh, $cwd_dir) or die "opendir $cwd_dir: $!";
    my @entries = grep { $_ ne '.' && $_ ne '..' && $_ ne 'require-only-child.pl' } readdir($dh);
    closedir $dh;
    is_deeply(\@entries, [],
        'A4-F (H3 wiring mutation coverage -- "executing at require time" mutation, measured passing '
      . '88/88 before this amendment): merely requiring scripts/run-tests.pl creates no new file in the '
      . 'child\'s working directory -- a system() call executed at require time would be visible here');
}

require $IMPL;

# =============================================================================
# PART A (AC-1, AC-3, AC-4; spec section 3.2) -- the precedence rule, as a
# case table. Each row calls classify_file() on a synthetic File::Temp
# fixture. Fixture bodies are ESCAPED STRING LITERALS, never heredocs --
# a marker-shaped line inside a heredoc is currently accepted as real by
# TestPlatform::parse_marker (bug 96a7), which would corrupt these fixtures'
# own declared markers if built any other way.
# =============================================================================
my $FIXDIR = tempdir(CLEANUP => 1);

# --- row 1: plain host -> host-parallel -----------------------------------
{
    my $f = write_fixture($FIXDIR, 'row1-host-plain.t',
        "#!/usr/bin/env perl\n# platform: host\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n");
    my $d = classify_file($f);
    is($d->{lane}, 'host-parallel', 'Part A row 1: plain host file -> host-parallel');
    is($d->{serial}, 0, 'Part A row 1: serial flag is 0');
}

# --- row 2: plain any -> container -------------------------------------------
{
    my $f = write_fixture($FIXDIR, 'row2-any-plain.t',
        "#!/usr/bin/env perl\n# platform: any\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n");
    my $d = classify_file($f);
    is($d->{lane}, 'container', 'Part A row 2: plain any file -> container');
    is($d->{serial}, 0, 'Part A row 2: serial flag is 0');
}

# --- row 3: plain linux -> container (zero real instances today; rule must
# exist anyway, DC-1's "what happens to linux" ask) ---------------------------
{
    my $f = write_fixture($FIXDIR, 'row3-linux-plain.t',
        "#!/usr/bin/env perl\n# platform: linux\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n");
    my $d = classify_file($f);
    is($d->{lane}, 'container', 'Part A row 3: plain linux file -> container');
}

# --- row 4 (THE COLLISION, AC-3): any + TestSandbox -> host-serial -----------
{
    my $f = write_fixture($FIXDIR, 'row4-any-serial-collision.t',
        "#!/usr/bin/env perl\n# platform: any\n${TSNS}podman_run_capture(); # a genuine ${TSNS} "
      . "reference, not a comment mention, trips the serial heuristic\n"
      . "print \"ok 1 - fixture pass\\n\"; exit 0;\n");
    my $d = classify_file($f);
    is($d->{lane}, 'host-serial',
        'Part A row 4 (THE COLLISION, AC-3): an any-marked, serial-classified file -> host-serial, '
      . 'NOT container -- the serial heuristic outranks the marker value');
    is($d->{serial}, 1, 'Part A row 4: serial flag is 1');
}

# --- row 5: host + podman_bin -> host-serial (no-op relative to today) ----
{
    my $f = write_fixture($FIXDIR, 'row5-host-serial.t',
        "#!/usr/bin/env perl\n# platform: host\n${TSNS}podman_bin(); # calls podman_bin() via "
      . "${TSNS}, a genuine load-shaped reference\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n");
    my $d = classify_file($f);
    is($d->{lane}, 'host-serial', 'Part A row 5: a serial-classified host file -> host-serial');
}

# --- row 6: linux + probe_image -> host-serial (generalised rule, zero real
# instances today) ------------------------------------------------------------
{
    my $f = write_fixture($FIXDIR, 'row6-linux-serial.t',
        "#!/usr/bin/env perl\n# platform: linux\n${TSNS}probe_image(); # calls probe_image() via "
      . "${TSNS}, a genuine load-shaped reference\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n");
    my $d = classify_file($f);
    is($d->{lane}, 'host-serial', 'Part A row 6: a serial-classified linux file -> host-serial');
}

# --- row 7 (AC-4, DC-4): no marker at all -> refused -------------------------
{
    my $f = write_fixture($FIXDIR, 'row7-unmarked.t',
        "#!/usr/bin/env perl\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n");
    my $d = classify_file($f);
    is($d->{lane}, 'refused', 'Part A row 7 (AC-4): an unmarked file -> refused');
    is($d->{marker}{outcome}, 'absent', 'Part A row 7: marker outcome is "absent"');
}

# --- row 8: illegal marker + serial-shaped body -> refused (marker gate runs
# BEFORE the serial heuristic even applies) -----------------------------------
{
    my $f = write_fixture($FIXDIR, 'row8-illegal-marker-serial-shaped.t',
        "#!/usr/bin/env perl\n# platform: macos\n# calls TestSandbox internally\n"
      . "print \"ok 1 - fixture pass\\n\"; exit 0;\n");
    my $d = classify_file($f);
    is($d->{lane}, 'refused',
        'Part A row 8: an illegal-marker, serial-shaped file is still refused -- never silently forced '
      . 'into host-serial just because its body matches the serial heuristic');
    is($d->{marker}{outcome}, 'invalid', 'Part A row 8: marker outcome is "invalid"');
    is($d->{marker}{reason}, 'unrecognized-value', 'Part A row 8: marker reason is "unrecognized-value"');
}

# --- row 9 (AC-1's substance): any + a backfill-signal string, NO serial-
# heuristic substring -> container (the signal has NO effect on the lane) ----
{
    my $f = write_fixture($FIXDIR, 'row9-any-backfill-signal-only.t',
        "#!/usr/bin/env perl\n# platform: any\n# mentions MSYS2_ARG_CONV_EXCL, a backfill-scanner signal, "
      . "not a serial-heuristic substring\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n");
    my $d = classify_file($f);
    is($d->{lane}, 'container',
        'Part A row 9 (AC-1): a backfill-signal string (MSYS2_ARG_CONV_EXCL) in the body has NO effect '
      . 'on the lane -- only the declared marker and the (unrelated) serial heuristic do');
}

# --- row 10: same proof, for the host value -------------------------------
{
    my $f = write_fixture($FIXDIR, 'row10-host-backfill-signal-only.t',
        "#!/usr/bin/env perl\n# platform: host\n# mentions cygpath and podman machine, backfill-scanner "
      . "signals with no underscore-joined serial-heuristic substring anywhere in this line\n"
      . "print \"ok 1 - fixture pass\\n\"; exit 0;\n");
    my $d = classify_file($f);
    is($d->{lane}, 'host-parallel',
        'Part A row 10 (AC-1): the same proof for the host value -- cygpath/"podman machine" in the '
      . 'body have NO effect on the lane');
}

# --- classify_file's other contract points: unreadable -> undef -------------
{
    my $ghost = File::Spec->catfile($FIXDIR, 'does-not-exist-ghost.t');
    ok(!-e $ghost, 'Part A setup: the ghost fixture path genuinely does not exist');
    is(classify_file($ghost), undef,
        'Part A: classify_file() returns undef for an unreadable/vanished path (unchanged silent-skip '
      . 'precedent, section 5.7) -- never reachable as "refused" or any real lane');
}

# =============================================================================
# PART B (section 3.3) -- hermetic podman-unavailable / image-absent cases.
# No opt-in flag, no real podman required -- deterministic via `local`
# typeglob overrides on the RunTestsContainerLane:: namespace, safe
# specifically because section 2.3 put every overridable name in its own
# namespace, never main::.
# =============================================================================
{
    local *RunTestsContainerLane::podman_bin = sub { '' };
    my @r = _run_container_batch('/abs/fake/a.t', '/abs/fake/b.t');
    is(scalar(@r), 2, 'Part B (podman-unavailable): one infra-failure result per input file');
    is(scalar(grep { ($_->{container_infra} // 0) == 1 } @r), 2,
        'Part B: ...each result is flagged container_infra => 1');
    is(scalar(grep { ($_->{rc} // -1) == 1 && ($_->{notok} // -1) == 0 } @r), 2,
        'Part B: ...each result carries rc => 1, notok => 0 (nothing ran, no TAP was ever produced)');
    like($r[0]{out}, qr/no docker\/podman CLI found on PATH/,
        'Part B: pinned reason text names the missing CLI');
    is($r[0]{file}, '/abs/fake/a.t',
        'Part B (section 2.4.1): file key is the ORIGINAL absolute path, never a relpath');
    is($r[1]{file}, '/abs/fake/b.t', 'Part B: ...same for the second input file');
}
{
    local *RunTestsContainerLane::podman_bin    = sub { 'fake-podman' };
    local *RunTestsContainerLane::image_present = sub { 0 };
    my @r = _run_container_batch('/abs/fake/c.t');
    is(scalar(@r), 1, 'Part B (image-absent): one infra-failure result');
    like($r[0]{out}, qr/\Qimage 'claude-sandbox:latest' is not present locally\E/,
        q{Part B: pinned image-absent reason text, $IMAGE interpolated verbatim});
    is($r[0]{container_infra}, 1, 'Part B: the image-absent result is also flagged container_infra');
}
{
    # Zero-file edge case, non-vacuity: _run_container_batch(()) must return
    # () and must call NO RunTestsContainerLane::* sub at all -- proven by
    # making every plausible entry point die if invoked.
    local *RunTestsContainerLane::podman_bin    = sub { die "podman_bin called on empty input\n" };
    local *RunTestsContainerLane::image_present = sub { die "image_present called on empty input\n" };
    my @r = eval { _run_container_batch() };
    is($@, '', 'Part B (zero files): _run_container_batch() does not die');
    is_deeply(\@r, [],
        'Part B (zero files): _run_container_batch() returns () for zero input files without calling '
      . 'any RunTestsContainerLane:: sub (each would have died above if it had)');
}

# =============================================================================
# PART C (section 3.4, opt-in, CCPRAXIS_CONTAINER_LANE_LIVE=1, mirrors
# package 05's own container-lane.t gate) -- one real, end-to-end
# _run_container_batch call against a dynamically-discovered live target.
# Skipped by default so no unattended sweep ever touches podman.
# =============================================================================
{
    my $PART_C_TEST_COUNT = 6;   # ok(defined $target) + 5 live assertions
    SKIP: {
        my $reason;
        if (!$ENV{CCPRAXIS_CONTAINER_LANE_LIVE}) {
            $reason = 'set CCPRAXIS_CONTAINER_LANE_LIVE=1 to run Part C (live, in-container) assertions; '
                    . 'skipped by default so no unattended sweep ever touches podman';
        }
        my $podman;
        if (!$reason) {
            $podman = RunTestsContainerLane::podman_bin();
            $reason = 'no docker/podman CLI on PATH' unless $podman;
        }
        if (!$reason && !RunTestsContainerLane::image_present($podman, $RunTestsContainerLane::IMAGE)) {
            $reason = "image '$RunTestsContainerLane::IMAGE' is not present locally -- Part C needs a "
                     . 'real image to run against';
        }
        skip $reason, $PART_C_TEST_COUNT if $reason;

        my @real_files = sort glob("$REPO_ROOT/plugins/*/tests/t/*.t");
        my ($target) = grep { (classify_file($_) // {})->{lane} eq 'container' } @real_files;
        ok(defined $target,
            'Part C: a live any/linux-marked, non-serial-classified file exists in the real tree to target');

        SKIP: {
            skip 'no container-lane-eligible file found in the real tree', $PART_C_TEST_COUNT - 1
                unless defined $target;

            my $ok = eval {
                local $SIG{ALRM} = sub { die "Part C timed out after 120 seconds\n" };
                alarm(120);

                my @r = _run_container_batch($target);
                is(scalar(@r), 1, 'Part C: exactly one result for the one live target');
                is($r[0]{file}, $target, 'Part C (section 2.4.1): file key is the original absolute path');
                is($r[0]{rc}, 0,
                    'Part C: the discovered file is a real, currently-green repo test -- a genuine run '
                  . 'must pass');
                ok(!$r[0]{container_infra}, 'Part C: container_infra is falsy for a genuine run');

                my (undef, $ps_after) = RunTestsContainerLane::_podman_capture(
                    RunTestsContainerLane::build_ps_argv($podman));
                unlike($ps_after // '', qr/ccpraxis-container-lane-/,
                    'Part C (disposal, obligation a): no lane container remains in `podman ps -a` afterward');

                alarm(0);
                1;
            };
            my $err = $@;
            alarm(0);
            fail("Part C aborted before completing (forced cleanup not attempted -- see err): $err")
                unless $ok;
        }
    }
}

# =============================================================================
# PART D (AC-2, AC-3, AC-6/DC-6 scoped) -- the enumerated, non-sampled proof.
# Three independent set-equality assertions, each computed by re-deriving
# the expected set from TestPlatform::parse_marker + the identical serial
# regex written out fresh here -- never by trusting classify_file to grade
# itself. Bug 20260916-162952-5ae3 established a sweep's own red/green
# output is unreliable in both directions, so this NEVER runs a sweep.
# =============================================================================
{
    my @real_files = sort glob("$REPO_ROOT/plugins/*/tests/t/*.t");
    ok(scalar(@real_files) >= 300,
        'Part D floor, non-vacuity: at least 300 real .t files were found by a fresh glob() at assertion '
      . 'time (got ' . scalar(@real_files) . ') -- never the drifting true count (350 as of this writing)');

    my (@by_classify_hp, @by_classify_c, @by_classify_hs, @by_classify_refused);
    for my $f (@real_files) {
        my $d = classify_file($f) or next;   # unreadable -- excluded from every set below
        push @by_classify_hp,      $f if $d->{lane} eq 'host-parallel';
        push @by_classify_c,       $f if $d->{lane} eq 'container';
        push @by_classify_hs,      $f if $d->{lane} eq 'host-serial';
        push @by_classify_refused, $f if $d->{lane} eq 'refused';
    }

    my (@expect_hp, @expect_c, @expect_hs, @expect_refused);
    for my $f (@real_files) {
        open my $fh, '<', $f or next;
        my $src = do { local $/; <$fh> };
        close $fh;
        my $m = TestPlatform::parse_marker($src);
        if ($m->{outcome} ne 'legal') { push @expect_refused, $f; next }
        my $code = join "\n", grep { !/^\s*#/ } split /\n/, $src, -1;
        my $serial = ($code =~ /\b(?:use|require)\s+TestSandbox\b/ || $code =~ /\bTestSandbox::/) ? 1 : 0;
        if    ($serial)                  { push @expect_hs, $f }
        elsif ($m->{value} eq 'host') { push @expect_hp, $f }
        else                              { push @expect_c,  $f }
    }

    is_deeply([sort @by_classify_hp], [sort @expect_hp],
        'AC-6/DC-6 (scoped): host-parallel set == host-marked, non-serial-classified files, enumerated '
      . 'and compared -- never sampled');
    is_deeply([sort @by_classify_c], [sort @expect_c],
        'AC-2/DC-2: container set == any/linux-marked, non-serial-classified files, enumerated and '
      . 'compared -- never sampled');
    is_deeply([sort @by_classify_hs], [sort @expect_hs],
        'AC-3/DC-3: host-serial set == serial-classified files regardless of marker value, enumerated and '
      . 'compared -- proving membership is UNCHANGED from today\'s pre-routing @serial (same regex, same '
      . 'files)');
    is_deeply([sort @by_classify_refused], [sort @expect_refused],
        'AC-4/DC-4 (enumerated, not sampled): refused set == every file whose marker is not legal, across '
      . 'the whole real tree -- the marker gate survives routing for every file, not just a hand-picked one');

    # The corrected DC-6 host set as a single, literal union -- the property
    # the spec's own section 0.3 and the ledger's STEP 2 GATE entry both
    # independently pin: host set == host UNION serial-classified, NOT
    # host alone.
    my %expect_host = map { $_ => 1 } (@expect_hp, @expect_hs);
    my %by_classify_host = map { $_ => 1 } (@by_classify_hp, @by_classify_hs);
    is_deeply([sort keys %by_classify_host], [sort keys %expect_host],
        'DC-6 (corrected, ledger STEP 2 GATE + spec section 0.3): the host set is EXACTLY '
      . '(host-marked files) UNION (serial-classified files), never the host set alone');
}

# =============================================================================
# FIX-BATCH AMENDMENT A2 (HIGH H1, ORACLE AMENDMENT AUTHORISATION item 2): a
# container-batch child that dies without writing its result file must make
# the sweep FAIL, never report "all green". Both halves of the fix are
# exercised, each forcing the real failure from inside a REAL run_sweep()
# call in a dedicated subprocess (never in-process -- section 2.2.1 forbids
# calling run_sweep() from this file's own process): a catchable die inside
# _run_container_batch (podman_bin, materialize_tree, etc. all reach the same
# undefended child before this fix) and an uncatchable POSIX::_exit() that
# leaves nothing for an eval to catch at all.
# =============================================================================
{
    my $container_fixture = write_fixture($FIXDIR, 'a2-h1-die.t',
        "#!/usr/bin/env perl\n# platform: any\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n");
    my $state_dir = tempdir(CLEANUP => 1);
    my $child_script = <<'CHILD';
use strict;
use warnings;
require $ENV{LANE_ROUTING_REQUIRE_TARGET};
no warnings 'redefine';
*RunTestsContainerLane::podman_bin = sub { die "H1-FORCED-DIE: podman_bin invoked\n" };
exit run_sweep(@ARGV);
CHILD
    my $res = _spawn_child_perl($child_script, [$container_fixture],
        { LANE_ROUTING_REQUIRE_TARGET     => $IMPL,
          CCPRAXIS_CONTAINER_LANE_ENABLED => '1',
          CCPRAXIS_TEST_STATE_DIR         => $state_dir });

    isnt($res->{rc}, 0,
        'A2 (H1, catchable die): a container-batch child that dies inside _run_container_batch (forced '
      . 'here via a died podman_bin()) makes the sweep exit NON-ZERO -- never the "all green, exit 0" '
      . 'the red-team measured with 232 of 351 real files silently unaccounted for');
    unlike($res->{out}, qr/\ball green\b/,
        'A2 (H1, catchable die): the sweep report does NOT claim "all green" when the container-lane '
      . 'batch died before producing a real result');
    my $base = File::Basename::basename($container_fixture);
    like($res->{out}, qr/\Q$base\E/,
        'A2 (H1, catchable die): the file the dead batch was responsible for is named in the report -- '
      . 'never silently dropped from every list the sweep produces');
}
{
    my $container_fixture = write_fixture($FIXDIR, 'a2-h1-hardkill.t',
        "#!/usr/bin/env perl\n# platform: any\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n");
    my $state_dir = tempdir(CLEANUP => 1);
    my $child_script = <<'CHILD';
use strict;
use warnings;
use POSIX ();
require $ENV{LANE_ROUTING_REQUIRE_TARGET};
no warnings 'redefine';
*RunTestsContainerLane::podman_bin = sub { POSIX::_exit(137) };   # no eval anywhere can catch this
exit run_sweep(@ARGV);
CHILD
    my $res = _spawn_child_perl($child_script, [$container_fixture],
        { LANE_ROUTING_REQUIRE_TARGET     => $IMPL,
          CCPRAXIS_CONTAINER_LANE_ENABLED => '1',
          CCPRAXIS_TEST_STATE_DIR         => $state_dir });

    isnt($res->{rc}, 0,
        'A2 (H1, uncatchable child death -- the OTHER half of the fix, the reap-loop fallback rather '
      . 'than the eval wrap): a batch child killed outright (POSIX::_exit, nothing an eval could ever '
      . 'catch) before writing anything still makes the sweep exit non-zero, never "all green"');
    unlike($res->{out}, qr/\ball green\b/,
        'A2 (H1, uncatchable child death): the report does not claim "all green" when the batch child '
      . 'was killed before writing its result file at all');
}

# =============================================================================
# FIX-BATCH AMENDMENT A3 (HIGH H2, ORACLE AMENDMENT AUTHORISATION item 3):
# the fork() at the container-batch spawn must check `defined`, proven by
# BEHAVIOUR under a forced fork() failure, never by matching source text.
# CORE::GLOBAL::fork is overridden BEFORE scripts/run-tests.pl is required in
# a fresh subprocess (the override must be visible at compile time of the
# code calling bare fork() -- installing it any later, or in this file's own
# already-loaded process, would not affect already-compiled calls). With
# every fork() forced to fail, the pre-fix code's "$pid == 0" (no `defined`
# check) misread the failure as "I am the child", ran the whole batch INLINE
# in the sweep's own process, and called exit(0) before the report, the
# serial phase or the state write ever ran.
# =============================================================================
{
    my $container_fixture = write_fixture($FIXDIR, 'a3-h2-forkfail.t',
        "#!/usr/bin/env perl\n# platform: any\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n");
    my $state_dir = tempdir(CLEANUP => 1);
    my $child_script = <<'CHILD';
use strict;
use warnings;
BEGIN { *CORE::GLOBAL::fork = sub { return undef } }
require $ENV{LANE_ROUTING_REQUIRE_TARGET};
exit run_sweep(@ARGV);
CHILD
    my $res = _spawn_child_perl($child_script, [$container_fixture],
        { LANE_ROUTING_REQUIRE_TARGET     => $IMPL,
          CCPRAXIS_CONTAINER_LANE_ENABLED => '1',
          CCPRAXIS_TEST_STATE_DIR         => $state_dir });

    isnt($res->{rc}, 0,
        'A3 (H2): with every fork() forced to fail, the container-lane batch is recorded as an infra '
      . 'failure (rc != 0) rather than the pre-fix "undef == 0 is true" mis-branch that ran the batch '
      . 'inline and exited 0 mid-sweep');
    like($res->{out}, qr/\d+\s+files\s+\d+s\s+wall/,
        'A3 (H2): the sweep\'s own summary line actually printed -- proving run_sweep() continued past '
      . 'the fork()-failure branch all the way to the report/state-write, rather than the pre-fix inline '
      . 'exit(0) that skipped the report, the serial phase and the state write entirely');
}

# =============================================================================
# FIX-BATCH AMENDMENT A4 (HIGH H3, ORACLE AMENDMENT AUTHORISATION item 4) --
# WIRING MUTATION COVERAGE. Reproduces three of the red-team's own named
# mutations (dropping the container list into nothing, deleting the serial
# phase, and inverting --fast) as real, bounded run-tests.pl subprocesses
# against tiny File::Temp fixtures -- the same already-blessed
# RunnerStateHarness::run_runner_bounded() the AC-4 guard below uses. The
# fourth named mutation (executing at require time) is amendment A1's own
# block above (A4-F). Each block here is a pinned CORRECT-behaviour
# assertion that the red-team's own report measured a mutant PASSING
# (88/88) before this amendment existed.
# =============================================================================
{
    # A4-A: "capability gate drops @container instead of folding it into
    # @host_parallel" (mutation A, the package's own named worst case -- a
    # file that runs in no lane at all).
    my $green_windows = write_fixture($FIXDIR, 'a4a-host-green.t',
        "#!/usr/bin/env perl\n# platform: host\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n");
    my $red_any = write_fixture($FIXDIR, 'a4a-any-red.t',
        "#!/usr/bin/env perl\n# platform: any\nprint \"not ok 1 - forced failure\\n\"; exit 1;\n");
    my $state_dir = tempdir(CLEANUP => 1);
    my $res = RunnerStateHarness::run_runner_bounded(
        args    => [$green_windows, $red_any],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir },
        timeout => 20,
    );
    is($res->{rc}, 1,
        'A4-A (mutation A, "drops @container instead of folding it"): with the container lane OFF '
      . '(default), a plain any-marked RED file still runs -- folded into the host-parallel set, never '
      . 'dropped -- and its failure surfaces in the sweep\'s exit code');
    my $base = File::Basename::basename($red_any);
    like($res->{out}, qr/\Q$base\E/,
        'A4-A: the any-marked red file is named in the report -- proving it actually ran rather than '
      . 'being silently discarded');
}
{
    # A4-D: "the serial phase deleted -- all 16 podman-starting tests never
    # run".
    my $serial_red = write_fixture($FIXDIR, 'a4d-serial-red.t',
        "#!/usr/bin/env perl\n# platform: any\n# this fixture references TestSandbox to trip the serial "
      . "heuristic\nprint \"not ok 1 - forced failure\\n\"; exit 1;\n");
    my $state_dir = tempdir(CLEANUP => 1);
    my $res = RunnerStateHarness::run_runner_bounded(
        args    => [$serial_red],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir },
        timeout => 20,
    );
    is($res->{rc}, 1,
        'A4-D (mutation D, "the serial phase deleted"): a serial-classified, any-marked RED file still '
      . 'runs and its failure surfaces -- the serial phase is not silently skippable');
    my $base = File::Basename::basename($serial_red);
    like($res->{out}, qr/\Q$base\E/, 'A4-D: the serial-classified file is named in the report');
}
{
    # A4-E: "--fast empties @container instead of @host_serial".
    my $serial_red = write_fixture($FIXDIR, 'a4e-serial-red.t',
        "#!/usr/bin/env perl\n# platform: any\n${TSNS}podman_run_capture(); # a genuine ${TSNS} "
      . "reference, not a comment mention, trips the serial heuristic\n"
      . "print \"not ok 1 - forced failure\\n\"; exit 1;\n");
    my $any_red = write_fixture($FIXDIR, 'a4e-any-red.t',
        "#!/usr/bin/env perl\n# platform: any\nprint \"not ok 1 - forced failure\\n\"; exit 1;\n");
    my $serial_base = File::Basename::basename($serial_red);
    my $any_base    = File::Basename::basename($any_red);

    my $state_dir1 = tempdir(CLEANUP => 1);
    my $res_no_fast = RunnerStateHarness::run_runner_bounded(
        args    => [$serial_red, $any_red],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir1 },
        timeout => 20,
    );
    like($res_no_fast->{out}, qr/\Q$serial_base\E/,
        'A4-E setup: without --fast, the serial-classified red file runs and appears in the report');
    like($res_no_fast->{out}, qr/\Q$any_base\E/,
        'A4-E setup: without --fast, the plain any-marked red file also runs and appears in the report');

    my $state_dir2 = tempdir(CLEANUP => 1);
    my $res_fast = RunnerStateHarness::run_runner_bounded(
        args    => ['--fast', $serial_red, $any_red],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir2 },
        timeout => 20,
    );
    # The claim is that the file was not RUN, and the evidence is that it is not
    # in the RED report -- a forced-failure fixture that executed would be there.
    #
    # It used to be asserted as "the basename appears nowhere in the output",
    # which stopped being the same claim when --fast started NAMING what it
    # skipped (report 20260918-042312-02db: reporting `0 serial` for a run that
    # dropped sixteen files reads as "there were none"). The basename now appears
    # in the skip notice, which is the very fact this assertion wants to be true.
    # Split so the two cannot be confused again.
    my ($red_section) = $res_fast->{out} =~ /^RED:\n(.*?)(?=\n\n|\z)/ms;
    $red_section //= '';
    unlike($red_section, qr/\Q$serial_base\E/,
        'A4-E (mutation E, "inverting --fast"): with --fast, the serial-classified red file is '
      . 'EXCLUDED -- it is absent from the RED report, so it did not run');
    like($res_fast->{out}, qr/--fast skipped .*\n(?:.*\n)*?\s+\Q$serial_base\E/,
        'A4-E: and --fast SAYS it skipped that file rather than dropping it silently');
    like($res_fast->{out}, qr/\Q$any_base\E/,
        'A4-E: with --fast, the plain any-marked red file STILL runs -- --fast never touches the '
      . 'container-classified set (folded into host-parallel with the lane off), only @host_serial');
}

# =============================================================================
# FIX-BATCH AMENDMENT A5 (MEDIUM M1, ORACLE AMENDMENT AUTHORISATION item 5):
# Decision 18 purity, proven DYNAMICALLY rather than by a source regex, to
# close two textual evasions the red-team demonstrated: "$ENV {X}" (a space
# before the subscript, which \$ENV\{ does not match) and "$_[1]" (a second
# positional argument, which an arity regex over only the first "my (...) ="
# line does not match). classify_file() must return the identical verdict
# for the same file regardless of a hostile %ENV/@ARGV, and must ignore a
# second positional argument entirely.
# =============================================================================
{
    my $f = write_fixture($FIXDIR, 'a5-purity-dynamic.t',
        "#!/usr/bin/env perl\n# platform: any\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n");
    my $baseline = classify_file($f);

    local %ENV = (%ENV,
        CCPRAXIS_CONTAINER_LANE_ENABLED => '1',
        CCPRAXIS_FORCE_HOST             => '1',   # a plausible evasion name, not a real switch
    );
    local @ARGV = ('--fast', '--jobs', '1');
    my $hostile = classify_file($f);
    is($hostile->{lane}, $baseline->{lane},
        'A5 (closes the "$ENV {X}"-with-a-space textual evasion): classify_file() returns the identical '
      . 'verdict for the same file under a hostile %ENV/@ARGV as under a clean one, proven by BEHAVIOUR '
      . 'rather than a source regex');

    my $extra = classify_file($f, 'a-second-positional-argument-nobody-passes-today');
    is($extra->{lane}, $baseline->{lane},
        'A5 (closes the "$_[1]" textual evasion): classify_file() ignores a second positional argument '
      . 'entirely -- passing one changes nothing about the verdict');
}

# =============================================================================
# FIX-BATCH AMENDMENT A6 (MEDIUM M3 + M4, ORACLE AMENDMENT AUTHORISATION item
# 6): the opt-in must not be inherited by a nested sweep, and the value
# parsing must treat false/no/off/0 as OFF.
# =============================================================================
{
    # M3: a nested sweep must not inherit the opt-in.
    local $ENV{CCPRAXIS_CONTAINER_LANE_ENABLED} = '1';
    my $probe = write_fixture($FIXDIR, 'a6-nested-env-probe.t',
        "#!/usr/bin/env perl\n# platform: any\n"
      . "if (exists \$ENV{CCPRAXIS_CONTAINER_LANE_ENABLED}) {\n"
      . "    print \"not ok 1 - lane var leaked into child: \$ENV{CCPRAXIS_CONTAINER_LANE_ENABLED}\\n\"; exit 1;\n"
      . "}\n"
      . "print \"ok 1 - lane var absent in child\\n\"; exit 0;\n");
    my $r = run_one($probe);
    is($r->{rc}, 0,
        'A6 (M3, opt-in inherited by nested sweeps): a child process spawned by run_one() does NOT '
      . 'inherit CCPRAXIS_CONTAINER_LANE_ENABLED even when the sweeping process itself has it set -- one '
      . 'operator opt-in must not fan out into containers started by nested sweeps');
}
{
    # M4: false/no/off/0 must all mean OFF (only 1/true/yes/on mean ON).
    for my $off_value (qw(false no off 0)) {
        my $red_any = write_fixture($FIXDIR, "a6-value-off-$off_value.t",
            "#!/usr/bin/env perl\n# platform: any\nprint \"not ok 1 - forced failure\\n\"; exit 1;\n");
        my $state_dir = tempdir(CLEANUP => 1);
        my $res = RunnerStateHarness::run_runner_bounded(
            args    => [$red_any],
            env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir,
                         CCPRAXIS_CONTAINER_LANE_ENABLED => $off_value },
            timeout => 20,
        );
        is($res->{rc}, 1,
            "A6 (M4): CCPRAXIS_CONTAINER_LANE_ENABLED=$off_value is treated as OFF -- the file still "
          . 'runs on the host (folded from @container) and its failure surfaces normally');
        unlike($res->{out}, qr/CONTAINER LANE/,
            "A6 (M4): CCPRAXIS_CONTAINER_LANE_ENABLED=$off_value never reaches the container-lane "
          . 'machinery at all -- no "CONTAINER LANE" message of any kind appears');
        like($res->{out}, qr/0\s+container\)/,
            "A6 (M4): CCPRAXIS_CONTAINER_LANE_ENABLED=$off_value -- the sweep's own summary line shows "
          . '0 container files, confirming the fold-back actually happened');
        like($res->{out}, qr/\Qnot ok 1 - forced failure\E/,
            "A6 (M4): CCPRAXIS_CONTAINER_LANE_ENABLED=$off_value -- the fixture's OWN real failure text "
          . 'appears in the report, proving it genuinely executed on the host rather than being turned '
          . 'into a synthetic infra-failure result');
    }

    # Truthy control: a genuinely-on value still routes to the container
    # lane. PATH is restricted to ONLY the directory holding this host's own
    # perl binary -- never emptied outright, because $^X on this host is the
    # bare string "perl" (PATH-relative, per $Config{perlpath}), and
    # RunnerStateHarness::spawn_runner's own `exec($^X, ...)` needs SOME
    # PATH to find it; an empty PATH breaks the harness itself before
    # run-tests.pl is ever reached, not just podman_bin()'s lookup. This
    # restricted PATH still can't resolve docker.exe/podman.exe, so it
    # deterministically hits the "no docker/podman CLI found" infra-failure
    # branch without ever touching a real podman.
    #
    # NOTE: the infra-failure MESSAGE text ("CONTAINER LANE UNAVAILABLE:
    # ...") is not asserted here -- it lives only in the synthesized
    # result's `out` field, which run_sweep's own report only ever prints
    # lines from that match /^not ok/, and the message is prose, not TAP, so
    # it never reaches stdout. What DOES reliably distinguish "routed to the
    # container lane, unavailable" from "ran for real on the host" on the
    # real CLI surface is exactly what section 2.5 pins in-process (Part B
    # above): rc => 1, notok => 0 (nothing ran, no TAP was ever produced) --
    # visible here as the file's own printed "notok=0" and the summary
    # line's "1 container", together with the fixture's own genuine "not ok
    # 1 - forced failure" text being ABSENT (it was never actually run).
    my $perl_only_path = File::Basename::dirname($Config::Config{perlpath});
    my $red_any_on = write_fixture($FIXDIR, 'a6-value-on.t',
        "#!/usr/bin/env perl\n# platform: any\nprint \"not ok 1 - forced failure\\n\"; exit 1;\n");
    my $state_dir_on = tempdir(CLEANUP => 1);
    my $res_on = RunnerStateHarness::run_runner_bounded(
        args    => [$red_any_on],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir_on,
                     CCPRAXIS_CONTAINER_LANE_ENABLED => '1',
                     PATH => $perl_only_path },
        timeout => 20,
    );
    my $base_on = File::Basename::basename($red_any_on);
    like($res_on->{out}, qr/1\s+container\)/,
        'A6 (M4 control): CCPRAXIS_CONTAINER_LANE_ENABLED=1 (a genuinely truthy value) DOES route the '
      . 'file into the container lane -- the summary line shows 1 container file, never 0');
    like($res_on->{out}, qr/\Q$base_on\E\s+exit=1\s+notok=0/,
        'A6 (M4 control): ...and the file is reported with notok=0 (nothing ran, no TAP was ever '
      . 'produced) -- an infra failure, not a genuine test run');
    unlike($res_on->{out}, qr/\Qnot ok 1 - forced failure\E/,
        'A6 (M4 control): ...and the fixture\'s OWN real failure text never appears -- confirming it '
      . 'was never actually executed, hermetically (no real podman touched: PATH restricted to exclude '
      . 'docker/podman)');
}

# =============================================================================
# AC-4 (DC-4) live regression guard -- a real run-tests.pl subprocess (its
# ordinary CLI invocation, never a `require`) still refuses an unmarked
# file after this package's changes. Bounded via RunnerStateHarness, never
# a bare system()/backticks call.
# =============================================================================
{
    my $STATE_DIR = tempdir(CLEANUP => 1);   # isolates this call from the real
                                              # .ccpraxis-local-data/test-state/last-failures.txt
    my $absent_fixture = write_fixture($FIXDIR, 'ac4-live-unmarked.t',
        "#!/usr/bin/env perl\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n");
    my $res = RunnerStateHarness::run_runner_bounded(
        args    => [$absent_fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $STATE_DIR },
        timeout => 15,
    );
    is($res->{rc}, 1,
        'AC-4 (live regression guard): a real run-tests.pl subprocess still refuses (rc == 1) an unmarked '
      . 'file after routing -- package 03\'s enforcement survives routing, on the real CLI surface, not '
      . 'just via classify_file() in-process');
    my $base = File::Basename::basename($absent_fixture);
    like($res->{out}, qr/PLATFORM MARKER REFUSED:.*\Q$base\E/s,
        'AC-4 (live regression guard): the refusal message still names the file');
}

done_testing();
