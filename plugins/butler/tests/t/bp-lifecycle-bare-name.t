#!/usr/bin/env perl
# platform: any
# 03-bp-lifecycle-bare-name-exit20 — bp-lifecycle.pl must behave identically
# whether invoked by bare name, `./`-relative, absolute, or repo-relative
# path. Pre-fix, bare-name invocation from inside plugins/butler/scripts/
# computes $SCRIPT_DIR as the absolute path of the SCRIPT ITSELF (not its
# directory), so the sibling `require "$SCRIPT_DIR/BpState.pm"` tries to open
# a path underneath a regular file. That fails with ENOTDIR (errno 20); a
# failed runtime require dies, and perl's die exit status is $!, so the
# process exits 20 instead of running at all.
#
# This file pins five invocation styles (S1 bare name .. S5 repo-relative)
# across three argument scenarios (B1 reconcile --all --json on an empty
# fixture, B2 no arguments, B3 an unknown --blueprint) and asserts the
# (exit, stdout, stderr) triple is IDENTICAL across all five styles, and
# individually correct per style. See spec:
# .ccpraxis-local-data/blueprints/tooling-backlog/specs/03-bp-lifecycle-bare-name-exit20-spec.md

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Spec;
use Cwd qw(abs_path getcwd);
use JSON::PP;

# Locate the scripts dir from THIS test's own __FILE__, via abs_path, BEFORE
# any chdir — same idiom as lifecycle-reconcile.t:32.
my $TEST_FILE = do { (my $f = __FILE__) =~ s{\\}{/}g; $f };
my $DIR       = dirname(abs_path($TEST_FILE));
my $SCRIPTS   = abs_path("$DIR/../../scripts");
my $LIFECYCLE = "$SCRIPTS/bp-lifecycle.pl";
my $REPO_ROOT = abs_path("$SCRIPTS/../../..");

ok(-f $LIFECYCLE, 'bp-lifecycle.pl exists') or BAIL_OUT('nothing to test');
ok(-d $REPO_ROOT && -f "$REPO_ROOT/plugins/butler/scripts/bp-lifecycle.pl",
   'repo root resolved correctly (plugins/butler/scripts/bp-lifecycle.pl found under it)')
    or BAIL_OUT('repo root miscomputed — cannot build S5');

my $ORIG_CWD = getcwd();

# ------------------------------------------------------------------ helpers ---

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# Run perl against a given script argument (bare name, './x', absolute, or
# repo-relative), with cwd set to $cwd for the duration of the call, restoring
# cwd afterward no matter what. Output captured through real File::Temp files
# (never an in-memory STDOUT/STDERR handle — Git-for-Windows perl fails that
# with "Bad file descriptor"). List-form system only; never a shell string.
sub run_style {
    my ($script_arg, $cwd, @args) = @_;

    my ($out_fh, $out_file) = tempfile(UNLINK => 1);
    close $out_fh;
    my ($err_fh, $err_file) = tempfile(UNLINK => 1);
    close $err_fh;

    ok(chdir($cwd), "chdir to $cwd") or BAIL_OUT("could not chdir to $cwd: $!");

    open(my $saved_out, '>&', \*STDOUT) or die "dup STDOUT: $!";
    open(my $saved_err, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDOUT, '>', $out_file) or die "redirect STDOUT: $!";
    open(STDERR, '>', $err_file) or die "redirect STDERR: $!";

    my $rc = system($^X, $script_arg, @args);

    open(STDOUT, '>&', $saved_out) or die "restore STDOUT: $!";
    open(STDERR, '>&', $saved_err) or die "restore STDERR: $!";
    close $saved_out;
    close $saved_err;

    chdir($ORIG_CWD) or BAIL_OUT("could not chdir back to $ORIG_CWD: $!");

    my $out = slurp($out_file) // '';
    my $err = slurp($err_file) // '';
    unlink $out_file, $err_file;

    return ($rc >> 8, $out, $err);
}

# ------------------------------------------------------------------ fixture ---

# A fresh, empty fixture data-dir: blueprints/ exists and is empty, so
# `reconcile --all --json` has nothing to visit and must report `[]`.
sub make_fixture {
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/blueprints");
    return $root;
}

# cwd for S4: a tempdir unrelated to the repo entirely.
my $UNRELATED_CWD = tempdir(CLEANUP => 1);

# ------------------------------------------------------------- the 5 styles ---
# Each entry: [ label, script-argument-builder(cwd), cwd ]
# The script argument is built fresh per call since S1/S2 are relative to cwd.
my @STYLES = (
    [ 'S1 bare name',                 sub { 'bp-lifecycle.pl' },                                $SCRIPTS ],
    [ 'S2 dot-relative',              sub { './bp-lifecycle.pl' },                               $SCRIPTS ],
    [ 'S3 absolute, cwd=scripts dir', sub { $LIFECYCLE },                                         $SCRIPTS ],
    [ 'S4 absolute, cwd=unrelated',   sub { $LIFECYCLE },                                         $UNRELATED_CWD ],
    [ 'S5 repo-relative, cwd=root',   sub { 'plugins/butler/scripts/bp-lifecycle.pl' },            $REPO_ROOT ],
);

# ------------------------------------------------------------------ scenarios --
# Each scenario builds its own fresh fixture per style invocation (so no style
# can see another style's side effects), and returns the argument list minus
# --data-dir (added by the caller once the fixture is built).
my %SCENARIOS = (
    B1 => {
        label => 'reconcile --all --json on an empty fixture',
        args  => sub { my ($root) = @_; return ('reconcile', '--all', '--json', '--data-dir', $root) },
        expect_rc  => 0,
        expect_out => sub {
            my ($out) = @_;
            my $data = eval { JSON::PP->new->decode($out) };
            return (ref $data eq 'ARRAY' && @$data == 0);
        },
        expect_err => sub {
            my ($err) = @_;
            return 1; # no particular content required beyond AC-4's forbidden substrings
        },
    },
    B2 => {
        label => 'no arguments at all',
        args  => sub { return () },
        expect_rc  => 2,
        expect_out => sub { my ($out) = @_; return $out eq '' || 1; }, # not specified; don't over-assert
        expect_err => sub {
            my ($err) = @_;
            return ($err =~ /missing subcommand/ && $err =~ /usage:/);
        },
    },
    B3 => {
        label => 'reconcile with an unknown --blueprint',
        args  => sub { my ($root) = @_; return ('reconcile', '--blueprint', 'no-such-bp', '--data-dir', $root) },
        expect_rc  => 2,
        expect_out => sub { return 1; },
        expect_err => sub {
            my ($err) = @_;
            return ($err =~ /no blueprint 'no-such-bp'/);
        },
    },
);

# AC-4's forbidden substrings: no bare-name run may show these (would mean the
# pre-fix ENOTDIR/require-failure path fired).
sub assert_no_enotdir_symptoms {
    my ($style_label, $rc, $err) = @_;
    isnt($rc, 20, "$style_label: exit code is not 20 (the pre-fix ENOTDIR symptom)");
    unlike($err, qr/Can't locate/, "$style_label: stderr has no \"Can't locate\"");
    unlike($err, qr/Not a directory/, "$style_label: stderr has no \"Not a directory\"");
    unlike($err, qr{bp-lifecycle\.pl[\\/]Bp}, "$style_label: stderr has no \"bp-lifecycle.pl/Bp...\" substring");
}

# ============================================================================
# Run every (scenario x style) combination. Collect each style's triple per
# scenario so AC-5's pairwise is_deeply comparisons (against S3 as reference)
# can be made after all styles have run for that scenario.
# ============================================================================
for my $scen_name (qw(B1 B2 B3)) {
    my $scen = $SCENARIOS{$scen_name};
    my %triples; # style label => [rc, out, err]

    # ONE fixture per scenario, shared across all 5 styles. This is required
    # for AC-5's identical-triple comparison: the spec notes "all paths in
    # output derive from the absolute --data-dir, so they are identical
    # across styles" — that is only true if every style is handed the SAME
    # --data-dir value. None of B1/B2/B3's argument sets mutate the fixture
    # (B1 is --all on an empty blueprints/ dir; B2 passes no --data-dir at
    # all; B3 targets a blueprint name that does not exist), so reusing one
    # fixture across 5 runs is safe.
    my $root = make_fixture();

    for my $style (@STYLES) {
        my ($label, $build_arg, $cwd) = @$style;

        my @args = $scen->{args}->($root);
        my $script_arg = $build_arg->();

        my ($rc, $out, $err) = run_style($script_arg, $cwd, @args);
        $triples{$label} = [ $rc, $out, $err ];

        # AC-1/AC-2/AC-3 applied per-style (AC-6 pins S2-S5 independently; we
        # apply the same checks to S1 too, which is AC-1/2/3's literal text).
        is($rc, $scen->{expect_rc}, "$label / $scen_name ($scen->{label}): exit code is $scen->{expect_rc}");
        ok($scen->{expect_out}->($out), "$label / $scen_name: stdout matches expectation")
            or diag("stdout was: " . (length($out) > 500 ? substr($out, 0, 500) . '...' : $out));
        ok($scen->{expect_err}->($err), "$label / $scen_name: stderr matches expectation")
            or diag("stderr was: " . (length($err) > 500 ? substr($err, 0, 500) . '...' : $err));

        # AC-4: only meaningful for bare-name (S1), but harmless to check for
        # all styles — none of them should ever show the ENOTDIR symptom.
        assert_no_enotdir_symptoms("$label / $scen_name", $rc, $err);
    }

    # AC-5: S1-S5 pairwise identical to S3 (reference), per scenario.
    my $ref = $triples{'S3 absolute, cwd=scripts dir'};
    for my $style (@STYLES) {
        my ($label) = @$style;
        next if $label eq 'S3 absolute, cwd=scripts dir';
        is_deeply($triples{$label}, $ref,
            "$scen_name: $label produces the SAME (exit, stdout, stderr) triple as S3 (reference)");
    }
}

done_testing();
