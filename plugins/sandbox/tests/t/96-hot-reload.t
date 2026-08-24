#!/usr/bin/env perl
# t11-tui-hot-reload -- the oracle for blueprint tui-operator-feedback.
#
# Operator: "Could we make source code changes on the TUI be hot-reloaded? I
# assume there is a high chance that a running TUI could break anyways if the
# running source code doesn't get reloaded but separate modules probably will".
#
# The assumption is right; the boundary is sharper than module-vs-launcher. It
# is IS THIS SUB ON THE CALL STACK: launcher.pl is the process and
# Dashboard::run is the loop, so both are frozen for the session, while
# everything the loop calls BY NAME resolves through the symbol table at call
# time and goes live.
#
# PART 1 IS THE MOST IMPORTANT SECTION IN THIS FILE and it does not test our
# code at all -- it tests PERL, and pins the reason the `perl -c` gate exists.
# The gate looks like belt-and-braces; it is not, and the difference is a
# behaviour nobody should have to rediscover by losing an afternoon to it.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Test::More;

my $SCRIPTS = "$Bin/../../scripts";
my $OK = eval { require HotReload; require tui::DashboardScreen; 1 };
ok($OK, 'HotReload.pm and tui/DashboardScreen.pm load') or BAIL_OUT("require failed: $@");

# ===========================================================================
# PART 1 -- WHY THE `perl -c` GATE IS LOAD-BEARING.
#
# A require of a file with a syntax error does NOT leave the old package
# intact. Subs are installed as they are parsed, so a syntax error at line N
# leaves every sub BEFORE it replaced and every sub AFTER it stale -- a
# silently mixed-version module. Nothing raises; the eval merely reports that
# the require failed, long after the damage.
#
# If a future change ever concludes "the eval around require is enough, drop
# the subprocess", this section is what should stop it.
# ===========================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    open(my $f, '>', "$dir/HalfClobber.pm") or die $!;
    print {$f} "package HalfClobber;\nsub alpha { 'v1' }\nsub beta { 'v1' }\n1;\n";
    close $f;

    unshift @INC, $dir;
    require HalfClobber;
    is(HalfClobber::alpha(), 'v1', 'PART 1 setup: both subs load at v1');
    is(HalfClobber::beta(),  'v1', 'PART 1 setup: ...');

    # v2 for alpha, then a syntax error BEFORE beta.
    open(my $g, '>', "$dir/HalfClobber.pm") or die $!;
    print {$g} "package HalfClobber;\nsub alpha { 'v2' }\nsub beta { this is not perl ( \n1;\n";
    close $g;

    delete $INC{'HalfClobber.pm'};
    my $ok = eval { local $SIG{__WARN__} = sub {}; require HalfClobber; 1 };
    ok(!$ok, 'PART 1: the require of a syntactically broken file fails, as expected');

    is(HalfClobber::alpha(), 'v2',
        'PART 1: THE POINT -- the sub BEFORE the syntax error was REPLACED anyway');
    is(HalfClobber::beta(), 'v1',
        'PART 1: while the sub AFTER it is stale. A failed require leaves a MIXED-VERSION package, silently -- which is why a candidate must be compiled in a process that cannot damage this one BEFORE any swap');
    shift @INC;
}

# ===========================================================================
# PART 2 -- the stash snapshot is a real rollback.
#
# Recorded because the driver's rollback was originally waved off as needing a
# temp-file dance. It does not: saving the coderefs out of the package stash
# and reinstalling them is a handful of lines, which is why the driver has
# rollback at all.
# ===========================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    open(my $f, '>', "$dir/Rollback.pm") or die $!;
    print {$f} "package Rollback;\nsub alpha { 'v1' }\nsub beta { 'v1' }\n1;\n";
    close $f;
    unshift @INC, $dir;
    require Rollback;

    no strict 'refs';
    my %saved = map  { $_ => \&{"Rollback::$_"} }
                grep { defined &{"Rollback::$_"} } keys %{"Rollback::"};
    is(scalar(keys %saved), 2, 'PART 2: both subs are captured from the stash');

    open(my $g, '>', "$dir/Rollback.pm") or die $!;
    print {$g} "package Rollback;\nsub alpha { 'v2' }\nsub beta { this is not perl ( \n1;\n";
    close $g;
    delete $INC{'Rollback.pm'};
    eval { local $SIG{__WARN__} = sub {}; require Rollback; 1 };
    is(Rollback::alpha(), 'v2', 'PART 2: the package is mixed-version after the failed load');

    { no warnings 'redefine'; *{"Rollback::$_"} = $saved{$_} for keys %saved; }
    is(Rollback::alpha(), 'v1', 'PART 2: reinstalling the saved coderefs restores the replaced sub');
    is(Rollback::beta(),  'v1', 'PART 2: ...and leaves the untouched one alone');
    shift @INC;
}

# ===========================================================================
# PART 3 -- the allowlist.
# ===========================================================================
{
    my @all = HotReload::reloadable_modules();
    cmp_ok(scalar(@all), '>', 0, 'AC1: the allowlist is non-empty');

    # THE THING THAT MUST NEVER BE RELOADABLE. launcher.pl is the running
    # process -- signal handlers, raw mode, child pids, open log handles. It is
    # also structurally absent from %INC (perl records require'd files; the
    # main program is not one), so this is belt AND braces.
    ok(!HotReload::is_reloadable('launcher'),   'AC2: launcher is not in the allowlist');
    ok(!HotReload::is_reloadable('launcher.pl'), 'AC2: nor under its filename');

    # Modules that own something the process cannot rebuild by recompiling.
    for my $owner (qw(KeepAwake SandboxLock LaunchLog)) {
        ok(!HotReload::is_reloadable($owner),
            "AC2: $owner is excluded -- it owns process state, not just code");
    }
    for my $render (qw(tui::Frame tui::Screen tui::DashboardScreen Theme Dashboard)) {
        ok(HotReload::is_reloadable($render), "AC3: $render is reloadable");
    }

    is(HotReload::inc_key('tui::DashboardScreen'), 'tui/DashboardScreen.pm', 'AC4: inc_key maps a module name to its %INC key');
    is(HotReload::inc_key('Theme'), 'Theme.pm', 'AC4: ...including a top-level one');
    for my $bad (undef, '', 'has space', 'has/slash', '../escape', 'Trailing::') {
        my $label = defined $bad ? "'$bad'" : 'undef';
        is(HotReload::inc_key($bad), undef,
            "AC4: inc_key refuses $label rather than building a path out of it");
    }
}

# ===========================================================================
# PART 4 -- loaded() and changed().
# ===========================================================================
{
    my $loaded = HotReload::loaded({
        'tui/Frame.pm'  => "$SCRIPTS/tui/Frame.pm",
        'Theme.pm'      => "$SCRIPTS/Theme.pm",
        'KeepAwake.pm'  => "$SCRIPTS/KeepAwake.pm",   # loaded but NOT allowlisted
        'JSON/PP.pm'    => '/usr/share/perl5/JSON/PP.pm',
    });
    my %names = map { $_->{name} => 1 } @$loaded;
    ok($names{'tui::Frame'}, 'AC5: an allowlisted, loaded module is returned');
    ok($names{'Theme'},      'AC5: ...and another');
    ok(!$names{'KeepAwake'}, 'AC5: a loaded module that is NOT allowlisted is excluded');
    is(scalar(@$loaded), 2,  'AC5: and nothing else leaks in');

    # A module in the list but never loaded is skipped: reloading it would run
    # its file-scope body for the first time at an arbitrary moment.
    my $lazy = HotReload::loaded({ 'Theme.pm' => "$SCRIPTS/Theme.pm" });
    is(scalar(@$lazy), 1, 'AC5: an allowlisted module absent from %INC is skipped, not conjured');

    my @set = ({ name => 'A' }, { name => 'B' }, { name => 'C' });
    my $ch = HotReload::changed(\@set, { A => 100, B => 200, C => 300 },
                                       { A => 100, B => 999, C => 300 });
    is_deeply([ map { $_->{name} } @$ch ], ['B'], 'AC6: only a module whose mtime moved is proposed');

    # NO BASELINE COUNTS AS CHANGED. The conservative direction: treating
    # never-seen-before as unchanged would skip a module on the first check
    # after it was added, which is exactly when someone is testing it.
    my $new = HotReload::changed(\@set, { A => 100 }, { A => 100, B => 200, C => 300 });
    is_deeply([ sort map { $_->{name} } @$new ], ['B','C'],
        'AC6: a module with no baseline counts as changed');

    # AN UNREADABLE MTIME COUNTS AS UNCHANGED -- the conservative direction for
    # the opposite reason: a file we cannot stat is one we cannot validate.
    my $gone = HotReload::changed(\@set, { A => 100, B => 200, C => 300 }, { A => 100, C => 300 });
    is_deeply([ map { $_->{name} } @$gone ], [],
        'AC6: a module we could not stat is NOT proposed for reload');

    for my $bad (undef, 'x', {}, []) {
        is(ref(HotReload::changed($bad, {}, {})), 'ARRAY', 'AC6: malformed input yields an arrayref rather than dying');
    }
}

# ===========================================================================
# PART 5 -- summarise, and the caveat that fires ON SUCCESS.
# ===========================================================================
{
    my $s = HotReload::summarise({ reloaded => ['tui::Frame','Theme'] });
    is($s->{ok}, 1, 'AC7: a clean reload reports ok');
    like($s->{headline}, qr/reloaded 2 modules/, 'AC7: and says how many');

    # THE ASSERTION THIS PACKAGE MOST DEPENDS ON. Most real changes to this TUI
    # touch a render module AND launcher.pl together -- t01 added
    # sampler_wait_spans to DashboardScreen *and* threaded resources_sampler
    # into launcher.pl's state hash. Hot-reload feeds NEW render code from the
    # OLD state, and because every function here is total, that renders the
    # fallback case cleanly. A correct change LOOKS BROKEN. Silence about that
    # would make this feature cost more than it saves.
    ok((grep { /launcher\.pl is never reloaded/ } @{ $s->{notes} }),
        'AC8: a SUCCESSFUL reload still warns that launcher.pl was not in the set');
    ok((grep { /half-applied/ } @{ $s->{notes} }),
        'AC8: and names the consequence -- a half-applied change renders its fallback rather than failing');

    my $none = HotReload::summarise({ reloaded => [] });
    ok(!(grep { /launcher\.pl/ } @{ $none->{notes} }),
        'AC8: but it does NOT fire when nothing reloaded -- a note that always appears is one nobody reads');

    my $bad = HotReload::summarise({ rolled_back => [ { name => 'tui::Frame', why => 'died rendering' } ] });
    is($bad->{ok}, 0, 'AC9: a rollback reports NOT ok');
    like($bad->{headline}, qr/FAILED/, 'AC9: loudly');
    ok((grep { /tui::Frame - died rendering/ } @{ $bad->{notes} }), 'AC9: naming the module and the reason');

    my $skip = HotReload::summarise({ skipped => [ { name => 'Theme', why => 'does not compile' } ] });
    is($skip->{ok}, 1, 'AC9: a SKIP is not a failure -- nothing was touched');
    like($skip->{headline}, qr/would not compile/, 'AC9: but it is reported');

    for my $b (undef, 'x', [], { reloaded => 'not-an-array' }) {
        my $g = eval { HotReload::summarise($b) };
        is(ref($g), 'HASH', 'AC10: malformed input yields a summary rather than dying') or diag("  died: $@");
    }
}

# ===========================================================================
# PART 6 -- what reaches the screen.
# ===========================================================================
{
    can_ok('tui::DashboardScreen', 'hot_reload_msgs');

    is_deeply(tui::DashboardScreen::hot_reload_msgs({}), [], 'AC11: a quiet state produces no banner');

    my $nudge = tui::DashboardScreen::hot_reload_msgs({ hot_reload_pending => 3 });
    ok((grep { /3 render modules changed on disk/ && /press \[r\]/ } @$nudge),
        'AC12: the nudge names the count and the key -- this is what closes the "promote you forgot to pick up" half');
    my $one = tui::DashboardScreen::hot_reload_msgs({ hot_reload_pending => 1 });
    ok((grep { /1 render module changed/ } @$one), 'AC12: and is singular for one');
    is_deeply(tui::DashboardScreen::hot_reload_msgs({ hot_reload_pending => 0 }), [],
        'AC12: zero pending says nothing at all');

    my $rep = tui::DashboardScreen::hot_reload_msgs({
        hot_reload => HotReload::summarise({ reloaded => ['tui::Frame'] }) });
    ok((grep { /^\[r\] reloaded 1 module/ } @$rep), 'AC13: the report leads with what happened');
    ok((grep { /launcher\.pl/ } @$rep), 'AC13: and carries the caveat through to the screen');

    for my $b (undef, 'x', [], { hot_reload => 'nonsense' }, { hot_reload_pending => 'lots' }) {
        is(ref(eval { tui::DashboardScreen::hot_reload_msgs($b) }), 'ARRAY',
            'AC14: malformed state yields an arrayref rather than dying on the render path');
    }

    # It reaches the composed frame, not just the helper.
    require Dashboard;
    my $f = Dashboard::compose_frame({ runs => [], events => [], tokens => {},
                                       hot_reload_pending => 2 }, 24, 120);
    my $joined = join("\n", map { my $t = $_->{text}; $t =~ s/\e\[[0-9;]*m//g; $t } @$f);
    like($joined, qr/2 render modules changed on disk/,
        'AC15: and it actually renders in a composed frame, not only in the helper');
}

# ===========================================================================
# PART 7 -- the driver's wiring. SOURCE-TEXT ONLY: this suite never executes
# launcher.pl, so these are weaker than behaviour and are labelled as such.
# ===========================================================================
{
    my $L = do { local $/; open(my $fh, '<', "$SCRIPTS/launcher.pl") or die $!; <$fh> };

    like($L, qr/_hot_reload_compiles/, 'AC16 (source-text): the compile gate exists');
    like($L, qr/'-c'/,                 'AC16 (source-text): and it really is perl -c');
    like($L, qr/_hot_reload_snapshot/, 'AC17 (source-text): the stash snapshot exists');
    like($L, qr/_hot_reload_restore/,  'AC17 (source-text): and its restore');
    like($L, qr/hot_reload\s*=>\s*sub/, 'AC18 (source-text): the seam is injected into Dashboard::run');

    # Dashboard.pm must stay free of spawning: it takes every I/O boundary as
    # an injection, which is why the driver lives in launcher.pl at all. This
    # package would be the obvious place to break that.
    my $D = do { local $/; open(my $fh, '<', "$SCRIPTS/Dashboard.pm") or die $!; <$fh> };
    $D =~ s/^\s*#.*$//mg;
    unlike($D, qr/(^|[^_\w])(system|exec|fork)\s*\(/,
        'AC19: Dashboard.pm still spawns nothing -- the reload driver did not become its first');
}

done_testing();
