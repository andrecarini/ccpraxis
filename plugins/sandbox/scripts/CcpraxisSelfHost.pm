package CcpraxisSelfHost;
# Detection + routing for the ccpraxis self-host flow (p01).
# All external facts are injected via %opts seams so tests need neither
# a real git repo nor Andre's machine.
#
# Security redesign per spec §9 (red-team fix-batch):
#   §9.1  hint-first anchor (_resolve_install_anchor)
#   §9.2  selfhost_route fail-safe
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
    selfhost_route
    selfhost_decline_outcome
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
# §9.1 — _resolve_install_anchor(\%opts)
# Internal helper: hint takes precedence over registry.
# =====================================================================
sub _resolve_install_anchor {
    my ($opts) = @_;
    $opts //= {};
    my $h = $opts->{live_install_hint};
    return canon_path($h) if defined $h && length $h;
    return live_install_dir($opts);
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
    return (defined $ca && defined $cb && $ca eq $cb) ? 1 : 0;
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

    # (A) Commondir + registry match
    my $install = live_install_dir($opts);
    if (defined $install) {
        my $gcd = eval { $gcd_fn->($path) };
        if (defined $gcd) {
            my $expected = canon_path("$install/.git");
            if (defined $expected && canon_path($gcd) eq $expected) {
                return 1;
            }
        }
    }

    # (B) Content-marker fallback. The ccpraxis marketplace manifest lives at
    # plugins/.claude-plugin/marketplace.json (the marketplace SOURCE dir is
    # plugins/), NOT at the repo root — checking the root silently missed the real
    # live repo (its only .claude-plugin/marketplace.json is under plugins/).
    if ($exists_fn->("$path/plugins/.claude-plugin/marketplace.json") &&
        $exists_fn->("$path/plugins/sandbox/scripts/launcher.pl")) {
        return 1;
    }

    return 0;
}

# =====================================================================
# §2.4 / §9.1 — is_in_place($path, \%opts) -> 0|1
# TRUE iff path resolves to the live install anchor (hint-first).
# =====================================================================
sub is_in_place {
    my ($path, $opts) = @_;
    $opts //= {};
    my $anchor = _resolve_install_anchor($opts);
    return 0 unless defined $anchor;
    return _same_path($path, $anchor, $opts);
}

# =====================================================================
# §2.5 / §9.2 — selfhost_route($path, \%opts) -> 'offer' | 'passthrough'
# Fail-safe: ccpraxis identity + NO resolvable anchor -> offer.
# =====================================================================
sub selfhost_route {
    my ($path, $opts) = @_;
    $opts //= {};
    return 'offer' if is_ccpraxis_project($path, $opts) && is_in_place($path, $opts);
    # fail-safe: identity is ccpraxis but NO anchor is resolvable ->
    # cannot rule out in-place; offering beats a silent in-place launch.
    return 'offer' if is_ccpraxis_project($path, $opts) && !defined _resolve_install_anchor($opts);
    return 'passthrough';
}

# =====================================================================
# §2.6 — selfhost_decline_outcome(\%opts) -> HASH ref
# Pure description of the decline outcome.
# =====================================================================
sub selfhost_decline_outcome {
    my ($opts) = @_;
    $opts //= {};
    return {
        warn    => 1,
        launch  => 0,
        message => "Declined: sandboxing ccpraxis in place was declined and is aborting. "
                 . "Use the self-host flow (claude-sandbox --selfhost or accept the offer) "
                 . "to safely provision a worktree sandbox instead of launching in place.",
    };
}

1;
