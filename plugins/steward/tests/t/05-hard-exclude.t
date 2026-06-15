#!/usr/bin/env perl
# 05-hard-exclude.t — hard-excludes are honoured both at WALK time (a tracked
# directory containing an excluded path) and at REGISTER time (refusing an
# excluded path outright). The blueprints/<name>/runs/ regex exclude is the
# canonical walk-time case: authored ledger files are backed up, the machine-local
# runs/ stream logs are not.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use StewardTest qw(ok run_vs temproot make_machine init_remote write_text path_exists done_testing diag);

my $root   = temproot();
my $remote = init_remote($root);
my $home   = make_machine($root, 'home1');
my $proj   = "$root/proj"; mkdir $proj or die;
run_vs($home, 'init', '--url', $remote);

# A tracked blueprints dir with an authored ledger AND a machine-local runs/ log.
write_text("$proj/.ccpraxis-local-data/blueprints/foo/blueprint.md", "# foo blueprint\n");
write_text("$proj/.ccpraxis-local-data/blueprints/foo/runs/session-123.log", "transient run log\n");

my $reg = run_vs($home, 'register', '--fresh', '--cwd', $proj,
                 '--slug', 'proj', '--files', '.ccpraxis-local-data/blueprints');
ok($reg->{json} && $reg->{json}{status} eq 'registered_fresh', "register --fresh") or diag($reg->{out});
run_vs($home, 'sync-project', '--slug', 'proj');
run_vs($home, 'commit-and-push', '--slug', 'proj');

my $vf = "$home/.claude/claude-code-vault/projects/proj/files";
ok(path_exists("$vf/.ccpraxis-local-data/blueprints/foo/blueprint.md"),
   "authored blueprint.md IS backed up");
ok(!path_exists("$vf/.ccpraxis-local-data/blueprints/foo/runs/session-123.log"),
   "machine-local runs/ log is hard-excluded from the vault");

# Register-time refusal: an explicitly hard-excluded path is rejected even though
# it exists on disk.
my $proj_b = "$root/projB"; mkdir $proj_b or die;
write_text("$proj_b/.claude/settings.local.json", "{\"x\":1}\n");
my $bad = run_vs($home, 'register', '--fresh', '--cwd', $proj_b,
                 '--slug', 'projb', '--files', '.claude/settings.local.json');
ok($bad->{json} && $bad->{json}{status} eq 'error', "register refuses a hard-excluded path");
ok($bad->{json} && $bad->{json}{error} =~ /hard-excluded/, "refusal cites hard-exclude") or diag($bad->{out});

done_testing();
