#!/usr/bin/env perl
# platform: any
# Machine-checks the seven butler skill files against package 02's continuity
# block rules: a delimited <!-- continuity:begin/end --> block per file, a
# per-file line budget counted inside it, a ban on the three stop-machinery
# words (butler-hold, butler-continuity, silence) outside it, a retired-term
# sweep across the whole file, required content per skill, and ordering for
# the two skills whose block placement matters. Reads SKILL.next.md when
# present, else falls back to the live SKILL.md, so it keeps working once
# package 16 swaps the files in. Reads nothing else: no environment variable
# except via FindBin, no process spawn, no network, no butler run state.
#
# Rule ids below (F, B, N, O, R, P, Q) are the spec's own letters, not
# invented here -- see specs/15-skills-prose-spec.md section 2.4.

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

# ---------------------------------------------------------------------------
# Low-level helpers shared by every rule sub. Each rule sub itself takes a
# plain string (AC-9), never a filehandle or a path.
# ---------------------------------------------------------------------------

my $BEGIN_MARKER = '<!-- continuity:begin -->';
my $END_MARKER   = '<!-- continuity:end -->';

sub _normalize_marker_line {
    my ($line) = @_;
    return '' unless defined $line;
    $line =~ s/\r\z//;
    $line =~ s/[ \t]+\z//;
    return $line;
}

# Returns (\@begin_indices, \@end_indices) over the line array.
sub _marker_indices {
    my (@lines) = @_;
    my (@b, @e);
    for my $i (0 .. $#lines) {
        my $norm = _normalize_marker_line($lines[$i]);
        push @b, $i if $norm eq $BEGIN_MARKER;
        push @e, $i if $norm eq $END_MARKER;
    }
    return (\@b, \@e);
}

sub _lines_of { my ($text) = @_; return split /\n/, (defined $text ? $text : ''); }

# ---------------------------------------------------------------------------
# Rule B -- block shape: exactly one begin, exactly one end, begin first.
# Returns a (possibly empty) list of violation strings.
# ---------------------------------------------------------------------------
sub rule_B_violations {
    my ($text) = @_;
    my @lines  = _lines_of($text);
    my ($b, $e) = _marker_indices(@lines);
    my @v;
    push @v, 'expected exactly one begin marker, found ' . scalar(@$b) unless @$b == 1;
    push @v, 'expected exactly one end marker, found ' . scalar(@$e) unless @$e == 1;
    if (@$b == 1 && @$e == 1 && $b->[0] >= $e->[0]) {
        push @v, 'begin marker does not come before end marker';
    }
    return @v;
}

# Strictly-between-markers line array, or undef if the shape is not the
# clean single-begin/single-end/begin-first case.
sub _block_line_range {
    my (@lines) = @_;
    my ($b, $e) = _marker_indices(@lines);
    return undef unless @$b == 1 && @$e == 1 && $b->[0] < $e->[0];
    return ($b->[0], $e->[0]);
}

# ---------------------------------------------------------------------------
# Rule N -- budget: non-blank lines strictly between the markers, blank
# meaning /^\s*$/, must be <= $budget.
# ---------------------------------------------------------------------------
sub rule_N_violations {
    my ($text, $budget) = @_;
    my @lines = _lines_of($text);
    my ($bi, $ei) = _block_line_range(@lines);
    return ('block shape invalid, cannot compute budget') unless defined $bi;
    my $count = 0;
    for my $i ($bi + 1 .. $ei - 1) {
        $count++ unless $lines[$i] =~ /^\s*$/;
    }
    return () if $count <= $budget;
    return ("budget exceeded: $count non-blank lines inside the block > $budget");
}

# ---------------------------------------------------------------------------
# Rule O -- outside-block ban on butler-hold / butler-continuity / silence.
# "Outside" excludes everything from the first begin line through the last
# end line, inclusive; if no complete pair is found, the whole text counts
# as outside (nothing to exempt).
# ---------------------------------------------------------------------------
sub _outside_text {
    my ($text) = @_;
    my @lines = _lines_of($text);
    my ($b, $e) = _marker_indices(@lines);
    if (@$b >= 1 && @$e >= 1 && $b->[0] < $e->[-1]) {
        my @out = (@lines[0 .. $b->[0] - 1], @lines[$e->[-1] + 1 .. $#lines]);
        return join("\n", @out);
    }
    return join("\n", @lines);
}

sub rule_O_violations {
    my ($text) = @_;
    my $outside = _outside_text($text);
    my @v;
    push @v, "outside text matches /butler-hold|butler-continuity|\\bsilence/i"
        if $outside =~ /butler-hold|butler-continuity|\bsilence/i;
    return @v;
}

# ---------------------------------------------------------------------------
# Rule R -- retired terms, whole file, after deleting the Decision 4
# exception string. Patterns are case-sensitive as written in the spec.
# ---------------------------------------------------------------------------
my @RETIRED_PATTERNS = (
    [ R1  => qr/bp-watch(?!-child)/ ],
    [ R2  => qr/bp-continuity/ ],
    [ R3  => qr/hold --seconds/ ],
    [ R4  => qr/\.run-finished/ ],
    [ R5  => qr/\.stop-ok/ ],
    [ R6  => qr/reporter-stop-ok/ ],
    [ R7  => qr/\.subagent-guard\/force-stop/ ],
    [ R8  => qr/[.\/]force-stop/ ],
    [ R9  => qr/CCPRAXIS_\w*STOP_OK/ ],
    [ R10 => qr/MAX_BLOCKS/ ],
    [ R11 => qr/\b(?:gate-drive-loop|gate-continuity|guard-subagent-stall|guard-run-finish|mark-wakeup)\b/ ],
    [ R12 => qr/\b(?:gate-stop|gate-headless-background|guard-validation-interlock|guard-judge-checks|guard-ledger-create|dispatch-discipline-nudge|context-ceiling-guidance|context-ceiling-flush|log-dispatch|record-dispatch-package|repeat-guard|track-worker-solo|untrack-worker-solo)\.sh\b/ ],
    [ R13 => qr/(?<![\w-])lib\.sh/ ],
    [ R14 => qr/\b(?:bp_hook_gate|bp_drive_retire)\b|butler-drive-solo-retire/ ],
    [ R15 => qr/wakeup-pending/ ],
    [ R16 => qr/\.(?:drive-solo|continuity|reporter)-active\b/ ],
    [ R17 => qr/\bbp-(?:resumption|session)\.pl\b/ ],
);

my $FORCE_STOP_EXCEPTION = 'runs/<pkg>.force-stop';

sub rule_R_violations {
    my ($text) = @_;
    my $t = defined $text ? $text : '';
    $t =~ s/\Q$FORCE_STOP_EXCEPTION\E//g;
    my @v;
    for my $pair (@RETIRED_PATTERNS) {
        my ($id, $re) = @$pair;
        push @v, "$id matched ($re)" if $t =~ $re;
    }
    return @v;
}

# ---------------------------------------------------------------------------
# Rule P -- required content. block-scoped items must be inside the block;
# file-scoped items may be anywhere. Matching is case-insensitive substring.
# ---------------------------------------------------------------------------
sub _block_text {
    my ($text) = @_;
    my @lines = _lines_of($text);
    my ($bi, $ei) = _block_line_range(@lines);
    return undef unless defined $bi;
    return join("\n", @lines[$bi + 1 .. $ei - 1]);
}

sub _has_ci {
    my ($haystack, $needle) = @_;
    return 0 unless defined $haystack;
    return index(lc($haystack), lc($needle)) >= 0;
}

# Returns a list of violation strings: one per missing required item.
sub rule_P_violations {
    my ($text, $block_items, $file_items) = @_;
    my @v;
    my $block = _block_text($text);
    for my $item (@{ $block_items || [] }) {
        if (!defined $block) {
            push @v, "block invalid, cannot verify block-required '$item'";
        } elsif (!_has_ci($block, $item)) {
            push @v, "missing block-required '$item'";
        }
    }
    for my $item (@{ $file_items || [] }) {
        push @v, "missing file-required '$item'" unless _has_ci($text, $item);
    }
    return @v;
}

# ---------------------------------------------------------------------------
# Rule Q -- ordering, reporter and drive-solo only.
# ---------------------------------------------------------------------------
sub rule_Q_reporter_violations {
    my ($text) = @_;
    my @lines = _lines_of($text);
    my ($bi, $ei) = _block_line_range(@lines);
    my @v;
    return ('block invalid, cannot verify Q') unless defined $bi;
    my $block = _block_text($text);
    my $pos = index($block, 'butler-');
    my $expect = 'butler-continuity on --role reporter';
    if ($pos < 0 || substr($block, $pos, length($expect)) ne $expect) {
        push @v, "first 'butler-' inside the block does not start '$expect'";
    }
    my $first_heading;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^## /) { $first_heading = $i; last; }
    }
    if (!defined $first_heading) {
        push @v, 'no line matching ^## found to order the block against';
    } elsif ($bi >= $first_heading) {
        push @v, 'begin marker does not precede the first ^## heading';
    }
    return @v;
}

sub rule_Q_drive_solo_violations {
    my ($text) = @_;
    my @lines = _lines_of($text);
    my ($bi, $ei) = _block_line_range(@lines);
    my @v;
    return ('block invalid, cannot verify Q') unless defined $bi;
    my $block = _block_text($text);
    my $pos = index($block, 'butler-');
    my $expect = 'butler-continuity on --role driver';
    if ($pos < 0 || substr($block, $pos, length($expect)) ne $expect) {
        push @v, "first 'butler-' inside the block does not start '$expect'";
    }
    my $preflight_idx;
    for my $i (0 .. $#lines) {
        if (_normalize_marker_line($lines[$i]) eq '## Preflight') { $preflight_idx = $i; last; }
    }
    if (!defined $preflight_idx) {
        push @v, 'no line "## Preflight" found to order the block against';
    } elsif ($bi >= $preflight_idx) {
        push @v, 'begin marker does not precede the "## Preflight" line';
    }
    return @v;
}

# ---------------------------------------------------------------------------
# Rule F -- frontmatter + H1 shape.
# ---------------------------------------------------------------------------
sub rule_F_violations {
    my ($text, $expected_name) = @_;
    my @lines = _lines_of($text);
    $lines[0] =~ s/\A\xEF\xBB\xBF// if defined $lines[0];   # raw bytes: a BOM is EF BB BF
    my @v;
    unless (defined $lines[0] && $lines[0] =~ /^---\s*\z/) {
        push @v, "first line is not '---'";
        return @v;
    }
    my $end_idx;
    for my $i (1 .. $#lines) {
        if ($lines[$i] =~ /^---\s*\z/) { $end_idx = $i; last; }
    }
    unless (defined $end_idx) {
        push @v, 'no closing --- found for frontmatter';
        return @v;
    }
    my $found_name = 0;
    for my $i (1 .. $end_idx - 1) {
        if ($lines[$i] =~ /^name:\s*\Q$expected_name\E\s*\z/) { $found_name = 1; last; }
    }
    push @v, "frontmatter missing 'name: $expected_name'" unless $found_name;
    my $found_h1 = 0;
    for my $i ($end_idx + 1 .. $#lines) {
        if ($lines[$i] =~ /^# \S/) { $found_h1 = 1; last; }
    }
    push @v, 'no line matching ^# \S after frontmatter' unless $found_h1;
    return @v;
}

# ===========================================================================
# AC-9: self-proof fixtures. Every fixture below is an inline string built by
# this file, never read from disk -- no scratch files, nothing under the
# skills tree.
# ===========================================================================

# (a) A retired term inside a block fails R.
{
    my $text = "before\n$BEGIN_MARKER\nrun bp-watch.pl --arm to start\n$END_MARKER\nafter\n";
    my @v = rule_R_violations($text);
    ok(@v > 0, 'AC-9(a): a retired term (bp-watch.pl) inside the block fails rule R');
}

# (b) butler-hold outside a block fails O.
{
    my $text = "call butler-hold first\n$BEGIN_MARKER\nsome guidance\n$END_MARKER\n";
    my @v = rule_O_violations($text);
    ok(@v > 0, 'AC-9(b): butler-hold outside the block fails rule O');
}

# (c) A block one line over budget fails N; at budget it passes.
{
    my $ok_text = "$BEGIN_MARKER\nline one\nline two\nline three\n$END_MARKER\n";
    my @ok_v = rule_N_violations($ok_text, 3);
    is_deeply(\@ok_v, [], 'AC-9(c): a block at exactly its budget passes rule N');

    my $over_text = "$BEGIN_MARKER\nline one\nline two\nline three\nline four\n$END_MARKER\n";
    my @over_v = rule_N_violations($over_text, 3);
    ok(@over_v > 0, 'AC-9(c): a block one line over budget fails rule N');
}

# (d) Two begin markers fail B; a missing end fails B.
{
    my $two_begins = "$BEGIN_MARKER\nx\n$BEGIN_MARKER\ny\n$END_MARKER\n";
    my @v1 = rule_B_violations($two_begins);
    ok(@v1 > 0, 'AC-9(d): two begin markers fails rule B');

    my $no_end = "$BEGIN_MARKER\nx\ny\n";
    my @v2 = rule_B_violations($no_end);
    ok(@v2 > 0, 'AC-9(d): a missing end marker fails rule B');
}

# (e) force-stop exception and kept names pass R; the rest fail R.
{
    for my $pass_text (
        'see runs/<pkg>.force-stop for the one-shot escape',
        'bp-watch-child.pl is kept',
        'bp-lib.sh has the shared helpers',
    ) {
        my @v = rule_R_violations($pass_text);
        is_deeply(\@v, [], "AC-9(e): '$pass_text' passes rule R");
    }
    for my $fail_text (
        '.subagent-guard/force-stop',
        'runs/x.force-stop',
        'hooks/lib.sh',
        'bp-continuity.pl hold',
        'CCPRAXIS_DRIVE_STOP_OK',
    ) {
        my @v = rule_R_violations($fail_text);
        ok(@v > 0, "AC-9(e): '$fail_text' fails rule R");
    }
}

# (f) "silenced" outside a block fails O (case-insensitive).
{
    my $text = "the run is Silenced for now\n$BEGIN_MARKER\nguidance\n$END_MARKER\n";
    my @v = rule_O_violations($text);
    ok(@v > 0, 'AC-9(f): "Silenced" outside the block fails rule O (case-insensitive)');
}

# (g) Blank lines inside a block do not count toward N.
{
    my $text = "$BEGIN_MARKER\nline one\n\n\nline two\n\n$END_MARKER\n";
    my @v = rule_N_violations($text, 2);
    is_deeply(\@v, [], 'AC-9(g): blank lines inside the block do not count toward the budget');
}

# ===========================================================================
# Target resolution (2.4): SKILL.next.md if present, else the live SKILL.md.
# Paths resolved from $Bin, no other filesystem walk.
# ===========================================================================

my %SKILLS = (
    continuity => {
        dir    => "$Bin/../../skills/continuity",
        name   => 'continuity',
        budget => 40,
        block_required => [
            'butler-continuity on',
            'outlive the turn',
            'unattended multi-step',
            "butler-continuity off --reason '<what is done>'",
            "butler-continuity silence --reason '<why this stop>'",
            'at least two words',
            'all work is done',
            'wait for the operator',
            '--token',
            'butler-hold <id>',
            'run_in_background: true',
            '50 minutes',
            'one holder per session',
            'never starts a second holder',
            'dispatch alone',
            '/butler:continuity off',
            'butler-continuity status',
            'butler-continuity ask --text',
        ],
        file_required => [],
        rule_q => undef,
    },
    'drive-solo' => {
        dir    => "$Bin/../../skills/drive-solo",
        name   => 'drive-solo',
        budget => 12,
        block_required => [
            'butler-continuity on --role driver',
            'Ledger: ',
            'exactly one',
            'in flight',
            'fork',
            'butler-hold',
            'run_in_background: true',
            "butler-continuity off --reason '<what is done>'",
            '`pause-long`',   # pkg10/never-halt AC-13: the off-line now also names pause-long
        ],
        file_required => [
            '`in-flight`',
            '`inflight`',
            'its own ledger',
            'STOP ITERATING AND REPORT NOW',
            'bp-dispatch-log.pl start',
            'do not defer again',
            '`pause-long`',   # pkg10/never-halt AC-13: the new action-table row
            'until_iso',      # pkg10/never-halt AC-13: the new action's handoff-time field
        ],
        rule_q => \&rule_Q_drive_solo_violations,
    },
    reporter => {
        dir    => "$Bin/../../skills/reporter",
        name   => 'reporter',
        budget => 4,
        block_required => [
            'butler-continuity on --role reporter',
            'butler-hold',
            'butler-continuity silence --reason',
            'butler-continuity off --reason',
        ],
        file_required => [],
        rule_q => \&rule_Q_reporter_violations,
    },
    'coordinator-protocol' => {
        dir    => "$Bin/../../skills/coordinator-protocol",
        name   => 'coordinator-protocol',
        budget => 12,
        block_required => [
            'butler-hold',
            'background subagent',
            '## Next action',
            'refuse',
        ],
        file_required => [
            'Ledger: ',
            'its own ledger',
            'fork',
            'registry-path',
            'runs/<pkg>.force-stop',
        ],
        rule_q => undef,
        force_stop_literal => 1,
    },
    'orchestrator-protocol' => {
        dir    => "$Bin/../../skills/orchestrator-protocol",
        name   => 'orchestrator-protocol',
        budget => 6,
        block_required => [
            'runs/.paused',
            'runs/.shutdown',
            'runs/<pkg>.force-stop',
            'butler-hold',
        ],
        file_required => [],
        rule_q => undef,
        force_stop_literal => 1,
    },
    'dispatch-fleet' => {
        dir    => "$Bin/../../skills/dispatch-fleet",
        name   => 'dispatch-fleet',
        budget => 4,
        block_required => ['butler-hold'],
        file_required  => [],
        rule_q => undef,
    },
    'carry-over' => {
        dir    => "$Bin/../../../../skills/carry-over",
        name   => 'carry-over',
        budget => 3,
        block_required => [
            'butler-continuity status',
            'butler-continuity on',
            'Re-orient first',
        ],
        file_required => [],
        rule_q => undef,
    },
);

sub _slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

for my $skill_name (sort keys %SKILLS) {
    my $cfg = $SKILLS{$skill_name};
    subtest "skill: $skill_name" => sub {
        my $next_path = "$cfg->{dir}/SKILL.next.md";
        my $md_path   = "$cfg->{dir}/SKILL.md";
        my $target    = -e $next_path ? $next_path : $md_path;

        ok(-e $target, "$skill_name: a target file exists ($target)")
            or return;

        my $text = _slurp($target);
        ok(defined $text, "$skill_name: target file is readable")
            or return;

        # Rule F (AC-1)
        my @fv = rule_F_violations($text, $cfg->{name});
        unless (ok(@fv == 0, "$skill_name: passes rule F (frontmatter + H1)")) {
            diag($_) for @fv;
        }

        # Rule B (AC-2)
        my @bv = rule_B_violations($text);
        unless (ok(@bv == 0, "$skill_name: passes rule B (block shape)")) {
            diag($_) for @bv;
        }

        # Rule N (AC-3)
        my @nv = rule_N_violations($text, $cfg->{budget});
        unless (ok(@nv == 0, "$skill_name: passes rule N (budget <= $cfg->{budget})")) {
            diag($_) for @nv;
        }

        # Rule O (AC-4)
        my @ov = rule_O_violations($text);
        unless (ok(@ov == 0, "$skill_name: passes rule O (no stop words outside the block)")) {
            diag($_) for @ov;
        }

        # Rule R (AC-5)
        my @rv = rule_R_violations($text);
        unless (ok(@rv == 0, "$skill_name: passes rule R (no retired terms)")) {
            diag($_) for @rv;
        }

        if ($cfg->{force_stop_literal}) {
            ok(index($text, 'runs/<pkg>.force-stop') >= 0,
                "$skill_name: carries the literal 'runs/<pkg>.force-stop' (AC-5)");
        }

        # Rule P (AC-6 / AC-7 / AC-8, and per-skill "Required" lists)
        my @pv = rule_P_violations($text, $cfg->{block_required}, $cfg->{file_required});
        unless (ok(@pv == 0, "$skill_name: passes rule P (required content)")) {
            diag($_) for @pv;
        }

        # Rule Q, reporter and drive-solo only (AC-7 / AC-8)
        if (my $qsub = $cfg->{rule_q}) {
            my @qv = $qsub->($text);
            unless (ok(@qv == 0, "$skill_name: passes rule Q (block placement/ordering)")) {
                diag($_) for @qv;
            }
        }
    };
}

# ===========================================================================
# package 10 (never-halt): the new `pause-long` row in drive-solo/SKILL.md,
# and a non-regression pin on the pre-existing `pause` row.
# Spec: .ccpraxis-local-data/blueprints/never-halt/specs/10-long-usage-pause-ends-session-spec.md
#   AC-14 -- the pause-long row's own content (table-row check, new here).
#   AC-15 -- the pause row stays byte-identical to its pre-change text.
# ===========================================================================
{
    my $dir        = "$Bin/../../skills/drive-solo";
    my $next_path  = "$dir/SKILL.next.md";
    my $md_path    = "$dir/SKILL.md";
    my $target     = -e $next_path ? $next_path : $md_path;
    my $text       = _slurp($target);

    unless (ok(defined $text, '(pkg10) AC-14/AC-15: drive-solo target file is readable')) {
        done_testing();
        exit;
    }

    my @lines = _lines_of($text);

    # ── AC-14: exactly one pause-long row, with the required content ───────
    my @pl_matches = grep { /^\|\s*`pause-long`/ } @lines;
    is(scalar(@pl_matches), 1,
        '(pkg10) AC-14: exactly one line matches /^\|\s*`pause-long`/');

    SKIP: {
        skip '(pkg10) AC-14: no pause-long row to inspect', 16 unless @pl_matches == 1;
        my $row = $pl_matches[0];

        for my $term (
            'TaskStop', 'no background sleep', 'no holder', 'handoff',
            '## Next action', 'attempt-log', 'git status', 'pending',
            'decision', 're-invoke', 'until_iso', 'continuity off', 'last',
            # fix-batch (reviewer S1/S2/N1, red-team L1/L2/L3): the row must
            # also stop an already-running holder, ignore its late report,
            # close each stopped worker's dispatch-log record, note any
            # refused call behind a stop, explain why no report-first step,
            # and state the report/continuity-off ordering unambiguously.
            "holder's background task", 'ignore', 'after continuity is off',
            'bp-dispatch-log.pl finish', 'interrupted',
            'bp-denials summary', 'refused',
            'needs a holder', 'same response turn',
        ) {
            ok(index(lc($row), lc($term)) >= 0,
                "(pkg10) AC-14: the pause-long row mentions '$term' (case-insensitive)");
        }

        my $handoff_pos    = index(lc($row), 'handoff');
        my $continuity_pos = index(lc($row), 'continuity off');
        ok($handoff_pos >= 0 && $continuity_pos >= 0 && $handoff_pos < $continuity_pos,
            '(pkg10) AC-14: "handoff" appears before "continuity off" in the row');

        unlike($row, qr/butler-hold|butler-continuity|\bsilence/i,
            '(pkg10) AC-14/E10: the row names no stop-machinery command directly '
          . '(it points at "Continuity and dispatch" instead)');
        unlike($row, qr/sleeps until/,
            '(pkg10) AC-14: the row describes no background sleep');

        my @cells = split /\|/, $row;
        my $last_cell = $cells[-1] // '';
        like($last_cell, qr/\(none/,
            '(pkg10) AC-14: the last cell (Next director call) matches /\(none/');
    }

    # ── AC-15: the pre-existing pause row is byte-identical, unedited ──────
    my $PINNED_PAUSE_ROW =
        '| `pause` (reason=`usage`) | Wait **token-cheaply** until `action.until_epoch` with one '
      . 'background Bash call that sleeps until that epoch, held as described in Continuity and '
      . 'dispatch. Never busy-poll. | `next` again (after it finishes) |';

    my @pause_matches = grep { /^\|\s*`pause` \(reason/ } @lines;
    is(scalar(@pause_matches), 1,
        '(pkg10) AC-15: exactly one line matches /^\|\s*`pause` \(reason/');
    SKIP: {
        skip '(pkg10) AC-15: no pause row to compare', 1 unless @pause_matches == 1;
        (my $got = $pause_matches[0]) =~ s/\r\z//;
        is($got, $PINNED_PAUSE_ROW,
            '(pkg10) AC-15: the pause row is byte-identical to its pre-change text');
    }

    # ── fix-batch item L4 (red-team): "Never end a turn with nothing
    # scheduled" named only two reasons a turn may end; pause-long is
    # neither, so it must now be named as a third. Section-scoped (not the
    # continuity block), so no budget constraint applies here.
    my $heading_idx;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^## Never end a turn with nothing scheduled\s*\z/) {
            $heading_idx = $i; last;
        }
    }
    ok(defined $heading_idx,
        '(pkg10) L4: "## Never end a turn with nothing scheduled" heading is present');

    SKIP: {
        skip '(pkg10) L4: heading not found, cannot verify its section', 1
            unless defined $heading_idx;
        my $next_heading_idx;
        for my $i ($heading_idx + 1 .. $#lines) {
            if ($lines[$i] =~ /^## /) { $next_heading_idx = $i; last; }
        }
        my $section = join("\n", @lines[$heading_idx + 1 .. (defined $next_heading_idx ? $next_heading_idx - 1 : $#lines)]);
        like($section, qr/pause-long/,
            '(pkg10) L4: the "Never end a turn" section names pause-long as a legitimate way to end a turn');
    }
}

done_testing();
