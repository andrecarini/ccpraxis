package Almanac::LegacyQueue;
# Almanac::LegacyQueue -- lazy absorption of the retired operator question
# queue (<project>/.ccpraxis-local-data/.subagent-guard/questions.md) into
# the almanac inbox store. Blueprint hook-continuity-remake,
# package 09-question-queue. See specs/09-question-queue-spec.md sec 2.1
# (renamed by blueprint where-things-go, package 01-inbox-rename).
#
# THE ONLY READER OF questions.md ANYWHERE (Q16 of that spec's oracle).
# open_inbox() in almanac-inbox.pl is the ONE call site (spec 2.2);
# nothing else in this repo may read or write that path.
#
# absorb() NEVER dies, prints or spawns, and it never opens a store itself
# (no ->open(, no Almanac::Inbox::*) -- it is handed an already-open
# store and writes only through $store->create, plus one rename.
use strict;
use warnings;
use Encode ();
use Digest::SHA ();
use Almanac::Lock ();

our $VERSION = '1.0';

# legacy_path($store) -> "<P>/.subagent-guard/questions.md", where <P> is
# $store->root with its trailing "/almanac" removed -- the project's own
# .ccpraxis-local-data, spelled exactly as the store spells it.
sub legacy_path {
    my ($store) = @_;
    my $root = $store->root;
    (my $p = $root) =~ s{/almanac\z}{};
    return "$p/.subagent-guard/questions.md";
}

sub _now_iso {
    my @t = gmtime(time);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
                   $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub _slurp_raw {
    my ($path) = @_;
    return undef unless -f $path;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# _rename_migrated($legacy) -> $target|undef. First free name among
# "<legacy>.migrated", "<legacy>.migrated.2", ".3", ... Never overwrites an
# earlier .migrated* file, never deletes anything.
sub _rename_migrated {
    my ($legacy) = @_;
    my $n = 0;
    while (1) {
        $n++;
        my $target = ($n == 1) ? "$legacy.migrated" : "$legacy.migrated.$n";
        next if -e $target;
        my ($ok, $err) = Almanac::Lock::rename_with_retry($legacy, $target);
        return $ok ? $target : undef;
    }
}

# _absorb_locked($store, $legacy, \%report) -> \%report. Called with the
# legacy file's lock already held.
sub _absorb_locked {
    my ($store, $legacy, $report) = @_;

    unless (-e $legacy) {
        return { %$report, state => 'absent', reason => 'absent', filed => 0, already => 0 };
    }

    my $raw = _slurp_raw($legacy);
    unless (defined $raw) {
        return { %$report, state => 'failed', reason => 'io', filed => 0, already => 0 };
    }

    my @lines = split /\n/, $raw;
    my %seen;
    my ($filed, $already) = (0, 0);

    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        (my $l = $line) =~ s/\r\z//;
        next unless $l =~ /^\s*-\s+(.*)\z/;
        my $rest = $1;

        my $k = ++$seen{$l};
        my $hex = substr(Digest::SHA::sha1_hex($l), 0, 16);
        my $id  = ($k >= 2) ? "legacy-$hex-$k" : "legacy-$hex";

        my $decoded = eval { Encode::decode('UTF-8', $rest) };
        $decoded = $rest unless defined $decoded;

        my $created;
        if ($decoded =~ /^\[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z)\]\s*/) {
            $created = $1;
            $decoded =~ s/^\[\Q$created\E\]\s*//;
        } else {
            $created = _now_iso();
        }

        my $title = $decoded;
        $title =~ s/[\t\x{2028}\x{2029}]+/ /g;
        $title =~ s/\p{Cc}//g;
        $title =~ s/\A\s+//;
        $title =~ s/\s+\z//;
        next unless length $title;

        my $rec = eval {
            $store->create(
                id     => $id,
                fields => { title => $title, status => 'unanswered', created => $created },
                order  => [qw(title status created)],
                body   => "Absorbed from the legacy question queue, line " . ($i + 1) . ".\n",
            );
        };
        if (my $err = $@) {
            if (ref($err) eq 'Almanac::Store::Error' && defined $err->{kind} && $err->{kind} eq 'exists') {
                $already++;
                next;
            }
            return { %$report, state => 'failed', reason => 'io', filed => $filed, already => $already };
        }
        $filed++;
    }

    my $migrated_to = _rename_migrated($legacy);
    unless (defined $migrated_to) {
        return { %$report, state => 'failed', reason => 'rename_failed', filed => $filed, already => $already };
    }

    return { %$report, state => 'absorbed', reason => 'ok', filed => $filed, already => $already,
              migrated_to => $migrated_to };
}

# absorb($store, %opt) -> \%report. opt: lock_timeout_ms.
#
# Removal condition: delete this module and its one call site once every
# live install and sandbox runs a promoted butler that no longer writes
# questions.md, and almanac-records 17's doctor reports no unabsorbed
# legacy queue in the operator's projects.
sub absorb {
    my ($store, %opt) = @_;
    my $legacy = legacy_path($store);
    my $report = { legacy => $legacy };

    unless (ref($store) && $store->writable) {
        return { %$report, state => 'failed', reason => 'not_writable', filed => 0, already => 0 };
    }
    unless (-e $legacy) {
        return { %$report, state => 'absent', reason => 'absent', filed => 0, already => 0 };
    }

    my %lock_opts = (verb => 'absorb');
    $lock_opts{timeout_ms} = $opt{lock_timeout_ms} if exists $opt{lock_timeout_ms};
    my ($lock, $lock_err) = Almanac::Lock->acquire($legacy, %lock_opts);
    unless ($lock) {
        my $kind = (ref $lock_err eq 'HASH') ? $lock_err->{kind} : '';
        my $reason = ($kind eq 'timeout') ? 'lock_timeout' : 'io';
        return { %$report, state => 'failed', reason => $reason, filed => 0, already => 0 };
    }

    my $result = eval { _absorb_locked($store, $legacy, $report) };
    my $err = $@;
    $lock->release;
    if ($err || !defined $result) {
        return { %$report, state => 'failed', reason => 'io', filed => 0, already => 0 };
    }
    return $result;
}

1;
