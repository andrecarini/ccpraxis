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
#   {"action":"stop","reason":"token-refresh-failed","detail":…} token could not be
#                                                      refreshed; the wake-lock is released and the
#                                                      run ends. NOT a pause: a pause promises a
#                                                      resume, and there is none until a human
#                                                      re-authenticates.
#   {"action":"blueprint-done","blueprint":B,"pending":[…]} B settled; pending = remaining bps to re-eval
#   {"action":"in-flight","blueprint":B,"packages":[…],"running":[…]}
#                                                      nothing dispatchable right now, but B still
#                                                      holds non-terminal packages (typically owned by
#                                                      a concurrent worker). NOT completion: stopping
#                                                      here kills the run mid-package.
#   {"action":"done"}                                  every in-scope blueprint is done-or-parked
#
#   Keep-awake is a director-managed SIDE EFFECT (started when work is runnable or a
#   timed auto-resume is pending; stopped when settled) — never an action.
#
# GOVERNOR VERDICT CONSUMED  (from bp-usage-gate.pl verdict — pkg-02)
#   {"action":"ok"|"pause-usage"|"pause-token"|"unavailable","until_epoch":E|null,"reason":…}
#   ok           → proceed
#   pause-usage  → pause reason=usage, until_epoch=E
#   pause-token  → attempt a refresh (bp-token-keeper). Recovered → proceed;
#                  failed → action=stop, wake-lock released, error logged.
#                  Solo NEVER pauses for token expiry — see _token_recover.
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
my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; abs_path($f) // $f });

# b44: require bp-orchestrator.pl SOLELY to delegate to its one new pure
# function, BpOrch::order_ready (priority-ordering of an already-eligible ready
# set). This is deliberately narrow — the other eight functions this file
# mirrors from BpOrch (see the `# Mirrored from BpOrch::...` comments below)
# are left as faithful copies on purpose (spec b44-execution-priority §3.1);
# t/17-drive-next.t asserts BpDrive's own write_sets_overlap behaviour
# (including its deliberate empty-prefix landmine), so collapsing those
# mirrors into requires would churn an immutable oracle for no gain here.
# Measured safe to require: bp-orchestrator.pl is `package BpOrch;` ending
# `package main; unless (caller) {...} 1;`, requires cleanly in ~0.1s with no
# side effects, and its whole require-tree is core-Perl only (t/06 already
# does this same require).
require "$DIR/bp-orchestrator.pl";
require "$DIR/bp-keepawake.pl";    # the shared wake-lock (also used by the fleet)

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
                priority  => ledger_fm($bpdir, $pkg, 'priority'),
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
    # The seam shape (spawn / kill_pid / powershell_available in %$opts) is
    # preserved verbatim so injected fakes keep working; only the body moved.
    BpKeepAwake::apply($phase, $dsdir, {
        %{ $opts // {} },
        log => sub { _append_run_log($dsdir, $_[0]) },
    });
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
    # gate-drive-loop.sh treats any non-done/pause action as actionable work and
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
    # it is actively dangerous: bp-watchdog.pl branches on the action string and
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
        print STDERR "Each is skipped by candidate discovery, so the scope resolves empty --\n"
                   . "but 'empty' and 'malformed' are not the same thing, and reporting the run\n"
                   . "settled over a half-created blueprint would disarm the watchdog on top of\n"
                   . "a package that may still be running. Finish creating it (blueprint.md), or\n"
                   . "move it aside, then retry.\n";
        return 2;
    }

    if (!@candidates) {
        _append_run_log($dsdir, 'DONE (nothing in scope: no blueprint matches the scope spec)');
        print _encode_action({ action => 'done' }), "\n";
        keepawake_apply('settled', $dsdir, $opts);
        return 0;
    }

    # B2: no order recorded → need-order
    unless (defined $order && @$order) {
        my $action = { action => 'need-order', candidates => \@candidates };
        print _encode_action($action), "\n";
        keepawake_apply('active', $dsdir, $opts);
        return 0;
    }

    # B2a: an order EXISTS but does not cover every in-scope candidate.
    #
    # The walk below iterates `@$order`, so a candidate absent from it is never
    # looked at -- and the walk then falls through to 'done', which asserts
    # "every in-scope blueprint is done-or-parked". That assertion is false, and
    # it is believed by the two mechanisms named at the in-flight branch below:
    # gate-drive-loop.sh allows the turn to end, and bp-watchdog.pl short-circuits
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

    # Blueprints that are NOT settled but have nothing dispatchable right now.
    # Collected rather than swallowed: emitting 'done' for these is the bug
    # documented at the in-flight branch below.
    my @in_flight;

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
        #   * gate-drive-loop.sh, the Stop hook that keeps an unattended driver
        #     from ending a turn with nothing scheduled to continue the run,
        #     treats 'done' as "run settled" and allows the stop. So the run
        #     dies silently mid-package, looking finished -- the exact failure
        #     that hook was written to prevent.
        #   * bp-watchdog.pl short-circuits to VERDICT: SETTLED on 'done',
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
        print _encode_action({
            action    => 'in-flight',
            blueprint => $f->{blueprint},
            packages  => $f->{packages},
            running   => $f->{running},
        }), "\n";
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
    # Archiving is enabled HERE and nowhere else in the automatic path. It is a
    # directory move, so it must only run where nothing holds the directory —
    # true at this point and not true inside the orchestrator (which lives in it)
    # or during a status read (which may be observing a run about to relaunch).
    # The director's own state lives in <data>/.drive-solo/, outside every
    # blueprint, so moving one cannot disturb it.
    #
    # A blueprint that is merely settled — parked or blocked awaiting a human —
    # is NOT all-delivered and is therefore left exactly where it is. bp-lifecycle
    # enforces that; the drive loop does not need to re-decide it.
    #
    # Best-effort: the run is over and reported done either way. A reconciliation
    # failure must not manufacture a failed drive.
    {
        my $lifecycle = "$DIR/bp-lifecycle.pl";
        if (-f $lifecycle) {
            my $rc = eval {
                system($^X, $lifecycle, 'reconcile', '--all',
                       '--data-dir', $data, '--archive', '--quiet');
            };
            _append_run_log($dsdir, 'LIFECYCLE-RECONCILE '
                . ((!$@ && defined $rc && $rc == 0) ? 'ok' : 'failed (non-fatal)'));
        }
    }

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
            print STDERR "Each argument must be a blueprint directory name under\n"
                       . "  $bpbase/\n"
                       . "(record-order takes bare names, no flags -- a flag recorded as a\n"
                       . "blueprint name reports itself settled and is never driven).\n";
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
        my $parks  = _read_json_file("$dsdir/parks.json", $dsdir);
        my %parked = map  { $_->{blueprint} => 1 }
                     grep { ref $_ eq 'HASH' && $_->{blueprint} }
                     (ref $parks eq 'ARRAY' ? @$parks : ());

        my @dropped;
        if (-d $bpbase && opendir(my $dh, $bpbase)) {
            my @dirs = sort grep { $_ ne '.' && $_ ne '..' && $_ ne '_archive'
                                   && -f "$bpbase/$_/blueprint.md" } readdir $dh;
            closedir $dh;
            for my $bp (@dirs) {
                next if $given{$bp} || $parked{$bp};
                my $dag = parse_dag(_read_file("$bpbase/$bp/blueprint.md"));
                my @live = grep { !_is_terminal(ledger_fm("$bpbase/$bp", $_, 'status') // 'pending') }
                           keys %$dag;
                push @dropped, "$bp (" . scalar(@live) . ' non-terminal package(s))' if @live;
            }
        }
        if (@dropped) {
            print STDERR "bp-drive-next record-order: refusing an order that omits blueprint(s)\n"
                       . "still holding non-terminal packages -- the `next` walk iterates the\n"
                       . "recorded order, so an omitted blueprint is never driven and the run\n"
                       . "reports 'done' over work it never looked at:\n";
            print STDERR "  - $_\n" for @dropped;
            print STDERR "Include them in the order, or exclude them deliberately with:\n"
                       . "  bp-drive-next.pl park <blueprint> <reason...>\n";
            return 2;
        }
    }

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
  {"action":"stop","reason":"token-refresh-failed","detail":…} token could not be
                                                     refreshed; the wake-lock is released and the
                                                     run ends. NOT a pause: a pause promises a
                                                     resume, and there is none until a human
                                                     re-authenticates.
  {"action":"blueprint-done","blueprint":B,"pending":[…]} B settled; pending = remaining bps to re-eval
  {"action":"in-flight","blueprint":B,"packages":[…],"running":[…]}
                                                     nothing dispatchable right now, but B still
                                                     holds non-terminal packages (typically owned by
                                                     a concurrent worker). NOT completion: stopping
                                                     here kills the run mid-package.
  {"action":"done"}                                  every in-scope blueprint is done-or-parked

  Keep-awake is a director-managed SIDE EFFECT (started when work is runnable or a
  timed auto-resume is pending; stopped when settled) — never an action.

GOVERNOR VERDICT CONSUMED  (from bp-usage-gate.pl verdict — pkg-02)
  {"action":"ok"|"pause-usage"|"pause-token"|"unavailable","until_epoch":E|null,"reason":…}
  ok           → proceed
  pause-usage  → pause reason=usage, until_epoch=E
  pause-token  → attempt a refresh (bp-token-keeper). Recovered → proceed;
                 failed → action=stop, wake-lock released, error logged.
                 Solo NEVER pauses for token expiry — see _token_recover.
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
        # TEST / DIAGNOSTIC SEAM, honoured only for well-formed JSON carrying an
        # 'action'. The production path below shells out to bp-usage-gate.pl,
        # which reads the host's REAL OAuth state -- so every consumer of the
        # director inherits that state, including gate-drive-loop.sh and any
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
