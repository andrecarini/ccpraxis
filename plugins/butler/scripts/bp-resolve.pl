#!/usr/bin/env perl
# bp-resolve.pl — e03-autonomous-resolution: the deterministic apply-step for
# bp-escalation-resolver's verdicts. Library + CLI, mirroring
# bp-answer-decision.pl's own pure-function/CLI split (BpAnswer -> BpResolve).
#
# Governing rule (spec e03-autonomous-resolution-spec.md, stated once so it is
# not diluted anywhere below): a run stops for the operator ONLY when there is
# nothing else it can do. Every gate below is asymmetric ON PURPOSE --
# uncertainty, malformed input, and anything outside the four narrow action
# verbs fall toward the operator, never toward guessing. Do not "optimize"
# this asymmetry away.
#
# Provenance (DC2): two distinct on-disk records, never conflated with each
# other or with bp-wait-for-decision.pl's UNRELATED classify_decision /
# autonomous_decision_record pair (b24-reporter-autonomy) --
#   (a) in-place tag on the STILL-QUEUED runs/needs-you/<id>.json, when the
#       resolver's verdict lands on category product/operational (including
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

# The four bounded action verbs this package may ever dispatch. 'accept'/
# 'drop' are NEVER in this set -- that bright line is enforced unconditionally
# in verdict_in_bounds below, checked before anything else.
my @VALID_ACTIONS = ('relaunch', 'widen-write-set', 'edit-depends-on', 'author-ledger');
my %VALID_ACTION  = map { $_ => 1 } @VALID_ACTIONS;

# The four categories the resolver may ACT on (never product/operational,
# never unclassified as a terminal value -- e01 §2.2/§2.3, restated here as
# the closed set this module is allowed to mutate on).
my @RESOLVER_OWNED = qw(conformance oracle scoping implementation);
my %RESOLVER_OWNED = map { $_ => 1 } @RESOLVER_OWNED;

# ---------------------------------------------------------------------------
# verdict_shape_ok(\%verdict) -> (1|0, $why)   -- PURE, no I/O.
# Required keys present per category:
#   product|operational  -> category, confidence, evidence defined;
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
# product/operational verdict is still shape_ok (V10's own pinned behavior).
# ---------------------------------------------------------------------------
sub verdict_shape_ok {
    my ($v) = @_;
    return (0, 'verdict must be a hashref') unless ref $v eq 'HASH';
    my $cat = $v->{category};
    return (0, 'missing category') unless defined $cat && length $cat;

    if ($cat eq 'product' || $cat eq 'operational') {
        return (0, "category=$cat verdict must not carry an action -- product/operational are never actable")
            if defined $v->{action};
        for my $k (qw(confidence evidence)) {
            return (0, "missing required key '$k' for category=$cat") unless defined $v->{$k};
        }
        return (1, undef);
    }
    if ($RESOLVER_OWNED{$cat}) {
        for my $k (qw(action confidence evidence rationale)) {
            return (0, "missing required key '$k' for category=$cat") unless defined $v->{$k};
        }
        return (1, undef);
    }
    return (0, "category '" . $cat . "' is not a recognized terminal verdict category "
             . "(must be one of product/operational/conformance/oracle/scoping/implementation -- "
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
        return (0, "action='$act' is never permitted -- the resolver may never accept or drop a decision");
    }
    my $cat = $v->{category} // '';
    return (0, "category '$cat' is not one of the closed 7-category set")
        unless grep { $_ eq $cat } @BpOrch::CATEGORIES;
    if ($RESOLVER_OWNED{$cat}) {
        return (0, 'a resolver-owned category requires an action') unless defined $act;
        return (0, "action '$act' is outside {relaunch,widen-write-set,edit-depends-on,author-ledger}")
            unless $VALID_ACTION{$act};
    }
    return (1, undef);
}

# ---------------------------------------------------------------------------
# confidence_gate(\%verdict) -> 'act' | 'tag-only' | 'refuse'   -- PURE.
# 'act'      iff shape_ok && in_bounds && category is resolver-owned &&
#            confidence eq 'high' && evidence is non-empty.
# 'tag-only' iff shape_ok && category in {product, operational}. An 'action'
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
    my $cat = $v->{category} // '';
    return 'tag-only' if $cat eq 'product' || $cat eq 'operational';
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

# list-form system() with the child's stdout/stderr redirected around the
# call -- the same discipline bp-answer-decision.pl's own
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

# ---------------------------------------------------------------------------
# _dispatch_action(\%verdict, \%rec, $id, \%ctx) -> exit-code-shaped integer
# (0 == succeeded). Reaches every one of the four bounded actions WITHOUT
# editing bp-answer-decision.pl or bp-blueprint.pl -- invoking their existing,
# already-shipped CLI surfaces (spec §2.3), the same reuse pattern
# bp-answer-decision.pl already applies to bp-ledger.pl.
# ---------------------------------------------------------------------------
sub _dispatch_action {
    my ($verdict, $rec, $id, $ctx) = @_;
    my $action    = $verdict->{action} // '';
    my $bp        = $ctx->{bp};
    my $bpdir     = $ctx->{bpdir};
    my $rationale = $verdict->{rationale} // '';

    if ($action eq 'relaunch') {
        return _run_quiet($^X, "$SELF_DIR/bp-answer-decision.pl", $bp,
            '--decision', $id, '--action', 'relaunch', '--note', $rationale, '--bp-dir', $bpdir);
    }
    if ($action eq 'widen-write-set') {
        # No dedicated 'path' key is mandated by verdict_shape_ok (spec §2.6) --
        # an agent citing the exact missing path puts it in 'evidence' (the
        # confidence-citation field already required for a resolver-owned
        # verdict); an optional 'path'/'target' key wins if present.
        my $path = $verdict->{path} // $verdict->{target} // $verdict->{evidence} // '';
        $path =~ s/^\s+|\s+$//g;
        return 1 unless length $path;
        return _run_quiet($^X, "$SELF_DIR/bp-answer-decision.pl", $bp,
            '--decision', $id, '--widen-write-set', $path, '--bp-dir', $bpdir);
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
        return _author_ledger($rec->{package}, $ctx) ? 0 : 1;
    }
    # Unreachable in practice -- verdict_in_bounds already refused anything
    # else before apply_verdict ever dispatches.
    return 1;
}

sub _iso_now {
    my @t = gmtime(time);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# author-ledger: reads blueprint.md's OWN row for the package (pkg,
# deliverable, depends_on, model -- the columns e03's fixtures/blueprint.md
# both use) and writes a fixed-template packages/<pkg>.md via
# BpWrite::guarded_write. A missing/incomplete template source is exactly the
# case e01 §2.4 says falls back to product/confidence:low at the AGENT level
# -- this function never invents ledger content, it only fails closed (0) if
# the row it needs is not there.
sub _author_ledger {
    my ($pkg, $ctx) = @_;
    return 0 unless defined $pkg && length $pkg;
    my $bpdir = $ctx->{bpdir};
    my $txt = BpOrch::_read_file("$bpdir/blueprint.md");
    return 0 unless defined $txt;
    my @lines = split /\n/, $txt;
    my $hdr_i;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^\|\s*pkg\s*\|/i) { $hdr_i = $i; last; }
    }
    return 0 unless defined $hdr_i;
    my @hdr = _table_cells($lines[$hdr_i]);
    my %col; for my $i (0 .. $#hdr) { $col{lc $hdr[$i]} = $i; }
    return 0 unless exists $col{pkg};

    my $row;
    for my $i ($hdr_i + 2 .. $#lines) {
        last unless $lines[$i] =~ /^\|/;
        my @cells = _table_cells($lines[$i]);
        next unless defined $cells[$col{pkg}] && $cells[$col{pkg}] eq $pkg;
        $row = \@cells; last;
    }
    return 0 unless $row;

    my $deliverable = (exists $col{deliverable} ? $row->[$col{deliverable}] : undef) // '';
    my $depends_on  = (exists $col{depends_on}  ? $row->[$col{depends_on}]  : undef) // '';
    my $model       = (exists $col{model}       ? $row->[$col{model}]       : undef) // 'sonnet';
    $depends_on = '' if $depends_on eq '—' || $depends_on eq '-';
    return 0 unless length $deliverable;   # no template source -> never invent content

    my $ledger  = "$bpdir/packages/$pkg.md";
    my $now_iso = _iso_now();
    my $body =
        "---\npackage: $pkg\nblueprint: " . ($ctx->{bp} // '') . "\nstatus: pending\n"
      . "write_set: \ndepends_on: $depends_on\nmodel: $model\nlast_updated: $now_iso\n---\n\n"
      . "# Package $pkg\n\n"
      . "## Scope\n\n$deliverable\n\n"
      . "## Done criteria\n\n1. TBD -- authored from blueprint.md's own row by bp-escalation-resolver; "
      . "the operator/architect should review and refine before this package's pipeline proceeds.\n\n"
      . "## Pipeline\n\n- [ ] 1. Scout\n\n"
      . "## Decisions & attempt log\n\n"
      . "- $now_iso -- bp-escalation-resolver -- ledger authored from blueprint.md (author-ledger action).\n\n"
      . "## Next action\n\nStart at Pipeline step 1.\n\n"
      . "## Outputs\n\n"
      . "## Escalation\n\n";

    my $r = BpWrite::guarded_write({
        site   => 'bp-resolve.author-ledger',
        path   => $ledger,
        mutate => sub { return ($body, undef); },
    });
    return ($r && $r->{ok}) ? 1 : 0;
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
        my $reg  = BpOrch::_read_json("$runs/registry.json");
        my $before = (ref $reg eq 'HASH' && ref $reg->{packages}{$pkg} eq 'HASH')
                   ? ($reg->{packages}{$pkg}{chronic_scoping_count} // 0) : 0;
        my ($after, $fire) = chronic_scoping_bump($before);
        BpOrch::update_registry_pkg($runs, $pkg, { chronic_scoping_count => $after });
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
                category   => 'product',
            }, $ctx->{bpdir});
        }
        1;
    };
    return;
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
# Returns { outcome, applied, archived, reason }.
# ---------------------------------------------------------------------------
sub apply_verdict {
    my ($verdict, $rec, $id, $ctx) = @_;
    my $runs  = $ctx->{runs};
    my $log   = $ctx->{log};
    my $qpath = "$runs/needs-you/$id.json";
    my $gate  = confidence_gate($verdict);

    if ($gate eq 'refuse') {
        _rlog($log, 'escalation_resolve_refused', {
            decision => $id, package => (ref $rec eq 'HASH' ? $rec->{package} : undef),
            category => $verdict->{category},
        });
        return { outcome => 'refuse', applied => 0, archived => 0, reason => 'verdict refused by confidence_gate' };
    }

    if ($gate eq 'tag-only') {
        my %tagged = (%$rec);
        $tagged{category}    = $verdict->{category};
        $tagged{resolved_by} = 'bp-escalation-resolver';
        $tagged{confidence}  = $verdict->{confidence};
        $tagged{evidence}    = $verdict->{evidence};
        $tagged{resolution}  = $verdict->{resolution} // $verdict->{rationale} // '';
        my $ok = _atomic_write_json($qpath, \%tagged);
        unless ($ok) {
            _rlog($log, 'escalation_resolve_tag_failed', { decision => $id, package => $rec->{package} });
            return { outcome => 'refuse', applied => 0, archived => 0, reason => 'in-place tag write failed' };
        }
        return { outcome => 'tag-only', applied => 0, archived => 0, reason => undef };
    }

    # $gate eq 'act'
    my $archive_path = "$runs/resolved-escalations/$id.json";
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
    unless (_atomic_write_json($archive_path, $arc)) {
        # HIGHEST-VALUE #2: a failed archive write must ABORT the deletion --
        # dispatch never runs, the queue file is never touched.
        _rlog($log, 'escalation_resolve_archive_failed', { decision => $id, package => $rec->{package} });
        return { outcome => 'act', applied => 0, archived => 0, reason => 'archive write failed -- deletion aborted' };
    }

    my $dispatch_rc = _dispatch_action($verdict, $rec, $id, $ctx);
    my $applied = ($dispatch_rc == 0) ? 1 : 0;

    # Re-write the archive with the REAL applied outcome. If this second write
    # somehow fails, the archive still holds applied=false from the first
    # write (never silently upgraded to look successful) -- degrade-safe.
    $arc->{applied} = $applied ? JSON::PP::true : JSON::PP::false;
    _atomic_write_json($archive_path, $arc);

    if ($applied) {
        unlink $qpath if -e $qpath;
        _bump_chronic_scoping_counter($rec, $id, $verdict, $ctx) if ($verdict->{category} // '') eq 'scoping';
    } else {
        _rlog($log, 'escalation_resolve_apply_failed', { decision => $id, package => $rec->{package}, rc => $dispatch_rc });
    }

    return { outcome => 'act', applied => $applied, archived => 1,
             reason => ($applied ? undef : "dispatch failed, rc=$dispatch_rc") };
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
    my $qpath = "$runs/needs-you/$id.json";
    my $rec = BpOrch::_read_json($qpath);
    unless (ref $rec eq 'HASH') {
        print STDERR "bp-resolve: queued decision not found or unreadable: $qpath\n"; exit 2;
    }

    my $outcome = BpResolve::apply_verdict($verdict, $rec, $id,
        { bpdir => $bpdir, runs => $runs, bp => $bp, log => "$runs/orchestrator.log" });
    print JSON::PP->new->canonical->encode($outcome) . "\n";
    exit 0;
}
1;
