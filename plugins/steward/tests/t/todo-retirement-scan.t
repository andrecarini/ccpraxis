#!/usr/bin/env perl
# platform: any
# Oracle for blueprint almanac-records, package 13 (the retirement of the
# legacy per-project todo plugin and its sync script). Written blind to the
# implementation: it enforces the ledger's zero-tracked-hits done criterion
# directly against the real working tree, carving out Decision 31's two
# comment-only exemptions by PATH rather than by weakening the pattern.
#
# Spec: .ccpraxis-local-data/blueprints/almanac-records/specs/13-retire-todo-plugin-spec.md
# section 4.2 AC11. Decision 31 exempts
# plugins/almanac/scripts/almanac-migrate-todos.pl and its test
# (plugins/almanac/tests/t/almanac-migrate-todos.t) from the zero-hits rule:
# both name the retired script only in a comment, and package 11 (which owns
# them) is already done.

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $ROOT = "$Bin/../../../..";

# -e, not -d: in a linked worktree (git worktree add) .git is a FILE.
ok(-e "$ROOT/.git", 'the repo root resolved above this file looks like a git worktree (sanity check)')
    or diag("resolved ROOT=$ROOT");

# Decision 31's two exemptions. Anything else naming the retired script or
# plugin key is a leftover reference this package must have repaired.
my %EXEMPT = (
    'plugins/almanac/scripts/almanac-migrate-todos.pl' => 1,
    'plugins/almanac/tests/t/almanac-migrate-todos.t'  => 1,
);

# Both forbidden tokens are assembled from two halves rather than written as
# a contiguous literal, so this file never contains either exact byte string
# it scans for -- once tracked, it would otherwise match itself and its own
# zero-hits assertion below would fail. Same technique as
# plugins/steward/tests/t/backup-vault.t's NEWAC-VAULTSCAN block.
my $tok_script = join('', 'todo', '-sync');
my $tok_plugin = join('', 'todo', '@ccpraxis-local');

my @raw = qx{git -C "$ROOT" grep -n -e "$tok_script" -e "$tok_plugin" -- . 2>&1};
my $git_exit = $? >> 8;

# git grep exits 0 (hits found) or 1 (no hits) on a clean invocation; any
# other exit code means the invocation itself failed (bad cwd, not a repo,
# etc.), which is a harness problem, not a content finding.
ok($git_exit == 0 || $git_exit == 1, "git grep exited 0 or 1 (got $git_exit)")
    or diag('git grep output: ' . join('', @raw));

my @unexempt;
for my $line (@raw) {
    chomp $line;
    next unless length $line;
    my ($path) = split /:/, $line, 2;
    next if defined($path) && $EXEMPT{$path};
    push @unexempt, $line;
}

is(scalar(@unexempt), 0,
    'zero tracked git-grep hits for the retired sync script or its plugin key outside the Decision 31 exemptions')
    or diag(join("\n", @unexempt));

for my $path (sort keys %EXEMPT) {
    ok(-f "$ROOT/$path", "Decision 31's exempted path still exists on disk: $path");
}

done_testing();
