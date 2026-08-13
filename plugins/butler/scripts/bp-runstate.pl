#!/usr/bin/env perl
# bp-runstate.pl — the run-state machine behind the stop gate.
#
# WHY IT IS A STATE MACHINE AND NOT A DETECTOR
#
# The first two attempts at this gate both asked "does anything look wrong?" —
# first "did a Bash command mention a guard token", then "does the closing
# prose promise work". Both are detectors, and a detector is only as good as
# its guesses: the token version accepted a guard that died on launch, and the
# prose version can be sidestepped by rephrasing a sentence.
#
# This inverts the default. The gate is INERT until a run actually starts, and
# once active the turn may not end until the agent RESOLVES it — explicitly,
# with a verb, in one of exactly two ways:
#
#   finish  — the run is over. Nothing pending. Back to inert.
#   pause   — the run continues, but something else will wake it. Requires a
#             LIVE watcher (real pid + future deadline), which the gate
#             verifies rather than takes on trust.
#
# There is no third way and no "looks fine to me". Silence is not a resolution.
#
# STATES
#   (absent)  inert   — no run. Stopping is always allowed.
#   active            — work is underway. Stopping is DENIED.
#   paused            — resolved temporarily; a verified watcher will resume it.
#                       Stopping is allowed WHILE the watcher is alive; once it
#                       dies or its deadline passes the pause is stale and the
#                       state reverts to active on the next read.
#   finished          — resolved permanently. Stopping is allowed.
#
# ACTIVATION IS NOT A THING THE AGENT MUST REMEMBER. The hook activates on the
# observable fact that a run started: a background subagent dispatch, or a
# director tick that returned run-package. Anything the agent must remember to
# do is a thing it will eventually forget — that is the whole reason this file
# exists.
#
# SCOPE. Project-level, not session-level: "a run" is a property of the
# project. drive-solo is explicitly one interactive session, so the simpler
# scope is the correct one here. Two concurrent drive sessions in one project
# would share this state; that is out of contract for drive-solo.

package BpRunState;
use strict;
use warnings;
use JSON::PP ();
use File::Basename qw(dirname);
use Cwd ();

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });

sub state_dir {
    my ($root) = @_;
    $root //= $ENV{CLAUDE_PROJECT_DIR} // Cwd::abs_path("$DIR/../../..") // '.';
    return "$root/.ccpraxis-local-data/.subagent-guard";
}
sub state_path { return state_dir($_[0]) . '/run-state.json' }

# pid_alive($pid) — see bp-keepawake.pl for why kill(0) is not enough on
# Windows: perl cannot signal a native process it did not create, and reports a
# healthy one as dead. A watcher we cannot verify must NOT hold a pause open.
sub pid_alive {
    my ($pid) = @_;
    return 0 unless defined $pid && $pid =~ /^\d+$/ && $pid > 0;
    return kill(0, $pid) ? 1 : 0 unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    return 1 if kill(0, $pid);
    my $out = do { local $ENV{MSYS2_ARG_CONV_EXCL} = '*'; `tasklist /FI "PID eq $pid" /NH` };
    return 0 unless defined $out;
    return ($out =~ /\b\Q$pid\E\b/) ? 1 : 0;
}

sub _read {
    my ($root) = @_;
    my $p = state_path($root);
    open my $fh, '<', $p or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return undef unless defined $raw && length $raw;
    my $j = eval { JSON::PP->new->decode($raw) };
    return (ref $j eq 'HASH') ? $j : undef;
}

sub _write {
    my ($root, $rec) = @_;
    my $d = state_dir($root);
    unless (-d $d) {
        # mkdir -p, and the leading separator is LOAD-BEARING. An earlier version
        # started $cur at '' and skipped empty components, which turned an
        # absolute "/tmp/x/y" into a RELATIVE "tmp/x/y" and created the whole
        # tree under the current working directory. Reproduced immediately: it
        # left ./tmp/tmp.K4d60R6Qym/... in the repo root — the same stray class
        # as the 576 drive-root entries in CLAUDE.md, from the same root cause
        # of treating an absolute path as relative.
        my $cur = ($d =~ m{^/}) ? '/' : '';
        for my $part (grep { length } split m{/}, $d) {
            $cur = ($cur eq '' || $cur eq '/') ? "$cur$part" : "$cur/$part";
            next if $cur =~ /^[A-Za-z]:$/;      # bare drive letter is not a dir
            unless (-d $cur) { mkdir $cur or return 0 }
        }
        return 0 unless -d $d;
    }
    my $p   = state_path($root);
    my $tmp = "$p.tmp.$$";
    open my $fh, '>', $tmp or return 0;
    print {$fh} JSON::PP->new->canonical->encode($rec);
    close $fh;
    rename($tmp, $p) or do { unlink $tmp; return 0 };
    return 1;
}

# effective($root) -> ($state, \%rec)
#
# The ONLY reader anything else should use. It resolves a stale pause back to
# active, which is the property that makes a pause safe to grant: a pause whose
# watcher died is indistinguishable from an abandoned run, so it must not keep
# permitting stops.
sub effective {
    my ($root) = @_;
    my $rec = _read($root) or return ('inert', {});
    my $st  = $rec->{state} // 'inert';
    return ($st, $rec) unless $st eq 'paused';

    my $ok = pid_alive($rec->{watcher_pid});
    $ok = 0 if $ok && defined $rec->{until} && $rec->{until} =~ /^\d+$/ && $rec->{until} <= time;
    return ('active', { %$rec, stale_pause => 1 }) unless $ok;
    return ('paused', $rec);
}

sub activate {
    my ($root, $reason) = @_;
    my ($st, $rec) = effective($root);
    # Never downgrade an explicit pause into active on a fresh dispatch — the
    # watcher is still live and the agent already resolved this turn.
    return 1 if $st eq 'paused';
    return _write($root, { state => 'active', reason => ($reason // 'run in progress'),
                           updated_at => time });
}

sub pause {
    my ($root, %o) = @_;
    my $pid = $o{watcher_pid};
    return (0, 'a pause needs --watcher-pid: an unwatched pause is just a stop')
        unless defined $pid && $pid =~ /^\d+$/;
    return (0, "watcher pid $pid is not running — a dead watcher cannot resume anything")
        unless pid_alive($pid);
    my $until = $o{until};
    return (0, 'a pause needs --until (epoch seconds): an unbounded pause never resumes')
        unless defined $until && $until =~ /^\d+$/;
    return (0, "--until $until is in the past")
        unless $until > time;
    _write($root, { state => 'paused', reason => ($o{reason} // 'waiting on a watcher'),
                    watcher_pid => $pid + 0, until => $until + 0, updated_at => time })
        or return (0, 'could not write the run state');
    return (1, "paused until $until, watched by pid $pid");
}

sub finish {
    my ($root, $reason) = @_;
    _write($root, { state => 'finished', reason => ($reason // 'run complete'),
                    updated_at => time })
        or return (0, 'could not write the run state');
    return (1, 'run finished; the gate is inert again');
}

package main;
use strict;
use warnings;

unless (caller) {
    my $cmd  = shift @ARGV // '';
    my %o;
    while (@ARGV) {
        my $a = shift @ARGV;
        if    ($a eq '--reason')      { $o{reason}      = shift @ARGV }
        elsif ($a eq '--watcher-pid') { $o{watcher_pid} = shift @ARGV }
        elsif ($a eq '--until')       { $o{until}       = shift @ARGV }
        elsif ($a eq '--root')        { $o{root}        = shift @ARGV }
        else { print STDERR "bp-runstate: unknown option '$a'\n"; exit 3 }
    }
    my $root = $o{root};

    if ($cmd eq 'status') {
        my ($st, $rec) = BpRunState::effective($root);
        # ORDER MATTERS: the record's own `state` is what was WRITTEN; $st is
        # what it EFFECTIVELY is now (a pause whose watcher died reads back as
        # active). Spreading %$rec last would let the stored value clobber the
        # computed one, and a stale pause would go on permitting stops — the
        # exact hole the reversion exists to close. Caught by t/112.
        print JSON::PP->new->canonical->encode({ %$rec, state => $st }), "\n";
        exit 0;
    }
    elsif ($cmd eq 'activate') {
        BpRunState::activate($root, $o{reason}) or exit 4;
        exit 0;
    }
    elsif ($cmd eq 'pause') {
        my ($ok, $msg) = BpRunState::pause($root, %o);
        print STDERR "bp-runstate: pause refused: $msg\n" unless $ok;
        print "$msg\n" if $ok;
        exit($ok ? 0 : 2);
    }
    elsif ($cmd eq 'finish') {
        my ($ok, $msg) = BpRunState::finish($root, $o{reason});
        print STDERR "bp-runstate: $msg\n" unless $ok;
        print "$msg\n" if $ok;
        exit($ok ? 0 : 4);
    }
    else {
        print STDERR <<'USAGE';
bp-runstate.pl — the run-state behind the stop gate.

  status                                   print the effective state as JSON
  activate [--reason R]                    mark a run underway (the hook does
                                           this automatically; rarely manual)
  pause --watcher-pid N --until EPOCH [--reason R]
                                           resolve THIS turn: something live
                                           will wake the session. Refused if
                                           the pid is not running or the
                                           deadline is not in the future.
  finish [--reason R]                      resolve permanently: nothing pending

Stopping is DENIED while the state is active. `pause` and `finish` are the only
two resolutions; there is no third.
USAGE
        exit 3;
    }
}
1;
