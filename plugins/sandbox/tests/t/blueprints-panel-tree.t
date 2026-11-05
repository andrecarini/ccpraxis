#!/usr/bin/env perl
# platform: any
# REWRITTEN for blueprint blueprints-panel-redesign,
# package 01-run-blocks (specs/01-run-blocks-spec.md; reports/decisions/10.md
# rulings A-K; blueprint.md Decision 11 C4). This file used to pin the agent
# TREE renderer (_tree_lines, _orchestrator_line, _package_tree_lines,
# _agent_row) that ruling A deletes outright, and a per-run TABLE row
# (_one_run_summary_cells / _BLUEPRINT_TABLE_OPTS) that the same ruling
# removes. Ruling J collapses every agent row into the owning package line's
# dot and step -- there is no per-agent "row", "level" or "indent" left to
# pin, so most of the old ACs have no 1:1 target in the new grammar.
#
# What happened to each old AC (full list, so the mapping is auditable):
#   KEPT verbatim (generic Theme/source contracts the redesign does not
#   touch; spec S5.1's own row for this file says so explicitly for
#   AC30/AC32/AC33): AC25 (_agent_live, kept sub), AC29, AC30, AC32, AC46
#   (_tree_now, kept sub), AC49, AC50, AC52.
#   RETARGETED (the underlying behaviour still has to be true of
#   _run_block/_run_summary_lines, just expressed in the new line grammar):
#   AC5, AC6, AC7, B4, AC8, AC9, AC12-AC17 (merged into one driver-line-
#   without-thread suite), AC18, AC20, AC21, AC22, AC23, AC24, AC26, AC27,
#   AC33 (second half), AC36, AC37, AC39, AC40, AC41, AC42, AC44, AC45
#   (colon half only), AC47, AC48, AC54.
#   DELETED -- ruling A removes the subject outright, and the surviving
#   behaviour is already byte-exact-pinned by dashboard-blueprints-blocks.t
#   (the new primary oracle for this package), or is structurally
#   impossible under the new flat (no agent-sub-level) line grammar:
#     AC1, AC2  -- the table row + 8-row agent tree golden capture. Subject
#       (_run_summary_lines returning table+tree rows) no longer exists;
#       the equivalent block rendering is dashboard-blueprints-blocks.t F1/F8.
#     AC3, AC4  -- per-row indent-level structure (2/4/6). Ruling J: there
#       are no agent sub-levels left to have an indent.
#     AC10 -- _BLUEPRINT_TABLE_OPTS / _one_run_summary_cells. Ruling A
#       removes both subs; blueprints-table.t covers the table's removal.
#     AC19/AC45 half ("no row at indent>=4 contains 'attempt'") -- there is
#       no indent>=4 row any more (ruling J); the surviving colon-check half
#       of AC19/AC45 is kept below.
#     AC28 -- per-agent-row judge/worker distinction at fixed indents.
#       Ruling J's replacement (worker segments before judge segments
#       inside ONE package line, judge dot via _judge_marker) is pinned by
#       dashboard-blueprints-blocks.t F8 and its AC8 precedence table.
#     AC34, AC35 -- the closed set of agent-row label words / absence of
#       hardcoded role-word literals. Ruling J: worker/judge labels now come
#       straight from worker_type (minus bp-/-judge), so there is no closed
#       label-word set and no hardcoded-literal concern left to guard.
#     AC38 -- "a blocked package's second row is the worker row, not a
#       coordinator row". Ruling J (BLOCKED detail, spec S2.3.6): a blocked
#       line NEVER lists agents at all now, which is exactly what
#       dashboard-blueprints-blocks.t F7 already pins (03-gamma carries a
#       live worker agent and still renders only "blocked waiting on ...").
#     AC43 -- word-survival-under-wrap using the now-dead CF() golden rows.
#       Superseded by dashboard-blueprints-blocks.t AC19 (same property, new
#       fixture, more widths).
#     AC53 -- a wrapped agent row's continuation landing on the WRONG agent
#       sub-level (hierarchy inversion). Structurally impossible now: block
#       lines are flat siblings (blueprint/driver/package/judge/next), none
#       nests inside another, so there is no "wrong level" left to land on.
#     The two trailing "package-13 regression" blocks (thread line placed
#       right after the table row; CF() with no thread key unaffected) --
#       ruling A/Decision 1's line order (S2.3.9: blueprint, then driver,
#       then package/judge/next) makes the driver line ALWAYS the second
#       line when present, which every threaded fixture in
#       dashboard-blueprints-blocks.t (F1, F3, F5b, F6, F6b) already pins.
#
# SUPERSEDED IN PART BY OPERATOR DECISION (2026-11-05, the Blueprints panel
# rework -- see .ccpraxis-local-data/mockups/panel-work-report.md): there is
# no driver row (the driver is on the blueprint line), and a package row no
# longer lists its agents by label -- its live workers feed the step-time
# column (oldest live worker), its live coordinator the total column, its
# live judge the dot. So the staleness-filter ACs (AC22-AC27) now observe the
# filter through _package_live_agents and the step-time column instead of a
# rendered worker label, and the label-only ACs (AC5 order, AC33 judge label,
# AC41/AC42 worker label) are retargeted to what a package row still shows.
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

use lib "$Bin/../../scripts";

require Dashboard;
require tui::DashboardScreen;
require Theme;

my $NOW = 1_800_000_000;

# JUDGE_MARKER: resolved exactly as the renderer must (Theme::glyph), never
# hardcoded.
my $JUDGE_MARKER = Theme::glyph('status.judge');
$JUDGE_MARKER = '' unless defined $JUDGE_MARKER;

# ===========================================================================
# Scaffolding (reused from dashboard-blueprints-blocks.t's own conventions
# where convenient; this file does not edit that one).
# ===========================================================================

sub G { my ($name) = @_; return Theme::glyph($name) // ''; }
sub S { return ' ' x $_[0]; }

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

sub deep { return dclone($_[0]) }

sub mk_agent {
    my (%o) = @_;
    return { id => $o{id}, role => $o{role}, worker_type => $o{worker_type},
             started_at => $o{started_at}, budget_seconds => $o{budget_seconds} // 1800,
             stale_after_seconds => $o{stale_after_seconds} // 7200 };
}

# call_ds / call1 -- symbolic-ref call so an undefined sub degrades to a
# clean string error rather than aborting the whole file (this suite's own
# established convention).
sub call_ds {
    my ($name, @args) = @_;
    no strict 'refs';
    my @res;
    my $ok = eval { @res = &{"tui::DashboardScreen::$name"}(@args); 1 };
    my $err = $ok ? '' : (defined($@) && length($@) ? $@ : 'unknown error');
    return (\@res, $err);
}
sub call1 { my ($name, @args) = @_; my ($r, $e) = call_ds($name, @args); return ($r->[0], $e); }

# row_text($row) -- concatenated text of a bare span array (a row returned
# by _run_summary_lines).
sub row_text {
    my ($row) = @_;
    return '' unless ref($row) eq 'ARRAY';
    return join('', map { (ref($_) eq 'HASH' && defined($_->{text}) && !ref($_->{text})) ? $_->{text} : '' } @$row);
}
sub rows_text { my ($rows) = @_; return [] unless ref($rows) eq 'ARRAY'; return [ map { row_text($_) } @$rows ]; }

# block_lines($summary, $now, $width) -- _run_block's lines, unwrapped.
sub block_lines {
    my ($summary, $now, $width) = @_;
    my ($block, $err) = call1('_run_block', $summary, $now, $width);
    return ([], $err) unless !$err && ref($block) eq 'HASH' && ref($block->{lines}) eq 'ARRAY';
    return ($block->{lines}, $err);
}
# line_by_kind($lines, $kind) -- first line of that kind, or undef.
sub line_by_kind {
    my ($lines, $kind) = @_;
    return undef unless ref($lines) eq 'ARRAY';
    for my $l (@$lines) { return $l if ref($l) eq 'HASH' && ($l->{kind} // '') eq $kind; }
    return undef;
}
sub lines_by_kind {
    my ($lines, $kind) = @_;
    return [] unless ref($lines) eq 'ARRAY';
    return [ grep { ref($_) eq 'HASH' && ($_->{kind} // '') eq $kind } @$lines ];
}
sub spans_text { my ($line) = @_; return '' unless ref($line) eq 'HASH' && ref($line->{spans}) eq 'ARRAY'; return row_text($line->{spans}); }

# _comment_stripped / _balanced_braces / _sub_body -- reused from this
# suite's own established detector shapes.
sub _comment_stripped {
    my ($src) = @_;
    return '' unless defined $src;
    return join("\n", map { /^\s*#/ ? '' : $_ } split /\n/, $src, -1);
}
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

sub base_state { my (%o) = @_; return { project_name => 'zqxproj187', container => 'zqxctr187', status => 'running', %o }; }
sub panel_by_title {
    my ($panels, $title) = @_;
    return undef unless ref($panels) eq 'ARRAY';
    for my $p (@$panels) { return $p if ref($p) eq 'HASH' && defined($p->{title}) && $p->{title} eq $title; }
    return undef;
}
sub line_text_arr { my ($line) = @_; return '' unless ref($line) eq 'ARRAY'; return join('', map { defined($_->{text}) ? $_->{text} : '' } @$line); }
sub panel_line_texts { my ($panel) = @_; return [] unless $panel && ref($panel->{lines}) eq 'ARRAY'; return [ map { line_text_arr($_) } @{ $panel->{lines} } ]; }
sub plain { my ($c) = @_; my $t = $c->{text}; return '' unless defined $t; $t =~ s/\x1b\[[0-9;]*m//g; return $t; }
sub frame_text { my ($f) = @_; return '' unless ref($f) eq 'ARRAY'; return join("\n", map { plain($_) } @$f) }

my $SCRIPTS = File::Spec->rel2abs("$Bin/../../scripts");

# ===========================================================================
# KEPT -- generic Theme/source contracts the redesign does not touch
# (spec S5.1's row for this file: AC30/AC32/AC33 "kept").
# ===========================================================================

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

# --- AC32 (D4, D9) ---------------------------------------------------------
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

        my $sub_start = index($scanned, 'sub _judge_marker');
        ok($sub_start >= 0, 'AC32 precondition: a sub _judge_marker exists in the source');
      SKIP: {
            skip('no sub found', 2) unless $sub_start >= 0;
            my $next_sub = index($scanned, "\nsub ", $sub_start + 1);
            $next_sub = length($scanned) if $next_sub < 0;
            my $marker_sub_src = substr($scanned, $sub_start, $next_sub - $sub_start);
            ok(($marker_sub_src !~ /\btitle\./ ? 1 : 0), 'AC32: sub _judge_marker itself names no title.* token');
            my $call_pos = index($scanned, "Theme::glyph('status.judge')");
            ok($call_pos >= $sub_start && $call_pos < $next_sub,
                'AC32: the sole Theme::glyph(status.judge) call site sits inside sub _judge_marker');
        }
    }
}

# --- AC25 (CF2, kept sub _agent_live) --------------------------------------
{
    my @hostile = (['undef', undef], ["'x'", 'x'], ['[]', []], ["bless({},'X')", bless({}, 'X')], ['{}', {}]);
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

# --- AC46 (D1, S1.4, kept sub _tree_now) -----------------------------------
{
    my ($v1, $e1) = call1('_tree_now', { now => 1800000000 });
    ok(!$e1, 'AC46 (now=1800000000 Int): does not die') or diag(" error: $e1");
    is($v1, 1800000000, 'AC46: returns the integer for now=>1800000000');

    my ($v2, $e2) = call1('_tree_now', { now => '1800000000' });
    ok(!$e2, "AC46 (now='1800000000' str): does not die") or diag(" error: $e2");
    is($v2, 1800000000, "AC46: returns the integer for now=>'1800000000' (string)");

    my @undef_cases = (
        ['absent', {}], ['undef', { now => undef }], ['0', { now => 0 }], ['-1', { now => -1 }],
        ["'abc'", { now => 'abc' }], ['1.5', { now => 1.5 }], ["'1e9'", { now => '1e9' }],
        ['[]', { now => [] }], ['{}', { now => {} }], ['13-digit', { now => 1234567890123 }],
        ["bless({},'X')", { now => bless({}, 'X') }],
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

# --- AC49 (D10) -------------------------------------------------------------
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

# --- AC50 (D9) ---------------------------------------------------------------
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
        my ($line) = ($raw =~ /^([^\n]*'status\.judge'[^\n]*)$/m);
        ok(defined($line), 'AC50 precondition: a status.judge declaration line is found in Theme.pm');
      SKIP: {
            skip('no declaration line found', 2) unless defined($line);
            ok(($line =~ /cp\s*=>\s*0x00A7/i ? 1 : 0), 'AC50: the status.judge line declares cp => 0x00A7 for the judge glyph');
            my @sec = ($line =~ /(\xA7)/g);
            is(scalar(@sec), 0, 'AC50: the status.judge declaration line itself contains no literal section-sign byte (0xA7)');
        }
    }
}

# --- AC52 (statusline-block-fresh) ------------------------------------------
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
            my $b = index($raw, $markers->{begin});
            my $e = index($raw, $markers->{end});
            ok($b >= 0 && $e > $b, 'AC52 precondition: a GENERATED block is present between the markers in statusline.pl');
          SKIP: {
                skip('no block found', 1) unless $b >= 0 && $e > $b;
                my $line_end = index($raw, "\n", $b);
                my $payload = substr($raw, $line_end + 1, $e - $line_end - 1);
                is($payload, Theme::generated_block(),
                    'AC52: Theme::generated_block() equals the block embedded in statusline.pl -- adding one glyph changes no role, so unchanged');
            }
        }
    }
}

# ===========================================================================
# RETARGETED -- package ACTIVE/BLOCKED detail (spec S2.3.6)
# ===========================================================================

# --- AC18-retargeted (step word + attempt N/M in the ACTIVE detail) -------
{
    my $pkg = { name => '04-agent-records', status => 'running', attempt => 2, attempt_cap => 5,
                step_word => 'implementation', agents => [] };
    my $s = { blueprint => 'bp18', state => 'running', packages => [$pkg], run_agents => [] };
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef, $NOW) };
    ok(!$@, 'AC18: _run_summary_lines does not die') or diag("  \$\@ = $@");
  SKIP: {
        skip('no rows', 1) unless ref($rows) eq 'ARRAY' && @$rows >= 2;
        # CHANGED 2026-11-05 (operator): the dot leads the row and is the
        # muted idle one, because nothing live backs this package (no agents,
        # no coordinator verdict); the name is cut to 16 columns; the attempt
        # is labelled "attempt N/M" so it cannot be read as step progress.
        is(row_text($rows->[1]), S(2) . G('status.idle') . ' 04-agent-records' . S(3) . 'implementation' . S(3) . 'attempt 2/5',
            'AC18: the package line carries step_word and "attempt N/M" (attempt 2 >= 2)');
    }
}

# --- AC20-retargeted (N/M presence/role rule, ruling D) --------------------
{
    my @cases = (
        [2, 5, 1, 'text.primary'], [5, 5, 1, 'state.warn'], [7, 5, 1, 'state.warn'],
        [1, 5, 0, undef], [0, 5, 0, undef], [undef, 5, 0, undef], [2, undef, 0, undef],
        [undef, undef, 0, undef], ['a', 5, 0, undef], [2, 'b', 0, undef], [[], 5, 0, undef],
    );
    for my $c (@cases) {
        my ($att, $cap, $present, $role) = @$c;
        my $pkg = { name => 'pkg-ac20', status => 'running', attempt => $att, attempt_cap => $cap,
                    step_word => 'scout', agents => [] };
        my $s = { blueprint => 'bp20', state => 'running', packages => [$pkg], run_agents => [] };
        my $alab = defined($att) ? (ref($att) ? ref($att) . '-ref' : "'$att'") : 'undef';
        my $clab = defined($cap) ? (ref($cap) ? ref($cap) . '-ref' : "'$cap'") : 'undef';
        my $rows = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef, $NOW) };
        ok(!$@, "AC20 (attempt=$alab/$clab): does not die") or diag("  \$\@ = $@");
      SKIP: {
            skip('no rows', 1) unless ref($rows) eq 'ARRAY' && @$rows >= 2;
            my $text = row_text($rows->[1]);
            if ($present) {
                like($text, qr/\bscout   attempt \Q$att\E\/\Q$cap\E\z/, "AC20 (attempt=$alab/$cap): the N/M clause is present and correct");
            } else {
                unlike($text, qr{\d+/\d+}, "AC20 (attempt=$alab/$clab): no N/M clause present");
            }
          SKIP: {
                skip('no N/M expected', 1) unless $present;
                my ($nm_span) = grep { ref($_) eq 'HASH' && defined($_->{text}) && $_->{text} =~ m{^\Q$att\E/\Q$cap\E\z} } @{ $rows->[1] };
                is($nm_span ? $nm_span->{role} : undef, $role, "AC20 (attempt=$alab/$cap): N/M span role is $role")
                    if $nm_span;
            }
        }
    }
}

# --- AC21-retargeted (STEP fallback chain and the 32-byte bound) -----------
{
    my @cases = (
        ['step_word present', { step_word => 'tests', status => 'running' }, 'tests'],
        ['step_word undef, status fallback', { step_word => undef, status => 'reviewing' }, 'reviewing'],
        ['both undef, running fallback', { step_word => undef, status => undef }, 'running'],
        ['step_word 40 bytes, bounded to 32', { step_word => ('x' x 40), status => 'running' }, ('x' x 32)],
    );
    for my $c (@cases) {
        my ($label, $extra, $expect) = @$c;
        my $pkg = { name => 'pkg-ac21', agents => [], %$extra };
        $pkg->{status} = 'running' unless defined $pkg->{status};
        my $s = { blueprint => 'bp21', state => 'running', packages => [$pkg], run_agents => [] };
        my $rows = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef, $NOW) };
        ok(!$@, "AC21 ($label): does not die") or diag("  \$\@ = $@");
      SKIP: {
            skip('no rows', 1) unless ref($rows) eq 'ARRAY' && @$rows >= 2;
            like(row_text($rows->[1]), qr/\Q$expect\E/, "AC21 ($label): STEP renders as '$expect'");
        }
    }
}

# --- AC22/AC23/AC24/AC26/AC27/AC54-retargeted (staleness filter, CF2) ------
{
    my $nonce3 = 'nonce-ac22-stale-w3-9f2c';
    my $pkg = { name => 'pkg-ac22', status => 'running', agents => [
        mk_agent(id=>'w1', role=>'worker', worker_type=>'nonce-ac22-w1', started_at=>$NOW-7199, stale_after_seconds=>7200),
        mk_agent(id=>'w2', role=>'worker', worker_type=>'nonce-ac22-w2', started_at=>$NOW-7200, stale_after_seconds=>7200),
        mk_agent(id=>'w3', role=>'worker', worker_type=>$nonce3,        started_at=>$NOW-7201, stale_after_seconds=>7200),
    ] };
    is($NOW - $pkg->{agents}[0]{started_at}, 7199, 'AC22 precondition: w1 is exactly 7199s old');
    is($NOW - $pkg->{agents}[1]{started_at}, 7200, 'AC22 precondition: w2 is exactly 7200s old (the boundary itself)');
    is($NOW - $pkg->{agents}[2]{started_at}, 7201, 'AC22 precondition: w3 is exactly 7201s old (one second past)');
    my $s = { blueprint => 'bp22', state => 'running', packages => [$pkg], run_agents => [] };
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef, $NOW) };
    ok(!$@, 'AC22: does not die') or diag("  \$\@ = $@");
    my @live = tui::DashboardScreen::_package_live_agents($pkg, $NOW);
    is_deeply([ map { $_->{id} } @live ], [ 'w1', 'w2' ],
        'AC22: the live set is w1 (7199s) and w2 (exactly 7200s, the boundary itself) -- w3 (7201s) is out');
  SKIP: {
        skip('no rows', 2) unless ref($rows) eq 'ARRAY' && @$rows >= 2;
        my $t = row_text($rows->[1]);
        like($t, qr/\s2h\z/, 'AC22: the step time is the oldest LIVE worker\'s (w2, 7200s -> 2h)');
        is(substr($t, 2, length(G('status.ok'))), G('status.ok'), 'AC22: the live workers make the dot green');
    }
    my $only_stale = { name => 'pkg-ac22s', status => 'running', agents => [ $pkg->{agents}[2] ] };
    my $rows_s = eval { tui::DashboardScreen::_run_summary_lines([ { blueprint => 'bp22s', state => 'running',
        packages => [$only_stale], run_agents => [] } ], undef, undef, $NOW) };
  SKIP: {
        skip('no rows', 1) unless ref($rows_s) eq 'ARRAY' && @$rows_s >= 2;
        is(row_text($rows_s->[1]), S(2) . G('status.idle') . ' pkg-ac22s' . S(3) . 'running',
            'AC22: a package whose only worker is one second stale shows no step time and an idle dot');
    }
}
{
    my @variants = (
        ['absent',  { id=>'x', role=>'worker', worker_type=>'zqxbad23', started_at=>$NOW-100 } ],
        ['undef',   { id=>'x', role=>'worker', worker_type=>'zqxbad23', started_at=>$NOW-100, stale_after_seconds=>undef } ],
        ['0',       { id=>'x', role=>'worker', worker_type=>'zqxbad23', started_at=>$NOW-100, stale_after_seconds=>0 } ],
        ['-1',      { id=>'x', role=>'worker', worker_type=>'zqxbad23', started_at=>$NOW-100, stale_after_seconds=>-1 } ],
        ["'abc'",   { id=>'x', role=>'worker', worker_type=>'zqxbad23', started_at=>$NOW-100, stale_after_seconds=>'abc' } ],
    );
    for my $v (@variants) {
        my ($label, $bad) = @$v;
        my $sibling = mk_agent(id=>'y', role=>'worker', worker_type=>'zqxlive23', started_at=>$NOW-100);
        my $pkg = { name => 'pkg-ac23', status => 'running', agents => [$bad, $sibling] };
        my $s = { blueprint => 'bp23', state => 'running', packages => [$pkg], run_agents => [] };
        my $rows = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef, $NOW) };
        ok(!$@, "AC23 (stale_after_seconds=$label): does not die") or diag("  \$\@ = $@");
      SKIP: {
            skip('no rows', 2) unless ref($rows) eq 'ARRAY' && @$rows >= 2;
            my @live = tui::DashboardScreen::_package_live_agents($pkg, $NOW);
            is_deeply([ map { $_->{id} } @live ], [ 'y' ], "AC23 (stale_after_seconds=$label): the malformed agent is not live, its sibling is");
            like(row_text($rows->[1]), qr/\s1m\z/, "AC23 (stale_after_seconds=$label): the step time is the live sibling's (100s -> 1m)");
        }
    }
}
{
    my @variants = (
        ['absent', { id=>'x', role=>'worker', worker_type=>'zqxbad24', stale_after_seconds=>7200 } ],
        ['undef',  { id=>'x', role=>'worker', worker_type=>'zqxbad24', started_at=>undef, stale_after_seconds=>7200 } ],
        ["'abc'",  { id=>'x', role=>'worker', worker_type=>'zqxbad24', started_at=>'abc',  stale_after_seconds=>7200 } ],
    );
    for my $v (@variants) {
        my ($label, $bad) = @$v;
        my $sibling = mk_agent(id=>'y', role=>'worker', worker_type=>'zqxlive24', started_at=>$NOW-100);
        my $pkg = { name => 'pkg-ac24', status => 'running', agents => [$bad, $sibling] };
        my $s = { blueprint => 'bp24', state => 'running', packages => [$pkg], run_agents => [] };
        my $rows = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef, $NOW) };
        ok(!$@, "AC24 (started_at=$label): does not die") or diag("  \$\@ = $@");
      SKIP: {
            skip('no rows', 2) unless ref($rows) eq 'ARRAY' && @$rows >= 2;
            like(row_text($rows->[1]), qr/\s1m\z/, "AC24 (started_at=$label) precondition: the live sibling's step time is rendered");
            my @live = tui::DashboardScreen::_package_live_agents($pkg, $NOW);
            is_deeply([ map { $_->{id} } @live ], [ 'y' ], "AC24 (started_at=$label): the malformed agent is not live");
        }
    }
}
{
    # AC26/AC54: a 'done' package whose only agent is stale/decade-future
    # contributes NO package line at all (no live agent, non-active status).
    my $stale_agent = mk_agent(id=>'c1', role=>'worker', worker_type=>'zqxac26', started_at=>$NOW-100_000);
    cmp_ok($NOW - $stale_agent->{started_at}, '>', $stale_agent->{stale_after_seconds},
        'AC26 precondition: the fixture agent is indeed stale (elapsed > stale_after_seconds)');
    my $decade_future = mk_agent(id=>'w', role=>'worker', worker_type=>'zqxfuture54', started_at=>$NOW+315_360_000);

    for my $case (['stale agent', $stale_agent], ['decade-future agent (AC54, H2)', $decade_future]) {
        my ($label, $agent) = @$case;
        my $pkg_done = { name => 'pkg-ac26', status => 'done', agents => [$agent] };
        my $s = { blueprint => 'bp26', state => 'running', packages => [$pkg_done], run_agents => [] };
        my $rows = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef, $NOW) };
        ok(!$@, "AC26/AC54 ($label, status=done): does not die") or diag("  \$\@ = $@");
        is(scalar(@{ $rows || [] }), 1, "AC26/AC54 ($label, status=done): only the blueprint line -- no package line, no false in-flight promotion");
    }

    my $pkg_run = { name => 'pkg-ac26', status => 'running', agents => [$stale_agent] };
    my $s_run = { blueprint => 'bp26b', state => 'running', packages => [$pkg_run], run_agents => [] };
    my $rows_run = eval { tui::DashboardScreen::_run_summary_lines([$s_run], undef, undef, $NOW) };
    ok(!$@, 'AC26 (status=running): does not die') or diag("  \$\@ = $@");
  SKIP: {
        skip('wrong row count', 1) unless ref($rows_run) eq 'ARRAY' && @$rows_run == 2;
        is(row_text($rows_run->[1]), S(2) . G('status.idle') . ' pkg-ac26' . S(3) . 'running',
            'AC26 (status=running): the stale agent gives no time and no green dot, though the package line still renders (status-driven ACTIVE line)');
    }
}
{
    my $a = mk_agent(id=>'w', role=>'worker', worker_type=>'zqxfuture27', started_at=>$NOW+600);
    is($NOW - $a->{started_at}, -600, 'AC27 precondition: NOW - started_at is exactly -600 (ordinary clock skew)');
    my $pkg = { name => 'pkg-ac27', status => 'running', agents => [$a] };
    my $s = { blueprint => 'bp27', state => 'running', packages => [$pkg], run_agents => [] };
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef, $NOW) };
    ok(!$@, 'AC27: does not die') or diag("  \$\@ = $@");
  SKIP: {
        skip('no rows', 2) unless ref($rows) eq 'ARRAY' && @$rows >= 2;
        my $t = row_text($rows->[1]);
        is(substr($t, 2, length(G('status.ok'))), G('status.ok'), 'AC27: a 600s-ahead record (ordinary clock skew) still counts as live -- not treated as stale');
        like($t, qr/\s<1m\z/, "AC27: its elapsed token is exactly '<1m' (clamped, never negative)");
    }
}

# --- AC5/AC36-retargeted (segment order: workers then judges; agents() -----
# --- order preserved within each group; coordinators never shown) ---------
{
    my $pkg = { name => 'pkg-ac5', status => 'running', agents => [
        mk_agent(id=>'j',  role=>'judge',       worker_type=>'bp-zqxj5-judge', started_at=>$NOW-100),
        mk_agent(id=>'w1', role=>'worker',      worker_type=>'bp-zqxw5a',      started_at=>$NOW-100),
        mk_agent(id=>'c',  role=>'coordinator', worker_type=>undef,            started_at=>$NOW-100),
        mk_agent(id=>'w2', role=>'worker',      worker_type=>'bp-zqxw5b',      started_at=>$NOW-100),
    ] };
    my $s = { blueprint => 'bp5', state => 'running', packages => [$pkg], run_agents => [] };
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef, $NOW) };
    ok(!$@, 'AC5: does not die') or diag("  \$\@ = $@");
  SKIP: {
        skip('no rows', 1) unless ref($rows) eq 'ARRAY' && @$rows >= 2;
        my $text = row_text($rows->[1]);
        # Operator layout (2026-11-05): the judge is the dot, the coordinator
        # the total (1m), the workers the step time (1m); no agent label.
        is($text, S(2) . G('status.judge') . ' pkg-ac5 1m   running   1m',
            'AC5: judge -> dot, coordinator -> total, workers -> step time, and no agent is named');
        unlike($text, qr/zqx|\bcoordinator\b/, 'AC5/scope: no agent label or role word appears on the package row');
        is(scalar(@$rows), 2, 'AC5/scope: the agents add no rows of their own');
    }
}

# --- AC37-retargeted (a coordinator-only package has NO segment at all) ---
{
    my $pkg = { name => 'pkg-ac37', status => 'running', step_word => 'scout',
                agents => [ mk_agent(id=>'c1', role=>'coordinator', worker_type=>undef, started_at=>$NOW-1860) ] };
    my $s = { blueprint => 'bp37', state => 'running', packages => [$pkg], run_agents => [] };
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef, $NOW) };
    ok(!$@, 'AC37: does not die') or diag("  \$\@ = $@");
  SKIP: {
        skip('no rows', 1) unless ref($rows) eq 'ARRAY' && @$rows >= 2;
        is(row_text($rows->[1]), S(2) . G('status.ok') . ' pkg-ac37 31m   scout',
            'AC37: a coordinator-only package shows the coordinator\'s run time as its total and no step time -- the coordinator is never named');
    }
}

# ===========================================================================
# RETARGETED -- blueprint-wide judge lines and run_agents filtering
# (spec S2.3.7, ruling J "non-judge run_agents are not rendered")
# ===========================================================================

# --- AC6-retargeted (judge lines in run_agents order; non-judges excluded) -
{
    my $s = { blueprint => 'bp6', state => 'running', packages => [],
        run_agents => [
            mk_agent(id=>'c',  role=>'coordinator', worker_type=>'zqxrc6',        started_at=>$NOW-100),
            mk_agent(id=>'j1', role=>'judge',       worker_type=>'bp-zqxrj6a-judge', started_at=>$NOW-100),
            mk_agent(id=>'w',  role=>'worker',      worker_type=>'zqxrw6',        started_at=>$NOW-100),
            mk_agent(id=>'j2', role=>'judge',       worker_type=>'bp-zqxrj6b-judge', started_at=>$NOW-100),
            mk_agent(id=>'u',  role=>'admiral',     worker_type=>'zqxru6',        started_at=>$NOW-100),
        ],
    };
    my ($lines, $err) = block_lines($s, $NOW, undef);
    ok(!$err, 'AC6: _run_block does not die') or diag("  error: $err");
    my $judges = lines_by_kind($lines, 'judge');
    is(scalar(@$judges), 2, 'AC6: exactly two judge lines (the two live judges) -- non-judge run_agents render no line at all');
  SKIP: {
        skip('wrong judge count', 1) unless scalar(@$judges) == 2;
        like(spans_text($judges->[0]), qr/zqxrj6a/, 'AC6: the first judge line is the FIRST live judge in run_agents order');
        like(spans_text($judges->[1]), qr/zqxrj6b/, 'AC6: the second judge line is the SECOND live judge in run_agents order');
    }
    my $all_text = join("\n", map { spans_text($_) } @$lines);
    for my $nonce (qw(zqxrc6 zqxrw6 zqxru6)) {
        unlike($all_text, qr/\Q$nonce\E/, "AC6: the non-judge run_agents entry ($nonce) contributes NO line anywhere in the block");
    }
}

# ===========================================================================
# RETARGETED -- the driver-line-without-a-thread (spec S2.3.5), folding the
# old AC12-AC17 (direct _orchestrator_line calls) into one suite against
# _run_block's "driver" line.
# ===========================================================================

{
    my @cases = (
        ['1 -> ok/alive',   1,     'status.ok',   'state.ok'],
        ['0 -> crit/dead',  0,     'status.crit', 'state.crit'],
        ['undef -> idle',   undef, 'status.idle', 'text.muted'],
        ["'' -> idle",      '',    'status.idle', 'text.muted'],
        ["'yes' -> idle",   'yes', 'status.idle', 'text.muted'],
        ['[] -> idle',      [],    'status.idle', 'text.muted'],
    );
    for my $c (@cases) {
        my ($label, $alive, $glyph_name, $role) = @$c;
        my $s = { blueprint => 'bp-drv', state => 'running', orchestrator_pid => 4242,
                  orchestrator_alive => $alive, orchestrator_started_at => $NOW - 600,
                  running_coordinators => 0, packages => [], run_agents => [] };
        my ($lines, $err) = block_lines($s, $NOW, undef);
        ok(!$err, "AC12-17 driver ($label): _run_block does not die") or diag("  error: $err");
        # The driver is on the blueprint line now (operator, 2026-11-05).
        my $driver = line_by_kind($lines, 'blueprint');
        ok(defined($driver), "AC12-17 driver ($label) precondition: the blueprint line carrying the driver is present");
      SKIP: {
            skip('no driver line', 2) unless defined $driver;
            my ($glyph_span) = grep { ref($_) eq 'HASH' && defined($_->{text}) && $_->{text} eq G($glyph_name) } @{ $driver->{spans} };
            ok(defined($glyph_span), "AC12-17 driver ($label): the dot glyph is $glyph_name") if length(G($glyph_name));
            is($glyph_span ? $glyph_span->{role} : undef, $role, "AC12-17 driver ($label): the dot's role is $role") if $glyph_span;
        }
    }

    # AC16-retargeted: a future orchestrator_started_at means _block_elapsed
    # is negative -> undef per spec S2.2's _block_elapsed contract -> the
    # caller omits the uptime token entirely (never "<1m", never negative).
    {
        my $s = { blueprint => 'bp-drv2', state => 'running', orchestrator_pid => 4242,
                  orchestrator_alive => 1, orchestrator_started_at => $NOW + 86_400,
                  running_coordinators => 0, packages => [], run_agents => [] };
        my ($lines, $err) = block_lines($s, $NOW, undef);
        ok(!$err, 'AC16: _run_block does not die') or diag("  error: $err");
        my $driver = line_by_kind($lines, 'blueprint');
        ok(defined($driver), 'AC16 precondition: the blueprint line is present');
      SKIP: {
            skip('no driver line', 1) unless defined $driver;
            like(spans_text($driver), qr/\Q${\ G('status.ok') } orchestrator\E\z/,
                'AC16: a future orchestrator_started_at renders no uptime token at all (never "<1m", never negative)');
        }
    }

    # AC14-retargeted: when alive is not literally 1 (unknown), no uptime is
    # ever shown, however old started_at is.
    {
        my $s = { blueprint => 'bp-drv3', state => 'running', orchestrator_pid => 4242,
                  orchestrator_alive => undef, orchestrator_started_at => $NOW - 2_592_000,
                  running_coordinators => 0, packages => [], run_agents => [] };
        my ($lines, $err) = block_lines($s, $NOW, undef);
        ok(!$err, 'AC14: _run_block does not die') or diag("  error: $err");
        my $driver = line_by_kind($lines, 'blueprint');
      SKIP: {
            skip('no driver line', 1) unless defined $driver;
            like(spans_text($driver), qr/\Q${\ G('status.idle') } orchestrator   running\E\z/,
                'AC14: a 30-day-old marker for an unknown (not literally alive) orchestrator renders NO duration');
        }
    }
}

# ===========================================================================
# RETARGETED -- blueprint line STATE role (spec S2.3.1/B4), hostile
# `packages` fallback (spec S2.3.6), and basic determinism/totality.
# ===========================================================================

# --- AC8-retargeted (B4: the state word's role) -----------------------------
{
    my %expect = (running => 'state.ok', parked => 'state.warn', idle => 'text.muted',
                   stale => 'text.muted', solo => 'text.muted', 'zqx-unknown-ac8' => 'text.muted');
    for my $st (sort keys %expect) {
        my $s = { blueprint => 'bp8', state => $st, packages => [], run_agents => [] };
        my ($lines, $err) = block_lines($s, $NOW, undef);
        ok(!$err, "AC8 (state='$st'): _run_block does not die") or diag("  error: $err");
        my $bp = line_by_kind($lines, 'blueprint');
        ok(defined($bp), "AC8 (state='$st') precondition: a blueprint line is present");
      SKIP: {
            skip('no blueprint line', 1) unless defined $bp;
            my ($state_span) = grep { ref($_) eq 'HASH' && defined($_->{text}) && $_->{text} eq $st } @{ $bp->{spans} };
            is($state_span ? $state_span->{role} : undef, $expect{$st}, "AC8 (state='$st'): role is $expect{$st} (B4)");
        }
    }
    # '?' for an absent/undef state.
    my $s_u = { blueprint => 'bp8u', state => undef, packages => [], run_agents => [] };
    my ($lines_u, $err_u) = block_lines($s_u, $NOW, undef);
    ok(!$err_u, 'AC8 (state=undef): _run_block does not die') or diag("  error: $err_u");
    my $bp_u = line_by_kind($lines_u, 'blueprint');
  SKIP: {
        skip('no blueprint line', 1) unless defined $bp_u;
        like(spans_text($bp_u), qr/\?\z|\?\s/, "AC8 (state=undef): the state word renders as '?'");
    }
}

# --- AC9-retargeted (hostile `packages`, no current_package -> no package --
# --- line at all; blueprint line alone, no die) -----------------------------
{
    my @variants = (
        ['key absent', sub { return { blueprint=>'bp9', state=>'running', run_agents=>[] }; }],
        ['undef',      sub { return { blueprint=>'bp9', state=>'running', packages=>undef, run_agents=>[] }; }],
        ['{}',         sub { return { blueprint=>'bp9', state=>'running', packages=>{},    run_agents=>[] }; }],
        ["'x'",        sub { return { blueprint=>'bp9', state=>'running', packages=>'x',    run_agents=>[] }; }],
        ['\\1',        sub { return { blueprint=>'bp9', state=>'running', packages=>\1,     run_agents=>[] }; }],
    );
    for my $v (@variants) {
        my ($label, $build) = @$v;
        my $s = $build->();
        my $rows = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef, $NOW) };
        ok(!$@, "AC9 (packages=$label): does not die") or diag("  \$\@ = $@");
        is(scalar(@{ $rows || [] }), 1, "AC9 (packages=$label): exactly one row -- the blueprint line, no fallback package line without current_package");
    }
}

# --- AC7-retargeted (purity: two calls equal; input unmutated) -------------
{
    my $s = { blueprint => 'bp7', state => 'running', orchestrator_pid => 4242, orchestrator_alive => 1,
              orchestrator_started_at => $NOW - 100, running_coordinators => 1,
              packages => [ { name=>'01-x', status=>'running', step_word=>'tests', agents=>[] } ],
              run_agents => [ mk_agent(id=>'j', role=>'judge', worker_type=>'bp-zqxj7-judge', started_at=>$NOW-10) ] };
    my $before = deep($s);
    my ($r1, $e1) = call1('_run_summary_lines', [$s], undef, undef, $NOW);
    my ($r2, $e2) = call1('_run_summary_lines', [$s], undef, undef, $NOW);
    ok(!$e1, 'AC7: first call does not die') or diag("  error: $e1");
    ok(!$e2, 'AC7: second call does not die') or diag("  error: $e2");
    is_deeply($r1, $r2, 'AC7: two successive calls return is_deeply-equal results (pure function)');
    is_deeply($s, $before, 'AC7: the summary is unmodified after two calls -- the renderer mutates nothing it is given');
}

# --- B4-retargeted (nothing but a driver, when packages is empty and no ----
# --- thread/judge/next exist) -----------------------------------------------
{
    my $s = { state => 'running', orchestrator_pid => 4242, orchestrator_alive => 1,
              orchestrator_started_at => $NOW - 60, running_coordinators => 0, packages => [], run_agents => [] };
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef, $NOW) };
    ok(!$@, 'B4: _run_summary_lines does not die for an orchestrator-only, package-less run') or diag("  \$\@ = $@");
    is(scalar(@{ $rows || [] }), 1, 'B4: exactly one row -- the blueprint line, which carries the driver');
  SKIP: {
        skip('wrong row count', 1) unless ref($rows) eq 'ARRAY' && @$rows == 1;
        like(row_text($rows->[0]), qr/\borchestrator 1m\z/, 'B4: the blueprint line ends in the driver and its uptime (60s -> 1m)');
    }
}

# --- AC33-retargeted (marker unavailable: _judge_marker itself unchanged; --
# --- the package/judge line still renders, without dying or warning) ------
{
    local *Theme::glyph = sub { return undef };
    my ($marker, $err0) = call1('_judge_marker');
    ok(!$err0, 'AC33: _judge_marker does not die with Theme::glyph overridden') or diag("  error: $err0");
    is($marker, '', 'AC33 precondition: with Theme::glyph overridden to return undef, _judge_marker() returns ""');

    my $j = mk_agent(id=>'j', role=>'judge', worker_type=>'bp-zqxjudge33-judge', started_at=>$NOW-100);
    my $pkg = { name => 'pkg-ac33', status => 'reviewing', agents => [$j] };
    my $s = { blueprint => 'bp33', state => 'running', packages => [$pkg], run_agents => [] };
    my (@warns, $rows, $err);
    {
        local $SIG{__WARN__} = sub { push @warns, $_[0] };
        ($rows, $err) = call1('_run_summary_lines', [$s], undef, undef, $NOW);
    }
    ok(!$err, 'AC33: _run_summary_lines does not die with the marker unavailable') or diag("  error: $err");
    ok(!@warns, 'AC33: _run_summary_lines does not warn with the marker unavailable') or diag(' warned: ' . join('; ', @warns));
  SKIP: {
        skip('no rows', 1) unless ref($rows) eq 'ARRAY' && @$rows >= 2;
        # No judge label is drawn on a package row any more; with the marker
        # unavailable the dot slot is simply empty and the row still renders.
        like(row_text($rows->[1]), qr/\Apkg-ac33|\A\s+pkg-ac33/, 'AC33: the package line still renders, its empty marker leaving only blanks before the name');
    }
}

# ===========================================================================
# RETARGETED -- robustness, scale, non-ASCII (old AC39-AC45) and bound checks
# ===========================================================================

# --- AC39-retargeted (totality across the subs this package keeps/adds) ---
{
    my @hostile = (undef, '', 0, [], {}, sub { 1 }, bless({}, 'X'));
    my %CALLS = (
        _run_block        => sub { my ($h) = @_; call1('_run_block', $h, $NOW, undef) },
        _run_summary_lines => sub { my ($h) = @_; call1('_run_summary_lines', [$h], undef, undef, $NOW) },
        _bound_display     => sub { my ($h) = @_; call1('_bound_display', $h, 64) },
        _elapsed           => sub { my ($h) = @_; call1('_elapsed', $NOW, $h) },
        _block_elapsed      => sub { my ($h) = @_; call1('_block_elapsed', $h) },
        _pause_words        => sub { my ($h) = @_; call1('_pause_words', $h) },
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
        my (undef, $rsl_err) = call1('_run_summary_lines', [$hostile_summary], undef, undef, $NOW);
        push @died, "_run_summary_lines(hostile struct): $rsl_err" if $rsl_err;
        my (undef, $rb_err) = call1('_run_block', $hostile_summary, $NOW, undef);
        push @died, "_run_block(hostile struct): $rb_err" if $rb_err;
    }
    is(scalar(@died), 0, 'AC39: none of this package\'s subs die on any hostile input (totality)') or diag(join("\n", @died));
    is(scalar(@warns), 0, 'AC39: none of this package\'s subs warn on any hostile input') or diag(join("\n", @warns));
}

# --- AC40-retargeted (scale: 40 running packages -> 40 package lines, -----
# --- order preserved, no die) ----------------------------------------------
{
    my @packages;
    for my $i (1 .. 40) {
        push @packages, { name => sprintf('pkg-ac40-%02d', $i), status => 'running', step_word => 'tests', agents => [] };
    }
    my $s = { blueprint => 'bp40', state => 'running', packages => \@packages, run_agents => [] };
    my ($lines, $err) = block_lines($s, $NOW, undef);
    ok(!$err, 'AC40: _run_block does not die on 40 packages') or diag("  error: $err");
    my $pkg_lines = lines_by_kind($lines, 'package');
    is(scalar(@$pkg_lines), 40, 'AC40: exactly 40 package lines -- one per package, no agent sub-rows under any of them');
  SKIP: {
        skip('wrong count', 1) unless scalar(@$pkg_lines) == 40;
        my @names_in_order = map { (spans_text($_) =~ /\s(pkg-ac40-\d\d)\b/) ? $1 : undef } @$pkg_lines;
        my @expected = map { sprintf('pkg-ac40-%02d', $_) } 1 .. 40;
        is_deeply(\@names_in_order, \@expected, 'AC40: package lines appear in packages[] array order');
    }
}

# --- AC41-retargeted (non-ASCII package name / worker_type round-trip) ----
{
    my $name = "andr\xC3\xA9-caf\xC3\xA9";
    my $wt   = "bp-impl\xC3\xA9menter";
    my $pkg  = { name => $name, status => 'running',
                 agents => [ mk_agent(id=>'w', role=>'worker', worker_type=>$wt, started_at=>$NOW-100) ] };
    my $s = { blueprint => 'bp41', state => 'running', packages => [$pkg], run_agents => [] };
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef, $NOW) };
    ok(!$@, 'AC41: does not die on non-ASCII package name / worker_type') or diag("  \$\@ = $@");
  SKIP: {
        skip('no rows', 2) unless ref($rows) eq 'ARRAY' && @$rows >= 2;
        like(row_text($rows->[1]), qr/\Q$name\E/, 'AC41: the package name round-trips byte-identically');
        # The worker is no longer named; it still counts (dot and step time).
        like(row_text($rows->[1]), qr/\s1m\z/, 'AC41: the non-ASCII-typed worker still feeds the step time');
    }
}

# --- AC42-retargeted (200-byte name bound, 64-byte worker-label bound) -----
{
    my $name = ('a' x 199) . "\xC3\xA9" . ('b' x 99);
    is(length($name), 300, 'AC42 precondition: fixture package name is exactly 300 bytes');
    my $pkg = { name => $name, status => 'running', agents => [] };
    my $s = { blueprint => 'bp42', state => 'running', packages => [$pkg], run_agents => [] };
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef, $NOW) };
    ok(!$@, 'AC42 (package name): does not die on a 300-byte name with a split UTF-8 sequence at the cut') or diag("  \$\@ = $@");
  SKIP: {
        skip('no rows', 3) unless ref($rows) eq 'ARRAY' && @$rows >= 2;
        my ($name_span) = grep { ref($_) eq 'HASH' && defined($_->{text}) && index($_->{text}, 'a') == 0 } @{ $rows->[1] };
        ok(defined($name_span), 'AC42 (package name) precondition: the name span is located');
      SKIP: {
            skip('span not found', 2) unless defined $name_span;
            # Ruling I/Decision 7: a name with non-empty detail is padded to
            # W+2 COLUMNS *inside the name span itself* -- here this one
            # package is the block's W-definer, with a non-empty detail
            # ('running'), so the span is the bounded name PLUS >= 2 trailing
            # pad spaces. The 200-byte bound applies to _bound_display's own
            # output (the name), not to the padded span; strip the trailing
            # pad before checking it.
            (my $name_only = $name_span->{text}) =~ s/ +\z//;
            cmp_ok(length($name_only), '<=', 200, 'AC42 (package name): the bounded package name (pad stripped) is at most 200 bytes');
            is($name_only, ('a' x 15) . G('ellipsis'), 'AC42 (package name): the drawn name is cut to 16 columns, ending in the theme ellipsis');
            my $ok_utf8 = eval { Encode::decode('UTF-8', $name_span->{text}, Encode::FB_CROAK()); 1 };
            ok($ok_utf8, 'AC42 (package name): the rendered package name decodes cleanly as UTF-8') or diag(" decode error: $@");
        }
    }

    my $wt = ('c' x 63) . "\xC3\xA9" . ('d' x 235);
    is(length($wt), 300, 'AC42 precondition: fixture worker_type is exactly 300 bytes');
    my $pkg2 = { name => 'pkg-ac42b', status => 'running',
                 agents => [ mk_agent(id=>'w', role=>'worker', worker_type=>$wt, started_at=>$NOW-100) ] };
    my $s2 = { blueprint => 'bp42b', state => 'running', packages => [$pkg2], run_agents => [] };
    my $rows2 = eval { tui::DashboardScreen::_run_summary_lines([$s2], undef, undef, $NOW) };
    ok(!$@, 'AC42 (worker_type): does not die') or diag("  \$\@ = $@");
  SKIP: {
        skip('no rows', 3) unless ref($rows2) eq 'ARRAY' && @$rows2 >= 2;
        my $text = row_text($rows2->[1]);
        like($text, qr/^(?:(?!zqx).)*\Q$pkg2->{name}\E/, 'AC42 (worker_type) precondition: the package row is present')
            if length($text);
        # Worker labels are no longer drawn on a package row, so the bound
        # is moot there; what remains true is that the oversized worker_type
        # never reaches the row at all.
        unlike($text, qr/ccc/, 'AC42 (worker_type): the oversized worker_type never reaches the package row');
        my $ok_utf8 = eval { Encode::decode('UTF-8', $text, Encode::FB_CROAK()); 1 };
        ok($ok_utf8, 'AC42 (worker_type): the package row decodes cleanly as UTF-8') or diag(" decode error: $@");
    }
}

# --- AC44-retargeted (no atomic span; no fit_spans call in the new subs) --
{
    my $pkg = { name => '04-agent-records', status => 'running', attempt => 2, attempt_cap => 5,
                step_word => 'implementation',
                agents => [ mk_agent(id=>'w1', role=>'worker', worker_type=>'bp-implementer', started_at=>$NOW-720) ] };
    my $s = { blueprint => 'bp44', state => 'running', orchestrator_pid => 4242, orchestrator_alive => 1,
              orchestrator_started_at => $NOW - 8040, running_coordinators => 1,
              packages => [$pkg], run_agents => [ mk_agent(id=>'j2', role=>'judge', worker_type=>'bp-conformance-judge', started_at=>$NOW-120) ] };
    my ($lines, $err) = block_lines($s, $NOW, undef);
    ok(!$err, 'AC44: _run_block does not die') or diag("  error: $err");
  SKIP: {
        skip('no lines', 1) unless ref($lines) eq 'ARRAY';
        my @atomic_hits;
        for my $l (@$lines) {
            next unless ref($l) eq 'HASH' && ref($l->{spans}) eq 'ARRAY';
            for my $span (@{ $l->{spans} }) {
                push @atomic_hits, $span if ref($span) eq 'HASH' && exists($span->{atomic}) && $span->{atomic};
            }
        }
        is(scalar(@atomic_hits), 0, 'AC44: no block-line span carries atomic => 1 (structural check)');
    }

    my $ds_path = File::Spec->rel2abs("$Bin/../../scripts/tui/DashboardScreen.pm");
  SKIP: {
        skip('DashboardScreen.pm not found', 2) unless -f $ds_path;
        my $scanned = _comment_stripped(slurp($ds_path));
        for my $sub_name (qw(_run_block _wrap_block_row)) {
            my $body = _sub_body($scanned, $sub_name);
            ok(defined($body), "AC44 precondition: sub $sub_name is defined in DashboardScreen.pm (so its body can be scanned)");
          SKIP: {
                skip("sub $sub_name not found", 1) unless defined $body;
                unlike($body, qr/\bfit_spans\b/, "AC44: sub ${sub_name}'s body does not call fit_spans");
            }
        }
    }
}

# --- AC45-retargeted (no colon anywhere in a representative set of blocks) -
{
    my @fixtures = (
        { blueprint => 'bp45a', state => 'running', orchestrator_pid => 4242, orchestrator_alive => 1,
          orchestrator_started_at => $NOW - 100, running_coordinators => 2,
          packages => [ { name=>'pkg-scan', status=>'running', attempt=>2, attempt_cap=>5, step_word=>'tests',
              agents => [ mk_agent(id=>'w', role=>'worker', worker_type=>'zqxscanw', started_at=>$NOW-100),
                          mk_agent(id=>'j', role=>'judge',  worker_type=>'bp-zqxscanj-judge', started_at=>$NOW-100) ] } ],
          run_agents => [ mk_agent(id=>'rj', role=>'judge', worker_type=>'bp-zqxscanrj-judge', started_at=>$NOW-100) ],
          next_package => 'pkg-next' },
    );
    my @all_rows;
    for my $s (@fixtures) {
        my $rows = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef, $NOW) };
        push @all_rows, @$rows if !$@ && ref($rows) eq 'ARRAY';
    }
    my $have_rows = scalar(@all_rows) > 0;
  SKIP: {
        skip('no rows collected (subs not implemented yet)', 1) unless $have_rows;
        my @colon_hits = grep { row_text($_) =~ /:/ } @all_rows;
        is(scalar(@colon_hits), 0, 'AC45: no block row\'s text contains ":" in any representative fixture')
            or diag(join("\n", map { row_text($_) } @colon_hits));
    }
}

# --- AC47-retargeted (the clock seam: no $now -> no uptime, no agent -------
# --- segments at all, and resume words never take the "resuming"/date form) -
{
    my $pkg = { name => '04-agent-records', status => 'running', attempt => 2, attempt_cap => 5,
                step_word => 'implementation',
                agents => [ mk_agent(id=>'w1', role=>'worker', worker_type=>'bp-implementer', started_at=>$NOW-720) ] };
    my $s = { blueprint => 'bp47', state => 'running', orchestrator_pid => 4242, orchestrator_alive => 1,
              orchestrator_started_at => $NOW - 8040, running_coordinators => 1, packages => [$pkg], run_agents => [] };
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef) };
    ok(!$@, 'AC47: _run_summary_lines(three args, no now) does not die') or diag("  \$\@ = $@");
  SKIP: {
        skip('no rows', 3) unless ref($rows) eq 'ARRAY' && @$rows == 2;
        like(row_text($rows->[0]), qr/\Q${\ G('status.ok') } orchestrator\E\z/, 'AC47: without now, the driver on the blueprint line has no uptime token');
        unlike(row_text($rows->[1]), qr/\d+[mhd]\b|<1m/, 'AC47: without now, the package line has no time at all (no agent can be judged live)');
        like(row_text($rows->[1]), qr/implementation   attempt 2\/5\z/, 'AC47: without now, the package line STILL carries its step_word and attempt (those do not need a clock)');
    }

    # Resume words: with no $now, rule 5 ("now undefined") always wins over
    # the date-form rule, for both a near and a far relaunch_at.
    for my $c (['near', $NOW + 10_800], ['far', $NOW + 777_600]) {
        my ($label, $relaunch_at) = @$c;
        my $sp = { blueprint => 'bp47p', state => 'paused', paused_reason => 'usage', paused_window => 'seven_day',
                   relaunch_at => $relaunch_at, relaunch_local => { wday=>'Mon', hhmm=>'18:05', day=>'03', mon=>'Nov' },
                   packages => [], run_agents => [] };
        my $rows_p = eval { tui::DashboardScreen::_run_summary_lines([$sp], undef, undef) };
        ok(!$@, "AC47 resume ($label, no now): does not die") or diag("  \$\@ = $@");
      SKIP: {
            skip('no rows', 2) unless ref($rows_p) eq 'ARRAY';
            unlike(row_text($rows_p->[0]), qr/resuming/, "AC47 resume ($label, no now): never 'resuming' without a now");
            like(row_text($rows_p->[0]), qr/until Mon 18:05/, "AC47 resume ($label, no now): weekday form, never the date form");
        }
    }
}

# --- AC48-retargeted ($state->{now} wiring through panels()) ---------------
{
    my $pkg = { name => '04-agent-records', status => 'running', step_word => 'tests',
                agents => [ mk_agent(id=>'w1', role=>'worker', worker_type=>'bp-test-writer', started_at=>$NOW-720) ] };
    my $run = { blueprint => 'bp48', state => 'running', packages => [$pkg], run_agents => [] };

    my $state_with = base_state(runs => [$run], now => $NOW);
    my $panels_with = tui::DashboardScreen::panels($state_with, 120);
    my $bpp_with = panel_by_title($panels_with, 'Blueprints');
    ok($bpp_with, 'AC48 precondition: Blueprints panel exists (with now)');
  SKIP: {
        skip('no panel', 1) unless $bpp_with;
        my $joined = join("\n", @{ panel_line_texts($bpp_with) });
        like($joined, qr/tests\s+12m/, 'AC48: with now => $NOW in $state, panels() Blueprints panel shows the live worker\'s step time');
    }

    my $state_without = base_state(runs => [$run]);
    my $panels_without = tui::DashboardScreen::panels($state_without, 120);
    my $bpp_without = panel_by_title($panels_without, 'Blueprints');
    ok($bpp_without, 'AC48 precondition: Blueprints panel exists (without now)');
  SKIP: {
        skip('no panel', 1) unless $bpp_without;
        my $joined = join("\n", @{ panel_line_texts($bpp_without) });
        unlike($joined, qr/12m/,
            'AC48: without now in $state, panels() Blueprints panel shows NO step time -- pins $state->{now} as the wired path');
    }
}

done_testing();
