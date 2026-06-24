#!/usr/bin/env perl
# 08-backup-data-migration.t — steward's per-project backup state (the
# registration metadata + the 3-way-merge cache base) moved out of the project's
# .claude/ (Claude Code's own dir) into the single .ccpraxis-local-data/ data
# root. Any command that reads project metadata lazily migrates a legacy layout
# on first access: .claude/backup-metadata.json -> .ccpraxis-local-data/
# backup-metadata.json and .claude/backup-cache/ -> .ccpraxis-local-data/
# backup-cache/, preserving content and self-gitignoring the data root.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use StewardTest qw(ok run_vs temproot make_machine init_remote write_text path_exists done_testing diag);
use File::Path qw(make_path);

my $root   = temproot();
my $remote = init_remote($root);
my $home   = make_machine($root, 'home1');
my $proj   = "$root/proj"; mkdir $proj or die;
run_vs($home, 'init', '--url', $remote);

# Register fresh — writes metadata + cache under the NEW data root.
write_text("$proj/.claude/CLAUDE.md", "# proj\n");
my $reg = run_vs($home, 'register', '--fresh', '--cwd', $proj,
                 '--slug', 'proj', '--files', '.claude/CLAUDE.md');
ok($reg->{json} && $reg->{json}{status} eq 'registered_fresh', 'register --fresh') or diag($reg->{out});
ok(path_exists("$proj/.ccpraxis-local-data/backup-metadata.json"),
   'register writes metadata under .ccpraxis-local-data/');

# Simulate a LEGACY (pre-consolidation) layout: move both back under .claude/,
# with a sentinel in the cache to prove content survives the migration.
make_path("$proj/.claude");
rename("$proj/.ccpraxis-local-data/backup-metadata.json", "$proj/.claude/backup-metadata.json")
    or die "simulate-legacy meta: $!";
rename("$proj/.ccpraxis-local-data/backup-cache", "$proj/.claude/backup-cache")
    or die "simulate-legacy cache: $!";
write_text("$proj/.claude/backup-cache/sentinel.txt", "keep-me\n");
ok(path_exists("$proj/.claude/backup-metadata.json"), 'legacy: metadata at old .claude/ path');
ok(!path_exists("$proj/.ccpraxis-local-data/backup-metadata.json"), 'legacy: new path absent before access');

# Any metadata-reading command triggers the lazy migration.
my $isreg = run_vs($home, 'is-registered', '--cwd', $proj);
ok($isreg->{json} && $isreg->{json}{registered}, 'is-registered detects the migrated project')
    or diag($isreg->{out});

# Both moved under the data root; legacy copies gone; cache content preserved.
ok(path_exists("$proj/.ccpraxis-local-data/backup-metadata.json"), 'migrated: metadata at new path');
ok(!path_exists("$proj/.claude/backup-metadata.json"),             'migrated: legacy metadata removed');
ok(path_exists("$proj/.ccpraxis-local-data/backup-cache/sentinel.txt"), 'migrated: cache content preserved');
ok(!path_exists("$proj/.claude/backup-cache"),                    'migrated: legacy cache dir removed');
ok(path_exists("$proj/.ccpraxis-local-data/.gitignore"),          'migrated: data root self-gitignore created');

# And the system is fully functional post-migration: a sync runs clean.
my $sync = run_vs($home, 'sync-project', '--slug', 'proj');
ok($sync->{json}, 'sync-project runs after migration') or diag($sync->{out});

done_testing();
