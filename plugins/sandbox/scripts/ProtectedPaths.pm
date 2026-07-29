package ProtectedPaths;
# Pure, filesystem-free path-containment and protected-root logic for the
# sandbox launcher refusal (q01-protected-roots). See
#   .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/q01-protected-roots-spec.md
# for the full contract; every numbered section reference below (§2.x) points
# there. This module never touches the filesystem or %ENV directly -- every
# external fact arrives through the seams described in §2.4, all of which are
# eval-wrapped so a hostile or dying test double can never escape (M5).

use strict;
use warnings;
use Exporter qw(import);
use JSON::PP ();
use CcpraxisWorkCopy qw(canon_path live_install_dir);

our @EXPORT_OK = qw(
    path_relation
    protected_roots
    target_self_codes
    normalize_path
);

# =====================================================================
# §2.3 (G2) -- platform rules obtained by probing the frozen subs, never by
# reimplementing the platform-name regex. our-scoped so a test can `local`
# either slot to force a decision deterministically on any platform.
# =====================================================================
our $FOLD_CASE;      # undef = not yet probed; 0|1 = decided (also test override slot)
our $WINDOWS_FAMILY; # undef = not yet probed; 0|1 = decided (also test override slot)

sub _fold_case {
    my ($opts) = @_;
    return ($opts->{fold_case} ? 1 : 0) if $opts && exists $opts->{fold_case};
    return $FOLD_CASE //= _probe_fold_case();
}

sub _probe_fold_case {
    my $r = eval { CcpraxisWorkCopy::_same_path('/A', '/a', { realpath => sub { $_[0] } }) };
    return 1 unless defined $r;   # probe failed: fold => matches more => refuses more (Decision #6)
    return $r ? 1 : 0;
}

sub _windows_family {
    my ($opts) = @_;
    return ($opts->{windows} ? 1 : 0) if $opts && exists $opts->{windows};
    return $WINDOWS_FAMILY //= _probe_windows();
}

sub _probe_windows {
    my $c = canon_path('c:/probe');
    return (defined $c && $c eq 'C:/probe') ? 1 : 0;
}

# =====================================================================
# §2.1 (G1) -- normalize_path($path) -> $normalized | undef
# Lexical `.`/`..` resolution layered on top of canon_path. Never dies.
# =====================================================================
sub normalize_path {
    my ($p) = @_;

    # Step 1.
    return undef unless defined $p && length $p;
    return undef if $p =~ /\A\s*\z/;

    # Step 2 -- all-slash pre-guard (canon_path('//') would otherwise
    # degrade a root to the empty string; see spec §2.1 step 2).
    my $w = $p;
    $w =~ s{\\}{/}g;
    return '/' if $w =~ m{\A/+\z};

    # Step 3.
    my $c = canon_path($p);
    return undef unless defined $c && length $c;

    # Step 4.
    $c =~ s{/{2,}}{/}g;

    # Step 5 -- split off the prefix; drive-letter case is left exactly as
    # canon_path produced it.
    my ($prefix, $absolute);
    if ($c =~ s{\A([A-Za-z]:)}{}) {
        $prefix   = $1;
        $absolute = 1;
    } else {
        $prefix   = '';
        $absolute = ($c =~ m{\A/}) ? 1 : 0;
    }
    $c =~ s{\A/}{};

    # Step 6.
    my @segments = grep { length($_) && $_ ne '.' } split m{/}, $c;

    # Step 7 -- resolve `..` against a stack.
    my @stack;
    for my $seg (@segments) {
        if ($seg eq '..') {
            if (@stack && $stack[-1] ne '..') {
                pop @stack;
            } elsif ($absolute) {
                # escaping the root is clamped: drop it (§3.4)
            } else {
                push @stack, '..';
            }
        } else {
            push @stack, $seg;
        }
    }

    # Step 8/9 -- rejoin and return.
    if ($absolute) {
        return $prefix . '/' . join('/', @stack);
    }
    return @stack ? join('/', @stack) : '.';
}

# Decompose an already-normalized path into (prefix, absolute, @segments).
# Internal only -- normalize_path has already resolved `.`/`..`, so this is
# a plain re-parse of its output, never a second implementation of §2.1.
sub _decompose {
    my ($n) = @_;
    my ($prefix, $absolute, $rest);
    if ($n =~ m{\A([A-Za-z]:)/(.*)\z}s) {
        ($prefix, $absolute, $rest) = ($1, 1, $2);
    } elsif ($n =~ m{\A/(.*)\z}s) {
        ($prefix, $absolute, $rest) = ('', 1, $1);
    } else {
        ($prefix, $absolute, $rest) = ('', 0, $n);
    }
    $rest = '' if $rest eq '.';
    my @segs = length($rest) ? split(m{/}, $rest) : ();
    return ($prefix, $absolute, @segs);
}

sub _is_bare_root {
    my ($n) = @_;
    return 0 unless defined $n;
    return $n =~ m{\A([A-Za-z]:)?/\z} ? 1 : 0;
}

# =====================================================================
# §2.2 -- path_relation($target, $root, \%opts) -> exact|descendant|ancestor|unrelated
# =====================================================================
sub path_relation {
    my ($target, $root, $opts) = @_;
    $opts //= {};

    my $t = normalize_path($target);
    my $r = normalize_path($root);
    return 'unrelated' unless defined $t && defined $r;

    my ($tprefix, $tabs, @tsegs) = _decompose($t);
    my ($rprefix, $rabs, @rsegs) = _decompose($r);

    return 'unrelated' if $tabs != $rabs;

    my $fold = _fold_case($opts);
    my $eqf  = sub {
        my ($a, $b) = @_;
        return $fold ? (lc($a) eq lc($b)) : ($a eq $b);
    };

    return 'unrelated' unless $eqf->($tprefix, $rprefix);

    my $n = (@tsegs < @rsegs) ? scalar(@tsegs) : scalar(@rsegs);
    for my $i (0 .. $n - 1) {
        return 'unrelated' unless $eqf->($tsegs[$i], $rsegs[$i]);
    }

    return 'exact'      if @tsegs == @rsegs;
    return 'descendant' if @tsegs > @rsegs;
    return 'ancestor';
}

# =====================================================================
# §2.5.8 -- the single choke point every externally-sourced path passes
# through. Guards the measured JSON::PP-wide-char-vs-filesystem-bytes bug.
# =====================================================================
sub _ingest_path {
    my ($raw) = @_;
    return undef unless defined $raw && !ref $raw;
    utf8::encode($raw) if utf8::is_utf8($raw);
    return normalize_path($raw);
}

sub _fold_key {
    my ($n, $fold) = @_;
    my ($prefix, $absolute, @segs) = _decompose($n);
    if ($fold) {
        $prefix = lc($prefix);
        @segs   = map { lc($_) } @segs;
    }
    return join("\x00", $prefix, @segs);
}

# =====================================================================
# §2.6 (G4, additive) -- target_self_codes($target, \%opts) -> \@codes
# =====================================================================
sub _user_home {
    my ($opts) = @_;
    my $env_fn = $opts->{env} // sub { $ENV{$_[0]} };
    my $windows = _windows_family($opts);
    my @names = $windows ? ('USERPROFILE', 'HOME') : ('HOME', 'USERPROFILE');
    for my $name (@names) {
        my $v = eval { $env_fn->($name) };
        next if $@;
        next unless defined $v;
        next if $v =~ /\A\s*\z/;
        return $v;
    }
    return undef;
}

sub target_self_codes {
    my ($target, $opts) = @_;
    $opts //= {};

    my @codes;

    my $n = normalize_path($target);
    if (defined $n) {
        my ($prefix, $absolute, @segs) = _decompose($n);
        push @codes, 'drive-root' if $absolute && !@segs;
    }

    my $home = _user_home($opts);
    if (defined $home) {
        my $rel = eval { path_relation($target, $home, $opts) };
        push @codes, 'user-home' if defined $rel && $rel eq 'exact';
    }

    return \@codes;
}

# =====================================================================
# §2.5 -- protected_roots(\%opts) -> { roots => [...], errors => [...] }
# Never dies. Always returns the two-key hash ref. Degrades toward
# refusing: one broken source never discards another's roots (Decision #6).
# =====================================================================

my %REASON_RANK = (
    'ccpraxis-install'    => 0,
    'claude-home'         => 1,
    'marketplace-install' => 2,
    'marketplace-source'  => 3,
    'user-configured'     => 4,
);

# Acquire a JSON data source per §2.4/§2.5.5/§2.5.6 precedence:
# data key (exists-tested, no I/O) -> path key -> default path.
# Returns ($decoded_value_or_undef, $was_attempted).
sub _acquire_json_source {
    my (%a) = @_;
    my $opts = $a{opts};

    if (exists $opts->{ $a{data_key} }) {
        return ($opts->{ $a{data_key} }, 1);
    }

    my $path;
    if (exists $opts->{ $a{path_key} }) {
        $path = $opts->{ $a{path_key} };
    } elsif (defined $a{default_path}) {
        $path = $a{default_path};
    } else {
        return (undef, 0);
    }

    my $ex = eval { $a{exists_fn}->($path) };
    $ex = 0 if $@ || !$ex;
    if (!$ex) {
        push @{ $a{errors} }, { code => $a{code_missing}, detail => "$a{label} file not found: $path" }
            if $a{missing_is_error};
        return (undef, 0);
    }

    my $bytes = eval { $a{read_fn}->($path) };
    if ($@ || !defined $bytes || !length $bytes) {
        push @{ $a{errors} }, { code => $a{code_unreadable}, detail => "cannot read $a{label} file: $path" };
        return (undef, 0);
    }

    my $decoded = eval { JSON::PP::decode_json($bytes) };
    if ($@) {
        push @{ $a{errors} }, { code => $a{code_unparseable}, detail => "$a{label} JSON parse failed: $path" };
        return (undef, 0);
    }

    return ($decoded, 1);
}

sub protected_roots {
    my ($opts) = @_;
    $opts //= {};

    my @errors;
    my @candidates;   # { path => normalized, reason => code }, pipeline order

    my $env_fn       = $opts->{env}       // sub { $ENV{$_[0]} };
    my $exists_fn    = $opts->{exists}    // sub { -e $_[0] ? 1 : 0 };
    my $read_file_fn = $opts->{read_file} // sub {
        my ($path) = @_;
        open my $fh, '<:raw', $path or die "cannot open: $!\n";
        local $/;
        my $bytes = <$fh>;
        close $fh;
        return $bytes;
    };

    # ---- §2.5.2 step 1: claude home -------------------------------------
    my $home_raw;   # unnormalised, used for the default registry/extra paths
    {
        my $cfg = eval { $env_fn->('CLAUDE_CONFIG_DIR') };
        $cfg = undef if $@;
        my $home_env = eval { $env_fn->('HOME') };
        $home_env = undef if $@;
        my $userprofile = eval { $env_fn->('USERPROFILE') };
        $userprofile = undef if $@;

        if (defined $cfg && $cfg !~ /\A\s*\z/) {
            $home_raw = $cfg;
        } elsif (defined $home_env && $home_env !~ /\A\s*\z/) {
            $home_raw = "$home_env/.claude";
        } elsif (defined $userprofile && $userprofile !~ /\A\s*\z/) {
            $home_raw = "$userprofile/.claude";
        }

        if (defined $home_raw) {
            my $n = _ingest_path($home_raw);
            push @candidates, { path => $n, reason => 'claude-home' } if defined $n;
        } else {
            push @errors, { code => 'claude-home-unresolved',
                             detail => 'none of CLAUDE_CONFIG_DIR, HOME, USERPROFILE yielded a usable value' };
        }
    }

    # ---- §2.5.2 step 2/3: registry acquisition + entries -----------------
    my $registry_default = defined $home_raw ? "$home_raw/plugins/known_marketplaces.json" : undef;
    my ($reg_raw, undef) = _acquire_json_source(
        opts             => $opts,
        data_key         => 'registry',
        path_key         => 'registry_path',
        default_path     => $registry_default,
        exists_fn        => $exists_fn,
        read_fn          => $read_file_fn,
        missing_is_error => 1,
        errors           => \@errors,
        label            => 'registry',
        code_missing     => 'registry-missing',
        code_unreadable  => 'registry-unreadable',
        code_unparseable => 'registry-unparseable',
    );

    my $reg;
    if (defined $reg_raw) {
        if (ref $reg_raw eq 'HASH') {
            $reg = $reg_raw;
        } else {
            push @errors, { code => 'registry-shape', detail => 'registry is not a JSON object' };
        }
    }

    if (defined $reg) {
        for my $name (sort keys %$reg) {
            my $entry = $reg->{$name};
            if (ref $entry ne 'HASH') {
                push @errors, { code => 'registry-entry', detail => "entry '$name' is not an object" };
                next;
            }

            my $il_n = _ingest_path($entry->{installLocation});
            if (defined $il_n) {
                push @candidates, { path => $il_n, reason => 'marketplace-install' };
            } else {
                push @errors, { code => 'registry-entry', detail => "entry '$name' installLocation is invalid" };
            }

            my $src = $entry->{source};
            if (ref $src eq 'HASH') {
                if (($src->{source} // '') eq 'directory') {
                    my $sp_n = _ingest_path($src->{path});
                    if (defined $sp_n) {
                        push @candidates, { path => $sp_n, reason => 'marketplace-source' };
                    } else {
                        push @errors, { code => 'registry-entry', detail => "entry '$name' source.path is invalid" };
                    }
                }
                # source.source ne 'directory' (e.g. github) is not an error.
            } else {
                push @errors, { code => 'registry-entry', detail => "entry '$name' source is invalid" };
            }
        }
    }

    # ---- §2.5.2 step 4: ccpraxis-install (source d) ----------------------
    {
        my $install;
        if (defined $reg) {
            $install = eval { live_install_dir({ registry => $reg }) };
        } else {
            $install = eval { live_install_dir({}) };
        }
        $install = undef if $@;
        if (defined $install) {
            my $n = _ingest_path($install);
            push @candidates, { path => $n, reason => 'ccpraxis-install' } if defined $n;
        }
    }

    # ---- §2.5.2 step 5: extra list (Decision #5) --------------------------
    my $extra_default = defined $home_raw ? "$home_raw/ccpraxis-protected-paths.json" : undef;
    my ($extra_raw, undef) = _acquire_json_source(
        opts             => $opts,
        data_key         => 'extra_list',
        path_key         => 'extra_list_path',
        default_path     => $extra_default,
        exists_fn        => $exists_fn,
        read_fn          => $read_file_fn,
        missing_is_error => 0,
        errors           => \@errors,
        label            => 'extra list',
        code_missing     => undef,
        code_unreadable  => 'extra-list-unreadable',
        code_unparseable => 'extra-list-unparseable',
    );

    if (defined $extra_raw) {
        if (ref $extra_raw eq 'ARRAY') {
            for my $el (@$extra_raw) {
                my $n = _ingest_path($el);
                if (defined $n) {
                    push @candidates, { path => $n, reason => 'user-configured' };
                } else {
                    push @errors, { code => 'extra-list-entry', detail => 'extra-list element is not a usable path' };
                }
            }
        } else {
            push @errors, { code => 'extra-list-shape', detail => 'extra list is not a JSON array' };
        }
    }

    # ---- §2.5.2 step 6: bare-root guard, de-duplication, sort -------------
    my @kept;
    for my $c (@candidates) {
        if (_is_bare_root($c->{path})) {
            push @errors, { code => 'root-bare-rejected', detail => "$c->{reason}: $c->{path}" };
            next;
        }
        push @kept, $c;
    }

    my $fold = _fold_case($opts);
    my %best;   # fold key -> { path, reason, rank }
    for my $c (@kept) {
        my $key  = _fold_key($c->{path}, $fold);
        my $rank = $REASON_RANK{ $c->{reason} };
        if (!exists $best{$key} || $rank < $best{$key}{rank}) {
            $best{$key} = { path => $c->{path}, reason => $c->{reason}, rank => $rank };
        }
    }

    my @roots =
        sort { $a->{reason_rank} <=> $b->{reason_rank} || $a->{path} cmp $b->{path} }
        map  { { path => $_->{path}, reason => $_->{reason}, reason_rank => $_->{rank} } }
        values %best;
    @roots = map { { path => $_->{path}, reason => $_->{reason} } } @roots;

    return { roots => \@roots, errors => \@errors };
}

1;
