#!/usr/bin/env perl
# Decision #10 / Ruling B (2026-07-28) — the .claude.json relocation migration.
#
# WHY THIS FILE EXISTS. The harvest audit failed this package because no
# migration code existed at all: the coordinator had substituted a post-hoc
# assertion for the COPY + backup-rename mechanism Decision #10 mandates. The
# ruling accepted the ARGUMENT (in this container both paths are one host
# file — s01 probe-05: inode 9288674232328321, dev 43 — so running the copy
# literally would rename the only config away from the path both resolvers
# read, i.e. the migration would BE the outage) but rejected the conclusion:
# the code must exist as a GUARDED no-op. This file is what keeps it from
# being unverifiable dead code — it drives the guard AND the real migration.
#
# ClaudeConfig::relocate_claude_json is the implementation; launcher.pl keeps
# only a thin wrapper that injects log_ev. That split exists because
# launcher.pl is a script with no main guard, so nothing inside it can be
# unit-tested — the same reasoning that put the mount-shape predicate in
# MountSpec.pm.
#
# No container runtime needed; deliberately does NOT use TestSandbox (which
# dies at import without docker/podman). Runs on host and in-container alike.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP ();
use ClaudeConfig ();

plan tests => 34;

# A realistic config carrying exactly the keys Decision #10 defines as "intact".
my $CONFIG = JSON::PP->new->canonical->encode({
    hasCompletedOnboarding => JSON::PP::true,
    lastOnboardingVersion  => '99.0.0',
    oauthAccount           => { accountUuid => 'abc-123', emailAddress => 'a@b.c' },
    userID                 => 'user-xyz',
    projects               => { '/project' => { allowedTools => [] } },
});

sub _slurp { open my $fh, '<:raw', $_[0] or return undef; local $/; my $c = <$fh>; close $fh; return $c }
sub _spew  { open my $fh, '>:raw', $_[0] or die "spew $_[0]: $!"; print $fh $_[1]; close $fh }

# Collect the (event, fields) pairs the function emits, so the log is asserted
# rather than assumed — a silent skip is indistinguishable from a no-op.
sub _collector { my $ev = shift; return sub { push @$ev, { event => $_[0], %{ $_[1] } } } }

# ---------------------------------------------------------------------
# 1. no-source — nothing at the old path. The legitimate first-run case.
# ---------------------------------------------------------------------
{
    my $d = tempdir(CLEANUP => 1);
    my @ev;
    my $out = ClaudeConfig::relocate_claude_json("$d/absent.json", "$d/new.json",
        logger => _collector(\@ev));
    is($out, 'no-source', 'absent old path -> no-source');
    is(scalar @ev, 0, 'no-source emits no event (nothing happened)');
    ok(!-e "$d/new.json", 'no-source creates nothing at the new path');
}

# A directory at the old path is not a config to migrate.
{
    my $d = tempdir(CLEANUP => 1);
    mkdir "$d/olddir" or die;
    is(ClaudeConfig::relocate_claude_json("$d/olddir", "$d/new.json"), 'no-source',
        'a DIRECTORY at the old path -> no-source (never migrated, never removed)');
    ok(-d "$d/olddir", 'the directory is left alone');
}

# ---------------------------------------------------------------------
# 2. same-file — THE case this container is in. Two different path
#    spellings, one inode (a hard link is the truest form of this).
#    Must skip entirely: no copy, no backup, no rename.
# ---------------------------------------------------------------------
{
    my $d = tempdir(CLEANUP => 1);
    my ($old, $new) = ("$d/old.json", "$d/new.json");
    _spew($old, $CONFIG);
    link($old, $new) or die "link: $!";   # same dev+inode, different names

    my @ev;
    my $out = ClaudeConfig::relocate_claude_json($old, $new, logger => _collector(\@ev), now => 1234);
    is($out, 'same-file', 'old and new resolving to ONE file -> same-file');
    is(scalar @ev, 1, 'the skip is logged (a silent skip would be indistinguishable from dead code)');
    is($ev[0]{event}, 'claude_json_relocation_skip', 'skip event name');
    is($ev[0]{reason}, 'same-file', 'skip reason names the guard that fired');
    ok(defined $ev[0]{inode} && defined $ev[0]{dev}, 'skip event records the dev+inode it matched on');

    ok(-e $old, 'same-file: the old path still exists');
    ok(-e $new, 'same-file: the new path still exists');
    is(_slurp($old), $CONFIG, 'same-file: contents untouched');
    my @bak = glob("$d/*pre-relocation-bak*");
    is(scalar @bak, 0, 'same-file: NO backup was created (renaming here would be the outage)');
}

# ---------------------------------------------------------------------
# 3. migrated — genuinely distinct locations: the real Decision #10 path.
# ---------------------------------------------------------------------
{
    my $d = tempdir(CLEANUP => 1);
    my ($old, $new) = ("$d/old.json", "$d/sub/new.json");
    mkdir "$d/sub" or die;
    _spew($old, $CONFIG);

    my @ev;
    my $out = ClaudeConfig::relocate_claude_json($old, $new, logger => _collector(\@ev), now => 1700000000);
    is($out, 'migrated', 'distinct locations -> migrated');
    ok(-e $new, 'migrated: the new location exists');
    is(_slurp($new), $CONFIG, 'migrated: new location holds the original bytes exactly');

    # Decision #10's literal definition of "intact".
    my $got = JSON::PP->new->decode(_slurp($new));
    ok($got->{hasCompletedOnboarding}, 'intact: hasCompletedOnboarding survived');
    is($got->{userID}, 'user-xyz',      'intact: userID survived');
    is($got->{oauthAccount}{accountUuid}, 'abc-123', 'intact: oauthAccount survived');
    ok(exists $got->{projects}{'/project'}, 'intact: projects survived');

    ok(!-e $old, 'migrated: the old path no longer holds the live config');
    ok(-e "$old.pre-relocation-bak-1700000000",
        'migrated: old renamed to the timestamped .pre-relocation-bak-<ts> backup');
    is(_slurp("$old.pre-relocation-bak-1700000000"), $CONFIG,
        'migrated: the backup is byte-identical to the original (non-destructive)');
    is($ev[-1]{event}, 'claude_json_relocation_migrated', 'the migration is logged');

    # 4. idempotent — a second run must be a harmless no-op, not a re-migration
    #    that would clobber the new file with a stale backup.
    my @ev2;
    my $again = ClaudeConfig::relocate_claude_json($old, $new, logger => _collector(\@ev2), now => 1700000001);
    is($again, 'no-source', 'idempotent: re-running finds nothing at the old path');
    is(_slurp($new), $CONFIG, 'idempotent: the migrated config is untouched by the second run');
}

# ---------------------------------------------------------------------
# 5. failed — the copy cannot land. The original MUST be left exactly as
#    it was: it is still the only copy at that moment.
# ---------------------------------------------------------------------
{
    my $d = tempdir(CLEANUP => 1);
    my $old = "$d/old.json";
    _spew($old, $CONFIG);
    # Target inside a directory that does not exist -> open() fails. Chosen
    # over chmod because these tests run as root, where mode bits are bypassed.
    my $new = "$d/nonexistent-dir/new.json";

    my @ev;
    my $out = ClaudeConfig::relocate_claude_json($old, $new, logger => _collector(\@ev));
    is($out, 'failed', 'unwritable target -> failed');
    ok(-e $old, 'failed: the ORIGINAL is still in place');
    is(_slurp($old), $CONFIG, 'failed: the original is byte-identical (nothing was destroyed)');
    my @bak = glob("$d/*pre-relocation-bak*");
    is(scalar @bak, 0, 'failed: no backup rename happened (the copy never succeeded)');
}

# ---------------------------------------------------------------------
# 6. target-exists — a non-empty config already at the new location.
#    Skip and touch nothing; never clobber a live config.
# ---------------------------------------------------------------------
{
    my $d = tempdir(CLEANUP => 1);
    my ($old, $new) = ("$d/old.json", "$d/new.json");
    _spew($old, $CONFIG);
    _spew($new, '{"already":"here"}');

    my $out = ClaudeConfig::relocate_claude_json($old, $new);
    is($out, 'target-exists', 'non-empty new location -> target-exists');
    is(_slurp($new), '{"already":"here"}', 'target-exists: the existing config is NOT clobbered');
    is(_slurp($old), $CONFIG, 'target-exists: the old file is left alone too');
}
