package BpPowerPlan;
# BpPowerPlan -- the Windows power plan follows arming (Decision 14).
# Spec: .ccpraxis-local-data/blueprints/host-wake-and-suspend/specs/06-plan-follows-arming-spec.md
#
# While at least one session is armed (BpContinuityLease::live_arms), the
# plan wanted is "Continuous work" (resolved by name through the /list
# verb, falling back to a stored GUID); otherwise it is "Balanced" (the
# stock GUID). Every check reconciles: no record of the previous plan is
# kept, and a manual switch gets no special case.
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

# decide(%in) -> \%d (spec 2.1's table).
sub decide {
    my (%in) = @_;
    my $armed = $in{armed};
    $armed = 0 unless defined $armed && $armed =~ /\A\d+\z/;
    my $active = defined $in{active} ? lc($in{active}) : undef;
    my $cw_name = defined $in{cw_name} ? $in{cw_name} : $CONTINUOUS_WORK_NAME;
    my $cw_guid = lc(defined $in{cw_guid} ? $in{cw_guid} : $CONTINUOUS_WORK_GUID);
    my $balanced_guid = lc(defined $in{balanced_guid} ? $in{balanced_guid} : $BALANCED_GUID);

    if ($armed == 0) {
        my $action = (defined $active && $active eq $balanced_guid) ? 'none' : 'set';
        return {
            action => $action, wanted_guid => $balanced_guid,
            wanted_name => 'Balanced', wanted_basis => 'stock', error => '',
        };
    }

    my $list = $in{list};
    unless (ref $list eq 'ARRAY') {
        return {
            action => 'error', wanted_guid => 'none', wanted_name => 'none',
            wanted_basis => 'none', error => 'list-failed',
        };
    }

    my $cw_name_norm = lc($cw_name);
    $cw_name_norm =~ s/\A\s+//; $cw_name_norm =~ s/\s+\z//;

    my (@S, %seen);
    for my $e (@$list) {
        next unless ref $e eq 'HASH';
        my $nm = $e->{name};
        next unless defined $nm;
        my $t = lc($nm);
        $t =~ s/\A\s+//; $t =~ s/\s+\z//;
        next unless $t eq $cw_name_norm;
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
        return {
            action => 'error', wanted_guid => 'none', wanted_name => 'none',
            wanted_basis => 'none', error => 'continuous-work-missing',
        };
    }

    my %inS = map { $_ => 1 } @S;
    if (defined $active && $inS{$active}) {
        return {
            action => 'none', wanted_guid => $active,
            wanted_name => $cw_name, wanted_basis => $basis, error => '',
        };
    }
    my $wanted_guid = $inS{$cw_guid} ? $cw_guid : $S[0];
    return {
        action => 'set', wanted_guid => $wanted_guid,
        wanted_name => $cw_name, wanted_basis => $basis, error => '',
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

sub _ascii_sanitize {
    my ($s) = @_;
    return $s unless defined $s;
    $s =~ s/[^\x20-\x7e]/?/g;
    return $s;
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
    my $arms = BpContinuityLease::live_arms($root);
    $arms = [] unless ref $arms eq 'ARRAY';
    my $armed = scalar @$arms;
    my $arm_ids = [ map { $_->{sid} } @$arms ];

    my $r1 = run_powercfg(['/getactivescheme'], %o);
    my $detail1 = _detail_for($r1);
    my ($found_guid, $found_name);
    if (!length $detail1) {
        my $parsed = parse_active($r1->{out});
        if (ref $parsed eq 'HASH' && defined $parsed->{guid}) {
            $found_guid = lc($parsed->{guid});
            $found_name = _ascii_sanitize($parsed->{name});
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
            detail => $detail1, rc => $last_rc, ms => $ms->(),
        );
        return _outcome(
            outcome => 'error', reason => 'getactive-failed', detail => $detail1,
            armed => $armed, arm_ids => $arm_ids,
            wanted_guid => 'none', wanted_name => 'none', wanted_basis => 'none',
            rc => $last_rc, journaled => $journaled, ms => $ms->(),
        );
    }

    my $list;
    if ($armed > 0) {
        my $r2 = run_powercfg(['/list'], %o);
        my $detail2 = _detail_for($r2);
        if (length $detail2) {
            my $journaled = _write_plan_record(
                dir => $dir, why => $why, armed => $armed, arm_ids => $arm_ids,
                found_guid => $found_guid, found_name => $found_name,
                wanted_guid => 'none', wanted_name => 'none', wanted_basis => 'none',
                action => 'none', result => 'error', error => 'list-failed',
                detail => $detail2, rc => $r2->{rc}, ms => $ms->(),
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
    }

    my $d = decide(armed => $armed, active => $found_guid, list => $list);

    if ($d->{action} eq 'error') {
        my $journaled = _write_plan_record(
            dir => $dir, why => $why, armed => $armed, arm_ids => $arm_ids,
            found_guid => $found_guid, found_name => $found_name,
            wanted_guid => 'none', wanted_name => 'none', wanted_basis => 'none',
            action => 'none', result => 'error', error => $d->{error},
            detail => '', rc => $last_rc, ms => $ms->(),
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
        if ($o{journal_noop}) {
            $journaled = _write_plan_record(
                dir => $dir, why => $why, armed => $armed, arm_ids => $arm_ids,
                found_guid => $found_guid, found_name => $found_name,
                wanted_guid => $d->{wanted_guid}, wanted_name => $d->{wanted_name},
                wanted_basis => $d->{wanted_basis},
                action => 'none', result => 'ok', error => '', detail => '',
                rc => $last_rc, ms => $ms->(),
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
    my $r3 = run_powercfg(['/setactive', $d->{wanted_guid}], %o);
    my $ok3 = (defined $r3->{status} && $r3->{status} eq 'ok' && defined $r3->{rc} && $r3->{rc} == 0);
    if ($ok3) {
        my $journaled = _write_plan_record(
            dir => $dir, why => $why, armed => $armed, arm_ids => $arm_ids,
            found_guid => $found_guid, found_name => $found_name,
            wanted_guid => $d->{wanted_guid}, wanted_name => $d->{wanted_name}, wanted_basis => $d->{wanted_basis},
            action => 'set', result => 'ok', error => '', detail => '',
            rc => $r3->{rc}, ms => $ms->(),
        );
        return _outcome(
            outcome => 'corrected', armed => $armed, arm_ids => $arm_ids,
            found_guid => $found_guid, found_name => $found_name,
            wanted_guid => $d->{wanted_guid}, wanted_name => $d->{wanted_name}, wanted_basis => $d->{wanted_basis},
            rc => $r3->{rc}, journaled => $journaled, ms => $ms->(),
        );
    }
    my $detail3 = _detail_for($r3);
    my $journaled = _write_plan_record(
        dir => $dir, why => $why, armed => $armed, arm_ids => $arm_ids,
        found_guid => $found_guid, found_name => $found_name,
        wanted_guid => $d->{wanted_guid}, wanted_name => $d->{wanted_name}, wanted_basis => $d->{wanted_basis},
        action => 'set', result => 'error', error => 'setactive-failed',
        detail => $detail3, rc => $r3->{rc}, ms => $ms->(),
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

my $USAGE = "usage: bp-power-plan reconcile [--why WORD] [--json]\n";

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

    my %rc_opts;
    $rc_opts{why} = $opt{why} if defined $opt{why};
    my $outcome = reconcile($dir, %rc_opts);
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
