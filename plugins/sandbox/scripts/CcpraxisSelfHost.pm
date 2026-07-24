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
    default_worktree_path
    worktree_plan
    blueprint_copy_plan
    provision_state
    provision_repair_plan
    fleet_live
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

# =====================================================================
# p02 — worktree provisioning
# =====================================================================

# Constant: the fixed branch name for the self-host worktree.
use constant WORKTREE_BRANCH => 'ccpraxis-sandbox-workcopy';

# _utf8_bytes($s) — normalise a path from JSON/registry decode to UTF-8 bytes.
# JSON::PP->decode returns wide characters (é = U+00E9); filesystem and git
# output are UTF-8 bytes (é = 0xC3 0xA9). Comparing them with `eq` silently
# fails on any non-ASCII install path. Re-encode a wide-char string back to
# UTF-8 bytes; leave already-byte strings untouched (guarded by utf8::is_utf8).
sub _utf8_bytes {
    my ($s) = @_;
    return $s unless defined $s;
    utf8::encode($s) if utf8::is_utf8($s);
    return $s;
}

# =====================================================================
# §2.1 — default_worktree_path(\%opts) -> canon path string | undef
# Precedence: explicit worktree_path > env.CCPRAXIS_WORKTREE_PATH > <home>/ccpraxis-sandbox-workcopy
# Never touches the filesystem.
# =====================================================================
sub default_worktree_path {
    my ($opts) = @_;
    $opts //= {};

    my $env  = exists $opts->{env} ? $opts->{env} : \%ENV;
    my $home = $opts->{home}
             // $env->{USERPROFILE}
             // $env->{HOME};

    # Determine raw path via precedence
    my $raw;
    if (defined $opts->{worktree_path} && length $opts->{worktree_path}) {
        $raw = _utf8_bytes($opts->{worktree_path});
    } elsif (defined $env->{CCPRAXIS_WORKTREE_PATH} && length $env->{CCPRAXIS_WORKTREE_PATH}) {
        $raw = _utf8_bytes($env->{CCPRAXIS_WORKTREE_PATH});
    } elsif (defined $home && length $home) {
        $raw = _utf8_bytes($home) . '/' . WORKTREE_BRANCH;
    } else {
        return undef;
    }

    # Expand a leading ~ against home
    if (defined $raw && $raw =~ m{^~/}) {
        return undef unless defined $home && length $home;
        (my $h = _utf8_bytes($home)) =~ s{/+$}{};
        $raw =~ s{^~/}{$h/};
    } elsif (defined $raw && $raw eq '~') {
        return undef unless defined $home && length $home;
        $raw = _utf8_bytes($home);
    }

    return undef unless defined $raw && length $raw;
    return canon_path($raw);
}

# =====================================================================
# §2.2 — worktree_plan(\%opts) -> HASH ref
# Pure planner for the git-worktree operation. No git, no fs.
# =====================================================================
sub worktree_plan {
    my ($opts) = @_;
    $opts //= {};

    my $live_root = canon_path(_utf8_bytes($opts->{live_root}));
    my $target    = default_worktree_path($opts);
    my $state     = $opts->{state} // 'absent';
    my $branch    = WORKTREE_BRANCH;

    if ($state eq 'complete') {
        return {
            branch       => $branch,
            target       => $target,
            live_root    => $live_root,
            git_argv     => [],
            needs_add    => 0,
            needs_branch => 0,
        };
    } elsif ($state eq 'branch_exists') {
        # Branch exists but no worktree at target: reuse branch, omit -b
        return {
            branch       => $branch,
            target       => $target,
            live_root    => $live_root,
            git_argv     => ['git', '-C', $live_root, 'worktree', 'add', $target, $branch],
            needs_add    => 1,
            needs_branch => 0,
        };
    } elsif ($state eq 'partial') {
        # Worktree registered at target but on wrong branch — advisory only
        return {
            branch       => $branch,
            target       => $target,
            live_root    => $live_root,
            git_argv     => [],
            needs_add    => 0,
            needs_branch => 0,
            conflict     => $opts->{current_branch} // 'unknown',
        };
    } else {
        # absent (default): full create with -b
        return {
            branch       => $branch,
            target       => $target,
            live_root    => $live_root,
            git_argv     => ['git', '-C', $live_root, 'worktree', 'add', $target, '-b', $branch],
            needs_add    => 1,
            needs_branch => 1,
        };
    }
}

# =====================================================================
# §2.3 — blueprint_copy_plan($live_root, $worktree_path) -> HASH ref
# Pure planner for the blueprint-tree copy. Both args are canon path strings.
# =====================================================================
sub blueprint_copy_plan {
    my ($live_root, $wt) = @_;
    $live_root = _utf8_bytes($live_root);
    $wt        = _utf8_bytes($wt);
    return {
        src => "$live_root/.ccpraxis-local-data/blueprints",
        dst => "$wt/.ccpraxis-local-data/blueprints",
    };
}

# =====================================================================
# §2.4 — provision_state(\%opts) -> 'absent' | 'partial' | 'complete'
# Pure classifier. All facts injected via %opts.
# =====================================================================
sub provision_state {
    my ($opts) = @_;
    $opts //= {};

    my $wl         = $opts->{worktree_list};
    my $target     = _utf8_bytes($opts->{target} // '');
    my $branch     = $opts->{branch} // WORKTREE_BRANCH;
    my $copy_probe = $opts->{copy_probe} // sub { 'complete' };
    my $lock_probe = $opts->{lock_probe} // sub { 0 };

    # No worktree list -> absent
    return 'absent' unless defined $wl && length $wl;

    # Parse porcelain records (blank-line separated)
    my @records;
    for my $block (split /\n\n+/, $wl) {
        my %rec;
        for my $line (split /\n/, $block) {
            if ($line =~ /^worktree (.+)$/) { $rec{path}   = $1; }
            if ($line =~ /^branch (.+)$/)   { $rec{branch} = $1; }
            if ($line =~ /^HEAD /)          { $rec{has_head} = 1; }
            if ($line =~ /^bare$/)          { $rec{bare}   = 1; }
            if ($line =~ /^detached$/)      { $rec{detached} = 1; }
        }
        push @records, \%rec if %rec;
    }

    # Find the record whose canon_path matches target
    my $target_canon = canon_path($target);
    my $matched;
    for my $rec (@records) {
        next unless defined $rec->{path};
        my $p = canon_path(_utf8_bytes($rec->{path}));
        if (defined $p && defined $target_canon && $p eq $target_canon) {
            $matched = $rec;
            last;
        }
    }

    # No match -> absent
    return 'absent' unless defined $matched;

    # Match found — check branch, copy, lock
    my $rec_branch = $matched->{branch} // '';
    my $branch_ok  = $rec_branch =~ m{(^|/)$branch$};

    unless ($branch_ok) {
        return 'partial';
    }

    my $copy_state = eval { $copy_probe->() } // 'absent';
    if ($copy_state eq 'partial' || $copy_state eq 'absent') {
        return 'partial';
    }

    my $has_lock = eval { $lock_probe->() } // 0;
    if ($has_lock) {
        return 'partial';
    }

    return 'complete';
}

# =====================================================================
# §2.5 — provision_repair_plan($state, \%opts) -> HASH ref
# Pure ordered-steps planner to reach 'complete'. No git/fs.
# =====================================================================
sub provision_repair_plan {
    my ($state, $opts) = @_;
    $opts //= {};

    my $live_root    = $opts->{live_root} // '';
    my $target       = $opts->{target}    // '';
    my $branch       = $opts->{branch}    // WORKTREE_BRANCH;
    my $branch_wrong = $opts->{branch_wrong} // 0;
    my $has_lock     = $opts->{lock}      // 0;

    if ($state eq 'complete') {
        return { state => $state, steps => [], noop => 1 };
    }

    my @steps;

    if ($state eq 'absent') {
        # Get the worktree_add argv from worktree_plan.
        # If branch_exists is set (e.g. after a worktree removal, which leaves the
        # branch behind), reuse the branch as a positional arg (no -b) to avoid the
        # "branch already exists" hard-fail. Otherwise create it fresh with -b.
        my $wt_state = $opts->{branch_exists} ? 'branch_exists' : 'absent';
        my $plan = worktree_plan({ %$opts, state => $wt_state });
        push @steps, { op => 'worktree_add', argv => $plan->{git_argv} };
        push @steps, { op => 'copy_tree' };
        return { state => $state, steps => \@steps, noop => 0 };
    }

    # partial: ordered repair steps
    if ($has_lock) {
        push @steps, { op => 'clear_lock', note => 'remove leftover lock/temp file' };
    }
    if ($branch_wrong) {
        # Switch the existing worktree onto the right branch
        # Use 'switch' (not checkout) — list-form git
        push @steps, {
            op   => 'fix_branch',
            argv => ['git', '-C', $target, 'switch', $branch],
        };
    }
    push @steps, { op => 'copy_tree' };

    return { state => $state, steps => \@steps, noop => 0 };
}

# =====================================================================
# §2.6 — fleet_live(\%opts) -> 0|1
# Host-observable liveness verdict. All probes injected.
# SHARED with p03 — factor once here.
# =====================================================================
sub fleet_live {
    my ($opts) = @_;
    $opts //= {};

    my $container_name    = $opts->{container_name} // '';
    my $container_running = $opts->{container_running} // sub { 0 };
    my $marker_probe      = $opts->{marker_probe}      // sub { undef };
    my $now               = $opts->{now}               // time();
    my $fresh_window      = $opts->{fresh_window}      // 900;

    # Primary: container running
    if (eval { $container_running->($container_name) }) {
        return 1;
    }

    # Secondary: fresh marker
    my $mtime = eval { $marker_probe->() };
    if (defined $mtime && ($now - $mtime) <= $fresh_window) {
        return 1;
    }

    return 0;
}

1;
