package ClaudeConfig;
# Self-healing for claude-home/.claude.json — the per-sandbox claude config.
# It is NOT bind-mounted as its own single-file mount: it lives inside the
# /root/.claude dir bind (host claude-home/.claude.json), seen in-container
# at /root/.claude/.claude.json via CLAUDE_CONFIG_DIR=/root/.claude.
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
# Returning undef when nothing must change lets the caller skip the write
# entirely — undef means "already onboarded, do not touch this file". That
# matters because concurrent in-container writers (the CLI itself, an mcp
# add/remove, a token refresh) may be mid read-modify-write on the same
# shared file; a needless rewrite here is a needless chance to race them,
# not a mount-shape concern.
# is_parseable_json($bytes) -> 0|1
# Pure, path-free predicate so the launcher can distinguish "unparseable ->
# back up before reseeding" from "valid but needs a merge" without
# duplicating a JSON decoder. undef / empty / whitespace-only -> 0. Uses
# the JSON::PP already imported by this module. No file I/O.
sub is_parseable_json {
    my ($bytes) = @_;
    return 0 unless defined $bytes && $bytes =~ /\S/;
    my $ok = eval { JSON::PP->new->utf8->decode($bytes); 1 };
    return $ok ? 1 : 0;
}

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

# relocate_claude_json($old, $new, %opt) -> $outcome
#
# Decision #10 / Ruling B (2026-07-28). One-time, non-destructive, idempotent
# migration of the global config off the OLD pre-fix location onto the NEW
# CLAUDE_CONFIG_DIR-resolved one: COPY old -> new, then rename old aside to
# "<old>.pre-relocation-bak-<ts>".
#
# THE GUARD IS THE POINT. In this project's layout both paths resolve to the
# SAME host file — claude-home/.claude.json, seen through the (removed)
# single-file bind and through the dir bind (s01 probe-05: inode
# 9288674232328321, dev 43 via both). Executing the copy+backup-rename there
# would rename the ONLY config away from the exact path both the old and the
# new resolver read: the "migration" would itself be the outage. So a same-file
# check (dev+inode, NOT string comparison — the two paths are spelled
# differently) skips the whole operation and logs the skip.
#
# It is still written, rather than omitted, because Decision #10 was authored
# for EXISTING sandboxes whose layout may not match this container's.
#
# UNLIKE heal_claude_json this function DOES perform I/O — that is inherent to
# a file migration. It lives here rather than in launcher.pl for the same
# reason the mount-shape predicate lives in MountSpec.pm: launcher.pl is a
# script with no main guard, so nothing in it can be unit-tested. The
# launcher keeps a thin wrapper that injects its own logger.
#
# Outcomes:
#   'no-source'     old missing (or a directory) -> nothing to migrate
#   'same-file'     old and new are one file -> SKIP (this container's case)
#   'target-exists' new already holds a non-empty config -> SKIP, touch nothing
#   'migrated'      copied, verified, old renamed to the timestamped backup
#   'failed'        copy or verification failed -> old left EXACTLY as it was
#
# %opt: logger => sub { $event, \%fields }; now => epoch (pins the suffix).
sub relocate_claude_json {
    my ($old, $new, %opt) = @_;
    my $log = $opt{logger} || sub { };
    my $now = defined $opt{now} ? $opt{now} : time();

    return 'no-source' unless defined $old && length $old && -e $old;
    return 'no-source' if -d $old;

    if (defined $new && length $new && -e $new) {
        my @so = stat($old);
        my @sn = stat($new);
        if (@so && @sn && $so[0] == $sn[0] && $so[1] == $sn[1]) {
            $log->('claude_json_relocation_skip',
                   { reason => 'same-file', path => $old, dev => $so[0], inode => $so[1] });
            return 'same-file';
        }
        if (-s $new) {
            $log->('claude_json_relocation_skip',
                   { reason => 'target-exists', old => $old, new => $new });
            return 'target-exists';
        }
    }

    # Genuinely distinct locations: copy first, verify, and only then move the
    # original aside. Ordering matters — the original is the only copy until
    # the new one is proven good.
    my $bytes = _slurp_raw($old);
    unless (defined $bytes && length $bytes) {
        $log->('claude_json_relocation_failed', { reason => 'unreadable-source', old => $old });
        return 'failed';
    }
    unless (_spew_atomic($new, $bytes)) {
        $log->('claude_json_relocation_failed',
               { reason => 'copy-failed', old => $old, new => $new });
        return 'failed';
    }
    my $check = _slurp_raw($new);
    unless (defined $check && $check eq $bytes && is_parseable_json($check)) {
        $log->('claude_json_relocation_failed',
               { reason => 'verify-failed', old => $old, new => $new });
        return 'failed';   # old untouched: nothing lost
    }
    my $backup = "$old.pre-relocation-bak-$now";
    unless (rename($old, $backup)) {
        $log->('claude_json_relocation_failed',
               { reason => 'backup-rename-failed', old => $old, backup => $backup });
        return 'failed';   # new is in place and valid; old still readable
    }
    chmod 0600, $new;
    $log->('claude_json_relocation_migrated', { old => $old, new => $new, backup => $backup });
    return 'migrated';
}

sub _slurp_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# Same temp+rename discipline the launcher uses: stage in the SAME directory
# (so rename is atomic and never EXDEV), chmod before the rename, and unlink
# the temp on any failure so a failed copy never leaves litter.
sub _spew_atomic {
    my ($path, $bytes) = @_;
    my $tmp = "$path.tmp.$$." . sprintf('%06x', int(rand(0xffffff)));
    open my $fh, '>:raw', $tmp or return 0;
    print $fh $bytes or do { close $fh; unlink $tmp; return 0 };
    unless (close $fh) { unlink $tmp; return 0 }
    chmod 0600, $tmp;
    unless (rename($tmp, $path)) { unlink $tmp; return 0 }
    return 1;
}

1;
