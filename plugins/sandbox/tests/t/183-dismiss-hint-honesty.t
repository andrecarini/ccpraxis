#!/usr/bin/env perl
# t/183 -- '[d] dismiss' must only appear when 'd' will dismiss something visible.
#
# Reported from the field 2026-09-09: "on `[r] no module changed on disk
# [d] dismiss` pressing `d` does nothing". The hint was glued unconditionally to
# install_warning while 'd' cleared only that field, so it rendered beside the
# hot-reload banner -- a different, undismissable line -- and the key appeared
# dead. It looked INTERMITTENT because the hot-reload report self-expires after
# HOT_RELOAD_REPORT_SECS (20s): press 'd' late enough and the banner vanished on
# its own timer at about the same moment, looking like the key had worked.
#
# The rule this file pins is LATCHED vs DERIVED:
#   latched  (dismissable) -- install_warning, the hot-reload REPORT
#   derived  (not)         -- the "N modules changed" nudge, "launcher.pl
#                             changed", and the lifecycle/status alerts, all of
#                             which are recomputed from live state every gather
#                             and would simply come back.
#
# And one suppression: while a confirm is armed, Dashboard::dispatch_key runs its
# pending-branches FIRST, so 'd' cancels the confirm and dismisses nothing.
# Advertising dismiss there is the same mislabelling in a different costume.
use strict;
use warnings;
use Test::More;
use lib 'plugins/sandbox/scripts';

require tui::DashboardScreen;

sub banner_text {
    my ($state) = @_;
    my $r = tui::DashboardScreen::_banner_lines($state);
    return '' unless ref($r) eq 'ARRAY';
    return join("\n", @$r);
}
my $HINT = qr/\[d\] dismiss/;

# --- A. THE REPORTED CASE ----------------------------------------------------
{
    my $t = banner_text({ hot_reload => { headline => 'no module changed on disk' } });
    like($t, qr/no module changed on disk/, 'A1: the hot-reload banner renders');
    like($t, $HINT, 'A2 CANONICAL: the dismiss hint IS offered for a lone hot-reload report');
    my ($line) = grep { /no module changed on disk/ } split /\n/, $t;
    like($line, $HINT,
        'A3 CANONICAL: the hint sits ON the hot-reload line -- the line the key actually clears');
}

# --- B. install_warning present: hint rides the warning ----------------------
{
    my $t = banner_text({ install_warning => 'backpack not installed',
                          hot_reload      => { headline => 'no module changed on disk' } });
    my ($wline) = grep { /backpack not installed/ } split /\n/, $t;
    like($wline, $HINT, 'B1: with a warning present the hint rides the warning line');
    is(scalar(() = $t =~ /\[d\] dismiss/g), 1, 'B2: exactly ONE hint, never doubled');
}

# --- C. a confirm is armed -> no hint at all ---------------------------------
for my $pending (qw(stop-runs full-shutdown relaunch)) {
    my $t = banner_text({ install_warning => 'backpack not installed', pending => $pending });
    like($t, qr/backpack not installed/, "C: the banner still renders while '$pending' is armed");
    unlike($t, $HINT,
        "C CANONICAL: no dismiss hint while '$pending' is armed -- 'd' cancels the confirm there");
}

# --- D. DERIVED banners only -> nothing to dismiss, so no hint ---------------
{
    my $t = banner_text({ hot_reload_pending => 3, launcher_changed => 1 });
    like($t, qr/3 render modules changed/, 'D1: the derived nudge still renders');
    like($t, qr/launcher\.pl changed/,     'D2: the launcher nudge still renders');
    unlike($t, $HINT,
        'D3 CANONICAL: no hint for derived-only banners -- they are recomputed and would return');
}

# --- E. NON-VACUITY: the pre-existing case must still work --------------------
# Without this, A-D could all pass by never emitting a hint at all.
{
    my $t = banner_text({ install_warning => 'backpack not installed' });
    like($t, $HINT, 'E1 NON-VACUITY: a lone install_warning still offers the hint (unchanged)');
}
{
    my $r = tui::DashboardScreen::_banner_lines({});
    is(ref($r), 'ARRAY', 'E2: empty state returns an arrayref');
    is(scalar(@$r), 0,   'E3: empty state renders no banners and no hint');
}

# --- F. hostile / malformed state must not die -------------------------------
for my $bad ([], \"x", sub {1}, 0, '') {
    my $r = eval { tui::DashboardScreen::_banner_lines($bad) };
    ok(!$@, 'F: _banner_lines survives a non-hash state') or diag("  \$\@ = $@");
    is(ref($r), 'ARRAY', 'F: ... and still returns an arrayref');
}
{
    my $r = eval { tui::DashboardScreen::_banner_lines(
        { install_warning => 'w', pending => [] }) };
    ok(!$@, 'F: a ref-valued pending does not die');
    like(join("\n", @{ $r || [] }), $HINT,
        'F: a ref-valued pending is not "armed", so the hint is still offered');
}

done_testing();
