package LaunchLog;
# LaunchLog — the sandbox launcher's durable, per-launch diagnostic log (B1).
#
# One JSON-line-per-event stream, autoflushed, written to a distinct file per
# launch under the project's gitignored data dir
# (<project>/.claude-data/sandbox-logs/<launch-id>.log). It is the source of
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

1;
