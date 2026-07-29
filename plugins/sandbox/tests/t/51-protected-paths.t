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

my $rp_id  = sub { $_[0] };                       # identity realpath (t/39 idiom) — accepted, never called
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
