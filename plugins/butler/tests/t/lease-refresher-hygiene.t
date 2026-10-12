#!/usr/bin/env perl
# platform: windows
#
# ORACLE for blueprint package 04-refresher-hygiene (host-wake-and-suspend),
# derived ONLY from
# .ccpraxis-local-data/blueprints/host-wake-and-suspend/specs/04-refresher-hygiene-spec.md
# (22 ACs) plus the ledger's Decision 17 write-set. NOT derived from the
# implementation: at the time this file is written, BpContinuityLease.pm has
# no active_reason/code_snapshot/code_changed/live_script_path/is_live_script/
# lease_log/handover machinery, and bp-keepawake.pl has no stop_helper/
# winpid_of/self_winpid/owner_desc_clean/replace. Every integration assertion
# below is expected to go red for THAT reason -- missing behavior -- not a
# scaffolding bug in this file.
#
# ISOLATION (spec 4, harness requirements). Every process this file spawns
# runs against a TEMP-rooted "live" copy of the scripts under test, never the
# real ~/.claude install and never this session's own continuity refresher or
# keep-awake helper (which hold the real machine's wake-lock and must never be
# touched). CCPRAXIS_LEASE_LIVE_SCRIPT (the spec's test seam) always names a
# path under that copy. Cleanup is keyed ONLY on pids/pidfiles this file
# itself created, in END and SIG INT/TERM handlers, per the three-step order
# the spec's harness section states.
#
# PID NAMESPACES (CLAUDE.md). A refresher this file forks is a perl child in
# OUR msys pid space -- kill()/waitpid() on it directly is correct. A
# keep-awake.ps1 helper (or a throwaway owner) is a NATIVE Windows process
# reachable only by WINPID, read via /proc/<msys-pid>/winpid, verified with
# `tasklist` and killed with `taskkill`, never perl's kill().
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Spec;
use Cwd ();
use Fcntl qw(:flock);
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep time);

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

# Captured BEFORE anything in this file ever touches HOME/USERPROFILE, for
# AC-17(c)'s read-only check of the operator's REAL registry lease.log. This
# process's own %ENV is never overridden below -- only forked children's are
# (post-fork, pre-exec) -- so this stays valid for the whole file.
my $REAL_HOME = $ENV{HOME} || $ENV{USERPROFILE};

(my $REPO_BUTLER_SCRIPTS = "$Bin/../../scripts") =~ s{\\}{/}g;
(my $REPO_SANDBOX_PS1    = "$Bin/../../../sandbox/scripts/keep-awake.ps1") =~ s{\\}{/}g;
my $REPO_MODULE      = "$REPO_BUTLER_SCRIPTS/BpContinuityLease.pm";
my $REPO_KEEPAWAKE_PL = "$REPO_BUTLER_SCRIPTS/bp-keepawake.pl";

ok(-f $REPO_MODULE, "sanity: $REPO_MODULE exists") or BAIL_OUT('module missing');
ok(-f $REPO_KEEPAWAKE_PL, "sanity: $REPO_KEEPAWAKE_PL exists") or BAIL_OUT('bp-keepawake.pl missing');
ok(-f $REPO_SANDBOX_PS1, "sanity: $REPO_SANDBOX_PS1 exists") or BAIL_OUT('keep-awake.ps1 missing');

my $WIN_TMP = $ENV{TEMP} || $ENV{TMP} || 'C:/Windows/Temp';
my $TICK = 2;   # CCPRAXIS_CONTINUITY_LEASE_TICK for every spawned refresher

# ---------------------------------------------------------------------------
# recursive copy -- File::Copy::Recursive is not core, so a small copier.
# ---------------------------------------------------------------------------
sub copy_tree {
    my ($src, $dst) = @_;
    make_path($dst) unless -d $dst;
    opendir(my $dh, $src) or die "opendir $src: $!";
    for my $entry (readdir $dh) {
        next if $entry eq '.' || $entry eq '..';
        my $s = "$src/$entry";
        my $d = "$dst/$entry";
        if (-d $s) { copy_tree($s, $d) }
        else       { copy($s, $d) or die "copy $s -> $d: $!" }
    }
    closedir $dh;
    return;
}

my $R = tempdir(DIR => $WIN_TMP, CLEANUP => 1);
(my $R_FWD = $R) =~ s{\\}{/}g;

copy_tree("$REPO_BUTLER_SCRIPTS", "$R_FWD/live/plugins/butler/scripts");
make_path("$R_FWD/live/plugins/sandbox/scripts");
copy($REPO_SANDBOX_PS1, "$R_FWD/live/plugins/sandbox/scripts/keep-awake.ps1")
    or die "copy keep-awake.ps1: $!";

my $LIVE_MODULE = "$R_FWD/live/plugins/butler/scripts/BpContinuityLease.pm";
ok(-f $LIVE_MODULE, 'harness: the live-copy module exists under $R');

# ===========================================================================
# Cleanup bookkeeping -- step (2)/(3) of the spec's harness requirement.
# Never a blind sweep: every entry below is something THIS FILE created.
# ===========================================================================
my @REFRESHER_MSYS_PIDS;   # forked or read from a lease.pid this file wrote
my %REFRESHER_WINPID_SEEN; # msys pid -> first-seen winpid (belt-and-suspenders)
my @HELPER_WINPIDS;        # every helper/owner winpid ever read
my %HELPER_WINPID_ROOT;    # winpid -> scratch-root substring its cmdline must contain
my @PENDING_PIDFILES;      # [pidfile, root] pairs -- re-checked in END (S4) so a
                            # cold-start helper that our bounded wait never saw
                            # cannot leak a real wake-lock past this process's exit
my @ARMED_FILES;           # every armed/<sid> file this file created
my @LEASE_LOGS;            # every lease.log path this file's groups own

sub _msys_winpid {
    my ($pid) = @_;
    return undef unless defined $pid && $pid =~ /^\d+$/;
    return undef unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    open(my $fh, '<', "/proc/$pid/winpid") or return undef;
    my $line = <$fh>;
    close $fh;
    return undef unless defined $line;
    $line =~ s/\s+//g;
    return ($line =~ /^[1-9]\d*$/) ? $line : undef;
}

sub register_refresher {
    my ($pid) = @_;
    return unless defined $pid;
    push @REFRESHER_MSYS_PIDS, $pid;
    my $w = _msys_winpid($pid);
    $REFRESHER_WINPID_SEEN{$pid} = $w if defined $w && !exists $REFRESHER_WINPID_SEEN{$pid};
    return;
}

sub register_helper_winpid {
    my ($w, $root) = @_;
    return unless defined $w && $w =~ /^\d+$/;
    push @HELPER_WINPIDS, $w;
    $HELPER_WINPID_ROOT{$w} = $root // $R_FWD;
    return;
}

# note_pending_pidfile($pidfile, $root) -- record a pidfile this file created
# BEFORE waiting on it, so END can re-attempt registration even if our own
# bounded wait gave up first (S4: cold PowerShell starts can outlast even a
# 60s wait under heavy host load).
sub note_pending_pidfile {
    my ($pidfile, $root) = @_;
    return unless defined $pidfile;
    push @PENDING_PIDFILES, [ $pidfile, $root // $R_FWD ];
    return;
}

sub tasklist_alive {
    my ($winpid) = @_;
    return 0 unless defined $winpid && $winpid =~ /^\d+$/;
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
    my $out = `tasklist /FI "PID eq $winpid" 2>&1`;
    return 0 unless defined $out;
    return ($out =~ /\b\Q$winpid\E\b/) ? 1 : 0;
}

# process_identity($winpid) -> ($image_name, $commandline) | (undef, undef).
# The ONLY source of truth this file uses to decide whether a winpid is
# something IT started -- never inferred from aliveness alone, because
# Windows reuses pids and this file's own bounded waits can outlive the
# process they were watching.
#
# Get-CimInstance, not wmic (deprecated) -- and [Console]::OutputEncoding=
# UTF8 is load-bearing, not decoration: without it PowerShell writes its
# captured stdout in the console's active codepage, and a path containing a
# non-ASCII byte (this host's home dir, "Andre" with an accented e) comes
# back mangled, silently breaking every command-line identity comparison for
# paths under this account. Same fix as bp-keepawake.pl's
# _production_cmdline_of.
sub process_identity {
    my ($winpid) = @_;
    return (undef, undef) unless defined $winpid && $winpid =~ /^\d+$/;
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
    # List-form open, no shell involved -- same technique as sweep_kill_root
    # and any_process_naming_root. A backtick/qx string here goes through
    # `sh -c "..."`, and $(...) inside that double-quoted string is a SHELL
    # command substitution, not a PowerShell subexpression -- this used to
    # read as "NAME=" / "CMD=" with sh itself failing on ".Name"/".CommandLine"
    # as bogus commands, so this always returned (undef, undef) and every
    # identity-checked kill silently no-op'd.
    my $ps = '[Console]::OutputEncoding=[Text.Encoding]::UTF8; $p = Get-CimInstance Win32_Process -Filter '
           . "'ProcessId=$winpid'"
           . '; if ($p) { "NAME=$($p.Name)"; "CMD=$($p.CommandLine)" }';
    my @cmd = ('powershell.exe', '-NoProfile', '-NonInteractive', '-Command', $ps);
    open(my $fh, '-|', @cmd) or return (undef, undef);
    my $out = do { local $/; <$fh> };
    close $fh;
    return (undef, undef) unless defined $out;
    my ($name) = $out =~ /^NAME=(.*)$/m;
    my ($cmd_out) = $out =~ /^CMD=(.*)$/m;
    for ($name, $cmd_out) { next unless defined; s/\s+$//; s/\r//g }
    return (undef, undef) unless defined $name && length $name;
    return ($name, $cmd_out);
}

# root_forms($root) -> lowercased, forward-slash forms of $root to match a
# process's command line against -- BOTH the form $root was handed in as,
# AND its Cwd::abs_path resolution. These can genuinely differ on Windows: a
# tempdir carved under $WIN_TMP can come back from File::Temp in short (8.3)
# form (e.g. "ANDR~1"), while a command line built via winify()/winify_out()
# (both of which call Cwd::abs_path at spawn time, which resolves through
# the filesystem to the directory entry's real, long-form name) carries the
# long form (e.g. "Andre"). A plain substring check against only $root's
# original spelling misses that process entirely -- observed: a live
# keep-awake.ps1 and its perl parent survived a whole sweep because of
# exactly this mismatch. Checking both forms, rather than trying to convert
# one into the other, is correct regardless of which form either side
# happens to be in.
sub root_forms {
    my ($root) = @_;
    return () unless defined $root && length $root;
    my %seen;
    my @forms;
    for my $r ($root, Cwd::abs_path($root)) {
        next unless defined $r && length $r;
        (my $fwd = $r) =~ s{\\}{/}g;
        $fwd =~ s{^/([a-zA-Z])/}{\u$1:/};
        my $lc = lc($fwd);
        push @forms, $lc unless $seen{$lc}++;
    }
    return @forms;
}

# force_kill_winpid($winpid, $root) -- NEVER kills on aliveness alone. A pid
# is only killed if, right now, tasklist shows it alive AND its image is
# powershell.exe or perl.exe (the only two kinds of process this file ever
# spawns) AND its own command line contains $root, in EITHER short or long
# form (root_forms) -- i.e. it names a path THIS FILE created. $root
# defaults to this file's scratch root $R_FWD. Windows pid reuse means the
# winpid alone never proves identity; this is the only guard, so every call
# site must go through it.
sub force_kill_winpid {
    my ($winpid, $root) = @_;
    return unless defined $winpid && $winpid =~ /^\d+$/;
    return unless tasklist_alive($winpid);
    $root //= $R_FWD;
    my ($img, $cmd) = process_identity($winpid);
    return unless defined $img && $img =~ /^(?:powershell|perl)\.exe$/i;
    return unless defined $cmd && length $cmd;
    (my $cmd_fwd = $cmd) =~ s{\\}{/}g;
    my $cmd_lc = lc($cmd_fwd);
    my @forms = root_forms($root);
    return unless grep { index($cmd_lc, $_) >= 0 } @forms;
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
    system('taskkill', '/F', '/PID', $winpid);
    return;
}

# any_process_naming_root($root) -> 1 if some LIVE powershell.exe/perl.exe
# process's command line names $root, in either short or long form
# (root_forms) -- the same ambiguity force_kill_winpid guards against.
# Queries Windows directly, independently of this file's own bookkeeping, so
# a pid this file failed to track (the exact failure mode this package
# fixes) still shows up.
sub any_process_naming_root {
    my ($root) = @_;
    my @forms = root_forms($root);
    return 0 unless @forms;
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
    my $ps = '[Console]::OutputEncoding=[Text.Encoding]::UTF8; '
           . q{Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -or $_.Name -eq 'perl.exe' } | }
           . q{ForEach-Object { "CMD=$($_.CommandLine)" }};
    my @cmd = ('powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $ps);
    open(my $fh, '-|', @cmd) or return 0;
    my $out = do { local $/; <$fh> };
    close $fh;
    return 0 unless defined $out;
    for my $line (split /\r?\n/, $out) {
        next unless $line =~ /^CMD=(.*)$/;
        (my $cmd_fwd = $1) =~ s{\\}{/}g;
        my $cmd_lc = lc($cmd_fwd);
        for my $f (@forms) { return 1 if index($cmd_lc, $f) >= 0 }
    }
    return 0;
}

# sweep_kill_root($root) -- force-kills EVERY live powershell.exe/perl.exe
# whose command line names $root (short or long form), found by querying
# Windows directly rather than by pid we happen to have tracked. Exists
# because Git-for-Windows perl's fork()+exec() emulation can leave a native
# process alive under a DIFFERENT pid than the one _msys_winpid() reported
# for the msys-level fork -- observed directly: registering and
# force-killing the AC-13 apply() child's own tracked WINPID was not enough
# to reap it. The identity guard is the same as force_kill_winpid (image
# name + command-line substring); this just applies it to every matching
# process instead of one already-known pid.
sub sweep_kill_root {
    my ($root) = @_;
    my @forms = root_forms($root);
    return unless @forms;
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
    my $ps = '[Console]::OutputEncoding=[Text.Encoding]::UTF8; '
           . q{Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -or $_.Name -eq 'perl.exe' } | }
           . q{ForEach-Object { "PID=$($_.ProcessId) CMD=$($_.CommandLine)" }};
    my @cmd = ('powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $ps);
    open(my $fh, '-|', @cmd) or return;
    my $out = do { local $/; <$fh> };
    close $fh;
    return unless defined $out;
    for my $line (split /\r?\n/, $out) {
        next unless $line =~ /^PID=(\d+)\s+CMD=(.*)$/s;
        my ($pid, $cmd) = ($1, $2);
        (my $cmd_fwd = $cmd) =~ s{\\}{/}g;
        my $cmd_lc = lc($cmd_fwd);
        next unless grep { index($cmd_lc, $_) >= 0 } @forms;
        local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
        system('taskkill', '/F', '/T', '/PID', $pid);
    }
    return;
}

# forget_winpid($w) -- drop a winpid from every tracked set the moment this
# file has itself observed it gone. Once dropped, cleanup will never attempt
# to touch that pid number again, so a later reuse by an unrelated process
# is never even considered, let alone killed.
sub forget_winpid {
    my ($w) = @_;
    return unless defined $w && $w =~ /^\d+$/;
    @HELPER_WINPIDS = grep { $_ ne $w } @HELPER_WINPIDS;
    delete $HELPER_WINPID_ROOT{$w};
    for my $pid (keys %REFRESHER_WINPID_SEEN) {
        delete $REFRESHER_WINPID_SEEN{$pid} if defined($REFRESHER_WINPID_SEEN{$pid}) && $REFRESHER_WINPID_SEEN{$pid} eq $w;
    }
    return;
}

sub _cleanup_everything {
    # (1) armed files
    for my $f (@ARMED_FILES) { unlink $f if defined $f && -e $f }
    # (2) refresher msys pids: TERM, wait <=10s, KILL, then taskkill its winpid
    for my $pid (@REFRESHER_MSYS_PIDS) {
        next unless defined $pid;
        local $@;
        eval {
            kill('TERM', $pid);
            my $deadline = time() + 10;
            while (time() < $deadline) {
                last unless kill(0, $pid);
                sleep(0.25);
            }
            if (kill(0, $pid)) {
                diag("_cleanup_everything: pid=$pid still alive 10s after TERM -- forcing KILL");
                kill('KILL', $pid);
            }
            waitpid($pid, WNOHANG);
        };
        my $w = $REFRESHER_WINPID_SEEN{$pid};
        force_kill_winpid($w) if defined $w;
    }
    # (2.5) S4: re-attempt registration for any pidfile whose helper our own
    # bounded wait never saw appear (cold-start slower than the wait), so it
    # is not left untracked -- and therefore un-killed -- at exit.
    for my $entry (@PENDING_PIDFILES) {
        my ($pidfile, $root) = @$entry;
        next unless defined $pidfile && -f $pidfile;
        my $w = read_first_line($pidfile);
        next unless defined $w && $w =~ /^\d+$/;
        register_helper_winpid($w, $root) unless grep { $_ eq $w } @HELPER_WINPIDS;
    }
    # (3) every helper/owner winpid ever seen
    for my $w (@HELPER_WINPIDS) { force_kill_winpid($w, $HELPER_WINPID_ROOT{$w}) }
    # (4) backstop sweep: pid-tracked cleanup above trusts OUR bookkeeping of
    # which pid is which. sweep_kill_root queries Windows directly for every
    # scratch root this file ever used (its own $R_FWD plus every distinct
    # root recorded against a tracked helper), so a process our own
    # bookkeeping lost track of -- a fork()/exec() emulation artifact, a race
    # in a bounded wait -- is still caught by identity (image + cmdline),
    # never by aliveness alone.
    my %roots = ($R_FWD => 1);
    $roots{$_} = 1 for grep { defined } values %HELPER_WINPID_ROOT;
    sweep_kill_root($_) for keys %roots;
    return;
}

END { _cleanup_everything() }
for my $sig (qw(INT TERM)) {
    $SIG{$sig} = sub { _cleanup_everything(); exit(1); };
}

# ---------------------------------------------------------------------------
# generic helpers
# ---------------------------------------------------------------------------
sub slurp {
    my ($p) = @_;
    return '' unless defined $p && -f $p;
    open(my $fh, '<:raw', $p) or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    $c = defined($c) ? $c : '';
    # keep-awake.ps1 writes its log via Add-Content, which is CRLF. A `$`-
    # anchored regex against that text (matching right before \n) sits one
    # byte short of the real end of line -- the stray \r is still there and
    # the match silently never succeeds, forever, even once the feature is
    # implemented. lease.log is perl-written (LF only) and unaffected either
    # way. Same normalisation execution-power-request.t gets for free by
    # opening in text mode instead of :raw.
    $c =~ s/\r\n/\n/g;
    return $c;
}

sub read_first_line {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open(my $fh, '<', $p) or return undef;
    my $l = <$fh>;
    close $fh;
    return undef unless defined $l;
    $l =~ s/\s+$//;
    return $l;
}

sub wait_for_regex {
    my ($file, $re, $timeout_s) = @_;
    my $deadline = time() + $timeout_s;
    while (time() < $deadline) {
        my $c = slurp($file);
        return 1 if $c =~ $re;
        sleep(0.25);
    }
    return 0;
}

sub wait_for_numeric_file {
    my ($file, $timeout_s) = @_;
    my $deadline = time() + $timeout_s;
    while (time() < $deadline) {
        my $l = read_first_line($file);
        return $l if defined $l && $l =~ /^\d+$/;
        sleep(0.25);
    }
    return undef;
}

sub wait_gone {
    my ($winpid, $timeout_s) = @_;
    my $deadline = time() + $timeout_s;
    while (time() < $deadline) {
        if (!defined($winpid) || !tasklist_alive($winpid)) {
            # M2: the moment THIS FILE has observed the pid gone, drop it from
            # every tracked set. A later Windows pid-reuse can never make
            # cleanup touch that number again.
            forget_winpid($winpid) if defined $winpid;
            return 1;
        }
        sleep(0.25);
    }
    return 0;
}

sub wait_pid_exit {
    my ($pid, $timeout_s) = @_;
    my $deadline = time() + $timeout_s;
    while (time() < $deadline) {
        my $w = waitpid($pid, WNOHANG);
        return 1 if $w == $pid;
        sleep(0.25);
    }
    return 0;
}

# close_pipe_bounded($fh, $pid, $timeout_s, $label) -- close a pipe-opened
# ('-|') filehandle without ever blocking for the child's own lifetime.
# Perl's close() on a pipe filehandle waits for the child to exit if it has
# not already been reaped; a real-process owner (e.g. a throwaway
# `Start-Sleep -Seconds 600`) that an identity-checked kill failed to reach
# turns that close() into a multi-minute stall (measured: 599s, one whole
# file, off a single silently no-op'd kill). This never trusts that the
# earlier kill worked: it waitpid()s with WNOHANG up to $timeout_s, and if
# the child is still alive at the deadline, KILLs it directly by (msys) $pid
# before ever calling the blocking close().
sub close_pipe_bounded {
    my ($fh, $pid, $timeout_s, $label) = @_;
    $timeout_s //= 15;
    $label //= 'close_pipe_bounded';
    if (defined $pid && $pid =~ /^\d+$/) {
        my $deadline = time() + $timeout_s;
        my $reaped = 0;
        while (time() < $deadline) {
            my $w = waitpid($pid, WNOHANG);
            if ($w == $pid) { $reaped = 1; last }
            sleep(0.25);
        }
        unless ($reaped) {
            diag("$label: pid=$pid still alive after ${timeout_s}s bounded wait -- forcing kill before close");
            local $@;
            eval { kill('KILL', $pid) };
            waitpid($pid, WNOHANG);
        }
    }
    close $fh if defined $fh;
    return;
}

# make_group($name) -- one registry dir, one state dir (with continuity/armed),
# a fake home and a fresh transcript, all under $R (spec harness requirement).
sub make_group {
    my ($name) = @_;
    my $base = tempdir(DIR => $R, CLEANUP => 1);
    (my $b = $base) =~ s{\\}{/}g;
    my %g = (
        base       => $b,
        registry   => "$b/registry",
        state      => "$b/state",
        home       => "$b/home",
        armed_dir  => "$b/state/continuity/armed",
        transcript => "$b/transcript.jsonl",
    );
    make_path($g{registry});
    make_path($g{home});
    make_path($g{armed_dir});
    open(my $fh, '>', $g{transcript}) or die $!;
    print {$fh} "x\n";
    close $fh;
    push @LEASE_LOGS, "$g{registry}/lease.log";
    return \%g;
}

sub write_arm {
    my ($g, $sid) = @_;
    my $f = "$g->{armed_dir}/$sid";
    open(my $fh, '>', $f) or die $!;
    print {$fh} qq({"transcript_path":"$g->{transcript}"}\n);
    close $fh;
    push @ARMED_FILES, $f;
    return $f;
}

# child_env($g, $live_script) -- the five env vars the harness requires,
# every one resolved under $R.
sub child_env {
    my ($g, $live_script) = @_;
    return (
        HOME                              => $g->{home},
        USERPROFILE                       => $g->{home},
        CCPRAXIS_CONTINUITY_ACTIVE_DIR    => $g->{registry},
        BUTLER_STATE_DIR                  => $g->{state},
        CCPRAXIS_LEASE_LIVE_SCRIPT        => $live_script,
        CCPRAXIS_CONTINUITY_LEASE_TICK    => $TICK,
    );
}

# spawn_refresher(script=>.., env=>{...}, no_wakelock=>0|1, extra_args=>[...])
# Forks a real perl child (our own msys pid space) running
# `perl $script lease --daemon [extra_args]`.
sub spawn_refresher {
    my (%opts) = @_;
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        my %e = %{ $opts{env} // {} };
        $ENV{$_} = $e{$_} for keys %e;
        if ($opts{no_wakelock}) { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
        else                    { delete $ENV{CCPRAXIS_NO_WAKELOCK} }
        open(STDIN,  '<', File::Spec->devnull);
        open(STDOUT, '>', File::Spec->devnull);
        open(STDERR, '>', File::Spec->devnull);
        my @cmd = ($^X, $opts{script}, 'lease', '--daemon', @{ $opts{extra_args} // [] });
        exec(@cmd);
        POSIX::_exit(127);
    }
    register_refresher($pid);
    return $pid;
}

# spawn_owner() -- a real throwaway powershell.exe writing its own $PID.
sub spawn_owner {
    my $dir  = tempdir(DIR => $WIN_TMP, CLEANUP => 1);
    (my $dir_fwd = $dir) =~ s{\\}{/}g;
    my $file = "$dir/owner.pid";
    my @cmd = (
        'powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-Command', "Set-Content -LiteralPath '$file' -Value \$PID -Encoding ascii; Start-Sleep -Seconds 600",
    );
    my $pid = open(my $fh, '-|', @cmd) or die "spawn owner failed: $!";
    note_pending_pidfile($file, $dir_fwd);
    my $w = wait_for_numeric_file($file, 30);
    register_helper_winpid($w, $dir_fwd) if defined $w;
    return ($w, $fh, $pid);
}

# spawn_keepawake_direct(%opts) -- drives keep-awake.ps1 (the live copy)
# directly, the same shape execution-power-request.t / keepawake-lease-
# liveness.t use.
sub spawn_keepawake_direct {
    my (%opts) = @_;
    my $dir     = tempdir(DIR => $WIN_TMP, CLEANUP => 1);
    my $pidfile = "$dir/keepawake.pid";
    my $logfile = "$dir/keepawake.log";
    my @cmd = (
        'powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', "$R_FWD/live/plugins/sandbox/scripts/keep-awake.ps1",
        '-PidFile', $pidfile, '-LogFile', $logfile,
        '-PollSeconds', $opts{poll} // 3,
        '-LeaseSeconds', $opts{lease} // 30,
    );
    push @cmd, '-OwnerDesc', $opts{owner_desc} if defined $opts{owner_desc};
    push @cmd, '-SimulatePowerRequestFailure' if $opts{simulate_failure};
    my $pid = open(my $fh, '-|', @cmd) or die "spawn keep-awake failed: $!";
    note_pending_pidfile($pidfile, $R_FWD);
    # S4: 60s, not 15s -- a cold PowerShell start under host load (the AC-12
    # flake) can outlast a 15s bound for no behavioral reason.
    my $w = wait_for_numeric_file($pidfile, 60);
    register_helper_winpid($w, $R_FWD) if defined $w;
    return ($logfile, $pidfile, $w, $fh, $pid);
}

# ===========================================================================
# AC-17(a): before the first spawn, all five env vars resolve under $R.
# ===========================================================================
{
    my $g1_probe = make_group('probe17a');
    my %e = child_env($g1_probe, $LIVE_MODULE);
    for my $k (qw(HOME USERPROFILE CCPRAXIS_CONTINUITY_ACTIVE_DIR BUTLER_STATE_DIR CCPRAXIS_LEASE_LIVE_SCRIPT)) {
        like($e{$k}, qr/^\Q$R_FWD\E/i, "AC-17(a): child env $k resolves under \$R");
    }
}

# ===========================================================================
# process_identity must actually resolve a live process. Every identity-checked
# kill in this file goes through it, so a lookup that silently returns nothing
# turns force_kill_winpid into a no-op. That happened once: the query ran
# through sh, which ate PowerShell's $_, and an unkilled 600s owner stretched
# this file from 34s to 690s with every assertion still green.
# ===========================================================================
{
    my $self_w = _msys_winpid($$);
    SKIP: {
        skip 'no /proc/$$/winpid on this platform', 2 unless defined $self_w;
        my ($img, $cmd) = process_identity($self_w);
        like($img // '', qr/^perl\.exe$/i,
            'process_identity: resolves this test process to perl.exe');
        like($cmd // '', qr/lease-refresher-hygiene\.t/,
            'process_identity: the command line names this test file');
    }
}

# ===========================================================================
# GROUP G1 (AC-1, AC-2, AC-20): code-changed handover, no lock gap.
# ===========================================================================
my ($g1, $r1_pid, $r1_winpid, $r2_pid, $handover_start_time, $r1_exited);
{
    $g1 = make_group('g1');
    my $sid = 'g1sess';
    write_arm($g1, $sid);

    my %env = child_env($g1, $LIVE_MODULE);
    $r1_pid = spawn_refresher(script => $LIVE_MODULE, env => \%env, no_wakelock => 0);

    my $pidfile = "$g1->{registry}/keepawake.pid";
    my $logfile = "$g1->{registry}/lease.log";

    my $h1_winpid = wait_for_numeric_file($pidfile, 30);
    register_helper_winpid($h1_winpid) if defined $h1_winpid;
    ok(defined($h1_winpid), 'G1 setup: a real keep-awake helper (H1) appears with a numeric WINPID')
        or diag('lease.log so far: ' . slurp($logfile));

    my $got_tick = wait_for_regex($logfile, qr/\bTICK\b/, $TICK * 6);
    ok($got_tick, 'G1 setup: R1 logs at least one TICK line before the mtime change')
        or diag('lease.log so far: ' . slurp($logfile));

    my $recorded_mtime = (stat($LIVE_MODULE))[9];
    utime($recorded_mtime - 3600, $recorded_mtime - 3600, $LIVE_MODULE);

    # AC-1(a)
    my $t_change = time();
    my $got_handover_start = wait_for_regex($logfile, qr/HANDOVER-START reason=code-changed/, $TICK + 10);
    ok($got_handover_start, 'AC-1(a): R1 logs HANDOVER-START reason=code-changed within tick+10s')
        or diag('lease.log so far: ' . slurp($logfile));
    $handover_start_time = time();

    my $log_at_handover_start = slurp($logfile);
    my ($before_handover) = $log_at_handover_start =~ /^(.*)HANDOVER-START reason=code-changed/s;
    $before_handover //= '';

    # AC-1(d)/AC-2 sampling loop: from HANDOVER-START until 5s after R1 exits,
    # every <=0.5s, lease.pid must exist+numeric and >=1 known keepawake winpid
    # must be alive. Also captures AC-2 (H1 gone within 45s) and finds R2.
    my $lease_pid_file = "$g1->{registry}/lease.pid";
    my @known_keepawake_winpids = ($h1_winpid);
    my $h1_gone_within_45 = 0;
    my $lease_pid_ok_every_sample = 1;
    my $any_alive_every_sample = 1;
    my $exit_seen_at;
    my $sample_deadline = time() + 90 + 5;   # AC-1(c) bound plus AC-1(d)'s +5s tail
    my $exit_check_deadline = time() + 90;

    while (time() < $sample_deadline) {
        my $now = time();

        # track any newer keepawake winpid (R2's replacement helper)
        my $cur = read_first_line($pidfile);
        if (defined $cur && $cur =~ /^\d+$/ && !grep { $_ eq $cur } @known_keepawake_winpids) {
            push @known_keepawake_winpids, $cur;
            register_helper_winpid($cur);
        }

        if (!$h1_gone_within_45 && ($now - $handover_start_time) <= 45) {
            unless (tasklist_alive($h1_winpid)) {
                $h1_gone_within_45 = 1;
                forget_winpid($h1_winpid);
            }
        }

        my $lp = read_first_line($lease_pid_file);
        $lease_pid_ok_every_sample = 0 unless defined($lp) && $lp =~ /^\d+$/;

        my $any_alive = 0;
        for my $w (@known_keepawake_winpids) { $any_alive = 1 if tasklist_alive($w) }
        $any_alive_every_sample = 0 unless $any_alive;

        if (!defined($exit_seen_at) && $now < $exit_check_deadline) {
            my $w = waitpid($r1_pid, WNOHANG);
            if ($w == $r1_pid) { $exit_seen_at = $now; $sample_deadline = $now + 5 }
        }

        sleep(0.5);
    }

    $r1_exited = defined $exit_seen_at;
    ok($r1_exited, 'AC-1(c): R1 exits within 90s of the mtime change')
        or diag('lease.log so far: ' . slurp($logfile));

    my $final_log = slurp($logfile);
    like($final_log, qr/HANDOVER-DONE.*EXIT reason=handed-over/s,
        'AC-1(c): the log has HANDOVER-DONE then EXIT reason=handed-over')
        or diag("lease.log:\n$final_log");

    # AC-1(b) is about R1 specifically -- the successor (R2) legitimately
    # ticks into the SAME lease.log after handing over (AC-1(f) requires
    # exactly that), so "no TICK anywhere in the file" would contradict
    # AC-1(f) by construction. Filter to lines carrying R1's own pid.
    {
        my $tail = substr(slurp($logfile), length($before_handover));
        my @r1_ticks_after = grep { /\bpid=\Q$r1_pid\E\b/ && /\bTICK\b/ } split /\n/, $tail;
        is(scalar(@r1_ticks_after), 0,
            "AC-1(b): no TICK line from R1 (pid=$r1_pid) appears after HANDOVER-START")
            or diag(join("\n", @r1_ticks_after));
    }

    ok($lease_pid_ok_every_sample,
        'AC-1(d): lease.pid existed and was numeric at every sample from HANDOVER-START to 5s after exit');
    ok($any_alive_every_sample,
        'AC-1(d): at least one known keepawake WINPID was alive at every sample');

    ok($h1_gone_within_45, 'AC-2: H1\'s WINPID is gone within 45s of HANDOVER-START')
        or diag('known winpids: ' . join(',', @known_keepawake_winpids));

    # AC-1(e): the lock must be free after R1 exits (a probe that "wins" must
    # release immediately and fail the assertion).
    SKIP: {
        skip 'AC-1(e): R1 never exited, cannot probe the lock meaningfully', 1 unless $r1_exited;
        my $lock_path = "$g1->{registry}/lease.lock";
        my $probe_ok = 0;
        if (open(my $lfh, '>>', $lock_path)) {
            if (flock($lfh, LOCK_EX | LOCK_NB)) {
                $probe_ok = 1;
                flock($lfh, LOCK_UN);
            }
            close $lfh;
        }
        ok(!$probe_ok, 'AC-1(e): after R1 exits, a LOCK_EX|LOCK_NB probe on lease.lock FAILS (someone else holds it)');
    }

    # AC-1(f) / AC-2's R2 identity
    my $lp_final = read_first_line($lease_pid_file);
    if (defined $lp_final && $lp_final =~ /^(\d+)$/) {
        $r2_pid = $1;
    }
    ok(defined($r2_pid) && (!$r1_exited || "$r2_pid" ne "$r1_pid"),
        'AC-1(f): lease.pid names a pid different from R1\'s')
        or diag('lease.pid: ' . (defined $lp_final ? $lp_final : '<absent>') . " R1=$r1_pid");

    SKIP: {
        skip 'AC-1(f): no successor pid recorded in lease.pid', 2 unless defined $r2_pid;
        register_refresher($r2_pid);
        my @r2_lines = grep { /\bpid=\Q$r2_pid\E\b/ } split /\n/, slurp($logfile);
        my $r2_text = join("\n", @r2_lines);
        like($r2_text, qr/\bSTART\b.*handover=1/, 'AC-1(f): lease.log lines for the successor pid include START with handover=1')
            or diag("successor lines:\n$r2_text");
        like($r2_text, qr/\bTICK\b/, 'AC-1(f): the successor also logs at least one TICK')
            or diag("successor lines:\n$r2_text");
    }

    # AC-2: H2 identity + OWNER winpid on H2's own keepawake.log
    my $h2_winpid = $known_keepawake_winpids[-1];
    ok(defined($h2_winpid) && (!defined($h1_winpid) || "$h2_winpid" ne "$h1_winpid"),
        'AC-2: the current keepawake.pid names H2, different from H1')
        or diag("h1=$h1_winpid h2=" . (defined $h2_winpid ? $h2_winpid : '<undef>'));

    my $keepawake_log = "$g1->{registry}/keepawake.log";
    SKIP: {
        skip 'AC-2: R2 pid unknown, cannot read its own WINPID for comparison', 2 unless defined $r2_pid;
        my $w_of_r2 = kill(0, $r2_pid) ? _msys_winpid($r2_pid) : undef;
        SKIP: {
            skip 'AC-2: R2 is not alive (or its winpid is unreadable) at the moment of the check', 1
                unless defined $w_of_r2;
            like(slurp($keepawake_log), qr/OWNER winpid=\Q$w_of_r2\E/,
                "AC-2: H2's keepawake.log has OWNER winpid=$w_of_r2, the successor's own WINPID");
        }
    }

    # AC-20: H1's exit did not delete H2's pid file; it still names H2.
    my $pf_after = read_first_line($pidfile);
    ok(defined($pf_after) && defined($h2_winpid) && "$pf_after" eq "$h2_winpid",
        "AC-20: keepawake.pid still exists after H1's exit and names H2")
        or diag('pidfile content: ' . (defined $pf_after ? $pf_after : '<absent>'));

    # group cleanup: best-effort now; global END is the backstop.
    force_kill_winpid($h1_winpid);
    force_kill_winpid($h2_winpid) if defined $h2_winpid;
    if (defined $r2_pid) { local $@; eval { kill('TERM', $r2_pid) } }
    unless ($r1_exited) { local $@; eval { kill('KILL', $r1_pid) } }
}

# ===========================================================================
# GROUP G2 (AC-3, AC-4): non-live start -> handover, no self-loop.
# ===========================================================================
{
    my $g2 = make_group('g2');
    my $sid = 'g2sess';
    write_arm($g2, $sid);

    my %env = child_env($g2, $LIVE_MODULE);   # live script = the COPY, not the repo
    my $r1_pid = spawn_refresher(script => $REPO_MODULE, env => \%env, no_wakelock => 1);

    my $logfile     = "$g2->{registry}/lease.log";
    my $lease_pid_f = "$g2->{registry}/lease.pid";

    # spec 2.7's format is "HANDOVER-START reason=<...> file=<abs> live=<abs>"
    # -- file= sits between reason= and live=, never adjacent to it.
    my $got_start = wait_for_regex($logfile, qr/HANDOVER-START reason=not-live file=\S+ live=\Q$LIVE_MODULE\E/, 20);
    ok($got_start, 'AC-3: R1 (started from a non-live path) logs HANDOVER-START reason=not-live on its first iteration')
        or diag('lease.log: ' . slurp($logfile));

    my $log_snapshot = slurp($logfile);
    my ($pre) = $log_snapshot =~ /^(.*)HANDOVER-START reason=not-live/s;
    $pre //= '';
    unlike(substr($log_snapshot, length($pre)), qr/\bTICK\b/,
        'AC-3: R1 logs no TICK line');

    my $exited = wait_pid_exit($r1_pid, 60);
    ok($exited, 'AC-3: R1 exits within 60s') or diag('lease.log: ' . slurp($logfile));

    like(slurp($logfile), qr/HANDOVER-DONE\s+successor=\S+\s+helper=none/,
        'AC-3: the log has HANDOVER-DONE ... helper=none (no helper existed, CCPRAXIS_NO_WAKELOCK kept)');

    SKIP: {
        skip 'AC-3: R1 never exited, lock probe is meaningless', 1 unless $exited;
        my $lock_path = "$g2->{registry}/lease.lock";
        my $probe_ok = 0;
        if (open(my $lfh, '>>', $lock_path)) {
            if (flock($lfh, LOCK_EX | LOCK_NB)) { $probe_ok = 1; flock($lfh, LOCK_UN) }
            close $lfh;
        }
        ok(!$probe_ok, 'AC-3: the lock probe fails after R1 exits');
    }

    my $lp2 = read_first_line($lease_pid_f);
    my $r2_pid_g2;
    if (defined $lp2 && $lp2 =~ /^(\d+)$/) { $r2_pid_g2 = $1; register_refresher($r2_pid_g2) }
    ok(defined($r2_pid_g2) && "$r2_pid_g2" ne "$r1_pid",
        'AC-3: lease.pid names a different pid than R1')
        or diag('lease.pid: ' . (defined $lp2 ? $lp2 : '<absent>'));

    SKIP: {
        skip 'AC-3: no successor pid found', 1 unless defined $r2_pid_g2;
        my @r2_lines = grep { /\bpid=\Q$r2_pid_g2\E\b/ } split /\n/, slurp($logfile);
        like(join("\n", @r2_lines), qr/\bSTART\b.*script=\Q$LIVE_MODULE\E.*handover=1/,
            "AC-3: the successor's START line has script=$LIVE_MODULE and handover=1")
            or diag("successor lines:\n" . join("\n", @r2_lines));
    }

    # AC-4: the successor never hands over for not-live within 3 ticks.
    SKIP: {
        skip 'AC-4: no successor pid found', 1 unless defined $r2_pid_g2;
        sleep($TICK * 3);
        my @r2_lines = grep { /\bpid=\Q$r2_pid_g2\E\b/ } split /\n/, slurp($logfile);
        unlike(join("\n", @r2_lines), qr/HANDOVER-START/,
            'AC-4: the successor logs no HANDOVER-START within 3 ticks after its START -- no self-loop');
        if (defined $r2_pid_g2) { local $@; eval { kill('TERM', $r2_pid_g2) } }
    }

    unless ($exited) { local $@; eval { kill('KILL', $r1_pid) } }
}

# ===========================================================================
# GROUP G3 / G3b (AC-5, AC-6, AC-9, AC-11, AC-14): TERM / normal-exit release,
# per-tick reason line, owner naming -- all sharing one live-copy refresher +
# real helper.
# ===========================================================================
my ($g3, $r3_winpid_of_refresher);
{
    $g3 = make_group('g3');
    my $sid = 'g3sess';
    write_arm($g3, $sid);

    my %env = child_env($g3, $LIVE_MODULE);   # live == own script: no not-live handover
    my $r1_pid = spawn_refresher(script => $LIVE_MODULE, env => \%env, no_wakelock => 0);

    my $logfile = "$g3->{registry}/lease.log";
    my $pidfile = "$g3->{registry}/keepawake.pid";
    my $keepawake_log = "$g3->{registry}/keepawake.log";

    my $h_winpid = wait_for_numeric_file($pidfile, 30);
    register_helper_winpid($h_winpid) if defined $h_winpid;
    ok(defined($h_winpid), 'G3 setup: a real keep-awake helper appears with a numeric WINPID')
        or diag('lease.log: ' . slurp($logfile));

    my $got_tick = wait_for_regex($logfile, qr/\bTICK\b/, $TICK * 8);
    ok($got_tick, 'G3 setup: at least one TICK line appears before TERM') or diag('lease.log: ' . slurp($logfile));

    # AC-9: the per-tick reason line, before TERM.
    my $log_before_term = slurp($logfile);
    like($log_before_term, qr/\bTICK active=1 reason=arm sid=\Q$sid\E basis=transcript age=\d+s arms=1$/m,
        'AC-9: a TICK line names the arm sid/basis/age/arms, before TERM')
        or diag("lease.log:\n$log_before_term");

    $r3_winpid_of_refresher = _msys_winpid($r1_pid);

    # AC-11 / AC-14: OWNER winpid + REASON text on the helper's own log,
    # while the refresher is still alive.
    SKIP: {
        skip 'AC-11/14: could not read the refresher\'s own WINPID via /proc', 2
            unless defined $r3_winpid_of_refresher;
        # A cold PowerShell start can take several seconds to reach its first
        # OWNER/REASON log lines; a bare slurp() racing that would read an
        # empty/partial log and fail for a scaffolding reason, not a missing-
        # behavior one.
        wait_for_regex($keepawake_log, qr/OWNER winpid=/, 15);
        like(slurp($keepawake_log), qr/OWNER winpid=\Q$r3_winpid_of_refresher\E/,
            'AC-14: the helper log has OWNER winpid=<refresher WINPID>, not OWNER-UNVERIFIABLE');
        like(slurp($keepawake_log),
            qr/REASON text=ccpraxis keep-awake: execution required -- owner continuity-lease,sid=\Q$sid\E,arms=1 winpid=\Q$r3_winpid_of_refresher\E$/m,
            'AC-11: REASON text names the owner description and winpid, from the helper\'s own log')
            or diag('keepawake.log: ' . slurp($keepawake_log));
        unlike(slurp($keepawake_log), qr/powercfg/i, 'AC-11: no powercfg is invoked anywhere in the log');
    }

    # ----- AC-5: TERM stops the real child. -----
    kill('TERM', $r1_pid);
    my $gone   = wait_gone($h_winpid, 20);
    my $unlink_pid  = !wait_gone_or_exists($pidfile, 20);
    # The refresher's release closure writes EXIT reason=released LAST -- after
    # the KEEPAWAKE stop line, the lease.pid unlink and RELEASE reason=term. The
    # helper vanishing (wait_gone) and keepawake.pid vanishing (the helper
    # deletes its own) do NOT imply the refresher has finished releasing: it
    # still has to notice via one more tasklist spawn, which under -j6 load can
    # take seconds. Bounded poll on the real terminal event (archived never-halt
    # Decision 28), never a longer fixed sleep. 20s: >= one $TICK of signal-
    # delivery latency + stop_helper's own 10s+2s ceiling, and matches this
    # block's other two bounds.
    my $released = wait_for_regex($logfile, qr/EXIT reason=released/, 20);
    ok($gone, 'AC-5: within 20s, tasklist no longer shows the helper')
        or diag('winpid: ' . (defined $h_winpid ? $h_winpid : '<undef>'));
    ok(!-e $pidfile, 'AC-5: keepawake.pid is absent within the bound');
    ok(!-e "$g3->{registry}/lease.pid", 'AC-5: lease.pid is absent within the bound');
    my $final5 = slurp($logfile);
    like($final5, qr/KEEPAWAKE keepawake stop winpid=\Q$h_winpid\E result=gone/,
        'AC-5: lease.log has the KEEPAWAKE stop result=gone line') or diag("lease.log:\n$final5");
    like($final5, qr/RELEASE reason=term/, 'AC-5: lease.log has RELEASE reason=term');
    like($final5, qr/EXIT reason=released/, 'AC-5: lease.log has EXIT reason=released')
        or diag("EXIT wait returned $released after 20s bound; lease.log:\n$final5");

    unless (wait_pid_exit($r1_pid, 10)) { local $@; eval { kill('KILL', $r1_pid) } }
    force_kill_winpid($h_winpid);
}

sub wait_gone_or_exists {   # small helper used only by AC-5 above: true while file exists
    my ($file, $timeout_s) = @_;
    my $deadline = time() + $timeout_s;
    while (time() < $deadline) {
        return 0 unless -e $file;
        sleep(0.25);
    }
    return -e $file;
}

# ----- G3b (AC-6): normal exit (arm removed) stops the child. -----
{
    my $g3b = make_group('g3b');
    my $sid = 'g3bsess';
    my $armed = write_arm($g3b, $sid);

    my %env = child_env($g3b, $LIVE_MODULE);
    my $r1_pid = spawn_refresher(script => $LIVE_MODULE, env => \%env, no_wakelock => 0);

    my $logfile = "$g3b->{registry}/lease.log";
    my $pidfile = "$g3b->{registry}/keepawake.pid";

    my $h_winpid = wait_for_numeric_file($pidfile, 30);
    register_helper_winpid($h_winpid) if defined $h_winpid;
    ok(defined($h_winpid), 'G3b setup: a real keep-awake helper appears') or diag('lease.log: ' . slurp($logfile));

    unlink $armed;
    @ARMED_FILES = grep { $_ ne $armed } @ARMED_FILES;

    my $bound = $TICK * 3 + 20;
    my $exited = wait_pid_exit($r1_pid, $bound);
    ok($exited, "AC-6: the refresher exits within tick*3+20s (${bound}s) once its only arm is unlinked")
        or diag('lease.log: ' . slurp($logfile));

    my $gone = wait_gone($h_winpid, 20);
    ok($gone, 'AC-6: the helper is gone according to tasklist');

    my $final = slurp($logfile);
    like($final, qr/IDLE reason=no-live-arm/, 'AC-6: lease.log has IDLE reason=no-live-arm')
        or diag("lease.log:\n$final");
    like($final, qr/RELEASE reason=idle/, 'AC-6: lease.log has RELEASE reason=idle');
    like($final, qr/result=gone/, 'AC-6: the release logs result=gone');

    unless ($exited) { local $@; eval { kill('KILL', $r1_pid) } }
    force_kill_winpid($h_winpid);
}

# ===========================================================================
# AC-12: default REASON text (no -OwnerDesc), driven directly.
# ===========================================================================
{
    my ($logfile, $pidfile, $w, $fh, $pid) = spawn_keepawake_direct(simulate_failure => 1);
    ok(defined($w), 'AC-12 setup: the directly-spawned helper has a numeric WINPID')
        or diag('log: ' . slurp($logfile));

    # S4: 60s, not 15s -- the AC-12 flake was a cold PowerShell start outracing
    # a too-tight bound, not missing behavior.
    my $got = wait_for_regex($logfile, qr/REASON text=/, 60);
    ok($got, 'AC-12: a REASON line appears') or diag('log: ' . slurp($logfile));

    like(slurp($logfile), qr/REASON text=ccpraxis keep-awake: execution required$/m,
        'AC-12: with no -OwnerDesc, the text is exactly today\'s default, nothing after it on the line')
        or diag('log: ' . slurp($logfile));

    force_kill_winpid($w);
    # Kill BEFORE close: close() on a pipe-opened handle waits on the child
    # if it is not already reaped, and this handle's child is a real
    # PowerShell process this file spawned.
    close_pipe_bounded($fh, $pid, 15, 'AC-12 keep-awake pipe');
}

# ===========================================================================
# AC-13: bp-keepawake.pl passes the owner (from a non-.t caller).
# ===========================================================================
{
    my ($owner_w, $owner_fh, $owner_pid) = spawn_owner();
    ok(defined($owner_w), 'AC-13 setup: a throwaway owner process has a real WINPID');

    SKIP: {
        skip 'AC-13: could not confirm an owner WINPID', 3 unless defined $owner_w;

        my $dir = tempdir(DIR => $WIN_TMP, CLEANUP => 1);
        my $pidfile = "$dir/keepawake.pid";
        my $logfile = "$dir/keepawake.log";
        (my $live_kapl = "$R_FWD/live/plugins/butler/scripts/bp-keepawake.pl") =~ s{\\}{/}g;
        (my $dir_fwd = $dir) =~ s{\\}{/}g;

        my $code = "require '$live_kapl'; "
                 . "BpKeepAwake::apply('active', '$dir_fwd', "
                 . "{ owner_winpid => $owner_w, owner_desc => 'hygiene-test' });";

        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            delete $ENV{CCPRAXIS_NO_WAKELOCK};
            open(STDIN, '<', File::Spec->devnull);
            open(STDOUT, '>', File::Spec->devnull);
            open(STDERR, '>', File::Spec->devnull);
            exec($^X, '-e', $code);
            POSIX::_exit(127);
        }
        # This child's own command line names $live_kapl, which is under
        # $R_FWD -- so the default root in force_kill_winpid/register_
        # helper_winpid matches it. Register the WINPID too, not just the
        # msys pid: Git-for-Windows perl's fork() is emulated with threads,
        # so kill('KILL', $pid)/waitpid below can report success while the
        # underlying native perl.exe process (running this -e child) is
        # still alive. register_refresher captures both, so END's cleanup
        # (step 2) taskkills the WINPID too if the msys-level kill did not
        # actually take the native process down.
        register_refresher($pid);
        my $exited = wait_pid_exit($pid, 20);
        unless ($exited) { local $@; eval { kill('KILL', $pid) } }
        my $ac13_child_winpid = $REFRESHER_WINPID_SEEN{$pid};
        force_kill_winpid($ac13_child_winpid) if defined $ac13_child_winpid;

        note_pending_pidfile($pidfile, $dir_fwd);
        # S4: 60s, not 15s -- same cold-start rationale as spawn_keepawake_direct.
        my $h_w = wait_for_numeric_file($pidfile, 60);
        register_helper_winpid($h_w, $dir_fwd) if defined $h_w;
        ok(defined($h_w), 'AC-13: bp-keepawake.pl (live copy) spawned a real helper')
            or diag('log: ' . slurp($logfile));

        SKIP: {
            skip 'AC-13: no helper winpid to check the log against', 2 unless defined $h_w;
            # Bounded wait: same cold-start rationale as AC-11/AC-14 above.
            wait_for_regex($logfile, qr/OWNER winpid=/, 15);
            like(slurp($logfile), qr/OWNER winpid=\Q$owner_w\E/,
                "AC-13: the helper's log shows OWNER winpid=$owner_w") or diag('log: ' . slurp($logfile));
            like(slurp($logfile),
                qr/REASON text=ccpraxis keep-awake: execution required -- owner hygiene-test winpid=\Q$owner_w\E/,
                'AC-13: the REASON text names the owner_desc and winpid passed through apply()')
                or diag('log: ' . slurp($logfile));
            force_kill_winpid($h_w, $dir_fwd);
        }
    }

    force_kill_winpid($owner_w, $HELPER_WINPID_ROOT{$owner_w // ''});
    # Kill BEFORE close, and bound close() itself: this is the AC-13 owner,
    # a real `Start-Sleep -Seconds 600` -- if the identity-checked kill above
    # ever fails to reach it, a bare close($owner_fh) blocks for the whole
    # 600s sleep (measured: this exact gap, once process_identity() itself
    # was broken and silently no-op'd the kill).
    close_pipe_bounded($owner_fh, $owner_pid, 15, 'AC-13 owner pipe');

    # Backstop for this block specifically: the perl -e child's own exec()
    # (fork()+exec() emulation on Git-for-Windows perl) has been observed to
    # leave a native process alive under a pid _msys_winpid() never reported
    # for the fork -- so the per-pid kills above are not trusted alone here.
    # Both the child and the keep-awake.ps1 helper it spawns name a path
    # under $R_FWD (the child via $live_kapl; the helper via its -File arg),
    # so one sweep on the default root reaps both.
    sweep_kill_root($R_FWD);
}

# ===========================================================================
# Unit tests (AC-8, AC-10, AC-16, AC-21) -- in-process, no wake-lock, no
# real ~/.claude state. Requires the REPO scripts directly (the convention
# every other unit-level test in this suite already uses).
# ===========================================================================
require "$REPO_KEEPAWAKE_PL";
require "$REPO_MODULE";

# LZ(pkg, name, @args) -- call <pkg>::<name> without dying when it does not
# exist yet (the sub is new in this package). Same technique as the sibling
# continuity-lease-follows-arm.t's LZ().
sub LZ {
    my ($pkg, $name, @args) = @_;
    my $code; { no strict 'refs'; $code = \&{"${pkg}::${name}"} }
    my @ret;
    my $ok = eval { @ret = $code->(@args); 1 };
    return $ok ? (wantarray ? @ret : $ret[0]) : undef;
}

# ----- AC-16: owner_desc_clean -----
{
    is(LZ('BpKeepAwake', 'owner_desc_clean', undef), undef, 'AC-16: owner_desc_clean(undef) is undef');
    is(LZ('BpKeepAwake', 'owner_desc_clean', ''), undef, "AC-16: owner_desc_clean('') is undef");
    is(LZ('BpKeepAwake', 'owner_desc_clean', ':::'), '___', "AC-16: owner_desc_clean(':::') is '___'");
    is(LZ('BpKeepAwake', 'owner_desc_clean', "a:b/c d\"e\xc3\xa9"), 'a_b_c_d_e__',
        'AC-16: every disallowed byte becomes exactly one underscore');
    is(length(LZ('BpKeepAwake', 'owner_desc_clean', ('x' x 300)) // ''), 100,
        'AC-16: a 300-char input of x is truncated to 100 chars');

    my $src = do { local $/; open(my $fh, '<:raw', $REPO_KEEPAWAKE_PL) or die $!; <$fh> };
    my ($spawn_body) = $src =~ /\bsub\s+spawn\s*\{(.*?)\n\}\n/s;
    ok(defined($spawn_body), 'AC-16 sanity: sub spawn() is locatable');
    like($spawn_body // '', qr/-OwnerDesc.{0,80}\bif\s+defined\b|\bif\s+defined\b.{0,80}-OwnerDesc/s,
        'AC-16 (static): spawn() adds -OwnerDesc only inside a branch guarded by defined')
        or diag($spawn_body // '<sub not found>');
}

# ----- AC-8: stop_helper unit behaviour + no-print integration -----
{
    my (@calls, $img_seq);
    my $seams = sub {
        my (%o) = @_;
        return (
            image_of => $o{image_of},
            taskkill => sub { push @calls, [ 'taskkill', @_ ] },
            wait_seconds => $o{wait_seconds} // 0.01,
        );
    };

    is(LZ('BpKeepAwake', 'stop_helper', '4242', $seams->(image_of => sub { undef })), 'gone',
        'AC-8: image_of undef -> gone with 0 taskkill calls');
    is(scalar(@calls), 0, 'AC-8: ...and 0 taskkill calls') or diag(scalar(@calls));

    @calls = ();
    is(LZ('BpKeepAwake', 'stop_helper', '4242', $seams->(image_of => sub { 'notepad.exe' })), 'not-ours',
        'AC-8: image_of notepad.exe -> not-ours with 0 taskkill calls');
    is(scalar(@calls), 0, 'AC-8: ...and 0 taskkill calls');

    @calls = ();
    my $first = 1;
    is(LZ('BpKeepAwake', 'stop_helper', '4242', $seams->(image_of => sub { $first-- >= 0 ? 'powershell.exe' : undef })),
        'gone', 'AC-8: powershell.exe once then undef -> gone with 1 taskkill call');
    is(scalar(@calls), 1, 'AC-8: ...exactly one taskkill call');

    @calls = ();
    is(LZ('BpKeepAwake', 'stop_helper', '4242', $seams->(image_of => sub { 'powershell.exe' }, wait_seconds => 0)),
        'still-alive', 'AC-8: always powershell.exe, wait_seconds=>0 -> still-alive with 2 taskkill calls');
    is(scalar(@calls), 2, 'AC-8: ...and exactly 2 taskkill calls');
    ok((grep { $_->[-1] } @calls), 'AC-8: the second taskkill call carries the tree flag')
        if @calls == 2;

    is(LZ('BpKeepAwake', 'stop_helper', 'abc'), 'invalid', "AC-8: 'abc' -> invalid");

    # Production seams, Windows only: a not-running pid -> gone, nothing printed.
    SKIP: {
        skip 'AC-8 (production seams): Windows-only', 3 unless $^O =~ /^(MSWin32|msys|cygwin)$/;
        my ($out_fh, $out_file) = tempfile();
        my ($err_fh, $err_file) = tempfile();
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        # The RESULT must never go to STDOUT/STDERR (that is exactly what
        # this case asserts is silent) -- it is written to a THIRD file
        # instead, so the "nothing printed" check and the "result is gone"
        # check cannot contradict each other.
        my $result_file = "$out_file.result";
        if ($pid == 0) {
            open(STDOUT, '>', $out_file);
            open(STDERR, '>', $err_file);
            my $result = eval { LZ('BpKeepAwake', 'stop_helper', '999999') };
            if (open(my $rf, '>', $result_file)) {
                print {$rf} (defined $result ? $result : '<undef>');
                close $rf;
            }
            POSIX::_exit(0);
        }
        wait_pid_exit($pid, 15) or do { local $@; eval { kill('KILL', $pid) } };
        is(slurp($out_file), '', 'AC-8: production stop_helper prints nothing to STDOUT');
        is(slurp($err_file), '', 'AC-8: production stop_helper prints nothing to STDERR');
        is(slurp($result_file), 'gone',
            'AC-8: production stop_helper (real tasklist, a not-running pid) returns gone');
        unlink $result_file;
    }
}

# ----- AC-8 (regression): a short-form pid_f against a long-form cmdline
# must not be mistaken for "not ours". The command line stop_helper compares
# against is built by winify()/winify_out() (Cwd::abs_path -> the long,
# resolved form), while a caller's own $pid_f can be handed in short (8.3)
# form when it was carved from a short-form tempdir root -- exactly the
# force_kill_winpid mismatch fixed above, one layer down in production code.
# A short/long mismatch here must never read as "some unrelated
# powershell.exe" and skip the kill.
#
# Both sides must resolve to a REAL directory: a fabricated short-form path
# naming a directory that does not exist resolves to nothing, so the
# assertion below would pass (or fail) for no reason connected to the
# behavior under test. $WIN_TMP is already in short (8.3) form on this host
# ($ENV{TEMP} = C:/Users/ANDR~1/...), and File::Temp does not resolve it, so
# a tempdir carved under it stays short-form -- exactly the shape a real
# caller hands in. The long form is Cwd::abs_path() of that SAME directory,
# i.e. bp-keepawake.pl's own winify()/winify_out() resolution -- not a
# hand-typed spelling, which is how the previous version of this case ended
# up comparing two different names ("Andre" vs "André") instead of two forms
# of the same one.
{
    my $short_dir = tempdir(DIR => $WIN_TMP, CLEANUP => 1);
    (my $short_dir_fwd = $short_dir) =~ s{\\}{/}g;
    my $long_dir_raw = Cwd::abs_path($short_dir);

    SKIP: {
        skip 'AC-8 (regression): this host resolves the short (8.3) form of its temp '
           . 'root identically to the long form (8.3 name generation is disabled), so '
           . 'the short/long mismatch this case exercises cannot be constructed here', 2
            unless defined($long_dir_raw) && lc($long_dir_raw) ne lc($short_dir_fwd);

        (my $long_dir_fwd = $long_dir_raw) =~ s{\\}{/}g;
        $long_dir_fwd =~ s{^/([a-zA-Z])/}{\u$1:/};

        my $short_pid_f = "$short_dir_fwd/keepawake.pid";   # NOT created: "pid file already gone"
        my $long_cmd    = "powershell.exe -NoProfile -File $long_dir_fwd/keep-awake.ps1"
                         . " -PidFile $long_dir_fwd/keepawake.pid -LeaseSeconds 900";
        my @calls;
        my $result = LZ('BpKeepAwake', 'stop_helper', '4242',
            image_of   => sub { 'powershell.exe' },
            cmdline_of => sub { $long_cmd },
            taskkill   => sub { push @calls, [ 'taskkill', @_ ] },
            wait_seconds => 0.01,
            pid_f      => $short_pid_f,
        );
        isnt($result, 'not-ours',
            "AC-8 (regression): a short-form pid_f against a long-form keep-awake.ps1 cmdline naming the same path is not 'not-ours'")
            or diag("result=" . (defined $result ? $result : '<undef>') . " short=$short_pid_f long_cmd=$long_cmd");
        ok(scalar(@calls) >= 1,
            'AC-8 (regression): the taskkill seam was called (the short/long match was recognized as "ours")')
            or diag('calls: ' . scalar(@calls));
    }
}

# ----- AC-10: active_reason -----
{
    my $home = tempdir(CLEANUP => 1);
    (my $abs_home = $home) =~ s{\\}{/}g;
    local $BpContinuityLease::STATE_ROOT = "$abs_home/state";
    make_path("$abs_home/state/armed");

    # basis=transcript
    my $tp = "$abs_home/t1.jsonl";
    open(my $fh1, '>', $tp) or die $!; print {$fh1} "x\n"; close $fh1;
    open(my $a1, '>', "$abs_home/state/armed/sidA") or die $!;
    print {$a1} qq({"transcript_path":"$tp"}\n);
    close $a1;
    my $r1 = LZ('BpContinuityLease', 'active_reason', $abs_home . '/legacy-unused');
    is(ref($r1) eq 'HASH' ? $r1->{basis} : undef, 'transcript', 'AC-10: a live transcript gives basis=transcript');
    is(BpContinuityLease::any_active($abs_home . '/legacy-unused'), (defined $r1 ? 1 : 0),
        'AC-10: any_active agrees with defined(active_reason) for the transcript fixture');
    unlink "$abs_home/state/armed/sidA";

    # basis=transcript-missing
    open(my $a2, '>', "$abs_home/state/armed/sidB") or die $!;
    print {$a2} qq({"transcript_path":"$abs_home/does-not-exist.jsonl"}\n);
    close $a2;
    my $r2 = LZ('BpContinuityLease', 'active_reason', $abs_home . '/legacy-unused');
    is(ref($r2) eq 'HASH' ? $r2->{basis} : undef, 'transcript-missing',
        'AC-10: a non-existent transcript with a fresh arm file gives basis=transcript-missing');
    is(BpContinuityLease::any_active($abs_home . '/legacy-unused'), (defined $r2 ? 1 : 0),
        'AC-10: any_active agrees with defined(active_reason) for the transcript-missing fixture');
    unlink "$abs_home/state/armed/sidB";

    # basis=arm-mtime (not JSON)
    open(my $a3, '>', "$abs_home/state/armed/sidC") or die $!;
    print {$a3} "not json at all\n";
    close $a3;
    my $r3 = LZ('BpContinuityLease', 'active_reason', $abs_home . '/legacy-unused');
    is(ref($r3) eq 'HASH' ? $r3->{basis} : undef, 'arm-mtime', 'AC-10: a non-JSON arm file gives basis=arm-mtime');
    is(BpContinuityLease::any_active($abs_home . '/legacy-unused'), (defined $r3 ? 1 : 0),
        'AC-10: any_active agrees with defined(active_reason) for the arm-mtime fixture');
    unlink "$abs_home/state/armed/sidC";

    # arms=2 and the sorted-first sid
    open(my $a4, '>', "$abs_home/state/armed/aaa") or die $!;
    print {$a4} "not json\n";
    close $a4;
    open(my $a5, '>', "$abs_home/state/armed/zzz") or die $!;
    print {$a5} "not json\n";
    close $a5;
    my $r4 = LZ('BpContinuityLease', 'active_reason', $abs_home . '/legacy-unused');
    is(ref($r4) eq 'HASH' ? $r4->{arms} : undef, 2, 'AC-10: two live arms give arms=2');
    is(ref($r4) eq 'HASH' ? $r4->{sid} : undef, 'aaa', 'AC-10: the sorted-first sid is reported');
    unlink "$abs_home/state/armed/aaa", "$abs_home/state/armed/zzz";

    # undef for an empty store
    my $r5 = LZ('BpContinuityLease', 'active_reason', $abs_home . '/legacy-unused');
    is($r5, undef, 'AC-10: an empty store gives undef');
    is(BpContinuityLease::any_active($abs_home . '/legacy-unused'), 0, 'AC-10: any_active agrees (0) for the empty store');

    # undef for an arm whose transcript is 2h old
    my $tp_old = "$abs_home/old.jsonl";
    open(my $fh6, '>', $tp_old) or die $!; print {$fh6} "x\n"; close $fh6;
    my $old_t = time() - 7200;
    utime($old_t, $old_t, $tp_old);
    open(my $a6, '>', "$abs_home/state/armed/sidOld") or die $!;
    print {$a6} qq({"transcript_path":"$tp_old"}\n);
    close $a6;
    my $r6 = LZ('BpContinuityLease', 'active_reason', $abs_home . '/legacy-unused');
    is($r6, undef, 'AC-10: an arm naming a 2h-old transcript gives undef');
    is(BpContinuityLease::any_active($abs_home . '/legacy-unused'), 0, 'AC-10: any_active agrees (0) for the stale-transcript fixture');
    unlink "$abs_home/state/armed/sidOld";
}

# ----- AC-21: daemon_loop, handover_spawn refuses, no H3 wait -----
{
    my $home = tempdir(CLEANUP => 1);
    (my $abs_home = $home) =~ s{\\}{/}g;
    make_path("$abs_home/registry");
    make_path("$abs_home/state/armed");
    local $BpContinuityLease::STATE_ROOT = "$abs_home/state";

    my $tp = "$abs_home/t.jsonl";
    open(my $fh, '>', $tp) or die $!; print {$fh} "x\n"; close $fh;
    open(my $a, '>', "$abs_home/state/armed/only") or die $!;
    print {$a} qq({"transcript_path":"$tp"}\n);
    close $a;

    local $ENV{CCPRAXIS_LEASE_LIVE_SCRIPT} = "$abs_home/not-a-real-module.pm";
    local $ENV{HOME} = $abs_home;
    local $ENV{USERPROFILE} = $abs_home;

    my $t0 = time();
    my $result;
    my $ok_call;
    {
        local $SIG{ALRM} = sub { die "AC-21-TIMEOUT\n" };
        alarm(15);
        $ok_call = eval {
            $result = BpContinuityLease::daemon_loop("$abs_home/registry",
                max_iterations => 2,
                handover_spawn => sub { undef },
            );
            1;
        };
        alarm(0);
    }
    my $elapsed = time() - $t0;

    ok($ok_call, 'AC-21: daemon_loop returns rather than alarming out at 15s') or diag($@ // 'died');
    SKIP: {
        skip 'AC-21: the call alarmed out, further assertions are meaningless', 4 unless $ok_call;
        is($result, 'done', 'AC-21: daemon_loop returns done');
        cmp_ok($elapsed, '<', 10, 'AC-21: the call finishes in under 10s (no H3 wait)');
        my $log = slurp("$abs_home/registry/lease.log");
        my @failed = ($log =~ /HANDOVER-FAILED reason=spawn-refused/g);
        is(scalar(@failed), 1, 'AC-21: exactly one HANDOVER-FAILED reason=spawn-refused line')
            or diag("lease.log:\n$log");
        my @ticks = ($log =~ /\bTICK\b/g);
        is(scalar(@ticks), 2, 'AC-21: exactly 2 TICK lines (max_iterations => 2)')
            or diag("lease.log:\n$log");
    }
}

# ===========================================================================
# Static checks (AC-7, AC-15, AC-18, AC-22)
# ===========================================================================
my $module_src = do { local $/; open(my $fh, '<:raw', $REPO_MODULE) or die $!; <$fh> };
my $kapl_src   = do { local $/; open(my $fh, '<:raw', $REPO_KEEPAWAKE_PL) or die $!; <$fh> };
my $ps1_src    = do { local $/; open(my $fh, '<:raw', $REPO_SANDBOX_PS1) or die $!; <$fh> };

# AC-7
{
    my ($term_block) = $module_src =~ /\$SIG\{TERM\}\s*=\s*(.{0,400})/s;
    my ($int_block)  = $module_src =~ /\$SIG\{INT\}\s*=\s*(.{0,400})/s;
    ok(defined($term_block) && defined($int_block), 'AC-7 sanity: both $SIG{TERM} and $SIG{INT} assignments are present');
    if (defined($term_block) && defined($int_block)) {
        my @term_calls = ($term_block =~ /(\$?\w+)\s*(?:->)?\s*\(/g);
        my @int_calls  = ($int_block  =~ /(\$?\w+)\s*(?:->)?\s*\(/g);
        my %int_seen = map { $_ => 1 } @int_calls;
        my @common = grep { $int_seen{$_} } @term_calls;
        ok(scalar(@common) > 0, 'AC-7: $SIG{TERM} and $SIG{INT} invoke at least one common subroutine (the release closure)')
            or diag('TERM calls: ' . join(',', @term_calls) . ' INT calls: ' . join(',', @int_calls));
    }

    my ($stop_helper_body) = $kapl_src =~ /\bsub\s+stop_helper\s*\{(.*?)\n\}\n/s;
    ok(defined($stop_helper_body), 'AC-7: sub stop_helper is locatable in bp-keepawake.pl');
    like($stop_helper_body // '', qr/\btaskkill\b/i, 'AC-7: stop_helper\'s body contains taskkill');
    like($stop_helper_body // '', qr/\btasklist\b/i, 'AC-7: stop_helper\'s body contains tasklist');
    unlike($stop_helper_body // '', qr/\bkill\s*\(/, 'AC-7: stop_helper\'s body has no kill( token');

    my ($kill_pid_body) = $kapl_src =~ /\bsub\s+kill_pid\s*\{(.*?)\n\}\n/s;
    ok(defined($kill_pid_body), 'AC-7 sanity: sub kill_pid is locatable');
    like($kill_pid_body // '', qr/\bstop_helper\s*\(/, 'AC-7: kill_pid calls stop_helper on the Windows branch');
}

# AC-15
{
    unlike($kapl_src, qr/-OwnerWinPid['"]?\s*,\s*(?:\$\$|getppid\s*\(\s*\)|\$pid\b)/,
        'AC-15: no -OwnerWinPid in bp-keepawake.pl is followed in the same statement by $$, getppid or $pid');
    my ($winpid_of_body) = $kapl_src =~ /\bsub\s+winpid_of\s*\{(.*?)\n\}\n/s;
    ok(defined($winpid_of_body), 'AC-15: sub winpid_of is locatable');
    like($winpid_of_body // '', qr{/proc/.*winpid}, 'AC-15: winpid_of reads a path matching /proc/ + /winpid');

    unlike($module_src, qr/owner_winpid\s*(?:=>|=)\s*(?:\$\$|getppid\s*\(\s*\))/,
        'AC-15: BpContinuityLease.pm never assigns owner_winpid from $$ or getppid');
    like($module_src, qr/owner_winpid.{0,120}(?:self_winpid|winpid_of)/s,
        'AC-15: the owner_winpid value passed comes from self_winpid or winpid_of')
        or like($module_src, qr/(?:self_winpid|winpid_of).{0,120}owner_winpid/s,
            'AC-15: (either ordering) self_winpid/winpid_of feeds owner_winpid');
}

# AC-18
{
    my $has_non_ascii = ($ps1_src =~ /[^\x00-\x7f]/) ? 1 : 0;
    ok(!$has_non_ascii, 'AC-18: keep-awake.ps1 contains no byte outside \\x00-\\x7f');
    my @addtype = ($ps1_src =~ /\bAdd-Type\b/g);
    is(scalar(@addtype), 1, 'AC-18: exactly one Add-Type call site');
    like($ps1_src, qr/\[string\]\s*\$OwnerDesc\s*=\s*['"]{2}/, "AC-18: [string]\$OwnerDesc = '' is declared");
    like($ps1_src, qr/\bREASON\b/, 'AC-18: the literal token REASON appears');
    for my $forbidden (qw(tasklist), 'Get-CimInstance', 'Get-WmiObject', 'Start-Process') {
        unlike($ps1_src, qr/\Q$forbidden\E/, "AC-18: '$forbidden' does not appear anywhere in the file");
    }
    my ($finally_block) = $ps1_src =~ /\bfinally\s*\{(.*?)Remove-Item/s;
    ok(defined($finally_block), 'AC-18: a finally block precedes a Remove-Item call');
    like($finally_block // '', qr/\$PID\b/, "AC-18: the text between finally and Remove-Item references \$PID (identity check)");
}

# AC-22
{
    like($module_src, qr/host refresher/, "AC-22: the module's header contains the words 'host refresher'");
    my ($spawn_daemon_body) = $module_src =~ /\bsub\s+_spawn_daemon\b(.*?)\n\}\n/s;
    ok(defined($spawn_daemon_body), 'AC-22 sanity: found the _spawn_daemon sub body');
    unlike($spawn_daemon_body // '', qr/bp-continuity/,
        'AC-22: _spawn_daemon no longer names the old continuity CLI (continuity-lease-daemon-entry.t check 3 still holds)');
}

# ===========================================================================
# AC-17(b) -- every START line this file's groups produced has dir= and
# live= under $R.
# ===========================================================================
{
    my $any_start_seen = 0;
    for my $log (@LEASE_LOGS) {
        my $text = slurp($log);
        # lease_log's own format prefixes every line with
        # "YYYY-MM-DD HH:MM:SS pid=<pid> ", so a START line never begins the
        # line at column 0 -- anchor on the token after pid=<n>, not the line
        # start. \bSTART\b alone would also match inside HANDOVER-START (the
        # hyphen is a word boundary too) -- a DIFFERENT event with no dir=
        # field at all, so it must be excluded, not merely "also matched".
        my @starts = ($text =~ /^(.*\bpid=\d+\s+START\b.*)$/mg);
        next unless @starts;
        $any_start_seen = 1;
        for my $line (@starts) {
            like($line, qr/\bdir=\S*\Q$R_FWD\E/i, "AC-17(b): START line's dir= is under \$R ($log)")
                or diag($line);
            like($line, qr/\blive=(?:unresolved|\S*\Q$R_FWD\E\S*)/i,
                "AC-17(b): START line's live= is either unresolved or under \$R ($log)")
                or diag($line);
        }
    }
    ok($any_start_seen, 'AC-17(b): at least one START line was produced by this file\'s groups')
        or diag('no lease.log in this run ever produced a START line -- expected while the feature is unimplemented');
}

# ===========================================================================
# AC-17(c) -- read-only: the operator's REAL registry lease.log (if any)
# never names $R.
# ===========================================================================
{
    SKIP: {
        skip 'AC-17(c): no real HOME/USERPROFILE resolvable in this environment', 1 unless defined $REAL_HOME;
        my $real_log = "$REAL_HOME/.claude/ccpraxis/.continuity-active/lease.log";
        skip "AC-17(c): the operator's real lease.log does not exist -- nothing to check", 1
            unless -f $real_log;
        my $real_text = slurp($real_log);
        unlike($real_text, qr/\Q$R_FWD\E/i,
            "AC-17(c): the operator's real lease.log never mentions this test's scratch root");
    }
}

# ===========================================================================
# Regression: after every block's own cleanup has run, but BEFORE END's
# global backstop, no process this file could have spawned is still alive
# and naming this file's scratch root -- in EITHER short or long form. This
# is what the sweep audit caught: a live keep-awake.ps1 and its perl parent
# survived a whole run because force_kill_winpid's single-form substring
# check silently skipped them. A short retry loop, not a single sample:
# taskkill is asynchronous, and the point here is per-block cleanup
# correctness, not a race against Windows's own teardown latency.
# ===========================================================================
{
    my $found = 0;
    for (1 .. 10) {
        $found = any_process_naming_root($R_FWD);
        last unless $found;
        sleep(1);
    }
    ok(!$found,
        'regression: no process whose command line names this file\'s scratch root (short or long form) is still alive before END runs');
}

# ===========================================================================
# AC-19 [validation]: run from disk by the coordinator, not re-implemented
# here -- each listed file's own oracle is authoritative for its own ACs.
# ===========================================================================
pass('AC-19 [validation]: keepawake-lease-liveness.t, execution-power-request.t, '
   . 'test-wakelock-hygiene.t, keepawake-no-process-storm.t, keepawake-shared.t, '
   . 'continuity-lease-follows-arm.t, continuity-lease-daemon-entry.t, '
   . 'continuity-lease-liveness.t, the powershell-syntax check and perl -c on both '
   . 'perl files are run directly from disk by the coordinator, per the spec\'s '
   . '[validation] marker -- not duplicated in-process here');

done_testing();
