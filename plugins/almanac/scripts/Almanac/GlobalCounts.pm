package Almanac::GlobalCounts;
# Almanac::GlobalCounts -- the single global-counts snapshot file (blueprint
# almanac-records, package 19-global-counts-snapshot). See specs/19-global-
# counts-snapshot-spec.md sections 2.3, 3, 4.
#
# Decision 7 (as amended): global counts are VISIBLE in a sandbox, global
# records are not ACCESSIBLE there. One file, one host path, written
# atomically through Almanac::Lock; a sandbox bind-mounts that single file
# read-only (MountSpec.pm, out of this module's scope).
#
# CORE PERL plus Almanac::Store, Almanac::Lock, JSON::PP. No import from
# another plugin (spec 2.3).
use strict;
use warnings;
use File::Path ();
use JSON::PP ();
use Time::HiRes ();
use Encode ();
use Almanac::Store ();
use Almanac::Lock ();

our $VERSION = '1.0';

our $FILE_NAME      = 'almanac-global-counts.json';
our $CONTAINER_PATH = '/root/.claude/almanac-global-counts.json';

# ---------------------------------------------------------------------------
# snapshot_path(%opt) -> $path        (%opt: home)
#
# Deliberately the SAME home resolution Almanac::Store uses for the global
# stores (Almanac::Store::_resolve_home) -- the snapshot must describe the
# vault under the same home a global mutation just wrote to.
# ---------------------------------------------------------------------------
sub snapshot_path {
    my (%opt) = @_;
    my $home = Almanac::Store::_resolve_home(home => $opt{home});
    return "$home/.claude/$FILE_NAME";
}

# ---------------------------------------------------------------------------
# compute(%opt) -> \%counts     (%opt: home); dies (a Store error) on failure
# ---------------------------------------------------------------------------
sub compute {
    my (%opt) = @_;

    my $todo_store = Almanac::Store->open(scope => 'global', type => 'todo', home => $opt{home});
    my $todo_list  = $todo_store->list();
    my ($open, $done, $total) = (0, 0, 0);
    for my $rec (@$todo_list) {
        $total++;
        my $st = $rec->{fields}{status};
        if    (defined $st && $st eq 'open') { $open++ }
        elsif (defined $st && $st eq 'done') { $done++ }
        else {
            die Almanac::Store::Error->new(kind => 'bad_status', id => $rec->{id}, path => $rec->{path});
        }
    }

    my $note_store = Almanac::Store->open(scope => 'global', type => 'note', home => $opt{home});
    my $note_list  = $note_store->list();

    my %out = (
        todo => { open => $open, done => $done, total => $total },
        note => { total => scalar(@$note_list) },
    );

    # thread.open (blueprint where-things-go, package 02-thread-store, spec
    # 2.6): number of thread metadata records with state live|handed-off,
    # across every root in %opt's roots. A root whose read dies contributes
    # 0 and is skipped (never fails the whole refresh).
    if (exists $opt{roots}) {
        my $n = 0;
        for my $root (@{ (ref $opt{roots} eq 'ARRAY') ? $opt{roots} : [] }) {
            my $ok = eval {
                my $thread_dir = "$root/.ccpraxis-local-data/almanac/thread";
                if (-d $thread_dir) {
                    my $store = Almanac::Store->open(scope => 'project', type => 'thread', root => $root);
                    my $list = $store->list();
                    for my $rec (@$list) {
                        my $st = $rec->{fields}{state};
                        $n++ if defined $st && ($st eq 'live' || $st eq 'handed-off');
                    }
                }
                1;
            };
            # swallow: a root whose read dies contributes 0.
        }
        $out{thread} = { open => $n };
    }

    return \%out;
}

# ---------------------------------------------------------------------------
# serialize(\%counts, $gen_at) -> $bytes -- exactly the section-2.2 shape.
# ---------------------------------------------------------------------------
sub serialize {
    my ($counts, $gen_at) = @_;
    my %doc = (
        generated_at => $gen_at,
        note         => { total => 0 + $counts->{note}{total} },
        schema       => 1,
        todo         => {
            done  => 0 + $counts->{todo}{done},
            open  => 0 + $counts->{todo}{open},
            total => 0 + $counts->{todo}{total},
        },
    );
    if (ref $counts->{thread} eq 'HASH') {
        my @projects;
        if (ref $counts->{thread}{projects} eq 'ARRAY') {
            for my $p (@{ $counts->{thread}{projects} }) {
                next unless defined $p && length $p;
                # Spec 2.6: path strings are decoded from UTF-8 bytes to
                # characters before encoding (FB_CROAK); an undecodable path
                # is dropped rather than corrupting or blanking the rest of
                # the recorded roots. JSON::PP->new->utf8->encode below then
                # re-encodes every string field (including the plain-ASCII
                # ones) to UTF-8 bytes itself, so decoded characters are the
                # correct input here, not raw bytes.
                my $decoded = eval { Encode::decode('UTF-8', $p, Encode::FB_CROAK()) };
                next unless defined $decoded;
                push @projects, $decoded;
            }
        }
        $doc{thread} = { open => 0 + $counts->{thread}{open}, projects => \@projects };
    }
    return JSON::PP->new->utf8->canonical(1)->encode(\%doc) . "\n";
}

sub _now_iso {
    my @t = gmtime(time);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
                   $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub _is_nonneg_int {
    my ($v) = @_;
    return 0 unless defined $v && !ref($v);
    return 0 unless "$v" =~ /\A\d+\z/;
    return 1;
}

# ---------------------------------------------------------------------------
# read_snapshot($path) -> \%snap | undef -- never dies, never writes, takes
# no lock. The reference implementation of the reader contract package 10
# reproduces in statusline.pl (Decision 18: it cannot require this module).
# PACKAGE-10 CONTRACT NOTE: the container-side reader (a per-render,
# short-lived process) does NOT retry -- see the bounded-retry note below
# for why that is deliberate, not an omission.
#
# Bounded-retry note (AC7, tightened per review MUST-FIX M1): the target is
# replaced only by rename (Almanac::Lock::rename_with_retry / write_atomic),
# which is atomic on POSIX but, measured on this host's Cygwin-flavoured
# perl under heavy concurrent rename traffic, has a real (sub-millisecond,
# but repeatable) window where -f is true yet a following stat() or open()
# momentarily fails -- the directory entry is between "old gone" and "new
# linked". A single-shot read would regress a caller from "saw a valid
# snapshot" to undef purely from that window, which is exactly what AC7
# forbids.
#
# The retry is therefore scoped to ONLY that case: this process has already
# read a VALID snapshot at this exact path at least once before (tracked in
# %SEEN_VALID, keyed by path). A first read of an absent path, a 0-byte
# stub, or a decoded-but-invalid file (every DC-f "no counters" case: no
# container has been created yet, or podman's auto-created 0-byte mount
# stub) returns undef on the FIRST attempt, with no sleep at all -- this is
# the common case for a per-render statusline read (spec 2.7's cost budget:
# one open, one bounded read, no loop), and retrying it would add up to
# 200ms of busy-polling to every such render for no benefit, since nothing
# is mid-transition. Once a path has produced one valid snapshot, later
# transient failures at that SAME path are retried for a short, bounded
# window (deadline 0.2s, 2ms polls) before giving up -- still no lock, no
# subprocess, no unbounded block.
my %SEEN_VALID;

sub read_snapshot {
    my ($path) = @_;
    return undef unless defined $path && length $path;

    my $snap = _read_snapshot_once($path);
    if (defined $snap) {
        $SEEN_VALID{$path} = 1;
        return $snap;
    }
    return undef unless $SEEN_VALID{$path};

    my $deadline = Time::HiRes::time() + 0.2;
    while (Time::HiRes::time() < $deadline) {
        Time::HiRes::sleep(0.002);
        $snap = _read_snapshot_once($path);
        if (defined $snap) {
            $SEEN_VALID{$path} = 1;
            return $snap;
        }
    }
    return undef;
}

sub _read_snapshot_once {
    my ($path) = @_;
    return undef unless -f $path;

    my @st = stat($path);
    return undef unless @st;
    my $size = $st[7];
    return undef unless defined $size && $size >= 1 && $size <= 4096;

    open(my $fh, '<:raw', $path) or return undef;
    # Bounded read (spec 2.7: "a bounded read of at most 4096 bytes"),
    # regardless of what the stat above reported -- the target can be
    # swapped by rename between stat and open (review S4), so the stat is
    # only a cheap early exit, never the size bound actually relied on.
    my $bytes = '';
    my $n = read($fh, $bytes, 4097);
    close $fh;
    return undef unless defined $n && $n >= 1 && $n <= 4096;

    my $decoded = eval { JSON::PP->new->decode($bytes) };
    return undef unless ref($decoded) eq 'HASH';

    return undef unless defined $decoded->{schema} && "$decoded->{schema}" eq '1';
    return undef unless defined $decoded->{generated_at}
        && $decoded->{generated_at} =~ /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/;

    my $todo = $decoded->{todo};
    return undef unless ref($todo) eq 'HASH';
    for my $k (qw(open done total)) {
        return undef unless _is_nonneg_int($todo->{$k});
    }

    my $note = $decoded->{note};
    return undef unless ref($note) eq 'HASH';
    return undef unless _is_nonneg_int($note->{total});

    # thread (blueprint where-things-go, package 02-thread-store, spec 2.6):
    # optional. A malformed thread section is dropped entirely rather than
    # failing the whole snapshot -- todo/note are the load-bearing counters
    # every existing reader (statusline) depends on; thread is additive.
    if (exists $decoded->{thread}) {
        my $t = $decoded->{thread};
        my $ok = (ref($t) eq 'HASH') && _is_nonneg_int($t->{open});
        if ($ok && exists $t->{projects}) {
            if (ref($t->{projects}) eq 'ARRAY') {
                for my $p (@{ $t->{projects} }) {
                    unless (defined $p && !ref($p) && length($p)) { $ok = 0; last }
                }
            }
            else {
                $ok = 0;
            }
        }
        if ($ok && ref($t->{projects}) eq 'ARRAY') {
            # JSON::PP->decode (no ->utf8, deliberately -- this reader works
            # on raw bytes throughout) still utf8-flags a decoded string that
            # contains a raw multi-byte UTF-8 sequence taken verbatim from
            # the input text -- but it does so by reinterpreting EACH BYTE as
            # its own Latin-1 code point (<=255) under that flag, not by
            # decoding the sequence as UTF-8. utf8::encode would therefore
            # RE-ENCODE each of those single-byte code points as its own
            # multi-byte UTF-8 sequence -- double-encoding the original bytes
            # (observed: C3 A9 -> C3 83 C2 A9). utf8::downgrade is the
            # correct inverse here: every code point already fits in a byte,
            # so it just clears the flag and hands back the original bytes
            # unchanged. (A caller handing the flagged form to a filesystem
            # call like Cwd::abs_path hits the Windows mis-upgrade corruption
            # documented in Almanac::PackageLink::_byteify; this avoids ever
            # producing that form in the first place.)
            for my $p (@{ $t->{projects} }) {
                utf8::downgrade($p, 1) if utf8::is_utf8($p);
            }
        }
        delete $decoded->{thread} unless $ok;
    }

    return $decoded;
}

# _byteify($s) -> raw UTF-8 bytes (never re-encodes an already-byte scalar).
# See Almanac::PackageLink::_byteify for the Cwd::abs_path flip-flop this
# guards against -- the same host quirk applies to every path handled here.
sub _byteify {
    my ($s) = @_;
    return $s unless defined $s;
    my $copy = $s;
    utf8::encode($copy) if utf8::is_utf8($copy);
    return $copy;
}

# _recorded_roots($path) -> \@roots -- the thread.projects list from the
# CURRENT snapshot at $path, if any, as raw UTF-8 bytes. Read directly
# (never through read_snapshot/_read_snapshot_once, which enforce the
# generated_at/todo/note shape this helper does not need) -- an absent or
# undecodable file simply contributes no prior roots.
sub _recorded_roots {
    my ($path) = @_;
    return [] unless defined $path && -f $path;
    open(my $fh, '<:raw', $path) or return [];
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return [] unless defined $bytes && length $bytes;
    my $decoded = eval { JSON::PP->new->utf8->decode($bytes) };
    return [] unless ref($decoded) eq 'HASH';
    my $t = $decoded->{thread};
    return [] unless ref($t) eq 'HASH' && ref($t->{projects}) eq 'ARRAY';
    my @out;
    for my $p (@{ $t->{projects} }) {
        next unless defined $p && !ref($p) && length $p;
        push @out, _byteify($p);
    }
    return \@out;
}

# _registry_roots(%opt) -> \@roots -- every project path known to the
# steward registry at <home>/.claude/claude-code-vault/.registry-local.json
# (%opt: home). Never dies: an absent/malformed registry contributes no
# roots.
sub _registry_roots {
    my (%opt) = @_;
    my $home = Almanac::Store::_resolve_home(home => $opt{home});
    my $path = "$home/.claude/claude-code-vault/.registry-local.json";
    return [] unless -f $path;
    open(my $fh, '<:raw', $path) or return [];
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return [] unless defined $bytes && length $bytes;
    my $decoded = eval { JSON::PP->new->utf8->decode($bytes) };
    return [] unless ref($decoded) eq 'HASH' && ref($decoded->{projects}) eq 'HASH';
    my @out;
    for my $slug (keys %{ $decoded->{projects} }) {
        my $p = $decoded->{projects}{$slug};
        next unless ref($p) eq 'HASH' && defined $p->{path} && length $p->{path};
        my $norm = $p->{path};
        $norm =~ s{\\}{/}g;
        $norm =~ s{/\z}{} if length($norm) > 1;
        push @out, _byteify($norm);
    }
    return \@out;
}

# ---------------------------------------------------------------------------
# refresh(%opt) -> \%result     (%opt: home, timeout_ms, record_root); never
# dies/prints/exits. See spec 2.3's six-step algorithm; record_root is the
# where-things-go/02-thread-store addition (spec 2.6).
# ---------------------------------------------------------------------------
sub refresh {
    my (%opt) = @_;
    my $path = snapshot_path(%opt);

    if (Almanac::Store::surface(%opt) eq 'container') {
        return { ok => 0, reason => 'container', path => $path };
    }

    my $dir = $path;
    $dir =~ s{/[^/]+\z}{};
    unless (-d $dir) {
        my $made = eval { File::Path::make_path($dir); 1 };
        unless ($made && -d $dir) {
            return { ok => 0, reason => 'io', path => $path };
        }
    }

    my ($lock, $lock_err) = Almanac::Lock->acquire($path, timeout_ms => $opt{timeout_ms}, verb => 'refresh');
    unless ($lock) {
        my $kind = (ref($lock_err) eq 'HASH' && defined $lock_err->{kind}) ? $lock_err->{kind} : 'io';
        return { ok => 0, reason => $kind, path => $path };
    }

    # thread.{open,projects} (spec 2.6): fold record_root into the roots
    # carried forward from the existing snapshot, drop anything no longer a
    # real directory, then union in every root the steward registry knows
    # about -- deduped by Almanac::Store::_canonical_path so a root reached
    # both ways is counted (and listed) once.
    my @recorded = @{ _recorded_roots($path) };
    if (defined $opt{record_root} && length $opt{record_root}) {
        my $rr = _byteify($opt{record_root});
        my $rr_c = Almanac::Store::_canonical_path($rr);
        @recorded = grep { Almanac::Store::_canonical_path($_) ne $rr_c } @recorded;
        push @recorded, $rr;
    }
    @recorded = grep { -d $_ } @recorded;

    my @registry = @{ _registry_roots(%opt) };
    my %seen;
    my @union;
    for my $r (@recorded, @registry) {
        next unless -d $r;
        my $c = Almanac::Store::_canonical_path($r);
        next if $seen{$c}++;
        push @union, $r;
    }

    my $counts = eval { compute(%opt, roots => \@union) };
    if (my $err = $@) {
        $lock->release;
        my $kind = (ref($err) && defined $err->{kind}) ? $err->{kind} : 'io';
        return { ok => 0, reason => $kind, path => $path };
    }
    $counts->{thread}{projects} = \@recorded;

    # 4096-byte size budget (spec 2.6): evict from `projects` only, never
    # from `open`. Registry-member entries are evicted first (oldest first,
    # i.e. from the front of @recorded, since new entries are always
    # appended at the end by the dedup/push above), then the oldest
    # remaining entry of any kind, until the serialized snapshot fits.
    my %is_registry = map { Almanac::Store::_canonical_path($_) => 1 } @registry;
    my $gen_at = _now_iso();
    my $bytes  = serialize($counts, $gen_at);
    while (length($bytes) > 4096 && @{ $counts->{thread}{projects} }) {
        my $projects = $counts->{thread}{projects};
        my $victim_idx;
        for my $i (0 .. $#$projects) {
            if ($is_registry{ Almanac::Store::_canonical_path($projects->[$i]) }) {
                $victim_idx = $i;
                last;
            }
        }
        $victim_idx = 0 unless defined $victim_idx;
        splice(@$projects, $victim_idx, 1);
        $bytes = serialize($counts, $gen_at);
    }

    my ($wok, $werr) = Almanac::Lock::write_atomic($path, $bytes);
    $lock->release;
    unless ($wok) {
        my $kind = (ref($werr) eq 'HASH' && defined $werr->{kind}) ? $werr->{kind} : 'io';
        return { ok => 0, reason => $kind, path => $path };
    }

    return { ok => 1, path => $path, counts => $counts, generated_at => $gen_at };
}

1;
