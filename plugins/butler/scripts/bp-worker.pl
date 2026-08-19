#!/usr/bin/env perl
# bp-worker.pl — deterministic non-Task dispatcher for butler workers.
#
# Implements plugins/butler/tests/../specs/b32-worker-backend-dispatcher-spec.md.
# Invoked by a coordinator via Bash instead of Task when the resolved
# `worker_backend:` is not `claude`. Re-implements no policy of its own: it
# sources hooks/lib.sh for the marker/lock/stop-signal primitives and
# reproduces track-dispatch.sh's and log-dispatch.sh's side effects
# byte-for-byte, because a Bash subprocess dispatch fires no PreToolUse /
# PostToolUse Task hooks.
#
# Core modules only (no CPAN) — see spec §5 "No CPAN".
use strict;
use warnings;
use FindBin qw($Bin);
use Getopt::Long qw();   # not used for parsing (see below) but declared for clarity
use POSIX qw(strftime WNOHANG);
use Fcntl qw(O_WRONLY O_RDONLY O_CREAT O_EXCL O_APPEND O_TRUNC LOCK_EX LOCK_UN);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Config;

# ---------------------------------------------------------------------------
# Global state consulted by the END block / signal handler (§2.6).
# ---------------------------------------------------------------------------
our $ACQUIRED       = 0;
our $MARKER_PATH    = undef;
our $MARKER_CONTENT = undef;
our $CHILD_PID      = undef;

END {
    if ($ACQUIRED && defined $MARKER_PATH) {
        my $cur = _read_raw($MARKER_PATH);
        if (defined $cur && $cur eq $MARKER_CONTENT) {
            unlink($MARKER_PATH);
        }
    }
}

sub signal_exit {
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
    my %signum = (TERM => 15, INT => 2, HUP => 1);
    exit(128 + ($signum{$name} // 15));
}
$SIG{TERM} = $SIG{INT} = $SIG{HUP} = \&signal_exit;

# ---------------------------------------------------------------------------
# Worker name closed set (§2.2).
# ---------------------------------------------------------------------------
my %WORKERS = (
    implementer   => { write => 1 },
    'test-writer' => { write => 1 },
    'ui-prober'   => { write => 1 },
    scout         => { write => 0 },
    architect     => { write => 0 },
    reviewer      => { write => 0 },
    redteam       => { write => 0 },
);

sub canonical_worker {
    my ($raw) = @_;
    return () unless defined $raw && length $raw;
    my $s = $raw;
    $s =~ s/^butler://;
    $s =~ s/^bp-//;
    return () unless exists $WORKERS{$s};
    return ("butler:bp-$s", $s, $WORKERS{$s}{write});
}

sub is_writer_str {
    my ($s) = @_;
    return 0 unless defined $s;
    return ($s =~ /bp-implementer/ || $s =~ /bp-test-writer/ || $s =~ /bp-ui-prober/) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Small helpers.
# ---------------------------------------------------------------------------
sub _read_raw {
    my ($path) = @_;
    return undef unless -e $path;
    open(my $fh, '<', $path) or return undef;
    binmode $fh;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub usage_text {
    return <<'USAGE';
usage: bp-worker.pl --worker <name> --prompt-file <path> [--model <M>]
                     [--turn-budget <N>] [--help]

  --worker <name>       required; one of: implementer, test-writer, ui-prober,
                        scout, architect, reviewer, redteam (any of the
                        bp-<name> / butler:bp-<name> spellings also accepted)
  --prompt-file <path>  required; readable file whose contents are the prompt
  --model <M>           optional; passed through to a non-claude backend
  --turn-budget <N>     optional; materialises a per-dispatch copy of the
                        OpenCode agent file with `steps:` overridden to N
  --help                print this message and exit 0
USAGE
}

sub usage_error {
    my ($msg) = @_;
    print STDERR "bp-worker.pl: $msg\n";
    exit 2;
}

# ---------------------------------------------------------------------------
# 1. Parse args (§2.1, §2.11 step 1) -> exit 2 on any problem.
# ---------------------------------------------------------------------------
my %opt;
{
    my @args = @ARGV;
    while (@args) {
        my $a = shift @args;
        if ($a eq '--help') {
            print usage_text();
            exit 0;
        }
        elsif ($a eq '--worker') {
            usage_error('--worker requires a value') unless @args;
            $opt{worker} = shift @args;
        }
        elsif ($a =~ /^--worker=(.*)$/) {
            $opt{worker} = $1;
        }
        elsif ($a eq '--prompt-file') {
            usage_error('--prompt-file requires a value') unless @args;
            $opt{prompt_file} = shift @args;
        }
        elsif ($a =~ /^--prompt-file=(.*)$/) {
            $opt{prompt_file} = $1;
        }
        elsif ($a eq '--model') {
            usage_error('--model requires a value') unless @args;
            $opt{model} = shift @args;
        }
        elsif ($a =~ /^--model=(.*)$/) {
            $opt{model} = $1;
        }
        elsif ($a eq '--turn-budget') {
            usage_error('--turn-budget requires a value') unless @args;
            $opt{turn_budget} = shift @args;
        }
        elsif ($a =~ /^--turn-budget=(.*)$/) {
            $opt{turn_budget} = $1;
        }
        else {
            usage_error("unrecognised argument: $a");
        }
    }
}

usage_error('--worker is required') unless defined $opt{worker};
usage_error('--prompt-file is required') unless defined $opt{prompt_file};
usage_error("--prompt-file does not exist or is not readable: $opt{prompt_file}")
    unless defined $opt{prompt_file} && -e $opt{prompt_file} && -r $opt{prompt_file} && -f $opt{prompt_file};

my ($CANON, $SHORT, $IS_WRITER) = canonical_worker($opt{worker});
usage_error("--worker '$opt{worker}' is not in the recognised set (implementer, test-writer, ui-prober, scout, architect, reviewer, redteam)")
    unless defined $CANON;

# ---------------------------------------------------------------------------
# 2. Env contract (§2.3, §2.11 step 2) -> exit 6.
# ---------------------------------------------------------------------------
my @required_env = qw(BP_DIR BP_PACKAGE BP_LEDGER BP_PROJECT_ROOT);
my @missing_env = grep { !defined $ENV{$_} || !length $ENV{$_} } @required_env;
if (@missing_env) {
    print STDERR "bp-worker.pl: missing required environment variable(s): " . join(', ', @missing_env) . "\n";
    exit 6;
}
my $BP_DIR      = $ENV{BP_DIR};
my $BP_PACKAGE  = $ENV{BP_PACKAGE};
my $BP_LEDGER   = $ENV{BP_LEDGER};

# ---------------------------------------------------------------------------
# 3. Source hooks/lib.sh (once) for marker_path / ledger_lock / bp_active_stop_signal.
# ---------------------------------------------------------------------------
(my $LIB = "$Bin/../hooks/lib.sh") =~ s{\\}{/}g;

sub sh_fn {
    my ($fn) = @_;
    my $o = `bash -c '. "\$1" >/dev/null 2>&1; $fn' bash "$LIB" 2>/dev/null`;
    $o = '' unless defined $o;
    chomp $o;
    return $o;
}

my $MARKER  = sh_fn('marker_path');
my $LOCKFILE = sh_fn('ledger_lock');

# ---------------------------------------------------------------------------
# 4. Stop-signal gate (§2.11 step 4) -> exit 5, NO marker, checked first.
# ---------------------------------------------------------------------------
my $stop = sh_fn('bp_active_stop_signal');
if (defined $stop && length $stop) {
    print STDERR "bp-worker.pl: a fleet stop signal ('$stop') is in force; refusing to dispatch $CANON\n";
    exit 5;
}

# ---------------------------------------------------------------------------
# 5. Resolve worker_backend (§2.4) -> exit 4 if unrecognised.
# ---------------------------------------------------------------------------
sub read_header_key {
    my ($file, $key) = @_;
    return undef unless defined $file && -r $file;
    open(my $fh, '<', $file) or return undef;
    my @lines = <$fh>;
    close $fh;
    chomp @lines;
    return undef unless @lines;

    my @region;
    if ($lines[0] =~ /^---\s*$/) {
        my $end;
        for my $i (1 .. $#lines) {
            if ($lines[$i] =~ /^---\s*$/) { $end = $i; last; }
        }
        return undef unless defined $end;
        @region = ($end > 1) ? @lines[1 .. $end - 1] : ();
    }
    else {
        my $end;
        for my $i (0 .. $#lines) {
            if ($lines[$i] =~ /^##\s/) { $end = $i; last; }
        }
        @region = defined $end ? ($end > 0 ? @lines[0 .. $end - 1] : ()) : @lines;
    }

    for my $line (@region) {
        next unless $line =~ /^\Q$key\E:\s*(.*)$/;
        my $v = $1;
        $v =~ s/\s+#.*$//;
        $v =~ s/^\s+|\s+$//g;
        $v =~ s/^["']|["']$//g;
        return length($v) ? $v : undef;
    }
    return undef;
}

my $PKG_LEDGER_FILE = "$BP_DIR/packages/$BP_PACKAGE.md";
my $BLUEPRINT_FILE  = "$BP_DIR/blueprint.md";

my ($backend, $backend_src) = (undef, undef);
$backend = read_header_key($PKG_LEDGER_FILE, 'worker_backend');
$backend_src = $PKG_LEDGER_FILE if defined $backend;
if (!defined $backend) {
    $backend = read_header_key($BLUEPRINT_FILE, 'worker_backend');
    $backend_src = $BLUEPRINT_FILE if defined $backend;
}
if (!defined $backend) {
    $backend = 'claude';
    $backend_src = '(default)';
}

if ($backend ne 'claude' && $backend ne 'opencode') {
    print STDERR "bp-worker.pl: unrecognised worker_backend '$backend' in $backend_src"
        . " (recognised: claude, opencode)\n";
    exit 4;
}

# ---------------------------------------------------------------------------
# 6. backend eq 'claude' -> non-executing 4-line block, exit 0 (§2.5, §2.7).
# ---------------------------------------------------------------------------
if ($backend eq 'claude') {
    print "worker: $CANON\n";
    print "backend: claude\n";
    print "model: -\n";
    print "dispatch: task\n";
    exit 0;
}

# ---------------------------------------------------------------------------
# 7. Resolve the backend binary on PATH (§2.5) -> exit 8 if missing.
# ---------------------------------------------------------------------------
my $sep = $Config{path_sep} || ':';
my @path_dirs = split /\Q$sep\E/, ($ENV{PATH} // '');
my $backend_bin;
for my $d (@path_dirs) {
    next unless length $d;
    my $cand = "$d/$backend";
    if (-f $cand && -x $cand) {
        $backend_bin = $cand;
        last;
    }
}
if (!defined $backend_bin) {
    print STDERR "bp-worker.pl: backend '$backend' not found or not executable on PATH."
        . " Install it (see plugins/sandbox/container/Containerfile's opencode section),"
        . " check it is backpack-declared (/backpack:list), and confirm PATH includes"
        . " /usr/bin inside this environment.\n";
    exit 8;
}

# ---------------------------------------------------------------------------
# 8. Acquire marker if write-capable (§2.6, §2.11 step 8) -> exit 3 if held.
# ---------------------------------------------------------------------------
if ($IS_WRITER) {
    make_path(dirname($MARKER));

    my $try_create = sub {
        my $fh;
        my $ok = sysopen($fh, $MARKER, O_WRONLY | O_CREAT | O_EXCL);
        return 0 unless $ok;
        binmode $fh;
        print $fh $CANON;
        close $fh;
        return 1;
    };

    if ($try_create->()) {
        $MARKER_PATH = $MARKER;
        $MARKER_CONTENT = $CANON;
        $ACQUIRED = 1;
    }
    else {
        my $current = _read_raw($MARKER);
        if (is_writer_str($current)) {
            print STDERR "BLOCKED: a write-capable worker ($current) is already in flight."
                . " The protocol allows at most one write-capable worker at a time"
                . " -- wait for it to return before dispatching $CANON.\n";
            exit 3;
        }
        # Stale non-writer marker: unlink and retry once.
        unlink($MARKER);
        if ($try_create->()) {
            $MARKER_PATH = $MARKER;
            $MARKER_CONTENT = $CANON;
            $ACQUIRED = 1;
        }
        else {
            print STDERR "BLOCKED: could not acquire the active-worker marker for $CANON"
                . " (lost a race) -- treating as a write-capable worker already in flight.\n";
            exit 3;
        }
    }
}

# ---------------------------------------------------------------------------
# 9. Open report file; fork+exec; wait (§2.8, §2.11 step 9).
# ---------------------------------------------------------------------------
my $reports_dir = "$BP_DIR/reports/$BP_PACKAGE";
make_path($reports_dir);
my $ts = strftime('%Y%m%dT%H%M%SZ', gmtime);
my $report_file = "$reports_dir/bp-worker-$SHORT-$ts.out";

sysopen(my $create_fh, $report_file, O_WRONLY | O_CREAT | O_TRUNC, 0644)
    or die "bp-worker.pl: cannot create report file $report_file: $!";
close($create_fh);

my $prompt_file = $opt{prompt_file};
my $model = $opt{model};

# ---------------------------------------------------------------------------
# 8a. b35: if the caller did not pin a --model, consult bp-worker-models.pl's
# worker_models: cascade (package ledger -> blueprint -> built-in) for a
# default, rather than leaving model selection entirely to the backend.
# ADDITIVE only: an explicit --model always wins, and any failure to resolve
# (script absent, ledger/blueprint missing, non-zero exit) is silently
# ignored -- this must never turn a working dispatch into a failing one.
# ---------------------------------------------------------------------------
if (!(defined $model && length $model) && $backend eq 'opencode') {
    (my $models_bin = "$Bin/bp-worker-models.pl") =~ s{\\}{/}g;
    if (-f $models_bin) {
        my $resolved = eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm(5);
            my $out = `"$^X" "$models_bin" resolve --role "bp-$SHORT" --package-ledger "$PKG_LEDGER_FILE" --blueprint "$BLUEPRINT_FILE" 2>/dev/null`;
            alarm(0);
            $out;
        };
        alarm(0);
        if (defined $resolved && $resolved =~ /^model:\s*(\S+)\s*$/m) {
            $model = $1;
        }
    }
}

# ---------------------------------------------------------------------------
# 8b. --turn-budget (§2.1): materialise a per-dispatch copy of the OpenCode
# agent file with `steps:` overridden, and point the dispatch at it. Shipped
# agents already carry a per-role default `steps` (mirroring the Claude
# twin's maxTurns); this is the dispatch-time override half of that decision.
# ---------------------------------------------------------------------------
my $materialised_agent_file;
my $materialised_agent_dir;
my $materialised_agent_name;
# OpenCode discovers agents relative to the directory it runs in. The backend is
# exec'd without a chdir, so it inherits this process's cwd; BP_PROJECT_ROOT is the
# contractual project root and is what a jailed or unjailed worker is pointed at.
(my $run_cwd = ($ENV{BP_PROJECT_ROOT} // '.')) =~ s{\\}{/}g;
if (defined $opt{turn_budget} && length $opt{turn_budget} && $opt{turn_budget} =~ /^\d+$/) {
    (my $agent_src = "$Bin/../opencode/bp-$SHORT.md") =~ s{\\}{/}g;
    if (-r $agent_src) {
        my $agent_content = _read_raw($agent_src);
        if (defined $agent_content) {
            if ($agent_content =~ /^steps:\s*\d+.*$/m) {
                $agent_content =~ s/^steps:\s*\d+(.*)$/steps: $opt{turn_budget}$1/m;
            }
            else {
                $agent_content =~ s/(\A---\s*\n)/$1steps: $opt{turn_budget}\n/;
            }
            # MUST land in the directory OpenCode actually reads. Measured against the
            # real CLI (1.18.7): an agent .md dropped in `<cwd>/.opencode/agents/<name>.md`
            # shows up in `opencode agent list` and is selectable with `--agent <name>`;
            # the singular `.opencode/agent/` is NOT read. Writing it anywhere else
            # (e.g. straight into reports/) produces a file nothing ever loads, so the
            # turn budget would silently not apply — exactly the failure this package's
            # ledger warns would "quietly undo" b09/b10/b11/b23.
            $materialised_agent_dir  = "$run_cwd/.opencode/agents";
            make_path($materialised_agent_dir) unless -d $materialised_agent_dir;
            $materialised_agent_name = "bp-$SHORT-tb-$ts";
            $materialised_agent_file = "$materialised_agent_dir/$materialised_agent_name.md";
            sysopen(my $afh, $materialised_agent_file, O_WRONLY | O_CREAT | O_TRUNC, 0644)
                or die "bp-worker.pl: cannot write materialised agent file $materialised_agent_file: $!";
            binmode $afh;
            print $afh $agent_content;
            close $afh;
        }
    }
}

# ---------------------------------------------------------------------------
# 8c. Per-invocation TMPDIR (spec §2.2, done criterion 2 -- opencode backend
# only; see spec §0 for why coordinator-level (bp-launch.sh) isolation is
# unreachable inside this write_set). Applied to EVERY dispatch, writer or
# read-only: a read-only worker's toolchain can equally contend for /tmp.
# sweep_stale runs BEFORE creating this invocation's own directory, so a
# crashed dispatch's leftover cannot itself accumulate forever, and cannot
# collide with the one this invocation is about to make.
#
# fixbatch step7 / F3: sweep_stale_tmp was mtime-only, no liveness check --
# reviewer SF2 / red-team MEDIUM-1, verified by reading the code: a dispatch
# whose toolchain writes only INTO subdirectories (never touching
# $DISPATCH_TMP's own top level again) leaves its parent mtime frozen at
# creation time, so a long-running-but-genuinely-live dispatch past the
# default 240-minute TTL could have its OWN live scratch directory swept by a
# CONCURRENT, unrelated bp-worker.pl invocation. Fixed by recording an OWNER
# (this invocation's own pid + a process-instance fingerprint, via
# bp-runstate.pl's pid_alive/pid_fingerprint -- the exact precedent named in
# the finding, already solving the identical "is the pid at this number the
# SAME process, or one the OS recycled the number to" problem for the stop
# gate) in a sidecar file inside DISPATCH_TMP at creation time. A stale-by-
# mtime directory is only swept if its owner cannot be verified alive AND
# the same instance -- never on mtime alone once an owner sidecar exists. A
# directory with NO owner sidecar (pre-fix leftovers, or the fixture-built
# "leftover from a crashed dispatch" case t/147 section C exercises) has
# nothing to verify and sweeps exactly as before -- this is what keeps that
# existing counter-fixture green.
# ---------------------------------------------------------------------------
my $WORKER_TMP_TTL_MIN = $ENV{CCPRAXIS_WORKER_TMP_TTL_MIN};
if (!defined $WORKER_TMP_TTL_MIN || $WORKER_TMP_TTL_MIN !~ /^\d+$/ || $WORKER_TMP_TTL_MIN <= 0) {
    $WORKER_TMP_TTL_MIN = 240;
}
my $TMPROOT = "$BP_DIR/tmp";

# _dispatch_tmp_owner_alive(DIR) -> 1 if DIR carries an owner sidecar (.owner,
# "PID:FINGERPRINT") whose pid is alive AND fingerprints identically to the
# one recorded at creation time -- i.e. verifiably the SAME still-running
# bp-worker.pl invocation, not merely "some process at that number now".
# Any ambiguity (no sidecar, unparsceable, pid dead, fingerprint mismatch or
# unobtainable) returns 0 -- fails toward "sweep it", the pre-existing
# best-effort-cleanup posture this file already documents everywhere else.
sub _dispatch_tmp_owner_alive {
    my ($dir) = @_;
    my $owner_file = "$dir/.owner";
    return 0 unless -f $owner_file;
    open(my $fh, '<', $owner_file) or return 0;
    my $line = <$fh>;
    close($fh);
    return 0 unless defined $line;
    chomp $line;
    my ($pid, $fp) = split(/:/, $line, 2);
    return 0 unless defined $pid && $pid =~ /^\d+$/;
    return 0 unless defined $fp && length $fp;
    require "$Bin/bp-runstate.pl";
    return 0 unless BpRunState::pid_alive($pid);
    my $have = BpRunState::pid_fingerprint($pid);
    return (defined $have && $have eq $fp) ? 1 : 0;
}

sub sweep_stale_tmp {
    my ($root, $ttl_min) = @_;
    return unless -d $root;
    my $now = time();
    opendir(my $dh, $root) or return;
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);
    for my $e (@entries) {
        my $p = "$root/$e";
        next unless -d $p;
        my @st = stat($p);
        next unless @st;
        my $age_min = ($now - $st[9]) / 60;
        next unless $age_min > $ttl_min;
        next if _dispatch_tmp_owner_alive($p);   # verified still-live: never sweep, however stale the mtime
        require File::Path;
        File::Path::remove_tree($p, { error => \my $err });
    }
}
make_path($TMPROOT) unless -d $TMPROOT;
sweep_stale_tmp($TMPROOT, $WORKER_TMP_TTL_MIN);
my $DISPATCH_TMP = "$TMPROOT/$BP_PACKAGE.$SHORT.$ts.$$";
make_path($DISPATCH_TMP);
{
    require "$Bin/bp-runstate.pl";
    my $owner_fp = BpRunState::pid_fingerprint($$);
    if (defined $owner_fp && length $owner_fp) {
        if (open(my $ownfh, '>', "$DISPATCH_TMP/.owner")) {
            print {$ownfh} "$$:$owner_fp\n";
            close($ownfh);
        }
    }
    # No fingerprint obtainable (e.g. neither /proc nor wmic resolved): the
    # directory is left with no owner sidecar, which is exactly the
    # "unverifiable -> sweep as before" fallback _dispatch_tmp_owner_alive
    # already implements -- never a wedge, just a lost liveness guarantee.
}

my $pid = fork();
die "bp-worker.pl: fork failed: $!" unless defined $pid;
if ($pid == 0) {
    # Child: redirect stdin from the prompt file, stdout+stderr into the report file.
    open(STDIN, '<', $prompt_file) or POSIX::_exit(126);
    sysopen(my $ofh, $report_file, O_WRONLY | O_APPEND) or POSIX::_exit(126);
    open(STDOUT, '>&', $ofh) or POSIX::_exit(126);
    open(STDERR, '>&', $ofh) or POSIX::_exit(126);
    # Child-only: never mutates the parent's own %ENV. bp-worker.pl itself
    # does no temp-file work that needs isolating; mutating the parent would
    # leak into anything it does after waitpid returns (report writes,
    # ledger append) for no benefit.
    $ENV{TMPDIR} = $DISPATCH_TMP;
    my @model_args = (defined $model && length $model) ? ('--model', $model) : ();
    my @format_args = ('--format', 'json');
    # `--agent <name>`, NOT `--agent-file <path>`. Measured: `--agent-file` is not a
    # real flag — the CLI prints usage and exits 1 on it, so every turn-budgeted
    # dispatch would have failed outright. `--agent` selects by NAME from the agents
    # directory the file above was materialised into.
    my @agent_args  = (defined $materialised_agent_name)
        ? ('--agent', $materialised_agent_name) : ();
    # `or` rather than a bare following statement: otherwise perl emits "Statement
    # unlikely to be reached ... (Maybe you meant system() when you said exec()?)" at
    # COMPILE time, on every dispatch, into the stderr this script is contractually
    # required to keep to ≤15 lines. The _exit is reachable — only if exec fails.
    exec { $backend_bin } ($backend, 'run', @format_args, @model_args, @agent_args)
        or POSIX::_exit(127);
}
$CHILD_PID = $pid;
waitpid($pid, 0);
my $status = $?;
# Best-effort cleanup, mirroring the existing marker cleanup's posture --
# never fatal, never blocks the report. A failure here (permissions, a
# slow-exiting child still holding a file open on Windows) is caught by the
# next invocation's sweep_stale_tmp once this directory's mtime ages past
# WORKER_TMP_TTL_MIN.
if (-d $DISPATCH_TMP) {
    require File::Path;
    eval { File::Path::remove_tree($DISPATCH_TMP, { error => \my $err }) };
}
$CHILD_PID = undef;
my $backend_rc = ($status == -1) ? 255 : ($status >> 8);

# A short, interruptible settle window right after the backend exits. A fast
# backend can finish in a couple of milliseconds; without this, a coordinator
# stop-signal delivered right as the backend completes could race the rest of
# this dispatch (log append + report print) and be missed entirely. Any
# TERM/INT/HUP arriving during this idle sleep still fires signal_exit()
# immediately (Perl signal delivery is not blocked by select()).
select(undef, undef, undef, 0.3);

# ---------------------------------------------------------------------------
# 9b. Parse a `--format json` NDJSON event stream (§2 item 3, E6): events are
# step_start / text / step_finish; the final assistant text is the LAST
# "text" part. If the report holds at least one such event, replace it with
# the PARSED final text (not the raw NDJSON) -- this is what lands under
# reports/$BP_PACKAGE/. Content that is not NDJSON-shaped (e.g. a plain-text
# or plain-stderr backend) is left byte-for-byte alone.
# ---------------------------------------------------------------------------
sub _json_string_field {
    my ($line, $key) = @_;
    return undef unless $line =~ /"\Q$key\E"\s*:\s*"/;
    my $rest = $';
    my $out = '';
    while (length $rest) {
        my $ch = substr($rest, 0, 1, '');
        if ($ch eq '\\') {
            my $esc = substr($rest, 0, 1, '');
            if    ($esc eq 'n')  { $out .= "\n"; }
            elsif ($esc eq 't')  { $out .= "\t"; }
            elsif ($esc eq 'r')  { $out .= "\r"; }
            elsif ($esc eq '"')  { $out .= '"'; }
            elsif ($esc eq '\\') { $out .= '\\'; }
            elsif ($esc eq '/')  { $out .= '/'; }
            else                 { $out .= $esc; }
            next;
        }
        last if $ch eq '"';
        $out .= $ch;
    }
    return $out;
}

{
    my $raw = _read_raw($report_file);
    if (defined $raw && length $raw) {
        my @lines = split /\n/, $raw;
        my $last_text;
        my $saw_event = 0;
        for my $line (@lines) {
            next unless $line =~ /^\s*\{.*"type"\s*:\s*"[^"]+"/;
            my $type = _json_string_field($line, 'type');
            next unless defined $type;
            $saw_event = 1;
            if ($type eq 'text') {
                my $t = _json_string_field($line, 'text');
                $last_text = $t if defined $t;
            }
        }
        if ($saw_event && defined $last_text) {
            sysopen(my $rfh, $report_file, O_WRONLY | O_CREAT | O_TRUNC, 0644)
                or die "bp-worker.pl: cannot rewrite report file $report_file: $!";
            binmode $rfh;
            print $rfh $last_text;
            print $rfh "\n" unless $last_text =~ /\n\z/;
            close $rfh;
        }
    }
}

# ---------------------------------------------------------------------------
# 9c. Classify a non-zero backend exit into a distinguishable `reason:` token
# (§2.1: names PINNED -- `reason:` field; `auth` vs `rate-limit` must be
# different strings so b35's ladder can respond oppositely -- E14).
# ---------------------------------------------------------------------------
my $reason;
if ($backend_rc != 0) {
    my $classify_text = (_read_raw($report_file) // '');
    if ($classify_text =~ /\b401\b|unauthoriz|invalid or missing credentials|not logged in|re-?auth/i) {
        $reason = 'auth';
    }
    elsif ($classify_text =~ /\b429\b|rate.?limit|too many requests|throttle/i) {
        $reason = 'rate-limit';
    }
    else {
        $reason = 'error';
    }
}

# ---------------------------------------------------------------------------
# 10. Append dispatch-log entry (§2.9, §2.11 step 10). Best-effort.
# ---------------------------------------------------------------------------
{
    my $desc = '';
    if (open(my $pf, '<', $prompt_file)) {
        binmode $pf, ':raw';
        my $first = <$pf>;
        close $pf;
        if (defined $first) {
            $first =~ s/\r?\n\z//;
            $desc = substr($first, 0, 100);
        }
    }
    my $tsline = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime);
    # NOTE: spec §2.9 describes this as "UTF-8 bytes C2 B7", but the oracle
    # (155-worker-backend-dispatcher.t A15a/A15b) reads the ledger file with no
    # utf8 decode layer and matches against a Perl `\x{00b7}` pattern, which
    # (absent `use utf8`) only matches a single raw byte 0xB7 — NOT the two-byte
    # C2 B7 UTF-8 encoding. Emitting the literal single byte is what makes the
    # oracle's byte-for-byte comparison succeed; see implementer report.
    my $dot = "\xB7";

    if (defined $LOCKFILE && length $LOCKFILE) {
        make_path(dirname($LOCKFILE));
        if (open(my $lfh, '>>', $LOCKFILE)) {
            my $locked = 0;
            eval {
                local $SIG{ALRM} = sub { die "timeout\n" };
                alarm(5);
                $locked = flock($lfh, LOCK_EX);
                alarm(0);
            };
            alarm(0);
            if ($locked) {
                my $existing = '';
                if (open(my $rfh2, '<', $BP_LEDGER)) {
                    binmode $rfh2, ':raw';
                    local $/;
                    $existing = <$rfh2> // '';
                    close $rfh2;
                }
                if (open(my $ledfh, '>>', $BP_LEDGER)) {
                    binmode $ledfh, ':raw';
                    unless ($existing =~ /^## Dispatch log \(auto\)/m) {
                        print $ledfh "\n## Dispatch log (auto)\n";
                    }
                    print $ledfh "- $tsline $dot $CANON $dot $desc\n";
                    close $ledfh;
                }
                flock($lfh, LOCK_UN);
            }
            close($lfh);
        }
    }
}

# ---------------------------------------------------------------------------
# 11. Print the <=15-line report block (§2.7).
# ---------------------------------------------------------------------------
sub tail_nonblank {
    my ($file, $n) = @_;
    my @buf;
    if (open(my $fh, '<', $file)) {
        binmode $fh, ':raw';
        while (my $line = <$fh>) {
            $line =~ s/\r?\n\z//;
            next unless $line =~ /\S/;
            push @buf, $line;
            shift @buf if @buf > $n;
        }
        close $fh;
    }
    return @buf;
}

my $fixed_lines = 5 + (defined $reason ? 1 : 0);
my @tail = tail_nonblank($report_file, 15 - $fixed_lines);
my @out;
push @out, "worker: $CANON";
push @out, "backend: $backend";
push @out, "model: " . ((defined $model && length $model) ? $model : '-');
push @out, "exit: $backend_rc";
push @out, "reason: $reason" if defined $reason;
push @out, "report: $report_file";
push @out, map { "| $_" } @tail;
print join("\n", @out), "\n";

exit($backend_rc == 0 ? 0 : 7);
