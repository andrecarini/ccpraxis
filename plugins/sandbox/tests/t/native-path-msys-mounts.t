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

# 07-one-keepawake-helper (Decision 19, spec section 7(2)): the real keep-awake
# spawn -- and therefore the native-path translation this file exists to
# guard -- moved out of launcher.pl's own _keepawake_start (DC1 deletes it)
# and into BpKeepAwake::winify/winify_out (bp-keepawake.pl), which carry the
# same 137a741 guarantee restated for the Cygwin::posix_to_win_path rule.
# one-keepawake-helper.t's AC12 now pins that guarantee directly against
# BpKeepAwake; this file keeps only the launcher-side regression guard (the
# sub must be gone) and the native_path unit checks below, which stay in
# scope here regardless of which caller uses them.
unlike($src, qr/\bsub _keepawake_start\b/,
    '_keepawake_start is gone from launcher.pl -- its native-path guarantee now lives in BpKeepAwake (see one-keepawake-helper.t AC12)');

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
