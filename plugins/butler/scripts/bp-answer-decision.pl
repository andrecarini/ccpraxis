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
#                            [--action relaunch|reset|accept|drop|resume]
#                            [--note "text"]
#                            [--widen-write-set PATH]   # b17: additive-only write_set
#                                                       # widening, through bp-ledger.pl
#                            [--set-write-set VALUE]    # b17: ALWAYS refused (narrowing/
#                                                       # replacing write_set is not a
#                                                       # supported move — see below)
#                            [--bp-dir DIR]
#      exit 0 = unblocked; 2 = usage / bad action for the kind / missing decision /
#               unknown decision kind / refused write_set narrow-or-replace / blank
#               --widen-write-set value.
#
# b17-answer-decision-completeness fixes four defects (see the spec of that name):
#   1. `--action reset` now CLEARS the package's registry `session_id` (plan_answer's
#      `clear_session`), so bp-resume-sweep.sh's "gap > 60m OR no session id" rule
#      classifies the next launch COLD. Plain `relaunch` does NOT touch session_id —
#      these are deliberately opposite levers (a human who wants a genuinely fresh
#      coordinator context asks for reset, not relaunch).
#   2. `--widen-write-set PATH` ADDS a path to the package ledger's write_set
#      frontmatter field, additively, going through bp-ledger.pl's own byte-level
#      splice/validate/atomic-write engine (run_op) rather than a second, independent
#      frontmatter writer of this script's own. `--set-write-set` (full replacement)
#      is always refused with a named cause — see the module doc below for why this
#      is NOT the same move as rewriting `mandated_means`.
#   3. Every kind bp-orchestrator.pl's own producers can queue routes to a
#      deterministic outcome; `known_kinds()` DERIVES that list by parsing
#      bp-orchestrator.pl's source with the exact same regexes t/69's oracle uses, so
#      it cannot hand-drift as b01/b09/b11/b16 add more kinds. An unrecognised kind
#      fails loudly (named in the message) and changes nothing.
#   4. `--note` now persists on EVERY action (relaunch/reset/accept/drop) — the
#      `if $plan->{relaunch}` gate that silently dropped it for accept/drop is gone.

use File::Basename qw(dirname);
use Cwd qw(abs_path);
my $SELF_DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; abs_path($f) // $f });
my $ORCH_SRC = "$SELF_DIR/bp-orchestrator.pl";

package BpAnswer;
use strict;
use warnings;

# known_kinds() -> the FULL set of decision kinds bp-orchestrator.pl's own
# queue_needs_you / _enter_pause_manual / _block_and_queue call sites actually
# emit. e02 §2.5: this used to source-scan bp-orchestrator.pl's text with a
# narrow line-window regex, which is invisible to 'dag-stalled' (built via the
# _dag_decision builder function, whose `kind => 'dag-stalled'` literal lives
# outside any scanned window) -- the still-live techcontas-batch1 #2 defect.
# Delegates to BpOrch::%KIND_REGISTRY (a shared, tested, data-driven registry
# both scripts load) instead, closing that blind spot for good rather than
# widening the window again.
sub known_kinds {
    return BpOrch::known_kinds_list();
}

# kind_family($kind) -> 'fleet' | 'package' | undef (unknown)
# A fleet pause is resolved by clearing the pause; everything else is a
# package-level park resolved through the ledger. `undef` $kind means "direct
# --package mode" (#29, no queued decision at all) — always 'package', the only
# family a decision-less direct action can mean. A DEFINED kind not among
# BpOrch::%KIND_REGISTRY is refused (undef return) rather than silently guessed
# as 'package' — the defect this closes let an unknown kind succeed as if it
# were 'stuck-package'.
sub kind_family {
    my ($k) = @_;
    return 'package' unless defined $k && length $k;
    return BpOrch::kind_family_of($k);   # undef -- unknown to every real producer
}

# plan_answer($kind, $action, $pseudo) -> { ok, family, action, ledger_status, clear_pause,
#                                  relaunch, reset_attempt, error }
# The pure mapping the CLI executes. Fail-CLOSED on a nonsensical (kind, action)
# pair: returns ok=0 with an explanatory error rather than guessing, so a
# mistyped action can never, say, mark a stuck package 'done'.
#
# e04 §2.2: optional 3rd arg $pseudo (boolean; omitted/undef = today's exact
# behavior, backward-compatible with every existing 2-arg call). When true AND
# the kind is family 'package', there is NO ledger to relaunch/reset/accept/
# drop -- 'dag-stalled'/'remediation-escalation' are filed against pseudo-
# packages ('_dag'/'_remediation'). The only action that makes sense is
# 'acknowledge': clear the current queued alert without touching a ledger that
# does not exist. This does not assert the underlying condition is fixed --
# see spec §2.2's "Honesty property".
sub plan_answer {
    my ($kind, $action, $pseudo) = @_;
    my $fam = kind_family($kind);
    unless (defined $fam) {
        return { ok => 0, family => 'unknown',
                 error => "unknown decision kind '" . ($kind // '') . "' -- not among the kinds "
                        . "bp-orchestrator.pl's own producers actually queue (known_kinds()); "
                        . "refusing rather than silently treating it as stuck-package" };
    }
    if ($fam eq 'fleet') {
        $action = 'resume' unless defined $action && length $action;
        return { ok => 0, family => 'fleet',
                 error => "fleet decision '" . ($kind // '') . "' only supports --action resume (got '$action')" }
            unless $action eq 'resume';
        return { ok => 1, family => 'fleet', action => 'resume',
                 ledger_status => undef, clear_pause => 1, relaunch => 0, reset_attempt => 0 };
    }
    if ($pseudo && $fam eq 'package') {
        $action = 'acknowledge' unless defined $action && length $action;
        return { ok => 0, family => 'package', pseudo => 1,
                 error => "'" . ($kind // '') . "' is filed against a pseudo-package with no ledger to "
                        . "relaunch/reset/accept/drop. Fix the underlying condition externally (e.g. "
                        . "'bp-blueprint.pl set-deps' for a DAG cycle), then run --action acknowledge "
                        . "to clear this decision. If the condition is not actually fixed, the "
                        . "orchestrator will re-file the same decision on its next tick." }
            unless $action eq 'acknowledge';
        return { ok => 1, family => 'package', pseudo => 1, action => 'acknowledge',
                 ledger_status => undef, clear_pause => 0, relaunch => 0, reset_attempt => 0 };
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
        # b17 C1/C2: `reset` is the ONLY action that clears session_id — the cold-start
        # lever. A plain `relaunch` MUST preserve it (a warm resume is still legitimate
        # for a package that simply hit a transient failure). These are the paired
        # opposites the oracle's vacuity gate asserts together.
        clear_session => ($action eq 'reset' ? 1 : 0),
    };
}

package main;
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use File::Spec ();
use Fcntl qw(LOCK_EX LOCK_UN);

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; abs_path($f) // $f });
require "$DIR/bp-orchestrator.pl";   # reuse BpOrch atomic ledger/registry/pause writers

# bp-ledger.pl (b17 1.2) declares no `package` of its own, so requiring it installs
# its subs (run_op, replace_first_key_line, validate_bytes, ...) directly into THIS
# file's package (main) — the same "requirable module, guarded by `unless (caller)`"
# shape bp-orchestrator.pl already uses (see its own header). This is how
# --widen-write-set goes THROUGH bp-ledger.pl's byte-level splice/validate/atomic-
# write engine rather than this script hand-rolling a second frontmatter writer.
require "$DIR/bp-ledger.pl";

# _write_set_splice($bytes, $newpath) -> ($new_bytes, undef) | (undef, $reason)
# The run_op-shaped splice callback (b17 1.2): reads the frontmatter `write_set:`
# line's colon-separated value (bp-lib.sh's own convention — see registry_get/
# match_any), and ADDS $newpath if it is not already present. Never removes, never
# reorders, never touches any other line — additive-only, by construction (there is
# no code path here that can drop an existing entry).
sub _write_set_splice {
    my ($B, $newpath) = @_;
    return (undef, 'no frontmatter block to update') unless $B =~ /\A---\s*\n(.*?)\n---/s;
    my ($fs, $fe) = ($-[1], $+[1]);
    my $region = substr($B, $fs, $fe - $fs);
    my $cur;
    for my $line (split(/\n/, $region, -1)) {
        if ($line =~ /^write_set:\s*(.*?)\s*$/) { $cur = $1; last }
    }
    return (undef, 'write_set: key not found in frontmatter') unless defined $cur;
    my @paths = length($cur) ? split(/:/, $cur) : ();
    return ($B, undef) if grep { $_ eq $newpath } @paths;   # already present: no-op (byte-identical)
    push @paths, $newpath;
    my $new = replace_first_key_line($B, $fs, $fe, 'write_set', 'write_set: ' . join(':', @paths));
    return (undef, 'write_set: key not found in frontmatter') unless defined $new;
    return ($new, undef);
}

# widen_write_set($ledger, $newpath) — never returns: bp-ledger.pl's run_op() (shared
# by all five typed ops) validates before and after the splice, checks the
# last_updated monotonicity rule, writes atomically (temp+rename) under its own
# lockfile, and calls `exit 0` on success or one of arg_error/io_error/reject_error/
# notfound_error (each a one-line stderr message + a specific non-zero exit) on any
# rejection or I/O failure. Since this splice never touches status: or last_updated:,
# a successful widen leaves every other line of the ledger byte-identical.
sub widen_write_set {
    my ($ledger, $newpath) = @_;
    run_op('widen-write-set', $ledger, sub { return _write_set_splice($_[0], $newpath) });
}

# Append (idempotently) the human's resolution to a package ledger as a corrective
# section the relaunched coordinator will read. Mirrors BpOrch::_apply_harvest_findings
# in shape.
#
# fixbatch step7 / MAJOR (reviewer) + MAJOR 3 (red-team): this used to read-modify-
# rename the SAME ledger S1 (_set_ledger_status) guards, with NO lock at all -- a
# lost-update race against a live coordinator or a concurrent bp-ledger.pl op on
# this file. Now takes the SAME lock those other writers take (BpWrite::lock_path,
# "$f.lock") around the read-modify-rename, so the three can never interleave.
#
# Deliberately NOT routed through BpWrite::guarded_write (unlike
# BpOrch::_apply_harvest_findings, which was): this must run BEFORE the ledger's
# status flips (see the call site in `unless (caller)` below) because bp-ledger.pl's
# own protocol `@STATUSES` list does not include "dropped" -- reordering the note-
# writers to run only after a successful status commit would make bp-ledger.pl's
# `set-next-action` (the sibling call, `update_next_action_with_note`) reject the
# ledger outright for `--action drop`. Kept as a plain, locked, in-this-file writer
# instead; t/69's own oracle (C3) also pins this file to exactly ONE raw ">:raw"
# writer, guarding against write-set widening growing a second independent one.
sub append_human_decision {
    my ($bpdir, $pkg, $note, $action) = @_;
    return unless defined $note && length $note;
    my $f = "$bpdir/packages/$pkg.md";
    my $lock_p = BpWrite::lock_path($f);
    open(my $lk, '>', $lock_p) or return;
    flock($lk, LOCK_EX) or do { close $lk; return };
    open my $r, '<:raw', $f or do { flock($lk, LOCK_UN); close $lk; return };
    local $/; my $txt = <$r>; close $r;
    unless (defined $txt) { flock($lk, LOCK_UN); close $lk; return; }
    $txt =~ s/\n*## Human decision \(resolve\).*?(?=\n## |\z)//s;   # drop any prior block
    my $sec = "\n\n## Human decision (resolve)\n\n"
            . "A human reviewed this package's park and chose to **$action** it with this guidance:\n\n"
            . "$note\n\n"
            . "Apply it, then re-run your own tests/review before reporting done.\n";
    $txt .= $sec;
    open my $w, '>:raw', "$f.tmp.$$" or do { flock($lk, LOCK_UN); close $lk; return };
    print $w $txt; close $w;
    rename "$f.tmp.$$", $f;
    flock($lk, LOCK_UN);
    close $lk;
    return;
}

# update_next_action_with_note($bpdir, $pkg, $note, $action) — b18-decision-delivery:
# the answer to a park must land where the resume prompt actually points ("Re-read
# your ledger ... then continue from the 'Next action' section" — bp-launch.sh), not
# only in the "## Human decision (resolve)" audit block appended above. That block is
# the durable RECORD (SYN-10: archive, never delete); THIS makes it the OPERATIVE
# instruction too, by REPLACING the stale park text in "## Next action" wholesale —
# appending beneath it would satisfy "the note is present" while still leaving the
# stale instruction as the last thing a resuming coordinator reads, which is the
# actual re-park defect (spec section 0/1).
#
# Goes through bp-ledger.pl's sanctioned `set-next-action` op — the ONE section
# documented as "meant to be rewritten" — as an out-of-process CLI call (list-form
# system(), no shell, so the note's own quoting/newlines need no escaping) rather
# than a second raw ledger writer of this script's own: bp-ledger.pl set-next-action
# does its own byte-level locate/validate/atomic-write, and adding another '>:raw'
# writer here would both duplicate that logic and break b17's oracle, which pins
# this script's raw-writer count at exactly one (the audit-record writer above).
sub update_next_action_with_note {
    my ($bpdir, $pkg, $note, $action) = @_;
    return unless defined $note && length $note;
    my $ledger = "$bpdir/packages/$pkg.md";
    return unless -f $ledger;
    my $body = "A human reviewed this package's park and chose to **$action** it. Their guidance:\n\n"
             . "$note\n\n"
             . "Apply it, then re-run your own tests/review before reporting done.";
    my $ledger_pl = "$SELF_DIR/bp-ledger.pl";
    # Redirect the CHILD's stdout/stderr to the null device around the call (list-form
    # system(): no shell, so the note's own quoting/newlines/metacharacters need no
    # escaping and cannot leak into a shell). bp-ledger.pl's stdout is documented as
    # always empty on this op, but its stderr is not: a ledger fixture that predates
    # b13's schema (missing frontmatter keys/sections bp-ledger.pl's own V1-V5 requires)
    # makes set-next-action reject and print one stderr line. Left unredirected, a
    # caller capturing this script's own combined output (2>&1, as several callers and
    # tests do) would see that line spliced into what must stay pure JSON on stdout.
    # A rejection here is a silent no-op for Next-action delivery, not a fatal error --
    # the audit record (append_human_decision, above) already landed regardless.
    my $devnull = File::Spec->devnull;
    my ($saved_out, $saved_err);
    open($saved_out, '>&', \*STDOUT) or return 0;
    open($saved_err, '>&', \*STDERR) or return 0;
    open(STDOUT, '>', $devnull) or do { open(STDOUT, '>&', $saved_out); return 0; };
    open(STDERR, '>', $devnull) or do { open(STDOUT, '>&', $saved_out); open(STDERR, '>&', $saved_err); return 0; };
    system($^X, $ledger_pl, 'set-next-action', '--ledger', $ledger, '--body', $body);
    my $rc = $?;
    open(STDOUT, '>&', $saved_out);
    open(STDERR, '>&', $saved_err);
    close $saved_out; close $saved_err;
    return ($rc == 0) ? 1 : 0;
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
        # BLOCKER 2 (fixbatch step7): nothing else in this write set ever clears
        # registry `pid` for a coordinator that exits non-terminally, so a stale
        # pid can strand later relaunch/accept/drop refusals (_set_ledger_status's
        # coordinator-alive gate) once the OS recycles it. This path just killed
        # the coordinator we know about -- clear the identity so the NEXT gate
        # check never mistakes a recycled pid for this one.
        BpOrch::update_registry_pkg($runs, $pkg, { pid => undef });
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

# _log_pseudo_ack($runs, $pkg, $kind, $note) — e04 §2.2: a pseudo-package
# acknowledge has no ledger to carry --note (there is nothing to append to),
# so the note is not fabricated into a location that doesn't exist. Best-
# effort logged to orchestrator.log instead, so the resolution is not silently
# dropped. Never fatal: a log write failure here must not block the
# acknowledge itself.
sub _log_pseudo_ack {
    my ($runs, $pkg, $kind, $note) = @_;
    return unless defined $runs;
    eval { BpOrch::_log("$runs/orchestrator.log", 'pseudo_package_acknowledge',
        { package => $pkg, kind => $kind, note => $note }); 1 };
    return;
}

unless (caller) {
    require JSON::PP;
    my ($bp, $bpdir, $decision, $package, $action, $note, $widen_write_set, $set_write_set);
    # e02 §2.7: --list is a new, standalone, READ-ONLY surface (mutates nothing).
    my ($list_mode, $category_arg);
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
        if    ($arg eq '--bp-dir')          { $bpdir           = $need->('--bp-dir'); }
        elsif ($arg eq '--decision')        { $decision        = $need->('--decision'); }
        elsif ($arg eq '--package')         { $package         = $need->('--package'); }
        elsif ($arg eq '--action')          { $action          = $need->('--action'); }
        elsif ($arg eq '--note')            { $note            = $need->('--note'); }
        elsif ($arg eq '--widen-write-set') { $widen_write_set = $need->('--widen-write-set'); }
        elsif ($arg eq '--set-write-set')   { $set_write_set   = $need->('--set-write-set'); }
        elsif ($arg eq '--list')            { $list_mode       = 1; }
        elsif ($arg eq '--category')        { $category_arg    = $need->('--category'); }
        elsif ($arg =~ /^--/)               { print STDERR "bp-answer-decision: unknown option $arg\n"; exit 2; }
        else  { push @pos, $arg; }
    }
    $bp = shift @pos if @pos;

    unless (defined $bp && length $bp) {
        print STDERR "usage: bp-answer-decision.pl <blueprint>\n"
                   . "         --decision <id|file> [--action relaunch|reset|accept|drop|resume]   # answer a queued decision\n"
                   . "         --package <pkg>      [--action reset|accept|drop]                    # act directly on a package (#29)\n"
                   . "         [--note ...] [--widen-write-set PATH] [--bp-dir DIR]\n"
                   . "  --widen-write-set PATH   ADD path to the package's write_set (additive only, via bp-ledger.pl)\n"
                   . "  --set-write-set VALUE    always refused: replacing/narrowing write_set is not supported\n";
        exit 2;
    }

    # b17 C4: full-replacement is refused outright, before anything else is touched or
    # even resolved — this is not "unknown option" (that already exits 2 above with a
    # different message); it is a NAMED refusal of a specific, deliberately-considered
    # move. write_set is the *answer* to a human decision (b17 spec §1.2) — additive
    # widening only. Narrowing or replacing it wholesale is never supported here.
    if (defined $set_write_set) {
        print STDERR "bp-answer-decision: --set-write-set would replace write_set wholesale; this is "
                   . "refused. Replacing or narrowing write_set is not a supported move -- write_set may "
                   . "only be WIDENED additively (see --widen-write-set PATH), never narrowed or replaced.\n";
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

    # e02 §2.7: --list is mutually exclusive with --decision/--package (same
    # "use X or Y, not both" pattern as above), refused BEFORE either is
    # resolved. Read-only: scans runs/needs-you/*.json, prints one JSON object
    # per matching record, sorted oldest-created_at first (ties by id, mirroring
    # BpWait::fresh_decisions's order), and mutates nothing.
    if ($list_mode) {
        if (defined $package || defined $decision) {
            print STDERR "bp-answer-decision: use --list OR --decision/--package, not both\n"; exit 2;
        }
        my %filter;
        if (defined $category_arg) {
            %filter = map { $_ => 1 } grep { length } split /,/, $category_arg;
            # fixbatch step7 / red-team NIT 1: a --category flag that IS given
            # but CSV-splits to only empty tokens (e.g. "--category ,,") must
            # not silently degrade to "no filtering" -- see the twin fix in
            # bp-wait-for-decision.pl for the full rationale. Only a genuinely
            # omitted --category keeps the "no filtering" meaning.
            unless (%filter) {
                no warnings 'once';   # cross-package global, referenced exactly once here
                print STDERR "bp-answer-decision: --category '$category_arg' has no usable "
                    . "category value; valid categories are: "
                    . join(', ', @BpOrch::CATEGORIES) . "\n";
                exit 2;
            }
        }
        my @recs;
        my $dir = "$runs/needs-you";
        if (opendir my $dh, $dir) {
            for my $f (grep { /\.json$/ } readdir $dh) {
                my $rec = BpOrch::_read_json("$dir/$f");
                next unless ref $rec eq 'HASH';
                my $cat = $rec->{category};
                next if %filter && !(defined $cat && $filter{$cat});
                (my $id = $f) =~ s/\.json$//i;
                push @recs, { id => $id, package => $rec->{package}, kind => $rec->{kind},
                              category => $cat, question => $rec->{question},
                              created_at => $rec->{created_at} };
            }
            closedir $dh;
        }
        @recs = sort {
            (($a->{created_at} // 0) <=> ($b->{created_at} // 0))
                || (($a->{id} // '') cmp ($b->{id} // ''))
        } @recs;
        print JSON::PP->new->canonical->encode($_), "\n" for @recs;
        exit 0;
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

    # e04 §2.2: 'dag-stalled'/'remediation-escalation' are filed against
    # pseudo-packages ('_dag'/'_remediation') with no ledger to act on. Keyed
    # on the package name starting with '_' -- works identically for both
    # --decision mode (package comes from the decision record) and direct
    # --package mode (package comes straight from --package), free symmetry
    # from the same check rather than a separate design.
    my $is_pseudo = defined $pkg && $pkg =~ /^_/;

    # b17 1.2/C3/C8(b): --widen-write-set is its own, standalone, additive mutation —
    # NOT folded into the relaunch/reset/accept/drop pipeline below. It never touches
    # ledger status/last_updated or the registry, so it cannot be entangled with
    # (or clobbered by) whatever --action was also passed; a reporter answering
    # "you need one more file" does not have to separately reason about which action
    # verb is "compatible" with widening. widen_write_set() never returns (it exits
    # via bp-ledger.pl's run_op — 0 on success, a specific non-zero on rejection).
    if (defined $widen_write_set) {
        (my $trimmed = $widen_write_set) =~ s/^\s+|\s+\z//g;
        if ($trimmed eq '') {
            print STDERR "bp-answer-decision: --widen-write-set requires a non-empty, non-blank path "
                       . "(got an empty/blank value); refusing rather than silently no-op'ing write_set\n";
            exit 2;
        }
        if ($trimmed =~ /:/) {
            print STDERR "bp-answer-decision: --widen-write-set path must not itself contain ':' "
                       . "(write_set's own colon separator, per bp-lib.sh's convention): '$trimmed'\n";
            exit 2;
        }
        unless (defined $pkg && length $pkg && -f "$bpdir/packages/$pkg.md") {
            print STDERR "bp-answer-decision: package ledger not found for '" . ($pkg // '') . "'\n"; exit 2;
        }
        widen_write_set("$bpdir/packages/$pkg.md", $trimmed);   # never returns
    }

    my $plan = BpAnswer::plan_answer($kind, $action, $is_pseudo);
    unless ($plan->{ok}) {
        # e04/e02 seam: name the specific pseudo-package target in the CLI's
        # own stderr, on top of plan_answer's kind-only message -- a
        # ledger-targeted refusal, not merely a generic kind-shaped one.
        my $suffix = ($is_pseudo && defined $pkg && length $pkg) ? " (package '$pkg')" : '';
        print STDERR "bp-answer-decision: $plan->{error}$suffix\n"; exit 2;
    }

    my $superseded = [];
    my $cleared    = 0;
    # b18: undef when no --note was supplied; 1/0 when one was, so a rejected
    # set-next-action is reported rather than swallowed.
    my $next_action_updated;
    if ($plan->{family} eq 'package' && $plan->{pseudo}) {
        # No ledger exists -- nothing to supersede, mutate, or gate on
        # coordinator liveness. --note has no ledger to land in; best-effort
        # logged rather than silently dropped (spec §2.2/§7 edge case 2).
        _log_pseudo_ack($runs, $pkg, $kind, $note) if defined $note && length $note;
    } elsif ($plan->{family} eq 'package') {
        unless (defined $pkg && length $pkg && -f "$bpdir/packages/$pkg.md") {
            print STDERR "bp-answer-decision: package ledger not found for '" . ($pkg // '') . "'\n"; exit 2;
        }
        # Supersede live work FIRST (before flipping to pending) so a fresh relaunch
        # can't collide with a coordinator/judge still editing the write-set. This also
        # clears registry `pid` when it actually kills something (BLOCKER 2 mitigation
        # in supersede_package_work itself), so a subsequent gate check never mistakes
        # a just-killed coordinator's pid, recycled later, for still being it.
        $superseded = supersede_package_work($runs, $pkg) if $plan->{supersede};
        # fixbatch step7 / BLOCKER 2 aggravating factor: a refused answer (exit 6)
        # used to leave the ledger HALF-applied -- append_human_decision and
        # update_next_action_with_note ran unconditionally BEFORE the coordinator-
        # alive gate inside _set_ledger_status, so the human's note landed while
        # `status:` (and the queued decision) stayed untouched. reporter/SKILL.md
        # promises a refused answer "changes nothing"; that must be true in the
        # common (non-racing) case, not just eventually-consistent.
        #
        # This PRE-check runs the SAME coordinator-alive logic _set_ledger_status
        # will authoritatively re-check under the lock, but BEFORE any write at all
        # -- so the ordinary case (a genuinely alive/genuinely dead coordinator) exits
        # 6 with nothing touched. The two ledger-note writers below then keep their
        # ORIGINAL ordering (before the status flip): bp-ledger.pl's own protocol
        # `@STATUSES` list does not include "dropped", so update_next_action_with_note
        # (routed through bp-ledger.pl set-next-action) must run while the ledger's
        # status is still whatever it was BEFORE this answer, never after a flip to
        # `dropped` -- reordering that too would make bp-ledger.pl reject the ledger
        # outright on the very next call. The authoritative gate inside
        # _set_ledger_status (below, still first among the actual WRITES) remains the
        # real enforcement point for the narrow residual race (coordinator becomes
        # alive between this pre-check and that call).
        if (defined $runs && !$plan->{supersede}) {
            my $reason = BpOrch::_coordinator_alive_refusal($runs, $pkg);
            if (defined $reason) {
                print JSON::PP->new->canonical->pretty->encode({
                    ok => JSON::PP::false(), package => $pkg, kind => $kind,
                    family => $plan->{family}, action => $plan->{action}, refused => $reason,
                });
                exit 6;
            }
        }
        # b17 C7/C8(a): --note now persists on EVERY action, including accept/drop —
        # the `if $plan->{relaunch}` gate that silently dropped it for those two
        # (defect 4, the worst-shaped of the four: exit 0, note vanished, no warning)
        # is gone. append_human_decision() itself already no-ops when $note is undef.
        append_human_decision($bpdir, $pkg, $note, $plan->{action});
        # b18: put the answer where the resume prompt actually points (see
        # update_next_action_with_note's own header) -- must run for every action
        # that carries a note (relaunch/reset/accept/drop alike), matching b17's
        # "note persists on every action" rule this package extends.
        # The return value is USED, not discarded. A rejected set-next-action leaves the
        # OPERATIVE copy of the answer unwritten while the audit record still lands -- which
        # is this package's own defect (the coordinator reads `## Next action`, finds stale
        # park text, and re-parks) reintroduced for any ledger bp-ledger.pl refuses. Silently
        # swallowing it would repeat b17's defect 4 (accepted, exit 0, wrote nothing) and
        # b09's item 14 (return discarded at every call site).
        #
        # It is surfaced in the JSON on stdout rather than on stderr: callers capture this
        # script's combined output and parse stdout as JSON, so any stderr line -- including
        # our own -- would corrupt what it is meant to warn about.
        $next_action_updated = update_next_action_with_note($bpdir, $pkg, $note, $plan->{action});
        # a01/S1+S1b: the ledger write and the registry write are both now guarded
        # (BpWrite::guarded_write) -- the ledger write additionally refuses while the
        # registry-recorded coordinator pid is alive, UNLESS this plan already
        # superseded it above (`--action reset`, spec behavior 14). This is the
        # AUTHORITATIVE gate (the pre-check above is best-effort only); a refusal
        # here means "the write no longer applies": the decision file is left queued
        # (not unlinked below) and we exit 6 with a machine-readable refusal token on
        # stdout (never stderr -- callers parse this script's combined output as
        # JSON, spec §2.5). In the ordinary case this was already caught by the
        # pre-check above with NOTHING written; this call only re-fires it in the
        # narrow race window between that pre-check and here, in which case the two
        # note-writers above (append_human_decision, update_next_action_with_note)
        # will have landed even though the status flip below did not -- the same
        # residual half-applied shape as before this fix-batch, now narrowed to that
        # window rather than present on every refusal.
        my $set_ok = BpOrch::_set_ledger_status($bpdir, $pkg, $plan->{ledger_status},
            { runs => $runs, supersede => ($plan->{supersede} ? 1 : 0) });
        unless ($set_ok) {
            my $reason = ($BpWrite::LAST_RESULT && $BpWrite::LAST_RESULT->{reason}) || 'write-refused';
            print JSON::PP->new->canonical->pretty->encode({
                ok => JSON::PP::false(), package => $pkg, kind => $kind,
                family => $plan->{family}, action => $plan->{action}, refused => $reason,
            });
            exit 6;
        }
        my %reg = ( status => $plan->{ledger_status} );
        $reg{attempt}          = 0 if $plan->{reset_attempt};
        $reg{resolve_attempts} = 0 if $plan->{reset_resolve};
        # SETTLE THE HARVEST on accept, or the acceptance is not durable.
        #
        # `accept` set the ledger to `done` and stopped there. But
        # want_harvest_audit fires on (status done, harvest EMPTY, none in
        # flight) — so a package whose harvest never produced a verdict was
        # immediately re-armed on the next tick. Reported from a live GSA fleet
        # run: 8 consecutive re-fires of the same harvest-failure decision, each
        # one re-accepted by hand, because accepting never recorded that the
        # question was settled. Worse where it started: the judge itself could
        # not complete (the one-shot deadlock fixed in 0841130), so there was no
        # verdict coming and the loop had no exit.
        #
        # 'pass' specifically, not a truthier-looking 'accepted': gate mode
        # admits a package's dependents only on `harvest eq 'pass'`
        # (bp-judge.pl:52), so any other value would stall them forever. The
        # honesty is preserved in a separate field rather than by weakening the
        # one the gate reads.
        #
        # The four companion resets mirror what a real pass writes
        # (bp-orchestrator.pl:2808) — leaving a stale defer/starve counter behind
        # would let a later cycle resurrect the audit this is meant to close.
        if (($plan->{action} // '') eq 'accept') {
            $reg{harvest}                     = 'pass';
            $reg{harvest_reaudit}             = 0;
            $reg{harvest_defer}               = 0;
            $reg{harvest_defer_blockers}      = '';
            $reg{harvest_starve_continuations}= 0;
            $reg{harvest_settled_by}          = 'human-accept';
        }
        # b17 C1/C2: the cold-start lever. `reset` clears session_id (set to undef,
        # which JSON::PP/registry_merge encode as JSON null — bp-resume-sweep.sh's
        # registry_get treats a null the same as absent via jq's `// empty`), so the
        # sweep's "gap > 60m OR no session id" rule classifies the next launch COLD.
        # `relaunch` must NEVER set this key — see plan_answer's clear_session.
        $reg{session_id}       = undef if $plan->{clear_session};
        my $reg_ok = BpOrch::update_registry_pkg($runs, $pkg, \%reg);
        unless ($reg_ok) {
            my $reason = ($BpWrite::LAST_RESULT && $BpWrite::LAST_RESULT->{reason}) || 'write-refused';
            print JSON::PP->new->canonical->pretty->encode({
                ok => JSON::PP::false(), package => $pkg, kind => $kind,
                family => $plan->{family}, action => $plan->{action}, refused => $reason,
            });
            exit 6;
        }
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
        # b18: absent when no --note was given. When one was, this says whether the
        # OPERATIVE copy reached `## Next action` -- the section a resuming coordinator
        # actually reads. false means the audit record landed but the coordinator will
        # still see stale park text, which is the re-park loop this package closes.
        (defined $next_action_updated
            ? (next_action_updated => ($next_action_updated ? JSON::PP::true() : JSON::PP::false()))
            : ()),
    });
    exit 0;
}
1;
