# BpDataRoot.pm — the single, bounded data-root resolution chain shared by
# bp-drive-next.pl and bp-lifecycle.pl (blueprint never-halt, package 04).
#
# Bug 0f1e: an unbounded walk-up for .ccpraxis-local-data, duplicated in both
# scripts, climbed out of a temp-dir cwd and adopted the real home data root.
# This module is that walk-up, written once, bounded at the OS temp dir and
# at the user's home dir (neither is adopted unless it IS the cwd), and used
# by both scripts.
#
# CONTRACT (see spec 04-director-args-and-root-spec.md §2.1): every function
# here never writes, creates or deletes a file/dir; never chdir()s; never
# modifies %ENV; prints nothing; and never dies (an internal failure degrades
# to the next step in the chain). Spawning `git` is the only external action,
# and even that is a test-seamed, best-effort read.
package BpDataRoot;
use strict;
use warnings;
no warnings 'redefine';
use Cwd ();
use File::Spec ();

# Double-load safety (spec §2.1): this file may be require'd twice under two
# different path spellings in one process (%INC keys are spelling-sensitive
# so `require` re-parses the file wholesale). The `no warnings 'redefine'`
# above, in effect for the rest of this file, is what keeps that harmless.

my $IS_WIN = ($^O =~ /^(MSWin32|msys|cygwin)$/) ? 1 : 0;

# macOS: APFS (the default volume format) is case-insensitive, and Cwd::abs_path
# keeps whatever case a path was TYPED with, so "/users/x" and "/Users/x" name
# one directory there and must compare equal -- otherwise a cwd spelled in the
# "wrong" case never matches the HOME stop and the walk climbs straight past it.
# Case folding only: drive forms and 8.3 short names stay Windows-only.
my $IS_DARWIN = ($^O eq 'darwin') ? 1 : 0;

# ---------------------------------------------------------------------------
# Lexical path canonicalisation and same_path() (spec §2.1)
# ---------------------------------------------------------------------------

sub _fold_ascii {
    my ($s) = @_;
    return $s unless defined $s;
    (my $t = $s) =~ tr/A-Z/a-z/;
    return $t;
}

sub _is_abs_ish {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    return 1 if $p =~ m{^/};
    return 1 if $p =~ m{^[A-Za-z]:[\\/]};
    return 1 if $IS_WIN && $p =~ m{^\\};
    return 0;
}

# \ -> /; on Windows-family perls, /x/... or /x -> x:/..., and X:/ -> x:/;
# collapse repeated /, drop . segments, collapse seg/.. lexically; strip a
# trailing / except from a bare root (/, x:/).
sub _lex_canon {
    my ($p) = @_;
    return '' unless defined $p;
    (my $s = $p) =~ s{\\}{/}g;

    my $drive_prefix = '';
    if ($IS_WIN) {
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
        if ($seg eq '..') {
            pop @out if @out;
            next;
        }
        push @out, $seg;
    }

    my $canon = $is_abs ? ('/' . join('/', @out)) : join('/', @out);
    $canon = $drive_prefix . $canon if length $drive_prefix;

    unless ($canon =~ m{^(?:[a-z]:)?/\z}) {
        $canon =~ s{/\z}{};
    }
    return $canon;
}

sub _seg_eq {
    my ($x, $y, $allow_83) = @_;
    $allow_83 = 1 unless defined $allow_83;
    return $x eq $y unless $IS_WIN || $IS_DARWIN;
    return 1 if _fold_ascii($x) eq _fold_ascii($y);
    return 0 unless $IS_WIN && $allow_83;

    # 8.3 tolerance (duplicates WriteGuards::_seg_eq_base's rule; package 02's
    # file is a heavy hook dependency this module must not require).
    for my $pair ([$x, $y], [$y, $x]) {
        my ($short, $long) = @$pair;
        next unless defined $short && $short =~ /^([^~\/]{1,6})~[0-9]+(?:\.[^.\/]{0,3})?$/;
        my $stem = _fold_ascii($1);
        $stem =~ s/[^a-z0-9]//g;
        next unless length $stem;
        my $longfold = _fold_ascii($long);
        $longfold =~ s/[^a-z0-9]//g;
        $longfold = substr($longfold, 0, 6);
        return 1 if $stem eq $longfold;
    }
    return 0;
}

sub same_path {
    my ($p, $q, $allow_83) = @_;
    $allow_83 = 1 unless defined $allow_83;
    return 0 unless defined $p && defined $q;
    my $ca = _lex_canon($p);
    my $cb = _lex_canon($q);
    my @sa = grep { length } split m{/}, $ca, -1;
    my @sb = grep { length } split m{/}, $cb, -1;
    return 0 unless scalar(@sa) == scalar(@sb);
    for my $i (0 .. $#sa) {
        return 0 unless _seg_eq($sa[$i], $sb[$i], $allow_83);
    }
    return 1;
}

# real(p) = abs_path(p) when p exists and abs_path returns defined, else p.
sub _real_path {
    my ($p) = @_;
    return $p unless defined $p && length $p;
    return $p unless -e $p;
    my $r = eval { Cwd::abs_path($p) };
    return (defined $r && length $r) ? $r : $p;
}

sub _same_path_any_form {
    my ($d, $s, $allow_83) = @_;
    $allow_83 = 1 unless defined $allow_83;
    return 1 if same_path($d, $s, $allow_83);
    my $rd = _real_path($d);
    my $rs = _real_path($s);
    return 1 if same_path($rd, $rs, $allow_83);
    if ($^O =~ /^(msys|cygwin)$/ && defined &Cygwin::posix_to_win_path) {
        my $wd = eval { Cygwin::posix_to_win_path($rd) };
        my $ws = eval { Cygwin::posix_to_win_path($rs) };
        $wd = $rd unless defined $wd;
        $ws = $rs unless defined $ws;
        return 1 if same_path($wd, $ws, $allow_83);
    }
    return 0;
}

# ---------------------------------------------------------------------------
# The bounded walk-up (spec §2.2)
# ---------------------------------------------------------------------------

sub _compute_stops {
    my @candidates;
    push @candidates, eval { File::Spec->tmpdir };
    push @candidates, $ENV{TMP}, $ENV{TEMP}, $ENV{TMPDIR};
    push @candidates, $ENV{HOME}, $ENV{USERPROFILE};
    # macOS has TWO temp roots: $TMPDIR (/var/folders/.../T, which tmpdir()
    # already returns) and /tmp (really /private/tmp), where Claude Code keeps
    # its per-session temp dirs and scratchpads. Without the second, a walk
    # from a scratchpad climbed /private/tmp -> /private -> / unbounded.
    push @candidates, '/tmp', '/private/tmp' if $IS_DARWIN;

    my @stops;
    for my $v (@candidates) {
        next unless defined $v && length $v;
        next unless _is_abs_ish($v);
        my $canon = _lex_canon($v);
        next if $canon =~ m{^(?:[a-z]:)?/\z};
        push @stops, $v;
    }
    return \@stops;
}

sub _is_stop {
    my ($d, $stops, $allow_83) = @_;
    $allow_83 = 1 unless defined $allow_83;
    for my $s (@$stops) {
        return 1 if _same_path_any_form($d, $s, $allow_83);
    }
    return 0;
}

# _collapse_dotdot($p) -> $p with "." and ".." segments collapsed lexically,
# preserving every other aspect of the spelling (Decision 23: this file must
# not respell a drive form) -- unlike _lex_canon, this never folds "/x/..."
# to "x:/..." or lower-cases a drive letter, and it is a no-op (returns the
# input unchanged) unless the input actually contains a "." or ".." segment,
# so a caller never observing item 8(a)'s edge case sees no spelling change.
sub _collapse_dotdot {
    my ($p) = @_;
    return $p unless defined $p && length $p;
    return $p unless $p =~ m{(?:^|/)\.\.?(?:/|\z)};

    my $drive_prefix = '';
    my $s = $p;
    if ($IS_WIN && $s =~ m{^([A-Za-z]:)(/.*)?\z}) {
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

# _home_usable() -> 1|0 -- Decision 25: a walk-up can only trust the HOME
# stop it computed if HOME or USERPROFILE is itself a usable (non-empty,
# absolute) value. When neither is, the process cannot tell whether some
# ancestor of the start IS the real home, so it must not ascend at all
# (item 8(b)): only the start directory itself is considered.
sub _home_usable {
    for my $v ($ENV{HOME}, $ENV{USERPROFILE}) {
        return 1 if defined $v && length $v && _is_abs_ish($v);
    }
    return 0;
}

# Lexical parent of a "/"-normalised path: strip the last segment while
# keeping any "x:" drive prefix intact, so a drive-letter-form path (M1)
# climbs to its OWN drive root ("c:/x" -> "c:/") rather than through
# File::Basename::dirname's Unix rules, which turn "c:/" into "." -- a
# relative path that resolves against the PROCESS cwd, not the cwd argument.
# Returns undef once there is no parent left (POSIX "/" or a drive root).
sub _parent_of {
    my ($d) = @_;
    return undef unless defined $d && length $d;
    (my $s = $d) =~ s{\\}{/}g;
    return undef if $s eq '/';
    return undef if $s =~ m{^[A-Za-z]:/?\z};

    my $drive_prefix = '';
    if ($s =~ m{^([A-Za-z]:)(/.*)?\z}) {
        $drive_prefix = $1;
        $s = defined $2 ? $2 : '/';
    }
    my $is_abs = ($s =~ m{^/});
    my @parts = split m{/}, $s;
    shift @parts if @parts && $parts[0] eq '';
    pop @parts;
    my $rest = join('/', @parts);
    my $result = $is_abs ? ('/' . $rest) : $rest;
    $result = $drive_prefix . $result if length $drive_prefix;
    return $result;
}

sub _walkup {
    my ($cwd, $stops) = @_;
    (my $start = $cwd) =~ s{\\}{/}g;
    # Item 8(a): canonicalise a start containing ".." before walking, so a
    # relative "../.." spelling cannot be mistaken for an ancestor climb.
    $start = _collapse_dotdot($start) if length $start;
    my $home_ok = _home_usable();
    my $d = $start;
    my %seen;
    while (1) {
        return undef if $seen{$d}++;
        my $is_stop_here = _is_stop($d, $stops);
        if ($is_stop_here && !_same_path_any_form($d, $start)) {
            return undef;
        }
        if (-d "$d/.ccpraxis-local-data") {
            # A cwd that IS a stop dir examines itself and is adopted
            # unconditionally (spec §2.2 R2); there is no additional gate on
            # how is_stop($d) matched.
            return $d;
        }
        if ($is_stop_here) {
            return undef;
        }
        # Item 8(b)/Decision 25: with no usable home known, the walk cannot
        # rule out an unrecognised ancestor being the real home, so it never
        # ascends past the start.
        return undef unless $home_ok;
        my $parent = eval { _parent_of($d) };
        return undef unless defined $parent && length $parent;
        return undef if $parent eq $d;
        $d = $parent;
    }
}

# ---------------------------------------------------------------------------
# Public API (Decision 20, spec §7 Q1) — the ONLY cross-module surface other
# packages may call. bp-drive-next.pl/bp-lifecycle.pl and this file's own
# resolve()/project_root()/data_dir() keep using the private _walkup/
# _compute_stops directly; BpProjectRoot.pm's bounded_walkup/bounded_ancestors
# adapter (package 03) calls these two instead of reaching for the
# underscore-prefixed internals across a module boundary.
# ---------------------------------------------------------------------------

# walkup(cwd => $start) -> $dir | undef. $start defaults to Cwd::getcwd().
sub walkup {
    my (%a) = @_;
    my $c = (defined $a{cwd} && length $a{cwd}) ? $a{cwd} : (Cwd::getcwd() // '.');
    return _walkup($c, _compute_stops());
}

# ancestors(cwd => $start) -> @dirs. $start and its parents, nearest first,
# stopping per the same R1-R4 rules _walkup uses (see spec §2.2): a stop dir
# strictly above the start is excluded and ends the list; the start itself is
# included even when it is a stop dir, and that ends the list too (R3).
sub ancestors {
    my (%a) = @_;
    my $start = (defined $a{cwd} && length $a{cwd}) ? $a{cwd} : (Cwd::getcwd() // '.');
    (my $s = $start) =~ s{\\}{/}g;
    # Item 8(a): canonicalise a start containing ".." before walking.
    $s = _collapse_dotdot($s) if length $s;
    my $home_ok = _home_usable();
    my $stops = _compute_stops();
    my @out;
    my $d = $s;
    my %seen;
    while (1) {
        last if $seen{$d}++;
        my $is_stop = _is_stop($d, $stops);
        last if $is_stop && !_same_path_any_form($d, $s);
        push @out, $d;
        last if $is_stop;
        # Item 8(b)/Decision 25: no usable home known means never ascend.
        last unless $home_ok;
        my $p = eval { _parent_of($d) };
        last unless defined $p && length $p && $p ne $d;
        $d = $p;
    }
    return @out;
}

# ---------------------------------------------------------------------------
# Git (step 4, spec §2.3) — best-effort, never bounded
# ---------------------------------------------------------------------------

sub _default_git {
    my ($cwd) = @_;
    return undef unless defined $cwd && length $cwd;

    my $native_cwd = $cwd;
    $native_cwd =~ s{\\}{/}g;
    if ($IS_WIN) {
        # Under MSYS2_ARG_CONV_EXCL=* (both callers set it process-wide) argv
        # is handed to native git.exe untranslated. Prefer Cygwin's own
        # translator so any POSIX-absolute cwd (not just the "/x/..."
        # single-letter-mount shape) survives; fall back to the "/x/..." rule
        # when the helper is unavailable.
        if ($^O =~ /^(msys|cygwin)$/ && defined &Cygwin::posix_to_win_path && $native_cwd =~ m{^/}) {
            my $w = eval { Cygwin::posix_to_win_path($native_cwd) };
            if (defined $w && length $w) {
                $native_cwd = $w;
                $native_cwd =~ s{\\}{/}g;
            }
        }
        if ($native_cwd =~ m{^/([A-Za-z])(/.*)?$}) {
            $native_cwd = uc($1) . ':' . (defined $2 ? $2 : '/');
        }
    }

    # List-form pipe open: no shell, no temp file, and no STDOUT juggling
    # (the pipe IS the child's stdout). Only STDERR needs suppressing --
    # `local *STDERR` alone reassigns a fresh Perl glob without the OS fd 2
    # that a forked child inherits, so it does not silence the child. Dup
    # fd 2 aside, reopen STDERR onto devnull for the duration of the spawn,
    # then restore it immediately, all inside one eval so a mid-call die
    # still restores it via the dup already held in $saved_err.
    my $out = eval {
        open(my $saved_err, '>&', \*STDERR) or return undef;
        unless (open(STDERR, '>', File::Spec->devnull)) {
            open(STDERR, '>&', $saved_err);
            close $saved_err;
            return undef;
        }
        my $fh;
        my $ok = open($fh, '-|', 'git', '-C', $native_cwd, 'rev-parse', '--show-toplevel');
        my $content;
        my $rc;
        if ($ok) {
            local $/;
            $content = <$fh>;
            close $fh;
            $rc = $?;
        }
        open(STDERR, '>&', $saved_err);
        close $saved_err;
        return undef unless $ok;
        return undef if $rc != 0;
        return $content;
    };
    return undef unless defined $out;
    chomp $out;
    return (length $out && -d $out) ? $out : undef;
}

# ---------------------------------------------------------------------------
# resolve() / project_root() / data_dir() (spec §2.1)
# ---------------------------------------------------------------------------

sub _steps_3_to_6 {
    my (%args) = @_;

    if (defined $ENV{BP_PROJECT_ROOT} && length $ENV{BP_PROJECT_ROOT}) {
        return ($ENV{BP_PROJECT_ROOT}, 'env:BP_PROJECT_ROOT');
    }

    my $cwd = (defined $args{cwd} && length $args{cwd}) ? $args{cwd} : (Cwd::getcwd() // '.');
    $cwd =~ s/\0//g if defined $cwd;

    my $git_fn = $args{git};
    my $top = defined $git_fn ? eval { $git_fn->($cwd) } : _default_git($cwd);
    if (defined $top && length $top) {
        (my $t = $top) =~ s/\s+\z//;
        if (length $t && -d $t) {
            return ($t, 'git');
        }
    }

    my $stops = _compute_stops();
    my $found = _walkup($cwd, $stops);
    if (defined $found) {
        return ($found, 'walk-up');
    }

    (my $cwd2 = $cwd) =~ s{\\}{/}g;
    return ($cwd2, 'cwd');
}

sub resolve {
    my (%args) = @_;

    if (defined $args{data_dir} && length $args{data_dir}) {
        return { data_dir => $args{data_dir}, project_root => undef, source => 'arg' };
    }
    if (defined $ENV{CCPRAXIS_DATA_DIR} && length $ENV{CCPRAXIS_DATA_DIR}) {
        return { data_dir => $ENV{CCPRAXIS_DATA_DIR}, project_root => undef, source => 'env:CCPRAXIS_DATA_DIR' };
    }

    my ($root, $source) = _steps_3_to_6(%args);
    return { data_dir => "$root/.ccpraxis-local-data", project_root => $root, source => $source };
}

sub project_root {
    my (%args) = @_;
    my ($root, undef) = _steps_3_to_6(%args);
    return $root;
}

sub data_dir {
    my (%args) = @_;
    return resolve(%args)->{data_dir};
}

1;
