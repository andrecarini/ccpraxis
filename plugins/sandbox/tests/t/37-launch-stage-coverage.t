#!/usr/bin/env perl
# 37 — EVERY LONG STRETCH OF THE LAUNCH FLOW IS INSIDE A STAGE.
#
# WHY THIS EXISTS. `_launch_stage_begin` is the only thing that repaints during
# the launch phase (launcher.pl's own note at its definition). So a stretch of
# main-flow work with no stage marker is not merely unlabelled — it is FROZEN:
# the frame keeps showing whatever was last drawn until the next marker.
#
# That shipped. Between the `select` stage ending and `create` beginning, the
# launcher ran ~1600 lines — the skills.pl `mounts` child, the plugin store
# copy, credential materialisation, a `wsl -d ... ip -4 addr` host-IP probe,
# session selection, the whole claude-home layout — with no marker at all. On a
# stale sandbox the operator chose an option and then watched a dead menu for
# 20+ seconds, with no way to tell it from a hang (bug report
# 20260829-194441-fd0a). None of that work was wrong; its invisibility was.
#
# The assertions below are structural, not timing-based. A test cannot measure
# "felt frozen", but it can measure the thing that causes it.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use lib "$Bin/../../scripts";

my $LAUNCHER = "$Bin/../../scripts/launcher.pl";

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

my $src = slurp($LAUNCHER);
ok(defined $src, 'precondition: launcher.pl is readable');
plan skip_all => 'launcher.pl unreadable' unless defined $src;

my $ls_ok = eval { require tui::LaunchScreens; 1 };
ok($ls_ok, 'precondition: tui::LaunchScreens loads') or diag("  $@");

# Comments stripped: this file's own prose, and the launcher's, name stage ids
# while explaining them. A scan that counted those would fail on the
# documentation of the fix — the failure mode t/66 already had to correct.
my $code = $src;
$code =~ s/^[ \t]*#[^\n]*$//mg;

my @begun = $code =~ /_launch_stage_begin\(\s*'([a-z_]+)'/g;
my @ended = $code =~ /_launch_stage_end\(\s*'([a-z_]+)'/g;

# ---------------------------------------------------------------------------
# AC1 — no stage id is invented at the call site.
#
# A typo'd id is the silent version of this whole bug: stage_begin on an unknown
# id finds no stage to mark, so it renders nothing and repaints nothing, and the
# launcher looks exactly as frozen as it did before any of this was fixed.
# ---------------------------------------------------------------------------
SKIP: {
    skip 'tui::LaunchScreens unavailable', 2 unless $ls_ok;
    my %declared = map { $_ => 1 } @{ tui::LaunchScreens::STAGE_IDS() };

    my @unknown_begin = grep { !$declared{$_} } @begun;
    is_deeply([sort keys %{{ map { $_ => 1 } @unknown_begin }}], [],
        'AC1: every _launch_stage_begin id is declared in STAGE_IDS (an unknown id repaints nothing)');

    my @unknown_end = grep { !$declared{$_} } @ended;
    is_deeply([sort keys %{{ map { $_ => 1 } @unknown_end }}], [],
        'AC1: every _launch_stage_end id is declared in STAGE_IDS');
}

# ---------------------------------------------------------------------------
# AC2 — no declared stage is dead. A stage listed in the progress screen that
# nothing ever begins is a row that sits at 'pending' forever, which reads to
# the operator as a step that never ran.
# ---------------------------------------------------------------------------
SKIP: {
    skip 'tui::LaunchScreens unavailable', 1 unless $ls_ok;
    my %begun = map { $_ => 1 } @begun;
    my @never = grep { !$begun{$_} } @{ tui::LaunchScreens::STAGE_IDS() };
    is_deeply(\@never, [],
        'AC2: every declared stage is begun somewhere in launcher.pl');
}

# ---------------------------------------------------------------------------
# AC3 — THE REGRESSION ITSELF, expressed structurally.
#
# The launcher already brackets its phases with `launch-emit:<name>:BEGIN/END`
# comment markers. Between `select:END` and `create:BEGIN` there must now be at
# least one stage begin. This is deliberately NOT a line-count threshold: the
# file grows, and a number chosen today would either rot into noise or quietly
# stop catching anything. What is asserted is the property that was violated —
# that the stretch is covered at all.
#
# Marker comments are matched against the RAW source, since the strip above
# removed them.
# ---------------------------------------------------------------------------
{
    my ($sel_end) = $src =~ /(.*)<<< launch-emit:select:END/s;
    my $sel_pos = defined $sel_end ? length($sel_end) : -1;
    my ($cre_pre) = $src =~ /(.*?)>>> launch-emit:create:BEGIN/s;
    my $cre_pos = defined $cre_pre ? length($cre_pre) : -1;

    ok($sel_pos >= 0, 'AC3: the select:END marker is present');
    ok($cre_pos > $sel_pos, 'AC3: the create:BEGIN marker follows it');

  SKIP: {
        skip 'markers not found', 1 unless $sel_pos >= 0 && $cre_pos > $sel_pos;
        my $between = substr($src, $sel_pos, $cre_pos - $sel_pos);
        $between =~ s/^[ \t]*#[^\n]*$//mg;
        my @marks = $between =~ /_launch_stage_begin\(\s*'([a-z_]+)'/g;
        ok(scalar(@marks) >= 1,
            'AC3: the stretch between select and create begins at least one stage -- '
          . 'it is the slowest phase of the launch and used to repaint nothing')
            or diag('  no stage begins between select:END and create:BEGIN; '
                  . 'the launch screen will sit frozen through that whole phase');
    }
}

# ---------------------------------------------------------------------------
# AC4 — the stage introduced for that stretch is ended, not just begun. A stage
# left 'active' never resolves in the progress list, so the screen keeps
# claiming work is in flight after it finished.
# ---------------------------------------------------------------------------
{
    my %begun_h = map { $_ => 1 } @begun;
    my %ended_h = map { $_ => 1 } @ended;
    ok($begun_h{prepare}, 'AC4: the prepare stage is begun');
    ok($ended_h{prepare}, 'AC4: the prepare stage is also ended (never left active)');
}

done_testing();
