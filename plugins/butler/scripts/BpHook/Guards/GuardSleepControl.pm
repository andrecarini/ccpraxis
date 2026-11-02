# BpHook::Guards::GuardSleepControl -- denies a Bash-tool command that changes
# the machine's sleep behaviour by hand: caffeinate (every spelling, and
# pkill/killall of it), pmset writes, powercfg changes, systemd-inhibit,
# SetThreadExecutionState through PowerShell, and a hand-started ccpraxis
# keep-awake holder. Registered for every session
# (hooks/guard-sleep-control.sh), main thread and subagents.
#
# WHY. On 2026-10-29 an unattended session ran `caffeinate -i -s -m -t 50400`
# to stop a lid-closed Mac on AC from sleeping. Its work ended at 23:01; the
# assertion kept the Mac awake until 08:52, because nothing that knows whether
# work is in flight owns a hand-taken lock. The operator's requirement: "a
# deterministic way to interact with caffeinate; don't let Claude willy-nilly
# toggle it on and off." The deterministic way already exists -- arming
# continuity, whose lease holds the managed wake-lock only while an armed
# session has work in flight (and, on a Mac, only on AC power, never against a
# closed lid) -- so this guard closes the other way in, and its deny names that
# path. Read-only queries stay allowed: `pmset -g ...`, powercfg's query verbs
# (/requests, /list, /query, /a, ...), `systemd-inhibit --list`.
#
# `pmset sleepnow` (and displaysleepnow, schedule, repeat, ...) is denied too,
# deliberately: every pmset verb but -g changes when the machine sleeps, and
# sleepnow suspends the very machine running unattended work -- the inverse of
# the incident, with nobody there to wake it. No agent task needs it; the
# operator can run it themselves.
#
# WHAT IT NEVER SEES. ccpraxis's own machinery takes its assertion by
# fork+exec from perl (bp-keepawake.pl's holder, the launcher, the continuity
# refresher), and Claude Code runs its own `caffeinate -i -t 300` as a child of
# the claude process while a session is busy. None of that is a Bash-tool
# call, so no PreToolUse hook is consulted for it. A Bash call that merely
# STARTS that machinery (`butler-continuity on ...`, a test run) names none of
# the commands below and is allowed.
#
# HOW. The command is walked with GuardBash's shared command walker
# (_hyg_commands: quote-aware segments, `$(...)` and backticks, `&`, pipes,
# `sh -c` / `eval` recursion, and the wrappers env, sudo, nohup, nice,
# timeout, time, command, exec, builtin, stdbuf, noglob, nocorrect), and each
# command word is reduced the way the shell resolves it: a path, zsh's
# `=name`, `\name`, a `.exe` suffix, any letter case (macOS and Windows find
# commands case-insensitively). On top of that walk: xargs, doas and the
# %WRAPPER commands (screen, tmux, launchctl, find -exec, su -c, cmd /c, ...),
# `env -S` and `exec -a`, PowerShell's -Command text, a heredoc or pipe into a
# shell (read as commands), interpreter one-liners that exec a target, and a
# command word nobody can resolve ($c) in a command that names a target. The
# hook's text prefilter sees only literal names: `caf""feinate` never reaches perl.
#
# A GUIDANCE GUARD, NOT A SANDBOX. A cooperating agent's every ordinary
# spelling is denied; an adversary with a shell can always reach a binary
# some way no text check sees. That is the line every guard here draws.
#
# run($p, @args) never calls exit, never dies on purpose, never spawns a
# process. Prints only through BpHook::deny(@lines). Fail direction: open
# (return 0) on any internal error; BpHook::main logs it.
package BpHook::Guards::GuardSleepControl;
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd ();

my $SELF_DIR;
{
    my $f = __FILE__;
    $f = Cwd::abs_path($f) // $f;
    $SELF_DIR = dirname($f);
}
require "$SELF_DIR/../../BpHook.pm"
    unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
require "$SELF_DIR/Common.pm"
    unless grep { m{(?:^|/)Guards/Common\.pm$} } keys %INC;
require "$SELF_DIR/GuardBash.pm"
    unless grep { m{(?:^|/)Guards/GuardBash\.pm$} } keys %INC;

# powercfg verbs that only read (case-insensitive, after the leading / or -).
# /requestsoverride is a read only with no further argument (it then lists the
# overrides); with arguments it sets one, so it is handled apart.
my %POWERCFG_READ = map { $_ => 1 } qw(
    requests list l getactivescheme query q qh a availablesleepstates
    lastwake devicequery waketimers energy batteryreport sleepstudy srumutil
    systemsleepdiagnostics systempowerreport spr ? help getsecuritydescriptor
    aliases aliasesh
);

my %SHELL = map { $_ => 1 } qw(sh bash zsh ksh dash);

# Commands that run another command given in their arguments, beyond the
# wrappers GuardBash's walker already unwraps (env, sudo, nohup, nice,
# timeout, time, command, exec, builtin, stdbuf, noglob, nocorrect) and xargs
# and doas below. Their arguments are searched for a target command word, and
# an argument with spaces in it is read as a command line of its own.
my %WRAPPER = map { $_ => 1 } qw(
    screen tmux launchctl script find arch xcrun watch taskpolicy coproc repeat
    su chroot unbuffer parallel cmd runas
);

# The command words _classify knows, for the wrapper search.
my %TARGET = map { $_ => 1 } qw(caffeinate pmset powercfg systemd-inhibit systemsetup pkill killall perl bp-keepawake.pl keepawake.pm);

# Interpreter one-liners: the code argument is only searched when the code
# also execs something, and then only for a target that STARTS a string or a
# quoted command (system("caffeinate ..."), ["caffeinate", ...], `caffeinate`,
# qx{caffeinate}), so `perl -ne 'print if /caffeinate/'` stays allowed.
my %ONE_LINER = (perl => qr/^-[A-Za-z]*[eE]$/, ruby => qr/^-[A-Za-z]*e$/, node => qr/^-(?:e|-eval|p|-print)$/,
                 python => qr/^-[A-Za-z]*c$/, python3 => qr/^-[A-Za-z]*c$/, osascript => qr/^-e$/);
my $EXEC_PRIMITIVE = qr/\b(?:system|exec\w*|qx|popen\w*|spawn\w*|subprocess|child_process|Start-Process)\b|do shell script|\x60|%x[\[({]/i;

# _cmd_name($word) -> the command a shell runs for this word, folded to lower
# case (an over-fold on a case-sensitive host only ever over-denies a command
# that does not exist there), without a path, `=`, or `.exe`.
sub _cmd_name {
    my ($w) = @_;
    my $n = BpHook::Guards::GuardBash::_hyg_command_name($w);
    return defined $n ? lc $n : undef;
}

sub _lit {
    my ($w) = @_;
    return undef unless ref $w eq 'HASH';
    return $w->{literal} if defined $w->{literal};
    return BpHook::Guards::GuardBash::_hyg_dequote($w->{raw})
        if defined $w->{raw} && BpHook::Guards::GuardBash::_hyg_raw_safe($w->{raw});
    return undef;
}

sub _raw_text {
    my ($w) = @_;
    return '' unless ref $w eq 'HASH';
    return defined $w->{literal} ? $w->{literal} : (defined $w->{raw} ? BpHook::Guards::GuardBash::_hyg_dequote($w->{raw}) : '');
}

sub _basename {
    my ($s) = @_;
    return '' unless defined $s;
    (my $b = $s) =~ s{.*[/\\]}{};
    return lc $b;
}

# ---------------------------------------------------------------------------
# _classify($name, \@argv_words) -> { what, hint } | undef for ONE command.
# ---------------------------------------------------------------------------
sub _classify {
    my ($name, $argv) = @_;
    return undef unless defined $name;
    my @lit = map { _lit($_) } @$argv;

    if ($name eq 'caffeinate') {
        return { what => 'caffeinate' };
    }
    if ($name eq 'pmset') {
        return undef unless @lit;                                    # usage text
        return undef if defined $lit[0] && $lit[0] =~ /\A-g/;         # every read
        my $verb = defined $lit[0] ? $lit[0] : '(an unresolvable argument)';
        return { what => "pmset $verb", hint => 'pmset' };
    }
    if ($name eq 'powercfg') {
        return undef unless @lit;                                    # help text
        my $v = $lit[0];
        if (defined $v) {
            (my $k = lc $v) =~ s{\A[/-]+}{};
            return undef if $POWERCFG_READ{$k};
            return undef if $k eq 'requestsoverride' && @lit == 1;
        }
        return { what => 'powercfg ' . (defined $v ? $v : '(an unresolvable argument)'), hint => 'powercfg' };
    }
    # macOS's other way to the same settings: -set<...>sleep writes them.
    if ($name eq 'systemsetup') {
        my ($set) = grep { defined $_ && /\A-set\w*sleep/i } @lit;
        return { what => "systemsetup $set", hint => 'systemsetup' } if defined $set;
        return undef;
    }
    # Killing caffeinate is toggling it off by hand: it takes down the managed
    # lock and Claude Code's own assertion along with any hand-run one.
    if (($name eq 'pkill' || $name eq 'killall') && grep { defined $_ && /caffeinate/i } @lit) {
        return { what => "$name caffeinate" };
    }
    if ($name eq 'systemd-inhibit') {
        return undef if @lit == 1 && defined $lit[0] && $lit[0] =~ /\A(?:--list|-h|--help|--version)\z/;
        return { what => 'systemd-inhibit', hint => 'systemd-inhibit' };
    }
    # A ccpraxis keep-awake holder started by hand, run directly or through
    # perl: the managed lock is the lease's to take and release.
    my @rest = @lit;
    if ($name =~ /\Aperl/) {
        while (@rest && defined $rest[0] && $rest[0] =~ /\A-/) {
            my $opt = shift @rest;
            shift @rest if $opt =~ /\A-[IMmx]\z/ && @rest;   # an option with a separate value
        }
    } else {
        unshift @rest, $name;
    }
    my @script = map { defined $_ ? _basename($_) : '' } @rest;
    if (@script >= 2 && ($script[0] eq 'bp-keepawake.pl' || $script[0] eq 'keepawake.pm') && $script[1] eq 'hold') {
        return { what => 'a hand-started keep-awake holder (' . $script[0] . ' hold)' };
    }
    return undef;
}

# _scan_text($text, $mode) -> { what, hint } | undef. For text the walker
# cannot see as commands. $mode:
#   'shell' (default)  a target at a word start (after a separator, a space,
#                      a quote, '=' or a path) -- PowerShell -Command text and
#                      a comment-free command with an unresolvable command word;
#   'code'             a target that starts a string or a quoted command in an
#                      interpreter one-liner that execs something.
# keep-awake.ps1 counts only where it is run (-File, &, Start-Process, a
# powershell argument), SetThreadExecutionState only where it is called or
# declared (`SetThreadExecutionState(`): a mention reads as a mention.
sub _scan_text {
    my ($t, $mode) = @_;
    return undef unless defined $t && length $t;
    my $A = ($mode // 'shell') eq 'code'
        ? '(?:["\'\x60(\[{,]\s*|\bq[qwx]?\s*[{(\[\/|!<]\s*)(?:[^\s"\'\x60]*\/)?'
        : '(?:^|[;&|\s\'"\x60({=\/\\\\])';
    return { what => 'caffeinate' } if $t =~ /${A}caffeinate(?:\.exe)?(?![\w.-])/im;
    return { what => 'systemd-inhibit', hint => 'systemd-inhibit' }
        if $t =~ /${A}systemd-inhibit(?![\w.-])(?![\s"',]+(?:--list|-h|--help|--version)\s*(?:$|[;&|)'"\]]))/im;
    while ($t =~ /${A}pmset(?![\w.-])[ \t"',]*([^\s;&|)'",\]]*)/gim) {
        my $arg = $1;
        next if $arg =~ /\A-g/ || $arg eq '';
        return { what => "pmset $arg", hint => 'pmset' };
    }
    while ($t =~ /${A}powercfg(?:\.exe)?(?![\w.-])[ \t"',]*([^\s;&|)'",\]]*)([ \t"',]+[^\s;&|)'",\]])?/gim) {
        my ($arg, $more) = ($1, $2);
        next if $arg eq '';
        (my $k = lc $arg) =~ s{\A[/-]+}{};
        next if $POWERCFG_READ{$k};
        next if $k eq 'requestsoverride' && !defined $more;
        return { what => "powercfg $arg", hint => 'powercfg' };
    }
    return { what => 'SetThreadExecutionState' } if $t =~ /SetThreadExecutionState\s*\(/i;
    return { what => 'a hand-started keep-awake helper (keep-awake.ps1)' }
        if $t =~ /(?:-File\s+|&\s*|Start-Process\b[^;|\n]*?|\b(?:powershell|pwsh)(?:\.exe)?\s+)['"]?[^\s'";|]*keep-awake\.ps1/i;
    return { what => 'a hand-started keep-awake holder (bp-keepawake.pl hold)' } if $t =~ /bp-keepawake\.pl\W+hold\b/i;
    return { what => 'a hand-started keep-awake holder (KeepAwake.pm hold)' } if $t =~ /KeepAwake\.pm\W+hold\b/i;
    return undef;
}

# The walk is bounded like GuardBash's own (_hyg_commands takes an absolute
# deadline and dies past it): a pathological command costs at most this long,
# and then the guard lets it through (fail open, as every check here does).
our $WALK_SECONDS = 2;
our $DEADLINE_AT;

# _heredoc_bodies($cmd) -> the text of each heredoc in $cmd (what a shell
# reading it would run).
sub _heredoc_bodies {
    my ($cmd) = @_;
    my @b;
    while ($cmd =~ /<<-?[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_.-]*)\1[^\n]*\n(.*?)(?:\n[ \t]*\2[ \t]*(?:\n|\z)|\z)/gs) {
        push @b, $3;
    }
    return @b;
}

# _on_path($word) -> 1 when $word names an executable (a path, or a name
# found on PATH): the command a wrapper runs, after which the remaining words
# are that command's own arguments.
sub _on_path {
    my ($w) = @_;
    return 0 unless defined $w && length $w && $w !~ /\A-/;
    return (-f $w && -x _) ? 1 : 0 if $w =~ m{[/\\]};
    for my $d (split /:/, ($ENV{PATH} // '')) {
        next unless length $d;
        return 1 if -f "$d/$w" && -x _;
    }
    return 0;
}

# _search_args(\@words, $depth, $wrapper) -> hit | undef: a wrapper's
# arguments, searched up to the command it runs. A target command word is
# classified with the words after it; an argument holding a command line of
# its own (`tmux new -d 'caffeinate -i'`) is read as one; the first other
# executable ends the search, since what follows is its own arguments
# (`watch grep caffeinate log` greps). find runs only what follows -exec,
# -execdir, -ok and -okdir (`find . -exec grep caffeinate {} +` greps too).
sub _search_args {
    my ($words, $depth, $wrapper) = @_;
    $wrapper //= '';
    my $after_exec = 0;
    for my $i (0 .. $#$words) {
        my $l = _lit($words->[$i]);
        next unless defined $l;
        if ($wrapper eq 'find') {
            if ($l =~ /\A-(?:exec|execdir|ok|okdir)\z/) { $after_exec = 1; next }
            next unless $after_exec;
            $after_exec = 0;
        }
        if ($l =~ /\s/) {
            my $h = _verdict($l, $depth + 1);
            return $h if $h;
            next;
        }
        my $n = _cmd_name($words->[$i]);
        if (defined $n && $TARGET{$n}) {
            return _classify($n, [ @{$words}[$i + 1 .. $#$words] ]) unless $n eq 'perl';
            my $h = _classify($n, [ @{$words}[$i + 1 .. $#$words] ]);
            return $h if $h;
            last;
        }
        last if $wrapper ne 'find' && _on_path($l);
    }
    return undef;
}

# _verdict($cmd, $depth) -> { what, hint } | undef for a whole command.
sub _verdict {
    my ($cmd, $depth) = @_;
    $depth //= 0;
    return undef if $depth > 3 || !defined $cmd || !length $cmd;
    my @commands = BpHook::Guards::GuardBash::_hyg_commands($cmd, 0, $DEADLINE_AT);
    my $unresolved = 0;
    my $stdin_shell = 0;
    for my $e (@commands) {
        next unless ref $e eq 'HASH';
        my $name = _cmd_name($e->{name});
        my @argv = @{ $e->{argv} || [] };
        if (!defined $name) {
            $unresolved = 1 if defined $e->{name};
            next;
        }
        # A command word with spaces is a command line re-read by its wrapper
        # (`env -S "caffeinate -i"`); an option where the command should be
        # (`exec -a name caffeinate`) leaves the command among the arguments.
        if ($name =~ /\s/) {
            my $h = _verdict(_lit($e->{name}) // $name, $depth + 1);
            return $h if $h;
            next;
        }
        if ($name =~ /\A-/) {
            my $h = _search_args(\@argv, $depth, 'exec');
            return $h if $h;
            next;
        }
        # xargs and doas run the rest of their arguments as a command.
        while (defined $name && ($name eq 'xargs' || $name eq 'doas')) {
            my $is_xargs = $name eq 'xargs';
            while (@argv && defined(my $l = _lit($argv[0]))) {
                last unless $l =~ /\A-/;
                shift @argv;
                # xargs options with a separate value; doas -u user / -C config.
                shift @argv if ($is_xargs && $l =~ /\A-[IJLnPsEd]\z/) || (!$is_xargs && $l =~ /\A-[uC]\z/);
            }
            last unless @argv;
            my $w = shift @argv;
            $name = _cmd_name($w);
            $unresolved = 1 unless defined $name;
        }
        next unless defined $name;

        my $hit = _classify($name, \@argv);
        return $hit if $hit;

        if ($WRAPPER{$name}) {
            my $h = _search_args(\@argv, $depth, $name);
            return $h if $h;
        }
        # PowerShell: its -Command text is commands too, and
        # SetThreadExecutionState / keep-awake.ps1 are what caffeinate is on a
        # Mac.
        if ($name =~ /\A(?:powershell|pwsh)\z/) {
            my $h = _scan_text(join(' ', map { _raw_text($_) } @argv), 'shell');
            return $h if $h;
        }
        # A shell reading its commands from stdin (no -c, no script operand).
        if ($SHELL{$name} && !defined BpHook::Guards::GuardBash::_hyg_find_shellc_script(\@argv)) {
            my $first_operand = (grep { my $l = _lit($_); !defined $l || $l !~ /\A[-+]/ } @argv)[0];
            $stdin_shell = 1 unless defined $first_operand;
        }
        # Interpreter one-liners that exec something.
        if (my $flag_re = $ONE_LINER{$name}) {
            for my $i (0 .. $#argv) {
                my $l = _lit($argv[$i]);
                next unless defined $l && $l =~ $flag_re;
                my $code = defined $argv[$i + 1] ? _raw_text($argv[$i + 1]) : '';
                next unless $code =~ $EXEC_PRIMITIVE;
                my $h = _scan_text($code, 'code');
                return $h if $h;
            }
        }
    }
    # A shell reading stdin runs a heredoc's body, or what a pipe feeds it:
    # read the bodies as commands, else every argument of the other commands
    # (`echo 'caffeinate -i' | sh`).
    if ($stdin_shell) {
        my @bodies = _heredoc_bodies($cmd);
        unless (@bodies) {
            for my $e (@commands) {
                next unless ref $e eq 'HASH';
                push @bodies, grep { defined && length } map { _lit($_) } @{ $e->{argv} || [] };
            }
            splice(@bodies, 50) if @bodies > 50;
        }
        for my $b (@bodies) {
            my $h = _verdict($b, $depth + 1);
            return $h if $h;
        }
    }
    # A command word nobody can resolve (`c=caffeinate; $c -i`) in a command
    # that names a target: the target may be what runs. Searched without its
    # comments and heredoc bodies (BpHook::_segments drops both).
    if ($unresolved) {
        my $h = _scan_text(join("\n", grep { defined } eval { BpHook::_segments($cmd) }), 'shell');
        return $h if $h;
    }
    return undef;
}

# verdict_for($cmd) -> { what, hint } | undef. The whole decision for a
# command string, bounded by $WALK_SECONDS; undef (allow) if the walk fails
# or runs out of time. Public for tests: no payload needed.
sub verdict_for {
    my ($cmd) = @_;
    local $DEADLINE_AT = do { require Time::HiRes; Time::HiRes::time() + $WALK_SECONDS };
    my $v = eval { _verdict($cmd, 0) };
    return $@ ? undef : $v;
}

# _platform_line() -> what the managed lock does on THIS host, chosen here
# rather than listed per OS in the message.
sub _platform_line {
    return 'On this Mac it is caffeinate -i, only on AC power: idle sleep is held off, a closed lid always sleeps the Mac.'
        if $^O eq 'darwin';
    return undef;
}

my %HINT = (
    pmset             => 'Read-only pmset -g (pmset -g, -g ps, -g assertions, -g log) is allowed.',
    powercfg          => 'Read-only queries (powercfg /requests, /list, /query, /a, /lastwake) are allowed.',
    'systemd-inhibit' => 'systemd-inhibit --list is allowed.',
    systemsetup       => 'Read-only systemsetup -get... (-getcomputersleep, -getdisplaysleep) is allowed.',
);

# ---------------------------------------------------------------------------
# run($p, @args) -> 0 | 2.
# ---------------------------------------------------------------------------
sub run {
    my ($p, @args) = @_;
    $p = {} unless ref $p eq 'HASH';
    return 0 unless BpHook::payload_ok();
    return 0 unless defined $p->{tool_name} && $p->{tool_name} eq 'Bash';
    my $ti = $p->{tool_input};
    return 0 unless ref $ti eq 'HASH';
    my $cmd = $ti->{command};
    return 0 unless defined $cmd && !ref($cmd) && length $cmd;

    my $hit = verdict_for($cmd);
    return 0 unless $hit;

    my @lines = ("BLOCKED: $hit->{what} changes this machine's sleep behaviour by hand, and nothing releases a hand-taken lock when the work ends.");
    if (defined BpHook::agent_id($p)) {
        push @lines, "Keeping the machine awake belongs to the main session's continuity arm; a subagent never manages it.";
    }
    elsif (BpHook::is_armed(BpHook::session_id($p))) {
        push @lines, 'This session is armed, so the managed wake-lock already keeps the machine awake while its work is in flight.';
    }
    else {
        push @lines, "The one sanctioned way to keep it awake: arm continuity, butler-continuity on --new-thread <name> --goal '<what this is for>'.";
    }
    push @lines, 'The managed lock is held only while work is in flight and released when it ends or continuity is turned off.';
    my $pl = _platform_line();
    push @lines, $pl if defined $pl;
    push @lines, $HINT{ $hit->{hint} } if defined $hit->{hint} && $HINT{ $hit->{hint} };
    push @lines, 'Command: ' . BpHook::Guards::Common::echo_cmd($cmd);
    return BpHook::deny(map { BpHook::Guards::Common::fit($_) } @lines);
}

1;
