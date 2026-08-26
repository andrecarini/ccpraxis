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
    #
    # q04 step 7 (reviewer m3): $opts IS threaded. The earlier one-argument call
    # was justified as "_is_bare_root's answer is platform-independent", which is
    # not quite true -- normalize_path's trailing-dot/space strip is
    # platform-gated, so a target like '/ .' is bare under `windows => 1` and not
    # under `windows => 0`. Leaving it unthreaded made this function honour
    # `windows` for its `user-home` code (below) and ignore it for `drive-root`,
    # i.e. inconsistent with itself within four lines.
    my $n = _ingest_path($target, $opts);
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

# q04 §1.1 -- the default `realpath` seam. Built from the same primitive as
# CcpraxisWorkCopy.pm's own $_default_realpath (:149-153) -- Cwd::abs_path
# (NOT Cwd::realpath), eval-wrapped -- because both modules answer the same
# question and should not diverge on the primitive.
#
# ONE REFINEMENT over the sibling, and it is a product requirement, not a test
# accommodation: A PATH THAT DOES NOT EXIST IS NOT AN UNRESOLVABLE PATH.
# abs_path returns undef for any non-existent path, and undef is what the
# pipeline reads as "unresolvable" and warns about (§1.3). Without this
# refinement every protected root that is merely absent -- a marketplace
# directory the user deleted, an extra-list entry pointing at a project they
# have not created yet -- would emit `root-unresolved` on EVERY launch, so a
# perfectly clean run would nag. t/53's Group G (AC-38..40, the C6
# clone-outside-the-install no-regression set) pins that: such a launch must
# come back with `warnings` EMPTY.
#
# So: absent  => return the path unchanged (resolved-to-itself; it stays in the
#                protected set, silently -- there is nothing to resolve, and
#                lexical containment still guards it);
#     DANGLING SYMLINK => undef, which warns. That is the case a user can and
#                should fix, and it is the one done-criterion 1 names.
#
# q04 step 7 (reviewer M1) -- WHY THE `-l` TEST IS LOAD-BEARING, measured, not
# assumed. The first shape of this closure asked "did abs_path fail AND does the
# path exist", and that combination is practically unreachable: `stat(2)` and
# `realpath(3)` need the same parent traversal, so every input where abs_path
# returns undef also has `-e` false (measured: absent parent, path through a
# dangling link). Worse, a dangling symlink does not fail resolution at all --
# abs_path cheerfully returns the non-existent TARGET -- so the very case the
# criterion names resolved silently to a directory that is not there. The
# distinguishing signal is `-l` TRUE while `-e` is FALSE: the path IS a symlink
# and what it points at is gone. That is reported; a plainly absent path (not a
# symlink) stays silent, which is what t/53's Group G pins (`warnings` EMPTY for
# a marketplace directory the user deleted).
#
# A symlink that resolves normally is untouched by this and still resolves to
# its target -- that is C5's whole fix and must not regress.
#
# `-e` and `-l` are deliberately REAL filesystem tests rather than the
# injectable `exists` seam: this closure IS the "no seam was injected, talk to
# the real host" branch, and t/51 arms `exists` as a die-ing tripwire, so
# routing through it here would make the default seam die where it should
# answer. Callers who inject `realpath` keep full control and are untouched by
# any of this -- an injected seam returning undef still means "unresolvable"
# (AC-51/AC-52).
my $_default_realpath = sub {
    my ($p) = @_;
    my $r      = eval { Cwd::abs_path($p) };
    my $exists = eval { (defined $p && length $p && -e $p) ? 1 : 0 };
    # Dangling (or looping) symlink => actionable fault, warn. Checked before
    # $r is trusted, because abs_path reports the dangling target as a success.
    return undef if !$exists && eval { (defined $p && length $p && -l $p) ? 1 : 0 };
    return $r if defined $r && length $r;
    return $p if !$exists;          # absent => nothing to resolve, not a fault
    return undef;                   # present but unresolvable => warn
};

# =====================================================================
# q04 §2.2 -- the default env-independent home probes (notion A only).
# Returns a LIST OF CODEREFS, each of which returns zero or more home
# DIRECTORIES; protected_roots evals each one separately so a probe that
# dies is silently skipped (AC-61). No PowerShell probe is shipped: the host
# perl has no Win32::* (measured absent -- KeepAwake.pm:13,
# launcher.pl:3850), and callers that need one inject `home_probes`.
# =====================================================================
sub _default_home_probes {
    my ($exists_fn) = @_;
    return (
        # Probe 1 -- the POSIX passwd database. This is the whole point of
        # finding 2: it reports the OS's own record of the home directory, so
        # `HOME=/tmp/decoy` cannot make the real `~/.claude` disappear from
        # `roots`.
        #
        # NOT gated on the broad Windows-family test. launcher.pl:78's
        # $WINDOWS_FAMILY matches MSWin32|cygwin|msys, but only *native*
        # MSWin32 lacks getpwuid; Git-for-Windows perl is `msys`, a Cygwin
        # derivative where the passwd database does work -- so the broad gate
        # would disable this on the project's primary host (spec §8 records
        # launcher.pl:544's identical over-broad gate for harvest).
        sub {
            return () if $^O eq 'MSWin32';
            my @pw = getpwuid($<);
            return () unless @pw && defined $pw[7] && length $pw[7];
            # EXISTENCE-GATED, unlike the env-derived candidates above, and
            # this asymmetry is deliberate. An env var (or an injected probe)
            # is a caller DECLARATION that a home exists; the passwd database
            # is a self-made GUESS about the ambient host -- in a container it
            # is typically /root, which has no Claude home at all. Adopting an
            # unverified guess would invent a phantom protected root out of
            # ambient state, and t/51's AC-24/AC-27/AC-49 pin exactly that:
            # they assert byte-exact root sets while arming `exists` as a
            # tripwire, so a candidate the module discovered by itself may only
            # be adopted after the seam confirms it. A guess about a directory
            # that does not exist protects nothing anyway.
            my $ex = eval { $exists_fn->("$pw[7]/.claude") };
            return () if $@ || !$ex;
            return ($pw[7]);
        },
    );
}

# =====================================================================
# q04 §2.3 -- the registry / extra-list SOURCE as a candidate SET.
# Given a path relative to a claude-home directory, return the additional
# paths to try under every SOURCE-ELIGIBLE home candidate, minus the one the
# primary acquisition already used (never attempt the same file twice).
#
# The caller passes @source_candidates, NOT the full notion-A @home_candidates
# (q04 step 7, redteam MAJOR-1/MAJOR-2): a directory named verbatim by one
# environment variable may contribute a root but may not contribute a SOURCE.
# The reasoning lives at the @source_candidates declaration in protected_roots.
# =====================================================================
sub _candidate_source_paths {
    my ($relative, $home_candidates, $primary) = @_;
    my %seen;
    $seen{$primary} = 1 if defined $primary && !ref $primary;
    my @out;
    for my $h (@$home_candidates) {
        next unless defined $h && !ref $h && $h !~ /\A\s*\z/;
        my $p = "$h/$relative";
        next if $seen{$p}++;
        push @out, $p;
    }
    return @out;
}

# =====================================================================
# q04 §3 / step 7 (reviewer C1, redteam CRITICAL-1) -- WHICH candidate reasons
# the user-home rejection may act on. THIS SET IS SECURITY-CRITICAL; read the
# argument before widening it.
#
# The rejection compares against notion B (`_user_home`), which is read
# straight from the environment and is therefore ATTACKER-STEERABLE -- and it
# is wired to REMOVE roots. Applied to a root the module DERIVED ITSELF, that
# makes one environment variable a delete button for the guard's highest-value
# root: `USERPROFILE=C:/Users/u/.claude` on the Windows family (never hardened
# by launcher.pl's `_pp_env_seam`, and tried FIRST by notion B there) made the
# real `claude-home` root match `exact`, deleted it, and took
# `~/.claude/projects`, `/memory` and `/todos` from REFUSE to
# LAUNCH. That is blueprint C1 reopened, and it breaks Appendix B Decision #3
# ("no override, no env var, no flag") and criterion D5.
#
# So gate the rejection by candidate REASON. The outage the rejection exists to
# prevent (finding 3) arrives only through a malformed/hostile registry entry or
# extra-list element -- i.e. through content, not through the module's own
# derivation. `claude-home` and `ccpraxis-install` are derived by the module
# from sources it already trusts, so a "rejected" one is always a LOSS, never a
# repair. AC-72 pins this; AC-62..AC-66 (every existing rejection assertion) use
# a reason from this set, so the gate costs the guard nothing.
my %HOME_REJECTABLE = map { $_ => 1 } qw(
    marketplace-install
    marketplace-source
    user-configured
);
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
    #
    # q04 §2.1/§2.2 extend the same argument off the environment entirely.
    # This is NOTION A ("home_candidates", plural): deliberately MAXIMAL,
    # because a *missing* candidate SHRINKS the protected set and makes the
    # guard fail open, which Decision #6 forbids. It is the exact opposite
    # bias from notion B (`_user_home`, singular, env-derived, unchanged by
    # q04) used further down to REMOVE roots -- the biases are opposite
    # because the consequences of error are opposite. Do not conflate them.
    #
    # q04 step 7 (redteam MAJOR-1/MAJOR-2) draws a THIRD distinction inside
    # notion A, and it is the one that matters for trust: a home candidate may
    # always contribute a protected ROOT, but only some of them may name a
    # SOURCE FILE whose contents become roots. See @source_candidates below.
    my $home_raw;            # unnormalised base of the *primary* default registry/extra path
    my @home_candidates;     # notion A: every candidate, roots only
    my @source_candidates;   # the subset trusted to NAME A SOURCE FILE (§2.3)
    {
        my $cfg = eval { $env_fn->('CLAUDE_CONFIG_DIR') };
        $cfg = undef if $@;
        my $home_env = eval { $env_fn->('HOME') };
        $home_env = undef if $@;
        my $userprofile = eval { $env_fn->('USERPROFILE') };
        $userprofile = undef if $@;

        push @home_candidates, $cfg                  if defined $cfg         && $cfg         !~ /\A\s*\z/;
        push @home_candidates, "$home_env/.claude"    if defined $home_env    && $home_env    !~ /\A\s*\z/;
        push @home_candidates, "$userprofile/.claude" if defined $userprofile && $userprofile !~ /\A\s*\z/;

        # q04 step 7 (redteam MAJOR-1 / MAJOR-2) -- WHICH candidates may act as
        # a SOURCE, i.e. may have `plugins/known_marketplaces.json` or
        # `ccpraxis-protected-paths.json` read out of them and their CONTENTS
        # adopted as protected roots. This is a strictly narrower question than
        # "may it be a root", and conflating the two was the defect:
        #
        #   * a candidate contributing only a ROOT can at worst over-refuse
        #     ITSELF -- a bounded, self-inflicted, recoverable cost, and the
        #     safe direction per Decision #6 (AC-74's third assertion requires
        #     the env-named dir to keep contributing its own root);
        #   * a candidate acting as a SOURCE contributes ARBITRARY THIRD-PARTY
        #     PATHS. `CLAUDE_CONFIG_DIR=/tmp/evil` plus one planted JSON file
        #     naming `["/home"]` refused every project on the machine, and with
        #     no override (Decision #3) that outage is unrecoverable. The same
        #     fan-out also RESURRECTED a stale registry under a former home and
        #     refused a legitimate ccpraxis clone -- a C6 regression
        #     (blueprint.md:176-179) hitting an ordinary user with no attacker
        #     involved. It additionally re-opened the hole q03 closed by pinning
        #     `extra_list_path` (launcher.pl:556).
        #
        # So: a directory named VERBATIM by a single environment variable is not
        # a trusted source. `CLAUDE_CONFIG_DIR` (taken verbatim) and
        # `USERPROFILE` are dropped from the source set; what remains is
        # `$HOME/.claude` -- the module's own pre-q04 source, and the one
        # variable launcher.pl's `_pp_env_seam` hardens (:291-305) -- plus the
        # env-INDEPENDENT probe results, which is exactly what finding 2's
        # fan-out was for (AC-58/AC-59 depend on those). Keeping HOME is
        # therefore not a widening: it is the pre-q04 baseline.
        push @source_candidates, "$home_env/.claude"
            if defined $home_env && $home_env !~ /\A\s*\z/;

        # q04 §2.2 -- env-INDEPENDENT probes, additive and best-effort. Each
        # probe is invoked under its OWN eval: a probe that dies contributes
        # nothing, is NOT an error, and leaves every other candidate intact
        # (AC-61, §M5). `home_probes` replaces the default probe list and
        # returns HOME DIRECTORIES (what getpwuid's pw_dir is); the "/.claude"
        # suffix is appended here, in one place. Probe results are
        # source-eligible: they come from the OS's own record (or from a caller
        # that injected the seam deliberately), not from an environment
        # variable an attacker can point anywhere.
        # q04 step 7 (reviewer m2) -- the DEFAULT probe list is built only when
        # the caller injected NO `exists` seam. An injected existence oracle
        # means "do not talk to the ambient host": t/51 guarantees no test
        # touches the real filesystem (`t/51:11-15`), yet the default passwd
        # probe made every call there consult the real passwd database, so
        # fixtures arming `exists => sub { 1 }` adopted a root derived from the
        # HOST's `/root/.claude` and the suite's results became host-dependent.
        # This is not a new coupling -- the probe's existence gate already routed
        # through the seam, so a caller injecting `exists => sub { 0 }` already
        # disabled it; the gate just makes that explicit one level up, and lets
        # the probe use the REAL `-e` in the branch that is genuinely ambient.
        # Production is unaffected: launcher.pl:553-559 injects `env` only, never
        # `exists`, so finding 2's passwd probe still runs there. A future caller
        # that injects `exists` AND wants ambient probing must pass `home_probes`
        # itself -- which is the seam for exactly that.
        my @probes = (defined $opts->{home_probes} && ref $opts->{home_probes} eq 'CODE')
            ? ($opts->{home_probes})
            : (exists $opts->{exists} ? () : _default_home_probes($exists_fn));
        for my $probe (@probes) {
            my @got = eval { $probe->() };
            @got = () if $@;
            for my $h (@got) {
                next if ref $h;
                next unless defined $h && $h !~ /\A\s*\z/;
                push @home_candidates,   "$h/.claude";
                push @source_candidates, "$h/.claude";
            }
        }

        # `$home_raw` is the base of the *PRIMARY* default registry/extra-list
        # path (§2.5.1), so it is a source and obeys the source rule above: the
        # precedence chain now runs over source-eligible values only, i.e.
        # `$HOME/.claude` then the first probe candidate. It is deliberately NOT
        # `CLAUDE_CONFIG_DIR` any more -- the planted-file injection above
        # arrived through the PRIMARY default, not only through §2.3's fan-out,
        # so gating the fan-out alone would have left the hole open (measured).
        # In production this changes nothing: launcher.pl:556 pins both
        # `registry_path` and `extra_list_path` explicitly, so the module's own
        # default is not consulted at all.
        for my $sc (@source_candidates) {
            $home_raw = $sc;
            last;
        }

        if (@home_candidates) {
            for my $hc (@home_candidates) {
                my $n = _ingest_path($hc, $opts);
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

    # The per-entry walk is a closure rather than inline code so q04 §2.3 can
    # apply it to EVERY registry the candidate set discovers (below), without
    # duplicating any of the hostile-registry hardening it carries.
    my $ingest_registry = sub {
        my ($reg) = @_;
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
                    my $il_n = _ingest_path($entry->{installLocation}, $opts);
                    if (defined $il_n) {
                        push @candidates, { path => $il_n, reason => 'marketplace-install' };
                    } else {
                        push @errors, { code => 'registry-entry', detail => "entry '$name' installLocation is invalid" };
                    }

                    my $src = $entry->{source};
                    if (ref $src eq 'HASH') {
                        if (($src->{source} // '') eq 'directory') {
                            my $sp_n = _ingest_path($src->{path}, $opts);
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
    };

    # Invoke the walk on the primary registry. This preserves exactly the
    # pre-q04 behaviour ("run the walk when a registry resolved"); §2.3's
    # candidate-set fan-out applies the same closure to any ADDITIONAL
    # registries discovered under other home candidates.
    $ingest_registry->($reg) if defined $reg;

    # ---- q04 §2.3: the registry SOURCE is a candidate SET -----------------
    # `$home_raw` is a SINGLE precedence-ordered value, and `$registry_default`
    # is derived from it, so a redirected HOME poisons the module's OWN default
    # registry path -- the residue q01 knowingly left (see its comment at step
    # 1). This applies the very transformation q01 made one layer up for the
    # claude-home roots, and its recorded rationale holds verbatim: a
    # precedence chain lets one redirected variable REMOVE a real protected
    # root while `errors` stays clean.
    #
    # So: try the same relative file under EVERY notion-A home candidate and
    # UNION the roots. An explicitly supplied `registry_path` (the launcher
    # always supplies one) is still honoured above and is ADDED TO here, never
    # replaced (AC-59); `_candidate_source_paths` drops the primary so no file
    # is read twice. Fold-key dedup (step 6) absorbs the overlap when two home
    # candidates name the same roots.
    #
    # `missing_is_error => 0` for these, unlike the primary: the primary is the
    # file the caller NAMED, so its absence is worth a warning, whereas these
    # are speculative discovery where absence is the normal case -- one
    # `registry-missing` per candidate home would be pure noise (and would
    # break AC-28's "exactly one error"). A registry that IS there but is
    # unreadable/unparseable/misshapen still reports, since that is a real
    # broken source.
    #
    # Skipped entirely when `registry` is supplied AS DATA: that is the caller
    # handing us the registry outright, not asking us to find one.
    my $candidate_reg;   # first candidate-derived registry (step 4 fallback)
    unless (exists $opts->{registry}) {
        my $primary = exists $opts->{registry_path} ? $opts->{registry_path} : $registry_default;
        for my $path (_candidate_source_paths('plugins/known_marketplaces.json',
                                              \@source_candidates, $primary)) {
            my ($raw, $attempted) = _acquire_json_source(
                opts             => {},
                data_key         => 'registry',
                path_key         => 'registry_path',
                default_path     => $path,
                exists_fn        => $exists_fn,
                read_fn          => $read_file_fn,
                missing_is_error => 0,
                errors           => \@errors,
                label            => 'registry',
                code_missing     => undef,
                code_unreadable  => 'registry-unreadable',
                code_unparseable => 'registry-unparseable',
            );
            next unless $attempted;
            if (ref $raw eq 'HASH') {
                $candidate_reg //= $raw;
                $ingest_registry->($raw);
            } else {
                push @errors, { code => 'registry-shape',
                                detail => "registry is not a JSON object: $path" };
            }
        }
    }

    # ---- §2.5.2 step 4: ccpraxis-install (source d) ----------------------
    {
        my $install;
        if (defined $reg) {
            $install = eval { live_install_dir({ registry => $reg }) };
        } elsif (defined $candidate_reg) {
            # q04 §2.3: when the primary registry is missing or poisoned but a
            # candidate home yielded one, derive the ccpraxis-install root from
            # THAT rather than falling through to the ambient-filesystem
            # branch. Losing this root is exactly the shrinkage Decision #6
            # forbids.
            $install = eval { live_install_dir({ registry => $candidate_reg }) };
        } else {
            $install = eval { live_install_dir({}) };
        }
        $install = undef if $@;
        if (defined $install) {
            my $n = _ingest_path($install, $opts);
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
    # (reviewer M1's direct sibling for extra-list-shape). Factored into a
    # closure for the same reason as $ingest_registry: q04 §2.3 applies it to
    # every extra list the home-candidate set discovers, not only the primary.
    my $ingest_extra_list = sub {
        my ($list) = @_;
        for my $el (@$list) {
            my $n = _ingest_path($el, $opts);
            if (defined $n) {
                push @candidates, { path => $n, reason => 'user-configured' };
            } else {
                push @errors, { code => 'extra-list-entry', detail => 'extra-list element is not a usable path' };
            }
        }
    };

    if (ref $extra_raw eq 'ARRAY') {
        $ingest_extra_list->($extra_raw);
    } elsif ($extra_attempted) {
        push @errors, { code => 'extra-list-shape', detail => 'extra list is not a JSON array' };
    }

    # q04 §2.3, the extra list's half: identical argument to the registry's.
    # Decision #5's user list must not be voidable by a redirected HOME either
    # -- the launcher pins an explicit `extra_list_path` precisely because
    # CLAUDE_CONFIG_DIR could otherwise silently empty it, and this closes the
    # same hole on the module's own default.
    unless (exists $opts->{extra_list}) {
        my $primary = exists $opts->{extra_list_path} ? $opts->{extra_list_path} : $extra_default;
        for my $path (_candidate_source_paths('ccpraxis-protected-paths.json',
                                              \@source_candidates, $primary)) {
            my ($raw, $attempted) = _acquire_json_source(
                opts             => {},
                data_key         => 'extra_list',
                path_key         => 'extra_list_path',
                default_path     => $path,
                exists_fn        => $exists_fn,
                read_fn          => $read_file_fn,
                missing_is_error => 0,
                errors           => \@errors,
                label            => 'extra list',
                code_missing     => undef,
                code_unreadable  => 'extra-list-unreadable',
                code_unparseable => 'extra-list-unparseable',
            );
            next unless $attempted;
            if (ref $raw eq 'ARRAY') {
                $ingest_extra_list->($raw);
            } else {
                push @errors, { code => 'extra-list-shape',
                                detail => "extra list is not a JSON array: $path" };
            }
        }
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
        #
        # q04 step 7 (reviewer M2 / redteam MINOR-7): the FIRST USE of the
        # returned value lives inside the SAME eval as the call. Wrapping only
        # the call left `length $raw` outside it, so a seam returning an object
        # with an overloaded `""` that dies took protected_roots down with it --
        # violating the absolute "never dies" contract in the module header
        # (§M5) and spec §0 C-0.2. `!ref` rejects a ref before anything can
        # stringify it, and the explicit "$v" forces stringification where an
        # exception is still caught. (CcpraxisWorkCopy::_same_path:164-166
        # carries the identical original flaw; fixing it is not in this write
        # set, so do not copy the shape back from there.) AC-75 pins this.
        my $raw = eval {
            my $v = $realpath_fn->($c->{path});
            (defined $v && !ref $v && length $v) ? "$v" : undef;
        };
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

    # q04 §3 -- the user-home half of the rejection guard. Notion B
    # (`_user_home`: minimal, precedence-ordered, env-derived) and NOT the
    # maximal notion-A candidate set: this value is used to REMOVE roots, so
    # widening it would remove more roots and refuse more legitimate projects
    # -- the opposite error from finding 2's (§2.1's asymmetry).
    my $user_home = _user_home($opts);

    my @kept;
    for my $c (@resolved) {
        if (_is_bare_root($c->{path})) {
            push @errors, { code => 'root-bare-rejected', detail => "$c->{reason}: $c->{path}" };
            next;
        }
        # One malformed installLocation that normalises to the user's home
        # makes EVERY project on the machine a descendant of a protected root,
        # and with no override (Decision #3) that is an unrecoverable outage
        # rather than an inconvenience. So reject it -- but EXACT MATCH ONLY,
        # never a descendant: `~/.claude` IS a descendant of the home and is
        # the guard's single highest-value root, so rejecting descendants
        # would delete the very protection being repaired (AC-64).
        # Compared through path_relation, which is segment-aware and honours
        # the platform fold rule (Decision #8), not by string equality
        # (AC-65). This is a per-candidate rejection, never an abort: the
        # remaining roots keep protecting normally (AC-63). The code is an
        # ERROR code and never a root `reason`, so it cannot leak into
        # `roots` (AC-47/AC-66).
        # ...and ONLY for a reason in %HOME_REJECTABLE (see the comment on that
        # hash): the right-hand operand is env-derived, so letting it remove a
        # module-derived root turns one environment variable into an override
        # (AC-72).
        if ($HOME_REJECTABLE{ $c->{reason} }
            && defined $user_home && $user_home !~ /\A\s*\z/) {
            my $rel = eval { path_relation($c->{path}, $user_home, $opts) };
            # `exact` is finding 3's original case. `ancestor` -- read per
            # path_relation's own contract at §2.4, "the FIRST argument CONTAINS
            # the second", so here: the candidate contains the user home, i.e.
            # it is a strict ANCESTOR of it (equivalently
            # `path_relation($user_home, $c->{path}) eq 'descendant'`; the
            # relation is symmetric, so one call answers both) -- is q04 step 7
            # (redteam MAJOR-3):
            # done-criterion 3 was only half closed, because `/home`, `/Users`
            # and `C:/Users` are neither bare nor exactly the home, so they were
            # adopted and refused every project on the machine. That is the same
            # unrecoverable outage as the exact match (Decision #3 forbids an
            # override), so it gets the same treatment and the same error code.
            #
            # THE ASYMMETRY IS THE POINT AND MUST NOT BE COLLAPSED: a candidate
            # that is a DESCENDANT of the home -- `~/.claude`, the guard's single
            # highest-value root -- is still KEPT. Only the ancestor direction is
            # an outage; the descendant direction is the protection itself.
            # AC-64 pins the exact-match case, AC-73 pins both halves of this
            # widening.
            if (defined $rel && ($rel eq 'exact' || $rel eq 'ancestor')) {
                push @errors, { code => 'root-home-rejected', detail => "$c->{reason}: $c->{path}" };
                next;
            }
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
