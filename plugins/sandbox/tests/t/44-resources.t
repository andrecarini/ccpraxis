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

# dlines($res) -> Dashboard::_resources_lines($res) as a list. On a missing
# sub / die it returns a single sentinel element, so an "empty list expected"
# assertion can never pass spuriously.
sub dlines {
    my ($res) = @_;
    my @lines = eval { Dashboard::_resources_lines($res) };
    return ({ __CALL_FAILED => ($@ || 'unknown') }) if $@;
    return @lines;
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
        [ 'fork',                 qr/\bfork\b/ ],
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

# --- AC-24 -> DC-3 (B21): panel presence + pinned order. ------------------
{
    my @none = Dashboard::build_panels(\%BASE_STATE, 80);
    my @titles_none = map { $_->{title} } @none;
    ok(!(grep { $_ eq 'Resources' } @titles_none),
        'AC-24: build_panels with no resources key -> NO Resources panel (B21)');
    is_deeply(\@titles_none, [ 'Sandbox', 'Run', 'Recent activity' ],
        'AC-24: the panel list is otherwise unchanged for a state without resources (B21)');

    for my $bad ( [ 'undef', undef ], [ "'x'", 'x' ], [ '[]', [] ] ) {
        my ($label, $val) = @$bad;
        my @p = Dashboard::build_panels({ %BASE_STATE, resources => $val }, 80);
        my @t = map { $_->{title} } @p;
        ok(!(grep { $_ eq 'Resources' } @t),
            "AC-24: resources => $label (not a hashref) -> NO Resources panel (B21)");
    }

    my @with = Dashboard::build_panels({ %BASE_STATE, resources => { %B10 } }, 80);
    my @with_titles = map { $_->{title} } @with;
    my $n = grep { $_ eq 'Resources' } @with_titles;
    is($n, 1, 'AC-24: resources => a hashref -> EXACTLY one Resources panel (B21)');
    my ($ri) = grep { $with_titles[$_] eq 'Resources' } 0 .. $#with_titles;
    my ($ai) = grep { $with_titles[$_] eq 'Recent activity' } 0 .. $#with_titles;
    ok(defined($ri) && defined($ai) && $ri == $ai - 1,
        'AC-24: Resources is positioned IMMEDIATELY before Recent activity (B21)');

    # An empty hashref still renders the panel (S5).
    my @empty = Dashboard::build_panels({ %BASE_STATE, resources => {} }, 80);
    is(scalar(grep { $_->{title} eq 'Resources' } @empty), 1,
        'AC-24: resources => {} still renders the panel (the guard is ref eq HASH) (S5)');

    # The pinned full order with every optional panel present.
    my @all = Dashboard::build_panels({
        %BASE_STATE,
        backpack  => { %BACKPACK_FIXTURE },
        tokens    => { %TOKENS_FIXTURE },
        resources => { %B10 },
    }, 80);
    is_deeply([ map { $_->{title} } @all ],
        [ 'Sandbox', 'Run', 'Backpack', 'Token', 'Resources', 'Recent activity' ],
        'AC-24: the pinned full panel order is Sandbox, Run, Backpack, Token, Resources, Recent activity');

    # _fixed_panels order (Recent activity is appended by build_panels).
    my @fixed = Dashboard::_fixed_panels({
        %BASE_STATE,
        backpack  => { %BACKPACK_FIXTURE },
        tokens    => { %TOKENS_FIXTURE },
        resources => { %B10 },
    }, 80);
    is_deeply([ map { $_->{title} } @fixed ],
        [ 'Sandbox', 'Run', 'Backpack', 'Token', 'Resources' ],
        'AC-24: _fixed_panels ends with Resources, so it never enters the two-column region (positions 0/1)');
}

# --- AC-25 -> DC-3 (B22/B23/B24/B25): the state -> line table, verbatim. --
{
    ok(Dashboard->can('_resources_lines'), 'AC-25: Dashboard::_resources_lines exists');

    my @lines = dlines(\%B10);
    is(scalar(@lines), 7, 'AC-25: the B10 struct renders exactly 7 body lines (B22)');

    my @expected = (
        [ $LABEL_SPANS[0],
          { text => 'running', role => 'good' },
          { text => ' (podman-machine-default)', role => 'muted' } ],
        [ $LABEL_SPANS[1],
          { text => '18.5 MB used | 6.2 GB free | 6.2 GB total', role => 'good' },
          $SEP_SPAN,
          { text => g(0), role => 'good' } ],
        [ $LABEL_SPANS[2],
          { text => '3.8%', role => 'value' } ],
        [ $LABEL_SPANS[3],
          { text => 'images 684.9 MB | containers 4.6 GB | volumes 0 B', role => 'value' } ],
        [ $LABEL_SPANS[4],
          { text => '21.9 GB used | 3.7 GB free | 25.5 GB total', role => 'warn' },
          $SEP_SPAN,
          { text => g(9), role => 'warn' } ],
        [ $LABEL_SPANS[5],
          { text => '205.5 GB used | 49.2 GB free | 254.8 GB total', role => 'warn' },
          $SEP_SPAN,
          { text => g(8), role => 'warn' },
          { text => ' (C:)', role => 'muted' } ],
        [ $LABEL_SPANS[6],
          { text => '16.0%', role => 'good' },
          $SEP_SPAN,
          { text => g(2), role => 'good' },
          { text => ' (8 cores)', role => 'muted' } ],
    );
    my @names = ('machine', 'ctr mem', 'ctr cpu', 'podman', 'host ram', 'host disk', 'host cpu');
    for my $i (0 .. 6) {
        is_deeply($lines[$i], $expected[$i],
            "AC-25: B10 line " . ($i + 1) . " ($names[$i]) matches the B23 table span-for-span");
    }

    # Every label span is exactly 14 ASCII characters (S2.6).
    for my $i (0 .. 6) {
        is(length($LABELS[$i]), 14, "AC-25: the '$names[$i]' label span text is exactly 14 characters");
        is(Dashboard::display_width($LABELS[$i]), 14,
            "AC-25: the '$names[$i]' label span display_width is 14 (ASCII-only)");
    }

    # B24: the all-n/a render -- exactly two spans per line, everywhere.
    for my $case ( [ 'build({})', R('build', {}) ], [ 'the literal all-n/a struct', { %ALL_NA } ], [ '{}', {} ] ) {
        my ($label, $struct) = @$case;
        my @l = dlines($struct);
        is(scalar(@l), 7, "AC-25: $label renders exactly 7 body lines (B22/B24)");
        for my $i (0 .. 6) {
            is_deeply($l[$i], [ $LABEL_SPANS[$i], $NA_SPAN ],
                "AC-25: $label line " . ($i + 1) . " is exactly [label, n/a] -- no gauge, no suffix (B24)");
        }
    }

    # B22: the empty list for a non-hashref.
    for my $case ( [ 'undef', undef ], [ '[]', [] ], [ "'x'", 'x' ], [ 'sub {}', sub { } ] ) {
        my ($label, $val) = @$case;
        my @l = dlines($val);
        is_deeply(\@l, [], "AC-25: _resources_lines($label) returns the EMPTY list, never dies (B22)");
    }

    # B25: partial degradation -- only host ram known.
    my %only_ram = ( host_ram_used => 21890629632, host_ram_total => 25542582272 );
    my @lr = dlines(\%only_ram);
    is(scalar(@lr), 7, 'AC-25: the host-ram-only struct still renders 7 lines (B25)');
    is_deeply($lr[4], [ $LABEL_SPANS[4],
                        { text => '21.9 GB used | 3.7 GB free | 25.5 GB total', role => 'warn' },
                        $SEP_SPAN,
                        { text => g(9), role => 'warn' } ],
        'AC-25: host-ram-only -> line 5 is the full gauge row (B25)');
    for my $i (0, 1, 2, 3, 5, 6) {
        is_deeply($lr[$i], [ $LABEL_SPANS[$i], $NA_SPAN ],
            'AC-25: host-ram-only -> line ' . ($i + 1) . " ($names[$i]) is n/a with no gauge (B25)");
    }

    # B25: podman row with only images known.
    my @lp = dlines({ pod_images => 684907310 });
    is_deeply($lp[3], [ $LABEL_SPANS[3],
                        { text => 'images 684.9 MB | containers n/a | volumes n/a', role => 'value' } ],
        'AC-25: pod_images set, the other two undef -> per-component n/a inside one value span (B25)');

    # machine_state variants (S2.6 line 1).
    my @mstates = ( [ 'running', 'good' ], [ 'starting', 'warn' ], [ 'stopped', 'bad' ] );
    for my $m (@mstates) {
        my ($state, $role) = @$m;
        my @l = dlines({ machine_state => $state });
        is_deeply($l[0], [ $LABEL_SPANS[0], { text => $state, role => $role } ],
            "AC-25: machine_state '$state' renders as {text=>'$state', role=>'$role'} with no name suffix");
    }
    my @lu = dlines({ machine_state => 'unknown', machine_name => '' });
    is_deeply($lu[0], [ $LABEL_SPANS[0], $NA_SPAN ],
        "AC-25: machine_state 'unknown' + empty machine_name -> the n/a span and NO name suffix");
    my @lw = dlines({ machine_state => 'wibble' });
    is_deeply($lw[0], [ $LABEL_SPANS[0], $NA_SPAN ],
        'AC-25: an unrecognized machine_state falls back to the n/a span');

    # Line 6's device suffix appears in the n/a branch too (S2.6).
    my @ld = dlines({ host_disk_dev => 'D:' });
    is_deeply($ld[5], [ $LABEL_SPANS[5], $NA_SPAN, { text => ' (D:)', role => 'muted' } ],
        'AC-25: host_disk_dev with no byte values -> n/a span PLUS the (device) suffix (S2.6 line 6)');

    # Line 7's cores suffix appears in the n/a branch too (S2.6).
    my @lc = dlines({ host_cores => 4 });
    is_deeply($lc[6], [ $LABEL_SPANS[6], $NA_SPAN, { text => ' (4 cores)', role => 'muted' } ],
        'AC-25: host_cores with no host_cpu_pct -> n/a span PLUS the (N cores) suffix (S2.6 line 7)');

    # No gauge on the ctr cpu row -- a container CPU% is not bounded by 100.
    my @lcpu = dlines({ ctr_cpu_pct => 137.5 });
    is_deeply($lcpu[2], [ $LABEL_SPANS[2], { text => '137.5%', role => 'value' } ],
        'AC-25: ctr cpu renders one value span with NO gauge, even above 100% (S2.6 line 3)');

    # total == 0 renders numbers with a muted role and an empty gauge (S5).
    my @lz = dlines({ ctr_mem_used => 0, vm_mem_total => 0 });
    is_deeply($lz[1], [ $LABEL_SPANS[1],
                        { text => '0 B used | 0 B free | 0 B total', role => 'muted' },
                        $SEP_SPAN,
                        { text => g(0), role => 'muted' } ],
        'AC-25: used=0/total=0 renders the numbers with a muted role and an empty gauge -- no division by zero (S5)');

    # available is clamped at 0, never negative.
    my @lo = dlines({ host_ram_used => 150, host_ram_total => 100 });
    is_deeply($lo[4], [ $LABEL_SPANS[4],
                        { text => '150 B used | 0 B free | 100 B total', role => 'bad' },
                        $SEP_SPAN,
                        { text => g(10), role => 'bad' } ],
        'AC-25: used > total -> free clamps to 0 B and the gauge clamps to full (S2.6)');

    # Structural shape + the closed role vocabulary.
    my %roles_ok = map { $_ => 1 } @ALLOWED_ROLES;
    for my $pair ( [ 'B10', \@lines ], [ 'all-n/a', [ dlines({ %ALL_NA }) ] ], [ 'host-ram-only', \@lr ] ) {
        my ($tag, $ls) = @$pair;
        for my $i (0 .. $#$ls) {
            my $line = $ls->[$i];
            is(ref($line), 'ARRAY', "AC-25: $tag line $i is an ARRAY ref of spans");
            next unless ref($line) eq 'ARRAY';
            for my $span (@$line) {
                is(ref($span), 'HASH', "AC-25: $tag line $i span is a HASH ref");
                next unless ref($span) eq 'HASH';
                is_deeply([ sort keys %$span ], [ 'role', 'text' ],
                    "AC-25: $tag line $i span has exactly the keys text/role");
                my $role = $span->{role};
                ok((defined($role) && $roles_ok{$role}),
                    "AC-25: $tag line $i span role (" . (defined $role ? $role : 'undef') . ') is in the closed vocabulary');
            }
        }
    }
}

# --- AC-28 -> DC-4 (B27): no new glyph. -----------------------------------
{
    my $table = Dashboard::glyph_table();
    is(ref($table), 'HASH', 'AC-28: glyph_table() returns a hashref');
    is(ref($table) eq 'HASH' ? scalar(keys %$table) : -1, 18,
        'AC-28: glyph_table() STILL has exactly 18 entries -- this package adds no glyph (B27)');

    for my $cols (80, 120) {
        my @panels = Dashboard::build_panels({ %BASE_STATE, resources => { %B10 } }, $cols);
        my $panel  = panel_by_title(\@panels, 'Resources');
        ok($panel, "AC-28: the Resources panel is present at $cols columns");
        next unless $panel && ref($panel->{lines}) eq 'ARRAY';

        my $text = join('', map { line_text($_) } @{ $panel->{lines} });
        my $decoded = eval { decode('UTF-8', $text, Encode::FB_CROAK) };
        ok(defined $decoded, "AC-28: the Resources panel span text is valid UTF-8 at $cols columns");
        next unless defined $decoded;

        my @bad = grep { $_ !~ /[\x20-\x7E\x{2588}\x{2591}]/ } split //, $decoded;
        is(scalar @bad, 0,
            "AC-28: every character of the Resources panel is printable ASCII or U+2588/U+2591 at $cols columns (B27)")
            or diag('offending: ' . join(' ', map { sprintf('U+%04X', ord $_) } @bad));
        unlike($text, qr/\?/,
            "AC-28: no '?' replacement character appears in any Resources row at $cols columns (B27)");
    }
}

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
        like($gr_body, qr/Resources::gather\s*\(/, 'AC-29: _gather_resources calls Resources::gather (S2.7e)');
        like($gr_body, qr/\bnow\s*=>\s*sub\s*\{\s*time\s*\}/,
            'AC-29: _gather_resources injects the clock as now => sub { time } -- time() lives HERE, not in Resources.pm');
        like($gr_body, qr/container\s*=>\s*\$CONTAINER_NAME/,
            'AC-29: _gather_resources passes container => $CONTAINER_NAME (never a positional guess)');
    } else {
        fail('AC-29: _gather_resources calls Resources::gather (S2.7e)');
        fail('AC-29: _gather_resources injects now => sub { time }');
        fail('AC-29: _gather_resources passes container => $CONTAINER_NAME');
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
        like($gather_block, qr/Resources::interval\s*\(\s*\)/,
            'AC-30: the gather closure passes Resources::interval() -- the cadence is never re-hardcoded (S2.3)');
        like($gather_block, qr/_gather_resources\s*\(\s*\)/,
            'AC-30: the gather closure calls _gather_resources() (B30)');
        my $n = () = $gather_block =~ /_gather_resources\s*\(/g;
        is($n, 1, 'AC-30: _gather_resources() appears exactly once as a call site in the gather closure (B30)');
        unlike($gather_block, qr/>=\s*23\b/,
            'AC-30: the gather closure does not hardcode 23 -- interval() is the single source of truth (S2.3)');
    } else {
        fail('AC-30: the gather closure calls Resources::should_sample (B30)');
        fail('AC-30: the gather closure passes Resources::interval() (S2.3)');
        fail('AC-30: the gather closure calls _gather_resources() (B30)');
        fail('AC-30: _gather_resources() appears exactly once in the gather closure (B30)');
        fail('AC-30: the gather closure does not hardcode 23 (S2.3)');
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
    like($dash, qr/\bsub\s+_token_lines\b/, 'AC-31: Dashboard.pm still defines sub _token_lines (B34)');
    like($dash, qr/title\s*=>\s*'Token'/,   "AC-31: Dashboard.pm still pushes the 'Token' panel (B34)");
    like($dash, qr/\bsub\s+_backpack_lines\b/, 'AC-31: Dashboard.pm still defines sub _backpack_lines (B34)');
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

done_testing();
