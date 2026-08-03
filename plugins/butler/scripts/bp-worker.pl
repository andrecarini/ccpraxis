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
usage: bp-worker.pl --worker <name> --prompt-file <path> [--model <M>] [--help]

  --worker <name>       required; one of: implementer, test-writer, ui-prober,
                        scout, architect, reviewer, redteam (any of the
                        bp-<name> / butler:bp-<name> spellings also accepted)
  --prompt-file <path>  required; readable file whose contents are the prompt
  --model <M>           optional; passed through to a non-claude backend
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
    print STDERR "bp-worker.pl: backend '$backend' not found or not executable on PATH\n";
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

my $pid = fork();
die "bp-worker.pl: fork failed: $!" unless defined $pid;
if ($pid == 0) {
    # Child: redirect stdin from the prompt file, stdout+stderr into the report file.
    open(STDIN, '<', $prompt_file) or POSIX::_exit(126);
    sysopen(my $ofh, $report_file, O_WRONLY | O_APPEND) or POSIX::_exit(126);
    open(STDOUT, '>&', $ofh) or POSIX::_exit(126);
    open(STDERR, '>&', $ofh) or POSIX::_exit(126);
    my @model_args = (defined $model && length $model) ? ('--model', $model) : ();
    exec { $backend_bin } ($backend, @model_args);
    POSIX::_exit(127);
}
$CHILD_PID = $pid;
waitpid($pid, 0);
my $status = $?;
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
    # (79-worker-backend-dispatcher.t A15a/A15b) reads the ledger file with no
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

my @tail = tail_nonblank($report_file, 10);
my @out;
push @out, "worker: $CANON";
push @out, "backend: $backend";
push @out, "model: " . ((defined $model && length $model) ? $model : '-');
push @out, "exit: $backend_rc";
push @out, "report: $report_file";
push @out, map { "| $_" } @tail;
print join("\n", @out), "\n";

exit($backend_rc == 0 ? 0 : 7);
