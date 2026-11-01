#!/usr/bin/env perl
# platform: any
# A bug report filed from a project SUBFOLDER lands at the project root.
#
# Bug report 20261031-232358-0381: almanac-bug.pl took its root from --project, else
# CLAUDE_PROJECT_DIR, else cwd. Claude Code sets CLAUDE_PROJECT_DIR for hooks, not for Bash tool
# commands, so an agent that had cd'd into functions/ filed into functions/.ccpraxis-local-data,
# which no collect walks. Two DAME reports sat there unseen from August to November.
#
# Every case runs the real script as a subprocess from a subfolder of a throwaway project, with
# CLAUDE_PROJECT_DIR and ALMANAC_PROJECT_ROOT unset, the way a Bash tool call sees them.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec ();
use Test::More;

(my $SCRIPT = "$Bin/../../scripts/almanac-bug.pl") =~ s{\\}{/}g;

sub file_from {
    my ($cwd, @extra) = @_;
    my $pid = open(my $kid, '-|') // die "fork: $!";
    if (!$pid) {
        delete @ENV{qw(CLAUDE_PROJECT_DIR ALMANAC_PROJECT_ROOT)};
        chdir $cwd or die "chdir $cwd: $!";
        open(STDERR, '>&', \*STDOUT);
        open(STDIN, '<', File::Spec->devnull) or die "devnull: $!";
        exec($^X, $SCRIPT, 'file', '--title', 'a test report', '--severity', 'low', '--area', 'almanac',
             '--body', 'filed by bug-file-project-root.t', @extra) or die "exec: $!";
    }
    my $out = do { local $/; <$kid> };
    close $kid;
    return ($? >> 8, $out // '');
}

sub reports_in { my ($root) = @_; my @r = glob("$root/.ccpraxis-local-data/bug-reports/*.md"); return @r }
sub n_reports  { my @r = reports_in($_[0]); return scalar @r }
sub field { my ($path, $k) = @_; open my $fh, '<', $path or return; while (<$fh>) { return $1 if /^\Q$k\E: (.*)$/ } return }

# --- a git project, filed from two levels down ------------------------------------------------------
{
    my $root = tempdir(CLEANUP => 1); $root =~ s{\\}{/}g;
    make_path("$root/.git", "$root/functions/src");
    my ($rc, $out) = file_from("$root/functions/src");
    is($rc, 0, 'filing from a subfolder succeeds') or diag($out);
    my @at_root = reports_in($root);
    is(scalar @at_root, 1, 'THE BUG: the report lands in the project root\'s store');
    ok(!-e "$root/functions/src/.ccpraxis-local-data" && !-e "$root/functions/.ccpraxis-local-data",
       'and no stray store is created in the subfolder');
    # Same directory, possibly spelled differently (/tmp/x vs its /c/Users/.../Temp/x target).
    my $proj = field($at_root[0], 'project') // '';
    my @a = stat($proj); my @b = stat($root);
    ok(@a && @b && $a[0] == $b[0] && $a[1] == $b[1], "its project: is the root ($proj)");
}

# --- the nearest existing store wins over a farther .git -------------------------------------------
{
    my $root = tempdir(CLEANUP => 1); $root =~ s{\\}{/}g;
    make_path("$root/.git", "$root/app/.ccpraxis-local-data", "$root/app/deep");
    my ($rc, $out) = file_from("$root/app/deep");
    is($rc, 0, 'filing below a nested store succeeds') or diag($out);
    is(n_reports("$root/app"), 1, 'the nearest ancestor holding .ccpraxis-local-data is the root');
    is(n_reports($root), 0, 'not the farther git root');
}

# --- --project still wins ------------------------------------------------------------------------
{
    my $root  = tempdir(CLEANUP => 1); $root  =~ s{\\}{/}g;
    my $other = tempdir(CLEANUP => 1); $other =~ s{\\}{/}g;
    make_path("$root/.git", "$root/sub");
    my ($rc, $out) = file_from("$root/sub", '--project', $other);
    is($rc, 0, '--project filing succeeds') or diag($out);
    is(n_reports($other), 1, 'an explicit --project is honoured');
    is(n_reports($root), 0, 'and the walk is not consulted');
}

done_testing();
