#!/usr/bin/env perl
# platform: any
# 108 — the orphan reaper selects exactly what it should, and nothing else.
#
# Bug report 20260828-095201-7c1e: a perl.exe running a throwaway probe out of a
# session scratchpad was found alive NINE DAYS AND NINETEEN HOURS after its
# session had exited, parent gone, 0.016s of CPU burnt in total. Nothing
# recorded it, killed it, or swept for it. It was found by accident.

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

# ---------------------------------------------------------------------------
# AC10 -- macOS/Linux. The reaper was inert off Windows for three reasons, each
# pinned here: the temp root is claude-<uid>, an orphan is ADOPTED by pid 1
# (alive, so "parent gone" never held), and macOS ps has no etimes column.
# ---------------------------------------------------------------------------
{
    my $mac = "/usr/bin/perl /private/tmp/claude-501/-Users-x-Projects-ccpraxis/$UUID/scratchpad/probe.pl";
    is(ReapOrphans::scratchpad_session($mac), $UUID,
        'AC10: a macOS scratchpad under /private/tmp/claude-501/ is recognised');
    is(ReapOrphans::scratchpad_session("/usr/bin/perl /tmp/claudex/p/$UUID/scratchpad/x.pl"), undef,
        'AC10: ...but only claude or claude-<digits>, not any directory starting with claude');

    my @procs = (
        { pid => 1,    ppid => 0,    age => 999999, cmd => '/sbin/launchd' },
        { pid => 4242, ppid => 1,    age => 7200,   cmd => $mac },          # adopted by launchd
        { pid => 777,  ppid => 1,    age => 7200,   cmd => '/usr/libexec/logd' },
        { pid => 900,  ppid => 4242, age => 7200,   cmd => "sh /private/tmp/claude-501/p/$OTHER/scratchpad/live.sh" },
    );
    my $without = ReapOrphans::select_orphans(\@procs, min_age => 3600);
    is(scalar @$without, 0, 'AC10: without the reparented set, an orphan adopted by pid 1 looks parented (the old darwin behaviour)');
    my $with = ReapOrphans::select_orphans(\@procs, min_age => 3600, reparented => { 1 => 1 });
    is_deeply([ map { $_->{pid} } @$with ], [4242], 'AC10: with pid 1 as the adopter, exactly the adopted scratchpad process is selected');
    my $young = ReapOrphans::select_orphans(\@procs, min_age => 9999, reparented => { 1 => 1 });
    is(scalar @$young, 0, 'AC10: the age floor still applies to an adopted process');
    my $mine = ReapOrphans::select_orphans(\@procs, min_age => 3600, reparented => { 1 => 1 }, session_id => $UUID);
    is(scalar @$mine, 0, 'AC10: --session-id still excludes an adopted process of the live session');

    is(ReapOrphans::parse_etime('05:07'), 307, 'AC10: etime mm:ss');
    is(ReapOrphans::parse_etime('1:00:00'), 3600, 'AC10: etime hh:mm:ss');
    is(ReapOrphans::parse_etime('08-12:29:06'), 8 * 86400 + 12 * 3600 + 29 * 60 + 6, 'AC10: etime dd-hh:mm:ss');
    is(ReapOrphans::parse_etime('/sbin/launchd'), undef, 'AC10: anything else is unknown age, never old');

    open my $fh, '<', $SCRIPT or BAIL_OUT("cannot read $SCRIPT");
    my $src = do { local $/; <$fh> };
    close $fh;
    like($src, qr/reparented\s*=>\s*\(\$\^O\s*=~\s*\/\^\(MSWin32\|cygwin\|msys\)\$\/\s*\?\s*\{\}\s*:\s*\{\s*1\s*=>\s*1\s*\}\s*\)/,
        'AC10: the CLI treats pid 1 as the adopter off Windows only (Windows keeps the dead parent\'s pid)');
    like($src, qr/\$\^O ne 'darwin'.*?etimes=/s,
        'AC10: darwin never trusts the etimes query (macOS ps prints the other columns anyway)');
}

# ===========================================================================
# THE PID NAMESPACE. Bug 20260917-033101-c455.
#
# enumerate_windows collects pids from `Get-CimInstance Win32_Process`, which are
# WINDOWS pids. perl's kill(), getppid() and $$ under Git-for-Windows are MSYS
# pids -- different numbers for the same process (`ps -W` prints both columns).
# Crossing them does not error; it answers "no such process", which reads as a
# real answer.
#
# The old kill block used perl `kill(0, $winpid)` to VERIFY a taskkill. That is
# false for every live Windows process, so $ok became 1 unconditionally: EVERY
# KILL REPORTED SUCCESS and @failed could not be populated. It was found after
# two launchers survived 37 hours on this host and the reaping story could not
# be trusted either way.
#
# These are SOURCE assertions, not behavioural ones, for the reason this file
# states at the top: a test for a reaper that actually reaps is a test that can
# take out the operator's own work.
# ===========================================================================
{
    open my $ns_fh, '<', $SCRIPT or BAIL_OUT("cannot read $SCRIPT");
    my $src = do { local $/; <$ns_fh> };
    close $ns_fh;

    # COMMENTS STRIPPED FIRST. The script DESCRIBES the removed kill(0,...) at
    # length in the comment explaining why it went, so a raw scan finds the very
    # string it is asserting is absent. Same non-comment scan lane-routing.t and
    # the retired hook-payload-read-bound coverage use -- forgetting it here cost a red run.
    my $code = $src;
    $code =~ s/^[ \t]*#[^\n]*$//mg;

    my $probe = qr/kill\(\s*0\s*,/;

    unlike($code, $probe,
        'NS1: no kill(0,...) liveness probe survives -- that is the MSYS-namespace check that made every kill report success');

    like($src, qr/sub terminate_pid/,
        'NS2: killing goes through terminate_pid, so exactly one place chooses the namespace');

    # \r?\n, because this tree carries CRLF files and a bare \n\} silently ran
    # past the sub and swallowed the rest of the script -- which is why NS3
    # passed (something matched) while NS4 and NS5 failed against it.
    # The CAPTURE GROUP is load-bearing: a successful match with no group
    # returns (1) in list context, so `my ($body) = ...` silently bound the
    # string "1" and NS4/NS5 then asserted against it. NS3 passed throughout,
    # because "1" is defined -- an existence check cannot notice this.
    my ($body) = $src =~ /(sub terminate_pid.*?\r?\n\})/s;
    ok(defined $body, 'NS3: terminate_pid has an extractable body');
    like($body, qr/taskkill/,
        'NS4: on Windows it kills with taskkill, which speaks WINPID -- the namespace enumerate_windows collected from');
    like($body, qr/kill\('TERM'/,
        'NS5: ...and keeps perl kill(TERM) for POSIX, where the pid namespaces do not split');

    like($src, qr/\bmy\s+%still\s*=\s*map\b[^;]*\benumerate\(\)/,
        'NS6: verification RE-ENUMERATES from the same source the candidates came from, so it cannot disagree with itself about namespaces');
    # [^}]* cannot span the real line, because the subscript itself contains a
    # brace: `$still{ $c->{pid} } ? \@failed : \@killed`.
    like($code, qr/\$still\{.*?\?\s*\\\@failed\s*:\s*\\\@killed/s,
        'NS7: a pid still present after the kill is reported FAILED -- the assertion the old design was incapable of making');

    # COUNTER-FIXTURE. NS1 is an `unlike`, and an unlike whose pattern matches
    # nothing passes for free. This proves the pattern does match the exact line
    # it was written to forbid.
    my $old_line = 'my $ok = (kill(0, $c->{pid}) ? 0 : 1);';
    like($old_line, $probe,
        'NS8: COUNTER-FIXTURE -- the NS1 pattern really does match the removed line, so NS1 is not vacuous');
}

done_testing();
