#!/usr/bin/env perl
# platform: any
# Immutable oracle for blueprint where-things-go, package 03-thread-sessions:
# Almanac::SessionLive, the one liveness helper (Decision 18 F5), covering
# AC4, AC11 and AC16 of specs/03-thread-sessions-spec.md section 4 (the
# thresholds, judge()'s decision table, butler_state_dir parity with
# BpHook::state_dir, orchestrator_live()'s flock probe, and the .about text).
#
# HOUSE PATTERN for not-yet-built code: Almanac::SessionLive.pm does not
# exist at all at the time this file is written. Every call is wrapped in
# eval{} so "Can't locate Almanac/SessionLive.pm" is a caught, reported
# failure for THIS assertion, never an abort of the whole file.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Fcntl qw(:flock);

BEGIN {
    my $dir = "$FindBin::Bin/../../scripts";
    $dir =~ s{\\}{/}g;
    unshift @INC, $dir;
}
(my $BUTLER_SCRIPTS = "$Bin/../../../butler/scripts") =~ s{\\}{/}g;
my $BPHOOK_PM = "$BUTLER_SCRIPTS/BpHook.pm";
ok(-f $BPHOOK_PM, 'precondition: BpHook.pm exists beside butler') or BAIL_OUT('BpHook.pm missing');
require $BPHOOK_PM unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;

my $SL_PM = "$Bin/../../scripts/Almanac/SessionLive.pm";
(my $SL_ABOUT = $SL_PM) =~ s/\.pm$/.pm.about/;

my $FILE_HOME = tempdir(CLEANUP => 1);
$FILE_HOME =~ s{\\}{/}g;
local $ENV{HOME}         = $FILE_HOME;
local $ENV{USERPROFILE}  = $FILE_HOME;
local $ENV{ALMANAC_HOME} = $FILE_HOME;
my $CFG = tempdir(CLEANUP => 1); $CFG =~ s{\\}{/}g;
local $ENV{CLAUDE_CONFIG_DIR} = $CFG;
my $BSD = tempdir(CLEANUP => 1); $BSD =~ s{\\}{/}g;
local $ENV{BUTLER_STATE_DIR} = $BSD;
delete local $ENV{CLAUDE_PROJECT_DIR};
delete local $ENV{CCPRAXIS_DATA_DIR};
delete local $ENV{CLAUDE_CODE_SESSION_ID};

sub load_sl { local $@; eval { require Almanac::SessionLive; 1 } or diag("load error: $@") }
my $SL_LOADS = load_sl();

ok(-f $SL_PM, 'Almanac/SessionLive.pm exists at plugins/almanac/scripts/Almanac/SessionLive.pm')
    or diag('not present yet; every assertion below is expected to fail for exactly that reason');

sub mk_transcript {
    my ($sid, $mtime, %o) = @_;
    my $dir = $o{dir} // "$CFG/projects/p";
    make_path($dir) unless -d $dir;
    my $path = "$dir/$sid.jsonl";
    open my $fh, '>', $path or die "fixture: cannot write $path: $!";
    print {$fh} "{}\n";
    close $fh;
    utime($mtime, $mtime, $path) if defined $mtime;
    return $path;
}

sub mk_arm_record {
    my ($sid, %f) = @_;
    my $dir = "$BSD/continuity/armed";
    make_path($dir) unless -d $dir;
    my $path = "$dir/$sid";
    open my $fh, '>', $path or die "fixture: cannot write $path: $!";
    require JSON::PP;
    print {$fh} JSON::PP->new->canonical->encode({ role => 'driver', at => '2026-01-01T00:00:00Z', %f });
    close $fh;
    return $path;
}

# =============================================================================
# AC4 -- thresholds and butler_state_dir parity.
# =============================================================================
SKIP: {
    skip 'AC4: Almanac::SessionLive not loadable', 10 unless $SL_LOADS;
    is($Almanac::SessionLive::IDLE_SECONDS, 3600, 'AC4: $IDLE_SECONDS == 3600');
    is($Almanac::SessionLive::ARMED_SECONDS, 46800, 'AC4: $ARMED_SECONDS == 46800');

    {
        local $ENV{BUTLER_STATE_DIR} = $BSD;
        is(Almanac::SessionLive::butler_state_dir(), BpHook::state_dir(),
            'AC4: butler_state_dir() matches BpHook::state_dir() under BUTLER_STATE_DIR set');
    }
    {
        local $ENV{BUTLER_STATE_DIR} = 'relative/path';
        is(Almanac::SessionLive::butler_state_dir(), BpHook::state_dir(),
            'AC4: butler_state_dir() matches BpHook::state_dir() under a RELATIVE BUTLER_STATE_DIR (both undef)');
    }
    {
        local $ENV{BUTLER_STATE_DIR};
        delete local $ENV{BUTLER_STATE_DIR};
        local $ENV{HOME} = $FILE_HOME;
        is(Almanac::SessionLive::butler_state_dir(), BpHook::state_dir(),
            'AC4: butler_state_dir() matches BpHook::state_dir() under BUTLER_STATE_DIR unset, HOME set');
    }
    {
        local $ENV{BUTLER_STATE_DIR};
        delete local $ENV{BUTLER_STATE_DIR};
        local $ENV{HOME};
        delete local $ENV{HOME};
        local $ENV{USERPROFILE} = $FILE_HOME;
        is(Almanac::SessionLive::butler_state_dir(), BpHook::state_dir(),
            'AC4: butler_state_dir() matches BpHook::state_dir() under HOME unset, USERPROFILE only');
    }

    # judge() fixture matrix (behaviour 6).
    my %cases;
    {
        my $t = mk_transcript('ACT1', time() - 60);
        my $v = eval { Almanac::SessionLive::judge(session => 'ACT1', transcript_path => $t, butler_present => 0) };
        is(ref($v) eq 'HASH' ? $v->{state} : "died: $@", 'alive', 'AC4: active (60s mtime) -> alive');
        is(ref($v) eq 'HASH' ? $v->{basis} : '?', 'active', 'AC4: active (60s mtime) -> basis active');
    }
    {
        my $t = mk_transcript('ARM1', time() - 2 * 3600);
        mk_arm_record('ARM1');
        my $v = eval { Almanac::SessionLive::judge(session => 'ARM1', transcript_path => $t, butler_present => 1) };
        is(ref($v) eq 'HASH' ? $v->{state} : "died: $@", 'alive', 'AC4: armed, 2h idle (within armed threshold) -> alive');
        is(ref($v) eq 'HASH' ? $v->{basis} : '?', 'armed', 'AC4: armed, 2h idle -> basis armed');
    }
    {
        my $t = mk_transcript('ARM2', time() - 14 * 3600);
        mk_arm_record('ARM2');
        my $v = eval { Almanac::SessionLive::judge(session => 'ARM2', transcript_path => $t, butler_present => 1) };
        is(ref($v) eq 'HASH' ? $v->{state} : "died: $@", 'dead', 'AC4: armed, 14h idle (past armed threshold) -> dead');
        is(ref($v) eq 'HASH' ? $v->{basis} : '?', 'armed-idle', 'AC4: armed, 14h idle -> basis armed-idle');
    }
    {
        my $t = mk_transcript('UNA1', time() - 30);
        my $v = eval { Almanac::SessionLive::judge(session => 'UNA1', transcript_path => $t, butler_present => 1) };
        is(ref($v) eq 'HASH' ? $v->{state} : "died: $@", 'alive', 'AC4: unarmed, active -> alive');
    }
    {
        my $t = mk_transcript('UNA2', time() - 2 * 3600);
        my $v = eval { Almanac::SessionLive::judge(session => 'UNA2', transcript_path => $t, butler_present => 1) };
        is(ref($v) eq 'HASH' ? $v->{state} : "died: $@", 'dead', 'AC4: unarmed, 2h idle -> dead (no arm record never excuses idleness)');
        is(ref($v) eq 'HASH' ? $v->{basis} : '?', 'idle', 'AC4: unarmed, 2h idle -> basis idle');
    }
    {
        # butler absent: an arm record on disk is irrelevant; judged by
        # activity alone.
        my $t = mk_transcript('BABS1', time() - 2 * 3600);
        mk_arm_record('BABS1');
        my $v = eval { Almanac::SessionLive::judge(session => 'BABS1', transcript_path => $t, butler_present => 0) };
        is(ref($v) eq 'HASH' ? $v->{state} : "died: $@", 'dead', 'AC4: butler absent, 2h idle (arm record ignored) -> dead');
        is(ref($v) eq 'HASH' ? $v->{basis} : '?', 'idle', 'AC4: butler absent, 2h idle -> basis idle (not armed-idle)');
    }
    {
        # /clear fixture: predecessor's old transcript is PRESENT but old;
        # presence never implies life, only mtime does.
        my $dir = "$CFG/projects/clearp";
        my $old = mk_transcript('CLROLD', time() - 2 * 3600, dir => $dir);
        my $new = mk_transcript('CLRNEW', time() - 5, dir => $dir);
        my $vold = eval { Almanac::SessionLive::judge(session => 'CLROLD', transcript_path => $old, butler_present => 0) };
        my $vnew = eval { Almanac::SessionLive::judge(session => 'CLRNEW', transcript_path => $new, butler_present => 0) };
        is(ref($vold) eq 'HASH' ? $vold->{state} : "died: $@", 'dead', 'AC4: /clear fixture -- old session (old mtime, transcript present) -> dead');
        is(ref($vnew) eq 'HASH' ? $vnew->{state} : "died: $@", 'alive', 'AC4: /clear fixture -- new session (fresh mtime) -> alive');
    }
    {
        # root visible but file missing.
        my $dir = "$CFG/projects/missingp";
        make_path($dir);
        my $v = eval { Almanac::SessionLive::judge(session => 'NOFILE1', transcript_path => "$dir/NOFILE1.jsonl", butler_present => 0) };
        is(ref($v) eq 'HASH' ? $v->{state} : "died: $@", 'dead', 'AC4: root visible, file missing -> dead');
        is(ref($v) eq 'HASH' ? $v->{basis} : '?', 'no-transcript', 'AC4: root visible, file missing -> basis no-transcript');
    }
    {
        # root invisible (a path whose grandparent directory never exists).
        my $invisible = "$FILE_HOME/no-such-mount/p/INVIS1.jsonl";
        my $v1 = eval { Almanac::SessionLive::judge(session => 'INVIS1', transcript_path => $invisible,
            since => time() - 3600, butler_present => 0) };
        is(ref($v1) eq 'HASH' ? $v1->{state} : "died: $@", 'alive', 'AC4: root invisible, since 1h -> alive');
        is(ref($v1) eq 'HASH' ? $v1->{basis} : '?', 'since', 'AC4: root invisible, since 1h -> basis since');

        my $v2 = eval { Almanac::SessionLive::judge(session => 'INVIS2', transcript_path => $invisible,
            since => time() - 14 * 3600, butler_present => 0) };
        is(ref($v2) eq 'HASH' ? $v2->{state} : "died: $@", 'dead', 'AC4: root invisible, since 14h -> dead');

        my $v3 = eval { Almanac::SessionLive::judge(session => 'INVIS3', transcript_path => $invisible, butler_present => 0) };
        is(ref($v3) eq 'HASH' ? $v3->{state} : "died: $@", 'unknown', 'AC4: root invisible, no since -> unknown');
        is(ref($v3) eq 'HASH' ? $v3->{basis} : '?', 'unresolved', 'AC4: root invisible, no since -> basis unresolved');
    }
    {
        # bad session id.
        my $v = eval { Almanac::SessionLive::judge(session => 'bad session!', butler_present => 0) };
        is(ref($v) eq 'HASH' ? $v->{state} : "died: $@", 'dead', 'AC4: a malformed session id -> dead');
        is(ref($v) eq 'HASH' ? $v->{basis} : '?', 'bad-session', 'AC4: a malformed session id -> basis bad-session');
    }
    {
        # is_alive() convenience wrapper.
        my $t = mk_transcript('ISALIVE1', time() - 60);
        is(eval { Almanac::SessionLive::is_alive(session => 'ISALIVE1', transcript_path => $t, butler_present => 0) }, 1,
            'AC4: is_alive() returns 1 for an active session');
        my $t2 = mk_transcript('ISDEAD1', time() - 2 * 3600);
        is(eval { Almanac::SessionLive::is_alive(session => 'ISDEAD1', transcript_path => $t2, butler_present => 0) }, 0,
            'AC4: is_alive() returns 0 for a dead session');
    }
}

# =============================================================================
# AC11 -- orchestrator liveness exactly while the marker flock is held.
# =============================================================================
SKIP: {
    skip 'AC11: Almanac::SessionLive not loadable', 3 unless $SL_LOADS;
    my $root = tempdir(CLEANUP => 1); $root =~ s{\\}{/}g;
    my $marker_dir = "$root/.ccpraxis-local-data/blueprints/bp/runs";
    make_path($marker_dir);
    my $marker = "$marker_dir/.orchestrator";
    open(my $fh, '>', $marker) or die $!;
    print {$fh} "12345\n";
    flock($fh, LOCK_EX);

    my $v1 = eval { Almanac::SessionLive::orchestrator_live(root => $root, blueprint => 'bp') };
    is($v1, 1, 'AC11: a held marker flock -> live') or diag("err: $@");

    flock($fh, LOCK_UN);
    close $fh;
    # marker file left behind, unflocked -- the "crashed orchestrator" case.
    my $v2 = eval { Almanac::SessionLive::orchestrator_live(root => $root, blueprint => 'bp') };
    is($v2, 0, 'AC11: an unflocked but present marker (released/crashed) -> dead');

    unlink $marker;
    my $v3 = eval { Almanac::SessionLive::orchestrator_live(root => $root, blueprint => 'bp') };
    is($v3, 0, 'AC11: no marker at all -> dead');
}

# =============================================================================
# AC16 -- SessionLive.pm.about text exact.
# =============================================================================
{
    ok(-f $SL_ABOUT, "SessionLive.pm.about exists at $SL_ABOUT")
        or diag('not present yet');
    SKIP: {
        skip 'AC16: .about file missing', 1 unless -f $SL_ABOUT;
        open my $fh, '<:raw', $SL_ABOUT or die $!;
        local $/;
        my $text = <$fh>;
        close $fh;
        is($text, "Session liveness: transcript activity within an idle threshold, or a longer armed threshold while an arm record exists\n",
            'AC16: SessionLive.pm.about is exactly the spec 2.2 one-liner');
    }
}

done_testing();
