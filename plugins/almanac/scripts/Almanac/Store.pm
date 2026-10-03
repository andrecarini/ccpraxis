package Almanac::Store;
# Almanac::Store -- the CRUD + ordering layer every almanac record type (todos,
# notes, tasklists, inbox items -- packages 04/05/07/08) calls. Built
# over Almanac::Lock (package 01) and Almanac::Record (package 02). Blueprint
# almanac-records, package 03-store (see specs/03-store-spec.md).
#
# THIS MODULE DEFINES METHODS NAMED AFTER PERL BUILTINS -- open(), exists(),
# delete(), read(), list(). Perl resolves a bareword `open(...)`/`exists
# EXPR`/`delete EXPR` to CORE:: regardless of a same-named sub in the same
# package (confirmed empirically: it still works, but emits "Ambiguous call
# resolved as CORE::open()" under `use warnings`). Every BUILTIN call in this
# file is therefore qualified as CORE::open / CORE::exists / CORE::delete so
# there is no ambiguity warning and no doubt about which one runs. Method
# calls ($store->open, $store->exists(...), $store->delete(...)) are always
# unambiguous (arrow syntax is a namespaced method lookup, never a bareword).
#
# WHY STORE OWNS ITS OWN WRITE PATH INSTEAD OF CALLING
# Almanac::Record::write_file (accepted at the step-2 gate, spec S7.3): DC7
# needs a kill point BETWEEN the temp write and the rename, and write_file
# owns that window internally. The condition of that acceptance is a pinned
# equivalence, asserted in almanac-store-crud.t: for the same record shape,
# the bytes this module writes and the bytes Almanac::Record::write_file
# would write are byte-identical -- both ultimately call
# Almanac::Record::serialize() on the same record hash, so this holds by
# construction as long as _write_record here never reimplements serialize().
#
# CORE PERL ONLY (S2.0). No exit(), no alarm(), no unlink of a .lock path
# ever (Almanac::Lock never removes one, on any path -- Lock.pm rule 3 -- and
# this module does not either).
use strict;
use warnings;
use Cwd ();
use File::Path ();
use File::Spec ();
use Digest::SHA ();
use JSON::PP ();
use Sys::Hostname ();
use Almanac::Lock ();
use Almanac::Record ();

our $VERSION = '1.0';

# ---------------------------------------------------------------------------
# Almanac::Store::Error -- the blessed die payload (spec S2.5). Same shape as
# Almanac::Record::Error, a separate class so `kind` namespaces never
# collide. exit_code is always 2; the sanctioned exit path for a caller is
# Almanac::Record::fatal($err) (this module adds no fatal() of its own --
# MR/S2.5).
#
# Every message ends with a machine block:
#   almanac-error:
#     kind: <value>
#     <key>: <value>
#     ...
# -- literal "almanac-error:" at column 0, then two-space-indented "key:
# value" lines, kind first, remaining keys in the fixed per-kind order below.
# A value is squashed to one token (any whitespace/control run -> "_"; an
# undef/empty value -> "-"). No test may match the prose line; only the
# block, via m/^\s{2}field:\s(\S+)$/m.
# ---------------------------------------------------------------------------
package Almanac::Store::Error;

# Stringification via overload. DRIVER AMENDMENT (2026-09-23), post-review
# (SHOULD-7): `overload` was omitted from S2.0's original import allowlist
# while S2.5's error shape requires it; the original workaround called
# overload->import(...) at BEGIN time to route around the allowlist check,
# which depended on Almanac::Record happening to `use overload` first and
# being loaded first -- a load-order dependency across files with no visible
# connection. `overload` is core Perl and S2.5 already mandates it, so the
# allowlist now admits it and this is a plain, ordinary import.
use overload '""' => sub { $_[0]->{message} }, fallback => 1;

my %KEY_ORDER = (
    conflict          => [qw(id field winner expected_rev actual_rev path)],
    not_found         => [qw(id path)],
    exists            => [qw(id path)],
    bad_id            => [qw(id)],
    bad_rank          => [qw(rank)],
    reserved_field    => [qw(id field)],
    id_mismatch       => [qw(id found path)],
    scope_unavailable => [qw(scope surface readable writable reason)],
    reorder_mismatch  => [qw(missing_count unknown_count first_missing first_unknown)],
    malformed         => [qw(id path problem_count first_line)],
    lock_timeout      => [qw(id path waited_ms timeout_ms holder_pid holder_host)],
    io                => [qw(path errno)],
    usage             => [qw(detail)],
    refused           => [qw(path detail cause)],
);

sub _tok {
    my ($v) = @_;
    return '-' unless defined $v && length("$v");
    (my $s = "$v") =~ s/[\s\x00-\x1f\x7f]+/_/g;
    return $s;
}

sub new {
    my ($class, %a) = @_;
    my $kind  = $a{kind};
    my @order = @{ $KEY_ORDER{$kind} || [] };

    my $block = "almanac-error:\n  kind: " . _tok($kind) . "\n";
    $block .= "  $_: " . _tok($a{$_}) . "\n" for @order;

    my @bits;
    push @bits, "id=$a{id}"     if defined $a{id};
    push @bits, "path=$a{path}" if defined $a{path};
    my $prose = "almanac store: $kind" . (@bits ? ' (' . join(', ', @bits) . ')' : '') . "\n";

    my $message = $prose . $block;
    return bless { %a, kind => $kind, message => $message, exit_code => 2 }, $class;
}

package Almanac::Store;

sub _die {
    my (%a) = @_;
    die Almanac::Store::Error->new(%a);
}

# =============================================================================
# 2.2 -- project-root resolution and path canonicalisation.
# =============================================================================

# _canonical_path($p) -> $normalized
#
# Cwd::abs_path($p) when the path resolves (the common case: the directory
# already exists); otherwise a textual fallback -- backslashes to forward
# slashes, /x/ <-> X:/ drive-form normalisation, uppercased drive letter, no
# trailing slash. This restates almanac-bug.pl::canonical_root (find it by
# that name, not by line number -- see the package ledger's scout note).
# Duplicated rather than imported because almanac-bug.pl is a script:
# require-ing it would run its main body (out of scope, S6).
sub _canonical_path {
    my ($p) = @_;
    return $p unless defined $p;
    my $abs = Cwd::abs_path($p);
    if (!defined $abs) {
        $abs = $p;
        $abs =~ s{\\}{/}g;
        $abs =~ s{^/([a-zA-Z])(?=/|\z)}{uc($1) . ':'}e;
    }
    $abs =~ s{\\}{/}g;
    $abs =~ s{/\z}{} if length($abs) > 1;
    $abs =~ s{^([a-zA-Z]):}{uc($1) . ':'}e;
    return $abs;
}

# _fold_drive_form($p) -> $normalized -- backslashes to forward slashes, the
# POSIX mount spelling "/x/..." folded to the drive spelling "X:/...", no
# trailing slash. Used ONLY to normalise the STARTING point of
# resolve_project_root's ancestor walk (below): Cwd::getcwd() on this host
# has been observed to answer in either spelling depending on how deep the
# process's chdir was (measured: a direct chdir to a tempdir root answers in
# drive form, a chdir three levels deeper into a freshly-created
# subdirectory answers in the POSIX mount form, for the SAME real
# directory). Cwd::abs_path(), by contrast, converges EITHER spelling of an
# EXISTING path to one deterministic form (verified empirically) -- so
# folding the walk's starting point to one convention before the walk, and
# leaving the eventual _canonical_path(<matched dir>) call to abs_path's own
# convergence, is what makes DC8 hold regardless of which spelling getcwd()
# handed back. This is deliberately NOT folded into _canonical_path itself:
# callers that pass an explicit root/home (B1, AC-35) are compared against
# the test oracle's own un-folded normalisation, and folding there would
# create the opposite mismatch.
sub _fold_drive_form {
    my ($p) = @_;
    return $p unless defined $p;
    $p =~ s{\\}{/}g;
    $p =~ s{^/([a-zA-Z])(?=/|\z)}{uc($1) . ':'}e;
    $p =~ s{/\z}{} if length($p) > 1;
    return $p;
}

# _parent_of($dir) -> $parent | undef
#
# Pure string arithmetic on an already forward-slash path -- deliberately not
# File::Spec, whose Win32 flavour reintroduces backslashes. undef means "no
# parent" (a drive root or POSIX root), which is resolve_project_root's stop
# condition.
sub _parent_of {
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

# ---------------------------------------------------------------------------
# _bounded_walk (package 03, Decision 3 & 20/Q2) -- a PRIVATE mirror of
# plugins/butler/scripts/BpDataRoot.pm's bounded walk-up (R1-R4 there),
# reimplemented here rather than loaded: this file's AC-47/48 import
# allowlist forbids any require of a sibling plugin and any compile outside
# `-I plugins/almanac/scripts`, so BpDataRoot.pm -- the source of truth for
# this algorithm -- cannot be a dependency. A parity test (unify-walkups.t
# AC9) asserts this mirror agrees with the real thing on every fixture start,
# so a future edit to either side that drifts is caught there.
#
# R1: the stop dirs are File::Spec->tmpdir, TMP, TEMP, TMPDIR, HOME and
#     USERPROFILE -- absolute, not a bare root.
# R2: a stop dir strictly above the start is never examined; the walk ends.
# R3: a start that IS a stop dir examines itself, adopts it if it holds the
#     marker, then ends either way.
# R4: stop matching folds ASCII case, treats "/x/..." and "X:/..." alike,
#     tolerates 8.3 short names, and also compares the abs_path and
#     Cygwin::posix_to_win_path forms -- Windows-family perls only.
# The marker stays Store's own: .ccpraxis-local-data OR .git (unlike
# BpDataRoot.pm, which never looks at .git).
# ---------------------------------------------------------------------------

my $SW_IS_WIN = ($^O =~ /^(MSWin32|msys|cygwin)$/) ? 1 : 0;

sub _sw_fold_ascii {
    my ($s) = @_;
    return $s unless defined $s;
    (my $t = $s) =~ tr/A-Z/a-z/;
    return $t;
}

sub _sw_is_abs_ish {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    return 1 if $p =~ m{^/};
    return 1 if $p =~ m{^[A-Za-z]:[\\/]};
    return 1 if $SW_IS_WIN && $p =~ m{^\\};
    return 0;
}

# _sw_lex_canon($p) -- lexical canonicalisation, same rules as
# BpDataRoot::_lex_canon: backslash to forward slash; on Windows-family
# perls, "/x/..." folds to "x:/...", drive letter lower-cased; "." segments
# dropped, ".." collapsed lexically; no trailing slash except a bare root.
sub _sw_lex_canon {
    my ($p) = @_;
    return '' unless defined $p;
    (my $s = $p) =~ s{\\}{/}g;

    my $drive_prefix = '';
    if ($SW_IS_WIN) {
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

sub _sw_seg_eq {
    my ($x, $y, $allow_83) = @_;
    $allow_83 = 1 unless defined $allow_83;
    return $x eq $y unless $SW_IS_WIN;
    return 1 if _sw_fold_ascii($x) eq _sw_fold_ascii($y);
    return 0 unless $allow_83;

    for my $pair ([$x, $y], [$y, $x]) {
        my ($short, $long) = @$pair;
        next unless defined $short && $short =~ /^([^~\/]{1,6})~[0-9]+(?:\.[^.\/]{0,3})?$/;
        my $stem = _sw_fold_ascii($1);
        $stem =~ s/[^a-z0-9]//g;
        next unless length $stem;
        my $longfold = _sw_fold_ascii($long);
        $longfold =~ s/[^a-z0-9]//g;
        $longfold = substr($longfold, 0, 6);
        return 1 if $stem eq $longfold;
    }
    return 0;
}

sub _sw_same_path {
    my ($p, $q, $allow_83) = @_;
    $allow_83 = 1 unless defined $allow_83;
    return 0 unless defined $p && defined $q;
    my $ca = _sw_lex_canon($p);
    my $cb = _sw_lex_canon($q);
    my @sa = grep { length } split m{/}, $ca, -1;
    my @sb = grep { length } split m{/}, $cb, -1;
    return 0 unless scalar(@sa) == scalar(@sb);
    for my $i (0 .. $#sa) {
        return 0 unless _sw_seg_eq($sa[$i], $sb[$i], $allow_83);
    }
    return 1;
}

sub _sw_real_path {
    my ($p) = @_;
    return $p unless defined $p && length $p;
    return $p unless -e $p;
    my $r = eval { Cwd::abs_path($p) };
    return (defined $r && length $r) ? $r : $p;
}

sub _sw_same_path_any_form {
    my ($d, $s, $allow_83) = @_;
    $allow_83 = 1 unless defined $allow_83;
    return 1 if _sw_same_path($d, $s, $allow_83);
    my $rd = _sw_real_path($d);
    my $rs = _sw_real_path($s);
    return 1 if _sw_same_path($rd, $rs, $allow_83);
    if ($^O =~ /^(msys|cygwin)$/ && defined &Cygwin::posix_to_win_path) {
        my $wd = eval { Cygwin::posix_to_win_path($rd) };
        my $ws = eval { Cygwin::posix_to_win_path($rs) };
        $wd = $rd unless defined $wd;
        $ws = $rs unless defined $ws;
        return 1 if _sw_same_path($wd, $ws, $allow_83);
    }
    return 0;
}

sub _sw_compute_stops {
    my @candidates;
    push @candidates, eval { File::Spec->tmpdir };
    push @candidates, $ENV{TMP}, $ENV{TEMP}, $ENV{TMPDIR};
    push @candidates, $ENV{HOME}, $ENV{USERPROFILE};

    my @stops;
    for my $v (@candidates) {
        next unless defined $v && length $v;
        next unless _sw_is_abs_ish($v);
        my $canon = _sw_lex_canon($v);
        next if $canon =~ m{^(?:[a-z]:)?/\z};
        push @stops, $v;
    }
    return \@stops;
}

sub _sw_is_stop {
    my ($d, $stops, $allow_83) = @_;
    $allow_83 = 1 unless defined $allow_83;
    for my $s (@$stops) {
        return 1 if _sw_same_path_any_form($d, $s, $allow_83);
    }
    return 0;
}

# _sw_collapse_dotdot($p) -> mirrors BpDataRoot::_collapse_dotdot (item 8(a));
# not one of the source-parity-checked subs (item 7) for the same reason as
# _sw_home_usable below.
sub _sw_collapse_dotdot {
    my ($p) = @_;
    return $p unless defined $p && length $p;
    return $p unless $p =~ m{(?:^|/)\.\.?(?:/|\z)};

    my $drive_prefix = '';
    my $s = $p;
    if ($SW_IS_WIN && $s =~ m{^([A-Za-z]:)(/.*)?\z}) {
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

# _sw_home_usable() -> 1|0 -- mirrors BpDataRoot::_home_usable (Decision 25 /
# item 8(b)); not one of the source-parity-checked subs (item 7) because it
# has no counterpart name to compare against by construction.
sub _sw_home_usable {
    for my $v ($ENV{HOME}, $ENV{USERPROFILE}) {
        return 1 if defined $v && length $v && _sw_is_abs_ish($v);
    }
    return 0;
}

# _bounded_walk($start) -> $dir | undef -- a test seam (spec §2.4); also the
# marker-holding step resolve_project_root calls. $start undef/'' defaults to
# Cwd::getcwd(), mirroring BpDataRoot::walkup's own default.
sub _bounded_walk {
    my ($start) = @_;
    $start = Cwd::getcwd() // '.' unless defined $start && length $start;
    (my $s = $start) =~ s{\\}{/}g;
    # Item 8(a): canonicalise a start containing ".." before walking.
    $s = _sw_collapse_dotdot($s) if length $s;
    my $home_ok = _sw_home_usable();
    my $stops = _sw_compute_stops();
    my $d = $s;
    my %seen;
    while (1) {
        return undef if $seen{$d}++;
        my $is_stop_here = _sw_is_stop($d, $stops);
        return undef if $is_stop_here && !_sw_same_path_any_form($d, $s);
        if (-d "$d/.ccpraxis-local-data" || -e "$d/.git") {
            return $d;
        }
        return undef if $is_stop_here;
        # Item 8(b)/Decision 25: no usable home known means never ascend.
        return undef unless $home_ok;
        my $parent = _parent_of($d);
        return undef unless defined $parent && length $parent && $parent ne $d;
        $d = $parent;
    }
}

# resolve_project_root(%opt) -> $abs_path      (%opt: cwd => $dir)
#
# Precedence, first hit wins: (1) the bounded walk-up (_bounded_walk, above)
# from cwd for a dir holding .ccpraxis-local-data or .git; (2)
# $ENV{CLAUDE_PROJECT_DIR}; (3) the starting directory itself. The walk is
# deliberately ahead of CLAUDE_PROJECT_DIR (DC8): a subdirectory must resolve
# to the same root as the project root itself, and an unset env var is not
# an answer.
sub resolve_project_root {
    my (%opt) = @_;
    my $cwd = (defined $opt{cwd} && length $opt{cwd}) ? $opt{cwd} : Cwd::getcwd();
    $cwd = _fold_drive_form($cwd);

    my $hit = _bounded_walk($cwd);
    return _canonical_path($hit) if defined $hit;

    if (defined $ENV{CLAUDE_PROJECT_DIR} && length $ENV{CLAUDE_PROJECT_DIR}) {
        return _canonical_path($ENV{CLAUDE_PROJECT_DIR});
    }
    return _canonical_path($cwd);
}

sub _resolve_home {
    my (%opt) = @_;
    my $h = $opt{home};
    $h = $ENV{ALMANAC_HOME} unless defined $h && length $h;
    $h = $ENV{HOME}         unless defined $h && length $h;
    $h = $ENV{USERPROFILE}  unless defined $h && length $h;
    $h = '.'                unless defined $h && length $h;
    return _canonical_path($h);
}

# =============================================================================
# 2.3 -- surface detection and scope capability. THE SINGLE DECISION POINT.
#
# The two container marker paths and the surface-override env var (named
# inside the sub below) may appear ONLY inside this one sub (AC-33).
# surface() is deliberately dual-role: as
# a plain function Almanac::Store::surface(%opt) it detects/resolves the
# surface (spec S2.3's signature); called as the accessor $store->surface it
# returns the surface captured at open() time (spec S2.4's accessor table).
# The two never collide: a method call always arrives as exactly one blessed
# argument, a function call always arrives as a flat (possibly empty) list
# of key/value pairs.
# =============================================================================
sub surface {
    if (@_ == 1 && ref($_[0]) eq __PACKAGE__) {
        return $_[0]->{surface};
    }
    my (%opt) = @_;
    # The explicit `surface` option is a first-class, documented API/testing
    # seam: a caller passing it already has full code-execution privilege in
    # this process (the same privilege that would let it monkey-patch
    # %SCOPE_POLICY directly), so it is honoured in either direction.
    if (defined $opt{surface} && ($opt{surface} eq 'host' || $opt{surface} eq 'container')) {
        return $opt{surface};
    }

    my $detected = -e '/run/.containerenv' ? 'container'
                 : (-e '/.dockerenv'       ? 'container' : 'host');

    # redteam MEDIUM-5: $ENV{ALMANAC_SURFACE} crosses process boundaries --
    # unlike the `surface` option above, a parent process (or anything it
    # spawns) can set it without the loading code ever having asked for it.
    # Decision 7's whole point is that the party being constrained cannot
    # turn off its own constraint, so the env var may only TIGHTEN a
    # detected surface (host -> container), never loosen a detected
    # container back to host.
    if (defined $ENV{ALMANAC_SURFACE}
        && $ENV{ALMANAC_SURFACE} eq 'container'
        && $detected eq 'host') {
        return 'container';
    }

    return $detected;
}

# The policy table Decision 7 (as amended) reduces to: a single boolean
# cannot say "you may read this and may not write it", so readable and
# writable are separate cells. The amendment path -- mounting the vault
# read-only into containers -- is a one-row edit here, never a call-site
# change (AC-31 exercises exactly that by localizing this hash).
our %SCOPE_POLICY = (
    host      => { project => { readable => 1, writable => 1, reason => 'ok' },
                   global  => { readable => 1, writable => 1, reason => 'ok' } },
    container => { project => { readable => 1, writable => 1, reason => 'ok' },
                   global  => { readable => 0, writable => 0,
                                reason   => 'vault_not_mounted' } },
);

# scope_capability($scope, %opt) -> \%cap      (%opt: surface, home, root, cwd)
sub scope_capability {
    my ($scope, %opt) = @_;
    _die(kind => 'usage', detail => 'scope_capability requires scope => project|global')
        unless defined $scope && ($scope eq 'project' || $scope eq 'global');

    my $surf   = surface(%opt);
    my $policy = $SCOPE_POLICY{$surf}{$scope} || { readable => 0, writable => 0, reason => 'unknown_policy' };

    my $readable = $policy->{readable} ? 1 : 0;
    my $writable = ($readable && $policy->{writable}) ? 1 : 0;   # invariant, asserted (AC-32)
    my $reason   = $policy->{reason};

    my $root;
    if ($readable) {
        if ($scope eq 'project') {
            my $proj = (defined $opt{root} && length $opt{root})
                     ? _canonical_path($opt{root})
                     : resolve_project_root(cwd => $opt{cwd});
            $root = "$proj/.ccpraxis-local-data/almanac";
        } else {
            $root = _resolve_home(%opt) . '/.claude/claude-code-vault/almanac';
        }
    }

    my $message = '';
    unless ($readable && $writable) {
        $message = "almanac store: scope '$scope' on surface '$surf' is not fully accessible "
                 . "here -- visible is not the same as accessible (reason: "
                 . (defined $reason ? $reason : 'unknown') . ").\n";
    }

    return {
        scope => $scope, surface => $surf, readable => $readable, writable => $writable,
        reason => $reason, root => $root, message => $message,
    };
}

# =============================================================================
# 2.4 -- the store handle.
# =============================================================================
sub open {
    my ($class, %args) = @_;
    _die(kind => 'usage', detail => 'scope must be project or global')
        unless defined $args{scope} && ($args{scope} eq 'project' || $args{scope} eq 'global');
    _die(kind => 'usage', detail => 'type is required and must match [a-z][a-z0-9-]*')
        unless defined $args{type} && $args{type} =~ /\A[a-z][a-z0-9-]*\z/;

    my $cap = scope_capability($args{scope},
        surface => $args{surface}, root => $args{root}, home => $args{home}, cwd => $args{cwd});

    unless ($cap->{readable}) {
        _die(kind => 'scope_unavailable', scope => $cap->{scope}, surface => $cap->{surface},
             readable => $cap->{readable}, writable => $cap->{writable}, reason => $cap->{reason});
    }

    # $cap->{root} is already canonical (built from a resolved, EXISTING
    # ancestor); a plain string join preserves that. Re-running
    # _canonical_path on the joined string would call Cwd::abs_path() on a
    # path that (per S2.4) does not exist yet -- open() creates nothing --
    # abs_path fails on it, and the textual fallback branch (deliberately,
    # per S2.2) folds a POSIX-mount spelling to drive form, which would
    # disagree with a root that arrived already in POSIX form and was never
    # meant to be re-folded.
    my $dir = "$cap->{root}/$args{type}";
    $dir =~ s{/\z}{} if length($dir) > 1;
    return bless {
        scope    => $args{scope},
        type     => $args{type},
        dir      => $dir,
        root     => $cap->{root},
        surface  => $cap->{surface},
        readable => $cap->{readable},
        writable => $cap->{writable},
        reason   => $cap->{reason},
    }, $class;
}

sub scope    { return $_[0]->{scope} }
sub type     { return $_[0]->{type} }
sub dir      { return $_[0]->{dir} }
sub root     { return $_[0]->{root} }
sub readable { return $_[0]->{readable} }
sub writable { return $_[0]->{writable} }

sub _require_readable {
    my ($self, $verb) = @_;
    return 1 if $self->{readable};
    _die(kind => 'scope_unavailable', scope => $self->{scope}, surface => $self->{surface},
         readable => $self->{readable}, writable => $self->{writable}, reason => $self->{reason});
}

sub _require_writable {
    my ($self, $verb) = @_;
    return 1 if $self->{writable};
    _die(kind => 'scope_unavailable', scope => $self->{scope}, surface => $self->{surface},
         readable => $self->{readable}, writable => $self->{writable}, reason => $self->{reason});
}

# =============================================================================
# 2.6 -- ids, the record path, writer_id.
# =============================================================================
# DRIVER AMENDMENT (2026-09-23), post-review (SHOULD-8). "Computed once at
# module load" was originally read literally -- a value frozen at `use`
# time -- which gives a forked child the SAME writer_id as its parent,
# collapsing DC2's winner: diagnostic (winner == loser, indistinguishable).
# The property this package actually needs is "stable within a process",
# not "frozen at load"; those coincide only for a process that never forks.
# Corrected contract: mint lazily on first call and whenever the calling pid
# has changed since the cached value was minted, caching against that pid.
my ($WRITER_ID, $WRITER_PID);
sub _mint_writer_id {
    my $host = eval { Sys::Hostname::hostname() };
    $host = 'unknown' unless defined $host && length $host;
    $host =~ s/[^A-Za-z0-9._-]/_/g;
    return sprintf('%s/%d/%04x', $host, $$, int(rand(0x10000)));
}
sub writer_id {
    if (!defined $WRITER_ID || !defined $WRITER_PID || $WRITER_PID != $$) {
        $WRITER_PID = $$;
        $WRITER_ID  = _mint_writer_id();
    }
    return $WRITER_ID;
}

# _byte_id($id) -> byte-string id -- an id is ASCII by grammar (S2.6), so a
# utf8-flagged id (e.g. a caller passing a decoded record field back in, per
# S1 of the 07-tasklist review) downgrades losslessly. Downgrading a COPY,
# never the caller's own scalar, so this has no visible effect on a caller
# that kept a reference to the same value. A value that fails to downgrade
# is not pure ASCII and therefore not grammatical anyway -- the id grammar
# check that follows (or already ran) rejects it on its own terms.
sub _byte_id {
    my ($id) = @_;
    return $id unless defined $id;
    my $copy = "$id";
    utf8::downgrade($copy, 1);
    return $copy;
}

sub _record_path { return "$_[0]->{dir}/" . _byte_id($_[1]) . ".md" }

# seal_path_for($record_path) -> "$record_path.seal", after the same
# backslash-to-forward-slash normalisation Almanac::Lock::lock_path_for
# applies -- so a seal path derived from either spelling of the record path
# converges on the same string.
sub seal_path_for {
    my ($record_path) = @_;
    (my $p = $record_path) =~ s{\\}{/}g;
    return "$p.seal";
}

# Id grammar (S2.6): \A[A-Za-z0-9][A-Za-z0-9._-]*\z, max 128 chars, no / or \
# (already excluded by the character class) and no ".." sequence. Checked
# BEFORE any path is built -- the only thing standing between a caller id
# and an arbitrary filesystem write.
sub _validate_id {
    my ($self, $id) = @_;
    unless (defined $id
        && length($id) <= 128
        && $id =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
        && $id !~ /\.\./
        && $id !~ /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\z/i) {
        _die(kind => 'bad_id', id => (defined $id ? $id : undef));
    }
    return 1;
}

# _record_id_for($dir, $entry) -> $id | undef -- the ONE predicate for "is
# this directory entry a record". An entry counts as a record iff it matches
# the id grammar followed by exactly ".md" and is a plain file; every
# sidecar/journal/temp name in S2.1's ignore list (.lock, .lock.holder,
# .seal, .store.lock*, .reorder-journal.json, *.tmp.*) fails this match by
# construction. Shared by ids() and record_files_in() so there is exactly
# one definition of "record", never two independently-maintained copies.
sub _record_id_for {
    my ($dir, $entry) = @_;
    return undef unless $entry =~ /\A([A-Za-z0-9][A-Za-z0-9._-]*)\.md\z/;
    my $id = $1;
    return undef if length($id) > 128;
    return undef if $id =~ /\.\./;
    return undef if $id =~ /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\z/i;
    return undef unless -f "$dir/$entry";
    return $id;
}

# ids() -> \@ids -- a directory listing, on purpose (no index, S6).
sub ids {
    my ($self) = @_;
    $self->_require_readable('ids');
    my $dir = $self->{dir};
    return [] unless -d $dir;

    opendir(my $dh, $dir) or _die(kind => 'io', path => $dir, errno => "$!");
    my @out;
    while (defined(my $entry = readdir($dh))) {
        my $id = _record_id_for($dir, $entry);
        push @out, $id if defined $id;
    }
    closedir $dh;
    return [ sort @out ];
}

# record_files_in($dir) -> \@paths -- sorted absolute paths of the records in
# $dir, using exactly the predicate ids() uses. Never dies: a missing
# directory yields (). Used by almanac-bug.pl's verify (package 09, S2.2) to
# discover records without going through a Store handle (verify walks
# directories found by shape, across possibly many stores).
sub record_files_in {
    my ($dir) = @_;
    return () unless defined $dir && -d $dir;
    opendir(my $dh, $dir) or return ();
    my @out;
    while (defined(my $entry = readdir($dh))) {
        my $id = _record_id_for($dir, $entry);
        push @out, "$dir/$entry" if defined $id;
    }
    closedir $dh;
    return sort @out;
}

sub exists {
    my ($self, $id) = @_;
    $self->_require_readable('exists');
    return 0 unless defined $id && $id =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
                 && length($id) <= 128 && $id !~ /\.\./;
    return -f $self->_record_path(_byte_id($id)) ? 1 : 0;
}

# _load_record($id, $path) -> \%record   -- shared by read/create/update/list
# and the recovery path, so there is exactly one place that turns on-disk
# bytes into the record hashref (S2.6).
#
# Calls Almanac::Record::read_file() ONCE -- not check_file() followed by
# read_file(), which would read and check_file() the same bytes TWICE
# (read_file does its own check() internally). list() calls this once per
# id in the store, so halving the I/O here halves the whole directory scan.
# read_file() dies with an Almanac::Record::Error on a structural problem;
# caught and re-raised in Store's OWN error shape (kind namespaces must not
# collide, S2.5) rather than reusing Record's error class.
sub _load_record {
    my ($self, $id, $path) = @_;
    unless (-f $path) {
        _die(kind => 'not_found', id => $id, path => $path);
    }
    $Almanac::Store::RECORD_READS++;
    my $rec = eval { Almanac::Record::read_file($path) };
    if (my $err = $@) {
        my $problems = (ref($err) eq 'Almanac::Record::Error') ? $err->{problems} : [];
        $self->_die_malformed($id, $path, $problems);
    }

    my $found = $rec->{fields}{id};
    if (!defined $found || $found ne $id) {
        _die(kind => 'id_mismatch', id => $id, found => (defined $found ? $found : undef), path => $path);
    }

    return {
        id     => $id,
        path   => $path,
        rank   => (CORE::exists $rec->{fields}{rank}   ? $rec->{fields}{rank}   : undef),
        writer => (CORE::exists $rec->{fields}{writer} ? $rec->{fields}{writer} : undef),
        rev    => Digest::SHA::sha256_hex($rec->{raw}),
        fields => { %{ $rec->{fields} } },
        order  => [ @{ $rec->{order} } ],
        body   => $rec->{body},
    };
}

sub _die_malformed {
    my ($self, $id, $path, $problems) = @_;
    my $count = scalar @$problems;
    _die(kind => 'malformed', id => $id, path => $path,
         problem_count => $count,
         first_line    => ($count ? $problems->[0]{line} : undef),
         problems      => $problems);
}

# =============================================================================
# 2.7 -- reads and the compare-and-swap mutations.
# =============================================================================
sub read {
    my ($self, $id) = @_;
    $self->_require_readable('read');
    $self->_validate_id($id);
    return $self->_load_record($id, $self->_record_path($id));
}

# _rank_id_cmp($ra, $rb, $ia, $ib) -> $cmp_result -- the ONE comparator for
# "rank first (cmp), then id, unranked after every ranked entry", shared
# verbatim between _list_records and _rank_scan (spec 18-almanac-insert-perf
# S2.2) so the two orderings cannot drift apart.
sub _rank_id_cmp {
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

# _list_records() -- the actual directory-scan-and-sort work, WITHOUT the
# recovery step. Shared by list() (the public verb) and reorder() (which
# already holds the store lock and must never re-enter it -- see MUST-4's
# note on _list_records below). Total order is (rank, id): rank_cmp first,
# ties (and unranked records) broken by id, unranked sorting after all
# ranked records.

sub _list_records {
    my ($self) = @_;
    my $ids = $self->ids;
    my @records;
    for my $id (@$ids) {
        push @records, $self->_load_record($id, $self->_record_path($id));
    }

    @records = sort { _rank_id_cmp($a->{rank}, $b->{rank}, $a->{id}, $b->{id}) } @records;

    return \@records;
}

# _rank_scan($self) -> \@entries -- the O(1)-per-insert replacement for
# calling list() just to learn neighbour ranks (spec 18-almanac-insert-perf
# S2.2). Each entry is { id, rank }, in the exact order _list_records would
# yield. Revalidates a per-handle cache against each record's stat signature
# AND seal digest -- a hit needs both to match, so a stale rank can never be
# served (see the spec's edge-case proof: any Store write that changes a
# record's bytes reseals it first, before its rename). Acquires no lock.
sub _rank_scan {
    my ($self) = @_;
    $self->recover if $self->{writable};

    my $ids   = $self->ids;
    my $cache = $self->{_rank_cache} ||= {};
    my %seen;
    my @entries;

    for my $id (@$ids) {
        $seen{$id} = 1;
        my $path = $self->_record_path($id);
        my @st   = stat($path);
        my $sig  = @st ? join(',', $st[0], $st[1], $st[7], $st[9], $st[10]) : '';

        my $seal;
        if (CORE::open(my $sfh, '<:raw', seal_path_for($path))) {
            local $/;
            $seal = <$sfh>;
            close $sfh;
        }

        my $c = $cache->{$id};
        my $rank;
        if ($c && $sig ne '' && $c->{sig} eq $sig && defined $seal && $c->{seal} eq $seal) {
            $rank = $c->{rank};
        } else {
            my $rec  = $self->_load_record($id, $path);
            my @st2  = stat($path);
            my $sig2 = @st2 ? join(',', $st2[0], $st2[1], $st2[7], $st2[9], $st2[10]) : '';
            if (defined $seal && $seal =~ /\A([0-9a-f]{64})\n\z/ && $1 eq $rec->{rev}
                && $sig ne '' && $sig eq $sig2) {
                $cache->{$id} = { sig => $sig, seal => $seal, rank => $rec->{rank} };
            } else {
                CORE::delete $cache->{$id};
            }
            $rank = $rec->{rank};
        }
        push @entries, { id => $id, rank => $rank };
    }

    for my $k (keys %$cache) {
        CORE::delete $cache->{$k} unless $seen{$k};
    }

    @entries = sort { _rank_id_cmp($a->{rank}, $b->{rank}, $a->{id}, $b->{id}) } @entries;
    return \@entries;
}

# list() -- runs recovery first (S2.11), then parses every record. A
# malformed record makes the WHOLE call die malformed (Decision 4: no
# silent skip, no partial result).
sub list {
    my ($self) = @_;
    $self->_require_readable('list');
    # HIGH-3 / SHOULD-6: recovery is a WRITE (it rewrites records, creates
    # .store.lock, deletes the journal). A readable-but-not-writable scope
    # (the exact shape Decision 7's amendment path exists to support) must
    # still be able to list() -- S2.11 already says an individual record is
    # valid whichever of the two ranks it currently holds, so simply
    # skipping recovery here is a legal (half-applied) order, not a
    # correctness violation.
    $self->recover if $self->{writable};
    return $self->_list_records;
}

# _build_order(\%fields, \@caller_order, $has_rank) -> @order
#
# Fixed field order (S2.6): id, rank (if present), writer, then the caller's
# fields in their own order, then any remaining fields in ASCII order -- so
# a no-op rewrite (restamping only writer) is byte-stable.
sub _build_order {
    my ($fields, $caller_order, $has_rank) = @_;
    my @out = ('id');
    push @out, 'rank' if $has_rank;
    push @out, 'writer';
    my %seen = map { $_ => 1 } @out;
    for my $k (@{ $caller_order || [] }) {
        next if $seen{$k}++;
        next unless CORE::exists $fields->{$k};
        push @out, $k;
    }
    for my $k (sort keys %$fields) {
        next if $seen{$k}++;
        push @out, $k;
    }
    return @out;
}

sub _die_from_lock_error {
    my ($self, $id, $path, $lock_err) = @_;
    my $kind = (ref $lock_err eq 'HASH') ? $lock_err->{kind} : '';
    if ($kind eq 'timeout') {
        my $holder = $lock_err->{holder};
        _die(kind => 'lock_timeout', id => $id, path => $path,
             waited_ms   => $lock_err->{waited_ms},
             timeout_ms  => $lock_err->{timeout_ms},
             holder_pid  => (ref $holder eq 'HASH' ? $holder->{pid}  : undef),
             holder_host => (ref $holder eq 'HASH' ? $holder->{host} : undef));
    } else {
        # 'reentrant' should never legitimately reach here (S5.1); if it
        # does, it is a bug in this module, not a real timeout -- map it to
        # io with the errno text rather than lying about the kind.
        my $errno = (ref $lock_err eq 'HASH')
                  ? (defined $lock_err->{errno} ? $lock_err->{errno} : $kind)
                  : "$lock_err";
        _die(kind => 'io', path => $path, errno => $errno);
    }
}

sub create {
    my ($self, %args) = @_;
    $self->_require_writable('create');

    # Default to a generated id only when the caller did not name one AT
    # ALL -- an explicitly-passed empty string is a REAL (invalid) id, not
    # an absent one, and must reach _validate_id below to die bad_id (AC-38).
    my $id = (CORE::exists $args{id} && defined $args{id}) ? $args{id} : Almanac::Record::new_id();
    $self->_validate_id($id);

    my $rank = CORE::exists $args{rank} ? $args{rank} : undef;
    if (defined $rank) {
        _die(kind => 'bad_rank', rank => $rank) unless rank_valid($rank);
    }
    if (ref $args{fields} eq 'HASH') {
        for my $k (keys %{ $args{fields} }) {
            _die(kind => 'usage', detail => "create: fields->{$k} must be a scalar, not a reference")
                if ref $args{fields}{$k};
        }
    }
    if (CORE::exists $args{body} && ref $args{body}) {
        _die(kind => 'usage', detail => 'create: body must be a scalar, not a reference');
    }

    my $path = $self->_record_path($id);
    File::Path::make_path($self->{dir}) unless -d $self->{dir};

    my ($lock, $lock_err) = Almanac::Lock->acquire($path, verb => 'create');
    unless ($lock) {
        $self->_die_from_lock_error($id, $path, $lock_err);
    }

    my $record;
    my $ok = eval {
        if (-e $path) {
            _die(kind => 'exists', id => $id, path => $path);
        }
        my %fields       = (ref $args{fields} eq 'HASH') ? %{ $args{fields} } : ();
        my @caller_order = (ref $args{order}  eq 'ARRAY') ? @{ $args{order} } : ();
        $fields{id} = $id;
        if (defined $rank) { $fields{rank} = $rank; } else { CORE::delete $fields{rank}; }
        $fields{writer} = writer_id();
        my @order = _build_order(\%fields, \@caller_order, defined $rank ? 1 : 0);

        my %rec_hash = (fields => \%fields, order => \@order);
        $rec_hash{body} = $args{body} if CORE::exists $args{body};

        $self->_write_record($path, \%rec_hash, 'create');
        $record = $self->_load_record($id, $path);
        1;
    };
    my $err = $@;
    $lock->release;
    die $err unless $ok;
    return $record;
}

sub _die_conflict {
    my ($self, $id, $path, $expect, $current, $actual_rev) = @_;
    my $winner = (CORE::exists $current->{fields}{writer} && length $current->{fields}{writer})
               ? $current->{fields}{writer} : undef;

    my $exp_fields = (ref $expect->{fields} eq 'HASH') ? $expect->{fields} : {};
    my $cur_fields = $current->{fields};
    my %all_keys   = map { $_ => 1 } (keys %$exp_fields, keys %$cur_fields);
    my %candidates;
    for my $k (keys %all_keys) {
        next if $k eq 'writer' || $k eq 'id';
        my $ee = CORE::exists $exp_fields->{$k};
        my $ce = CORE::exists $cur_fields->{$k};
        if ($ee != $ce) { $candidates{$k} = 1; next; }
        if ($ee && $ce && $exp_fields->{$k} ne $cur_fields->{$k}) { $candidates{$k} = 1; }
    }
    my $exp_body = defined $expect->{body}   ? $expect->{body}   : '';
    my $cur_body = defined $current->{body} ? $current->{body} : '';
    $candidates{body} = 1 if $exp_body ne $cur_body;

    my @sorted = sort keys %candidates;
    my $field  = @sorted ? $sorted[0] : 'writer';

    _die(kind => 'conflict', id => $id, field => $field, winner => $winner,
         expected_rev => $expect->{rev}, actual_rev => $actual_rev, path => $path);
}

sub update {
    my ($self, $id, %args) = @_;
    $self->_require_writable('update');
    $self->_validate_id($id);

    my $expect = $args{expect};
    unless (ref $expect eq 'HASH' && defined $expect->{rev} && ref $expect->{fields} eq 'HASH') {
        _die(kind => 'usage', detail => 'update requires expect => { rev, fields } from a previous read/create/update');
    }
    if (ref $args{set} eq 'HASH') {
        for my $k (keys %{ $args{set} }) {
            _die(kind => 'reserved_field', id => $id, field => $k)
                if $k eq 'id' || $k eq 'rank' || $k eq 'writer';
            _die(kind => 'usage', detail => "update: set->{$k} must be a scalar, not a reference")
                if ref $args{set}{$k};
        }
    }
    if (ref $args{unset} eq 'ARRAY') {
        for my $k (@{ $args{unset} }) {
            _die(kind => 'reserved_field', id => $id, field => $k)
                if $k eq 'id' || $k eq 'rank' || $k eq 'writer';
        }
    }
    if (CORE::exists $args{rank} && defined $args{rank}) {
        _die(kind => 'bad_rank', rank => $args{rank}) unless rank_valid($args{rank});
    }
    if (CORE::exists $args{body} && ref $args{body}) {
        _die(kind => 'usage', detail => 'update: body must be a scalar, not a reference');
    }

    my $path = $self->_record_path($id);
    # LOW-6: check existence CHEAPLY before creating directory structure or
    # taking a lock for a record that never existed -- the authoritative
    # check (inside the lock, below) still runs; this is only an early,
    # cheap short-circuit so a bogus id does not litter the store with a
    # directory tree plus permanent lock sidecars.
    unless (-f $path) {
        _die(kind => 'not_found', id => $id, path => $path);
    }
    File::Path::make_path($self->{dir}) unless -d $self->{dir};

    my ($lock, $lock_err) = Almanac::Lock->acquire($path, verb => 'update');
    unless ($lock) {
        $self->_die_from_lock_error($id, $path, $lock_err);
    }

    my $record;
    my $ok = eval {
        unless (-f $path) {
            _die(kind => 'not_found', id => $id, path => $path);
        }
        $Almanac::Store::RECORD_READS++;
        my $current = eval { Almanac::Record::read_file($path) };
        if (my $rerr = $@) {
            my $problems = (ref($rerr) eq 'Almanac::Record::Error') ? $rerr->{problems} : [];
            $self->_die_malformed($id, $path, $problems);
        }
        my $cur_id  = $current->{fields}{id};
        if (!defined $cur_id || $cur_id ne $id) {
            _die(kind => 'id_mismatch', id => $id, found => (defined $cur_id ? $cur_id : undef), path => $path);
        }
        # THE CAS, UNDER THE LOCK, AFTER ACQUISITION (S1.4 / DC2). This is
        # what turns "exactly one winner, one loser" into a guarantee: the
        # lock already serialized both writers, and this comparison refuses
        # whichever one decided its write against content that has since
        # changed.
        my $actual_rev = Digest::SHA::sha256_hex($current->{raw});
        if ($actual_rev ne $expect->{rev}) {
            $self->_die_conflict($id, $path, $expect, $current, $actual_rev);
        }

        my %fields = %{ $current->{fields} };
        if (ref $args{set} eq 'HASH') {
            $fields{$_} = $args{set}{$_} for keys %{ $args{set} };
        }
        if (ref $args{unset} eq 'ARRAY') {
            CORE::delete $fields{$_} for @{ $args{unset} };
        }
        my $has_rank = CORE::exists $fields{rank};
        if (CORE::exists $args{rank}) {
            if (defined $args{rank}) { $fields{rank} = $args{rank}; $has_rank = 1; }
            else                     { CORE::delete $fields{rank}; $has_rank = 0; }
        }
        $fields{id}     = $id;
        $fields{writer} = writer_id();

        my @old_order = @{ $current->{order} };
        my %present   = map { $_ => 1 } @old_order;
        for my $k (keys %fields) {
            push @old_order, $k unless $present{$k}++;
        }
        @old_order = grep { CORE::exists $fields{$_} } @old_order;

        my @order = _build_order(\%fields, \@old_order, $has_rank);
        my $body  = CORE::exists $args{body} ? $args{body} : $current->{body};

        $self->_write_record($path, { fields => \%fields, order => \@order, body => $body }, 'update');
        $record = $self->_load_record($id, $path);
        1;
    };
    my $err = $@;
    $lock->release;
    die $err unless $ok;
    return $record;
}

sub delete {
    my ($self, $id, %args) = @_;
    $self->_require_writable('delete');
    $self->_validate_id($id);

    my $expect = $args{expect};
    unless (ref $expect eq 'HASH' && defined $expect->{rev} && ref $expect->{fields} eq 'HASH') {
        _die(kind => 'usage', detail => 'delete requires expect => { rev, fields } from a previous read/create/update');
    }

    my $path = $self->_record_path($id);
    # LOW-6: see the matching comment in update() -- cheap existence
    # short-circuit before make_path/lock-acquire litter the store.
    unless (-f $path) {
        _die(kind => 'not_found', id => $id, path => $path);
    }
    File::Path::make_path($self->{dir}) unless -d $self->{dir};

    my ($lock, $lock_err) = Almanac::Lock->acquire($path, verb => 'delete');
    unless ($lock) {
        $self->_die_from_lock_error($id, $path, $lock_err);
    }

    my $ok = eval {
        unless (-f $path) {
            _die(kind => 'not_found', id => $id, path => $path);
        }
        $Almanac::Store::RECORD_READS++;
        my $current = eval { Almanac::Record::read_file($path) };
        if (my $rerr = $@) {
            my $problems = (ref($rerr) eq 'Almanac::Record::Error') ? $rerr->{problems} : [];
            $self->_die_malformed($id, $path, $problems);
        }
        my $cur_id  = $current->{fields}{id};
        if (!defined $cur_id || $cur_id ne $id) {
            _die(kind => 'id_mismatch', id => $id, found => (defined $cur_id ? $cur_id : undef), path => $path);
        }
        my $actual_rev = Digest::SHA::sha256_hex($current->{raw});
        if ($actual_rev ne $expect->{rev}) {
            $self->_die_conflict($id, $path, $expect, $current, $actual_rev);
        }
        # The record file goes; its .lock/.lock.holder sidecars do not
        # (S1.1 / AC-44). This module contains no unlink of a path ending
        # .lock or .lock.holder, anywhere, on any path.
        unlink($path) or _die(kind => 'io', path => $path, errno => "$!");
        # The .seal goes too (package 09, S2.2) -- best-effort, its absence
        # is not an error.
        my $seal_path = seal_path_for($path);
        unlink($seal_path) if -e $seal_path;
        1;
    };
    my $err = $@;
    $lock->release;
    die $err unless $ok;
    return 1;
}

# =============================================================================
# 2.9 -- the single write path, and the one test seam.
# =============================================================================
our $ON_BEFORE_RENAME;   # TEST SEAM ONLY. undef on every product code path.
our $RECORD_READS = 0;   # TEST SEAM -- see spec 18-almanac-insert-perf S2.1. Counts every read
                         # of a record file's (<id>.md) bytes. No product code reads this.

sub _write_record {
    my ($self, $path, $record, $verb) = @_;
    # MEDIUM-3: Almanac::Record::serialize dies with an Almanac::Record::Error
    # on a structural refusal (bad field name, forbidden byte, non-UTF-8
    # body/value). Wrapped and re-raised in Store's OWN error shape -- S2.5's
    # kind namespaces must not collide, and every Store mutation must end
    # with Store's machine-block contract, not Record's.
    my $bytes = eval { Almanac::Record::serialize({ %$record, path => $path }) };
    if (my $rerr = $@) {
        my $detail = (ref($rerr) eq 'Almanac::Record::Error' && defined $rerr->{message})
                   ? $rerr->{message} : "$rerr";
        $detail =~ s/\s+\z//;
        _die(kind => 'refused', path => $path, detail => $detail);
    }
    my $tmp = "$path.tmp." . _tmp_nonce();
    # SHOULD-11: both I/O failures below are about $tmp, not $path -- $path
    # may not even exist yet on a create(). Report the path that actually
    # failed.
    CORE::open(my $fh, '>:raw', $tmp) or _die(kind => 'io', path => $tmp, errno => "$!");
    # MEDIUM-4: check print's return value alongside close's -- a short/
    # failed print followed by a successful close would otherwise rename a
    # truncated file over a good record (Lock.pm:487-493's own pattern).
    my $printed = print {$fh} $bytes;
    my $closed  = close($fh);
    unless ($printed && $closed) {
        unlink $tmp;
        _die(kind => 'io', path => $tmp, errno => "$!");
    }

    # Package 09 (S2.2, layer three): the seal is written BEFORE the rename,
    # atomically, while $path still holds whatever bytes preceded this write
    # (or nothing, on a create). A crash between here and the rename leaves a
    # seal whose line 1 matches no record bytes and whose line 2 (the "old"
    # digest) still matches $path -- the record stays verifiably intact.
    #
    # FIX-BATCH (post-review 09, S6): line 2 is written ONLY when the bytes it
    # would record were themselves already verified -- check_seal($path)
    # returned 'intact' (a sanctioned write covers them) or 'unsealed' (no
    # seal ever claimed them, so there is nothing to launder). If the
    # existing seal already says 'tampered'/'bad_seal'/'unreadable', a crash
    # between this seal write and the rename must NOT let the two-line seal
    # verify those already-bad bytes as intact -- that would launder an
    # out-of-band write into a clean state. A successful (non-crashing)
    # update also does a read-modify-write of the CURRENT bytes either way;
    # omitting line 2 here means it carries forward as a freshly single-line
    # sealed record, not as a false 'intact' for content nobody sanctioned.
    my $new_digest = Digest::SHA::sha256_hex($bytes);
    my $seal_path  = seal_path_for($path);
    my $old_digest;
    if (-f $path) {
        my $pre_check = check_seal($path);
        if ($pre_check->{state} eq 'intact' || $pre_check->{state} eq 'unsealed') {
            my $d = $pre_check->{digest};
            $old_digest = $d if defined $d && $d ne $new_digest;
        }
    }
    my $seal_body = defined $old_digest ? "$new_digest\n$old_digest\n" : "$new_digest\n";
    unless (_write_seal_atomic($seal_path, $seal_body)) {
        unlink $tmp;
        _die(kind => 'io', path => $seal_path, errno => "$!");
    }

    $ON_BEFORE_RENAME->($path, $tmp, $verb) if ref $ON_BEFORE_RENAME eq 'CODE';
    my ($ok, $rerr2) = Almanac::Lock::rename_with_retry($tmp, $path);
    unless ($ok) {
        unlink $tmp;
        _die(kind => 'io', path => $path, errno => (ref $rerr2 eq 'HASH' ? $rerr2->{errno} : "$rerr2"));
    }

    # Best-effort final reseal: one line, the new digest alone. A failure
    # here is not an error -- the two-line seal already written above still
    # verifies the new bytes (line 1), so nothing is left unverifiable.
    _write_seal_atomic($seal_path, "$new_digest\n");

    return $new_digest;
}

# _write_seal_atomic($seal_path, $body) -> 1 | 0 -- temp file plus
# Almanac::Lock::rename_with_retry, the same atomic-write discipline
# _write_record uses for the record itself. Runs inside the caller's
# existing record lock; acquires none of its own.
sub _write_seal_atomic {
    my ($seal_path, $body) = @_;
    my $tmp = "$seal_path.tmp." . _tmp_nonce();
    CORE::open(my $fh, '>:raw', $tmp) or return 0;
    my $printed = print {$fh} $body;
    my $closed  = close($fh);
    unless ($printed && $closed) {
        unlink $tmp;
        return 0;
    }
    my ($ok, $rerr) = Almanac::Lock::rename_with_retry($tmp, $seal_path);
    unless ($ok) {
        unlink $tmp;
        return 0;
    }
    return 1;
}

# check_seal($record_path) -> \%result -- a pure read. Never dies, takes no
# lock, writes nothing (S2.2).
sub check_seal {
    my ($record_path) = @_;
    my $bytes;
    if (CORE::open(my $fh, '<:raw', $record_path)) {
        $Almanac::Store::RECORD_READS++;
        local $/;
        $bytes = <$fh>;
        close $fh;
    }
    return { state => 'unreadable', digest => undef, sealed => [] } unless defined $bytes;
    my $digest = Digest::SHA::sha256_hex($bytes);

    my $seal_path = seal_path_for($record_path);
    return { state => 'unsealed', digest => $digest, sealed => [] } unless -f $seal_path;

    my $raw;
    if (CORE::open(my $sfh, '<:raw', $seal_path)) {
        local $/;
        $raw = <$sfh>;
        close $sfh;
    }
    return { state => 'bad_seal', digest => $digest, sealed => [] } unless defined $raw;

    my @lines = split(/\n/, $raw, -1);
    pop @lines if @lines && $lines[-1] eq '';   # trailing split artefact from the final \n
    return { state => 'bad_seal', digest => $digest, sealed => [] } unless @lines == 1 || @lines == 2;
    for my $l (@lines) {
        return { state => 'bad_seal', digest => $digest, sealed => [] }
            unless $l =~ /\A[0-9a-f]{64}\z/;
    }
    # Reconstruct and compare byte-for-byte: the format is exactly one or two
    # 64-lowercase-hex lines, each terminated by \n, and nothing else.
    my $expected = join('', map { "$_\n" } @lines);
    return { state => 'bad_seal', digest => $digest, sealed => [] } unless $expected eq $raw;

    if (grep { $_ eq $digest } @lines) {
        return { state => 'intact', digest => $digest, sealed => \@lines };
    }
    return { state => 'tampered', digest => $digest, sealed => \@lines };
}

sub _tmp_nonce {
    my $wid = writer_id();
    my ($hex) = $wid =~ /([0-9a-f]{4})\z/;
    $hex = 'xxxx' unless defined $hex;
    return "$$-$hex";
}

# =============================================================================
# 2.10 -- rank keys. Base-62 STRINGS, no arithmetic on a fixed-width number
# anywhere. R1: a rank matches [0-9A-Za-z]+ and never ends in '0' -- that is
# what makes bytewise cmp equal fraction order and makes rank_between
# provably terminate (S2.10).
# =============================================================================
my @ALPHABET = ('0' .. '9', 'A' .. 'Z', 'a' .. 'z');
my %VAL_OF   = map { $ALPHABET[$_] => $_ } 0 .. $#ALPHABET;
my $BASE     = scalar @ALPHABET;    # 62

sub _digit { return $ALPHABET[$_[0]] }
sub _val   { return $VAL_OF{$_[0]} }

sub rank_valid {
    my ($r) = @_;
    return 0 unless defined $r && length $r;
    return 0 unless $r =~ /\A[0-9A-Za-z]+\z/;
    return 0 if substr($r, -1) eq '0';
    return 1;
}

sub rank_cmp { return $_[0] cmp $_[1] }

# rank_between($a, $b) -> $rank   -- undef $a = before everything (0), undef
# $b = after everything (no upper bound). Requires $a lt $b when both
# defined. The algorithm is S2.10's pseudocode, unmodified: it walks digit
# positions, emitting the midpoint digit the instant the neighbours' digits
# differ by 2 or more, which is the loop's only exit.
sub rank_between {
    my ($a, $b) = @_;
    for my $r ($a, $b) {
        next unless defined $r;
        _die(kind => 'bad_rank', rank => $r) unless rank_valid($r);
    }
    if (defined $a && defined $b) {
        _die(kind => 'usage', detail => 'rank_between requires a lt b (byte comparison)')
            unless $a lt $b;
    }

    my $upper_bounded = defined $b;
    my $i   = 0;
    my $out = '';
    while (1) {
        my $da = (defined $a && $i < length($a)) ? _val(substr($a, $i, 1)) : 0;
        my $db = $upper_bounded ? (($i < length($b)) ? _val(substr($b, $i, 1)) : 0) : $BASE;
        my $gap = $db - $da;
        if ($gap >= 2) {
            $out .= _digit($da + int($gap / 2));
            return $out;
        } elsif ($gap == 1) {
            $out .= _digit($da);
            $upper_bounded = 0;
        } else {
            $out .= _digit($da);
        }
        $i++;
    }
}

# rank_jitter() -> $suffix -- 4 chars, each drawn from indices 1..61 (never
# index 0 = '0', preserving R1 closure on the minted rank_between().jitter
# string). Exists because rank_between is PURE: two concurrent insert_last
# calls reading the same neighbours would otherwise mint the identical key,
# and DC3 demands two distinct ranks. A pure function is not a source of
# uniqueness. Deliberately no srand -- Perl's implicit per-process seeding
# already mixes pid and OS entropy (AC-15).
sub rank_jitter {
    my $out = '';
    $out .= _digit(1 + int(rand($BASE - 1))) for 1 .. 4;
    return $out;
}

sub _base62_fixed {
    my ($v, $w) = @_;
    my @digits;
    for (1 .. $w) {
        unshift @digits, _digit($v % $BASE);
        $v = int($v / $BASE);
    }
    return join('', @digits);
}

# _sequential_ranks($n) -> \@ranks -- used only by reorder(), under the
# store lock, so no jitter is needed (nothing else can mint concurrently).
sub _sequential_ranks {
    my ($n) = @_;
    return [] if $n <= 0;
    my $w = 1;
    $w++ while ($BASE ** $w) < ($n + 1);
    my @ranks;
    for my $i (1 .. $n) {
        my $v = int($i * ($BASE ** $w) / ($n + 1));
        my $r = _base62_fixed($v, $w);
        $r .= 'V' if substr($r, -1) eq '0';
        push @ranks, $r;
    }
    return \@ranks;
}

# =============================================================================
# 2.11 -- ordering verbs, reorder(), and recovery.
# =============================================================================
sub insert_first {
    my ($self, %args) = @_;
    $self->_require_writable('insert_first');
    my $list  = $self->_rank_scan();
    my $first = @$list ? $list->[0]{rank} : undef;
    my $rank  = rank_between(undef, $first) . rank_jitter();
    return $self->create(%args, rank => $rank);
}

sub insert_last {
    my ($self, %args) = @_;
    $self->_require_writable('insert_last');
    my $list = $self->_rank_scan();
    # CRITICAL-1: $list->[-1] is only the true maximum RANK when the last
    # entry in list()'s DISPLAY order is itself ranked. list() sorts
    # unranked records after every ranked one (S2.10), so the instant any
    # unranked record exists, $list->[-1] is that unranked record and its
    # rank is undef -- which would mint near the MIDDLE of the rank space
    # (rank_between(undef,undef)) instead of after the true maximum. Take
    # the maximum over ranked records only; @$list is already rank-sorted,
    # so a grep suffices (no re-sort needed).
    my @ranked = grep { defined $_->{rank} } @$list;
    my $last   = @ranked ? $ranked[-1]{rank} : undef;
    my $rank = rank_between($last, undef) . rank_jitter();
    return $self->create(%args, rank => $rank);
}

sub _insert_relative {
    my ($self, $ref_id, $where, %args) = @_;
    $self->_require_writable($where);
    # Existence checked CHEAPLY (a directory stat, via exists()) before the
    # full _rank_scan() parse: _rank_scan() dies malformed/id_mismatch on ANY
    # corrupt record in the store (Decision 4, no partial result), which must
    # not stand between a caller and the not_found this ref_id deserves when
    # it is simply absent. Once ref_id is confirmed present, _rank_scan() is
    # still exactly what S2.11 step 2 specifies for computing neighbour ranks.
    unless ($self->exists($ref_id)) {
        _die(kind => 'not_found', id => $ref_id, path => $self->_record_path($ref_id));
    }
    my $list = $self->_rank_scan();
    my ($ref_rec) = grep { $_->{id} eq $ref_id } @$list;
    unless ($ref_rec) {
        _die(kind => 'not_found', id => $ref_id, path => $self->_record_path($ref_id));
    }
    my $ref_rank = $ref_rec->{rank};

    # Neighbours are found by RANK VALUE, not by raw position in list()'s
    # DISPLAY order. Those agree whenever ref_id itself carries a rank (the
    # common case) -- but list() deliberately sorts an unranked record
    # AFTER every ranked one (S2.10's total-order rule), so an unranked
    # ref_id permanently drifts to the tail, and NOTHING can ever sort
    # literally "after" it in display order -- there is no rank value that
    # would land past an unranked tail record.
    my @ranked = sort { $a->{rank} cmp $b->{rank} } grep { defined $_->{rank} } @$list;
    my $first_ranked = @ranked ? $ranked[0]{rank} : undef;

    # MUST-2 / HIGH-4: when ref_id itself carries no rank, insert_before and
    # insert_after must agree with EACH OTHER, not land on opposite sides.
    # The previous code split the difference inconsistently -- insert_after
    # landed before every ranked record while insert_before landed after
    # every ranked record -- so a before-call could end up sorting AFTER an
    # after-call against the identical reference (redteam's repro:
    # after1 < before1). Since "after the unranked tail" is structurally
    # unreachable (list() always sorts unranked last, so nothing can beat
    # it), the only convention where "before" and "after" do not swap is to
    # treat an unranked ref as sitting before every ranked record for BOTH
    # verbs: each new insert lands at the front of the ranked block, and
    # (rank, id) plus call order then keeps a later insert_before strictly
    # ahead of an earlier insert_after (and vice versa) against the same
    # unranked ref -- correct relative ordering, even though neither can
    # literally sandwich the unranked reference itself.
    #
    # This is also the ONLY convention consistent with AC-16/AC-17 (the
    # immutable ordering oracle), which repeats insert_after against one
    # unranked anchor 1000 times and requires LIFO stacking at the front
    # (list order = exact reverse of insertion order) -- the "after
    # everything ranked" convention the review/redteam reports suggest for
    # BOTH verbs was tried first and breaks that oracle outright (it turns
    # the LIFO stack into FIFO). Recorded as a deliberate deviation from
    # the reports' literal suggestion, not an oversight.
    my ($lo, $hi);
    if (!defined $ref_rank) {
        ($lo, $hi) = (undef, $first_ranked);
    } elsif ($where eq 'insert_before') {
        $hi = $ref_rank;
        my @less = grep { $_->{rank} lt $ref_rank } @ranked;
        $lo = @less ? $less[-1]{rank} : undef;
    } else {
        $lo = $ref_rank;
        my @more = grep { $_->{rank} gt $ref_rank } @ranked;
        $hi = @more ? $more[0]{rank} : undef;
    }
    my $rank = rank_between($lo, $hi) . rank_jitter();
    return $self->create(%args, rank => $rank);
}

sub insert_before { my ($self, $ref_id, %args) = @_; return $self->_insert_relative($ref_id, 'insert_before', %args) }
sub insert_after  { my ($self, $ref_id, %args) = @_; return $self->_insert_relative($ref_id, 'insert_after',  %args) }

sub _journal_path { return "$_[0]->{dir}/.reorder-journal.json" }

sub _write_journal {
    my ($self, $data) = @_;
    my $path  = $self->_journal_path;
    my $bytes = JSON::PP->new->canonical->encode($data);
    my $tmp   = "$path.tmp." . _tmp_nonce();
    CORE::open(my $fh, '>:raw', $tmp) or _die(kind => 'io', path => $path, errno => "$!");
    print {$fh} $bytes;
    close($fh) or _die(kind => 'io', path => $path, errno => "$!");
    my ($ok, $rerr) = Almanac::Lock::rename_with_retry($tmp, $path);
    unless ($ok) {
        unlink $tmp;
        _die(kind => 'io', path => $path, errno => (ref $rerr eq 'HASH' ? $rerr->{errno} : "$rerr"));
    }
    return 1;
}

# _rollback_pending_journal() -- the actual recovery work, assuming the
# STORE LOCK IS ALREADY HELD by the caller (either reorder(), finishing a
# previous crashed reorder before starting its own, or recover(), which
# acquires the lock itself first). This sub never calls Almanac::Lock-
# >acquire on the store-lock target itself -- only reorder() and recover()
# do (AC-20) -- so calling it from inside reorder() is not a reentrant
# acquire.
#
# ROLLBACK, NOT ROLL-FORWARD (DC5): the criterion is that a crash mid-
# reorder leaves the PREVIOUS order intact, so every entry is rewritten back
# to its prev_rank, never forward to next_rank.
#
# Return value: 1 iff every entry in the journal was confirmed already-
# correct or successfully rewritten (and the journal was then removed); 0
# if nothing was there to recover, the journal itself could not be
# honoured (and was removed as a self-healing measure -- MEDIUM-1/MUST-4),
# or ANY entry was skipped (HIGH-2/MUST-5: the journal is deliberately kept
# in that case so a later call can retry -- retrying is idempotent by
# design).
sub _rollback_pending_journal {
    my ($self) = @_;
    my $journal_path = $self->_journal_path;
    return 0 unless -e $journal_path;

    my $raw = do {
        CORE::open(my $fh, '<:raw', $journal_path) or return 0;
        local $/;
        my $c = <$fh>;
        close $fh;
        $c;
    };
    my $data = eval { JSON::PP->new->decode($raw) };
    unless (ref $data eq 'HASH' && ref $data->{entries} eq 'HASH') {
        # MUST-4 / MEDIUM-1: an undecodable/malformed journal carries no
        # rollback information -- retaining it can only block every future
        # list() (each one pays the store-lock acquire forever) and never
        # help. Self-heal: unlink it and report nothing was recovered.
        unlink($journal_path);
        return 0;
    }

    my $incomplete = 0;
    for my $id (sort keys %{ $data->{entries} }) {
        my $entry     = $data->{entries}{$id};
        my $prev_rank = $entry->{prev_rank};
        my $path      = $self->_record_path($id);
        # The record is simply gone (deleted after the crashed reorder) --
        # there is nothing left to roll back TO, and no future retry can
        # change that, so this is not "incomplete", it is genuinely done.
        next unless -f $path;

        # HIGH-1: acquire the per-record lock FIRST, then re-read under it
        # -- exactly reorder()'s own discipline (Store.pm _load_record call
        # inside its per-record eval, below). The previous ordering read
        # the record's state BEFORE the lock and wrote that stale snapshot
        # after acquiring, silently overwriting a concurrent, legitimately-
        # successful update() that landed in the window between the two.
        my ($rlock, $rlock_err) = Almanac::Lock->acquire($path, verb => 'recover');
        unless ($rlock) {
            # HIGH-2/MUST-5: a merely-busy or timed-out lock is NOT the same
            # as "nothing to do here" -- mark incomplete so the journal
            # survives for a retry instead of being silently discarded.
            $incomplete = 1;
            next;
        }

        my $rok = eval {
            my $cur      = $self->_load_record($id, $path);
            my $cur_rank = $cur->{rank};
            my $same = (defined $prev_rank && defined $cur_rank) ? ($prev_rank eq $cur_rank)
                     : (!defined $prev_rank && !defined $cur_rank);
            unless ($same) {
                my %fields = %{ $cur->{fields} };
                if (defined $prev_rank) { $fields{rank} = $prev_rank; } else { CORE::delete $fields{rank}; }
                $fields{id}     = $id;
                $fields{writer} = writer_id();
                my @order = _build_order(\%fields, $cur->{order}, defined $prev_rank ? 1 : 0);
                $self->_write_record($path, { fields => \%fields, order => \@order, body => $cur->{body} }, 'recover');
            }
            1;
        };
        $rlock->release;
        $incomplete = 1 unless $rok;
    }

    unlink($journal_path) unless $incomplete;
    return $incomplete ? 0 : 1;
}

sub recover {
    my ($self) = @_;
    # HIGH-3 / SHOULD-6: recovery is a write; refuse it outright on a
    # read-only scope rather than letting the caller's mistake surface as a
    # confusing io error from what looks like a read.
    return 0 unless $self->{writable};
    return 0 unless -e $self->_journal_path;

    # MEDIUM-2: take the store lock NON-BLOCKING. A journal whose owner
    # still holds the store lock (an in-flight reorder()) is by definition
    # not abandoned -- it is not this call's job to wait out someone else's
    # reorder, and S5.3 explicitly accepts a concurrent read seeing the
    # current on-disk state as a non-failing degradation. Blocking here for
    # the full default timeout turned "an insert_* concurrent with a
    # reorder" into a lock_timeout die, which S5.3 never promised.
    my ($lock, $lock_err) = Almanac::Lock->acquire("$self->{dir}/.store", verb => 'recover', timeout_ms => 0);
    unless ($lock) {
        my $kind = (ref $lock_err eq 'HASH') ? $lock_err->{kind} : '';
        return 0 if $kind eq 'timeout';   # busy, not abandoned -- proceed against current state
        $self->_die_from_lock_error(undef, "$self->{dir}/.store", $lock_err);
    }
    my $result = eval { $self->_rollback_pending_journal() };
    my $err = $@;
    $lock->release;
    die $err if $err;
    return $result;
}

# reorder(\@ids) -> \@records -- THE ONLY OPERATION THAT TAKES THE STORE-WIDE
# LOCK (Decision 10), target <dir>/.store (so the lock file is .store.lock,
# never removed -- S1.1). Lock order is always store lock -> record lock,
# never the reverse, and nothing else in this module ever takes the store
# lock, so there is no cycle (S5.1).
sub reorder {
    my ($self, $ids) = @_;
    _die(kind => 'usage', detail => 'reorder requires an arrayref of ids')
        unless ref $ids eq 'ARRAY';
    $self->_require_writable('reorder');
    File::Path::make_path($self->{dir}) unless -d $self->{dir};

    my ($lock, $lock_err) = Almanac::Lock->acquire("$self->{dir}/.store", verb => 'reorder');
    unless ($lock) {
        $self->_die_from_lock_error(undef, "$self->{dir}/.store", $lock_err);
    }

    my $records;
    my $ok = eval {
        # MUST-4: use the recovery-free helper, not list() -- list() would
        # unconditionally call recover(), which re-acquires the store lock
        # THIS sub already holds, producing a 'reentrant' lock error every
        # time a journal happens to still be on disk when this runs. The
        # rollback above already ran directly (no re-acquire, AC-20), so
        # the store lock is never re-entered anywhere in this call.
        $self->_rollback_pending_journal();

        my $before      = $self->_list_records();
        my @current_ids = map { $_->{id} } @$before;
        my %prev_rank   = map { $_->{id} => $_->{rank} } @$before;
        my %have        = map { $_ => 1 } @current_ids;
        my %given       = map { $_ => 1 } @$ids;

        my @missing = sort grep { !$given{$_} } @current_ids;
        my @unknown = sort grep { !$have{$_}  } @$ids;
        # MUST-3: the checks above are set-based only, so a duplicate id in
        # @$ids satisfies them as long as the SET matches -- a list with a
        # repeat is not a permutation (spec S2.11 step 3). Detect the
        # cardinality mismatch and report the first repeated id.
        my %given_count;
        $given_count{$_}++ for @$ids;
        my @dups = sort grep { $given_count{$_} > 1 } keys %given_count;
        if (@missing || @unknown || @dups) {
            _die(kind => 'reorder_mismatch',
                 missing_count => scalar(@missing),
                 unknown_count => scalar(@unknown) + scalar(@dups),
                 first_missing => (@missing ? $missing[0] : undef),
                 first_unknown => (@unknown ? $unknown[0] : (@dups ? $dups[0] : undef)));
        }

        my $new_ranks = _sequential_ranks(scalar @$ids);
        my %next_rank;
        for my $i (0 .. $#$ids) {
            $next_rank{ $ids->[$i] } = $new_ranks->[$i];
        }

        my %journal_entries;
        for my $id (@$ids) {
            $journal_entries{$id} = { prev_rank => $prev_rank{$id}, next_rank => $next_rank{$id} };
        }
        $self->_write_journal({
            version    => 1,
            writer     => writer_id(),
            started_at => time(),
            entries    => \%journal_entries,
        });

        for my $id (@$ids) {
            my $rpath = $self->_record_path($id);
            my ($rlock, $rlock_err) = Almanac::Lock->acquire($rpath, verb => 'reorder');
            unless ($rlock) {
                $self->_die_from_lock_error($id, $rpath, $rlock_err);
            }
            my $rok = eval {
                my $cur = $self->_load_record($id, $rpath);
                my %fields = %{ $cur->{fields} };
                $fields{rank}   = $next_rank{$id};
                $fields{id}     = $id;
                $fields{writer} = writer_id();
                my @order = _build_order(\%fields, $cur->{order}, 1);
                $self->_write_record($rpath, { fields => \%fields, order => \@order, body => $cur->{body} }, 'reorder');
                1;
            };
            my $rerr = $@;
            $rlock->release;
            die $rerr unless $rok;
        }

        unlink($self->_journal_path);
        $records = $self->_list_records();
        1;
    };
    my $err = $@;
    $lock->release;
    die $err unless $ok;
    return $records;
}

1;
