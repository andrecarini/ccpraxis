#!/usr/bin/env perl
# backup-user-config.pl — copy a user's pre-existing Claude Code config aside
# before ccpraxis installs over it.
#
# WHY THIS IS A SCRIPT AND NOT A LINE IN THE INSTALL PROTOCOL.
#
# The install writes ~/.claude/CLAUDE.md and ~/.claude/settings.json — replacing
# the first with a symlink or merging into it, copying or key-merging the second.
# It is interactive and diff-gated, so nothing is clobbered without being shown.
# But a reviewed diff is not a rollback: once the merge is accepted, the file the
# user had is gone, and the README could only honestly tell them to restore
# "from a backup if you kept one".
#
# /steward:backup already does the right thing for the same file
# (plugins/steward/skills/backup/SKILL.md), so the protection existed on the
# routine path and was missing from the one irreversible path: the first run,
# against a config the user already had, by someone who has not yet decided to
# trust this repo.
#
# Asking the protocol to remember is the failure mode this project exists to
# argue against. A step that must be performed by a reader is a step that gets
# skipped; a script either ran or it did not.
#
# Bug report 20260901-140408-f661.
#
# Usage:
#   perl scripts/backup-user-config.pl            # back up, print what happened
#   perl scripts/backup-user-config.pl --json     # machine-readable
#   perl scripts/backup-user-config.pl --dir DIR  # override ~/.claude (tests)
#
# Idempotent and safe to run repeatedly: a file that does not exist is skipped,
# never created; each run stamps a new timestamp so an earlier backup is never
# overwritten. Exit 0 when everything that exists was copied, 1 on a copy error.
use strict;
use warnings;
use File::Copy qw(copy);
use File::Spec;

my ($JSON, $DIR, $HELP);
while (@ARGV) {
    my $a = shift @ARGV;
    if    ($a eq '--json') { $JSON = 1 }
    elsif ($a eq '--dir')  { $DIR = shift @ARGV }
    elsif ($a =~ /^-h|^--help$/) { $HELP = 1 }
    else { die "backup-user-config.pl: unknown argument '$a'\n" }
}

if ($HELP) {
    print "Usage: perl backup-user-config.pl [--json] [--dir DIR]\n";
    print "Copies existing CLAUDE.md and settings.json aside, timestamped.\n";
    exit 0;
}

sub home_dir {
    return $DIR if defined $DIR && length $DIR;
    my $h = $ENV{HOME} // $ENV{USERPROFILE};
    die "backup-user-config.pl: cannot determine home directory\n"
        unless defined $h && length $h;
    return File::Spec->catdir($h, '.claude');
}

# UTC, and colon-free: a colon is legal in a POSIX filename and is not legal in
# a Windows one, and this repo runs on both.
sub stamp {
    my @t = gmtime(time);
    return sprintf '%04d-%02d-%02dT%02d%02d%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
}

my $root  = home_dir();
my $when  = stamp();
my @files = qw(CLAUDE.md settings.json);

my (@copied, @skipped, @failed);

for my $name (@files) {
    my $src = File::Spec->catfile($root, $name);

    # A symlink here means a PREVIOUS ccpraxis install already took this file
    # over; the user's original is whatever the symlink was made from, not this
    # path, and copying it would archive our own payload as though it were
    # theirs. Skip rather than record a misleading backup.
    if (-l $src) {
        push @skipped, { path => $src, reason => 'already a symlink (ccpraxis is installed here)' };
        next;
    }
    unless (-f $src) {
        push @skipped, { path => $src, reason => 'does not exist' };
        next;
    }

    my $dest = "$src.pre-ccpraxis.$when";
    # Never overwrite: if a backup for this second already exists, walk a suffix
    # rather than destroy it. Losing a backup while taking a backup would be a
    # remarkable way to fail.
    if (-e $dest) {
        my $n = 1;
        $n++ while -e "$dest.$n";
        $dest = "$dest.$n";
    }

    if (copy($src, $dest)) {
        push @copied, { from => $src, to => $dest, bytes => (-s $dest // 0) };
    }
    else {
        push @failed, { path => $src, error => "$!" };
    }
}

if ($JSON) {
    # Hand-rolled so this script has no non-core dependency and can run before
    # anything at all is installed.
    my $q = sub { my $s = shift // ''; $s =~ s/(["\\])/\\$1/g; $s =~ s/\n/\\n/g; qq{"$s"} };
    my @parts;
    push @parts, '"status":' . $q->(@failed ? 'error' : 'ok');
    push @parts, '"copied":[' . join(',', map {
        '{"from":' . $q->($_->{from}) . ',"to":' . $q->($_->{to}) . ',"bytes":' . ($_->{bytes} + 0) . '}'
    } @copied) . ']';
    push @parts, '"skipped":[' . join(',', map {
        '{"path":' . $q->($_->{path}) . ',"reason":' . $q->($_->{reason}) . '}'
    } @skipped) . ']';
    push @parts, '"failed":[' . join(',', map {
        '{"path":' . $q->($_->{path}) . ',"error":' . $q->($_->{error}) . '}'
    } @failed) . ']';
    print '{', join(',', @parts), "}\n";
}
else {
    print "backed up: $_->{from}\n        -> $_->{to}\n" for @copied;
    print "skipped:   $_->{path} ($_->{reason})\n"        for @skipped;
    print "FAILED:    $_->{path} ($_->{error})\n"         for @failed;
    print "nothing to back up; no existing config found\n"
        unless @copied || @failed;
}

exit(@failed ? 1 : 0);
