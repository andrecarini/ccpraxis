#!/usr/bin/env perl
# platform: windows
# Oracle for blueprint package 04-scratch-root (blueprint test-platform-split).
# Derived ONLY from
# .ccpraxis-local-data/blueprints/test-platform-split/specs/04-scratch-root-spec.md
# (260 lines). NOT derived from any implementation: at the time this file is
# written, HostCaps.pm has no scratch_root() sub, and StewardTest.pm /
# TestSandbox.pm have no `require HostCaps` at all -- every assertion below
# that depends on scratch_root() existing is EXPECTED TO FAIL on "Undefined
# subroutine", never on a bug in this file's own scaffolding.
#
# AC -> block mapping (ledger's 8 done criteria; AC7/AC8 are [R], AC4/AC6 are
# [S] -- see "OUT OF SCOPE" below):
#   AC1 (criterion 1, one owner/derivation)   -> "ONE DEFINER", "BAREWORD
#         REQUIRE", "AC1 DERIVATION" blocks
#   AC2 (criterion 2, three-constraints-at-once) -> "AC2/AC3: NATIVE PATH",
#         "AC2/AC3: ASCII", "AC2/AC3: NO 8.3 (subdirs)",
#         "AC2/AC3: NO 8.3 (root, functional substitute)",
#         "AC2/AC3: CONTAINER REACHABILITY"
#   AC3 (criterion 3, each constraint names its incident) -> every test name
#         in the five AC2 blocks above carries its incident/decision citation
#   AC5 (criterion 5, override validated not trusted)  -> "AC5: OVERRIDE
#         CASE TABLE" block (rows 1,3,4,5,6,7 -- see INTERPRETATION NOTE 1)
#   native_tmp()/git_path() regression (spec 2.4's landmine, task's own
#         "assertions that matter most" #6) -> "NATIVE_TMP MUST NOT MOVE"
#
# OUT OF SCOPE FOR THIS FILE, ON PURPOSE:
#   AC4 [S] (steward git suite stays green) and AC6 [S] (full sweep has no
#   new red) are sweep-level criteria per the spec's own table -- "no single
#   .t assertion can stand in for it". They are verified by actually running
#   plugins/steward/tests/t/*.t and scripts/run-tests.pl as part of package
#   validation, not by anything in this file.
#   AC7 [R] (the package emits the exact Add-MpPreference command) and AC8
#   [R] (the ledger's Escalation section + read-only verifier) are
#   documentation deliverables per the spec's own flag -- verified by report
#   / ledger inspection. Inventing a .t assertion that greps the ledger for
#   prose would be a test that fails for the wrong reasons; none is here.
#   This file also NEVER runs Add-MpPreference / Set-MpPreference /
#   Get-MpPreference, and never mkdir's anything directly at a drive root --
#   the only thing that may create plugins/butler/tests/lib/HostCaps.pm's
#   C:/ccpraxis-scratch is HostCaps::scratch_root() itself, called as the
#   function under test, never this file acting directly on the filesystem.
#
# INTERPRETATION NOTES (recorded, not silently resolved -- a guess here
# becomes an immutable contract per the test-writer's own brief):
#
#   1. "ALL SIX ROWS" vs. the 2.3 table's SEVEN rows. Section 2.3 says "All
#      six rows are exercised... rows 1 and 3 are additionally exercised
#      through [derivers]", but the table has seven rows (1=unset/Windows,
#      2=unset/non-Windows, 3..7=override cases). Read literally against
#      AC5's own text -- "rows 1 and 3 ... rows 4/6/5" (five rows named) --
#      "six" resolves to {1,3,4,5,6,7}, i.e. every row EXCEPT row 2, which is
#      the one row that only applies off Windows and cannot be exercised
#      directly on this Windows host. This file exercises all six of
#      {1,3,4,5,6,7} for real, plus row 2 as a clearly-labelled BEST-EFFORT
#      bonus (achieved by faking $^O in a child process -- legitimate
#      because HostCaps checks $^O dynamically inside each sub, exactly as
#      native_tmp()/git_path() already do; this is exercising the pseudocode
#      CONTRACT in 2.2, not guessing at an implementation detail).
#
#   2. MEMOIZATION FORCES SUBPROCESSES FOR THE OVERRIDE TABLE. 2.2's own
#      pseudocode caches scratch_root()'s result in %cache after the FIRST
#      call in a process. Calling HostCaps::scratch_root() repeatedly in
#      THIS file's own process with different $ENV{CCPRAXIS_SCRATCH_ROOT}
#      values between calls would silently keep returning the FIRST result
#      forever -- a fixture fault indistinguishable from a real defect. The
#      spec does not spell this out, but StewardTest.pm's own header names
#      exactly this class of problem for vault-sync.pl's HOME handling ("must
#      be set in the CHILD env BEFORE the script is spawned... which is why
#      every scenario step shells out instead of calling subs in-process").
#      This file follows the same discipline: every override-table row runs
#      in a fresh child perl process. The DEFAULT (unset) scenario is the
#      first and only scratch_root() call this file's own process ever makes
#      directly, so its cache is never polluted by a later override test.
#
#   3. THE ROOT'S OWN "NO 8.3 ALIAS" CHECK IS SUBSTITUTED, WITH EVIDENCE.
#      AC2(c) asks for a functional check "via cmd.exe's %~sI... not by
#      string inspection". Two empirical findings from this host, both
#      reproduced while writing this file, changed how that is operationalised:
#        (a) Direct cmd.exe invocation (via backticks, system(), or list-form
#            system(), from this test-execution environment) HANGS rather
#            than running %~sI and returning -- confirmed by a genuine 120s
#            timeout on `cmd.exe /c "echo x"` with no shell wrapper involved.
#            cygpath (already on PATH, part of the same Git-for-Windows/MSYS
#            toolchain, calling the identical underlying
#            GetShortPathName/GetLongPathName Win32 APIs) does the same job
#            without hanging, so `cygpath -d` / `cygpath -w -l` are used
#            below as a mechanism-equivalent, non-hanging substitute for
#            %~sI -- not a weaker check, a working one.
#        (b) MORE IMPORTANTLY: `C:/ccpraxis-scratch` -- the fixed root chosen
#            by Decision 7, not something this file or the implementer can
#            change -- is 16 characters long. This volume has 8dot3name
#            generation ENABLED (confirmed directly: `mkdir C:/ccpraxis-scratch`
#            then `cygpath -d` on it returns `C:\CCPRAX~1`, distinct from the
#            long form, and a plain 9-character ASCII test directory with no
#            special characters at all reproduces the same aliasing while an
#            8-character one does not -- this is a pure LENGTH threshold, not
#            an ASCII or embedded-character issue). That means a literal
#            "the root's own directory entry has no distinct short alias"
#            check is UNSATISFIABLE for this specific, spec-fixed root name,
#            regardless of how well HostCaps.pm is implemented -- asserting
#            it literally would make this oracle permanently red even after
#            a perfect implementation, which is exactly the "wrong reason"
#            failure mode the test-writer brief forbids introducing. The
#            spec's own text elsewhere sanctions exactly this substitution
#            for this exact constraint: "the functional form of the 8.3
#            constraint, not a string check" (observable behavior 11) is used
#            here in place of a literal alias-equality check ON THE ROOT
#            SEGMENT ONLY. The three PLUGIN SUBDIRECTORIES (butler=6,
#            steward=7, sandbox=7 characters, all <=8) are NOT subject to this
#            problem -- confirmed empirically the same way -- so they get the
#            literal short-name-equality check AC2(c) actually asks for,
#            compared by BASENAME (the path segment under test), since a
#            full-path comparison would spuriously "fail" on the root
#            segment's own unavoidable alias even when the subdirectory name
#            itself is perfectly alias-free.
#
# NON-VACUITY STRATEGY (this blueprint's own standing rule):
#   - Every detector-style assertion (native-path regex, ASCII regex, the
#     8.3 basename comparator, the %INC single-key count, the "one definer"
#     source-text regex, the die-message regexes) is followed by a
#     COUNTER-FIXTURE proving the same predicate fires on data engineered to
#     trip it.
#   - Where something is asserted ABSENT (no independent scratch_root() in
#     StewardTest.pm/TestSandbox.pm; no string-path require of HostCaps.pm),
#     the counter-fixture supplies the POSITIVE case on fabricated text, so
#     the absence check cannot be trivially true because nothing was ever
#     checked for real.

use strict;
use warnings;
use Test::More;

# The whole file is the oracle for scratch_root()'s WINDOWS-host derivation
# (native path, ASCII, no 8.3, the drive-root strays). Off Windows the
# contract is "returns undef" (Row 2), which this file already checks on
# Windows by faking $^O, so a non-Windows host has nothing to run here.
plan skip_all => 'Windows-only oracle: scratch_root() derives the Windows host scratch root; '
    . 'elsewhere it returns undef by contract (Row 2, exercised on Windows with $^O faked)'
    unless $^O =~ /^(MSWin32|cygwin|msys)$/;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Basename qw(dirname basename);
use Cwd qw(abs_path);

# Never let a spawned TestSandbox (main process or any child) burn time
# sweeping other runs' orphan containers -- unrelated to what this file tests.
BEGIN { $ENV{CCPRAXIS_TEST_NO_SWEEP} = 1; }

# ── lib wiring, exactly per spec 2.5 ────────────────────────────────────────
use lib "$Bin/../lib";                              # HostCaps
use lib "$Bin/../../../steward/tests/lib";          # StewardTest
use lib "$Bin/../../../sandbox/tests/lib";          # TestSandbox
use lib "$Bin/../../../sandbox/scripts";            # MountSpec (load-order
                                                     # landmine per spec 2.5 --
                                                     # this MUST be added
                                                     # before `require
                                                     # TestSandbox` runs, or
                                                     # TestSandbox.pm's own
                                                     # FindBin-derived (and,
                                                     # from here, WRONG)
                                                     # `use lib` line leaves
                                                     # MountSpec unfindable)

my $HOSTCAPS_PM     = "$Bin/../lib/HostCaps.pm";
my $STEWARDTEST_PM  = "$Bin/../../../steward/tests/lib/StewardTest.pm";
my $TESTSANDBOX_PM  = "$Bin/../../../sandbox/tests/lib/TestSandbox.pm";

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub fwd { my $p = shift; return undef unless defined $p; $p =~ s{\\}{/}g; return $p; }

# The exact, unchanged POSIX-form conversion StewardTest.pm's temproot()
# already applies to every candidate (spec 2.4: "the existing POSIX-form
# conversion... [is] unchanged and appl[ies] to the new first candidate
# exactly as they applied to the old one"). Replicated here only to build the
# EXPECTED prefix from the ground-truth HostCaps::scratch_root() value, never
# to guess at StewardTest.pm's internals.
sub to_posix_form {
    my ($p) = @_;
    return undef unless defined $p;
    (my $q = $p) =~ s{\\}{/}g;
    $q =~ s{^([a-zA-Z]):/}{'/' . lc($1) . '/'}e;
    return $q;
}

# ============================================================================
# Load HostCaps.pm -- the ground truth. Everything downstream depends on
# this succeeding; it is expected to succeed today (the file already exists
# and compiles), only `scratch_root()` itself is missing.
# ============================================================================
ok(-f $HOSTCAPS_PM, 'HostCaps.pm exists at plugins/butler/tests/lib/HostCaps.pm');

my $HOSTCAPS_LOAD_ERR;
eval { require HostCaps; 1 } or do { $HOSTCAPS_LOAD_ERR = $@; };
ok(!defined $HOSTCAPS_LOAD_ERR, 'HostCaps.pm loads with no compile/runtime error')
    or diag("load error: $HOSTCAPS_LOAD_ERR");

# ============================================================================
# ONE DEFINER (AC1 / done criterion 1) -- source-text checks over all three
# write-set .pm files. "scratch_root" must be defined in HostCaps.pm and
# NOWHERE else.
# ============================================================================
{
    my $hc_src = slurp($HOSTCAPS_PM);
    my $st_src = slurp($STEWARDTEST_PM);
    my $ts_src = slurp($TESTSANDBOX_PM);

    my $DEFINER_RE = qr/^\s*sub\s+scratch_root\b/m;

    like($hc_src, $DEFINER_RE,
        'AC1 (one owner, criterion 1): HostCaps.pm defines sub scratch_root');
    unlike($st_src, $DEFINER_RE,
        'AC1 (one owner, criterion 1): StewardTest.pm does NOT independently define scratch_root');
    unlike($ts_src, $DEFINER_RE,
        'AC1 (one owner, criterion 1): TestSandbox.pm does NOT independently define scratch_root');

    # Counter-fixture: prove $DEFINER_RE actually fires on a definition,
    # rather than being a pattern that can never match anything.
    my $fake_src = "package Something;\nuse strict;\nsub scratch_root {\n    return 1;\n}\n1;\n";
    like($fake_src, $DEFINER_RE,
        'counter-fixture: the one-definer regex fires on a fabricated independent definition');

    # HostCaps.pm's @EXPORT_OK must list scratch_root (spec 2.2's interface
    # contract), so HostCaps's own in-plugin callers can `use HostCaps
    # qw(scratch_root)` normally.
    my ($export_list) = $hc_src =~ /\@EXPORT_OK\s*=\s*qw\(([^)]*)\)/s;
    my @exported = defined($export_list) ? split(/\s+/, $export_list) : ();
    ok((grep { $_ eq 'scratch_root' } @exported) ? 1 : 0,
        'AC1: HostCaps.pm @EXPORT_OK lists scratch_root')
        or diag('@EXPORT_OK contents: ' . (defined($export_list) ? $export_list : '(not found)'));

    # Bareword require, never a string-path require (spec 2.1's "why the
    # adaptation" -- a string-path require from either deriver would give a
    # SECOND %INC key for the same file and load it twice).
    my $BAREWORD_RE     = qr/^\s*require\s+HostCaps\s*;/m;
    my $STRINGPATH_RE   = qr/require\s+["'][^"']*HostCaps\.pm["']/;

    like($st_src, $BAREWORD_RE,
        'AC1 (bareword require, criterion 1): StewardTest.pm contains a bareword `require HostCaps;`');
    like($ts_src, $BAREWORD_RE,
        'AC1 (bareword require, criterion 1): TestSandbox.pm contains a bareword `require HostCaps;`');
    unlike($st_src, $STRINGPATH_RE,
        'AC1: StewardTest.pm does not require HostCaps.pm by string path (would fragment %INC)');
    unlike($ts_src, $STRINGPATH_RE,
        'AC1: TestSandbox.pm does not require HostCaps.pm by string path (would fragment %INC)');

    # Counter-fixtures for both regexes, proving they are not tautologies.
    like('require HostCaps;', $BAREWORD_RE,
        'counter-fixture: the bareword-require regex fires on a real bareword require');
    like(q{require "$DIR/HostCaps.pm";}, $STRINGPATH_RE,
        'counter-fixture: the string-path-require regex fires on a fabricated string-path require');
    unlike('require HostCaps;', $STRINGPATH_RE,
        'counter-fixture: the string-path-require regex does NOT fire on a genuine bareword require (no false positive)');
}

# ============================================================================
# BAREWORD REQUIRE / SINGLE-LOAD (AC1 / observable behavior 13) -- require
# HostCaps via all three paths in one process (directly here, transitively
# via StewardTest, transitively via TestSandbox) and confirm %INC has exactly
# one key for it, with no "Subroutine ... redefined" warning.
# ============================================================================
my (@warnings_seen, $STEWARDTEST_LOAD_ERR, $TESTSANDBOX_OK, $TESTSANDBOX_LOAD_ERR);
{
    local $SIG{__WARN__} = sub { push @warnings_seen, $_[0]; };
    eval { require HostCaps; 1 };   # already loaded above; re-require is a no-op if bareword-consistent
    eval { require StewardTest; 1 } or $STEWARDTEST_LOAD_ERR = $@;
    $TESTSANDBOX_OK = eval {
        require TestSandbox;
        # Deliberately no ->import(...) call: every use of TestSandbox in this
        # file is fully qualified (TestSandbox::new_temp_dir() etc., see below),
        # and TestSandbox's own import() (Decision 120(a), package 36) calls
        # Test::More's plan(skip_all=>...) + exits the whole process when the
        # CLI is present but the runtime is unreachable AND a runtime-talking
        # symbol was requested. That is safe for a file that imports at its very
        # top, before any assertion has run; it is NOT safe here, where this
        # `require` happens well after nine assertions above already printed
        # "ok" lines, and where this file wants its OWN localized skip()s around
        # exactly the container-dependent checks (see the SKIP: block below)
        # rather than a whole-file skip. Not calling ->import() avoids invoking
        # that logic at all, while `require`'s own pre-existing die-with-no-CLI
        # behavior (used to set $TESTSANDBOX_OK below) is unchanged.
        1;
    };
    $TESTSANDBOX_LOAD_ERR = $@ unless $TESTSANDBOX_OK;
}

ok(!defined $STEWARDTEST_LOAD_ERR, 'StewardTest.pm loads (its own `require HostCaps` succeeds transitively)')
    or diag("load error: $STEWARDTEST_LOAD_ERR");

if (!$TESTSANDBOX_OK) {
    diag("TestSandbox did not load: " . (defined($TESTSANDBOX_LOAD_ERR) ? $TESTSANDBOX_LOAD_ERR : '(unknown)'));
}
ok($TESTSANDBOX_OK ? 1 : 0,
    'TestSandbox.pm loads (its own `require HostCaps` succeeds transitively; container CLI is on PATH on this host)');

{
    my @hostcaps_inc_keys = grep { /HostCaps\.pm$/ } keys %INC;
    is(scalar(@hostcaps_inc_keys), 1,
        'AC1 (observable behavior 13): %INC has exactly ONE key for HostCaps.pm after loading it via '
      . 'all three paths (a string-path require anywhere would fragment this into two keys)')
        or diag('keys found: ' . join(', ', @hostcaps_inc_keys));

    my @redefine_warnings = grep { /Subroutine\s+HostCaps::\w+\s+redefined/ } @warnings_seen;
    is(scalar(@redefine_warnings), 0,
        'AC1: no "Subroutine HostCaps::* redefined" warning fired while loading HostCaps via all three paths')
        or diag('warnings: ' . join(' | ', @redefine_warnings));

    # Counter-fixtures: prove both detectors actually fire on fabricated bad data.
    my %fake_inc = ('HostCaps.pm' => '/a/HostCaps.pm', 'C:/other/full/path/HostCaps.pm' => '/a/HostCaps.pm');
    my @fake_keys = grep { /HostCaps\.pm$/ } keys %fake_inc;
    ok(scalar(@fake_keys) > 1,
        'counter-fixture: the %INC-single-key detector fires on two distinct keys for the same file (fragmentation)');

    my $fake_warn = "Subroutine HostCaps::native_tmp redefined at plugins/steward/tests/lib/StewardTest.pm line 30.\n";
    like($fake_warn, qr/Subroutine\s+HostCaps::\w+\s+redefined/,
        'counter-fixture: the redefinition-warning detector fires on a fabricated redefinition warning');
}

# ============================================================================
# DEFAULT SCENARIO -- the ONLY in-process call to HostCaps::scratch_root()
# this file ever makes (see INTERPRETATION NOTE 2). Feeds AC1 derivation,
# AC2/AC3's native-path/ASCII/8.3 checks, the native_tmp regression guard,
# and the functional root-level 8.3 substitute.
# ============================================================================
my $SCRATCH_ROOT_ERR;
my $ROOT = eval { HostCaps::scratch_root() };
$SCRATCH_ROOT_ERR = $@ if $@;
ok(!defined($SCRATCH_ROOT_ERR) || !length($SCRATCH_ROOT_ERR),
    'HostCaps::scratch_root() (default, CCPRAXIS_SCRATCH_ROOT unset) does not die')
    or diag("died: $SCRATCH_ROOT_ERR");
ok(defined $ROOT, 'HostCaps::scratch_root() (default) returns a defined value on this Windows host')
    or diag('scratch_root() returned undef -- every check below in this scenario will report the same root cause');

# ----------------------------------------------------------------------------
# AC2/AC3: NATIVE PATH (criterion 2's first constraint; criterion 3's citation)
# ----------------------------------------------------------------------------
{
    my $NATIVE_RE = qr{^[A-Za-z]:/};
    if (defined $ROOT) {
        like($ROOT, $NATIVE_RE,
            'AC2/AC3 (576 drive-root strays, 2026-06-12): default scratch_root() is a native C:/... path, '
          . 'never a bare POSIX path that native git.exe could resolve against the current drive');
    } else {
        fail('AC2/AC3 (576 drive-root strays, 2026-06-12): cannot check -- scratch_root() returned undef (see above)');
    }
    unlike('/c/ccpraxis-scratch', $NATIVE_RE,
        'counter-fixture: the native-path regex correctly rejects a POSIX-style /c/... spelling of the same directory');
    like('C:/ccpraxis-scratch', $NATIVE_RE,
        'counter-fixture: the native-path regex correctly accepts the intended C:/... spelling');
}

# ----------------------------------------------------------------------------
# AC2/AC3: ASCII (criterion 2's second constraint)
# ----------------------------------------------------------------------------
{
    my $NONASCII_RE = qr/[^\x00-\x7f]/;
    if (defined $ROOT) {
        unlike($ROOT, $NONASCII_RE,
            'AC2/AC3 (ASCII): default scratch_root() contains no byte outside the ASCII range');
    } else {
        fail('AC2/AC3 (ASCII): cannot check -- scratch_root() returned undef (see above)');
    }
    like("C:/Users/Andr\x{e9}/x", $NONASCII_RE,
        'counter-fixture: the ASCII-purity regex correctly flags a non-ASCII path (the %TEMP%-adjacent shape)');
    unlike('C:/ccpraxis-scratch/butler', $NONASCII_RE,
        'counter-fixture: the ASCII-purity regex does not false-positive on a pure-ASCII path');
}

# ----------------------------------------------------------------------------
# 8.3 short-name helper: functional (Win32 GetShortPathName / GetLongPathName
# via cygpath), compared by BASENAME so an unavoidably-aliased ANCESTOR
# segment (see INTERPRETATION NOTE 3b) cannot make a genuinely alias-free
# child segment look aliased. Requires the path to exist on disk, which is
# exactly right: "does not exist" IS "not implemented yet" here.
# ----------------------------------------------------------------------------
sub short_name_alias_free {
    my ($path) = @_;
    return (undef, 'undef or empty path') unless defined $path && length $path;
    my $short = `cygpath -d '$path' 2>&1`;
    my $short_rc = $? >> 8;
    chomp $short;
    return (undef, "cygpath -d failed (rc=$short_rc): $short") if $short_rc != 0;
    my $long = `cygpath -w -l '$path' 2>&1`;
    my $long_rc = $? >> 8;
    chomp $long;
    return (undef, "cygpath -w -l failed (rc=$long_rc): $long") if $long_rc != 0;
    my ($short_base) = $short =~ m{([^\\/]+)$};
    my ($long_base)  = $long  =~ m{([^\\/]+)$};
    return (undef, "could not parse basenames (short='$short', long='$long')")
        unless defined $short_base && defined $long_base;
    return ((lc($short_base) eq lc($long_base)) ? 1 : 0, "short-base='$short_base' long-base='$long_base'");
}

# Counter-fixture for the helper itself, run unconditionally (does not depend
# on scratch_root() at all): $ENV{USERPROFILE} is known, on THIS host, right
# now, to carry an 8.3 alias on its own last path segment (the non-ASCII
# username) -- StewardTest.pm's own cited incident, restated functionally
# instead of as a string literal.
{
    my ($free, $detail) = short_name_alias_free($ENV{USERPROFILE});
    if (defined $free) {
        is($free, 0,
            'counter-fixture (ANDR~1 / StewardTest.pm:85): the 8.3-alias-free detector correctly reports '
          . "\$ENV{USERPROFILE} ($ENV{USERPROFILE}) as ALIASED ($detail)");
    } else {
        fail("counter-fixture setup failed for \$ENV{USERPROFILE}: $detail");
    }

    # Positive twin: a short (<=8 char), pure-ASCII directory name must NOT be
    # reported as aliased -- proves the detector distinguishes, rather than
    # reporting every path as aliased unconditionally.
    my $short_ascii_dir = tempdir(TEMPLATE => 'shrtok-XXXXXX', CLEANUP => 1);
    # tempdir()'s random suffix pushes the leaf name past 8 characters by
    # design (collision avoidance) -- that is fine, it is not the property
    # under test here. Use a same-length ANCESTOR check instead: an 8-char
    # leaf carved out fresh under it.
    my $eight_char_leaf = "$short_ascii_dir/eightch1";
    mkdir $eight_char_leaf or die "fixture: mkdir $eight_char_leaf: $!";
    my ($free2, $detail2) = short_name_alias_free($eight_char_leaf);
    if (defined $free2) {
        is($free2, 1,
            "positive case: an 8-character pure-ASCII leaf ($eight_char_leaf) is correctly reported as "
          . "alias-free ($detail2), proving the detector above is not simply always-aliased");
    } else {
        fail("positive-case setup failed for $eight_char_leaf: $detail2");
    }
}

# ============================================================================
# AC1 DERIVATION (criterion 1: "derive from it", not "happen to agree") +
# AC2/AC3: NO 8.3 on the three plugin subdirectories, in-process, under the
# default scenario.
# ============================================================================
my ($STEWARD_ROOT, $TA_DIR);
{
    my %ta = eval { HostCaps::tempdir_args() };
    $TA_DIR = $ta{DIR};
    if (defined $ROOT) {
        is($TA_DIR, "$ROOT/butler",
            'observable behavior 2: HostCaps::tempdir_args() returns DIR => "<scratch_root()>/butler"');
    } else {
        fail('cannot check tempdir_args() DIR -- scratch_root() returned undef');
    }

    # Splice into a real tempdir() call (observable behavior 2's second half):
    # it must actually create a real, writable directory there.
    if (defined $TA_DIR) {
        my $probe = eval { tempdir(HostCaps::tempdir_args(), CLEANUP => 1) };
        if (defined $probe) {
            ok(-d $probe, 'a tempdir() call spliced with HostCaps::tempdir_args() creates a real directory');
            my $f = "$probe/write-probe.txt";
            my $wrote = eval { open(my $fh, '>', $f) or die $!; print {$fh} 'x'; close $fh; 1 };
            ok($wrote, 'the directory created via tempdir_args() is genuinely writable') or diag($@);
        } else {
            fail("tempdir(HostCaps::tempdir_args(), CLEANUP=>1) died: $@");
        }
    } else {
        fail('cannot splice tempdir_args() into tempdir() -- DIR was undef');
    }
}

$STEWARD_ROOT = eval { StewardTest::temproot() };
my $STEWARD_ROOT_ERR = $@;
ok(!$STEWARD_ROOT_ERR, 'StewardTest::temproot() (default scenario) does not die') or diag("died: $STEWARD_ROOT_ERR");

if (defined $ROOT && defined $STEWARD_ROOT) {
    my $root_posix = to_posix_form($ROOT);
    like($STEWARD_ROOT, qr{^\Q$root_posix\E/steward/},
        'AC1 (derivation, not agreement, criterion 1): StewardTest::temproot() output is a genuine '
      . 'DESCENDANT of HostCaps::scratch_root() (POSIX form), proven by prefix match against the '
      . 'ground-truth value this file obtained from its own direct require of HostCaps.pm');

    # Counter-fixtures proving "descendant" is not confused with "equal" or
    # "unrelated sibling".
    unlike($root_posix, qr{^\Q$root_posix\E/steward/},
        'counter-fixture: the root itself (no /steward/ suffix) does NOT match the descendant pattern '
      . '-- equality is not mistaken for descendance');
    unlike('/c/Users/Public/unrelated-XXXXXX', qr{^\Q$root_posix\E/steward/},
        'counter-fixture: the OLD hardcoded /c/Users/Public candidate does not match the descendant pattern');
} else {
    fail('AC1: cannot check StewardTest::temproot() derivation -- a prerequisite value was undef');
}

# 8.3 check on the steward subdirectory (its PARENT, since temproot() itself
# returns a randomized per-invocation leaf beneath the fixed subdirectory).
if (defined $STEWARD_ROOT) {
    my $steward_subdir = dirname($STEWARD_ROOT);
    my ($free, $detail) = short_name_alias_free($steward_subdir);
    if (defined $free) {
        is($free, 1,
            "AC2/AC3 (8.3 / StewardTest.pm:85): the steward plugin subdirectory ($steward_subdir, "
          . "basename 'steward', 7 chars) carries no 8.3 alias of its OWN ($detail)");
    } else {
        fail("AC2/AC3 (8.3 / StewardTest.pm:85): could not check $steward_subdir: $detail");
    }
} else {
    fail('AC2/AC3 (8.3 / StewardTest.pm:85): cannot check the steward subdirectory -- temproot() died');
}

SKIP: {
    if (!$TESTSANDBOX_OK) {
        skip('no container CLI on PATH -- TestSandbox.pm did not load, so its derivation cannot be checked here', 6);
    }
    my $sandbox_dir = eval { TestSandbox::new_temp_dir() };
    my $sandbox_err = $@;
    ok(!$sandbox_err, 'TestSandbox::new_temp_dir() (default scenario) does not die') or diag("died: $sandbox_err");

    if (defined $ROOT && defined $sandbox_dir) {
        like($sandbox_dir, qr{^\Q$ROOT\E/sandbox/},
            'AC1 (derivation, not agreement, criterion 1): TestSandbox::new_temp_dir() output is a genuine '
          . 'DESCENDANT of HostCaps::scratch_root() (Windows form)');
        unlike($ROOT, qr{^\Q$ROOT\E/sandbox/},
            'counter-fixture: the root itself (no /sandbox/ suffix) does NOT match the descendant pattern');
        my $old_default = fwd($ENV{USERPROFILE}) . '/.cache/sandbox-tests/unrelated-XXXXXX';
        unlike($old_default, qr{^\Q$ROOT\E/sandbox/},
            'counter-fixture: the OLD $HOME/.cache/sandbox-tests default does not match the descendant pattern');
    } else {
        fail('AC1: cannot check TestSandbox::new_temp_dir() derivation -- a prerequisite value was undef');
        fail('(counter-fixture 1 skipped: prerequisite undef)');
        fail('(counter-fixture 2 skipped: prerequisite undef)');
    }

    if (defined $sandbox_dir) {
        my $sandbox_subdir = dirname($sandbox_dir);
        my ($free, $detail) = short_name_alias_free($sandbox_subdir);
        if (defined $free) {
            is($free, 1,
                "AC2/AC3 (8.3): the sandbox plugin subdirectory ($sandbox_subdir, basename 'sandbox', "
              . "7 chars) carries no 8.3 alias of its OWN ($detail)");
        } else {
            fail("AC2/AC3 (8.3): could not check $sandbox_subdir: $detail");
        }
    } else {
        fail('AC2/AC3 (8.3): cannot check the sandbox subdirectory -- new_temp_dir() died');
    }

    # ------------------------------------------------------------------------
    # AC2/AC3: CONTAINER REACHABILITY (criterion 2's fourth constraint,
    # discovered by the audit per spec section 1) -- observable behavior 10.
    # A file written under TestSandbox::new_temp_dir() must be visible BY
    # CONTENT inside a probe container bind-mounting it.
    # ------------------------------------------------------------------------
    if (defined $sandbox_dir) {
        my $nonce  = 'zqx-reach-' . $$ . '-' . int(rand(1_000_000));
        my $marker = "$sandbox_dir/marker.txt";
        my $wrote  = eval { open(my $fh, '>', $marker) or die $!; print {$fh} $nonce; close $fh; 1 };
        ok($wrote, 'AC2/AC3 (container / mnt/c reachability): fixture file written under TestSandbox::new_temp_dir()')
            or diag($@);

        # Decision 120(a): a bounded reachability probe, not just CLI presence,
        # gates these three -- on this host's normal state (podman on PATH,
        # machine STOPPED), `create_probe_container()` would otherwise die with
        # a raw podman connection-refused error, reported as a genuine
        # assertion failure rather than the clean skip this actually is.
        SKIP: {
            skip(TestSandbox::container_unreachable_reason(), 3)
                unless TestSandbox::container_runtime_reachable();

            my $container = eval { TestSandbox::create_probe_container(mounts => ['-v', "$sandbox_dir:/mnt/probe"]) };
            my $create_err = $@;
            if (defined $container) {
                my ($rc, $out) = TestSandbox::podman_run_capture('exec', $container, 'cat', '/mnt/probe/marker.txt');
                is($rc, 0, 'AC2/AC3 (container / mnt/c reachability): `cat` of the mounted marker file exits 0')
                    or diag($out);
                like($out, qr/\Q$nonce\E/,
                    'AC2/AC3 (container / mnt/c reachability): the file written under TestSandbox::new_temp_dir() '
                  . 'is visible BY CONTENT inside a probe container bind-mounting it');
                unlike($out, qr/zqx-should-never-appear-[0-9a-f]{8}/,
                    'counter-fixture: an unrelated nonce that was never written does not spuriously appear');
                TestSandbox::cleanup_all();
            } else {
                fail("AC2/AC3 (container / mnt/c reachability): create_probe_container() died: $create_err");
                fail('(cat check skipped: no container)');
                fail('(counter-fixture skipped: no container)');
            }
        }
    } else {
        fail('AC2/AC3 (container / mnt/c reachability): cannot test -- new_temp_dir() died');
        fail('(cat check skipped)');
        fail('(counter-fixture skipped)');
    }
}

# ============================================================================
# AC2/AC3: NO 8.3 on the ROOT itself -- FUNCTIONAL SUBSTITUTE (INTERPRETATION
# NOTE 3b). A real git init --bare / clone / push round-trip under
# HostCaps::scratch_root() . '/steward', reusing $STEWARD_ROOT above, exactly
# mirroring plugins/steward/tests/t/no-drive-root-strays.t's own shape
# (observable behavior 11).
# ============================================================================
if (defined $STEWARD_ROOT) {
    my $remote = eval { StewardTest::init_remote($STEWARD_ROOT) };
    my $home   = eval { StewardTest::make_machine($STEWARD_ROOT, 'home1') } if !$@;
    if (defined $remote && defined $home) {
        my $init = StewardTest::run_vs($home, 'init', '--url', $remote);
        ok($init->{exit} == 0 && $init->{json},
            'AC2/AC3 (8.3 / StewardTest.pm:85, functional form): vault init (clone) under '
          . 'HostCaps::scratch_root().."/steward" succeeds -- the real-world failure mode an 8.3-tainted '
          . 'root produces is a broken git remote, not a cosmetic string mismatch')
            or diag("exit=$init->{exit} out=$init->{out}");

        my $hp = StewardTest::run_vs($home, 'host-memory-path', '--cwd', "$STEWARD_ROOT/proj");
        if ($hp->{json} && $hp->{json}{memory_dir}) {
            StewardTest::write_text("$hp->{json}{memory_dir}/MEMORY.md", "scratch-root-single.t probe\n");
        }
        my $reg = StewardTest::run_vs($home, 'register', '--fresh', '--cwd', "$STEWARD_ROOT/proj",
                                       '--slug', 'scratch-root-probe', '--files', '_host-memory');
        ok($reg->{exit} == 0 && $reg->{json},
            'AC2/AC3 (8.3 / StewardTest.pm:85, functional form): vault register (commit + push) under '
          . 'HostCaps::scratch_root().."/steward" succeeds')
            or diag("exit=$reg->{exit} out=$reg->{out}");

        # Non-vacuity: if the flow silently no-opped, the two checks above
        # would be meaningless.
        ok($init->{exit} == 0, 'non-vacuity: the git round-trip actually ran (init exited 0)');
    } else {
        fail("AC2/AC3 (8.3, functional form): setup (init_remote/make_machine) failed: $@");
        fail('(register check skipped: setup failed)');
        fail('(non-vacuity check skipped: setup failed)');
    }
} else {
    fail('AC2/AC3 (8.3, functional form): cannot run the git round-trip -- StewardTest::temproot() died');
    fail('(register check skipped)');
    fail('(non-vacuity check skipped)');
}

# ============================================================================
# NATIVE_TMP MUST NOT MOVE -- task's own "assertions that matter most" #6.
# git_path()'s `/tmp -> native_tmp()` substitution exists because MSYS
# physically mounts /tmp at the Windows temp directory; native_tmp() is a
# MOUNT-POINT TRANSLATION TABLE, not a choice of scratch root, so it must
# stay %TEMP%-anchored even after this package's default root moves
# elsewhere (spec 2.4, substantiated with the exact quoted git_path() source
# in the spec and independently confirmed against this host's `cygpath -w
# /tmp`). Repointing it at scratch_root() would make git_path('/tmp/X')
# return a path where nothing was ever physically created -- the 576-stray
# incident recurring through a different call path.
# ============================================================================
{
    my $native = eval { HostCaps::native_tmp() };
    ok(!$@, 'HostCaps::native_tmp() does not die') or diag($@);

    my $expect_native = fwd($ENV{TEMP} // $ENV{TMP});
    if (defined $native && defined $expect_native) {
        is(lc($native), lc($expect_native),
            'native_tmp() regression guard: still anchored at %TEMP%, NOT repointed at scratch_root() '
          . '(the landmine spec 2.4 names explicitly)');
    } else {
        fail('native_tmp() regression guard: cannot compare -- native_tmp() or %TEMP% was undef');
    }

    my $translated = eval { HostCaps::git_path('/tmp/regression-marker-8f3c1') };
    ok(!$@, 'HostCaps::git_path("/tmp/X") does not die') or diag($@);
    if (defined $translated && defined $expect_native) {
        like($translated, qr{^\Q$expect_native\E/regression-marker-8f3c1$},
            'git_path("/tmp/X") still resolves under %TEMP% -- the MSYS /tmp mount is not this package\'s '
          . 'to move, and this is exactly the substitution the 8.3/native-path regression tests already '
          . 'depend on');
        # Counter-fixture: prove this WOULD catch the exact regression the
        # spec names, if native_tmp() were ever repointed at scratch_root().
        if (defined $ROOT) {
            unlike($translated, qr{^\Q$ROOT\E},
                'counter-fixture: git_path("/tmp/X") result is NOT under scratch_root() -- proving this '
              . 'check would fail loudly if native_tmp() were ever repointed there');
        }
    } else {
        fail('git_path("/tmp/X") regression guard: cannot compare -- a prerequisite value was undef');
    }
}

# ============================================================================
# AC5: OVERRIDE CASE TABLE (criterion 5) -- every row runs in a fresh child
# perl process (INTERPRETATION NOTE 2). Rows named per spec 2.3's table;
# "row 2" is the non-Windows-only row, included as a best-effort bonus
# (INTERPRETATION NOTE 1).
# ============================================================================

sub child_snippet {
    my ($setup, $expr) = @_;
    $setup //= '';
    return $setup . "\n"
         . qq{my \$r = eval { $expr };\n}
         . qq{if (\$\@) { print "DIED::" . \$\@; exit 3; }\n}
         . qq{print "OK::" . (defined(\$r) ? \$r : "UNDEF");\n}
         . qq{exit 0;\n};
}

sub run_perl_child {
    my (%opt) = @_;
    my @inc  = @{ $opt{inc} || [] };
    my $code = $opt{code};

    my $tmp = File::Temp->new(SUFFIX => '.pl', UNLINK => 1);
    print {$tmp} $code;
    close $tmp;
    my $script = $tmp->filename;

    local %ENV = %ENV;
    my %env_over = %{ $opt{env} || {} };
    for my $k (keys %env_over) {
        if (defined $env_over{$k}) { $ENV{$k} = $env_over{$k}; }
        else                       { delete $ENV{$k}; }
    }
    $ENV{CCPRAXIS_TEST_NO_SWEEP} = 1;

    my @cmd = ($^X, (map { "-I$_" } @inc), $script);
    open my $fh, '-|', @cmd or die "cannot spawn child perl: $!";
    local $/;
    my $out = <$fh>;
    close $fh;
    my $exit = $? >> 8;
    return (defined($out) ? $out : '', $exit);
}

my $HOSTCAPS_INC    = ["$Bin/../lib"];
my $STEWARDTEST_INC = ["$Bin/../../../steward/tests/lib"];
my $TESTSANDBOX_INC = ["$Bin/../../../sandbox/tests/lib", "$Bin/../../../sandbox/scripts"];

my $HC_EXPR = 'require HostCaps; HostCaps::scratch_root()';
my $ST_EXPR = 'require StewardTest; StewardTest::temproot()';
my $TS_EXPR = 'require TestSandbox; TestSandbox->import(qw(new_temp_dir)); TestSandbox::new_temp_dir()';

# ---- Row 1: unset, Windows -> default, created if missing -----------------
{
    my ($out, $exit) = run_perl_child(inc => $HOSTCAPS_INC, env => { CCPRAXIS_SCRATCH_ROOT => undef },
                                       code => child_snippet(undef, $HC_EXPR));
    like($out, qr/^OK::/, 'AC5 row 1 (unset): HostCaps::scratch_root() does not die in a fresh process')
        or diag("child output: $out (exit=$exit)");
    (my $val = $out) =~ s/^OK:://;
    is($val, 'C:/ccpraxis-scratch', 'AC5 row 1 (unset): HostCaps::scratch_root() returns exactly C:/ccpraxis-scratch');
}

# ---- Row 1 (edge case, spec section 5): empty string treated as unset -----
{
    my ($out, $exit) = run_perl_child(inc => $HOSTCAPS_INC, env => { CCPRAXIS_SCRATCH_ROOT => '' },
                                       code => child_snippet(undef, $HC_EXPR));
    (my $val = $out) =~ s/^OK:://;
    is($val, 'C:/ccpraxis-scratch',
        "edge case (spec section 5): CCPRAXIS_SCRATCH_ROOT='' (empty string) is treated identically to unset")
        or diag("child output: $out (exit=$exit)");
}

# ---- Row 1, derivation via subprocess (spec 2.3: "additionally exercised
#      through StewardTest::temproot() and TestSandbox::new_temp_dir()") ----
{
    my ($out, $exit) = run_perl_child(inc => $STEWARDTEST_INC, env => { CCPRAXIS_SCRATCH_ROOT => undef },
                                       code => child_snippet(undef, $ST_EXPR));
    like($out, qr{^OK::/c/ccpraxis-scratch/steward/},
        'AC5 row 1, via StewardTest::temproot() in a fresh process: descends from the default root')
        or diag("child output: $out (exit=$exit)");
}
SKIP: {
    skip('no container CLI on PATH', 1) unless $TESTSANDBOX_OK;
    my ($out, $exit) = run_perl_child(inc => $TESTSANDBOX_INC, env => { CCPRAXIS_SCRATCH_ROOT => undef },
                                       code => child_snippet(undef, $TS_EXPR));
    like($out, qr{^OK::C:/ccpraxis-scratch/sandbox/},
        'AC5 row 1, via TestSandbox::new_temp_dir() in a fresh process: descends from the default root')
        or diag("child output: $out (exit=$exit)");
}

# ---- Row 2 (BEST-EFFORT bonus, INTERPRETATION NOTE 1): unset + non-Windows
{
    my ($out, $exit) = run_perl_child(inc => $HOSTCAPS_INC, env => { CCPRAXIS_SCRATCH_ROOT => undef },
                                       code => child_snippet('BEGIN { $^O = "linux" }', $HC_EXPR));
    is($out, 'OK::UNDEF',
        'best-effort row 2 (unset, $^O faked to non-Windows): scratch_root() returns undef, per the '
      . 'pseudocode contract (2.2) -- caller falls back to its own pre-existing non-Windows behavior')
        or diag("child output: $out (exit=$exit)");
}

# ---- Row 3: absolute, pre-created, writable override -----------------------
my $OVERRIDE_DIR;
{
    my $native_temp = fwd($ENV{TEMP} // $ENV{TMP});
    $OVERRIDE_DIR = fwd(tempdir(DIR => $native_temp, CLEANUP => 1));

    my ($out, $exit) = run_perl_child(inc => $HOSTCAPS_INC,
                                       env => { CCPRAXIS_SCRATCH_ROOT => $OVERRIDE_DIR },
                                       code => child_snippet(undef, $HC_EXPR));
    is($out, "OK::$OVERRIDE_DIR",
        'AC5 row 3 (absolute, pre-created, writable override): scratch_root() returns it verbatim')
        or diag("child output: $out (exit=$exit)");

    # Backslash-given variant must normalize to the identical forward-slash result.
    (my $backslash_form = $OVERRIDE_DIR) =~ s{/}{\\}g;
    my ($out2, $exit2) = run_perl_child(inc => $HOSTCAPS_INC,
                                         env => { CCPRAXIS_SCRATCH_ROOT => $backslash_form },
                                         code => child_snippet(undef, $HC_EXPR));
    is($out2, "OK::$OVERRIDE_DIR",
        'AC5 row 3: given with backslashes (C:\...\...), the override is backslash-normalized to the same forward-slash value')
        or diag("child output: $out2 (exit=$exit2)");

    # Derivation through both derivers, under the override.
    my ($sout, $sexit) = run_perl_child(inc => $STEWARDTEST_INC,
                                         env => { CCPRAXIS_SCRATCH_ROOT => $OVERRIDE_DIR },
                                         code => child_snippet(undef, $ST_EXPR));
    my $override_posix = to_posix_form($OVERRIDE_DIR);
    like($sout, qr{^OK::\Q$override_posix\E/steward/},
        'AC5 row 3, via StewardTest::temproot(): descends from the OVERRIDE root, not the default')
        or diag("child output: $sout (exit=$sexit)");

    SKIP: {
        skip('no container CLI on PATH', 1) unless $TESTSANDBOX_OK;
        my ($tout, $texit) = run_perl_child(inc => $TESTSANDBOX_INC,
                                             env => { CCPRAXIS_SCRATCH_ROOT => $OVERRIDE_DIR },
                                             code => child_snippet(undef, $TS_EXPR));
        like($tout, qr{^OK::\Q$OVERRIDE_DIR\E/sandbox/},
            'AC5 row 3, via TestSandbox::new_temp_dir(): descends from the OVERRIDE root, not the default')
            or diag("child output: $tout (exit=$texit)");
    }

    # "no directory named ccpraxis-scratch is touched" (observable behavior 5).
    if (defined $ROOT && -d "$ROOT/steward") {
        opendir(my $dh, "$ROOT/steward") or die "opendir $ROOT/steward: $!";
        my @before = grep { !/^\.\.?$/ } readdir $dh;
        closedir $dh;
        # (the override subprocess above already ran before this snapshot;
        # take a second one after a no-op re-run to prove stability)
        my ($sout2, undef) = run_perl_child(inc => $STEWARDTEST_INC,
                                             env => { CCPRAXIS_SCRATCH_ROOT => $OVERRIDE_DIR },
                                             code => child_snippet(undef, $ST_EXPR));
        opendir(my $dh2, "$ROOT/steward") or die "opendir $ROOT/steward: $!";
        my @after = grep { !/^\.\.?$/ } readdir $dh2;
        closedir $dh2;
        is(scalar(@after), scalar(@before),
            'observable behavior 5: exercising a valid override does not add entries under the '
          . 'DEFAULT root\'s steward subdirectory');
    } else {
        fail('cannot check "no ccpraxis-scratch touched" -- default root/steward subdir not present');
    }
}

# ============================================================================
# FIX-BATCH (blueprint test-platform-split, package 04-scratch-root, step 6
# red-team + review + Decision 12). Authorised ADDITIONS only -- every row
# above this block is unmodified and its expected values are unchanged.
# ============================================================================

# ---- A1/Decision 12 (M1, 576 drive-root strays): a bare POSIX absolute
#      override is REFUSED on Windows, since the override BECOMES the root
#      and inherits the native-path constraint the default root must also
#      satisfy. Counter-fixture: a drive-letter form of a real directory is
#      still accepted, so this cannot be passing by rejecting everything. ----
SKIP: {
    skip('Windows-only: constraint 1 (native path) only bites on this platform', 3)
        unless $^O =~ /^(MSWin32|cygwin|msys)$/;

    my $posix_override = '/usr';
    ok(-d $posix_override, 'fixture sanity: /usr genuinely exists on this Git-for-Windows host')
        or diag('If /usr does not exist here, this row cannot exercise the real hazard -- see M1.');

    my ($out, $exit) = run_perl_child(inc => $HOSTCAPS_INC,
                                       env => { CCPRAXIS_SCRATCH_ROOT => $posix_override },
                                       code => child_snippet(undef, $HC_EXPR));
    like($out, qr/^DIED::/,
        'A1/Decision 12 (576 drive-root strays): a bare POSIX absolute override (/usr, which genuinely '
      . 'exists on this host) is REFUSED on Windows -- it is exactly the shape that a native binary '
      . 'resolves against the current drive')
        or diag("child output: $out (exit=$exit)");
    like($out, qr/bare POSIX-style absolute path/,
        'A1/Decision 12: the die names the drive-resolution hazard specifically, not the generic '
      . '"relative path" message');

    # Counter-fixture: the drive-letter form of a real, existing directory is
    # still accepted -- proves the check above rejects the SHAPE (bare POSIX),
    # not every override.
    my $drive_form = fwd($ENV{TEMP} // $ENV{TMP});
    my ($out2, $exit2) = run_perl_child(inc => $HOSTCAPS_INC,
                                         env => { CCPRAXIS_SCRATCH_ROOT => $drive_form },
                                         code => child_snippet(undef, $HC_EXPR));
    is($out2, "OK::$drive_form",
        'counter-fixture: the drive-letter form of a real, existing directory is still ACCEPTED -- the '
      . 'bare-POSIX-absolute check above cannot be passing by rejecting every override')
        or diag("child output: $out2 (exit=$exit2)");
}

# ---- A2 (M2): an override containing a '..' path segment is refused
#      outright, never silently resolved. ----------------------------------
{
    my $native_temp = fwd($ENV{TEMP} // $ENV{TMP});
    my ($leaf) = $native_temp =~ m{([^/]+)\z};
    my $parent = $native_temp;
    $parent =~ s{/\Q$leaf\E\z}{};
    my $dotdot_override = "$parent/$leaf/../$leaf";  # resolves to $native_temp itself

    my ($out, $exit) = run_perl_child(inc => $HOSTCAPS_INC,
                                       env => { CCPRAXIS_SCRATCH_ROOT => $dotdot_override },
                                       code => child_snippet(undef, $HC_EXPR));
    like($out, qr/^DIED::/,
        'A2 (M2): an override containing a ".." path segment is REFUSED outright, not silently '
      . 'canonicalized, even though it resolves to a real, existing, writable directory')
        or diag("child output: $out (exit=$exit)");
    like($out, qr/canonical form \(no '\.\.'\)/,
        'A2 (M2): the die message names the ".." problem and asks for canonical form');

    # Counter-fixture: the SAME target given WITHOUT the '..' segment is
    # accepted -- proves the check rejects the SEGMENT, not the destination.
    my ($out2, $exit2) = run_perl_child(inc => $HOSTCAPS_INC,
                                         env => { CCPRAXIS_SCRATCH_ROOT => $native_temp },
                                         code => child_snippet(undef, $HC_EXPR));
    is($out2, "OK::$native_temp",
        'counter-fixture: the identical destination given WITHOUT a ".." segment is accepted -- the '
      . 'check above rejects the segment, not the resolved directory')
        or diag("child output: $out2 (exit=$exit2)");
}

# ---- A3 (M3): StewardTest::temproot() DIES LOUDLY, naming the path and
#      reason, rather than falling through to %TEMP% when its
#      scratch_root()-derived steward subdirectory cannot be created/used.
#      This is the actual regression M3 warns about: the candidate's role
#      changed from cosmetic to load-bearing, and a silent fallthrough here
#      would defeat the whole package's purpose.
#
#      NON-VACUITY NOTE: on this host, Perl's -w on a DIRECTORY does not
#      reflect chmod/attrib/real-ACL restriction (empirically confirmed while
#      writing this fix -- even "C:/System Volume Information", genuinely
#      restricted to SYSTEM, reports -w=1), so a "-d true but -w false"
#      fixture cannot be constructed on this host and would not distinguish
#      old from new code if it could (File::Path's own croak, unwrapped,
#      already propagates uncaught in the PRE-fix code for a make_path
#      failure -- confirmed directly: reverting A3 alone did NOT turn this
#      block red when it asserted only "dies"/"does not return"). The
#      genuinely distinguishing, fix-specific signal is the MESSAGE ITSELF:
#      pre-fix, a blocked make_path() propagates File::Path's own raw croak
#      text ("mkdir ... File exists at StewardTest.pm line N"); post-fix it
#      is wrapped with a diagnostic prefix naming the path and
#      HostCaps::scratch_root()."/steward" explicitly. That prefix is what is
#      asserted below, not merely "some die happened". ----------------------
{
    my $native_temp = fwd($ENV{TEMP} // $ENV{TMP});
    my $blocked_root = fwd(tempdir(DIR => $native_temp, CLEANUP => 1));
    # Occupy the "steward" subdirectory slot with a plain FILE, so
    # make_path("$blocked_root/steward") cannot create a directory there --
    # reproducing "cannot create/use" without depending on chmod/attrib
    # semantics, which (per the note above) do not restrict directory writes
    # on NTFS via MSYS perl on this host.
    open(my $fh, '>', "$blocked_root/steward") or die "fixture: open $blocked_root/steward: $!";
    close $fh;

    my ($out, $exit) = run_perl_child(inc => $STEWARDTEST_INC,
                                       env => { CCPRAXIS_SCRATCH_ROOT => $blocked_root },
                                       code => child_snippet(undef, $ST_EXPR));
    like($out, qr/^DIED::/,
        'A3 (M3): StewardTest::temproot() DIES when its scratch_root()-derived steward subdirectory '
      . 'cannot be created (a plain file occupies that path), rather than silently trying another candidate')
        or diag("child output: $out (exit=$exit)");
    unlike($out, qr/^OK::/,
        'A3 (M3): the actual regression being prevented -- temproot() must NOT return ANY path (in '
      . 'particular not a %TEMP%-based one) when the authoritative scratch-root candidate fails')
        or diag("child output: $out (exit=$exit) -- if this is OK::<some TEMP-based path>, temproot() is "
              . "silently falling back exactly as M3 warns against");
    like($out, qr/could not create scratch subdirectory .*HostCaps::scratch_root\(\)/,
        'A3 (M3), FIX-SPECIFIC SIGNAL: the die is StewardTest\'s OWN diagnostic wrapper naming the path and '
      . 'HostCaps::scratch_root().\'/steward\' explicitly -- not merely File::Path\'s raw unwrapped croak '
      . '(which is what the pre-fix code propagated for this exact fixture, and which contains neither phrase)')
        or diag("child output: $out (exit=$exit)");
}

# ---- A4 (T1): an override that EXISTS but is a plain file gets a distinct
#      message from "does not exist". ---------------------------------------
{
    my $native_temp = fwd($ENV{TEMP} // $ENV{TMP});
    my ($fh, $file_override_raw) = File::Temp::tempfile(DIR => $native_temp, UNLINK => 0, SUFFIX => '.txt');
    close $fh;
    my $file_override = fwd($file_override_raw);

    my ($out, $exit) = run_perl_child(inc => $HOSTCAPS_INC,
                                       env => { CCPRAXIS_SCRATCH_ROOT => $file_override },
                                       code => child_snippet(undef, $HC_EXPR));
    unlink $file_override_raw;

    like($out, qr/^DIED::/,
        'A4 (T1): an override that exists but is a plain FILE (not a directory) dies')
        or diag("child output: $out (exit=$exit)");
    like($out, qr/exists and is not a directory/,
        'A4 (T1): the message distinguishes "exists and is not a directory" from "does not exist"');
    unlike($out, qr/does not exist/,
        'A4 (T1): the file-not-directory case does NOT get the misleading "does not exist" message');
}

# ---- Row 4: relative path -> dies, propagates uncaught through BOTH derivers
{
    my $relval = 'ccpraxis-scratch';
    my $expected_re = qr/is set to a relative path \('\Q$relval\E'\); it must be absolute\. Refusing rather than guessing\./;

    my ($out, $exit) = run_perl_child(inc => $HOSTCAPS_INC, env => { CCPRAXIS_SCRATCH_ROOT => $relval },
                                       code => child_snippet(undef, $HC_EXPR));
    like($out, qr/^DIED::/, 'AC5 row 4 (relative): HostCaps::scratch_root() dies') or diag($out);
    like($out, $expected_re, 'AC5 row 4 (relative): dies with the pinned message');

    my ($sout, $sexit) = run_perl_child(inc => $STEWARDTEST_INC, env => { CCPRAXIS_SCRATCH_ROOT => $relval },
                                         code => child_snippet(undef, $ST_EXPR));
    like($sout, qr/^DIED::/,
        'AC5 row 4: the die propagates UNCAUGHT through StewardTest::temproot() (not swallowed in an internal eval)')
        or diag("child output: $sout (exit=$sexit) -- if this is OK::<some path>, temproot() is silently "
              . "falling back to a different candidate instead of letting the bad override abort the run");
    like($sout, $expected_re, 'AC5 row 4, via StewardTest::temproot(): the propagated die carries the pinned message');

    SKIP: {
        skip('no container CLI on PATH', 2) unless $TESTSANDBOX_OK;
        my ($tout, $texit) = run_perl_child(inc => $TESTSANDBOX_INC, env => { CCPRAXIS_SCRATCH_ROOT => $relval },
                                             code => child_snippet(undef, $TS_EXPR));
        like($tout, qr/^DIED::/,
            'AC5 row 4: the die propagates UNCAUGHT through TestSandbox::new_temp_dir() (not swallowed)')
            or diag("child output: $tout (exit=$texit)");
        like($tout, $expected_re, 'AC5 row 4, via TestSandbox::new_temp_dir(): the propagated die carries the pinned message');
    }
}

# ---- Row 5: absolute, nonexistent -> dies with the "does not exist" message
{
    my $missing = 'C:/does/not/exist-scratch-root-probe-' . $$;
    my $expected_re = qr/is set to '\Q$missing\E', but that directory\s+does not exist\. Create it first, or unset the variable to use\s+the default root\./;

    my ($out, $exit) = run_perl_child(inc => $HOSTCAPS_INC, env => { CCPRAXIS_SCRATCH_ROOT => $missing },
                                       code => child_snippet(undef, $HC_EXPR));
    like($out, qr/^DIED::/, 'AC5 row 5 (nonexistent): HostCaps::scratch_root() dies') or diag($out);
    like($out, $expected_re, 'AC5 row 5 (nonexistent): dies with the pinned message');
}

# ---- Row 6: tilde -> dies with the SAME relative-path message as row 4 -----
{
    my $tildeval = '~/scratch';
    my $expected_re = qr/is set to a relative path \('\Q$tildeval\E'\); it must be absolute\. Refusing rather than guessing\./;
    my $generic_re  = qr/relative path/;

    my ($out, $exit) = run_perl_child(inc => $HOSTCAPS_INC, env => { CCPRAXIS_SCRATCH_ROOT => $tildeval },
                                       code => child_snippet(undef, $HC_EXPR));
    like($out, qr/^DIED::/, 'AC5 row 6 (tilde): HostCaps::scratch_root() dies (no ~ expansion happens)') or diag($out);
    like($out, $generic_re, 'AC5 row 6 (tilde): dies with a message matching /relative path/, same shape as row 4');
    like($out, $expected_re,
        'AC5 row 6 (tilde): the message is the IDENTICAL relative-path template, not a distinct tilde-specific message');
}

# ---- Row 7: absolute, non-ASCII, pre-created -> succeeds, verbatim --------
# Decision 120(b): this used to rely on $ENV{USERPROFILE} itself containing a
# non-ASCII byte (the real, ambient username on this host). Under
# scripts/run-tests.pl's per-file sandbox (package 21-test-sandbox),
# USERPROFILE (and TEMP/TMP) are replaced with a throwaway ASCII path, so
# that assumption no longer holds -- this fixture now builds its OWN
# non-ASCII subdirectory under the sandbox/native temp root instead of
# depending on the ambient environment's real value.
{
    my $native_temp = fwd($ENV{TEMP} // $ENV{TMP});
    my $base_dir = fwd(tempdir(DIR => $native_temp, CLEANUP => 1));
    my $nonascii_dir = "$base_dir/Andr\x{e9}";
    mkdir($nonascii_dir) or die "fixture: mkdir $nonascii_dir: $!";
    like($nonascii_dir, qr/[^\x00-\x7f]/,
        'fixture sanity: the row-7 override directory genuinely contains a non-ASCII byte (built by this '
      . 'fixture under the temp root, not relying on $ENV{USERPROFILE}\'s ambient value)');

    my ($out, $exit) = run_perl_child(inc => $HOSTCAPS_INC, env => { CCPRAXIS_SCRATCH_ROOT => $nonascii_dir },
                                       code => child_snippet(undef, $HC_EXPR));
    is($out, "OK::$nonascii_dir",
        'AC5 row 7 (absolute, non-ASCII, pre-created override): scratch_root() succeeds and returns it '
      . 'verbatim -- no ASCII re-validation is applied to an explicit override (spec 2.3 row 7)')
        or diag("child output: $out (exit=$exit)");
}

done_testing();
