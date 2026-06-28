#!/usr/bin/env perl
# Fix 2 tier-2 merge-preserve + provenance. Re-materializing the plugin
# registries from the host selection each launch must NOT clobber plugins /
# marketplaces installed INSIDE the sandbox. materialize-plugins must:
#   - refresh host-SELECTED entries (host is authoritative),
#   - PRESERVE entries the launcher never placed (sandbox installs) — even when
#     that plugin ALSO exists on the host but was never selected (the notion
#     trap; provenance comes from the prior copy-plan MANIFEST, not the host
#     registry),
#   - DROP entries the launcher placed before that are now deselected,
#   - emit a copy-plan manifest the launcher uses to copy + reconcile.
# Tests call the skills.pl subs directly (SANDBOX_SKILLS_NO_DISPATCH).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

BEGIN { $ENV{SANDBOX_SKILLS_NO_DISPATCH} = 1; }
require "$Bin/../../scripts/skills.pl";

plan tests => 12;

my $dir = tempdir(CLEANUP => 1);
sub t_spew  { my ($p,$d)=@_; open my $f,'>:raw',$p or die "$p: $!";
              print $f (ref $d ? JSON::PP->new->canonical->encode($d) : $d); close $f; }
sub t_slurp { my $p=shift; open my $f,'<:raw',$p or die "$p: $!"; local $/; JSON::PP->new->decode(<$f>); }

# =========================================================================
# installed_plugins.json merge + manifest provenance
# =========================================================================
{
    # Host registry: A, C, N are all host plugins. B is NOT.
    my $host_reg = "$dir/host_installed.json";
    t_spew($host_reg, { plugins => {
        A => [ { scope=>'user', version=>'1.0.0', installPath=>'/c/x/.claude/plugins/cache/mkt-a/A/1.0.0', gitCommitSha=>'aaa', installedAt=>'2026-01-01' } ],
        C => [ { scope=>'user', version=>'1.0.0', installPath=>'/c/x/.claude/plugins/cache/mkt-c/C/1.0.0', gitCommitSha=>'ccc', installedAt=>'2026-01-01' } ],
        N => [ { scope=>'user', version=>'1.0.0', installPath=>'/c/x/.claude/plugins/cache/mkt-n/N/1.0.0', gitCommitSha=>'nnn', installedAt=>'2026-01-01' } ],
    }});
    my $snap = "$dir/snap.json";
    t_spew($snap, [
        { key=>'A', scope=>'user', version=>'1.0.0', install_path=>'/c/x/.claude/plugins/cache/mkt-a/A/1.0.0' },
        { key=>'C', scope=>'user', version=>'1.0.0', install_path=>'/c/x/.claude/plugins/cache/mkt-c/C/1.0.0' },
        { key=>'N', scope=>'user', version=>'1.0.0', install_path=>'/c/x/.claude/plugins/cache/mkt-n/N/1.0.0' },
    ]);
    my $out      = "$dir/installed_out.json";
    my $sel      = "$dir/sel.json";
    my $manifest = "$dir/manifest.json";

    # Round 1: select A and C (NOT N).
    t_spew($sel, { schema_version=>3, selected_plugins=>['A','C'] });
    cmd_materialize_plugins( selection_file=>$sel, output=>$out, manifest=>$manifest,
        plugins_snapshot=>$snap, plugins_file=>$host_reg, project_path=>'/c/proj' );
    my $r1 = t_slurp($out);
    ok(exists $r1->{plugins}{A}, 'round 1: host-selected A materialized');
    ok(exists $r1->{plugins}{C}, 'round 1: host-selected C materialized');
    ok(!exists $r1->{plugins}{N}, 'round 1: unselected host plugin N NOT materialized');
    # Manifest = the copy-plan the launcher will execute (host-tier this launch).
    my $m1 = t_slurp($manifest);
    my %m1keys = map { $_->{key} => $_ } @$m1;
    ok($m1keys{A} && $m1keys{C} && !$m1keys{N}, 'round 1: manifest copy-plan = [A,C] (placed keys)');
    is($m1keys{A}{dest_rel}, 'cache/mkt-a/A/1.0.0', 'round 1: manifest dest_rel is container-relative');

    # Simulate in-container installs rewriting the registry: B (not on host) AND
    # N (a host plugin the user installed in-sandbox without ever selecting it).
    $r1->{plugins}{B} = [ { scope=>'user', version=>'9.9', installPath=>'/root/.claude/plugins/cache/mkt-b/B/9.9' } ];
    $r1->{plugins}{N} = [ { scope=>'user', version=>'1.0.0', installPath=>'/root/.claude/plugins/cache/mkt-n/N/1.0.0' } ];
    t_spew($out, $r1);

    # Round 2: DESELECT C (select only A). B + N stay on disk.
    t_spew($sel, { schema_version=>3, selected_plugins=>['A'] });
    cmd_materialize_plugins( selection_file=>$sel, output=>$out, manifest=>$manifest,
        plugins_snapshot=>$snap, plugins_file=>$host_reg, project_path=>'/c/proj' );
    my $r2 = t_slurp($out);
    ok(exists $r2->{plugins}{A},  'round 2: selected host plugin A kept (refreshed)');
    ok(exists $r2->{plugins}{B},  'round 2: sandbox-installed B PRESERVED (never a host plugin)');
    ok(exists $r2->{plugins}{N},  'round 2: NOTION TRAP — host plugin N installed in-sandbox but never selected is PRESERVED');
    ok(!exists $r2->{plugins}{C}, 'round 2: DESELECTED host plugin C dropped (was placed by the launcher)');
}

# =========================================================================
# known_marketplaces.json merge
# =========================================================================
{
    my $host_mkt = "$dir/host_km.json";
    t_spew($host_mkt, { mkt1 => { source=>{ source=>'github', repo=>'o/r' },
        installLocation=>'C:\\x\\plugins\\marketplaces\\mkt1' } });
    my $out = "$dir/km_out.json";

    cmd_materialize_known_marketplaces( output=>$out, host_marketplaces=>$host_mkt );
    my $k1 = t_slurp($out);
    is($k1->{mkt1}{installLocation}, '/root/.claude/plugins/marketplaces/mkt1',
       'km round 1: host marketplace installLocation rewritten to container path');

    # Simulate `claude plugin marketplace add mkt2` inside the sandbox.
    $k1->{mkt2} = { source=>{ source=>'github', repo=>'o/r2' },
        installLocation=>'/root/.claude/plugins/marketplaces/mkt2' };
    t_spew($out, $k1);

    cmd_materialize_known_marketplaces( output=>$out, host_marketplaces=>$host_mkt );
    my $k2 = t_slurp($out);
    ok(exists $k2->{mkt1}, 'km round 2: host marketplace kept (refreshed)');
    ok(exists $k2->{mkt2}, 'km round 2: sandbox-added marketplace mkt2 PRESERVED');
}
