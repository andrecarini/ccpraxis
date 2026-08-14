#!/usr/bin/env perl
# 151-continuity-statusline-badge.t -- g01-explicit-continuity-arming, THE
# STATUSLINE BADGE: scripts/statusline.pl (repo root) -- NOT
# plugins/butler/scripts/bp-statusline.pl, which the live statusline never
# invokes (ledger correction, 2026-08-14).
#
# Spec: specs/g01-explicit-continuity-arming-spec.md SS2.6 (badge design),
# SS3 behaviors 16-18, SS4 AC-7/AC-8/AC-13. Written BLIND to any continuity
# code in scripts/statusline.pl -- it does not exist yet (0 references to
# session_id in the file, per the scout report).
#
# Scaffolding (make_tput/make_git/spew_raw/payload_for shape) is adapted from
# plugins/sandbox/tests/t/69-statusline-rebuild.t's own conventions for
# spawning this exact file, not copied wholesale -- only what this file's
# assertions need.
#
# NEVER points at real state: HOME and CCPRAXIS_CONTINUITY_ACTIVE_DIR are
# always File::Temp tempdirs; PATH is overridden to a shim dir so no real
# `git`/`tput` on this machine is ever consulted.
#
# Runs standalone: perl plugins/butler/tests/t/151-continuity-statusline-badge.t
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use JSON::PP qw(encode_json);

my $STATUSLINE = "$Bin/../../../../scripts/statusline.pl";

ok(-f $STATUSLINE, 'A1: scripts/statusline.pl exists') or BAIL_OUT('file missing');

# ---------------------------------------------------------------------------
# Scaffolding
# ---------------------------------------------------------------------------
sub spew_raw {
    my ($path, $bytes) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print {$fh} $bytes;
    close $fh;
    return $path;
}

my $SHIM_DIR = tempdir(CLEANUP => 1);
sub make_tput {
    my ($cols) = @_;
    spew_raw("$SHIM_DIR/tput", "#!/bin/sh\necho $cols\n");
    chmod 0755, "$SHIM_DIR/tput";
}
# A git shim that always reports "not a repo" (exit 1 on everything) -- this
# file's assertions are about the badge, not git rendering, so the simplest
# correct shim is one that never supplies a toplevel/branch.
sub make_git_absent {
    spew_raw("$SHIM_DIR/git", "#!/bin/sh\nexit 1\n");
    chmod 0755, "$SHIM_DIR/git";
}
make_tput(120);
make_git_absent();

my $TMPROOT = tempdir(CLEANUP => 1);

sub payload_for {
    my (%opt) = @_;
    my %p = (
        model          => { display_name => 'Claude Sonnet 5', id => 'claude-sonnet-5' },
        workspace      => { current_dir  => $opt{current_dir} // '/w/proj-alpha' },
        context_window => { used_percentage => 10, context_window_size => 200_000 },
    );
    $p{session_id} = $opt{session_id} if exists $opt{session_id};
    return \%p;
}

# run_statusline(\%payload, %opt) -> ($stdout_bytes, $rc)
# opt: cdir (CCPRAXIS_CONTINUITY_ACTIVE_DIR), home
sub run_statusline {
    my ($payload, %opt) = @_;
    my ($infh, $inpath) = tempfile(DIR => $TMPROOT);
    binmode $infh, ':raw';
    print {$infh} encode_json($payload);
    close $infh;

    local %ENV = %ENV;
    $ENV{PATH} = "$SHIM_DIR:$ENV{PATH}";
    $ENV{HOME} = $opt{home} // tempdir(CLEANUP => 1);
    if (defined $opt{cdir}) { $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $opt{cdir} }
    else                    { delete $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} }

    my $out = `timeout 20 perl "$STATUSLINE" < "$inpath" 2>/dev/null`;
    my $rc  = $? >> 8;
    return (defined($out) ? $out : '', $rc);
}

sub plant_marker {
    my ($cdir, $sid) = @_;
    mkdir $cdir unless -d $cdir;
    open my $fh, '>', "$cdir/$sid" or die "plant $cdir/$sid: $!";
    print {$fh} "agent 2026-01-01T00:00:00Z\n";
    close $fh;
}

# ===========================================================================
# B. AC-7 (behavior 16): a marker present for session S; stdin payload
#    carries "session_id":"S" -> WATCHED renders (byte-exact substring in
#    stdout).
# ===========================================================================
{
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-b-armed');
    my ($out, $rc) = run_statusline(payload_for(session_id => 'sess-b-armed'), cdir => $cdir);
    is($rc, 0, 'B1 setup: statusline.pl exits 0 for an armed session'."'".' payload');
    ok(index($out, 'WATCHED') >= 0,
       'B2 CANONICAL (-> AC-7/behavior 16): the WATCHED badge is a byte-exact substring of '
     . 'stdout when the payload'."'".'s session_id matches an armed marker');
}

# ===========================================================================
# C. AC-7 continued: the badge is PER-SESSION, not "is anything armed
#    anywhere". A marker exists only for S; the payload carries a DIFFERENT
#    session id T -> WATCHED does NOT render.
# ===========================================================================
{
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-c-armed-other');
    my ($out, $rc) = run_statusline(payload_for(session_id => 'sess-c-DIFFERENT-unarmed'), cdir => $cdir);
    is($rc, 0, 'C1 setup: exits 0');
    ok(index($out, 'WATCHED') < 0,
       'C2 CANONICAL (-> AC-7 negative): a DIFFERENT session id in the payload, even though '
     . 'SOME session is armed in the same registry directory, does NOT render WATCHED -- '
     . 'proves per-session lookup, not "is anything armed anywhere" (spec SS out-of-scope '
     . 'item, explicitly rejected)');
}

# ===========================================================================
# D. AC-8 (behavior 16, negative): no marker at all for the payload'"'"'s own
#    session_id -> no WATCHED badge, exit 0, no crash.
# ===========================================================================
{
    my $cdir = tempdir(CLEANUP => 1);   # empty registry
    my ($out, $rc) = run_statusline(payload_for(session_id => 'sess-d-never-armed'), cdir => $cdir);
    is($rc, 0, 'D1: exits 0 for an unarmed session with an otherwise-valid session_id');
    ok(index($out, 'WATCHED') < 0, 'D2: no WATCHED badge for an unarmed session');
}

# ===========================================================================
# E. AC-8 (behavior 16, graceful degradation): session_id OMITTED ENTIRELY --
#    still renders (>=2 rows, no crash), badge slot blank-padded (no WATCHED
#    substring), no reflow.
# ===========================================================================
{
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-e-irrelevant');  # some OTHER session is armed; must not leak in
    my %p = %{ payload_for() };
    delete $p{session_id};                      # explicitly absent, not merely empty-string
    ok(!exists $p{session_id}, 'E0 setup: payload has no session_id key at all');

    my ($out, $rc) = run_statusline(\%p, cdir => $cdir);
    is($rc, 0, 'E1 CANONICAL (-> AC-8/behavior 16): statusline.pl does not crash when '
             . 'session_id is entirely absent from the payload -- exit 0');
    my @rows = grep { length } split /\n/, $out;
    ok(scalar(@rows) >= 2,
       'E2 CANONICAL: still renders (at least) the two previously-fixed rows -- no reflow, '
     . 'no row dropped, when session_id is missing');
    ok(index($out, 'WATCHED') < 0,
       'E3 CANONICAL: no WATCHED badge renders when session_id is absent -- and critically, '
     . 'does NOT fall back to "something, somewhere, is armed" (an armed marker for a '
     . 'DIFFERENT, unrelated session exists in the same registry dir in this exact fixture) '
     . '-- the spec explicitly rejects that weaker fallback');
}

# ===========================================================================
# F. Row-width parity: an armed and an unarmed run at the SAME terminal width
#    produce line-1 outputs of the SAME row_cost budget class -- i.e. the
#    badge slot is fixed-width and reserved even when blank, not appended
#    only when present (spec SS2.6: "BADGE_SLOT = row_cost('WATCHED'),
#    fixed width, computed once"). Asserted as a relationship (byte-length of
#    line 1 differs by exactly the padding-vs-glyph delta, never by "badge
#    line is longer" in a way that would reflow the row), not as a pinned
#    absolute width -- honouring the no-whole-shape-pin discipline documented
#    in 69-statusline-rebuild.t's own header.
# ===========================================================================
{
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-f-armed');

    my ($out_armed)   = run_statusline(payload_for(session_id => 'sess-f-armed'), cdir => $cdir);
    my ($out_unarmed) = run_statusline(payload_for(session_id => 'sess-f-unarmed'), cdir => $cdir);

    my ($line1_armed)   = split /\n/, $out_armed;
    my ($line1_unarmed) = split /\n/, $out_unarmed;
    $line1_armed   //= ''; $line1_unarmed //= '';

    # SGR-stripped byte length, matching 69-statusline-rebuild.t's own
    # strip_sgr technique -- badges are rendered in colour, so raw length
    # comparison must first remove escape sequences.
    my $strip = sub { my $s = shift; $s =~ s/\033\[[^m]*m//g; return $s };
    my $bare_armed   = $strip->($line1_armed);
    my $bare_unarmed = $strip->($line1_unarmed);

    is(length($bare_armed), length($bare_unarmed),
       'F1 CANONICAL (-> SS2.6 fixed-width badge slot): line 1'."'".'s SGR-stripped byte '
     . 'length is IDENTICAL whether the badge renders WATCHED or blank padding -- the slot '
     . 'is reserved either way, so the row never reflows between armed and unarmed sessions');
}

# ===========================================================================
# G. AC-13 (cross-cutting, path-resolution parity) -- HALF of the three-way
#    parity: statusline.pl's own registry-path resolution must agree with
#    the documented default, (b) CCPRAXIS_CONTINUITY_ACTIVE_DIR override
#    wins over HOME. This file cannot invoke lib.sh (bash) or bp-continuity.pl
#    directly and stay a pure statusline oracle, so it asserts statusline.pl's
#    OWN observable behavior under both env states; the bash/perl agreement
#    itself is the OTHER half, covered by 149/150 resolving under the same
#    override and never under a HOME-only default in this suite.
# ===========================================================================
{
    # (a) CCPRAXIS_CONTINUITY_ACTIVE_DIR unset, HOME set to a fixture path:
    #     the badge must key off ${HOME}/.claude/ccpraxis/.continuity-active.
    my $home = tempdir(CLEANUP => 1);
    my $default_dir = "$home/.claude/ccpraxis/.continuity-active";
    mkdir_p_test($default_dir);
    plant_marker($default_dir, 'sess-g-home-default');

    my ($out, $rc) = run_statusline(
        payload_for(session_id => 'sess-g-home-default'),
        home => $home,
        # cdir deliberately NOT passed -- exercise the HOME-derived default
    );
    is($rc, 0, 'G1 setup: exits 0');
    ok(index($out, 'WATCHED') >= 0,
       'G2 CANONICAL (-> AC-13a): with CCPRAXIS_CONTINUITY_ACTIVE_DIR UNSET and HOME pointed '
     . 'at a fixture, the badge renders from a marker planted at the documented default path '
     . '${HOME}/.claude/ccpraxis/.continuity-active/<sid> -- proves statusline.pl'."'".'s own '
     . 'resolution matches lib.sh'."'".'s bp_continuity_active_dir default, not merely that '
     . 'an explicit override works');
}
{
    # (b) CCPRAXIS_CONTINUITY_ACTIVE_DIR SET, HOME set DIFFERENTLY: the
    #     override must win -- a marker at the HOME-default path must NOT be
    #     seen when the override points elsewhere.
    my $home = tempdir(CLEANUP => 1);
    my $home_default_dir = "$home/.claude/ccpraxis/.continuity-active";
    mkdir_p_test($home_default_dir);
    plant_marker($home_default_dir, 'sess-g2-should-not-be-seen');

    my $override_dir = tempdir(CLEANUP => 1);   # deliberately empty -- no marker here

    my ($out, $rc) = run_statusline(
        payload_for(session_id => 'sess-g2-should-not-be-seen'),
        home => $home, cdir => $override_dir,
    );
    is($rc, 0, 'G3 setup: exits 0');
    ok(index($out, 'WATCHED') < 0,
       'G4 CANONICAL (-> AC-13b): with CCPRAXIS_CONTINUITY_ACTIVE_DIR SET to an EMPTY '
     . 'override dir, a marker sitting at the HOME-derived default path is NOT consulted -- '
     . 'the override wins, matching lib.sh'."'".'s own override-first precedence exactly');
}

sub mkdir_p_test {
    my ($path) = @_;
    require File::Path;
    File::Path::make_path($path);
}

# ===========================================================================
# H. fix-batch F1: registry path resolution follows the SAME single rule as
#    lib.sh's bp_continuity_active_dir and bp-continuity.pl's
#    continuity_active_dir -- override, else $HOME, else $USERPROFILE. (a)
#    $HOME unset but $USERPROFILE set (a fixture tempdir, never the real
#    user profile) resolves under $USERPROFILE.
# ===========================================================================
{
    my $userprofile = tempdir(CLEANUP => 1);
    my $default_dir = "$userprofile/.claude/ccpraxis/.continuity-active";
    mkdir_p_test($default_dir);
    plant_marker($default_dir, 'sess-h-userprofile');

    my ($infh, $inpath) = tempfile(DIR => $TMPROOT);
    binmode $infh, ':raw';
    print {$infh} encode_json(payload_for(session_id => 'sess-h-userprofile'));
    close $infh;

    local %ENV = %ENV;
    $ENV{PATH} = "$SHIM_DIR:$ENV{PATH}";
    delete $ENV{HOME};
    $ENV{USERPROFILE} = $userprofile;
    delete $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
    my $out = `timeout 20 perl "$STATUSLINE" < "$inpath" 2>/dev/null`;
    my $rc  = $? >> 8;
    is($rc, 0, 'H1 setup: exits 0 with $HOME unset, $USERPROFILE set');
    ok(index($out, 'WATCHED') >= 0,
       'H2 CANONICAL (-> fix-batch F1): with $HOME unset and $USERPROFILE pointed at a fixture, '
     . 'the badge renders from a marker under $USERPROFILE/.claude/ccpraxis/.continuity-active '
     . '-- matches lib.sh'."'".'s and bp-continuity.pl'."'".'s documented fallback order '
     . 'exactly, closing the three-way divergence fix-batch F1 was filed to fix');
}

# ===========================================================================
# I. fix-batch F1 continued: (b) NEITHER $HOME NOR $USERPROFILE set (and no
#    override) -- the badge must degrade SAFELY to "not armed" (no WATCHED,
#    no crash, exit 0), never guess '.' (the pre-fix behavior) and never die.
#    This is the READ-side half of F1's rule: an unresolvable directory here
#    is truthful, because bp-continuity.pl could never have written a marker
#    under an unresolvable path either (it fails loudly instead).
# ===========================================================================
{
    my ($infh, $inpath) = tempfile(DIR => $TMPROOT);
    binmode $infh, ':raw';
    print {$infh} encode_json(payload_for(session_id => 'sess-i-unresolvable'));
    close $infh;

    local %ENV = %ENV;
    $ENV{PATH} = "$SHIM_DIR:$ENV{PATH}";
    delete $ENV{HOME};
    delete $ENV{USERPROFILE};
    delete $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
    my $out = `timeout 20 perl "$STATUSLINE" < "$inpath" 2>/dev/null`;
    my $rc  = $? >> 8;
    is($rc, 0, 'I1 CANONICAL (-> fix-batch F1): statusline.pl does not crash when '
             . 'CCPRAXIS_CONTINUITY_ACTIVE_DIR, $HOME and $USERPROFILE are all unset');
    ok(index($out, 'WATCHED') < 0,
       'I2 CANONICAL: badge renders unarmed (no WATCHED) rather than guessing \'.\' as a '
     . 'registry root -- the pre-fix fallback');
    my @rows = grep { length } split /\n/, $out;
    ok(scalar(@rows) >= 2, 'I3: still renders both rows -- no crash, no reflow');
}

done_testing();
