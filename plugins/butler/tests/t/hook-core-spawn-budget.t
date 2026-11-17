#!/usr/bin/env perl
# platform: any
# IMMUTABLE ORACLE for package 03-hook-core (blueprint hook-continuity-remake),
# S1-S9 of specs/03-hook-core-spec.md (DC2): run-hook.sh's process budget,
# measured with a PATH shim that logs every bash/perl/jq launch.
#
# run-hook.sh and BpHook.pm DO NOT EXIST YET at the time this file is
# written. build_tree() below copies them into a scratch tree; when the
# source is absent, the copy leaves the destination missing too, so fx.sh's
# own "[ -f run-hook.sh ] || exit 0" guard fires immediately and every test
# expecting a perl launch fails legibly ("expected 1, got 0"), never with a
# shell 127 or a perl crash. S7 (the real in-repo run-hook.sh) fails its own
# precondition check first, with a clear diagnostic, when the file is
# missing.
#
# Every subprocess this file starts goes through run_shim(), which bounds
# itself with the shell "timeout" utility AND a perl alarm() as a hard
# backstop, and every fifo-writer child (S1, S6) is pushed onto @KILL_PIDS,
# reaped by the END block below (routed through exit() so it always runs).
# Nothing in this file spawns plugins/sandbox/scripts/launcher.pl, and
# nothing here registers anything.
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Spec ();
use POSIX qw(_exit);
use Cwd qw(getcwd);

my $BUTLER_DIR      = "$Bin/../..";                                  # plugins/butler
my $REAL_RUN_HOOK    = "$BUTLER_DIR/hooks/run-hook.sh";
my $REAL_READ_LIB    = "$BUTLER_DIR/scripts/read-payload.sh";     # sourced by run-hook.sh
my $REAL_BPHOOK      = "$BUTLER_DIR/scripts/BpHook.pm";
my $REAL_BPPROJROOT  = "$BUTLER_DIR/scripts/BpProjectRoot.pm";

# ---------------------------------------------------------------------------
# H(name, @args) -- same seam as hook-core-api.t: call BpHook::<name>
# in-process (used only to arm fixture sessions ahead of a subprocess run),
# catching a missing module/sub instead of crashing this file.
# ---------------------------------------------------------------------------
my $HOOK_LOAD_ERR;
{
    local $@;
    my $ok = eval { require $REAL_BPHOOK; 1 };
    $HOOK_LOAD_ERR = $@ unless $ok;
}
diag("BpHook.pm did not load cleanly (expected until package 03 is implemented): "
   . ($HOOK_LOAD_ERR // 'unknown error')) if $HOOK_LOAD_ERR;

sub H {
    my ($name, @args) = @_;
    my $code; { no strict 'refs'; $code = \&{"BpHook::$name"} }
    my $ret;
    my $ok = eval { $ret = $code->(@args); 1 };
    return $ok ? $ret : undef;
}

sub scrub_env {
    delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
}

sub read_bytes {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

my $ANDRE = "Andr\xC3\xA9"; # raw UTF-8 bytes, matches hook-core-api.t's convention.
sub fresh_state_root { my $t = tempdir(CLEANUP => 1); return "$t/state" }
sub andre_state_root { my $t = tempdir(CLEANUP => 1); return "$t/$ANDRE/state" }

# The ONE real, un-shimmed bash on this host, resolved via the ORIGINAL PATH
# (before any shim dir is ever prepended). Used only to DRIVE each run (the
# harness's own launch of the hook file), never logged and never counted --
# exactly as Claude Code's own harness launch of a registered hook file is
# not itself one of the measured hops.
my $REAL_BASH_ABS = do {
    my $p = `bash -c "command -v bash"`;
    chomp $p;
    $p;
};
BAIL_OUT('cannot resolve a real bash on PATH -- required for every fixture in this file')
    unless length $REAL_BASH_ABS;

# The ONE real "timeout" utility, resolved via the ORIGINAL PATH, exactly
# like $REAL_BASH_ABS above. run_shim()'s own driver invocation runs under
# whatever %ENV{PATH} a given test supplies (S5f sets PATH to *only* the
# shim dir, deliberately, to prove there is no perl on it) -- a bare
# "timeout" in that driver command would resolve against that same
# restricted PATH and fail with 127 before the script under test ever
# starts. Resolving it once, up front, from the original PATH avoids that.
my $REAL_TIMEOUT_ABS = do {
    my $p = `bash -c "command -v timeout"`;
    chomp $p;
    $p;
};
BAIL_OUT('cannot resolve a real timeout utility on PATH -- required for every fixture in this file')
    unless length $REAL_TIMEOUT_ABS;

# The ONE real perl, resolved to an ABSOLUTE path via the ORIGINAL PATH (or
# $Config{perlpath} as a fallback), for use inside the perl shim script
# build_shim() writes. $^X is "perl" (bareword, not absolute) when this file
# is run the documented way (`perl plugins/.../hook-core-spawn-budget.t`),
# and a shim whose "exec $^X ..." re-resolves "perl" against the shim dir's
# OWN PATH prefix loops back into itself instead of the real interpreter.
use Config ();
my $REAL_PERL_ABS = do {
    my $p;
    if (File::Spec->file_name_is_absolute($^X) && -x $^X) {
        $p = $^X;
    } else {
        require Config;
        my $found = `bash -c "command -v perl"`;
        chomp $found;
        $p = (length $found && -x $found) ? $found : $Config::Config{perlpath};
    }
    $p;
};
BAIL_OUT('cannot resolve a real perl to an absolute path -- required for every fixture in this file')
    unless length $REAL_PERL_ABS;
# Asserted up front, before any shim dir exists (each is a fresh tempdir
# created later, per build_shim() call) -- so "resolved from the shim dir"
# is not yet possible at this point in the file.
ok(File::Spec->file_name_is_absolute($REAL_PERL_ABS),
   'setup: the real perl resolved to an absolute path');
unlike($REAL_PERL_ABS, qr/^\Q$Bin\E/,
   "setup: the real perl's path is not under this test file's own directory");

# ---------------------------------------------------------------------------
# process bookkeeping -- fifo-writer children (S1, S6).
# ---------------------------------------------------------------------------
my @KILL_PIDS;
END {
    for my $pid (@KILL_PIDS) { next unless $pid; kill('TERM', $pid) }
    if (@KILL_PIDS) {
        select(undef, undef, undef, 0.3);
        for my $pid (@KILL_PIDS) { next unless $pid; kill('KILL', $pid) if kill(0, $pid) }
        for my $pid (@KILL_PIDS) { next unless $pid; local $@; eval { waitpid($pid, 0) } }
    }
    $? = 0;
}
$SIG{$_} = sub { exit 1 } for qw(TERM INT HUP);

# ---------------------------------------------------------------------------
# copy_file(src, dst) -- best-effort byte copy. When src does not exist
# (BpHook.pm / run-hook.sh, before package 03 is implemented), dst is simply
# left missing, and every downstream fx.sh run legibly fails to find a
# perl launch it expected.
# ---------------------------------------------------------------------------
sub copy_file {
    my ($src, $dst) = @_;
    make_path(File::Spec->catpath((File::Spec->splitpath($dst))[0, 1], ''));
    return unless -f $src;
    open my $in, '<:raw', $src or return;
    open my $out, '>:raw', $dst or do { close $in; return };
    local $/;
    print {$out} scalar(<$in>);
    close $in;
    close $out;
    chmod 0755, $dst;
}

# ---------------------------------------------------------------------------
# build_tree() -- T/plugins/butler/{hooks/next/{run-hook.sh (copy),
# guards/fx.sh}, scripts/{BpHook.pm (copy), BpProjectRoot.pm (copy),
# read-payload.sh (copy, the payload reader run-hook.sh sources),
# BpHook/SpawnFx.pm}}. fx.sh is the architecture's hook-file shape,
# parameterised so each test can supply its own --pre clauses.
# ---------------------------------------------------------------------------
sub build_tree {
    my $T = tempdir(CLEANUP => 1);
    make_path("$T/plugins/butler/hooks/next/guards");
    make_path("$T/plugins/butler/scripts/BpHook");

    copy_file($REAL_RUN_HOOK,   "$T/plugins/butler/hooks/next/run-hook.sh");
    copy_file($REAL_READ_LIB,   "$T/plugins/butler/scripts/read-payload.sh");
    copy_file($REAL_BPHOOK,     "$T/plugins/butler/scripts/BpHook.pm");
    copy_file($REAL_BPPROJROOT, "$T/plugins/butler/scripts/BpProjectRoot.pm");

    write_spawn_fx($T, <<'PERL');
package BpHook::SpawnFx;
sub run {
    my ($p, @args) = @_;
    my $log = $ENV{SPAWN_FX_LOG};
    if (defined $log && open(my $fh, '>>', $log)) {
        BpHook::payload();
        BpHook::payload();
        print {$fh} join(' ',
            'parse_count=' . (BpHook::parse_count() // ''),
            'payload_ok='  . (BpHook::payload_ok() ? 1 : 0),
            'truncated='   . ($ENV{BP_PAYLOAD_TRUNCATED} // ''),
            'args=' . join(',', @args),
        ) . "\n";
        close $fh;
    }
    my $rc = $ENV{SPAWN_FX_RC};
    if (defined $rc && $rc == 2) {
        print STDERR "SpawnFx stderr line\n";
    }
    return defined $rc ? $rc + 0 : 0;
}
1;
PERL

    open my $fxh, '>', "$T/plugins/butler/hooks/next/guards/fx.sh" or die $!;
    print {$fxh} <<'SH';
#!/usr/bin/env bash
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/../run-hook.sh" ] || d=${d%/*}
[ -f "$d/../run-hook.sh" ] || exit 0
exec bash "$d/../run-hook.sh" SpawnFx "$@"
SH
    close $fxh;
    chmod 0755, "$T/plugins/butler/hooks/next/guards/fx.sh";

    return $T;
}

sub write_spawn_fx {
    my ($T, $content) = @_;
    open my $fh, '>', "$T/plugins/butler/scripts/BpHook/SpawnFx.pm" or die $!;
    print {$fh} $content;
    close $fh;
}

# ---------------------------------------------------------------------------
# build_shim() -- a temp dir with bash/perl/jq shims. Each is a bash script
# (shebang #!<real bash>) that logs 'name pid' to $SHIM_LOG then execs the
# real binary by absolute path; jq just logs and exits 0 (never exec'd for
# real -- nothing in this package's contract calls jq).
# ---------------------------------------------------------------------------
sub build_shim {
    my $shim = tempdir(CLEANUP => 1);
    for my $pair ([bash => $REAL_BASH_ABS], [perl => $REAL_PERL_ABS]) {
        my ($name, $real) = @$pair;
        open my $fh, '>', "$shim/$name" or die $!;
        print {$fh} "#!$REAL_BASH_ABS\n";
        print {$fh} "printf '%s %s\\n' '$name' \"\$\$\" >> \"\$SHIM_LOG\"\n";
        print {$fh} "exec \"$real\" \"\$\@\"\n";
        close $fh;
        chmod 0755, "$shim/$name";
    }
    open my $jfh, '>', "$shim/jq" or die $!;
    print {$jfh} "#!$REAL_BASH_ABS\n";
    print {$jfh} "printf '%s %s\\n' 'jq' \"\$\$\" >> \"\$SHIM_LOG\"\n";
    print {$jfh} "exit 0\n";
    close $jfh;
    chmod 0755, "$shim/jq";
    return $shim;
}

# ---------------------------------------------------------------------------
# run_shim(%opt) -- drives $shim_dir/bash <script> @args via the ONE real,
# un-shimmed bash, with $ENV{PATH} arranged so the script's OWN internal
# "exec bash ..." / "exec perl ..." bareword lookups resolve to the shims.
# Bounded by both the shell "timeout" utility and a perl alarm() backstop.
# ---------------------------------------------------------------------------
sub run_shim {
    my (%opt) = @_;
    my $script     = $opt{script};
    my $args       = $opt{args} // [];
    my $env        = $opt{env} // {};
    my $stdin_path = $opt{stdin_path};
    my $timeout    = $opt{timeout} // 15;
    my $shim_dir   = $opt{shim_dir} // build_shim();

    my ($lfh, $shim_log_path) = tempfile(); close $lfh; unlink $shim_log_path;
    my ($ofh, $out_path) = tempfile(); close $ofh;
    my ($efh, $err_path) = tempfile(); close $efh;

    local %ENV = %ENV;
    scrub_env();
    for my $k (keys %$env) {
        if (defined $env->{$k}) { $ENV{$k} = $env->{$k} } else { delete $ENV{$k} }
    }
    $ENV{SHIM_LOG} = $shim_log_path;
    unless (exists $env->{PATH}) {
        $ENV{PATH} = "$shim_dir:$ENV{PATH}";
    }

    my @inner_cmd = ("$shim_dir/bash", $script, @$args);
    my $inner = join(' ', map { qq("$_") } @inner_cmd);
    $inner = "$REAL_TIMEOUT_ABS $timeout $inner";
    $inner .= defined $stdin_path ? qq( < "$stdin_path") : ' < /dev/null';
    $inner .= qq( > "$out_path" 2> "$err_path");

    local $SIG{ALRM} = sub { die "run_shim: hard alarm backstop exceeded\n" };
    alarm($timeout + 15);
    system($REAL_BASH_ABS, '-c', $inner);
    my $rc = ($? == -1) ? -1 : ($? >> 8);
    alarm(0);

    return {
        rc       => $rc,
        out      => read_bytes($out_path)      // '',
        err      => read_bytes($err_path)      // '',
        shim_log => read_bytes($shim_log_path) // '',
        shim_dir => $shim_dir,
    };
}

sub count_lines { my ($log, $prefix) = @_; return scalar(grep { /^\Q$prefix\E / } split /\n/, $log) }

sub has_mkfifo { return system('bash', '-c', 'command -v mkfifo >/dev/null 2>&1') == 0 }

sub spawn_fifo_writer {
    my ($fifo, $prewrite) = @_;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDOUT, '>', File::Spec->devnull);
        open(STDERR, '>', File::Spec->devnull);
        if (defined $prewrite && length $prewrite) {
            exec($REAL_BASH_ABS, '-c', 'exec 3>"$1"; printf "%s" "$2" >&3; sleep 30',
                 'writer', $fifo, $prewrite) or POSIX::_exit(127);
        } else {
            exec($REAL_BASH_ABS, '-c', 'exec 3>"$1"; sleep 30', 'writer', $fifo)
                or POSIX::_exit(127);
        }
    }
    push @KILL_PIDS, $pid;
    return $pid;
}

# ===========================================================================
# S1 -- --pre ledger with BP_LEDGER unset, stdin a fifo whose writer never
# writes or closes: exit 0 under a 9s alarm, 0 perl, 0 jq, no SPAWN_FX_LOG,
# every logged pid equal.
# ===========================================================================
{
    my $T  = build_tree();
    my $fx = "$T/plugins/butler/hooks/next/guards/fx.sh";

  SKIP: {
        skip 'S1: no mkfifo on this host', 5 unless has_mkfifo();
        my $tmp  = tempdir(CLEANUP => 1);
        my $fifo = "$tmp/s1.fifo";
        (system('bash', '-c', qq(mkfifo "$fifo")) == 0)
            or skip('S1: mkfifo failed', 5);
        spawn_fifo_writer($fifo);

        my ($lfh, $fxlog) = tempfile(); close $lfh; unlink $fxlog;
        local $SIG{ALRM} = sub { die "S1 alarm: run exceeded 9s\n" };
        alarm(9);
        my $res = eval {
            run_shim(script => $fx, args => ['--pre', 'ledger'],
                     env => {BP_PAYLOAD_READ_TIMEOUT => 10, SPAWN_FX_LOG => $fxlog},
                     stdin_path => $fifo, timeout => 8);
        };
        alarm(0);
        ok(!$@, 'S1: the run completed within the 9s alarm bound') or diag($@);
        SKIP: {
            skip 'S1: run_shim did not return (see alarm diag above)', 4 unless ref($res) eq 'HASH';
            is($res->{rc}, 0, 'S1: exits 0');
            is(count_lines($res->{shim_log}, 'perl'), 0, 'S1: 0 perl launches');
            is(count_lines($res->{shim_log}, 'jq'),   0, 'S1: 0 jq launches');
            ok(!-e $fxlog, 'S1: no SPAWN_FX_LOG file created (SpawnFx::run never invoked)');
            my @bash_lines = grep { /^bash / } split /\n/, $res->{shim_log};
            my %pids = map { (split ' ', $_)[1] => 1 } @bash_lines;
            is(scalar(keys %pids), @bash_lines ? 1 : 0, 'S1: every logged pid is equal (one bash lineage)');
        }
    }
}

# ===========================================================================
# S2 -- not-applies cases: exit 0, 0 perl, 0 jq, at most 2 bash lines.
# ===========================================================================
{
    my $T  = build_tree();
    my $fx = "$T/plugins/butler/hooks/next/guards/fx.sh";
    my $root = fresh_state_root();
    {
        local %ENV = %ENV; scrub_env();
        $ENV{BUTLER_STATE_DIR} = $root;
        H('arm', 'S2B', role => 'manual', by => 'arm-on-entry');
    }

    my @cases = (
        ['ledger,armed with a valid sid and no arm file' => 'ledger,armed', {}, '{"session_id":"S2A"}'],
        ['ledger,driver with armed/<sid> role manual'     => 'ledger,driver', {}, '{"session_id":"S2B"}'],
        ['text:butler-hold with a payload that lacks it'  => 'text:butler-hold', {}, '{"session_id":"S2C"}'],
        ['coordinator with BP_ROLE=judge'                 => 'coordinator', {BP_LEDGER => '/x.md', BP_ROLE => 'judge'},
         '{"session_id":"S2D"}'],
    );
    for my $c (@cases) {
        my ($label, $pre, $extra_env, $payload_json) = @$c;
        my ($pfh, $ppath) = tempfile(); print {$pfh} $payload_json; close $pfh;
        my %env = (%$extra_env, BUTLER_STATE_DIR => $root);
        my $res = run_shim(script => $fx, args => ['--pre', $pre], env => \%env,
                            stdin_path => $ppath, timeout => 10);
        is($res->{rc}, 0, "S2: $label -> exits 0");
        is(count_lines($res->{shim_log}, 'perl'), 0, "S2: $label -> 0 perl launches");
        is(count_lines($res->{shim_log}, 'jq'),   0, "S2: $label -> 0 jq launches");
        my @bash_lines = grep { /^bash / } split /\n/, $res->{shim_log};
        cmp_ok(scalar(@bash_lines), '<=', 2, "S2: $label -> at most 2 bash lines");
    }
}

# ===========================================================================
# S3 -- fall-through with no session_id and --pre ledger,armed: exactly 1
# perl, same pid as the bash lines, 0 jq, parse_count 1, exit 0.
# ===========================================================================
{
    my $T  = build_tree();
    my $fx = "$T/plugins/butler/hooks/next/guards/fx.sh";
    my $root = fresh_state_root();
    my ($pfh, $ppath) = tempfile(); print {$pfh} '{"hook_event_name":"PreToolUse"}'; close $pfh;
    my ($lfh, $fxlog) = tempfile(); close $lfh; unlink $fxlog;

    my $res = run_shim(script => $fx, args => ['--pre', 'ledger,armed'],
                        env => {BUTLER_STATE_DIR => $root, SPAWN_FX_LOG => $fxlog},
                        stdin_path => $ppath, timeout => 10);
    is($res->{rc}, 0, 'S3: fall-through (no session_id) with ledger,armed -> exit 0');
    is(count_lines($res->{shim_log}, 'perl'), 1, 'S3: exactly 1 perl launch');
    is(count_lines($res->{shim_log}, 'jq'),   0, 'S3: 0 jq launches');
    my @perl_lines = grep { /^perl / } split /\n/, $res->{shim_log};
    my @bash_lines = grep { /^bash / } split /\n/, $res->{shim_log};
    my %pids = map { (split ' ', $_)[1] => 1 } (@perl_lines, @bash_lines);
    is(scalar(keys %pids), 1, 'S3: the perl launch is in the same pid as the bash lines');
    like(read_bytes($fxlog) // '', qr/parse_count=1\b/, 'S3: SpawnFx observed parse_count 1');
}

# ===========================================================================
# S4 -- applies path: 1 perl, parse_count 1, run receives the hook args;
# SPAWN_FX_RC=2 gives exit 2 with the fixture's STDERR; SPAWN_FX_RC=0 gives 0.
# ===========================================================================
{
    my $root = fresh_state_root();
    {
        local %ENV = %ENV; scrub_env();
        $ENV{BUTLER_STATE_DIR} = $root;
        H('arm', 'S4', role => 'manual', by => 'arm-on-entry');
    }
    my ($pfh, $ppath) = tempfile(); print {$pfh} '{"session_id":"S4"}'; close $pfh;

    {
        my $T  = build_tree();
        my $fx = "$T/plugins/butler/hooks/next/guards/fx.sh";
        my ($lfh, $fxlog) = tempfile(); close $lfh; unlink $fxlog;
        my $res = run_shim(script => $fx, args => ['--pre', 'armed', '--', 'hookargA', 'hookargB'],
                            env => {BUTLER_STATE_DIR => $root, SPAWN_FX_LOG => $fxlog, SPAWN_FX_RC => 0},
                            stdin_path => $ppath, timeout => 10);
        is(count_lines($res->{shim_log}, 'perl'), 1, 'S4: applies path runs exactly 1 perl');
        my $fxlog_content = read_bytes($fxlog) // '';
        like($fxlog_content, qr/parse_count=1\b/, 'S4: parse_count 1');
        like($fxlog_content, qr/args=hookargA,hookargB/, 'S4: run receives the hook args');
        is($res->{rc}, 0, 'S4: SPAWN_FX_RC=0 gives exit 0');
    }
    {
        my $T  = build_tree();
        my $fx = "$T/plugins/butler/hooks/next/guards/fx.sh";
        my $res = run_shim(script => $fx, args => ['--pre', 'armed', '--', 'x'],
                            env => {BUTLER_STATE_DIR => $root, SPAWN_FX_RC => 2},
                            stdin_path => $ppath, timeout => 10);
        is($res->{rc}, 2, 'S4: SPAWN_FX_RC=2 gives exit 2');
        like($res->{err}, qr/SpawnFx stderr line/, "S4: ...with the fixture's STDERR passed through");
    }
}

# ===========================================================================
# S5 -- fail-open: every case below exits 0.
# ===========================================================================
{
    my $root = fresh_state_root();
    {
        local %ENV = %ENV; scrub_env();
        $ENV{BUTLER_STATE_DIR} = $root;
        H('arm', 'S5', role => 'manual', by => 'arm-on-entry');
    }
    my ($pfh, $ppath) = tempfile(); print {$pfh} '{"session_id":"S5"}'; close $pfh;

    { # (a) the fixture dies
        my $T = build_tree();
        write_spawn_fx($T, "package BpHook::SpawnFx;\nsub run { die \"S5 boom\\n\" }\n1;\n");
        my $fx = "$T/plugins/butler/hooks/next/guards/fx.sh";
        my $res = run_shim(script => $fx, args => ['--pre', 'armed'],
                            env => {BUTLER_STATE_DIR => $root}, stdin_path => $ppath, timeout => 10);
        is($res->{rc}, 0, 'S5a: the fixture dies -> exit 0');
    }
    { # (b) the fixture calls exit 2 itself
        my $T = build_tree();
        write_spawn_fx($T, "package BpHook::SpawnFx;\nsub run { exit(2) }\n1;\n");
        my $fx = "$T/plugins/butler/hooks/next/guards/fx.sh";
        my $res = run_shim(script => $fx, args => ['--pre', 'armed'],
                            env => {BUTLER_STATE_DIR => $root}, stdin_path => $ppath, timeout => 10);
        is($res->{rc}, 0, 'S5b: the fixture calls exit(2) itself -> exit 0 (the END block forces it)');
    }
    { # (c) SPAWN_FX_RC=3
        my $T  = build_tree();
        my $fx = "$T/plugins/butler/hooks/next/guards/fx.sh";
        my $res = run_shim(script => $fx, args => ['--pre', 'armed'],
                            env => {BUTLER_STATE_DIR => $root, SPAWN_FX_RC => 3},
                            stdin_path => $ppath, timeout => 10);
        is($res->{rc}, 0, 'S5c: SPAWN_FX_RC=3 -> exit 0 (only exactly 2 blocks)');
    }
    { # (d) BpHook.pm replaced by one that requires a missing module
        my $T = build_tree();
        open my $fh, '>', "$T/plugins/butler/scripts/BpHook.pm" or die $!;
        print {$fh} "package BpHook;\nsub main { require No::Such::Mod; return 0 }\n1;\n";
        close $fh;
        my $fx = "$T/plugins/butler/hooks/next/guards/fx.sh";
        my $res = run_shim(script => $fx, args => ['--pre', 'armed'],
                            env => {BUTLER_STATE_DIR => $root}, stdin_path => $ppath, timeout => 10);
        is($res->{rc}, 0, 'S5d: BpHook.pm requiring a missing module -> exit 0');
    }
    { # (e) BpHook.pm removed -> 0 perl
        my $T = build_tree();
        unlink "$T/plugins/butler/scripts/BpHook.pm";
        my $fx = "$T/plugins/butler/hooks/next/guards/fx.sh";
        my $res = run_shim(script => $fx, args => ['--pre', 'armed'],
                            env => {BUTLER_STATE_DIR => $root}, stdin_path => $ppath, timeout => 10);
        is($res->{rc}, 0, 'S5e: BpHook.pm removed -> exit 0');
        is(count_lines($res->{shim_log}, 'perl'), 0, 'S5e: ...and 0 perl launches');
    }
    { # (f) PATH with only the bash shim (no perl anywhere)
        my $T = build_tree();
        my $fx = "$T/plugins/butler/hooks/next/guards/fx.sh";
        my $shim_dir = build_shim();
        unlink "$shim_dir/perl";
        my $res = run_shim(script => $fx, args => ['--pre', 'armed'],
                            env => {BUTLER_STATE_DIR => $root, PATH => $shim_dir},
                            stdin_path => $ppath, timeout => 10, shim_dir => $shim_dir);
        is($res->{rc}, 0, 'S5f: PATH with only the bash shim (no perl) -> exit 0');
    }
    { # (g) run-hook.sh invoked with no args
        my $T = build_tree();
        my $run_hook = "$T/plugins/butler/hooks/next/run-hook.sh";
        my $res = run_shim(script => $run_hook, args => [],
                            env => {BUTLER_STATE_DIR => $root}, stdin_path => undef, timeout => 10);
        is($res->{rc}, 0, 'S5g: run-hook.sh invoked with no args -> exit 0');
    }
}

# ===========================================================================
# S6 -- bounded read: a fifo writer sends a partial payload and holds the
# fifo open. The run returns under a 25s alarm, 1 perl runs, and the fixture
# observes payload_ok 0 / BP_PAYLOAD_TRUNCATED 1. Neither run-hook.sh nor the
# scripts/read-payload.sh it sources has $(cat or a bare pipe; the library has
# read -r -N 8388608 -t, and -d '' only as its bash < 4.1 fallback.
# ===========================================================================
{
    my $T  = build_tree();
    my $fx = "$T/plugins/butler/hooks/next/guards/fx.sh";
    my $root = fresh_state_root();

  SKIP: {
        skip 'S6: no mkfifo on this host', 3 unless has_mkfifo();
        my $tmp  = tempdir(CLEANUP => 1);
        my $fifo = "$tmp/s6.fifo";
        (system('bash', '-c', qq(mkfifo "$fifo")) == 0)
            or skip('S6: mkfifo failed', 3);
        spawn_fifo_writer($fifo, '{"session_id":"');

        my ($lfh, $fxlog) = tempfile(); close $lfh; unlink $fxlog;
        local $SIG{ALRM} = sub { die "S6 alarm: run exceeded 25s\n" };
        alarm(25);
        my $res = eval {
            run_shim(script => $fx, args => ['--pre', 'text:never-there'],
                     env => {BUTLER_STATE_DIR => $root, BP_PAYLOAD_READ_TIMEOUT => 2, SPAWN_FX_LOG => $fxlog},
                     stdin_path => $fifo, timeout => 20);
        };
        alarm(0);
        ok(!$@, 'S6: the run returns within the 25s alarm') or diag($@);
        SKIP: {
            skip 'S6: run_shim did not return (see alarm diag above)', 3 unless ref($res) eq 'HASH';
            is(count_lines($res->{shim_log}, 'perl'), 1,
               'S6: exactly 1 perl runs (armed/driver/text: fall through on truncation)');
            my $fxlog_content = read_bytes($fxlog) // '';
            like($fxlog_content, qr/payload_ok=0\b/,  'S6: SpawnFx observed payload_ok 0');
            like($fxlog_content, qr/truncated=1\b/,   'S6: SpawnFx observed BP_PAYLOAD_TRUNCATED 1');
        }
    }

    # The read itself lives in scripts/read-payload.sh, which run-hook.sh sources
    # (no process) -- so the source rules cover both files: neither may cat
    # stdin or contain a bare pipe, and the bulk -N read must be there.
    # read -d '' survives only as the library's bash < 4.1 fallback (stock
    # macOS /bin/bash 3.2 has no -N), selected by BASH_VERSINFO.
    my $src = read_bytes($REAL_RUN_HOOK) // '';
    $src =~ s/#.*$//mg;
    my $lib = read_bytes($REAL_READ_LIB) // '';
    $lib =~ s/#.*$//mg;
    like($src, qr{\.\s+"\$s/read-payload\.sh"}, 'S6: run-hook.sh sources read-payload.sh from the scripts dir it loads BpHook.pm from');
    like($src, qr/\bccp_read_payload\s+BP_PAYLOAD\b/, 'S6: run-hook.sh reads the payload with ccp_read_payload BP_PAYLOAD');
    unlike($src, qr/\bread\b[^\n]*\s-[Nd]\s/, 'S6: run-hook.sh keeps no stdin read of its own');
    for my $pair (['run-hook.sh', $src], ['scripts/read-payload.sh', $lib]) {
        my ($name, $text) = @$pair;
        unlike($text, qr/\$\(cat/, "S6: $name source has no \$(cat");
        unlike($text, qr/(?<!\|)\|(?!\|)/, "S6: $name source has no bare pipe (as opposed to ||)");
    }
    like($lib, qr/read\s+-r\s+-N\s+8388608\s+-t/, 'S6: scripts/read-payload.sh has read -r -N 8388608 -t');
    my @delims = ($lib =~ /\bread\b[^\n]*?\s-d\s+(\S+)/g);
    is_deeply([grep { $_ ne q{''} } @delims], [], q{S6: the library's only delimiter read is -d '' (to end of input)});
}

# ===========================================================================
# S7 -- the real in-repo run-hook.sh: NoSuchFx --pre ledger -- exits 0 with
# 0 perl when BP_LEDGER is unset; NoSuchFx -- exits 0 with 1 perl and one
# hook-errors.log line; an empty payload gives exit 0 in both cases.
# ===========================================================================
{
    ok(-f $REAL_RUN_HOOK, 'S7 precondition: the real run-hook.sh exists')
        or diag("missing: $REAL_RUN_HOOK (package 03 has not written it yet)");
    my $root = fresh_state_root();

    my ($pfh1, $ppath1) = tempfile(); print {$pfh1} '{"session_id":"S7A"}'; close $pfh1;
    my $res1 = run_shim(script => $REAL_RUN_HOOK, args => ['NoSuchFx', '--pre', 'ledger', '--'],
                         env => {BUTLER_STATE_DIR => $root}, stdin_path => $ppath1, timeout => 10);
    is($res1->{rc}, 0, 'S7: NoSuchFx --pre ledger -- exits 0 when BP_LEDGER is unset');
    is(count_lines($res1->{shim_log}, 'perl'), 0, 'S7: ...with 0 perl launches');

    my ($pfh2, $ppath2) = tempfile(); print {$pfh2} '{"session_id":"S7B"}'; close $pfh2;
    my $errlog = "$root/continuity/hook-errors.log";
    my $res2 = run_shim(script => $REAL_RUN_HOOK, args => ['NoSuchFx', '--'],
                         env => {BUTLER_STATE_DIR => $root}, stdin_path => $ppath2, timeout => 10);
    is($res2->{rc}, 0, 'S7: NoSuchFx -- exits 0 with 1 perl');
    is(count_lines($res2->{shim_log}, 'perl'), 1, 'S7: ...with exactly 1 perl launch');
    like(read_bytes($errlog) // '', qr/NoSuchFx/, 'S7: one NoSuchFx line landed in hook-errors.log');

    my ($pfh3, $ppath3) = tempfile(); close $pfh3; # empty payload
    my $res3 = run_shim(script => $REAL_RUN_HOOK, args => ['NoSuchFx', '--pre', 'ledger', '--'],
                         env => {BUTLER_STATE_DIR => $root}, stdin_path => $ppath3, timeout => 10);
    is($res3->{rc}, 0, 'S7: an empty payload gives exit 0 (ledger-clause path, Decision 38)');
    my $res4 = run_shim(script => $REAL_RUN_HOOK, args => ['NoSuchFx', '--'],
                         env => {BUTLER_STATE_DIR => $root}, stdin_path => $ppath3, timeout => 10);
    is($res4->{rc}, 0, 'S7: an empty payload gives exit 0 (applies-path, Decision 38)');
}

# ===========================================================================
# S8 -- state-root parity: an André-rooted BUTLER_STATE_DIR sees a real
# BpHook::arm-written file and runs perl; a relative BUTLER_STATE_DIR exits
# in bash.
# ===========================================================================
{
    my $T  = build_tree();
    my $fx = "$T/plugins/butler/hooks/next/guards/fx.sh";
    my $andre_root = andre_state_root();
    {
        local %ENV = %ENV; scrub_env();
        $ENV{BUTLER_STATE_DIR} = $andre_root;
        H('arm', 'S8', role => 'manual', by => 'arm-on-entry');
    }
    my ($pfh, $ppath) = tempfile(); print {$pfh} '{"session_id":"S8"}'; close $pfh;

    my $res = run_shim(script => $fx, args => ['--pre', 'ledger,armed'],
                        env => {BUTLER_STATE_DIR => $andre_root}, stdin_path => $ppath, timeout => 10);
    is(count_lines($res->{shim_log}, 'perl'), 1,
       "S8: an Andr\x{e9}-rooted BUTLER_STATE_DIR sees the BpHook::arm-written file and runs perl");

    my $res2 = run_shim(script => $fx, args => ['--pre', 'ledger,armed'],
                         env => {BUTLER_STATE_DIR => 'rel/x'}, stdin_path => $ppath, timeout => 10);
    is($res2->{rc}, 0, 'S8: BUTLER_STATE_DIR=rel/x exits in bash');
    is(count_lines($res2->{shim_log}, 'perl'), 0, 'S8: ...with 0 perl launches');
}

# ===========================================================================
# R2-n2/L8 -- a --pre clause atom containing a glob character is never
# glob-expanded against the wrapper's cwd (review n2 / redteam L8;
# run-hook.sh:52,69,165's unquoted "for atom in $clause", both declined in
# fix-batch.md: "set -f ... is a behavioural change to the early-exit path
# with no S-case asserting it").
#
# Repro: the atom "text:*" is the clause micro-language's own
# "text:<needle>" syntax; a literal "*" needle should search BP_PAYLOAD for
# a literal asterisk character. But "for atom in $clause" is unquoted, so
# bash's implicit pathname expansion runs on it too: if the wrapper's cwd
# holds a file whose name matches the pattern "text:*" (built here as
# "text:contains-pwned-substring"), the atom silently becomes that
# filename BEFORE the "text:" prefix is stripped, so the needle becomes
# "contains-pwned-substring" instead of the literal "*" the operator wrote.
# This test's payload contains that suffix as a literal substring but never
# a literal "*", so the two cwd states (empty vs. holding the matching
# file) diverge ONLY if the bug fires: correctly quoted, both must reach
# the identical decision (the literal needle "*" is absent from the
# payload, so the clause never holds and SpawnFx never runs, in EITHER
# cwd) -- "the wrapper's decision equals the one made in an empty cwd".
# ===========================================================================
{
    my $T  = build_tree();
    my $fx = "$T/plugins/butler/hooks/next/guards/fx.sh";
    my $root = fresh_state_root();

    my $payload_json = '{"session_id":"N2","note":"contains-pwned-substring"}';
    my ($pfh, $ppath) = tempfile(); print {$pfh} $payload_json; close $pfh;

    my $cwd_before = getcwd();
    my ($res_empty, $res_glob, $fxlog1, $fxlog2);
    my $ok = eval {
        my $empty_cwd = tempdir(CLEANUP => 1);
        my ($lfh1, $l1) = tempfile(); close $lfh1; unlink $l1; $fxlog1 = $l1;
        chdir($empty_cwd) or die "chdir $empty_cwd: $!";
        $res_empty = run_shim(script => $fx, args => ['--pre', 'text:*'],
                               env => {BUTLER_STATE_DIR => $root, SPAWN_FX_LOG => $fxlog1},
                               stdin_path => $ppath, timeout => 10);
        chdir($cwd_before) or die "chdir back from $empty_cwd: $!";

        my $glob_cwd = tempdir(CLEANUP => 1);
        open(my $mfh, '>', "$glob_cwd/text:contains-pwned-substring") or die "create marker file: $!";
        close $mfh;
        my ($lfh2, $l2) = tempfile(); close $lfh2; unlink $l2; $fxlog2 = $l2;
        chdir($glob_cwd) or die "chdir $glob_cwd: $!";
        $res_glob = run_shim(script => $fx, args => ['--pre', 'text:*'],
                              env => {BUTLER_STATE_DIR => $root, SPAWN_FX_LOG => $fxlog2},
                              stdin_path => $ppath, timeout => 10);
        chdir($cwd_before) or die "chdir back from $glob_cwd: $!";
        1;
    };
    chdir($cwd_before); # belt-and-suspenders: never leave this file's cwd moved
    ok($ok, 'R2-n2/L8 setup: both shim runs (empty cwd, cwd with a "text:*"-matching file) completed')
        or diag($@);

  SKIP: {
        skip 'R2-n2/L8: setup did not complete (see diag above)', 4 unless $ok;
        is($res_empty->{rc}, 0, 'R2-n2/L8 setup: --pre text:* in an empty cwd exits 0');
        is(count_lines($res_empty->{shim_log}, 'perl'), 0,
            'R2-n2/L8 setup: --pre text:* in an empty cwd never runs SpawnFx (needle "*" is not in the payload)');
        is(count_lines($res_glob->{shim_log}, 'perl'), count_lines($res_empty->{shim_log}, 'perl'),
            'R2-n2/L8: --pre text:* makes the SAME perl-launch decision whether or not the cwd holds a file '
          . 'matching the pattern (the atom must never be glob-expanded against the cwd)');
        is((-e $fxlog2 ? 1 : 0), (-e $fxlog1 ? 1 : 0),
            'R2-n2/L8: ...and SpawnFx is invoked in neither cwd or both, never only the one with the matching file');
    }
}

# ===========================================================================
# RT-M3 -- session_id extraction (run-hook.sh:117, "sid=${BP_PAYLOAD#*..}")
# is O(p^2) in the offset of the match: quadratic when "session_id" is
# absent or far from the front. Repro (redteam M3): a ~400KB payload whose
# session_id sits at the END (never first) took ~67s on this host today,
# against ~0s when it is first. Per spec sec 4 ("No test asserts wall time;
# the alarm is a hang guard only"), this does not assert an elapsed-time
# NUMBER -- it bounds the run with a tight 3s shell "timeout" (well above a
# fixed implementation's sub-second cost, far below the ~67s broken one) and
# asserts the run still completed (exit 0), rather than being killed by the
# bound (rc 124). A hard 20s perl alarm (inside run_shim) remains a backstop.
# ===========================================================================
{
    my $T  = build_tree();
    my $fx = "$T/plugins/butler/hooks/next/guards/fx.sh";
    my $root = fresh_state_root();
    {
        local %ENV = %ENV; scrub_env();
        $ENV{BUTLER_STATE_DIR} = $root;
        H('arm', 'RTM3', role => 'manual', by => 'arm-on-entry');
    }
    # session_id is present but nowhere near the front: ~400KB of filler
    # precedes it, matching the redteam repro table's "session_id not first" row.
    my $big_payload = '{"hook_event_name":"PreToolUse","junk":"' . ('x' x 400_000) . '","session_id":"RTM3"}';
    my ($pfh, $ppath) = tempfile(); print {$pfh} $big_payload; close $pfh;

    my $res = run_shim(script => $fx, args => ['--pre', 'armed'],
                        env => {BUTLER_STATE_DIR => $root}, stdin_path => $ppath, timeout => 3);
    is($res->{rc}, 0,
        'RT-M3: a ~400KB payload with session_id NOT first still completes inside a 3s bound (bash sid scan is not quadratic)');
}

# ===========================================================================
# RT-M2 -- on bash older than 4.1 (stock macOS /bin/bash 3.2), "read -N" is
# an invalid option (added in bash 4.1) and returns rc 2, which the wrapper
# does not currently treat as truncated (only rc 0 or >128), so every hook
# silently sees an empty payload. Neither the spec nor the architecture
# names a version-override seam (grepped specs/03-hook-core-spec.md: no
# BASH_VERSINFO mention), and this host has only bash 5.3 -- there is no way
# to make "read -N" actually fail here without a second bash binary. Per the
# task's own fallback instruction, this is asserted STRUCTURALLY instead:
# the fix (redteam M3 minimal fix) is an explicit BASH_VERSINFO guard that
# fails open (exit 0) before the read, on bash < 4.1.
# ===========================================================================
{
    # The version check moved with the read into scripts/read-payload.sh, which
    # run-hook.sh sources. bash < 4.1 no longer fails open: it reads with
    # -d '' -n 8388608 instead (read-payload-lib.t runs both branches
    # wherever both bashes exist).
    my $src = read_bytes($REAL_READ_LIB) // '';
    $src =~ s/#.*$//mg;
    like($src, qr/BASH_VERSINFO/,
        'RT-M2: scripts/read-payload.sh (sourced by run-hook.sh) checks BASH_VERSINFO before relying on "read -N"');
}

# ===========================================================================
# S9 (DC2, wall time, not asserted) -- an opt-in timing harness the
# coordinator runs alone, outside the sweep, with BUTLER_TIME_HOOKS=1.
# Building the full 5-warm-up/40-round/median/p90 driver is coordinator
# tooling, not a pass/fail oracle assertion; this block only documents and
# gates the opt-in so the suite never silently assumes it ran.
# ===========================================================================
{
  SKIP: {
        skip 'S9: opt-in timing run (set BUTLER_TIME_HOOKS=1 and run this file alone to execute it)', 1
            unless $ENV{BUTLER_TIME_HOOKS};
        pass('S9: opt-in timing harness placeholder -- see spec sec 4.2 S9 for the exact method; '
           . 'the coordinator runs it alone (ps -W | grep -c run-tests = 0) and records medians/p90 '
           . 'in the 03 ledger, wall time itself is never asserted here');
    }
}

$? = 0;
done_testing();
