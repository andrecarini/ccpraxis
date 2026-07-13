package SandboxLock;
# 04-build-race-lock — generalised mkdir-based lock, parameterised by directory.
#
# Multiple concurrently-held locks (per-project lock + global image-build lock)
# are tracked in the module-scope %OWNED hash so release_all() frees everything
# on Ctrl-C / END, regardless of which lock was acquired last.
#
# API:
#   SandboxLock::acquire($dir, %opts)  -> 1 (got it) | 0 (timed out)
#   SandboxLock::release($dir)
#   SandboxLock::release_all()
#
# acquire() does NOT print or exit on timeout — the CALLER decides.
# opts: timeout (default 10s), poll (default 1s), windows (bool, informational).

use strict;
use warnings;
use File::Path ();

my %OWNED;

# acquire($dir, %opts) -> 1 | 0
sub acquire {
    my ($dir, %opts) = @_;
    my $timeout = defined $opts{timeout} ? $opts{timeout} : 10;
    my $poll    = defined $opts{poll}    ? $opts{poll}    : 1;
    # $opts{windows} is informational — no behaviour difference currently.

    my $elapsed = 0;
    while (1) {
        if (mkdir $dir) {
            # Acquired — write pid file and record ownership.
            if (open my $fh, '>', "$dir/pid") {
                print $fh $$;
                close $fh;
            }
            $OWNED{$dir} = 1;
            return 1;
        }

        # Lock dir already exists — check for a dead owner.
        my $pid_file = "$dir/pid";
        if (-f $pid_file) {
            if (open my $fh, '<', $pid_file) {
                my $owner = <$fh>;
                close $fh;
                chomp $owner if defined $owner;
                if (defined $owner && length $owner && $owner =~ /^\d+$/) {
                    my $alive = kill(0, $owner) ? 1 : 0;
                    if (!$alive) {
                        # Stale lock from a crashed owner — reclaim and retry immediately.
                        File::Path::remove_tree($dir, { safe => 1, error => \my $err });
                        next;
                    }
                }
            }
        }

        # Live owner (or unreadable pid) — check timeout.
        if ($elapsed >= $timeout) {
            return 0;
        }

        # timeout => 0: must return 0 promptly, no sleep.
        last if $timeout == 0;

        sleep $poll;
        $elapsed += $poll;
    }
    return 0;
}

# release($dir) — remove the lock dir if we own it.
sub release {
    my ($dir) = @_;
    return unless $OWNED{$dir};
    File::Path::remove_tree($dir, { safe => 1, error => \my $err });
    delete $OWNED{$dir};
}

# release_all() — release every lock currently held by this process.
sub release_all {
    for my $dir (keys %OWNED) {
        release($dir);
    }
}

1;
