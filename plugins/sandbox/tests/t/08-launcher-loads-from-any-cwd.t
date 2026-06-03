#!/usr/bin/env perl
# Regression: launcher.pl must resolve its own scripts/ dir to find
# MountSpec.pm regardless of the caller's CWD. The .ps1 shim invokes
# perl from whatever shell the user is in (typically a project dir);
# FindBin::$Bin was unreliable in that path on cygwin perl with a
# Windows-style $0 and pointed at the CWD instead, breaking the very
# first `use MountSpec` with "Can't locate MountSpec.pm". The fix
# anchors via `dirname(abs_path(__FILE__))` — this test pins it.

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Basename qw(dirname);

plan tests => 3;

my $launcher = "$Bin/../../scripts/launcher.pl";
ok(-f $launcher, 'launcher.pl is where the test expects') or BAIL_OUT;

# Probe 1: POSIX-style path. This is what the .sh shim and most test
# harnesses pass.
{
    my $isolated_cwd = tempdir(CLEANUP => 1);
    my $cmd = sprintf('cd %s && "%s" -c "%s" 2>&1',
                      $isolated_cwd, $^X, $launcher);
    my $output = `$cmd`;
    is($? >> 8, 0, 'POSIX-style path: launcher.pl `perl -c` succeeds from unrelated CWD')
        or diag("output: $output");
}

# Probe 2: Windows-style path with drive letter (`C:/...`) — what the
# .ps1 shim ACTUALLY passes when the user runs `claude-sandbox` from
# PowerShell. This is the path shape that broke production: cygwin
# perl's Cwd::abs_path didn't recognise `C:/...` as absolute, prepended
# CWD, and produced `/cwd/C:/path/...` garbage in @INC.
SKIP: {
    skip "windows-style path shape only applies on Windows", 1
        unless $^O =~ /^(MSWin32|cygwin|msys)$/;
    my $winify = sub {
        my $p = shift;
        $p =~ s|^/([a-zA-Z])/|uc($1) . ":/"|e;
        return $p;
    };
    my $win_launcher = $winify->($launcher);
    my $isolated_cwd = tempdir(CLEANUP => 1);
    my $cmd = sprintf('cd %s && "%s" -c "%s" 2>&1',
                      $isolated_cwd, $^X, $win_launcher);
    my $output = `$cmd`;
    is($? >> 8, 0,
       "Windows-style path: launcher.pl `perl -c $win_launcher` succeeds")
        or diag("output: $output");
}
