package HostTz;
use strict;
use warnings;

# HostTz -- pure(ish) host-timezone detection for the sandbox connector
# (blueprint sandbox-session-ux, package 01-container-timezone; Decision 8:
# containers run in the host's current timezone, re-derived at EVERY session
# launch, never hard-coded). See
# .ccpraxis-local-data/blueprints/sandbox-session-ux/specs/01-container-timezone-spec.md
# sec 2.1/2.2 for the full contract this module implements.
#
# This module never prints, never dies, never warns, and never reads %ENV
# directly on the Windows path. Every real I/O op (registry read, tzutil
# spawn, readlink, container probe) goes through an injectable seam so a
# test never touches the operator's real host state.

# ---------------------------------------------------------------------------
# Registry path constants (spec sec 2.1). Exact literal paths -- an invalid
# Windows id is NEVER interpolated into TZI(); see windows id validation
# below.
# ---------------------------------------------------------------------------
sub KEYNAME { return '/proc/registry/HKEY_LOCAL_MACHINE/SYSTEM/CurrentControlSet/Control/TimeZoneInformation/TimeZoneKeyName'; }
sub DDTD    { return '/proc/registry/HKEY_LOCAL_MACHINE/SYSTEM/CurrentControlSet/Control/TimeZoneInformation/DynamicDaylightTimeDisabled'; }
sub TZI {
    my ($id) = @_;
    return '/proc/registry/HKEY_LOCAL_MACHINE/SOFTWARE/Microsoft/Windows NT/CurrentVersion/Time Zones/' . $id . '/TZI';
}

my $WINDOWS_ID_RE = qr/\A[A-Za-z0-9][A-Za-z0-9 .+\-]{0,63}\z/;
my $IANA_RE       = qr{\A[A-Za-z0-9_+\-]+(?:/[A-Za-z0-9_+\-]+)*\z};

# ---------------------------------------------------------------------------
# windows_to_iana($windows_id) -> $iana_or_undef
#
# Embedded CLDR supplemental/windowsZones.xml table, territory="001" rows
# only (the "golden zone" per Windows id) -- verbatim shape, one
# 'Windows Id' => 'Area/City' pair per entry. Source: CLDR release "48"
# (tag release-48, commit acd6d88ae493633240e19a87a721076a8a75c310, committed
# 2025-10-23, common/supplemental/windowsZones.xml), well over the spec's
# 7-day-old-release floor. Re-taken 2026-09-26 to fix two stale rows found by
# review (Mountain Standard Time (Mexico) -> America/Mazatlan, not the
# pre-2022f America/Chihuahua; Central Asia Standard Time -> Asia/Bishkek,
# not the pre-2024a Asia/Almaty), add South Sudan Standard Time (present in
# the host registry, absent from the prior table), and drop Mid-Atlantic
# Standard Time and Kamchatka Standard Time, which release 48 no longer
# lists under territory="001". Legacy CLDR link names (e.g. Asia/Calcutta)
# are kept as CLDR gives them -- the image installs tzdata-legacy, which
# ships those links on Debian 13 (Containerfile comment).
# ---------------------------------------------------------------------------
my %WINDOWS_TO_IANA = (
    'Dateline Standard Time'            => 'Etc/GMT+12',
    'UTC-11'                            => 'Etc/GMT+11',
    'Aleutian Standard Time'            => 'America/Adak',
    'Hawaiian Standard Time'            => 'Pacific/Honolulu',
    'Marquesas Standard Time'           => 'Pacific/Marquesas',
    'Alaskan Standard Time'             => 'America/Anchorage',
    'UTC-09'                            => 'Etc/GMT+9',
    'Pacific Standard Time (Mexico)'    => 'America/Tijuana',
    'UTC-08'                            => 'Etc/GMT+8',
    'Pacific Standard Time'             => 'America/Los_Angeles',
    'US Mountain Standard Time'         => 'America/Phoenix',
    'Mountain Standard Time (Mexico)'   => 'America/Mazatlan',
    'Mountain Standard Time'            => 'America/Denver',
    'Yukon Standard Time'               => 'America/Whitehorse',
    'Central America Standard Time'     => 'America/Guatemala',
    'Central Standard Time'             => 'America/Chicago',
    'Easter Island Standard Time'       => 'Pacific/Easter',
    'Central Standard Time (Mexico)'    => 'America/Mexico_City',
    'Canada Central Standard Time'      => 'America/Regina',
    'SA Pacific Standard Time'          => 'America/Bogota',
    'Eastern Standard Time (Mexico)'    => 'America/Cancun',
    'Eastern Standard Time'             => 'America/New_York',
    'Haiti Standard Time'               => 'America/Port-au-Prince',
    'Cuba Standard Time'                => 'America/Havana',
    'US Eastern Standard Time'          => 'America/Indianapolis',
    'Turks And Caicos Standard Time'    => 'America/Grand_Turk',
    'Paraguay Standard Time'            => 'America/Asuncion',
    'Atlantic Standard Time'            => 'America/Halifax',
    'Venezuela Standard Time'           => 'America/Caracas',
    'Central Brazilian Standard Time'   => 'America/Cuiaba',
    'SA Western Standard Time'          => 'America/La_Paz',
    'Pacific SA Standard Time'          => 'America/Santiago',
    'Newfoundland Standard Time'        => 'America/St_Johns',
    'Tocantins Standard Time'           => 'America/Araguaina',
    'E. South America Standard Time'    => 'America/Sao_Paulo',
    'SA Eastern Standard Time'          => 'America/Cayenne',
    'Argentina Standard Time'           => 'America/Buenos_Aires',
    'Greenland Standard Time'           => 'America/Godthab',
    'Montevideo Standard Time'          => 'America/Montevideo',
    'Magallanes Standard Time'          => 'America/Punta_Arenas',
    'Saint Pierre Standard Time'        => 'America/Miquelon',
    'Bahia Standard Time'               => 'America/Bahia',
    'UTC-02'                            => 'Etc/GMT+2',
    'Azores Standard Time'              => 'Atlantic/Azores',
    'Cape Verde Standard Time'          => 'Atlantic/Cape_Verde',
    'UTC'                               => 'Etc/UTC',
    'GMT Standard Time'                 => 'Europe/London',
    'Greenwich Standard Time'           => 'Atlantic/Reykjavik',
    'Sao Tome Standard Time'            => 'Africa/Sao_Tome',
    'Morocco Standard Time'             => 'Africa/Casablanca',
    'W. Europe Standard Time'           => 'Europe/Berlin',
    'Central Europe Standard Time'      => 'Europe/Budapest',
    'Romance Standard Time'             => 'Europe/Paris',
    'Central European Standard Time'    => 'Europe/Warsaw',
    'W. Central Africa Standard Time'   => 'Africa/Lagos',
    'Jordan Standard Time'              => 'Asia/Amman',
    'GTB Standard Time'                 => 'Europe/Bucharest',
    'Middle East Standard Time'         => 'Asia/Beirut',
    'Egypt Standard Time'               => 'Africa/Cairo',
    'E. Europe Standard Time'           => 'Europe/Chisinau',
    'Syria Standard Time'               => 'Asia/Damascus',
    'West Bank Standard Time'           => 'Asia/Hebron',
    'South Africa Standard Time'        => 'Africa/Johannesburg',
    'FLE Standard Time'                 => 'Europe/Kiev',
    'Israel Standard Time'              => 'Asia/Jerusalem',
    'South Sudan Standard Time'         => 'Africa/Juba',
    'Kaliningrad Standard Time'         => 'Europe/Kaliningrad',
    'Sudan Standard Time'               => 'Africa/Khartoum',
    'Libya Standard Time'               => 'Africa/Tripoli',
    'Namibia Standard Time'             => 'Africa/Windhoek',
    'Arabic Standard Time'              => 'Asia/Baghdad',
    'Turkey Standard Time'              => 'Europe/Istanbul',
    'Arab Standard Time'                => 'Asia/Riyadh',
    'Belarus Standard Time'             => 'Europe/Minsk',
    'Russian Standard Time'             => 'Europe/Moscow',
    'E. Africa Standard Time'           => 'Africa/Nairobi',
    'Iran Standard Time'                => 'Asia/Tehran',
    'Arabian Standard Time'             => 'Asia/Dubai',
    'Astrakhan Standard Time'           => 'Europe/Astrakhan',
    'Azerbaijan Standard Time'          => 'Asia/Baku',
    'Russia Time Zone 3'                => 'Europe/Samara',
    'Mauritius Standard Time'           => 'Indian/Mauritius',
    'Saratov Standard Time'             => 'Europe/Saratov',
    'Georgian Standard Time'            => 'Asia/Tbilisi',
    'Volgograd Standard Time'           => 'Europe/Volgograd',
    'Caucasus Standard Time'            => 'Asia/Yerevan',
    'Afghanistan Standard Time'         => 'Asia/Kabul',
    'West Asia Standard Time'           => 'Asia/Tashkent',
    'Ekaterinburg Standard Time'        => 'Asia/Yekaterinburg',
    'Pakistan Standard Time'            => 'Asia/Karachi',
    'Qyzylorda Standard Time'           => 'Asia/Qyzylorda',
    'India Standard Time'               => 'Asia/Calcutta',
    'Sri Lanka Standard Time'           => 'Asia/Colombo',
    'Nepal Standard Time'               => 'Asia/Katmandu',
    'Central Asia Standard Time'        => 'Asia/Bishkek',
    'Bangladesh Standard Time'          => 'Asia/Dhaka',
    'Omsk Standard Time'                => 'Asia/Omsk',
    'Myanmar Standard Time'             => 'Asia/Rangoon',
    'SE Asia Standard Time'             => 'Asia/Bangkok',
    'Altai Standard Time'               => 'Asia/Barnaul',
    'W. Mongolia Standard Time'         => 'Asia/Hovd',
    'North Asia Standard Time'          => 'Asia/Krasnoyarsk',
    'N. Central Asia Standard Time'     => 'Asia/Novosibirsk',
    'Tomsk Standard Time'               => 'Asia/Tomsk',
    'China Standard Time'               => 'Asia/Shanghai',
    'North Asia East Standard Time'     => 'Asia/Irkutsk',
    'Singapore Standard Time'           => 'Asia/Singapore',
    'W. Australia Standard Time'        => 'Australia/Perth',
    'Taipei Standard Time'              => 'Asia/Taipei',
    'Ulaanbaatar Standard Time'         => 'Asia/Ulaanbaatar',
    'Aus Central W. Standard Time'      => 'Australia/Eucla',
    'Transbaikal Standard Time'         => 'Asia/Chita',
    'Tokyo Standard Time'               => 'Asia/Tokyo',
    'North Korea Standard Time'         => 'Asia/Pyongyang',
    'Korea Standard Time'               => 'Asia/Seoul',
    'Yakutsk Standard Time'             => 'Asia/Yakutsk',
    'Cen. Australia Standard Time'      => 'Australia/Adelaide',
    'AUS Central Standard Time'         => 'Australia/Darwin',
    'E. Australia Standard Time'        => 'Australia/Brisbane',
    'AUS Eastern Standard Time'         => 'Australia/Sydney',
    'West Pacific Standard Time'        => 'Pacific/Port_Moresby',
    'Tasmania Standard Time'            => 'Australia/Hobart',
    'Vladivostok Standard Time'         => 'Asia/Vladivostok',
    'Lord Howe Standard Time'           => 'Australia/Lord_Howe',
    'Bougainville Standard Time'        => 'Pacific/Bougainville',
    'Russia Time Zone 10'               => 'Asia/Srednekolymsk',
    'Magadan Standard Time'             => 'Asia/Magadan',
    'Norfolk Standard Time'             => 'Pacific/Norfolk',
    'Sakhalin Standard Time'            => 'Asia/Sakhalin',
    'Central Pacific Standard Time'     => 'Pacific/Guadalcanal',
    'Russia Time Zone 11'               => 'Asia/Kamchatka',
    'New Zealand Standard Time'         => 'Pacific/Auckland',
    'UTC+12'                            => 'Etc/GMT-12',
    'Fiji Standard Time'                => 'Pacific/Fiji',
    'Chatham Islands Standard Time'     => 'Pacific/Chatham',
    'UTC+13'                            => 'Etc/GMT-13',
    'Tonga Standard Time'               => 'Pacific/Tongatapu',
    'Samoa Standard Time'               => 'Pacific/Apia',
    'Line Islands Standard Time'        => 'Pacific/Kiritimati',
);

sub windows_to_iana {
    my ($id) = @_;
    return undef unless defined $id;
    return $WINDOWS_TO_IANA{$id};
}

# ---------------------------------------------------------------------------
# Registry string decode (spec sec 2.1 "Registry string decode"). Applies to
# both the KEYNAME bytes and tzutil stdout.
# ---------------------------------------------------------------------------
sub _decode_registry_string {
    my ($bytes) = @_;
    return undef unless defined $bytes;
    my $s   = $bytes;
    my $len = length($s);
    if ($len >= 2 && $len % 2 == 0) {
        my $is_ascii_u16 = 1;
        for (my $i = 1; $i < $len; $i += 2) {
            if (substr($s, $i, 1) ne "\0") { $is_ascii_u16 = 0; last; }
        }
        if ($is_ascii_u16) {
            my $out = '';
            for (my $i = 0; $i < $len; $i += 2) { $out .= substr($s, $i, 1); }
            $s = $out;
        }
    }
    $s =~ s/\0//g;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return length($s) ? $s : undef;
}

# ---------------------------------------------------------------------------
# parse_tzi($bytes) -> \%tzi_or_undef (spec sec 2.1)
# ---------------------------------------------------------------------------
sub parse_tzi {
    my ($bytes) = @_;
    return undef unless defined $bytes && length($bytes) == 44;
    my @f = unpack('l< l< l< v8 v8', $bytes);
    return undef unless @f == 19;
    my ($bias, $std_bias, $dst_bias, @rest) = @f;
    my @std = @rest[0 .. 7];
    my @dlt = @rest[8 .. 15];

    for my $b ($bias, $std_bias, $dst_bias) {
        return undef if abs($b) > 1440;
    }

    my $std_month = $std[1];
    my $dlt_month = $dlt[1];
    return undef if (($std_month == 0) ? 1 : 0) != (($dlt_month == 0) ? 1 : 0);

    my $has_dst = $std_month != 0;

    for my $date (\@std, \@dlt) {
        my ($y, $mo, $dow, $day, $h, $mi, $s, $ms) = @$date;
        next if $mo == 0;
        return undef if $y != 0;
        return undef if $mo  < 1 || $mo  > 12;
        return undef if $dow < 0 || $dow > 6;
        return undef if $day < 1 || $day > 5;
        return undef if $h   < 0 || $h   > 23;
        return undef if $mi  < 0 || $mi  > 59;
        return undef if $s   < 0 || $s   > 59;
        return undef if $ms  < 0 || $ms  > 999;
    }

    return {
        bias     => $bias,
        std_bias => $std_bias,
        dst_bias => $dst_bias,
        std      => { month => $std[1], dow => $std[2], week => $std[3], hour => $std[4], min => $std[5], sec => $std[6], ms => $std[7] },
        dst      => { month => $dlt[1], dow => $dlt[2], week => $dlt[3], hour => $dlt[4], min => $dlt[5], sec => $dlt[6], ms => $dlt[7] },
        has_dst  => ($has_dst ? 1 : 0),
    };
}

# ---------------------------------------------------------------------------
# posix_rule(\%tzi, $dst_disabled) -> $rule_string (spec sec 2.1)
# ---------------------------------------------------------------------------
sub _label {
    my ($m) = @_;
    my $sign = $m <= 0 ? '+' : '-';
    my $am   = abs($m);
    my $hh   = int($am / 60);
    my $mm   = $am % 60;
    return '<' . $sign . sprintf('%02d', $hh) . ($mm ? sprintf('%02d', $mm) : '') . '>';
}

sub _offset {
    my ($m)  = @_;
    my $sign = $m < 0 ? '-' : '';
    my $am   = abs($m);
    my $hh   = int($am / 60);
    my $mm   = $am % 60;
    return $sign . $hh . ($mm ? sprintf(':%02d', $mm) : '');
}

sub _hms {
    my ($t) = @_;
    my $total = $t->{hour} * 3600 + $t->{min} * 60 + $t->{sec} + ($t->{ms} == 999 ? 1 : 0);
    my $h   = int($total / 3600);
    my $rem = $total % 3600;
    my $mi  = int($rem / 60);
    my $s   = $rem % 60;
    return sprintf('%d:%02d:%02d', $h, $mi, $s) if $s;
    return sprintf('%d:%02d', $h, $mi) if $mi;
    return "$h";
}

sub _when {
    my ($t) = @_;
    return 'M' . $t->{month} . '.' . $t->{week} . '.' . $t->{dow} . '/' . _hms($t);
}

sub posix_rule {
    my ($tzi, $dst_disabled) = @_;
    return undef unless ref($tzi) eq 'HASH';
    my $S    = $tzi->{bias} + $tzi->{std_bias};
    my $rule = _label($S) . _offset($S);
    if ($tzi->{has_dst} && !$dst_disabled) {
        my $D = $tzi->{bias} + $tzi->{dst_bias};
        $rule .= _label($D) . _offset($D) . ',' . _when($tzi->{dst}) . ',' . _when($tzi->{std});
    }
    return $rule;
}

# ---------------------------------------------------------------------------
# exec_env_args($result) -> ('-e', "TZ=$tz") or () (spec sec 2.1)
# ---------------------------------------------------------------------------
sub exec_env_args {
    my ($r) = @_;
    return () unless ref($r) eq 'HASH';
    my $tz = $r->{tz};
    return () unless defined $tz;
    return () unless $tz =~ /\A[\x21-\x7e]{1,128}\z/;
    return () if substr($tz, 0, 1) eq '/';
    return ('-e', "TZ=$tz");
}

# ---------------------------------------------------------------------------
# log_event($result) -> ($type, \%fields) (spec sec 2.1)
# ---------------------------------------------------------------------------
sub log_event {
    my ($r) = @_;
    return ('container_tz_unset', { reason => 'detect_failed' }) unless ref($r) eq 'HASH';
    if (defined $r->{tz}) {
        my %fields = (tz => $r->{tz}, source => $r->{source});
        $fields{note}       = $r->{note}       if defined $r->{note};
        $fields{windows_id} = $r->{windows_id} if defined $r->{windows_id};
        return ('container_tz', \%fields);
    }
    my %fields = (reason => $r->{reason});
    $fields{windows_id} = $r->{windows_id} if defined $r->{windows_id};
    return ('container_tz_unset', \%fields);
}

# ---------------------------------------------------------------------------
# Default seams (used only when a caller omits one -- tests always pass all
# of them, per spec sec 2.1's test rule).
# ---------------------------------------------------------------------------
sub _default_read_file {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

sub _default_readlink {
    my ($path) = @_;
    my $r = eval { CORE::readlink($path) };
    return $r;
}

sub _default_run {
    my (@argv) = @_;
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*' if $^O =~ /^(MSWin32|cygwin|msys)$/;
    my $out = '';
    my $ok = eval {
        open(my $fh, '-|', @argv) or die "spawn failed\n";
        local $/;
        $out = <$fh>;
        $out = '' unless defined $out;
        close($fh);
        1;
    };
    return $ok ? ($? >> 8, $out) : (-1, '');
}

sub _fail_win {
    my ($reason, $windows_id) = @_;
    return { tz => undef, source => undef, note => undef, reason => $reason, windows_id => $windows_id };
}

sub _fail_other {
    my ($reason) = @_;
    return { tz => undef, source => undef, note => undef, reason => $reason, windows_id => undef };
}

# ---------------------------------------------------------------------------
# detect algorithm, Windows family (spec sec 2.2 "Windows family")
# ---------------------------------------------------------------------------
sub _detect_windows {
    my ($read_file, $run, $has_probe, $probe) = @_;

    my $bytes = $read_file->(KEYNAME());
    my $id    = _decode_registry_string($bytes);
    if (!defined $id) {
        my ($rc, $out) = $run->('tzutil.exe', '/g');
        if (defined $rc && $rc == 0) {
            my $tid = _decode_registry_string($out);
            $id = $tid if defined $tid;
        }
    }
    return _fail_win('windows_id_unreadable') unless defined $id;

    my $dst_off = 0;
    if ($id =~ /_dstoff\z/) {
        $id =~ s/_dstoff\z//;
        $dst_off = 1;
    }
    return _fail_win('windows_id_invalid') unless $id =~ $WINDOWS_ID_RE;
    my $windows_id = $id;

    unless ($dst_off) {
        my $ddtd = eval { $read_file->(DDTD()) };
        if (defined $ddtd && length($ddtd) == 4) {
            my $val = unpack('V', $ddtd);
            $dst_off = 1 if $val == 1;
        }
    }

    my $note;
    if (!$dst_off) {
        my $iana = windows_to_iana($id);
        if (defined $iana) {
            if (!$has_probe) {
                return { tz => $iana, source => 'windows_iana', note => undef, reason => undef, windows_id => $windows_id };
            }
            my $probe_ok = defined($probe) ? eval { $probe->($iana) } : undef;
            if ($probe_ok) {
                return { tz => $iana, source => 'windows_iana', note => undef, reason => undef, windows_id => $windows_id };
            }
            $note = 'iana_missing_in_image';
        }
    }

    my $tzi_bytes = $read_file->(TZI($id));
    return _fail_win('tzi_unreadable', $windows_id) unless defined $tzi_bytes;

    my $tzi = parse_tzi($tzi_bytes);
    return _fail_win('tzi_malformed', $windows_id) unless defined $tzi;

    my $final_note = $dst_off ? 'dst_auto_adjust_off' : ($note // 'windows_id_unmapped');
    my $rule = posix_rule($tzi, $dst_off);
    return { tz => $rule, source => 'windows_posix', note => $final_note, reason => undef, windows_id => $windows_id };
}

# ---------------------------------------------------------------------------
# detect algorithm, other OS (spec sec 2.2 "Other OS")
# ---------------------------------------------------------------------------
sub _detect_other {
    my ($env, $read_file, $readlink_fn, $has_probe, $probe) = @_;

    my $candidate;
    my $source;
    my $override_path;

    my $tz_env = $env->{TZ};
    if (defined $tz_env) {
        (my $rest = $tz_env) =~ s/^://;
        if (length $rest) {
            if ($rest =~ m{^/}) {
                $override_path = $rest;
            } else {
                return _fail_other('zone_value_invalid') unless $rest =~ /\A[\x21-\x7e]{1,128}\z/;
                $candidate = $rest;
                $source    = 'env';
            }
        }
    }

    unless (defined $candidate) {
        my $lt_path     = defined($override_path) ? $override_path : '/etc/localtime';
        my $link_target = $readlink_fn->($lt_path);
        my $found;
        for my $s (grep { defined } ($link_target, $lt_path)) {
            if ($s =~ m{/zoneinfo/}) { $found = $s; last; }
        }
        if (defined $found) {
            my ($after) = $found =~ m{.*/zoneinfo/(.*)$};
            $after =~ s{^posix/}{};
            $after =~ s{^right/}{};
            $candidate = $after;
            $source    = 'localtime_link';
        }
    }

    unless (defined $candidate) {
        my $tzfile = $read_file->('/etc/timezone');
        if (defined $tzfile) {
            my ($first_line) = split /\n/, $tzfile, 2;
            $first_line = '' unless defined $first_line;
            $first_line =~ s/^\s+//;
            $first_line =~ s/\s+$//;
            if (length $first_line) {
                $candidate = $first_line;
                $source    = 'etc_timezone';
            }
        }
    }

    return _fail_other('host_zone_not_found') unless defined $candidate;

    if ($source eq 'localtime_link' || $source eq 'etc_timezone') {
        return _fail_other('zone_value_invalid') unless $candidate =~ $IANA_RE;
    }

    if ($candidate =~ $IANA_RE && $has_probe) {
        my $probe_ok = defined($probe) ? eval { $probe->($candidate) } : undef;
        return { tz => undef, source => undef, note => undef, reason => 'zone_missing_in_image', windows_id => undef }
            unless $probe_ok;
    }

    return { tz => $candidate, source => $source, note => undef, reason => undef, windows_id => undef };
}

# ---------------------------------------------------------------------------
# detect(%seams) -> \%result (spec sec 2.1/2.2). Total: every seam call is
# fenced (die and warn both contained), so this never dies and never lets a
# warning escape.
# ---------------------------------------------------------------------------
sub detect {
    my (%seams) = @_;
    my $result;
    my $ok = eval {
        local $SIG{__WARN__} = sub { };
        $result = _detect_impl(%seams);
        1;
    };
    return $ok ? $result : { tz => undef, source => undef, note => undef, reason => 'detect_failed', windows_id => undef };
}

sub _detect_impl {
    my (%seams) = @_;
    my $os          = exists($seams{os})  ? $seams{os}  : $^O;
    my $env         = exists($seams{env}) ? $seams{env} : \%ENV;
    my $read_file   = $seams{read_file}   || \&_default_read_file;
    my $readlink_fn = $seams{readlink}    || \&_default_readlink;
    my $run         = $seams{run}         || \&_default_run;
    my $has_probe   = exists $seams{probe_iana};
    my $probe       = $seams{probe_iana};

    if (defined($os) && $os =~ /^(MSWin32|cygwin|msys)$/) {
        return _detect_windows($read_file, $run, $has_probe, $probe);
    }
    return _detect_other($env, $read_file, $readlink_fn, $has_probe, $probe);
}

1;
