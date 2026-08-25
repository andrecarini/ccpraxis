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

# The 15 closed keys of the Resources::build / snapshot "resources" struct,
# in no particular order (unlike @PROBE_ORDER this list has no cadence
# meaning -- it exists so snapshot_build can extract exactly these keys and
# no others, per-key, without depending on build()'s internal hash literal).
my @STRUCT_KEYS = qw(
    machine_name machine_state
    ctr_mem_used vm_mem_total ctr_cpu_pct
    pod_images pod_containers pod_volumes
    host_ram_used host_ram_total
    host_disk_dev host_disk_used host_disk_total
    host_cpu_pct host_cores
);

my $DEFAULT_BUDGET   = 4;    # elapsed seconds for a whole probe round
my $SAMPLE_INTERVAL  = 23;   # seconds between probe rounds (coprime with the
                             # 10s inspect cadence, so the two rounds collide
                             # once every 230s instead of every 50s) -- 03:
                             # now exclusively the SAMPLER's own probe cadence
my $READ_INTERVAL    = 5;    # 03: seconds between snapshot READS on the render tick
my $MAX_AGE          = 60;   # 03: snapshot older than this reads 'stale'.
                             # 2*interval()=46 < 60 < 3*interval()=69, so one
                             # missed sampler round is still 'fresh' and two
                             # consecutive missed rounds are 'stale'. Worst-case
                             # observed age on a healthy system is
                             # interval()+read_interval() = 28.
my $SNAPSHOT_VERSION = 1;    # 03: the one supported snapshot schema version
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
#
# SCHEMA: podman has shipped `stats --format json` with a lowercase-tagged
# spelling (name / mem_usage / cpu_percent) AND a capitalized one (Name /
# MemUsage / CPUPerc / MemUsageBytes / MemLimit) across versions. Every key is
# read lowercase-FIRST and capitalized only as a fallback, so the captured
# fixtures keep byte-for-byte the same path. Without the fallback a capitalized
# build matched on Name and then returned an all-undef struct -- a healthy
# container rendering n/a, indistinguishable from a dead probe.
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
        $usage = _str($e->{MemUsage}) unless defined $usage;
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
        # The capitalized schema also carries the unambiguous numeric pair.
        # Consulted ONLY when the human string produced nothing, so it can
        # never override a parsed value (and never fires on the fixtures).
        $used  = _uint($e->{MemUsageBytes}) unless defined $used;
        $limit = _uint($e->{MemLimit})      unless defined $limit;
        my $pct = $e->{cpu_percent};
        $pct = $e->{CPUPerc} unless defined $pct;
        return {
            name      => $n,
            mem_used  => $used,
            mem_limit => $limit,
            cpu_pct   => parse_percent($pct),
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

# Resources::interval() -> 23, the single source of truth for the SAMPLER's
# probe cadence. Nothing else may hardcode it. PUBLIC, pure.
sub interval { return $SAMPLE_INTERVAL; }

# Resources::read_interval() -> 5, the single source of truth for the render
# tick's snapshot READ cadence (distinct from interval(), the sampler's probe
# cadence). PUBLIC, pure.
sub read_interval { return $READ_INTERVAL; }

# Resources::max_age() -> 60, seconds; a snapshot older than this reads
# 'stale' rather than 'fresh'. PUBLIC, pure. See $MAX_AGE's declaration
# comment for the arithmetic rationale.
sub max_age { return $MAX_AGE; }

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
#
# BUDGET GRANULARITY: the budget bounds when the NEXT probe may start, not how
# long the round takes -- a probe already running is not interruptible, so the
# real worst case is budget + one probe's duration. It is also only as precise
# as the injected clock: the production caller injects `sub { time }`, i.e.
# INTEGER seconds, so a nominal 4 resolves to somewhere in [3, 5). Read the
# number as an advisory floor on the round, never as a wall-clock cap. (Tests
# inject a fractional clock and do get fractional resolution.)
#
# `local $@` keeps a dying probe's message from leaking out of gather: without
# it the last probe's die would still be sitting in $@ at the caller's next
# `if ($@)`, misfiring on a successful frame.
sub gather {
    my ($probes, $opts) = @_;
    local $@;
    $probes = {} unless ref $probes eq 'HASH';
    $opts   = {} unless ref $opts   eq 'HASH';

    my $budget = _num($opts->{budget});
    $budget = $DEFAULT_BUDGET unless defined $budget && $budget > 0;
    my $clock = $opts->{now};
    my $t0    = _clock($clock);
    # Opt-in out-param: a hashref here collects one short reason per probe that
    # yielded nothing. See the note at the eval below.
    my $errors = (ref $opts->{errors} eq 'HASH') ? $opts->{errors} : undef;

    my %raw;
    for my $key (@PROBE_ORDER) {
        my $cb = $probes->{$key};
        next unless ref $cb eq 'CODE';
        if (defined $t0) {
            my $t = _clock($clock);
            last if defined $t && ($t - $t0) >= $budget;
        }
        # KEEP THE REASON. This was `eval { local $SIG{__WARN__} = sub {}; ... }`
        # with `local $@` at the top of the sub, so a probe that died and a
        # probe that returned nothing were indistinguishable, and BOTH were
        # indistinguishable from a probe that ran fine and found nothing.
        #
        # Observed live on 2026-08-25: a snapshot with probes_absent EMPTY (all
        # six probes present and executed) and every one of the fifteen facts
        # undef. The panel could only say "fresh, 14 facts unavailable", which
        # tells the operator that something failed and nothing about what --
        # and there was no way to find out afterwards, because the reason had
        # been discarded at this line.
        #
        # $opts->{errors}, when the caller supplies a hashref, collects one
        # short reason per failed probe. Opt-in so pure callers and tests are
        # unaffected.
        my @warn;
        my $out = eval { local $SIG{__WARN__} = sub { push @warn, $_[0] }; $cb->() };
        my $err = $@;
        $raw{$key} = (defined $out && !ref $out && length $out) ? $out : undef;

        if (ref $errors eq 'HASH' && !defined $raw{$key}) {
            my $why = (defined $err && length $err) ? $err
                    : (@warn                       ? $warn[0]
                    : (ref $out                    ? 'probe returned a ' . ref($out) . ' ref'
                                                   : 'probe produced no output'));
            $why =~ s/\s+/ /g;
            $why =~ s/^\s+|\s+$//g;
            $why = substr($why, 0, 160) if length($why) > 160;
            $errors->{$key} = $why;
        }
    }

    return build({ %raw, container => $opts->{container}, device => $opts->{device} });
}

# ---------------------------------------------------------------------------
# 03-resources-reader-model -- the sampler's probe-availability seam.
# ---------------------------------------------------------------------------

# Resources::sampler_probe_opts($container, $device) -> \%opts. The sampler's
# opts for gather(): EXACTLY { container, device } -- no `now` key and no
# `budget` key, ever. That absence is what disables gather's elapsed-budget
# accounting (see gather's own header): every probe in @PROBE_ORDER is
# invoked exactly once, off the render tick where a frame deadline no longer
# applies. PUBLIC, pure, total.
sub sampler_probe_opts {
    my ($container, $device) = @_;
    return {
        container => (defined $container && !ref $container) ? $container : undef,
        device    => (defined $device    && !ref $device)    ? $device    : undef,
    };
}

# Resources::probe_availability($probes) -> { present => \@keys, absent => \@keys }.
# `present` is every @PROBE_ORDER key for which $probes->{$key} is a CODE
# ref, in @PROBE_ORDER order; `absent` is the remaining @PROBE_ORDER keys, in
# @PROBE_ORDER order. Keys of $probes outside @PROBE_ORDER are ignored
# entirely. A non-hashref $probes -> present => [], absent => the whole
# @PROBE_ORDER. This is Rule 4's "not applicable on this platform" signal,
# carried as DATA in the snapshot rather than as a zero. PUBLIC, pure, total.
sub probe_availability {
    my ($probes) = @_;
    my (@present, @absent);
    if (ref $probes eq 'HASH') {
        for my $key (@PROBE_ORDER) {
            if (ref $probes->{$key} eq 'CODE') { push @present, $key; }
            else                               { push @absent,  $key; }
        }
    } else {
        @absent = @PROBE_ORDER;
    }
    return { present => \@present, absent => \@absent };
}

# _probe_list($v) -> arrayref, $v filtered to @PROBE_ORDER members, in
# @PROBE_ORDER order (never the input's own order). [] if $v is not an
# arrayref. PRIVATE, pure, total.
sub _probe_list {
    my ($v) = @_;
    return [] unless ref $v eq 'ARRAY';
    my %have = map { (defined $_ && !ref $_) ? ($_ => 1) : () } @$v;
    return [ grep { $have{$_} } @PROBE_ORDER ];
}

# ---------------------------------------------------------------------------
# 03-resources-reader-model -- the snapshot: build / encode / parse / status.
# ---------------------------------------------------------------------------

# Keys of @STRUCT_KEYS that snapshot_build coerces through _num rather than
# _str (03-resources-reader-model fix-batch, red-team M6). machine_name and
# host_disk_dev are free strings; machine_state is handled separately below
# (it is an enum, not a free string, and undef is a MEANINGFUL value -- "no
# container" -- that must survive, unlike a garbage/ref value).
my %NUM_STRUCT_KEY = map { $_ => 1 } qw(
    ctr_mem_used vm_mem_total ctr_cpu_pct
    pod_images pod_containers pod_volumes
    host_ram_used host_ram_total
    host_disk_used host_disk_total
    host_cpu_pct host_cores
);
my %MACHINE_STATE_OK = map { $_ => 1 } qw(running starting stopped unknown);

# Resources::snapshot_build($struct, $meta) -> \%snapshot. $struct is a
# Resources::build-shaped hashref (or not -- see below); $meta is
# { now, pid, container, platform, probes_run, probes_absent }. Returns a
# hashref with EXACTLY eight keys, always all present: v (always 1),
# written_at (uint|undef), sampler_pid (uint|undef), container (str|undef),
# platform ('windows'|'posix'), probes_run/probes_absent (arrayrefs,
# @PROBE_ORDER-filtered and -ordered), resources (the closed 15-key struct --
# Resources::build({}) if $struct is not a hashref, else exactly the 15
# @STRUCT_KEYS values taken from it, missing key -> undef, no other key
# copied in).
#
# 03-resources-reader-model fix-batch (red-team M6): on the WRITE path
# $struct comes from Resources::build, where every value is already
# _num/_str-coerced -- but on the READ path (snapshot_parse) it comes from
# arbitrary JSON, and a plain verbatim copy handed a HASH/ARRAY ref or a
# JSON::PP::Boolean straight to the panel, reopening a Dashboard rendering
# branch (a gauge bar with no real values behind it) that was previously
# unreachable. Each value is now coerced the SAME way build() itself would
# have produced it -- idempotent on already-clean input, so this changes
# nothing for a real sampler and only tightens the corrupt/hostile-file case.
# PUBLIC, pure, total.
sub snapshot_build {
    my ($struct, $meta) = @_;
    $meta = {} unless ref $meta eq 'HASH';

    my $resources;
    if (ref $struct eq 'HASH') {
        $resources = {};
        for my $k (@STRUCT_KEYS) {
            my $v = $struct->{$k};
            if ($k eq 'machine_state') {
                $v = 'unknown' if defined $v && (ref $v || !$MACHINE_STATE_OK{$v});
            } elsif ($NUM_STRUCT_KEY{$k}) {
                $v = _num($v);
            } else {
                $v = _str($v);
            }
            $resources->{$k} = $v;
        }
    } else {
        $resources = build({});
    }

    return {
        v              => $SNAPSHOT_VERSION,
        written_at     => _uint($meta->{now}),
        sampler_pid    => _uint($meta->{pid}),
        container      => _str($meta->{container}),
        platform       => (defined $meta->{platform} && $meta->{platform} eq 'windows') ? 'windows' : 'posix',
        probes_run     => _probe_list($meta->{probes_run}),
        probes_absent  => _probe_list($meta->{probes_absent}),
        # WHY each probe yielded nothing, when the caller collected it. Meta,
        # not a fact -- it describes the MEASUREMENT, exactly as probes_run and
        # probes_absent do, and is what turns "14 facts unavailable" from a
        # symptom into something an operator can act on.
        probe_errors   => ((ref $meta->{probe_errors} eq 'HASH') ? $meta->{probe_errors} : {}),
        resources      => $resources,
    };
}

# Resources::snapshot_encode($snapshot) -> $bytes | undef. Canonical (sorted
# key order) JSON::PP encoding, so a round-trip is byte-comparable. undef if
# $snapshot is not a hashref or the encode fails. PUBLIC, pure, total.
sub snapshot_encode {
    my ($snap) = @_;
    return undef unless ref $snap eq 'HASH';
    local $@;
    my $bytes = eval { JSON::PP->new->canonical(1)->encode($snap) };
    return (defined $bytes && !$@) ? $bytes : undef;
}

# Resources::snapshot_parse($bytes) -> \%snapshot | undef. Total inverse of
# snapshot_encode: undef -- NEVER a partial struct -- when $bytes is
# undef/ref/empty, is not decodable JSON (covers a truncated document),
# decodes to something other than a hashref, has v != 1, or has a
# `resources` that is not a hashref. Otherwise returns a NORMALISED snapshot
# (routed back through snapshot_build, so it carries the same eight keys and
# coercions, and `resources` is normalised to exactly the 15 @STRUCT_KEYS
# keys). Goes through _decode (BOM strip, warnings swallowed, never dies).
# PUBLIC, pure, total.
sub snapshot_parse {
    my ($bytes) = @_;
    return undef if !defined $bytes || ref $bytes || !length $bytes;
    my $d = _decode($bytes);
    return undef unless ref $d eq 'HASH';
    my $v = _uint($d->{v});
    return undef unless defined $v && $v == $SNAPSHOT_VERSION;
    return undef unless ref $d->{resources} eq 'HASH';
    return snapshot_build($d->{resources}, {
        now           => $d->{written_at},
        pid           => $d->{sampler_pid},
        container     => $d->{container},
        platform      => $d->{platform},
        probes_run    => $d->{probes_run},
        probes_absent => $d->{probes_absent},
    });
}

# Resources::snapshot_status($parsed, $now, $max_age) -> { state, age,
# written_at, resources }. $max_age defaults to max_age() when not a usable
# positive number. `state` is NEVER 'absent' here -- absence is a filesystem
# fact and belongs to the caller (_gather_resources). On 'stale' and 'failed'
# the returned `resources` is the all-n/a struct: a stale snapshot's numbers
# are never handed to the panel as if current. Evaluated in this order:
#   $parsed not a hashref                      -> failed, age undef, written_at undef, resources build({})
#   written_at/$now not usable numbers         -> failed, age undef, written_at AS PARSED, resources build({})
#   $now < written_at (clock went backwards)   -> fresh,  age 0,             resources $parsed->{resources}
#   $now - written_at <= $max_age              -> fresh,  age (now-written_at), resources $parsed->{resources}
#   otherwise                                  -> stale,  age (now-written_at), resources build({})
#
# H3 (03-resources-reader-model fix-batch, step 7): a $written_at meaningfully
# AHEAD of $now used to read unconditionally as fresh/age=>0, with no bound on
# the skew -- one NTP step or DST jump would pin the panel to an arbitrarily
# old measurement presented as "written just now". The anti-flicker intent
# (small forward skew should not flicker the panel to n/a) is preserved for
# skew <= $max_age; beyond that the skew can no longer be told apart from a
# genuine time machine, so it degrades to 'stale' like any other aged-out
# snapshot -- never to 'failed', because the record itself is well-formed and
# the resources it names once existed.
# Never dies, never warns. PUBLIC, pure, total.
sub snapshot_status {
    my ($parsed, $now, $max_age) = @_;
    my $ma = _num($max_age);
    $ma = max_age() unless defined $ma && $ma > 0;

    return { state => 'failed', age => undef, written_at => undef, resources => build({}) }
        unless ref $parsed eq 'HASH';

    my $wa = _num($parsed->{written_at});
    my $n  = _num($now);
    return { state => 'failed', age => undef, written_at => $parsed->{written_at}, resources => build({}) }
        unless defined $wa && defined $n;

    return { state => 'fresh', age => 0, written_at => $wa, resources => $parsed->{resources} }
        if $n < $wa && ($wa - $n) <= $ma;

    return { state => 'stale', age => 0, written_at => $wa, resources => build({}) }
        if $n < $wa;

    return { state => 'fresh', age => $n - $wa, written_at => $wa, resources => $parsed->{resources} }
        if ($n - $wa) <= $ma;

    return { state => 'stale', age => $n - $wa, written_at => $wa, resources => build({}) };
}

# ---------------------------------------------------------------------------
# 03-resources-reader-model -- sampler pidfile / orphan-reap decision.
# ---------------------------------------------------------------------------

# Resources::sampler_reap_decision($text, $now, $interval, $owner_alive) ->
# { pid, owner, reap }. Parses one sampler pidfile record and decides whether
# killing that PID is safe. $text must match /^\s*(\d+)\s+(\d+)\s+(\d+)\s*$/
# -- "sampler_pid owner_pid stamp". No match (including undef/ref/empty
# $text) -> { pid => undef, owner => undef, reap => 0 }. On match: pid => $1,
# owner => $2 (03 fix-batch H1: previously DISCARDED via
# "my ($pid, undef, $stamp) = (...)", which meant nothing downstream could
# ever tell a live peer's sampler apart from a genuine orphan -- recovering
# it here is what makes the 4th parameter meaningful).
#
# $owner_alive answers a DIFFERENT question than the stamp does: the stamp
# says "is this record recent"; $owner_alive says "is this process actually
# an orphan". Only the second question is safe to gate a kill() on --
# 03 fix-batch H1/H2c:
#   $owner_alive is TRUE      -> reap => 0 UNCONDITIONALLY. A live recorded
#                                 owner is BY DEFINITION not orphaned, no
#                                 matter how stale or fresh the stamp reads
#                                 (this is what stops a second dashboard's
#                                 reaper from killing a first dashboard's
#                                 healthy sampler -- red-team H1).
#   $owner_alive is FALSE     -> reap => 1 whenever pid > 0, $now is usable,
#                                 and $stamp <= $now -- REGARDLESS of
#                                 staleness. A confirmed-dead owner removes
#                                 the PID-recycling ambiguity that the
#                                 staleness rule exists to guard against, so
#                                 a wedged-but-ours sampler (frozen stamp, the
#                                 exact state a hung probe produces) is now
#                                 reapable instead of being permanently
#                                 immortal -- red-team H2c.
#   $owner_alive is undef     -> falls back to the ORIGINAL freshness-only
#     (the default when omitted) algorithm: reap => 1 IFF pid > 0 AND $now is usable AND
#                                 $stamp <= $now AND $now - $stamp <= 3 *
#                                 $interval. This is the correct fallback for
#                                 a caller that cannot determine owner
#                                 liveness -- it is NOT what a caller that CAN
#                                 determine it should rely on; see
#                                 _resources_sampler_reap_orphan in
#                                 launcher.pl, which always computes and
#                                 passes owner liveness explicitly rather than
#                                 omitting this argument.
# pid = 0 always refuses (reap => 0), independent of $owner_alive -- pid
# remains the load-bearing safety gate. $interval defaults to interval() when
# unusable. Never dies, never warns. PUBLIC, pure, total.
sub sampler_reap_decision {
    my ($text, $now, $iv, $owner_alive) = @_;
    return { pid => undef, owner => undef, reap => 0 } if !defined $text || ref $text;
    return { pid => undef, owner => undef, reap => 0 } unless $text =~ /^\s*(\d+)\s+(\d+)\s+(\d+)\s*$/;
    my ($pid, $owner, $stamp) = ($1, $2, $3);

    my $i = _num($iv);
    $i = interval() unless defined $i && $i > 0;
    my $n = _num($now);

    my $reap;
    if (defined $owner_alive) {
        if ($owner_alive) {
            $reap = 0;                                                     # H1: never reap a live owner's sampler
        } else {
            $reap = ($pid > 0 && defined $n && $stamp <= $n) ? 1 : 0;       # H2c: dead owner -> reapable regardless of staleness
        }
    } else {
        $reap = ($pid > 0 && defined $n && $stamp <= $n && ($n - $stamp) <= 3 * $i) ? 1 : 0;  # original freshness-only fallback
    }
    return { pid => $pid, owner => $owner, reap => $reap };
}

# sampler_start_outcome($pid, $errno_str, $started_at) -> \%fact
#
# The pure translation from a fork() result into the plain-data fact the TUI
# renders. It lives HERE rather than in launcher.pl for one reason: the sandbox
# suite never require's launcher.pl (it builds container images), so anything
# that needs a real function-call test has to sit in a real module.
#
# WHY THIS EXISTS AT ALL. _resources_sampler_start already knew whether the fork
# succeeded, and already LOGGED the failure -- but the answer was kept in a
# teardown-only lexical and never reached the screen. So a sampler that failed
# to start and a sampler that was merely three seconds old rendered the same
# sentence, forever: "sampling - no reading yet". The operator reported exactly
# that. The fact was not missing; it was discarded on the way to the panel.
sub sampler_start_outcome {
    my ($pid, $errno_str, $started_at) = @_;
    my $at = _uint($started_at);
    my $p  = _uint($pid);
    return {
        status     => 'ok',
        (defined $at ? (started_at => $at) : ()),
        pid        => $p,
    } if defined $p && $p > 0;

    # No usable pid: a failure, whether or not the caller handed us an errno.
    # Never invent a pid key, and never report success for an absent child.
    my $why = _str($errno_str);
    return {
        status => 'failed',
        (defined $at ? (started_at => $at) : ()),
        reason => 'fork: ' . (defined $why ? $why : 'unknown'),
    };
}

1;
