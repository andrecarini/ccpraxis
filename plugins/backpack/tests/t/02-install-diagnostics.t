#!/usr/bin/env perl
# When a backpack item installs but its post-install verify fails, the install
# pass must surface WHY — not just the verify command (which is usually
# self-silencing, e.g. `… 2>/dev/null | grep -q …`). cmd_install re-runs the
# failed verify under `bash -x` and echoes a bounded trace. This is the fix for
# the real flutter case: its verify's `head -1 | grep "^Flutter <ver>"` was
# defeated by flutter's first-run banner, and the old report showed only the
# command, not the cause.

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);

my $BP = "$Bin/../../scripts/backpack.pl";
ok(-f $BP, 'backpack.pl exists') or BAIL_OUT("script missing");

# install/verify (and the diagnostic) run through bash; skip where it's absent.
unless (system('bash -c "exit 0" >/dev/null 2>&1') == 0) {
    plan skip_all => 'bash not available on this host';
}

my $dir = tempdir(CLEANUP => 1);

# An item whose install succeeds (`true`) but whose verify always fails
# (`command -v <missing>`), so cmd_install reaches the verify-after-install
# failure path and must emit the diagnostic.
my $json = "$dir/backpack.json";
open my $w, '>', $json or die "write $json: $!";
print $w '{"version":2,"items":[{"category":"other","name":"diagtest",'
       . '"install":"true","verify":"command -v __no_such_bin_zzzqqq__"}]}';
close $w;

my $out = `"$^X" "$BP" install "$json" 2>&1`;
my $rc  = $? >> 8;

like($out, qr/INSTALL: other:diagtest/,   'install runs (pre-verify failed by design)');
like($out, qr/verify after install/,      'reports a post-install verify failure');
like($out, qr/why \(bash -x/,             'emits the new bash -x diagnostic block');
like($out, qr/\+ command -v __no_such_bin_zzzqqq__/,
     'diagnostic shows the traced failing command (the "why")');
is($rc, 1, 'install exits 1 when an item fails');

# Control: an item whose verify passes must NOT emit the diagnostic noise.
my $ok = "$dir/ok.json";
open my $w2, '>', $ok or die "write $ok: $!";
print $w2 '{"version":2,"items":[{"category":"other","name":"oktest",'
        . '"install":"true","verify":"true"}]}';
close $w2;

my $out2 = `"$^X" "$BP" install "$ok" 2>&1`;
my $rc2  = $? >> 8;

unlike($out2, qr/why \(bash -x/, 'no diagnostic when the verify passes');
is($rc2, 0, 'install exits 0 when all items pass');

done_testing();
