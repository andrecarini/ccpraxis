#!/usr/bin/env perl
# bp-drive-next.pl — the mechanical director for /butler:drive-solo.
# Stateless-from-disk: every `next` recomputes from ledgers + <data>/.drive-solo/.
#
# USAGE
#   bp-drive-next.pl next --scope <spec>
#   bp-drive-next.pl record-order <bp> [<bp> …]
#   bp-drive-next.pl park <blueprint> <reason…>
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
#   park <blueprint> <reason…>
#       Record a blueprint-level park (idempotent) to parks.json and log it. A parked
#       blueprint is settled: never driven, excluded from every pending list.
#
# NEXT-ACTION JSON  (exactly one per `next`)
#   {"action":"need-order","candidates":[…]}          no order yet; session must judge+record
#   {"action":"run-package","blueprint":B,"package":P} drive this package next
#   {"action":"pause","until_epoch":E,"reason":"usage"} timed auto-resume at epoch E
#   {"action":"pause","until_epoch":null,"reason":"token"} TERMINAL relogin park (re-login, re-invoke)
#   {"action":"blueprint-done","blueprint":B,"pending":[…]} B settled; pending = remaining bps to re-eval
#   {"action":"done"}                                  every in-scope blueprint is done-or-parked
#
#   Keep-awake is a director-managed SIDE EFFECT (started when work is runnable or a
#   timed auto-resume is pending; stopped when settled) — never an action.
#
# GOVERNOR VERDICT CONSUMED  (from bp-usage-gate.pl verdict — pkg-02)
#   {"action":"ok"|"pause-usage"|"pause-token"|"unavailable","until_epoch":E|null,"reason":…}
#   ok           → proceed
#   pause-usage  → pause reason=usage, until_epoch=E
#   pause-token  → pause reason=token, until_epoch=null (hard-stop relogin)
#   unavailable  → retry a few times, then degrade-and-proceed (log "governance degraded")
#
# STATE  (<data>/.drive-solo/, all director-owned)
#   order.json      {"order":[…],"recorded_at":<epoch>}
#   parks.json      [{"blueprint":…,"reason":…,"at":<epoch>}, …]
#   announced.json  {"announced":[…]}   blueprints whose blueprint-done already fired
#   keepawake.pid   PID of the wake-lock process (host only; sandbox = no file)
#   run.md          append-only structured run log

package BpDrive;
use strict;
use warnings;
use JSON::PP;
use File::Path qw(make_path);
use File::Basename qw(dirname basename);
use Cwd qw(abs_path);

# MSYS2 path-conversion guard (house rule — EC-7 / Landmine #1): this script may
# spawn powershell / taskkill with ':'-bearing args on a Windows host.
BEGIN { $ENV{MSYS2_ARG_CONV_EXCL} = '*' if $^O =~ /^(MSWin32|cygwin|msys)$/; }

# How many verdict attempts before degrading (spec §2.5, Decision #14).
our $VERDICT_RETRY_MAX = 3;

# Absolute script dir: lets tests `require` from any working dir.
my $DIR = dirname(abs_path(__FILE__));

# ===========================================================================
# PURE DECISION FUNCTIONS (no I/O, no globals, no network — unit-tested in t/17)
# ===========================================================================

# --- terminal status: done|dropped|blocked|parked
# Mirrored from BpOrch::_is_terminal (bp-orchestrator.pl line 66).
sub _is_terminal { my $s = shift // ''; $s =~ /^(done|dropped|blocked|parked)$/ ? 1 : 0 }

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
    return @ready;
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
sub keepawake_should_be_on {
    my ($phase) = @_;
    return ($phase eq 'active' || $phase eq 'pause-pending') ? 1 : 0;
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
        return { action => 'pause', reason => 'token', until_epoch => undef };
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
            push @deps, $d if $d =~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/;
        }
        $dag{$pkg} = \@deps;
    }
    return \%dag;
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

    # parks.json
    my $parks_raw = _read_json_file("$dsdir/parks.json", $dsdir);
    my @parks_list = (ref $parks_raw eq 'ARRAY') ? @$parks_raw : ();
    my %parked = map { $_->{blueprint} => 1 } grep { ref $_ eq 'HASH' && $_->{blueprint} } @parks_list;

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
            };
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
# KEEP-AWAKE ACTUATION (side effect; seam-injectable; never affects action/exit)
# ===========================================================================

sub keepawake_apply {
    my ($phase, $dsdir, $opts) = @_;
    my $spawn  = $opts->{spawn}                // sub {};
    my $killp  = $opts->{kill_pid}             // sub {};
    my $ps_ok  = $opts->{powershell_available} // sub { 0 };
    my $pid_f  = "$dsdir/keepawake.pid";

    if (keepawake_should_be_on($phase)) {
        return unless $ps_ok->();
        # idempotent: skip if already live
        if (-e $pid_f) {
            my $pid = do { my $t = _read_file($pid_f); $t && $t =~ /^(\d+)/ ? $1 : undef };
            return if defined $pid && kill(0, $pid);
        }
        eval { $spawn->($pid_f) };
        if ($@) { _append_run_log($dsdir, "WARN keepawake spawn failed: $@"); }
    } else {
        if (-e $pid_f) {
            my $pid = do { my $t = _read_file($pid_f); $t && $t =~ /^(\d+)/ ? $1 : undef };
            if (defined $pid) {
                eval { $killp->($pid) };
                _append_run_log($dsdir, "WARN keepawake kill failed: $@") if $@;
            }
            unlink $pid_f;
        }
    }
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

    my @candidates = resolve_scope($spec, \@all_bps);

    # Read all state from disk
    make_path($dsdir) unless -d $dsdir;
    my $state = read_state($data, $dsdir, \@candidates);

    my $order     = $state->{order};
    my %parked    = %{ $state->{parked} };
    my %announced = %{ $state->{announced} };
    my %bp_meta   = %{ $state->{bp_meta} };
    my %bp_status = %{ $state->{bp_status} };

    # B2: no order recorded → need-order
    unless (defined $order && @$order) {
        my $action = { action => 'need-order', candidates => \@candidates };
        print _encode_action($action), "\n";
        keepawake_apply('active', $dsdir, $opts);
        return 0;
    }

    # B3: walk recorded order
    for my $bp (@$order) {
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
                        $done_or_parked{$b} = 1 if $b_settled || $b_parked;
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
                _append_run_log($dsdir, "BLUEPRINT-DONE $bp pending=" . join(',', @pending_list));

                my $action = { action => 'blueprint-done', blueprint => $bp, pending => \@pending_list };
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

        if ($mapped->{action} && $mapped->{action} eq 'pause') {
            my $until = $mapped->{until_epoch};
            my $reason = $mapped->{reason};
            my $phase  = ($reason eq 'usage') ? 'pause-pending' : 'settled';
            my $action = { action => 'pause', reason => $reason, until_epoch => $until };
            print _encode_action($action), "\n";
            keepawake_apply($phase, $dsdir, $opts);
            return 0;
        }

        # ok or degraded → find first ready package
        my @ready = ready_packages($meta, $status, []);
        if (@ready) {
            my $pkg    = $ready[0];  # sorted by key (ready_packages uses sort keys)
            my $action = { action => 'run-package', blueprint => $bp, package => $pkg };
            _append_run_log($dsdir, "RUN $bp/$pkg");
            print _encode_action($action), "\n";
            keepawake_apply('active', $dsdir, $opts);
            return 0;
        }

        # No ready packages but also not settled: should not normally happen,
        # but treat as settled-pending (no progressable work right now).
        # Continue to next blueprint.
    }

    # B6: all blueprints in the order are settled+announced (or parked)
    _append_run_log($dsdir, 'DONE');
    print _encode_action({ action => 'done' }), "\n";
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
    _write_json_atomic("$dsdir/order.json", { order => $bps, recorded_at => $now });
    _append_run_log($dsdir, "order recorded: " . join(',', @$bps));
    return 0;
}

# ===========================================================================
# SUBCOMMAND: park
# ===========================================================================

sub _cmd_park {
    my ($bp, $reason, $opts) = @_;
    my $data  = $opts->{data_dir} or die "bp-drive-next: data_dir required\n";
    my $now   = $opts->{now}->();
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir) unless -d $dsdir;

    my $parks_raw = _read_json_file("$dsdir/parks.json");
    my @parks = (ref $parks_raw eq 'ARRAY') ? @$parks_raw : ();

    # Idempotent: check if bp already parked (EC-2)
    my $already = grep { ref $_ eq 'HASH' && ($_->{blueprint} // '') eq $bp } @parks;
    if ($already) {
        # Re-park is structural no-op: do NOT add a second entry, do NOT log to run.md (B8 / EC-2)
        return 0;
    }

    push @parks, { blueprint => $bp, reason => $reason, at => $now };
    _write_json_atomic("$dsdir/parks.json", \@parks);
    _append_run_log($dsdir, "PARK $bp — $reason");
    return 0;
}

# ===========================================================================
# JSON encoding: use canonical, and handle undef as JSON null explicitly
# ===========================================================================

sub _encode_action {
    my ($action) = @_;
    # We need JSON null for until_epoch when undef.
    # JSON::PP->new->canonical handles undef → null correctly.
    return JSON::PP->new->canonical->encode($action);
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
  bp-drive-next.pl park <blueprint> <reason…>
  bp-drive-next.pl --help

SUBCOMMANDS
  next --scope <spec>
      Print exactly ONE next-action JSON (below) to stdout, single line.
      <spec> = one blueprint name | comma/space list of names | "all" (or empty)
      = all audited blueprints. <spec> resolves mechanically to the candidate SET
      and is used ONLY for need-order candidates; once order.json exists it is the
      authoritative scope+order and --scope is ignored.
  record-order <bp> [<bp> …]
      Persist the SESSION-judged blueprint order to order.json. The director never
      invents order — it only persists and serves it.
  park <blueprint> <reason…>
      Record a blueprint-level park (idempotent) to parks.json and log it. A parked
      blueprint is settled: never driven, excluded from every pending list.

NEXT-ACTION JSON  (exactly one per `next`)
  {"action":"need-order","candidates":[…]}          no order yet; session must judge+record
  {"action":"run-package","blueprint":B,"package":P} drive this package next
  {"action":"pause","until_epoch":E,"reason":"usage"} timed auto-resume at epoch E
  {"action":"pause","until_epoch":null,"reason":"token"} TERMINAL relogin park (re-login, re-invoke)
  {"action":"blueprint-done","blueprint":B,"pending":[…]} B settled; pending = remaining bps to re-eval
  {"action":"done"}                                  every in-scope blueprint is done-or-parked

  Keep-awake is a director-managed SIDE EFFECT (started when work is runnable or a
  timed auto-resume is pending; stopped when settled) — never an action.

GOVERNOR VERDICT CONSUMED  (from bp-usage-gate.pl verdict — pkg-02)
  {"action":"ok"|"pause-usage"|"pause-token"|"unavailable","until_epoch":E|null,"reason":…}
  ok           → proceed
  pause-usage  → pause reason=usage, until_epoch=E
  pause-token  → pause reason=token, until_epoch=null (hard-stop relogin)
  unavailable  → retry a few times, then degrade-and-proceed (log "governance degraded")

STATE  (<data>/.drive-solo/, all director-owned)
  order.json      {"order":[…],"recorded_at":<epoch>}
  parks.json      [{"blueprint":…,"reason":…,"at":<epoch>}, …]
  announced.json  {"announced":[…]}   blueprints whose blueprint-done already fired
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
# despite pending work. This mirrors bp-lib.sh's bp_project_root()+bp_data_dir()
# so the perl director and the bash helpers agree on exactly one root.
#
# Priority (identical to bp-lib.sh, plus the injected data_dir opt on top for tests):
#   data_dir opt (--data-dir) > $CCPRAXIS_DATA_DIR
#     > <project root>/.ccpraxis-local-data
#   project root = $BP_PROJECT_ROOT > git toplevel
#     > walk up from cwd for a dir containing .ccpraxis-local-data > cwd

sub _resolve_project_root {
    return $ENV{BP_PROJECT_ROOT}
        if defined $ENV{BP_PROJECT_ROOT} && length $ENV{BP_PROJECT_ROOT};

    # git toplevel — trust only a clean exit and a real directory.
    my $top = `git rev-parse --show-toplevel 2>/dev/null`;
    if ($? == 0 && defined $top) {
        chomp $top;
        return $top if length $top && -d $top;
    }

    # Walk up from cwd for the first ancestor that already holds .ccpraxis-local-data.
    my $d = Cwd::getcwd();
    if (defined $d && length $d) {
        my %seen;
        while (!$seen{$d}++) {
            return $d if -d "$d/.ccpraxis-local-data";
            my $parent = dirname($d);
            last if $parent eq $d;    # reached the filesystem / drive root
            $d = $parent;
        }
    }

    return Cwd::getcwd() // '.';
}

sub _resolve_data_dir {
    my ($opts) = @_;
    return $opts->{data_dir}
        if defined $opts->{data_dir} && length $opts->{data_dir};
    return $ENV{CCPRAXIS_DATA_DIR}
        if defined $ENV{CCPRAXIS_DATA_DIR} && length $ENV{CCPRAXIS_DATA_DIR};
    return _resolve_project_root() . '/.ccpraxis-local-data';
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
            print STDERR "  Resolution order: --data-dir opt > \$CCPRAXIS_DATA_DIR > \$BP_PROJECT_ROOT\n";
            print STDERR "                    > git toplevel > walk-up for .ccpraxis-local-data > cwd.\n";
            print STDERR "  Set CCPRAXIS_DATA_DIR=<project>/.ccpraxis-local-data (or pass --data-dir) and retry.\n";
            return 2;
        }
    }

    my $now_fn = $opts->{now} // sub { time };
    my $verdict_fn = $opts->{verdict} // sub {
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
        spawn    => $opts->{spawn}                // sub { },
        kill_pid => $opts->{kill_pid}             // sub { },
        powershell_available => $opts->{powershell_available} // sub { _ps_available() },
    );

    if ($sub eq 'next') {
        return _cmd_next(\@argv, \%full_opts);
    } elsif ($sub eq 'record-order') {
        return _cmd_record_order(\@argv, \%full_opts);
    } elsif ($sub eq 'park') {
        my $bp     = shift @argv;
        my $reason = join(' ', @argv);
        unless (defined $bp && length $bp) {
            print STDERR "bp-drive-next park: blueprint name required\n";
            return 2;
        }
        return _cmd_park($bp, $reason, \%full_opts);
    } else {
        print STDERR "bp-drive-next: unknown subcommand '$sub'\n";
        print STDERR "usage: bp-drive-next.pl next|record-order|park|--help\n";
        return 2;
    }
}

# Detect whether powershell.exe is resolvable (for keep-awake actuation).
sub _ps_available {
    # Keep-awake actuation is a Windows-only concern; in the Linux sandbox it is a
    # documented no-op (doctrine). Probing powershell.exe off-Windows only spams
    # stderr with "Can't exec \"powershell.exe\": No such file or directory" on every
    # `next` — harmless (eval'd → 0) but misleading. Short-circuit off-Windows.
    return 0 unless $^O =~ /^(MSWin32|msys|cygwin)$/;

    # List-form system() spawns powershell.exe directly (no shell), so there is no
    # /dev/null-vs-NUL redirect hazard (CLAUDE.md house rule) and the intent is explicit.
    # `-Command "exit 0"` prints nothing; ENOENT (not found) -> system() returns -1.
    my $rc = eval { system('powershell.exe', '-NoProfile', '-NonInteractive', '-Command', 'exit 0') };
    return (defined $rc && $rc == 0 && !$@) ? 1 : 0;
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
