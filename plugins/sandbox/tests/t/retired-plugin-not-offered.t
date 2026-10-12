#!/usr/bin/env perl
# platform: any
# A plugin whose source no longer exists anywhere is not offered by the picker.
#
# WHAT WAS WRONG (bug 20261011-215330-2d26)
#
# `todo` was retired from the ccpraxis marketplace, but Claude Code never
# prunes installed_plugins.json, so its rows (user and project scope) survived.
# discover_plugins() ranks rows by scope and builds an entry from the winner
# without asking whether the plugin's files exist, so the picker kept listing
# `todo` with nothing behind it.
#
# installPath alone is the wrong test: for a directory-source marketplace Claude
# Code never populates the cache dir it records (see host-only-plugin-skills.t
# AC4), so every live ccpraxis plugin has a dead installPath too. The test that
# matches what can actually be mounted is plugin_source_dir(): the installPath
# if it exists, else the marketplace's own source dir.
#
# AC1  a live directory-source plugin with a dead installPath is still offered
# AC2  a plugin dropped from marketplace.json, with no dir, is not offered
# AC3  a plugin still listed in marketplace.json whose dir was deleted is not offered
# AC4  a plugin from a cache-backed marketplace whose installPath exists is offered
# AC5  a plugin from a cache-backed marketplace whose installPath is gone is not offered
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();

my $SKILLS_PL = "$Bin/../../scripts/skills.pl";
ok(-f $SKILLS_PL, 'skills.pl present') or BAIL_OUT('no skills.pl');

my $root = tempdir(CLEANUP => 1);
my $home = "$root/home";
my $mkt  = "$root/marketplace";

sub write_file {
    my ($path, $body) = @_;
    (my $dir = $path) =~ s{/[^/]+$}{};
    make_path($dir) unless -d $dir;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh $body;
    close $fh;
}

sub write_plugin {
    my ($base, $plugin) = @_;
    write_file("$base/.claude-plugin/plugin.json",
               qq({\n  "name": "$plugin",\n  "version": "0.1.0"\n}\n));
    write_file("$base/skills/work/SKILL.md",
               "---\nname: work\ndescription: fixture\n---\n\n# work\n");
}

# Directory-source marketplace: `live` exists; `deleted` is listed but its dir
# is gone; `retired` is in neither the listing nor on disk.
write_plugin("$mkt/live", 'live');
write_file("$mkt/.claude-plugin/marketplace.json", JSON::PP->new->pretty->encode({
    name    => 'fixture-local',
    plugins => [
        { name => 'live',    source => './live'    },
        { name => 'deleted', source => './deleted' },
    ],
}));

# Cache-backed marketplace: Claude Code populated the cache for `cached`; the
# cache dir of `evicted` is gone.
my $cache = "$home/.claude/plugins/cache";
write_plugin("$cache/remote-mkt/cached/1.0.0", 'cached');

write_file("$home/.claude/plugins/known_marketplaces.json", JSON::PP->new->pretty->encode({
    'fixture-local' => { source => { source => 'directory', path => $mkt } },
    'remote-mkt'    => { source => { source => 'github', repo => 'example/remote' },
                         installLocation => "$home/.claude/plugins/marketplaces/remote-mkt" },
}));

my $project = "$root/project";
make_path($project);
my $dead = "$cache/fixture-local";
sub row { return [ { scope => 'user', version => '0.1.0', installPath => $_[0] } ] }
write_file("$home/.claude/plugins/installed_plugins.json", JSON::PP->new->pretty->encode({
    plugins => {
        'live@fixture-local'    => row("$dead/live/0.1.0"),
        'deleted@fixture-local' => row("$dead/deleted/0.1.0"),
        'retired@fixture-local' => row("$dead/retired/0.1.0"),
        'cached@remote-mkt'     => row("$cache/remote-mkt/cached/1.0.0"),
        'evicted@remote-mkt'    => row("$cache/remote-mkt/evicted/1.0.0"),
    },
}));
ok(!-d "$dead/live/0.1.0", 'fixture: the live plugin\'s installPath is dead, as in production');

sub run_skills {
    my (@args) = @_;
    local $ENV{HOME} = $home;
    local $ENV{USERPROFILE} = $home;
    open my $ph, '-|', $^X, $SKILLS_PL, @args or die "spawn: $!";
    local $/;
    my $out = <$ph>;
    close $ph;
    return defined $out ? $out : '';
}

my $raw = run_skills('discover-plugins', '--project-path', $project);
my $found = eval { JSON::PP->new->decode($raw) };
ok(ref $found eq 'ARRAY', 'discover-plugins returned JSON') or diag("raw: $raw");
my %by_key = map { $_->{key} => $_ } @{ $found || [] };

ok(exists $by_key{'live@fixture-local'},
   'AC1 a live directory-source plugin with a dead installPath is offered');
ok(!exists $by_key{'retired@fixture-local'},
   'AC2 a plugin retired from the marketplace is not offered');
ok(!exists $by_key{'deleted@fixture-local'},
   'AC3 a listed plugin whose directory is gone is not offered');
ok(exists $by_key{'cached@remote-mkt'},
   'AC4 a cache-backed plugin whose installPath exists is offered');
ok(!exists $by_key{'evicted@remote-mkt'},
   'AC5 a cache-backed plugin whose installPath is gone is not offered');

done_testing;
