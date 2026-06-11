#!/usr/bin/perl
# Check plugin installation status against config.
# Compares enabledPlugins in settings with installed_plugins.json and
# verifies that required marketplaces are registered.
#
# Usage: perl check-plugins.pl [--settings FILE] [--installed FILE] [--marketplaces FILE]
#
# All arguments are optional — missing files are treated as empty.
#
# Exit codes: 0 = all enabled plugins installed, 1 = some missing, 2 = error
use strict;
use warnings;
use JSON::PP;
use Getopt::Long;

my ($settings_file, $installed_file, $marketplaces_file);
GetOptions(
    'settings=s'     => \$settings_file,
    'installed=s'    => \$installed_file,
    'marketplaces=s' => \$marketplaces_file,
) or exit 2;

my $pretty = JSON::PP->new->pretty->canonical;

sub read_json_file {
    my $path = shift;
    return undef unless defined $path && -f $path;
    open my $fh, '<', $path or return undef;
    local $/;
    my $data = eval { decode_json(<$fh>) };
    return $data;
}

# Read enabledPlugins from settings
my $settings = read_json_file($settings_file);
my $enabled_plugins = $settings ? ($settings->{enabledPlugins} || {}) : {};
my @enabled_keys = sort grep { $enabled_plugins->{$_} } keys %$enabled_plugins;

unless (@enabled_keys) {
    print $pretty->encode({ status => "no_config", enabled => [], missing => [],
                            missing_marketplaces => [], extra_installed => [] });
    exit 0;
}

# Read installed plugins
my $installed_data = read_json_file($installed_file);
if ($installed_data && (!ref($installed_data) || ref($installed_data) ne 'HASH' || !exists $installed_data->{plugins})) {
    print STDERR "Warning: $installed_file has unexpected schema (expected {plugins: {...}}). Treating as empty.\n";
    $installed_data = undef;
}
my %installed = map { $_ => 1 } keys %{ ($installed_data || {})->{plugins} || {} };

# Read known marketplaces
my $marketplaces_data = read_json_file($marketplaces_file);
my %marketplaces = $marketplaces_data ? (map { $_ => 1 } keys %$marketplaces_data) : ();

# Classify each enabled plugin
my (@ok, @missing, @missing_mp);
for my $key (@enabled_keys) {
    my ($name, $mp) = split /@/, $key, 2;
    my $is_installed   = $installed{$key} ? JSON::PP::true : JSON::PP::false;
    my $mp_registered  = $marketplaces{$mp // ''} ? JSON::PP::true : JSON::PP::false;
    my $entry = {
        plugin               => $key,
        name                 => $name,
        marketplace          => $mp // '',
        installed            => $is_installed,
        marketplace_registered => $mp_registered,
    };
    if ($installed{$key})          { push @ok, $entry }
    elsif (!$marketplaces{$mp // ''}) { push @missing_mp, $entry }
    else                           { push @missing, $entry }
}

# Find extra installed plugins not in enabledPlugins
my @extra;
for my $key (sort keys %installed) {
    next if $enabled_plugins->{$key};
    push @extra, { plugin => $key, note => "installed locally but not in enabledPlugins config" };
}

my $has_missing = @missing || @missing_mp;
print $pretty->encode({
    status               => $has_missing ? "missing_plugins" : "ok",
    enabled              => \@ok,
    missing              => \@missing,
    missing_marketplaces => \@missing_mp,
    extra_installed      => \@extra,
});

exit($has_missing ? 1 : 0);
