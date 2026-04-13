#!/usr/bin/perl
# Merge settings.json: starts from <existing>, adds only keys missing from <defaults>.
# All existing keys/values are preserved — no overwrites.
# Not run automatically by /backup; available as a manual utility.
#
# Usage: perl merge-settings.pl <existing> <defaults>
# Prints merged JSON to stdout.
use strict;
use warnings;
use JSON::PP;

die "Usage: $0 <existing.json> <defaults.json>\n" unless @ARGV == 2;

my $codec = JSON::PP->new->pretty->canonical;

sub read_json {
    open my $fh, '<', $_[0] or die "Cannot open $_[0]: $!\n";
    local $/;
    return decode_json(<$fh>);
}

my $existing = read_json($ARGV[0]);
my $defaults = read_json($ARGV[1]);

# Start from existing; only add keys from defaults that aren't already present
my $merged = { %$existing };
for my $key (keys %$defaults) {
    $merged->{$key} = $defaults->{$key} unless exists $existing->{$key};
}

print $codec->encode($merged);
