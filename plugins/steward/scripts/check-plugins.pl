#!/usr/bin/perl
# Check plugin installation status against config.
# Compares enabledPlugins in settings with installed_plugins.json and
# verifies that required marketplaces are registered. A plugin served in
# place from a directory-source marketplace counts as available even
# without an installed_plugins.json entry (spec 17, section 1.2/2.1).
#
# Usage: perl check-plugins.pl [--settings FILE] [--installed FILE] [--marketplaces FILE] [--project DIR]
#
# All arguments are optional — missing files are treated as empty.
#
# Exit codes: 0 = all enabled plugins installed, 1 = some missing, 2 = error
use strict;
use warnings;
use JSON::PP;
use Getopt::Long;
use Encode ();
use B ();

my ($settings_file, $installed_file, $marketplaces_file, $project_dir);
GetOptions(
    'settings=s'     => \$settings_file,
    'installed=s'    => \$installed_file,
    'marketplaces=s' => \$marketplaces_file,
    'project=s'      => \$project_dir,
) or exit 2;

my $pretty = JSON::PP->new->pretty->canonical->space_before(0)->space_after(0);

sub read_json_file {
    my $path = shift;
    return undef unless defined $path && -f $path;
    open my $fh, '<', $path or return undef;
    local $/;
    my $data = eval { decode_json(<$fh>) };
    return $data;
}

# ===========================================================================
# norm / same_path -- spec 2.1 path normalisation for the install-record
# project-scope rule.
# ===========================================================================
sub _to_bytes {
    my ($s) = @_;
    return $s unless defined $s;
    return Encode::encode('UTF-8', $s) if utf8::is_utf8($s);
    return $s;
}

sub norm_path {
    my ($p) = @_;
    return '' unless defined $p;
    $p = _to_bytes($p);
    $p =~ s{\\}{/}g;
    if ($^O =~ /^(MSWin32|msys|cygwin)$/) {
        $p =~ s{^/([A-Za-z])(?=/|\z)}{$1:};
    }
    $p =~ s{(?<=.)/+\z}{};
    return $p;
}

sub same_path {
    my ($path1, $path2) = @_;
    my $A = norm_path($path1);
    my $B = norm_path($path2);
    if ($A =~ m{^[A-Za-z]:(?:/|\z)} && $B =~ m{^[A-Za-z]:(?:/|\z)}) {
        return lc($A) eq lc($B);
    }
    return $A eq $B;
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
my %installed_raw = %{ ($installed_data || {})->{plugins} || {} };

# ===========================================================================
# counts_as_installed -- spec 2.1 install-record rule: at least one array
# element (a hash) whose scope qualifies.
# ===========================================================================
sub counts_as_installed {
    my ($entries, $project) = @_;
    return 0 unless ref($entries) eq 'ARRAY';
    for my $e (@$entries) {
        next unless ref($e) eq 'HASH';
        my $scope = $e->{scope};
        next unless defined $scope;
        if ($scope eq 'user' || $scope eq 'managed') {
            return 1;
        }
        elsif ($scope eq 'project' || $scope eq 'local') {
            next unless defined $project && length $project;
            my $pp = $e->{projectPath};
            next unless defined $pp && !ref($pp) && length $pp;
            return 1 if same_path($pp, $project);
        }
    }
    return 0;
}

my %installed;
for my $key (keys %installed_raw) {
    $installed{$key} = counts_as_installed($installed_raw{$key}, $project_dir) ? 1 : 0;
}

# Read known marketplaces
my $marketplaces_data = read_json_file($marketplaces_file);
my %marketplaces = $marketplaces_data ? %$marketplaces_data : ();

# ===========================================================================
# served_in_place -- spec 2.1 served-in-place rule for a directory-source
# marketplace. Any failure means "not served in place"; never dies/warns.
# ===========================================================================
my %marketplace_catalog_cache;

# True only for a genuine JSON number: decode_json sets IOK/NOK on numbers
# but not POK, while a numeric-looking *string* carries POK. Claude Code's
# loader requires typeof source === "string", so a genuine number must be
# rejected even though it is a non-ref defined scalar.
sub _is_json_number {
    my $f = B::svref_2object(\$_[0])->FLAGS;
    return (($f & (B::SVf_IOK | B::SVf_NOK)) && !($f & B::SVf_POK)) ? 1 : 0;
}

sub is_absolute_path {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    return 1 if $p =~ m{^[A-Za-z]:[\\/]};
    return 1 if $p =~ m{^\\\\};
    if ($^O =~ /^(MSWin32|msys|cygwin)$/) {
        return 0;
    }
    return 1 if $p =~ m{^/};
    return 0;
}

sub load_marketplace_catalog {
    my ($path) = @_;
    return $marketplace_catalog_cache{$path} if exists $marketplace_catalog_cache{$path};
    my $catalog_path = "$path/.claude-plugin/marketplace.json";
    my $data = eval { read_json_file($catalog_path) };
    $marketplace_catalog_cache{$path} = $data;
    return $data;
}

sub served_in_place {
    my ($name, $mp) = @_;
    return 0 unless defined $mp && length $mp;
    my $mp_entry = $marketplaces{$mp};
    return 0 unless ref($mp_entry) eq 'HASH';
    my $src = $mp_entry->{source};
    return 0 unless ref($src) eq 'HASH';
    return 0 unless defined $src->{source} && $src->{source} eq 'directory';
    my $path = $src->{path};
    return 0 unless defined $path && !ref($path) && length $path;
    # Check absoluteness against the normalised form (norm_path), not the
    # raw bytes: on MSYS/cygwin perl a real Windows absolute path arrives
    # here as "/c/foo" (host-perl convention, not a bare POSIX path), and
    # norm_path already knows how to turn that into "c:/foo" for the
    # drive-letter check below. A genuine bare "/foo" (no drive segment)
    # stays bare and is correctly rejected, matching Claude Code's own X6
    # check, which requires a drive letter or UNC prefix on Windows.
    return 0 unless is_absolute_path(norm_path($path));

    my $catalog = load_marketplace_catalog($path);
    return 0 unless ref($catalog) eq 'HASH';
    return 0 unless ref($catalog->{plugins}) eq 'ARRAY';

    for my $p (@{ $catalog->{plugins} }) {
        next unless ref($p) eq 'HASH';
        next unless defined $p->{name} && $p->{name} eq $name;
        my $psrc = $p->{source};
        return 1 if defined $psrc && !ref($psrc) && length($psrc) && !_is_json_number($psrc);
        return 0;
    }
    return 0;
}

# Classify each enabled plugin
my (@ok, @missing, @missing_mp);
for my $key (@enabled_keys) {
    my ($name, $mp) = split /@/, $key, 2;
    my $has_record     = $installed{$key} ? 1 : 0;
    my $mp_registered  = exists($marketplaces{$mp // ''}) ? 1 : 0;
    my $sip            = served_in_place($name, $mp) ? 1 : 0;
    my $entry = {
        plugin               => $key,
        name                 => $name,
        marketplace          => $mp // '',
        installed            => $has_record ? JSON::PP::true : JSON::PP::false,
        marketplace_registered => $mp_registered ? JSON::PP::true : JSON::PP::false,
        served_in_place      => $sip ? JSON::PP::true : JSON::PP::false,
    };
    if ($has_record || $sip)       { push @ok, $entry }
    elsif (!$mp_registered)        { push @missing_mp, $entry }
    else                           { push @missing, $entry }
}

# Find extra installed plugins not in enabledPlugins (over the counting set).
my @extra;
for my $key (sort keys %installed) {
    next unless $installed{$key};
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
