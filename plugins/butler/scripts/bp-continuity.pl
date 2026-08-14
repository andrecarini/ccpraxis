#!/usr/bin/env perl
# bp-continuity.pl — explicit continuity arm/disarm/status for THIS session.
#
# g01-explicit-continuity-arming: the canonical mechanism for arming a
# session doing unattended work with no blueprint, no drive-solo, no
# reporter. Callable directly by the agent (Bash tool) or wrapped by the
# /butler:continuity skill (operator-facing). See
# specs/g01-explicit-continuity-arming-spec.md SS2.1/SS2.2.
#
# Subcommands:
#   arm    [--session <id>] [--by operator|agent]   (default --by agent)
#   disarm [--session <id>]
#   status [--session <id>]
#
# Session resolution: --session if given, else $ENV{CLAUDE_SESSION_ID}, else
# ERROR (exit 1) — this is a direct, non-hook invocation, so silently no-op-
# ing on a missing session id would be exactly the "correct, tested, never
# invoked" defect this run has hit repeatedly.
#
# Registry: ${CCPRAXIS_CONTINUITY_ACTIVE_DIR:-$HOME/.claude/ccpraxis/.continuity-active},
# duplicated from lib.sh's bp_continuity_active_dir on purpose (this script
# imports nothing bash-side) — the two resolutions must agree; see
# scripts/statusline.pl's own duplicate for the third leg of that parity.
#
# PATH RESOLUTION — see lib.sh's bp_continuity_active_dir for the single rule
# all three components follow (fix-batch F1): override, else $HOME, else
# $USERPROFILE, else UNRESOLVABLE. Because THIS script is the write path
# (arm/disarm/status all mutate or authoritatively read the registry), an
# unresolvable directory here FAILS LOUDLY (STATUS: error, exit 1) rather
# than guessing — see resolve_registry_dir_or_die() below. That is what makes
# the gate's and the badge's own "unresolvable => treat as nothing armed"
# fail-safe behavior correct rather than a fourth divergent guess: if this
# script could never resolve a directory, it could never have written a
# marker there either.
use strict;
use warnings;
use POSIX qw(strftime);
use File::Path qw(make_path);

my $cmd = shift @ARGV // '';

if    ($cmd eq 'arm')    { cmd_arm()    }
elsif ($cmd eq 'disarm') { cmd_disarm() }
elsif ($cmd eq 'status') { cmd_status() }
else {
    emit('STATUS', 'error');
    emit('ERROR',  "Unknown command '$cmd' (usage: arm|disarm|status)");
    exit 1;
}

# ── Subcommands ─────────────────────────────────────────────

sub cmd_arm {
    my $opts = parse_args(qw(session by));

    if (defined $ENV{BP_LEDGER} && length $ENV{BP_LEDGER}) {
        emit('STATUS', 'error');
        emit('ERROR',  'refused: BP_LEDGER is set (this is a coordinator process; '
                      . 'gate-stop.sh and gate-headless-background.sh already cover it)');
        exit 1;
    }

    my $sid = resolve_session($opts) or return;   # resolve_session already emitted+exited
    my $by = $opts->{by} // 'agent';
    unless ($by eq 'operator' || $by eq 'agent') {
        emit('STATUS', 'error');
        emit('ERROR',  "--by must be 'operator' or 'agent' (got: $by)");
        exit 1;
    }

    my $dir = resolve_registry_dir_or_die();
    my $mark = continuity_marker($sid, $dir);
    unless (defined $mark) {
        emit('STATUS', 'error');
        emit('ERROR',  "invalid session id: $sid");
        exit 1;
    }

    make_path($dir) unless -d $dir;
    my $since = iso_now();
    open my $fh, '>', $mark or do {
        emit('STATUS', 'error');
        emit('ERROR',  "Cannot write $mark: $!");
        exit 1;
    };
    print {$fh} "$by $since\n";
    close $fh;
    # Explicit touch: on some filesystems a fresh open+print already sets
    # mtime to now, but idempotent re-arm (behavior 8) requires the mtime to
    # move forward on every arm call, not just the first — utime() makes that
    # true unconditionally rather than depending on open() semantics.
    my $now = time();
    utime($now, $now, $mark);

    emit('STATUS',   'armed');
    emit('SESSION',  $sid);
    emit('ARMED_BY', $by);
    emit('SINCE',    $since);
}

sub cmd_disarm {
    my $opts = parse_args(qw(session));
    my $sid = resolve_session($opts) or return;

    my $dir = resolve_registry_dir_or_die();
    my $mark = continuity_marker($sid, $dir);
    unless (defined $mark) {
        emit('STATUS', 'error');
        emit('ERROR',  "invalid session id: $sid");
        exit 1;
    }

    unless (-f $mark) {
        emit('STATUS',  'not_armed');
        emit('SESSION', $sid);
        exit 2;
    }

    # fix-batch F4: a false "disarmed" is the exact mirror of a false
    # "armed" -- both lie about whether the session is watched. Verify the
    # PRIMARY marker is actually gone (re-stat rather than trust unlink's
    # return value alone, since the goal is "is it still enforceable", not
    # "did the syscall report success") before ever claiming disarmed.
    # Companion files are best-effort cleanup: their survival cannot cause
    # gate-continuity.sh to re-block (it only blocks off the PRIMARY
    # marker's presence), so a companion unlink failure does not change the
    # STATUS this command reports.
    unlink $mark;
    unlink "$mark.wakeup-pending";
    unlink "$mark.stop-blocks";
    unlink "$mark.stop-ok";

    if (-f $mark) {
        emit('STATUS',  'error');
        emit('SESSION', $sid);
        emit('ERROR',   "primary marker $mark still exists after unlink (permission or lock?) "
                       . "-- refusing to report disarmed while continuity enforcement may still "
                       . "be in force");
        exit 1;
    }

    emit('STATUS',  'disarmed');
    emit('SESSION', $sid);
}

sub cmd_status {
    my $opts = parse_args(qw(session));
    my $sid = resolve_session($opts) or return;

    my $dir = resolve_registry_dir_or_die();
    my $mark = continuity_marker($sid, $dir);
    unless (defined $mark) {
        emit('STATUS', 'error');
        emit('ERROR',  "invalid session id: $sid");
        exit 1;
    }

    unless (-f $mark) {
        emit('STATUS',  'unarmed');
        emit('SESSION', $sid);
        return;
    }

    open my $fh, '<', $mark or do {
        emit('STATUS',  'unarmed');
        emit('SESSION', $sid);
        return;
    };
    my $line = <$fh>;
    close $fh;
    chomp($line //= '');
    my ($by, $since) = $line =~ /^(\S+)\s+(\S+)/;

    emit('STATUS',   'armed');
    emit('SESSION',  $sid);
    emit('ARMED_BY', $by // 'unknown');
    emit('SINCE',    $since // '');
}

# ── Helpers ────────────────────────────────────────────────

sub emit {
    my ($key, $val) = @_;
    print "$key: $val\n";
}

sub iso_now {
    return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime());
}

# resolve_session(\%opts) -> session id, or exits 1 with STATUS: error.
sub resolve_session {
    my ($opts) = @_;
    my $sid = $opts->{session};
    $sid = $ENV{CLAUDE_SESSION_ID} unless defined $sid && length $sid;
    unless (defined $sid && length $sid) {
        emit('STATUS', 'error');
        emit('ERROR',  'no session id: pass --session or set $CLAUDE_SESSION_ID');
        exit 1;
    }
    return $sid;
}

# continuity_active_dir() -> the registry dir, or undef if UNRESOLVABLE.
# Duplicated from lib.sh's bp_continuity_active_dir on purpose; must resolve
# IDENTICALLY for a given environment (spec SS2.6/AC-13; fix-batch F1's
# single rule, documented in full at lib.sh's bp_continuity_active_dir):
# override, else $HOME, else $USERPROFILE, else undef. Does NOT guess $PWD
# or '.' -- see resolve_registry_dir_or_die(), the only caller, which is
# where the "fail loudly" half of F1's rule actually lives.
sub continuity_active_dir {
    return $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR}
        if defined $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} && length $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
    my $home = $ENV{HOME};
    $home = $ENV{USERPROFILE} unless defined $home && length $home;
    return undef unless defined $home && length $home;
    return "$home/.claude/ccpraxis/.continuity-active";
}

# resolve_registry_dir_or_die() -> the registry dir, or exits 1 with
# STATUS: error if UNRESOLVABLE (fix-batch F1). This script is the WRITE
# path (arm mutates the registry; disarm/status are its authoritative
# reads), so an unresolvable directory here must never silently fall back
# to $PWD or '.' -- that is exactly how the gate and the badge would end up
# looking in a different place than arm just wrote to.
sub resolve_registry_dir_or_die {
    my $dir = continuity_active_dir();
    unless (defined $dir) {
        emit('STATUS', 'error');
        emit('ERROR',  'cannot resolve continuity registry directory: neither $HOME nor '
                      . '$USERPROFILE is set, and CCPRAXIS_CONTINUITY_ACTIVE_DIR is not set '
                      . 'either -- refusing to guess a location (e.g. $PWD or \'.\') that the '
                      . 'gate and the statusline badge would not agree with');
        exit 1;
    }
    return $dir;
}

# continuity_marker($sid, $dir) -> marker path, or undef for an invalid id.
# Mirrors bp_continuity_marker's refusals exactly: a path separator, a
# backslash (fix-batch F3 -- see lib.sh's bp_continuity_marker for why),
# a glob metacharacter, or a literal '.' anywhere in the id. Takes $dir
# explicitly (rather than re-resolving) so callers control whether/how an
# unresolvable directory is reported -- see resolve_registry_dir_or_die().
sub continuity_marker {
    my ($sid, $dir) = @_;
    return undef unless defined $sid && length $sid;
    return undef if $sid =~ m{[/\\*.\x00]};
    return undef unless defined $dir;
    return "$dir/$sid";
}

sub parse_args {
    my @known = @_;
    my %known = map { $_ => 1 } @known;
    my %opts;
    while (my $arg = shift @ARGV) {
        unless ($arg =~ /^--([\w-]+)$/ && $known{$1}) {
            emit('STATUS', 'error');
            emit('ERROR',  "Unknown or unexpected argument: $arg");
            exit 1;
        }
        my $key = $1;
        my $val = shift @ARGV;
        unless (defined $val) {
            emit('STATUS', 'error');
            emit('ERROR',  "Flag --$key requires a value");
            exit 1;
        }
        $opts{$key} = $val;
    }
    return \%opts;
}
