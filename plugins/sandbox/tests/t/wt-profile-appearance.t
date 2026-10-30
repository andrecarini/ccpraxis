#!/usr/bin/env perl
# platform: host
# ORACLE for blueprint sandbox-session-ux, package 04-wt-appearance, spec
# specs/04-wt-appearance-spec.md (AC-A1..AC-A19), Decisions 9, 15 and 17.
# Written BLIND to any appearance-copying implementation -- straight from the
# spec's sections 2.1-2.6 and observable behaviors B1..B11 -- so this file is
# an oracle, not an echo of whatever the implementer eventually writes. Do
# not weaken an assertion here to make a future implementation's life
# easier; the package ledger records tests as immutable once implementation
# starts.
#
# EVERY settings.json FIXTURE BELOW IS SYNTHETIC, written by this file into
# File::Temp::tempdir(CLEANUP => 1), using made-up GUIDs and made-up profile
# names. Nothing here ever reads, names, or copies the operator's real
# settings.json or the real %LOCALAPPDATA% (Decision 15). Every
# ensure_fragment() call passes an explicit { settings_path => ... } opts
# hash, except the one call that deliberately empties %ENV to exercise the
# default-source resolution path with no fixture at all.
#
# TODAY'S EXPECTED STATE: the appearance-copying behavior (settings
# candidate resolution, the tolerant JSONC reader, the defaults/profile
# merge, and the widened fragment renderer) does not exist yet. Assertions
# below are EXPECTED to fail for that reason -- that is the correct state
# for this file today, not a bug in it. Calls to functions that do not exist
# yet are routed through small eval-wrapping helpers (_call_hashref/_call_
# str/_call_list below) precisely so that "the function is not defined yet"
# surfaces as ordinary failing assertions rather than as an uncaught die
# that would abort the rest of this file's plan.
#
# HARD CONSTRAINTS: this file spawns no wt.exe, no launcher.pl, needs no
# container, no network, and no `prove` (there is no TAP::Harness on this
# host). It runs standalone via `perl <file>`.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use File::Temp qw(tempdir tempfile);
use File::Spec;
use JSON::PP qw(decode_json);

my $SCRIPTS      = "$Bin/../../scripts";
my $WTPROFILE_PM = "$SCRIPTS/WtProfile.pm";

# ---------------------------------------------------------------------------
# Byte-level helpers (test-owned detectors, not a sketch of the
# implementation) -- same techniques used by the sibling fragment oracle.
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

sub _write_bytes {
    my ($path, $bytes) = @_;
    open(my $fh, '>:raw', $path) or die "test fixture: cannot write '$path': $!";
    print $fh $bytes;
    close $fh;
    return $path;
}

# Redirects the REAL stdout/stderr file descriptors (via File::Temp, never an
# in-memory scalar) around a coderef, and returns what it printed.
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

# _call_hashref/_call_str/_call_list -- eval-wrapping shims around calls to
# functions this spec introduces (default_appearance, settings_candidates)
# that do not exist on disk yet. A call to a genuinely undefined sub dies
# with "Undefined subroutine ... called"; without this wrapper that die
# would be uncaught and would abort this whole file before done_testing()
# ever runs. Once the real functions exist, these wrappers are inert -- they
# neither swallow nor alter a real return value.
sub _call_hashref {
    my ($code) = @_;
    my $r = eval { $code->() };
    return (ref($r) eq 'HASH') ? $r : {};
}

sub _call_str {
    my ($code) = @_;
    my $r = eval { $code->() };
    return defined($r) ? $r : '';
}

sub _call_list {
    my ($code) = @_;
    my @r = eval { $code->() };
    return @r;
}

# ---------------------------------------------------------------------------
# Shared fixture builders.
# ---------------------------------------------------------------------------

# The "canonical" fixture from AC-A1: profiles.defaults sets colorScheme and
# font.features, the matched profile (by GUID, stated in a different letter
# case than the list entry) sets font face/size/weight. Carries a line
# comment, a block comment, trailing commas in an object and an array, and a
# "$help" URL value containing "//". Single-quoted heredoc throughout so
# Perl never interpolates "$help" as a variable.
sub _canonical_fixture_json {
    return <<'JSON';
{
  // top-of-file comment, must not break parsing
  "$help": "https://example.invalid/x",
  "defaultProfile": "{aabbccdd-1122-4000-8000-0000000000ee}",
  "profiles": {
    "defaults": {
      "colorScheme": "One Half Dark",
      "font": { "features": { "ss01": 1 }, },
    },
    "list": [
      {
        "name": "Made Up Profile",
        "guid": "{AABBCCDD-1122-4000-8000-0000000000EE}",
        "font": { "face": "Cascadia Code", "size": 10, "weight": "semi-light" },
      },
    ],
  },
  /* trailing
     block comment */
}
JSON
}

# A11's non-appearance-only edit: same profile/defaults, one added
# non-appearance key and one added comment, so the resolved appearance is
# byte-identical to the canonical fixture's.
sub _canonical_fixture_json_with_copyonselect {
    return <<'JSON';
{
  // top-of-file comment, must not break parsing
  // a second, unrelated comment added later
  "$help": "https://example.invalid/x",
  "copyOnSelect": true,
  "defaultProfile": "{aabbccdd-1122-4000-8000-0000000000ee}",
  "profiles": {
    "defaults": {
      "colorScheme": "One Half Dark",
      "font": { "features": { "ss01": 1 }, },
    },
    "list": [
      {
        "name": "Made Up Profile",
        "guid": "{AABBCCDD-1122-4000-8000-0000000000EE}",
        "font": { "face": "Cascadia Code", "size": 10, "weight": "semi-light" },
      },
    ],
  },
  /* trailing
     block comment */
}
JSON
}

# A12's appearance-only edit: font.size 10 -> 11, otherwise identical.
sub _canonical_fixture_json_size11 {
    return <<'JSON';
{
  // top-of-file comment, must not break parsing
  "$help": "https://example.invalid/x",
  "defaultProfile": "{aabbccdd-1122-4000-8000-0000000000ee}",
  "profiles": {
    "defaults": {
      "colorScheme": "One Half Dark",
      "font": { "features": { "ss01": 1 }, },
    },
    "list": [
      {
        "name": "Made Up Profile",
        "guid": "{AABBCCDD-1122-4000-8000-0000000000EE}",
        "font": { "face": "Cascadia Code", "size": 11, "weight": "semi-light" },
      },
    ],
  },
  /* trailing
     block comment */
}
JSON
}

sub _write_canonical_fixture {
    my ($dir) = @_;
    return _write_bytes(File::Spec->catfile($dir, 'settings.json'), _canonical_fixture_json());
}

my %EXPECTED_CANONICAL_FONT = (face => 'Cascadia Code', size => 10, weight => 'semi-light', features => { ss01 => 1 });

# ---------------------------------------------------------------------------
# The load itself. Guarded RUNTIME require (WtProfile.pm already exists as
# of package 01-wt-profile-fragment; a static `use` would still be wrong
# house style here). Captures real STDOUT/STDERR around the require.
# ---------------------------------------------------------------------------
my ($load_ret, $load_stdout, $load_stderr) = _capture_streams(sub {
    my $ok = eval { require WtProfile; 1 };
    my $err = $@;
    return ($ok, $err);
});
my ($WTPROFILE_LOADED, $load_err) = @{$load_ret};

ok($WTPROFILE_LOADED, 'WtProfile.pm loads via require')
    or diag("require WtProfile failed: $load_err");
is($load_stdout, '', 'require WtProfile produced no output on STDOUT');
is($load_stderr, '', 'require WtProfile produced no output on STDERR');

sub _base_literal {
    my $name = WtProfile::profile_name();
    my $guid = WtProfile::profile_guid();
    return "{\n  \"profiles\": [\n    {\n      \"name\": \"$name\",\n      \"guid\": \"$guid\",\n"
         . "      \"scrollbarState\": \"hidden\"\n    }\n  ]\n}\n";
}

# ===========================================================================
# AC-A1 -- canonical fixture, end to end through ensure_fragment
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 10) unless $WTPROFILE_LOADED;

    my $dir  = tempdir(CLEANUP => 1);
    my $path = _write_canonical_fixture($dir);
    my $root = tempdir(CLEANUP => 1);

    my $res = _call_hashref(sub { WtProfile::ensure_fragment($root, { settings_path => $path }) });
    is($res->{ok}, 1, 'A1: ensure_fragment(canonical fixture) returns ok=1');
    is($res->{action}, 'wrote', 'A1: first call on a fresh root reports action="wrote"');
    is($res->{appearance}, 'copied', 'A1: appearance="copied" for a resolved default profile');

    my $bytes   = defined($res->{path}) ? _slurp_raw($res->{path}) : '';
    my $decoded = eval { decode_json($bytes) };
    ok(!$@, 'A1: fragment bytes decode as JSON') or diag("decode error: $@ / bytes: $bytes");

    my $profile = (ref($decoded) eq 'HASH' && ref($decoded->{profiles}) eq 'ARRAY') ? $decoded->{profiles}[0] : undef;
    ok(defined($profile), 'A1: decoded fragment has a profiles[0] entry');
    is($profile->{name}, WtProfile::profile_name(), 'A1: profile name equals profile_name()');
    is($profile->{guid}, WtProfile::profile_guid(), 'A1: profile guid equals profile_guid()');
    is($profile->{scrollbarState}, 'hidden', 'A1: scrollbarState is "hidden"');
    is($profile->{colorScheme}, 'One Half Dark', 'A1: colorScheme is copied from profiles.defaults');
    is_deeply($profile->{font}, \%EXPECTED_CANONICAL_FONT,
              'A1: font merges the matched profile\'s face/size/weight with defaults.font.features');
}

# ===========================================================================
# AC-A2 -- fragment_json() with appearance keys, pinned byte for byte
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 1) unless $WTPROFILE_LOADED;

    my $app = { font => { face => 'Cascadia Code', size => 10, weight => 'semi-light' }, colorScheme => 'One Half Dark' };
    my $bytes = _call_str(sub { WtProfile::fragment_json($app) });
    my $guid  = WtProfile::profile_guid();
    my $expected = "{\n  \"profiles\": [\n    {\n      \"name\": \"claude-sandbox\",\n      \"guid\": \"$guid\",\n"
                 . "      \"scrollbarState\": \"hidden\",\n"
                 . "      \"font\": {\"face\":\"Cascadia Code\",\"size\":10,\"weight\":\"semi-light\"},\n"
                 . "      \"colorScheme\": \"One Half Dark\"\n    }\n  ]\n}\n";
    is($bytes, $expected, 'A2: fragment_json(appearance) equals the sec-2.5 pinned example byte for byte');
}

# ===========================================================================
# AC-A3 -- profile overrides defaults, per top-level key and per font sub-key
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 4) unless $WTPROFILE_LOADED;

    my $dir = tempdir(CLEANUP => 1);
    my $json = <<'JSON';
{
  "defaultProfile": "{00000000-0000-4000-8000-000000000003}",
  "profiles": {
    "defaults": { "colorScheme": "A", "font": { "face": "X", "size": 12 } },
    "list": [
      { "name": "P3", "guid": "{00000000-0000-4000-8000-000000000003}",
        "colorScheme": "B", "font": { "face": "Y" } }
    ]
  }
}
JSON
    my $path = _write_bytes(File::Spec->catfile($dir, 'settings.json'), $json);
    my $res  = _call_hashref(sub { WtProfile::default_appearance($path) });
    is($res->{ok}, 1, 'A3: default_appearance(override fixture) returns ok=1');
    my $app = (ref($res->{appearance}) eq 'HASH') ? $res->{appearance} : {};
    is($app->{colorScheme}, 'B', 'A3: profile colorScheme overrides defaults colorScheme');
    is($app->{font}{face}, 'Y', 'A3: profile font.face overrides defaults font.face');
    is($app->{font}{size}, 12, 'A3: defaults font.size passes through when the profile does not set it');
}

# ===========================================================================
# AC-A4 -- legacy fontFace/fontSize/fontWeight
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 4) unless $WTPROFILE_LOADED;

    # Case A: profile carries only legacy keys, no font object, no defaults.
    my $dirA = tempdir(CLEANUP => 1);
    my $jsonA = <<'JSON';
{
  "defaultProfile": "P4A",
  "profiles": {
    "defaults": {},
    "list": [
      { "name": "P4A", "fontFace": "Cascadia Code", "fontSize": 10, "fontWeight": "semi-light" }
    ]
  }
}
JSON
    my $pathA = _write_bytes(File::Spec->catfile($dirA, 'settings.json'), $jsonA);
    my $resA  = _call_hashref(sub { WtProfile::default_appearance($pathA) });
    my $appA  = (ref($resA->{appearance}) eq 'HASH') ? $resA->{appearance} : {};
    is_deeply($appA->{font}, { face => 'Cascadia Code', size => 10, weight => 'semi-light' },
              'A4: legacy fontFace/fontSize/fontWeight render as font.face/size/weight');

    # Case B: same layer, font object beats legacy keys.
    my $dirB = tempdir(CLEANUP => 1);
    my $jsonB = <<'JSON';
{
  "defaultProfile": "P4B",
  "profiles": {
    "defaults": {},
    "list": [
      { "name": "P4B", "fontFace": "L", "font": { "face": "F" } }
    ]
  }
}
JSON
    my $pathB = _write_bytes(File::Spec->catfile($dirB, 'settings.json'), $jsonB);
    my $resB  = _call_hashref(sub { WtProfile::default_appearance($pathB) });
    my $appB  = (ref($resB->{appearance}) eq 'HASH') ? $resB->{appearance} : {};
    is($appB->{font}{face}, 'F', 'A4: within the profile layer, the font object beats its own legacy keys');

    # Case C: profile's legacy key beats defaults' font object.
    my $dirC = tempdir(CLEANUP => 1);
    my $jsonC = <<'JSON';
{
  "defaultProfile": "P4C",
  "profiles": {
    "defaults": { "font": { "face": "D" } },
    "list": [
      { "name": "P4C", "fontFace": "L" }
    ]
  }
}
JSON
    my $pathC = _write_bytes(File::Spec->catfile($dirC, 'settings.json'), $jsonC);
    my $resC  = _call_hashref(sub { WtProfile::default_appearance($pathC) });
    my $appC  = (ref($resC->{appearance}) eq 'HASH') ? $resC->{appearance} : {};
    is($appC->{font}{face}, 'L', 'A4: profile legacy fontFace beats defaults\' font object');
}

# ===========================================================================
# AC-A5 -- allow-list: forbidden keys never copied, allowed keys copied
# in section-2.4 order within the rendered bytes
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 15) unless $WTPROFILE_LOADED;

    # Forbidden keys.
    my $dir5a = tempdir(CLEANUP => 1);
    my $json5a = <<'JSON';
{
  "defaultProfile": "P5A",
  "profiles": {
    "defaults": {},
    "list": [
      { "name": "P5A", "commandline": "cmd.exe", "icon": "x.ico",
        "startingDirectory": "C:\\x", "backgroundImage": "bg.png",
        "experimental": { "retroTerminalEffect": true },
        "scrollbarState": "visible", "hidden": true }
    ]
  }
}
JSON
    my $path5a = _write_bytes(File::Spec->catfile($dir5a, 'settings.json'), $json5a);
    my $res5a  = _call_hashref(sub { WtProfile::default_appearance($path5a) });
    is($res5a->{ok}, 1, 'A5: default_appearance(forbidden-key fixture) returns ok=1');
    my $app5a = (ref($res5a->{appearance}) eq 'HASH') ? $res5a->{appearance} : {};
    for my $forbidden (qw(commandline icon startingDirectory backgroundImage experimental scrollbarState hidden)) {
        ok(!exists $app5a->{$forbidden}, "A5: forbidden key '$forbidden' is absent from the resolved appearance");
    }

    my $root5a = tempdir(CLEANUP => 1);
    my $ens5a  = _call_hashref(sub { WtProfile::ensure_fragment($root5a, { settings_path => $path5a }) });
    my $bytes5a   = defined($ens5a->{path}) ? _slurp_raw($ens5a->{path}) : '';
    my $decoded5a = eval { decode_json($bytes5a) };
    is(!$@ && ref($decoded5a) eq 'HASH' ? $decoded5a->{profiles}[0]{scrollbarState} : undef, 'hidden',
       'A5: scrollbarState in the rendered fragment stays "hidden" even though the settings profile asked for "visible"');

    # Allowed keys, checked both for value and for section-2.4 relative order.
    my $dir5b = tempdir(CLEANUP => 1);
    my $json5b = <<'JSON';
{
  "defaultProfile": "P5B",
  "profiles": {
    "defaults": {},
    "list": [
      { "name": "P5B", "opacity": 90, "useAcrylic": false, "padding": "4",
        "cursorShape": "bar", "intenseTextStyle": "all" }
    ]
  }
}
JSON
    my $path5b = _write_bytes(File::Spec->catfile($dir5b, 'settings.json'), $json5b);
    my $root5b = tempdir(CLEANUP => 1);
    my $ens5b  = _call_hashref(sub { WtProfile::ensure_fragment($root5b, { settings_path => $path5b }) });
    my $raw5b  = defined($ens5b->{path}) ? _slurp_raw($ens5b->{path}) : '';
    my $decoded5b = eval { decode_json($raw5b) };
    my $prof5b = (!$@ && ref($decoded5b) eq 'HASH') ? $decoded5b->{profiles}[0] : {};
    is($prof5b->{opacity}, 90, 'A5: opacity is copied with its own value');
    ok(!$prof5b->{useAcrylic}, 'A5: useAcrylic=false is preserved as falsy');
    is($prof5b->{padding}, '4', 'A5: padding is copied with its own value');
    is($prof5b->{cursorShape}, 'bar', 'A5: cursorShape is copied with its own value');
    is($prof5b->{intenseTextStyle}, 'all', 'A5: intenseTextStyle is copied with its own value');

    my $pos_cursor_shape = index($raw5b, '"cursorShape"');
    my $pos_opacity      = index($raw5b, '"opacity"');
    my $pos_use_acrylic  = index($raw5b, '"useAcrylic"');
    my $pos_padding      = index($raw5b, '"padding"');
    my $pos_intense      = index($raw5b, '"intenseTextStyle"');
    ok($pos_cursor_shape >= 0 && $pos_opacity > $pos_cursor_shape && $pos_use_acrylic > $pos_opacity
       && $pos_padding > $pos_use_acrylic && $pos_intense > $pos_padding,
       'A5: cursorShape, opacity, useAcrylic, padding and intenseTextStyle render in section-2.4 order in the raw bytes');
}

# ===========================================================================
# AC-A6 -- defaultProfile as a NAME, and legacy bare-array "profiles"
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 4) unless $WTPROFILE_LOADED;

    my $dir6a = tempdir(CLEANUP => 1);
    my $json6a = <<'JSON';
{
  "defaultProfile": "My Named Profile",
  "profiles": {
    "defaults": {},
    "list": [
      { "name": "My Named Profile", "colorScheme": "NameMatch" }
    ]
  }
}
JSON
    my $path6a = _write_bytes(File::Spec->catfile($dir6a, 'settings.json'), $json6a);
    my $res6a  = _call_hashref(sub { WtProfile::default_appearance($path6a) });
    is($res6a->{ok}, 1, 'A6: defaultProfile given as a plain profile name resolves (ok=1)');
    is(((ref($res6a->{appearance}) eq 'HASH') ? $res6a->{appearance}{colorScheme} : undef), 'NameMatch',
       'A6: the name-matched entry\'s colorScheme is resolved');

    my $dir6b = tempdir(CLEANUP => 1);
    my $json6b = <<'JSON';
{
  "defaultProfile": "Bare Array Profile",
  "profiles": [
    { "name": "Bare Array Profile", "colorScheme": "BareArray" }
  ]
}
JSON
    my $path6b = _write_bytes(File::Spec->catfile($dir6b, 'settings.json'), $json6b);
    my $res6b  = _call_hashref(sub { WtProfile::default_appearance($path6b) });
    is($res6b->{ok}, 1, 'A6: a legacy bare-array "profiles" resolves (ok=1)');
    is(((ref($res6b->{appearance}) eq 'HASH') ? $res6b->{appearance}{colorScheme} : undef), 'BareArray',
       'A6: the bare-array entry\'s colorScheme is resolved, with no profiles.defaults');
}

# ===========================================================================
# AC-A7 -- missing settings file, and settings_path => undef
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 8) unless $WTPROFILE_LOADED;

    my $dir7  = tempdir(CLEANUP => 1);
    my $missing_path = File::Spec->catfile($dir7, 'does-not-exist.json');
    ok(!-e $missing_path, 'A7 fixture sanity: the missing-file path genuinely does not exist');

    my $root7a = tempdir(CLEANUP => 1);
    my $res7a  = _call_hashref(sub { WtProfile::ensure_fragment($root7a, { settings_path => $missing_path }) });
    is($res7a->{ok}, 1, 'A7: ensure_fragment(missing settings file) returns ok=1');
    is($res7a->{appearance}, 'fallback', 'A7: appearance="fallback" for a missing settings file');
    is($res7a->{appearance_reason}, 'settings_not_found', 'A7: appearance_reason="settings_not_found"');
    my $bytes7a = defined($res7a->{path}) ? _slurp_raw($res7a->{path}) : '';
    is($bytes7a, _call_str(sub { WtProfile::fragment_json() }), 'A7: fragment bytes equal fragment_json()');
    is($bytes7a, _base_literal(), 'A7: fragment bytes equal today\'s pinned three-key literal');

    my $root7b = tempdir(CLEANUP => 1);
    my $res7b  = _call_hashref(sub { WtProfile::ensure_fragment($root7b, { settings_path => undef }) });
    is($res7b->{ok}, 1, 'A7: ensure_fragment(settings_path => undef) returns ok=1');
    is($res7b->{appearance_reason}, 'settings_not_found', 'A7: settings_path => undef gives the same reason');
}

# ===========================================================================
# AC-A8 -- broken/unusable settings, one case per closed reason
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 24) unless $WTPROFILE_LOADED;

    my $base_dir8 = tempdir(CLEANUP => 1);

    my @cases = (
        ['truncated object', 'settings_unparseable', '{ "profiles": '],
        ['top-level array (not an object)', 'settings_unparseable', '[1,2]'],
        ['unterminated block comment', 'settings_unparseable', '{ "profiles": {}, /* never closed'],
        ['defaultProfile matches nothing', 'no_default_profile',
         '{"defaultProfile":"nope","profiles":{"defaults":{},"list":[{"name":"other"}]}}'],
        ['defaultProfile absent', 'no_default_profile',
         '{"profiles":{"defaults":{},"list":[{"name":"x"}]}}'],
    );

    my $i = 0;
    for my $case (@cases) {
        my ($label, $reason, $content) = @$case;
        $i++;
        my $path = _write_bytes(File::Spec->catfile($base_dir8, "case$i.json"), $content);
        my $root = tempdir(CLEANUP => 1);
        my $res  = _call_hashref(sub { WtProfile::ensure_fragment($root, { settings_path => $path }) });
        is($res->{ok}, 1, "A8 ($label): ensure_fragment returns ok=1");
        is($res->{appearance}, 'fallback', "A8 ($label): appearance=\"fallback\"");
        is($res->{appearance_reason}, $reason, "A8 ($label): appearance_reason=\"$reason\"");
        my $bytes = defined($res->{path}) ? _slurp_raw($res->{path}) : '';
        is($bytes, _base_literal(), "A8 ($label): fragment bytes equal today's base literal");
    }

    # Directory at the settings path.
    my $dir_as_settings = File::Spec->catdir($base_dir8, 'a-directory-not-a-file');
    mkdir($dir_as_settings) or die "test fixture: mkdir failed for A8 directory case: $!";
    my $root_dir = tempdir(CLEANUP => 1);
    my $res_dir  = _call_hashref(sub { WtProfile::ensure_fragment($root_dir, { settings_path => $dir_as_settings }) });
    is($res_dir->{ok}, 1, 'A8 (directory at settings path): ensure_fragment returns ok=1');
    is($res_dir->{appearance}, 'fallback', 'A8 (directory at settings path): appearance="fallback"');
    is($res_dir->{appearance_reason}, 'settings_not_found', 'A8 (directory at settings path): appearance_reason="settings_not_found"');
    my $bytes_dir = defined($res_dir->{path}) ? _slurp_raw($res_dir->{path}) : '';
    is($bytes_dir, _base_literal(), 'A8 (directory at settings path): fragment bytes equal today\'s base literal');
}

# ===========================================================================
# AC-A9 -- every A7/A8 call, and one A1-shaped call, produce no die, no
# warning and no output on either stream; a counter-fixture proves the
# capture mechanism can detect a real STDERR write.
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 37) unless $WTPROFILE_LOADED;

    my $dir9 = tempdir(CLEANUP => 1);
    my $canon_path9        = _write_canonical_fixture($dir9);
    my $missing_path9      = File::Spec->catfile($dir9, 'missing.json');
    my $trunc_path9        = _write_bytes(File::Spec->catfile($dir9, 'trunc.json'), '{ "profiles": ');
    my $arr_path9          = _write_bytes(File::Spec->catfile($dir9, 'arr.json'), '[1,2]');
    my $unterminated_path9 = _write_bytes(File::Spec->catfile($dir9, 'unterminated.json'), '{ "profiles": {}, /* never closed');
    my $nomatch_path9      = _write_bytes(File::Spec->catfile($dir9, 'nomatch.json'),
        '{"defaultProfile":"nope","profiles":{"defaults":{},"list":[{"name":"other"}]}}');
    my $nodp_path9         = _write_bytes(File::Spec->catfile($dir9, 'nodp.json'),
        '{"profiles":{"defaults":{},"list":[{"name":"x"}]}}');
    my $dirpath9 = File::Spec->catdir($dir9, 'a-directory');
    mkdir($dirpath9) or die "test fixture: mkdir failed for A9 directory case: $!";

    my @targets = (
        ['A7 missing file',                 $missing_path9],
        ['A7 undef settings_path',          undef],
        ['A8 truncated object',             $trunc_path9],
        ['A8 top-level array',              $arr_path9],
        ['A8 unterminated block comment',   $unterminated_path9],
        ['A8 defaultProfile matches nothing', $nomatch_path9],
        ['A8 defaultProfile absent',        $nodp_path9],
        ['A8 directory at settings path',   $dirpath9],
        ['A1 canonical fixture',            $canon_path9],
    );

    for my $t (@targets) {
        my ($label, $sp) = @$t;
        my $root = tempdir(CLEANUP => 1);
        my ($ret, $out, $err) = _capture_streams(sub {
            my @warns;
            my $res;
            my $eval_ok = eval {
                local $SIG{__WARN__} = sub { push @warns, @_ };
                $res = WtProfile::ensure_fragment($root, { settings_path => $sp });
                1;
            };
            return ($eval_ok, \@warns, $@);
        });
        my ($eval_ok, $warns, $die_err) = @{$ret};
        ok($eval_ok, "A9 ($label): ensure_fragment does not die") or diag("died: $die_err");
        is(scalar(@$warns), 0, "A9 ($label): ensure_fragment warns nothing");
        is($out, '', "A9 ($label): ensure_fragment produced no STDOUT output");
        is($err, '', "A9 ($label): ensure_fragment produced no STDERR output");
    }

    my ($ret_c, $out_c, $err_c) = _capture_streams(sub { print STDERR "A9-COUNTER-PROBE\n"; return (1); });
    like($err_c, qr/A9-COUNTER-PROBE/, 'A9 counter-fixture: the stream-capture mechanism used above detects a real print STDERR');
}

# ===========================================================================
# AC-A10 -- idempotence on the canonical fixture
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 8) unless $WTPROFILE_LOADED;

    my $dir10  = tempdir(CLEANUP => 1);
    my $path10 = _write_canonical_fixture($dir10);
    my $root10 = tempdir(CLEANUP => 1);

    my $res10a = _call_hashref(sub { WtProfile::ensure_fragment($root10, { settings_path => $path10 }) });
    is($res10a->{ok}, 1, 'A10: first call on a fresh root returns ok=1');
    is($res10a->{action}, 'wrote', 'A10: first call reports action="wrote"');

    my $frag_path10 = $res10a->{path};
    my $past10 = time() - 10_000;
    utime($past10, $past10, $frag_path10) or die "test fixture: utime failed for A10: $!";
    my $mtime_before10 = (stat($frag_path10))[9];
    is($mtime_before10, $past10, 'A10 fixture sanity: utime set the fragment mtime to the past value');

    my $res10b = _call_hashref(sub { WtProfile::ensure_fragment($root10, { settings_path => $path10 }) });
    is($res10b->{ok}, 1, 'A10: second call with identical settings returns ok=1');
    is($res10b->{action}, 'unchanged', 'A10: second call with identical settings reports action="unchanged"');
    is($res10b->{appearance}, 'copied', 'A10: second call still reports appearance="copied"');
    my $mtime_after10 = (stat($frag_path10))[9];
    is($mtime_after10, $past10, 'A10: fragment mtime is unchanged after the second call -- no rewrite happened');

    utime(undef, undef, $frag_path10) or die "test fixture: utime(touch) failed for A10 counter-fixture: $!";
    my $mtime_touched10 = (stat($frag_path10))[9];
    isnt($mtime_touched10, $past10, 'A10 counter-fixture: utime(now) on the same file really does move its mtime');
}

# ===========================================================================
# AC-A11 -- a non-appearance settings change still reports "unchanged"
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 4) unless $WTPROFILE_LOADED;

    my $dir11  = tempdir(CLEANUP => 1);
    my $path11 = File::Spec->catfile($dir11, 'settings.json');
    _write_bytes($path11, _canonical_fixture_json());
    my $root11 = tempdir(CLEANUP => 1);

    my $res11a = _call_hashref(sub { WtProfile::ensure_fragment($root11, { settings_path => $path11 }) });
    is($res11a->{ok}, 1, 'A11: first call returns ok=1');
    my $frag_path11 = $res11a->{path};
    my $mtime_before11 = defined($frag_path11) ? (stat($frag_path11))[9] : undef;

    _write_bytes($path11, _canonical_fixture_json_with_copyonselect());

    my $res11b = _call_hashref(sub { WtProfile::ensure_fragment($root11, { settings_path => $path11 }) });
    is($res11b->{action}, 'unchanged', 'A11: a non-appearance settings change (added key + comment) reports action="unchanged"');
    my $mtime_after11 = defined($frag_path11) ? (stat($frag_path11))[9] : undef;
    is($mtime_after11, $mtime_before11, 'A11: fragment mtime is unchanged after the non-appearance settings edit');
    is($res11b->{appearance}, 'copied', 'A11: appearance is still "copied" after the non-appearance settings edit');
}

# ===========================================================================
# AC-A12 -- an appearance change rewrites the fragment; then breaking
# settings falls back to today's base bytes (B8)
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 7) unless $WTPROFILE_LOADED;

    my $dir12  = tempdir(CLEANUP => 1);
    my $path12 = File::Spec->catfile($dir12, 'settings.json');
    _write_bytes($path12, _canonical_fixture_json());
    my $root12 = tempdir(CLEANUP => 1);

    my $res12a = _call_hashref(sub { WtProfile::ensure_fragment($root12, { settings_path => $path12 }) });
    is($res12a->{ok}, 1, 'A12: first call returns ok=1');
    my $frag_path12 = $res12a->{path};

    _write_bytes($path12, _canonical_fixture_json_size11());
    my $res12b = _call_hashref(sub { WtProfile::ensure_fragment($root12, { settings_path => $path12 }) });
    is($res12b->{action}, 'wrote', 'A12: an appearance change (size 10 -> 11) reports action="wrote"');
    my $decoded12b = eval { decode_json(defined($frag_path12) ? _slurp_raw($frag_path12) : '') };
    is(!$@ && ref($decoded12b) eq 'HASH' ? $decoded12b->{profiles}[0]{font}{size} : undef, 11,
       'A12: decoded font.size is 11 after the appearance change');

    _write_bytes($path12, '{ "profiles": ');
    my $res12c = _call_hashref(sub { WtProfile::ensure_fragment($root12, { settings_path => $path12 }) });
    is($res12c->{action}, 'wrote', 'A12: breaking settings after a copied appearance rewrites the fragment');
    is($res12c->{appearance}, 'fallback', 'A12: appearance="fallback" once settings are broken');
    my $bytes12c = defined($frag_path12) ? _slurp_raw($frag_path12) : '';
    is($bytes12c, _base_literal(), 'A12: after the break, fragment bytes equal today\'s base literal (B8)');
    is($bytes12c, _call_str(sub { WtProfile::fragment_json() }), 'A12: after the break, fragment bytes equal fragment_json()');
}

# ===========================================================================
# AC-A13 -- settings.json is never opened for writing: bytes and mtime are
# unchanged by any of these call shapes
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 12) unless $WTPROFILE_LOADED;

    my @scenarios = (
        ['A1-shaped (single call)',           _canonical_fixture_json(), 1],
        ['A10-shaped (idempotent, two calls)', _canonical_fixture_json(), 2],
        ['A11-shaped (single call)',          _canonical_fixture_json_with_copyonselect(), 1],
        ['A12-shaped (appearance-changed, two calls)', _canonical_fixture_json_size11(), 2],
    );

    for my $scenario (@scenarios) {
        my ($label, $content, $calls) = @$scenario;
        my $dir  = tempdir(CLEANUP => 1);
        my $path = File::Spec->catfile($dir, 'settings.json');
        _write_bytes($path, $content);
        my $past = time() - 5_000;
        utime($past, $past, $path) or die "test fixture: utime failed for A13 ($label): $!";
        my $mtime_before = (stat($path))[9];
        is($mtime_before, $past, "A13 fixture sanity ($label): utime set the settings mtime to the past value");

        my $root = tempdir(CLEANUP => 1);
        for (1 .. $calls) {
            WtProfile::ensure_fragment($root, { settings_path => $path });
        }
        my $mtime_after = (stat($path))[9];
        my $bytes_after = _slurp_raw($path);
        is($mtime_after, $mtime_before, "A13 ($label): settings mtime is unchanged after ensure_fragment");
        is($bytes_after, $content, "A13 ($label): settings bytes are unchanged after ensure_fragment");
    }
}

# ===========================================================================
# AC-A14 -- the default source, under an emptied %ENV
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 3) unless $WTPROFILE_LOADED;

    local %ENV = ();
    my $root14 = tempdir(CLEANUP => 1);
    my $res14 = _call_hashref(sub { WtProfile::ensure_fragment($root14) });
    is($res14->{ok}, 1, 'A14: ensure_fragment($root) with one argument and empty %ENV returns ok=1');
    is($res14->{appearance}, 'fallback', 'A14: appearance="fallback" with no LOCALAPPDATA to resolve candidates from');
    is($res14->{appearance_reason}, 'settings_not_found', 'A14: appearance_reason="settings_not_found"');
}

# ===========================================================================
# AC-A15 -- settings_candidates()
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 13) unless $WTPROFILE_LOADED;

    my @c1 = _call_list(sub { WtProfile::settings_candidates({ LOCALAPPDATA => 'C:\Users\x\AppData\Local\\' }) });
    is(scalar(@c1), 2, 'A15: settings_candidates() returns exactly two candidates for a valid LOCALAPPDATA');
    is($c1[0], 'C:\Users\x\AppData\Local\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json',
       'A15: candidate 1 is the packaged/Store WT location');
    is($c1[1], 'C:\Users\x\AppData\Local\Microsoft\Windows Terminal\settings.json',
       'A15: candidate 2 is the unpackaged WT location');
    unlike($c1[0], qr{/}, 'A15: no forward slash in candidate 1 (must not use File::Spec)');
    unlike($c1[0], qr{\\\\}, 'A15: no doubled backslash in candidate 1 (trailing separator absorbed)');

    my $la_nonascii = 'C:\Users\x' . chr(0xC3) . chr(0xA9) . '\AppData\Local';
    my @c2 = _call_list(sub { WtProfile::settings_candidates({ LOCALAPPDATA => $la_nonascii }) });
    is(scalar(@c2), 2, 'A15: settings_candidates() returns exactly two candidates for a non-ASCII LOCALAPPDATA');
    like($c2[0], qr/\Q$la_nonascii\E/, 'A15: non-ASCII LOCALAPPDATA bytes pass through byte for byte in candidate 1');

    my $unc = (chr(92) x 2) . 'server' . chr(92) . 'share';
    for my $case (
        ['{}', {}],
        ['empty string', { LOCALAPPDATA => '' }],
        ['whitespace only', { LOCALAPPDATA => '   ' }],
        ['relative path', { LOCALAPPDATA => 'foo\bar' }],
        ['UNC path', { LOCALAPPDATA => $unc }],
        ['a path with a .. segment', { LOCALAPPDATA => 'C:\Users\..\x' }],
    ) {
        my ($label, $env) = @$case;
        my @c = _call_list(sub { WtProfile::settings_candidates($env) });
        is(scalar(@c), 0, "A15: settings_candidates($label) returns the empty list");
    }
}

# ===========================================================================
# AC-A16 -- success result key sets, and the closed appearance_reason set
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 3) unless $WTPROFILE_LOADED;

    my $dir16  = tempdir(CLEANUP => 1);
    my $path16 = _write_canonical_fixture($dir16);
    my $root16 = tempdir(CLEANUP => 1);
    my $res16a = _call_hashref(sub { WtProfile::ensure_fragment($root16, { settings_path => $path16 }) });
    is_deeply([ sort(keys(%$res16a)) ], [ sort(qw(action appearance ok path)) ],
              'A16: a "copied" success result has exactly the keys action/appearance/ok/path');

    my $root16b = tempdir(CLEANUP => 1);
    my $res16b  = _call_hashref(sub { WtProfile::ensure_fragment($root16b, { settings_path => undef }) });
    is_deeply([ sort(keys(%$res16b)) ], [ sort(qw(action appearance appearance_reason ok path)) ],
              'A16: a "fallback" success result has exactly the keys action/appearance/appearance_reason/ok/path');

    my %closed = map { $_ => 1 } qw(settings_not_found settings_unreadable settings_unparseable no_default_profile);
    ok($closed{ $res16b->{appearance_reason} || '' }, 'A16: the observed appearance_reason is a member of the closed set');
}

# ===========================================================================
# AC-A17 -- a non-ASCII font face renders as a \u escape, ASCII-clean output
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 7) unless $WTPROFILE_LOADED;

    # UTF-8 bytes for U+6E38, built from explicit byte values so this test
    # FILE stays pure ASCII source.
    my $face_bytes = chr(0xE6) . chr(0xB8) . chr(0xB8);
    my $json17 = '{"defaultProfile":"P17","profiles":{"defaults":{},"list":['
               . '{"name":"P17","font":{"face":"' . $face_bytes . '"}}]}}';
    my $dir17  = tempdir(CLEANUP => 1);
    my $path17 = _write_bytes(File::Spec->catfile($dir17, 'settings.json'), $json17);
    my $root17 = tempdir(CLEANUP => 1);

    my $res17 = _call_hashref(sub { WtProfile::ensure_fragment($root17, { settings_path => $path17 }) });
    is($res17->{ok}, 1, 'A17: ensure_fragment(non-ASCII face fixture) returns ok=1');
    is($res17->{appearance}, 'copied', 'A17: appearance="copied" for the non-ASCII face fixture');

    my $frag_bytes17 = defined($res17->{path}) ? _slurp_raw($res17->{path}) : '';
    ok(!_has_high_byte($frag_bytes17), 'A17: fragment bytes contain no byte >= 0x80');
    unlike($frag_bytes17, qr/\r/, 'A17: fragment bytes contain no carriage return');
    ok(!_has_utf8_bom($frag_bytes17), 'A17: fragment bytes carry no UTF-8 BOM');
    like($frag_bytes17, qr/\\u/, 'A17: fragment bytes contain a \\uXXXX escape for the non-ASCII face');

    my $decoded17 = eval { decode_json($frag_bytes17) };
    is(!$@ && ref($decoded17) eq 'HASH' ? $decoded17->{profiles}[0]{font}{face} : undef, chr(0x6E38),
       'A17: the decoded font.face equals the original character U+6E38');
}

# ===========================================================================
# AC-A18 -- a UTF-8 BOM-prefixed fixture parses the same as the un-prefixed
# canonical fixture
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 4) unless $WTPROFILE_LOADED;

    my $dir18  = tempdir(CLEANUP => 1);
    my $path18 = _write_bytes(File::Spec->catfile($dir18, 'settings.json'), "\xEF\xBB\xBF" . _canonical_fixture_json());
    my $root18 = tempdir(CLEANUP => 1);

    my $res18 = _call_hashref(sub { WtProfile::ensure_fragment($root18, { settings_path => $path18 }) });
    is($res18->{ok}, 1, 'A18: ensure_fragment(BOM-prefixed canonical fixture) returns ok=1');
    is($res18->{appearance}, 'copied', 'A18: appearance="copied" for the BOM-prefixed fixture');

    my $decoded18 = eval { decode_json(defined($res18->{path}) ? _slurp_raw($res18->{path}) : '') };
    my $prof18 = (!$@ && ref($decoded18) eq 'HASH') ? $decoded18->{profiles}[0] : {};
    is_deeply($prof18->{font}, \%EXPECTED_CANONICAL_FONT,
              'A18: the BOM-prefixed fixture decodes to the same font appearance as A1');
    is($prof18->{colorScheme}, 'One Half Dark', 'A18: the BOM-prefixed fixture\'s colorScheme is unaffected by the BOM');
}

# ===========================================================================
# AC-A19 -- an oversize settings file (> 4 MiB) is treated as unreadable
# ===========================================================================
SKIP: {
    skip('WtProfile.pm not loaded', 5) unless $WTPROFILE_LOADED;

    my $dir19  = tempdir(CLEANUP => 1);
    my $path19 = File::Spec->catfile($dir19, 'settings.json');
    my $pad_len = 4_194_304 + 1024;
    _write_bytes($path19, '{' . (' ' x $pad_len) . '}');
    ok((-s $path19) > 4_194_304, 'A19 fixture sanity: the oversize settings file exceeds the 4 MiB limit');

    my $root19 = tempdir(CLEANUP => 1);
    my $res19 = _call_hashref(sub { WtProfile::ensure_fragment($root19, { settings_path => $path19 }) });
    is($res19->{ok}, 1, 'A19: ensure_fragment(oversize settings) returns ok=1');
    is($res19->{appearance}, 'fallback', 'A19: appearance="fallback" for an oversize settings file');
    is($res19->{appearance_reason}, 'settings_unreadable', 'A19: appearance_reason="settings_unreadable"');
    my $bytes19 = defined($res19->{path}) ? _slurp_raw($res19->{path}) : '';
    is($bytes19, _base_literal(), 'A19: the fragment bytes equal today\'s base literal');
}

done_testing();
