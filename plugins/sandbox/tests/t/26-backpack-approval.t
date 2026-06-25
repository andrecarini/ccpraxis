#!/usr/bin/env perl
# BackpackApproval.pm — per-item, machine-local approval memory for backpack
# items (the launcher's root-command install gate, #21).
#
#   identity + content-hash    -> unchanged items never re-prompt; changed re-prompt
#   partition                  -> approved vs pending (only pending gets reviewed)
#   approve / forget / prune   -> mutate the store
#   load / save                -> machine-local JSON store, fail-safe on corruption
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);

use_ok('BackpackApproval') or BAIL_OUT('BackpackApproval.pm did not load');


# ---- identity + hashing ---------------------------------------------------
my %item = (category => 'apt', name => 'chromium',
            install => 'apt-get install -y chromium',
            verify  => 'command -v chromium',
            version => '149', rationale => 'browser for e2e');

is(BackpackApproval::item_key(\%item), 'apt:chromium', 'item_key: category:name');
is(BackpackApproval::item_key({}),     ':',            'item_key: empty fields tolerated');

my $h = BackpackApproval::item_hash(\%item);
is(BackpackApproval::item_hash(\%item), $h, 'item_hash: stable for identical content');

# rationale is NOT part of the fingerprint (prose, never executed)
is(BackpackApproval::item_hash({ %item, rationale => 'totally different reason' }), $h,
    'item_hash: editing rationale does NOT change the hash');

# editing an executed field DOES change the hash
isnt(BackpackApproval::item_hash({ %item, install => 'apt-get install -y evil' }), $h,
    'item_hash: editing install changes the hash');
isnt(BackpackApproval::item_hash({ %item, verify  => 'true' }), $h,
    'item_hash: editing verify changes the hash');
is(BackpackApproval::item_hash({ %item, version => '150' }), $h,
    'item_hash: a legacy/stray version field is ignored (removed from schema) - NOT hashed');

# ---- is_approved ----------------------------------------------------------
my %appr = ( 'apt:chromium' => $h );
ok(BackpackApproval::is_approved(\%item, \%appr), 'is_approved: key + matching hash -> approved');
ok(!BackpackApproval::is_approved(\%item, {}), 'is_approved: empty store -> pending');
ok(!BackpackApproval::is_approved({ %item, install => 'apt-get install -y evil' }, \%appr),
    'is_approved: changed command -> pending (re-review), NOT auto-approved');
ok(!BackpackApproval::is_approved({ category => 'apt', name => 'newpkg' }, \%appr),
    'is_approved: unknown item -> pending');

# ---- partition ------------------------------------------------------------
my @items = (
    { category => 'apt',  name => 'chromium', install => 'i1', verify => 'v1' },
    { category => 'apt',  name => 'newpkg',   install => 'i2', verify => 'v2' },
    { category => 'curl-script', name => 'node', install => 'i3', verify => 'v3' },
);
my $store = {};
BackpackApproval::approve($items[0], $store);   # pre-approve the first
BackpackApproval::approve($items[2], $store);   # and the third
my ($ok, $pending) = BackpackApproval::partition(\@items, $store);
is(scalar(@$ok), 2,      'partition: two approved');
is(scalar(@$pending), 1, 'partition: one pending');
is($pending->[0]{name}, 'newpkg', 'partition: the un-approved item is pending');
# order preserved among approved
is($ok->[0]{name}, 'chromium', 'partition: approved order preserved');

# ---- approve / forget / prune --------------------------------------------
my %s2 = ();
BackpackApproval::approve($items[0], \%s2);
ok(BackpackApproval::is_approved($items[0], \%s2), 'approve: records the item');
BackpackApproval::forget($items[0], \%s2);
ok(!BackpackApproval::is_approved($items[0], \%s2), 'forget: drops the item');

my %s3 = ();
BackpackApproval::approve($_, \%s3) for @items;          # approve all three
my $gone = BackpackApproval::prune(\%s3, [ @items[0,1] ]); # item[2] no longer in backpack
is($gone, 1, 'prune: drops approvals for vanished items');
ok(!exists $s3{'curl-script:node'}, 'prune: vanished item removed from store');
ok(exists $s3{'apt:chromium'},      'prune: surviving items kept');

# ---- load / save round-trip ----------------------------------------------
my $dir  = tempdir(CLEANUP => 1);
my $path = "$dir/backpack-approvals.json";
is_deeply(BackpackApproval::load($path), {}, 'load: missing file -> empty (fail-safe)');

my %tosave = ('apt:chromium' => $h, 'apt:jq' => 'deadbeef');
ok(BackpackApproval::save($path, \%tosave), 'save: writes the store');
is_deeply(BackpackApproval::load($path), \%tosave, 'load: round-trips the saved store');

# corrupt file -> empty (re-review rather than trust garbage)
open my $cf, '>', $path or die; print $cf "{not valid json"; close $cf;
is_deeply(BackpackApproval::load($path), {}, 'load: corrupt file -> empty (fail-safe)');

# overwrite an existing store (Windows rename-clobber path)
ok(BackpackApproval::save($path, { 'apt:only' => 'x' }), 'save: overwrites an existing store');
is_deeply(BackpackApproval::load($path), { 'apt:only' => 'x' }, 'save: overwrite took effect');

done_testing();
