#!/usr/bin/env perl
# bp-hook-probe.pl — diagnostic hook-payload logger for blueprint
# hook-continuity-remake, package 01-harness-facts. Registered NOWHERE in
# this repo (blueprint spec, local) -- it is invoked directly by scratch
# experiment harnesses (outside the repo, per the spec) and by
# plugins/butler/tests/t/hook-probe-logger.t, and only there. It exists to
# capture the RAW bytes of a Claude Code hook payload verbatim, for the
# measurements recorded in plugins/butler/docs/harness-facts.md.
#
# Usage (as a Claude Code command hook):
#   CCPRAXIS_HOOK_PROBE_LOG=<path> perl <abs>/bp-hook-probe.pl
#
# Contract, enforced end to end by this file's structure:
#   - stdin  : the hook payload, read to EOF in raw/binary mode. Never
#              parsed, validated, re-encoded or pretty-printed.
#   - stdout : never written, on any path.
#   - stderr : never written by this script's own logic, on any path
#              ($SIG{__WARN__} is a no-op and the whole body runs inside
#              eval). Perl's own startup (e.g. a bad LC_ALL locale) can still
#              write to stderr before this script's code ever runs -- that
#              is outside this script's control.
#   - exit   : always 0.
#   - argv   : ignored entirely.
#   - CCPRAXIS_HOOK_PROBE_LOG unset or empty: stdin is still drained, but
#     nothing is written and no file is created. Deliberately NOT a BP_*
#     name: Decision 42 scrubs BP_* (and this package's scratch harness also
#     scrubs CCPRAXIS_*) from nested sessions, so callers must supply this
#     variable inline in the hook command string rather than rely on
#     inheriting it.
#   - Line construction: strip every trailing \r/\n byte from the payload,
#     then append exactly one "\n". If nothing is left after stripping
#     (stdin was empty, or held only CR/LF), nothing is written and no file
#     is created.
#   - Append only, never truncate. The file is created if missing; parent
#     directories are NEVER created. If the parent is missing, if the target
#     is a directory, or the open/lock/write/close fails for any reason,
#     nothing is written and nothing is printed -- exit is still 0.
#   - Target hardening (red-team M1/L1): the target must resolve to a plain
#     regular file once opened (checked on the filehandle, not the path, to
#     avoid a TOCTOU race). A FIFO, device, or other special file is refused
#     silently rather than risking a hang until the hook timeout. Known
#     Windows reserved device names (CON, PRN, AUX, NUL, COMn, LPTn) and any
#     path under /dev/ are refused before ever touching the filesystem, since
#     opening those by name can create an undeletable literal file or hand
#     the payload back to the harness via stdout/stderr.
#   - Concurrency: flock(LOCK_EX | LOCK_NB) before writing, retried up to 50
#     times at a 20 ms interval (~1-2 s total, subject to OS sleep
#     granularity). If still unlocked after that, write anyway. The whole
#     line goes out in one syswrite call so concurrent invocations never
#     interleave within a line.
#
# Out of scope, deliberately: no timestamp, tag, filter or JSON validation
# -- any of those would break "verbatim".

use strict;
use warnings;
use Fcntl qw(O_WRONLY O_APPEND O_CREAT O_NONBLOCK LOCK_EX LOCK_NB);
use Time::HiRes qw(sleep);

$SIG{__WARN__} = sub { };

eval {
    binmode(STDIN, ':raw');
    local $/;
    my $payload = <STDIN>;
    $payload = '' unless defined $payload;

    # Strip every trailing \r/\n byte, then append exactly one "\n".
    $payload =~ s/[\r\n]+\z//;
    if ($payload ne '') {
        my $log = $ENV{CCPRAXIS_HOOK_PROBE_LOG};
        if (defined $log && $log ne '') {
            my $line = $payload . "\n";

            # Refuse known-unsafe targets before touching the filesystem.
            my ($base) = $log =~ m{([^/\\]+)\z};
            $base = $log unless defined $base;
            my $is_dev_path   = ($log =~ m{^/dev/});
            my $is_device_name = ($base =~ /\A(?:CON|PRN|AUX|NUL|COM\d|LPT\d)(?:\..*)?\z/i);

            if (!$is_dev_path && !$is_device_name) {
                # O_NONBLOCK: on a FIFO with no reader, this makes the open
                # fail (ENXIO) instead of hanging until a reader shows up or
                # the hook timeout fires. It has no effect on a regular file.
                if (sysopen(my $fh, $log, O_WRONLY | O_APPEND | O_CREAT | O_NONBLOCK, 0644)) {
                    binmode($fh, ':raw');

                    # Only write to a plain regular file. Tested on the
                    # filehandle, not the path, so there is no TOCTOU window
                    # between the check and the write.
                    if (-f $fh) {
                        for (1 .. 50) {
                            last if flock($fh, LOCK_EX | LOCK_NB);
                            sleep(0.02);
                        }
                        # Write regardless of whether the lock was acquired
                        # (spec: "if the lock is still not held, it writes
                        # anyway").
                        syswrite($fh, $line);
                    }
                    close($fh);
                }
            }
        }
    }
};

exit 0;
