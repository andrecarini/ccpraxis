package CcpraxisWorkCopy;
# Detection + routing for the ccpraxis sandboxed work-copy flow (p01).
# All external facts are injected via %opts seams so tests need neither
# a real git repo nor Andre's machine.
#
# Security redesign per spec §9 (red-team fix-batch):
#   §9.1  anchor set, hint first then registry (_install_anchors)
#   §9.2  workcopy_route fail-safe
#   §9.3  non-shell list-form git (RCE fix)
#   §9.4  bare-root derived-install-dir rejection

use strict;
use warnings;
use Exporter qw(import);
use File::Basename qw(dirname);
use File::Spec ();
use Cwd ();
use JSON::PP ();
use MountSpec qw(winify_path);

our @EXPORT_OK = qw(
    is_ccpraxis_project
    is_in_place
    workcopy_route
    workcopy_refusal_outcome
    canon_path
    live_install_dir
);

# =====================================================================
# §2.1 — canon_path($path)
# String-normalise a path so comparisons are drive-letter/slash-insensitive.
# Never touches the filesystem.
# =====================================================================
sub canon_path {
    my ($p) = @_;
    return undef unless defined $p && length $p;
    $p =~ s|\\|/|g;                     # backslash -> forward slash
    $p =~ s|/+$|| if $p =~ m|/.+|;     # strip trailing slash(es), but keep bare root slash
    $p = winify_path($p);               # /c/... -> C:/... on Windows
    # Uppercase drive letter on Windows family
    if ($^O =~ /^(MSWin32|cygwin|msys)$/) {
        $p =~ s|^([a-z]):|uc($1).':'|e;
    }
    return $p;
}

# =====================================================================
# §2.2 — live_install_dir(\%opts)
# Resolves the live ccpraxis repo root from the known_marketplaces.json
# ccpraxis-local entry. Returns canon_path'd root, or undef on any failure.
# §9.4: rejects a bare-root derived install dir.
# =====================================================================
sub live_install_dir {
    my ($opts) = @_;
    $opts //= {};

    my $reg;
    if (exists $opts->{registry}) {
        $reg = $opts->{registry};
    } elsif (exists $opts->{registry_path}) {
        $reg = eval {
            open my $fh, '<:raw', $opts->{registry_path}
                or die "cannot open: $!\n";
            local $/;
            my $raw = <$fh>;
            close $fh;
            JSON::PP::decode_json($raw);
        };
        # Missing/unreadable/unparseable -> treat as no registry, never die
        $reg = undef if $@;
    }

    return undef unless defined $reg && ref $reg eq 'HASH';

    my $entry = $reg->{'ccpraxis-local'};
    return undef unless defined $entry && ref $entry eq 'HASH';

    my $src = $entry->{source};
    return undef unless defined $src && ref $src eq 'HASH';
    return undef unless ($src->{source} // '') eq 'directory';
    return undef unless defined $src->{path} && length $src->{path};

    # Encoding normalization (CRITICAL — real André-path bug the unit tests missed):
    # JSON::PP::decode_json returns DECODED characters (é = wide U+00E9), but the
    # filesystem and git --git-common-dir output are UTF-8 BYTES (é = 0xC3 0xA9).
    # Comparing the two with `eq` fails on ANY non-ASCII install path, silently
    # routing the real live repo to passthrough → in-place launch. Re-encode a
    # wide-char path back to UTF-8 bytes so every comparison is byte-vs-byte.
    # Guarded so an already-byte (ASCII) path is left untouched (no double-encode).
    my $reg_path = $src->{path};
    utf8::encode($reg_path) if utf8::is_utf8($reg_path);

    my $plugins_path = canon_path($reg_path);
    return undef unless defined $plugins_path;

    my $install = canon_path(dirname($plugins_path));
    return undef unless defined $install;

    # §9.4: reject bare drive/root (e.g. "C:", "/", "C:/")
    # Matches ^[A-Za-z]:?/?$ or length <= 3
    if ($install =~ m|^[A-Za-z]:?/?$| || length($install) <= 3) {
        return undef;
    }

    return $install;
}

# =====================================================================
# §9.1 — _install_anchors(\%opts)
# Internal helper: returns an ARRAYREF of canon_path'd install anchors.
# Never undef, never a bare list. Order: caller hint first, registry-derived
# second. Deduped by exact string equality on the canon_path'd values.
# =====================================================================
sub _install_anchors {
    my ($opts) = @_;
    $opts //= {};
    my @a;
    my $h = $opts->{live_install_hint};
    if (defined $h && length $h) {
        my $c = canon_path($h);
        push @a, $c if defined $c && length $c;
    }
    my $r = live_install_dir($opts);
    push @a, $r if defined $r && length $r;
    # first-seen-wins dedup on exact string equality
    my (%seen, @out);
    for my $x (@a) { push @out, $x unless $seen{$x}++; }
    return \@out;
}

# =====================================================================
# Default realpath seam — uses Cwd::abs_path; returns undef for
# non-existent paths (which is the desired fallback trigger).
# =====================================================================
my $_default_realpath = sub {
    my ($p) = @_;
    my $r = eval { Cwd::abs_path($p) };
    return $r;
};

# =====================================================================
# §9.1 — _same_path($a, $b, $opts)
# Compare two paths via an injectable realpath seam, falling back to
# canon_path when realpath returns undef/empty (fabricated test paths).
# =====================================================================
sub _same_path {
    my ($a, $b, $opts) = @_;
    $opts //= {};
    my $rp = $opts->{realpath} // $_default_realpath;
    my $ra = eval { $rp->($a) };
    my $rb = eval { $rp->($b) };
    my $ca = canon_path((defined $ra && length $ra) ? $ra : $a);
    my $cb = canon_path((defined $rb && length $rb) ? $rb : $b);
    return 0 unless defined $ca && defined $cb;
    # BLOCKER-2 fix: on case-insensitive filesystems (Windows/macOS), two
    # canon_path()'d strings that differ only in case are the SAME real
    # directory -- canon_path only uppercases the drive letter, it never
    # case-folds the rest of the path. Fold case for the comparison ONLY
    # (never change what canon_path returns; other callers rely on its
    # exact case-preserving output). Linux is correctly case-sensitive and
    # must not be folded.
    if ($^O =~ /^(MSWin32|cygwin|msys|darwin)$/) {
        return (lc($ca) eq lc($cb)) ? 1 : 0;
    }
    return ($ca eq $cb) ? 1 : 0;
}

# =====================================================================
# §2.3 — is_ccpraxis_project($path, \%opts) -> 0|1
# TRUE if path is the ccpraxis repo, a worktree, or a clone.
# Detection = (A) commondir+registry match OR (B) content-marker fallback.
# §9.3: default git seam uses list-form open (no shell).
# =====================================================================
sub is_ccpraxis_project {
    my ($path, $opts) = @_;
    $opts //= {};

    # Resolve the git_commondir seam
    my $gcd_fn = $opts->{git_commondir};
    unless (defined $gcd_fn) {
        $gcd_fn = sub {
            my ($p) = @_;
            local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
            my $out;
            # Save and redirect STDERR to devnull (fd-dup; no in-memory scalar — Win-perl caveat)
            open(my $saveerr, '>&', \*STDERR) or return undef;
            open(STDERR, '>', File::Spec->devnull) or do { open(STDERR, '>&', $saveerr); return undef; };
            my $pid = open(my $gfh, '-|', 'git', '-C', $p, 'rev-parse', '--git-common-dir');
            if ($pid) { local $/; $out = <$gfh>; close $gfh; }
            open(STDERR, '>&', $saveerr);
            return undef unless $pid;
            return undef if $?;                       # nonzero git exit
            return undef unless defined $out && length $out;
            chomp $out;
            # If git returns a relative path (e.g. ".git"), resolve relative to $p
            unless ($out =~ m|^([A-Za-z]:)?/|) {
                $out = "$p/$out";
            }
            return canon_path($out);
        };
    }

    # Resolve the exists seam
    my $exists_fn = $opts->{exists} // sub { -e $_[0] };

    # (A) commondir matches the .git of ANY resolved install anchor
    my $anchors = _install_anchors($opts);
    if (@$anchors) {
        my $gcd = eval { $gcd_fn->($path) };
        if (defined $gcd) {
            my $cg = canon_path($gcd);
            for my $a (@$anchors) {
                my $expected = canon_path("$a/.git");
                return 1 if defined $expected && defined $cg && $cg eq $expected;
            }
        }
    }

    # (B) marker-count fallback. The ccpraxis marketplace manifest lives at
    # plugins/.claude-plugin/marketplace.json (the marketplace SOURCE dir is
    # plugins/), NOT at the repo root — checking the root silently missed the real
    # live repo (its only .claude-plugin/marketplace.json is under plugins/).
    # Identity by markers iff at least TWO distinct members exist, so deleting
    # any single marker cannot disarm detection (MAJOR-3).
    my $count = 0;
    for my $marker (_ccpraxis_markers()) {
        $count++ if $exists_fn->("$path/$marker");
        last if $count >= 2;
    }
    return 1 if $count >= 2;

    return 0;
}

# =====================================================================
# §2.3 — _ccpraxis_markers()
# Ordered, relative to the project root. Private. Real ccpraxis-repo paths,
# each verified present in this clone on 2026-07-29.
# =====================================================================
sub _ccpraxis_markers {
    return (
        'plugins/.claude-plugin/marketplace.json',      # M1 marketplace manifest (SOURCE dir is plugins/)
        'plugins/sandbox/scripts/launcher.pl',          # M2
        'plugins/sandbox/.claude-plugin/plugin.json',   # M3
        'plugins/sandbox/scripts/MountSpec.pm',         # M4
        'plugins/sandbox/bin/claude-sandbox.sh',        # M5
        'plugins/sandbox/docs/working-on-ccpraxis.md',  # M6
    );
}

# =====================================================================
# §2.4 / §9.1 — is_in_place($path, \%opts) -> 0|1
# TRUE iff path resolves to the live install anchor (hint-first).
# =====================================================================
sub is_in_place {
    my ($path, $opts) = @_;
    $opts //= {};
    my $anchors = _install_anchors($opts);
    for my $a (@$anchors) { return 1 if _same_path($path, $a, $opts); }
    return 0;
}

# =====================================================================
# §2.5 / §9.2 — workcopy_route($path, \%opts) -> 'offer' | 'passthrough'
# Fail-safe: ccpraxis identity + NO resolvable anchor -> offer.
# =====================================================================
sub workcopy_route {
    my ($path, $opts) = @_;
    $opts //= {};
    return 'offer' if is_ccpraxis_project($path, $opts) && is_in_place($path, $opts);
    # fail-safe: identity is ccpraxis but NO anchor is resolvable ->
    # cannot rule out in-place; offering beats a silent in-place launch.
    return 'offer' if is_ccpraxis_project($path, $opts) && !@{ _install_anchors($opts) };
    return 'passthrough';
}

# =====================================================================
# §2.6 — workcopy_refusal_outcome(\%opts) -> HASH ref
# Pure description of the in-place refusal (Decision #1). No I/O.
# =====================================================================
sub workcopy_refusal_outcome {
    my ($opts) = @_;
    $opts //= {};
    my $path = (defined $opts->{path}      && length $opts->{path})      ? $opts->{path}      : '<project path>';
    my $live = (defined $opts->{live_root} && length $opts->{live_root}) ? $opts->{live_root} : $path;
    my $message = "claude-sandbox will not sandbox the ccpraxis installation in place:\n"
        . "\n"
        . "  $path\n"
        . "\n"
        . "This is the ccpraxis installation Claude Code is running from — its plugins,\n"
        . "skills and launcher are in use right now. Sandboxing it here would edit the\n"
        . "tooling while it is running, and git inside the container would not work.\n"
        . "\n"
        . "Work on a separate clone instead. Pick any ordinary directory outside this\n"
        . "install (for example C:/Development/ccpraxis on Windows, or ~/src/ccpraxis on\n"
        . "macOS or Linux), then run:\n"
        . "\n"
        . "  git clone --no-hardlinks $live <your-clone-dir>\n"
        . "  cd <your-clone-dir>\n"
        . "  claude-sandbox\n"
        . "\n"
        . "The --no-hardlinks flag is required: a local clone hardlinks the object store by\n"
        . "default, which would silently re-couple the clone to this installation.\n"
        . "\n"
        . "That clone is an ordinary project — git works normally inside the container, and\n"
        . "nothing it does can reach this installation. To bring changes back, merge them\n"
        . "into this install from the host:\n"
        . "\n"
        . "  git -C $live pull <your-clone-dir> main\n"
        . "\n"
        . "That alone promotes them: this repo IS the installed plugin tree. Re-run\n"
        . "install.pl only if the PATH wiring or the set of plugins changed.\n"
        . "See plugins/sandbox/docs/working-on-ccpraxis.md.\n"
        . "\n"
        . "Aborting.";
    return {
        warn      => 1,
        launch    => 0,
        exit_code => 1,
        message   => $message,
    };
}

1;
