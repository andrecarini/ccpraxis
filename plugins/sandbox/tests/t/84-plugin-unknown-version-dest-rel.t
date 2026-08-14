#!/usr/bin/env perl
# p01-sandbox-plugin-provisioning — AC-9 (maps to done-criterion 6, "a
# marketplace copy that leaves a plugin uncached").
#
# THIS IS A REGRESSION LOCK, NOT A DEFECT-A FIX-CLAIM. spec.md §0 rules
# defect A NOT FIXABLE inside this repo (Claude Code's own runtime resolves
# plugin code into a content-hash-named cache directory this repo cannot
# compute — see scout-step1.md's "Follow-up pass" §3). This test does NOT
# assert "feature-dev is no longer reported not-cached" (that would require a
# live Claude Code runtime and is exactly the kind of "symptom stopped"
# evidence done-criterion 2 forbids). It asserts only the one fact that IS
# testable and IS true today: cmd_materialize_plugins's copy-plan dest_rel
# for a plugin whose host registry `version` is the literal string "unknown"
# (feature-dev's real shape, confirmed live in scout-step1.md) is
# `cache/<marketplace>/<plugin>/unknown` — hand-written here, not derived by
# calling the rewrite logic under test — so that any FUTURE change to this
# naming (e.g. an attempt to work around the address-scheme mismatch by
# renaming the `unknown` segment) is a deliberate, reviewed decision, not an
# accidental one. Per spec.md §2.4, this dest_rel naming is unchanged by this
# package; this test's job is to make an accidental change to it loud.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

BEGIN { $ENV{SANDBOX_SKILLS_NO_DISPATCH} = 1; }
require "$Bin/../../scripts/skills.pl";

plan tests => 4;

my $J = JSON::PP->new->canonical->utf8;
sub spew { my ($p, $c) = @_; my ($d) = $p =~ m{^(.*)/[^/]+$}; make_path($d) if $d && !-d $d;
           open my $f, '>:raw', $p or die "$p: $!"; print $f (ref $c ? $J->encode($c) : $c); close $f; }
sub t_slurp { my $p = shift; open my $f, '<:raw', $p or die "$p: $!"; local $/; $J->decode(<$f>); }

my $dir = tempdir(CLEANUP => 1);

# Host registry: feature-dev@claude-plugins-official, version literally
# "unknown" — the real shape scout-step1.md confirmed live for this plugin
# (it ships no semver). installPath under a github-source marketplace cache.
my $host_reg = "$dir/host_installed.json";
spew($host_reg, { plugins => {
    'feature-dev@claude-plugins-official' => [ {
        scope       => 'user',
        version     => 'unknown',
        installPath => '/c/Users/tester/.claude/plugins/cache/claude-plugins-official/feature-dev/unknown',
        installedAt => '2026-01-01',
    } ],
}});

my $snap = "$dir/snap.json";
spew($snap, [ {
    key          => 'feature-dev@claude-plugins-official',
    scope        => 'user',
    version      => 'unknown',
    install_path => '/c/Users/tester/.claude/plugins/cache/claude-plugins-official/feature-dev/unknown',
} ]);

my $sel      = "$dir/sel.json";
my $out      = "$dir/installed_out.json";
my $manifest = "$dir/manifest.json";
spew($sel, { schema_version => 3, selected_plugins => ['feature-dev@claude-plugins-official'] });

cmd_materialize_plugins(
    selection_file => $sel, output => $out, manifest => $manifest,
    plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/c/proj',
);

ok(-f $manifest, 'materialize-plugins wrote a copy-plan manifest');
my $plan = t_slurp($manifest);
my ($entry) = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'feature-dev@claude-plugins-official' } @$plan;
ok($entry, 'copy-plan manifest contains an entry for feature-dev@claude-plugins-official');

# Hand-written expected literal — NOT derived by calling the rewrite sub
# under test (that would be a self-fulfilling oracle).
my $expected_dest_rel = 'cache/claude-plugins-official/feature-dev/unknown';
is($entry->{dest_rel}, $expected_dest_rel,
   "copy-plan dest_rel for a version=>'unknown' plugin is the literal path '$expected_dest_rel' (hand-written expectation, spec.md §2.4)");
is($entry->{src}, '/c/Users/tester/.claude/plugins/cache/claude-plugins-official/feature-dev/unknown',
   'copy-plan src is the real host install_path (unrewritten) — this IS what the launcher already copies correctly per scout-step1.md');
