#!/usr/bin/env perl
# ccpraxis-mergeback.pl -- host CLI for merge-back and discard of the
# sandboxed ccpraxis work-copy (git worktree).
#
# Subcommands:
#   merge   -- fleet-guarded, confirm-gated merge of the work-copy branch
#              into live main; shows diff before committing.
#   discard -- fleet-guarded, confirm-gated removal of the work-copy
#              WITHOUT merging (worktree remove + branch -D).
#
# GUARD FIRST, ALWAYS: mergeback_guard is called before any git operation
# for both subcommands. A 'blocked' result exits nonzero immediately.
#
# House rules:
#   - List-form git only (system('git',...) / open '-|','git',...).
#     No qx{}, no backtick, no shell strings.
#   - Commits carry no trailer lines (house rule).
#   - No cd-chaining; use git -C throughout.
#   - MSYS2_ARG_CONV_EXCL='*' set around all git invocations.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin";
use File::Basename qw(dirname basename);
use File::Spec ();
use Cwd qw(abs_path);
use Digest::MD5 ();
use MountSpec qw(winify_path);
use CcpraxisWorkCopy qw(
    mergeback_guard
    mergeback_plan
    discard_plan
    default_worktree_path
);

# Resolve $LIVE from __FILE__ — same depth as launcher.pl:221
# plugins/sandbox/scripts/ccpraxis-mergeback.pl -> scripts -> sandbox -> plugins -> ccpraxis
my $LIVE = do {
    my $h = __FILE__;
    $h =~ s|\\|/|g;
    my $s = dirname($h);
    dirname(dirname(dirname($s)));
};

# Resolve worktree path
my $wt = default_worktree_path({ live_install_hint => $LIVE });
unless (defined $wt) {
    print "STATUS: cannot determine worktree path (no HOME/USERPROFILE)\n";
    exit 1;
}

# Build container name (same derivation as launcher.pl:_container_name_for)
sub _container_name_for {
    my ($raw_path) = @_;
    my $p = abs_path($raw_path) // $raw_path;
    $p =~ s|\\|/|g;
    $p =~ s|/+$||;
    $p = winify_path($p);
    my $n = lc(basename($p));
    $n =~ s/ /-/g;
    return "claude-${n}-" . substr(Digest::MD5->new->add($p)->hexdigest, 0, 8);
}

my $container_name = _container_name_for($wt);

# _freshest_marker_mtime: newest mtime of <wt>/.ccpraxis-local-data/blueprints/*/runs/.orchestrator
# Uses opendir/readdir -- NO glob (e-path safe).
sub _freshest_marker_mtime {
    my ($worktree) = @_;
    my $base = "$worktree/.ccpraxis-local-data/blueprints";
    return undef unless -d $base;
    my $newest;
    opendir(my $bd, $base) or return undef;
    for my $bp (readdir $bd) {
        next if $bp eq '.' || $bp eq '..';
        my $marker = "$base/$bp/runs/.orchestrator";
        next unless -f $marker;
        my $mt = (stat($marker))[9];
        $newest = $mt if defined $mt && (!defined $newest || $mt > $newest);
    }
    closedir $bd;
    return $newest;
}

# _detect_container_cli() -> the container engine binary the fleet actually runs in.
# MUST match launcher.pl:_detect_container_cli (launcher.pl:83-91) — the guard has to
# query the SAME engine the sandbox launched with, or it silently sees "not running"
# on a docker host and could clear over a LIVE fleet (red-team p03 HIGH).
sub _detect_container_cli {
    my $windows = ($^O =~ /^(MSWin32|cygwin|msys)$/);
    for my $candidate ($windows ? ('docker.exe', 'podman.exe') : ('docker', 'podman')) {
        my $rc = system("$candidate --version > /dev/null 2>&1");
        return $candidate if $rc == 0;
    }
    return undef;
}

# _podman_name_running($name) -> 0|1  (queries the DETECTED engine, not bare podman)
sub _podman_name_running {
    my ($name) = @_;
    return 0 unless defined $name && length $name;
    my $cli = _detect_container_cli();
    # No engine detected: liveness UNKNOWN -> fail safe (assume live). fleet_live
    # treats a throwing probe as live, so signal the unknown by throwing.
    die "no container engine (docker/podman) found — cannot verify fleet liveness\n"
        unless defined $cli;
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
    my $pid = open(my $fh, '-|', $cli, 'ps', '--filter', "name=$name", '--format', '{{.Names}}');
    return 0 unless $pid;
    local $/;
    my $out = <$fh>;
    close $fh;
    return (defined $out && $out =~ /\S/) ? 1 : 0;
}

# --yes flag: skips only the tty confirmation prompt, NEVER the guard
my $yes = grep { $_ eq '--yes' } @ARGV;
my @plain_args = grep { $_ ne '--yes' } @ARGV;
my $subcmd = $plain_args[0] // '';

# =====================================================================
# GUARD FIRST, ALWAYS -- runs before any git op, before --yes branch
# =====================================================================
my $guard_result = mergeback_guard({
    container_name    => $container_name,
    container_running => \&_podman_name_running,
    marker_probe      => sub { _freshest_marker_mtime($wt) },
});

if ($guard_result eq 'blocked') {
    print "BLOCKED: a sandbox fleet is live against the work-copy $wt -- refusing.\n";
    exit 1;
}

# =====================================================================
# 'merge' subcommand
# =====================================================================
if ($subcmd eq 'merge') {
    my $plan = mergeback_plan({
        live              => $LIVE,
        worktree          => $wt,
        container_running => sub { 0 },   # guard already passed
        marker_probe      => sub { undef },
    });

    # Pre-check: live repo must be on main and have a clean working tree
    {
        local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
        my $branch_out = '';
        if (open my $fh, '-|', 'git', '-C', $LIVE, 'rev-parse', '--abbrev-ref', 'HEAD') {
            local $/; $branch_out = <$fh> // ''; close $fh;
        }
        chomp $branch_out;
        if ($branch_out ne 'main') {
            print "STATUS: aborted -- live repo not on a clean main\n";
            exit 2;
        }

        my $status_out = '';
        if (open my $fh, '-|', 'git', '-C', $LIVE, 'status', '--porcelain') {
            local $/; $status_out = <$fh> // ''; close $fh;
        }
        if (length($status_out =~ s/\s+//gr)) {
            print "STATUS: aborted -- live repo not on a clean main\n";
            exit 2;
        }
    }

    # Step: switch_main
    {
        local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
        system('git', '-C', $LIVE, 'switch', 'main');
    }

    # Step: merge_no_ff_no_commit
    {
        local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
        my $branch = 'ccpraxis-sandbox-workcopy';
        my $rc = system('git', '-C', $LIVE, 'merge', '--no-ff', '--no-commit', $branch);
        if ($rc != 0) {
            # Conflict: abort and stop -- no cleanup, no half-merge
            system('git', '-C', $LIVE, 'merge', '--abort');
            print "STATUS: merge aborted (conflict) -- no changes committed, work-copy kept\n";
            exit 3;
        }
    }

    # Step: show_diff (print it for the user to review)
    {
        local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
        if (open my $fh, '-|', 'git', '-C', $LIVE, 'diff', '--cached') {
            while (my $line = <$fh>) { print $line; }
            close $fh;
        }
    }

    # Step: confirm gate (tty prompt; --yes skips only this)
    unless ($yes) {
        print "Merge the above diff into live main? [y/N] ";
        my $answer = <STDIN> // '';
        chomp $answer;
        unless (lc($answer) eq 'y') {
            # Abort the staged merge and exit without committing
            local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
            system('git', '-C', $LIVE, 'merge', '--abort');
            print "STATUS: merge cancelled by user\n";
            exit 0;
        }
    }

    # Step: commit (bare -- no -m; git uses default merge message; no trailer lines)
    {
        local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
        my $rc = system('git', '-C', $LIVE, 'commit');
        if ($rc != 0) {
            print "STATUS: commit failed\n";
            exit 4;
        }
    }

    # Step: worktree_remove
    {
        local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
        system('git', '-C', $LIVE, 'worktree', 'remove', $wt);
    }

    # Step: branch_delete (safe -d; branch was just merged)
    {
        local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
        system('git', '-C', $LIVE, 'branch', '-d', 'ccpraxis-sandbox-workcopy');
    }

    print "STATUS: merged and cleaned up\n";
    exit 0;

# =====================================================================
# 'discard' subcommand
# =====================================================================
} elsif ($subcmd eq 'discard') {

    # Confirm gate (tty / --yes)
    unless ($yes) {
        print "Discard the work-copy $wt WITHOUT merging? [y/N] ";
        my $answer = <STDIN> // '';
        chomp $answer;
        unless (lc($answer) eq 'y') {
            print "STATUS: discard cancelled by user\n";
            exit 0;
        }
    }

    # Step: worktree_remove; retry with --force if it fails (uncommitted changes)
    {
        local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
        if (-d $wt) {
            my $rc = system('git', '-C', $LIVE, 'worktree', 'remove', $wt);
            if ($rc != 0) {
                print "STATUS: forcing worktree removal (uncommitted changes discarded)\n";
                system('git', '-C', $LIVE, 'worktree', 'remove', '--force', $wt);
            }
        }
        # Already gone => treat as success (idempotent)
    }

    # Step: branch_force_delete (-D; unmerged commits intentionally discarded)
    {
        local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
        my $rc = system('git', '-C', $LIVE, 'branch', '-D', 'ccpraxis-sandbox-workcopy');
        # An already-deleted branch is fine (idempotent)
    }

    print "STATUS: discarded work-copy\n";
    exit 0;

} else {
    print "Usage: ccpraxis-mergeback.pl <merge|discard> [--yes]\n";
    exit 1;
}
