#!/usr/bin/env perl
# bp-write-guard.pl — BpWrite::guarded_write, the a01-write-integrity-reread-under-lock
# primitive: lock -> re-read-under-the-lock -> validate -> mutate -> temp+rename ->
# READ-BACK (still under the lock) -> release. This closes the gap the source report
# named: "state is read, a decision is made, and the write lands against a world that
# has since changed — with no re-read and no read-back."
#
# The read-back proves the bytes are readable through the filesystem after the rename
# WHILE THE LOCK IS STILL HELD. It does NOT fsync and does NOT claim to survive a power
# loss — it proves visibility, not durability (spec §5 edge case 8).
#
# Core Perl only. Never touches STDOUT/STDERR, never dies, never exits (§2.5 — callers
# such as bp-answer-decision.pl parse their own combined stdout+stderr as JSON, so a
# stray line here would corrupt that).
#
# require:  require "<path>/bp-write-guard.pl"; BpWrite::guarded_write({ ... });
# CLI seam (single source of truth for the timeout, consumed by bp-lib.sh):
#   perl bp-write-guard.pl --lock-timeout       -> prints $LOCK_TIMEOUT_SECS, exit 0
#   perl bp-write-guard.pl --lock-path <file>   -> prints "<file>.lock", exit 0
#   anything else                               -> usage on stderr, exit 2

package BpWrite;
use strict;
use warnings;
use Fcntl qw(:flock);
use File::Basename qw(dirname);
use Cwd qw(abs_path);

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; abs_path($f) // $f });
require "$DIR/bp-log.pl";   # BpLog::event -- structured, crash-safe log lines

# Single source of truth for the lock-acquisition bound (spec §2.2): bounded
# everywhere, one value, a timeout is a reported refusal, never a silent skip and
# never an unbounded block. Matches the shipped shell value (bp-lib.sh's `flock -w
# 10`); bp-lib.sh now DERIVES its literal from this value via the CLI seam below
# rather than hardcoding it a second time.
our $LOCK_TIMEOUT_SECS = 10;

# --- injected seams (spec §8) -- all default to no-op/undef, so production
# behaviour is byte-identical to having no seam at all.
our $AFTER_LOCK_HOOK;      # fires after the lock is held, before read()
our $BEFORE_COMMIT_HOOK;   # fires after validity passes, before temp+rename
our $AFTER_COMMIT_HOOK;    # fires after the rename, before the read-back
our $NOW_FN = sub { return time; };
# fixbatch step7 / MINOR 10: the previous shape here honoured
# $ENV{BP_WRITEGUARD_FAIL_RENAME} at REQUIRE TIME to force every rename in the
# process to fail -- a production-reachable kill switch (the orchestrator inherits
# its environment and passes it to every spawned coordinator/judge; a single stray
# export would silently disable every guarded write in the whole process tree, and
# at the void-context _set_ledger_status sites -- MAJOR 4 -- that would be
# completely invisible). Grepping the whole tree found no test that actually sets
# this env var out-of-process; $RENAME_FN is already an injectable package
# variable, so in-process tests (`local $BpWrite::RENAME_FN = sub {...}`) never
# needed the env form at all. Removed rather than gated: nothing depends on it.
our $RENAME_FN = sub { return rename($_[0], $_[1]); };

# house precedent: $BpOrch::LAST_EXEC_ERROR (bp-orchestrator.pl:72). Mirrors the
# hashref every call returns, so a converted function can keep its existing
# 0/1-or-path return contract while still exposing the detail.
our $LAST_RESULT;

# re-entrancy guard (AC7): a guarded_write called from inside another guarded_write's
# own callback (valid/mutate/verify) must refuse rather than deadlock or corrupt
# lock ownership. Cleared on every exit path of the OUTER call.
our $HELD_LOCK;

# BpWrite is the single source of the lock-path derivation rule too (spec §2.1), so
# bp-lib.sh and every Perl site derive the SAME path rather than each inventing one.
sub lock_path { my ($target) = @_; return "$target.lock"; }

sub _effective_timeout {
    my ($opt_timeout) = @_;
    return $opt_timeout + 0 if defined $opt_timeout && $opt_timeout =~ /^\d+$/ && $opt_timeout > 0;
    my $env = $ENV{BP_WRITEGUARD_LOCK_TIMEOUT};
    return $env + 0 if defined $env && $env =~ /^\d+$/ && $env > 0;
    return $LOCK_TIMEOUT_SECS;
}

# default `read`: slurp raw, or undef if the file doesn't exist / can't be opened.
sub _default_read {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $x = <$fh>;
    close $fh;
    return $x;
}

# Never lets a log failure escape (the very condition being reported may also break
# the report -- same defensive shape as bp-orchestrator.pl's _escalation_write_failed).
sub _log_event {
    my ($log, $site, $path, $outcome, $reason) = @_;
    return unless defined $log;
    eval {
        BpLog::event($log, 'write_guard', { site => $site, path => $path, outcome => $outcome, reason => $reason });
        1;
    };
    return;
}

sub guarded_write {
    my ($args) = @_;
    my $result = eval { _guarded_write($args) };
    if ($@) {
        # A die anywhere inside must never escape guarded_write (AC6). Best-effort
        # report, then the honest io-error shape.
        my $err = $@;
        $result = { ok => 0, outcome => 'io-error', reason => "internal error: $err", path => $args->{path} };
        _log_event($args->{log}, $args->{site}, $args->{path}, 'io-error', $result->{reason});
    }
    $LAST_RESULT = $result;
    return $result;
}

sub _guarded_write {
    my ($args) = @_;
    my $site    = $args->{site};
    my $path    = $args->{path};
    my $lock_p  = $args->{lock_path} // lock_path($path);
    my $readf   = $args->{read}   // \&_default_read;
    my $validf  = $args->{valid};
    my $mutatef = $args->{mutate};
    my $verifyf = $args->{verify};
    my $log     = $args->{log};
    my $timeout = _effective_timeout($args->{timeout});

    if ($HELD_LOCK) {
        my $r = { ok => 0, outcome => 'nested-lock',
                  reason => 'guarded_write called re-entrantly while another lock is held', path => $path };
        _log_event($log, $site, $path, 'nested-lock', $r->{reason});
        return $r;
    }

    open(my $lk, '>', $lock_p) or do {
        my $r = { ok => 0, outcome => 'io-error', reason => "cannot open lock file $lock_p: $!", path => $path };
        _log_event($log, $site, $path, 'io-error', $r->{reason});
        return $r;
    };

    my $deadline = $NOW_FN->() + $timeout;
    until (flock($lk, LOCK_EX | LOCK_NB)) {
        if ($NOW_FN->() >= $deadline) {
            close $lk;
            my $r = { ok => 0, outcome => 'lock-timeout',
                      reason => "lock not acquired within ${timeout}s", path => $path };
            _log_event($log, $site, $path, 'lock-timeout', $r->{reason});
            return $r;
        }
        select(undef, undef, undef, 0.05);
    }
    $HELD_LOCK = $lock_p;

    my $result = eval { _guarded_write_locked($site, $path, $readf, $validf, $mutatef, $verifyf, $log) };
    if ($@) {
        my $err = $@;
        $result = { ok => 0, outcome => 'io-error', reason => "internal error: $err", path => $path };
        _log_event($log, $site, $path, 'io-error', $result->{reason});
    }

    $HELD_LOCK = undef;
    flock($lk, LOCK_UN);
    close $lk;

    return $result;
}

# Runs entirely UNDER the lock. Returning from inside the `eval BLOCK` this is
# called from exits only the eval, not the enclosing sub (perldoc -f return) --
# every branch below is written to rely on exactly that.
sub _guarded_write_locked {
    my ($site, $path, $readf, $validf, $mutatef, $verifyf, $log) = @_;

    $AFTER_LOCK_HOOK->() if $AFTER_LOCK_HOOK;

    my $state = $readf->($path);   # THE RE-READ, under the lock

    if ($validf) {
        my $reason = $validf->($state);
        if (defined $reason) {
            _log_event($log, $site, $path, 'refused', $reason);
            return { ok => 0, outcome => 'refused', reason => $reason, path => $path };
        }
    }

    my ($new, $mreason) = $mutatef->($state);
    unless (defined $new) {
        _log_event($log, $site, $path, 'refused', $mreason);
        return { ok => 0, outcome => 'refused', reason => $mreason, path => $path };
    }

    my $state_bytes = defined $state ? $state : '';
    if ($new eq $state_bytes) {
        return { ok => 1, outcome => 'unchanged', reason => undef, path => $path };
    }

    $BEFORE_COMMIT_HOOK->() if $BEFORE_COMMIT_HOOK;

    # fixbatch step7 / MINOR 11: best-effort prune of `$path.tmp.<pid>` files a
    # PAST crash left behind (a crash between this call's own temp-write and its
    # rename, in an earlier process). Safe to do here: we hold the exclusive lock
    # on $path, so any OTHER $path.tmp.* file present right now cannot belong to a
    # live concurrent writer -- a live one would need this same lock first. Glob
    # failures/permission errors are swallowed; this is hygiene, never load-bearing.
    eval {
        my @stray = glob("\Q$path\E.tmp.*");
        unlink grep { -f $_ } @stray;
        1;
    };

    my $tmp = "$path.tmp.$$";
    my $wrote_ok = eval {
        open(my $w, '>:raw', $tmp) or die "open $tmp: $!\n";
        print { $w } $new or die "print $tmp: $!\n";
        close($w) or die "close $tmp: $!\n";
        1;
    };
    unless ($wrote_ok) {
        my $err = $@;
        unlink $tmp;
        my $reason = "write $tmp failed: $err";
        _log_event($log, $site, $path, 'io-error', $reason);
        return { ok => 0, outcome => 'io-error', reason => $reason, path => $path };
    }

    unless ($RENAME_FN->($tmp, $path)) {
        unlink $tmp;
        my $reason = "rename $tmp -> $path failed";
        _log_event($log, $site, $path, 'io-error', $reason);
        return { ok => 0, outcome => 'io-error', reason => $reason, path => $path };
    }

    $AFTER_COMMIT_HOOK->() if $AFTER_COMMIT_HOOK;

    my $after = $readf->($path);   # THE READ-BACK -- proves visibility, not durability.
    my $vreason;
    if ($verifyf) {
        $vreason = $verifyf->($after, $new);
    } else {
        my $after_bytes = defined $after ? $after : '';
        $vreason = ($after_bytes eq $new) ? undef : 'value did not survive the write';
    }
    if (defined $vreason) {
        # No rollback, no retry (spec §5 edge case 9): retrying would re-run a
        # mutation whose premise on disk is now unknown.
        _log_event($log, $site, $path, 'readback-failed', $vreason);
        return { ok => 0, outcome => 'readback-failed', reason => $vreason, path => $path };
    }

    return { ok => 1, outcome => 'written', reason => undef, path => $path };
}

package main;

unless (caller) {
    if (@ARGV == 1 && $ARGV[0] eq '--lock-timeout') {
        # fixbatch step7 / MINOR 9: print the EFFECTIVE timeout (honours
        # BP_WRITEGUARD_LOCK_TIMEOUT), not the bare constant -- this seam exists
        # specifically so bp-lib.sh and the Perl side can never drift, and printing
        # the constant instead of _effective_timeout reintroduced exactly that
        # drift under the one env var this module defines to prevent it.
        print BpWrite::_effective_timeout(undef), "\n";
        exit 0;
    }
    if (@ARGV == 2 && $ARGV[0] eq '--lock-path') {
        print BpWrite::lock_path($ARGV[1]), "\n";
        exit 0;
    }
    print STDERR "usage: bp-write-guard.pl --lock-timeout | --lock-path <file>\n";
    exit 2;
}

1;
