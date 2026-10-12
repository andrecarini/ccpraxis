#!/usr/bin/env perl
# platform: windows
#
# Package 16-sandbox-picker-missing-host-rows (almanac bug 20261001-192457-
# f15e): the sandbox session picker showed ZERO host-origin rows despite
# real host *.jsonl session files existing on disk for the project.
#
# Root cause (confirmed by the driver directly -- Decision 68, no architect
# spec; see .ccpraxis-local-data/blueprints/tooling-backlog/blueprint.md):
# on this host's Git-for-Windows perl, Cwd::abs_path() returns a POSIX-style
# path with a LOWERCASE drive letter (e.g. /c/Development/ccpraxis).
# launcher.pl's $PROJECT_PATH = winify_path($PROJECT_PATH) (around line 476)
# converts this to `c:/Development/ccpraxis` via a regex that PRESERVES
# whatever case the drive letter already had. SessionFork::encode_project_path
# is case-preserving BY DESIGN (only [A-Za-z0-9] chars pass through
# literally), so it then encodes this into `c--Development-ccpraxis` -- but
# real Claude Code host session directories on disk use an UPPERCASE drive
# letter (`C--Development-ccpraxis`; verified present on this host, 60+ real
# *.jsonl files). The case mismatch means origin_sessions('host') in
# select-session.pl never matches the real directory, so the picker shows no
# host rows at all.
#
# The decided fix (implementer's job, not this test's): uppercase the
# captured drive letter inside winify_path's use in launcher.pl ONLY --
# bootstrap.pl and MountSpec.pm carry the identical regex but are explicitly
# OUT OF SCOPE (Decision 68), so this file must never assert anything about
# their behaviour.
#
# This file does NOT launch a sandbox or a container (CLAUDE.md: "Never let
# a test spawn launcher.pl unguarded" -- it will build an image and start a
# container). Part 2 below runs a TRUNCATED copy of launcher.pl's own source
# (everything up to and including the $PROJECT_PATH/$PROJECT_NAME resolution,
# BEFORE any lock/TUI/podman-create logic) as a real subprocess, so the
# assertion exercises launcher.pl's actual production code -- wherever
# within that prefix the implementer lands the fix -- rather than a
# reimplementation of it that could pass independently of the real bug.

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Basename qw(dirname basename);
use Cwd qw(abs_path);

my $scripts_dir       = "$Bin/../../scripts";
my $launcher          = "$scripts_dir/launcher.pl";
my $session_fork_pm   = "$scripts_dir/SessionFork.pm";
my $select_session_pl = "$scripts_dir/select-session.pl";

ok(-f $launcher,          'launcher.pl is where the test expects')          or BAIL_OUT("missing $launcher");
ok(-f $session_fork_pm,   'SessionFork.pm is where the test expects')       or BAIL_OUT("missing $session_fork_pm");
ok(-f $select_session_pl, 'select-session.pl is where the test expects')    or BAIL_OUT("missing $select_session_pl");

require $session_fork_pm;

# =====================================================================
# Part 1 -- encode_project_path is case-preserving BY DESIGN (pin the
# contract so this package's fix is never mistakenly applied here instead
# of at winify_path's call site in launcher.pl), and show its composed
# consequence: fed a lowercase-drive path it produces a dirname that does
# NOT match the real on-disk host sessions dir.
# =====================================================================

is(SessionFork::encode_project_path('/c/Development/ccpraxis'), '-c-Development-ccpraxis',
   'encode_project_path is case-preserving for a lowercase-drive POSIX path (by design -- not this bug)');
is(SessionFork::encode_project_path('/C/Development/ccpraxis'), '-C-Development-ccpraxis',
   'encode_project_path is case-preserving for an uppercase-drive POSIX path (by design -- not this bug)');
isnt(SessionFork::encode_project_path('/c/Development/ccpraxis'),
     SessionFork::encode_project_path('/C/Development/ccpraxis'),
     'encode_project_path therefore encodes a lowercase- and uppercase-drive form of the SAME path differently -- '
     . 'the composed consequence that makes the f15e mismatch possible');

# =====================================================================
# Part 2 (root-cause pin / AC "winify_path composed path") -- run
# launcher.pl's OWN project-path resolution block, as real production code,
# against a lowercase-drive-letter input, and assert the resulting
# $PROJECT_PATH carries an UPPERCASE drive letter.
#
# Sliced rather than `do`ne: launcher.pl calls exit()/die() throughout, and
# $PROJECT_PATH is a lexical `my` invisible to a caller after `do` returns
# (or never returns, if launcher.pl exits). Slicing to a prefix that ends
# right after the winify_path() call means this subprocess never reaches
# any lock/TUI/podman-create code -- it only needs a container CLI on PATH
# for its OWN startup probe (`docker --version` / `podman --version`,
# launcher.pl's very first gate), never an actual container.
# =====================================================================

sub _have_container_cli {
    my $null = ($^O =~ /MSWin32/) ? 'nul' : '/dev/null';
    for my $cli (qw(docker podman)) {
        return 1 if system("$cli --version >$null 2>&1") == 0;
    }
    return 0;
}

my $anchor = '$PROJECT_PATH = winify_path($PROJECT_PATH);';

SKIP: {
    skip 'neither docker nor podman is on PATH (launcher.pl refuses to start without one)', 3
        unless _have_container_cli();

    open my $fh, '<', $launcher or BAIL_OUT("cannot read $launcher: $!");
    local $/;
    my $src = <$fh>;
    close $fh;

    my $pos = index($src, $anchor);
    ok($pos >= 0, "found the \$PROJECT_PATH = winify_path(...) call site in launcher.pl (the fix's pin point)")
        or skip 'cannot locate the winify_path call site -- launcher.pl source changed shape', 2;

    my $prefix = substr($src, 0, $pos + length($anchor));
    $prefix .= "\nprint \"PROJECT_PATH=\$PROJECT_PATH\\n\";\n1;\n";

    my ($slice_fh, $slice_path) = tempfile(SUFFIX => '.pl', UNLINK => 1);
    print {$slice_fh} $prefix;
    close $slice_fh;

    # A real project directory with a lowercase-drive form on this host --
    # exactly the shape Cwd::abs_path() hands back (confirmed root cause).
    my $probe_dir = tempdir(CLEANUP => 1);

    my $cmd = sprintf('"%s" -I"%s" "%s" "%s" 2>&1', $^X, $scripts_dir, $slice_path, $probe_dir);
    my $output = `$cmd`;
    my $rc = $? >> 8;

    is($rc, 0, 'the sliced project-path-resolution prefix of launcher.pl runs cleanly')
        or diag("command: $cmd\noutput:\n$output");

    my ($captured) = $output =~ /PROJECT_PATH=(.*)$/m;
    ok(defined $captured, 'sliced launcher.pl prefix printed a resolved PROJECT_PATH')
        or diag("full output:\n$output");

    my ($drive) = defined($captured) ? ($captured =~ m{^([A-Za-z]):/}) : (undef);
    is(defined $drive ? $drive : '(none)', defined $drive ? uc($drive) : '(none -- see above)',
       'launcher.pl resolves a lowercase-drive project path to an UPPERCASE drive letter (f15e fix)');

    # =====================================================================
    # Part 3 (AC "end-to-end confirm against a real C--...-named directory
    # on disk") -- re-run the same sliced prefix against the REAL ccpraxis
    # checkout this test lives in (the exact project the bug report's 60+
    # real host session files belong to), then confirm
    # SessionFork::host_sessions_dir() for the CORRECTED path resolves to a
    # directory that genuinely exists on disk with real session files --
    # the observable fix for "the picker shows real host-origin rows".
    # =====================================================================
    SKIP: {
        skip 'Part 2 did not produce a usable PROJECT_PATH', 3 unless defined $drive;

        my $repo_root = abs_path("$Bin/../../../..");
        ok(defined $repo_root && -d $repo_root && -d "$repo_root/.git",
           'resolved this checkout\'s repo root for the end-to-end fixture')
            or skip 'could not resolve repo root', 2;

        my $cmd2 = sprintf('"%s" -I"%s" "%s" "%s" 2>&1', $^X, $scripts_dir, $slice_path, $repo_root);
        my $output2 = `$cmd2`;
        my ($real_project_path) = $output2 =~ /PROJECT_PATH=(.*)$/m;
        ok(defined $real_project_path, 'sliced prefix resolved this real checkout\'s own project path')
            or diag("full output:\n$output2");

        SKIP: {
            skip 'no resolved real project path to compose a host-sessions-dir from', 1
                unless defined $real_project_path;

            my $home = $ENV{HOME} // $ENV{USERPROFILE};
            my $claude_config_dir = "$home/.claude";
            my $host_sessions_dir = SessionFork::host_sessions_dir($claude_config_dir, $real_project_path);

            SKIP: {
                skip 'no real on-disk host sessions dir for this checkout on this host', 1
                    unless -d $host_sessions_dir;

                my @jsonl = glob("$host_sessions_dir/*.jsonl");
                ok((-d $host_sessions_dir && @jsonl > 0),
                   "host_sessions_dir() for the fixed PROJECT_PATH ($real_project_path) resolves to a real, "
                   . "populated session directory ($host_sessions_dir) -- the picker's host rows become visible")
                    or diag("host_sessions_dir computed as: $host_sessions_dir"
                            . (-d $host_sessions_dir ? ' (exists, 0 *.jsonl files)' : ' (does not exist)'));
            }
        }
    }
}

# =====================================================================
# Part 4 (Decision 69 regression pin) -- SessionFork::host_sessions_dir()'s
# utf8::encode fix, exercised with a SYNTHETIC non-ASCII claude_config_dir/
# project_path pair. Not gated on any real on-disk directory, so it runs
# identically on every host regardless of what sessions happen to exist
# here -- the durable coverage Part 3 cannot provide by itself.
# =====================================================================

sub _byte_string {
    my ($s) = @_;
    return $s unless defined $s;
    my $copy = $s;
    utf8::encode($copy) if utf8::is_utf8($copy);
    return $copy;
}

{
    my $claude_config_dir = "/home/Andr\x{e9}/.claude";
    my $project_path      = "/home/Andr\x{e9}/projects/ccpraxis";

    # Force the UTF8 flag on $project_path, simulating a wide-character
    # string as it would arrive via a decoded command-line argument -- the
    # exact shape the Decision 69 utf8::encode fix (inside
    # encode_project_path, which host_sessions_dir() delegates to) guards
    # against. $claude_config_dir is left as a plain byte string, matching
    # how it is produced in practice (e.g. from $ENV{HOME}).
    utf8::upgrade($project_path);

    my $host_sessions_dir = SessionFork::host_sessions_dir($claude_config_dir, $project_path);

    ok(!utf8::is_utf8($host_sessions_dir),
       'host_sessions_dir() returns a byte string (not UTF8-flagged) for a non-ASCII synthetic path '
       . '-- the Decision 69 utf8::encode fix');

    my $expected = _byte_string($claude_config_dir) . '/projects/'
        . _byte_string(SessionFork::encode_project_path($project_path));

    is(_byte_string($host_sessions_dir), $expected,
       'host_sessions_dir() for a synthetic non-ASCII claude_config_dir/project_path pair is byte-exact-equal '
       . 'to the expected composed path');
}

done_testing();
