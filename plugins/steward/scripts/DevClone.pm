# DevClone -- which checkout the backup reads from and which one it writes to.
#
# Two checkouts of ccpraxis exist on a machine, and they have opposite roles:
#
#   the live install  <home>/.claude/ccpraxis. What Claude Code runs. It is
#                     produced by scripts/promote.pl and by nothing else, so the
#                     backup only ever READS it: its scripts run, its committed
#                     payload is the baseline, its .backup-preferences.json holds
#                     this machine's answers. No git verb that changes it.
#   the dev clone     where development happens, and the only checkout that talks
#                     to GitHub (/steward:upstream-sync: fetch, integrate
#                     origin/main, push). /steward:backup, which never touches
#                     a remote, promotes it into the live install, exports into
#                     its working tree, commits only the files it wrote, and
#                     promotes again.
#
# promote.pl sets the live install's `origin` to the dev clone it promotes from,
# so that remote is how the backup finds the dev clone (locate()). A live install
# whose origin is still a GitHub URL was set up the old way; until it is promoted
# once, the backup cannot know where the dev clone is and skips the ccpraxis part.
#
# payload_check() is the precondition for exporting at all. The export merges
# live settings INTO the dev clone's payload files with live winning on shared
# keys, so a payload change sitting in the dev clone that was never promoted
# would be silently overwritten by the older live value. Exporting is therefore
# allowed only while the dev clone's payload (working tree and HEAD) is exactly
# what the live install was promoted with.
#
# Core modules only; no state. Callers: scripts/backup/Preflight.pm and
# Export.pm (loaded from the live install's copy of this directory),
# ccpraxis-helpers.pl, sync-export.pl and upstream-sync.pl (their own
# directory).
package DevClone;
use strict;
use warnings;
use Cwd ();
use File::Temp ();
use Exporter 'import';

our @EXPORT_OK = qw(
    PAYLOAD_PATHS default_live_root locate payload_check relation promote_argv promote_outcome
    git_path same_dir promote_hint redact run_capture run_git
);

# What the export writes and the payload check compares: the global-config/
# directory and the container's settings file. Repo-relative, forward slashes.
use constant PAYLOAD_PATHS => ('global-config', 'plugins/sandbox/container/settings.json');

# <home>/.claude/ccpraxis, the live install, in forward-slash form. promote.pl's
# --live defaults to the same directory; every backup-side script takes the live
# root from here (or from a --live-root argument the driver passes), so the
# ${CCPRAXIS_LIVE} expansion promote writes and the collapse the export does
# always agree on which directory the token stands for.
sub default_live_root {
    my ($home) = @_;
    $home = $ENV{HOME} unless defined $home && length $home;
    $home = $ENV{USERPROFILE} unless defined $home && length $home;
    return undef unless defined $home && length $home;
    (my $h = $home) =~ s{\\}{/}g;
    $h =~ s{/+\z}{};
    return "$h/.claude/ccpraxis";
}

# The forward-slash Windows form (C:/...) native git.exe accepts whether or not
# MSYS rewrites argv (the house rule, CLAUDE.md "MSYS2 mangles"). A no-op on
# macOS and Linux.
sub git_path {
    my ($p) = @_;
    return $p unless defined $p;
    (my $q = $p) =~ s{\\}{/}g;
    $q =~ s{^/([a-zA-Z])/}{uc($1) . ':/'}e;
    return $q;
}

sub _is_windows { return ($^O eq 'MSWin32' || $^O eq 'cygwin' || $^O eq 'msys') ? 1 : 0 }

# Canonical form for comparing two directories: resolved through symlinks (a
# macOS /var path is /private/var once resolved), forward slashes, no trailing
# slash, and case folded where the filesystem is case-insensitive (NTFS, APFS).
sub _canon {
    my ($p) = @_;
    return undef unless defined $p && length $p;
    my $n = git_path($p);
    my $abs = -e $n ? (Cwd::abs_path($n) // $n) : $n;
    $abs =~ s{\\}{/}g;
    $abs =~ s{(?<=.)/+\z}{};
    return (_is_windows() || $^O eq 'darwin') ? lc $abs : $abs;
}

sub same_dir {
    my ($a, $b) = @_;
    my ($ca, $cb) = (_canon($a), _canon($b));
    return (defined $ca && defined $cb && $ca eq $cb) ? 1 : 0;
}

# The one command that repairs every "dev clone not located" case.
sub promote_hint {
    my ($dev_clone) = @_;
    my $where = (defined $dev_clone && length $dev_clone) ? git_path($dev_clone) : '<dev clone>';
    return "run `perl $where/scripts/promote.pl` once; it points the live install's origin at the dev clone";
}

# run_capture(@cmd) -> ($exit, $stdout, $stderr): list form, stdout and stderr
# captured through real temp files (never an in-memory filehandle: Git-for-
# Windows perl fails on those). $exit is -1 when the command could not be
# started, and 128+N when a signal killed it (a bare $? >> 8 reads a
# signal-killed child as a clean 0).
sub run_capture {
    my (@cmd) = @_;
    my ($efh, $ename) = File::Temp::tempfile(UNLINK => 1);
    close $efh;
    my $saved;
    open($saved, '>&', \*STDERR) or return (-1, '', "cannot save STDERR: $!");
    unless (open(STDERR, '>', $ename)) {
        open(STDERR, '>&', $saved);
        return (-1, '', "cannot redirect STDERR: $!");
    }
    my ($out, $exit) = ('', -1);
    if (open(my $fh, '-|', @cmd)) {
        binmode $fh;   # bytes as the child wrote them (a git archive is binary)
        local $/;
        $out = <$fh> // '';
        close $fh;
        my $st = $?;
        $exit = ($st & 127) ? 128 + ($st & 127) : ($st >> 8);
    }
    open(STDERR, '>&', $saved);
    close $saved;
    my $err = '';
    if (open my $rfh, '<:raw', $ename) { local $/; $err = <$rfh> // ''; close $rfh; }
    unlink $ename;
    return ($exit, $out, $err);
}

# run_git($dir, @args) -> ($exit, $stdout, $stderr): the default git runner,
# `git -C <dir>` with no terminal prompt. Callers of locate() and friends may
# pass their own runner with the same contract.
sub run_git {
    my ($dir, @args) = @_;
    local $ENV{GIT_TERMINAL_PROMPT} = '0';
    # Paired with git_path() on the directory, never set alone.
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*' if _is_windows();
    return run_capture('git', '-C', git_path($dir), @args);
}

sub _line { my ($s) = @_; $s //= ''; $s =~ s/\s+\z//; return $s; }

# A URL's userinfo (https://user:token@host/...) never reaches a reason, a
# checkpoint or the driver's stdout.
sub redact { my ($s) = @_; return $s unless defined $s; $s =~ s{(://)[^/@\s]+@}{$1<redacted>@}g; return $s; }

# A remote that is a URL rather than a local path. file:// is a local path in
# disguise and is stripped by the caller first; C:/... and C:\... are local.
sub _is_url {
    my ($u) = @_;
    return 1 if $u =~ m{^[A-Za-z][A-Za-z0-9+.\-]*://};
    return 0 if $u =~ m{^[A-Za-z]:[\\/]};
    return 1 if $u =~ m{^[^/\\:]+:};      # scp-like: host:path, user@host:path
    return 0;
}

# locate(live_root => DIR, override => DIR?, git => CODE?) -> hashref
#
#   dev_clone   the dev clone's directory (forward slashes), or undef
#   source      'origin' or 'override' (BACKUP_CLONE_DIR, a test seam)
#   origin      the live install's origin as configured, or undef
#   reason      why there is no dev clone (undef when there is one)
#   fix         what to do about it (undef when there is one)
#
# Valid only if it is a local path to the top of a git work tree that has a main
# branch and is not the live install itself. Never changes anything.
sub locate {
    my (%a) = @_;
    my $git  = $a{git} // \&run_git;
    my $live = $a{live_root};
    my %r = (dev_clone => undef, source => undef, origin => undef, reason => undef, fix => undef);
    my $fail = sub {
        my ($reason, $fix) = @_;
        $r{reason} = $reason;
        $r{fix}    = $fix // promote_hint(undef);
        return \%r;
    };

    unless (defined $live && length $live && -d $live) {
        return $fail->('the live install was not found' . (defined $live ? " at $live" : ''),
            'install ccpraxis first: clone it as a dev clone, then run `perl <dev clone>/scripts/promote.pl`');
    }

    my $cand;
    if (defined $a{override} && length $a{override}) {
        $r{source} = 'override';
        $cand = $a{override};
    }
    else {
        $r{source} = 'origin';
        my ($rc, $out) = $git->($live, 'remote', 'get-url', 'origin');
        my $origin = _line($out);
        if ($rc != 0 || !length $origin) {
            return $fail->('the live install has no origin remote, so the dev clone it was promoted from is unknown');
        }
        $r{origin} = redact($origin);
        (my $local = $origin) =~ s{^file://}{};
        if (_is_url($local)) {
            return $fail->("the live install's origin is $r{origin}, not a local dev clone (a live install set up "
                         . 'before promote.pl owned it)');
        }
        $cand = $local;
    }

    $cand =~ s{\\}{/}g;
    $cand =~ s{(?<=.)/+\z}{};
    # A relative remote path is relative to the repository it is configured in.
    $cand = "$live/$cand" unless $cand =~ m{^/} || $cand =~ m{^[A-Za-z]:/};
    my $label = $r{source} eq 'override' ? "BACKUP_CLONE_DIR ($cand)" : "the live install's origin ($cand)";

    return $fail->("$label does not exist") unless -d git_path($cand) || -d $cand;
    my ($trc, $top) = $git->($cand, 'rev-parse', '--show-toplevel');
    $top = _line($top);
    return $fail->("$label is not a git work tree") if $trc != 0 || !length $top;
    return $fail->("$label is inside the git work tree $top, not at its top") unless same_dir($cand, $top);
    return $fail->("$label is the live install itself", 'promote from the dev clone: `perl <dev clone>/scripts/promote.pl`')
        if same_dir($cand, $live);
    my ($mrc) = $git->($cand, 'rev-parse', '-q', '--verify', 'refs/heads/main');
    return $fail->("$label has no main branch") if $mrc != 0;

    $r{dev_clone} = $cand;
    return \%r;
}

# path => blob id for every payload file committed at HEAD in $dir, or undef if
# HEAD cannot be read.
sub _payload_blobs {
    my ($git, $dir) = @_;
    my ($rc, $out) = $git->($dir, '-c', 'core.quotePath=false', 'ls-tree', '-r', '-z', 'HEAD', '--', PAYLOAD_PATHS);
    return undef if $rc != 0;
    my %blobs;
    for my $rec (split /\0/, $out // '') {
        next unless $rec =~ /^\d+ \S+ ([0-9a-f]+)\t(.+)\z/s;
        $blobs{$2} = $1;
    }
    return \%blobs;
}

# payload_check(live_root => DIR, dev_clone => DIR, git => CODE?) -> hashref
#
#   equal       1 when the dev clone's payload equals the live install's at HEAD
#               and the dev clone has no uncommitted payload change
#   differing   [ { path, why } ], why one of 'committed in the dev clone, not
#               promoted' | 'uncommitted in the dev clone'
#   error       why the comparison could not be made (then equal is 0)
#
# Blob ids are compared, not bytes, and the working-tree side is git's own
# status, so line-ending conversion on a Windows checkout is not a difference.
sub payload_check {
    my (%a) = @_;
    my $git = $a{git} // \&run_git;
    my ($live, $clone) = @a{qw(live_root dev_clone)};
    my %r = (equal => 0, differing => [], error => undef);

    my $lb = _payload_blobs($git, $live);
    unless ($lb) { $r{error} = "cannot read the live install's committed payload ($live)"; return \%r; }
    my $cb = _payload_blobs($git, $clone);
    unless ($cb) { $r{error} = "cannot read the dev clone's committed payload ($clone)"; return \%r; }

    my %paths = map { $_ => 1 } (keys %$lb, keys %$cb);
    for my $p (sort keys %paths) {
        next if defined $lb->{$p} && defined $cb->{$p} && $lb->{$p} eq $cb->{$p};
        my $why = !defined $cb->{$p} ? 'removed in the dev clone, not promoted'
                : !defined $lb->{$p} ? 'added in the dev clone, not promoted'
                :                      'committed in the dev clone, not promoted';
        push @{ $r{differing} }, { path => $p, why => $why };
    }

    my ($src, $sout, $serr) = $git->($clone, '-c', 'core.quotePath=false', 'status', '--porcelain',
                                     '--untracked-files=all', '--', PAYLOAD_PATHS);
    if ($src != 0) {
        $r{error} = 'git status failed in the dev clone: ' . _line($serr);
        return \%r;
    }
    for my $line (split /\r?\n/, $sout // '') {
        next unless $line =~ /^(..) (.+)\z/;
        my $p = $2;
        $p =~ s/^.* -> //;   # a rename: the new name is the one in the payload
        push @{ $r{differing} }, { path => $p, why => 'uncommitted in the dev clone' };
    }

    $r{equal} = @{ $r{differing} } ? 0 : 1;
    return \%r;
}

# relation(live_root => DIR, dev_clone => DIR, git => CODE?) -> hashref
#
#   state       'same'          the live install is at the dev clone's main
#               'ahead'         the dev clone's main has commits the live install
#                               lacks, and promotion would fast-forward to them
#               'live_has_own'  the live install's HEAD is not in the dev clone's
#                               main: it has commits of its own, which
#                               promote.pl refuses (they were made some other way)
#   live_head, clone_main   the two shas
#   commits     for 'ahead': [ { sha, subject } ], newest first
#   fix         for 'live_has_own': the command that brings them into the dev
#               clone (promote.pl's own wording)
#   error       why the relation could not be read (state is undef then)
#
# Promotion is a fast-forward of the live install to the dev clone's main, so
# this is the question every caller asks before running it.
sub relation {
    my (%a) = @_;
    my $git = $a{git} // \&run_git;
    my ($live, $clone) = @a{qw(live_root dev_clone)};
    my %r = (state => undef, live_head => undef, clone_main => undef, commits => [], fix => undef, error => undef);

    my ($lrc, $lout) = $git->($live, 'rev-parse', '-q', '--verify', 'HEAD');
    my ($crc, $cout) = $git->($clone, 'rev-parse', '-q', '--verify', 'refs/heads/main');
    if ($lrc != 0 || $crc != 0) {
        $r{error} = $lrc != 0 ? "cannot read the live install's HEAD ($live)" : "cannot read the dev clone's main ($clone)";
        return \%r;
    }
    @r{qw(live_head clone_main)} = (_line($lout), _line($cout));
    if ($r{live_head} eq $r{clone_main}) {
        $r{state} = 'same';
        return \%r;
    }
    my ($arc) = $git->($clone, 'merge-base', '--is-ancestor', $r{live_head}, $r{clone_main});
    if ($arc == 0) {
        $r{state} = 'ahead';
        my ($grc, $gout) = $git->($clone, 'log', '--format=%H%x09%s', "$r{live_head}..$r{clone_main}");
        if ($grc == 0) {
            for my $l (split /\r?\n/, $gout // '') {
                my ($sha, $subject) = split /\t/, $l, 2;
                push @{ $r{commits} }, { sha => $sha, subject => $subject // '' } if defined $sha && length $sha;
            }
        }
        return \%r;
    }
    $r{state} = 'live_has_own';
    $r{fix} = 'bring them into the dev clone, then back up again: git -C ' . git_path($clone)
            . ' pull --no-rebase ' . git_path($live) . ' main';
    return \%r;
}

# The one way to promote: the dev clone's own scripts/promote.pl, the only
# thing that writes the live install, told exactly which checkouts and home
# it is working on. keep_keys => [...] are settings units the operator
# answered "skip" this run: promote.pl leaves them as ~/.claude has them
# (--keep-key). A list for a list-form spawn.
sub promote_argv {
    my (%a) = @_;
    my ($clone, $live, $home) = @a{qw(dev_clone live_root home)};
    my @argv = ($a{perl} // $^X, "$clone/scripts/promote.pl", '--clone', $clone, '--live', $live);
    push @argv, '--home', $home if defined $home && length $home;
    push @argv, map { ('--keep-key', $_) } grep { defined && length } @{ $a{keep_keys} // [] };
    return @argv;
}

# promote_outcome(exit => N, output => TEXT, live_head_after => SHA, target => SHA)
# -> { ok, moved, refusals => [lines], reason }
#
# What a promote.pl run means for the caller. Exit 0 is success. Exit 1 is a
# payload file promote.pl refused (a hand-edited ~/.claude/CLAUDE.md, a
# symlink to some other file) AFTER its fast-forward: when the live install
# did reach the target, the promotion happened and the caller carries on,
# with the refusal lines kept for the report. Anything else -- exit 2 (the
# merge refused or failed), a live install that did not move -- is a stop.
sub promote_outcome {
    my (%a) = @_;
    my $exit  = $a{exit} // -1;
    my $moved = (defined $a{live_head_after} && defined $a{target} && $a{live_head_after} eq $a{target}) ? 1 : 0;
    my @refusals;
    my $in = 0;
    for my $l (split /\r?\n/, $a{output} // '') {
        if ($l =~ /^(?:claude-md|settings|marketplaces): (?:refused|error)\b/) { push @refusals, $l; $in = 1; next; }
        if ($in && $l =~ /^\s/) { push @refusals, $l; next; }
        $in = 0;
    }
    return { ok => 1, moved => $moved, refusals => \@refusals, reason => undef } if $exit == 0;
    return { ok => 1, moved => 1, refusals => \@refusals,
             reason => 'promote.pl refused a payload file after its fast-forward (exit 1)' } if $exit == 1 && $moved;
    return { ok => 0, moved => $moved, refusals => \@refusals,
             reason => $exit < 0 ? 'promote.pl could not be started' : "promote.pl exited $exit" };
}

1;
