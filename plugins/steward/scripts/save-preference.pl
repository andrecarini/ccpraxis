#!/usr/bin/perl
# Save or remove a backup sync preference.
#
# Usage:
#   perl save-preference.pl --prefs FILE --scope SCOPE --key KEY --category CAT --action ACTION
#   perl save-preference.pl --prefs FILE --scope SCOPE --remove KEY
#
# Valid category/action pairs:
#   diverged   / skip-always   — intentionally different between sources
#   only_left  / left-only     — intentionally absent from right source
#   only_right / right-only    — intentionally absent from left source
#
# Creates the preferences file if it doesn't exist.
# Exit codes: 0 = success, 2 = usage/validation error
use strict;
use warnings;
use JSON::PP;
use Getopt::Long;
use Encode ();

my ($prefs_file, $scope, $key, $category, $action, $remove);
GetOptions(
    'prefs=s'    => \$prefs_file,
    'scope=s'    => \$scope,
    'key=s'      => \$key,
    'category=s' => \$category,
    'action=s'   => \$action,
    'remove=s'   => \$remove,
) or exit 2;

unless ($prefs_file && $scope && ($key || $remove)) {
    print STDERR "Usage: $0 --prefs FILE --scope SCOPE --key KEY --category CAT --action ACTION\n";
    print STDERR "       $0 --prefs FILE --scope SCOPE --remove KEY\n";
    exit 2;
}

# The file is UTF-8 JSON (decode_json reads it as such, and so do
# filter-diff.pl and promote.pl), so it is written with ->utf8, and the names
# given on the command line -- UTF-8 bytes -- are decoded to text first.
# Without both, a non-ASCII key ("café") was written as bytes next to the
# decoded text of the keys already in the file: the next save re-encoded it,
# the one after that could not parse the file, and every backup then failed
# in filter-diff.pl.
my $pretty = JSON::PP->new->utf8->pretty->canonical;
my ($scope_b, $key_b, $remove_b) = ($scope, $key, $remove);   # bytes, for messages
for my $v ($scope, $key, $remove) {
    next unless defined $v && !utf8::is_utf8($v);
    my $copy = $v;
    my $text = eval { Encode::decode('UTF-8', $copy, Encode::FB_CROAK()) };
    $v = $text if defined $text;
}

# Read existing preferences
my $prefs = {};
if (-f $prefs_file) {
    open my $fh, '<', $prefs_file or do { print STDERR "Cannot open $prefs_file: $!\n"; exit 2 };
    local $/;
    $prefs = decode_json(<$fh>);
    close $fh;
}

if ($remove) {
    if (exists $prefs->{$scope} && exists $prefs->{$scope}{$remove}) {
        delete $prefs->{$scope}{$remove};
        # Clean up empty scope
        delete $prefs->{$scope} unless %{$prefs->{$scope}};
        print "Removed preference: $scope_b / $remove_b\n";
    } else {
        print "No saved preference for: $scope_b / $remove_b\n";
    }
} else {
    # Validate category/action combination
    my %valid = (
        diverged   => ['skip-always'],
        only_left  => ['left-only'],
        only_right => ['right-only'],
    );

    unless ($category && $action) {
        print STDERR "Both --category and --action are required when saving.\n";
        exit 2;
    }

    unless (exists $valid{$category} && grep { $_ eq $action } @{$valid{$category}}) {
        print STDERR "Invalid category/action: $category / $action\n";
        print STDERR "Valid: diverged/skip-always, only_left/left-only, only_right/right-only\n";
        exit 2;
    }

    $prefs->{$scope} ||= {};
    $prefs->{$scope}{$key} = { category => $category, action => $action };
    print "Saved preference: $scope_b / $key_b = $action ($category)\n";
}

# Write back
open my $fh, '>:raw', $prefs_file or do { print STDERR "Cannot write $prefs_file: $!\n"; exit 2 };
print $fh $pretty->encode($prefs);
close $fh;

exit 0;
