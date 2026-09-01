#!/usr/bin/env perl
# 13-install-config-backup.t — installing must not destroy a config the user
# already had.
#
# Bug report 20260901-140408-f661. The install replaces ~/.claude/CLAUDE.md with
# a symlink (or merges into it) and copies/merges ~/.claude/settings.json.
# Nothing took a backup first, while /steward:backup takes a timestamped one for
# the same settings.json on every routine run. The protection existed on the
# repeatable path and was missing from the irreversible one.
#
# The README could therefore only tell the user to restore "from a backup if you
# kept one" — asking them to have done something we were better placed to do, at
# the one moment the original still existed.
#
# AC1  an existing config is copied aside, and the copy matches the original
# AC2  a second run does not overwrite the first backup
# AC3  a missing file is skipped, never created
# AC4  a file ALREADY symlinked by a prior install is not archived as if it were
#      the user's own
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use StewardTest qw(ok is like done_testing diag);

my $SCRIPT = "$Bin/../../../../scripts/backup-user-config.pl";
ok(-f $SCRIPT, 'the backup script exists') or do { done_testing(); exit };

sub run_backup {
    my $dir = shift;
    my $out = `"$^X" "$SCRIPT" --dir "$dir" 2>&1`;
    return { out => $out, exit => $? >> 8 };
}

sub write_file {
    my ($p, $t) = @_;
    open my $fh, '>:raw', $p or die "write $p: $!";
    print {$fh} $t;
    close $fh;
}

sub slurp {
    my $p = shift;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    return <$fh>;
}

sub backups_in {
    my $dir = shift;
    opendir my $dh, $dir or return ();
    my @b = sort grep { /\.pre-ccpraxis\./ } readdir $dh;
    closedir $dh;
    # `return sort @b` puts sort in scalar context, which yields undef rather
    # than a count -- so `is(scalar backups_in($d), 0)` compared undef to 0 and
    # failed for a reason that had nothing to do with the code under test.
    return wantarray ? @b : scalar @b;
}

# ---------------------------------------------------------------------------
# AC1 — an existing config is copied aside, byte-for-byte.
# ---------------------------------------------------------------------------
my $root = tempdir('cfg-backup-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $home = "$root/.claude";
make_path($home);

my $claude_body   = "# my own rules\nnever touch prod\n";
my $settings_body = qq({\n  "model": "opus",\n  "mine": true\n}\n);
write_file("$home/CLAUDE.md",     $claude_body);
write_file("$home/settings.json", $settings_body);

my $r1 = run_backup($home);
is($r1->{exit}, 0, 'AC1: backup run succeeded') or diag($r1->{out});

my @b1 = backups_in($home);
is(scalar @b1, 2, 'AC1: both files were backed up') or diag("found: @b1");

# THE ASSERTION THAT MATTERS: the copy is the user's ORIGINAL content. A backup
# that exists but holds the wrong bytes is worse than none, because it will be
# trusted.
my ($cbak) = grep { /^CLAUDE\.md\./ } @b1;
my ($sbak) = grep { /^settings\.json\./ } @b1;
is(slurp("$home/$cbak"), $claude_body,   'AC1: CLAUDE.md backup is byte-identical');
is(slurp("$home/$sbak"), $settings_body, 'AC1: settings.json backup is byte-identical');

# The originals are untouched -- this copies aside, it does not move.
is(slurp("$home/CLAUDE.md"), $claude_body, 'AC1: the original CLAUDE.md is still there');

# ---------------------------------------------------------------------------
# AC2 — a second run must not destroy the first backup.
#
# Both runs can land in the same second, so the timestamp alone does not
# guarantee a distinct name. Losing a backup while taking a backup would be a
# remarkable way to fail, so the collision path is asserted rather than assumed.
# ---------------------------------------------------------------------------
write_file("$home/CLAUDE.md", "# changed since the first backup\n");
my $r2 = run_backup($home);
is($r2->{exit}, 0, 'AC2: second backup run succeeded') or diag($r2->{out});

my @b2 = backups_in($home);
ok(scalar @b2 > scalar @b1, "AC2: the second run ADDED backups (" . scalar(@b1) . " -> " . scalar(@b2) . ")")
    or diag("found: @b2");

# The first backup still holds the first content.
is(slurp("$home/$cbak"), $claude_body,
    'AC2: the ORIGINAL backup still holds the original bytes after a second run');

# ---------------------------------------------------------------------------
# AC3 — a missing file is skipped, not created.
# ---------------------------------------------------------------------------
my $empty_root = tempdir('cfg-empty-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $empty_home = "$empty_root/.claude";
make_path($empty_home);

my $r3 = run_backup($empty_home);
is($r3->{exit}, 0, 'AC3: a home with no config is not an error') or diag($r3->{out});
is(scalar backups_in($empty_home), 0, 'AC3: no backups were invented');
ok(!-e "$empty_home/CLAUDE.md",     'AC3: CLAUDE.md was not created');
ok(!-e "$empty_home/settings.json", 'AC3: settings.json was not created');

# ---------------------------------------------------------------------------
# AC4 — a file a PREVIOUS install already symlinked is not the user's own.
#
# ccpraxis replaces CLAUDE.md with a symlink to its own payload. Re-running the
# install would otherwise archive OUR file as though it were the user's, which
# is a backup that quietly says the wrong thing.
# ---------------------------------------------------------------------------
{
    my $link_root = tempdir('cfg-link-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $link_home = "$link_root/.claude";
    make_path($link_home);
    write_file("$link_root/payload.md", "# ccpraxis payload, not the user's\n");

    # symlink() RETURNING TRUE IS NOT EVIDENCE A SYMLINK EXISTS. On this
    # Git-for-Windows host it returns 1 and produces a regular file copy --
    # measured: `-l` is false, `-f` is true -- which is the same silent fallback
    # the install protocol warns about for `ln -s`. Trusting the return value
    # made this case build a plain file, hand it to a script whose whole job is
    # to treat symlinks differently, and then fail the script for the fixture's
    # mistake. Verify the artefact, not the call.
    eval { symlink("$link_root/payload.md", "$link_home/CLAUDE.md") };
    my $made = -l "$link_home/CLAUDE.md";

    if (!$made) {
        unlink "$link_home/CLAUDE.md";   # remove the fallback copy, if one was made
        diag('AC4 NOT RUN: symlink() unavailable on this host (Windows without Developer Mode)');
        ok(1, 'AC4: skipped, symlinks unavailable (see diag)');
    }
    else {
        my $r4 = run_backup($link_home);
        is($r4->{exit}, 0, 'AC4: run succeeded with a symlinked CLAUDE.md') or diag($r4->{out});

        my @b4 = grep { /^CLAUDE\.md\./ } backups_in($link_home);
        is(scalar @b4, 0, "AC4: a symlinked CLAUDE.md is NOT archived as the user's own")
            or diag("archived anyway: @b4");
    }
}

done_testing();
