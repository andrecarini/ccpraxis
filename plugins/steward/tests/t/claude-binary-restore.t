#!/usr/bin/env perl
# platform: any
# claude-binary-backup.pl must hand back a RUNNABLE claude, through the
# symlink the native installer uses on macOS and Linux.
#
# WHY. File::Copy::copy creates its destination 0666 & ~umask, so every
# snapshot and every restore came out 0644: a restore left `claude`
# non-executable. And ~/.local/bin/claude is a symlink into
# ~/.local/share/claude/versions/<v> there, so renaming the staged copy over
# it replaced the link with a plain file behind the installer's back. Windows
# never noticed either: no mode bits, and claude.exe is a real file.
#
# The fake binary is a tiny sh script that prints a version, so "runnable" is
# asserted by running it. HERMETIC: CLAUDE_BINARY_BACKUP_ROOT and --binary
# point every operation at a tempdir.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;

my $SCRIPT = "$Bin/../../scripts/claude-binary-backup.pl";
ok(-f $SCRIPT, 'claude-binary-backup.pl exists') or BAIL_OUT('script missing');

plan skip_all => 'POSIX mode bits and symlinks: not applicable to claude.exe on Windows'
    if $^O =~ /^(MSWin32|cygwin|msys)$/;

my $T = tempdir(CLEANUP => 1);
$ENV{CLAUDE_BINARY_BACKUP_ROOT} = "$T/backups";
$ENV{HOME} = "$T/home";
make_path("$T/home/.local/bin", "$T/home/.local/share/claude/versions");

sub write_exe {
    my ($path, $version) = @_;
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} "#!/bin/sh\necho '$version (Claude Code)'\n";
    close $fh;
    chmod 0755, $path or die "chmod $path: $!";
}
sub run_script {
    my (@args) = @_;
    open my $fh, '-|', $^X, $SCRIPT, @args or die "spawn: $!";
    local $/;
    my $out = <$fh> // '';
    close $fh;
    return ($? >> 8, (eval { decode_json($out) } // { raw => $out }));
}
sub mode_of { return (stat($_[0]))[2] & 07777; }
sub runs_as {
    my ($path) = @_;
    return undef unless -x $path;
    my $out = `"$path" 2>/dev/null`;
    return $? == 0 ? $out : undef;
}

my $versions = "$T/home/.local/share/claude/versions";
my $link     = "$T/home/.local/bin/claude";
write_exe("$versions/2.1.300", '2.1.300');
symlink("../share/claude/versions/2.1.300", $link) or die "symlink: $!";
ok(-l $link && -x $link, '(setup) ~/.local/bin/claude is a relative symlink to an executable version file');

# --- snapshot keeps the mode --------------------------------------------
my ($rc, $snap) = run_script('snapshot', '--binary', $link);
is($rc, 0, 'snapshot exits 0') or diag(explain($snap));
my $snap_bin = "$snap->{path}/claude";
ok(-f $snap_bin, 'the snapshot holds the binary');
is(sprintf('%04o', mode_of($snap_bin)), '0755', 'the snapshot copy keeps the source mode (was 0644)');

# --- a botched update: the version file is replaced and loses its exec bit
write_exe("$versions/2.1.300", '9.9.9-broken');
chmod 0644, "$versions/2.1.300";

($rc, my $res) = run_script('restore', '--snapshot', $snap->{id}, '--binary', $link);
is($rc, 0, 'restore exits 0') or diag(explain($res));
ok(-l $link, 'restore leaves ~/.local/bin/claude a symlink (it used to become a plain file)');
is(readlink($link), '../share/claude/versions/2.1.300', 'the symlink still points where the installer put it');
like(($res->{restored_path} // ''), qr{/versions/2\.1\.300\z}, 'the report names the file actually written');
is(sprintf('%04o', mode_of("$versions/2.1.300")), '0644',
    'a live file keeps the mode it had (here the broken 0644, nothing invented)');

# --- the realistic case: the live file is executable, and so is the result
write_exe("$versions/2.1.300", '9.9.9-broken');
($rc, $res) = run_script('restore', '--snapshot', $snap->{id}, '--binary', $link);
is($rc, 0, 'restore over an executable live file exits 0') or diag(explain($res));
like(runs_as($link) // '', qr/^2\.1\.300 /, 'the restored claude RUNS through the symlink and is the snapshot version');

# --- the live file is gone: restore recreates it executable ---------------
unlink "$versions/2.1.300";
($rc, $res) = run_script('restore', '--snapshot', $snap->{id}, '--binary', $link, '--no-pre-snapshot');
is($rc, 0, 'restore into a dangling symlink exits 0') or diag(explain($res));
ok(-l $link, '...the link is still a link');
like(runs_as($link) // '', qr/^2\.1\.300 /, '...and the recreated target is executable and correct');

# --- an old 0644 snapshot (taken before the fix) still restores runnable --
chmod 0644, $snap_bin;
unlink "$versions/2.1.300";
($rc, $res) = run_script('restore', '--snapshot', $snap->{id}, '--binary', $link, '--no-pre-snapshot');
is($rc, 0, 'restore from a 0644 snapshot exits 0') or diag(explain($res));
like(runs_as($link) // '', qr/^2\.1\.300 /, 'a pre-fix 0644 snapshot still restores an executable binary');

# --- a plain (non-symlink) binary is replaced in place, exec bit intact ---
# Snapshot ids have one-second resolution; the restores above may share this
# second, and a second pre-restore snapshot of an unversioned binary in the
# same second is refused as an id collision by design.
sleep 1;
my $plain = "$T/home/plain-claude";
write_exe($plain, '2.1.301');
($rc, my $s2) = run_script('snapshot', '--binary', $plain);
is($rc, 0, 'snapshot of a plain binary exits 0') or diag(explain($s2));
write_exe($plain, 'broken');
($rc, $res) = run_script('restore', '--snapshot', $s2->{id}, '--binary', $plain);
is($rc, 0, 'restore of a plain binary exits 0') or diag(explain($res));
ok(!-l $plain, 'a plain binary stays a plain file');
like(runs_as($plain) // '', qr/^2\.1\.301 /, 'and runs as the snapshot version');

done_testing();
