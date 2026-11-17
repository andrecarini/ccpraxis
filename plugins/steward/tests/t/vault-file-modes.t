#!/usr/bin/env perl
# platform: any
# vault-sync.pl on a Mac: exec bits survive the round trip, and Finder
# metadata never becomes project content.
#
# WHY. copy_file wrote every staged file with a fresh open('>'), so it came
# out 0644: a tracked .claude/hooks/*.sh lost its exec bit on the way into the
# vault (git recorded 100644) and again on the way back out, and a synced hook
# stopped running on the next Mac. Separately, .DS_Store (any folder Finder
# has shown) and ._* AppleDouble files were walked like any other file, so a
# Mac pushed them into the vault and every machine pulled them back. Windows
# hid both: no mode bits, no Finder.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use StewardTest qw(ok is like unlike run_vs temproot make_machine init_remote write_text read_text path_exists done_testing diag);

my $IS_WIN = $^O =~ /^(MSWin32|cygwin|msys)$/;
sub mode_of { return (stat($_[0]))[2] & 07777; }
sub git_out {
    my ($home, $dir, @args) = @_;
    local $ENV{HOME} = $home;
    local $ENV{GIT_CONFIG_GLOBAL} = "$home/.gitconfig";
    open my $fh, '-|', 'git', '-C', $dir, @args or die "git: $!";
    local $/;
    my $o = <$fh> // '';
    close $fh;
    return $o;
}

my $root   = temproot();
my $remote = init_remote($root);

# ── Machine 1 ────────────────────────────────────────────────────────
my $home1 = make_machine($root, 'home1');
my $vault1 = "$home1/.claude/claude-code-vault";
my $proj1 = "$root/proj1";
write_text("$proj1/.claude/hooks/run.sh", "#!/bin/sh\necho v1\n");
chmod 0755, "$proj1/.claude/hooks/run.sh";
write_text("$proj1/.claude/hooks/notes.md", "plain\n");
write_text("$proj1/.claude/hooks/.DS_Store", "\0\0\0\1Bud1 finder junk");
write_text("$proj1/.claude/hooks/._run.sh", "\0\5\26\7 appledouble");

my $init1 = run_vs($home1, 'init', '--url', $remote);
ok($init1->{json} && ($init1->{json}{status} // '') eq 'initialized', 'm1 vault init') or diag($init1->{out});
my $gi = read_text("$vault1/.gitignore") // '';
like($gi, qr/^\.DS_Store$/m, 'a new vault ignores .DS_Store');
like($gi, qr/^\._\*$/m,      'a new vault ignores ._* AppleDouble files');

my $reg1 = run_vs($home1, 'register', '--fresh', '--cwd', $proj1, '--slug', 'modes', '--files', '.claude/hooks');
ok($reg1->{json} && ($reg1->{json}{status} // '') eq 'registered_fresh', 'm1 register --fresh') or diag($reg1->{out});
my $s1 = run_vs($home1, 'sync-project', '--slug', 'modes');
ok($s1->{json} && ($s1->{json}{status} // '') eq 'synced', 'm1 sync-project') or diag($s1->{out});
my $c1 = run_vs($home1, 'commit-and-push', '--slug', 'modes');
ok($c1->{json} && ($c1->{json}{status} // '') eq 'committed_and_pushed', 'm1 commit-and-push') or diag($c1->{out});

my $vfiles = "$vault1/projects/modes/files/.claude/hooks";
ok(path_exists("$vfiles/run.sh"),    'the hook reached the vault');
ok(path_exists("$vfiles/notes.md"),  'an ordinary file reached the vault');
ok(!path_exists("$vfiles/.DS_Store"), '.DS_Store was NOT synced into the vault');
ok(!path_exists("$vfiles/._run.sh"),  '._run.sh was NOT synced into the vault');
my $ls = git_out($home1, $vault1, 'ls-files', '-s', '--', 'projects/modes/files');
unlike($ls, qr/\.DS_Store|\._run\.sh/, 'neither junk file is in the vault index');
unless ($IS_WIN) {
    is(sprintf('%04o', mode_of("$vfiles/run.sh")), '0755', 'the vault copy of the hook keeps its exec bit');
    like($ls, qr{^100755 \S+ \d+\tprojects/modes/files/\.claude/hooks/run\.sh$}m, 'git records the hook as 100755');
    like($ls, qr{^100644 \S+ \d+\tprojects/modes/files/\.claude/hooks/notes\.md$}m, '...and the plain file as 100644 (nothing invented)');
}

# ── Machine 2: link and pull ─────────────────────────────────────────
my $home2 = make_machine($root, 'home2');
my $proj2 = "$root/proj2";
mkdir $proj2 or die "mkdir: $!";
ok(run_vs($home2, 'init', '--url', $remote)->{json}, 'm2 vault init (clone)');
my $reg2 = run_vs($home2, 'register', '--link', '--cwd', $proj2, '--slug', 'modes');
ok($reg2->{json} && ($reg2->{json}{status} // '') eq 'registered_link', 'm2 register --link') or diag($reg2->{out});
run_vs($home2, 'sync-project', '--slug', 'modes');
my $c2 = run_vs($home2, 'commit-and-push', '--slug', 'modes');
ok($c2->{json} && ($c2->{json}{status} // '') eq 'committed_and_pushed', 'm2 finalized the pull') or diag($c2->{out});
is(read_text("$proj2/.claude/hooks/run.sh"), "#!/bin/sh\necho v1\n", 'm2 pulled the hook');
ok(-x "$proj2/.claude/hooks/run.sh", 'the pulled hook is executable on machine 2') unless $IS_WIN;

# ── A vault copy written without exec bits must not strip +x locally ──
# Machine 1 pushes a new version at 0644 (what a Windows push records).
write_text("$proj1/.claude/hooks/run.sh", "#!/bin/sh\necho v2\n");
chmod 0644, "$proj1/.claude/hooks/run.sh";
sleep 1;   # one-second mtime/stamp resolution
run_vs($home1, 'sync-project', '--slug', 'modes');
my $c3 = run_vs($home1, 'commit-and-push', '--slug', 'modes');
ok($c3->{json} && ($c3->{json}{status} // '') eq 'committed_and_pushed', 'm1 pushed v2') or diag($c3->{out});
run_vs($home2, 'sync-project', '--slug', 'modes');
my $c4 = run_vs($home2, 'commit-and-push', '--slug', 'modes');
ok($c4->{json} && ($c4->{json}{status} // '') eq 'committed_and_pushed', 'm2 pulled v2') or diag($c4->{out});
is(read_text("$proj2/.claude/hooks/run.sh"), "#!/bin/sh\necho v2\n", 'm2 has v2');
ok(-x "$proj2/.claude/hooks/run.sh", 'a 0644 vault copy did not strip the exec bit from the local hook') unless $IS_WIN;

# ── An existing vault without the Finder rules gets them, committed ───
{
    my $text = read_text("$vault1/.gitignore");
    $text =~ s/\n# macOS Finder metadata.*\z/\n/s;
    write_text("$vault1/.gitignore", $text);
    git_out($home1, $vault1, 'commit', '-q', '-m', 'simulate an old vault', '--', '.gitignore');
    unlike(read_text("$vault1/.gitignore"), qr/^\.DS_Store$/m, '(setup) the vault .gitignore lacks the rule');
    my $s = run_vs($home1, 'sync-project', '--slug', 'modes');
    is($s->{exit}, 0, 'sync-project on the old vault succeeds') or diag($s->{out});
    like(read_text("$vault1/.gitignore"), qr/^\.DS_Store$/m, 'sync-project adds the .DS_Store rule to an old vault');
    is(git_out($home1, $vault1, 'status', '--porcelain', '--', '.gitignore'), '', '...and commits it (no dirty .gitignore left behind)');
    my $before = git_out($home1, $vault1, 'rev-parse', 'HEAD');
    run_vs($home1, 'sync-project', '--slug', 'modes');
    is(git_out($home1, $vault1, 'rev-parse', 'HEAD'), $before, 'a second sync adds nothing (idempotent)');
    run_vs($home1, 'commit-and-push', '--slug', 'modes');
}

done_testing();
