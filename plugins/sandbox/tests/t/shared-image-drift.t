#!/usr/bin/env perl
# platform: any
# A project that never built must still notice a shared image built from an older Containerfile.
#
# Bug report 20261029-100635-e6a7 (acxpraxis): after the shared Containerfile moved from Debian 12
# to Debian 13, a NEW project's first launch printed "claude-sandbox:latest already built" and
# created its container from the two-week-old Debian 12 image. Containerfile drift was judged only
# from $LAUNCHER_DIR/containerfile-hash, which is per project, and a project with no record skips
# the check. The fix stamps the build-input hash on the image as a label at every build site and
# compares that label on every launch.
#
# AC1  image_inputs_hash covers the Containerfile and heartbeat.sh, and equals the old launcher
#      algorithm (so existing per-project records do not all read as drift at once)
# AC2  shared_image_stale_reason, driven through every (label x record) state
# AC3  both build sites (launcher build_image, bootstrap) stamp the label
# AC4  the launcher runs the check for every project with an image, record or not
#
# No podman, no launcher spawn: pure functions plus source text.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Digest::MD5 ();
use Test::More;
use lib "$Bin/../../scripts";
use SandboxIdentity ();

sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $c = <$fh>; close $fh; $c }
sub spew  { my ($p, $c) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print $fh $c; close $fh }

# --- AC1 -------------------------------------------------------------------------------------------
{
    my $d = tempdir(CLEANUP => 1);
    spew("$d/Containerfile", "FROM debian:13\n");
    spew("$d/heartbeat.sh", "#!/bin/sh\n");
    my $h0 = SandboxIdentity::image_inputs_hash($d);
    like($h0, qr/\A[0-9a-f]{32}\z/, 'AC1 the hash is md5 hex');

    my $old = Digest::MD5::md5_hex(
        Digest::MD5::md5_hex("FROM debian:13\n") . ':' . Digest::MD5::md5_hex("#!/bin/sh\n"));
    is($h0, $old, 'AC1 same value the launcher recorded before the move (no mass false drift)');

    spew("$d/Containerfile", "FROM debian:12\n");
    isnt(SandboxIdentity::image_inputs_hash($d), $h0, 'AC1 a Containerfile edit changes the hash');
    spew("$d/Containerfile", "FROM debian:13\n");
    is(SandboxIdentity::image_inputs_hash($d), $h0, 'AC1 and is stable for the same inputs');
    spew("$d/heartbeat.sh", "#!/bin/sh\nexit 0\n");
    isnt(SandboxIdentity::image_inputs_hash($d), $h0, 'AC1 a heartbeat.sh edit changes the hash');
    unlink "$d/heartbeat.sh";
    my $absent = Digest::MD5::md5_hex(Digest::MD5::md5_hex("FROM debian:13\n") . ':absent');
    is(SandboxIdentity::image_inputs_hash($d), $absent, 'AC1 a missing heartbeat.sh hashes as absent');

    is(SandboxIdentity::image_inputs_label(), 'ccpraxis.containerfile-hash', 'AC1 label name');
}

# --- AC2 -------------------------------------------------------------------------------------------
my $LAUNCHER = "$Bin/../../scripts/launcher.pl";
my $SRC = slurp($LAUNCHER);
ok(defined $SRC, 'precondition: launcher.pl readable') or do { done_testing(); exit };
my ($sub) = $SRC =~ /(sub\s+shared_image_stale_reason\s*\{.*?\n\})/s;
ok(defined $sub, 'precondition: shared_image_stale_reason is extractable') or do { done_testing(); exit };
my $ok = eval "package SharedImageDriftUnderTest;\nuse strict;\nuse warnings;\n$sub\n1;\n";  ## no critic
ok($ok, 'precondition: shared_image_stale_reason compiles on its own') or diag($@);
*reason = \&SharedImageDriftUnderTest::shared_image_stale_reason;

my ($img, $cur) = ('claude-sandbox:latest', 'a' x 32);
for my $rec (0, 1) {
    is(reason($img, $cur, $cur, $rec), undef, "AC2 label == current: not stale (record=$rec)");
    like(reason($img, 'b' x 32, $cur, $rec) // '', qr/built from an older Containerfile/,
         "AC2 label != current: stale (record=$rec) -- THE REPORTED CASE when record=0");
    is(reason($img, undef, $cur, $rec), undef, "AC2 podman could not answer: never stale (record=$rec)");
}
like(reason($img, '', $cur, 0) // '', qr/predates build-input tracking/,
     'AC2 unlabelled image, no project record: stale (inputs unknown, nothing vouches)');
is(reason($img, '', $cur, 1), undef,
   'AC2 unlabelled image, project has a record: left to the per-project check');
is(reason($img, 'b' x 32, '', 0), undef, 'AC2 no current hash: cannot judge');

# --- AC3 -------------------------------------------------------------------------------------------
{
    my ($build) = $SRC =~ /(sub\s+build_image\s*\{.*?\n\})/s;
    like($build // '', qr/'--label',\s*SandboxIdentity::image_inputs_label\(\)\s*\.\s*'='\s*\.\s*containerfile_hash\(\)/,
         'AC3 the launcher build stamps the label');
    like($SRC, qr/sub\s+containerfile_hash\s*\{[^}]*SandboxIdentity::image_inputs_hash\(\$CONTAINER_CONFIG\)/s,
         'AC3 the launcher hashes with the shared function (one algorithm for both build sites)');

    my $boot = slurp("$Bin/../../scripts/bootstrap.pl");
    my ($bbuild) = ($boot // '') =~ /(system\(\$PODMAN,\s*'build',.*?\);)/s;
    like($bbuild // '', qr/'--label',\s*SandboxIdentity::image_inputs_label\(\)\s*\.\s*'='\s*\.\s*SandboxIdentity::image_inputs_hash\(\$CONTAINER_CONFIG\)/s,
         'AC3 the bootstrap build stamps the same label');
}

# --- AC4 -------------------------------------------------------------------------------------------
{
    my ($block) = $SRC =~ /(if \(\$IMAGE_EXISTS\) \{\n    my \$label = image_inputs_label_of\(\$IMAGE_LATEST\);.*?\n\})/s;
    ok(defined $block, 'AC4 the shared-image check runs whenever the image exists');
    unlike($block // '', qr/_container_exists|CONTAINER_EXISTS_NOW/,
           'AC4 it does not depend on this project having a container');
    like($block // '', qr/push \@STALE_REASONS/, 'AC4 a stale image becomes a rebuild-prompt reason');
    my ($fmt) = $SRC =~ /sub\s+image_inputs_label_of\s*\{.*?my \$fmt = '([^']*)'/s;
    like($fmt // '', qr/\.Config\.Labels/, 'AC4 the label is read from .Config.Labels (podman and docker both have it)');
}

done_testing();
