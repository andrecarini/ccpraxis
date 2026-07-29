#!/usr/bin/env perl
# Oracle tests for ProtectedPaths (q01-protected-roots), derived from
#   .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/q01-protected-roots-spec.md
#
# IMMUTABLE ORACLE: the implementer conforms to the API + behavior specified
# there. This file is written from the spec alone — ProtectedPaths.pm does
# not exist yet at the time this file is authored, and this file is expected
# to fail to compile with "Can't locate ProtectedPaths.pm in @INC" until q01
# lands. That is the correct, intended state.
#
# All paths in this file are FABRICATED. All filesystem/env access is via
# injected seams (registry/extra_list/env/exists/read_file/realpath). No
# test in this file touches the real filesystem, the real %ENV, or the real
# ~/.claude/plugins/known_marketplaces.json. `protected_roots()` is never
# called without an opts hash (§7.1).
#
# Criterion mapping (see also the full AC -> test-name table in
#   reports/q01-protected-roots/test-writer-step3.md):
#   AC-1        : module loads, can(...) for all four exports
#   AC-2..6     : normalize_path (G1)
#   AC-7..22    : path_relation (Decision #1/#8, G2 fold rule)
#   AC-23..42   : protected_roots (Decision #4/#5/#6, G3)
#   AC-43..47   : target_self_codes (Decision #2, G4 — additive)
#   AC-48       : suite hygiene
#   AC-49..71   : q04-protected-paths-resolution — root resolution through the
#                 realpath seam (49-55), environment-independent home candidates
#                 (56-61), user-home root rejection + the C6 clone regression
#                 (62-67), and normalize_path's windows option (68-71). Derived
#                 from specs/q04-protected-paths-resolution-spec.md.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use ProtectedPaths qw(path_relation protected_roots target_self_codes normalize_path);

# =====================================================================
# AC-1 — module shape
# =====================================================================
for my $sub (qw(path_relation protected_roots target_self_codes normalize_path)) {
    ok(ProtectedPaths->can($sub), "AC-1: ProtectedPaths->can('$sub')");
}

# =====================================================================
# Shared fixtures (§7.2) — fabricated paths and injected seams only.
# =====================================================================

my $rp_id  = sub { $_[0] };                       # identity realpath (t/39 idiom) — called during root
                                                  # ingestion (q04 §1.2); identity resolution is a
                                                  # deliberate no-op, which is why every pre-q04
                                                  # expectation below is unchanged by that change.
my $no_fs  = sub { die "test touched the filesystem\n" };   # tripwire
my $env_of = sub { my %e = @_; return sub { $e{$_[0]} } };

# The AC-24 "happy path" registry: a github entry plus a directory entry
# whose source.path differs from its installLocation (Done criterion 5).
my $REG = {
    'gh-one' => {
        source          => { source => 'github', repo => 'o/r' },
        installLocation => '/home/u/.claude/plugins/marketplaces/gh-one',
    },
    'ccpraxis-local' => {
        source          => { source => 'directory', path => '/home/u/.claude/ccpraxis/plugins' },
        installLocation => '/home/u/.claude/ccpraxis/marketplace-install',
    },
};

my %O = (
    registry   => $REG,
    extra_list => ['/opt/protected-one'],
    env        => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
    exists     => $no_fs,               # tripwires: prove the zero-I/O guarantee
    read_file  => $no_fs,
    realpath   => $rp_id,
);

# The exact AC-24 expected roots, in §2.5.9 order.
my $AC24_ROOTS = [
    { path => '/home/u/.claude/ccpraxis',                              reason => 'ccpraxis-install' },
    { path => '/home/u/.claude',                                       reason => 'claude-home' },
    { path => '/home/u/.claude/ccpraxis/marketplace-install',          reason => 'marketplace-install' },
    { path => '/home/u/.claude/plugins/marketplaces/gh-one',           reason => 'marketplace-install' },
    { path => '/home/u/.claude/ccpraxis/plugins',                      reason => 'marketplace-source' },
    { path => '/opt/protected-one',                                    reason => 'user-configured' },
];

# ---- small local helpers (test scaffolding only; no filesystem access) ----
sub has_root {
    my ($r, $path, $reason) = @_;
    return scalar grep { $_->{path} eq $path && $_->{reason} eq $reason } @{ $r->{roots} };
}
sub has_error_code {
    my ($r, $code) = @_;
    return scalar grep { $_->{code} eq $code } @{ $r->{errors} };
}
sub count_error_code {
    my ($r, $code) = @_;
    return scalar grep { $_->{code} eq $code } @{ $r->{errors} };
}

# =====================================================================
# AC-2..AC-6 — normalize_path (G1)
# =====================================================================

for my $bad (undef, '', '   ', "\t") {
    my $label = defined $bad ? "'$bad'" : 'undef';
    my $got = eval { normalize_path($bad) };
    is($@, '', "AC-2: normalize_path($label) does not die");
    is($got, undef, "AC-2: normalize_path($label) returns undef");
}

for my $in (qw(/ // ///)) {
    is(normalize_path($in), '/', "AC-3: normalize_path('$in') eq '/'");
}
is(normalize_path('/.'),    '/', "AC-3: normalize_path('/.') eq '/'");
is(normalize_path('/a/..'), '/', "AC-3: normalize_path('/a/..') eq '/'");

for my $in ('C:', 'C:/', 'C:\\', 'C://') {
    is(normalize_path($in), 'C:/', "AC-3: normalize_path('$in') eq 'C:/'");
}
is(normalize_path('C:/a/..'), 'C:/', "AC-3: normalize_path('C:/a/..') eq 'C:/'");

is(normalize_path('/a/../..'),        '/',   "AC-4: normalize_path('/a/../..') eq '/'");
is(normalize_path('/a/../../../b'),   '/b',  "AC-4: normalize_path('/a/../../../b') eq '/b'");
is(normalize_path('C:/a/../..'),      'C:/', "AC-4: normalize_path('C:/a/../..') eq 'C:/'");

is(normalize_path('../a'),      '../a', "AC-5: normalize_path('../a') eq '../a'");
is(normalize_path('a/b/../c'),  'a/c',  "AC-5: normalize_path('a/b/../c') eq 'a/c'");
is(normalize_path('.'),         '.',    "AC-5: normalize_path('.') eq '.'");
is(normalize_path('a/..'),      '.',    "AC-5: normalize_path('a/..') eq '.'");

is(normalize_path('/a/b/'),      '/a/b',   "AC-6: normalize_path('/a/b/') eq '/a/b'");
is(normalize_path('/a//b///c/'), '/a/b/c', "AC-6: normalize_path('/a//b///c/') eq '/a/b/c'");
is(normalize_path('C:\\a\\b\\'), 'C:/a/b', "AC-6: normalize_path('C:\\\\a\\\\b\\\\') eq 'C:/a/b'");

# =====================================================================
# AC-7..AC-22 — path_relation (Decision #1/#8, G2)
# =====================================================================

is(path_relation('/a/b', '/a/b'), 'exact', "AC-7: path_relation('/a/b','/a/b') eq 'exact'");

# ---- DIRECTION ANCHOR — read early (spec §2.2 "READ THIS TWICE") ----
# descendant means the FIRST argument (target) is INSIDE the second (root).
is(path_relation('/a/b/c', '/a/b'),     'descendant',
   "AC-8: DIRECTION ANCHOR — path_relation('/a/b/c','/a/b') eq 'descendant' (target inside root)");
is(path_relation('/a/b/c/d/e', '/a/b'), 'descendant',
   "AC-8: path_relation('/a/b/c/d/e','/a/b') eq 'descendant'");

# ancestor means the FIRST argument (target) CONTAINS the second (root).
is(path_relation('/a', '/a/b'),      'ancestor',
   "AC-9: DIRECTION ANCHOR — path_relation('/a','/a/b') eq 'ancestor' (target contains root)");
is(path_relation('/', '/a/b/c'),     'ancestor',
   "AC-9: path_relation('/','/a/b/c') eq 'ancestor'");

is(path_relation('/a/x', '/b/y'), 'unrelated', "AC-10: path_relation('/a/x','/b/y') eq 'unrelated'");

is(path_relation('/a/bc', '/a/b'),   'unrelated', "AC-11: /a/bc vs /a/b is unrelated, not descendant (Decision #8)");
is(path_relation('/a/b', '/a/bc'),   'unrelated', "AC-11: symmetric — /a/b vs /a/bc is unrelated");
is(path_relation('/a/bc/d', '/a/b'), 'unrelated', "AC-11: /a/bc/d vs /a/b is unrelated");

is(path_relation('/a/b/', '/a/b'),        'exact',      "AC-12: trailing slash — /a/b/ vs /a/b eq 'exact'");
is(path_relation('/a/b//c///', '/a/b'),   'descendant', "AC-12: repeated slashes — /a/b//c/// vs /a/b eq 'descendant'");

is(path_relation('/a/./b', '/a/b'),     'exact',     "AC-13: dot segment — /a/./b vs /a/b eq 'exact'");
is(path_relation('/a/b/c/..', '/a/b'),  'exact',     "AC-13: trailing .. — /a/b/c/.. vs /a/b eq 'exact'");
is(path_relation('/a/b/../c', '/a/b'),  'unrelated', "AC-13: /a/b/../c vs /a/b eq 'unrelated'");

is(path_relation('/a/../..', '/'), 'exact',      "AC-14: clamped .. compares as root — /a/../.. vs / eq 'exact'");
is(path_relation('/x', '/a/../..'), 'descendant', "AC-14: /x vs clamped /a/../.. eq 'descendant'");

# Mixed separators with a MATCHING drive-letter case — platform-independent
# (no case folding is exercised; both inputs already spell 'C:').
is(path_relation('C:\\a\\b\\c', 'C:/a/b'), 'descendant', "AC-15: mixed separators, matching drive case eq 'descendant'");
is(path_relation('C:\\a\\b\\', 'C:/a/b'),  'exact',      "AC-15: mixed separators, matching drive case eq 'exact'");

is(path_relation('C:/a', 'D:/a'), 'unrelated', "AC-16: prefix mismatch — C:/a vs D:/a eq 'unrelated'");
is(path_relation('C:/a', '/a'),   'unrelated', "AC-16: prefix mismatch — C:/a vs /a eq 'unrelated'");
is(path_relation('/a', 'C:/a'),   'unrelated', "AC-16: prefix mismatch — /a vs C:/a eq 'unrelated'");
is(path_relation('../a', '/a'),   'unrelated', "AC-16: prefix mismatch — relative vs absolute eq 'unrelated'");

is(path_relation('C:/a/b', 'C:'), 'descendant', "AC-17: bare drive as root — C:/a/b vs C: eq 'descendant'");
is(path_relation('C:', 'C:/'),    'exact',      "AC-17: bare drive as root — C: vs C:/ eq 'exact'");

for my $pair ([undef, '/a'], ['/a', undef], [undef, undef], ['', '/a'], ['/a', ''], ['   ', '/a']) {
    my ($t, $r) = @$pair;
    my $got = eval { path_relation($t, $r) };
    is($@, '', "AC-18: path_relation degenerate args does not die");
    is($got, 'unrelated', "AC-18: path_relation degenerate args returns 'unrelated'");
}

is(path_relation('/a/B/C', '/a/b', { fold_case => 1 }), 'descendant',
   "AC-19: fold seam ON — /a/B/C vs /a/b eq 'descendant'");
is(path_relation('/A/B', '/a/b', { fold_case => 1 }), 'exact',
   "AC-19: fold seam ON — /A/B vs /a/b eq 'exact'");
{
    # second independent mechanism (§2.3(b)): the package-var override
    local $ProtectedPaths::FOLD_CASE = 1;
    is(path_relation('/A/B', '/a/b'), 'exact',
       "AC-19: local \$ProtectedPaths::FOLD_CASE=1 override — /A/B vs /a/b eq 'exact'");
}

is(path_relation('/a/B/C', '/a/b', { fold_case => 0 }), 'unrelated',
   "AC-20: fold seam OFF — /a/B/C vs /a/b eq 'unrelated'");
is(path_relation('/A/B', '/a/b', { fold_case => 0 }), 'unrelated',
   "AC-20: fold seam OFF — /A/B vs /a/b eq 'unrelated'");
{
    local $ProtectedPaths::FOLD_CASE = 0;
    is(path_relation('/A/B', '/a/b'), 'unrelated',
       "AC-20: local \$ProtectedPaths::FOLD_CASE=0 override — /A/B vs /a/b eq 'unrelated'");
}

SKIP: {
    skip 'whole-path case folding is Windows/macOS only (reused from _same_path)', 1
        unless $^O =~ /^(MSWin32|cygwin|msys|darwin)$/;
    is(path_relation('/A/B', '/a/b'), 'exact', 'AC-21: case-variant paths match on folding platforms (no fold_case opt)');
}
SKIP: {
    skip 'case sensitivity is the Linux-family behaviour', 1
        if $^O =~ /^(MSWin32|cygwin|msys|darwin)$/;
    is(path_relation('/A/B', '/a/b'), 'unrelated', 'AC-21: case-variant paths differ on Linux (no fold_case opt)');
}

is(path_relation('/a/b/c', '/a/b', { realpath => sub { die 'no' } }), 'descendant',
   "AC-22: realpath is never consulted by path_relation");

# =====================================================================
# AC-23..AC-42 — protected_roots (Decision #4/#5/#6, G3)
# =====================================================================

# AC-23 — return shape for the clean fixture %O
{
    my $r = protected_roots(\%O);
    is(ref $r, 'HASH', 'AC-23: protected_roots returns a HASH ref');
    is_deeply([sort keys %$r], [qw(errors roots)], 'AC-23: result has exactly the keys roots, errors');
    is(ref $r->{roots}, 'ARRAY', 'AC-23: roots is an ARRAY ref');
    is(ref $r->{errors}, 'ARRAY', 'AC-23: errors is an ARRAY ref');
    is_deeply($r->{errors}, [], 'AC-23: errors is empty for the clean fixture');
    for my $root (@{ $r->{roots} }) {
        is_deeply([sort keys %$root], [qw(path reason)], 'AC-23: each root has exactly path, reason');
        ok(defined $root->{path} && length $root->{path}, 'AC-23: root path is a non-empty string');
        ok(defined $root->{reason} && length $root->{reason}, 'AC-23: root reason is a non-empty string');
        ok((grep { $_ eq $root->{reason} }
              qw(marketplace-install marketplace-source claude-home ccpraxis-install user-configured)),
           "AC-23: reason '$root->{reason}' is in the five-code set");
    }
}

# AC-24 — all five reason codes, exact ordering (Done criterion 5)
{
    my $r = protected_roots(\%O);
    is_deeply($r, { roots => $AC24_ROOTS, errors => [] },
        'AC-24: all five reason codes, directory source.path differing from installLocation, exact §2.5.9 order');
}

# AC-25 — backslashed installLocation (real host shape) is canonicalised
{
    my $reg = {
        one => {
            source          => { source => 'github', repo => 'o/r' },
            installLocation => 'C:\\Users\\u\\.claude\\plugins\\marketplaces\\gh-one',
        },
    };
    my $r = protected_roots({
        registry   => $reg,
        extra_list => [],
        env        => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists     => $no_fs, read_file => $no_fs, realpath => $rp_id,
    });
    ok(has_root($r, 'C:/Users/u/.claude/plugins/marketplaces/gh-one', 'marketplace-install'),
       'AC-25: backslashed installLocation canonicalised to C:/Users/u/.claude/plugins/marketplaces/gh-one');
}

# AC-26 — ordering and determinism
{
    my $r1 = protected_roots(\%O);
    my $r2 = protected_roots(\%O);
    is_deeply($r1, $r2, 'AC-26: two identical protected_roots(\%O) calls are is_deeply-equal (determinism)');
    is_deeply($r1->{roots}, $AC24_ROOTS, 'AC-26: roots order matches the reason-rank-then-cmp rule');
}

# AC-27 — de-dup precedence, loser dropped
{
    # Case A: same path as installLocation AND an extra-list element -> marketplace-install wins.
    my $reg_a = { one => { source => { source => 'github', repo => 'o/r' },
                            installLocation => '/home/u/.claude/dup-marketplace' } };
    my $r_a = protected_roots({
        registry => $reg_a, extra_list => ['/home/u/.claude/dup-marketplace'],
        env => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id,
    });
    is(scalar(@{ $r_a->{roots} }), 2, 'AC-27a: dup path collapses — root count reflects the collapse');
    ok(has_root($r_a, '/home/u/.claude/dup-marketplace', 'marketplace-install'),
       'AC-27a: path present as both installLocation and extra-list appears once as marketplace-install');
    is((grep { $_->{reason} eq 'user-configured' } @{ $r_a->{roots} }), 0,
       'AC-27a: loser (user-configured) reason is dropped');

    # Case B: same path as Claude home AND an installLocation -> claude-home wins.
    my $reg_b = { one => { source => { source => 'github', repo => 'o/r' },
                            installLocation => '/home/u/.claude' } };
    my $r_b = protected_roots({
        registry => $reg_b, extra_list => [],
        env => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id,
    });
    is_deeply($r_b, { roots => [ { path => '/home/u/.claude', reason => 'claude-home' } ], errors => [] },
       'AC-27b: path present as both claude-home and installLocation appears once as claude-home');
}

# AC-28 — registry missing
{
    my $r = protected_roots({
        registry_path => '/fab/none.json',
        extra_list    => ['/opt/x'],
        env           => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists        => sub { 0 },
        read_file     => $no_fs,
        realpath      => $rp_id,
    });
    is(scalar(@{ $r->{errors} }), 1, 'AC-28: registry missing produces exactly one error');
    is($r->{errors}[0]{code}, 'registry-missing', "AC-28: error code eq 'registry-missing'");
    ok(has_root($r, '/home/u/.claude', 'claude-home'),  'AC-28: claude-home root still present');
    ok(has_root($r, '/opt/x', 'user-configured'),       'AC-28: user-configured root still present');
}

# AC-29 — registry unreadable
{
    my $r = protected_roots({
        registry_path => '/fab/none.json',
        extra_list    => ['/opt/x'],
        env           => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists        => sub { 1 },
        read_file     => sub { die "boom\n" },
        realpath      => $rp_id,
    });
    ok(has_error_code($r, 'registry-unreadable'), "AC-29: one error code eq 'registry-unreadable'");
    ok(has_root($r, '/home/u/.claude', 'claude-home'),  'AC-29: non-registry root (claude-home) intact');
    ok(has_root($r, '/opt/x', 'user-configured'),       'AC-29: non-registry root (user-configured) intact');
}

# AC-30 — registry unparseable
{
    my $r = protected_roots({
        registry_path => '/fab/none.json',
        extra_list    => ['/opt/x'],
        env           => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists        => sub { 1 },
        read_file     => sub { '{ not json' },
        realpath      => $rp_id,
    });
    ok(has_error_code($r, 'registry-unparseable'), "AC-30: one error code eq 'registry-unparseable'");
    ok(has_root($r, '/home/u/.claude', 'claude-home'), 'AC-30: non-registry root (claude-home) intact');
    ok(has_root($r, '/opt/x', 'user-configured'),      'AC-30: non-registry root (user-configured) intact');
}

# AC-31 — registry wrong shape (both supplied-as-data and decoded-as-array forms)
{
    my $r1 = protected_roots({
        registry => [], extra_list => ['/opt/x'],
        env => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id,
    });
    ok(has_error_code($r1, 'registry-shape'), "AC-31: registry=>[] gives one error code eq 'registry-shape'");
    is((grep { $_->{reason} =~ /^marketplace-/ } @{ $r1->{roots} }), 0, 'AC-31: no marketplace-* roots (registry=>[])');
    ok(has_root($r1, '/opt/x', 'user-configured'), 'AC-31: non-registry root intact (registry=>[])');

    my $r2 = protected_roots({
        registry_path => '/fab/none.json', extra_list => ['/opt/x'],
        env => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists => sub { 1 }, read_file => sub { '["a","b"]' }, realpath => $rp_id,
    });
    ok(has_error_code($r2, 'registry-shape'), "AC-31: decoded-as-array gives one error code eq 'registry-shape'");
    is((grep { $_->{reason} =~ /^marketplace-/ } @{ $r2->{roots} }), 0, 'AC-31: no marketplace-* roots (decoded array)');
    ok(has_root($r2, '/opt/x', 'user-configured'), 'AC-31: non-registry root intact (decoded array)');
}

# AC-32 — bad entries never discard good ones
{
    my $reg = {
        good      => { source => { source => 'directory', path => '/p/good/src' }, installLocation => '/p/good/inst' },
        notahash  => 'scalar',
        noinstall => { source => { source => 'github', repo => 'o/r' } },
        dirnopath => { source => { source => 'directory' }, installLocation => '/p/dnp/inst' },
    };
    my $r = protected_roots({
        registry => $reg, extra_list => [],
        env => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id,
    });
    ok(has_root($r, '/p/good/inst', 'marketplace-install'), 'AC-32: good entry installLocation root present');
    ok(has_root($r, '/p/good/src',  'marketplace-source'),  'AC-32: good entry source.path root present');
    ok(has_root($r, '/p/dnp/inst',  'marketplace-install'), 'AC-32: dirnopath entry installLocation root still present');
    is(scalar(@{ $r->{errors} }), 3, 'AC-32: exactly three registry-entry errors, one per offending (entry,field)');
    is((grep { $_->{code} eq 'registry-entry' } @{ $r->{errors} }), 3, 'AC-32: all three errors are registry-entry');
}

# AC-33 — a github source is not an error
{
    my $r = protected_roots(\%O);
    ok(has_root($r, '/home/u/.claude/plugins/marketplaces/gh-one', 'marketplace-install'),
       'AC-33: github entry yields a marketplace-install root');
    is(has_root($r, '/home/u/.claude/plugins/marketplaces/gh-one', 'marketplace-source'), 0,
       'AC-33: github entry yields no marketplace-source root');
    is_deeply($r->{errors}, [], 'AC-33: a github source produces no error');
}

# AC-34 — extra list absent is NOT an error (Decision #5)
{
    my $r = protected_roots({
        registry        => $REG,
        extra_list_path => '/fab/extra.json',
        env             => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists          => sub { 0 },
        read_file       => $no_fs,
        realpath        => $rp_id,
    });
    is((grep { $_->{reason} eq 'user-configured' } @{ $r->{roots} }), 0,
       'AC-34: absent extra-list file yields no user-configured root');
    is((grep { $_->{code} =~ /^extra-list/ } @{ $r->{errors} }), 0,
       'AC-34: absent extra-list file produces NO error (no extra-list-* code)');
}

# AC-35 — extra list malformed IS an error (Decision #6)
{
    my $r1 = protected_roots({
        registry => {}, extra_list => {},
        env => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id,
    });
    is(scalar(@{ $r1->{errors} }), 1, 'AC-35: extra_list=>{} produces exactly one error');
    is($r1->{errors}[0]{code}, 'extra-list-shape', "AC-35: extra_list=>{} error code eq 'extra-list-shape'");

    my $r2 = protected_roots({
        registry => {}, extra_list => ['/ok/one', '', undef, {}, '/ok/two'],
        env => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id,
    });
    ok(has_root($r2, '/ok/one', 'user-configured'), 'AC-35: good element /ok/one still becomes a root');
    ok(has_root($r2, '/ok/two', 'user-configured'), 'AC-35: good element /ok/two still becomes a root');
    is((grep { $_->{code} eq 'extra-list-entry' } @{ $r2->{errors} }), 3,
       'AC-35: three extra-list-entry errors for the three bad elements');
}

# AC-36 — UTF-8, both directions, one dedup
{
    my $wide = "/home/Andr\x{e9}/.claude/x";
    utf8::upgrade($wide);
    my $expect_bytes = do { my $b = "/home/Andr\x{e9}/.claude/x"; utf8::encode($b); $b };
    my $already_bytes = "/home/Andr\x{c3}\x{a9}/.claude/x";   # byte string, utf8 flag off, same visible spelling

    my $reg = {
        one => { source => { source => 'github', repo => 'o/r' }, installLocation => $wide },
        two => { source => { source => 'github', repo => 'o/r' }, installLocation => $already_bytes },
    };
    my $r = protected_roots({
        registry => $reg, extra_list => [],
        env => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id,
    });
    my @matches = grep { $_->{path} eq $expect_bytes && $_->{reason} eq 'marketplace-install' } @{ $r->{roots} };
    is(scalar(@matches), 1,
       'AC-36: wide-char installLocation and already-byte installLocation dedup to exactly one root');
    ok(defined $matches[0] && !utf8::is_utf8($matches[0]{path}),
       'AC-36: the root path is a UTF-8 byte string (no utf8 flag) — no double-encoding');
}

# AC-37 — bare-root guard
{
    my $reg = { bare => { source => { source => 'github', repo => 'o/r' }, installLocation => '/' } };
    my $r = protected_roots({
        registry => $reg, extra_list => ['C:/', '/valid/one'],
        env => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id,
    });
    is((grep { $_->{path} eq '/' } @{ $r->{roots} }), 0, "AC-37: bare root '/' does not appear in roots");
    is((grep { $_->{path} eq 'C:/' } @{ $r->{roots} }), 0, "AC-37: bare root 'C:/' does not appear in roots");
    ok(has_root($r, '/valid/one', 'user-configured'), 'AC-37: non-bare extra-list element /valid/one is a root');
    is((grep { $_->{code} eq 'root-bare-rejected' } @{ $r->{errors} }), 2,
       'AC-37: exactly two root-bare-rejected errors (one per bare candidate)');
    for my $root (@{ $r->{roots} }) {
        unlike($root->{path}, qr/^([A-Za-z]:)?\/$/, "AC-37: no returned root path is a bare root ($root->{path})");
    }
}

# AC-38 — Claude home resolution
{
    my $r = protected_roots({ registry => {}, extra_list => [], env => $env_of->(CLAUDE_CONFIG_DIR => '/cfg/dir'),
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id });
    ok(has_root($r, '/cfg/dir', 'claude-home'), 'AC-38: CLAUDE_CONFIG_DIR alone -> claude-home root /cfg/dir');

    my $r2 = protected_roots({ registry => {}, extra_list => [], env => $env_of->(HOME => '/home/u'),
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id });
    ok(has_root($r2, '/home/u/.claude', 'claude-home'), 'AC-38: HOME alone -> claude-home root $HOME/.claude');

    my $r3 = protected_roots({ registry => {}, extra_list => [], env => $env_of->(USERPROFILE => '/Users/u'),
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id });
    ok(has_root($r3, '/Users/u/.claude', 'claude-home'), 'AC-38: USERPROFILE alone -> claude-home root $USERPROFILE/.claude');

    my $r4 = protected_roots({ registry => {}, extra_list => [], env => $env_of->(),
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id });
    is((grep { $_->{reason} eq 'claude-home' } @{ $r4->{roots} }), 0,
       'AC-38: none of the three env vars -> no claude-home root');
    is_deeply($r4->{errors}, [ { code => 'claude-home-unresolved', detail => $r4->{errors}[0]{detail} } ],
       'AC-38: none of the three env vars -> exactly one claude-home-unresolved error, no other error');
}

# AC-39 — ccpraxis-install from live_install_dir, no file access
{
    my $reg = { 'ccpraxis-local' => { source => { source => 'directory', path => '/home/u/.claude/ccpraxis/plugins' } } };
    my $r = protected_roots({
        registry => $reg, extra_list => [],
        env => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id,
    });
    ok(has_root($r, '/home/u/.claude/ccpraxis', 'ccpraxis-install'),
       'AC-39: ccpraxis-install root derived from live_install_dir with no file access');

    my $r_none = protected_roots({
        registry => {}, extra_list => [],
        env => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id,
    });
    is((grep { $_->{reason} eq 'ccpraxis-install' } @{ $r_none->{roots} }), 0,
       'AC-39: registry with no ccpraxis-local entry -> no ccpraxis-install root');
    is_deeply($r_none->{errors}, [], 'AC-39: registry with no ccpraxis-local entry -> no error');
}

# AC-40 — zero-I/O guarantee (registry, extra_list, env supplied; exists/read_file/realpath all tripwires)
{
    my %O40 = (%O, realpath => $no_fs);
    my $r = protected_roots(\%O40);
    is_deeply($r, { roots => $AC24_ROOTS, errors => [] },
        'AC-40: zero-I/O guarantee — AC-24 structure returned unchanged with dying exists/read_file/realpath');
}

# AC-41 — never dies, hostile compound garbage
{
    my $r;
    eval {
        $r = protected_roots({
            registry   => 'a string',
            extra_list => \'ref',
            env        => sub { die 'boom' },
            exists     => sub { die 'boom' },
            read_file  => sub { die 'boom' },
        });
    };
    is($@, '', 'AC-41: protected_roots survives hostile compound-garbage opts without dying');
    ok(defined $r && ref($r) eq 'HASH', 'AC-41: still returns a HASH ref');
    ok(exists $r->{roots} && ref($r->{roots}) eq 'ARRAY', 'AC-41: HASH ref still has an ARRAY roots key');
    ok(exists $r->{errors} && ref($r->{errors}) eq 'ARRAY', 'AC-41: HASH ref still has an ARRAY errors key');
}

# AC-42 — C6 regression: a ccpraxis clone outside the install is unrelated to every root
{
    my $r = protected_roots(\%O);
    my $clone = '/src/ccpraxis';
    is((grep { $_->{path} eq $clone } @{ $r->{roots} }), 0, 'AC-42: clone path is not itself a protected root');
    for my $root (@{ $r->{roots} }) {
        is(path_relation($clone, $root->{path}), 'unrelated',
           "AC-42: C6 regression — clone $clone is unrelated to root $root->{path} ($root->{reason})");
    }
}

# =====================================================================
# AC-43..AC-47 — target_self_codes (Decision #2, G4 — additive)
# =====================================================================

for my $t ('/', 'C:', 'C:/', 'C:\\', '/a/../..') {
    is_deeply(target_self_codes($t, \%O), ['drive-root'], "AC-43: target_self_codes('$t', \\%O) is_deeply ['drive-root']");
}

{
    my $opts = { env => $env_of->(HOME => '/home/u'), windows => 0 };
    is_deeply(target_self_codes('/home/u', $opts), ['user-home'],
        "AC-44: target_self_codes('/home/u', ...) is_deeply ['user-home']");
    is_deeply(target_self_codes('/home/u/', $opts), ['user-home'],
        "AC-44: target_self_codes('/home/u/', ...) is_deeply ['user-home']");
    is_deeply(target_self_codes('/home/u/projects/x', $opts), [],
        "AC-44: target_self_codes('/home/u/projects/x', ...) is_deeply [] (subdir is not user-home)");
}

{
    my $env = $env_of->(USERPROFILE => '/Users/w', HOME => '/home/u');
    my $opts_win = { env => $env, windows => 1 };
    is_deeply(target_self_codes('/Users/w', $opts_win), ['user-home'],
        "AC-45: windows=>1 — target_self_codes('/Users/w', ...) is_deeply ['user-home']");
    is_deeply(target_self_codes('/home/u', $opts_win), [],
        "AC-45: windows=>1 — target_self_codes('/home/u', ...) is_deeply []");

    my $opts_posix = { env => $env, windows => 0 };
    is_deeply(target_self_codes('/Users/w', $opts_posix), [],
        "AC-45: windows=>0 — target_self_codes('/Users/w', ...) is_deeply [] (swapped)");
    is_deeply(target_self_codes('/home/u', $opts_posix), ['user-home'],
        "AC-45: windows=>0 — target_self_codes('/home/u', ...) is_deeply ['user-home'] (swapped)");

    {
        local $ProtectedPaths::WINDOWS_FAMILY = 1;
        is_deeply(target_self_codes('/Users/w', { env => $env }), ['user-home'],
            "AC-45: local \$ProtectedPaths::WINDOWS_FAMILY=1 override — /Users/w is_deeply ['user-home']");
    }
}

{
    my $got = eval { target_self_codes('/a/b', \%O) };
    is($@, '', 'AC-46: target_self_codes does not die on an ordinary path');
    is_deeply($got, [], "AC-46: target_self_codes('/a/b', \\%O) is_deeply []");

    my $got2 = eval { target_self_codes('/a/b', { env => sub { undef } }) };
    is($@, '', 'AC-46: target_self_codes does not die with an env seam returning undef for everything');
    is_deeply($got2, [], "AC-46: target_self_codes('/a/b', { env => sub{undef} }) is_deeply []");
}

{
    my $r = protected_roots(\%O);
    my @leaked = grep { $_->{reason} eq 'drive-root' || $_->{reason} eq 'user-home' } @{ $r->{roots} };
    is(scalar(@leaked), 0, "AC-47: target-side codes ('drive-root','user-home') never leak into protected_roots roots");
}

# =====================================================================
# q04 §1 — the realpath seam (AC-49..55).
#
# Resolution happens at ROOT INGESTION inside protected_roots, never inside
# path_relation (spec §0 C-0.1) — path_relation stays a pure lexical
# predicate, which is what lets AC-22 above remain true and untouched.
#
# ZERO REAL I/O (spec §0 C-0.3): symlinks are SIMULATED by injecting a
# realpath sub over a fabricated hash. No test here creates a real symlink,
# uses File::Temp, or touches the real filesystem — the $no_fs tripwires
# stay armed throughout, and this is also why these tests pass on Windows.
# =====================================================================

# AC-49 — regression guard for every pre-q04 expectation: with an identity
# realpath, the AC-24 happy path is byte-identical to its pre-q04 value.
{
    my $r = protected_roots(\%O);
    is_deeply($r->{roots}, $AC24_ROOTS,
        'AC-49: identity realpath leaves the AC-24 roots byte-identical (regression guard)');
    is(scalar @{ $r->{errors} }, 0, 'AC-49: identity realpath introduces no errors');
}

# AC-50 — THE FLAGSHIP BUG. With ~/.claude a symlink to /data/claude,
# `claude-sandbox ~/.claude` today returns refuse=0 with zero warnings,
# because the target is abs_path'd by the launcher while the root stays
# lexical. Resolving the root closes it.
{
    my %map = ('/home/u/.claude' => '/data/claude');
    my $rp  = sub { $map{$_[0]} // $_[0] };
    my $r   = protected_roots({
        registry => {}, extra_list => [],
        env => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists => $no_fs, read_file => $no_fs, realpath => $rp,
    });
    ok(has_root($r, '/data/claude', 'claude-home'),
        'AC-50: a symlinked claude-home root is ingested as its RESOLVED path /data/claude');
    is((grep { $_->{path} eq '/home/u/.claude' } @{ $r->{roots} }), 0,
        'AC-50: the unresolved lexical form is not also kept as a separate root');
    my ($root) = grep { $_->{reason} eq 'claude-home' } @{ $r->{roots} };
    is(path_relation('/data/claude', $root->{path}), 'exact',
        'AC-50: the resolved target now matches the resolved root (was "unrelated" pre-q04)');
}

# AC-51 — an unresolvable root (broken symlink / missing dir) degrades to its
# LEXICAL form and warns. Dropping it would shrink the protected set, which
# is the one direction Decision #6 forbids.
{
    my $rp = sub { return $_[0] eq '/opt/gone' ? undef : $_[0] };
    my $r  = protected_roots({
        registry => {}, extra_list => ['/opt/gone', '/opt/here'],
        env => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists => $no_fs, read_file => $no_fs, realpath => $rp,
    });
    ok(has_root($r, '/opt/gone', 'user-configured'),
        'AC-51: an unresolvable root is KEPT at its lexical path (never dropped)');
    ok(has_root($r, '/opt/here', 'user-configured'),
        'AC-51: the resolvable sibling root is unaffected');
    is(count_error_code($r, 'root-unresolved'), 1,
        'AC-51: exactly one root-unresolved error, naming the unresolvable candidate');
    my ($err) = grep { $_->{code} eq 'root-unresolved' } @{ $r->{errors} };
    like($err->{detail}, qr{/opt/gone},
        'AC-51: the root-unresolved detail names the offending path (so the launcher can warn about it)');
}

# AC-52 — a realpath seam that DIES behaves identically to one returning
# undef, and protected_roots itself never dies (spec §0 C-0.2). The eval
# wrapping the seam call in CcpraxisWorkCopy::_same_path is the precedent.
{
    my $rp = sub { die "boom\n" if $_[0] eq '/opt/gone'; return $_[0] };
    my $r  = eval { protected_roots({
        registry => {}, extra_list => ['/opt/gone', '/opt/here'],
        env => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists => $no_fs, read_file => $no_fs, realpath => $rp,
    }) };
    is($@, '', 'AC-52: protected_roots does not die when the realpath seam dies');
    ok(defined $r && has_root($r, '/opt/gone', 'user-configured'),
        'AC-52: a dying seam degrades that candidate to its lexical path');
    is(count_error_code($r, 'root-unresolved'), 1,
        'AC-52: a dying seam yields exactly one root-unresolved error (same as undef)');
    ok(has_root($r, '/opt/here', 'user-configured'),
        'AC-52: a dying seam for one candidate leaves the others intact');
}

# AC-53 — ORDER: resolve BEFORE dedup. Two candidates that are different
# symlinks to the same real directory must collapse to ONE root, and the
# survivor keeps the higher-ranked reason (%REASON_RANK: claude-home 1 beats
# user-configured 4). Dedup-before-resolve would leave two roots.
{
    my %map = ('/home/u/.claude' => '/real/claude', '/opt/link' => '/real/claude');
    my $rp  = sub { $map{$_[0]} // $_[0] };
    my $r   = protected_roots({
        registry => {}, extra_list => ['/opt/link'],
        env => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists => $no_fs, read_file => $no_fs, realpath => $rp,
    });
    is((grep { $_->{path} eq '/real/claude' } @{ $r->{roots} }), 1,
        'AC-53: two symlinks to one real directory collapse to exactly one root');
    ok(has_root($r, '/real/claude', 'claude-home'),
        'AC-53: the surviving reason is the higher-ranked one (claude-home over user-configured)');
}

# AC-54 — ORDER: resolve BEFORE reject. A candidate whose realpath maps it to
# a bare root must be rejected, not adopted. Reject-before-resolve lets
# finding 3's machine-wide outage arrive through finding 1's hole.
{
    my $rp = sub { return $_[0] eq '/opt/sneaky' ? '/' : $_[0] };
    my $r  = protected_roots({
        registry => {}, extra_list => ['/opt/sneaky', '/opt/fine'],
        env => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        exists => $no_fs, read_file => $no_fs, realpath => $rp,
    });
    is((grep { $_->{path} eq '/' } @{ $r->{roots} }), 0,
        'AC-54: a candidate resolving to a bare root does not become a root');
    ok(has_error_code($r, 'root-bare-rejected'),
        'AC-54: it is rejected loudly via root-bare-rejected (resolution precedes rejection)');
    ok(has_root($r, '/opt/fine', 'user-configured'),
        'AC-54: the well-formed sibling root still protects normally');
}

# AC-55 — path_relation still never consults realpath. This restates AC-22's
# invariant as a q04-owned assertion so this package cannot regress it,
# WITHOUT editing AC-22 (spec §7: zero existing assertions retargeted).
{
    my $boom = sub { die "path_relation must not consult realpath\n" };
    my $rel  = eval { path_relation('/a/b/c', '/a/b', { realpath => $boom }) };
    is($@, '', 'AC-55: path_relation does not invoke the realpath seam (q04-owned restatement of AC-22)');
    is($rel, 'descendant', 'AC-55: path_relation remains a pure lexical predicate');
}

# =====================================================================
# q04 §2 — environment-independent home candidates (AC-56..61).
#
# TWO NOTIONS OF "HOME", opposite bias (spec §2.1) — conflating them is a
# defect:
#   notion A  home_candidates : MAXIMAL. Missing a candidate SHRINKS the
#             protected set (fails open), which Decision #6 forbids. Feeds
#             claude-home roots and the default registry/extra-list sources.
#   notion B  _user_home      : MINIMAL, env-derived, EXACTLY as Appendix B
#             Decision #2 mandates. Feeds the 'user-home' target reason code
#             and the §3 rejection. Unchanged by q04 — widening it would
#             remove roots and refuse legitimate projects.
#
# The env-independent probes are injected via the `home_probes` seam, which
# returns zero or more HOME DIRECTORIES (as getpwuid's pw_dir would); the
# module derives "$home/.claude" from each. Every probe is independently
# eval-wrapped: a probe that fails contributes nothing and is NOT an error.
# =====================================================================

# AC-56 — cross-platform half of finding 2: a decoy HOME cannot displace the
# real home when USERPROFILE still names it (guards the existing union).
{
    my $r = protected_roots({
        registry => {}, extra_list => [],
        env => $env_of->(HOME => '/tmp/decoy', USERPROFILE => '/real/home'),
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id,
    });
    ok(has_root($r, '/real/home/.claude', 'claude-home'),
        'AC-56: a decoy HOME does not remove the real home\'s .claude from the protected set');
    ok(has_root($r, '/tmp/decoy/.claude', 'claude-home'),
        'AC-56: the decoy contributes an EXTRA root (over-refusal is the safe direction, Decision #6)');
}

# AC-57 — finding 2's core claim: an env-independent probe still yields its
# claude-home root when EVERY environment variable the module reads is a
# decoy. This is the assertion that a redirected environment cannot shrink
# the protected set.
{
    my $r = protected_roots({
        registry => {}, extra_list => [],
        env => $env_of->(HOME => '/tmp/decoy', USERPROFILE => '/tmp/decoy2',
                         CLAUDE_CONFIG_DIR => '/tmp/decoy3'),
        home_probes => sub { return ('/real/home') },
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id,
    });
    ok(has_root($r, '/real/home/.claude', 'claude-home'),
        'AC-57: an env-independent home probe yields its claude-home root despite all-decoy environment');
    ok(has_root($r, '/tmp/decoy3', 'claude-home'),
        'AC-57: the probe is ADDITIVE — env-derived candidates are still present, not replaced');
}

# AC-58 — the residue that lives in THIS module: $home_raw (:381) is a single
# precedence-ordered value and $registry_default (:415) is derived from it, so
# a redirected HOME poisons the module's OWN default registry path regardless
# of what the launcher passes. The source must become a candidate SET.
{
    my $real_reg = '/real/home/.claude/plugins/known_marketplaces.json';
    my $r = protected_roots({
        extra_list => [],
        env => $env_of->(HOME => '/tmp/decoy'),
        home_probes => sub { return ('/real/home') },
        exists     => sub { return $_[0] eq $real_reg ? 1 : 0 },
        read_file  => sub {
            return '{"gh":{"source":{"source":"github","repo":"o/r"},'
                 . '"installLocation":"/real/home/.claude/plugins/marketplaces/gh"}}'
                if $_[0] eq $real_reg;
            die "unexpected read of $_[0]\n";
        },
        realpath => $rp_id,
    });
    ok(has_root($r, '/real/home/.claude/plugins/marketplaces/gh', 'marketplace-install'),
        'AC-58: a registry found under a non-$home_raw home candidate still contributes its roots');
}

# AC-59 — an explicitly supplied registry_path (the launcher always supplies
# one) is honoured AND unioned with any candidate-derived registry, never
# replaced by it.
{
    my $explicit = '/explicit/known_marketplaces.json';
    my $probe_reg = '/real/home/.claude/plugins/known_marketplaces.json';
    my $r = protected_roots({
        registry_path => $explicit,
        extra_list    => [],
        env => $env_of->(HOME => '/tmp/decoy'),
        home_probes => sub { return ('/real/home') },
        exists    => sub { return ($_[0] eq $explicit || $_[0] eq $probe_reg) ? 1 : 0 },
        read_file => sub {
            return '{"a":{"source":{"source":"github","repo":"o/a"},"installLocation":"/roots/from-explicit"}}'
                if $_[0] eq $explicit;
            return '{"b":{"source":{"source":"github","repo":"o/b"},"installLocation":"/roots/from-probe"}}'
                if $_[0] eq $probe_reg;
            die "unexpected read of $_[0]\n";
        },
        realpath => $rp_id,
    });
    ok(has_root($r, '/roots/from-explicit', 'marketplace-install'),
        'AC-59: the explicitly supplied registry_path is still read');
    ok(has_root($r, '/roots/from-probe', 'marketplace-install'),
        'AC-59: a candidate-derived registry is UNIONED with it, not replaced by it');
}

# AC-60 — notion B is UNCHANGED. Appendix B Decision #2 specifies _user_home
# literally as %USERPROFILE% on Windows else $HOME; q04 must not silently
# override a user decision. Restates AC-45's guarantee as a q04-owned
# assertion without editing AC-45.
{
    my $env = $env_of->(USERPROFILE => '/Users/w', HOME => '/home/u');
    is_deeply(target_self_codes('/Users/w', { env => $env, windows => 1 }), ['user-home'],
        'AC-60: notion B unchanged — windows=>1 still uses %USERPROFILE% (Decision #2)');
    is_deeply(target_self_codes('/home/u', { env => $env, windows => 0 }), ['user-home'],
        'AC-60: notion B unchanged — windows=>0 still uses $HOME (Decision #2)');
}

# AC-61 — a probe that dies contributes nothing, raises NO error, and leaves
# the rest of the candidate set intact (spec §0 C-0.2: never dies).
{
    my $r = eval { protected_roots({
        registry => {}, extra_list => [],
        env => $env_of->(CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        home_probes => sub { die "probe exploded\n" },
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id,
    }) };
    is($@, '', 'AC-61: protected_roots does not die when a home probe dies');
    ok(defined $r && has_root($r, '/home/u/.claude', 'claude-home'),
        'AC-61: a dying probe leaves the env-derived candidates intact');
    is(count_error_code($r, 'home-probe-failed'), 0,
        'AC-61: a failed probe is not an error (best-effort, additive only)');
}

# =====================================================================
# q04 §3 — reject roots that normalise to the user home (AC-62..67).
#
# The bare-root half already exists (AC-37 / _is_bare_root). This is the
# missing user-home half. Without it, ONE malformed installLocation that
# climbs to the user's home makes EVERY project on the machine a descendant
# of a protected root — and with no override (Decision #3) that is an
# unrecoverable outage, not an inconvenience.
#
# Rejection uses notion B (minimal, env-derived), NOT notion A: using the
# maximal candidate set here would reject more roots and weaken the guard.
# =====================================================================

# AC-62 — the outage reproduction. An installLocation that climbs out of the
# plugins dir lands exactly on the user home.
# '/home/u/.claude/plugins/../..' normalises to '/home/u'.
{
    my $reg = { bad => { source => { source => 'github', repo => 'o/r' },
                         installLocation => '/home/u/.claude/plugins/../..' } };
    my $r = protected_roots({
        registry => $reg, extra_list => [],
        env => $env_of->(HOME => '/home/u'), windows => 0,
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id,
    });
    is((grep { $_->{path} eq '/home/u' } @{ $r->{roots} }), 0,
        'AC-62: a root normalising to the user home is NOT adopted');
    is(count_error_code($r, 'root-home-rejected'), 1,
        'AC-62: exactly one root-home-rejected error (loud, never silent)');
}

# AC-63 — the remaining roots still protect normally: a per-candidate
# rejection, never an abort of the whole set.
{
    my $reg = {
        bad  => { source => { source => 'github', repo => 'o/r' },
                  installLocation => '/home/u/.claude/plugins/../..' },
        good => { source => { source => 'github', repo => 'o/g' },
                  installLocation => '/home/u/.claude/plugins/marketplaces/good' },
    };
    my $r = protected_roots({
        registry => $reg, extra_list => ['/opt/keep'],
        env => $env_of->(HOME => '/home/u'), windows => 0,
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id,
    });
    ok(has_root($r, '/home/u/.claude/plugins/marketplaces/good', 'marketplace-install'),
        'AC-63: a well-formed marketplace root survives alongside the rejected one');
    ok(has_root($r, '/opt/keep', 'user-configured'),
        'AC-63: the extra-list root survives too');
    ok(scalar @{ $r->{roots} } > 0,
        'AC-63: rejecting a bad root never empties the protected set');
}

# AC-64 — ANTI-OVER-CORRECTION, the most important assertion in this section.
# The home itself is rejected, but ~/.claude — a DESCENDANT of the home — is
# the guard's single highest-value root (C5) and must be KEPT. A fix that
# rejects descendants deletes the guard it was meant to repair.
{
    my $r = protected_roots({
        registry => {}, extra_list => ['/home/u', '/home/u/.claude'],
        env => $env_of->(HOME => '/home/u'), windows => 0,
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id,
    });
    is((grep { $_->{path} eq '/home/u' } @{ $r->{roots} }), 0,
        'AC-64: the user home itself is rejected (exact match)');
    # Asserted by PATH, not by reason: '/home/u/.claude' is contributed both by
    # the extra list (user-configured, rank 4) and by the claude-home
    # derivation from $HOME (rank 1), and dedup keeps the higher-ranked
    # reason. What matters here is only that the descendant SURVIVES.
    is((grep { $_->{path} eq '/home/u/.claude' } @{ $r->{roots} }), 1,
        'AC-64: ~/.claude, a DESCENDANT of the home, is KEPT — rejection is exact-match only');
    ok(has_root($r, '/home/u/.claude', 'claude-home'),
        'AC-64: and it survives under its higher-ranked claude-home reason');
}

# AC-65 — case-folding (Decision #8): the comparison is segment-aware and
# honours the platform fold rule, not naive string equality.
{
    my %args = (
        registry => {}, extra_list => ['/HOME/U'],
        env => $env_of->(HOME => '/home/u'), windows => 0,
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id,
    );
    my $rf = protected_roots({ %args, fold_case => 1 });
    is((grep { $_->{path} eq '/HOME/U' } @{ $rf->{roots} }), 0,
        'AC-65: fold_case=>1 — a candidate differing from the home only in case is still rejected');
    my $rs = protected_roots({ %args, fold_case => 0 });
    ok(has_root($rs, '/HOME/U', 'user-configured'),
        'AC-65: fold_case=>0 — case-sensitive platforms treat it as a distinct, legitimate root');
}

# AC-66 — the new code is an ERROR code, never a root reason (extends AC-47's
# invariant, which forbids target-side codes leaking into roots).
{
    my $reg = { bad => { source => { source => 'github', repo => 'o/r' },
                         installLocation => '/home/u/.claude/plugins/../..' } };
    my $r = protected_roots({
        registry => $reg, extra_list => [],
        env => $env_of->(HOME => '/home/u'), windows => 0,
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id,
    });
    is((grep { $_->{reason} eq 'root-home-rejected' } @{ $r->{roots} }), 0,
        'AC-66: root-home-rejected never appears as a reason on a returned root');
}

# AC-67 — MANDATORY C6 REGRESSION (blueprint.md:176-179). An ordinary ccpraxis
# CLONE outside the install is not a registered marketplace, not the home and
# not bare, so it must remain unprotected and still launch. THIS BLUEPRINT IS
# ITSELF EXECUTING FROM SUCH A CLONE — resolving roots must not break it.
{
    my $clone = '/work/ccpraxis-clone';
    my $r = protected_roots({
        registry => $REG, extra_list => [],
        env => $env_of->(HOME => '/home/u', CLAUDE_CONFIG_DIR => '/home/u/.claude'),
        windows => 0,
        exists => $no_fs, read_file => $no_fs, realpath => $rp_id,
    });
    my @related = grep { path_relation($clone, $_->{path}) ne 'unrelated' } @{ $r->{roots} };
    is(scalar(@related), 0,
        'AC-67: C6 — an ordinary ccpraxis clone is unrelated to every protected root (must still launch)');
    is((grep { $_->{path} eq $clone } @{ $r->{roots} }), 0,
        'AC-67: C6 — the clone is not itself adopted as a protected root');
    is(count_error_code($r, 'root-home-rejected'), 0,
        'AC-67: C6 — a legitimate configuration produces no spurious home rejection');
}

# =====================================================================
# q04 §4 — normalize_path honours a `windows` option (MINOR-8) (AC-68..71).
#
# Narrower than "the module ignores windows": AC-45 above already proves the
# option IS honoured through target_self_codes/_user_home. The one real defect
# is that normalize_path takes NO $opts at all, so it calls the argless
# _windows_family() and the ambient platform probe wins — which makes the
# Windows-only normalisation rules untestable on a Linux runner. That is the
# concrete cost, and AC-69 is the assertion that could not be written before.
# =====================================================================

# AC-68 — the option is accepted and honoured on any host.
{
    is(normalize_path('C:/a/b/./c', { windows => 1 }), 'C:/a/b/c',
        'AC-68: normalize_path honours windows=>1 (drive-letter path normalises)');
    is(normalize_path('/a/b/./c', { windows => 0 }), '/a/b/c',
        'AC-68: normalize_path honours windows=>0 (POSIX path normalises)');
}

# AC-69 — the Windows-only trailing dot/space strip (:111-121) fires under
# windows=>1 and must NOT fire under windows=>0, ON LINUX. On POSIX "foo." and
# "foo " are legitimately distinct directory names; on Windows they alias
# "foo". This pair is what MINOR-8 made impossible to assert on a Linux host.
{
    is(normalize_path('/a/foo./b', { windows => 1 }), '/a/foo/b',
        'AC-69: windows=>1 strips a trailing dot from a segment (Win32 filesystem quirk)');
    is(normalize_path('/a/foo /b', { windows => 1 }), '/a/foo/b',
        'AC-69: windows=>1 strips a trailing space from a segment');
    is(normalize_path('/a/foo./b', { windows => 0 }), '/a/foo./b',
        'AC-69: windows=>0 PRESERVES a trailing dot — distinct name on POSIX');
    is(normalize_path('/a/foo /b', { windows => 0 }), '/a/foo /b',
        'AC-69: windows=>0 PRESERVES a trailing space — distinct name on POSIX');
    is(normalize_path('/a/../b', { windows => 1 }), '/b',
        'AC-69: the ".." marker is exempt from the strip and still resolves under windows=>1');
}

# AC-70 — BACK-COMPAT GUARD. Called with no second argument, behaviour is
# byte-identical to today. launcher.pl calls normalize_path($x) with one
# argument at :458 and :487; that must not change meaning.
{
    is(normalize_path('/a/b/./c'), '/a/b/c',
        'AC-70: no-opts call still normalises POSIX paths as before');
    is(normalize_path('/a/b/../c'), '/a/c',
        'AC-70: no-opts call still resolves ".." as before');
    is(normalize_path('//'), '/',
        'AC-70: no-opts all-slash pre-guard still returns "/"');
    is(normalize_path(''), undef,
        'AC-70: no-opts empty string is still undef');
    is(normalize_path('   '), undef,
        'AC-70: no-opts whitespace-only is still undef');
    is(normalize_path({}), undef,
        'AC-70: no-opts ref is still undef (ref guard intact)');
}

# AC-71 — path_relation threads its own opts into BOTH ingestions, so a
# Windows-quirk path pair compares consistently on a Linux host.
{
    is(path_relation('/a/foo./b', '/a/foo', { windows => 1 }), 'descendant',
        'AC-71: windows=>1 threads through path_relation — "foo." aliases "foo", so b is inside');
    is(path_relation('/a/foo./b', '/a/foo', { windows => 0 }), 'unrelated',
        'AC-71: windows=>0 threads through — "foo." is a distinct segment, so it is unrelated');
}

# =====================================================================
# AC-48 — suite hygiene: file ends with done_testing(); zero not-ok is
# judged by the harness running this file (exit code + not-ok count),
# not by an assertion inside itself.
# =====================================================================
{
    open my $fh, '<', $0 or die "cannot reopen own test file $0: $!";
    my @lines = <$fh>;
    close $fh;
    my @nonblank = grep { $_ !~ /^\s*$/ } @lines;
    like($nonblank[-1], qr/^\s*done_testing\(\);\s*$/,
        'AC-48: t/51-protected-paths.t ends with done_testing() (no fixed plan)');
}

done_testing();
