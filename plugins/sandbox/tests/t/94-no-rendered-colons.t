#!/usr/bin/env perl
# t05-no-colons -- the oracle for blueprint tui-operator-feedback.
#
# Operator, verbatim: "we use way too many instances of the character `:`. Its
# distracting. We need none of them." -- and, asked about the one conflict,
# they confirmed blueprint Decision 2: clock times keep theirs.
#
# THE ASSERTION THAT MATTERS IS THE SWEEP, not the six call sites. Criterion 5
# asks that a future label cannot quietly reintroduce a colon, and a test that
# names the six places we fixed would not notice a seventh. So this composes
# real frames across a matrix of states and widths and asserts that NO rendered
# row carries a colon outside a clock time -- which is a property of the screen
# rather than a list of the edits.
#
# WHAT THE RULE DOES NOT TOUCH (blueprint Decision 20): values. A label gutter,
# a provider prefix and a warning sentence are text this repo AUTHORS and lose
# their colons. An event body, a blueprint name, a container name, a path, an
# error string from a subprocess are DATA passing through the renderer --
# rewriting those would make the screen disagree with the thing it reports on.
# PART 3 asserts that directly, because a rule enforced too widely is its own
# defect.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;

my $OK = eval { require Dashboard; require SpendPanel; require tui::DashboardScreen;
                require tui::BackpackScreen; 1 };
ok($OK, 'the TUI modules load') or BAIL_OUT("require failed: $@");

sub plain { my ($s) = @_; $s = '' if !defined $s; $s =~ s/\e\[[0-9;]*m//g; return $s }

# strip_clocks($text) -- remove HH:MM and HH:MM:SS, which Decision 2 exempts.
# Deliberately anchored on the digit shape rather than on "a colon with digits
# near it", so a value like "3:1" (a ratio, not a clock) would still be caught
# and escalated rather than silently excused.
sub strip_clocks {
    my ($t) = @_;
    $t =~ s/\b\d{2}:\d{2}:\d{2}\b//g;
    $t =~ s/\b\d{2}:\d{2}\b//g;
    return $t;
}

my $SPEND = SpendPanel::status(SpendPanel::from_snapshot({ results => [
    { provider => 'go',     status => 'ok', five_hour => { used => 42, limit => 100 },
                                            weekly    => { used => 300, limit => 1000 } },
    { provider => 'zen',    status => 'ok', balance => '12.34', budget => '50.00' },
    { provider => 'claude', status => 'ok', five_hour => { utilization => 0.42 },
                                            seven_day => { utilization => 0.9 } },
] }), 1787000000);

my @EVENTS = map {
    [ { text => sprintf('%-6s  ', sprintf('16:%02d', $_)), role => 'text.muted' },
      { text => 'o ', role => 'text.primary' },
      { text => "some_event exit=0", role => 'text.primary' } ]
} 1 .. 6;

my @RUNS = (
    { blueprint => 'bp-one', state => 'running', packages_done => 1, packages_total => 3,
      current_package => 'pkg-a', running_coordinators => 1, decisions_waiting => 2 },
    { blueprint => 'bp-two', state => 'paused',  packages_done => 0, packages_total => 9 },
);

# A matrix of STATES, not just of sizes. Each entry turns on a different set of
# rows, and several of them were the only way to reach a given colon at all --
# the stale-snapshot wording, the not-logged-in wording and the install banner
# each appear in exactly one branch.
my %STATES = (
    'populated' => {
        runs => \@RUNS, events => \@EVENTS, project_name => 'ccpraxis', container => 'claude-x',
        status => 'running', spend => $SPEND,
        tokens => { access_state => 'ok', access_seconds_left => 3000, refresh_present => 1,
                    refresh_fingerprint => 'ab12', subscription_type => 'max', rate_limit_tier => 't3' },
        resources => { snapshot_state => 'fresh', snapshot_age => 5, cpu_pct => 12 },
        heartbeat_age => 12, uptime => 3600, busy_age => 5, stay_awake => 1,
    },
    'empty' => { runs => [], events => [], tokens => {} },
    'stale-resources' => {
        runs => [], events => [], tokens => {},
        resources => { snapshot_state => 'stale', snapshot_age => 900 },
    },
    'failed-resources' => {
        runs => [], events => [], tokens => {},
        resources => { snapshot_state => 'failed' },
    },
    'no-login' => { runs => [], events => [], tokens => { access_state => 'absent' } },
    'install-warning' => {
        runs => [], events => [], tokens => {},
        install_warning => 'backpack install - some items failed',
    },
    'needs-you' => {
        runs => \@RUNS, events => \@EVENTS, tokens => {},
        needs_you => { count => 1 }, backpack => { pending => 2, failed => 1 },
    },
    'spend-absent' => {
        runs => [], events => [], tokens => { access_state => 'ok', access_seconds_left => 500 },
        spend_sampler => { status => 'failed', reason => 'fork: Cannot fork' },
    },
);

# ===========================================================================
# PART 1 -- the sweep. No authored colon survives, in any state, at any size.
# ===========================================================================
{
    my @offenders;
    my $checked = 0;
    for my $name (sort keys %STATES) {
        for my $cols (60, 100, 130, 150, 200) {
            for my $rows (12, 24, 40) {
                my $f = Dashboard::compose_frame($STATES{$name}, $rows, $cols);
                $checked++;
                for my $r (@$f) {
                    my $t = strip_clocks(plain($r->{text}));
                    next unless $t =~ /:/;
                    push @offenders, "[$name ${cols}x${rows}] " . plain($r->{text});
                }
            }
        }
    }
    is(scalar(@offenders), 0,
        "AC1: no rendered row carries a colon outside a clock time, across $checked state/size combinations")
        or diag("  offending rows:\n    " . join("\n    ", @offenders[ 0 .. ($#offenders > 9 ? 9 : $#offenders) ]));
}

# AC2 -- and the sweep is NON-VACUOUS. If it never saw a colon-bearing row even
# before the fix, it would prove nothing. Feed the matrix a value that legally
# contains one and confirm the detector fires.
{
    my $st = { %{ $STATES{'empty'} }, runs => [ { blueprint => 'has:colon', state => 'running',
                                                  packages_done => 0, packages_total => 1 } ] };
    my $f = Dashboard::compose_frame($st, 24, 150);
    my $hits = grep { strip_clocks(plain($_->{text})) =~ /:/ } @$f;
    cmp_ok($hits, '>', 0,
        'AC2 non-vacuity: the detector does fire on a colon that reaches the screen -- PART 1 passing is a fact about the rows, not about the check');
}

# AC3 -- clock times are EXEMPT, and visibly so. The activity column's rows
# must still carry theirs; Decision 2 is operator-confirmed and the example row
# they approved contains one.
{
    my $f = Dashboard::compose_frame($STATES{'populated'}, 24, 150);
    my $joined = join("\n", map { plain($_->{text}) } @$f);
    like($joined, qr/\b16:0\d\b/, 'AC3: clock times keep their colon');
}

# ===========================================================================
# PART 2 -- the fix is at the SHARED SITE (criterion 3), not at N call sites.
# ===========================================================================
{
    can_ok('tui::DashboardScreen', 'gutter');
    can_ok('tui::DashboardScreen', 'pad_label');

    my $g = tui::DashboardScreen::gutter('uptime');
    unlike($g, qr/:/, 'AC4: the shared label gutter renders no colon');
    is(length($g), tui::DashboardScreen::LABEL_GUTTER() + length(tui::DashboardScreen::GUTTER_SEP()),
        'AC4: and is the label width plus the separator');

    # AC5 -- THE WIDTH IS UNCHANGED, which is what made this safe to apply
    # everywhere at once (Decision 21). " : " is three columns and so is the
    # replacement, so every downstream width computation, fit_spans budget and
    # truncation point is untouched -- only the characters differ.
    is(length(tui::DashboardScreen::GUTTER_SEP()), 3,
        'AC5: the separator is exactly as wide as the " : " it replaces');

    # The gutter sprintf must exist in ONE place. Two copies of it used to sit
    # in this file alongside row()'s, and a copy that has to be edited next to
    # its original is how the next colon gets reintroduced.
    my $src = do { local $/; open(my $fh, '<', "$Bin/../../scripts/tui/DashboardScreen.pm") or die $!; <$fh> };
    $src =~ s/^\s*#.*$//mg;                      # comments are not behaviour
    my $copies = () = $src =~ /LABEL_GUTTER\(\)/g;
    cmp_ok($copies, '<=', 2,
        'AC6 (criterion 3): LABEL_GUTTER is referenced only by its own declaration and the one helper that formats with it');
}

# ===========================================================================
# PART 3 -- the rule is not over-applied (Decision 20).
#
# A rule enforced too widely is its own defect. These assertions fail if a
# future implementation starts scrubbing colons out of DATA.
# ===========================================================================
{
    my $st = { runs => [ { blueprint => 'weird:name', state => 'running',
                           packages_done => 0, packages_total => 1,
                           current_package => 'pkg:with:colons' } ],
               events => [ [ { text => '16:01   ', role => 'text.muted' },
                             { text => 'o ', role => 'text.primary' },
                             { text => 'ran C:/Users/x/thing.pl', role => 'text.primary' } ] ],
               tokens => {} };
    my $joined = join("\n", map { plain($_->{text}) } @{ Dashboard::compose_frame($st, 30, 200) });

    like($joined, qr/weird:name/,
        'AC7: a blueprint whose NAME contains a colon renders it -- the rule governs text we author, not values we display');
    like($joined, qr/pkg:with:colons/,
        'AC7: and so does a package identifier');
    like($joined, qr{C:/Users/x/thing\.pl},
        'AC7: and a path inside an event body, which is the case where scrubbing would make the screen disagree with what it reports');
}

# ===========================================================================
# PART 4 -- the other surfaces. The operator's complaint was about the TUI, not
# about one panel.
# ===========================================================================
{
    my $ss = { rows => [ { key => 'chromium', approved => 0, size => '221MB' },
                         { key => 'ripgrep',  approved => 1 } ],
               cursor => 0, title => 'Backpack',
               status => { kind => 'failed', op => 'remove', detail => 'permission denied' } };
    my $f = tui::BackpackScreen::compose($ss, 20, 100);
    my @bad = grep { strip_clocks(plain($_->{text})) =~ /:/ } @$f;
    is(scalar(@bad), 0, 'AC8: the backpack screen renders no colon either')
        or diag('  ' . join("\n  ", map { plain($_->{text}) } @bad));

    my $ss2 = { %$ss, status => { kind => 'unavailable', op => 'read', detail => 'file missing' } };
    my @bad2 = grep { strip_clocks(plain($_->{text})) =~ /:/ } @{ tui::BackpackScreen::compose($ss2, 20, 100) };
    is(scalar(@bad2), 0, 'AC8: including its unavailable-status wording');
}

# ===========================================================================
# PART 5 -- the launcher's own authored warning sentences.
#
# Source-text only: this suite never executes launcher.pl. Weaker than
# behaviour, and labelled as such.
# ===========================================================================
{
    my $src = do { local $/; open(my $fh, '<', "$Bin/../../scripts/launcher.pl") or die $!; <$fh> };
    my @warns = $src =~ /\$INSTALL_WARNING\s*=\s*'([^']*)'/g;
    cmp_ok(scalar(@warns), '>=', 4, 'AC9 precondition: the install-warning sentences are locatable');
    my @with = grep { /:/ } @warns;
    is(scalar(@with), 0, 'AC9 (source-text): no install-warning sentence carries a colon')
        or diag('  ' . join("\n  ", @with));
}

done_testing();
