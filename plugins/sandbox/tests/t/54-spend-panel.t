#!/usr/bin/env perl
# b37-spend-surfaces oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b37-spend-surfaces-spec.md
# sections 0-4 (criteria C1..C11).
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. plugins/sandbox/scripts/SpendPanel.pm,
# plugins/sandbox/scripts/Dashboard.pm's spend wiring, and
# plugins/butler/scripts/bp-statusline.pl do not exist / do not yet carry
# spend support at the time this file was authored. Every assertion that
# depends on them is expected to fail on MISSING BEHAVIOUR (a failed
# `require`/`can`, caught by eval, or a spawned script producing nothing) --
# never a raw Perl exception escaping this file.
#
# INVENTED CONTRACT (the test-writer's job, same discipline
# t/83-multi-provider-spend.t applied to bp-spend.pl before it existed). The
# spec pins the PURITY rules, the STATES, and the ACCEPTANCE CRITERIA, but not
# exact sub names/signatures for a brand new module -- so this oracle invents
# a minimal, TokenInfo.pm-shaped contract and documents it here so implementer
# and reviewer can see the decision rather than reverse-engineer it:
#
#   package SpendPanel (plugins/sandbox/scripts/SpendPanel.pm), PURE:
#
#     SpendPanel::status(\%spend, $now) -> \%info
#
#     \%spend (the input, composed by launcher.pl from BpSpend::fetch() for
#     go/zen -- spec S0 -- and from bp-usage-gate.pl's own $parsed for claude,
#     which the spec S2 names as a third meter this panel must show even
#     though b36 does not produce it):
#       claude => { status => 'ok'|'unknown',
#                   five_hour => { utilization => 0..1 } | undef,
#                   seven_day => { utilization => 0..1 } | undef,
#                   diagnostic => $str | undef }
#       go     => { status => 'ok'|'unknown'|'absent',
#                   five_hour|weekly|monthly => { used => N, limit => N } | undef,
#                   diagnostic => $str | undef }
#       zen    => { status => 'ok'|'unknown'|'absent',
#                   balance => N | undef, budget => N | undef,
#                   diagnostic => $str | undef }
#       zen_enabled => 0 | 1   -- operator toggle, independent of zen.status
#
#     \%info (the output, render-ready but NOT yet spans -- exactly the
#     TokenInfo::status()/Dashboard::_token_lines split the spec S1 mandates):
#       claude => { state => 'ok'|'unreadable',
#                   windows => [ { name=>'five_hour'|'seven_day', fraction=>N, text=>STR }, ... ] }
#       go     => { state => 'absent'|'unreadable'|'exhausted'|'ok',
#                   windows => [ { name=>'five_hour'|'weekly'|'monthly', used=>N, limit=>N,
#                                  fraction=>N, text=>'$N.NN / $N.NN' }, ... ],
#                   diagnostic => $str | undef }
#       zen    => { state => 'disabled'|'absent'|'unreadable'|'exhausted'|'ok',
#                   balance_text => STR|undef, budget_text => STR|undef,
#                   fraction => N|undef, diagnostic => $str|undef }
#       priority => [ { provider=>'claude'|'go'|'zen', window=>NAME, fraction=>N }, ... ]
#                   -- every window with a defined fraction and state 'ok',
#                   stable-sorted by fraction DESCENDING (nearest exhaustion
#                   first); ties keep NATURAL declared order: claude/five_hour,
#                   claude/seven_day, go/five_hour, go/weekly, go/monthly,
#                   zen/balance. This is what makes C6 assertable: "nearest
#                   exhaustion first" needs a concrete, sortable field, and
#                   "the natural order when nothing is tight" needs a concrete
#                   tie-break, or C6's paired gate cannot be told apart from
#                   an implementation that just always emits the same order.
#     'exhausted' is DERIVED here (spec S0.1): status eq 'ok' AND some window's
#     fraction >= 1.0. Never a b36 status.
#
#   package Dashboard (plugins/sandbox/scripts/Dashboard.pm), spend wiring:
#     Dashboard::_spend_lines(\%info, $cols) -> \@lines   (array of span-lines,
#       following _token_lines' shape/precedent -- grep for _token_lines).
#       Every line's spans_width <= $cols (never overflows, C9).
#
#   plugins/butler/scripts/bp-statusline.pl (a NEW script, b37's own file --
#     NOT s17's scripts/statusline.pl):
#     Filter script, stdin JSON -> stdout bytes, one line, matching this
#     repo's existing "statusline.pl" convention (scripts/statusline.pl reads
#     JSON from STDIN). Input: { spend => \%spend, now => N, width => N }.
#     Output: a single compact line, exactly $width display columns (per
#     Dashboard::display_width), truncated (if needed) via Dashboard's
#     fit_spans-style whole-glyph-drop rule -- never mid-glyph, never by raw
#     `length`.
#
# MANDATORY VACUITY GATES (spec's own standing rule, C4/C6 explicitly):
#   - C4: a genuinely-zero REAL figure (status ok, used=>0) DOES render as
#     '$0' in the SAME run that proves unconfigured/unreadable/exhausted never
#     do -- otherwise "never print $0" would pass against an implementation
#     that never prints $0 at all.
#   - C6: the near-exhaustion fixture surfaces the tight window first, AND a
#     comfortable-everywhere fixture surfaces the NATURAL (non-monthly-first)
#     order in the same run -- otherwise "always show monthly" would pass.
#
# NO SKIP whose condition is the failure state. Absence is always a FAILURE,
# never a skip (house rule, restated because it has fired 3x in this
# blueprint already).
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir tempfile);
use JSON::PP qw(encode_json);
use Encode qw(encode);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $SANDBOX_SCRIPTS = fwd("$Bin/../../scripts");
my $SPEND_PANEL     = "$SANDBOX_SCRIPTS/SpendPanel.pm";
my $DASHBOARD       = "$SANDBOX_SCRIPTS/Dashboard.pm";
my $STATUSLINE      = fwd("$Bin/../../../butler/scripts/bp-statusline.pl");

diag("subject under test: $SPEND_PANEL " . (-e $SPEND_PANEL ? "(present)" : "(ABSENT)"));
diag("subject under test: $STATUSLINE " . (-e $STATUSLINE ? "(present)" : "(ABSENT)"));

use constant NOW_EPOCH => 1785800000;   # 2026-08-03-ish; not load-bearing.

# =====================================================================================
# Scaffolding
# =====================================================================================
sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

# try_call($desc, $coderef) -> ($result_arrayref | undef, $err | undef).
# Never lets a missing sub/package take the whole file down (house idiom,
# t/83-multi-provider-spend.t).
sub try_call {
    my ($desc, $code) = @_;
    my @out;
    my $ok = eval { @out = $code->(); 1 };
    unless ($ok) {
        my $err = $@;
        $err =~ s/\s+$//;
        return (undef, "died calling $desc: $err");
    }
    return (\@out, undef);
}

# --- Fixture builders ---------------------------------------------------------------
sub fixture_claude_comfortable { return { status => 'ok', five_hour => { utilization => 0.10 }, seven_day => { utilization => 0.05 } } }
sub fixture_claude_unreadable  { return { status => 'unknown', diagnostic => 'usage endpoint unreachable' } }

sub fixture_go_ok {
    my (%over) = @_;
    return {
        status    => 'ok',
        five_hour => { used => 1,  limit => 12 },
        weekly    => { used => 3,  limit => 30 },
        monthly   => { used => 6,  limit => 60 },
        %over,
    };
}
sub fixture_go_absent     { return { status => 'absent',  diagnostic => 'provider not configured: no credential found' } }
sub fixture_go_unreadable { return { status => 'unknown', diagnostic => 'credential unavailable (insecure-file): credential file /x/y is group/world-readable (mode 0644); refusing to read a session cookie from it -- required mode is 0600 (chmod 0600 /x/y). Before repairing the scrape, check whether OpenCode now publishes a documented API, CLI subcommand, or usage header for Go/Zen quota -- if it does, replace this reader rather than fix it.' } }
sub fixture_go_exhausted_monthly {
    return fixture_go_ok(monthly => { used => 60, limit => 60 });
}
sub fixture_go_zero { return fixture_go_ok(five_hour => { used => 0, limit => 12 }) }

sub fixture_zen_ok        { return { status => 'ok', balance => 42, budget => 100 } }
sub fixture_zen_absent    { return { status => 'absent',  diagnostic => 'provider not configured: no credential found' } }
sub fixture_zen_unreadable { return { status => 'unknown', diagnostic => 'session rejected (redirected to sign-in) -- re-copy the cookie from your opencode.ai session and try again.' } }

my %HOSTILE = (
    'undef'                 => undef,
    'empty hashref'         => {},
    'empty string'          => '',
    'plain scalar'          => 'not-a-hashref',
    'arrayref where hash'   => [ 1, 2, 3 ],
    'coderef'                => sub { 1 },
    'deeply nested garbage' => { status => { status => { status => 'ok' } } },
    'wrong-typed windows'   => { status => 'ok', five_hour => 'not-a-hash', weekly => [1,2], monthly => undef },
    'blessed ref'           => bless({}, 'Spend::Test::Bogus'),
);

# =====================================================================================
# HARNESS: load SpendPanel.pm and Dashboard.pm. Guarded (house idiom).
# =====================================================================================
my $SPEND_PANEL_LOADED = do { local $@; eval { require $SPEND_PANEL }; !$@ };
ok($SPEND_PANEL_LOADED, 'HARNESS: SpendPanel.pm requires cleanly as a module')
    or diag("require failed (expected pre-implementation): $@");

my $DASHBOARD_LOADED = do { local $@; eval { require $DASHBOARD }; !$@ };
ok($DASHBOARD_LOADED, 'HARNESS: Dashboard.pm requires cleanly as a module')
    or diag("require failed: $@");

# ===========================================================================
# C1 -- purity, asserted over SpendPanel.pm's source (s08's TokenInfo.pm
# convention). Comments stripped BEFORE matching (house idiom: 42/44/45/47/53
# `s/#[^\n]*//g`) so a prose mention of "open" in a comment cannot trip this.
# ===========================================================================
{
    my $raw = slurp($SPEND_PANEL);
    my $have = length($raw) > 0;
    ok($have, 'C1: SpendPanel.pm exists and is readable on disk')
        or diag("expected at $SPEND_PANEL");

    my $src = $raw;
    $src =~ s/#[^\n]*//g;

    my @forbidden = (
        [ 'open(',           qr/\bopen\s*\(/ ],
        [ 'open FILEHANDLE', qr/\bopen\s+my\b/ ],
        [ 'stat(',           qr/\bstat\s*\(/ ],
        [ 'lstat(',          qr/\blstat\s*\(/ ],
        [ 'a -e/-f file test', qr/(?<![\w\$])-[ef]\s/ ],
        [ 'time(',           qr/\btime\s*\(/ ],
        [ 'bare time',       qr/\btime\b/ ],
        [ 'localtime',       qr/\blocaltime\b/ ],
        [ 'gmtime',          qr/\bgmtime\b/ ],
    );
    for my $f (@forbidden) {
        my ($label, $qr) = @$f;
        my $desc = "C1: SpendPanel.pm source (comments stripped) contains no $label";
        $have ? unlike($src, $qr, $desc) : fail("$desc [SpendPanel.pm not on disk]");
    }

    # Positive gate for the purity block itself: SpendPanel.pm DOES exist and
    # DOES contain the string 'status' (its documented entry point) -- proves
    # the forbidden-pattern checks above ran against real source, not an
    # empty file that trivially contains none of the forbidden shapes.
    if ($have) {
        like($src, qr/\bstatus\b/, 'C1 (non-vacuity): SpendPanel.pm source is non-trivial (mentions its own entry point)');
    } else {
        fail('C1 (non-vacuity): SpendPanel.pm source is non-trivial [SpendPanel.pm not on disk]');
    }
}

# ===========================================================================
# C11 (module-separation half of spec S1): Dashboard.pm does NOT load
# SpendPanel -- exactly as it does not load TokenInfo (grep for _token_lines).
# ===========================================================================
{
    my $dash = slurp($DASHBOARD);
    my $have = length($dash) > 0;
    ok($have, 'C11/S1: Dashboard.pm is readable on disk') or diag("expected at $DASHBOARD");
    if ($have) {
        unlike($dash, qr/\buse\s+SpendPanel\b/,     'S1: Dashboard.pm source contains no "use SpendPanel"');
        unlike($dash, qr/\brequire\s+SpendPanel\b/, 'S1: Dashboard.pm source contains no "require SpendPanel"');
        unlike($dash, qr/SpendPanel::/,             'S1: Dashboard.pm source contains no "SpendPanel::" call');
    } else {
        fail('S1: Dashboard.pm contains no SpendPanel reference [Dashboard.pm not on disk]');
    }
}

# ===========================================================================
# C2 -- SpendPanel::status never dies, over undef/empty/wrong-typed/nested/
# hostile input, at every argument position (spend struct AND $now).
# ===========================================================================
{
    for my $label (sort keys %HOSTILE) {
        my $spend = $HOSTILE{$label};
        my ($out, $err) = try_call("SpendPanel::status(<$label>, NOW_EPOCH)",
            sub { SpendPanel::status($spend, NOW_EPOCH) });
        ok(!defined $err, "C2: SpendPanel::status(<$label>, valid now) never dies")
            or diag($err);
    }
    for my $label (sort keys %HOSTILE) {
        my $now = $HOSTILE{$label};
        my ($out, $err) = try_call("SpendPanel::status(<well-formed>, <$label>)",
            sub { SpendPanel::status({ go => fixture_go_ok() }, $now) });
        ok(!defined $err, "C2: SpendPanel::status(well-formed spend, now=<$label>) never dies")
            or diag($err);
    }
    my ($out, $err) = try_call('SpendPanel::status(undef, undef)', sub { SpendPanel::status(undef, undef) });
    ok(!defined $err, 'C2: SpendPanel::status(undef, undef) never dies') or diag($err);

    # C2 (non-vacuity): a well-formed call ALSO never dies AND returns a
    # hashref -- proves the totality above isn't trivially satisfied by a sub
    # that dies on everything except never being reached (i.e. this proves
    # the sub is actually callable and productive, not merely absent).
    my ($ok_out, $ok_err) = try_call('SpendPanel::status(well-formed, NOW_EPOCH)',
        sub { SpendPanel::status({ claude => fixture_claude_comfortable(), go => fixture_go_ok(), zen => fixture_zen_ok(), zen_enabled => 1 }, NOW_EPOCH) });
    ok(!defined $ok_err, 'C2 (non-vacuity): well-formed call does not die either')
        or diag($ok_err);
    is(ref(($ok_out || [])->[0]), 'HASH', 'C2 (non-vacuity): well-formed call returns a hashref') if $ok_out;
}

# ===========================================================================
# Helper to build \%info from a \%spend fixture, tolerant of failure (all
# later blocks check definedness before indexing so a missing implementation
# fails each assertion individually rather than dying out of the file).
# ===========================================================================
sub build_info {
    my ($spend, $now) = @_;
    $now = NOW_EPOCH unless defined $now;
    my ($out, $err) = try_call('SpendPanel::status', sub { SpendPanel::status($spend, $now) });
    return (undef, $err) if $err;
    my $info = $out->[0];
    return (undef, 'did not return a hashref') unless ref($info) eq 'HASH';
    return ($info, undef);
}

sub build_lines {
    my ($info, $cols) = @_;
    my ($out, $err) = try_call('Dashboard::_spend_lines', sub { Dashboard::_spend_lines($info, $cols) });
    return (undef, $err) if $err;
    my $lines = $out->[0];
    return (undef, 'did not return an arrayref') unless ref($lines) eq 'ARRAY';
    return ($lines, undef);
}

sub lines_text {
    my ($lines) = @_;
    return join("\n", map { Dashboard::spans_text($_) } @$lines);
}

# ===========================================================================
# C3 -- all three providers render, each with every window: Claude 5h/7d, Go
# 5h/weekly/monthly, Zen balance.
# ===========================================================================
{
    my $spend = { claude => fixture_claude_comfortable(), go => fixture_go_ok(), zen => fixture_zen_ok(), zen_enabled => 1 };
    my ($info, $err) = build_info($spend);
    ok(!defined $err, 'C3: SpendPanel::status(full ok fixture) succeeds') or diag($err // '(no info)');

    SKIP_INFO: {
        unless (defined $info) {
            fail('C3: claude.windows present for full ok fixture [SpendPanel::status did not return usable info]');
            fail('C3: go.windows present for full ok fixture [SpendPanel::status did not return usable info]');
            fail('C3: zen fields present for full ok fixture [SpendPanel::status did not return usable info]');
            last SKIP_INFO;
        }
        my @claude_names = ref($info->{claude}{windows}) eq 'ARRAY'
            ? sort map { $_->{name} // '?' } @{ $info->{claude}{windows} } : ();
        is_deeply(\@claude_names, [ 'five_hour', 'seven_day' ], 'C3: claude renders both five_hour and seven_day windows');

        my @go_names = ref($info->{go}{windows}) eq 'ARRAY'
            ? sort map { $_->{name} // '?' } @{ $info->{go}{windows} } : ();
        is_deeply(\@go_names, [ 'five_hour', 'monthly', 'weekly' ], 'C3: go renders five_hour, weekly and monthly windows');

        ok(defined $info->{zen}{balance_text}, 'C3: zen renders a balance figure when enabled+ok');
    }

    my ($lines, $lerr) = build_lines($info, 80);
    ok(!defined $lerr, 'C3: Dashboard::_spend_lines(info, 80) succeeds') or diag($lerr // '(no info)');
    if (defined $lines) {
        my $text = lines_text($lines);
        for my $needle (qw(Claude Go Zen)) {
            like($text, qr/\Q$needle\E/i, "C3: rendered panel text mentions provider '$needle'");
        }
    } else {
        fail('C3: rendered panel text mentions provider Claude/Go/Zen [_spend_lines unusable]');
    }
}

# ===========================================================================
# C4 -- unconfigured/unreadable/exhausted render DIFFERENTLY, none renders a
# zero-valued currency figure for a non-ok provider. Vacuity gate: a REAL
# zero (ok, used=>0) DOES render as $0.
# ===========================================================================
{
    my %renderings;
    my %states = (
        unconfigured => { go => fixture_go_absent() },
        unreadable   => { go => fixture_go_unreadable() },
        exhausted    => { go => fixture_go_exhausted_monthly() },
    );
    for my $label (qw(unconfigured unreadable exhausted)) {
        my $spend = { claude => fixture_claude_comfortable(), zen_enabled => 0, %{ $states{$label} } };
        my ($info, $err) = build_info($spend);
        my ($lines, $lerr) = defined $info ? build_lines($info, 80) : (undef, 'no info');
        if (defined $lines) {
            $renderings{$label} = lines_text($lines);
        } else {
            $renderings{$label} = undef;
            fail("C4: $label state rendered at all [" . ($err // $lerr) . "]");
        }
    }

    if (defined $renderings{unconfigured} && defined $renderings{unreadable}) {
        isnt($renderings{unconfigured}, $renderings{unreadable}, 'C4: unconfigured and unreadable render DIFFERENTLY');
    } else {
        fail('C4: unconfigured and unreadable render differently [one or both did not render]');
    }
    if (defined $renderings{unreadable} && defined $renderings{exhausted}) {
        isnt($renderings{unreadable}, $renderings{exhausted}, 'C4: unreadable and exhausted render DIFFERENTLY');
    } else {
        fail('C4: unreadable and exhausted render differently [one or both did not render]');
    }
    if (defined $renderings{unconfigured} && defined $renderings{exhausted}) {
        isnt($renderings{unconfigured}, $renderings{exhausted}, 'C4: unconfigured and exhausted render DIFFERENTLY');
    } else {
        fail('C4: unconfigured and exhausted render differently [one or both did not render]');
    }

    for my $label (qw(unconfigured unreadable)) {
        if (defined $renderings{$label}) {
            unlike($renderings{$label}, qr/\$0(?!\d)(?:\.0+)?\b/, "C4: $label rendering never shows a \$0 currency figure");
        } else {
            fail("C4: $label rendering never shows \$0 [did not render]");
        }
    }

    # Vacuity gate: a REAL zero (ok, five_hour used=>0) DOES render as $0.
    my $spend_zero = { claude => fixture_claude_comfortable(), zen_enabled => 0, go => fixture_go_zero() };
    my ($info_zero, $err_zero) = build_info($spend_zero);
    my ($lines_zero, $lerr_zero) = defined $info_zero ? build_lines($info_zero, 80) : (undef, 'no info');
    if (defined $lines_zero) {
        my $text_zero = lines_text($lines_zero);
        like($text_zero, qr/\$0(?!\d)/, 'C4 (vacuity gate): a genuinely-zero REAL figure (ok, used=>0) DOES render as $0');
    } else {
        fail('C4 (vacuity gate): a genuinely-zero real figure renders as $0 [did not render]');
    }
}

# ===========================================================================
# C5 -- Zen disabled by default; enabled shows cap + consumed fraction.
# ===========================================================================
{
    my ($info_off, $err_off) = build_info({ go => fixture_go_ok(), zen => fixture_zen_ok(), zen_enabled => 0 });
    if (defined $info_off) {
        is($info_off->{zen}{state}, 'disabled', 'C5: zen_enabled=0 -> zen state is disabled (default)');
    } else {
        fail("C5: zen_enabled=0 -> zen state is disabled [$err_off]");
    }

    my ($info_on, $err_on) = build_info({ go => fixture_go_ok(), zen => fixture_zen_ok(), zen_enabled => 1 });
    if (defined $info_on) {
        isnt($info_on->{zen}{state}, 'disabled', 'C5: zen_enabled=1 -> zen state is not disabled');
        ok(defined $info_on->{zen}{budget_text}, 'C5: zen_enabled=1 -> a cap (budget) figure is present');
        ok(defined $info_on->{zen}{fraction} && $info_on->{zen}{fraction} > 0,
            'C5: zen_enabled=1 -> a consumed fraction is present and nonzero for balance=42/budget=100');
    } else {
        fail("C5: zen_enabled=1 -> cap+fraction present [$err_on]");
    }

    my ($lines_off, $lerr_off) = defined $info_off ? build_lines($info_off, 80) : (undef, 'no info');
    my ($lines_on,  $lerr_on)  = defined $info_on  ? build_lines($info_on, 80)  : (undef, 'no info');
    if (defined $lines_off && defined $lines_on) {
        isnt(lines_text($lines_off), lines_text($lines_on), 'C5: disabled-Zen and enabled-Zen render DIFFERENTLY');
        unlike(lines_text($lines_off), qr/\$0(?!\d)/, 'C5: disabled Zen never shows as $0 (shown as disabled, not zero/error)');
    } else {
        fail('C5: disabled vs enabled Zen render differently [one or both did not render]');
    }
}

# ===========================================================================
# C6 -- nearest-exhaustion first. Paired gate: all-comfortable -> natural
# order (not "always monthly").
# ===========================================================================
{
    # Tight fixture: comfortable 5-hour, nearly-exhausted monthly.
    my $spend_tight = {
        claude => fixture_claude_comfortable(),
        go     => fixture_go_ok(five_hour => { used => 1, limit => 12 }, monthly => { used => 59, limit => 60 }),
        zen_enabled => 0,
    };
    my ($info_tight, $err_tight) = build_info($spend_tight);
    if (defined $info_tight && ref($info_tight->{priority}) eq 'ARRAY' && @{ $info_tight->{priority} }) {
        my $top = $info_tight->{priority}[0];
        is($top->{provider}, 'go',      'C6: near-exhausted-monthly fixture -> top priority provider is go');
        is($top->{window},   'monthly', 'C6: near-exhausted-monthly fixture -> top priority window is monthly');
    } else {
        fail('C6: near-exhausted-monthly fixture surfaces monthly first [priority list unusable]');
        fail('C6: near-exhausted-monthly fixture surfaces monthly first (window) [priority list unusable]');
    }

    # Paired gate: everything comfortable and roughly EQUAL -> natural
    # (declared) order, not hardcoded "always monthly".
    my $spend_calm = {
        claude => { status => 'ok', five_hour => { utilization => 0.10 }, seven_day => { utilization => 0.10 } },
        go     => fixture_go_ok(five_hour => { used => 1, limit => 12 }, weekly => { used => 2.5, limit => 30 }, monthly => { used => 5, limit => 60 }),
        zen_enabled => 0,
    };
    my ($info_calm, $err_calm) = build_info($spend_calm);
    if (defined $info_calm && ref($info_calm->{priority}) eq 'ARRAY' && @{ $info_calm->{priority} }) {
        my $top_calm = $info_calm->{priority}[0];
        my $is_monthly_first = ($top_calm->{provider} eq 'go' && $top_calm->{window} eq 'monthly') ? 1 : 0;
        is($is_monthly_first, 0, 'C6 (paired gate): all-comfortable fixture does NOT always surface monthly first');
    } else {
        fail('C6 (paired gate): all-comfortable fixture does not always surface monthly first [priority list unusable]');
    }
}

# ===========================================================================
# C7 -- display-width correctness under the s04 core, never `length`. Include
# a multi-byte fixture whose byte length differs from its column count.
# ===========================================================================
{
    my $spend = { claude => fixture_claude_comfortable(), go => fixture_go_ok(), zen => fixture_zen_ok(), zen_enabled => 1 };
    my ($info, $err) = build_info($spend);
    my ($lines, $lerr) = defined $info ? build_lines($info, 78) : (undef, 'no info');
    if (defined $lines) {
        my $bad = 0;
        for my $line (@$lines) {
            my $text  = Dashboard::spans_text($line);
            my $width = Dashboard::spans_width($line);
            # A multi-byte glyph (e.g. a status dot) makes byte length != display
            # width whenever one is present; assert the module's own display_width
            # core (not raw `length`) is what governs spans_width, by cross-checking
            # against Dashboard::display_width($text) (the SAME s04 primitive every
            # other panel oracle uses -- 41-panel-semantics AC27).
            $bad++ if $width != Dashboard::display_width($text);
        }
        is($bad, 0, 'C7: every spend line spans_width agrees with Dashboard::display_width(spans_text) (s04 core, not length)');

        # Positive multi-byte fixture: assert at least one glyph byte length
        # differs from its column count is exercised by the s04 core itself
        # (non-vacuity for the invariant above -- proves multi-byte content is
        # actually present in these lines, not just ASCII that trivially
        # satisfies width==length).
        my $whole_text = join('', map { Dashboard::spans_text($_) } @$lines);
        my $glyph = encode('UTF-8', "\x{1F7E2}");   # green circle: 4 bytes, 2 columns (s06 palette)
        if (index($whole_text, $glyph) >= 0) {
            isnt(length($glyph), Dashboard::display_width($glyph), 'C7 (non-vacuity): a real multi-byte glyph has byte length != display width');
        } else {
            # Not required to use exactly this glyph, but SOME status marker
            # must differ; check bytes(line) != display_width(line) directly.
            my $byte_len = length($whole_text);
            my $disp_w   = 0;
            $disp_w += Dashboard::display_width(Dashboard::spans_text($_)) for @$lines;
            ok($byte_len != $disp_w || $byte_len == 0, 'C7 (non-vacuity): rendered text is not purely 1-byte-per-column ASCII throughout')
                if $byte_len > 0;
        }
    } else {
        fail('C7: spend lines measured via display_width, not length [_spend_lines unusable]');
    }
}

# ===========================================================================
# C9 -- narrow breakpoint (s05-responsive-layout): degrades rather than
# overflowing. Every rendered line at a narrow width fits within that width.
# ===========================================================================
{
    my $spend = { claude => fixture_claude_comfortable(), go => fixture_go_ok(), zen => fixture_zen_ok(), zen_enabled => 1 };
    my ($info, $err) = build_info($spend);
    for my $cols (20, 40, 78, 120) {
        my ($lines, $lerr) = defined $info ? build_lines($info, $cols) : (undef, 'no info');
        if (defined $lines) {
            my $overflow = grep { Dashboard::spans_width($_) > $cols } @$lines;
            is($overflow, 0, "C9: at cols=$cols no spend line overflows its width (degrades, never overflows)");
        } else {
            fail("C9: at cols=$cols no spend line overflows [_spend_lines unusable]");
        }
    }
    # Non-vacuity: narrow (20) and wide (120) renderings actually DIFFER --
    # proves cols is really honoured, not a fixed-width render that happens
    # to fit both by coincidence.
    my ($lines_narrow, $en) = defined $info ? build_lines($info, 20)  : (undef, 'no info');
    my ($lines_wide,   $ew) = defined $info ? build_lines($info, 120) : (undef, 'no info');
    if (defined $lines_narrow && defined $lines_wide) {
        isnt(lines_text($lines_narrow), lines_text($lines_wide), 'C9 (non-vacuity): narrow (20) and wide (120) renderings differ');
    } else {
        fail('C9 (non-vacuity): narrow and wide renderings differ [unusable]');
    }
}

# ===========================================================================
# C10 -- no credential material in any rendered string. Token-shaped fixture
# (b35's convention) injected into fields a naive renderer might dump
# wholesale, alongside real, legitimate data that MUST still render.
# ===========================================================================
{
    my $SENTINEL = 'sk-ant-oat01-FAKECOOKIE-DO-NOT-LEAK-ABCDEFGHIJK';
    my $spend_leaky = {
        claude => fixture_claude_comfortable(),
        go     => { %{ fixture_go_ok() }, cookie => $SENTINEL, credential => { cookie => $SENTINEL }, raw_headers => "Cookie: session=$SENTINEL" },
        zen    => { %{ fixture_zen_ok() }, cookie => $SENTINEL },
        zen_enabled => 1,
    };
    my ($info, $err) = build_info($spend_leaky);
    my ($lines, $lerr) = defined $info ? build_lines($info, 100) : (undef, 'no info');
    if (defined $lines) {
        my $text = lines_text($lines);
        unlike($text, qr/\Q$SENTINEL\E/, 'C10: rendered spend panel never contains the full credential sentinel');

        my $leak_sub = 0;
        for (my $i = 0; $i + 8 <= length($SENTINEL); $i++) {
            my $chunk = substr($SENTINEL, $i, 8);
            $leak_sub++ if index($text, $chunk) >= 0;
        }
        is($leak_sub, 0, 'C10: rendered spend panel never contains any >=8-char substring of the credential sentinel');

        # Positive gate: real, legitimate data DID render in the same run.
        like($text, qr/\$1\.00|\$3\.00|\$6\.00/, 'C10 (non-vacuity): legitimate Go dollar figures still render despite the sentinel present in the fixture');
    } else {
        fail('C10: rendered spend panel never contains credential material [_spend_lines unusable]');
        fail('C10 (non-vacuity): legitimate data still renders [_spend_lines unusable]');
    }
}

# ===========================================================================
# C11 -- unreadable rendering surfaces it is a READER problem, carrying b36's
# revisit prompt through, rather than presenting a broken scrape as an
# account state.
# ===========================================================================
{
    my $spend = { claude => fixture_claude_comfortable(), go => fixture_go_unreadable(), zen_enabled => 0 };
    my ($info, $err) = build_info($spend);
    my ($lines, $lerr) = defined $info ? build_lines($info, 100) : (undef, 'no info');
    if (defined $lines) {
        my $text = lines_text($lines);
        like($text, qr/before repairing the scrape/i,
            'C11: unreadable rendering carries b36\'s revisit prompt through verbatim');
        like($text, qr/unreadable|unavailable|reader|scrape|credential/i,
            'C11: unreadable rendering names it as a reader/credential problem');
        unlike($text, qr/\$0(?!\d)/, 'C11: unreadable rendering never presents the broken scrape as a $0 account state');
    } else {
        fail('C11: unreadable rendering carries the revisit prompt through [_spend_lines unusable]');
        fail('C11: unreadable rendering names it as a reader problem [_spend_lines unusable]');
    }

    if (defined $info) {
        ok(defined $info->{go}{diagnostic} && $info->{go}{diagnostic} =~ /before repairing the scrape/i,
            'C11: SpendPanel::status itself preserves the revisit-prompt diagnostic (not dropped before render)');
    } else {
        fail('C11: SpendPanel::status preserves the revisit-prompt diagnostic [status() unusable]');
    }
}

# ===========================================================================
# C8 -- the statusline form (bp-statusline.pl) fits its budget without
# truncating mid-glyph. Spawned as a plain filter script (stdin JSON ->
# stdout), bound by `timeout`, exactly as t/102-tui-output-hygiene.t spawns
# scripts/statusline.pl -- never launcher.pl, never a container.
# ===========================================================================
{
    ok(-e $STATUSLINE, 'C8: plugins/butler/scripts/bp-statusline.pl exists on disk')
        or diag("expected at $STATUSLINE");

    if (-e $STATUSLINE) {
        my $src = slurp($STATUSLINE);
        my $code = $src;
        $code =~ s/#[^\n]*//g;
        unlike($code, qr/\blength\s*\(/, 'C8: bp-statusline.pl source never measures width via raw length()');
        like($code, qr/display_width|fit_spans|spans_width/, 'C8: bp-statusline.pl source uses the s04 display-width core');

        # Functional: a multi-byte-glyph fixture at a width that FORCES
        # truncation must not cut a glyph in half (no stray high/continuation
        # UTF-8 byte at the very end of the output).
        my $tempdir = tempdir(CLEANUP => 1);
        my $spend_glyph = {
            claude => fixture_claude_comfortable(),
            go     => fixture_go_exhausted_monthly(),   # forces a status glyph/marker
            zen    => fixture_zen_ok(),
            zen_enabled => 1,
        };
        my $payload = encode_json({ spend => $spend_glyph, now => NOW_EPOCH, width => 10 });
        my ($fh, $infile) = tempfile(DIR => $tempdir);
        binmode $fh, ':raw';
        print {$fh} $payload;
        close $fh;

        my $out = `timeout 5 perl "$STATUSLINE" < "$infile" 2>&1`;
        my $rc  = $? >> 8;
        ok(defined $out && length($out) >= 0, 'C8: bp-statusline.pl runs to completion under timeout (does not hang)');

        if (defined $out && length($out)) {
            # Never split a UTF-8 multi-byte glyph: strip trailing whitespace/
            # newline, then the last byte must not be a UTF-8 continuation or
            # leading byte awaiting more bytes.
            (my $trimmed = $out) =~ s/\s+\z//;
            if (length($trimmed)) {
                my $last_byte = ord(substr($trimmed, -1, 1));
                my $mid_glyph = ($last_byte >= 0x80 && $last_byte <= 0xBF) ? 1   # continuation byte stranded
                              : ($last_byte >= 0xC0)                        ? 1   # leading byte with nothing after it
                              : 0;
                is($mid_glyph, 0, 'C8: bp-statusline.pl output at a forcing width does not end mid-glyph');
            } else {
                fail('C8: bp-statusline.pl produced output to check for mid-glyph truncation [empty after trim]');
            }

            # Non-vacuity: at a GENEROUS width the same fixture produces
            # different (longer) output than the forcing-width run -- proves
            # $width is actually honoured, not a fixed truncation.
            my $payload_wide = encode_json({ spend => $spend_glyph, now => NOW_EPOCH, width => 100 });
            my ($fh2, $infile2) = tempfile(DIR => $tempdir);
            binmode $fh2, ':raw';
            print {$fh2} $payload_wide;
            close $fh2;
            my $out_wide = `timeout 5 perl "$STATUSLINE" < "$infile2" 2>&1`;
            isnt($out, $out_wide, 'C8 (non-vacuity): narrow (10) and wide (100) statusline renders differ')
                if defined $out_wide && length($out_wide);
            fail('C8 (non-vacuity): narrow and wide statusline renders differ [wide run produced nothing]')
                unless defined $out_wide && length($out_wide);
        } else {
            fail('C8: bp-statusline.pl output does not end mid-glyph [produced no output]');
            fail('C8 (non-vacuity): narrow and wide statusline renders differ [produced no output]');
        }
    } else {
        fail('C8: bp-statusline.pl source uses the s04 display-width core [file absent]');
        fail('C8: bp-statusline.pl output does not end mid-glyph [file absent]');
        fail('C8 (non-vacuity): narrow and wide statusline renders differ [file absent]');
    }
}

# ===========================================================================
# C6b -- THE EXHAUSTION BOUNDARY. Added by the coordinator after finding, by
# direct execution, that a provider dropped OUT of the nearest-exhaustion
# ranking at the exact moment it became exhausted: _priority admitted only
# state 'ok', and hitting a limit flips the state to 'exhausted'. Exactly
# backwards -- criterion 6 exists to surface the window closest to its limit,
# and a window AT its limit is the closest possible.
#
# C6 above never caught it because its fixture is "nearly exhausted" (58/60),
# which is still state 'ok'. The bug lives only at used >= limit. This asserts
# the boundary and just past it.
# ===========================================================================
{
    my $claude_low = { status => 'ok', five_hour => { utilization => 0.10 } };

    for my $case ([58, 'go', 'below the limit (still ok)'],
                   [60, 'go', 'exactly AT the limit'],
                   [61, 'go', 'past the limit']) {
        my ($used, $want_provider, $label) = @$case;
        my $spend = { zen_enabled => 0,
                       claude => $claude_low,
                       go     => { status => 'ok', monthly => { used => $used, limit => 60 } },
                       zen    => { status => 'absent' } };
        my ($info, $err) = build_info($spend);
        my $top = (ref $info eq 'HASH' && ref $info->{priority} eq 'ARRAY' && @{ $info->{priority} })
                    ? $info->{priority}[0] : undef;
        is(($top ? $top->{provider} : undef), $want_provider,
           "C6b: with go/monthly $label, the nearest-exhaustion entry is still GO -- "
         . "an exhausted provider must not vanish from the ranking");
    }

    # VACUITY GATE: when go is genuinely the comfortable one, claude wins. So
    # this is not an implementation that simply always answers 'go'.
    my $spend_flip = { zen_enabled => 0,
                        claude => { status => 'ok', five_hour => { utilization => 0.99 } },
                        go     => { status => 'ok', monthly => { used => 1, limit => 60 } },
                        zen    => { status => 'absent' } };
    my ($info_flip) = build_info($spend_flip);
    my $top_flip = (ref $info_flip eq 'HASH' && ref $info_flip->{priority} eq 'ARRAY'
                     && @{ $info_flip->{priority} }) ? $info_flip->{priority}[0] : undef;
    is(($top_flip ? $top_flip->{provider} : undef), 'claude',
       'C6b VACUITY GATE: when claude is the tighter meter it wins -- the ranking is real, not hardcoded to go');
}

done_testing();
