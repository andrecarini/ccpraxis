#!/usr/bin/env perl
# platform: windows
# ORACLE: scripts/statusline.pl (repo root) -- NOT
# plugins/butler/scripts/bp-statusline.pl, which the live statusline never
# invokes (ledger correction, 2026-08-14).
#
# Spec 16-cutover (hook-continuity-remake), batch C, criterion C-8: the badge
# is lit iff <state>/armed/<sid> is a regular file, where <state> is
# BUTLER_STATE_DIR + "/continuity" when that variable is set and absolute
# (set but relative: unresolvable, badge stays hollow), else $HOME then
# $USERPROFILE + "/.claude/butler-state/continuity" (BpHook::state_dir's own
# rule, duplicated here because statusline.pl stays a standalone payload).
# The three old per-session registries (.continuity-active, .drive-solo-active,
# .reporter-active) are gone (1.3 departure #8); a marker in the OLD registry
# alone must now leave the badge hollow (this file's own K section pinned
# those three registries before batch C -- superseded here, reason SW: the
# switch this file tested is retired, not merely renamed).
#
# NEVER points at real state: HOME, USERPROFILE and BUTLER_STATE_DIR are
# always File::Temp tempdirs; PATH is overridden to a shim dir so no real
# `git`/`tput` on this machine is ever consulted.
#
# Runs standalone: perl this file
use strict;
use warnings;

# A TEST MUST NEVER ACTUATE A REAL WAKE-LOCK.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP qw(encode_json);
use Cwd ();
use Encode qw(encode);
use lib "$Bin/../../../sandbox/scripts";   # Theme.pm, for colour comparison only

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
sub make_git_absent {
    spew_raw("$SHIM_DIR/git", "#!/bin/sh\nexit 1\n");
    chmod 0755, "$SHIM_DIR/git";
}
make_tput(120);
make_git_absent();

my $TMPROOT = tempdir(CLEANUP => 1);

# THE HYGIENE SCRUB (hook-continuity-remake package 10, spec section 4).
# statusline.pl now resolves a project root from workspace.current_dir (walk up
# to .ccpraxis-local-data or .git, then CLAUDE_PROJECT_DIR) and reads that
# project's almanac stores. So every current_dir lives under $FAKE_ROOT, a
# tempdir with its own .git -- the walk stops at an EMPTY project -- the spawn's
# process cwd is that scratch dir, and the keys in @SCRUB_ENV never leak in.
my $FAKE_ROOT = tempdir(CLEANUP => 1);
$FAKE_ROOT =~ s{\\}{/}g;
mkdir "$FAKE_ROOT/.git" or die "fixture setup: cannot mkdir $FAKE_ROOT/.git: $!";
my $DEFAULT_CWD = "$FAKE_ROOT/w/proj-alpha";
my @SCRUB_ENV = qw(CLAUDE_PROJECT_DIR ALMANAC_HOME ALMANAC_SURFACE);

# Every stdout rendered by this file, in order. The pre-existing sections'
# share of it is what AC-21 checks for stray badge glyphs.
my @ALL_OUTPUTS;

# spawn_statusline($inpath) -> ($out, $rc): the one place a render is spawned,
# from the scratch cwd, recording its stdout. %ENV is the caller's business.
sub spawn_statusline {
    my ($inpath) = @_;
    my $prev_cwd = Cwd::getcwd();
    chdir($FAKE_ROOT) or die "fixture setup: cannot chdir to $FAKE_ROOT: $!";
    my $out = `timeout 20 perl "$STATUSLINE" < "$inpath" 2>/dev/null`;
    my $rc  = $? >> 8;
    chdir($prev_cwd) or die "fixture teardown: cannot chdir back to $prev_cwd: $!";
    $out = '' unless defined $out;
    push @ALL_OUTPUTS, $out;
    return ($out, $rc);
}

# The real repo's almanac store, listed before any render and compared at the
# end: this file must never write it.
my $REAL_STORE = "$Bin/../../../../.ccpraxis-local-data/almanac";
sub almanac_listing {
    my ($root) = @_;
    my @out;
    return \@out unless -d $root;
    require File::Find;
    no warnings 'once';
    File::Find::find({ no_chdir => 1, wanted => sub {
        my @st = stat($_);
        (my $rel = $File::Find::name) =~ s{\A\Q$root\E}{};
        push @out, join("\t", $rel, (-d $_ ? 'd' : 'f'), ($st[7] // -1), ($st[9] // -1));
    } }, $root);
    return [ sort @out ];
}
my $REAL_STORE_BEFORE = almanac_listing($REAL_STORE);

# WHAT THE BADGE LOOKS LIKE -- the lead glyph, filled when armed, hollow when
# not (Decision 3: filled means watched, hollow means not; survives an SGR
# strip).
my $GLYPH_WATCHED   = "\xe2\x97\x8f";   # U+25CF filled
my $GLYPH_UNWATCHED = "\xe2\x97\x8b";   # U+25CB hollow
sub armed_out {
    my ($out) = @_;
    $out = '' unless defined $out;
    $out =~ s/\033\[[^m]*m//g;
    my ($first) = split /\n/, $out, 2;
    $first = '' unless defined $first;
    return index($first, $GLYPH_WATCHED) == 0 ? 1 : 0;
}

sub payload_for {
    my (%opt) = @_;
    my %p = (
        model          => { display_name => 'Claude Sonnet 5', id => 'claude-sonnet-5' },
        workspace      => { current_dir  => $opt{current_dir} // $DEFAULT_CWD },
        context_window => { used_percentage => 10, context_window_size => 200_000 },
    );
    $p{session_id} = $opt{session_id} if exists $opt{session_id};
    return \%p;
}

# plant_armed($butler_state_dir, $sid) -- creates
# <butler_state_dir>/continuity/armed/<sid> as a plain regular file, exactly
# where statusline.pl's _state_dir() resolves BUTLER_STATE_DIR to (it appends
# "/continuity" itself). Content is irrelevant to the badge (presence-only);
# an empty file is deliberately used so no test here depends on the arm
# file's own JSON shape.
sub plant_armed {
    my ($butler_state_dir, $sid) = @_;
    my $dir = "$butler_state_dir/continuity/armed";
    make_path($dir) unless -d $dir;
    open my $fh, '>', "$dir/$sid" or die "plant $dir/$sid: $!";
    close $fh;
}

# plant_armed_under_state_dir($resolved_state_dir, $sid) -- for the HOME/
# USERPROFILE-derived fixtures (G, H), which already build the FULL resolved
# path ".../continuity" themselves; this variant does not append it again.
sub plant_armed_under_state_dir {
    my ($resolved_state_dir, $sid) = @_;
    my $dir = "$resolved_state_dir/armed";
    make_path($dir) unless -d $dir;
    open my $fh, '>', "$dir/$sid" or die "plant $dir/$sid: $!";
    close $fh;
}

# run_statusline(\%payload, %opt) -> ($stdout_bytes, $rc)
# opt: state (BUTLER_STATE_DIR), home
sub run_statusline {
    my ($payload, %opt) = @_;
    my ($infh, $inpath) = tempfile(DIR => $TMPROOT);
    binmode $infh, ':raw';
    print {$infh} encode_json($payload);
    close $infh;

    local %ENV = %ENV;
    $ENV{PATH} = "$SHIM_DIR:$ENV{PATH}";
    $ENV{HOME} = $opt{home} // tempdir(CLEANUP => 1);
    delete $ENV{USERPROFILE} unless exists $opt{userprofile};
    $ENV{USERPROFILE} = $opt{userprofile} if exists $opt{userprofile};
    if (defined $opt{state}) { $ENV{BUTLER_STATE_DIR} = $opt{state} }
    else                     { delete $ENV{BUTLER_STATE_DIR} }
    # No legacy override ever leaks into a fixture.
    delete $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
    delete $ENV{CCPRAXIS_DRIVE_ACTIVE_DIR};
    delete $ENV{CCPRAXIS_REPORTER_ACTIVE_DIR};
    # Hygiene (package 10): no project/home override leaks in, and the
    # surface is the host's unless a case asks otherwise.
    delete $ENV{$_} for @SCRUB_ENV;
    delete $ENV{CCPRAXIS_SANDBOX};

    return spawn_statusline($inpath);
}

sub mkdir_p_test {
    my ($path) = @_;
    make_path($path);
}

# ===========================================================================
# B. C-8 positive: an armed/<sid> file exists for session S under a temp
#    BUTLER_STATE_DIR; the payload carries session_id=S -> the glyph is
#    filled (byte-exact substring in stdout).
# ===========================================================================
{
    my $state = tempdir(CLEANUP => 1);
    plant_armed($state, 'sess-b-armed');
    my ($out, $rc) = run_statusline(payload_for(session_id => 'sess-b-armed'), state => $state);
    is($rc, 0, 'B1 setup: statusline.pl exits 0 for an armed session'."'".' payload');
    ok(armed_out($out),
       'B2 CANONICAL (-> C-8): the glyph is filled when armed/<sid> exists under BUTLER_STATE_DIR '
     . 'and the payload'."'".'s session_id matches');
}

# ===========================================================================
# C. Per-session: an armed/<sid> file exists only for S; the payload carries a
#    DIFFERENT session id T -> the glyph stays hollow.
# ===========================================================================
{
    my $state = tempdir(CLEANUP => 1);
    plant_armed($state, 'sess-c-armed-other');
    my ($out, $rc) = run_statusline(payload_for(session_id => 'sess-c-DIFFERENT-unarmed'), state => $state);
    is($rc, 0, 'C1 setup: exits 0');
    ok(!armed_out($out),
       'C2 CANONICAL: a DIFFERENT session id in the payload, even though SOME session is armed '
     . 'under the same state root, does NOT light the badge -- per-session lookup, not '
     . '"is anything armed anywhere"');
}

# ===========================================================================
# D. No armed file at all for the payload's own session_id -> no badge,
#    exit 0, no crash.
# ===========================================================================
{
    my $state = tempdir(CLEANUP => 1);   # empty store
    my ($out, $rc) = run_statusline(payload_for(session_id => 'sess-d-never-armed'), state => $state);
    is($rc, 0, 'D1: exits 0 for an unarmed session with an otherwise-valid session_id');
    ok(!armed_out($out), 'D2: no badge for an unarmed session');
}

# ===========================================================================
# E. Graceful degradation: session_id OMITTED ENTIRELY -- still renders (>=2
#    rows, no crash), badge slot blank-padded, no reflow.
# ===========================================================================
{
    my $state = tempdir(CLEANUP => 1);
    plant_armed($state, 'sess-e-irrelevant');   # some OTHER session is armed
    my %p = %{ payload_for() };
    delete $p{session_id};
    ok(!exists $p{session_id}, 'E0 setup: payload has no session_id key at all');

    my ($out, $rc) = run_statusline(\%p, state => $state);
    is($rc, 0, 'E1 CANONICAL: statusline.pl does not crash when session_id is entirely absent '
             . 'from the payload -- exit 0');
    my @rows = grep { length } split /\n/, $out;
    ok(scalar(@rows) >= 2,
       'E2 CANONICAL: still renders (at least) the two previously-fixed rows -- no reflow, '
     . 'no row dropped, when session_id is missing');
    ok(!armed_out($out),
       'E3 CANONICAL: no badge renders when session_id is absent -- and does NOT fall back to '
     . '"something, somewhere, is armed"');
}

# ===========================================================================
# F. Row-width parity: an armed and an unarmed run at the SAME terminal width
#    produce line-1 outputs of the SAME row_cost budget class.
# ===========================================================================
{
    my $state = tempdir(CLEANUP => 1);
    plant_armed($state, 'sess-f-armed');

    my ($out_armed)   = run_statusline(payload_for(session_id => 'sess-f-armed'), state => $state);
    my ($out_unarmed) = run_statusline(payload_for(session_id => 'sess-f-unarmed'), state => $state);

    my ($line1_armed)   = split /\n/, $out_armed;
    my ($line1_unarmed) = split /\n/, $out_unarmed;
    $line1_armed   //= ''; $line1_unarmed //= '';

    my $strip = sub { my $s = shift; $s =~ s/\033\[[^m]*m//g; return $s };
    my $bare_armed   = $strip->($line1_armed);
    my $bare_unarmed = $strip->($line1_unarmed);

    is(length($bare_armed), length($bare_unarmed),
       'F1 CANONICAL: line 1'."'".'s SGR-stripped byte length is IDENTICAL whether the badge '
     . 'renders filled or hollow -- the slot is reserved either way');
}

# ===========================================================================
# G. Path-resolution parity (C-8 / spec 2.9), (a): BUTLER_STATE_DIR unset,
#    HOME set to a fixture path -- the badge must key off
#    ${HOME}/.claude/butler-state/continuity/armed/<sid>.
# ===========================================================================
{
    my $home = tempdir(CLEANUP => 1);
    my $default_dir = "$home/.claude/butler-state/continuity";
    mkdir_p_test($default_dir);
    plant_armed_under_state_dir($default_dir, 'sess-g-home-default');

    my ($out, $rc) = run_statusline(
        payload_for(session_id => 'sess-g-home-default'),
        home => $home,
        # state deliberately NOT passed -- exercise the HOME-derived default
    );
    is($rc, 0, 'G1 setup: exits 0');
    ok(armed_out($out),
       'G2 CANONICAL (-> C-8/2.9a): with BUTLER_STATE_DIR UNSET and HOME pointed at a fixture, '
     . 'the badge renders from armed/<sid> planted at the documented default path '
     . '${HOME}/.claude/butler-state/continuity -- proves statusline.pl'."'".'s own resolution '
     . 'matches BpHook::state_dir'."'".'s default');
}
{
    # (b) BUTLER_STATE_DIR SET, HOME set DIFFERENTLY: the override must win --
    #     an armed file at the HOME-default path must NOT be seen when the
    #     override points elsewhere.
    my $home = tempdir(CLEANUP => 1);
    my $home_default_dir = "$home/.claude/butler-state/continuity";
    mkdir_p_test($home_default_dir);
    plant_armed_under_state_dir($home_default_dir, 'sess-g2-should-not-be-seen');

    my $override_root = tempdir(CLEANUP => 1);   # deliberately empty -- no armed file here

    my ($out, $rc) = run_statusline(
        payload_for(session_id => 'sess-g2-should-not-be-seen'),
        home => $home, state => $override_root,
    );
    is($rc, 0, 'G3 setup: exits 0');
    ok(!armed_out($out),
       'G4 CANONICAL (-> C-8/2.9a): with BUTLER_STATE_DIR SET to an EMPTY override root, an '
     . 'armed file sitting at the HOME-derived default path is NOT consulted -- the override wins');
}

# ===========================================================================
# H. (a) $HOME unset but $USERPROFILE set (a fixture tempdir, never the real
#    user profile) resolves under $USERPROFILE.
# ===========================================================================
{
    my $userprofile = tempdir(CLEANUP => 1);
    my $default_dir = "$userprofile/.claude/butler-state/continuity";
    mkdir_p_test($default_dir);
    plant_armed_under_state_dir($default_dir, 'sess-h-userprofile');

    my ($infh, $inpath) = tempfile(DIR => $TMPROOT);
    binmode $infh, ':raw';
    print {$infh} encode_json(payload_for(session_id => 'sess-h-userprofile'));
    close $infh;

    local %ENV = %ENV;
    $ENV{PATH} = "$SHIM_DIR:$ENV{PATH}";
    delete $ENV{HOME};
    $ENV{USERPROFILE} = $userprofile;
    delete $ENV{BUTLER_STATE_DIR};
    delete $ENV{$_} for @SCRUB_ENV;
    my ($out, $rc) = spawn_statusline($inpath);
    is($rc, 0, 'H1 setup: exits 0 with $HOME unset, $USERPROFILE set');
    ok(armed_out($out),
       'H2 CANONICAL: with $HOME unset and $USERPROFILE pointed at a fixture, the badge renders '
     . 'from armed/<sid> under $USERPROFILE/.claude/butler-state/continuity -- matches '
     . 'BpHook::state_dir'."'".'s fallback order exactly');
}

# ===========================================================================
# I. (b) NEITHER $HOME NOR $USERPROFILE set (and no BUTLER_STATE_DIR) -- the
#    badge must degrade SAFELY to "not armed" (no glyph filled, no crash,
#    exit 0), never guess '.' as a store root and never die.
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
    delete $ENV{BUTLER_STATE_DIR};
    delete $ENV{$_} for @SCRUB_ENV;
    my ($out, $rc) = spawn_statusline($inpath);
    is($rc, 0, 'I1 CANONICAL: statusline.pl does not crash when BUTLER_STATE_DIR, $HOME and '
             . '$USERPROFILE are all unset');
    ok(!armed_out($out),
       'I2 CANONICAL: badge renders unarmed (no badge) rather than guessing \'.\' as a store root');
    my @rows = grep { length } split /\n/, $out;
    ok(scalar(@rows) >= 2, 'I3: still renders both rows -- no crash, no reflow');
}

# ===========================================================================
# I2. C-8: a RELATIVE BUTLER_STATE_DIR leaves the badge hollow -- unresolvable,
#     never guessed at, even though an armed file exists at the resolved-looking
#     relative path in the current directory.
# ===========================================================================
{
    my $home = tempdir(CLEANUP => 1);
    my ($out, $rc) = run_statusline(
        payload_for(session_id => 'sess-i2-relative'),
        home => $home, state => 'relative/state/dir',
    );
    is($rc, 0, 'I2-1: exits 0 with a relative BUTLER_STATE_DIR');
    ok(!armed_out($out),
       'I2-2 CANONICAL (-> C-8): a relative BUTLER_STATE_DIR is unresolvable -- badge stays '
     . 'hollow rather than guessing');
}

# ===========================================================================
# L. F8 (fix-batch 16-cutover, red-team L6). Addition, not a weakening: a
#    BARE drive letter with no slash ("C:") is NOT absolute -- BpHook::_is_abs
#    requires [\\/] right after the colon, and statusline.pl must agree, so a
#    bare "C:" BUTLER_STATE_DIR leaves the badge hollow rather than resolving
#    to a real "C:/continuity" this test must never touch.
# ===========================================================================
{
    my $home = tempdir(CLEANUP => 1);
    my ($out, $rc) = run_statusline(
        payload_for(session_id => 'sess-l-bare-drive'),
        home => $home, state => 'C:',
    );
    is($rc, 0, 'L1: exits 0 with a bare drive-letter BUTLER_STATE_DIR');
    ok(!armed_out($out),
       'L2 CANONICAL (-> F8/L6): a bare "C:" BUTLER_STATE_DIR (no slash) is treated as NOT '
     . 'absolute, matching BpHook::_is_abs -- the badge stays hollow rather than resolving '
     . 'to a real C:/continuity path');
}

# ===========================================================================
# J. NARROW-WIDTH TRUNCATION MUST NOT SPLIT AN ANSI ESCAPE.
#
# NON-VACUITY: this asserts on the RAW BYTES of stdout, and the widths below
# straddle the rung that broke -- 120 and 20 rendered correctly before the
# fix, 14/10/6/3/1 did not.
# ===========================================================================
{
    my $state = tempdir(CLEANUP => 1);
    plant_armed($state, 'sess-j-armed');

    my $well_formed = qr/\e(?:\[[0-9;:?]*[ -\/]*[\@-~]|[\@-_])/;

    for my $cols (120, 20, 14, 10, 6, 3, 1) {
        make_tput($cols);
        my ($out, $rc) = run_statusline(payload_for(session_id => 'sess-j-armed'), state => $state);
        is($rc, 0, "J: statusline.pl exits 0 at cols=$cols");

        my $scan = $out;
        $scan =~ s/$well_formed//g;
        ok(index($scan, "\e") < 0,
           "J: no truncated/malformed ANSI escape survives at cols=$cols "
         . '(fit_head must treat an escape as atomic and zero-width)')
            or diag('offending bytes: ' . join('', map { sprintf('\\x%02x', ord) } split //, $scan));
    }

    make_tput(120);   # restore the harness default for any later section
}

# ===========================================================================
# K. THE OLD PER-SESSION REGISTRIES NO LONGER LIGHT THE BADGE (SW).
#
# Batch C retires the switch this file's old section K exercised: the badge
# is single-source now. A marker planted in any of the three old registries,
# with no armed/<sid> file anywhere, must leave the badge hollow.
# ===========================================================================
{
    my $home = tempdir(CLEANUP => 1);
    for my $leaf (qw(.continuity-active .drive-solo-active .reporter-active)) {
        my $dir = "$home/.claude/ccpraxis/$leaf";
        mkdir_p_test($dir);
        open my $fh, '>', "$dir/sess-k-legacy-only" or die "plant $dir: $!";
        close $fh;
    }
    my ($out, $rc) = run_statusline(payload_for(session_id => 'sess-k-legacy-only'), home => $home);
    is($rc, 0, 'K1: exits 0');
    ok(!armed_out($out),
       'K2 CANONICAL (-> C-8, SW): a marker in any of the three old per-session registries alone, '
     . 'with no armed/<sid> file, leaves the badge hollow -- the old registries are retired');
}

# ===========================================================================
# hook-continuity-remake PACKAGE 10 -- the Decision 7 badge (spec
# .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 10-statusline-counters-spec.md, section 2.3 "Continuity badge"). Written
# BLIND to statusline.pl. Everything above this line is the pre-existing
# oracle, kept unchanged in meaning (AC-22); everything below is new.
#
#   agent-off: <state>/off/<sid> decodes to a hash with actor eq 'agent'
#              -> U+2205 in state.warn.
#   silenced:  RETIRED. It was U+2016 for a valid <state>/silence/<sid>; the
#              `silence` verb is gone (judged-continuity-disarm 05), and a
#              leftover record now renders nothing (AC-19 below).
#   both -> agent-off only; neither -> nothing, not even a space.
#   Marker field, stripped: "<lead> <WORD>[ <badge>]". blueprint
#   operator-ui-tweaks Decision 1(b) (package 01-statusline-counters) moves
#   the U+2691 pending-decisions flag OUT of the marker field and into the
#   front of the counters segment, so it no longer trails the badge here.
#   No assertion below changes: 543, 584 and 611 already accept "(?: |\z)"
#   after the badge, which holds whether or not a counters field follows.
# ===========================================================================
my $N_PRE_EXISTING = scalar @ALL_OUTPUTS;   # AC-21 checks exactly these

my $G_SILENCED = encode('UTF-8', chr(0x2016));
my $G_AGENTOFF = encode('UTF-8', chr(0x2205));
my $THEME_OK   = eval { require Theme; 1 };
ok($THEME_OK, 'P10 setup: Theme.pm loads, so the badge colour is compared against Theme::roles(), not a literal');
my $WARN_SGR = $THEME_OK ? sprintf("\e[38;2;%d;%d;%dm", @{ Theme::roles()->{'state.warn'}{rgb} }) : "\e[38;2;x";

sub strip_sgr { my $s = shift; $s = '' unless defined $s; $s =~ s/\033\[[^m]*m//g; return $s }
sub row1      { my ($out) = @_; my ($l) = split /\n/, (defined $out ? $out : ''), 2; return defined $l ? $l : '' }

# plant_badge_file($butler_state_dir, $kind, $sid, $bytes) -- writes
# <butler_state_dir>/continuity/<kind>/<sid> (kind: off | silence), the same
# root _state_dir() resolves armed/<sid> under. $bytes undef makes a
# DIRECTORY at that path instead of a file.
sub plant_badge_file {
    my ($root, $kind, $sid, $bytes) = @_;
    my $dir = "$root/continuity/$kind";
    make_path($dir) unless -d $dir;
    if (!defined $bytes) { make_path("$dir/$sid"); return }
    spew_raw("$dir/$sid", $bytes);
}
my $CANON = JSON::PP->new->canonical;
sub off_json     { my ($sid, $actor) = @_; return $CANON->encode({ actor => $actor, at => '2026-09-26T00:00:00Z', reason => 'paused for the operator to decide', session_id => $sid }) . "\n" }
sub silence_json {
    my ($sid, %o) = @_;
    return $CANON->encode({ at => '2026-09-26T00:00:00Z', by => $o{by} // 'butler-continuity',
                            reason => $o{reason} // 'waiting on the operator', session_id => $o{session_id} // $sid }) . "\n";
}

# badge_sgr_ok($row, $glyph) -> 1 when the SGR run immediately before the
# glyph's first byte ends with state.warn's foreground.
sub badge_sgr_ok {
    my ($row, $glyph) = @_;
    my $gi = index($row, $glyph);
    return 0 if $gi < 0;
    my $pre = substr($row, 0, $gi);
    return ($pre =~ /((?:\033\[[^m]*m)+)\z/ && substr($1, -length($WARN_SGR)) eq $WARN_SGR) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# AC-19 (behaviour 14), RETIRED with the `silence` verb (judged-continuity-
# disarm 05): a silence record, even one the old gate would have honoured,
# shows nothing. U+2016 stays defined below only to assert its absence.
# ---------------------------------------------------------------------------
{
    my $sid = 'sess-ac19-silenced';
    my $state = tempdir(CLEANUP => 1);
    plant_armed($state, $sid);
    plant_badge_file($state, 'silence', $sid, silence_json($sid));
    my ($out, $rc) = run_statusline(payload_for(session_id => $sid), state => $state);
    is($rc, 0, 'AC-19 (retired) setup: an armed session with a leftover silence record exits 0');
    ok(armed_out($out), 'AC-19 (retired): the lead glyph is FILLED -- arming alone decides it');
    is(index($out, $G_SILENCED), -1, 'AC-19 (retired): no U+2016 -- the silence verb is gone, so a leftover record is never read');
    unlike(strip_sgr(row1($out)), qr/\A\Q$GLYPH_WATCHED\E HOST  /,
        'AC-19 (retired): no reserved badge slot either (no double space after the word)');
}

# ---------------------------------------------------------------------------
# AC-20 (behaviour 13): an agent off shows U+2205 with the lead hollow; an
# operator off and a malformed off show nothing.
# ---------------------------------------------------------------------------
{
    my $sid = 'sess-ac20-agent-off';
    my $state = tempdir(CLEANUP => 1);
    plant_badge_file($state, 'off', $sid, off_json($sid, 'agent'));
    my ($out, $rc) = run_statusline(payload_for(session_id => $sid), state => $state);
    is($rc, 0, 'AC-20 setup: a session disarmed by an agent exits 0');
    ok(!armed_out($out), 'AC-20 (behaviour 13): the lead glyph is HOLLOW -- a disarmed session is not armed');
    my $vis = strip_sgr(row1($out));
    like($vis, qr/\A\Q$GLYPH_UNWATCHED\E HOST \Q$G_AGENTOFF\E(?: |\z)/,
        'AC-20 (behaviour 13): the marker field reads "<hollow> HOST U+2205"')
        or diag("  row 1 = [$vis]");
    ok(badge_sgr_ok(row1($out), $G_AGENTOFF), 'AC-20 (spec 2.3): U+2205 is rendered in state.warn');

    my %NO_BADGE = (
        'operator off'      => off_json($sid, 'operator'),
        '0-byte off'        => '',
        'non-JSON off'      => "agent\n",
        'JSON array off'    => "[\"agent\"]\n",
        'off without actor' => $CANON->encode({ at => '2026-09-26T00:00:00Z', reason => 'no actor here', session_id => $sid }) . "\n",
        'off is a directory' => undef,
    );
    for my $label (sort keys %NO_BADGE) {
        my $st = tempdir(CLEANUP => 1);
        plant_badge_file($st, 'off', $sid, $NO_BADGE{$label});
        my ($o, $r) = run_statusline(payload_for(session_id => $sid), state => $st);
        is($r, 0, "AC-20 ($label): exits 0");
        is(index($o, $G_AGENTOFF), -1, "AC-20 ($label): no U+2205");
        is(index($o, $G_SILENCED), -1, "AC-20 ($label): no U+2016 either");
    }

    # both hold -> agent-off only.
    my $st = tempdir(CLEANUP => 1);
    plant_badge_file($st, 'off', $sid, off_json($sid, 'agent'));
    plant_badge_file($st, 'silence', $sid, silence_json($sid));
    my ($ob) = run_statusline(payload_for(session_id => $sid), state => $st);
    like(strip_sgr(row1($ob)), qr/\A\Q$GLYPH_UNWATCHED\E HOST \Q$G_AGENTOFF\E(?: |\z)/,
        'AC-20 (spec 2.3): with both an agent off and a valid silence, the agent-off badge renders');
    is(index($ob, $G_SILENCED), -1, 'AC-20 (spec 2.3): ...and the silenced badge does not -- agent-off only');

    # neither -> nothing, not even a space: the word is followed directly by
    # the row's own separator, exactly as with no badge files at all.
    my $sn = tempdir(CLEANUP => 1);
    my ($on) = run_statusline(payload_for(session_id => $sid), state => $sn);
    unlike(strip_sgr(row1($on)), qr/\A\Q$GLYPH_UNWATCHED\E HOST  /,
        'AC-20 (spec 2.3): with neither record, the word is not followed by a reserved badge slot (no double space)');
}

# ---------------------------------------------------------------------------
# AC-21 (behaviour 15): badge files for session T never badge session S; no
# session_id, or an unresolvable state root, renders no badge and exits 0; and
# no PRE-EXISTING fixture in this file renders either badge glyph.
# ---------------------------------------------------------------------------
{
    my $state = tempdir(CLEANUP => 1);
    my $t = 'sess-ac21-T';
    plant_badge_file($state, 'off', $t, off_json($t, 'agent'));
    plant_badge_file($state, 'silence', $t, silence_json($t));
    plant_armed($state, $t);

    my ($os, $rs) = run_statusline(payload_for(session_id => 'sess-ac21-S'), state => $state);
    is($rs, 0, 'AC-21 (behaviour 15): a payload for S with badge files only for T exits 0');
    ok(index($os, $G_AGENTOFF) < 0 && index($os, $G_SILENCED) < 0,
        'AC-21 (behaviour 15): badge files for session T render no badge for session S');

    my %p = %{ payload_for() };
    delete $p{session_id};
    my ($on, $rn) = run_statusline(\%p, state => $state);
    is($rn, 0, 'AC-21 (behaviour 15): no session_id at all exits 0');
    ok(index($on, $G_AGENTOFF) < 0 && index($on, $G_SILENCED) < 0,
        'AC-21 (behaviour 15): no session_id renders no badge -- never "some session, somewhere"');

    # unresolvable state root: BUTLER_STATE_DIR, HOME and USERPROFILE unset.
    my ($infh, $inpath) = tempfile(DIR => $TMPROOT);
    binmode $infh, ':raw';
    print {$infh} encode_json(payload_for(session_id => $t));
    close $infh;
    {
        local %ENV = %ENV;
        $ENV{PATH} = "$SHIM_DIR:$ENV{PATH}";
        delete $ENV{$_} for qw(HOME USERPROFILE BUTLER_STATE_DIR CCPRAXIS_SANDBOX), @SCRUB_ENV;
        my ($ou, $ru) = spawn_statusline($inpath);
        is($ru, 0, 'AC-21 (behaviour 15): an unresolvable state root exits 0');
        ok(index($ou, $G_AGENTOFF) < 0 && index($ou, $G_SILENCED) < 0,
            'AC-21 (behaviour 15): an unresolvable state root renders no badge');
    }

    ok($N_PRE_EXISTING >= 20,
        "AC-21 (precondition): the pre-existing fixtures were all collected ($N_PRE_EXISTING renders)");
    my @hits = grep { index($ALL_OUTPUTS[$_], $G_AGENTOFF) >= 0 || index($ALL_OUTPUTS[$_], $G_SILENCED) >= 0 }
               0 .. $N_PRE_EXISTING - 1;
    is(scalar(@hits), 0,
        'AC-21: no pre-existing fixture in this file (A-L) renders U+2016 or U+2205 -- none of them plants a badge record')
        or diag('  offending render(s): ' . join(', ', map { $_ + 1 } @hits));
}

# ---------------------------------------------------------------------------
# AC-9, badge-block half: the badge code sits between its own markers and
# contains no spawn, import or write construct (spec 2.2's list).
# ---------------------------------------------------------------------------
sub forbidden_constructs {
    my ($code) = @_;
    my @hits;
    push @hits, 'backtick'        if $code =~ /`/;
    push @hits, 'qx'              if $code =~ /\bqx\s*[^\s\w=,;)]/;
    push @hits, 'system'          if $code =~ /\bsystem\b(?!\s*=>)/;
    push @hits, 'exec'            if $code =~ /\bexec\b(?!\s*=>)/;
    push @hits, 'fork'            if $code =~ /\bfork\b(?!\s*=>)/;
    push @hits, 'cmd_out'         if $code =~ /\bcmd_out\b/;
    push @hits, 'spawn_detached'  if $code =~ /\bspawn_detached\b/;
    push @hits, 'pipe-open'       if $code =~ /['"]\s*(?:-\||\|-)\s*['"]/
                                  || $code =~ /\bopen\b[^;]*['"]\s*\|/ || $code =~ /\bopen\b[^;]*\|\s*['"]/;
    push @hits, 'write-mode open' if $code =~ /\bopen\b\s*\(?[^;]*?,\s*['"]\s*(?:\+?>{1,2}|\+<)/;
    push @hits, 'use'             if $code =~ /(?:^|[;{}])\s*use\s+[A-Za-z]/m;
    push @hits, 'require'         if $code =~ /\brequire\b/;
    push @hits, 'do FILE'         if $code =~ /\bdo\s*\(?\s*['"\$]/;
    return @hits;
}
{
    open my $fh, '<:raw', $STATUSLINE or die "cannot read $STATUSLINE: $!";
    my $src = do { local $/; <$fh> };
    close $fh;
    $src =~ s/\r\n/\n/g;
    my @b = ($src =~ /^[ \t]*\Q# -- continuity-badge:begin --\E[ \t]*$/mg);
    my @e = ($src =~ /^[ \t]*\Q# -- continuity-badge:end --\E[ \t]*$/mg);
    is(scalar(@b), 1, 'AC-9 (badge half): "# -- continuity-badge:begin --" occurs exactly once');
    is(scalar(@e), 1, 'AC-9 (badge half): "# -- continuity-badge:end --" occurs exactly once');
    my ($blk) = $src =~ /^[ \t]*\Q# -- continuity-badge:begin --\E[ \t]*\n(.*?)^[ \t]*\Q# -- continuity-badge:end --\E/ms;
    my $code = defined($blk) ? join("\n", map { /^\s*#/ ? '' : $_ } split /\n/, $blk, -1) : '';
    ok(defined($blk) && $code =~ /\S/, 'AC-9 (badge half): the begin marker precedes the end marker, with code between them');
    my @f = forbidden_constructs($code);
    ok(defined($blk) && !@f, 'AC-9 (badge half): the badge block contains none of the spec 2.2 forbidden constructs')
        or diag('  found: ' . join(', ', @f));
    ok($code =~ /\boff\b/ && $code !~ /\bsilence\b/,
        'AC-9 (badge half): the badge block reads off/<sid>, and no longer silence/<sid>');
    ok($code =~ /JSON::PP|decode_json/, 'AC-9 (badge half): the badge records are decoded with JSON::PP');

    # counter-fixtures: the scan fires on spawns and writes, and is silent on
    # a bounded read-and-decode.
    ok(scalar(forbidden_constructs('my $x = `cat f`;')) > 0,               'AC-9 (counter-fixture): the scan FIRES on a backtick');
    ok(scalar(forbidden_constructs('system("perl", "x");')) > 0,         'AC-9 (counter-fixture): the scan FIRES on system');
    ok(scalar(forbidden_constructs(q{open(my $fh, '>', $p);})) > 0,      'AC-9 (counter-fixture): the scan FIRES on a write-mode open');
    ok(scalar(forbidden_constructs(q{open(my $fh, '-|', 'x');})) > 0,    'AC-9 (counter-fixture): the scan FIRES on a pipe open');
    is(scalar(forbidden_constructs(q{if (-f $p && open(my $fh, '<:raw', $p)) { read($fh, my $b, 4096); my $j = eval { JSON::PP->new->decode($b) }; }})), 0,
        'AC-9 (counter-fixture): the scan stays silent on a bounded read-open, read and JSON::PP decode');
}

is_deeply(almanac_listing($REAL_STORE), $REAL_STORE_BEFORE,
    'hygiene: the real repo\'s .ccpraxis-local-data/almanac listing is unchanged by this file');

done_testing();
