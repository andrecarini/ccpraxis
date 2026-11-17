#!/usr/bin/env perl
# platform: host
# Oracle for blueprint package 01-platform-marker (blueprint test-platform-split).
# Derived ONLY from
# .ccpraxis-local-data/blueprints/test-platform-split/specs/01-platform-marker-spec.md
# (507 lines, AC-1..AC-17 in section 4, the 17-row worked-example oracle in
# section 5). NOT derived from any implementation: plugins/butler/tests/lib/
# TestPlatform.pm does not exist on disk at the time this file is written.
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. Every assertion below is expected to
# fail on ABSENCE OF THE MODULE (a `require` error caught by eval, so a
# fully-qualified call like TestPlatform::parse_marker(...) dies with
# "Undefined subroutine" -- caught per-call, never allowed to abort the run),
# never on a bug, typo, or bad expectation in THIS file.
#
# AC -> test label mapping (every AC-1..AC-17 and every oracle row 1..17 is
# covered by at least one labelled check below; grep this file for the AC/
# oracle number to find its assertions):
#   AC-1  -> oracle#1/2/3 (one per legal value), oracle#7 (dup collapse),
#            oracle#8 (conflict), oracle#12/13 (whitespace variants),
#            oracle#14/15 (malformed), oracle#17/AC-16 (precedence)
#   AC-2  -> oracle#4 (shebang header), oracle#10 (empty string), AC-13 (read_prefix)
#   AC-3  -> "AC-3 (undef input)"
#   AC-4  -> oracle#5 (unrecognised value)
#   AC-5  -> oracle#6 (legal word, wrong case)
#   AC-6  -> the "AC-6" sweep block, near the end
#   AC-7  -> oracle#12 (no whitespace), oracle#13 (leading indentation)
#   AC-8  -> oracle#14 (miscapitalized keyword)
#   AC-9  -> oracle#7 (duplicate identical legal markers)
#   AC-10 -> oracle#8 (legal-vs-legal) + "AC-10b" (legal-vs-illegal)
#   AC-11 -> oracle#9 (beyond the bound) + prefix_bytes()==4096 check
#   AC-12 -> oracle#11 (binary garbage)
#   AC-13 -> the read_prefix() fixture block
#   AC-14 -> the "perl -c" block
#   AC-15 -> oracle#15 (trailing prose)
#   AC-16 -> oracle#17, in its own dedicated precedence block
#   AC-17 -> "AC-17 (two loose-matching lines...)"
#
# MANDATORY VACUITY GATE (this blueprint's own standing rule -- a wrong
# implementation has passed a whole oracle here before, and the defect was in
# the oracle, not the code under test):
#   - Every detector-style check (the AC-6 structural sweep, the
#     malformed-marker-line-is-a-reason-not-an-outcome check, and AC-16's
#     "does not leak into raw" check) is followed by a COUNTER-FIXTURE that
#     proves the same predicate actually fires on data engineered to trip it.
#   - The AC-6 sweep additionally carries a non-vacuity GATE: it demands at
#     least 17 real (non-died) results before trusting "zero violations",
#     so a suite where every call died cannot report a false "pass".
#   - Where something is asserted ABSENT (the malformed line missing from
#     raw; malformed-marker-line never appearing as an outcome), the nearby
#     POSITIVE case (the line's presence when it SHOULD be there) is asserted
#     too, so the absence check cannot pass because everything is empty.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Terse    = 1;
$Data::Dumper::Indent   = 1;

use lib "$Bin/../lib";
my $MODULE_PM = "$Bin/../lib/TestPlatform.pm";

ok(-f $MODULE_PM, 'TestPlatform.pm exists at plugins/butler/tests/lib/TestPlatform.pm')
    or diag('TestPlatform.pm is not present yet -- every parse_marker/read_prefix/'
          . 'legal_values/prefix_bytes assertion below is expected to fail for '
          . 'exactly that reason, not for any other.');

my $LOAD_ERR;
eval { require TestPlatform; 1 } or do { $LOAD_ERR = $@ };
ok(!defined $LOAD_ERR, 'TestPlatform.pm loads with no compile/runtime error')
    or diag("load error: $LOAD_ERR");

# =============================================================================
# AC-14 (part 1) -- perl -c on the module itself.
# =============================================================================
{
    my $compile_out = `perl -c "$MODULE_PM" 2>&1`;
    my $compile_rc  = $?;
    is($compile_rc, 0, 'AC-14: perl -c plugins/butler/tests/lib/TestPlatform.pm exits 0')
        or diag($compile_out);
}

# =============================================================================
# Scaffolding: call_* wrappers never let a die/warn escape to the harness.
# Each returns ($result, $died_message_or_empty, \@warnings_seen).
# =============================================================================

sub call_parse_marker {
    my ($text) = @_;
    my @warnings;
    my $result;
    my $died;
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        $result = eval { TestPlatform::parse_marker($text) };
        $died = $@;
    }
    return ($result, $died, \@warnings);
}

sub call_read_prefix {
    my ($path) = @_;
    my @warnings;
    my $result;
    my $died;
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        $result = eval { TestPlatform::read_prefix($path) };
        $died = $@;
    }
    return ($result, $died, \@warnings);
}

sub call_legal_values {
    my @warnings;
    my @result;
    my $died;
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        @result = eval { TestPlatform::legal_values() };
        $died = $@;
    }
    return (\@result, $died, \@warnings);
}

sub call_prefix_bytes {
    my @warnings;
    my $result;
    my $died;
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        $result = eval { TestPlatform::prefix_bytes() };
        $died = $@;
    }
    return ($result, $died, \@warnings);
}

# Every real (non-died) parse_marker() result collected below, for the AC-6
# structural sweep near the end. A died call contributes nothing here (there
# is no hashref to check invariants against) -- its die/warn/shape failures
# are already reported at the call site.
my @ALL_RESULTS;

# check_parse_marker($label, $text, $expected_hashref) -> $result
# Asserts: no die, no warning, and an exact is_deeply match against $expected.
# Accumulates every successfully-returned hashref into @ALL_RESULTS.
sub check_parse_marker {
    my ($label, $text, $expected) = @_;
    my ($result, $died, $warnings) = call_parse_marker($text);
    ok(!$died, "$label -- parse_marker does not die")
        or diag("died: $died");
    is(scalar(@$warnings), 0, "$label -- parse_marker does not warn")
        or diag('warnings: ' . join(' | ', @$warnings));
    is_deeply($result, $expected, "$label -- parse_marker returns the expected result")
        or diag('got: ' . Dumper($result));
    push @ALL_RESULTS, $result if ref($result) eq 'HASH';
    return $result;
}

# =============================================================================
# prefix_bytes() -- AC-11's fixed-constant half.
# =============================================================================
my ($PB_RAW, $pb_died, $pb_warn) = call_prefix_bytes();
ok(!$pb_died, 'prefix_bytes() does not die') or diag("died: $pb_died");
is(scalar(@$pb_warn), 0, 'prefix_bytes() does not warn');
is($PB_RAW, 4096, 'AC-11: prefix_bytes() returns exactly 4096');

# Fallback ONLY so the fixtures below (which need a byte count to pad against)
# can be constructed before the module exists. The real pinned assertion
# (prefix_bytes() == 4096) already happened above and fails independently of
# this fallback; once the module exists, $PREFIX_BYTES below is the module's
# OWN reported value, not a re-hardcoded 4096, so a future change to the
# constant is still honoured by every fixture that uses $PREFIX_BYTES.
my $PREFIX_BYTES = (defined $PB_RAW && $PB_RAW =~ /^\d+$/) ? $PB_RAW : 4096;

# =============================================================================
# legal_values() -- exact three-element list, exact order.
# =============================================================================
{
    my ($lv, $died, $warn) = call_legal_values();
    ok(!$died, 'legal_values() does not die') or diag("died: $died");
    is(scalar(@$warn), 0, 'legal_values() does not warn');
    is_deeply($lv, ['host', 'linux', 'any'],
        "interface contract (spec section 2): legal_values() returns exactly "
      . "('host','linux','any') in that order");
}

# =============================================================================
# The 17-row worked-example oracle (spec section 5), plus AC-1..AC-15 as they
# fall out of those rows. Row 9 (beyond the bound) and row 17 (precedence)
# get their own dedicated blocks further down because they need extra
# scaffolding / extra explanation.
# =============================================================================

check_parse_marker('AC-1/oracle#1 (minimal legal marker: host)',
    "# platform: host\n",
    { outcome => 'legal', value => 'host', reason => undef, raw => ['host'] });

check_parse_marker('AC-1/oracle#2 (minimal legal marker: linux)',
    "# platform: linux\n",
    { outcome => 'legal', value => 'linux', reason => undef, raw => ['linux'] });

check_parse_marker('AC-1/oracle#3 (minimal legal marker: any)',
    "# platform: any\n",
    { outcome => 'legal', value => 'any', reason => undef, raw => ['any'] });

check_parse_marker('AC-2/oracle#4 (ordinary shebang header, no marker anywhere)',
    "#!/usr/bin/env perl\nuse strict;\nuse warnings;\n",
    { outcome => 'absent', value => undef, reason => undef, raw => [] });

check_parse_marker('AC-4/oracle#5 (unrecognised value: macos)',
    "# platform: macos\n",
    { outcome => 'invalid', value => undef, reason => 'unrecognized-value', raw => ['macos'] });

check_parse_marker('rename/oracle (retired value "windows" is illegal, not an alias)',
    "# platform: windows\n",
    { outcome => 'invalid', value => undef, reason => 'unrecognized-value', raw => ['windows'] });

is_deeply({ TestPlatform::renamed_values() }, { windows => 'host' },
    'rename/oracle: renamed_values() maps the retired "windows" to "host"');
ok(!(grep { $_ eq 'windows' } TestPlatform::legal_values()),
    'rename/oracle: "windows" is not among legal_values()');

check_parse_marker('AC-5/oracle#6 (legal word, wrong case: Host)',
    "# platform: Host\n",
    { outcome => 'invalid', value => undef, reason => 'unrecognized-value', raw => ['Host'] });

check_parse_marker('AC-9/oracle#7 (two identical legal markers collapse to one legal result)',
    "# platform: host\n# something else\n# platform: host\n",
    { outcome => 'legal', value => 'host', reason => undef, raw => ['host', 'host'] });

check_parse_marker('AC-10a/oracle#8 (conflicting markers: legal-vs-legal)',
    "# platform: host\n# platform: linux\n",
    { outcome => 'invalid', value => undef, reason => 'conflicting-markers', raw => ['host', 'linux'] });

check_parse_marker('AC-10b (conflicting markers: legal-vs-illegal)',
    "# platform: host\n# platform: macos\n",
    { outcome => 'invalid', value => undef, reason => 'conflicting-markers', raw => ['host', 'macos'] });

# D3 (spec section 8): duplicate IDENTICAL ILLEGAL values fold to
# 'unrecognized-value', never 'conflicting-markers' -- only genuine
# disagreement between raw captures produces 'conflicting-markers'.
# Fix-batch addition (review-step6.md oracle finding): a concrete alternate
# implementation was demonstrated that passes all 109 prior assertions while
# violating D3 (it derives the reason from `@raw > 1` instead of from
# whether the single unique value is legal). This case is the one that
# alternate implementation gets wrong.
check_parse_marker('D3 (duplicate identical ILLEGAL values fold to unrecognized-value, not conflicting-markers)',
    "# platform: macos\n# platform: macos\n",
    { outcome => 'invalid', value => undef, reason => 'unrecognized-value', raw => ['macos', 'macos'] });

check_parse_marker('oracle#10 (empty string)',
    '',
    { outcome => 'absent', value => undef, reason => undef, raw => [] });

check_parse_marker('AC-12/oracle#11 (binary garbage, no # byte anywhere, no die/warn regardless of byte values)',
    pack('C*', (0x00, 0x01, 0xFF, 0x10) x 50),
    { outcome => 'absent', value => undef, reason => undef, raw => [] });

check_parse_marker('AC-7a/oracle#12 (no whitespace anywhere: #platform:host)',
    "#platform:host\n",
    { outcome => 'legal', value => 'host', reason => undef, raw => ['host'] });

check_parse_marker('AC-7b/oracle#13 (leading indentation before #)',
    "   # platform: host\n",
    { outcome => 'legal', value => 'host', reason => undef, raw => ['host'] });

check_parse_marker('AC-8/oracle#14 (miscapitalized keyword: # Platform: host)',
    "# Platform: host\n",
    { outcome => 'invalid', value => undef, reason => 'malformed-marker-line', raw => ['# Platform: host'] });

check_parse_marker('AC-15/oracle#15 (trailing prose after an otherwise-legal value)',
    "# platform: host extra text\n",
    { outcome => 'invalid', value => undef, reason => 'malformed-marker-line',
      raw => ['# platform: host extra text'] });

check_parse_marker('oracle#16 (CRLF line ending, decision D4)',
    "# platform: host\r\n",
    { outcome => 'legal', value => 'host', reason => undef, raw => ['host'] });

check_parse_marker('AC-3 (undef input behaves exactly like the empty string)',
    undef,
    { outcome => 'absent', value => undef, reason => undef, raw => [] });

check_parse_marker('AC-17 (two loose-matching lines, no strict match anywhere)',
    "# Platform: host\n# platform : linux extra\n",
    { outcome => 'invalid', value => undef, reason => 'malformed-marker-line',
      raw => ['# Platform: host', '# platform : linux extra'] });

# =============================================================================
# never-dies / never-warns -- two more of the named edge cases (very long
# line, no trailing newline) not already covered by a row above. Neither is
# marker-shaped, so `absent` is the correct result; the point of these two
# is purely "does not die, does not warn" on shapes rows 1-17 don't exercise.
# =============================================================================

check_parse_marker('never-dies (a very long single line, no embedded newline, no trailing newline)',
    ('y' x 200000),
    { outcome => 'absent', value => undef, reason => undef, raw => [] });

check_parse_marker('never-dies + correctness (legal marker with NO trailing newline at all)',
    '# platform: any',
    { outcome => 'legal', value => 'any', reason => undef, raw => ['any'] });

# =============================================================================
# AC-11 -- the prefix bound, exercised as a pure in-memory string (per the
# spec, the bound is enforced inside parse_marker itself). Padding is derived
# from $PREFIX_BYTES (the module's own reported constant, with the pre-
# implementation fallback above), never hardcoded to 4096 directly, so this
# survives a future change to prefix_bytes().
# =============================================================================
{
    my $beyond_pad = $PREFIX_BYTES + 1000;
    check_parse_marker(
        "AC-11/oracle#9 (marker begins $beyond_pad bytes in -- strictly beyond prefix_bytes())",
        ('x' x $beyond_pad) . "\n# platform: host\n",
        { outcome => 'absent', value => undef, reason => undef, raw => [] });

    # Counter-fixture (non-vacuity): the SAME shape, padded to stay
    # comfortably WITHIN the bound, must still parse as legal -- proving the
    # `absent` result above is caused by the byte bound itself, not by some
    # accident of the padding character or the fixture's general shape.
    my $within_pad = ($PREFIX_BYTES > 300) ? $PREFIX_BYTES - 300 : 0;
    check_parse_marker(
        "AC-11 counter-fixture (marker begins $within_pad bytes in -- WITHIN prefix_bytes())",
        ('x' x $within_pad) . "\n# platform: host\n",
        { outcome => 'legal', value => 'host', reason => undef, raw => ['host'] });
}

# =============================================================================
# D9 -- a UTF-8 BOM before a first-line marker must not hide it (fix-batch
# addition, red-team MAJOR reproduced live: without the fix, this exact
# input returned `absent` because `^[ \t]*#` cannot consume the BOM's three
# bytes at byte offset 0).
# =============================================================================
check_parse_marker('D9 (UTF-8 BOM before a first-line marker is stripped -- marker is found)',
    "\xEF\xBB\xBF# platform: host\n",
    { outcome => 'legal', value => 'host', reason => undef, raw => ['host'] });

# Counter-fixture: the identical text with the BOM removed. This isolates
# the BOM as the only variable between the two fixtures -- proving the
# assertion above passes because the BOM is correctly stripped, not because
# every input happens to return `legal` regardless of what precedes it.
check_parse_marker('D9 counter-fixture (same text, no BOM)',
    "# platform: host\n",
    { outcome => 'legal', value => 'host', reason => undef, raw => ['host'] });

# =============================================================================
# D10 -- a marker cut mid-value by the prefix_bytes() truncation must never
# be accepted as a complete line (fix-batch addition, red-team MAJOR
# reproduced live). Without the fix, truncation mid-value can silently
# FORGE a legal-looking value out of an illegal one (or vice versa), which
# is strictly worse than a spurious `invalid`: it routes package 06's
# host-vs-container lane on a confidently wrong `legal` answer. All
# positions below are derived from TestPlatform::prefix_bytes() ($PREFIX_BYTES),
# never hardcoded to 4096.
# =============================================================================
{
    # --- Headline case: an ILLEGAL value ("anything") truncated to exactly
    # its first 3 characters happens to spell a LEGAL value ("any"). Before
    # the fix this returned {outcome=>'legal', value=>'any', ...} -- a
    # forged legal result for a file whose real, complete marker line is
    # illegal. This is the case that would silently route a test to the
    # wrong lane.
    my $prefix_before_value = '# platform: ';
    my $cut_after            = 3;   # chars of "anything" left inside the bound
    my $head_pad_len = $PREFIX_BYTES - length($prefix_before_value) - $cut_after;
    my $filler        = ('z' x ($head_pad_len - 1)) . "\n";
    my $text_forged   = $filler . $prefix_before_value . "anything\n";
    my $result_forged = check_parse_marker(
        'D10 headline (illegal value "anything" truncated mid-value must NOT forge the legal value "any")',
        $text_forged,
        { outcome => 'absent', value => undef, reason => undef, raw => [] });
    isnt(($result_forged || {})->{value}, 'any',
        'D10 headline: value is definitely not the forged "any"')
        if ref($result_forged) eq 'HASH';

    # --- Second reproduction: a LEGAL value ("host") truncated to its
    # first 4 characters ("wind"). Before the fix this returned
    # {outcome=>'invalid', reason=>'unrecognized-value', raw=>['wind']} --
    # a fragment that never appears in the real file as a standalone token.
    my $cut_after2     = 4;   # chars of "host" left inside the bound
    my $head_pad_len2  = $PREFIX_BYTES - length($prefix_before_value) - $cut_after2;
    my $filler2        = ('z' x ($head_pad_len2 - 1)) . "\n";
    my $text_fragment  = $filler2 . $prefix_before_value . "host\n";
    my $result_fragment = check_parse_marker(
        'D10 (legal value "host" truncated mid-value must not yield the fragment "wind" in raw)',
        $text_fragment,
        { outcome => 'absent', value => undef, reason => undef, raw => [] });
    if (ref($result_fragment) eq 'HASH' && ref($result_fragment->{raw}) eq 'ARRAY') {
        my @leaked = grep { /wind/ } @{ $result_fragment->{raw} };
        is(scalar(@leaked), 0, 'D10: the truncation fragment "wind" does not leak into raw at all');
    } else {
        fail('D10: the truncation fragment "wind" does not leak into raw at all (no raw array to inspect)');
    }

    # --- Counter-fixture (non-vacuity, "cannot pass by dropping too much"):
    # a marker that sits WHOLLY within the bound and whose line ends EXACTLY
    # at the truncation point (the bounded text's last byte is the marker
    # line's own trailing "\n") must still parse normally. This proves D10's
    # rule triggers only on a genuine mid-line cut, not on every truncation.
    my $marker_line   = "# platform: host\n";
    my $filler3_len   = $PREFIX_BYTES - length($marker_line);
    my $filler3       = ('z' x ($filler3_len - 1)) . "\n";
    my $text_aligned  = $filler3 . $marker_line . ('q' x 500);  # longer than the bound, cut is line-aligned
    check_parse_marker(
        'D10 counter-fixture (truncation lands exactly on a line boundary -- marker still parses)',
        $text_aligned,
        { outcome => 'legal', value => 'host', reason => undef, raw => ['host'] });
}

# =============================================================================
# AC-16 / oracle#17 -- PRECEDENCE, in its own block with its own comment.
#
# This is the assertion that stops a future "improvement" to the loose regex
# from silently reclassifying a valid file: a text with ONE malformed line
# (wrong-case keyword) and ONE strictly-valid line must resolve to `legal`,
# full stop, and the malformed line must be entirely invisible in `raw` --
# not merely outnumbered, but ABSENT. Per the spec this precedence is
# prefix-wide, not per-line, and the loose pattern is consulted only when the
# strict pattern found zero matches anywhere in the bounded prefix.
# =============================================================================
{
    my $result = check_parse_marker(
        'AC-16/oracle#17 (precedence: one malformed line + one strict-valid line)',
        "# Platform: host\n# platform: linux\n",
        { outcome => 'legal', value => 'linux', reason => undef, raw => ['linux'] });

    # Explicit, separate check (not merely riding on is_deeply having passed
    # above): the malformed line's exact text must not appear anywhere in raw.
    if (ref($result) eq 'HASH' && ref($result->{raw}) eq 'ARRAY') {
        my @leaked = grep { /Platform/ } @{ $result->{raw} };
        is(scalar(@leaked), 0,
            'AC-16: the malformed line ("# Platform: host") does not leak into raw at all');
    } else {
        fail('AC-16: the malformed line does not leak into raw at all (no raw array to inspect)');
    }

    # Counter-fixture (non-vacuity): swap which line is malformed vs. valid,
    # and confirm the OTHER strict value wins -- proving this isn't just "the
    # first/second line always wins" or some other positional accident.
    check_parse_marker(
        'AC-16 counter-fixture (swapped order: strict-valid line first, malformed line second)',
        "# platform: any\n# Platform: host\n",
        { outcome => 'legal', value => 'any', reason => undef, raw => ['any'] });
}

# =============================================================================
# AC-13 -- read_prefix() against real files, via File::Temp.
# =============================================================================
{
    my $WORK = tempdir(CLEANUP => 1);

    # Oversized file: strictly larger than prefix_bytes().
    my $big_path = "$WORK/big.txt";
    {
        open my $fh, '>:raw', $big_path or die "fixture: cannot write $big_path: $!";
        print {$fh} ('a' x ($PREFIX_BYTES + 500));
        close $fh;
    }
    {
        my ($got, $died, $warn) = call_read_prefix($big_path);
        ok(!$died, 'AC-13: read_prefix() on an oversized file does not die') or diag("died: $died");
        is(scalar(@$warn), 0, 'AC-13: read_prefix() on an oversized file does not warn');
        is(defined($got) ? length($got) : -1, $PREFIX_BYTES,
            "AC-13: read_prefix() on a file > prefix_bytes() returns a string of length exactly $PREFIX_BYTES");
    }

    # Small file: strictly smaller than prefix_bytes() -- returns the WHOLE
    # file. A positive case next to the bound above, so "truncates" is never
    # confused with "always returns exactly prefix_bytes() bytes".
    my $small_path    = "$WORK/small.txt";
    my $small_content = "# platform: linux\n";
    {
        open my $fh, '>:raw', $small_path or die "fixture: cannot write $small_path: $!";
        print {$fh} $small_content;
        close $fh;
    }
    {
        my ($got, $died, $warn) = call_read_prefix($small_path);
        ok(!$died, 'AC-13: read_prefix() on a small file does not die') or diag("died: $died");
        is(scalar(@$warn), 0, 'AC-13: read_prefix() on a small file does not warn');
        is($got, $small_content, 'AC-13: read_prefix() on a file < prefix_bytes() returns the WHOLE file');
    }

    # Nonexistent path.
    {
        my $missing = "$WORK/does-not-exist-8f3c1.txt";
        my ($got, $died, $warn) = call_read_prefix($missing);
        ok(!$died, 'AC-13: read_prefix() on a nonexistent path does not die') or diag("died: $died");
        is(scalar(@$warn), 0, 'AC-13: read_prefix() on a nonexistent path does not warn');
        is($got, '', 'AC-13: read_prefix() on a nonexistent path returns the empty string');
    }

    # Directory path (observable behavior 8's other "unreadable" case).
    {
        my ($got, $died, $warn) = call_read_prefix($WORK);
        ok(!$died, 'OB-8: read_prefix() on a directory does not die') or diag("died: $died");
        is(scalar(@$warn), 0, 'OB-8: read_prefix() on a directory does not warn');
        is($got, '', 'OB-8: read_prefix() on a directory returns the empty string');
    }

    # Undef path -- per the pseudocode's own guard clause ("return '' unless
    # defined $filepath").
    {
        my ($got, $died, $warn) = call_read_prefix(undef);
        ok(!$died, 'read_prefix(undef) does not die') or diag("died: $died");
        is(scalar(@$warn), 0, 'read_prefix(undef) does not warn');
        is($got, '', 'read_prefix(undef) returns the empty string');
    }
}

# =============================================================================
# AC-6 -- structural invariants, swept over EVERY result collected above (not
# per-case). This is the package's real reason for existing: package 03 turns
# `absent` into a hard failure, and if `value` were ever defined for a
# non-legal outcome, or a fourth outcome slipped in, that enforcement would
# become decorative.
# =============================================================================
{
    my $n = scalar @ALL_RESULTS;
    ok($n >= 17,
        "AC-6 non-vacuity gate: at least 17 real parse_marker results were collected to sweep (got $n) "
      . "-- 0 here would mean every call above died, and the checks below would trivially "
      . "'pass' over an empty set");

    my @bad_value = grep { defined($_->{value}) != ($_->{outcome} eq 'legal') } @ALL_RESULTS;
    is(scalar(@bad_value), 0,
        'AC-6: value is defined if and only if outcome eq legal, swept across every collected result')
        or diag(Dumper(\@bad_value));

    my @bad_outcome = grep { $_->{outcome} !~ /^(?:legal|absent|invalid)$/ } @ALL_RESULTS;
    is(scalar(@bad_outcome), 0,
        'AC-6: outcome is always exactly one of legal/absent/invalid, swept across every collected result')
        or diag(Dumper(\@bad_outcome));

    my %seen_outcomes = map { $_->{outcome} => 1 } @ALL_RESULTS;
    is_deeply([sort keys %seen_outcomes], [sort qw(absent invalid legal)],
        'AC-6 non-vacuity: the sweep actually exercised all three outcomes, not just one');

    my @bad_reason = grep {
        (defined($_->{reason}) ? 1 : 0) != ($_->{outcome} eq 'invalid' ? 1 : 0)
    } @ALL_RESULTS;
    is(scalar(@bad_reason), 0,
        'structural invariant (spec section 2): reason is defined if and only if outcome eq invalid')
        or diag(Dumper(\@bad_reason));

    my @bad_raw_absent = grep {
        $_->{outcome} eq 'absent' && (ref($_->{raw}) ne 'ARRAY' || @{$_->{raw}} != 0)
    } @ALL_RESULTS;
    is(scalar(@bad_raw_absent), 0,
        'structural invariant: every absent result has raw == [] (the "only if" direction)');

    my @non_absent_with_empty_raw = grep {
        $_->{outcome} ne 'absent' && ref($_->{raw}) eq 'ARRAY' && @{$_->{raw}} == 0
    } @ALL_RESULTS;
    is(scalar(@non_absent_with_empty_raw), 0,
        'structural invariant: no non-absent result has an empty raw array (the "if" direction)');
}

# Meta counter-fixture (non-vacuity for the AC-6 checks immediately above):
# prove the membership/iff predicates used above are not tautologies by
# running them against fabricated data engineered to violate each one, and
# confirming they DO flag it. This never touches TestPlatform -- it is a
# self-check of this file's own assertion logic, exactly the kind of proof
# this blueprint's own vacuity gate demands.
{
    my @fake = (
        { outcome => 'legal',   value => undef,     reason => undef, raw => ['host'] }, # bad: legal w/o value
        { outcome => 'absent',  value => 'host',  reason => undef, raw => [] },          # bad: absent w/ value
        { outcome => 'bogus',   value => undef,      reason => undef, raw => [] },          # bad: 4th outcome
        { outcome => 'invalid', value => undef,      reason => undef, raw => ['x'] },       # bad: invalid w/o reason
    );
    my @bad_value   = grep { defined($_->{value}) != ($_->{outcome} eq 'legal') } @fake;
    my @bad_outcome = grep { $_->{outcome} !~ /^(?:legal|absent|invalid)$/ } @fake;
    my @bad_reason  = grep { (defined($_->{reason}) ? 1 : 0) != ($_->{outcome} eq 'invalid' ? 1 : 0) } @fake;
    ok(scalar(@bad_value) >= 2, 'meta: the value-iff-legal predicate fires on fabricated violations (non-vacuity)');
    ok(scalar(@bad_outcome) >= 1, 'meta: the three-outcome membership predicate fires on a fabricated 4th outcome (non-vacuity)');
    ok(scalar(@bad_reason) >= 1, 'meta: the reason-iff-invalid predicate fires on a fabricated violation (non-vacuity)');
}

# =============================================================================
# malformed-marker-line must be a REASON, never a fourth OUTCOME. Swept over
# every collected result so a future patch adding it as an outcome anywhere
# breaks this file loudly.
# =============================================================================
{
    my @wrong_outcome = grep { ($_->{outcome} // '') eq 'malformed-marker-line' } @ALL_RESULTS;
    is(scalar(@wrong_outcome), 0,
        "malformed-marker-line never appears as an outcome (it is a reason under 'invalid')");

    # Non-vacuity: the check above is meaningless if nothing in the sweep
    # ever carries this reason at all -- prove the positive case exists too.
    my @have_reason = grep { defined($_->{reason}) && $_->{reason} eq 'malformed-marker-line' } @ALL_RESULTS;
    ok(scalar(@have_reason) >= 3,
        'non-vacuity: at least 3 collected results DO carry reason eq malformed-marker-line '
      . '(got ' . scalar(@have_reason) . ') -- proving the check above is not vacuously true '
      . 'over a set that never produces this reason at all');
}

done_testing();
