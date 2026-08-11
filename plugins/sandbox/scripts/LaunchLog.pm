package LaunchLog;
# LaunchLog — the sandbox launcher's durable, per-launch diagnostic log (B1).
#
# One JSON-line-per-event stream, autoflushed, written to a distinct file per
# launch under the project's gitignored data dir
# (<project>/.ccpraxis-local-data/claude-home/sandbox-logs/<launch-id>.log). It is the source of
# truth the TUI dashboard (B2) renders. Line-flushed JSON means killing the
# launcher mid-run leaves a readable log up to the failure: every event is a
# complete line on disk the instant it is emitted.
#
# Kept dependency-light (JSON::PP is core) and decoupled from butler — the
# sandbox plugin stands alone; it does not reach into plugins/butler.
#
# UTF-8 / André-path safety: launcher paths are opaque OS byte strings that are
# already UTF-8 (e.g. "André" = ...C3 A9...). We encode JSON WITHOUT the utf8
# flag and write to a :raw handle, so those bytes pass straight through. Setting
# JSON's utf8 flag (or writing to an :encoding handle) would treat each byte as
# Latin-1 and re-encode it to "Ã©" — the exact corruption the global rules warn
# about. So: no utf8 flag, :raw handle, bytes preserved.

use strict;
use warnings;
use POSIX qw(strftime);
use JSON::PP ();

# format_event($type, \%fields, $epoch, $pid) -> a single JSON line (no newline)
# PURE: no I/O. Canonical (sorted keys) so output is deterministic for tests. The
# ts/pid/type are always present; caller fields are merged in (and win on a clash,
# which lets a caller override e.g. ts in a test). Returns a byte string.
sub format_event {
    my ($type, $fields, $epoch, $pid) = @_;
    $epoch = time   unless defined $epoch;
    $pid   = $$     unless defined $pid;
    my %rec = (
        ts   => strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($epoch)),
        pid  => $pid,
        type => (defined $type ? "$type" : "event"),
    );
    if (ref $fields eq 'HASH') { $rec{$_} = $fields->{$_} for keys %$fields; }
    # No utf8 flag (see header) — byte strings pass through unmodified.
    return JSON::PP->new->canonical->encode(\%rec);
}

# open_log($path) -> $fh | undef
# Open the per-launch log for append-style writing (truncate: one file per
# launch, named uniquely), autoflushed. Creates the parent dir. Returns undef on
# failure so the launcher degrades to "no log" rather than dying — diagnostics
# must never take down the thing they diagnose.
sub open_log {
    my ($path) = @_;
    return undef unless defined $path && length $path;
    (my $dir = $path) =~ s{[\\/][^\\/]+$}{};
    if (length $dir && !-d $dir) {
        require File::Path;
        eval { File::Path::make_path($dir); 1 } or return undef;
    }
    open my $fh, '>:raw', $path or return undef;
    my $old = select($fh); $| = 1; select($old);   # autoflush this handle
    return $fh;
}

# event($fh, $type, \%fields) -> 1 if written, 0 if no-op
# No-op (returns 0) when $fh is undef, so every call site is safe even if the log
# failed to open. Autoflush + a trailing newline => crash-readable.
sub event {
    my ($fh, $type, $fields) = @_;
    return 0 unless $fh;
    print {$fh} format_event($type, $fields), "\n";
    return 1;
}

# close_log($fh) — flush + close, tolerant of undef.
sub close_log {
    my ($fh) = @_;
    return unless $fh;
    close $fh;
}

# recent_logs($dir, $n, $exclude) -> @paths (spec S2.1)
# Enumerate the newest-$n prior "launch-*.log" files in $dir (mtime descending,
# basename-descending tie-break), excluding $exclude (compared as a basename,
# BEFORE truncation). TOTAL: never dies/warns; opendir/readdir only, never glob
# (a project path may contain spaces or non-ASCII bytes).
sub recent_logs {
    my ($dir, $n, $exclude) = @_;
    return () unless defined $dir && length $dir;
    $n = 5 unless defined $n && $n =~ /^\d+$/ && $n >= 1;
    (my $base = $dir) =~ s{[\\/]+$}{};
    my @cand;
    my $ok = eval {
        opendir(my $dh, $base) or return 0;
        my @names = readdir($dh);
        closedir($dh);
        for my $name (@names) {
            next unless defined $name && $name =~ /^launch-[^.]+\.log$/;
            next if defined $exclude && length $exclude && $name eq $exclude;
            my $path = "$base/$name";
            next if -l $path;
            next unless -f $path;
            my $mtime = (stat($path))[9];
            next unless defined $mtime;
            push @cand, [ $mtime, $name, $path ];
        }
        1;
    };
    return () unless $ok;
    @cand = sort { $b->[0] <=> $a->[0] || $b->[1] cmp $a->[1] } @cand;
    splice(@cand, $n) if @cand > $n;
    return map { $_->[2] } @cand;
}

# ---------------------------------------------------------------------------
# Retention.
#
# Nothing ever removed anything from sandbox-logs/, so it grew without bound —
# one JSON log plus one raw transcript per launch, forever. The operator asked
# for the last 10 launches and nothing older.
#
# Retention is keyed on the LAUNCH ID, not on individual files, because one
# launch owns several: `launch-<id>.log`, `launch-<id>.transcript.log`, and now
# `launch-<id>.bootstrap.log`. Pruning file-by-file would happily keep a
# transcript whose JSON log had already been deleted — half a launch record,
# which is worse than none because it reads as complete.
#
# `bootstrap-<stamp>-<pid>.log` files are written by bootstrap.pl before any
# launch id exists, so they are retained as their own newest-$keep series.

# _launch_id_of($basename) -> id | undef
# `launch-20260806T000150Z-1860.transcript.log` -> `20260806T000150Z-1860`.
sub _launch_id_of {
    my ($name) = @_;
    return undef unless defined $name;
    return undef unless $name =~ /\Alaunch-([^.\\\/]+)\./;
    return $1;
}

# group_launch_files(\@names) -> { id => [names...] }, plus a BOOTSTRAP key for
# the standalone bootstrap logs. PURE, so the grouping rule is testable without
# a filesystem.
sub group_launch_files {
    my ($names) = @_;
    my %g;
    for my $name (@{ $names || [] }) {
        next unless defined $name && length $name;
        if (my $id = _launch_id_of($name)) { push @{ $g{$id} }, $name; next }
        if ($name =~ /\Abootstrap-([^.\\\/]+)\.log\z/) { push @{ $g{"\0bootstrap:$1"} }, $name }
    }
    return \%g;
}

# prune_logs($dir, $keep, $current_id) -> @removed
# Keep the newest $keep launch-id groups (the current launch is ALWAYS kept and
# always counts as one of them) and the newest $keep bootstrap logs; unlink the
# rest. TOTAL: never dies. A retention failure must never take down a launch, so
# every error path simply stops pruning.
sub prune_logs {
    my ($dir, $keep, $current_id) = @_;
    return () unless defined $dir && length $dir;
    $keep = 10 unless defined $keep && $keep =~ /\A\d+\z/ && $keep >= 1;
    (my $base = $dir) =~ s{[\\/]+\z}{};

    my @removed;
    my $ok = eval {
        opendir(my $dh, $base) or return 0;
        my @names = readdir($dh);
        closedir($dh);

        my $groups = group_launch_files(\@names);

        # Rank a group by its newest member's mtime, with the group key as a
        # deterministic tie-break (ids embed a UTC stamp, so key order is
        # chronological and a same-second tie still resolves stably).
        my @ranked;
        for my $key (keys %$groups) {
            my $newest = 0;
            my $any = 0;
            for my $n (@{ $groups->{$key} }) {
                my $p = "$base/$n";
                next if -l $p;
                next unless -f $p;
                my $m = (stat($p))[9];
                next unless defined $m;
                $any = 1;
                $newest = $m if $m > $newest;
            }
            next unless $any;
            push @ranked, [ $newest, $key ];
        }

        # Bootstrap logs are their own series; a first-time setup record must not
        # be evicted just because ten ordinary launches happened afterwards.
        my @launch    = grep { $_->[1] !~ /\A\0bootstrap:/ } @ranked;
        my @bootstrap = grep { $_->[1] =~ /\A\0bootstrap:/ } @ranked;

        for my $set (\@launch, \@bootstrap) {
            my @s = sort { $b->[0] <=> $a->[0] || $b->[1] cmp $a->[1] } @$set;
            my $kept = 0;
            for my $entry (@s) {
                my $key = $entry->[1];
                # The launch writing right now is never a candidate: its handles
                # are open and its record is the one being created.
                if (defined $current_id && length $current_id && $key eq $current_id) {
                    $kept++;
                    next;
                }
                if ($kept < $keep) { $kept++; next }
                for my $n (@{ $groups->{$key} }) {
                    my $p = "$base/$n";
                    next if -l $p;
                    next unless -f $p;
                    push @removed, $p if unlink $p;
                }
            }
        }
        1;
    };
    return () unless $ok;
    return @removed;
}

# merge_sessions(\@groups, %opts) -> \@merged (spec S2.2)
# Pure merge of per-session item groups (oldest first, LAST group is the
# current session) into one chronological list with an optional
# session-boundary marker and a total cap. Items are OPAQUE -- never
# inspected, copied or stringified. TOTAL: never dies/warns.
sub merge_sessions {
    my ($groups, @rest) = @_;
    my %opts = (@rest % 2 == 0) ? @rest : ();
    my @g = (ref $groups eq 'ARRAY') ? @$groups : ();
    @g = map { (ref $_ eq 'ARRAY') ? $_ : [] } @g;
    return [] unless @g;

    my @cur  = @{ pop @g };
    my @hist = map { @$_ } @g;

    my $max = $opts{max};
    $max = 50 unless defined $max && $max =~ /^\d+$/ && $max >= 1;

    my $marker = $opts{marker};
    my $want_marker = (defined $marker) && @hist && @cur;

    my $room = $max - scalar(@cur);
    $room -= 1 if $want_marker;

    @hist = () if $room <= 0;
    @hist = @hist[ -$room .. -1 ] if $room > 0 && @hist > $room;

    $want_marker = 0 unless @hist;

    my @out = (@hist, ($want_marker ? ($marker) : ()), @cur);
    @out = @out[ -$max .. -1 ] if @out > $max;

    return \@out;
}

# merge_by_key($sources, key => $keyfn, max => $n) -> \@merged (spec S1/S1.1,
# s16-fleet-event-source). The cross-source, best-effort-chronological
# interleave that `merge_sessions` (above) deliberately cannot do, because it
# never inspects an item. `merge_by_key` doesn't either -- ONLY the caller's
# `key` coderef does, so s13's opacity guarantee is unaffected.
#
# $sources : arrayref of arrayrefs; each inner array is ONE source's items,
#            already in that source's own authoritative append order (e.g. one
#            array per log file, oldest-appended first).
# key      : REQUIRED coderef; given an item, returns a comparable scalar
#            (epoch seconds) or undef when it cannot be determined. Required
#            (not defaulted) so a caller can't silently fall back to
#            append-order-only merging while believing it's time-ordered.
# max      : optional total cap -- keeps the most recent (trailing) $max items.
#
# THE ORDERING RULING (spec S1): within one source, append order is NEVER
# violated -- a clock that jumps backwards mid-source must not reorder that
# source's own items. Across sources, ordering is best-effort by timestamp.
# This holds structurally, not by sorting: at every step we only ever compare
# the CURRENT HEAD of each source (an N-way merge, like mergesort's merge
# step) and advance the winning source's cursor by one. Two items from the
# SAME source are therefore never compared against each other -- one of them
# is always still "behind" its source's own head when the other is emitted --
# so no key, however skewed, can ever reorder a source's own sequence. This is
# also why a single source degenerates to pure append order regardless of its
# keys (proven by the oracle's C4a).
#
# STABLE on ties/undef/skew: when two current heads don't have a strictly
# smaller key than the running best, the earlier-found head (lower $sources
# index) keeps precedence, so equal or unknown keys don't reshuffle relative
# to a deterministic, source-order fallback.
#
# TOTAL: never dies, never warns. A $keyfn that dies on some item is caught
# per-item (that item's key degrades to undef) rather than aborting the merge.
sub merge_by_key {
    my ($sources, %opts) = @_;
    my $keyfn = $opts{key};
    return [] unless ref $sources eq 'ARRAY';
    return [] unless ref $keyfn eq 'CODE';

    my @srcs = map { (ref $_ eq 'ARRAY') ? $_ : [] } @$sources;
    my @pos  = (0) x scalar(@srcs);

    my @out;
    while (1) {
        my $best_i;
        my $best_key;
        for my $i (0 .. $#srcs) {
            next if $pos[$i] > $#{ $srcs[$i] };
            my $item = $srcs[$i][ $pos[$i] ];
            my $k = eval { $keyfn->($item) };
            $k = undef if $@;
            if (!defined $best_i) {
                $best_i  = $i;
                $best_key = $k;
                next;
            }
            if (defined $k && (!defined $best_key || $k < $best_key)) {
                $best_i   = $i;
                $best_key = $k;
            }
        }
        last unless defined $best_i;
        push @out, $srcs[$best_i][ $pos[$best_i] ];
        $pos[$best_i]++;
    }

    my $max = $opts{max};
    if (defined $max && $max =~ /^\d+$/ && $max >= 1 && @out > $max) {
        @out = @out[ -$max .. -1 ];
    }
    return \@out;
}

1;
