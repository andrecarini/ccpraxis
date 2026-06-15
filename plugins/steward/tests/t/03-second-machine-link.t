#!/usr/bin/env perl
# 03-second-machine-link.t — the cross-machine guarantee from Decision #1: host
# memories pushed from machine A are pulled on machine B into B's OWN encoded
# memory dir (computed from B's cwd), NOT machine A's. Machine 1 pushes; machine
# 2 links the same vault from a different HOME + different project cwd and syncs.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use StewardTest qw(ok is run_vs temproot make_machine init_remote write_text read_text path_exists done_testing diag);

my $root   = temproot();
my $remote = init_remote($root);

# ── Machine 1: create + push a host memory ──────────────────────────
my $home1 = make_machine($root, 'home1');
my $proj1 = "$root/proj1"; mkdir $proj1 or die "mkdir: $!";
ok(run_vs($home1, 'init', '--url', $remote)->{json}, "m1 vault init");
my $hp1 = run_vs($home1, 'host-memory-path', '--cwd', $proj1);
my $mem1 = $hp1->{json}{memory_dir};
write_text("$mem1/MEMORY.md", "machine-1 host memory\n");
my $reg1 = run_vs($home1, 'register', '--fresh', '--cwd', $proj1, '--slug', 'shared', '--files', '_host-memory');
ok($reg1->{json} && $reg1->{json}{status} eq 'registered_fresh', "m1 register --fresh") or diag($reg1->{out});
run_vs($home1, 'sync-project', '--slug', 'shared');
my $cp1 = run_vs($home1, 'commit-and-push', '--slug', 'shared');
ok($cp1->{json} && $cp1->{json}{status} eq 'committed_and_pushed', "m1 pushed host memory") or diag($cp1->{out});

# ── Machine 2: link the SAME vault from a different HOME + cwd ───────
my $home2 = make_machine($root, 'home2');
my $proj2 = "$root/proj2"; mkdir $proj2 or die "mkdir: $!";
ok(run_vs($home2, 'init', '--url', $remote)->{json}, "m2 vault init (clone non-empty)");

# Encodings must differ — different cwd => different transcript dir.
my $enc1 = run_vs($home1, 'host-memory-path', '--cwd', $proj1)->{json}{encoded};
my $enc2 = run_vs($home2, 'host-memory-path', '--cwd', $proj2)->{json}{encoded};
ok($enc1 ne $enc2, "proj1 and proj2 encode to different memory dirs ($enc1 != $enc2)");

my $reg2 = run_vs($home2, 'register', '--link', '--cwd', $proj2, '--slug', 'shared');
ok($reg2->{json} && $reg2->{json}{status} eq 'registered_link', "m2 register --link") or diag($reg2->{out});

my $sync2 = run_vs($home2, 'sync-project', '--slug', 'shared');
ok($sync2->{json} && $sync2->{json}{status} eq 'synced', "m2 sync-project staged the pull") or diag($sync2->{out});
my $cp2 = run_vs($home2, 'commit-and-push', '--slug', 'shared');
ok($cp2->{json} && $cp2->{json}{status} eq 'committed_and_pushed', "m2 finalized the pull") or diag($cp2->{out});

# The memory must land in MACHINE 2's encoded dir, with machine 1's content.
my $mem2 = run_vs($home2, 'host-memory-path', '--cwd', $proj2)->{json}{memory_dir};
ok(path_exists("$mem2/MEMORY.md"), "host memory pulled into machine-2's own encoded dir");
is(read_text("$mem2/MEMORY.md"), "machine-1 host memory\n", "pulled content matches machine 1");

# And it must NOT have been written under machine 1's encoding inside home2.
my $wrong = "$home2/.claude/projects/$enc1/memory/MEMORY.md";
ok(!path_exists($wrong), "memory was NOT placed under machine 1's encoding on machine 2");

done_testing();
