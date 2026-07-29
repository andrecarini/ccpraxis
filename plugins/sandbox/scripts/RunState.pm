package RunState;
# RunState.pm — pure orchestrator/run-state summarizer for the dashboard.
#
# Walks a blueprints root (`<project>/.ccpraxis-local-data/blueprints/`) and
# builds one summary struct per blueprint that has a decodable
# `runs/registry.json`, cross-referencing the run markers (`.orchestrator`,
# `.paused`, `.shutdown`), the `needs-you/` decision queue, and each
# package's ledger frontmatter `status:` line (authoritative over the
# registry's own `status`) — spec `07-run-state-panel-spec.md`, s10 of
# blueprint sandbox-butler-overhaul.
#
# Pure, in the SessionFilter sense: no console I/O (no print/warn/die), no
# spawning, no writes, no globals mutated. Read-only, and only under the
# root/dir it is handed. Total: every public sub returns its declared type
# for every input, including undef, refs where scalars are expected, hostile
# bytes, symlinks, unreadable files and malformed JSON — nothing propagates
# an exception; all decoding happens inside eval {}.
#
# Discovery uses opendir/readdir — glob is forbidden anywhere in this file —
# so a project path containing spaces or non-ASCII bytes (André) is safe.
# Nothing is exported; callers use fully-qualified names
# (RunState::summarize(...)), exactly as launcher.pl calls SessionFilter:: /
# BackpackApproval::. No time()/localtime/gmtime/clock read. No kill, no
# process probing — a recorded PID is reported verbatim, never liveness-
# checked.
#
# See specs/07-run-state-panel-spec.md (S2) for the full field-by-field
# contract; the struct's 11-key set is CLOSED and stable (s11 depends on it).

use strict;
use warnings;
use JSON::PP ();

our $MAX_REGISTRY_BYTES = 4 * 1024 * 1024;   # 4 MiB, mirrors SessionFilter
our $MAX_LEDGER_BYTES   = 65536;             # 64 KiB of a package ledger is plenty for frontmatter
our $MAX_MARKER_BYTES   = 4096;              # .orchestrator / .paused are tiny

# _read_capped($path, $cap) -> $bytes|undef (private)
#
# Reads a plain file, capped at $cap+1 bytes so an over-cap file is detected
# without slurping it whole. Returns undef for: not a plain file, open
# failure, empty file, or a file whose length exceeds $cap ("a file larger
# than its cap is treated exactly as an unreadable file").
sub _read_capped {
    my ($path, $cap) = @_;
    return undef unless defined $path && -f $path;
    open my $fh, '<:raw', $path or return undef;
    my $blob = '';
    my $n = read($fh, $blob, $cap + 1);
    close $fh;
    return undef if !defined $n || $n == 0 || $n > $cap;
    return $blob;
}

# blueprint_dirs($blueprints_root) -> @dirs
#
# Enumerates candidate blueprint directories one level deep, mirroring
# SessionFilter::registry_paths. undef/zero-length/non-existent-dir root ->
# (). opendir failure -> (). Skips . and .., skips symlinks, skips non-dirs.
# Returns "$root/$entry" in ascending sort order of the entry name. Never
# dies.
sub blueprint_dirs {
    my ($root) = @_;
    return () unless defined $root && !ref($root) && length($root) && -d $root;
    opendir(my $dh, $root) or return ();
    my @out;
    for my $e (sort readdir $dh) {
        next if $e eq '.' || $e eq '..';
        next if -l "$root/$e";
        next unless -d "$root/$e";
        push @out, "$root/$e";
    }
    closedir $dh;
    return @out;
}

# _safe_pkg_name($pkg) -> 0|1 (private)
#
# A package key is "safe" (eligible for a packages/<pkg>.md ledger read) iff
# it is a defined, non-ref scalar containing none of '/', '\', NUL; does not
# begin with '.'; and is no longer than 128 bytes. Anything else falls
# through to the registry status without ever attempting an open().
sub _safe_pkg_name {
    my ($pkg) = @_;
    return 0 unless defined $pkg && !ref($pkg) && length($pkg);
    return 0 if $pkg =~ /[\/\\\x00]/;
    return 0 if $pkg =~ /^\./;
    return 0 if length($pkg) > 128;
    return 1;
}

# _normalize_status($raw) -> $status (private)
#
# Trims leading/trailing whitespace, lowercases. Accepts only
# /^[a-z][a-z0-9_-]{0,31}$/; anything else (undef, a ref, '', "12", a 200-
# char blob) becomes the unknown status ''.
sub _normalize_status {
    my ($raw) = @_;
    return '' if !defined $raw || ref $raw;
    $raw =~ s/^\s+|\s+$//g;
    $raw = lc $raw;
    return ($raw =~ /^[a-z][a-z0-9_-]{0,31}$/) ? $raw : '';
}

# _ledger_status($blueprint_dir, $pkg) -> $status (private, '' when none)
#
# Reads "$blueprint_dir/packages/$pkg.md", capped at $MAX_LEDGER_BYTES. The
# ledger read is skipped entirely (no open attempted) for an unsafe $pkg. The
# file must begin with a line that is exactly '---'; subsequent lines are
# scanned until the next line that is exactly '---' or EOF; within that
# block, the first line matching /^status:\s*(.*?)\s*$/ supplies the raw
# status, which is then normalised.
sub _ledger_status {
    my ($blueprint_dir, $pkg) = @_;
    return '' unless _safe_pkg_name($pkg);
    my $blob = _read_capped("$blueprint_dir/packages/$pkg.md", $MAX_LEDGER_BYTES);
    return '' unless defined $blob;
    my @lines = split /\n/, $blob, -1;
    return '' unless @lines && $lines[0] eq '---';
    my $raw_status;
    for (my $i = 1; $i <= $#lines; $i++) {
        my $line = $lines[$i];
        last if $line eq '---';
        if (!defined $raw_status && $line =~ /^status:\s*(.*?)\s*$/) {
            $raw_status = $1;
        }
    }
    return _normalize_status($raw_status);
}

# _effective_status($blueprint_dir, $pkg, $entry) -> $status (private)
#
# S2.5: the ledger's normalised status wins whenever it is non-empty;
# otherwise the registry entry's 'status' field is used (only when $entry is
# a HASH), normalised the same way.
sub _effective_status {
    my ($blueprint_dir, $pkg, $entry) = @_;
    my $ledger_status = _ledger_status($blueprint_dir, $pkg);
    return $ledger_status if length $ledger_status;
    my $raw = (ref($entry) eq 'HASH') ? $entry->{status} : undef;
    return _normalize_status($raw);
}

# _orchestrator_pid($path) -> $pid|undef (private)
#
# The first integer found in the (capped) file content, or undef when the
# file is absent, unreadable, over cap, or holds no integer at all.
sub _orchestrator_pid {
    my ($path) = @_;
    my $blob = _read_capped($path, $MAX_MARKER_BYTES);
    return undef unless defined $blob;
    return ($blob =~ /(\d+)/) ? ($1 + 0) : undef;
}

# _paused_info($path) -> ($paused_manual, $paused_reason) (private)
#
# $paused_manual is 1 iff the (capped) file decodes as a HASH whose 'manual'
# key is truthy; 0 otherwise (missing file, unreadable, over cap, malformed
# JSON, non-HASH, or falsy 'manual'). $paused_reason is the 'reason' field
# only when it is a defined, non-ref, non-empty scalar; else undef. Note
# this is independent of `state` classification (S2.3 is existence-only).
sub _paused_info {
    my ($path) = @_;
    my $blob = _read_capped($path, $MAX_MARKER_BYTES);
    return (0, undef) unless defined $blob;
    my $data = eval { JSON::PP->new->decode($blob) };
    return (0, undef) unless ref($data) eq 'HASH';
    my $manual = $data->{manual} ? 1 : 0;
    my $reason = $data->{reason};
    $reason = (defined($reason) && !ref($reason) && length($reason)) ? $reason : undef;
    return ($manual, $reason);
}

# _count_decisions($needs_you_dir) -> $n (private)
#
# opendir $needs_you_dir; counts entries that are plain files, skipping any
# name beginning with '.' and any name ending in '.tmp'. Missing directory,
# or opendir failure -> 0. Deliberately identical to launcher.pl's
# _count_needs_you inner loop (AC-25).
sub _count_decisions {
    my ($dir) = @_;
    return 0 unless -d $dir;
    opendir(my $dh, $dir) or return 0;
    my $n = 0;
    for my $f (readdir $dh) {
        next if $f =~ /^\./;
        next if $f =~ /\.tmp$/;
        $n++ if -f "$dir/$f";
    }
    closedir $dh;
    return $n;
}

# summarize_dir($blueprint_dir) -> \%summary | undef
#
# Builds the S2.2 summary for ONE blueprint directory (the directory that
# *contains* runs/). undef (the blueprint is skipped entirely) when:
# $blueprint_dir is undef/zero-length/not a directory; runs/ is not a
# directory; runs/registry.json is not a plain file, is unreadable, is
# empty, or exceeds $MAX_REGISTRY_BYTES; or the registry body does not
# decode as a JSON HASH. Never dies.
sub summarize_dir {
    my ($blueprint_dir) = @_;
    return undef unless defined $blueprint_dir && !ref($blueprint_dir)
        && length($blueprint_dir) && -d $blueprint_dir;

    my $runs_dir = "$blueprint_dir/runs";
    return undef unless -d $runs_dir;

    my $blob = _read_capped("$runs_dir/registry.json", $MAX_REGISTRY_BYTES);
    return undef unless defined $blob;
    my $data = eval { JSON::PP->new->decode($blob) };
    return undef unless ref($data) eq 'HASH';

    my $pkgs = (ref($data->{packages}) eq 'HASH') ? $data->{packages} : {};
    my $packages_total = scalar keys %$pkgs;

    my $packages_done = 0;
    my $running_count  = 0;
    my $current_package;
    for my $pkg (sort keys %$pkgs) {
        my $status = _effective_status($blueprint_dir, $pkg, $pkgs->{$pkg});
        $packages_done++ if $status eq 'done';
        if ($status eq 'running') {
            $running_count++;
            $current_package = $pkg unless defined $current_package;
        }
    }

    my $has_shutdown = -e "$runs_dir/.shutdown";
    my $has_paused   = -e "$runs_dir/.paused";
    my $has_orch     = -e "$runs_dir/.orchestrator";
    my $state = $has_shutdown ? 'parked'
              : $has_paused   ? 'paused'
              : $has_orch     ? 'running'
              :                 'idle';

    my $running_coordinators = $has_orch ? $running_count : 0;

    my $orchestrator_pid = _orchestrator_pid("$runs_dir/.orchestrator");
    my ($paused_manual, $paused_reason) = _paused_info("$runs_dir/.paused");
    my $decisions_waiting = _count_decisions("$runs_dir/needs-you");

    my $bp_name = $blueprint_dir;
    $bp_name =~ s{/+$}{};
    $bp_name = (split m{/}, $bp_name)[-1];

    return {
        blueprint            => $bp_name,
        runs_dir             => $runs_dir,
        state                => $state,
        orchestrator_pid     => $orchestrator_pid,
        paused_manual        => $paused_manual,
        paused_reason        => $paused_reason,
        packages_total       => $packages_total,
        packages_done        => $packages_done,
        current_package      => $current_package,
        running_coordinators => $running_coordinators,
        decisions_waiting    => $decisions_waiting,
    };
}

# summarize($blueprints_root) -> \@summaries
#
# Always returns an ARRAYREF ([] when there is nothing to report). Never
# undef, never dies, for any input whatsoever. Equivalent to
# [ grep { defined } map { summarize_dir($_) } blueprint_dirs($root) ].
# Per-blueprint isolation: one blueprint with a malformed registry never
# suppresses, alters, or reorders any sibling's summary. Order is ascending
# by blueprint directory name (inherited from blueprint_dirs).
sub summarize {
    my ($root) = @_;
    my @out;
    for my $dir (blueprint_dirs($root)) {
        my $s = summarize_dir($dir);
        push @out, $s if defined $s;
    }
    return \@out;
}

1;
