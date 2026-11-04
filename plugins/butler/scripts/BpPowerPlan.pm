package BpPowerPlan;
# BpPowerPlan -- the Windows power plan follows arming (Decision 14), and
# (wake-and-pause-consolidation Decisions 4, 9, 15) reconcile undoes only
# ITS OWN switch.
# Spec: .ccpraxis-local-data/blueprints/host-wake-and-suspend/specs/06-plan-follows-arming-spec.md
#       .ccpraxis-local-data/blueprints/wake-and-pause-consolidation/specs/03-plan-restores-prior-spec.md
#
# While at least one session is armed (BpContinuityLease::live_arms), the
# plan wanted is "Continuous work" (resolved by name through the /list
# verb, falling back to a stored GUID); otherwise it is "Balanced" (the
# stock GUID). Decision 4: reconcile now RECORDS the plan it switches away
# from (power-plan-switch.json in the continuity state root) and restores
# exactly that plan once nothing holds any more -- a plan chosen by hand
# while idle is left alone, because there is no record to restore from.
# Decision 9: Continuous work left active by pre-03 code (no record at
# all) is treated as reconcile's own doing and Balanced is restored once;
# Decision 15 makes "once" mean once per machine, tracked by a migration
# marker (power-plan-migrated.json) whose mere presence is the only thing
# ever read from it.
#
# THE REAL PLAN IS NEVER TOUCHED BY A TEST. Every powercfg call goes through
# powercfg_argv, which refuses under a .t file or CCPRAXIS_NO_WAKELOCK, and
# through run_powercfg's run coderef seam.
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd ();
use JSON::PP ();
use Time::HiRes ();
use Fcntl qw(:flock);
use File::Path ();
use Sys::Hostname ();

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });
# BpContinuityLease.pm is never checked via %INC: it is the module whose OWN
# daemon_loop is what requires us (Package 06's run_plan_step, invoked once
# per tick), and its normal production entry point runs it as the perl MAIN
# PROGRAM ("perl BpContinuityLease.pm lease --daemon") -- a script that is
# executing AS $0 is never added to %INC (only files reached through
# require/use are). So the %INC-based guard every other require in this
# codebase uses would find no entry, unconditionally re-require the file, and
# re-execute its ~1400 lines top to bottom WHILE THE ORIGINAL daemon_loop
# invocation is still on the call stack -- redefining daemon_loop,
# _handle_signal, sync, lease_log and every other sub the live $SIG{TERM}
# closure depends on, mid-flight, for no reason (the package is already
# fully loaded; nothing here needs a second copy of it). Measured: with the
# %INC guard, BpContinuityLease.pm's own top-level runs twice and every one
# of its subs logs a "Subroutine ... redefined" warning. Checking the
# package's own symbol table instead answers the real question ("is
# BpContinuityLease already loaded, however it got here") and is true
# whether it arrived via require or as the main script.
require "$DIR/BpContinuityLease.pm" unless defined &BpContinuityLease::platform;
require "$DIR/BpPowerJournal.pm"    unless grep { m{(?:^|/)BpPowerJournal\.pm$} }    keys %INC;
require "$DIR/BpAwakeConst.pm"      unless defined &BpAwakeConst::AC_STALE;

our $BALANCED_GUID      = '381b4222-f694-41f0-9685-ff5bb260df2e';
our $CONTINUOUS_WORK_NAME = 'Continuous work';
our $CONTINUOUS_WORK_GUID = '54a34db5-af62-4d8a-ba50-af7155ee895a';
our $POWERCFG_TIMEOUT_SECONDS = 5;

# $LIVE_ROOT -- a test seam, same shape as BpContinuityLease's $STATE_ROOT.
# Production never sets it; _own_live_root() resolves the module's own
# __FILE__ instead. A same-process test may set this package variable; a
# subprocess (the CLI, a spawned refresher) has no access to it, so it may
# instead set CCPRAXIS_POWER_PLAN_LIVE_ROOT (an absolute path), which
# _own_live_root() honours the same way. Neither is ever set in production.
our $LIVE_ROOT;

my $GUID_RE = qr/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/;

# ---------------------------------------------------------------------------
# state files (wake-and-pause-consolidation spec 2.1): the switch record,
# the migration marker, and the plan lock -- all in the continuity state
# root, never in $dir (the power journal's own home).
# ---------------------------------------------------------------------------

our $PLAN_LOCK_TIMEOUT_SECONDS = 20;

# $_PLAN_LOCK_HELD -- re-entrant-within-one-process marker for the plan lock
# (triage item 1, step-6 reviewer M1 / redteam F3). flock is per OPEN FILE
# DESCRIPTION, so a reconcile() nested inside another reconcile() IN THE SAME
# PROCESS -- exactly what the refresher's signal-exit restore does when a
# TERM/INT lands mid-tick -- would open a SECOND handle on the same lock file
# and spin out the full timeout contending with its OWN outer flock, then
# return skipped/plan-locked and never restore anything. Cross-process
# exclusion is already in force via the outer call's held flock, so a nested
# call on this flag skips straight through; set via local() so it reverts the
# instant the holding call returns, by any path (including a die).
our $_PLAN_LOCK_HELD = 0;

sub switch_record_path    { my ($root) = @_; return "$root/power-plan-switch.json" }
sub migration_marker_path { my ($root) = @_; return "$root/power-plan-migrated.json" }
sub plan_lock_path         { my ($root) = @_; return "$root/power-plan.lock" }

# this_host() -> lc hostname, or '' if unavailable. Used only to tell a
# record this host wrote from one a different host left behind.
sub this_host {
    my $h = eval { Sys::Hostname::hostname() };
    if (defined $h && length $h) { return lc($h) }
    my $env = $ENV{COMPUTERNAME};
    return (defined $env && length $env) ? lc($env) : '';
}

# _atomic_write($path, $content) -> 1 | 0. Writes to "$path.tmp.$$" then
# renames over $path; never dies, unlinks the tmp file on any failure.
sub _atomic_write {
    my ($path, $content) = @_;
    return 0 unless defined $path && length $path;
    my ($rootdir) = $path =~ m{\A(.*)/[^/]+\z};
    if (defined $rootdir && length $rootdir && !-d $rootdir) {
        eval { File::Path::make_path($rootdir) };
    }
    my $tmp = "$path.tmp.$$";
    my $ok = eval {
        open(my $fh, '>', $tmp) or die "open $tmp: $!";
        print {$fh} $content or die "print $tmp: $!";
        close($fh) or die "close $tmp: $!";
        rename($tmp, $path) or die "rename $tmp -> $path: $!";
        1;
    };
    unless ($ok) {
        unlink $tmp;
        return 0;
    }
    return 1;
}

# read_switch_record($root) -> {guid, name, written_at, host} | undef.
# undef means "treat as absent": missing/unreadable, not a JSON object,
# v != 1, a malformed guid, or a record a DIFFERENT host wrote (foreign).
# Never deletes an invalid/foreign file -- only an H4 write replaces it.
sub read_switch_record {
    my ($root) = @_;
    return undef unless defined $root && length $root;
    my $path = switch_record_path($root);
    return undef unless -f $path;
    my $raw = do {
        open(my $fh, '<:raw', $path) or return undef;
        local $/;
        my $c = <$fh>;
        close $fh;
        $c;
    };
    return undef unless defined $raw && length $raw;
    my $d = eval { JSON::PP->new->utf8->decode($raw) };
    return undef unless ref $d eq 'HASH';
    return undef unless defined $d->{v} && $d->{v} eq '1';
    return undef unless defined $d->{guid} && !ref $d->{guid} && $d->{guid} =~ /\A$GUID_RE\z/;
    my $host = (defined $d->{host} && !ref $d->{host}) ? $d->{host} : '';
    my $this = this_host();
    return undef if length $host && length $this && lc($host) ne lc($this);
    my $name = (defined $d->{name} && !ref $d->{name}) ? $d->{name} : '';
    return {
        guid => lc($d->{guid}), name => $name,
        written_at => $d->{written_at}, host => $host,
    };
}

# write_switch_record($root, $guid, $name) -> 1 | 0 (atomic).
sub write_switch_record {
    my ($root, $guid, $name) = @_;
    return 0 unless defined $root && length $root && defined $guid && length $guid;
    my %rec = (
        guid => lc($guid), host => this_host(),
        name => defined $name ? $name : '', v => 1, written_at => time(),
    );
    my $json = JSON::PP->new->utf8->canonical->encode(\%rec) . "\n";
    return _atomic_write(switch_record_path($root), $json);
}

# remove_switch_record($root) -> 1 if the file is absent afterwards, else 0.
sub remove_switch_record {
    my ($root) = @_;
    return 0 unless defined $root && length $root;
    my $path = switch_record_path($root);
    unlink $path;
    return -e $path ? 0 : 1;
}

# write_migration_marker($root, $why) -> 1 | 0 (atomic; a no-op success if
# the marker already exists -- presence alone is ever read, Decision 15).
sub write_migration_marker {
    my ($root, $why) = @_;
    return 0 unless defined $root && length $root;
    my $path = migration_marker_path($root);
    return 1 if -e $path;
    my %rec = (
        host => this_host(), v => 1,
        why => (defined $why ? $why : 'switch'), written_at => time(),
    );
    my $json = JSON::PP->new->utf8->canonical->encode(\%rec) . "\n";
    return _atomic_write($path, $json);
}

# _norm_str($s) -> lc, trimmed | undef.
sub _norm_str {
    my ($s) = @_;
    return undef unless defined $s;
    my $t = lc($s);
    $t =~ s/\A\s+//; $t =~ s/\s+\z//;
    return $t;
}

# _is_cw($active, $active_name, $cw_guid, $cw_name) -> bool. Spec 2.3: by
# guid, or by name (case/whitespace-insensitive). Used only in the unheld
# rows; the held rows keep today's S-set (list membership) unchanged.
sub _is_cw {
    my ($active, $active_name, $cw_guid, $cw_name) = @_;
    return 0 unless defined $active;
    return 1 if lc($active) eq lc($cw_guid);
    my $an = _norm_str($active_name);
    my $cn = _norm_str($cw_name);
    return (defined $an && defined $cn && $an eq $cn) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# pure parsers (spec 2.1)
# ---------------------------------------------------------------------------

# parse_list($bytes) -> \@entries, each {guid, name}, in output order.
sub parse_list {
    my ($bytes) = @_;
    my @entries;
    return \@entries unless defined $bytes && length $bytes;
    for my $line (split /\r?\n/, $bytes) {
        next unless $line =~ /($GUID_RE)/;
        my $guid = lc($1);
        my $rest = substr($line, $+[0]);
        $rest =~ s/\s+\z//;
        $rest =~ s/\*\z//;
        $rest =~ s/\s+\z//;
        my $name;
        if ($rest =~ /\A\s*\((.*)\)\s*\z/) { $name = $1 }
        push @entries, { guid => $guid, name => $name };
    }
    return \@entries;
}

# parse_active($bytes) -> {guid, name} | undef. The first GUID-bearing line.
sub parse_active {
    my ($bytes) = @_;
    my $list = parse_list($bytes);
    return @$list ? $list->[0] : undef;
}

# decide(%in) -> \%d (spec 2.3's table: H1-H5 held, U1-U8 unheld). Pure --
# never touches a file or runs powercfg. Every return carries action,
# wanted_guid, wanted_name, wanted_basis, error, record_op, marker_op.
sub decide {
    my (%in) = @_;
    my $armed = $in{armed};
    $armed = 0 unless defined $armed && $armed =~ /\A\d+\z/;
    my $active = defined $in{active} ? lc($in{active}) : undef;
    my $active_name = $in{active_name};
    my $cw_name = defined $in{cw_name} ? $in{cw_name} : $CONTINUOUS_WORK_NAME;
    my $cw_guid = lc(defined $in{cw_guid} ? $in{cw_guid} : $CONTINUOUS_WORK_GUID);
    my $balanced_guid = lc(defined $in{balanced_guid} ? $in{balanced_guid} : $BALANCED_GUID);
    my $migrated = $in{migrated} ? 1 : 0;
    my $record = (ref $in{record} eq 'HASH') ? $in{record} : undef;

    if ($armed == 0) {
        if (defined $record) {
            my $rguid = lc($record->{guid});
            my $rname = (defined $record->{name} && length $record->{name}) ? $record->{name} : 'unknown';
            if (defined $active && $active eq $rguid) {
                # U1
                return {
                    action => 'none', wanted_guid => $rguid, wanted_name => $rname,
                    wanted_basis => 'record', error => '', record_op => 'remove', marker_op => 'none',
                };
            }
            unless (_is_cw($active, $active_name, $cw_guid, $cw_name)) {
                # U2
                return {
                    action => 'none', wanted_guid => $active, wanted_name => (defined $active_name ? $active_name : 'unknown'),
                    wanted_basis => 'record-superseded', error => '', record_op => 'remove', marker_op => 'none',
                };
            }
            my $list = $in{list};
            unless (ref $list eq 'ARRAY' && @$list) {
                # U3
                return {
                    action => 'error', wanted_guid => 'none', wanted_name => 'none',
                    wanted_basis => 'none', error => 'list-failed', record_op => 'none', marker_op => 'none',
                };
            }
            my $found = grep { ref $_ eq 'HASH' && defined $_->{guid} && lc($_->{guid}) eq $rguid } @$list;
            if ($found) {
                # U4
                return {
                    action => 'set', wanted_guid => $rguid, wanted_name => $rname,
                    wanted_basis => 'record', error => '', record_op => 'remove', marker_op => 'none',
                };
            }
            # U5
            return {
                action => 'set', wanted_guid => $balanced_guid, wanted_name => 'Balanced',
                wanted_basis => 'record-missing', error => '', record_op => 'remove', marker_op => 'none',
            };
        }
        # record undef
        unless (_is_cw($active, $active_name, $cw_guid, $cw_name)) {
            # U6
            return {
                action => 'none', wanted_guid => $active, wanted_name => (defined $active_name ? $active_name : 'unknown'),
                wanted_basis => 'left', error => '', record_op => 'none', marker_op => 'none',
            };
        }
        if ($migrated) {
            # U7
            return {
                action => 'none', wanted_guid => $active, wanted_name => (defined $active_name ? $active_name : 'unknown'),
                wanted_basis => 'left', error => '', record_op => 'none', marker_op => 'none',
            };
        }
        # U8
        return {
            action => 'set', wanted_guid => $balanced_guid, wanted_name => 'Balanced',
            wanted_basis => 'migration', error => '', record_op => 'none', marker_op => 'write',
        };
    }

    # Held (H1-H5): today's S-set logic, unchanged, plus record/marker columns.
    my $list = $in{list};
    unless (ref $list eq 'ARRAY') {
        # H1
        return {
            action => 'error', wanted_guid => 'none', wanted_name => 'none',
            wanted_basis => 'none', error => 'list-failed', record_op => 'none', marker_op => 'none',
        };
    }

    my $cw_name_norm = _norm_str($cw_name);

    my (@S, %seen);
    for my $e (@$list) {
        next unless ref $e eq 'HASH';
        my $nm = $e->{name};
        next unless defined $nm;
        my $t = _norm_str($nm);
        next unless defined $t && $t eq $cw_name_norm;
        next unless defined $e->{guid};
        my $g = lc($e->{guid});
        next if $seen{$g}++;
        push @S, $g;
    }

    my $basis = 'name';
    if (!@S) {
        my $found = grep { ref $_ eq 'HASH' && defined $_->{guid} && lc($_->{guid}) eq $cw_guid } @$list;
        if ($found) { @S = ($cw_guid); $basis = 'stored-guid' }
    }
    if (!@S) {
        # H2
        return {
            action => 'error', wanted_guid => 'none', wanted_name => 'none',
            wanted_basis => 'none', error => 'continuous-work-missing', record_op => 'none', marker_op => 'none',
        };
    }

    my %inS = map { $_ => 1 } @S;
    if (defined $active && $inS{$active}) {
        # H3
        return {
            action => 'none', wanted_guid => $active, wanted_name => $cw_name,
            wanted_basis => $basis, error => '', record_op => 'none', marker_op => 'none',
        };
    }
    my $wanted_guid = $inS{$cw_guid} ? $cw_guid : $S[0];
    if (defined $record) {
        # H5 -- a record already exists; keep it as-is, re-ensure the marker.
        return {
            action => 'set', wanted_guid => $wanted_guid, wanted_name => $cw_name,
            wanted_basis => $basis, error => '', record_op => 'none', marker_op => 'write',
        };
    }
    # H4 -- this is reconcile's own first switch away from $active: record it
    # to restore later -- UNLESS $active IS Continuous work itself, by the
    # stored guid or by name, under a rename/duplicate that keeps it out of
    # the name-matched S-set (triage item 3, step-6 reviewer m1). Recording
    # CW as "the plan to restore" would pin the machine on CW forever once
    # released, exactly the failure Decision 4 exists to prevent.
    my $active_is_cw_itself = _is_cw($active, $active_name, $cw_guid, $cw_name);
    return {
        action => 'set', wanted_guid => $wanted_guid, wanted_name => $cw_name,
        wanted_basis => $basis, error => '',
        record_op => ($active_is_cw_itself ? 'none' : 'write'), marker_op => 'write',
    };
}

# ---------------------------------------------------------------------------
# powercfg runner (spec 2.1)
# ---------------------------------------------------------------------------

sub _is_abs_path {
    my ($v) = @_;
    return 0 unless defined $v && length $v;
    return 1 if $v =~ m{^/};
    return 0 unless $v =~ m{^[A-Za-z]:};
    my $rest = substr($v, 2);
    return 1 if $rest eq q{} || $rest =~ m{^/} || substr($rest, 0, 1) eq chr(92);
    return 0;
}

# ---------------------------------------------------------------------------
# Decision 24 -- the structural live-install guard.
#
# powercfg /setactive may run only when (a) this module's own resolved path
# is <root>/plugins/butler/scripts/BpPowerPlan.pm, where <root> is a
# directory named "ccpraxis" whose parent is ".claude", AND (b) the
# arm-state dir reconcile() was given resolves to exactly
# <root>/.continuity-active. A scratch copy of this file (a), or the real
# file pointed at fake state (b), refuses by construction. This is the
# FIRST layer; the existing env-based guards in powercfg_argv stay as a
# second layer underneath it.
# ---------------------------------------------------------------------------

# _win_drive_fix($path) -> $path, with a leading /<letter>/ rewritten to
# "<LETTER>:/" (the /c/ -> C:/ normalisation).
sub _win_drive_fix {
    my ($v) = @_;
    return $v unless defined $v;
    if ($v =~ m{\A/([A-Za-z])(?:/|\z)}) {
        my $letter = uc($1);
        $v = "$letter:" . substr($v, 2);
    }
    return $v;
}

# _norm_fs_path($path) -> normalised path | undef. Forward slashes, /c/ ->
# C:/, and 8.3 short names expanded via Cwd::abs_path (best-effort: a
# nonexistent path is normalised without short-name expansion rather than
# failing outright, since the arm-state dir need not exist yet).
sub _norm_fs_path {
    my ($p) = @_;
    return undef unless defined $p && length $p;
    my $v = $p;
    $v =~ tr{\\}{/};
    $v = _win_drive_fix($v);
    my $abs = Cwd::abs_path($v);
    if (defined $abs && length $abs) {
        $v = $abs;
        $v =~ tr{\\}{/};
        $v = _win_drive_fix($v);
    }
    $v =~ s{/\z}{} if $v =~ m{/\z} && $v !~ m{\A[A-Za-z]:/\z};
    return $v;
}

# _paths_equal($a, $b) -> bool. Case-insensitive on Windows/msys/cygwin,
# case-sensitive elsewhere.
sub _paths_equal {
    my ($a, $b) = @_;
    return 0 unless defined $a && defined $b;
    return ($^O =~ /^(MSWin32|msys|cygwin)$/) ? (lc($a) eq lc($b)) : ($a eq $b);
}

# _own_live_root_info() -> ($root, $source) | (undef, undef), where <root>
# is the ccpraxis-under-.claude directory this module's own file resolves
# inside, or undef if it does not resolve there at all (a clone, a scratch
# copy, ...). $source is 'override' when $LIVE_ROOT or
# CCPRAXIS_POWER_PLAN_LIVE_ROOT supplied the root, 'module-path' when it came
# from this module's own __FILE__. Only a module-path root may ever reach the
# real powercfg.exe (see _live_root_is_override, powercfg_argv).
sub _own_live_root_info {
    if (defined $LIVE_ROOT) { return ($LIVE_ROOT, 'override') }
    my $env = $ENV{CCPRAXIS_POWER_PLAN_LIVE_ROOT};
    if (defined $env && length $env) {
        my $n = _norm_fs_path($env);
        return (defined $n && length $n) ? ($n, 'override') : (undef, undef);
    }
    # Separators FIRST, then abs_path -- __FILE__ can carry backslashes on
    # Windows. Same shape as BpTurnCaps::script_dir_for; asserted repo-wide by
    # turn-cap-consistency.t's C9.
    (my $self = __FILE__) =~ s{\\}{/}g;
    my $mod = Cwd::abs_path($self);
    $mod = $self unless defined $mod;
    my $norm = _norm_fs_path($mod);
    return (undef, undef) unless defined $norm;
    if ($norm =~ m{\A(.*/\.claude/ccpraxis)/plugins/butler/scripts/BpPowerPlan\.pm\z}i) {
        return ($1, 'module-path');
    }
    return (undef, undef);
}

# _own_live_root() -> <root> | undef. Convenience wrapper over
# _own_live_root_info() for callers that only need the path.
sub _own_live_root {
    my ($root, undef) = _own_live_root_info();
    return $root;
}

# _live_root_is_override() -> bool. True when the live root in effect (if
# any) came from $LIVE_ROOT or CCPRAXIS_POWER_PLAN_LIVE_ROOT rather than this
# module's own resolved __FILE__. Used by powercfg_argv to keep an override
# from ever reaching the real powercfg.exe: an override can prove structural
# eligibility (is_live_install) for a test/tool that supplies its own fake
# arm-state layout, but it must never also unlock the real binary -- only a
# root this module's own file actually resolves inside may do that.
sub _live_root_is_override {
    my (undef, $source) = _own_live_root_info();
    return (defined $source && $source eq 'override') ? 1 : 0;
}

# is_live_install($dir) -> bool. $dir is the arm-state (legacy registry) dir
# reconcile() was given; it must resolve to exactly <root>/.continuity-active
# for the SAME <root> this module's own file resolves inside.
sub is_live_install {
    my ($dir) = @_;
    my $root = _own_live_root();
    return 0 unless defined $root && length $root;
    return 0 unless defined $dir && length $dir;
    my $want = _norm_fs_path("$root/.continuity-active");
    my $got  = _norm_fs_path($dir);
    return 0 unless defined $want && defined $got;
    return _paths_equal($want, $got) ? 1 : 0;
}

# powercfg_argv(@args) -> \@argv | undef
sub powercfg_argv {
    my (@args) = @_;
    if (defined $ENV{CCPRAXIS_POWERCFG} && length $ENV{CCPRAXIS_POWERCFG}) {
        my $path = $ENV{CCPRAXIS_POWERCFG};
        return undef unless _is_abs_path($path) && -f $path;
        return [ $^X, $path, @args ];
    }
    return undef if defined $0 && $0 =~ /\.t\z/;
    return undef if $ENV{CCPRAXIS_NO_WAKELOCK};
    # Decision 24 hazard close: an overridden live root (either $LIVE_ROOT or
    # CCPRAXIS_POWER_PLAN_LIVE_ROOT) can make is_live_install() true for fake
    # arm state without a fake powercfg also being named. That combination
    # must never reach the real binary -- only a root this module's own file
    # resolves inside may.
    return undef if _live_root_is_override();
    return [ 'powercfg.exe', @args ];
}

# run_powercfg(\@args, %o) -> {status, rc, out, ms}
sub run_powercfg {
    my ($args, %o) = @_;
    my @args = (ref $args eq 'ARRAY') ? @$args : ();
    if (exists $o{run}) {
        return $o{run}->(@args);
    }
    my $argv = powercfg_argv(@args);
    unless (defined $argv) {
        return { status => 'refused', rc => undef, out => '', ms => 0 };
    }
    my $timeout = defined $o{timeout} ? $o{timeout} : $POWERCFG_TIMEOUT_SECONDS;
    return BpPowerJournal::run_bounded($argv, $timeout);
}

sub _detail_for {
    my ($r) = @_;
    return '' unless ref $r eq 'HASH';
    my $status = defined $r->{status} ? $r->{status} : '';
    return 'timeout'      if $status eq 'timeout';
    return 'spawn-failed' if $status eq 'spawn-failed';
    return 'refused'      if $status eq 'refused';
    if (defined $r->{rc} && $r->{rc} != 0) { return 'rc=' . $r->{rc} }
    return '';
}

# _decode_once($s) -> $s, decoded from UTF-8 bytes into Perl's internal
# Unicode representation if it is not already (same idiom as
# BpPowerJournal::_decode_once / BpHook's _decode_maybe): a byte string read
# from OUTSIDE this process -- here, powercfg's /getactivescheme output --
# is decoded EXACTLY ONCE before it can ever reach a ->utf8 JSON encoder.
# Triage item 6 (step-6 redteam F8): a non-ASCII plan name must round-trip
# byte-exact through the switch record and the journal, not be replaced
# byte-by-byte with '?' (the previous _ascii_sanitize). A string that is not
# valid UTF-8, or already carries the utf8 flag, is left alone untouched.
sub _decode_once {
    my ($s) = @_;
    return $s unless defined $s;
    return $s if utf8::is_utf8($s);
    my $copy = $s;
    return utf8::decode($copy) ? $copy : $s;
}

# ---------------------------------------------------------------------------
# journal record (spec 2.2)
# ---------------------------------------------------------------------------

sub _write_plan_record {
    my (%f) = @_;
    my $dir = delete $f{dir};
    return 0 unless defined $dir && length $dir;
    my $now = time();
    my %rec = (
        v => 1, kind => 'plan', ts => $now,
        utc => BpPowerJournal::_utc_iso($now), local => BpPowerJournal::_local_iso($now),
        pid => $$,
        why => $f{why},
        armed => $f{armed}, arm_ids => (ref $f{arm_ids} eq 'ARRAY' ? $f{arm_ids} : []),
        found_guid => defined $f{found_guid} ? $f{found_guid} : 'unknown',
        found_name => defined $f{found_name} ? $f{found_name} : 'unknown',
        wanted_guid => defined $f{wanted_guid} ? $f{wanted_guid} : 'none',
        wanted_name => defined $f{wanted_name} ? $f{wanted_name} : 'none',
        wanted_basis => defined $f{wanted_basis} ? $f{wanted_basis} : 'none',
        action => $f{action}, result => $f{result},
        error => defined $f{error} ? $f{error} : '',
        detail => defined $f{detail} ? $f{detail} : '',
        rc => $f{rc}, ms => $f{ms},
    );
    # Package 09: override is emitted only when the caller passed one
    # (battery_releases said release) -- every pre-09 record, and every
    # non-battery reconcile, stays byte-for-byte as before.
    $rec{override} = $f{override} if defined $f{override};
    return BpPowerJournal::append_record($dir, \%rec) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# reconcile (spec 2.1's effect step)
# ---------------------------------------------------------------------------

sub _outcome {
    my (%f) = @_;
    my (undef, $lr_source) = _own_live_root_info();
    return {
        outcome => $f{outcome},
        reason => defined $f{reason} ? $f{reason} : '',
        detail => defined $f{detail} ? $f{detail} : '',
        armed => $f{armed},
        arm_ids => (ref $f{arm_ids} eq 'ARRAY' ? $f{arm_ids} : []),
        found_guid => $f{found_guid},
        found_name => $f{found_name},
        wanted_guid => $f{wanted_guid},
        wanted_name => $f{wanted_name},
        wanted_basis => $f{wanted_basis},
        rc => $f{rc},
        journaled => $f{journaled} ? 1 : 0,
        ms => $f{ms},
        live_root_source => defined $lr_source ? $lr_source : 'none',
    };
}

sub reconcile {
    my ($dir, %o) = @_;
    my $why = (defined $o{why} && $o{why} =~ /\A[a-z][a-z-]{0,31}\z/) ? $o{why} : 'manual';
    my $t0 = Time::HiRes::time();
    my $ms = sub { return int((Time::HiRes::time() - $t0) * 1000) };

    my $plat = eval { BpContinuityLease::platform() };
    $plat = 'unsupported' unless defined $plat;
    if ($plat ne 'windows') {
        return _outcome(outcome => 'skipped', reason => 'not-windows', ms => $ms->());
    }

    unless (exists $o{run}) {
        unless (is_live_install($dir)) {
            return _outcome(outcome => 'skipped', reason => 'not-live-install', ms => $ms->());
        }
        my $argv = powercfg_argv('/getactivescheme');
        unless (defined $argv) {
            return _outcome(outcome => 'skipped', reason => 'guard', ms => $ms->());
        }
    }

    my $root = BpContinuityLease::store_root_for($dir);
    unless (defined $root && length $root) {
        my $journaled = _write_plan_record(
            dir => $dir, why => $why, armed => 0, arm_ids => [],
            found_guid => 'unknown', found_name => 'unknown',
            wanted_guid => 'none', wanted_name => 'none', wanted_basis => 'none',
            action => 'none', result => 'error', error => 'arm-state-unresolvable',
            detail => '', rc => undef, ms => $ms->(),
        );
        return _outcome(
            outcome => 'error', reason => 'arm-state-unresolvable',
            armed => 0, arm_ids => [],
            wanted_guid => 'none', wanted_name => 'none', wanted_basis => 'none',
            journaled => $journaled, ms => $ms->(),
        );
    }
    # Lock (spec 2.4 step 1): serialises the refresher hold tick against a
    # launcher's --hold/--release CLI call, or continuity off against the
    # refresher's own exit step, so an unheld restore can never remove the
    # record out from under a concurrent held reconcile relying on it (H5).
    # A lexical handle: it stays open (and the flock held) until reconcile
    # returns by any path, including a die propagating from the run seam.
    eval { File::Path::make_path($root) } unless -d $root;
    my $lock_timeout = defined $o{lock_timeout} ? $o{lock_timeout} : $PLAN_LOCK_TIMEOUT_SECONDS;
    my $lockfh;
    if ($_PLAN_LOCK_HELD) {
        # Triage item 1: this process already holds the lock (we are a
        # reconcile nested inside another reconcile's run seam). Skip
        # straight through -- see $_PLAN_LOCK_HELD's own comment.
    } elsif (open($lockfh, '>>', plan_lock_path($root))) {
        my $locked = 0;
        my $deadline = Time::HiRes::time() + $lock_timeout;
        until ($locked) {
            $locked = 1, last if flock($lockfh, LOCK_EX | LOCK_NB);
            last if Time::HiRes::time() >= $deadline;
            Time::HiRes::sleep(0.1);
        }
        unless ($locked) {
            # Triage item 5 (step-6 reviewer m3, fixed in BpPowerPlan's OWN
            # journal rather than BpContinuityLease.pm's PLAN log, which is
            # outside this package's write set): a genuinely-contended skip
            # is now journaled, so it can be told apart from "nothing to
            # do" -- superseding spec 2.4 step 1's "writes no journal" for
            # this one case.
            my $journaled = _write_plan_record(
                dir => $dir, why => $why, armed => 0, arm_ids => [],
                found_guid => 'unknown', found_name => 'unknown',
                wanted_guid => 'none', wanted_name => 'none', wanted_basis => 'none',
                action => 'none', result => 'error', error => 'plan-locked',
                detail => '', rc => undef, ms => $ms->(),
            );
            return _outcome(outcome => 'skipped', reason => 'plan-locked', journaled => $journaled, ms => $ms->());
        }
    }
    # If the open itself failed, proceed WITHOUT the lock (degraded case; no
    # outcome changes) -- an ACL problem on the lock file must not block
    # reconcile from doing its job.
    local $_PLAN_LOCK_HELD = 1; # held for the rest of THIS call (including any
        # nested reconcile() invoked from inside the run seam below).

    my $arms = BpContinuityLease::live_arms($root);
    $arms = [] unless ref $arms eq 'ARRAY';
    # A sandboxed run arms INSIDE its container, which this host never reads; what
    # reaches the host is the launcher holding the wake-lock for it. Decision 14
    # counts "whatever the wake-lock lease counts as active", so a fresh sandbox
    # hold counts as an arm (bug 20261031-225231-6764).
    push @$arms, map { { sid => "sandbox:$_" } } @{ sandbox_holds($root) };
    # Package 08-host-awake-actuator: a counting registry entry (sandbox/
    # fleet/solo) counts as an arm too, for every reconcile caller alike --
    # the refresher's own tick, the bp-power-plan CLI an old launcher still
    # calls, butler-continuity off, the AC monitor. That shared set is
    # what keeps the plan from flapping between whichever caller last
    # reconciled it. HostAwake.pm is loaded lazily (symbol guard, never
    # %INC -- see this file's own header); a load or call failure adds
    # nothing and changes nothing else.
    eval {
        require "$DIR/HostAwake.pm" unless defined &HostAwake::counting_ids;
        push @$arms, map { { sid => "source:$_" } } @{ HostAwake::counting_ids($root, time()) };
    };

    # Package 09-battery-for-every-source: battery past grace overrides
    # EVERY source above (arms, sandbox/solo/fleet entries, old holds) into
    # an empty arm set, so every reconcile caller agrees -- the CLI, the
    # refresher's own hold tick, "butler-continuity off", and the AC
    # monitor all restore the same way instead of fighting each other. A
    # load or call failure leaves $override undef, so the arm set and every
    # caller's behaviour are unchanged (fail-open, AC12(c)).
    my $override;                                   # undef | 'battery'
    eval {
        require "$DIR/HostAwake.pm" unless defined &HostAwake::battery_releases;
        # review n1/m7: Time::HiRes here is for the probe-interval TEST SEAM
        # only (see HostAwake::battery_step's own header), not a correctness
        # requirement of this call -- battery_verdict's V2 check already
        # carries a 1s tolerance on the future-dated comparison (BpAcWatch.pm,
        # battery_verdict's own header) specifically so that an integer "now"
        # a few ms behind a fractional probed_at never misreads as a clock
        # step-back. An integer time() here would cost nothing real; HiRes is
        # kept only so this call's own sub-second precision matches every
        # other battery_releases/battery_step caller, not because it is
        # needed to avoid a false flip.
        $override = 'battery' if HostAwake::battery_releases($root, Time::HiRes::time());
    };
    $arms = [] if defined $override;

    my $armed = scalar @$arms;
    my $arm_ids = [ map { $_->{sid} } @$arms ];

    my $r1 = run_powercfg(['/getactivescheme'], %o);
    my $detail1 = _detail_for($r1);
    my ($found_guid, $found_name);
    if (!length $detail1) {
        my $parsed = parse_active($r1->{out});
        if (ref $parsed eq 'HASH' && defined $parsed->{guid}) {
            $found_guid = lc($parsed->{guid});
            $found_name = _decode_once($parsed->{name});
        } else {
            $detail1 = 'unparseable';
        }
    }
    my $last_rc = $r1->{rc};

    if (!defined $found_guid) {
        my $journaled = _write_plan_record(
            dir => $dir, why => $why, armed => $armed, arm_ids => $arm_ids,
            found_guid => 'unknown', found_name => 'unknown',
            wanted_guid => 'none', wanted_name => 'none', wanted_basis => 'none',
            action => 'none', result => 'error', error => 'getactive-failed',
            detail => $detail1, rc => $last_rc, ms => $ms->(), override => $override,
        );
        return _outcome(
            outcome => 'error', reason => 'getactive-failed', detail => $detail1,
            armed => $armed, arm_ids => $arm_ids,
            wanted_guid => 'none', wanted_name => 'none', wanted_basis => 'none',
            rc => $last_rc, journaled => $journaled, ms => $ms->(),
        );
    }

    # Step 4: the switch record and migration marker -- read once, read-only
    # until decide() tells us what (if anything) to do with them.
    my $record = read_switch_record($root);
    my $migrated = -e migration_marker_path($root) ? 1 : 0;

    # Step 5: /list is run when armed (unchanged), OR when unheld with a
    # record naming a plan other than the one active, AND that active plan
    # is Continuous work (U3/U4/U5 need the list; U1/U2/U6/U7/U8 never do).
    my $need_list = $armed > 0;
    if (!$need_list && defined $record) {
        my $rguid = lc($record->{guid});
        $need_list = 1 if $found_guid ne $rguid
            && _is_cw($found_guid, $found_name, $CONTINUOUS_WORK_GUID, $CONTINUOUS_WORK_NAME);
    }

    my $list;
    if ($need_list) {
        my $r2 = run_powercfg(['/list'], %o);
        my $detail2 = _detail_for($r2);
        if (length $detail2) {
            my $journaled = _write_plan_record(
                dir => $dir, why => $why, armed => $armed, arm_ids => $arm_ids,
                found_guid => $found_guid, found_name => $found_name,
                wanted_guid => 'none', wanted_name => 'none', wanted_basis => 'none',
                action => 'none', result => 'error', error => 'list-failed',
                detail => $detail2, rc => $r2->{rc}, ms => $ms->(), override => $override,
            );
            return _outcome(
                outcome => 'error', reason => 'list-failed', detail => $detail2,
                armed => $armed, arm_ids => $arm_ids,
                found_guid => $found_guid, found_name => $found_name,
                wanted_guid => 'none', wanted_name => 'none', wanted_basis => 'none',
                rc => $r2->{rc}, journaled => $journaled, ms => $ms->(),
            );
        }
        $last_rc = $r2->{rc};
        $list = parse_list($r2->{out});
        if ($armed == 0 && !@$list) {
            # spec 2.4 step 5: unheld, /list ok but unparseable -- same
            # error path, record and marker untouched.
            my $journaled = _write_plan_record(
                dir => $dir, why => $why, armed => $armed, arm_ids => $arm_ids,
                found_guid => $found_guid, found_name => $found_name,
                wanted_guid => 'none', wanted_name => 'none', wanted_basis => 'none',
                action => 'none', result => 'error', error => 'list-failed',
                detail => 'unparseable', rc => $last_rc, ms => $ms->(), override => $override,
            );
            return _outcome(
                outcome => 'error', reason => 'list-failed', detail => 'unparseable',
                armed => $armed, arm_ids => $arm_ids,
                found_guid => $found_guid, found_name => $found_name,
                wanted_guid => 'none', wanted_name => 'none', wanted_basis => 'none',
                rc => $last_rc, journaled => $journaled, ms => $ms->(),
            );
        }
    }

    my $d = decide(
        armed => $armed, active => $found_guid, active_name => $found_name,
        list => $list, record => $record, migrated => $migrated,
    );

    if ($d->{action} eq 'error') {
        my $journaled = _write_plan_record(
            dir => $dir, why => $why, armed => $armed, arm_ids => $arm_ids,
            found_guid => $found_guid, found_name => $found_name,
            wanted_guid => 'none', wanted_name => 'none', wanted_basis => 'none',
            action => 'none', result => 'error', error => $d->{error},
            detail => '', rc => $last_rc, ms => $ms->(), override => $override,
        );
        return _outcome(
            outcome => 'error', reason => $d->{error}, detail => '',
            armed => $armed, arm_ids => $arm_ids,
            found_guid => $found_guid, found_name => $found_name,
            wanted_guid => 'none', wanted_name => 'none', wanted_basis => 'none',
            rc => $last_rc, journaled => $journaled, ms => $ms->(),
        );
    }

    if ($d->{action} eq 'none') {
        my $journaled = 0;
        if ($d->{record_op} eq 'remove') {
            my $removed = remove_switch_record($root);
            $journaled = _write_plan_record(
                dir => $dir, why => $why, armed => $armed, arm_ids => $arm_ids,
                found_guid => $found_guid, found_name => $found_name,
                wanted_guid => $d->{wanted_guid}, wanted_name => $d->{wanted_name},
                wanted_basis => $d->{wanted_basis},
                action => 'none', result => 'ok', error => '',
                detail => ($removed ? '' : 'record-remove-failed'),
                rc => $last_rc, ms => $ms->(), override => $override,
            );
        } elsif ($o{journal_noop}) {
            $journaled = _write_plan_record(
                dir => $dir, why => $why, armed => $armed, arm_ids => $arm_ids,
                found_guid => $found_guid, found_name => $found_name,
                wanted_guid => $d->{wanted_guid}, wanted_name => $d->{wanted_name},
                wanted_basis => $d->{wanted_basis},
                action => 'none', result => 'ok', error => '', detail => '',
                rc => $last_rc, ms => $ms->(), override => $override,
            );
        }
        return _outcome(
            outcome => 'correct', armed => $armed, arm_ids => $arm_ids,
            found_guid => $found_guid, found_name => $found_name,
            wanted_guid => $d->{wanted_guid}, wanted_name => $d->{wanted_name},
            wanted_basis => $d->{wanted_basis}, rc => $last_rc, journaled => $journaled, ms => $ms->(),
        );
    }

    # action eq 'set'
    my @detail_bits;
    if ($d->{record_op} eq 'write') {
        # The switch still happens even if this write fails -- keeping the
        # machine awake wins; the failure is only journaled (spec 2.4 step 9.1).
        push @detail_bits, 'record-write-failed' unless write_switch_record($root, $found_guid, $found_name);
    }
    my $r3 = run_powercfg(['/setactive', $d->{wanted_guid}], %o);
    my $ok3 = (defined $r3->{status} && $r3->{status} eq 'ok' && defined $r3->{rc} && $r3->{rc} == 0);
    if ($ok3) {
        if ($d->{record_op} eq 'remove') {
            push @detail_bits, 'record-remove-failed' unless remove_switch_record($root);
        }
        # Triage item 2 (step-6 redteam F1, overriding spec section 5's
        # acceptance that a record-write failure is "rare" and tolerable for
        # the whole root -- the triage narrows it to this one file): the
        # marker is written only when the switch record write (if any was
        # due) actually succeeded. Writing it anyway would leave Continuous
        # work pinned forever once the record is unreadable -- without the
        # marker, the Decision 9 migration restore still fires on the next
        # unheld reconcile.
        if ($d->{marker_op} eq 'write' && !grep { $_ eq 'record-write-failed' } @detail_bits) {
            my $marker_why = ($d->{wanted_basis} eq 'migration') ? 'migration' : 'switch';
            push @detail_bits, 'marker-write-failed' unless write_migration_marker($root, $marker_why);
        }
        my $journaled = _write_plan_record(
            dir => $dir, why => $why, armed => $armed, arm_ids => $arm_ids,
            found_guid => $found_guid, found_name => $found_name,
            wanted_guid => $d->{wanted_guid}, wanted_name => $d->{wanted_name}, wanted_basis => $d->{wanted_basis},
            action => 'set', result => 'ok', error => '', detail => join(',', @detail_bits),
            rc => $r3->{rc}, ms => $ms->(), override => $override,
        );
        return _outcome(
            outcome => 'corrected', armed => $armed, arm_ids => $arm_ids,
            found_guid => $found_guid, found_name => $found_name,
            wanted_guid => $d->{wanted_guid}, wanted_name => $d->{wanted_name}, wanted_basis => $d->{wanted_basis},
            rc => $r3->{rc}, journaled => $journaled, ms => $ms->(),
        );
    }
    # /setactive failed: no record removal and no marker write. A record
    # written just above (record_op eq 'write') stays -- the next healthy
    # reconcile performs the restore/migration (spec 2.4 step 9.4).
    my $detail3 = _detail_for($r3);
    # Triage item 4 (step-6 reviewer m2): keep record-write-failed in the
    # journaled detail even when /setactive ALSO failed -- previously only
    # $detail3 was kept, silently dropping the diagnostic in exactly the
    # degraded case it was added for.
    my $detail_final = join(',', grep { length } ($detail3, @detail_bits));
    my $journaled = _write_plan_record(
        dir => $dir, why => $why, armed => $armed, arm_ids => $arm_ids,
        found_guid => $found_guid, found_name => $found_name,
        wanted_guid => $d->{wanted_guid}, wanted_name => $d->{wanted_name}, wanted_basis => $d->{wanted_basis},
        action => 'set', result => 'error', error => 'setactive-failed',
        detail => $detail_final, rc => $r3->{rc}, ms => $ms->(), override => $override,
    );
    return _outcome(
        outcome => 'error', reason => 'setactive-failed', detail => $detail3,
        armed => $armed, arm_ids => $arm_ids,
        found_guid => $found_guid, found_name => $found_name,
        wanted_guid => $d->{wanted_guid}, wanted_name => $d->{wanted_name}, wanted_basis => $d->{wanted_basis},
        rc => $r3->{rc}, journaled => $journaled, ms => $ms->(),
    );
}

# ---------------------------------------------------------------------------
# CLI (spec 2.1)
# ---------------------------------------------------------------------------

my $USAGE = "usage: bp-power-plan reconcile [--why WORD] [--json] [--hold NAME | --release NAME]\n";

# ---------------------------------------------------------------------------
# sandbox holds (bug 20261031-225231-6764)
# ---------------------------------------------------------------------------
# <root>/sandbox-holds/<name>: one file per sandbox launcher currently holding
# the wake-lock for its container, kept fresh by `reconcile --hold <name>` on
# every launcher keep-awake tick (two minutes) and removed by `--release`. A
# launcher that dies without releasing leaves a file that stops counting after
# $SANDBOX_HOLD_FRESH_SECONDS, so a crash cannot pin Continuous work forever.
our $SANDBOX_HOLD_FRESH_SECONDS = BpAwakeConst::LEASE_FRESH();
my $HOLD_NAME_RE = qr/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/;

sub sandbox_hold_dir { my ($root) = @_; return "$root/sandbox-holds" }

# sandbox_holds($root) -> [names of fresh holds], sorted. Never dies.
sub sandbox_holds {
    my ($root) = @_;
    my @out;
    return \@out unless defined $root && length $root;
    my $d = sandbox_hold_dir($root);
    opendir(my $dh, $d) or return \@out;
    my $cutoff = time() - $SANDBOX_HOLD_FRESH_SECONDS;
    for my $e (sort readdir $dh) {
        next unless $e =~ $HOLD_NAME_RE;
        my $m = (stat("$d/$e"))[9];
        push @out, $e if defined $m && $m >= $cutoff;
    }
    closedir $dh;
    return \@out;
}

# set_sandbox_hold($root, $name, $on) -> 1 | 0. On: create or touch. Off: remove.
sub set_sandbox_hold {
    my ($root, $name, $on) = @_;
    return 0 unless defined $root && length $root && defined $name && $name =~ $HOLD_NAME_RE;
    my $d = sandbox_hold_dir($root);
    my $f = "$d/$name";
    unless ($on) { unlink $f; return -e $f ? 0 : 1 }
    eval { require File::Path; File::Path::make_path($d) } unless -d $d;
    open(my $fh, '>', $f) or return 0;
    print {$fh} time(), "\n";
    close $fh or return 0;
    return 1;
}

# sandbox_hold_files($root) -> [names], sorted. Every entry of
# sandbox_hold_dir($root) that matches $HOLD_NAME_RE and is a regular file --
# FRESH OR STALE, unlike sandbox_holds above. Content is never read and the
# function never dies; [] on an undef/empty root or a missing/unopenable
# directory, which is never created here (package 02-plan-hold-expiry spec
# 2.1). The hold-only refresher tick is the only caller that cares about a
# stale name, so the freshness filter that sandbox_holds applies for the plan
# decision must not be baked into this one.
sub sandbox_hold_files {
    my ($root) = @_;
    my @out;
    return \@out unless defined $root && length $root;
    my $d = sandbox_hold_dir($root);
    opendir(my $dh, $d) or return \@out;
    for my $e (readdir $dh) {
        next unless $e =~ $HOLD_NAME_RE;
        next unless -f "$d/$e";
        push @out, $e;
    }
    closedir $dh;
    return [ sort @out ];
}

# prune_stale_sandbox_holds($root, %o) -> { removed => [ {name,age} ... ], failed => [names] }
#
# Removes every hold file that is PRUNABLE at the moment of this call, re-
# stat'd immediately before the unlink decision so a launcher that refreshes
# the file between sandbox_hold_files' readdir and this re-stat is not
# punished for a snapshot that is already out of date (package 02 spec 2.1,
# edge case "rewritten during the tick"). A residual window remains between
# the re-stat and the unlink itself: if a launcher's refresh lands exactly
# there, its file is removed anyway, and the worst outcome is the no-hold
# plan until that launcher's next --hold (at most 120 s), which re-creates
# the file, reconciles, and re-ensures the refresher.
#
# A file is prunable when its mtime is more than $SANDBOX_HOLD_FRESH_SECONDS
# away from now in EITHER direction (addendum A.3.2): the ordinary stale case
# ($mt < now - FRESH), and a far-future mtime ($mt > now + FRESH), which a
# clock jump or a corrupted stat could otherwise pin for years since a dead
# launcher's file never self-heals. A near-future mtime (up to FRESH ahead)
# is kept, same as sandbox_holds counts it in.
#
# `failed` is reported only when the unlink genuinely did not remove a file
# that is STILL prunable afterwards (addendum A.3.1): a file that disappeared
# on its own, or that a live launcher refreshed back to freshness between the
# decision and this re-check, is neither removed nor failed -- it is a live
# hold, not a stuck one. $o{unlink} is an optional seam, a CODE ref taking one
# path and returning true/false, defaulting to CORE::unlink; production
# callers (daemon_loop) pass no options.
#
# Never dies; does nothing when $root is undef/empty or the hold directory is
# missing (and never creates it).
sub prune_stale_sandbox_holds {
    my ($root, %o) = @_;
    my %out = (removed => [], failed => []);
    return \%out unless defined $root && length $root;
    my $d = sandbox_hold_dir($root);
    return \%out unless -d $d;

    my $unlink = (ref $o{unlink} eq 'CODE') ? $o{unlink} : sub { CORE::unlink($_[0]) };
    my $prunable = sub {
        my ($mt, $now) = @_;
        return $mt < $now - $SANDBOX_HOLD_FRESH_SECONDS || $mt > $now + $SANDBOX_HOLD_FRESH_SECONDS;
    };
    for my $e (@{ sandbox_hold_files($root) }) {
        my $f = "$d/$e";
        my $mt = (stat($f))[9];
        next unless defined $mt;              # stat failed: neither removed nor failed
        next unless $prunable->($mt, time());  # fresh, or within FRESH either side: never touched

        my $age = time() - $mt;
        if ($unlink->($f)) {
            push @{ $out{removed} }, { name => $e, age => $age };
            next;                              # never also pushed to failed (B18)
        }
        my $mt2 = (stat($f))[9];
        push @{ $out{failed} }, $e if defined $mt2 && $prunable->($mt2, time());
    }
    $out{removed} = [ sort { $a->{name} cmp $b->{name} } @{ $out{removed} } ];
    $out{failed}  = [ sort @{ $out{failed} } ];
    return \%out;
}

sub _prune_plan_checked {
    my ($dir) = @_;
    my $root = BpContinuityLease::store_root_for($dir);
    return unless defined $root && length $root;
    my $pdir = "$root/plan-checked";
    return unless -d $pdir;
    my $cutoff = time() - 7 * 86400;
    opendir(my $dh, $pdir) or return;
    while (defined(my $e = readdir($dh))) {
        next if $e eq '.' || $e eq '..';
        my $f = "$pdir/$e";
        next unless -f $f;
        my $mt = (stat($f))[9];
        next unless defined $mt;
        unlink $f if $mt < $cutoff;
    }
    closedir($dh);
    return;
}

sub cli_main {
    my (@argv) = @_;
    my $verb = shift(@argv);
    unless (defined $verb && $verb eq 'reconcile') {
        print STDERR $USAGE;
        return 2;
    }
    my %opt;
    while (@argv) {
        my $a = shift @argv;
        if ($a eq '--why') {
            unless (@argv) { print STDERR $USAGE; return 2 }
            $opt{why} = shift @argv;
        } elsif ($a eq '--json') {
            $opt{json} = 1;
        } elsif ($a eq '--hold' || $a eq '--release') {
            unless (@argv && !defined $opt{hold_name} && $argv[0] =~ $HOLD_NAME_RE) { print STDERR $USAGE; return 2 }
            $opt{hold_name} = shift @argv;
            $opt{hold_on}   = ($a eq '--hold') ? 1 : 0;
        } else {
            print STDERR $USAGE;
            return 2;
        }
    }

    my $dir = BpContinuityLease::legacy_dir();
    unless (defined $dir) {
        print "armed: unknown\n";
        print "found: unknown (unknown)\n";
        print "wanted: none (none, none)\n";
        print "result: error: arm-state-unresolvable\n";
        return 1;
    }

    if (defined $opt{hold_name}) {
        my $root = BpContinuityLease::store_root_for($dir);
        unless (defined $root && length $root && set_sandbox_hold($root, $opt{hold_name}, $opt{hold_on})) {
            print STDERR "bp-power-plan: could not " . ($opt{hold_on} ? 'record' : 'remove')
                . " sandbox hold '$opt{hold_name}'\n";
            return 1;
        }
    }

    my %rc_opts;
    $rc_opts{why} = $opt{why} if defined $opt{why};
    my $outcome = reconcile($dir, %rc_opts);

    # Package 02-plan-hold-expiry: every `--hold` call ensures a refresher
    # exists, so a crashed launcher's hold is reconciled again without a
    # host arm (spec 2.2). BEFORE anything is printed to STDOUT -- ensure_daemon
    # may fork, and a forked child reopening STDOUT would flush the parent's
    # buffered output a second time. Called by fully qualified name (never a
    # cached coderef) so a test's `local *BpContinuityLease::ensure_daemon`
    # stub is seen; the verdict is ignored and an exception swallowed, since
    # neither ever changes this CLI's stdout/stderr/exit contract.
    if (defined $opt{hold_name} && $opt{hold_on}) {
        eval { BpContinuityLease::ensure_daemon($dir) };
    }

    unless (ref $outcome eq 'HASH') {
        print STDERR "bp-power-plan: reconcile failed\n";
        return 1;
    }

    if ($opt{json}) {
        print JSON::PP->new->canonical->encode($outcome), "\n";
    } else {
        if ($outcome->{outcome} eq 'skipped') {
            print 'result: skipped: ' . (defined $outcome->{reason} ? $outcome->{reason} : '') . "\n";
        } else {
            my $armed_n = defined $outcome->{armed} ? $outcome->{armed} : 'unknown';
            my $sids = (ref $outcome->{arm_ids} eq 'ARRAY' && @{ $outcome->{arm_ids} })
                ? ' (' . join(', ', @{ $outcome->{arm_ids} }) . ')' : '';
            print "armed: $armed_n$sids\n";
            my $fg = defined $outcome->{found_guid} ? $outcome->{found_guid} : 'unknown';
            my $fn = defined $outcome->{found_name} ? $outcome->{found_name} : 'unknown';
            print "found: $fg ($fn)\n";
            my $wg = defined $outcome->{wanted_guid} ? $outcome->{wanted_guid} : 'none';
            my $wn = defined $outcome->{wanted_name} ? $outcome->{wanted_name} : 'none';
            my $wb = defined $outcome->{wanted_basis} ? $outcome->{wanted_basis} : 'none';
            print "wanted: $wg ($wn, $wb)\n";
            if ($outcome->{outcome} eq 'error') {
                my $reason = defined $outcome->{reason} ? $outcome->{reason} : '';
                my $detail = defined $outcome->{detail} ? $outcome->{detail} : '';
                my $line = "result: error: $reason";
                $line .= " ($detail)" if length $detail;
                print "$line\n";
            } else {
                print "result: $outcome->{outcome}\n";
            }
        }
    }

    if (($outcome->{outcome} eq 'corrected' || $outcome->{outcome} eq 'error') && !$outcome->{journaled}) {
        print STDERR "bp-power-plan: journal append failed\n";
    }

    if (defined $opt{why} && $opt{why} eq 'statusline') {
        eval { _prune_plan_checked($dir) };
    }

    return $outcome->{outcome} eq 'error' ? 1 : 0;
}

1;
