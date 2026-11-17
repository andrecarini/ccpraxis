#!/usr/bin/env perl
# bp-ac-watch.pl -- the AC-reconnect monitor and status/clear CLI (package 11
# of blueprint tooling-backlog).
#
#   bp-ac-watch.pl monitor
#   bp-ac-watch.pl status
#   bp-ac-watch.pl clear --reason '<2+ words>'
#
# Contract: .ccpraxis-local-data/blueprints/tooling-backlog/specs/
# 11-ac-loss-clean-suspend-cycle-spec.md sec 2.8. All real logic lives in
# BpAcWatch.pm; this file is argv parsing, data-dir resolution and exit
# codes only.
use strict;
use warnings;
use FindBin qw($Bin);
use JSON::PP ();

# MSYS2 path-conversion guard (house rule), as bp-drive-next.pl does: this
# process may, via BpAcWatch's production seams, end up behind a native
# Windows command whose args contain a ':'.
BEGIN { $ENV{MSYS2_ARG_CONV_EXCL} = '*' if $^O =~ /^(MSWin32|cygwin|msys)$/; }

require "$Bin/BpAcWatch.pm"
    unless grep { m{(?:^|/)BpAcWatch\.pm$} } keys %INC;

sub _out { print STDOUT $_[0] . "\n" }
sub _err { print STDERR $_[0] . "\n" }

# ---------------------------------------------------------------------------
# data-dir resolution. Spec 2.1 names BpDataRoot::resolve()->{data_dir} as
# the CLI's resolution chain; this deliberately does NOT switch to that full
# chain (env, then git top-level, then a bounded walk-up from cwd) -- a
# `monitor`/`clear` call that resolved to the WRONG project's real
# .ccpraxis-local-data (anything a git walk-up from an arbitrary cwd might
# find) would read and write that project's real AC-cycle state, which is
# worse than refusing.
#
# H1 (fix-batch, reviewer-1/redteam-1): the original comment here claimed
# every production caller already has CCPRAXIS_DATA_DIR or BP_PROJECT_ROOT
# set. That is false for the one real caller: the drive-solo skill's own
# Bash tool, which has neither. Resolution order is now:
#   --data-dir <abs>  (explicit, from the director's own ac-stand-down
#                       action's data_dir field -- the skill passes it
#                       straight through, no cwd/env guessing at all)
#   > $CCPRAXIS_DATA_DIR > $BP_PROJECT_ROOT > refuse.
# A caller with none of the three still refuses (rc 1) exactly as before --
# this closes the real gap without widening the refusal contract.
sub _resolve_data_dir {
    my ($explicit) = @_;
    return $explicit if defined $explicit && length $explicit;
    my $v = $ENV{CCPRAXIS_DATA_DIR};
    return $v if defined $v && length $v;
    my $root = $ENV{BP_PROJECT_ROOT};
    return "$root/.ccpraxis-local-data" if defined $root && length $root;
    return undef;
}

my $USAGE = 'usage: bp-ac-watch.pl monitor [--data-dir <abs>] | status [--data-dir <abs>] | '
          . 'clear --reason \'<2+ words>\' [--data-dir <abs>]';

my @ARGV_ORIG = @ARGV;
my $cmd = shift(@ARGV) // '';

# --data-dir is accepted by every verb; pull it out of @ARGV up front so
# each verb's own parsing (clear's --reason) sees only its own flags.
my $DATA_DIR_OPT;
{
    my @rest;
    while (@ARGV) {
        my $w = shift @ARGV;
        if ($w eq '--data-dir') { $DATA_DIR_OPT = shift(@ARGV); next; }
        push @rest, $w;
    }
    @ARGV = @rest;
}

if ($cmd eq '' || $cmd eq '--help' || $cmd eq '-h') {
    _out($USAGE);
    exit($cmd eq '' ? 1 : 0);
}

if ($cmd eq 'status') {
    my $data = _resolve_data_dir($DATA_DIR_OPT);
    unless (defined $data && length $data) {
        _err('bp-ac-watch: no data dir (pass --data-dir, or set CCPRAXIS_DATA_DIR).');
        exit 1;
    }
    my $st = BpAcWatch::status($data);
    _out(JSON::PP->new->canonical->encode($st));
    exit 0;
}

if ($cmd eq 'clear') {
    my $reason = '';
    {
        my @a = @ARGV;
        while (@a) {
            my $w = shift @a;
            if ($w eq '--reason') { $reason = shift(@a) // ''; }
        }
    }
    my @words = grep { length } split /\s+/, $reason;
    if (@words < 2) {
        _err("bp-ac-watch: clear --reason '<2+ words>' is required.");
        exit 1;
    }
    my $data = _resolve_data_dir($DATA_DIR_OPT);
    unless (defined $data && length $data) {
        _err('bp-ac-watch: no data dir (pass --data-dir, or set CCPRAXIS_DATA_DIR).');
        exit 1;
    }
    BpAcWatch::clear($data, $reason);
    exit 0;
}

if ($cmd eq 'monitor') {
    my $data = _resolve_data_dir($DATA_DIR_OPT);
    unless (defined $data && length $data) {
        _err('bp-ac-watch: no data dir (pass --data-dir, or set CCPRAXIS_DATA_DIR).');
        exit 1;
    }
    my $rc = BpAcWatch::monitor_loop($data);
    $rc = 1 unless defined $rc && $rc =~ /^-?\d+$/;
    exit $rc;
}

_err("bp-ac-watch: unknown command '$cmd'. $USAGE");
exit 1;
