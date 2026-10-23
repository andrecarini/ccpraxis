#!/usr/bin/env perl
# bp-ledger.pl — the deterministic ledger API (b13-deterministic-ledger-api).
#
# Five typed, surgical mutation ops on a package ledger (set-status, append-attempt,
# tick-step, set-next-action, add-output) plus a `validate` subcommand that runs the
# same V1-V5 byte-oriented rule set ledger-guard.sh (b12) enforces. See:
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b13-deterministic-ledger-api-spec.md
#
# Plus a sixth op, `rotate` (b45-ledger-context-budget), which moves stale
# `## Decisions & attempt log` entries out to reports/ledger-history/<pkg>.md so the
# ledger stays inside a context budget. See:
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b45-ledger-context-budget-spec.md
#
# Plus a tenth op, `create` (04-model-effort-ledger-validation), which renders
# plugins/blueprint/templates/package-ledger.md into a new, validate()-clean package
# ledger -- the only op that creates a file rather than splicing an existing one,
# validating `model:`/`effort:` against @MODELS/@EFFORTS before anything reaches disk.
# See:
# .ccpraxis-local-data/blueprints/coordinator-context-discipline/specs/04-model-effort-ledger-validation-spec.md
#
# Plus three more (22-ledger-rescope, Decisions 84, 87 & 89 of hook-continuity-remake):
# a re-scope must never again mean "drop this package and create a new one".
# `set-write-set` / `set-test-paths` REPLACE write_set/test_paths wholesale (narrow or
# widen in one call, unlike the additive-only `widen-write-set`); every path the new
# set adds over the old one must be named verbatim in the given blueprint Decision
# (removals need no naming), and the call is refused outright -- leaving the ledger
# byte-identical -- while its own status is done/dropped (Decision 89: NOT while the
# package is listed in <data>/.drive-solo/inflight.json, and NOT for status running --
# rescoping a running package between worker dispatches is exactly the use case). An
# ADDED path (never a removed one) is separately refused if it overlaps the write_set
# of ANOTHER in-flight package, naming the conflicting package. `set-section` replaces
# the body of exactly
# one of Scope/Done criteria/Inputs/Out of scope, leaving the frontmatter byte-
# identical; every other heading is refused (Pipeline/Decisions & attempt log/Next
# action each already have a dedicated verb, as do Outputs (add-output) and Escalation
# (set-escalation)). `widen-write-set --edit-target` widens write_set only, never test_paths
# (task 25's "a widened test file also joins test_paths" behaviour is unchanged
# without the flag).
#
# Exit codes (an interface, fixed): 0 success, 2 validation rejection (byte-identical
# file), 3 usage/argument error (nothing read), 4 I/O/lock/atomicity failure
# (byte-identical), 5 target region not found (byte-identical).
#
# stdout is ALWAYS empty, EXCEPT `rotate --dry-run`, `claim-check` and `migrate-oracle`
# (01-compact-oracle-records-spec.md §2.8), all of which print a report/summary line to
# stdout. `claim-check` and `rotate --dry-run` touch nothing; `migrate-oracle` (a real
# run) prints its summary AFTER a successful write. stderr on any
# non-zero exit is EXACTLY ONE line. `append-attempt` may ALSO print one budget-notice
# line to stderr on an otherwise-successful (exit 0) run — see DEFAULT_BUDGET_BYTES
# below; that is not a rejection, just visibility, and the append still happens.
# `rotate` may likewise print one LEDGER_IRREDUCIBLE notice to stderr on an otherwise-
# successful (exit 0) run when it determines the ledger cannot be reduced further
# (a03-ledger-budget-irreducible spec §2.1/§2.5) — same non-error notice shape, same
# one-line discipline. `tick-step` may likewise print exactly ONE stderr warning naming
# the ledger, on an otherwise-successful (exit 0) run, when the oracle sidecar cannot be
# written (Decision 11 of tooling-fixes, amending 01-compact-oracle-records-spec.md
# §2.6 step 5's "no stderr" line) — the record is still written, in long form.
#
# Core Perl only: strict, warnings, Getopt::Long, Fcntl(:flock), JSON::PP, B. No
# other module may be loaded on any path (latency constraint, §2.5) -- with ONE
# named exception: `set-checks` (27-ledger-set-checks) `require`s bp-checks.pl,
# from this file's own directory, INSIDE that op only, to reuse BpChecks::parse_table
# / BpChecks::missing / BpChecks::_fm rather than re-implement the checks-table
# vocabulary a second time. bp-checks.pl in turn pulls in core File::Basename /
# File::Spec. No other verb's load path is affected.
use strict;
use warnings;
use Getopt::Long qw(GetOptionsFromArray);
use Fcntl qw(:flock);
use JSON::PP ();
use B ();

my $EMDASH = "\xE2\x80\x94";

# b45-ledger-context-budget-spec.md §4: a single named constant, ~10k tokens at this
# repo's ~4 bytes/token estimate. `rotate --budget` may override it for that one call;
# `append-attempt`'s warning always measures against this default (no CLI override
# there — the warning is visibility, not policy).
use constant DEFAULT_BUDGET_BYTES => 40000;

# =====================================================================================
# Oracle identity (08-completion-claims-checked) — constants (spec §2.1, exact names).
# =====================================================================================
use constant ORACLE_SECTION_HEADING   => '## Oracle identity';
use constant ORACLE_LINE_PREFIX       => '- oracle ';   # note the single trailing space
use constant ORACLE_DESCRIPTION_CAP   => 300;           # descriptions[] omitted above this
use constant ORACLE_DEFAULT_TIMEOUT_S => 300;

# 01-compact-oracle-records (bug 20260926-155710-2c57) — compact ledger records + sidecar
# (spec §2.1, exact names).
use constant ORACLE_RECORD_MAX_BYTES  => 400;   # hard cap on one compact ledger line, prefix included
use constant ORACLE_COMPACT_VERSION   => 2;     # value of the "v" key that marks a compact record
use constant ORACLE_REASON_MAX_CHARS  => 64;    # compact "reason" length after sanitising
our @ORACLE_RECORDED_STEPS = (3, 5);
our @PIPELINE_CONDITIONAL_STEPS = (8);

# The default test-run implementation (spec §2.2). Test-only in-process seam: a caller
# may override $main::ORACLE_RUN_FN entirely (e.g. to `die`, simulating an unrecoverable
# derivation failure — AC-12). Never loaded/used outside tick-step --step 3|5.
#
# Uses a real fork ('-|' open with no LIST — MSYS2/Git-for-Windows perl supports genuine
# fork/exec, unlike native Win32 perl) plus a select()-based polling read loop for the
# timeout, deliberately NOT alarm(): measured on this host, alarm's SIGALRM does not
# reliably interrupt a blocking read on a forked pipe here, so a select() with an
# explicit per-iteration timeout (which needs no signal delivery at all) is what
# actually bounds the wait. On timeout the child is killed outright (best-effort; see
# spec §5's named residual risk).
our $ORACLE_RUN_FN = sub {
    my ($test_path, $timeout_s) = @_;
    $timeout_s = ORACLE_DEFAULT_TIMEOUT_S unless defined $timeout_s && $timeout_s > 0;
    my $interp = (defined $ENV{BP_ORACLE_RUN_CMD} && length $ENV{BP_ORACLE_RUN_CMD})
        ? $ENV{BP_ORACLE_RUN_CMD} : $^X;

    my $pid = open(my $fh, '-|');
    die "ORACLE_SPAWN_FAIL\n" unless defined $pid;
    if ($pid == 0) {
        open(STDERR, '>&STDOUT');
        exec($interp, $test_path) or exit(126);
    }

    my $out = '';
    my $deadline = time() + $timeout_s;
    my $timed_out = 0;
    while (1) {
        my $remaining = $deadline - time();
        if ($remaining <= 0) { $timed_out = 1; last }
        my $rin = '';
        vec($rin, fileno($fh), 1) = 1;
        my $wait = $remaining > 1 ? 1 : $remaining;
        my $nfound = select($rin, undef, undef, $wait);
        if ($nfound && $nfound > 0) {
            my $buf;
            my $n = sysread($fh, $buf, 65536);
            last unless defined $n && $n > 0;   # EOF or read error -> child is done
            $out .= $buf;
        }
    }

    if ($timed_out) {
        eval { kill('KILL', $pid) };
        eval { waitpid($pid, 0) };
        eval { close($fh) };
        die "ORACLE_TIMEOUT\n";
    }

    close($fh);
    waitpid($pid, 0);
    my $exit_code = defined $? ? ($? >> 8) : undef;
    return ($out, $exit_code);
};

# The injected-rename seam (bp-token-keeper.pl's `rename_fn` shape). When
# BP_LEDGER_FAIL_RENAME is set and non-empty, simulate a mid-write rename failure
# without touching the filesystem — the only test-only environment hook here.
my $RENAME_FN = sub { return rename($_[0], $_[1]) };
if (defined $ENV{BP_LEDGER_FAIL_RENAME} && length($ENV{BP_LEDGER_FAIL_RENAME})) {
    $RENAME_FN = sub { return 0 };
}

# =====================================================================================
# stderr / exit helpers — one line, one framing convention: `bp-ledger: <sub>: ...`
# =====================================================================================

sub emit_err {
    my ($m) = @_;
    $m =~ s/[\r\n]+/ /g;
    print STDERR $m . "\n";
}

sub arg_error      { my ($sub, $msg)          = @_; emit_err("bp-ledger: $sub: $msg"); exit 3 }
sub io_error       { my ($sub, $path, $msg)   = @_; emit_err("bp-ledger: $sub: $path: $msg"); exit 4 }
sub reject_error   { my ($sub, $path, $detail)= @_; emit_err("bp-ledger: $sub: $path: $detail"); exit 2 }
sub notfound_error { my ($sub, $path, $msg)   = @_; emit_err("bp-ledger: $sub: $path: $msg"); exit 5 }

# `create`'s own arg-safety check, copied verbatim from bp-blueprint.pl's
# field_safe (op_init) -- a value carrying a pipe or a CR/LF cannot round-trip
# through the frontmatter's single-line `key: value` shape.
# Guarded against a "Subroutine redefined" warning if this file and
# bp-blueprint.pl (which defines the same sub, same package) are ever loaded
# together in one process -- same defensive idiom ledger-guard.sh:241-244
# already needed for its own require of this file.
unless (defined &main::field_safe) {
    *main::field_safe = sub { my ($s) = @_; return defined($s) && $s !~ /[\r\n|]/ };
}

# A NOTICE is a state of the ledger, never an outcome of the call (a03 spec §2.1): it
# must NOT reuse the `bp-ledger: <sub>: <path>: <msg>` shape the four error helpers
# above emit (that shape is indistinguishable from a real rejection), and it must carry
# a stable, greppable, machine-readable TOKEN right after the op prefix (spec §2.2) so a
# caller can tell the three budget outcomes apart without parsing English. Exit code is
# whatever the caller was already going to exit with (0, always, for a notice) — this
# never calls exit itself.
sub emit_notice {
    my ($sub, $token, $msg) = @_;
    $msg =~ s/[\r\n]+/ /g;
    print STDERR "bp-ledger: $sub: $token: $msg\n";
}

# =====================================================================================
# Budget-notice marker (a03 spec §2.1) — cross-process suppression for the ONE-TIME
# "this ledger is irreducible" fact. A sidecar file next to the ledger, so it survives
# across processes (a per-process flag is explicitly NOT acceptable — each bp-ledger.pl
# invocation is a fresh process). `rotate` writes it when it determines irreducibility
# and clears it the moment a rotate finds the ledger reducible again; `append-attempt`
# clears it the moment the ledger is genuinely back under budget. Either clearing means
# the NEXT over-budget notice starts fresh, so suppression can never go stale (spec's
# own bullet: "stale suppression is a worse defect than the noise it replaces").
# =====================================================================================

sub budget_marker_path { return "$_[0].budget-state" }

# Trust window for a "notified, stop repeating" marker (red-team step6 MAJOR-1): the
# sidecar lives in the same directory as the ledger, outside ledger-guard.sh's
# `packages/*.md` glob, so anything with ordinary write access to that directory can
# plant one without ever running a genuine `rotate`. This file cannot cheaply re-derive
# rotate's own floor/forced-entry computation to *prove* a marker's claim, so instead it
# bounds how long a "notified" marker is trusted before append-attempt re-asserts the
# notice regardless of what the marker says. A forged or stale marker therefore fails
# toward NOISY, never toward permanently silent -- the worst a forgery/staleness can do
# is delay one re-notification by at most this many seconds, not suppress forever.
# Override for tests only (mirrors the BP_LEDGER_FAIL_RENAME test-only seam above).
my $BUDGET_MARKER_TTL_SECONDS = 3600;
if (defined $ENV{BP_LEDGER_BUDGET_MARKER_TTL} && $ENV{BP_LEDGER_BUDGET_MARKER_TTL} =~ /^\d+$/) {
    $BUDGET_MARKER_TTL_SECONDS = $ENV{BP_LEDGER_BUDGET_MARKER_TTL};
}

# Deliberately a plain truncate-and-write, not the tmp+rename+read-back ceremony the
# ledger/history writes use elsewhere in this file (reviewer step6 MINOR): the marker is
# a single short advisory line, its own worst-case torn-read is "treat it as absent/
# stale and re-notify" (see budget_marker_fresh above), which is already the fail-safe
# this file wants -- the ceremony would add real complexity for no correctness gain here.
sub mark_irreducible {
    my ($ledger) = @_;
    open(my $fh, '>', budget_marker_path($ledger)) or return;
    print {$fh} "irreducible pending " . time() . "\n";
    close $fh;
}

sub mark_irreducible_notified {
    my ($ledger) = @_;
    open(my $fh, '>', budget_marker_path($ledger)) or return;
    print {$fh} "irreducible notified " . time() . "\n";
    close $fh;
}

sub clear_budget_marker {
    my ($ledger) = @_;
    my $p = budget_marker_path($ledger);
    unlink $p if -e $p;
}

sub read_budget_marker {
    my ($ledger) = @_;
    my $p = budget_marker_path($ledger);
    return undef unless -e $p;
    open(my $fh, '<', $p) or return undef;
    my $line = <$fh>;
    close $fh;
    return undef unless defined $line;
    chomp $line;
    my ($state, $flag, $ts) = split(' ', $line);
    return undef unless defined $state;
    return { state => $state, flag => ($flag // ''), ts => $ts };
}

# Was this marker's "notified" claim stamped recently enough (by a real bp-ledger.pl
# process, in the past, within the trust window) to still be honoured? A missing,
# non-numeric, or future timestamp is exactly what a hand-planted forgery looks like
# (the demonstrated attack wrote no timestamp at all) -- treat any of those as already
# expired rather than trusting them, so the fail-safe direction is always toward noise.
sub budget_marker_fresh {
    my ($ts) = @_;
    return 0 unless defined $ts && $ts =~ /^\d+$/;
    my $now = time();
    return 0 if $ts > $now;
    return ($now - $ts) < $BUDGET_MARKER_TTL_SECONDS;
}

sub iso_now {
    my @t = gmtime(time);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# =====================================================================================
# last_updated VALUE integrity (b19-ledger-timestamp-integrity) — an AUDIT-TRAIL check,
# not a run-control one (bp-status.sh uses mtime; stop-gate.sh and the watchdog never
# parse this field at all, per the spec's own retracted impact claim). ONE
# implementation, enforced at BOTH this API (below) and the b12 hook, which `require`s
# THIS FILE rather than reimplementing the check — two copies would drift, and the
# failure mode is specific and nasty: a sanctioned API write the guard then rejects,
# leaving a coordinator with no legal move at all.
# =====================================================================================

# Ordinary container/host clock skew is seconds to low single-digit minutes, while the
# defect this check exists to catch was observed at 25-55 minutes, once ~1 hour. 300s
# sits an order of magnitude above normal skew and an order of magnitude below the
# smallest observed defect, so neither bound is close. Verified against the full real
# ledger corpus at this value (0 of it is future-dated beyond 300s).
use constant LEDGER_FUTURE_SKEW_S => 300;

# Pull the last_updated: VALUE out of a frontmatter block, byte-wise, exactly as V3
# above locates keys. Returns undef if there is no parseable frontmatter or no such key
# (both cases are V3's job to reject; this function is silent about it).
sub extract_last_updated {
    my ($B) = @_;
    return undef unless $B =~ /\A---\s*\n(.*?)\n---/s;
    my $FM = $1;
    for my $l (split(/\n/, $FM, -1)) {
        if ($l =~ /^last_updated:\s*(.*?)\s*$/) { return $1 }
    }
    return undef;
}

# Core-Perl-only (§2.5 forbids adding Time::Local to the allowed-module list): epoch
# seconds (UTC) from a strict `YYYY-MM-DDTHH:MM:SSZ` stamp, via Howard Hinnant's
# civil_from_days day-counting algorithm. Returns undef on anything not exactly that
# shape or out of range — deliberately lenient: a malformed VALUE is not this check's
# job (V1-V5 above police shape; this function only ever compares two valid stamps).
sub epoch_from_iso {
    my ($s) = @_;
    return undef unless defined $s;
    return undef unless $s =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/;
    my ($Y, $Mo, $D, $H, $Mi, $S) = (int($1), int($2), int($3), int($4), int($5), int($6));
    return undef if $Mo < 1 || $Mo > 12 || $D < 1 || $D > 31 || $H > 23 || $Mi > 59 || $S > 60;
    my $y = $Y;
    $y-- if $Mo <= 2;
    my $era = int(($y >= 0 ? $y : $y - 399) / 400);
    my $yoe = $y - $era * 400;                                       # [0, 399]
    my $mp  = ($Mo + 9) % 12;                                        # Mar=0 .. Feb=11
    my $doy = int((153 * $mp + 2) / 5) + $D - 1;                     # [0, 365]
    my $doe = $yoe * 365 + int($yoe / 4) - int($yoe / 100) + $doy;   # [0, 146096]
    my $days = $era * 146097 + $doe - 719468;                        # days since 1970-01-01
    return $days * 86400 + $H * 3600 + $Mi * 60 + $S;
}

# THE check (spec §2). $old_bytes may be undef (nothing on disk to compare against —
# e.g. a fresh Write, or the static `validate --stdin`/`--ledger` surfaces, which
# validate one buffer with no notion of a prior write at all). Returns undef (fine) or
# a one-sentence DETAIL FRAGMENT in the same no-framing-prefix convention as
# validate_bytes above.
sub last_updated_check {
    my ($old_bytes, $new_bytes) = @_;

    my $new_val = extract_last_updated($new_bytes);
    return undef unless defined $new_val;
    my $new_ep = epoch_from_iso($new_val);
    return undef unless defined $new_ep;

    my $now = time;
    if (($new_ep - $now) > LEDGER_FUTURE_SKEW_S) {
        return sprintf(
            'has a last_updated: value that is more than %d seconds ahead of the current time (%s): '
          . '%s. Clock skew this large is rejected so a coordinator with a wrong clock can correct rather than guess.',
            LEDGER_FUTURE_SKEW_S, iso_now(), $new_val);
    }

    if (defined $old_bytes) {
        my $old_val = extract_last_updated($old_bytes);
        if (defined $old_val) {
            my $old_ep = epoch_from_iso($old_val);
            if (defined $old_ep && $new_ep < $old_ep) {
                return sprintf(
                    'has a last_updated: value (%s) OLDER than the value currently on disk (%s); '
                  . 'a write must never move last_updated: backward (an equal, same-second value is permitted).',
                    $new_val, $old_val);
            }
        }
    }

    return undef;
}

# =====================================================================================
# The validation core — V1..V5, normative (spec §2.4). First failing class wins.
# Returns undef (valid) or a one-sentence DETAIL FRAGMENT (no framing prefix — the two
# framings differ only in prefix, per §2.2 / AC-30).
# =====================================================================================

my @REQUIRED_KEYS = qw(package blueprint status write_set last_updated);
# `dropped` added 2026-08-13, the THIRD home of the same defect (07d28a2 fixed
# bp-blueprint.pl, 8cc98d8 fixed ledger-guard.sh and stop-gate.sh). This is the
# sanctioned WRITER of package ledgers, so without it a coordinator that
# legitimately dropped its package could not record that through the typed API
# at all -- while bp-drive-next.pl and bp-orchestrator.pl both read the field and
# call `dropped` terminal. Filed as 2026-08-06 batch2 #12.
#
# `converging` belongs here and NOT in bp-blueprint.pl's vocabulary: this is the
# package ledger's mid-flight value, which the blueprint.md summary table has no
# use for. Two vocabularies on purpose -- do not "unify" them.
my @STATUSES      = qw(pending running converging reviewing done blocked parked dropped);

# 04-model-effort-ledger-validation §2.1. Model is derived from every real usage
# site in this codebase (D-A); effort is anchored to bp-launch.sh:70-73, which
# validates the `claude` CLI's own accepted values. DUPLICATED, deliberately, in
# bp-model-check.pl (D-B) -- bp-ledger.pl loads core Perl only (:29-30) and
# cannot `require` it. model-effort-check.t's AC-17 pins the two copies (plus
# bp-launch.sh's effort case arm) together by PARSING the sources, so a drift
# between them is a test failure, not a silent divergence.
my @MODELS  = qw(sonnet opus haiku);
my @EFFORTS = qw(low medium high xhigh max);

# A STRINGIFIED PERL REFERENCE IN A LEDGER BODY IS NEVER INTENTIONAL.
#
# Observed on a live run (almanac 20260915-191939-da6e): a package's Escalation
# section ended
#
#     ...or adding the boolean fallback.SCALAR(0x5c7bd4bd3308)
#
# welded onto the last sentence with no separator. A writer interpolated a ref
# where it meant the referent, so whatever that text WAS is gone -- not
# mis-rendered, lost -- and nothing refused the write, because the section still
# parses as prose. The Escalation section is exactly what the orchestrator and
# the reporter read to decide what a blocked package needs.
#
# WHY THIS IS NOT PART OF validate_bytes. run_op validates the ORIGINAL bytes as
# well as the new ones, and a ledger that already carries this corruption would
# then reject every subsequent operation -- bricking the package this rule exists
# to protect. So the check is DIFFERENTIAL: it fires only when an operation
# INTRODUCES a ref address that was not already there. Existing damage stays
# operable and repairable; new damage cannot get in.
#
# Blessed refs stringify as Foo=HASH(0x...), so the optional class prefix is
# matched too.
my $REF_ADDR_RE = qr/(?:\w+=)?(?:SCALAR|ARRAY|HASH|CODE|REF|GLOB|Regexp|FORMAT|LVALUE|IO)\(0x[0-9a-fA-F]+\)/;

sub count_ref_addrs {
    my ($B) = @_;
    return 0 unless defined $B && length $B;
    my $n = 0;
    $n++ while $B =~ /$REF_ADDR_RE/g;
    return $n;
}

# validate_no_new_ref_addr($orig, $new) -> $detail | undef
sub validate_no_new_ref_addr {
    my ($orig, $new) = @_;
    my $before = count_ref_addrs($orig);
    my $after  = count_ref_addrs($new);
    return undef if $after <= $before;
    my ($sample) = ($new =~ /($REF_ADDR_RE)/);
    return 'would write a stringified Perl reference into the ledger body ('
         . (defined $sample ? $sample : 'ref address')
         . '). That is always a writer bug -- the value it points at is being '
         . 'LOST, not merely mis-rendered. Dereference it before writing.';
}

sub validate_bytes {
    my ($B) = @_;

    # V1 — control byte. Exempt \t \n \r. C1 (0x80-0x9F) is NOT rejected.
    if ($B =~ /([\x00-\x08\x0B\x0C\x0E-\x1F\x7F])/) {
        my $off  = $-[1];
        my $byte = ord($1);
        my $pre  = substr($B, 0, $off);
        my $line = 1 + ($pre =~ tr/\n//);
        return sprintf('contains a control byte 0x%02X at line %d.', $byte, $line);
    }

    # V2 — frontmatter block, \A-anchored, non-greedy.
    my ($FM) = $B =~ /\A---\s*\n(.*?)\n---/s;
    unless (defined $FM) {
        return 'has no parseable frontmatter block: it must begin at byte 0 with a line '
             . '"---" and be closed by a later line "---".';
    }
    my @FML = split(/\n/, $FM, -1);

    # V3 — required frontmatter keys, matched line-wise inside the FM block only.
    my @missing;
    for my $k (@REQUIRED_KEYS) {
        my $found = 0;
        for my $l (@FML) { if ($l =~ /^\Q$k\E:\s*(.*?)\s*$/) { $found = 1; last } }
        push @missing, $k unless $found;
    }
    if (@missing) {
        return 'is missing required frontmatter key(s): ' . join(', ', @missing) . '.';
    }

    # V4 — status value. The FIRST status: line wins.
    my $status;
    for my $l (@FML) { if ($l =~ /^status:\s*(.*?)\s*$/) { $status = $1; last } }
    $status = '' unless defined $status;
    unless (grep { $_ eq $status } @STATUSES) {
        return 'frontmatter status: "' . $status . '" is not a protocol status. Allowed: '
             . join(', ', @STATUSES) . '.';
    }

    # V4a — write_set: must not be EMPTY.
    #
    # Bug 20260916-180317-71de: a ledger was rewritten to a 727-byte stub with a
    # bare `write_set:` and nothing after it, losing test_paths, checks,
    # max_turns, effort, Inputs, Constraints and most of Scope. It passed
    # validation, because @REQUIRED_KEYS checks a key is PRESENT, never that it
    # carries a value.
    #
    # AN EMPTY WRITE SET IS NOT A DEGRADED STATE, IT IS A DEAD ONE. guard-writes
    # permits nothing, so the package cannot write a single file -- it would
    # relaunch, be unable to touch its own deliverables, and block again, with no
    # field left to explain why.
    #
    # The rule already existed and was enforced in the wrong place: bp-auditor's
    # DAG-integrity list says in as many words "no package declares an empty
    # `write_set`". That is an authoring-time check by an agent. This is the
    # sanctioned WRITER, and a writer that accepts a state its own auditor
    # forbids is how the stub reached disk. Same shape as V4b below, which was
    # added for the same reason an hour earlier.
    #
    # Verified before shipping: every ledger in the tree, active and archived,
    # carries a non-empty write_set, so this rejects nothing that exists.
    # THE FIELD HAS TWO LEGAL FORMS, and the first draft of these rules knew only
    # one. A colon-delimited scalar (`write_set: a/b.pm:c/d.t`) is what every
    # ledger in this tree uses -- and a YAML-ish list is ALSO accepted:
    #
    #   write_set:
    #     - plugins/butler/scripts/bp-ledger.pl
    #
    # ledger-api.t's own canonical fixture uses the list form. Validating the
    # scalar-only rules against "every ledger in the tree" missed this entirely,
    # because the tree happens to use one form and the oracle uses the other --
    # 100 assertions went red the moment the rules ran against it. A check
    # written against the data you have, rather than the format you accept, is a
    # check that passes until someone uses the other half of the contract.
    my $field_segments = sub {
        my ($field) = @_;
        my ($i, $scalar) = (-1, undef);
        for my $n (0 .. $#FML) {
            if ($FML[$n] =~ /^\Q$field\E:\s*(.*?)\s*$/) { $i = $n; $scalar = $1; last }
        }
        return (undef, ()) if $i < 0;
        my @items;
        for my $n ($i + 1 .. $#FML) {
            last unless $FML[$n] =~ /^\s+-\s*(.*?)\s*$/;
            push @items, $1 if length $1;
        }
        return ($scalar, @items);
    };

    {
        my ($ws, @items) = $field_segments->('write_set');
        if (defined $ws && $ws eq '' && !@items) {
            return 'frontmatter write_set: is EMPTY. A package whose write set permits nothing '
                 . 'cannot edit its own deliverables -- it would relaunch, write nothing, and block '
                 . 'again with no field left to explain why. This is the shape a truncated ledger '
                 . 'takes (report 20260916-180317-71de); if the package genuinely owns no files, it '
                 . 'should not be a package.';
        }
    }

    # V4b — write_set:/test_paths: segments must be PATHS, not prose.
    #
    # Bug 20260916-175013-34af. These fields are a single COLON-DELIMITED string,
    # exported verbatim into BP_WRITE_SET by bp-launch.sh and split on ':' by
    # guard-writes.sh. An author who annotates the field in prose --
    #
    #   write_set: a/b.pm:c/d.t:e/f.pl — in scope for ONE thing only: the entry point
    #
    # -- produces FOUR patterns instead of three, and the third is
    # "e/f.pl — in scope for ONE thing only", which matches no file on disk. The
    # bare path `e/f.pl` is then NOT IN THE WRITE SET AT ALL, and the package
    # cannot edit a file its own blueprint mandates in three places. Measured:
    # `match_any "scripts/fleet-orchestrator.pl" "$BP_WRITE_SET"` -> NOMATCH.
    #
    # WHY IT MUST BE CAUGHT HERE AND NOT LATER. Nothing re-derives BP_WRITE_SET
    # mid-session -- guard-writes.sh reads only the env var -- so the corrupt
    # value is fixed for the session's lifetime and no in-session ledger repair
    # unblocks the running coordinator. A relaunch is the only recovery. The
    # field is malformed AT REST and every layer below faithfully propagates it,
    # so the only place to stop it is where the ledger is written.
    #
    # The test is whitespace. The FIRST justification written here was that "a
    # path with a space is already unrepresentable in a colon-delimited list, so
    # this forbids nothing that previously worked" -- and that was WRONG, caught
    # by running the rule over every ledger in the tree including the archive:
    #
    #   _archive/audit-remediation/packages/08-job-search-coherence.md
    #   write_set: C:/Users/André/Personal Files/Job search/CLAUDE.md:C:/Users/...
    #
    # Absolute paths, with spaces, targeting another project. The rule flags it,
    # and flagging it is CORRECT -- but not for the reason first given. That
    # field was already broken before anyone annotated anything, because a
    # WINDOWS DRIVE LETTER CONTAINS A COLON: splitting it yields "C",
    # "/Users/André/Personal Files/Job search/CLAUDE.md", "C", ... So the
    # colon-delimited write_set format cannot express an absolute Windows path
    # AT ALL, and a blueprint that targets another project by absolute path has
    # a silently corrupt write set from the moment it is authored.
    #
    # That is a separate finding from 34af and is recorded in the V4c check
    # below rather than left implicit in a whitespace rule that happens to catch
    # it. The honest statement of THIS rule is narrower than the original: it
    # forbids prose, and it also refuses space-bearing absolute paths, which the
    # format could never carry safely in the first place.
    for my $field (qw(write_set test_paths)) {
        my ($val, @items) = $field_segments->($field);
        next unless defined $val;

        # DEFER TO V4c WHEN A DRIVE LETTER IS PRESENT. An absolute Windows path
        # splits into a bare drive letter plus a remainder that usually contains
        # spaces, so this whitespace rule fires first and reports "not a path"
        # -- true, but a symptom. The drive letter is the root cause and the
        # more useful message, so it gets to speak.
        next if join(':', (length $val ? $val : ()), @items) =~ m{(?:^|:)[A-Za-z]:[/\\]};

        my @segs = ((length $val ? split(/:/, $val, -1) : ()), @items);
        for my $seg (@segs) {
            next unless length $seg;
            next unless $seg =~ /\s/;
            return "frontmatter $field: contains a segment that is not a path: \"$seg\". "
                 . 'These fields are colon-delimited and are split on ":" by guard-writes.sh, so '
                 . 'an annotation containing a colon silently splits into extra patterns and '
                 . 'DROPS the annotated path from the write set (report 20260916-175013-34af). '
                 . 'Put explanatory prose in the Scope section, never in this field.';
        }
    }

    # V4c — a Windows DRIVE LETTER in write_set:/test_paths: is always corrupt.
    #
    # Found 2026-09-17 while validating V4b against the archive, not filed from
    # a symptom -- which is why it is worth its own check rather than being left
    # to the whitespace rule that happened to catch one instance.
    #
    # These fields are split on ":". `C:/Users/...` therefore splits into "C" and
    # "/Users/...", so a blueprint targeting another project by absolute Windows
    # path has a silently corrupt write set FROM THE MOMENT IT IS AUTHORED --
    # before anyone annotates anything, and with no symptom until a guard refuses
    # a write nobody expected it to refuse. The bare "C" pattern is also the
    # dangerous half: depending on the matcher it can match far more than
    # intended, not less.
    #
    # The format cannot carry absolute Windows paths, so the rule is to say so at
    # the point of writing rather than to let the field look plausible.
    for my $field (qw(write_set test_paths)) {
        my ($val, @items) = $field_segments->($field);
        next unless defined $val;
        my $joined = join(':', (length $val ? $val : ()), @items);
        next unless length $joined;
        next unless $joined =~ m{(?:^|:)([A-Za-z]):[/\\]};
        my $drive = $1;
        return "frontmatter $field: contains a Windows drive letter (\"$drive:\"). This field is "
             . 'split on ":", so an absolute Windows path splits into a bare drive letter plus the '
             . 'rest and the intended path is never matched -- the field is corrupt from the moment '
             . 'it is written, with no symptom until a guard refuses a write. Use repository-'
             . 'relative paths.';
    }

    # V4d — a ledger may not carry a `depends_on:` frontmatter field.
    #
    # Report 20260916-185610-8ee1 established it is a PHANTOM FIELD: written by
    # hand, read by NOTHING, validated by nothing, and absent from the template
    # that defines what a ledger contains. The scheduler's DAG comes from
    # blueprint.md's package-status table -- bp-drive-next.pl says so in as many
    # words -- and no script anywhere reads a ledger's frontmatter depends_on.
    #
    # It looks exactly as authoritative as write_set and test_paths, which ARE
    # contracts. The measured harm was comprehension, not scheduling: a
    # coordinator reading "this file alone", which every ledger header promises
    # is sufficient, learns nothing about ordering or learns something false;
    # and the report's own filer inferred a scheduling hazard from it and filed
    # at the wrong severity before checking which representation the scheduler
    # reads.
    #
    # Measured 2026-09-17 before adding this: ZERO of the 32 active ledgers
    # carry the field. So this forbids nothing in use -- it stops it coming
    # back, which is the report's own revised suggestion 1 (delete it entirely
    # rather than reconcile two sources that can only ever disagree).
    #
    # Ordering belongs in a `## Dependency edges` SECTION, in prose, where a
    # reader can see the reason and not just the edge.
    {
        for my $l (@FML) {
            next unless $l =~ /^depends_on:/;
            return 'frontmatter depends_on: is not a ledger field. The scheduler builds its DAG '
                 . 'from blueprint.md\'s package-status table and NOTHING reads this key, so a '
                 . 'second copy here can only ever drift out of agreement with the one that counts '
                 . '(report 20260916-185610-8ee1). Put ordering, and the reason for it, in a '
                 . '"## Dependency edges" section instead.';
        }
    }

    # V5 — required sections, presence only, prefix matches. No uniqueness constraint.
    my @sections = (
        ['## Next action',             qr/^## Next action/m],
        ['## Decisions & attempt log', qr/^##\s+Decisions & attempt log\b/m],
        ['## Pipeline',                qr/^##\s+Pipeline\b/m],
        ['## Outputs',                 qr/^##\s+Outputs\b/m],
        ['## Escalation',              qr/^##\s+Escalation\b/m],
    );
    my @gone = map { $_->[0] } grep { $B !~ $_->[1] } @sections;
    if (@gone) {
        return 'drops required section heading(s): ' . join(', ', @gone) . '.';
    }

    return undef;
}

# =====================================================================================
# Shared mechanics (§2.11): fence-aware line walking, section location.
# =====================================================================================

# Walk lines in [start, end) of $B. $cb->($line, $abs_offset, $len, $has_nl) is called
# for each; if it returns a defined value, the walk stops and that value is returned.
sub each_line_with_offset {
    my ($B, $start, $end, $cb) = @_;
    my $pos = $start;
    while ($pos < $end) {
        my $nl       = index($B, "\n", $pos);
        my $has_nl   = ($nl >= 0 && $nl < $end) ? 1 : 0;
        my $line_end = $has_nl ? $nl : $end;
        my $line     = substr($B, $pos, $line_end - $pos);
        my $r = $cb->($line, $pos, $line_end - $pos, $has_nl);
        return $r if defined $r;
        $pos = $has_nl ? $nl + 1 : $end;
    }
    return undef;
}

# A fence delimiter line, CommonMark-accurate: a backtick fence's info string may not
# itself contain a backtick (else it is not a valid fence, e.g. an inline ``` `x` ```
# aside quoted in prose — b09's live landmine). Tilde fences have no such restriction.
#
# RESOLVES A SPEC INCONSISTENCY (2026-08-03, coordinator). Spec §2.11's prose describes
# a NAIVE toggle — "any line whose leading-whitespace-stripped form begins with three or
# more backticks or three or more tildes" — while §469 puts b09 in the corpus precisely
# as "the corpus's live proof a naive parser is foolable". Both cannot hold.
#
# It is not a matter of taste; the naive rule is IMPOSSIBLE here, demonstrated by running
# it. b09:625 is prose containing an inline ``` `## Next action` ``` aside; the only real
# fence pair is 925/928. Naive counting therefore sees 3 fence lines (odd), leaves the
# Decisions section unterminated at EOF, and §2.11's own rule then mandates exit 5 —
# contradicting AC-8's "append-attempt on b09 exits 0". Measured: the naive rule fails
# AC-8 assertions 125, 126 and 128; CommonMark fails none.
#
# The oracle's own fence helpers (fenced_lines / offset_in_fence in t/65) were naive and
# were corrected to match, so parser and oracle agree on what a fence IS. That agreement
# is load-bearing beyond this package: the MEANS-DEVIATION anti-forgery guard at
# SKILL.md:121 is fence-scoped, and if the guard and the parser disagreed about which
# lines are fences, the gap between them would be exactly the forgery window the guard
# exists to close.
sub is_fence_line {
    my ($line) = @_;
    if ($line =~ /^[ \t]*(`{3,})(.*)$/s) {
        return index($2, '`') >= 0 ? 0 : 1;
    }
    return 1 if $line =~ /^[ \t]*~{3,}/;
    return 0;
}

# Locate the FIRST heading matching $head_re and its fence-aware section end
# (first non-fenced /^##\s/ line after it, or EOF).
#
# BOTH scans are fence-aware, and the heading scan must be. The original version
# located the heading with a bare `$B =~ /$head_re/`, which matches the first
# occurrence ANYWHERE — including inside a fenced code block. A ledger that
# quotes `## Decisions & attempt log` inside a ``` fence (this repo's own
# documentation does exactly that) anchored the section on the fenced lookalike.
# The end-scan then started from inside a fence with $infence = 0, inverting
# every subsequent toggle, and the entry was spliced INTO the code block —
# corrupting quoted content that AC-8 requires stay byte-identical.
# All three call sites pass /m line-anchored patterns, so per-line matching is
# equivalent for the heading itself.
sub locate_section {
    my ($B, $head_re) = @_;
    my $len_B   = length($B);
    my $infence = 0;
    my ($body_start, $found_head);
    each_line_with_offset($B, 0, $len_B, sub {
        my ($line, $off, $len, $has_nl) = @_;
        if (is_fence_line($line)) { $infence = !$infence; return undef }
        return undef if $infence;
        if ($line =~ /$head_re/) {
            $body_start = $has_nl ? $off + $len + 1 : $len_B;
            $found_head = 1;
            return 1;
        }
        return undef;
    });
    return undef unless $found_head;

    $infence  = 0;
    my $end   = $len_B;
    my $found = 0;
    each_line_with_offset($B, $body_start, $len_B, sub {
        my ($line, $off, $len, $has_nl) = @_;
        if (is_fence_line($line)) { $infence = !$infence; return undef }
        if (!$infence && $line =~ /^##\s/) { $end = $off; $found = 1; return 1 }
        return undef;
    });
    return {
        body_start   => $body_start,
        body_end     => $end,
        unterminated => (!$found && $infence) ? 1 : 0,
    };
}

# =====================================================================================
# Region-splice functions — one per op. Each returns ($new_bytes, undef) on success, or
# (undef, $reason) when the target region is not found (-> exit 5 at the call site).
# =====================================================================================

sub replace_first_key_line {
    my ($B, $rstart, $rend, $key, $new_line) = @_;
    my $region = substr($B, $rstart, $rend - $rstart);
    my $off = 0;
    for my $line (split(/\n/, $region, -1)) {
        if ($line =~ /^\Q$key\E:\s*(.*?)\s*$/) {
            my $line_start = $rstart + $off;
            my $line_len   = length($line);
            return substr($B, 0, $line_start) . $new_line . substr($B, $line_start + $line_len);
        }
        $off += length($line) + 1;
    }
    return undef;
}

sub splice_set_status {
    my ($B, $status, $iso) = @_;
    return (undef, 'no frontmatter block to update') unless $B =~ /\A---\s*\n(.*?)\n---/s;
    my ($fs, $fe) = ($-[1], $+[1]);
    my $new = replace_first_key_line($B, $fs, $fe, 'status', "status: $status");
    return (undef, 'status: key not found in frontmatter') unless defined $new;
    $new =~ /\A---\s*\n(.*?)\n---/s;
    my ($fs2, $fe2) = ($-[1], $+[1]);
    my $new2 = replace_first_key_line($new, $fs2, $fe2, 'last_updated', "last_updated: $iso");
    return (undef, 'last_updated: key not found in frontmatter') unless defined $new2;
    return ($new2, undef);
}

# append-attempt / add-output share this mechanic: insert $entry_text (no trailing
# newline) either replacing a lone italic placeholder line, or before the section's
# terminating heading / EOF.
sub splice_insert_entry {
    my ($B, $head_re, $entry_text) = @_;
    my $loc = locate_section($B, $head_re);
    return (undef, 'target section heading not found') unless $loc;
    return (undef, 'section ends inside an unterminated fenced code block; refusing to insert into a fence')
        if $loc->{unterminated};

    my $infence = 0;
    my @nonblank;
    each_line_with_offset($B, $loc->{body_start}, $loc->{body_end}, sub {
        my ($line, $off, $len, $has_nl) = @_;
        if (is_fence_line($line)) { $infence = !$infence; return undef }
        if (!$infence && $line !~ /^\s*$/) { push @nonblank, { off => $off, len => $len, line => $line } }
        return undef;
    });

    if (@nonblank == 1 && $nonblank[0]{line} =~ /^_\(.*\)_$/) {
        my $abs = $nonblank[0]{off};
        my $len = $nonblank[0]{len};
        return (substr($B, 0, $abs) . $entry_text . substr($B, $abs + $len), undef);
    }

    my $off = $loc->{body_end};
    return (substr($B, 0, $off) . $entry_text . "\n" . substr($B, $off), undef);
}

sub splice_tick_step {
    my ($B, $N) = @_;
    my $head_re = qr/^##\s+Pipeline\b/m;
    my $loc = locate_section($B, $head_re);
    return (undef, '## Pipeline section not found') unless $loc;

    my $infence = 0;
    my $target_re = qr/^(\s*-\s*\[)([ xX])(\]\s*\Q$N\E\.)/;
    my $result;
    each_line_with_offset($B, $loc->{body_start}, $loc->{body_end}, sub {
        my ($line, $off, $len, $has_nl) = @_;
        if (is_fence_line($line)) { $infence = !$infence; return undef }
        if (!$infence && $line =~ $target_re) {
            my $bracket_off = $off + length($1);
            my $cur = $2;
            if ($cur eq 'x' || $cur eq 'X') { $result = [$B, undef] }
            else { $result = [substr($B, 0, $bracket_off) . 'x' . substr($B, $bracket_off + 1), undef] }
            return 1;
        }
        return undef;
    });
    return @$result if $result;
    return (undef, "no line matching '- [ ] $N.' (or [x]/[X]) found in ## Pipeline");
}

sub splice_set_next_action {
    my ($B, $body) = @_;
    my $head_re = qr/^## Next action/m;
    my $loc = locate_section($B, $head_re);
    return (undef, '## Next action section not found') unless $loc;
    my $has_term = ($loc->{body_end} < length($B)) ? 1 : 0;
    my $new_span = "\n" . $body . ($has_term ? "\n\n" : "\n");
    return (substr($B, 0, $loc->{body_start}) . $new_span . substr($B, $loc->{body_end}), undef);
}

# =====================================================================================
# Oracle identity — derivation, records, sections, pipeline/claim-check (spec §2.3-2.9).
# =====================================================================================

# Pure. Strips a trailing TAP directive, truncates at the first "(", squeezes
# whitespace, trims. Returns '' for a description that normalizes to nothing.
sub normalize_description {
    my ($desc) = @_;
    return '' unless defined $desc;
    my $d = $desc;
    # A skipped point's TAP line is `ok N # skip <reason>`, so the whole
    # "description" is the directive; it asserts nothing (bug
    # 20261012-014847-ded4).
    $d =~ s/^\s*#\s*(?:SKIP|TODO)\b.*\z//is;
    $d =~ s/\s+#\s*(?:SKIP|TODO)\b.*\z//i;
    $d =~ s/\(.*\z//s;
    $d =~ s/\s+/ /g;
    $d =~ s/^\s+|\s+\z//g;
    return $d;
}

# Pure. $tap is the combined stdout+stderr of a run. Returns ($assertion_count,
# \@normalized_descriptions_sorted_unique).
sub parse_tap {
    my ($tap) = @_;
    $tap = '' unless defined $tap;
    my $count = 0;
    my %descset;
    for my $line (split(/\n/, $tap, -1)) {
        next if $line =~ /^\s/;   # indented (subtest) lines are never top-level
        next unless $line =~ /^(?:not )?ok(?:\s+(\d+))?(?:\s*-?\s*(.*))?$/;
        $count++;
        my $norm = normalize_description(defined $2 ? $2 : '');
        $descset{$norm} = 1 if length $norm;
    }
    my @descs = sort keys %descset;
    return ($count, \@descs);
}

# Impure but TOTAL: never dies, never warns, never writes to stderr, never exits.
# Returns a hashref, always (spec §2.3).
sub derive_oracle_identity {
    my ($test_path) = @_;
    my $result;
    local $SIG{__DIE__} = sub { };
    local $SIG{__WARN__} = sub { };
    eval {
        unless (defined $test_path && length $test_path && -f $test_path && -r $test_path) {
            $result = { status => 'unavailable', reason => 'not a readable file' };
            return;
        }
        my $sha_ok = eval { require Digest::SHA; 1 };
        unless ($sha_ok) {
            $result = { status => 'unavailable', reason => 'Digest::SHA unavailable' };
            return;
        }
        my $bytes;
        {
            open(my $fh, '<:raw', $test_path) or die "ORACLE_UNREADABLE\n";
            local $/;
            $bytes = <$fh>;
            close $fh;
            $bytes = '' unless defined $bytes;
        }
        my $sha = Digest::SHA::sha256_hex($bytes);

        my $timeout_s = ORACLE_DEFAULT_TIMEOUT_S;
        if (defined $ENV{BP_ORACLE_TIMEOUT_S} && $ENV{BP_ORACLE_TIMEOUT_S} =~ /^\d+$/) {
            $timeout_s = $ENV{BP_ORACLE_TIMEOUT_S};
        }

        my ($tap, $exit_code) = $ORACLE_RUN_FN->($test_path, $timeout_s);

        unless (defined $exit_code) {
            $result = { status => 'unavailable', reason => 'run failed' };
            return;
        }
        unless (defined $tap && length $tap) {
            $result = { status => 'unavailable', reason => 'no TAP output' };
            return;
        }

        my ($count, $descs) = parse_tap($tap);
        unless ($count) {
            $result = { status => 'unavailable', reason => 'no TAP output' };
            return;
        }

        my %rec = (status => 'ok', sha256 => $sha, assertions => $count + 0);
        $rec{descriptions_sha256} = Digest::SHA::sha256_hex(join("\n", @$descs));
        $rec{descriptions} = $descs if scalar(@$descs) <= ORACLE_DESCRIPTION_CAP;
        $result = \%rec;
    };
    if (my $err = $@) {
        if ($err =~ /ORACLE_TIMEOUT/) {
            $result = { status => 'unavailable', reason => 'timed out' };
        }
        else {
            $result = { status => 'unavailable', reason => 'internal error' };
        }
    }
    return $result // { status => 'unavailable', reason => 'internal error' };
}

# Replace every ref-address-shaped substring with a fixed elision token (spec §2.4),
# so a recorded description can never trip validate_no_new_ref_addr.
sub sanitize_ref_addrs_str {
    my ($s) = @_;
    return $s unless defined $s;
    $s =~ s/$REF_ADDR_RE/<ref-address-elided>/g;
    return $s;
}

sub encode_oracle_record {
    my ($rec) = @_;
    return ORACLE_LINE_PREFIX . JSON::PP->new->canonical(1)->ascii(1)->encode($rec);
}

sub oracle_records_equal_ignoring_time {
    my ($a, $b) = @_;
    my %a2 = %$a; delete $a2{recorded_at};
    my %b2 = %$b; delete $b2{recorded_at};
    return JSON::PP->new->canonical(1)->ascii(1)->encode(\%a2)
        eq JSON::PP->new->canonical(1)->ascii(1)->encode(\%b2);
}

# Build the JSON-ready record hash (spec §2.4). $identity is derive_oracle_identity's
# return; $reaccept, if given, is {reason=>..., delta=>...} already computed.
sub build_oracle_record {
    my (%p) = @_;
    my %rec = (
        step        => $p{step} + 0,
        path        => $p{path},
        recorded_at => $p{recorded_at},
        status      => $p{identity}{status},
    );
    if ($rec{status} eq 'ok') {
        $rec{sha256}     = $p{identity}{sha256};
        $rec{assertions} = $p{identity}{assertions} + 0;
        $rec{descriptions_sha256} = $p{identity}{descriptions_sha256};
        if (exists $p{identity}{descriptions}) {
            $rec{descriptions} = [ map { sanitize_ref_addrs_str($_) } @{ $p{identity}{descriptions} } ];
        }
    }
    else {
        $rec{reason} = sanitize_ref_addrs_str($p{identity}{reason});
    }
    if (exists $p{reaccept}) {
        my %ra = %{ $p{reaccept} };
        $ra{reason} = sanitize_ref_addrs_str($ra{reason}) if defined $ra{reason};
        $rec{reaccept} = \%ra;
    }
    return \%rec;
}

# Fence-aware, scoped to the ORACLE_SECTION_HEADING section. Silently skips any line
# that is not `- oracle <json-object>` or whose JSON fails to decode (spec §2.4).
sub parse_oracle_records {
    my ($bytes) = @_;
    my $loc = locate_section($bytes, qr/^\Q@{[ORACLE_SECTION_HEADING]}\E\b/m);
    return () unless $loc;
    my $prefix_re = qr/^\Q@{[ORACLE_LINE_PREFIX]}\E(\{.*\})\s*$/;
    my @records;
    my $infence = 0;
    each_line_with_offset($bytes, $loc->{body_start}, $loc->{body_end}, sub {
        my ($line, $off, $len, $has_nl) = @_;
        if (is_fence_line($line)) { $infence = !$infence; return undef }
        return undef if $infence;
        if ($line =~ $prefix_re) {
            my $rec = eval { JSON::PP->new->decode($1) };
            push @records, $rec if ref $rec eq 'HASH';
        }
        return undef;
    });
    return @records;
}

# Fence-aware search for a heading's LINE START offset (not locate_section's body
# start, which is after the heading line).
sub locate_heading_start {
    my ($B, $head_re) = @_;
    my $infence = 0;
    my $found;
    each_line_with_offset($B, 0, length($B), sub {
        my ($line, $off, $len, $has_nl) = @_;
        if (is_fence_line($line)) { $infence = !$infence; return undef }
        return undef if $infence;
        if ($line =~ /$head_re/) { $found = $off; return 1 }
        return undef;
    });
    return $found;
}

sub render_oracle_section {
    my (@lines) = @_;
    my $body = join('', map { $_ . "\n" } @lines);
    return "\n" . ORACLE_SECTION_HEADING . "\n\n"
         . "Machine-written by `bp-ledger.pl tick-step` at steps 3 and 5. One JSON record per line.\n"
         . "Never hand-edit: `bp-ledger.pl claim-check` reads these to verify the completion claim.\n\n"
         . $body . "\n";
}

sub insert_oracle_section {
    my ($B, @lines) = @_;
    my $section_text = render_oracle_section(@lines);
    my $pos = locate_heading_start($B, qr/^##\s+Decisions & attempt log\b/m);
    if (defined $pos) {
        return substr($B, 0, $pos) . substr($section_text, 1) . substr($B, $pos);
    }
    return $B . $section_text;
}

sub replace_oracle_section {
    my ($B, @lines) = @_;
    my $head_re = qr/^\Q@{[ORACLE_SECTION_HEADING]}\E\b/m;
    my $heading_start = locate_heading_start($B, $head_re);
    return insert_oracle_section($B, @lines) unless defined $heading_start;
    my $loc = locate_section($B, $head_re);
    return insert_oracle_section($B, @lines) unless $loc;
    my $section_text = render_oracle_section(@lines);
    return substr($B, 0, $heading_start) . substr($section_text, 1) . substr($B, $loc->{body_end});
}

sub insert_or_replace_oracle_section {
    my ($B, @lines) = @_;
    my $head_re = qr/^\Q@{[ORACLE_SECTION_HEADING]}\E\b/m;
    if (defined locate_heading_start($B, $head_re)) {
        return replace_oracle_section($B, @lines);
    }
    return insert_oracle_section($B, @lines);
}

# Merge @new_records (each already carrying step/path) into whatever the ledger
# currently has, replacing a (step,path) pair in place, keeping an unchanged record
# byte-stable (ignoring recorded_at) for idempotency (AC-6/AC-7), and rendering the
# whole section fresh via the canonical/ascii encoder (deterministic -> stable bytes).
sub merge_and_render_oracle_section {
    my ($B, @new_records) = @_;
    my @existing = parse_oracle_records($B);
    my %new_by_key = map { (($_->{step} // '') . '|' . ($_->{path} // '')) => $_ } @new_records;
    my %used;
    my @final;
    for my $rec (@existing) {
        my $key = ($rec->{step} // '') . '|' . ($rec->{path} // '');
        if (exists $new_by_key{$key} && !$used{$key}) {
            my $cand = $new_by_key{$key};
            push @final, oracle_records_equal_ignoring_time($rec, $cand) ? $rec : $cand;
            $used{$key} = 1;
        }
        else {
            push @final, $rec;
        }
    }
    for my $cand (@new_records) {
        my $key = ($cand->{step} // '') . '|' . ($cand->{path} // '');
        next if $used{$key};
        push @final, $cand;
        $used{$key} = 1;
    }
    my @lines = map { encode_oracle_record($_) } @final;
    return insert_or_replace_oracle_section($B, @lines);
}

# =====================================================================================
# Compact oracle records + sidecar (01-compact-oracle-records, bug 2c57).
# spec §2.3-2.5. Digest::SHA is loaded lazily, INSIDE this sub only (never at file
# scope -- completion-claim-integrity.t AC-33's file-scope module scan enforces this).
# =====================================================================================

sub _oracle_lazy_sha256_hex {
    my ($bytes) = @_;
    require Digest::SHA;
    return Digest::SHA::sha256_hex($bytes);
}

sub canonical_json_encode {
    my ($rec) = @_;
    return JSON::PP->new->canonical(1)->ascii(1)->encode($rec);
}

# spec §2.3: every character outside printable ASCII (0x20-0x7E) becomes "?", then
# truncate to the first ORACLE_REASON_MAX_CHARS characters.
sub sanitize_oracle_reason_compact {
    my ($s) = @_;
    return '' unless defined $s;
    (my $r = $s) =~ s/[^\x20-\x7E]/?/g;
    return substr($r, 0, ORACLE_REASON_MAX_CHARS);
}

# compact_oracle_record($full) -> \%compact. Pure, deterministic (spec §2.3). Never
# contains "descriptions" or "reaccept".
sub compact_oracle_record {
    my ($full) = @_;
    my %base = (
        v           => ORACLE_COMPACT_VERSION,
        recorded_at => $full->{recorded_at},
        status      => $full->{status},
    );
    # S5 (Decision 13 review ruling): never invent a field the input lacks -- an
    # undefined "step"/"assertions" must be OMITTED, not coerced to 0 via "+ 0" (which
    # also warns "Use of uninitialized value in addition" on stderr).
    $base{step} = $full->{step} + 0 if defined $full->{step};
    if (defined $base{status} && $base{status} eq 'ok') {
        $base{sha256}              = $full->{sha256}              if defined $full->{sha256};
        $base{assertions}          = $full->{assertions} + 0      if defined $full->{assertions};
        $base{descriptions_sha256} = $full->{descriptions_sha256} if defined $full->{descriptions_sha256};
    }
    else {
        $base{reason} = sanitize_oracle_reason_compact($full->{reason});
    }
    $base{reaccepted} = JSON::PP::true if exists $full->{reaccept};

    my %with_path = (%base, path => $full->{path});
    my $line = encode_oracle_record(\%with_path);
    return \%with_path if length($line) <= ORACLE_RECORD_MAX_BYTES;

    my %with_hash = (%base, path_sha256 => _oracle_lazy_sha256_hex($full->{path}));
    return \%with_hash;
}

# S4 (Decision 13 review ruling): true only for a genuine JSON NUMBER scalar (no POK
# flag) -- a JSON string "2" (or "2.0", "2abc", etc.) must never pass, even though it is
# numerically == 2.
sub is_json_number_scalar {
    my ($v) = @_;
    return 0 unless defined $v;
    return 0 if ref $v;
    my $f = B::svref_2object(\$v)->FLAGS;
    return 0 if $f & B::SVp_POK();
    return ($f & (B::SVp_IOK() | B::SVp_NOK())) ? 1 : 0;
}

# spec §2.2: a decoded "- oracle" object is compact iff it carries "v":2 as a JSON
# NUMBER (spec §2.2 / S4). Anything else -- no v, a string "v", or any other v value --
# is long form.
sub is_compact_record {
    my ($r) = @_;
    return 0 unless ref($r) eq 'HASH';
    return 0 unless exists $r->{v};
    my $v = $r->{v};
    return 0 unless is_json_number_scalar($v);
    no warnings 'numeric';
    return ($v == ORACLE_COMPACT_VERSION) ? 1 : 0;
}

# oracle_sidecar_path($ledger) -- pure (spec §2.4).
sub oracle_sidecar_path {
    my ($ledger) = @_;
    (my $p = $ledger) =~ s{\\}{/}g;
    # S1 (Decision 13 review ruling): the prefix before "packages/" is OPTIONAL and
    # defaults to "." (the addressed cwd) -- a bare "packages/x.md" and "./packages/x.md"
    # must resolve to the SAME sidecar a full ".../<bp>/packages/x.md" resolves to.
    if ($p =~ m{^(?:(.*)/)?packages/([^/]+)\.md$}) {
        my $dir = (defined($1) && length($1)) ? $1 : '.';
        return "$dir/oracle/$2.jsonl";
    }
    my ($dir, $base);
    if ($p =~ m{^(.*)/([^/]+)$}) { ($dir, $base) = ($1, $2) }
    else                          { ($dir, $base) = ('.', $p) }
    $base =~ s/\.md$//;
    return "$dir/oracle/$base.jsonl";
}

# Read the sidecar JSONL: one full record per line. Missing file -> (). Empty or
# non-decoding lines are skipped (spec §2.4).
sub read_sidecar_entries {
    my ($path) = @_;
    return () unless -e $path;
    open(my $fh, '<:raw', $path) or return ();
    local $/;
    my $bytes = <$fh>;
    close $fh;
    $bytes = '' unless defined $bytes;
    my @out;
    for my $line (split(/\n/, $bytes, -1)) {
        next unless length $line;
        my $d = eval { JSON::PP->new->decode($line) };
        push @out, $d if ref($d) eq 'HASH';
    }
    return @out;
}

# render_sidecar_bytes(@entries) -- one full record per line, canonical/ascii encoder,
# each line ending in "\n" (spec §2.4). No prefix, no header.
sub render_sidecar_bytes {
    my (@entries) = @_;
    return join('', map { canonical_json_encode($_) . "\n" } @entries);
}

# write_oracle_sidecar($path, @entries) -> 1 (written or already correct) | 0 (failed).
# Atomic (tmp + $RENAME_FN), parent dir via ensure_dir_exists, written only when the
# new content differs from what's on disk, never created empty (spec §2.4).
sub write_oracle_sidecar {
    my ($path, @entries) = @_;
    my $new_bytes = render_sidecar_bytes(@entries);
    my $exists = -e $path;
    return 1 if !@entries && !$exists;

    if ($exists) {
        open(my $fh, '<:raw', $path) or return 0;
        local $/;
        my $old_bytes = <$fh>;
        close $fh;
        $old_bytes = '' unless defined $old_bytes;
        return 1 if $old_bytes eq $new_bytes;
    }

    my $dir = $path;
    $dir =~ s{/[^/]+$}{};
    ensure_dir_exists($dir) or return 0;

    my $tmp = "$path.tmp.$$";
    open(my $w, '>:raw', $tmp) or return 0;
    print {$w} $new_bytes or do { close $w; unlink $tmp; return 0 };
    close($w) or do { unlink $tmp; return 0 };
    unless ($RENAME_FN->($tmp, $path)) { unlink $tmp; return 0 }
    return 1;
}

# build_sidecar_index(@sidecar_entries) -> \%index, encoded-compact-json => full record
# (first entry wins for a given key -- spec's matching rule is content equality, so a
# later duplicate is indistinguishable from the first anyway).
sub build_sidecar_index {
    my (@sidecar_entries) = @_;
    my %index;
    for my $s (@sidecar_entries) {
        my $cand = eval { compact_oracle_record($s) };
        next unless $cand;
        my $enc = canonical_json_encode($cand);
        $index{$enc} = $s unless exists $index{$enc};
    }
    return \%index;
}

# hydrate_one_oracle_record($r, \%sidecar_index, \@test_paths) -> ($full|undef, $degraded).
# Long-form $r: ($r, 0). Compact $r with a backing entry: ($entry, 0). Compact $r with
# none: degraded reconstruction (spec §2.5), or (undef, 1) if path_sha256 can't be
# resolved against @test_paths ("no usable key").
sub hydrate_one_oracle_record {
    my ($r, $sidecar_index, $test_paths) = @_;
    return ($r, 0) unless is_compact_record($r);

    my $enc = canonical_json_encode($r);
    return ($sidecar_index->{$enc}, 0) if exists $sidecar_index->{$enc};

    my %full = %$r;
    delete $full{v};
    if (delete $full{reaccepted}) { $full{reaccept} = {} }
    if (exists $full{path_sha256}) {
        my $hash = delete $full{path_sha256};
        my $matched;
        for my $tp (@$test_paths) {
            if (_oracle_lazy_sha256_hex($tp) eq $hash) { $matched = $tp; last }
        }
        return (undef, 1) unless defined $matched;
        $full{path} = $matched;
    }
    return (\%full, 1);
}

# hydrate_oracle_records(\@raw, \@sidecar_entries, \@test_paths) -> a list of
# { raw, full, degraded } (spec §2.5), one per raw record IN ORDER, except that a
# compact record whose path_sha256 resolves against no @test_paths segment is dropped
# entirely (it has no usable key).
sub hydrate_oracle_records {
    my ($raw, $sidecar_entries, $test_paths) = @_;
    my $index = build_sidecar_index(@$sidecar_entries);
    my @out;
    for my $r (@$raw) {
        my ($full, $degraded) = hydrate_one_oracle_record($r, $index, $test_paths);
        next unless defined $full;
        push @out, { raw => $r, full => $full, degraded => $degraded };
    }
    return @out;
}

# build_sidecar_retention(%p) -> a list of full records to write to the sidecar
# (spec §2.4's retention rule): (a) one backing entry for every compact record in the
# NEW ledger section that has one available, in section order; then (b) every existing
# entry that backed a compact line in the OLD (on-disk) section, in the OLD sidecar's
# own file order. Identical entries are written once (first occurrence wins).
sub build_sidecar_retention {
    my (%p) = @_;
    my $new_records = $p{new_records};
    my $new_backing = $p{new_backing} || {};
    my $old_bytes   = $p{old_bytes};
    my $old_sidecar = $p{old_sidecar} || [];

    my %old_backing_by_enc;
    my @old_order;
    for my $s (@$old_sidecar) {
        my $cand = eval { compact_oracle_record($s) };
        next unless $cand;
        my $enc = canonical_json_encode($cand);
        unless (exists $old_backing_by_enc{$enc}) {
            $old_backing_by_enc{$enc} = $s;
            push @old_order, $enc;
        }
    }

    my (@a_list, %seen);
    for my $rec (@$new_records) {
        next unless is_compact_record($rec);
        my $enc = canonical_json_encode($rec);
        next if $seen{$enc};
        my $backing = $new_backing->{$enc};
        $backing = $old_backing_by_enc{$enc} unless defined $backing;
        next unless defined $backing;
        push @a_list, $backing;
        $seen{$enc} = 1;
    }

    my %needed_b;
    if (defined $old_bytes) {
        for my $orec (parse_oracle_records($old_bytes)) {
            next unless is_compact_record($orec);
            my $enc = canonical_json_encode($orec);
            $needed_b{$enc} = 1 if exists $old_backing_by_enc{$enc};
        }
    }
    my @b_list;
    for my $enc (@old_order) {
        next unless $needed_b{$enc};
        next if $seen{$enc};
        push @b_list, $old_backing_by_enc{$enc};
        $seen{$enc} = 1;
    }

    return (@a_list, @b_list);
}

# compact_or_fallback($cand) -- the per-record defensive rule (spec §2.3): if the
# compact line would still exceed the cap (never happens for assertions below 10^10),
# write that ONE record in long form instead.
sub compact_or_fallback {
    my ($cand) = @_;
    my $compact = compact_oracle_record($cand);
    my $line_len = length(encode_oracle_record($compact));
    return $line_len <= ORACLE_RECORD_MAX_BYTES ? $compact : $cand;
}

# Both legal frontmatter forms (colon-delimited scalar AND the YAML-ish list), mirroring
# the existing $field_segments closure inside validate_bytes (spec §2.9).
sub ledger_field_segments {
    my ($B, $field) = @_;
    return () unless $B =~ /\A---\s*\n(.*?)\n---/s;
    my @FML = split(/\n/, $1, -1);
    my ($i, $scalar) = (-1, undef);
    for my $n (0 .. $#FML) {
        if ($FML[$n] =~ /^\Q$field\E:\s*(.*?)\s*$/) { $i = $n; $scalar = $1; last }
    }
    return () if $i < 0;
    my @items;
    for my $n ($i + 1 .. $#FML) {
        last unless $FML[$n] =~ /^\s+-\s*(.*?)\s*$/;
        push @items, $1 if length $1;
    }
    my @segs;
    push @segs, split(/:/, $scalar, -1) if defined $scalar && length $scalar;
    push @segs, @items;
    return @segs;
}

# An oracle path is a test_paths segment ending in ".t" (spec §2.9). Scope-prefix
# segments (e.g. "t/") are skipped entirely.
sub ledger_test_paths {
    my ($B) = @_;
    return grep { length($_) && /\.t\z/ } ledger_field_segments($B, 'test_paths');
}

# Pipeline satisfaction rules (spec §2.8), scoped to ## Pipeline via locate_section /
# is_fence_line so a fenced lookalike never counts. Conditionality is decided by step
# NUMBER, never by prose.
sub ledger_pipeline_items {
    my ($B) = @_;
    my $loc = locate_section($B, qr/^##\s+Pipeline\b/m);
    return () unless $loc;
    my $item_re = qr/^\s*-\s*\[([ xX])\]\s*(\d+)\.\s*(.*?)\s*$/;
    my @items;
    my $infence = 0;
    each_line_with_offset($B, $loc->{body_start}, $loc->{body_end}, sub {
        my ($line, $off, $len, $has_nl) = @_;
        if (is_fence_line($line)) { $infence = !$infence; return undef }
        return undef if $infence;
        if ($line =~ $item_re) {
            my ($box, $n, $text) = ($1, $2 + 0, $3);
            my $ticked      = ($box eq 'x' || $box eq 'X') ? 1 : 0;
            my $conditional = (grep { $_ == $n } @PIPELINE_CONDITIONAL_STEPS) ? 1 : 0;
            my $na          = ($text =~ /(?<![A-Za-z0-9])N\/A(?![A-Za-z0-9])/i) ? 1 : 0;
            my $satisfied   = ($ticked || ($conditional && $na)) ? 1 : 0;
            push @items, { step => $n, ticked => $ticked, conditional => $conditional,
                           na => $na, satisfied => $satisfied, text => $text };
        }
        return undef;
    });
    return @items;
}

# =====================================================================================
# The shared five-op algorithm (spec §2.3, steps 1..10).
# =====================================================================================

# _run_op_lock($lk, $sub, $path, $lockpath) -- takes run_op's exclusive lock.
# Blocking by default, exactly as before. BP_LEDGER_LOCK_TIMEOUT=<seconds>
# (positive integer) opts a caller into a BOUNDED wait instead: on expiry it
# exits through io_error (exit 4) with a message starting "lock-timeout:", so
# a caller that must never wedge on a stuck holder can tell this apart from
# any other I/O failure. bp-answer-escalation.pl sets it (todo
# 20261002-153740-41890000): that script runs synchronously inside the
# orchestrator's tick loop, and a blocking wait here froze the whole fleet,
# token keeper included. Coordinators never set it, so their ops still wait
# for the lock however long it is held.
sub _run_op_lock {
    my ($lk, $sub, $path, $lockpath) = @_;
    my $t = $ENV{BP_LEDGER_LOCK_TIMEOUT};
    unless (defined $t && $t =~ /\A\d+\z/ && $t > 0) {
        flock($lk, LOCK_EX) or io_error($sub, $path, "cannot acquire lock on $lockpath: $!");
        return;
    }
    my $deadline = time + $t;
    until (flock($lk, LOCK_EX | LOCK_NB)) {
        if (time >= $deadline) {
            close $lk;
            io_error($sub, $path, "lock-timeout: could not acquire $lockpath within ${t}s");
        }
        select(undef, undef, undef, 0.05);
    }
    return;
}

sub run_op {
    my ($sub, $path, $splice_cb, $post_cb) = @_;

    my $lockpath = "$path.lock";
    open(my $lk, '>', $lockpath) or io_error($sub, $path, "cannot open lock file $lockpath: $!");
    _run_op_lock($lk, $sub, $path, $lockpath);

    my $orig;
    {
        open(my $fh, '<:raw', $path) or io_error($sub, $path, "cannot read: $!");
        local $/;
        $orig = <$fh>;
        close $fh;
        $orig = '' unless defined $orig;
    }

    my $detail = validate_bytes($orig);
    reject_error($sub, $path, $detail) if defined $detail;

    my ($new, $notfound) = $splice_cb->($orig);
    notfound_error($sub, $path, $notfound) unless defined $new;

    my $detail2 = validate_bytes($new);
    reject_error($sub, $path, $detail2) if defined $detail2;

    my $ref_detail = validate_no_new_ref_addr($orig, $new);
    reject_error($sub, $path, $ref_detail) if defined $ref_detail;

    my $lu_detail = last_updated_check($orig, $new);
    reject_error($sub, $path, $lu_detail) if defined $lu_detail;

    if ($new eq $orig) { $post_cb->($new) if $post_cb; exit 0 }

    my $tmp = "$path.tmp.$$";
    open(my $w, '>:raw', $tmp) or io_error($sub, $path, "cannot open temp file $tmp: $!");
    print {$w} $new or do { close $w; unlink $tmp; io_error($sub, $path, "write to $tmp failed: $!") };
    close($w) or do { unlink $tmp; io_error($sub, $path, "close $tmp failed: $!") };

    unless ($RENAME_FN->($tmp, $path)) {
        unlink $tmp;
        io_error($sub, $path, "rename $tmp -> $path failed: $!");
    }

    # a01 §7 / behavior 33: the read-back is not optional even in the house
    # precedent -- still under the lock, still routed through the EXISTING
    # io_error/exit-4 path (no new exit-code vocabulary, per spec §6 "Changing
    # run_op's exit-code vocabulary ... is out of scope"). A rename that reports
    # success but whose bytes don't read back is exactly the DROP shape this
    # package exists to close.
    my $after;
    {
        open(my $rfh, '<:raw', $path) or io_error($sub, $path, "read-back: cannot read: $!");
        local $/;
        $after = <$rfh>;
        close $rfh;
        $after = '' unless defined $after;
    }
    unless ($after eq $new) {
        io_error($sub, $path, "value did not survive the write");
    }

    # a03-ledger-budget-irreducible spec: $post_cb (the budget-marker read/mutate) must
    # run under the SAME lock discipline on every path through run_op -- the no-op path
    # above already calls it before releasing the lock (it never explicitly unlocks;
    # process exit does that). Calling it here, before flock(LOCK_UN), keeps this path
    # consistent with that one and with op_rotate's own $finalize_budget_state (always
    # called before its flock(LOCK_UN)) -- all three marker-mutation sites now agree.
    # Reviewer step6 MAJOR / red-team MINOR-2: previously this ran AFTER the unlock,
    # opening a race window against a concurrent invocation on the same lockfile.
    $post_cb->($new) if $post_cb;
    flock($lk, LOCK_UN);
    close($lk);
    exit 0;
}

# =====================================================================================
# Free-text argument acquisition: --text/--body (inline, '-' means stdin),
# --text-file/--body-file (raw file read). Exactly one source.
# =====================================================================================

sub get_freetext_arg {
    my (%p) = @_;
    my ($sub, $opt, $primary, $filekey) = @p{qw(sub opt primary filekey)};
    my $has_inline = defined $opt->{$primary};
    my $has_file   = defined $opt->{$filekey};
    if ($has_inline && $has_file) {
        arg_error($sub, "specify exactly one of --$primary or --$filekey, not both");
    }
    if (!$has_inline && !$has_file) {
        arg_error($sub, "missing required --$primary (or --$filekey, or --$primary -  for stdin)");
    }
    if ($has_file) {
        my $path = $opt->{$filekey};
        open(my $fh, '<:raw', $path) or arg_error($sub, "cannot read --$filekey $path: $!");
        local $/;
        my $c = <$fh>;
        close $fh;
        return defined $c ? $c : '';
    }
    my $v = $opt->{$primary};
    if ($v eq '-') {
        binmode STDIN;
        local $/;
        my $c = <STDIN>;
        return defined $c ? $c : '';
    }
    return $v;
}

# =====================================================================================
# Op handlers.
# =====================================================================================

sub op_set_status {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { }; $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'status=s'); }
    arg_error('set-status', 'unrecognised option') unless $ok;
    arg_error('set-status', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('set-status', 'missing required --ledger') unless defined $opt{ledger};
    arg_error('set-status', 'missing required --status') unless defined $opt{status};
    unless (grep { $_ eq $opt{status} } @STATUSES) {
        arg_error('set-status',
            "'$opt{status}' is not a recognised status; allowed values: " . join(', ', @STATUSES));
    }
    my $iso = iso_now();
    run_op('set-status', $opt{ledger}, sub { return splice_set_status($_[0], $opt{status}, $iso) });
}

sub op_append_attempt {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'text=s', 'text-file=s'); }
    arg_error('append-attempt', 'unrecognised option') unless $ok;
    arg_error('append-attempt', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('append-attempt', 'missing required --ledger') unless defined $opt{ledger};
    my $text = get_freetext_arg(sub => 'append-attempt', opt => \%opt, primary => 'text', filekey => 'text-file');
    $text =~ s/[\r\n]+/ /g;
    my $iso   = iso_now();
    my $entry = "- ${iso} ${EMDASH} ${text}";
    # b45 §4: visibility, never a refusal. The append has already happened (or is a
    # no-op) by the time this fires; we only ever warn, never block.
    my $budget_check = sub {
        my ($bytes) = @_;
        my $size = length($bytes);
        if ($size <= DEFAULT_BUDGET_BYTES) {
            # Genuinely back under budget: any prior suppression is stale now, and any
            # prior "reducible" notice state is moot -- clear the marker so the NEXT
            # over-budget encounter (whatever it turns out to be) starts fresh (spec
            # §2.1's own bullet on staleness).
            clear_budget_marker($opt{ledger});
            return;
        }
        my $marker = read_budget_marker($opt{ledger});
        if ($marker && $marker->{state} eq 'irreducible') {
            # A rotate already determined this ledger cannot be reduced further.
            # Say it once (the marker's own "notified" flag), not on every append --
            # but only while that "notified" claim is still within its trust window
            # (red-team step6 MAJOR-1). A forged or stale marker falls through here and
            # re-notifies rather than staying silent forever.
            return if $marker->{flag} eq 'notified' && budget_marker_fresh($marker->{ts});
            emit_notice('append-attempt', 'LEDGER_IRREDUCIBLE',
                "$opt{ledger} is $size bytes, over the " . DEFAULT_BUDGET_BYTES
                . '-byte budget; a prior rotate already determined this ledger cannot be reduced '
                . 'further -- see that rotate run for the diagnosis. Not repeated on subsequent appends.');
            mark_irreducible_notified($opt{ledger});
            return;
        }
        # b45 §4: visibility, never a refusal. The append has already happened (or is a
        # no-op) by the time this fires; we only ever notify, never block.
        emit_notice('append-attempt', 'BUDGET_OVER',
            "$opt{ledger} is $size bytes, exceeding the " . DEFAULT_BUDGET_BYTES
            . "-byte budget; run: bp-ledger.pl rotate --ledger $opt{ledger}");
    };
    run_op('append-attempt', $opt{ledger},
        sub { return splice_insert_entry($_[0], qr/^##\s+Decisions & attempt log\b/m, $entry) },
        $budget_check);
}

# Recompute a delta between a step-3 and step-5 record (both must exist and be
# considered), for the `reaccept` object the caller's --reaccept-oracle names (spec
# §2.4) as well as for claim-check's own report (spec §2.6/§2.7). Booleans use
# JSON::PP::true/false so they encode as JSON booleans, not 0/1.
sub oracle_delta {
    my ($step3, $step5) = @_;
    my $before = ($step3 && $step3->{status} eq 'ok') ? $step3->{assertions} + 0 : undef;
    my $after  = ($step5 && $step5->{status} eq 'ok') ? $step5->{assertions} + 0 : undef;
    my $comparable = ($step3 && $step5 && exists $step3->{descriptions} && exists $step5->{descriptions}) ? 1 : 0;
    my (@added, @removed);
    if ($comparable) {
        # Comparison is always by NORMALIZED description (spec §2.3/AC-25/AC-26):
        # a stored record's descriptions may themselves be un-normalized (e.g. a
        # hand-authored fixture record), so normalize here defensively -- idempotent
        # against an already-normalized live derivation.
        my %s3 = map { (normalize_description($_) => 1) } @{ $step3->{descriptions} || [] };
        my %s5 = map { (normalize_description($_) => 1) } @{ $step5->{descriptions} || [] };
        delete $s3{''}; delete $s5{''};
        @added   = sort grep { !$s3{$_} } keys %s5;
        @removed = sort grep { !$s5{$_} } keys %s3;
    }
    return {
        assertions_before      => $before,
        assertions_after       => $after,
        descriptions_added     => \@added,
        descriptions_removed   => \@removed,
        descriptions_comparable=> $comparable ? JSON::PP::true : JSON::PP::false,
    };
}

sub op_tick_step {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'step=s',
                                 'reaccept-oracle=s@', 'reaccept-reason=s'); }
    arg_error('tick-step', 'unrecognised option') unless $ok;
    arg_error('tick-step', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('tick-step', 'missing required --ledger') unless defined $opt{ledger};
    arg_error('tick-step', 'missing required --step') unless defined $opt{step};
    unless ($opt{step} =~ /^[1-9][0-9]*$/) {
        arg_error('tick-step', "'--step $opt{step}' is not a positive integer without a leading zero");
    }
    my @reaccept_paths = @{ $opt{'reaccept-oracle'} || [] };
    if (@reaccept_paths && $opt{step} != 5) {
        arg_error('tick-step', '--reaccept-oracle is only valid with --step 5');
    }
    if (@reaccept_paths && !defined $opt{'reaccept-reason'}) {
        arg_error('tick-step', '--reaccept-oracle requires --reaccept-reason');
    }
    if (!@reaccept_paths && defined $opt{'reaccept-reason'}) {
        arg_error('tick-step', '--reaccept-reason requires at least one --reaccept-oracle');
    }

    # Set inside the splice callback below when the sidecar write fails (Decision 11):
    # printed by the $post_cb, under the same lock discipline append-attempt's own
    # budget notice uses, so it can never race a concurrent invocation.
    my $sidecar_warn;
    # Step-5 oracle changes that were NOT reaccepted. Advisory only (the
    # fail-silent mandate: recording never subtracts availability), printed
    # after the write. Nothing coordinator-facing documented --reaccept-oracle,
    # so coordinators learned of it only from a failed harvest audit, one
    # corrective round per package (where-things-go/10 and /11,
    # judged-continuity-disarm/01 and /06, 2026-10-22/23).
    my @drift_notices;

    run_op('tick-step', $opt{ledger}, sub {
        my ($B) = @_;
        my ($ticked, $notfound) = splice_tick_step($B, $opt{step});
        return (undef, $notfound) unless defined $ticked;

        # Fail-silent mandate (spec §5): recording may never subtract availability.
        # Any exception/undef/validation failure anywhere below -> plain tick only.
        my $step_n = $opt{step} + 0;
        return ($ticked, undef)
            if defined $ENV{BP_ORACLE_RECORD} && $ENV{BP_ORACLE_RECORD} eq '0';
        return ($ticked, undef) unless grep { $_ == $step_n } @ORACLE_RECORDED_STEPS;

        my $final = eval {
            local $SIG{__DIE__} = sub { };
            local $SIG{__WARN__} = sub { };
            my @paths = ledger_test_paths($B);
            return $ticked unless @paths;

            my $now = iso_now();
            my %reaccept_wanted = map { ($_ => 1) } @reaccept_paths;
            my $sidecar_path = oracle_sidecar_path($opt{ledger});
            my @old_sidecar  = read_sidecar_entries($sidecar_path);
            my $sidecar_index = build_sidecar_index(@old_sidecar);
            my @raw_existing = parse_oracle_records($B);

            my %step3_by_path;
            for my $r (@raw_existing) {
                my ($full) = hydrate_one_oracle_record($r, $sidecar_index, \@paths);
                next unless defined $full && defined $full->{step} && $full->{step} == 3;
                $step3_by_path{ $full->{path} } = $full if defined $full->{path};
            }

            my @candidates;
            for my $path (@paths) {
                my $identity = derive_oracle_identity($path);
                my %args = (step => $step_n, path => $path, recorded_at => $now, identity => $identity);
                if ($step_n == 5 && $reaccept_wanted{$path}) {
                    my $step3 = $step3_by_path{$path};
                    my $delta = oracle_delta($step3, $identity);
                    $args{reaccept} = { reason => $opt{'reaccept-reason'}, delta => $delta };
                }
                elsif ($step_n == 5 && $step3_by_path{$path}) {
                    my $n = _oracle_change_notice($path, $step3_by_path{$path}, $identity);
                    push @drift_notices, $n if defined $n;
                }
                push @candidates, build_oracle_record(%args);
            }
            my %cand_by_key = map { (($_->{step} // '') . '|' . ($_->{path} // '')) => $_ } @candidates;

            # Merge (spec §2.6 step 4), keyed by (step, path) taken from the HYDRATED
            # full record. $render_fn decides how a replaced/new candidate is rendered
            # (compact-with-per-record-fallback, or forced long form).
            my $do_merge = sub {
                my ($render_fn) = @_;
                my (@final, %used, %new_backing);
                for my $r (@raw_existing) {
                    my ($full, $degraded) = hydrate_one_oracle_record($r, $sidecar_index, \@paths);
                    my $key = (defined $full && defined $full->{path})
                        ? (($full->{step} // '') . '|' . $full->{path}) : undef;
                    if (defined $key && exists $cand_by_key{$key} && !$used{$key}) {
                        my $cand = $cand_by_key{$key};
                        if (!$degraded && oracle_records_equal_ignoring_time($full, $cand)) {
                            push @final, $r;
                        }
                        else {
                            my $rendered = $render_fn->($cand);
                            push @final, $rendered;
                            $new_backing{ canonical_json_encode($rendered) } = $cand if is_compact_record($rendered);
                        }
                        $used{$key} = 1;
                    }
                    else {
                        push @final, $r;
                    }
                }
                for my $cand (@candidates) {
                    my $key = ($cand->{step} // '') . '|' . ($cand->{path} // '');
                    next if $used{$key};
                    my $rendered = $render_fn->($cand);
                    push @final, $rendered;
                    $new_backing{ canonical_json_encode($rendered) } = $cand if is_compact_record($rendered);
                    $used{$key} = 1;
                }
                return (\@final, \%new_backing);
            };

            my ($final_records, $new_backing) = $do_merge->(\&compact_or_fallback);
            my @lines = map { encode_oracle_record($_) } @$final_records;
            my $merged = insert_or_replace_oracle_section($ticked, @lines);

            # Self-validate BEFORE returning: never let run_op's own re-validation
            # be the thing that discovers a problem (that path exits 2, forbidden here).
            return $ticked if defined validate_bytes($merged);
            return $ticked if defined validate_no_new_ref_addr($B, $merged);

            my @retention = build_sidecar_retention(
                new_records => $final_records, new_backing => $new_backing,
                old_bytes   => $B,             old_sidecar => \@old_sidecar);

            if (write_oracle_sidecar($sidecar_path, @retention)) {
                return $merged;
            }

            # Decision 11 fallback: the sidecar could not be written -- render every
            # candidate this tick touches in LONG FORM instead, leave the sidecar file
            # untouched, and warn (exactly once) via $post_cb below.
            my ($long_records, undef) = $do_merge->(sub { return $_[0] });
            my @long_lines = map { encode_oracle_record($_) } @$long_records;
            my $long_merged = insert_or_replace_oracle_section($ticked, @long_lines);
            return $ticked if defined validate_bytes($long_merged);
            return $ticked if defined validate_no_new_ref_addr($B, $long_merged);

            $sidecar_warn = "bp-ledger: tick-step: $opt{ledger}: could not write oracle sidecar "
                . "($sidecar_path); recorded oracle data in long form instead";
            return $long_merged;
        };
        $final = $ticked if $@ || !defined $final;
        return ($final, undef);
    }, sub {
        print STDERR $sidecar_warn . "\n" if defined $sidecar_warn;
        print STDERR "bp-ledger: tick-step 5: $_\n" for @drift_notices;
    });
}

# _oracle_change_notice($path, $step3, $identity) -> $text | undef. Mirrors
# claim-check's own classification (op_claim_check): a vanished description
# or fewer assertions is a shrink, which no reaccept clears; any other
# difference is drift, which --reaccept-oracle records.
sub _oracle_change_notice {
    my ($path, $r3, $id) = @_;
    return undef unless ref $r3 eq 'HASH' && ref $id eq 'HASH';
    return undef unless ($r3->{status} // '') eq 'ok' && ($id->{status} // '') eq 'ok';
    my $delta = oracle_delta($r3, $id);
    my $comparable = (exists $r3->{descriptions} && exists $id->{descriptions}) ? 1 : 0;
    my @added   = $comparable ? @{ $delta->{descriptions_added} }   : ();
    my @removed = $comparable ? @{ $delta->{descriptions_removed} } : ();
    my $a3 = $r3->{assertions} // 0;
    my $a5 = $id->{assertions} // 0;
    if ($a5 < $a3 || @removed) {
        return "$path: the oracle SHRANK since step 3 (assertions $a3 -> $a5, "
             . scalar(@removed) . " description(s) gone). claim-check will gate this package and a reaccept "
             . "does not clear a shrink: restore the vanished assertions (a renamed description counts as "
             . "vanished), then tick step 5 again.";
    }
    my $desc_changed = $comparable ? scalar(@added) : (($r3->{descriptions_sha256} // '') ne ($id->{descriptions_sha256} // ''));
    my $changed = $desc_changed || $a3 != $a5 || (($r3->{sha256} // '') ne ($id->{sha256} // ''));
    return undef unless $changed;
    return "$path: the oracle changed since step 3 (assertions $a3 -> $a5) without a reaccept; claim-check "
         . "will gate this package at harvest. If the change is intended, tick step 5 again with "
         . "--reaccept-oracle $path --reaccept-reason '<why>'.";
}

sub op_set_next_action {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'body=s', 'body-file=s'); }
    arg_error('set-next-action', 'unrecognised option') unless $ok;
    arg_error('set-next-action', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('set-next-action', 'missing required --ledger') unless defined $opt{ledger};
    my $body = get_freetext_arg(sub => 'set-next-action', opt => \%opt, primary => 'body', filekey => 'body-file');
    $body =~ s/\s+\z//;
    if ($body eq '') {
        arg_error('set-next-action',
            'the --body is empty after stripping trailing whitespace; set-next-action requires non-empty content');
    }
    my @lines = split(/\n/, $body, -1);
    my $first = $lines[0];
    if ($first eq '' || $first =~ /^#/) {
        arg_error('set-next-action',
            "the first line of --body must be non-blank and must not begin with '#': bp-status.sh renders the "
          . "first non-blank line as the human-facing summary while stop-gate.sh additionally skips '#'-leading "
          . "lines, so the two readers would disagree about what the next action is");
    }
    if (grep { /^\s*-\s*\[[xX]\]/ } @lines) {
        arg_error('set-next-action',
            "the --body must not contain a line matching '- [x]' (would forge the orchestrator's ledger_checkboxes "
          . 'progress signal)');
    }
    run_op('set-next-action', $opt{ledger}, sub { return splice_set_next_action($_[0], $body) });
}

# =====================================================================================
# `widen-write-set` -- ADD paths to a package ledger's write_set, and only when a
# blueprint Decision names each one. This is how a Decision 29 re-scope reaches the
# contract the write-guards enforce. Before this verb, a recorded re-scope had no typed
# path into the ledger: guard-blueprint-write.sh rightly refuses a hand edit, and
# bp-answer-decision.pl's --widen-write-set is reachable only through the fleet's
# decision queue, whose direct --package actions all change the package's status.
#
# Additive only, like bp-answer-decision.pl's widening: narrowing or replacing a
# write_set is not a supported move (it could strand work already done under the old
# scope). The Decision requirement keeps this from being a free "widen my own scope"
# lever: the path must appear verbatim in a Decision row of the blueprint.md two
# directories above the ledger, which is itself written only through bp-blueprint.pl.
# The widening and its attempt-log line are one atomic splice under the ledger lock.
# =====================================================================================

sub _widen_path_error {
    my ($p) = @_;
    return 'an empty path'                         if $p eq '';
    return "'$p' is absolute; repo-relative only"   if $p =~ m{\A(?:/|[A-Za-z]:(?:[\\/]|\z))};
    return "'$p' contains ':', a pipe or a newline" if $p =~ /[:|\r\n]/;
    return "'$p' contains '..'"                     if $p =~ m{(?:\A|/)\.\.(?:/|\z)};
    return "'$p' is a pure wildcard or project-root scope"
        if $p =~ m{\A(?:\*+|\*\*/\*|\.|\./)\z};
    return undef;
}

# _decision_text($blueprint_bytes, $id) -> the Decision row's text, or undef.
sub _decision_text {
    my ($B, $id) = @_;
    for my $line (split /\n/, $B) {
        return $1 if $line =~ /^\|\s*\Q$id\E\s*\|(.*)\|\s*[^|]*\|\s*[^|]*\|\s*$/;
    }
    return undef;
}

# =====================================================================================
# F5 (red-team M1 + L5, package 16 fix-batch): a widening must not make this
# package's write set overlap another IN-FLIGHT package's write set
# (.drive-solo/inflight.json) -- with the switch gone, two or more packages
# are routinely in flight together, and nothing else re-checks this once a
# widening happens after hand-out. The overlap test folds ASCII case on a
# case-insensitive host, same rule BpHook::WriteGuards/BindDispatch use
# (auto-detect from $^O; no override needed here since bp-ledger.pl is a
# standalone CLI, never require'd alongside those modules).
# =====================================================================================

sub _widen_ws_is_ci {
    return ($^O =~ /\A(?:msys|MSWin32|cygwin|darwin)\z/) ? 1 : 0;
}

sub _widen_ws_fold {
    my ($s) = @_;
    return $s unless _widen_ws_is_ci();
    (my $v = $s) =~ tr/A-Z/a-z/;
    return $v;
}

# _widen_ws_prefixes(\@paths) -- same shape as bp-drive-next.pl's own
# BpDrive::_ws_prefixes: cut at the first glob, drop a trailing slash.
sub _widen_ws_prefixes {
    my ($paths) = @_;
    my @out;
    for my $p (@$paths) {
        next unless defined $p && length $p;
        (my $q = $p) =~ s{\*.*$}{};
        $q =~ s{/+$}{};
        push @out, $q;
    }
    return @out;
}

sub _widen_prefix_related {
    my ($a, $b) = @_;
    $a = _widen_ws_fold($a);
    $b = _widen_ws_fold($b);
    return 1 if $a eq $b;
    return 1 if $a eq '' || $b eq '';       # empty prefix matches anything (Landmine #4)
    return 1 if index("$b/", "$a/") == 0;   # a is ancestor dir of b
    return 1 if index("$a/", "$b/") == 0;   # b is ancestor dir of a
    return 0;
}

# _byteify($s) -> raw UTF-8 bytes (never re-encoded if already bytes). See
# Almanac::PackageLink::_byteify for the full rationale: a decoded (utf8-
# flagged) string concatenated with a raw-bytes string silently corrupts
# non-ASCII bytes under Perl's mismatched-encoding upgrade rules. See also
# `as_bytes` (~2946): that helper downgrades first and encodes only as a
# fallback, which matters when the source already holds raw bytes that were
# merely upgraded (not characters) -- `_widen_check_inflight_conflict` tries
# both interpretations and keeps whichever one resolves to a real file.
sub _byteify {
    my ($s) = @_;
    return $s unless defined $s;
    my $copy = $s;
    utf8::encode($copy) if utf8::is_utf8($copy);
    return $copy;
}

# _widen_valid_name($s) -- same grammar bp-drive-next.pl's own `_valid_name`
# uses for an inflight.json entry's blueprint/package names (spec Sec2.2).
# Keeping entries to this grammar also rules out path traversal when we
# build a filesystem path out of them below.
sub _widen_valid_name {
    my ($s) = @_;
    return (defined $s && !ref $s && $s =~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/) ? 1 : 0;
}

# _widen_check_inflight_conflict($ledger, \@new_paths) -> "$bp/$pkg" | undef.
# Reads .drive-solo/inflight.json alongside $ledger's own data dir (4 levels
# up: packages/ -> <bp>/ -> blueprints/ -> data). Any failure to resolve or
# read is treated as "no conflict" (fail open -- this is an additive safety
# check, not the widen op's own I/O path).
sub _widen_check_inflight_conflict {
    my ($ledger, $new_paths) = @_;

    my $pkg_dir        = op_create_dirname($ledger);
    my $bp_dir         = op_create_dirname($pkg_dir);
    my $blueprints_dir = op_create_dirname($bp_dir);
    my $data_dir       = op_create_dirname($blueprints_dir);
    return undef unless length $data_dir;

    my $inflight_path = "$data_dir/.drive-solo/inflight.json";
    return undef unless -f $inflight_path;

    my $raw = do {
        open(my $fh, '<:raw', $inflight_path) or return undef;
        local $/;
        my $c = <$fh>;
        close $fh;
        $c;
    };
    return undef unless defined $raw && length $raw;
    my $data = eval { JSON::PP->new->utf8->decode($raw) };
    return undef unless ref $data eq 'HASH' && ref $data->{packages} eq 'ARRAY';

    (my $own_bp  = $bp_dir) =~ s{.*[\\/]}{};
    (my $own_pkg = $ledger) =~ s{.*[\\/]}{};
    $own_pkg =~ s{\.md\z}{};

    my @new_prefixes = _widen_ws_prefixes($new_paths);

    for my $e (@{ $data->{packages} }) {
        next unless ref $e eq 'HASH';
        my $obp  = $e->{blueprint};
        my $opkg = $e->{package};
        next unless defined $obp && !ref($obp) && defined $opkg && !ref($opkg);
        next if $obp eq $own_bp && $opkg eq $own_pkg; # never conflict with self

        my $oledger_fs;

        # Prefer deriving the other ledger's path from its own blueprint/
        # package names -- the same way the director (bp-drive-next.pl)
        # always re-derives the file it reads. The entry's `ledger` string
        # is written data-dir-relative by the director but is documented
        # there as informational only; resolving it against $data_dir
        # (below) double-joins the data dir and never exists in practice.
        if (_widen_valid_name($obp) && _widen_valid_name($opkg)) {
            my $cand = "$blueprints_dir/$obp/packages/$opkg.md";
            $oledger_fs = $cand if -f $cand;
        }

        if (!defined $oledger_fs) {
            my $oledger = $e->{ledger};
            if (defined $oledger && !ref($oledger) && length $oledger) {
                # Try both byte interpretations of the decoded JSON string:
                # a producer that wrote raw UTF-8 bytes without a JSON
                # ->utf8 encode round-trips correctly through `_byteify`
                # (re-encode only if the decode flagged it as characters);
                # a producer that itself ->utf8->encode'd an already-raw-
                # bytes string round-trips through `as_bytes`'s downgrade
                # instead. Keep whichever candidate actually stats.
                for my $cand (_byteify($oledger), as_bytes($oledger)) {
                    (my $cand_fs = $cand) =~ tr{\\}{/};
                    unless ($cand_fs =~ m{\A(?:/|[A-Za-z]:/)}) {
                        $cand_fs = "$data_dir/$cand_fs";
                    }
                    if (-f $cand_fs) {
                        $oledger_fs = $cand_fs;
                        last;
                    }
                }
            }
        }

        next unless defined $oledger_fs;

        my $ocontent = do {
            open(my $ofh, '<:raw', $oledger_fs) or next;
            local $/;
            my $c = <$ofh>;
            close $ofh;
            $c;
        };
        next unless defined $ocontent;
        my $ows = extract_frontmatter_value($ocontent, 'write_set');
        next unless defined $ows && length $ows;
        my @oset = grep { length } split /:/, $ows;
        my @other_prefixes = _widen_ws_prefixes(\@oset);

        for my $np (@new_prefixes) {
            for my $op (@other_prefixes) {
                return "$obp/$opkg" if _widen_prefix_related($np, $op);
            }
        }
    }
    return undef;
}

sub op_widen_write_set {
    my @args = @_;
    my %opt = (path => []);
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'path=s@', 'decision=s', 'edit-target'); }
    arg_error('widen-write-set', 'unrecognised option') unless $ok;
    arg_error('widen-write-set', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('widen-write-set', 'missing required --ledger') unless defined $opt{ledger};
    arg_error('widen-write-set', 'missing required --path (repeatable)') unless @{ $opt{path} };
    arg_error('widen-write-set', 'missing required --decision') unless defined $opt{decision};
    arg_error('widen-write-set', "--decision '$opt{decision}' is not a positive integer")
        unless $opt{decision} =~ /\A[1-9][0-9]*\z/;
    for my $p (@{ $opt{path} }) {
        my $err = _widen_path_error($p);
        arg_error('widen-write-set', "--path $err") if defined $err;
    }

    my $bp = op_create_dirname(op_create_dirname($opt{ledger})) . '/blueprint.md';
    open(my $bfh, '<:raw', $bp)
        or arg_error('widen-write-set', "cannot read the blueprint for this ledger ($bp): $!");
    my $bytes = do { local $/; <$bfh> };
    close $bfh;
    my $dtext = _decision_text($bytes // '', $opt{decision});
    arg_error('widen-write-set', "Decision $opt{decision} not found in $bp") unless defined $dtext;
    for my $p (@{ $opt{path} }) {
        arg_error('widen-write-set', "Decision $opt{decision} does not name '$p' (verbatim) -- record the "
            . 're-scope in blueprint.md first (bp-blueprint.pl add-decision)')
            unless index($dtext, $p) >= 0;
    }

    my $conflict = _widen_check_inflight_conflict($opt{ledger}, $opt{path});
    if (defined $conflict) {
        arg_error('widen-write-set',
            "would overlap in-flight package ${conflict}'s write set; refusing (nothing written)");
    }

    my $entry = '- ' . iso_now() . " ${EMDASH} write_set widened per Decision $opt{decision}: "
              . join(', ', @{ $opt{path} });
    run_op('widen-write-set', $opt{ledger}, sub {
        my ($B) = @_;
        return (undef, 'no frontmatter block to update') unless $B =~ /\A---\s*\n(.*?)\n---/s;
        my ($fs, $fe) = ($-[1], $+[1]);
        my $cur = extract_frontmatter_value($B, 'write_set');
        return (undef, 'write_set: key not found in frontmatter') unless defined $cur;
        my @set  = grep { length } split /:/, $cur;
        my %have = map { ($_ => 1) } @set;
        push @set, grep { !$have{$_}++ } @{ $opt{path} };
        my $new = replace_first_key_line($B, $fs, $fe, 'write_set', 'write_set: ' . join(':', @set));
        return (undef, 'write_set: key not found in frontmatter') unless defined $new;
        # A widened TEST file is also an oracle path: guard-writes lets a
        # test-writer write only under test_paths, so a re-scope that adds a
        # tests/t/*.t to write_set alone leaves the test-writer refused
        # (hook-continuity-remake 06, 2026-09-24). Add it to test_paths too.
        # 22-ledger-rescope / Decision 87 (task 33): --edit-target means this widening
        # is EDIT TARGETS, never oracles -- task 25's own coupling (a widened .t path
        # also joins test_paths) is exactly what turned an edit target into an
        # immutable oracle and blocked package 21's test fixes. Skip it under the flag;
        # unchanged (today's behaviour) without it.
        my @tests = $opt{'edit-target'} ? ()
                  : grep { m{(?:\A|/)tests/t/[^/]+\.t\z} } @{ $opt{path} };
        if (@tests) {
            $new =~ /\A---\s*\n(.*?)\n---/s;
            my ($ts, $te) = ($-[1], $+[1]);
            my $tcur = extract_frontmatter_value($new, 'test_paths');
            if (defined $tcur) {
                my @tp = grep { length } split /:/, $tcur;
                my %thave = map { ($_ => 1) } @tp;
                push @tp, grep { !$thave{$_}++ } @tests;
                my $new2 = replace_first_key_line($new, $ts, $te, 'test_paths', 'test_paths: ' . join(':', @tp));
                $new = $new2 if defined $new2;
            }
        }
        return splice_insert_entry($new, qr/^##\s+Decisions & attempt log\b/m, $entry);
    });
}

# =====================================================================================
# `set-write-set` / `set-test-paths` (22-ledger-rescope, Decision 84) -- REPLACE
# write_set/test_paths wholesale, narrow or widen in one call. Unlike widen-write-set
# (additive only), this is the typed path for a genuine re-scope: before it, a
# narrowing (or a widen mixed with a narrow) had no legal move except dropping the
# package and creating a new one -- exactly the operator-named defect this package
# fixes ("if your solution was dropping a package and creating a new one, then that
# means there's missing functionality ... Bugfix it.").
#
# Every path the NEW set adds over the OLD set must be named verbatim in the given
# Decision's row text (same naming rule widen-write-set already enforces); a removed
# path needs no naming at all. Refused outright, leaving the ledger byte-for-byte
# unchanged, when its own ledger status is done or dropped (bp-drive-next.pl/
# bp-orchestrator.pl already treat those two as terminal -- there is no package left
# to re-scope). Decision 89 (correcting Decision 84's own first draft, caught before
# commit): rescoping a RUNNING package between worker dispatches is exactly the use
# case this exists for, so neither the package's own status of `running` nor its own
# membership in <data>/.drive-solo/inflight.json is a reason to refuse. Separately,
# when the call ADDS a path (one not already in the field), it is refused if that
# added path overlaps the write_set of ANOTHER in-flight package (the same overlap
# semantics widen-write-set already applies via _widen_check_inflight_conflict),
# naming the conflicting package; a removal-only call never triggers this check, even
# when the remaining paths still overlap another in-flight package.
# =====================================================================================

# _rescope_refusal_reason($ledger) -> a one-sentence refusal reason, or undef. Reads
# only the ledger's own status (Decision 89: in-flight membership and a `running`
# status are no longer refusal reasons on their own -- see _widen_check_inflight_conflict
# for the separate, added-path-only overlap check). Any I/O failure reading the ledger
# is treated as "no refusal" -- this is an additive safety gate, not the op's own
# read/validate path (run_op still re-reads and re-validates for real).
sub _rescope_refusal_reason {
    my ($ledger) = @_;

    if (open(my $fh, '<:raw', $ledger)) {
        local $/;
        my $B = <$fh>;
        close $fh;
        if (defined $B) {
            my $status = extract_frontmatter_value($B, 'status');
            if (defined $status && grep { $_ eq $status } qw(done dropped)) {
                return "this ledger's own status is '$status'; refusing to re-scope a package that is "
                     . 'done or dropped';
            }
        }
    }
    return undef;
}

# Shared by op_set_write_set / op_set_test_paths -- same shape, differing only in
# which frontmatter field is replaced (Decision 84 says explicitly they share it).
sub _op_set_scope_field {
    my ($field, $verb, @args) = @_;
    my %opt = (path => []);
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'path=s@', 'decision=s'); }
    arg_error($verb, 'unrecognised option') unless $ok;
    arg_error($verb, 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error($verb, 'missing required --ledger') unless defined $opt{ledger};
    arg_error($verb, 'missing required --decision') unless defined $opt{decision};
    arg_error($verb, 'missing required --path (repeatable)') unless @{ $opt{path} };
    arg_error($verb, "--decision '$opt{decision}' is not a positive integer")
        unless $opt{decision} =~ /\A[1-9][0-9]*\z/;

    for my $p (@{ $opt{path} }) {
        my $err = _widen_path_error($p);
        arg_error($verb, "--path $err") if defined $err;
    }

    my $refusal = _rescope_refusal_reason($opt{ledger});
    arg_error($verb, $refusal) if defined $refusal;

    my $bp = op_create_dirname(op_create_dirname($opt{ledger})) . '/blueprint.md';
    open(my $bfh, '<:raw', $bp)
        or arg_error($verb, "cannot read the blueprint for this ledger ($bp): $!");
    my $bytes = do { local $/; <$bfh> };
    close $bfh;
    my $dtext = _decision_text($bytes // '', $opt{decision});
    arg_error($verb, "Decision $opt{decision} not found in $bp") unless defined $dtext;

    my $cur_B;
    {
        open(my $lfh, '<:raw', $opt{ledger}) or arg_error($verb, "cannot read $opt{ledger}: $!");
        local $/;
        $cur_B = <$lfh>;
        close $lfh;
        $cur_B = '' unless defined $cur_B;
    }
    my %existing = map { ($_ => 1) } ledger_field_segments($cur_B, $field);

    my @added;
    for my $p (@{ $opt{path} }) {
        next if $existing{$p};
        arg_error($verb, "Decision $opt{decision} does not name '$p' (verbatim) -- record the re-scope in "
            . 'blueprint.md first (bp-blueprint.pl add-decision)')
            unless index($dtext, $p) >= 0;
        push @added, $p;
    }

    # Decision 89: only an ADDED path can trigger the overlap-with-another-in-flight-
    # package refusal -- a removal-only call (no @added at all) never checks this, even
    # when the paths that remain still overlap another in-flight package's write_set.
    if (@added) {
        my $conflict = _widen_check_inflight_conflict($opt{ledger}, \@added);
        if (defined $conflict) {
            arg_error($verb,
                "would overlap in-flight package ${conflict}'s write set; refusing (nothing written)");
        }
    }

    my $entry = '- ' . iso_now() . " ${EMDASH} $field replaced per Decision $opt{decision}: "
              . join(':', @{ $opt{path} });

    run_op($verb, $opt{ledger}, sub {
        my ($B) = @_;
        return (undef, 'no frontmatter block to update') unless $B =~ /\A---\s*\n(.*?)\n---/s;
        my ($fs, $fe) = ($-[1], $+[1]);
        my $new = replace_first_key_line($B, $fs, $fe, $field, "$field: " . join(':', @{ $opt{path} }));
        return (undef, "$field: key not found in frontmatter") unless defined $new;
        return splice_insert_entry($new, qr/^##\s+Decisions & attempt log\b/m, $entry);
    });
}

sub op_set_write_set  { return _op_set_scope_field('write_set',  'set-write-set',  @_) }
sub op_set_test_paths { return _op_set_scope_field('test_paths', 'set-test-paths', @_) }

# =====================================================================================
# `set-checks` (27-ledger-set-checks, Decision 106) -- REPLACE the ledger's frontmatter
# `checks:` field wholesale, the same `_op_set_scope_field` model set-write-set /
# set-test-paths already use: refuse on done/dropped, require every ADDED check to be
# named verbatim (bounded token) in the given blueprint Decision, refuse when the new
# set still omits a check the package's write_set implies per BpChecks::missing.
#
# Decision 106 SUPERSEDES this package's own spec §2.3 ("table UNION a fixed eight-name
# list"): there is NO fixed built-in list. Vocabulary comes from the blueprint's live
# checks-table alone (BpChecks::parse_table) -- a table with rows constrains every
# requested name to those rows; a blueprint with no live table (absent, or only inside
# an HTML comment) imposes no vocabulary constraint at all, so any well-formed name is
# accepted, exactly as `create` already accepts any name today.
# =====================================================================================

sub _check_name_shape_error {
    my ($name) = @_;
    return "is empty" if $name eq '';
    return "contains ':', '|', or a newline" if $name =~ /[:|\r\n]/;
    return "contains whitespace" if $name =~ /\s/;
    return undef;
}

# Detects the list form of the ledger's own `checks:` field (scalar key line followed
# by `- item` lines) -- refused outright (spec 2.5 step 7) rather than half-rewritten,
# because replace_first_key_line touches only the key line and would leave the old
# list items merged in alongside the new scalar value.
sub _ledger_checks_is_list_form {
    my ($B) = @_;
    return 0 unless $B =~ /\A---\s*\n(.*?)\n---/s;
    my @FML = split(/\n/, $1, -1);
    for my $n (0 .. $#FML) {
        if ($FML[$n] =~ /^checks:\s*(?:.*?)\s*$/) {
            return (($n + 1) <= $#FML && $FML[$n + 1] =~ /^\s+-\s*(?:.*?)\s*$/) ? 1 : 0;
        }
    }
    return 0;
}

sub op_set_checks {
    my @args = @_;
    my %opt = (check => []);
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'check=s@', 'decision=s'); }
    arg_error('set-checks', 'unrecognised option') unless $ok;
    arg_error('set-checks', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('set-checks', 'missing required --ledger') unless defined $opt{ledger};
    arg_error('set-checks', 'missing required --decision') unless defined $opt{decision};
    arg_error('set-checks', 'missing required --check (repeatable)') unless @{ $opt{check} };
    arg_error('set-checks', "--decision '$opt{decision}' is not a positive integer")
        unless $opt{decision} =~ /\A[1-9][0-9]*\z/;

    for my $c (@{ $opt{check} }) {
        my $err = _check_name_shape_error($c);
        arg_error('set-checks', "--check '$c' $err") if defined $err;
    }

    my $refusal = _rescope_refusal_reason($opt{ledger});
    arg_error('set-checks', $refusal) if defined $refusal;

    my $bp = op_create_dirname(op_create_dirname($opt{ledger})) . '/blueprint.md';
    open(my $bfh, '<:raw', $bp)
        or arg_error('set-checks', "cannot read the blueprint for this ledger ($bp): $!");
    my $bp_bytes = do { local $/; <$bfh> };
    close $bfh;
    my $dtext = _decision_text($bp_bytes // '', $opt{decision});
    arg_error('set-checks', "Decision $opt{decision} not found in $bp") unless defined $dtext;

    # Normalise separators before deriving the directory: __FILE__ may arrive with
    # Windows backslashes, and op_create_dirname must not be handed a raw __FILE__
    # (turn-cap-consistency.t C9 -- separators normalised first, same idiom bp-checks.pl
    # itself already uses before its own dirname() call).
    (my $self_file = __FILE__) =~ s{\\}{/}g;
    my $checks_pl = op_create_dirname($self_file) . '/bp-checks.pl';
    eval { require $checks_pl; 1 }
        or io_error('set-checks', $checks_pl, "cannot load: " . ($@ || 'unknown error'));

    my $rows = BpChecks::parse_table($bp_bytes // '');

    my $cur_B;
    {
        open(my $lfh, '<:raw', $opt{ledger}) or arg_error('set-checks', "cannot read $opt{ledger}: $!");
        local $/;
        $cur_B = <$lfh>;
        close $lfh;
        $cur_B = '' unless defined $cur_B;
    }
    arg_error('set-checks',
        "frontmatter checks: is in list form; set-checks only replaces the scalar colon-delimited form")
        if _ledger_checks_is_list_form($cur_B);
    my %existing = map { ($_ => 1) } ledger_field_segments($cur_B, 'checks');

    my (@new, %seen);
    for my $c (@{ $opt{check} }) { push @new, $c unless $seen{$c}++ }

    # Both the vocabulary check (Decision 106: table-rows-only, no fixed list) and the
    # Decision-naming check apply ONLY to ADDED names -- a name already in the ledger's
    # existing checks: field needs neither re-validating nor re-naming, exactly as
    # set-write-set/set-test-paths treat their own added-vs-removed paths.
    my %known = @$rows ? (map { ($_->{check} => 1) } @$rows) : ();
    for my $c (@new) {
        next if $existing{$c};
        if (@$rows && !$known{$c}) {
            arg_error('set-checks',
                "'$c' is not a row of the blueprint's live checks-table and there is no fixed check "
              . 'list (Decision 106)');
        }
        arg_error('set-checks', "Decision $opt{decision} does not name '$c' (verbatim) -- record the "
            . 're-scope in blueprint.md first (bp-blueprint.pl add-decision)')
            unless $dtext =~ /(?<![A-Za-z0-9_-])\Q$c\E(?![A-Za-z0-9_-])/;
    }

    my $ws = BpChecks::_fm($cur_B, 'write_set');
    if (defined $ws && length $ws && @$rows) {
        my $miss = BpChecks::missing($rows, $ws, join(':', @new));
        if (@$miss) {
            arg_error('set-checks',
                "the package's write set implies '$miss->[0]'; audit would fail if it were dropped");
        }
    }

    my $entry = '- ' . iso_now() . " ${EMDASH} checks replaced per Decision $opt{decision}: " . join(':', @new);

    run_op('set-checks', $opt{ledger}, sub {
        my ($B) = @_;
        return (undef, 'no frontmatter block to update') unless $B =~ /\A---\s*\n(.*?)\n---/s;
        my ($fs, $fe) = ($-[1], $+[1]);
        my $new = replace_first_key_line($B, $fs, $fe, 'checks', 'checks: ' . join(':', @new));
        return (undef, 'checks: key not found in frontmatter') unless defined $new;
        return splice_insert_entry($new, qr/^##\s+Decisions & attempt log\b/m, $entry);
    });
}

# =====================================================================================
# `set-section` (22-ledger-rescope, Decision 84) -- replace the BODY of exactly one of
# Scope / Done criteria / Inputs / Out of scope, leaving the frontmatter byte-
# identical (unlike every other mutating verb here, which is free to bump
# last_updated). Every other heading is refused: Pipeline / Decisions & attempt log /
# Next action already have their own dedicated verb (tick-step / append-attempt /
# set-next-action), as do Outputs (add-output) and Escalation (set-escalation).
# =====================================================================================

my @SET_SECTION_ALLOWED = ('Scope', 'Done criteria', 'Inputs', 'Out of scope');

sub splice_set_section {
    my ($B, $section, $text) = @_;
    my $head_re = qr/^##\s+\Q$section\E\b/m;
    my $loc = locate_section($B, $head_re);
    return (undef, "## $section section not found") unless $loc;
    return (undef, 'section ends inside an unterminated fenced code block; refusing to replace inside a fence')
        if $loc->{unterminated};
    my $has_term = ($loc->{body_end} < length($B)) ? 1 : 0;
    my $new_span = "\n" . $text . ($has_term ? "\n\n" : "\n");
    return (substr($B, 0, $loc->{body_start}) . $new_span . substr($B, $loc->{body_end}), undef);
}

sub op_set_section {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'section=s', 'text=s', 'text-file=s'); }
    arg_error('set-section', 'unrecognised option') unless $ok;
    arg_error('set-section', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('set-section', 'missing required --ledger') unless defined $opt{ledger};
    arg_error('set-section', 'missing required --section') unless defined $opt{section};
    unless (grep { $_ eq $opt{section} } @SET_SECTION_ALLOWED) {
        arg_error('set-section', "'--section $opt{section}' is not one of the sections this verb may replace "
            . '(' . join(', ', @SET_SECTION_ALLOWED) . '); Pipeline, Decisions & attempt log and Next action '
            . 'each have their own dedicated verb, and every other heading is outside the allow-list');
    }
    my $text = get_freetext_arg(sub => 'set-section', opt => \%opt, primary => 'text', filekey => 'text-file');

    run_op('set-section', $opt{ledger}, sub { return splice_set_section($_[0], $opt{section}, $text) });
}

# `set-escalation` -- replace the BODY of ## Escalation. The coordinator protocol
# has a blocked/parked coordinator fill it, and the orchestrator, resolver and
# reporter read it, but direct Edit of a ledger is refused (GuardBlueprintWrite)
# and set-section deliberately excludes it, so before this verb there was no
# sanctioned way to write it (bug 20261022-115951-2e6f).
sub op_set_escalation {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'text=s', 'text-file=s'); }
    arg_error('set-escalation', 'unrecognised option') unless $ok;
    arg_error('set-escalation', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('set-escalation', 'missing required --ledger') unless defined $opt{ledger};
    my $text = get_freetext_arg(sub => 'set-escalation', opt => \%opt, primary => 'text', filekey => 'text-file');
    $text =~ s/\s+\z//;
    arg_error('set-escalation', 'the --text is empty after stripping trailing whitespace') if $text eq '';
    my @lines = split(/\n/, $text, -1);
    if (grep { /^\s*-\s*\[[xX]\]/ } @lines) {
        arg_error('set-escalation',
            "the --text must not contain a line matching '- [x]' (would forge the orchestrator's ledger_checkboxes "
          . 'progress signal)');
    }
    if (grep { /^#{1,2}\s/ } @lines) {
        arg_error('set-escalation',
            "the --text must not contain a '#' or '##' heading line (it would end the Escalation section early)");
    }
    run_op('set-escalation', $opt{ledger}, sub { return splice_set_section($_[0], 'Escalation', $text) });
}

sub op_add_output {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'text=s', 'text-file=s'); }
    arg_error('add-output', 'unrecognised option') unless $ok;
    arg_error('add-output', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('add-output', 'missing required --ledger') unless defined $opt{ledger};
    my $text = get_freetext_arg(sub => 'add-output', opt => \%opt, primary => 'text', filekey => 'text-file');
    if (grep { /^\s*-\s*\[[xX]\]/ } split(/\n/, $text, -1)) {
        arg_error('add-output',
            "the --text must not contain a line matching '- [x]' (would forge the orchestrator's ledger_checkboxes "
          . 'progress signal)');
    }
    $text =~ s/[\r\n]+/ /g;
    my $entry = "- ${text}";
    run_op('add-output', $opt{ledger}, sub { return splice_insert_entry($_[0], qr/^##\s+Outputs\b/m, $entry) });
}

# =====================================================================================
# `claim-check` (08-completion-claims-checked spec §2.6/§2.7) — READ-ONLY report. Never
# mutates, never refuses on pipeline/oracle state; always exits 0 when it can produce a
# report. Exit 3 usage, exit 4 I/O.
# =====================================================================================

sub extract_frontmatter_value {
    my ($B, $key) = @_;
    return undef unless $B =~ /\A---\s*\n(.*?)\n---/s;
    for my $l (split(/\n/, $1, -1)) {
        if ($l =~ /^\Q$key\E:\s*(.*?)\s*$/) { return $1 }
    }
    return undef;
}

sub op_claim_check {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { }; $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s'); }
    arg_error('claim-check', 'unrecognised option') unless $ok;
    arg_error('claim-check', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('claim-check', 'missing required --ledger') unless defined $opt{ledger};

    my $B;
    {
        open(my $fh, '<:raw', $opt{ledger}) or io_error('claim-check', $opt{ledger}, "cannot read: $!");
        local $/;
        $B = <$fh>;
        close $fh;
        $B = '' unless defined $B;
    }

    my $status  = extract_frontmatter_value($B, 'status');
    my $package = extract_frontmatter_value($B, 'package');
    my $gated   = (defined $status && $status eq 'done') ? 1 : 0;

    my @items = ledger_pipeline_items($B);
    my @unsatisfied = map { $_->{step} } grep { !$_->{satisfied} } @items;

    my @test_paths = ledger_test_paths($B);
    my @raw_records = parse_oracle_records($B);
    my $sidecar_path = oracle_sidecar_path($opt{ledger});
    my @sidecar_entries = eval { read_sidecar_entries($sidecar_path) };
    @sidecar_entries = () if $@;
    my @hydrated = eval { hydrate_oracle_records(\@raw_records, \@sidecar_entries, \@test_paths) };
    @hydrated = () if $@;

    my %latest;            # "$step|$path" => full record (last one wins if somehow duplicated)
    my %latest_degraded;   # "$step|$path" => 0|1
    for my $h (@hydrated) {
        my $f = $h->{full};
        my $key = ($f->{step} // '') . '|' . ($f->{path} // '');
        $latest{$key} = $f;
        $latest_degraded{$key} = $h->{degraded};
    }

    my %all_paths = map { ($_ => 1) } @test_paths;
    $all_paths{ $_->{full}{path} } = 1 for grep { defined $_->{full}{path} } @hydrated;

    my @oracle_paths;
    my @findings;

    for my $path (sort keys %all_paths) {
        my $r3 = $latest{"3|$path"};
        my $r5 = $latest{"5|$path"};
        my $step3_ticked = grep { $_->{step} == 3 && $_->{satisfied} } @items;
        my $step5_ticked = grep { $_->{step} == 5 && $_->{satisfied} } @items;

        my $verdict = 'unknown';
        my $delta;

        if ($gated) {
            if ($step3_ticked && !$r3) {
                push @findings, { code => 'ORACLE_NOT_RECORDED',
                                   path => $path, step => undef,
                                   detail => "step 3 is ticked but no oracle record exists for $path" };
            }
            if ($r3 && $r3->{status} eq 'unavailable') {
                push @findings, { code => 'ORACLE_UNDERIVABLE', path => $path, step => 3,
                                   detail => "step-3 record for $path is unavailable: " . ($r3->{reason} // '') };
            }
            if ($r5 && $r5->{status} eq 'unavailable') {
                push @findings, { code => 'ORACLE_UNDERIVABLE', path => $path, step => 5,
                                   detail => "step-5 record for $path is unavailable: " . ($r5->{reason} // '') };
            }
            if ($step5_ticked && $r3 && !$r5) {
                push @findings, { code => 'ORACLE_NOT_REVALIDATED', path => $path, step => undef,
                                   detail => "step 5 is ticked and $path has a step-3 record but no step-5 record" };
            }

            if ($r3 && $r5 && $r3->{status} eq 'ok' && $r5->{status} eq 'ok') {
                $delta = oracle_delta($r3, $r5);
                my $comparable = (exists $r3->{descriptions} && exists $r5->{descriptions}) ? 1 : 0;

                # "differ" (sha256, assertion count, or description SET) is judged on
                # NORMALIZED descriptions (AC-25/AC-26: a parenthetical-only or
                # whitespace/TODO-only difference is not a real change), never on the
                # raw descriptions_sha256, which is a surface hash over unnormalized text.
                my $desc_changed = $comparable
                    ? (scalar(@{ $delta->{descriptions_added} }) > 0 || scalar(@{ $delta->{descriptions_removed} }) > 0)
                    : (($r3->{descriptions_sha256} // '') ne ($r5->{descriptions_sha256} // ''));
                my $sha_changed        = (($r3->{sha256} // '') ne ($r5->{sha256} // ''));
                my $assertions_changed = ($r3->{assertions} != $r5->{assertions});
                my $identical = !$desc_changed && !$sha_changed && !$assertions_changed;

                my $shrank = ($r5->{assertions} < $r3->{assertions})
                          || ($comparable && scalar(@{ $delta->{descriptions_removed} }) > 0);

                if ($shrank) {
                    $verdict = 'shrunk';
                    push @findings, { code => 'ORACLE_SHRANK', path => $path, step => undef, delta => $delta,
                        detail => sprintf('%s: assertions %d -> %d (or a description vanished)',
                                           $path, $r3->{assertions}, $r5->{assertions}) };
                }
                elsif (!$identical) {
                    $verdict = 'drifted';
                    if (!exists $r5->{reaccept}) {
                        my @added = @{ $delta->{descriptions_added} };
                        push @findings, { code => 'ORACLE_DRIFT_UNACCEPTED', path => $path, step => undef, delta => $delta,
                            detail => "$path: oracle changed without a reaccept (added: "
                                    . join(', ', @added) . ')' };
                    }
                    else {
                        $verdict = 'reaccepted';
                    }
                }
                else {
                    $verdict = 'ok';
                }
            }
            elsif ($r3 && !$r5) { $verdict = 'not-revalidated' }
            elsif (!$r3)        { $verdict = 'not-recorded' }
        }

        my $sidecar_missing = (($r3 && $latest_degraded{"3|$path"}) || ($r5 && $latest_degraded{"5|$path"})) ? 1 : 0;
        push @oracle_paths, {
            path    => $path,
            verdict => $verdict,
            step3   => $r3 ? $r3->{status} : undef,
            step5   => $r5 ? $r5->{status} : undef,
            (defined $delta ? (delta => $delta) : ()),
            reaccept => ($r5 && exists $r5->{reaccept}) ? $r5->{reaccept} : undef,
            ($sidecar_missing ? (sidecar => 'missing') : ()),
        };
    }

    if ($gated) {
        for my $it (sort { $a->{step} <=> $b->{step} } grep { !$_->{satisfied} } @items) {
            push @findings, { code => 'PIPELINE_STEP_UNTICKED', path => undef, step => $it->{step},
                               detail => $it->{text} };
        }
    }
    @findings = () unless $gated;

    my $report = {
        ledger   => $opt{ledger},
        package  => $package,
        status   => $status,
        gated    => $gated ? JSON::PP::true : JSON::PP::false,
        pipeline => {
            items => [ map {
                { step => $_->{step} + 0, ticked => ($_->{ticked} ? JSON::PP::true : JSON::PP::false),
                  conditional => ($_->{conditional} ? JSON::PP::true : JSON::PP::false),
                  na => ($_->{na} ? JSON::PP::true : JSON::PP::false),
                  satisfied => ($_->{satisfied} ? JSON::PP::true : JSON::PP::false),
                  text => $_->{text} }
            } @items ],
            unsatisfied => [ sort { $a <=> $b } @unsatisfied ],
        },
        oracle   => { paths => \@oracle_paths },
        findings => \@findings,
    };

    print JSON::PP->new->canonical(1)->ascii(1)->encode($report) . "\n";
    exit 0;
}

# =====================================================================================
# `rotate` (b45-ledger-context-budget-spec.md §3) — moves stale
# `## Decisions & attempt log` entries to reports/ledger-history/<pkg>.md.
# =====================================================================================

# Split the `## Decisions & attempt log` body [$body_start, $body_end) into ordered,
# fence-aware "entries". An entry begins at a NOT-in-fence line matching /^-\s/ (the
# shape every append-attempt/MEANS-DEVIATION entry has, per SKILL.md) and runs up to
# (but not including) the next such line, or to $body_end. Content before the first
# entry (placeholder text, blank lines) is "preamble" and is never a rotation
# candidate. Because entry boundaries are only recognised OUTSIDE a fence, a fence
# can never be split: any fence-toggle line and everything inside it is absorbed into
# whichever entry (or the preamble) precedes it, never carved into its own entry.
sub parse_attempt_entries {
    my ($B, $body_start, $body_end) = @_;
    my $infence = 0;
    my @entries;
    my $cur_start;
    each_line_with_offset($B, $body_start, $body_end, sub {
        my ($line, $off, $len, $has_nl) = @_;
        if (is_fence_line($line)) { $infence = !$infence; return undef }
        if (!$infence && $line =~ /^-\s/) {
            push @entries, { start => $cur_start, end => $off } if defined $cur_start;
            $cur_start = $off;
        }
        return undef;
    });
    push @entries, { start => $cur_start, end => $body_end } if defined $cur_start;
    my $preamble_end = @entries ? $entries[0]{start} : $body_end;
    return (\@entries, $preamble_end);
}

# Does this entry span contain a LIVE (non-fenced) MEANS-DEVIATION: marker? Mirrors
# BpJudge::parse_means_deviations's own fence-skipping exactly (bp-judge.pl:635) —
# parser and retention rule must agree on what counts, or the gap between them is a
# forgery window (spec §1 / SKILL.md:159-161).
sub entry_has_live_marker {
    my ($B, $start, $end) = @_;
    my $infence = 0;
    my $found = 0;
    each_line_with_offset($B, $start, $end, sub {
        my ($line, $off, $len, $has_nl) = @_;
        if (is_fence_line($line)) { $infence = !$infence; return undef }
        if (!$infence && $line =~ /MEANS-DEVIATION:/) { $found = 1; return 1 }
        return undef;
    });
    return $found;
}

# reports/ledger-history/<pkg>.md is relative to the BLUEPRINT dir (spec §3), derived
# from the ledger path's own `.../packages/<pkg>.md` shape — never a second, parallel
# naming convention. Deliberately requires the packages/ path element: bp-resume-sweep.sh
# and bp-status.sh glob "packages/*.md" (spec §2), so history must never be reachable
# by guessing a sibling of the ledger without going through that exact anchor.
sub derive_history_path {
    my ($ledger) = @_;
    return undef unless $ledger =~ m{^(.*)/packages/([^/]+)\.md$};
    my ($bpdir, $pkg) = ($1, $2);
    return "$bpdir/reports/ledger-history/$pkg.md";
}

# mkdir -p, core-Perl only (File::Path is not on the allowed-module list, §2.5).
sub ensure_dir_exists {
    my ($dir) = @_;
    return 1 if -d $dir;
    # Drive-RELATIVE (red-team step6 MAJOR-2): "C:foo" (a colon with NO separator
    # right after it) is a distinct, legal Windows path form that resolves against
    # that drive's own process-specific "current directory" -- something this function
    # has no way to know or safely guess. Falling through to the generic branches below
    # would silently rebuild the whole path as a literally-named "C:foo" directory
    # relative to the CWD (demonstrated) -- the exact stray-directory class §2.4 exists
    # to close, just for an input shape the drive-absolute fix didn't cover. Refuse
    # outright rather than guess; the caller already treats a false return as io_error.
    return 0 if $dir =~ m{^[A-Za-z]:(?![\\/])};
    my @parts = split(m{[\\/]}, $dir);
    my $cur;
    if ($dir =~ m{^([A-Za-z]:)[\\/]}) {
        # Windows drive-absolute (a03 spec §2.4/§1c): the walk must start AT the drive
        # root (e.g. "C:"), never be treated as relative -- the bug this fixes rebuilt
        # the whole tree under the process cwd as a stray "./C:/..." directory.
        $cur = $1;
        shift @parts; # the split's first element is the same "C:" already in $cur
    }
    elsif ($dir =~ m{^[\\/]}) {
        $cur = '';
    }
    else {
        $cur = '.';
    }
    for my $p (@parts) {
        next if $p eq '';
        $cur .= '/' . $p;
        next if -d $cur;
        return 0 unless mkdir($cur, 0755);
    }
    return 1;
}

sub op_rotate {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'keep=i', 'budget=i', 'dry-run'); }
    arg_error('rotate', 'unrecognised option') unless $ok;
    arg_error('rotate', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('rotate', 'missing required --ledger') unless defined $opt{ledger};
    my $keep = defined $opt{keep} ? $opt{keep} : 5;
    arg_error('rotate', "'--keep $opt{keep}' must be a non-negative integer") if $keep !~ /^\d+$/;
    my $budget = defined $opt{budget} ? $opt{budget} : DEFAULT_BUDGET_BYTES;
    arg_error('rotate', "'--budget $opt{budget}' must be a positive integer") if $budget !~ /^[1-9]\d*$/;
    my $dry_run = $opt{'dry-run'} ? 1 : 0;
    my $ledger  = $opt{ledger};

    my $history = derive_history_path($ledger);
    arg_error('rotate', "--ledger '$ledger' is not of the form .../packages/<pkg>.md; "
        . 'cannot derive the blueprint dir and package name for history routing')
        unless defined $history;

    my $lockpath = "$ledger.lock";
    open(my $lk, '>', $lockpath) or io_error('rotate', $ledger, "cannot open lock file $lockpath: $!");
    flock($lk, LOCK_EX) or io_error('rotate', $ledger, "cannot acquire lock on $lockpath: $!");

    my $orig;
    {
        open(my $fh, '<:raw', $ledger) or io_error('rotate', $ledger, "cannot read: $!");
        local $/;
        $orig = <$fh>;
        close $fh;
        $orig = '' unless defined $orig;
    }

    # Deliberately NO validate_bytes() call here (unlike the other five ops). rotate
    # is pure byte-preserving surgery, never content synthesis, and the corpus
    # contains at least one ledger with a raw NUL byte inside an entry (SYN-19: q01)
    # that V1 would otherwise reject outright — rotating that ledger back under
    # budget must not itself be blocked by the very check that flags NUL as invalid.
    my $head_re = qr/^##\s+Decisions & attempt log\b/m;
    my $loc = locate_section($orig, $head_re);
    notfound_error('rotate', $ledger, '## Decisions & attempt log section not found') unless $loc;
    notfound_error('rotate', $ledger,
        'section ends inside an unterminated fenced code block; refusing to rotate')
        if $loc->{unterminated};

    my ($entries, $preamble_end) = parse_attempt_entries($orig, $loc->{body_start}, $loc->{body_end});
    my $total = scalar @$entries;

    # b45 §3 (amended): retention is BUDGET-DRIVEN with a count FLOOR, not count-driven.
    # Mandatory, absolute, never movable at any budget: every entry with a live
    # MEANS-DEVIATION marker (any age, §1), and the most recent --keep (floor, default 5)
    # NON-marker entries, "however large they are" (a replacement coordinator always has
    # recent context). Above that floor, move as many of the OLDER non-marker entries as
    # it takes to land the whole ledger under --budget -- never fewer than needed, never
    # digging into the floor to do it.
    my @forced;     # entry indices with a live marker -- never movable, any age
    my @non_forced; # {idx, len} in original order, excluding forced
    for my $i (0 .. $total - 1) {
        my $e = $entries->[$i];
        if (entry_has_live_marker($orig, $e->{start}, $e->{end})) { push @forced, $i }
        else { push @non_forced, { idx => $i, len => $e->{end} - $e->{start} } }
    }
    my $n_nf    = scalar @non_forced;
    my $floor_k = $keep < $n_nf ? $keep : $n_nf;

    # suffix_len[$j] = total bytes of the LAST $j non-forced entries (by recency).
    my @suffix_len = (0) x ($n_nf + 1);
    for my $j (1 .. $n_nf) {
        $suffix_len[$j] = $suffix_len[$j - 1] + $non_forced[$n_nf - $j]{len};
    }
    my $forced_len = 0;
    $forced_len += ($entries->[$_]{end} - $entries->[$_]{start}) for @forced;
    my $const_len = $loc->{body_start} + ($preamble_end - $loc->{body_start})
                  + (length($orig) - $loc->{body_end}) + $forced_len;

    # Prefer the LARGEST k (fewest entries moved) that lands at/under budget, without ever
    # going below the floor. If even the floor itself is over budget, use the floor anyway
    # (it is mandatory) and report the shortfall rather than fabricate compliance.
    my $k = $n_nf;
    my $unreachable = 0;
    while ($k > $floor_k && ($const_len + $suffix_len[$k]) > $budget) { $k-- }
    if (($const_len + $suffix_len[$k]) > $budget) { $unreachable = 1 }

    my %kept_non_forced = map { $non_forced[$n_nf - $_ - 1]{idx} => 1 } (0 .. $k - 1) if $k > 0;
    my (@moved, @retained);
    for my $i (0 .. $total - 1) {
        my $e = $entries->[$i];
        if ($kept_non_forced{$i} || grep { $_ == $i } @forced) { push @retained, $e }
        else { push @moved, $e }
    }

    my $moved_bytes = 0;
    $moved_bytes += ($_->{end} - $_->{start}) for @moved;
    my $new_len = $const_len + $suffix_len[$k];

    # a03 spec §2.1/§2.3: the irreducible fact is a STATE, reported via emit_notice's
    # distinct, non-error-shaped, machine-readable-token line -- never emit_err's
    # `bp-ledger: <sub>: <path>: <msg>` shape. Diagnosis wording is preserved verbatim
    # (done-criterion 4); only the framing (prefix/token) changes.
    my $irreducible_msg = $unreachable
        ? "$ledger is $new_len bytes, over the $budget-byte budget after rotating everything it "
          . "legitimately can (floor --keep $floor_k non-marker entries (" . $suffix_len[$k]
          . " bytes) + " . scalar(@forced) . " MEANS-DEVIATION entry/ies ($forced_len bytes) + "
          . 'fixed sections are, together, already over budget). Not reducible further without '
          . 'either dropping mandated retention or losing the record.'
        : undef;

    # a03 spec §2.5: exactly one stderr line on any non-zero exit. Deferring the notice
    # to right before each SUCCESS exit point (never called on a path that is about to
    # io_error) is how this file satisfies that invariant -- by the time this runs, every
    # fallible step on that path has already succeeded. `touch_marker` is off for
    # --dry-run, which is a report-only op that touches nothing on disk (header comment,
    # bp-ledger.pl:18-19) -- the marker is disk state, so writing it would violate that.
    my $finalize_budget_state = sub {
        my (%o) = @_;
        my $touch_marker = exists $o{touch_marker} ? $o{touch_marker} : 1;
        if ($unreachable) {
            emit_notice('rotate', 'LEDGER_IRREDUCIBLE', $irreducible_msg);
            mark_irreducible($ledger) if $touch_marker;
        }
        elsif ($touch_marker) {
            # A rotate call that finds the ledger reducible (or already fine) is exactly
            # the "new rotate finds it reducible again" case spec §2.1 says must clear
            # any earlier irreducible suppression.
            clear_budget_marker($ledger);
        }
    };

    if (!@moved) {
        if ($dry_run) {
            $finalize_budget_state->(touch_marker => 0);
            print "bp-ledger: rotate: $ledger: 0 of $total entries eligible to move; nothing to do.\n";
        }
        else {
            $finalize_budget_state->();
        }
        flock($lk, LOCK_UN);
        close($lk);
        exit 0;
    }

    my $new_body = substr($orig, $loc->{body_start}, $preamble_end - $loc->{body_start})
                 . join('', map { substr($orig, $_->{start}, $_->{end} - $_->{start}) } @retained);
    my $new_ledger = substr($orig, 0, $loc->{body_start}) . $new_body . substr($orig, $loc->{body_end});
    my $history_append = join('', map { substr($orig, $_->{start}, $_->{end} - $_->{start}) } @moved);

    if ($dry_run) {
        $finalize_budget_state->(touch_marker => 0);
        my $over = $unreachable ? " -- unreachable (see prior stderr line)" : '';
        print "bp-ledger: rotate: $ledger: would move " . scalar(@moved) . " of $total entries "
            . "($moved_bytes bytes) to $history: ledger would be $new_len bytes (budget $budget)$over.\n";
        flock($lk, LOCK_UN);
        close($lk);
        exit 0;
    }

    # History first, ledger second: on ANY failure between here and the final
    # rename, the ledger (read above, untouched on disk so far) stays byte-identical
    # (spec §3 "atomic ... any failure at any point leaves the ledger byte-identical").
    # Writing history first means a crash after it succeeds risks a *duplicate*
    # history append on retry (the ledger still shows those entries as un-rotated) --
    # strictly preferable to the alternative order, which risks losing the entries
    # outright (removed from the ledger, never landed in history).
    my $hist_dir = $history;
    $hist_dir =~ s{/[^/]+$}{};
    ensure_dir_exists($hist_dir) or io_error('rotate', $ledger, "cannot create directory $hist_dir: $!");

    my $hist_orig = '';
    if (-e $history) {
        open(my $hfh, '<:raw', $history) or io_error('rotate', $ledger, "cannot read $history: $!");
        local $/;
        $hist_orig = <$hfh>;
        close $hfh;
        $hist_orig = '' unless defined $hist_orig;
    }
    my $hist_new = $hist_orig . $history_append;

    my $hist_tmp = "$history.tmp.$$";
    open(my $hw, '>:raw', $hist_tmp) or io_error('rotate', $ledger, "cannot open temp file $hist_tmp: $!");
    print {$hw} $hist_new or do { close $hw; unlink $hist_tmp; io_error('rotate', $ledger, "write to $hist_tmp failed: $!") };
    close($hw) or do { unlink $hist_tmp; io_error('rotate', $ledger, "close $hist_tmp failed: $!") };
    unless ($RENAME_FN->($hist_tmp, $history)) {
        unlink $hist_tmp;
        io_error('rotate', $ledger, "rename $hist_tmp -> $history failed: $! (ledger untouched)");
    }

    my $tmp = "$ledger.tmp.$$";
    open(my $w, '>:raw', $tmp) or io_error('rotate', $ledger, "cannot open temp file $tmp: $!");
    print {$w} $new_ledger or do { close $w; unlink $tmp; io_error('rotate', $ledger, "write to $tmp failed: $!") };
    close($w) or do { unlink $tmp; io_error('rotate', $ledger, "close $tmp failed: $!") };
    unless ($RENAME_FN->($tmp, $ledger)) {
        unlink $tmp;
        io_error('rotate', $ledger, "rename $tmp -> $ledger failed: $!");
    }

    # Every fallible step on this path has now succeeded -- safe to finalize/notify
    # (a03 spec §2.5's one-stderr-line invariant: deferred to here, so an earlier
    # failure above never reaches this line at all).
    $finalize_budget_state->();

    flock($lk, LOCK_UN);
    close($lk);
    exit 0;
}

# =====================================================================================
# `validate` — three entry shapes (spec §2.5).
# =====================================================================================

# --- payload-mode helpers, a pure lift of ledger-guard.sh:87-329 ---------------------

sub is_str {
    my ($v) = @_;
    return 0 unless defined $v;
    return 0 if ref $v;
    my $f = B::svref_2object(\$v)->FLAGS;
    return 0 unless $f & B::SVp_POK();
    return 0 if $f & (B::SVp_IOK() | B::SVp_NOK());
    return 1;
}

sub as_bytes {
    my ($s) = @_;
    return '' unless defined $s;
    utf8::encode($s) unless utf8::downgrade($s, 1);
    return $s;
}

sub count_occ {
    my ($hay, $needle) = @_;
    return 0 if $needle eq '';
    my ($n, $p) = (0, 0);
    while ((my $i = index($hay, $needle, $p)) >= 0) { $n++; $p = $i + length($needle) }
    return $n;
}

sub splice_bytes {
    my ($hay, $old, $new, $all) = @_;
    my ($out, $p) = ('', 0);
    while ((my $i = index($hay, $old, $p)) >= 0) {
        $out .= substr($hay, $p, $i - $p) . $new;
        $p = $i + length($old);
        last unless $all;
    }
    return $out . substr($hay, $p);
}

sub read_bytes_or_m6 {
    my ($path, $abs, $tool) = @_;
    open(my $fh, '<', $path) or m6_payload($abs, $tool, "cannot read $path: $!");
    binmode($fh);
    my ($out, $buf) = ('', '');
    while (1) {
        my $n = sysread($fh, $buf, 65536);
        if (!defined $n) { close $fh; m6_payload($abs, $tool, "read error on $path: $!") }
        last if $n == 0;
        $out .= $buf;
    }
    close $fh;
    return $out;
}

sub deny_payload {
    my ($msg) = @_;
    emit_err($msg);
    exit 2;
}

sub m6_payload {
    my ($abs, $tool, $reason) = @_;
    my $what = ($tool // '') ne '' ? $tool : 'write';
    deny_payload("LEDGER-GUARD: BLOCKED ${EMDASH} cannot reconstruct the content this $what would leave in "
        . "$abs ($reason), so it cannot be validated, and an unvalidated ledger write is not permitted. "
        . 'Use Write with the full file content, or Edit with a non-empty old_string, then retry.');
}

sub validate_and_exit_payload {
    my ($abs, $bytes, $old_bytes) = @_;
    my $detail = validate_bytes($bytes);
    if (defined $detail) {
        deny_payload("LEDGER-GUARD: BLOCKED ${EMDASH} the content this write would leave in $abs $detail");
    }
    my $lu_detail = last_updated_check($old_bytes, $bytes);
    if (defined $lu_detail) {
        deny_payload("LEDGER-GUARD: BLOCKED ${EMDASH} the content this write would leave in $abs $lu_detail");
    }
    exit 0;
}

# Best-effort read of the CURRENT on-disk bytes at $abs, for the last_updated_check's
# monotonicity comparison only. Never fatal: an unreadable or absent prior file just
# means there is nothing to compare a Write's candidate value against (a fresh ledger
# has no "older" to violate) — reconstruction failures for Edit/MultiEdit are handled
# separately by read_bytes_or_m6, since THOSE tools need the prior bytes to even know
# what they would write.
sub try_read_bytes {
    my ($path) = @_;
    return undef unless -e $path;
    return eval {
        open(my $fh, '<:raw', $path) or die "open failed";
        local $/;
        my $b = <$fh>;
        close $fh;
        defined $b ? $b : '';
    };
}

sub op_validate_payload {
    my $ABS  = defined $ENV{LG_ABS}  ? $ENV{LG_ABS}  : '';
    my $TOOL = defined $ENV{LG_TOOL} ? $ENV{LG_TOOL} : '';

    binmode STDIN;
    my $raw = do { local $/; <STDIN> };
    $raw = '' unless defined $raw;
    my $payload = eval { JSON::PP->new->decode($raw) };
    if (!defined $payload || ref($payload) ne 'HASH') {
        m6_payload($ABS, $TOOL, 'payload is not a JSON object (decode failed or non-object)');
    }
    my $ti = $payload->{tool_input};
    $ti = {} unless ref($ti) eq 'HASH';

    if ($TOOL eq 'Write') {
        my $c = $ti->{content};
        m6_payload($ABS, $TOOL, 'Write payload has no string "content" field') unless is_str($c);
        validate_and_exit_payload($ABS, as_bytes($c), try_read_bytes($ABS));
    }
    elsif ($TOOL eq 'Edit') {
        exit 0 unless -e $ABS;
        my $orig = read_bytes_or_m6($ABS, $ABS, $TOOL);
        my ($old, $new) = ($ti->{old_string}, $ti->{new_string});
        m6_payload($ABS, $TOOL, 'Edit payload has no string old_string/new_string')
            unless is_str($old) && is_str($new);
        $old = as_bytes($old);
        $new = as_bytes($new);
        m6_payload($ABS, $TOOL, 'empty old_string') if $old eq '';
        my $all = $ti->{replace_all} ? 1 : 0;
        my $n   = count_occ($orig, $old);
        exit 0 if $n == 0;
        exit 0 if $n > 1 && !$all;
        validate_and_exit_payload($ABS, splice_bytes($orig, $old, $new, $all), $orig);
    }
    elsif ($TOOL eq 'MultiEdit') {
        my $edits = $ti->{edits};
        my $bad   = '"edits" is missing or is not a non-empty array of {old_string,new_string} objects';
        m6_payload($ABS, $TOOL, $bad) unless ref($edits) eq 'ARRAY' && @$edits;
        for my $e (@$edits) {
            m6_payload($ABS, $TOOL, $bad)
                unless ref($e) eq 'HASH' && is_str($e->{old_string}) && is_str($e->{new_string});
        }
        exit 0 unless -e $ABS;
        my $buf  = read_bytes_or_m6($ABS, $ABS, $TOOL);
        my $orig = $buf;
        for my $e (@$edits) {
            my $old = as_bytes($e->{old_string});
            my $new = as_bytes($e->{new_string});
            m6_payload($ABS, $TOOL, 'empty old_string') if $old eq '';
            my $all = $e->{replace_all} ? 1 : 0;
            my $n   = count_occ($buf, $old);
            exit 0 if $n == 0;
            exit 0 if $n > 1 && !$all;
            $buf = splice_bytes($buf, $old, $new, $all);
        }
        validate_and_exit_payload($ABS, $buf, $orig);
    }
    elsif ($TOOL eq 'NotebookEdit') {
        deny_payload("LEDGER-GUARD: BLOCKED ${EMDASH} NotebookEdit cannot target a package ledger ($ABS): "
            . 'a ledger is markdown, not a notebook. Use Edit or Write.');
    }
    else {
        m6_payload($ABS, $TOOL, $TOOL eq '' ? 'payload has no tool_name' : qq(unrecognised tool "$TOOL"));
    }
}

sub op_validate {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'stdin', 'payload'); }
    arg_error('validate', 'unrecognised option') unless $ok;
    arg_error('validate', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    my $n = (defined $opt{ledger} ? 1 : 0) + ($opt{stdin} ? 1 : 0) + ($opt{payload} ? 1 : 0);
    arg_error('validate', 'specify exactly one of --ledger, --stdin, --payload') unless $n == 1;

    if ($opt{payload}) { op_validate_payload(); return }

    my ($bytes, $label);
    if (defined $opt{ledger}) {
        $label = $opt{ledger};
        open(my $fh, '<:raw', $opt{ledger}) or io_error('validate', $opt{ledger}, "cannot read: $!");
        local $/;
        $bytes = <$fh>;
        close $fh;
        $bytes = '' unless defined $bytes;
    }
    else {
        binmode STDIN;
        local $/;
        $bytes = <STDIN>;
        $bytes = '' unless defined $bytes;
        $label = '(stdin)';
    }
    my $detail = validate_bytes($bytes);
    if (defined $detail) {
        emit_err("bp-ledger: validate: $label: $detail");
        exit 2;
    }
    # Static surface, no on-disk "before": only the future-skew half of the b19 check
    # applies here (monotonicity needs a prior value to compare against, which this
    # single-buffer surface has no notion of).
    my $lu_detail = last_updated_check(undef, $bytes);
    if (defined $lu_detail) {
        emit_err("bp-ledger: validate: $label: $lu_detail");
        exit 2;
    }
    exit 0;
}

# =====================================================================================
# `migrate-depends-on` — the repair path for a ledger the V-checks now refuse.
#
# Report 20260917-063908-db14. `blueprint/templates/blueprint.md` told the author
# that every listed package field is copied into the ledger's frontmatter, and
# listed `depends_on:` among them, while this script rejects that key on EVERY
# write. The two plugins disagreed and the authoring side won at create time, so
# blueprints authored before the rule landed carry the key in every ledger.
#
# That is worse than a normal refusal. The rejection covers `set-status`, which
# is the only sanctioned way a coordinator reaches a terminal state, so such a
# package cannot be finished, blocked OR parked -- and `stop-gate.sh` will not
# let the session end until it is. The prescribed remedy was an edit to the very
# frontmatter the protocol tells coordinators never to hand-edit: the escape
# hatch was also the thing the doctrine forbids. Measured blast radius: all five
# ledgers of one blueprint, with the rule activating MID-RUN after package 01
# had already reached done.
#
# WHY THIS CANNOT USE run_op. run_op validates the ORIGINAL bytes before calling
# the splice callback (:782) and rejects on failure -- which is the whole point
# of it, and exactly what makes it unable to repair a file whose stored form is
# already invalid. This op therefore owns its own lock/read/write, and its
# safety comes from the other end: it REFUSES unless removing `depends_on:` is
# sufficient to make the file valid. A ledger that is broken in some further way
# is left alone and reported, rather than half-repaired into a shape whose
# remaining fault is now harder to see.
# =====================================================================================

sub op_migrate_depends_on {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'dry-run'); }
    arg_error('migrate-depends-on', 'unrecognised option') unless $ok;
    arg_error('migrate-depends-on', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('migrate-depends-on', 'missing required --ledger') unless defined $opt{ledger};

    my $path = $opt{ledger};
    my $lockpath = "$path.lock";
    open(my $lk, '>', $lockpath)
        or io_error('migrate-depends-on', $path, "cannot open lock file $lockpath: $!");
    flock($lk, LOCK_EX)
        or io_error('migrate-depends-on', $path, "cannot acquire lock on $lockpath: $!");

    my $orig;
    {
        open(my $fh, '<:raw', $path)
            or io_error('migrate-depends-on', $path, "cannot read: $!");
        local $/;
        $orig = <$fh>;
        close $fh;
        $orig = '' unless defined $orig;
    }

    my ($FM) = $orig =~ /\A---\s*\n(.*?)\n---/s;
    unless (defined $FM) {
        reject_error('migrate-depends-on', $path,
            'has no parseable frontmatter block, so there is no `depends_on:` line to move. '
          . 'This op repairs exactly one fault; fix the frontmatter first.');
    }

    # Collect the edges being moved, in file order, before removing anything.
    my @edges;
    for my $l (split(/\n/, $FM, -1)) {
        next unless $l =~ /^depends_on:\s*(.*?)\s*$/;
        push @edges, $1;
    }
    unless (@edges) {
        emit_err("bp-ledger: migrate-depends-on: $path: no frontmatter depends_on: line; nothing to do.");
        exit 0;
    }

    # Remove the key from the frontmatter block ONLY. A `depends_on:` written in
    # the body -- inside a Dependency edges section, say, or quoted in an attempt
    # log entry -- is prose and must survive untouched, so the substitution is
    # scoped to the matched block rather than run over the whole file.
    my $new_fm = join("\n", grep { !/^depends_on:/ } split(/\n/, $FM, -1));
    my $new = $orig;
    substr($new, 0, length($FM) + 8) =~ s/\A---\s*\n\Q$FM\E\n---/---\n$new_fm\n---/
        or reject_error('migrate-depends-on', $path, 'could not rewrite the frontmatter block');

    # Record the edge where it belongs. Appended, never merged into an existing
    # section body, so a hand-written Dependency edges section keeps its prose and
    # the migrated value sits beside it plainly marked as migrated.
    my $edge_txt = join(', ', map { length($_) ? $_ : '(empty)' } @edges);
    my $note = "\n## Dependency edges\n\n"
             . "- Migrated from frontmatter `depends_on:` by `bp-ledger.pl migrate-depends-on`: $edge_txt\n"
             . "  The scheduler builds its DAG from blueprint.md's package-status table; this is the record of what the ledger used to claim, kept so the edge and its reason are not lost.\n";
    if ($new =~ /^##\s+Dependency edges\b/m) {
        $new =~ s/(^##\s+Dependency edges\b[^\n]*\n)/$1\n- Migrated from frontmatter `depends_on:` by `bp-ledger.pl migrate-depends-on`: $edge_txt\n/m;
    }
    else {
        $new =~ s/\s*\z//;
        $new .= "\n$note";
    }

    # THE SAFETY PROPERTY. Removing the key must be SUFFICIENT. If the file is
    # still invalid afterwards it was broken in some further way, and a partial
    # repair would leave a harder problem wearing a "migrated" label.
    my $detail = validate_bytes($new);
    if (defined $detail) {
        reject_error('migrate-depends-on', $path,
            "removing depends_on: is not sufficient -- the ledger is still invalid: $detail "
          . 'Nothing was written. Fix the remaining fault, then re-run.');
    }
    my $lu_detail = last_updated_check($orig, $new);
    reject_error('migrate-depends-on', $path, $lu_detail) if defined $lu_detail;

    if ($opt{'dry-run'}) {
        print "bp-ledger: migrate-depends-on: $path: would move depends_on: $edge_txt\n";
        exit 0;
    }

    my $tmp = "$path.tmp.$$";
    open(my $w, '>:raw', $tmp)
        or io_error('migrate-depends-on', $path, "cannot open temp file $tmp: $!");
    print {$w} $new
        or do { close $w; unlink $tmp; io_error('migrate-depends-on', $path, "write to $tmp failed: $!") };
    close($w)
        or do { unlink $tmp; io_error('migrate-depends-on', $path, "close $tmp failed: $!") };
    unless ($RENAME_FN->($tmp, $path)) {
        unlink $tmp;
        io_error('migrate-depends-on', $path, "rename $tmp -> $path failed: $!");
    }
    print "bp-ledger: migrate-depends-on: $path: moved depends_on: $edge_txt\n";
    exit 0;
}

# =====================================================================================
# op_create — 04-model-effort-ledger-validation §2.1. The tenth verb, and the
# only one that CREATES a file rather than splicing an existing one -- so, like
# bp-blueprint.pl's op_init (the shape this mirrors), it owns its own
# lock/temp/rename/read-back and cannot go through run_op (run_op:1148ff slurps
# and validates the TARGET first, which cannot work when there is no target
# yet).
#
# Renders plugins/blueprint/templates/package-ledger.md into a real, clean,
# validate()-passing ledger: drops every `#`-comment frontmatter line (D-E),
# substitutes the ten frontmatter keys in template order, and rewrites the
# `# Package <NN-slug> — <title>` body title line. Nothing is written to disk
# until the fully-rendered bytes pass validate_bytes() AND last_updated_check()
# -- `create` must never be able to produce a ledger its own `validate` verb
# would reject (AC-9).
# =====================================================================================

# dirname(), core-Perl only (mirrors ensure_dir_exists' own no-File::Path
# discipline, §2.5): '' when $p has no directory component, else the parent.
sub op_create_dirname {
    my ($p) = @_;
    return '' unless defined $p && length $p;
    (my $d = $p) =~ s{[\\/][^\\/]*\z}{};
    return $d eq $p ? '' : $d;
}

sub op_create {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt,
            'ledger=s', 'package=s', 'blueprint=s', 'template=s', 'write-set=s',
            'test-paths=s', 'checks=s', 'model=s', 'effort=s', 'max-turns=s', 'title=s'); }

    # Rule 1 — unrecognised option / extra args / missing required option.
    arg_error('create', 'unrecognised option') unless $ok;
    arg_error('create', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(ledger package blueprint template write-set)) {
        arg_error('create', "missing required --$r") unless defined $opt{$r};
    }

    # Rule 2 — every SUPPLIED value must survive the frontmatter's single-line
    # `key: value` shape. Iterates only keys GetOptionsFromArray actually set,
    # so an unsupplied optional field (default-filled below) is never checked
    # against a value it never carried.
    for my $k (sort keys %opt) {
        next unless defined $opt{$k};
        next if field_safe($opt{$k});
        arg_error('create', "--$k contains a pipe or newline");
    }

    # Rule 3 — --package shape: NN-slug.
    unless ($opt{package} =~ /\A[0-9]{2}-[a-z0-9]+(?:-[a-z0-9]+)*\z/) {
        arg_error('create', "--package '$opt{package}' is not NN-slug shaped "
                           . '(two digits, a hyphen, then lowercase kebab-case)');
    }
    # Rule 4 — --blueprint shape: kebab-case.
    unless ($opt{blueprint} =~ /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/) {
        arg_error('create', "--blueprint '$opt{blueprint}' is not kebab-case (a-z, 0-9, single hyphens)");
    }
    # Rule 5 — --max-turns shape, only when supplied (unsupplied -> default 800).
    if (defined $opt{'max-turns'} && $opt{'max-turns'} !~ /\A[1-9][0-9]*\z/) {
        arg_error('create', "--max-turns '$opt{'max-turns'}' is not a positive integer");
    }

    my $model      = defined $opt{model}         ? $opt{model}         : 'sonnet';
    my $effort     = defined $opt{effort}        ? $opt{effort}        : 'medium';
    my $max_turns  = defined $opt{'max-turns'}   ? $opt{'max-turns'}   : 800;
    my $test_paths = defined $opt{'test-paths'}  ? $opt{'test-paths'}  : '';
    my $checks     = defined $opt{checks}        ? $opt{checks}        : '';
    my $title      = defined $opt{title}         ? $opt{title}         : $opt{package};

    # Rule 6 — --model against @MODELS. Exit 2, not 3 (D-D): the argument is
    # well-formed; what is refused is the LEDGER CONTENT the call would produce.
    unless (grep { $_ eq $model } @MODELS) {
        emit_err("bp-ledger: create: model \"$model\" is not a supported model; "
               . 'allowed values: ' . join(', ', @MODELS));
        exit 2;
    }
    # Rule 7 — --effort against @EFFORTS. Same exit-2 reasoning as rule 6.
    unless (grep { $_ eq $effort } @EFFORTS) {
        emit_err("bp-ledger: create: effort \"$effort\" is not a supported effort; "
               . 'allowed values: ' . join(', ', @EFFORTS));
        exit 2;
    }

    # Rule 8 — refuse rather than overwrite (mirrors op_init:503-506).
    if (-e $opt{ledger}) {
        reject_error('create', $opt{ledger},
            "already exists -- refusing to overwrite an existing ledger. Use the typed verbs "
          . '(set-status, append-attempt, tick-step, set-next-action, add-output) to modify it.');
    }

    # Rule 9 — template must be readable.
    my $tpl;
    {
        open(my $fh, '<:raw', $opt{template}) or io_error('create', $opt{template}, "cannot read: $!");
        local $/;
        $tpl = <$fh>;
        close $fh;
        $tpl = '' unless defined $tpl;
    }

    # Rule 10 — the template must carry a \A--- frontmatter block with all ten
    # keys. Same \A---...--- anchor validate_bytes' V2 uses (byte 0, non-greedy).
    unless ($tpl =~ /\A---\s*\n(.*?)\n---/s) {
        reject_error('create', $opt{template},
            'has no parseable \A--- frontmatter block; refusing to guess its shape');
    }
    my $fm_content = $1;
    my $body       = substr($tpl, $+[0]);

    # Rendering (spec §2.1 "Rendering"): drop every `#`-comment frontmatter
    # line, then substitute the ten keys, IN TEMPLATE ORDER, into whatever
    # (non-comment) lines remain.
    my @fm_lines = grep { !/^\s*#/ } split(/\n/, $fm_content, -1);
    my @KEY_ORDER = qw(package blueprint status model effort max_turns
                        write_set test_paths checks last_updated);
    my %values = (
        package      => $opt{package},
        blueprint    => $opt{blueprint},
        status       => 'pending',
        model        => $model,
        effort       => $effort,
        max_turns    => $max_turns,
        write_set    => $opt{'write-set'},
        test_paths   => $test_paths,
        checks       => $checks,
        last_updated => iso_now(),
    );
    my @missing_keys;
    for my $k (@KEY_ORDER) {
        my $found = 0;
        for my $i (0 .. $#fm_lines) {
            if ($fm_lines[$i] =~ /^\Q$k\E:/) {
                $fm_lines[$i] = length($values{$k}) ? "$k: $values{$k}" : "$k:";
                $found = 1;
                last;
            }
        }
        push @missing_keys, $k unless $found;
    }
    if (@missing_keys) {
        reject_error('create', $opt{template},
            'is missing required frontmatter key(s): ' . join(', ', @missing_keys) . '.');
    }

    # Body: verbatim except the title line (D-E / B-6).
    $body =~ s/^# Package\b.*$/# Package $opt{package} $EMDASH $title/m;

    my $rendered = "---\n" . join("\n", @fm_lines) . "\n---" . $body;

    # Rule 11 — `create` must never produce a ledger its own `validate` verb
    # would reject (AC-9).
    my $detail = validate_bytes($rendered);
    reject_error('create', $opt{ledger}, $detail) if defined $detail;
    my $lu_detail = last_updated_check(undef, $rendered);
    reject_error('create', $opt{ledger}, $lu_detail) if defined $lu_detail;

    # Rule 12 — write discipline mirroring op_init: make_path, lock, re-check
    # under the lock, temp + rename (via the injected $RENAME_FN test seam),
    # read-back, unlock.
    my $dir = op_create_dirname($opt{ledger});
    if (length($dir) && !-d $dir) {
        unless (ensure_dir_exists($dir)) {
            io_error('create', $opt{ledger}, "cannot create directory $dir: $!");
        }
    }

    my $lockpath = "$opt{ledger}.lock";
    open(my $lk, '>', $lockpath) or io_error('create', $opt{ledger}, "cannot open lock file $lockpath: $!");
    flock($lk, LOCK_EX) or io_error('create', $opt{ledger}, "cannot acquire lock on $lockpath: $!");

    if (-e $opt{ledger}) {
        close $lk;
        reject_error('create', $opt{ledger}, "already exists (created concurrently) -- refusing to overwrite");
    }

    my $tmp = "$opt{ledger}.tmp.$$";
    open(my $w, '>:raw', $tmp) or do {
        close $lk; io_error('create', $opt{ledger}, "cannot open temp file $tmp: $!") };
    print {$w} $rendered or do {
        close $w; unlink $tmp; close $lk; io_error('create', $opt{ledger}, "write to $tmp failed: $!") };
    close($w) or do {
        unlink $tmp; close $lk; io_error('create', $opt{ledger}, "close $tmp failed: $!") };
    unless ($RENAME_FN->($tmp, $opt{ledger})) {
        unlink $tmp;
        close $lk;
        io_error('create', $opt{ledger}, "rename $tmp -> $opt{ledger} failed: $!");
    }

    my $after;
    {
        open(my $rfh, '<:raw', $opt{ledger}) or do {
            unlink $opt{ledger}; close $lk;
            io_error('create', $opt{ledger}, "read-back: cannot read: $!") };
        local $/;
        $after = <$rfh>;
        close $rfh;
        $after = '' unless defined $after;
    }
    unless ($after eq $rendered) {
        unlink $opt{ledger};
        close $lk;
        io_error('create', $opt{ledger}, "value did not survive the write");
    }

    flock($lk, LOCK_UN);
    close($lk);
    exit 0;
}

# =====================================================================================
# `migrate-oracle` (01-compact-oracle-records spec §2.8) -- the ONLY thing that converts
# a long-form oracle record to compact. Implemented manually (not via run_op) because a
# failed sidecar write must exit 4 (io_error) with the ledger left byte-identical, which
# run_op's splice-callback shape (undef/reason -> exit 5) cannot express.
# =====================================================================================

sub op_migrate_oracle {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'dry-run'); }
    arg_error('migrate-oracle', 'unrecognised option') unless $ok;
    arg_error('migrate-oracle', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('migrate-oracle', 'missing required --ledger') unless defined $opt{ledger};
    my $ledger  = $opt{ledger};
    my $dry_run = $opt{'dry-run'} ? 1 : 0;

    my $lockpath = "$ledger.lock";
    open(my $lk, '>', $lockpath) or io_error('migrate-oracle', $ledger, "cannot open lock file $lockpath: $!");
    flock($lk, LOCK_EX) or io_error('migrate-oracle', $ledger, "cannot acquire lock on $lockpath: $!");

    my $orig;
    {
        open(my $fh, '<:raw', $ledger) or io_error('migrate-oracle', $ledger, "cannot read: $!");
        local $/;
        $orig = <$fh>;
        close $fh;
        $orig = '' unless defined $orig;
    }

    my $detail = validate_bytes($orig);
    reject_error('migrate-oracle', $ledger, $detail) if defined $detail;

    # S6 (Decision 13 review ruling): the future-dated last_updated check applies even
    # when there turn out to be zero records to convert -- it must not be skipped just
    # because the early-exit branches below never reach the later last_updated_check
    # against $new_bytes.
    my $lu_detail0 = last_updated_check($orig, $orig);
    reject_error('migrate-oracle', $ledger, $lu_detail0) if defined $lu_detail0;

    my @raw = parse_oracle_records($orig);
    my $total = scalar @raw;
    my $sidecar_path = oracle_sidecar_path($ledger);

    my $print_and_exit0 = sub {
        my ($verb, $n, $before, $after) = @_;
        print "bp-ledger: migrate-oracle: $ledger: $verb $n of $total oracle records; "
            . "$before -> $after bytes; sidecar $sidecar_path\n";
        flock($lk, LOCK_UN);
        close($lk);
        exit 0;
    };

    unless ($total) {
        $print_and_exit0->($dry_run ? 'would compact' : 'compacted', 0, length($orig), length($orig));
    }

    my @old_sidecar = read_sidecar_entries($sidecar_path);

    my (@final, %new_backing);
    my $n = 0;
    for my $r (@raw) {
        if (is_compact_record($r) || !defined($r->{step}) || !defined($r->{path})) {
            push @final, $r;
            next;
        }
        my $compact = compact_oracle_record($r);
        push @final, $compact;
        $new_backing{ canonical_json_encode($compact) } = $r;   # verbatim (spec §2.8 step 2)
        $n++;
    }

    if ($n == 0) {
        $print_and_exit0->($dry_run ? 'would compact' : 'compacted', 0, length($orig), length($orig));
    }

    my @lines = map { encode_oracle_record($_) } @final;
    my $new_bytes = insert_or_replace_oracle_section($orig, @lines);

    my $detail2 = validate_bytes($new_bytes);
    reject_error('migrate-oracle', $ledger, $detail2) if defined $detail2;
    my $ref_detail = validate_no_new_ref_addr($orig, $new_bytes);
    reject_error('migrate-oracle', $ledger, $ref_detail) if defined $ref_detail;
    my $lu_detail = last_updated_check($orig, $new_bytes);
    reject_error('migrate-oracle', $ledger, $lu_detail) if defined $lu_detail;

    if ($dry_run) {
        $print_and_exit0->('would compact', $n, length($orig), length($new_bytes));
    }

    my @retention = build_sidecar_retention(
        new_records => \@final, new_backing => \%new_backing,
        old_bytes   => $orig,   old_sidecar => \@old_sidecar);
    unless (write_oracle_sidecar($sidecar_path, @retention)) {
        io_error('migrate-oracle', $ledger, "cannot write sidecar $sidecar_path: $!");
    }

    my $tmp = "$ledger.tmp.$$";
    open(my $w, '>:raw', $tmp) or io_error('migrate-oracle', $ledger, "cannot open temp file $tmp: $!");
    print {$w} $new_bytes or do { close $w; unlink $tmp; io_error('migrate-oracle', $ledger, "write to $tmp failed: $!") };
    close($w) or do { unlink $tmp; io_error('migrate-oracle', $ledger, "close $tmp failed: $!") };
    unless ($RENAME_FN->($tmp, $ledger)) {
        unlink $tmp;
        io_error('migrate-oracle', $ledger, "rename $tmp -> $ledger failed: $!");
    }

    my $after;
    {
        open(my $rfh, '<:raw', $ledger) or io_error('migrate-oracle', $ledger, "read-back: cannot read: $!");
        local $/;
        $after = <$rfh>;
        close $rfh;
        $after = '' unless defined $after;
    }
    unless ($after eq $new_bytes) {
        io_error('migrate-oracle', $ledger, "value did not survive the write");
    }

    $print_and_exit0->('compacted', $n, length($orig), length($new_bytes));
}

# =====================================================================================
# Main
# =====================================================================================

my %DISPATCH = (
    'set-status'      => \&op_set_status,
    'migrate-depends-on' => \&op_migrate_depends_on,
    'append-attempt'   => \&op_append_attempt,
    'tick-step'        => \&op_tick_step,
    'set-next-action'  => \&op_set_next_action,
    'add-output'       => \&op_add_output,
    'set-escalation'   => \&op_set_escalation,
    'widen-write-set'  => \&op_widen_write_set,
    'set-write-set'    => \&op_set_write_set,
    'set-test-paths'   => \&op_set_test_paths,
    'set-checks'       => \&op_set_checks,
    'set-section'      => \&op_set_section,
    'rotate'           => \&op_rotate,
    'validate'         => \&op_validate,
    'claim-check'      => \&op_claim_check,
    'migrate-oracle'   => \&op_migrate_oracle,
    'create'           => \&op_create,
);

# Guarded so ledger-guard.sh's embedded validator (b19) can `require` this file for
# its shared last_updated_check() without also running this CLI — the same
# requirable-module shape bp-orchestrator.pl already uses.
unless (caller) {
    my $sub = shift @ARGV;
    if (!defined $sub || $sub eq '') {
        arg_error('(none)', 'missing subcommand; expected one of: '
            . join(', ', sort keys %DISPATCH));
    }
    unless (exists $DISPATCH{$sub}) {
        arg_error($sub, "unknown subcommand '$sub'; expected one of: " . join(', ', sort keys %DISPATCH));
    }
    $DISPATCH{$sub}->(@ARGV);
    exit 0;
}

1;
