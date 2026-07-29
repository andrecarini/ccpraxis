package Resources;
# Pure parsers + assembler for the s09 Resources panel (podman machine,
# this container, and the Windows host). Turns the raw stdout of six probes
# into a render-ready, closed-key-set struct.
#
# PURE module, by contract (spec S2.0): no I/O of any kind, no clock, no
# sleeping/forking, never dies, never warns, and no render vocabulary (no
# roles, no glyphs, no widths, no colors). The single documented exception is
# Resources::gather, which INVOKES caller-supplied coderefs -- every side
# effect there is the caller's, never this module's.
#
# Loaded by launcher.pl and by t/44-resources.t. Dashboard.pm does NOT load
# it: the launcher computes, Dashboard renders (same split as s08/TokenInfo).
#
# See specs/s09-resources-panel-spec.md S2.0-S2.4 for the binding contract.

use strict;
use warnings;
use JSON::PP ();   # core; the only dependency (precedent: SessionFilter.pm)

# The probe keys, in the order gather invokes them. Ordered by value-per-cost:
# the container stats first (cheapest podman call, most-wanted fact), the
# image-store walk last (most expensive, first thing the budget drops).
my @PROBE_ORDER = qw(stats machine cim_mem cim_cpu cim_disk df);

my $DEFAULT_BUDGET   = 4;    # elapsed seconds for a whole probe round
my $SAMPLE_INTERVAL  = 23;   # seconds between probe rounds (coprime with the
                             # 10s inspect cadence, so the two rounds collide
                             # once every 230s instead of every 50s)
my $NUM_RE = qr/^-?\d+(?:\.\d+)?$/;

# ---------------------------------------------------------------------------
# Shared private coercions. All total: any hostile input yields undef.
# ---------------------------------------------------------------------------

sub _uint { my ($v) = @_; return undef if !defined $v || ref $v; return ($v =~ /^\d+$/) ? 0 + $v : undef; }
sub _str  { my ($v) = @_; return undef if !defined $v || ref $v; return length($v) ? "$v" : undef; }
sub _num  { my ($v) = @_; return undef if !defined $v || ref $v; return ($v =~ $NUM_RE) ? 0 + $v : undef; }

# _decode($raw) -> decoded data | undef. The ONE shared decode path; every
# public parser goes through it.
#
# The BOM strip is mandatory, not defensive: the captured CIM fixtures are
# ConvertTo-Json output and begin with a UTF-8 BOM, on which JSON::PP dies
# with "malformed JSON string ... at character offset 0". Both forms are
# stripped, in order, so it works whether the string is byte-flavoured (the
# real subprocess case) or char-flavoured (an upgraded test literal).
#
# decode is used WITHOUT ->utf8: the input is raw bytes from a subprocess and
# utf8 mode would validate the byte stream and die on a malformed sequence.
# No field read here is ever non-ASCII. PRIVATE, pure, total.
sub _decode {
    my ($raw) = @_;
    return undef if !defined $raw || ref $raw;
    my $s = $raw;
    $s =~ s/^\x{EF}\x{BB}\x{BF}//;
    $s =~ s/^\x{FEFF}//;
    $s =~ s/^\s+//;
    return undef unless length $s;
    local $@;
    my $d = eval { local $SIG{__WARN__} = sub { }; JSON::PP->new->decode($s) };
    return (defined $d && !$@) ? $d : undef;
}

# ---------------------------------------------------------------------------
# S2.1 -- the pure parsers. All PUBLIC, pure, total.
# ---------------------------------------------------------------------------

# parse_human_bytes($str) -> integer bytes | undef. Reads podman's human
# sizes. DECIMAL (1000) unless the IEC "i" is present, matching go-units --
# "782.3kB" is 782300, not 801075.
sub parse_human_bytes {
    my ($v) = @_;
    return undef if !defined $v || ref $v;
    return undef unless $v =~ /^\s*([0-9]+(?:\.[0-9]+)?)\s*([kKmMgGtTpP])?(i)?B\s*$/;
    my ($n, $prefix, $iec) = ($1, $2, $3);
    my $base = defined $iec ? 1024 : 1000;
    my %exp  = (k => 1, m => 2, g => 3, t => 4, p => 5);
    my $e = defined $prefix ? $exp{ lc $prefix } : 0;
    return int($n * $base ** $e + 0.5);
}

# parse_percent($str) -> number | undef. The '%' is optional, so the same
# helper reads podman's "3.76%" and CIM's bare 16. A leading sign is rejected.
sub parse_percent {
    my ($v) = @_;
    return undef if !defined $v || ref $v;
    return undef unless $v =~ /^\s*([0-9]+(?:\.[0-9]+)?)\s*%?\s*$/;
    return 0 + $1;
}

# parse_machine_list($raw) -> { name, running, starting } | undef.
# The element with a truthy Default wins regardless of position; otherwise the
# first hash element. The CONFIGURED memory / disk size are deliberately not
# parsed and not returned (spec B4): they are cosmetic on WSL2 and disagree
# with the cgroup limit podman stats reports, which is the authoritative one.
sub parse_machine_list {
    my ($raw) = @_;
    my $d = _decode($raw);
    return undef unless ref $d eq 'ARRAY';
    my ($pick, $first);
    for my $el (@$d) {
        next unless ref $el eq 'HASH';
        $first = $el unless defined $first;
        if ($el->{Default}) { $pick = $el; last; }
    }
    $pick = $first unless defined $pick;
    return undef unless defined $pick;
    return {
        name     => _str($pick->{Name}),
        running  => ($pick->{Running}  ? 1 : 0),
        starting => ($pick->{Starting} ? 1 : 0),
    };
}

# parse_stats($raw, $name) -> { name, mem_used, mem_limit, cpu_pct } | undef.
# Selection is BY NAME, never by position: the host runs one sandbox container
# per project, and picking [0] would show another sandbox's numbers here. No
# name, no match, no struct -- there is no positional fallback.
sub parse_stats {
    my ($raw, $name) = @_;
    return undef if !defined $name || ref $name || !length $name;
    my $d = _decode($raw);
    my $list = (ref $d eq 'ARRAY') ? $d : (ref $d eq 'HASH') ? [$d] : undef;
    return undef unless defined $list;
    for my $e (@$list) {
        next unless ref $e eq 'HASH';
        my $n = _str($e->{name});
        $n = _str($e->{Name}) unless defined $n;
        next unless defined $n && $n eq $name;
        my ($used, $limit);
        my $usage = _str($e->{mem_usage});
        if (defined $usage && $usage =~ m{/}) {
            my ($u, $l) = split m{/}, $usage, 2;
            for my $part ($u, $l) {
                next unless defined $part;
                $part =~ s/^\s+//;
                $part =~ s/\s+$//;
            }
            $used  = parse_human_bytes($u);
            $limit = parse_human_bytes($l);
        }
        return {
            name      => $n,
            mem_used  => $used,
            mem_limit => $limit,
            cpu_pct   => parse_percent($e->{cpu_percent}),
        };
    }
    return undef;
}

# parse_system_df($raw) -> { images, containers, volumes } | undef, each value
# either undef (no such row) or { size, reclaimable }. The Type match is
# case-sensitive; unknown types are ignored; the first matching row wins.
sub parse_system_df {
    my ($raw) = @_;
    my $d = _decode($raw);
    return undef unless ref $d eq 'ARRAY';
    my %map = ('Images' => 'images', 'Containers' => 'containers', 'Local Volumes' => 'volumes');
    my %out = (images => undef, containers => undef, volumes => undef);
    for my $row (@$d) {
        next unless ref $row eq 'HASH';
        my $t = _str($row->{Type});
        next unless defined $t && exists $map{$t};
        my $k = $map{$t};
        next if defined $out{$k};
        $out{$k} = { size => _uint($row->{RawSize}), reclaimable => _uint($row->{RawReclaimable}) };
    }
    return \%out;
}

# parse_cim_memory($raw) -> { ram_free, ram_total } | undef, in BYTES.
# CIM reports kilobytes and those kilobytes are 1024 bytes, so the conversion
# constant here is 1024 (unlike parse_human_bytes' decimal default).
sub parse_cim_memory {
    my ($raw) = @_;
    my $d = _decode($raw);
    $d = $d->[0] if ref $d eq 'ARRAY';
    return undef unless ref $d eq 'HASH';
    my $free  = _uint($d->{FreePhysicalMemory});
    my $total = _uint($d->{TotalVisibleMemorySize});
    return {
        ram_free  => (defined $free  ? $free  * 1024 : undef),
        ram_total => (defined $total ? $total * 1024 : undef),
    };
}

# parse_cim_disk($raw, $device) -> { device, disk_free, disk_total } | undef.
# The drive is matched case-insensitively and returned VERBATIM (the panel
# prints the device it measured). No device, no match, no struct -- never
# guess a drive. CIM already reports bytes here, so nothing is converted.
sub parse_cim_disk {
    my ($raw, $device) = @_;
    return undef if !defined $device || ref $device || !length $device;
    my $d = _decode($raw);
    my $list = (ref $d eq 'ARRAY') ? $d : (ref $d eq 'HASH') ? [$d] : undef;
    return undef unless defined $list;
    my $want = uc $device;
    for my $e (@$list) {
        next unless ref $e eq 'HASH';
        my $id = _str($e->{DeviceID});
        next unless defined $id && uc($id) eq $want;
        return { device => $id, disk_free => _uint($e->{FreeSpace}), disk_total => _uint($e->{Size}) };
    }
    return undef;
}

# parse_cim_cpu($raw) -> { cpu_pct, cores } | undef. A multi-socket host emits
# an array; element [0] is used. The CPU model string is ignored (the probe
# does not even select it -- it is the one non-ASCII-capable field).
sub parse_cim_cpu {
    my ($raw) = @_;
    my $d = _decode($raw);
    $d = $d->[0] if ref $d eq 'ARRAY';
    return undef unless ref $d eq 'HASH';
    return {
        cpu_pct => parse_percent($d->{LoadPercentage}),
        cores   => _uint($d->{NumberOfLogicalProcessors}),
    };
}

# ---------------------------------------------------------------------------
# S2.2 -- the assembler.
# ---------------------------------------------------------------------------

# _delta($total, $part) -> $total - $part, or undef unless both are defined
# and the subtraction is physically possible. Never a negative byte count.
sub _delta {
    my ($total, $part) = @_;
    my $t = _num($total);
    my $p = _num($part);
    return undef unless defined $t && defined $p;
    return undef if $t < $p;
    return $t - $p;
}

# _sub($h, $k) -> $h->{$k} when $h is a hashref, else undef.
sub _sub { my ($h, $k) = @_; return (ref $h eq 'HASH') ? $h->{$k} : undef; }

# _dfsize($df, $k) -> the size of one podman store row, or undef.
sub _dfsize {
    my ($df, $k) = @_;
    my $row = _sub($df, $k);
    return (ref $row eq 'HASH') ? $row->{size} : undef;
}

# Resources::build($raw) -> the 15-key render-ready struct. PUBLIC, pure,
# total: ALWAYS a hashref with the complete closed key set; an unknown fact is
# an undef VALUE, never a missing key. The key names encode the source
# (ctr_ = this container, vm_ = the podman VM, host_ = the Windows host,
# pod_ = the podman image/container/volume store); host_ and vm_ facts are
# never summed, compared or conflated.
sub build {
    my ($raw) = @_;
    $raw = {} unless ref $raw eq 'HASH';

    my $machine = parse_machine_list($raw->{machine});
    my $stats   = parse_stats($raw->{stats}, $raw->{container});
    my $df      = parse_system_df($raw->{df});
    my $mem     = parse_cim_memory($raw->{cim_mem});
    my $disk    = parse_cim_disk($raw->{cim_disk}, $raw->{device});
    my $cpu     = parse_cim_cpu($raw->{cim_cpu});

    my $state = 'unknown';
    if (ref $machine eq 'HASH') {
        $state = $machine->{running}  ? 'running'
               : $machine->{starting} ? 'starting'
               :                        'stopped';
    }

    return {
        machine_name    => _sub($machine, 'name'),
        machine_state   => $state,
        ctr_mem_used    => _sub($stats, 'mem_used'),
        vm_mem_total    => _sub($stats, 'mem_limit'),
        ctr_cpu_pct     => _sub($stats, 'cpu_pct'),
        pod_images      => _dfsize($df, 'images'),
        pod_containers  => _dfsize($df, 'containers'),
        pod_volumes     => _dfsize($df, 'volumes'),
        host_ram_used   => _delta(_sub($mem, 'ram_total'), _sub($mem, 'ram_free')),
        host_ram_total  => _sub($mem, 'ram_total'),
        host_disk_dev   => _sub($disk, 'device'),
        host_disk_used  => _delta(_sub($disk, 'disk_total'), _sub($disk, 'disk_free')),
        host_disk_total => _sub($disk, 'disk_total'),
        host_cpu_pct    => _sub($cpu, 'cpu_pct'),
        host_cores      => _sub($cpu, 'cores'),
    };
}

# ---------------------------------------------------------------------------
# S2.3 -- the throttle decision. Lives here, not in the launcher closure, so
# it is testable without loading launcher.pl (which has load-time side
# effects and cannot be require'd by a test).
# ---------------------------------------------------------------------------

# Resources::interval() -> 23, the single source of truth for the resources
# cadence. Nothing else may hardcode it. PUBLIC, pure.
sub interval { return $SAMPLE_INTERVAL; }

# Resources::should_sample($last_at, $now, $interval) -> 0 | 1. PUBLIC, pure,
# total. An unusable $now means "cannot decide" -> do not sample; an unusable
# $last_at means "never sampled" -> sample now; a backwards clock resamples
# rather than freezing the panel for a clock-jump's worth of seconds. The
# boundary is inclusive: exactly $interval elapsed samples.
sub should_sample {
    my ($last_at, $now, $iv) = @_;
    my $i = _num($iv);
    $i = interval() unless defined $i && $i > 0;
    my $n = _num($now);
    return 0 unless defined $n;
    my $l = _num($last_at);
    return 1 unless defined $l;
    return 1 if $n < $l;
    return ($n - $l >= $i) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# S2.4 -- the injectable probe seam.
# ---------------------------------------------------------------------------

# _clock($cb) -> the injected clock's reading as a number, or undef when no
# usable clock was injected. PRIVATE, total.
sub _clock {
    my ($cb) = @_;
    return undef unless ref $cb eq 'CODE';
    my $v = eval { local $SIG{__WARN__} = sub { }; $cb->() };
    return (defined $v && !ref $v && $v =~ $NUM_RE) ? 0 + $v : undef;
}

# Resources::gather($probes, $opts) -> the 15-key struct. PUBLIC, total,
# never dies. Performs NO I/O itself: it invokes caller-supplied coderefs, so
# every side effect belongs to the caller (and a test can drive it with fake
# slow / dying probes, with no podman and no container).
#
# $probes: { key => coderef }; only the six recognized keys are ever invoked,
# in @PROBE_ORDER. $opts: { container, device, budget, now }.
#
# Per-probe guards: each probe is eval'd (a die degrades that field to n/a and
# every LATER probe still runs) with warnings swallowed (anything reaching
# STDERR would splatter the alt-screen). The injected-clock elapsed budget is
# checked BEFORE each invocation, so one slow probe cannot multiply into six.
# A probe returning undef, '' or a ref degrades to n/a and is never
# dereferenced.
sub gather {
    my ($probes, $opts) = @_;
    $probes = {} unless ref $probes eq 'HASH';
    $opts   = {} unless ref $opts   eq 'HASH';

    my $budget = _num($opts->{budget});
    $budget = $DEFAULT_BUDGET unless defined $budget && $budget > 0;
    my $clock = $opts->{now};
    my $t0    = _clock($clock);

    my %raw;
    for my $key (@PROBE_ORDER) {
        my $cb = $probes->{$key};
        next unless ref $cb eq 'CODE';
        if (defined $t0) {
            my $t = _clock($clock);
            last if defined $t && ($t - $t0) >= $budget;
        }
        my $out = eval { local $SIG{__WARN__} = sub { }; $cb->() };
        $raw{$key} = (defined $out && !ref $out && length $out) ? $out : undef;
    }

    return build({ %raw, container => $opts->{container}, device => $opts->{device} });
}

1;
