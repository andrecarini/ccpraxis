package BpPowerJournal;
# BpPowerJournal -- a per-minute power journal (Decision 13) and a timeline
# report, so an unattended 24h+ run can be reconstructed after the fact.
# Spec: .ccpraxis-local-data/blueprints/host-wake-and-suspend/specs/05-power-journal-spec.md
#
# One JSONL "tick" line per armed refresher tick, written by
# BpContinuityLease::daemon_loop on the Windows platform only, inside an
# eval so a journal failure can never break the refresher. All external
# reads (battery, plan, display, process scan) are batched into one bounded
# PowerShell spawn, at most once per $PROBE_MIN_INTERVAL, with a hard
# timeout so the probe never stalls the refresher's tick.
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use Fcntl qw(O_WRONLY O_CREAT O_APPEND);
use POSIX qw(WNOHANG);
use Time::HiRes ();
use Time::Local ();
use JSON::PP ();
use MIME::Base64 ();
use Encode ();
use Cwd ();

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });
require "$DIR/bp-keepawake.pl";
# BpContinuityLease.pm is checked via its OWN symbol table, not %INC: its
# production entry point runs it as the perl MAIN PROGRAM
# ("perl BpContinuityLease.pm lease --daemon"), and a script executing AS $0
# is never added to %INC (only files reached through require/use are). The
# %INC-based guard every other require in this file uses would therefore
# find no entry on that path, unconditionally re-require the file, and
# re-execute its ~1400 lines top to bottom WHILE THE ORIGINAL daemon_loop
# invocation (the one that got here via its own per-tick require of this
# module) is still on the call stack -- redefining daemon_loop,
# _handle_signal, sync, lease_log and every other sub the live $SIG{TERM}
# closure depends on, mid-flight, for no reason. See BpPowerPlan.pm's
# identical guard for the same defect, measured the same way.
require "$DIR/BpContinuityLease.pm" unless defined &BpContinuityLease::platform;

our $JOURNAL_MAX_BYTES     = 2 * 1024 * 1024;   # rotate when the next append would exceed it
our $JOURNAL_KEEP          = 4;                 # rotated generations kept (.1 .. .4)
our $PROBE_MIN_INTERVAL    = 55;                # seconds between probe spawns
our $PROBE_TIMEOUT_SECONDS = 20;                # M0 (2.2): p95 measured 1.39s on this host, well under
                                                 # the 6s "keep 20" threshold -- unchanged from the spec default.
our $GAP_TICKS             = 2;                 # report: a gap is > GAP_TICKS * tick_s
our $DC_CUTOFF_SECONDS     = 300;               # report: battery cut-off threshold

# ---------------------------------------------------------------------------
# journal_path / rotate_if_needed / append_record
# ---------------------------------------------------------------------------

sub journal_path { my ($dir) = @_; return "$dir/power-journal.jsonl" }

# rotate_if_needed($path, $incoming_len) -- shifts .4..1 generations when the
# next append would push the current file past $JOURNAL_MAX_BYTES. A rename
# failure is accepted, not retried (spec 5): the append still happens.
sub rotate_if_needed {
    my ($path, $incoming_len) = @_;
    return unless defined $path && length $path;
    $incoming_len = 0 unless defined $incoming_len;
    my $cur_size = (-e $path) ? ((stat($path))[7] // 0) : 0;
    return if ($cur_size + $incoming_len) <= $JOURNAL_MAX_BYTES;
    return unless $cur_size > 0;   # nothing to shift; let an oversized single line through
    eval {
        unlink "$path.$JOURNAL_KEEP";
        for my $g (reverse 1 .. ($JOURNAL_KEEP - 1)) {
            my $from = "$path.$g";
            my $to   = "$path." . ($g + 1);
            rename($from, $to) if -e $from;
        }
        rename($path, "$path.1");
    };
    return;
}

# append_record($dir, \%rec) -> 1|0. Sets v/ts defaults, rotates, appends one
# line under O_APPEND with a single syswrite (no torn interleaving on a
# hard freeze). Never dies.
sub append_record {
    my ($dir, $rec) = @_;
    return 0 unless defined $dir && length $dir && ref $rec eq 'HASH';
    my %r = %$rec;
    $r{v}  = 1        unless defined $r{v};
    $r{ts} = time()    unless defined $r{ts};

    my $ok = 0;
    eval {
        make_path($dir) unless -d $dir;
        my $path = journal_path($dir);
        my $json = JSON::PP->new->utf8->canonical->encode(\%r);
        my $line = "$json\n";
        rotate_if_needed($path, length($line));
        sysopen(my $fh, $path, O_WRONLY | O_CREAT | O_APPEND) or die "open: $!\n";
        binmode($fh);
        my $n = syswrite($fh, $line);
        close($fh);
        $ok = (defined $n && $n == length($line)) ? 1 : 0;
        1;
    } or do { $ok = 0 };
    return $ok;
}

# ---------------------------------------------------------------------------
# time formatting
# ---------------------------------------------------------------------------

sub _utc_iso {
    my ($ts) = @_;
    $ts = 0 unless defined $ts;
    my @g = gmtime($ts);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1], $g[0]);
}

# _local_iso($ts) -- naive-local YYYY-MM-DDTHH:MM:SS+HH:MM, offset computed
# from Time::Local::timegm(localtime ts) - ts (spec 2.1), for direct
# correlation with keepawake.log's own naive-local timestamps.
sub _local_iso {
    my ($ts) = @_;
    $ts = 0 unless defined $ts;
    my @l = localtime($ts);
    my $off = Time::Local::timegm(@l) - $ts;
    my $sign = $off < 0 ? '-' : '+';
    my $abs = abs($off);
    my $oh = int($abs / 3600);
    my $om = int(($abs % 3600) / 60);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02d%s%02d:%02d',
        $l[5] + 1900, $l[4] + 1, $l[3], $l[2], $l[1], $l[0], $sign, $oh, $om);
}

# _iso_to_ms($iso) -- parses an ISO-8601 UTC timestamp (Z-suffixed, up to 7
# fractional digits) into epoch milliseconds, truncated to ms (spec 2.6).
# _display_local($epoch) -- spec 2.7's report-text-only local display
# format, "YYYY-MM-DD HH:MM:SS", distinct from the journal line's own
# offset-carrying _local_iso (which stays as-is for JSON output and the
# journal schema itself).
sub _display_local {
    my ($ts) = @_;
    $ts = 0 unless defined $ts;
    my @l = localtime($ts);
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d', $l[5] + 1900, $l[4] + 1, $l[3], $l[2], $l[1], $l[0]);
}

sub _iso_to_ms {
    my ($s) = @_;
    return undef unless defined $s;
    return undef unless $s =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?Z?$/;
    my ($Y, $Mo, $D, $H, $Mi, $S, $frac) = ($1, $2, $3, $4, $5, $6, $7);
    my $epoch = eval { Time::Local::timegm($S, $Mi, $H, $D, $Mo - 1, $Y) };
    return undef unless defined $epoch;
    my $ms = 0;
    if (defined $frac) {
        $frac = substr($frac, 0, 3);
        $frac .= '0' x (3 - length($frac));
        $ms = $frac + 0;
    }
    return $epoch * 1000 + $ms;
}

# ---------------------------------------------------------------------------
# probe: argv builder, bounded runner, output parser
# ---------------------------------------------------------------------------

# _probe_script_text() -- the inline PowerShell probe (spec 2.2 pseudocode).
# Never elevates, never queries powercfg's live request list (out of scope,
# spec section 6). AC10 greps THIS FILE'S OWN SOURCE for forbidden strings,
# so nothing below may spell any of them out, including in comments.
sub _probe_script_text {
    return <<'PS1';
$r = @{ v = 1; err = @{} }
try {
    Add-Type -AssemblyName System.Windows.Forms
    $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
    $r.power = @{ line = "$($ps.PowerLineStatus)"; pct = $ps.BatteryLifePercent; chg = "$($ps.BatteryChargeStatus)" }
} catch { $r.err.power = "$($_.Exception.Message)" }
try {
    $r.plan = @{ raw = (powercfg /getactivescheme | Out-String) }
} catch { $r.err.plan = "$($_.Exception.Message)" }
$bootTicks = $null
try {
    $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 5
    $bootTicks = [long]([DateTimeOffset]$os.LastBootUpTime.ToUniversalTime()).ToUnixTimeMilliseconds()
    $r.boot_id = "$bootTicks"
} catch { $r.err.boot = "$($_.Exception.Message)" }
try {
    $e = Get-WinEvent -MaxEvents 1 -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=506,507} -ErrorAction Stop
    $csTicks = [long]([DateTimeOffset]$e.TimeCreated.ToUniversalTime()).ToUnixTimeMilliseconds()
    # A sample from a PRIOR boot must not be attributed to the current one
    # (review SHOULD-FIX 6): the newest 506/507 event can predate an
    # unclean reboot, so its own boot_id is only the CURRENT boot's when
    # its own timestamp is not earlier than this boot's start.
    if ($bootTicks -ne $null -and $csTicks -ge $bootTicks) { $csBootId = "$bootTicks" } else { $csBootId = 'prior-boot' }
    $r.cs = @{ id = $e.Id; t_ms = $csTicks; boot_id = $csBootId }
} catch {
    if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { $r.cs = $null } else { $r.err.cs = "$($_.Exception.Message)" }
}
try {
    $r.ka = @(Get-CimInstance Win32_Process -OperationTimeoutSec 5 -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*keep-awake.ps1*' } | ForEach-Object { @{ pid = $_.ProcessId; cmd = $_.CommandLine } })
} catch { $r.err.ka = "$($_.Exception.Message)" }
[Console]::Out.Write([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($r | ConvertTo-Json -Compress -Depth 5))))
PS1
}

# probe_argv() -> \@argv | undef -- the production argv builder. undef under
# a .t (same idiom as BpKeepAwake::spawn) so a test driving daemon_loop on
# the windows platform can never start a real PowerShell, and undef when
# powershell.exe is not resolvable (edge case, spec 5).
sub probe_argv {
    return undef if defined $0 && $0 =~ /\.t\z/;
    # Same rule, same reason as BpKeepAwake::spawn: a test's own subprocess
    # (a spawned successor/daemon whose own $0 is BpContinuityLease.pm, not
    # a .t file) must never start a real, uncontrolled OS process either.
    # lease-refresher-hygiene.t sets this at BEGIN precisely to keep its
    # spawned successors from actuating anything real.
    return undef if $ENV{CCPRAXIS_NO_WAKELOCK};
    return undef unless BpKeepAwake::ps_available();
    my $script = _probe_script_text();
    my $utf16le = Encode::encode('UTF-16LE', $script);
    my $b64 = MIME::Base64::encode_base64($utf16le, '');
    return [ 'powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
             '-WindowStyle', 'Hidden', '-EncodedCommand', $b64 ];
}

# run_bounded(\@argv, $timeout_s) -> {status, rc, out, ms}. status is one of
# ok, timeout or spawn-failed (spec 2.2). Forks; the child's stdout goes to a
# File::Temp file (never an in-memory reopen or a pipe -- CLAUDE.md's
# landmine and the pipe-buffer deadlock, both). The parent polls waitpid
# every 100ms; on timeout it kills the MSYS pid, and falls back to
# taskkill.exe /T /F on the recorded winpid if that alone did not reap it.
sub run_bounded {
    my ($argv, $timeout_s, $cache) = @_;
    $timeout_s = $PROBE_TIMEOUT_SECONDS unless defined $timeout_s;
    # SHOULD-FIX 5 (review): reap any pid a PRIOR call left behind after
    # kill(KILL) alone did not reap it and the taskkill fallback also raced
    # the reaper -- a safety net for a safety net, but the daemon lives for
    # days, so an unreaped pid here is a slow zombie leak, not a one-off.
    if (ref $cache eq 'HASH' && ref $cache->{zombies} eq 'ARRAY' && @{ $cache->{zombies} }) {
        $cache->{zombies} = [ grep { waitpid($_, WNOHANG) != $_ } @{ $cache->{zombies} } ];
    }
    my $t0 = Time::HiRes::time();

    my ($out_fh, $out_path) = eval { tempfile() };
    unless ($out_fh) {
        return { status => 'spawn-failed', rc => undef, out => '', ms => int((Time::HiRes::time() - $t0) * 1000) };
    }
    close $out_fh;

    my $pid = eval { fork() };
    if (!defined $pid) {
        unlink $out_path;
        return { status => 'spawn-failed', rc => undef, out => '', ms => int((Time::HiRes::time() - $t0) * 1000) };
    }

    if ($pid == 0) {
        open(STDIN,  '<', '/dev/null');
        open(STDOUT, '>', $out_path);
        open(STDERR, '>', '/dev/null');
        { local $ENV{MSYS2_ARG_CONV_EXCL} = '*'; exec(@$argv) or POSIX::_exit(127); }
        POSIX::_exit(127);
    }

    my $deadline = $t0 + $timeout_s;
    my ($status, $rc) = ('timeout', undef);
    while (1) {
        my $w = waitpid($pid, WNOHANG);
        if ($w == $pid) { $rc = $? >> 8; $status = 'ok'; last }
        if (Time::HiRes::time() >= $deadline) { $status = 'timeout'; last }
        Time::HiRes::sleep(0.1);
    }

    if ($status eq 'timeout') {
        my $wp = eval { BpKeepAwake::winpid_of($pid) };
        kill('KILL', $pid);
        my $kdeadline = Time::HiRes::time() + 2;
        my $reaped = 0;
        while (Time::HiRes::time() < $kdeadline) {
            my $w = waitpid($pid, WNOHANG);
            if ($w == $pid) { $reaped = 1; last }
            Time::HiRes::sleep(0.1);
        }
        unless ($reaped) {
            if (defined $wp) {
                local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
                system('taskkill.exe', '/PID', $wp, '/T', '/F');
            }
            my $w2 = waitpid($pid, WNOHANG);
            if ($w2 != $pid && ref $cache eq 'HASH') {
                push @{ $cache->{zombies} ||= [] }, $pid;
            }
        }
        unlink $out_path;
        return { status => 'timeout', rc => undef, out => '', ms => int((Time::HiRes::time() - $t0) * 1000) };
    }

    my $out = '';
    if (open(my $fh, '<:raw', $out_path)) { local $/; $out = <$fh>; $out = '' unless defined $out; close $fh; }
    unlink $out_path;
    return { status => 'ok', rc => $rc, out => $out, ms => int((Time::HiRes::time() - $t0) * 1000) };
}

sub _unknown_probe_fields {
    return {
        power_source => 'unknown', battery_pct => 'unknown', plan_guid => 'unknown',
        plan_name => 'unknown', display => 'unknown', display_basis => 'unknown', display_at => 'unknown',
    };
}

# parse_probe($stdout_bytes) -> \%fields -- base64-decodes, JSON-decodes
# (->utf8, so the result is already Perl characters -- spec's "never
# re-encoded" rule), and maps to the 2.1 schema plus {ka, status, error}.
# Anything undecodable makes every field "unknown" and status "error".
sub parse_probe {
    my ($bytes) = @_;
    my %out = (
        power_source => 'unknown', battery_pct => 'unknown', plan_guid => 'unknown',
        plan_name => 'unknown', display => 'unknown', display_basis => 'unknown', display_at => 'unknown',
        ka => undef, status => 'error', error => '',
    );
    return \%out unless defined $bytes && length $bytes;
    my $trimmed = $bytes;
    $trimmed =~ s/^\s+//; $trimmed =~ s/\s+$//;
    return \%out unless length $trimmed;

    my $json_bytes = eval { MIME::Base64::decode_base64($trimmed) };
    unless (defined $json_bytes && length $json_bytes) {
        $out{error} = 'undecodable base64';
        return \%out;
    }
    my $data = eval { JSON::PP->new->utf8->decode($json_bytes) };
    unless (ref $data eq 'HASH') {
        $out{error} = 'undecodable json';
        return \%out;
    }

    my $err = (ref $data->{err} eq 'HASH') ? $data->{err} : {};
    my $had_error   = scalar(keys %$err) ? 1 : 0;
    my $had_success = 0;

    if (ref $data->{power} eq 'HASH' && !exists $err->{power}) {
        my $p = $data->{power};
        my $line = $p->{line};
        $out{power_source} = (defined $line && $line eq 'Online') ? 'ac'
                            : (defined $line && $line eq 'Offline') ? 'dc' : 'unknown';
        my $chg = defined $p->{chg} ? $p->{chg} : '';
        if ($chg =~ /NoSystemBattery/) {
            $out{battery_pct} = 'none';
        } else {
            # BatteryLifePercent (SystemInformation.PowerStatus) is a real
            # Single from 0.0 to 1.0, never an already-scaled 0-100 integer
            # (review MUST-FIX 1, measured on this host: pct=1 at 100%). A
            # value outside [0.0, 1.0] -- the 255-sentinel's equivalent on
            # this scale, or any other out-of-range float -- is "unknown",
            # never rounded into range.
            my $pct = $p->{pct};
            if (defined $pct && $pct =~ /^-?\d+(?:\.\d+)?$/ && $pct >= 0 && $pct <= 1.0) {
                $out{battery_pct} = int($pct * 100 + 0.5);
            } else {
                $out{battery_pct} = 'unknown';
            }
        }
        $had_success = 1;
    }

    if (ref $data->{plan} eq 'HASH' && !exists $err->{plan}) {
        my $raw = defined $data->{plan}{raw} ? $data->{plan}{raw} : '';
        my $found = 0;
        if ($raw =~ /([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/) {
            $out{plan_guid} = lc($1);
            $found = 1;
        }
        if ($raw =~ /\(([^()]*)\)\s*$/m) {
            $out{plan_name} = $1;
            $found = 1;
        }
        $had_success = 1 if $found;
    }

    if (exists $data->{cs} && !exists $err->{cs}) {
        my $cs = $data->{cs};
        # SHOULD-FIX 6 (review): the newest 506/507 sample is stale across
        # an unclean reboot when it belongs to a PRIOR boot -- compared by
        # boot_id (top-level, the current boot) vs cs.boot_id (the sampled
        # event's own), never reported as the pre-reboot value.
        my $boot_id    = defined $data->{boot_id} ? $data->{boot_id} : undef;
        my $cs_boot_id = (ref $cs eq 'HASH' && defined $cs->{boot_id}) ? $cs->{boot_id} : undef;
        my $stale_boot = (defined $boot_id && defined $cs_boot_id && $boot_id ne $cs_boot_id) ? 1 : 0;
        if ($stale_boot) {
            $out{display} = 'unknown';
            $out{display_basis} = 'unknown';
        } elsif (ref $cs eq 'HASH' && defined $cs->{id}) {
            if    ($cs->{id} == 506) { $out{display} = 'off' }
            elsif ($cs->{id} == 507) { $out{display} = 'on' }
            else                     { $out{display} = 'unknown' }
            $out{display_basis} = 'kernel-power-506-507';
            if (defined $cs->{t_ms} && $cs->{t_ms} =~ /^-?\d+(?:\.\d+)?$/) {
                $out{display_at} = _local_iso(int($cs->{t_ms} / 1000));
            }
        } else {
            $out{display} = 'unknown';
            $out{display_basis} = 'unknown';
        }
        $had_success = 1;
    }

    if (!exists $err->{ka} && ref $data->{ka} eq 'ARRAY') {
        $out{ka} = $data->{ka};
        $had_success = 1;
    }

    $out{status} = $had_error ? 'partial' : ($had_success ? 'ok' : 'error');
    return \%out;
}

# ---------------------------------------------------------------------------
# helpers: our own helper state, never powercfg (spec 2.4, Decision 19)
# ---------------------------------------------------------------------------

# _decode_once($s) -- decode-exactly-once discipline (spec 2.1 DC7): a byte
# string read from the filesystem/env is decoded once before it can ever
# reach a ->utf8 JSON encoder; a string already carrying Perl's utf8 flag
# (e.g. probe output, already JSON-decoded) is left alone. Same idiom as
# BpHook.pm's own _decode_maybe.
sub _decode_once {
    my ($s) = @_;
    return $s unless defined $s;
    return $s if ref $s;
    return $s if utf8::is_utf8($s);
    my $copy = $s;
    return utf8::decode($copy) ? $copy : $s;
}

sub _extract_flag_value {
    my ($cmd, $flag) = @_;
    return undef unless defined $cmd && length $cmd;
    if ($cmd =~ /-\Q$flag\E\s+"([^"]*)"/i) { return $1 }
    if ($cmd =~ /-\Q$flag\E\s+'([^']*)'/i) { return $1 }
    if ($cmd =~ /-\Q$flag\E\s+(\S+)/i)     { return $1 }
    return undef;
}

sub _read_log_tail {
    my ($path, $max_bytes) = @_;
    return undef unless defined $path && length $path && -f $path;
    open(my $fh, '<:raw', $path) or return undef;
    my $size = (stat($fh))[7];
    $size = 0 unless defined $size;
    if (defined $max_bytes && $size > $max_bytes) {
        seek($fh, $size - $max_bytes, 0);
    }
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

# requests_from_log($log_path, $winpid) -> {requests, owner_winpid,
# owner_desc, last, last_at} (spec 2.4 point 4). Reads at most the last 8MiB
# of the log and keeps only lines with "pid=<winpid> " (a following space),
# walked in order to derive the current ES_* + EXECUTION request set.
sub requests_from_log {
    my ($log_path, $winpid) = @_;
    my %result = (requests => 'unknown', owner_winpid => 'unknown', owner_desc => 'unknown',
                  last => 'unknown', last_at => 'unknown');
    return \%result unless defined $log_path && length $log_path && defined $winpid && length $winpid;

    my $bytes = _read_log_tail($log_path, 8 * 1024 * 1024);
    return \%result unless defined $bytes;

    my @lines = split /\n/, $bytes;
    my (%flags, $owner_winpid, $owner_desc, $last, $last_at);
    my $seen_any = 0;
    # SHOULD-FIX 2 (review): $seen_any goes true on ANY matching line
    # (including a bare OWNER/REASON line), so reporting requests=[] on
    # that alone claims "holds nothing" when really no flag-setting event
    # was seen in this (8 MiB tail) window -- honestly "unknown" instead.
    my $seen_flag_event = 0;

    for my $line (@lines) {
        next unless $line =~ /\bpid=\Q$winpid\E\s/;
        $seen_any = 1;
        my $ts = (length($line) >= 19) ? substr($line, 0, 19) : undef;

        if ($line =~ /\bASSERTED\s+flags=(\S+)/) {
            %flags = ();
            for my $f (split /\|/, $1) {
                $flags{SYSTEM}   = 1 if $f eq 'ES_SYSTEM_REQUIRED';
                $flags{DISPLAY}  = 1 if $f eq 'ES_DISPLAY_REQUIRED';
                $flags{AWAYMODE} = 1 if $f eq 'ES_AWAYMODE_REQUIRED';
            }
            $last = "ASSERTED flags=$1"; $last_at = $ts;
            $seen_flag_event = 1;
        }
        elsif ($line =~ /\bPOWER-REQUEST-CREATED\b/) {
            $flags{EXECUTION} = 1;
            $last = 'POWER-REQUEST-CREATED'; $last_at = $ts;
            $seen_flag_event = 1;
        }
        elsif ($line =~ /\bPOWER-REQUEST-DEGRADED\b/) {
            delete $flags{EXECUTION};
            $last = 'POWER-REQUEST-DEGRADED'; $last_at = $ts;
            $seen_flag_event = 1;
        }
        elsif ($line =~ /\bPOWER-REQUEST-RELEASED\b/) {
            delete $flags{EXECUTION};
            $last = 'POWER-REQUEST-RELEASED'; $last_at = $ts;
            $seen_flag_event = 1;
        }
        elsif ($line =~ /\bRELEASE\b/) {
            %flags = ();
            $last = 'RELEASE'; $last_at = $ts;
            $seen_flag_event = 1;
        }
        elsif ($line =~ /\bEXIT\b/) {
            %flags = ();
            $last = 'EXIT'; $last_at = $ts;
            $seen_flag_event = 1;
        }
        elsif ($line =~ /\bOWNER\s+winpid=(\d+)/) {
            $owner_winpid = $1;
            $last = "OWNER winpid=$1"; $last_at = $ts;
        }
        elsif ($line =~ /\bREASON\s+(.*)$/) {
            my $rest = $1;
            $last = "REASON $rest"; $last_at = $ts;
            if ($rest =~ /\bowner\s+(\S+)/) { $owner_desc = $1 unless defined $owner_desc }
            if ($rest =~ /\bwinpid=(\d+)/)  { $owner_winpid = $1 unless defined $owner_winpid }
        }
    }

    return \%result unless $seen_any;
    $result{requests}     = $seen_flag_event ? [ sort keys %flags ] : 'unknown';
    $result{owner_winpid} = defined $owner_winpid ? $owner_winpid : 'unknown';
    $result{owner_desc}   = defined $owner_desc   ? $owner_desc   : 'unknown';
    $result{last}         = defined $last         ? $last         : 'unknown';
    $result{last_at}      = defined $last_at      ? $last_at      : 'unknown';
    return \%result;
}

# helpers_from_state($dir, $scan) -> \@helpers (spec 2.4). $scan is the
# probe's 'ka' list (arrayref of {pid, cmd}) or undef when the scan itself
# failed/was skipped.
sub helpers_from_state {
    my ($dir, $scan) = @_;
    my @helpers;
    my $scan_ok = (ref $scan eq 'ARRAY') ? 1 : 0;
    my %scan_pids;
    if ($scan_ok) {
        for my $e (@$scan) {
            next unless ref $e eq 'HASH';
            my $pid = $e->{pid};
            next unless defined $pid;
            $scan_pids{"$pid"} = $e;
        }
    }

    my $pidfile1 = "$dir/keepawake.pid";
    my $cont_winpid;
    if (-e $pidfile1 && !-z $pidfile1) {
        $cont_winpid = BpKeepAwake::read_pid($pidfile1);
    }

    my %seen;
    if (defined $cont_winpid) {
        my $alive = !$scan_ok ? 'unknown' : (exists $scan_pids{"$cont_winpid"} ? 1 : 0);
        my $logf = "$dir/keepawake.log";
        my $req = requests_from_log($logf, $cont_winpid);
        my $requests = $req->{requests};
        $requests = [] if $alive eq '0';
        push @helpers, {
            source => 'continuity-pidfile', winpid => $cont_winpid, alive => $alive,
            owner_winpid => $req->{owner_winpid}, owner_desc => $req->{owner_desc},
            requests => $requests, last => $req->{last}, last_at => $req->{last_at},
            pidfile => _decode_once($pidfile1),
        };
        $seen{"$cont_winpid"} = 1;
    }

    if ($scan_ok) {
        for my $e (@$scan) {
            next unless ref $e eq 'HASH';
            my $pid = $e->{pid};
            next unless defined $pid;
            next if $seen{"$pid"};
            $seen{"$pid"} = 1;
            my $cmd = defined $e->{cmd} ? $e->{cmd} : '';
            my $pidfile = _extract_flag_value($cmd, 'PidFile');
            my $logfile = _extract_flag_value($cmd, 'LogFile');
            $pidfile =~ tr{\\}{/} if defined $pidfile;
            $logfile =~ tr{\\}{/} if defined $logfile;
            my $req = defined $logfile
                ? requests_from_log($logfile, $pid)
                : { requests => 'unknown', owner_winpid => 'unknown', owner_desc => 'unknown', last => 'unknown', last_at => 'unknown' };
            my $owf = _extract_flag_value($cmd, 'OwnerWinPid');
            my $odf = _extract_flag_value($cmd, 'OwnerDesc');
            $req->{owner_winpid} = $owf if $req->{owner_winpid} eq 'unknown' && defined $owf;
            $req->{owner_desc}   = $odf if $req->{owner_desc}   eq 'unknown' && defined $odf;
            push @helpers, {
                source => 'process-scan', winpid => $pid, alive => 1,
                owner_winpid => $req->{owner_winpid}, owner_desc => $req->{owner_desc},
                requests => $req->{requests}, last => $req->{last}, last_at => $req->{last_at},
                pidfile => defined $pidfile ? $pidfile : 'unknown',
            };
        }
    }

    return \@helpers;
}

# ---------------------------------------------------------------------------
# sessions (spec 2.5): live_arms lives on BpContinuityLease; this wraps it
# with the holder record's pid/liveness.
# ---------------------------------------------------------------------------

sub _slurp_bytes {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub _sessions_for {
    my ($dir, %o) = @_;
    my $root = $o{state_root};
    $root = eval { BpContinuityLease::store_root_for($dir) } unless defined $root;
    return 'unknown' unless defined $root && length $root;
    my $arms = eval { BpContinuityLease::live_arms($root) };
    return 'unknown' unless ref $arms eq 'ARRAY';

    my $holder_alive_fn = $o{holder_alive};
    my @out;
    for my $a (@$arms) {
        my $sid = $a->{sid};
        my $hpath = "$root/holder/$sid.json";
        my ($pid_msys, $holder_alive) = ('none', 'none');
        if (-f $hpath) {
            my $raw = _slurp_bytes($hpath);
            my $h = (defined $raw && length $raw) ? eval { JSON::PP->new->utf8->decode($raw) } : undef;
            if (ref $h eq 'HASH') {
                $pid_msys = defined $h->{pid} ? $h->{pid} : 'unknown';
                if (defined $holder_alive_fn) {
                    $holder_alive = $holder_alive_fn->($h) ? 1 : 0;
                } elsif (defined &BpHook::_holder_proc_alive) {
                    $holder_alive = BpHook::_holder_proc_alive($h) ? 1 : 0;
                } else {
                    $holder_alive = 'unknown';
                }
            } else {
                $pid_msys = 'unknown';
                $holder_alive = 'unknown';
            }
        }
        push @out, {
            sid => $sid, role => (defined $a->{role} ? $a->{role} : 'unknown'),
            basis => $a->{basis}, age_s => $a->{age},
            workers => (ref $a->{workers} eq 'ARRAY' ? $a->{workers} : []),
            holder_pid_msys => $pid_msys, holder_alive => $holder_alive,
        };
    }
    return \@out;
}

# ---------------------------------------------------------------------------
# build_tick_record / tick (spec 2.3)
# ---------------------------------------------------------------------------

# build_tick_record($dir, %o) -> \%rec -- assembles one tick line, resolving
# the probe (spawning/caching per $PROBE_MIN_INTERVAL) and the helpers/
# sessions fields. Dies only on caller misuse (no $dir) or when a probe_argv
# seam itself dies (AC5): that must propagate to daemon_loop's own eval, so
# nothing here wraps the seam call in its own eval.
sub build_tick_record {
    my ($dir, %o) = @_;
    die "BpPowerJournal::build_tick_record: dir required\n" unless defined $dir && length $dir;

    my $now_fn = $o{now} // sub { time() };
    my $now = $now_fn->();
    my $cache = (ref $o{cache} eq 'HASH') ? $o{cache} : {};
    $cache->{seq} = (defined $cache->{seq} ? $cache->{seq} : 0) + 1;
    my $seq = $cache->{seq};
    my $tick_s = defined $o{tick_s} ? $o{tick_s} : 0;

    my $has_seam = exists $o{probe_argv};
    my $probe_argv_fn = $has_seam ? $o{probe_argv} : \&probe_argv;
    my $timeout = defined $o{probe_timeout} ? $o{probe_timeout} : $PROBE_TIMEOUT_SECONDS;

    my ($probe_fields, $probe_status, $probe_ms, $probe_age, $probe_error, $ka_scan);

    my $need_spawn = 1;
    if (defined $cache->{probe_ts}) {
        my $age0 = $now - $cache->{probe_ts};
        $need_spawn = 0 if $age0 >= 0 && $age0 < $PROBE_MIN_INTERVAL;
    }

    if ($need_spawn) {
        my $argv = $probe_argv_fn->();
        if (!defined $argv) {
            my $t_guard = (defined $0 && $0 =~ /\.t\z/) || $ENV{CCPRAXIS_NO_WAKELOCK} ? 1 : 0;
            if (!$has_seam && !$t_guard && !BpKeepAwake::ps_available()) {
                $probe_status = 'error'; $probe_error = 'powershell unavailable';
            } else {
                $probe_status = 'skipped'; $probe_error = '';
            }
            $probe_fields = _unknown_probe_fields();
            $probe_ms = 'unknown'; $probe_age = 0; $ka_scan = undef;
        } else {
            my $result = run_bounded($argv, $timeout, $cache);
            $probe_ms = $result->{ms};
            $probe_age = 0;
            if ($result->{status} eq 'timeout') {
                $probe_fields = _unknown_probe_fields();
                $probe_status = 'timeout'; $probe_error = 'timeout'; $ka_scan = undef;
            }
            elsif ($result->{status} eq 'spawn-failed') {
                $probe_fields = _unknown_probe_fields();
                $probe_status = 'error'; $probe_error = 'spawn-failed'; $ka_scan = undef;
            }
            elsif (defined $result->{rc} && $result->{rc} != 0) {
                $probe_fields = _unknown_probe_fields();
                $probe_status = 'error'; $probe_error = 'probe exited ' . $result->{rc}; $ka_scan = undef;
            }
            else {
                my $parsed = parse_probe($result->{out});
                $probe_status = $parsed->{status};
                $probe_error = defined $parsed->{error} ? $parsed->{error} : '';
                $probe_fields = {
                    power_source => $parsed->{power_source}, battery_pct => $parsed->{battery_pct},
                    plan_guid => $parsed->{plan_guid}, plan_name => $parsed->{plan_name},
                    display => $parsed->{display}, display_basis => $parsed->{display_basis},
                    display_at => $parsed->{display_at},
                };
                $ka_scan = $parsed->{ka};
            }
        }
        $cache->{probe_ts} = $now;
        $cache->{probe_fields} = $probe_fields;
        $cache->{probe_ka} = $ka_scan;
    }
    else {
        my $age = $now - $cache->{probe_ts};
        $probe_ms = 'unknown';
        $probe_age = $age;
        $probe_status = 'cached';
        $probe_error = '';
        if ($age > 3 * $PROBE_MIN_INTERVAL) {
            $probe_fields = _unknown_probe_fields();
            $ka_scan = undef;
        } else {
            $probe_fields = (ref $cache->{probe_fields} eq 'HASH') ? $cache->{probe_fields} : _unknown_probe_fields();
            $ka_scan = $cache->{probe_ka};
        }
    }

    my $helpers = eval { helpers_from_state($dir, $ka_scan) };
    $helpers = 'unknown' unless ref $helpers eq 'ARRAY';

    my $sessions = _sessions_for($dir, %o);

    return {
        v => 1, kind => 'tick', ts => $now, utc => _utc_iso($now), local => _local_iso($now),
        seq => $seq, refresher_pid => $$, tick_s => $tick_s,
        power_source => $probe_fields->{power_source}, battery_pct => $probe_fields->{battery_pct},
        plan_guid => $probe_fields->{plan_guid}, plan_name => $probe_fields->{plan_name},
        display => $probe_fields->{display}, display_basis => $probe_fields->{display_basis},
        display_at => $probe_fields->{display_at},
        helpers => $helpers, sessions => $sessions,
        probe => { status => $probe_status, ms => $probe_ms, age_s => $probe_age, error => $probe_error },
    };
}

# tick($dir, %o) -> \%rec -- builds and appends ONE tick line. A thin
# wrapper: it must not catch anything build_tick_record raises (AC5 relies
# on a probe_argv seam's die propagating all the way to daemon_loop's own
# eval), and append_record itself never dies.
sub tick {
    my ($dir, %o) = @_;
    die "BpPowerJournal::tick: dir required\n" unless defined $dir && length $dir;
    my $rec = build_tick_record($dir, %o);
    my $ok = append_record($dir, $rec);
    # MUST-FIX 4 (review): an append failure (full disk, ACL, a rename race)
    # must not be silent forever. This die propagates to daemon_loop's own
    # eval around the journal step, the same JOURNAL-ERROR path any other
    # journal-step exception takes, already bounded by its hourly
    # suppression.
    die "journal append failed: " . journal_path($dir) . "\n" unless $ok;
    return $rec;
}

# ---------------------------------------------------------------------------
# report: parse_event_xml / build_timeline (spec 2.6)
# ---------------------------------------------------------------------------

# parse_event_xml($xml) -> {provider, id, time_ms, data} -- regex-based on
# purpose: the shape Get-WinEvent's ToXml() produces is small and
# well-formed, and pulling in an XML parser (not core) for four attributes
# and a Data map is not worth the dependency.
sub parse_event_xml {
    my ($xml) = @_;
    return undef unless defined $xml && length $xml;
    my %out;
    if ($xml =~ /<Provider\s+[^>]*\bName=(["'])([^"']*)\1/) { $out{provider} = $2 }
    if ($xml =~ /<EventID[^>]*>(\d+)<\/EventID>/) { $out{id} = $1 + 0 }
    if ($xml =~ /<TimeCreated\s+[^>]*\bSystemTime=(["'])([^"']*)\1/) {
        $out{time_ms} = _iso_to_ms($2);
    }
    # A real EventLog 6008's <Data> children carry NO Name attribute (M0,
    # 2026-09-26): they are positional, not named. Named Data still goes
    # into %data by name; a Data tag with no Name goes into an ordered list
    # instead, so neither shape silently produces an empty map.
    my %data;
    my @data_positional;
    while ($xml =~ /<Data(\s[^>]*)?>([^<]*)<\/Data>/g) {
        my ($attrs, $value) = ($1, $2);
        $attrs = '' unless defined $attrs;
        if ($attrs =~ /\bName=(["'])([^"']*)\1/) {
            $data{$2} = $value;
        } else {
            push @data_positional, $value;
        }
    }
    $out{data} = \%data;
    $out{data_positional} = \@data_positional;
    return \%out;
}

sub _has_held_request {
    my ($helpers) = @_;
    return 0 unless ref $helpers eq 'ARRAY';
    for my $h (@$helpers) {
        next unless ref $h eq 'HASH';
        next unless ref $h->{requests} eq 'ARRAY';
        return 1 if @{ $h->{requests} };
    }
    return 0;
}

sub _tick_key {
    my ($t) = @_;
    my @hp;
    if (ref $t->{helpers} eq 'ARRAY') {
        for my $h (@{ $t->{helpers} }) {
            next unless ref $h eq 'HASH';
            my $reqs = (ref $h->{requests} eq 'ARRAY') ? join(',', sort @{ $h->{requests} }) : (defined $h->{requests} ? $h->{requests} : '');
            push @hp, (defined $h->{winpid} ? $h->{winpid} : '') . ':' . $reqs;
        }
    }
    @hp = sort @hp;
    my @sids;
    if (ref $t->{sessions} eq 'ARRAY') {
        @sids = sort map { (ref $_ eq 'HASH' && defined $_->{sid}) ? $_->{sid} : '' } @{ $t->{sessions} };
    }
    return join('|', (defined $t->{power_source} ? $t->{power_source} : ''),
                      (defined $t->{plan_guid} ? $t->{plan_guid} : ''),
                      (defined $t->{display} ? $t->{display} : ''),
                      join(',', @hp), join(',', @sids));
}

# build_timeline(%a) -> \@entries (spec 2.6). journal_lines is a list of
# already-decoded records (or undef/malformed entries -- a truncated line
# after a hard freeze -- which are skipped, never used for gap detection).
sub build_timeline {
    my (%a) = @_;
    my $journal_lines = (ref $a{journal_lines} eq 'ARRAY') ? $a{journal_lines} : [];
    my $events        = (ref $a{events} eq 'ARRAY') ? $a{events} : [];
    my $transcript    = $a{transcript};
    my $since_ms      = $a{since_ms};
    my $until_ms      = $a{until_ms};

    my (@ticks, @notes, @plans);
    # SHOULD-FIX 1 (review) / spec B13: a line that cannot be decoded (a
    # truncated last line after a hard freeze) is skipped AND counted, never
    # silently dropped -- an all-zeros count would read identically to "the
    # source was never even consulted".
    my $journal_skipped = 0;
    for my $rec (@$journal_lines) {
        unless (ref $rec eq 'HASH' && defined $rec->{kind}) { $journal_skipped++; next }
        if ($rec->{kind} eq 'tick') {
            next unless defined $rec->{ts} && defined $rec->{seq};
            push @ticks, $rec;
        } elsif ($rec->{kind} eq 'plan') {
            # Decision 22 (package 06-plan-follows-arming): a kind:plan
            # record renders as its own "plan" timeline entry rather than
            # falling through to an "unknown kind: plan" note.
            push @plans, $rec;
        } else {
            push @notes, $rec;
        }
    }
    @ticks = sort { $a->{ts} <=> $b->{ts} } @ticks;

    my @entries;

    # ---- journal spans: coalesce consecutive ticks sharing the same key ----
    my @spans;
    my $cur;
    for my $t (@ticks) {
        my $key = _tick_key($t);
        if ($cur && $cur->{key} eq $key) {
            $cur->{to_ms} = $t->{ts} * 1000;
            $cur->{count}++;
            $cur->{battery_last} = $t->{battery_pct};
        } else {
            push @spans, $cur if $cur;
            $cur = {
                key => $key, from_ms => $t->{ts} * 1000, to_ms => $t->{ts} * 1000, count => 1,
                battery_first => $t->{battery_pct}, battery_last => $t->{battery_pct},
                power_source => $t->{power_source}, plan_guid => $t->{plan_guid}, display => $t->{display},
            };
        }
    }
    push @spans, $cur if $cur;
    for my $s (@spans) {
        push @entries, {
            kind => 'journal', t_ms => $s->{from_ms}, local => _local_iso(int($s->{from_ms} / 1000)),
            from_ms => $s->{from_ms}, to_ms => $s->{to_ms}, count => $s->{count},
            battery_first => $s->{battery_first}, battery_last => $s->{battery_last},
            power_source => $s->{power_source}, plan_guid => $s->{plan_guid}, display => $s->{display},
        };
    }

    # ---- GAP flags ----
    for my $i (1 .. $#ticks) {
        my $prev = $ticks[$i - 1];
        my $next = $ticks[$i];
        my $delta = $next->{ts} - $prev->{ts};
        next if $delta <= 0;
        next unless $delta > $GAP_TICKS * ($prev->{tick_s} || 1);
        my $seq_reset = ((defined $next->{refresher_pid} ? $next->{refresher_pid} : '') ne (defined $prev->{refresher_pid} ? $prev->{refresher_pid} : ''))
                     || ((defined $next->{seq} ? $next->{seq} : 0) <= (defined $prev->{seq} ? $prev->{seq} : 0));
        push @entries, {
            kind => 'flag', flag => 'GAP', t_ms => $prev->{ts} * 1000, local => _local_iso($prev->{ts}),
            from_ms => $prev->{ts} * 1000, to_ms => $next->{ts} * 1000, seconds => $delta,
            seq_reset => $seq_reset ? 1 : 0, ended_by => undef,
        };
    }

    # ---- events ----
    my @parsed_events;
    for my $ev (@$events) {
        next unless ref $ev eq 'HASH';
        my $p = parse_event_xml($ev->{xml});
        next unless ref $p eq 'HASH';
        my $provider = defined $p->{provider} ? $p->{provider} : '';
        my $id = $p->{id};
        next unless defined $id;
        # Matched by suffix, not exact equality: the real Get-WinEvent
        # provider name is fully qualified ("Microsoft-Windows-Kernel-Power",
        # measured M0e), but a fixture is free to spell the short form
        # ("Kernel-Power") -- both name the same provider.
        my $keep = 0;
        $keep = 1 if $provider =~ /Kernel-Power\z/ && grep { $_ == $id } (41, 42, 105, 107, 506, 507, 566);
        $keep = 1 if $provider eq 'EventLog' && $id == 6008;
        next unless $keep;
        my $t_ms = $p->{time_ms};
        next unless defined $t_ms;
        # Real Get-WinEvent messages are multi-line (M0e / review MUST-FIX 3,
        # measured on this host: the Reason text sits on line 3, never line
        # 1). Reason detection (spec 2.6, amended by review Decision 21)
        # reads the WHOLE message; only the display summary keeps the first
        # line.
        my $msg_full = defined $ev->{message} ? $ev->{message} : '';
        my $msg1 = (split /\n/, $msg_full)[0];
        $msg1 = '' unless defined $msg1;
        push @entries, {
            kind => 'event', t_ms => $t_ms, local => _local_iso(int($t_ms / 1000)),
            provider => $provider, id => $id, message => $msg1,
            data => $p->{data}, data_positional => $p->{data_positional},
        };
        push @parsed_events, { id => $id, t_ms => $t_ms };

        if ($id == 42 || $id == 506) {
            push @entries, {
                kind => 'flag', flag => ($id == 42 ? 'SLEEP' : 'STANDBY'),
                t_ms => $t_ms, local => _local_iso(int($t_ms / 1000)),
            };
            if ($msg_full =~ /\b(?:lid|button)\b/i) {
                push @entries, {
                    kind => 'flag', flag => 'LID-OR-BUTTON', t_ms => $t_ms, local => _local_iso(int($t_ms / 1000)),
                };
            }
        }
        elsif ($id == 41 || $id == 6008) {
            my $u = { kind => 'flag', flag => 'UNCLEAN-SHUTDOWN', t_ms => $t_ms, local => _local_iso(int($t_ms / 1000)) };
            if ($id == 6008) {
                $u->{data} = $p->{data};
                $u->{data_positional} = $p->{data_positional};
            }
            push @entries, $u;
        }
    }

    for my $e (@entries) {
        next unless $e->{kind} eq 'flag' && $e->{flag} eq 'GAP';
        my ($from, $to) = ($e->{from_ms}, $e->{to_ms});
        my @cands = sort { $a->{t_ms} <=> $b->{t_ms} }
                    grep { $_->{t_ms} > $from && $_->{t_ms} < $to && ($_->{id} == 41 || $_->{id} == 107 || $_->{id} == 507) }
                    @parsed_events;
        $e->{ended_by} = @cands ? $cands[0]{id} : undef;
    }

    # ---- BATTERY-CUTOFF: maximal runs of consecutive dc ticks all holding
    # at least one non-empty helper request set ----
    my (@dc_runs, $run);
    for my $t (@ticks) {
        my $qualifies = (defined $t->{power_source} && $t->{power_source} eq 'dc') && _has_held_request($t->{helpers});
        if ($qualifies) {
            $run = { ticks => [] } unless $run;
            push @{ $run->{ticks} }, $t;
        } else {
            push @dc_runs, $run if $run;
            $run = undef;
        }
    }
    push @dc_runs, $run if $run;
    for my $r (@dc_runs) {
        my @rt = @{ $r->{ticks} };
        my ($first, $last) = ($rt[0], $rt[-1]);
        my $dur = $last->{ts} - $first->{ts};
        next unless $dur >= $DC_CUTOFF_SECONDS;
        push @entries, {
            kind => 'flag', flag => 'BATTERY-CUTOFF',
            t_ms => ($first->{ts} + $DC_CUTOFF_SECONDS) * 1000,
            local => _local_iso($first->{ts} + $DC_CUTOFF_SECONDS),
            from_ms => $first->{ts} * 1000, to_ms => $last->{ts} * 1000,
        };
    }

    # ---- transcript spans ----
    my $transcript_skipped = 0;
    if (defined $transcript && -f $transcript) {
        my @points;
        if (open(my $fh, '<:raw', $transcript)) {
            while (my $line = <$fh>) {
                $line =~ s/[\r\n]+$//;
                next unless length $line;
                my $d = eval { JSON::PP->new->utf8->decode($line) };
                unless (ref $d eq 'HASH' && defined $d->{timestamp}) { $transcript_skipped++; next }
                my $ms = _iso_to_ms($d->{timestamp});
                if (defined $ms) { push @points, $ms } else { $transcript_skipped++ }
            }
            close $fh;
        }
        @points = sort { $a <=> $b } @points;
        my (@tspans, $tcur);
        for my $p (@points) {
            if ($tcur && ($p - $tcur->{to}) <= 300000) {
                $tcur->{to} = $p; $tcur->{count}++;
            } else {
                push @tspans, $tcur if $tcur;
                $tcur = { from => $p, to => $p, count => 1 };
            }
        }
        push @tspans, $tcur if $tcur;
        for my $s (@tspans) {
            push @entries, {
                kind => 'transcript', t_ms => $s->{from}, local => _local_iso(int($s->{from} / 1000)),
                from_ms => $s->{from}, to_ms => $s->{to}, count => $s->{count},
            };
        }
    }

    for my $p (@plans) {
        push @entries, {
            kind => 'plan', t_ms => (defined $p->{ts} ? $p->{ts} : 0) * 1000,
            local => _local_iso(defined $p->{ts} ? $p->{ts} : 0),
            why => $p->{why}, armed => $p->{armed}, arm_ids => $p->{arm_ids},
            found_guid => $p->{found_guid}, found_name => $p->{found_name},
            wanted_guid => $p->{wanted_guid}, wanted_name => $p->{wanted_name},
            wanted_basis => $p->{wanted_basis},
            action => $p->{action}, result => $p->{result},
            error => $p->{error}, detail => $p->{detail}, rc => $p->{rc}, ms => $p->{ms},
        };
    }

    for my $n (@notes) {
        push @entries, {
            kind => 'note', t_ms => (defined $n->{ts} ? $n->{ts} : 0) * 1000,
            local => _local_iso(defined $n->{ts} ? $n->{ts} : 0),
            note => 'unknown kind: ' . (defined $n->{kind} ? $n->{kind} : 'unknown'),
        };
    }

    # SHOULD-FIX 1 (review) / spec B13: surfaced as a note so it always
    # shows up in both the text header's per-kind counts and the JSON
    # stream, without changing build_timeline's arrayref return shape.
    if ($journal_skipped || $transcript_skipped) {
        my @parts;
        push @parts, "journal=$journal_skipped" if $journal_skipped;
        push @parts, "transcript=$transcript_skipped" if $transcript_skipped;
        my $skip_ms = defined $since_ms ? $since_ms : 0;
        my $total = $journal_skipped + $transcript_skipped;
        push @entries, {
            kind => 'note', t_ms => $skip_ms, local => _local_iso(int($skip_ms / 1000)),
            note => "skipped=$total undecodable line(s) (" . join(' ', @parts) . ')',
        };
    }

    # MUST-FIX 2 (review): an entry that carries a range (journal spans,
    # GAP, BATTERY-CUTOFF, transcript spans) is windowed by OVERLAP and
    # clipped to the window, never dropped whole for having begun before
    # --since. A steady 24h+ run that started days ago must still show
    # journal coverage for the whole window; windowing by from_ms alone
    # drops it entirely, which reads exactly like "the machine was not
    # running" (Decision 4's absence-misread). Point entries (event, note)
    # keep the simple point-in-window test.
    if (defined $since_ms || defined $until_ms) {
        my @kept;
        for my $e (@entries) {
            if (defined $e->{from_ms} && defined $e->{to_ms}) {
                next if defined $until_ms && $e->{from_ms} > $until_ms;
                next if defined $since_ms && $e->{to_ms} < $since_ms;
                $e->{from_ms} = $since_ms if defined $since_ms && $e->{from_ms} < $since_ms;
                $e->{to_ms}   = $until_ms if defined $until_ms && $e->{to_ms} > $until_ms;
                $e->{t_ms} = $e->{from_ms} if $e->{t_ms} < $e->{from_ms};
                $e->{t_ms} = $e->{to_ms}   if $e->{t_ms} > $e->{to_ms};
                $e->{local} = _local_iso(int($e->{t_ms} / 1000));
            } else {
                next if defined $since_ms && $e->{t_ms} < $since_ms;
                next if defined $until_ms && $e->{t_ms} > $until_ms;
            }
            push @kept, $e;
        }
        @entries = @kept;
    }

    my %rank = (event => 0, journal => 1, transcript => 2, plan => 3, note => 4, flag => 5);
    my $idx = 0;
    for my $e (@entries) { $e->{__idx} = $idx++ }
    @entries = sort {
        $a->{t_ms} <=> $b->{t_ms}
            || (defined $rank{$a->{kind}} ? $rank{$a->{kind}} : 9) <=> (defined $rank{$b->{kind}} ? $rank{$b->{kind}} : 9)
            || $a->{__idx} <=> $b->{__idx}
    } @entries;
    delete $_->{__idx} for @entries;

    return \@entries;
}

# ---------------------------------------------------------------------------
# CLI: report_main (spec 2.7). bp-power-journal.pl is a thin caller.
# ---------------------------------------------------------------------------

my $USAGE = "usage: bp-power-journal report [--since T] [--until T] [--session SID | --transcript PATH] [--dir DIR] [--events-file PATH | --no-events] [--format text|json]\n";

sub _parse_time {
    my ($s, $now) = @_;
    return undef unless defined $s && length $s;
    if ($s =~ /^\d{9,}$/) { return $s + 0 }
    if ($s =~ /^(\d+)([mhd])$/) {
        my ($n, $u) = ($1, $2);
        my $sec = $u eq 'm' ? 60 : $u eq 'h' ? 3600 : 86400;
        return $now - $n * $sec;
    }
    if ($s =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:\d{2})$/) {
        my ($Y, $Mo, $D, $H, $Mi, $S, $off) = ($1, $2, $3, $4, $5, $6, $7);
        my $epoch = eval { Time::Local::timegm($S, $Mi, $H, $D, $Mo - 1, $Y) };
        return undef unless defined $epoch;
        if ($off ne 'Z') {
            my ($sign, $oh, $om) = $off =~ /^([+-])(\d{2}):(\d{2})$/;
            my $adj = ($oh * 3600 + $om * 60) * ($sign eq '-' ? -1 : 1);
            $epoch -= $adj;
        }
        return $epoch;
    }
    if ($s =~ /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?$/) {
        my ($Y, $Mo, $D, $H, $Mi, $S) = ($1, $2, $3, $4, $5, defined $6 ? $6 : 0);
        return eval { Time::Local::timelocal($S, $Mi, $H, $D, $Mo - 1, $Y) };
    }
    return undef;
}

sub _summary_for {
    my ($e) = @_;
    my $k = $e->{kind};
    if ($k eq 'flag') {
        return $e->{flag} eq 'GAP' ? "seconds=$e->{seconds} seq_reset=$e->{seq_reset}"
             : $e->{flag} eq 'BATTERY-CUTOFF' ? "from=$e->{from_ms} to=$e->{to_ms}"
             : '';
    }
    if ($k eq 'journal')    { return "count=$e->{count} power=$e->{power_source} display=$e->{display}" }
    if ($k eq 'event')      { return "id=$e->{id} $e->{message}" }
    if ($k eq 'transcript') { return "count=$e->{count}" }
    if ($k eq 'plan') {
        my $why    = defined $e->{why}        ? $e->{why}        : '';
        my $action = defined $e->{action}     ? $e->{action}     : '';
        my $result = defined $e->{result}     ? $e->{result}     : '';
        my $found  = defined $e->{found_guid} ? $e->{found_guid} : '';
        my $wanted = defined $e->{wanted_guid} ? $e->{wanted_guid} : '';
        my $s = "why=$why action=$action result=$result found=$found wanted=$wanted";
        if ($result eq 'error') {
            my $err    = defined $e->{error}  ? $e->{error}  : '';
            my $detail = defined $e->{detail} ? $e->{detail} : '';
            $s .= " error=$err";
            $s .= " detail=$detail" if length $detail;
        }
        return $s;
    }
    if ($k eq 'note')       { return $e->{note} }
    return '';
}

# _read_events_live($since_e, $until_e) -> \@events | $error_string. The
# default reader (2.7); refuses under $0 =~ /\.t\z/ so no test can ever
# spawn a real Get-WinEvent, same idiom as probe_argv.
sub _read_events_live {
    my ($since_e, $until_e) = @_;
    # The System event log is a Windows thing. Off Windows this used to spawn
    # powershell.exe anyway and report the failed spawn as a broken log; say
    # what is actually true instead (the journal half of the report still runs).
    return "the Windows System event log does not exist on $^O"
        unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    return 'refused: test guard' if defined $0 && $0 =~ /\.t\z/;
    my $since_iso = _utc_iso($since_e);
    my $until_iso = _utc_iso($until_e);
    my $script = <<"PS1";
try {
    \$e = Get-WinEvent -FilterHashtable \@{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power','EventLog'; Id=41,42,105,107,506,507,566,6008; StartTime='$since_iso'; EndTime='$until_iso'} -ErrorAction Stop
    \$out = \@(\$e | ForEach-Object { \@{ xml = \$_.ToXml(); message = "\$(\$_.Message)" } })
} catch {
    if (\$_.CategoryInfo.Category -eq 'ObjectNotFound') { \$out = \@() } else { throw }
}
[Console]::Out.Write([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject \$out -Compress -Depth 5))))
PS1
    my $utf16le = Encode::encode('UTF-16LE', $script);
    my $b64 = MIME::Base64::encode_base64($utf16le, '');
    my @argv = ('powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-WindowStyle', 'Hidden', '-EncodedCommand', $b64);
    my $r = run_bounded(\@argv, 60);
    return 'System log read timed out' if $r->{status} eq 'timeout';
    return 'System log read failed to spawn' if $r->{status} eq 'spawn-failed';
    return 'System log read exited nonzero' if defined $r->{rc} && $r->{rc} != 0;
    my $bytes = eval { MIME::Base64::decode_base64($r->{out}) };
    return 'System log output undecodable' unless defined $bytes;
    # MUST-FIX 5 (review): the probe now always wraps with -InputObject, so
    # an empty result is a stable "[]", never empty stdout -- but an empty
    # decode is still treated as "no events found" rather than "unreadable"
    # as a defensive fallback (spec 2.7: "No events found" means an empty
    # list).
    return [] unless length $bytes;
    my $data = eval { JSON::PP->new->utf8->decode($bytes) };
    return 'System log output not JSON' unless ref $data eq 'ARRAY' || ref $data eq 'HASH';
    my @list = ref $data eq 'ARRAY' ? @$data : ($data);
    return \@list;
}

sub report_main {
    my (@argv) = @_;
    if (@argv && $argv[0] eq '--help') { print $USAGE; return 0 }
    unless (@argv && $argv[0] eq 'report') { print STDERR $USAGE; return 2 }
    shift @argv;

    my %opt = (format => 'text');
    while (@argv) {
        my $a = shift @argv;
        if    ($a eq '--since')        { $opt{since} = shift @argv }
        elsif ($a eq '--until')        { $opt{until} = shift @argv }
        elsif ($a eq '--session')      { $opt{session} = shift @argv }
        elsif ($a eq '--transcript')   { $opt{transcript} = shift @argv }
        elsif ($a eq '--dir')          { $opt{dir} = shift @argv }
        elsif ($a eq '--events-file')  { $opt{events_file} = shift @argv }
        elsif ($a eq '--no-events')    { $opt{no_events} = 1 }
        elsif ($a eq '--format')       { $opt{format} = shift @argv }
        elsif ($a eq '--help')         { print $USAGE; return 0 }
        else { print STDERR "bp-power-journal: unknown argument '$a'\n"; print STDERR $USAGE; return 2 }
    }

    my $now = time();
    my $since_e = defined $opt{since} ? _parse_time($opt{since}, $now) : ($now - 24 * 3600);
    my $until_e = defined $opt{until} ? _parse_time($opt{until}, $now) : $now;
    unless (defined $since_e && defined $until_e) {
        print STDERR "bp-power-journal: unparseable --since/--until\n";
        return 2;
    }
    if ($since_e > $until_e) {
        print STDERR "bp-power-journal: --since must not be after --until\n";
        return 2;
    }
    my $since_ms = $since_e * 1000;
    my $until_ms = $until_e * 1000;

    my $dir = defined $opt{dir} ? $opt{dir} : BpContinuityLease::legacy_dir();
    my @notes;

    my @journal_lines;
    if (defined $dir) {
        my $path = journal_path($dir);
        if (-f $path) {
            for my $suffix ('.4', '.3', '.2', '.1', '') {
                my $p = length($suffix) ? "$path$suffix" : $path;
                next unless -f $p;
                open(my $fh, '<:raw', $p) or next;
                while (my $line = <$fh>) {
                    $line =~ s/[\r\n]+$//;
                    next unless length $line;
                    my $d = eval { JSON::PP->new->utf8->decode($line) };
                    push @journal_lines, (ref $d eq 'HASH') ? $d : undef;
                }
                close $fh;
            }
        } else {
            push @notes, "no power journal file at $path";
        }
    } else {
        push @notes, 'no continuity directory resolvable';
    }

    my $transcript_path;
    if (defined $opt{transcript}) {
        $transcript_path = $opt{transcript};
    }
    elsif (defined $opt{session}) {
        my $root = eval { BpContinuityLease::store_root_for($dir) };
        unless (defined $root && length $root) {
            $root = eval { require "$DIR/BpHook.pm" unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC; BpHook::state_dir() };
        }
        my $found;
        for my $sub ('armed', 'off') {
            next unless defined $root && length $root;
            my $f = "$root/$sub/$opt{session}";
            next unless -f $f;
            my $raw = _slurp_bytes($f);
            next unless defined $raw;
            my $d = eval { JSON::PP->new->utf8->decode($raw) };
            next unless ref $d eq 'HASH' && defined $d->{transcript_path} && length $d->{transcript_path};
            next unless -f $d->{transcript_path};
            $found = $d->{transcript_path};
            last;
        }
        unless (defined $found) {
            print STDERR "transcript for $opt{session} not found; pass --transcript PATH\n";
            return 1;
        }
        $transcript_path = $found;
    }

    my $events = [];
    if ($opt{no_events}) {
        # no source
    }
    elsif (defined $opt{events_file}) {
        if (-f $opt{events_file}) {
            my $raw = _slurp_bytes($opt{events_file});
            if (defined $raw) {
                my $d = eval { JSON::PP->new->utf8->decode($raw) };
                $events = (ref $d eq 'ARRAY') ? $d : [];
            } else {
                push @notes, "cannot read events file: $opt{events_file}";
            }
        } else {
            push @notes, "events file not found: $opt{events_file}";
        }
    }
    else {
        my $r = _read_events_live($since_e, $until_e);
        if (ref $r eq 'ARRAY') { $events = $r }
        else { push @notes, "System log unreadable: $r" }
    }

    my $entries = build_timeline(
        journal_lines => \@journal_lines, events => $events, transcript => $transcript_path,
        since_ms => $since_ms, until_ms => $until_ms,
    );
    for my $n (reverse @notes) {
        unshift @$entries, { kind => 'note', t_ms => $since_ms, local => _local_iso($since_e), note => $n };
    }

    if ($opt{format} eq 'json') {
        for my $e (@$entries) { print JSON::PP->new->utf8->canonical->encode($e), "\n" }
    } else {
        # SHOULD-FIX 7 (review): the header counts per-SOURCE input (journal
        # lines read, events read, transcript lines read), not per entry-KIND
        # -- so "0 events read" and "events read but filtered out" are two
        # different, distinguishable header lines, which matters for the
        # incident-timeline use this report exists for.
        my $transcript_lines = 0;
        if (defined $transcript_path && -f $transcript_path) {
            if (open(my $fh, '<:raw', $transcript_path)) { $transcript_lines++ while <$fh>; close $fh; }
        }
        my @src = ('journal=' . scalar(@journal_lines), 'events=' . scalar(@$events));
        push @src, "transcript=$transcript_lines" if defined $transcript_path;
        print "window: " . _display_local($since_e) . ' .. ' . _display_local($until_e) . "\n";
        print "sources: " . join(', ', @src) . "\n";
        for my $e (@$entries) {
            my $local = _display_local(int($e->{t_ms} / 1000));
            if ($e->{kind} eq 'flag') {
                printf "%s !! %-16s %s\n", $local, $e->{flag}, _summary_for($e);
            } else {
                printf "%s %-10s %s\n", $local, uc($e->{kind}), _summary_for($e);
            }
        }
    }
    return 0;
}

1;
