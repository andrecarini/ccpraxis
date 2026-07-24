#!/usr/bin/env perl
# Tests for CcpraxisSelfHost — the detection + routing module (p01).
#
# IMMUTABLE ORACLE: the implementer conforms to the API + behavior here.
# All seams injected — no real git repo, no dependence on this machine
# being André's. The in-place comparison is exercised through an injected
# `realpath` seam so it is deterministic regardless of the host's real
# Cwd::abs_path quirks (the production default is Cwd::abs_path).
#
# Criterion mapping:
#   AC-1..4  : is_ccpraxis_project (live/worktree/clone/unrelated)
#   AC-5,6   : is_in_place (hint-first anchor, registry fallback, canonicalization)
#   AC-7,8   : selfhost_route (offer in-place / passthrough else)
#   AC-9,10  : structural launcher wiring + decline outcome
#   AC-12    : selfhost_route fail-safe — ccpraxis identity + NO anchor → offer   (CRIT-1)
#   AC-13    : poison-immunity — hint overrides a poisoned/wrong registry        (HIGH-3)
#   AC-14    : abs_path symmetry — realpath-resolved equality                    (HIGH-4)
#   AC-15    : live_install_dir rejects a bare-root derived install dir          (MED-5)
#   AC-16    : NO shell interpolation in the git default (structural + canary)   (CRIT-2 RCE)

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use CcpraxisSelfHost qw(
    is_ccpraxis_project
    is_in_place
    selfhost_route
    selfhost_decline_outcome
    canon_path
    live_install_dir
);

# =====================================================================
# Shared fake paths (fabricated — never touch the real filesystem)
# =====================================================================

my $LIVE      = 'C:/foo/ccpraxis';
my $WORKTREE  = 'C:/foo/ccpraxis-selfhost';
my $CLONE     = 'C:/bar/some-clone';
my $FOREIGN   = 'C:/other/myproject';
my $LIVE_GIT  = "$LIVE/.git";
my $FOREIGN_GIT = 'C:/other/myproject/.git';

# Identity realpath seam: forces the in-place comparison down to pure
# canon_path() string equality (deterministic for fabricated paths).
my $rp_id = sub { $_[0] };

# Registries
my $REG_OK = {
    'ccpraxis-local' => { source => { source => 'directory', path => "$LIVE/plugins" } },
};
my $REG_EMPTY     = {};
my $REG_NODIRTYPE = {
    'ccpraxis-local' => { source => { source => 'git', path => "$LIVE/plugins" } },
};
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

# exists seam factory: markers present only under $dir
sub exists_markers_for {
    my ($dir) = @_;
    return sub {
        my ($p) = @_;
        # Markers live UNDER plugins/ (the marketplace source dir), not the repo root.
        return 1 if $p eq "$dir/plugins/.claude-plugin/marketplace.json";
        return 1 if $p eq "$dir/plugins/sandbox/scripts/launcher.pl";
        return 0;
    };
}
my $exists_live  = exists_markers_for($LIVE);
my $exists_wt    = exists_markers_for($WORKTREE);
my $exists_clone = exists_markers_for($CLONE);
my $exists_none  = sub { 0 };

# =====================================================================
# live_install_dir — §2.2 + §9.4 (MED-5)
# =====================================================================

is(live_install_dir({ registry => $REG_OK }), $LIVE,
   'live_install_dir: valid registry entry resolves to parent of /plugins');
is(live_install_dir({ registry => $REG_EMPTY }), undef,
   'live_install_dir: empty registry → undef');
is(live_install_dir({ registry => $REG_NODIRTYPE }), undef,
   'live_install_dir: non-directory source → undef');

my $got;
eval { $got = live_install_dir({ registry_path => 'C:/nonexistent/known_marketplaces.json' }) };
is($@, '', 'live_install_dir: bad registry_path does not die');
is($got, undef, 'live_install_dir: bad registry_path → undef');

is(live_install_dir({ registry => { 'ccpraxis-local' => { source => { source => 'directory', path => 'C:/foo/ccpraxis/plugins' } } } }),
   'C:/foo/ccpraxis', 'live_install_dir: §3 worked example');

# AC-15 (MED-5): dirname of a root-adjacent path is a bare root → reject → undef
is(live_install_dir({ registry => { 'ccpraxis-local' => { source => { source => 'directory', path => 'C:/plugins' } } } }),
   undef, 'AC-15: registry path whose dirname is a bare drive (C:/plugins→C:) → undef');
is(live_install_dir({ registry => { 'ccpraxis-local' => { source => { source => 'directory', path => '/' } } } }),
   undef, 'AC-15: registry path "/" → derived root rejected → undef');

# =====================================================================
# canon_path — §2.1
# =====================================================================

is(canon_path('C:\\Users\\André\\.claude\\ccpraxis\\'), 'C:/Users/André/.claude/ccpraxis',
   'canon_path: backslash→slash, trailing slash stripped, drive uppercased');
is(canon_path('c:/x/y'), canon_path('C:/x/y'),
   'canon_path: c:/x/y equals C:/x/y (case-insensitive drive letter)');
my $unicode_canon = canon_path('C:/Users/André/.claude/ccpraxis');
is(canon_path('c:\\Users\\André\\.claude\\ccpraxis\\'), $unicode_canon,
   'canon_path: André Unicode backslash/lc-drive variant equals canonical form');
is(canon_path(undef), undef, 'canon_path: undef → undef');
is(canon_path(''),    undef, 'canon_path: empty string → undef');

# =====================================================================
# AC-1..4 — is_ccpraxis_project (identity; unaffected by the in-place redesign)
# =====================================================================

is(is_ccpraxis_project($LIVE, { registry => $REG_OK, git_commondir => $git_commondir_live, exists => $exists_none }),
   1, 'AC-1: is_ccpraxis_project=1 for live repo via commondir branch');

is(is_ccpraxis_project($WORKTREE, { registry => $REG_OK, git_commondir => $git_commondir_live, exists => $exists_none }),
   1, 'AC-2: is_ccpraxis_project=1 for worktree (shares live .git commondir)');

is(is_ccpraxis_project($CLONE, { registry => $REG_EMPTY, git_commondir => $git_commondir_none, exists => $exists_clone }),
   1, 'AC-3: is_ccpraxis_project=1 for clone via content-marker fallback (empty registry, no git)');
is(is_ccpraxis_project($CLONE, { registry => $REG_NODIRTYPE, git_commondir => $git_commondir_none, exists => $exists_clone }),
   1, 'AC-3b: content-marker fallback fires when registry has non-directory source');

is(is_ccpraxis_project($FOREIGN, { registry => $REG_OK, git_commondir => $git_commondir_none, exists => $exists_none }),
   0, 'AC-4i: is_ccpraxis_project=0 for non-git dir with no markers');
is(is_ccpraxis_project($FOREIGN, { registry => $REG_OK, git_commondir => $git_commondir_foreign, exists => $exists_none }),
   0, 'AC-4ii: is_ccpraxis_project=0 for git repo with foreign commondir, no markers');

# =====================================================================
# AC-5 — is_in_place (§9.1: hint-first anchor, registry fallback)
# =====================================================================

# Hint-based (production reality: launcher passes its own resolved root)
is(is_in_place($LIVE,     { live_install_hint => $LIVE, realpath => $rp_id }), 1,
   'AC-5a: is_in_place=1 for live path == hint');
is(is_in_place($WORKTREE, { live_install_hint => $LIVE, realpath => $rp_id }), 0,
   'AC-5b: is_in_place=0 for worktree (≠ hint)');
is(is_in_place($CLONE,    { live_install_hint => $LIVE, realpath => $rp_id }), 0,
   'AC-5c: is_in_place=0 for clone (≠ hint)');
is(is_in_place($LIVE,     { realpath => $rp_id }), 0,
   'AC-5d: is_in_place=0 with neither hint nor registry (no anchor)');

# Registry fallback still works (no hint)
is(is_in_place($LIVE,     { registry => $REG_OK, realpath => $rp_id }), 1,
   'AC-5e: is_in_place=1 via registry fallback when no hint');
is(is_in_place($WORKTREE, { registry => $REG_OK, realpath => $rp_id }), 0,
   'AC-5f: is_in_place=0 for worktree via registry fallback');
is(is_in_place($LIVE,     { registry => $REG_EMPTY, realpath => $rp_id }), 0,
   'AC-5g: is_in_place=0 when registry has no anchor');

# §3 obs-4 verbatim vectors (registry fallback)
is(is_in_place('C:/foo/ccpraxis', { registry => { 'ccpraxis-local' => { source => { source => 'directory', path => 'C:/foo/ccpraxis/plugins' } } }, realpath => $rp_id }),
   1, 'AC-5/§3: is_in_place("C:/foo/ccpraxis", registry) → 1');
is(is_in_place('C:/foo/ccpraxis-selfhost', { registry => { 'ccpraxis-local' => { source => { source => 'directory', path => 'C:/foo/ccpraxis/plugins' } } }, realpath => $rp_id }),
   0, 'AC-5/§3: is_in_place("C:/foo/ccpraxis-selfhost", registry) → 0');

# =====================================================================
# AC-6 — canonicalization in is_in_place (backslash, trailing slash, lc drive, Unicode)
# =====================================================================

is(is_in_place('c:\\foo\\ccpraxis\\', { live_install_hint => $LIVE, realpath => $rp_id }), 1,
   'AC-6: is_in_place=1 for backslash/trailing-slash/lowercase-drive variant of live path');

my $REG_ANDRE = { 'ccpraxis-local' => { source => { source => 'directory', path => 'C:/Users/André/.claude/ccpraxis/plugins' } } };
is(is_in_place('c:\\Users\\André\\.claude\\ccpraxis\\', { registry => $REG_ANDRE, realpath => $rp_id }), 1,
   'AC-6: André Unicode backslash variant matches registry anchor');
is(canon_path('C:/Users/André/.claude/ccpraxis'), 'C:/Users/André/.claude/ccpraxis',
   'AC-6: canon_path is idempotent on already-canonical André path');

# =====================================================================
# AC-7 — selfhost_route → 'offer' for live in-place ccpraxis (hint anchor)
# =====================================================================

is(selfhost_route($LIVE, { live_install_hint => $LIVE, exists => $exists_live, realpath => $rp_id }),
   'offer', 'AC-7: selfhost_route="offer" for live in-place ccpraxis (identity via markers, in-place via hint)');

# =====================================================================
# AC-8 — selfhost_route → 'passthrough' when anchor is resolvable but ≠ project
# =====================================================================

is(selfhost_route($WORKTREE, { live_install_hint => $LIVE, exists => $exists_wt, realpath => $rp_id }),
   'passthrough', 'AC-8a: passthrough for ccpraxis worktree (identity yes, in-place no)');
is(selfhost_route($CLONE, { live_install_hint => $LIVE, exists => $exists_clone, realpath => $rp_id }),
   'passthrough', 'AC-8b: passthrough for clone (identity yes, ≠ hint)');
is(selfhost_route($FOREIGN, { live_install_hint => $LIVE, git_commondir => $git_commondir_none, exists => $exists_none, realpath => $rp_id }),
   'passthrough', 'AC-8c: passthrough for non-git non-ccpraxis project');
is(selfhost_route($FOREIGN, { live_install_hint => $LIVE, git_commondir => $git_commondir_foreign, exists => $exists_none, realpath => $rp_id }),
   'passthrough', 'AC-8d: passthrough for foreign git repo');

# =====================================================================
# AC-12 — FAIL-SAFE (CRIT-1): ccpraxis identity + NO anchor resolvable → offer
# =====================================================================

is(selfhost_route($CLONE, { registry => $REG_EMPTY, git_commondir => $git_commondir_none, exists => $exists_clone, realpath => $rp_id }),
   'offer', 'AC-12: fail-safe — ccpraxis-by-markers with NO hint and empty registry → offer (never silent passthrough)');
is(selfhost_route($LIVE, { git_commondir => $git_commondir_live, registry => $REG_EMPTY, exists => $exists_live, realpath => $rp_id }),
   'offer', 'AC-12b: fail-safe — live repo, empty registry, no hint → offer');

# =====================================================================
# AC-13 — POISON-IMMUNITY (HIGH-3): hint overrides a poisoned/wrong registry
# =====================================================================

is(is_in_place($LIVE, { live_install_hint => $LIVE, registry => $REG_POISON, realpath => $rp_id }), 1,
   'AC-13: is_in_place uses the hint, immune to a poisoned registry source.path');
is(selfhost_route($LIVE, { live_install_hint => $LIVE, registry => $REG_POISON, exists => $exists_live, realpath => $rp_id }),
   'offer', 'AC-13b: route=offer for live repo despite poisoned registry (hint wins)');

# =====================================================================
# AC-14 — abs_path SYMMETRY (HIGH-4): realpath-resolved equality
# =====================================================================

my $SHORT   = 'C:/PROGRA~1/ccpraxis';
my $LONG    = 'C:/Program Files/ccpraxis';
my $rp_map  = sub {
    my ($p) = @_;
    return 'C:/RESOLVED/ccpraxis' if $p eq $SHORT || $p eq canon_path($LONG);
    return $p;
};
is(is_in_place($SHORT, { live_install_hint => $LONG, realpath => $rp_map }), 1,
   'AC-14: is_in_place=1 when short-name project and hint realpath-resolve to the same dir');
is(is_in_place('C:/other/ccpraxis', { live_install_hint => $LONG, realpath => $rp_map }), 0,
   'AC-14b: is_in_place=0 when realpath resolutions differ');

# =====================================================================
# AC-9 — structural: launcher.pl wires selfhost_route after winify_path($PROJECT_PATH)
# =====================================================================

my $launcher = "$Bin/../../scripts/launcher.pl";
ok(-f $launcher, 'AC-9: launcher.pl is present') or BAIL_OUT('launcher missing');

open my $fh, '<', $launcher or BAIL_OUT("cannot open launcher.pl: $!");
my @lines = <$fh>;
close $fh;

my $winify_line_idx;
for my $i (0 .. $#lines) {
    if ($lines[$i] =~ /winify_path\(\s*\$PROJECT_PATH\s*\)/) { $winify_line_idx = $i; last; }
}
ok(defined $winify_line_idx, 'AC-9: found winify_path($PROJECT_PATH) line in launcher.pl')
    or BAIL_OUT("could not locate winify_path(\$PROJECT_PATH) in launcher.pl");

my $route_line_idx;
for my $i ($winify_line_idx + 1 .. $#lines) {
    if ($lines[$i] =~ /selfhost_route\s*\(/) { $route_line_idx = $i; last; }
}
ok(defined $route_line_idx, 'AC-9: selfhost_route( call exists after the winify_path line');

# The route call must pass a registry-independent live-install hint (§9.1)
my $route_passes_hint = 0;
if (defined $route_line_idx) {
    for my $i ($route_line_idx .. ($route_line_idx + 4 <= $#lines ? $route_line_idx + 4 : $#lines)) {
        $route_passes_hint = 1 if $lines[$i] =~ /live_install_hint/;
    }
}
ok($route_passes_hint, 'AC-9: launcher passes live_install_hint to selfhost_route (registry-independent anchor)');

my $has_prompt_selfhost = grep { /prompt_selfhost_action/ } @lines;
ok($has_prompt_selfhost, 'AC-9: launcher.pl references prompt_selfhost_action for the offer branch');

# =====================================================================
# AC-10 — selfhost_decline_outcome shape + structural decline abort
# =====================================================================

my $outcome = selfhost_decline_outcome({});
is(ref $outcome, 'HASH', 'AC-10: selfhost_decline_outcome returns a HASH ref');
is($outcome->{warn},   1, 'AC-10: decline outcome has warn=1');
is($outcome->{launch}, 0, 'AC-10: decline outcome has launch=0');
ok(defined $outcome->{message} && length $outcome->{message}, 'AC-10: decline outcome has a non-empty message');
like($outcome->{message}, qr/declin/i, 'AC-10: decline message mentions decline/declined');
like($outcome->{message}, qr/abort|not .* in.?place|self.?host/i, 'AC-10: decline message mentions abort or self-host context');

my ($stderr_after_route, $abort_after_route) = (0, 0);
if (defined $route_line_idx) {
    for my $i ($route_line_idx .. $#lines) {
        $stderr_after_route = 1 if $lines[$i] =~ /(?:print\s+STDERR|warn\s)/;
        $abort_after_route  = 1 if $lines[$i] =~ /(?:\bexit\b|\bdie\b)/;
        last if $lines[$i] =~ /system\s*\(\s*\$PODMAN\s*,\s*['"]start['"]/;
    }
}
ok($stderr_after_route, 'AC-10 structural: decline branch emits to STDERR before podman start');
ok($abort_after_route,  'AC-10 structural: decline branch aborts (exit/die) before podman start');

# =====================================================================
# AC-16 — NO shell interpolation in the git default (CRIT-2 RCE)
# =====================================================================

my $mod = "$Bin/../../scripts/CcpraxisSelfHost.pm";
open my $mfh, '<', $mod or BAIL_OUT("cannot open CcpraxisSelfHost.pm: $!");
my $src = do { local $/; <$mfh> };
close $mfh;

unlike($src, qr/qx\s*[\{\(\/'"][^\n]*git/, 'AC-16: module does NOT use qx{...} to run git (no shell)');
unlike($src, qr/`[^`\n]*git[^`\n]*`/,      'AC-16: module does NOT use backticks to run git (no shell)');
like($src,   qr/open\s*\(?[^\n;]*['"]-\|['"][^\n;]*['"]git['"]/,
     'AC-16: module uses list-form open(...,"-|",...,"git",...) to run git (no shell)');

# Behavioral canary: call the DEFAULT git seam with a payload path; a shell would
# execute the embedded command. List-form must pass it literally → no canary.
SKIP: {
    my $git_ok = 0;
    { local $ENV{MSYS2_ARG_CONV_EXCL} = '*'; $git_ok = 1 if system('git --version > /dev/null 2>&1') == 0; }
    skip 'git not available for RCE canary', 1 unless $git_ok;

    my $prev = getcwd();
    my $work = eval { tempdir(CLEANUP => 1) };
    skip 'could not make tempdir for RCE canary', 1 unless $work;
    chdir $work or skip 'could not chdir tempdir', 1;

    my $canary  = "PWNED_$$";
    my $payload = "evil`touch $canary`x";   # shell would create ./PWNED_<pid>
    # No git_commondir injected → default seam runs; registry defined so branch A fires.
    eval { is_ccpraxis_project($payload, { registry => $REG_OK, exists => $exists_none }) };
    my $pwned = -e "$work/$canary" ? 1 : 0;
    chdir $prev;
    is($pwned, 0, 'AC-16: default git seam does NOT execute an injected command from the path (RCE closed)');
}

# =====================================================================
# AC-17 — ENCODING (production André-path bug): live_install_dir must return
# UTF-8 BYTES, not JSON::PP-decoded wide chars, so it compares byte-equal to the
# filesystem/git form. Reproduces the real bug portably (no real repo needed).
# =====================================================================
{
    my $tmp = File::Temp->new(SUFFIX => '.json');
    binmode $tmp, ':raw';
    # é encoded as its UTF-8 bytes 0xC3 0xA9 (a byte string, utf8 flag off) —
    # exactly what a real known_marketplaces.json contains on disk.
    my $utf8_plugins = "C:/Users/Andr\x{c3}\x{a9}/ccpraxis/plugins";
    print $tmp '{"ccpraxis-local":{"source":{"source":"directory","path":"' . $utf8_plugins . '"}}}';
    $tmp->flush;
    my $lid = live_install_dir({ registry_path => $tmp->filename });
    is($lid, "C:/Users/Andr\x{c3}\x{a9}/ccpraxis",
       'AC-17: live_install_dir returns UTF-8 BYTES (é=0xC3 0xA9) matching the filesystem/git form, not JSON-decoded wide chars');
    ok(defined $lid && !utf8::is_utf8($lid),
       'AC-17b: live_install_dir result is a byte string (no utf8 flag) — comparable to git/fs byte paths');
}

# =====================================================================
# AC-18 — MARKER LOCATION (production bug): the content-marker branch must check
# plugins/.claude-plugin/marketplace.json (where the ccpraxis manifest actually
# lives), NOT the repo root.
# =====================================================================
is(is_ccpraxis_project('C:/x/repo', {
        git_commondir => sub { undef },
        exists => sub {
            my $p = shift;
            return 1 if $p eq 'C:/x/repo/plugins/.claude-plugin/marketplace.json';
            return 1 if $p eq 'C:/x/repo/plugins/sandbox/scripts/launcher.pl';
            return 0;
        },
    }), 1, 'AC-18: content markers under plugins/ identify ccpraxis (matches real repo layout)');
is(is_ccpraxis_project('C:/x/repo', {
        git_commondir => sub { undef },
        exists => sub {
            my $p = shift;
            # only a ROOT marketplace.json (the OLD wrong path) + the launcher
            return 1 if $p eq 'C:/x/repo/.claude-plugin/marketplace.json';
            return 1 if $p eq 'C:/x/repo/plugins/sandbox/scripts/launcher.pl';
            return 0;
        },
    }), 0, 'AC-18b: a root-only .claude-plugin/marketplace.json (wrong location) does NOT satisfy the marker check');

done_testing();
