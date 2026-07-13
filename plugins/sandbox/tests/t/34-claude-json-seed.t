#!/usr/bin/env perl
# ClaudeConfig::heal_claude_json — the self-heal for claude-home/.claude.json's
# onboarding bypass. A 0-byte / corrupt config (left by an interrupted in-place
# write or two connectors writing the one shared file) was treated as "present"
# by the launcher's old `-f` guard, so the onboarding template was never
# re-applied and the in-container claude reopened the setup wizard. These lock
# the heal: reseed when missing/empty/corrupt, merge the onboarding keys into a
# valid config that lost them, and DON'T touch an already-onboarded config.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use JSON::PP ();
use ClaudeConfig;

plan tests => 20;

my $TPL = <<'JSON';
{
  "hasCompletedOnboarding": true,
  "lastOnboardingVersion": "99.0.0",
  "numStartups": 1,
  "hasSeenTasksHint": true,
  "editorMode": "vim"
}
JSON

my $jp = JSON::PP->new->utf8;

# ---- reseed: missing / empty / corrupt -> template verbatim -----------------
for my $case (
    ['undef (file missing)', undef],
    ['empty string',         ''],
    ['whitespace only',      "  \n\t "],
    ['unparseable garbage',  '{ not json'],
    ['valid JSON but array', '[]'],
    ['valid JSON but scalar','42'],
) {
    my ($label, $cur) = @$case;
    my $out = ClaudeConfig::heal_claude_json($cur, $TPL);
    is($out, $TPL, "reseed ($label) returns the template verbatim");
}

# ---- reseed with NO template -> synthesized minimal bypass ------------------
{
    my $out = ClaudeConfig::heal_claude_json(undef, undef);
    ok(defined $out && length $out, 'reseed without a template still returns content');
    my $o = $jp->decode($out);
    ok($o->{hasCompletedOnboarding} ? 1 : 0, 'synthesized config has hasCompletedOnboarding true');
    is($o->{lastOnboardingVersion}, '99.0.0', 'synthesized config has lastOnboardingVersion');
}

# ---- merge: valid config missing BOTH onboarding keys -----------------------
{
    my $cur = $jp->encode({
        oauthAccount => { emailAddress => 'me@example.com' },
        userID       => 'abc123',
        projects     => { '/work' => { allowedTools => [] } },
        editorMode   => 'emacs',     # a user choice that must survive
    });
    my $out = ClaudeConfig::heal_claude_json($cur, $TPL);
    ok(defined $out, 'a config missing the onboarding keys is rewritten');
    my $o = $jp->decode($out);
    ok($o->{hasCompletedOnboarding} ? 1 : 0, 'merge sets hasCompletedOnboarding true');
    is($o->{lastOnboardingVersion}, '99.0.0',        'merge sets lastOnboardingVersion');
    is($o->{editorMode},            'emacs',         'merge preserves the user editorMode (no clobber)');
    is($o->{userID},                'abc123',        'merge preserves userID');
    is($o->{oauthAccount}{emailAddress}, 'me@example.com', 'merge preserves nested oauthAccount');
    ok(!exists $o->{numStartups}, 'merge injects ONLY onboarding keys, not other template keys');
}

# ---- merge: only one onboarding key missing ---------------------------------
{
    my $cur = $jp->encode({
        hasCompletedOnboarding => JSON::PP::true,   # present already
        userID                 => 'x',
    });
    my $out = ClaudeConfig::heal_claude_json($cur, $TPL);
    ok(defined $out, 'config missing only lastOnboardingVersion is rewritten');
    my $o = $jp->decode($out);
    is($o->{lastOnboardingVersion}, '99.0.0', 'the missing key is added');
}

# ---- no-op: already onboarded -> undef (no needless rewrite) ----------------
{
    my $cur = $jp->encode({
        hasCompletedOnboarding => JSON::PP::true,
        lastOnboardingVersion  => '1.2.3',     # user's own value, must be kept
        userID                 => 'x',
    });
    my $out = ClaudeConfig::heal_claude_json($cur, $TPL);
    is($out, undef, 'an already-onboarded config returns undef (no rewrite)');
}

# ---- merge respects an existing onboarding value (never override) -----------
{
    my $cur = $jp->encode({
        hasCompletedOnboarding => JSON::PP::true,
        lastOnboardingVersion  => '7.7.7',
    });
    my $out = ClaudeConfig::heal_claude_json($cur, $TPL);
    is($out, undef, 'both keys present (custom version) -> no change, version not forced to template');
}
