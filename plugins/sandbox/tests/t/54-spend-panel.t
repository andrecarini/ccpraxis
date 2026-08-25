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
#                   five_hour => { utilization => 0..100 } | undef,
#                   seven_day => { utilization => 0..100 } | undef,
#
# UTILIZATION IS AN INTEGER PERCENT, NOT A FRACTION. This header declared
# 0..1 and every fixture below followed it, which is exactly why SpendPanel
# was written to multiply by 100 and shipped rendering a real 25% as "2500%".
#
# The endpoint's own contract settles it twice over: BpContract documents the
# field as "utilization:int%" and rejects anything outside 0..100, and
# bp-orchestrator compares it directly against ceilings of 85 and 90 -- values
# a 0..1 fraction could never reach. The operator's live screen showed 2500%
# and 1800%, i.e. 25 and 18.
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
sub fixture_claude_comfortable { return { status => 'ok', five_hour => { utilization => 10 }, seven_day => { utilization => 5 } } }
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

sub lines_text {
    my ($lines) = @_;
    return join("\n", map { Dashboard::spans_text($_) } @$lines);
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
        claude => { status => 'ok', five_hour => { utilization => 10 }, seven_day => { utilization => 10 } },
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
    my $claude_low = { status => 'ok', five_hour => { utilization => 10 } };

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
                        claude => { status => 'ok', five_hour => { utilization => 99 } },
                        go     => { status => 'ok', monthly => { used => 1, limit => 60 } },
                        zen    => { status => 'absent' } };
    my ($info_flip) = build_info($spend_flip);
    my $top_flip = (ref $info_flip eq 'HASH' && ref $info_flip->{priority} eq 'ARRAY'
                     && @{ $info_flip->{priority} }) ? $info_flip->{priority}[0] : undef;
    is(($top_flip ? $top_flip->{provider} : undef), 'claude',
       'C6b VACUITY GATE: when claude is the tighter meter it wins -- the ranking is real, not hardcoded to go');
}

done_testing();
