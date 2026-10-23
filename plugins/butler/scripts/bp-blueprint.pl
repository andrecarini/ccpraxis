#!/usr/bin/env perl
# bp-blueprint.pl — the deterministic blueprint.md write/read API (b43-blueprint-write-api).
#
# Typed, surgical write ops (add-package, set-deps, add-decision,
# set-decision, set-field, add-harvest, set-meta, set-section, set-test-paths, init) plus
# four read ops (show, deps, status, decisions) over the
# package-status table `bp-orchestrator.pl`'s BpOrch::parse_dag reads. `set-status` is
# retired (Decision 11/s03: the table has no `status` column any more) -- it still
# dispatches, but only to refuse loudly; `set-field --field status` refuses the same way.
# `ready` was a read op and no longer exists. See:
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b43-blueprint-write-api-spec.md
#
# WHY THIS EXISTS: every hand-splice of blueprint.md to date has been correct by luck,
# never by construction (spec preamble). This API makes "correct by construction" the
# only path: atomic temp+rename under flock, refuse-rather-than-guess validation, and
# the SAME parser (BpOrch::parse_dag) the orchestrator reads with -- never a second,
# drifting implementation (spec §2.3, the b12/b13 lesson).
#
# :raw ONLY, throughout. NEVER add an :encoding(UTF-8) layer -- the file carries
# Andr\x{e9}-class paths and multi-byte status glyphs as raw bytes; decoding them and
# re-encoding on write would corrupt the byte-identical round trip (spec G11 / landmine 2).
#
# Exit codes (not part of the oracle's contract, but kept consistent with bp-ledger.pl's
# shape): 0 success, 2 validation refusal (byte-identical file), 3 usage/argument error
# (nothing read), 4 I/O/lock/atomicity failure (byte-identical), 5 target not found.
#
# Core Perl only: strict, warnings, Getopt::Long, Fcntl(:flock), File::Basename. The two
# REAL parsers/validators (BpOrch::parse_dag / BpOrch::resolve_dep_token, both living in
# bp-orchestrator.pl) are `require`d, never reimplemented (spec §2.3).
use strict;
use warnings;
use Getopt::Long qw(GetOptionsFromArray);
use Fcntl qw(:flock);
use File::Basename qw(dirname basename);
use Cwd qw(abs_path);

# abs_path, NOT bare dirname(__FILE__): invoked as `perl plugins/butler/scripts/bp-blueprint.pl`
# from the repo root, __FILE__ is RELATIVE, so $DIR is relative, and `require "$DIR/..."` searches
# @INC — which has not contained '.' since perl 5.26. The script then dies with
# "Can't locate plugins/butler/scripts/bp-orchestrator.pl in @INC" for every real invocation.
# t/86 did not catch it because the harness supplies its own @INC. bp-drive-next.pl already uses
# this form; bp-validate-dag.pl has the same latent bug, masked by callers passing `-I.`.
my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; abs_path($f) // $f });

# The REAL parser/resolver. Never reimplement BpOrch::parse_dag or
# BpOrch::resolve_dep_token -- this is the b12/b13 lesson restated (spec §2.3).
require "$DIR/bp-orchestrator.pl";

# bp-validate-dag.pl shares BpOrch::resolve_dep_token (it only (re)defines it "unless
# already defined" -- bp-orchestrator.pl already defines it, so this require is a no-op
# on that function and exists here so both scripts are provably consuming the one real
# implementation, not two that could drift (spec §2.3's "do not grow a second one").
require "$DIR/bp-validate-dag.pl";

# =====================================================================================
# Package status is no longer a blueprint.md TABLE concern (Decision 11,
# s03-drop-table-status-column). It is written and read via the package LEDGER
# (packages/<pkg>.md `status:`, guarded by ledger-guard.sh) and BpState.pm /
# /butler:status -- never via this script's write verbs. The seven-glyph
# vocabulary that used to live here (and its legend/help/normalize machinery) is
# retired along with the table column; `dropped` remains a live LEDGER status
# (bp-drive-next.pl, bp-orchestrator.pl, ledger-guard.sh, stop-gate.sh,
# bp-ledger.pl all still enforce it there -- none of those files are touched by
# this retirement).
# =====================================================================================

my $STATUS_RETIRED_MSG =
    "package status no longer lives in blueprint.md's table (Decision 11) -- write it via "
  . "bp-ledger.pl set-status against the package ledger (packages/<pkg>.md 'status:', guarded "
  . "by ledger-guard.sh); read it via BpState::package_status / all_package_statuses "
  . "(plugins/butler/scripts/BpState.pm) or /butler:status.";

my $PKG_ID_RE = qr/^[A-Za-z0-9][A-Za-z0-9_.-]*$/;
my $DEP_TOK_RE = qr/^[A-Za-z0-9][A-Za-z0-9_.-]*$/;

# =====================================================================================
# stderr / exit helpers -- one line, one framing convention: `bp-blueprint: <sub>: ...`
# =====================================================================================

sub emit_err {
    my ($m) = @_;
    $m =~ s/[\r\n]+/ /g;
    print STDERR $m . "\n";
}
sub arg_error      { my ($sub, $msg) = @_; emit_err("bp-blueprint: $sub: $msg"); exit 3 }
sub io_error       { my ($sub, $msg) = @_; emit_err("bp-blueprint: $sub: $msg"); exit 4 }
sub reject_error   { my ($sub, $msg) = @_; emit_err("bp-blueprint: $sub: $msg"); exit 2 }
sub notfound_error { my ($sub, $msg) = @_; emit_err("bp-blueprint: $sub: $msg"); exit 5 }

# =====================================================================================
# Byte-level I/O.
# =====================================================================================

sub _today {
    my @t = gmtime(time);
    return sprintf('%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3]);
}

sub _slurp {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $r = <$fh>;
    close $fh;
    return defined $r ? $r : '';
}

# =====================================================================================
# Table location -- DIVERGES from BpOrch::parse_dag's latch on purpose (a02 defect 7 /
# spec §2.4, §5.3). parse_dag (the READER) still latches onto the first `|`-row anywhere
# containing "depends_on"; that is unchanged here and is s03's decision to revisit.
# This WRITER anchors on the "## Package status" heading and searches only inside that
# section, so an ordinary prose table above it (which may itself name "depends_on" in a
# header) can never be captured. If the heading is present but its section has no
# depends_on row, this REFUSES (returns undef) rather than falling back to a global
# re-scan -- a re-scan is exactly the bug this fixes. If the heading is absent entirely,
# this falls back to today's whole-document scan (legacy documents, spec observable 35).
# split(..., -1) keeps a trailing empty element so join("\n", @lines) round-trips a file
# byte-for-byte when nothing in it changes.
# =====================================================================================

my $PKG_STATUS_HEAD_RE = qr/^##\s+Package\s+status\b/i;

sub _table_cols {
    my ($ln) = @_;
    $ln =~ s/^\s*\|//; $ln =~ s/\|\s*$//;
    my @c = split /\|/, $ln, -1;
    s/^\s+//, s/\s+$// for @c;
    return @c;
}

my $FENCE_RE = qr/^\s*(?:`{3,}|~{3,})/;

sub locate_table {
    my ($B) = @_;
    my @lines = split /\n/, $B, -1;

    # 1. Anchor on the heading; search only inside that section. Absent -> legacy
    #    whole-document fallback.
    #
    # step-6 red-team MAJOR-6: $PKG_STATUS_HEAD_RE previously matched the
    # FIRST "## Package status"-shaped line anywhere, including inside a
    # fenced code block -- a blueprint documenting its own format (authoring
    # guidance actively encourages this) bricks EVERY typed write for the
    # whole document, since the "section" it computes ends at the REAL
    # heading (also `^##\s`) with no depends_on row in the empty span between
    # them. Fixed two ways: (a) skip fenced regions (``` / ~~~) entirely when
    # collecting heading candidates, so a documentation fence can never be
    # mistaken for the real section start; (b) collect EVERY unfenced
    # candidate and try them in document order, refusing only after every
    # candidate's section has been searched and none has a depends_on row --
    # not just the first candidate found, per the same reasoning.
    my @candidates;
    my $in_fence = 0;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ $FENCE_RE) { $in_fence = !$in_fence; next }
        next if $in_fence;
        push @candidates, $i if $lines[$i] =~ $PKG_STATUS_HEAD_RE;
    }

    my ($lo, $hi);
    if (@candidates) {
        for my $sec (@candidates) {
            $lo = $sec + 1;
            $hi = $#lines;
            for my $j ($sec + 1 .. $#lines) {
                if ($lines[$j] =~ /^##\s/) { $hi = $j - 1; last }
            }
            my $hdr_i;
            for my $i ($lo .. $hi) {
                if ($lines[$i] =~ /^\s*\|/ && $lines[$i] =~ /depends_on/) { $hdr_i = $i; last }
            }
            next unless defined $hdr_i;
            # 3. Terminator: first subsequent non-`|` line WITHIN this section, else
            #    the section's own end (secondary fix: previously unbounded, ran to
            #    EOF regardless of $hi -- harmless in practice since a `## ` heading
            #    is never a `|`-row, but the two bounds should agree).
            my $end_i = $hi + 1;
            for my $i ($hdr_i + 1 .. $hi) {
                if ($lines[$i] !~ /^\s*\|/) { $end_i = $i; last }
            }
            return {
                lines => \@lines,
                hdr_i => $hdr_i,
                end_i => $end_i,
                cols  => [ _table_cols($lines[$hdr_i]) ],
            };
        }
        return undef;   # REFUSE; no legacy re-scan once ANY heading was found
    }

    ($lo, $hi) = (0, $#lines);

    # 2. Header row = first `|`-row containing "depends_on" WITHIN [$lo..$hi].
    my $hdr_i;
    for my $i ($lo .. $hi) {
        if ($lines[$i] =~ /^\s*\|/ && $lines[$i] =~ /depends_on/) { $hdr_i = $i; last }
    }
    return undef unless defined $hdr_i;

    # 3. Terminator unchanged: first subsequent non-`|` line, else EOF.
    my $end_i = scalar(@lines);
    for my $i ($hdr_i + 1 .. $#lines) {
        if ($lines[$i] !~ /^\s*\|/) { $end_i = $i; last }
    }
    return {
        lines => \@lines,
        hdr_i => $hdr_i,
        end_i => $end_i,
        cols  => [ _table_cols($lines[$hdr_i]) ],
    };
}

sub _is_sep_row { return $_[0] =~ /^\s*\|[\s:|-]+\|?\s*$/ }

# step-6 reviewer M1 / red-team MAJOR-5: locate_table (this WRITER, above) is
# heading-anchored; BpOrch::parse_dag (the READER, bp-orchestrator.pl) is
# deliberately left on its old global first-match latch -- it still returns
# the FIRST `|`-row anywhere in the document containing "depends_on", fenced
# or not, heading or not (s03's decision to revisit, not this package's).
# When a document also carries a prose table above "## Package status" whose
# own header cell happens to say "depends_on", the two now disagree about
# which table is real: the writer correctly ignores the prose table, but the
# reader latches onto it and returns an EMPTY dag -- silently, since
# add-package still reports success. Detects that divergence at write time
# so at least the write call is LOUD about it (bp-validate-dag.pl's own
# header-hijack check only runs at drive-solo preflight, not on every typed
# write -- see M1). Returns true iff the reader's own latch point differs
# from the line this write actually targeted.
sub _reader_hijack_risk {
    my ($orig, $hdr_i) = @_;
    my @lines = split /\n/, $orig, -1;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^\s*\|/ && $lines[$i] =~ /depends_on/) {
            return $i != $hdr_i;
        }
    }
    return 0;   # no depends_on row anywhere -- reader and writer cannot diverge
}

# =====================================================================================
# Decisions-section location & shape detection (b42-decision-context-split-spec §4).
# Header recognition WIDENS to also match "## Synthesis Decisions" -- "## Decisions"
# behaviour is unchanged, this only broadens what else counts as the same section.
# Shape is detected by CONTENT, never configuration: a `|`-row immediately followed by
# a `|---`-style separator row means the section is a markdown TABLE (b42's target
# shape); anything else is the legacy BULLET list op_add_decision has always assumed.
# =====================================================================================

my $DECISIONS_HEAD_RE = qr/^##\s+(?:Synthesis\s+)?Decisions\b/i;

# Returns ($start_i, $end_i): $start_i is the header line index, $end_i is the index of
# the next `## ` line (or EOF). Returns (undef, undef) if no such section exists.
sub locate_decisions_bounds {
    my ($lines_ref) = @_;
    my $start;
    for my $i (0 .. $#$lines_ref) {
        if ($lines_ref->[$i] =~ $DECISIONS_HEAD_RE) { $start = $i; last }
    }
    return (undef, undef) unless defined $start;
    my $end = scalar(@$lines_ref);
    for my $i ($start + 1 .. $#$lines_ref) {
        if ($lines_ref->[$i] =~ /^##\s/) { $end = $i; last }
    }
    return ($start, $end);
}

# If the Decisions section (bounded by $start/$end, both from locate_decisions_bounds)
# is table-shaped, returns a hashref describing it: { hdr_i, sep_i, end_i, cols }. Returns
# undef if the section is bullet-shaped (or empty) -- i.e. no `|`-row + separator pair.
sub decisions_table_info {
    my ($lines_ref, $start, $end) = @_;
    for my $i ($start + 1 .. $end - 1) {
        next unless $lines_ref->[$i] =~ /^\s*\|/;
        next unless defined $lines_ref->[$i + 1] && _is_sep_row($lines_ref->[$i + 1]);
        my $hdr_i = $i;
        my $sep_i = $i + 1;
        # The table runs to the END OF THE SECTION, not to the first non-`|` line.
        # Measured on sandbox-butler-overhaul: its 26 decisions are written as THREE
        # `|`-row blocks separated by blank lines. Stopping at the first gap saw only the
        # first 15, so set-decision refused SYN-16..SYN-26 as "not found" -- a migration
        # driven by it would have rewritten 15 rows and then aborted on a half-migrated
        # table. Blank lines between blocks are cosmetic in markdown; they do not start a
        # new table, so a gap must not end this one.
        my $end_i = $end;
        return { hdr_i => $hdr_i, sep_i => $sep_i, end_i => $end_i,
                 cols  => [ _table_cols($lines_ref->[$hdr_i]) ] };
    }
    return undef;
}

# The column that holds the decision's prose: whichever header cell mentions "decision"
# (case-insensitively, matching the target `| # | Decision |` shape), else the last
# column of a >=2-column table. Returns undef if neither applies (e.g. a 1-column table).
sub decisions_text_col {
    my ($cols) = @_;
    for my $i (0 .. $#$cols) { return $i if $cols->[$i] =~ /decision/i; }
    return $#$cols if @$cols >= 2;
    return undef;
}

# Row index (into $lines_ref) of the decisions-table row whose first cell trims to
# exactly $id, or undef. $tbl is a decisions_table_info() result.
sub decisions_find_row {
    my ($lines_ref, $tbl, $id) = @_;
    for my $i ($tbl->{sep_i} + 1 .. $tbl->{end_i} - 1) {
        next unless defined $lines_ref->[$i] && $lines_ref->[$i] =~ /^\s*\|/;
        next if _is_sep_row($lines_ref->[$i]);   # a later block may repeat the separator
        my @c = _table_cols($lines_ref->[$i]);
        next unless defined $c[0];
        (my $rid = $c[0]) =~ s/^\s+//; $rid =~ s/\s+$//;
        return $i if $rid eq $id;
    }
    return undef;
}

# Row index (into $tbl->{lines}) whose first column trims to exactly $pkg, or undef.
sub find_row_index {
    my ($tbl, $pkg) = @_;
    my @lines = @{ $tbl->{lines} };
    for my $i ($tbl->{hdr_i} + 1 .. $tbl->{end_i} - 1) {
        next if _is_sep_row($lines[$i]);
        my @c = _table_cols($lines[$i]);
        next unless defined $c[0];
        (my $id = $c[0]) =~ s/^\s+//; $id =~ s/\s+$//;
        return $i if $id eq $pkg;
    }
    return undef;
}

sub col_index {
    my ($tbl, $name) = @_;
    my @cols = @{ $tbl->{cols} };
    for my $i (0 .. $#cols) { return $i if lc($cols[$i]) eq lc($name) }
    return undef;
}

# step-7 fix-batch HIGH: a column index computed from the HEADER only identifies the
# right cell when the row has exactly as many cells as the header does. On a
# partially-migrated table (Decision-13 coexistence -- a table this API is required to
# tolerate, not just a hypothetical), a row can carry a stale leftover cell the header
# no longer has. In that shape $col_idx still passes replace_cell's `$col_idx > $#cells`
# bounds check, but lands in the WRONG cell -- the write silently succeeds (exit 0) while
# the real value for that column sits untouched and invisible one cell over. Refusing a
# row/header arity mismatch outright is the safe half; silently renumbering or dropping
# the stale cell is a repair decision this op does not get to make on the caller's
# behalf.
sub row_cell_count {
    my ($line) = @_;
    my $inner = $line;
    $inner =~ s/^\s*\|//;
    $inner =~ s/\|\s*$//;
    my @cells = split /\|/, $inner, -1;
    return scalar @cells;
}

# Replace ONE cell of a `|`-delimited row by column index, preserving every other
# cell's original bytes (spacing, non-ASCII) verbatim -- only the target cell changes.
sub replace_cell {
    my ($line, $col_idx, $new_val) = @_;
    my $inner = $line;
    $inner =~ s/^\s*\|//;
    $inner =~ s/\|\s*$//;
    my @cells = split /\|/, $inner, -1;
    return undef if $col_idx > $#cells;
    $cells[$col_idx] = " $new_val ";
    return '|' . join('|', @cells) . '|';
}

# A field value that cannot land in a `|`-delimited cell / bullet line without
# corrupting structure: no CR/LF, no literal pipe.
sub field_safe { my ($s) = @_; return defined($s) && $s !~ /[\r\n|]/ }

# Split a --deps value on the SAME separator parse_dag uses (spec §1.1: /[,\s]+/),
# keep only tokens that look like a package id, dedupe preserving first occurrence.
sub split_dep_tokens {
    my ($raw) = @_;
    my @out; my %seen;
    for my $t (split /[,\s]+/, (defined $raw ? $raw : '')) {
        next unless length $t;
        # package 30 (spec §2.4): keep every token containing '/' too --
        # well-formed or not; validation happens later, per token, in the
        # caller. Other shapes ('—', punctuation) are still silently dropped.
        next unless $t =~ $DEP_TOK_RE || $t =~ m{/};
        next if $seen{$t}++;
        push @out, $t;
    }
    return @out;
}

# _own_bp_and_base($file) -> ($own_bp, $bp_base) (spec §2.4).
sub _own_bp_and_base {
    my ($file) = @_;
    my $own_bp  = basename(dirname($file));
    my $bp_base = dirname(dirname($file));
    return ($own_bp, $bp_base);
}

# _resolve_cross_token($tok, $own_bp, $bp_base) -> ($canon, undef) |
# (undef, $reason) (spec §2.4). Validates a single '<bp>/<pkg>' token in
# order: malformed -> self-blueprint -> unknown blueprint (checked via an
# exact, case-sensitive readdir of $bp_base then $bp_base/_archive, never
# -f, so a case-insensitive filesystem cannot pass a case mismatch) ->
# unresolvable package (via the REAL BpOrch::resolve_dep_token against the
# REFERENT blueprint's own BpOrch::parse_dag keys).
sub _resolve_cross_token {
    my ($tok, $own_bp, $bp_base) = @_;
    my ($bp, $pkg) = ($tok =~ m{^([A-Za-z0-9][A-Za-z0-9_.-]*)/([A-Za-z0-9][A-Za-z0-9_.-]*)$});
    return (undef, 'malformed') unless defined $bp;
    return (undef, 'names this blueprint') if $bp eq $own_bp;

    my $bpdir;
    for my $root ($bp_base, "$bp_base/_archive") {
        next unless opendir(my $dh, $root);
        my @entries = readdir $dh;
        closedir $dh;
        if (grep { $_ eq $bp } @entries) {
            my $cand = "$root/$bp";
            if (-f "$cand/blueprint.md") { $bpdir = $cand; last; }
        }
    }
    unless (defined $bpdir) {
        return (undef, "no blueprint '$bp' under $bp_base (or its _archive/)");
    }

    my $ref_md  = _slurp("$bpdir/blueprint.md");
    my $ref_dag = BpOrch::parse_dag(defined $ref_md ? $ref_md : '');
    my ($how, $name) = BpOrch::resolve_dep_token($pkg, $ref_dag);
    unless ($how eq 'exact' || $how eq 'normalized') {
        return (undef, "package '$pkg' does not resolve in blueprint '$bp'");
    }
    return ("$bp/$name", undef);
}

# resolve_deps_mixed(\@tokens, $names, $own_bp, $bp_base) -> (\@canon, \@bad)
# (spec §2.4). Local tokens resolve exactly as before (resolve_deps);
# cross tokens ('/'-bearing) resolve via _resolve_cross_token. Canonical
# tokens are kept in INPUT ORDER, local and cross interleaved, deduped
# (first occurrence wins). @bad holds { tok, reason } in encounter order;
# reason is 'local' for an unresolved local token (keeps the existing
# aggregate message), else the specific cross-token refusal text.
sub resolve_deps_mixed {
    my ($tokens, $names, $own_bp, $bp_base) = @_;
    my (@canon, @bad, %seen);
    for my $tok (@$tokens) {
        if ($tok =~ m{/}) {
            my ($canon_tok, $reason) = _resolve_cross_token($tok, $own_bp, $bp_base);
            if (defined $canon_tok) {
                next if $seen{$canon_tok}++;
                push @canon, $canon_tok;
            } else {
                push @bad, { tok => $tok, reason => $reason };
            }
        } else {
            my ($how, $name) = BpOrch::resolve_dep_token($tok, $names);
            if ($how eq 'exact' || $how eq 'normalized') {
                next if $seen{$name}++;
                push @canon, $name;
            } else {
                push @bad, { tok => $tok, reason => 'local' };
            }
        }
    }
    return (\@canon, \@bad);
}

# _deps_bad_message(\@bad) -> $msg. Keeps the existing local-only message
# byte-identical (spec §2.4: "unchanged"); a cross-token failure appends
# '<tok>: <reason>' entries, each of which names the offending token.
sub _deps_bad_message {
    my ($bad) = @_;
    my @local_bad = map { $_->{tok} } grep { $_->{reason} eq 'local' } @$bad;
    my @cross_bad = grep { $_->{reason} ne 'local' } @$bad;
    my @parts;
    push @parts, '--deps names package id(s) that do not resolve: ' . join(', ', @local_bad)
        if @local_bad;
    push @parts, join('; ', map { "'$_->{tok}': $_->{reason}" } @cross_bad)
        if @cross_bad;
    return join(' | ', @parts);
}

# Resolve every token in @tokens against the REAL resolver (BpOrch::resolve_dep_token,
# spec §2.3 -- "call it; do not copy it"). $names is a hashref whose KEYS are the
# universe of real package ids (parse_dag's own dag is exactly this shape). Returns
# (\@canon, \@bad) where @bad holds the tokens that resolved to 'ambiguous' or 'none'.
sub resolve_deps {
    my ($tokens, $names) = @_;
    my (@canon, @bad, %seen);
    for my $tok (@$tokens) {
        my ($how, $name) = BpOrch::resolve_dep_token($tok, $names);
        if ($how eq 'exact' || $how eq 'normalized') {
            next if $seen{$name}++;
            push @canon, $name;
        } else {
            push @bad, $tok;
        }
    }
    return (\@canon, \@bad);
}

my $EMDASH = "\xE2\x80\x94";

sub deps_cell_text {
    my (@canon) = @_;
    return @canon ? join(', ', @canon) : $EMDASH;
}

# =====================================================================================
# The shared write algorithm -- mirrors bp-ledger.pl's run_op shape (spec §2.3):
# flock, read, mutate (validation lives INSIDE $mutate_cb, which returns (undef, $why)
# to refuse), atomic temp+rename. Never touches the file at all on refusal.
# =====================================================================================

sub run_write {
    my ($sub, $path, $mutate_cb) = @_;

    my $lockpath = "$path.lock";
    open(my $lk, '>', $lockpath) or io_error($sub, "cannot open lock file $lockpath: $!");
    flock($lk, LOCK_EX) or io_error($sub, "cannot acquire lock on $lockpath: $!");

    my $orig = _slurp($path);
    unless (defined $orig) {
        close $lk;
        io_error($sub, "cannot read $path: $!");
    }

    my ($new, $why) = $mutate_cb->($orig);
    unless (defined $new) {
        close $lk;
        reject_error($sub, $why);
    }

    if ($new eq $orig) {
        flock($lk, LOCK_UN);
        close $lk;
        exit 0;
    }

    my $tmp = "$path.tmp.$$";
    open(my $w, '>:raw', $tmp) or do { close $lk; io_error($sub, "cannot open temp file $tmp: $!") };
    print {$w} $new or do { close $w; unlink $tmp; close $lk; io_error($sub, "write to $tmp failed: $!") };
    close($w) or do { unlink $tmp; close $lk; io_error($sub, "close $tmp failed: $!") };

    unless (rename($tmp, $path)) {
        unlink $tmp;
        close $lk;
        io_error($sub, "rename $tmp -> $path failed: $!");
    }

    flock($lk, LOCK_UN);
    close $lk;
    exit 0;
}

# =====================================================================================
# Write ops.
# =====================================================================================

# -------------------------------------------------------------------------------------
# op_init — CREATE blueprint.md from a template.
#
# WHY THIS EXISTS. `guard-blueprint-write.sh` denies Write/Edit to ANY blueprint.md
# path -- including one that does not exist yet -- while /blueprint:create step 4 said
# "Write blueprint.md from templates/blueprint.md". The documented create flow was
# therefore impossible to execute as written, and every author had to route around the
# guard via Bash: exactly the hand-splice the guard exists to prevent, through a door
# the hook cannot see. Prose said one thing, the mechanism enforced another.
#
# The template path is a PARAMETER, never derived here. bp-blueprint.pl ships in the
# butler plugin; the template ships in the blueprint plugin, and installed plugins live
# in separate cache trees -- so a cross-plugin path would resolve on a dev checkout and
# break on a real install. The caller (which owns the template) passes it in.
# -------------------------------------------------------------------------------------
sub op_init {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt,
            'file=s', 'template=s', 'name=s', 'created=s'); }
    arg_error('init', 'unrecognised option') unless $ok;
    arg_error('init', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file template name)) {
        arg_error('init', "missing required --$r") unless defined $opt{$r};
    }
    unless (field_safe($opt{name})) {
        arg_error('init', '--name contains a pipe or newline');
    }
    unless ($opt{name} =~ /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/) {
        arg_error('init', "--name '$opt{name}' is not kebab-case (a-z, 0-9, single hyphens)");
    }

    my $path = $opt{file};

    # REFUSE rather than overwrite. An existing blueprint is somebody's initiative;
    # re-running init must never be the thing that destroys it.
    if (-e $path) {
        reject_error('init', "$path already exists -- refusing to overwrite an existing blueprint. "
                           . 'Use the typed verbs (add-package, add-decision, set-section) to modify it.');
    }

    my $tpl = _slurp($opt{template});
    defined $tpl or io_error('init', "cannot read template $opt{template}: $!");

    # A template that does not carry the metadata block is not a blueprint template;
    # substituting into it would silently produce a file parse_dag cannot read.
    unless ($tpl =~ /^blueprint:\s*\S/m) {
        reject_error('init', "template $opt{template} has no `blueprint:` metadata line -- "
                           . 'refusing to guess its shape');
    }

    my $created = $opt{created};
    unless (defined $created && length $created) {
        my @t = gmtime(time);
        $created = sprintf('%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3]);
    }
    unless (field_safe($created)) {
        arg_error('init', '--created contains a pipe or newline');
    }

    # STRIP TEMPLATE PLACEHOLDER ROWS. The template ships illustrative table rows --
    # `| 01-<slug> | <one line> | — | sonnet | pending |` and `| 1 | <e.g. ...> |`.
    # Left in place, BpOrch::parse_dag reads `01-<slug>` as a REAL package with no
    # ledger, so a brand-new blueprint fails its own DAG validation and every author
    # has to remember to delete rows by hand. A data row carrying an angle-bracket
    # placeholder is by definition not real content; header and separator rows are
    # never touched.
    {
        my @keep;
        for my $ln (split /\n/, $tpl, -1) {
            if ($ln =~ /^\s*\|/ && !_is_sep_row($ln) && $ln =~ /<[^>]*>/) {
                next;   # illustrative row from the template
            }
            push @keep, $ln;
        }
        $tpl = join("\n", @keep);
    }

    $tpl =~ s/^blueprint:\s*.*$/blueprint: $opt{name}/m;
    $tpl =~ s/^created:\s*.*$/created: $created/m;
    $tpl =~ s/^last_updated:\s*.*$/last_updated: $created/m;
    $tpl =~ s/^status:\s*\S+/status: drafting/m;

    my $dir = dirname($path);
    if (length $dir && !-d $dir) {
        require File::Path;
        File::Path::make_path($dir)
            or io_error('init', "cannot create directory $dir: $!");
    }

    # Same atomic discipline as run_write: temp + rename under flock. Not run_write
    # itself, which slurps the target first and so cannot create one.
    my $lockpath = "$path.lock";
    open(my $lk, '>', $lockpath) or io_error('init', "cannot open lock file $lockpath: $!");
    flock($lk, LOCK_EX) or io_error('init', "cannot acquire lock on $lockpath: $!");

    # Re-check under the lock: two authors racing must not both "create" it.
    if (-e $path) {
        close $lk;
        reject_error('init', "$path already exists (created concurrently) -- refusing to overwrite");
    }

    my $tmp = "$path.tmp.$$";
    open(my $w, '>:raw', $tmp) or do { close $lk; io_error('init', "cannot open temp file $tmp: $!") };
    print {$w} $tpl or do { close $w; unlink $tmp; close $lk; io_error('init', "write to $tmp failed: $!") };
    close($w) or do { unlink $tmp; close $lk; io_error('init', "close $tmp failed: $!") };
    unless (rename($tmp, $path)) {
        unlink $tmp;
        close $lk;
        io_error('init', "rename $tmp -> $path failed: $!");
    }
    flock($lk, LOCK_UN);
    close $lk;
    exit 0;
}

# -------------------------------------------------------------------------------------
# op_set_section — replace the BODY of a `## ` prose section.
#
# The other write verbs are all typed edits to the package-status table and the
# decisions table. The NARRATIVE sections (Objective, Constraints & known hazards, Key
# references, the per-package blocks) had no verb at all -- so an author filling in a
# freshly-initialised template still had to hand-splice, and the guard still refused.
# This closes that loop: every mutation of blueprint.md now has a typed, atomic path.
#
# Structural sections are REFUSED here on purpose. "Package status" and "Decisions" are
# tables the orchestrator's parse_dag reads; they have their own validated verbs, and
# letting free text overwrite them would reintroduce exactly the corruption this API
# exists to make impossible.
# -------------------------------------------------------------------------------------
my %SECTION_REFUSED = map { lc($_) => 1 } (
    'Package status',   # add-package / set-field / set-deps own this
    'Decisions',        # add-decision / set-decision own this
    'Harvest log',      # orchestrator-only; add-harvest owns it
);

sub op_set_section {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'section=s', 'text-file=s'); }
    arg_error('set-section', 'unrecognised option') unless $ok;
    arg_error('set-section', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file section text-file)) {
        arg_error('set-section', "missing required --$r") unless defined $opt{$r};
    }

    my $want = $opt{section};
    if ($SECTION_REFUSED{ lc $want }) {
        arg_error('set-section',
            "section '$want' is structured state with its own typed verbs -- refusing. "
          . 'Use add-package/set-field/set-deps, add-decision/set-decision, '
          . 'or add-harvest.');
    }

    my $body = _slurp($opt{'text-file'});
    defined $body or io_error('set-section', "cannot read --text-file $opt{'text-file'}: $!");

    # New text may not introduce a `## ` heading: that would silently restructure the
    # document and could manufacture a second "Package status" the parser then latches
    # onto (the SYN-14 failure shape, one level up).
    if ($body =~ /^##\s/m) {
        arg_error('set-section',
            '--text-file contains a `## ` heading; that would restructure the document. '
          . 'Set one section at a time.');
    }

    run_write('set-section', $opt{file}, sub {
        my ($orig) = @_;

        # Match this `## <section>` up to the next `## ` at line start, or EOF.
        my $q = quotemeta $want;
        unless ($orig =~ /^##[ \t]+$q[ \t]*$/m) {
            return (undef, "no `## $want` section found in $opt{file} -- refusing to invent one. "
                         . 'Sections come from the template; check the exact heading text.');
        }

        $body =~ s/\s*\z//;                    # normalise trailing whitespace
        my $new = $orig;
        # `[ \t]*` not `\s*` after the heading: `\s*` also matches the newline, so the
        # capture swallowed the blank line that follows and every set-section added
        # another one. Caught by diffing the bytes, not by reading the regex.
        $new =~ s{(^##[ \t]+$q[ \t]*\n)(.*?)(?=^##[ \t]|\z)}{$1\n$body\n\n}ms;
        return ($new, undef);
    });
}

# -------------------------------------------------------------------------------------
# op_set_meta — set a field in the blueprint's own metadata block.
#
# The lifecycle field `status:` (drafting -> audited -> running -> done -> archived) is
# documented in the template and had NO verb: set-field only edits package-status TABLE
# rows and rejects these values outright. So advancing a blueprint's own lifecycle -- the
# last step of /blueprint:create -- required a hand-splice, which is precisely what this
# API exists to prevent. Found by hitting it while authoring a real blueprint.
#
# 08-blueprint-parks (spec §2.2) extends this: `parked` is a fourth AUTHORED word,
# carrying a `parked_reason:` fenced-metadata line that exists iff status is parked, and
# a status write that LEAVES parked closes that park's open inbox item (package 01's
# almanac-inbox.pl) under this file's own lock, before the rename lands.
# -------------------------------------------------------------------------------------
my @BP_LIFECYCLE_AUTHORED = qw(drafting audited parked archived);
my @BP_LIFECYCLE_DERIVED  = qw(running done);
my %BP_LIFECYCLE_DERIVED  = map { $_ => 1 } @BP_LIFECYCLE_DERIVED;
my %BP_LIFECYCLE_AUTHORED = map { $_ => 1 } @BP_LIFECYCLE_AUTHORED;
my %META_FIELDS  = map { $_ => 1 } qw(blueprint created last_updated status execution_mode);

# REASON_OK($r) -> 1|0 (spec §2.1). After trimming, non-empty, at most 200
# bytes, and contains none of CR, LF, '|' or '#'. Raw bytes, never decoded.
sub _reason_ok {
    my ($r) = @_;
    return 0 unless defined $r;
    (my $t = $r) =~ s/\A\s+|\s+\z//g;
    return 0 unless length $t;
    return 0 if length($t) > 200;
    return 0 if $t =~ /[\r\n|#]/;
    return 1;
}

sub _trim_reason { my ($r) = @_; (my $t = $r) =~ s/\A\s+|\s+\z//g; return $t; }

# The fence marker is built via chr() -- a literal triple-backtick is itself
# a banned token in some sibling modules' source; kept the same way here for
# consistency with BpState.pm's bp_meta_get.
my $FENCE = chr(96) x 3;

# _authored_field_of($text, $field) -> $value|undef: the first "$field:" line
# inside the FIRST fenced metadata block, trimmed, comment stripped. Used to
# read the PRE-WRITE authored status/parked_reason before any mutation.
sub _authored_field_of {
    my ($text, $field) = @_;
    my $fence_q = quotemeta $FENCE;
    return undef unless defined $text && $text =~ /^$fence_q\s*\n((?:.*\n)*?)^$fence_q\s*$/m;
    my $block = $1;
    my $fq = quotemeta $field;
    return undef unless $block =~ /^$fq:[ \t]*([^\n#]*)/m;
    my $v = $1;
    $v =~ s/\s+\z//;
    return $v;
}

# _set_parked_reason($text, $reason) -> $new_text. $reason defined => insert/
# update a `parked_reason:` line right after the first fenced block's
# `status:` line (and after any `^[ \t]+#` continuation lines that directly
# follow it, so the template's two-line comment is never split, spec §2.1).
# $reason undef => remove any existing `parked_reason:` line in that fence.
# A no-op (no fence, or no `status:` line in it) returns $text unchanged --
# the caller has already validated a `status:` line exists.
sub _set_parked_reason {
    my ($text, $reason) = @_;
    my @lines = split /\n/, $text, -1;
    my ($start, $end);
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^\Q$FENCE\E\s*$/) {
            if (!defined $start) { $start = $i; }
            else { $end = $i; last; }
        }
    }
    return $text unless defined $start && defined $end;

    my ($status_i, $pr_i);
    for my $i ($start + 1 .. $end - 1) {
        $status_i = $i if !defined($status_i) && $lines[$i] =~ /^status:/;
        $pr_i     = $i if !defined($pr_i)     && $lines[$i] =~ /^parked_reason:/;
    }
    return $text unless defined $status_i;

    if (defined $reason) {
        if (defined $pr_i) {
            $lines[$pr_i] = "parked_reason: $reason";
        } else {
            my $insert_at = $status_i + 1;
            while ($insert_at <= $end - 1 && $lines[$insert_at] =~ /^[ \t]+#/) { $insert_at++; }
            splice(@lines, $insert_at, 0, "parked_reason: $reason");
        }
    } elsif (defined $pr_i) {
        splice(@lines, $pr_i, 1);
    }
    return join("\n", @lines);
}

sub _iso_now_utc {
    my @t = gmtime(time);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
                   $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# _close_park_items($file, $new_value, $pre_reason): the unpark hook (spec
# §2.2). $file is the blueprint.md path being written; $new_value is the
# status it is being set to (never 'parked' -- the caller only calls this
# when leaving parked). Closes every open park item for this blueprint via a
# CAS update to 'answered'. Returns 1 on success (including "nothing to do"
# skip cases). On any real failure it prints to STDERR and calls `exit 4`
# directly -- this runs from inside run_write's mutate callback, BEFORE the
# rename, so exiting here leaves blueprint.md byte-identical (spec §2.2 step
# 5 / E2).
#
# Spec E2's OTHER half lives downstream of here, not in this function: this
# call can return 1 (every item closed successfully) and run_write's own
# rename can STILL fail afterwards (an I/O error, `io_error` -> exit 4). That
# leaves the item answered while blueprint.md is still authored `parked` --
# accepted and documented per E2 ("the item is closed but the blueprint is
# still parked... re-running the unpark succeeds, with nothing left to
# close"). Nothing to fix here; this is the accepted asymmetry, not a bug.
sub _close_park_items {
    my ($file, $new_value, $pre_reason) = @_;

    my $abs_dir = abs_path(dirname($file));
    return 1 unless defined $abs_dir;
    (my $norm = $abs_dir) =~ s{\\}{/}g;
    return 1 unless $norm =~ m{^(.+)/\.ccpraxis-local-data/blueprints/([^/]+)$};
    my ($root, $bp) = ($1, $2);
    return 1 unless -d "$root/.ccpraxis-local-data";
    return 1 unless -d "$root/.ccpraxis-local-data/almanac/inbox";

    my $inbox_pl = "$DIR/../../almanac/scripts/almanac-inbox.pl";
    my $load_ok = eval { require $inbox_pl; 1 };
    unless ($load_ok) {
        (my $msg = $@) =~ s/\s+\z//;
        emit_err("bp-blueprint: set-meta: cannot load inbox library $inbox_pl: $msg");
        exit 4;
    }

    my $items = eval { Almanac::Inbox::list_items(root => $root) };
    if ($@) {
        my $msg = ref($@) ? ($@->{detail} // $@->{kind} // 'error') : $@;
        $msg =~ s/\s+\z// unless ref $msg;
        emit_err("bp-blueprint: set-meta: cannot list inbox items at $root: $msg");
        exit 4;
    }

    my $reason_text = (defined $pre_reason && length $pre_reason) ? $pre_reason : '(none recorded)';
    my $closed_reason = "blueprint $bp left parked (status now $new_value); park reason: $reason_text";

    my @park_items = grep {
        ref $_ eq 'HASH'
        && defined $_->{fields}{link}   && $_->{fields}{link}   eq $bp
        && defined $_->{fields}{status} && $_->{fields}{status} eq 'unanswered'
        && defined $_->{fields}{title}  && $_->{fields}{title}  =~ /^Blueprint \Q$bp\E parked:/
    } @$items;

    for my $item (@park_items) {
        my $ok = eval {
            Almanac::Inbox::open_inbox(root => $root)->update($item->{id},
                expect => { rev => $item->{rev}, fields => $item->{fields} },
                set    => { status => 'answered', closed_at => _iso_now_utc(),
                            closed_reason => $closed_reason, closed_by => 'bp-blueprint.pl set-meta' });
            1;
        };
        unless ($ok) {
            my $err = $@;
            my $kind = (ref($err) && eval { $err->isa('Almanac::Store::Error') }) ? $err->{kind} : undef;
            if (defined $kind && $kind eq 'conflict') {
                my $re = eval { Almanac::Inbox::read_item($item->{id}, root => $root) };
                if (!$@ && ref($re) eq 'HASH'
                    && (!defined($re->{fields}{status}) || $re->{fields}{status} ne 'unanswered')) {
                    next;   # already handled (by this attempt or a concurrent one)
                }
            }
            my $msg = ref($err) ? ($err->{detail} // $err->{kind} // 'error') : $err;
            $msg =~ s/\s+\z// unless ref $msg;
            emit_err("bp-blueprint: set-meta: could not close park item $item->{id} for $bp: $msg");
            exit 4;
        }
    }
    return 1;
}

sub op_set_meta {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'field=s', 'value=s', 'reason=s'); }
    arg_error('set-meta', 'unrecognised option') unless $ok;
    arg_error('set-meta', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file field value)) {
        arg_error('set-meta', "missing required --$r") unless defined $opt{$r};
    }
    unless ($META_FIELDS{ $opt{field} }) {
        arg_error('set-meta', "--field '$opt{field}' is not a metadata field; expected one of: "
                            . join(', ', sort keys %META_FIELDS));
    }
    unless (field_safe($opt{value})) {
        arg_error('set-meta', '--value contains a pipe or newline');
    }
    if ($opt{field} eq 'status') {
        # F5 (s04 fix-batch step 7, red-team LOW): a case/whitespace variant
        # of a derived word (e.g. 'Done', ' RUNNING') fails the EXACT match
        # below and used to fall through to the generic "unrecognised value"
        # arg_error path -- the write was refused either way (verified, no
        # bypass), but the user got the wrong explanation (looked like a typo
        # rather than "this is derived, never authored"). Normalise ONLY for
        # this derived-word check, so the better message fires for variants
        # too; the exact-match AUTHORED check just below is left untouched --
        # widening it would let a case variant of an authored word (e.g.
        # 'Audited') through validation and then get WRITTEN verbatim,
        # which is a real behavior change, not a message fix, and out of
        # scope here.
        my $norm_value = lc($opt{value} // '');
        $norm_value =~ s/\A\s+|\s+\z//g;
        if ($BP_LIFECYCLE_DERIVED{$opt{value}} || $BP_LIFECYCLE_DERIVED{$norm_value}) {
            reject_error('set-meta',
                "--value '$opt{value}' is a DERIVED blueprint state, not something set-meta writes -- "
              . "'running' is derived from a live runs/.orchestrator marker (BpState::run_is_live) and "
              . "'done' from every package ledger reaching done/dropped (BpState::blueprint_lifecycle); "
              . "authored values are: " . join(', ', @BP_LIFECYCLE_AUTHORED));
        }
        unless ($BP_LIFECYCLE_AUTHORED{$opt{value}}) {
            arg_error('set-meta', "--value '$opt{value}' is not a blueprint lifecycle status; expected one of: "
                                . join(', ', @BP_LIFECYCLE_AUTHORED));
        }
    }

    # 08-blueprint-parks (spec §2.2): --reason is accepted ONLY with
    # --field status --value parked, where it is required and must pass
    # REASON_OK. `parked_reason` is never a --field of its own (not added to
    # %META_FIELDS above), so `--field parked_reason` keeps refusing there.
    if (defined $opt{reason}) {
        unless ($opt{field} eq 'status' && $opt{value} eq 'parked') {
            arg_error('set-meta', "--reason is accepted only with --field status --value parked");
        }
        unless (_reason_ok($opt{reason})) {
            arg_error('set-meta', "--reason is invalid: must be non-empty, at most 200 bytes, "
                                 . "and contain none of CR, LF, '|' or '#'");
        }
        $opt{reason} = _trim_reason($opt{reason});
    } elsif ($opt{field} eq 'status' && $opt{value} eq 'parked') {
        arg_error('set-meta', "--value parked requires --reason <text>");
    }

    run_write('set-meta', $opt{file}, sub {
        my ($orig) = @_;
        my $f = quotemeta $opt{field};

        # The metadata block is the fenced ``` block near the top. Only ever touch a
        # `field:` line inside it -- a `status:` elsewhere (a package ledger quoted in
        # prose, or a prose line that happens to start with "status:" ABOVE the fence,
        # say) must not be rewritten. 08-blueprint-parks MF-1/M3: the previous version
        # of this rewrite used a plain `/m` substitution with no fence anchoring, so a
        # `status:`-looking line appearing textually before the fence (prose) was
        # rewritten instead of the real fenced line, and the function still reported
        # success. Confine the rewrite to the FIRST fenced block's line range, using
        # the same fence-boundary scan `_set_parked_reason` already does.
        my @lines = split /\n/, $orig, -1;
        my ($fstart, $fend);
        for my $i (0 .. $#lines) {
            if ($lines[$i] =~ /^\Q$FENCE\E\s*$/) {
                if (!defined $fstart) { $fstart = $i; }
                else { $fend = $i; last; }
            }
        }
        my $done = 0;
        if (defined $fstart && defined $fend) {
            for my $i ($fstart + 1 .. $fend - 1) {
                next if $done;
                if ($lines[$i] =~ /^($f:)([ \t]*)([^\n#]*)(#[^\n]*)?$/) {
                    my ($g1, $g2, $g3, $g4) = ($1, $2, $3, $4);
                    $lines[$i] = $g1 . ($g2 || ' ') . $opt{value} . (defined $g4 ? "        $g4" : '');
                    $done = 1;
                }
            }
        }
        return (undef, "no `$opt{field}:` line found in the metadata block of $opt{file}")
            unless defined $fstart && defined $fend;
        return (undef, "could not rewrite `$opt{field}:`") unless $done;
        my $new = join("\n", @lines);

        if ($opt{field} eq 'status') {
            # 08-blueprint-parks L7/NIT-3/NIT-5: this used to be an ad hoc
            # lc+trim comparison, which disagreed with BpState::norm_bp_status
            # (the project's one true normaliser -- also used by the director
            # and by RunState) on a hand-edited value like `status: parked.`
            # or `status: "parked"`. Route through the same normaliser so all
            # three readers reach the same verdict.
            require "$DIR/BpState.pm" unless defined &BpState::norm_bp_status;
            my $pre_status = BpState::norm_bp_status(_authored_field_of($orig, 'status'));

            # Redteam L4(a): a duplicate/concurrent `park` call must not
            # clobber the reason already recorded -- the first reason wins
            # (EC-2), including on this idempotent re-park path.
            my $reason_to_write = $opt{reason};
            if ($opt{value} eq 'parked' && $pre_status eq 'parked') {
                my $existing_reason = _authored_field_of($orig, 'parked_reason');
                $reason_to_write = $existing_reason if defined $existing_reason && length $existing_reason;
            }

            $new = _set_parked_reason($new, $opt{value} eq 'parked' ? $reason_to_write : undef);

            # Unpark hook (spec §2.2): fires only when the PRE-write authored
            # status was 'parked' and the new value is not -- so a second,
            # unrelated status write (already non-parked) never loads the
            # inbox at all (B9's no-op guarantee).
            if ($pre_status eq 'parked' && $opt{value} ne 'parked') {
                my $pre_reason = _authored_field_of($orig, 'parked_reason');
                _close_park_items($opt{file}, $opt{value}, $pre_reason);   # exits 4 on failure
            }
        }

        return ($new, undef);
    });
}

sub op_add_package {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt,
          'file=s', 'pkg=s', 'deliverable=s', 'deps=s', 'model=s', 'status=s'); }
    arg_error('add-package', 'unrecognised option') unless $ok;
    arg_error('add-package', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file pkg deliverable)) {
        arg_error('add-package', "missing required --$r") unless defined $opt{$r};
    }
    if (defined $opt{status}) {
        arg_error('add-package', "--status is not accepted here -- " . $STATUS_RETIRED_MSG);
    }

    my $pkg = $opt{pkg};
    unless (field_safe($pkg) && $pkg =~ $PKG_ID_RE) {
        arg_error('add-package',
            "--pkg '$pkg' cannot form a contiguous table row (must match $PKG_ID_RE, no pipe/newline)");
    }
    unless (field_safe($opt{deliverable})) {
        arg_error('add-package', '--deliverable contains a pipe or newline; would break the table row');
    }

    if (defined $opt{model} && !field_safe($opt{model})) {
        arg_error('add-package', '--model contains a pipe or newline; would break the table row');
    }

    run_write('add-package', $opt{file}, sub {
        my ($orig) = @_;
        my $tbl = locate_table($orig);
        return (undef, "no package-status table found (no 'depends_on' column header)") unless $tbl;

        if (_reader_hijack_risk($orig, $tbl->{hdr_i})) {
            print STDERR "bp-blueprint: add-package: WARNING: header-hijack risk -- a depends_on-bearing "
                        . "prose table elsewhere in this document will make the orchestrator's DAG reader "
                        . "(parse_dag) latch onto a DIFFERENT table than this write targeted; it may see an "
                        . "empty or wrong dag for this package. Run bp-validate-dag.pl before relying on it.\n";
        }

        return (undef, "package '$pkg' already exists in the table") if defined find_row_index($tbl, $pkg);

        my $dag = BpOrch::parse_dag($orig);
        my @tokens = defined $opt{deps} ? split_dep_tokens($opt{deps}) : ();
        my ($own_bp, $bp_base) = _own_bp_and_base($opt{file});
        my ($canon, $bad) = resolve_deps_mixed(\@tokens, $dag, $own_bp, $bp_base);
        return (undef, _deps_bad_message($bad)) if @$bad;

        my %fields = (
            pkg         => $pkg,
            deliverable => $opt{deliverable},
            depends_on  => deps_cell_text(@$canon),
            model       => defined $opt{model} ? $opt{model} : '',
        );
        my @row_cells = map { $fields{lc $_} // '' } @{ $tbl->{cols} };
        my $row = '| ' . join(' | ', @row_cells) . ' |';

        my @lines = @{ $tbl->{lines} };
        splice(@lines, $tbl->{end_i}, 0, $row);

        # a02 defect 5 §2.6: no refusal (blueprint authoring adds every row before any
        # ledger exists) -- just a loud stderr notice naming what the orchestrator will
        # do about it. Fires only here, at the tail of an otherwise-valid add.
        my $ledger_path = dirname($opt{file}) . "/packages/$pkg.md";
        unless (-f $ledger_path) {
            print STDERR "bp-blueprint: add-package: notice: no ledger at $ledger_path -- the orchestrator "
                        . "will HOLD this package (logged as awaiting_ledger) and not launch it until one exists.\n";
        }

        return (join("\n", @lines), undef);
    });
}

# Retired unconditionally (Decision 11) -- args are NEVER inspected, the file is
# NEVER touched. A silent no-op here is how a caller keeps believing it wrote
# something; this fails loudly instead, every time, regardless of table shape.
sub op_set_status {
    my @args = @_;
    arg_error('set-status', $STATUS_RETIRED_MSG);
}

sub op_set_deps {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'pkg=s', 'deps=s'); }
    arg_error('set-deps', 'unrecognised option') unless $ok;
    arg_error('set-deps', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file pkg)) {
        arg_error('set-deps', "missing required --$r") unless defined $opt{$r};
    }
    my $pkg = $opt{pkg};

    run_write('set-deps', $opt{file}, sub {
        my ($orig) = @_;
        my $tbl = locate_table($orig);
        return (undef, "no package-status table found (no 'depends_on' column header)") unless $tbl;
        my $ci = col_index($tbl, 'depends_on');
        return (undef, "table has no 'depends_on' column") unless defined $ci;
        my $ri = find_row_index($tbl, $pkg);
        return (undef, "no such package '$pkg' in the table") unless defined $ri;

        my $dag = BpOrch::parse_dag($orig);
        delete $dag->{$pkg};   # a package cannot depend on itself
        my @tokens = split_dep_tokens($opt{deps});
        my ($own_bp, $bp_base) = _own_bp_and_base($opt{file});
        my ($canon, $bad) = resolve_deps_mixed(\@tokens, $dag, $own_bp, $bp_base);
        return (undef, _deps_bad_message($bad)) if @$bad;

        my @lines = @{ $tbl->{lines} };
        my $ncols = scalar @{ $tbl->{cols} };
        my $nrow  = row_cell_count($lines[$ri]);
        return (undef, "row for '$pkg' has $nrow cell(s) but the header has $ncols column(s); "
              . 'refusing to write into a row of mismatched arity rather than guess which cell is depends_on')
            if $nrow != $ncols;
        my $new_line = replace_cell($lines[$ri], $ci, deps_cell_text(@$canon));
        return (undef, "internal error replacing the depends_on cell for '$pkg'") unless defined $new_line;
        $lines[$ri] = $new_line;
        return (join("\n", @lines), undef);
    });
}

# -------------------------------------------------------------------------------------
# op_set_test_paths — full-replacement write of a PACKAGE LEDGER's `test_paths:`
# frontmatter field (a02 defect 2 / spec §2.2). `--widen-write-set`
# (bp-answer-escalation.pl, outside this write set) is the precedent for `write_set`;
# there was no counterpart for `test_paths` before this. Operates on a package
# ledger, NOT blueprint.md -- shape-validated so it cannot be mis-aimed at the wrong
# file. Full replacement only; there is deliberately no additive/widen mode (spec
# out-of-scope).
# -------------------------------------------------------------------------------------
sub op_set_test_paths {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'paths=s'); }
    arg_error('set-test-paths', 'unrecognised option') unless $ok;
    arg_error('set-test-paths', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file paths)) {
        arg_error('set-test-paths', "missing required --$r") unless defined $opt{$r};
    }

    my $paths = $opt{paths};
    if ($paths !~ /\S/) {
        arg_error('set-test-paths',
            'refusing to clear test_paths: an empty scope would remove the oracle boundary the guard enforces');
    }
    unless (field_safe($paths)) {
        arg_error('set-test-paths', '--paths contains a pipe or newline');
    }
    for my $entry (split /:/, $paths, -1) {
        if ($entry eq '') {
            arg_error('set-test-paths', "--paths has an empty entry; repo-relative paths only (colon-separated)");
        }
        if ($entry =~ m{^/}) {
            arg_error('set-test-paths',
                "--paths entry '$entry' is absolute; repo-relative paths only");
        }
        if ($entry =~ m{(^|/)\.\.(/|$)}) {
            arg_error('set-test-paths',
                "--paths entry '$entry' contains '..'; repo-relative paths only");
        }
        # step-6 red-team MAJOR-3: a pattern this broad LOSES every specificity
        # comparison in guard-writes.sh (its own character length is 1-4,
        # shorter than virtually any write_set entry), which silently flips
        # the whole-package implementer guard from "everything looks like a
        # test" (loud, HEAD's own over-broad-test_paths failure mode) to
        # "nothing does" (silent) under the new ranking. Refuse pure-wildcard
        # or project-root-equivalent entries explicitly rather than accepting
        # a value that is syntactically valid but functionally disables the
        # oracle boundary this verb exists to protect.
        if ($entry =~ m{\A(?:\*+|\*\*/\*|\.|\./|/)\z}) {
            arg_error('set-test-paths',
                "--paths entry '$entry' is a pure wildcard or project-root-equivalent scope; it would functionally disable the test-oracle guard for this package");
        }
    }

    run_write('set-test-paths', $opt{file}, sub {
        my ($orig) = @_;
        unless ($orig =~ /\A---\s*\n(.*?)\n---/s) {
            return (undef, "$opt{file} is not a package ledger (no frontmatter block at byte 0)");
        }
        my $fm = $1;
        unless ($fm =~ /^package:\s*\S/m) {
            return (undef, "--file must be a package ledger, not blueprint.md (no `package:` line in frontmatter)");
        }
        unless ($fm =~ /^test_paths:\s*/m) {
            return (undef, "no `test_paths:` key in the frontmatter -- refusing to invent one");
        }
        my $new = $orig;
        my $replaced = ($new =~ s/^test_paths:.*$/test_paths: $paths/m);
        return (undef, "internal error: could not locate test_paths: line to replace") unless $replaced;
        return ($new, undef);
    });
}

sub op_add_decision {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'id=s', 'text=s', 'decided=s', 'date=s'); }
    arg_error('add-decision', 'unrecognised option') unless $ok;
    arg_error('add-decision', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file id text)) {
        arg_error('add-decision', "missing required --$r") unless defined $opt{$r};
    }
    unless (field_safe($opt{id})) {
        arg_error('add-decision', '--id contains a pipe or newline');
    }
    # SYN-14 hazard (spec §1.1 / §3 G3): parse_dag latches onto the FIRST `|`-row
    # containing the literal "depends_on" as the header. A decision whose text
    # carries that token risks becoming (or masquerading as) a second such row/
    # table, mis-routing the whole run. Refused mechanically, naming SYN-14.
    if (index($opt{text}, 'depends_on') >= 0) {
        arg_error('add-decision',
            "--text contains the literal token 'depends_on' (SYN-14 hazard: parse_dag latches onto the "
          . 'FIRST |-row containing that token as its table header -- a second one mis-routes the whole '
          . 'run). Rephrase without the literal token.');
    }

    for my $f (qw(text decided date)) {
        next unless defined $opt{$f};
        arg_error('add-decision',
            "--$f contains a pipe or newline; a decisions row is ONE line and `|` delimits its cells "
          . '(the same constraint field_safe already enforces for --id). Pass a single line.')
            unless field_safe($opt{$f});
    }

    my $text = $opt{text};
    my $entry = "- $opt{id}: $text";

    run_write('add-decision', $opt{file}, sub {
        my ($orig) = @_;
        my @lines = split /\n/, $orig, -1;
        my ($start, $end) = locate_decisions_bounds(\@lines);
        return (undef, "no '## Decisions' section found") unless defined $start;
        # A table-shaped section (b42's target shape) must never receive an appended
        # bullet -- that would corrupt the table silently. Refuse instead; editing an
        # existing row is set-decision's job, and creating new rows is out of scope here.
        # TABLE-SHAPED: append a ROW, don't refuse.
        #
        # This used to refuse outright, which left a hole nobody could get through:
        # `add-decision` would not append to a table and `set-decision` requires a row
        # that already exists -- so a table-shaped Decisions section could never receive
        # a NEW decision. b42 converted the shape and did not update the appender, and
        # the refusal message pointed at a verb that cannot create rows. A freshly
        # initialised blueprint (whose template ships the table shape) was therefore
        # un-authorable through the API, which is what forced hand-splicing.
        if (my $tbl = decisions_table_info(\@lines, $start, $end)) {
            my $ci = decisions_text_col($tbl->{cols});
            return (undef, 'decisions table has no identifiable text column') unless defined $ci;

            return (undef, "a decision with id '$opt{id}' already exists; use set-decision to edit it")
                if defined decisions_find_row(\@lines, $tbl, $opt{id});

            # Fill by COLUMN HEADER, not by position: the table's shape is the
            # blueprint author's, and assuming a fixed 4-column layout is how a
            # generic API silently corrupts a project-specific one.
            my @cells;
            for my $i (0 .. $#{ $tbl->{cols} }) {
                if    ($i == 0)   { push @cells, $opt{id} }
                elsif ($i == $ci) { push @cells, $opt{text} }
                elsif ($tbl->{cols}[$i] =~ /decided|by|who/i)  { push @cells, $opt{decided} // 'user' }
                elsif ($tbl->{cols}[$i] =~ /date|when/i)       { push @cells, $opt{date} // _today() }
                else                                           { push @cells, '' }
            }
            my $row = '| ' . join(' | ', @cells) . ' |';

            # Insert immediately after the last CONTIGUOUS row, not at the section's
            # end_i. On a freshly initialised blueprint the table is header+separator
            # followed by a blank line, and appending at end_i put the row AFTER that
            # blank -- which terminates the table, so the row was orphaned and invisible
            # to the parser. Found by reading the emitted bytes, not the code.
            my $ins = $tbl->{sep_i} + 1;
            $ins++ while defined $lines[$ins]
                      && $lines[$ins] =~ /^\s*\|/
                      && !_is_sep_row($lines[$ins]);
            splice(@lines, $ins, 0, $row);
            return (join("\n", @lines), undef);
        }
        my $insert_at = $end;
        $insert_at-- if $insert_at > 0 && $lines[$insert_at - 1] eq '';
        splice(@lines, $insert_at, 0, $entry);
        return (join("\n", @lines), undef);
    });
}

my $HARVEST_HEAD_RE = qr/^##\s+Harvest\s+log\b/i;

# Same contract as locate_decisions_bounds, for the Harvest log section.
sub locate_harvest_bounds {
    my ($lines_ref) = @_;
    my $start;
    for my $i (0 .. $#$lines_ref) {
        if ($lines_ref->[$i] =~ $HARVEST_HEAD_RE) { $start = $i; last }
    }
    return (undef, undef) unless defined $start;
    my $end = scalar(@$lines_ref);
    for my $i ($start + 1 .. $#$lines_ref) {
        if ($lines_ref->[$i] =~ /^##\s/) { $end = $i; last }
    }
    return ($start, $end);
}

# Append one row to the Harvest log table.
#
# WHY THIS VERB EXISTS. The Harvest log was unwritable by ANY path: set-section refuses
# it as "orchestrator-only, written during execution", the guard hook refuses a direct
# Edit, and no orchestrator verb was ever written -- so "written during execution" named
# a writer that does not exist. Every blueprint's harvest log was therefore empty, which
# quietly voids any done-criterion phrased as "recorded in the harvest log" (this was
# caught by 11-operator-visual-signoff, whose criterion 2 is exactly that). This is the
# same hole shape the add-decision comment above documents: a section owned by typed
# verbs, with no typed verb that can reach it. Found 2026-08-12.
sub op_add_harvest {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt,
                                'file=s', 'pkg=s', 'outputs=s', 'by=s', 'date=s'); }
    arg_error('add-harvest', 'unrecognised option') unless $ok;
    arg_error('add-harvest', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file pkg outputs)) {
        arg_error('add-harvest', "missing required --$r") unless defined $opt{$r};
    }
    for my $f (qw(pkg outputs by date)) {
        next unless defined $opt{$f};
        arg_error('add-harvest', "--$f contains a pipe or newline; would break the table row")
            unless field_safe($opt{$f});
    }
    # SYN-14, same hazard as add-decision: parse_dag latches onto the FIRST `|`-row
    # containing the literal token as the package-status header. A harvest row carrying
    # it could masquerade as that table and mis-route the whole run.
    if (index($opt{outputs}, 'depends_on') >= 0) {
        arg_error('add-harvest',
            "--outputs contains the literal token 'depends_on' (SYN-14 hazard). Rephrase without it.");
    }

    run_write('add-harvest', $opt{file}, sub {
        my ($orig) = @_;
        my @lines = split /\n/, $orig, -1;
        my ($start, $end) = locate_harvest_bounds(\@lines);
        return (undef, "no '## Harvest log' section found") unless defined $start;
        my $tbl = decisions_table_info(\@lines, $start, $end);
        return (undef, "the Harvest log section is not table-shaped (no `|`-row + separator pair)")
            unless $tbl;

        # Fill by COLUMN HEADER, never by position -- the table's shape belongs to the
        # blueprint author, and assuming the template's 4 columns is how a generic API
        # silently corrupts a project-specific one.
        my @cells;
        for my $i (0 .. $#{ $tbl->{cols} }) {
            my $h = $tbl->{cols}[$i];
            if    ($i == 0)                       { push @cells, $opt{pkg} }
            elsif ($h =~ /output|verified\s+what/i){ push @cells, $opt{outputs} }
            elsif ($h =~ /by|who/i)               { push @cells, $opt{by} // 'orchestrator' }
            elsif ($h =~ /date|when/i)            { push @cells, $opt{date} // _today() }
            else                                   { push @cells, '' }
        }
        my $row = '| ' . join(' | ', @cells) . ' |';

        # Walk to the end of the contiguous row block (see add-decision: appending at the
        # section's end_i lands AFTER the trailing blank line, which terminates the table
        # and orphans the row).
        my $ins = $tbl->{sep_i} + 1;
        my @blank_rows;
        while (defined $lines[$ins] && $lines[$ins] =~ /^\s*\|/) {
            # The template ships a placeholder `| | | |`, and _is_sep_row matches it --
            # its character class is [\s:|-], which an all-blank row satisfies. So the
            # placeholder READS AS A SEPARATOR and stops the walk, which is why the first
            # cut inserted above it and never removed it. Discriminate first: an all-empty
            # row is a placeholder; a separator is what is left that still matches.
            my $blank = (join('', _table_cols($lines[$ins])) =~ /^\s*$/);
            last if !$blank && _is_sep_row($lines[$ins]);
            push @blank_rows, $ins if $blank;
            $ins++;
        }
        splice(@lines, $ins, 0, $row);
        # Remove placeholders AFTER inserting, so the recorded indices stay valid (they
        # are all below $ins), and highest-first so earlier removals don't shift later ones.
        splice(@lines, $_, 1) for reverse @blank_rows;
        return (join("\n", @lines), undef);
    });
}

sub op_set_decision {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'id=s', 'text=s'); }
    arg_error('set-decision', 'unrecognised option') unless $ok;
    arg_error('set-decision', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file id text)) {
        arg_error('set-decision', "missing required --$r") unless defined $opt{$r};
    }
    unless (field_safe($opt{id})) {
        arg_error('set-decision', '--id contains a pipe or newline');
    }
    unless (field_safe($opt{text})) {
        arg_error('set-decision', '--text contains a pipe or newline');
    }
    # SYN-14 hazard, identical wording class to op_add_decision (spec §4): the decisions
    # table sits ABOVE the real depends_on/DAG header, so a --text carrying the literal
    # token risks becoming (or masquerading as) a second such row and mis-routing parse_dag.
    if (index($opt{text}, 'depends_on') >= 0) {
        arg_error('set-decision',
            "--text contains the literal token 'depends_on' (SYN-14 hazard: parse_dag latches onto the "
          . 'FIRST |-row containing that token as its table header -- a second one mis-routes the whole '
          . 'run). Rephrase without the literal token.');
    }

    # Best-effort pre-check outside the lock: an unknown --id is refused up front (exit 3,
    # via arg_error, file never opened for writing) rather than only discovered inside the
    # write transaction. The mutate callback below re-derives this under the lock and is
    # the actual source of truth -- this pre-check only makes the common case a clean,
    # argument-validation-style refusal instead of a generic write-transaction rejection.
    {
        my $pre = _slurp($opt{file});
        if (defined $pre) {
            my @lines = split /\n/, $pre, -1;
            my ($start, $end) = locate_decisions_bounds(\@lines);
            if (defined $start) {
                my $tbl = decisions_table_info(\@lines, $start, $end);
                if ($tbl && !defined decisions_find_row(\@lines, $tbl, $opt{id})) {
                    arg_error('set-decision', "no decision with id '$opt{id}' found in the table");
                }
            }
        }
    }

    run_write('set-decision', $opt{file}, sub {
        my ($orig) = @_;
        my @lines = split /\n/, $orig, -1;
        my ($start, $end) = locate_decisions_bounds(\@lines);
        return (undef, "no '## Decisions' section found") unless defined $start;
        my $tbl = decisions_table_info(\@lines, $start, $end);
        return (undef, "the Decisions section is not table-shaped; set-decision requires a table")
            unless $tbl;
        my $ci = decisions_text_col($tbl->{cols});
        return (undef, "decisions table has no identifiable text column") unless defined $ci;
        my $ri = decisions_find_row(\@lines, $tbl, $opt{id});
        return (undef, "no decision with id '$opt{id}' found in the table") unless defined $ri;

        # When the decision text is the LAST column, everything after the preceding `|` IS the
        # text -- including any unescaped `|` the prose happens to contain. replace_cell splits
        # on `|` and rewrites one field, so on such a row it overwrote only the first fragment
        # and left the rest of the old prose trailing behind the new text.
        #
        # Measured: SYN-14 of sandbox-butler-overhaul is the one decision of 26 whose text
        # carries an internal pipe. Replacing its cell produced a 1,338-byte row holding the new
        # statement AND the tail of the original. Silent corruption of the row this op exists to
        # rewrite, so it is handled here rather than left to callers to pre-sanitise.
        my $new_line;
        if ($ci == $#{ $tbl->{cols} }) {
            my @c = _table_cols($lines[$ri]);
            my @keep = @c[0 .. $ci - 1];
            $new_line = '| ' . join(' | ', @keep, $opt{text}) . ' |';
        }
        else {
            # Interior column: one field, one replacement -- the same helper set-deps uses.
            $new_line = replace_cell($lines[$ri], $ci, $opt{text});
        }
        return (undef, "internal error replacing the decision text cell for '$opt{id}'")
            unless defined $new_line;
        $lines[$ri] = $new_line;
        return (join("\n", @lines), undef);
    });
}

# -------------------------------------------------------------------------------------
# op_set_title — rewrite the document's H1 title (line 1: `# <text>`).
#
# No existing verb owns this region (04-blueprint-title-verb spec §1): `set-meta` only
# rewrites `key: value` lines inside the fenced metadata block, and `set-section`
# explicitly refuses structural sections and operates on `##` headings, not the H1.
# Fence-aware (spec §2.2): both real blueprints carry single-`#`-prefixed COMMENT lines
# (e.g. `# owner: platform`) inside the fenced metadata block, which a naive `^#`
# scan would miscount as extra H1 candidates and refuse on every real invocation.
# Refuse-rather-than-guess on no H1 / H1 not on line 1 / more than one candidate --
# matching this script's existing posture (add-package refuses a missing depends_on
# table rather than inventing one; set-section refuses a missing `## ` heading the same
# way). Always normalises to a single space after `#` (spec §2.3), so idempotence falls
# out of run_write's own `$new eq $orig` no-op branch -- no second check is added here.
# -------------------------------------------------------------------------------------
sub op_set_title {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'title=s'); }
    arg_error('set-title', 'unrecognised option') unless $ok;
    arg_error('set-title', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file title)) {
        arg_error('set-title', "missing required --$r") unless defined $opt{$r};
    }
    unless (field_safe($opt{title})) {
        arg_error('set-title', '--title contains a pipe or newline');
    }

    run_write('set-title', $opt{file}, sub {
        my ($orig) = @_;
        my @lines = split /\n/, $orig, -1;

        my $in_fence = 0;
        my @candidates;
        for my $i (0 .. $#lines) {
            if ($lines[$i] =~ /^```/) { $in_fence = !$in_fence; next }
            next if $in_fence;
            push @candidates, $i if $lines[$i] =~ /^#(?!#)[ \t]+\S/;
        }

        if (!@candidates) {
            return (undef, "no H1 (a single '# ' heading) found outside any fenced block in $opt{file} -- "
                         . "refusing to invent one; the template places it on line 1.");
        }
        if (@candidates > 1) {
            my $n = scalar @candidates;
            my @onebased = map { $_ + 1 } @candidates;
            return (undef, "$n '# ' headings found outside fenced blocks (lines " . join(', ', @onebased) . ') '
                         . '-- refusing to guess which is the title.');
        }
        if ($candidates[0] != 0) {
            my $n1 = $candidates[0] + 1;
            return (undef, "the only '# ' heading found is on line $n1, not line 1 -- refusing to guess this "
                         . "is the blueprint's title; move it to line 1, or this is not the H1.");
        }

        $lines[0] = '# ' . $opt{title};
        return (join("\n", @lines), undef);
    });
}

sub op_set_field {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'pkg=s', 'field=s', 'value=s'); }
    arg_error('set-field', 'unrecognised option') unless $ok;
    arg_error('set-field', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file pkg field value)) {
        arg_error('set-field', "missing required --$r") unless defined $opt{$r};
    }
    my ($pkg, $field, $value) = @opt{qw(pkg field value)};

    if (lc($field) eq 'status') {
        arg_error('set-field', $STATUS_RETIRED_MSG);
    }
    if (lc($field) eq 'depends_on') {
        return op_set_deps('--file', $opt{file}, '--pkg', $pkg, '--deps', $value);
    }
    unless (field_safe($value)) {
        arg_error('set-field', "--value contains a pipe or newline; would break the table row");
    }

    run_write('set-field', $opt{file}, sub {
        my ($orig) = @_;
        my $tbl = locate_table($orig);
        return (undef, "no package-status table found (no 'depends_on' column header)") unless $tbl;
        my $ci = col_index($tbl, $field);
        return (undef, "table has no '$field' column") unless defined $ci;
        my $ri = find_row_index($tbl, $pkg);
        return (undef, "no such package '$pkg' in the table") unless defined $ri;

        my @lines = @{ $tbl->{lines} };
        my $ncols = scalar @{ $tbl->{cols} };
        my $nrow  = row_cell_count($lines[$ri]);
        return (undef, "row for '$pkg' has $nrow cell(s) but the header has $ncols column(s); "
              . "refusing to write into a row of mismatched arity rather than guess which cell is '$field'")
            if $nrow != $ncols;
        my $new_line = replace_cell($lines[$ri], $ci, $value);
        return (undef, "internal error replacing the '$field' cell for '$pkg'") unless defined $new_line;
        $lines[$ri] = $new_line;
        return (join("\n", @lines), undef);
    });
}

# =====================================================================================
# Read ops -- equally important (spec §2.2): a coordinator must be able to fetch its
# own block without slurping the whole file. `show` is bounded well under 8 KB (G8).
# =====================================================================================

sub _read_or_die {
    my ($sub, $file) = @_;
    my $b = _slurp($file);
    io_error($sub, "cannot read $file: $!") unless defined $b;
    return $b;
}

sub row_fields {
    my ($tbl, $ri) = @_;
    my @c = _table_cols($tbl->{lines}[$ri]);
    my %f;
    my @cols = @{ $tbl->{cols} };
    for my $i (0 .. $#cols) {
        my $v = defined $c[$i] ? $c[$i] : '';
        $f{$cols[$i]} = $v;
    }
    return \%f;
}

sub op_show {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { }; $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'pkg=s'); }
    arg_error('show', 'unrecognised option') unless $ok;
    for my $r (qw(file pkg)) { arg_error('show', "missing required --$r") unless defined $opt{$r}; }

    my $B = _read_or_die('show', $opt{file});
    my $tbl = locate_table($B);
    notfound_error('show', "no package-status table found") unless $tbl;
    my $ri = find_row_index($tbl, $opt{pkg});
    notfound_error('show', "no such package '$opt{pkg}' in the table") unless defined $ri;

    my $f = row_fields($tbl, $ri);
    for my $col (@{ $tbl->{cols} }) {
        print "$col: $f->{$col}\n";
    }
    exit 0;
}

sub op_deps {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { }; $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'pkg=s'); }
    arg_error('deps', 'unrecognised option') unless $ok;
    for my $r (qw(file pkg)) { arg_error('deps', "missing required --$r") unless defined $opt{$r}; }

    my $B = _read_or_die('deps', $opt{file});
    my $dag = BpOrch::parse_dag($B);
    notfound_error('deps', "no such package '$opt{pkg}' in the table") unless exists $dag->{ $opt{pkg} };

    # package 30 (spec §2.4): print tokens verbatim, in CELL ORDER, including
    # cross tokens -- BpOrch::parse_dag itself still drops them (§5, "other
    # readers"), so the existence check above uses it but the printed list
    # does not.
    my @tokens;
    my $tbl = locate_table($B);
    if ($tbl) {
        my $ci = col_index($tbl, 'depends_on');
        my $ri = defined $ci ? find_row_index($tbl, $opt{pkg}) : undef;
        if (defined $ci && defined $ri) {
            my @c = _table_cols($tbl->{lines}[$ri]);
            @tokens = split_dep_tokens($c[$ci] // '');
        }
    }
    print "$_\n" for @tokens;
    exit 0;
}

sub op_status {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { }; $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'pkg=s'); }
    arg_error('status', 'unrecognised option') unless $ok;
    arg_error('status', 'missing required --file') unless defined $opt{file};

    my $B = _read_or_die('status', $opt{file});
    my $tbl = locate_table($B);
    notfound_error('status', "no package-status table found") unless $tbl;
    my $ci = col_index($tbl, 'status');
    notfound_error('status', "table has no 'status' column") unless defined $ci;

    if (defined $opt{pkg}) {
        my $ri = find_row_index($tbl, $opt{pkg});
        notfound_error('status', "no such package '$opt{pkg}' in the table") unless defined $ri;
        my @c = _table_cols($tbl->{lines}[$ri]);
        print "$c[$ci]\n";
        exit 0;
    }
    for my $i ($tbl->{hdr_i} + 1 .. $tbl->{end_i} - 1) {
        next if _is_sep_row($tbl->{lines}[$i]);
        my @c = _table_cols($tbl->{lines}[$i]);
        next unless defined $c[0] && length $c[0];
        print "$c[0]: $c[$ci]\n";
    }
    exit 0;
}

sub op_decisions {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { }; $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'id=s'); }
    arg_error('decisions', 'unrecognised option') unless $ok;
    arg_error('decisions', 'missing required --file') unless defined $opt{file};

    my $B = _read_or_die('decisions', $opt{file});
    my @lines = split /\n/, $B, -1;
    my ($start, $end) = locate_decisions_bounds(\@lines);
    notfound_error('decisions', "no '## Decisions' section found") unless defined $start;

    # Shape-aware, for the same reason set-decision is: a decisions section may be a bullet list
    # or a markdown table. Reading only bullets against a table printed nothing and exited 0 --
    # a silent vacuous success, indistinguishable from "this blueprint has no decisions".
    my @found;
    my $tbl = decisions_table_info(\@lines, $start, $end);
    if ($tbl) {
        my $col = decisions_text_col($tbl->{cols});
        notfound_error('decisions', 'decisions table has no column holding the decision text')
            unless defined $col;
        for my $i ($tbl->{sep_i} + 1 .. $tbl->{end_i} - 1) {
            next unless defined $lines[$i] && $lines[$i] =~ /^\s*\|/;
            next if _is_sep_row($lines[$i]);
            my @cells = _table_cols($lines[$i]);
            next unless @cells > $col;
            my $id = $cells[0];
            next unless defined $id && $id =~ /^\S+$/;
            push @found, [ $id, $cells[$col] ];
        }
    }
    else {
        for my $i ($start + 1 .. $end - 1) {
            next unless $lines[$i] =~ /^-\s*(\S+?):\s*(.*)$/;
            push @found, [ $1, $2 ];
        }
    }

    my @sel = defined $opt{id} ? grep { $_->[0] eq $opt{id} } @found : @found;

    # Never exit 0 having found nothing: an empty result is either a bad --id or a section shape
    # this op cannot read, and both must be distinguishable from a genuinely empty section.
    if (!@sel) {
        notfound_error('decisions', "no decision with id '$opt{id}' found") if defined $opt{id};
        notfound_error('decisions',
            'decisions section contains no readable entries (neither `- ID: text` bullets nor a table row)')
            if !@found;
    }

    print "$_->[0]: $_->[1]\n" for @sel;
    exit 0;
}

# =====================================================================================
# Main.
# =====================================================================================

my %DISPATCH = (
    'init'         => \&op_init,
    'set-meta'     => \&op_set_meta,
    'set-section'  => \&op_set_section,
    'add-package'  => \&op_add_package,
    'set-status'   => \&op_set_status,
    'set-deps'     => \&op_set_deps,
    'set-test-paths' => \&op_set_test_paths,
    'add-decision' => \&op_add_decision,
    'set-decision' => \&op_set_decision,
    'add-harvest'  => \&op_add_harvest,
    'set-field'    => \&op_set_field,
    'set-title'    => \&op_set_title,
    'show'         => \&op_show,
    'deps'         => \&op_deps,
    'status'       => \&op_status,
    'decisions'    => \&op_decisions,
);

my $sub = shift @ARGV;
if (!defined $sub || $sub eq '') {
    arg_error('(none)', 'missing subcommand; expected one of: ' . join(', ', sort keys %DISPATCH));
}
unless (exists $DISPATCH{$sub}) {
    arg_error($sub, "unknown subcommand '$sub'; expected one of: " . join(', ', sort keys %DISPATCH));
}
$DISPATCH{$sub}->(@ARGV);
exit 0;
