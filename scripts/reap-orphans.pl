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
# Condition 2 is the one doing the real work: a process whose parent is gone
# was reparented, so the thing that started it is not around to stop it.
# Condition 3 exists only so a process caught in the split second between its
# parent exiting and its own cleanup is not killed.
#
# Condition 2 does NOT mean the SESSION is over. A live session's detached job
# (`nohup`, setsid, a backgrounded subshell) loses its launching shell at once.
# On macOS and Linux it is adopted by pid 1, which is how "parent gone" is
# read there, so an ADOPTED candidate is killed only on further evidence that
# its owning session has ended (ReapOrphans::session_over); without it, it is
# reported as spared. Windows keeps the dead parent's pid and passes no
# adopter set, so this extra rule does not reach it -- and the same detached-
# job weakness remains there (see session_over's comment).
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
# already uses (bp-dispatch-log.pl). The point is testability
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
# On macOS (and Linux) the temp root carries the uid --
#   /private/tmp/claude-501/<project-slug>/<session-uuid>/scratchpad/...
# -- so the directory is claude or claude-<digits>. The uuid is what ties a
# process back to a session, so it is CAPTURED rather than merely matched --
# --session-id has to be able to exclude by it.
# The project slug is captured too: it names the directory Claude Code keeps
# that session's transcript in (session_over, below).
our $SCRATCHPAD_RE = qr{
    [/\\] claude (?: -\d+ )? [/\\] ( [^/\\]+ ) [/\\]
    ( [0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12} )
    [/\\] scratchpad [/\\]
}x;

# scratchpad_owner($cmd) -> ($slug, $uuid) | (). PURE.
sub scratchpad_owner {
    my ($cmd) = @_;
    return () unless defined $cmd && length $cmd;
    my ($slug, $uuid) = $cmd =~ $SCRATCHPAD_RE or return ();
    return ($slug, $uuid);
}

# scratchpad_session($cmd) -> session uuid | undef. PURE.
sub scratchpad_session {
    my (undef, $uuid) = scratchpad_owner(@_);
    return $uuid;
}

# select_orphans(\@procs, %opt) -> \@candidates. PURE, total.
#
# @procs is [ { pid, ppid, age, cmd }, ... ]; `age` undef means the platform
# could not supply a start time. %opt takes min_age, session_id, self (a hashref
# of pids that must never be selected) and reparented (a hashref of ppids that
# mean "the real parent is gone": on macOS and Linux an orphan is adopted by
# pid 1, which is alive, so without this no POSIX orphan ever had a gone
# parent. Windows does not reparent and passes none).
#
# Each candidate carries `session` (uuid), `slug` (the project directory the
# scratchpad sits under) and `adopted` (1 when its parent counted as gone only
# because it is in the reparented set -- the CLI then needs session_over's
# evidence before it may kill it).
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
    my $adopted = ref $o{reparented} eq 'HASH' ? $o{reparented} : {};
    # ref-checked BEFORE dereferencing: a single malformed row must not abort
    # the sweep. A die here does not degrade the reaper, it STOPS it, and the
    # leak silently resumes -- which is indistinguishable from the bug this
    # script exists to close. Caught by t/38 AC8.
    my %alive = map { (ref $_ eq 'HASH' && defined $_->{pid}) ? ($_->{pid} => 1) : () } @$procs;

    my @out;
    for my $p (@$procs) {
        next unless ref $p eq 'HASH';
        my ($slug, $uuid) = scratchpad_owner($p->{cmd});
        next unless defined $uuid;                          # 1. names a scratchpad
        next if $self->{ $p->{pid} // -1 };                 #    never ourselves
        next if defined $o{session_id} && lc($uuid) eq lc($o{session_id});
        next if $alive{ $p->{ppid} // -1 }                  # 2. parent is gone
             && !$adopted->{ $p->{ppid} // -1 };            #    (adopted by init counts)
        next unless defined $p->{age};                      #    unknown age != old
        next unless $p->{age} >= $min_age;                  # 3. old enough
        # `adopted`: the parent counted as gone only because it is an adopter
        # (pid 1 on POSIX). That inference is the weak one -- see
        # session_over -- so the CLI asks for more evidence before killing.
        push @out, { %$p, session => $uuid, slug => $slug,
                     adopted => ($adopted->{ $p->{ppid} // -1 } ? 1 : 0) };
    }
    return \@out;
}

# parse_etime($s) -> seconds | undef. PURE. BSD/macOS `ps -o etime` prints
# [[dd-]hh:]mm:ss (macOS has no `etimes`); anything else is undef, which the
# selector treats as unknown age and never reaps.
sub parse_etime {
    my ($s) = @_;
    return undef unless defined $s;
    my ($d, $h, $m, $sec) = $s =~ /^\s*(?:(?:(\d+)-)?(\d+):)?(\d+):(\d+)\s*\z/ or return undef;
    return ((($d // 0) * 24 + ($h // 0)) * 60 + $m) * 60 + $sec;
}

# ---------------------------------------------------------------------------
# IS THE OWNING SESSION OVER? Asked only for an ADOPTED candidate.
#
# On macOS and Linux an orphan is adopted by pid 1, so "parent is gone" was
# read off "parent is pid 1". But a process a LIVE session detaches -- a
# `nohup ... &`, a setsid'd job, anything whose launching shell has already
# exited -- is adopted by pid 1 immediately, while its session is still
# running. --session-id spares only the session running the sweep; with two
# windows open, or a drive-solo run in one of them, the OTHER session's
# SessionStart killed the first one's hour-old background job.
#
# So an adopted candidate is killed only on evidence that the session that
# owns its scratchpad is over. Both must hold:
#
#   1. No live Claude Code process claims the session. Claude Code keeps a
#      registry of running sessions, <config>/sessions/<pid>.json, each
#      carrying the pid and its sessionId. It is an internal format, so it
#      is trusted only while it demonstrably works: at least one entry must
#      name a live pid. Unreadable, absent, or holding only dead pids is "no
#      evidence", never "session over".
#   2. Its transcript, <config>/projects/<slug>/<uuid>.jsonl, exists and has
#      not been written for at least the age floor. Missing (a session under
#      another config dir, another HOME) is "no evidence" too.
#
# Rule 1 is what protects an idle-but-open session; rule 2 backs it up when
# the registry misses a session (Claude Code registers interactive and
# background sessions; a headless `claude -p` may not appear there). The
# residual risk is a headless session whose transcript has been quiet for
# the whole age floor while a detached job of its own is still wanted.
#
# Windows passes no adopter set, so no Windows candidate is ever adopted and
# none of this applies there. The same weakness exists there (a detached
# job whose launching shell exited has a gone parent), and is not addressed
# here.
#
# session_over(%a) -> ($over 0|1, $why). PURE.
#   uuid             the candidate's session
#   registry         [ { pid, session_id }, ... ] | undef (unreadable)
#   alive            { pid => 1 } -- the enumerated process set
#   transcript_mtime epoch | undef (no transcript found)
#   now, min_idle    seconds
sub session_over {
    my (%a) = @_;
    my $uuid = $a{uuid};
    return (0, 'no session id') unless defined $uuid && length $uuid;
    my $reg = $a{registry};
    return (0, 'session registry unreadable') unless ref $reg eq 'ARRAY';
    my $alive = ref $a{alive} eq 'HASH' ? $a{alive} : {};
    my @rows  = grep { ref $_ eq 'HASH' && defined $_->{pid} && $_->{pid} =~ /^\d+\z/ } @$reg;
    return (0, 'session registry names no live process, so it cannot vouch for anything')
        unless grep { $alive->{ $_->{pid} } } @rows;
    for my $r (@rows) {
        next unless defined $r->{session_id} && lc($r->{session_id}) eq lc($uuid);
        return (0, "session is live (pid $r->{pid})") if $alive->{ $r->{pid} };
    }
    my $mt = $a{transcript_mtime};
    return (0, 'no transcript found for the session') unless defined $mt && $mt =~ /^\d+(?:\.\d+)?\z/;
    my $now  = defined $a{now} ? $a{now} : time;
    my $idle = int($now - $mt);
    my $floor = (defined $a{min_idle} && $a{min_idle} =~ /^\d+\z/) ? $a{min_idle} : 0;
    return (0, "transcript written ${idle}s ago") if $idle < $floor;
    return (1, "no live process claims the session; transcript idle ${idle}s");
}

# claude_config_dir() -> where Claude Code keeps sessions/ and projects/.
sub claude_config_dir {
    my $c = $ENV{CLAUDE_CONFIG_DIR};
    return $c if defined $c && length $c;
    my $home = $ENV{HOME} // $ENV{USERPROFILE};
    return (defined $home && length $home) ? "$home/.claude" : undef;
}

# read_session_registry($dir) -> [ { pid, session_id }, ... ] | undef.
# undef when the directory cannot be read at all. Entries that do not parse
# are skipped; the caller decides whether what is left proves anything.
sub read_session_registry {
    my ($dir) = @_;
    return undef unless defined $dir && length $dir && -d $dir;
    opendir(my $dh, $dir) or return undef;
    my @files = grep { /^\d+\.json\z/ } readdir $dh;
    closedir $dh;
    require JSON::PP;
    my @out;
    for my $f (sort @files) {
        my $p = "$dir/$f";
        next unless -f $p && -s _ <= 262144;
        open(my $fh, '<:raw', $p) or next;
        my $raw = do { local $/; <$fh> };
        close $fh;
        my $d = eval { JSON::PP->new->decode($raw // '') };
        next unless ref $d eq 'HASH';
        my ($pid) = $f =~ /^(\d+)/;
        $pid = $d->{pid} if defined $d->{pid} && !ref $d->{pid} && $d->{pid} =~ /^\d+\z/;
        my $sid = $d->{sessionId};
        next unless defined $sid && !ref $sid && length $sid;
        push @out, { pid => $pid + 0, session_id => $sid };
    }
    return \@out;
}

# transcript_mtime($config_dir, $slug, $uuid) -> epoch | undef. The temp
# root and the projects dir use the same slug for a session; when they do
# not, the transcript is looked up by session id across every project.
sub transcript_mtime {
    my ($cfg, $slug, $uuid) = @_;
    return undef unless defined $cfg && length $cfg && defined $uuid && length $uuid;
    if (defined $slug && length $slug) {
        my @st = stat("$cfg/projects/$slug/$uuid.jsonl");
        return $st[9] if @st;
    }
    opendir(my $dh, "$cfg/projects") or return undef;
    my @dirs = grep { !/^\.\.?\z/ } readdir $dh;
    closedir $dh;
    my $best;
    for my $d (@dirs) {
        my @st = stat("$cfg/projects/$d/$uuid.jsonl");
        $best = $st[9] if @st && (!defined $best || $st[9] > $best);
    }
    return $best;
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
    # etimes (elapsed seconds) is Linux. macOS ps has no such column, and used
    # to fall straight through to "no age", which spared everything: the
    # reaper was inert there. It now asks for etime ([[dd-]hh:]mm:ss) and
    # parses it (ReapOrphans::parse_etime). -ww: never truncate args, which is
    # where the scratchpad path is.
    # NOT detected by "no output": macOS ps reports the unknown keyword on
    # stderr and then prints the other columns anyway, so the args landed in
    # the age slot. Chosen by platform, and the etimes output is still checked
    # for a numeric third column before it is believed.
    my @lines;
    my $age_kind = 'etime';
    if ($^O ne 'darwin') {
        @lines = `ps -eo pid=,ppid=,etimes=,args= 2>/dev/null`;
        $age_kind = 'etimes';
        @lines = () unless grep { /^\s*\d+\s+\d+\s+\d+\s/ } @lines;
    }
    if (!@lines) {
        @lines = `ps -ww -eo pid=,ppid=,etime=,args= 2>/dev/null`;
        $age_kind = 'etime';
    }
    if (!@lines) {
        @lines = `ps -eo pid=,ppid=,args= 2>/dev/null`;
        $age_kind = '';
    }
    my @out;
    for my $l (@lines) {
        chomp $l;
        $l =~ s/^\s+//;
        my ($pid, $ppid, $age, $cmd);
        if ($age_kind) {
            ($pid, $ppid, $age, $cmd) = split /\s+/, $l, 4;
            $age = ReapOrphans::parse_etime($age) if $age_kind eq 'etime';
        }
        else { ($pid, $ppid, $cmd) = split /\s+/, $l, 3; $age = undef }
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
    # POSIX reparents an orphan to pid 1; Windows keeps the dead parent's pid.
    reparented => ($^O =~ /^(MSWin32|cygwin|msys)$/ ? {} : { 1 => 1 }),
) };

# An ADOPTED candidate's parent is pid 1 whether or not its session is still
# running (see ReapOrphans::session_over). It is reaped only when the session
# that owns its scratchpad is shown to be over; otherwise it is reported as
# spared, with the reason, and never killed. The registry and transcripts
# are read once, and only when there is an adopted candidate to judge.
my @spared;
{
    my ($cfg, $registry, $loaded);
    my %alive = map { (defined $_->{pid}) ? ($_->{pid} => 1) : () } @procs;
    my @kept;
    for my $c (@candidates) {
        unless ($c->{adopted}) { push @kept, $c; next }
        unless ($loaded++) {
            $cfg      = ReapOrphans::claude_config_dir();
            $registry = defined $cfg ? ReapOrphans::read_session_registry("$cfg/sessions") : undef;
        }
        my ($over, $why) = ReapOrphans::session_over(
            uuid             => $c->{session},
            registry         => $registry,
            alive            => \%alive,
            transcript_mtime => ReapOrphans::transcript_mtime($cfg, $c->{slug}, $c->{session}),
            now              => time,
            min_idle         => $opt{'min-age-seconds'},
        );
        if ($over) { push @kept, { %$c, evidence => $why } }
        else       { push @spared, { %$c, spared_because => $why } }
    }
    @candidates = @kept;
}

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

# terminate_pid($pid) -- send the kill IN THE NAMESPACE THE PID CAME FROM.
#
# THE BUG THIS REPLACES (20260917-033101-c455). This block used to try
# `kill('TERM', $pid)` first, fall back to `taskkill` when that failed, and then
# verify with `kill(0, $pid)`. Every one of those perl calls asks MSYS about a
# pid that `enumerate_windows` collected from `Get-CimInstance Win32_Process`.
#
# Git-for-Windows perl runs under MSYS2, which keeps its OWN pid numbering.
# `ps -W` prints both and they are different numbers for the same process:
#
#     PID    PPID    WINPID   COMMAND
#  832282       1    159020   /usr/bin/perl        <- one process, two ids
#
# perl's $$, getppid() and kill() use PID. CIM, Get-Process, Stop-Process and
# taskkill use WINPID. Crossing them DOES NOT ERROR -- it answers "no such
# process", which reads as a real answer.
#
# So the old first attempt could never land (hence the taskkill workaround, whose
# comment recorded the symptom without the cause), and worse, the VERIFICATION
# `kill(0, $winpid)` returned false for every live process, setting $ok = 1
# unconditionally. THE TOOL REPORTED EVERY KILL AS SUCCESSFUL and @failed could
# not be populated. A reaper that cannot say what it failed to reap is exactly
# the tool you cannot trust when something leaks -- which is how it was found,
# after two launchers survived 37 hours on this host.
sub terminate_pid {
    my ($pid) = @_;
    return unless defined $pid && $pid =~ /^\d+$/;
    if ($^O =~ /^(MSWin32|cygwin|msys)$/) {
        system("taskkill /PID $pid /F >/dev/null 2>&1");
        return;
    }
    kill('TERM', $pid);
}

my @killed;
my @failed;
if ($opt{kill}) {
    terminate_pid($_->{pid}) for @candidates;

    # VERIFY BY RE-ENUMERATING, not by asking about one pid. enumerate() is the
    # same source every candidate came from, so it cannot disagree with itself
    # about which namespace these numbers live in -- which is precisely the
    # disagreement that made the old check meaningless. One query for the whole
    # batch, rather than one per pid.
    select(undef, undef, undef, 0.5);   # brief settle; a forced kill is not instant
    my %still = map { $_->{pid} => 1 } enumerate();

    for my $c (@candidates) {
        push @{ $still{ $c->{pid} } ? \@failed : \@killed }, $c;
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
                                cmd => $_->{cmd},
                                (defined $_->{evidence} ? (evidence => $_->{evidence}) : ()) } } @candidates ],
        # Adopted processes whose session could not be shown to be over: never
        # killed, listed so the log says what was left alone and why.
        spared     => [ map { { pid => $_->{pid}, ppid => $_->{ppid},
                                age_seconds => $_->{age}, session => $_->{session},
                                cmd => $_->{cmd}, reason => $_->{spared_because} } } @spared ],
    }), "\n";
    exit 0;
}

sub print_spared {
    return unless @spared;
    printf "reap-orphans: %d adopted process(es) spared -- their session may still be live:\n\n",
        scalar @spared;
    for my $c (@spared) {
        my $cmd = $c->{cmd};
        $cmd = substr($cmd, 0, 110) . '...' if length($cmd) > 113;
        printf "  pid %-8s age %-10s session %s  (%s)\n", $c->{pid}, human_age($c->{age}),
            substr($c->{session}, 0, 8), $c->{spared_because};
        printf "      %s\n", $cmd;
    }
    print "\n";
}

if (!@candidates) {
    printf "reap-orphans: nothing to reap (%d processes examined, min age %ds).\n",
        scalar(@procs), $opt{'min-age-seconds'};
    print_spared();
    exit 0;
}

printf "reap-orphans: %d orphaned process(es) from ended sessions:\n\n", scalar @candidates;
for my $c (@candidates) {
    my $cmd = $c->{cmd};
    $cmd = substr($cmd, 0, 110) . '...' if length($cmd) > 113;
    printf "  pid %-8s parent %-8s age %-10s session %s\n", $c->{pid},
        (defined $c->{ppid} ? $c->{ppid} : '?') . ($c->{adopted} ? ' (adopted)' : ' (gone)'),
        human_age($c->{age}), substr($c->{session}, 0, 8);
    printf "      %s\n", $cmd;
}
print "\n";
print_spared();
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
