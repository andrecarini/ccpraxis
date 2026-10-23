#!/usr/bin/env perl
# gen-statusline-counters.pl -- prints the almanac counting block that
# scripts/statusline.pl embeds between its "GENERATED FROM
# gen-statusline-counters.pl" markers (blueprint hook-continuity-remake,
# package 10, spec section 2.1).
#
# WHY GENERATED. statusline.pl is a standalone installed payload: it may load
# nothing from this repo (Decision 18, AC-S3), and it runs on every render,
# where a subprocess costs about 292 ms on the Windows host. So the counting
# code can be neither imported nor spawned. It is emitted here instead, next
# to the modules whose rules it restates, and statusline.pl carries the exact
# bytes. A test compares the two byte for byte, so a drift fails the suite
# rather than silently miscounting.
#
# Usage: perl plugins/almanac/scripts/gen-statusline-counters.pl
#   Prints the payload to STDOUT and exits 0. Takes no arguments; any
#   argument prints one usage line to STDERR and exits 2. Writes no file.
#
# The payload is deterministic, LF-only, printable ASCII, with no blank lines
# and no trailing whitespace. It contains subs, `my` scalars and nothing else
# at column 0; no use/require, no spawn, no write-mode open (spec 2.2).
use strict;
use warnings;
use File::Basename ();
use Cwd ();    # the payload it emits calls Cwd::abs_path; statusline.pl loads it
BEGIN {
    # Separators FIRST, then dirname -- __FILE__ can carry backslashes on
    # Windows and dirname on a mixed-separator path misbehaves. Same shape as
    # BpTurnCaps::script_dir_for; asserted repo-wide by turn-cap-consistency.t's C9.
    (my $self = __FILE__) =~ s{\\}{/}g;
    unshift @INC, File::Basename::dirname($self);
}
use Almanac::GlobalCounts ();
use Almanac::PackageLink ();

if (@ARGV) {
    print STDERR "usage: perl plugins/almanac/scripts/gen-statusline-counters.pl (takes no arguments)\n";
    exit 2;
}

my $file_name = $Almanac::GlobalCounts::FILE_NAME;
die "gen-statusline-counters: GlobalCounts FILE_NAME is not a plain file name\n"
    unless defined $file_name && $file_name =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;

my @pkg_statuses = @Almanac::PackageLink::STATUSES;
die "gen-statusline-counters: Almanac::PackageLink::STATUSES is empty\n" unless @pkg_statuses;
for my $s (@pkg_statuses) {
    die "gen-statusline-counters: a PackageLink status is not a bare lowercase word\n"
        unless defined $s && $s =~ /\A[a-z]+\z/;
}

my $payload = <<'PAYLOAD';
# ALMANAC COUNTERS -- generated from plugins/almanac/scripts/gen-statusline-counters.pl.
# Regenerate: perl plugins/almanac/scripts/gen-statusline-counters.pl
#
# The one shared accessor for almanac counts, restated from Almanac::Store,
# Almanac::GlobalCounts, Almanac::PackageLink and Almanac::Thread because
# this file may import nothing. Every public sub wraps its body in eval and
# degrades to the "unavailable" value (undef); nothing here ever dies to its
# caller, spawns, or writes. Paths are byte strings throughout.
#
#   almanac_counts(cwd => $dir, sandbox => 0|1) -> {
#       project => { todo, note, thread, inbox } | undef,
#       global  => { todo, note, thread } | undef }
#   almanac_thread(cwd => $dir, session => $sid) -> undef | {
#       name, done, total, doing => [ \%label, ... ],
#       current => \%label | undef, next => \%label | undef }
#     %label = ( class => 'doing'|'blocked'|'pending',
#                kind => 'text', title => $text, waits_on => $text|undef )
#            | ( class => ..., kind => 'link', blueprint => $bp,
#                number => $nn, step => $word )
#   blueprint where-things-go, package 12-statusline-threads (spec section
#   2). almanac_focus and the flat-tasklist "task" count are RETIRED
#   (Decision 3): the row-1 counter and the directory row now read threads.
my $ALMANAC_SNAPSHOT_NAME = '@@FILE_NAME@@';
my $ALMANAC_LEGACY_INBOX_DIR = 'decision';
my $ALM_PKG_STATUS_OK = { map { ($_ => 1) } qw(@@PKG_STATUSES@@) };
# Frontmatter already read this render, keyed by the record dir's identity
# (device and inode where the platform has them, else its path) plus the
# entry name. An attached thread's own record and its task records are each
# read once, not twice, even though almanac_counts and almanac_thread both
# scan thread/ -- a file open is the dominant cost of a render.
my $ALMANAC_FM_SEEN = {};
my $ALMANAC_DIR_KEY = {};
# Per-render memo of _alm_link_resolve, keyed by "$root\0$link" -- spec 5
# requires each ledger be read at most once per render; without this, K tasks
# linking the same package re-read and re-scan the ledger K times.
my $ALMANAC_LINK_SEEN = {};
# _alm_bytes($s) -> $s as UTF-8 bytes. A JSON-decoded path is a character
# string; the filesystem wants the bytes.
sub _alm_bytes {
    my ($s) = @_;
    return '' unless defined $s && !ref($s);
    $s = "$s";
    utf8::encode($s) if utf8::is_utf8($s);
    return $s;
}
sub _alm_is_abs {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    return 1 if substr($p, 0, 1) eq '/';
    return ($p =~ m{\A[A-Za-z]:(?:/|\z)}) ? 1 : 0;
}
# _alm_is_id($id) -> 1 when $id is a record id (Almanac::Store's grammar).
sub _alm_is_id {
    my ($id) = @_;
    return 0 unless defined $id && !ref($id);
    return 0 unless length($id) <= 128 && $id =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;
    return 0 if index($id, '..') >= 0;
    return 0 if $id =~ /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\z/i;
    return 1;
}
# _alm_sw_* / $ALMANAC_SW_IS_WIN / _alm_bounded_walk -- a PRIVATE mirror of
# plugins/butler/scripts/BpDataRoot.pm's bounded walk-up (R1-R4), restated
# here because this file may import nothing (AC-S3/AC-9). The marker kept is
# this file's own: .ccpraxis-local-data OR .git, matching
# Almanac::Store::_bounded_walk (unlike BpDataRoot.pm, which never looks at
# .git). A parity test (statusline-bounded-walkup.t AC-3) asserts the 11
# stop-rule subs below are source-identical to BpDataRoot.pm, modulo naming.
my $ALMANAC_SW_IS_WIN = ($^O =~ /^(MSWin32|msys|cygwin)$/) ? 1 : 0;
sub _alm_sw_fold_ascii {
    my ($s) = @_;
    return $s unless defined $s;
    (my $t = $s) =~ tr/A-Z/a-z/;
    return $t;
}
sub _alm_sw_is_abs_ish {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    return 1 if $p =~ m{^/};
    return 1 if $p =~ m{^[A-Za-z]:[\\/]};
    return 1 if $ALMANAC_SW_IS_WIN && $p =~ m{^\\};
    return 0;
}
sub _alm_sw_lex_canon {
    my ($p) = @_;
    return '' unless defined $p;
    (my $s = $p) =~ s{\\}{/}g;
    my $drive_prefix = '';
    if ($ALMANAC_SW_IS_WIN) {
        if ($s =~ m{^/([A-Za-z])(/.*)?$}) {
            my $rest = defined $2 ? $2 : '/';
            $s = lc($1) . ':' . $rest;
        }
        elsif ($s =~ m{^([A-Za-z]):(/.*)?$}) {
            my $rest = defined $2 ? $2 : '/';
            $s = lc($1) . ':' . $rest;
        }
        if ($s =~ m{^([a-z]:)(/.*)?$}) {
            $drive_prefix = $1;
            $s = defined $2 ? $2 : '/';
        }
    }
    my $is_abs = ($s =~ m{^/});
    my @parts = split m{/+}, $s;
    shift @parts if @parts && $parts[0] eq '';
    my @out;
    for my $seg (@parts) {
        next if $seg eq '' || $seg eq '.';
        if ($seg eq '..') { pop @out if @out; next }
        push @out, $seg;
    }
    my $canon = $is_abs ? ('/' . join('/', @out)) : join('/', @out);
    $canon = $drive_prefix . $canon if length $drive_prefix;
    unless ($canon =~ m{^(?:[a-z]:)?/\z}) {
        $canon =~ s{/\z}{};
    }
    return $canon;
}
sub _alm_sw_seg_eq {
    my ($x, $y, $allow_83) = @_;
    $allow_83 = 1 unless defined $allow_83;
    return $x eq $y unless $ALMANAC_SW_IS_WIN;
    return 1 if _alm_sw_fold_ascii($x) eq _alm_sw_fold_ascii($y);
    return 0 unless $allow_83;
    for my $pair ([$x, $y], [$y, $x]) {
        my ($short, $long) = @$pair;
        next unless defined $short && $short =~ /^([^~\/]{1,6})~[0-9]+(?:\.[^.\/]{0,3})?$/;
        my $stem = _alm_sw_fold_ascii($1);
        $stem =~ s/[^a-z0-9]//g;
        next unless length $stem;
        my $longfold = _alm_sw_fold_ascii($long);
        $longfold =~ s/[^a-z0-9]//g;
        $longfold = substr($longfold, 0, 6);
        return 1 if $stem eq $longfold;
    }
    return 0;
}
sub _alm_sw_same_path {
    my ($p, $q, $allow_83) = @_;
    $allow_83 = 1 unless defined $allow_83;
    return 0 unless defined $p && defined $q;
    my $ca = _alm_sw_lex_canon($p);
    my $cb = _alm_sw_lex_canon($q);
    my @sa = grep { length } split m{/}, $ca, -1;
    my @sb = grep { length } split m{/}, $cb, -1;
    return 0 unless scalar(@sa) == scalar(@sb);
    for my $i (0 .. $#sa) {
        return 0 unless _alm_sw_seg_eq($sa[$i], $sb[$i], $allow_83);
    }
    return 1;
}
sub _alm_sw_real_path {
    my ($p) = @_;
    return $p unless defined $p && length $p;
    return $p unless -e $p;
    my $r = eval { Cwd::abs_path($p) };
    return (defined $r && length $r) ? $r : $p;
}
sub _alm_sw_same_path_any_form {
    my ($d, $s, $allow_83) = @_;
    $allow_83 = 1 unless defined $allow_83;
    return 1 if _alm_sw_same_path($d, $s, $allow_83);
    my $rd = _alm_sw_real_path($d);
    my $rs = _alm_sw_real_path($s);
    return 1 if _alm_sw_same_path($rd, $rs, $allow_83);
    if ($^O =~ /^(msys|cygwin)$/ && defined &Cygwin::posix_to_win_path) {
        my $wd = eval { Cygwin::posix_to_win_path($rd) };
        my $ws = eval { Cygwin::posix_to_win_path($rs) };
        $wd = $rd unless defined $wd;
        $ws = $rs unless defined $ws;
        return 1 if _alm_sw_same_path($wd, $ws, $allow_83);
    }
    return 0;
}
sub _alm_sw_compute_stops {
    my @candidates;
    push @candidates, eval { File::Spec->tmpdir };
    push @candidates, $ENV{TMP}, $ENV{TEMP}, $ENV{TMPDIR};
    push @candidates, $ENV{HOME}, $ENV{USERPROFILE};
    my @stops;
    for my $v (@candidates) {
        next unless defined $v && length $v;
        next unless _alm_sw_is_abs_ish($v);
        my $canon = _alm_sw_lex_canon($v);
        next if $canon =~ m{^(?:[a-z]:)?/\z};
        push @stops, $v;
    }
    return \@stops;
}
sub _alm_sw_is_stop {
    my ($d, $stops, $allow_83) = @_;
    $allow_83 = 1 unless defined $allow_83;
    for my $s (@$stops) {
        return 1 if _alm_sw_same_path_any_form($d, $s, $allow_83);
    }
    return 0;
}
sub _alm_sw_collapse_dotdot {
    my ($p) = @_;
    return $p unless defined $p && length $p;
    return $p unless $p =~ m{(?:^|/)\.\.?(?:/|\z)};
    my $drive_prefix = '';
    my $s = $p;
    if ($ALMANAC_SW_IS_WIN && $s =~ m{^([A-Za-z]:)(/.*)?\z}) {
        $drive_prefix = $1;
        $s = defined $2 ? $2 : '/';
    }
    my $is_abs = ($s =~ m{^/});
    my @parts = split m{/+}, $s;
    shift @parts if @parts && $parts[0] eq '';
    my @out;
    for my $seg (@parts) {
        next if $seg eq '' || $seg eq '.';
        if ($seg eq '..') { pop @out if @out; next }
        push @out, $seg;
    }
    my $canon = $is_abs ? ('/' . join('/', @out)) : join('/', @out);
    $canon = $drive_prefix . $canon if length $drive_prefix;
    unless ($canon =~ m{^(?:[A-Za-z]:)?/\z}) {
        $canon =~ s{/\z}{};
    }
    return $canon;
}
sub _alm_sw_home_usable {
    for my $v ($ENV{HOME}, $ENV{USERPROFILE}) {
        return 1 if defined $v && length $v && _alm_sw_is_abs_ish($v);
    }
    return 0;
}
sub _alm_sw_parent_of {
    my ($d) = @_;
    return undef unless defined $d && length $d;
    return undef if $d =~ m{\A[A-Za-z]:/?\z};
    return undef if $d eq '/';
    my $idx = rindex($d, '/');
    return undef if $idx < 0;
    my $parent = substr($d, 0, $idx);
    return '/' if $parent eq '';
    return "$parent/" if $parent =~ m{\A[A-Za-z]:\z};
    return $parent;
}
sub _alm_bounded_walk {
    my ($start) = @_;
    return undef unless defined $start && length $start;
    (my $s = $start) =~ s{\\}{/}g;
    $s = _alm_sw_collapse_dotdot($s) if length $s;
    my $home_ok = _alm_sw_home_usable();
    my $stops = _alm_sw_compute_stops();
    # stat-based identity (device+inode) check, supplementing _alm_sw_is_stop's
    # text-only match: this file loads no Cwd (AC-S3/AC-9), so the _alm_sw_*
    # subs' realpath step is silently inert and a junction/symlink/alternate-
    # codepoint alias of a stop directory evades text comparison. stat is a
    # core builtin -- no use/require needed -- and two paths naming the same
    # filesystem entry share a (dev, ino) pair even when their text differs.
    my @stop_dev_ino;
    for my $stop (@$stops) {
        my @st = stat($stop);
        push @stop_dev_ino, [$st[0], $st[1]] if @st && defined $st[0];
    }
    my $d = $s;
    my %seen;
    while (1) {
        return undef if $seen{$d}++;
        my $is_stop_here = _alm_sw_is_stop($d, $stops);
        if (!$is_stop_here && @stop_dev_ino) {
            my @dst = stat($d);
            if (@dst && defined $dst[0]) {
                for my $sdi (@stop_dev_ino) {
                    if ($dst[0] == $sdi->[0] && $dst[1] == $sdi->[1]) {
                        $is_stop_here = 1;
                        last;
                    }
                }
            }
        }
        return undef if $is_stop_here && !_alm_sw_same_path_any_form($d, $s);
        return $d if -d "$d/.ccpraxis-local-data" || -e "$d/.git";
        return undef if $is_stop_here;
        return undef unless $home_ok;
        my $parent = _alm_sw_parent_of($d);
        return undef unless defined $parent && length $parent && $parent ne $d;
        $d = $parent;
    }
}
# _alm_project_root($cwd) -> the project root, or undef. The nearest ancestor
# holding .ccpraxis-local-data or .git, found by the bounded walk
# _alm_bounded_walk above; that walk mirrors Almanac::Store::_bounded_walk
# and plugins/butler/scripts/BpDataRoot.pm's R1-R4, restated inline because
# this file may import nothing. After the walk comes CLAUDE_PROJECT_DIR, then
# the start. A relative start is never walked, so the process cwd is never
# consulted; a relative result is no project.
sub _alm_project_root {
    my ($cwd) = @_;
    my $start = _alm_bytes($cwd);
    $start =~ tr{\\}{/};
    my $project;
    if (_alm_is_abs($start)) {
        my $dir = $start;
        $dir =~ s{/+\z}{} unless $dir =~ m{\A(?:[A-Za-z]:)?/\z};
        $project = _alm_bounded_walk($dir);
    }
    if (!defined $project) {
        my $cpd = $ENV{CLAUDE_PROJECT_DIR};
        $project = (defined $cpd && length $cpd) ? $cpd : $start;
        $project =~ tr{\\}{/};
    }
    $project =~ s{/+\z}{};
    return undef unless _alm_is_abs($project);
    return $project;
}
# _alm_home() -> ALMANAC_HOME, else HOME, else USERPROFILE; undef if none.
sub _alm_home {
    for my $h ($ENV{ALMANAC_HOME}, $ENV{HOME}, $ENV{USERPROFILE}) {
        next unless defined $h && length $h;
        my $v = $h;
        $v =~ tr{\\}{/};
        $v =~ s{/+\z}{};
        return $v;
    }
    return undef;
}
# _alm_record_names($dir) -> the entries of $dir that name a record. A
# missing or unreadable dir has none.
sub _alm_record_names {
    my ($dir) = @_;
    my @names;
    opendir(my $dh, $dir) or return @names;
    while (defined(my $e = readdir($dh))) {
        next unless $e =~ /\A(.+)\.md\z/s;
        push @names, $e if _alm_is_id($1);
    }
    closedir($dh);
    return @names;
}
sub _alm_dir_key {
    my ($dir) = @_;
    my $k = $ALMANAC_DIR_KEY->{$dir};
    return $k if defined $k;
    my @st = stat($dir);
    $k = (@st && $st[1]) ? "inode:$st[0]:$st[1]" : "path:$dir";
    $ALMANAC_DIR_KEY->{$dir} = $k;
    return $k;
}
# almanac_parse_record($bytes) -> \%fields, or undef when Almanac::Record
# would refuse the bytes (almanac-records Decision 38: this parser accepts
# exactly what Almanac::Record::check accepts). Field values are decoded
# characters, exactly as Almanac::Record::parse returns them. Refused:
# invalid UTF-8 (strict: no surrogate, noncharacter or code point past
# U+10FFFF), a first line that is not exactly "---", no closing "---", a CR
# on either delimiter or any field line, an empty front matter, a line that
# is not "key: value" (one colon, one space), a duplicate key, and a value
# carrying C0 (less TAB), DEL, C1, U+2028 or U+2029. A value is never
# trimmed, so "status: open " is not "open".
sub almanac_parse_record {
    my ($bytes) = @_;
    return undef unless defined $bytes && !ref($bytes);
    my $text = "$bytes";
    if ($text =~ /[^\x00-\x7f]/) {
        return undef if utf8::is_utf8($text);
        return undef unless utf8::decode($text);
        return undef if $text =~ /[^\x{0}-\x{10FFFF}]/;
        return undef if $text =~ /@@BAD_CODE_POINTS@@/;
    }
    my @l = split /\n/, $text, -1;
    return undef unless @l && $l[0] eq '---';
    my $closing;
    for my $i (1 .. $#l) {
        if ($l[$i] =~ /\A---\r?\z/) { $closing = $i; last }
    }
    return undef unless defined $closing && $closing >= 2 && $l[$closing] eq '---';
    my %fields;
    for my $i (1 .. $closing - 1) {
        return undef unless $l[$i] =~ /\A([A-Za-z0-9_]+): (.*)\z/;
        my ($k, $v) = ($1, $2);
        return undef if exists $fields{$k};
        return undef if $v =~ /[\x00-\x08\x0A-\x1F\x7F-\x9F\x{2028}\x{2029}]/;
        $fields{$k} = $v;
    }
    return \%fields;
}
# _alm_frontmatter($dir, $entry) -> almanac_parse_record's fields for that
# file, or 0 when it cannot be read, exceeds @@READ_CAP@@ bytes, or is refused.
sub _alm_frontmatter {
    my ($dir, $entry) = @_;
    my $path = "$dir/$entry";
    my $key = _alm_dir_key($dir) . "/$entry";
    my $seen = $ALMANAC_FM_SEEN->{$key};
    return $seen if defined $seen;
    my $fm = 0;
    if (open(my $fh, '<:raw', $path)) {
        # Read in 8 KiB steps: one read() with the whole cap as its length
        # would allocate that much for every record, and records are small.
        my $bytes = '';
        my $n = 0;
        while (1) {
            my $got = read($fh, $bytes, 8192, length $bytes);
            if (!defined $got) { $n = undef; last }
            $n += $got;
            last if $got < 8192 || $n > @@READ_CAP@@;
        }
        close($fh);
        if (defined $n && $n <= @@READ_CAP@@) {
            my $f = almanac_parse_record($bytes);
            $fm = $f if $f;
        }
    }
    $ALMANAC_FM_SEEN->{$key} = $fm;
    return $fm;
}
# _alm_count($dir, @statuses) -> the records in $dir that parse and whose
# status is one of @statuses; with no statuses, every record that parses.
sub _alm_count {
    my ($dir, @statuses) = @_;
    my %want = map { ($_ => 1) } @statuses;
    my $n = 0;
    for my $e (_alm_record_names($dir)) {
        my $fm = _alm_frontmatter($dir, $e);
        next unless $fm;
        if (@statuses) {
            next unless defined $fm->{status};
            next unless $want{ $fm->{status} };
        }
        $n++;
    }
    return $n;
}
# _alm_count_field($dir, $field, @values) -> the records in $dir that parse
# and whose $field equals one of @values. Same record-name grammar and
# frontmatter cache as _alm_count, generalised to any field (package
# 12-statusline-threads: thread records are counted by "state", not
# "status").
sub _alm_count_field {
    my ($dir, $field, @values) = @_;
    my %want = map { ($_ => 1) } @values;
    my $n = 0;
    for my $e (_alm_record_names($dir)) {
        my $fm = _alm_frontmatter($dir, $e);
        next unless $fm;
        next unless defined $fm->{$field};
        next unless $want{ $fm->{$field} };
        $n++;
    }
    return $n;
}
sub _alm_nonneg_int {
    my ($v) = @_;
    return 0 unless defined $v && !ref($v);
    return ("$v" =~ /\A\d+\z/) ? 1 : 0;
}
# _alm_snapshot($path) -> { todo, note, thread } or undef. One attempt, never
# a retry: Almanac::GlobalCounts::_read_snapshot_once's checks, in its order.
# thread is the integer thread.open when the snapshot carries a HASH "thread"
# member whose "open" is a non-negative integer and whose "projects" (if
# present) is an ARRAY of defined, non-ref, non-empty scalars; otherwise
# thread is undef -- a malformed thread member never invalidates todo/note
# (package 12-statusline-threads, spec 2.1).
sub _alm_snapshot {
    my ($path) = @_;
    return undef unless -f $path;
    my @st = stat($path);
    return undef unless @st && defined $st[7] && $st[7] >= 1 && $st[7] <= 4096;
    open(my $fh, '<:raw', $path) or return undef;
    my $bytes = '';
    my $n = read($fh, $bytes, 4097);
    close($fh);
    return undef unless defined $n && $n >= 1 && $n <= 4096;
    my $d = eval { JSON::PP->new->decode($bytes) };
    return undef unless ref($d) eq 'HASH';
    return undef unless defined $d->{schema} && !ref($d->{schema}) && "$d->{schema}" eq '1';
    my $at = $d->{generated_at};
    return undef unless defined $at && !ref($at) && $at =~ /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/;
    my $todo = $d->{todo};
    return undef unless ref($todo) eq 'HASH';
    for my $k (qw(open done total)) {
        return undef unless _alm_nonneg_int($todo->{$k});
    }
    my $note = $d->{note};
    return undef unless ref($note) eq 'HASH' && _alm_nonneg_int($note->{total});
    my $thread;
    my $th = $d->{thread};
    if (ref($th) eq 'HASH' && _alm_nonneg_int($th->{open})) {
        my $projects_ok = 1;
        if (exists $th->{projects}) {
            if (ref($th->{projects}) eq 'ARRAY') {
                for my $p (@{ $th->{projects} }) {
                    $projects_ok = 0 if !defined($p) || ref($p) || !length("$p");
                }
            } else {
                $projects_ok = 0;
            }
        }
        $thread = 0 + $th->{open} if $projects_ok;
    }
    return { todo => 0 + $todo->{open}, note => 0 + $note->{total}, thread => $thread };
}
sub almanac_counts {
    my (%o) = @_;
    my ($project, $global);
    eval {
        my $root = _alm_project_root($o{cwd});
        if (defined $root) {
            my $ad = "$root/.ccpraxis-local-data/almanac";
            $project = {
                todo     => _alm_count("$ad/todo", 'open'),
                note     => _alm_count("$ad/note"),
                thread   => _alm_count_field("$ad/thread", 'state', 'live', 'handed-off'),
                inbox    => _alm_count(-d "$ad/inbox" ? "$ad/inbox" : "$ad/$ALMANAC_LEGACY_INBOX_DIR", 'unanswered'),
            };
        }
        1;
    } or $project = undef;
    eval {
        my $home = _alm_home();
        if (defined $home) {
            my $snap = _alm_snapshot("$home/.claude/$ALMANAC_SNAPSHOT_NAME");
            if ($o{sandbox}) {
                $global = $snap;
            } else {
                my $v = "$home/.claude/claude-code-vault/almanac";
                $global = { todo => _alm_count("$v/todo", 'open'), note => _alm_count("$v/note"), thread => (ref($snap) eq 'HASH' ? $snap->{thread} : undef) };
            }
        }
        1;
    } or $global = undef;
    return { project => $project, global => $global };
}
# _alm_text($chars) -> a decoded field value with C0, DEL and Unicode format
# characters (\p{Cf}: bidi overrides/embeddings/isolates, ZWSP, the Arabic
# letter mark, etc.) removed. Format characters pass grammar-restricted
# fields untouched (those are plain ASCII) but would otherwise reach a free-
# text title or blocked_on byte for byte, letting a crafted value reverse or
# spoof the rendered row on a bidi-aware terminal (redteam L1).
sub _alm_text {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/[\x00-\x1f\x7f]//g;
    $s =~ s/\p{Cf}//g;
    return $s;
}
# _alm_thread_name_ok($name) -> 1 iff $name is a thread id (restates
# Almanac::Thread::valid_name: lowercase alnum/hyphen, <=64 chars, not a
# reserved device name). This is stricter and lower-case-only compared to
# _alm_is_id, which is the generic Almanac::Store grammar used for record
# FILE names (e.g. task ids) -- the two must not be conflated.
sub _alm_thread_name_ok {
    my ($name) = @_;
    return 0 unless defined $name && $name =~ /\A[a-z0-9][a-z0-9-]{0,63}\z/;
    return 0 if $name =~ /\A(?:con|prn|aux|nul|com[1-9]|lpt[1-9])\z/i;
    return 1;
}
# _alm_rank_id_cmp($ra, $rb, $ia, $ib) -> restates Almanac::Store's
# _rank_id_cmp: rank (if both defined) compared with cmp, tie broken by id;
# a ranked entry always sorts before an unranked one; two unranked entries
# sort by id.
sub _alm_rank_id_cmp {
    my ($ra, $rb, $ia, $ib) = @_;
    if (defined $ra && defined $rb) {
        my $c = $ra cmp $rb;
        return $c ? $c : ($ia cmp $ib);
    } elsif (defined $ra) {
        return -1;
    } elsif (defined $rb) {
        return 1;
    } else {
        return $ia cmp $ib;
    }
}
# _alm_norm_pkg_status($raw) -> restates Almanac::PackageLink::norm_status:
# lowercase, every run of non-[a-z] becomes one space, trim, and the WHOLE
# result must equal one of @Almanac::PackageLink::STATUSES (interpolated at
# generation time into $ALM_PKG_STATUS_OK, the same way $ALMANAC_SNAPSHOT_NAME
# is interpolated) or the result is ''.
sub _alm_norm_pkg_status {
    my ($s) = @_;
    return '' unless defined $s;
    my $t = lc $s;
    $t =~ s/[^a-z]+/ /g;
    $t =~ s/\A\s+|\s+\z//g;
    return $ALM_PKG_STATUS_OK->{$t} ? $t : '';
}
# _alm_read_capped($path, $cap) -> up to $cap bytes of $path, or undef if it
# cannot be opened. Read in 8 KiB steps, same discipline as _alm_frontmatter.
sub _alm_read_capped {
    my ($path, $cap) = @_;
    return undef unless open(my $fh, '<:raw', $path);
    my $bytes = '';
    my $n = 0;
    while ($n < $cap) {
        my $want = $cap - $n;
        $want = 8192 if $want > 8192;
        my $got = read($fh, $bytes, $want, $n);
        last unless defined $got && $got > 0;
        $n += $got;
    }
    close($fh);
    return $bytes;
}
# _alm_link_resolve($root, $link) -> restates Almanac::PackageLink::resolve
# plus the pipeline-step reader (spec 2.2). Never consults CCPRAXIS_DATA_DIR.
# { state => 'invalid' }
# { state => 'missing', blueprint, package }
# { state => 'ok', blueprint, package, status, step }
sub _alm_link_resolve {
    my ($root, $link) = @_;
    $link = '' unless defined $link;
    my $key = (defined($root) ? $root : '') . "\0" . $link;
    my $cached = $ALMANAC_LINK_SEEN->{$key};
    return $cached if defined $cached;
    my $result = _alm_link_resolve_uncached($root, $link);
    $ALMANAC_LINK_SEEN->{$key} = $result;
    return $result;
}
sub _alm_link_resolve_uncached {
    my ($root, $link) = @_;
    my @parts = split m{/}, $link, -1;
    return { state => 'invalid' } unless @parts == 2;
    my ($bp, $pkg) = @parts;
    for my $p ($bp, $pkg) {
        return { state => 'invalid' }
            unless defined($p) && length($p) && length($p) <= 128
                && $p =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/ && index($p, '..') < 0;
    }
    $bp  = _alm_bytes($bp);
    $pkg = _alm_bytes($pkg);
    my $live     = "$root/.ccpraxis-local-data/blueprints/$bp/packages/$pkg.md";
    my $archived = "$root/.ccpraxis-local-data/blueprints/_archive/$bp/packages/$pkg.md";
    my $ledger;
    if (-f $live)          { $ledger = $live }
    elsif (-f $archived)   { $ledger = $archived }
    else                   { return { state => 'missing', blueprint => $bp, package => $pkg } }
    my $bytes = _alm_read_capped($ledger, 65536);
    $bytes = '' unless defined $bytes;
    my @lines = split /\n/, $bytes, -1;
    my $in = 0;
    my $status_raw;
    for my $ln (@lines) {
        if ($ln =~ /\A-{3}\s*\z/) { $in++; last if $in == 2; next; }
        next unless $in == 1;
        if (!defined($status_raw) && $ln =~ /\Astatus:[ \t]*(.*)/) {
            my $raw = $1;
            $raw =~ s/\s+\z//;
            $status_raw = $raw;
        }
    }
    my $norm = _alm_norm_pkg_status($status_raw);
    my $status = length($norm) ? $norm : 'pending';
    my $step = _alm_pipeline_step($bytes);
    return { state => 'ok', blueprint => $bp, package => $pkg, status => $status, step => $step };
}
# _alm_pipeline_step($blob) -> the current step word, or undef -- restates
# RunState::_parse_pipeline's rule (spec 2.2), run over ledger bytes.
sub _alm_pipeline_step {
    my ($blob) = @_;
    return undef unless defined $blob && length $blob;
    my $s = $blob;
    $s =~ s/\A\xEF\xBB\xBF//;
    my @lines = split /\n/, $s, -1;
    for my $l (@lines) { $l =~ s/\r\z//; }
    my $start;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /\A##[ \t]+Pipeline[ \t]*\z/i) { $start = $i; last; }
    }
    return undef unless defined $start;
    my %checked;
    my %word;
    my $in_fence = 0;
    for (my $i = $start + 1; $i <= $#lines; $i++) {
        my $line = $lines[$i];
        if ($line =~ /\A[ \t]*(?:\x60{3}|~~~)/) { $in_fence = $in_fence ? 0 : 1; next; }
        last if !$in_fence && $line =~ /\A#{1,6}[ \t]/;
        next if length($line) > 1024;
        if ($line =~ /\A[ \t]*-[ \t]*\[([ xX])\][ \t]*(\d{1,2})\.[ \t]+(\S+)/) {
            my ($mark, $num_raw, $w) = ($1, $2, $3);
            my $num = 0 + $num_raw;
            next if exists $checked{$num};
            $checked{$num} = ($mark eq 'x' || $mark eq 'X') ? 1 : 0;
            $word{$num} = $w;
        }
    }
    my @nums = sort { $a <=> $b } keys %checked;
    return undef unless @nums;
    my @pending = grep { !$checked{$_} } @nums;
    return undef unless @pending;
    my $w = lc($word{ $pending[0] });
    $w =~ s/[^a-z0-9-]//g;
    return length($w) ? $w : undef;
}
# _alm_classify_linked($status) -> 'done'|'doing'|'blocked'|'pending', per
# spec 2.1's resolved-status table.
sub _alm_classify_linked {
    my ($status) = @_;
    return 'done'    if defined($status) && ($status eq 'done' || $status eq 'dropped');
    return 'doing'   if defined($status) && ($status eq 'running' || $status eq 'converging' || $status eq 'reviewing');
    return 'blocked' if defined($status) && ($status eq 'blocked' || $status eq 'parked');
    return 'pending';
}
# _alm_classify_unlinked($status) -> 'done'|'doing'|'blocked'|'pending', per
# spec 2.1's unlinked-status table.
sub _alm_classify_unlinked {
    my ($status) = @_;
    $status = '' unless defined $status;
    return 'done'    if $status eq 'done' || $status eq 'obsoleted';
    return 'doing'   if $status eq 'doing';
    return 'blocked' if $status eq 'blocked';
    return 'pending';
}
# _alm_pkg_number($pkg) -> the leading digits of a package name (leading
# zeros kept), or the whole package part when it has none (spec 2.1 rule 7).
sub _alm_pkg_number {
    my ($pkg) = @_;
    $pkg = '' unless defined $pkg;
    return $1 if $pkg =~ /\A(\d+)/;
    return $pkg;
}
# _alm_task_label($root, \%fm, $id) -> ($class, \%label), per spec 2.1 rules
# 5-9.
sub _alm_task_label {
    my ($root, $fm, $id) = @_;
    if (defined($fm->{link})) {
        my $res = _alm_link_resolve($root, $fm->{link});
        if ($res->{state} eq 'ok') {
            my $class = _alm_classify_linked($res->{status});
            my $step  = (defined($res->{step}) && length($res->{step})) ? $res->{step} : $res->{status};
            return ($class, { class => $class, kind => 'link', blueprint => $res->{blueprint}, number => _alm_pkg_number($res->{package}), step => $step });
        }
        if ($res->{state} eq 'missing') {
            return ('pending', { class => 'pending', kind => 'link', blueprint => $res->{blueprint}, number => _alm_pkg_number($res->{package}), step => 'missing' });
        }
        my $txt = _alm_text($fm->{link}) . ' missing';
        return ('pending', { class => 'pending', kind => 'text', title => $txt, waits_on => undef });
    }
    my $class = _alm_classify_unlinked($fm->{status});
    my $title = _alm_text($fm->{title});
    $title = $id unless length $title;
    my $wo;
    if (defined $fm->{blocked_on}) {
        my $w = _alm_text($fm->{blocked_on});
        $wo = length($w) ? $w : undef;
    }
    return ($class, { class => $class, kind => 'text', title => $title, waits_on => $wo });
}
# _alm_thread_find(cwd, session) -> the implementation behind almanac_thread
# (spec 2.1). Not eval-wrapped itself; almanac_thread wraps it.
sub _alm_thread_find {
    my (%o) = @_;
    my $sid = $o{session};
    return undef unless _alm_is_id($sid);
    my $root = _alm_project_root($o{cwd});
    return undef unless defined $root;
    my $tdir = "$root/.ccpraxis-local-data/almanac/thread";
    my @names;
    if (opendir(my $dh, $tdir)) {
        while (defined(my $e = readdir($dh))) {
            next unless $e =~ /\A(.+)\.md\z/s;
            push @names, $1 if _alm_thread_name_ok($1);
        }
        closedir($dh);
    }
    my $chosen;
    for my $name (sort @names) {
        my $fm = _alm_frontmatter($tdir, "$name.md");
        next unless $fm;
        next unless defined($fm->{state}) && $fm->{state} eq 'live';
        next unless defined($fm->{owner_kind}) && $fm->{owner_kind} eq 'session';
        next unless defined($fm->{owner_id}) && $fm->{owner_id} eq $sid;
        $chosen = $name;
        last;
    }
    return undef unless defined $chosen;
    my $tasks_dir = "$root/.ccpraxis-local-data/almanac/thread-tasks-$chosen";
    my @recs;
    for my $e (_alm_record_names($tasks_dir)) {
        my $fm = _alm_frontmatter($tasks_dir, $e);
        next unless $fm;
        (my $id = $e) =~ s/\.md\z//;
        push @recs, { id => $id, fm => $fm };
    }
    @recs = sort { _alm_rank_id_cmp($a->{fm}{rank}, $b->{fm}{rank}, $a->{id}, $b->{id}) } @recs;
    my $total = scalar @recs;
    my $done = 0;
    my @doing;
    my $current;
    my $next;
    for my $r (@recs) {
        my ($class, $label) = _alm_task_label($root, $r->{fm}, $r->{id});
        if ($class eq 'done') { $done++; next; }
        push @doing, $label if $class eq 'doing';
        $current = $label unless defined $current;
        $next = $label if !defined($next) && $class eq 'pending';
    }
    $current = undef if @doing;
    return { name => $chosen, done => $done, total => $total, doing => \@doing, current => $current, next => $next };
}
sub almanac_thread {
    my (%o) = @_;
    my $t;
    eval { $t = _alm_thread_find(%o); 1 } or $t = undef;
    return $t;
}
PAYLOAD

$payload =~ s/\@\@FILE_NAME\@\@/$file_name/g;

# Interpolated the same way $ALMANAC_SNAPSHOT_NAME is: the generator loads
# Almanac::PackageLink (never the payload, spec 2.2) and restates its status
# list as a literal word list.
my $pkg_statuses = join(' ', @pkg_statuses);
$payload =~ s/\@\@PKG_STATUSES\@\@/$pkg_statuses/g;

# The code points strict UTF-8 (Encode's 'UTF-8', which Almanac::Record::check
# uses) refuses but utf8::decode admits: surrogates and the 66 noncharacters.
# Spelled out as one character class so the payload needs no \p{} property,
# whose first use can load Unicode tables at render time.
my $bad = '[\x{D800}-\x{DFFF}\x{FDD0}-\x{FDEF}'
        . join('', map { sprintf('\x{%X}\x{%X}', $_ * 0x10000 + 0xFFFE, $_ * 0x10000 + 0xFFFF) } 0 .. 16)
        . ']';
$payload =~ s/\@\@BAD_CODE_POINTS\@\@/$bad/g;

# A record larger than this is not counted. Records are a few hundred bytes;
# the cap only bounds what one render may read from a hostile or broken file.
my $read_cap = 1048576;
$payload =~ s/\@\@READ_CAP\@\@/$read_cap/g;
die "gen-statusline-counters: unreplaced placeholder\n" if $payload =~ /\@\@[A-Z_]+\@\@/;
print $payload;
exit 0;
