#!/usr/bin/env perl
# platform: any
# Bug 20261014-131539-49bb: the continuity, inbox and drive-solo skills tell
# agents to run a bare `almanac <store> <verb>`, and butler's ticket hook
# (BpHook/ContinuityOffCheck.pm) matches that bare form -- but no `almanac`
# command existed, so it failed with exit 127. Claude Code puts each enabled
# plugin's bin/ on PATH; this pins the shim that makes the bare form real.
#
# Only read-only, store-free calls are made (a usage error and a verb list),
# so nothing here can touch a real almanac store.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);

my $PLUGIN = "$Bin/../..";
my $SHIM   = "$PLUGIN/bin/almanac";

ok(-f $SHIM, 'plugins/almanac/bin/almanac exists');

open my $fh, '<', $SHIM or BAIL_OUT("cannot read $SHIM: $!");
my $first = <$fh>;
my $body  = do { local $/; <$fh> };
close $fh;
like($first, qr{^#!/bin/bash\s*$}, 'shim has a bash shebang');
like($body, qr{\.\./scripts/almanac\.pl}, 'shim execs ../scripts/almanac.pl, not a copy of its logic');
unlike($first . $body, qr{\r}, 'shim has LF line endings (CRLF breaks the shebang)');

# The git index must carry the executable bit, or a fresh clone on Linux/macOS
# (and the sandbox) gets a shim PATH lookup skips.
my $mode = `git -C "$PLUGIN" ls-files -s -- bin/almanac 2>/dev/null`;
SKIP: {
    skip 'not a git checkout, or shim not yet staged', 1 unless defined $mode && length $mode;
    like($mode, qr/^100755 /, 'git records bin/almanac as executable (100755)');
}

# Run through bash, as the PATH lookup would, from a temp cwd so no project
# store is in reach. `almanac inbox` with no verb is a usage error that lists
# the verbs -- proof the dispatcher, not the shim, answered.
my $tmp = tempdir(CLEANUP => 1);
local $ENV{HOME} = $tmp;
local $ENV{ALMANAC_HOME} = $tmp;
delete local $ENV{CLAUDE_PROJECT_DIR};
my $out = `cd "$tmp" && bash "$SHIM" inbox 2>&1`;
my $rc  = $? >> 8;
isnt($rc, 127, 'shim does not fail with command-not-found');
like($out, qr/almanac inbox verbs: .*\bfile\b/, 'dispatcher answered with the inbox verb list');

done_testing();
