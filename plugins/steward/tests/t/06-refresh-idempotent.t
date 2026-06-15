#!/usr/bin/env perl
# 06-refresh-idempotent.t — refresh-default-tracked picks up default paths that
# came into existence AFTER registration (the synthetic _host-memory among them)
# and is idempotent: a second run adds nothing and reports already_tracked
# (Decision #1, scope item 3; done-criterion).
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use StewardTest qw(ok is run_vs temproot make_machine init_remote write_text done_testing diag);

my $root   = temproot();
my $remote = init_remote($root);
my $home   = make_machine($root, 'home1');
my $proj   = "$root/proj"; mkdir $proj or die;
run_vs($home, 'init', '--url', $remote);

# Register tracking only CLAUDE.md.
write_text("$proj/CLAUDE.md", "# proj\n");
my $reg = run_vs($home, 'register', '--fresh', '--cwd', $proj, '--slug', 'proj', '--files', 'CLAUDE.md');
ok($reg->{json} && $reg->{json}{status} eq 'registered_fresh', "register --fresh (CLAUDE.md only)") or diag($reg->{out});

# NOW create two default-tracked paths that didn't exist at registration:
# a host memory dir (synthetic _host-memory) and a blueprints dir.
my $mem = run_vs($home, 'host-memory-path', '--cwd', $proj)->{json}{memory_dir};
write_text("$mem/MEMORY.md", "late host memory\n");
write_text("$proj/.ccpraxis-local-data/blueprints/x/blueprint.md", "# x\n");

# First refresh: should ADD both new paths, report CLAUDE.md already tracked.
my $r1 = run_vs($home, 'refresh-default-tracked', '--slug', 'proj');
ok($r1->{json}, "refresh emitted JSON") or diag($r1->{out});
is($r1->{json}{status}, 'tracked_added', "first refresh added new defaults");
my %added = map { $_ => 1 } @{ $r1->{json}{added} // [] };
ok($added{'_host-memory'}, "refresh added _host-memory");
ok($added{'.ccpraxis-local-data/blueprints'}, "refresh added the blueprints dir");
my %already1 = map { $_ => 1 } @{ $r1->{json}{already_tracked} // [] };
ok($already1{'CLAUDE.md'}, "CLAUDE.md reported already_tracked");

# Second refresh: idempotent — nothing added, everything already_tracked.
my $r2 = run_vs($home, 'refresh-default-tracked', '--slug', 'proj');
is($r2->{json}{status}, 'already_tracked', "second refresh is idempotent (status)");
is(scalar(@{ $r2->{json}{added} // [] }), 0, "second refresh added nothing");
my %already2 = map { $_ => 1 } @{ $r2->{json}{already_tracked} // [] };
ok($already2{'_host-memory'} && $already2{'.ccpraxis-local-data/blueprints'} && $already2{'CLAUDE.md'},
   "second refresh reports the prior adds as already_tracked");

done_testing();
