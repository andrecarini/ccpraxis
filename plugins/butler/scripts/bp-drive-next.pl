#!/usr/bin/env perl
# bp-drive-next.pl — the mechanical director for /butler:drive-solo.
# Stateless-from-disk: every `next` recomputes from ledgers + <data>/.drive-solo/.
#
# USAGE
#   bp-drive-next.pl next --scope <spec>
#   bp-drive-next.pl record-order <bp> [<bp> …]
#   bp-drive-next.pl park <blueprint> [--needs-operator] <reason…>
#   bp-drive-next.pl --help
#
# SUBCOMMANDS
#   next --scope <spec>
#       Print exactly ONE next-action JSON (below) to stdout, single line.
#       <spec> = one blueprint name | comma/space list of names | "all" (or empty)
#       = all audited blueprints. <spec> resolves mechanically to the candidate SET
#       and is used ONLY for need-order candidates; once order.json exists it is the
#       authoritative scope+order and --scope is ignored.
#   record-order <bp> [<bp> …]
#       Persist the SESSION-judged blueprint order to order.json. The director never
#       invents order — it only persists and serves it.
#   park <blueprint> [--needs-operator] <reason…>
#       Write status: parked and the reason into the blueprint's OWN blueprint.md
#       (via bp-blueprint.pl set-meta), idempotent, and log it. A parked blueprint is
#       settled: never driven, excluded from every pending list. --needs-operator also
#       files one inbox item linked to the blueprint; unparking is a plain set-meta
#       status write, which closes that item. A legacy park file, if one exists, is
#       migrated into blueprint.md on the first call and then removed (package
#       08-blueprint-parks).
#
# NEXT-ACTION JSON  (exactly one per `next`)
#   {"action":"need-order","candidates":[…]}          no order yet; session must judge+record
#   {"action":"run-package","blueprint":B,"package":P} drive this package next
#   {"action":"pause","until_epoch":E,"reason":"usage"} timed auto-resume at epoch E
#   {"action":"pause-long","reason":"usage","until_epoch":E,"until_iso":"…"}  usage pause ending
#                                                      more than 12 h out: the session writes its
#                                                      handoff and ends; no auto-resume in this session
#   {"action":"stop","reason":"token-refresh-failed","detail":…} token could not be
#                                                      refreshed; the wake-lock is released and the
#                                                      run ends. NOT a pause: a pause promises a
#                                                      resume, and there is none until a human
#                                                      re-authenticates.
#   {"action":"blueprint-done","blueprint":B,"pending":[…],"archived":true|false,
#    "archive_detail":"…"}                             B settled; pending = remaining bps to re-eval;
#                                                      archived reports whether the director's own
#                                                      single-blueprint archive attempt (reusing
#                                                      bp-lifecycle.pl reconcile --archive) landed —
#                                                      archive_detail names the outcome either way
#   {"action":"in-flight","blueprint":B,"packages":[…],"running":[…]}
#                                                      nothing dispatchable right now, but B still
#                                                      holds non-terminal packages (typically owned by
#                                                      a concurrent worker). NOT completion: stopping
#                                                      here kills the run mid-package.
#   {"action":"done","denials":N}                      every in-scope blueprint is done-or-parked;
#                                                      N = cumulative auto-mode denial count (never-halt
#                                                      Decision 9; see `bp-denials summary` for a breakdown)
#   {"action":"ac-stand-down","reason":"ac-loss","on_battery_since_iso":…,
#    "grace_expired_iso":…,"inflight":[…],"monitor_live":true|false,
#    "log":…}                                          package 11 (tooling-backlog): AC power has been
#                                                      lost past the 5-minute grace period. Stand down
#                                                      in-flight local dispatches, disarm continuity,
#                                                      release the wake-lock and start/confirm
#                                                      bp-ac-watch.pl monitor; see the drive-solo SKILL.
#
#   Keep-awake is a director-managed SIDE EFFECT (started when work is runnable or a
#   timed auto-resume is pending; stopped when settled) — never an action.
#
# GOVERNOR VERDICT CONSUMED  (from bp-usage-gate.pl verdict — pkg-02)
#   {"action":"ok"|"pause-usage"|"pause-token"|"unavailable","until_epoch":E|null,"reason":…}
#   ok           → proceed
#   pause-usage  → pause reason=usage, until_epoch=E; pause-long instead when E - now > 12 h
#   pause-token  → attempt a refresh (bp-token-keeper). Recovered → proceed;
#                  failed → action=stop, wake-lock released, error logged.
#                  Solo NEVER pauses for token expiry — see _token_recover.
#   unavailable  → retry a few times, then degrade-and-proceed (log "governance degraded")
#
# STATE  (<data>/.drive-solo/, all director-owned)
#   order.json      {"order":[…],"recorded_at":<epoch>}
#   announced.json  {"announced":[…]}   blueprints whose blueprint-done already fired
#   inflight.json   {"packages":[{"blueprint":…,"package":…,"ledger":…,"since":<epoch>}],
#                   "updated_at":<epoch>}   the project-level in-flight set
#                   (package 11): a package is added on run-package, removed
#                   once its ledger turns terminal. Batch C (spec 16-cutover):
#                   concurrent hand-out (a further ready package whose write
#                   set is disjoint from every in-flight one) is unconditional
#                   now; current.json and the old concurrency-switch env var
#                   no longer exist.
#   inflight.lock   exclusive-lock file guarding one `next` call's read+prune
#                   +write of inflight.json (never deleted; contents unused).
#   keepawake.pid   PID of the wake-lock process (host only; sandbox = no file)
#   run.md          append-only structured run log

package BpDrive;
use strict;
use warnings;
use JSON::PP;
use File::Path qw(make_path);
use File::Basename qw(dirname basename);
use Cwd qw(abs_path);
use Fcntl qw(:flock);
use Errno ();
use POSIX qw(strftime);
use Encode ();
use File::Spec ();
# Loaded WITHOUT importing `time`/`sleep` — this file's default `now` seam is
# bare `time` (CORE, integer epoch, per spec "Integer epochs"); importing
# Time::HiRes's floating-point time() would silently change that contract.
# Called fully-qualified (Time::HiRes::time / ::sleep) at the one call site
# that needs sub-second precision: the inflight.lock poll (package 11).
use Time::HiRes ();

# MSYS2 path-conversion guard (house rule — EC-7 / Landmine #1): this script may
# spawn powershell / taskkill with ':'-bearing args on a Windows host.
BEGIN { $ENV{MSYS2_ARG_CONV_EXCL} = '*' if $^O =~ /^(MSWin32|cygwin|msys)$/; }

# How many verdict attempts before degrading (spec §2.5, Decision #14).
our $VERDICT_RETRY_MAX = 3;

# How far ahead a usage pause may resume and still justify holding the machine
# awake for it. Six hours: the FIVE-HOUR usage window can never reopen more than
# five hours out, so this covers it with an hour of slack, while excluding the
# seven-day window entirely. See the pause branch in run_next() for why that
# distinction is the whole point.
our $KEEPAWAKE_PAUSE_HORIZON_SECONDS = 6 * 3600;

# Absolute script dir: lets tests `require` from any working dir.
my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; abs_path($f) // $f });

# b44: require bp-orchestrator.pl SOLELY to delegate to its one new pure
# function, BpOrch::order_ready (priority-ordering of an already-eligible ready
# set). This is deliberately narrow — the other eight functions this file
# mirrors from BpOrch (see the `# Mirrored from BpOrch::...` comments below)
# are left as faithful copies on purpose (spec b44-execution-priority §3.1);
# t/drive-next.t asserts BpDrive's own write_sets_overlap behaviour
# (including its deliberate empty-prefix landmine), so collapsing those
# mirrors into requires would churn an immutable oracle for no gain here.
# Measured safe to require: bp-orchestrator.pl is `package BpOrch;` ending
# `package main; unless (caller) {...} 1;`, requires cleanly in ~0.1s with no
# side effects, and its whole require-tree is core-Perl only (t/06 already
# does this same require).
require "$DIR/bp-orchestrator.pl";
require "$DIR/bp-keepawake.pl";    # the shared wake-lock (also used by the fleet)
require "$DIR/BpDataRoot.pm";      # the single, bounded data-root resolution chain (package 04)
require "$DIR/BpHook/PromptWatch.pm";  # denial_count() for the `done` action's denials key (never-halt 06)

# ===========================================================================
# PURE DECISION FUNCTIONS (no I/O, no globals, no network — unit-tested in t/17)
# ===========================================================================

# --- terminal status: done|dropped|blocked|parked
# Mirrored from BpOrch::_is_terminal (bp-orchestrator.pl line 66).
sub _is_terminal { my $s = shift // ''; $s =~ /^(done|dropped|blocked|parked)$/ ? 1 : 0 }

# --- inflight.json entry name validity (spec §2.2): the same regex parse_dag
# already uses for a dependency name.
sub _valid_name {
    my ($s) = @_;
    return (defined $s && !ref $s && $s =~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/) ? 1 : 0;
}

# --- inflight.json entry ledger string (spec §2.2): "<L>/blueprints/<bp>/
# packages/<pkg>.md" where <L> is the basename of $data after turning '\'
# into '/' and dropping trailing slashes. Informational only — the director
# always derives the ledger FILE it reads from blueprint+package, never from
# this string.
sub _ledger_str {
    my ($data, $bp, $pkg) = @_;
    (my $d = $data) =~ s{\\}{/}g;
    $d =~ s{/+$}{};
    return basename($d) . "/blueprints/$bp/packages/$pkg.md";
}

# --- has any non-terminal package with no dead-ended dep?
# Mirrored from BpOrch::has_progressable_work (bp-orchestrator.pl line 247-263).
sub has_progressable_work {
    my ($meta, $status) = @_;
    for my $pkg (keys %$meta) {
        my $st = $status->{$pkg} // 'pending';
        next if _is_terminal($st);
        my $dead_dep = 0;
        for my $d (@{ $meta->{$pkg}{deps} || [] }) {
            my $ds = $status->{$d} // 'pending';
            # a dependency that is terminal-but-not-done can never satisfy deps_met
            $dead_dep = 1 if _is_terminal($ds) && $ds ne 'done';
        }
        return 1 unless $dead_dep;
    }
    return 0;
}

# 1. resolve_scope($spec, \@all_bp_names) → @candidate_bps
# "all" / empty → whole list; else split on commas/whitespace, filter to known
# names, dedupe, first-seen order.
sub resolve_scope {
    my ($spec, $all) = @_;
    $spec //= '';
    if ($spec eq '' || $spec eq 'all') {
        return @$all;
    }
    my %known = map { $_ => 1 } @$all;
    my %seen;
    my @out;
    for my $name (split /[,\s]+/, $spec) {
        next unless length $name;
        next unless $known{$name};
        next if $seen{$name}++;
        push @out, $name;
    }
    return @out;
}

# 1a. blueprint_lifecycle($bpdir) → 'drafting'|'audited'|'parked'|'archived'|'' (unknown)
# Reads blueprint.md's OWN `status:` -- the authoring lifecycle. That is a
# different axis from package status (which lives in ledger frontmatter) and from
# the run states this file computes; blueprint.md's own comment says so:
# "drafting | audited | parked | archived -- running/done are computed".
# Bounded to the first 40 lines because it is frontmatter: a `status:` further
# down is prose about a package, not the blueprint's declaration.
# 08-blueprint-parks: this local reader/gate pair is UNCHANGED by that package.
# `parked` stays drivable here (fails open, see blueprint_drivable below) --
# exclusion of a parked blueprint from driving is handled entirely through
# `_bp_parked($bpdir)` / `%parked` (spec §2.5), never through this function.
sub blueprint_lifecycle {
    my ($bpdir) = @_;
    open my $fh, '<', "$bpdir/blueprint.md" or return '';
    my $out = '';
    while (my $l = <$fh>) {
        last if $. > 40;
        if ($l =~ /^status:\s*(\S+)/) { $out = lc $1; last }
    }
    close $fh;
    return $out;
}

# 1b. blueprint_drivable($lifecycle) → 0|1
# FAILS OPEN, deliberately: only a positively-read `drafting` or `archived`
# excludes. A missing or unrecognised status stays drivable, because the two
# errors are not symmetric -- wrongly refusing to drive stalls an unattended run
# with nobody present to notice, while wrongly driving one costs a package that a
# human can re-scope. Same asymmetry the run-finish guard is built on.
sub blueprint_drivable {
    my ($lc) = @_;
    $lc = defined $lc ? lc $lc : '';
    return ($lc eq 'drafting' || $lc eq 'archived') ? 0 : 1;
}

# 2. deps_met($deps, $status) → 0|1
# Mirrored from BpOrch::deps_met (bp-orchestrator.pl line 87-92).
sub deps_met {
    my ($deps, $status) = @_;
    return 1 unless ref $deps eq 'ARRAY' && @$deps;
    for my $d (@$deps) { return 0 unless ($status->{$d} // '') eq 'done'; }
    return 1;
}

# 2. write_sets_overlap($wa, $wb) → 0|1
# Mirrored from BpOrch::write_sets_overlap (bp-orchestrator.pl line 96-121).
# EC-1 / Landmine #4: empty prefix matches anything — mirror faithfully, do NOT fix.
sub _ws_prefixes {
    my ($ws) = @_;
    my @out;
    for my $p (split /:/, (defined $ws ? $ws : '')) {
        next unless length $p;
        $p =~ s{\*.*$}{};   # cut at first glob -> directory prefix
        $p =~ s{/+$}{};     # drop trailing slash(es)
        push @out, $p;
    }
    return @out;
}
sub _prefix_related {
    my ($a, $b) = @_;
    return 1 if $a eq $b;
    return 1 if $a eq '' || $b eq '';      # empty prefix matches anything (Landmine #4)
    return 1 if index("$b/", "$a/") == 0; # a is ancestor dir of b
    return 1 if index("$a/", "$b/") == 0; # b is ancestor dir of a
    return 0;
}
sub write_sets_overlap {
    my ($wa, $wb) = @_;
    my @a = _ws_prefixes($wa);
    my @b = _ws_prefixes($wb);
    # Faithful mirror of BpOrch::write_sets_overlap (Decision #9, spec §3#3/EC-1):
    # empty prefix lists -> the loop body never runs -> returns 0 (disjoint), exactly
    # like the orchestrator. Do NOT inject a conservative '' default here; that would
    # diverge from the fleet on empty-string write-sets (the real Landmine #4 is a
    # bare glob collapsing to an empty PREFIX, which _prefix_related already handles).
    for my $x (@a) { for my $y (@b) { return 1 if _prefix_related($x, $y); } }
    return 0;
}

# 2. ready_packages($meta, $status, $running) → @ready
# Mirrored from BpOrch::ready_packages (bp-orchestrator.pl line 125-138).
# In solo $running is always [], but the disjointness clause must still be present.
sub ready_packages {
    my ($meta, $status, $running) = @_;
    my @run_ws = map { $meta->{$_}{write_set} } grep { exists $meta->{$_} } @{ $running || [] };
    my @ready;
    for my $pkg (sort keys %$meta) {
        my $st = $status->{$pkg} // 'pending';
        next unless $st eq 'pending';
        next unless deps_met($meta->{$pkg}{deps}, $status);
        my $ws = $meta->{$pkg}{write_set};
        next if grep { write_sets_overlap($ws, $_) } @run_ws;
        push @ready, $pkg;
    }
    # b44: delegate ordering to the ONE shared rule (BpOrch::order_ready) rather
    # than growing a second copy of the priority-sort logic here.
    return BpOrch::order_ready(\@ready, $meta);
}

# 4. blueprint_settled($meta, $status, $parked_bool) → 0|1
# Settled if parked OR no progressable work AND no ready package (all terminal).
sub blueprint_settled {
    my ($meta, $status, $parked) = @_;
    return 1 if $parked;
    # Settled = nothing can progress without human intervention. A blocked/parked
    # package that dead-ends its dependents leaves NO progressable work even though
    # those dependents are still 'pending' (spec EC-10) — so settled is exactly
    # !has_progressable_work. Do NOT additionally require every package be terminal
    # (that stricter gloss in spec §3#4 contradicts the immutable oracle t/17 #76).
    return has_progressable_work($meta, $status) ? 0 : 1;
}

# 7. keepawake_should_be_on($run_phase) → 0|1
# active/pause-pending → 1; settled → 0.
# Delegates to BpKeepAwake — ONE definition of the wake-lock, shared with the
# fleet orchestrator (see bp-keepawake.pl's header for why it is not copied).
# The name stays here because it is part of this module's tested surface.
sub keepawake_should_be_on {
    my ($phase) = @_;
    return BpKeepAwake::should_be_on($phase);
}

# 8. pending_blueprints(\@order, $done_or_parked_href) → @pending
# Returns later-in-order blueprints that are neither done nor parked.
sub pending_blueprints {
    my ($order, $done_or_parked) = @_;
    my @out;
    for my $bp (@$order) {
        push @out, $bp unless $done_or_parked->{$bp};
    }
    return @out;
}

# 6. verdict_to_action($verdict, $now) → hash
# Maps one verdict hash → proceed ({ok=>1}), pause action, or {unavailable=>1}.
sub verdict_to_action {
    my ($verdict, $now) = @_;
    my $act = $verdict->{action} // 'unavailable';
    if ($act eq 'ok') {
        return { ok => 1 };
    } elsif ($act eq 'pause-usage') {
        return { action => 'pause', reason => 'usage', until_epoch => $verdict->{until_epoch} };
    } elsif ($act eq 'pause-token') {
        # DRIVE-SOLO DOES NOT PAUSE FOR TOKEN EXPIRY, but it does not ignore it
        # either. Operator decision (2026-08-12).
        #
        # The token floor is a safeguard for the UNATTENDED fleet, where a
        # mid-flight death strands headless coordinators nobody is watching.
        # Solo is different in the way that matters: a human is in the session
        # and the work is committed incrementally. Parking here bought no safety
        # and cost the whole session, which then had to be picked up by hand --
        # exactly the cost the floor was meant to avoid.
        #
        # So the caller does not pause and does not blindly proceed. It attempts
        # a REFRESH (see _token_recover), and the outcome decides:
        #   refreshed  -> carry on, nobody is told anything
        #   failed     -> STOP cleanly: release the wake-lock, log the error
        # The failure branch matters because the alternative is worse than a
        # pause: proceeding on a dead token means the next API call 401s and the
        # session dies mid-write, holding a wake-lock, with no record of why.
        return { token_floor => 1 };
    } else {
        # unavailable or unknown
        return { unavailable => 1 };
    }
}

# ===========================================================================
# I/O HELPERS (tolerate missing/malformed files; never die on absence)
# ===========================================================================

sub _read_file {
    my ($f) = @_;
    open my $fh, '<:raw', $f or return undef;
    local $/; my $r = <$fh>; close $fh; $r;
}

sub _read_json_file {
    my ($f, $dsdir) = @_;
    my $txt = _read_file($f);
    return undef unless defined $txt;
    my $d = eval { JSON::PP->new->decode($txt) };
    if ($@) {
        # Malformed JSON — treat as absent + log warning (B10 / EC-9)
        _append_run_log($dsdir, "WARN malformed JSON in $f — treating as absent") if defined $dsdir;
        return undef;
    }
    return $d;
}

# Atomic write (temp + rename), mirrored from BpOrch::write_paused.
sub _write_json_atomic {
    my ($path, $data) = @_;
    my $json = JSON::PP->new->canonical->encode($data);
    my $tmp  = "$path.tmp.$$";
    open my $fh, '>:raw', $tmp or die "bp-drive-next: write $tmp: $!";
    print $fh $json;
    close $fh;
    rename $tmp, $path or do { unlink $tmp; die "bp-drive-next: rename $tmp -> $path: $!"; };
}

# ===========================================================================
# IN-FLIGHT SET (package 11, spec §2.2/2.5/2.6/2.7) — project-level, written
# only by the director. Batch C (spec 16-cutover, 1.3 departure #9/#10):
# current.json is gone. The director never creates, reads or removes it, and
# seed_from_current is removed rather than kept as a migration path (the live
# director already writes inflight.json before promotion).
# ===========================================================================

# load_inflight($data, $dsdir, $now) -> (\@entries, $dirty) (spec §2.5)
sub load_inflight {
    my ($data, $dsdir, $now) = @_;
    my $existed = -e "$dsdir/inflight.json" ? 1 : 0;
    my $raw = _read_json_file("$dsdir/inflight.json", $dsdir);
    unless (ref $raw eq 'HASH' && ref $raw->{packages} eq 'ARRAY') {
        return ([], $existed ? 1 : 0);
    }
    my @entries;
    my %seen;
    my $dirty = 0;
    for my $e (@{ $raw->{packages} }) {
        if (ref $e eq 'HASH'
            && _valid_name($e->{blueprint}) && _valid_name($e->{package})
            && defined $e->{ledger} && !ref $e->{ledger}
            && defined $e->{since} && !ref $e->{since} && $e->{since} =~ /^-?\d+$/) {
            my $key = "$e->{blueprint}\0$e->{package}";
            if ($seen{$key}++) { $dirty = 1; next; }   # first of any duplicate pair wins
            push @entries, {
                blueprint => $e->{blueprint}, package => $e->{package},
                ledger    => $e->{ledger},    since   => $e->{since} + 0,
            };
        } else {
            $dirty = 1;
        }
    }
    return (\@entries, $dirty);
}

# _bp_parked($bpdir) -> 0|1 (package 08-blueprint-parks, spec §2.5). The ONE
# parkedness test in this file: 1 iff blueprint.md's own authored status
# (BpState::bp_meta_get + BpState::norm_bp_status, the same reader
# _archive_gate already loads BpState for) is 'parked'. No other code in
# this file names a legacy park file any more -- see _migrate_parks_json,
# the one remaining reader, which absorbs it into blueprint.md before any of
# this runs.
sub _bp_parked {
    my ($bpdir) = @_;
    require "$DIR/BpState.pm" unless defined &BpState::norm_bp_status;
    return (BpState::norm_bp_status(BpState::bp_meta_get("$bpdir/blueprint.md", 'status')) eq 'parked') ? 1 : 0;
}

# _prune_inflight($data, \@entries) -> $dirty (spec §2.6). Mutates @entries
# in place (drops terminal-ledger, missing-ledger and parked-blueprint ones).
sub _prune_inflight {
    my ($data, $entries) = @_;
    my @kept;
    my $dirty = 0;
    for my $e (@$entries) {
        my ($bp, $pkg) = ($e->{blueprint}, $e->{package});
        my $bpdir = "$data/blueprints/$bp";
        # red-team M3: a set entry whose blueprint dir/blueprint.md is gone, or
        # whose blueprint.md itself says `drafting`, can never be resumed by
        # any driver -- prune it rather than let it block overlapping work
        # forever. Same status read the director already uses for blueprints.
        if (!-d $bpdir || !-f "$bpdir/blueprint.md") { $dirty = 1; next; }
        if (blueprint_lifecycle($bpdir) eq 'drafting') { $dirty = 1; next; }
        if (!-f "$bpdir/packages/$pkg.md") { $dirty = 1; next; }
        if (_bp_parked($bpdir))            { $dirty = 1; next; }
        my $status = ledger_fm($bpdir, $pkg, 'status') // 'pending';
        if (_is_terminal($status))         { $dirty = 1; next; }
        push @kept, $e;
    }
    @$entries = @kept;
    return $dirty;
}

# _write_inflight_set($dsdir, \@entries, $now) — atomic, NEVER FATAL (spec
# §2.3): a failure (unwritable dir, inflight.json existing as a directory,
# rename failure) is logged as one WARN line and changes nothing else.
sub _write_inflight_set {
    my ($dsdir, $entries, $now) = @_;
    eval {
        make_path($dsdir) unless -d $dsdir;
        _write_json_atomic("$dsdir/inflight.json", { packages => $entries, updated_at => $now });
    };
    if ($@) {
        _append_run_log($dsdir, "WARN inflight.json write failed: $@");
    }
    return;
}

# _acquire_inflight_lock($dsdir, $opts) -> $filehandle | undef (spec §2.4).
# Exclusive, non-blocking, polled every 100ms up to
# $opts->{inflight_lock_timeout} seconds (default 30). NEVER FATAL: any
# failure (cannot open, flock error, timeout) logs one WARN line and returns
# undef so the caller proceeds unlocked — a stalled `next` is worse than a
# racy one. The lock is released implicitly when the returned filehandle goes
# out of scope (held for the caller's whole lifetime, exactly the critical
# section the spec names).
sub _acquire_inflight_lock {
    my ($dsdir, $opts) = @_;
    my $timeout  = $opts->{inflight_lock_timeout} // 30;
    my $lockfile = "$dsdir/inflight.lock";
    my $fh;
    unless (open $fh, '>>', $lockfile) {
        _append_run_log($dsdir, "WARN inflight.lock: cannot open $lockfile: $!");
        return undef;
    }
    my $deadline = Time::HiRes::time() + $timeout;
    while (1) {
        my $got = eval { flock($fh, LOCK_EX | LOCK_NB) };
        return $fh if $got;
        # review M3: only contention (EWOULDBLOCK/EAGAIN) is worth polling for.
        # Any other flock failure (ENOLCK, EINVAL, ENOSYS, a die from $@, …) is
        # not going to clear itself in 30s of retrying — log one WARN and
        # proceed unlocked immediately, exactly like the timeout branch below.
        unless (!$@ && ($!{EWOULDBLOCK} || $!{EAGAIN})) {
            my $why = $@ ? do { (my $e = $@) =~ s/\s+\z//; $e } : $!;
            _append_run_log($dsdir, "WARN inflight.lock: flock failed: $why — proceeding unlocked");
            close $fh;
            return undef;
        }
        if (Time::HiRes::time() >= $deadline) {
            _append_run_log($dsdir,
                "WARN inflight.lock: timed out after ${timeout}s waiting for the lock — proceeding unlocked");
            close $fh;
            return undef;
        }
        Time::HiRes::sleep(0.1);
    }
}

# _acquire_archive_lock($dsdir) -> $filehandle | undef (review 01, M1).
# Exclusive, non-blocking, single attempt -- no retry, no timeout. Busy or
# any failure to acquire both return undef so the caller can defer
# immediately rather than stall `next`. Released implicitly when the
# returned filehandle goes out of scope (held for the caller's critical
# section only).
sub _acquire_archive_lock {
    my ($dsdir) = @_;
    make_path($dsdir) unless -d $dsdir;
    my $lockfile = "$dsdir/archive.lock";
    my $fh;
    return undef unless open $fh, '>>', $lockfile;
    my $got = eval { flock($fh, LOCK_EX | LOCK_NB) };
    unless ($got) {
        close $fh;
        return undef;
    }
    return $fh;
}

sub _append_run_log {
    my ($dsdir, $line) = @_;
    return unless defined $dsdir;
    make_path($dsdir) unless -d $dsdir;
    open my $fh, '>>:raw', "$dsdir/run.md" or return;
    print $fh "$line\n";
    close $fh;
}

# Parse blueprint.md status table into DAG: { pkg => [deps] }.
# Mirrored from BpOrch::parse_dag (bp-orchestrator.pl line 302-342).
sub _table_cols {
    my ($ln) = @_;
    $ln =~ s/^\s*\|//; $ln =~ s/\|\s*$//;
    my @c = split /\|/, $ln, -1;
    s/^\s+//, s/\s+$// for @c;
    return @c;
}
sub parse_dag {
    my ($md) = @_;
    my %dag;
    my @lines = split /\n/, (defined $md ? $md : '');
    my ($in, $hdr) = (0, undef);
    for my $ln (@lines) {
        if (!$in) {
            if ($ln =~ /^\s*\|/ && $ln =~ /depends_on/) {
                $hdr = [ _table_cols($ln) ];
                $in  = 1;
            }
            next;
        }
        last unless $ln =~ /^\s*\|/;
        next if $ln =~ /^\s*\|[\s:|-]+\|?\s*$/;   # separator row
        my @c = _table_cols($ln);
        my %row; @row{@$hdr} = @c;
        my $pkg = $row{pkg};
        next unless defined $pkg && length $pkg;
        my $deps_raw = $row{depends_on} // '';
        my @deps;
        for my $d (split /[,\s]+/, $deps_raw) {
            # package 30 (spec §2.2): a token containing '/' is kept VERBATIM,
            # whether or not it is a well-formed cross-blueprint EXTREF -- the
            # malformed shape is resolved (to state 'malformed') by
            # external_dep_state, not filtered here. A token with no '/' keeps
            # the original local-package whitelist unchanged.
            if ($d =~ m{/}) {
                push @deps, $d;
            } elsif ($d =~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/) {
                push @deps, $d;
            }
        }
        $dag{$pkg} = \@deps;
    }
    return \%dag;
}

# parse_ext_ref($tok) -> ($bp, $pkg) for a well-formed EXTREF (spec §2.1:
# NAME "/" NAME); empty list for anything else, including a local token.
sub parse_ext_ref {
    my ($tok) = @_;
    return () unless defined $tok && !ref $tok;
    return () unless $tok =~ m{^([A-Za-z0-9][A-Za-z0-9_.-]*)/([A-Za-z0-9][A-Za-z0-9_.-]*)$};
    return ($1, $2);
}

# external_dep_state($data, $tok) -> $state (spec §2.2). Pure read: never
# dies, never writes. Resolution order is the live blueprints/<bp> first,
# then blueprints/_archive/<bp> (spec §2.2 / B7).
sub external_dep_state {
    my ($data, $tok) = @_;
    my ($bp, $pkg) = parse_ext_ref($tok);
    return 'malformed' unless defined $bp;
    for my $root ("$data/blueprints/$bp", "$data/blueprints/_archive/$bp") {
        next unless -f "$root/blueprint.md";
        return 'missing-package' unless -f "$root/packages/$pkg.md";
        my $st = ledger_fm($root, $pkg, 'status');
        return (defined $st && length $st) ? $st : 'pending';
    }
    return 'missing-blueprint';
}

# ledger_fm($bpdir, $pkg, $key): read status/write_set from ledger frontmatter.
# Mirrored from BpOrch::ledger_fm (bp-orchestrator.pl line 352-363).
sub ledger_fm {
    my ($bpdir, $pkg, $key) = @_;
    my $f = "$bpdir/packages/$pkg.md";
    my $txt = _read_file($f);
    return undef unless defined $txt;
    my ($fm) = $txt =~ /\A---\s*\n(.*?)\n---/s;
    return undef unless defined $fm;
    for my $ln (split /\n/, $fm) {
        if ($ln =~ /^\Q$key\E:\s*(.*?)\s*$/) { return $1; }
    }
    return undef;
}

# read_state: assemble $state from disk.
# deps from blueprint.md DAG (E-1 resolution); status/write_set from ledger frontmatter.
sub read_state {
    my ($data, $dsdir, $candidate_bps) = @_;
    my $bpbase = "$data/blueprints";

    # order.json
    my $order_data = _read_json_file("$dsdir/order.json", $dsdir);
    my $order = (ref $order_data eq 'HASH' && ref $order_data->{order} eq 'ARRAY')
              ? $order_data->{order} : undef;

    # parked (package 08-blueprint-parks, spec §2.5): every blueprint in the
    # order AND in the candidate set (B2a needs candidates not yet in the
    # order too) whose blueprint.md authors status: parked. A legacy park
    # file is gone after migration; _bp_parked is the only parkedness test.
    my %parked;
    {
        my %seen;
        for my $bp (@{ $order // [] }, @$candidate_bps) {
            next if $seen{$bp}++;
            $parked{$bp} = 1 if _bp_parked("$bpbase/$bp");
        }
    }

    # announced.json
    my $ann_data = _read_json_file("$dsdir/announced.json", $dsdir);
    my %announced;
    if (ref $ann_data eq 'HASH' && ref $ann_data->{announced} eq 'ARRAY') {
        %announced = map { $_ => 1 } @{ $ann_data->{announced} };
    }

    # per-blueprint: DAG (deps) + ledger (status, write_set)
    my %bp_meta;    # { bp => { pkg => { deps, write_set } } }
    my %bp_status;  # { bp => { pkg => status } }

    my $scope_bps = defined $order ? $order : $candidate_bps;
    for my $bp (@$scope_bps) {
        my $bpdir = "$bpbase/$bp";
        my $dag   = parse_dag(_read_file("$bpdir/blueprint.md"));
        my (%meta, %status);
        for my $pkg (keys %$dag) {
            $status{$pkg} = ledger_fm($bpdir, $pkg, 'status') // 'pending';
            $meta{$pkg}   = {
                deps      => $dag->{$pkg},
                write_set => (ledger_fm($bpdir, $pkg, 'write_set') // ''),
                priority  => ledger_fm($bpdir, $pkg, 'priority'),
            };
        }
        # package 30 (spec §2.2): every cross-blueprint token ('<bp>/<pkg>')
        # that appears anywhere in this blueprint's DAG becomes a key in the
        # status view too, mapped to its external_dep_state. A package id can
        # never contain '/', so this key can never collide with a package key
        # (spec's invariant) -- deps_met/has_progressable_work/ready_packages
        # need no changes at all: they already just look up $status->{$d}.
        for my $pkg (keys %$dag) {
            for my $d (@{ $dag->{$pkg} }) {
                next unless $d =~ m{/};
                next if exists $status{$d};
                $status{$d} = external_dep_state($data, $d);
            }
        }
        $bp_meta{$bp}   = \%meta;
        $bp_status{$bp} = \%status;
    }

    return {
        order      => $order,
        parked     => \%parked,
        announced  => \%announced,
        bp_meta    => \%bp_meta,
        bp_status  => \%bp_status,
        candidates => $candidate_bps,
    };
}

# _log_external_missing($dsdir, $bp, $meta, $status): for every non-terminal
# package of $bp whose DAG holds a cross token whose resolved state is
# missing-blueprint, missing-package or malformed, append exactly one
# EXTERNAL-MISSING line (spec §2.3). No dedupe across calls -- matches the
# existing ORDER-PRUNE/NOT-AUDITED convention.
sub _log_external_missing {
    my ($dsdir, $bp, $meta, $status) = @_;
    for my $pkg (sort keys %$meta) {
        next if _is_terminal($status->{$pkg} // 'pending');
        for my $d (@{ $meta->{$pkg}{deps} || [] }) {
            next unless $d =~ m{/};
            my $st = $status->{$d};
            next unless defined $st && $st =~ /^(?:missing-blueprint|missing-package|malformed)$/;
            _append_run_log($dsdir, "EXTERNAL-MISSING $bp/$pkg waits on $d ($st)");
        }
    }
}

# _external_waits_for($meta, $status) -> \@waits (spec §2.3): one entry per
# PENDING package with at least one unmet cross token, sorted by package;
# each entry's deps lists only the unmet cross tokens, in cell order.
sub _external_waits_for {
    my ($meta, $status) = @_;
    my @waits;
    for my $pkg (sort keys %$meta) {
        next unless ($status->{$pkg} // 'pending') eq 'pending';
        my @unmet;
        for my $d (@{ $meta->{$pkg}{deps} || [] }) {
            next unless $d =~ m{/};
            my $st = $status->{$d} // 'pending';
            next if $st eq 'done';
            push @unmet, { ref => $d, state => $st };
        }
        push @waits, { package => $pkg, deps => \@unmet } if @unmet;
    }
    return \@waits;
}

# mark_announced: add a blueprint to announced.json atomically.
sub mark_announced {
    my ($dsdir, $bp) = @_;
    make_path($dsdir) unless -d $dsdir;
    my $ann_data = _read_json_file("$dsdir/announced.json");
    my @list = (ref $ann_data eq 'HASH' && ref $ann_data->{announced} eq 'ARRAY')
             ? @{ $ann_data->{announced} } : ();
    unless (grep { $_ eq $bp } @list) { push @list, $bp; }
    _write_json_atomic("$dsdir/announced.json", { announced => \@list });
}

# ===========================================================================
# SINGLE-BLUEPRINT ARCHIVE AT blueprint-done (director-archives-finished,
# package 01, spec §2.3-2.6). Reuses bp-lifecycle.pl's own archive gate
# (BpState::blueprint_lifecycle) and its `reconcile --archive` action as a
# list-form subprocess -- never a second archive implementation. A failed or
# deferred attempt never blocks the run; the caller retries on a later `next`
# (the retry sweep in _cmd_next) or via the run-done `--all` backstop.
# ===========================================================================

# _archive_detail_clean($s): one line (every \r/\n run collapsed to a single
# space), at most 400 characters, never empty (spec §2.1).
sub _archive_detail_clean {
    my ($s) = @_;
    $s = defined $s ? $s : '';
    $s =~ s/[\r\n]+/ /g;
    $s = substr($s, 0, 400) if length($s) > 400;
    return length($s) ? $s : 'archive failed: unknown';
}

# _archive_gate($data, $bp) -> ($ok, $detail) — pure read (spec §2.3).
# Precedence: no ledgers -> not archivable; any non-done/dropped status ->
# not all delivered; lifecycle ne 'done' -> not archivable; else (1, undef).
sub _archive_gate {
    my ($data, $bp) = @_;
    require "$DIR/BpState.pm" unless defined &BpState::all_package_statuses;
    my $bpdir = "$data/blueprints/$bp";
    my $statuses = BpState::all_package_statuses($bpdir);
    unless (%$statuses) {
        return (0, 'not archivable: no package ledgers');
    }
    my @bad = grep { $statuses->{$_} ne 'done' && $statuses->{$_} ne 'dropped' } sort keys %$statuses;
    if (@bad) {
        return (0, 'not all delivered: ' . join(', ', map { "$_=$statuses->{$_}" } @bad));
    }
    my $lc = BpState::blueprint_lifecycle($bpdir, sub { kill(0, $_[0]) ? 1 : 0 });
    if ($lc ne 'done') {
        return (0, "not archivable: lifecycle is '$lc'");
    }
    return (1, undef);
}

# _archive_blockers($data, $dsdir, $bp, $now) -> \@parts (spec §2.4). Three
# read-only deferral checks; empty list = not deferred. $now is the
# director's own now seam for the dispatch-log staleness check ONLY -- the
# worker-marker staleness check below uses the REAL clock deliberately
# (mtime is real; see spec §2.4/2).
sub _archive_blockers {
    my ($data, $dsdir, $bp, $now) = @_;
    my @parts;

    # 1. in-flight set: NOT pruned (spec rationale — pruning would drop the
    # very entry this check exists to see).
    my ($entries) = load_inflight($data, $dsdir, $now);
    my @inflight_pkgs = sort map { $_->{package} }
                        grep { $_->{blueprint} eq $bp } @$entries;
    push @parts, 'in-flight ' . join(',', @inflight_pkgs) if @inflight_pkgs;

    # 2. live worker marker bound to one of this blueprint's ledgers.
    my @live_tuids;
    my $wdir = "$dsdir/workers";
    my $bdir = "$dsdir/bindings";
    if (-d $wdir) {
        my $stale_min = 180;
        if (defined $ENV{CCPRAXIS_VALIDATION_STALE_MIN}
            && $ENV{CCPRAXIS_VALIDATION_STALE_MIN} =~ /^[0-9]+\z/
            && $ENV{CCPRAXIS_VALIDATION_STALE_MIN} > 0) {
            $stale_min = $ENV{CCPRAXIS_VALIDATION_STALE_MIN} + 0;
        }
        if (opendir(my $dh, $wdir)) {
            for my $f (readdir $dh) {
                next unless $f =~ /^[A-Za-z0-9_-]{1,128}\z/;
                my $path = "$wdir/$f";
                next unless -f $path;
                my @st = stat($path);
                next unless @st;
                next unless (CORE::time() - $st[9]) < ($stale_min * 60);
                my $binding = _read_json_file("$bdir/$f.json");
                next unless ref $binding eq 'HASH' && (($binding->{blueprint} // '') eq $bp);
                push @live_tuids, $f;
            }
            closedir $dh;
        }
    }
    push @parts, 'live worker ' . join(',', sort @live_tuids) if @live_tuids;

    # 3. open dispatch-log entry attributed to this blueprint.
    my $dispatch_dir = "$data/.dispatch-log";
    my @open_ids;
    my $lib_ok = eval {
        require "$DIR/bp-dispatch-log.pl" unless defined &BpDispatchLog::is_live;
        1;
    };
    if (!$lib_ok) {
        push @parts, 'dispatch-log unreadable';
    } elsif (-d $dispatch_dir && opendir(my $dh, $dispatch_dir)) {
        for my $f (readdir $dh) {
            next unless $f =~ /^(.+)\.json\z/;
            my $id  = $1;
            my $rec = _read_json_file("$dispatch_dir/$f");
            next unless ref $rec eq 'HASH';
            next unless BpDispatchLog::is_live($rec, $now);
            my $attr = BpDispatchLog::attribution($rec);
            next unless (($attr->{blueprint} // '') eq $bp);
            push @open_ids, $id;
        }
        closedir $dh;
    }
    push @parts, 'open dispatch ' . join(',', sort @open_ids) if @open_ids;

    return \@parts;
}

# _run_archive($data, $dsdir, $bp, $opts) -> ($archived_bool_plain, $detail)
# (spec §2.5). List-form subprocess, never a shell string; STDOUT/STDERR
# captured through real temp files (never an in-memory scalar — Landmine #2).
# Review 01 M1: takes a non-blocking $dsdir/archive.lock around the whole
# attempt (busy -> deferred immediately, no retry) and, under that lock,
# re-checks immediately before running bp-lifecycle.pl that the source still
# exists and the destination does not -- closing the window a concurrent
# `next` could have used to already file this same archive. Lock is released
# on every return path via $lock_fh going out of scope.
sub _run_archive {
    my ($data, $dsdir, $bp, $opts) = @_;
    my $script = $opts->{lifecycle_script} // "$DIR/bp-lifecycle.pl";

    my $lock_fh = _acquire_archive_lock($dsdir);
    return (0, 'deferred: archive in progress') unless $lock_fh;

    my $bp_dir      = "$data/blueprints/$bp";
    my $archive_dir = "$data/blueprints/_archive/$bp";
    unless (-e $bp_dir) {
        return (1, "already archived to _archive/$bp") if -d $archive_dir;
        return (0, 'deferred: archive in progress');
    }
    # Decision 6: source and destination both present is a failure needing a
    # human, never a deferral -- it does not clear by itself. Never runs
    # bp-lifecycle.pl or touches _archive/<b> in this case.
    return (0, "archive failed: _archive/$bp already exists (reconcile not run)") if -e $archive_dir;

    require File::Temp;
    my ($otfh, $opath) = File::Temp::tempfile(); close $otfh;
    my ($etfh, $epath) = File::Temp::tempfile(); close $etfh;

    open(my $saved_out, '>&', \*STDOUT) or return (0, "archive failed: could not run bp-lifecycle.pl (cannot dup STDOUT: $!)");
    open(my $saved_err, '>&', \*STDERR) or do {
        open(STDOUT, '>&', $saved_out); close $saved_out;
        return (0, "archive failed: could not run bp-lifecycle.pl (cannot dup STDERR: $!)");
    };
    my $rc = -1;
    my $fail_detail;
    if (open(STDOUT, '>', $opath)) {
        if (open(STDERR, '>', $epath)) {
            $rc = system($^X, $script, 'reconcile', '--blueprint', $bp,
                         '--data-dir', $data, '--archive', '--json');
            $fail_detail = "could not run bp-lifecycle.pl ($!)" if $rc == -1;
        } else {
            $fail_detail = "cannot capture output: $!";
        }
    } else {
        $fail_detail = "cannot capture output: $!";
    }
    open(STDOUT, '>&', $saved_out); close $saved_out;
    open(STDERR, '>&', $saved_err); close $saved_err;

    my $out = _read_file($opath) // '';
    my $err = _read_file($epath) // '';
    unlink $opath, $epath;

    if ($rc == -1) {
        return (0, "archive failed: $fail_detail");
    }
    my $exit = $rc >> 8;

    my $parsed = eval { JSON::PP->new->decode($out) };
    my $rec;
    if (ref $parsed eq 'ARRAY') {
        ($rec) = grep { ref $_ eq 'HASH' && (($_->{blueprint} // '') eq $bp) } @$parsed;
    }

    if ($exit != 0) {
        my $detail;
        if ($rec && ref $rec->{errors} eq 'ARRAY' && @{ $rec->{errors} }) {
            $detail = $rec->{errors}[0];
        }
        unless (defined $detail) {
            my @lines = grep { length } split /\r?\n/, $err;
            $detail = $lines[0] if @lines;
        }
        $detail //= 'no output';
        return (0, "archive failed: reconcile exit $exit: $detail");
    }

    # exit 0: disk state decides `archived`, never the JSON (spec §2.5).
    if (-d "$data/blueprints/_archive/$bp" && !-e "$data/blueprints/$bp") {
        my $detail;
        if ($rec && ref $rec->{actions} eq 'ARRAY') {
            my ($act) = grep { ref $_ eq 'HASH' && (($_->{kind} // '') eq 'archive') && $_->{applied} }
                        @{ $rec->{actions} };
            $detail = $act->{detail} if $act;
        }
        $detail //= "archived to _archive/$bp";
        return (1, $detail);
    }

    # exit 0 but not archived: a reported `skipped` action names why and is
    # NOT a failure (a live orchestrator raced the gate); anything else is.
    if ($rec && ref $rec->{actions} eq 'ARRAY') {
        my ($skip) = grep { ref $_ eq 'HASH' && (($_->{kind} // '') eq 'skipped') } @{ $rec->{actions} };
        if ($skip) {
            return (0, "not archivable: $skip->{detail}");
        }
    }
    my $lc = $rec ? ($rec->{lifecycle} // '?') : '?';
    return (0, "archive failed: reconcile exited 0 but did not archive (lifecycle '$lc')");
}

# _attempt_archive($data, $dsdir, $bp, $now, $opts) -> ($archived_bool_json,
# $detail, $outcome) (spec §2.3). Gate -> blockers -> subprocess, first stop
# wins. Never dies: the whole body is guarded so any exception becomes
# (false, "archive failed: <msg>", 'failed'). Drops $bp from order.json on
# 'archived' only.
sub _attempt_archive {
    my ($data, $dsdir, $bp, $now, $opts) = @_;
    my ($archived, $detail, $outcome) = (0, undef, undef);
    my $ok = eval {
        my $inner = sub {
            my ($gate_ok, $gate_detail) = _archive_gate($data, $bp);
            return (0, $gate_detail, 'not-archivable') unless $gate_ok;

            my $blockers = _archive_blockers($data, $dsdir, $bp, $now);
            return (0, 'deferred: ' . join('; ', @$blockers), 'deferred') if @$blockers;

            my ($ab, $rd) = _run_archive($data, $dsdir, $bp, $opts);
            return (1, $rd, 'archived') if $ab;
            return (0, $rd, 'not-archivable') if $rd =~ /^not archivable:/;
            return (0, $rd, 'deferred') if $rd =~ /^deferred:/;
            return (0, $rd, 'failed');
        };
        ($archived, $detail, $outcome) = $inner->();
        1;
    };
    unless ($ok) {
        (my $msg = $@) =~ s/\s+\z//;
        ($archived, $detail, $outcome) = (0, "archive failed: $msg", 'failed');
    }
    if ($outcome eq 'archived') {
        _drop_from_order($dsdir, $bp);
    }
    my $archived_json = $archived ? JSON::PP::true : JSON::PP::false;
    return ($archived_json, _archive_detail_clean($detail), $outcome);
}

# _drop_from_order($dsdir, @names): re-reads order.json from disk and, if it
# is a HASH whose `order` is an ARRAY containing any of @names, rewrites it
# atomically with those names removed, preserving every other key. Never
# writes when nothing is removed. A write failure logs one WARN line and is
# otherwise ignored (spec §2.3).
sub _drop_from_order {
    my ($dsdir, @names) = @_;
    return unless @names;
    my $path = "$dsdir/order.json";
    my $order_data = _read_json_file($path, $dsdir);
    return unless ref $order_data eq 'HASH' && ref $order_data->{order} eq 'ARRAY';
    my %drop = map { $_ => 1 } @names;
    my @removed = grep { $drop{$_} } @{ $order_data->{order} };
    return unless @removed;
    my @kept = grep { !$drop{$_} } @{ $order_data->{order} };
    my %new_data = %$order_data;
    $new_data{order} = \@kept;
    eval { _write_json_atomic($path, \%new_data); };
    if ($@) {
        (my $msg = $@) =~ s/\s+\z//;
        _append_run_log($dsdir, "WARN order.json update failed: $msg");
        return;
    }
    _append_run_log($dsdir, "ORDER-DROP-ARCHIVED $_") for @removed;
}

# ===========================================================================
# KEEP-AWAKE ACTUATION (side effect; seam-injectable; never affects action/exit)
# ===========================================================================

# pause_keepawake_phase($reason, $until_epoch, $now) -> 'pause-pending'|'settled'
#
# HOLDING THE WAKE-LOCK ACROSS A PAUSE IS A PROMISE ABOUT RESUMING. A usage pause
# auto-resumes, and the machine has to still be awake when the window reopens --
# which is why 'pause-pending' is one of the two phases should_be_on() holds for.
#
# That reasoning is sound for the FIVE-HOUR usage window, which cannot reopen
# more than five hours out. It is not sound for the SEVEN-DAY window. Measured on
# this host 2026-09-18, the governor returned
#   {"action":"pause","reason":"usage","until_epoch":1790013600}
# with seven_day at 86%, resetting 2026-09-21T18:00Z -- 88 hours away.
# 'pause-pending' would have held a laptop awake from Friday morning until Monday
# evening waiting for it. Nobody expects that, and nobody would ask for it.
#
# Past the horizon the honest phase is 'settled': release the lock, let the
# machine sleep, and let whoever comes back wake it. The pause ACTION is
# byte-identical either way -- this decides only whether the machine is held
# awake, never what any caller sees.
#
# An UNDEFINED until_epoch keeps the old behaviour and HOLDS. That is the
# pre-existing semantics, it is the case no measurement covers, and a short pause
# wrongly released is a broken auto-resume -- so the change stays scoped to the
# case actually observed.
#
# Strictly greater-than, so a pause landing exactly ON the horizon still holds.
sub pause_keepawake_phase {
    my ($reason, $until, $now) = @_;
    return 'settled' unless defined $reason && $reason eq 'usage';
    return 'pause-pending' unless defined $until;
    return (($until - $now) > $KEEPAWAKE_PAUSE_HORIZON_SECONDS) ? 'settled' : 'pause-pending';
}

# never-halt package 10: a usage pause that reopens more than 12h out hands the
# session off instead of waiting it out (Decision 41, narrowed by Decision 42 —
# butler-hold.pl's 50-minute clamp is explicitly NOT the mechanism here).
our $LONG_PAUSE_HANDOFF_SECONDS = 12 * 3600;   # 43200, package-global, test-readable

# pause_is_long($reason, $until_epoch, $now) -> 1 | 0   (pure; no I/O)
#   1 iff  defined $reason && $reason eq 'usage'
#      &&  defined $until_epoch && $until_epoch =~ /\A-?\d+(?:\.\d+)?\z/
#      &&  ($until_epoch - $now) > $LONG_PAUSE_HANDOFF_SECONDS
#   else 0
sub pause_is_long {
    my ($reason, $until, $now) = @_;
    return 0 unless defined $reason && $reason eq 'usage';
    return 0 unless defined $until && $until =~ /\A-?\d+(?:\.\d+)?\z/;
    # red-team L5: a pathologically huge until_epoch blows up gmtime()/
    # strftime() downstream ("Usage: POSIX::strftime") -- fail safe to "not
    # long" here, before any caller reaches that strftime call.
    return 0 unless gmtime(int $until);
    return (($until - $now) > $LONG_PAUSE_HANDOFF_SECONDS) ? 1 : 0;
}

sub keepawake_apply {
    my ($phase, $dsdir, $opts) = @_;
    # The seam shape (spawn / kill_pid / powershell_available in %$opts) is
    # preserved verbatim so injected fakes keep working; only the body moved.
    BpKeepAwake::apply($phase, $dsdir, {
        %{ $opts // {} },
        log => sub { _append_run_log($dsdir, $_[0]) },
    });
}

# ===========================================================================
# AC-LOSS WATCH WIRING (package 11, tooling-backlog, spec sec 2.5)
# ===========================================================================

# Set by ac_check() when the phase was `reconnected`; consumed (and
# cleared) by _encode_action(), which logs RESUMED right before the normal
# next-action JSON it is about to print -- the one point every return path
# of _cmd_next already funnels through, so this needs no change to any of
# the many individual print sites below.
my $AC_RESUME_DATA;

sub _ac_inflight_list {
    my ($dsdir) = @_;
    my $path = "$dsdir/inflight.json";
    return [] unless -f $path;
    my $data = eval {
        open(my $fh, '<:raw', $path) or return undef;
        local $/;
        my $raw = <$fh>;
        close $fh;
        JSON::PP->new->utf8->decode($raw);
    };
    return [] unless ref $data eq 'HASH' && ref $data->{packages} eq 'ARRAY';
    return [ map { { blueprint => $_->{blueprint}, package => $_->{package} } }
             grep { ref $_ eq 'HASH' } @{ $data->{packages} } ];
}

# ac_check($data, $dsdir, $opts) -> \%action | undef. Any failure here (a
# die, a lock timeout, enabled() false) is swallowed and logged WATCH-ERROR
# on a best-effort basis; `next` then proceeds exactly as it does today
# (spec sec 2.5's "whole call wrapped in eval").
sub ac_check {
    my ($data, $dsdir, $opts) = @_;
    $opts = {} unless ref $opts eq 'HASH';
    my $result;
    my $ok = eval {
        require "$DIR/BpAcWatch.pm" unless defined &BpAcWatch::enabled;
        return 1 unless BpAcWatch::enabled();

        # M2 (fix-batch, redteam-1): a stored "reconnected" phase is only
        # ever set from an earlier observation -- it can be minutes stale by
        # the time this `next` call gets around to it. Force a FRESH probe
        # in that one case (never on the far more common ac/grace/etc. path,
        # to avoid adding a real probe spawn to every ordinary `next` call)
        # so a flicker or a fail-open resume that has since reverted to dc
        # is caught before the director re-asserts the wake-lock on battery.
        my $prior_status = eval { BpAcWatch::status($data) };
        my $prior_phase = (ref $prior_status eq 'HASH') ? $prior_status->{phase} : undef;
        my $force_probe = (defined $prior_phase && $prior_phase eq 'reconnected') ? 1 : 0;

        my %obs_opts = (src => 'director');
        $obs_opts{force} = 1 if $force_probe;
        my $obs = BpAcWatch::observe($data, %obs_opts);
        my $phase = (ref $obs eq 'HASH') ? $obs->{phase} : undef;
        return 1 unless defined $phase;

        if ($phase eq 'expired' || $phase eq 'standing-down' || $phase eq 'monitoring') {
            my $inflight = _ac_inflight_list($dsdir);
            $result = BpAcWatch::standdown_director_side($data,
                inflight => $inflight,
                keepawake_settle => sub { keepawake_apply('settled', $dsdir, $opts) },
            );
        }
        elsif ($phase eq 'reconnected') {
            if ($force_probe && (($obs->{source} // '') eq 'dc')) {
                # The fresh probe this call just took contradicts the stored
                # reconnect: do not resume onto battery. Revert to
                # monitoring and report ac-stand-down again instead.
                BpAcWatch::revert_reconnect_to_monitoring($data);
                my $inflight = _ac_inflight_list($dsdir);
                $result = BpAcWatch::standdown_director_side($data,
                    inflight => $inflight,
                    keepawake_settle => sub { keepawake_apply('settled', $dsdir, $opts) },
                );
            }
            else {
                BpAcWatch::resume_director_side($data);
                $AC_RESUME_DATA = $data;
            }
        }
        1;
    };
    unless ($ok) {
        my $e = defined $@ ? $@ : 'unknown error';
        $e =~ s/\n.*//s;
        eval {
            require "$DIR/BpAcWatch.pm" unless defined &BpAcWatch::log_event;
            BpAcWatch::log_event($data, 'director', 'WATCH-ERROR', {}, $e);
        };
    }
    return $result;
}

# ===========================================================================
# TOKEN RECOVERY (operator decision 2026-08-12)
# ===========================================================================
#
# When the governor reports the access token is under the floor, solo does not
# park and wait for a human. It attempts the refresh ITSELF, using the refresh
# token, and only stops if that genuinely fails.
#
# The refresh is not re-derived here. `bp-token-keeper.pl` already implements
# it -- the OAuth token endpoint, the request shape, atomic write-back under
# flock with a re-read stand-down, temp+rename, JSON validation, mode
# preservation and 429 backoff. Re-implementing any of that would be a second,
# less-tested writer for the credential store, which is the last file in the
# system that should have two.
#
# Returns ($recovered, $detail). $detail is always a short human string; it goes
# to the run log and, on failure, out in the action, so a run that stops for
# this reason explains itself without anyone reading code.
#
# The `refresh` opt is the test seam. Production default calls the keeper.
sub _token_recover {
    my ($opts, $now) = @_;

    if (my $fn = $opts->{refresh}) {
        my $r = eval { $fn->($now) };
        return (0, "refresh seam died: $@") if $@;
        return (0, 'refresh seam returned nothing') unless ref $r eq 'HASH';
        my $act = $r->{action} // '';
        return (1, $act) if $act eq 'refreshed' || $act eq 'ok';
        return (0, "keeper said '$act'" . (defined $r->{detail} && !ref $r->{detail}
                                            ? ": $r->{detail}" : ''));
    }

    my $creds = $opts->{creds_path}
             // ($ENV{BP_CREDS_PATH} || (($ENV{HOME} // $ENV{USERPROFILE} // '.')
                                          . '/.claude/.credentials.json'));
    return (0, "no credentials file at $creds") unless -f $creds;

    my $keeper = "$DIR/bp-token-keeper.pl";
    return (0, "token-keeper missing at $keeper") unless -f $keeper;

    my $r = eval {
        require $keeper;
        BpKeeper::keeper_tick({ creds_path => $creds, now_ms => $now * 1000 });
    };
    return (0, "keeper_tick died: $@") if $@;
    return (0, 'keeper_tick returned nothing') unless ref $r eq 'HASH';

    my $act = $r->{action} // '';
    # 'ok' means the keeper looked and the token did not need refreshing -- which
    # can happen if it was refreshed between the governor's verdict and now.
    # Treat it as recovered: re-checking would only race again.
    return (1, $act) if $act eq 'refreshed' || $act eq 'ok';

    my $d = $r->{detail};
    return (0, "keeper said '$act'" . (defined $d && !ref $d ? ": $d" : ''));
}

# ===========================================================================
# VERDICT RETRY / DEGRADE LOOP (wraps the verdict seam; §2.5 / Decision #14)
# ===========================================================================

sub _fetch_verdict_with_retry {
    my ($verdict_fn, $dsdir) = @_;
    my $degraded = 0;
    for my $attempt (1 .. $VERDICT_RETRY_MAX) {
        my $v = eval { $verdict_fn->() } // { action => 'unavailable' };
        my $act = (ref $v eq 'HASH' ? $v->{action} : undef) // 'unavailable';
        if ($act ne 'unavailable') {
            return ($v, 0);   # non-unavailable → short-circuit, not degraded
        }
        # On last attempt, degrade-and-proceed
        if ($attempt == $VERDICT_RETRY_MAX) {
            _append_run_log($dsdir, 'WARN governance degraded — proceeding without usage gate');
            return ({ action => 'ok' }, 1);
        }
    }
    # Should not be reached
    return ({ action => 'ok' }, 1);
}

# ===========================================================================
# SUBCOMMAND: next
# ===========================================================================

sub _cmd_next {
    my ($argv, $opts) = @_;
    my $data   = $opts->{data_dir} or die "bp-drive-next: data_dir required\n";
    my $now    = $opts->{now}->();
    my $dsdir  = "$data/.drive-solo";
    my $verdict_fn = $opts->{verdict};

    # package 11 (tooling-backlog), spec sec 2.5: the AC-loss watch, checked
    # once, before any keepawake_apply call and before need-order or
    # usage-gate work.
    my $ac_result = ac_check($data, $dsdir, $opts);
    if (defined $ac_result) {
        print _encode_action($ac_result), "\n";
        return 0;
    }

    # Parse --scope <spec>
    my $spec = '';
    {
        my @a = @$argv;
        while (@a) {
            my $o = shift @a;
            if ($o eq '--scope') { $spec = shift(@a) // ''; }
        }
    }

    # Discover blueprint dirs for candidate resolution
    my @all_bps;
    if (-d "$data/blueprints") {
        opendir my $dh, "$data/blueprints" or die "cannot opendir $data/blueprints: $!";
        @all_bps = sort grep { /\S/ && -d "$data/blueprints/$_" && -f "$data/blueprints/$_/blueprint.md" }
                        grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
    }

    # A blueprint that has not been AUDITED is not drivable, and this is the one
    # place that enforces it. This file's own USAGE block documents `--scope all`
    # as "all audited blueprints"; until 2026-09-18 the code simply listed every
    # directory holding a blueprint.md and never read a lifecycle status at all,
    # so a blueprint still at `status: drafting` was handed out as work.
    #
    # Measured on this host: the director returned run-package for
    # butler-gate-ergonomics/01-live-watcher-probe while that blueprint was
    # drafting. The expensive half is second-order -- `next` is called from the
    # Stop hook on EVERY turn end, so keepawake_apply('active') kept re-spawning
    # the wake-lock, and the machine was held awake for hours on a run whose
    # runstate said `finished`. Killing the helper only bought one turn.
    #
    # NOT folded into @all_bps. That list answers "does this exist on disk", which
    # is what the ORDER-PRUNE below keys on; pruning a drafting blueprint there
    # would log it as "absent from disk -- archived, or not yet fully created",
    # asserting something false about a blueprint that is present and healthy.
    my %undrivable = map { $_ => 1 }
                     grep { !blueprint_drivable(blueprint_lifecycle("$data/blueprints/$_")) }
                     @all_bps;

    my @candidates = grep { !$undrivable{$_} } resolve_scope($spec, \@all_bps);

    # Read all state from disk
    make_path($dsdir) unless -d $dsdir;

    # In-flight set (package 11, spec §2.1/2.4-2.6, amended by the fix-batch;
    # batch C: concurrent hand-out is unconditional): do NOT take the lock or
    # load the set yet. Fix-batch red-team M2: the lock must never be held
    # across network I/O (the usage/governor verdict fetch, token recovery,
    # the `done` branch's `system()`), so it is acquired lazily, just before
    # the load/prune/write/hand-out sequence that actually needs it -- see the
    # "ok or degraded" branch below, which is reached only AFTER that bp's
    # verdict has already been fetched. $inflight_entries is populated there
    # (and reused for the in-flight action's `inflight` key), never here.
    my $inflight_entries;

    my $state = read_state($data, $dsdir, \@candidates);

    my $order     = $state->{order};
    my %parked    = %{ $state->{parked} };
    my %announced = %{ $state->{announced} };
    my %bp_meta   = %{ $state->{bp_meta} };
    my %bp_status = %{ $state->{bp_status} };

    # director-archives-finished / package 01, spec §2.6#3: whether order.json
    # held an ARRAY that was EMPTY on disk, captured BEFORE the ORDER-PRUNE
    # step below (which cannot change an already-empty array). Distinct from
    # "no order.json at all" (undef) and from "pruned to empty in memory"
    # (order-json-prune-stale-blueprint.t AC4/C, unaffected by this flag).
    my $order_was_empty_array = (defined $order && ref $order eq 'ARRAY' && !@$order) ? 1 : 0;

    # package 30 (spec §2.3): report every unresolvable cross token in scope,
    # for every `next` call, regardless of which action this call ends up
    # returning.
    for my $bp (keys %bp_meta) {
        _log_external_missing($dsdir, $bp, $bp_meta{$bp}, $bp_status{$bp});
    }

    # e04 §2.4/AC4: prune, IN MEMORY, any order.json entry whose blueprint no
    # longer exists on disk -- before B2a's coverage check and the B3 walk see
    # it. B2a's own coverage check requires FULL coverage (a superset of "any
    # ordered blueprint absent"), but a dead name that sits ALONGSIDE a live,
    # correctly-covered one slips past B2a and reaches the B3 walk unfiltered,
    # where parse_dag(undef) => {} makes blueprint_settled trivially true --
    # a false terminal report ("blueprint-done"/"done") for a blueprint never
    # touched this run. order.json on disk is NEVER rewritten here (only
    # record-order writes it) -- recomputed and re-logged on every `next` call
    # for as long as the stale name persists, matching this file's existing
    # convention for repeated, non-deduped WARN logging.
    if (defined $order && @$order) {
        my %exists = map { $_ => 1 } @all_bps;
        my @pruned = grep { $exists{$_} } @$order;
        if (@pruned != @$order) {
            my @dropped = grep { !$exists{$_} } @$order;
            # fixbatch step7 / red-team MEDIUM: "no longer on disk" asserts the
            # archived/deleted case this criterion was written for, but the same
            # branch also fires during bp-blueprint.pl init's genuine mkdir-then-
            # rename TOCTOU window (a blueprint dir exists before blueprint.md is
            # renamed into place) -- mislabelling a blueprint mid-creation as gone.
            # Effect stays safe either way (in-memory only, recomputed next call),
            # but the wording must not assert something that may be false.
            _append_run_log($dsdir, 'ORDER-PRUNE (absent from disk -- archived, or not yet fully created): ' . join(',', @dropped));
            $order = \@pruned;
        }
    }

    # B1a: NOTHING IN SCOPE — settled, not a question.
    #
    # An empty candidate set has no order to judge, but B2 below emitted
    # need-order with candidates:[] anyway. That prompt is UNANSWERABLE, and it
    # is a closed loop rather than a stall: record-order refuses an empty list,
    # so the session cannot answer it; `next` returns it again on every call;
    # stop-gate.sh treats any non-done/pause action as actionable work and
    # blocks the stop for it; and keepawake_apply('active') holds the machine
    # awake over a run containing no work at all.
    #
    # Observed 2026-08-25: the last blueprint was archived, blueprints/ held only
    # _archive/, and the driver could not end its turn — the gate demanded it
    # "do the next thing NOW" over zero candidates.
    #
    # 'done' asserts "every in-scope blueprint is done-or-parked". That is
    # vacuously true of an empty scope, and it settles keep-awake, which is what
    # an empty scope actually needs. This runs BEFORE B2 so the degenerate case
    # never reaches the ordering logic at all.
    # EMPTY IS NOT THE SAME AS MALFORMED, and conflating them is a
    # false-settled bug rather than a cosmetic one.
    #
    # Candidate discovery requires blueprint.md, so a directory under
    # blueprints/ that HAS packages but no blueprint.md is silently skipped and
    # lands here looking identical to "nothing is there". Reporting `done` over
    # it is actively dangerous: the watchdog logic branches on the action string and
    # treats `done` as absolute ("The director reports no remaining work. Do not
    # re-arm."), so a package ledger sitting at status: running would be
    # declared settled and the dead-man's switch disarmed over a wedged run.
    # 95-watchdog.t's fixture is exactly this shape and caught it.
    #
    # A malformed tree is a statement about the TREE, not about the work, so it
    # takes the same route the missing-blueprints/ case already takes: a hard
    # error naming what is wrong. That also keeps the watchdog honest by
    # construction -- director_action() maps an empty stdout to 'unknown', which
    # is not 'done', so it proceeds to its PROGRESS/STALLED analysis instead of
    # standing down.
    my @malformed;
    if (-d "$data/blueprints" && opendir(my $mdh, "$data/blueprints")) {
        @malformed = sort grep { $_ ne '.' && $_ ne '..' && $_ ne '_archive'
                                 && -d "$data/blueprints/$_"
                                 && !-f "$data/blueprints/$_/blueprint.md" }
                          readdir $mdh;
        closedir $mdh;
    }
    if (!@candidates && @malformed) {
        _append_run_log($dsdir, 'MALFORMED (directory under blueprints/ with no blueprint.md): '
                              . join(',', @malformed));
        print STDERR "bp-drive-next: blueprints/ holds directories with no blueprint.md:\n";
        print STDERR "  - $_\n" for @malformed;
        print STDERR "Each is skipped by candidate discovery, so the scope resolves empty -- but 'empty' and 'malformed' are not the same thing, and reporting the run settled over a half-created blueprint would disarm the watchdog on top of a package that may still be running. Finish creating it (blueprint.md), or move it aside, then retry.\n";
        return 2;
    }

    if (!@candidates) {
        _append_run_log($dsdir, 'DONE (nothing in scope: no blueprint matches the scope spec)');
        print _encode_action({ action => 'done', denials => _denials_count($data) }), "\n";
        keepawake_apply('settled', $dsdir, $opts);
        return 0;
    }

    # B2: no order recorded → need-order.
    #
    # director-archives-finished / package 01, spec §2.6#3: an order.json that
    # held an ARRAY EMPTY ON DISK (captured above, before ORDER-PRUNE) is not
    # "no order recorded" when every in-scope candidate is parked — every
    # blueprint the archive removed from the order is exactly the case this
    # exempts. Falling through here lets B2a (which already excludes parked
    # names from `missing`) and the B3 walk (which iterates an empty @$order
    # and finds nothing to do) settle it as `done`, never as a fresh
    # need-order prompt for work that is either archived or parked.
    unless (defined $order && @$order) {
        unless ($order_was_empty_array && !(grep { !$parked{$_} } @candidates)) {
            my $action = { action => 'need-order', candidates => \@candidates };
            print _encode_action($action), "\n";
            keepawake_apply('active', $dsdir, $opts);
            return 0;
        }
    }

    # B2a: an order EXISTS but does not cover every in-scope candidate.
    #
    # The walk below iterates `@$order`, so a candidate absent from it is never
    # looked at -- and the walk then falls through to 'done', which asserts
    # "every in-scope blueprint is done-or-parked". That assertion is false, and
    # it is believed by the two mechanisms named at the in-flight branch below:
    # stop-gate.sh allows the turn to end, and the watchdog logic short-circuits
    # to SETTLED. So the run reports finished having never considered the work.
    #
    # This is the same false-settled class as the in-flight bug documented there,
    # reached from the other direction, and it is NOT hypothetical: on 2026-08-12
    # `next --scope butler-and-dashboard-overhaul` returned {"action":"done"} on a
    # 22-package blueprint with every package still `pending`, because order.json
    # held a single now-archived name from the previous run.
    #
    # The header's "once order.json exists it is the authoritative scope+order and
    # --scope is ignored" still holds for ORDERING. It cannot be allowed to mean
    # "silently drop work the caller asked for": a stale order is a reason to ask
    # the session to re-judge, never a reason to claim completion. Excluding a
    # blueprint is what `park` is for -- and _cmd_record_order enforces exactly
    # that, so this cannot livelock on a session that re-records the same order.
    {
        my %in_order = map { $_ => 1 } @$order;
        my @missing  = grep { !$in_order{$_} && !$parked{$_} } @candidates;
        if (@missing) {
            _append_run_log($dsdir, 'NEED-ORDER (scope extends recorded order): '
                                  . join(',', @missing));
            print _encode_action({
                action     => 'need-order',
                candidates => \@candidates,
                missing    => \@missing,
                reason     => 'scope-extends-order',
            }), "\n";
            keepawake_apply('active', $dsdir, $opts);
            return 0;
        }
    }

    # director-archives-finished / package 01, spec §2.6#2: the archive retry
    # sweep. Every `next` (not only the call that first emits blueprint-done)
    # retries the single-blueprint archive for any blueprint already
    # announced, settled, unparked and drivable — so a deferral (in-flight /
    # live worker / open dispatch) or a failure clears on a later call
    # without a fresh blueprint-done. Silent when the gate itself still
    # fails (the steady state for every fixture with no audited status);
    # logged only for archived/deferred/failed, matching the emission-time
    # ARCHIVE line's own vocabulary. This sweep changes which action THIS
    # call returns only through an archived name's removal from `$order`.
    for my $b (@$order) {
        next if $undrivable{$b};
        next if $parked{$b};
        next unless $announced{$b};
        my $b_meta   = $bp_meta{$b}   // {};
        my $b_status = $bp_status{$b} // {};
        next unless blueprint_settled($b_meta, $b_status, 0);

        # S1 (review 01): no unguarded pre-check here -- _attempt_archive
        # already runs _archive_gate inside its own eval (never dies) and
        # the log filter below already suppresses its 'not-archivable'
        # outcome, so calling it directly avoids a duplicate ledger read
        # that could itself die outside any eval.
        my ($archived_bool, $archive_detail, $outcome) = _attempt_archive($data, $dsdir, $b, $now, $opts);
        if ($outcome eq 'archived' || $outcome eq 'deferred' || $outcome eq 'failed') {
            _append_run_log($dsdir, "ARCHIVE $b $outcome -- $archive_detail");
        }
        if ($outcome eq 'archived') {
            $order = [ grep { $_ ne $b } @$order ];
        }
    }

    # Blueprints that are NOT settled but have nothing dispatchable right now.
    # Collected rather than swallowed: emitting 'done' for these is the bug
    # documented at the in-flight branch below.
    my @in_flight;

    # Filtering @candidates above is NOT sufficient on its own: this walk iterates
    # @$order, not @candidates, so a blueprint already recorded in order.json is
    # visited whatever the scope resolved to. That is exactly the observed case --
    # order.json held ["almanac-records","butler-gate-ergonomics"] from when the
    # second was expected to be audited shortly. Both filters are load-bearing.
    if (my @nd = grep { $undrivable{$_} } @$order) {
        _append_run_log($dsdir,
            'NOT-AUDITED (skipped; blueprint.md status is not `audited`): ' . join(',', @nd));
    }

    # B3: walk recorded order
    for my $bp (@$order) {
        # Not audited: settled for drive purposes, and skipped exactly like a park
        # -- never driven, and never ANNOUNCED, because blueprint-done asserts the
        # blueprint FINISHED, which a drafting one emphatically has not.
        next if $undrivable{$bp};

        my $is_parked   = $parked{$bp} ? 1 : 0;
        my $meta        = $bp_meta{$bp}   // {};
        my $status      = $bp_status{$bp} // {};
        my $settled     = blueprint_settled($meta, $status, $is_parked);

        if ($settled) {
            # B4: settled but not yet announced (and not a park — parks aren't announced)
            if (!$is_parked && !$announced{$bp}) {
                # compute pending: later blueprints after $bp that are not done/parked
                my $found_bp = 0;
                my %done_or_parked;
                for my $b (@$order) {
                    if ($b eq $bp) { $found_bp = 1; next; }
                    if ($found_bp) {
                        my $b_parked  = $parked{$b} ? 1 : 0;
                        my $b_meta    = $bp_meta{$b}   // {};
                        my $b_status  = $bp_status{$b} // {};
                        my $b_settled = blueprint_settled($b_meta, $b_status, $b_parked);
                        # %done_or_parked is really "not pending work for this
                        # run", and a non-audited blueprint is not pending work --
                        # listing it would tell the session to re-evaluate a
                        # blueprint it cannot legally drive.
                        $done_or_parked{$b} = 1 if $b_settled || $b_parked || $undrivable{$b};
                    }
                }
                # collect blueprints strictly after $bp in the recorded order
                my @after;
                my $past = 0;
                for my $b (@$order) {
                    if ($b eq $bp) { $past = 1; next; }
                    push @after, $b if $past;
                }
                my @pending_list = grep { !$done_or_parked{$_} } @after;

                # Write to announced.json before returning (fire-once idempotence, B4)
                mark_announced($dsdir, $bp);

                # director-archives-finished / package 01, spec §2.6#1: the
                # director's own single-blueprint archive attempt, reusing
                # bp-lifecycle.pl's reconcile --archive. Never blocks the run
                # -- archived/archive_detail report the outcome either way,
                # and blueprint-done still fires exactly once via
                # announced.json above regardless of it.
                my ($archived_bool, $archive_detail, $archive_outcome) =
                    _attempt_archive($data, $dsdir, $bp, $now, $opts);

                _append_run_log($dsdir, "BLUEPRINT-DONE $bp pending=" . join(',', @pending_list));
                _append_run_log($dsdir, "ARCHIVE $bp $archive_outcome -- $archive_detail");

                my $action = { action => 'blueprint-done', blueprint => $bp, pending => \@pending_list,
                               archived => $archived_bool, archive_detail => $archive_detail };
                print _encode_action($action), "\n";
                my $phase = @pending_list ? 'active' : 'settled';
                keepawake_apply($phase, $dsdir, $opts);
                return 0;
            }
            # Already announced or is parked: skip to next bp
            next;
        }

        # Blueprint not settled: fetch verdict + compute action
        my ($verdict, $degraded) = _fetch_verdict_with_retry($verdict_fn, $dsdir);
        my $mapped = verdict_to_action($verdict, $now);

        # Token floor: try to recover it ourselves before deciding anything.
        if ($mapped->{token_floor}) {
            my ($recovered, $detail) = _token_recover($opts, $now);
            if (!$recovered) {
                # Terminal, and deliberately NOT a pause. A pause implies
                # "resume later"; there is nothing to resume to until a human
                # re-authenticates, and waiting would hold the wake-lock while
                # achieving nothing. Release it and say why, once.
                _append_run_log($dsdir,
                    "ERROR token refresh failed — stopping. $detail");
                my $action = { action => 'stop', reason => 'token-refresh-failed',
                               detail => $detail };
                print _encode_action($action), "\n";
                keepawake_apply('settled', $dsdir, $opts);
                return 0;
            }
            _append_run_log($dsdir, "token refreshed — continuing ($detail)");
        }

        if ($mapped->{action} && $mapped->{action} eq 'pause') {
            my $until = $mapped->{until_epoch};
            my $reason = $mapped->{reason};

            if (pause_is_long($reason, $until, $now)) {
                my $iso = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(int($until)));
                _append_run_log($dsdir, sprintf(
                    'PAUSE-LONG (%.1fh away, threshold %.1fh) -- the session hands off and ends; '
                  . 're-invoke drive-solo after %s',
                    ($until - $now) / 3600, $LONG_PAUSE_HANDOFF_SECONDS / 3600, $iso));
                my $action = { action => 'pause-long', reason => $reason,
                               until_epoch => $until, until_iso => $iso };
                print _encode_action($action), "\n";
                keepawake_apply('settled', $dsdir, $opts);
                return 0;
            }

            my $phase = pause_keepawake_phase($reason, $until, $now);
            if ($phase eq 'settled' && $reason eq 'usage' && defined $until) {
                _append_run_log($dsdir, sprintf(
                    'PAUSE-BEYOND-HORIZON (%.1fh away, horizon %.1fh) -- releasing the wake-lock; '
                  . 'the run still resumes at %d, but the machine is free to sleep until then',
                    ($until - $now) / 3600, $KEEPAWAKE_PAUSE_HORIZON_SECONDS / 3600, $until));
            }
            my $action = { action => 'pause', reason => $reason, until_epoch => $until };
            print _encode_action($action), "\n";
            keepawake_apply($phase, $dsdir, $opts);
            return 0;
        }

        # ok or degraded → find first ready package (spec §2.7, batch C: a
        # SECOND disjoint ready package may always be handed out while others
        # are in flight -- concurrent hand-out is unconditional now).
        #
        # Fix-batch red-team M2: the lock is acquired HERE, after this bp's own
        # verdict fetch (above) has already completed -- never across it. The
        # load, unconditional prune (review M1) and write of the set, and the
        # hand-out decision, all stay inside this block's lock, which is
        # released as soon as the block ends (whether by falling through to
        # the in-flight collection below, or by the `return 0` inside it).
        my $handed;
        {
            my $lock_fh = _acquire_inflight_lock($dsdir, $opts);
            my $dirty;
            ($inflight_entries, $dirty) = load_inflight($data, $dsdir, $now);
            my $pruned = _prune_inflight($data, $inflight_entries);
            $dirty = 1 if $pruned;
            _write_inflight_set($dsdir, $inflight_entries, $now) if $dirty;

            # Decision 65 / package 12 AC-20: reclaim a claimed-but-undriven
            # in-flight entry. Carried from package 11's red-team M1/M4 (this
            # ledger, 2026-09-24T12:50:48Z): an inflight.json entry can be
            # claimed but never driven. Reclaiming means handing it out again
            # -- a director act, done here rather than in the hook (spec sec
            # 3.5).
            my $bd_ok = eval {
                require "$DIR/BpHook/BindDispatch.pm"
                    unless defined &BpHook::BindDispatch::bound_since;
                1;
            };
            if ($bd_ok) {
                my $reclaim_after = $opts->{reclaim_after} // 1800;
                my @reclaimable =
                    sort { $a->{package} cmp $b->{package} }
                    grep {
                        $_->{blueprint} eq $bp
                        && (($status->{ $_->{package} } // 'pending') eq 'pending')
                        && (($now - $_->{since}) >= $reclaim_after)
                        && !BpHook::BindDispatch::bound_since($data, $bp, $_->{package}, $_->{since})
                        # package 30 / AC-12 (B11): never reclaim a pending
                        # entry whose deps (local or external) are unmet.
                        && deps_met($meta->{ $_->{package} }{deps}, $status)
                    } @$inflight_entries;
                if (@reclaimable) {
                    my $entry = $reclaimable[0];
                    my $pkg   = $entry->{package};
                    my $action = { action => 'run-package', blueprint => $bp, package => $pkg };
                    _append_run_log($dsdir, "RECLAIM $bp/$pkg (no dispatch bound since $entry->{since})");
                    _append_run_log($dsdir, "RUN $bp/$pkg");
                    $entry->{since}  = $now;
                    $entry->{ledger} = _ledger_str($data, $bp, $pkg);
                    _write_inflight_set($dsdir, $inflight_entries, $now);
                    print _encode_action($action), "\n";
                    keepawake_apply('active', $dsdir, $opts);
                    return 0;
                }
            }

            my @here = map { $_->{package} } grep { $_->{blueprint} eq $bp } @$inflight_entries;
            # Driver decision (Decision 31 / red-team H1 / review M2): a
            # package whose LEDGER status is `running` counts as in flight
            # whether or not it is recorded in inflight.json.
            push @here, grep { ($status->{$_} // '') eq 'running' } keys %$meta;
            my %here_seen = map { $_ => 1 } @here;
            my @ready = ready_packages($meta, $status, [ keys %here_seen ]);
            @ready = grep { !$here_seen{$_} } @ready;   # in-flight-but-pending is never re-handed

            my @other_ws;
            for my $e (grep { $_->{blueprint} ne $bp } @$inflight_entries) {
                push @other_ws, ledger_fm("$data/blueprints/$e->{blueprint}", $e->{package}, 'write_set') // '';
            }
            for my $obp (@$order) {
                next if $obp eq $bp;
                my $ometa   = $bp_meta{$obp}   // {};
                my $ostatus = $bp_status{$obp} // {};
                for my $opkg (keys %$ometa) {
                    next unless ($ostatus->{$opkg} // '') eq 'running';
                    push @other_ws, $ometa->{$opkg}{write_set};
                }
            }
            @ready = grep {
                my $ws = $meta->{$_}{write_set};
                !grep { write_sets_overlap($ws, $_) } @other_ws
            } @ready;
            $handed = $ready[0] if @ready;

            if (defined $handed) {
                my $pkg    = $handed;
                my $action = { action => 'run-package', blueprint => $bp, package => $pkg };
                _append_run_log($dsdir, "RUN $bp/$pkg");

                # §2.7 (batch C: always APPENDS to the set, keeping the old
                # `since` if the same pair was already present).
                my ($existing) = grep { $_->{blueprint} eq $bp && $_->{package} eq $pkg } @$inflight_entries;
                my $since = $existing ? $existing->{since} : $now;
                my $new_entry = { blueprint => $bp, package => $pkg, ledger => _ledger_str($data, $bp, $pkg), since => $since };
                @$inflight_entries = (
                    (grep { !($_->{blueprint} eq $bp && $_->{package} eq $pkg) } @$inflight_entries),
                    $new_entry,
                );
                _write_inflight_set($dsdir, $inflight_entries, $now);

                print _encode_action($action), "\n";
                keepawake_apply('active', $dsdir, $opts);
                return 0;
            }
        }

        # No ready packages, but the blueprint is NOT settled. The comment here
        # used to read "should not normally happen", and treated the state as
        # settled-pending by falling through to 'done'. It happens constantly:
        # any package marked 'running' is non-terminal, so the blueprint is not
        # settled, while ready_packages() correctly refuses to hand out a
        # package that is already owned or whose write set overlaps one. A
        # driver dispatching two workers concurrently reaches this on every
        # call.
        #
        # Record it instead of swallowing it. Falling through to 'done' asserts
        # "every in-scope blueprint is done-or-parked" (the documented contract
        # at the top of this file), which is simply false while work is in
        # flight -- and two safety mechanisms believe that assertion:
        #
        #   * stop-gate.sh, the Stop hook that keeps an unattended driver
        #     from ending a turn with nothing scheduled to continue the run,
        #     treats 'done' as "run settled" and allows the stop. So the run
        #     dies silently mid-package, looking finished -- the exact failure
        #     that hook was written to prevent.
        #   * the watchdog logic short-circuits to VERDICT: SETTLED on 'done',
        #     ahead of its own movement analysis, so an armed watchdog reports
        #     all-clear over a wedged run.
        #
        # Both were observed on 2026-08-08 in a single run, from this one
        # cause. Neither needs changing: 'in-flight' is not 'done', so the gate
        # blocks and the watchdog falls through to measuring movement, which is
        # what each already does for every other action.
        my @nonterminal = grep { !_is_terminal($status->{$_} // 'pending') } sort keys %$meta;
        my @running_now = grep { ($status->{$_} // '') eq 'running' } @nonterminal;
        push @in_flight, {
            blueprint => $bp,
            packages  => \@nonterminal,
            running   => \@running_now,
        } if @nonterminal;
    }

    # B6a: nothing is dispatchable, but at least one blueprint still holds
    # non-terminal packages. Distinct from 'done' on purpose -- "nothing to
    # hand out right now" and "the work is finished" are different statements,
    # and only the second one makes it safe to stop.
    if (@in_flight) {
        my $f = $in_flight[0];
        _append_run_log($dsdir, "IN-FLIGHT $f->{blueprint}"
            . ' running=' . (join(',', @{ $f->{running} }) || '-')
            . ' nonterminal=' . join(',', @{ $f->{packages} }));
        my $action = {
            action    => 'in-flight',
            blueprint => $f->{blueprint},
            packages  => $f->{packages},
            running   => $f->{running},
        };
        # §2.8 (batch C: unconditional): gain an `inflight` key carrying the
        # current set verbatim — never a re-issued run-package, which would
        # tell the session to start a second pipeline over a ledger it is
        # already driving.
        # The set is loaded lazily inside the hand-out block; if this call
        # never reached it, read (and prune, read-only) it here rather than
        # letting @$inflight_entries autovivify into an empty list, which
        # would tell a recovering session that nothing is in flight.
        unless (ref $inflight_entries eq 'ARRAY') {
            ($inflight_entries) = load_inflight($data, $dsdir, $now);
            _prune_inflight($data, $inflight_entries);
        }
        $action->{inflight} = [ map {
            { blueprint => $_->{blueprint}, package => $_->{package},
              ledger    => $_->{ledger},    since   => $_->{since} }
        } @$inflight_entries ];
        # package 30 (spec §2.3): external_waits key only when non-empty, so
        # a fixture with no cross tokens (AC-13/B12) produces a byte-identical
        # action.
        {
            my $ew = _external_waits_for($bp_meta{ $f->{blueprint} } // {}, $bp_status{ $f->{blueprint} } // {});
            $action->{external_waits} = $ew if @$ew;
        }
        print _encode_action($action), "\n";
        keepawake_apply('active', $dsdir, $opts);
        return 0;
    }

    # B6: all blueprints in the order are settled+announced (or parked)
    _append_run_log($dsdir, 'DONE');

    # Close the books before announcing done.
    #
    # Reaching here means nothing in scope can progress without a human, so this
    # is the one moment in the drive loop where no blueprint is being executed
    # and reconciliation cannot race anything. Two things happen:
    #   * derived state (blueprint.md's own `status:`, its package-status table,
    #     runs/registry.json, a stale runs/.orchestrator) is repaired against the
    #     ledgers, which are the truth;
    #   * a blueprint whose packages are ALL delivered is advanced to `done` and
    #     filed into blueprints/_archive/.
    #
    # This --all sweep is the BACKSTOP for the director's own single-blueprint
    # archive at blueprint-done (emission) and its retry sweep (B2a-B3):
    # unlike those, it ignores the deferral records entirely (Decision 3(1))
    # -- deliberately, since reaching B6 at all means nothing in scope can
    # progress without a human, so nothing can still be writing into any
    # blueprint's directory. It is a directory move, so it must only run
    # where nothing holds the directory — true at this point and not true
    # inside the orchestrator (which lives in it) or during a status read
    # (which may be observing a run about to relaunch). The director's own
    # state lives in <data>/.drive-solo/, outside every blueprint, so moving
    # one cannot disturb it.
    #
    # A blueprint that is merely settled — parked or blocked awaiting a human —
    # is NOT all-delivered and is therefore left exactly where it is. bp-lifecycle
    # enforces that; the drive loop does not need to re-decide it.
    #
    # Best-effort: the run is over and reported done either way. A reconciliation
    # failure must not manufacture a failed drive.
    {
        # director-archives-finished / package 01, spec §2.6#4: snapshot the
        # order BEFORE the sweep (its own archives happen inside the
        # subprocess below, invisible to this process until it returns), so
        # that "newly archived by THIS sweep" can be told apart from
        # "already archived earlier this run".
        my @snapshot_names = @$order
            ? grep { -f "$data/blueprints/$_/blueprint.md" } @$order
            : ();

        # M1 (review 01): the same non-blocking archive.lock as the
        # single-blueprint path, so this --all sweep can never race a
        # concurrent `next`'s archive of the same blueprint. Busy -> skip
        # the sweep this call, non-fatal, retried next time.
        my $lock_fh = _acquire_archive_lock($dsdir);
        if ($lock_fh) {
            my $lifecycle = "$DIR/bp-lifecycle.pl";
            if (-f $lifecycle) {
                my $rc = eval {
                    system($^X, $lifecycle, 'reconcile', '--all',
                           '--data-dir', $data, '--archive', '--quiet');
                };
                _append_run_log($dsdir, 'LIFECYCLE-RECONCILE '
                    . ((!$@ && defined $rc && $rc == 0) ? 'ok' : 'failed (non-fatal)'));
            }
        } else {
            _append_run_log($dsdir, 'LIFECYCLE-RECONCILE deferred -- archive in progress');
        }

        my @newly_archived = grep {
            !-e "$data/blueprints/$_" && -d "$data/blueprints/_archive/$_"
        } @snapshot_names;
        for my $n (@newly_archived) {
            _append_run_log($dsdir, "ARCHIVE $n archived -- by the run-done sweep");
        }
        _drop_from_order($dsdir, @newly_archived) if @newly_archived;
    }

    print _encode_action({ action => 'done', denials => _denials_count($data) }), "\n";
    keepawake_apply('settled', $dsdir, $opts);
    return 0;
}

# ===========================================================================
# SUBCOMMAND: record-order
# ===========================================================================

sub _cmd_record_order {
    my ($bps, $opts) = @_;
    unless (@$bps) {
        print STDERR "bp-drive-next record-order: at least one blueprint name required\n";
        return 2;
    }
    my $data  = $opts->{data_dir} or die "bp-drive-next: data_dir required\n";
    my $now   = $opts->{now}->();
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir) unless -d $dsdir;

    # Every name GIVEN must name a real blueprint.
    #
    # The omission check immediately below is exhaustive about what is MISSING
    # and said nothing whatsoever about what is PRESENT, so any string that
    # reached @argv was persisted verbatim as a blueprint name -- including a
    # flag. This machine's order.json held
    #     {"order":["--order","tui-operator-feedback"], ...}
    # from a `record-order --order <bp>` invocation. The damage is silent, not
    # loud: the B3 walk looks for a blueprint literally named "--order", finds no
    # blueprint.md, and parse_dag(undef) => {} makes blueprint_settled trivially
    # TRUE -- so the bogus entry reports itself settled and the run walks on. It
    # is the same false-settled class B2a documents, entered through the writer
    # rather than the reader, which is why fixing it there was not enough.
    #
    # Parked blueprints are accepted: a park excludes a blueprint from being
    # DRIVEN, not from existing, and its directory is still on disk. A name that
    # matches no directory at all is the error.
    {
        my $bpbase = "$data/blueprints";
        my @unknown = grep { !( -f "$bpbase/$_/blueprint.md" ) } @$bps;
        if (@unknown) {
            print STDERR "bp-drive-next record-order: not a blueprint:\n";
            print STDERR "  - $_\n" for @unknown;
            print STDERR "Each argument must be a blueprint directory name under $bpbase/ (record-order takes bare names, no flags -- a flag recorded as a blueprint name reports itself settled and is never driven).\n";
            return 2;
        }
    }

    # An order that OMITS a blueprint still holding non-terminal packages silently
    # drops that work: the `next` walk iterates the order, so an omitted blueprint
    # is never looked at. Refuse instead of accepting it.
    #
    # This is also what stops B2a from livelocking. B2a re-asks for an order
    # whenever the recorded one does not cover an in-scope candidate; if a session
    # could answer by re-recording the same incomplete order, the two would loop
    # forever. Here the incomplete answer fails loudly, and the message names the
    # sanctioned way to exclude a blueprint deliberately: park it.
    {
        my $bpbase = "$data/blueprints";
        my %given  = map { $_ => 1 } @$bps;

        my @dropped;
        if (-d $bpbase && opendir(my $dh, $bpbase)) {
            my @dirs = sort grep { $_ ne '.' && $_ ne '..' && $_ ne '_archive'
                                   && -f "$bpbase/$_/blueprint.md" } readdir $dh;
            closedir $dh;
            for my $bp (@dirs) {
                next if $given{$bp} || _bp_parked("$bpbase/$bp");
                my $dag = parse_dag(_read_file("$bpbase/$bp/blueprint.md"));
                my @live = grep { !_is_terminal(ledger_fm("$bpbase/$bp", $_, 'status') // 'pending') }
                           keys %$dag;
                push @dropped, "$bp (" . scalar(@live) . ' non-terminal package(s))' if @live;
            }
        }
        if (@dropped) {
            print STDERR "bp-drive-next record-order: refusing an order that omits blueprint(s) still holding non-terminal packages -- the `next` walk iterates the recorded order, so an omitted blueprint is never driven and the run reports 'done' over work it never looked at:\n";
            print STDERR "  - $_\n" for @dropped;
            print STDERR "Include them in the order, or exclude them deliberately with:\n"
                       . "  bp-drive-next.pl park <blueprint> [--needs-operator] <reason...>\n";
            return 2;
        }
    }

    _write_json_atomic("$dsdir/order.json", { order => $bps, recorded_at => $now });
    _append_run_log($dsdir, "order recorded: " . join(',', @$bps));
    return 0;
}

# ===========================================================================
# SUBCOMMAND: park (package 08-blueprint-parks, spec §2.3)
# ===========================================================================

# REASON_OK($r) -> 1|0 (spec §2.1). After trimming, non-empty, at most 200
# bytes, and contains none of CR, LF, '|' or '#'. Mirrors bp-blueprint.pl's
# own _reason_ok — kept as a second, deliberately tiny copy rather than a
# cross-script require, the same choice this file already makes for every
# other BpOrch-mirrored pure function.
sub _reason_ok {
    my ($r) = @_;
    return 0 unless defined $r && !ref $r;
    (my $t = $r) =~ s/\A\s+|\s+\z//g;
    return 0 unless length $t;
    return 0 if length($t) > 200;
    return 0 if $t =~ /[\r\n|#]/;
    return 1;
}
sub _trim_reason { my ($r) = @_; (my $t = $r) =~ s/\A\s+|\s+\z//g; return $t; }

# _run_capturing_stderr(@cmd) -> ($exit, $stderr_text). List-form subprocess
# (never a shell string); STDERR captured through a real temp file, never an
# in-memory scalar (Landmine #2). $exit is -1 if the process could not even
# be started.
#
# N6 (review NIT-6): the child's STDOUT is ALSO redirected, to /dev/null (or
# the Windows equivalent) -- set-meta prints nothing to stdout today, but
# this is the subprocess the stop gate's "empty stdout means unknown" action
# JSON contract depends on (spec §5/S3), and a future set-meta stdout line
# would otherwise land, unredirected, in whatever this process's own STDOUT
# currently is (the director's own action JSON during `next`'s migration
# call). Discarding it here removes that latent risk entirely rather than
# merely capturing it unused.
sub _run_capturing_stderr {
    my (@cmd) = @_;
    require File::Temp;
    my ($efh, $epath) = File::Temp::tempfile(); close $efh;
    my $devnull = File::Spec->devnull;
    open(my $saved_err, '>&', \*STDERR) or return (-1, "cannot dup STDERR: $!");
    open(my $saved_out, '>&', \*STDOUT) or do {
        open(STDERR, '>&', $saved_err); close $saved_err;
        return (-1, "cannot dup STDOUT: $!");
    };
    my $rc = -1;
    if (open(STDERR, '>', $epath) && open(STDOUT, '>', $devnull)) {
        $rc = system(@cmd);
    }
    open(STDERR, '>&', $saved_err); close $saved_err;
    open(STDOUT, '>&', $saved_out); close $saved_out;
    my $err = _read_file($epath) // '';
    unlink $epath;
    my $exit = ($rc == -1) ? -1 : ($rc >> 8);
    return ($exit, $err);
}

# _flock_bounded_secs($fh, $secs) -> 1 locked | 0 not within $secs. LOCK_NB
# polling: a plain LOCK_EX never times out.
sub _flock_bounded_secs {
    my ($fh, $secs) = @_;
    my $deadline = time + $secs;
    until (eval { flock($fh, LOCK_EX | LOCK_NB) }) {
        return 0 if time >= $deadline;
        select(undef, undef, undef, 0.05);
    }
    return 1;
}

# _park_item_open($items, $bp) -> $item|undef: the first OPEN park item for
# $bp (spec §2.2 step 4's definition, reused by both the director and
# bp-blueprint.pl's unpark hook): fields.link eq $bp, fields.status eq
# 'unanswered', title starting "Blueprint $bp parked:".
sub _park_item_open {
    my ($items, $bp) = @_;
    for my $it (@$items) {
        next unless ref $it eq 'HASH';
        next unless defined $it->{fields}{link}   && $it->{fields}{link}   eq $bp;
        next unless defined $it->{fields}{status} && $it->{fields}{status} eq 'unanswered';
        next unless defined $it->{fields}{title}  && $it->{fields}{title}  =~ /^Blueprint \Q$bp\E parked:/;
        return $it;
    }
    return undef;
}

sub _cmd_park {
    my ($bp, $reason, $needs_operator, $opts) = @_;
    my $data  = $opts->{data_dir} or die "bp-drive-next: data_dir required\n";
    my $dsdir = "$data/.drive-solo";
    # No make_path here: every validation refusal below (B20) must leave
    # the data dir byte-for-byte untouched, including no .drive-solo/ at
    # all when it did not already exist. _append_run_log creates it lazily,
    # only on the PARK line this function logs after a real write.

    # M1/SF-2/L5 (redteam-1): validate the name BEFORE any filesystem check
    # that could be satisfied by a path-traversal segment (`../../victim`).
    # Reuses `_valid_name`, the same grammar already used for an
    # inflight.json blueprint entry, plus a length cap -- this also closes
    # L5 (an invalid name under --needs-operator used to park first and only
    # fail at filing time, looping on exit 3 forever on every retry).
    unless (_valid_name($bp) && length($bp) <= 128) {
        print STDERR "bp-drive-next park: '$bp' is not a valid blueprint name "
                    . "(expected alnum start, then alnum/./_/-, at most 128 bytes)\n";
        return 2;
    }

    # Validation (spec §2.3 step 4, exit 2, nothing written).
    my $bpdir = "$data/blueprints/$bp";
    my $bpmd  = "$bpdir/blueprint.md";
    unless (-f $bpmd) {
        print STDERR "bp-drive-next park: no such blueprint '$bp' (no $bpmd)\n";
        return 2;
    }
    require "$DIR/BpState.pm" unless defined &BpState::norm_bp_status;
    my $authored = BpState::norm_bp_status(BpState::bp_meta_get($bpmd, 'status'));
    if ($authored eq 'archived') {
        print STDERR "bp-drive-next park: '$bp' is archived; refusing to park an archived blueprint\n";
        return 2;
    }

    my $root;
    if ($needs_operator) {
        (my $norm = $data) =~ s{\\}{/}g;
        $norm =~ s{/+\z}{};
        unless ($norm =~ m{^(.+)/\.ccpraxis-local-data\z} && -d "$1/.ccpraxis-local-data") {
            print STDERR "bp-drive-next park: --needs-operator requires the data dir to be "
                        . "<project>/.ccpraxis-local-data; got $data\n";
            return 2;
        }
        $root = $1;
        my $inbox_pl = "$DIR/../../almanac/scripts/almanac-inbox.pl";
        my $load_ok = eval { require $inbox_pl; 1 };
        unless ($load_ok) {
            (my $msg = $@) =~ s/\s+\z//;
            print STDERR "bp-drive-next park: --needs-operator requires the inbox library "
                        . "($inbox_pl), which failed to load: $msg\n";
            return 2;
        }
    }

    # Write (spec §2.3 step 5): already parked -> write nothing, log nothing
    # (EC-2, the first reason wins). Otherwise a list-form bp-blueprint.pl
    # set-meta subprocess.
    if ($authored ne 'parked') {
        my ($exit, $err) = _run_capturing_stderr(
            $^X, "$DIR/bp-blueprint.pl", 'set-meta', '--file', $bpmd,
            '--field', 'status', '--value', 'parked', '--reason', $reason);
        if ($exit != 0) {
            print STDERR $err if length $err;
            print STDERR "bp-drive-next park: could not park '$bp' (bp-blueprint.pl set-meta exited $exit)\n"
                unless length $err;
            return 2;
        }
        # MF-1/M3 (redteam-1): set-meta exiting 0 is not proof the fenced
        # `status:` line actually changed -- a fence-scoping defect in the
        # rewrite could leave blueprint.md reading as unparked while this
        # function reports success and logs PARK. Re-check with the same
        # reader the rest of the director trusts before logging anything.
        unless (_bp_parked($bpdir)) {
            print STDERR "bp-drive-next park: set-meta exited 0 for '$bp' but it does not read as "
                        . "parked afterwards; refusing to log PARK\n";
            return 2;
        }
        _append_run_log($dsdir, "PARK $bp — $reason");
    }

    # needs-operator (spec §2.3 step 6): file one item, unless one is already
    # open. Exit 3 on a filing failure -- the status stays parked either way.
    if ($needs_operator) {
        # L4(b) (redteam, todo 20261002-185449-c3eb0000): two concurrent
        # `park --needs-operator` calls each ran list -> check -> file with no
        # lock around the sequence, so both could file an item. The sequence
        # now runs under blueprint.md's own lock -- the one bp-blueprint.pl's
        # run_write holds while an unpark closes park items -- so it is
        # serialised against other filers AND against an unpark: if an unpark
        # got in first, the blueprint no longer reads parked under the lock
        # and nothing is filed at all. Bounded wait; on expiry this is the
        # same exit-3 "already parked, re-run to retry filing" as any other
        # filing failure.
        my $plk;
        unless (open($plk, '>', "$bpmd.lock") && _flock_bounded_secs($plk, 10)) {
            close $plk if $plk;
            print STDERR "bp-drive-next park: could not lock $bpmd.lock to file the inbox item for '$bp'\n";
            print STDERR "'$bp' is already parked; re-run the same command to retry filing it.\n";
            return 3;
        }
        unless (_bp_parked($bpdir)) {
            close $plk;     # unparked meanwhile: nothing left to ask the operator
            return 0;
        }
        my $filed_item;
        my $ok = eval {
            my $items = Almanac::Inbox::list_items(root => $root);
            unless (_park_item_open($items, $bp)) {
                $filed_item = Almanac::Inbox::file(root => $root, title => "Blueprint $bp parked: $reason",
                    link => $bp,
                    body => "Unpark with: bp-blueprint.pl set-meta --file $bpmd --field status --value audited\n");
            }
            1;
        };
        close $plk;   # releases the lock; the L4(c) re-check below needs none
        unless ($ok) {
            (my $msg = $@) =~ s/\s+\z//;
            print STDERR "bp-drive-next park: could not file the inbox item for '$bp': $msg\n";
            print STDERR "'$bp' is already parked; re-run the same command to retry filing it.\n";
            return 3;
        }

        # L4(c) (redteam-1): an unpark can race in between the set-meta write
        # above and this filing. Nothing else will ever close an item filed
        # for a blueprint that is no longer parked (the unpark hook only
        # fires on a status write LEAVING parked, and none happened here) --
        # so re-check and close it ourselves rather than leave it orphaned.
        # Best-effort: a failure here just leaves the pre-existing race
        # window open, no worse than before this check.
        if (defined $filed_item && !_bp_parked($bpdir)) {
            eval {
                Almanac::Inbox::open_inbox(root => $root)->update($filed_item->{id},
                    expect => { rev => $filed_item->{rev}, fields => $filed_item->{fields} },
                    set    => { status => 'answered',
                                closed_at => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(CORE::time())),
                                closed_reason => "blueprint $bp was unparked concurrently with this --needs-operator filing",
                                closed_by => 'bp-drive-next.pl park' });
            };
        }
    }

    return 0;
}

# ===========================================================================
# _migrate_parks_json (spec §2.4): absorbs a legacy park file, if one exists,
# into every listed blueprint's own blueprint.md as status: parked. Runs
# from run() BEFORE every subcommand. The legacy file is removed only once
# every listed entry is migrated -- a migration failure leaves it untouched
# and fails the WHOLE call closed (exit 2, empty stdout), per this package's
# self-modification safety constraint (spec §5): one of "the legacy file is
# gone and blueprint.md is the whole truth" or "the director refuses to act"
# always holds, never a mix. This function is the ONLY place in this file --
# and, per the static check this package adds, the only place outside
# tests/ in the whole plugin tree -- that names the legacy file by its
# literal filename.
# ===========================================================================

sub _sanitize_migrate_reason {
    my ($r) = @_;
    $r = (defined $r && !ref $r) ? $r : '';
    $r =~ s/[\r\n|#]/ /g;
    $r =~ s/\s+/ /g;
    $r =~ s/\A\s+|\s+\z//g;
    if (length($r) > 200) {
        $r = substr($r, 0, 200);
        # N1 (review NIT-1): back off an INCOMPLETE trailing UTF-8 sequence
        # only -- never a COMPLETE one that merely happens to end exactly on
        # the 200-byte boundary. The previous version always stripped any
        # trailing continuation run plus the lead byte before it, which lost
        # a whole, perfectly valid character whenever the cut landed cleanly
        # (spec E6 only requires never SPLITTING a character, not discarding
        # one gratuitously). Scan back at most 3 bytes (the longest lead-byte
        # distance for a 4-byte sequence) to find the nearest non-
        # continuation byte, then compare how many continuation bytes
        # actually follow it to how many its own high bits declare.
        my $len = length($r);
        for my $back (1 .. 3) {
            last if $back > $len;
            my $pos = $len - $back;
            my $b = ord(substr($r, $pos, 1));
            next if ($b & 0xC0) == 0x80;   # a continuation byte -- keep scanning back
            my $expect = ($b & 0xF8) == 0xF0 ? 3
                       : ($b & 0xF0) == 0xE0 ? 2
                       : ($b & 0xE0) == 0xC0 ? 1
                       : 0;
            my $have = $back - 1;          # continuation bytes actually present after it
            $r = substr($r, 0, $pos) if $expect > 0 && $have < $expect;
            last;                           # found the nearest lead/ASCII byte; stop
        }
    }
    return length($r) ? $r : '(no reason recorded)';
}

# _migrate_parks_json($data, $dsdir, $opts) -> @failures (empty = ok).
sub _migrate_parks_json {
    my ($data, $dsdir, $opts) = @_;
    my $file = "$dsdir/parks.json";
    return () unless -e $file;

    # L1 second half (redteam, todo 20261002-185449-c3eb0000): two director
    # invocations could both decode the file; one finished, unlinked it, and
    # the operator then unparked a blueprint -- while the other, still on its
    # stale in-memory list, re-parked it. The whole read -> park -> unlink
    # sequence now runs under one lock, and the file's existence is checked
    # again once it is held: a caller that waited finds the file gone and
    # has nothing to migrate. The lock is released when $mlk goes out of
    # scope (every return below). Bounded wait; on expiry the call fails
    # closed like any other migration failure.
    my $mlk;
    unless (open($mlk, '>', "$dsdir/parks.migrate.lock") && _flock_bounded_secs($mlk, 10)) {
        return ("could not lock $dsdir/parks.migrate.lock for the legacy park migration");
    }
    return () unless -e $file;

    # Decoded WITH ->utf8 (unlike every other JSON reader in this file): the
    # legacy file may carry a reason with real non-ASCII content (spec §2.4
    # step 2/E6), and only a semantic UTF-8 decode here, paired with an
    # explicit re-encode back to bytes below before the reason reaches argv,
    # round-trips it byte-for-byte. Decoding as plain octets (this file's
    # usual `_read_json_file`) would upgrade each raw UTF-8 byte to its OWN
    # codepoint instead, which a subprocess call then mangles on the way out.
    # M2 (redteam-1): _read_file returning undef is a READ failure (EACCES, a
    # sharing violation), not evidence the file is corrupt -- fail closed
    # (a migration failure for the whole call) rather than moving aside a
    # file nothing actually looked at.
    my $raw = _read_file($file);
    return ("could not read $file: $!") unless defined $raw;

    my $decoded = eval { JSON::PP->new->utf8->decode($raw) };
    my $octet_fallback = 0;
    if ($@ || ref($decoded) ne 'ARRAY') {
        # M2 (redteam-1): a valid-JSON parks.json holding non-UTF-8 bytes (a
        # raw CP1252 byte in a reason, say) croaks under ->utf8. The OLD
        # reader (_read_json_file) decoded without ->utf8 (octet semantics)
        # and the old writer wrote raw argv bytes back verbatim, so such a
        # file was an EFFECTIVE park under the old code. Retry with octet
        # semantics before concluding the file is corrupt; only the
        # "moved aside" conclusion loses parks the old code honoured.
        my $octet_decoded = eval { JSON::PP->new->decode($raw) };
        if (!$@ && ref($octet_decoded) eq 'ARRAY') {
            $decoded = $octet_decoded;
            $octet_fallback = 1;
        }
    }
    if (ref($decoded) ne 'ARRAY') {
        my $moved = "$dsdir/parks.json.corrupt-" . $opts->{now}->();
        unless (rename($file, $moved)) {
            return ("could not move aside corrupt parks.json to $moved: $!");
        }
        _append_run_log($dsdir, "WARN PARKS-MIGRATE: $file is not a JSON array; moved aside to $moved");
        return ();
    }

    require "$DIR/BpState.pm" unless defined &BpState::norm_bp_status;

    my ($parked_now, @failures) = (0);
    for my $entry (@$decoded) {
        next unless ref $entry eq 'HASH';
        my $bp = $entry->{blueprint};
        next unless defined $bp && !ref $bp && length $bp;

        # M1/SF-2 (redteam-1): an entry naming a path-traversal segment
        # (`../../victim`) must not reach the filesystem checks below. Skip
        # and log it, same as any other unmigratable entry -- it does not
        # fail the whole migration (spec §2.4 step 3's existing skip shape).
        unless (_valid_name($bp) && length($bp) <= 128) {
            _append_run_log($dsdir, "PARKS-MIGRATE skip $bp: invalid blueprint name");
            next;
        }

        my $bpmd = "$data/blueprints/$bp/blueprint.md";
        unless (-f $bpmd) {
            _append_run_log($dsdir, "PARKS-MIGRATE skip $bp: no live blueprint");
            next;
        }
        my $authored = BpState::norm_bp_status(BpState::bp_meta_get($bpmd, 'status'));
        if ($authored eq 'archived') {
            _append_run_log($dsdir, "PARKS-MIGRATE skip $bp: archived");
            next;
        }
        next if $authored eq 'parked';   # already parked -- ok, no write, no re-log

        # Re-encode the decoded (character) reason back to raw bytes before
        # it goes anywhere near argv or _sanitize_migrate_reason's
        # byte-counting (spec §2.4 step 2) -- an ASCII-only reason round-trips
        # through this as a no-op either way. M2 (redteam-1): when the whole
        # file was decoded under the OCTET fallback above, JSON::PP still
        # hands back a utf8-FLAGGED Perl string whose codepoints are each
        # 0-255 and equal the original raw byte values one-for-one (octet
        # decoding never produces a codepoint above 255) -- it is NOT already
        # a byte string. encode_utf8 would re-encode it as real UTF-8 (one
        # codepoint like U+00E9 becomes the TWO bytes 0xC3 0xA9), corrupting
        # it a second time; the correct downgrade is iso-8859-1/latin1, which
        # maps each 0-255 codepoint back to its identical single raw byte.
        my $reason_bytes = $entry->{reason};
        $reason_bytes = (defined $reason_bytes && !ref $reason_bytes)
            ? ($octet_fallback ? Encode::encode('iso-8859-1', $reason_bytes) : Encode::encode_utf8($reason_bytes))
            : '';
        my $reason = _sanitize_migrate_reason($reason_bytes);
        my ($exit, $err) = _run_capturing_stderr(
            $^X, "$DIR/bp-blueprint.pl", 'set-meta', '--file', $bpmd,
            '--field', 'status', '--value', 'parked', '--reason', $reason);
        if ($exit != 0) {
            (my $msg = $err) =~ s/\s+\z//;
            push @failures, "could not park $bp during parks.json migration"
                           . (length($msg) ? ": $msg" : '');
            next;
        }
        # MF-1/M3 (redteam-1): re-check, same as _cmd_park -- set-meta exiting
        # 0 is not proof the fenced status line actually changed. Treat a
        # mismatch as a migration failure for this entry so the file is kept
        # (not unlinked) rather than silently losing the park.
        unless (_bp_parked("$data/blueprints/$bp")) {
            push @failures, "$bp: set-meta exited 0 during migration but it does not read as parked afterwards";
            next;
        }
        $parked_now++;
    }

    return @failures if @failures;

    unless (unlink($file) || $!{ENOENT}) {
        return ("could not remove $file after migration: $!");
    }
    # N2 (review NIT-2): "skipped" here is everything this call did NOT park
    # just now -- it lumps together entries already parked (no write needed,
    # arguably a success) with entries genuinely skipped (no live blueprint,
    # archived, invalid name, not a hash/no blueprint key). No test or
    # consumer distinguishes these sub-counts today; documenting the lumped
    # meaning here is the cheapest correct fix rather than growing the
    # loop's bookkeeping for a line only run.md shows.
    my $skipped = scalar(@$decoded) - $parked_now;
    _append_run_log($dsdir, "PARKS-MIGRATED $parked_now parked, $skipped skipped");
    return ();
}

# ===========================================================================
# JSON encoding: use canonical, and handle undef as JSON null explicitly
# ===========================================================================

sub _encode_action {
    my ($action) = @_;
    # package 11 (tooling-backlog), spec sec 2.5: after a resume, the
    # director logs RESUMED with the first normal action's name, right
    # before printing it. Every _cmd_next return path funnels through this
    # one function, so this is the single point that needs to know.
    if (defined $AC_RESUME_DATA) {
        my $d = $AC_RESUME_DATA;
        $AC_RESUME_DATA = undef;
        eval {
            require "$DIR/BpAcWatch.pm" unless defined &BpAcWatch::log_event;
            my $name = (ref $action eq 'HASH' && defined $action->{action}) ? $action->{action} : '-';
            BpAcWatch::log_event($d, 'director', 'RESUMED', { first_action => $name },
                'resume complete; reporting the first normal action');
        };
    }
    # We need JSON null for until_epoch when undef.
    # JSON::PP->new->canonical handles undef → null correctly.
    return JSON::PP->new->canonical->encode($action);
}

# never-halt package 06: denials count for the `done` action. Any failure
# (bad data dir, decode error, missing file) degrades to 0 -- a corrupt or
# huge denials.jsonl can only lower the count, never fail `done` (spec
# sec 2.10, edge case 12).
sub _denials_count {
    my ($data) = @_;
    my $n = eval { BpHook::PromptWatch::denial_count($data) };
    return (defined $n && $n =~ /\A\d+\z/) ? $n : 0;
}

# ===========================================================================
# HELP TEXT
# ===========================================================================

my $HELP_TEXT = <<'END_HELP';
bp-drive-next.pl — the mechanical director for /butler:drive-solo.
Stateless-from-disk: every `next` recomputes from ledgers + <data>/.drive-solo/.

USAGE
  bp-drive-next.pl next --scope <spec>
  bp-drive-next.pl record-order <bp> [<bp> …]
  bp-drive-next.pl park <blueprint> [--needs-operator] <reason…>
  bp-drive-next.pl --help

SUBCOMMANDS
  next --scope <spec>
      Print exactly ONE next-action JSON (below) to stdout, single line.
      <spec> = one blueprint name | comma/space list of names | "all" (or empty) = all audited blueprints. <spec> resolves mechanically to the candidate SET and is used ONLY for need-order candidates; once order.json exists it is the authoritative scope+order and --scope is ignored.
  record-order <bp> [<bp> …]
      Persist the SESSION-judged blueprint order to order.json. The director never invents order — it only persists and serves it.
  park <blueprint> [--needs-operator] <reason…>
      Write status: parked and the reason into the blueprint's own blueprint.md (idempotent, via bp-blueprint.pl set-meta) and log it. A parked blueprint is settled: never driven, excluded from every pending list. --needs-operator also files one inbox item linked to the blueprint; unparking (bp-blueprint.pl set-meta --field status --value <audited|drafting|archived>) closes that item.

NEXT-ACTION JSON  (exactly one per `next`)
  {"action":"need-order","candidates":[…]}          no order yet; session must judge+record
  {"action":"run-package","blueprint":B,"package":P} drive this package next
  {"action":"pause","until_epoch":E,"reason":"usage"} timed auto-resume at epoch E
  {"action":"pause-long","reason":"usage","until_epoch":E,"until_iso":"…"}  usage pause ending more than 12 h out: the session writes its handoff and ends; no auto-resume in this session
  {"action":"stop","reason":"token-refresh-failed","detail":…} token could not be refreshed; the wake-lock is released and the run ends. NOT a pause: a pause promises a resume, and there is none until a human re-authenticates.
  {"action":"blueprint-done","blueprint":B,"pending":[…],"archived":true|false,"archive_detail":"…"} B settled; pending = remaining bps to re-eval; archived/archive_detail report the director's own single-blueprint archive attempt (reuses bp-lifecycle.pl reconcile --archive)
  {"action":"in-flight","blueprint":B,"packages":[…],"running":[…]} nothing dispatchable right now, but B still holds non-terminal packages (typically owned by a concurrent worker). NOT completion: stopping here kills the run mid-package.
  {"action":"done","denials":N}                      every in-scope blueprint is done-or-parked; N = cumulative auto-mode denial count (never-halt Decision 9; see `bp-denials summary` for a breakdown)
  {"action":"ac-stand-down","reason":"ac-loss","on_battery_since_iso":…,"grace_expired_iso":…,"inflight":[…],"monitor_live":true|false,"log":…} package 11 (tooling-backlog): AC power lost past the 5-minute grace period; stand down, disarm continuity, release the wake-lock and run bp-ac-watch.pl monitor

  Keep-awake is a director-managed SIDE EFFECT (started when work is runnable or a timed auto-resume is pending; stopped when settled) — never an action.

GOVERNOR VERDICT CONSUMED  (from bp-usage-gate.pl verdict — pkg-02)
  {"action":"ok"|"pause-usage"|"pause-token"|"unavailable","until_epoch":E|null,"reason":…}
  ok           → proceed
  pause-usage  → pause reason=usage, until_epoch=E; pause-long instead when E - now > 12 h
  pause-token  → attempt a refresh (bp-token-keeper). Recovered → proceed; failed → action=stop, wake-lock released, error logged. Solo NEVER pauses for token expiry — see _token_recover.
  unavailable  → retry a few times, then degrade-and-proceed (log "governance degraded")

STATE  (<data>/.drive-solo/, all director-owned)
  order.json      {"order":[…],"recorded_at":<epoch>}
  announced.json  {"announced":[…]}   blueprints whose blueprint-done already fired
  inflight.json   {"packages":[{"blueprint":…,"package":…,"ledger":…,"since":<epoch>}],
                  "updated_at":<epoch>}   the project-level in-flight set: added on run-package, pruned once its ledger turns terminal. Concurrent hand-out (a further ready package disjoint from every in-flight write set) is unconditional.
  keepawake.pid   PID of the wake-lock process (host only; sandbox = no file)
  run.md          append-only structured run log
END_HELP

# ===========================================================================
# PROJECT-ANCHORED DATA-DIR RESOLUTION
# ===========================================================================
# CRITICAL: the data root MUST be anchored to the PROJECT, never to __FILE__/the
# plugin dir. A marketplace/plugin install lives OUTSIDE the project tree — e.g.
# $HOME/.claude/plugins/marketplaces/<mkt>/butler/scripts — so a script-relative
# "../../../.ccpraxis-local-data" guess resolves an unrelated root (the
# marketplaces dir) that has no blueprints/. read_state then builds an empty DAG,
# every blueprint looks settled, and `next` silently emits blueprint-done→done
# despite pending work. bp-lib.sh's bp_project_root()+bp_data_dir() is still
# the unbounded walk-up this package replaces here (Decision 17 follow-up);
# the two are not yet the same logic.
#
# Priority (BpDataRoot.pm, package 04 — written once, shared with bp-lifecycle.pl):
#   data_dir opt ($opts->{data_dir}, a PROGRAMMATIC seam -- there is no CLI
#     --data-dir option on this director) > $CCPRAXIS_DATA_DIR
#     > <project root>/.ccpraxis-local-data
#   project root = $BP_PROJECT_ROOT > git toplevel
#     > BOUNDED walk-up from cwd for a dir containing .ccpraxis-local-data
#       (stops at the OS temp dir and at the user's home dir; neither is
#       adopted unless it IS the cwd -- bug 0f1e) > cwd

sub _resolve_project_root { BpDataRoot::project_root() }

sub _resolve_data_dir {
    my ($opts) = @_;
    return BpDataRoot::data_dir(data_dir => $opts->{data_dir});
}

# ===========================================================================
# ARGUMENT VALIDATION (spec §2.4, Decision 7: "any argument starting with
# '-' that the subcommand does not define" is rejected, exit 2, BEFORE any
# root resolution -- so a bug-0f1e-shaped mistyped flag never gets a chance
# to be silently ignored while the walk-up quietly adopts the wrong root).
# ===========================================================================

my $USAGE = <<'END_USAGE';
usage: bp-drive-next.pl next --scope <spec>
       bp-drive-next.pl record-order <bp> [<bp> ...]
       bp-drive-next.pl park <blueprint> [--needs-operator] <reason...>
       bp-drive-next.pl --help
END_USAGE

# Returns the FIRST offending dash-argument (in argv order), or undef if
# every element is well-formed for $sub. `next` defines --scope <spec>: the
# element right after --scope is consumed as its value only when it exists
# and does not itself start with '-' (otherwise --scope's value is '' and
# that next element is validated on its own, same as the old silent-ignore
# parse used to leave for _cmd_next). `record-order` defines no options at
# all, so ANY element starting with '-' is rejected. `park` defines exactly
# one option, the bare token --needs-operator, in any position after the
# subcommand (spec §2.3); any other element starting with '-' is rejected --
# including a `park` reason word typed unquoted with a leading dash (Q4).
sub _reject_unknown_options {
    my ($sub, $argv) = @_;
    my @a = @$argv;

    if ($sub eq 'next') {
        my $i = 0;
        while ($i <= $#a) {
            my $o = $a[$i];
            if ($o eq '--scope') {
                $i++;
                $i++ if $i <= $#a && $a[$i] !~ /^-/;
                next;
            }
            return $o if $o =~ /^-/;
            $i++;
        }
        return undef;
    }

    if ($sub eq 'park') {
        for my $o (@a) {
            next if $o eq '--needs-operator';
            return $o if $o =~ /^-/;
        }
        return undef;
    }

    for my $o (@a) {
        return $o if $o =~ /^-/;
    }
    return undef;
}

# ===========================================================================
# TOP-LEVEL run() — the seam entry point (spec §4)
# ===========================================================================

sub run {
    my ($argv, $opts) = @_;
    $opts //= {};

    my @argv = @{ $argv // [] };
    my $sub  = shift @argv // '';

    # --help / -h need no data dir — handle before any resolution or shell-out.
    if ($sub eq '--help' || $sub eq '-h') {
        print $HELP_TEXT;
        return 0;
    }

    # NEW (spec §2.4 step 2): an unrecognised subcommand -- including a
    # leading flag such as `--data-dir X next` -- is rejected here, before
    # any root resolution, rather than falling through to the old
    # end-of-run() "unknown subcommand" branch.
    unless ($sub eq 'next' || $sub eq 'record-order' || $sub eq 'park') {
        print STDERR "bp-drive-next: unknown subcommand '$sub'\n";
        print STDERR $USAGE;
        return 2;
    }

    # NEW (spec §2.4 step 3): reject any dash-argument the subcommand does
    # not define, BEFORE any resolution -- nothing is resolved, spawned, or
    # written on rejection.
    if (defined(my $bad = _reject_unknown_options($sub, \@argv))) {
        print STDERR "bp-drive-next $sub: unknown option '$bad'\n";
        print STDERR $USAGE;
        return 2;
    }

    # park's own argument shape (spec §2.3 step 1): --needs-operator in any
    # position, then <blueprint>, then the reason (join of what remains).
    # REASON_OK is checked here too -- BEFORE any data-root resolution or
    # migration, so a bad reason never shells out or writes anything.
    my ($park_bp, $park_reason, $park_needs_operator);
    if ($sub eq 'park') {
        $park_needs_operator = 0;
        my @filtered;
        for my $a (@argv) {
            if ($a eq '--needs-operator') { $park_needs_operator = 1; next; }
            push @filtered, $a;
        }
        $park_bp     = shift @filtered;
        $park_reason = join(' ', @filtered);
        unless (defined $park_bp && length $park_bp) {
            print STDERR "bp-drive-next park: blueprint name required\n";
            return 2;
        }
        unless (_reason_ok($park_reason)) {
            print STDERR "bp-drive-next park: reason must be non-empty, at most 200 bytes, "
                        . "and contain none of CR, LF, '|' or '#'\n";
            return 2;
        }
        $park_reason = _trim_reason($park_reason);
    }

    # Inject production defaults for each seam. data_dir is PROJECT-anchored
    # (see _resolve_data_dir) — NEVER __FILE__/plugin-relative.
    my $data_dir = _resolve_data_dir($opts);

    # Fail loud on an indeterminate / mis-resolved data root — for EVERY subcommand
    # that reads or writes blueprint state. A missing blueprints/ must NEVER be treated
    # as valid: for `next` it makes the empty DAG look settled and emits
    # blueprint-done→done (the silent false-completion bug); for `record-order`/`park`
    # it would write order/park state under the wrong root where no `next` will ever
    # read it (silent state loss on a hand-run with a wrong CCPRAXIS_DATA_DIR). Mirror
    # the siblings (bp-orchestrator / bp-answer-decision / bp-wait-for-decision), which
    # exit nonzero when the data dir is indeterminate rather than guessing. Runs before
    # any make_path, so a wrong root never materializes a bogus .drive-solo/.
    if ($sub eq 'next' || $sub eq 'record-order' || $sub eq 'park') {
        unless (-d "$data_dir/blueprints") {
            print STDERR "bp-drive-next: no blueprints/ under the resolved data dir:\n";
            print STDERR "    $data_dir\n";
            print STDERR "  Resolution order: \$CCPRAXIS_DATA_DIR > \$BP_PROJECT_ROOT > git toplevel\n";
            print STDERR "                    > walk-up for .ccpraxis-local-data (stops at the temp dir and at home) > cwd.\n";
            print STDERR "  Set CCPRAXIS_DATA_DIR=<project>/.ccpraxis-local-data and retry.\n";
            return 2;
        }
    }

    my $now_fn = $opts->{now} // sub { time };
    my $verdict_fn = $opts->{verdict} // sub {
        # TEST / DIAGNOSTIC SEAM, honoured only for well-formed JSON carrying an
        # 'action'. The production path below shells out to bp-usage-gate.pl,
        # which reads the host's REAL OAuth state -- so every consumer of the
        # director inherits that state, including stop-gate.sh and any
        # assertion about it. On 2026-08-08 t/94's stop-gate assertions went red
        # for exactly this reason: the host token aged under the relogin floor
        # mid-run, the director began answering pause/token, the gate correctly
        # allowed the stop, and a test that had passed an hour earlier failed
        # without a line of code changing. A test whose result tracks a token
        # clock is a false red, and this repo has already paid for that shape
        # once in t/95 (a child resolving its own data dir from the cwd).
        #
        # Deliberately NOT a general "skip governance" switch: it is read only
        # here, it must parse, and it must carry an action. It cannot be set by
        # accident, and nothing in the production launch path sets it.
        if (defined $ENV{CCPRAXIS_USAGE_VERDICT_JSON} && length $ENV{CCPRAXIS_USAGE_VERDICT_JSON}) {
            my $ov = eval { JSON::PP->new->decode($ENV{CCPRAXIS_USAGE_VERDICT_JSON}) };
            return $ov if ref $ov eq 'HASH' && defined $ov->{action};
        }
        # Production: shell out to bp-usage-gate.pl verdict in the same dir
        my $gate = "$DIR/bp-usage-gate.pl";
        my $out  = eval { `"$^X" "$gate" verdict 2>/dev/null` };
        if ($? != 0 || !defined $out || !length $out) {
            return { action => 'unavailable' };
        }
        my $d = eval { JSON::PP->new->decode($out) };
        return $@ ? { action => 'unavailable' } : $d;
    };

    # Rebuild opts with all injected seams + data_dir
    my %full_opts = (
        %$opts,
        data_dir => $data_dir,
        now      => $now_fn,
        verdict  => $verdict_fn,
        # Keep-awake actuation is NOT defaulted here any more: BpKeepAwake::apply
        # supplies the real spawn/kill/probe when the opts omit them, and an
        # injected fake still overrides because keepawake_apply passes %$opts
        # straight through. Defaulting here as well meant this file carried its
        # own copy of the actuation — the duplication t/111 now forbids.
        #
        # (These were once empty subs, which made the whole mechanism inert in
        # production while still looking wired — see 3c661a0. The module's
        # defaults are real; that is the point of them living in one place.)
    );

    # _migrate_parks_json (spec §2.4): runs from run(), AFTER the data-root
    # check and BEFORE dispatch to _cmd_next / _cmd_record_order / _cmd_park
    # -- no subcommand reads director state before this. Self-modification
    # safety (spec §5): on failure, print to STDERR, nothing on STDOUT, and
    # return 2 -- never drive anything over a half-migrated legacy park file.
    {
        # No make_path here: a data dir with no legacy park file (the
        # steady state for every B20 refusal fixture) must leave NO trace
        # at all -- _migrate_parks_json's own -e check short-circuits
        # before touching .drive-solo/, and _append_run_log creates it
        # lazily only when there is something real to log.
        my $dsdir = "$data_dir/.drive-solo";
        my @fail = _migrate_parks_json($data_dir, $dsdir, \%full_opts);
        if (@fail) {
            print STDERR "bp-drive-next: legacy park migration failed -- nothing driven:\n";
            print STDERR "  - $_\n" for @fail;
            # Redteam L2 (cheap half): this stalls every subsequent call on
            # every blueprint until the cause is fixed, with no other signal
            # (exit 2, empty stdout, by design -- spec §5/B17). Point at
            # repairing or removing the offending entry (named above) in the
            # legacy park file under $dsdir, so an unattended run's operator
            # is not left guessing. (The legacy file's own name is a literal
            # string AC5 confines to _migrate_parks_json's body, so it is not
            # repeated here -- see that sub's failure messages above.)
            print STDERR "Repair or remove the offending entry (named above) in the legacy park file "
                        . "under $dsdir, then retry -- each entry is migrated independently and idempotently.\n";
            return 2;
        }
    }

    if ($sub eq 'next') {
        return _cmd_next(\@argv, \%full_opts);
    } elsif ($sub eq 'record-order') {
        return _cmd_record_order(\@argv, \%full_opts);
    } else {    # $sub eq 'park'
        return _cmd_park($park_bp, $park_reason, $park_needs_operator, \%full_opts);
    }
}

# ===========================================================================
# CLI entry point (when run directly, not required)
# ===========================================================================
package main;
use strict;
use warnings;
unless (caller) {
    my $rc = BpDrive::run(\@ARGV);
    exit($rc // 2);
}
1;
