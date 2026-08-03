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
# Exit codes (an interface, fixed): 0 success, 2 validation rejection (byte-identical
# file), 3 usage/argument error (nothing read), 4 I/O/lock/atomicity failure
# (byte-identical), 5 target region not found (byte-identical).
#
# stdout is ALWAYS empty, EXCEPT `rotate --dry-run`, which is a report-only op by
# spec (b45 §3) and prints its report to stdout while touching nothing. stderr on any
# non-zero exit is EXACTLY ONE line. `append-attempt` may ALSO print one budget-warning
# line to stderr on an otherwise-successful (exit 0) run — see BUDGET_BYTES below; that
# is not a rejection, just visibility, and the append still happens.
#
# Core Perl only: strict, warnings, Getopt::Long, Fcntl(:flock), JSON::PP, B. No
# other module may be loaded on any path (latency constraint, §2.5).
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

sub iso_now {
    my @t = gmtime(time);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# =====================================================================================
# The validation core — V1..V5, normative (spec §2.4). First failing class wins.
# Returns undef (valid) or a one-sentence DETAIL FRAGMENT (no framing prefix — the two
# framings differ only in prefix, per §2.2 / AC-30).
# =====================================================================================

my @REQUIRED_KEYS = qw(package blueprint status write_set last_updated);
my @STATUSES      = qw(pending running converging reviewing done blocked parked);

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
# The shared five-op algorithm (spec §2.3, steps 1..10).
# =====================================================================================

sub run_op {
    my ($sub, $path, $splice_cb, $post_cb) = @_;

    my $lockpath = "$path.lock";
    open(my $lk, '>', $lockpath) or io_error($sub, $path, "cannot open lock file $lockpath: $!");
    flock($lk, LOCK_EX) or io_error($sub, $path, "cannot acquire lock on $lockpath: $!");

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

    if ($new eq $orig) { $post_cb->($new) if $post_cb; exit 0 }

    my $tmp = "$path.tmp.$$";
    open(my $w, '>:raw', $tmp) or io_error($sub, $path, "cannot open temp file $tmp: $!");
    print {$w} $new or do { close $w; unlink $tmp; io_error($sub, $path, "write to $tmp failed: $!") };
    close($w) or do { unlink $tmp; io_error($sub, $path, "close $tmp failed: $!") };

    unless ($RENAME_FN->($tmp, $path)) {
        unlink $tmp;
        io_error($sub, $path, "rename $tmp -> $path failed: $!");
    }

    flock($lk, LOCK_UN);
    close($lk);
    $post_cb->($new) if $post_cb;
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
        if ($size > DEFAULT_BUDGET_BYTES) {
            emit_err("bp-ledger: append-attempt: $opt{ledger} is $size bytes, exceeding the "
                . DEFAULT_BUDGET_BYTES . "-byte budget; run: bp-ledger.pl rotate --ledger $opt{ledger}");
        }
    };
    run_op('append-attempt', $opt{ledger},
        sub { return splice_insert_entry($_[0], qr/^##\s+Decisions & attempt log\b/m, $entry) },
        $budget_check);
}

sub op_tick_step {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { }; $ok = GetOptionsFromArray(\@args, \%opt, 'ledger=s', 'step=s'); }
    arg_error('tick-step', 'unrecognised option') unless $ok;
    arg_error('tick-step', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    arg_error('tick-step', 'missing required --ledger') unless defined $opt{ledger};
    arg_error('tick-step', 'missing required --step') unless defined $opt{step};
    unless ($opt{step} =~ /^[1-9][0-9]*$/) {
        arg_error('tick-step', "'--step $opt{step}' is not a positive integer without a leading zero");
    }
    run_op('tick-step', $opt{ledger}, sub { return splice_tick_step($_[0], $opt{step}) });
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
          . "first non-blank line as the human-facing summary while gate-stop.sh additionally skips '#'-leading "
          . "lines, so the two readers would disagree about what the next action is");
    }
    if (grep { /^\s*-\s*\[[xX]\]/ } @lines) {
        arg_error('set-next-action',
            "the --body must not contain a line matching '- [x]' (would forge the orchestrator's ledger_checkboxes "
          . 'progress signal)');
    }
    run_op('set-next-action', $opt{ledger}, sub { return splice_set_next_action($_[0], $body) });
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
    my @parts = split(m{/}, $dir);
    my $cur = ($dir =~ m{^/}) ? '' : '.';
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

    if ($unreachable) {
        emit_err("bp-ledger: rotate: $ledger: $new_len bytes, over the $budget-byte budget after "
            . "rotating everything it legitimately can (floor --keep $floor_k non-marker entries "
            . "(" . $suffix_len[$k] . " bytes) + " . scalar(@forced) . " MEANS-DEVIATION entry/ies "
            . "($forced_len bytes) + fixed sections are, together, already over budget). "
            . 'Not reducible further without either dropping mandated retention or losing the record.');
    }

    if (!@moved) {
        if ($dry_run) {
            print "bp-ledger: rotate: $ledger: 0 of $total entries eligible to move; nothing to do.\n";
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
    my ($abs, $bytes) = @_;
    my $detail = validate_bytes($bytes);
    if (defined $detail) {
        deny_payload("LEDGER-GUARD: BLOCKED ${EMDASH} the content this write would leave in $abs $detail");
    }
    exit 0;
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
        validate_and_exit_payload($ABS, as_bytes($c));
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
        validate_and_exit_payload($ABS, splice_bytes($orig, $old, $new, $all));
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
        my $buf = read_bytes_or_m6($ABS, $ABS, $TOOL);
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
        validate_and_exit_payload($ABS, $buf);
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
    exit 0;
}

# =====================================================================================
# Main
# =====================================================================================

my %DISPATCH = (
    'set-status'      => \&op_set_status,
    'append-attempt'   => \&op_append_attempt,
    'tick-step'        => \&op_tick_step,
    'set-next-action'  => \&op_set_next_action,
    'add-output'       => \&op_add_output,
    'rotate'           => \&op_rotate,
    'validate'         => \&op_validate,
);

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
