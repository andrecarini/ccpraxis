#!/usr/bin/env perl
# platform: any
# Oracle for blueprint package 03-enforce-marker (blueprint test-platform-split).
# Derived ONLY from
# .ccpraxis-local-data/blueprints/test-platform-split/specs/03-enforce-marker-spec.md
# (sections 1-6) and the package ledger's 5 done criteria. NOT derived from any
# implementation: scripts/run-tests.pl does not yet enforce the marker gate at
# the time this file is written, and this file must never add that gate
# itself -- that is the implementer's job, under a review the driver performs
# separately.
#
# THE SOLE DECISION POINT, IN BOTH SURFACES THIS FILE PROVES, IS
# TestPlatform::parse_marker (package 01) -- never a second regex. scan_offenders()
# below (test-local, per spec section 1.5) calls it directly; the real
# scripts/run-tests.pl is driven only as a genuine subprocess via
# RunnerStateHarness::run_runner_bounded, never re-implemented here.
#
# WHY AC-1 IS GREEN TODAY, AND WHY THAT IS NOT A COINCIDENCE (done criterion
# 5, spec AC-10/AC-11): the standing sweep in PART 1 below passes right now
# ONLY because 02-backfill-scan already landed on every real .t file in the
# tree (349 of 349, commit 3411f29). If package 02 and this package were ever
# reordered -- enforcement shipped before the backfill -- PART 1 would turn
# red on day one, for every real file in the tree at once, BY DESIGN. That is
# the ordering dependency Decision 4 calls a hard edge, not a preference, and
# this file proves it live rather than asserting it in a comment.
#
# WHAT IS EXPECTED TO FAIL TODAY, AND WHY: every assertion in PARTs 2, 3, 5
# and 8 that drives a real run-tests.pl subprocess against a markerless or
# invalid-marker fixture expects the process to REFUSE the file (rc == 1, a
# "PLATFORM MARKER REFUSED" message). scripts/run-tests.pl does not do this
# yet -- verified directly: a markerless fixture handed to run-tests.pl today
# is simply executed and, if its own body is TAP-green, reported green (rc ==
# 0), never refused. Those assertions are the ones this package's
# implementation step must turn green. PART 6 additionally expects
# RunnerStateHarness.pm's three fixture-source generators to carry a legal
# platform marker -- the three-line companion fix Decision 16 folded into
# this package's write set -- which is also not applied yet.
#
# WHAT IS EXPECTED TO PASS TODAY, AND WHY THAT IS NOT VACUOUS: PART 1 (the
# real-tree sweep, package 02's own work), every scan_offenders()-only
# assertion in PARTs 2-4 and 7 (pure TestPlatform.pm consumption, already
# correct), and the "positive pairing" halves of PARTs 2 and 8-9 (a
# legally-marked fixture already runs normally, because nothing today stops
# it) are all real, non-vacuous checks against code that already exists --
# not placeholders waiting for the implementation.
#
# NON-VACUITY, PER THIS BLUEPRINT'S STANDING RULE:
#   - AC-4 (done criterion 4, MANDATORY): a markerless counter-fixture is
#     proven to fire on BOTH surfaces (PART 2), paired immediately with a
#     properly-marked fixture proven to be ACCEPTED by both -- a guard that
#     refused everything unconditionally could not pass both halves.
#   - Every sweep over a collection (PART 1's real-tree glob) also asserts
#     the collection is non-empty, with a floor far below the drifting true
#     count (currently 349; this file must never pin that number -- spec
#     section 6).
#   - "Unreadable" and "absent" are proven to be distinct offender tokens
#     (PART 7), never folded into one another.
#
# AN AMBIGUITY IN THE SPEC, RESOLVED HERE (reported to the driver as such):
# section 3's AC-6 says the conflicting-markers/malformed-marker-line reasons
# are proven "via scan_offenders only (in-process, no subprocess spawn
# needed)"; section 3's AC-7, two paragraphs later, requires proving that
# run-tests.pl's OWN refusal message for malformed-marker-line never says "no
# platform marker found" -- a property that lives in run-tests.pl's message
# text (spec section 1.4), not in scan_offenders' token format (spec section
# 1.5), and which scan_offenders literally cannot exercise. PART 5 resolves
# this in favour of AC-7's more explicit, more specific text: it spawns one
# additional bounded subprocess against the malformed-marker-line fixture,
# because this is the exact failure package 01's own header comment names as
# the reason the "malformed-marker-line" reason exists at all.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Basename ();
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

use lib "$Bin/../lib";
use TestPlatform ();
use RunnerStateHarness ();

my $REPO_ROOT = abs_path("$Bin/../../../..");

# =============================================================================
# PART 0 -- helpers
# =============================================================================

# _relpath($abs) -- mirrors run-tests.pl's own _relpath (scripts/run-tests.pl,
# _relpath sub) exactly: File::Spec->abs2rel against $REPO_ROOT, backslashes
# rewritten to forward slashes.
sub _relpath {
    my ($f) = @_;
    my $rel = File::Spec->abs2rel($f, $REPO_ROOT);
    $rel =~ s{\\}{/}g;
    return $rel;
}

# scan_offenders(@files) -- pinned VERBATIM from spec section 1.5. The single
# offender-listing format for this file's own diagnostics.
sub scan_offenders {
    my (@files) = @_;
    my @offenders;
    for my $f (sort @files) {
        my $rel = _relpath($f);
        unless (-r $f) {
            push @offenders, "$rel (unreadable)";
            next;
        }
        my $marker = TestPlatform::parse_marker(TestPlatform::read_prefix($f));
        next if $marker->{outcome} eq 'legal';
        my $detail = $marker->{outcome} eq 'absent' ? 'absent' : "invalid:$marker->{reason}";
        push @offenders, "$rel ($detail)";
    }
    return @offenders;
}

sub write_fixture {
    my ($dir, $name, $content) = @_;
    my $path = File::Spec->catfile($dir, $name);
    open my $fh, '>:raw', $path or die "cannot write fixture $path: $!";
    print {$fh} $content;
    close $fh;
    return $path;
}

# =============================================================================
# PART 1 (AC-1, AC-2, AC-3, AC-10, AC-11) -- the standing, durable check
# against the real tree. Mirrors backfill-scan.t's own PART 4 shape exactly:
# a fresh glob, a floor rather than a pinned count, and a LIVE assertion of
# the ordering dependency rather than a comment claiming it.
# =============================================================================
my @real_files = sort glob("$REPO_ROOT/plugins/*/tests/t/*.t");

ok(scalar(@real_files) >= 200,
    'AC-2 non-vacuity: at least 200 real .t files were found by a fresh glob() at assertion time '
  . '(got ' . scalar(@real_files) . ') -- the same floor backfill-scan.t\'s PART 4 already uses, '
  . 'guarding only against a broken glob path, never pinning the drifting true count');

{
    my @offenders = scan_offenders(@real_files);
    is(scalar(@offenders), 0,
        'AC-1/AC-10/AC-11: every .t under a freshly-globbed plugins/*/tests/t/*.t carries a legal '
      . 'platform marker -- green TODAY ONLY because 02-backfill-scan already landed (349/349, commit '
      . '3411f29); reordering 02-backfill-scan and 03-enforce-marker would turn this red on day one for '
      . 'every real file in the tree at once, by design, not by bug')
        or diag('AC-3: offenders (' . scalar(@offenders) . ' of ' . scalar(@real_files) . "):\n  "
              . join("\n  ", @offenders));
}

# =============================================================================
# PART 2 (AC-4, DC-4 -- MANDATORY, non-vacuity): a counter-fixture .t with no
# marker is created in a temp dir and BOTH surfaces are shown to fire on it,
# paired immediately with a properly-marked positive fixture accepted by
# both -- without the pairing, a guard that refused every file unconditionally
# would still pass the negative half alone.
# =============================================================================
my $FIXDIR    = tempdir(CLEANUP => 1);
my $STATE_DIR = tempdir(CLEANUP => 1);   # isolates every run_runner_bounded call below
                                          # from the real .ccpraxis-local-data/test-state/
                                          # last-failures.txt, same discipline as the
                                          # sibling runner-state-*.t suite.
my $BOUND = 15;

my $ABSENT_BODY = "#!/usr/bin/env perl\nuse strict;\nuse warnings;\nprint \"ok 1 - fixture pass\\n\";\nexit 0;\n";
my $absent_fixture = write_fixture($FIXDIR, 'ac4-absent-marker.t', $ABSENT_BODY);

{
    my @offenders = scan_offenders($absent_fixture);
    is_deeply(\@offenders, [ _relpath($absent_fixture) . ' (absent)' ],
        'AC-4: scan_offenders() reports exactly one offender, "<path> (absent)", for the markerless fixture -- '
      . 'proving the hygiene surface fires on it');
}
{
    my $res = RunnerStateHarness::run_runner_bounded(
        args    => [$absent_fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $STATE_DIR },
        timeout => $BOUND,
    );
    is($res->{rc}, 1, 'AC-4/AC-8: run_runner_bounded rc is exactly 1 for a single markerless target -- '
                     . 'proving the runner surface fires on it too');
    my $base = File::Basename::basename($absent_fixture);
    like($res->{out}, qr/PLATFORM MARKER REFUSED:.*\Q$base\E.*no platform marker found/s,
        'AC-4: the real run-tests.pl subprocess refuses the fixture, naming the file and '
      . '"no platform marker found" (matched on basename + fixed message text, since _relpath '
      . 'may rewrite an out-of-tree path to a "..".relative form -- spec AC-4)');
    like($res->{out}, qr/\QFix: add "# platform: host|linux|any"\E/,
        'AC-9: the refusal message names the fix verbatim (absent-marker wording, spec section 1.4)');
}

# The positive pairing (spec: "assert the positive alongside"): a properly-
# marked fixture of otherwise identical shape is accepted by BOTH surfaces.
my $LEGAL_BODY = "#!/usr/bin/env perl\n# platform: any\nuse strict;\nuse warnings;\nprint \"ok 1 - fixture pass\\n\";\nexit 0;\n";
my $legal_fixture = write_fixture($FIXDIR, 'ac4-legal-marker.t', $LEGAL_BODY);

{
    my @offenders = scan_offenders($legal_fixture);
    is(scalar(@offenders), 0,
        'AC-4 (positive pairing): scan_offenders() reports zero offenders for a properly-marked fixture');
}
{
    my $res = RunnerStateHarness::run_runner_bounded(
        args    => [$legal_fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $STATE_DIR },
        timeout => $BOUND,
    );
    is($res->{rc}, 0,
        'AC-4 (positive pairing): run-tests.pl actually runs (not refuses) the properly-marked fixture -- '
      . 'rc == 0 is possible only if it ran and passed, since a refusal counts as red (exit scalar(@red))');
    unlike($res->{out}, qr/PLATFORM MARKER REFUSED/,
        'AC-4 (positive pairing): no refusal text appears anywhere in the report for the properly-marked fixture');
}

# =============================================================================
# PART 3 (AC-5, DC-3) -- an INVALID value (unrecognized-value) fails as
# loudly as absent, on both surfaces.
# =============================================================================
my $UNRECOG_BODY = "#!/usr/bin/env perl\n# platform: macos\nprint \"ok 1 - fixture pass\\n\";\nexit 0;\n";
my $unrecog_fixture = write_fixture($FIXDIR, 'ac5-unrecognized-value.t', $UNRECOG_BODY);

{
    my @offenders = scan_offenders($unrecog_fixture);
    is_deeply(\@offenders, [ _relpath($unrecog_fixture) . ' (invalid:unrecognized-value)' ],
        'AC-5: scan_offenders() reports "<path> (invalid:unrecognized-value)" for the "macos" fixture');
}
{
    my $res = RunnerStateHarness::run_runner_bounded(
        args    => [$unrecog_fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $STATE_DIR },
        timeout => $BOUND,
    );
    is($res->{rc}, 1, 'AC-5: run_runner_bounded rc is exactly 1 for the "macos" target');
    like($res->{out}, qr/unrecognized platform value "macos"/,
        'AC-5: the real run-tests.pl subprocess names the offending value verbatim -- never silently '
      . 'treated as "any" or skipped');
}

# =============================================================================
# PART 4 (AC-6, DC-3) -- conflicting-markers and malformed-marker-line, both
# proven via scan_offenders only (in-process; TestPlatform.pm's own
# correctness for these two reasons is already exhaustively covered by
# package 01's 129 assertions -- what THIS package must prove is that the
# consuming code treats every non-legal outcome as a refusal and never
# collapses malformed-marker-line into "no marker").
# =============================================================================
my $CONFLICT_BODY = "#!/usr/bin/env perl\n# platform: host\n# platform: linux\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n";
my $conflict_fixture = write_fixture($FIXDIR, 'ac6-conflicting-markers.t', $CONFLICT_BODY);
{
    my @offenders = scan_offenders($conflict_fixture);
    is_deeply(\@offenders, [ _relpath($conflict_fixture) . ' (invalid:conflicting-markers)' ],
        'AC-6: scan_offenders() reports "<path> (invalid:conflicting-markers)" for two conflicting strict marker lines');
}

my $MALFORMED_BODY = "#!/usr/bin/env perl\n# Platform: host\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n";
my $malformed_fixture = write_fixture($FIXDIR, 'ac6-malformed-marker-line.t', $MALFORMED_BODY);
{
    my @offenders = scan_offenders($malformed_fixture);
    is_deeply(\@offenders, [ _relpath($malformed_fixture) . ' (invalid:malformed-marker-line)' ],
        'AC-6: scan_offenders() reports "<path> (invalid:malformed-marker-line)" for a wrong-case marker line -- '
      . 'never "(absent)", which would send whoever wrote it to add a line that is already there');
}

# =============================================================================
# PART 5 (AC-7, DC-3) -- the malformed-marker-line MESSAGE contract on the
# run-tests.pl surface, exercised through a real subprocess (see the header
# comment above for why this file resolves the AC-6/AC-7 tension this way).
# =============================================================================
{
    my $res = RunnerStateHarness::run_runner_bounded(
        args    => [$malformed_fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $STATE_DIR },
        timeout => $BOUND,
    );
    is($res->{rc}, 1, 'AC-7: run_runner_bounded rc is exactly 1 for the wrong-case-marker target');
    like($res->{out}, qr/malformed platform marker line/,
        'AC-7: the message contains the word "malformed"');
    like($res->{out}, qr/\Q"# Platform: host"\E/,
        'AC-7: the message quotes the literal offending line verbatim');
    unlike($res->{out}, qr/no platform marker found/,
        'AC-7: the message never says "no platform marker found" -- the precise failure this reason '
      . 'exists to prevent (TestPlatform.pm\'s own header comment)');
}

# =============================================================================
# PART 6 (AC-13, regression guard for Decision 16's write-set widening) --
# RunnerStateHarness.pm's three fixture-source generators must themselves
# carry a legal platform marker, or every consumer that writes one of their
# outputs to disk and hands it to run-tests.pl (six files, including
# container-lane.t, package 05's own oracle) regresses the moment enforcement
# goes live. Proven through TestPlatform::parse_marker -- never a second
# regex -- exactly like every other assertion in this file.
# =============================================================================
for my $case (
    [ 'green_source()',     RunnerStateHarness::green_source() ],
    [ 'red_source($label)', RunnerStateHarness::red_source('regression label') ],
    [ 'sleeper_source($s)', RunnerStateHarness::sleeper_source(1) ],
) {
    my ($label, $content) = @$case;
    my $marker = TestPlatform::parse_marker($content);
    is($marker->{outcome}, 'legal',
        "AC-13: RunnerStateHarness::$label output carries a legal platform marker -- regression guard "
      . 'for runner-state-*.t, jobs-precedence-chain.t and container-lane.t once enforcement is live');
}

# =============================================================================
# PART 7 (observable behaviors 7/8, spec sections 5.4/5.5) -- "unreadable" is
# NOT "unmarked". A file that cannot even be opened is a different condition
# and must never present as "you forgot a marker".
# =============================================================================
my $ghost = File::Spec->catfile($FIXDIR, 'does-not-exist-ghost.t');
ok(!-e $ghost, 'PART 7 setup: the ghost fixture path genuinely does not exist on disk');
{
    my @offenders = scan_offenders($ghost);
    is_deeply(\@offenders, [ _relpath($ghost) . ' (unreadable)' ],
        'PART 7: scan_offenders() reports "<path> (unreadable)" for a vanished/unopenable path -- '
      . 'a distinct token from "(absent)"');
}
{
    # run-tests.pl's own pre-existing "open ... or next" silently drops an
    # unreadable/vanished target -- deliberately UNCHANGED (spec section
    # 5.4). Proven alongside a real, legally-marked sibling in the same
    # invocation so the sweep is shown to continue rather than abort, and the
    # vanished file is shown to be genuinely invisible rather than
    # misreported as a marker refusal.
    my $sibling_body = "#!/usr/bin/env perl\n# platform: any\nprint \"ok 1 - part7 sibling pass\\n\"; exit 0;\n";
    my $sibling = write_fixture($FIXDIR, 'part7-legal-sibling.t', $sibling_body);
    my $res = RunnerStateHarness::run_runner_bounded(
        args    => [$sibling, $ghost],
        env     => { CCPRAXIS_TEST_STATE_DIR => $STATE_DIR },
        timeout => $BOUND,
    );
    is($res->{rc}, 0,
        'PART 7: a vanished target alongside a real legal file contributes zero to the exit code -- rc == 0 is '
      . 'possible only if the one real, collected file ran and passed');
    unlike($res->{out}, qr/PLATFORM MARKER REFUSED/,
        'PART 7: the vanished file is never misreported as a marker refusal');
    like($res->{out}, qr/\Qpart7-legal-sibling.t\E/,
        'PART 7: the real sibling file was actually collected and reported on (named in the "slowest" '
      . 'section run-tests.pl always prints), not silently dropped alongside the vanished target');
}

# =============================================================================
# PART 8 (observable behavior 10, spec section 5.2) -- --fast has no effect
# on marker refusal; it only empties the container-heuristic serial lane,
# which sits strictly after the marker gate.
# =============================================================================
{
    my $res = RunnerStateHarness::run_runner_bounded(
        args    => ['--fast', $absent_fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $STATE_DIR },
        timeout => $BOUND,
    );
    is($res->{rc}, 1, 'PART 8: --fast does not exempt a markerless target from refusal');
    my $base = File::Basename::basename($absent_fixture);
    like($res->{out}, qr/PLATFORM MARKER REFUSED:.*\Q$base\E/s,
        'PART 8: the refusal message still names the file under --fast');
}

# =============================================================================
# PART 9 (observable behavior 11) -- a sweep containing one refused file and
# several legal files: the legal files still run, and only the refused file
# contributes to the exit code -- marker enforcement does not abort the
# invocation (spec section 5.1).
# =============================================================================
{
    my $tree = RunnerStateHarness::make_fixture_tree(
        'mixed-green-a.t' => "#!/usr/bin/env perl\n# platform: any\nprint \"ok 1 - mixed fixture pass a\\n\"; exit 0;\n",
        'mixed-green-b.t' => "#!/usr/bin/env perl\n# platform: any\nprint \"ok 1 - mixed fixture pass b\\n\"; exit 0;\n",
        'mixed-absent.t'  => $ABSENT_BODY,
    );
    my $res = RunnerStateHarness::run_runner_bounded(
        args    => [$tree],
        env     => { CCPRAXIS_TEST_STATE_DIR => $STATE_DIR },
        timeout => $BOUND,
    );
    is($res->{rc}, 1, 'PART 9: exactly one red (the refused file) among three targets -- the two legal '
                     . 'files never turn red just because a sibling was refused');
    like($res->{out}, qr/PLATFORM MARKER REFUSED:.*mixed-absent\.t/s,
        'PART 9: the refused file is named in the report');
    like($res->{out}, qr/\Qmixed-green-a.t\E/,
        'PART 9: the first legal sibling was actually collected and reported on (named in the '
      . '"slowest" section run-tests.pl always prints for every result, red or green)');
    like($res->{out}, qr/\Qmixed-green-b.t\E/,
        'PART 9: the second legal sibling was actually collected and reported on');
}

# =============================================================================
# PART 10 (fix-batch 03-enforce-marker step 7, finding A1 -- ORACLE
# AUTHORIZATION granted for this batch only) -- a malformed marker line
# carrying a raw control character or an ANSI escape must never reach the
# refusal message unsanitized. Confirmed live by the red-team before this
# fix: an embedded \r repaints the terminal line the refusal is printed on,
# and a raw ESC byte carries a full ANSI escape sequence through -- a .t file
# that will never even run could still spoof or overwrite its own refusal
# line during a live sweep. _escape_marker_text() (scripts/run-tests.pl) must
# render such bytes as a readable "\xHH" escape, never silently strip them
# and never pass them through raw.
# =============================================================================
{
    my $cr_body = "#!/usr/bin/env perl\n# Platform: host\rALL CLEAR - NOTHING TO SEE HERE\nprint \"ok 1\\n\"; exit 0;\n";
    my $cr_fixture = write_fixture($FIXDIR, 'a1-control-char-cr.t', $cr_body);
    my $res = RunnerStateHarness::run_runner_bounded(
        args    => [$cr_fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $STATE_DIR },
        timeout => $BOUND,
    );
    is($res->{rc}, 1, 'A1 (CR injection): the malformed-marker fixture is still refused');
    like($res->{out}, qr/\\x0d/,
        'A1 (CR injection): the embedded \r is rendered as a readable "\x0d" escape, not silently stripped');
    unlike($res->{out}, qr/host\rALL CLEAR/,
        'A1 (CR injection): the raw \r never reaches the output between "host" and "ALL CLEAR" -- '
      . 'the exact sequence that would repaint a live terminal line');
    like($res->{out}, qr/\QALL CLEAR - NOTHING TO SEE HERE\E/,
        'A1 (CR injection): the rest of the offending line text is still visible verbatim (escaping, not '
      . 'stripping, so a human can see what is actually in their file)');
}
{
    my $esc_body = "#!/usr/bin/env perl\n# platform: \e[31mHACKED\e[0m\nprint \"ok 1\\n\"; exit 0;\n";
    my $esc_fixture = write_fixture($FIXDIR, 'a1-control-char-esc.t', $esc_body);
    my $res = RunnerStateHarness::run_runner_bounded(
        args    => [$esc_fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $STATE_DIR },
        timeout => $BOUND,
    );
    is($res->{rc}, 1, 'A1 (ESC injection): the unrecognized-value fixture is still refused');
    like($res->{out}, qr/\\x1b/,
        'A1 (ESC injection): the embedded ESC byte is rendered as a readable "\x1b" escape');
    unlike($res->{out}, qr/\e\[31mHACKED/,
        'A1 (ESC injection): the raw ANSI escape sequence never reaches the output verbatim');
}

# =============================================================================
# PART 11 (fix-batch 03-enforce-marker step 7, finding A2) -- an explicit CLI
# target whose own path contains a space must still be collected. Before the
# fix, glob()'s csh-style word-splitting silently dropped it: "no test files
# matched", exit 2, the file never even reaches the marker gate.
# =============================================================================
{
    my $space_dir = File::Spec->catdir($FIXDIR, 'has space');
    make_path($space_dir);
    my $space_fixture = write_fixture($space_dir, 'a2-space-target.t', $LEGAL_BODY);
    my $res = RunnerStateHarness::run_runner_bounded(
        args    => [$space_fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $STATE_DIR },
        timeout => $BOUND,
    );
    is($res->{rc}, 0,
        'A2: a legally-marked explicit target whose path contains a space is still collected and run '
      . '(rc == 0 is possible only if it ran and passed)');
    unlike($res->{out}, qr/no test files matched/,
        'A2: the space-containing target is never reported as unmatched');
    like($res->{out}, qr/\Qa2-space-target.t\E/,
        'A2: the space-containing target is named in the report (the "slowest" section)');
}

# =============================================================================
# PART 12 (fix-batch 03-enforce-marker step 7, finding A3) -- an out-of-tree
# target given in Windows drive-letter style (C:/Users/...) must render a
# followable path in the refusal message, never the reproduced garbled form
# "../../../../C:/Users/...". _relpath() falls back to the absolute path
# whenever the computed relative form still embeds a drive letter.
# =============================================================================
{
    my $a3_fixture_ms  = write_fixture($FIXDIR, 'a3-drive-letter.t', $ABSENT_BODY);
    my $a3_fixture_abs = abs_path($a3_fixture_ms);
    (my $a3_fixture_win = $a3_fixture_abs) =~ s{^/([A-Za-z])/}{\U$1\E:/};

    SKIP: {
        skip 'A3: fixture path is not MSYS-style (/c/...) on this host, cannot construct a '
           . 'drive-letter form to probe', 3
            unless $a3_fixture_win =~ m{^[A-Za-z]:/} && $a3_fixture_win ne $a3_fixture_abs;

        my $res = RunnerStateHarness::run_runner_bounded(
            args    => [$a3_fixture_win],
            env     => { CCPRAXIS_TEST_STATE_DIR => $STATE_DIR },
            timeout => $BOUND,
        );
        is($res->{rc}, 1, 'A3: the drive-letter-style target is still refused (markerless)');
        unlike($res->{out}, qr/REFUSED:\s*\.\./,
            'A3: the refusal message never renders a "../"-prefixed garbled path for an out-of-tree '
          . 'drive-letter target');
        like($res->{out}, qr/\Q$a3_fixture_win\E/,
            'A3: the refusal message contains the clean absolute drive-letter path verbatim instead');
    }
}

# =============================================================================
# PART 13 (KNOWN GAP -- documented, NOT fixed here; filed separately per
# fix-batch 03-enforce-marker step 7, section B) -- a marker-shaped line
# inside a heredoc body is indistinguishable, to TestPlatform::parse_marker,
# from a genuine top-of-file declaration. Root cause is package 01's
# TestPlatform.pm (out of this package's write set; this batch's
# authorization covers ADDING assertions here, never touching that module).
# This assertion documents today's actual (undesired) behavior so the gap is
# visible and tracked, not silently rediscovered later -- it is NOT a
# statement that this behavior is correct. If/when package 01 confines the
# scan to a genuine leading-comment run, THIS assertion's expected outcome
# will need to change from 'legal' to 'absent', and that is the fix landing,
# not a regression.
# =============================================================================
{
    my $smuggled = "#!/usr/bin/env perl\nuse strict; use warnings;\n"
                 . "my \$fixture_body = <<'EOF';\n# platform: any\nnot really asserted\nEOF\n"
                 . "print \"ok 1\\n\"; exit 0;\n";
    my $marker = TestPlatform::parse_marker($smuggled);
    is($marker->{outcome}, 'absent',
        'PART 13 (GAP NOW CLOSED, 20260916-221455-96a7): a "# platform: any" line inside a '
      . 'heredoc body is NO LONGER accepted as a genuine top-of-file declaration -- the file never '
      . 'declared a platform, so it is `absent` and refuses loudly, which is what Decision 4 asks '
      . 'for. This assertion previously expected `legal` and the comment above predicted exactly '
      . 'this change; the fix is a POSITIONAL rule in package 01\'s TestPlatform.pm -- a '
      . 'declaration must appear before any heredoc, POD or __DATA__. Measured across all 352 .t '
      . 'files before shipping: 0 changed outcome. Original note follows, kept because it is the '
      . 'record of the gap being tracked rather than rediscovered: root cause is package 01\'s '
      . 'TestPlatform.pm, out of that package\'s write '
      . 'set -- this assertion documented the gap, it did not endorse it.');

    # THE OTHER DIRECTION, which nobody anticipated and which bites in ordinary
    # use rather than under attack. A file that CORRECTLY declares its platform
    # and then writes a marker-bearing fixture through a heredoc -- the natural
    # idiom here, since every .t needs a marker so fixtures need one too -- used
    # to parse `invalid/conflicting-markers`: refused, reported red, with the
    # diagnostic pointing at a line its author never meant as a declaration.
    my $correct = "#!/usr/bin/env perl\n# platform: host\n"
                . "my \$fixture = <<'EOF';\n# platform: any\nEOF\n"
                . "print \"ok 1\\n\"; exit 0;\n";
    my $cm = TestPlatform::parse_marker($correct);
    is($cm->{outcome}, 'legal',
        'PART 13b: a CORRECTLY declared file that writes a marker-bearing fixture through a '
      . 'heredoc is legal, not a conflict -- the false-refusal half of 96a7, and the half that '
      . 'fires in ordinary work rather than under a contrived file');
    is($cm->{value}, 'host',
        'PART 13b: ...and it keeps the platform the AUTHOR declared, not the one in the fixture');

    # NON-VACUITY: the positional rule must not simply ignore every marker. A
    # file whose declaration sits before any heredoc still parses normally.
    my $plain = "#!/usr/bin/env perl\n# platform: any\nprint \"ok 1\\n\"; exit 0;\n";
    is(TestPlatform::parse_marker($plain)->{value}, 'any',
        'PART 13c: NON-VACUITY -- an ordinary declaration with no heredoc anywhere still parses, '
      . 'so 13a and 13b are not passing because the parser stopped seeing markers at all');
}

# PART 14 -- the retired value "windows" is refused with the exact rename hint.
{
    my $f = write_fixture($FIXDIR, 'rename-windows-to-host.t',
        "#!/usr/bin/env perl\n# platform: windows\nprint \"ok 1 - fixture pass\\n\"; exit 0;\n");
    my $res = RunnerStateHarness::run_runner_bounded(
        args    => [$f],
        env     => { CCPRAXIS_TEST_STATE_DIR => $STATE_DIR },
        timeout => $BOUND,
    );
    is($res->{rc}, 1, 'PART 14: a file still carrying "# platform: windows" is refused (rc 1)');
    like($res->{out}, qr/unrecognized platform value "windows"/,
        'PART 14: the refusal names the retired value');
    like($res->{out}, qr/\Q"windows" was renamed to "host"; change the line to "# platform: host".\E/,
        'PART 14: the refusal says exactly what to change');
    my @offenders = scan_offenders($f);
    is_deeply(\@offenders, [ _relpath($f) . ' (invalid:unrecognized-value)' ],
        'PART 14: the hygiene scan reports it as invalid:unrecognized-value (no alias)');
}

done_testing();
