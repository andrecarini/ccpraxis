#!/usr/bin/env perl
# platform: any
# native_path: a real host path handed to a native Windows program must arrive
# in a form Windows resolves to the same file.
#
# Bug (2026-11-02): the launcher handed keep-awake.ps1 its -PidFile and -LogFile
# through winify_path, which rewrites only /<drive>/ prefixes. The sampler dir
# lives under File::Spec->tmpdir(), which is /tmp under MSYS, so powershell.exe
# got a bare /tmp/... and Windows resolved it to C:\tmp\..., a directory that
# does not exist. The helper could not write its pidfile and exited; the
# launcher's revive respawned it once a minute (667 times in one launch), each
# respawn a hidden powershell.exe, and the operator's terminal kept minimizing.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use MountSpec qw(winify_path native_path);

my $launcher = "$Bin/../../scripts/launcher.pl";
open(my $fh, '<', $launcher) or die "read $launcher: $!";
my $src = do { local $/; <$fh> };
close $fh;

# The keep-awake spawn translates every path it hands powershell.exe through
# native_path, never winify_path.
my ($start) = $src =~ /(sub _keepawake_start \{.*?\n\})/s;
ok(defined $start, '_keepawake_start found');
like($start, qr/my \$win_ps1 = native_path\(\$ps1\)/,     '-File goes through native_path');
like($start, qr/my \$win_pid = native_path\(\$pidfile\)/, '-PidFile goes through native_path');
like($start, qr/'-LogFile', native_path\(\$logfile\)/,    '-LogFile goes through native_path');
unlike($start, qr/winify_path\(/, 'no winify_path left in the keep-awake spawn');

is(native_path(undef), undef, 'undef passes through');
is(native_path(''),    '',    'empty passes through');

SKIP: {
    skip('native_path is a no-op off the Windows family', 4) unless $MountSpec::WINDOWS_FAMILY;

    is(native_path('/c/Users/foo'), winify_path('/c/Users/foo'),
       'a /<drive>/ path translates exactly as winify_path does');
    is(native_path('C:/already'), 'C:/already', 'an already-native path is left alone');

    # A real directory under the MSYS temp mount: the translated form must be a
    # drive path, and must name the same directory.
    my $d = tempdir(DIR => File::Spec->tmpdir(), CLEANUP => 1);
    open(my $o, '>', "$d/probe.txt") or die "write probe: $!";
    print {$o} "x\n";
    close $o;
    my $n = native_path("$d/probe.txt");
    like($n, qr{^[A-Za-z]:/}, "a temp-mount path becomes a drive path ($n)");
    my $back = `cygpath -u "$n"`;
    chomp $back;
    ok(-e $back && -s $back == 2, 'the translated path names the same file');
}

done_testing();
