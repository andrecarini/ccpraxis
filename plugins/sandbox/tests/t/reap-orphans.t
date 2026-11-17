#!/usr/bin/env perl
# platform: any
# 108 — the orphan reaper selects exactly what it should, and nothing else.
#
# Bug report 20260828-095201-7c1e: a perl.exe running a throwaway probe out of a
# session scratchpad was found alive NINE DAYS AND NINETEEN HOURS after its
# session had exited, parent gone, 0.016s of CPU burnt in total. Nothing
# recorded it, killed it, or swept for it. It was found by accident.

# THIS TEST NEVER KILLS A PROCESS, AND SPAWNS ONLY THE REPORT-ONLY CLI AGAINST A
# STUB `ps` (AC12). scripts/reap-orphans.pl is split
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
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();

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

# ---------------------------------------------------------------------------
# AC11 -- AN ADOPTED PROCESS IS NOT PROOF THAT ITS SESSION IS OVER. On macOS and
# Linux a live session's detached job (nohup, setsid) is adopted by pid 1 the
# moment its launching shell exits, so "parent is pid 1" says nothing about
# the session. Another session's SessionStart sweep killed such jobs after an
# hour. An adopted candidate is now killed only when session_over says the
# owning session has ended; every way of failing to show that spares it.
# ---------------------------------------------------------------------------
{
    my $mac = "/usr/bin/perl /private/tmp/claude-501/-Users-x-Projects-ccpraxis/$UUID/scratchpad/probe.pl";
    my ($slug, $uuid) = ReapOrphans::scratchpad_owner($mac);
    is($slug, '-Users-x-Projects-ccpraxis', 'AC11: the scratchpad path yields the project slug');
    is($uuid, $UUID, 'AC11: ...and the session');
    is_deeply([ ReapOrphans::scratchpad_owner('perl x.pl') ], [], 'AC11: a non-scratchpad command yields nothing');

    my @procs = (
        { pid => 1,    ppid => 0,    age => 999999, cmd => '/sbin/launchd' },
        { pid => 4242, ppid => 1,    age => 7200,   cmd => $mac },             # adopted
        { pid => 4343, ppid => 9999, age => 7200,   cmd => pad($OTHER) },      # parent truly gone
    );
    my %by = map { $_->{pid} => $_ } @{ ReapOrphans::select_orphans(\@procs, min_age => 3600, reparented => { 1 => 1 }) };
    is($by{4242}{adopted}, 1, 'AC11: a candidate whose parent is the adopter is marked adopted');
    is($by{4242}{slug}, '-Users-x-Projects-ccpraxis', 'AC11: ...and carries its slug');
    is($by{4343}{adopted}, 0, 'AC11: a candidate whose parent is really gone is not');
    my %win = map { $_->{pid} => $_ } @{ ReapOrphans::select_orphans(\@procs, min_age => 3600) };
    is($win{4343}{adopted}, 0, 'AC11: with no adopter set (Windows) nothing is ever adopted');

    my $NOW   = 1_800_000_000;
    my %alive = (1 => 1, 500 => 1, 4242 => 1);
    my $live_other = [ { pid => 500, session_id => $OTHER } ];
    my %base = (uuid => $UUID, alive => \%alive, now => $NOW, min_idle => 3600);

    my @cases = (
        [ 'registry unreadable',            { registry => undef, transcript_mtime => $NOW - 86400 }, 0 ],
        [ 'registry has no live entry',     { registry => [ { pid => 777, session_id => $OTHER } ],
                                              transcript_mtime => $NOW - 86400 }, 0 ],
        [ 'a live process claims the session', { registry => [ @$live_other, { pid => 4242, session_id => uc $UUID } ],
                                              transcript_mtime => $NOW - 86400 }, 0 ],
        [ 'no transcript',                  { registry => $live_other, transcript_mtime => undef }, 0 ],
        [ 'transcript written recently',    { registry => $live_other, transcript_mtime => $NOW - 60 }, 0 ],
        [ 'dead claimant + idle transcript', { registry => [ @$live_other, { pid => 31337, session_id => $UUID } ],
                                              transcript_mtime => $NOW - 7200 }, 1 ],
        [ 'unclaimed + idle transcript',    { registry => $live_other, transcript_mtime => $NOW - 3600 }, 1 ],
    );
    for my $c (@cases) {
        my ($name, $over, $want) = @$c;
        my ($got, $why) = ReapOrphans::session_over(%base, %$over);
        is($got, $want, "AC11: session_over -- $name -> " . ($want ? 'over' : 'not over') . " ($why)");
        like($why, qr/\S/, "AC11: ...and says why ($name)");
    }
    my ($nosid) = ReapOrphans::session_over(%base, uuid => undef, registry => $live_other, transcript_mtime => 0);
    is($nosid, 0, 'AC11: no session id is never over');

    # The registry and transcript readers, against a fake config dir.
    my $cfg = tempdir(CLEANUP => 1);
    make_path("$cfg/sessions", "$cfg/projects/-Users-x-Projects-ccpraxis", "$cfg/projects/elsewhere");
    my $wf = sub { my ($p, $c) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $c; close $fh };
    $wf->("$cfg/sessions/500.json", qq({"pid":500,"sessionId":"$OTHER","kind":"interactive"}));
    $wf->("$cfg/sessions/600.json", qq({"sessionId":"$UUID"}));
    $wf->("$cfg/sessions/700.json", 'not json');
    $wf->("$cfg/sessions/800.json", qq({"pid":800}));
    $wf->("$cfg/sessions/500.abcdef.key", 'secret-looking, never read');
    my $reg = ReapOrphans::read_session_registry("$cfg/sessions");
    is_deeply($reg, [ { pid => 500, session_id => $OTHER }, { pid => 600, session_id => $UUID } ],
        'AC11: read_session_registry keeps parseable <pid>.json entries (pid from the name when absent), skips the rest');
    is(ReapOrphans::read_session_registry("$cfg/no-such-dir"), undef,
        'AC11: a missing registry is undef (no evidence), not an empty list');

    is(ReapOrphans::transcript_mtime($cfg, '-Users-x-Projects-ccpraxis', $UUID), undef,
        'AC11: no transcript -> undef');
    $wf->("$cfg/projects/-Users-x-Projects-ccpraxis/$UUID.jsonl", "{}\n");
    utime($NOW - 5000, $NOW - 5000, "$cfg/projects/-Users-x-Projects-ccpraxis/$UUID.jsonl");
    is(ReapOrphans::transcript_mtime($cfg, '-Users-x-Projects-ccpraxis', $UUID), $NOW - 5000,
        'AC11: the transcript under the scratchpad\'s own slug is found');
    $wf->("$cfg/projects/elsewhere/$OTHER.jsonl", "{}\n");
    utime($NOW - 10, $NOW - 10, "$cfg/projects/elsewhere/$OTHER.jsonl");
    is(ReapOrphans::transcript_mtime($cfg, 'some-other-slug', $OTHER), $NOW - 10,
        'AC11: ...and looked up by session id across projects when the slug differs');

    # The CLI applies it: adopted candidates go through session_over, and only
    # those it confirms stay candidates. Source assertions, like NS1-NS7 below,
    # because this file never runs the CLI (it would enumerate and kill).
    open my $sfh, '<', $SCRIPT or BAIL_OUT("cannot read $SCRIPT");
    my $src = do { local $/; <$sfh> };
    close $sfh;
    my ($cli) = $src =~ /(\n\s*unless \(caller\) \{.*)\z/s;
    like($cli, qr/unless\s*\(\$c->\{adopted\}\)\s*\{\s*push\s+\@kept/,
        'AC11: the CLI passes a non-adopted candidate straight through');
    like($cli, qr/ReapOrphans::session_over\(.*?if\s*\(\$over\)\s*\{\s*push\s+\@kept.*?else\s*\{\s*push\s+\@spared/s,
        'AC11: an adopted candidate is kept only when session_over confirms; otherwise it is spared');
    like($cli, qr/\@candidates\s*=\s*\@kept;.*?terminate_pid\(\$_->\{pid\}\)\s+for\s+\@candidates/s,
        'AC11: ...and the filtering happens before anything is terminated');
}

# ---------------------------------------------------------------------------
# AC12 -- the CLI end to end, REPORT-ONLY, against a FAKE process list. The
# one exception to "this file never spawns": a stub `ps` first on PATH hands
# the CLI synthetic processes with pids far above any real one, --kill is never
# passed, and CLAUDE_CONFIG_DIR points at a fake registry and transcripts. So
# nothing real is enumerated, judged or signalled. POSIX only: Windows
# enumerates through PowerShell/CIM, which no stub on PATH replaces.
# ---------------------------------------------------------------------------
SKIP: {
    skip 'AC12: Windows enumerates via CIM, not ps', 9 if $^O =~ /^(MSWin32|cygwin|msys)$/;
    my $root = File::Temp::tempdir(CLEANUP => 1);
    my ($A, $B, $C) = ('aaaaaaaa-0000-4000-8000-00000000000a', 'bbbbbbbb-0000-4000-8000-00000000000b',
                       'cccccccc-0000-4000-8000-00000000000c');
    my $sp = sub { "/usr/bin/perl /private/tmp/claude-501/-proj/$_[0]/scratchpad/job.pl" };
    my @rows = (
        [ 1,          0, '10-00:00:00', '/sbin/launchd' ],
        [ 2000000100, 1, '05:00:00',    'claude' ],              # the live session A's claude
        [ 2000000001, 1, '02:00:00',    $sp->($A) ],             # A is live: spared
        [ 2000000002, 1, '02:00:00',    $sp->($B) ],             # B unclaimed, idle transcript: candidate
        [ 2000000003, 1, '02:00:00',    $sp->($C) ],             # C has no transcript: spared
    );
    File::Path::make_path("$root/bin", "$root/cfg/sessions", "$root/cfg/projects/-proj");
    my $wf = sub { my ($p, $c) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $c; close $fh };
    $wf->("$root/ps.txt", join('', map { sprintf "%d %d %s %s\n", @$_ } @rows));
    $wf->("$root/bin/ps", "#!/bin/sh\ncat '$root/ps.txt'\n");
    chmod 0755, "$root/bin/ps";
    $wf->("$root/cfg/sessions/2000000100.json", qq({"pid":2000000100,"sessionId":"$A"}));
    for my $s ($A, $B) {
        $wf->("$root/cfg/projects/-proj/$s.jsonl", "{}\n");
        utime(time - 7200, time - 7200, "$root/cfg/projects/-proj/$s.jsonl");
    }

    my $json;
    {
        local $ENV{PATH} = "$root/bin:$ENV{PATH}";
        local $ENV{CLAUDE_CONFIG_DIR} = "$root/cfg";
        $json = `"$^X" "$SCRIPT" --json 2>&1`;    # report-only: no --kill
    }
    is($? >> 8, 0, 'AC12: the report-only CLI exits 0') or diag($json);
    my $d = eval { JSON::PP->new->decode($json) } || {};
    is($d->{status}, 'ok', 'AC12: it enumerated the stub list');
    is_deeply([ map { $_->{pid} } @{ $d->{candidates} || [] } ], [2000000002],
        'AC12: only the process of the session shown to be over is a candidate') or diag($json);
    my %sp = map { $_->{pid} => $_ } @{ $d->{spared} || [] };
    is_deeply([ sort keys %sp ], [2000000001, 2000000003], 'AC12: the other two adopted processes are spared');
    like($sp{2000000001}{reason} // '', qr/session is live/, 'AC12: ...the live session\'s job, because its session is live');
    like($sp{2000000003}{reason} // '', qr/no transcript/,   'AC12: ...the unknown one, because there is no transcript');
    like($d->{candidates}[0]{evidence} // '', qr/transcript idle/, 'AC12: the candidate records the evidence it was judged on');
    is_deeply($d->{killed}, [], 'AC12: report-only kills nothing');
    is_deeply($d->{failed}, [], 'AC12: ...and fails nothing');
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
