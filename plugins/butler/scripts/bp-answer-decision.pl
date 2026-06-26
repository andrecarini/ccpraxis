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
#       reset              -> like relaunch, but ALSO resets the resolve budget and
#                             SUPERSEDES any in-flight coordinator/judge for the
#                             package (kills it + clears its markers) — for a
#                             package wedged at the cap or mid-resolve the human
#                             wants to retry from scratch (#29).
#       accept             -> ledger status -> done (accept the output as-is; no
#                             relaunch — e.g. a harvest the human judges fine).
#       drop               -> ledger status -> dropped (abandon the package).
#   • fleet pause — reauth | contract-drift:
#       resume (default)   -> clear runs/.paused (the human did the external
#                             action: /login, or inspected the drift); the
#                             orchestrator resumes next tick.
# Decision mode DELETES the answered queue file; direct --package mode clears every
# queued decision for that package (a reset has no single decision id to consume).
#
# DIRECT PACKAGE MODE (#29): bp-answer-decision.pl <bp> --package <pkg> [--action
# reset] resets/relaunches a package that has NO queued decision (e.g. it just hit
# the attempt cap and the orchestrator fired a resolve-judge). It does the same
# atomic surgery a human would otherwise hand-craft — no manual registry edits,
# process-killing, or marker-clearing. The orchestrator (left running) relaunches
# the package fresh on its next tick.
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
    my %status_for = ( relaunch => 'pending', reset => 'pending', accept => 'done', drop => 'dropped' );
    return { ok => 0, family => 'package',
             error => "package decision '" . ($kind // '') . "' supports --action relaunch|reset|accept|drop (got '$action')" }
        unless exists $status_for{$action};
    # relaunch and reset both re-queue the package with a fresh attempt budget;
    # reset is the stronger form (#29): it ALSO resets the resolve budget and
    # supersedes any in-flight coordinator/judge, for a package wedged at the cap
    # or mid-resolve that the human wants to retry from scratch rather than via the
    # resolve-judge path. accept/drop are terminal and touch no live work.
    my $is_relaunch = ($action eq 'relaunch' || $action eq 'reset') ? 1 : 0;
    return {
        ok            => 1,
        family        => 'package',
        action        => $action,
        ledger_status => $status_for{$action},
        clear_pause   => 0,
        relaunch      => $is_relaunch,
        reset_attempt => $is_relaunch,
        reset_resolve => ($action eq 'reset' ? 1 : 0),
        supersede     => ($action eq 'reset' ? 1 : 0),
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

# supersede_package_work($runs, $pkg) -> \@superseded
# Kill anything still editing the package's write-set so a fresh relaunch can't
# collide with it on disk: a live coordinator (registry pid) AND any in-flight
# resolve/harvest judge (runs/<kind>/<pkg>.pid — written by bp-judge.sh). Then
# clear the judges' on-disk markers (pid/.inflight/verdict) so the orchestrator
# doesn't act on a stale verdict from the one we just killed. Reuses BpOrch's
# setsid-group-aware kill + zombie-aware liveness. Dead/absent pids are no-ops.
sub supersede_package_work {
    my ($runs, $pkg) = @_;
    my @killed;
    my $reg = BpOrch::_read_json("$runs/registry.json");
    my $cpid = (ref $reg eq 'HASH') ? ($reg->{packages}{$pkg}{pid}) : undef;
    if (defined $cpid && BpOrch::pid_alive($cpid)) {
        BpOrch::kill_pid($cpid);
        push @killed, "coordinator:$cpid";
    }
    for my $kind (qw(resolve harvest)) {
        my $pidf = "$runs/$kind/$pkg.pid";
        if (-f $pidf) {
            my ($jpid) = (BpOrch::_read_file($pidf) // '') =~ /^(\d+)/;
            if (defined $jpid && BpOrch::pid_alive($jpid)) {
                BpOrch::kill_pid($jpid);
                push @killed, "$kind-judge:$jpid";
            }
            unlink $pidf;
        }
        BpOrch::clear_judge_inflight($runs, $kind, $pkg);
        BpOrch::clear_judge_verdict($runs, $kind, $pkg);
    }
    return \@killed;
}

# clear_pkg_decisions($runs, $pkg) -> count — delete any queued needs-you decisions
# for this package (a direct reset has no single decision id to consume). Other
# packages' decisions are left alone.
sub clear_pkg_decisions {
    my ($runs, $pkg) = @_;
    my $d = "$runs/needs-you";
    return 0 unless -d $d;
    opendir my $h, $d or return 0;
    my @files = grep { /\.json$/ } readdir $h;
    closedir $h;
    my $n = 0;
    for my $f (@files) {
        my $rec = BpOrch::_read_json("$d/$f");
        next unless ref $rec eq 'HASH' && defined $rec->{package} && $rec->{package} eq $pkg;
        $n++ if unlink "$d/$f";
    }
    return $n;
}

unless (caller) {
    require JSON::PP;
    my ($bp, $bpdir, $decision, $package, $action, $note);
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
        elsif ($arg eq '--package')  { $package  = $need->('--package'); }
        elsif ($arg eq '--action')   { $action   = $need->('--action'); }
        elsif ($arg eq '--note')     { $note     = $need->('--note'); }
        elsif ($arg =~ /^--/)        { print STDERR "bp-answer-decision: unknown option $arg\n"; exit 2; }
        else  { push @pos, $arg; }
    }
    $bp = shift @pos if @pos;

    unless (defined $bp && length $bp) {
        print STDERR "usage: bp-answer-decision.pl <blueprint>\n"
                   . "         --decision <id|file> [--action relaunch|reset|accept|drop|resume]   # answer a queued decision\n"
                   . "         --package <pkg>      [--action reset|accept|drop]                    # act directly on a package (#29)\n"
                   . "         [--note ...] [--bp-dir DIR]\n";
        exit 2;
    }
    unless (defined $bpdir) {
        my $data = $ENV{CCPRAXIS_DATA_DIR};
        unless (defined $data) { print STDERR "bp-answer-decision: set --bp-dir or CCPRAXIS_DATA_DIR\n"; exit 2; }
        $bpdir = "$data/blueprints/$bp";
    }
    my $runs = "$bpdir/runs";

    if (defined $package && defined $decision) {
        print STDERR "bp-answer-decision: use --package OR --decision, not both\n"; exit 2;
    }

    my ($pkg, $kind, $file);
    if (defined $package && length $package) {
        # Direct package mode (#29): no queued decision to consume. Defaults to a
        # full reset (fresh budget + supersede in-flight work). The package's own
        # queued decisions, if any, are cleared after.
        $pkg  = $package;
        $kind = undef;                  # no decision -> 'package' family
        $action = 'reset' unless defined $action && length $action;
    } else {
        unless (defined $decision && length $decision) {
            print STDERR "bp-answer-decision: pass --decision <id|file|path> or --package <pkg>\n"; exit 2;
        }
        # Resolve the decision file: a path as-is, else <runs>/needs-you/<id>.json.
        $file = $decision;
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
        $pkg  = $rec->{package};
        $kind = $rec->{kind};
    }

    my $plan = BpAnswer::plan_answer($kind, $action);
    unless ($plan->{ok}) { print STDERR "bp-answer-decision: $plan->{error}\n"; exit 2; }

    my $superseded = [];
    my $cleared    = 0;
    if ($plan->{family} eq 'package') {
        unless (defined $pkg && length $pkg && -f "$bpdir/packages/$pkg.md") {
            print STDERR "bp-answer-decision: package ledger not found for '" . ($pkg // '') . "'\n"; exit 2;
        }
        # Supersede live work FIRST (before flipping to pending) so a fresh relaunch
        # can't collide with a coordinator/judge still editing the write-set.
        $superseded = supersede_package_work($runs, $pkg) if $plan->{supersede};
        append_human_decision($bpdir, $pkg, $note, $plan->{action}) if $plan->{relaunch};
        BpOrch::_set_ledger_status($bpdir, $pkg, $plan->{ledger_status});
        my %reg = ( status => $plan->{ledger_status} );
        $reg{attempt}          = 0 if $plan->{reset_attempt};
        $reg{resolve_attempts} = 0 if $plan->{reset_resolve};
        BpOrch::update_registry_pkg($runs, $pkg, \%reg);
    } else {
        BpOrch::clear_pause($runs);
    }

    # Clear the queue: the single answered decision (decision mode), else every
    # queued decision for this package (direct package mode).
    if (defined $file) { unlink $file; $cleared = 1; }
    elsif ($plan->{family} eq 'package') { $cleared = clear_pkg_decisions($runs, $pkg); }

    print JSON::PP->new->canonical->pretty->encode({
        ok => JSON::PP::true(), package => $pkg, kind => $kind,
        family => $plan->{family}, action => $plan->{action},
        ledger_status => $plan->{ledger_status},
        cleared_pause => ($plan->{clear_pause} ? JSON::PP::true() : JSON::PP::false()),
        superseded => $superseded, decisions_cleared => $cleared,
    });
    exit 0;
}
1;
