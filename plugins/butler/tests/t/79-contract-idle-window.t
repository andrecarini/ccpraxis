#!/usr/bin/env perl
# b28-contract-idle-window — an idle usage window (utilization 0) legitimately
# omits resets_at; validate_usage must require resets_at only for a window
# whose utilization is numeric and strictly > 0. See spec section 3/4.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

require "$Bin/../../scripts/bp-contract.pl";

# ---- AC-1: idle window, resets_at absent -> OK -----------------------------
{
    my ($ok, $p) = BpContract::validate_usage({
        five_hour => { utilization => 0 },
        seven_day => { utilization => 0 },
    });
    is($ok, 1, 'AC-1: idle windows with resets_at absent pass');
    is(scalar @$p, 0, 'AC-1: idle windows with resets_at absent have no problems');
}

# ---- AC-2: idle window, resets_at explicitly undef -> OK -------------------
{
    my ($ok, $p) = BpContract::validate_usage({
        five_hour => { utilization => 0, resets_at => undef },
        seven_day => { utilization => 0, resets_at => undef },
    });
    is($ok, 1, 'AC-2: idle windows with resets_at => undef pass');
    is(scalar @$p, 0, 'AC-2: idle windows with resets_at => undef have no problems');
}

# ---- AC-3: idle window with a supplied valid resets_at -> OK ---------------
{
    my ($ok, $p) = BpContract::validate_usage({
        five_hour => { utilization => 0, resets_at => '2026-06-22T05:59:59.7+00:00' },
        seven_day => { utilization => 0, resets_at => '2026-06-22T17:59:59+00:00' },
    });
    is($ok, 1, 'AC-3: idle windows with a valid supplied resets_at pass');
    is(scalar @$p, 0, 'AC-3: idle windows with a valid supplied resets_at have no problems');
}

# ---- AC-4: mixed real-world idle payload (the exact shape that paused the fleet) --
{
    my ($ok, $p) = BpContract::validate_usage({
        five_hour => { utilization => 0 },
        seven_day => { utilization => 12, resets_at => '2026-06-22T17:59:59+00:00' },
    });
    is($ok, 1, 'AC-4: mixed idle/active payload passes');
    is(scalar @$p, 0, 'AC-4: mixed idle/active payload has no problems');
}

# ---- AC-5: active window, resets_at absent -> still fails ------------------
{
    my ($ok, $p) = BpContract::validate_usage({
        five_hour => { utilization => 58, resets_at => '2026-06-22T05:59:59+00:00' },
        seven_day => { utilization => 7 },
    });
    is($ok, 0, 'AC-5: active seven_day window with resets_at absent fails');
    ok((grep { /seven_day\.resets_at/ } @$p), 'AC-5: a problem matches qr/seven_day\.resets_at/');
    ok((grep { $_ eq 'usage: seven_day.resets_at missing or not ISO-8601' } @$p),
        'AC-5: the exact verbatim resets_at problem string is present');
}

# ---- AC-6: active window, resets_at present but not ISO-8601 -> still fails --
{
    for my $bad ('tomorrow', '', '2026-06-22') {
        my ($ok, $p) = BpContract::validate_usage({
            five_hour => { utilization => 58, resets_at => '2026-06-22T05:59:59+00:00' },
            seven_day => { utilization => 7, resets_at => $bad },
        });
        is($ok, 0, "AC-6: active seven_day window with resets_at=" . (length($bad) ? $bad : '(empty string)') . " fails");
        ok((grep { /seven_day\.resets_at/ } @$p),
            "AC-6: a problem matches qr/seven_day\\.resets_at/ for resets_at=" . (length($bad) ? $bad : '(empty string)'));
    }
}

# ---- AC-7: fractional utilization above zero is active ---------------------
{
    my ($ok, $p) = BpContract::validate_usage({
        five_hour => { utilization => 0.5 },
        seven_day => { utilization => 7, resets_at => '2026-06-22T05:59:59+00:00' },
    });
    is($ok, 0, 'AC-7: five_hour utilization 0.5 with resets_at absent fails');
    ok((grep { /five_hour\.resets_at/ } @$p), 'AC-7: a problem matches qr/five_hour\.resets_at/');
}

# ---- AC-8: non-numeric/missing utilization -> utilization problem only, no warning --
{
    my @warn;
    my ($ok, $p);
    {
        local $SIG{__WARN__} = sub { push @warn, $_[0] };
        ($ok, $p) = BpContract::validate_usage({
            five_hour => { utilization => 'x' },
            seven_day => {},
        });
    }
    is(scalar @warn, 0, 'AC-8a: no Perl warning is emitted for non-numeric/missing utilization');
    is($ok, 0, 'AC-8b: non-numeric/missing utilization payload fails');
    ok((grep { /five_hour\.utilization/ } @$p), 'AC-8c: a problem matches qr/five_hour\.utilization/');
    ok((grep { /seven_day\.utilization/ } @$p), 'AC-8c: a problem matches qr/seven_day\.utilization/');
    ok(!(grep { /resets_at/ } @$p), 'AC-8d: no problem matches qr/resets_at/');
}

# ---- AC-9: out-of-range utilization above 100 -> unchanged, resets_at still required --
{
    my ($ok, $p) = BpContract::validate_usage({
        five_hour => { utilization => 150, resets_at => '2026-06-22T00:00:00Z' },
        seven_day => { utilization => 7, resets_at => '2026-06-22T00:00:00Z' },
    });
    is($ok, 0, 'AC-9: out-of-range five_hour utilization (150) fails');
    ok((grep { $_ eq 'usage: five_hour.utilization out of 0..100 (got 150)' } @$p),
        'AC-9: exact out-of-range problem string present');
}
{
    my ($ok, $p) = BpContract::validate_usage({
        five_hour => { utilization => 150 },
        seven_day => { utilization => 7, resets_at => '2026-06-22T00:00:00Z' },
    });
    is($ok, 0, 'AC-9: out-of-range five_hour utilization (150) with resets_at absent fails');
    ok((grep { $_ eq 'usage: five_hour.utilization out of 0..100 (got 150)' } @$p),
        'AC-9: out-of-range problem present when resets_at is also absent');
    ok((grep { /five_hour\.resets_at/ } @$p),
        'AC-9: resets_at problem also present because 150 > 0');
}

# ---- AC-10: out-of-range negative utilization -> out-of-range problem only --
{
    my @warn;
    my ($ok, $p);
    {
        local $SIG{__WARN__} = sub { push @warn, $_[0] };
        ($ok, $p) = BpContract::validate_usage({
            five_hour => { utilization => -5 },
            seven_day => { utilization => 7, resets_at => '2026-06-22T00:00:00Z' },
        });
    }
    is($ok, 0, 'AC-10: negative five_hour utilization (-5) fails');
    ok((grep { $_ eq 'usage: five_hour.utilization out of 0..100 (got -5)' } @$p),
        'AC-10: exact out-of-range negative problem string present');
    ok(!(grep { /five_hour\.resets_at/ } @$p),
        'AC-10: no problem matches qr/five_hour\.resets_at/ (-5 > 0 is false)');
    is(scalar @warn, 0, 'AC-10: no Perl warning is emitted for negative utilization');
}

# ---- AC-11: numeric-string zero behaves as zero -----------------------------
{
    my ($ok, $p) = BpContract::validate_usage({
        five_hour => { utilization => '0' },
        seven_day => { utilization => '0' },
    });
    is($ok, 1, "AC-11: numeric-string utilization '0' on both windows with resets_at absent passes");
    is(scalar @$p, 0, "AC-11: numeric-string utilization '0' has no problems");
}
{
    my ($ok, $p) = BpContract::validate_usage({
        five_hour => { utilization => '0.0' },
        seven_day => { utilization => '0.0' },
    });
    is($ok, 1, "AC-11: numeric-string utilization '0.0' on both windows with resets_at absent passes");
    is(scalar @$p, 0, "AC-11: numeric-string utilization '0.0' has no problems");
}

# ---- AC-12: structural failures unchanged ----------------------------------
{
    my ($ok, $p) = BpContract::validate_usage("not a hash");
    is($ok, 0, 'AC-12: non-HASH input fails');
    is_deeply($p, ['usage: response is not a JSON object'],
        'AC-12: non-HASH input yields exactly the one expected problem');
}
{
    my ($ok, $p) = BpContract::validate_usage({ five_hour => { utilization => 0 } });
    is($ok, 0, 'AC-12: missing seven_day fails');
    ok((grep { /'seven_day' window missing/ } @$p),
        "AC-12: a problem matches qr/'seven_day' window missing/");
}
{
    my ($ok, $p) = BpContract::validate_usage({
        five_hour => 'nope',
        seven_day => { utilization => 0 },
    });
    is($ok, 0, 'AC-12: scalar five_hour fails');
    ok((grep { /'five_hour' window missing/ } @$p),
        "AC-12: a problem matches qr/'five_hour' window missing/");
    ok(!(grep { /five_hour\.utilization/ } @$p),
        'AC-12: no five_hour.utilization problem (next short-circuits the window)');
    ok(!(grep { /five_hour\.resets_at/ } @$p),
        'AC-12: no five_hour.resets_at problem (next short-circuits the window)');
}

# ---- AC-13: doctrine — orchestrator-protocol/SKILL.md carries the triage subsection --
{
    my $skill_path = "$Bin/../../skills/orchestrator-protocol/SKILL.md";
    ok(-e $skill_path, "AC-13: $skill_path exists") or diag("cannot find SKILL.md at $skill_path");

    my @lines;
    if (open my $fh, '<', $skill_path) {
        @lines = <$fh>;
        close $fh;
    }

    my ($role_boundary_idx, $context_economics_idx, $heading_idx);
    for my $i (0 .. $#lines) {
        $role_boundary_idx = $i if !defined($role_boundary_idx) && $lines[$i] =~ /^### Role boundary/;
        $context_economics_idx = $i if !defined($context_economics_idx) && $lines[$i] =~ /^## Context economics/;
        $heading_idx = $i if $lines[$i] =~ /^### Contract-drift triage \(before you forward one\)\s*$/;
    }

    ok(defined $heading_idx,
        'AC-13: SKILL.md contains the exact heading "### Contract-drift triage (before you forward one)"');

    SKIP: {
        skip 'heading not found; cannot verify placement/content', 3 unless defined $heading_idx;

        ok(defined($role_boundary_idx) && defined($context_economics_idx)
                && $heading_idx > $role_boundary_idx && $heading_idx < $context_economics_idx,
            'AC-13: heading is placed after ^### Role boundary and before the next ^## Context economics');

        # Body: lines strictly between the heading and the next line matching ^#{2,3} ...
        my @body;
        for my $i ($heading_idx + 1 .. $#lines) {
            last if $lines[$i] =~ /^#{2,3}\s/;
            push @body, $lines[$i];
        }
        my $body_text = join('', @body);

        my @required = ('/api/oauth/usage', 'contract-drift', 'resets_at', '--action resume');
        my @missing = grep { index($body_text, $_) == -1 } @required;
        ok(scalar(@missing) == 0,
            'AC-13: body contains /api/oauth/usage, contract-drift, resets_at, --action resume')
            or diag('missing literals: ' . join(', ', @missing));

        ok(scalar(@body) > 0, 'AC-13: heading has a non-empty body');
    }
}

done_testing();
