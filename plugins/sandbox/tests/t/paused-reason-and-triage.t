#!/usr/bin/env perl
# platform: any
# 182 -- IMMUTABLE ORACLE for package
# 01 (blueprint agent-telemetry), specs/
# 01-spec.md. Derived from the spec's SS4
# acceptance criteria (AC1-AC17), written BLIND to any implementation of
# tui::DashboardScreen::_paused_reason_line -- it does not exist yet at the
# time this file is written; the spec's SS2.1 pseudocode was read for the
# CONTRACT SHAPE only (return undef|\@spans, the exact label text, the
# gating rule, the truncation bound), never executed, and this file's
# fixtures/golden values were verified only against the CURRENT,
# UNMODIFIED DashboardScreen.pm (for AC9/AC10's golden captures) and
# against the pure input/output contracts stated in the spec (everywhere
# else). Do NOT weaken an assertion here to make a future implementation's
# life easier.
#
# THE GOLDEN CAPTURES (AC9/AC10) were taken by running the CURRENT,
# UNMODIFIED plugins/sandbox/scripts/tui/DashboardScreen.pm on 2026-09-08,
# before this package's implementation existed, via a throwaway capture
# script that called _one_run_summary_cells/_run_summary_lines/panels()
# directly and printed the result with Data::Dumper. The literals below are
# that captured output, transcribed by hand into Perl syntax. Do NOT
# regenerate them from a future DashboardScreen.pm -- that would defeat the
# regression guard AC9/AC10 exist to be.
#
# NON-VACUITY: AC7 is explicitly the non-vacuity pair for AC5/AC6 (spec's
# own framing). Every other negative assertion here ("no fabricated line",
# "no die/warn") is paired with a positive twin elsewhere in this file that
# exercises the SAME detector on a fixture that SHOULD trip it.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use File::Spec ();

require Dashboard;
require tui::DashboardScreen;

# ===========================================================================
# Scaffolding
# ===========================================================================

# mk_run(%o) -> a run-summary hashref carrying ONLY the keys explicitly
# passed. Deliberately does NOT default every key the way t/63's mk_summary
# does -- AC9's golden fixtures and AC2/AC3's "key omitted" fixtures both
# depend on being able to construct a hash where a field is genuinely ABSENT
# (no key at all), not merely present-and-undef. Both _paused_reason_line and
# _one_run_summary_cells read via ->{key} with no `exists` check anywhere in
# their spec'd contract, so an absent key and an explicit undef value must
# (and do, per the spec's own guards) behave identically -- this helper lets
# either be constructed on demand.
sub mk_run {
    my (%o) = @_;
    my %s;
    for my $k (qw(blueprint state packages_done packages_total
                  running_coordinators inbox_waiting escalations_waiting
                  triage_waiting paused_reason current_package)) {
        $s{$k} = $o{$k} if exists $o{$k};
    }
    return \%s;
}

# RETARGETED by package 01-run-blocks (spec S5.1 table, ruling B/G):
# _paused_reason_line is removed. The pause words now live on the
# blueprint line itself (kind 'blueprint', lines[0]) built by _run_block.
# blueprint_line_spans($s, $now) -> \@spans | undef, never dies.
sub blueprint_line_spans {
    my ($s, $now) = @_;
    my $block = eval { tui::DashboardScreen::_run_block($s, $now, undef) };
    return undef if $@;
    return undef unless ref($block) eq 'HASH' && ref($block->{lines}) eq 'ARRAY' && ref($block->{lines}[0]) eq 'HASH';
    return $block->{lines}[0]{spans};
}
sub call_block_line0 {
    my ($s, $now) = @_;
    my $res = eval { blueprint_line_spans($s, $now) };
    my $err = $@;
    $err = '' unless defined $err;
    return ($res, $err);
}

sub base_state {
    my (%o) = @_;
    return { project_name => 'zqxproj182', container => 'zqxctr182', status => 'running', %o };
}

sub panel_by_title {
    my ($panels, $title) = @_;
    return undef unless ref($panels) eq 'ARRAY';
    for my $p (@$panels) {
        return $p if ref($p) eq 'HASH' && defined($p->{title}) && $p->{title} eq $title;
    }
    return undef;
}
sub line_text {
    my ($line) = @_;
    return '' unless ref($line) eq 'ARRAY';
    return join('', map { defined($_->{text}) ? $_->{text} : '' } @$line);
}
sub panel_line_texts {
    my ($panel) = @_;
    return [] unless $panel && ref($panel->{lines}) eq 'ARRAY';
    return [ map { line_text($_) } @{ $panel->{lines} } ];
}
sub plain {
    my ($c) = @_;
    my $t = $c->{text};
    $t =~ s/\x1b\[[0-9;]*m//g;
    return $t;
}
sub frame_text { my ($f) = @_; return join("\n", map { plain($_) } @$f) }

# ===========================================================================
# AC1 (done criterion 1; B1) -- state=>paused, non-empty paused_reason ->
# a "  paused <reason>" line, role state.warn, strictly after the run's own
# row and strictly before its current-package line.
# ===========================================================================
{
    my $reason = 'nonce-ac1-reason-9f3a';
    my $s = mk_run(blueprint => 'bp-ac1', state => 'paused', paused_reason => $reason,
                    current_package => 'ac1-current-pkg-marker', packages_done => 1, packages_total => 2);

    # RETARGETED by package 01-run-blocks (spec S5.1 table; ruling B/G,
    # Decision 11 C4): _paused_reason_line is removed. The pause words
    # live in the STATE slot of the blueprint line (lines[0]), prefixed by
    # the thread.idle glyph (Decision 11 amends ruling G's title.paused to
    # thread.idle -- identical bytes). PAUSE_WORDS for an unrecognised
    # reason token is the reason verbatim (table row "any other non-empty
    # string").
    my ($spans, $err) = call_block_line0($s, undef);
    ok(!$err, 'AC1: _run_block is callable without dying') or diag("  \$\@ = $err");
    ok(ref($spans) eq 'ARRAY', 'AC1: _run_block returns a blueprint-line spans array for state=>paused with a non-empty reason');
  SKIP: {
        skip('_run_block did not return a spans array', 2) unless ref($spans) eq 'ARRAY';
        my $idle_glyph = Theme::glyph('thread.idle') // '';
        my ($pause_span) = grep { ref($_) eq 'HASH' && defined($_->{text}) && index($_->{text}, $reason) >= 0 } @$spans;
        ok($pause_span, 'AC1: a span carries the reason verbatim');
        is($pause_span->{role}, 'state.warn', 'AC1: that span\'s role is state.warn') if $pause_span;
        my $full = join('', map { $_->{text} // '' } @$spans);
        ok(length($idle_glyph) && index($full, $idle_glyph . ' ' . $reason) >= 0,
            'AC1: the blueprint line contains "<thread.idle glyph> " immediately before the reason, verbatim');
    }

    # The current-package fallback line is now a PACKAGE-kind line of the
    # same block, structurally guaranteed (by the line grammar, S2.3.9) to
    # come strictly after the blueprint line -- so this is checked via
    # _run_summary_lines's row order rather than a panel-text index lookup.
    my ($rows, $rows_err) = (eval { tui::DashboardScreen::_run_summary_lines([$s], undef, 120, undef) }, $@);
    ok(!$rows_err, 'AC1: _run_summary_lines does not die') or diag("  \$\@ = $rows_err");
  SKIP: {
        skip('_run_summary_lines did not return rows', 2) unless ref($rows) eq 'ARRAY';
        my ($row_idx)    = grep { ref($rows->[$_]) eq 'ARRAY' && tui::Frame::spans_text($rows->[$_]) =~ /bp-ac1\b/ } 0 .. $#$rows;
        my ($cur_idx)    = grep { ref($rows->[$_]) eq 'ARRAY' && tui::Frame::spans_text($rows->[$_]) =~ /ac1-current-pkg/ } 0 .. $#$rows;   # cut to 16 columns (2026-11-05)
        ok(defined($row_idx) && defined($cur_idx) && $cur_idx > $row_idx,
            'AC1: the current-package line appears strictly AFTER the blueprint line (same row carries the pause words, so "after the reason" is automatic)');
    }
}

# ===========================================================================
# AC2 (done criterion 1; B2) -- paused_reason omitted/undef -> the STATE
# slot renders "paused" (the undef/empty branch of the pause-words table),
# never a fabricated reason.
# ===========================================================================
{
    for my $variant ('key omitted entirely', 'key present, value undef') {
        my $s = ($variant eq 'key omitted entirely')
            ? mk_run(blueprint => 'bp-ac2', state => 'paused', packages_done => 1, packages_total => 2)
            : mk_run(blueprint => 'bp-ac2', state => 'paused', paused_reason => undef, packages_done => 1, packages_total => 2);

        my ($spans, $err) = call_block_line0($s, undef);
        ok(!$err, "AC2 ($variant): _run_block is callable without dying") or diag("  \$\@ = $err");
      SKIP: {
            skip('no spans', 2) unless ref($spans) eq 'ARRAY';
            my $full = join('', map { $_->{text} // '' } @$spans);
            ok(index($full, 'paused') >= 0, "AC2 ($variant): the STATE slot renders the bare word 'paused'");
            unlike($full, qr/paused\s+\S/, "AC2 ($variant): no fabricated reason text follows 'paused'");
        }
    }
}

# ===========================================================================
# AC3 (done criterion 1; B3) -- paused_reason eq '' -> same as undef ("paused").
# ===========================================================================
{
    my $s = mk_run(blueprint => 'bp-ac3', state => 'paused', paused_reason => '', packages_done => 1, packages_total => 2);
    my ($spans, $err) = call_block_line0($s, undef);
    ok(!$err, 'AC3: _run_block is callable without dying') or diag("  \$\@ = $err");
  SKIP: {
        skip('no spans', 2) unless ref($spans) eq 'ARRAY';
        my $full = join('', map { $_->{text} // '' } @$spans);
        ok(index($full, 'paused') >= 0, "AC3: the STATE slot renders the bare word 'paused'");
        unlike($full, qr/paused\s+\S/, 'AC3: no fabricated reason text follows \'paused\'');
    }
}
# ===========================================================================
# AC4 (done criterion 1; B4) -- any non-'paused' state renders no pause
# glyph/words at all (ruling G: the pause slot gates on state eq 'paused'),
# even with paused_reason set anyway, for every listed state plus one
# unrecognised value.
# ===========================================================================
{
    my $nonce = 'nonce-ac4-should-never-render';
    my $idle_glyph = Theme::glyph('thread.idle') // '';
    for my $st (qw(running idle solo stale parked bogus)) {
        my $s = mk_run(blueprint => "bp-ac4-$st", state => $st, paused_reason => $nonce);
        my ($spans, $err) = call_block_line0($s, undef);
        ok(!$err, "AC4: state=>'$st' -- _run_block is callable without dying") or diag("  \$\@ = $err");
      SKIP: {
            skip('no spans', 2) unless ref($spans) eq 'ARRAY';
            my $full = join('', map { $_->{text} // '' } @$spans);
            unlike($full, qr/\Q$nonce\E/, "AC4: state=>'$st' with a non-empty paused_reason set anyway -- the nonce never renders");
            ok(!(length($idle_glyph) && index($full, $idle_glyph) >= 0),
                "AC4: state=>'$st' -- no pause glyph is emitted");
        }
    }
}

# ===========================================================================
# AC5 (done criterion 2; B5) -- inbox_waiting=>2, triage_waiting=>1 ->
# 2 spans; span0 '/^2 waiting$/' in state.warn/state.crit per state; span1
# '/^, 1 triage$/' in text.muted; roles differ. Also asserted at panel level.
# ===========================================================================
# RETARGETED by package 01-run-blocks (spec S5.1 table, grammar S2.3.1):
# the WAIT/TRIAGE slots now live on the same blueprint line, as
# "G('icon.decisions').' '.n" (role state.crit while paused, else
# state.warn) and "<n> triage" (role text.muted), each gated on n>0.
my $DECISIONS = Theme::glyph('icon.decisions') // '';

{
    for my $case (['running', 'state.warn'], ['paused', 'state.crit']) {
        my ($st, $expect_role) = @$case;
        my $s = mk_run(blueprint => "bp-ac5-$st", state => $st, inbox_waiting => 2, triage_waiting => 1,
                        packages_done => 0, packages_total => 1);
        my ($spans, $err) = call_block_line0($s, undef);
        ok(!$err, "AC5 (state=$st): _run_block does not die") or diag("  \$\@ = $err");
      SKIP: {
            skip('no spans', 4) unless ref($spans) eq 'ARRAY';
            my ($wait_span) = grep { ref($_) eq 'HASH' && defined($_->{text}) && length($DECISIONS) && index($_->{text}, $DECISIONS) == 0 } @$spans;
            ok($wait_span, "AC5 (state=$st): a span carries the WAIT glyph");
            is($wait_span->{text}, $DECISIONS . ' 2', "AC5 (state=$st): WAIT span text is exactly the glyph + ' 2'") if $wait_span;
            is($wait_span->{role}, $expect_role, "AC5 (state=$st): WAIT span role is $expect_role") if $wait_span;
            my ($triage_span) = grep { ref($_) eq 'HASH' && defined($_->{text}) && $_->{text} eq '1 triage' } @$spans;
            ok($triage_span, "AC5 (state=$st): a span is exactly '1 triage'");
            is($triage_span->{role}, 'text.muted', "AC5 (state=$st): TRIAGE span role is text.muted") if $triage_span;
        }

        my $state = base_state(runs => [$s]);
        my $panels = tui::DashboardScreen::panels($state, 120);
        my $bpp = panel_by_title($panels, 'Blueprints');
        ok($bpp, "AC5 (state=$st) precondition: a Blueprints panel exists");
      SKIP: {
            skip('no Blueprints panel', 2) unless $bpp;
            my $joined = join("\n", @{ panel_line_texts($bpp) });
            like($joined, qr/\Q$DECISIONS\E 2/, "AC5 (state=$st): panel-level rendered text contains the WAIT glyph + '2'") if length($DECISIONS);
            like($joined, qr/1 triage/,  "AC5 (state=$st): panel-level rendered text contains '1 triage'");
        }
    }
}

# ===========================================================================
# AC6 (done criterion 2; B6) -- inbox_waiting=>0 (defined, so n=0, WAIT
# gated off since n>0 is false), triage_waiting=>3 -> TRIAGE renders alone,
# text exactly "3 triage" with no WAIT glyph anywhere on the line.
# ===========================================================================
{
    my $s = mk_run(blueprint => 'bp-ac6', state => 'running', inbox_waiting => 0, triage_waiting => 3,
                    packages_done => 0, packages_total => 1);
    my ($spans, $err) = call_block_line0($s, undef);
    ok(!$err, 'AC6: _run_block does not die') or diag("  \$\@ = $err");
  SKIP: {
        skip('no spans', 2) unless ref($spans) eq 'ARRAY';
        my $full = join('', map { $_->{text} // '' } @$spans);
        ok((!length($DECISIONS)) || index($full, $DECISIONS) < 0, 'AC6: no WAIT glyph anywhere on the line (n=0)');
        my ($triage_span) = grep { ref($_) eq 'HASH' && defined($_->{text}) && $_->{text} eq '3 triage' } @$spans;
        ok($triage_span, 'AC6: a span is exactly "3 triage" (no leading glyph/comma/space)');
        is($triage_span->{role}, 'text.muted', 'AC6: that span carries role text.muted') if $triage_span;
    }
}

# ===========================================================================
# AC7 (done criterion 2; B7, non-vacuity pair to AC5/AC6) --
# triage_waiting 0 or absent -> no "triage" substring anywhere on the line
# -- proves the AC5/AC6 detector is not vacuously true.
# ===========================================================================
{
    for my $case (['triage_waiting=>0', { inbox_waiting => 4, triage_waiting => 0 }],
                  ['triage_waiting absent entirely', { inbox_waiting => 4 }]) {
        my ($label, $extra) = @$case;
        my $s = mk_run(blueprint => 'bp-ac7', state => 'running', packages_done => 0, packages_total => 1, %$extra);
        my ($spans, $err) = call_block_line0($s, undef);
        ok(!$err, "AC7 ($label): _run_block does not die") or diag("  \$\@ = $err");
      SKIP: {
            skip('no spans', 2) unless ref($spans) eq 'ARRAY';
            my $full = join('', map { $_->{text} // '' } @$spans);
            ok(length($DECISIONS) && index($full, $DECISIONS . ' 4') >= 0, "AC7 ($label): the WAIT glyph + ' 4' is present");
            unlike($full, qr/triage/, "AC7 ($label): no text contains the substring 'triage'");
        }
    }
}

# ===========================================================================
# AC8 (done criterion 2; B5/B6 fallback interplay) -- inbox_waiting
# absent, escalations_waiting=>5, triage_waiting=>2 -> WAIT falls back to
# escalations_waiting (n=5) and composes with TRIAGE (n=2).
# ===========================================================================
{
    my $s = mk_run(blueprint => 'bp-ac8', state => 'running', escalations_waiting => 5, triage_waiting => 2,
                    packages_done => 0, packages_total => 1);
    my ($spans, $err) = call_block_line0($s, undef);
    ok(!$err, 'AC8: _run_block does not die') or diag("  \$\@ = $err");
  SKIP: {
        skip('no spans', 2) unless ref($spans) eq 'ARRAY';
        my $full = join('', map { $_->{text} // '' } @$spans);
        ok(length($DECISIONS) && index($full, $DECISIONS . ' 5') >= 0, 'AC8: the WAIT glyph + \' 5\' (escalations_waiting fallback) is present');
        ok(index($full, '2 triage') >= 0, 'AC8: "2 triage" is present');
    }
}

# ===========================================================================
# AC9 (done criterion 3; B8) -- THE REGRESSION GUARD.
#
# Golden values below were captured by running the CURRENT, UNMODIFIED
# DashboardScreen.pm (2026-09-08) against these exact fixtures via a
# throwaway Data::Dumper capture script, then transcribed by hand. Fixture A
# has neither new fact present (no paused_reason key, no triage_waiting
# key). Fixture B additionally sets state=>paused with paused_reason still
# absent (proves the new paused-gate introduces no drift on its own).
# Fixture C additionally sets current_package (proves the interleave order
# is unaffected when neither new fact is present).
# ===========================================================================
{
    my $A = mk_run(blueprint => 'bp-golden-a', state => 'running', packages_done => 2, packages_total => 5,
                    running_coordinators => 1, inbox_waiting => 3);
    my $B = mk_run(blueprint => 'bp-golden-b', state => 'paused', packages_done => 1, packages_total => 4,
                    running_coordinators => 0, inbox_waiting => 2);
    my $C = mk_run(blueprint => 'bp-golden-c', state => 'running', packages_done => 3, packages_total => 6,
                    running_coordinators => 2, inbox_waiting => 0, current_package => 'golden-current-pkg');

    # RETARGETED by package 01-run-blocks (spec S5.1 table): the table and
    # _one_run_summary_cells are gone (ruling A). These are no longer
    # "pre-package" captures of the OLD renderer -- they are freshly
    # DERIVED golden text for the NEW block grammar (spec S2.3), built here
    # from Theme::glyph and the grammar's own M()/pad formulas, not copied
    # from any implementation. running_coordinators has nowhere to render
    # without a thread/orchestrator_pid (ruling H: coord only ever appears
    # on a driver line) -- fixtures A/C's running_coordinators is therefore
    # correctly invisible in the new golden text, a real behaviour change
    # from the old table column.
    my $ICON_BP = Theme::glyph('icon.blueprints') // '';
    my $GAUGE_FULL  = Theme::glyph('gauge.full')  // '';
    my $GAUGE_EMPTY = Theme::glyph('gauge.empty') // '';
    my $OK_GLYPH    = Theme::glyph('status.ok')   // '';
    my $IDLE_GLYPH  = Theme::glyph('thread.idle') // '';
    my $meter = sub {
        my ($d, $t) = @_;
        return '' unless $t;
        my $f = ($d == 0) ? 0 : ($d >= $t ? 15 : int(($d * 15 + $t - 1) / $t));
        $f = 14 if $f > 14 && !($d >= $t);
        return ($GAUGE_FULL x $f) . ($GAUGE_EMPTY x (15 - $f));
    };

    # Operator layout (2026-11-05): the meter sits three columns after the
    # blueprint name, whatever the block's other names.
    # Fixture A: one line (blueprint only -- no packages/thread/driver).
    my $GOLDEN_TEXT_A = $ICON_BP . ' bp-golden-a' . (' ' x 3) . $meter->(2, 5) . '  2/5' . '   ' . 'running'
        . '   ' . $DECISIONS . ' 3';

    # Fixture B: one line. paused_reason absent -> PAUSE_WORDS 'paused'.
    my $GOLDEN_TEXT_B = $ICON_BP . ' bp-golden-b' . (' ' x 3) . $meter->(1, 4) . '  1/4' . '   '
        . $IDLE_GLYPH . ' paused' . '   ' . $DECISIONS . ' 2';

    # Fixture C: two lines. inbox_waiting=>0 (defined, n=0) gates WAIT off.
    my $GOLDEN_TEXT_C_L1 = $ICON_BP . ' bp-golden-c' . (' ' x 3) . $meter->(3, 6) . '  3/6' . '   ' . 'running';
    # 2026-11-05 (operator): the dot leads the package row; this legacy
    # current_package-only shape carries no liveness evidence, so it is the
    # muted idle dot, never green; the 18-column name is cut to 16.
    my $GOLDEN_TEXT_C_L2 = '  ' . (Theme::glyph('status.idle') // '') . ' golden-current-' . (Theme::glyph('ellipsis') // '')
        . (' ' x 3) . 'running';

    my ($rows_a, $err_a) = (eval { tui::DashboardScreen::_run_summary_lines([$A], undef, undef, undef) }, $@);
    ok(!$err_a, 'AC9: fixture A -- _run_summary_lines does not die') or diag("  \$\@ = $err_a");
    is(ref($rows_a) eq 'ARRAY' ? tui::Frame::spans_text($rows_a->[0]) : undef, $GOLDEN_TEXT_A,
        'AC9: fixture A -- the rendered blueprint line matches the new grammar\'s derived golden text exactly');

    my ($rows_b, $err_b) = (eval { tui::DashboardScreen::_run_summary_lines([$B], undef, undef, undef) }, $@);
    ok(!$err_b, 'AC9: fixture B -- _run_summary_lines does not die') or diag("  \$\@ = $err_b");
    is(ref($rows_b) eq 'ARRAY' ? tui::Frame::spans_text($rows_b->[0]) : undef, $GOLDEN_TEXT_B,
        'AC9: fixture B -- the rendered blueprint line matches the new grammar\'s derived golden text exactly (the paused-gate introduces no drift beyond the words themselves)');

    my ($rows_c, $err_c) = (eval { tui::DashboardScreen::_run_summary_lines([$C], undef, undef, undef) }, $@);
    ok(!$err_c, 'AC9: fixture C -- _run_summary_lines does not die') or diag("  \$\@ = $err_c");
  SKIP: {
        skip('fixture C rows missing', 2) unless ref($rows_c) eq 'ARRAY' && @$rows_c >= 2;
        is(tui::Frame::spans_text($rows_c->[0]), $GOLDEN_TEXT_C_L1, 'AC9: fixture C -- blueprint line matches derived golden text');
        is(tui::Frame::spans_text($rows_c->[1]), $GOLDEN_TEXT_C_L2, 'AC9: fixture C -- current_package fallback ACTIVE line matches derived golden text (interleave order unaffected)');
    }

    # =======================================================================
    # AC10 (done criterion 3; B8, end-to-end) -- the SAME "neither fact"
    # fixture (A), captured at the panels() layer.
    # =======================================================================
    my $state = base_state(runs => [$A]);
    my $panels = tui::DashboardScreen::panels($state, 120);
    my $bpp = panel_by_title($panels, 'Blueprints');
    ok($bpp, 'AC10 precondition: a Blueprints panel exists');
  SKIP: {
        skip('no Blueprints panel', 1) unless $bpp;
        my ($bpline) = grep { line_text($_) =~ /bp-golden-a/ } @{ $bpp->{lines} };
        is(defined($bpline) ? line_text($bpline) : undef, $GOLDEN_TEXT_A,
            "AC10: panels(\$state,120)'s Blueprints panel line for fixture A matches the same derived golden text as AC9");
    }
}

# ===========================================================================
# AC11 (B9) -- non-ASCII bytes in paused_reason survive verbatim. Explicit
# UTF-8 byte escape, no `use utf8`, matching this suite's convention at
# t/63:644.
# ===========================================================================
{
    my $reason = "Andr\xC3\xA9's escalation";
    my $s = mk_run(blueprint => 'bp-ac11', state => 'paused', paused_reason => $reason);
    my ($spans, $err) = call_block_line0($s, undef);
    ok(!$err, 'AC11: _run_block does not die on a non-ASCII paused_reason') or diag("  \$\@ = $err");
    ok(ref($spans) eq 'ARRAY', 'AC11: _run_block returns a defined spans array for a non-ASCII paused_reason');
  SKIP: {
        skip('no spans returned', 1) unless ref($spans) eq 'ARRAY';
        my $full = join('', map { $_->{text} // '' } @$spans);
        ok(index($full, "Andr\xC3\xA9") >= 0,
            'AC11: the blueprint line contains the literal bytes "Andr\xC3\xA9" verbatim');
    }
}

# ===========================================================================
# AC12 (B10) -- a 500-character paused_reason truncates to exactly the
# first 200 characters.
# ===========================================================================
{
    my $long = ('A' x 200) . ('B' x 300);
    is(length($long), 500, 'AC12 precondition: the fixture reason is exactly 500 characters');
    my $s = mk_run(blueprint => 'bp-ac12', state => 'paused', paused_reason => $long);
    my ($spans, $err) = call_block_line0($s, undef);
    ok(!$err, 'AC12: _run_block is callable without dying') or diag("  \$\@ = $err");
    ok(ref($spans) eq 'ARRAY', 'AC12: _run_block returns a spans array for a 500-char reason');
  SKIP: {
        skip('no spans returned', 3) unless ref($spans) eq 'ARRAY';
        my $full = join('', map { $_->{text} // '' } @$spans);
        my $idle_glyph = Theme::glyph('thread.idle') // '';
        (my $stripped = $full) =~ s/\A.*\Q$idle_glyph\E //s;
        is(length($stripped), 200, 'AC12: the rendered text (minus everything up to and incl. the pause glyph) is exactly 200 characters');
        is($stripped, 'A' x 200, 'AC12: the rendered text (minus the prefix) is exactly the first 200 characters of the input');
        isnt($stripped, $long, 'AC12: the rendered text is NOT the full 500-character input');
    }
}

# ===========================================================================
# AC13 (B11) -- an embedded "\n" and, separately, an embedded "\x01" survive
# verbatim; no die, no warning.
# ===========================================================================
{
    for my $case (['embedded newline', "line one\nline two nonce-ac13-nl"],
                  ['embedded control byte 0x01', "before\x01after nonce-ac13-ctrl"]) {
        my ($label, $reason) = @$case;
        my $s = mk_run(blueprint => 'bp-ac13', state => 'paused', paused_reason => $reason);
        my @warns;
        my $spans;
        my $err;
        {
            local $SIG{__WARN__} = sub { push @warns, $_[0] };
            $spans = eval { blueprint_line_spans($s, undef) };
            $err = $@;
        }
        ok(!$err, "AC13 ($label): _run_block does not die") or diag("  \$\@ = $err");
        ok(!@warns, "AC13 ($label): _run_block does not warn") or diag('  warned: ' . join('; ', @warns));
        ok(ref($spans) eq 'ARRAY', "AC13 ($label): _run_block returns a spans array");
      SKIP: {
            skip('no spans returned', 1) unless ref($spans) eq 'ARRAY';
            my $full = join('', map { $_->{text} // '' } @$spans);
            ok(index($full, $reason) >= 0, "AC13 ($label): the raw byte(s) are present verbatim in the blueprint line text");
        }
    }
}

# ===========================================================================
# AC14 (B12) -- at a narrow width, the paused-reason line WRAPS rather than
# being truncated or dropped. Tested at two levels: directly against
# tui::Frame::wrap_line (the SAME mechanism _current_package_line already
# relies on, per t/77's own precedent for this exact API) on the span
# _paused_reason_line produces, and end-to-end through
# Dashboard::compose_frame at a narrow terminal width.
#
# INTERPRETATION NOTE (see report): the spec text says "Render the
# Blueprints panel (panels($state, $cols))... reassembled across however
# many lines the panel produced". panels() itself returns PRE-WRAP logical
# lines (SS2.1.2 of the spec states wrapping happens downstream, in
# Dashboard::compose_frame via tui::Frame::wrap_line) -- panels() output
# does not vary in line COUNT with $cols for a standalone spans-line, only
# the table columns' widths do. Wrapping is therefore only observable via
# Dashboard::compose_frame, which is what both checks below actually use;
# panels() is not sufficient to test this behavior on its own.
# ===========================================================================
{
    # Ruling AT-1 (driver, 2026-09-08): fixture bounded to 14 words / 172 chars.
    # It was 40 words / 510 chars, which AC12's mandated substr($reason,0,200)
    # truncates to ~word 16 BEFORE wrap_line ever sees it -- making "all 40 words
    # recoverable" unsatisfiable by any correct implementation. AC14 tests WRAPPING;
    # AC12 (tests 74-78) already tests truncation. Kept long enough to wrap at w=40.
    my $words = join(' ', map { "reasonword$_" } 1 .. 14);
    my $s = mk_run(blueprint => 'bp-ac14', state => 'paused', paused_reason => $words);
    # RETARGETED by package 01-run-blocks: _paused_reason_line/wrap_line is
    # replaced by _run_block/_wrap_block_row (spec S2.4) -- the block's own
    # `hang` (not a literal 2) is what a wrapped continuation indents by.
    my $block = eval { tui::DashboardScreen::_run_block($s, undef, undef) };
    my $err = $@;
    ok(!$err, 'AC14 precondition: _run_block is callable without dying') or diag("  \$\@ = $err");
    my $line0 = (ref($block) eq 'HASH' && ref($block->{lines}) eq 'ARRAY') ? $block->{lines}[0] : undef;
    ok(ref($line0) eq 'HASH' && ref($line0->{spans}) eq 'ARRAY',
        'AC14 precondition: _run_block returns a usable blueprint-line spans array for a long, many-word reason');
  SKIP: {
        skip('no line to wrap', 3) unless ref($line0) eq 'HASH' && ref($line0->{spans}) eq 'ARRAY';
        require tui::Frame;
        my $w = 40;
        my $cells = eval { tui::DashboardScreen::_wrap_block_row($line0->{spans}, $w, $block->{hang}) };
        ok(!$@, 'AC14/_wrap_block_row: does not die wrapping the blueprint line at width 40') or diag("  \$\@ = $@");
      SKIP: {
            skip('_wrap_block_row died', 2) unless !$@;
            cmp_ok(scalar(@$cells), '>', 1, 'AC14/_wrap_block_row: the blueprint line wraps into MORE THAN ONE physical row at width 40 (not truncated to one line)');
            my $joined = join(' ', map { tui::Frame::spans_text($_) } @$cells);
            my @found = ($joined =~ /reasonword(\d+)/g);
            is_deeply(\@found, [1 .. 14],
                'AC14/_wrap_block_row: reconstructing every wrapped row recovers every original word, in order, none dropped or duplicated');
        }
    }
}
{
    # Ruling AT-1: bounded to 18 words / 170 chars, same reason as above.
    my $words = join(' ', map { "acfwrap$_" } 1 .. 18);
    my $s = mk_run(blueprint => 'bp-ac14b', state => 'paused', paused_reason => $words, packages_done => 0, packages_total => 1);
    my $state = base_state(runs => [$s]);
    # Ruling AT-1: rows raised 30 -> 80. AC14's variable is WIDTH (cols=40, unchanged);
    # at 30 rows the frame height budget clipped the last wrapped line, so the test
    # was failing on vertical space rather than on the wrap behaviour it asserts.
    my $frame = Dashboard::compose_frame($state, 80, 40);
    my $t = frame_text($frame);
    my @found = ($t =~ /acfwrap(\d+)/g);
    is_deeply(\@found, [1 .. 18],
        'AC14/compose_frame: at cols=40 the full reason survives across the rendered frame, every word present, in order, none dropped or duplicated');
    my @lines_with_words = grep { /acfwrap/ } split /\n/, $t;
    cmp_ok(scalar(@lines_with_words), '>', 1,
        'AC14/compose_frame: the reason spans MORE THAN ONE rendered terminal line at cols=40 (wrapped, not dropped/truncated-to-one-line)');
}

# ===========================================================================
# AC15 (B13) -- 3 runs (A paused-with-reason, B triage>0, C neither): each
# run's own facts render only under its own row; nothing leaks.
# ===========================================================================
{
    my $nonceA = 'nonce-ac15-runA-reason-x7q';
    my $runA = mk_run(blueprint => 'bp-ac15-a', state => 'paused', paused_reason => $nonceA, packages_done => 1, packages_total => 3);
    my $runB = mk_run(blueprint => 'bp-ac15-b', state => 'running', triage_waiting => 1, packages_done => 2, packages_total => 4);
    my $runC = mk_run(blueprint => 'bp-ac15-c', state => 'idle', packages_done => 0, packages_total => 1);

    my $state = base_state(runs => [$runA, $runB, $runC]);
    my $panels = tui::DashboardScreen::panels($state, 120);
    my $bpp = panel_by_title($panels, 'Blueprints');
    ok($bpp, 'AC15 precondition: a Blueprints panel exists');
  SKIP: {
        skip('no Blueprints panel', 7) unless $bpp;
        my $texts = panel_line_texts($bpp);
        my $joined_all = join("\n", @$texts);

        my $count_nonce  = () = $joined_all =~ /\Q$nonceA\E/g;
        is($count_nonce, 1, 'AC15: run A\'s nonce appears EXACTLY ONCE in the composed panels() output');
        my $count_triage = () = $joined_all =~ /1 triage/g;
        is($count_triage, 1, 'AC15: "1 triage" appears EXACTLY ONCE in the composed panels() output');

        my ($rowA_idx) = grep { $texts->[$_] =~ /bp-ac15-a/ } 0 .. $#$texts;
        my ($rowB_idx) = grep { $texts->[$_] =~ /bp-ac15-b/ } 0 .. $#$texts;
        my ($rowC_idx) = grep { $texts->[$_] =~ /bp-ac15-c/ } 0 .. $#$texts;
        ok(defined($rowA_idx) && defined($rowB_idx) && defined($rowC_idx), 'AC15 precondition: all three runs\' own table rows are found');
      SKIP: {
            skip('a row was not found', 4) unless defined($rowA_idx) && defined($rowB_idx) && defined($rowC_idx);

            # Rulings B/G: the pause reason moves ONTO the blueprint line's
            # own STATE slot (words), so run A's nonce shares run A's own
            # row rather than occupying a separate line beneath it.
            my ($nonce_idx) = grep { $texts->[$_] =~ /\Q$nonceA\E/ } 0 .. $#$texts;
            ok(defined($nonce_idx) && $nonce_idx == $rowA_idx && $nonce_idx < $rowB_idx,
                'AC15: run A\'s nonce renders on run A\'s own blueprint line, before run B\'s row (under its own row only)');

            my ($triage_idx) = grep { $texts->[$_] =~ /1 triage/ } 0 .. $#$texts;
            is($triage_idx, $rowB_idx, 'AC15: "1 triage" sits on run B\'s own table row (not a separate leaked line)');

            is($rowC_idx, $#$texts, 'AC15: run C\'s row is the LAST line (nothing rendered beneath it)');
            my $nothing_after_c = !defined($texts->[$rowC_idx + 1]);
            ok($nothing_after_c, 'AC15: no line follows run C\'s row at all');
        }
    }
}

# ===========================================================================
# AC16 (done criterion 4) -- perl -c exits 0; no byte >= 0x80 and no
# \x{...} escape >= 0x80 anywhere in DashboardScreen.pm.
# ===========================================================================
{
    my $ds_path = File::Spec->rel2abs("$Bin/../../scripts/tui/DashboardScreen.pm");
    ok(-f $ds_path, "AC16 precondition: DashboardScreen.pm exists at $ds_path");
  SKIP: {
        skip('DashboardScreen.pm not found', 3) unless -f $ds_path;
        my $scripts_dir = File::Spec->rel2abs("$Bin/../../scripts");
        my $out = `perl -I "$scripts_dir" -c "$ds_path" 2>&1`;
        my $rc = $? >> 8;
        is($rc, 0, 'AC16: `perl -c` on DashboardScreen.pm exits 0') or diag("  output: $out");

        open(my $fh, '<:raw', $ds_path) or die "cannot open $ds_path: $!";
        local $/;
        my $raw = <$fh>;
        close $fh;

        my @high_bytes = ($raw =~ /([^\x00-\x7f])/g);
        is(scalar(@high_bytes), 0, 'AC16: no byte >= 0x80 appears in DashboardScreen.pm')
            or diag('  found ' . scalar(@high_bytes) . ' high byte(s)');

        my @escapes = ($raw =~ /\\x\{([0-9A-Fa-f]+)\}/g);
        my @bad_escapes = grep { hex($_) >= 0x80 } @escapes;
        is(scalar(@bad_escapes), 0, 'AC16: no \x{...} escape >= 0x80 appears in DashboardScreen.pm')
            or diag('  bad escapes: ' . join(', ', @bad_escapes));
    }
}

done_testing();
