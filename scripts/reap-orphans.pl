#!/usr/bin/env perl
# reap-orphans.pl — find (and optionally kill) processes left behind by a
# Claude Code session that has ended.
#
# WHY THIS EXISTS. Bug report 20260828-095201-7c1e: a perl.exe running a
# throwaway probe out of a session scratchpad was found alive NINE DAYS AND
# NINETEEN HOURS after the session that spawned it had exited. Its parent was
# gone. It had burnt 0.016s of CPU in total -- blocked on a read, not spinning --
# while holding 11 MB and 135 handles. Nothing in ccpraxis recorded that the
# session had spawned it, killed it when the session ended, or swept for it
# afterwards. It was found by accident, in a process list, while investigating
# something else.
#
# That report's own words: "This is silent and unbounded. One leak is 11 MB; the
# failure mode is that every hung probe across every session accumulates until
# someone happens to look at a process list."
#
# WHAT COUNTS AS AN ORPHAN HERE -- three conditions, ALL required:
#
#   1. its command line names a session scratchpad
#      (<temp>/claude/<project>/<session-uuid>/scratchpad/...)
#   2. its parent process no longer exists
#   3. it is older than --min-age-seconds (default 1h)
#
# Condition 2 is the one doing the real work and is why this is safe: a live
# session's children have a live parent. A process whose parent is gone was
# reparented, which on both Windows and POSIX means the thing that started it is
# not around to stop it. Condition 3 exists only so a process caught in the
# split second between its parent exiting and its own cleanup is not killed.
#
# NEVER KILLS THE CURRENT SESSION. --session-id excludes a uuid outright, and
# the running process and its own ancestors are excluded by pid. A reaper that
# can kill the session invoking it is worse than the leak.
#
# DEFAULT IS REPORT-ONLY. Killing requires --kill, explicitly. This is a tool
# that terminates processes; it does not get to do that as a side effect of
# someone running it to look around.
#
#   perl scripts/reap-orphans.pl                        # report candidates
#   perl scripts/reap-orphans.pl --kill                 # report and terminate
#   perl scripts/reap-orphans.pl --min-age-seconds 300  # loosen the age floor
#   perl scripts/reap-orphans.pl --json                 # machine-readable
#
# SCRATCHPAD DIRECTORIES ARE DELIBERATELY NOT SWEPT, and the report asked for
# that to be an explicit decision rather than an accident. They are kept:
#   - they are the post-mortem. This very bug was diagnosed by reading probe4.pl
#     out of a scratchpad belonging to a session that had ended nine days
#     earlier; a sweeper would have deleted the evidence.
#   - they are small and inert. A leaked directory costs disk; a leaked PROCESS
#     costs memory, handles, and a share of whatever it is blocked on.
#   - the harness owns that directory, not ccpraxis. Deleting another tool's
#     working directory on a schedule is how you lose something that mattered.
# If they ever do need bounding, bound them by age with the same report-first
# discipline as the process path -- do not fold it into this script's --kill.
# SHAPE: a pure selection library plus a thin CLI, the convention this repo
# already uses (bp-dispatch-log.pl, bp-runstate.pl). The point is testability
# WITHOUT SPAWNING ANYTHING: select_orphans takes a process list as data, so the
# oracle feeds it synthetic processes instead of creating real orphans and real
# kills inside the suite. A test for a process reaper that reaps is a test that
# can take out something it did not mean to.
package ReapOrphans;
use strict;
use warnings;

# MSYS2 path conversion off for the whole process tree: this spawns
# powershell.exe, a NATIVE Windows binary, and hands it arguments containing
# both ':' and '\'. See the user-global CLAUDE.md -- the launcher and bootstrap
# carry the same guard for the same reason.
BEGIN { $ENV{MSYS2_ARG_CONV_EXCL} = '*' if $^O =~ /^(MSWin32|cygwin|msys)$/ }

# A scratchpad path, as the harness builds it:
#   <temp>/claude/<project-slug>/<session-uuid>/scratchpad/...
# The uuid is what ties a process back to a session, so it is CAPTURED rather
# than merely matched -- --session-id has to be able to exclude by it.
our $SCRATCHPAD_RE = qr{
    [/\\] claude [/\\] [^/\\]+ [/\\]
    ( [0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12} )
    [/\\] scratchpad [/\\]
}x;

# scratchpad_session($cmd) -> session uuid | undef. PURE.
sub scratchpad_session {
    my ($cmd) = @_;
    return undef unless defined $cmd && length $cmd;
    my ($uuid) = $cmd =~ $SCRATCHPAD_RE;
    return $uuid;
}

# select_orphans(\@procs, %opt) -> \@candidates. PURE, total.
#
# @procs is [ { pid, ppid, age, cmd }, ... ]; `age` undef means the platform
# could not supply a start time. %opt takes min_age, session_id, self (a hashref
# of pids that must never be selected).
#
# ALL THREE CONDITIONS ARE REQUIRED, and the order below is the order they are
# argued for in the header. The parent-gone test is the load-bearing one; the
# age floor exists only so a process caught between its parent exiting and its
# own cleanup is left alone.
sub select_orphans {
    my ($procs, %o) = @_;
    return [] unless ref $procs eq 'ARRAY';
    my $min_age = defined $o{min_age} && $o{min_age} =~ /^\d+$/ ? $o{min_age} + 0 : 0;
    my $self    = ref $o{self} eq 'HASH' ? $o{self} : {};
    # ref-checked BEFORE dereferencing: a single malformed row must not abort
    # the sweep. A die here does not degrade the reaper, it STOPS it, and the
    # leak silently resumes -- which is indistinguishable from the bug this
    # script exists to close. Caught by t/38 AC8.
    my %alive = map { (ref $_ eq 'HASH' && defined $_->{pid}) ? ($_->{pid} => 1) : () } @$procs;

    my @out;
    for my $p (@$procs) {
        next unless ref $p eq 'HASH';
        my $uuid = scratchpad_session($p->{cmd});
        next unless defined $uuid;                          # 1. names a scratchpad
        next if $self->{ $p->{pid} // -1 };                 #    never ourselves
        next if defined $o{session_id} && lc($uuid) eq lc($o{session_id});
        next if $alive{ $p->{ppid} // -1 };                 # 2. parent is gone
        next unless defined $p->{age};                      #    unknown age != old
        next unless $p->{age} >= $min_age;                  # 3. old enough
        push @out, { %$p, session => $uuid };
    }
    return \@out;
}

package main;
use strict;
use warnings;

# `unless (caller)` so a test can load this file for ReapOrphans::select_orphans
# without the CLI running -- which would enumerate every process on the machine
# and, with --kill, terminate things. The oracle must be able to reach the
# selection logic without either.
unless (caller) {

my %opt = (
    'min-age-seconds' => 3600,
    kill              => 0,
    json              => 0,
    'session-id'      => undef,
);
while (@ARGV) {
    my $a = shift @ARGV;
    if    ($a eq '--kill')  { $opt{kill} = 1 }
    elsif ($a eq '--json')  { $opt{json} = 1 }
    elsif ($a eq '--help' || $a eq '-h') { usage(); exit 0 }
    elsif ($a =~ /^--(min-age-seconds|session-id)$/) { $opt{$1} = shift @ARGV }
    else { die "reap-orphans: unknown argument '$a' (try --help)\n" }
}
$opt{'min-age-seconds'} = 3600
    unless defined $opt{'min-age-seconds'} && $opt{'min-age-seconds'} =~ /^\d+$/;

sub usage {
    print <<'USAGE';
reap-orphans.pl — processes left behind by an ended Claude Code session.

  --kill                 terminate what it finds (default: report only)
  --min-age-seconds N    minimum age to consider (default 3600)
  --session-id UUID      never touch this session's processes
  --json                 machine-readable output
USAGE
}

# (the scratchpad pattern lives in package ReapOrphans, above)

# ---------------------------------------------------------------------------
# Process enumeration. Returns a list of { pid, ppid, age, cmd }.
# `age` is undef when the platform could not supply a start time -- callers
# must treat undef as "unknown", never as "old".
# ---------------------------------------------------------------------------
sub enumerate_windows {
    my $ps = 'powershell.exe -NoProfile -NonInteractive -Command '
           . '"Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | '
           . 'Select-Object ProcessId,ParentProcessId,CreationDate,CommandLine | '
           . 'ConvertTo-Json -Compress -Depth 3"';
    my $raw = `$ps 2>/dev/null`;
    return () unless defined $raw && $raw =~ /\S/;

    require JSON::PP;
    my $data = eval { JSON::PP->new->utf8(0)->decode($raw) };
    return () unless ref $data;
    $data = [$data] if ref $data eq 'HASH';

    my $now = time;
    my @out;
    for my $p (@$data) {
        next unless ref $p eq 'HASH';
        my $pid  = $p->{ProcessId}       or next;
        my $ppid = $p->{ParentProcessId};
        my $cmd  = $p->{CommandLine};
        next unless defined $cmd && length $cmd;

        # /Date(1787911926701)/ -> epoch seconds. A CreationDate we cannot parse
        # yields undef, which is treated as unknown age and therefore NOT reaped.
        my $age;
        if (defined $p->{CreationDate} && $p->{CreationDate} =~ m{/Date\((\d+)}) {
            $age = $now - int($1 / 1000);
        }
        push @out, { pid => $pid, ppid => $ppid, age => $age, cmd => $cmd };
    }
    return @out;
}

sub enumerate_posix {
    # etimes (elapsed seconds) is Linux; macOS ps has no such column. Ask for it
    # and fall back to no age rather than parsing the several formats of etime.
    my @lines = `ps -eo pid=,ppid=,etimes=,args= 2>/dev/null`;
    my $have_age = 1;
    if (!@lines) {
        @lines = `ps -eo pid=,ppid=,args= 2>/dev/null`;
        $have_age = 0;
    }
    my @out;
    for my $l (@lines) {
        chomp $l;
        $l =~ s/^\s+//;
        my ($pid, $ppid, $age, $cmd);
        if ($have_age) { ($pid, $ppid, $age, $cmd) = split /\s+/, $l, 4 }
        else           { ($pid, $ppid, $cmd) = split /\s+/, $l, 3; $age = undef }
        next unless defined $cmd && length $cmd;
        push @out, { pid => $pid, ppid => $ppid,
                     age => (defined $age && $age =~ /^\d+$/ ? $age + 0 : undef),
                     cmd => $cmd };
    }
    return @out;
}

sub enumerate {
    return ($^O =~ /^(MSWin32|cygwin|msys)$/) ? enumerate_windows() : enumerate_posix();
}

# ---------------------------------------------------------------------------
# Selection.
# ---------------------------------------------------------------------------
my @procs = enumerate();
if (!@procs) {
    print "reap-orphans: could not enumerate processes on this platform ($^O).\n"
        unless $opt{json};
    print "{\"status\":\"unavailable\",\"candidates\":[]}\n" if $opt{json};
    exit 0;
}

# Our own ancestry, so the reaper cannot reap the session running it. Walked
# from this pid upward through the enumerated set.
my %self;
{
    my %by_pid = map { $_->{pid} => $_ } @procs;
    my $p = $$;
    my $guard = 0;
    while (defined $p && $by_pid{$p} && $guard++ < 64) {
        $self{$p} = 1;
        $p = $by_pid{$p}{ppid};
    }
}

my @candidates = @{ ReapOrphans::select_orphans(\@procs,
    min_age    => $opt{'min-age-seconds'},
    session_id => $opt{'session-id'},
    self       => \%self,
) };

# ---------------------------------------------------------------------------
# Report / act.
# ---------------------------------------------------------------------------
sub human_age {
    my ($s) = @_;
    return '?' unless defined $s;
    return sprintf('%dd %dh', int($s / 86400), int(($s % 86400) / 3600)) if $s >= 86400;
    return sprintf('%dh %dm', int($s / 3600), int(($s % 3600) / 60))     if $s >= 3600;
    return sprintf('%dm', int($s / 60));
}

my @killed;
my @failed;
if ($opt{kill}) {
    for my $c (@candidates) {
        my $ok = kill('TERM', $c->{pid}) ? 1 : 0;
        # Windows perl's kill(TERM) does not always land on a native process;
        # fall back to taskkill, which does. Verified against a real orphan.
        if (!$ok && $^O =~ /^(MSWin32|cygwin|msys)$/) {
            system("taskkill /PID $c->{pid} /F >/dev/null 2>&1");
            $ok = (kill(0, $c->{pid}) ? 0 : 1);
        }
        push @{ $ok ? \@killed : \@failed }, $c;
    }
}

if ($opt{json}) {
    require JSON::PP;
    print JSON::PP->new->canonical->encode({
        status     => 'ok',
        killed     => [ map { $_->{pid} } @killed ],
        failed     => [ map { $_->{pid} } @failed ],
        candidates => [ map { { pid => $_->{pid}, ppid => $_->{ppid},
                                age_seconds => $_->{age}, session => $_->{session},
                                cmd => $_->{cmd} } } @candidates ],
    }), "\n";
    exit 0;
}

if (!@candidates) {
    printf "reap-orphans: nothing to reap (%d processes examined, min age %ds).\n",
        scalar(@procs), $opt{'min-age-seconds'};
    exit 0;
}

printf "reap-orphans: %d orphaned process(es) from ended sessions:\n\n", scalar @candidates;
for my $c (@candidates) {
    my $cmd = $c->{cmd};
    $cmd = substr($cmd, 0, 110) . '...' if length($cmd) > 113;
    printf "  pid %-8s parent %-8s age %-10s session %s\n", $c->{pid},
        (defined $c->{ppid} ? $c->{ppid} : '?') . ' (gone)', human_age($c->{age}),
        substr($c->{session}, 0, 8);
    printf "      %s\n", $cmd;
}
print "\n";
if ($opt{kill}) {
    printf "  terminated: %d\n", scalar @killed;
    printf "  FAILED to terminate: %s\n", join(', ', map { $_->{pid} } @failed) if @failed;
}
else {
    print "  (report only — pass --kill to terminate them)\n";
}
exit 0;

}

1;
