#!/usr/bin/env perl
# podman-machine.pl -- keep the macOS podman machine rootful and sharing only what the sandbox needs.
#
#   perl podman-machine.pl plan                     current machine next to the desired one
#   perl podman-machine.pl apply [--confirm]        recreate (or create) it to match
#   perl podman-machine.pl add-project <dir> [--confirm]
#   perl podman-machine.pl remove-project <dir> [--confirm]
#   perl podman-machine.pl test-scratch on|off [--confirm]
#
# Nothing changes without --confirm. All logic is in PodmanMachine.pm (next to
# this file), which documents the desired machine, where the share list lives
# and why. darwin only: on Windows and Linux it says so and exits 0.
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use lib dirname(abs_path(__FILE__));
use PodmanMachine ();

binmode STDOUT, ':raw';
binmode STDERR, ':raw';
$| = 1;

exit PodmanMachine::cli(\@ARGV);
