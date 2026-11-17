#!/usr/bin/env perl
# reap-orphans-hook.pl — SessionStart hook: sweep processes left behind by
# sessions that have already ended.
#
# Closes the last piece of bug report 20260828-095201-7c1e. scripts/reap-orphans.pl
# could find and kill a nine-day-old orphan, but nothing ran it, so the leak
# still accumulated until somebody happened to look at a process list -- which
# is the report's original complaint, not a detail of it.
#
# WHY SessionStart. The event fires once per session rather than on a timer,
# so the cost is paid at the one moment a small delay is invisible. It does NOT
# mean that whatever matches belongs to a session that is over. The reaper
# selects processes whose PARENT is gone, and a live session's detached job
# loses its launching shell at once; with several windows open, or a drive-
# solo run in one of them, every other session's start sweeps that job too.
# On macOS and Linux (where such a job is adopted by pid 1) the reaper
# therefore kills an adopted process only when the session owning its
# scratchpad is shown to be over -- no live Claude Code process claims it and
# its transcript has been idle for the age floor -- and otherwise logs it as
# spared. On Windows the dead parent's pid is kept and that extra check does
# not apply; a live session's hour-old detached job there is still exposed to
# other sessions' sweeps.
#
# WHY GLOBALLY (global-config/settings.json, not a project plugin). The leak is
# per-MACHINE. The orphan in that report was spawned by a ccpraxis session and
# found from an unrelated project while investigating something else; a hook
# registered only in ccpraxis would have missed most of the accumulation.
#
# THREE RULES, all about never being the thing that breaks a session:
#
#   1. IT NEVER BLOCKS. The sweep is detached and this exits immediately. A full
#      process enumeration shells out to powershell on Windows and takes
#      seconds; paying that before every session in every project would be a
#      tax on the whole machine to clean up after a rare failure.
#   2. IT NEVER FAILS THE SESSION. Every path exits 0. A hook that can refuse a
#      session start is far more expensive than the leak it is cleaning up.
#   3. IT NEVER TOUCHES THE SESSION RUNNING IT. The session id (from the
#      environment, see below) is passed through as --session-id, so this
#      session's own processes are excluded by name. OTHER live sessions are
#      protected only by the reaper's own rules (see WHY SessionStart).
#
# Set CCPRAXIS_REAP_ORPHANS=0 to disable; set it to `report` to sweep without
# killing (the findings land in the log either way).
use strict;
use warnings;

# Never let this hook be the reason a session does not start.
$SIG{__DIE__} = sub { exit 0 };

exit 0 if defined $ENV{CCPRAXIS_REAP_ORPHANS} && $ENV{CCPRAXIS_REAP_ORPHANS} eq '0';

# THE SESSION ID COMES FROM THE ENVIRONMENT, NOT STDIN, and that is the whole
# design of this hook rather than a convenience.
#
# The obvious implementation reads the hook payload from stdin and pulls
# session_id out of it. That was written first, with a bounded read guarded by
# alarm(5) -- the same discipline this session applied to 19 butler hook call
# sites (b64f288). MEASURED: it took 25 SECONDS against a producer that held
# stdin open for 25. Perl's alarm on Windows does not interrupt a blocking read,
# so the bound was decorative and the hook would have stalled session start for
# as long as whatever was upstream held the pipe.
#
# CLAUDE_CODE_SESSION_ID carries the same value, needs no read at all, and
# cannot block. Verified equal to the live session's uuid before being relied on.
#
# AND THE ID IS NOT OPTIONAL. Without it the reaper's remaining guards -- parent
# gone, self-ancestry, an age floor -- would still spare essentially everything,
# but not quite: a session's own DETACHED background job (a backgrounded sweep,
# a long-running probe) can outlive its parent shell and sit in this session's
# scratchpad. After an hour it would match. Excluding by session id closes that,
# and it is exactly the case that produced the report this hook exists for.
my $session_id;
if (defined $ENV{CLAUDE_CODE_SESSION_ID}
    && $ENV{CLAUDE_CODE_SESSION_ID} =~ /^([0-9a-fA-F-]{36})$/) {
    $session_id = $1;
}

my $root   = $ENV{HOME} // $ENV{USERPROFILE} // '';
my $reaper = "$root/.claude/ccpraxis/scripts/reap-orphans.pl";
exit 0 unless length $root && -f $reaper;

my $mode = (defined $ENV{CCPRAXIS_REAP_ORPHANS} && $ENV{CCPRAXIS_REAP_ORPHANS} eq 'report')
         ? '' : '--kill';

my $log = "$root/.claude/ccpraxis/.reap-orphans.log";

# BOUNDED LOG. This appends once per session start, forever, on a machine with
# many projects -- an unbounded file is a slower version of the leak this hook
# exists to stop. Trimmed to the most recent lines when it grows past the cap,
# best-effort: a failure to trim must never prevent the sweep.
eval {
    my $CAP = 200;
    if (-f $log && -s $log > 64 * 1024) {
        open my $in, '<', $log or die;
        my @lines = <$in>;
        close $in;
        if (@lines > $CAP) {
            open my $out, '>', $log or die;
            print {$out} @lines[ -$CAP .. -1 ];
            close $out;
        }
    }
    1;
};

# DETACHED, and the output goes to a file rather than to stdout.
#
# stdout from a SessionStart hook is parsed by the harness as hook protocol --
# anything this printed would be interpreted, not logged. The sweep's findings
# belong in a file the operator can read after the fact, which is also what
# makes an auto-kill accountable: every terminated pid is recorded with the
# session it belonged to and how old it was.
my @cmd = ('perl', $reaper, '--json');
push @cmd, $mode if length $mode;
push @cmd, '--session-id', $session_id if defined $session_id;

my $quoted = join ' ', map { my $a = $_; $a =~ s/"/\\"/g; qq{"$a"} } @cmd;
system(qq{( $quoted >> "$log" 2>&1 & ) >/dev/null 2>&1 &});

exit 0;
