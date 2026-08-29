#!/usr/bin/env perl
# 38 — the orphan reaper selects exactly what it should, and nothing else.
#
# Bug report 20260828-095201-7c1e: a perl.exe running a throwaway probe out of a
# session scratchpad was found alive NINE DAYS AND NINETEEN HOURS after its
# session had exited, parent gone, 0.016s of CPU burnt in total. Nothing
# recorded it, killed it, or swept for it. It was found by accident.
#
# THIS TEST NEVER SPAWNS OR KILLS A PROCESS. scripts/reap-orphans.pl is split
# into a pure selection library and a `unless (caller)` CLI precisely so the
# oracle can feed it synthetic process lists. A test for a process reaper that
# actually reaps is a test that can take out something it did not mean to --
# and this suite runs unattended, in parallel, on the operator's own machine.
#
# The assertions that matter are the NEGATIVE ones. Failing to reap a leak costs
# 11 MB; reaping something live costs the operator their work. So every reason a
# process must be spared gets its own case, and each is written so it fails if
# that single guard is removed.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $SCRIPT = "$Bin/../../../../scripts/reap-orphans.pl";
ok(-f $SCRIPT, 'reap-orphans.pl exists') or BAIL_OUT('script missing');

# Loading must NOT run the CLI. If the `unless (caller)` guard were dropped,
# requiring this file would enumerate every process on the machine.
require $SCRIPT;
ok(defined &ReapOrphans::select_orphans, 'the selection library loads without running the CLI');

my $UUID  = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
my $OTHER = '11111111-2222-4333-8444-555555555555';
sub pad {
    my ($uuid, $file) = @_;
    $file //= 'probe.pl';
    return qq{"C:\\Program Files\\Git\\usr\\bin\\perl.exe" }
         . qq{C:/Users/X/AppData/Local/Temp/claude/C--Development-ccpraxis/$uuid/scratchpad/$file};
}

# ---------------------------------------------------------------------------
# AC1 -- the report's own process is selected.
# ---------------------------------------------------------------------------
{
    my @procs = (
        { pid => 87244, ppid => 90520, age => 9 * 86400 + 19 * 3600, cmd => pad($UUID, 'probe4.pl') },
        # 90520 is deliberately ABSENT from the list: that is what "parent gone" is.
        { pid => 1,     ppid => 0,     age => 999999, cmd => 'init' },
    );
    my $got = ReapOrphans::select_orphans(\@procs, min_age => 3600);
    is(scalar @$got, 1, 'AC1: the nine-day orphan is selected');
    is($got->[0]{pid}, 87244, 'AC1: ...and it is the right process');
    is($got->[0]{session}, $UUID, 'AC1: ...tagged with the session it belonged to');
}

# ---------------------------------------------------------------------------
# AC2 -- A LIVE PARENT SPARES IT. This is the load-bearing guard: every process
# of a running session has a live parent, so without this the reaper would kill
# the work of whoever is using the machine.
# ---------------------------------------------------------------------------
{
    my @procs = (
        { pid => 200, ppid => 100, age => 86400, cmd => pad($UUID) },
        { pid => 100, ppid => 1,   age => 86400, cmd => 'claude' },   # parent ALIVE
    );
    my $got = ReapOrphans::select_orphans(\@procs, min_age => 0);
    is(scalar @$got, 0, 'AC2: a process whose parent is still alive is NEVER selected');
}

# ---------------------------------------------------------------------------
# AC3 -- the age floor.
# ---------------------------------------------------------------------------
{
    my @procs = ({ pid => 200, ppid => 999, age => 60, cmd => pad($UUID) });
    is(scalar @{ ReapOrphans::select_orphans(\@procs, min_age => 3600) }, 0,
        'AC3: a young orphan is spared (it may still be exiting cleanly)');
    is(scalar @{ ReapOrphans::select_orphans(\@procs, min_age => 30) }, 1,
        'AC3: ...and is selected once past the floor');
}

# ---------------------------------------------------------------------------
# AC4 -- UNKNOWN AGE IS NOT OLD AGE. A platform that cannot report a start time
# must not have every match treated as ancient; undef means "do not know", and
# the safe reading of "do not know" is "leave it".
# ---------------------------------------------------------------------------
{
    my @procs = ({ pid => 200, ppid => 999, age => undef, cmd => pad($UUID) });
    is(scalar @{ ReapOrphans::select_orphans(\@procs, min_age => 0) }, 0,
        'AC4: a process with an unknown start time is spared, even at min_age 0');
}

# ---------------------------------------------------------------------------
# AC5 -- the current session is excluded outright.
# ---------------------------------------------------------------------------
{
    my @procs = (
        { pid => 200, ppid => 999, age => 86400, cmd => pad($UUID)  },
        { pid => 201, ppid => 999, age => 86400, cmd => pad($OTHER) },
    );
    my $got = ReapOrphans::select_orphans(\@procs, min_age => 0, session_id => $UUID);
    is(scalar @$got, 1, 'AC5: --session-id excludes its own session');
    is($got->[0]{session}, $OTHER, 'AC5: ...and leaves other sessions selectable');

    # Case-insensitively: a uuid rendered in a different case is the same session.
    my $up = ReapOrphans::select_orphans(\@procs, min_age => 0, session_id => uc $UUID);
    is(scalar @$up, 1, 'AC5: the session match is case-insensitive');
}

# ---------------------------------------------------------------------------
# AC6 -- the reaper's own ancestry is excluded, so it cannot kill the session
# running it.
# ---------------------------------------------------------------------------
{
    my @procs = ({ pid => 200, ppid => 999, age => 86400, cmd => pad($UUID) });
    is(scalar @{ ReapOrphans::select_orphans(\@procs, min_age => 0, self => { 200 => 1 }) }, 0,
        'AC6: a pid in the self set is never selected');
}

# ---------------------------------------------------------------------------
# AC7 -- ONLY SCRATCHPAD PROCESSES. The reaper is scoped to session debris; an
# ordinary orphan (a daemon, a detached editor, anything the user backgrounded
# on purpose) is none of its business.
# ---------------------------------------------------------------------------
{
    my @procs = (
        { pid => 300, ppid => 999, age => 86400, cmd => 'perl /home/me/server.pl' },
        { pid => 301, ppid => 999, age => 86400, cmd => 'nginx: master process' },
        { pid => 302, ppid => 999, age => 86400, cmd => 'perl C:/tmp/claude/proj/not-a-uuid/scratchpad/x.pl' },
        { pid => 303, ppid => 999, age => 86400, cmd => "perl C:/tmp/claude/proj/$UUID/notscratch/x.pl" },
    );
    is(scalar @{ ReapOrphans::select_orphans(\@procs, min_age => 0) }, 0,
        'AC7: non-scratchpad orphans are ignored, including near-miss paths');
}

# ---------------------------------------------------------------------------
# AC8 -- totality. This runs on whatever a platform hands back; malformed rows
# must not kill the sweep, because a die here means the reaper stops running at
# all and the leak silently resumes.
# ---------------------------------------------------------------------------
{
    is_deeply(ReapOrphans::select_orphans(undef), [], 'AC8: undef input yields no candidates');
    is_deeply(ReapOrphans::select_orphans([]),    [], 'AC8: an empty list yields no candidates');
    my $mixed = ReapOrphans::select_orphans(
        [ undef, 'not a hash', {}, { pid => 5, ppid => 999, age => 86400, cmd => pad($UUID) } ],
        min_age => 0);
    is(scalar @$mixed, 1, 'AC8: malformed rows are skipped without dying');
}

# ---------------------------------------------------------------------------
# AC9 -- both path separators. Windows reports backslashes; the same machine's
# Git-Bash perl reports forward slashes, and a real command line mixes them.
# ---------------------------------------------------------------------------
{
    my $backslashed = qq{perl.exe C:\\Users\\X\\AppData\\Local\\Temp\\claude\\proj\\$UUID\\scratchpad\\probe.pl};
    is(ReapOrphans::scratchpad_session($backslashed), $UUID,
        'AC9: a fully backslashed path is recognised');
    is(ReapOrphans::scratchpad_session(pad($UUID)), $UUID,
        'AC9: a forward-slash path is recognised');
    is(ReapOrphans::scratchpad_session('perl foo.pl'), undef,
        'AC9: an unrelated command yields no session');
}

done_testing();
