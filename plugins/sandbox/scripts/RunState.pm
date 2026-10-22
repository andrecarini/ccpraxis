package RunState;
# RunState.pm — pure orchestrator/run-state summarizer for the dashboard.
#
# Walks a blueprints root (`<project>/.ccpraxis-local-data/blueprints/`) and
# builds one summary struct per blueprint that has a decodable
# `runs/registry.json`, cross-referencing the run markers (`.orchestrator`,
# `.paused`, `.shutdown`), the `needs-you/` decision queue, and each
# package's ledger frontmatter `status:` line (authoritative over the
# registry's own `status`) — spec `07-run-state-panel-spec.md`, s10 of
# blueprint sandbox-butler-overhaul.
#
# Pure, in the SessionFilter sense: no console I/O (no print/warn/die), no
# spawning, no writes, no globals mutated. Read-only, and only under the
# root/dir it is handed. Total: every public sub returns its declared type
# for every input, including undef, refs where scalars are expected, hostile
# bytes, symlinks, unreadable files and malformed JSON — nothing propagates
# an exception; all decoding happens inside eval {}.
#
# Discovery uses opendir/readdir — glob is forbidden anywhere in this file —
# so a project path containing spaces or non-ASCII bytes (André) is safe.
# Nothing is exported; callers use fully-qualified names
# (RunState::summarize(...)), exactly as launcher.pl calls SessionFilter:: /
# BackpackApproval::. No time()/localtime/gmtime/clock read.
#
# 04-run-panel-ledger-truth (Decision 3): RunState performs NO process probe
# itself and contains no `kill` -- it delegates coordinator-PID liveness to a
# caller-injected coderef, $RunState::PID_ALIVE, installed by launcher.pl
# (the impure kill(0,...) syscall lives there, never here). RunState is total
# against a prober that dies, returns undef, or returns anything hostile at
# all -- see _pid_state(). Progress (packages_total/packages_done/
# current_package) is derived from packages/*.md ledgers whenever at least
# one candidate ledger exists; runs/registry.json is consulted only as the
# per-package status fallback and, after a liveness check, for
# running_coordinators.
#
# See specs/07-run-state-panel-spec.md (S2) for the full field-by-field
# contract; the struct's 11-key set is CLOSED and stable (s11 depends on it).

use strict;
use warnings;
use JSON::PP ();
# No Time::Local: this module reads no clock, and Time::Local calls one at load
# (redteam L1). Every epoch this file produces comes from a byte already on disk
# (a log record's own `at:` field) via _utc_epoch's plain arithmetic.

our $MAX_REGISTRY_BYTES = 4 * 1024 * 1024;   # 4 MiB, mirrors SessionFilter
our $MAX_LEDGER_BYTES   = 65536;             # 64 KiB of a package ledger is plenty for frontmatter
our $MAX_MARKER_BYTES   = 4096;              # .orchestrator / .paused are tiny
our $MAX_PACKAGES       = 512;               # a registry (or ledger set) with more package keys
                                              # than this is treated as unreadable (falls back /
                                              # skips the blueprint), same degradation the byte
                                              # caps above already use
our $MAX_DISPATCH_RECORDS = 512;             # 05-runstate-agent-aggregation (spec S2.9): candidate
                                              # *.json entries in the dispatch log. Over this,
                                              # _dispatch_index returns {} (every blueprint reports
                                              # agents => [], no error, no partial answer -- Decision
                                              # 9's "an over-cap set degrades to NO row rather than a
                                              # fabricated one").

# package 13-dashboard-threads (specs/13-dashboard-threads-spec.md S2.2):
# bounds for the thread/thread_events surface, same "over cap degrades to
# nothing fabricated" discipline as $MAX_DISPATCH_RECORDS above.
our $MAX_THREAD_EVENTS = 10;          # mirrors launcher.pl's $ORCH_EVENTS_PER_LOG
our $MAX_THREAD_RECORDS = 512;        # .md entries in almanac/thread/
our $MAX_THREAD_TASKS = 512;          # .md entries in one thread-tasks-<name>/
our $MAX_ALMANAC_RECORD_BYTES = 65536;   # bytes read from one almanac record file
our $MAX_INDEX_LINK_RESOLUTIONS = 8192;  # redteam M2: global cap on linked-task
                                          # ledger lookups per _thread_index call
                                          # (worst case otherwise 512 threads x
                                          # 512 tasks); the per-call cache keeps
                                          # repeats of the same link free
our $FUTURE_EVENT_SLACK_SECONDS = 300;   # redteam M3: an `at:` more than this
                                          # far past its log file's mtime is
                                          # dropped rather than trusted, so a
                                          # thread can't plant future-dated
                                          # events to permanently fill the
                                          # project-wide newest-10 feed

# $PID_ALIVE: CODE ref | undef. Injected by the caller (launcher.pl). NEVER
# set or probed by RunState itself -- see _pid_state() below.
our $PID_ALIVE;

# _read_capped($path, $cap) -> $bytes|undef (private)
#
# Reads a plain file, capped at $cap+1 bytes so an over-cap file is detected
# without slurping it whole. Returns undef for: not a plain file, a symlink
# (extends blueprint_dirs' -l skip one level down), open failure, empty
# file, or a file whose length exceeds $cap ("a file larger than its cap is
# treated exactly as an unreadable file"). Used for the registry and the
# 4 KiB markers, where reject-on-oversize is the WANTED behaviour (an
# oversized marker is itself suspicious; a truncated JSON blob can't be
# partially parsed) -- NOT for ledgers, see _read_head below
# (04-run-panel-ledger-truth consolidated fix-batch).
sub _read_capped {
    my ($path, $cap) = @_;
    return undef unless defined $path && -f $path;
    return undef if -l $path;
    open my $fh, '<:raw', $path or return undef;
    my $blob = '';
    my $n = read($fh, $blob, $cap + 1);
    close $fh;
    return undef if !defined $n || $n == 0 || $n > $cap;
    return $blob;
}

# _read_head($path, $cap) -> $bytes|undef (private)
#
# Reads the first $cap bytes of a plain, non-symlink file. Unlike
# _read_capped, an over-cap file is NOT rejected -- its first $cap bytes are
# returned instead ("64 KiB of a package ledger is plenty for frontmatter";
# a ledger grows without bound by design, and the only thing ever needed
# from it is the frontmatter near the top). Returns '' (defined, not undef)
# for a genuinely empty file -- the caller needs to distinguish "empty" from
# "unreadable". Returns undef only for: not a plain file, a symlink, or an
# open failure. 04-run-panel-ledger-truth consolidated fix-batch (the
# oversized-ledger defect: reject-on-oversize applied to ledgers silently
# fell through to the stale registry for any ledger over 64 KiB).
sub _read_head {
    my ($path, $cap) = @_;
    return undef unless defined $path && -f $path;
    return undef if -l $path;
    open my $fh, '<:raw', $path or return undef;
    my $blob = '';
    read($fh, $blob, $cap);
    close $fh;
    return $blob;
}

# _looks_like_frontmatter($blob) -> 0|1 (private)
#
# MEDIUM-5: used ONLY to decide ledger-set MEMBERSHIP (candidacy), never to
# parse a status -- see _ledger_status, which keeps its own strict, non-
# tolerant '---' check unchanged (04-run-panel-ledger-truth consolidated
# fix-batch report explains why the two must diverge). undef/zero-length
# blob -> 1 (ambiguous/unreadable -> never demote a candidate on that
# basis). Otherwise: strip a leading UTF-8 BOM, split on "\n", skip leading
# blank lines (an empty string or a bare "\r"), strip a trailing "\r" from
# the first non-blank line, and require it to equal exactly '---'.
sub _looks_like_frontmatter {
    my ($blob) = @_;
    return 1 unless defined $blob;
    return 1 unless length $blob;
    my $b = $blob;
    $b =~ s/\A\xEF\xBB\xBF//;
    my @lines = split /\n/, $b, -1;
    my $i = 0;
    $i++ while $i <= $#lines && $lines[$i] =~ /\A\r?\z/;
    return 0 unless defined $lines[$i];
    (my $l = $lines[$i]) =~ s/\r\z//;
    return $l eq '---' ? 1 : 0;
}

# blueprint_dirs($blueprints_root) -> @dirs
#
# Enumerates candidate blueprint directories one level deep, mirroring
# SessionFilter::registry_paths. undef/zero-length/non-existent-dir root ->
# (). opendir failure -> (). Skips . and .., skips symlinks, skips non-dirs.
# Returns "$root/$entry" in ascending sort order of the entry name. Never
# dies.
sub blueprint_dirs {
    my ($root) = @_;
    return () unless defined $root && !ref($root) && length($root) && -d $root;
    opendir(my $dh, $root) or return ();
    my @out;
    for my $e (sort readdir $dh) {
        next if $e eq '.' || $e eq '..';
        next if -l "$root/$e";
        next unless -d "$root/$e";
        push @out, "$root/$e";
    }
    closedir $dh;
    return @out;
}

# _safe_pkg_name($pkg) -> 0|1 (private)
#
# A package key is "safe" (eligible for a packages/<pkg>.md ledger read) iff
# it is a defined, non-ref scalar containing none of '/', '\', ':', NUL; does
# not begin with '.'; is no longer than 128 bytes; and is not a Windows
# reserved device name (CON/PRN/AUX/NUL/COM1-9/LPT1-9, with or without an
# extension) -- defense in depth for the repo's documented primary host, in
# case a future filesystem layer ever makes "$pkg.md" resolve to a device
# rather than a regular file. Anything else falls through to the registry
# status without ever attempting an open().
sub _safe_pkg_name {
    my ($pkg) = @_;
    return 0 unless defined $pkg && !ref($pkg) && length($pkg);
    return 0 if $pkg =~ /[\/\\\x00]/;
    return 0 if $pkg =~ /^\./;
    return 0 if length($pkg) > 128;
    return 0 if $pkg =~ /:/;
    return 0 if $pkg =~ /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|\z)/i;
    return 1;
}

# _normalize_status($raw) -> $status (private)
#
# Trims leading/trailing whitespace, lowercases. Accepts only
# /^[a-z][a-z0-9_-]{0,31}$/; anything else (undef, a ref, '', "12", a 200-
# char blob) becomes the unknown status ''. Rejects anything over 64 bytes
# before trimming (the accept regex tops out at 32 chars anyway; the length
# guard also sidesteps CVE-class quadratic-backtracking risk in the trim
# below by bounding its input) and uses two anchored, non-/g substitutions
# rather than a /g-driven alternation, so the trim is O(n) rather than O(n^2)
# on an interior whitespace run.
sub _normalize_status {
    my ($raw) = @_;
    return '' if !defined $raw || ref $raw;
    return '' if length($raw) > 64;
    $raw =~ s/\A\s+//;
    $raw =~ s/\s+\z//;
    $raw = lc $raw;
    return ($raw =~ /^[a-z][a-z0-9_-]{0,31}$/) ? $raw : '';
}

# _ledger_status($blueprint_dir, $pkg) -> $status (private, '' when none)
#
# Reads the first $MAX_LEDGER_BYTES of "$blueprint_dir/packages/$pkg.md" (a
# HEAD read, not a reject-on-oversize -- see _read_head; 04-run-panel-
# ledger-truth consolidated fix-batch closed the oversized-ledger defect
# this way, since _ledger_status already stops at the closing '---', so a
# truncated tail is harmless). The ledger read is skipped entirely (no open
# attempted) for an unsafe $pkg. The file must begin with a line that is
# EXACTLY '---' (deliberately strict, no BOM/CRLF/leading-blank tolerance --
# that tolerance exists only in _looks_like_frontmatter for MEMBERSHIP, not
# here, see that sub's comment); subsequent lines are scanned until the next
# line that is exactly '---' or EOF; within that block, the first line
# matching /^status:[ \t]*(.*)$/ supplies the raw status (trimming is left
# to _normalize_status, which does it with two anchored non-/g substitutions
# rather than the ambiguous-quantifier /^status:\s*(.*?)\s*$/ shape, which is
# quadratic on an interior whitespace run).
sub _ledger_status {
    my ($blueprint_dir, $pkg) = @_;
    return '' unless _safe_pkg_name($pkg);
    my $blob = _read_head("$blueprint_dir/packages/$pkg.md", $MAX_LEDGER_BYTES);
    return '' unless defined $blob && length $blob;
    my @lines = split /\n/, $blob, -1;
    return '' unless @lines && $lines[0] eq '---';
    my $raw_status;
    for (my $i = 1; $i <= $#lines; $i++) {
        my $line = $lines[$i];
        last if $line eq '---';
        next if length($line) > 1024;
        if (!defined $raw_status && $line =~ /^status:[ \t]*(.*)$/) {
            $raw_status = $1;
        }
    }
    return _normalize_status($raw_status);
}

# _effective_status($blueprint_dir, $pkg, $entry, $ledger_present) -> $status (private)
#
# S2.5 + 04-run-panel-ledger-truth consolidated fix-batch (HIGH-2 governing
# rule): the ledger's normalised status wins whenever it is non-empty.
# s02-registry-runtime-only (Decision 13, binding, not optional): the
# registry's 'status' field is never consulted, present or absent, ledger
# file present or not -- butler no longer writes it, so a legacy/stale copy
# on disk must never be adopted as a fallback. When the ledger yields no
# status ('' -- over-cap, CRLF, BOM, malformed, no status: line, no ledger
# file at all, whatever the cause), the package is honestly '' (neither done
# nor running). Under-reporting is honest; adopting a contradicting or stale
# registry value is not.
sub _effective_status {
    my ($blueprint_dir, $pkg, $entry, $ledger_present) = @_;
    my $ledger_status = _ledger_status($blueprint_dir, $pkg);
    return $ledger_status if length $ledger_status;
    return '';   # registry.status carries no authority (Decision 13) -- s02, butler no longer writes it
}

# _orchestrator_pid($path) -> $pid|undef (private)
#
# The leading integer at the very start of the (capped) file content, or
# undef when the file is absent, unreadable, over cap, or does not itself
# begin with a bare digit run. Anchored to \A and bounded to 1-10 digits
# with a trailing (?!\d) so an over-long run is REJECTED rather than
# truncated to a plausible-looking wrong PID -- 04-run-panel-ledger-truth
# consolidated fix-batch (HIGH-3 / reviewer MINOR / LOW-15): the previous
# unanchored /(\d{1,10})/ fabricated PIDs out of ordinary content (a JSON
# blob's embedded "pid" field, a header comment's date, a negative marker's
# magnitude with the sign silently dropped), and disagreed with
# bp-orchestrator.pl's own anchored /^(\d+)/ reader of the SAME file. This
# matches that reader's domain: undef for anything whose first bytes are not
# themselves a bare digit run (S2.2 promises a Perl integer, not a float,
# hence the 10-digit bound rather than an unbounded \d+).
sub _orchestrator_pid {
    my ($path) = @_;
    my $blob = _read_capped($path, $MAX_MARKER_BYTES);
    return undef unless defined $blob;
    return ($blob =~ /\A(\d{1,10})(?!\d)/) ? ($1 + 0) : undef;
}

# _paused_info($path) -> ($paused_manual, $paused_reason) (private)
#
# $paused_manual is 1 iff the (capped) file decodes as a HASH whose 'manual'
# key is truthy; 0 otherwise (missing file, unreadable, over cap, malformed
# JSON, non-HASH, or falsy 'manual'). $paused_reason is the 'reason' field
# only when it is a defined, non-ref, non-empty scalar; else undef. Note
# this is independent of `state` classification (S2.3 is existence-only).
sub _paused_info {
    my ($path) = @_;
    my $blob = _read_capped($path, $MAX_MARKER_BYTES);
    return (0, undef) unless defined $blob;
    local $@;
    my $data = eval { JSON::PP->new->decode($blob) };
    return (0, undef) unless ref($data) eq 'HASH';
    my $manual = $data->{manual} ? 1 : 0;
    my $reason = $data->{reason};
    $reason = (defined($reason) && !ref($reason) && length($reason)) ? $reason : undef;
    return ($manual, $reason);
}

# ===========================================================================
# t07-needs-you-lifecycle. Operator, verbatim: "the TUI for GSA says 'needs
# you: 1 decision waiting' despite the agent that was working on it doesn't
# really have anything that needs my attention?"
#
# COUNTING FILES IN A DIRECTORY IS NOT A LIFECYCLE, and that was the whole
# defect. Eight scripts write into runs/needs-you/ and exactly ONE narrow path
# clears them (bp-answer-escalation.pl's clear_pkg_decisions, and only for a
# direct package reset). Everything else -- a package that finished normally, a
# run that ended, a fleet question the operator resolved some other way --
# leaves its file behind forever, and the panel keeps asking.
#
# THE FAILURE DIRECTION IS NOT SYMMETRIC (done-criterion 4). A decision wrongly
# kept is a panel that nags. A decision wrongly dropped is a human who is never
# asked. So every rule below is conservative BY CONSTRUCTION: a record is live
# unless something demonstrably settled it, and every unreadable, malformed,
# ambiguous or unrecognised case counts as live.
#
# A decision is SETTLED only when the thing it was blocking is demonstrably
# finished:
#
#   1. Its package's ledger says `done` or `dropped`. That is not a new
#      judgement -- it is the SAME set bp-orchestrator.pl's %DECISION_VALIDITY
#      already uses to REFUSE FILING one of these. If a package being done
#      means "do not file this", then a decision filed earlier and now done is
#      equally moot. The symmetry is the argument.
#
#   2. Or the RUN ITSELF is over: no live orchestrator and no .paused marker.
#      A decision blocking a run that has finished cannot still be blocking it.
#      This is what covers the fleet-family kinds (reauth, contract-drift,
#      broken-env), which name no real package.
#
# WHY NOT SIMPLY "no .paused means settled": some kinds are filed WITHOUT
# pausing the run, so a rule keyed on .paused alone would read them as settled
# the instant they were written -- silently dropping a real pending decision,
# which is precisely the direction done-criterion 4 forbids. Requiring the run
# to be over as well is what makes rule 2 safe.
# ===========================================================================

# The ledger statuses that settle a package-scoped decision. Deliberately NOT
# including 'blocked' or 'parked': those are exactly the states that mean a
# human is still needed.
my %SETTLED_STATUS = map { $_ => 1 } qw(done dropped);

# decision_live(\%rec, $blueprint_dir, $runs_dir, $run_over) -> 1 | 0. PUBLIC
# and pure (one small file read at most, no writes, no clock, never dies).
#
# $run_over is supplied by the caller rather than derived here, because
# deciding whether a run is over needs the orchestrator-pid liveness probe,
# which this module deliberately does not perform itself (see the header's
# Decision 3 note -- the kill(0) syscall lives in launcher.pl).
sub decision_live {
    my ($rec, $blueprint_dir, $runs_dir, $run_over) = @_;

    # Anything we cannot read or recognise stays LIVE. This is the branch that
    # protects a real pending decision from a schema change, a truncated write
    # or a record from a future version of the queue.
    return 1 unless ref($rec) eq 'HASH';

    my $pkg = $rec->{package};
    if (defined $pkg && !ref($pkg) && length $pkg && _safe_pkg_name($pkg)
        && -f "$blueprint_dir/packages/$pkg.md") {
        my $status = _ledger_status($blueprint_dir, $pkg);
        # An empty status means the ledger could not be read or carries none.
        # That is not evidence of settlement, so the decision stays live.
        return 1 unless length $status;
        return $SETTLED_STATUS{$status} ? 0 : 1;
    }

    # No package ledger to consult -- fleet-family kinds, pseudo-packages, and
    # anything whose ledger has been removed. Settled only if the run is over.
    return $run_over ? 0 : 1;
}

# _count_decisions($needs_you_dir, $blueprint_dir, $run_over) -> $n (private)
#
# opendir $needs_you_dir; counts entries that are plain files, skipping any
# name beginning with '.' and any name ending in '.tmp' -- and, since t07,
# skipping any whose record decision_live says is settled.
#
# $blueprint_dir undef restores the pre-t07 behaviour of counting every file,
# which is what a caller with no blueprint context can honestly report.
sub _count_decisions {
    my ($dir, $blueprint_dir, $run_over) = @_;
    my $split = _count_decisions_split($dir, $blueprint_dir, $run_over);
    return $split->{operator} + $split->{triage};
}

# ===========================================================================
# WHOSE QUEUE IS THIS? A live record is not the same as a record that needs the
# operator, and the panel spent its whole life conflating them.
#
# Operator, on the run that forced this: "we use way too many instances of ..."
# -- no, the one that matters here: "It stopped an overnight run blocking on me
# to answer some random bullshit question that is an implementation detail."
#
# Every queued escalation carries a `category`. Two of them (product,
# operator-action) are the ones bp-resolve.pl may never decide: they leave the
# queue only when a human reads them. The rest are handed to the escalation
# resolver, which either acts or re-tags -- nobody needs to be woken for those.
#
# THE DEFAULT IS STILL THE OPERATOR, and deliberately so. A record whose
# category is missing, unreadable or unrecognised counts as operator-owned,
# because nothing will ever triage it: bp-orchestrator.pl's resolver dispatch
# filters on exactly the triageable set, so an unrecognised category is a record
# no agent will ever look at again. Counting it as "someone else's problem"
# would be the one failure this module's own header forbids -- "a decision
# wrongly dropped is a human who is never asked".
#
# The list is duplicated from BpOrch::@RESOLVER_TRIAGEABLE rather than imported:
# RunState is a sandbox-plugin module and BpOrch is a butler-plugin script, and
# a cross-plugin require would make the TUI's render path depend on butler being
# installed. t/97 pins the two lists equal, so the duplication cannot drift
# silently.
# Mirrors BpOrch::ESCALATIONS_DIRNAME / ESCALATIONS_LEGACY. Duplicated for the
# same reason the category list below is: a sandbox render module must not
# require a butler script. t/97 pins both against the butler source.
use constant ESCALATIONS_DIRNAME => 'escalations';
use constant ESCALATIONS_LEGACY  => 'needs-you';

our @TRIAGEABLE_CATEGORIES = qw(unclassified conformance oracle scoping implementation);
my %TRIAGEABLE = map { $_ => 1 } @TRIAGEABLE_CATEGORIES;

# The legacy spelling, mirroring BpOrch::%CATEGORY_ALIAS. Neither name is
# triageable, so this only matters for keeping the two tables honestly parallel.
my %CATEGORY_ALIAS = ('operational' => 'operator-action');

# decision_operator_owned($rec) -> 1|0
# 1 = only a human can clear this. 0 = an agent is expected to triage it.
sub decision_operator_owned {
    my ($rec) = @_;
    return 1 unless ref($rec) eq 'HASH';
    my $cat = $rec->{category};
    return 1 unless defined $cat && !ref($cat) && length $cat;
    $cat = $CATEGORY_ALIAS{$cat} // $cat;
    return $TRIAGEABLE{$cat} ? 0 : 1;
}

# _count_decisions_split($dir, $blueprint_dir, $run_over)
#   -> { operator => N, triage => M }   (private)
#
# Same walk as before, same settled-record skipping, but the survivors are split
# by ownership instead of summed. Nothing is hidden: a record awaiting triage is
# still counted, just not under a heading that claims it needs the operator.
sub _count_decisions_split {
    my ($dir, $blueprint_dir, $run_over) = @_;
    my %n = (operator => 0, triage => 0);
    return \%n if -l $dir;
    return \%n unless -d $dir;
    opendir(my $dh, $dir) or return \%n;
    for my $f (readdir $dh) {
        next if $f =~ /^\./;
        next if $f =~ /\.tmp$/;
        # A QUEUE RECORD IS A .json FILE. Everything that WRITES or REMOVES one
        # already agrees on that -- bp-answer-escalation.pl's clear_pkg_decisions
        # and sweep_settled, and bp-orchestrator.pl's queued_decision_pkgs, all
        # filter /\.json$/. This counter did not, and the gap had a name: a
        # zero-byte `<id>.json.lock` left behind after its record was answered
        # and unlinked. No cleanup path can see it, and every filter here let it
        # through -- not a dotfile, does not end in .tmp, is a file. It then read
        # as unparseable, which decision_live deliberately treats as LIVE and
        # decision_operator_owned deliberately treats as the OPERATOR'S, both
        # being the right answer for a truncated RECORD and the wrong one for a
        # stray lock. The panel reported "needs you: 1 decision waiting" against
        # an empty queue, permanently (almanac 20260916-103055-7f5e, and the
        # unexplained item 4 of 20260915-230820-d33e).
        #
        # The fail-safe below is untouched on purpose: an unreadable .json still
        # counts as live. This narrows WHAT IS A RECORD, not what an unreadable
        # record means.
        next unless $f =~ /\.json$/;
        next unless -f "$dir/$f";
        my $rec;
        if (defined $blueprint_dir) {
            $rec = _read_json_capped("$dir/$f");
            next unless decision_live($rec, $blueprint_dir, $dir, $run_over);
        } else {
            $rec = _read_json_capped("$dir/$f");
        }
        $n{ decision_operator_owned($rec) ? 'operator' : 'triage' }++;
    }
    closedir $dh;
    return \%n;
}

# _read_json_capped($path) -> decoded value | undef (private). Size-capped and
# eval-wrapped, matching _paused_info's discipline: a queue directory is
# writable by anything in the container, so a planted multi-GB file must not
# freeze a render tick.
sub _read_json_capped {
    my ($path) = @_;
    my $blob = _read_head($path, $MAX_MARKER_BYTES);
    return undef unless defined $blob && length $blob;
    my $data = eval { JSON::PP->new->decode($blob) };
    return ref($data) ? $data : undef;
}

# _pid_state($pid) -> 1 | 0 | undef (private)
#
# Delegates liveness to the caller-injected $PID_ALIVE coderef. Total against
# a hostile/absent/failing prober -- see the table in
# specs/04-run-panel-ledger-truth-spec.md S2.1:
#   $pid undef                    -> undef (nothing to check)
#   $PID_ALIVE not a CODE ref     -> undef (no prober installed -- UNKNOWN)
#   prober dies                   -> undef (probe failed)
#   prober returns undef          -> undef (probe could not decide)
#   prober returns truthy         -> 1     (alive)
#   prober returns defined-falsy  -> 0     (checked and dead)
sub _pid_state {
    my ($pid) = @_;
    return undef unless defined $pid;
    return undef unless ref($PID_ALIVE) eq 'CODE';
    local $@;
    my $result = eval { $PID_ALIVE->($pid) };
    return undef if $@;
    return undef unless defined $result;
    return $result ? 1 : 0;
}

# _mtime($path) -> Int|undef (private)
#
# 04-runstate-run-and-package-facts (spec S2.3): the DRIVER-SIDE timestamp
# behind orchestrator_started_at. Uses stat, never a clock read. undef
# unless $path is a plain file and not a symlink; undef unless
# (stat $path)[9] is defined, matches /\A\d+\z/ and is > 0; else that
# integer. Never dies.
sub _mtime {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    return undef if -l $path;
    my @st = stat($path);
    my $mtime = $st[9];
    return undef unless defined $mtime && $mtime =~ /\A\d+\z/ && $mtime > 0;
    return $mtime + 0;
}

# _reg_count($v) -> Int (private)
#
# 04-runstate-run-and-package-facts (spec S2.4): reproduces
# bp-orchestrator.pl's `_reg_int($v) // 0` composition exactly, including
# its treatment of 0. Returns $v + 0 when $v is defined, not a ref, and
# matches /\A\d{1,10}\z/ (bare unsigned digits, 1-10 of them -- rejects a
# sign, a decimal point, exponent notation, and an 11-digit run); returns 0
# for everything else (undef, a ref, a negative, a float, "1e3", a string).
sub _reg_count {
    my ($v) = @_;
    return 0 unless defined $v && !ref($v);
    return 0 unless $v =~ /\A\d{1,10}\z/;
    return $v + 0;
}

# _attempt_cap() -> Int (private)
#
# 04-runstate-run-and-package-facts (spec S2.4): mirrors
# bp-orchestrator.pl:2419's `cap => $ENV{BP_ATTEMPT_CAP} // 5` -- a
# dashboard process without the variable reports the same cap an
# orchestrator without the variable would use. $ENV{BP_ATTEMPT_CAP} + 0 when
# that variable is defined, matches /\A\d{1,10}\z/ and is > 0; otherwise 5.
# Reading %ENV is not a clock read, a spawn or an I/O and does not breach
# S2.0.
sub _attempt_cap {
    my $v = $ENV{BP_ATTEMPT_CAP};
    return 5 unless defined $v && $v =~ /\A\d{1,10}\z/;
    my $n = $v + 0;
    return $n > 0 ? $n : 5;
}

# _parse_pipeline($blob) -> ($step, $steps_pending) (private)
#
# 04-runstate-run-and-package-facts (spec S2.5): pure, takes the raw ledger
# bytes, never touches the filesystem, never dies. Returns (undef, undef)
# when $blob is undef/empty or when no checkbox line is recognised.
sub _parse_pipeline {
    my ($blob) = @_;
    return (undef, undef) unless defined $blob && length $blob;
    my $stripped = $blob;
    $stripped =~ s/\A\xEF\xBB\xBF//;
    my @lines = split /\n/, $stripped, -1;
    for my $l (@lines) { $l =~ s/\r\z//; }

    my $start;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /\A##[ \t]+Pipeline[ \t]*\z/i) { $start = $i; last; }
    }
    return (undef, undef) unless defined $start;

    # fix-batch MEDIUM-2: the heading stop-test is byte-level and
    # markdown-naive -- a shell comment/log line pasted into the section at
    # column 0 (e.g. "# perl scripts/run-tests.pl", a plausible thing for a
    # validation step to carry) looks exactly like the next heading and
    # truncates the scan early, understating $total and (combined with the
    # AT-6 max-based denominator) rendering an in-progress package as
    # COMPLETE. Track a fenced-code-block toggle and suppress the heading
    # stop-test while inside a fence.
    my %checked;   # step number (string "1".."8") -> 1|0, first occurrence wins
    my $in_fence = 0;
    for (my $i = $start + 1; $i <= $#lines; $i++) {
        my $line = $lines[$i];
        if ($line =~ /\A[ \t]*(?:\x60\x60\x60|~~~)/) { $in_fence = !$in_fence; next; }
        last if !$in_fence && $line =~ /\A#{1,6}[ \t]/;
        next if length($line) > 1024;
        if ($line =~ /\A[ \t]*-[ \t]*\[([ xX])\][ \t]*([1-8])\.[ \t]/) {
            my ($mark, $num) = ($1, $2);
            next if exists $checked{$num};
            $checked{$num} = ($mark eq 'x' || $mark eq 'X') ? 1 : 0;
        }
    }

    my @seen_nums = map { $_ + 0 } keys %checked;
    return (undef, undef) unless @seen_nums;

    # fix-batch AT-6 (driver ruling): the denominator is the HIGHEST STEP
    # NUMBER OBSERVED, not a count of parseable lines. The two diverge the
    # moment any recognised line is skipped (over-length, a repeated number)
    # while a HIGHER-numbered step is still present -- previously this mixed
    # a step NUMBER (numerator) with a LINE COUNT (denominator), e.g. six
    # steps pending against a denominator of seven in an eight-step pipeline.
    my $total = $seen_nums[0];
    for my $n (@seen_nums) { $total = $n if $n > $total; }

    my @pending = sort { $a <=> $b } grep { !$checked{$_} } @seen_nums;
    my $current = @pending ? $pending[0] : $total;
    my $step = sprintf('%d/%d', $current, $total);
    return ($step, \@pending);
}

# _parse_next_action($blob) -> Str|undef (private)
#
# 04-runstate-run-and-package-facts (spec S2.6): pure, never dies.
#
# fix-batch HIGH-2: takes the LAST matching heading, not the first. A
# template has exactly one '## Next action' section, so first == only there
# -- but real ledgers in this repo append a fresh one after every journal
# entry, newest last (verified on a real archived ledger with five headings:
# the first was a step-3 dispatch instruction, the last "None -- package
# COMPLETE"). First-match renders the OLDEST instruction as current; taking
# the last is what makes the panel show the actually-current one.
sub _parse_next_action {
    my ($blob) = @_;
    return undef unless defined $blob && length $blob;
    my $stripped = $blob;
    $stripped =~ s/\A\xEF\xBB\xBF//;
    my @lines = split /\n/, $stripped, -1;
    for my $l (@lines) { $l =~ s/\r\z//; }

    my $start;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /\A##[ \t]+Next[ \t]+action[ \t]*\z/i) { $start = $i; }
    }
    return undef unless defined $start;

    # fix-batch MEDIUM-2 (redteam's own "same guard should be applied to
    # _parse_next_action, whose collection loop has the identical stop
    # condition"): a fenced code block containing a line starting with '#'
    # at column 0 must not be misread as the next heading and truncate the
    # collected text early.
    my @collected;
    my $len = 0;
    my $in_fence = 0;
    for (my $i = $start + 1; $i <= $#lines; $i++) {
        my $line = $lines[$i];
        if ($line =~ /\A[ \t]*(?:\x60\x60\x60|~~~)/) { $in_fence = !$in_fence; }
        else { last if !$in_fence && $line =~ /\A#{1,6}[ \t]/; }
        push @collected, $line;
        $len += length($line) + 1;
        last if $len >= 4096;
    }

    my $joined = join(' ', @collected);
    $joined =~ s/[\x00-\x1F\x7F]/ /g;
    $joined =~ s/\x20+/\x20/g;
    $joined =~ s/\A\x20+//;
    $joined =~ s/\x20+\z//;
    return undef unless length $joined;
    return undef if substr($joined, 0, 1) eq '<' && substr($joined, -1, 1) eq '>';

    if (length($joined) > 200) {
        $joined = substr($joined, 0, 200);
        while (length($joined) && ord(substr($joined, -1, 1)) >= 0x80 && ord(substr($joined, -1, 1)) <= 0xBF) {
            $joined = substr($joined, 0, -1);
        }
        if (length($joined)) {
            my $last = ord(substr($joined, -1, 1));
            $joined = substr($joined, 0, -1) if $last >= 0xC0 && $last <= 0xFF;
        }
    }
    return $joined;
}

# _ledger_facts($blueprint_dir, $pkg) -> \%facts (private)
#
# 04-runstate-run-and-package-facts (spec S2.7): keys step/steps_pending/
# next_action, all undef on any failure. Never dies. Deliberately
# independent of frontmatter validity -- unlike _ledger_status, which stays
# strict and unchanged.
sub _ledger_facts {
    my ($blueprint_dir, $pkg) = @_;
    my %facts = (step => undef, steps_pending => undef, next_action => undef);
    return \%facts unless _safe_pkg_name($pkg);
    my $blob = _read_head("$blueprint_dir/packages/$pkg.md", $MAX_LEDGER_BYTES);
    return \%facts unless defined $blob && length $blob;
    my ($step, $pending) = _parse_pipeline($blob);
    $facts{step}          = $step;
    $facts{steps_pending} = $pending;
    $facts{next_action}   = _parse_next_action($blob);
    return \%facts;
}

# _ledger_packages($blueprint_dir) -> \@names | undef (private)
#
# undef ONLY when "$blueprint_dir/packages" is genuinely absent: a symlink,
# not a directory, or opendir fails -- i.e. there is truly no ledger source,
# which is what licenses summarize_dir's registry fallback. Otherwise an
# ascending-sorted, possibly-empty arrayref of package names, REGARDLESS of
# how large -- the $MAX_PACKAGES cardinality cap is enforced by the caller
# (summarize_dir), not here. 04-run-panel-ledger-truth consolidated
# fix-batch (HIGH-4): this used to self-degrade to undef when over cap,
# which then silently fell through to summarize_dir's registry-fallback
# branch (the exact "bound became a fabrication" shape this package exists
# to eliminate, on a much larger scale than the original oversized-ledger
# defect). An over-cap ledger set must now cause summarize_dir to return
# undef DIRECTLY -- see there.
#
# A directory entry is a candidate ledger iff: the name does not begin with
# '.'; the name ends in '.md' (case-sensitive); "$dir/packages/$name" is not
# a symlink and IS a plain file; the name with '.md' stripped passes
# _safe_pkg_name; and (MEDIUM-5) it is not POSITIVELY confirmed to lack
# frontmatter -- a small (0 < size <= $MAX_LEDGER_BYTES), fully-readable file
# whose first non-blank line (BOM/CRLF/leading-blank tolerant, via
# _looks_like_frontmatter) is not exactly '---' is excluded (a stray
# README.md/TEMPLATE.md dropped in packages/ must not inflate
# packages_total forever). A zero-length file, an over-cap file (size >
# $MAX_LEDGER_BYTES), or one whose stat/open fails is NEVER excluded on this
# basis -- ambiguous cases stay candidates, so a genuinely malformed-but-
# real ledger is never silently dropped from the denominator (that would
# reintroduce HIGH-2 from the other side). This membership check is
# deliberately independent of _ledger_status's STRICT, non-tolerant parse --
# see that sub's comment for why the two must not share tolerance.
#
# Discovery is opendir/readdir only. glob remains forbidden anywhere in this
# file (t/45:340-342 / AC-21).
sub _ledger_packages {
    my ($blueprint_dir) = @_;
    return undef unless defined $blueprint_dir && !ref($blueprint_dir) && length($blueprint_dir);
    my $pkgs_dir = "$blueprint_dir/packages";
    return undef if -l $pkgs_dir;
    return undef unless -d $pkgs_dir;
    opendir(my $dh, $pkgs_dir) or return undef;
    my @names;
    for my $e (readdir $dh) {
        next if $e eq '.' || $e eq '..';
        next if $e =~ /^\./;
        next unless $e =~ /\.md\z/;
        my $full = "$pkgs_dir/$e";
        next if -l $full;
        next unless -f $full;
        (my $name = $e) =~ s/\.md\z//;
        next unless _safe_pkg_name($name);
        my $size = -s $full;
        if (defined($size) && $size > 0 && $size <= $MAX_LEDGER_BYTES) {
            my $blob = _read_head($full, $MAX_LEDGER_BYTES);
            next if defined($blob) && !_looks_like_frontmatter($blob);
        }
        push @names, $name;
    }
    closedir $dh;
    return [ sort @names ];
}

# ===========================================================================
# 05-runstate-agent-aggregation: the dispatch-log reader.
#
# RunState DUPLICATES the small parse rules bp-dispatch-log.pl (a BUTLER
# plugin script) owns, rather than `require`ing across the plugin boundary --
# spec S1.1. Three recorded reasons: no stable path from the sandbox plugin
# to the butler plugin across clone/live-install/mount layouts;
# bp-dispatch-log.pl is a script whose `package main` section transitively
# requires bp-write-guard.pl and defines a print-STDERR-and-exit helper,
# neither of which may enter a render-only module's graph; and what is
# actually needed is a few lines of arithmetic and a 3-element membership
# test -- the same call package 04 already made for effective_attempts.
#
# The five predicate-input helpers below are pure, pinned-name, and total:
# none dies, none warns, on any input including refs and hostile bytes.
# ===========================================================================

# _rec_attr($v) -> Str | undef (private)
#
# Reproduces BpDispatchLog::attribution's collapse: undef unless $v is
# defined, not a ref, and has non-zero length; else $v verbatim (bytes
# untouched).
sub _rec_attr {
    my ($v) = @_;
    return undef unless defined($v) && !ref($v) && length($v);
    return $v;
}

# _rec_str($v) -> Str (private)
#
# '' unless $v is defined and not a ref; else $v. Used only for the `status`
# comparison, so a `status` that is a hashref can never warn.
sub _rec_str {
    my ($v) = @_;
    return '' unless defined($v) && !ref($v);
    return $v;
}

# _rec_epoch($v) -> Int | undef (private)
#
# undef unless $v is defined, not a ref, matches /\A\d{1,12}\z/ and is > 0;
# else $v + 0. Deliberate deviation from 02's is_live (which uses
# looks_like_number, admitting "1.5e9"/"-3"): bare digits only, matching the
# shape _mtime/_orchestrator_pid already use in this module.
sub _rec_epoch {
    my ($v) = @_;
    return undef unless defined($v) && !ref($v) && $v =~ /\A\d{1,12}\z/;
    return undef unless $v > 0;
    return $v + 0;
}

# _rec_budget($v) -> Int | undef (private)
#
# undef unless $v is defined, not a ref, matches /\A\d{1,10}\z/, is > 0, and
# is <= 604800 (7 days -- reproduces $BpDispatchLog::MAX_BUDGET_SECONDS,
# guarding against an absurd budget scaling stale_after_seconds past any
# reachable clock).
sub _rec_budget {
    my ($v) = @_;
    return undef unless defined($v) && !ref($v) && $v =~ /\A\d{1,10}\z/;
    return undef unless $v > 0 && $v <= 604800;
    return $v + 0;
}

# _rec_role($v) -> Str | undef (private)
#
# _rec_attr first, then membership in the literal list
# qw(coordinator worker judge); anything else -> undef. Decision 6 locks the
# vocabulary -- an unrecognised role string is never emitted verbatim.
my %RS_ROLE_OK = map { $_ => 1 } qw(coordinator worker judge);
sub _rec_role {
    my ($v) = @_;
    my $s = _rec_attr($v);
    return undef unless defined $s;
    return $RS_ROLE_OK{$s} ? $s : undef;
}

# _rec_worker_type($v) -> Str | undef (private)
#
# _rec_attr first; then, on the bytes: replace every control byte
# ([\x00-\x1F\x7F]) with a space, collapse runs of spaces, trim; undef if the
# result is empty; truncate to at most 64 bytes, then repair a split UTF-8
# sequence at the cut (package 04 S2.6 step 7's exact rule: drop trailing
# continuation bytes \x80-\xBF, then drop one more byte if what remains ends
# in a lead byte \xC0-\xFF).
sub _rec_worker_type {
    my ($v) = @_;
    my $s = _rec_attr($v);
    return undef unless defined $s;
    # fix-batch MEDIUM-1 / red-team MEDIUM-1: JSON::PP->decode (no ->utf8)
    # returns a UTF8-flagged character string, so length()/substr() below
    # would count code points, not bytes -- a 64-CHARACTER bound rather than
    # the 64-BYTE bound spec S2.7/B15 actually specifies. Downgrade to raw
    # bytes first so every operation below (control-byte class, length,
    # substr, the split-sequence repair) is genuinely byte-scoped.
    utf8::encode($s) if utf8::is_utf8($s);
    $s =~ s/[\x00-\x1F\x7F]/ /g;
    $s =~ s/\x20+/\x20/g;
    $s =~ s/\A\x20+//;
    $s =~ s/\x20+\z//;
    return undef unless length $s;
    if (length($s) > 64) {
        $s = substr($s, 0, 64);
        while (length($s) && ord(substr($s, -1, 1)) >= 0x80 && ord(substr($s, -1, 1)) <= 0xBF) {
            $s = substr($s, 0, -1);
        }
        if (length($s)) {
            my $last_byte = ord(substr($s, -1, 1));
            $s = substr($s, 0, -1) if $last_byte >= 0xC0 && $last_byte <= 0xFF;
        }
    }
    return $s;
}

# _dispatch_dir($blueprints_root) -> Str | undef (private, pinned name)
#
# Pure string arithmetic, no filesystem access, never dies (spec S2.4). The
# anchor is deliberately strict: only a path whose tail is exactly
# "/.ccpraxis-local-data/blueprints" (optionally trailing-slashed) yields a
# dispatch dir, so an unrelated directory two levels up from an arbitrary
# fixture is never read.
sub _dispatch_dir {
    my ($blueprints_root) = @_;
    return undef unless defined($blueprints_root) && !ref($blueprints_root) && length($blueprints_root);
    my $p = $blueprints_root;
    $p =~ s{\\}{/}g;
    $p =~ s{/+\z}{};
    return undef unless $p =~ m{\A(.+)/\.ccpraxis-local-data/blueprints\z};
    return "$1/.ccpraxis-local-data/.dispatch-log";
}

# _dispatch_index($dispatch_dir) -> \%idx (private, pinned name)
#
# Shape: { <blueprint> => { <package> => [ <agent>, ... ] } }, blueprint and
# package keys taken VERBATIM from the record, agents sorted per S2.8 (by
# started_at ascending, ties broken by id ascending). Never dies, never
# warns. Always returns a HASH ref, never undef -- including when
# $dispatch_dir is undef/a ref/zero-length, is a symlink, is not a directory,
# opendir fails, or the candidate count exceeds $MAX_DISPATCH_RECORDS
# (Decision 9: an over-cap set degrades to NO row, not a partial answer).
#
# Discovery is opendir/readdir only (glob is forbidden anywhere in this
# file). Per-record reads reuse the module's existing _read_json_capped,
# which already degrades a directory-named-*.json, a symlink, an unreadable
# file, an empty file, and undecodable/oversized bytes to undef -- so all of
# those "skip" cases need no new code here.
sub _dispatch_index {
    my ($dispatch_dir) = @_;
    my %idx;
    return \%idx unless defined($dispatch_dir) && !ref($dispatch_dir) && length($dispatch_dir);
    return \%idx if -l $dispatch_dir;
    return \%idx unless -d $dispatch_dir;
    opendir(my $dh, $dispatch_dir) or return \%idx;
    my @candidates;
    for my $entry (readdir $dh) {
        push @candidates, $1 if $entry =~ /\A([A-Za-z0-9._-]{1,128})\.json\z/;
    }
    closedir $dh;
    return \%idx if scalar(@candidates) > $MAX_DISPATCH_RECORDS;

    for my $stem (sort @candidates) {
        my $rec = _read_json_capped("$dispatch_dir/$stem.json");
        next unless ref($rec) eq 'HASH';
        next unless _rec_str($rec->{status}) eq 'running';
        my $started = _rec_epoch($rec->{started_at});
        next unless defined $started;
        my $bp = _rec_attr($rec->{blueprint});
        next unless defined $bp;
        my $pkg = _rec_attr($rec->{package});
        next unless defined $pkg;
        my $budget = _rec_budget($rec->{budget_seconds});
        push @{ $idx{$bp}{$pkg} }, {
            id                  => $stem,
            role                => _rec_role($rec->{role}),
            worker_type         => _rec_worker_type($rec->{worker_type}),
            started_at          => $started,
            budget_seconds      => $budget,
            stale_after_seconds => 4 * ($budget // 1800),
        };
    }

    for my $bp (keys %idx) {
        for my $pkg (keys %{ $idx{$bp} }) {
            $idx{$bp}{$pkg} = [
                sort { $a->{started_at} <=> $b->{started_at} || $a->{id} cmp $b->{id} }
                    @{ $idx{$bp}{$pkg} }
            ];
        }
    }
    return \%idx;
}

# _bp_authored_parked($blueprint_dir) -> 0|1 (private, package blueprint-park (08))
#
# Reads blueprint.md's own fenced metadata (never a package ledger): the
# first fenced code block in the file, the first status: line inside it,
# normalised and compared to 'parked'. Never dies, never writes; an undef/
# missing/symlinked blueprint.md degrades to 0. The fence marker is built via
# chr() rather than written literally -- a literal triple-backtick is itself a
# banned token in this module's own source (checks:no-shell-capture, AC-8).
#
# Normalisation is duplicated from BpState::norm_bp_status (lowercase, strip
# a trailing '#...' comment, collapse every run of non-letters to a single
# space, trim) rather than imported: RunState is a sandbox-plugin module and
# BpState is a butler-plugin script, and a cross-plugin require would make
# the TUI's render path depend on butler being installed (the same reason
# ESCALATIONS_DIRNAME and @TRIAGEABLE_CATEGORIES above are duplicated, not
# imported). Package 08 (status "parked") L7/NIT-3: this used to be a plain
# lc+trim-exact comparison, which disagreed with BpState on a hand-edited
# value like `status: parked.` or `status: "parked"`. Keep this in lockstep
# with BpState::norm_bp_status by hand; nothing currently pins the two
# algorithms equal the way t/97 pins the triageable lists.
sub _bp_authored_parked {
    my ($blueprint_dir) = @_;
    return 0 unless defined $blueprint_dir;
    my $blob = _read_head("$blueprint_dir/blueprint.md", 65536);
    return 0 unless defined $blob;
    my $fence_q = quotemeta(chr(96) x 3);
    return 0 unless $blob =~ /^$fence_q[ \t]*\r?\n((?:.*\r?\n)*?)^$fence_q[ \t]*\r?$/m;
    my $fence = $1;
    return 0 unless $fence =~ /^status:[ \t]*([^\r\n]*)/m;
    my $v = lc($1);
    $v =~ s/#.*\z//;
    $v =~ s/[^a-z]+/ /g;
    $v =~ s/\A\s+|\s+\z//g;
    return ($v eq 'parked') ? 1 : 0;
}

# ===========================================================================
# package 13-dashboard-threads (specs/13-dashboard-threads-spec.md): the
# thread/thread_events surface. Restates package 02's store layout and
# package 12's task-labelling rules (spec S2.1) rather than loading any
# Almanac:: module -- a sandbox-plugin module must not depend on the almanac
# plugin being installed, and Almanac::Thread reads the clock and takes
# locks, which this module's own purity contract forbids. Every helper below
# is total: a malformed/hostile/over-cap input degrades to an empty/undef
# result, never propagates an exception.
# ===========================================================================

# _project_root($blueprints_root) -> Str | undef (private, pinned name)
#
# Pure string arithmetic, the same anchor _dispatch_dir uses: only a path
# whose tail is exactly "/.ccpraxis-local-data/blueprints" (optionally
# trailing-slashed, backslashes folded to '/') yields a project root.
sub _project_root {
    my ($blueprints_root) = @_;
    return undef unless defined($blueprints_root) && !ref($blueprints_root) && length($blueprints_root);
    my $p = $blueprints_root;
    $p =~ s{\\}{/}g;
    $p =~ s{/+\z}{};
    return undef unless $p =~ m{\A(.+)/\.ccpraxis-local-data/blueprints\z};
    return $1;
}

# %THREAD_EVENT_OK -- restates Almanac::Thread's @EVENTS exactly (the only
# event names Almanac's writer accepts). A thread-log record naming anything
# else did not come from that writer and is not surfaced.
# dashboard-threads-followups.t
# pins the two lists equal.
our @THREAD_EVENTS = qw(created attached detached handed-off taken-over paused resumed archived
                        task-status launched escalation-sent answer-applied finished);
my %THREAD_EVENT_OK = map { $_ => 1 } @THREAD_EVENTS;

# _valid_thread_name($name) -> 0|1 (private)
#
# Restates Almanac::Thread::valid_name exactly.
sub _valid_thread_name {
    my ($name) = @_;
    return 0 unless defined $name;
    return 0 unless $name =~ /\A[a-z0-9][a-z0-9-]{0,63}\z/;
    return 0 if $name =~ /\A(?:con|prn|aux|nul|com[1-9]|lpt[1-9])\z/i;
    return 1;
}

# _valid_record_id($id) -> 0|1 (private)
#
# Restates Almanac::Store's own record-id grammar (one task/log entry's file
# stem).
sub _valid_record_id {
    my ($id) = @_;
    return 0 unless defined($id) && length($id) <= 128;
    return 0 unless $id =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;
    return 0 if $id =~ /\.\./;
    return 0 if $id =~ /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\z/i;
    return 1;
}

# _valid_link_part($s) -> 0|1 (private). Shared grammar for one side of a
# "<blueprint>/<package>" link AND for an orchestrator thread's owner_id
# (which names a blueprint directory).
sub _valid_link_part {
    my ($s) = @_;
    return 0 unless defined($s) && !ref($s) && length($s) && length($s) <= 128;
    return 0 unless $s =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;
    return 0 if $s =~ /\.\./;
    return 1;
}

# _rank_id_cmp_local($ra, $rb, $ia, $ib) -> Int (private)
#
# Restates Almanac::Store::_rank_id_cmp: rank first (cmp), ties (and
# unranked records) broken by id; unranked sorts after every ranked entry.
sub _rank_id_cmp_local {
    my ($ra, $rb, $ia, $ib) = @_;
    if (defined($ra) && defined($rb)) {
        my $c = $ra cmp $rb;
        return $c ? $c : ($ia cmp $ib);
    }
    elsif (defined $ra) { return -1; }
    elsif (defined $rb) { return 1; }
    else { return $ia cmp $ib; }
}

# _alm_text($v) -> Str | undef (private). C0 and DEL removed; undef in, undef
# out.
sub _alm_text {
    my ($v) = @_;
    return undef unless defined($v) && !ref($v);
    my $s = $v;
    $s =~ s/[\x00-\x1F\x7F]//g;
    return $s;
}

# _parse_record($bytes) -> \%fields | undef (private, pinned name)
#
# Accepts exactly what statusline.pl's almanac_parse_record accepts: a
# "---\n" + "key: value\n" lines + "---\n" frontmatter block, nothing after
# it required. Values are validated against a DECODED copy (so a character
# class like [A-Za-z0-9_] behaves correctly on a multi-byte key, and the
# control-character reject applies to codepoints, not raw bytes) but the
# fields returned hold the ORIGINAL bytes -- Dashboard's caller contract D3
# wants UTF-8 bytes, never a double-decoded value.
sub _parse_record {
    my ($bytes) = @_;
    return undef unless defined($bytes) && !ref($bytes);
    my $raw  = "$bytes";
    my $text = $raw;
    if ($text =~ /[^\x00-\x7f]/) {
        return undef if utf8::is_utf8($text);
        return undef unless utf8::decode($text);
        return undef if $text =~ /[^\x{0}-\x{10FFFF}]/;
        return undef if $text =~ /[\x{D800}-\x{DFFF}\x{FDD0}-\x{FDEF}\x{FFFE}\x{FFFF}\x{1FFFE}\x{1FFFF}\x{2FFFE}\x{2FFFF}\x{3FFFE}\x{3FFFF}\x{4FFFE}\x{4FFFF}\x{5FFFE}\x{5FFFF}\x{6FFFE}\x{6FFFF}\x{7FFFE}\x{7FFFF}\x{8FFFE}\x{8FFFF}\x{9FFFE}\x{9FFFF}\x{AFFFE}\x{AFFFF}\x{BFFFE}\x{BFFFF}\x{CFFFE}\x{CFFFF}\x{DFFFE}\x{DFFFF}\x{EFFFE}\x{EFFFF}\x{FFFFE}\x{FFFFF}\x{10FFFE}\x{10FFFF}]/;
    }
    my @l  = split /\n/, $text, -1;
    my @lb = split /\n/, $raw,  -1;
    return undef unless @l && $l[0] eq '---';
    my $closing;
    for my $i (1 .. $#l) {
        if ($l[$i] =~ /\A---\r?\z/) { $closing = $i; last; }
    }
    return undef unless defined($closing) && $closing >= 2 && $l[$closing] eq '---';
    my %fields;
    for my $i (1 .. $closing - 1) {
        return undef unless $l[$i] =~ /\A([A-Za-z0-9_]+): (.*)\z/;
        my ($k, $v) = ($1, $2);
        return undef if exists $fields{$k};
        return undef if $v =~ /[\x00-\x08\x0A-\x1F\x7F-\x9F\x{2028}\x{2029}]/;
        my ($bv) = ($lb[$i] =~ /\A[A-Za-z0-9_]+: (.*)\z/);
        $fields{$k} = defined($bv) ? $bv : $v;
    }
    return \%fields;
}

# @LINK_STATUSES -- restates Almanac::PackageLink::@STATUSES.
my %LINK_STATUSES = map { $_ => 1 } qw(pending running converging reviewing done blocked parked dropped);

# _normalize_link_status($raw) -> one of @LINK_STATUSES | '' (private).
# Restates Almanac::PackageLink::norm_status.
sub _normalize_link_status {
    my ($s) = @_;
    return '' unless defined $s;
    $s = lc $s;
    $s =~ s/[^a-z]+/ /g;
    $s =~ s/\A\s+|\s+\z//g;
    return $LINK_STATUSES{$s} ? $s : '';
}

# _fm_status_from_blob($blob) -> Str (private)
#
# Restates Almanac::PackageLink::_fm_get('status'), operating on bytes
# already in hand rather than re-opening the file: the FIRST '---'-delimited
# block only, the first `status:` line inside it wins.
sub _fm_status_from_blob {
    my ($blob) = @_;
    return '' unless defined($blob) && length($blob);
    my @lines = split /\n/, $blob, -1;
    my $in = 0;
    for my $ln (@lines) {
        if ($ln =~ /\A-{3}\s*\z/) { $in++; last if $in == 2; next; }
        next unless $in == 1;
        if ($ln =~ /\Astatus:\s*(.*?)\s*\z/) { return _normalize_link_status($1); }
    }
    return '';
}

# _pipeline_step_word($blob) -> Str | undef (private, pinned name)
#
# Restates _parse_pipeline's own "## Pipeline" scan, but returns the WORD of
# the lowest-numbered unchecked entry rather than an "N/M" fraction -- see
# spec S2.1 "Pipeline step word". Never reuses _parse_pipeline itself (that
# sub accepts only steps 1-8; this one accepts 1-99 per the spec's checkbox
# regex).
sub _pipeline_step_word {
    my ($blob) = @_;
    return undef unless defined($blob) && length($blob);
    my $stripped = $blob;
    $stripped =~ s/\A\xEF\xBB\xBF//;
    my @lines = split /\n/, $stripped, -1;
    for my $l (@lines) { $l =~ s/\r\z//; }

    my $start;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /\A##[ \t]+Pipeline[ \t]*\z/i) { $start = $i; last; }
    }
    return undef unless defined $start;

    my %entry;   # num -> [checked?, word], first occurrence of each number wins
    my $in_fence = 0;
    for (my $i = $start + 1; $i <= $#lines; $i++) {
        my $line = $lines[$i];
        if ($line =~ /\A[ \t]*(?:\x60\x60\x60|~~~)/) { $in_fence = !$in_fence; next; }
        last if !$in_fence && $line =~ /\A#{1,6}[ \t]/;
        next if length($line) > 1024;
        if ($line =~ /\A[ \t]*-[ \t]*\[([ xX])\][ \t]*(\d{1,2})\.[ \t]+(\S+)/) {
            my ($mark, $num, $word) = ($1, $2, $3);
            $num = 0 + $num;   # reviewer N3: "01." and "1." are one step, as statusline.pl reads it
            next if exists $entry{$num};
            $entry{$num} = [ ($mark eq 'x' || $mark eq 'X') ? 1 : 0, $word ];
        }
    }
    my @nums = sort { $a <=> $b } keys %entry;
    return undef unless @nums;
    my ($lowest_unchecked) = grep { !$entry{$_}[0] } @nums;
    return undef unless defined $lowest_unchecked;
    my $word = lc($entry{$lowest_unchecked}[1]);
    $word =~ s/[^a-z0-9-]//g;
    return length($word) ? $word : undef;
}

# _link_resolve($project_root, $link, \%cache) -> \%r (private, pinned name)
#
# Restates Almanac::PackageLink::resolve exactly (Decision 18 F1): live
# ledger wins over an archived one, which wins over "missing". Never
# consults CCPRAXIS_DATA_DIR. Total -- a bad project root or link grammar
# degrades to state 'invalid', never an exception.
#
# \%cache is optional (spec S2.2 step 4: "cache ledger reads by path for this
# call"). When given, it is keyed by "$project_root\0$link" and holds the
# full result, so a package linked by more than one task across the index is
# read from disk at most once per _thread_index call. Callers that omit it
# get the old uncached behaviour.
sub _link_resolve {
    my ($project_root, $link, $cache) = @_;
    my $invalid = { state => 'invalid', blueprint => undef, package => undef, status => undef, step => undef };
    return $invalid unless defined($link) && length($link);

    my $key = (ref($cache) eq 'HASH' && defined($project_root) && length($project_root))
        ? "$project_root\0$link" : undef;
    return $cache->{$key} if defined($key) && exists $cache->{$key};

    my @parts = split m{/}, $link, -1;
    if (@parts != 2) { $cache->{$key} = $invalid if defined $key; return $invalid; }
    my ($bp, $pkg) = @parts;
    if (!_valid_link_part($bp) || !_valid_link_part($pkg) || !defined($project_root) || !length($project_root)) {
        $cache->{$key} = $invalid if defined $key;
        return $invalid;
    }

    # Link parts are forced to bytes before concatenation with the root (a
    # flagged-but-ASCII part would otherwise Latin-1-upgrade a non-ASCII
    # root -- spec S2.1).
    for my $p ($bp, $pkg) { utf8::encode($p) if utf8::is_utf8($p); }

    my $bdir = "$project_root/.ccpraxis-local-data/blueprints";
    my $live_path     = "$bdir/$bp/packages/$pkg.md";
    my $archived_path = "$bdir/_archive/$bp/packages/$pkg.md";

    my $ledger;
    # The !-l is a deliberate divergence from Almanac::PackageLink::resolve and
    # statusline.pl's restatement (reviewer N4): this module never follows a
    # symlink into data it renders, so a symlinked ledger reads `missing` here
    # where those read it `ok`.
    if    (-f $live_path     && !-l $live_path)     { $ledger = $live_path; }
    elsif (-f $archived_path && !-l $archived_path) { $ledger = $archived_path; }
    else {
        my $r = { state => 'missing', blueprint => $bp, package => $pkg, status => undef, step => undef };
        $cache->{$key} = $r if defined $key;
        return $r;
    }

    my $blob       = _read_head($ledger, $MAX_LEDGER_BYTES);
    my $raw_status = _fm_status_from_blob($blob);
    my $status     = length($raw_status) ? $raw_status : 'pending';
    my $step       = _pipeline_step_word($blob);
    my $r = { state => 'ok', blueprint => $bp, package => $pkg, status => $status, step => $step };
    $cache->{$key} = $r if defined $key;
    return $r;
}

# _status_class($status) -> 'done'|'doing'|'blocked'|'pending' (private).
# Spec S2.1's linked-task classification table.
sub _status_class {
    my ($status) = @_;
    return 'done'    if $status eq 'done'    || $status eq 'dropped';
    return 'doing'   if $status eq 'running' || $status eq 'converging' || $status eq 'reviewing';
    return 'blocked' if $status eq 'blocked' || $status eq 'parked';
    return 'pending';
}

# _is_abs_local($p) -> 0|1 (private). Restates Almanac::SessionLive::_is_abs.
sub _is_abs_local {
    my ($p) = @_;
    return 0 unless defined($p) && length($p);
    return 1 if $p =~ m{\A/};
    return 1 if $p =~ m{\A[A-Za-z]:[\\/]};
    return 0;
}

# _build_owner($blueprints_root, $project_root, \%thread_fields) -> \%owner
# (private). Spec S2.2 "owner rules". Total: a hostile/absent field degrades
# to the honest "no evidence" shape, never an exception.
sub _build_owner {
    my ($blueprints_root, $project_root, $f) = @_;
    my $raw_kind = (ref($f) eq 'HASH') ? $f->{owner_kind} : undef;
    my $kind = (defined($raw_kind) && ($raw_kind eq 'session' || $raw_kind eq 'orchestrator'))
        ? $raw_kind : 'none';
    my $raw_id = (ref($f) eq 'HASH') ? $f->{owner_id} : undef;
    my $id = (defined($raw_id) && !ref($raw_id) && length($raw_id) && $raw_id ne '-') ? $raw_id : undef;

    my %owner = (kind => $kind, id => $id, alive => undef, activity_at => undef, armed => 0);
    return \%owner unless $kind eq 'session' || $kind eq 'orchestrator';

    if ($kind eq 'orchestrator') {
        if (defined($id) && _valid_link_part($id)) {
            my $marker = "$blueprints_root/$id/runs/.orchestrator";
            $owner{alive} = (-e $marker && !-l $marker) ? _pid_state(_orchestrator_pid($marker)) : 0;
        }
        return \%owner;
    }

    # $kind eq 'session'. owner.alive stays undef for the whole lifetime of
    # this branch (S2.2: "undef for session/none") -- the live/dead verdict
    # for a session is made at render time, from activity_at/armed, by
    # tui::DashboardScreen::thread_owner_status.
    my $sid_ok = defined($id) && $id =~ /\A[A-Za-z0-9_-]{1,128}\z/;
    return \%owner unless $sid_ok;

    my $raw_t = (ref($f) eq 'HASH') ? $f->{owner_transcript} : undef;
    return \%owner unless defined($raw_t) && !ref($raw_t) && length($raw_t);

    my $mapped = 0;
    my $t = $raw_t;
    if ($t =~ m{\A/root/\.claude/(.*)\z}) {
        $t = "$project_root/.ccpraxis-local-data/claude-home/$1";
        $mapped = 1;
    }

    # H1 hardening: owner_transcript comes from a thread record the
    # container can write, so it must not be trusted as a raw filesystem
    # path -- a crafted "//host/share" or a backslash form could reach a
    # network share (confirmed: cygpath reads "//host/share" as a UNC path),
    # and ".." could walk the path outside the tree the mapping intended.
    # Reject traversal, any backslash, a leading "//" (UNC), and require the
    # basename to be exactly "<sid>.jsonl" (it must name this session's own
    # transcript, never another session's or an arbitrary file). Anything
    # else leaves activity_at undef (renders "unknown"), never a stat or
    # opendir attempt.
    my $valid_t = 0;
    if (defined($t) && length($t) && $t !~ /\.\./ && $t !~ /\\/ && $t !~ m{\A/{2,}}) {
        my ($base) = ($t =~ m{([^/]+)\z});
        $valid_t = 1 if defined($base) && $base eq "$id.jsonl";
    }

    if ($valid_t && -f $t && !-l $t) {
        my @st = stat($t);
        my $best = (defined($st[9]) && $st[9] =~ /\A\d+\z/) ? $st[9] + 0 : undef;
        if (($t) =~ m{\A(.*)/[^/]+\z}) {
            my $subdir = "$1/$id/subagents";
            if (-d $subdir && !-l $subdir) {
                if (opendir(my $dh, $subdir)) {
                    my @cands;
                    for my $e (readdir $dh) {
                        next unless $e =~ /\.jsonl\z/;
                        next unless -f "$subdir/$e" && !-l "$subdir/$e";
                        push @cands, $e;
                        last if scalar(@cands) >= 512;
                    }
                    closedir $dh;
                    for my $e (@cands) {
                        my @st2 = stat("$subdir/$e");
                        next unless defined($st2[9]) && $st2[9] =~ /\A\d+\z/;
                        $best = $st2[9] + 0 if !defined($best) || $st2[9] + 0 > $best;
                    }
                }
            }
        }
        $owner{activity_at} = $best;
    }

    my $arm_path;
    if ($mapped) {
        $arm_path = "$project_root/.ccpraxis-local-data/claude-home/butler-state/continuity/armed/$id";
    }
    else {
        my $bsd = $ENV{BUTLER_STATE_DIR};
        if (defined($bsd) && length($bsd) && _is_abs_local($bsd)) {
            (my $v = $bsd) =~ s{/+\z}{};
            $arm_path = "$v/continuity/armed/$id";
        }
        else {
            for my $var (qw(HOME USERPROFILE)) {
                my $val = $ENV{$var};
                next unless defined($val) && length($val) && _is_abs_local($val);
                (my $v = $val) =~ s{/+\z}{};
                $arm_path = "$v/.claude/butler-state/continuity/armed/$id";
                last;
            }
        }
    }
    $owner{armed} = (defined($arm_path) && -f $arm_path && !-l $arm_path) ? 1 : 0;
    return \%owner;
}

# _thread_build($project_root, $blueprints_root, $name, \%fields, \%cache, \$link_budget)
#   -> \%thread | undef (private)
#
# Never undef in practice: an over-cap task set (spec S2.2 step 4) yields a
# degraded thread with no progress and a "not read" label, never a skip.
# Otherwise: name/done/total/doing/current/next/owner/driven, where
# `driven` is the set of blueprint names this thread's own tasks + its
# `blueprints` field name (spec S2.2 step 5) -- `state` is added by the
# caller, which already has it from the thread record.
#
# \%cache and \$link_budget are optional, forwarded to _link_resolve. When
# \$link_budget is given and reaches 0, further linked tasks in this (and any
# later) thread degrade to the same "missing" rendering as an invalid link,
# without attempting another ledger read -- redteam M2's global cap.
sub _thread_build {
    my ($project_root, $blueprints_root, $name, $fields, $cache, $link_budget) = @_;

    my $tasks_dir = "$project_root/.ccpraxis-local-data/almanac/thread-tasks-$name";
    # S3/M1 fix: filter by name only first (no stat), so an over-cap
    # directory (the abuse case this cap exists for) is rejected without
    # stat'ing every entry -- measured ~1.7s per scan at 5000 entries vs
    # 0.007s matching names only.
    my @raw_ids;
    if (-d $tasks_dir && !-l $tasks_dir) {
        if (opendir(my $dh, $tasks_dir)) {
            for my $e (readdir $dh) {
                next unless $e =~ /\A(.+)\.md\z/;
                my $id = $1;
                next unless _valid_record_id($id);
                push @raw_ids, [ $id, $e ];
            }
            closedir $dh;
        }
    }
    # Over the cap the task set is not read at all (the abuse case the cap
    # exists for), but the THREAD stays: dropping it used to make a thread
    # vanish from the dashboard once it accumulated its 513th task, with
    # another thread silently taking its line (redteam L6). It keeps its
    # owner and its `blueprints` claim, and says why its progress is absent.
    if (scalar(@raw_ids) > $MAX_THREAD_TASKS) {
        my %driven_cap;
        if (defined($fields->{blueprints}) && length($fields->{blueprints})) {
            $driven_cap{$_} = 1 for split /,/, $fields->{blueprints};
        }
        return {
            name => $name, done => 0, total => 0, doing => [],
            current => { class => 'blocked', kind => 'text',
                         title => "over $MAX_THREAD_TASKS tasks, not read", waits_on => undef },
            next => undef,
            owner => _build_owner($blueprints_root, $project_root, $fields),
            driven => \%driven_cap,
        };
    }

    my @candidates;
    for my $pair (@raw_ids) {
        my ($id, $e) = @$pair;
        push @candidates, $id if -f "$tasks_dir/$e" && !-l "$tasks_dir/$e";
    }

    my @parsed;
    for my $id (sort @candidates) {
        my $blob = _read_capped("$tasks_dir/$id.md", $MAX_ALMANAC_RECORD_BYTES);
        next unless defined $blob;
        my $f = _parse_record($blob);
        next unless ref($f) eq 'HASH';
        push @parsed, { id => $id, rank => $f->{rank}, fields => $f };
    }
    @parsed = sort { _rank_id_cmp_local($a->{rank}, $b->{rank}, $a->{id}, $b->{id}) } @parsed;

    my %driven;
    if (defined($fields->{blueprints}) && length($fields->{blueprints})) {
        $driven{$_} = 1 for split /,/, $fields->{blueprints};
    }

    my @doing;
    my $current;
    my $next_label;
    my $done = 0;
    my $total = scalar(@parsed);

    for my $t (@parsed) {
        my $f = $t->{fields};
        my $link = $f->{link};
        my ($class, $label);
        if (defined($link) && length($link)) {
            my $budget_exhausted = ref($link_budget) eq 'SCALAR' && defined($$link_budget) && $$link_budget <= 0;
            my $r;
            if ($budget_exhausted) {
                $r = { state => 'invalid', blueprint => undef, package => undef, status => undef, step => undef };
            }
            else {
                $$link_budget-- if ref($link_budget) eq 'SCALAR' && defined($$link_budget);
                $r = _link_resolve($project_root, $link, $cache);
            }
            if ($r->{state} eq 'invalid') {
                $class = 'pending';
                my $title = _alm_text($link);
                $title = '' unless defined $title;
                $label = { class => $class, kind => 'text', title => "$title missing", waits_on => undef };
            }
            else {
                $driven{ $r->{blueprint} } = 1 if defined $r->{blueprint};
                my $number = (defined($r->{package}) && $r->{package} =~ /\A(\d+)/) ? $1 : $r->{package};
                if ($r->{state} eq 'ok') {
                    $class = _status_class($r->{status});
                    my $step = defined($r->{step}) ? $r->{step} : $r->{status};
                    $label = { class => $class, kind => 'link', blueprint => $r->{blueprint}, number => $number, step => $step };
                }
                else {   # missing
                    $class = 'pending';
                    $label = { class => $class, kind => 'link', blueprint => $r->{blueprint}, number => $number, step => 'missing' };
                }
            }
        }
        else {
            my $status = $f->{status};
            $status = '' unless defined $status;
            $class = ($status eq 'done' || $status eq 'obsoleted') ? 'done'
                   : ($status eq 'doing')                           ? 'doing'
                   : ($status eq 'blocked')                         ? 'blocked'
                   :                                                  'pending';
            my $title = _alm_text($f->{title});
            $title = $t->{id} unless defined($title) && length($title);
            my $waits_on = _alm_text($f->{blocked_on});
            $waits_on = undef unless defined($waits_on) && length($waits_on);
            $label = { class => $class, kind => 'text', title => $title, waits_on => $waits_on };
        }

        $done++ if $class eq 'done';
        push @doing, $label if $class eq 'doing';
        $current = $label if !defined($current) && $class ne 'done';
        $next_label = $label if !defined($next_label) && $class eq 'pending';
    }
    $current = undef if @doing;

    my $owner = _build_owner($blueprints_root, $project_root, $fields);

    return {
        name => $name, done => $done, total => $total,
        doing => \@doing, current => $current, next => $next_label,
        owner => $owner, driven => \%driven,
    };
}

# _utc_epoch($year, $month, $day, $hour, $min, $sec) -> Int | undef (private,
# pure). Seconds since 1970-01-01T00:00:00Z for a UTC civil instant, by the
# days-from-civil algorithm (proleptic Gregorian). undef for any field that is
# not a non-negative integer, a year before 1970, or an instant that does not
# exist (month 13, Feb 30, hour 24, minute or second 60).
sub _utc_epoch {
    my ($y, $mo, $d, $h, $mi, $s) = @_;
    for my $v ($y, $mo, $d, $h, $mi, $s) {
        return undef unless defined($v) && !ref($v) && $v =~ /\A\d{1,4}\z/;
    }
    ($y, $mo, $d, $h, $mi, $s) = map { $_ + 0 } ($y, $mo, $d, $h, $mi, $s);
    return undef if $y < 1970 || $mo < 1 || $mo > 12 || $h > 23 || $mi > 59 || $s > 59;
    my $leap = (($y % 4 == 0) && ($y % 100 != 0)) || ($y % 400 == 0);
    my @dim = (31, $leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
    return undef if $d < 1 || $d > $dim[$mo - 1];
    my $yy  = ($mo <= 2) ? $y - 1 : $y;
    my $era = int($yy / 400);
    my $yoe = $yy - $era * 400;
    my $doy = int((153 * ($mo > 2 ? $mo - 3 : $mo + 9) + 2) / 5) + $d - 1;
    my $doe = $yoe * 365 + int($yoe / 4) - int($yoe / 100) + $doy;
    my $days = $era * 146097 + $doe - 719468;
    return $days * 86400 + $h * 3600 + $mi * 60 + $s;
}

# _thread_events_for(\%kept, $project_root) -> \@events (private). Spec S2.2 step 7:
# project-level, the newest $MAX_THREAD_EVENTS entries across every kept
# thread, ascending by (epoch, thread, id).
sub _thread_events_for {
    my ($kept, $project_root) = @_;
    my $A = "$project_root/.ccpraxis-local-data/almanac";
    my @all;
    for my $name (sort keys %$kept) {
        my $ldir = "$A/thread-log-$name";
        next unless -d $ldir && !-l $ldir;
        next unless opendir(my $dh, $ldir);
        # S3/M1 fix: match names only first, sort and cut to the top N, and
        # stat only the survivors -- a thread log grows unboundedly, so
        # stat'ing every entry before the cut cost ~1.7s per scan at 5000
        # entries, measured, against 0.007s for the name match alone.
        my @raw_ids;
        for my $e (readdir $dh) {
            push @raw_ids, [ $1, $e ] if $e =~ /\A(\d{8})\.md\z/;
        }
        closedir $dh;
        next unless @raw_ids;
        @raw_ids = sort { $b->[0] <=> $a->[0] } @raw_ids;
        @raw_ids = @raw_ids[0 .. $MAX_THREAD_EVENTS - 1] if scalar(@raw_ids) > $MAX_THREAD_EVENTS;
        my @ids;
        for my $pair (@raw_ids) {
            my ($id, $e) = @$pair;
            next unless -f "$ldir/$e" && !-l "$ldir/$e";
            my @st = stat("$ldir/$e");
            my $mtime = (defined($st[9]) && $st[9] =~ /\A\d+\z/) ? $st[9] + 0 : undef;
            push @ids, [ $id, $mtime ];
        }
        for my $pair (@ids) {
            my ($id, $mtime) = @$pair;
            my $blob = _read_capped("$ldir/$id.md", $MAX_ALMANAC_RECORD_BYTES);
            next unless defined $blob;
            my $f = _parse_record($blob);
            next unless ref($f) eq 'HASH';
            my $event = $f->{event};
            # Only Almanac's own event vocabulary (redteam L3): the feed styles
            # rows by event name, so a free-form name like `x_dead` would pick
            # up crit styling and raise a false alarm.
            next unless defined($event) && $THREAD_EVENT_OK{$event};
            my $at = $f->{at};
            next unless defined($at) && $at =~ /\A(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z\z/;
            my ($yr, $mo, $dy, $h, $mi, $s) = ($1, $2, $3, $4, $5, $6);
            # Plain civil-date arithmetic (_utc_epoch), not Time::Local:
            # loading Time::Local calls the clock at module load, which broke
            # this module's "reads no clock" contract (redteam L1), and its
            # timegm reads years through a rolling-century heuristic (S2).
            # Anything before 1970 or not a real calendar instant is skipped.
            my $epoch = _utc_epoch($yr, $mo, $dy, $h, $mi, $s);
            next unless defined $epoch;
            # M3 fix: a thread record the container controls can set `at:`
            # to any future timestamp; without a ceiling it would sort as
            # the newest event forever and permanently occupy a slot in the
            # project-wide top-10 feed. The log file's own mtime (not the
            # clock) is the only trustworthy ceiling available to a
            # clock-free module.
            next if defined($mtime) && $epoch > $mtime + $FUTURE_EVENT_SLACK_SECONDS;
            push @all, {
                thread => $name, id => $id, at => $at, epoch => $epoch, event => $event,
                actor => $f->{actor}, session => $f->{session}, task => $f->{task},
                from => $f->{from}, to => $f->{to}, reason => $f->{reason},
            };
        }
    }
    @all = sort {
        $b->{epoch} <=> $a->{epoch} || $a->{thread} cmp $b->{thread} || $b->{id} cmp $a->{id}
    } @all;
    @all = @all[0 .. $MAX_THREAD_EVENTS - 1] if scalar(@all) > $MAX_THREAD_EVENTS;
    @all = sort {
        $a->{epoch} <=> $b->{epoch} || $a->{thread} cmp $b->{thread} || $a->{id} cmp $b->{id}
    } @all;
    return \@all;
}

# _thread_index($blueprints_root) -> { by_bp => {...}, events => [...] }
# (private, pinned name)
#
# Never undef, never dies. On any failure (no project root, no thread/ dir,
# an over-cap thread-record set) it returns the empty shape. Spec S2.2's
# full algorithm.
sub _thread_index {
    my ($blueprints_root) = @_;
    my $empty = { by_bp => {}, events => [] };

    my $P = _project_root($blueprints_root);
    return $empty unless defined $P;
    my $A = "$P/.ccpraxis-local-data/almanac";
    my $tdir = "$A/thread";
    return $empty if -l $tdir;
    return $empty unless -d $tdir;

    # S3/M1 fix: match/validate names only first (no stat), so an over-cap
    # thread/ directory is rejected without stat'ing every entry.
    my @raw_stems;
    if (opendir(my $dh, $tdir)) {
        for my $e (readdir $dh) {
            next unless $e =~ /\A(.+)\.md\z/;
            my $stem = $1;
            push @raw_stems, [ $stem, $e ] if _valid_thread_name($stem);
        }
        closedir $dh;
    }
    return $empty if scalar(@raw_stems) > $MAX_THREAD_RECORDS;

    my @candidates;
    for my $pair (@raw_stems) {
        my ($stem, $e) = @$pair;
        push @candidates, $stem if -f "$tdir/$e" && !-l "$tdir/$e";
    }

    my %kept;
    my %ledger_cache;                                 # spec S2.2 step 4
    my $link_budget = $MAX_INDEX_LINK_RESOLUTIONS;    # redteam M2 global cap
    for my $name (sort @candidates) {
        my $blob = _read_capped("$tdir/$name.md", $MAX_ALMANAC_RECORD_BYTES);
        next unless defined $blob;
        my $fields = _parse_record($blob);
        next unless ref($fields) eq 'HASH';
        my $state = $fields->{state};
        next unless defined($state) && ($state eq 'live' || $state eq 'handed-off');

        my $built = _thread_build($P, $blueprints_root, $name, $fields, \%ledger_cache, \$link_budget);
        next unless ref($built) eq 'HASH';
        $built->{state} = $state;
        $kept{$name} = $built;
    }

    my %by_bp_candidates;
    for my $name (keys %kept) {
        for my $bp (keys %{ $kept{$name}{driven} }) {
            push @{ $by_bp_candidates{$bp} }, $name;
        }
    }

    my %by_bp;
    for my $bp (keys %by_bp_candidates) {
        my $winner;
        for my $name (@{ $by_bp_candidates{$bp} }) {
            if (!defined $winner) { $winner = $name; next; }
            my $t = $kept{$name};
            my $w = $kept{$winner};
            my $t_live = ($t->{state} eq 'live') ? 0 : 1;
            my $w_live = ($w->{state} eq 'live') ? 0 : 1;
            if ($t_live != $w_live) { $winner = $name if $t_live < $w_live; next; }
            my $t_orch = ($t->{owner}{kind} eq 'orchestrator' && defined($t->{owner}{id}) && $t->{owner}{id} eq $bp) ? 0 : 1;
            my $w_orch = ($w->{owner}{kind} eq 'orchestrator' && defined($w->{owner}{id}) && $w->{owner}{id} eq $bp) ? 0 : 1;
            if ($t_orch != $w_orch) { $winner = $name if $t_orch < $w_orch; next; }
            $winner = $name if ($name cmp $winner) < 0;
        }
        $by_bp{$bp} = $kept{$winner} if defined $winner;
    }

    my $events = _thread_events_for(\%kept, $P);
    return { by_bp => \%by_bp, events => $events };
}

# summarize_dir($blueprint_dir) -> \%summary | undef
#
# Builds the S2.2 summary for ONE blueprint directory. undef (the blueprint
# contributes no row -- Rule 4 "no data yet") when: $blueprint_dir is
# undef/zero-length/not a directory; or NEITHER a usable ledger set (>=1
# candidate under packages/) NOR a usable registry (a decodable JSON HASH,
# <= $MAX_PACKAGES non-'_' keys) is available.
#
# 04-run-panel-ledger-truth / Decision 3: progress (packages_total /
# packages_done / current_package) is derived from the LEDGER set whenever
# packages/ yields at least one candidate; the registry key set is used only
# as a fallback when packages/ yields none. runs/ (and therefore
# registry.json) need not exist at all for a ledger-driven blueprint (state
# 'solo'). A blueprint whose recorded coordinator PID is checked-dead (via
# the injected $PID_ALIVE) never reports a live coordinator (state 'stale',
# running_coordinators 0), regardless of what the registry claims. Never
# dies.
sub summarize_dir {
    my ($blueprint_dir, $agent_index, $thread_index) = @_;
    return undef unless defined $blueprint_dir && !ref($blueprint_dir)
        && length($blueprint_dir) && -d $blueprint_dir;

    # 05-runstate-agent-aggregation (spec S2.1/S2.6): $agent_index is an
    # optional second parameter, a HashRef in the shape _dispatch_index
    # returns. When it is NOT a HASH ref (undef, a scalar, an arrayref, a
    # blessed object), it is ignored entirely and this call builds its own
    # index -- the anchor is the parent of $blueprint_dir, normalised the
    # same way _dispatch_dir itself normalises its own input.
    my $idx;
    if (ref($agent_index) eq 'HASH') {
        $idx = $agent_index;
    }
    else {
        my $parent = $blueprint_dir;
        $parent =~ s{\\}{/}g;
        $parent =~ s{/+\z}{};
        $parent =~ s{/[^/]*\z}{};
        $idx = _dispatch_index(_dispatch_dir($parent));
    }

    # package 13-dashboard-threads (spec S2.2): $thread_index is an optional
    # third parameter, in the shape _thread_index returns -- same "ignored
    # when not a HASH, this call builds its own" discipline as $agent_index
    # above, same parent-of-$blueprint_dir anchor.
    my $tidx;
    if (ref($thread_index) eq 'HASH') {
        $tidx = $thread_index;
    }
    else {
        my $parent = $blueprint_dir;
        $parent =~ s{\\}{/}g;
        $parent =~ s{/+\z}{};
        $parent =~ s{/[^/]*\z}{};
        $tidx = _thread_index($parent);
    }

    # S2.6: $bp_name is the SAME value the summary emits as its own
    # `blueprint` key, computed by the same three lines used below -- pinned
    # here too so the record's `blueprint` field is matched against exactly
    # the string the panel displays.
    my $bp_name = $blueprint_dir;
    $bp_name =~ s{/+$}{};
    $bp_name = (split m{/}, $bp_name)[-1];
    my $by_pkg = (ref($idx) eq 'HASH' && ref($idx->{$bp_name}) eq 'HASH') ? $idx->{$bp_name} : {};

    my $runs_dir = "$blueprint_dir/runs";
    my $has_runs = (-d $runs_dir) ? 1 : 0;

    my $reg;
    if ($has_runs) {
        my $blob = _read_capped("$runs_dir/registry.json", $MAX_REGISTRY_BYTES);
        if (defined $blob) {
            # MEDIUM-8: a cap-compliant-BY-BYTES but cardinality-hostile
            # registry (many small keys) must never reach the multi-second
            # pure-Perl JSON::PP decode on the 10s gather tick (adapter
            # Rule 1: never block). Cheap regex pre-count of `"<key>":{`
            # occurrences in the RAW bytes, before any decode is attempted --
            # a rough over-estimate is fine (top-level "packages":{ itself
            # also matches, and nested objects would too, so this can only
            # ever over-count, never under-count past $MAX_PACKAGES for a
            # registry shaped like ours). $MAX_REGISTRY_BYTES stays at 4 MiB
            # (not lowered) -- lowering it would reject legitimate
            # cap-compliant registries at the byte layer before this guard
            # even runs.
            my $rough_key_count = () = $blob =~ /"(?:[^"\\]|\\.)*"\s*:\s*\{/g;
            if ($rough_key_count <= $MAX_PACKAGES) {
                local $@;
                my $data = eval { JSON::PP->new->decode($blob) };
                $reg = (ref($data) eq 'HASH') ? $data : undef;
            }
        }
    }

    # MINOR-5: exclude butler's underscore-prefixed bookkeeping pseudo-keys
    # (e.g. "_run", written by bp-remediate.pl) from the package count/loop --
    # they are not packages and inflate the denominator with a status-less
    # entry.
    my $reg_pkgs = (ref($reg) eq 'HASH' && ref($reg->{packages}) eq 'HASH') ? $reg->{packages} : {};
    my @reg_keys = grep { !/\A_/ } keys %$reg_pkgs;
    # MAJOR-2: a registry whose package count exceeds $MAX_PACKAGES is
    # treated as unusable -- the same "over cap -> unreadable" degradation
    # the byte caps above already use, so a cap-compliant-by-bytes-but-
    # cardinality-hostile registry cannot force a 10s-cadence walk of
    # hundreds of thousands of keys.
    my $reg_usable = defined($reg) && (scalar(@reg_keys) <= $MAX_PACKAGES);

    my $ledgers = _ledger_packages($blueprint_dir);

    # HIGH-4: an over-cap ledger set must degrade HONESTLY -- no row at all
    # -- rather than silently substituting the (much smaller, contradicting)
    # registry key set as a fabricated truth. This is enforced HERE, not
    # inside _ledger_packages, precisely so it can return undef directly
    # instead of falling into the registry-fallback branch below.
    return undef if defined($ledgers) && scalar(@$ledgers) > $MAX_PACKAGES;

    my $ledger_mode = (defined($ledgers) && @$ledgers) ? 1 : 0;
    my @pkgs;
    if ($ledger_mode) {
        @pkgs = @$ledgers;
    }
    elsif ($reg_usable) {
        @pkgs = @reg_keys;
    }
    else {
        return undef;   # Rule 4 "no data yet" -- neither source is usable
    }

    my $packages_total = scalar @pkgs;
    my $packages_done  = 0;
    my $running_count  = 0;
    my $current_package;
    my @packages_out;   # 04-runstate-run-and-package-facts: ArrayRef[HashRef], ledger order
    for my $pkg (sort @pkgs) {
        my $entry = $reg_pkgs->{$pkg};
        # HIGH-2 governing rule: the registry is consulted only when the
        # package has NO ledger file at all ($ledger_mode true means every
        # $pkg here came from a real, present packages/<pkg>.md).
        my $status = _effective_status($blueprint_dir, $pkg, $entry, $ledger_mode);
        $packages_done++ if $status eq 'done';
        if ($status eq 'running') {
            # MEDIUM-7: a per-package registry-recorded coordinator PID is
            # now liveness-checked too (via the same injected $PID_ALIVE,
            # no new probe) -- previously ONLY the orchestrator PID was ever
            # probed, so a crashed per-package coordinator (whose ledger was
            # written 'running' before the risky step, by design) inflated
            # running_coordinators forever. Fail-safe: an UNKNOWN per-package
            # liveness (no pid recorded, non-numeric, or the prober itself
            # can't decide) still counts -- only a POSITIVELY checked-dead
            # per-package PID is excluded.
            my $pkg_pid = (ref($entry) eq 'HASH') ? $entry->{pid} : undef;
            my $pkg_alive = (defined($pkg_pid) && !ref($pkg_pid) && $pkg_pid =~ /\A\d+\z/)
                ? _pid_state($pkg_pid + 0) : undef;
            my $pkg_checked_dead = (defined($pkg_alive) && !$pkg_alive) ? 1 : 0;
            $running_count++ unless $pkg_checked_dead;
            # MAJOR-3: current_package is a display value (s11 renders the
            # same struct); bound its length at the producer so an
            # oversized key can never reach a per-character sanitizer
            # downstream at full length.
            $current_package = (length($pkg) > 128 ? substr($pkg, 0, 128) : $pkg)
                unless defined $current_package;
        }

        # 04-runstate-run-and-package-facts (spec S2.4): the displayed
        # attempt is effective_attempts (attempts - turn_continuations -
        # rate_limit_discounts, floored at 0) -- the number the orchestrator
        # actually acts on, not the raw registry `attempt`. Undef whenever
        # the registry itself is unusable or this package's entry is not a
        # HASH; a registry-fallback entry (no ledger file) still populates
        # it from the same $entry the loop already fetched, no second read.
        my ($attempt, $attempt_cap);
        if ($reg_usable && ref($entry) eq 'HASH') {
            my $raw   = _reg_count($entry->{attempt});
            my $tc    = _reg_count($entry->{turn_continuations});
            my $rld   = _reg_count($entry->{rate_limit_discounts});
            my $n     = $raw - $tc - $rld;
            $attempt     = $n < 0 ? 0 : $n;
            $attempt_cap = _attempt_cap();
        }

        # spec S2.7: ledger-derived facts are independent of $ledger_mode --
        # a registry-fallback package (no packages/<pkg>.md at all) simply
        # has no file for _read_head to find, so _ledger_facts naturally
        # returns all-undef without any special-casing here.
        my $facts = _ledger_facts($blueprint_dir, $pkg);

        # 05-runstate-agent-aggregation (spec S2.2/S2.6): a fresh arrayref of
        # fresh element hashes per entry, never aliased into the shared index
        # (AC39) -- `[ @$list ]` alone only copies the list, not the element
        # hashrefs inside it, and those elements are the same SVs that live
        # in %idx; `[ map { { %$_ } } @$list ]` copies both levels (fix-batch
        # MEDIUM-2 / red-team 05-redteam.md).
        my $pkg_agent_list = $by_pkg->{$pkg};
        my $agents = (ref($pkg_agent_list) eq 'ARRAY') ? [ map { { %$_ } } @$pkg_agent_list ] : [];

        push @packages_out, {
            name          => $pkg,
            status        => (length($status) ? $status : undef),
            attempt       => $attempt,
            attempt_cap   => $attempt_cap,
            step          => $facts->{step},
            steps_pending => $facts->{steps_pending},
            next_action   => $facts->{next_action},
            agents        => $agents,
        };
    }

    my $has_shutdown = $has_runs && -e "$runs_dir/.shutdown";
    my $has_paused   = $has_runs && -e "$runs_dir/.paused";
    my $has_orch     = $has_runs && -e "$runs_dir/.orchestrator";

    my $orchestrator_pid = $has_runs ? _orchestrator_pid("$runs_dir/.orchestrator") : undef;
    my $alive = _pid_state($orchestrator_pid);
    my $dead  = (defined($alive) && !$alive) ? 1 : 0;   # ONLY a positive "checked and dead"

    my $state = $has_shutdown                        ? 'parked'
              : (($has_orch || $has_paused) && $dead) ? 'stale'
              : $has_paused                           ? 'paused'
              : $has_orch                             ? 'running'
              : !$has_runs                            ? 'solo'
              :                                         'idle';

    my $running_coordinators = ($has_orch && !$dead && $reg_usable) ? $running_count : 0;

    # 04-runstate-run-and-package-facts (spec S2.3, driver ruling AT-5):
    # $alive is REUSED verbatim, not re-probed (AC9 -- no second probe).
    # orchestrator_started_at is the marker's mtime (driver-side, never a
    # self-report, never a computed uptime -- RunState may not read a
    # clock), suppressed the moment the pid is POSITIVELY checked-dead so a
    # stale marker cannot yield an ever-growing uptime downstream. Unknown
    # liveness does NOT suppress it (a dead prober or missing prober is not
    # evidence of death). NOTE (fix-batch HIGH-1, left UNCHANGED -- see the
    # implementer's report): the requested revision, gating on $alive == 1
    # rather than !$dead, contradicts spec S2.3's own worked example ("unknown
    # liveness is not treated as death") and t/184 AC6 (an IMMUTABLE oracle,
    # not in this batch's two authorised test edits), which asserts
    # orchestrator_started_at stays DEFINED for all three unknown-liveness
    # sub-cases. The red-team report's own "Minimal mitigation" for HIGH-1
    # (04-redteam.md ~line 72) places the fix in package 06's renderer
    # ("an uptime may be rendered only when orchestrator_alive == 1"), not
    # here. Implementing HIGH-1 as literally worded in this dispatch breaks
    # AC6 (verified: 3 `not ok`) and the spec text simultaneously, so it is
    # left as-is pending coordinator adjudication.
    my $orchestrator_alive = $alive;
    my $orchestrator_started_at =
        (!$has_orch) ? undef
      : $dead         ? undef
      :                 _mtime("$runs_dir/.orchestrator");

    my ($paused_manual, $paused_reason) = _paused_info("$runs_dir/.paused");

    # t07: "the run is over" is exactly what $state already computes, so it is
    # read from there rather than re-derived. `idle` and `solo` mean nothing is
    # running and nothing is paused; `parked` means a shutdown marker is
    # present. `stale` is deliberately NOT in the set: a dead orchestrator with
    # a .paused still on disk is an abandoned run, and abandoning a run is not
    # the same as answering the question it was blocked on.
    my $run_over = ($state eq 'idle' || $state eq 'solo' || $state eq 'parked') ? 1 : 0;

    # package blueprint-park (08) (spec §2.8): blueprint.md's own authored
    # 'parked' beats everything, including a live orchestrator marker --
    # state 'parked' now ALSO means "blueprint.md authored parked", not only
    # "a runs/.shutdown marker exists". $run_over, computed above, is derived
    # from the run markers only and is NOT recomputed here: escalations/
    # inbox/triage waiting counts stay exactly what the same fixture reports
    # under any other authored value. No new key -- the run-level key set is closed (19 keys since package 13).
    $state = 'parked' if _bp_authored_parked($blueprint_dir);
    # The queue directory was renamed needs-you -> escalations: the old name
    # claimed the operator owns every record, and most are resolver-owned.
    # bp-orchestrator.pl migrates it on its first tick, but this module RENDERS
    # -- it must never write, and it must show the truth about a tree that has
    # not ticked since the rename. So: read whichever exists, preferring the new
    # name. A run mid-migration reads correctly under either.
    my $q_dir = "$runs_dir/" . ESCALATIONS_DIRNAME;
    $q_dir = "$runs_dir/" . ESCALATIONS_LEGACY
        if !-d $q_dir && -d "$runs_dir/" . ESCALATIONS_LEGACY;
    my $split = _count_decisions_split($q_dir, $blueprint_dir, $run_over);
    # escalations_waiting stays the TOTAL, so every existing consumer keeps the
    # number it has always had. The split is additive.
    my $escalations_waiting = $split->{operator} + $split->{triage};
    my $inbox_waiting       = $split->{operator};
    my $triage_waiting      = $split->{triage};

    # Ruling AT-8: a 17th run-level key, run_agents, holding agents whose
    # `package` is the orchestrator's `_run` pseudo-package (Decision 10's
    # blueprint-scoped conformance judge, bp-orchestrator.pl:2095). `agents`
    # nests inside `packages`, and `_run` is not a real package (it is
    # excluded from @pkgs above by the registry's own underscore-prefix
    # filter and never has a packages/_run.md ledger), so it has nowhere to
    # attach inside the packages loop -- same $by_pkg lookup, same fresh-copy
    # rule (never aliased into the shared index).
    my $run_agent_list = $by_pkg->{'_run'};
    my $run_agents = (ref($run_agent_list) eq 'ARRAY') ? [ map { { %$_ } } @$run_agent_list ] : [];

    # package 13-dashboard-threads (spec S2.2): the 18th/19th run-level keys.
    # `thread` is a FRESH deep copy of whichever thread $tidx chose to drive
    # THIS blueprint (undef when none does); `thread_events` is a fresh deep
    # copy of the project-level list, identical across every summary from one
    # summarize() call but never the same reference (AC1/B7).
    my $chosen = (ref($tidx) eq 'HASH' && ref($tidx->{by_bp}) eq 'HASH') ? $tidx->{by_bp}{$bp_name} : undef;
    my $thread_out;
    if (ref($chosen) eq 'HASH') {
        $thread_out = {
            name    => $chosen->{name},
            state   => $chosen->{state},
            done    => $chosen->{done},
            total   => $chosen->{total},
            doing   => [ map { { %$_ } } @{ $chosen->{doing} || [] } ],
            current => (ref($chosen->{current}) eq 'HASH') ? { %{ $chosen->{current} } } : undef,
            next    => (ref($chosen->{next})    eq 'HASH') ? { %{ $chosen->{next} } }    : undef,
            owner   => (ref($chosen->{owner})   eq 'HASH') ? { %{ $chosen->{owner} } }   : undef,
        };
        # redteam L4: an orchestrator owner's `alive` was read from the
        # .orchestrator marker of the blueprint the owner id names. On THIS
        # blueprint's line that says nothing unless it is this blueprint, so
        # a thread owned by another blueprint's orchestrator renders its
        # liveness as unknown rather than borrowing that one's "live".
        my $o = $thread_out->{owner};
        if (ref($o) eq 'HASH' && defined($o->{kind}) && $o->{kind} eq 'orchestrator'
            && !(defined($o->{id}) && !ref($o->{id}) && defined($bp_name) && $o->{id} eq $bp_name)) {
            $o->{alive} = undef;
        }
    }
    my $thread_events_src = (ref($tidx) eq 'HASH' && ref($tidx->{events}) eq 'ARRAY') ? $tidx->{events} : [];
    my $thread_events_out = [ map { { %$_ } } @$thread_events_src ];

    return {
        blueprint               => $bp_name,
        runs_dir                => $runs_dir,
        state                   => $state,
        orchestrator_pid        => $orchestrator_pid,
        orchestrator_alive      => $orchestrator_alive,
        orchestrator_started_at => $orchestrator_started_at,
        paused_manual           => $paused_manual,
        paused_reason           => $paused_reason,
        packages_total          => $packages_total,
        packages_done           => $packages_done,
        current_package         => $current_package,
        running_coordinators    => $running_coordinators,
        escalations_waiting     => $escalations_waiting,
        inbox_waiting           => $inbox_waiting,
        triage_waiting          => $triage_waiting,
        packages                => \@packages_out,
        run_agents              => $run_agents,
        thread                  => $thread_out,
        thread_events           => $thread_events_out,
    };
}

# summarize($blueprints_root) -> \@summaries
#
# Always returns an ARRAYREF ([] when there is nothing to report). Never
# undef, never dies, for any input whatsoever. Equivalent to
# [ grep { defined } map { summarize_dir($_) } blueprint_dirs($root) ].
# Per-blueprint isolation: one blueprint with a malformed registry never
# suppresses, alters, or reorders any sibling's summary. Order is ascending
# by blueprint directory name (inherited from blueprint_dirs).
#
# 05-runstate-agent-aggregation (spec S2.1, Decision 9): the dispatch-log
# index is built ONCE here and passed to every summarize_dir call, rather
# than each blueprint re-enumerating and re-opening the same records --
# without this, an 11-run dashboard would pay the opendir + up-to-512
# head-reads eleven times per 10s gather tick instead of once.
#
# summarize($root, \%extra) -- the optional second argument is an OUT
# parameter: when it is a HASH ref, $extra->{thread_events} receives a fresh
# deep copy of the PROJECT-level thread_events (the same list every summary
# also carries), filled even when no blueprint yields a summary. That is the
# only way thread activity reaches the dashboard for a project with no
# blueprint on it (todo 20261002-193830-34ac0000): the per-summary copies need
# a summary to ride on. An out parameter rather than a new return shape, so
# every existing caller keeps its arrayref and the index is still built once.
sub summarize {
    my ($root, $extra) = @_;
    my $idx = _dispatch_index(_dispatch_dir($root));
    # package 13-dashboard-threads (spec S2.2): the thread index is built
    # ONCE here too, same reasoning as the dispatch index above.
    my $tidx = _thread_index($root);
    my @out;
    for my $dir (blueprint_dirs($root)) {
        my $s = summarize_dir($dir, $idx, $tidx);
        push @out, $s if defined $s;
    }
    if (ref($extra) eq 'HASH') {
        my $src = (ref($tidx) eq 'HASH' && ref($tidx->{events}) eq 'ARRAY') ? $tidx->{events} : [];
        $extra->{thread_events} = [ map { { %$_ } } @$src ];
    }
    return \@out;
}

1;
