#!/usr/bin/env perl
# Tests for q02-detector-hardening — the anchor-set / marker-count / branch-(A)
# hardening of CcpraxisWorkCopy (spec:
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/q02-detector-hardening-spec.md).
#
# IMMUTABLE ORACLE, written before the implementation. t/39-ccpraxis-workcopy-detect.t
# is NOT touched or required by this file — it is judged separately, from disk, by
# the harness runner (see AC-25). This file targets ONLY the three new/changed
# surfaces named in spec §2: `_install_anchors`, `_ccpraxis_markers`, and the
# broadened `is_in_place` / `is_ccpraxis_project` / `workcopy_route` built on them.
#
# Hermeticity (spec §3 binding preamble): every call injects `exists`,
# `git_commondir` (wherever the default git seam would otherwise spawn), and
# `realpath` where a path comparison occurs; `registry` is always a HASH, never
# `registry_path` pointing at a real file. `is_ccpraxis_project('/project', {})`
# returns 1 on this clone today via the REAL filesystem — no assertion below is
# reachable through that path (AC-24 proves the seams displace it).
#
# `_install_anchors` and `_ccpraxis_markers` do not exist yet. Calling an
# undefined fully-qualified sub dies at runtime, which would abort this whole
# file before done_testing() and collapse 25 ACs into one crash. Every call to
# either is therefore made through the `call_install_anchors` / `call_ccpraxis_markers`
# wrappers below, which eval-wrap the call and hand back a safe (arrayref, err)
# pair so a missing sub yields a clean `not ok`, never a die.
#
# Criterion mapping (see the report at
# reports/q02-detector-hardening/test-writer-step3.md for the full table):
#   AC-1..5   : _install_anchors contract (order, dedup, empties, canonicalisation, shape)
#   AC-6,7    : MAJOR-1 core + route level — MUST FAIL against today's code
#   AC-8..13  : is_in_place / workcopy_route union semantics (unchanged + F1 tradeoff)
#   AC-14..18 : _ccpraxis_markers + threshold=2 identity rule (MAJOR-3)
#   AC-19..22 : branch (A) reachability via the anchor set
#   AC-23     : Decision #9 freeze holds (canon_path/live_install_dir/_same_path/@EXPORT_OK)
#   AC-24     : hermeticity proof
#   AC-25     : suite-health meta-criterion (structural, no subprocess spawn)

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use CcpraxisWorkCopy qw(
    is_ccpraxis_project
    is_in_place
    workcopy_route
    canon_path
    live_install_dir
);

# =====================================================================
# Shared fake paths (fabricated — never touch the real filesystem)
# =====================================================================

my $LIVE        = 'C:/foo/ccpraxis';
my $WORKTREE    = 'C:/foo/ccpraxis-sandbox-workcopy';
my $CLONE       = 'C:/bar/some-clone';
my $FOREIGN     = 'C:/other/myproject';
my $LIVE_GIT    = "$LIVE/.git";
my $FOREIGN_GIT = "$FOREIGN/.git";

# Identity realpath seam: forces every in-place comparison down to pure
# canon_path() string equality (deterministic for fabricated paths).
my $rp_id = sub { $_[0] };

# Registries
my $REG_OK = {
    'ccpraxis-local' => { source => { source => 'directory', path => "$LIVE/plugins" } },
};
my $REG_EMPTY = {};
# Poisoned: source.path points somewhere OTHER than the true live root.
my $REG_POISON = {
    'ccpraxis-local' => { source => { source => 'directory', path => 'D:/evil/elsewhere/plugins' } },
};

# git_commondir seams
my $git_commondir_live = sub {
    my ($p) = @_;
    my $cp = canon_path($p) // '';
    return $LIVE_GIT if $cp eq canon_path($LIVE) || $cp eq canon_path($WORKTREE);
    return undef;
};
my $git_commondir_foreign = sub { $FOREIGN_GIT };
my $git_commondir_none    = sub { undef };

# exists seam factory: grants exactly M1 ('plugins/.claude-plugin/marketplace.json')
# and M2 ('plugins/sandbox/scripts/launcher.pl') under $dir — the same two-marker
# fixture t/39 uses, which is also the exact ceiling/floor pin for the threshold=2
# window (spec §2.3, §5.3).
sub exists_markers_for {
    my ($dir) = @_;
    return sub {
        my ($p) = @_;
        return 1 if $p eq "$dir/plugins/.claude-plugin/marketplace.json";
        return 1 if $p eq "$dir/plugins/sandbox/scripts/launcher.pl";
        return 0;
    };
}
my $exists_none = sub { 0 };

# Generic exists seam: grants exactly the given absolute paths.
sub exists_granting {
    my (@granted) = @_;
    my %ok = map { ($_ => 1) } @granted;
    return sub { my ($p) = @_; return $ok{$p} ? 1 : 0; };
}

# =====================================================================
# Safe wrappers around the two not-yet-existing subs. Never let a missing
# sub crash the file — capture the die and hand back a usable empty shape.
# =====================================================================
sub call_install_anchors {
    my ($opts) = @_;
    my $r = eval { CcpraxisWorkCopy::_install_anchors($opts) };
    my $err = $@;
    return ($r, $err);
}
sub call_ccpraxis_markers {
    my @r = eval { CcpraxisWorkCopy::_ccpraxis_markers() };
    my $err = $@;
    return (\@r, $err);
}

# Precompute the marker list once (empty pre-implementation; that emptiness is
# itself informative and is asserted on directly in AC-14).
my ($MARKERS_REF, $markers_err) = call_ccpraxis_markers();
my @MARKERS = @$MARKERS_REF;

# =====================================================================
# AC-1..5 — _install_anchors(\%opts) contract
# =====================================================================

{
    my ($r, $err) = call_install_anchors({ live_install_hint => 'C:/hintroot', registry => $REG_OK });
    ok(!$err, 'AC-1: _install_anchors({hint,registry}) does not die') or diag("died: $err");
    my @out = (ref $r eq 'ARRAY') ? @$r : ();
    is_deeply(\@out, ['C:/hintroot', $LIVE],
        'AC-1: order — hint anchor at index 0, registry-derived anchor second');
}

{
    my ($r, $err) = call_install_anchors({ live_install_hint => $LIVE, registry => $REG_OK });
    ok(!$err, 'AC-2: _install_anchors({hint==registry}) does not die') or diag("died: $err");
    my @out = (ref $r eq 'ARRAY') ? @$r : ();
    is(scalar(@out), 1,
        'AC-2: dedup — hint and registry resolving to the same anchor yield exactly one element');
}

{
    for my $case (
        [ 'empty opts',            {} ],
        [ 'empty-string hint',     { live_install_hint => '' } ],
        [ 'empty registry',        { registry => $REG_EMPTY } ],
    ) {
        my ($label, $opts) = @$case;
        my ($r, $err) = call_install_anchors($opts);
        ok(!$err, "AC-3: _install_anchors($label) does not die") or diag("died: $err");
        is(ref $r, 'ARRAY', "AC-3: _install_anchors($label) returns a defined arrayref (never undef)");
        my @out = (ref $r eq 'ARRAY') ? @$r : ('SENTINEL-not-an-arrayref');
        is(scalar(@out), 0, "AC-3: _install_anchors($label) arrayref has length 0 (not [undef])")
            if ref $r eq 'ARRAY';
        ok(0, "AC-3: _install_anchors($label) did not return an arrayref at all") unless ref $r eq 'ARRAY';
    }
}

{
    my ($r, $err) = call_install_anchors({ live_install_hint => 'C:/foo/ccpraxis/' });
    ok(!$err, 'AC-4: _install_anchors(trailing-slash hint) does not die') or diag("died: $err");
    my @out = (ref $r eq 'ARRAY') ? @$r : ();
    is_deeply(\@out, [ canon_path('C:/foo/ccpraxis/') ],
        'AC-4: canonicalisation — sole member is canon_path\'d, not the raw trailing-slash string');
}

ok(!CcpraxisWorkCopy->can('_resolve_install_anchor'),
    'AC-5: the defective single-anchor shape _resolve_install_anchor is gone');
ok(CcpraxisWorkCopy->can('_install_anchors'),
    'AC-5: the replacement _install_anchors is present');

# =====================================================================
# AC-6, AC-7 — MAJOR-1 core. MUST FAIL AGAINST TODAY'S CODE.
# =====================================================================

is(is_in_place($LIVE, { registry => $REG_OK, live_install_hint => 'C:/wrong/place', realpath => $rp_id }), 1,
    'AC-6: MAJOR-1 — is_in_place=1 via the registry anchor even though live_install_hint is wrong (MUST FAIL today: wrong hint wins, today returns 0)');

is(workcopy_route($LIVE, {
        registry          => $REG_OK,
        live_install_hint => 'C:/wrong/place',
        exists            => exists_markers_for($LIVE),
        git_commondir     => $git_commondir_none,
        realpath          => $rp_id,
    }), 'offer',
    "AC-7: MAJOR-1 at route level — workcopy_route='offer' via the registry anchor despite a wrong hint (MUST FAIL today: today returns 'passthrough', a silent in-place launch)");

# =====================================================================
# AC-8, AC-9 — is_in_place unchanged for hint-only / registry-only opts
# =====================================================================

is(is_in_place($LIVE,  { live_install_hint => $LIVE, realpath => $rp_id }), 1,
    'AC-8: hint-only — is_in_place=1 for the live path against its own hint');
is(is_in_place($CLONE, { live_install_hint => $LIVE, realpath => $rp_id }), 0,
    'AC-8: hint-only — is_in_place=0 for a clone against the live hint');

is(is_in_place($LIVE,     { registry => $REG_OK, realpath => $rp_id }), 1,
    'AC-9: registry-only — is_in_place=1 for the live path via the registry anchor');
is(is_in_place($WORKTREE, { registry => $REG_OK, realpath => $rp_id }), 0,
    'AC-9: registry-only — is_in_place=0 for the worktree via the registry anchor');

# =====================================================================
# AC-10, AC-11 — the F1 tradeoff (Appendix B Decision #6), pinned both directions
# =====================================================================

# Decision #6: "a registry that fails to parse is an error the user is told
# about, and the launcher still refuses on whatever roots it did resolve.
# Degrade toward refusing, never toward launching." A union anchor set means a
# poisoned registry can WIDEN refusal (false positive on an unrelated dir) but
# can never narrow it (it can never make a previously-refused dir launch).
# This assertion pins the accepted widening so a future change cannot silently
# re-narrow the union back to hint-only.
is(is_in_place('D:/evil/elsewhere', { live_install_hint => $LIVE, registry => $REG_POISON, realpath => $rp_id }), 1,
    'AC-10: F1 tradeoff (Appendix B Decision #6) — a poisoned registry anchor widens is_in_place to the attacker path (accepted false-refusal direction)');

is(is_in_place($LIVE, { live_install_hint => $LIVE, registry => $REG_POISON, realpath => $rp_id }), 1,
    'AC-11: poison immunity for the live path survives — a poisoned registry can never REMOVE the hint anchor');

# =====================================================================
# AC-12 — empty anchor set → not in place
# =====================================================================

is(is_in_place($LIVE, { realpath => $rp_id }), 0,
    'AC-12: empty anchor set (no hint, no registry) — is_in_place=0');
is(is_in_place($LIVE, { registry => $REG_EMPTY, realpath => $rp_id }), 0,
    'AC-12: empty anchor set (empty registry, no hint) — is_in_place=0');

# =====================================================================
# AC-13 — fail-safe restated in set terms, with a control (C6 clone regression)
# =====================================================================

is(workcopy_route($CLONE, {
        registry      => $REG_EMPTY,
        git_commondir => $git_commondir_none,
        exists        => exists_markers_for($CLONE),
        realpath      => $rp_id,
    }), 'offer',
    'AC-13: fail-safe — ccpraxis identity (markers) + empty anchor set → offer');

is(workcopy_route($CLONE, {
        live_install_hint => $LIVE,
        git_commondir     => $git_commondir_none,
        exists            => exists_markers_for($CLONE),
        realpath          => $rp_id,
    }), 'passthrough',
    'AC-13: control — ccpraxis identity + a NON-empty anchor set that does not match → passthrough, not offer (the fix must not be "always offer"; also the C6 clone-workflow regression)');

# =====================================================================
# AC-14 — _ccpraxis_markers() shape
# =====================================================================

ok(!$markers_err, 'AC-14: _ccpraxis_markers() does not die') or diag("died: $markers_err");
cmp_ok(scalar(@MARKERS), '>=', 5, 'AC-14: _ccpraxis_markers() returns at least 5 distinct entries (length)');
{
    my %seen;
    my @dups = grep { $seen{$_}++ } @MARKERS;
    is(scalar(@dups), 0, 'AC-14: _ccpraxis_markers() entries are distinct (no duplicates)');
}
ok((grep { $_ eq 'plugins/.claude-plugin/marketplace.json' } @MARKERS),
    'AC-14: _ccpraxis_markers() contains plugins/.claude-plugin/marketplace.json');
ok((grep { $_ eq 'plugins/sandbox/scripts/launcher.pl' } @MARKERS),
    'AC-14: _ccpraxis_markers() contains plugins/sandbox/scripts/launcher.pl');
ok(!(grep { $_ eq '.claude-plugin/marketplace.json' } @MARKERS),
    'AC-14: _ccpraxis_markers() does NOT contain the root-located wrong path .claude-plugin/marketplace.json');
ok(!(grep { m{^/} } @MARKERS),
    'AC-14: no _ccpraxis_markers() entry starts with a leading slash (all relative)');
ok(!(grep { m{^\.claude-plugin/} } @MARKERS),
    'AC-14: no _ccpraxis_markers() entry starts with .claude-plugin/ (the marketplace manifest lives under plugins/)');

# =====================================================================
# AC-15 — MAJOR-3 core: survives removal of ANY single marker. Data-driven
# over the real _ccpraxis_markers() list so it follows edits to the list.
# =====================================================================

if (!@MARKERS) {
    ok(0, 'AC-15: _ccpraxis_markers() returned no markers — cannot data-drive the single-marker-removal proof (sub missing or empty)');
} else {
    for my $i (0 .. $#MARKERS) {
        my @granted = map { "$CLONE/$MARKERS[$_]" } grep { $_ != $i } (0 .. $#MARKERS);
        my $seam = exists_granting(@granted);
        is(is_ccpraxis_project($CLONE, { registry => $REG_EMPTY, git_commondir => $git_commondir_none, exists => $seam }), 1,
            "AC-15: identity survives removal of marker index $i ('$MARKERS[$i]') — all other markers present");
    }
}

# =====================================================================
# AC-16 — threshold floor: 1 marker → 0, 0 markers → 0, 2 markers → 1
# =====================================================================

is(is_ccpraxis_project($CLONE, {
        registry      => $REG_EMPTY,
        git_commondir => $git_commondir_none,
        exists        => exists_granting("$CLONE/plugins/sandbox/scripts/launcher.pl"),
    }), 0,
    'AC-16: exactly one granted marker (launcher.pl) does not reach the threshold — is_ccpraxis_project=0');

is(is_ccpraxis_project($CLONE, {
        registry      => $REG_EMPTY,
        git_commondir => $git_commondir_none,
        exists        => $exists_none,
    }), 0,
    'AC-16: zero granted markers — is_ccpraxis_project=0');

{
    # "Arbitrary two distinct members" — deliberately NOT the legacy M1/M2 pair.
    # Coordinator sharpening 2026-07-29: picking indices [0,1] selects exactly the
    # two markers today's code already hardcodes, so the assertion passed both
    # before and after the change and proved nothing about the threshold. Picking
    # two NON-legacy members instead makes this a discriminating proof: it fails
    # against today's code (which demands M1 AND M2 specifically) and passes only
    # once identity is genuinely a COUNT over the marker set. Together with AC-15
    # this rules out both "M1/M2 mandatory" and "threshold > 2" rules.
    my @two = (@MARKERS >= 4) ? @MARKERS[2, 3]
                              : ('plugins/sandbox/.claude-plugin/plugin.json', 'plugins/sandbox/scripts/MountSpec.pm');
    my @granted = map { "$CLONE/$_" } @two;
    is(is_ccpraxis_project($CLONE, {
            registry      => $REG_EMPTY,
            git_commondir => $git_commondir_none,
            exists        => exists_granting(@granted),
        }), 1,
        "AC-16: exactly two granted distinct markers ('$two[0]', '$two[1]') reach the threshold — is_ccpraxis_project=1");
}

# =====================================================================
# AC-17 — the AC-18b trap, duplicated inside t/52 so it is guarded by this
# package's own oracle too (spec §5.3).
# =====================================================================

is(is_ccpraxis_project('C:/x/repo', {
        git_commondir => sub { undef },
        exists => sub {
            my ($p) = @_;
            # Only a ROOT marketplace.json (the OLD wrong path) + the launcher.
            return 1 if $p eq 'C:/x/repo/.claude-plugin/marketplace.json';
            return 1 if $p eq 'C:/x/repo/plugins/sandbox/scripts/launcher.pl';
            return 0;
        },
    }), 0,
    'AC-17: root-located marketplace.json (wrong path) + launcher.pl alone = 1 real marker, below the threshold — is_ccpraxis_project=0 (AC-18b trap, duplicated from t/39)');

# =====================================================================
# AC-18 — probe containment: the root-located manifest is never even probed.
# Must NOT assert a probe count (short-circuiting is allowed).
# =====================================================================

{
    my @probed;
    my $exists_rec = sub { my ($p) = @_; push @probed, $p; return 0; };
    is_ccpraxis_project('C:/x/repo', { git_commondir => sub { undef }, exists => $exists_rec });

    my %known = map { ("C:/x/repo/$_" => 1) } @MARKERS;
    my @unknown = grep { !$known{$_} } @probed;
    is(scalar(@unknown), 0,
        'AC-18: every probed path corresponds to a member of _ccpraxis_markers()')
        or diag('unrecognised probes: ' . join(', ', @unknown) . '; known members: ' . join(', ', @MARKERS));

    ok(!(grep { $_ eq 'C:/x/repo/.claude-plugin/marketplace.json' } @probed),
        'AC-18: the root-located .claude-plugin/marketplace.json is never probed');
}

# =====================================================================
# AC-19 — branch (A) fires on a registry-anchor commondir match, zero markers
# =====================================================================

is(is_ccpraxis_project($LIVE, { registry => $REG_OK, git_commondir => $git_commondir_live, exists => sub { 0 } }), 1,
    'AC-19: branch (A) fires for the live path via the registry anchor, with zero markers granted');
is(is_ccpraxis_project($WORKTREE, { registry => $REG_OK, git_commondir => $git_commondir_live, exists => sub { 0 } }), 1,
    'AC-19: branch (A) fires for the worktree via the registry anchor, with zero markers granted');

# =====================================================================
# AC-20 — branch (A) reachability via the HINT anchor alone. MUST FAIL
# AGAINST TODAY'S CODE (today: live_install_dir ignores the hint with no
# registry present, so branch (A) is skipped entirely).
# =====================================================================

is(is_ccpraxis_project($WORKTREE, { live_install_hint => $LIVE, git_commondir => $git_commondir_live, exists => sub { 0 } }), 1,
    "AC-20: F4 fix — branch (A) reachable via the hint anchor alone (no registry) (MUST FAIL today: live_install_dir(\$opts) ignores the hint, branch (A) is skipped, markers absent -> today returns 0)");

# =====================================================================
# AC-21 — branch (A) does not over-broaden for a foreign commondir
# =====================================================================

is(is_ccpraxis_project($FOREIGN, { live_install_hint => $LIVE, git_commondir => $git_commondir_foreign, exists => sub { 0 } }), 0,
    'AC-21: branch (A) does not fire for a foreign git commondir that matches no anchor');

# =====================================================================
# AC-22 — branch (A) matches ANY anchor in the union (same Decision #6 direction)
# =====================================================================

is(is_ccpraxis_project('C:/somewhere', {
        live_install_hint => $LIVE,
        registry          => $REG_POISON,
        git_commondir     => sub { 'D:/evil/elsewhere/.git' },
        exists            => sub { 0 },
    }), 1,
    'AC-22: branch (A) matches via a poisoned registry anchor even though the hint anchor does not match (union semantics, Decision #6)');

# =====================================================================
# AC-23 — Appendix B Decision #9 freeze holds
# =====================================================================

is(live_install_dir({ registry => $REG_OK }), $LIVE,
    'AC-23: Decision #9 freeze — live_install_dir(valid registry) unchanged');
is(live_install_dir({ registry => $REG_EMPTY }), undef,
    'AC-23: Decision #9 freeze — live_install_dir(empty registry) unchanged (undef)');
is(live_install_dir({ registry => { 'ccpraxis-local' => { source => { source => 'directory', path => 'C:/plugins' } } } }), undef,
    'AC-23: Decision #9 freeze — live_install_dir bare-root rejection unchanged (undef)');

is(canon_path('C:\\Users\\André\\.claude\\ccpraxis\\'), 'C:/Users/André/.claude/ccpraxis',
    'AC-23: Decision #9 freeze — canon_path backslash/trailing-slash normalisation unchanged');

{
    my $expected = ($^O =~ /^(MSWin32|cygwin|msys|darwin)$/) ? 1 : 0;
    is(CcpraxisWorkCopy::_same_path('/A', '/a', { realpath => sub { $_[0] } }), $expected,
        "AC-23: Decision #9 freeze — _same_path case-folding is platform-correct on \$^O=$^O");
}

{
    my $mod = "$Bin/../../scripts/CcpraxisWorkCopy.pm";
    open my $mfh, '<', $mod or BAIL_OUT("cannot open CcpraxisWorkCopy.pm: $!");
    my $msrc = do { local $/; <$mfh> };
    close $mfh;
    my ($export_list) = $msrc =~ /\@EXPORT_OK\s*=\s*qw\(([^)]*)\)/s;
    ok(defined $export_list, 'AC-23: found @EXPORT_OK = qw(...) in CcpraxisWorkCopy.pm')
        or diag('no @EXPORT_OK = qw(...) found');
    $export_list //= '';
    my @got  = sort grep { length } split(/\s+/, $export_list);
    my @want = sort qw(is_ccpraxis_project is_in_place workcopy_route workcopy_refusal_outcome canon_path live_install_dir);
    is_deeply(\@got, \@want,
        'AC-23: Decision #9 / t/42 AC-D6 freeze — @EXPORT_OK is exactly the six existing names, nothing added');
}

# =====================================================================
# AC-24 — hermeticity proof: injected seams fully displace the real
# filesystem and registry, even against /project (a real ccpraxis clone
# whose real markers exist and which returns 1 via is_ccpraxis_project('/project', {}) today).
# =====================================================================

is(is_ccpraxis_project('/project', { git_commondir => sub { undef }, exists => sub { 0 }, registry => $REG_EMPTY }), 0,
    'AC-24: hermeticity — injected seams (exists=>0, git_commondir=>undef, registry=>{}) displace the real filesystem/registry even for the real /project clone');

# =====================================================================
# AC-25 — the oracle and its nearest neighbour stay green (meta-criterion).
# This package does NOT spawn t/39 or t/42 from inside this file (fragile,
# slow, and duplicative of the harness runner that already executes both
# from disk per the CLAUDE.md test-running convention). Expressed
# structurally instead: the oracle and its guard file are present, and this
# file's own diff footprint touches neither. The actual "0 not ok" check for
# t/39 (64 assertions) and the "stays green" check for t/42 are run by the
# harness/operator directly against disk, per spec AC-25's own seam note
# ("run-from-disk, timeout 60, never prove") and the package instructions.
# =====================================================================

ok(-f "$Bin/39-ccpraxis-workcopy-detect.t",
    'AC-25: t/39-ccpraxis-workcopy-detect.t (the immutable oracle) is present on disk');
ok(-f "$Bin/42-refuse-in-place.t",
    'AC-25: t/42-refuse-in-place.t (the nearest-neighbour consumer of this module) is present on disk');
pass('AC-25: t/39 and t/42 are judged by running them from disk (perl t/NN-*.t, exit code + not-ok count), ' .
     'not by spawning them from inside t/52 — documented per the package instructions rather than executed here');

done_testing();
