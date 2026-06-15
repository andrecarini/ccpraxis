#!/usr/bin/env perl
# All three perl entry points (launcher.pl, bootstrap.pl, TestSandbox.pm)
# ship the same docker-or-podman detection helper. This test confirms:
#   - the detector picks SOMETHING on a host where one of them is installed
#     (we just verified TestSandbox.pm imported successfully, which means
#     its detection succeeded — so we're running on a viable host);
#   - the detected binary actually responds to `--version`;
#   - the same detection shape is present in all three files, so adding a
#     third runtime (e.g. nerdctl) is one-place-to-edit.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use TestSandbox qw(podman_bin);

plan tests => 5;

# 1. TestSandbox detected a CLI.
my $cli = podman_bin();
ok(defined $cli && length $cli, 'TestSandbox detected a container CLI');

# 2. The detected CLI responds to --version (sanity check on the detection result).
my $rc = system("$cli --version > /dev/null 2>&1");
is($rc, 0, "detected CLI ($cli) responds to --version");

# 3-5. Same detection shape in all three scripts.
for my $file (
    ['launcher.pl',     "$Bin/../../scripts/launcher.pl"],
    ['bootstrap.pl',    "$Bin/../../scripts/bootstrap.pl"],
    ['TestSandbox.pm',  "$Bin/../lib/TestSandbox.pm"],
) {
    my ($name, $path) = @$file;
    open my $fh, '<', $path or do { fail("open $name: $!"); next };
    my $src = do { local $/; <$fh> };
    close $fh;
    like($src, qr/_detect_container_cli/,
         "$name uses the shared _detect_container_cli pattern");
}
