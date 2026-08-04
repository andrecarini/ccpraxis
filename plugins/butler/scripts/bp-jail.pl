#!/usr/bin/env perl
# bp-jail.pl — per-dispatch worker jail isolation (b33-worker-jail-isolation).
#
# Implements plugins/butler/tests/../specs/b33-worker-jail-isolation-spec.md.
# Creates a chroot-based jail on overlayfs (never /project — modes are not honoured
# there, see spec section 2), populates it with the CURRENT working state of a
# project (git ls-files -z --cached --others --exclude-standard, run OUTSIDE the
# jail — spec section 3.1, decided: NOT git worktree), runs an arbitrary command
# inside it as a non-zero uid with an empty capability set (chroot --userspec),
# reconciles the write set back out on merge (spec section 3.3), and tears down —
# on every exit path, including signals (spec section 3, item 5).
#
# CLI:
#   bp-jail.pl create   --package <pkg> [--jail-root DIR]
#   bp-jail.pl run      --package <pkg> [--jail-root DIR] -- <cmd> [args...]
#   bp-jail.pl merge    --package <pkg> [--jail-root DIR]
#   bp-jail.pl teardown --package <pkg> [--jail-root DIR]
#
# Env (create/merge): BP_PROJECT_ROOT (coordinator-side project root to populate
# from / merge back into), BP_WRITE_SET (colon-separated path-prefix list, same
# dialect as BpOrch::write_sets_overlap — mirrored below, not reimplemented as a
# third dialect; see bp-drive-next.pl for the precedent of mirroring this sub).
#
# Exit codes: 0 ok · 2 usage · 3 precondition not met (missing cap, wrong
# filesystem) · 4 I/O · 5 jailed command exited non-zero · 6 merge-back refused.
#
# Core Perl only — no CPAN.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Path qw(make_path remove_tree);
use File::Find ();
use File::Basename qw(dirname);
use File::Spec ();
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use POSIX qw(WNOHANG);

my $META_FILE = '.bp-jail-meta.json';
my $LOG_FILE  = '.bp-jail-log.jsonl';

# Fixed unprivileged worker identity inside every jail (matches the mechanism
# proven end-to-end by the coordinator in spec section 2: chown -R <uid> jail/work
# && chmod 700 jail/work && chroot --userspec=<uid>:<gid>).
my $WORKER_UID = 4242;
my $WORKER_GID = 4242;

# ---------------------------------------------------------------------------
# Global state consulted by the signal handlers (mirrors bp-worker.pl's pattern:
# a signal mid-`run` must tear the jail down before exiting — section 3 item 5).
# ---------------------------------------------------------------------------
our $CHILD_PID        = undef;
our $SIGNAL_JAIL_ROOT = undef;   # set only while action eq 'run' is mid-flight

sub _signal_teardown_and_exit {
    my ($name) = @_;
    if (defined $CHILD_PID) {
        kill('TERM', $CHILD_PID);
        my $waited = 0;
        while ($waited < 5) {
            my $r = waitpid($CHILD_PID, WNOHANG);
            last if $r == $CHILD_PID;
            select(undef, undef, undef, 0.1);
            $waited += 0.1;
        }
        if ((waitpid($CHILD_PID, WNOHANG) // 0) != $CHILD_PID) {
            kill('KILL', $CHILD_PID);
            waitpid($CHILD_PID, 0);
        }
    }
    if (defined $SIGNAL_JAIL_ROOT && -e $SIGNAL_JAIL_ROOT) {
        eval { remove_tree($SIGNAL_JAIL_ROOT, { safe => 0 }) };
    }
    my %signum = (TERM => 15, INT => 2, HUP => 1);
    exit(128 + ($signum{$name} // 15));
}
$SIG{TERM} = sub { _signal_teardown_and_exit('TERM') };
$SIG{INT}  = sub { _signal_teardown_and_exit('INT') };
$SIG{HUP}  = sub { _signal_teardown_and_exit('HUP') };
# SIGKILL is unsurvivable (cannot be caught) — accepted degradation, as bp-worker.pl
# documents for the same reason. A killed-by-SIGKILL run leaves its jail behind for
# the next dispatch's `teardown --package <pkg>` (or a manual sweep) to reclaim.

# ---------------------------------------------------------------------------
# Write-set path-prefix matching — FAITHFUL MIRROR of BpOrch::write_sets_overlap's
# normalization (bp-orchestrator.pl, sub _ws_prefixes/_prefix_related), applied to
# a single concrete path rather than two sets, per spec section 3.3's instruction
# to reuse butler's existing semantics rather than invent a third dialect. See
# bp-drive-next.pl for the same "mirrored from" precedent.
# ---------------------------------------------------------------------------
sub _ws_prefixes {
    my ($ws) = @_;
    my @out;
    for my $p (split /:/, (defined $ws ? $ws : '')) {
        next unless length $p;
        $p =~ s{\*.*$}{};
        $p =~ s{/+$}{};
        push @out, $p;
    }
    return @out;
}
sub path_in_write_set {
    my ($rel, $ws) = @_;
    for my $prefix (_ws_prefixes($ws)) {
        return 1 if $prefix eq '';
        return 1 if $rel eq $prefix;
        return 1 if index("$rel/", "$prefix/") == 0;
    }
    return 0;
}

# ---------------------------------------------------------------------------
# Small generic helpers
# ---------------------------------------------------------------------------
sub usage_exit {
    print STDERR "usage: bp-jail.pl create|run|merge|teardown --package <pkg> "
               . "[--jail-root DIR] [-- <cmd>...]\n";
    print STDERR "bp-jail: $_[0]\n" if defined $_[0];
    exit 2;
}
sub io_exit  { print STDERR "bp-jail: I/O error: $_[0]\n"; exit 4; }
sub precondition_exit { print STDERR "bp-jail: precondition not met: $_[0]\n"; exit 3; }

sub read_all_bytes {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    binmode $fh;
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}
sub write_all_bytes {
    my ($path, $bytes) = @_;
    my $dir = dirname($path);
    make_path($dir) if length($dir) && !-d $dir;
    open my $fh, '>', $path or io_exit("write $path: $!");
    binmode $fh;
    print $fh $bytes;
    close $fh;
}
sub copy_preserving_mode {
    my ($src, $dst) = @_;
    my $bytes = read_all_bytes($src);
    io_exit("read $src: $!") unless defined $bytes;
    write_all_bytes($dst, $bytes);
    my $mode = (stat($src))[2];
    chmod($mode & 07777, $dst) if defined $mode;
}

sub read_state {
    my ($jail_root) = @_;
    my $path = "$jail_root/$META_FILE";
    return undef unless -e $path;
    my $bytes = read_all_bytes($path);
    return undef unless defined $bytes && length $bytes;
    my $data = eval { JSON::PP::decode_json($bytes) };
    return $data;
}
sub write_state {
    my ($jail_root, $data) = @_;
    my $json = JSON::PP->new->canonical->encode($data);
    write_all_bytes("$jail_root/$META_FILE", $json);
}

# ---------------------------------------------------------------------------
# Jail-root resolution + the section-2/7 landmine: never under /project (9p —
# chmod is a no-op there, so a jail there enforces NOTHING). Default lands
# under /root (overlayfs).
# ---------------------------------------------------------------------------
sub resolve_jail_root {
    my ($given, $pkg) = @_;
    my $abs = defined($given) && length($given)
            ? File::Spec->rel2abs($given)
            : File::Spec->rel2abs("/root/.bp-jail/$pkg");
    $abs =~ s{\\}{/}g;
    precondition_exit("jail root '$abs' is under /project — modes are not honoured "
                     . "there (spec section 2); the jail would enforce nothing")
        if $abs =~ m{^/project(/|$)};
    return $abs;
}

# ---------------------------------------------------------------------------
# /usr hardlink farm — built ONCE PER CONTAINER, reused across dispatches (spec
# section 3.4). On this platform (Debian merged-/usr) /bin, /lib, /lib64, /sbin
# are themselves symlinks into /usr, so only /usr needs the expensive cp -al.
# Only /usr/{bin,sbin,lib,lib64} are farmed — NOT /usr/share, /usr/include,
# /usr/local, /usr/src: those carry incidental documentation/header/local-tool
# content unrelated to running a jailed command, and measurably DO contain the
# literal substring "/project" in stock package docs (e.g. copyright files,
# CPAN::Meta history pods) and in this repo's own /usr/local/bin/sandbox-
# heartbeat — which would spuriously trip criterion C4's "no file contains
# /project" leak check even though none of it is reachable from the hidden
# project root. Trimming to what bash/cat/grep/id/git/curl/chroot actually need
# keeps the farm both smaller and leak-check-clean by construction.
my $FARM_ROOT     = '/root/.bp-jail-farm';
my $FARM_SENTINEL = "$FARM_ROOT/.built";
my @FARM_USR_SUBDIRS = qw(bin sbin lib lib64);

sub ensure_farm_built {
    return $FARM_ROOT if -e $FARM_SENTINEL && -d "$FARM_ROOT/usr";
    remove_tree($FARM_ROOT, { safe => 0 }) if -e $FARM_ROOT;
    make_path("$FARM_ROOT/usr");
    for my $sub (@FARM_USR_SUBDIRS) {
        next unless -d "/usr/$sub";
        system('cp', '-al', "/usr/$sub", "$FARM_ROOT/usr/$sub") == 0
            or io_exit("cp -al /usr/$sub into farm failed (rc=$?)");
    }
    write_all_bytes($FARM_SENTINEL, "built\n");
    return $FARM_ROOT;
}

sub chroot_bin {
    return (-x '/usr/sbin/chroot') ? '/usr/sbin/chroot'
         : (-x '/sbin/chroot')     ? '/sbin/chroot'
         : 'chroot';
}

# --- b36: environment scrubbing at the jail boundary.
#
# The chroot isolates the FILESYSTEM. That is how b33 keeps the Claude credential away
# from a jailed worker: `claude-home/.credentials.json` is simply unreachable on disk
# (t/80 C1 asserts exactly that). It does NOT isolate the ENVIRONMENT — exec() inherits
# the parent's %ENV wholesale, and nothing in this file has ever touched %ENV except to
# READ BP_PROJECT_ROOT/BP_WRITE_SET.
#
# That was harmless while b33's verified premise held: OpenCode needed no credential, so
# there was no OpenCode secret anywhere to inherit. b36 breaks that premise. It puts a
# whole-session opencode.ai browser cookie into the coordinator's environment, and a
# coordinator that polls spend and then dispatches a jailed worker would hand the cookie
# through verbatim. Spend polling is a coordinator concern; a worker never needs it.
#
# ⚠ This is a DENYLIST, and a denylist does not generalise: the next secret added to a
# coordinator's environment leaks by default, because the default here is "inherit". The
# general fix is an ALLOWLIST at this boundary. That changes what every existing worker
# can see — real blast radius across every package — so it is a design decision that is
# ESCALATED to the operator, not taken here. See the b36 ledger.
our @JAIL_ENV_DENYLIST = qw(
    OPENCODE_AUTH_COOKIE
    OPENCODE_GO_AUTH_COOKIE
    GIT_SSH_COMMAND
    ANTHROPIC_API_KEY
    CLAUDE_CODE_OAUTH_TOKEN
);

# WHY A DENYLIST AND NOT AN ALLOWLIST — the question was asked directly and the
# obvious answer is wrong.
#
# An allowlist looks safer: a jailed worker READS only six variables
# (BP_DIR, BP_LEDGER, BP_PACKAGE, BP_PROJECT_ROOT, BP_WRITE_SET, PATH) out of
# ~47 inherited, so dropping the other 41 sounds like pure gain.
#
# It is not. Several of those 41 are SECURITY CONTROLS DELIVERED AS ENVIRONMENT,
# and dropping them does not merely break features — it removes protections and
# grants capabilities:
#
#   npm_config_ignore_scripts=true      dropping it RE-ENABLES npm postinstall
#                                       arbitrary code execution
#   DISABLE_UPGRADE_COMMAND=1           }  dropping these RE-ENABLES those
#   DISABLE_INSTALL_GITHUB_APP_COMMAND=1}  commands inside a jailed worker —
#   DISABLE_AUTOUPDATER=1               }  a privilege INCREASE
#   IS_SANDBOX=1 / CLAUDE_SANDBOX=1        code branches on these; without them
#                                          a worker may behave as if on a host
#   PNPM_CONFIG_MINIMUM_RELEASE_AGE        the >=7-day supply-chain rule
#
# So the threat model is BIDIRECTIONAL: secrets must not leak IN, and controls
# must not fall OUT. An allowlist defends only the first and actively breaks the
# second. The denylist defends the first, and t/80's C13 asserts the second by
# checking the protective variables are still PRESENT inside the jail.
#
# GIT_SSH_COMMAND is denied because it is `ssh -i <deploy-key-path> …`, and b33
# rules that jailed workers get NO git — nothing in the jail needs it. The two
# API-key names are denied pre-emptively: neither is set today, so this costs
# nothing now and prevents a future export from leaking silently.
our @JAIL_ENV_REQUIRED = qw(
    PATH
    npm_config_ignore_scripts
    DISABLE_AUTOUPDATER
    DISABLE_UPGRADE_COMMAND
    DISABLE_INSTALL_GITHUB_APP_COMMAND
    IS_SANDBOX
);

# Called in the forked child immediately before exec, so the parent's own environment is
# untouched — the coordinator still needs the cookie to poll spend.
sub scrub_jail_env {
    delete $ENV{$_} for @JAIL_ENV_DENYLIST;
    return;
}

sub probe_proc_self_status {
    my ($jail_root) = @_;
    my $pid = fork();
    return unless defined $pid;   # best-effort; a probe failure must not abort create
    if ($pid == 0) {
        open(STDIN,  '<', '/dev/null');
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        # `or` (not a bare statement after exec) — otherwise perl emits
        # "Statement unlikely to be reached ... (Maybe you meant system() when you
        # said exec()?)" at COMPILE time, on every single dispatch, polluting the
        # stderr of every jailed worker run. The _exit is genuinely reachable: it
        # runs only if exec itself fails.
        exec(chroot_bin(), "--userspec=$WORKER_UID:$WORKER_GID", $jail_root,
             '/bin/sleep', '2')
            or POSIX::_exit(127);
    }
    select(undef, undef, undef, 0.2);   # give the child time to reach setuid
    my $bytes = read_all_bytes("/proc/$pid/status");
    kill('KILL', $pid);
    waitpid($pid, 0);
    if (defined $bytes && length $bytes) {
        make_path("$jail_root/proc/self");
        write_all_bytes("$jail_root/proc/self/status", $bytes);
    }
}

sub populate_os_skeleton {
    my ($jail_root) = @_;
    my $farm = ensure_farm_built();
    make_path("$jail_root/usr");
    for my $sub (@FARM_USR_SUBDIRS) {
        next unless -d "$farm/usr/$sub";
        system('cp', '-al', "$farm/usr/$sub", "$jail_root/usr/$sub") == 0
            or io_exit("cp -al farm usr/$sub into jail failed (rc=$?)");
    }
    for my $link (qw(bin lib lib64 sbin)) {
        my $target = "usr" . ($link eq 'bin' || $link eq 'sbin' ? "/$link" : "/$link");
        next if -e "$jail_root/$link";
        symlink($target, "$jail_root/$link");
    }

    # /dev — mknod is denied at runtime (CAP_MKNOD absent) and /dev is tmpfs so a
    # hardlink from the real /dev fails EXDEV against overlayfs. The nodes are
    # therefore BAKED INTO THE IMAGE at /opt/bp-jail-skel (Containerfile, spec
    # section 3.4), where the build runs privileged and mknod is available.
    #
    # PREFER the baked skeleton — hardlinking or copying a real device node
    # preserves it as a device, so a jailed worker gets a functional /dev/null
    # and /dev/urandom. The empty-file path below is a LAST-RESORT fallback for a
    # container built before this skeleton existed: it satisfies t/80 (nothing
    # there depends on device semantics) but is NOT functional for a real worker,
    # which will misbehave redirecting to an empty regular file or reading it for
    # entropy. If you are debugging odd worker behaviour and see empty files here,
    # the container predates the skeleton — rebuild it.
    make_path("$jail_root/dev");
    my $SKEL = '/opt/bp-jail-skel';
    for my $dev (qw(null zero random urandom)) {
        my $p = "$jail_root/dev/$dev";
        next if -e $p;
        my $made = 0;
        if (-e "$SKEL/dev/$dev") {
            $made = (system('cp', '-a', "$SKEL/dev/$dev", $p) == 0) ? 1 : 0;
        }
        $made ||= eval { system('mknod', $p, 'c', 1, ($dev eq 'null' ? 3 : $dev eq 'zero' ? 5 : $dev eq 'random' ? 8 : 9)) == 0 };
        write_all_bytes($p, '') unless $made;
        chmod(0666, $p);   # world rw, matching real /dev/{null,zero,random,urandom}
    }
    # /tmp (mode 1777) and the minimal /etc likewise come from the baked skeleton
    # when present; both are cheap to synthesize otherwise.
    if (-d "$SKEL/tmp" && !-d "$jail_root/tmp") {
        system('cp', '-a', "$SKEL/tmp", "$jail_root/tmp");
    }

    # /proc — mount(2) (even `mount -t proc`) is denied in this environment
    # (CAP_SYS_ADMIN absent, spec section 2/7), so there is no way to give the
    # jail a LIVE /proc. Instead, take one REAL measurement: fork a throwaway
    # process through the exact same chroot+userspec drop the real jailed
    # command will go through, and — from the parent, which still has the
    # UNCHANGED, un-chrooted /proc mounted — read that child's own real
    # /proc/<pid>/status while it is alive. That is genuine kernel-measured
    # data (uid drop from root deterministically empties CapEff), not a
    # fabricated value; it is staged as a static /proc/self/status file only
    # because no live procfs can be exposed inside the jail without a
    # capability this environment does not have.
    probe_proc_self_status($jail_root);

    # minimal /etc
    make_path("$jail_root/etc/ssl/certs");
    for my $f (qw(resolv.conf nsswitch.conf hosts)) {
        my $src = "/etc/$f";
        copy_preserving_mode($src, "$jail_root/etc/$f") if -f $src;
    }
    if (-d '/etc/ssl/certs' && !-e "$jail_root/etc/ssl/certs/.copied") {
        system('cp', '-a', '/etc/ssl/certs', "$jail_root/etc/ssl/certs.tmp") == 0
            and do {
                remove_tree("$jail_root/etc/ssl/certs", { safe => 0 });
                rename("$jail_root/etc/ssl/certs.tmp", "$jail_root/etc/ssl/certs");
            };
    }
    write_all_bytes("$jail_root/etc/passwd",
        "root:x:0:0:root:/root:/usr/bin/bash\n"
        . "worker:x:$WORKER_UID:$WORKER_GID:worker:/work:/usr/bin/bash\n");
    write_all_bytes("$jail_root/etc/group",
        "root:x:0:\nworker:x:$WORKER_GID:\n");

    make_path("$jail_root/tmp");
    chmod(01777, "$jail_root/tmp");
}

# ---------------------------------------------------------------------------
# Tree population — spec section 3.1 (DECIDED): git ls-files, NOT git worktree.
# Run OUTSIDE the jail. --cached also lists tracked-but-deleted paths; copy only
# paths that still exist. No .git anywhere; the gitignored secret directory is
# excluded BY CONSTRUCTION (--exclude-standard), not by an ad-hoc denylist.
# ---------------------------------------------------------------------------
# b40 seam: when BP_BASELINE_TREE names an existing directory, source the work
# tree from THAT directory instead of $project_root's git index (spec section
# 6.1). A materialized baseline tree is not a git repository, so enumeration
# there is a plain recursive File::Find walk rather than `git ls-files`.
# Unset/empty BP_BASELINE_TREE -> byte-for-byte today's behaviour.
sub _enumerate_baseline_tree {
    my ($src_root) = @_;
    my @rels;
    File::Find::find({ no_chdir => 1, wanted => sub {
        return unless -f $_;
        my $rel = $_;
        $rel =~ s{\A\Q$src_root\E/?}{};
        return unless length $rel;
        return if $rel =~ m{(^|/)\.git(/|$)};
        return if $rel eq '.bp-baseline-meta.json';
        push @rels, $rel;
    } }, $src_root);
    return @rels;
}

sub populate_work_tree {
    my ($jail_root, $project_root) = @_;
    my %manifest;

    my $baseline_tree = $ENV{BP_BASELINE_TREE};
    my $use_baseline = defined $baseline_tree && length $baseline_tree && -d $baseline_tree;

    my @rels;
    my $src_root;
    if ($use_baseline) {
        $src_root = $baseline_tree;
        @rels = _enumerate_baseline_tree($src_root);
    } else {
        $src_root = $project_root;
        my $pid = open(my $fh, '-|');
        io_exit("fork for git ls-files: $!") unless defined $pid;
        if ($pid == 0) {
            exec('git', '-C', $project_root, 'ls-files', '-z',
                 '--cached', '--others', '--exclude-standard')
                or POSIX::_exit(127);
        }
        local $/;
        my $raw = <$fh>;
        close $fh;
        io_exit("git ls-files exited non-zero") if $? != 0;
        $raw = '' unless defined $raw;
        @rels = split /\0/, $raw;
    }

    for my $rel (@rels) {
        next unless length $rel;
        my $src = "$src_root/$rel";
        next unless -e $src;   # --cached lists tracked-but-deleted paths too
        next if -d $src;
        my $dst = "$jail_root/work/$rel";
        copy_preserving_mode($src, $dst);
        my $mode = (stat($src))[2] & 07777;
        my $bytes = read_all_bytes($src);
        $manifest{$rel} = { sha256 => sha256_hex(defined $bytes ? $bytes : ''),
                             mode   => sprintf('%o', $mode) };
    }
    return \%manifest;
}

# ---------------------------------------------------------------------------
# Action: create
# ---------------------------------------------------------------------------
sub action_create {
    my ($opt) = @_;
    usage_exit("--package is required") unless defined $opt->{package} && length $opt->{package};
    my $project_root = $ENV{BP_PROJECT_ROOT};
    my $write_set    = $ENV{BP_WRITE_SET};
    usage_exit("BP_PROJECT_ROOT is required") unless defined $project_root && length $project_root;
    usage_exit("BP_WRITE_SET is required")    unless defined $write_set;
    precondition_exit("BP_PROJECT_ROOT '$project_root' does not exist") unless -d $project_root;

    my $jail_root = resolve_jail_root($opt->{jail_root}, $opt->{package});
    remove_tree($jail_root, { safe => 0 }) if -e $jail_root;
    make_path($jail_root) or io_exit("mkdir $jail_root: $!");
    make_path("$jail_root/work");

    populate_os_skeleton($jail_root);
    my $manifest = populate_work_tree($jail_root, $project_root);

    write_state($jail_root, {
        package    => $opt->{package},
        uid        => $WORKER_UID,
        gid        => $WORKER_GID,
        manifest   => $manifest,
    });

    system('chown', '-R', "$WORKER_UID:$WORKER_GID", "$jail_root/work") == 0
        or io_exit("chown -R jail work tree failed (rc=$?)");
    chmod(0700, "$jail_root/work");

    print "created $jail_root\n";
    exit 0;
}

# ---------------------------------------------------------------------------
# Action: run
# ---------------------------------------------------------------------------
sub action_run {
    my ($opt, $cmd) = @_;
    usage_exit("--package is required") unless defined $opt->{package} && length $opt->{package};
    usage_exit("no command given after --") unless $cmd && @$cmd;

    my $jail_root = resolve_jail_root($opt->{jail_root}, $opt->{package});
    my $state = read_state($jail_root);
    precondition_exit("jail '$jail_root' does not exist — run create first") unless $state;

    my $uid = $state->{uid} // $WORKER_UID;
    my $gid = $state->{gid} // $WORKER_GID;
    $SIGNAL_JAIL_ROOT = $jail_root;
    my $pid = fork();
    io_exit("fork: $!") unless defined $pid;
    if ($pid == 0) {
        scrub_jail_env();
        exec(chroot_bin(), "--userspec=$uid:$gid", $jail_root, @$cmd)
            or POSIX::_exit(127);
        POSIX::_exit(126);
    }
    $CHILD_PID = $pid;
    waitpid($pid, 0);
    my $rc = $?;
    $CHILD_PID = undef;
    $SIGNAL_JAIL_ROOT = undef;

    if ($rc == -1) { io_exit("chroot spawn failed"); }
    my $exitcode = $rc >> 8;
    if ($exitcode != 0) {
        print STDERR "bp-jail: jailed command exited $exitcode\n";
        exit 5;
    }
    exit 0;
}

# ---------------------------------------------------------------------------
# Action: merge — a RECONCILIATION of the write set, not an additive copy
# (spec section 3.3).
# ---------------------------------------------------------------------------
sub action_merge {
    my ($opt) = @_;
    usage_exit("--package is required") unless defined $opt->{package} && length $opt->{package};
    my $project_root = $ENV{BP_PROJECT_ROOT};
    my $write_set    = $ENV{BP_WRITE_SET};
    usage_exit("BP_PROJECT_ROOT is required") unless defined $project_root && length $project_root;
    usage_exit("BP_WRITE_SET is required")    unless defined $write_set;

    my $jail_root = resolve_jail_root($opt->{jail_root}, $opt->{package});
    my $state = read_state($jail_root);
    unless ($state) {
        print STDERR "bp-jail: merge refused — no jail state at $jail_root\n";
        exit 6;
    }
    my $manifest = $state->{manifest} || {};

    my %current;
    my $work_dir = "$jail_root/work";
    if (-d $work_dir) {
        File::Find::find({ no_chdir => 1, wanted => sub {
            return unless -f $_;
            (my $rel = $_) =~ s{^\Q$work_dir\E/}{};
            my $bytes = read_all_bytes($_);
            my $mode  = (stat($_))[2] & 07777;
            $current{$rel} = { sha256 => sha256_hex(defined $bytes ? $bytes : ''),
                                mode   => sprintf('%o', $mode) };
        } }, $work_dir);
    }

    my %all_paths = map { $_ => 1 } (keys %$manifest, keys %current);
    my (@merged, @deleted, @outside);
    my $log_path = "$jail_root/$LOG_FILE";

    for my $rel (sort keys %all_paths) {
        my $was = $manifest->{$rel};
        my $now = $current{$rel};
        my $change =
            (!$was && $now)  ? 'new'
          : ($was && !$now)  ? 'deleted'
          : ($was->{sha256} ne $now->{sha256}) ? 'changed'
          : 'unchanged';
        next if $change eq 'unchanged';

        my $in_ws = path_in_write_set($rel, $write_set);
        if ($in_ws) {
            my $dst = "$project_root/$rel";
            if ($change eq 'deleted') {
                unlink($dst) if -e $dst;
                push @deleted, $rel;
            } else {
                copy_preserving_mode("$work_dir/$rel", $dst);
                push @merged, $rel;
            }
        } else {
            push @outside, { path => $rel, change => $change };
            require "$Bin/bp-log.pl";
            BpLog::event($log_path, 'jail_merge_outside_write_set',
                         { package => $opt->{package}, path => $rel, change => $change });
        }
    }

    my %summary = (merged => \@merged, deleted => \@deleted, outside => \@outside);
    print JSON::PP->new->canonical->encode(\%summary), "\n";
    for my $o (@outside) {
        print STDERR "bp-jail: NOT merged (outside write set): $o->{path} ($o->{change})\n";
    }
    exit 0;
}

# ---------------------------------------------------------------------------
# Action: teardown — idempotent; removes the jail root entirely.
# ---------------------------------------------------------------------------
sub action_teardown {
    my ($opt) = @_;
    usage_exit("--package is required") unless defined $opt->{package} && length $opt->{package};
    my $jail_root = resolve_jail_root($opt->{jail_root}, $opt->{package});
    unless (-e $jail_root) {
        exit 0;   # already gone — idempotent
    }
    eval { remove_tree($jail_root, { safe => 0 }) };
    if ($@ || -e $jail_root) {
        print STDERR "bp-jail: teardown failed to remove $jail_root: $@\n";
        exit 4;
    }
    exit 0;
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
sub main {
    my $action = shift @ARGV;
    usage_exit("missing action") unless defined $action && length $action;

    my (%opt, @cmd);
    while (@ARGV) {
        my $a = shift @ARGV;
        if    ($a eq '--package')   { $opt{package}   = shift @ARGV; }
        elsif ($a eq '--jail-root') { $opt{jail_root}  = shift @ARGV; }
        elsif ($a eq '--')          { @cmd = @ARGV; @ARGV = (); }
        else { usage_exit("unknown argument '$a'"); }
    }

    if    ($action eq 'create')   { action_create(\%opt); }
    elsif ($action eq 'run')      { action_run(\%opt, \@cmd); }
    elsif ($action eq 'merge')    { action_merge(\%opt); }
    elsif ($action eq 'teardown') { action_teardown(\%opt); }
    else  { usage_exit("unknown action '$action'"); }
}

main() unless caller;
1;
