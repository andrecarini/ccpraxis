package GuardHarness;
use strict;
use warnings;

# =============================================================================
# GuardHarness.pm -- the shared rig for every guards-remake-*.t file
# (blueprint hook-continuity-remake, package 14-guards-remake, batch 1).
# Built against specs/14-guards-remake-spec.md sec 4.1's exact list:
# isolate_env(), fresh_state(), arm($sid, $role), run_module(), run_wrapper(),
# run_shim(), count_lines(). Every successor's wrapper and module DO NOT EXIST
# YET at the time this file is written -- see run_module()/run_wrapper()/
# run_shim() below for how each fails legibly (never a harness crash) until
# package 14's implementer writes them.
#
# House idiom, copied from the package-03/06/07 oracles (hook-core-spawn-
# budget.t, stop-gate-single.t, continuity-arm-on-entry.t):
#   * every subprocess is bounded by the shell "timeout" utility;
#   * output is always captured to a real File::Temp file, never an
#     in-memory scalar reopen of STDOUT/STDERR (the Windows "Bad file
#     descriptor" landmine);
#   * real bash/perl/timeout are resolved to ABSOLUTE paths once, from the
#     ORIGINAL PATH, before any shim directory is ever prepended;
#   * %ENV is always restored via "local %ENV = %ENV" in the CALLER's scope
#     (isolate_env() mutates the live %ENV, so every call site must localize
#     first -- documented per-sub below).
#
# Nothing in this module spawns claude, podman or launcher.pl. Nothing here
# executes another .t file or an old plugins/butler/hooks/*.sh (Decision 11).
# =============================================================================

use Test::More ();
use File::Basename qw(dirname);
use File::Temp qw(tempdir tempfile);
use File::Spec ();
use JSON::PP ();
use Config ();
use Cwd ();

# NOT FindBin: FindBin's $Bin resolves against $0 (the TOP-LEVEL script),
# not this module's own file, so it would answer "where is the .t file"
# instead of "where is GuardHarness.pm" -- wrong whenever a caller outside
# plugins/butler/tests/t/ uses this module (e.g. this file's own self-check
# invocation). __FILE__ is always this file's own path, regardless of caller,
# but it can still be RELATIVE (e.g. "plugins/butler/tests/t/../lib/
# GuardHarness.pm" when a caller added a relative "use lib") -- resolve it
# with Cwd::abs_path so the "../.." below always lands on a real directory
# regardless of how this module was found.
(my $MY_DIR = Cwd::abs_path(dirname(__FILE__))) =~ s{\\}{/}g;
my $BUTLER_DIR = "$MY_DIR/../..";  # plugins/butler, from plugins/butler/tests/lib
my $SCRIPTS_DIR = "$BUTLER_DIR/scripts";
my $GUARDS_DIR  = "$BUTLER_DIR/hooks";
my $BPHOOK_PM   = "$SCRIPTS_DIR/BpHook.pm";

# Production runs "perl -I$s" (run-hook.sh:250, $s = plugins/butler/scripts)
# for the WHOLE spawned perl process, then BpHook::main does
# "require \"BpHook/\$relpath.pm\"" -- a require-by-relative-path that only
# resolves via @INC. run_module() below issues that exact same
# require-by-relative-path string to mirror BpHook::main() faithfully, so it
# MUST see $SCRIPTS_DIR on @INC exactly as the real wrapper's perl does, or
# every such require silently fails (require_ok false -> fails open, rc 0)
# and every deny-path assertion in every guards-remake-*.t goes green for the
# wrong reason (the module never ran at all). Done once at load time, not
# per-call, matching "-I" being a once-per-process flag in the real wrapper.
unshift @INC, $SCRIPTS_DIR unless grep { $_ eq $SCRIPTS_DIR } @INC;

# BpHook.pm belongs to package 03 and is already implemented; require it
# once, unconditionally -- every guards-remake-*.t needs it and a missing
# copy is a real environment defect, not something to fail open around.
require $BPHOOK_PM;

# =============================================================================
# R9-RM4 (review M4): hermeticity is the HARNESS's job, not each .t file's.
# Captured from the UNTOUCHED ambient env, before isolate_env() ever runs
# below -- this is the operator's real state root, and the only thing every
# later isolate_env()/fresh_state()/arm()/run_module() call in this whole
# process must never be able to reach.
# =============================================================================
my $REAL_HOME = $ENV{HOME};
$REAL_HOME = $ENV{USERPROFILE} unless defined $REAL_HOME && length $REAL_HOME;
(my $REAL_STATE_ROOT = defined $REAL_HOME ? $REAL_HOME : '') =~ s{\\}{/}g;
$REAL_STATE_ROOT =~ s{/+\z}{};
$REAL_STATE_ROOT = length($REAL_STATE_ROOT) ? "$REAL_STATE_ROOT/.claude/butler-state" : '';

# The real .ccpraxis-local-data root of THIS repo (not a decoy), for the
# CCPRAXIS_DATA_DIR/CLAUDE_PROJECT_DIR/BP_PROJECT_ROOT half of the check.
(my $REAL_DATA_ROOT = Cwd::abs_path("$BUTLER_DIR/../../.ccpraxis-local-data") // "$BUTLER_DIR/../../.ccpraxis-local-data") =~ s{\\}{/}g;

sub _canon {
    my ($p) = @_;
    return '' unless defined $p && length $p;
    (my $c = $p) =~ s{\\}{/}g;
    $c =~ s{/+\z}{};
    $c = lc($c) if $^O =~ /^(?:MSWin32|msys|cygwin)$/;
    return $c;
}

my $CANON_REAL_STATE = _canon($REAL_STATE_ROOT);
my $CANON_REAL_DATA  = _canon($REAL_DATA_ROOT);

# ---------------------------------------------------------------------------
# _assert_hermetic($where) -- BAIL_OUT the whole run (never a silent pass)
# the moment anything in this process is one call away from touching the
# REAL ~/.claude/butler-state or this repo's REAL .ccpraxis-local-data.
# Called at the top of every state-touching entry point (arm, run_module,
# run_wrapper, run_shim), so no guards-remake-*.t file can forget it, and no
# reordering of blocks within a file can make it forget either.
# ---------------------------------------------------------------------------
sub _assert_hermetic {
    my ($where) = @_;
    if (length $CANON_REAL_STATE) {
        my $sd = eval { BpHook::state_dir() };
        if (defined $sd && length $sd) {
            my $c = _canon($sd);
            if (length($c) && index($c, $CANON_REAL_STATE) == 0) {
                Test::More::BAIL_OUT(
                    "GuardHarness::_assert_hermetic ($where): BpHook::state_dir() "
                  . "resolved to the REAL state root ($sd) -- refusing to run. "
                  . "isolate_env()/fresh_state() was not called, or BUTLER_STATE_DIR/"
                  . "HOME/USERPROFILE leaked back to the operator's real environment.");
            }
        }
    }
    if (length $CANON_REAL_DATA) {
        for my $var (qw(CCPRAXIS_DATA_DIR CLAUDE_PROJECT_DIR BP_PROJECT_ROOT)) {
            my $v = $ENV{$var};
            next unless defined $v && length $v;
            my $c = _canon($v);
            next unless length $c;
            if (index($c, $CANON_REAL_DATA) == 0 || index($CANON_REAL_DATA, $c) == 0) {
                Test::More::BAIL_OUT(
                    "GuardHarness::_assert_hermetic ($where): \$ENV{$var} ($v) resolves "
                  . "inside this repo's REAL .ccpraxis-local-data -- refusing to run.");
            }
        }
    }
    return 1;
}

# ---------------------------------------------------------------------------
# _snapshot_real_state() -- path => "mtime:size" for every regular file
# under the REAL state root, used by the load-time/END hermeticity check
# below. Never touches anything else; returns {} when the real root does
# not exist (the common case on a machine that never armed continuity).
# ---------------------------------------------------------------------------
sub _snapshot_real_state {
    my %seen;
    return \%seen unless length $REAL_STATE_ROOT && -d $REAL_STATE_ROOT;
    my @stack = ($REAL_STATE_ROOT);
    while (my $d = pop @stack) {
        opendir(my $dh, $d) or next;
        for my $entry (readdir $dh) {
            next if $entry eq '.' || $entry eq '..';
            my $full = "$d/$entry";
            if (-d $full) { push @stack, $full; next }
            my @st = stat $full;
            (my $rel = $full) =~ s{\\}{/}g;
            $seen{$rel} = ($st[9] // 0) . ':' . ($st[7] // 0);
        }
        closedir $dh;
    }
    return \%seen;
}

# Snapshot BEFORE isolate_env()/fresh_state() run below, so this reflects
# the operator's real state exactly as this process found it.
my $REAL_STATE_SNAPSHOT_AT_LOAD = _snapshot_real_state();

END {
    # Skip entirely if the real root never existed either time -- nothing to
    # protect and nothing to compare (avoids a spurious fail on a machine
    # that has never armed continuity at all).
    my $after = _snapshot_real_state();
    my @before_keys = sort keys %$REAL_STATE_SNAPSHOT_AT_LOAD;
    my @after_keys  = sort keys %$after;
    my @diffs;
    for my $k (@after_keys) {
        my $b = $REAL_STATE_SNAPSHOT_AT_LOAD->{$k};
        my $a = $after->{$k};
        push @diffs, "changed: $k" if !defined($b) || $b ne $a;
    }
    for my $k (@before_keys) {
        push @diffs, "removed: $k" unless exists $after->{$k};
    }
    if (@diffs) {
        print STDERR "GuardHarness: HERMETICITY FAILURE -- the REAL ~/.claude/butler-state "
                    . "changed during this test run:\n" . join("\n", map { "  $_" } @diffs) . "\n";
        $? = 1;
    }
}

# ---------------------------------------------------------------------------
# real bash / perl / timeout, resolved to ABSOLUTE paths from the ORIGINAL
# PATH (package-03 technique). Resolved once at load time, before this
# process's PATH is ever altered by a shim.
# ---------------------------------------------------------------------------
my $REAL_BASH_ABS = do { my $p = `bash -c "command -v bash"`; chomp $p; $p };
Test::More::BAIL_OUT('GuardHarness: cannot resolve a real bash on PATH')
    unless length $REAL_BASH_ABS;

my $REAL_TIMEOUT_ABS = do {
    my $p = `bash -c "command -v timeout"`; chomp $p;
    # macOS has no GNU timeout. scripts/run-tests.pl puts the repo's pure-perl
    # stand-in on PATH for a sweep; a file run on its own falls back to it here.
    unless (length $p) {
        (my $self = __FILE__) =~ s{\\}{/}g;
        my $shim = File::Spec->rel2abs(File::Basename::dirname($self) . '/../../../../scripts/test-bin/timeout');
        $p = $shim if -x $shim;
    }
    $p;
};
Test::More::BAIL_OUT('GuardHarness: cannot resolve a real timeout utility on PATH')
    unless length $REAL_TIMEOUT_ABS;

my $REAL_PERL_ABS = do {
    my $p;
    if (File::Spec->file_name_is_absolute($^X) && -x $^X) {
        $p = $^X;
    } else {
        my $found = `bash -c "command -v perl"`; chomp $found;
        $p = (length $found && -x $found) ? $found : $Config::Config{perlpath};
    }
    $p;
};
Test::More::BAIL_OUT('GuardHarness: cannot resolve a real perl to an absolute path')
    unless length $REAL_PERL_ABS;

# ---------------------------------------------------------------------------
# read_bytes($path) -- raw byte slurp, '' on any failure. Never dies.
# ---------------------------------------------------------------------------
sub read_bytes {
    my ($path) = @_;
    return '' unless defined $path;
    open(my $fh, '<:raw', $path) or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

# ---------------------------------------------------------------------------
# isolate_env() -- deletes every BP_*/CCPRAXIS_*/CLAUDE_* var from the LIVE
# %ENV, sets CCPRAXIS_NO_WAKELOCK=1, and pins HOME/USERPROFILE to a fresh
# decoy tempdir so nothing under this process can resolve to the operator's
# real ~/.claude or ~/.ccpraxis-local-data by falling through a fallback
# root. Mutates %ENV in place -- every caller MUST wrap its own call site in
# "local %ENV = %ENV;" first (exactly like every package-03/06/07 fixture
# does), or the mutation leaks into the rest of the suite.
# ---------------------------------------------------------------------------
sub isolate_env {
    delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
    $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
    my $decoy_root = tempdir(CLEANUP => 1);
    (my $decoy = "$decoy_root/decoy-home") =~ s{\\}{/}g;
    mkdir $decoy;
    $ENV{HOME}        = $decoy;
    $ENV{USERPROFILE} = $decoy;
    return $decoy;
}

# =============================================================================
# R9-RM4: isolate AT LOAD, unconditionally, so every guards-remake-*.t file
# is hermetic by default from the moment it does "use GuardHarness;" --
# never dependent on that file remembering to call isolate_env() itself, or
# on block order within the file. Every individual file's own ambient
# "delete $ENV{...}" preamble (still present in several files, run AFTER
# this "use" line) is therefore redundant, not load-bearing -- this is the
# single source of truth.
#
# BUTLER_STATE_DIR is deleted HERE, exactly once, from the untouched ambient
# env an operator's own shell may have exported -- this is the leak review
# M4 named. It is deliberately NOT deleted inside isolate_env() itself:
# several existing oracles (e.g. the gate-shutdown/bash self-check blocks)
# call fresh_state() once, then arm(), then MULTIPLE run_wrapper()/
# run_shim() calls that must keep seeing that SAME state root -- and both
# of those internally call isolate_env() again per call. Deleting
# BUTLER_STATE_DIR inside isolate_env() itself would silently break that
# established, passing pattern on every such nested call. Once, at load,
# is exactly enough to close the ambient-leak hole without touching the
# harness's own later, deliberate fresh_state() calls.
# =============================================================================
delete $ENV{BUTLER_STATE_DIR};
isolate_env();


# ---------------------------------------------------------------------------
# fresh_state() -- a brand-new tempdir, with $ENV{BUTLER_STATE_DIR} pointed
# at "<tmp>/state" (BpHook itself appends "/continuity"). Returns that base
# path. Callers still own their own "local %ENV = %ENV;" -- this sub sets
# exactly one key.
# ---------------------------------------------------------------------------
sub fresh_state {
    my $t = tempdir(CLEANUP => 1);
    (my $base = "$t/state") =~ s{\\}{/}g;
    $ENV{BUTLER_STATE_DIR} = $base;
    return $base;
}

# ---------------------------------------------------------------------------
# arm($sid, $role, %opts) -- BpHook::arm($sid, role => $role, by => ...)
# against whatever BUTLER_STATE_DIR is currently set (normally fresh_state()'s
# return value). $opts{by} defaults to 'arm-on-entry'. Returns the boolean
# BpHook::arm() itself returns.
# ---------------------------------------------------------------------------
sub arm {
    my ($sid, $role, %opts) = @_;
    _assert_hermetic('arm');
    return BpHook::arm($sid, role => $role, by => ($opts{by} // 'arm-on-entry'));
}

# ---------------------------------------------------------------------------
# _encode_payload($payload) -- a hashref is canonical-UTF8-JSON-encoded (the
# BYTES BpHook::load_payload expects); a plain scalar is passed through
# unchanged (already-raw JSON, truncated JSON, non-JSON, whatever the
# caller wants BpHook to see verbatim).
# ---------------------------------------------------------------------------
sub _encode_payload {
    my ($payload) = @_;
    return $payload unless ref $payload eq 'HASH';
    return JSON::PP->new->utf8->canonical->encode($payload);
}

# ---------------------------------------------------------------------------
# _write_stdin($payload) -- _encode_payload(), written to a fresh File::Temp
# file. Returns the path.
# ---------------------------------------------------------------------------
sub _write_stdin {
    my ($payload) = @_;
    my (undef, $path) = tempfile();
    open(my $fh, '>:raw', $path) or die "GuardHarness: cannot write stdin fixture: $!";
    print {$fh} _encode_payload($payload);
    close $fh;
    return $path;
}

# ---------------------------------------------------------------------------
# run_module($module, $payload, %opts) -- the in-process seam every ordinary
# (non-[wrapper]/[shim]) AC uses. $module is the bare "Guards::X" name (no
# "BpHook::" prefix, matching the wrapper's own exec line and BpHook::main's
# own convention). $payload is a hashref (JSON-encoded here) or a raw
# string (passed through as-is, e.g. deliberately truncated/invalid JSON).
#
# %opts:
#   env  => {}   -- overlaid onto %ENV for the duration of the call, then
#                    restored (this sub localizes %ENV itself, so callers do
#                    NOT need their own "local %ENV = %ENV;" around it -- but
#                    isolate_env()/fresh_state() calls made BEFORE run_module
#                    are not undone by it, exactly like BpHook::main never
#                    resets ambient env either).
#   args => []   -- extra argv passed to run(), after the payload.
#
# Mirrors BpHook::main()'s own require-and-call contract EXACTLY (this is
# the in-process stand-in for what run-hook.sh's spawned perl does), so a
# missing module, a require that dies, or a run() that dies or exit()s all
# fail open (rc 0) here precisely as they do through the real wrapper:
#   * require "BpHook/Guards/<X>.pm" failing -> rc 0, out '', err ''.
#   * run() dying                            -> rc 0 (an END block never
#                                                fires here, but a plain
#                                                die() inside eval cannot
#                                                escape either).
#   * run() returning anything whose string form is not exactly "2" -> rc 0.
#   * run() returning exactly 2              -> rc 2, whatever it printed
#                                                to BpHook::deny() kept.
#
# Returns { rc, out, err, parse_delta }. parse_delta is
# BpHook::parse_count() taken right after run() minus the count taken right
# after load_payload() (SH-5: run() must never re-parse the payload, so a
# passing module always yields parse_delta == 0).
# ---------------------------------------------------------------------------
sub run_module {
    my ($module, $payload, %opts) = @_;
    my $env  = $opts{env}  // {};
    my $args = $opts{args} // [];

    local %ENV = %ENV;
    for my $k (keys %$env) {
        if (defined $env->{$k}) { $ENV{$k} = $env->{$k} } else { delete $ENV{$k} }
    }
    _assert_hermetic('run_module');

    my (undef, $out_path) = tempfile();
    my (undef, $err_path) = tempfile();
    open(my $saved_out, '>&', \*STDOUT) or die "GuardHarness: dup STDOUT: $!";
    open(my $saved_err, '>&', \*STDERR) or die "GuardHarness: dup STDERR: $!";
    open(STDOUT, '>', $out_path) or die "GuardHarness: redirect STDOUT: $!";
    open(STDERR, '>', $err_path) or die "GuardHarness: redirect STDERR: $!";

    # BpHook::main() installs a $SIG{__WARN__} handler so a payload-decode
    # warning goes to hook-errors.log, never to stderr (spec sec 4.11's
    # "warn ... never to stderr" note, and SH-7's "no output" contract).
    # This harness has no hook-errors.log to write to, so it just swallows
    # the warning here -- the observable contract (stderr stays empty) is
    # what SH-7 actually asserts, and swallowing (rather than leaving it to
    # fall through to this file's own real STDERR/STDOUT, which are ALREADY
    # redirected above) keeps that true without inventing a log file no
    # spec section asks this harness to model.
    local $SIG{__WARN__} = sub { };

    BpHook::load_payload(_encode_payload($payload));
    my $p = BpHook::payload();
    my $parse_before = BpHook::parse_count();

    my $relpath = $module;
    $relpath =~ s{::}{/}g;
    my $rc = 0;
    my $parse_after = $parse_before;
    my $require_ok = eval { require "BpHook/$relpath.pm"; 1 };
    if ($require_ok) {
        my $ret;
        my $ok = eval {
            my $fn = "BpHook::${module}::run";
            no strict 'refs';
            $ret = &$fn($p, @$args);
            1;
        };
        $parse_after = BpHook::parse_count();
        if ($ok) {
            my $rs = defined $ret ? "$ret" : '';
            $rc = ($rs =~ /^\s*2\s*$/) ? 2 : 0;
        }
    }

    open(STDOUT, '>&', $saved_out) or die "GuardHarness: restore STDOUT: $!";
    open(STDERR, '>&', $saved_err) or die "GuardHarness: restore STDERR: $!";
    close $saved_out;
    close $saved_err;

    my $out = read_bytes($out_path);
    my $err = read_bytes($err_path);
    unlink $out_path, $err_path;

    return {
        rc          => $rc,
        out         => $out,
        err         => $err,
        parse_delta => $parse_after - $parse_before,
    };
}

# ---------------------------------------------------------------------------
# _hook_path($hook) -- $hook may already be an absolute/relative path
# (contains a "/"); otherwise it is a bare wrapper name resolved under
# hooks/next/guards/, with a ".sh" suffix added if missing.
# ---------------------------------------------------------------------------
sub _hook_path {
    my ($hook) = @_;
    return $hook if $hook =~ m{/};
    $hook .= '.sh' unless $hook =~ /\.sh$/;
    return "$GUARDS_DIR/$hook";
}

# ---------------------------------------------------------------------------
# run_wrapper($hook, $payload, %opts) -- a real subprocess through the
# actual bash wrapper file (hooks/next/guards/<hook>.sh, or a full path).
# Bounded by the real "timeout" utility. No PATH shim: use this when an AC
# only needs rc/stdout/stderr, not a process count (use run_shim for that).
#
# Until package 14 writes the wrapper file, the real bash reports "No such
# file or directory" on stderr and exits 127 -- a legible failure, never a
# harness crash.
#
# %opts: env => {}, args => [], timeout => 10 (default).
# Returns { rc, out, err }.
# ---------------------------------------------------------------------------
sub run_wrapper {
    my ($hook, $payload, %opts) = @_;
    my $script  = _hook_path($hook);
    my $env     = $opts{env}     // {};
    my $args    = $opts{args}    // [];
    my $timeout = $opts{timeout} // 10;

    my $stdin_path = _write_stdin($payload);
    my (undef, $out_path) = tempfile();
    my (undef, $err_path) = tempfile();

    local %ENV = %ENV;
    isolate_env();
    for my $k (keys %$env) {
        if (defined $env->{$k}) { $ENV{$k} = $env->{$k} } else { delete $ENV{$k} }
    }
    _assert_hermetic('run_wrapper');

    my @cmd = ($REAL_TIMEOUT_ABS, $timeout, $REAL_BASH_ABS, $script, @$args);
    my $inner = join(' ', map { qq("$_") } @cmd);
    $inner .= qq( < "$stdin_path" > "$out_path" 2> "$err_path");
    system($REAL_BASH_ABS, '-c', $inner);
    my $rc = ($? == -1) ? -1 : ($? >> 8);

    my $out = read_bytes($out_path);
    my $err = read_bytes($err_path);
    unlink $stdin_path, $out_path, $err_path;
    return { rc => $rc, out => $out, err => $err };
}

# ---------------------------------------------------------------------------
# _build_shim() -- a tempdir with bash/perl/jq shims (package-03 technique).
# Each shim logs "<name> <pid>" to $ENV{SHIM_LOG} before exec'ing the real
# binary by absolute path (jq just logs and exits 0 -- nothing in this
# package's contract calls jq for real).
# ---------------------------------------------------------------------------
sub _build_shim {
    my $shim = tempdir(CLEANUP => 1);
    for my $pair ([bash => $REAL_BASH_ABS], [perl => $REAL_PERL_ABS]) {
        my ($name, $real) = @$pair;
        open(my $fh, '>', "$shim/$name") or die "GuardHarness: cannot write shim $name: $!";
        print {$fh} "#!$REAL_BASH_ABS\n";
        print {$fh} "printf '%s %s\\n' '$name' \"\$\$\" >> \"\$SHIM_LOG\"\n";
        print {$fh} "exec \"$real\" \"\$\@\"\n";
        close $fh;
        chmod 0755, "$shim/$name";
    }
    open(my $jfh, '>', "$shim/jq") or die "GuardHarness: cannot write shim jq: $!";
    print {$jfh} "#!$REAL_BASH_ABS\n";
    print {$jfh} "printf '%s %s\\n' 'jq' \"\$\$\" >> \"\$SHIM_LOG\"\n";
    print {$jfh} "exit 0\n";
    close $jfh;
    chmod 0755, "$shim/jq";
    return $shim;
}

# ---------------------------------------------------------------------------
# run_shim($hook, $payload, %opts) -- run_wrapper()'s process-budget twin
# (Decision 33/SH-3/SH-4): the wrapper runs under a PATH whose bash/perl/jq
# are the _build_shim() loggers, so the returned shim_log records exactly
# what the wrapper's own internal "exec bash .../exec perl ..." launched.
# This IS the "package-03 PATH-shim spawn counter" the package spec asks
# this module to expose -- call count_lines($res->{shim_log}, 'perl') (etc.)
# on the result to read it.
#
# %opts: env => {}, args => [], timeout => 15 (default), shim_dir => (reuse
# an existing one instead of building a fresh one).
# Returns { rc, out, err, shim_log, shim_dir }.
# ---------------------------------------------------------------------------
sub run_shim {
    my ($hook, $payload, %opts) = @_;
    my $script   = _hook_path($hook);
    my $env      = $opts{env}     // {};
    my $args     = $opts{args}    // [];
    my $timeout  = $opts{timeout} // 15;
    my $shim_dir = $opts{shim_dir} // _build_shim();

    my $stdin_path = _write_stdin($payload);
    my (undef, $shim_log_path) = tempfile(); unlink $shim_log_path;
    my (undef, $out_path) = tempfile();
    my (undef, $err_path) = tempfile();

    local %ENV = %ENV;
    isolate_env();
    for my $k (keys %$env) {
        if (defined $env->{$k}) { $ENV{$k} = $env->{$k} } else { delete $ENV{$k} }
    }
    $ENV{SHIM_LOG} = $shim_log_path;
    unless (exists $env->{PATH}) { $ENV{PATH} = "$shim_dir:$ENV{PATH}" }
    _assert_hermetic('run_shim');

    my @inner_cmd = ("$shim_dir/bash", $script, @$args);
    my $inner = join(' ', map { qq("$_") } @inner_cmd);
    $inner = "$REAL_TIMEOUT_ABS $timeout $inner";
    $inner .= qq( < "$stdin_path" > "$out_path" 2> "$err_path");

    local $SIG{ALRM} = sub { die "GuardHarness::run_shim: hard alarm backstop exceeded\n" };
    alarm($timeout + 15);
    system($REAL_BASH_ABS, '-c', $inner);
    my $rc = ($? == -1) ? -1 : ($? >> 8);
    alarm(0);

    my $out = read_bytes($out_path);
    my $err = read_bytes($err_path);
    my $shim_log = read_bytes($shim_log_path);
    unlink $stdin_path, $out_path, $err_path;

    return { rc => $rc, out => $out, err => $err, shim_log => $shim_log, shim_dir => $shim_dir };
}

# ---------------------------------------------------------------------------
# count_lines($log, $name) -- how many "<name> <pid>" lines a run_shim()
# shim_log carries for the given tool name ('perl', 'jq', 'bash').
# ---------------------------------------------------------------------------
sub count_lines {
    my ($log, $name) = @_;
    return 0 unless defined $log && defined $name;
    return scalar(grep { /^\Q$name\E / } split /\n/, $log);
}

1;
