package SessionFilter;
# SessionFilter.pm — pure classifier for butler-spawned sessions.
#
# Cross-references every blueprint's orchestrator run registry
# (`<blueprints-root>/*/runs/registry.json`, written by butler's
# bp-lib.sh) to build the set of session UUIDs that were spawned by
# butler (coordinators/agents), so select-session.pl's picker can hide
# them by default (Decision #10) and reveal them behind a `[t]` toggle
# (Decision #14).
#
# Pure: no console I/O, no spawning, no writes, no globals mutated.
# Reads only the paths it is handed. Nothing is exported; callers use
# fully-qualified names (SessionFilter::collect_butler_sids(...)),
# exactly as launcher.pl calls BackpackApproval::....
#
# Fail-open, never fail-closed (Decision #4): every failure path here
# (module missing is handled by the caller; root missing, registry
# missing/corrupt/huge) yields fewer butler SIDs, never more, and never
# a die or a warn.

use strict;
use warnings;
use JSON::PP ();

our $MAX_REGISTRY_BYTES = 4 * 1024 * 1024;   # 4 MiB

# registry_paths($blueprints_root) -> @paths
#
# Discovers every blueprint's run registry, one level deep:
# <root>/<blueprint>/runs/registry.json. Returns paths in ascending
# `sort` order of the blueprint directory name (deterministic). Uses
# opendir/readdir (not glob) so a project path containing spaces or
# non-ASCII bytes is safe. undef/empty/non-existent/non-directory
# $root -> (). Never dies.
sub registry_paths {
    my ($root) = @_;
    return () unless defined $root && length $root && -d $root;
    opendir(my $dh, $root) or return ();
    my @out;
    for my $e (sort readdir $dh) {
        next if $e eq '.' || $e eq '..';
        next if -l "$root/$e";          # a real blueprint dir is never a symlink
        next unless -d "$root/$e";
        my $p = "$root/$e/runs/registry.json";
        push @out, $p if -f $p;
    }
    closedir $dh;
    return @out;
}

# sids_from_registry_file($path) -> @sids
#
# Extracts the butler session IDs from ONE registry file. Every failure
# path returns () and MUST NOT die, warn, or hang.
sub sids_from_registry_file {
    my ($path) = @_;
    return () unless defined $path && -f $path;
    open my $fh, '<:raw', $path or return ();
    my $blob = '';
    my $n = read($fh, $blob, $MAX_REGISTRY_BYTES + 1);
    close $fh;
    return () if !defined $n || $n == 0 || $n > $MAX_REGISTRY_BYTES;
    my $data = eval { JSON::PP->new->decode($blob) };   # never propagates
    return () unless ref $data eq 'HASH';
    my $pkgs = $data->{packages};
    return () unless ref $pkgs eq 'HASH';
    my @out;
    for my $pkg (sort keys %$pkgs) {
        my $ent = $pkgs->{$pkg};
        next unless ref $ent eq 'HASH';
        my $sid = _norm_sid($ent->{session_id});
        push @out, $sid if length $sid;
    }
    return @out;
}

# _norm_sid($v) -> $string (private)
#
# Trims surrounding whitespace, lowercases, and only accepts hex-and-
# dash strings of length >= 8, so "", "0", "none", a JSON true, or a
# nested object can never enter the butler set. Never dies, never warns.
sub _norm_sid {
    my ($v) = @_;
    return '' if !defined $v || ref $v;
    return '' if length($v) > 64;   # a UUID is 36 chars; nothing longer can pass the shape check below — avoids O(n^2) trim on a pathological value
    $v =~ s/^\s+|\s+$//g;
    return '' unless $v =~ /^[0-9a-fA-F-]{8,}$/;   # UUID-shaped, nothing else
    return lc $v;
}

# collect_butler_sids($blueprints_root) -> \%sids
#
# Always returns a HASHREF ({} when there is nothing to collect). Never
# undef, never dies, for ANY input. Per-FILE isolation: one corrupt
# registry never suppresses the SIDs of a sibling valid registry.
sub collect_butler_sids {
    my ($root) = @_;
    my %sids;
    for my $p (registry_paths($root)) {
        $sids{$_} = 1 for sids_from_registry_file($p);
    }
    return \%sids;
}

# is_butler_session($uuid, $sids) -> 0|1
#
# Returns exactly 1 or 0 (never undef, never the stored value).
# undef/empty/non-UUID $uuid -> 0. undef/non-hash $sids -> 0.
# Case-insensitive match.
sub is_butler_session {
    my ($uuid, $sids) = @_;
    return 0 unless ref $sids eq 'HASH';
    my $u = _norm_sid($uuid);
    return 0 unless length $u;
    return $sids->{$u} ? 1 : 0;
}

# mark_sessions($sessions_aref, $sids) -> $sessions_aref
#
# Mutates each session hashref in place, adding is_butler => 0|1;
# returns the same arrayref. Order is never changed, no other key is
# touched. Non-array / non-hash elements are skipped silently.
sub mark_sessions {
    my ($sessions, $sids) = @_;
    return $sessions unless ref $sessions eq 'ARRAY';
    for my $s (@$sessions) {
        next unless ref $s eq 'HASH';
        $s->{is_butler} = is_butler_session($s->{uuid}, $sids);
    }
    return $sessions;
}

1;
