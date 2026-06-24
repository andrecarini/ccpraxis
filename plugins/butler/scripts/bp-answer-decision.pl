#!/usr/bin/env perl
# bp-answer-decision.pl — the MECHANICAL unblock the reporter performs once a
# human has answered a queued runs/needs-you/ decision (A7). The reporter (Claude)
# decides *what* the answer is (intent — talking to the human, choosing the
# action, writing the corrective note); THIS does the deterministic, atomic file
# surgery that actually unblocks the run, so that load-bearing step is unit-tested
# rather than improvised in prose (house rule: deterministic enforcement, not a
# skill body, for mechanical state changes).
#
# Two families of decision, distinguished by `kind` (the schema A3/A5 queue):
#   • package park — stuck-package | harvest-failure | harvest-spawn-failure:
#       relaunch (default) -> append the human's note to the ledger as a
#                             "## Human decision" corrective section, set ledger
#                             status -> pending, reset the registry (attempt 0,
#                             status pending) so the orchestrator relaunches it
#                             next tick with a fresh budget (_load_state is
#                             ledger-first, re-read every tick).
#       accept             -> ledger status -> done (accept the output as-is; no
#                             relaunch — e.g. a harvest the human judges fine).
#       drop               -> ledger status -> dropped (abandon the package).
#   • fleet pause — reauth | contract-drift:
#       resume (default)   -> clear runs/.paused (the human did the external
#                             action: /login, or inspected the drift); the
#                             orchestrator resumes next tick.
# Every path then DELETES the queue file (clears the decision).
#
# DESIGN: plan_answer() is a PURE function (kind+action -> the plan) so t/13 can
# exhaust the matrix; the CLI does the I/O, reusing bp-orchestrator.pl's already-
# tested atomic writers (no duplicated, drift-prone frontmatter/registry logic).
#
# CLI: bp-answer-decision.pl <blueprint> --decision <id|file|path>
#                            [--action relaunch|accept|drop|resume]
#                            [--note "text"] [--bp-dir DIR]
#      exit 0 = unblocked; 2 = usage / bad action for the kind / missing decision.

package BpAnswer;
use strict;
use warnings;

# kind_family($kind) -> 'fleet' | 'package'
# A fleet pause is resolved by clearing the pause; everything else is a
# package-level park resolved through the ledger. Unknown kinds default to
# 'package' (the conservative, recoverable path — relaunch with a note).
sub kind_family {
    my ($k) = @_;
    return 'fleet' if defined $k && $k =~ /^(reauth|contract-drift)$/;
    return 'package';
}

# plan_answer($kind, $action) -> { ok, family, action, ledger_status, clear_pause,
#                                  relaunch, reset_attempt, error }
# The pure mapping the CLI executes. Fail-CLOSED on a nonsensical (kind, action)
# pair: returns ok=0 with an explanatory error rather than guessing, so a
# mistyped action can never, say, mark a stuck package 'done'.
sub plan_answer {
    my ($kind, $action) = @_;
    my $fam = kind_family($kind);
    if ($fam eq 'fleet') {
        $action = 'resume' unless defined $action && length $action;
        return { ok => 0, family => 'fleet',
                 error => "fleet decision '" . ($kind // '') . "' only supports --action resume (got '$action')" }
            unless $action eq 'resume';
        return { ok => 1, family => 'fleet', action => 'resume',
                 ledger_status => undef, clear_pause => 1, relaunch => 0, reset_attempt => 0 };
    }
    $action = 'relaunch' unless defined $action && length $action;
    my %status_for = ( relaunch => 'pending', accept => 'done', drop => 'dropped' );
    return { ok => 0, family => 'package',
             error => "package decision '" . ($kind // '') . "' supports --action relaunch|accept|drop (got '$action')" }
        unless exists $status_for{$action};
    return {
        ok            => 1,
        family        => 'package',
        action        => $action,
        ledger_status => $status_for{$action},
        clear_pause   => 0,
        relaunch      => ($action eq 'relaunch' ? 1 : 0),
        reset_attempt => ($action eq 'relaunch' ? 1 : 0),
    };
}

package main;
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

my $DIR = dirname(abs_path(__FILE__));
require "$DIR/bp-orchestrator.pl";   # reuse BpOrch atomic ledger/registry/pause writers

# Append (idempotently) the human's resolution to a package ledger as a corrective
# section the relaunched coordinator will read. Mirrors BpOrch::_apply_harvest_findings:
# drop any prior block, append a fresh one, atomic temp+rename.
sub append_human_decision {
    my ($bpdir, $pkg, $note, $action) = @_;
    return unless defined $note && length $note;
    my $f = "$bpdir/packages/$pkg.md";
    open my $r, '<:raw', $f or return;
    local $/; my $txt = <$r>; close $r;
    return unless defined $txt;
    $txt =~ s/\n*## Human decision \(resolve\).*?(?=\n## |\z)//s;   # drop any prior block
    my $sec = "\n\n## Human decision (resolve)\n\n"
            . "A human reviewed this package's park and chose to **$action** it with this guidance:\n\n"
            . "$note\n\n"
            . "Apply it, then re-run your own tests/review before reporting done.\n";
    $txt .= $sec;
    open my $w, '>:raw', "$f.tmp.$$" or return;
    print $w $txt; close $w;
    rename "$f.tmp.$$", $f;
}

unless (caller) {
    require JSON::PP;
    my ($bp, $bpdir, $decision, $action, $note);
    my @pos;
    my $need = sub {
        my ($flag) = @_;
        my $v = shift @ARGV;
        unless (defined $v && $v !~ /^--/) {
            print STDERR "bp-answer-decision: $flag requires a value\n"; exit 2;
        }
        return $v;
    };
    while (@ARGV) {
        my $arg = shift @ARGV;
        if    ($arg eq '--bp-dir')   { $bpdir    = $need->('--bp-dir'); }
        elsif ($arg eq '--decision') { $decision = $need->('--decision'); }
        elsif ($arg eq '--action')   { $action   = $need->('--action'); }
        elsif ($arg eq '--note')     { $note     = $need->('--note'); }
        elsif ($arg =~ /^--/)        { print STDERR "bp-answer-decision: unknown option $arg\n"; exit 2; }
        else  { push @pos, $arg; }
    }
    $bp = shift @pos if @pos;

    unless (defined $bp && length $bp) {
        print STDERR "usage: bp-answer-decision.pl <blueprint> --decision <id|file> [--action relaunch|accept|drop|resume] [--note ...] [--bp-dir DIR]\n";
        exit 2;
    }
    unless (defined $bpdir) {
        my $data = $ENV{CCPRAXIS_DATA_DIR};
        unless (defined $data) { print STDERR "bp-answer-decision: set --bp-dir or CCPRAXIS_DATA_DIR\n"; exit 2; }
        $bpdir = "$data/blueprints/$bp";
    }
    my $runs = "$bpdir/runs";

    unless (defined $decision && length $decision) {
        print STDERR "bp-answer-decision: --decision <id|file|path> is required\n"; exit 2;
    }
    # Resolve the decision file: a path as-is, else <runs>/needs-you/<id>.json.
    my $file = $decision;
    unless ($file =~ m{[\\/]}) {
        $file =~ s/\.json$//i;
        $file = "$runs/needs-you/$file.json";
    }
    unless (-f $file) {
        print STDERR "bp-answer-decision: decision not found: $file\n"; exit 2;
    }
    my $rec = do { open my $fh, '<:raw', $file or do { print STDERR "bp-answer-decision: read $file: $!\n"; exit 2 };
                   local $/; my $raw = <$fh>; close $fh; eval { JSON::PP->new->decode($raw) } };
    unless (ref $rec eq 'HASH') {
        print STDERR "bp-answer-decision: decision file is not valid JSON: $file\n"; exit 2;
    }
    my $pkg  = $rec->{package};
    my $kind = $rec->{kind};

    my $plan = BpAnswer::plan_answer($kind, $action);
    unless ($plan->{ok}) { print STDERR "bp-answer-decision: $plan->{error}\n"; exit 2; }

    if ($plan->{family} eq 'package') {
        unless (defined $pkg && length $pkg && -f "$bpdir/packages/$pkg.md") {
            print STDERR "bp-answer-decision: package ledger not found for '" . ($pkg // '') . "'\n"; exit 2;
        }
        append_human_decision($bpdir, $pkg, $note, $plan->{action}) if $plan->{relaunch};
        BpOrch::_set_ledger_status($bpdir, $pkg, $plan->{ledger_status});
        my %reg = ( status => $plan->{ledger_status} );
        $reg{attempt} = 0 if $plan->{reset_attempt};
        BpOrch::update_registry_pkg($runs, $pkg, \%reg);
    } else {
        BpOrch::clear_pause($runs);
    }

    unlink $file;   # clear the decision from the queue

    print JSON::PP->new->canonical->pretty->encode({
        ok => JSON::PP::true(), package => $pkg, kind => $kind,
        family => $plan->{family}, action => $plan->{action},
        ledger_status => $plan->{ledger_status}, cleared_pause => ($plan->{clear_pause} ? JSON::PP::true() : JSON::PP::false()),
    });
    exit 0;
}
1;
