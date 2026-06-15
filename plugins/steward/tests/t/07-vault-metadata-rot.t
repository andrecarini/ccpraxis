#!/usr/bin/env perl
# 07-vault-metadata-rot.t — scope item 4: when this machine's local tracked_paths
# grow beyond what the vault metadata.json records, the next sync-project must
# write the union back into the vault metadata (within its own commit) so a future
# cross-machine link sees the full set. Without this, a linked machine silently
# drops the newer paths.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use StewardTest qw(ok run_vs temproot make_machine init_remote write_text read_text done_testing diag);
use JSON::PP;

my $root   = temproot();
my $remote = init_remote($root);
my $home   = make_machine($root, 'home1');
my $proj   = "$root/proj"; mkdir $proj or die;
run_vs($home, 'init', '--url', $remote);

write_text("$proj/CLAUDE.md", "# proj\n");
run_vs($home, 'register', '--fresh', '--cwd', $proj, '--slug', 'proj', '--files', 'CLAUDE.md');
run_vs($home, 'sync-project', '--slug', 'proj');
run_vs($home, 'commit-and-push', '--slug', 'proj');

my $vmeta_path = "$home/.claude/claude-code-vault/projects/proj/metadata.json";
my $before = decode_json(read_text($vmeta_path));
my %b = map { $_ => 1 } @{ $before->{tracked_paths} };
ok($b{'CLAUDE.md'} && !$b{'.ccpraxis-local-data/blueprints'},
   "vault metadata starts with only CLAUDE.md");

# A new default path appears locally; refresh adds it to LOCAL metadata only.
write_text("$proj/.ccpraxis-local-data/blueprints/x/blueprint.md", "# x\n");
run_vs($home, 'refresh-default-tracked', '--slug', 'proj');

# The next sync must converge the vault metadata to include it.
run_vs($home, 'sync-project', '--slug', 'proj');
my $cp = run_vs($home, 'commit-and-push', '--slug', 'proj');
ok($cp->{json} && $cp->{json}{status} eq 'committed_and_pushed', "sync committed") or diag($cp->{out});

my $after = decode_json(read_text($vmeta_path));
my %a = map { $_ => 1 } @{ $after->{tracked_paths} };
ok($a{'CLAUDE.md'}, "vault metadata still has CLAUDE.md (union, not replace)");
ok($a{'.ccpraxis-local-data/blueprints'}, "vault metadata converged to include the new path");

done_testing();
