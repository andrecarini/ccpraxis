#!/usr/bin/env perl
# platform: any
# Todo 20261002-125337-de8b0000, session half: Almanac::SessionLive joined a
# utf8-FLAGGED session id (what Almanac::Record hands back for a thread's
# owner_id, even when pure ASCII) into raw-byte paths rooted under a non-ASCII
# profile directory. Perl upgrades the raw bytes as Latin-1 ("C3 A9" ->
# "C3 83 C2 A9"), so the transcript, the arm record and the subagents dir all
# went missing and a live session read dead. orchestrator_live's half of the
# same bug is covered by orchestrator-live-nonascii.t.
#
# Fixture: a tempdir with a RAW two-byte UTF-8 segment (\xC3\xA9), so the bug
# reproduces on any host, not only one whose profile path is non-ASCII.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp ();
use File::Spec ();
use File::Path qw(make_path);
use Encode ();

BEGIN {
    my $dir = "$FindBin::Bin/../../scripts";
    $dir =~ s{\\}{/}g;
    unshift @INC, $dir;
}

my $base = File::Temp::tempdir(DIR => File::Spec->tmpdir, CLEANUP => 1);
$base =~ s{\\}{/}g;
my $home = "$base/Andr\xC3\xA9-home";
make_path("$home/.claude/projects/p1");
make_path("$home/.claude/butler-state/continuity/armed");

local $ENV{HOME}         = $home;
local $ENV{USERPROFILE}  = $home;
local $ENV{ALMANAC_HOME} = $home;
delete local $ENV{CLAUDE_CONFIG_DIR};
delete local $ENV{BUTLER_STATE_DIR};
delete local $ENV{CLAUDE_PROJECT_DIR};
delete local $ENV{CCPRAXIS_DATA_DIR};
delete local $ENV{CLAUDE_CODE_SESSION_ID};

require Almanac::SessionLive;

my $sid_raw  = 'nonascii-sess-1';
my $sid_flag = Encode::decode('UTF-8', $sid_raw);
ok(!utf8::is_utf8($home),    'precondition: home is raw bytes');
ok(utf8::is_utf8($sid_flag), 'precondition: flagged sid is utf8-flagged');

sub touch {
    my ($p, $mtime) = @_;
    open my $fh, '>', $p or die "fixture: cannot write $p: $!";
    print {$fh} "{}\n";
    close $fh;
    utime $mtime, $mtime, $p if defined $mtime;
}

my $now   = time;
my $tdir  = "$home/.claude/projects/p1";
my $tpath = "$tdir/$sid_raw.jsonl";

# --- find_transcript / fresh transcript -------------------------------------
touch($tpath, $now);
for my $case ([raw => $sid_raw], [flagged => $sid_flag]) {
    my ($label, $sid) = @$case;
    my ($found) = Almanac::SessionLive::find_transcript($sid);
    is($found, $tpath, "find_transcript finds the transcript ($label sid)");
    my $v = Almanac::SessionLive::judge(session => $sid, butler_present => 0, now => $now);
    is($v->{state}, 'alive', "judge: fresh transcript is alive ($label sid)")
        or diag("basis=$v->{basis}");
}

# --- arm record: idle 2h, armed -> alive/armed -------------------------------
touch($tpath, $now - 7200);
touch("$home/.claude/butler-state/continuity/armed/$sid_raw");
for my $case ([raw => $sid_raw], [flagged => $sid_flag]) {
    my ($label, $sid) = @$case;
    ok(defined Almanac::SessionLive::arm_record($sid, butler_present => 1),
        "arm_record finds the arm file ($label sid)");
    my $v = Almanac::SessionLive::judge(session => $sid, butler_present => 1, now => $now,
        transcript_path => Encode::decode('UTF-8', $tpath));
    is("$v->{state}/$v->{basis}", 'alive/armed', "judge: armed + 2h idle is alive/armed ($label sid)");
}
unlink "$home/.claude/butler-state/continuity/armed/$sid_raw";

# --- subagents dir widens last activity --------------------------------------
make_path("$tdir/$sid_raw/subagents");
touch("$tdir/$sid_raw/subagents/agent-1.jsonl", $now);
for my $case ([raw => $sid_raw], [flagged => $sid_flag]) {
    my ($label, $sid) = @$case;
    my $v = Almanac::SessionLive::judge(session => $sid, butler_present => 0, now => $now,
        transcript_path => $tpath);
    is("$v->{state}/$v->{basis}", 'alive/active',
        "judge: a fresh subagent transcript keeps an idle session alive ($label sid)");
}

done_testing();
