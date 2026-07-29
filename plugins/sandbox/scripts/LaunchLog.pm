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

1;
