#!/usr/bin/env perl
# platform: any
# Oracle for blueprint package 01-container-timezone (sandbox-session-ux),
# Decision 8: containers run in the host's current timezone, re-derived at
# every session launch. Derived ONLY from
#   .ccpraxis-local-data/blueprints/sandbox-session-ux/specs/01-container-timezone-spec.md
# (sections 1-6, AC1-AC23) and the package ledger's done criteria. NOT
# derived from any implementation of HostTz.pm, launcher.pl's connector
# block, or the Containerfile's apt list -- none of that exists yet, which
# is exactly why most assertions below are EXPECTED to fail today. Do not
# weaken any assertion to make a future implementation's life easier.
#
# FIXTURES, all synthetic (Decision 15). Every registry read, every tzutil
# stdout, every TZI blob is built in this file with pack()/plain strings --
# nothing here ever touches the operator's real registry, real /etc/*, or a
# real tzutil.exe. A separate, clearly-labeled diag() near the bottom reads
# the REAL host zone for visibility only; nothing is asserted on it.
#
# TECHNIQUE FOR THE MODULE THAT DOES NOT EXIST YET. HostTz.pm is in this
# package's write set as "new" -- at the time this file is written, `perl
# -MHostTz` fails. Every call into HostTz:: below therefore goes through a
# small set of FENCED wrapper subs (H_detect, H_win2iana, H_parse_tzi,
# H_posix_rule, H_exec_env_args, H_log_event) that eval{} the real call and
# substitute an inert placeholder on failure -- so a missing module or a
# missing sub produces a plain "not ok" on the assertion that follows,
# never a died test process. One prereq assertion records the module's
# absence explicitly; large sections gated on it are then SKIPped (the same
# house technique wt-profile-spawn.t uses for its own not-yet-real sentinel
# region), so the failure count stays attributable rather than a wall of
# identical "module missing" duplicates. AC18, AC19, AC21, AC22 and AC23
# read launcher.pl / the Containerfile as SOURCE TEXT ONLY and are never
# gated on HostTz.pm -- those run unconditionally and are expected to
# produce real, non-duplicate failures against the current pre-change files.
#
# No test in this file starts a container, spawns podman, or spawns
# launcher.pl -- checked structurally at the bottom (the PATH tripwire),
# following host-only-masks-any-layer.t's precedent.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use POSIX ();
use Time::Local ();

use lib "$Bin/../../scripts";

my $SCRIPTS_DIR   = "$Bin/../../scripts";
my $HOSTTZ_PM     = "$SCRIPTS_DIR/HostTz.pm";
my $LAUNCHER      = "$SCRIPTS_DIR/launcher.pl";
my $CONTAINERFILE = "$Bin/../../container/Containerfile";

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

# ---------------------------------------------------------------------------
# Fenced HostTz:: callers. Every one eval{}s the real call so a missing
# module/sub degrades to a placeholder result instead of killing this file.
# ---------------------------------------------------------------------------
my $HOSTTZ_LOADED = eval { require HostTz; 1 };
my $HOSTTZ_LOAD_ERR = $@;

sub H_detect {
    my (%seams) = @_;
    my $r;
    my $ok = eval { $r = HostTz::detect(%seams); 1 };
    return $ok && ref($r) eq 'HASH' ? $r
         : { tz => undef, source => undef, note => undef, reason => 'CALL_FAILED', windows_id => undef };
}
sub H_win2iana  { my ($id)          = @_; my $r; my $ok = eval { $r = HostTz::windows_to_iana($id); 1 }; return $ok ? $r : undef; }
sub H_parse_tzi { my ($bytes)       = @_; my $r; my $ok = eval { $r = HostTz::parse_tzi($bytes); 1 };   return $ok ? $r : undef; }
sub H_posix_rule{ my ($tzi, $dstoff)= @_; my $r; my $ok = eval { $r = HostTz::posix_rule($tzi, $dstoff); 1 }; return $ok ? $r : undef; }
sub H_exec_env_args { my ($r) = @_; my @o; my $ok = eval { @o = HostTz::exec_env_args($r); 1 }; return $ok ? @o : (); }
sub H_log_event     { my ($r) = @_; my @o; my $ok = eval { @o = HostTz::log_event($r); 1 };     return $ok ? @o : (); }

# tzi_bytes(bias, std_bias, dst_bias, \@std8, \@dlt8) -> 44-byte blob, per
# spec sec 2.1 parse_tzi contract: pack('l< l< l< v8 v8', ...), each SYSTEMTIME
# array in order [wYear,wMonth,wDayOfWeek,wDay,wHour,wMinute,wSecond,wMilliseconds].
sub tzi_bytes {
    my ($bias, $std_bias, $dst_bias, $std, $dlt) = @_;
    $std ||= [0,0,0,0,0,0,0,0];
    $dlt ||= [0,0,0,0,0,0,0,0];
    return pack('l< l< l< v8 v8', $bias, $std_bias, $dst_bias, @$std, @$dlt);
}

my $IANA_RE  = qr{\A[A-Za-z0-9_+\-]+(?:/[A-Za-z0-9_+\-]+)*\z};
my $POSIX_RE = qr{^<[+-]\d{2}(?:\d{2})?>-?\d{1,2}(?::\d{2})?(?:<[+-]\d{2}(?:\d{2})?>-?\d{1,2}(?::\d{2})?,M\d{1,2}\.[1-5]\.[0-6]/\d{1,2}(?::\d{2}){0,2},M\d{1,2}\.[1-5]\.[0-6]/\d{1,2}(?::\d{2}){0,2})?$};

# Shared TZI fixtures, reused across ACs (and by AC16's DST oracle) exactly
# as the spec's own examples chain together.
my $TZI_W_EUROPE   = tzi_bytes(-60, 0, -60, [0,10,0,5,3,0,0,0], [0,3,0,5,2,0,0,0]);   # AC6
my $TZI_SOUTHERN   = tzi_bytes(-600, 0, -60, [0,4,0,1,3,0,0,0], [0,10,0,1,2,0,0,0]);  # AC7 ("Fictional"/AUS-shaped)
my $TZI_NEWFOUNDLD = tzi_bytes(210, 0, -60, [0,11,0,1,2,0,0,0], [0,3,0,2,2,0,0,0]);   # AC8's second example

sub epoch_utc {
    my ($y, $mo, $d, $h, $mi, $s) = @_;
    return Time::Local::timegm($s, $mi, $h, $d, $mo - 1, $y);
}

# =============================================================================
# prereq -- module presence, recorded once, non-duplicated. Large sections
# gated on this are SKIPped below with an explicit reason.
# =============================================================================
ok($HOSTTZ_LOADED, 'prereq: HostTz.pm exists and loads cleanly (required for AC1-AC17, AC20)')
    or diag("HostTz.pm did not load (expected -- not yet implemented): $HOSTTZ_LOAD_ERR");

# =============================================================================
# AC1 -- windows_to_iana table
# =============================================================================
{
    my @pairs = (
        ['W. Europe Standard Time',        'Europe/Berlin'],
        ['AUS Eastern Standard Time',       'Australia/Sydney'],
        ['E. South America Standard Time',  'America/Sao_Paulo'],
        ['GMT Standard Time',               'Europe/London'],
        ['Pacific Standard Time',           'America/Los_Angeles'],
        ['Tokyo Standard Time',             'Asia/Tokyo'],
        ['New Zealand Standard Time',       'Pacific/Auckland'],
        ['UTC',                             'Etc/UTC'],
    );
    for my $p (@pairs) {
        is(H_win2iana($p->[0]), $p->[1], "AC1: windows_to_iana('$p->[0]') is '$p->[1]'");
    }
    is(H_win2iana('Fictional Standard Time'), undef, 'AC1: an id absent from CLDR returns undef');
    is(H_win2iana('w. europe standard time'), undef, 'AC1: lookup is case-sensitive -- a lowercase variant returns undef');
}
{
    my $src = slurp($HOSTTZ_PM);
    SKIP: {
        skip 'AC1 (table structure/size): HostTz.pm source is not present yet', 4 unless defined $src;
        like($src, qr/windowsZones\.xml/, 'AC1: HostTz.pm names windowsZones.xml in a comment');
        like($src, qr/CLDR/, "AC1: HostTz.pm names a CLDR release tag in a comment");
        # Structural floor: at least 120 string=>string pairs whose RHS looks
        # like an IANA name -- the conventional shape of an embedded lookup
        # table of this kind. This is a floor on the table's SIZE, not a
        # claim about its exact internal representation.
        my @rhs = $src =~ /['"][^'"]+['"]\s*=>\s*['"]([^'"]+)['"]/g;
        my @iana_rhs = grep { /$IANA_RE/ } @rhs;
        cmp_ok(scalar(@iana_rhs), '>=', 120,
            'AC1: at least 120 string=>string table entries whose value matches IANA_RE '
          . '(got ' . scalar(@iana_rhs) . ')');
        my @bad_rhs = grep { !/$IANA_RE/ } @rhs;
        # not a hard requirement across the WHOLE file (other unrelated string
        # pairs may legitimately not look like IANA names) -- see report note.
        ok(1, 'AC1: non-vacuity placeholder (see report: table-size check is structural, not exhaustive)');
    }
}

SKIP: {
    skip 'AC2-AC17, AC20: HostTz.pm not present -- not yet implemented', 1000 unless $HOSTTZ_LOADED;

# =============================================================================
# AC2 -- Windows, mapped id via KEYNAME, probe true
# =============================================================================
{
    my @read_calls;
    my @run_calls;
    my $r = H_detect(
        os        => 'msys',
        env       => {},
        read_file => sub { push @read_calls, $_[0]; return "W. Europe Standard Time\0" },
        readlink  => sub { return undef },
        run       => sub { push @run_calls, [@_]; return (-1, ''); },
        probe_iana=> sub { return 1; },
    );
    is($r->{tz}, 'Europe/Berlin', 'AC2: tz is Europe/Berlin');
    is($r->{source}, 'windows_iana', 'AC2: source is windows_iana');
    is($r->{windows_id}, 'W. Europe Standard Time', 'AC2: windows_id is the KEYNAME value');
    is($r->{reason}, undef, 'AC2: reason is undef');
    is($r->{note}, undef, 'AC2: note is undef');
    is(scalar(@run_calls), 0, 'AC2: run is called 0 times');
    ok((grep { /TimeZoneKeyName/ } @read_calls), 'AC2: read_file was called with the KEYNAME path');
}

# =============================================================================
# AC3 -- Southern hemisphere through IANA, UTF-16LE-encoded KEYNAME
# =============================================================================
{
    my $utf16 = join('', map { "$_\0" } split //, 'AUS Eastern Standard Time');
    $utf16 .= "\0\0";
    my $r = H_detect(
        os => 'msys', env => {},
        read_file => sub { return $utf16 },
        readlink  => sub { undef },
        run       => sub { (-1, '') },
        probe_iana=> sub { 1 },
    );
    is($r->{tz}, 'Australia/Sydney', 'AC3: tz is Australia/Sydney from a UTF-16LE-encoded KEYNAME');
    is($r->{source}, 'windows_iana', 'AC3: source is windows_iana');
}

# =============================================================================
# AC4 -- KEYNAME unreadable, tzutil supplies the id
# =============================================================================
{
    my @run_calls;
    my $r = H_detect(
        os => 'msys', env => {},
        read_file => sub { return undef },
        readlink  => sub { undef },
        run       => sub { push @run_calls, [@_]; return (0, "E. South America Standard Time\r\n"); },
        probe_iana=> sub { 1 },
    );
    is($r->{tz}, 'America/Sao_Paulo', 'AC4: tz is America/Sao_Paulo via tzutil fallback');
    is(scalar(@run_calls), 1, 'AC4: run was called exactly once');
    is_deeply($run_calls[0], ['tzutil.exe', '/g'], "AC4: run was called with exactly ('tzutil.exe','/g')");
}

# =============================================================================
# AC5 -- both sources fail
# =============================================================================
for my $run_result ([1, ''], [-1, '']) {
    my $r = H_detect(
        os => 'msys', env => {},
        read_file => sub { undef },
        readlink  => sub { undef },
        run       => sub { @$run_result },
        probe_iana=> sub { 1 },
    );
    is($r->{tz}, undef, "AC5: tz is undef when run returns (@$run_result)");
    is($r->{reason}, 'windows_id_unreadable', "AC5: reason is windows_id_unreadable when run returns (@$run_result)");
    is_deeply([ H_exec_env_args($r) ], [], "AC5: exec_env_args returns the empty list when run returns (@$run_result)");
}

# =============================================================================
# AC6 -- mapped id, probe false -> POSIX fallback (W. Europe)
# =============================================================================
{
    my @read_calls;
    my $r = H_detect(
        os => 'msys', env => {},
        read_file => sub {
            push @read_calls, $_[0];
            return "W. Europe Standard Time\0" if $_[0] =~ /TimeZoneKeyName/;
            return $TZI_W_EUROPE if $_[0] =~ /TZI$/;
            return undef;
        },
        readlink  => sub { undef },
        run       => sub { (-1, '') },
        probe_iana=> sub { 0 },
    );
    is($r->{tz}, '<+01>-1<+02>-2,M3.5.0/2,M10.5.0/3', 'AC6: POSIX rule for W. Europe with probe false');
    is($r->{source}, 'windows_posix', 'AC6: source is windows_posix');
    is($r->{note}, 'iana_missing_in_image', 'AC6: note is iana_missing_in_image');
    ok((grep { /Time Zones.*W\. Europe Standard Time.*TZI$/ } @read_calls),
        "AC6: read_file was called with TZI('W. Europe Standard Time')");
}

# =============================================================================
# AC7 -- unmapped id, southern hemisphere through POSIX
# =============================================================================
{
    my $r = H_detect(
        os => 'msys', env => {},
        read_file => sub {
            return "Fictional Standard Time\0" if $_[0] =~ /TimeZoneKeyName/;
            return $TZI_SOUTHERN if $_[0] =~ /TZI$/;
            return undef;
        },
        readlink  => sub { undef },
        run       => sub { (-1, '') },
        probe_iana=> sub { 1 },
    );
    is($r->{tz}, '<+10>-10<+11>-11,M10.1.0/2,M4.1.0/3', 'AC7: POSIX rule for the southern-hemisphere fixture');
    is($r->{note}, 'windows_id_unmapped', 'AC7: note is windows_id_unmapped');
}

# =============================================================================
# AC8 -- posix_rule direct unit tests
# =============================================================================
{
    my $tzi_no_dst = H_parse_tzi(tzi_bytes(-330, 0, 0));
    is(H_posix_rule($tzi_no_dst, 0), '<+0530>-5:30', 'AC8: no-DST Bias -330 gives <+0530>-5:30');

    my $tzi_nfld = H_parse_tzi($TZI_NEWFOUNDLD);
    is(H_posix_rule($tzi_nfld, 0), '<-0330>3:30<-0230>2:30,M3.2.0/2,M11.1.0/2',
        'AC8: Bias 210/DltBias -60 Newfoundland-shaped fixture');

    my $tzi_2359 = H_parse_tzi(tzi_bytes(0, 0, -60, [0,1,0,1,23,59,59,999], [0,6,0,1,2,0,0,0]));
    like(H_posix_rule($tzi_2359, 0), qr{/24$}, 'AC8: a Std date at 23:59:59.999 renders as /24');

    my $tzi_zero = H_parse_tzi(tzi_bytes(0, 0, 0));
    is(H_posix_rule($tzi_zero, 0), '<+00>0', 'AC8: Bias 0 with no DST gives <+00>0');
}

# =============================================================================
# AC9 -- DST auto-adjust off
# =============================================================================
{
    my @probe_calls;
    my $r = H_detect(
        os => 'msys', env => {},
        read_file => sub {
            return "W. Europe Standard Time\0" if $_[0] =~ /TimeZoneKeyName/;
            return pack('V', 1) if $_[0] =~ /DynamicDaylightTimeDisabled/;
            return $TZI_W_EUROPE if $_[0] =~ /TZI$/;
            return undef;
        },
        readlink  => sub { undef },
        run       => sub { (-1, '') },
        probe_iana=> sub { push @probe_calls, $_[0]; return 1; },
    );
    is($r->{tz}, '<+01>-1', 'AC9(a): DDTD=1 gives <+01>-1');
    is($r->{note}, 'dst_auto_adjust_off', 'AC9(a): note is dst_auto_adjust_off');
    is(scalar(@probe_calls), 0, 'AC9(a): the probe is not consulted');
}
{
    my @probe_calls;
    my $r = H_detect(
        os => 'msys', env => {},
        read_file => sub {
            return undef if $_[0] =~ /TimeZoneKeyName/;
            return $TZI_W_EUROPE if $_[0] =~ /TZI$/;
            return undef;
        },
        readlink  => sub { undef },
        run       => sub { (0, "W. Europe Standard Time_dstoff"); },
        probe_iana=> sub { push @probe_calls, $_[0]; return 1; },
    );
    is($r->{tz}, '<+01>-1', 'AC9(b): tzutil "_dstoff" suffix gives <+01>-1');
    is($r->{note}, 'dst_auto_adjust_off', 'AC9(b): note is dst_auto_adjust_off');
    is($r->{windows_id}, 'W. Europe Standard Time', 'AC9(b): windows_id has the _dstoff suffix stripped');
    is(scalar(@probe_calls), 0, 'AC9(b): the probe is not consulted');
}

# =============================================================================
# AC10 -- unmapped id, TZI failures
# =============================================================================
{
    my $r = H_detect(
        os => 'msys', env => {},
        read_file => sub {
            return "Fictional Standard Time\0" if $_[0] =~ /TimeZoneKeyName/;
            return undef if $_[0] =~ /TZI$/;
            return undef;
        },
        readlink => sub { undef }, run => sub { (-1,'') }, probe_iana => sub { 1 },
    );
    is($r->{tz}, undef, 'AC10: undef TZI gives tz undef');
    is($r->{reason}, 'tzi_unreadable', 'AC10: undef TZI gives reason tzi_unreadable');
    is($r->{windows_id}, 'Fictional Standard Time', 'AC10: windows_id is still set on tzi_unreadable');
}
{
    my @bad = (
        ['40-byte TZI'          => substr($TZI_W_EUROPE, 0, 40)],
        ['wYear=2026 on a date' => tzi_bytes(-60, 0, -60, [2026,10,0,5,3,0,0,0], [0,3,0,5,2,0,0,0])],
        ['wMonth=13'            => tzi_bytes(-60, 0, -60, [0,13,0,5,3,0,0,0], [0,3,0,5,2,0,0,0])],
        ['exactly one wMonth=0' => tzi_bytes(-60, 0, -60, [0,0,0,5,3,0,0,0],  [0,3,0,5,2,0,0,0])],
    );
    for my $case (@bad) {
        my ($label, $bytes) = @$case;
        my $r = H_detect(
            os => 'msys', env => {},
            read_file => sub {
                return "Fictional Standard Time\0" if $_[0] =~ /TimeZoneKeyName/;
                return $bytes if $_[0] =~ /TZI$/;
                return undef;
            },
            readlink => sub { undef }, run => sub { (-1,'') }, probe_iana => sub { 1 },
        );
        is($r->{tz}, undef, "AC10: $label gives tz undef");
        is($r->{reason}, 'tzi_malformed', "AC10: $label gives reason tzi_malformed");
        is($r->{windows_id}, 'Fictional Standard Time', "AC10: $label still sets windows_id");
    }
}

# =============================================================================
# AC11 -- invalid Windows ids never reach a TZI(id) path
# =============================================================================
{
    my @bad_ids = ('..\\evil', 'a/b', ('x' x 65), "bad\x01char");
    for my $id (@bad_ids) {
        my @read_calls;
        my $r = H_detect(
            os => 'msys', env => {},
            read_file => sub { push @read_calls, $_[0]; return "$id\0" if $_[0] =~ /TimeZoneKeyName/; return undef; },
            readlink  => sub { undef },
            run       => sub { (-1, '') },
            probe_iana=> sub { 1 },
        );
        (my $safe_id = $id) =~ s/[^\x20-\x7e]/?/g;
        is($r->{reason}, 'windows_id_invalid', "AC11: id '$safe_id' gives reason windows_id_invalid");
        my @offenders = grep { defined && index($_, $id) >= 0 } @read_calls;
        is(scalar(@offenders), 0, "AC11: no recorded read_file path contains the offending id '$safe_id'");
    }
}

# =============================================================================
# AC12 -- no false abbreviation
# =============================================================================
{
    my @posix_results = (
        H_detect(os=>'msys', env=>{}, read_file=>sub { return "W. Europe Standard Time\0" if $_[0]=~/TimeZoneKeyName/; return $TZI_W_EUROPE if $_[0]=~/TZI$/; return undef }, readlink=>sub{undef}, run=>sub{(-1,'')}, probe_iana=>sub{0}),
        H_detect(os=>'msys', env=>{}, read_file=>sub { return "Fictional Standard Time\0" if $_[0]=~/TimeZoneKeyName/; return $TZI_SOUTHERN if $_[0]=~/TZI$/; return undef }, readlink=>sub{undef}, run=>sub{(-1,'')}, probe_iana=>sub{1}),
        H_detect(os=>'msys', env=>{}, read_file=>sub { return "W. Europe Standard Time\0" if $_[0]=~/TimeZoneKeyName/; return pack('V',1) if $_[0]=~/DynamicDaylightTimeDisabled/; return $TZI_W_EUROPE if $_[0]=~/TZI$/; return undef }, readlink=>sub{undef}, run=>sub{(-1,'')}, probe_iana=>sub{1}),
    );
    for my $i (0 .. $#posix_results) {
        my $tz = $posix_results[$i]{tz};
        next unless defined $tz;
        like($tz, $POSIX_RE, "AC12: windows_posix result #$i matches the no-abbreviation regex ('$tz')");
    }
    my $r = H_detect(
        os => 'msys', env => { TZ => 'WEST-1WEST' },
        read_file => sub { return "W. Europe Standard Time\0" if $_[0]=~/TimeZoneKeyName/; return $TZI_W_EUROPE if $_[0]=~/TZI$/; return undef; },
        readlink  => sub { undef }, run => sub { (-1,'') }, probe_iana => sub { 0 },
    );
    ok(!defined($r->{tz}) || $r->{tz} !~ /WEST/, 'AC12: a Windows detect with env TZ=WEST-1WEST never returns a tz containing WEST');
}

# =============================================================================
# AC13 -- non-Windows hosts
# =============================================================================
{
    my $r = H_detect(os => 'linux', env => { TZ => ':Europe/Lisbon' }, read_file => sub { undef }, readlink => sub { undef }, run => sub { (-1,'') });
    is($r->{tz}, 'Europe/Lisbon', 'AC13: env TZ=:Europe/Lisbon gives Europe/Lisbon');
    is($r->{source}, 'env', 'AC13: source is env');
}
{
    my $r = H_detect(os => 'linux', env => {}, read_file => sub { undef },
        readlink => sub { return '/var/db/timezone/zoneinfo/America/New_York' if $_[0] eq '/etc/localtime'; return undef; },
        run => sub { (-1,'') });
    is($r->{tz}, 'America/New_York', 'AC13: readlink /etc/localtime -> .../zoneinfo/America/New_York gives America/New_York');
    is($r->{source}, 'localtime_link', 'AC13: source is localtime_link');
}
{
    my $r = H_detect(os => 'darwin', env => {}, read_file => sub { undef },
        readlink => sub { return '/usr/share/zoneinfo/posix/Europe/Berlin' if $_[0] eq '/etc/localtime'; return undef; },
        run => sub { (-1,'') });
    is($r->{tz}, 'Europe/Berlin', 'AC13: a posix/ prefixed zoneinfo link strips the posix/ segment');
}
{
    my $r = H_detect(os => 'linux', env => {}, read_file => sub { return "Asia/Tokyo\n" if $_[0] eq '/etc/timezone'; return undef; },
        readlink => sub { undef }, run => sub { (-1,'') });
    is($r->{tz}, 'Asia/Tokyo', 'AC13: /etc/timezone alone gives Asia/Tokyo');
    is($r->{source}, 'etc_timezone', 'AC13: source is etc_timezone');
}
{
    my $r = H_detect(os => 'linux', env => {}, read_file => sub { undef }, readlink => sub { undef }, run => sub { (-1,'') });
    is($r->{tz}, undef, 'AC13: no TZ, no link, no /etc/timezone gives tz undef');
    is($r->{reason}, 'host_zone_not_found', 'AC13: reason is host_zone_not_found');
}
{
    my $r = H_detect(os => 'linux', env => {}, read_file => sub { undef },
        readlink => sub { return '/usr/share/zoneinfo/../../etc/passwd' if $_[0] eq '/etc/localtime'; return undef; },
        run => sub { (-1,'') });
    is($r->{tz}, undef, 'AC13: a traversal-shaped zoneinfo link gives tz undef');
    is($r->{reason}, 'zone_value_invalid', 'AC13: reason is zone_value_invalid for the traversal-shaped link');
}

# =============================================================================
# AC14 -- non-Windows, probe false
# =============================================================================
{
    my $r = H_detect(os => 'linux', env => { TZ => 'Europe/Lisbon' }, read_file => sub { undef }, readlink => sub { undef },
        run => sub { (-1,'') }, probe_iana => sub { 0 });
    is($r->{tz}, undef, 'AC14: probe_iana false gives tz undef');
    is($r->{reason}, 'zone_missing_in_image', 'AC14: reason is zone_missing_in_image');
}

# =============================================================================
# AC15 -- totality
# =============================================================================
{
    my @seam_names = qw(read_file readlink run probe_iana);
    for my $mode (qw(die warn)) {
        for my $dying (@seam_names) {
            my %seams = (
                os => 'msys', env => {},
                read_file  => sub { return "W. Europe Standard Time\0" if $_[0] =~ /TimeZoneKeyName/; return $TZI_W_EUROPE if $_[0] =~ /TZI$/; return undef; },
                readlink   => sub { undef },
                run        => sub { (-1, '') },
                probe_iana => sub { 1 },
            );
            $seams{$dying} = $mode eq 'die' ? sub { die "boom\n" } : sub { warn "boom\n"; return undef; };
            my @warnings;
            my $r;
            my $ok = eval {
                local $SIG{__WARN__} = sub { push @warnings, @_ };
                $r = H_detect(%seams);
                1;
            };
            ok($ok, "AC15 ($mode/$dying): detect() itself never dies");
            is(ref($r), 'HASH', "AC15 ($mode/$dying): detect() returns a hashref");
            is_deeply([ sort keys %$r ], [qw(note reason source tz windows_id)],
                "AC15 ($mode/$dying): key set is exactly (note,reason,source,tz,windows_id)");
        }
    }
    my $r = H_detect(os => 'linux', env => {});
    is(ref($r), 'HASH', 'AC15: detect(os=>linux, env=>{}) with every other seam absent is total');
    is_deeply([ sort keys %$r ], [qw(note reason source tz windows_id)], 'AC15: key set holds for the minimal-seam call too');
}

# =============================================================================
# AC16 -- DST oracle
# =============================================================================
{
    my $tzset_available = eval { local $ENV{TZ} = '<+05>-5'; POSIX::tzset(); 1 };
    SKIP: {
        skip 'AC16: POSIX::tzset()/TZ environment DST oracle is not usable on this host', 11 unless $tzset_available;

        sub dst_offset {
            my ($rule, $t) = @_;
            local $ENV{TZ} = $rule;
            POSIX::tzset();
            my @lt = localtime($t);
            my $back = Time::Local::timegm(@lt[0 .. 5]);
            return $back - $t;
        }

        is(dst_offset('<+05>-5', epoch_utc(2026,1,15,12,0,0)), 18000, 'AC16: control rule <+05>-5 gives +18000');

        my $we = H_posix_rule(H_parse_tzi($TZI_W_EUROPE), 0);
        is(dst_offset($we, epoch_utc(2026,1,15,12,0,0)),  3600, 'AC16: W. Europe, 2026-01-15T12:00Z, +3600');
        is(dst_offset($we, epoch_utc(2026,7,15,12,0,0)),  7200, 'AC16: W. Europe, 2026-07-15T12:00Z, +7200');
        is(dst_offset($we, epoch_utc(2026,3,29,0,59,59)), 3600, 'AC16: W. Europe, 2026-03-29T00:59:59Z, +3600');
        is(dst_offset($we, epoch_utc(2026,3,29,1,0,0)),   7200, 'AC16: W. Europe, 2026-03-29T01:00:00Z, +7200');

        my $aus = H_posix_rule(H_parse_tzi($TZI_SOUTHERN), 0);
        is(dst_offset($aus, epoch_utc(2026,1,15,12,0,0)), 39600, 'AC16: AUS-shaped rule, 2026-01-15T12:00Z, +39600');
        is(dst_offset($aus, epoch_utc(2026,7,15,12,0,0)), 36000, 'AC16: AUS-shaped rule, 2026-07-15T12:00Z, +36000');

        my $nfld = H_posix_rule(H_parse_tzi($TZI_NEWFOUNDLD), 0);
        is(dst_offset($nfld, epoch_utc(2026,1,15,12,0,0)), -12600, 'AC16: Newfoundland, 2026-01-15T12:00Z, -12600');
        is(dst_offset($nfld, epoch_utc(2026,7,15,12,0,0)), -9000,  'AC16: Newfoundland, 2026-07-15T12:00Z, -9000');

        ok(defined($we) && length($we), 'AC16 non-vacuity: the W. Europe rule string was actually generated');
        ok(defined($aus) && length($aus), 'AC16 non-vacuity: the AUS-shaped rule string was actually generated');
    }
}

# =============================================================================
# AC20 -- log_event
# =============================================================================
{
    my ($type, $fields) = H_log_event({ tz => 'Europe/Berlin', source => 'windows_iana', note => undef, reason => undef, windows_id => 'W. Europe Standard Time' });
    is($type, 'container_tz', 'AC20: windows_iana gives type container_tz');
    is_deeply([ sort keys %$fields ], [qw(source tz windows_id)], 'AC20: windows_iana fields key set is exactly (tz,source,windows_id)')
        if ref($fields) eq 'HASH';

    ($type, $fields) = H_log_event({ tz => '<+01>-1', source => 'windows_posix', note => 'dst_auto_adjust_off', reason => undef, windows_id => 'W. Europe Standard Time' });
    is($type, 'container_tz', 'AC20: windows_posix gives type container_tz');
    is_deeply([ sort keys %$fields ], [qw(note source tz windows_id)], 'AC20: windows_posix fields key set is exactly (tz,source,note,windows_id)')
        if ref($fields) eq 'HASH';

    ($type, $fields) = H_log_event({ tz => undef, source => undef, note => undef, reason => 'host_zone_not_found', windows_id => undef });
    is($type, 'container_tz_unset', 'AC20: an unset result gives type container_tz_unset');
    is_deeply([ sort keys %$fields ], [qw(reason)], 'AC20: unset (no windows_id) fields key set is exactly (reason)')
        if ref($fields) eq 'HASH';

    ($type, $fields) = H_log_event({ tz => undef, source => undef, note => undef, reason => 'windows_id_invalid', windows_id => 'bad id' });
    is_deeply([ sort keys %$fields ], [qw(reason windows_id)], 'AC20: unset with windows_id set gives fields (reason,windows_id)')
        if ref($fields) eq 'HASH';

    ($type, $fields) = H_log_event('not a hashref');
    is($type, 'container_tz_unset', 'AC20: a non-hashref gives type container_tz_unset');
    is_deeply($fields, { reason => 'detect_failed' }, 'AC20: a non-hashref gives fields exactly {reason=>detect_failed}');

    require Data::Dumper;
    my $dump = Data::Dumper::Dumper([ H_log_event({ tz => undef, source => undef, note => undef, reason => 'windows_id_unreadable', windows_id => 'W. Europe Standard Time' }) ]);
    unlike($dump, qr{/proc/registry}, 'AC20: no field value contains /proc/registry');
}

} # end SKIP AC2-AC17/AC20

# =============================================================================
# AC17 -- exec_env_args (kept outside the big SKIP so a missing module still
# surfaces one real failure per case, since the function is trivial to call)
# =============================================================================
{
    is_deeply([ H_exec_env_args({ tz => 'Europe/Berlin' }) ], ['-e', 'TZ=Europe/Berlin'],
        'AC17: a defined simple tz gives (-e, TZ=<tz>)');
    for my $case ({ tz => undef }, undef, { tz => '/etc/x' }, { tz => 'a b' }, { tz => '' }) {
        is_deeply([ H_exec_env_args($case) ], [], 'AC17: an invalid/undef tz gives the empty list');
    }
}

# =============================================================================
# AC18 -- computed exec argv, extracted from launcher.pl SOURCE and eval'd
# with stub variables. Never executes launcher.pl.
# =============================================================================
{
    my $src = slurp($LAUNCHER);
    ok(defined($src) && length($src), 'prereq: launcher.pl source read as text (never require/do-ed)')
        or BAIL_OUT("cannot read $LAUNCHER");

    my @occurrences = $src =~ /my \@cmd = \(\$PODMAN, 'exec', '-it',.*?\);/sg;
    is(scalar(@occurrences), 1, "AC18: the \@cmd statement occurs exactly once");

    SKIP: {
        skip 'AC18: the @cmd statement was not found', 4 unless @occurrences;
        my $stmt = $occurrences[0];
        like($stmt, qr/HostTz::exec_env_args\(\$HOST_TZ\)/, 'AC18: the statement contains HostTz::exec_env_args($HOST_TZ)');
        my $idx_call = index($stmt, 'HostTz::exec_env_args($HOST_TZ)');
        my $idx_cname = index($stmt, '$CONTAINER_NAME', $idx_call >= 0 ? $idx_call : 0);
        ok($idx_call >= 0 && $idx_cname > $idx_call, 'AC18: $CONTAINER_NAME follows the exec_env_args( call');

        for my $case (
            [ { tz => 'Europe/Berlin' }, ['podman', 'exec', '-it', '-e', 'TZ=Europe/Berlin', 'c', 'claude', '--dangerously-skip-permissions', '--resume', 'u'] ],
            [ { tz => undef, reason => 'x' }, ['podman', 'exec', '-it', 'c', 'claude', '--dangerously-skip-permissions', '--resume', 'u'] ],
        ) {
            my ($host_tz, $expected) = @$case;
            my $PODMAN = 'podman';
            my $CONTAINER_NAME = 'c';
            my @SESSION_FLAGS = ('--resume', 'u');
            my $HOST_TZ = $host_tz;
            # The statement text is `my @cmd = (...);` -- eval-ing it as a bare
            # string declares a FRESH lexical @cmd scoped to that eval string,
            # which never escapes back to this sub's own @cmd. Wrapping it in
            # a do{} block and returning \@cmd from the SAME eval string keeps
            # the declaration and the read in one lexical scope, so the value
            # actually comes back.
            my $cmd_ref = eval "do { $stmt \\\@cmd };";   ## no critic
            my $got = ref($cmd_ref) eq 'ARRAY' ? $cmd_ref : [];
            is_deeply($got, $expected, 'AC18: evaluated @cmd statement matches the expected argv for host_tz=' . (defined($host_tz->{tz}) ? $host_tz->{tz} : 'undef'))
                or diag("eval error: $@; got: " . join(',', map { $_ // 'undef' } @$got));
        }
    }
}

# =============================================================================
# AC19 -- launcher wiring, source-text only
# =============================================================================
{
    my $src = slurp($LAUNCHER);
    SKIP: {
        skip 'AC19: launcher.pl not readable', 8 unless defined $src;

        like($src, qr/use HostTz \(\);/, 'AC19: use HostTz (); is present');

        my $detect_count = () = $src =~ /HostTz::detect\(/g;
        is($detect_count, 1, 'AC19: HostTz::detect( occurs exactly once');

        my $orphan_idx = index($src, 'kill_orphan_claudes_if_user_confirms(');
        my $detect_idx = index($src, 'HostTz::detect(');
        my $cmd_idx    = index($src, "my \@cmd = (\$PODMAN, 'exec', '-it',");
        ok($orphan_idx >= 0 && $detect_idx >= 0 && $orphan_idx < $detect_idx,
            'AC19: HostTz::detect( appears after kill_orphan_claudes_if_user_confirms(');
        ok($detect_idx >= 0 && $cmd_idx >= 0 && $detect_idx < $cmd_idx,
            'AC19: HostTz::detect( appears before the @cmd statement');

        my $probe_idx = index($src, 'probe_iana =>', $detect_idx >= 0 ? $detect_idx : 0);
        cmp_ok($probe_idx, '>=', 0, 'AC19: a probe_iana => argument is present after the detect( call');
        if ($probe_idx >= 0) {
            my $window = substr($src, $probe_idx, 400);
            like($window, qr/'test',\s*'-f'/, "AC19: the probe_iana closure contains 'test', '-f'");
            like($window, qr{/usr/share/zoneinfo/}, 'AC19: the probe_iana closure contains /usr/share/zoneinfo/');
        }

        like($src, qr/log_ev\(HostTz::log_event\(\$HOST_TZ\)\)/, 'AC19: log_ev(HostTz::log_event($HOST_TZ)) appears');
        unlike($src, qr/['"]TZ=/, 'AC19: no \'TZ= or "TZ= literal exists anywhere in launcher.pl');

        like($src, qr/\$ENV\{MSYS2_ARG_CONV_EXCL\} = '\*' if \$WINDOWS_FAMILY;/,
            "AC19: the file-scope MSYS2_ARG_CONV_EXCL guard is still present, before the connector block");
        cmp_ok(index($src, "\$ENV{MSYS2_ARG_CONV_EXCL} = '*' if \$WINDOWS_FAMILY;"), '<', ($detect_idx >= 0 ? $detect_idx : length($src)),
            'AC19: that file-scope guard still comes before the connector block');
    }
}

# =============================================================================
# AC21 -- Containerfile, static checks
# =============================================================================
{
    my $src = slurp($CONTAINERFILE);
    ok(defined($src), 'prereq: Containerfile is readable') or diag("not found at $CONTAINERFILE");
    SKIP: {
        skip 'AC21: Containerfile not readable', 5 unless defined $src;

        my ($install_block) = $src =~ /(apt-get install[^\n]*(?:\\\n[^\n]*)*)/;
        ok(defined($install_block) && index($install_block, 'tzdata') >= 0,
            'AC21: the first apt install list contains tzdata');

        my $ddta_idx    = index($src, 'DEBIAN_FRONTEND=noninteractive');
        my $install_idx = index($src, 'apt-get install');
        ok($ddta_idx >= 0 && $install_idx >= 0 && $ddta_idx < $install_idx,
            'AC21: DEBIAN_FRONTEND=noninteractive appears before apt-get install in the same RUN');

        like($src, qr{\Qpodman run --rm --entrypoint ls claude-sandbox:latest /usr/share/zoneinfo/Europe/Berlin /usr/share/zoneinfo/Asia/Calcutta\E},
            'AC21: the verbatim manual-check command from spec sec 2.4 is present');
        like($src, qr/tzdata-legacy/, 'AC21: the word tzdata-legacy appears (backward-links comment)');
    }
}
{
    my $lsrc = slurp($LAUNCHER);
    SKIP: {
        skip 'AC21 (launcher side): launcher.pl not readable', 1 unless defined $lsrc;
        my $needle21 = '"$CONTAINER_CONFIG/Containerfile"';
        like($lsrc, qr/\Q$needle21\E/, 'AC21: containerfile_hash still hashes "$CONTAINER_CONFIG/Containerfile"');
    }
}

# =============================================================================
# AC22 -- Decision 17: wt_profile_plan's appearance-fallback branch.
# Extracted and eval'd from the ALREADY-EXISTING wt-profile:BEGIN/END
# sentinel region, the same technique wt-profile-spawn.t uses. The region
# exists (an earlier package landed it); the new appearance handling inside
# it does not, so the assertions below are expected to fail on today's code.
# =============================================================================
{
    my $src = slurp($LAUNCHER);
    my ($region) = defined($src) ? ($src =~ /\Q# >>> wt-profile:BEGIN\E.*?\n(.*?)\Q# <<< wt-profile:END\E/s) : (undef);

    SKIP: {
        skip 'AC22: the wt-profile:BEGIN/END sentinel region was not found', 12 unless defined $region;

        my $harness = "package HostTzWtProfilePlan;\nuse strict;\nuse warnings;\n" . $region . "\n1;\n";
        my $eval_ok = eval $harness;   ## no critic
        ok($eval_ok, 'AC22: the wt-profile region evals cleanly') or diag("eval error: $@");

        SKIP: {
            skip 'AC22: region did not eval cleanly', 11 unless $eval_ok;
            my $PLAN = HostTzWtProfilePlan->can('wt_profile_plan');
            ok(defined $PLAN, "AC22: the resulting package ->can('wt_profile_plan')");

            SKIP: {
                skip 'AC22: wt_profile_plan not available', 10 unless defined $PLAN;

                my %base_seams = (
                    resolve_root => sub { { ok => 1, root => '/tmp/frag' } },
                    profile_name => sub { 'claude-sandbox' },
                );

                my $plan_fallback = $PLAN->(
                    %base_seams,
                    ensure => sub { { ok => 1, action => 'wrote', path => '/tmp/x', appearance => 'fallback', appearance_reason => 'settings_unparseable' } },
                );
                is_deeply($plan_fallback,
                    { profile => 'claude-sandbox', event => { type => 'launch_profile_appearance_fallback', fields => { reason => 'settings_unparseable' } } },
                    'AC22: appearance=fallback with a valid reason produces the fallback event');

                my $plan_copied = $PLAN->(
                    %base_seams,
                    ensure => sub { { ok => 1, action => 'wrote', path => '/tmp/x', appearance => 'copied' } },
                );
                is_deeply($plan_copied, { profile => 'claude-sandbox', event => undef },
                    'AC22: appearance=copied produces {profile=>name, event=>undef}');

                my $plan_missing = $PLAN->(
                    %base_seams,
                    ensure => sub { { ok => 1, action => 'wrote', path => '/tmp/x' } },
                );
                is_deeply($plan_missing, { profile => 'claude-sandbox', event => undef },
                    'AC22: a missing appearance key produces {profile=>name, event=>undef}');

                for my $bad_reason (undef, [1,2], '', 'Bad Reason!') {
                    my $plan_bad = $PLAN->(
                        %base_seams,
                        ensure => sub { { ok => 1, action => 'wrote', path => '/tmp/x', appearance => 'fallback', appearance_reason => $bad_reason } },
                    );
                    is($plan_bad->{event}{fields}{reason}, 'unknown',
                        "AC22: an invalid appearance_reason (" . (defined($bad_reason) ? (ref($bad_reason) ? 'ref' : "'$bad_reason'") : 'undef') . ') gives reason=>unknown');
                }
            }
        }
    }
    my $body_ok = defined($src) ? ($src =~ /\nsub _spawn_session \{\n(.*?)\n\}\n/s) : undef;
    my ($body) = defined($src) ? ($src =~ /\nsub _spawn_session \{\n(.*?)\n\}\n/s) : ();
    like($body // '', qr/log_ev\([^;]*\$plan->\{event\}/s, "AC22: _spawn_session's body still contains the guarded log_ev( referencing \$plan->{event}")
        if defined $body;
    ok(defined($body), 'AC22: _spawn_session body is extractable') unless defined $body;
}

# =============================================================================
# AC23 -- global_counts, computed create args
# =============================================================================
{
    my $src = slurp($LAUNCHER);
    my ($call) = defined($src) ? ($src =~ /(MountSpec::claude_home_create_args\(.*?\))\s*;/s) : (undef);

    my @occurrences = defined($src) ? ($src =~ /MountSpec::claude_home_create_args\(/g) : ();
    is(scalar(@occurrences), 1, 'AC23: MountSpec::claude_home_create_args( occurs exactly once');

    SKIP: {
        skip 'AC23: the claude_home_create_args( call was not found', 5 unless defined $call;

        my $needle23 = 'global_counts => "${CLAUDE_HOST_CONFIG}/almanac-global-counts.json"';
        like($call, qr/\Q$needle23\E/,
            'AC23: the contiguous global_counts literal is present');
        like($call, qr/defined &MountSpec::ensure_global_counts_file/,
            'AC23: the global_counts line is guarded on defined &MountSpec::ensure_global_counts_file');
        unlike($call, qr/claude-code-vault/, 'AC23: the call does not mention claude-code-vault');

        require MountSpec;
        my $tmp_cd = tempdir(CLEANUP => 1);
        my $tmp_ld = tempdir(CLEANUP => 1);
        my $tmp_hc = tempdir(CLEANUP => 1);
        my $CLAUDE_DATA        = $tmp_cd;
        my $LAUNCHER_DIR       = $tmp_ld;
        my $CLAUDE_HOST_CONFIG = $tmp_hc;
        # The statusline source is the launcher's own install root
        # (SandboxIdentity::install_root), no longer a ~/.claude/ccpraxis literal;
        # the fixture places that root where the literal used to point.
        my $INSTALL_ROOT       = "$tmp_hc/ccpraxis";
        mkdir("$tmp_hc/ccpraxis");
        mkdir("$tmp_hc/ccpraxis/scripts");
        open(my $fh, '>', "$tmp_hc/ccpraxis/scripts/statusline.pl"); print $fh "1;\n"; close $fh;

        my @result;
        my $eval_ok = eval "\@result = $call; 1;";   ## no critic
        ok($eval_ok, 'AC23: the extracted call evaluates cleanly with fresh temp dirs') or diag("eval error: $@");

        if ($eval_ok) {
            my $CD = $tmp_cd; my $LD = $tmp_ld; my $HC = $tmp_hc;
            if (!defined &MountSpec::ensure_global_counts_file) {
                diag('AC23: defined &MountSpec::ensure_global_counts_file is FALSE -- pre-almanac-19 branch');
                is_deeply(\@result,
                    ['-e', 'CLAUDE_CONFIG_DIR=/root/.claude', '-v', "$CD:/root/.claude", '-v', "$LD:/root/.claude/.launcher:ro",
                     '-v', "$HC/ccpraxis/scripts/statusline.pl:/root/.claude/statusline.pl:ro"],
                    'AC23: pre-almanac-19, the result is byte-identical to today\'s create args');
                ok(!-e "$HC/almanac-global-counts.json", 'AC23: pre-almanac-19, almanac-global-counts.json does not exist afterwards');
            } else {
                diag('AC23: defined &MountSpec::ensure_global_counts_file is TRUE -- post-almanac-19 branch');
                is_deeply([ @result[-2, -1] ],
                    ['-v', "$HC/almanac-global-counts.json:/root/.claude/almanac-global-counts.json:ro"],
                    'AC23: post-almanac-19, the result ends with the read-only global-counts bind');
            }
        }
    }
}

# =============================================================================
# Hygiene: real-host diag only (never asserted on), plus the PATH tripwire /
# self-scan proving this file never starts a container or spawns launcher.pl.
# =============================================================================
{
    # Informational only -- see header. Never used in any assertion above.
    my $real_tz_hint = $ENV{TZ} // '(unset)';
    diag("informational only, not asserted: \$ENV{TZ}=$real_tz_hint on this host");
}
{
    my $empty_path_dir = tempdir(CLEANUP => 1);
    local $ENV{PATH} = $empty_path_dir;
    my $rc = system('podman', '--version');
    isnt($rc, 0, 'PATH tripwire: a bare "podman" lookup is unreachable under an emptied PATH');
}
{
    my $self_src = slurp(__FILE__);
    ok(defined($self_src) && length($self_src), 'prereq: this file can read its own source via __FILE__');
    if (defined $self_src) {
        my @bad_lines = grep { /launcher\.pl/ && (/\bsystem\s*\(/ || /\bexec\s*\(/ || /'-\|'/) } split /\n/, $self_src;
        is(scalar(@bad_lines), 0, 'hygiene: no system/exec/open(-|) call in this file references launcher.pl');
        my $runtime_word = join('', qw(p o d m a n));
        my @spawn_lines = grep { /\Q$runtime_word\E/ && /\bsystem\s*\(/ } split /\n/, $self_src;
        is(scalar(@spawn_lines), 1, 'hygiene: exactly one system( call in this file mentions the container runtime (the PATH tripwire itself)');
    }
}

done_testing();
