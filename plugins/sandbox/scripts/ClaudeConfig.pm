package ClaudeConfig;
# Self-healing for claude-home/.claude.json — the per-sandbox claude config that
# is bind-mounted to /root/.claude.json inside the container.
#
# THE BUG THIS FIXES. The launcher seeds .claude.json from a container-config
# template whose whole purpose is to carry the onboarding-bypass keys
# (hasCompletedOnboarding etc.) so the in-container claude never drops the user
# into the first-run setup wizard. But the seeding guarded on `-f` (file exists),
# which is TRUE for a 0-byte file — so once .claude.json was truncated to 0 bytes
# the template was never re-applied. claude treats a 0-byte (or otherwise
# unparseable) .claude.json as corrupt: it renames it to .claude.json.corrupted.*
# and re-runs onboarding. A .claude.json can reach 0 bytes from an interrupted
# in-place write (claude writes it non-atomically and a container stop / engine
# drop can catch it mid-write) or from two connector windows writing the one
# shared file concurrently. This is the same 0-byte class of bug Fix 1 fixed for
# the credentials accumulator — there it was the .credentials.json side; here it
# is .claude.json, which was missed.
#
# heal_claude_json is the PURE decision (text in, text-or-undef out) so the
# launcher's file I/O wrapper stays thin and this is unit-testable on the host.
use strict;
use warnings;
use JSON::PP ();

# The keys whose ABSENCE makes the in-container claude show the onboarding
# wizard. We only ever ADD these to an existing config (never override a value
# the user/claude already chose); their canonical values come from the template,
# with a built-in fallback so a missing template can't defeat the bypass.
our @ONBOARDING_KEYS = qw(hasCompletedOnboarding lastOnboardingVersion);

sub _onboarding_defaults {
    return (
        hasCompletedOnboarding => JSON::PP::true,
        lastOnboardingVersion  => '99.0.0',
    );
}

# heal_claude_json($current_bytes, $template_bytes) -> $new_bytes | undef
#
# Decide what (if anything) claude-home/.claude.json must be rewritten to so the
# sandbox claude never lands in onboarding:
#
#   * current missing / empty / whitespace / unparseable / not-an-object
#       -> reseed: the template verbatim when it's a valid object (it also
#          carries editorMode + the hint flags), else a synthesized minimal
#          onboarding-bypass object (so the bypass holds even if the template
#          file is gone). A 0-byte file MUST be treated as absent here — that is
#          the whole point.
#   * current valid JSON object but missing an onboarding key
#       -> merge in ONLY the missing onboarding key(s), preserving every existing
#          key (oauthAccount, projects, mcp config, editorMode, theme, ...), and
#          return the re-encoded bytes.
#   * current valid JSON object already carrying the onboarding keys
#       -> undef (no rewrite needed).
#
# Returning undef when nothing must change lets the caller skip the in-place
# rewrite — important because .claude.json is a single-file bind mount, so a
# needless rewrite churns the file the container reads through.
sub heal_claude_json {
    my ($cur, $tpl) = @_;

    my $tpl_obj = (defined $tpl && $tpl =~ /\S/)
        ? eval { JSON::PP->new->utf8->decode($tpl) } : undef;
    $tpl_obj = undef unless ref $tpl_obj eq 'HASH';

    my $cur_obj = (defined $cur && $cur =~ /\S/)
        ? eval { JSON::PP->new->utf8->decode($cur) } : undef;

    my %defaults = _onboarding_defaults();

    # Missing / empty / unparseable / non-object -> reseed.
    if (ref $cur_obj ne 'HASH') {
        return $tpl if defined $tpl_obj;   # template verbatim (preserve its bytes)
        return JSON::PP->new->utf8->canonical->pretty->encode(\%defaults);
    }

    # Valid object: add only the missing onboarding keys, sourcing each value
    # from the template when present, else the built-in default.
    my $changed = 0;
    for my $k (@ONBOARDING_KEYS) {
        next if exists $cur_obj->{$k};
        $cur_obj->{$k} = (defined $tpl_obj && exists $tpl_obj->{$k})
            ? $tpl_obj->{$k} : $defaults{$k};
        $changed = 1;
    }
    return undef unless $changed;
    return JSON::PP->new->utf8->canonical->encode($cur_obj);
}

1;
