#!/usr/bin/env perl
# 66-dashboard-screen.t — ORACLE for package 06-dashboard-screen (blueprint
# unified-tui-design-system), specs/06-dashboard-screen-spec.md. Written BLIND
# to any tui/DashboardScreen.pm implementation -- it does not exist yet --
# directly from the spec's numbered observable behaviors (§3) and acceptance
# criteria (§4, AC-B/C/G/S/D/E/F/R/K/L/P). Do NOT weaken an assertion here to
# make a future implementation's life easier.
#
# TODAY'S EXPECTED STATE: plugins/sandbox/scripts/tui/DashboardScreen.pm does
# not exist. Every direct tui::DashboardScreen::* call below is gated on
# $DS_OK and SKIPs cleanly (not a fail, not a compile error) when it is
# false. Dashboard.pm, Theme.pm and the four tui/{Frame,Layout,Meter,Screen}
# modules ALREADY EXIST (shipped by earlier packages) and are called directly
# and unconditionally -- most of THOSE assertions are expected to go RED
# TODAY for a WRONG VALUE (the old dashboard shape: Sandbox panel present,
# breakpoint 100, four duration formats, no density suppression, no
# snapshot_state rendering) rather than a die, which is an equally valid RED
# signal and is exactly what "missing behavior" looks like here.
#
# NON-VACUITY STRATEGY (the priority named by the driver: package 05's oracle
# failed three ways that all looked like coverage -- 423 assertions that
# could not fail, an assertion forbidding what the spec mandated, and a
# fixture widened until a failing assertion passed). This file's answer,
# applied uniformly:
#   1. Count VALUE NONCES (zqxproj7714, zqxctr7714, zqxitem-a..g, zqxevt7714),
#      never label words -- AC-D, AC-K, AC-R.
#   2. Every "== 1" / "== 0" count is preceded by a SEPARATELY NAMED "> 0" /
#      liveness assertion, so "the fact was deleted entirely" fails as its
#      own assertion rather than hiding inside a single already-red one --
#      AC-D4, AC-E2/E5, AC-F3, AC-K1.
#   3. Every negative assertion (unlike/no-row/no-key) is paired with a
#      COUNTER-FIXTURE proving the SAME detector fires on a hand-built input
#      that SHOULD trip it -- AC-D3, AC-E4, AC-G5(local liveness), AC-K2,
#      AC-R2/R3, AC-L4, AC-P5/P6. A guard that cannot fire is not a guard.
#   4. Negatives are scoped to the VALUE side of the ' : ' gutter (AC-E2), or
#      to a bounded token-extraction regex (AC-F1), never to a whole rendered
#      line -- so a correct render (e.g. a role literally named 'state.warn')
#      can never trip a detector built to catch something else.
#   5. Criterion 7 ("no empty right third") is measured with
#      tui::Layout::content_reach, NEVER dead_columns (0 by construction of
#      divide() -- package 05 spec §2.3 says so in as many words).
#   6. Decision 15 (no row-count assertion) is enforced MECHANICALLY, not
#      just promised: AC-P6 below greps this file's OWN source for
#      `is(scalar(@` outside the one whitelisted frame-length identity.
#
# FIVE-ORACLE-CORRECTION CONTEXT (not this file's job, but load-bearing for
# reading its results together with the suite): t/44, t/65, t/41, t/40, t/25
# and t/64 were corrected in the SAME change as this file lands, each
# preserving an old CLAIM while moving its SUBJECT (t/44's AC-20: identical
# -> distinct; t/65's AC-D1: Dashboard has no tui:: -> tui/ has no Dashboard;
# t/41: 4 emoji constants -> Theme-derived; t/40+t/25: breakpoint 100 -> 90;
# t/64's B-E7: Theme::display_width deleted outright, not repointed).
#
# A DOCUMENTED SPEC-TEXT DEFECT (reported per this role's mandate rather than
# silently "fixed to pass"): AC-F1/AC-F2's own superset regex, copied
# character-for-character from the spec, does NOT match its own AC-F2 demo
# string '42 minutes' (verified: 'min'/'mins' are listed but not
# 'minute'/'minutes', so the trailing 'utes' fails the (?![\w]) lookahead).
# The unit-word list below is extended (minute/minutes/hour/hours added)
# so AC-F2's own explicit claim actually holds; this does not change what
# AC-F1 can capture from THIS file's own fixture (nothing in it is spelled
# "N minutes"), and does not touch the regex's other, load-bearing property:
# it also cannot capture tui::DashboardScreen's OWN compact grammar
# (\d+h\d{2}m / \d+d\d{2}h) at all -- by design, that grammar is verified
# directly against DURATION_RE() (AC-F1/F4), not via this catcher, whose job
# is to surface the THREE outlawed formats (HH:MM:SS, "Xh Ym Zs", bare
# English unit words) if any of them leak into a rendered frame.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use Encode qw(encode decode);

my $SCRIPTS      = "$Bin/../../scripts";
my $TUI_DIR      = "$SCRIPTS/tui";
my $DASHBOARD_PM = "$SCRIPTS/Dashboard.pm";
my $THEME_PM     = "$SCRIPTS/Theme.pm";
my $DS_PM        = "$TUI_DIR/DashboardScreen.pm";
my $SELF_PATH    = "$Bin/66-dashboard-screen.t";

use lib "$Bin/../../scripts";

my $NOW = 1700003600;   # pinned clock -- no real-time dependence anywhere in this file.

# ===========================================================================
# Scaffolding
# ===========================================================================

# slurp($path) -> file contents as raw bytes, or undef.
sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

# _write($path, $content) -> write bytes to a File::Temp-owned path.
sub _write {
    my ($path, $content) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print $fh $content;
    close $fh;
}

# _comment_stripped($src) -> $src with whole-line `#` comments blanked. Same
# shape as t/65-tui-render-library.t's own helper (spec's "blank comments
# before any source scan" -- this has bitten the suite five times per the
# coordinator's own hard constraint).
sub _comment_stripped {
    my ($src) = @_;
    return join("\n", map { /^\s*#/ ? '' : $_ } split /\n/, $src, -1);
}

# _balanced_braces / _strip_sub_bodies -- reused VERBATIM (same shape) from
# t/64-theme-tokens.t:322-359, per this suite's convention of reusing proven
# detector shapes rather than inventing weaker ones.
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
sub _strip_sub_bodies {
    my ($src) = @_;
    my $out = $src;
    while ($out =~ /\bsub\s+\w+\s*(?:\([^)]*\))?\s*/g) {
        my $after = pos($out);
        my $body  = _balanced_braces($out, $after);
        last unless defined $body;
        my $body_start = index($out, $body, $after);
        last if $body_start < 0;
        (my $blanked = $body) =~ s/[^\n]/ /g;
        substr($out, $body_start, length($body), $blanked);
        pos($out) = $body_start + length($blanked);
    }
    return $out;
}

# _strip_comments($src) -> $src with every full-line and trailing `#` comment
# blanked, line structure preserved so reported line numbers stay meaningful.
#
# Deliberately conservative about what counts as a comment start: a `#` is only
# treated as one when it is at the start of a line (possibly indented) or
# preceded by whitespace. That leaves `$#array`, `${\ ... }` and a `#` inside a
# string mostly intact -- and being conservative is the right direction here,
# because a `#` this MISSES simply leaves text in place for the checks to scan,
# which is the pre-existing behaviour. A `#` this over-matched would blank real
# code and hide a genuine violation.
sub _strip_comments {
    my ($src) = @_;
    return $src unless defined $src;
    my @out;
    for my $line (split(/\n/, $src, -1)) {
        if ($line =~ /^(\s*)#/) {
            $line =~ s/\S/ /g;                 # whole-line comment
        } elsif ($line =~ /^(.*?)(\s#.*)$/) {
            my ($code, $comment) = ($1, $2);
            $comment =~ s/\S/ /g;
            $line = $code . $comment;          # trailing comment
        }
        push @out, $line;
    }
    return join("\n", @out);
}

# _is_emoji / _emoji_hits -- reused VERBATIM (same shape, same block ranges)
# from t/64-theme-tokens.t:268-320 (AC-G4 mandates this explicitly).
sub _is_emoji {
    my ($cp) = @_;
    return 0 unless defined $cp;
    for my $r (
        [0x1F000, 0x1F0FF], [0x1F100, 0x1F1FF], [0x1F200, 0x1F2FF],
        [0x1F300, 0x1F5FF], [0x1F600, 0x1F64F], [0x1F650, 0x1F67F],
        [0x1F680, 0x1F6FF], [0x1F700, 0x1F77F], [0x1F780, 0x1F7FF],
        [0x1F800, 0x1F8FF], [0x1F900, 0x1F9FF], [0x1FA00, 0x1FAFF],
        [0x2600,  0x26FF],  [0x2700,  0x27BF],
    ) {
        return 1 if $cp >= $r->[0] && $cp <= $r->[1];
    }
    return 1 if $cp == 0xFE0F;
    return 0;
}
sub _emoji_hits {
    my ($text) = @_;
    return () unless defined $text;
    my @hits;
    while ($text =~ /\\x\{([0-9A-Fa-f]{2,6})\}/g) {
        my $cp = hex($1);
        next unless _is_emoji($cp);
        my $prefix = substr($text, 0, $-[0]);
        my $line = 1 + ($prefix =~ tr/\n//);
        push @hits, { cp => $cp, line => $line, how => 'escape' };
    }
    my $decoded = decode('UTF-8', $text, Encode::FB_DEFAULT);
    my $pos = 0;
    for my $ch (split //, $decoded) {
        my $cp = ord($ch);
        if (_is_emoji($cp)) {
            my $prefix = substr($decoded, 0, $pos);
            my $line = 1 + ($prefix =~ tr/\n//);
            push @hits, { cp => $cp, line => $line, how => 'literal' };
        }
        $pos += length($ch);
    }
    return @hits;
}

# _split_gutter($text) -> ($label, $value) if $text matches the row() gutter
# shape ('%-11s : %s'), else () -- used by AC-E2/AC-E4's walker. Scoped to
# the VALUE side deliberately (redteam.md M-shape: never grep the whole line
# for a literal like 'n/a', which would also match a container name).
sub _split_gutter {
    my ($text) = @_;
    return () unless defined $text && $text =~ /\A(.{11}) : (.*)\z/s;
    my ($raw_label, $value) = ($1, $2);   # captured BEFORE any further regex op --
                                           # a subsequent s/// on $raw_label would
                                           # otherwise clobber $2 (a real bug this
                                           # file hit and fixed: AC-E4 non-vacuity
                                           # was failing because of exactly this).
    (my $label = $raw_label) =~ s/\s+\z//;
    return ($label, $value);
}

# _value_is_absent_token($value) -> 1 iff the (trimmed, casefolded) VALUE
# text is a literal member of tui::DashboardScreen::ABSENT_TOKENS(). Reuses
# the closed list itself (never a re-typed copy) once tui::DashboardScreen
# has loaded; degrades to a local literal copy otherwise so this helper is
# usable even before the module exists (both lists must agree -- proven by
# AC-E1 elsewhere in this file).
my @LOCAL_ABSENT_TOKENS = ('', 'n/a', 'none', 'not configured', 'not-configured', 'disabled', 'absent', 'unknown', '?');
sub _value_is_absent_token {
    my ($value) = @_;
    return 0 unless defined $value;
    (my $v = $value) =~ s/\A\s+|\s+\z//g;
    my $lc = lc($v);
    my $tokens = ($INC{'tui/DashboardScreen.pm'} && tui::DashboardScreen->can('ABSENT_TOKENS'))
        ? tui::DashboardScreen::ABSENT_TOKENS() : \@LOCAL_ABSENT_TOKENS;
    for my $tok (@$tokens) {
        return 1 if $lc eq lc($tok);
    }
    return 0;
}

# _row_violations(\@cells, \@always_shown) -> \@violations -- walks composed
# cells, splits each on the gutter, and flags any row (not in @always_shown)
# whose VALUE is an ABSENT_TOKENS member. AC-E2's mechanism; AC-E4 proves it
# is live.
sub _row_violations {
    my ($cells, $always_shown) = @_;
    my %always = map { $_ => 1 } @{ $always_shown || [] };
    my @out;
    for my $cell (@$cells) {
        next unless ref($cell) eq 'HASH' && defined $cell->{text};
        my ($label, $value) = _split_gutter($cell->{text});
        next unless defined $label;
        next if $always{$label};
        push @out, { label => $label, value => $value } if _value_is_absent_token($value);
    }
    return \@out;
}

# Known rendered panel titles (spec §2.4.3) -- used by AC-L2's "two panel
# titles in one row" detector. The lead-in "-- <Title> " is literal ASCII
# regardless of what glyph fills the rest of the rule (tui::Frame's
# panel_title_line uses Theme's rule.h glyph, U+2500, not ASCII '-' -- so
# this detector matches only the literal lead, never the fill).
#
# UPDATED (package t01-providers-panel, spec §6): Token/Spend are gone;
# Blueprints (new sibling of Run) and Providers (Token+Spend's successor)
# take their place. This list feeds ONLY the wrap-regression detector
# (AC-L2, used below) -- leaving stale titles here would not fail any test
# today but would make that detector blind to a regression touching only
# the new titles.
my @KNOWN_PANEL_TITLES = ('Run', 'Blueprints', 'Resources', 'Providers', 'Recent activity');
sub _panel_title_hits_in_row {
    my ($text) = @_;
    return 0 unless defined $text;
    my $n = 0;
    for my $t (@KNOWN_PANEL_TITLES) {
        $n += () = $text =~ /-- \Q$t\E /g;
    }
    return $n;
}

# AC-F1/AC-F2 superset duration-token extractor. See the file-header note:
# the unit-word list is extended past the spec's literal text (minute(s),
# hour(s) added) so AC-F2's own three demo strings actually match, which the
# spec's literal regex text does not for '42 minutes'. Everything else
# (structure, the two other alternatives, the lookaround boundaries) is
# copied verbatim.
my $DUR_EXTRACT_RE = qr/(?<![\w.])\d+(?:\.\d+)?\s*(?:sec|secs|s|min|mins|minute|minutes|m|hour|hours|h|day|days|d)(?![\w])|\b\d{1,3}:\d{2}:\d{2}\b|\b\d+h \d+m \d+s\b/;

# ===========================================================================
# Load attempts. Dashboard/Theme/tui::{Frame,Layout,Meter,Screen} ship from
# earlier packages and MUST already be loadable; tui::DashboardScreen is
# THIS package's new file and is not expected to exist yet.
# ===========================================================================
my $DASH_OK = eval { require Dashboard; 1 };
ok($DASH_OK, 'plugins/sandbox/scripts/Dashboard.pm loads') or diag("  require Dashboard failed: $@");
my $THEME_OK = eval { require Theme; 1 };
ok($THEME_OK, 'plugins/sandbox/scripts/Theme.pm loads') or diag("  require Theme failed: $@");
my $LAYOUT_OK = eval { require tui::Layout; 1 };
ok($LAYOUT_OK, 'plugins/sandbox/scripts/tui/Layout.pm loads (package 05, shipped)') or diag("  require tui::Layout failed: $@");
my $FRAME_OK = eval { require tui::Frame; 1 };
ok($FRAME_OK, 'plugins/sandbox/scripts/tui/Frame.pm loads (package 05, shipped)') or diag("  require tui::Frame failed: $@");
my $METER_OK = eval { require tui::Meter; 1 };
ok($METER_OK, 'plugins/sandbox/scripts/tui/Meter.pm loads (package 05, shipped)') or diag("  require tui::Meter failed: $@");
my $SCREEN_OK = eval { require tui::Screen; 1 };
ok($SCREEN_OK, 'plugins/sandbox/scripts/tui/Screen.pm loads (package 05, shipped)') or diag("  require tui::Screen failed: $@");

my $DS_OK = eval { require tui::DashboardScreen; 1 };
ok($DS_OK, 'plugins/sandbox/scripts/tui/DashboardScreen.pm loads (THIS package -- expected to fail until 06 lands)')
    or diag("  require tui::DashboardScreen failed: $@");

BAIL_OUT('Dashboard.pm did not load -- nothing below can mean anything') unless $DASH_OK;

# ===========================================================================
# Fixtures. Declared ONCE (spec §5's "no assertion may edit it locally");
# nonces are VALUES, never label words, per the non-vacuity strategy above.
# ===========================================================================
my $PROJECT_NONCE   = 'zqxproj7714';
my $CONTAINER_NONCE = 'zqxctr7714';

my %TOKENS_PRESENT = (
    logged_in => 1, access_present => 1, access_state => 'valid',
    access_expires_at => $NOW + 11520, access_seconds_left => 11520,
    refresh_present => 1, refresh_fingerprint => 'zqxfp0011',
    refresh_expires => 'n/a (not stored)',
    last_refreshed_at => $NOW - 3600, last_refreshed_age => 3600,
    subscription_type => 'max', rate_limit_tier => 'default_max',
);
my $OAUTH_TEXT_WITH_TOKENS    = Dashboard::fmt_oauth(11520);        # "expires in 3h12m"
my $OAUTH_TEXT_WITHOUT_TOKENS = Dashboard::fmt_oauth(300);          # "expires in 5m"

my @RESOURCE_KEYS_15 = qw(
    machine_name machine_state
    ctr_mem_used vm_mem_total ctr_cpu_pct
    pod_images pod_containers pod_volumes
    host_ram_used host_ram_total
    host_disk_dev host_disk_used host_disk_total
    host_cpu_pct host_cores
);
my %RESOURCES_ALL_NA = map { $_ => undef } @RESOURCE_KEYS_15;
my %RESOURCES_FRESH_FULL = (
    %RESOURCES_ALL_NA,
    snapshot_state => 'fresh', snapshot_age => 300, snapshot_written_at => $NOW - 300,
    machine_name => 'vm-zqx', machine_state => 'running',
    ctr_mem_used => 123_456_789, vm_mem_total => 987_654_321, ctr_cpu_pct => 12.5,
    pod_images => 4, pod_containers => 2, pod_volumes => 3,
    host_ram_used => 1_000_000_000, host_ram_total => 16_000_000_000,
    host_disk_dev => '/dev/sda1', host_disk_used => 50_000_000_000, host_disk_total => 200_000_000_000,
    host_cpu_pct => 33.3, host_cores => 8,
);
my %RESOURCES_FRESH_GAPS = ( %RESOURCES_ALL_NA, snapshot_state => 'fresh', snapshot_age => 60, snapshot_written_at => $NOW - 60,
    machine_name => 'vm-zqx', machine_state => 'running' );   # 13 of 15 remain undef -> 13 suppressed rows
my %RESOURCES_STALE  = ( %RESOURCES_ALL_NA, snapshot_state => 'stale',  snapshot_age => 900, snapshot_written_at => $NOW - 900 );
my %RESOURCES_STALE_NO_AGE = ( %RESOURCES_ALL_NA, snapshot_state => 'stale', snapshot_age => undef, snapshot_written_at => undef );
my %RESOURCES_FAILED = ( %RESOURCES_ALL_NA, snapshot_state => 'failed', snapshot_age => undef, snapshot_written_at => undef );

my @BACKPACK_SEVEN_ITEMS = map { { key => "zqxitem-$_", approved => 0 } } ('a' .. 'g');
my %BACKPACK_SEVEN = ( total => 7, approved => 3, pending => 4, items => \@BACKPACK_SEVEN_ITEMS );

my @EVENTS_PLAIN = (
    LaunchLog_format_event('launch_start', {}, $NOW - 120, 111),
    LaunchLog_format_event('container_start', { exit => 0 }, $NOW - 60, 111),
);
sub LaunchLog_format_event {
    my ($type, $fields, $epoch, $pid) = @_;
    my $ok = eval { require LaunchLog; 1 };
    return '{}' unless $ok;
    return LaunchLog::format_event($type, $fields, $epoch, $pid);
}

# The "rich" state: everything present, both a with-tokens and a
# without-tokens arm (AC-D2/AC-D4's "both arms" requirement).
my %STATE_BASE = (
    project_name => $PROJECT_NONCE,
    container    => $CONTAINER_NONCE,
    status       => 'running',
    beat_age     => 12,
    uptime       => 3660,
    busy_age     => 90,
    stay_awake   => 1,
    needs_you    => 3,
    backpack     => { %BACKPACK_SEVEN },
    resources    => { %RESOURCES_FRESH_FULL },
    events       => [ @EVENTS_PLAIN ],
);
my %STATE_WITH_TOKENS = ( %STATE_BASE, tokens => { %TOKENS_PRESENT } );
my %STATE_NO_TOKENS   = ( %STATE_BASE, oauth_remaining => 300 );

# The AC-E2/AC-E5 fixture: the five named fields undef (E2), and tokens
# carrying an explicitly-absent access/refresh pair (E5, ALWAYS_SHOWN honoured).
my %STATE_ABSENTS = (
    project_name => $PROJECT_NONCE, container => $CONTAINER_NONCE, status => 'running',
    beat_age => undef, uptime => undef, busy_age => undef,
    tokens => { access_state => 'absent', refresh_present => 0, last_refreshed_age => undef, refresh_expires => undef },
    needs_you => 0,
);

# The AC-L6 "narrow-content" minimal fixture: short project name, no runs,
# no backpack, no spend, no tokens, no resources.
my %STATE_MINIMAL = ( project_name => 'p', container => 'c', status => 'running' );

# $RICH_ROWS: the row count used whenever a test needs the Activity panel to
# actually render something for %STATE_WITH_TOKENS/%STATE_NO_TOKENS (a
# content-heavy fixture: full 15-key Resources, a 7-item backpack, a 5-line
# Token panel). Measured directly against TODAY's Dashboard::activity_capacity
# for this exact fixture: 30 rows yields capacity 0 (verified), 40 yields 10,
# so 50 is a comfortable margin that stays non-zero both today (the old,
# heavier layout) and after 06 lands (the denser one, which only needs less
# room). Rows=24 is used separately, deliberately, wherever a test is about
# WIDTH/reflow (Behaviors 23-26 pin rows=24 specifically) rather than about
# activity-row content.
my $RICH_ROWS = 50;

# ===========================================================================
# AC-P1 -- load hygiene: top-level (sub bodies blanked) has no %ENV, no
# print/warn/say, no Theme:: call.
# ===========================================================================
{
    my $src = slurp($DS_PM);
    ok(defined($src), 'AC-P1: precondition -- tui/DashboardScreen.pm is readable as text (expected to fail until 06 lands)');
  SKIP: {
        skip('tui/DashboardScreen.pm does not exist yet', 3) unless defined $src;
        # COMMENTS ARE STRIPPED TOO, and that is the fix rather than a
        # loosening. AC-P1 is about load hygiene: what this module DOES when
        # it is require'd. A comment does nothing. Without this line the check
        # forbids three ordinary English words -- print, warn, say -- from
        # appearing anywhere in the file's prose outside a sub body, and this
        # module's top-level prose is where its design decisions are recorded.
        #
        # It had already fired, silently. Commit c38e594 (package t01 of
        # blueprint tui-operator-feedback) added a comment reading "the panel
        # could never say anything but", which turned this assertion red; t01's
        # validation ran t/25, t/44, t/87, t/89 and t/90 and did not include
        # this file, so the red went unnoticed until t02's own baseline sweep.
        # Package t02 then added a second occurrence ("nothing to say"),
        # which is what makes this a rule to fix rather than two words to
        # reword: the next comment will do it again.
        #
        # THE INTENT IS FULLY PRESERVED. A real top-level `print`, `warn` or
        # `say` STATEMENT is still caught -- stripping comments removes only
        # text that cannot execute. This is the same correction t01 had to make
        # to its own AC12, where an oracle forbidding a string anywhere in a
        # file failed on the comment explaining the change.
        my $top = _strip_comments(_strip_sub_bodies($src));
        unlike($top, qr/%ENV/, 'AC-P1: no top-level (outside any sub) reference to %ENV');
        unlike($top, qr/\bprint\b|\bwarn\b|\bsay\b/, 'AC-P1: no top-level print/warn/say');
        unlike($top, qr/\bTheme::\w+\s*\(/, 'AC-P1: no top-level call into Theme::');
    }
}

# ===========================================================================
# AC-P2 -- forbidden-construct scan. Table reused VERBATIM from
# t/65-tui-render-library.t (same eight classes; "the cycle" is the separate
# AC-P4 below), asserted on comment-stripped source.
# ===========================================================================
my %FORBIDDEN_CLASS = (
    clock          => qr/\b(?:time|times|localtime|gmtime)\s*\(|\bTime::HiRes\b|\bTime::Local\b/,
    environment    => qr/%ENV\b|\$ENV\{|\bTheme::capability\s*\(/,
    filesystem     => qr/\bopen\s*\(|\bopen\s+my\b|\bopen\s+\$|\bopendir\s*\(|\breaddir\s*\(|\bclose\s*\(|\bunlink\s*\(|\bmkdir\s*\(|\brename\s*\(|\bstat\s*\(|\blstat\s*\(|(?<![\w\$])-[efdsrwx]\s+[\$\(]|\bFile::\w+/,
    process        => qr/`[^`]*`|\bqx\s*[\{\(\/\#\|]|\bsystem\s*\(|\bexec\s*\(|\bfork\s*\(|\breadpipe\s*\(|\bwait\s*\(|\bwaitpid\s*\(|\bkill\s*\(|IPC::Open[23]|CORE::(?:system|exec|fork)\s*\(/,
    console        => qr/\bprint\b|\bprintf\b|\bsay\b|\bwarn\s*\(|STDIN|STDOUT|STDERR|\bbinmode\s*\(|\bselect\s*\(|\bioctl\s*\(|Term::ReadKey/,
    nondeterminism => qr/\brand\s*\(|\bsrand\s*\(|\$\$(?!\w)|\$0\b/,
    blocking       => qr/\bsleep\s*\(|\bflock\s*\(/,
    fatality       => qr/\bdie\b|\bcroak\s*\(|\bconfess\s*\(/,
);
my @CLASS_ORDER = qw(clock environment filesystem process console nondeterminism blocking fatality);

{
    my $src = slurp($DS_PM);
  SKIP: {
        skip('tui/DashboardScreen.pm does not exist yet', scalar(@CLASS_ORDER)) unless defined $src;
        my $scanned = _comment_stripped($src);
        for my $class (@CLASS_ORDER) {
            unlike($scanned, $FORBIDDEN_CLASS{$class},
                "AC-P2/Behavior27: tui/DashboardScreen.pm: no '$class' construct (purity)");
        }
    }
}

# AC-P5 -- each AC-P2 detector proven live against a File::Temp fixture.
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my %FIXTURE_SNIPPET = (
        clock          => "my \$t = time();\n",
        environment    => "my \$x = \$ENV{PATH};\n",
        filesystem     => "open(my \$fh, '<', 'x.txt');\n",
        process        => "system('ls');\n",
        console        => "print 'hi';\n",
        nondeterminism => "my \$r = rand();\n",
        blocking       => "sleep(1);\n",
        fatality       => "die 'oops';\n",
    );
    for my $class (@CLASS_ORDER) {
        my $f = "$tmpdir/$class.pl";
        _write($f, $FIXTURE_SNIPPET{$class});
        like(slurp($f), $FORBIDDEN_CLASS{$class},
            "AC-P5: the '$class' detector fires on a fixture containing that exact construct (non-vacuity)");
    }
}

# ===========================================================================
# AC-P4 -- the cycle half of Behavior 27: tui/DashboardScreen.pm names
# neither 'Dashboard' nor the literal 'Theme::display_width'.
# ===========================================================================
{
    my $src = slurp($DS_PM);
  SKIP: {
        skip('tui/DashboardScreen.pm does not exist yet', 2) unless defined $src;
        my $scanned = _comment_stripped($src);
        unlike($scanned, qr/\bDashboard\b/, 'AC-P4: tui/DashboardScreen.pm names no Dashboard identifier anywhere');
        unlike($scanned, qr/\QTheme::display_width\E/, 'AC-P4: tui/DashboardScreen.pm names no literal Theme::display_width');
    }
}
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $f1 = "$tmpdir/use-dash.pl";
    _write($f1, "use Dashboard;\n");
    like(slurp($f1), qr/\bDashboard\b/, 'AC-P5: the AC-P4 Dashboard-name detector fires on a fixture naming Dashboard (non-vacuity)');
    my $f2 = "$tmpdir/theme-dw.pl";
    _write($f2, "my \$w = Theme::display_width('x');\n");
    like(slurp($f2), qr/\QTheme::display_width\E/, 'AC-P5: the AC-P4 Theme::display_width detector fires on a fixture naming it (non-vacuity)');
}

# ===========================================================================
# Behavior 27 (byte >= 0x80 / raw SGR / hex colour) -- rounding out the
# purity/hygiene scan alongside AC-P2/AC-P4.
# ===========================================================================
{
    my $src = slurp($DS_PM);
  SKIP: {
        skip('tui/DashboardScreen.pm does not exist yet', 4) unless defined $src;
        my $scanned = _comment_stripped($src);
        ok(($src !~ /[\x80-\xFF]/), 'Behavior27: tui/DashboardScreen.pm contains no byte >= 0x80');
        unlike($scanned, qr/\\e\b|\\x1[bB]\b|\\x\{1[bB]\}|\\033\b|\\027\b/, 'Behavior27: no escape-literal ESC form');
        unlike($src, qr/\x1B/, 'Behavior27: no literal ESC byte (0x1B) in source');
        unlike($scanned, qr/#(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})\b/, 'Behavior27: no hex colour literal');
    }
}

# ===========================================================================
# AC-P3 -- totality: every public tui::DashboardScreen function survives the
# hostile corpus without dying or warning. $SIG{__WARN__} turns a warning
# into a failure.
# ===========================================================================
{
    my @HOSTILE = (undef, '', [], {}, bless({}, 'ZqxHostile'), "\xC0\x80", "\x9B", ('y' x 10240));
    my %CALLS = (
        'compose'                => sub { tui::DashboardScreen::compose($_[0], 24, 80) },
        'screen'                 => sub { tui::DashboardScreen::screen($_[0], 80) },
        'panels'                 => sub { tui::DashboardScreen::panels($_[0], 80) },
        'header_spans'           => sub { tui::DashboardScreen::header_spans($_[0], 80) },
        'fmt_duration'           => sub { tui::DashboardScreen::fmt_duration($_[0]) },
        'is_absent'              => sub { tui::DashboardScreen::is_absent($_[0]) },
        'row'                    => sub { tui::DashboardScreen::row({ label => 'x', value => $_[0] }) },
        'collapse_records'       => sub { tui::DashboardScreen::collapse_records($_[0]) },
        'snapshot_spans'         => sub { tui::DashboardScreen::snapshot_spans($_[0]) },
        'backpack_summary_spans' => sub { tui::DashboardScreen::backpack_summary_spans($_[0]) },
        'theme_role'             => sub { tui::DashboardScreen::theme_role($_[0]) },
    );
  SKIP: {
        skip('tui::DashboardScreen did not load', scalar(keys %CALLS) * scalar(@HOSTILE) * 2) unless $DS_OK;
        for my $name (sort keys %CALLS) {
            for my $h (@HOSTILE) {
                my $warned = 0;
                local $SIG{__WARN__} = sub { $warned++ };
                my $died = !eval { $CALLS{$name}->($h); 1 };
                my $label = !defined($h) ? 'undef' : (ref($h) ? ref($h) || 'REF' : (length($h) > 20 ? '<long/binary>' : $h));
                ok(!$died, "AC-P3: tui::DashboardScreen::$name survives hostile input ($label) without dying");
                ok(!$warned, "AC-P3: tui::DashboardScreen::$name survives hostile input ($label) without warning");
            }
        }
        for my $accessor (qw(DURATION_RE ABSENT_TOKENS ALWAYS_SHOWN LABEL_GUTTER)) {
            my $warned = 0;
            local $SIG{__WARN__} = sub { $warned++ };
            my $died = !eval { no strict 'refs'; &{"tui::DashboardScreen::$accessor"}(); 1 };
            ok(!$died, "AC-P3: tui::DashboardScreen::$accessor() (0-arg) survives without dying");
            ok(!$warned, "AC-P3: tui::DashboardScreen::$accessor() (0-arg) survives without warning");
        }
    }
}

# ===========================================================================
# AC-P6 -- Decision 15 self-scan (criterion 1). Decision 15's actual concern
# is a ROW/PANEL-COUNT pin over a COMPOSED FRAME (the kind that turns a done
# sibling red the moment a later package adds a panel) -- NOT every
# `is(scalar(@...))` in this file (most of those count DETECTOR HITS,
# collapse_records() outputs, or fixture sizes, which are not frame shape
# pins at all and must not be flagged; a scanner that flagged them would
# itself be the over-broad-negative vacuity trap the driver named). Scoped
# to this file's own frame-variable naming convention ($f / $frame, with an
# optional numeric/word suffix, e.g. $f0/$f_diff_right/$frame2): the ONLY
# permitted shape is the $rows-length identity `is(scalar(@$f...), $rows,
# ...)`.
# ===========================================================================
{
    my $self_src = slurp($SELF_PATH);
    ok(defined($self_src), 'AC-P6: precondition -- this file is readable as text (self-scan)');
  SKIP: {
        skip('self unreadable', 1) unless defined $self_src;
        my @hits = ($self_src =~ /is\(\s*scalar\(\@\$(?:f|frame)\w*\)[^\n]*/g);
        my @non_whitelisted = grep { !/\$rows\b/ } @hits;
        is(scalar(@non_whitelisted), 0,
            'AC-P6 (Decision 15 self-scan): every is(scalar(@$f.../@$frame...)) in this file is the whitelisted $rows-length identity')
            or diag("  offenders: " . join(' | ', @non_whitelisted));
    }
}
{
    # AC-P6 non-vacuity: the self-scan detector fires on a hand-built line
    # matching the forbidden shape (a frame row-count NOT compared to $rows).
    # BUILT VIA CONCATENATION, deliberately -- if this fixture appeared as one
    # contiguous literal substring in this file's OWN source, the self-scan
    # above (which slurps this whole file) would trip on the fixture itself
    # rather than on a real offending assertion (the same self-referential
    # trap tui::Screen.pm's own AC-P2 comment names and works around).
    my $fixture_line = 'is(scalar(@$' . 'frame), 42, "pinned panel count");';
    my @hits = ($fixture_line =~ /is\(\s*scalar\(\@\$(?:f|frame)\w*\)[^\n]*/g);
    my @non_whitelisted = grep { !/\$rows\b/ } @hits;
    ok(scalar(@non_whitelisted) > 0, 'AC-P6 non-vacuity: the self-scan detector fires on a hand-built row-count-pin line');
}

# ===========================================================================
# AC-B -- the breakpoint (Obligation 1, criterion 7, Decision 14)
# ===========================================================================
{
    my $BP = tui::Layout::BREAKPOINT_TWO_COL();
    for my $c (60, $BP - 1) {
        is(Dashboard::_two_col_mode($c), 0, "AC-B1: _two_col_mode($c) == 0 (below breakpoint)");
    }
    for my $c ($BP, $BP + 1, 99, 100, 120, 200) {
        is(Dashboard::_two_col_mode($c), 1, "AC-B1: _two_col_mode($c) == 1 (at/above breakpoint)");
    }
    for my $c (undef, '', 'abc', 0, -5) {
        my $label = defined($c) ? ($c eq '' ? "''" : $c) : 'undef';
        is(Dashboard::_two_col_mode($c), 0, "AC-B1: _two_col_mode($label) == 0 (degradation)");
    }

    is(Dashboard::_two_col_min_cols(), tui::Layout::BREAKPOINT_TWO_COL(),
        'AC-B2: Dashboard::_two_col_min_cols() == tui::Layout::BREAKPOINT_TWO_COL() (derivation, not a re-pinned literal)');
    is(tui::Layout::BREAKPOINT_TWO_COL(), 90,
        'AC-B2: tui::Layout::BREAKPOINT_TWO_COL() == 90'); # shape-lint: intentional -- Decision 14 locks the responsive breakpoint at 90 columns
}
{
    my $src = slurp($DASHBOARD_PM);
    ok(defined($src), 'AC-B3: precondition -- Dashboard.pm is readable as text');
  SKIP: {
        skip('Dashboard.pm unreadable', 1) unless defined $src;
        my $scanned = _comment_stripped($src);
        my @susp = grep { /_two_col|threshold/i } split /\n/, $scanned;
        my @bad  = grep { /\b(?:90|100)\b/ && !/BREAKPOINT_TWO_COL/ } @susp;
        is(scalar(@bad), 0,
            'AC-B3/Behavior7: Dashboard.pm names no numeric two-column threshold literal in a _two_col*/threshold context')
            or diag("  offending lines: " . join(' | ', @bad));
    }
}
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $f = "$tmpdir/two-col-fixture.pl";
    _write($f, "sub _two_col_min_cols { return 100; }\n");
    my $scanned = _comment_stripped(slurp($f));
    my @susp = grep { /_two_col|threshold/i } split /\n/, $scanned;
    my @bad  = grep { /\b(?:90|100)\b/ && !/BREAKPOINT_TWO_COL/ } @susp;
    ok(scalar(@bad) > 0, 'AC-B3 non-vacuity: the threshold-literal detector fires on a fixture containing "sub _two_col_min_cols { return 100; }"');
}
# AC-B4 (t/40-layout-responsive.t's 53-literal migration) is dischargeable in
# t/40 itself, which is in this package's write set -- see that file's
# file-header note. Not re-tested here; a test may not certify its sibling.

# ===========================================================================
# AC-C -- the dependency edge (Obligation 2)
# ===========================================================================
{
    my $src = slurp($THEME_PM);
    ok(defined($src), 'AC-C1: precondition -- Theme.pm is readable as text');
  SKIP: {
        skip('Theme.pm unreadable', 1) unless defined $src;
        my $scanned = _comment_stripped($src);
        unlike($scanned, qr/\brequire\s+Dashboard\b|\bDashboard::\w+/,
            'AC-C1: Theme.pm names no require Dashboard / Dashboard:: qualified call');
    }
}
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $f = "$tmpdir/require-dash.pl";
    _write($f, "require Dashboard;\n");
    like(_comment_stripped(slurp($f)), qr/\brequire\s+Dashboard\b|\bDashboard::\w+/,
        'AC-C1 non-vacuity: the detector fires on a fixture containing "require Dashboard;"');
}
# AC-C2 CORRECTED (consistent with t/64's B-E7 correction, same driver ruling
# E-F: Theme::display_width is DELETED OUTRIGHT, not repointed at
# tui::Layout -- repointing alone only trades a Theme<->Dashboard 2-cycle for
# a Theme<->tui::Layout 2-cycle, since tui::Layout does `use Theme;` at
# compile time). The spec's literal AC-C2 text ("Theme::display_width agrees
# with tui::Layout::display_width") assumed the repoint-only design that
# predates the driver's final ruling; asserting it here would call a
# function the ruling requires to no longer exist. Corrected claim: Theme.pm
# no longer defines display_width at all.
ok(!Theme->can('display_width'),
    'AC-C2 (corrected, driver ruling E-F): Theme.pm no longer defines display_width -- deleted outright, not repointed');
{
    # AC-C3: loading Theme alone does not pull Dashboard.pm into %INC.
    # Genuine isolation needs a subprocess (this file itself already loads
    # Dashboard for other ACs) -- the $^X-subprocess idiom is an established
    # convention in this suite (t/43, t/44's AC-32).
    my ($fh, $probe_path) = tempfile(SUFFIX => '.pl');
    print $fh "require Theme;\nprint( (exists \$INC{'Dashboard.pm'}) ? 'PULLED' : 'CLEAN' );\n";
    close $fh;
    my $cmd = sprintf('"%s" -I"%s" "%s" 2>&1', $^X, $SCRIPTS, $probe_path);
    my $out = `$cmd`;
    is($out, 'CLEAN', 'AC-C3: loading Theme alone (isolated subprocess) does not pull Dashboard.pm into %INC');
}

# ===========================================================================
# AC-G -- glyphs and widths (Obligations 3 and 5)
# ===========================================================================
{
    my $glyphs = Theme::glyphs();
    for my $name (sort keys %$glyphs) {
        my $g = $glyphs->{$name};
        is(Dashboard::display_width($g->{bytes}), $g->{width}, "AC-G1: Dashboard::display_width(glyph '$name') == Theme's declared width");
        is(Dashboard::glyph_width($g->{bytes}), $g->{width}, "AC-G1: Dashboard::glyph_width(glyph '$name') == Theme's declared width");
    }
}
{
    my $table = Dashboard::glyph_table();
    ok(exists $table->{"\x{FF5C}"}, 'AC-G2: Dashboard::glyph_table() contains U+FF5C (sep.bar), by membership not table size');
    is($table->{"\x{FF5C}"}, 2, 'AC-G2: U+FF5C is declared at width 2') if exists $table->{"\x{FF5C}"};
    for my $cp (0x1F7E2, 0x1F534, 0x1F7E1, 0x26AA) {
        ok(!exists $table->{ chr($cp) }, sprintf('AC-G2: Dashboard::glyph_table() contains NO U+%04X (emoji circle), by membership', $cp));
    }
}
{
    my @CORPUS = ('ascii only text 123', '');
    push @CORPUS, map { Theme::glyph($_) } sort keys %{ Theme::glyphs() };
    push @CORPUS, "\xFF\xFE\x80", "\e[1;31mred\e[0m plain", ('x' x 10240);
    for my $i (0 .. $#CORPUS) {
        is(Dashboard::display_width($CORPUS[$i]), tui::Layout::display_width($CORPUS[$i]),
            "AC-G3/Behavior1: Dashboard::display_width agrees with tui::Layout::display_width (corpus item $i)");
    }
}
{
    my $src = slurp($DASHBOARD_PM);
  SKIP: {
        skip('Dashboard.pm unreadable', 1) unless defined $src;
        my @hits = _emoji_hits($src);
        is(scalar(@hits), 0, 'AC-G4/Behavior4: Dashboard.pm source contains no emoji codepoint (raw byte or \\x{...} escape)');
        diag(sprintf("  U+%04X at line %d (%s)", $_->{cp}, $_->{line}, $_->{how})) for @hits;
    }
}
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $f = "$tmpdir/emoji-fixture.pl";
    _write($f, "my \$g = \"\\x{1F534}\";\n");
    my @hits = _emoji_hits(slurp($f));
    ok(scalar(@hits) > 0, 'AC-G4 non-vacuity/AC-P5: the emoji detector fires on a fixture containing "\\x{1F534}"');
}
# AC-G5: waiver-clearance is a LEDGER VALIDATION COMMAND, not asserted here
# (a test may not certify its sibling): once this package clears Dashboard.pm's
# emoji constants and the sep.bar glyph, run
#   perl plugins/sandbox/tests/t/64-theme-tokens.t
# and confirm it is green with %EMOJI_PENDING{'plugins/sandbox/scripts/Dashboard.pm'}
# and %PENDING_GLYPH_REGISTRATION{'sep.bar'} DELETED from that file. Leaving
# either in place makes t/64 fail with STALE ENTRY -- that red is the
# mechanism proving this package landed, observed once then cleared.
# AC-G6 (width-sensitive assertion migration rule) is a REVIEWER'S RULE for
# OTHER oracles (t/41's correction in this same change already applies it:
# Theme::glyph('status.*') selected live, fails loudly if missing, rather
# than a hardcoded emoji literal) -- not a distinct t/66 assertion.

# ===========================================================================
# AC-S -- snapshot_state (Obligation 4, adapter contract Rule 4)
# ===========================================================================
{
    is_deeply([ Dashboard::_resources_lines(undef) ], [], 'AC-S4/Behavior19: Dashboard::_resources_lines(undef) returns the empty list');
    is_deeply([ Dashboard::_resources_lines('x') ], [], 'AC-S4/Behavior19: Dashboard::_resources_lines(\'x\') returns the empty list');
}
sub _dlines_text {
    my ($res) = @_;
    my @lines = eval { Dashboard::_resources_lines($res) };
    return '<CALL FAILED>' if $@;
    return join("\n", map {
        ref($_) eq 'ARRAY' ? join('', map { (ref($_) eq 'HASH' && defined $_->{text}) ? $_->{text} : '' } @$_) : ''
    } @lines);
}
{
    my $fresh_full  = _dlines_text(\%RESOURCES_FRESH_FULL);
    my $fresh_gaps  = _dlines_text(\%RESOURCES_FRESH_GAPS);
    my $stale_text  = _dlines_text(\%RESOURCES_STALE);
    my $failed_text = _dlines_text(\%RESOURCES_FAILED);
    my $plain_text  = _dlines_text({ %RESOURCES_ALL_NA });

    isnt($fresh_full,  $stale_text,  'AC-S1/Behavior20: fresh renders DISTINCTLY from stale');
    isnt($fresh_full,  $failed_text, 'AC-S1/Behavior20: fresh renders DISTINCTLY from failed');
    isnt($stale_text,  $failed_text, 'AC-S1/Behavior20: stale renders DISTINCTLY from failed');
    isnt($fresh_full,  $plain_text,  'AC-S1/Behavior20: fresh renders DISTINCTLY from the never-written (no snapshot_state key) case');
    isnt($stale_text,  $plain_text,  'AC-S1/Behavior20: stale renders DISTINCTLY from the never-written case');
    isnt($failed_text, $plain_text,  'AC-S1/Behavior20: failed renders DISTINCTLY from the never-written case');

    unlike(_dlines_text(\%RESOURCES_STALE_NO_AGE), qr/\b0[smhd]\b/,
        'AC-S2/Behavior21: stale with snapshot_age undef renders NO fabricated zero-duration clause');
    like('stale, 0s ago', qr/\b0[smhd]\b/,
        'AC-S2 non-vacuity: the fabricated-zero detector fires on a hand-built "stale, 0s ago" string');

    unlike($stale_text,  qr/\bn\/a\b/i, 'AC-S5: the stale panel contains no n/a row');
    unlike($failed_text, qr/\bn\/a\b/i, 'AC-S5: the failed panel contains no n/a row');
    unlike($fresh_full,  qr/\bn\/a\b/i, 'AC-S3: fresh-with-every-value panel renders no n/a row');
    unlike($fresh_full,  qr/unavailable/i, 'AC-S3: fresh-with-every-value panel names no unavailable clause');
    like($fresh_gaps, qr/(\d+)\s*facts?\s*unavailable/i, 'AC-S5: the fresh-with-gaps panel names a count of suppressed facts, pluralised')
        or diag("  rendered: $fresh_gaps");
    if ($fresh_gaps =~ /(\d+)\s*facts?\s*unavailable/i) {
        is($1, 13, 'AC-S5: the fresh-with-gaps count equals the number of suppressed rows (13 of 15 keys undef)');
    }
}

# ===========================================================================
# AC-D -- no duplicated facts (criterion 2)
# ===========================================================================
{
    my $f = eval { Dashboard::compose_frame(\%STATE_WITH_TOKENS, $RICH_ROWS, 120) };
    ok(!$@, 'AC-D1 precondition: compose_frame(with-tokens fixture) does not die') or diag($@);
    my $joined = defined($f) ? join("\n", map { $_->{text} } @$f) : '';

    my $n_project   = () = $joined =~ /\Q$PROJECT_NONCE\E/g;
    my $n_container = () = $joined =~ /\Q$CONTAINER_NONCE\E/g;
    my $n_oauth     = () = $joined =~ /\Q$OAUTH_TEXT_WITH_TOKENS\E/g;

    cmp_ok($n_project,   '>', 0, 'AC-D4: project nonce appears at least once (with tokens) -- over-suppression guard');
    cmp_ok($n_container, '>', 0, 'AC-D4: container nonce appears at least once (with tokens) -- over-suppression guard');
    cmp_ok($n_oauth,      '>', 0, 'AC-D4: oauth text appears at least once (with tokens) -- over-suppression guard');
    is($n_project,   1, 'AC-D1: project nonce appears EXACTLY once (with tokens)');
    is($n_container, 1, 'AC-D1: container nonce appears EXACTLY once (with tokens)');
    is($n_oauth,     1, 'AC-D1: oauth value appears EXACTLY once (with tokens)');
}
{
    my $f = eval { Dashboard::compose_frame(\%STATE_NO_TOKENS, $RICH_ROWS, 120) };
    ok(!$@, 'AC-D2 precondition: compose_frame(without-tokens fixture) does not die') or diag($@);
    my $joined = defined($f) ? join("\n", map { $_->{text} } @$f) : '';

    my $n_project   = () = $joined =~ /\Q$PROJECT_NONCE\E/g;
    my $n_container = () = $joined =~ /\Q$CONTAINER_NONCE\E/g;
    my $n_oauth     = () = $joined =~ /\Q$OAUTH_TEXT_WITHOUT_TOKENS\E/g;

    cmp_ok($n_project,   '>', 0, 'AC-D4: project nonce appears at least once (without tokens) -- over-suppression guard');
    cmp_ok($n_container, '>', 0, 'AC-D4: container nonce appears at least once (without tokens) -- over-suppression guard');
    cmp_ok($n_oauth,      '>', 0, 'AC-D4: oauth text appears at least once (without tokens) -- over-suppression guard');
    is($n_project,   1, 'AC-D2: project nonce appears EXACTLY once (without tokens)');
    is($n_container, 1, 'AC-D2: container nonce appears EXACTLY once (without tokens)');
    is($n_oauth,     1, 'AC-D2: oauth value (Run-panel row) appears EXACTLY once (without tokens)');
}
{
    # AC-D3 -- non-vacuity counter-fixture. Injected through the PUBLIC
    # screen()/panels() return value (screen()'s 'panels' key IS panels()'s
    # own return per spec §2.4, so mutating it is mutating that same public
    # data), never by editing the module.
  SKIP: {
        skip('tui::DashboardScreen did not load', 1) unless $DS_OK;
        my $screen = eval { tui::DashboardScreen::screen(\%STATE_WITH_TOKENS, 120) };
        skip('tui::DashboardScreen::screen died', 1) if $@ || ref($screen) ne 'HASH';
        my $panels = $screen->{panels};
        skip('screen()->{panels} is not an arrayref', 1) unless ref($panels) eq 'ARRAY' && @$panels;
        push @{ $panels->[0]{lines} }, [ { text => "extra $PROJECT_NONCE line", role => 'text.primary' } ];
        my $frame = eval { tui::Screen::compose($screen, 30, 120) };
        skip('tui::Screen::compose died', 1) if $@ || ref($frame) ne 'ARRAY';
        my $joined = join("\n", map { $_->{text} } @$frame);
        my $n = () = $joined =~ /\Q$PROJECT_NONCE\E/g;
        is($n, 2, 'AC-D3 non-vacuity: a panels()-injected duplicate nonce is counted TWICE -- proves the counter is live, not blind');
    }
}

# ===========================================================================
# AC-E -- no empty rows (criterion 3)
# ===========================================================================
{
  SKIP: {
        skip('tui::DashboardScreen did not load', 1) unless $DS_OK;
        my $tokens = tui::DashboardScreen::ABSENT_TOKENS();
        is_deeply([ sort @$tokens ], [ sort @LOCAL_ABSENT_TOKENS ],
            'AC-E1 precondition: ABSENT_TOKENS() matches the spec-closed list (case-preserved membership)');
    }
    for my $tok (@LOCAL_ABSENT_TOKENS, uc('N/A'), '  none  ') {
      SKIP: {
            skip('tui::DashboardScreen did not load', 1) unless $DS_OK;
            ok(tui::DashboardScreen::is_absent($tok), "AC-E1: is_absent('$tok') is true (ABSENT_TOKENS member, case/whitespace-insensitive)");
        }
    }
    for my $v (undef, [], {}) {
      SKIP: {
            skip('tui::DashboardScreen did not load', 1) unless $DS_OK;
            my $label = defined($v) ? ref($v) : 'undef';
            ok(tui::DashboardScreen::is_absent($v), "AC-E1: is_absent($label) is true");
        }
    }
    for my $v (0, '0', '0%', 'ok', '0 items') {
      SKIP: {
            skip('tui::DashboardScreen did not load', 1) unless $DS_OK;
            ok(!tui::DashboardScreen::is_absent($v), "AC-E1: is_absent('$v') is FALSE (own description -- a genuine value is not absent)");
        }
    }
}
{
    my $f = eval { Dashboard::compose_frame(\%STATE_ABSENTS, 30, 120) };
    ok(!$@, 'AC-E2 precondition: compose_frame(all-absent fixture) does not die') or diag($@);
  SKIP: {
        skip('tui::DashboardScreen did not load', 1) unless $DS_OK;
        my $always = tui::DashboardScreen::ALWAYS_SHOWN();
        my $violations = _row_violations($f || [], $always);
        is(scalar(@$violations), 0,
            'AC-E2: the composed frame has no ABSENT_TOKENS-valued row except ALWAYS_SHOWN labels')
            or diag("  violations: " . join(' | ', map { "$_->{label} => $_->{value}" } @$violations));
    }
}
{
    my $hand_built = [ { text => sprintf('%-11s : %s', 'foo', 'n/a'), spans => [] } ];
    my $violations = _row_violations($hand_built, []);
    is(scalar(@$violations), 1, 'AC-E4 non-vacuity: the row-violation walker reports exactly 1 on a hand-built n/a row -- proves it sees rows at all');
}
{
  SKIP: {
        skip('tui::DashboardScreen did not load', 4) unless $DS_OK;
        my $always = tui::DashboardScreen::ALWAYS_SHOWN();
        ok((grep { $_ eq 'access' } @$always) ? 1 : 0, "AC-E5 precondition: ALWAYS_SHOWN() includes 'access'");
        ok((grep { $_ eq 'refresh' } @$always) ? 1 : 0, "AC-E5 precondition: ALWAYS_SHOWN() includes 'refresh'");
        my $f = eval { Dashboard::compose_frame(\%STATE_ABSENTS, 30, 120) };
        my $joined = (!$@ && defined $f) ? join("\n", map { $_->{text} } @$f) : '';
        # AMENDED BY t05-no-colons: the label gutter's separator is three
        # spaces now, not " : ". The intent -- that the row is RENDERED even
        # when its value is an absent token, so ALWAYS_SHOWN is honoured rather
        # than merely declared -- is unchanged, and these still fail if either
        # row stops being emitted. Anchored to the start of a line so a stray
        # "access" inside some other row's prose cannot satisfy them.
        like($joined, qr/^\s*access\s+\S/m, "AC-E5: the 'access' row is rendered even though its value is an absent token (ALWAYS_SHOWN honoured, not just declared)");
        like($joined, qr/^\s*refresh\s+\S/m, "AC-E5: the 'refresh' row is rendered even though its value is an absent token");
    }
}
{
    # needs you: absent at 0, present+prominent above -- both arms.
    my %ny0 = ( %STATE_WITH_TOKENS, needs_you => 0 );
    my %ny3 = ( %STATE_WITH_TOKENS, needs_you => 3 );
    my $f0 = eval { Dashboard::compose_frame(\%ny0, 30, 120) };
    my $f3 = eval { Dashboard::compose_frame(\%ny3, 30, 120) };
    my $j0 = (!$@ && defined $f0) ? join("\n", map { $_->{text} } @$f0) : '';
    my $j3 = (defined $f3) ? join("\n", map { $_->{text} } @$f3) : '';
    unlike($j0, qr/needs you/, 'AC-E3/Behavior13: needs_you==0 -> "needs you" row absent from the frame');
    like($j3, qr/needs you/, 'AC-E3/Behavior13: needs_you==3 -> "needs you" row present');
    like($j3, qr/3\s*decisions\s*waiting/, 'AC-E3: needs_you==3 row carries the count, pluralised');
  SKIP: {
        skip('tui::DashboardScreen did not load', 1) unless $DS_OK;
        my $ny_row = tui::DashboardScreen::row(label => 'needs you', value => "3 decisions waiting", role => 'state.warn');
        my ($attention_span) = grep { ref($_) eq 'HASH' && defined($_->{role}) && $_->{role} =~ /^state\.(warn|crit)$/ } @$ny_row;
        ok(defined($attention_span), 'AC-E3: the escalations value span carries a Theme ATTENTION role (state.warn/state.crit), asserted on the span not emitted bytes');
    }
}

# ===========================================================================
# AC-F -- one duration format (criterion 4)
# ===========================================================================
{
    like('1h 1m 0s', $DUR_EXTRACT_RE, "AC-F2: the superset regex matches the hand-built 'Xh Ym Zs' string");
    like('14:32:07', $DUR_EXTRACT_RE, "AC-F2: the superset regex matches the hand-built 'HH:MM:SS' string");
    like('42 minutes', $DUR_EXTRACT_RE, "AC-F2: the superset regex matches the hand-built '42 minutes' bare-English-unit string");
}
{
    my $f = eval { Dashboard::compose_frame(\%STATE_WITH_TOKENS, $RICH_ROWS, 120) };
    ok(!$@, 'AC-F1 precondition: compose_frame does not die') or diag($@);
    my $joined = (defined $f) ? join("\n", map { $_->{text} } @$f) : '';
    my @tokens = ($joined =~ /$DUR_EXTRACT_RE/g);
    # Branch classification is LOCAL regex work, independent of whether
    # tui::DashboardScreen has loaded -- it must run against TODAY's actual
    # rendered tokens too, not silently degrade to zero because the new
    # module doesn't exist yet (that was a real bug caught while verifying
    # this file: nesting this loop inside the $DS_OK SKIP block made AC-F3
    # report 0 branches for the wrong reason).
    my %branches;
    for my $t (@tokens) {
        if    ($t =~ /\A\d+s\z/)        { $branches{s}++ }
        elsif ($t =~ /\A\d+m\z/)        { $branches{m}++ }
        elsif ($t =~ /\A\d+h\d{2}m\z/)  { $branches{hm}++ }
        elsif ($t =~ /\A\d+d\d{2}h\z/)  { $branches{dh}++ }
        else                             { $branches{other}++ }
    }
  SKIP: {
        skip('tui::DashboardScreen did not load', scalar(@tokens)) unless $DS_OK;
        my $dre = tui::DashboardScreen::DURATION_RE();
        for my $t (@tokens) {
            like($t, $dre, "AC-F1/Behavior15: extracted duration-shaped token '$t' matches DURATION_RE()");
        }
    }
    cmp_ok(scalar(@tokens), '>=', 3, 'AC-F3: the fixture yields at least 3 distinct-position extracted duration tokens (floor, not a ceiling)')
        or diag("  extracted: " . join(' | ', @tokens));
    my %distinct = map { $_ => 1 } @tokens;
    cmp_ok(scalar(keys %distinct), '>=', 3, 'AC-F3: at least 3 DISTINCT token strings')
        or diag("  distinct: " . join(' | ', sort keys %distinct));
    cmp_ok(scalar(keys %branches), '>=', 2, 'AC-F3: the extracted tokens span at least 2 of DURATION_RE\'s branches')
        or diag("  branches seen: " . join(',', sort keys %branches));
}
{
  SKIP: {
        skip('tui::DashboardScreen did not load', 1) unless $DS_OK;
        my @table = (
            [ undef, 'n/a' ], [ -1, 'n/a' ], [ 0, '0s' ], [ 59, '59s' ], [ 60, '1m' ],
            [ 3599, '59m' ], [ 3600, '1h00m' ], [ 3660, '1h01m' ], [ 86399, '23h59m' ],
            [ 86400, '1d00h' ], [ 90000, '1d01h' ],
        );
        my $dre = tui::DashboardScreen::DURATION_RE();
        for my $row (@table) {
            my ($in, $want) = @$row;
            my $label = defined($in) ? $in : 'undef';
            is(tui::DashboardScreen::fmt_duration($in), $want, "AC-F4: fmt_duration($label) eq '$want'");
            like(tui::DashboardScreen::fmt_duration($in), $dre, "AC-F4: fmt_duration($label) matches DURATION_RE()");
        }
    }
}
{
    for my $path ($DASHBOARD_PM, $DS_PM) {
        my $src = slurp($path);
      SKIP: {
            skip("$path unreadable", 1) unless defined $src;
            my $scanned = _comment_stripped($src);
            my @fmt_hms_hits  = grep { /\bfmt_hms\b/ && !/^\s*sub\s+fmt_hms\b/ } split /\n/, $scanned;
            my @event_t_hits  = grep { /\b_event_time\b/ && !/^\s*sub\s+_event_time\b/ } split /\n/, $scanned;
            is(scalar(@fmt_hms_hits), 0, "AC-F5: $path calls fmt_hms only in its own definition (not on the render path)")
                or diag("  " . join(' | ', @fmt_hms_hits));
            is(scalar(@event_t_hits), 0, "AC-F5: $path calls _event_time only in its own definition (not on the render path)")
                or diag("  " . join(' | ', @event_t_hits));
        }
    }
}

# ===========================================================================
# AC-R -- collapsed repeats (criterion 5)
# ===========================================================================
{
  SKIP: {
        skip('tui::DashboardScreen did not load', 20) unless $DS_OK;

        my @run4 = map { { epoch => $NOW + $_, body => 'zqxevt-A', role => 'text.primary', glyph => 'x' } } (0 .. 3);
        my $out4 = tui::DashboardScreen::collapse_records(\@run4);
        is(scalar(@$out4), 1, 'AC-R1/Behavior16(a): 4 consecutive identical records collapse to 1');
        is($out4->[0]{count}, 4, 'AC-R1: the collapsed record carries count == 4') if @$out4;
        is($out4->[0]{epoch}, $NOW + 3, 'AC-R1: the collapsed record carries the NEWEST member\'s epoch') if @$out4;

        my @aba = (
            { epoch => $NOW,     body => 'zqxevt-A', role => 'text.primary', glyph => 'x' },
            { epoch => $NOW + 1, body => 'zqxevt-B', role => 'text.primary', glyph => 'x' },
            { epoch => $NOW + 2, body => 'zqxevt-A', role => 'text.primary', glyph => 'x' },
        );
        my $out_aba = tui::DashboardScreen::collapse_records(\@aba);
        is(scalar(@$out_aba), 3, 'AC-R2 non-vacuity: non-adjacent duplicates (A,B,A) do NOT collapse -- 3 records remain');
        ok(!(grep { exists $_->{count} } @$out_aba), 'AC-R2: none of the 3 uncollapsed records carries a count key');

        my @singles = map { { epoch => $NOW + $_, body => "zqxevt-single-$_", role => 'text.primary', glyph => 'x' } } (0 .. 3);
        my $out_singles = tui::DashboardScreen::collapse_records(\@singles);
        is(scalar(@$out_singles), 4, 'AC-R3 setup: 4 distinct records stay 4 records');
        ok(!(grep { exists $_->{count} } @$out_singles), 'AC-R3/Behavior17: a run of length 1 carries no count key (no implementation always appends a count)');

        my @mixed = (
            { epoch => $NOW,     body => 'zqxevt-A', role => 'r', glyph => 'g' },
            { epoch => $NOW + 1, body => 'zqxevt-A', role => 'r', glyph => 'g' },
            { epoch => $NOW + 2, body => 'zqxevt-A', role => 'r', glyph => 'g' },
            { epoch => $NOW + 3, body => 'zqxevt-B', role => 'r', glyph => 'g' },
            { epoch => $NOW + 4, body => 'zqxevt-C', role => 'r', glyph => 'g' },
            { epoch => $NOW + 5, body => 'zqxevt-C', role => 'r', glyph => 'g' },
        );
        my $out_mixed = tui::DashboardScreen::collapse_records(\@mixed);
        is(scalar(@$out_mixed), 3, 'AC-R4: mixed run A,A,A,B,C,C collapses to 3 records');
        if (@$out_mixed == 3) {
            is($out_mixed->[0]{count}, 3, 'AC-R4: record 0 (A run) carries count == 3');
            ok(!exists $out_mixed->[1]{count}, 'AC-R4: record 1 (B, singleton) carries no count');
            is($out_mixed->[2]{count}, 2, 'AC-R4: record 2 (C run) carries count == 2');
        }
    }
}
{
    # AC-R5: the collapse is visible IN A RENDERED FRAME, not only in
    # collapse_records's return. 4 consecutive identical real events via
    # LaunchLog::format_event + Dashboard::recent_events.
    my @lines = map { LaunchLog_format_event('zqxevt7714', {}, $NOW - (4 - $_), 111) } (0 .. 3);
    my $events = eval { Dashboard::recent_events(\@lines, 10, undef, $NOW) };
    ok(!$@, 'AC-R5 precondition: Dashboard::recent_events does not die on the 4-identical-event fixture') or diag($@);
    my %se = ( %STATE_WITH_TOKENS, events => $events );
    my $f = eval { Dashboard::compose_frame(\%se, $RICH_ROWS, 120) };
    ok(!$@, 'AC-R5 precondition: compose_frame does not die') or diag($@);
    my $joined = (defined $f) ? join("\n", map { $_->{text} } @$f) : '';
    my $n_x4   = () = $joined =~ / x4\b/g;
    my $n_body = () = $joined =~ /zqxevt7714/g;
    is($n_x4, 1, 'AC-R5: the rendered frame contains " x4" exactly once');
    is($n_body, 1, 'AC-R5: the collapsed body text ("zqxevt7714") appears exactly once, not 4 times');
    unlike($joined, qr/ x1\b/, 'AC-R3/Behavior17: the substring " x1" never appears in this (or any) frame produced in this file');
}

# ===========================================================================
# AC-K -- backpack summary only (criterion 6, Decision 9)
# ===========================================================================
{
  SKIP: {
        skip('tui::DashboardScreen did not load', 6) unless $DS_OK;
        is_deeply(tui::DashboardScreen::backpack_summary_spans({ total => 0 }), [],
            'AC-K3/Behavior18: total==0 -> no backpack row at all');
        is_deeply(tui::DashboardScreen::backpack_summary_spans('not a hashref'), [],
            'AC-K3: a non-hashref %bp -> no backpack row (total)');
        my $no_pending = tui::DashboardScreen::backpack_summary_spans({ total => 5, approved => 5, pending => 0 });
        my $txt_np = join('', map { $_->{text} } @$no_pending);
        unlike($txt_np, qr/pending/, 'AC-K4: pending==0 -> no pending clause');
        like($txt_np, qr/5 items/, q{AC-K4 precondition: total renders as "5 items" -- pluralised});
        my $one = tui::DashboardScreen::backpack_summary_spans({ total => 1, approved => 1, pending => 0 });
        like(join('', map { $_->{text} } @$one), qr/\b1 item\b/,
             q{AC-K4: a count of 1 renders the SINGULAR "1 item" -- the whole point of dropping "(s)"});
        my $with_pending = tui::DashboardScreen::backpack_summary_spans({ total => 5, approved => 2, pending => 3 });
        my $txt_wp = join('', map { $_->{text} } @$with_pending);
        like($txt_wp, qr/pending/, 'AC-K4: pending>0 -> pending clause present');
        like($txt_wp, qr/3\s*pending/, 'AC-K4: the pending clause names the pending count');
    }
}
{
    my $f = eval { Dashboard::compose_frame(\%STATE_WITH_TOKENS, $RICH_ROWS, 120) };
    ok(!$@, 'AC-K1 precondition: compose_frame(7-item backpack fixture) does not die') or diag($@);
    my $joined = (defined $f) ? join("\n", map { $_->{text} } @$f) : '';
    my $n_total = () = $joined =~ /7 items/g;
    cmp_ok($n_total, '>', 0, q{AC-D4-style guard: "7 items" appears at least once});
    my @leaked = grep { $joined =~ /\Q$_\E/ } map { "zqxitem-$_" } ('a' .. 'g');
    is(scalar(@leaked), 0, 'AC-K1/Behavior18: none of the 7 backpack item keys appear anywhere in the rendered frame')
        or diag("  leaked: " . join(',', @leaked));
    like($joined, qr/7 items/, q{AC-K1: the frame contains "7 items"});
    unlike($joined, qr/\bitem\(s\)/, q{AC-K1: and never the lazy "item(s)" form the operator called out});
}
{
    my $hand_built = "some frame text mentioning zqxitem-c in a row\n";
    my @leaked = grep { $hand_built =~ /\Q$_\E/ } map { "zqxitem-$_" } ('a' .. 'g');
    ok(scalar(@leaked) > 0, 'AC-K2 non-vacuity: the key-leak detector fires on a hand-built frame carrying "zqxitem-c"');
}

# ===========================================================================
# AC-L -- reflow and dead space (criterion 7, Decisions 13/14)
# ===========================================================================
{
    my $violations = 0;
    my $first_bad;
    for my $cols (60 .. 200) {
        my $f = eval { Dashboard::compose_frame(\%STATE_WITH_TOKENS, 24, $cols) };
        next if $@ || ref($f) ne 'ARRAY';
        for my $i (0 .. $#$f) {
            my $w = Dashboard::display_width($f->[$i]{text});
            if ($w != $cols || length($f->[$i]{text}) - 0 < 0) {
                $violations++;
                $first_bad ||= "cols=$cols row=$i width=$w";
            }
        }
    }
    is($violations, 0, 'AC-L1/Behavior23: over cols 60..200 at rows=24, every cell is exactly $cols display columns')
        or diag("  first offender: " . ($first_bad // '?'));
}
{
    for my $cols (60, 80, 89) {
        my $f = eval { Dashboard::compose_frame(\%STATE_WITH_TOKENS, 24, $cols) };
        my $both = 0;
        $both = grep { _panel_title_hits_in_row($_->{text}) >= 2 } @$f if !$@ && ref($f) eq 'ARRAY';
        is($both, 0, "AC-L2/Behavior24: at cols=$cols (< breakpoint), no row carries two panel titles");
    }
    for my $cols (90, 91, 120, 200) {
        my $f = eval { Dashboard::compose_frame(\%STATE_WITH_TOKENS, 24, $cols) };
        my $both = 0;
        $both = grep { _panel_title_hits_in_row($_->{text}) >= 2 } @$f if !$@ && ref($f) eq 'ARRAY';
        cmp_ok($both, '>=', 1, "AC-L2/Behavior24: at cols=$cols (>= breakpoint) with >=2 panels, at least one row carries two panel titles");
    }
}
{
    for my $cols (90, 120, 160, 200) {
        my $f = eval { Dashboard::compose_frame(\%STATE_WITH_TOKENS, 24, $cols) };
        next if $@ || ref($f) ne 'ARRAY';
        my $reach = tui::Layout::content_reach($f);
        my $rts   = tui::Layout::right_third_start($cols);
        cmp_ok($reach, '>=', $rts, "AC-L3/Behavior25: at cols=$cols, content_reach >= right_third_start (no empty right third)");
    }
    for my $cols (90, 120, 160, 200) {
        my $f = eval { Dashboard::compose_frame(\%STATE_MINIMAL, 24, $cols) };
        next if $@ || ref($f) ne 'ARRAY';
        my $reach = tui::Layout::content_reach($f);
        my $rts   = tui::Layout::right_third_start($cols);
        cmp_ok($reach, '>=', $rts, "AC-L6 (narrow-content arm): at cols=$cols with the minimal fixture, content_reach >= right_third_start");
    }
}
{
    my @hand_built;
    for (1 .. 24) {
        push @hand_built, { text => ('x' x 40) . (' ' x 160), spans => [ { text => ('x' x 40), role => 'text.primary' }, { text => (' ' x 160), role => 'text.primary' } ] };
    }
    my $reach = tui::Layout::content_reach(\@hand_built);
    cmp_ok($reach, '<', tui::Layout::right_third_start(200),
        'AC-L4 non-vacuity: content_reach on a hand-built 200-col frame whose ink stops at column 40 is LESS than right_third_start(200) -- the metric can fail');
}
is(tui::Layout::right_third_start(200), 200 - int(200 / 3),
    'AC-L5: right_third_start(200) asserted as a DERIVATION (200 - int(200/3)), not the literal 134');

# ===========================================================================
# NO_COLOR REGRESSION (fix-batch item 1 -- the point of this batch). Driver
# diagnosis, verified directly: NO_COLOR=1 still paints recent_events'
# activity-event rows in colour. Cause: recent_events builds glyph/body
# spans with event_style's LEGACY role names ('good'/'bad'/'warn'/...), and
# Dashboard::sgr_for_role only routes THEME role names (Theme::roles()'
# nine) through Theme::sgr (which honours NO_COLOR) -- a legacy name falls
# through to a hard-coded escape that honours nothing. Fix under test
# (implementer, concurrent): recent_events maps each legacy role through
# tui::DashboardScreen::theme_role(...) at the span, exactly as the time
# span already does (t/41's TIME_ROLE).
#
# Spec S5's degradation table is explicit that NO_COLOR strips COLOUR only
# -- attribute-only escapes (dim \e[2m, bold \e[1m) are CORRECT and must
# still appear. So the detector below is scoped to COLOUR SGR parameters
# specifically (foreground 30-37/90-97, background 40-47/100-107, or an
# extended 38/48 introducer), never "any escape at all" -- asserting the
# latter would forbid behaviour the spec mandates.
# ===========================================================================

# _sgr_has_color($sgr) -> 1 iff the SGR escape string carries a COLOUR
# parameter, 0 if it is empty or attribute-only. The ONE detector used by
# both arms below.
sub _sgr_has_color {
    my ($sgr) = @_;
    return 0 unless defined $sgr && length($sgr);
    while ($sgr =~ /\e\[([\d;]*)m/g) {
        for my $code (split /;/, $1) {
            next unless length($code);
            return 1 if $code eq '38' || $code eq '48';
            return 1 if $code >= 30  && $code <= 37;
            return 1 if $code >= 40  && $code <= 47;
            return 1 if $code >= 90  && $code <= 97;
            return 1 if $code >= 100 && $code <= 107;
        }
    }
    return 0;
}
{
    # _sgr_has_color non-vacuity: fires on a hand-built colour SGR, does
    # NOT fire on a hand-built attribute-only SGR or an empty string.
    ok(_sgr_has_color("\e[32m"),      '_sgr_has_color non-vacuity: fires on a bare foreground colour code (32, green)');
    ok(_sgr_has_color("\e[1;33;41m"), '_sgr_has_color non-vacuity: fires when a colour code (41) is mixed in with attribute codes');
    ok(_sgr_has_color("\e[38;5;208m"), '_sgr_has_color non-vacuity: fires on an extended 256-colour (38;5;N) code');
    ok(!_sgr_has_color("\e[2m"), '_sgr_has_color non-vacuity: does NOT fire on a bare dim (attribute-only) code');
    ok(!_sgr_has_color("\e[1m"), '_sgr_has_color non-vacuity: does NOT fire on a bare bold (attribute-only) code');
    ok(!_sgr_has_color(''),      '_sgr_has_color non-vacuity: does NOT fire on the empty string');
}
{
    my @nc_lines = (
        LaunchLog_format_event('container_start', { exit => 0 }, $NOW - 30, 111),   # -> event_style role 'good'
        LaunchLog_format_event('error',            {},           $NOW - 20, 111),   # -> event_style role 'bad'
        LaunchLog_format_event('launch_session',   {},           $NOW - 10, 111),   # -> event_style role 'accent'
    );

    # ---- Arm 1 (counter-fixture, checked FIRST): with NO_COLOR UNSET, at
    # ---- least one span produced from this exact fixture resolves to a
    # ---- COLOUR SGR -- proves the detector below can actually fire; a
    # ---- guard that cannot fire is not a guard.
    my $n_color_on = 0;
    {
        local $ENV{NO_COLOR};
        delete $ENV{NO_COLOR};
        Theme::_reset_capability_memo() if $THEME_OK;
        my $ev_on = eval { Dashboard::recent_events(\@nc_lines, 10, undef, $NOW) };
        ok(!$@, 'NO_COLOR regression precondition: recent_events does not die (NO_COLOR unset)') or diag($@);
        my @spans_on = map { @$_ } @{ (ref($ev_on) eq 'ARRAY') ? $ev_on : [] };
        $n_color_on = grep { _sgr_has_color(Dashboard::sgr_for_role($_->{role})) } @spans_on;
    }
    cmp_ok($n_color_on, '>', 0,
        'NO_COLOR regression counter-fixture: with NO_COLOR UNSET, at least one recent_events span resolves to a COLOUR SGR -- proves the detector below is not vacuously green');

    # ---- Arm 2: the regression assertion itself.
    my (@offenders);
    {
        local $ENV{NO_COLOR} = '1';
        Theme::_reset_capability_memo() if $THEME_OK;
        my $ev_off = eval { Dashboard::recent_events(\@nc_lines, 10, undef, $NOW) };
        ok(!$@, 'NO_COLOR regression precondition: recent_events does not die (NO_COLOR=1)') or diag($@);
        my @spans_off = map { @$_ } @{ (ref($ev_off) eq 'ARRAY') ? $ev_off : [] };
        for my $sp (@spans_off) {
            my $sgr = Dashboard::sgr_for_role($sp->{role});
            push @offenders, { role => $sp->{role}, sgr => $sgr } if _sgr_has_color($sgr);
        }
    }
    Theme::_reset_capability_memo() if $THEME_OK;   # never leak the memo into later assertions
    is(scalar(@offenders), 0,
        'NO_COLOR regression: with NO_COLOR=1, NO span produced by recent_events resolves to a COLOUR SGR (attribute-only escapes such as dim/bold remain permitted, per spec S5)')
        or diag("  offenders: " . join(' | ', map { my $s = $_->{sgr}; $s =~ s/\e/\\e/g; "role=$_->{role} sgr=$s" } @offenders));
}

# ===========================================================================
# PARITY (fix-batch item 3, review-major re-scoped by the driver):
# Dashboard::_status_alert / tui::DashboardScreen::_status_alert_msg, and
# Dashboard::lifecycle_alert_msg / tui::DashboardScreen::_lifecycle_alert_msg,
# are two independently-maintained copies of the same banner logic (AC-P4
# forbids the tui:: side calling back into Dashboard, so the duplication is
# structurally required). Nothing else asserts they stay byte-equal; if they
# drift, activity_capacity (Dashboard.pm:2317, via _alert_msgs) reserves the
# wrong number of banner rows for what the render path (tui::DashboardScreen
# ::_banner_lines) actually draws -- a layout mis-size with no obvious
# symptom. This is NOT new coverage of either function in isolation (t/46
# AC-20 and t/47 already drive Dashboard::compose_frame with lifecycle/status
# alerts and assert on the resulting rows) -- it is the missing PARITY check
# between the two copies.
# ===========================================================================
{
    my @PARITY_STATES = (
        ['machine stopped overrides an otherwise-quiet status',
            { machine_state => 'stopped', status => 'running' }],
        ['container_gone with a known status',
            { container_gone => 1, status => 'exited' }],
        ['container_gone with status absent (falsy -- "without a known status")',
            { container_gone => 1, status => undef }],
        ["container_gone with status literally 'unknown'",
            { container_gone => 1, status => 'unknown' }],
        ["status='' -> no alert",         { status => '' }],
        ["status='?' -> no alert",        { status => '?' }],
        ["status='running' -> no alert",  { status => 'running' }],
        ["status='created' -> no alert",  { status => 'created' }],
        ["status='restarting' -> no alert", { status => 'restarting' }],
        ["status='unknown' (no container_gone) -> alert", { status => 'unknown' }],
        ["status='paused' (an arbitrary other status) -> alert", { status => 'paused' }],
        ['lifecycle active, registered mode',
            { status => 'running', lifecycle => { mode => 'stop-runs', active => 1, index => 2, total => 5, label => 'zqx-run-a', state => 'stopping' } }],
        ['lifecycle active, UNREGISTERED mode (label falls back to the mode string itself)',
            { status => 'running', lifecycle => { mode => 'zqx-custom-mode-7714', active => 1, index => 1, total => 1, label => 'zqx-run-b', state => 'zqx-state-b' } }],
        ['lifecycle done, registered mode',
            { status => 'running', lifecycle => { mode => 'full-shutdown', active => 0, summary => 'zqx-summary-7714' } }],
        ['install_warning present, otherwise fully quiet',
            { status => 'running', install_warning => 'zqx-install-warn-7714' }],
        ['the everything-quiet state -- status_alert AND lifecycle_alert_msg both return undef from BOTH implementations (agreeing on "no alert" is as load-bearing as agreeing on text)',
            { status => 'running' }],
    );
  SKIP: {
        skip('tui::DashboardScreen did not load', scalar(@PARITY_STATES) * 2) unless $DS_OK;
        for my $case (@PARITY_STATES) {
            my ($desc, $state) = @$case;
            my $d_status = Dashboard::_status_alert($state);
            my $t_status = tui::DashboardScreen::_status_alert_msg($state);
            is($t_status, $d_status,
                "PARITY (status alert): tui::DashboardScreen::_status_alert_msg agrees with Dashboard::_status_alert -- $desc");

            my $d_lc = Dashboard::lifecycle_alert_msg($state);
            my $t_lc = tui::DashboardScreen::_lifecycle_alert_msg($state);
            is($t_lc, $d_lc,
                "PARITY (lifecycle alert): tui::DashboardScreen::_lifecycle_alert_msg agrees with Dashboard::lifecycle_alert_msg -- $desc");
        }
    }
}
{
    # PARITY non-vacuity: the same is()-equality mechanism used in the table
    # above CAN report two banner messages as different -- proven on two
    # real, DERIVED (not hand-typed) _status_alert branch outputs that are
    # known to differ (the container_gone/known-status branch vs the bare
    # 'unknown'-status branch).
    my $msg_a = Dashboard::_status_alert({ container_gone => 1, status => 'exited' });
    my $msg_b = Dashboard::_status_alert({ status => 'unknown' });
    isnt($msg_a, $msg_b,
        'PARITY non-vacuity: two genuinely different _status_alert branch outputs are reported as different by the same equality check used in the parity table above');
}

done_testing();
