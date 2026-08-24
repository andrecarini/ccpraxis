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

our $MAX_REGISTRY_BYTES = 4 * 1024 * 1024;   # 4 MiB, mirrors SessionFilter
our $MAX_LEDGER_BYTES   = 65536;             # 64 KiB of a package ledger is plenty for frontmatter
our $MAX_MARKER_BYTES   = 4096;              # .orchestrator / .paused are tiny
our $MAX_PACKAGES       = 512;               # a registry (or ledger set) with more package keys
                                              # than this is treated as unreadable (falls back /
                                              # skips the blueprint), same degradation the byte
                                              # caps above already use

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
# clears them (bp-answer-decision.pl's clear_pkg_decisions, and only for a
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
    my ($blueprint_dir) = @_;
    return undef unless defined $blueprint_dir && !ref($blueprint_dir)
        && length($blueprint_dir) && -d $blueprint_dir;

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

    my ($paused_manual, $paused_reason) = _paused_info("$runs_dir/.paused");

    # t07: "the run is over" is exactly what $state already computes, so it is
    # read from there rather than re-derived. `idle` and `solo` mean nothing is
    # running and nothing is paused; `parked` means a shutdown marker is
    # present. `stale` is deliberately NOT in the set: a dead orchestrator with
    # a .paused still on disk is an abandoned run, and abandoning a run is not
    # the same as answering the question it was blocked on.
    my $run_over = ($state eq 'idle' || $state eq 'solo' || $state eq 'parked') ? 1 : 0;
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
    # decisions_waiting stays the TOTAL, so every existing consumer keeps the
    # number it has always had. The split is additive.
    my $decisions_waiting  = $split->{operator} + $split->{triage};
    my $decisions_operator = $split->{operator};
    my $decisions_triage   = $split->{triage};

    my $bp_name = $blueprint_dir;
    $bp_name =~ s{/+$}{};
    $bp_name = (split m{/}, $bp_name)[-1];

    return {
        blueprint            => $bp_name,
        runs_dir             => $runs_dir,
        state                => $state,
        orchestrator_pid     => $orchestrator_pid,
        paused_manual        => $paused_manual,
        paused_reason        => $paused_reason,
        packages_total       => $packages_total,
        packages_done        => $packages_done,
        current_package      => $current_package,
        running_coordinators => $running_coordinators,
        decisions_waiting    => $decisions_waiting,
        decisions_operator   => $decisions_operator,
        decisions_triage     => $decisions_triage,
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
sub summarize {
    my ($root) = @_;
    my @out;
    for my $dir (blueprint_dirs($root)) {
        my $s = summarize_dir($dir);
        push @out, $s if defined $s;
    }
    return \@out;
}

1;
