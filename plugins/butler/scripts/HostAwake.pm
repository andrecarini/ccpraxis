package HostAwake;
# HostAwake -- the single decision (which mode, lock or not) and the one
# registry every host-side wake-lock producer publishes into (blueprint
# wake-and-pause-consolidation, package 08-host-awake-actuator).
# Spec: .ccpraxis-local-data/blueprints/wake-and-pause-consolidation/specs/08-host-awake-actuator-spec.md
#
# THE PROBLEM THIS REPLACES. Before this file, four processes each decided
# AND ACTUATED a host wake-lock independently (the continuity refresher, the
# orchestrator, drive-solo, the launcher), and two of them also drove the
# power plan. Two helpers could coexist, and the plan could flap between
# whichever caller last reconciled it. Here, every producer only PUBLISHES
# an intent -- one small JSON file per producer under
# "<state root>/awake-sources/<id>.json" -- and the continuity refresher
# (BpContinuityLease::daemon_loop) is the ONLY actuator: it reads this
# registry every tick (through gather/decide below) and converges the one
# host helper and the power plan by level, never by edge.
#
# A producer's own identity names what it is: "sandbox-<container>" (the
# launcher, one per running sandbox), "fleet-<blueprint>-<root tag>" (an
# orchestrator), "solo-<root tag>" (drive-solo). An entry counts while fresh
# (LEASE_FRESH) or, for a producer waiting out a pause, until an explicit
# `until` -- bounded so a crashed producer cannot pin the machine awake
# indefinitely (entry_counts, B3/B21).
#
# ONLY CORE MODULES AT FILE SCOPE, on purpose (Decision 13): the sandbox
# plugin's launcher.pl loads this file by path with no butler plugin
# guaranteed present, so BpContinuityLease.pm, BpPowerPlan.pm and
# bp-keepawake.pl are required LAZILY, inside the one sub that needs each,
# guarded by the package's own symbol table (never %INC -- BpPowerPlan.pm's
# own header explains why: a script executing AS $0 is never added to %INC,
# so an %INC guard would re-require and re-execute it from under itself).
use strict;
use warnings;
use JSON::PP ();
use Digest::MD5 ();
use File::Path ();
use File::Basename ();
use Cwd ();
use Time::HiRes ();

my $DIR = File::Basename::dirname(
    do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });
require "$DIR/BpAwakeConst.pm" unless defined &BpAwakeConst::LEASE_FRESH;

# --- test seams (package variables, never set in production) --------------
our $STATE_ROOT;   # overrides state_root()
our $HOST_SIDE;    # overrides host_side()

# ---------------------------------------------------------------------------
# state_root() -> $path | undef
#
# Decision 22/26(a): the rule itself lives in BpAwakeConst.pm (loaded above,
# at file scope, unconditionally), which is why it is byte-identical to
# BpHook::state_dir() -- both are pinned equal by
# awake-constants-single-source.t AC1/AC-1. This is a thin delegate, kept so
# every existing HostAwake::state_root caller (including this file's own
# _resolve_root) needs no change.
# ---------------------------------------------------------------------------
sub state_root { return BpAwakeConst::state_root(); }

# ---------------------------------------------------------------------------
# Identity (spec 2.2)
# ---------------------------------------------------------------------------
our $ID_RE = qr/\A(?:sandbox|fleet|solo)-[A-Za-z0-9][A-Za-z0-9._-]{0,199}\z/;

# root_tag($path) -> 8 lowercase hex | undef. undef for an undef/empty path.
sub root_tag {
    my ($path) = @_;
    return undef unless defined $path && length $path;
    (my $norm = $path) =~ tr{\\}{/};
    $norm =~ s{/+$}{};
    if ($norm =~ m{\A([A-Za-z]):/}) {
        $norm = '/' . lc($1) . '/' . substr($norm, 3);
    }
    my $bytes = $norm;
    utf8::encode($bytes) if utf8::is_utf8($bytes);
    return substr(Digest::MD5::md5_hex($bytes), 0, 8);
}

sub sandbox_id {
    my ($container) = @_;
    return undef unless defined $container && length $container;
    my $id = "sandbox-$container";
    return $id =~ $ID_RE ? $id : undef;
}

sub fleet_id {
    my ($bp, $project_root) = @_;
    my $tag = root_tag($project_root);
    return undef unless defined $tag;
    return undef unless defined $bp && length $bp;
    my $id = "fleet-$bp-$tag";
    return $id =~ $ID_RE ? $id : undef;
}

sub solo_id {
    my ($project_root) = @_;
    my $tag = root_tag($project_root);
    return undef unless defined $tag;
    my $id = "solo-$tag";
    return $id =~ $ID_RE ? $id : undef;
}

# ---------------------------------------------------------------------------
# Where it applies (spec 2.2)
# ---------------------------------------------------------------------------

# host_side() -> 0|1. Producers publish and withdraw only when this is 1 --
# inside a container there is no reader for a host registry.
sub host_side {
    return $HOST_SIDE ? 1 : 0 if defined $HOST_SIDE;
    return $^O =~ /^(MSWin32|msys|cygwin)$/ ? 1 : 0;
}

sub registry_dir { my ($root) = @_; return "$root/awake-sources" }

# _resolve_root(%o) -> ($root, $guarded). $guarded is true iff the root came
# from state_root() (no explicit seam, no BUTLER_STATE_DIR -- i.e. the
# DEFAULT root) AND either this is a direct .t run, or CCPRAXIS_NO_WAKELOCK
# is set (Decision 30, fix-batch).
#
# Why the second clause: the original .t-only guard cannot see a
# SUBPROCESS a test harness spawns (its own $0 is a scratch .pl, never a
# .t). Measured since 08 (32c0328): test runs that spawn producers as
# subprocesses wrote 14 solo- entries into the real
# ~/.claude/butler-state/continuity/awake-sources between 14:17 and 15:50
# on 2026-11-04, and after promotion each leaked entry would hold the
# machine awake for up to 15 minutes. CCPRAXIS_NO_WAKELOCK is already the
# operator's or a harness's own "no wake-lock" instruction (BpAcWatch's
# _default_wakelock_state and every GuardHarness-based test already set
# it), so refusing to publish under it is correct in production too, not
# only a test-safety measure. It applies only to the DEFAULT root -- an
# explicit {root} or BUTLER_STATE_DIR is always honoured, exactly as
# before, because that is the caller deliberately naming where to write.
sub _resolve_root {
    my (%o) = @_;
    return ($o{root}, 0) if exists $o{root};
    return ($STATE_ROOT, 0) if defined $STATE_ROOT;
    my $bsd = $ENV{BUTLER_STATE_DIR};
    my $from_env = defined $bsd && length $bsd;
    my $root = state_root();
    my $default_root = !$from_env;
    my $t_guard = ($default_root && defined $0 && $0 =~ /\.t\z/) ? 1 : 0;
    my $nwl_guard = ($default_root && $ENV{CCPRAXIS_NO_WAKELOCK}) ? 1 : 0;
    my $guard = ($t_guard || $nwl_guard) ? 1 : 0;
    return ($root, $guard);
}

# ---------------------------------------------------------------------------
# Registry write and delete (spec 2.2, B1/B2)
# ---------------------------------------------------------------------------

sub publish {
    my ($id, $intent, %o) = @_;
    return 0 unless defined $id && $id =~ $ID_RE;
    return 0 unless ref $intent eq 'HASH' && $intent->{awake};
    my ($root, $guarded) = _resolve_root(%o);
    return 0 unless defined $root && length $root;
    return 0 if $guarded;

    # review m4 / red-team n1: written_at must be an integer -- read_registry
    # requires /\A\d{1,15}\z/, so a fractional $o{now} (e.g. a future
    # Time::HiRes::time() caller) would write an entry that never counts
    # while still returning 1, which looks like a successful publish.
    my $now = int(defined $o{now} ? $o{now} : time());
    my $reason = (defined $intent->{reason} && $intent->{reason} =~ /\A[A-Za-z0-9_.-]{1,64}\z/)
        ? $intent->{reason} : 'unknown';
    my $until;
    if (defined $intent->{until} && "$intent->{until}" =~ /\A\d{1,15}(?:\.\d{1,6})?\z/) {
        $until = 0 + $intent->{until};
    }

    my $dir = registry_dir($root);
    my $ok = eval {
        File::Path::make_path($dir) unless -d $dir;
        my $path = "$dir/$id.json";
        my $tmp  = "$dir/$id.json.tmp.$$";
        my %h = (awake => 1, reason => $reason, source => $id, until => $until, v => 1, written_at => $now);
        my $json = JSON::PP->new->canonical(1)->encode(\%h) . "\n";
        open(my $fh, '>', $tmp) or die "open $tmp: $!";
        print {$fh} $json or die "print $tmp: $!";
        close($fh) or die "close $tmp: $!";
        rename($tmp, $path) or die "rename $tmp -> $path: $!";
        utime($now, $now, $path);
        1;
    };
    unless ($ok) {
        my $dir2 = registry_dir($root);
        unlink "$dir2/$id.json.tmp.$$";
        return 0;
    }
    return 1;
}

sub withdraw {
    my ($id, %o) = @_;
    return 0 unless defined $id && $id =~ $ID_RE;
    my ($root, $guarded) = _resolve_root(%o);
    return 0 unless defined $root && length $root;
    return 0 if $guarded;
    my $path = registry_dir($root) . "/$id.json";
    unlink $path;
    return -e $path ? 0 : 1;
}

# ---------------------------------------------------------------------------
# Registry read and decision (spec 2.2, B3/B4/B5)
# ---------------------------------------------------------------------------

# _read_entry_file($path, $id) -> \%entry | undef. Factored out of
# read_registry (review N4) so prune_registry's tombstone re-check (below)
# can re-judge one file's actual content without re-reading the whole
# directory or re-deriving the id from a filename that, for a tombstone,
# no longer matches ID_RE. Never dies. undef only when the path cannot be
# stat'd at all (gone, or lstat itself failed).
sub _read_entry_file {
    my ($path, $id) = @_;
    # Decision 26(d)/red-team m1: lstat first so a symlink is never
    # followed, and require a REGULAR file before anything opens it. A
    # FIFO or device node planted at this name must never be read -- open+
    # slurp on one hangs or blocks without bound.
    my @lst = lstat($path);
    return undef unless @lst;
    return undef if -l $path;      # never follow a symlink
    return undef unless -f $path;  # regular files only -- no FIFO, no device
    my @st = stat($path);
    return undef unless @st;
    my $entry = { id => $id, file => $path, mtime => $st[9], valid => 0,
                  written_at => undef, until => undef, reason => undef };
    eval {
        die "too big\n" if $st[7] > 4096;
        open(my $fh, '<:raw', $path) or die "open: $!\n";
        local $/;
        my $raw = <$fh>;
        close $fh;
        my $d = JSON::PP->new->decode($raw);
        die "not a hash\n" unless ref $d eq 'HASH';
        die "v\n"      unless defined $d->{v}     && $d->{v} == 1;
        die "awake\n"  unless defined $d->{awake}  && $d->{awake} == 1;
        die "source\n" unless defined $d->{source} && $d->{source} eq $id;
        die "wa\n"     unless defined $d->{written_at} && "$d->{written_at}" =~ /\A\d{1,15}\z/;
        if (defined $d->{until}) {
            die "until\n" unless "$d->{until}" =~ /\A\d{1,15}(?:\.\d{1,6})?\z/;
        }
        die "reason\n" unless defined $d->{reason} && $d->{reason} =~ /\A[A-Za-z0-9_.-]{1,64}\z/;
        $entry->{written_at} = 0 + $d->{written_at};
        $entry->{until}      = defined $d->{until} ? 0 + $d->{until} : undef;
        $entry->{reason}     = $d->{reason};
        $entry->{valid}      = 1;
        1;
    };
    return $entry;
}

# read_registry($root) -> \@entries, sorted by id. Never dies.
sub read_registry {
    my ($root) = @_;
    my @out;
    return \@out unless defined $root && length $root;
    my $dir = registry_dir($root);
    opendir(my $dh, $dir) or return \@out;
    my @names = grep { /\A((?:sandbox|fleet|solo)-[A-Za-z0-9][A-Za-z0-9._-]{0,199})\.json\z/ && $1 =~ $ID_RE }
                readdir($dh);
    closedir $dh;
    for my $name (@names) {
        my ($id) = $name =~ /\A(.+)\.json\z/;
        next unless defined $id && $id =~ $ID_RE;
        my $path = "$dir/$name";
        my $entry = _read_entry_file($path, $id);
        push @out, $entry if defined $entry;
    }
    return [ sort { $a->{id} cmp $b->{id} } @out ];
}

# entry_counts(\%e, $now) -> 0|1. Pure (spec 2.2, B3; Decision 26(b)/(c)).
sub entry_counts {
    my ($e, $now) = @_;
    return 0 unless ref $e eq 'HASH' && $e->{valid};
    my $wa = $e->{written_at};
    return 0 unless defined $wa;
    my $fresh = BpAwakeConst::LEASE_FRESH();
    return 0 if $wa > $now + $fresh;
    # Decision 26(c): a solo- entry's `until` is capped at the narrower
    # SOLO_PAUSE_HORIZON (12h past written_at), never the 32h fleet/sandbox
    # horizon (red-team m7) -- fleet- and sandbox- entries keep the wider one
    # (and, per spec 2.6/2.5, never carry `until` at all in production).
    my $horizon = (defined $e->{id} && $e->{id} =~ /\Asolo-/)
        ? BpAwakeConst::SOLO_PAUSE_HORIZON() : BpAwakeConst::FLEET_PAUSE_HORIZON();
    my $u = 0;
    if (defined $e->{until} && $e->{until} <= $wa + $horizon) {
        $u = $e->{until};
    }
    my $bound = $wa + $fresh;
    # Decision 26(b): an entry with an `until` counts through until +
    # LEASE_FRESH, not just until -- a paused drive-solo session that resumes
    # exactly on time must never be released at the boundary itself (the
    # resume call needs a model turn, often tens of seconds).
    $u += $fresh if $u > 0;
    $bound = $u if $u > $bound;
    return $now < $bound ? 1 : 0;
}

# counting_ids($root, $now) -> [ids], sorted.
sub counting_ids {
    my ($root, $now) = @_;
    my $entries = read_registry($root);
    return [ map { $_->{id} } grep { entry_counts($_, $now) } @$entries ];
}

# prune_registry($root, %o) -> { removed => [{id,age}], failed => [ids] }
sub prune_registry {
    my ($root, %o) = @_;
    my %out = (removed => [], failed => []);
    return \%out unless defined $root && length $root;
    my $dir = registry_dir($root);
    return \%out unless -d $dir;

    my $skip = (ref $o{skip} eq 'HASH') ? $o{skip} : {};
    my $unlink = (ref $o{unlink} eq 'CODE') ? $o{unlink} : sub { CORE::unlink($_[0]) };
    my $rename = (ref $o{rename} eq 'CODE') ? $o{rename} : sub { CORE::rename($_[0], $_[1]) };
    my $now = time();
    my $entries = read_registry($root);
    for my $e (@$entries) {
        next if exists $skip->{$e->{id}};
        next if entry_counts($e, $now);

        # Re-read and re-judge THIS ONE file immediately before unlinking
        # (spec 2.2): a producer that refreshed it in between is kept.
        my $fresh_now = time();
        my $recheck = read_registry($root);
        my ($cur) = grep { $_->{id} eq $e->{id} } @$recheck;
        next unless defined $cur;
        next if entry_counts($cur, $fresh_now);

        # review m1 / red-team m5: the re-check above narrows the race but
        # does not close it -- a producer's rename onto <id>.json can still
        # land between that re-check and the unlink below. Move the file to
        # a tombstone first (an atomic rename grabs whatever content is
        # actually there at that instant), then re-judge THAT content. If a
        # producer's fresh rename landed first, the tombstone holds the
        # fresh content, so put it right back instead of deleting it. Only a
        # tombstone that still does not count is unlinked.
        my $tomb = "$cur->{file}.prune.$$";
        unless ($rename->($cur->{file}, $tomb)) {
            # Gone already (another prune or the producer's own withdraw) is
            # fine; still there and un-renameable is the same "failed" shape
            # unlink failure always was.
            my $still = read_registry($root);
            my ($after) = grep { $_->{id} eq $cur->{id} } @$still;
            push @{ $out{failed} }, $cur->{id} if defined $after && !entry_counts($after, time());
            next;
        }
        my $tomb_now = time();
        my $tentry = _read_entry_file($tomb, $cur->{id});
        if (defined $tentry && entry_counts($tentry, $tomb_now)) {
            $rename->($tomb, $cur->{file});
            next;
        }

        my $age = $tomb_now - $cur->{mtime};
        if ($unlink->($tomb)) {
            push @{ $out{removed} }, { id => $cur->{id}, age => $age };
            next;
        }
        my $still = read_registry($root);
        my ($after) = grep { $_->{id} eq $cur->{id} } @$still;
        push @{ $out{failed} }, $cur->{id} if defined $after && !entry_counts($after, time());
    }
    $out{removed} = [ sort { $a->{id} cmp $b->{id} } @{ $out{removed} } ];
    $out{failed}  = [ sort @{ $out{failed} } ];
    return \%out;
}

# decide(\%in) -> \%d. PURE: no I/O, no clock, no %ENV (spec 2.2, B5).
#
# Package 09 (D0): battery past grace overrides every other source -- arms,
# counting registry entries, fresh sandbox holds, old holds -- into hold,
# which releases the helper and lets reconcile restore the plan. D0 fires
# only while something would otherwise hold (D1-D4 unchanged, including the
# "battery release but nothing holding" rows, which fall straight through to
# whatever D1-D4 already say). Any $in->{battery} value other than the exact
# string "release" (absent included) means hold, so a caller that never asks
# the battery question behaves exactly as before 09.
sub decide {
    my ($in) = @_;
    die "HostAwake::decide: not a HASH\n" unless ref $in eq 'HASH';
    my $counting = (ref $in->{counting} eq 'ARRAY') ? $in->{counting} : [];
    my $arms = (defined $in->{arms} && $in->{arms} =~ /\A\d+\z/) ? $in->{arms} : 0;
    my $fresh_holds = (defined $in->{fresh_holds} && $in->{fresh_holds} =~ /\A\d+\z/) ? $in->{fresh_holds} : 0;
    my $pending = $in->{pending} ? 1 : 0;
    my $battery_release = (defined $in->{battery} && $in->{battery} eq 'release') ? 1 : 0;

    if ($battery_release && ($arms > 0 || @$counting > 0 || $fresh_holds > 0)) {
        return { mode => 'hold', lock => 0, plan_hold => 0, why => 'refresher-hold-tick',
                 counting => $counting, battery => 1 };
    }

    if ($arms > 0) {
        return { mode => 'arm', lock => 1, plan_hold => 1, why => 'refresher-tick',
                 counting => $counting, battery => 0 };
    }
    if (@$counting > 0) {
        return { mode => 'source', lock => 1, plan_hold => 1, why => 'refresher-source-tick',
                 counting => $counting, battery => 0 };
    }
    if ($pending) {
        return { mode => 'hold', lock => 0, plan_hold => ($fresh_holds > 0 ? 1 : 0),
                 why => 'refresher-hold-tick', counting => $counting, battery => 0 };
    }
    return { mode => 'idle', lock => 0, plan_hold => 0, why => 'refresher-exit', counting => $counting, battery => 0 };
}

# host_ac_dir($root) -> "$root/host-ac" | undef (package 09, spec 2.2). undef
# for an undef or empty root. BpAcWatch's own helpers append /.drive-solo, so
# the actual state file sits at host_ac_dir($root) . '/.drive-solo/ac-state.json'.
sub host_ac_dir {
    my ($root) = @_;
    return (defined $root && length $root) ? "$root/host-ac" : undef;
}

# battery_releases($root, $now) -> 0|1 (package 09, spec 2.2). No probe, no
# write, never dies. This is the ONLY battery question reconcile asks --
# every other caller goes through gather/decide instead. Fail-open: 0 (hold)
# for an undef root, any load/call failure, or a missing/garbled state.
sub battery_releases {
    my ($root, $now) = @_;
    return 0 unless defined $root && length $root;
    my $hdir = host_ac_dir($root);
    return 0 unless defined $hdir;
    my $v = eval {
        require "$DIR/BpAcWatch.pm" unless defined &BpAcWatch::battery_verdict;
        BpAcWatch::battery_verdict(BpAcWatch::read_state($hdir), defined $now ? $now : time());
    };
    return 0 unless ref $v eq 'HASH';
    return (($v->{verdict} // '') eq 'release') ? 1 : 0;
}

# battery_step($dir, $root, %o) -> \%v (package 09, spec 2.2). One host_step
# tick of the host-wide BpAcWatch instance under host_ac_dir($root), plus the
# journal record a VERDICT CHANGE (not every tick) writes. Never dies; any
# internal failure gives {verdict => hold, basis => error, journaled => 0}.
#
# Decision 29(a) (fix-batch): the "last announced" verdict this compares
# against lives in the host-ac state itself (BpAcWatch::read_state's
# `announced` key, under its own lock -- BpAcWatch::mark_announced), never
# in a per-process cache. A per-process cache (keyed by dir, defaulting to
# "hold" the first time a process sees it) duplicated a "released" record on
# every refresher restart or handover, because the NEW process's cache
# always started at "hold" even though the state on disk was already
# release -- and it lost the "held" edge entirely when the daemon
# idle-exited mid-outage, because the next process to run also started its
# cache at "hold" (review M1). Reading `announced` from disk means any
# process, cold-started or not, agrees with whatever the LAST process
# actually got journaled -- and `mark_announced` is called ONLY after
# `append_record` returns success, so a failed append leaves `announced`
# unchanged and the very next tick retries rather than silently dropping
# the edge forever.
sub battery_step {
    my ($dir, $root, %o) = @_;
    my $result = eval {
        require "$DIR/BpAcWatch.pm" unless defined &BpAcWatch::host_step;
        my $hdir = host_ac_dir($root);
        # Time::HiRes, not time(): a daemon tick's own test seam (no real
        # sleep between iterations) can run two ticks within the same
        # integer second, and observe()'s "has it been _probe_interval()
        # seconds since the last probe" check needs sub-second resolution to
        # tell those two ticks apart -- an integer $now would make the
        # second tick's elapsed time read as 0 and skip the reprobe that a
        # fast test seam (CCPRAXIS_AC_TICK_SECONDS) exists to force.
        my $now = defined $o{now} ? $o{now} : Time::HiRes::time();
        # Read the announced verdict from disk BEFORE stepping (spec 2.2
        # step 2's own "prev = ... read before stepping"), so this call's
        # own write (inside host_step) can never be mistaken for the
        # previous tick's announcement.
        my $prev_state = BpAcWatch::read_state($hdir);
        my $prev_verdict = (ref $prev_state eq 'HASH' && defined $prev_state->{announced}
            && length $prev_state->{announced}) ? $prev_state->{announced} : 'hold';
        my %step_opts = (now => $now, src => 'host-awake');
        $step_opts{probe} = $o{probe} if ref $o{probe} eq 'CODE';
        my $cur = BpAcWatch::host_step($hdir, %step_opts);
        die "HostAwake::battery_step: host_step returned a non-HASH\n" unless ref $cur eq 'HASH';
        my $cur_verdict = $cur->{verdict} // 'hold';

        my $journaled = 0;
        if ($prev_verdict ne $cur_verdict) {
            require "$DIR/BpPowerJournal.pm" unless defined &BpPowerJournal::awake_record;
            my $rec = BpPowerJournal::awake_record(
                now => $now,
                state => (($cur->{verdict} // '') eq 'release' ? 'released' : 'held'),
                basis => $cur->{basis}, phase => $cur->{phase}, power_source => $cur->{source},
                on_battery_since => $cur->{dc_since}, grace_until => $cur->{grace_until},
                arms => $o{arms}, sources => $o{counting}, fresh_holds => $o{fresh_holds},
            );
            $journaled = BpPowerJournal::append_record($dir, $rec) ? 1 : 0;
            BpAcWatch::mark_announced($hdir, $cur_verdict) if $journaled;
        }
        return { %$cur, journaled => $journaled };
    };
    return (ref $result eq 'HASH') ? $result : { verdict => 'hold', basis => 'error', journaled => 0 };
}

# gather($dir, %o) -> \%in. Reads the inputs decide() needs (spec 2.2).
sub gather {
    my ($dir, %o) = @_;
    require "$DIR/BpContinuityLease.pm" unless defined &BpContinuityLease::platform;
    my $root = BpContinuityLease::store_root_for($dir);
    my %in = (arms => $o{arms});

    if ((BpContinuityLease::platform() ne 'windows') || !defined $root || !length $root) {
        $in{arms}          = 0 unless defined $in{arms};
        $in{counting}      = [];
        $in{fresh_holds}   = 0;
        $in{pending}       = 0;
        $in{battery}       = 'hold';
        $in{battery_basis} = 'off-platform';
        return \%in;
    }

    # review m6: spec 2.2 says "when absent, gather counts live_arms($root)".
    # The daemon always passes arms explicitly (from the same active_reason
    # call it already made), so this only matters for a future caller (09's
    # battery filter) that calls gather($dir) with no arms key.
    unless (defined $in{arms}) {
        my $la = eval { BpContinuityLease::live_arms($root) };
        $in{arms} = (ref $la eq 'ARRAY') ? scalar(@$la) : 0;
    }

    require "$DIR/BpPowerPlan.pm" unless defined &BpPowerPlan::sandbox_holds;
    # Time::HiRes, not time(): see battery_step's own header for why -- the
    # daemon tick path (the only caller that never passes {now}) needs
    # sub-second resolution for the battery probe interval to behave right
    # under a fast test seam; counting_ids/sandbox_holds only ever compare
    # $now numerically, so the extra precision changes nothing for them.
    my $now = defined $o{now} ? $o{now} : Time::HiRes::time();
    $in{counting}    = counting_ids($root, $now);
    $in{fresh_holds} = scalar @{ BpPowerPlan::sandbox_holds($root) };

    my $skip_sources = (ref $o{skip_sources} eq 'HASH') ? $o{skip_sources} : {};
    my $reg_pending = 0;
    for my $e (@{ read_registry($root) }) {
        unless (exists $skip_sources->{$e->{id}}) { $reg_pending = 1; last }
    }
    $in{pending} = (BpContinuityLease::holds_pending($dir, skip => $o{skip_holds}) || $reg_pending) ? 1 : 0;

    # Package 09: the battery question is only ever worth asking (a probe,
    # a state file) when something could hold -- an arm, a counting source,
    # or a fresh sandbox hold. With nothing that could hold, battery is moot
    # (D0 never fires anyway: it requires one of those three to be
    # nonzero), so no host-ac state is read, probed or created.
    if ($in{arms} > 0 || @{ $in{counting} } > 0 || $in{fresh_holds} > 0) {
        my $bres = eval {
            battery_step($dir, $root, now => $now, probe => $o{ac_probe},
                arms => $in{arms}, counting => $in{counting}, fresh_holds => $in{fresh_holds});
        };
        if (ref $bres eq 'HASH') {
            $in{battery}       = $bres->{verdict} // 'hold';
            $in{battery_basis} = $bres->{basis}   // 'error';
        }
        else {
            # battery_step died (or a test stubbed it to die) or returned
            # something unusable -- fail open to hold, never let a battery
            # subsystem failure silently release every source (AC12(d)).
            $in{battery}       = 'hold';
            $in{battery_basis} = 'error';
        }
    }
    else {
        $in{battery}       = 'hold';
        $in{battery_basis} = 'not-needed';
    }

    return \%in;
}

# ---------------------------------------------------------------------------
# Producer helpers (spec 2.2)
# ---------------------------------------------------------------------------

# ensure_refresher(%o) -> 'running'|'spawned'|'idle'|'refused'
sub ensure_refresher {
    my (%o) = @_;
    my $v = eval {
        require "$DIR/BpContinuityLease.pm" unless defined &BpContinuityLease::ensure_daemon;
        my $dir = BpContinuityLease::legacy_dir();
        return 'refused' unless defined $dir;
        return BpContinuityLease::ensure_daemon($dir, %o);
    };
    return (defined $@ && length $@) ? 'refused' : (defined $v ? $v : 'refused');
}

# announce($id, \%intent, %o) -> ($wrote, $verdict)
sub announce {
    my ($id, $intent, %o) = @_;
    my $wrote = publish($id, $intent, %o);
    return (0, undef) unless $wrote;
    my $ensure = (ref $o{ensure} eq 'CODE') ? $o{ensure} : \&ensure_refresher;
    my $verdict = eval { $ensure->() };
    return (1, $verdict);
}

# retire_legacy_helper($dir, %o) -> 1|0
sub retire_legacy_helper {
    my ($dir, %o) = @_;
    return 0 unless defined $dir && length $dir;
    my $pf = "$dir/keepawake.pid";
    return 1 unless -e $pf;
    if ($^O =~ /^(MSWin32|msys|cygwin)$/) {
        eval {
            require "$DIR/bp-keepawake.pl" unless defined &BpKeepAwake::read_pid;
            my $pid = BpKeepAwake::read_pid($pf);
            if (defined $pid) {
                my $killp = (ref $o{kill_pid} eq 'CODE') ? $o{kill_pid} : \&BpKeepAwake::kill_pid;
                $killp->($pid, $pf);
            }
        };
    }
    unlink $pf;
    return -e $pf ? 0 : 1;
}

# ---------------------------------------------------------------------------
# CLI (spec 2.2)
# ---------------------------------------------------------------------------
sub main {
    my (@argv) = @_;
    if (@argv == 1 && $argv[0] eq 'ensure') {
        ensure_refresher();
        return 0;
    }
    print STDERR "usage: perl HostAwake.pm ensure\n";
    return 2;
}

exit(main(@ARGV)) unless caller;

1;
