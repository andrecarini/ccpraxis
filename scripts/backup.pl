#!/usr/bin/env perl
# backup.pl -- CLI entry point for the backup driver (blueprint backup-driver,
# package 01-driver-skeleton).
#
# This file owns ONLY: argument parsing, dispatch, JSON encoding, printing,
# and the process exit code. All engine mechanics -- the state machine, the
# run-state file, the resume-token grammar, phase discovery, and the
# decision-kind enum -- live in scripts/backup/Run.pm (package Backup::Run).
# Backup::Run::execute() PRINTS NOTHING and never calls exit: it returns
# ($exit_code, $result_href), and this script is the only place that turns
# that into stdout / stderr / a real process exit. See the spec
# (01-driver-skeleton-spec.md) S2.7 for why the seam is drawn there.
#
# USAGE
#   perl backup.pl run [--json] [--restart]
#   perl backup.pl run [--json] --resume <token> --answer <id>=<choice> [--answer <id>=<choice> ...]
#   perl backup.pl --help
#
# Exactly one JSON object (JSON::PP->new->canonical, newline-terminated) is
# written to stdout per invocation -- nothing else is ever written there. A
# refusal or error additionally writes a short human line to stderr, prefixed
# "backup:".
#
# Decision-kind string literals (the values of @Backup::Run::DECISION_KINDS)
# are defined in exactly ONE place: Run.pm's declaration. This file must
# never repeat one -- AC3 greps this file for every kind value and asserts
# absence.
#
# This package performs NO git operation of any kind (blueprint Decisions 4
# and 6, honoured by omission) and therefore never sets
# MSYS2_ARG_CONV_EXCL -- see Run.pm's header for why a later phase module
# must not inherit that decision from here.

use strict;
use warnings;
use JSON::PP;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# Locate Run.pm relative to THIS file (bp-drive-next.pl's idiom), so the
# script behaves the same regardless of the caller's working directory.
my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; abs_path($f) // $f });
require "$DIR/backup/Run.pm";

my $HELP_TEXT = <<'TXT';
usage: backup.pl run [--json] [--restart]
       backup.pl run [--json] --resume <token> --answer <id>=<choice> [--answer <id>=<choice> ...]
       backup.pl --help

  run                     execute (or continue) a backup run
    --json                  accepted for the wrapper's calling convention;
                             output is always JSON, with or without this flag
    --restart               discard any existing run state and start a fresh
                             run (also the escape hatch past a corrupt state
                             file)
    --resume <token>         continue a paused run using the given resume
                             token (mutually exclusive with --restart)
    --answer <id>=<choice>  answer one pending decision; repeat once per
                             pending decision

  --help                  print this usage text and exit 0 (touches no state)

Exactly one JSON object is written to stdout per invocation.

Exit codes: 0 complete, 10 needs a decision, 20 complete with failures,
2 usage, 3 resume token refused, 4 answer refused, 1 internal error.
TXT

sub _print_json_result {
    my ($result) = @_;
    my $json = JSON::PP->new->canonical->encode($result);
    print STDOUT $json, "\n";
    if (($result->{status} // '') eq 'error') {
        my $msg = $result->{error}{message} // 'unknown error';
        print STDERR "backup: $msg\n";
    }
    return;
}

# unknown subcommand / no arguments: usage on stderr per spec S2.5.
#
# The "backup: <message>" human line is printed exactly ONCE, by
# _print_json_result below (its status-eq-'error' branch already owns that
# line for every other refusal path in this file). A prior version also
# printed it directly here, so it appeared twice with the full help text
# sandwiched between the two copies -- a plain duplicate-print bug (redteam
# MINOR).
sub _usage_error {
    my ($message) = @_;
    print STDERR $HELP_TEXT;
    _print_json_result({ status => 'error', run_id => undef,
                          error => { code => 'usage', message => $message } });
    return 2;
}

package main;

unless (caller) {
    my @argv = @ARGV;
    my $sub  = shift @argv;

    my $rc;
    if (!defined $sub || $sub eq '') {
        $rc = _usage_error('no subcommand given (expected "run" or "--help")');
    }
    elsif ($sub eq '--help' || $sub eq '-h') {
        # Resolves no state path and reads no files (spec Behavior 18).
        print STDOUT $HELP_TEXT;
        $rc = 0;
    }
    elsif ($sub eq 'run') {
        # Backup::Run::execute() already guarantees this can't die (R4, its
        # own header) -- this eval is defence in depth at the one seam that
        # turns an outcome into stdout/exit, per redteam M3's remedy: this
        # file is the single place that already owns "turn a result into
        # JSON, print it, exit", so it is also the single place that must
        # never let ANYTHING escape to a bare, JSON-less process death.
        my ($exit_code, $result);
        {
            local $@;
            my @ret = eval { Backup::Run::execute({ argv => \@argv, now => sub { time } }) };
            if ($@) {
                $result = { status => 'error', run_id => undef,
                            error => { code => 'internal', message => "unhandled error: $@" } };
                $exit_code = 1;
            }
            else {
                ($exit_code, $result) = @ret;
            }
        }
        _print_json_result($result);
        $rc = $exit_code;
    }
    else {
        $rc = _usage_error("unknown subcommand '$sub' (expected \"run\" or \"--help\")");
    }

    exit($rc // 2);
}

1;
