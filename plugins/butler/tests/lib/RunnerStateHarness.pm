package RunnerStateHarness;
# Shared scaffolding for the --state=failed oracle group
# (plugins/butler/tests/t/runner-state-*.t): fixture-tree builders, a bounded
# fork+exec wrapper around scripts/run-tests.pl, and state-file read/write
# helpers. Every helper here exists because the package's own hazard warning
# is absolute -- an unbounded invocation of the real script recursively
# triggers a ~17-minute sweep inside the suite -- so no caller gets to spawn
# it any other way.
#
# WHY A BOUNDED FORK+EXEC AND NOT system()/backticks: a hung child under
# system() blocks the parent indefinitely with no way to reclaim control; a
# forked child can be waited on with polling and killed (TERM, then KILL) the
# same way this repo's process supervisors do for their own
# subprocess supervision.
#
# WHY REAL FILES AND NOT AN IN-MEMORY SCALAR FOR CAPTURED OUTPUT: reopening
# STDOUT/STDERR onto a scalar fails with "Bad file descriptor" on this host's
# perl (documented landmine) -- capture through File::Temp instead.
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
    repo_root runner_script
    make_fixture_tree green_source red_source sleeper_source
    state_file_path write_state_file read_state_file slurp_raw
    relpath_from_root
    run_runner_bounded spawn_runner reap_with_grace
);

use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use POSIX qw(WNOHANG);

# --- location -----------------------------------------------------------
# Anchored on THIS module's own path (plugins/butler/tests/lib/) rather than
# on the calling .t file's $Bin, so every caller gets the same answer
# regardless of how deep it lives under tests/t/.
sub repo_root {
    my $here = abs_path(__FILE__);          # .../plugins/butler/tests/lib/RunnerStateHarness.pm
    my $d = dirname($here);                 # lib
    $d = dirname($d);                       # tests
    $d = dirname($d);                       # butler
    $d = dirname($d);                       # plugins
    $d = dirname($d);                       # repo root
    return $d;
}

sub runner_script { return File::Spec->catfile(repo_root(), 'scripts', 'run-tests.pl') }

# --- fixture sources ------------------------------------------------------
# Deliberately raw TAP-shaped output via print+exit, not Test::More, so the
# exit code and the "not ok" line count are both fully deterministic --
# exactly the two signals run_one() in run-tests.pl judges a file by.
sub green_source {
    return "#!/usr/bin/env perl\n# platform: any\nprint \"ok 1 - fixture pass\\n\";\nexit 0;\n";
}
sub red_source {
    my ($label) = @_;
    $label //= 'fixture forced failure';
    return "#!/usr/bin/env perl\n# platform: any\nprint \"not ok 1 - $label\\n\";\nexit 1;\n";
}
sub sleeper_source {
    my ($secs) = @_;
    $secs //= 5;
    return "#!/usr/bin/env perl\n# platform: any\nsleep($secs);\nprint \"not ok 1 - fixture forced failure after sleep\\n\";\nexit 1;\n";
}

# make_fixture_tree(%files) -> $dir
# %files maps a bare basename (must end .t) to file content. Populates
# $dir/tests/t/<name> for each, matching run-tests.pl's own
# "$t/tests/t/*.t" resolution when $dir is passed as a positional target.
sub make_fixture_tree {
    my (%files) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $ttdir = File::Spec->catdir($dir, 'tests', 't');
    make_path($ttdir);
    for my $name (sort keys %files) {
        my $path = File::Spec->catfile($ttdir, $name);
        open my $fh, '>', $path or die "cannot write fixture $path: $!";
        print {$fh} $files{$name};
        close $fh;
    }
    return $dir;
}

# --- state file I/O (test-side helpers; independent of the runner's own
# not-yet-implemented write logic -- used to pre-seed and to inspect) -------
sub state_file_path { my ($dir) = @_; return File::Spec->catfile($dir, 'last-failures.txt') }

sub write_state_file {
    my ($dir, @lines) = @_;
    make_path($dir) unless -d $dir;
    my $path = state_file_path($dir);
    open my $fh, '>:raw', $path or die "cannot write state file $path: $!";
    print {$fh} "$_\n" for @lines;
    close $fh;
    return $path;
}

sub read_state_file {
    my ($dir) = @_;
    my $path = state_file_path($dir);
    return () unless -f $path;
    my $raw = slurp_raw($path);
    return () unless defined $raw && length $raw;
    return split /\n/, $raw;
}

sub slurp_raw {
    my ($path) = @_;
    return undef unless -f $path;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    my $raw = <$fh>;
    close $fh;
    return $raw;
}

# relpath_from_root($abs_path) -> forward-slash path relative to repo_root()
sub relpath_from_root {
    my ($abs) = @_;
    my $rel = File::Spec->abs2rel($abs, repo_root());
    $rel =~ s{\\}{/}g;
    return $rel;
}

# --- bounded execution ------------------------------------------------------
# spawn_runner(args => [...], env => {...}) -> ($pid, $out_path, $err_path)
# Forks and execs `perl scripts/run-tests.pl @args` with %ENV merged with the
# given env overrides (CCPRAXIS_TEST_STATE_DIR above all). Does NOT wait --
# callers that need timing control (the kill-mid-flight group) call
# reap_with_grace() themselves; callers that just want a bounded run-to-
# completion should use run_runner_bounded() instead.
sub spawn_runner {
    my (%args) = @_;
    my $arglist = $args{args} // [];
    my $env     = $args{env}  // {};
    my $script  = runner_script();

    my $out_fh = File::Temp->new(UNLINK => 0);
    my $err_fh = File::Temp->new(UNLINK => 0);
    my $out_path = "$out_fh";
    my $err_path = "$err_fh";
    close $out_fh;
    close $err_fh;

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        for my $k (keys %$env) { $ENV{$k} = $env->{$k} }
        open(STDOUT, '>', $out_path) or POSIX::_exit(97);
        open(STDERR, '>', $err_path) or POSIX::_exit(98);
        exec($^X, $script, @$arglist) or POSIX::_exit(99);
    }
    return ($pid, $out_path, $err_path);
}

# reap_with_grace($pid, %opts) -> ($rc, $timed_out)
# Polls WNOHANG up to opts{timeout} seconds (default 15). If still alive,
# sends TERM, gives it opts{term_grace} seconds (default 2), then KILL and a
# blocking waitpid.
sub reap_with_grace {
    my ($pid, %opts) = @_;
    my $timeout    = $opts{timeout}    // 15;
    my $term_grace = $opts{term_grace} // 2;

    my $deadline = time() + $timeout;
    my $reaped = 0;
    while (time() < $deadline) {
        my $r = waitpid($pid, WNOHANG);
        if ($r == $pid) { $reaped = 1; last }
        select(undef, undef, undef, 0.1);
    }
    my $timed_out = 0;
    unless ($reaped) {
        $timed_out = 1;
        kill('TERM', $pid);
        my $waited = 0;
        while ($waited < $term_grace) {
            my $r = waitpid($pid, WNOHANG);
            last if $r == $pid;
            select(undef, undef, undef, 0.1);
            $waited += 0.1;
        }
        if ((waitpid($pid, WNOHANG) // 0) != $pid) {
            kill('KILL', $pid);
            waitpid($pid, 0);
        }
    }
    my $rc = $? >> 8;
    return ($rc, $timed_out);
}

# run_runner_bounded(args => [...], env => {...}, timeout => N)
#   -> { rc, out, err, timed_out }
# Spawns and waits to completion (or kills at the timeout), returning
# captured stdout/stderr. The one-stop helper for every ordinary (non-timing-
# sensitive) invocation in this group.
sub run_runner_bounded {
    my (%args) = @_;
    my ($pid, $out_path, $err_path) = spawn_runner(%args);
    my ($rc, $timed_out) = reap_with_grace($pid, timeout => ($args{timeout} // 15));
    my $out = slurp_raw($out_path) // '';
    my $err = slurp_raw($err_path) // '';
    unlink $out_path, $err_path;
    return { rc => $rc, out => $out, err => $err, timed_out => $timed_out, pid => $pid };
}

1;
