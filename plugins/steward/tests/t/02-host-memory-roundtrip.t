#!/usr/bin/env perl
# 02-host-memory-roundtrip.t — fresh register + host-memory PUSH. Proves the
# synthetic _host-memory tracked path resolves to ~/.claude/projects/<enc>/memory
# on this machine, gets walked, and lands in the vault under
# projects/<slug>/files/_host-memory/ (Decision #1, scope items 2 & 5).
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use StewardTest qw(ok is run_vs temproot make_machine init_remote write_text read_text path_exists done_testing diag);

my $root = temproot();
my $url  = init_remote($root);
my $home = make_machine($root, 'home1');
my $proj = "$root/proj1";
mkdir $proj or die "mkdir $proj: $!";

my $i = run_vs($home, 'init', '--url', $url);
my $init_ok = $i->{json} && $i->{json}{status} =~ /^(?:initialized|already_initialized)$/;
ok($init_ok, "vault init") or diag($i->{out});

# Resolve and populate this machine's host memory dir for the project.
my $hp = run_vs($home, 'host-memory-path', '--cwd', $proj);
my $memdir = $hp->{json} ? $hp->{json}{memory_dir} : undef;
ok($memdir, "resolved host memory dir") or diag($hp->{out});
write_text("$memdir/MEMORY.md", "# memory\n- a host memory fact\n");
write_text("$memdir/sub/note.md", "nested host memory\n");

# A normal in-project tracked file, to prove both kinds coexist.
write_text("$proj/CLAUDE.md", "# proj\n");

my $reg = run_vs($home, 'register', '--fresh', '--cwd', $proj,
                 '--slug', 'proj1', '--files', '_host-memory,CLAUDE.md');
ok($reg->{json} && $reg->{json}{status} eq 'registered_fresh', "register --fresh")
    or diag($reg->{out});

my $sync = run_vs($home, 'sync-project', '--slug', 'proj1');
ok($sync->{json} && $sync->{json}{status} eq 'synced', "sync-project staged")
    or diag($sync->{out});

my $cp = run_vs($home, 'commit-and-push', '--slug', 'proj1');
ok($cp->{json} && $cp->{json}{status} eq 'committed_and_pushed', "commit-and-push")
    or diag($cp->{out});

my $vault = "$home/.claude/claude-code-vault/projects/proj1/files";
ok(path_exists("$vault/_host-memory/MEMORY.md"),    "vault has _host-memory/MEMORY.md");
ok(path_exists("$vault/_host-memory/sub/note.md"),  "vault has nested _host-memory/sub/note.md");
is(read_text("$vault/_host-memory/MEMORY.md"),
   "# memory\n- a host memory fact\n",              "vault host-memory content matches source");
ok(path_exists("$vault/CLAUDE.md"),                 "vault has the normal CLAUDE.md too");

done_testing();
