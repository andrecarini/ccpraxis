#!/usr/bin/env perl
# 04-conflict.t — a real 3-way conflict on the synthetic _host-memory path: two
# machines edit the same memory file away from a common base, and sync must
# DETECT the conflict (not silently clobber). Proves classify() + the conflict
# path work through local_abs for host memories.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use StewardTest qw(ok is run_vs temproot make_machine init_remote write_text done_testing diag);

my $root   = temproot();
my $remote = init_remote($root);

sub memdir { my ($home, $cwd) = @_; run_vs($home, 'host-memory-path', '--cwd', $cwd)->{json}{memory_dir} }

# Machine 1 establishes the base and pushes it.
my $home1 = make_machine($root, 'home1');
my $proj1 = "$root/proj1"; mkdir $proj1 or die;
run_vs($home1, 'init', '--url', $remote);
write_text(memdir($home1, $proj1) . "/MEMORY.md", "base line\n");
run_vs($home1, 'register', '--fresh', '--cwd', $proj1, '--slug', 'shared', '--files', '_host-memory');
run_vs($home1, 'sync-project', '--slug', 'shared');
run_vs($home1, 'commit-and-push', '--slug', 'shared');

# Machine 2 links, pulls the base, then diverges and pushes "from-2".
my $home2 = make_machine($root, 'home2');
my $proj2 = "$root/proj2"; mkdir $proj2 or die;
run_vs($home2, 'init', '--url', $remote);
run_vs($home2, 'register', '--link', '--cwd', $proj2, '--slug', 'shared');
run_vs($home2, 'sync-project', '--slug', 'shared');
run_vs($home2, 'commit-and-push', '--slug', 'shared');
write_text(memdir($home2, $proj2) . "/MEMORY.md", "from machine 2\n");
my $s2 = run_vs($home2, 'sync-project', '--slug', 'shared');
my $c2 = run_vs($home2, 'commit-and-push', '--slug', 'shared');
ok($c2->{json} && $c2->{json}{status} eq 'committed_and_pushed', "m2 pushed its divergent edit") or diag($c2->{out});

# Machine 1 diverges differently, then syncs: vault(from-2) vs local(from-1) vs
# base(base line) → conflict.
write_text(memdir($home1, $proj1) . "/MEMORY.md", "from machine 1\n");
my $s1 = run_vs($home1, 'sync-project', '--slug', 'shared');
ok($s1->{json}, "m1 sync emitted JSON") or diag($s1->{out});
my @conf = $s1->{json} ? @{ $s1->{json}{conflicts} // [] } : ();
ok(@conf >= 1, "sync reported a conflict");
my @hit = grep { $_->{path} eq '_host-memory/MEMORY.md' } @conf;
ok(@hit == 1, "the conflict is on _host-memory/MEMORY.md");

done_testing();
