#!/usr/bin/env perl
# s09-resources-panel: podman machine + container + host resources.
#
# This file is the IMMUTABLE ORACLE for blueprint sandbox-butler-overhaul,
# package s09-resources-panel (specs/s09-resources-panel-spec.md). It is
# written BLIND to any Resources.pm / Dashboard.pm / launcher.pl
# implementation -- directly from the spec -- so it can serve as an oracle
# rather than an echo of whatever the implementer eventually writes.
#
# Coverage: AC-1..AC-32 (spec S4). AC-33 (whole-suite-green gate) is
# deliberately NOT encoded here -- it is a coordinator-side check, exactly as
# t/43 treats its AC-22.
#
# Resources.pm DOES NOT EXIST YET, and neither Dashboard::_resources_lines /
# pressure_role / gauge / fmt_bytes nor the launcher wiring have landed. Every
# call below goes through a helper that wraps the call in `eval`, so a missing
# module/sub degrades to a clean per-assertion FAIL rather than aborting the
# file. That is EXPECTED and correct until the implementer lands s09.
#
# Hard constraints honoured here (spec S7):
#   * self-contained -- every fixture is INLINED as a Perl string literal;
#     this file never reads .ccpraxis-local-data/ (gitignored, does not travel).
#   * launcher.pl is NEVER require'd/do'ne -- source-text slurp + regex only,
#     plus `perl -c` in a subprocess (t/36:3's stated convention).
#   * this file MUST NOT `use utf8`; glyphs are "\x{...}" escapes encoded to
#     UTF-8 bytes via Encode::encode.
#   * no real clock, no sleep -- the slow-probe assertion (AC-21) drives
#     Resources::gather with an injected fake clock.
#
# SPEC CONFLICT recorded in-place (see the AC-23 block): spec S3 B12 pins
# should_sample(0, 0, 23) => 1, but the binding algorithm in S2.3 yields 0
# (0 and 0 are both numeric, 0 is not < 0, and 0 - 0 >= 23 is false). This
# file asserts the S2.3 algorithm -- the normative interface contract -- and
# additionally asserts the startup behaviour B12's vector was reaching for.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use Encode qw(encode decode);
use JSON::PP ();
use File::Temp qw(tempdir);

# ===========================================================================
# Pinned "now" -- no real-clock dependence anywhere in this file (S7).
# ===========================================================================
my $NOW = 1700003600;

my $SCRIPTS_DIR    = "$Bin/../../scripts";
my $LAUNCHER_PATH  = "$SCRIPTS_DIR/launcher.pl";
my $DASHBOARD_PATH = "$SCRIPTS_DIR/Dashboard.pm";
my $RESOURCES_PATH = "$SCRIPTS_DIR/Resources.pm";

# ===========================================================================
# Inlined fixtures (copied from fixtures/06-resources/, trimmed to the fields
# the spec reads). S7's fixture table.
# ===========================================================================
my $BOM = "\xEF\xBB\xBF";    # 3 BYTES, exactly the captured PowerShell prefix
my $CTR = 'claude-ccpraxis-ec7f975a';
my $CTR2 = 'claude-gsa-superapp-0f5c8f75';

my $FX_MACHINE = q{[{"Name":"podman-machine-default","Default":true,"Running":true,"Starting":false,"Memory":"6442450944","DiskSize":"21474836480"}]};

my $FX_STATS = q{[
 {
  "id": "30e78c418c1d",
  "name": "claude-ccpraxis-ec7f975a",
  "cpu_time": "3m22.676891s",
  "cpu_percent": "3.76%",
  "avg_cpu": "3.76%",
  "mem_usage": "18.51MB / 6.214GB",
  "mem_percent": "0.30%",
  "net_io": "3.746MB / 4.815MB",
  "block_io": "10.43MB / 782.3kB",
  "pids": "12"
 },
 {
  "id": "17ce63b765bc",
  "name": "claude-gsa-superapp-0f5c8f75",
  "cpu_time": "5m47.818382s",
  "cpu_percent": "7.82%",
  "avg_cpu": "7.82%",
  "mem_usage": "1.153GB / 6.214GB",
  "mem_percent": "18.56%",
  "net_io": "2.085GB / 17.6MB",
  "block_io": "325.8MB / 5.828GB",
  "pids": "23"
 }
]};

my $FX_DF = q{[
    {"Type":"Images","Total":24,"Active":2,"RawSize":684907310,"RawReclaimable":684894973,"TotalCount":24,"Size":"684.9MB","Reclaimable":"684.9MB (100%)"},
    {"Type":"Containers","Total":3,"Active":2,"RawSize":4594936026,"RawReclaimable":13305,"TotalCount":3,"Size":"4.595GB","Reclaimable":"13.3kB (0%)"},
    {"Type":"Local Volumes","Total":0,"Active":0,"RawSize":0,"RawReclaimable":0,"TotalCount":0,"Size":"0B","Reclaimable":"0B (0%)"}
]};

# Same document with the "Local Volumes" row removed (AC-8, second half).
my $FX_DF_NO_VOL = q{[
    {"Type":"Images","Total":24,"Active":2,"RawSize":684907310,"RawReclaimable":684894973},
    {"Type":"Containers","Total":3,"Active":2,"RawSize":4594936026,"RawReclaimable":13305}
]};

my $FX_CIM_MEM = q{{"FreePhysicalMemory":3566360,"TotalVisibleMemorySize":24943928}};

my $FX_CIM_DISK = q{[{"DeviceID":"C:","FreeSpace":49240297472,"Size":254788440064},{"DeviceID":"G:","FreeSpace":46778281984,"Size":254788440064}]};

# ConvertTo-Json emits a BARE HASH when only one drive matches (AC-10).
my $FX_CIM_DISK_ONE = q{{"DeviceID":"C:","FreeSpace":49240297472,"Size":254788440064}};

# `Name` is kept deliberately, to prove the parser ignores it (S2.1).
my $FX_CIM_CPU = q{{"Name":"11th Gen Intel(R) Core(TM) i5-1135G7 @ 2.40GHz","LoadPercentage":16,"NumberOfLogicalProcessors":8}};

# Two machines, the Default-truthy one NOT first (AC-5 / B3).
my $FX_MACHINE_TWO = q{[{"Name":"other-machine","Default":false,"Running":false,"Starting":false},{"Name":"podman-machine-default","Default":true,"Running":true,"Starting":false}]};

# Running false / Starting true (AC-5 / B3).
my $FX_MACHINE_STARTING = q{[{"Name":"boot-me","Default":true,"Running":false,"Starting":true}]};

# ===========================================================================
# Glyph literals (S2.5): UTF-8 BYTES, the module's span `text` contract.
# ===========================================================================
my $FULL  = encode('UTF-8', "\x{2588}");    # E2 96 88
my $LIGHT = encode('UTF-8', "\x{2591}");    # E2 96 91

sub g { my ($f, $cells) = @_; $cells = 10 unless defined $cells; return ($FULL x $f) . ($LIGHT x ($cells - $f)); }

# ===========================================================================
# The B10 struct, written out LITERALLY so the panel tests do not depend on
# Resources::build having landed.
# ===========================================================================
my %B10 = (
    machine_name    => 'podman-machine-default',
    machine_state   => 'running',
    ctr_mem_used    => 18510000,
    vm_mem_total    => 6214000000,
    ctr_cpu_pct     => 3.76,
    pod_images      => 684907310,
    pod_containers  => 4594936026,
    pod_volumes     => 0,
    host_ram_used   => 21890629632,
    host_ram_total  => 25542582272,
    host_disk_dev   => 'C:',
    host_disk_used  => 205548142592,
    host_disk_total => 254788440064,
    host_cpu_pct    => 16,
    host_cores      => 8,
);

my @KEYS_15 = qw(
    machine_name machine_state
    ctr_mem_used vm_mem_total ctr_cpu_pct
    pod_images pod_containers pod_volumes
    host_ram_used host_ram_total
    host_disk_dev host_disk_used host_disk_total
    host_cpu_pct host_cores
);

# The all-n/a struct (S2.2 last bullet).
my %ALL_NA = map { $_ => undef } @KEYS_15;
$ALL_NA{machine_state} = 'unknown';

# ===========================================================================
# Scaffolding
# ===========================================================================

# slurp($path) -> file contents, or '' if unreadable. (Verbatim from t/43.)
sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

# _balanced($src, $from) -> the brace-balanced block starting at the first '{'
# at-or-after $from, or undef.
sub _balanced {
    my ($src, $from) = @_;
    my $brace_idx = index($src, '{', $from);
    return undef if $brace_idx < 0;
    my $depth = 0;
    my $i     = $brace_idx;
    my $len   = length($src);
    for (; $i < $len; $i++) {
        my $c = substr($src, $i, 1);
        if    ($c eq '{') { $depth++; }
        elsif ($c eq '}') { $depth--; last if $depth == 0; }
    }
    return undef if $depth != 0;
    return substr($src, $brace_idx, $i - $brace_idx + 1);
}

# extract_block($src, $start_literal) -> brace-balanced block. (From t/43.)
sub extract_block {
    my ($src, $start_literal) = @_;
    my $idx = index($src, $start_literal);
    return undef if $idx < 0;
    return _balanced($src, $idx);
}

# extract_block_re($src, $qr) -> brace-balanced block starting at the first
# '{' at-or-after the first match of $qr. Source-text only; launcher.pl is
# never loaded.
sub extract_block_re {
    my ($src, $qr) = @_;
    return undef unless $src =~ $qr;
    return _balanced($src, $-[0]);
}

# $FAILED is the sentinel returned in place of a value whenever a call could
# not be made at all (missing module/sub) or died. It exists so that an
# assertion expecting `undef` can never PASS just because Resources.pm is not
# there yet -- an oracle that passes for the wrong reason is worse than no
# oracle. It is deliberately a blessed ref, so it is never == undef, never a
# plain HASH, and never numerically equal to anything by accident.
my $FAILED = bless { t44 => 'call did not happen' }, 'T44::CallFailed';

# probe_call($fn, @args) -> ($result, $err, \@warnings). Never propagates a
# die (so a missing Resources.pm degrades to a per-assertion FAIL).
sub probe_call {
    my ($fn, @args) = @_;
    my @warns;
    my $res;
    my $err;
    {
        local $SIG{__WARN__} = sub { push @warns, $_[0] };
        $res = eval { no strict 'refs'; &{"Resources::$fn"}(@args) };
        $err = $@;
    }
    $err = '' unless defined $err;
    return ($res, $err, \@warns);
}

# R($fn, @args) -> just the value, or $FAILED if the sub is missing / died.
sub R {
    my ($res, $err) = probe_call(@_);
    return $FAILED if $err ne '';
    return $res;
}

# D($fn, @args) -> Dashboard::$fn(@args) scalar value, undef on missing/die.
sub D {
    my ($fn, @args) = @_;
    my $res = eval { no strict 'refs'; &{"Dashboard::$fn"}(@args) };
    return $res;
}

sub is_hashref { my ($h) = @_; return ref($h) eq 'HASH'; }

# field($h, $k) -> $h->{$k}, or $FAILED when $h is not a plain hashref (so an
# `is(field(...), undef)` assertion cannot pass on a call that never happened).
sub field { my ($h, $k) = @_; return is_hashref($h) ? $h->{$k} : $FAILED; }

# numeric($v) -> true only for a defined, non-ref, numeric scalar.
sub numeric { my ($v) = @_; return defined($v) && !ref($v) && $v =~ /^-?\d+(?:\.\d+)?$/; }

# _deep_values($v, $acc) -> flat arrayref of every non-ref scalar in $v.
sub _deep_values {
    my ($v, $acc) = @_;
    $acc ||= [];
    if    (ref $v eq 'HASH')  { _deep_values($_, $acc) for values %$v; }
    elsif (ref $v eq 'ARRAY') { _deep_values($_, $acc) for @$v; }
    else                      { push @$acc, $v; }
    return $acc;
}

# line_text($line) -> the concatenated span text of one body line.
sub line_text {
    my ($line) = @_;
    return '' unless ref($line) eq 'ARRAY';
    return join('', map { (ref($_) eq 'HASH' && defined $_->{text}) ? $_->{text} : '' } @$line);
}

# panel_by_title(\@panels, $title) -> the panel hashref or undef.
sub panel_by_title {
    my ($panels, $title) = @_;
    return undef unless ref($panels) eq 'ARRAY';
    for my $p (@$panels) {
        return $p if ref($p) eq 'HASH' && defined $p->{title} && $p->{title} eq $title;
    }
    return undef;
}

# The 7 pinned label spans (S2.6), written out literally rather than via
# sprintf, so the oracle pins the rendered text and not the formula.
my @LABELS = (
    'machine     : ',
    'ctr mem     : ',
    'ctr cpu     : ',
    'podman      : ',
    'host ram    : ',
    'host disk   : ',
    'host cpu    : ',
);
my @LABEL_SPANS = map { { text => $_, role => 'label' } } @LABELS;
my $NA_SPAN = { text => 'n/a', role => 'muted' };
my $SEP_SPAN = { text => '  ', role => 'body' };

my @ALLOWED_ROLES = qw(label value muted strong good warn bad accent body);

# ===========================================================================
# 1. Load + purity.
# ===========================================================================
use_ok('Resources');
use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

# --- AC-14 -> DC-1/DC-3 (S2.0): Resources.pm is provably pure. -------------
{
    my $raw = slurp($RESOURCES_PATH);
    ok(length($raw) > 0, 'AC-14: Resources.pm exists and is readable on disk')
        or diag("expected at $RESOURCES_PATH");

    my $have = (length($raw) > 0);
    my $src  = $raw;
    $src =~ s/#[^\n]*//g;    # strip #-to-end-of-line comments (AC-14)

    my @forbidden = (
        [ 'a backtick character', qr/`/ ],
        [ 'qx',                   qr/\bqx\b/ ],
        [ 'system(',              qr/\bsystem\s*\(/ ],
        [ 'exec(',                qr/\bexec\s*\(/ ],
        [ 'open(',                qr/\bopen\s*\(/ ],
        [ 'open FILEHANDLE',      qr/\bopen\s+my\b/ ],
        [ 'stat(',                qr/\bstat\s*\(/ ],
        [ 'readdir',              qr/\breaddir\b/ ],
        [ 'time(',                qr/\btime\s*\(/ ],
        [ 'bare time',            qr/\btime\b/ ],
        [ 'localtime',            qr/\blocaltime\b/ ],
        [ 'gmtime',               qr/\bgmtime\b/ ],
        [ 'sleep',                qr/\bsleep\b/ ],
        # NARROWED 2026-08-19 by package t01-resources-sampler (blueprint
        # tui-operator-feedback), from qr/\bfork\b/ to a CALL.
        #
        # This list enforces PURITY -- Resources.pm does no I/O, reads no clock,
        # spawns nothing. A bare-word match also forbade the WORD, and so caught
        # `reason => 'fork: ...'`: a string the module must now produce, because
        # it is the text the panel shows when the sampler could not be spawned,
        # fixed verbatim by the t01 spec.
        #
        # Forbidding a CALL is the property that was meant. Forbidding a
        # substring additionally forbade the module from naming the thing it
        # reports on, which is not purity. Package d01 of the predecessor
        # initiative spent a fix-batch on this same over-broad shape.
        [ 'a fork call',          qr/\bfork\s*(?:\(|;)/ ],
        [ 'alarm',                qr/\balarm\b/ ],
        [ '$PODMAN',              qr/\$PODMAN\b/ ],
        [ 'powershell',           qr/powershell/i ],
        [ 'an ANSI escape',       qr/\\e\[/ ],
        [ 'a literal ESC byte',   qr/\x1b/ ],
        [ 'a -e/-f file test',    qr/(?<![\w\$])-[ef]\s/ ],
    );
    for my $f (@forbidden) {
        my ($label, $qr) = @$f;
        my $desc = "AC-14: Resources.pm source (comments stripped) contains no $label";
        $have ? unlike($src, $qr, $desc) : fail("$desc [Resources.pm not on disk]");
    }

    # Render vocabulary must not appear at all (S2.0 "no render vocabulary").
    for my $word (qw(sgr_for_role display_width make_cell)) {
        my $desc = "AC-14: Resources.pm source contains no render primitive '$word'";
        $have ? unlike($src, qr/\Q$word\E/, $desc) : fail("$desc [Resources.pm not on disk]");
    }

    # Dependencies: JSON::PP only (plus the strict/warnings pragmas).
    if ($have) {
        my %allowed = map { $_ => 1 } qw(strict warnings constant JSON::PP);
        my @used;
        while ($src =~ /^\s*(?:use|require)\s+([A-Za-z_][\w:]*)/mg) { push @used, $1; }
        my @extra = grep { !$allowed{$_} } @used;
        is_deeply(\@extra, [],
            'AC-14: Resources.pm use/require only strict, warnings and JSON::PP (no new dependency)')
            or diag('unexpected dependencies: ' . join(', ', @extra));
    } else {
        fail('AC-14: Resources.pm use/require only strict, warnings and JSON::PP [Resources.pm not on disk]');
    }
    like($src, qr/\buse\s+JSON::PP\b/, 'AC-14: Resources.pm uses JSON::PP (the one allowed dependency)');
}

# --- AC-26 -> DC-3 (B28): Dashboard.pm does not know Resources.pm. --------
{
    my $dash = slurp($DASHBOARD_PATH);
    ok(length($dash) > 0, 'AC-26: Dashboard.pm is readable on disk') or BAIL_OUT("cannot read $DASHBOARD_PATH");
    unlike($dash, qr/\buse\s+Resources\b/,     'AC-26: Dashboard.pm source contains no "use Resources"');
    unlike($dash, qr/\brequire\s+Resources\b/, 'AC-26: Dashboard.pm source contains no "require Resources"');
    unlike($dash, qr/Resources::/,             'AC-26: Dashboard.pm source contains no "Resources::" call');
}

# ===========================================================================
# 2. Scalar parsers -- AC-3, AC-4.
# ===========================================================================

# --- AC-3 -> DC-1 (B6): parse_human_bytes, decimal by default. ------------
{
    my @pinned = (
        [ '18.51MB', 18510000 ],
        [ '6.214GB', 6214000000 ],
        [ '1.153GB', 1153000000 ],
        [ '782.3kB', 782300 ],
        [ '0B',      0 ],
        [ '999B',    999 ],
        [ '1kB',     1000 ],
        [ '1KiB',    1024 ],
        [ '1MiB',    1048576 ],
    );
    for my $c (@pinned) {
        my ($in, $want) = @$c;
        is(R('parse_human_bytes', $in), $want, "AC-3: parse_human_bytes('$in') == $want (B6, decimal unless IEC)");
    }
    my @bad = ( [ 'undef', undef ], [ "''", '' ], [ "'abc'", 'abc' ], [ "'12'", '12' ],
                [ "'-1MB'", '-1MB' ], [ "'1.2.3MB'", '1.2.3MB' ], [ '[]', [] ] );
    for my $c (@bad) {
        my ($label, $in) = @$c;
        is(R('parse_human_bytes', $in), undef, "AC-3: parse_human_bytes($label) == undef");
    }
    # The decimal/binary distinction is the whole point of B6.
    my $gb = R('parse_human_bytes', '6.214GB');
    ok(numeric($gb) && $gb != 6672894525,
        'AC-3: parse_human_bytes("6.214GB") is NOT the binary interpretation (B6)');
}

# --- AC-4 -> DC-1: parse_percent, the '%' optional. -----------------------
{
    my @pinned = ( [ "'3.76%'", '3.76%', 3.76 ], [ "'7.82%'", '7.82%', 7.82 ],
                   [ '16 (bare number)', 16, 16 ], [ "'0%'", '0%', 0 ] );
    for my $c (@pinned) {
        my ($label, $in, $want) = @$c;
        is(R('parse_percent', $in), $want, "AC-4: parse_percent($label) == $want");
    }
    is(R('parse_percent', 'n/a'), undef, "AC-4: parse_percent('n/a') == undef");
    is(R('parse_percent', '-3%'), undef, "AC-4: parse_percent('-3%') == undef (leading sign rejected)");
    is(R('parse_percent', undef), undef, 'AC-4: parse_percent(undef) == undef');
}

# ===========================================================================
# 3. Document parsers vs the inlined fixtures -- AC-2, AC-5, AC-7..AC-11.
# ===========================================================================

# --- AC-5 -> DC-1 (B3): parse_machine_list. -------------------------------
{
    my $m = R('parse_machine_list', $FX_MACHINE);
    is_deeply($m, { name => 'podman-machine-default', running => 1, starting => 0 },
        'AC-5: parse_machine_list(fixture) == {name,running,starting} exactly (B3)');
    if (is_hashref($m)) {
        is_deeply([ sort keys %$m ], [ qw(name running starting) ],
            'AC-5: parse_machine_list returns exactly the three keys name/running/starting');
    } else {
        fail('AC-5: parse_machine_list returns exactly the three keys name/running/starting');
    }

    is(R('parse_machine_list', '[]'), undef, "AC-5: parse_machine_list('[]') == undef (B3)");

    my $two = R('parse_machine_list', $FX_MACHINE_TWO);
    is(field($two, 'name'), 'podman-machine-default',
        'AC-5: with two machines the Default-truthy one is chosen regardless of position (B3)');
    is(field($two, 'running'), 1, 'AC-5: the Default-truthy machine carries its own Running value (B3)');

    my $st = R('parse_machine_list', $FX_MACHINE_STARTING);
    is(field($st, 'running'),  0, 'AC-5: Running false -> running == 0 (B3)');
    is(field($st, 'starting'), 1, 'AC-5: Starting true -> starting == 1 (B3)');
}

# --- AC-6 -> DC-1 (B4): configured VM memory never reaches the struct. ----
{
    my $m = R('parse_machine_list', $FX_MACHINE);
    if (is_hashref($m)) {
        my @mem_keys = grep { /mem/i } keys %$m;
        is_deeply(\@mem_keys, [], 'AC-6: parse_machine_list result has no /mem/i key at all (B4)');
    } else {
        fail('AC-6: parse_machine_list result has no /mem/i key at all (B4) [no hashref returned]');
    }

    my $built = R('build', { machine => $FX_MACHINE, stats => $FX_STATS, df => $FX_DF,
                             cim_mem => $BOM . $FX_CIM_MEM, cim_disk => $BOM . $FX_CIM_DISK,
                             cim_cpu => $BOM . $FX_CIM_CPU, container => $CTR, device => 'C:' });
    for my $forbidden (6442450944, 6144) {
        my $desc = "AC-6: no value in the built struct is the configured machine memory ($forbidden) (B4)";
        if (!is_hashref($built)) {
            fail("$desc [build() did not return a hashref]");
            next;
        }
        my $vals = _deep_values($built);
        my $hits = grep { numeric($_) && $_ == $forbidden } @$vals;
        is($hits, 0, $desc);
    }

    my $src = slurp($RESOURCES_PATH);
    my $have = (length($src) > 0);
    $src =~ s/#[^\n]*//g;
    my @scans = (
        [ 'no "machine inspect" probe/parser (S6)',   qr/machine\s+inspect/ ],
        [ 'no bare "Memory" traversal (FreePhysicalMemory/TotalVisibleMemorySize are exempt)',
                                                      qr/(?<![A-Za-z])Memory(?![A-Za-z])/ ],
        [ 'no "DiskSize" traversal (B4)',             qr/(?<![A-Za-z])DiskSize(?![A-Za-z])/ ],
    );
    for my $s (@scans) {
        my ($label, $qr) = @$s;
        my $desc = "AC-6: Resources.pm source has $label";
        $have ? unlike($src, $qr, $desc) : fail("$desc [Resources.pm not on disk]");
    }
}

# --- AC-7 -> DC-1 (B5): parse_stats selects BY NAME, never by position. ---
{
    my $s1 = R('parse_stats', $FX_STATS, $CTR);
    is_deeply($s1, { name => $CTR, mem_used => 18510000, mem_limit => 6214000000, cpu_pct => 3.76 },
        "AC-7: parse_stats(fixture, '$CTR') selects the index-0 container by name (B5)");

    my $s2 = R('parse_stats', $FX_STATS, $CTR2);
    is(field($s2, 'name'),      $CTR2,      "AC-7: parse_stats(fixture, '$CTR2') selects the index-1 container by name (B5)");
    is(field($s2, 'mem_used'),  1153000000, 'AC-7: the index-1 container mem_used == 1153000000 (B5)');
    is(field($s2, 'mem_limit'), 6214000000, 'AC-7: the index-1 container mem_limit == 6214000000 (B5)');
    is(field($s2, 'cpu_pct'),   7.82,       'AC-7: the index-1 container cpu_pct == 7.82 (B5)');

    for my $bad ( [ "'nope'", 'nope' ], [ 'undef', undef ], [ "''", '' ], [ '[]', [] ] ) {
        my ($label, $name) = @$bad;
        is(R('parse_stats', $FX_STATS, $name), undef,
            "AC-7: parse_stats(fixture, $label) == undef -- NO positional fallback (B5)");
    }

    # A bare hash document is treated as a one-element array (S2.1).
    my $one = q{{"name":"solo","cpu_percent":"1.00%","mem_usage":"1MB / 2MB"}};
    is_deeply(R('parse_stats', $one, 'solo'),
        { name => 'solo', mem_used => 1000000, mem_limit => 2000000, cpu_pct => 1 },
        'AC-7: a bare-HASH stats document is treated as a one-element array');

    # mem_usage without a '/' -> both byte fields undef, name still matched.
    my $nos = q{[{"name":"solo","cpu_percent":"2%","mem_usage":"18.51MB"}]};
    my $r   = R('parse_stats', $nos, 'solo');
    is(field($r, 'mem_used'),  undef, 'AC-7: mem_usage with no "/" -> mem_used undef');
    is(field($r, 'mem_limit'), undef, 'AC-7: mem_usage with no "/" -> mem_limit undef');
    is(field($r, 'cpu_pct'),   2,     'AC-7: mem_usage with no "/" leaves cpu_pct intact');
}

# --- AC-8 -> DC-1: parse_system_df. ---------------------------------------
{
    my $df = R('parse_system_df', $FX_DF);
    is_deeply($df, {
        images     => { size => 684907310,  reclaimable => 684894973 },
        containers => { size => 4594936026, reclaimable => 13305 },
        volumes    => { size => 0,          reclaimable => 0 },
    }, 'AC-8: parse_system_df(fixture) maps Images/Containers/Local Volumes exactly');

    my $df2 = R('parse_system_df', $FX_DF_NO_VOL);
    is(field($df2, 'volumes'), undef, 'AC-8: a df document with no "Local Volumes" row -> volumes => undef');
    is_deeply(field($df2, 'images'), { size => 684907310, reclaimable => 684894973 },
        'AC-8: ... with images intact');
    is_deeply(field($df2, 'containers'), { size => 4594936026, reclaimable => 13305 },
        'AC-8: ... with containers intact');
    if (is_hashref($df2)) {
        is_deeply([ sort keys %$df2 ], [ qw(containers images volumes) ],
            'AC-8: parse_system_df always returns exactly the three keys');
    } else {
        fail('AC-8: parse_system_df always returns exactly the three keys');
    }

    # Case-sensitive Type match, unknown types ignored.
    my $odd = q{[{"Type":"images","RawSize":5,"RawReclaimable":1},{"Type":"Wibble","RawSize":7,"RawReclaimable":2}]};
    my $df3 = R('parse_system_df', $odd);
    is(field($df3, 'images'), undef, 'AC-8: Type matching is case-sensitive ("images" is not "Images")');
}

# --- AC-9 -> DC-1 (B7): parse_cim_memory converts CIM kilobytes x1024. ----
{
    is_deeply(R('parse_cim_memory', $BOM . $FX_CIM_MEM),
        { ram_free => 3651952640, ram_total => 25542582272 },
        'AC-9: parse_cim_memory(BOM+fixture) == KB values x 1024 (B7)');
}

# --- AC-10 -> DC-1 (B8): parse_cim_disk drive selection. ------------------
{
    is_deeply(R('parse_cim_disk', $BOM . $FX_CIM_DISK, 'C:'),
        { device => 'C:', disk_free => 49240297472, disk_total => 254788440064 },
        "AC-10: parse_cim_disk(fixture,'C:') picks the C: row, bytes unconverted (B7/B8)");
    is_deeply(R('parse_cim_disk', $BOM . $FX_CIM_DISK, 'c:'),
        { device => 'C:', disk_free => 49240297472, disk_total => 254788440064 },
        "AC-10: parse_cim_disk(fixture,'c:') is case-insensitive and returns DeviceID verbatim (B8)");
    my $g = R('parse_cim_disk', $BOM . $FX_CIM_DISK, 'G:');
    is(field($g, 'device'),    'G:',        "AC-10: parse_cim_disk(fixture,'G:') picks the G: row (B8)");
    is(field($g, 'disk_free'), 46778281984, "AC-10: the G: row disk_free == 46778281984 (B8)");

    for my $bad ( [ "'Z:'", 'Z:' ], [ 'undef', undef ], [ "''", '' ], [ '[]', [] ] ) {
        my ($label, $dev) = @$bad;
        is(R('parse_cim_disk', $BOM . $FX_CIM_DISK, $dev), undef,
            "AC-10: parse_cim_disk(fixture, $label) == undef -- never guess a drive (B8)");
    }

    is_deeply(R('parse_cim_disk', $BOM . $FX_CIM_DISK_ONE, 'C:'),
        { device => 'C:', disk_free => 49240297472, disk_total => 254788440064 },
        'AC-10: a single-drive BARE-HASH document is parsed as a one-element array');
}

# --- AC-11 -> DC-1: parse_cim_cpu, Name ignored. --------------------------
{
    is_deeply(R('parse_cim_cpu', $BOM . $FX_CIM_CPU), { cpu_pct => 16, cores => 8 },
        'AC-11: parse_cim_cpu(BOM+fixture) == {cpu_pct=>16, cores=>8}, Name ignored');
    is_deeply(R('parse_cim_cpu', $BOM . '[' . $FX_CIM_CPU . ']'), { cpu_pct => 16, cores => 8 },
        'AC-11: an ARRAY-wrapped (multi-socket) document takes element [0] and yields the same values');
}

# --- AC-2 -> DC-1 (B1): BOM survival, and why the strip must exist. -------
{
    my @pairs = (
        [ 'parse_cim_memory', [ $FX_CIM_MEM ],           { ram_free => 3651952640, ram_total => 25542582272 } ],
        [ 'parse_cim_disk',   [ $FX_CIM_DISK, 'C:' ],    { device => 'C:', disk_free => 49240297472, disk_total => 254788440064 } ],
        [ 'parse_cim_cpu',    [ $FX_CIM_CPU ],           { cpu_pct => 16, cores => 8 } ],
    );
    for my $p (@pairs) {
        my ($fn, $args, $want) = @$p;
        my @with = @$args;
        $with[0] = $BOM . $with[0];
        my ($bom_res, $bom_err, $bom_warns) = probe_call($fn, @with);
        my ($raw_res, $raw_err, $raw_warns) = probe_call($fn, @$args);
        is_deeply($bom_res, $want,     "AC-2: $fn parses the BOM-prefixed fixture to the pinned values (B1)");
        is_deeply($raw_res, $want,     "AC-2: $fn parses the un-prefixed fixture to the identical values (B1)");
        my $ident_desc = "AC-2: $fn -- BOM and no-BOM results are identical (B1)";
        ($bom_err eq '' && $raw_err eq '' && !@$raw_warns)
            ? is_deeply($bom_res, $raw_res, $ident_desc)
            : fail("$ident_desc [one of the two calls did not complete]");
        is($bom_err, '',               "AC-2: $fn does not die on the BOM-prefixed fixture (B1)");
        ok($bom_err eq '' && !@$bom_warns,
                                       "AC-2: $fn completes without warning on the BOM-prefixed fixture (B1)");
    }

    # The podman fixtures survive a BOM too (B1 last sentence).
    is_deeply(R('parse_machine_list', $BOM . $FX_MACHINE),
        { name => 'podman-machine-default', running => 1, starting => 0 },
        'AC-2: a BOM prefixed onto the podman machine fixture still parses (B1)');
    is(field(R('parse_stats', $BOM . $FX_STATS, $CTR), 'mem_used'), 18510000,
        'AC-2: a BOM prefixed onto the podman stats fixture still parses (B1)');

    # Documents WHY the strip exists: raw decode_json on a BOM dies.
    my $ok = eval { JSON::PP::decode_json($BOM . $FX_CIM_MEM); 1 };
    ok(!$ok, 'AC-2: raw JSON::PP::decode_json on the BOM-prefixed literal DOES die (documents the strip)');
    like($@ || '', qr/malformed JSON string/,
        'AC-2: ... with the pinned "malformed JSON string" diagnostic at character offset 0');
}

# ===========================================================================
# 4. Totality sweep -- AC-1 (B2). Every public function x 12 hostile inputs:
#    never dies, never warns, returns a sane type.
# ===========================================================================
{
    my @HOSTILE = (
        [ 'undef',           undef ],
        [ "''",              '' ],
        [ "'   '",           '   ' ],
        [ "'not json'",      'not json' ],
        [ "'{'",             '{' ],
        [ "'[1,2,3]'",       '[1,2,3]' ],
        [ '\'"str"\'',       '"str"' ],
        [ "'null'",          'null' ],
        [ '[]',              [] ],
        [ '{}',              {} ],
        [ 'sub {}',          sub { } ],
        [ "bless({},'X')",   bless({}, 'X') ],
    );

    # [ label, argument-builder, result validator, validator description ]
    my $undef_only    = [ sub { !defined $_[0] },                                  'undef' ];
    my $undef_or_hash = [ sub { !defined $_[0] || ref($_[0]) eq 'HASH' },          'undef or a hashref' ];
    my $hash_only     = [ sub { ref($_[0]) eq 'HASH' },                            'a hashref' ];
    my $zero_or_one   = [ sub { defined $_[0] && !ref($_[0]) && ($_[0] eq '0' || $_[0] eq '1') }, '0 or 1' ];

    my @SHAPES = (
        [ 'parse_human_bytes($x)',        sub { ('parse_human_bytes', $_[0]) },                $undef_only ],
        [ 'parse_percent($x)',            sub { ('parse_percent', $_[0]) },                    $undef_only ],
        [ 'parse_machine_list($x)',       sub { ('parse_machine_list', $_[0]) },               $undef_or_hash ],
        [ 'parse_stats($x, $ctr)',        sub { ('parse_stats', $_[0], $CTR) },                $undef_or_hash ],
        [ 'parse_stats($fixture, $x)',    sub { ('parse_stats', $FX_STATS, $_[0]) },           $undef_or_hash ],
        [ 'parse_system_df($x)',          sub { ('parse_system_df', $_[0]) },                  $undef_or_hash ],
        [ 'parse_cim_memory($x)',         sub { ('parse_cim_memory', $_[0]) },                 $undef_or_hash ],
        [ 'parse_cim_disk($x, "C:")',     sub { ('parse_cim_disk', $_[0], 'C:') },             $undef_or_hash ],
        [ 'parse_cim_disk($fixture, $x)', sub { ('parse_cim_disk', $FX_CIM_DISK, $_[0]) },     $undef_or_hash ],
        [ 'parse_cim_cpu($x)',            sub { ('parse_cim_cpu', $_[0]) },                    $undef_or_hash ],
        [ 'build($x)',                    sub { ('build', $_[0]) },                            $hash_only ],
        [ 'gather($x, {})',               sub { ('gather', $_[0], {}) },                       $hash_only ],
        [ 'gather({}, $x)',               sub { ('gather', {}, $_[0]) },                       $hash_only ],
        [ 'should_sample($x, 100, 23)',   sub { ('should_sample', $_[0], 100, 23) },           $zero_or_one ],
        [ 'should_sample(100, $x, 23)',   sub { ('should_sample', 100, $_[0], 23) },           $zero_or_one ],
        [ 'should_sample(100, 122, $x)',  sub { ('should_sample', 100, 122, $_[0]) },          $zero_or_one ],
    );

    for my $shape (@SHAPES) {
        my ($label, $mk, $val) = @$shape;
        my ($check, $desc) = @$val;
        my (@died, @warned, @badtype);
        for my $h (@HOSTILE) {
            my ($hl, $hv) = @$h;
            my ($res, $err, $warns) = probe_call($mk->($hv));
            push @died,    "$hl => $err"                    if $err ne '';
            push @warned,  "$hl => call failed ($err)"      if $err ne '';
            push @warned,  "$hl => $warns->[0]"             if @$warns;
            push @badtype, $hl . ($err ne '' ? ' (call failed)' : '')
                unless $err eq '' && $check->($res);
        }
        is(scalar @died,    0, "AC-1: Resources::$label never dies across the 12 hostile inputs (B2)")
            or diag(join("\n", @died));
        is(scalar @warned,  0, "AC-1: Resources::$label completes without warning across the 12 hostile inputs (B2)")
            or diag(join("\n", @warned));
        is(scalar @badtype, 0, "AC-1: Resources::$label always returns $desc across the 12 hostile inputs (B2)")
            or diag('offending inputs: ' . join(', ', @badtype));
    }

    # interval() takes no arguments but must still be total.
    my ($iv, $ierr, $iwarns) = probe_call('interval');
    is($ierr, '', 'AC-1: Resources::interval() does not die');
    ok($ierr eq '' && !@$iwarns, 'AC-1: Resources::interval() completes without warning');
}

# ===========================================================================
# 5. Builder -- AC-12, AC-13 (B9/B10/B11).
# ===========================================================================
my $BUILT;
{
    $BUILT = R('build', {
        machine   => $FX_MACHINE,
        stats     => $FX_STATS,
        df        => $FX_DF,
        cim_mem   => $BOM . $FX_CIM_MEM,
        cim_disk  => $BOM . $FX_CIM_DISK,
        cim_cpu   => $BOM . $FX_CIM_CPU,
        container => $CTR,
        device    => 'C:',
    });

    ok(is_hashref($BUILT), 'AC-12: build(all six fixtures + selectors) returns a hashref (B10)');
    if (is_hashref($BUILT)) {
        is_deeply([ sort keys %$BUILT ], [ sort @KEYS_15 ],
            'AC-12: the returned key set is EXACTLY the 15 closed keys -- an extra key fails (B9)');
    } else {
        fail('AC-12: the returned key set is EXACTLY the 15 closed keys (B9)');
    }
    for my $k (sort @KEYS_15) {
        is(field($BUILT, $k), $B10{$k}, "AC-12: build(...)->{$k} == " . (defined $B10{$k} ? $B10{$k} : 'undef') . ' (B10)');
    }

    for my $c ( [ 'undef', undef ], [ '{}', {} ], [ '[]', [] ], [ "'x'", 'x' ] ) {
        my ($label, $in) = @$c;
        my $b = R('build', $in);
        ok(is_hashref($b), "AC-12: build($label) returns a hashref (B9)");
        if (is_hashref($b)) {
            is_deeply([ sort keys %$b ], [ sort @KEYS_15 ], "AC-12: build($label) still has all 15 keys (B9)");
            is_deeply($b, \%ALL_NA,
                "AC-12: build($label) is the all-n/a struct: machine_state 'unknown', every other value undef (B9)");
        } else {
            fail("AC-12: build($label) still has all 15 keys (B9)");
            fail("AC-12: build($label) is the all-n/a struct (B9)");
        }
    }

    # machine_state derivation (S2.2): running wins over starting.
    is(field(R('build', { machine => $FX_MACHINE_STARTING }), 'machine_state'), 'starting',
        'AC-12: Running false + Starting true -> machine_state "starting"');
    is(field(R('build', { machine => q{[{"Name":"m","Default":true,"Running":true,"Starting":true}]} }), 'machine_state'),
        'running', 'AC-12: Running AND Starting both true -> machine_state "running" (running wins)');
    is(field(R('build', { machine => q{[{"Name":"m","Default":true,"Running":false,"Starting":false}]} }), 'machine_state'),
        'stopped', 'AC-12: neither Running nor Starting -> machine_state "stopped"');
    is(field(R('build', { machine => 'garbage' }), 'machine_state'), 'unknown',
        'AC-12: unparseable machine output -> machine_state "unknown", never undef (B9)');

    # host_ram_used / host_disk_used derivations, including the defensive case.
    my $impossible = R('build', { cim_mem => q{{"FreePhysicalMemory":99999999,"TotalVisibleMemorySize":1}} });
    is(field($impossible, 'host_ram_used'), undef,
        'AC-12: ram_free > ram_total -> host_ram_used undef, never a negative byte count (S5)');
    is(field($impossible, 'host_ram_total'), 1024,
        'AC-12: ... while host_ram_total keeps its converted value');
}

# --- AC-13 -> DC-1 (B11): host and VM are never conflated. ----------------
{
    my $hrt = field($BUILT, 'host_ram_total');
    my $vmt = field($BUILT, 'vm_mem_total');
    my $hru = field($BUILT, 'host_ram_used');
    my $cmu = field($BUILT, 'ctr_mem_used');
    isnt($hrt, $vmt, 'AC-13: host_ram_total and vm_mem_total are distinct values (B11)');

    my $vals = is_hashref($BUILT) ? _deep_values($BUILT) : [];
    my @forbidden;
    if (numeric($hrt) && numeric($vmt)) {
        push @forbidden, [ 'host_ram_total + vm_mem_total', $hrt + $vmt ];
        push @forbidden, [ 'host_ram_total - vm_mem_total', $hrt - $vmt ];
    }
    push @forbidden, [ 'host_ram_used + ctr_mem_used', $hru + $cmu ] if numeric($hru) && numeric($cmu);
    if (@forbidden) {
        for my $f (@forbidden) {
            my ($label, $n) = @$f;
            my $hits = grep { numeric($_) && $_ == $n } @$vals;
            is($hits, 0, "AC-13: no value in the struct equals $label ($n) -- host and VM are never summed (B11)");
        }
    } else {
        fail('AC-13: host/VM conflation sweep (the built struct was not populated)');
    }
}

# ===========================================================================
# 6. Throttle -- AC-23 (B12).
# ===========================================================================
{
    is(R('interval'), 23, 'AC-23: Resources::interval() == 23 -- the single source of truth for the cadence');

    my @vectors = (
        [ '(100, 122, 23)  -- 22s elapsed, below the interval',        [ 100, 122, 23 ],    0 ],
        [ '(100, 123, 23)  -- EXACTLY 23s elapsed, the >= boundary',   [ 100, 123, 23 ],    1 ],
        [ '(100, 124, 23)  -- past the interval',                      [ 100, 124, 23 ],    1 ],
        [ '(100, 50, 23)   -- backwards clock, resample',              [ 100, 50, 23 ],     1 ],
        [ '(undef, 500, 23) -- never sampled, sample now',             [ undef, 500, 23 ],  1 ],
        [ '(100, undef, 23) -- $now unusable, cannot decide',          [ 100, undef, 23 ],  0 ],
        [ "(100, 'x', 23)  -- \$now non-numeric, cannot decide",       [ 100, 'x', 23 ],    0 ],
        [ "('x', 500, 23)  -- \$last_at non-numeric, sample now",      [ 'x', 500, 23 ],    1 ],
        [ '(100, 122, undef) -- interval falls back to interval()',    [ 100, 122, undef ], 0 ],
        [ '(100, 122, 0)   -- interval <= 0 falls back to interval()', [ 100, 122, 0 ],     0 ],
        [ '(100, 122, -5)  -- negative interval falls back',           [ 100, 122, -5 ],    0 ],
        [ "(100, 122, 'x') -- non-numeric interval falls back",        [ 100, 122, 'x' ],   0 ],
    );
    for my $v (@vectors) {
        my ($label, $args, $want) = @$v;
        is(R('should_sample', @$args), $want, "AC-23: should_sample$label == $want (B12)");
    }

    # SPEC CONFLICT: B12 pins should_sample(0,0,23) => 1, but S2.3's binding
    # algorithm yields 0 (both args numeric; 0 is not < 0; 0-0 >= 23 is false).
    # S2.3 is the normative interface contract, so that is what is asserted.
    is(R('should_sample', 0, 0, 23), 0,
        'AC-23: should_sample(0, 0, 23) == 0 per the S2.3 algorithm [SPEC CONFLICT: B12 pins 1; S2.3 is binding]');
    # The substance B12's vector was reaching for: a zero-initialised stamp
    # against a real clock fires on the very first tick (S2.3 "Startup").
    is(R('should_sample', 0, $NOW, 23), 1,
        'AC-23: should_sample(0, <real-clock now>, 23) == 1 -- the zero-initialised stamp fires on the first tick');

    # The boundary again, at an interval other than 23, so the >= is not an
    # artefact of the default.
    is(R('should_sample', 1000, 1010, 10), 1, 'AC-23: exactly $interval elapsed -> 1 (>=, not >), interval 10');
    is(R('should_sample', 1000, 1009, 10), 0, 'AC-23: one second short of $interval -> 0, interval 10');
}

# ===========================================================================
# 7. The seam -- AC-19, AC-20, AC-21, AC-22 (B13..B20).
# ===========================================================================
ok(Resources->can('gather'), 'S2.4: Resources::gather exists (guards the counter-based seam assertions below)');

# --- AC-19 -> DC-3 (B13/B16/B20): nothing injected / junk / unknown keys. --
{
    is_deeply(R('gather', {}, {}), \%ALL_NA, 'AC-19: gather({}, {}) == the all-n/a 15-key struct (B13)');
    is_deeply(R('gather', undef, undef), \%ALL_NA, 'AC-19: gather(undef, undef) == the all-n/a 15-key struct (B13)');
    is_deeply(R('gather', 'x', 'y'), \%ALL_NA, 'AC-19: gather(non-hashref, non-hashref) == the all-n/a struct (B13)');

    my $evil_calls = 0;
    my ($eres, $eerr) = probe_call('gather', { evil => sub { $evil_calls++; die "must never run\n" } }, {});
    ok($eerr eq '' && $evil_calls == 0, 'AC-19: an unrecognized probe key is NEVER invoked (B20)');
    is_deeply($eres, \%ALL_NA, 'AC-19: gather({evil=>sub{die}}, {}) still returns the all-n/a struct (B20)');

    for my $junk ( [ 'undef', undef ], [ "''", '' ], [ '[]', [] ], [ '{}', {} ], [ 'sub {}', sub { } ] ) {
        my ($label, $val) = @$junk;
        my %probes = map { my $v = $val; ( $_ => sub { $v } ) }
                     qw(stats machine cim_mem cim_cpu cim_disk df);
        my ($r, $err, $warns) = probe_call('gather', \%probes, { container => $CTR, device => 'C:' });
        is($err, '', "AC-19: probes all returning $label -- gather does not die (B16)");
        is_deeply($r, \%ALL_NA, "AC-19: probes all returning $label -> the all-n/a struct, never dereferenced (B16)");
    }
}

# --- AC-20 -> DC-3 (B14/B15): a dying probe is not fatal; warns are silent. -
{
    my %probes = (
        stats    => sub { die "boom\n" },
        machine  => sub { $FX_MACHINE },
        cim_mem  => sub { $BOM . $FX_CIM_MEM },
        cim_cpu  => sub { $BOM . $FX_CIM_CPU },
        cim_disk => sub { $BOM . $FX_CIM_DISK },
        df       => sub { $FX_DF },
    );
    my ($res, $err, $warns) = probe_call('gather', \%probes, { container => $CTR, device => 'C:' });
    is($err, '', 'AC-20: a dying probe never propagates out of gather (B14)');
    ok($err eq '' && !@$warns, 'AC-20: a dying probe emits nothing to STDERR (B14)');
    ok(is_hashref($res), 'AC-20: gather returns normally despite the dying probe (B14)');

    for my $k (qw(ctr_mem_used vm_mem_total ctr_cpu_pct)) {
        my $desc = "AC-20: the dying stats probe degrades $k to undef (B14)";
        is_hashref($res) ? is($res->{$k}, undef, $desc) : fail("$desc [gather did not return a hashref]");
    }
    my %expect_populated = (
        machine_state   => 'running',
        machine_name    => 'podman-machine-default',
        pod_images      => 684907310,
        pod_containers  => 4594936026,
        pod_volumes     => 0,
        host_ram_total  => 25542582272,
        host_ram_used   => 21890629632,
        host_cpu_pct    => 16,
        host_cores      => 8,
        host_disk_dev   => 'C:',
        host_disk_total => 254788440064,
        host_disk_used  => 205548142592,
    );
    for my $k (sort keys %expect_populated) {
        is(field($res, $k), $expect_populated{$k},
            "AC-20: $k is fully populated -- the probes AFTER the dying one still ran (B14)");
    }

    # A warning probe: suppressed, value still used.
    my %wprobes = (
        stats   => sub { $FX_STATS },
        machine => sub { warn "noise\n"; return $FX_MACHINE },
    );
    my ($wres, $werr, $wwarns) = probe_call('gather', \%wprobes, { container => $CTR });
    is($werr, '', 'AC-20: a warning probe does not make gather die (B15)');
    ok($werr eq '' && !@$wwarns,
        'AC-20: a warning probe emits NOTHING to STDERR (B15, $SIG{__WARN__} collector)');
    is(field($wres, 'machine_state'), 'running', 'AC-20: the warning probe\'s value is still used (B15)');
    is(field($wres, 'ctr_mem_used'), 18510000, 'AC-20: ... and the other probes are unaffected (B15)');
}

# --- AC-21 -> DC-3 (B17/B18) -- THE FAKE SLOW-PROBE ASSERTION. ------------
# No sleep, no real clock: the injected clock is scripted (1000, 1000, 1010,...)
# so the elapsed budget is blown after the first probe returns.
{
    my @ORDER = qw(stats machine cim_mem cim_cpu cim_disk df);

    my %count = map { $_ => 0 } @ORDER;
    my %probes = map { my $k = $_; ( $k => sub { $count{$k}++; return 'x' } ) } @ORDER;

    my $clock_calls = 0;
    my $clock = sub { $clock_calls++; return $clock_calls <= 2 ? 1000 : 1010; };

    my ($res, $err, $warns) = probe_call('gather', \%probes,
        { container => $CTR, device => 'C:', budget => 4, now => $clock });

    is($err, '', 'AC-21: gather with a budget-tripping injected clock does not die (B17)');
    is($count{stats}, 1, 'AC-21: the FIRST probe (stats) is invoked exactly once -- the budget check precedes invocation (B17)');
    for my $k (qw(machine cim_mem cim_cpu cim_disk df)) {
        ok($err eq '' && $count{$k} == 0,
            "AC-21: probe '$k' is invoked ZERO times once the elapsed budget is blown (B17)");
    }
    ok(is_hashref($res), 'AC-21: gather still returns a struct after the budget cut the round short (B17)');
    if (is_hashref($res)) {
        is_deeply([ sort keys %$res ], [ sort @KEYS_15 ],
            'AC-21: the budget-truncated round still returns the FULL 15-key struct (B17)');
    } else {
        fail('AC-21: the budget-truncated round still returns the FULL 15-key struct (B17)');
    }
    is($count{stats} + $count{machine} + $count{cim_mem} + $count{cim_cpu} + $count{cim_disk} + $count{df}, 1,
        'AC-21: exactly ONE probe ran in total -- one slow probe cannot become six (B17)');

    # B18: no clock => no budget accounting, all six run.
    my %count2 = map { $_ => 0 } @ORDER;
    my %probes2 = map { my $k = $_; ( $k => sub { $count2{$k}++; return 'x' } ) } @ORDER;
    my ($res2, $err2) = probe_call('gather', \%probes2, { container => $CTR, device => 'C:', budget => 4 });
    is($err2, '', 'AC-21: gather with NO injected clock does not die (B18)');
    for my $k (@ORDER) {
        is($count2{$k}, 1, "AC-21: with 'now' absent, probe '$k' is invoked exactly once -- budget accounting disabled (B18)");
    }

    # A "slow" probe with no clock still lets every later probe run (B18).
    my %count3 = map { $_ => 0 } @ORDER;
    my %probes3 = map { my $k = $_; ( $k => sub { $count3{$k}++; return 'x' } ) } @ORDER;
    $probes3{stats} = sub { $count3{stats}++; my $x = 0; $x += $_ for (1 .. 2000); return 'x' };
    probe_call('gather', \%probes3, {});
    is_deeply([ map { $count3{$_} } @ORDER ], [ 1, 1, 1, 1, 1, 1 ],
        'AC-21: with no clock, a slow first probe does not stop the later five (B18)');
}

# --- AC-22 -> DC-3 (B19): invocation order. -------------------------------
{
    my @ORDER = qw(stats machine cim_mem cim_cpu cim_disk df);
    my @seen;
    my %probes = map { my $k = $_; ( $k => sub { push @seen, $k; return 'x' } ) } @ORDER;
    probe_call('gather', \%probes, { container => $CTR, device => 'C:' });
    is_deeply(\@seen, \@ORDER,
        'AC-22: the probes are invoked in exactly the order stats, machine, cim_mem, cim_cpu, cim_disk, df (B19)');

    # A probe not injected is never invoked and leaves its raw undef.
    my @seen2;
    my %partial = ( df => sub { push @seen2, 'df'; return $FX_DF } );
    my $res = R('gather', \%partial, {});
    is_deeply(\@seen2, [ 'df' ], 'AC-22: only the injected probe runs when the others are absent (S2.4)');
    is(field($res, 'pod_images'), 684907310, 'AC-22: ... and its output is still built into the struct');
    is(field($res, 'machine_state'), 'unknown', 'AC-22: ... while the absent probes degrade to n/a');

    # gather({}, {}) is exactly build({}) (S2.4 guarantee).
    my $g0 = R('gather', {}, {});
    my $b0 = R('build', {});
    if (is_hashref($g0) && is_hashref($b0)) {
        is_deeply($g0, $b0, 'AC-22: gather({}, {}) is identical to build({}) (S2.4)');
    } else {
        fail('AC-22: gather({}, {}) is identical to build({}) (S2.4) [one of them did not return a hashref]');
    }

    # The full round with all six real fixture texts equals the B10 struct.
    my %real = (
        stats    => sub { $FX_STATS },
        machine  => sub { $FX_MACHINE },
        cim_mem  => sub { $BOM . $FX_CIM_MEM },
        cim_cpu  => sub { $BOM . $FX_CIM_CPU },
        cim_disk => sub { $BOM . $FX_CIM_DISK },
        df       => sub { $FX_DF },
    );
    is_deeply(R('gather', \%real, { container => $CTR, device => 'C:' }), \%B10,
        'AC-22: a full six-probe round with the fixture texts yields exactly the B10 struct');
}

# ===========================================================================
# 8. Classifier / gauge / formatter -- AC-15..AC-18.
# ===========================================================================

# --- AC-15 -> DC-2: pressure_role, boundaries included. -------------------
{
    my @vectors = (
        [ '(0,100)    ratio 0',                        [ 0, 100 ],     'good' ],
        [ '(74,100)   ratio 0.74',                     [ 74, 100 ],    'good' ],
        [ '(74.9,100) just under the warn boundary',   [ 74.9, 100 ],  'good' ],
        [ '(75,100)   EXACTLY 0.75 -- BOUNDARY',       [ 75, 100 ],    'warn' ],
        [ '(89.9,100) just under the bad boundary',    [ 89.9, 100 ],  'warn' ],
        [ '(90,100)   EXACTLY 0.90 -- BOUNDARY',       [ 90, 100 ],    'bad' ],
        [ '(100,100)  ratio 1',                        [ 100, 100 ],   'bad' ],
        [ '(150,100)  ratio > 1, no clamp',            [ 150, 100 ],   'bad' ],
        [ '(1,0)      total 0',                        [ 1, 0 ],       'muted' ],
        [ '(1,-5)     total negative',                 [ 1, -5 ],      'muted' ],
        [ '(undef,100) used undef',                    [ undef, 100 ], 'muted' ],
        [ '(-1,100)   used negative',                  [ -1, 100 ],    'muted' ],
        [ "('x',100)  used non-numeric",               [ 'x', 100 ],   'muted' ],
        [ "(50,'x')   total non-numeric",              [ 50, 'x' ],    'muted' ],
        [ '([],100)   used a ref',                     [ [], 100 ],    'muted' ],
    );
    for my $v (@vectors) {
        my ($label, $args, $want) = @$v;
        is(D('pressure_role', @$args), $want, "AC-15: pressure_role$label == '$want'");
    }
    my $r75 = D('pressure_role', 75, 100);
    my $r90 = D('pressure_role', 90, 100);
    ok(defined($r75) && !ref($r75) && $r75 ne 'good',
        'AC-15: ratio exactly 0.75 is NOT good (good uses a strict <)');
    ok(defined($r90) && !ref($r90) && $r90 ne 'warn',
        'AC-15: ratio exactly 0.90 is NOT warn (warn uses a strict <)');
}

# --- AC-16 -> DC-2/DC-4: every returned role is styled by sgr_for_role. ---
{
    my %want = ( good => "\e[32m", warn => "\e[33m", bad => "\e[31m", muted => "\e[2m" );
    for my $role (sort keys %want) {
        is(Dashboard::sgr_for_role($role), $want{$role},
            "AC-16: sgr_for_role('$role') == the pinned SGR -- no new role is introduced");
    }
}

# --- AC-17 -> DC-3/DC-4: gauge, byte-exact, always width 10. --------------
{
    my @vectors = (
        [ 'gauge(0,100)',        [ 0, 100 ],        g(0)  ],
        [ 'gauge(100,100)',      [ 100, 100 ],      g(10) ],
        [ 'gauge(50,100)',       [ 50, 100 ],       g(5)  ],
        [ 'gauge(16,100)',       [ 16, 100 ],       g(2)  ],
        [ 'gauge(85.698,100)',   [ 85.698, 100 ],   g(9)  ],
        [ 'gauge(undef,undef)',  [ undef, undef ],  g(0)  ],
        [ 'gauge(1,0)',          [ 1, 0 ],          g(0)  ],
    );
    for my $v (@vectors) {
        my ($label, $args, $want) = @$v;
        my $got = D('gauge', @$args);
        is($got, $want, "AC-17: $label returns the exact UTF-8 byte string (full-block x filled . light-shade x rest)");
        is(Dashboard::display_width(defined $got ? $got : ''), 10, "AC-17: display_width($label) == 10");
    }

    for my $bad ( [ 'undef', undef ], [ '0', 0 ], [ '-1', -1 ], [ "'x'", 'x' ], [ '[]', [] ] ) {
        my ($label, $cells) = @$bad;
        my $got = D('gauge', 50, 100, $cells);
        is(Dashboard::display_width(defined $got ? $got : ''), 10,
            "AC-17: gauge(50,100,$label) falls back to 10 cells (display_width == 10)");
    }

    # $cells is honoured (and truncated to an integer) when usable.
    my $g4 = D('gauge', 100, 100, 4);
    is($g4, $FULL x 4, 'AC-17: gauge(100,100,4) == 4 full blocks');
    is(Dashboard::display_width(defined $g4 ? $g4 : ''), 4, 'AC-17: display_width(gauge(100,100,4)) == 4');
    is(D('gauge', 100, 100, 4.9), $FULL x 4, 'AC-17: $cells is truncated with int() (4.9 -> 4)');

    # Both glyphs are already allow-listed (this package adds none).
    my $table = Dashboard::glyph_table();
    is(ref($table) eq 'HASH' ? $table->{"\x{2588}"} : undef, 1, 'AC-17: U+2588 is already in glyph_table at width 1');
    is(ref($table) eq 'HASH' ? $table->{"\x{2591}"} : undef, 1, 'AC-17: U+2591 is already in glyph_table at width 1');
}

# --- AC-18 -> DC-4: fmt_bytes, the 20 pinned literals. --------------------
{
    my @vectors = (
        [ '0',            0,             '0 B' ],
        [ '999',          999,           '999 B' ],
        [ '1000',         1000,          '1.0 kB' ],
        [ '782300',       782300,        '782.3 kB' ],
        [ '18510000',     18510000,      '18.5 MB' ],
        [ '684907310',    684907310,     '684.9 MB' ],
        [ '6214000000',   6214000000,    '6.2 GB' ],
        [ '6195490000',   6195490000,    '6.2 GB' ],
        [ '4594936026',   4594936026,    '4.6 GB' ],
        [ '25542582272',  25542582272,   '25.5 GB' ],
        [ '21890629632',  21890629632,   '21.9 GB' ],
        [ '3651952640',   3651952640,    '3.7 GB' ],
        [ '254788440064', 254788440064,  '254.8 GB' ],
        [ '205548142592', 205548142592,  '205.5 GB' ],
        [ '49240297472',  49240297472,   '49.2 GB' ],
        [ '1000000000000', 1000000000000, '1.0 TB' ],
        [ 'undef',        undef,         'n/a' ],
        [ '-1',           -1,            'n/a' ],
        [ "'x'",          'x',           'n/a' ],
        [ '[]',           [],            'n/a' ],
    );
    for my $v (@vectors) {
        my ($label, $in, $want) = @$v;
        is(D('fmt_bytes', $in), $want, "AC-18: fmt_bytes($label) eq '$want'");
    }
}

# ===========================================================================
# 9. The panel -- AC-24, AC-25, AC-28.
# ===========================================================================

my %BASE_STATE = (
    project_name => 'demo', container => 'claude-demo-abcd1234', status => 'running',
    beat_age => 12, uptime => 3660, oauth_remaining => 11520,
    busy_age => 30, stay_awake => 1, needs_you => 0,
);
my %TOKENS_FIXTURE = (
    logged_in => 1, access_present => 1, access_state => 'valid',
    access_expires_at => $NOW + 11520, access_seconds_left => 11520,
    refresh_present => 1, refresh_fingerprint => 'abc12345',
    refresh_expires => 'n/a (not stored)',
    last_refreshed_at => $NOW - 3600, last_refreshed_age => 3600,
);
my %BACKPACK_FIXTURE = ( total => 1, approved => 1, items => [ { key => 'apt:jq', approved => 1 } ] );

# ===========================================================================
# 10. Render invariant -- AC-27 (B26).
# ===========================================================================
{
    my %state = (
        %BASE_STATE,
        tokens    => { %TOKENS_FIXTURE },
        backpack  => { %BACKPACK_FIXTURE },
        resources => { %B10 },
        events    => [ 'e0', 'e1', 'e2' ],
    );
    for my $cols (40, 60, 80, 100, 120) {
        my $frame = Dashboard::compose_frame(\%state, 30, $cols);
        is(ref($frame), 'ARRAY', "AC-27: compose_frame(state,30,$cols) returns an arrayref (B26)");
        next unless ref($frame) eq 'ARRAY';
        is(scalar(@$frame), 30, "AC-27: compose_frame(state,30,$cols) returns exactly 30 rows (B26)");
        my $bad_width  = 0;
        my $bad_escape = 0;
        for my $cell (@$frame) {
            my $t = (ref($cell) eq 'HASH' && defined $cell->{text}) ? $cell->{text} : '';
            $bad_width++  if Dashboard::display_width($t) != $cols;
            $bad_escape++ if $t =~ /\e/;
        }
        is($bad_width, 0,
            "AC-27: every row's display_width == $cols (columns, not bytes) with a resources state (B26)");
        is($bad_escape, 0, "AC-27: no row text contains an ANSI escape (\\e) at $cols columns (B26)");
    }

    # The all-n/a struct must be width-safe too (the normal Linux-container case, S5).
    for my $cols (40, 80) {
        my $frame = Dashboard::compose_frame({ %BASE_STATE, resources => { %ALL_NA } }, 30, $cols);
        next unless ref($frame) eq 'ARRAY';
        my $bad = grep { Dashboard::display_width($_->{text}) != $cols } @$frame;
        is($bad, 0, "AC-27: the all-n/a resources state is width-safe at $cols columns (S5)");
    }
}

# ===========================================================================
# 11. Launcher wiring -- source text + `perl -c` ONLY. launcher.pl is NEVER
#     require'd or do'ne (t/36:3's stated convention: it has side effects).
#     AC-29..AC-32.
# ===========================================================================
my $launcher_src = slurp($LAUNCHER_PATH);
ok(length($launcher_src) > 0, 'launcher.pl is readable on disk') or BAIL_OUT("cannot read $LAUNCHER_PATH");

# --- AC-29 -> DC-3 (B29/B31/B32/B33). -------------------------------------
{
    my @required = (
        [ 'use Resources',                    qr/\buse\s+Resources\b/ ],
        [ 'sub _resources_probes',            qr/\bsub\s+_resources_probes\b/ ],
        [ 'sub _powershell_json',             qr/\bsub\s+_powershell_json\b/ ],
        [ 'sub _gather_resources',            qr/\bsub\s+_gather_resources\b/ ],
        [ 'my $cached_resources',             qr/\bmy\s+\$cached_resources\b/ ],
        [ 'my $last_resources',               qr/\bmy\s+\$last_resources\b/ ],
        [ 'resources => $cached_resources',   qr/resources\s*=>\s*\$cached_resources/ ],
    );
    for my $r (@required) {
        my ($label, $qr) = @$r;
        like($launcher_src, $qr, "AC-29: launcher.pl source contains $label (B29/B31)");
    }

    my @probe_substrings = (
        'stats --no-stream --format json',
        'system df --format json',
        'machine list --format json',
        'Win32_OperatingSystem',
        'Win32_Processor',
        'Win32_LogicalDisk',
        '-OperationTimeoutSec 3',
        '-NoProfile',
        '-NonInteractive',
    );
    for my $s (@probe_substrings) {
        like($launcher_src, qr/\Q$s\E/, "AC-29: launcher.pl source contains the probe substring '$s' (B32)");
    }

    my $ps_body = extract_block($launcher_src, 'sub _powershell_json');
    ok(defined $ps_body, 'AC-29: the _powershell_json body is extractable from launcher.pl');
    if (defined $ps_body) {
        like($ps_body, qr{2>/dev/null}, 'AC-29: _powershell_json redirects stderr to 2>/dev/null (B33)');
        unlike($ps_body, qr/NUL/, 'AC-29: _powershell_json never uses the literal NUL (Windows landmine) (B33)');
        like($ps_body, qr/MSYS2_ARG_CONV_EXCL/, 'AC-29: _powershell_json sets MSYS2_ARG_CONV_EXCL locally (S2.7c)');
        like($ps_body, qr/\$WINDOWS_FAMILY/, 'AC-29: _powershell_json is guarded by $WINDOWS_FAMILY (S2.7c)');
    } else {
        fail('AC-29: _powershell_json redirects stderr to 2>/dev/null (B33)');
        fail('AC-29: _powershell_json never uses the literal NUL (B33)');
        fail('AC-29: _powershell_json sets MSYS2_ARG_CONV_EXCL locally (S2.7c)');
        fail('AC-29: _powershell_json is guarded by $WINDOWS_FAMILY (S2.7c)');
    }

    my $probes_body = extract_block($launcher_src, 'sub _resources_probes');
    ok(defined $probes_body, 'AC-29: the _resources_probes body is extractable from launcher.pl');
    if (defined $probes_body) {
        like($probes_body, qr{2>/dev/null}, 'AC-29: _resources_probes redirects stderr to 2>/dev/null (B33)');
        unlike($probes_body, qr/NUL/, 'AC-29: _resources_probes never uses the literal NUL (B33)');
        like($probes_body, qr/\$WINDOWS_FAMILY/,
            'AC-29: _resources_probes gates the machine + cim_* probes on $WINDOWS_FAMILY (S2.7d)');
    } else {
        fail('AC-29: _resources_probes redirects stderr to 2>/dev/null (B33)');
        fail('AC-29: _resources_probes never uses the literal NUL (B33)');
        fail('AC-29: _resources_probes gates on $WINDOWS_FAMILY (S2.7d)');
    }

    my $gr_body = extract_block($launcher_src, 'sub _gather_resources');
    ok(defined $gr_body, 'AC-29: the _gather_resources body is extractable from launcher.pl');
    if (defined $gr_body) {
        # RE-POINTED (spec S7 lines 1475/1476; package 03 driver ruling on E2):
        # _gather_resources is now a PURE READ (spec S2.B) -- it must NOT call
        # Resources::gather and must NOT inject a clock. The two facts these
        # assertions used to pin -- "the probe round is driven through
        # Resources::gather" and "the clock lives in launcher.pl, never in
        # Resources.pm" -- are re-pointed below to _resources_sampler_round, the
        # sub that now owns both. An assertion may change its subject; it may
        # not lose its claim.
        unlike($gr_body, qr/Resources::gather\s*\(/,
            'AC-29 [RE-POINTED]: _gather_resources does NOT call Resources::gather -- it is a pure read (S2.B) (was: asserted it DID)');
        unlike($gr_body, qr/\bnow\s*=>/,
            'AC-29 [RE-POINTED]: _gather_resources injects no now => key -- no clock lives here any more (S2.B) (was: asserted now => sub { time })');
    } else {
        fail('AC-29 [RE-POINTED]: _gather_resources does NOT call Resources::gather');
        fail('AC-29 [RE-POINTED]: _gather_resources injects no now => key');
    }

    # RE-POINTED (spec S7 lines 1475/1476): the probe round + the injected clock
    # now live in _resources_sampler_round (spec S2.F), not _gather_resources.
    my $round_body_29 = extract_block($launcher_src, 'sub _resources_sampler_round');
    ok(defined $round_body_29,
        'AC-29 [RE-POINTED]: the _resources_sampler_round body is extractable from launcher.pl');
    if (defined $round_body_29) {
        like($round_body_29, qr/Resources::gather\s*\(/,
            'AC-29 [RE-POINTED]: _resources_sampler_round calls Resources::gather -- the probe round is driven through it (property was pinned on _gather_resources)');
        like($round_body_29, qr/\btime\b/,
            'AC-29 [RE-POINTED]: _resources_sampler_round injects the clock via time -- it lives HERE, not in Resources.pm (property was pinned on _gather_resources)');
    } else {
        fail('AC-29 [RE-POINTED]: _resources_sampler_round calls Resources::gather');
        fail('AC-29 [RE-POINTED]: _resources_sampler_round injects the clock via time');
    }

    # RE-POINTED (spec S7 line 1478): the container name is now passed
    # explicitly to _resources_sampler_start (spec S2.G), never guessed
    # positionally, and never via _gather_resources/Resources::gather at all.
    my $enter_dashboard_body = extract_block($launcher_src, 'sub enter_dashboard');
    ok(defined $enter_dashboard_body,
        'AC-29 [RE-POINTED]: the enter_dashboard body is extractable from launcher.pl');
    if (defined $enter_dashboard_body) {
        like($enter_dashboard_body,
            qr/_resources_sampler_start\s*\([^)]*\$CONTAINER_NAME[^)]*\)/,
            'AC-29 [RE-POINTED]: enter_dashboard passes $CONTAINER_NAME to _resources_sampler_start(...) -- the container name is passed explicitly, never guessed positionally (property was pinned on _gather_resources)');
    } else {
        fail('AC-29 [RE-POINTED]: enter_dashboard passes $CONTAINER_NAME to _resources_sampler_start(...)');
    }
}

# --- AC-30 -> DC-3 (B30): the two cadences are independent. ---------------
{
    my $inspect_body = extract_block_re($launcher_src,
        qr/if\s*\(\s*\$now\s*-\s*\$last_inspect\s*>=\s*(?:\d+|\$[A-Za-z_]\w*)\s*\)/);
    ok(defined $inspect_body, 'AC-30: the 10s inspect guard block is extractable from launcher.pl');
    if (defined $inspect_body) {
        unlike($inspect_body, qr/_gather_resources/,
            'AC-30: the 10s inspect block does NOT contain _gather_resources -- the cadences are independent (B30)');
        unlike($inspect_body, qr/should_sample/,
            'AC-30: the 10s inspect block does NOT contain should_sample (B30)');
    } else {
        fail('AC-30: the 10s inspect block does not contain _gather_resources (B30)');
        fail('AC-30: the 10s inspect block does not contain should_sample (B30)');
    }

    my $gather_block = extract_block($launcher_src, 'gather    => sub {');
    ok(defined $gather_block, 'AC-30: the gather => sub {...} closure is extractable from launcher.pl')
        or diag('cannot locate the "gather    => sub {" literal -- has formatting changed?');
    if (defined $gather_block) {
        like($gather_block, qr/Resources::should_sample\s*\(/,
            'AC-30: the gather closure calls Resources::should_sample (B30)');
        # RE-POINTED (spec S7 line 1508; package 03 driver ruling on E2): the
        # render tick now reads on Resources::read_interval() (5s); interval()
        # (23s) is now the SAMPLER's own probe cadence exclusively (spec S2.A).
        # The property "the cadence is never re-hardcoded at a call site"
        # re-points to read_interval() here, and gets a NEW pin on interval()
        # at the sampler loop below.
        like($gather_block, qr/Resources::read_interval\s*\(\s*\)/,
            'AC-30 [RE-POINTED]: the gather closure passes Resources::read_interval() -- the READ cadence is never re-hardcoded (was pinned on Resources::interval())');
        unlike($gather_block, qr/Resources::interval\s*\(\s*\)/,
            'AC-30 [RE-POINTED]: the gather closure does NOT call Resources::interval() -- that is now the sampler-only cadence, not the read cadence');
        like($gather_block, qr/_gather_resources\s*\(\s*\)/,
            'AC-30: the gather closure calls _gather_resources() (B30)');
        my $n = () = $gather_block =~ /_gather_resources\s*\(/g;
        is($n, 1, 'AC-30: _gather_resources() appears exactly once as a call site in the gather closure (B30)');
        unlike($gather_block, qr/>=\s*23\b/,
            'AC-30: the gather closure does not hardcode 23 -- interval() is the sampler-only source of truth (S2.3)');
        unlike($gather_block, qr/>=\s*5\b/,
            'AC-30 [NEW, spec S7]: the gather closure does not hardcode 5 either -- read_interval() is the single source of truth for the READ cadence');
    } else {
        fail('AC-30: the gather closure calls Resources::should_sample (B30)');
        fail('AC-30 [RE-POINTED]: the gather closure passes Resources::read_interval()');
        fail('AC-30 [RE-POINTED]: the gather closure does NOT call Resources::interval()');
        fail('AC-30: the gather closure calls _gather_resources() (B30)');
        fail('AC-30: _gather_resources() appears exactly once in the gather closure (B30)');
        fail('AC-30: the gather closure does not hardcode 23 (S2.3)');
        fail('AC-30 [NEW, spec S7]: the gather closure does not hardcode 5 either');
    }

    # RE-POINTED (spec S7 line 1508, NEW subject): _resources_sampler_main's
    # own loop calls Resources::interval() -- the sampler's cadence is never
    # re-hardcoded either, now that it has moved off the render tick entirely.
    my $main_body_30 = extract_block($launcher_src, 'sub _resources_sampler_main');
    ok(defined $main_body_30,
        'AC-30 [RE-POINTED, NEW]: the _resources_sampler_main body is extractable from launcher.pl');
    if (defined $main_body_30) {
        like($main_body_30, qr/Resources::interval\s*\(\s*\)/,
            'AC-30 [RE-POINTED, NEW]: _resources_sampler_main calls Resources::interval() -- the probe cadence is never re-hardcoded (property was pinned on the gather closure)');
    } else {
        fail('AC-30 [RE-POINTED, NEW]: _resources_sampler_main calls Resources::interval()');
    }
}

# --- AC-31 -> DC-3/DC-4 (B34): non-regression. ----------------------------
{
    for my $needle ('_gather_backpack', '_gather_oauth_expiry', '_gather_tokens') {
        like($launcher_src, qr/\bsub\s+\Q$needle\E\b/, "AC-31: launcher.pl still defines sub $needle (B34)");
    }
    like($launcher_src, qr/oauth_expires_at\s*=>/, 'AC-31: launcher.pl gather return hash still has oauth_expires_at => (B34)');
    like($launcher_src, qr/backpack\s*=>/,         'AC-31: launcher.pl gather return hash still has backpack => (B34)');
    like($launcher_src, qr/tokens\s*=>/,           'AC-31: launcher.pl gather return hash still has tokens => (B34)');

    my $dash = slurp($DASHBOARD_PATH);
    # AC-31's three Dashboard.pm non-regression scans removed 2026-08-25:
    # they asserted that sub _token_lines, the 'Token' panel push, and sub
    # _backpack_lines were STILL PRESENT. All three were deleted as
    # unreachable legacy -- the Token panel was replaced by Providers, whose
    # oracle is t/79. An assertion that dead code still exists is the one
    # kind that cannot survive deleting it. The launcher.pl scans above are
    # untouched: that code is live.
}

# --- AC-32 -> DC-4 (B35): perl -c from an unrelated CWD. ------------------
{
    my $isolated_cwd = tempdir(CLEANUP => 1);

    my $cmd = sprintf('cd %s && "%s" -c "%s" 2>&1', $isolated_cwd, $^X, $LAUNCHER_PATH);
    my $out = `$cmd`;
    is($? >> 8, 0,
        'AC-32: perl -c launcher.pl exits 0 from an unrelated CWD (Resources.pm resolves via the @INC bootstrap)')
        or diag("output: $out");

    for my $mod ( [ 'Resources.pm', $RESOURCES_PATH ], [ 'Dashboard.pm', $DASHBOARD_PATH ] ) {
        my ($label, $path) = @$mod;
        my $c = sprintf('cd %s && "%s" -I"%s" -c "%s" 2>&1', $isolated_cwd, $^X, $SCRIPTS_DIR, $path);
        my $o = `$c`;
        is($? >> 8, 0, "AC-32: perl -c $label exits 0 from an unrelated CWD")
            or diag("output: $o");
    }
}

# ===========================================================================
# 12. Package 03-resources-reader-model additions.
#
# The cross-boundary no-spawn proof (AC-1..AC-6), the sampler (AC-7..AC-11),
# snapshot & atomicity (AC-12..AC-17), four-state distinguishability
# (AC-18..AC-20), probe starvation (AC-21..AC-22), and purity (AC-23..AC-24).
# All against specs/03-resources-reader-model-spec.md.
#
# THE ONE STRUCTURAL FACT THIS SECTION EXISTS TO NAIL DOWN (spec S1.3):
# t/62-tui-adapter-contract.t's call-closure walker is SAME-FILE ONLY, by
# documented design. Deleting its %WAIVED entry for _gather_resources
# therefore proves *necessary but not sufficient* -- moving the podman/
# PowerShell probes behind Resources:: would silence t/62 while the fork
# stayed on the render tick. The walker below is that SAME detector's shape
# (_cw_blank/_cw_subs/_cw_get_body/_cw_edges/_cw_spawns mirror t/62's
# _blank_noncode/_subs/_get_body/_edges_from/_spawns construct-for-construct
# -- spec AC-3's own instruction to reuse the proven shape), EXTENDED with
# one new edge kind: a qualified "$qualifier::<name>(" call resolves into a
# SECOND file's own sub table and recurses through THAT file's same-file
# calls. AC-5 is the mandatory negative control proving this extension can
# actually detect a violation -- without it an empty cross-file closure
# would pass AC-3 silently, exactly the failure mode package 02 shipped
# three times over (spec AC-5's own text).
#
# AC-11 (DC-6, "launcher.pl still compiles / Resources.pm compiles and loads
# cleanly") is judged already covered, verbatim, by the pre-existing AC-32
# block just above -- same two files, same `perl -c` subprocess convention.
# Not duplicated here.
#
# AC-25 (t/62 passes with %WAIVED empty) and AC-26 (whole-suite-green judged
# against the pre-change baseline) are coordinator-level checks, exactly as
# this file's own header treats its AC-33 -- verified by running t/62 and
# the sandbox suite directly, not encoded as an assertion in this file.
# ===========================================================================

my $resources_src = slurp($RESOURCES_PATH);
ok(length($resources_src) > 0, 'package 03: Resources.pm is readable on disk')
    or BAIL_OUT("cannot read $RESOURCES_PATH");

# extract_sub($src, $name) -> the brace-balanced body of `sub $name { ... }`,
# via extract_block_re so a name that is a SUBSTRING of another sub's name
# (e.g. 'build' inside a hypothetical 'build_something') can never collide.
sub extract_sub {
    my ($src, $name) = @_;
    return extract_block_re($src, qr/\bsub\s+\Q$name\E\s*\{/);
}

# ---------------------------------------------------------------------------
# The cross-file closure walker. Ported from t/62-tui-adapter-contract.t's
# analyser (spec AC-3's instruction: "package 01's t/62 has a proven
# detector; reuse its shape rather than inventing a weaker one").
# ---------------------------------------------------------------------------

# _cw_blank($src) -> $src2, comments/POD/heredoc bodies blanked, SAME line
# count as the input.
sub _cw_blank {
    my ($src) = @_;
    my @lines = split /\n/, $src, -1;

    # heredocs first -- a heredoc body is DATA, never Perl.
    {
        my $tag;
        my $indented = 0;
        for my $l (@lines) {
            if (defined $tag) {
                my $is_term = $indented ? ($l =~ /^\s*\Q$tag\E\s*$/) : ($l =~ /^\Q$tag\E\s*$/);
                $l = '';
                $tag = undef if $is_term;
                next;
            }
            next if $l =~ /^\s*#/;
            if ($l =~ /<<(~?)\s*(?:(['"])([A-Za-z_]\w*)\2|([A-Za-z_]\w*))/) {
                $indented = ($1 eq '~') ? 1 : 0;
                $tag      = defined($3) ? $3 : $4;
            }
        }
    }

    # POD.
    my $in_pod = 0;
    for my $l (@lines) {
        if (!$in_pod && $l =~ /^=[a-zA-Z]/) { $in_pod = 1; $l = ''; next; }
        if ($in_pod) {
            my $was_cut = ($l =~ /^=cut\b/);
            $l = '';
            $in_pod = 0 if $was_cut;
            next;
        }
    }

    # comments.
    for my $l (@lines) {
        if ($l =~ /^(\s*)#/) { $l = $1; next; }
        my $len = length($l);
        my ($in_sq, $in_dq, $in_bt) = (0, 0, 0);
        my $cut_at;
        for (my $i = 0; $i < $len; $i++) {
            my $c    = substr($l, $i, 1);
            my $prev = $i > 0 ? substr($l, $i - 1, 1) : '';
            next if $prev eq '\\';
            if ($c eq "'" && !$in_dq && !$in_bt) { $in_sq = !$in_sq; next; }
            if ($c eq '"' && !$in_sq && !$in_bt) { $in_dq = !$in_dq; next; }
            if ($c eq '`' && !$in_sq && !$in_dq) { $in_bt = !$in_bt; next; }
            if ($c eq '#' && !$in_sq && !$in_dq && !$in_bt) {
                my $preceding = $i > 0 ? substr($l, $i - 1, 1) : '';
                next if $preceding eq '$';
                if ($i == 0 || $preceding =~ /\s/) { $cut_at = $i; last; }
            }
        }
        $l = substr($l, 0, $cut_at) if defined $cut_at;
    }

    return join("\n", @lines);
}

# _cw_subs($blanked) -> \%subs { name => { start_line, start_pos } }.
sub _cw_subs {
    my ($blanked) = @_;
    my %subs;
    while ($blanked =~ /^sub\s+([A-Za-z_]\w*)\s*\{/mg) {
        my $name       = $1;
        my $start_pos  = $-[0];
        my $before     = substr($blanked, 0, $start_pos);
        my $start_line = 1 + (() = $before =~ /\n/g);
        $subs{$name} = { start_line => $start_line, start_pos => $start_pos };
    }
    return \%subs;
}

# _cw_get_body($name, $subs, $blanked, $cache, $failed) -> validated body
# text, brace-matched (last line a bare '}' at column 0, or a genuine
# one-line body). A failed extraction is reported once per sub name.
sub _cw_get_body {
    my ($name, $subs, $blanked, $cache, $failed) = @_;
    return $cache->{$name} if exists $cache->{$name};
    my $info = $subs->{$name};
    return undef unless $info;

    my $body = _balanced($blanked, $info->{start_pos});
    my $ok = 1;
    if (!defined $body) {
        $ok = 0;
    } else {
        my @lines = split /\n/, $body;
        if (!@lines
            || ($lines[-1] !~ /^\}\s*$/ && !(@lines == 1 && $lines[0] =~ /\}\s*$/))) {
            $ok = 0;
        } else {
            for my $i (1 .. $#lines) {
                if ($lines[$i] =~ /^sub\s+\w+/) { $ok = 0; last; }
            }
        }
    }
    if (!$ok) {
        fail("package 03 closure walker: body extraction failed for sub '$name'")
            unless $failed->{$name}++;
        $cache->{$name} = undef;
        return undef;
    }
    $cache->{$name} = $body;
    return $body;
}

# _cw_edges($body, $names) -> @callee_names, same-file unqualified calls only.
sub _cw_edges {
    my ($body, $names) = @_;
    my @callees;
    for my $v (@$names) {
        if ($body =~ /(?<![\w:>\$\@%&])\Q$v\E\s*\(/ || $body =~ /\\?&\s*\Q$v\E\b/) {
            push @callees, $v;
        }
    }
    return @callees;
}

# _cw_qualified_edges($body, $qualifier) -> @callee_names for
# "$qualifier::<name>(" calls -- the edge kind t/62 explicitly declines to
# follow (spec S1.3), and the whole point of this file's own walker.
sub _cw_qualified_edges {
    my ($body, $qualifier) = @_;
    my @callees;
    while ($body =~ /\Q$qualifier\E::([A-Za-z_]\w*)\s*\(/g) {
        push @callees, $1;
    }
    return @callees;
}

# _cw_spawns($body, $start_line) -> @findings, each { construct, line, snippet }.
# Ported from t/62's _spawns -- the full construct set (backticks, qx,
# system, exec, fork, readpipe, CORE::-qualified forms, open2/open3, piped
# open including the conservative variable-mode flag), plus 'sleep' (AC-1's
# own forbidden list explicitly includes it).
sub _cw_spawns {
    my ($body, $start_line) = @_;
    my @findings;
    my $line_of = sub {
        my ($pos)  = @_;
        my $before = substr($body, 0, $pos);
        my $nl     = () = $before =~ /\n/g;
        return $start_line + $nl;
    };
    my $snippet_at = sub {
        my ($pos) = @_;
        my $ls = rindex($body, "\n", $pos);
        $ls = $ls < 0 ? 0 : $ls + 1;
        my $le = index($body, "\n", $pos);
        $le = length($body) if $le < 0;
        my $s = substr($body, $ls, $le - $ls);
        $s =~ s/^\s+|\s+$//g;
        return $s;
    };

    while ($body =~ /`/g) {
        my $pos = $-[0];
        push @findings, { construct => 'backticks', line => $line_of->($pos), snippet => $snippet_at->($pos) };
    }
    while ($body =~ /(?<![\w:>\$\@%])qx\s*[\(\{\[<\/\|!#'"]/g) {
        my $pos = $-[0];
        push @findings, { construct => 'qx', line => $line_of->($pos), snippet => $snippet_at->($pos) };
    }
    while ($body =~ /(?<![\w:>\$\@%&-])system\s*(?:\(|['"\$\@])/g) {
        my $pos = $-[0];
        push @findings, { construct => 'system', line => $line_of->($pos), snippet => $snippet_at->($pos) };
    }
    while ($body =~ /(?<![\w:>\$\@%&-])exec\s*(?:\(|['"\$\@])/g) {
        my $pos = $-[0];
        push @findings, { construct => 'exec', line => $line_of->($pos), snippet => $snippet_at->($pos) };
    }
    while ($body =~ /(?<![\w:>\$\@%&-])fork\s*(?:\(|;|\)|,|$)/mg) {
        my $pos = $-[0];
        push @findings, { construct => 'fork', line => $line_of->($pos), snippet => $snippet_at->($pos) };
    }
    while ($body =~ /(?<![\w:>\$\@%&-])readpipe\b/g) {
        my $pos = $-[0];
        push @findings, { construct => 'readpipe', line => $line_of->($pos), snippet => $snippet_at->($pos) };
    }
    while ($body =~ /\bCORE::(system|exec|fork|readpipe)\b/g) {
        my $pos = $-[0];
        push @findings, { construct => $1, line => $line_of->($pos), snippet => $snippet_at->($pos) };
    }
    while ($body =~ /(?<![\w:>\$\@%&-])open[23]\s*\(/g) {
        my $pos = $-[0];
        push @findings, { construct => 'open2/open3', line => $line_of->($pos), snippet => $snippet_at->($pos) };
    }
    while ($body =~ /IPC::Open[23]/g) {
        my $pos = $-[0];
        push @findings, { construct => 'open2/open3', line => $line_of->($pos), snippet => $snippet_at->($pos) };
    }
    while ($body =~ /(?<![\w:>\$\@%&-])sleep\s*(?:\(|;|\)|,|$)/mg) {
        my $pos = $-[0];
        push @findings, { construct => 'sleep', line => $line_of->($pos), snippet => $snippet_at->($pos) };
    }
    while ($body =~ /(?<![\w:>\$\@%&-])open\b/g) {
        my $mpos   = $-[0];
        my $limit  = $mpos + 300;
        my $semi   = index($body, ';', $mpos);
        my $winend = ($semi >= 0 && $semi < $limit) ? $semi : $limit;
        $winend = length($body) if $winend > length($body);
        my $window = substr($body, $mpos, $winend - $mpos);
        my $arg2;
        if ($window =~ /\bopen\b[^,;]*,\s*(['"])([^'"]*)\1/) {
            $arg2 = $2;
        } elsif ($window =~ /\bopen\b[^,;]*,\s*qq?\{([^}]*)\}/) {
            $arg2 = $1;
        }
        if (defined $arg2) {
            if ($arg2 =~ /^\s*-?\|/ || $arg2 =~ /^\s*\|-/ || $arg2 =~ /\|\s*$/) {
                push @findings, { construct => 'piped open', line => $line_of->($mpos), snippet => $snippet_at->($mpos) };
            }
        } elsif ($window =~ /\bopen\b[^,;]*,\s*(\$\w+)\b/) {
            push @findings, {
                construct => 'piped open (variable mode, flagged conservatively)',
                line      => $line_of->($mpos),
                snippet   => $snippet_at->($mpos),
            };
        }
    }

    my %seen_finding;
    return grep { my $k = "$_->{construct}|$_->{line}"; !$seen_finding{$k}++; } @findings;
}

# _cw_cross_closure($root, $lsubs,$lblanked,$lnames, $msubs,$mblanked,$mnames,
#                    $qualifier) -> @members, each { side => 'L'|'M', name }.
# Starts at $root in the launcher-side ("L") file, follows same-file L calls
# and qualified "$qualifier::<name>(" calls resolved into the module-side
# ("M") file, then recurses through M's own same-file calls. Cycle-safe via
# a %seen{side:name} guard (spec AC-3).
sub _cw_cross_closure {
    my ($root, $lsubs, $lblanked, $lnames, $msubs, $mblanked, $mnames, $qualifier) = @_;
    my %seen;
    my @queue = ( { side => 'L', name => $root } );
    my @order;
    my (%cache_l, %failed_l, %cache_m, %failed_m);
    while (@queue) {
        my $node = shift @queue;
        my $key  = "$node->{side}:$node->{name}";
        next if $seen{$key}++;
        push @order, $node;

        my ($subs, $blanked, $names, $cache, $failed) = $node->{side} eq 'L'
            ? ($lsubs, $lblanked, $lnames, \%cache_l, \%failed_l)
            : ($msubs, $mblanked, $mnames, \%cache_m, \%failed_m);
        my $body = _cw_get_body($node->{name}, $subs, $blanked, $cache, $failed);
        next unless defined $body;

        if ($node->{side} eq 'L') {
            for my $v (_cw_edges($body, $lnames)) {
                push @queue, { side => 'L', name => $v } unless $seen{"L:$v"};
            }
            for my $v (_cw_qualified_edges($body, $qualifier)) {
                push @queue, { side => 'M', name => $v } unless $seen{"M:$v"};
            }
        } else {
            for my $v (_cw_edges($body, $mnames)) {
                push @queue, { side => 'M', name => $v } unless $seen{"M:$v"};
            }
        }
    }
    return @order;
}

# _cw_body_of($node, $lsubs,$lblanked, $msubs,$mblanked) -> body text for a
# {side,name} node (one-shot, uncached -- call sites here scan each member
# exactly once).
sub _cw_body_of {
    my ($node, $lsubs, $lblanked, $msubs, $mblanked) = @_;
    my ($subs, $blanked) = $node->{side} eq 'L' ? ($lsubs, $lblanked) : ($msubs, $mblanked);
    my $info = $subs->{ $node->{name} };
    return undef unless $info;
    return _balanced($blanked, $info->{start_pos});
}

my $LBLANKED = _cw_blank($launcher_src);
my $LSUBS    = _cw_subs($LBLANKED);
my @LNAMES   = sort keys %$LSUBS;

my $MBLANKED = _cw_blank($resources_src);
my $MSUBS    = _cw_subs($MBLANKED);
my @MNAMES   = sort keys %$MSUBS;

# --- AC-1 -> DC-1: _gather_resources' own body carries no spawn construct. -
# Scanned BLANKED (via _cw_blank, defined above) so a prose comment mentioning
# a backtick/fork/etc (e.g. markdown-style `4` in a doc comment) cannot
# false-positive -- exactly the hazard t/62's own _spawns is written against.
{
    my $gr_body_raw = extract_sub($launcher_src, '_gather_resources');
    my $gr_body = defined($gr_body_raw) ? _cw_blank($gr_body_raw) : undef;
    ok(defined $gr_body, 'AC-1: the _gather_resources body is extractable from launcher.pl');
    my @forbidden = (
        [ 'a backtick character', qr/`/ ],
        [ 'qx',                   qr/\bqx\b/ ],
        [ 'readpipe',             qr/\breadpipe\b/ ],
        [ 'system(',              qr/\bsystem\s*\(/ ],
        [ 'exec(',                qr/\bexec\s*\(/ ],
        [ 'fork',                 qr/\bfork\b/ ],
        [ 'open2(',               qr/\bopen2\s*\(/ ],
        [ 'open3(',               qr/\bopen3\s*\(/ ],
        [ 'IPC::Open2',           qr/IPC::Open2/ ],
        [ 'IPC::Open3',           qr/IPC::Open3/ ],
        [ 'sleep',                qr/\bsleep\b/ ],
    );
    for my $f (@forbidden) {
        my ($label, $qr) = @$f;
        my $desc = "AC-1: _gather_resources body contains no $label";
        defined($gr_body) ? unlike($gr_body, $qr, $desc) : fail("$desc [_gather_resources not extractable]");
    }
    my $desc_pipe = 'AC-1: _gather_resources body contains no piped open (-|, |-)';
    if (defined $gr_body) {
        unlike($gr_body, qr/open\s*\([^)]*['"]-\|['"]/, $desc_pipe);
        unlike($gr_body, qr/open\s*\([^)]*['"]\|-['"]/, $desc_pipe);
    } else {
        fail($desc_pipe);
    }
}

# --- AC-2 -> DC-1: _gather_resources' body names none of the spawn-side subs. --
# Also scanned BLANKED, for the same reason as AC-1.
{
    my $gr_body_raw = extract_sub($launcher_src, '_gather_resources');
    my $gr_body = defined($gr_body_raw) ? _cw_blank($gr_body_raw) : undef;
    my @forbidden_ids = qw(
        _resources_probes _powershell_json _ps_commands Resources::gather
        _resources_sampler_start _resources_sampler_round _resources_sampler_main
    );
    for my $id (@forbidden_ids) {
        my $desc = "AC-2: _gather_resources body does not call/name $id";
        defined($gr_body) ? unlike($gr_body, qr/\Q$id\E/, $desc) : fail("$desc [_gather_resources not extractable]");
    }
}

# --- AC-3 (load-bearing) -> DC-1/DC-2: the cross-boundary closure. --------
my @CLOSURE_AC3;
{
    @CLOSURE_AC3 = _cw_cross_closure('_gather_resources', $LSUBS, $LBLANKED, \@LNAMES,
                                      $MSUBS, $MBLANKED, \@MNAMES, 'Resources');
    my @all_findings;
    for my $node (@CLOSURE_AC3) {
        my $body = _cw_body_of($node, $LSUBS, $LBLANKED, $MSUBS, $MBLANKED);
        next unless defined $body;
        my $start_line = $node->{side} eq 'L' ? $LSUBS->{ $node->{name} }{start_line} : $MSUBS->{ $node->{name} }{start_line};
        for my $f (_cw_spawns($body, $start_line)) {
            $f->{defining_sub} = $node->{name};
            $f->{side}         = $node->{side} eq 'L' ? 'launcher.pl' : 'Resources.pm';
            push @all_findings, $f;
        }
    }
    is(scalar(@all_findings), 0,
        'AC-3 (load-bearing): the transitive call closure of _gather_resources across the module boundary (launcher.pl -> Resources.pm) has ZERO forbidden-spawn findings -- this is precisely the assertion t/62 documents itself as declining to make')
        or diag(join("\n", map {
            sprintf('  %s reached via %s (%s) at reported-line %d: %s',
                $_->{construct}, $_->{defining_sub}, $_->{side}, $_->{line}, $_->{snippet})
        } @all_findings));
}

# --- AC-4 -> DC-1/DC-2: the AC-3 closure is non-vacuous. ------------------
{
    my @module_side = grep { $_->{side} eq 'M' } @CLOSURE_AC3;
    ok(scalar(@module_side) >= 1,
        'AC-4: the AC-3 closure contains at least one member defined in Resources.pm -- the walk really crossed the module boundary');

    my @closure_names = map { $_->{name} } @CLOSURE_AC3;
    for my $fm (qw(_resources_probes _powershell_json _ps_commands)) {
        ok(!(grep { $_ eq $fm } @closure_names), "AC-4: the AC-3 closure does not contain $fm");
    }
    my @sampler_named = grep { /^_resources_sampler_/ } @closure_names;
    is(scalar(@sampler_named), 0,
        'AC-4: the AC-3 closure contains no _resources_sampler_* sub -- the reader never reaches the sampler machinery')
        or diag('found: ' . join(', ', @sampler_named));
}

# --- AC-5 (NEGATIVE CONTROL, mandatory) -> DC-2. --------------------------
# Without this, an empty cross-file closure (a walker bug) would pass AC-3
# silently. Package 02 shipped three green-but-leaking scrubs for exactly
# this reason -- a detector that is never SHOWN to detect proves nothing.
{
    my $fake_launcher = <<'FAKE_LAUNCHER';
sub _gather_x {
    return Fake::probe(1);
}
FAKE_LAUNCHER
    my $fake_module = <<'FAKE_MODULE';
package Fake;
sub probe {
    my $x = `echo hi`;
    return $x;
}
1;
FAKE_MODULE

    my $flblanked = _cw_blank($fake_launcher);
    my $flsubs    = _cw_subs($flblanked);
    my @flnames   = sort keys %$flsubs;

    my $fmblanked = _cw_blank($fake_module);
    my $fmsubs    = _cw_subs($fmblanked);
    my @fmnames   = sort keys %$fmsubs;

    ok(exists $flsubs->{_gather_x}, 'AC-5 setup: the fixture launcher text discovers sub _gather_x');
    ok(exists $fmsubs->{probe},     'AC-5 setup: the fixture module text discovers sub probe');

    my @closure = _cw_cross_closure('_gather_x', $flsubs, $flblanked, \@flnames,
                                     $fmsubs, $fmblanked, \@fmnames, 'Fake');
    my @findings;
    for my $node (@closure) {
        my $body = _cw_body_of($node, $flsubs, $flblanked, $fmsubs, $fmblanked);
        next unless defined $body;
        my $start_line = $node->{side} eq 'L' ? $flsubs->{ $node->{name} }{start_line} : $fmsubs->{ $node->{name} }{start_line};
        for my $f (_cw_spawns($body, $start_line)) {
            $f->{defining_sub} = $node->{name};
            push @findings, $f;
        }
    }
    is(scalar(@findings), 1,
        'AC-5 (NEGATIVE CONTROL): the walker run over a synthetic fixture whose module-side sub carries a backtick reports EXACTLY ONE finding -- proves the walker can actually detect a cross-file violation')
        or diag('found ' . scalar(@findings) . ' findings: ' . join(', ', map { "$_->{construct}\@$_->{defining_sub}" } @findings));
    is(($findings[0] || {})->{defining_sub}, 'probe',
        'AC-5 (NEGATIVE CONTROL): the one finding names probe -- the module-side sub, correctly resolved across the boundary');
}

# --- AC-6 -> DC-1: Resources::gather( / _resources_probes( call sites. ---
# Counted against $LBLANKED (comments/heredocs/POD already blanked) -- a doc
# comment such as "# _resources_probes() -> { key => coderef }, ..." (a real
# line in launcher.pl today, at the sub's own header) would otherwise inflate
# the raw-text count and make this AC permanently unsatisfiable.
{
    my $n_gather = () = $LBLANKED =~ /Resources::gather\s*\(/g;
    is($n_gather, 1, 'AC-6: Resources::gather( occurs in launcher.pl exactly once (comments excluded)');

    my $round_body_raw = extract_sub($launcher_src, '_resources_sampler_round');
    my $round_body = defined($round_body_raw) ? _cw_blank($round_body_raw) : undef;
    ok(defined $round_body, 'AC-6: sub _resources_sampler_round body is extractable from launcher.pl');
    if (defined $round_body) {
        my $n_in_round = () = $round_body =~ /Resources::gather\s*\(/g;
        is($n_in_round, 1, 'AC-6: the sole Resources::gather( call site lies inside _resources_sampler_round');
    } else {
        fail('AC-6: the sole Resources::gather( call site lies inside _resources_sampler_round');
    }

    my $n_probes_calls = () = $LBLANKED =~ /_resources_probes\s*\(/g;
    is($n_probes_calls, 1, 'AC-6: _resources_probes( occurs exactly once outside its own definition (comments excluded)');
    if (defined $round_body) {
        my $n_probes_in_round = () = $round_body =~ /_resources_probes\s*\(/g;
        is($n_probes_in_round, 1, 'AC-6: the sole _resources_probes( call site lies inside _resources_sampler_round');
    } else {
        fail('AC-6: the sole _resources_probes( call site lies inside _resources_sampler_round');
    }
}

# --- AC-7 -> DC-1: _resources_sampler_start -- degrade once, never retry. -
{
    my $body = extract_sub($launcher_src, '_resources_sampler_start');
    ok(defined $body, 'AC-7: the _resources_sampler_start body is extractable from launcher.pl');
    if (defined $body) {
        like($body, qr/\bfork\s*\(\s*\)/, 'AC-7: _resources_sampler_start calls fork()');
        like($body, qr/!\s*defined\s*\$pid/, 'AC-7: _resources_sampler_start branches on !defined $pid');
        like($body, qr/log_ev\s*\(\s*['"]resources_sampler_start_failed['"]/,
            'AC-7: the !defined $pid branch calls log_ev with resources_sampler_start_failed');
        like($body, qr/reason\s*=>\s*"fork/, 'AC-7: the log_ev reason mentions fork');
        # AMENDED 2026-08-19 by package t01-resources-sampler. The failure branch
        # used to `return undef` and nothing else, so the caller learned only
        # that there was no pid -- the REASON was logged and then discarded, and
        # the resources panel could say nothing but "sampling - no reading yet"
        # forever even when no reading was ever coming. That is the operator
        # report this package closes, so the arity change is the fix, not damage
        # to route around.
        #
        # The assertion's intent is preserved exactly: the failure branch still
        # yields NO PID. It now additionally carries the reason outward, and
        # this pins that shape rather than merely tolerating it.
        like($body, qr/return\s*\(\s*undef\s*,/,
            'AC-7: the !defined $pid branch returns no pid, and carries the reason out with it');
        # STDIN/STDOUT still go to /dev/null. STDERR does NOT, and that is the
        # fix rather than a regression.
        #
        # The property AC-7 is protecting is that the child never inherits the
        # CONSOLE handles -- a sampler that writes to the terminal scribbles
        # across the very TUI it feeds. /dev/null satisfied that for STDERR and
        # also destroyed the child's only explanation of itself: its argument
        # validation exits 2 after printing exactly one line naming what was
        # wrong, and that line went nowhere. The operator saw "FAILED - sampler
        # exited before writing a reading" and the trail ended there.
        #
        # So the assertion now pins the PROPERTY (redirected away from the
        # console) rather than one particular destination, and separately pins
        # that STDERR goes somewhere READABLE.
        for my $fh (qw(STDIN STDOUT)) {
            like($body, qr/open\s*\(\s*\Q$fh\E\s*,\s*['"][<>]['"]\s*,\s*['"]\/dev\/null['"]/,
                "AC-7: _resources_sampler_start reopens $fh on /dev/null");
        }
        like($body, qr/_sampler_stderr_to\s*\(/,
            'AC-7: _resources_sampler_start redirects the child STDERR through _sampler_stderr_to '
          . '-- away from the console (the property AC-7 protects) and into a file a human can read');
        unlike($body, qr/open\s*\(\s*STDERR\s*,\s*['"]>['"]\s*,\s*['"]\/dev\/null['"]/,
            'AC-7: ...and NOT straight to /dev/null, which threw away the one line the child '
          . 'prints to say why it refused to start');
        like($body, qr/local\s+\$ENV\{MSYS2_ARG_CONV_EXCL\}\s*=\s*'\*'/,
            q{AC-7: _resources_sampler_start sets local $ENV{MSYS2_ARG_CONV_EXCL} = '*'});
        like($body, qr/\bexec\s*\(/, 'AC-7: _resources_sampler_start calls exec(');
        like($body, qr/POSIX::_exit/, 'AC-7: _resources_sampler_start calls POSIX::_exit on exec failure');
        unlike($body, qr/\bwhile\s*\(/, 'AC-7: _resources_sampler_start contains no while loop');
        unlike($body, qr/\bfor\s*\(/,   'AC-7: _resources_sampler_start contains no for loop');
        unlike($body, qr/\bsleep\b/,    'AC-7: _resources_sampler_start contains no sleep -- degrade once, never retry');
        my $n_fork = () = $body =~ /\bfork\s*\(/g;
        is($n_fork, 1, 'AC-7: _resources_sampler_start calls fork() exactly once -- no second/retry fork');
    } else {
        fail($_) for (
            'AC-7: _resources_sampler_start calls fork()',
            'AC-7: _resources_sampler_start branches on !defined $pid',
            'AC-7: the !defined $pid branch calls log_ev with resources_sampler_start_failed',
            'AC-7: the log_ev reason mentions fork',
            'AC-7: the !defined $pid branch returns undef',
            'AC-7: _resources_sampler_start reopens STDIN on /dev/null',
            'AC-7: _resources_sampler_start reopens STDOUT on /dev/null',
            'AC-7: _resources_sampler_start reopens STDERR on /dev/null',
            q{AC-7: _resources_sampler_start sets local $ENV{MSYS2_ARG_CONV_EXCL} = '*'},
            'AC-7: _resources_sampler_start calls exec(',
            'AC-7: _resources_sampler_start calls POSIX::_exit on exec failure',
            'AC-7: _resources_sampler_start contains no while loop',
            'AC-7: _resources_sampler_start contains no for loop',
            'AC-7: _resources_sampler_start contains no sleep -- degrade once, never retry',
            'AC-7: _resources_sampler_start calls fork() exactly once -- no second/retry fork',
        );
    }
}

# --- AC-8 -> DC-1: stop / reap_orphan / release_global wiring. -----------
{
    my $stop_body = extract_sub($launcher_src, '_resources_sampler_stop');
    ok(defined $stop_body, 'AC-8: the _resources_sampler_stop body is extractable');
    if (defined $stop_body) {
        like($stop_body, qr/kill\s*\(\s*['"]KILL['"]/, q{AC-8: _resources_sampler_stop calls kill('KILL', ...)});
        like($stop_body, qr/\bwaitpid\b/, 'AC-8: _resources_sampler_stop calls waitpid');
        like($stop_body, qr/\bunlink\b/,  'AC-8: _resources_sampler_stop calls unlink');
    } else {
        fail($_) for (q{AC-8: _resources_sampler_stop calls kill('KILL', ...)},
                       'AC-8: _resources_sampler_stop calls waitpid',
                       'AC-8: _resources_sampler_stop calls unlink');
    }

    my $reap_body = extract_sub($launcher_src, '_resources_sampler_reap_orphan');
    ok(defined $reap_body, 'AC-8: the _resources_sampler_reap_orphan body is extractable');
    if (defined $reap_body) {
        like($reap_body, qr/Resources::sampler_reap_decision\s*\(/,
            'AC-8: _resources_sampler_reap_orphan calls Resources::sampler_reap_decision');
        like($reap_body, qr/\{reap\}/,
            "AC-8: _resources_sampler_reap_orphan guards its kill on the decision's reap key");
        like($reap_body, qr/\bkill\s*\(/, 'AC-8: _resources_sampler_reap_orphan calls kill');
    } else {
        fail($_) for ('AC-8: _resources_sampler_reap_orphan calls Resources::sampler_reap_decision',
                       "AC-8: _resources_sampler_reap_orphan guards its kill on the decision's reap key",
                       'AC-8: _resources_sampler_reap_orphan calls kill');
    }

    # COMMENTS STRIPPED FIRST. This is a PROXIMITY window over raw source: it
    # takes 600 characters from the FIRST occurrence of `$SIG{INT}` and looks for
    # the release call inside it. Any comment that merely NAMES the handler --
    # e.g. "the signal/abnormal-exit half is covered separately by
    # $SIG{INT}/$SIG{TERM}/END at file scope" -- becomes the first match, and the
    # window then covers prose instead of the handler.
    #
    # That fired for real: extracting the terminal-restore primitives out of
    # leave_raw moved a comment carrying exactly that sentence from line ~5250 to
    # ~1000, ahead of the handlers, and two assertions went red while the
    # handlers themselves were untouched. The code was correct; the oracle was
    # reading prose.
    #
    # Sixth instance of this shape in one day (t/26, t/61, t/65, t/66, t/115),
    # and the same remedy each time.
    (my $launcher_code = $launcher_src) =~ s/^\s*#.*$//mg;

    for my $pair ( [ '$SIG{INT}', qr/\$SIG\{INT\}/ ], [ '$SIG{TERM}', qr/\$SIG\{TERM\}/ ], [ 'END', qr/^END\s*\{/m ] ) {
        my ($label, $qr) = @$pair;
        my $desc = "AC-8: _resources_sampler_release_global appears in the $label handler";
        if ($launcher_code =~ $qr) {
            my $window = substr($launcher_code, $-[0], 600);
            like($window, qr/_resources_sampler_release_global/, $desc);
        } else {
            fail("$desc [$label not found in launcher.pl]");
        }
    }
}

# --- AC-9 -> DC-1: Resources::sampler_reap_decision behavioural table. ---
# EXTENDED here for the step-7 fix-batch (red-team H1): sampler_reap_decision
# used to parse the record's owner_pid and then DISCARD it
# ("my ($pid, undef, $stamp) = ($1, $2, $3)"), so nothing downstream could
# ever tell a live peer's sampler apart from a real orphan. The fix recovers
# it as a new `owner` key, unconditionally, in every 3-arg call too -- this
# is a pure ADDITION to the table (every pid/reap claim below is unchanged),
# not a weakening. See the FIXBATCH-2/4 block near the end of this file for
# the new 4-arg owner-liveness-aware behaviour this field enables.
{
    my @vectors = (
        [ 'well-formed, fresh stamp', "123 456 " . ($NOW - 5) . "\n", $NOW, 23, { pid => 123, owner => 456, reap => 1 } ],
        [ 'well-formed, stamp exactly 3*interval old -> reap', "123 456 " . ($NOW - 69) . "\n", $NOW, 23, { pid => 123, owner => 456, reap => 1 } ],
        [ 'well-formed, stamp one second past 3*interval -> refuse', "123 456 " . ($NOW - 70) . "\n", $NOW, 23, { pid => 123, owner => 456, reap => 0 } ],
        [ 'garbage text',     'not a record', $NOW, 23, { pid => undef, owner => undef, reap => 0 } ],
        [ 'empty string',     '',             $NOW, 23, { pid => undef, owner => undef, reap => 0 } ],
        [ 'undef text',       undef,          $NOW, 23, { pid => undef, owner => undef, reap => 0 } ],
        [ 'a ref instead of text', [],        $NOW, 23, { pid => undef, owner => undef, reap => 0 } ],
        [ 'future stamp',     "123 456 " . ($NOW + 100) . "\n", $NOW, 23, { pid => 123, owner => 456, reap => 0 } ],
    );
    for my $v (@vectors) {
        my ($label, $text, $now, $iv, $want) = @$v;
        my ($res, $err, $warns) = probe_call('sampler_reap_decision', $text, $now, $iv);
        is($err, '', "AC-9: sampler_reap_decision($label) does not die");
        ok($err eq '' && !@$warns, "AC-9: sampler_reap_decision($label) does not warn");
        is_deeply($res, $want, "AC-9: sampler_reap_decision($label) matches the behavioural table");
    }
    # pid = 0: spec leaves the returned pid value ambiguous (undef|0) but is
    # explicit that reap must be 0 -- assert only the load-bearing half.
    {
        my ($res, $err) = probe_call('sampler_reap_decision', "0 456 $NOW\n", $NOW, 23);
        is($err, '', 'AC-9: sampler_reap_decision(pid=0 record) does not die');
        ok(is_hashref($res) && $res->{reap} == 0,
            'AC-9: sampler_reap_decision(pid=0 record) -> reap=>0 (pid itself is spec-ambiguous, undef|0)');
    }
    # interval defaults to interval() when unusable.
    {
        my $want = R('sampler_reap_decision', "123 456 " . ($NOW - 5) . "\n", $NOW, undef);
        ok(is_hashref($want) && $want->{reap} == 1,
            'AC-9: sampler_reap_decision with an unusable $interval falls back to interval() (23) rather than dying');
    }
}

# --- AC-10 -> DC-1: sampler-mode arg parsing + dispatch-block ordering. ---
{
    for my $flag ('--resources-sampler', '--sampler-container', '--sampler-owner-pid') {
        like($launcher_src, qr/\Q$flag\E/, "AC-10: launcher.pl source contains the flag $flag");
    }
    like($launcher_src, qr/RESOURCES_SAMPLER_MODE/, 'AC-10: launcher.pl source sets $RESOURCES_SAMPLER_MODE');

    my $dispatch_pos = ($launcher_src =~ /RESOURCES_SAMPLER_MODE[^\n]*\)\s*\{[^\n]*\n[^\n]*_resources_sampler_main/)
        ? $-[0] : undef;
    ok(defined $dispatch_pos,
        'AC-10: the sampler-mode dispatch block (if ($RESOURCES_SAMPLER_MODE) { exit(_resources_sampler_main(...)) }) is locatable');

    my $lock_pos   = ($launcher_src =~ /SandboxLock::acquire\s*\(/) ? $-[0] : undef;
    my $sigint_pos = ($launcher_src =~ /\$SIG\{INT\}\s*=/) ? $-[0] : undef;
    ok(defined $lock_pos,   'AC-10: SandboxLock::acquire( is locatable in launcher.pl');
    ok(defined $sigint_pos, 'AC-10: $SIG{INT} = is locatable in launcher.pl');

    if (defined $dispatch_pos && defined $lock_pos) {
        ok($dispatch_pos < $lock_pos, 'AC-10: the sampler-mode dispatch block appears BEFORE SandboxLock::acquire( by byte offset');
    } else {
        fail('AC-10: the sampler-mode dispatch block appears BEFORE SandboxLock::acquire( by byte offset');
    }
    if (defined $dispatch_pos && defined $sigint_pos) {
        ok($dispatch_pos < $sigint_pos, 'AC-10: the sampler-mode dispatch block appears BEFORE the $SIG{INT} assignment by byte offset');
    } else {
        fail('AC-10: the sampler-mode dispatch block appears BEFORE the $SIG{INT} assignment by byte offset');
    }
}

# --- AC-12 -> DC-1: declared snapshot/pidfile paths under the state dir. --
{
    like($launcher_src, qr/\$RESOURCES_SNAPSHOT_FILE\s*=\s*"\$LAUNCHER_DIR\/\.resources-snapshot\.json"/,
        'AC-12: launcher.pl declares $RESOURCES_SNAPSHOT_FILE = "$LAUNCHER_DIR/.resources-snapshot.json"');
    like($launcher_src, qr/\$RESOURCES_SAMPLER_PID\s*=\s*"\$LAUNCHER_DIR\/resources-sampler\.pid"/,
        'AC-12: launcher.pl declares $RESOURCES_SAMPLER_PID = "$LAUNCHER_DIR/resources-sampler.pid"');
}

# --- AC-13 -> DC-5: sampler writes go through _write_file_atomic only. ----
{
    my $round_body = extract_sub($launcher_src, '_resources_sampler_round');
    ok(defined $round_body, 'AC-13: the _resources_sampler_round body is extractable');
    if (defined $round_body) {
        like($round_body, qr/_write_file_atomic\s*\(/, 'AC-13: _resources_sampler_round calls _write_file_atomic(');
        unlike($round_body, qr/open\s*\([^)]*['"]>['"]/,  'AC-13: _resources_sampler_round contains no ">" write-mode open');
        unlike($round_body, qr/open\s*\([^)]*['"]>>['"]/, 'AC-13: _resources_sampler_round contains no ">>" write-mode open');
        unlike($round_body, qr/open\s*\([^)]*['"]\+<['"]/, 'AC-13: _resources_sampler_round contains no "+<" write-mode open');
    } else {
        fail($_) for ('AC-13: _resources_sampler_round calls _write_file_atomic(',
                       'AC-13: _resources_sampler_round contains no ">" write-mode open',
                       'AC-13: _resources_sampler_round contains no ">>" write-mode open',
                       'AC-13: _resources_sampler_round contains no "+<" write-mode open');
    }

    my $main_body = extract_sub($launcher_src, '_resources_sampler_main');
    ok(defined $main_body, 'AC-13: the _resources_sampler_main body is extractable');
    if (defined $main_body) {
        like($main_body, qr/_write_file_atomic\s*\(/, 'AC-13: _resources_sampler_main writes the pidfile through _write_file_atomic(');
    } else {
        fail('AC-13: _resources_sampler_main writes the pidfile through _write_file_atomic(');
    }
}

# --- AC-14 -> DC-5: _write_file_atomic non-regression pin. ---------------
{
    my $body = extract_sub($launcher_src, '_write_file_atomic');
    ok(defined $body, 'AC-14: the _write_file_atomic body is extractable (non-regression pin)');
    if (defined $body) {
        like($body, qr/\.tmp\.\$\$\./, 'AC-14: _write_file_atomic uses a .tmp.$$. temp-file component (non-regression)');
        like($body, qr/rand\(/,        'AC-14: _write_file_atomic includes a random hex component (non-regression)');
        like($body, qr/chmod\s+0600/,  'AC-14: _write_file_atomic chmods the temp file 0600 (non-regression)');
        like($body, qr/rename\s*\(/,   'AC-14: _write_file_atomic calls rename( (non-regression)');
        my $n_unlink = () = $body =~ /unlink\s+\$tmp/g;
        ok($n_unlink >= 2,
            'AC-14: _write_file_atomic unlinks $tmp on at least two failure paths (close-failure and rename-failure, non-regression)');
    } else {
        fail($_) for ('AC-14: _write_file_atomic uses a .tmp.$$. temp-file component',
                       'AC-14: _write_file_atomic includes a random hex component',
                       'AC-14: _write_file_atomic chmods the temp file 0600',
                       'AC-14: _write_file_atomic calls rename(',
                       'AC-14: _write_file_atomic unlinks $tmp on at least two failure paths');
    }
}

# --- AC-15 -> DC-5/DC-3: round-trip snapshot_parse(snapshot_encode(snapshot_build)). --
{
    my @fixtures = (
        [ 'fully populated', { %B10 },
          { now => $NOW, pid => 4242, container => $CTR, platform => 'windows',
            probes_run => [ qw(stats machine cim_mem) ], probes_absent => [] } ],
        [ 'all-undef struct', { %ALL_NA },
          { now => undef, pid => undef, container => undef, platform => 'posix',
            probes_run => [], probes_absent => [] } ],
        [ 'off-Windows probes_absent', { %B10 },
          { now => $NOW, pid => 99, container => $CTR, platform => 'posix',
            probes_run => [ 'stats', 'df' ], probes_absent => [ qw(machine cim_mem cim_cpu cim_disk) ] } ],
    );
    for my $f (@fixtures) {
        my ($label, $struct, $meta) = @$f;
        my $desc = "AC-15: snapshot_parse(snapshot_encode(snapshot_build(...))) round-trips byte-for-byte for the $label fixture";
        # Each step is called through probe_call directly (not R()'s $FAILED
        # sentinel) and gated on its own success -- R()'s $FAILED sentinel is
        # the SAME blessed object on every failed call, so is_deeply($FAILED,
        # $FAILED) would otherwise PASS this assertion for the wrong reason
        # (missing subs, not a working round-trip) exactly the hazard the
        # sentinel's own doc comment (t/44:216) warns against elsewhere.
        my ($built,   $ebuilt)   = probe_call('snapshot_build',  $struct, $meta);
        my ($encoded, $eencoded) = probe_call('snapshot_encode', $built);
        my ($parsed,  $eparsed)  = probe_call('snapshot_parse',  $encoded);
        if ($ebuilt ne '' || $eencoded ne '' || $eparsed ne '') {
            fail("$desc [a step in the chain did not complete: build='$ebuilt' encode='$eencoded' parse='$eparsed']");
        } else {
            is_deeply($parsed, $built, $desc);
        }
    }
}

# --- AC-16 -> DC-5: truncation robustness -- never a partial struct. -----
{
    my $valid = R('snapshot_build', { %B10 },
        { now => $NOW, pid => 1, container => $CTR, platform => 'windows', probes_run => [ 'stats' ], probes_absent => [] });
    my $bytes = R('snapshot_encode', $valid);
    ok(defined($bytes) && !ref($bytes) && length($bytes) > 0, 'AC-16 setup: snapshot_encode produced non-empty bytes');

    if (defined($bytes) && !ref($bytes)) {
        my $len = length($bytes);
        for my $frac (0.1, 0.25, 0.5, 0.75, 0.9) {
            my $truncated = substr($bytes, 0, int($len * $frac));
            my $res = R('snapshot_parse', $truncated);
            is($res, undef, 'AC-16: snapshot_parse(truncated at ' . int($frac * 100) . '%) == undef -- never a partial struct');
        }
    } else {
        fail("AC-16: snapshot_parse(truncated at $_\%) == undef") for (10, 25, 50, 75, 90);
    }

    is(R('snapshot_parse', undef), undef, 'AC-16: snapshot_parse(undef) == undef');
    is(R('snapshot_parse', ''),    undef, 'AC-16: snapshot_parse("") == undef');
    is(R('snapshot_parse', '[]'),  undef, 'AC-16: snapshot_parse of a JSON array == undef');

    my $bad_v = R('snapshot_encode', { v => 2, written_at => $NOW, sampler_pid => 1, container => undef,
                    platform => 'posix', probes_run => [], probes_absent => [], resources => { %ALL_NA } });
    is(R('snapshot_parse', $bad_v), undef, 'AC-16: snapshot_parse of an encoded doc with v => 2 == undef');

    my $bad_res = R('snapshot_encode', { v => 1, written_at => $NOW, sampler_pid => 1, container => undef,
                    platform => 'posix', probes_run => [], probes_absent => [], resources => 'not a hashref' });
    is(R('snapshot_parse', $bad_res), undef, 'AC-16: snapshot_parse of an encoded doc with a non-hashref resources == undef');
}

# --- AC-17 -> DC-1/DC-6: snapshot_build's eight declared keys. -----------
{
    my @SNAP_KEYS = qw(v written_at sampler_pid container platform probes_run probes_absent resources);
    for my $case ( [ 'undef struct', undef ], [ 'ref struct', [] ], [ 'struct with extra keys', { %B10, bogus_extra_key => 'x' } ] ) {
        my ($label, $struct) = @$case;
        my $meta = { now => $NOW, pid => 1, container => $CTR, platform => 'windows', probes_run => [], probes_absent => [] };
        my $snap = R('snapshot_build', $struct, $meta);
        ok(is_hashref($snap), "AC-17: snapshot_build($label, meta) returns a hashref");
        if (is_hashref($snap)) {
            is_deeply([ sort keys %$snap ], [ sort @SNAP_KEYS ],
                "AC-17: snapshot_build($label, meta) has exactly the eight declared keys");
            ok(is_hashref($snap->{resources}), "AC-17: snapshot_build($label, meta)->{resources} is a hashref");
            if (is_hashref($snap->{resources})) {
                is_deeply([ sort keys %{ $snap->{resources} } ], [ sort @KEYS_15 ],
                    "AC-17: snapshot_build($label, meta)->{resources} has exactly the 15 closed keys");
            } else {
                fail("AC-17: snapshot_build($label, meta)->{resources} has exactly the 15 closed keys");
            }
        } else {
            fail("AC-17: snapshot_build($label, meta) has exactly the eight declared keys");
            fail("AC-17: snapshot_build($label, meta)->{resources} is a hashref");
            fail("AC-17: snapshot_build($label, meta)->{resources} has exactly the 15 closed keys");
        }
    }
    is(field(R('snapshot_build', {}, {}), 'v'), 1, 'AC-17: snapshot_build(...)->{v} is always 1');
}

# --- AC-18 -> DC-3: snapshot_status behavioural table. --------------------
{
    my @vectors = (
        [ 'undef parsed',          undef,                       $NOW, 60, 'failed' ],
        [ 'age == max_age',        { written_at => $NOW - 60 }, $NOW, 60, 'fresh'  ],
        [ 'age == max_age + 1',    { written_at => $NOW - 61 }, $NOW, 60, 'stale'  ],
        [ 'now < written_at',      { written_at => $NOW + 5 },  $NOW, 60, 'fresh'  ],
        [ 'unusable written_at',   { written_at => 'x' },       $NOW, 60, 'failed' ],
        [ 'unusable now',          { written_at => $NOW },      'x',  60, 'failed' ],
    );
    for my $v (@vectors) {
        my ($label, $parsed, $now, $max_age, $want_state) = @$v;
        my ($res, $err, $warns) = probe_call('snapshot_status', $parsed, $now, $max_age);
        is($err, '', "AC-18: snapshot_status($label) does not die");
        ok($err eq '' && !@$warns, "AC-18: snapshot_status($label) does not warn");
        is(field($res, 'state'), $want_state, "AC-18: snapshot_status($label) -> state == '$want_state'");
    }
    is(field(R('snapshot_status', { written_at => $NOW + 5 }, $NOW, 60), 'age'), 0,
        'AC-18: now < written_at -> age => 0 (backwards clock reads fresh, never stale)');
    my $stale = R('snapshot_status', { written_at => $NOW - 61, resources => { %B10 } }, $NOW, 60);
    is(field($stale, 'age'), 61, 'AC-18: stale state carries the real numeric age');
    is_deeply(field($stale, 'resources'), R('build', {}), 'AC-18: stale state resources is the all-n/a struct (build({}))');
    my $failed = R('snapshot_status', undef, $NOW, 60);
    is_deeply(field($failed, 'resources'), R('build', {}), 'AC-18: failed state resources is the all-n/a struct (build({}))');
}

# --- AC-19 -> DC-3: the four states are pairwise distinguishable. --------
{
    my $stale_status  = R('snapshot_status', { written_at => $NOW - 61 }, $NOW, 60);
    my $failed_status = R('snapshot_status', undef, $NOW, 60);
    my $fresh_status  = R('snapshot_status', { written_at => $NOW, resources => { %B10 } }, $NOW, 60);

    is(field($stale_status,  'state'), 'stale',  'AC-19: the stale state is state=>stale');
    is(field($failed_status, 'state'), 'failed', 'AC-19: the failed state is state=>failed');
    is(field($fresh_status,  'state'), 'fresh',  'AC-19: the fresh state is state=>fresh');
    isnt(field($stale_status,  'state'), field($failed_status, 'state'), 'AC-19: stale != failed');
    isnt(field($stale_status,  'state'), field($fresh_status,  'state'), 'AC-19: stale != fresh');
    isnt(field($failed_status, 'state'), field($fresh_status,  'state'), 'AC-19: failed != fresh');

    my $gr_body = extract_sub($launcher_src, '_gather_resources');
    ok(defined $gr_body, 'AC-19: the _gather_resources body is extractable');
    if (defined $gr_body) {
        like($gr_body, qr/return\s+undef\s+unless\s+-f/,
            'AC-19: _gather_resources returns undef on the missing-file branch (never-written, distinguishable from stale/failed)');
        like($gr_body, qr/snapshot_state/,
            'AC-19: _gather_resources otherwise returns a hash containing snapshot_state');
    } else {
        fail('AC-19: _gather_resources returns undef on the missing-file branch');
        fail('AC-19: _gather_resources otherwise returns a hash containing snapshot_state');
    }

    my $snap = R('snapshot_build', { %B10, machine_state => undef, machine_name => undef },
                  { now => $NOW, pid => 1, container => undef, platform => 'posix',
                    probes_run => [ 'stats', 'df' ], probes_absent => [ qw(machine cim_mem cim_cpu cim_disk) ] });
    ok(is_hashref($snap), 'AC-19 setup: snapshot_build produced a hashref for the no-container fixture');
    if (is_hashref($snap)) {
        is(field($snap->{resources}, 'machine_state'), undef,
            'AC-19: no-container snapshot -> machine_state is undef in resources (not-applicable, orthogonal to B16-B19)');
        is_deeply($snap->{probes_absent}, [ qw(machine cim_mem cim_cpu cim_disk) ],
            'AC-19: no-container snapshot -> probes_absent names what this platform never had');
    } else {
        fail('AC-19: no-container snapshot -> machine_state is undef in resources');
        fail('AC-19: no-container snapshot -> probes_absent names what this platform never had');
    }
}

# --- AC-21 -> DC-4: starvation contrast, starved arm vs sampler arm. -----
{
    my @ORDER = qw(stats machine cim_mem cim_cpu cim_disk df);

    my %count_s = map { $_ => 0 } @ORDER;
    my %probes_s = (
        stats    => sub { $count_s{stats}++;    return $FX_STATS },
        machine  => sub { $count_s{machine}++;  return $FX_MACHINE },
        cim_mem  => sub { $count_s{cim_mem}++;  return $BOM . $FX_CIM_MEM },
        cim_cpu  => sub { $count_s{cim_cpu}++;  return $BOM . $FX_CIM_CPU },
        cim_disk => sub { $count_s{cim_disk}++; return $BOM . $FX_CIM_DISK },
        df       => sub { $count_s{df}++;       return $FX_DF },
    );
    my $clock_calls_s = 0;
    my $clock_s = sub { $clock_calls_s++; return 1000 + 2 * $clock_calls_s; };
    my ($res_s, $err_s) = probe_call('gather', \%probes_s,
        { container => $CTR, device => 'C:', budget => 4, now => $clock_s });
    is($err_s, '', 'AC-21 (starved arm): gather with the render-tick-shaped opts does not die');
    is($count_s{cim_disk}, 0, 'AC-21 (starved arm): cim_disk is invoked ZERO times under the render-tick budget/clock shape');
    is($count_s{df},       0, 'AC-21 (starved arm): df is invoked ZERO times under the render-tick budget/clock shape');
    for my $k (qw(host_disk_total host_disk_used pod_images pod_containers pod_volumes)) {
        is(field($res_s, $k), undef, "AC-21 (starved arm): $k is undef -- the tail probes never ran");
    }

    my %count_p = map { $_ => 0 } @ORDER;
    my %probes_p = (
        stats    => sub { $count_p{stats}++;    return $FX_STATS },
        machine  => sub { $count_p{machine}++;  return $FX_MACHINE },
        cim_mem  => sub { $count_p{cim_mem}++;  return $BOM . $FX_CIM_MEM },
        cim_cpu  => sub { $count_p{cim_cpu}++;  return $BOM . $FX_CIM_CPU },
        cim_disk => sub { $count_p{cim_disk}++; return $BOM . $FX_CIM_DISK },
        df       => sub { $count_p{df}++;       return $FX_DF },
    );
    my $opts = R('sampler_probe_opts', $CTR, 'C:');
    ok(is_hashref($opts), 'AC-21 setup: sampler_probe_opts returns a hashref');
    my ($res_p, $err_p) = probe_call('gather', \%probes_p, $opts);
    is($err_p, '', 'AC-21 (sampler arm): gather with sampler_probe_opts does not die');
    for my $k (@ORDER) {
        is($count_p{$k}, 1, "AC-21 (sampler arm): probe '$k' (the SAME probes as the starved arm) is invoked exactly once");
    }
    for my $k (qw(host_disk_total host_disk_used host_disk_dev pod_images pod_containers pod_volumes)) {
        is(field($res_p, $k), $B10{$k},
            "AC-21 (sampler arm): $k is defined and equals the fixture-derived value -- the tail probes produce VALUES, not just run");
    }

    my $o2 = R('sampler_probe_opts', 'c', 'C:');
    is_deeply($o2, { container => 'c', device => 'C:' }, q{AC-21: sampler_probe_opts('c','C:') has exactly the keys container and device});
    ok(is_hashref($o2) && !exists($o2->{now}),    'AC-21: sampler_probe_opts result has no now key (exists is false)');
    ok(is_hashref($o2) && !exists($o2->{budget}), 'AC-21: sampler_probe_opts result has no budget key (exists is false)');
}

# --- AC-22 -> DC-3/DC-4: Resources::probe_availability. -------------------
{
    my %full = map { $_ => sub {1} } qw(stats machine cim_mem cim_cpu cim_disk df);
    is_deeply(R('probe_availability', \%full),
        { present => [ qw(stats machine cim_mem cim_cpu cim_disk df) ], absent => [] },
        'AC-22: probe_availability with the full six-key probe hash -> present = full PROBE_ORDER, absent = []');

    my %partial = ( stats => sub {1}, df => sub {1} );
    is_deeply(R('probe_availability', \%partial),
        { present => [ 'stats', 'df' ], absent => [ qw(machine cim_mem cim_cpu cim_disk) ] },
        'AC-22: probe_availability with only stats+df -> present in PROBE_ORDER order, absent the remaining four in order');

    my %mixed = ( stats => sub {1}, machine => 'not a coderef', bogus_key => sub {1} );
    is_deeply(R('probe_availability', \%mixed),
        { present => [ 'stats' ], absent => [ qw(machine cim_mem cim_cpu cim_disk df) ] },
        'AC-22: probe_availability ignores a non-CODE value and an unrecognized key');

    for my $bad ( [ 'undef', undef ], [ "'x'", 'x' ], [ '[]', [] ] ) {
        my ($label, $val) = @$bad;
        is_deeply(R('probe_availability', $val),
            { present => [], absent => [ qw(stats machine cim_mem cim_cpu cim_disk df) ] },
            "AC-22: probe_availability($label) -> present=>[], absent=>full PROBE_ORDER");
    }
}

# --- AC-23 -> DC-6: Resources::build stays pure -- no new snapshot machinery. --
{
    my $body = extract_sub($resources_src, 'build');
    ok(defined $body, "AC-23: Resources::build's body is extractable from Resources.pm");
    my @forbidden = (
        [ 'time',       qr/\btime\b/ ],           [ 'localtime', qr/\blocaltime\b/ ],
        [ 'open',       qr/\bopen\b/ ],            [ 'a -e file test', qr/(?<![\w\$])-e\s/ ],
        [ 'a -f file test', qr/(?<![\w\$])-f\s/ ], [ '$ENV', qr/\$ENV\b/ ],
        [ 'fork',       qr/\bfork\b/ ],            [ 'system', qr/\bsystem\b/ ],
        [ 'exec',       qr/\bexec\b/ ],            [ 'a backtick character', qr/`/ ],
        [ 'qx',         qr/\bqx\b/ ],              [ 'readpipe', qr/\breadpipe\b/ ],
        [ 'sleep',      qr/\bsleep\b/ ],           [ 'die', qr/\bdie\b/ ],
        [ 'warn',       qr/\bwarn\b/ ],            [ 'print', qr/\bprint\b/ ],
    );
    for my $f (@forbidden) {
        my ($label, $qr) = @$f;
        my $desc = "AC-23: Resources::build's body contains no $label";
        defined($body) ? unlike($body, $qr, $desc) : fail("$desc [build not extractable]");
    }
    for my $sub_name (qw(snapshot_build snapshot_encode snapshot_parse snapshot_status
                          sampler_probe_opts probe_availability sampler_reap_decision
                          read_interval max_age)) {
        my $desc = "AC-23: Resources::build's body does not name the new snapshot sub $sub_name -- none of the metadata appears in its output or inputs";
        defined($body) ? unlike($body, qr/\Q$sub_name\E/, $desc) : fail("$desc [build not extractable]");
    }
}

# --- AC-24 -> DC-6: Resources::build behaviour is unchanged and deterministic. --
{
    my $input = { machine => $FX_MACHINE, stats => $FX_STATS, df => $FX_DF,
                  cim_mem => $BOM . $FX_CIM_MEM, cim_disk => $BOM . $FX_CIM_DISK,
                  cim_cpu => $BOM . $FX_CIM_CPU, container => $CTR, device => 'C:' };
    my ($r1, $err1, $w1) = probe_call('build', $input);
    my ($r2, $err2, $w2) = probe_call('build', $input);
    is($err1, '', 'AC-24: build(fixture) does not die on the first call');
    is($err2, '', 'AC-24: build(fixture) does not die on the second call');
    ok($err1 eq '' && !@$w1, 'AC-24: build(fixture) records zero warnings on the first call');
    ok($err2 eq '' && !@$w2, 'AC-24: build(fixture) records zero warnings on the second call');
    is_deeply($r1, $r2, 'AC-24: calling build(fixture) twice with the same input returns deep-equal results (determinism)');
}

# ===========================================================================
# 12. STEP-7 CONSOLIDATED FIX-BATCH (03-resources-reader-model) -- assertions
#     for reviewer MAJOR-1 and red-team H1/H2/H2b/H2c/H3, all REPRODUCED FROM
#     SOURCE by the driver (reports/03-resources-reader-model/{reviewer,
#     redteam}.md) before this dispatch. Source-text / pure-function only,
#     per the SAME no-spawn convention as section 11 -- launcher.pl is NEVER
#     require'd/do'ne and podman/launcher.pl are NEVER invoked from this file.
#
#     MINOR-1 checked, no test change needed: neither this file nor t/53
#     contains "SandboxLock"/"concurrent"/"prevented upstream" prose
#     repeating the spec's false claim that SandboxLock prevents two
#     concurrent dashboards/samplers -- the actual (safe) mechanism is
#     owner-liveness (H1's fix below), not lock scope. Recorded here so a
#     future editor does not reintroduce the false reason in a comment.
# ===========================================================================

# --- FIXBATCH-1 -> reviewer MAJOR-1 / red-team H2: the three podman
#     backtick probes in _resources_probes must be wrapped in a BOUNDED
#     timeout (the in-repo `timeout N cmd` idiom already used at
#     bp-baseline.pl:266 -- /usr/bin/timeout is available on this host and
#     exits 124 on expiry), so a hung podman/WSL backend can no longer block
#     the sampler's round forever and starve the once-per-round
#     kill(0,$owner_pid) liveness gate at the top of _resources_sampler_main's
#     loop. Source-level only -- never spawns podman or timeout(1). ---
{
    my $probes_body = extract_block($launcher_src, 'sub _resources_probes');
    ok(defined $probes_body, 'FIXBATCH-1: the _resources_probes body is extractable from launcher.pl');
    if (defined $probes_body) {
        like($probes_body, qr/\btimeout\s+\d+\s+\S+\s+stats\s+--no-stream\s+--format\s+json/,
            'FIXBATCH-1 (MAJOR-1/H2): the "stats --no-stream" podman probe is wrapped in a bounded timeout (a hung podman.exe can no longer block the sampler round forever)');
        like($probes_body, qr/\btimeout\s+\d+\s+\S+\s+system\s+df\s+--format\s+json/,
            'FIXBATCH-1 (MAJOR-1/H2): the "system df" podman probe is wrapped in a bounded timeout');
        like($probes_body, qr/\btimeout\s+\d+\s+\S+\s+machine\s+list\s+--format\s+json/,
            'FIXBATCH-1 (MAJOR-1/H2): the "machine list" podman probe is wrapped in a bounded timeout');
    } else {
        fail($_) for (
            'FIXBATCH-1 (MAJOR-1/H2): the "stats --no-stream" podman probe is wrapped in a bounded timeout',
            'FIXBATCH-1 (MAJOR-1/H2): the "system df" podman probe is wrapped in a bounded timeout',
            'FIXBATCH-1 (MAJOR-1/H2): the "machine list" podman probe is wrapped in a bounded timeout',
        );
    }
}

# --- FIXBATCH-2/4 -> red-team H1 + H2c: Resources::sampler_reap_decision
#     gains a 4th, OPTIONAL owner-liveness parameter. Omitted/undef preserves
#     the ORIGINAL freshness-only algorithm exactly (AC-9 above, still
#     exercised in its 3-arg form -- the correct fallback for a caller that
#     cannot determine owner liveness). When supplied:
#       * owner_alive TRUE  -> reap => 0 UNCONDITIONALLY (H1: never kill a
#         sampler whose recorded owner is still alive -- a live owner is BY
#         DEFINITION not an orphan, no matter how the stamp reads).
#       * owner_alive FALSE -> reap => 1 whenever pid > 0 and the stamp is
#         usable, REGARDLESS of staleness (H2c: "wedged but ours" is now
#         reapable -- a confirmed-dead owner removes the PID-recycling
#         ambiguity that the staleness rule existed to guard against).
#     This is the distinction the dispatch asked to be encoded: staleness
#     alone only answers "is this record recent"; owner-liveness answers "is
#     this an orphan" -- and only the second question is safe to gate a
#     kill() on. ---
{
    my @owner_vectors = (
        [ 'fresh stamp, owner ALIVE -> H1: never reap a live owner\'s sampler',
          "123 456 " . ($NOW - 5) . "\n", $NOW, 23, 1, { pid => 123, owner => 456, reap => 0 } ],
        [ 'stale stamp (past 3x interval), owner ALIVE -> still refuse (a live owner trumps staleness)',
          "123 456 " . ($NOW - 70) . "\n", $NOW, 23, 1, { pid => 123, owner => 456, reap => 0 } ],
        [ 'stale stamp (past 3x interval), owner DEAD -> H2c: wedged-but-ours is now reapable',
          "123 456 " . ($NOW - 70) . "\n", $NOW, 23, 0, { pid => 123, owner => 456, reap => 1 } ],
        [ 'fresh stamp, owner DEAD -> also reapable (dead owner removes the recycling ambiguity)',
          "123 456 " . ($NOW - 5) . "\n", $NOW, 23, 0, { pid => 123, owner => 456, reap => 1 } ],
        [ 'garbage text, owner ALIVE -> still pid=>undef, reap=>0 (nothing parseable to reap)',
          'not a record', $NOW, 23, 1, { pid => undef, owner => undef, reap => 0 } ],
        [ 'stale stamp, owner-aliveness UNKNOWN (explicit undef 4th arg) -> falls back to the ORIGINAL freshness heuristic, same claim as the 3-arg AC-9 vector',
          "123 456 " . ($NOW - 70) . "\n", $NOW, 23, undef, { pid => 123, owner => 456, reap => 0 } ],
    );
    for my $v (@owner_vectors) {
        my ($label, $text, $now, $iv, $owner_alive, $want) = @$v;
        my ($res, $err, $warns) = probe_call('sampler_reap_decision', $text, $now, $iv, $owner_alive);
        is($err, '', "FIXBATCH-2/4: sampler_reap_decision($label) does not die");
        ok($err eq '' && !@$warns, "FIXBATCH-2/4: sampler_reap_decision($label) does not warn");
        is_deeply($res, $want, "FIXBATCH-2/4: sampler_reap_decision($label) matches the owner-aware behavioural table");
    }
    # pid = 0 stays refused even with a confirmed-dead owner -- pid remains
    # the load-bearing safety gate independent of owner-liveness.
    {
        my ($res, $err) = probe_call('sampler_reap_decision', "0 456 $NOW\n", $NOW, 23, 0);
        is($err, '', 'FIXBATCH-2/4: sampler_reap_decision(pid=0 record, owner DEAD) does not die');
        ok(is_hashref($res) && $res->{reap} == 0,
            'FIXBATCH-2/4: sampler_reap_decision(pid=0 record, owner DEAD) -> reap=>0 (pid=0 refuses regardless of owner-liveness)');
    }
}

# --- FIXBATCH-3 -> red-team H2b: _resources_sampler_reap_orphan must not
#     destroy the pidfile record before consulting the decision -- currently
#     it unlinks the pidfile ONE LINE before calling
#     Resources::sampler_reap_decision, so a record for a process it then
#     declines to kill is destroyed anyway and can never be reconsidered by a
#     later launch (the orphan becomes untracked forever). ---
{
    my $reap_body = extract_sub($launcher_src, '_resources_sampler_reap_orphan');
    ok(defined $reap_body, 'FIXBATCH-3: the _resources_sampler_reap_orphan body is extractable (re-extracted for this block)');
    if (defined $reap_body) {
        my $ok_conditional =
            ($reap_body =~ /unlink\s+\$pidfile\s+if\s+[^;{]*reap/s)
         || ($reap_body =~ /if\s*\([^)]*\{reap\}[^)]*\)\s*\{[^}]*unlink\s+\$pidfile/s);
        ok($ok_conditional,
            q{FIXBATCH-3 (H2b): unlink $pidfile is conditioned on Resources::sampler_reap_decision's reap result -- the record for a process the reaper declined to kill is never destroyed});

        my $decision_pos = ($reap_body =~ /Resources::sampler_reap_decision\s*\(/) ? $-[0] : undef;
        my $unlink_pos   = ($reap_body =~ /\bunlink\s+\$pidfile\b/) ? $-[0] : undef;
        ok(defined $decision_pos, 'FIXBATCH-3 (H2b): sampler_reap_decision( is locatable inside _resources_sampler_reap_orphan');
        ok(defined $unlink_pos,   'FIXBATCH-3 (H2b): unlink $pidfile is locatable inside _resources_sampler_reap_orphan');
        if (defined $decision_pos && defined $unlink_pos) {
            ok($unlink_pos > $decision_pos,
                'FIXBATCH-3 (H2b): unlink $pidfile occurs AFTER Resources::sampler_reap_decision( is called, by byte offset -- the decision is consulted before the record can be destroyed');
        } else {
            fail('FIXBATCH-3 (H2b): unlink $pidfile occurs AFTER Resources::sampler_reap_decision( is called, by byte offset');
        }
    } else {
        fail($_) for (
            q{FIXBATCH-3 (H2b): unlink $pidfile is conditioned on Resources::sampler_reap_decision's reap result},
            'FIXBATCH-3 (H2b): sampler_reap_decision( is locatable inside _resources_sampler_reap_orphan',
            'FIXBATCH-3 (H2b): unlink $pidfile is locatable inside _resources_sampler_reap_orphan',
            'FIXBATCH-3 (H2b): unlink $pidfile occurs AFTER Resources::sampler_reap_decision( is called, by byte offset',
        );
    }
}

# --- FIXBATCH-5 -> red-team H3: a written_at meaningfully ahead of $now must
#     NOT read as fresh. Property over a RANGE of skews (not two hardcoded
#     values) -- the driver reproduced the bug at +3600 and +86400. B21's
#     tolerated-skew intent (AC-18's existing 'now < written_at' vector,
#     skew=5) is preserved UNCHANGED below; only skews larger than max_age
#     must stop reading fresh -- one NTP step or DST jump must not pin the
#     panel to stale values that read as current. ---
{
    my $max_age = 60;
    # Skews at/under max_age -- the anti-flicker intent AC-18 already pins
    # (skew=5) still holds, including the boundary (skew == max_age).
    for my $skew (1, 30, 59, 60) {
        my $res = R('snapshot_status', { written_at => $NOW + $skew, resources => { %B10 } }, $NOW, $max_age);
        is(field($res, 'state'), 'fresh',
            "FIXBATCH-5: written_at ${skew}s ahead of now (<= max_age) still reads fresh (anti-flicker tolerance preserved, unchanged from AC-18)");
    }
    # Skews beyond max_age -- the property under test: NONE of these may read
    # 'fresh'. A single hardcoded +3600/+86400 check would miss an off-by-one
    # or a boundary-only fix; this sweeps a representative range instead.
    for my $skew ($max_age + 1, $max_age + 2, 2 * $max_age, 10 * $max_age, 3600, 86400, 7 * 86400, 365 * 86400) {
        my ($res, $err, $warns) = probe_call('snapshot_status', { written_at => $NOW + $skew, resources => { %B10 } }, $NOW, $max_age);
        is($err, '', "FIXBATCH-5: snapshot_status(written_at +${skew}s) does not die");
        ok($err eq '' && !@$warns, "FIXBATCH-5: snapshot_status(written_at +${skew}s) does not warn");
        isnt(field($res, 'state'), 'fresh',
            "FIXBATCH-5 (H3): written_at +${skew}s ahead of now must NOT read as fresh -- a clock skew this large must not pin the panel to stale values that read as current");
    }
}

done_testing();
