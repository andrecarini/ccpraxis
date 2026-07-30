#!/usr/bin/env perl
# bp-judge.pl — the DETERMINISTIC decision core for A5 (the judges). The judges
# themselves are scoped, throwaway `claude -p` calls the orchestrator fires (the
# only Claude in the whole run besides the coordinators); THIS file holds none of
# that — it is the pure, unit-tested logic that decides *whether* to fire a judge,
# *what* to do with its verdict, and *how* a harvest knob reshapes the DAG. The
# orchestrator (bp-orchestrator.pl) is the thin shell that spawns the judges and
# feeds their on-disk verdicts back through these functions.
#
# Two judges (Decisions #13/#15), both fresh-context, both verdict-on-disk:
#   • harvest-judge — verifies a FINISHED package's declared outputs against its
#     done-criteria from disk → pass | fail. Default runs as an async spot-audit
#     (#15); configurably as a per-launch gate.
#   • resolve-judge — a deeper, broad-context attempt to fix a STUCK package
#     (re-scope, corrected relaunch, drop an *optional* criterion) → relaunch | park.
#
# DESIGN: every decision here is a PURE function — no I/O, no globals, no clock —
# so t/10-judges.t can exhaust the matrix without a real `claude`. Verdict parsing
# is fail-CLOSED (an unrecognized judge verdict never reads as "all good": a bad
# harvest verdict escalates, a bad resolve verdict parks — Decision #29's spirit
# applied to the judges' own output).
#
# require: require "<path>/bp-judge.pl"; BpJudge::escalation_verdict(...)

package BpJudge;
use strict;
use warnings;

# ===========================================================================
# HARVEST KNOB (Decision #15)
# ===========================================================================

# harvest_mode($v) -> 'audit' | 'gate'
# The configured harvest mode. Default = 'audit' (#15: trust the coordinator's own
# tests/review/red-team, launch dependents immediately, verify async). Any
# unrecognized value falls back to the documented default rather than erroring —
# the knob can never wedge a run by being mistyped.
sub harvest_mode {
    my ($v) = @_;
    return 'gate' if defined $v && lc("$v") eq 'gate';
    return 'audit';
}

# gate_admits($mode,$status,$harvest) -> 0|1
# May dependents treat this package as satisfied? In audit mode, status 'done' is
# enough (verification is async, off the critical path). In gate mode, a finished
# package is admitted only once its harvest verdict is 'pass'.
sub gate_admits {
    my ($mode, $status, $harvest) = @_;
    return 0 unless defined $status && $status eq 'done';
    return 1 unless ($mode // 'audit') eq 'gate';
    return (defined $harvest && $harvest eq 'pass') ? 1 : 0;
}

# effective_status($mode,\%status,\%harvest) -> \%eff
# The status map the DAG should actually see. In GATE mode, a 'done' package whose
# harvest verdict isn't yet 'pass' is demoted to 'harvesting' so deps_met /
# ready_packages (which only ever honor 'done') hold its dependents back until the
# gate passes — without touching those functions. In AUDIT mode this is an exact
# identity passthrough, so A3's launch behavior is byte-for-byte unchanged.
sub effective_status {
    my ($mode, $status, $harvest) = @_;
    my %eff = %{ $status || {} };
    return \%eff unless ($mode // 'audit') eq 'gate';
    for my $pkg (keys %eff) {
        next unless defined $eff{$pkg} && $eff{$pkg} eq 'done';
        $eff{$pkg} = 'harvesting'
            unless gate_admits('gate', $eff{$pkg}, ($harvest ? $harvest->{$pkg} : undef));
    }
    return \%eff;
}

# ===========================================================================
# ESCALATION LADDER (Decision #13: park-the-branch, never global-halt)
# ===========================================================================

# escalation_verdict($c) -> 'resolve' | 'park'
# Consulted only AFTER the coordinator's own retry loops are exhausted (the
# watchdog has returned 'block' — the package is genuinely stuck). Spend a
# resolve-judge call if the per-package resolve budget remains; otherwise park the
# branch and queue the decision. The resolve-judge is deliberately rare (#13),
# hence a small cap (default 1).
#   $c = { resolve_attempts => N, resolve_cap => M (default 1) }
sub escalation_verdict {
    my ($c) = @_;
    my $cap = defined $c->{resolve_cap} ? $c->{resolve_cap} : 1;
    my $att = $c->{resolve_attempts} // 0;
    return ($att < $cap) ? 'resolve' : 'park';
}

# normalize_resolve($parsed) -> { action => 'relaunch'|'park', reason => ..., ... }
# Interpret the resolve-judge's on-disk verdict object. The judge itself (Claude,
# scoped, with Edit/Write inside a declared write-set) does the intent-laden fix —
# re-scopes the spec, drops an *optional* criterion, corrects the ledger — and
# records `action: relaunch` when it applied a fix the coordinator should retry, or
# `action: park` when it could not determine intent. THIS function does only the
# deterministic mapping the orchestrator acts on. Fail-CLOSED: a missing, crashed,
# or unrecognized verdict parks (never a silent relaunch loop — #13 "parks without
# guessing"). On park it surfaces `needs_you` (the question for the human) verbatim.
sub normalize_resolve {
    my ($p) = @_;
    return { action => 'park', reason => 'resolve verdict missing or not an object' }
        unless ref $p eq 'HASH';
    my $a = lc($p->{action} // '');
    if ($a eq 'relaunch') {
        return {
            action        => 'relaunch',
            reason        => ($p->{reason} // ''),
            mutated_files => (ref $p->{mutated_files} eq 'ARRAY' ? $p->{mutated_files} : []),
        };
    }
    # Coerce needs_you to a hashref (or undef) so a malformed verdict (needs_you as a
    # bare string, etc.) can't blow up the orchestrator's `needs_you->{question}` deref.
    my $ny = $p->{needs_you};
    $ny = (ref $ny eq 'HASH') ? $ny
        : (defined $ny ? { question => "$ny" } : undef);
    return {
        action    => 'park',
        reason    => ($p->{reason} // ($a eq 'park'
                        ? 'resolve-judge could not determine intent'
                        : "unrecognized resolve action '" . ($p->{action} // '') . "'")),
        needs_you => $ny,
    };
}

# ===========================================================================
# HARVEST VERDICT + FAILED-AUDIT HANDLING (Q2)
# ===========================================================================

# normalize_harvest($parsed) -> 'pass' | 'fail' | 'error'
# The harvest-judge writes { verdict: 'pass'|'fail', ... } after reading only the
# package's done-criteria + declared outputs from disk. Anything else (missing,
# malformed, crashed judge) is 'error' — NOT silently 'pass'. Upstream, both 'fail'
# and 'error' are non-pass and trigger the same conservative escalation, so a judge
# we can't trust never green-lights a package (#29's never-proceed-on-unrecognized).
sub normalize_harvest {
    my ($p) = @_;
    return 'error' unless ref $p eq 'HASH';
    my $v = lc($p->{verdict} // $p->{result} // '');
    return 'pass' if $v eq 'pass';
    return 'fail' if $v eq 'fail';
    return 'error';
}

# audit_outcome($c) -> 'accept' | 'defer' | 'reopen' | 'park'      # EXTENDED (b09)
# What the orchestrator does with a completed harvest verdict (audit mode — the
# package's dependents may already be running off the trusted output):
#   pass                                              -> accept  (record harvest-verified, done)
#   non-pass AND deferrable AND defer_attempts < cap  -> defer   (b09: every cited
#                                                        failure belongs to a not-yet-
#                                                        landed sibling — re-check
#                                                        later instead of burning a
#                                                        corrective cycle on the
#                                                        audited package's own red)
#   non-pass, under corrective cap    -> reopen   (relaunch the package NON-terminal
#                                                  with the audit's specific failures
#                                                  as corrective context; one cycle)
#   non-pass, corrective cap exhausted-> park     (queue a needs-you alarm)
# Park-don't-halt (#13) + demote-don't-panic (#12): a failed audit never auto-kills
# live dependents — the orchestrator flags them for re-verification, the loop keeps
# independent work running. corrective_cap default 1 (a single corrective cycle).
# defer_cap defaults to 2 when the key is absent; deferrable defaults to 0, so every
# pre-existing call shape (no deferrable/defer_attempts/defer_cap keys) is
# byte-for-byte unchanged (t/10-judges.t:91-95).
sub audit_outcome {
    my ($c) = @_;
    return 'accept' if defined $c->{verdict} && $c->{verdict} eq 'pass';
    my $defer_cap = defined $c->{defer_cap} ? $c->{defer_cap} : 2;
    my $defer_att = $c->{defer_attempts} // 0;
    return 'defer' if $c->{deferrable} && $defer_att < $defer_cap;
    my $cap = defined $c->{corrective_cap} ? $c->{corrective_cap} : 1;
    my $att = $c->{corrective_attempts} // 0;
    return ($att < $cap) ? 'reopen' : 'park';
}

# ===========================================================================
# b09-judge-starvation-and-verdict-archive — pure decision core additions
# (harvest turn-budget scaling, immediate starvation/crash classification,
# sibling-red attribution). All pure: no I/O, no globals, no clock, never die.
# ===========================================================================

# _split_paths($v) -> @paths      (internal helper; not exported, called by full
# name from within this package and from bp-orchestrator.pl as BpJudge::_split_paths
# is NOT part of the public contract, but Perl namespacing makes it reachable —
# treated as private by convention, mirrored on both write_set and test_paths.)
# $v: colon-separated string (ledger frontmatter shape), arrayref, or undef.
# Splits on ':', trims whitespace, drops empties and the placeholder tokens '-',
# '—', '[]', 'none' (case-insensitive), strips one leading './' and any trailing
# '/', de-duplicates preserving first-seen order. Never dies.
sub _split_paths {
    my ($v) = @_;
    my @raw;
    if    (ref $v eq 'ARRAY')        { @raw = @$v; }
    elsif (defined $v && !ref $v)    { @raw = split /:/, $v; }
    else                             { return (); }
    my %placeholder = map { (lc $_) => 1 } ('-', '—', '[]', 'none');
    my (@out, %seen);
    for my $p (@raw) {
        next unless defined $p && !ref $p;
        $p =~ s/^\s+//; $p =~ s/\s+$//;
        next unless length $p;
        next if $placeholder{lc $p};
        $p =~ s{^\./}{};
        $p =~ s{/+$}{};
        next unless length $p;
        next if $seen{$p}++;
        push @out, $p;
    }
    return @out;
}

# harvest_max_turns($write_set, $test_paths) -> $int
# files = count of distinct paths in _split_paths(write_set) UNION _split_paths(test_paths)
# n     = 20 + 8 * files
# return 28 if n < 28; return 60 if n > 60; return n
# Pure, total over undef/empty/garbage. Never returns < 28 or > 60 (Ruling 1).
sub harvest_max_turns {
    my ($write_set, $test_paths) = @_;
    my %union = map { ($_ => 1) } (_split_paths($write_set), _split_paths($test_paths));
    my $files = scalar keys %union;
    my $n = 20 + 8 * $files;
    return 28 if $n < 28;
    return 60 if $n > 60;
    return $n;
}

# judge_liveness($c) -> 'starved' | 'crashed' | 'running' | 'unknown'
# $c = { pid_present => 0|1, pid_alive => 0|1, terminal => \%tv | undef }
# %tv is terminal_verdict()'s totalized shape; anything not a HASH is read as
# { verdict => 'unknown' }. Consulted ONLY when no verdict file exists (Ruling 3).
# Never dies; total over garbage input.
sub judge_liveness {
    my ($c) = @_;
    $c = {} unless ref $c eq 'HASH';
    return 'unknown' unless $c->{pid_present};      # pid-file missing: death cannot be proven
    return 'running' if $c->{pid_alive};             # alive -> keep waiting on the wall clock
    my $term = $c->{terminal};
    my $v = (ref $term eq 'HASH' && defined $term->{verdict} && !ref $term->{verdict})
          ? $term->{verdict} : 'unknown';
    return 'starved' if $v eq 'max_turns';
    return 'crashed';                                 # success / error / unknown terminal, pid dead
}

# _owns($entry, $token) -> 0|1   (internal helper for attribute_failures)
# $entry is already a _split_paths-normalized write-set entry; $token is a raw
# candidate path extracted from a failure string, normalized here the same way.
sub _owns {
    my ($entry, $token) = @_;
    return 0 unless defined $entry && length $entry;
    my ($norm) = _split_paths([$token]);
    return 0 unless defined $norm && length $norm;
    return 1 if $norm eq $entry;
    return 1 if index($norm, "$entry/") == 0;
    return 0;
}

# attribute_failures($c) -> { attributable => 0|1, blockers => \@pkgs,
#                             unattributed => \@failure_strings }
# $c = { package    => $pkg_under_audit,
#        failures   => \@strings,                        # verdict->{failures}
#        write_sets => { pkg => $colon_str|\@ },
#        status     => { pkg => $status_str } }
# Algorithm (spec §3 behavior 22): pure; tolerates any garbage input; never dies.
sub attribute_failures {
    my ($c) = @_;
    $c = {} unless ref $c eq 'HASH';
    my $pkg = defined $c->{package} && !ref $c->{package} ? $c->{package} : '';
    my @f = grep { defined $_ && !ref $_ && /\S/ }
            (ref $c->{failures} eq 'ARRAY' ? @{ $c->{failures} } : ());
    return { attributable => 0, blockers => [], unattributed => [] } unless @f;

    my %write_sets = (ref $c->{write_sets} eq 'HASH') ? %{ $c->{write_sets} } : ();
    my %status     = (ref $c->{status}     eq 'HASH') ? %{ $c->{status} }     : ();

    # the audited package's OWN write set: its own declared file is its own
    # responsibility, so a token it owns is disqualified regardless of siblings.
    my @own = _split_paths($write_sets{$pkg});

    # pre-normalize every sibling's write set once.
    my %sib_paths;
    for my $s (keys %write_sets) {
        next if $s eq $pkg;
        $sib_paths{$s} = [ _split_paths($write_sets{$s}) ];
    }

    my %blockers;
    my @unattributed;
    for my $fail (@f) {
        my @tokens = $fail =~ m{([A-Za-z0-9_][A-Za-z0-9_./+-]*/[A-Za-z0-9_.+-]+)}g;
        # AND, not OR (item 2): a failure string is attributable only if EVERY
        # extracted path token is attributable to a live sibling. A single token
        # owned by a sibling used to launder the WHOLE failure into a deferral even
        # when another cited token (e.g. the audited package's own test file) was
        # genuine own-red. $saw_token tracks whether any path-like token was found
        # at all (no tokens => unattributed, same as before).
        my $saw_token = 0;
        my $all_attributed = 1;
        for my $tok (@tokens) {
            $tok =~ s/[.,;:)\]'"]+$//;
            next unless length $tok;
            $saw_token = 1;
            if (grep { _owns($_, $tok) } @own) {      # disqualified: A's own file
                $all_attributed = 0;                  # not attributable to a sibling
                next;
            }
            my $tok_attributed = 0;
            for my $s (sort keys %sib_paths) {
                next if $s eq $pkg;
                my $st = defined $status{$s} && !ref $status{$s} ? lc($status{$s}) : '';
                $st =~ s/^\s+//; $st =~ s/\s+$//;
                # LIVE == not done/dropped/blocked/parked (a blocked/parked sibling
                # is not a blocker — the human is already looking at it).
                next if $st eq 'done' || $st eq 'dropped' || $st eq 'blocked' || $st eq 'parked';
                if (grep { _owns($_, $tok) } @{ $sib_paths{$s} }) {
                    $blockers{$s} = 1;
                    $tok_attributed = 1;
                }
            }
            $all_attributed = 0 unless $tok_attributed;
        }
        my $attributed = ($saw_token && $all_attributed) ? 1 : 0;
        push @unattributed, $fail unless $attributed;
    }
    my $attributable = @unattributed ? 0 : 1;
    return { attributable => $attributable, blockers => [ sort keys %blockers ], unattributed => \@unattributed };
}

# ===========================================================================
# JUDGE FIRING POLICY (which packages need which judge this tick) — pure
# ===========================================================================

# want_harvest_audit($c) -> 0|1
# In AUDIT mode, fire a harvest spot-audit exactly once per finished package:
# status is 'done', no verdict recorded yet, and none already in flight. (In GATE
# mode the gate fires through the same seam but is sequenced by effective_status,
# so this audit-mode predicate returns 0.)
sub want_harvest_audit {
    my ($c) = @_;
    return 0 unless ($c->{mode} // 'audit') eq 'audit';
    return 0 unless defined $c->{status} && $c->{status} eq 'done';
    return 0 if $c->{inflight};
    return 0 if defined $c->{harvest} && length $c->{harvest};   # already verdicted
    return 1;
}

# want_harvest_gate($c) -> 0|1
# In GATE mode, fire the harvest gate for a finished-but-unadmitted package: status
# 'done', no 'pass' verdict yet, none in flight. (Mirror of want_harvest_audit for
# the gate knob; effective_status holds the dependents while this runs.)
sub want_harvest_gate {
    my ($c) = @_;
    return 0 unless ($c->{mode} // 'audit') eq 'gate';
    return 0 unless defined $c->{status} && $c->{status} eq 'done';
    return 0 if $c->{inflight};
    return 0 if defined $c->{harvest} && length $c->{harvest};   # already verdicted
    return 1;
}

# ---------------------------------------------------------------------------
# b05-conformance-gate — pure conformance decision functions (spec §2.1).
# All pure: no I/O, no globals, never die, fail-closed (missing/empty/
# unparseable input NEVER yields a silent pass).
# ---------------------------------------------------------------------------

# --- fire condition: every package terminal AND none awaiting a human (D6).
# %pkgs: { pkg => { status => $str, ... } }
# 'awaiting_human' takes precedence over 'not_terminal' when both hold, because a
# run holding a blocked/parked package never actually finished — judging it would
# produce a junk verdict.
sub conformance_ready {
    my ($pkgs) = @_;
    $pkgs = {} unless ref $pkgs eq 'HASH';
    my @names = sort keys %$pkgs;
    return { ready => 0, reason => 'empty_registry', awaiting => [] } unless @names;
    my (@awaiting, $nonterm);
    for my $n (@names) {
        my $st = '';
        $st = $pkgs->{$n}{status} if ref $pkgs->{$n} eq 'HASH' && defined $pkgs->{$n}{status};
        # tolerate sloppy ledger values: a stray space or capital would otherwise read
        # as non-terminal and silently skip the gate for the whole run.
        $st =~ s/^\s+//; $st =~ s/\s+$//; $st = lc $st;
        if    ($st eq 'blocked' || $st eq 'parked')  { push @awaiting, $n }
        elsif ($st eq 'done'    || $st eq 'dropped') { }
        else                                         { $nonterm = 1 }
    }
    return { ready => 0, reason => 'awaiting_human', awaiting => \@awaiting } if @awaiting;
    return { ready => 0, reason => 'not_terminal',   awaiting => [] } if $nonterm;
    return { ready => 1, reason => 'ready',          awaiting => [] };
}

# --- mandated_means parsing (D8). $raw = verbatim text after 'mandated_means:'
# in ledger frontmatter, or undef when the key is absent. ledger_fm is scalar-only,
# so this is the narrow list-aware reader — deliberately NOT a general YAML parser.
# shape in (flow | flow_empty | block | absent | unknown)
sub _mm_clean {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/^\s+//; $s =~ s/\s+$//;
    $s =~ s/^-\s*//;
    $s =~ s/^\s+//; $s =~ s/\s+$//;
    $s =~ s/^"(.*)"$/$1/s or $s =~ s/^'(.*)'$/$1/s;
    $s =~ s/^\s+//; $s =~ s/\s+$//;
    return $s;
}
sub parse_mandated_means {
    my ($raw) = @_;
    return { means => [], shape => 'absent', ok => 1 } unless defined $raw && $raw =~ /\S/;
    my $t = $raw;
    $t =~ s/^\s+//; $t =~ s/\s+$//;
    if ($t =~ /^\[(.*)\]$/s) {                       # inline flow list
        my $inner = $1;
        return { means => [], shape => 'flow_empty', ok => 1 } unless $inner =~ /\S/;
        # a nested structure is not a flat list we understand — fail closed
        return { means => [], shape => 'unknown', ok => 0 } if $inner =~ /[\[\]{}]/;
        my @m = grep { length } map { _mm_clean($_) } split /,/, $inner;
        return { means => \@m, shape => 'flow', ok => 1 };
    }
    my @lines = grep { /\S/ } split /\n/, $t;        # YAML block list
    if (@lines && !grep { !/^\s*-\s*\S/ } @lines) {
        my @m = grep { length } map { _mm_clean($_) } @lines;
        return { means => \@m, shape => 'block', ok => 1 };
    }
    return { means => [], shape => 'unknown', ok => 0 };
}

# --- deviation classification (spec §3.3): 'review' ONLY on a genuinely non-blank
# justification. Anything ambiguous is 'fail' — a forged or empty justification
# must never downgrade a FAIL into a non-blocking review.
sub classify_deviation {
    my ($dev) = @_;
    return 'ignore' unless ref $dev eq 'HASH';
    return 'ignore' unless defined $dev->{means} && $dev->{means} =~ /\S/;
    my $why = defined $dev->{justification} ? $dev->{justification} : '';
    $why =~ s/^\s+//; $why =~ s/\s+$//;
    return 'review' if $dev->{justification_present} && length $why;
    return 'fail';
}

# --- verdict normalization. $raw = decoded verdict JSON, the {_malformed=>1}
# sentinel from read_judge_verdict, or undef. NEVER returns 'pass' for those.
sub normalize_conformance {
    my ($raw) = @_;
    my %out = (outcome => 'error', findings => [], reviews => [], notices => [],
               notes => [], deviations => []);
    unless (ref $raw eq 'HASH') {
        push @{ $out{notes} }, 'raw conformance verdict absent or not an object';
        return \%out;
    }
    if ($raw->{_malformed}) {
        push @{ $out{notes} }, 'raw conformance verdict was malformed JSON';
        return \%out;
    }
    for my $k (qw(findings reviews notices deviations)) {
        $out{$k} = (ref $raw->{$k} eq 'ARRAY') ? [ @{ $raw->{$k} } ] : [];
    }
    push @{ $out{notes} }, @{ $raw->{notes} } if ref $raw->{notes} eq 'ARRAY';
    my $o = defined $raw->{outcome} ? lc $raw->{outcome}
          : defined $raw->{verdict} ? lc $raw->{verdict} : '';
    unless ($o eq 'pass' || $o eq 'fail' || $o eq 'error') {
        push @{ $out{notes} }, 'unrecognized or missing outcome in raw verdict';
        return \%out;                       # stays 'error' — never a silent pass
    }
    $out{outcome} = $o;
    $out{outcome} = 'fail' if $o eq 'pass' && @{ $out{findings} };
    return \%out;
}

# --- deps-check folding (Decision #14, spec §2.10/§3.7).
# $report = decoded runs/deps-check.json | {_malformed=>1} | undef.
# b05 NEVER runs bp-deps-check.pl; the on-disk report is the entire interface, so
# b04's exit-2 is irrelevant here — a BLOCK is detected by reading blocks[].
sub fold_deps_check {
    my ($report) = @_;
    my %out = (findings => [], reviews => [], notices => [], outcome_hint => 'pass', ok => 1);
    unless (defined $report) {
        push @{ $out{notices} }, { subject => 'deps-check report absent', severity => 'info',
            detail => 'no runs/deps-check.json present; dependency policy was not evaluated',
            evidence => {} };
        return \%out;
    }
    if (ref $report ne 'HASH' || $report->{_malformed}
        || (exists $report->{blocks} && ref $report->{blocks} ne 'ARRAY')
        || (exists $report->{warns}  && ref $report->{warns}  ne 'ARRAY')) {
        $out{ok} = 0;
        $out{outcome_hint} = 'error';
        push @{ $out{notices} }, { subject => 'deps-check report malformed', severity => 'warn',
            detail => 'runs/deps-check.json could not be interpreted; treated as a failure, not a pass',
            evidence => {} };
        return \%out;
    }
    # Fail-closed on severity as well as position: an entry is blocking if it sits in
    # blocks[] OR labels itself severity=block. b04 guarantees the two agree, but this
    # file is just a file — trusting position alone would let a warns[] entry labelled
    # severity=block be downgraded to a non-blocking review.
    my @block_entries = @{ $report->{blocks} || [] };
    my @warn_entries;
    for my $w (@{ $report->{warns} || [] }) {
        if (ref $w eq 'HASH' && defined $w->{severity} && lc $w->{severity} eq 'block') {
            push @block_entries, $w;
        } else { push @warn_entries, $w }
    }
    for my $b (@block_entries) {
        next unless ref $b eq 'HASH';
        push @{ $out{findings} }, {
            kind     => (defined $b->{kind} ? $b->{kind} : 'deps-check-block'),   # PRESERVED for b07
            severity => 'block',
            subject  => (defined $b->{subject} ? $b->{subject} : 'unknown'),
            detail   => (defined $b->{detail}  ? $b->{detail}  : ''),
            evidence => (ref $b->{evidence} eq 'HASH' ? $b->{evidence} : {}),
            remedy   => (ref $b->{remedy}   eq 'HASH' ? $b->{remedy}   : { action => 'none' }),
            needs_justification => 0,
        };
        $out{outcome_hint} = 'fail';
    }
    for my $w (@warn_entries) {
        next unless ref $w eq 'HASH';
        push @{ $out{reviews} }, {
            package        => 'unknown',
            coordinator    => 'unknown',
            original_means => (defined $w->{subject} ? $w->{subject} : 'unknown'),
            change         => (defined $w->{detail}  ? $w->{detail}  : ''),
            why            => ((ref $w->{remedy} eq 'HASH' && defined $w->{remedy}{action})
                                ? $w->{remedy}{action} : 'justify'),
            ledger_marker  => 'deps-check::warn',
            evidence       => (ref $w->{evidence} eq 'HASH' ? $w->{evidence} : {}),
        };
    }
    return \%out;
}

# --- fire-once bookkeeping (D7): inflight | verdict-present | spawn cap.
sub conformance_should_spawn {
    my ($s) = @_;
    return 0 unless ref $s eq 'HASH';
    return 0 if $s->{inflight};
    return 0 if $s->{verdict_present};
    my $spawns = defined $s->{spawns} ? $s->{spawns} : 0;
    my $cap    = defined $s->{cap}    ? $s->{cap}    : 0;
    return ($spawns < $cap) ? 1 : 0;
}

# --- record builders (spec §2.4 finding / §2.5 notice / §2.6 review).
sub finding_record {
    my ($dev, $ctx) = @_;
    $dev ||= {}; $ctx ||= {};
    return {
        kind     => ($ctx->{kind} || 'conformance-deviation'),
        severity => 'block',
        subject  => (defined $dev->{package} ? $dev->{package} : 'unknown'),
        detail   => ($ctx->{detail} || ("mandated means '" . (defined $dev->{means} ? $dev->{means} : '?')
                     . "' not evidenced" . (defined $dev->{observed} ? "; observed: $dev->{observed}" : ''))),
        evidence => { means    => (defined $dev->{means}    ? $dev->{means}    : ''),
                      observed => (defined $dev->{observed} ? $dev->{observed} : ''),
                      files    => (ref $dev->{files} eq 'ARRAY' ? $dev->{files} : []) },
        remedy   => { action  => 'remediate-conformance',
                      package => (defined $dev->{package} ? $dev->{package} : 'unknown'),
                      means   => (defined $dev->{means}   ? $dev->{means}   : '') },
        needs_justification => 0,
    };
}
sub review_record {
    my ($dev, $ctx) = @_;
    $dev ||= {}; $ctx ||= {};
    return {
        schema         => 'review/1',
        generated_at   => ($ctx->{generated_at} || ''),
        package        => (defined $dev->{package} ? $dev->{package} : 'unknown'),
        coordinator    => ($ctx->{coordinator} || $dev->{who} || $dev->{package} || 'unknown'),
        original_means => (defined $dev->{means} ? $dev->{means} : ''),
        change         => (defined $dev->{change} ? $dev->{change}
                           : (defined $dev->{observed} ? $dev->{observed} : '')),
        why            => (defined $dev->{justification} ? $dev->{justification} : ''),
        ledger_marker  => ($ctx->{ledger_marker} || 'Decisions & attempt log :: MEANS-DEVIATION'),
        evidence       => { files => (ref $dev->{files} eq 'ARRAY' ? $dev->{files} : []) },
    };
}
sub notice_record {
    my ($subject, $detail, $ctx) = @_;
    $ctx ||= {};
    return {
        schema       => 'notice/1',
        generated_at => ($ctx->{generated_at} || ''),
        source       => 'conformance-gate',
        subject      => (defined $subject ? $subject : 'notice'),
        detail       => (defined $detail  ? $detail  : ''),
        severity     => ($ctx->{severity} || 'warn'),
        evidence     => (ref $ctx->{evidence} eq 'HASH' ? $ctx->{evidence} : {}),
    };
}

# --- MEANS-DEVIATION extraction from ledger TEXT (pure; spec §3.3 + §7.2).
# Only entries inside '## Decisions & attempt log' count, and a fenced code block
# never counts: otherwise a forged marker would silently downgrade a FAIL to a
# non-blocking review and suppress remediation entirely.
sub parse_means_deviations {
    my ($txt) = @_;
    my %out;
    return \%out unless defined $txt && length $txt;
    my ($sec) = $txt =~ /^##\s+Decisions\s*&\s*attempt\s+log\s*$(.*?)(?=^##\s|\z)/ms;
    return \%out unless defined $sec;
    my $fenced = 0;
    for my $ln (split /\r?\n/, $sec) {
        $ln =~ s/\r$//;
        # BOTH fence styles must count. Only handling ``` left a hole: a ~~~ fence
        # would hide a forged MEANS-DEVIATION from this filter while still reading
        # as a code block, downgrading a blocking FAIL to a non-blocking review and
        # silently suppressing remediation. Found by the coordinator's own red-team.
        if ($ln =~ /^\s*(?:```|~~~)/) { $fenced = !$fenced; next }
        next if $fenced;
        next unless $ln =~ /MEANS-DEVIATION:\s*(.*)$/;
        my $rest = $1;
        # Every field's lookahead must name EVERY other field, `who=` included.
        # Omitting `\s+who=` made `why=` swallow a trailing " who=<id>" into the
        # justification text (corrupting the review record's `why`) while `who`
        # itself was never captured, so review_record's $dev->{who} was always
        # undef and `coordinator` silently fell back to the package name.
        my $STOP = qr/(?=\s+means=|\s+change=|\s+why=|\s+who=|$)/;
        my ($means)  = $rest =~ /\bmeans=(.*?)$STOP/;
        my ($change) = $rest =~ /\bchange=(.*?)$STOP/;
        my ($why)    = $rest =~ /\bwhy=(.*?)$STOP/;
        my ($who)    = $rest =~ /\bwho=(.*?)$STOP/;
        next unless defined $means && $means =~ /\S/;
        for ($means, $change, $why, $who) { next unless defined $_; s/^\s+//; s/\s+$// }
        $out{$means} = { change  => (defined $change ? $change : ''),
                         why     => (defined $why    ? $why    : ''),
                         who     => (defined $who    ? $who    : ''),
                         present => 1 };
    }
    return \%out;
}

package main;
use strict;
use warnings;
1;
