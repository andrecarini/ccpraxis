#!/usr/bin/env perl
# platform: any
# The Blueprints panel's per-package PIPELINE STRIP (operator, 2026-11-10,
# approved against .ccpraxis-local-data/mockups/pipeline-strip-mock.pl):
#   1 labels          -- sco spe tes imp val rev fix ui hnd from the step's
#                        first word; any other word -> its first three letters
#   2 fixed columns   -- the union of a block's step words, first-seen order,
#                        one column each, one space apart; a 9-step ledger
#                        adds a column the others leave blank
#   3 skipped / n/a   -- blank space in its column; a column with no drawn
#                        step in any row of the block is dropped
#   4 styles          -- done text.muted, upcoming text.faint, current bold:
#                        step.current (accent) when live, step.current.idle
#                        otherwise; nothing but spaces between steps
#   5 time / attempt  -- the step time right-aligned after the strip, then
#                        "attempt N/M"
#   6 waiting         -- a not-started package: full strip, all upcoming, its
#                        reason in text.waiting in the time slot, never
#                        widening it
#   7 no checklist    -- a blank strip area and "no checklist" (text.waiting)
#   9 width           -- too narrow for the strip: the step word, time and
#                        attempt kept
# plus RunState passing `pipeline` through summarize_dir's package entries.
#
# Every pipeline below is parsed from ledger text by RunState's own
# _scan_pipeline, so the strip is tested on the shape the producer emits.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use File::Temp qw(tempdir);
use File::Path qw(make_path);

BEGIN {
    my $pin = File::Temp::tempdir(CLEANUP => 1);
    $ENV{HOME} = $pin; $ENV{USERPROFILE} = $pin; $ENV{ALMANAC_HOME} = $pin;
}

require Theme;
require tui::Layout;
require tui::Frame;
require tui::DashboardScreen;
require RunState;

my $NOW = 1_762_000_000;
my $EM  = "\xE2\x80\x94";

sub G { my ($n) = @_; return Theme::glyph($n) // ''; }
sub S { return ' ' x $_[0]; }
sub rows { my ($runs, $w) = @_; return tui::DashboardScreen::_run_summary_lines($runs, undef, $w, $NOW); }
sub texts { my ($r) = @_; return [ map { tui::Frame::spans_text($_) } @$r ]; }
sub dw { return tui::Layout::display_width($_[0]); }
# col($line, $needle) -> the DISPLAY column $needle starts at (the rows carry a
# multi-byte ellipsis, so a byte index is not a column).
sub col { my ($l, $n) = @_; my $i = index($l, $n); return $i < 0 ? -1 : dw(substr($l, 0, $i)); }

# ledger(@steps) -> the ledger's "## Pipeline" section, each step
# [ 'Word text', mark ] with mark x (done), ' ' (todo), 's' (ticked skipped)
# or 'n' (n/a box). Numbered from 1.
sub ledger {
    my (@steps) = @_;
    my $n = 0;
    my @l = ("---", "package: p", "status: running", "---", "# ledger", "", "## Pipeline", "");
    for my $s (@steps) {
        my ($text, $m) = @$s;
        $n++;
        push @l, $m eq 'x' ? "- [x] $n. $text"
               : $m eq 's' ? "- [x] $n. $text $EM skipped: scope maps cleanly"
               : $m eq 'n' ? "- [-] $n. $text"
               :             "- [ ] $n. $text";
    }
    return join("\n", @l, '', '## Decisions', '');
}
my @WORDS = ('Scout the terrain', 'Spec written', 'Tests written', 'Implementation converged',
             'Validation green', 'Review complete', 'Fix-batch applied', 'UI pass');
# pl($marks, %o) -> RunState pipeline. $marks is one char per template step
# (x, ' ', s, n); handoff => mark adds the ninth step.
sub pl {
    my ($marks, %o) = @_;
    my @m = split //, $marks;
    my @steps = map { [ $WORDS[$_], $m[$_] ] } 0 .. $#m;
    push @steps, [ 'Handoff to the operator', $o{handoff} ] if defined $o{handoff};
    return RunState::_scan_pipeline(ledger(@steps));
}
sub agent {
    my (%o) = @_;
    return { id => $o{id}, role => $o{role}, worker_type => $o{worker_type},
             started_at => $NOW - $o{age}, budget_seconds => 1800, stale_after_seconds => 86_400 };
}
sub pkg {
    my (%o) = @_;
    return { name => $o{name}, status => $o{status} // 'running', attempt => $o{attempt} // 1, attempt_cap => 5,
             step => undef, steps_pending => undef, next_action => undef, agents => $o{agents} // [],
             step_word => $o{step_word}, waits_on => $o{waits_on}, pipeline => $o{pipeline},
             coordinator_alive => $o{alive}, coordinator_started_at => $o{started} };
}
sub run {
    my (%o) = @_;
    return { blueprint => $o{blueprint} // 'acxpraxis-step-2', state => $o{state} // 'running',
             packages_done => 9, packages_total => 15, paused_reason => undef, paused_window => undef,
             relaunch_at => undef, relaunch_local => undef,
             orchestrator_pid => 41, orchestrator_alive => 1, orchestrator_started_at => $NOW - 108_960,
             running_coordinators => 1, inbox_waiting => 0, triage_waiting => 0,
             thread => { name => 'fleet', state => 'live', done => 0, total => 0, doing => [], current => undef,
                         owner => { kind => 'orchestrator', id => 'x', alive => 1 } },
             packages => $o{packages}, run_agents => [], next_package => $o{next_package} };
}

# The mock-up's block: 03 skipped its scout, 01 is a 9-step ledger at its
# handoff, 14 waits, z01 has no checklist. ui is skipped by every package.
my @MOCK = (
    pkg(name => '03-make-and-hooks', step_word => 'implementation', attempt => 2, alive => 1, started => $NOW - 43_440,
        pipeline => pl('sxx    s'), agents => [ agent(id => 'w1', role => 'worker', worker_type => 'bp-implementer', age => 11_520) ]),
    pkg(name => '12-model-merge', step_word => 'tests', alive => 1, started => $NOW - 15_660,
        pipeline => pl('xx     s'),
        agents => [ agent(id => 'w2', role => 'worker', worker_type => 'bp-test-writer', age => 2_460) ]),
    pkg(name => '01-execution-power-request', step_word => 'handoff', alive => 0,
        pipeline => pl('xxxxxxxs', handoff => ' ')),
    pkg(name => '14-fold-results', status => 'blocked', waits_on => '15', pipeline => pl('       s')),
    pkg(name => 'z01-operator-signoff', step_word => undef, alive => 0, pipeline => undef),
);
my $MOCK_RUN = run(packages => \@MOCK);

# ===========================================================================
# 1 -- labels.
# ===========================================================================
{
    my %want = (scout => 'sco', spec => 'spe', tests => 'tes', implementation => 'imp', validation => 'val',
                review => 'rev', 'fix-batch' => 'fix', ui => 'ui', handoff => 'hnd');
    is(tui::DashboardScreen::_step_abbr($_), $want{$_}, "1: '$_' -> '$want{$_}'") for sort keys %want;
    is(tui::DashboardScreen::_step_abbr('elevated'), 'ele', '1: an unknown word -> its first three letters');
    is(tui::DashboardScreen::_step_abbr('Deploy'), 'dep', '1: ... lower-cased');
    is(tui::DashboardScreen::_step_abbr('qa'), 'qa', '1: a word shorter than three letters is itself');
    is(tui::DashboardScreen::_step_abbr($_), undef, '1: no word -> no label') for (undef, '', '!!');
    my $p = RunState::_scan_pipeline(ledger([ 'Scout', 'x' ], [ 'Elevated review', ' ' ]));
    is_deeply([ map { $_->{abbr} } @{ tui::DashboardScreen::_strip_of($p, 'step.current') } ], [ 'sco', 'ele' ],
        '1: labels come from the ledger step\'s first word');
}

# ===========================================================================
# 2 + 3 + 5 + 6 + 7 -- the mock-up's block, byte-exact.
# ===========================================================================
{
    my $r = texts(rows([$MOCK_RUN]));
    my $strip8 = 'sco spe tes imp val rev fix';
    my @want = (
        S(2) . G('status.ok')      . ' 03-make-and-hoo' . G('ellipsis') . ' 12h' . S(3) . S(4) . 'spe tes imp val rev fix' . S(4) . S(3) . '3h' . S(10) . S(3) . 'attempt 2/5',
        S(2) . G('status.ok')      . ' 12-model-merge'  . S(2)          . '  4h' . S(3) . $strip8 . S(4) . S(3) . '41m',
        S(2) . G('status.idle')    . ' 01-execution-po' . G('ellipsis') . S(4)   . S(3) . $strip8 . ' hnd',
        S(2) . G('thread.blocked') . ' 14-fold-results' . S(1)          . S(4)   . S(3) . $strip8 . S(4) . S(3) . 'waiting on 15',
        S(2) . G('status.idle')    . ' z01-operator-si' . G('ellipsis') . S(4)   . S(3) . S(31) . S(3) . 'no checklist',
    );
    is_deeply([ @$r[1 .. 5] ], \@want, '2/3/5/6/7: the mock-up\'s five rows, byte-exact');

    # 2: every label sits in one column across the rows that draw it.
    my $col0 = col($r->[2], 'sco');
    ok($col0 > 0, '2 precondition: the strip starts after the total column');
    my %at;
    for my $i (1 .. 4) {
        while ($r->[$i] =~ /\b(sco|spe|tes|imp|val|rev|fix|hnd)\b/g) { push @{ $at{$1} }, dw(substr($r->[$i], 0, $-[0])); }
    }
    my @off = grep { my %u = map { $_ => 1 } @{ $at{$_} }; keys(%u) != 1 } sort keys %at;
    is_deeply(\@off, [], '2: each step label is at the same column in every row') or diag(explain(\%at));
    is($at{hnd}[0] - $col0, 7 * 4, '2: the 9th step (hnd) gets its own 8th column; ui, skipped everywhere, has none');
    is(scalar(@{ $at{hnd} }), 1, '2: only the 9-step ledger draws hnd; the 8-step rows leave that column blank');
    # 3: the skipped scout is blank in its column.
    is(col($r->[1], 'spe') - $col0, 4, '3: 03\'s skipped scout is blank space in the sco column (spe still in its column)');
    like($r->[1], qr/12h {7}spe/, '3: ... the blank cell is spaces');
    unlike(join("\n", @$r), qr/\bui\b/, '3: a column skipped by every row (ui) is dropped');
    # 5 (2026-11-11): ONE status column after the strip, LEFT-aligned: step
    # times, reasons and no checklist all start in it.
    is(col($r->[1], '3h'), col($r->[2], '41m'), '5: the step times are left-aligned in one column');
    # 6: the reason starts in the time slot and does not widen it.
    is(col($r->[4], 'waiting'), col($r->[2], '41m'), '6: "waiting on 15" starts where the step time starts');
    is(col($r->[5], 'no checklist'), col($r->[2], '41m'), '7: "no checklist" starts in the status column too');
    # The attempt column follows the status column, which is as wide as the
    # longest SHORT status: here no checklist (12); without it the longest
    # time (41m, 3).
    is(col($r->[1], 'attempt'), col($r->[2], '41m') + 12 + 3, '6/7: attempt starts after the 12-wide status column');
    my $no_wait = texts(rows([ run(packages => [ @MOCK[0 .. 2] ]) ]));
    is(col($no_wait->[1], 'attempt'), col($no_wait->[2], '41m') + 3 + 3, '6/7: without the reasons the status column is as wide as the longest time');
    unlike($r->[4], qr/\x{2026}|\xe2\x80\xa6/, '6: "waiting on 15" on a row with no attempt is never cut');
}

# ===========================================================================
# 3 -- a column comes back as soon as one row draws it; n/a is blank too.
# ===========================================================================
{
    my $ui = run(packages => [ pkg(name => '03-a', alive => 1, pipeline => pl('xx      ')),
                               pkg(name => '04-b', alive => 1, pipeline => pl('xxn  ')) ]);
    my $r = texts(rows([$ui]));
    like($r->[1], qr/sco spe tes imp val rev fix ui\z/, '3: one row with an unskipped ui step brings the ui column back');
    is($r->[2], S(2) . G('status.ok') . ' 04-b   sco spe' . S(4) . ' imp val', '3: an n/a step is blank in its column too');
}

# ===========================================================================
# 2 -- the union is per block, first-seen order; the time slot lines up
# across the whole panel.
# ===========================================================================
{
    my $a = run(blueprint => 'one', packages => [
        pkg(name => '01-a', alive => 1, pipeline => pl('xx     s'),
            agents => [ agent(id => 'w', role => 'worker', worker_type => 'bp-test-writer', age => 120) ]) ]);
    my $b = run(blueprint => 'two', packages => [
        pkg(name => '01-b', alive => 1, pipeline => pl('sx      ', handoff => ' '),
            agents => [ agent(id => 'v', role => 'worker', worker_type => 'bp-implementer', age => 600) ]) ]);
    my $r = texts(rows([ $a, $b ]));
    like($r->[1], qr/01-a   sco spe tes imp val rev fix {7}2m\z/, '2: block one has no ui and no hnd column');
    is($r->[2], '', '2: one blank row separates the two blocks (2026-11-11)');
    like($r->[4], qr/01-b   spe tes imp val rev fix ui  hnd   10m\z/,
        '2: block two keeps ui and hnd, and drops sco -- skipped by every row of ITS block, though block one draws it');
    is(col($r->[1], '2m'), col($r->[4], '10m'), '2: the step time column starts in one column across blocks');
    my $dup = RunState::_scan_pipeline(ledger([ 'Review one', 'x' ], [ 'Review two', ' ' ]));
    is_deeply([ map { $_->{key} } @{ tui::DashboardScreen::_strip_of($dup, undef) } ], [ 'review', 'review#2' ],
        '2: a word used twice in one ledger keeps two columns');
}

# ===========================================================================
# 4 -- state styles.
# ===========================================================================
{
    my $r = rows([$MOCK_RUN]);
    my %role = map { ($_->{text} => $_->{role}) } grep { $_->{text} =~ /\A[a-z]{3}\z/ } @{ $r->[1] };
    is($role{spe}, 'text.muted', '4: a done step is text.muted');
    is($role{imp}, 'step.current', '4: the current step of a live package is step.current');
    is($role{$_}, 'text.faint', "4: upcoming '$_' is text.faint") for qw(val rev fix);
    my %idle = map { ($_->{text} => $_->{role}) } grep { $_->{text} =~ /\A[a-z]{3}\z/ } @{ $r->[3] };
    is($idle{hnd}, 'step.current.idle', '4: the current step of a package with nothing live is step.current.idle');
    my %wait = map { ($_->{text} => $_->{role}) } grep { $_->{text} =~ /\A[a-z]{3}\z/ } @{ $r->[4] };
    is_deeply([ sort values %wait ], [ ('text.faint') x 7 ], '6: a waiting package\'s whole strip is upcoming');
    my @asides = grep { $_->{text} eq 'waiting on 15' || $_->{text} eq 'no checklist' } map { @{ $r->[$_] } } 4, 5;
    is_deeply([ map { $_->{role} } @asides ], [ 'text.waiting', 'text.waiting' ], '6/7: both reasons are text.waiting');
    my @sp = @{ $r->[2] };
    my ($first) = grep { $sp[$_]{text} eq 'sco' } 0 .. $#sp;
    my ($last)  = grep { $sp[$_]{text} eq 'fix' } 0 .. $#sp;
    my @between = grep { $_->{text} !~ /\A[a-z]{3}\z/ } @sp[ $first .. $last ];
    ok(@between && !(grep { $_->{text} !~ /\A +\z/ } @between), '4: no glyph between steps, only spaces');

    my $paused = run(state => 'paused', packages => [ pkg(name => '03-a', alive => 0, pipeline => pl('xx     s')) ]);
    my ($cur) = grep { $_->{text} eq 'tes' } @{ rows([$paused])->[1] };
    is($cur->{role}, 'step.current.idle', '4: paused, nothing live -> step.current.idle');

    # Theme: the two roles are accent / state.idle plus bold at every rung.
    my $roles = Theme::roles();
    ok($roles->{'step.current'}{bold} && $roles->{'step.current.idle'}{bold}, '4: Theme declares both roles bold');
    is_deeply($roles->{'step.current'}{rgb}, $roles->{accent}{rgb}, '4: step.current is accent\'s colour');
    is_deeply($roles->{'step.current.idle'}{rgb}, $roles->{'state.idle'}{rgb}, '4: step.current.idle is state.idle\'s colour');
    is(Theme::sgr('step.current', 'truecolor'), Theme::sgr('accent', 'truecolor') . "\e[1m", '4: truecolour: accent + SGR 1');
    is(Theme::sgr('step.current', '256'), "\e[38;5;69m\e[1m", '4: 256-colour fallback: accent\'s 69 + SGR 1');
    is(Theme::sgr('step.current.idle', '256'), "\e[38;5;244m\e[1m", '4: 256-colour fallback: state.idle\'s 244 + SGR 1');
    is(Theme::sgr($_, 'none'), "\e[1m", "4: no colour: $_ is bold, apart from the dim done/upcoming cells")
        for qw(step.current step.current.idle);
    ok(!(grep { $roles->{$_}{bold} } grep { !/\Astep\.current/ } keys %$roles), '4: no other role is bold-flagged');
}

# ===========================================================================
# 6 -- a next package draws its strip when packages[] has it.
# ===========================================================================
{
    my $s = run(packages => [ pkg(name => '03-a', alive => 1, pipeline => pl('xx     s')),
                              pkg(name => '04-b', status => 'pending', pipeline => pl('       s')) ],
                next_package => '04-b');
    my $r = texts(rows([$s]));
    is($r->[2], S(2) . G('arrow.right') . ' 04-b   sco spe tes imp val rev fix   next',
        '6: the next package: its full strip, all upcoming, then "next"');
}

# ===========================================================================
# 9 -- width: the strip falls back to the step word, keeping time and
# attempt; and a panel with no checklist anywhere keeps its words.
# ===========================================================================
{
    my $full = texts(rows([$MOCK_RUN]));
    my $W = 0;
    for my $l (@$full[1 .. $#$full]) { $W = dw($l) if dw($l) > $W; }
    my $fits = texts(rows([$MOCK_RUN], $W));
    is_deeply([ @$fits[1 .. 5] ], [ @$full[1 .. 5] ], "9: at exactly the widest strip row ($W) the strip is drawn");
    my $narrow = texts(rows([$MOCK_RUN], $W - 1));
    my ($a) = grep { /03-make/ } @$narrow;
    ok(defined($a) && $a !~ /\bspe\b/, '9: one column narrower, the strip is gone');
    like($a // '', qr/implementation\s+3h\s+attempt 2\/5\z/, '9: ... replaced by the step word, time and attempt kept');
    my ($w) = grep { /14-fold/ } @$narrow;
    like($w // '', qr/14-fold-results\s+waiting on 15\z/, '9: ... a waiting row shows only its reason, as before the strip');
    ok(!(grep { dw($_) > $W - 1 } @$narrow[1 .. $#$narrow]), '9: every fallback row fits');

    my $legacy = run(packages => [ pkg(name => '03-a', step_word => 'tests', alive => 1),
                                   pkg(name => '04-b', step_word => 'review', alive => 0) ]);
    my $l = texts(rows([$legacy]));
    like($l->[1], qr/03-a   tests\z/, '9: a panel with no checklist at all keeps the step word');
    unlike(join("\n", @$l), qr/no checklist/, '9: ... and says nothing about checklists');
}

# ===========================================================================
# RunState: summarize_dir passes the ledger's checklist through.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = "$root/.ccpraxis-local-data/blueprints/strip";
    make_path("$dir/runs", "$dir/packages");
    open my $fh, '>', "$dir/blueprint.md" or die;
    print $fh "| pkg | deliverable | depends_on | model |\n|-----|-----|-----|-----|\n| 01-a | x | $EM | sonnet |\n| 02-b | y | $EM | sonnet |\n";
    close $fh;
    open $fh, '>', "$dir/packages/01-a.md" or die;
    binmode $fh;
    print $fh ledger([ 'Scout', 's' ], [ 'Spec', 'x' ], [ 'Tests', ' ' ]) =~ s/package: p\n/package: 01-a\n/r;
    close $fh;
    open $fh, '>', "$dir/packages/02-b.md" or die;
    print $fh "---\npackage: 02-b\nstatus: pending\n---\n# ledger\n";
    close $fh;
    no warnings 'once';
    local $RunState::PID_ALIVE = undef;
    my $s = eval { RunState::summarize_dir($dir) };
    ok(ref($s) eq 'HASH', 'RunState precondition: summarize_dir returns a summary') or diag($@);
    my %by = map { ($_->{name} => $_) } grep { ref($_) eq 'HASH' } @{ $s->{packages} || [] };
    is_deeply([ map { [ $_->{word}, $_->{state} ] } @{ $by{'01-a'}{pipeline} || [] } ],
              [ [ 'scout', 'skipped' ], [ 'spec', 'done' ], [ 'tests', 'todo' ] ],
              'RunState: a package entry carries its checklist as `pipeline`');
    ok(exists($by{'02-b'}{pipeline}) && !defined($by{'02-b'}{pipeline}), 'RunState: no checklist -> pipeline undef');
}

done_testing();
