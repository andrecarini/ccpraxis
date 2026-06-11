#!/usr/bin/perl
# Filter json-diff.pl output through saved backup preferences.
#
# Usage: perl json-diff.pl left.json right.json | perl filter-diff.pl --prefs FILE --scope SCOPE
#
# Reads a json-diff report from stdin and a preferences file.
# Keys with matching saved preferences (same category) are auto-applied.
# Keys without preferences or with a category mismatch are in needs_decision.
#
# Output: JSON with auto_applied (list) and needs_decision (object with
#         only_left, only_right, diverged sub-objects).
#
# Exit codes: 0 = success, 2 = usage error
use strict;
use warnings;
use JSON::PP;
use Getopt::Long;

my ($prefs_file, $scope);
GetOptions(
    'prefs=s' => \$prefs_file,
    'scope=s' => \$scope,
) or exit 2;

unless ($prefs_file && $scope) {
    print STDERR "Usage: ... | $0 --prefs FILE --scope SCOPE\n";
    exit 2;
}

# ->utf8 makes the encoder emit UTF-8 *bytes* (not wide chars). decode_json /
# Encode::decode below yield utf8-flagged character strings; without ->utf8 here
# the encoder would emit wide chars to a byte-mode STDOUT, triggering
# "Wide character in print" and mangling non-ASCII (e.g. "André" -> "Andr?").
my $pretty = JSON::PP->new->utf8->pretty->canonical;

# Read diff from stdin
my $diff_json = do { local $/; <STDIN> };
# Tolerate invalid UTF-8 bytes (e.g. Latin-1 paths in settings.json from
# tools that wrote files without proper UTF-8 encoding). Fallback path
# substitutes U+FFFD for any malformed byte sequence, allowing the diff
# to proceed instead of hard-failing the whole backup.
my $diff;
eval { $diff = decode_json($diff_json); };
if ($@) {
    require Encode;
    # FB_DEFAULT constant must be imported at runtime (Bareword strict)
    my $fb = Encode::FB_DEFAULT();
    my $clean = Encode::decode('UTF-8', $diff_json, $fb);
    $diff = JSON::PP->new->decode($clean);
}

# If diff is identical, pass through immediately
if ($diff->{status} eq 'identical') {
    print $pretty->encode({
        status       => 'identical',
        auto_applied => [],
        needs_decision => {
            only_left  => {},
            only_right => {},
            diverged   => {},
        },
        has_undecided => JSON::PP::false,
    });
    exit 0;
}

# Read preferences file (empty hash if file doesn't exist)
my $prefs = {};
if (-f $prefs_file) {
    open my $fh, '<', $prefs_file or do { print STDERR "Cannot open $prefs_file: $!\n"; exit 2 };
    local $/;
    my $all_prefs = decode_json(<$fh>);
    $prefs = $all_prefs->{$scope} || {};
}

# Valid action for each category — only these combinations auto-apply
my %valid_action = (
    only_left  => 'left-only',
    only_right => 'right-only',
    diverged   => 'skip-always',
);

my @auto_applied;
my (%nd_only_left, %nd_only_right, %nd_diverged);

# Process only_left keys
for my $key (sort keys %{$diff->{only_left} || {}}) {
    my $saved = $prefs->{$key};
    if ($saved
        && $saved->{category} eq 'only_left'
        && $saved->{action}   eq $valid_action{only_left})
    {
        push @auto_applied, { key => $key, category => 'only_left', action => $saved->{action} };
    } else {
        $nd_only_left{$key} = $diff->{only_left}{$key};
    }
}

# Process only_right keys
for my $key (sort keys %{$diff->{only_right} || {}}) {
    my $saved = $prefs->{$key};
    if ($saved
        && $saved->{category} eq 'only_right'
        && $saved->{action}   eq $valid_action{only_right})
    {
        push @auto_applied, { key => $key, category => 'only_right', action => $saved->{action} };
    } else {
        $nd_only_right{$key} = $diff->{only_right}{$key};
    }
}

# Process diverged keys
for my $key (sort keys %{$diff->{diverged} || {}}) {
    my $saved = $prefs->{$key};
    if ($saved
        && $saved->{category} eq 'diverged'
        && $saved->{action}   eq $valid_action{diverged})
    {
        push @auto_applied, { key => $key, category => 'diverged', action => $saved->{action} };
    } else {
        $nd_diverged{$key} = $diff->{diverged}{$key};
    }
}

my $has_undecided = %nd_only_left || %nd_only_right || %nd_diverged;

print $pretty->encode({
    status         => 'filtered',
    auto_applied   => \@auto_applied,
    needs_decision => {
        only_left  => \%nd_only_left,
        only_right => \%nd_only_right,
        diverged   => \%nd_diverged,
    },
    has_undecided => $has_undecided ? JSON::PP::true : JSON::PP::false,
});

exit 0;
