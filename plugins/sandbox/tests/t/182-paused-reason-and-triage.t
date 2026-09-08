#!/usr/bin/env perl
# 182-paused-reason-and-triage.t -- IMMUTABLE ORACLE for package
# 01-paused-reason-and-triage (blueprint agent-telemetry), specs/
# 01-paused-reason-and-triage-spec.md. Derived from the spec's SS4
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
                  running_coordinators decisions_operator decisions_waiting
                  decisions_triage paused_reason current_package)) {
        $s{$k} = $o{$k} if exists $o{$k};
    }
    return \%s;
}

# call_prl($s) -> ($result, $err). Never lets a die escape -- required
# because tui::DashboardScreen::_paused_reason_line does not exist yet at
# the time this oracle is written; an unguarded call would abort the whole
# script rather than fail one assertion. $err is '' on success, so callers
# that expect undef-on-success (e.g. AC2/AC3/AC4) can assert BOTH "no die"
# and "result is undef" -- collapsing those into a single is($result,undef)
# check would let "died, so $result happens to be undef" pass vacuously
# before the sub exists, which is exactly the false-green this suite must
# not produce.
sub call_prl {
    my ($s) = @_;
    my $res = eval { tui::DashboardScreen::_paused_reason_line($s) };
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

    my ($line, $err) = call_prl($s);
    ok(!$err, 'AC1: _paused_reason_line is callable without dying') or diag("  \$\@ = $err");
    ok(ref($line) eq 'ARRAY', 'AC1: _paused_reason_line returns an arrayref for state=>paused with a non-empty reason');
  SKIP: {
        skip('_paused_reason_line did not return an arrayref', 2) unless ref($line) eq 'ARRAY';
        is($line->[0]{text}, '  paused ' . $reason, 'AC1: the span text is the literal "  paused " prefix plus the reason, verbatim');
        is($line->[0]{role}, 'state.warn', 'AC1: the span role is state.warn');
    }

    my $state = base_state(runs => [$s]);
    my $panels = tui::DashboardScreen::panels($state, 120);
    my $bpp = panel_by_title($panels, 'Blueprints');
    ok($bpp, 'AC1 precondition: a Blueprints panel exists');
  SKIP: {
        skip('no Blueprints panel', 4) unless $bpp;
        my $texts = panel_line_texts($bpp);
        my ($row_idx)    = grep { $texts->[$_] =~ /bp-ac1\b/ } 0 .. $#$texts;
        my ($reason_idx) = grep { $texts->[$_] =~ /\Q  paused $reason\E/ } 0 .. $#$texts;
        my ($cur_idx)    = grep { $texts->[$_] =~ /ac1-current-pkg-marker/ } 0 .. $#$texts;
        ok(defined $row_idx, 'AC1: the run\'s own table row is found in the panel');
        ok(defined $reason_idx, 'AC1: a line containing the literal "  paused <reason>" is found in the panel');
      SKIP: {
            skip('a required line was not found', 2) unless defined($row_idx) && defined($reason_idx) && defined($cur_idx);
            ok($reason_idx > $row_idx, 'AC1: the paused-reason line appears strictly AFTER the run\'s own table row');
            ok($reason_idx < $cur_idx, 'AC1: the paused-reason line appears strictly BEFORE the current-package line');
        }
    }
}

# ===========================================================================
# AC2 (done criterion 1; B2) -- paused_reason omitted/undef -> no line.
# ===========================================================================
{
    for my $variant ('key omitted entirely', 'key present, value undef') {
        my $s = ($variant eq 'key omitted entirely')
            ? mk_run(blueprint => 'bp-ac2', state => 'paused', packages_done => 1, packages_total => 2)
            : mk_run(blueprint => 'bp-ac2', state => 'paused', paused_reason => undef, packages_done => 1, packages_total => 2);

        my ($line, $err) = call_prl($s);
        ok(!$err, "AC2 ($variant): _paused_reason_line is callable without dying") or diag("  \$\@ = $err");
        is($line, undef,
            "AC2 ($variant): _paused_reason_line returns undef when paused_reason is absent, state=>paused");

        my $state = base_state(runs => [$s]);
        my $panels = tui::DashboardScreen::panels($state, 120);
        my $bpp = panel_by_title($panels, 'Blueprints');
        ok($bpp, "AC2 ($variant) precondition: a Blueprints panel exists");
      SKIP: {
            skip('no Blueprints panel', 1) unless $bpp;
            my $texts = panel_line_texts($bpp);
            my ($row_idx) = grep { $texts->[$_] =~ /bp-ac2/ } 0 .. $#$texts;
            my $next = defined($row_idx) ? $texts->[$row_idx + 1] : undef;
            my $fabricated = defined($next) && $next =~ /^  paused /;
            ok(!$fabricated, "AC2 ($variant): no fabricated 'paused ...' line follows the run's row");
        }
    }
}

# ===========================================================================
# AC3 (done criterion 1; B3) -- paused_reason eq '' -> no line, same as undef.
# ===========================================================================
{
    my $s = mk_run(blueprint => 'bp-ac3', state => 'paused', paused_reason => '', packages_done => 1, packages_total => 2);
    my ($line, $err) = call_prl($s);
    ok(!$err, 'AC3: _paused_reason_line is callable without dying') or diag("  \$\@ = $err");
    is($line, undef,
        "AC3: _paused_reason_line returns undef when paused_reason is the empty string, state=>paused");

    my $state = base_state(runs => [$s]);
    my $panels = tui::DashboardScreen::panels($state, 120);
    my $bpp = panel_by_title($panels, 'Blueprints');
    ok($bpp, 'AC3 precondition: a Blueprints panel exists');
  SKIP: {
        skip('no Blueprints panel', 1) unless $bpp;
        my $texts = panel_line_texts($bpp);
        my ($row_idx) = grep { $texts->[$_] =~ /bp-ac3/ } 0 .. $#$texts;
        my $next = defined($row_idx) ? $texts->[$row_idx + 1] : undef;
        my $fabricated = defined($next) && $next =~ /^  paused /;
        ok(!$fabricated, "AC3: no fabricated 'paused ...' line follows the run's row");
    }
}

# ===========================================================================
# AC4 (done criterion 1; B4) -- any non-'paused' state, reason set anyway
# -> no line, for every listed state plus one unrecognised value.
# ===========================================================================
{
    my $nonce = 'nonce-ac4-should-never-render';
    for my $st (qw(running idle solo stale parked bogus)) {
        my $s = mk_run(blueprint => "bp-ac4-$st", state => $st, paused_reason => $nonce);
        my ($line, $err) = call_prl($s);
        ok(!$err, "AC4: state=>'$st' -- _paused_reason_line is callable without dying") or diag("  \$\@ = $err");
        is($line, undef,
            "AC4: state=>'$st' with a non-empty paused_reason set anyway -- _paused_reason_line returns undef");
    }
}

# ===========================================================================
# AC5 (done criterion 2; B5) -- decisions_operator=>2, decisions_triage=>1 ->
# 2 spans; span0 '/^2 waiting$/' in state.warn/state.crit per state; span1
# '/^, 1 triage$/' in text.muted; roles differ. Also asserted at panel level.
# ===========================================================================
{
    for my $case (['running', 'state.warn'], ['paused', 'state.crit']) {
        my ($st, $expect_role0) = @$case;
        my $s = mk_run(blueprint => "bp-ac5-$st", state => $st, decisions_operator => 2, decisions_triage => 1,
                        packages_done => 0, packages_total => 1);
        my $cells = tui::DashboardScreen::_one_run_summary_cells($s);
        my $cell = $cells->[4];
        is(scalar(@$cell), 2, "AC5 (state=$st): cell index 4 has exactly 2 spans");
      SKIP: {
            skip('cell did not have 2 spans', 5) unless scalar(@$cell) == 2;
            like($cell->[0]{text}, qr/^2 waiting$/, "AC5 (state=$st): span0 text matches /^2 waiting\$/");
            is($cell->[0]{role}, $expect_role0, "AC5 (state=$st): span0 role is $expect_role0");
            like($cell->[1]{text}, qr/^, 1 triage$/, "AC5 (state=$st): span1 text matches /^, 1 triage\$/");
            is($cell->[1]{role}, 'text.muted', "AC5 (state=$st): span1 role is text.muted");
            isnt($cell->[0]{role}, $cell->[1]{role}, "AC5 (state=$st): the two spans' roles differ");
        }

        my $state = base_state(runs => [$s]);
        my $panels = tui::DashboardScreen::panels($state, 120);
        my $bpp = panel_by_title($panels, 'Blueprints');
        ok($bpp, "AC5 (state=$st) precondition: a Blueprints panel exists");
      SKIP: {
            skip('no Blueprints panel', 2) unless $bpp;
            my $joined = join("\n", @{ panel_line_texts($bpp) });
            like($joined, qr/2 waiting/, "AC5 (state=$st): panel-level rendered text contains '2 waiting'");
            like($joined, qr/1 triage/,  "AC5 (state=$st): panel-level rendered text contains '1 triage'");
        }
    }
}

# ===========================================================================
# AC6 (done criterion 2; B6) -- decisions_operator=>0, decisions_triage=>3 ->
# 2 spans, joined text exactly "3 triage" (no leading comma/space).
# ===========================================================================
{
    my $s = mk_run(blueprint => 'bp-ac6', state => 'running', decisions_operator => 0, decisions_triage => 3,
                    packages_done => 0, packages_total => 1);
    my $cell = tui::DashboardScreen::_one_run_summary_cells($s)->[4];
    is(scalar(@$cell), 2, 'AC6: cell index 4 has exactly 2 spans');
  SKIP: {
        skip('cell did not have 2 spans', 2) unless scalar(@$cell) == 2;
        my $joined = join('', map { $_->{text} } @$cell);
        is($joined, '3 triage', 'AC6: joined cell text is exactly "3 triage" (no leading ", ", no leading space)');
        is($cell->[1]{role}, 'text.muted', 'AC6: the (non-empty) second span carries role text.muted');
    }
}

# ===========================================================================
# AC7 (done criterion 2; B7, non-vacuity pair to AC5/AC6) --
# decisions_triage 0 or absent -> exactly 1 span, "N waiting", no "triage"
# substring anywhere -- proves the AC5/AC6 detector is not vacuously true.
# ===========================================================================
{
    for my $case (['decisions_triage=>0', { decisions_operator => 4, decisions_triage => 0 }],
                  ['decisions_triage absent entirely', { decisions_operator => 4 }]) {
        my ($label, $extra) = @$case;
        my $s = mk_run(blueprint => 'bp-ac7', state => 'running', packages_done => 0, packages_total => 1, %$extra);
        my $cell = tui::DashboardScreen::_one_run_summary_cells($s)->[4];
        is(scalar(@$cell), 1, "AC7 ($label): cell index 4 has exactly 1 span");
      SKIP: {
            skip('cell did not have exactly 1 span', 2) unless scalar(@$cell) == 1;
            is($cell->[0]{text}, '4 waiting', "AC7 ($label): the single span's text is '4 waiting'");
            my @triage_hits = grep { defined($_->{text}) && $_->{text} =~ /triage/ } @$cell;
            is(scalar(@triage_hits), 0, "AC7 ($label): no span text contains the substring 'triage'");
        }
    }
}

# ===========================================================================
# AC8 (done criterion 2; B5/B6 fallback interplay) -- decisions_operator
# absent, decisions_waiting=>5, decisions_triage=>2 -> joined text is exactly
# "5 waiting, 2 triage" (the pre-existing operator->waiting fallback composes
# correctly with the new triage span).
# ===========================================================================
{
    my $s = mk_run(blueprint => 'bp-ac8', state => 'running', decisions_waiting => 5, decisions_triage => 2,
                    packages_done => 0, packages_total => 1);
    my $cell = tui::DashboardScreen::_one_run_summary_cells($s)->[4];
    my $joined = join('', map { $_->{text} } @$cell);
    is($joined, '5 waiting, 2 triage', 'AC8: joined cell text is exactly "5 waiting, 2 triage"');
}

# ===========================================================================
# AC9 (done criterion 3; B8) -- THE REGRESSION GUARD.
#
# Golden values below were captured by running the CURRENT, UNMODIFIED
# DashboardScreen.pm (2026-09-08) against these exact fixtures via a
# throwaway Data::Dumper capture script, then transcribed by hand. Fixture A
# has neither new fact present (no paused_reason key, no decisions_triage
# key). Fixture B additionally sets state=>paused with paused_reason still
# absent (proves the new paused-gate introduces no drift on its own).
# Fixture C additionally sets current_package (proves the interleave order
# is unaffected when neither new fact is present).
# ===========================================================================
{
    my $A = mk_run(blueprint => 'bp-golden-a', state => 'running', packages_done => 2, packages_total => 5,
                    running_coordinators => 1, decisions_operator => 3);
    my $B = mk_run(blueprint => 'bp-golden-b', state => 'paused', packages_done => 1, packages_total => 4,
                    running_coordinators => 0, decisions_operator => 2);
    my $C = mk_run(blueprint => 'bp-golden-c', state => 'running', packages_done => 3, packages_total => 6,
                    running_coordinators => 2, decisions_operator => 0, current_package => 'golden-current-pkg');

    my $GOLDEN_CELLS_A = [
        [ { role => 'accent',       text => 'bp-golden-a' } ],
        [ { role => 'state.ok',     text => 'running' } ],
        [ { role => 'text.primary', text => '2/5 pkg' } ],
        [ { role => 'accent',       text => '1 coord' } ],
        [ { role => 'state.warn',   text => '3 waiting' } ],
    ];
    my $GOLDEN_CELLS_B = [
        [ { role => 'accent',       text => 'bp-golden-b' } ],
        [ { role => 'state.warn',   text => 'paused' } ],
        [ { role => 'text.primary', text => '1/4 pkg' } ],
        [ { role => 'accent',       text => '' } ],
        [ { role => 'state.crit',   text => '2 waiting' } ],
    ];
    my $GOLDEN_CELLS_C = [
        [ { role => 'accent',       text => 'bp-golden-c' } ],
        [ { role => 'state.ok',     text => 'running' } ],
        [ { role => 'text.primary', text => '3/6 pkg' } ],
        [ { role => 'accent',       text => '2 coord' } ],
        [ { role => 'state.warn',   text => '' } ],
    ];

    is_deeply(tui::DashboardScreen::_one_run_summary_cells($A), $GOLDEN_CELLS_A,
        'AC9: fixture A (neither new fact present) -- _one_run_summary_cells is byte-identical to the pre-package golden capture');
    is_deeply(tui::DashboardScreen::_one_run_summary_cells($B), $GOLDEN_CELLS_B,
        'AC9: fixture B (state=>paused, no paused_reason) -- _one_run_summary_cells is byte-identical to the pre-package golden capture');
    is_deeply(tui::DashboardScreen::_one_run_summary_cells($C), $GOLDEN_CELLS_C,
        'AC9: fixture C (current_package set) -- _one_run_summary_cells is byte-identical to the pre-package golden capture');

    my $GOLDEN_LINES_A = [
        [
            { role => 'accent',       text => 'bp-golden-a' },
            { role => 'text.primary', text => '  ' },
            { role => 'state.ok',     text => 'running' },
            { role => 'text.primary', text => '  ' },
            { role => 'text.primary', text => '2/5 pkg' },
            { role => 'text.primary', text => '  ' },
            { role => 'accent',       text => '1 coord' },
            { role => 'text.primary', text => '  ' },
            { role => 'state.warn',   text => '3 waiting' },
        ],
    ];
    my $GOLDEN_LINES_B = [
        [
            { role => 'accent',       text => 'bp-golden-b' },
            { role => 'text.primary', text => '  ' },
            { role => 'state.warn',   text => 'paused' },
            { role => 'text.primary', text => '  ' },
            { role => 'text.primary', text => '1/4 pkg' },
            { role => 'text.primary', text => '  ' },
            { role => 'state.crit',   text => '2 waiting' },
        ],
    ];
    my $GOLDEN_LINES_C = [
        [
            { role => 'accent',       text => 'bp-golden-c' },
            { role => 'text.primary', text => '  ' },
            { role => 'state.ok',     text => 'running' },
            { role => 'text.primary', text => '  ' },
            { role => 'text.primary', text => '3/6 pkg' },
            { role => 'text.primary', text => '  ' },
            { role => 'accent',       text => '2 coord' },
        ],
        [
            { role => 'text.primary', text => '  cur golden-current-pkg' },
        ],
    ];

    is_deeply(tui::DashboardScreen::_run_summary_lines([$A], undef, 120), $GOLDEN_LINES_A,
        'AC9: fixture A -- _run_summary_lines is byte-identical to the pre-package golden capture');
    is_deeply(tui::DashboardScreen::_run_summary_lines([$B], undef, 120), $GOLDEN_LINES_B,
        'AC9: fixture B -- _run_summary_lines is byte-identical to the pre-package golden capture (the new paused-gate introduces no drift)');
    is_deeply(tui::DashboardScreen::_run_summary_lines([$C], undef, 120), $GOLDEN_LINES_C,
        'AC9: fixture C -- _run_summary_lines is byte-identical to the pre-package golden capture (interleave order is unaffected)');

    # =======================================================================
    # AC10 (done criterion 3; B8, end-to-end) -- the SAME "neither fact"
    # fixture (A), captured at the panels() layer.
    # =======================================================================
    my $GOLDEN_PANELS_LINES_A = [
        [
            { role => 'accent',       text => 'bp-golden-a' },
            { role => 'text.primary', text => '  ' },
            { role => 'state.ok',     text => 'running' },
            { role => 'text.primary', text => '  ' },
            { role => 'text.primary', text => '2/5 pkg' },
            { role => 'text.primary', text => '  ' },
            { role => 'accent',       text => '1 coord' },
            { role => 'text.primary', text => '  ' },
            { role => 'state.warn',   text => '3 waiting' },
        ],
    ];
    my $state = base_state(runs => [$A]);
    my $panels = tui::DashboardScreen::panels($state, 120);
    my $bpp = panel_by_title($panels, 'Blueprints');
    ok($bpp, 'AC10 precondition: a Blueprints panel exists');
  SKIP: {
        skip('no Blueprints panel', 1) unless $bpp;
        is_deeply($bpp->{lines}, $GOLDEN_PANELS_LINES_A,
            "AC10: panels(\$state,120)'s Blueprints panel's lines are byte-identical to the pre-package golden capture (fixture A, neither fact present)");
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
    my $line = eval { tui::DashboardScreen::_paused_reason_line($s) };
    ok(!$@, 'AC11: _paused_reason_line does not die on a non-ASCII paused_reason') or diag("  \$\@ = $@");
    ok(ref($line) eq 'ARRAY', 'AC11: _paused_reason_line returns a defined arrayref for a non-ASCII paused_reason');
  SKIP: {
        skip('no line returned', 1) unless ref($line) eq 'ARRAY';
        ok(index($line->[0]{text}, "Andr\xC3\xA9") >= 0,
            'AC11: the span text contains the literal bytes "Andr\xC3\xA9" verbatim');
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
    my ($line, $err) = call_prl($s);
    ok(!$err, 'AC12: _paused_reason_line is callable without dying') or diag("  \$\@ = $err");
    ok(ref($line) eq 'ARRAY', 'AC12: _paused_reason_line returns an arrayref for a 500-char reason');
  SKIP: {
        skip('no line returned', 3) unless ref($line) eq 'ARRAY';
        (my $stripped = $line->[0]{text}) =~ s/^  paused //;
        is(length($stripped), 200, 'AC12: the rendered text (minus the "  paused " prefix) is exactly 200 characters');
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
        my $line;
        {
            local $SIG{__WARN__} = sub { push @warns, $_[0] };
            $line = eval { tui::DashboardScreen::_paused_reason_line($s) };
        }
        ok(!$@, "AC13 ($label): _paused_reason_line does not die") or diag("  \$\@ = $@");
        ok(!@warns, "AC13 ($label): _paused_reason_line does not warn") or diag('  warned: ' . join('; ', @warns));
        ok(ref($line) eq 'ARRAY', "AC13 ($label): _paused_reason_line returns an arrayref");
      SKIP: {
            skip('no line returned', 1) unless ref($line) eq 'ARRAY';
            ok(index($line->[0]{text}, $reason) >= 0, "AC13 ($label): the raw byte(s) are present verbatim in the span text");
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
    my ($line, $err) = call_prl($s);
    ok(!$err, 'AC14 precondition: _paused_reason_line is callable without dying') or diag("  \$\@ = $err");
    ok(ref($line) eq 'ARRAY', 'AC14 precondition: _paused_reason_line returns an arrayref for a long, many-word reason');
  SKIP: {
        skip('no line to wrap', 3) unless ref($line) eq 'ARRAY';
        require tui::Frame;
        my $w = 40;
        my $cells = eval { tui::Frame::wrap_line($line, 'state.warn', $w, 2) };
        ok(!$@, 'AC14/wrap_line: does not die wrapping the paused-reason span at width 40') or diag("  \$\@ = $@");
      SKIP: {
            skip('wrap_line died', 2) unless !$@;
            cmp_ok(scalar(@$cells), '>', 1, 'AC14/wrap_line: the paused-reason span wraps into MORE THAN ONE physical line at width 40 (not truncated to one line)');
            my $joined = join(' ', map { $_->{text} } @$cells);
            my @found = ($joined =~ /reasonword(\d+)/g);
            is_deeply(\@found, [1 .. 14],
                'AC14/wrap_line: reconstructing every wrapped cell recovers every original word, in order, none dropped or duplicated');
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
    my $runB = mk_run(blueprint => 'bp-ac15-b', state => 'running', decisions_triage => 1, packages_done => 2, packages_total => 4);
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

            my ($nonce_idx) = grep { $texts->[$_] =~ /\Q$nonceA\E/ } 0 .. $#$texts;
            ok(defined($nonce_idx) && $nonce_idx > $rowA_idx && $nonce_idx < $rowB_idx,
                'AC15: run A\'s nonce line sits strictly between run A\'s row and run B\'s row (under its own row only)');

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

# ===========================================================================
# AC17 (done criterion 4) -- 79-providers-panel.t and 63-run-panel-truth.t
# both still exit 0 with no `not ok` lines, run UNMODIFIED. This file does
# not touch either.
# ===========================================================================
{
    for my $name (qw(79-providers-panel.t 63-run-panel-truth.t)) {
        my $path = File::Spec->rel2abs("$Bin/$name");
        ok(-f $path, "AC17 precondition: $path exists");
      SKIP: {
            skip("$path not found", 2) unless -f $path;
            my $out = `perl "$path" 2>&1`;
            my $rc = $? >> 8;
            is($rc, 0, "AC17: $name exits 0 when run standalone") or diag("  tail: " . substr($out, -1500));
            my @notok = ($out =~ /^not ok.*$/mg);
            is(scalar(@notok), 0, "AC17: $name has no 'not ok' lines") or diag('  ' . join("\n  ", @notok));
        }
    }
}

done_testing();
