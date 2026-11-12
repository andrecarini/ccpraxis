#!/usr/bin/env perl
# bp-resolve.pl — e03-autonomous-resolution: the deterministic apply-step for
# bp-escalation-resolver's verdicts. Library + CLI, mirroring
# bp-answer-escalation's own pure-function/CLI split (BpAnswer -> BpResolve).
#
# Governing rule (spec e03-autonomous-resolution-spec.md, stated once so it is
# not diluted anywhere below): a run stops for the operator ONLY when there is
# nothing else it can do. Every gate below is asymmetric ON PURPOSE --
# uncertainty, malformed input, and anything outside the four narrow action
# verbs fall toward the operator, never toward guessing. Do not "optimize"
# this asymmetry away.
#
# Provenance (DC2): two distinct on-disk records, never conflated with each
# other or with bp-wait-for-escalation.pl's UNRELATED classify_decision /
# autonomous_decision_record pair (b24-reporter-autonomy) --
#   (a) in-place tag on the STILL-QUEUED runs/needs-you/<id>.json, when the
#       resolver's verdict lands on category product/operator-action (including
#       every unclassified record that falls back there);
#   (b) a durable archive at runs/resolved-escalations/<id>.json, written
#       BEFORE any resolver-triggered unlink of the queue file -- a FAILED
#       archive write must ABORT the deletion (see apply_verdict below).
#
# _block_and_queue (bp-orchestrator.pl) gains NO argument from this package
# (spec §2.2, AC-BQ) -- this script never calls it. It only reads/rewrites
# runs/needs-you/*.json and files its one new kind (chronic-scoping) through
# the already-generic BpOrch::queue_needs_you().

package BpResolve;
use strict;
use warnings;
use Fcntl qw(:flock);
# @BpOrch::CATEGORIES is read exactly once from this file -- perl's "used
# only once" heuristic would otherwise print a warning to STDERR on every
# load, and the CLI below (unless (caller)) is parsed as stdout+stderr JSON
# by its own callers (bp-orchestrator.pl's tick loop), same discipline as
# bp-orchestrator.pl's own known_kinds_list() header comment explains.
no warnings 'once';
use JSON::PP;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use File::Spec ();

my $SELF_DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; abs_path($f) // $f });
require "$SELF_DIR/bp-orchestrator.pl";   # BpOrch:: -- @CATEGORIES, queue_needs_you, _read_json, _log, ...
require "$SELF_DIR/bp-write-guard.pl";    # BpWrite::guarded_write -- used only by _author_ledger

# The bounded action verbs this package may ever dispatch. 'accept'/'drop'
# are NEVER in this set -- that bright line is enforced unconditionally in
# verdict_in_bounds below, checked before anything else. narrow-test-paths
# (bug 20261112-214934-365f) only ever shrinks the oracle boundary.
my @VALID_ACTIONS = ('relaunch', 'widen-write-set', 'narrow-test-paths', 'edit-depends-on', 'author-ledger');
my %VALID_ACTION  = map { $_ => 1 } @VALID_ACTIONS;

# The four categories the resolver may ACT on (never product/operator-action,
# never unclassified as a terminal value -- e01 §2.2/§2.3, restated here as
# the closed set this module is allowed to mutate on).
my @RESOLVER_OWNED = qw(conformance oracle scoping implementation);
my %RESOLVER_OWNED = map { $_ => 1 } @RESOLVER_OWNED;

# The two the resolver may never DECIDE, only confirm (the 'tag-only' verdict).
# Named once rather than open-coded as `$cat eq 'product' || $cat eq '...'` at
# each gate: that idiom is how the rename would have been applied to two of the
# three sites and missed the third.
my @OPERATOR_OWNED = qw(product operator-action);
my %OPERATOR_OWNED = map { $_ => 1 } @OPERATOR_OWNED;
sub _operator_owned { my ($c) = @_; return defined $c && $OPERATOR_OWNED{$c} ? 1 : 0 }

# _has_visible_text($s) -> 1|0 -- PURE-ish (never dies, never mutates $s: it
# only ever reads a COPY). redteam-1.md L3: true only if, after decoding real
# UTF-8 bytes (undoing the JSON::PP flag quirk -- see BpOrch::_json_bytes'
# header comment) and trimming every Unicode whitespace character PLUS the
# zero-width/BOM format characters that Unicode does not classify as
# whitespace but no renderer ever shows, at least one character remains.
sub _has_visible_text {
    my ($s) = @_;
    return 0 unless defined $s && !ref $s;
    require Encode;
    my $bytes = $s;
    utf8::downgrade($bytes, 1);
    my $decoded = eval { Encode::decode('UTF-8', $bytes, Encode::FB_DEFAULT()) };
    $decoded = $bytes unless defined $decoded;
    $decoded =~ s/[\s\x{200B}-\x{200D}\x{2060}\x{FEFF}]+//g;
    return length($decoded) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# verdict_shape_ok(\%verdict) -> (1|0, $why)   -- PURE, no I/O.
# Required keys present per category:
#   product|operator-action  -> category, confidence, evidence defined;
#                            action MUST be absent/undef (a shape violation
#                            otherwise -- see confidence_gate's own comment).
#   conformance|oracle|scoping|implementation
#                         -> category, action, confidence, evidence, rationale
#                            all defined.
#   anything else (incl. 'unclassified' as a FINAL verdict value, or an
#   unrecognized category string) -> not shape_ok; e01 §2.1 never treats
#   'unclassified' as a legitimate terminal answer.
# Content (emptiness, confidence value) is judged elsewhere (confidence_gate)
# -- this only checks presence, so a low-confidence or empty-evidence
# product/operator-action verdict is still shape_ok (V10's own pinned behavior).
# ---------------------------------------------------------------------------
sub verdict_shape_ok {
    my ($v) = @_;
    return (0, 'verdict must be a hashref') unless ref $v eq 'HASH';
    # Canonicalise before every comparison below: a verdict may name the legacy
    # 'operational' spelling (an older agent doc, a replayed verdict file), and
    # it must be judged by what it means. BpOrch owns the alias map.
    my $cat = BpOrch::canonical_category($v->{category});
    return (0, 'missing category') unless defined $cat && length $cat;

    if (_operator_owned($cat)) {
        return (0, "category=$cat verdict must not carry an action -- product/operator-action are never actable")
            if defined $v->{action};
        for my $k (qw(confidence evidence)) {
            return (0, "missing required key '$k' for category=$cat") unless defined $v->{$k};
        }
        # e06-fleet-inbox-bridge §2.6: product_question is REQUIRED for the
        # operator-owned pair -- the inbox item's title/body (and, before
        # that, this gate) depend on the resolver having actually phrased a
        # product-level question rather than merely naming a category.
        # redteam-1.md L3: `/\S/` alone accepts invisible-only Unicode (a
        # lone NBSP or ZWSP) because \S only tests for "not a whitespace
        # BYTE" against a JSON::PP-decoded string that is still raw bytes
        # under a spurious utf8 flag (see BpOrch::_json_bytes). Decode for
        # real, trim Unicode whitespace AND the zero-width/BOM format
        # characters that are not whitespace but are still invisible, and
        # require something remains.
        my $pq = $v->{product_question};
        return (0, "missing required key 'product_question' for category=$cat")
            unless defined $pq && !ref($pq) && _has_visible_text($pq);
        return (1, undef);
    }
    if ($RESOLVER_OWNED{$cat}) {
        for my $k (qw(action confidence evidence rationale)) {
            return (0, "missing required key '$k' for category=$cat") unless defined $v->{$k};
        }
        return (1, undef);
    }
    return (0, "category '" . $cat . "' is not a recognized terminal verdict category "
             . "(must be one of product/operator-action/conformance/oracle/scoping/implementation -- "
             . "'unclassified' is never a legitimate FINAL verdict, e01 §2.1)");
}

# ---------------------------------------------------------------------------
# verdict_in_bounds(\%verdict) -> (1|0, $why)   -- PURE, no I/O.
# The accept/drop bright line is checked FIRST, unconditionally -- e01 §2.4's
# hard refusal, regardless of what category/confidence would otherwise allow.
# ---------------------------------------------------------------------------
sub verdict_in_bounds {
    my ($v) = @_;
    return (0, 'verdict must be a hashref') unless ref $v eq 'HASH';
    my $act = $v->{action};
    if (defined $act && ($act eq 'accept' || $act eq 'drop')) {
        return (0, "action='$act' is never permitted -- the resolver may never accept or drop an escalation");
    }
    # Canonicalised, like the other two gates. Without this a legacy
    # 'operational' verdict passes verdict_shape_ok (which canonicalises) and
    # then fails HERE on the membership check, because @BpOrch::CATEGORIES no
    # longer contains the old spelling -- a verdict accepted by one gate and
    # rejected by the next, for a difference neither gate is about.
    my $cat = BpOrch::canonical_category($v->{category}) // '';
    return (0, "category '$cat' is not one of the closed 7-category set")
        unless grep { $_ eq $cat } @BpOrch::CATEGORIES;
    if ($RESOLVER_OWNED{$cat}) {
        return (0, 'a resolver-owned category requires an action') unless defined $act;
        return (0, "action '$act' is outside {" . join(',', @VALID_ACTIONS) . "}")
            unless $VALID_ACTION{$act};
    }
    return (1, undef);
}

# ---------------------------------------------------------------------------
# confidence_gate(\%verdict) -> 'act' | 'tag-only' | 'refuse'   -- PURE.
# 'act'      iff shape_ok && in_bounds && category is resolver-owned &&
#            confidence eq 'high' && evidence is non-empty.
# 'tag-only' iff shape_ok && category in {product, operator-action}. An 'action'
#            key present on such a verdict is itself a shape violation
#            (verdict_shape_ok already refused it) and this branch never
#            fires for it -- it falls through to 'refuse' instead, so a
#            category the resolver may not decide is never silently allowed
#            to also carry a mutation.
# 'refuse'   otherwise -- INCLUDING a resolver-owned category paired with
#            confidence 'low' or missing/empty evidence: e01 §2.4 requires
#            that combination to instead be FILED as category=product/
#            confidence=low by the agent itself; an agent that emits
#            resolver-owned+low anyway is a CONTRACT VIOLATION, treated
#            exactly like a crash -- left queued untouched, logged.
# ---------------------------------------------------------------------------
sub confidence_gate {
    my ($v) = @_;
    return 'refuse' unless ref $v eq 'HASH';
    my ($shape_ok) = verdict_shape_ok($v);
    return 'refuse' unless $shape_ok;
    my $cat = BpOrch::canonical_category($v->{category}) // '';
    return 'tag-only' if _operator_owned($cat);
    my ($bounds_ok) = verdict_in_bounds($v);
    if ($bounds_ok && $RESOLVER_OWNED{$cat}
        && defined $v->{confidence} && $v->{confidence} eq 'high'
        && defined $v->{evidence}   && length $v->{evidence}) {
        return 'act';
    }
    return 'refuse';
}

# ---------------------------------------------------------------------------
# chronic_scoping_bump($count_before) -> ($count_after, $fires_escalation)
# Pure counter step (e01 §2.5's stated threshold, exactly): fires iff
# $count_after > 2. Persistence (where the count lives on disk) is handled by
# the caller (_bump_chronic_scoping_counter below) -- this sub never touches
# disk.
# ---------------------------------------------------------------------------
sub chronic_scoping_bump {
    my ($count_before) = @_;
    my $after = (defined $count_before ? $count_before : 0) + 1;
    my $fire  = ($after > 2) ? 1 : 0;
    return ($after, $fire);
}

# --- small local helpers (deliberately not reusing BpOrch's private ones,
# which are written for the orchestrator's own atomic conventions but are not
# exported for cross-file reuse beyond the fully-qualified read helpers).
sub _atomic_write_json {
    my ($path, $data) = @_;
    (my $dir = $path) =~ s{[\\/][^\\/]+$}{};
    unless (-d $dir) {
        eval { require File::Path; File::Path::make_path($dir); 1 };
        return 0 unless -d $dir;
    }
    my $tmp = "$path.tmp.$$";
    my $ok = eval {
        open my $fh, '>', $tmp or die "open: $!";
        print $fh JSON::PP->new->canonical->pretty->encode($data) or die "print: $!";
        close $fh or die "close: $!";
        rename($tmp, $path) or die "rename: $!";
        1;
    };
    unless ($ok) { unlink $tmp; return 0; }
    return 1;
}

sub _rlog {
    my ($log, $type, $fields) = @_;
    eval { BpOrch::_log($log, $type, $fields) };
    return;
}

# fixbatch step7 / CRITICAL + HIGH, one root cause: apply_verdict used to act
# on the CALLER-SUPPLIED $rec snapshot with no re-read at all, at any point,
# under any lock, before committing. The resolver judge's own wall-clock
# budget is up to 1800s (BP_JUDGE_TIMEOUT_SECS) -- easily enough time for an
# operator to independently answer the same decision via
# bp-answer-escalation while the judge is still thinking. Per spec §2.1b,
# the operator's own answer deletes runs/needs-you/<id>.json with no archive
# entry -- THAT deletion is itself the record of what happened. Committing
# the stale snapshot afterward silently UNDID the operator's own action
# (tag-only: resurrected the deleted file, resolver-tagged) or FORGED a
# resolved-escalations archive entry claiming the resolver decided an id the
# operator had already disposed of (act).
#
# This is the a01 re-read-under-lock convention (package a01,
# BpWrite::guarded_write), applied here rather than reinvented: lock ->
# re-read the queue record -> compare to the snapshot the caller was handed
# -> if it is GONE or has CHANGED, ABORT before any write. An operator's
# disposal must win every race. bp-answer-escalation's own final unlink
# (line ~682) does not itself take this lock -- that file is outside this
# package's write set -- so this narrows the staleness window from the
# resolver's full ~1800s wall-clock budget down to the few milliseconds
# between this re-read and the commit that follows it in the SAME locked
# section, rather than claiming to close the cross-process race completely.
sub _same_queued_record {
    my ($a, $b) = @_;
    return 0 unless ref $a eq 'HASH' && ref $b eq 'HASH';
    my $j = JSON::PP->new->canonical;
    my $ea = eval { $j->encode($a) };
    my $eb = eval { $j->encode($b) };
    return (defined $ea && defined $eb && $ea eq $eb) ? 1 : 0;
}

# Runs $code->() under an exclusive lock on "$qpath.lock" (BpWrite's own
# lock-path convention, so this serialises against anything else that took
# that same lock). Returns whatever $code->() returns; on a lock-open/
# lock-timeout failure returns (undef, 'lock-error') instead of running
# $code at all -- callers must treat that as "could not prove freshness",
# never as "proven fresh".
sub _with_qpath_lock {
    my ($qpath, $code) = @_;
    my $lock_p = "$qpath.lock";
    open(my $lk, '>', $lock_p) or return (undef, 'lock-open-failed');
    my $timeout  = 10;
    my $deadline = time + $timeout;
    until (flock($lk, LOCK_EX | LOCK_NB)) {
        if (time >= $deadline) { close $lk; return (undef, 'lock-timeout'); }
        select(undef, undef, undef, 0.05);
    }
    my @r = eval { $code->() };
    my $err = $@;
    flock($lk, LOCK_UN);
    close $lk;
    return (undef, "internal error: $err") if $err;
    return @r;
}

# list-form system() with the child's stdout/stderr redirected around the
# call -- the same discipline bp-answer-escalation's own
# update_next_action_with_note already uses, for the same reason: a caller of
# THIS module (the orchestrator's tick loop, or the CLI below) may itself be
# parsing stdout as JSON, and a stray line from a shelled-out script must
# never corrupt that.
sub _run_quiet {
    my (@cmd) = @_;
    my $devnull = File::Spec->devnull;
    my ($so, $se);
    open($so, '>&', \*STDOUT) or return 1;
    open($se, '>&', \*STDERR) or return 1;
    unless (open(STDOUT, '>', $devnull)) { open(STDOUT, '>&', $so); return 1; }
    unless (open(STDERR, '>', $devnull)) { open(STDOUT, '>&', $so); open(STDERR, '>&', $se); return 1; }
    my $rc = system(@cmd);
    open(STDOUT, '>&', $so); open(STDERR, '>&', $se);
    close $so; close $se;
    return 0 if $rc == 0;
    my $ec = $rc >> 8;
    return $ec || 1;
}

# _relaunch_already_holds($bpdir, $pkg) -> reason string | undef.
# 'pending' when the ledger already reads pending (what a relaunch writes);
# 'coordinator-live' when runs/<pkg>.pid names a live process. This script
# runs beside the orchestrator in the same pid namespace (the sandbox), so a
# kill-0 probe on that pid is meaningful here. undef when neither holds, or
# when the ledger cannot be read: a relaunch then proceeds as before.
sub _relaunch_already_holds {
    my ($bpdir, $pkg) = @_;
    return undef unless defined $bpdir && length $bpdir;
    if (open(my $fh, '<', "$bpdir/packages/$pkg.md")) {
        my ($dashes, $status) = (0, undef);
        while (my $line = <$fh>) {
            if ($line =~ /\A-{3}\s*\z/) { last if ++$dashes == 2; next; }
            if ($dashes == 1 && $line =~ /\Astatus:\s*([A-Za-z-]+)/) { $status = $1; last; }
        }
        close $fh;
        return 'pending' if defined $status && $status eq 'pending';
    }
    if (open(my $pf, '<', "$bpdir/runs/$pkg.pid")) {
        my $pid = <$pf>;
        close $pf;
        if (defined $pid && $pid =~ /\A\s*([1-9]\d{0,9})\s*\z/) {
            return 'coordinator-live' if kill(0, $1);
        }
    }
    return undef;
}

# _requeue_after_widen(\%ctx, \%rec, $id) -> 1 requeued | 0 left alone.
#
# Bug 20261112-120628-9d26. A coordinator parks a package `blocked` to ask for a
# write_set widening, and the widening was all a widen verdict applied: the
# ledger stayed `blocked` with nothing queued, so the next tick's orphan
# reconciler filed it again, and a second (often a third) paid resolver judge
# answered `relaunch` before the package moved. Seen four times on 2026-11-12
# (acxpraxis-step-2 package 15, Decisions 36, 37, 39 and the sim-exempt files).
# The widening WAS the answer the park asked for, so the package goes back to
# `pending` with its attempt counter reset, as a relaunch would leave it; the
# orchestrator's watchdog relaunches it next tick.
#
# Left alone (0): the ledger is not blocked/parked, the coordinator is still
# alive (the setter's own gate refuses then; that coordinator reads its widened
# write_set itself), or any write fails -- the orphan reconciler is still there
# behind this, so a failure costs a judge, never a stall.
sub _requeue_after_widen {
    my ($ctx, $rec, $id, $what) = @_;
    $what = 'widen' unless defined $what && $what =~ /\A[a-z]+\z/;
    my $pkg = ref $rec eq 'HASH' ? $rec->{package} : undef;
    return 0 unless defined $pkg && $pkg =~ /\A[A-Za-z0-9._-]+\z/;
    my ($bpdir, $runs) = ($ctx->{bpdir}, $ctx->{runs});
    return 0 unless defined $bpdir && defined $runs;
    return 0 if defined _relaunch_already_holds($bpdir, $pkg);
    my $txt = BpOrch::_read_file("$bpdir/packages/$pkg.md");
    return 0 unless defined $txt && $txt =~ /\A---\s*\n(.*?)\n---/s;
    return 0 unless $1 =~ /^status:\s*(?:blocked|parked)\s*$/m;
    my $ok = eval {
        BpOrch::_set_ledger_status($bpdir, $pkg, 'pending', { runs => $runs, log => $ctx->{log} })
    };
    return 0 unless $ok;
    eval { BpOrch::update_registry_pkg($runs, $pkg, { attempt => 0 }) };
    _rlog($ctx->{log}, "escalation_resolve_${what}_requeued", { decision => $id, package => $pkg })
        if $ctx->{log};
    return 1;
}

# _narrow_test_paths(\%verdict, \%rec, $id, \%ctx) -> (1, undef) applied |
# (0, undef) malformed verdict (the resolver's to redo) | (0, $why) refused,
# for the operator.
#
# Bug 20261112-214934-365f. The commonest park in acxpraxis-step-2 (ten
# packages, Decisions 20-30 and 43): a ledger's test_paths names a whole source
# directory, the write guard then classifies every file in it as TEST, and the
# implementer cannot write the code its scope requires. The coordinator cannot
# re-scope its own oracle, and until now the resolver could only `relaunch`,
# which changes nothing, so the package parked again.
#
# The verdict carries `test_paths` (a list, or one colon-separated string) and
# a required `decision`. Every new path must lie inside the CURRENT test_paths
# (equal to an entry, or under an entry ending in '/'): this only ever shrinks
# the oracle boundary. Moving it anywhere else is a different question and goes
# to the operator. Applied as two typed calls, the way widen-with-decision is:
# bp-blueprint.pl add-decision (decided by agent, the new paths named
# verbatim), then bp-ledger.pl set-test-paths --decision N.
sub _narrow_test_paths {
    my ($verdict, $rec, $id, $ctx) = @_;
    my $bpdir = $ctx->{bpdir};
    my $pkg   = ref $rec eq 'HASH' ? $rec->{package} : undef;
    return (0, undef) unless defined $pkg && $pkg =~ /\A[A-Za-z0-9._-]+\z/;
    my $dtext = $verdict->{decision};
    return (0, undef) unless defined $dtext && !ref $dtext && _has_visible_text($dtext);
    $dtext =~ s/\s+/ /g;
    $dtext =~ s/\A | \z//g;
    return (0, undef) if $dtext =~ /\|/ || index($dtext, 'depends_on') >= 0;

    my $raw = $verdict->{test_paths};
    my @new = ref $raw eq 'ARRAY' ? @$raw : (defined $raw && !ref $raw ? split(/:/, $raw) : ());
    @new = grep { length } map { my $p = defined $_ && !ref $_ ? $_ : ''; $p =~ s/\A\s+|\s+\z//g; $p } @new;
    return (0, undef) unless @new;
    my %seen;
    @new = grep { !$seen{$_}++ } @new;
    for my $p (@new) {
        return (0, undef) if $p =~ m{\A(?:/|[A-Za-z]:(?:[\\/]|\z))}
                          || $p =~ /[|\r\n:`]/
                          || $p =~ m{(?:\A|/)\.\.(?:/|\z)}
                          || $p =~ m{\A(?:\*+|\*\*/\*|\.|\./)\z};
    }

    my $ledger = "$bpdir/packages/$pkg.md";
    return (0, "packages/$pkg.md does not exist, so there are no test_paths to narrow") unless -f $ledger;
    my $ltxt = BpOrch::_read_file($ledger);
    my ($fm) = defined $ltxt ? $ltxt =~ /\A---\s*\n(.*?)\n---/s : ();
    my ($old_raw) = defined $fm ? $fm =~ /^test_paths:[ \t]*(.*?)[ \t]*$/m : ();
    my @old = grep { length } split /:/, ($old_raw // '');
    return (0, "${pkg}'s ledger has no test_paths to narrow") unless @old;
    my @outside = grep {
        my $p = $_;
        !grep { $p eq $_ || (substr($_, -1) eq '/' && index($p, $_) == 0) } @old;
    } @new;
    return (0, "narrow-test-paths may only shrink ${pkg}'s test_paths (" . join(':', @old)
             . "), and these lie outside it: " . join(', ', @outside)
             . ". Moving the oracle boundary elsewhere is a question for the operator.") if @outside;
    my %old = map { $_ => 1 } @old;
    return (0, undef) if @new == @old && !grep { !$old{$_} } @new;   # no change: a malformed verdict

    my $bpmd = "$bpdir/blueprint.md";
    my $txt  = BpOrch::_read_file($bpmd);
    return (0, 'cannot read blueprint.md to record the Decision') unless defined $txt;
    my $did = _next_decision_id($txt);
    return (0, "blueprint.md has no Decisions table to record the narrowing of ${pkg}'s test_paths in; "
             . "narrow them by hand with bp-ledger.pl set-test-paths once a Decision names the paths")
        unless defined $did;

    my $row = "$dtext (bp-escalation-resolver, escalation $id: narrows $pkg test_paths to "
            . join(', ', map { "`$_`" } @new) . ')';
    my ($rc, $err) = _run_capture($^X, "$SELF_DIR/bp-blueprint.pl", 'add-decision',
        '--file', $bpmd, '--id', $did, '--text', $row, '--decided', 'agent');
    return (0, "recording Decision $did in blueprint.md was refused (exit $rc): $err; nothing was changed")
        if $rc;
    local $ENV{BP_LEDGER_LOCK_TIMEOUT} = $ENV{BP_LEDGER_LOCK_TIMEOUT} // 10;
    ($rc, $err) = _run_capture($^X, "$SELF_DIR/bp-ledger.pl", 'set-test-paths',
        '--ledger', $ledger, '--decision', $did, map { ('--path', $_) } @new);
    return (0, "Decision $did was recorded in blueprint.md, but narrowing ${pkg}'s test_paths was refused "
             . "(exit $rc): $err") if $rc;
    _rlog($ctx->{log}, 'escalation_resolve_narrowed_test_paths',
        { decision => $id, package => $pkg, test_paths => \@new, blueprint_decision => $did }) if $ctx->{log};
    return (1, undef);
}

# ---------------------------------------------------------------------------
# _dispatch_action(\%verdict, \%rec, $id, \%ctx) -> exit-code-shaped integer
# (0 == succeeded). Reaches every one of the four bounded actions WITHOUT
# editing bp-answer-escalation or bp-blueprint.pl -- invoking their existing,
# already-shipped CLI surfaces (spec §2.3), the same reuse pattern
# bp-answer-escalation already applies to bp-ledger.pl.
# ---------------------------------------------------------------------------
sub _dispatch_action {
    my ($verdict, $rec, $id, $ctx) = @_;
    my $action    = $verdict->{action} // '';
    my $bp        = $ctx->{bp};
    my $bpdir     = $ctx->{bpdir};
    my $rationale = $verdict->{rationale} // '';

    if ($action eq 'relaunch') {
        # Already relaunched: a duplicate escalation for the same stop (the
        # orchestrator re-filed an orphan escalation while the first was with
        # the resolver, 2026-10-22) must settle, not retry every tick. A live
        # coordinator means a relaunch would kill working code, and a pending
        # ledger is exactly what a relaunch produces; either way the desired
        # state already holds.
        my $pkg = ref $rec eq 'HASH' ? $rec->{package} : undef;
        if (defined $pkg && $pkg =~ /\A[A-Za-z0-9._-]+\z/) {
            my $why = _relaunch_already_holds($bpdir, $pkg);
            if (defined $why) {
                _rlog($ctx->{log}, 'escalation_resolve_relaunch_moot', { decision => $id, package => $pkg, why => $why })
                    if $ctx->{log};
                return 0;
            }
        }
        # --answered-by: this note is the resolver's own guidance, and the ledger must
        # say so. Written as a human's answer, the next resolver read it as an operator
        # ruling and stopped routing product questions to the operator (bug
        # 20261112-132220-5b54).
        return _run_quiet($^X, "$SELF_DIR/bp-answer-escalation.pl", $bp,
            '--decision', $id, '--action', 'relaunch', '--note', $rationale,
            '--answered-by', 'escalation-resolver', '--bp-dir', $bpdir);
    }
    if ($action eq 'widen-write-set') {
        # fixbatch step7 / MEDIUM (red-team) + SHOULD-FIX (reviewer), one root
        # cause found twice independently: this used to fall back to
        # $verdict->{evidence}, but the agent's own output contract documents
        # 'evidence' as a PROSE CITATION ("file:line, ledger section, or
        # Decisions row" -- bp-escalation-resolver.md), and
        # bp-answer-escalation's --widen-write-set handler unconditionally
        # REJECTS any value containing a colon. A 'file:line' citation --
        # exactly the format the agent's own prompt suggests first -- made
        # this fail EVERY TIME for a fully compliant agent, with no forward
        # progress (the decision just loops back through resolver dispatch).
        # Fix: a DEDICATED, validated 'path' key (now documented in the
        # agent's output contract), never a silent repurposing of 'evidence'.
        # A missing/blank/colon-bearing path is a clean refusal, not a
        # fallback to the wrong field.
        my $path = $verdict->{path};
        return 1 unless defined $path && !ref $path;
        $path =~ s/^\s+|\s+$//g;
        return 1 unless length $path;
        return 1 if $path =~ /:/;   # same guard bp-answer-escalation enforces -- refuse here, don't shell out to fail there
        # bug 20261105-055544-2c28: a widening the resolver wants RECORDED as a
        # blueprint Decision (with its reason, e.g. an exemption granted in the
        # same breath) goes through the Decision-gated typed path instead.
        if (defined $verdict->{decision}) {
            my ($ok, $why) = _widen_with_decision($verdict, $rec, $id, $ctx, $path);
            if ($ok) { _requeue_after_widen($ctx, $rec, $id); return 0; }
            $ctx->{needs_human} = $why if defined $why;
            return 1;
        }
        my $wrc = _run_quiet($^X, "$SELF_DIR/bp-answer-escalation.pl", $bp,
            '--decision', $id, '--widen-write-set', $path, '--bp-dir', $bpdir);
        _requeue_after_widen($ctx, $rec, $id) if $wrc == 0;
        return $wrc;
    }
    if ($action eq 'narrow-test-paths') {
        my ($ok, $why) = _narrow_test_paths($verdict, $rec, $id, $ctx);
        if ($ok) { _requeue_after_widen($ctx, $rec, $id, 'narrow'); return 0; }
        $ctx->{needs_human} = $why if defined $why;
        return 1;
    }
    if ($action eq 'edit-depends-on') {
        my $deps = $verdict->{deps} // $verdict->{depends_on} // '';
        $deps =~ s/^\s+|\s+$//g;
        return 1 unless length $deps;
        my $blueprint_md = "$bpdir/blueprint.md";
        return 1 unless -f $blueprint_md;
        return _run_quiet($^X, "$SELF_DIR/bp-blueprint.pl", 'set-deps',
            '--file', $blueprint_md, '--pkg', $rec->{package}, '--deps', $deps);
    }
    if ($action eq 'author-ledger') {
        # A refusal here is never transient: the blueprint lacks what a ledger
        # needs, and re-running the resolver cannot add it. The reason goes back
        # through $ctx so apply_verdict can hand the record to a human instead of
        # leaving it queued for the resolver to pick the same action again.
        my ($ok, $why) = _author_ledger($rec->{package}, $ctx);
        return 0 if $ok;
        $ctx->{needs_human} = $why;
        return 1;
    }
    # Unreachable in practice -- verdict_in_bounds already refused anything
    # else before apply_verdict ever dispatches.
    return 1;
}

sub _iso_now {
    my @t = gmtime(time);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# ---------------------------------------------------------------------------
# widen-write-set WITH a decision (bug 20261105-055544-2c28).
#
# What the resolver wanted in that bug was "record a Decision and widen the
# write set"; the vocabulary had no such action, so it reached for the wrong
# one. A widen-write-set verdict may now carry `decision` (one line of text):
#   1. bp-blueprint.pl add-decision appends it to blueprint.md's Decisions
#      table under the next free numeric id, decided by `agent`, with the
#      provenance (escalation id, package, path) appended so the row names the
#      path verbatim;
#   2. bp-ledger.pl widen-write-set --decision <id> widens the ledger. That verb
#      refuses unless the Decision names the path, checks overlap with other
#      in-flight packages, and writes the widening and its attempt-log line in
#      one typed splice under the ledger lock.
# Without `decision` the action is unchanged (bp-answer-escalation's plain
# --widen-write-set). Everything checkable is checked before step 1, so a
# refusal there writes nothing; a refusal at step 2 leaves the Decision row
# and says so. -> (1, undef) | (0, $reason_for_a_human) | (0, undef) for a
# malformed verdict (left queued, as for a missing `path`).
# ---------------------------------------------------------------------------
sub _next_decision_id {
    my ($txt) = @_;
    my @lines = split /\n/, ($txt // '');
    my ($in, $table, $max) = (0, 0, 0);
    my $fence = 0;
    for my $l (@lines) {
        if ($l =~ /^\s*(?:```|~~~)/) { $fence = !$fence; next; }
        next if $fence;
        if ($l =~ /^##\s+Decisions\b/) { $in = 1; next; }
        next unless $in;
        last if $l =~ /^#{1,2}\s/;
        next unless $l =~ /^\s*\|/;
        $table = 1;
        $max = $1 if $l =~ /^\s*\|\s*([0-9]+)\s*\|/ && $1 > $max;
    }
    return $table ? $max + 1 : undef;
}

sub _widen_with_decision {
    my ($verdict, $rec, $id, $ctx, $path) = @_;
    my $bpdir = $ctx->{bpdir};
    my $pkg   = ref $rec eq 'HASH' ? $rec->{package} : undef;
    my $dtext = $verdict->{decision};
    return (0, undef) unless defined $dtext && !ref $dtext && _has_visible_text($dtext);
    return (0, undef) unless defined $pkg && $pkg =~ /\A[A-Za-z0-9._-]+\z/;
    $dtext =~ s/\s+/ /g;
    $dtext =~ s/\A | \z//g;
    # The checks bp-ledger.pl widen-write-set and bp-blueprint.pl add-decision
    # would refuse on, made here so a doomed call never leaves a Decision row
    # behind. A malformed verdict is the resolver's to redo: (0, undef).
    return (0, undef) if $dtext =~ /\|/ || index($dtext, 'depends_on') >= 0;
    return (0, undef) if $path =~ m{\A(?:/|[A-Za-z]:(?:[\\/]|\z))}
                      || $path =~ /[|\r\n]/
                      || $path =~ m{(?:\A|/)\.\.(?:/|\z)}
                      || $path =~ m{\A(?:\*+|\*\*/\*|\.|\./)\z};
    my $ledger = "$bpdir/packages/$pkg.md";
    return (0, "packages/$pkg.md does not exist, so there is no write_set to widen") unless -f $ledger;
    my $bpmd = "$bpdir/blueprint.md";
    my $txt  = BpOrch::_read_file($bpmd);
    return (0, 'cannot read blueprint.md to record the Decision') unless defined $txt;
    my $did = _next_decision_id($txt);
    return (0, "blueprint.md has no Decisions table to record the widening of ${pkg}'s write_set by "
             . "'$path' in; widen it by hand with bp-ledger.pl widen-write-set once a Decision names it")
        unless defined $did;

    my $row = "$dtext (bp-escalation-resolver, escalation $id: widens $pkg write_set by `$path`)";
    my ($rc, $err) = _run_capture($^X, "$SELF_DIR/bp-blueprint.pl", 'add-decision',
        '--file', $bpmd, '--id', $did, '--text', $row, '--decided', 'agent');
    return (0, "recording Decision $did in blueprint.md was refused (exit $rc): $err; nothing was changed")
        if $rc;

    local $ENV{BP_LEDGER_LOCK_TIMEOUT} = $ENV{BP_LEDGER_LOCK_TIMEOUT} // 10;
    ($rc, $err) = _run_capture($^X, "$SELF_DIR/bp-ledger.pl", 'widen-write-set',
        '--ledger', $ledger, '--path', $path, '--decision', $did);
    return (0, "Decision $did was recorded in blueprint.md, but widening ${pkg}'s write_set by '$path' "
             . "was refused (exit $rc): $err") if $rc;
    _rlog($ctx->{log}, 'escalation_resolve_widened_with_decision',
        { decision => $id, package => $pkg, path => $path, blueprint_decision => $did }) if $ctx->{log};
    return (1, undef);
}

# ---------------------------------------------------------------------------
# author-ledger (bug 20261104-163147-07ae).
#
# This USED to build the ledger from blueprint.md's package-STATUS ROW alone
# (pkg | deliverable | depends_on | model) through a hand-rolled heredoc: an
# empty `write_set:`, `depends_on:` copied into the frontmatter, the one-line
# deliverable as the whole Scope, "TBD" done criteria, and no effort/max_turns/
# test_paths/checks. Each of those is fatal: bp-launch refuses an empty
# write_set, and bp-ledger refuses EVERY write (set-status included) to a ledger
# whose frontmatter carries depends_on, so the authored ledger could neither be
# launched nor repaired through the API. Observed in acxpraxis-step-2, package
# 12-model-merge, whose own `### 12-model-merge` section carried every field the
# stub lacked.
#
# The status row is the DAG and nothing more. The contract is the package's own
# `### <pkg>` section (plugins/blueprint/templates/blueprint.md, "Packages"), so
# the ledger is rendered from that section through the SAME path an author uses:
# `bp-ledger.pl create` for the frontmatter, then `set-section` for Scope / Done
# criteria / Inputs / Out of scope. It is validate()-clean by construction and
# never carries depends_on (ordering stays in the status table).
#
# It is staged in a temp dir and committed only when every step succeeded, and
# never over an existing ledger. Anything missing (no section, no write_set, no
# scope or done criteria, a value bp-ledger refuses) is a REFUSAL with a reason;
# apply_verdict then hands the record to a human (category operator-action)
# instead of writing an unlaunchable stub or marking the escalation resolved.
# ---------------------------------------------------------------------------

# _package_section($blueprint_bytes, $pkg) -> { title => $t, fields => {k=>v} } | undef
# PURE. Finds the `### <pkg>` heading (outside fenced code, after HTML comments
# are removed -- the template annotates its bullets with <!-- --> comments) and
# collects its `- **key:** value` bullets, each running until the next key
# bullet or the next level 1-3 heading. Continuation lines are kept, so a
# multi-line scope or a numbered done-criteria list survives intact. Keys are
# normalised to lower case with spaces/hyphens as '_'.
sub _package_section {
    my ($txt, $pkg) = @_;
    return undef unless defined $txt && defined $pkg && length $pkg;
    (my $t = $txt) =~ s/<!--.*?-->//gs;
    $t =~ s/\r\n/\n/g;
    my @lines = split /\n/, $t, -1;
    my ($start, $title);
    my $fence = 0;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^\s*(?:```|~~~)/) { $fence = !$fence; next; }
        next if $fence;
        if ($lines[$i] =~ /^###\s+\Q$pkg\E(?=\s|:|\z)(.*)$/) {
            ($start, $title) = ($i, $1);
            last;
        }
    }
    return undef unless defined $start;
    # Separator between the id and the title: ':' or an em/en dash or '-'.
    $title =~ s/\A\s*(?::|\xE2\x80\x94|\xE2\x80\x93|-)?\s*//;
    $title =~ s/\s+\z//;

    my (%f, $key);
    $fence = 0;
    for my $i ($start + 1 .. $#lines) {
        my $l = $lines[$i];
        if ($l =~ /^\s*(?:```|~~~)/) { $fence = !$fence; }
        last if !$fence && $l =~ /^#{1,3}\s/;
        if (!$fence && $l =~ /^\s?[-*]\s+\*\*\s*([A-Za-z][A-Za-z0-9 _-]*?)\s*(?::\s*\*\*|\*\*\s*:)\s?(.*)$/) {
            ($key = lc $1) =~ s/[\s-]+/_/g;
            $f{$key} = $2;
            next;
        }
        next unless defined $key;
        (my $c = $l) =~ s/^ {1,2}//;
        $f{$key} .= "\n$c";
    }
    for my $k (keys %f) { $f{$k} =~ s/\A\s+|\s+\z//g; }
    return { title => $title, fields => \%f };
}

# A colon-delimited frontmatter field from a bullet value. The template writes
# these in backticks (`a/:b/`); several backticked spans are joined with ':'.
# A placeholder dash or "none" is empty.
sub _author_path_field {
    my ($v) = @_;
    return '' unless defined $v;
    my @spans = ($v =~ /`([^`]*)`/g);
    my $s = @spans ? join(':', grep { length } map { my $x = $_; $x =~ s/^\s+|\s+$//g; $x } @spans) : $v;
    $s =~ s/^\s+|\s+$//g;
    return '' if $s =~ /\A(?:-|\xE2\x80\x94|none|n\/a)?\z/i;
    return $s;
}

# The first word of a bullet value (model/effort), lower-cased, or undef.
sub _author_word_field {
    my ($v) = @_;
    return undef unless defined $v && $v =~ /\A\W*([A-Za-z][A-Za-z0-9.-]*)/;
    return lc $1;
}

# list-form system() with stdout discarded and stderr captured through a FILE,
# never an in-memory scalar (Git-for-Windows perl fails reopening STDERR onto
# one -- repo CLAUDE.md, "Windows landmines"). -> ($rc, $first_stderr_line)
sub _run_capture {
    my (@cmd) = @_;
    require File::Temp;
    my ($efh, $efile) = File::Temp::tempfile('bp-resolve-err-XXXXXX', TMPDIR => 1, UNLINK => 1);
    close $efh;
    my ($so, $se);
    open($so, '>&', \*STDOUT) or return (1, 'cannot dup STDOUT');
    open($se, '>&', \*STDERR) or return (1, 'cannot dup STDERR');
    unless (open(STDOUT, '>', File::Spec->devnull)) { open(STDOUT, '>&', $so); return (1, 'cannot redirect STDOUT'); }
    unless (open(STDERR, '>', $efile)) { open(STDOUT, '>&', $so); open(STDERR, '>&', $se); return (1, 'cannot redirect STDERR'); }
    my $rc = system(@cmd);
    open(STDOUT, '>&', $so); open(STDERR, '>&', $se);
    close $so; close $se;
    my $err = BpOrch::_read_file($efile) // '';
    unlink $efile;
    my ($first) = grep { /\S/ } split /\n/, $err;
    $first //= '';
    $first =~ s/\s+\z//;
    return (0, '') if $rc == 0;
    return ((($rc >> 8) || 1), $first);
}

# _author_ledger($pkg, \%ctx) -> (1, undef) | (0, $reason). Never dies.
sub _author_ledger {
    my ($pkg, $ctx) = @_;
    my @r = eval { _author_ledger_inner($pkg, $ctx) };
    return (0, "author-ledger failed: $@") if $@;
    return @r;
}

sub _author_ledger_inner {
    my ($pkg, $ctx) = @_;
    return (0, 'the escalation names no package') unless defined $pkg && length $pkg;
    my $bpdir  = $ctx->{bpdir};
    my $bp     = $ctx->{bp} // '';
    # fixbatch step7 / LOW: sanitize $pkg the same way _unique_decision_path
    # does (BpOrch::_safe_path_component) -- strips only path separators and
    # NUL, never touching legitimate non-ASCII.
    my $ledger = "$bpdir/packages/" . BpOrch::_safe_path_component($pkg) . ".md";
    my $fix = "Add a complete '### $pkg' section to blueprint.md (scope, done_criteria, write_set, "
            . "test_paths, checks, model, max_turns, inputs, out_of_scope) and answer not-mine to retry, "
            . "or create the ledger with bp-ledger.pl create.";

    return (0, "a ledger already exists at packages/$pkg.md; author-ledger never overwrites one. "
             . 'Repair it with the bp-ledger.pl verbs instead.') if -e $ledger;

    my $txt = BpOrch::_read_file("$bpdir/blueprint.md");
    return (0, "cannot read blueprint.md, so there is nothing to author packages/$pkg.md from. $fix")
        unless defined $txt;
    my $sec = _package_section($txt, $pkg);
    return (0, "blueprint.md has no '### $pkg' section, so there is no write_set, scope or done "
             . "criteria to author packages/$pkg.md from (the status-table row is ordering only). $fix")
        unless $sec;
    my $f = $sec->{fields};

    my $ws = _author_path_field($f->{write_set});
    return (0, "blueprint.md's '### $pkg' section has no write_set; a ledger without one cannot be "
             . "launched. $fix") unless length $ws;
    for my $k (qw(scope done_criteria)) {
        return (0, "blueprint.md's '### $pkg' section has no $k; author-ledger will not invent one. $fix")
            unless defined $f->{$k} && $f->{$k} =~ /\S/;
    }

    # model: the section first, then the status table's model column.
    my $model = _author_word_field($f->{model});
    unless (defined $model) {
        my $row = _status_row($txt, $pkg);
        $model = _author_word_field($row->{model}) if $row;
    }
    my $effort  = _author_word_field($f->{effort});
    my ($turns) = (($f->{max_turns} // '') =~ /([0-9]+)/);
    my $tp      = _author_path_field($f->{test_paths});
    my $checks  = _author_path_field($f->{checks});
    my $title   = length($sec->{title}) ? $sec->{title} : $pkg;

    my $tpl = "$SELF_DIR/../../blueprint/templates/package-ledger.md";
    return (0, "the package-ledger template is missing ($tpl)") unless -f $tpl;
    my $ledger_pl = "$SELF_DIR/bp-ledger.pl";

    require File::Temp;
    my $stage = File::Temp::tempdir('bp-author-ledger-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $sl = "$stage/$pkg.md";
    my $ledger_call = sub {
        my ($verb, @a) = @_;
        my ($rc, $err) = _run_capture($^X, $ledger_pl, $verb, '--ledger', $sl, @a);
        return $rc ? "bp-ledger.pl $verb refused (exit $rc): $err" : undef;
    };
    my $n = 0;
    my $textfile = sub {
        my ($body) = @_;
        my $p = "$stage/text-" . $n++ . '.txt';
        open(my $fh, '>:raw', $p) or die "cannot write $p: $!\n";
        print $fh $body;
        close $fh or die "cannot close $p: $!\n";
        return $p;
    };

    my $why = $ledger_call->('create',
        '--package', $pkg, '--blueprint', $bp, '--template', $tpl, '--write-set', $ws,
        '--title', $title,
        (length $tp      ? ('--test-paths', $tp)     : ()),
        (length $checks  ? ('--checks',     $checks) : ()),
        (defined $model  ? ('--model',      $model)  : ()),
        (defined $effort ? ('--effort',     $effort) : ()),
        (defined $turns  ? ('--max-turns',  $turns)  : ()));
    return (0, "$why. $fix") if defined $why;

    my $none = "_Not stated in blueprint.md's '### $pkg' section._";
    for my $s (['Scope', 'scope'], ['Done criteria', 'done_criteria'],
               ['Inputs', 'inputs'], ['Out of scope', 'out_of_scope']) {
        my $v = $f->{ $s->[1] };
        my $body = (defined $v && $v =~ /\S/) ? $v : $none;
        $why = $ledger_call->('set-section', '--section', $s->[0], '--text-file', $textfile->($body));
        return (0, "$why. $fix") if defined $why;
    }
    $why = $ledger_call->('append-attempt', '--text-file', $textfile->(
        "bp-escalation-resolver (author-ledger): ledger rendered from blueprint.md's '### $pkg' section "
      . 'through bp-ledger.pl create and set-section.'));
    return (0, "$why. $fix") if defined $why;
    $why = $ledger_call->('set-next-action', '--body-file', $textfile->('Start at Pipeline step 1.'));
    return (0, "$why. $fix") if defined $why;

    my $bytes = BpOrch::_read_file($sl);
    return (0, 'the staged ledger could not be read back') unless defined $bytes && length $bytes;

    unless (-d "$bpdir/packages") {
        require File::Path;
        eval { File::Path::make_path("$bpdir/packages"); 1 };
    }
    my $r = BpWrite::guarded_write({
        site   => 'bp-resolve.author-ledger',
        path   => $ledger,
        valid  => sub { return defined $_[0] ? 'a ledger appeared concurrently; never overwritten' : undef },
        mutate => sub { return ($bytes, undef); },
    });
    return (1, undef) if $r && $r->{ok};
    return (0, "writing packages/$pkg.md failed: " . (($r && $r->{reason}) // 'unknown'));
}

# The package-status table row for $pkg as { lc(column) => cell }, or undef.
sub _status_row {
    my ($txt, $pkg) = @_;
    my @lines = split /\n/, $txt;
    my $hdr_i;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^\|\s*pkg\s*\|/i) { $hdr_i = $i; last; }
    }
    return undef unless defined $hdr_i;
    my @hdr = map { lc } _table_cells($lines[$hdr_i]);
    my %col; for my $i (0 .. $#hdr) { $col{$hdr[$i]} = $i; }
    return undef unless exists $col{pkg};
    for my $i ($hdr_i + 2 .. $#lines) {
        last unless $lines[$i] =~ /^\|/;
        my @cells = _table_cells($lines[$i]);
        next unless defined $cells[$col{pkg}] && $cells[$col{pkg}] eq $pkg;
        return { map { $_ => $cells[$col{$_}] } keys %col };
    }
    return undef;
}

sub _table_cells {
    my ($line) = @_;
    my @cells = split /\|/, $line, -1;
    @cells = map { my $s = $_; $s =~ s/^\s+|\s+$//g; $s } @cells;
    shift @cells while @cells && $cells[0] eq '';
    pop @cells while @cells && $cells[-1] eq '';
    return @cells;
}

# When a resolver-owned category='scoping' verdict is successfully applied,
# bump the package's chronic-scoping counter (registry.json field, the same
# shape every other counter in this codebase uses via update_registry_pkg)
# and, on the >2 crossing, file exactly one 'chronic-scoping'/'product'
# decision via BpOrch::queue_needs_you -- deduped on (package, kind) for
# free by that function's own existing dedupe (never re-filed on a later
# crossing). Never blocks/slows/gates the package itself (e01 §2.5) -- this
# is best-effort and never changes apply_verdict's own return value.
sub _bump_chronic_scoping_counter {
    my ($rec, $id, $verdict, $ctx) = @_;
    eval {
        my $runs = $ctx->{runs};
        my $pkg  = $rec->{package};
        # Resolving the chronic-scoping escalation itself is not another
        # scoping resolution of the package. Counting it made the counter feed
        # itself: each resolution of the "more than 2" escalation bumped the
        # count and filed the next one (acxpraxis 15-model-check-cost,
        # 2026-11-05: 25 resolver judges in 2h, every one a moot relaunch).
        return 1 if ($rec->{kind} // '') eq 'chronic-scoping';
        my $reg  = BpOrch::_read_json("$runs/registry.json");
        my $prec = (ref $reg eq 'HASH' && ref $reg->{packages}{$pkg} eq 'HASH') ? $reg->{packages}{$pkg} : {};
        my $before = $prec->{chronic_scoping_count} // 0;
        my ($after, $fire) = chronic_scoping_bump($before);
        # The pure counter keeps reporting "fires" past the threshold; filing
        # is once per package. queue_needs_you only dedupes against a record
        # still QUEUED, so after the first one was resolved and archived every
        # later bump filed a fresh one.
        $fire = 0 if $prec->{chronic_scoping_filed};
        BpOrch::update_registry_pkg($runs, $pkg, { chronic_scoping_count => $after,
                                                   ($fire ? (chronic_scoping_filed => time) : ()) });
        if ($fire) {
            BpOrch::queue_needs_you($runs, {
                package    => $pkg,
                blueprint  => $ctx->{bp},
                kind       => 'chronic-scoping',
                question   => "Package '$pkg' has had more than 2 autonomous scoping resolutions -- "
                             . "review whether its write_set/scope needs a human decision.",
                context    => "Most recent autonomous scoping resolution: $id"
                             . (length($verdict->{rationale} // '') ? " -- $verdict->{rationale}" : ''),
                created_at => time,
                # e06-fleet-inbox-bridge §2.6: unclassified, not product -- a
                # mechanical site must not route straight to the operator;
                # the resolver judges this one too (Decision 17 Q23).
                category   => 'unclassified',
            }, $ctx->{bpdir});
        }
        1;
    };
    return;
}

# _surface_needs_human($qpath, \%rec, \%verdict, $why, $log, $id) -> 1|0
# An action the apply-step REFUSED for a reason no resolver rerun can change
# (author-ledger against a blueprint with no usable package section, bug
# 20261104-163147-07ae) must not stay resolver-triageable: the orchestrator
# would fire the resolver again, it would pick the same action, and the
# package would sit unlaunchable with nobody told. Re-tag the queued record in
# place as operator-action with the refusal as its product_question, so the
# inbox bridge files it for a human; nothing is unlinked. Same lock and
# freshness check as the tag-only branch: a record the operator already
# disposed of is left alone.
#
# \%opt (optional): log_type (the event logged on success; '<log_type>_failed'
# on failure), question (the product_question to file; defaults to the
# author-ledger wording), stale_ref (a scalar ref set to 1 when the record had
# changed or vanished, so the caller can report 'stale' rather than a failure).
sub _surface_needs_human {
    my ($qpath, $rec, $verdict, $why, $log, $id, $opt) = @_;
    $opt ||= {};
    my $log_type = $opt->{log_type} // 'escalation_resolve_needs_human';
    my $stale = 0;
    my ($ok) = _with_qpath_lock($qpath, sub {
        my $fresh = BpOrch::_read_json($qpath);
        unless (_same_queued_record($fresh, $rec)) { $stale = 1; return 0; }
        my %tagged = (%$rec);
        my $pkg = $rec->{package} // '?';
        $tagged{category}         = 'operator-action';
        $tagged{resolved_by}      = 'bp-resolve';
        $tagged{confidence}       = $verdict->{confidence};
        $tagged{evidence}         = $verdict->{evidence};
        $tagged{resolution}       = "the resolver chose $verdict->{action}, and it was refused: $why";
        $tagged{product_question} = $opt->{question}
            // (($verdict->{action} // '') eq 'author-ledger'
                ? "Package $pkg cannot be given a ledger automatically: $why"
                : "Package ${pkg}'s escalation could not be resolved automatically: the resolver chose "
                  . ($verdict->{action} // '?') . ", and it was refused: $why");
        return _atomic_write_json($qpath, \%tagged);
    });
    ${ $opt->{stale_ref} } = $stale if ref $opt->{stale_ref} eq 'SCALAR';
    _rlog($log, ($ok ? $log_type : "${log_type}_failed"),
        { decision => $id, package => (ref $rec eq 'HASH' ? $rec->{package} : undef),
          action => $verdict->{action}, why => $why, ($stale ? (stale => 1) : ()) });
    return $ok ? 1 : 0;
}

# ---------------------------------------------------------------------------
# _verdict_contradicts_state(\%verdict, \%rec, \%ctx) -> reason | undef
# (bug 20261105-055544-2c28). A verdict whose action cannot mean what it says
# against the package as it stands on disk is not a resolution, however
# confident it is. Observed: an escalation asking to widen a write_set by one
# file and to grant a lint exemption got `author-ledger` (rationale: "author a
# new blueprint.md Decision granting both"), and the pre-923dd82 apply step
# overwrote the package's live 9.9 KB ledger with a stub.
#
# author-ledger is valid ONLY for a package with no ledger file. _author_ledger
# itself also refuses (and its guarded_write refuses a file that appears under
# the lock), so this is not the only line of defence -- it is the one that
# fires BEFORE anything is archived or dispatched, logs the case under its own
# event (escalation_resolve_contradiction), and files the question with the
# escalation's own text, so the operator answers what was actually asked rather
# than "cannot be given a ledger".
#
# Deliberately structural only. Matching the rationale/evidence prose for
# "write set" or "Decision" was considered and rejected: when no ledger exists
# author-ledger renders from the blueprint's own section whatever the prose
# says, so a text match would add only false refusals (a correct rationale
# naturally says "its section declares the write_set") and misses for every
# rewording. The one thing that makes this action destructive is a file on
# disk, and that is what is checked.
# ---------------------------------------------------------------------------
sub _verdict_contradicts_state {
    my ($verdict, $rec, $ctx) = @_;
    my $action = $verdict->{action} // '';
    return undef unless $action eq 'author-ledger';
    my $pkg = ref $rec eq 'HASH' ? $rec->{package} : undef;
    return undef unless defined $pkg && length $pkg && defined $ctx->{bpdir};
    my $ledger = "$ctx->{bpdir}/packages/" . BpOrch::_safe_path_component($pkg) . '.md';
    return undef unless -e $ledger;
    return "the resolver chose author-ledger, which only creates a ledger for a package that has none, "
         . "but packages/$pkg.md already exists; nothing was changed";
}

# One line, at most $max bytes, for embedding queued prose in a product_question.
sub _one_line {
    my ($s, $max) = @_;
    return '' unless defined $s && !ref $s;
    (my $t = $s) =~ s/\s+/ /g;
    $t =~ s/\A | \z//g;
    $t = substr($t, 0, $max - 3) . '...' if defined $max && length($t) > $max;
    return $t;
}

# ---------------------------------------------------------------------------
# apply_verdict(\%verdict, \%decision_rec, $decision_id, \%ctx) -> \%outcome
# \%ctx = { bpdir, runs, bp, log }
# Orchestrates the three pure gates above, then:
#   'act'      -> ARCHIVE FIRST (§2.1b), BEFORE any unlink. A failed archive
#                 write ABORTS the whole operation: dispatch never runs, the
#                 queue file is never touched (HIGHEST-VALUE #2). Only once
#                 the archive is confirmed on disk does dispatch run; the
#                 archive is then updated with the real applied outcome, and
#                 the queue file is unlinked ONLY on applied=>true.
#   'tag-only' -> rewrite the queue file in place (§2.1a); nothing unlinked,
#                 nothing archived.
#   'refuse'   -> log only; queue file untouched; no archive (a refusal is
#                 not itself a decision, §2.6).
#   'contradiction' -> an 'act' verdict whose action contradicts the package's
#                 state on disk (_verdict_contradicts_state: author-ledger for a
#                 package that already has a ledger). Checked BEFORE the archive
#                 and dispatch: nothing archived, nothing dispatched, the ledger
#                 untouched; the queued record is re-tagged operator-action with
#                 a question (log event escalation_resolve_contradiction).
# Returns { outcome, applied, archived, reason } (+ surfaced when handed to a human).
# ---------------------------------------------------------------------------
sub apply_verdict {
    my ($verdict, $rec, $id, $ctx) = @_;
    my $runs  = $ctx->{runs};
    my $log   = $ctx->{log};
    my $qpath = BpOrch::escalations_dir($runs) . "/$id.json";
    my $gate  = confidence_gate($verdict);

    if ($gate eq 'refuse') {
        _rlog($log, 'escalation_resolve_refused', {
            decision => $id, package => (ref $rec eq 'HASH' ? $rec->{package} : undef),
            category => $verdict->{category},
        });
        return { outcome => 'refuse', applied => 0, archived => 0, reason => 'verdict refused by confidence_gate' };
    }

    if ($gate eq 'tag-only') {
        my $stale = 0;
        my ($ok) = _with_qpath_lock($qpath, sub {
            my $fresh = BpOrch::_read_json($qpath);
            unless (_same_queued_record($fresh, $rec)) { $stale = 1; return 0; }
            my %tagged = (%$rec);
            $tagged{category}    = $verdict->{category};
            $tagged{resolved_by} = 'bp-escalation-resolver';
            $tagged{confidence}  = $verdict->{confidence};
            $tagged{evidence}    = $verdict->{evidence};
            $tagged{resolution}  = $verdict->{resolution} // $verdict->{rationale} // '';
            # e06-fleet-inbox-bridge §2.6: carried onto the tagged record
            # (trimmed) -- verdict_shape_ok already guaranteed it is defined
            # and non-blank for this category.
            (my $pq = $verdict->{product_question}) =~ s/\A\s+|\s+\z//g;
            $tagged{product_question} = $pq;
            return _atomic_write_json($qpath, \%tagged);
        });
        if ($stale) {
            _rlog($log, 'escalation_resolve_stale', { decision => $id, package => (ref $rec eq 'HASH' ? $rec->{package} : undef) });
            return { outcome => 'stale', applied => 0, archived => 0,
                     reason => 'queued record changed or was removed before the verdict could be applied -- '
                             . 'the operator likely disposed of it already; nothing written' };
        }
        unless ($ok) {
            _rlog($log, 'escalation_resolve_tag_failed', { decision => $id, package => (ref $rec eq 'HASH' ? $rec->{package} : undef) });
            return { outcome => 'refuse', applied => 0, archived => 0, reason => 'in-place tag write failed' };
        }
        return { outcome => 'tag-only', applied => 0, archived => 0, reason => undef };
    }

    # $gate eq 'act'
    my $archive_path = "$runs/resolved-escalations/$id.json";

    # fixbatch step7 / MEDIUM (crash window): if a prior run already got as
    # far as durably recording applied=>true for this id (the second archive
    # write below succeeded) but was killed before the unlink that follows
    # it, the queue file is still sitting in runs/needs-you/ and would
    # otherwise be picked up and RE-DISPATCHED by a later tick -- re-running
    # work (e.g. relaunch) that already landed. Detect that up front and
    # finish the interrupted cleanup instead of re-dispatching.
    my $prior_arc = BpOrch::_read_json($archive_path);
    if (ref $prior_arc eq 'HASH' && $prior_arc->{applied}) {
        unlink $qpath if -e $qpath;
        return { outcome => 'act', applied => 1, archived => 1,
                 reason => 'already applied in a prior run (archive already marked applied=true); '
                         . 'finished the interrupted cleanup without re-dispatching' };
    }

    # After the crash-window check on purpose: an author-ledger that DID land
    # in a prior run leaves a ledger behind, and that must finish its cleanup,
    # not read as a contradiction. Nothing is archived here -- nothing was
    # decided -- and the queued record is re-tagged in place for a human.
    if (defined(my $contra = _verdict_contradicts_state($verdict, $rec, $ctx))) {
        my $pkg = ref $rec eq 'HASH' ? ($rec->{package} // '?') : '?';
        my $asked = _one_line(ref $rec eq 'HASH' ? $rec->{question} : undef, 600);
        my $why_r = _one_line($verdict->{rationale}, 300);
        my $question = "Package ${pkg}'s escalation needs your decision: the resolver proposed author-ledger, "
                     . "but packages/$pkg.md already exists, so its verdict contradicts the package's state "
                     . "and was not applied (the ledger is untouched)."
                     . (length $asked ? " The escalation asked: $asked" : '')
                     . (length $why_r ? " The resolver's rationale: $why_r" : '')
                     . ' Answer with the action the package actually needs (for example a write_set '
                     . 'widening backed by a Decision), or not-mine to send it back to the resolver.';
        my $stale_c = 0;
        my $ok = _surface_needs_human($qpath, $rec, $verdict, $contra, $log, $id,
            { log_type => 'escalation_resolve_contradiction', question => $question, stale_ref => \$stale_c });
        if ($stale_c) {
            return { outcome => 'stale', applied => 0, archived => 0,
                     reason => 'queued record changed or was removed before the verdict could be applied -- '
                             . 'nothing written' };
        }
        return { outcome => 'contradiction', applied => 0, archived => 0,
                 ($ok ? (surfaced => 'operator-action') : ()),
                 reason => "author-ledger refused: $contra" };
    }

    my $stale = 0;
    my ($archived_ok) = _with_qpath_lock($qpath, sub {
        my $fresh = BpOrch::_read_json($qpath);
        unless (_same_queued_record($fresh, $rec)) { $stale = 1; return 0; }
        my $arc = {
            original    => $rec,
            resolved_by => 'bp-escalation-resolver',
            action      => $verdict->{action},
            rationale   => $verdict->{rationale},
            confidence  => $verdict->{confidence},
            evidence    => $verdict->{evidence},
            resolved_at => time,
            applied     => JSON::PP::false,
        };
        return _atomic_write_json($archive_path, $arc);
    });
    if ($stale) {
        _rlog($log, 'escalation_resolve_stale', { decision => $id, package => (ref $rec eq 'HASH' ? $rec->{package} : undef) });
        return { outcome => 'stale', applied => 0, archived => 0,
                 reason => 'queued record changed or was removed before the verdict could be applied -- '
                         . 'the operator likely disposed of it already; nothing archived, nothing dispatched' };
    }
    unless ($archived_ok) {
        # HIGHEST-VALUE #2: a failed archive write must ABORT the deletion --
        # dispatch never runs, the queue file is never touched.
        _rlog($log, 'escalation_resolve_archive_failed', { decision => $id, package => (ref $rec eq 'HASH' ? $rec->{package} : undef) });
        return { outcome => 'act', applied => 0, archived => 0, reason => 'archive write failed -- deletion aborted' };
    }

    my $dispatch_rc = _dispatch_action($verdict, $rec, $id, $ctx);
    my $applied = ($dispatch_rc == 0) ? 1 : 0;

    # A refusal the resolver cannot fix goes to a human (see
    # _surface_needs_human). The archive below still records applied=false.
    my $refusal = $applied ? undef : delete $ctx->{needs_human};
    my $surfaced = defined($refusal)
        ? _surface_needs_human($qpath, $rec, $verdict, $refusal, $log, $id) : 0;

    # Re-write the archive with the REAL applied outcome, return value now
    # CHECKED (fixbatch step7 / MEDIUM: it used to be silently ignored). If
    # this second write fails and dispatch did NOT succeed, the archive
    # still holds applied=false from the first write (never silently
    # upgraded to look successful) and the queue file is left in place, same
    # as before, so a later tick can still discover and re-attempt it. If
    # dispatch DID succeed but only this bookkeeping write failed, the queue
    # file is still unlinked anyway -- the crash-window guard above (checking
    # $prior_arc->{applied}) exists precisely because RE-DISPATCHING an
    # action that already landed is a worse outcome than an under-reporting
    # archive record, and the failure is logged either way, not swallowed.
    {
        my $arc2 = {
            original    => $rec,
            resolved_by => 'bp-escalation-resolver',
            action      => $verdict->{action},
            rationale   => $verdict->{rationale},
            confidence  => $verdict->{confidence},
            evidence    => $verdict->{evidence},
            resolved_at => time,
            applied     => $applied ? JSON::PP::true : JSON::PP::false,
            (defined $refusal ? (refusal => $refusal, surfaced_to => ($surfaced ? 'operator-action' : undef)) : ()),
        };
        my $arc2_ok = _atomic_write_json($archive_path, $arc2);
        unless ($arc2_ok) {
            _rlog($log, 'escalation_resolve_archive_update_failed',
                { decision => $id, package => (ref $rec eq 'HASH' ? $rec->{package} : undef), applied => $applied });
            if ($applied) {
                # Dispatch really happened but the durable record could not be
                # updated to say so -- log it, but do NOT re-queue-visible this
                # id for re-dispatch either: unlink it anyway, same as the
                # applied=>true path below, since re-running an action that
                # already succeeded is the harm this fix targets, not a stale
                # applied=>false archive record (which is already logged).
                unlink $qpath if -e $qpath;
                _bump_chronic_scoping_counter($rec, $id, $verdict, $ctx) if ($verdict->{category} // '') eq 'scoping';
            } else {
                _rlog($log, 'escalation_resolve_apply_failed', { decision => $id, package => (ref $rec eq 'HASH' ? $rec->{package} : undef), rc => $dispatch_rc });
            }
            return { outcome => 'act', applied => $applied, archived => 1,
                     reason => ($applied ? 'dispatch succeeded but the archive update failed -- logged, queue file unlinked anyway'
                                          : "dispatch failed, rc=$dispatch_rc; archive update also failed") };
        }
    }

    if ($applied) {
        unlink $qpath if -e $qpath;
        _bump_chronic_scoping_counter($rec, $id, $verdict, $ctx) if ($verdict->{category} // '') eq 'scoping';
    } else {
        _rlog($log, 'escalation_resolve_apply_failed', { decision => $id, package => (ref $rec eq 'HASH' ? $rec->{package} : undef), rc => $dispatch_rc });
    }

    return { outcome => 'act', applied => $applied, archived => 1,
             ($surfaced ? (surfaced => 'operator-action') : ()),
             reason => ($applied ? undef
                       : defined($refusal) ? "$verdict->{action} refused: $refusal"
                       : "dispatch failed, rc=$dispatch_rc") };
}

# ---------------------------------------------------------------------------
# digest_list($runs) -> \@records
# DC6's read-only surface: scans runs/resolved-escalations/*.json, returns
# one hashref per resolution, sorted oldest resolved_at first. Mutates
# nothing.
# ---------------------------------------------------------------------------
sub digest_list {
    my ($runs) = @_;
    my $dir = "$runs/resolved-escalations";
    return [] unless -d $dir;
    opendir(my $dh, $dir) or return [];
    my @files = grep { /\.json$/i } readdir $dh;
    closedir $dh;
    my @recs;
    for my $f (@files) {
        my $r = BpOrch::_read_json("$dir/$f");
        push @recs, $r if ref $r eq 'HASH';
    }
    @recs = sort { ($a->{resolved_at} // 0) <=> ($b->{resolved_at} // 0) } @recs;
    return \@recs;
}

package main;
use strict;
use warnings;

unless (caller) {
    require JSON::PP;
    my ($bp, $bpdir, $apply_verdict_path, $decision, $digest_mode);
    my @pos;
    my $need = sub {
        my ($flag) = @_;
        my $v = shift @ARGV;
        unless (defined $v && $v !~ /^--/) {
            print STDERR "bp-resolve: $flag requires a value\n"; exit 2;
        }
        return $v;
    };
    while (@ARGV) {
        my $arg = shift @ARGV;
        if    ($arg eq '--bp-dir')          { $bpdir              = $need->('--bp-dir'); }
        elsif ($arg eq '--apply-verdict')   { $apply_verdict_path = $need->('--apply-verdict'); }
        elsif ($arg eq '--decision')        { $decision           = $need->('--decision'); }
        elsif ($arg eq '--digest')          { $digest_mode        = 1; }
        elsif ($arg =~ /^--/)               { print STDERR "bp-resolve: unknown option $arg\n"; exit 2; }
        else  { push @pos, $arg; }
    }
    $bp = shift @pos if @pos;

    unless (defined $bp && length $bp) {
        print STDERR "usage: bp-resolve.pl <blueprint> --apply-verdict <path> --decision <id> [--bp-dir DIR]\n"
                   . "       bp-resolve.pl <blueprint> --digest [--bp-dir DIR]\n";
        exit 2;
    }
    unless (defined $bpdir) {
        my $data = $ENV{CCPRAXIS_DATA_DIR};
        unless (defined $data) { print STDERR "bp-resolve: set --bp-dir or CCPRAXIS_DATA_DIR\n"; exit 2; }
        $bpdir = "$data/blueprints/$bp";
    }
    my $runs = "$bpdir/runs";

    if ($digest_mode) {
        my $recs = BpResolve::digest_list($runs);
        my $j = JSON::PP->new->canonical;
        for my $r (@$recs) { print $j->encode($r) . "\n"; }
        exit 0;
    }

    unless (defined $apply_verdict_path && defined $decision) {
        print STDERR "bp-resolve: --apply-verdict <path> --decision <id> required (or use --digest)\n";
        exit 2;
    }
    my $vtxt = BpOrch::_read_file($apply_verdict_path);
    unless (defined $vtxt) {
        print STDERR "bp-resolve: cannot read verdict file: $apply_verdict_path\n"; exit 2;
    }
    my $verdict = eval { JSON::PP->new->decode($vtxt) };
    unless (ref $verdict eq 'HASH') {
        print STDERR "bp-resolve: verdict file is not valid JSON: $apply_verdict_path\n"; exit 2;
    }

    (my $id = $decision) =~ s{.*[\\/]}{};
    $id =~ s/\.json$//i;
    my $qpath = BpOrch::escalations_dir($runs) . "/$id.json";
    my $rec = BpOrch::_read_json($qpath);
    unless (ref $rec eq 'HASH') {
        # The package can settle while its resolver is still deciding: the
        # coordinator finishes, S1 archives the escalation, then the verdict
        # arrives for a record that is gone (where-things-go/10, 2026-10-22,
        # logged as escalation_resolve_apply_failed rc 512). Settled is the
        # outcome the verdict was working toward, so that is moot, not a
        # failure. A record missing with no archive is still an error.
        if (!-e $qpath && -f "$runs/resolved-escalations/$id.json") {
            BpOrch::_log("$runs/orchestrator.log", 'escalation_resolve_apply_moot',
                { decision => $id, why => 'already-settled' });
            exit 0;
        }
        print STDERR "bp-resolve: queued escalation not found or unreadable: $qpath\n"; exit 2;
    }

    my $outcome = BpResolve::apply_verdict($verdict, $rec, $id,
        { bpdir => $bpdir, runs => $runs, bp => $bp, log => "$runs/orchestrator.log" });
    print JSON::PP->new->canonical->encode($outcome) . "\n";
    exit 0;
}
1;
