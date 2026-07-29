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
use Cwd ();          # core; the default `realpath` seam only (q04 §1.1)
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
# §2.1 (G1) -- normalize_path($path, \%opts) -> $normalized | undef
# Lexical `.`/`..` resolution layered on top of canon_path. Never dies.
#
# q04 §4 (MINOR-8): \%opts is OPTIONAL and back-compatibility is mandatory
# -- called with one argument (as launcher.pl does at :458/:487) the
# platform decision still comes from the ambient probe, byte-identically to
# before. Supplying { windows => 0|1 } forces the platform-specific rules
# below (step 6.5) instead, which is what makes them assertable on a Linux
# runner at all.
# =====================================================================
sub normalize_path {
    my ($p, $opts) = @_;

    # Step 0 -- refs are never a path (mirrors _ingest_path's guard so the
    # two choke points can't silently diverge; a caller bug that hands us a
    # hash/array ref must fail loudly, not stringify to a memory address).
    return undef if ref $p;

    # Step 1.
    return undef unless defined $p && length $p;
    return undef if $p =~ /\A\s*\z/;

    # Step 1.5 -- Windows extended-length / device-path prefix (\\?\,
    # \\?\UNC\). This must run on the raw (still-backslash) string, since
    # canon_path's unconditional backslash->slash rewrite below would
    # otherwise mangle it into a bogus POSIX-absolute path that loses the
    # drive letter entirely (redteam M4). Not gated on Windows-family: the
    # prefix syntax itself is unambiguous device-path notation on any
    # platform.
    if ($p =~ s{\A\\\\\?\\UNC\\}{\\\\}i) {
        # \\?\UNC\server\share -> \\server\share
    } elsif ($p =~ s{\A\\\\\?\\}{}i) {
        # \\?\C:\... -> C:\...
    }

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

    # Step 6.5 -- Windows silently strips trailing dots/spaces from path
    # components (a well-known Win32 filesystem quirk), so "foo." and
    # "foo " alias "foo" there. Gated on the Windows-family probe: on
    # Linux/POSIX, "foo." and "foo " are legitimately distinct directory
    # names and must stay distinct (redteam M4). `..` is exempted so the
    # parent-directory marker itself is never touched.
    # `$opts` (q04 §4) lets the caller force the decision; absent, this is
    # the pre-q04 ambient probe.
    if (_windows_family($opts)) {
        @segments = grep { length $_ }
                    map  { $_ eq '..' ? $_ : do { (my $s = $_) =~ s/[. ]+\z//; $s } }
                    @segments;
    }

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
#
# DIRECTION CONTRACT (read this twice, per spec §2.2): the relation is
# read as "$target is a ___ of $root". So 'descendant' means the FIRST
# argument ($target) is inside the SECOND ($root); 'ancestor' means the
# first argument CONTAINS the second. Getting this backwards silently
# inverts every containment check downstream -- this is the trap q03 is
# most likely to hit when wiring the launcher refusal.
# =====================================================================
sub path_relation {
    my ($target, $root, $opts) = @_;
    $opts //= {};

    # Route both sides through the same UTF-8-encode choke point as every
    # other externally-sourced path (§2.5.8's _ingest_path), not the bare
    # normalize_path. Without this, a wide-character target compared
    # against a byte-encoded root fails OPEN ('unrelated') instead of
    # matching -- the measured CcpraxisWorkCopy.pm André bug class
    # (redteam M1). _ingest_path is a strict superset of normalize_path
    # (same algorithm, plus the ref-guard and the encode), so this is
    # never a narrowing for callers who were already passing plain bytes.
    # BOTH ingestions get the same $opts (q04 §4/AC-71): normalising one side
    # under the ambient platform and the other under a forced one would make
    # the comparison meaningless.
    my $t = _ingest_path($target, $opts);
    my $r = _ingest_path($root,   $opts);
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
    my ($raw, $opts) = @_;
    return undef unless defined $raw && !ref $raw;
    # A control byte (including NUL) inside a segment is never a legitimate
    # path component on any supported platform, and is legal inside a JSON
    # string -- left unchecked it lets two genuinely different paths
    # collide on the same _fold_key (redteam C1: "home/u\0.claude" vs.
    # "home/u/.claude"), silently evicting the higher-ranked one from
    # `roots` with no error. Reject it here so it takes the existing loud
    # registry-entry/extra-list-entry error branch instead.
    return undef if $raw =~ /[\x00-\x1f]/;
    utf8::encode($raw) if utf8::is_utf8($raw);
    # q04 §4: forward the caller's platform overrides so an ingested path and
    # its comparison partner are normalised under the SAME platform rules.
    return normalize_path($raw, $opts);
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

    # _ingest_path, not the bare normalize_path -- same encode/ref-guard
    # choke point as every other externally-sourced path (redteam M1); a
    # bare normalize_path call here would fail open on a wide-character
    # target the way path_relation used to. _is_bare_root is the single
    # helper shared with the root-side guard in protected_roots so the two
    # "is this a bare root" checks can never silently diverge (reviewer N2).
    my $n = _ingest_path($target);
    push @codes, 'drive-root' if _is_bare_root($n);

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

# q04 §1.1 -- the default `realpath` seam. Deliberately IDENTICAL in shape to
# CcpraxisWorkCopy.pm's own $_default_realpath (:149-153) rather than a second
# invention, because both modules answer the same question: Cwd::abs_path (NOT
# Cwd::realpath), eval-wrapped, and returning undef for a path that does not
# exist -- which is exactly the fallback trigger the degrade-to-lexical path
# below wants.
my $_default_realpath = sub {
    my ($p) = @_;
    my $r = eval { Cwd::abs_path($p) };
    return $r;
};

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
    # DELIBERATE DEVIATION FROM SPEC §2.5.1, approved by the coordinator
    # (redteam M3): the spec prose describes this as a precedence chain --
    # "$CLAUDE_CONFIG_DIR if set, else ~/.claude" -- but Appendix B
    # Decision #3 is absolute: "No override. No escape hatch. No env var,
    # no flag." A precedence chain lets `CLAUDE_CONFIG_DIR=/tmp/decoy`
    # *remove* the real `~/.claude` from `roots` entirely with a clean
    # `errors: []`, defeating the refusal it exists to guarantee. So the
    # candidate set below is a UNION, not a chain: every one of
    # CLAUDE_CONFIG_DIR, $HOME/.claude and $USERPROFILE/.claude that
    # resolves contributes its own `claude-home` candidate. Existing
    # de-duplication (§2.5.8) absorbs the usual overlap when they agree;
    # the residue when they disagree is over-refusal, the safe direction
    # per Decision #6. `$home_raw` itself stays a single, precedence-
    # ordered value -- it is only used below to derive the *default*
    # registry/extra-list paths, which §2.5.1 is unmodified for.
    my $home_raw;   # unnormalised, used for the default registry/extra paths
    {
        my $cfg = eval { $env_fn->('CLAUDE_CONFIG_DIR') };
        $cfg = undef if $@;
        my $home_env = eval { $env_fn->('HOME') };
        $home_env = undef if $@;
        my $userprofile = eval { $env_fn->('USERPROFILE') };
        $userprofile = undef if $@;

        my @home_candidates;
        push @home_candidates, $cfg                  if defined $cfg         && $cfg         !~ /\A\s*\z/;
        push @home_candidates, "$home_env/.claude"    if defined $home_env    && $home_env    !~ /\A\s*\z/;
        push @home_candidates, "$userprofile/.claude" if defined $userprofile && $userprofile !~ /\A\s*\z/;

        if (defined $cfg && $cfg !~ /\A\s*\z/) {
            $home_raw = $cfg;
        } elsif (defined $home_env && $home_env !~ /\A\s*\z/) {
            $home_raw = "$home_env/.claude";
        } elsif (defined $userprofile && $userprofile !~ /\A\s*\z/) {
            $home_raw = "$userprofile/.claude";
        }

        if (@home_candidates) {
            for my $hc (@home_candidates) {
                my $n = _ingest_path($hc);
                push @candidates, { path => $n, reason => 'claude-home' } if defined $n;
            }
        } else {
            push @errors, { code => 'claude-home-unresolved',
                             detail => 'none of CLAUDE_CONFIG_DIR, HOME, USERPROFILE yielded a usable value' };
        }
    }

    # ---- §2.5.2 step 2/3: registry acquisition + entries -----------------
    my $registry_default = defined $home_raw ? "$home_raw/plugins/known_marketplaces.json" : undef;
    my ($reg_raw, $reg_attempted) = _acquire_json_source(
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

    # Gate the shape check on "was a source actually attempted" (the second
    # return value above), not on `defined $reg_raw`. An explicitly-supplied
    # `registry => undef`, or a registry file that decodes to JSON `null`,
    # is "supplied but broken" per §2.4/§2.5.5 -- it must raise
    # registry-shape, not silently vanish as "no registry" (reviewer M1).
    my $reg;
    if (ref $reg_raw eq 'HASH') {
        $reg = $reg_raw;
    } elsif ($reg_attempted) {
        push @errors, { code => 'registry-shape', detail => 'registry is not a JSON object' };
    }

    if (defined $reg) {
        # Never dies (module header §M5): a hostile registry can be a tied
        # or otherwise poisoned hash whose FETCH/keys enumeration dies
        # mid-walk. Wrap the whole per-entry body (including the key
        # enumeration itself) so one hostile entry raises a loud
        # registry-entry error and leaves every other entry -- and every
        # other root source -- intact, rather than propagating a die up
        # through protected_roots (redteam m1).
        my @names = eval { sort keys %$reg };
        if ($@) {
            push @errors, { code => 'registry-entry', detail => 'registry could not be enumerated' };
            @names = ();
        }
        for my $name (@names) {
            # NB: a `return` inside a block eval returns from the enclosing
            # named sub, not just the eval -- so this is deliberately
            # written as nested if/else falling through to a trailing `1`
            # rather than early-returning, to avoid silently truncating
            # protected_roots itself on the happy path.
            my $ok = eval {
                my $entry = $reg->{$name};
                if (ref $entry ne 'HASH') {
                    push @errors, { code => 'registry-entry', detail => "entry '$name' is not an object" };
                } else {
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
                1;
            };
            push @errors, { code => 'registry-entry', detail => "entry '$name' could not be read" }
                unless $ok;
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
    my ($extra_raw, $extra_attempted) = _acquire_json_source(
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

    # Same "was attempted" gate as the registry block above -- an explicit
    # `extra_list => undef` is "supplied but broken", not "not supplied"
    # (reviewer M1's direct sibling for extra-list-shape).
    if (ref $extra_raw eq 'ARRAY') {
        for my $el (@$extra_raw) {
            my $n = _ingest_path($el);
            if (defined $n) {
                push @candidates, { path => $n, reason => 'user-configured' };
            } else {
                push @errors, { code => 'extra-list-entry', detail => 'extra-list element is not a usable path' };
            }
        }
    } elsif ($extra_attempted) {
        push @errors, { code => 'extra-list-shape', detail => 'extra list is not a JSON array' };
    }

    # ---- §2.5.2 step 6: resolve, reject, de-duplicate, sort ---------------
    # THE ORDER IS PART OF THE CONTRACT (q04 §1.2) -- resolve -> reject ->
    # dedup -> sort -- and every edge is a real defect if inverted:
    #   * resolve BEFORE reject, or a symlink pointing at `/` or at the user
    #     home escapes both guards below, i.e. finding 3's machine-wide
    #     outage arrives through finding 1's hole;
    #   * resolve BEFORE dedup, or two candidates that are different symlinks
    #     to one real directory survive as two roots with different reason
    #     ranks instead of collapsing to one.
    # Do not reorder this to chase a failing assertion.
    #
    # Resolution applies to the candidate ROOTS ONLY. The target is already
    # resolved by the caller (launcher.pl abs_path()s $PROJECT_PATH before
    # asking), which is why path_relation itself stays a pure lexical
    # predicate and never consults this seam (§C-0.1, AC-22/AC-55).
    my $realpath_fn = $opts->{realpath} // $_default_realpath;
    my @resolved;          # { path, reason, unresolved }
    my $resolved_count = 0;
    for my $c (@candidates) {
        # eval the seam call exactly as CcpraxisWorkCopy::_same_path (:164-165)
        # does: that is what makes a DYING seam behave identically to one
        # returning undef (AC-51 vs AC-52) and keeps §M5's "never dies" true.
        my $raw = eval { $realpath_fn->($c->{path}) };
        my $n   = (defined $raw && length $raw) ? _ingest_path($raw, $opts) : undef;
        if (defined $n) {
            $resolved_count++;
            push @resolved, { path => $n, reason => $c->{reason}, unresolved => 0 };
        } else {
            # DEGRADE to the lexical form, never drop (q04 §1.3): dropping it
            # would SHRINK the protected set, the one direction Decision #6
            # forbids.
            push @resolved, { path => $c->{path}, reason => $c->{reason}, unresolved => 1 };
        }
    }

    # ...and warn, per candidate, so _pp_source_warnings surfaces it (it is
    # code-agnostic, so no launcher change is needed).
    #
    # DELIBERATE NARROWING of q04 §1.3, forced by the oracle: the warning is
    # emitted only when the seam resolved at least ONE candidate. A seam that
    # resolved *nothing* is an unusable seam -- one fact about the host, not N
    # facts about N roots -- and reporting it N times would burn the launcher's
    # 10-warning cap (§1.3) on a single cause and drown out the real
    # diagnostics. t/51's AC-40 pins exactly this: `realpath => $no_fs` (a
    # seam that dies for everything) must still return the AC-24 structure
    # with `errors => []`, while AC-51/AC-52 (one candidate of three failing)
    # must warn. Roots degrade to lexical either way, so the protected set is
    # never shrunk by this narrowing -- only the diagnostics are.
    if ($resolved_count) {
        for my $c (@resolved) {
            push @errors, { code => 'root-unresolved', detail => "$c->{reason}: $c->{path}" }
                if $c->{unresolved};
        }
    }

    my @kept;
    for my $c (@resolved) {
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
