#!/usr/bin/env perl
# platform: host
# ORACLE for package 01-wt-profile-fragment (blueprint sandbox-wt-profile),
# specs/01-wt-profile-fragment-spec.md. Written BLIND to any WtProfile.pm
# implementation -- directly from the spec's observable behaviors (B1..B15)
# and acceptance criteria (AC-1.x..AC-7.x) -- so it serves as an oracle, not
# an echo of whatever the implementer eventually writes. Do NOT weaken an
# assertion here to make a future implementation's life easier; this file is
# immutable once the implementer starts (see package ledger, step 4).
#
# TODAY'S EXPECTED STATE, recorded so a future reader is not surprised:
# plugins/sandbox/scripts/WtProfile.pm does not exist yet. The "WtProfile.pm
# loads via require" assertion below is the one that is SUPPOSED to fail
# right now -- that is the correct, deliberate state, not a bug in this
# file. Sections that do not depend on the module (the capture/warn/die
# meta-self-tests, and the source-hygiene scan when the file happens to be
# absent) report honestly either way. A static `use WtProfile ();` would
# abort compilation of this WHOLE file the instant the module is missing
# (BEGIN blocks run during compilation, before any runtime statement), which
# would make it impossible to report anything -- so the load is a guarded
# RUNTIME `require` instead, same as this house's other blind oracles (see
# plugins/sandbox/tests/t/theme-tokens.t's header for the same technique).
# Once package 01 lands WtProfile.pm, $WTPROFILE_LOADED flips true and every
# SKIP block below starts running its assertions for real.
#
# COUNTER-FIXTURES (house convention: a guard that cannot fire is not
# coverage). Three mechanisms are reused dozens of times below -- "assert no
# warning fired", "assert no die happened", "assert no STDOUT/STDERR output
# was produced" -- and this file proves each mechanism can actually detect a
# real warn/die/print exactly ONCE, near the top, rather than repeating an
# identical meta-proof at every one of the ~30 call sites that rely on it
# (see "shared-mechanism self-tests" below). Every OTHER negative assertion
# -- forbidden JSON keys, BOM bytes, CRLF, doubled path separators, the
# no-forward-slash resolver check, the two source-literal scans -- is
# spec-specific detection logic, not a generic Perl idiom, so each of THOSE
# gets its own local counter-fixture at its point of use.
#
# FILESYSTEM SAFETY (Decision 8): every filesystem AC uses
# File::Temp::tempdir(CLEANUP => 1) / File::Temp::tempfile(UNLINK => 1).
# Nothing in this file ever writes to, reads from, or names as a write
# target the developer's real %LOCALAPPDATA% Fragments directory.
# fragment_root's ACs pass only a synthetic hashref and assert on the
# returned STRING -- they never touch the filesystem.
#
# HARD CONSTRAINTS (AC-7.2): this file spawns no wt.exe, no launcher.pl,
# needs no container, no network, no `prove` (there is no TAP::Harness on
# this host). It runs standalone via `perl <file>`.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use File::Temp qw(tempdir tempfile);
use File::Spec;
use JSON::PP qw(decode_json);

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
my $SCRIPTS      = "$Bin/../../scripts";
my $WTPROFILE_PM = "$SCRIPTS/WtProfile.pm";

# ---------------------------------------------------------------------------
# Small byte-level helpers used by several ACs below (module-blind: these are
# TEST-owned detectors, not a sketch of the implementation).
# ---------------------------------------------------------------------------
sub _slurp_raw {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or die "cannot open '$path' for raw read: $!";
    local $/;
    my $data = <$fh>;
    close $fh;
    return defined($data) ? $data : '';
}

sub _has_high_byte {
    my ($bytes) = @_;
    return ($bytes =~ /[\x80-\xFF]/) ? 1 : 0;
}

sub _has_utf8_bom {
    my ($bytes) = @_;
    return (substr($bytes, 0, 3) eq "\xEF\xBB\xBF") ? 1 : 0;
}

sub _has_utf16_bom {
    my ($bytes) = @_;
    my $prefix = substr($bytes, 0, 2);
    return ($prefix eq "\xFF\xFE" || $prefix eq "\xFE\xFF") ? 1 : 0;
}

# Redirects the REAL stdout/stderr file descriptors (via File::Temp, never an
# in-memory scalar -- see this repo's CLAUDE.md on why reopening STDOUT/STDERR
# onto \$scalar breaks on Git-for-Windows perl) around a coderef, and returns
# what it printed. The coderef MUST NOT call any Test::More function -- that
# output would itself be swallowed by the redirect and corrupt this file's own
# TAP stream. Every call site below honors that rule.
sub _capture_streams {
    my ($code) = @_;
    my ($ofh, $ofile) = tempfile(UNLINK => 1);
    my ($efh, $efile) = tempfile(UNLINK => 1);
    close $ofh;
    close $efh;
    open(my $saved_out, '>&', \*STDOUT) or die "dup STDOUT: $!";
    open(my $saved_err, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDOUT, '>', $ofile) or die "redirect STDOUT: $!";
    open(STDERR, '>', $efile) or die "redirect STDERR: $!";
    my @ret = $code->();
    open(STDOUT, '>&', $saved_out) or die "restore STDOUT: $!";
    open(STDERR, '>&', $saved_err) or die "restore STDERR: $!";
    close $saved_out;
    close $saved_err;
    return (\@ret, _slurp_raw($ofile), _slurp_raw($efile));
}

# ---------------------------------------------------------------------------
# Shared-mechanism self-tests (counter-fixtures for every "warns nothing" /
# "does not die" / "no output" assertion later in this file). These do not
# touch WtProfile at all -- they prove Perl's own capture idioms work on
# THIS host before 30-odd assertions downstream lean on them.
# ---------------------------------------------------------------------------
{
    my @w;
    { local $SIG{__WARN__} = sub { push @w, @_ }; warn "meta-test probe warning\n"; }
    ok(scalar(@w) == 1 && $w[0] =~ /meta-test probe warning/,
       'meta-self-test: $SIG{__WARN__} capture (used by every "warns nothing" assertion below) catches a real warn');
}
{
    my $ok = eval { die "meta-test probe death\n"; 1 };
    ok(!$ok, 'meta-self-test: eval{}/$@ die-capture (used by every "does not die" assertion below) catches a real die');
}
{
    my ($ret, $out, $err) = _capture_streams(sub {
        print STDOUT "META-OUT-PROBE\n";
        print STDERR "META-ERR-PROBE\n";
        return (1);
    });
    ok(($out =~ /META-OUT-PROBE/) && ($err =~ /META-ERR-PROBE/),
       'meta-self-test: the file-redirect stream capture (used for the require "no output" check) catches real STDOUT/STDERR writes');
}

# ---------------------------------------------------------------------------
# Hygiene checks on WtProfile.pm's SOURCE -- these need the file on disk but
# not a successful `require`, so they run (and report honestly) even while
# the module is entirely absent, as long as we gate on -f rather than on a
# successful load. Today the file does not exist, so this whole block is
# skipped with a clear reason -- that is correct, not a bug.
# ---------------------------------------------------------------------------
SKIP: {
    skip('WtProfile.pm does not exist on disk yet (criterion 8 / AC-1.6, AC-7.1, AC-7.3 need the file present)', 11)
        unless -f $WTPROFILE_PM;

    # AC-7.1: perl -c exits 0 and prints "syntax OK". Redirect the real
    # STDERR (where -c writes its verdict) to a temp file so we can inspect
    # it without depending on shell quoting for a path that may contain
    # spaces or non-ASCII characters.
    {
        my ($ret, $out, $err) = _capture_streams(sub {
            my $rc = system($^X, '-c', $WTPROFILE_PM);
            return ($rc);
        });
        my ($rc) = @{$ret};
        is($rc, 0, 'AC-7.1: perl -c WtProfile.pm exits 0');
        like($err, qr/syntax OK/, 'AC-7.1: perl -c WtProfile.pm reports "syntax OK"');
    }

    open(my $fh, '<:raw', $WTPROFILE_PM) or die "cannot open WtProfile.pm for source scan: $!";
    my @lines = <$fh>;
    close $fh;
    my $all_bytes = join('', @lines);

    # AC-1.6: the ccpraxis GUID literal must never appear hardcoded on a
    # non-comment line -- otherwise profile_guid() could be a stored
    # constant and AC-1.3/criterion-2 would be vacuous.
    my @literal_hits = grep { !/^\s*#/ && /f4982b7c/i } @lines;
    is(scalar(@literal_hits), 0, 'AC-1.6: no f4982b7c literal (any case) on a non-comment line of WtProfile.pm');
    # counter-fixture: the same scan, run against synthetic lines that DO
    # contain the literal on a code line and, separately, only in a comment.
    my @synth_16 = ("my \$x = 'f4982b7c';\n", "# f4982b7c mentioned only in a comment\n");
    my @synth_16_hits = grep { !/^\s*#/ && /f4982b7c/i } @synth_16;
    is(scalar(@synth_16_hits), 1,
       'counter-fixture: AC-1.6 scan fires on a non-comment line and correctly ignores a comment-only line');
    # counter-fixture: an UPPERCASE stored literal must be caught too -- a
    # case-sensitive scan is what let a stored '{F4982B7C-...}' literal
    # returned via lc($it) pass this AC undetected (redteam MAJOR-1 #2).
    my @synth_16_upper = ("my \$x = 'F4982B7C';\n");
    my @synth_16_upper_hits = grep { !/^\s*#/ && /f4982b7c/i } @synth_16_upper;
    is(scalar(@synth_16_upper_hits), 1,
       'counter-fixture: AC-1.6 scan is case-insensitive and fires on an uppercase literal too');

    # AC-7.3: no `use utf8`.
    my @utf8_hits = grep { /^\s*use\s+utf8\b/ } @lines;
    is(scalar(@utf8_hits), 0, 'AC-7.3: WtProfile.pm contains no "use utf8"');
    my @synth_utf8_hits = grep { /^\s*use\s+utf8\b/ } ("use utf8;\n");
    is(scalar(@synth_utf8_hits), 1, 'counter-fixture: the "use utf8" scan fires on a line that actually has it');

    # AC-7.3: no byte >= 0x80 anywhere in the source.
    ok(!_has_high_byte($all_bytes), 'AC-7.3: WtProfile.pm source contains no byte >= 0x80');
    ok(_has_high_byte("x" . chr(0xE9)), 'counter-fixture: the high-byte scan fires on bytes that actually have one');

    # AC-7.3: only the permitted core modules are used/required.
    my %permitted = map { $_ => 1 } qw(strict warnings Digest::SHA File::Path File::Spec JSON::PP);
    my @bad_uses;
    for my $l (@lines) {
        if ($l =~ /^\s*(?:use|require)\s+([A-Za-z0-9_:]+)/) {
            my $mod = $1;
            push @bad_uses, $mod unless $permitted{$mod};
        }
    }
    is_deeply(\@bad_uses, [], 'AC-7.3: WtProfile.pm uses/requires only strict/warnings/Digest::SHA/File::Path/File::Spec/JSON::PP');
    my @synth_use_hits;
    for my $l ("use Data::Dumper;\n", "use strict;\n") {
        if ($l =~ /^\s*(?:use|require)\s+([A-Za-z0-9_:]+)/) {
            my $mod = $1;
            push @synth_use_hits, $mod unless $permitted{$mod};
        }
    }
    is_deeply(\@synth_use_hits, ['Data::Dumper'],
              'counter-fixture: the non-core-module scan fires on "use Data::Dumper" (still forbidden) and ignores permitted "use strict"');
}

# ---------------------------------------------------------------------------
# The load itself. Guarded RUNTIME require (see file header for why it is
# not a static `use`). Captures real STDOUT/STDERR around the require so we
# can assert B15/AC-7.3's "produces no output on either stream" without
# relying on $SIG{__WARN__} alone (which would miss a stray bare `print`).
# ---------------------------------------------------------------------------
my ($load_ret, $load_stdout, $load_stderr) = _capture_streams(sub {
    my $ok = eval { require WtProfile; 1 };
    my $err = $@;
    return ($ok, $err);
});
my ($WTPROFILE_LOADED, $load_err) = @{$load_ret};

ok($WTPROFILE_LOADED, 'WtProfile.pm loads via require')
    or diag("require WtProfile failed (this is the EXPECTED failure today, before package 01 lands the module): $load_err");
is($load_stdout, '', 'AC-7.3/B15: require WtProfile produced no output on STDOUT');
is($load_stderr, '', 'AC-7.3/B15: require WtProfile produced no output on STDERR (covers "no warnings" at load time too)');

# ===========================================================================
# AC-1 -- GUID derivation
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 18) unless $WTPROFILE_LOADED;

    my $NS = '{f65ddb7e-706b-4499-8a50-40313caf510a}';

    # AC-1.1 -- Microsoft's published vector
    is(WtProfile::uuid5($NS, WtProfile::utf16le('Git')),
       '{a3464014-7f9f-5763-ace4-e15905a9d7ee}',
       'AC-1.1: uuid5(NS, utf16le("Git")) matches the Microsoft-published vector');

    # EXTERNAL, non-Microsoft vector (redteam MAJOR-1 #1): every vector
    # above appears in this spec, so a four-entry lookup table with no real
    # UUID algorithm behind it could pass all of them. This one is the
    # published RFC-4122 DNS-namespace example, verified independently
    # against Digest::SHA by hand (not copied from WtProfile.pm):
    #   uuid5(DNS namespace, 'python.org') -> {886313e1-3b8a-5372-9b90-0c9aee199e5d}
    # Note the name bytes here are plain ASCII, NOT utf16le() output -- this
    # is deliberately testing that uuid5() is a generic namespace+name SHA-1
    # v5 function agnostic to the caller's encoding choice, not something
    # that only works when fed this module's own utf16le().
    is(WtProfile::uuid5('6ba7b810-9dad-11d1-80b4-00c04fd430c8', 'python.org'),
       '{886313e1-3b8a-5372-9b90-0c9aee199e5d}',
       'AC-1.1 (external vector): uuid5(DNS namespace, "python.org") matches the published RFC-4122 example, independent of the spec');

    # AC-1.2 -- chained, Microsoft's published check value
    is(WtProfile::uuid5('{a3464014-7f9f-5763-ace4-e15905a9d7ee}', WtProfile::utf16le('Git Bash')),
       '{2ece5bfe-50ed-5f3a-ab87-5cd4baafed2b}',
       'AC-1.2: uuid5(prev, utf16le("Git Bash")) matches the Microsoft-published check value');

    # AC-1.3 -- the ccpraxis chain
    my $ns_app = WtProfile::uuid5($NS, WtProfile::utf16le('ccpraxis'));
    is($ns_app, '{0c9982f6-3ac2-5617-8fa9-cb03567ee71d}',
       'AC-1.3: intermediate uuid5(NS, utf16le("ccpraxis"))');
    is(WtProfile::profile_guid(), '{f4982b7c-7770-5eb7-bcf3-074fbbfd0b31}',
       'AC-1.3: profile_guid() derives to the pinned ccpraxis GUID');

    # AC-1.4 -- utf16le shape
    is(WtProfile::utf16le('Git'), "G\0i\0t\0",
       'AC-1.4: utf16le("Git") is three low-byte-first UTF-16LE character pairs');
    is(length(WtProfile::utf16le('claude-sandbox')), 2 * length('claude-sandbox'),
       'AC-1.4: length(utf16le($s)) == 2 * length($s)');
    # AC-1.4 (redteam MAJOR-1 #3): every fixture above is pure ASCII, so a
    # wrong implementation appending a bare NUL per character ($_ . "\0")
    # instead of pack('v', ord $_) would pass all of them. Assert a
    # character above 0x7F, built from an explicit byte value so this test
    # file stays ASCII.
    is(WtProfile::utf16le(chr(0xE9)), "\xE9\x00",
       'AC-1.4: utf16le(chr(0xE9)) is pack(\'v\', 0xE9), not a NUL-appended byte');

    # Contract (spec section 2.2), not a numbered AC but stated explicitly:
    # utf16le('') eq '', utf16le(undef) is undef.
    is(WtProfile::utf16le(''), '', 'contract sec-2.2: utf16le("") returns ""');
    is(WtProfile::utf16le(undef), undef, 'contract sec-2.2: utf16le(undef) returns undef');

    # AC-1.5 -- namespace input tolerance
    my $braced   = WtProfile::uuid5($NS, WtProfile::utf16le('Git'));
    my $unbraced = WtProfile::uuid5('f65ddb7e-706b-4499-8a50-40313caf510a', WtProfile::utf16le('Git'));
    my $bare_hex = WtProfile::uuid5('f65ddb7e706b44998a5040313caf510a', WtProfile::utf16le('Git'));
    my $upper    = WtProfile::uuid5('{F65DDB7E-706B-4499-8A50-40313CAF510A}', WtProfile::utf16le('Git'));
    is($unbraced, $braced, 'AC-1.5: unbraced-hyphenated NS form matches the braced form');
    is($bare_hex, $braced, 'AC-1.5: bare 32-hex NS form matches the braced form');
    is($upper, $braced, 'AC-1.5: uppercase NS input still yields the same (lowercase-output) GUID');

    # AC-1.5 -- quiet rejection of garbage (also B4)
    my @w;
    my $r1 = do { local $SIG{__WARN__} = sub { push @w, @_ }; WtProfile::uuid5(undef, WtProfile::utf16le('Git')) };
    my $r2 = do { local $SIG{__WARN__} = sub { push @w, @_ }; WtProfile::uuid5('nonsense', WtProfile::utf16le('Git')) };
    my $r3 = do { local $SIG{__WARN__} = sub { push @w, @_ }; WtProfile::uuid5('{f65ddb7e-706b}', WtProfile::utf16le('Git')) };
    my $r4 = do { local $SIG{__WARN__} = sub { push @w, @_ }; WtProfile::uuid5($NS, undef) };
    is($r1, undef, 'AC-1.5/B4: uuid5(undef, name) returns undef');
    is($r2, undef, 'AC-1.5/B4: uuid5("nonsense", name) returns undef');
    is($r3, undef, 'AC-1.5/B4: uuid5(truncated-hex, name) returns undef');
    is($r4, undef, 'AC-1.5/B4: uuid5(NS, undef) returns undef');
    is(scalar(@w), 0, 'AC-1.5/B4: all four quiet-rejection calls produced no warnings');
}

# ===========================================================================
# AC-2 -- rendered JSON
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 23) unless $WTPROFILE_LOADED;

    my $json_bytes = WtProfile::fragment_json();
    my $decoded = eval { decode_json($json_bytes) };
    ok(!$@, 'AC-2.1: fragment_json() parses as JSON without error') or diag("decode_json error: $@");
    is(ref($decoded), 'HASH', 'AC-2.1: decoded fragment is a hashref');
    is_deeply([sort keys %$decoded], ['profiles'], 'AC-2.1: decoded top-level key set is exactly (profiles)');
    is(ref($decoded->{profiles}), 'ARRAY', 'AC-2.1: profiles value is an arrayref');
    is(scalar(@{$decoded->{profiles}}), 1, 'AC-2.1: profiles array has exactly one element');

    my $profile = $decoded->{profiles}[0];
    is_deeply([sort keys %$profile], ['guid', 'name', 'scrollbarState'],
              'AC-2.2: the profile object key set is exactly name/guid/scrollbarState');

    is(WtProfile::profile_name(), 'claude-sandbox', 'contract sec-2.2: profile_name() is "claude-sandbox"');
    is($profile->{name}, 'claude-sandbox', 'AC-2.3: profile name is "claude-sandbox"');
    is($profile->{name}, WtProfile::profile_name(), 'AC-2.3: profile name matches profile_name()');
    is($profile->{guid}, WtProfile::profile_guid(), 'AC-2.3: profile guid matches profile_guid()');
    is($profile->{scrollbarState}, 'hidden', 'AC-2.3: scrollbarState is "hidden"');

    for my $forbidden (qw(font colorScheme padding opacity icon commandline)) {
        ok(!exists $profile->{$forbidden}, "AC-2.4: forbidden key '$forbidden' is absent from the profile");
    }
    # counter-fixture: the same exists() check, against a profile that DOES
    # carry a forbidden key.
    my %bad_profile = (%$profile, font => 'Cascadia Code');
    ok(exists $bad_profile{font}, 'counter-fixture: exists() fires when a forbidden key is really present');

    my $pinned = "{\n  \"profiles\": [\n    {\n      \"name\": \"claude-sandbox\",\n"
               . "      \"guid\": \"{f4982b7c-7770-5eb7-bcf3-074fbbfd0b31}\",\n"
               . "      \"scrollbarState\": \"hidden\"\n    }\n  ]\n}\n";
    is($json_bytes, $pinned, 'AC-2.5: fragment_json() equals the pinned sec-2.3 literal byte-for-byte');
    unlike($json_bytes, qr/\r/, 'AC-2.5: fragment_json() contains no carriage return');
    ok(!_has_high_byte($json_bytes), 'AC-2.5: fragment_json() contains no byte >= 0x80');
    # counter-fixtures for the two negative checks immediately above
    like("a\rb", qr/\r/, 'counter-fixture: the \r detector fires on a string that actually has one');
    ok(_has_high_byte("a" . chr(0xE9) . "b"), 'counter-fixture: the high-byte detector fires on a string that actually has one');
}

# ===========================================================================
# AC-3 -- idempotent write under an injected root
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 33) unless $WTPROFILE_LOADED;

    # contract sec-2.2: fragment_path(undef) / fragment_path('') return undef,
    # no I/O.
    is(WtProfile::fragment_path(undef), undef, 'contract sec-2.2: fragment_path(undef) returns undef');
    is(WtProfile::fragment_path(''), undef, 'contract sec-2.2: fragment_path("") returns undef');

    # AC-3.1 + AC-3.2(b) -- missing intermediate directories
    my $root1 = tempdir(CLEANUP => 1);
    my $deep  = File::Spec->catdir($root1, 'a', 'b', 'c');
    my $res1  = WtProfile::ensure_fragment($deep, { settings_path => undef });
    is($res1->{ok}, 1, 'AC-3.1: ensure_fragment(deep missing path) returns ok=1');
    is($res1->{action}, 'wrote', 'AC-3.1: first write on missing intermediate dirs reports action="wrote"');
    my $created_path = WtProfile::fragment_path($deep);
    ok(-f $created_path, 'AC-3.1: the fragment file exists on disk after ensure_fragment');
    my (undef, $created_dir, $created_base) = File::Spec->splitpath($created_path);
    is($created_base, 'claude-sandbox.json', 'AC-3.2: created file basename is "claude-sandbox.json"');
    like($created_dir, qr/ccpraxis/, 'AC-3.2: created file sits inside a directory named "ccpraxis"');

    # AC-3.2(a) -- the fragment_path formula, independent of any write
    my $root2 = tempdir(CLEANUP => 1);
    is(WtProfile::fragment_path($root2), File::Spec->catfile($root2, 'ccpraxis', 'claude-sandbox.json'),
       'AC-3.2: fragment_path($root) eq File::Spec->catfile($root, "ccpraxis", "claude-sandbox.json")');

    # AC-3.3 -- idempotence, asserted by mtime
    my $root3 = tempdir(CLEANUP => 1);
    my $res3a = WtProfile::ensure_fragment($root3, { settings_path => undef });
    is($res3a->{ok}, 1, 'AC-3.3: first ensure_fragment call on a fresh root succeeds');
    my $path3 = WtProfile::fragment_path($root3);
    my $t = time() - 10_000;
    utime($t, $t, $path3) or die "test fixture: utime failed for AC-3.3: $!";
    my $mtime_before = (stat($path3))[9];
    is($mtime_before, $t, 'AC-3.3 fixture: utime set mtime to the distinct past value (sanity check on this filesystem)');
    my $res3b = WtProfile::ensure_fragment($root3, { settings_path => undef });
    is($res3b->{ok}, 1, 'AC-3.3: second ensure_fragment call returns ok=1');
    is($res3b->{action}, 'unchanged', 'AC-3.3: second call with identical content reports action="unchanged"');
    my $mtime_after = (stat($path3))[9];
    is($mtime_after, $t, 'AC-3.3: mtime is unchanged after the second call -- no rewrite happened');
    # counter-fixture: prove mtime on this filesystem really DOES move when
    # touched, so the equality assertion above is not vacuously true.
    utime(undef, undef, $path3) or die "test fixture: utime(touch) failed for AC-3.3 counter-fixture: $!";
    my $mtime_touched = (stat($path3))[9];
    isnt($mtime_touched, $t, 'counter-fixture: utime(now) on the same file actually moves its mtime away from $t');

    # AC-3.4 -- drift self-heals
    my $root4 = tempdir(CLEANUP => 1);
    WtProfile::ensure_fragment($root4, { settings_path => undef });
    my $path4 = WtProfile::fragment_path($root4);
    open(my $gfh, '>:raw', $path4) or die "test fixture: cannot write garbage for AC-3.4: $!";
    print $gfh "garbage\n";
    close $gfh;
    my $res4 = WtProfile::ensure_fragment($root4, { settings_path => undef });
    is($res4->{ok}, 1, 'AC-3.4: ensure_fragment on drifted content returns ok=1');
    is($res4->{action}, 'wrote', 'AC-3.4: drifted content triggers action="wrote" (self-heal)');
    my $bytes4 = _slurp_raw($path4);
    is($bytes4, WtProfile::fragment_json(), 'AC-3.4: after self-heal, on-disk bytes equal fragment_json() again');

    # AC-3.4 (redteam MAJOR-1 #4): drift the file to SAME-SIZE, DIFFERENT
    # CONTENT. "garbage\n" above is a different LENGTH than fragment_json(),
    # so a wrong implementation comparing only (-s $path) == length($wanted)
    # would pass both AC-3.3 (equal size, equal content) and the "garbage"
    # drift (unequal size) without ever doing a real byte comparison. This
    # fixture is the one case that distinguishes "compares sizes" from
    # "compares bytes": same length as fragment_json(), one word altered.
    my $root4b = tempdir(CLEANUP => 1);
    WtProfile::ensure_fragment($root4b, { settings_path => undef });
    my $path4b = WtProfile::fragment_path($root4b);
    my $wanted4b = WtProfile::fragment_json();
    (my $same_size_tampered = $wanted4b) =~ s/hidden/HIDDEN/;
    is(length($same_size_tampered), length($wanted4b),
       'AC-3.4 fixture: the same-size tamper really is the same length as fragment_json() (sanity check on the fixture itself)');
    open(my $gfh2, '>:raw', $path4b) or die "test fixture: cannot write same-size tampered content for AC-3.4: $!";
    print $gfh2 $same_size_tampered;
    close $gfh2;
    my $res4b = WtProfile::ensure_fragment($root4b, { settings_path => undef });
    is($res4b->{ok}, 1, 'AC-3.4 (same-size drift): ensure_fragment on same-size-different-content returns ok=1');
    is($res4b->{action}, 'wrote', 'AC-3.4 (same-size drift): same-size-different-content triggers action="wrote", not "unchanged"');
    my $bytes4b = _slurp_raw($path4b);
    is($bytes4b, WtProfile::fragment_json(), 'AC-3.4 (same-size drift): after self-heal, on-disk bytes equal fragment_json() again');

    # AC-3.5 -- success returns have exactly ok/action/path
    for my $case (
        [$res1, $deep,  'wrote (AC-3.1)'],
        [$res3b, $root3, 'unchanged (AC-3.3)'],
        [$res4, $root4, 'wrote (AC-3.4)'],
    ) {
        my ($res, $root_for_case, $label) = @$case;
        is_deeply([sort keys %$res], ['action', 'appearance', 'appearance_reason', 'ok', 'path'],
                  "AC-3.5: success return ($label) has exactly the keys action/appearance/appearance_reason/ok/path");
        is($res->{path}, WtProfile::fragment_path($root_for_case),
           "AC-3.5: success return ($label) path matches fragment_path(root)");
        is($res->{appearance}, 'fallback', "AC-3.5: success return ($label) appearance=\"fallback\" (settings_path => undef)");
        is($res->{appearance_reason}, 'settings_not_found', "AC-3.5: success return ($label) appearance_reason=\"settings_not_found\"");
    }
}

# ===========================================================================
# AC-4 -- bytes on disk
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 12) unless $WTPROFILE_LOADED;

    my $root = tempdir(CLEANUP => 1);
    WtProfile::ensure_fragment($root, { settings_path => undef });
    my $path  = WtProfile::fragment_path($root);
    my $bytes = _slurp_raw($path);

    # AC-4.1
    is($bytes, WtProfile::fragment_json(), 'AC-4.1: bytes read back with binmode equal fragment_json()');

    # AC-4.2
    unlike($bytes, qr/\r/, 'AC-4.2: on-disk bytes contain no carriage return (not CRLF)');
    ok(!_has_high_byte($bytes), 'AC-4.2: every on-disk byte is < 0x80');
    ok(!_has_utf8_bom($bytes), 'AC-4.2: on-disk bytes do not start with a UTF-8 BOM (EF BB BF)');
    ok(!_has_utf16_bom($bytes), 'AC-4.2: on-disk bytes do not start with a UTF-16 BOM (FF FE or FE FF)');
    is(substr($bytes, 0, 1), "\x7B", 'AC-4.2: first on-disk byte is 0x7B ("{")');

    # counter-fixtures for the four negative byte-shape checks above
    like("a\rb", qr/\r/, 'counter-fixture: \r detector fires on a string that actually has one');
    ok(_has_high_byte("a" . chr(0xE9)), 'counter-fixture: high-byte detector fires on a string that actually has one');
    ok(_has_utf8_bom("\xEF\xBB\xBFhello"), 'counter-fixture: UTF-8 BOM detector fires on a real UTF-8 BOM');
    ok(_has_utf16_bom("\xFF\xFEh\x00"), 'counter-fixture: UTF-16LE BOM detector fires on a real UTF-16LE BOM');
    ok(_has_utf16_bom("\xFE\xFF\x00h"), 'counter-fixture: UTF-16BE BOM detector fires on a real UTF-16BE BOM');

    # AC-4.3
    is(-s $path, length($bytes), 'AC-4.3: on-disk size equals length(fragment_json()) -- no line-ending translation');
}

# ===========================================================================
# AC-5 -- failure is structured, silent and non-fatal
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 38) unless $WTPROFILE_LOADED;

    my @failure_results;

    # AC-5.1 -- undef / empty root. Each call is wrapped in BOTH the
    # $SIG{__WARN__} capture (below) AND the real stream-redirect capture
    # from _capture_streams (redteam MAJOR-2): $SIG{__WARN__} alone is deaf
    # to a bare `print STDOUT`/`print STDERR`, which is exactly the failure
    # mode a debuggability one-liner would introduce and the suite would
    # otherwise never catch.
    for my $case ([undef, 'undef'], ['', 'empty string']) {
        my ($root_arg, $label) = @$case;
        my ($ret, $out, $err) = _capture_streams(sub {
            my @w;
            my $res;
            my $eval_ok = eval {
                local $SIG{__WARN__} = sub { push @w, @_ };
                $res = WtProfile::ensure_fragment($root_arg, { settings_path => undef });
                1;
            };
            return ($eval_ok, $res, \@w, $@);
        });
        my ($eval_ok, $res, $warns, $die_err) = @{$ret};
        ok($eval_ok, "AC-5.1/AC-5.4: ensure_fragment($label) does not die") or diag("died: $die_err");
        is($res->{ok}, 0, "AC-5.1: ensure_fragment($label) returns ok=0");
        is($res->{action}, 'failed', "AC-5.1: ensure_fragment($label) action=\"failed\"");
        is($res->{reason}, 'root_missing', "AC-5.1: ensure_fragment($label) reason=\"root_missing\"");
        ok(defined $res->{error}, "AC-5.1: ensure_fragment($label) error is defined");
        is(scalar(@$warns), 0, "AC-5.1/AC-5.4: ensure_fragment($label) warns nothing");
        is($out, '', "AC-5.4: ensure_fragment($label) produced no STDOUT output");
        is($err, '', "AC-5.4: ensure_fragment($label) produced no STDERR output");
        push @failure_results, $res;
    }

    # AC-5.2 -- unwritable root: a FILE occupies a path component (portable;
    # avoids chmod, which is a no-op for root in a container and meaningless
    # on Windows).
    my ($fh5, $file5) = tempfile(UNLINK => 1);
    close $fh5;
    my $bad_dir = File::Spec->catdir($file5, 'sub');
    my ($ret2, $out2, $err2) = _capture_streams(sub {
        my @w2;
        my $res5;
        my $eval_ok2 = eval {
            local $SIG{__WARN__} = sub { push @w2, @_ };
            $res5 = WtProfile::ensure_fragment($bad_dir, { settings_path => undef });
            1;
        };
        return ($eval_ok2, $res5, \@w2, $@);
    });
    my ($eval_ok2, $res5, $warns2, $die_err2) = @{$ret2};
    ok($eval_ok2, 'AC-5.2/AC-5.4: ensure_fragment(file-occupied path component) does not die') or diag("died: $die_err2");
    is($res5->{ok}, 0, 'AC-5.2: ensure_fragment(file-occupied path) returns ok=0');
    is($res5->{action}, 'failed', 'AC-5.2: action="failed"');
    is($res5->{reason}, 'mkdir_failed', 'AC-5.2: reason="mkdir_failed"');
    ok(defined($res5->{error}) && length($res5->{error}), 'AC-5.2: error is defined and non-empty');
    is(scalar(@$warns2), 0, 'AC-5.2/AC-5.4: ensure_fragment(file-occupied path) warns nothing');
    is($out2, '', 'AC-5.4: ensure_fragment(file-occupied path) produced no STDOUT output');
    is($err2, '', 'AC-5.4: ensure_fragment(file-occupied path) produced no STDERR output');
    push @failure_results, $res5;

    # AC-5.3 -- unwritable file: the target path is itself a directory
    my $root6 = tempdir(CLEANUP => 1);
    my $app_dir6 = File::Spec->catdir($root6, 'ccpraxis');
    mkdir($app_dir6) or die "test fixture: mkdir failed for AC-5.3: $!";
    my $fragment_as_dir6 = File::Spec->catdir($app_dir6, 'claude-sandbox.json');
    mkdir($fragment_as_dir6) or die "test fixture: mkdir(fragment-as-dir) failed for AC-5.3: $!";
    my ($ret3, $out3, $err3) = _capture_streams(sub {
        my @w3;
        my $res6;
        my $eval_ok3 = eval {
            local $SIG{__WARN__} = sub { push @w3, @_ };
            $res6 = WtProfile::ensure_fragment($root6, { settings_path => undef });
            1;
        };
        return ($eval_ok3, $res6, \@w3, $@);
    });
    my ($eval_ok3, $res6, $warns3, $die_err3) = @{$ret3};
    ok($eval_ok3, 'AC-5.3/AC-5.4: ensure_fragment(fragment path is a directory) does not die') or diag("died: $die_err3");
    is($res6->{ok}, 0, 'AC-5.3: ensure_fragment(fragment path is a directory) returns ok=0');
    is($res6->{action}, 'failed', 'AC-5.3: action="failed"');
    is($res6->{reason}, 'write_failed', 'AC-5.3: reason="write_failed"');
    ok(defined $res6->{error}, 'AC-5.3: error is defined');
    is(scalar(@$warns3), 0, 'AC-5.3/AC-5.4: ensure_fragment(fragment path is a directory) warns nothing');
    is($out3, '', 'AC-5.4: ensure_fragment(fragment path is a directory) produced no STDOUT output');
    is($err3, '', 'AC-5.4: ensure_fragment(fragment path is a directory) produced no STDERR output');
    push @failure_results, $res6;

    # AC-5.4 -- the happy path too, not just failures: one successful
    # ensure_fragment() call under the same stream capture.
    my $root7 = tempdir(CLEANUP => 1);
    my ($ret4, $out4, $err4) = _capture_streams(sub {
        my $res7 = WtProfile::ensure_fragment($root7, { settings_path => undef });
        return ($res7);
    });
    my ($res7) = @{$ret4};
    is($res7->{ok}, 1, 'AC-5.4 (success path): ensure_fragment(fresh root) returns ok=1 under stream capture');
    is($out4, '', 'AC-5.4: ensure_fragment(fresh root, success) produced no STDOUT output');
    is($err4, '', 'AC-5.4: ensure_fragment(fresh root, success) produced no STDERR output');

    # AC-5.5 -- every failure's reason is a member of the closed set
    my %closed = map { $_ => 1 } qw(root_missing mkdir_failed write_failed);
    for my $r (@failure_results) {
        ok($closed{ $r->{reason} }, "AC-5.5: reason '$r->{reason}' is a member of the closed reason set");
    }
}

# ===========================================================================
# AC-6 -- the real-root resolver
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 34) unless $WTPROFILE_LOADED;

    # AC-6.1 -- non-ASCII LOCALAPPDATA, byte-for-byte. The e-acute is built
    # from explicit bytes (chr(0xC3).chr(0xA9), i.e. UTF-8 "\xC3\xA9") so this
    # test FILE stays pure ASCII and source-encoding cannot confound it.
    my $le = 'C:\Users\Andr' . chr(0xC3) . chr(0xA9) . '\AppData\Local';
    my $r1 = WtProfile::fragment_root({ LOCALAPPDATA => $le });
    is($r1->{ok}, 1, 'AC-6.1: ok=1 for non-ASCII LOCALAPPDATA');
    is($r1->{root}, $le . '\Microsoft\Windows Terminal\Fragments',
       'AC-6.1: non-ASCII bytes carried through byte-for-byte with the suffix appended');

    # AC-5.4/B15 (redteam MAJOR-2): fragment_root() itself was never wrapped
    # in the real stream-redirect capture either -- only ensure_fragment
    # calls were named in the finding, but the same "$SIG{__WARN__} is deaf
    # to a bare print" gap applies here too.
    my ($r1_ret, $r1_out, $r1_err) = _capture_streams(sub {
        my $r = WtProfile::fragment_root({ LOCALAPPDATA => $le });
        return ($r);
    });
    my ($r1_captured) = @{$r1_ret};
    is($r1_captured->{ok}, 1, 'AC-5.4 (stream capture): fragment_root(non-ASCII LOCALAPPDATA) returns ok=1 under stream capture');
    is($r1_out, '', 'AC-5.4: fragment_root(non-ASCII LOCALAPPDATA) produced no STDOUT output');
    is($r1_err, '', 'AC-5.4: fragment_root(non-ASCII LOCALAPPDATA) produced no STDERR output');

    # AC-6.2 -- ASCII control case, and no File::Spec-style forward slash
    my $ascii = 'C:\Users\x\AppData\Local';
    my $r2 = WtProfile::fragment_root({ LOCALAPPDATA => $ascii });
    is($r2->{root}, 'C:\Users\x\AppData\Local\Microsoft\Windows Terminal\Fragments',
       'AC-6.2: ASCII control-case root is exactly the expected literal join');
    unlike($r2->{root}, qr{/}, 'AC-6.2: resolved root contains no forward slash (resolver must not use File::Spec)');
    like('a/b', qr{/}, 'counter-fixture: the no-forward-slash check fires on a string that actually has one');

    # AC-6.3 -- a trailing separator is absorbed, no doubled separator
    my $r3a = WtProfile::fragment_root({ LOCALAPPDATA => 'C:\Users\x\AppData\Local\\' });
    my $r3b = WtProfile::fragment_root({ LOCALAPPDATA => 'C:\Users\x\AppData\Local/' });
    is($r3a->{root}, $r2->{root}, 'AC-6.3: trailing backslash is absorbed, same root as no trailing separator');
    is($r3b->{root}, $r2->{root}, 'AC-6.3: trailing forward slash is absorbed, same root as no trailing separator');
    unlike($r3a->{root}, qr{\\\\}, 'AC-6.3: no doubled backslash in the resolved root');
    unlike($r3a->{root}, qr{\\/}, 'AC-6.3: no backslash-then-slash in the resolved root');
    like("a\\\\b", qr{\\\\}, 'counter-fixture: the doubled-backslash check fires on a string that actually has one');
    like("a\\/b", qr{\\/}, 'counter-fixture: the backslash-then-slash check fires on a string that actually has one');

    # AC-6.4 -- absent / undef / empty / whitespace-only LOCALAPPDATA
    for my $case (
        ['{}', {}],
        ['undef', { LOCALAPPDATA => undef }],
        ['empty string', { LOCALAPPDATA => '' }],
        ['whitespace only', { LOCALAPPDATA => '   ' }],
    ) {
        my ($label, $env) = @$case;
        my @w;
        my $res = do { local $SIG{__WARN__} = sub { push @w, @_ }; WtProfile::fragment_root($env) };
        is($res->{ok}, 0, "AC-6.4: fragment_root($label) returns ok=0");
        is($res->{reason}, 'no_localappdata', "AC-6.4: fragment_root($label) reason=\"no_localappdata\"");
        ok(!exists $res->{root}, "AC-6.4: fragment_root($label) result has no 'root' key");
        is(scalar(@w), 0, "AC-6.4: fragment_root($label) warns nothing");
    }

    # AC-6.5 -- the %ENV default, isolated to this tight scope
    {
        local %ENV = (LOCALAPPDATA => 'C:\x');
        my $r5a = WtProfile::fragment_root();
        is($r5a->{ok}, 1, 'AC-6.5: fragment_root() with no argument reads %ENV and succeeds when LOCALAPPDATA is set');
        is($r5a->{root}, 'C:\x\Microsoft\Windows Terminal\Fragments',
           'AC-6.5: fragment_root() with no argument derives the root from %ENV');
    }
    {
        local %ENV = ();
        my $r5b = WtProfile::fragment_root();
        is($r5b->{ok}, 0, 'AC-6.5: fragment_root() with no argument and empty %ENV returns ok=0');
        is($r5b->{reason}, 'no_localappdata', 'AC-6.5: fragment_root() with no argument and empty %ENV reason="no_localappdata"');
    }
}

done_testing();
