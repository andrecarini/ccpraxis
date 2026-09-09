#!/usr/bin/env perl
# 187-blueprints-panel-tree.t -- IMMUTABLE ORACLE for package
# 06-blueprints-panel-tree (blueprint agent-telemetry), specs/
# 06-blueprints-panel-tree-spec.md. Written BLIND to any implementation of
# the tree renderer -- none of tui::DashboardScreen::{_tree_now, _tree_lines,
# _orchestrator_line, _package_tree_lines, _agent_row, _agent_live, _elapsed,
# _indent, _bound_display, _judge_marker} exist at the time this file is
# written. Their signatures and pure/total contract (spec S2.2) were read as
# INTERFACE, never as implementation -- there is no implementation to read.
# _run_summary_lines, _one_run_summary_cells, _BLUEPRINT_TABLE_OPTS, panels(),
# Dashboard::compose_frame and Theme::glyph/glyphs already exist and are
# UNCHANGED surface this package extends; calling them is calling shipped,
# tested behaviour, not peeking at 06's own implementation.
#
# RULING AT-12 (write-set amendment): launcher.pl:6082 gains `now => $now,`.
# Until that ships, panels()/compose_frame() driven from real launcher state
# render the clock-free half of the tree only (AC47/AC48 pin this exactly).
# This file's calls that pass `$now` explicitly (direct sub calls, or a
# hand-built $state->{now}) are unaffected by that gap -- they exercise the
# renderer's OWN contract, independent of whether launcher.pl has been
# amended in this checkout.
#
# THE GOLDEN CAPTURES in the "non-running runs are untouched" section (AC8,
# AC9) were taken by running the CURRENT, UNMODIFIED
# plugins/sandbox/scripts/tui/DashboardScreen.pm (2026-09-09) via a throwaway
# Data::Dumper capture script against the CF fixture below with `state` and
# `packages` varied, then transcribed by hand. Do NOT regenerate them from a
# future DashboardScreen.pm -- that would defeat the regression guard they
# exist to be. (_one_run_summary_cells ignores the `packages` key entirely
# today, which is why all nine states and all five `packages` variants below
# collapse to the same golden row modulo the state word/role.)
#
# NON-VACUITY STRATEGY (per this initiative's own hard-won house rule: three
# distinct "green but vacuous" mechanisms already found earlier in this
# blueprint -- a property check passing on a failure sentinel; a fixture
# whose two dispatch types were both blocked by the same interlock; a
# boundary fixture that never reached its boundary):
#   1. Value NONCES (zqx*, nonce-ac*), never label words, wherever a
#      "this text must / must not appear" check could otherwise be tripped
#      by a coincidental substring.
#   2. Every negative assertion (unlike / not-rendered / absent) is paired
#      with either a positive twin on the SAME fixture (its live sibling IS
#      rendered) or a separately-asserted precondition pinning the fixture's
#      shape BEFORE the assertion that depends on it -- explicit at AC10,
#      AC22, AC24, AC26, AC27, AC29, AC33, AC42, AC43, per the spec's own
#      list, and added wherever else a fixture could silently drift.
#   3. Every "is defined / matches a regex / has this length" check is paired
#      with a `ref($v)` guard, because a blessed reference stringifies short,
#      printable and valid UTF-8 -- the spec's own warning (S4 preamble).
#   4. The judge marker ($JUDGE_MARKER, resolved once via Theme::glyph
#      exactly as the renderer must) is used everywhere a marker-prefixed
#      label is compared, rather than a hardcoded character -- so this file
#      does not silently pass by agreeing with itself on a wrong glyph.
#
# INTERPRETATION NOTES (recorded rather than silently resolved):
#   * AC3's "no non-first span text begins with a space-run that would
#     double the indent" is read as: the row's SECOND span (the first
#     non-indent span -- typically a label) must not itself be purely
#     whitespace. A literal "no span after the first may start with a
#     space" reading is unsatisfiable by the spec's OWN grammar: DUR() and
#     the attempt/step clauses are defined to start with two literal spaces
#     as a value-separator, by design (S2.6). The failure mode AC3 exists to
#     catch is Frame.pm's wrap_line() front-walk consuming a SECOND
#     purely-whitespace span as though it were part of the indent -- which
#     is what "would double the indent" describes.
#   * AC19/AC45 ("no fixture in the file") are asserted over a representative
#     set of this file's fixtures (CF, the 40-package fixture, a mixed-role
#     package, a mixed-role run_agents list) collected into one array,
#     rather than literally re-scanning every closure in the file -- an
#     exhaustive AST-level self-scan is out of proportion to what the
#     criterion is protecting against (an attempt number, or a colon,
#     leaking onto an agent row).
#   * AC44's "the tree subs' source names neither [atomic nor fit_spans]" is
#     asserted two ways: structurally over CF's actual rendered spans (no
#     span carries atomic=>1 -- this is the reliable half), and textually
#     over the extracted body of each pinned tree sub by name (best-effort;
#     each such check carries its own "sub exists" precondition so a missing
#     sub reads as a failing precondition, never a silent 0-assertions
#     no-op).
#
# Do NOT weaken an assertion here to make a future implementation's life
# easier.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec ();
use Storable qw(dclone);
use Encode ();

my $SCRIPTS = File::Spec->rel2abs("$Bin/../../scripts");
# fix-batch (H3, red-team): this used to be a hardcoded absolute clone path,
# so after promotion the file silently loaded DashboardScreen.pm/Theme.pm
# from the DEVELOPMENT CLONE rather than from the live install under test --
# a green run that proved nothing about the code actually being exercised --
# and it could not run at all outside this one host directory.
#
# `use lib $SCRIPTS` (the $SCRIPTS computed just above, already used at
# AC49's perl -I "$SCRIPTS" -c shell-out) does NOT work here: `use` runs at
# COMPILE time, before the ordinary `my $SCRIPTS = ...` assignment above it
# has RUN (that only happens at runtime, after the whole file compiles), so
# `use lib $SCRIPTS` sees an empty compile-time value and dies ("Empty
# compile time value given to use lib"). $Bin itself, from FindBin, IS
# already populated at compile time (FindBin's own import runs in a BEGIN
# block), so every sibling oracle uses it directly: `use lib
# "$Bin/../../scripts";` (t/186:77, t/182:33, t/66:82). Matching that form
# here, rather than $SCRIPTS, is what actually works.
use lib "$Bin/../../scripts";

require Dashboard;
require tui::DashboardScreen;
require Theme;

my $NOW = 1_800_000_000;

# JUDGE_MARKER: resolved exactly as the renderer must (Theme::glyph), never
# hardcoded. Empty string today (status.judge does not exist yet in
# Theme.pm) -- every check below that depends on a non-empty marker carries
# its own precondition guard so this is never silently vacuous.
my $JUDGE_MARKER = Theme::glyph('status.judge');
$JUDGE_MARKER = '' unless defined $JUDGE_MARKER;

# ===========================================================================
# Scaffolding
# ===========================================================================

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

sub deep { return dclone($_[0]) }

# CF() -- the canonical fixture (spec S3.1), rebuilt fresh on every call so
# no test can leak mutation into another's fixture.
sub CF {
    return {
        blueprint => 'agent-telemetry', state => 'running',
        packages_done => 3, packages_total => 9, running_coordinators => 2,
        decisions_waiting => 1, decisions_operator => 1, decisions_triage => 0,
        current_package => undef, paused_manual => 0, paused_reason => undef,
        orchestrator_pid => 4242, orchestrator_alive => 1,
        orchestrator_started_at => $NOW - 8040,
        packages => [
            { name => '04-agent-records', status => 'running', attempt => 2, attempt_cap => 5,
              step => '4/8', steps_pending => [4,5,6,7,8], next_action => 'x', agents => [
                { id=>'c1', role=>'coordinator', worker_type=>undef,
                  started_at=>$NOW-1860, budget_seconds=>7200, stale_after_seconds=>28800 },
                { id=>'w1', role=>'worker', worker_type=>'bp-implementer',
                  started_at=>$NOW-720,  budget_seconds=>1800, stale_after_seconds=>7200 },
                { id=>'j1', role=>'judge', worker_type=>'bp-resolve-judge',
                  started_at=>$NOW-480,  budget_seconds=>1800, stale_after_seconds=>7200 } ] },
            { name => '05-runstate-agg', status => 'running', attempt => 1, attempt_cap => 5,
              step => '6/8', steps_pending => [6,7,8], next_action => undef, agents => [] },
            { name => '06-panel', status => 'queued', attempt => undef, attempt_cap => undef,
              step => undef, steps_pending => undef, next_action => undef, agents => [] } ],
        run_agents => [
            { id=>'j2', role=>'judge', worker_type=>'bp-conformance-judge',
              started_at=>$NOW-120, budget_seconds=>1800, stale_after_seconds=>7200 } ],
    };
}

# many_pkg_fixture() -- 40 in-flight packages x 6 live agents each (AC3, AC19,
# AC40, AC45). Field names taken from CF, not invented.
sub many_pkg_fixture {
    my @packages;
    for my $i (1 .. 40) {
        my $name = sprintf('pkg-ac40-%02d', $i);
        my @agents = (
            { id=>"$name-c1", role=>'coordinator', worker_type=>undef,   started_at=>$NOW-100, stale_after_seconds=>7200 },
            { id=>"$name-w1", role=>'worker',      worker_type=>'wt1',   started_at=>$NOW-100, stale_after_seconds=>7200 },
            { id=>"$name-w2", role=>'worker',      worker_type=>'wt2',   started_at=>$NOW-100, stale_after_seconds=>7200 },
            { id=>"$name-w3", role=>'worker',      worker_type=>'wt3',   started_at=>$NOW-100, stale_after_seconds=>7200 },
            { id=>"$name-j1", role=>'judge',       worker_type=>'jt1',   started_at=>$NOW-100, stale_after_seconds=>7200 },
            { id=>"$name-u1", role=>'admiral',     worker_type=>'ut1',   started_at=>$NOW-100, stale_after_seconds=>7200 },
        );
        push @packages, { name => $name, status => 'running', agents => \@agents };
    }
    return { state => 'running', packages => \@packages, run_agents => [] };
}

# call_ds($sub_name, @args) -> (\@results, $err). Symbolic-ref call so an
# undefined sub (every new sub, today) is caught as a normal string error
# rather than aborting the whole file. $err is '' on success.
sub call_ds {
    my ($name, @args) = @_;
    no strict 'refs';
    my @res;
    my $ok = eval { @res = &{"tui::DashboardScreen::$name"}(@args); 1 };
    my $err = $ok ? '' : (defined($@) && length($@) ? $@ : 'unknown error');
    return (\@res, $err);
}
sub call1 {
    my ($name, @args) = @_;
    my ($res, $err) = call_ds($name, @args);
    return ($res->[0], $err);
}

# row_text($row) -> concatenated text of every span's {text}, defensively.
sub row_text {
    my ($row) = @_;
    return '' unless ref($row) eq 'ARRAY';
    return join('', map {
        (ref($_) eq 'HASH' && defined($_->{text}) && !ref($_->{text})) ? $_->{text} : ''
    } @$row);
}
# row_pair($row) -> [ leading_space_count, concatenated_span_text ] (AC1).
sub row_pair {
    my ($row) = @_;
    my $full = row_text($row);
    my ($lead) = $full =~ /^( *)/;
    $lead = '' unless defined $lead;
    return [ length($lead), $full ];
}
# row_leading($row) -> the leading-space count of the row's FIRST span only
# (used for indent-level checks, distinct from row_pair's whole-text lead).
sub row_leading {
    my ($row) = @_;
    return -1 unless ref($row) eq 'ARRAY' && ref($row->[0]) eq 'HASH';
    my $t = $row->[0]{text};
    return -1 unless defined($t) && !ref($t);
    return length($1) if $t =~ /^( *)\z/;
    return -1;
}

# _comment_stripped($src) -- same shape as t/65's / t/66's own helper (this
# suite's convention: blank whole-line `#` comments before any source scan).
sub _comment_stripped {
    my ($src) = @_;
    return '' unless defined $src;
    return join("\n", map { /^\s*#/ ? '' : $_ } split /\n/, $src, -1);
}

# _balanced_braces / _sub_body -- same shape as t/66-dashboard-screen.t's own
# helper (reused per this suite's convention of reusing proven detector
# shapes rather than inventing weaker ones).
sub _balanced_braces {
    my ($src, $from) = @_;
    my $idx = index($src, '{', $from);
    return undef if $idx < 0;
    my $depth = 0;
    my $i     = $idx;
    my $len   = length($src);
    for (; $i < $len; $i++) {
        my $c = substr($src, $i, 1);
        if    ($c eq '{') { $depth++; }
        elsif ($c eq '}') { $depth--; last if $depth == 0; }
    }
    return undef if $depth != 0;
    return substr($src, $idx, $i - $idx + 1);
}
sub _sub_body {
    my ($src, $name) = @_;
    while ($src =~ /\bsub\s+\Q$name\E\s*(?:\([^)]*\))?\s*/g) {
        my $after = pos($src);
        return _balanced_braces($src, $after);
    }
    return undef;
}

# _extract_block_between_markers -- same extraction rule as t/64's own
# _extract_generated_block: payload is everything strictly between BEGIN's
# terminating "\n" and the first character of END's line. undef if either
# marker is missing/duplicated/out of order.
sub _extract_block_between_markers {
    my ($text, $begin, $end) = @_;
    return undef unless defined($text) && defined($begin) && defined($end);
    my $b = index($text, $begin);
    return undef if $b < 0;
    my $b2 = index($text, $begin, $b + 1);
    return undef if $b2 >= 0;
    my $e = index($text, $end);
    return undef if $e < 0 || $e < $b;
    my $line_end = index($text, "\n", $b);
    return undef if $line_end < 0;
    my $payload_start = $line_end + 1;
    return substr($text, $payload_start, $e - $payload_start);
}

# base_state / panel_by_title / line_text / panel_line_texts / plain /
# frame_text -- same shape as t/182-paused-reason-and-triage.t's own helpers.
sub base_state {
    my (%o) = @_;
    return { project_name => 'zqxproj187', container => 'zqxctr187', status => 'running', %o };
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
    return '' unless defined $t;
    $t =~ s/\x1b\[[0-9;]*m//g;
    return $t;
}
sub frame_text { my ($f) = @_; return '' unless ref($f) eq 'ARRAY'; return join("\n", map { plain($_) } @$f) }

# run_test_file($rel) -> ($rc, $out) -- run a sibling .t file standalone.
sub run_test_file {
    my ($rel) = @_;
    my $path = File::Spec->rel2abs("$Bin/$rel");
    return (undef, undef) unless -f $path;
    my $out = `perl "$path" 2>&1`;
    my $rc  = $? >> 8;
    return ($rc, $out);
}

# ===========================================================================
# Structure -- Decision 10's exact shape (AC1-AC7)
# ===========================================================================

# --- AC1 (D1) ---------------------------------------------------------
{
    my ($rows, $err) = call1('_run_summary_lines', [ CF() ], undef, 120, $NOW);
    ok(!$err, 'AC1: _run_summary_lines(CF, undef, 120, $NOW) does not die') or diag(" error: $err");
    ok(ref($rows) eq 'ARRAY', 'AC1: returns an arrayref');
  SKIP: {
        skip('not an arrayref', 2) unless ref($rows) eq 'ARRAY';
        cmp_ok(scalar(@$rows), '>=', 9, 'AC1 precondition: at least 9 rows returned (table row + 8 tree rows)')
            or diag(' got ' . scalar(@$rows) . ' rows: ' . join(' | ', map { row_text($_) } @$rows));
      SKIP: {
            skip('fewer than 9 rows', 1) unless @$rows >= 9;
            my @pairs = map { row_pair($_) } @$rows[0 .. 8];
            my $M = $JUDGE_MARKER;
            my @expected = (
                [0, 'agent-telemetry  running  3/9 pkg  2 coord  1 waiting'],
                [2, '  orchestrator  alive  2h14m'],
                [2, '  04-agent-records  attempt 2/5  step 4/8'],
                [4, '    coordinator  31m'],
                [6, '      bp-implementer  12m'],
                [4, '    ' . $M . 'bp-resolve-judge  8m'],
                [2, '  05-runstate-agg  attempt 1/5  step 6/8'],
                [4, '    coordinator'],
                [2, '  ' . $M . 'bp-conformance-judge  2m'],
            );
            is_deeply(\@pairs, \@expected,
                'AC1: rows 0..8 are is_deeply-equal to B1\'s table row + eight-row tree, verbatim, marker taken from Theme::glyph');
        }
    }
}

# --- AC2 (D1) ---------------------------------------------------------
{
    my ($rows, $err) = call1('_run_summary_lines', [ CF() ], undef, 120, $NOW);
    ok(!$err, 'AC2: does not die') or diag(" error: $err");
    is(scalar(@{ $rows || [] }), 9, 'AC2: _run_summary_lines(CF, now) returns EXACTLY 9 rows -- no extra, no missing');
}

# --- AC3 (D1, D8) -------------------------------------------------------
{
    for my $case ([ 'CF', CF() ], [ 'many-package fixture', many_pkg_fixture() ]) {
        my ($label, $s) = @$case;
        my ($rows, $err) = call1('_tree_lines', $s, $NOW);
        ok(!$err, "AC3 ($label): _tree_lines does not die") or diag(" error: $err");
      SKIP: {
            skip('no rows', 2) unless ref($rows) eq 'ARRAY' && @$rows;
            my (@bad_first, @bad_second);
            for my $row (@$rows) {
                my $ftext = (ref($row->[0]) eq 'HASH') ? $row->[0]{text} : undef;
                if (!defined($ftext) || ref($ftext) || $ftext !~ /^(?: {2}| {4}| {6})\z/) {
                    push @bad_first, (defined($ftext) && !ref($ftext)) ? "'$ftext'" : 'undef/ref';
                }
                my $stext = (ref($row->[1]) eq 'HASH') ? $row->[1]{text} : undef;
                if (defined($stext) && !ref($stext) && $stext =~ /^ *\z/) {
                    push @bad_second, "'$stext'";
                }
            }
            is(scalar(@bad_first), 0,
                "AC3 ($label): every row's first span is whitespace-only with length 2, 4 or 6 (n in {1,2,3})")
                or diag(' bad: ' . join(', ', @bad_first));
            is(scalar(@bad_second), 0,
                "AC3 ($label): no row's second span is itself purely whitespace (would double the indent on wrap)")
                or diag(' bad: ' . join(', ', @bad_second));
        }
    }
}

# --- AC4 (D1, D6) -------------------------------------------------------
{
    my ($rows, $err) = call1('_tree_lines', CF(), $NOW);
    ok(!$err, 'AC4: does not die') or diag(" error: $err");
  SKIP: {
        skip('no rows', 1) unless ref($rows) eq 'ARRAY' && @$rows;
        my %expect = (
            'orchestrator'         => 2,
            '04-agent-records'     => 2,
            '05-runstate-agg'      => 2,
            'coordinator'          => 4,
            'bp-resolve-judge'     => 4,
            'bp-implementer'       => 6,
            'bp-conformance-judge' => 2,
        );
        for my $word (sort keys %expect) {
            my ($row) = grep { row_text($_) =~ /\Q$word\E/ } @$rows;
            ok(defined($row), "AC4 precondition: a row mentioning '$word' exists in CF's tree");
          SKIP: {
                skip('row not found', 1) unless defined $row;
                is(row_leading($row), $expect{$word}, "AC4: row '$word' is at indent $expect{$word}");
            }
        }
    }
}

# --- AC5 (D1) ---------------------------------------------------------
{
    my $pkg = { name=>'pkg-ac5', status=>'running', agents=>[
        { id=>'j',  role=>'judge',       worker_type=>'zqxj5',  started_at=>$NOW-100, stale_after_seconds=>7200 },
        { id=>'w1', role=>'worker',      worker_type=>'zqxw5a', started_at=>$NOW-100, stale_after_seconds=>7200 },
        { id=>'c',  role=>'coordinator', worker_type=>undef,    started_at=>$NOW-100, stale_after_seconds=>7200 },
        { id=>'w2', role=>'worker',      worker_type=>'zqxw5b', started_at=>$NOW-100, stale_after_seconds=>7200 },
    ] };
    my ($rows, $err) = call1('_package_tree_lines', $pkg, $NOW);
    ok(!$err, 'AC5: does not die') or diag(" error: $err");
  SKIP: {
        skip('no rows', 1) unless ref($rows) eq 'ARRAY' && @$rows >= 5;
        my @after_pkg = @$rows[1 .. $#$rows];
        my @kind = map {
            my $t = row_text($_);
            $t =~ /^\s*coordinator\b/ ? 'coordinator'
          : $t =~ /zqxw5a/            ? 'worker1'
          : $t =~ /zqxw5b/            ? 'worker2'
          : $t =~ /zqxj5/             ? 'judge'
          :                             '?';
        } @after_pkg;
        is_deeply(\@kind, ['coordinator', 'worker1', 'worker2', 'judge'],
            'AC5: emitted order is coordinator, then workers in original relative order, then judges');
    }
}

# --- AC6 (D1) ---------------------------------------------------------
{
    my ($rows, $err) = call1('_tree_lines', CF(), $NOW);
    ok(!$err, 'AC6: does not die') or diag(" error: $err");
  SKIP: {
        skip('no rows', 1) unless ref($rows) eq 'ARRAY' && @$rows;
        like(row_text($rows->[-1]), qr/bp-conformance-judge/,
            'AC6: run_agents rows appear after ALL package blocks -- CF\'s last row is the conformance-judge row');
    }
}

# --- AC7 (D1) ---------------------------------------------------------
{
    my $cf     = CF();
    my $before = deep($cf);
    my ($r1, $e1) = call1('_tree_lines', $cf, $NOW);
    my ($r2, $e2) = call1('_tree_lines', $cf, $NOW);
    ok(!$e1, 'AC7: first call to _tree_lines does not die') or diag(" error: $e1");
    ok(!$e2, 'AC7: second call to _tree_lines does not die') or diag(" error: $e2");
    is_deeply($r1, $r2, 'AC7: two successive calls return is_deeply-equal results (pure function)');
    is_deeply($cf, $before, 'AC7: CF is unmodified after two calls to _tree_lines -- the renderer mutates nothing it is given');
}

# --- B4 (D1, not independently AC-numbered) -----------------------------
{
    my $s = { state=>'running', orchestrator_alive=>1, orchestrator_started_at=>$NOW-60,
              packages=>[], run_agents=>[] };
    my ($rows, $err) = call1('_tree_lines', $s, $NOW);
    ok(!$err, 'B4: _tree_lines does not die for state=>running, packages=>[], run_agents=>[]') or diag(" error: $err");
    is(scalar(@{ $rows || [] }), 1, 'B4: exactly one tree row -- the orchestrator row, when there is nothing else to draw');
  SKIP: {
        skip('wrong row count', 1) unless ref($rows) eq 'ARRAY' && @$rows == 1;
        like(row_text($rows->[0]), qr/^\s*orchestrator\b/, 'B4: the single row is the orchestrator row');
    }
}

# ===========================================================================
# Non-running runs are untouched (AC8-AC11, D5)
# ===========================================================================

# golden_table_row($word, $state_role, $waiting_role) -- the pre-package
# capture showed the DECISIONS cell ("1 waiting") is ALSO state-dependent
# (state.crit under paused, state.warn everywhere else -- the same
# operator/paused distinction t/182's own AC5 exercises), so that role is a
# parameter too, not a constant, or this golden would be wrong for 'paused'.
sub golden_table_row {
    my ($word, $state_role, $waiting_role) = @_;
    $waiting_role = 'state.warn' unless defined $waiting_role;
    return [
        { role => 'accent',       text => 'agent-telemetry' },
        { role => 'text.primary', text => '  ' },
        { role => $state_role,    text => $word },
        { role => 'text.primary', text => '  ' },
        { role => 'text.primary', text => '3/9 pkg' },
        { role => 'text.primary', text => '  ' },
        { role => 'accent',       text => '2 coord' },
        { role => 'text.primary', text => '  ' },
        { role => $waiting_role,  text => '1 waiting' },
    ];
}

# --- AC8 (D5) ---------------------------------------------------------
{
    my %role_for = (queued=>'text.muted', done=>'text.muted', failed=>'text.muted', idle=>'text.muted',
                     paused=>'state.warn', parked=>'state.warn', stale=>'text.muted', solo=>'text.muted',
                     ''=>'text.muted');
    my %waiting_role_for = map { $_ => 'state.warn' } (qw(queued done failed idle parked stale solo), '');
    $waiting_role_for{paused} = 'state.crit';
    for my $st (qw(queued done failed idle paused parked stale solo), '') {
        my $cf = CF();
        $cf->{state} = $st;
        my ($rows, $err) = call1('_run_summary_lines', [ $cf ], undef, 120);
        ok(!$err, "AC8 (state='$st'): _run_summary_lines does not die") or diag(" error: $err");
        my $word = ($st eq '') ? '?' : $st;
        is_deeply($rows, [ golden_table_row($word, $role_for{$st}, $waiting_role_for{$st}) ],
            "AC8 (state='$st'): output is byte-identical to the pre-package golden capture (no tree row)");
    }
}

# --- AC9 (D5) ---------------------------------------------------------
{
    my $golden = [ golden_table_row('running', 'state.ok', 'state.warn') ];
    my @variants = (
        ['key absent', sub { my $c = CF(); delete $c->{packages}; return $c; }],
        ['undef',      sub { my $c = CF(); $c->{packages} = undef; return $c; }],
        ['{}',         sub { my $c = CF(); $c->{packages} = {};    return $c; }],
        ["'x'",        sub { my $c = CF(); $c->{packages} = 'x';   return $c; }],
        ['\\1',        sub { my $c = CF(); $c->{packages} = \1;    return $c; }],
    );
    for my $v (@variants) {
        my ($label, $build) = @$v;
        my $cf = $build->();
        my ($rows, $err) = call1('_run_summary_lines', [ $cf ], undef, 120);
        ok(!$err, "AC9 (packages=$label): does not die") or diag(" error: $err");
        is_deeply($rows, $golden, "AC9 (packages=$label): output is byte-identical to the pre-package golden capture");
    }
}

# --- AC10 (D5, D8) ------------------------------------------------------
{
    is_deeply(tui::DashboardScreen::_BLUEPRINT_TABLE_OPTS(),
        { gap => 2, align => [qw(left left right right right)], min => [8,4,5,3,3], drop => [undef,undef,undef,2,1] },
        'AC10: _BLUEPRINT_TABLE_OPTS is unchanged -- still 5 columns, same gap/align/min/drop');
    my $cells = tui::DashboardScreen::_one_run_summary_cells(CF());
    is(scalar(@$cells), 5, 'AC10: _one_run_summary_cells returns exactly 5 cells for CF -- no tree fact became a table column');
}

# --- AC11 (D5, D11) ------------------------------------------------------
{
    for my $name (qw(182-paused-reason-and-triage.t 93-blueprints-table.t 94-no-rendered-colons.t
                      63-run-panel-truth.t 73-layout-flex-stability.t 75-wrap-on-overflow.t
                      77-wrap-width-regressions.t 79-providers-panel.t)) {
        my $path = File::Spec->rel2abs("$Bin/$name");
        ok(-f $path, "AC11 precondition: $path exists");
      SKIP: {
            skip("$path not found", 2) unless -f $path;
            my ($rc, $out) = run_test_file($name);
            is($rc, 0, "AC11: $name exits 0 when run standalone, UNMODIFIED by this package") or diag(' tail: ' . substr($out, -1500));
            my @notok = ($out =~ /^not ok.*$/mg);
            is(scalar(@notok), 0, "AC11: $name has no 'not ok' lines") or diag(' ' . join("\n ", @notok));
        }
    }
}

# ===========================================================================
# CF1 -- the orchestrator uptime gate (AC12-AC17)
# ===========================================================================

# --- AC12 (D1) ----------------------------------------------------------
{
    my ($row, $err) = call1('_orchestrator_line', CF(), $NOW);
    ok(!$err, 'AC12: _orchestrator_line does not die for CF') or diag(" error: $err");
    ok(ref($row) eq 'ARRAY', 'AC12: _orchestrator_line returns an arrayref for CF');
  SKIP: {
        skip('no row', 1) unless ref($row) eq 'ARRAY';
        is(row_text($row), '  orchestrator  alive  2h14m', 'AC12: CF orchestrator row text is exactly "  orchestrator  alive  2h14m"');
    }
}

# --- AC13 (D1, CF1) -------------------------------------------------------
{
    my @cases = (
        ['1',      'alive',   sub { my $c=CF(); $c->{orchestrator_alive}=1;     $c }],
        ['0',      'dead',    sub { my $c=CF(); $c->{orchestrator_alive}=0;     $c }],
        ['undef',  'unknown', sub { my $c=CF(); $c->{orchestrator_alive}=undef; $c }],
        ['absent', 'unknown', sub { my $c=CF(); delete $c->{orchestrator_alive}; $c }],
        ["''",     'dead',    sub { my $c=CF(); $c->{orchestrator_alive}='';    $c }],
        ["'yes'",  'alive',   sub { my $c=CF(); $c->{orchestrator_alive}='yes'; $c }],
        ['[]',     'unknown', sub { my $c=CF(); $c->{orchestrator_alive}=[];    $c }],
    );
    for my $c (@cases) {
        my ($label, $word, $build) = @$c;
        my $cf = $build->();
        my ($row, $err) = call1('_orchestrator_line', $cf, $NOW);
        ok(!$err, "AC13 (orchestrator_alive=$label): _orchestrator_line does not die") or diag(" error: $err");
        ok(ref($row) eq 'ARRAY', "AC13 (orchestrator_alive=$label): returns an arrayref");
      SKIP: {
            skip('no row', 2) unless ref($row) eq 'ARRAY';
            my $text = row_text($row);
            like($text, qr/\b\Q$word\E\b/, "AC13 (orchestrator_alive=$label): liveness word is '$word'");
            if ($word eq 'alive') {
                like($text, qr/\d+h\d{2}m|\d+m\b|<1m|\d+d\d{2}h/,
                    "AC13 (orchestrator_alive=$label): a duration-shaped token IS present");
            } else {
                unlike($text, qr/\d+h\d{2}m|\d+m\b|<1m|\d+d\d{2}h/,
                    "AC13 (orchestrator_alive=$label): no duration-shaped token present ($word)");
            }
        }
    }
}

# --- AC14 (CF1) -----------------------------------------------------------
{
    my $cf = CF();
    $cf->{orchestrator_alive}      = undef;
    $cf->{orchestrator_started_at} = $NOW - 2_592_000;
    my ($row, $err) = call1('_orchestrator_line', $cf, $NOW);
    ok(!$err, 'AC14: does not die') or diag(" error: $err");
    ok(ref($row) eq 'ARRAY', 'AC14: returns an arrayref');
  SKIP: {
        skip('no row', 1) unless ref($row) eq 'ARRAY';
        is(row_text($row), '  orchestrator  unknown',
            'AC14: a 30-day-old marker for an unprobeable pid renders NO duration (CF1\'s exact production case)');
    }
}

# --- AC15 (D1) ------------------------------------------------------------
{
    my @cases = (
        ['alive',   'state.ok',   sub { my $c=CF(); $c->{orchestrator_alive}=1;     $c }],
        ['dead',    'state.crit', sub { my $c=CF(); $c->{orchestrator_alive}=0;     $c }],
        ['unknown', 'text.muted', sub { my $c=CF(); $c->{orchestrator_alive}=undef; $c }],
    );
    for my $c (@cases) {
        my ($word, $exp_role, $build) = @$c;
        my $cf = $build->();
        my ($row, $err) = call1('_orchestrator_line', $cf, $NOW);
        ok(!$err, "AC15 ($word): _orchestrator_line does not die") or diag(" error: $err");
      SKIP: {
            skip('no row', 2) unless ref($row) eq 'ARRAY' && @$row >= 3;
            like($row->[2]{text}, qr/\b\Q$word\E\b/, "AC15 ($word) precondition: liveness span text contains the word '$word'");
            is($row->[2]{role}, $exp_role, "AC15 ($word): liveness span role is $exp_role");
        }
    }
}

# --- AC16 (CF3) -----------------------------------------------------------
{
    my $cf = CF();
    $cf->{orchestrator_alive}      = 1;
    $cf->{orchestrator_started_at} = $NOW + 86_400;
    my ($row, $err) = call1('_orchestrator_line', $cf, $NOW);
    ok(!$err, 'AC16: does not die') or diag(" error: $err");
  SKIP: {
        skip('no row', 1) unless ref($row) eq 'ARRAY';
        is(row_text($row), '  orchestrator  alive  <1m',
            'AC16: a future orchestrator_started_at renders "<1m" -- never n/a, never negative');
    }
}

# --- AC17 (CF1, CF3) --------------------------------------------------------
{
    my @variants = (
        ['absent',   sub { my $c=CF(); delete $c->{orchestrator_started_at}; $c }],
        ['undef',    sub { my $c=CF(); $c->{orchestrator_started_at}=undef;  $c }],
        ['0',        sub { my $c=CF(); $c->{orchestrator_started_at}=0;      $c }],
        ['-5',       sub { my $c=CF(); $c->{orchestrator_started_at}=-5;     $c }],
        ["'abc'",    sub { my $c=CF(); $c->{orchestrator_started_at}='abc';  $c }],
        ["'1e9'",    sub { my $c=CF(); $c->{orchestrator_started_at}='1e9';  $c }],
        ['[]',       sub { my $c=CF(); $c->{orchestrator_started_at}=[];     $c }],
        ['1.5',      sub { my $c=CF(); $c->{orchestrator_started_at}=1.5;    $c }],
    );
    for my $v (@variants) {
        my ($label, $build) = @$v;
        my $cf = $build->();
        $cf->{orchestrator_alive} = 1;
        my ($row, $err) = call1('_orchestrator_line', $cf, $NOW);
        ok(!$err, "AC17 (orchestrator_started_at=$label): does not die") or diag(" error: $err");
      SKIP: {
            skip('no row', 1) unless ref($row) eq 'ARRAY';
            is(row_text($row), '  orchestrator  alive',
                "AC17 (orchestrator_started_at=$label): row text is exactly '  orchestrator  alive', no duration");
        }
    }
}

# ===========================================================================
# The package row, and Decision 3 (AC18-AC21)
# ===========================================================================

# --- AC18 (D1) ------------------------------------------------------------
{
    my $pkg = CF()->{packages}[0];
    my ($rows, $err) = call1('_package_tree_lines', $pkg, $NOW);
    ok(!$err, 'AC18: does not die') or diag(" error: $err");
    ok(ref($rows) eq 'ARRAY' && @$rows >= 1, 'AC18: returns a non-empty arrayref for an in-flight package');
  SKIP: {
        skip('no rows', 1) unless ref($rows) eq 'ARRAY' && @$rows;
        is(row_text($rows->[0]), '  04-agent-records  attempt 2/5  step 4/8', 'AC18: CF pkg[0] package row text is exact');
    }
}

# --- AC20 (D2) ------------------------------------------------------------
{
    my @cases = ([2,5,'text.primary'], [5,5,'state.warn'], [7,5,'state.warn'], [0,5,'text.primary']);
    for my $c (@cases) {
        my ($att, $cap, $role) = @$c;
        my $pkg = { name=>'pkg-ac20', status=>'running', attempt=>$att, attempt_cap=>$cap, agents=>[] };
        my ($rows, $err) = call1('_package_tree_lines', $pkg, $NOW);
        ok(!$err, "AC20 (attempt=$att/$cap): does not die") or diag(" error: $err");
      SKIP: {
            skip('no rows', 1) unless ref($rows) eq 'ARRAY' && @$rows;
            ok(scalar(@{ $rows->[0] }) >= 3, "AC20 (attempt=$att/$cap) precondition: the package row has an attempt-clause span");
          SKIP: {
                skip('no attempt span', 2) unless scalar(@{ $rows->[0] }) >= 3;
                is($rows->[0][2]{text}, "  attempt $att/$cap", "AC20 (attempt=$att/$cap): attempt span text");
                is($rows->[0][2]{role}, $role, "AC20 (attempt=$att/$cap): attempt span role is $role");
            }
        }
    }
    my @neg = (
        [2, undef, 'attempt_cap undef'], [undef, 5, 'attempt undef'], [undef, undef, 'both undef'],
        ['a', 5, "attempt='a'"], [2, 'b', "attempt_cap='b'"], [[], 5, 'attempt=[]'],
    );
    for my $n (@neg) {
        my ($att, $cap, $label) = @$n;
        my $pkg = { name=>'pkg-ac20neg', status=>'running', attempt=>$att, attempt_cap=>$cap, agents=>[] };
        my ($rows, $err) = call1('_package_tree_lines', $pkg, $NOW);
        ok(!$err, "AC20 neg ($label): does not die") or diag(" error: $err");
      SKIP: {
            skip('no rows', 1) unless ref($rows) eq 'ARRAY' && @$rows;
            unlike(row_text($rows->[0]), qr/attempt/, "AC20 neg ($label): no attempt clause at all");
        }
    }
}

# --- AC19 (D2) -- placed after AC20 so the "attempt" vocabulary is fresh;
# real assertion executes near end of file once every representative
# fixture has been collected (see AC19/AC45 CUMULATIVE SCAN below). --------

# --- AC21 (D1) ------------------------------------------------------------
{
    my @cases = (
        { label => "'4/8'",         val => '4/8',        present => 1, expect => '4/8' },
        { label => 'undef',         val => undef,         present => 0 },
        { label => "''",            val => '',            present => 0 },
        { label => '[]',            val => [],            present => 0 },
        { label => '40 bytes of x', val => ('x' x 40),    present => 1, expect => ('x' x 32) },
    );
    for my $c (@cases) {
        my $pkg = { name=>'pkg-ac21', status=>'running', attempt=>undef, attempt_cap=>undef, step=>$c->{val}, agents=>[] };
        my ($rows, $err) = call1('_package_tree_lines', $pkg, $NOW);
        ok(!$err, "AC21 (step=$c->{label}): does not die") or diag(" error: $err");
      SKIP: {
            skip('no rows', 1) unless ref($rows) eq 'ARRAY' && @$rows;
            if ($c->{present}) {
                like(row_text($rows->[0]), qr/\Qstep $c->{expect}\E/,
                    "AC21 (step=$c->{label}): step clause present with expected (possibly bounded) text");
            } else {
                unlike(row_text($rows->[0]), qr/step/, "AC21 (step=$c->{label}): no step clause");
            }
        }
    }
}

# ===========================================================================
# CF2 -- staleness, the filter that stops the panel lying (AC22-AC27)
# ===========================================================================

# --- AC22 (D1, CF2) ---------------------------------------------------------
{
    my $nonce3 = 'nonce-ac22-stale-w3-9f2c';
    my $pkg = {
        name => 'pkg-ac22', status => 'running',
        agents => [
            { id=>'w1', role=>'worker', worker_type=>'nonce-ac22-w1', started_at=>$NOW-7199, stale_after_seconds=>7200 },
            { id=>'w2', role=>'worker', worker_type=>'nonce-ac22-w2', started_at=>$NOW-7200, stale_after_seconds=>7200 },
            { id=>'w3', role=>'worker', worker_type=>$nonce3,        started_at=>$NOW-7201, stale_after_seconds=>7200 },
        ],
    };
    is($NOW - $pkg->{agents}[0]{started_at}, 7199, 'AC22 precondition: w1 is exactly 7199s old');
    is($NOW - $pkg->{agents}[1]{started_at}, 7200, 'AC22 precondition: w2 is exactly 7200s old (the boundary itself)');
    is($NOW - $pkg->{agents}[2]{started_at}, 7201, 'AC22 precondition: w3 is exactly 7201s old (one second past)');

    my ($rows, $err) = call1('_package_tree_lines', $pkg, $NOW);
    ok(!$err, 'AC22: does not die') or diag(" error: $err");
  SKIP: {
        skip('no rows', 3) unless ref($rows) eq 'ARRAY';
        my $joined = join("\n", map { row_text($_) } @$rows);
        like($joined, qr/nonce-ac22-w1/, 'AC22: w1 (7199s, within boundary) IS rendered');
        like($joined, qr/nonce-ac22-w2/, 'AC22: w2 (exactly 7200s, boundary itself) IS rendered');
        unlike($joined, qr/\Q$nonce3\E/, 'AC22: w3 (7201s, one second past) is rendered NOWHERE in the output');
    }
}

# --- AC23 (CF2) ------------------------------------------------------------
{
    my @variants = (
        ['absent',  sub { my $a = { id=>'x', role=>'worker', worker_type=>'zqxbad23', started_at=>$NOW-100 }; return $a; }],
        ['undef',   sub { { id=>'x', role=>'worker', worker_type=>'zqxbad23', started_at=>$NOW-100, stale_after_seconds=>undef } }],
        ['0',       sub { { id=>'x', role=>'worker', worker_type=>'zqxbad23', started_at=>$NOW-100, stale_after_seconds=>0 } }],
        ['-1',      sub { { id=>'x', role=>'worker', worker_type=>'zqxbad23', started_at=>$NOW-100, stale_after_seconds=>-1 } }],
        ["'abc'",   sub { { id=>'x', role=>'worker', worker_type=>'zqxbad23', started_at=>$NOW-100, stale_after_seconds=>'abc' } }],
        ['1.5',     sub { { id=>'x', role=>'worker', worker_type=>'zqxbad23', started_at=>$NOW-100, stale_after_seconds=>1.5 } }],
        ['[]',      sub { { id=>'x', role=>'worker', worker_type=>'zqxbad23', started_at=>$NOW-100, stale_after_seconds=>[] } }],
    );
    for my $v (@variants) {
        my ($label, $build) = @$v;
        my $bad     = $build->();
        my $sibling = { id=>'y', role=>'worker', worker_type=>'zqxlive23', started_at=>$NOW-100, stale_after_seconds=>7200 };
        my $pkg     = { name=>'pkg-ac23', status=>'running', agents=>[$bad, $sibling] };
        my ($rows, $err) = call1('_package_tree_lines', $pkg, $NOW);
        ok(!$err, "AC23 (stale_after_seconds=$label): does not die") or diag(" error: $err");
      SKIP: {
            skip('no rows', 2) unless ref($rows) eq 'ARRAY';
            my $joined = join("\n", map { row_text($_) } @$rows);
            unlike($joined, qr/zqxbad23/, "AC23 (stale_after_seconds=$label): the malformed agent is not rendered");
            like($joined, qr/zqxlive23/, "AC23 (stale_after_seconds=$label): its live sibling in the same agents list IS still rendered");
        }
    }
}

# --- AC24 (CF2) ------------------------------------------------------------
{
    my @variants = (
        ['absent', sub { { id=>'x', role=>'worker', worker_type=>'zqxbad24', stale_after_seconds=>7200 } }],
        ['undef',  sub { { id=>'x', role=>'worker', worker_type=>'zqxbad24', started_at=>undef, stale_after_seconds=>7200 } }],
        ['0',      sub { { id=>'x', role=>'worker', worker_type=>'zqxbad24', started_at=>0,      stale_after_seconds=>7200 } }],
        ["'abc'",  sub { { id=>'x', role=>'worker', worker_type=>'zqxbad24', started_at=>'abc',  stale_after_seconds=>7200 } }],
        ['[]',     sub { { id=>'x', role=>'worker', worker_type=>'zqxbad24', started_at=>[],     stale_after_seconds=>7200 } }],
    );
    for my $v (@variants) {
        my ($label, $build) = @$v;
        my $bad     = $build->();
        my $sibling = { id=>'y', role=>'worker', worker_type=>'zqxlive24', started_at=>$NOW-100, stale_after_seconds=>7200 };
        my $pkg     = { name=>'pkg-ac24', status=>'running', agents=>[$bad, $sibling] };
        my ($rows, $err) = call1('_package_tree_lines', $pkg, $NOW);
        ok(!$err, "AC24 (started_at=$label): does not die") or diag(" error: $err");
      SKIP: {
            skip('no rows', 2) unless ref($rows) eq 'ARRAY';
            my $joined = join("\n", map { row_text($_) } @$rows);
            like($joined, qr/zqxlive24/, "AC24 (started_at=$label) precondition: the live sibling IS rendered");
            unlike($joined, qr/zqxbad24/, "AC24 (started_at=$label): the malformed agent is not rendered");
        }
    }
}

# --- AC25 (CF2) ------------------------------------------------------------
{
    my @hostile = (
        ['undef', undef], ["'x'", 'x'], ['[]', []], ["bless({},'X')", bless({}, 'X')], ['{}', {}],
    );
    for my $h (@hostile) {
        my ($label, $val) = @$h;
        my ($res, $err) = call1('_agent_live', $val, $NOW);
        ok(!$err, "AC25 ($label): _agent_live does not die") or diag(" error: $err");
        ok(defined($res), "AC25 ($label): _agent_live's return value is defined (never undef)");
        is($res, 0, "AC25 ($label): _agent_live returns exactly 0");
    }
    my $well = { id=>'z', role=>'worker', worker_type=>'x', started_at=>$NOW-100, stale_after_seconds=>7200 };
    my ($res_u, $err_u) = call1('_agent_live', $well, undef);
    ok(!$err_u, 'AC25 (well-formed, now=undef): does not die') or diag(" error: $err_u");
    is($res_u, 0, 'AC25 (well-formed, now=undef): returns 0');
    my ($res_l, $err_l) = call1('_agent_live', $well, $NOW);
    ok(!$err_l, 'AC25 (well-formed, live): does not die') or diag(" error: $err_l");
    is($res_l, 1, 'AC25 (well-formed, live): returns 1');
}

# --- AC26 (CF2, D7) ---------------------------------------------------------
{
    my $stale_agent = { id=>'c1', role=>'coordinator', worker_type=>undef, started_at=>$NOW-100_000, stale_after_seconds=>7200 };
    cmp_ok($NOW - $stale_agent->{started_at}, '>', $stale_agent->{stale_after_seconds},
        'AC26 precondition: the fixture agent is indeed stale (elapsed > stale_after_seconds)');

    my $pkg_done = { name=>'pkg-ac26', status=>'done', agents=>[$stale_agent] };
    my ($rows_done, $err1) = call1('_package_tree_lines', $pkg_done, $NOW);
    ok(!$err1, 'AC26 (status=done): does not die') or diag(" error: $err1");
    is_deeply($rows_done, [], 'AC26 (status=done): a package whose only agents are stale contributes ZERO rows');

    my $pkg_run = { name=>'pkg-ac26', status=>'running', agents=>[$stale_agent] };
    my ($rows_run, $err2) = call1('_package_tree_lines', $pkg_run, $NOW);
    ok(!$err2, 'AC26 (status=running): does not die') or diag(" error: $err2");
    is(scalar(@{ $rows_run || [] }), 2, 'AC26 (status=running): exactly 2 rows -- package row + duration-less coordinator row');
  SKIP: {
        skip('wrong row count', 2) unless ref($rows_run) eq 'ARRAY' && @$rows_run == 2;
        is(row_text($rows_run->[1]), '    coordinator', 'AC26 (status=running): the coordinator row has no duration');
        unlike(row_text($rows_run->[1]), qr/\d/, 'AC26 (status=running): no digit anywhere in the coordinator row (no duration leaked)');
    }
}

# --- AC27 (CF2, CF3) ---------------------------------------------------------
{
    my $a = { id=>'w', role=>'worker', worker_type=>'zqxfuture27', started_at=>$NOW+600, stale_after_seconds=>7200 };
    is($NOW - $a->{started_at}, -600, 'AC27 precondition: NOW - started_at is exactly -600 (negative, future record)');
    my $pkg = { name=>'pkg-ac27', status=>'running', agents=>[$a] };
    my ($rows, $err) = call1('_package_tree_lines', $pkg, $NOW);
    ok(!$err, 'AC27: does not die') or diag(" error: $err");
  SKIP: {
        skip('no rows', 2) unless ref($rows) eq 'ARRAY';
        my $joined = join("\n", map { row_text($_) } @$rows);
        like($joined, qr/zqxfuture27/, 'AC27: a future-timestamped record (negative difference) IS rendered -- not treated as stale');
        like($joined, qr/<1m/, 'AC27: its duration token is exactly "<1m" (clamped, not negative)');
    }
}

# --- AC54 (fix-batch, H2) ---------------------------------------------------
# A record whose started_at is FAR in the future (host-vs-container clock
# skew is the realistic trigger, per this repo's own WSL clock-skew note) is
# not ordinary skew -- it is not evaluable, and must not render as live
# forever. Before the fix, _agent_live used the RAW difference with no upper
# bound: any started_at in the future made the difference negative, which is
# `<= stale_after_seconds` for every staleness window, so the agent rendered
# as live UNCONDITIONALLY -- even under a status=>'done' package, which
# _pkg_in_flight then wrongly promotes to "in flight" on the strength of
# that one bogus agent. _elapsed's existing clamp only bounds the DISPLAYED
# duration string ("<1m"); it does not bound the LIVENESS DECISION, so a
# "<1m" agent could in fact be a decade in the future.
{
    my $decade_future = { id=>'w', role=>'worker', worker_type=>'zqxfuture54',
                           started_at=>$NOW+315_360_000, stale_after_seconds=>7200 };
    my ($live, $err1) = call1('_agent_live', $decade_future, $NOW);
    ok(!$err1, 'AC54: _agent_live does not die on a decade-ahead started_at') or diag(" error: $err1");
    is($live, 0, 'AC54: a started_at ten years in the future is NOT live (H2 -- no unbounded future liveness)');

    my $pkg = { name=>'pkg-ac54', status=>'done', agents=>[$decade_future] };
    my ($flight, $err2) = call1('_pkg_in_flight', $pkg, $NOW);
    ok(!$err2, 'AC54: _pkg_in_flight does not die') or diag(" error: $err2");
    is($flight, 0, 'AC54: a status=>done package with only a decade-ahead agent is NOT promoted to in-flight');

    # AC27's own 600s-ahead record must still be ordinary skew, not evaluated
    # away by this same fix -- pinned again here, directly against
    # _agent_live rather than through the rendered row, so a future change to
    # FUTURE_SLACK that broke AC27 would fail at the more direct call too.
    my $moderate_future = { id=>'w', role=>'worker', worker_type=>'zqxfuture54b',
                             started_at=>$NOW+600, stale_after_seconds=>7200 };
    my ($live2, $err3) = call1('_agent_live', $moderate_future, $NOW);
    ok(!$err3, 'AC54: _agent_live does not die on a 600s-ahead started_at') or diag(" error: $err3");
    is($live2, 1, 'AC54: a started_at 600s in the future (ordinary clock skew, AC27) is still live');
}

# ===========================================================================
# Decision 4 / Decision 6 / Decision 11 -- the roles and the marker (AC28-AC36)
# ===========================================================================

# --- AC28 (D6) ------------------------------------------------------------
{
    my $shared = 'zqxshared28';
    my $judge  = { id=>'j', role=>'judge',  worker_type=>$shared, started_at=>$NOW-100, stale_after_seconds=>7200 };
    my $worker = { id=>'w', role=>'worker', worker_type=>$shared, started_at=>$NOW-100, stale_after_seconds=>7200 };
    my $pkg    = { name=>'pkg-ac28', status=>'running', agents=>[$judge, $worker] };
    my ($rows, $err) = call1('_package_tree_lines', $pkg, $NOW);
    ok(!$err, 'AC28: does not die') or diag(" error: $err");
  SKIP: {
        skip('no rows', 1) unless ref($rows) eq 'ARRAY' && @$rows;
        my @hit_idx = grep { row_text($rows->[$_]) =~ /\Q$shared\E/ } 0 .. $#$rows;
        is(scalar(@hit_idx), 2, 'AC28 precondition: exactly two rows mention the shared worker_type (one worker, one judge)');
      SKIP: {
            skip('wrong hit count', 6) unless scalar(@hit_idx) == 2;
            my ($worker_row, $judge_row);
            for my $idx (@hit_idx) {
                my $lead = row_leading($rows->[$idx]);
                $worker_row = $rows->[$idx] if $lead == 6;
                $judge_row  = $rows->[$idx] if $lead == 4;
            }
            ok(defined($worker_row) && defined($judge_row),
                'AC28 precondition: one hit is at indent 6 (worker) and the other at indent 4 (judge)');
          SKIP: {
                skip('rows not identified', 5) unless defined($worker_row) && defined($judge_row);
                is(row_leading($judge_row), 4, 'AC28 (a): judge row indent is 4');
                is(row_leading($worker_row), 6, 'AC28 (a): worker row indent is 6');
                is($judge_row->[1]{role}, 'state.warn', 'AC28 (c): judge row label span role is state.warn');
                is($worker_row->[1]{role}, 'text.primary', 'AC28 (c): worker row label span role is text.primary');
                ok(length($JUDGE_MARKER), 'AC28 precondition: the judge marker (Theme::glyph(status.judge)) is a non-empty string');
              SKIP: {
                    skip('marker empty/undef', 2) unless length($JUDGE_MARKER);
                    like($judge_row->[1]{text}, qr/^\Q$JUDGE_MARKER\E/, 'AC28 (b): judge row label span text begins with the judge marker');
                    unlike($worker_row->[1]{text}, qr/^\Q$JUDGE_MARKER\E/, 'AC28 (b): worker row label span text does NOT begin with the judge marker');
                }
            }
        }
    }
}

# --- AC29 (D4) ------------------------------------------------------------
{
    my $g = Theme::glyphs();
    ok(ref($g) eq 'HASH' && exists $g->{'status.judge'}, 'AC29 precondition: Theme::glyphs() has a status.judge entry');
  SKIP: {
        skip('no status.judge entry', 5) unless ref($g) eq 'HASH' && exists $g->{'status.judge'};
        my $rec   = $g->{'status.judge'};
        my $bytes = Theme::glyph('status.judge');
        ok(defined($bytes) && !ref($bytes) && length($bytes), 'AC29: Theme::glyph(status.judge) is a defined non-empty byte string');
        is($rec->{cp}, 0x00A7, 'AC29: cp is 0x00A7');
        is($rec->{width}, 1, 'AC29: width is 1');
        cmp_ok(length(defined($rec->{desc}) ? $rec->{desc} : ''), '>=', 3, 'AC29: desc is at least 3 characters');
        like('status.judge', qr/\A[a-z]+(?:\.[a-z0-9]+)*\z/, 'AC29: the name matches the naming convention');
    }
}

# --- AC30 (D4) ------------------------------------------------------------
{
    my $g = Theme::glyphs();
    ok(ref($g) eq 'HASH' && exists $g->{'status.judge'}, 'AC30 precondition: status.judge exists');
  SKIP: {
        skip('no status.judge', 1) unless ref($g) eq 'HASH' && exists $g->{'status.judge'};
        my $judge_char = $g->{'status.judge'}{char};
        my @collisions = grep {
            $_ ne 'status.judge' && ref($g->{$_}) eq 'HASH' && defined($g->{$_}{char}) && defined($judge_char) && $g->{$_}{char} eq $judge_char
        } keys %$g;
        is(scalar(@collisions), 0, 'AC30: status.judge char is distinct from every other glyph in Theme::glyphs()')
            or diag(' collides with: ' . join(', ', @collisions));
    }
}

# --- AC31 (D4, D9) ------------------------------------------------------------
{
    ok(-f File::Spec->rel2abs("$Bin/64-theme-tokens.t"), 'AC31 precondition: 64-theme-tokens.t exists');
  SKIP: {
        skip('not found', 2) unless -f File::Spec->rel2abs("$Bin/64-theme-tokens.t");
        my ($rc, $out) = run_test_file('64-theme-tokens.t');
        is($rc, 0, 'AC31: 64-theme-tokens.t exits 0 with the new glyph present') or diag(' tail: ' . substr($out, -2000));
        my @notok = ($out =~ /^not ok.*$/mg);
        is(scalar(@notok), 0, 'AC31: 64-theme-tokens.t has zero not ok lines (B-E5/B-E7/B-E14a/b among them)') or diag(' ' . join("\n ", @notok));
    }
}

# --- AC32 (D4, D9) ------------------------------------------------------------
{
    my $ds_path = File::Spec->rel2abs("$Bin/../../scripts/tui/DashboardScreen.pm");
    ok(-f $ds_path, 'AC32 precondition: DashboardScreen.pm exists');
  SKIP: {
        skip('not found', 6) unless -f $ds_path;
        my $raw     = slurp($ds_path);
        my $scanned = _comment_stripped($raw);

        my @brace_esc = ($raw =~ /\\x\{([0-9A-Fa-f]+)\}/g);
        is(scalar(grep { hex($_) == 0xA7 } @brace_esc), 0, 'AC32: no \\x{A7} escape (section sign) in the source');
        my @bare_esc = ($raw =~ /\\x([0-9A-Fa-f]{2})/g);
        is(scalar(grep { hex($_) == 0xA7 } @bare_esc), 0, 'AC32: no \\xA7 escape (section sign) in the source');
        my @raw_bytes = ($raw =~ /(\xA7)/g);
        is(scalar(@raw_bytes), 0, 'AC32: no literal section-sign byte (0xA7) in the source');

        ok(($raw =~ /Theme::glyph\(\s*'status\.judge'\s*\)/ ? 1 : 0),
            "AC32: the source contains the exact call Theme::glyph('status.judge')");
        my @callsites = ($scanned =~ /Theme::glyph\(\s*'status\.judge'\s*\)/g);
        is(scalar(@callsites), 1, 'AC32: Theme::glyph(status.judge) is called exactly once in the whole file');

        # THE "no title.* token" CLAIM IS SCOPED TO _judge_marker'S OWN BODY,
        # not the whole file: DashboardScreen.pm's PRE-EXISTING container_glyph
        # mechanism already names title.paused/title.exited/title.gone
        # legitimately (header/container-state glyphs, unrelated to the judge
        # marker), and t/64's own B-E14 evidently does not flag that usage
        # either (AC31 above runs t/64 green). A whole-file "no title." scan
        # would therefore fail on TODAY's unmodified file for a reason that has
        # nothing to do with this package -- scoping to the sub that resolves
        # the judge marker is the claim the spec text is actually protecting
        # (Decision 11: the JUDGE marker must not borrow a title.* token).
        my $sub_start = index($scanned, 'sub _judge_marker');
        ok($sub_start >= 0, 'AC32 precondition: a sub _judge_marker exists in the source');
      SKIP: {
            skip('no sub found', 2) unless $sub_start >= 0;
            my $next_sub = index($scanned, "\nsub ", $sub_start + 1);
            $next_sub = length($scanned) if $next_sub < 0;
            my $marker_sub_src = substr($scanned, $sub_start, $next_sub - $sub_start);
            ok(($marker_sub_src !~ /\btitle\./ ? 1 : 0),
                'AC32: sub _judge_marker itself names no title.* token');
            my $call_pos = index($scanned, "Theme::glyph('status.judge')");
            ok($call_pos >= $sub_start && $call_pos < $next_sub,
                'AC32: the sole Theme::glyph(status.judge) call site sits inside sub _judge_marker');
        }
    }
}

# --- AC33 (D4, D6) ------------------------------------------------------------
{
    local *Theme::glyph = sub { return undef };
    my ($marker, $err0) = call1('_judge_marker');
    ok(!$err0, 'AC33: _judge_marker does not die with Theme::glyph overridden') or diag(" error: $err0");
    is($marker, '', 'AC33 precondition: with Theme::glyph overridden to return undef, _judge_marker() returns ""');

    my $j   = { id=>'j', role=>'judge', worker_type=>'zqxjudge33', started_at=>$NOW-100, stale_after_seconds=>7200 };
    my $pkg = { name=>'pkg-ac33', status=>'running', agents=>[$j] };
    my (@warns, $rows, $err);
    {
        local $SIG{__WARN__} = sub { push @warns, $_[0] };
        ($rows, $err) = call1('_package_tree_lines', $pkg, $NOW);
    }
    ok(!$err, 'AC33: _package_tree_lines does not die with the marker unavailable') or diag(" error: $err");
    ok(!@warns, 'AC33: _package_tree_lines does not warn with the marker unavailable') or diag(' warned: ' . join('; ', @warns));
  SKIP: {
        skip('no rows', 1) unless ref($rows) eq 'ARRAY';
        my ($judge_row) = grep { row_text($_) =~ /zqxjudge33/ } @$rows;
        ok(defined($judge_row), 'AC33 precondition: a judge row is present in the output');
      SKIP: {
            skip('no judge row', 3) unless defined $judge_row;
            is(row_leading($judge_row), 4, 'AC33: the judge row still renders at indent 4');
            is($judge_row->[1]{text}, 'zqxjudge33', 'AC33: labelled by its worker_type with no marker prefix');
            is($judge_row->[1]{role}, 'state.warn', 'AC33: still in state.warn');
        }
    }
}

# --- AC34 (D3) ------------------------------------------------------------
{
    my @role_agents = (
        { id=>'c',  role=>'coordinator', worker_type=>undef, started_at=>$NOW-10, stale_after_seconds=>7200 },
        { id=>'w',  role=>'worker',      worker_type=>undef, started_at=>$NOW-10, stale_after_seconds=>7200 },
        { id=>'j',  role=>'judge',       worker_type=>undef, started_at=>$NOW-10, stale_after_seconds=>7200 },
        { id=>'a1', role=>'admiral',     worker_type=>undef, started_at=>$NOW-10, stale_after_seconds=>7200 },
        { id=>'a2', role=>'',            worker_type=>undef, started_at=>$NOW-10, stale_after_seconds=>7200 },
        { id=>'a3', role=>[],            worker_type=>undef, started_at=>$NOW-10, stale_after_seconds=>7200 },
        { id=>'a4',                      worker_type=>undef, started_at=>$NOW-10, stale_after_seconds=>7200 },
    );
    my %labels;
    my ($orow, $oerr) = call1('_orchestrator_line', CF(), $NOW);
    ok(!$oerr, 'AC34: _orchestrator_line does not die') or diag(" error: $oerr");
    $labels{ $orow->[1]{text} } = 1 if ref($orow) eq 'ARRAY' && ref($orow->[1]) eq 'HASH' && defined($orow->[1]{text});

    for my $a (@role_agents) {
        my $rlabel = !exists($a->{role}) ? 'absent(no key)' : (!defined($a->{role}) ? 'undef' : (ref($a->{role}) ? ref($a->{role}) . '-ref' : "'$a->{role}'"));
        my ($row, $err) = call1('_agent_row', $a, 2, $NOW);
        ok(!$err, "AC34 (role=$rlabel): _agent_row does not die") or diag(" error: $err");
        if (ref($row) eq 'ARRAY' && ref($row->[1]) eq 'HASH' && defined($row->[1]{text})) {
            $labels{ $row->[1]{text} } = 1;
        }
    }
    my $marker = $JUDGE_MARKER;
    my %normalized;
    for my $w (keys %labels) {
        my $stripped = $w;
        $stripped =~ s/^\Q$marker\E// if length($marker);
        $normalized{$stripped} = 1;
    }
    is_deeply([ sort keys %normalized ], [ sort ('orchestrator', 'coordinator', 'worker', 'judge', '?') ],
        'AC34: the set of label-span texts (marker-stripped) is exactly {orchestrator, coordinator, worker, judge, ?} -- '
      . 'no other authored word appears, for role admiral/empty-string/arrayref/absent');
}

# --- AC35 (D3) ------------------------------------------------------------
{
    my $ds_path = File::Spec->rel2abs("$Bin/../../scripts/tui/DashboardScreen.pm");
    ok(-f $ds_path, 'AC35 precondition: DashboardScreen.pm exists');
  SKIP: {
        skip('not found', 8) unless -f $ds_path;
        my $scanned = _comment_stripped(slurp($ds_path));
        for my $word (qw(agent subagent implementer reviewer redteam resolver a1 a2)) {
            ok(($scanned !~ /(['"])\Q$word\E\1/ ? 1 : 0),
                "AC35: the quoted literal '$word' does not appear as a role word in DashboardScreen.pm");
        }
    }
}

# --- AC36 (D1) ------------------------------------------------------------
{
    my $s = {
        state => 'running', packages => [],
        run_agents => [
            { id=>'c', role=>'coordinator', worker_type=>'zqxrc36', started_at=>$NOW-100, stale_after_seconds=>7200 },
            { id=>'w', role=>'worker',      worker_type=>'zqxrw36', started_at=>$NOW-100, stale_after_seconds=>7200 },
            { id=>'j', role=>'judge',       worker_type=>'zqxrj36', started_at=>$NOW-100, stale_after_seconds=>7200 },
            { id=>'u', role=>'admiral',     worker_type=>'zqxru36', started_at=>$NOW-100, stale_after_seconds=>7200 },
        ],
    };
    my ($rows, $err) = call1('_tree_lines', $s, $NOW);
    ok(!$err, 'AC36: does not die') or diag(" error: $err");
  SKIP: {
        skip('no rows', 3) unless ref($rows) eq 'ARRAY';
        my @order = grep { defined } map {
            my $t = row_text($rows->[$_]);
            $t =~ /zqxrc36/ ? 'c' : $t =~ /zqxrw36/ ? 'w' : $t =~ /zqxrj36/ ? 'j' : $t =~ /zqxru36/ ? 'u' : undef;
        } 0 .. $#$rows;
        is_deeply(\@order, ['c', 'w', 'j', 'u'], 'AC36: run_agents rows appear in the array\'s own order');

        my @nonces = qw(zqxrc36 zqxrw36 zqxrj36 zqxru36);
        my @bad_indent;
        for my $nonce (@nonces) {
            my ($row) = grep { row_text($_) =~ /\Q$nonce\E/ } @$rows;
            push @bad_indent, $nonce if $row && row_leading($row) != 2;
        }
        is(scalar(@bad_indent), 0, 'AC36: every run_agents row renders at indent 2') or diag(' bad: ' . join(',', @bad_indent));

        my ($judge_row) = grep { row_text($_) =~ /zqxrj36/ } @$rows;
        ok(defined($judge_row), 'AC36 precondition: the judge run_agents row is present');
      SKIP: {
            skip('no judge row / no marker', 1) unless defined($judge_row) && length($JUDGE_MARKER);
            like($judge_row->[1]{text}, qr/^\Q$JUDGE_MARKER\E/, 'AC36: the judge run_agents row label begins with the judge marker');
        }
        for my $nonce (qw(zqxrc36 zqxrw36 zqxru36)) {
            my ($row) = grep { row_text($_) =~ /\Q$nonce\E/ } @$rows;
            next unless $row && length($JUDGE_MARKER);
            unlike($row->[1]{text}, qr/^\Q$JUDGE_MARKER\E/, "AC36: non-judge run_agents row ($nonce) does not carry the judge marker");
        }
    }
}

# ===========================================================================
# Decision 10's coordinator row (AC37-AC38)
# ===========================================================================

# --- AC37 (D7) ------------------------------------------------------------
{
    # (a) no agents
    {
        my $pkg = { name=>'pkg-ac37a', status=>'running', agents=>[] };
        my ($rows, $err) = call1('_package_tree_lines', $pkg, $NOW);
        ok(!$err, 'AC37 (a, no agents): does not die') or diag(" error: $err");
        is(scalar(@{ $rows || [] }), 2, 'AC37 (a): package row + exactly one coordinator row');
      SKIP: {
            skip('wrong shape', 1) unless ref($rows) eq 'ARRAY' && @$rows == 2;
            is(row_text($rows->[1]), '    coordinator', 'AC37 (a): coordinator row text is exactly "    coordinator", no duration');
        }
    }
    # (b) one live coordinator
    {
        my $dur = tui::DashboardScreen::fmt_duration(1860);
        my $c   = { id=>'c1', role=>'coordinator', worker_type=>undef, started_at=>$NOW-1860, stale_after_seconds=>28800 };
        my $pkg = { name=>'pkg-ac37b', status=>'running', agents=>[$c] };
        my ($rows, $err) = call1('_package_tree_lines', $pkg, $NOW);
        ok(!$err, 'AC37 (b, one live coordinator): does not die') or diag(" error: $err");
        is(scalar(@{ $rows || [] }), 2, 'AC37 (b): package row + one coordinator row');
      SKIP: {
            skip('wrong shape', 1) unless ref($rows) eq 'ARRAY' && @$rows == 2;
            is(row_text($rows->[1]), "    coordinator  $dur", "AC37 (b): coordinator row text is '    coordinator  $dur'");
        }
    }
    # (c) two live coordinators
    {
        my $c1 = { id=>'c1', role=>'coordinator', worker_type=>undef, started_at=>$NOW-100, stale_after_seconds=>7200 };
        my $c2 = { id=>'c2', role=>'coordinator', worker_type=>undef, started_at=>$NOW-200, stale_after_seconds=>7200 };
        my $pkg = { name=>'pkg-ac37c', status=>'running', agents=>[$c1, $c2] };
        my ($rows, $err) = call1('_package_tree_lines', $pkg, $NOW);
        ok(!$err, 'AC37 (c, two live coordinators): does not die') or diag(" error: $err");
        is(scalar(@{ $rows || [] }), 3, 'AC37 (c): package row + exactly TWO coordinator rows (no third synthesised)');
      SKIP: {
            skip('wrong shape', 2) unless ref($rows) eq 'ARRAY' && @$rows == 3;
            my $d1 = tui::DashboardScreen::fmt_duration(100);
            my $d2 = tui::DashboardScreen::fmt_duration(200);
            is(row_text($rows->[1]), "    coordinator  $d1", 'AC37 (c): first coordinator row matches c1, in agents order');
            is(row_text($rows->[2]), "    coordinator  $d2", 'AC37 (c): second coordinator row matches c2, in agents order');
        }
    }
    # (d) one stale coordinator
    {
        my $c = { id=>'c1', role=>'coordinator', worker_type=>undef, started_at=>$NOW-1_000_000, stale_after_seconds=>7200 };
        cmp_ok($NOW - $c->{started_at}, '>', $c->{stale_after_seconds}, 'AC37 (d) precondition: the coordinator fixture is stale');
        my $pkg = { name=>'pkg-ac37d', status=>'running', agents=>[$c] };
        my ($rows, $err) = call1('_package_tree_lines', $pkg, $NOW);
        ok(!$err, 'AC37 (d, one stale coordinator): does not die') or diag(" error: $err");
        is(scalar(@{ $rows || [] }), 2, 'AC37 (d): package row + one duration-less coordinator row (package not mistaken for empty)');
      SKIP: {
            skip('wrong shape', 1) unless ref($rows) eq 'ARRAY' && @$rows == 2;
            is(row_text($rows->[1]), '    coordinator', 'AC37 (d): coordinator row has no duration');
        }
    }
}

# --- AC38 (D7) ------------------------------------------------------------
{
    my $w   = { id=>'w1', role=>'worker', worker_type=>'zqxw38', started_at=>$NOW-100, stale_after_seconds=>7200 };
    my $pkg = { name=>'pkg-ac38', status=>'blocked', agents=>[$w] };
    my ($rows, $err) = call1('_package_tree_lines', $pkg, $NOW);
    ok(!$err, 'AC38: does not die') or diag(" error: $err");
    is(scalar(@{ $rows || [] }), 2, 'AC38: exactly 2 rows -- package row + worker row (no coordinator row)');
  SKIP: {
        skip('wrong shape', 3) unless ref($rows) eq 'ARRAY' && @$rows == 2;
        unlike(row_text($rows->[1]), qr/\bcoordinator\b/, 'AC38: the second row is NOT a coordinator row');
        like(row_text($rows->[1]), qr/zqxw38/, 'AC38: the second row is the worker row');
        is(row_leading($rows->[1]), 6, 'AC38: the worker row is at indent 6');
    }
}

# ===========================================================================
# Robustness, scale, non-ASCII (AC39-AC45)
# ===========================================================================

# --- AC39 (D1) ------------------------------------------------------------
{
    my @hostile = (undef, '', 0, [], {}, sub { 1 }, bless({}, 'X'));
    my %CALLS = (
        _tree_lines         => sub { my ($h) = @_; call1('_tree_lines', $h, $NOW) },
        _orchestrator_line  => sub { my ($h) = @_; call1('_orchestrator_line', $h, $NOW) },
        _package_tree_lines => sub { my ($h) = @_; call1('_package_tree_lines', $h, $NOW) },
        _agent_row          => sub { my ($h) = @_; call1('_agent_row', $h, 2, $NOW) },
        _bound_display      => sub { my ($h) = @_; call1('_bound_display', $h, 64) },
        _elapsed            => sub { my ($h) = @_; call1('_elapsed', $NOW, $h) },
    );
    my (@warns, @died);
    {
        local $SIG{__WARN__} = sub { push @warns, $_[0] };
        for my $h (@hostile) {
            my $label = !defined($h) ? 'undef' : (ref($h) ? (ref($h) eq 'X' ? "bless({},'X')" : ref($h) . '-ref') : (length($h) ? "'$h'" : "''"));
            for my $name (sort keys %CALLS) {
                my (undef, $err) = $CALLS{$name}->($h);
                push @died, "$name($label): $err" if $err;
            }
        }
        my $hostile_summary = { state=>'running', packages=>[ {}, 'x', undef, [] ], run_agents=>[ {}, 'x', undef, [] ] };
        my (undef, $rsl_err) = call1('_run_summary_lines', [$hostile_summary], undef, 120, $NOW);
        push @died, "_run_summary_lines(hostile struct): $rsl_err" if $rsl_err;
        my (undef, $tl_err) = call1('_tree_lines', $hostile_summary, $NOW);
        push @died, "_tree_lines(hostile struct): $tl_err" if $tl_err;
    }
    is(scalar(@died), 0, 'AC39: none of the tree subs die on any hostile input (totality)') or diag(join("\n", @died));
    is(scalar(@warns), 0, 'AC39: none of the tree subs warn on any hostile input') or diag(join("\n", @warns));
}

# --- AC40 (D1, CF4) ------------------------------------------------------------
{
    my $s = many_pkg_fixture();
    is(scalar(@{ $s->{packages} }), 40, 'AC40 precondition: exactly 40 packages built');
    is(scalar(@{ $s->{packages}[0]{agents} }), 6, 'AC40 precondition: each package has exactly 6 agents');

    my ($rows, $err) = call1('_tree_lines', $s, $NOW);
    ok(!$err, 'AC40: _tree_lines does not die on 40 packages x 6 agents') or diag(" error: $err");
    # Ruling AT-13 (driver, 2026-09-09): was 1 + 40*(1+1+4) = 241, which accounts for
    # FIVE agents per package -- while this AC's OWN precondition, one line above,
    # asserts each package has SIX. The sixth is role=>'admiral', and spec R6
    # explicitly rejects the only reconciliation: "Rejected: dropping the row (it
    # hides a live agent) and inventing a fourth role word". AC36 independently
    # renders an admiral element, so unattributed roles demonstrably do render.
    # The AC contradicted itself; the formula was the wrong half.
    is(scalar(@{ $rows || [] }), 1 + 40 * (1 + 1 + 5), 'AC40: exactly 1 + 40*(package+coordinator+5 agents) rows');
  SKIP: {
        skip('wrong row count', 1) unless ref($rows) eq 'ARRAY';
        my @names_in_order = grep { defined } map {
            my $t = row_text($_);
            ($t =~ /^\s*(pkg-ac40-\d\d)\b/) ? $1 : undef;
        } @$rows;
        my @expected = map { sprintf('pkg-ac40-%02d', $_) } 1 .. 40;
        is_deeply(\@names_in_order, \@expected, 'AC40: package rows appear in array order');
    }
}

# --- AC41 (D1) ------------------------------------------------------------
{
    my $name = "andr\xC3\xA9-caf\xC3\xA9";
    my $wt   = "bp-impl\xC3\xA9menter";
    my $w    = { id=>'w', role=>'worker', worker_type=>$wt, started_at=>$NOW-100, stale_after_seconds=>7200 };
    my $pkg  = { name=>$name, status=>'running', agents=>[$w] };
    my ($rows, $err) = call1('_package_tree_lines', $pkg, $NOW);
    ok(!$err, 'AC41: does not die on non-ASCII package name / worker_type') or diag(" error: $err");
  SKIP: {
        skip('no rows', 2) unless ref($rows) eq 'ARRAY' && @$rows;
        like(row_text($rows->[0]), qr/\Q$name\E/, 'AC41: the package name round-trips byte-identically');
        my $all = join("\n", map { row_text($_) } @$rows);
        like($all, qr/\Q$wt\E/, 'AC41: the worker_type round-trips byte-identically');
    }
}

# --- AC42 (D1) ------------------------------------------------------------
{
    my $name = ('a' x 199) . "\xC3\xA9" . ('b' x 99);
    is(length($name), 300, 'AC42 precondition: fixture package name is exactly 300 bytes');
    is(ord(substr($name, 199, 1)), 0xC3, 'AC42 precondition: byte 200 (1-based, last kept by a 200-byte cut) is 0xC3 (>= 0x80)');
    my $pkg = { name=>$name, status=>'running', agents=>[] };
    my ($rows, $err) = call1('_package_tree_lines', $pkg, $NOW);
    ok(!$err, 'AC42 (package name): does not die on a 300-byte name with a split UTF-8 sequence at the cut') or diag(" error: $err");
  SKIP: {
        skip('no rows', 3) unless ref($rows) eq 'ARRAY' && @$rows;
        my $rendered = $rows->[0][1]{text};
        ok(defined($rendered) && !ref($rendered), 'AC42 (package name): the rendered name span is a defined non-ref scalar');
      SKIP: {
            skip('not a scalar', 2) unless defined($rendered) && !ref($rendered);
            cmp_ok(length($rendered), '<=', 200, 'AC42 (package name): rendered package name is at most 200 bytes');
            my $ok_utf8 = eval { Encode::decode('UTF-8', $rendered, Encode::FB_CROAK()); 1 };
            ok($ok_utf8, 'AC42 (package name): the rendered package name decodes cleanly as UTF-8') or diag(" decode error: $@");
        }
    }

    my $wt = ('c' x 63) . "\xC3\xA9" . ('d' x 235);
    is(length($wt), 300, 'AC42 precondition: fixture worker_type is exactly 300 bytes');
    is(ord(substr($wt, 63, 1)), 0xC3, 'AC42 precondition: byte 64 (1-based, last kept by a 64-byte cut) is 0xC3 (>= 0x80)');
    my $w2   = { id=>'w', role=>'worker', worker_type=>$wt, started_at=>$NOW-100, stale_after_seconds=>7200 };
    my $pkg2 = { name=>'pkg-ac42b', status=>'running', agents=>[$w2] };
    my ($rows2, $err2) = call1('_package_tree_lines', $pkg2, $NOW);
    ok(!$err2, 'AC42 (worker_type): does not die') or diag(" error: $err2");
  SKIP: {
        skip('no rows', 3) unless ref($rows2) eq 'ARRAY' && @$rows2 > 1;
        my $wrow     = $rows2->[-1];
        my $rendered = $wrow->[1]{text};
        ok(defined($rendered) && !ref($rendered), 'AC42 (worker_type): rendered label is a defined non-ref scalar');
      SKIP: {
            skip('not scalar', 2) unless defined($rendered) && !ref($rendered);
            cmp_ok(length($rendered), '<=', 64, 'AC42 (worker_type): rendered worker_type is at most 64 bytes');
            my $ok_utf8 = eval { Encode::decode('UTF-8', $rendered, Encode::FB_CROAK()); 1 };
            ok($ok_utf8, 'AC42 (worker_type): the rendered worker_type decodes cleanly as UTF-8') or diag(" decode error: $@");
        }
    }
}

# --- AC43 (D8, CF4) ------------------------------------------------------------
{
    my $M = $JUDGE_MARKER;
    my @b1_rows = (
        '  orchestrator  alive  2h14m',
        '  04-agent-records  attempt 2/5  step 4/8',
        '    coordinator  31m',
        '      bp-implementer  12m',
        '    ' . $M . 'bp-resolve-judge  8m',
        '  05-runstate-agg  attempt 1/5  step 6/8',
        '    coordinator',
        '  ' . $M . 'bp-conformance-judge  2m',
    );
    my @words;
    for my $r (@b1_rows) { push @words, grep { length } split /\s+/, $r; }

    for my $cols (60, 80, 90, 103, 120) {
        my $state = base_state(runs => [ CF() ], now => $NOW);
        my $frame = Dashboard::compose_frame($state, 60, $cols);
        my $t     = frame_text($frame);
        ok(length($t) > 0, "AC43 (cols=$cols) precondition: the composed frame is non-empty");
        like($t, qr/agent-telemetry/, "AC43 (cols=$cols) precondition: the frame contains the blueprint name (frame did not fail to build)");
        my %missing;
        for my $w (@words) { $missing{$w} = 1 unless index($t, $w) >= 0; }
        is(scalar(keys %missing), 0, "AC43 (cols=$cols): every word of every one of B1's 8 rows appears in the composed frame")
            or diag(' missing: ' . join(', ', sort keys %missing));
    }
}

# --- AC53 (fix-batch, H1) --------------------------------------------------
# A wrapped tree row's continuation must never land on a tree level it does
# not own. tui::Screen's continuation indent and this tree's own level step
# are BOTH 2, so a naive continuation (own_indent + 2) collides exactly with
# the next level down -- a package row's own continuation reads as its
# coordinator, a coordinator's continuation reads as its worker. No EXISTING
# criterion here can catch this: every row_leading assertion above runs on
# pre-wrap logical rows, and AC43 only composes at cols>=60, where CF never
# wraps. This composes at cols narrow enough that CF's own package row (whose
# `attempt`/`step` suffix is long relative to a 20-30 column band) DOES wrap,
# and checks the PHYSICALLY RENDERED frame -- not the logical rows.
{
    for my $cols (20, 24, 30) {
        my $state = base_state(runs => [ CF() ], now => $NOW);
        my $frame = Dashboard::compose_frame($state, 60, $cols);
        my @lines = map { plain($_) } @$frame;

        my ($coord_lead, $pkg_continuation_lead);
        for my $i (0 .. $#lines) {
            my $t = $lines[$i];
            if (!defined($coord_lead) && $t =~ /\bcoordinator\b/) {
                my ($lead) = $t =~ /^( *)/;
                $coord_lead = length($lead // '');
            }
            # The package row's own continuation carries "attempt" or "step"
            # but NOT the package name itself (the name is on the first
            # physical line) -- that is what marks it as a continuation
            # rather than the row's own first line.
            if (!defined($pkg_continuation_lead)
                && $t =~ /\b(?:attempt|step)\b/ && $t !~ /04-agent-records/) {
                my ($lead) = $t =~ /^( *)/;
                $pkg_continuation_lead = length($lead // '');
            }
        }
        ok(defined($coord_lead), "AC53 (cols=$cols) precondition: a coordinator row is present in the composed frame")
            or diag(" frame:\n" . join("\n", @lines));
        ok(defined($pkg_continuation_lead), "AC53 (cols=$cols) precondition: the package row wraps (a continuation with attempt/step is present)")
            or diag(" frame:\n" . join("\n", @lines));
      SKIP: {
            skip('preconditions not met', 1) unless defined($coord_lead) && defined($pkg_continuation_lead);
            isnt($pkg_continuation_lead, $coord_lead,
                "AC53 (cols=$cols): the package row's wrapped continuation does not sit at the SAME indent as a real coordinator row (H1 -- hierarchy inversion)");
        }
    }
}

# --- AC44 (D8) ------------------------------------------------------------
{
    my ($rows, $err) = call1('_tree_lines', CF(), $NOW);
    ok(!$err, 'AC44: _tree_lines does not die on CF') or diag(" error: $err");
  SKIP: {
        skip('no rows', 1) unless ref($rows) eq 'ARRAY';
        my @atomic_hits;
        for my $row (@$rows) {
            for my $span (@$row) {
                push @atomic_hits, $span if ref($span) eq 'HASH' && exists($span->{atomic}) && $span->{atomic};
            }
        }
        is(scalar(@atomic_hits), 0, 'AC44: no tree row span carries atomic => 1 (structural check over CF)');
    }

    my $ds_path = File::Spec->rel2abs("$Bin/../../scripts/tui/DashboardScreen.pm");
  SKIP: {
        skip('DashboardScreen.pm not found', 4) unless -f $ds_path;
        my $scanned = _comment_stripped(slurp($ds_path));
        for my $sub_name (qw(_tree_lines _orchestrator_line _package_tree_lines _agent_row)) {
            my $body = _sub_body($scanned, $sub_name);
            ok(defined($body), "AC44 precondition: sub $sub_name is defined in DashboardScreen.pm (so its body can be scanned)");
          SKIP: {
                skip("sub $sub_name not found", 1) unless defined $body;
                unlike($body, qr/\bfit_spans\b/, "AC44: sub $sub_name's body does not call fit_spans");
            }
        }
    }
}

# --- AC19 / AC45 CUMULATIVE SCAN (D2, D11) ---------------------------------
{
    my @all_rows;
    my @fixtures = (
        CF(), many_pkg_fixture(),
        { state=>'running', packages=>[ { name=>'pkg-scan', status=>'running', agents=>[
              { id=>'c', role=>'coordinator', worker_type=>undef, started_at=>$NOW-100, stale_after_seconds=>7200 },
              { id=>'w', role=>'worker', worker_type=>'zqxscanw', started_at=>$NOW-100, stale_after_seconds=>7200 },
              { id=>'j', role=>'judge', worker_type=>'zqxscanj', started_at=>$NOW-100, stale_after_seconds=>7200 },
              { id=>'u', role=>'admiral', worker_type=>'zqxscanu', started_at=>$NOW-100, stale_after_seconds=>7200 },
          ] } ], run_agents=>[ { id=>'rj', role=>'judge', worker_type=>'zqxscanrj', started_at=>$NOW-100, stale_after_seconds=>7200 } ] },
    );
    for my $s (@fixtures) {
        my ($rows, $err) = call1('_tree_lines', $s, $NOW);
        push @all_rows, @$rows if ref($rows) eq 'ARRAY';
    }
    my $have_rows = scalar(@all_rows) > 0;
  SKIP: {
        skip('no rows collected from any representative fixture (subs not implemented yet)', 2) unless $have_rows;
        my @attempt_hits = grep { row_leading($_) >= 4 && row_text($_) =~ /attempt/ } @all_rows;
        is(scalar(@attempt_hits), 0,
            'AC19: no agent row (indent >= 4) in any representative fixture contains the substring "attempt"')
            or diag(join("\n", map { row_text($_) } @attempt_hits));
        my @colon_hits = grep { row_text($_) =~ /:/ } @all_rows;
        is(scalar(@colon_hits), 0, 'AC45: no tree row\'s text contains ":" in any representative fixture')
            or diag(join("\n", map { row_text($_) } @colon_hits));
    }
}

# ===========================================================================
# The clock seam (AC46-AC48)
# ===========================================================================

# --- AC46 (D1, S1.4) ------------------------------------------------------------
{
    my ($v1, $e1) = call1('_tree_now', { now => 1800000000 });
    ok(!$e1, 'AC46 (now=1800000000 Int): does not die') or diag(" error: $e1");
    is($v1, 1800000000, 'AC46: returns the integer for now=>1800000000');

    my ($v2, $e2) = call1('_tree_now', { now => '1800000000' });
    ok(!$e2, "AC46 (now='1800000000' str): does not die") or diag(" error: $e2");
    is($v2, 1800000000, "AC46: returns the integer for now=>'1800000000' (string)");

    my @undef_cases = (
        ['absent',            {}],
        ['undef',             { now => undef }],
        ['0',                 { now => 0 }],
        ['-1',                { now => -1 }],
        ["'abc'",             { now => 'abc' }],
        ['1.5',               { now => 1.5 }],
        ["'1e9'",             { now => '1e9' }],
        ['[]',                { now => [] }],
        ['{}',                { now => {} }],
        ['13-digit',          { now => 1234567890123 }],
        ["bless({},'X')",     { now => bless({}, 'X') }],
    );
    for my $c (@undef_cases) {
        my ($label, $s) = @$c;
        my ($v, $e) = call1('_tree_now', $s);
        ok(!$e, "AC46 (now=$label): _tree_now does not die") or diag(" error: $e");
        is($v, undef, "AC46 (now=$label): _tree_now returns undef");
    }

    my $called = 0;
    my ($v3, $e3) = call1('_tree_now', { now => sub { $called = 1; return 1800000000 } });
    ok(!$e3, 'AC46 (now=coderef): _tree_now does not die') or diag(" error: $e3");
    is($v3, undef, 'AC46 (now=coderef): returns undef for a coderef');
    is($called, 0, 'AC46 (now=coderef): the coderef is NEVER called');
}

# --- AC47 (D1, D7, CF2) ------------------------------------------------------------
{
    my ($rows, $err) = call1('_run_summary_lines', [ CF() ], undef, 120);
    ok(!$err, 'AC47: _run_summary_lines(three args, no now) does not die') or diag(" error: $err");
  SKIP: {
        skip('no rows', 2) unless ref($rows) eq 'ARRAY';
        cmp_ok(scalar(@$rows), '>=', 6, 'AC47 precondition: at least 6 rows returned (table row + 5 tree rows)')
            or diag(' got ' . scalar(@$rows) . ' rows: ' . join(' | ', map { row_text($_) } @$rows));
      SKIP: {
            skip('fewer than 6 rows', 2) unless @$rows >= 6;
            my @after_table = @$rows[1 .. $#$rows];
            is(scalar(@after_table), 5, 'AC47: exactly 5 tree rows after the table row');
            my @expected = (
                '  orchestrator  alive',
                '  04-agent-records  attempt 2/5  step 4/8',
                '    coordinator',
                '  05-runstate-agg  attempt 1/5  step 6/8',
                '    coordinator',
            );
            my @actual = map { row_text($_) } @after_table;
            is_deeply(\@actual, \@expected, 'AC47: exact 5-row degradation set, in order (no clock -> no agent rows)');

            my $joined = join("\n", @actual);
            for my $nonce (qw(bp-implementer bp-resolve-judge bp-conformance-judge)) {
                unlike($joined, qr/\Q$nonce\E/, "AC47: agent worker_type nonce '$nonce' is absent (zero agent rows without a clock)");
            }
        }
    }
}

# --- AC48 (S1.4) ------------------------------------------------------------
{
    my $state_with = base_state(runs => [ CF() ], now => $NOW);
    my $panels_with = tui::DashboardScreen::panels($state_with, 120);
    my $bpp_with = panel_by_title($panels_with, 'Blueprints');
    ok($bpp_with, 'AC48 precondition: Blueprints panel exists (with now)');
  SKIP: {
        skip('no panel', 1) unless $bpp_with;
        my $joined = join("\n", @{ panel_line_texts($bpp_with) });
        like($joined, qr/bp-implementer/, 'AC48: with now => $NOW in $state, panels() Blueprints panel contains agent rows');
    }

    my $state_without = base_state(runs => [ CF() ]);
    my $panels_without = tui::DashboardScreen::panels($state_without, 120);
    my $bpp_without = panel_by_title($panels_without, 'Blueprints');
    ok($bpp_without, 'AC48 precondition: Blueprints panel exists (without now)');
  SKIP: {
        skip('no panel', 1) unless $bpp_without;
        my $joined = join("\n", @{ panel_line_texts($bpp_without) });
        unlike($joined, qr/bp-implementer/,
            'AC48: without now in $state, panels() Blueprints panel does NOT contain agent rows -- pins $state->{now} as the wired path');
    }
}

# ===========================================================================
# Module contract (AC49-AC52)
# ===========================================================================

# --- AC49 (D10) ------------------------------------------------------------
{
    for my $case (['tui/DashboardScreen.pm', "$Bin/../../scripts/tui/DashboardScreen.pm"],
                  ['Theme.pm',                "$Bin/../../scripts/Theme.pm"]) {
        my ($label, $rel) = @$case;
        my $path = File::Spec->rel2abs($rel);
        ok(-f $path, "AC49 precondition: $label exists at $path");
      SKIP: {
            skip("$path not found", 1) unless -f $path;
            my $out = `perl -I "$SCRIPTS" -c "$path" 2>&1`;
            my $rc  = $? >> 8;
            is($rc, 0, "AC49: perl -c on $label exits 0") or diag("  output: $out");
        }
    }
}

# --- AC50 (D9) ------------------------------------------------------------
{
    my $ds_path = File::Spec->rel2abs("$Bin/../../scripts/tui/DashboardScreen.pm");
  SKIP: {
        skip('DashboardScreen.pm not found', 2) unless -f $ds_path;
        my $raw = slurp($ds_path);
        my @high = ($raw =~ /([^\x00-\x7f])/g);
        is(scalar(@high), 0, 'AC50: no byte >= 0x80 in DashboardScreen.pm') or diag(' found ' . scalar(@high) . ' high byte(s)');
        my @esc = ($raw =~ /\\x\{([0-9A-Fa-f]+)\}/g);
        my @bad = grep { hex($_) >= 0x80 } @esc;
        is(scalar(@bad), 0, 'AC50: no \\x{...} escape >= 0x80 in DashboardScreen.pm') or diag(' bad: ' . join(',', @bad));
    }

    my $theme_path = File::Spec->rel2abs("$Bin/../../scripts/Theme.pm");
  SKIP: {
        skip('Theme.pm not found', 1) unless -f $theme_path;
        my $raw = slurp($theme_path);
        # SCOPED TO THE status.judge DECLARATION LINE ITSELF, not the whole
        # file: Theme.pm is NOT under the tui-ascii-only rule (only tui/*.pm
        # is), and its comments already contain the literal byte sequence for
        # section-sign (U+00A7, UTF-8 C2 A7) in existing "spec Ss2.4.5"-style
        # cross-references, unrelated to this glyph. The spec's own claim is
        # "Theme.pm's NEW LINE ... contains no literal section-sign byte" --
        # a whole-file scan asserts something the spec never claimed and that
        # is already false today for reasons that predate this package.
        my ($line) = ($raw =~ /^([^\n]*'status\.judge'[^\n]*)$/m);
        ok(defined($line), 'AC50 precondition: a status.judge declaration line is found in Theme.pm');
      SKIP: {
            skip('no declaration line found', 2) unless defined($line);
            ok(($line =~ /cp\s*=>\s*0x00A7/i ? 1 : 0),
                'AC50: the status.judge line declares cp => 0x00A7 for the judge glyph');
            my @sec = ($line =~ /(\xA7)/g);
            is(scalar(@sec), 0, 'AC50: the status.judge declaration line itself contains no literal section-sign byte (0xA7)');
        }
    }
}

# --- AC51 (D9, D10) ------------------------------------------------------------
{
    ok(-f File::Spec->rel2abs("$Bin/66-dashboard-screen.t"), 'AC51 precondition: 66-dashboard-screen.t exists');
  SKIP: {
        skip('not found', 2) unless -f File::Spec->rel2abs("$Bin/66-dashboard-screen.t");
        my ($rc, $out) = run_test_file('66-dashboard-screen.t');
        is($rc, 0, 'AC51: 66-dashboard-screen.t exits 0') or diag(' tail: ' . substr($out, -2000));
        my @notok = ($out =~ /^not ok.*$/mg);
        is(scalar(@notok), 0, 'AC51: 66-dashboard-screen.t has zero not ok lines (AC-P2\'s clock class stays absent)') or diag(' ' . join("\n ", @notok));
    }
}

# --- AC52 (statusline-block-fresh) ------------------------------------------------------------
{
    my $sl_path = File::Spec->rel2abs("$Bin/../../../../scripts/statusline.pl");
    ok(-f $sl_path, "AC52 precondition: statusline.pl exists at $sl_path");
  SKIP: {
        skip('not found', 2) unless -f $sl_path;
        my $raw = slurp($sl_path);
        my $markers = Theme::generated_markers();
        ok(ref($markers) eq 'HASH' && defined($markers->{begin}) && defined($markers->{end}),
            'AC52 precondition: Theme::generated_markers() returns begin/end markers');
      SKIP: {
            skip('no markers', 1) unless ref($markers) eq 'HASH' && defined($markers->{begin}) && defined($markers->{end});
            my $payload = _extract_block_between_markers($raw, $markers->{begin}, $markers->{end});
            ok(defined($payload), 'AC52 precondition: a GENERATED block is present between the markers in statusline.pl');
          SKIP: {
                skip('no block found', 1) unless defined($payload);
                is($payload, Theme::generated_block(),
                    'AC52: Theme::generated_block() equals the block embedded in statusline.pl -- adding one glyph changes no role, so unchanged');
            }
        }
    }
}

done_testing();
