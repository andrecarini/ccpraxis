#!/usr/bin/env perl
# bp-remediate.pl — b07-auto-remediation-engine: the DETERMINISTIC decision core
# that turns a b05 conformance-verdict FAIL into action. b05 (bp-judge.pl +
# bp-orchestrator.pl's conformance gate) detects and stops (its D10/§2.7); this
# file decides what to DO about a characterized finding — auto-fix it by
# authoring a scoped remediation package, route it to review ('justify'), or
# escalate to the ONE human decision this engine ever files (Decision #20).
#
# DESIGN (spec 08-auto-remediation-engine-spec.md):
#   - every DECISION function is PURE: no I/O, no globals, no clock reads,
#     never dies. plan() is the heart — decoded verdict + decoded queue +
#     context in, everything the caller must do out.
#   - every WRITE is atomic temp+rename and never dies (impure functions only).
#   - fail-closed throughout: a missing/unparseable input is never read as an
#     empty/passing state; a corrupt queue is never treated as an empty one
#     (that would silently reset the round counters and unbound the loop).
#   - no side effects at load: this file only DEFINES package BpRemediate and
#     ends in '1;'. It is required by bp-orchestrator.pl exactly the way
#     bp-judge.pl is, and is independently loadable/testable on its own.
#   - the ONLY dependency is JSON::PP. No shelling out of any kind: no system,
#     no exec, no backticks, no q-x-word-boundary-form (AC-28 scans this file
#     statically for those tokens), no piped open() — b07 authors ledgers for a
#     coordinator to execute; it never runs git, a build, or bp-deps-check.pl
#     itself (D11).
#
# require: require "<path>/bp-remediate.pl"; BpRemediate::plan(...)

package BpRemediate;
use strict;
use warnings;
use JSON::PP;

# ===========================================================================
# tiny local I/O primitives (no File::Basename/File::Path/Fcntl — only
# JSON::PP is a real "dependency"; these are built from Perl operators alone)
# ===========================================================================

sub _slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $txt = <$fh>;
    close $fh;
    return $txt;
}

sub _dirname {
    my ($path) = @_;
    return '.' unless defined $path && length $path;
    if ($path =~ m{^(.*)/[^/]+$}) { return length($1) ? $1 : '/'; }
    return '.';
}

sub _make_path {
    my ($dir) = @_;
    return unless defined $dir && length $dir;
    return if -d $dir;
    my @parts = split m{/}, $dir;
    my $cur = ($dir =~ m{^/}) ? '' : '.';
    for my $p (@parts) {
        next unless length $p;
        # An ABSOLUTE path starts this loop with $cur eq '', so the first
        # component must be re-rooted as "/$p" -- a bare "$p" silently drops the
        # leading slash and builds the whole tree RELATIVE to the cwd. Every
        # mkdir then "succeeds" somewhere useless and the caller's later
        # rename/open fails with nothing to trace it back to.
        $cur = ($cur eq '') ? "/$p" : "$cur/$p";
        mkdir $cur unless -d $cur;
    }
}

# ISO-8601 from an injected epoch (never wall-clock — deterministic tests).
sub _iso {
    my ($epoch) = @_;
    $epoch = 0 unless defined $epoch;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
                   $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub _slug {
    my ($s, $max) = @_;
    $s = '' unless defined $s;
    $s = lc $s;
    $s =~ s/[^a-z0-9]+/-/g;
    $s =~ s/^-+//; $s =~ s/-+$//;
    $s = substr($s, 0, ($max || 48));
    $s =~ s/-+$//;
    return length($s) ? $s : 'entry';
}

# deep clone via a JSON round-trip — every structure this file passes around
# is plain JSON-shaped data (hashrefs/arrayrefs/scalars), so this is a safe,
# dependency-free way to guarantee plan() never aliases the caller's queue.
sub _clone {
    my ($d) = @_;
    return $d unless ref $d;
    my $j = JSON::PP->new;
    return $j->decode($j->encode($d));
}

# ===========================================================================
# §2.2 — finding identity and signature (pure)
# ===========================================================================

sub finding_key {
    my ($f) = @_;
    $f = {} unless ref $f eq 'HASH';
    my $remedy   = (ref $f->{remedy}   eq 'HASH') ? $f->{remedy}   : {};
    my $evidence = (ref $f->{evidence} eq 'HASH') ? $f->{evidence} : {};

    # Build the candidate list with exists-guards and never let foreach alias a
    # hash element. the form 'for my $c ($h->{k})' ALIASES $h->{k}, and taking an alias to
    # a missing key AUTOVIVIFIES it -- so the old form silently mutated the very
    # finding it was inspecting, stamping an evidence.means => null key onto it. That
    # made finding_signature() of a "clean" verdict finding differ from the
    # signature stored when the entry was authored, so the NP-1 no-progress guard
    # could never see two identical signatures and a stalled remediation kept
    # opening fresh rounds. This function is documented as pure; keep it pure.
    my @cands;
    for my $key (qw(means runtime file ecosystem package)) {
        push @cands, $remedy->{$key} if exists $remedy->{$key};
    }
    push @cands, $evidence->{means} if exists $evidence->{means};
    push @cands, $evidence->{files}[0]
        if ref $evidence->{files} eq 'ARRAY' && @{ $evidence->{files} };

    my $discriminator = '';
    for my $cand (@cands) {
        if (defined $cand && !ref($cand) && length("$cand")) { $discriminator = "$cand"; last; }
    }

    my $kind    = (defined $f->{kind}    && !ref $f->{kind})    ? "$f->{kind}"    : '';
    my $subject = (defined $f->{subject} && !ref $f->{subject}) ? "$f->{subject}" : '';

    # Total emptiness (no identifying information at all) -> the literal
    # 'unclassified', regardless of the action fallback below — that fallback
    # exists only to disambiguate an otherwise-identical kind/subject/
    # discriminator triple by its remedy action, not to manufacture identity
    # out of nothing.
    return 'unclassified' if $kind eq '' && $subject eq '' && $discriminator eq '';

    my $action = (defined $remedy->{action} && !ref $remedy->{action} && length("$remedy->{action}"))
               ? "$remedy->{action}" : 'none';

    my $raw = join('-', $kind, $subject, $action, $discriminator);
    my $slug = lc $raw;
    $slug =~ s/[^a-z0-9]+/-/g;
    $slug =~ s/^-+//; $slug =~ s/-+$//;
    $slug = substr($slug, 0, 64);
    $slug =~ s/-+$//;
    return length($slug) ? $slug : 'unclassified';
}

sub finding_signature {
    my ($f) = @_;
    $f = {} unless ref $f eq 'HASH';
    my $obj = {
        kind     => (defined $f->{kind}    ? $f->{kind}    : undef),
        subject  => (defined $f->{subject} ? $f->{subject} : undef),
        detail   => (defined $f->{detail}  ? $f->{detail}  : undef),
        evidence => ((ref $f->{evidence} eq 'HASH' || ref $f->{evidence} eq 'ARRAY') ? $f->{evidence} : {}),
    };
    my $s = eval { JSON::PP->new->canonical->encode($obj) };
    return defined $s ? $s : '{}';
}

# ===========================================================================
# §2.4 — write-set resolution (the anti-deadlock ladder; pure)
# ===========================================================================

my %LOCKFILE_TABLE = (
    npm => 'package-lock.json', pnpm => 'pnpm-lock.yaml', yarn => 'yarn.lock',
    pip => 'requirements.txt',  cargo => 'Cargo.lock',    pub => 'pubspec.lock', go => 'go.sum',
);

# F1 (red-team): a write_set segment licenses ANOTHER agent's write scope —
# unlike this file's OWN output paths (author_ledger/rotate_verdict), a
# segment here is taken verbatim from evidence.files[]/remedy.file, which can
# be influenced by a conformance verdict a coordinator produced after reading
# repo content. Reject anything that could escape the repo or smuggle extra
# scope past a later per-element review:
#   - absolute paths ("/etc/...")            -> starts with '/'
#   - home expansion ("~/.claude/...")        -> starts with '~'
#   - traversal ("../../deploy_key")          -> a '..' path component
#   - colon smuggling ("a:b" -> two segments) -> contains ':'
#   - '.' / empty after normalization
# A segment that survives must be repo-relative and have at least one
# non-'.' path component.
sub _ws_segment_ok {
    my ($s) = @_;
    return 0 unless defined $s && !ref $s;
    return 0 unless length $s;
    return 0 if $s =~ /^\s*$/;
    return 0 if $s eq '/';
    return 0 if $s =~ m{^/};
    return 0 if $s =~ m{^~};
    return 0 if index($s, ':') >= 0;
    return 0 if $s eq '.';
    my @parts = split m{/}, $s;
    for my $p (@parts) { return 0 if $p eq '..'; }
    return 0 unless grep { length($_) && $_ ne '.' } @parts;
    return 1;
}

# join valid, deduped, contained segments with ':'. Returns undef when nothing
# survives — NEVER an empty or whitespace string (D2 / landmine 1: an empty
# write_set matches every running package's write set at _ws_prefixes('') and
# deadlocks the run).
sub _join_ws {
    my (@segs) = @_;
    my (@out, %seen);
    for my $s (@segs) {
        next unless _ws_segment_ok($s);
        next if $seen{$s}++;
        push @out, $s;
    }
    return @out ? join(':', @out) : undef;
}

sub write_set_for {
    my ($f, $ctx) = @_;
    $f   = {} unless ref $f   eq 'HASH';
    $ctx = {} unless ref $ctx eq 'HASH';
    my $remedy   = (ref $f->{remedy}   eq 'HASH') ? $f->{remedy}   : {};
    my $evidence = (ref $f->{evidence} eq 'HASH') ? $f->{evidence} : {};
    my $action = (defined $remedy->{action} && !ref $remedy->{action}) ? "$remedy->{action}" : '';

    # rung 1: evidence.files[] — every non-empty element, deduped, in order.
    if (ref $evidence->{files} eq 'ARRAY' && @{ $evidence->{files} }) {
        my $ws = _join_ws(@{ $evidence->{files} });
        return $ws if defined $ws;
    }

    # rung 2: action-specific.
    if ($action eq 'commit_lockfile') {
        my $ws = _join_ws($remedy->{file});
        return $ws if defined $ws;
    } elsif ($action eq 'create_lockfile') {
        my $eco = (defined $remedy->{ecosystem} && !ref $remedy->{ecosystem}) ? "$remedy->{ecosystem}" : '';
        if (exists $LOCKFILE_TABLE{$eco}) {
            my $lockfile = $LOCKFILE_TABLE{$eco};
            my $file0 = (ref $evidence->{files} eq 'ARRAY' && @{ $evidence->{files} }) ? $evidence->{files}[0] : undef;
            if (defined $file0 && !ref $file0 && $file0 =~ m{^(.*)/[^/]*$} && length($1)) {
                $lockfile = "$1/$lockfile";
            }
            my $ws = _join_ws($lockfile);
            return $ws if defined $ws;
        }
    } elsif ($action eq 'declare_backpack') {
        my $ws = _join_ws($ctx->{backpack_path});
        return $ws if defined $ws;
    } elsif ($action eq 'bump_runtime') {
        my $ws = _join_ws($remedy->{file});
        return $ws if defined $ws;
    }

    # rung 3: the offending package's own declared write_set.
    my $subject = (defined $f->{subject} && !ref $f->{subject}) ? "$f->{subject}" : undef;
    if (defined $subject && ref $ctx->{pkg_write_sets} eq 'HASH' && exists $ctx->{pkg_write_sets}{$subject}) {
        my $ws = _join_ws($ctx->{pkg_write_sets}{$subject});
        return $ws if defined $ws;
    }

    # rung 4: escalate — never an empty/invented string.
    return undef;
}

# ===========================================================================
# §2.3 — dispatch table (the SYN-6 safety line; pure, total, never dies)
# ===========================================================================

sub _is_scheduling_state_kind {
    my ($kind) = @_;
    # closed, named set -- the ONLY member observed anywhere in the codebase
    # (bp-orchestrator.pl:3778, dag_stall_step's synthetic finding). Extend by
    # adding to this set; never by pattern-matching kind text. This is a
    # SAFETY gate (deciding "must not be routed as a defect"), so matching
    # a near-miss (surrounding whitespace, differing case) is the fail-closed
    # direction -- a stray space or a capitalised variant must still be
    # caught, not waved through as an ordinary code defect.
    return 0 unless defined $kind && !ref $kind;
    my $k = "$kind";
    $k =~ s/^\s+|\s+$//g;
    return (lc($k) eq 'dag-stall') ? 1 : 0;
}

sub _test_paths_ok {
    my ($ctx) = @_;
    return 0 unless ref $ctx eq 'HASH';
    my $tp = $ctx->{test_paths};
    return (defined $tp && !ref $tp && "$tp" =~ /\S/) ? 1 : 0;
}

# Guards every value ledger_text() interpolates into the '---' YAML
# frontmatter block: a newline or carriage return would inject an extra
# 'key: value' line, and a value that (after trimming) starts with '---'
# could forge a block boundary. See ledger_text's own comment for why this
# is a refusal, not an escape.
sub _fm_value_ok {
    my ($v) = @_;
    return 0 unless defined $v && !ref $v;
    my $s = "$v";
    return 0 if $s =~ /[\r\n]/;
    (my $trimmed = $s) =~ s/^\s+//;
    return 0 if $trimmed =~ /^---/;
    return 1;
}

sub classify_finding {
    my ($f, $ctx) = @_;
    $f   = {} unless ref $f   eq 'HASH';
    $ctx = {} unless ref $ctx eq 'HASH';
    my $remedy = $f->{remedy};
    unless (ref $remedy eq 'HASH') {
        return { disposition => 'escalate', action => undef, reason => 'unfixable' };
    }
    my $action = (defined $remedy->{action} && !ref $remedy->{action} && length("$remedy->{action}"))
               ? "$remedy->{action}" : undef;
    unless (defined $action) {
        return { disposition => 'escalate', action => $action, reason => 'unfixable' };
    }

    # A scheduling state (a DAG stall) is not a code defect -- refuse before
    # any per-action dispatch, regardless of how resolvable its remedy looks.
    if (_is_scheduling_state_kind($f->{kind})) {
        return { disposition => 'escalate', action => $action, reason => 'scheduling_state' };
    }

    my $result;
    if ($action eq 'bump_runtime') {
        my $to = $remedy->{to};
        $result = (defined $to && !ref $to && length("$to"))
            ? { disposition => 'auto', action => $action, reason => '' }
            : { disposition => 'escalate', action => $action, reason => 'ambiguous' };
    }
    elsif ($action eq 'declare_backpack') {
        my $ws = write_set_for($f, $ctx);
        $result = defined $ws ? { disposition => 'auto', action => $action, reason => '' }
                               : { disposition => 'escalate', action => $action, reason => 'unscopable' };
    }
    elsif ($action eq 'create_lockfile') {
        my $ws = write_set_for($f, $ctx);
        $result = defined $ws ? { disposition => 'auto', action => $action, reason => '' }
                               : { disposition => 'escalate', action => $action, reason => 'ambiguous' };
    }
    elsif ($action eq 'commit_lockfile') {
        my $file = $remedy->{file};
        $result = (defined $file && !ref $file && length("$file"))
            ? { disposition => 'auto', action => $action, reason => '' }
            : { disposition => 'escalate', action => $action, reason => 'unscopable' };
    }
    elsif ($action eq 'remediate-conformance') {
        my $means = $remedy->{means};
        unless (defined $means && !ref $means && "$means" =~ /\S/) {
            $result = { disposition => 'escalate', action => $action, reason => 'means_missing' };
        }
        else {
            my $ws = write_set_for($f, $ctx);
            $result = defined $ws ? { disposition => 'auto', action => $action, reason => '' }
                                   : { disposition => 'escalate', action => $action, reason => 'unscopable' };
        }
    }
    elsif ($action eq 'remediate-build') {
        my $ws = write_set_for($f, $ctx);
        $result = defined $ws ? { disposition => 'auto', action => $action, reason => '' }
                               : { disposition => 'escalate', action => $action, reason => 'unscopable' };
    }
    elsif ($action eq 'justify') {
        $result = { disposition => 'review', action => $action, reason => '' };
    }
    elsif ($action eq 'none') {
        $result = { disposition => 'escalate', action => $action, reason => 'unfixable' };
    }
    else {
        # unrecognized action — fail-closed (D4).
        $result = { disposition => 'escalate', action => $action, reason => 'unfixable' };
    }

    # Uniform post-check, applied after ANY action resolves to 'auto': a
    # package that will not know what to run/verify against is unsatisfiable
    # no matter how resolvable its write_set/means looked.
    if (($result->{disposition} // '') eq 'auto' && !_test_paths_ok($ctx)) {
        $result = { disposition => 'escalate', action => $action, reason => 'test_paths_unresolved' };
    }

    return $result;
}

# ===========================================================================
# §2.1 — package id (pure)
# ===========================================================================

sub package_id {
    my ($finding_key, $round) = @_;
    $finding_key = 'unclassified' unless defined $finding_key && length $finding_key;
    $round = 1 unless defined $round && "$round" =~ /^\d+$/;
    my $prefix = 'remediation-';
    my $suffix = "-r$round";
    my $max = 96;
    my $budget = $max - length($prefix) - length($suffix);
    $budget = 1 if $budget < 1;
    my $key = $finding_key;
    $key = substr($key, 0, $budget) if length($key) > $budget;
    $key =~ s/-+$//;
    $key = 'x' unless length $key;
    return "$prefix$key$suffix";
}

# source classification (§2.1): deps-check BLOCK kinds (preserved verbatim by
# fold_deps_check, bp-judge.pl:341) vs everything else (conformance).
sub _source_for {
    my ($f) = @_;
    my $kind = (ref $f eq 'HASH' && defined $f->{kind} && !ref $f->{kind}) ? "$f->{kind}" : '';
    return 'deps' if $kind =~ /^(?:eol_runtime|undeclared_runtime|lockfile_missing|lockfile_uncommitted)$/;
    return 'conformance';
}

sub _mandated_means_for {
    my ($action, $finding) = @_;
    my $remedy = (ref $finding eq 'HASH' && ref $finding->{remedy} eq 'HASH') ? $finding->{remedy} : {};
    if (($action // '') eq 'remediate-conformance' && defined $remedy->{means} && !ref $remedy->{means} && length("$remedy->{means}")) {
        return [ "$remedy->{means}" ];
    }
    return [];
}

# Build a brand-new, fully-populated entry object (§2.1). Never writes.
sub _build_entry {
    my ($a) = @_;
    my $id      = $a->{id};
    my $action  = defined $a->{action} ? $a->{action} : 'none';
    my $finding = (ref $a->{finding} eq 'HASH') ? _clone($a->{finding}) : {};
    my $ctx     = (ref $a->{ctx} eq 'HASH') ? $a->{ctx} : {};
    return {
        id                => $id,
        finding_key       => $a->{finding_key},
        round             => $a->{round},
        max_rounds        => $a->{max_rounds},
        source            => ($a->{source} // 'conformance'),
        action            => $action,
        disposition       => 'auto',
        state             => 'queued',
        pkg_status        => 'pending',
        ledger_path       => "packages/$id.md",
        write_set         => $a->{write_set},
        test_paths        => $ctx->{test_paths},
        deps              => (ref $a->{deps} eq 'ARRAY' ? [ @{ $a->{deps} } ] : []),
        model             => ($ctx->{model} // 'sonnet'),
        max_turns         => ($ctx->{max_turns} // 60),
        mandated_means    => _mandated_means_for($action, $finding),
        signature         => $a->{signature},
        finding           => $finding,
        created_at        => $a->{now_iso},
        updated_at        => $a->{now_iso},
        history           => [ { round => $a->{round}, at => $a->{now_iso}, event => 'authored', signature => $a->{signature} } ],
        escalation_reason => undef,
    };
}

# ===========================================================================
# §2.1 — queue lifecycle: fresh / shape validation (pure)
# ===========================================================================

sub queue_new {
    my ($ctx) = @_;
    $ctx = {} unless ref $ctx eq 'HASH';
    my $iso = defined $ctx->{iso} ? $ctx->{iso} : _iso($ctx->{now});
    my $cap = (defined $ctx->{cap} && "$ctx->{cap}" =~ /^\d+$/) ? $ctx->{cap} + 0 : 6;
    return {
        schema       => 'remediation-queue/1',
        generated_at => $iso,
        project      => (defined $ctx->{blueprint} ? $ctx->{blueprint} : ''),
        rounds_used  => 0,
        rounds_cap   => $cap,
        gate_firings => 0,
        last_verdict => undef,
        entries      => [],
        escalated    => [],
        notes        => [],
    };
}

my @ENTRY_MANDATORY_KEYS = qw(
    id finding_key round max_rounds source action disposition state
    pkg_status ledger_path write_set test_paths deps model max_turns
    mandated_means signature finding created_at updated_at history
);

sub queue_ok {
    my ($q) = @_;
    return 0 unless ref $q eq 'HASH';
    return 0 if $q->{_corrupt};
    return 0 unless defined $q->{schema} && $q->{schema} eq 'remediation-queue/1';
    return 0 unless ref $q->{entries} eq 'ARRAY';
    return 0 unless defined $q->{rounds_used} && !ref($q->{rounds_used}) && "$q->{rounds_used}" =~ /^\d+$/;
    for my $e (@{ $q->{entries} }) {
        return 0 unless ref $e eq 'HASH';
        for my $k (@ENTRY_MANDATORY_KEYS) {
            return 0 unless exists $e->{$k};
        }
        # F2/F5: presence alone is not enough. An empty/whitespace/ref-valued
        # write_set survives an exists-only check and then merge_queue skips
        # the entry FOREVER (silent, permanent verify_ready=0/outstanding=1
        # deadlock — bp-orchestrator.pl:2085/:2096 discards @skipped). A
        # non-ARRAY history is worse: push @{ $e->{history} }, {...} inside
        # plan() dies under strict refs, which propagates out of the
        # un-eval'd remediation_step and kills the whole orchestrator tick.
        # Type-check every load-bearing key so either class routes into the
        # existing §3.8 fail-closed branch instead.
        return 0 unless defined $e->{write_set} && !ref($e->{write_set}) && $e->{write_set} =~ /\S/;
        for my $k (qw(id state round signature)) {
            return 0 if ref $e->{$k};
        }
        return 0 unless ref $e->{history} eq 'ARRAY';
    }
    return 1;
}

# ===========================================================================
# §3.1 — merge_queue (pure): DAG-append merge into %meta/%status, plus the
# on-disk-ledger-status resync that drives the queued -> awaiting_verify /
# queued -> escalated(remediation_not_done) transitions (§2.5).
# ===========================================================================

sub merge_queue {
    my ($queue, $meta, $status, $ledger_status) = @_;
    $meta   ||= {};
    $status ||= {};
    $ledger_status ||= {};
    my (@merged, @skipped, @transitioned);
    my @entries = (ref $queue eq 'HASH' && ref $queue->{entries} eq 'ARRAY') ? @{ $queue->{entries} } : ();

    for my $e (@entries) {
        next unless ref $e eq 'HASH';
        my $id = $e->{id};
        next unless defined $id && length $id;

        # Resync entry.state against the on-disk ledger status (§2.5). This is
        # the ONLY place b07 observes real package completion. A blocked/
        # parked/dropped remediation package is marked escalated here (pure,
        # no notice) — the pre-existing awaiting_human/orphan_escalations
        # machinery already surfaces it to a human independently (spec §8.4).
        my $lst = $ledger_status->{$id};
        if (defined $lst && length $lst && (($e->{state} // '') eq 'queued')) {
            if ($lst eq 'done') {
                $e->{state} = 'awaiting_verify';
                push @transitioned, $id;
            } elsif ($lst =~ /^(?:dropped|blocked|parked)$/) {
                $e->{state} = 'escalated';
                $e->{escalation_reason} = 'remediation_not_done';
            }
        }

        # A no_package entry is BOOKKEEPING, not a package. It exists so
        # %tracked remembers "asked and refused" and the finding cannot
        # re-escalate every ingestion; it has no ledger and no write set, by
        # construction (_escalate_new sets write_set => 'n/a' precisely because
        # there is nothing to write).
        #
        # It must never enter %meta. 'n/a' is non-empty, so it slipped past the
        # empty_write_set skip below and was merged with pkg_status 'done' --
        # and a done package is one the orchestrator asks a harvest judge to
        # verify. The judge cannot start (no ledger), the spawn cap eventually
        # fires, and _block_and_queue files a harvest-spawn-failure naming an id
        # that by construction has no ledger. Every bp-answer-decision.pl action
        # (accept/drop/relaunch) resolves the ledger first and fail-closes, and
        # `acknowledge` is only available to pseudo-packages, so the operator is
        # left with a queue entry only hand-deletion can clear -- which the
        # reporter protocol forbids. Almanac 20260824-100216-4ec2.
        if ($e->{no_package}) {
            push @skipped, { id => $id, reason => 'no_package' };
            next;
        }

        my $ws = $e->{write_set};
        if (!defined $ws || !length($ws) || $ws =~ /^\s*$/) {
            push @skipped, { id => $id, reason => 'empty_write_set' };
            next;
        }
        if (exists $meta->{$id}) {
            push @skipped, { id => $id, reason => 'already_exists' };
            next;
        }
        $meta->{$id} = {
            deps        => (ref $e->{deps} eq 'ARRAY' ? [ @{ $e->{deps} } ] : []),
            write_set   => $ws,
            remediation => 1,
            finding_key => $e->{finding_key},
        };
        my $st = (defined $lst && length $lst) ? $lst : $e->{pkg_status};
        $st = 'pending' unless defined $st && length $st;
        # An entry past 'queued' has already had its remediation package run to
        # completion -- that transition is exactly what moved it to
        # awaiting_verify/terminal. It must never look launchable again: a stale
        # pkg_status of 'pending' makes ready_packages relaunch it every tick, so
        # $any_running never falls to 0, the conformance gate never fires, and the
        # verification pass that would retire the entry can never run. Keep it in
        # %meta (the remediation flag is what excludes it from conformance_registry)
        # but report it as finished.
        $st = 'done' if ($e->{state} // '') ne 'queued' && $st eq 'pending';
        $status->{$id} = $st;
        push @merged, $id;
    }
    return { merged => \@merged, skipped => \@skipped, transitioned => \@transitioned };
}

# ===========================================================================
# §3.2 / §3.4 — the two flags the orchestrator threads through run_complete
# and the gate's fire condition (pure)
# ===========================================================================

sub remediation_outstanding {
    my ($q) = @_;
    return 0 unless ref $q eq 'HASH' && ref $q->{entries} eq 'ARRAY';
    for my $e (@{ $q->{entries} }) {
        next unless ref $e eq 'HASH';
        my $s = $e->{state} // '';
        return 1 if $s eq 'queued' || $s eq 'awaiting_verify';
    }
    return 0;
}

sub verify_ready {
    my ($q) = @_;
    return 1 unless ref $q eq 'HASH' && ref $q->{entries} eq 'ARRAY';
    for my $e (@{ $q->{entries} }) {
        next unless ref $e eq 'HASH';
        return 0 if (($e->{state} // '') eq 'queued');
    }
    return 1;
}

# ===========================================================================
# escalation helper (internal; used only inside plan())
# ===========================================================================

sub _escalate_entry {
    my ($e, $reason, $now_iso, $notices, $escalate, $nq) = @_;
    $e->{state}             = 'escalated';
    $e->{escalation_reason} = $reason;
    $e->{updated_at}        = $now_iso;
    push @{ $e->{history} }, { round => $e->{round}, at => $now_iso, event => 'escalated', signature => $e->{signature} };
    my $fdata = (ref $e->{finding} eq 'HASH') ? $e->{finding} : {};
    push @$escalate, {
        finding_key       => $e->{finding_key},
        kind              => $fdata->{kind},
        subject           => $fdata->{subject},
        detail            => $fdata->{detail},
        action            => $e->{action},
        escalation_reason => $reason,
        rounds_used       => $nq->{rounds_used},
        evidence          => (ref $fdata->{evidence} eq 'HASH' ? $fdata->{evidence} : {}),
    };
    push @$notices, {
        subject  => 'remediation escalated',
        detail   => "finding '" . ($e->{finding_key} // '') . "' escalated ($reason)",
        severity => 'warn',
        evidence => { finding_key => $e->{finding_key}, escalation_reason => $reason },
    };
    push @{ $nq->{escalated} }, $e->{finding_key}
        unless grep { $_ eq ($e->{finding_key} // '') } @{ $nq->{escalated} };
}

sub _escalate_new_finding {
    my ($f, $k, $reason, $rounds_used, $notices, $escalate, $nq, $now_iso, $ctx, $sig) = @_;
    push @$escalate, {
        finding_key       => $k,
        kind              => $f->{kind},
        subject           => $f->{subject},
        detail            => $f->{detail},
        action            => (ref $f->{remedy} eq 'HASH' ? $f->{remedy}{action} : undef),
        escalation_reason => $reason,
        rounds_used       => $rounds_used,
        evidence          => (ref $f->{evidence} eq 'HASH' ? $f->{evidence} : {}),
    };
    push @$notices, {
        subject  => 'remediation escalated',
        detail   => "finding '$k' escalated ($reason)",
        severity => 'warn',
        evidence => { finding_key => $k, escalation_reason => $reason },
    };
    push @{ $nq->{escalated} }, $k unless grep { $_ eq $k } @{ $nq->{escalated} };

    # F6 (red-team): without a PERSISTED entry, %tracked (rebuilt from
    # $nq->{entries} at the top of the NEXT plan() call) never sees this
    # finding_key, so an unfixable/unscopable/capped-out NEW finding
    # re-escalates on every subsequent ingestion — unbounded runs/notices/
    # growth and a decision the operator can never dismiss (F4's exact
    # inverse, from the same asymmetry: entry-sourced escalations already
    # go terminal via _escalate_entry; this path did not). Append a
    # terminal, bookkeeping-only entry so it is tracked from here on.
    # no_package=>1 tells merge_queue (bp-orchestrator.pl:conformance_registry
    # never sees it either, same as any other remediation=>1 exclusion) that
    # this id maps to NO ledger and NO write_set — there is none, this finding
    # was never auto-fixable — so it must never be treated as launchable.
    # No rounds_used increment: this is not a round opened, it is a permanent
    # record of "asked and refused".
    my $entry = _build_entry({
        id => package_id($k, 1), finding_key => $k, round => 1,
        max_rounds => (defined $ctx && ref $ctx eq 'HASH' && $ctx->{rounds}) ? $ctx->{rounds} : 2,
        source => _source_for($f),
        action => (ref $f->{remedy} eq 'HASH' ? $f->{remedy}{action} : undef),
        write_set => 'n/a', deps => [], finding => $f, signature => $sig,
        now_iso => (defined $now_iso ? $now_iso : _iso(undef)), ctx => (ref $ctx eq 'HASH' ? $ctx : {}),
    });
    $entry->{state}             = 'escalated';
    $entry->{escalation_reason} = $reason;
    $entry->{pkg_status}        = 'done';
    $entry->{no_package}        = 1;
    return $entry;
}

# ===========================================================================
# §2.10 — plan(): the pure decision heart
# ===========================================================================

sub plan {
    my ($verdict, $queue, $ctx) = @_;
    $ctx = {} unless ref $ctx eq 'HASH';
    my $now_iso = defined $ctx->{iso} ? $ctx->{iso} : _iso($ctx->{now});
    my $cap     = (defined $ctx->{cap}    && "$ctx->{cap}"    =~ /^\d+$/) ? $ctx->{cap}    + 0 : 6;
    my $rounds_default = (defined $ctx->{rounds} && "$ctx->{rounds}" =~ /^\d+$/) ? $ctx->{rounds} + 0 : 2;

    # ---- step 1: corrupt queue — fail-closed, never treated as empty (D5) --
    my $corrupt = (ref $queue ne 'HASH') || $queue->{_corrupt} || !queue_ok($queue);
    if ($corrupt) {
        my $nq = queue_new($ctx);
        $nq->{rounds_used} = $nq->{rounds_cap};   # reduce, never reset, the remaining budget
        $nq->{escalated}   = [ 'queue-corrupt' ];
        my @notices = ( {
            subject  => 'remediation queue corrupt',
            detail   => 'runs/remediation-queue.json was unreadable or failed shape validation; treated fail-closed, never as empty',
            severity => 'warn',
            evidence => {},
        } );
        my @escalate = ( {
            finding_key       => 'queue-corrupt',
            kind              => undef,
            subject           => '_remediation',
            detail            => 'the remediation queue could not be trusted and was reset fail-closed',
            action            => undef,
            escalation_reason => 'queue_corrupt',
            rounds_used       => $nq->{rounds_used},
            evidence          => {},
        } );
        return { queue => $nq, author => [], notices => \@notices, reviews => [],
                 escalate => \@escalate, rotate => 0, outstanding => remediation_outstanding($nq) };
    }

    my $nq = _clone($queue);
    $nq->{generated_at} = $now_iso;
    $nq->{rounds_cap}   = $cap;
    $nq->{entries}   = [] unless ref $nq->{entries}   eq 'ARRAY';
    $nq->{escalated} = [] unless ref $nq->{escalated} eq 'ARRAY';
    $nq->{notes}     = [] unless ref $nq->{notes}     eq 'ARRAY';
    my @entries = @{ $nq->{entries} };

    my (@notices, @reviews, @escalate, @author);
    my $rotate = 0;

    # ---- step 2: verdict shape guard --------------------------------------
    my $v = (ref $verdict eq 'HASH') ? $verdict : {};
    my $outcome = (defined $v->{outcome} && !ref $v->{outcome}) ? lc("$v->{outcome}") : '';
    my $outcome_ok = ($outcome eq 'pass' || $outcome eq 'fail' || $outcome eq 'error');
    if (!$outcome_ok || $outcome eq 'error') {
        push @notices, {
            subject  => 'remediation verdict not actionable',
            detail   => (!$outcome_ok
                ? 'the conformance verdict outcome was missing or unrecognized; nothing to remediate or verify'
                : 'the conformance verdict outcome is error; nothing to remediate or verify yet'),
            severity => 'warn',
            evidence => { outcome => (defined $v->{outcome} ? $v->{outcome} : undef) },
        };
        $nq->{entries} = \@entries;
        return { queue => $nq, author => [], notices => \@notices, reviews => [],
                 escalate => [], rotate => 0, outstanding => remediation_outstanding($nq) };
    }

    my $findings_ok = (ref $v->{findings} eq 'ARRAY') ? 1 : 0;
    my @findings = $findings_ok ? @{ $v->{findings} } : ();
    unless ($findings_ok) {
        push @notices, {
            subject  => 'remediation verdict findings malformed',
            detail   => 'the conformance verdict findings field was not an array; treated as zero findings',
            severity => 'warn',
            evidence => {},
        };
    }

    # ---- step 3: recursion refusal (D9) ------------------------------------
    my %existing_ids = map { $_->{id} => 1 } grep { ref $_ eq 'HASH' && defined $_->{id} } @entries;
    my @clean;
    for my $f (@findings) {
        next unless ref $f eq 'HASH';
        my $subject = (defined $f->{subject} && !ref $f->{subject}) ? "$f->{subject}" : '';
        if ($subject =~ /^remediation-/ || $existing_ids{$subject}) {
            push @notices, {
                subject  => 'remediation recursion refused',
                detail   => "finding subject '$subject' names a remediation package; refused (no recursive remediation)",
                severity => 'warn',
                evidence => { subject => $subject },
            };
            next;
        }
        push @clean, $f;
    }

    # precompute (finding, key, signature) once per clean finding.
    my @fk = map { { f => $_, key => finding_key($_), sig => finding_signature($_) } } @clean;
    my %by_key;
    for my $x (@fk) { push @{ $by_key{ $x->{key} } }, $x; }

    # An entry's MATCH key is recomputed from the entry's OWN stored finding
    # whenever it has one, falling back to the stored finding_key. In normal
    # operation the two are identical (plan() stamps the computed key at
    # authoring time), but recomputing is what makes re-verification robust: the
    # live verdict's copy of the same defect is passed through the very same
    # finding_key(), so the two sides always agree. Matching on a stored
    # shorthand key instead silently fails to find the entry, which marks a
    # still-broken finding 'verified' AND lets the new-findings path author a
    # duplicate round-1 entry for the same defect.
    my $match_key = sub {
        my ($e) = @_;
        return undef unless ref $e eq 'HASH';
        if (ref $e->{finding} eq 'HASH') {
            my $k = finding_key($e->{finding});
            return $k if defined $k && length $k && $k ne 'unclassified';
        }
        return $e->{finding_key};
    };

    # finding_keys already tracked by ANY entry (any round/state) are never
    # "new" again — this is what keeps a persistently-failing finding from
    # being re-authored every tick (bounded rounds, §3.7).
    my %tracked;
    for my $e (@entries) {
        next unless ref $e eq 'HASH';
        my $k = $match_key->($e);
        $tracked{$k} = 1 if defined $k;
        $tracked{$e->{finding_key}} = 1 if defined $e->{finding_key};
    }

    # only the HIGHEST round for a finding_key is ever "live" for verify-pass /
    # regression-check purposes — an older round superseded by a newer one is
    # excluded from both (it was already marked escalated/superseded below).
    my %max_round_for_key;
    for my $e (@entries) {
        next unless ref $e eq 'HASH';
        my $k = $match_key->($e);
        next unless defined $k;
        my $r = $e->{round} // 0;
        $max_round_for_key{$k} = $r if !exists $max_round_for_key{$k} || $r > $max_round_for_key{$k};
    }
    my $is_live = sub {
        my ($e) = @_;
        my $k = $match_key->($e);
        return 1 unless defined $k;
        return (($e->{round} // 0) >= ($max_round_for_key{$k} // 0)) ? 1 : 0;
    };

    # ---- step 4: verification pass over awaiting_verify entries (§3.6) -----
    my @snapshot_awaiting = grep { ref $_ eq 'HASH' && ($_->{state} // '') eq 'awaiting_verify' && $is_live->($_) } @entries;
    my @new_from_verify;
    for my $e (@snapshot_awaiting) {
        my $k = $match_key->($e);
        my $matches = $by_key{$k} || [];

        if (!@$matches) {
            # finding_key absent from this verdict -> verified (terminal).
            $e->{state}      = 'verified';
            $e->{updated_at} = $now_iso;
            push @{ $e->{history} }, { round => $e->{round}, at => $now_iso, event => 'verify_pass', signature => $e->{signature} };
            push @notices, {
                subject  => 'remediation verified',
                detail   => "finding '$k' is no longer present in the conformance verdict",
                severity => 'info',
                evidence => { finding_key => $k, package => $e->{id} },
            };
            next;
        }

        my $match  = $matches->[0];
        my $newsig = $match->{sig};

        # NP-1: byte-identical signature -> no observable progress; escalate
        # immediately, without consuming the remaining round budget.
        if ($newsig eq ($e->{signature} // '')) {
            _escalate_entry($e, 'no_progress', $now_iso, \@notices, \@escalate, $nq);
            next;
        }
        # (i) round budget for this finding.
        if (!( ($e->{round} // 0) < ($e->{max_rounds} // $rounds_default) )) {
            _escalate_entry($e, 'rounds_exhausted', $now_iso, \@notices, \@escalate, $nq);
            next;
        }
        # (ii) global cap.
        if (!( ($nq->{rounds_used} // 0) < $cap )) {
            _escalate_entry($e, 'global_cap', $now_iso, \@notices, \@escalate, $nq);
            next;
        }
        # progress + budget: open the next round for a re-classified,
        # re-scoped version of the SAME finding.
        my $newf = $match->{f};
        my $cls  = classify_finding($newf, $ctx);
        if (($cls->{disposition} // '') ne 'auto') {
            _escalate_entry($e, ($cls->{reason} || 'unfixable'), $now_iso, \@notices, \@escalate, $nq);
            next;
        }
        my $ws = write_set_for($newf, $ctx);
        unless (defined $ws) {
            _escalate_entry($e, 'unscopable', $now_iso, \@notices, \@escalate, $nq);
            next;
        }

        my $next_round = ($e->{round} // 0) + 1;
        my $new_id = package_id($k, $next_round);
        my $new_entry = _build_entry({
            id => $new_id, finding_key => $k, round => $next_round, max_rounds => ($e->{max_rounds} // $rounds_default),
            source => $e->{source}, action => $cls->{action}, write_set => $ws, deps => [ $e->{id} ],
            finding => $newf, signature => $newsig, now_iso => $now_iso, ctx => $ctx,
        });
        push @new_from_verify, $new_entry;
        push @author, $new_entry;
        push @notices, {
            subject  => 'remediation package authored',
            detail   => "round $next_round authored for finding '$k'",
            severity => 'info',
            evidence => { finding_key => $k, action => $new_entry->{action}, package => $new_id,
                          write_set => $ws, round => $next_round, max_rounds => $new_entry->{max_rounds},
                          files => [ split /:/, $ws ] },
        };
        $nq->{rounds_used} = ($nq->{rounds_used} // 0) + 1;

        # the superseded (old-round) entry: terminal, but purely internal
        # bookkeeping — never a user-facing escalation (no entry in
        # escalate[]/queue.escalated/notices) and never re-checked for
        # regression (regression-check only scans state=='verified').
        $e->{state}             = 'escalated';
        $e->{escalation_reason} = 'superseded';
        $e->{updated_at}        = $now_iso;
    }
    push @entries, @new_from_verify;

    # ---- step 5: regression check over (live) verified entries ------------
    my @snapshot_verified = grep { ref $_ eq 'HASH' && ($_->{state} // '') eq 'verified' && $is_live->($_) } @entries;
    for my $e (@snapshot_verified) {
        my $k = $match_key->($e);
        my $matches = $by_key{$k} || [];
        next unless @$matches;
        _escalate_entry($e, 'regressed', $now_iso, \@notices, \@escalate, $nq);
    }

    # ---- step 6: new findings ----------------------------------------------
    my %seen_this_call;
    for my $x (@fk) {
        my $k = $x->{key};
        next if $tracked{$k};
        next if $seen_this_call{$k}++;   # two findings collapsing to one key -> one entry (§5)
        my $f = $x->{f};
        my $cls = classify_finding($f, $ctx);
        my $disp = $cls->{disposition} // 'escalate';

        if ($disp eq 'review') {
            push @reviews, $f;
            next;
        }
        if ($disp ne 'auto') {
            push @entries, _escalate_new_finding($f, $k, ($cls->{reason} || 'unfixable'), ($nq->{rounds_used} // 0),
                \@notices, \@escalate, $nq, $now_iso, $ctx, $x->{sig});
            next;
        }
        unless ( ($nq->{rounds_used} // 0) < $cap ) {
            push @entries, _escalate_new_finding($f, $k, 'global_cap', ($nq->{rounds_used} // 0),
                \@notices, \@escalate, $nq, $now_iso, $ctx, $x->{sig});
            next;
        }
        my $ws = write_set_for($f, $ctx);
        unless (defined $ws) {
            push @entries, _escalate_new_finding($f, $k, 'unscopable', ($nq->{rounds_used} // 0),
                \@notices, \@escalate, $nq, $now_iso, $ctx, $x->{sig});
            next;
        }

        my $new_entry = _build_entry({
            id => package_id($k, 1), finding_key => $k, round => 1, max_rounds => $rounds_default,
            source => _source_for($f), action => $cls->{action}, write_set => $ws, deps => [],
            finding => $f, signature => $x->{sig}, now_iso => $now_iso, ctx => $ctx,
        });
        push @entries, $new_entry;
        push @author, $new_entry;
        push @notices, {
            subject  => 'remediation package authored',
            detail   => "round 1 authored for finding '$k'",
            severity => 'info',
            evidence => { finding_key => $k, action => $new_entry->{action}, package => $new_entry->{id},
                          write_set => $ws, round => 1, max_rounds => $rounds_default, files => [ split /:/, $ws ] },
        };
        $nq->{rounds_used} = ($nq->{rounds_used} // 0) + 1;
        $tracked{$k} = 1;
    }

    $nq->{entries} = \@entries;
    $nq->{last_verdict} = {
        generated_at => (defined $v->{generated_at} ? $v->{generated_at} : ''),
        outcome      => $outcome,
        finding_keys => [ sort keys %{ { map { $_->{key} => 1 } @fk } } ],
        findings     => scalar(@clean),
    };

    return { queue => $nq, author => \@author, notices => \@notices, reviews => \@reviews,
             escalate => \@escalate, rotate => $rotate, outstanding => remediation_outstanding($nq) };
}

# ===========================================================================
# §2.11 — ledger_text / author_ledger
# ===========================================================================

my %REMEDY_SUMMARY = (
    bump_runtime         => sub { my $r = shift; 'bump ' . ($r->{runtime} // 'the runtime') . ' to ' . ($r->{to} // 'its LTS successor') },
    declare_backpack     => sub { my $r = shift; 'declare ' . ($r->{runtime} // 'the runtime') . ' in the backpack' },
    create_lockfile      => sub { my $r = shift; 'generate the ' . ($r->{ecosystem} // '') . ' lockfile' },
    commit_lockfile      => sub { my $r = shift; 'commit ' . ($r->{file} // 'the lockfile') },
    'remediate-conformance' => sub { my ($r, $f) = @_; 'use mandated means ' . ($r->{means} // '') . ' in ' . ($r->{package} // ($f->{subject} // 'the package')) },
    'remediate-build'    => sub { 'fix the build' },
);

sub _remedy_summary {
    my ($action, $f) = @_;
    my $remedy = (ref $f eq 'HASH' && ref $f->{remedy} eq 'HASH') ? $f->{remedy} : {};
    my $gen = $REMEDY_SUMMARY{$action // ''};
    return $gen ? $gen->($remedy, $f) : 'remediate finding';
}

# §3.9 — the mechanical remedy sentence (used for BOTH Done criteria and Next
# action, per the template's shared substance).
sub _remedy_sentence {
    my ($action, $f) = @_;
    my $remedy = (ref $f eq 'HASH' && ref $f->{remedy} eq 'HASH') ? $f->{remedy} : {};
    if (($action // '') eq 'bump_runtime') {
        my $runtime = $remedy->{runtime} // 'the runtime';
        my $from    = $remedy->{from}    // 'the old version';
        my $to      = $remedy->{to}      // 'the LTS successor';
        return "Replace runtime $runtime $from with $to in every file in write_set; $to is the LTS successor named by the finding. Do not choose a different version.";
    }
    if (($action // '') eq 'declare_backpack') {
        my $runtime = $remedy->{runtime} // 'the runtime';
        return "Declare runtime $runtime in the backpack (/backpack:add) with a one-line rationale, so a container rebuild restores it.";
    }
    if (($action // '') eq 'create_lockfile') {
        my $eco = $remedy->{ecosystem} // 'the';
        return "Generate the $eco lockfile from the existing manifest; do not add, remove or upgrade dependencies while doing so.";
    }
    if (($action // '') eq 'commit_lockfile') {
        my $file = $remedy->{file} // 'the lockfile';
        return "Ensure $file is present and tracked. Git may be unavailable in this container — if git cannot run, record that fact in the ledger's attempt log and stop; do not fabricate a commit.";
    }
    if (($action // '') eq 'remediate-conformance') {
        my $means = $remedy->{means} // 'the mandated means';
        my $pkg   = $remedy->{package} // ($f->{subject} // 'this package');
        return "Actually use the mandated means $means in $pkg\'s code (present and wired, not a hand-rolled substitute), touching only write_set. mandated_means: of this ledger is [$means].";
    }
    if (($action // '') eq 'remediate-build') {
        return "Make the build green for the files in write_set; do not widen scope, do not disable checks or tests.";
    }
    return "Close the finding within write_set; do not widen scope.";
}

sub ledger_text {
    my ($entry, $ctx) = @_;
    $entry = {} unless ref $entry eq 'HASH';
    $ctx   = {} unless ref $ctx   eq 'HASH';

    my $id         = defined $entry->{id} ? $entry->{id} : 'remediation-unknown-r1';
    my $bp         = defined $ctx->{blueprint} ? $ctx->{blueprint} : '';
    my $model      = defined $entry->{model}      ? $entry->{model}      : ($ctx->{model}      // 'sonnet');
    my $max_turns  = defined $entry->{max_turns}  ? $entry->{max_turns}  : ($ctx->{max_turns}  // 60);
    my $write_set  = defined $entry->{write_set}  ? $entry->{write_set}  : '';
    my $test_paths = $entry->{test_paths};
    return undef unless defined $test_paths && !ref $test_paths && "$test_paths" =~ /\S/;
    my $mm         = (ref $entry->{mandated_means} eq 'ARRAY') ? $entry->{mandated_means} : [];
    my $mm_flow    = '[' . join(', ', @$mm) . ']';
    my $now_iso    = defined $ctx->{iso} ? $ctx->{iso} : _iso($ctx->{now});
    my $action     = defined $entry->{action} ? $entry->{action} : 'none';

    # Every value interpolated into the '---' YAML frontmatter block below
    # (directly, or via mandated_means) must be refused -- not escaped -- if
    # it could inject additional 'key: value' lines that bp-orchestrator.pl's
    # ledger_fm() would then parse as real fields (e.g. a forged
    # last_updated/status/write_set). REFUSE, do not escape: this package's
    # thesis is that declining to author is better than authoring something
    # a downstream parser can misread. A newline, a carriage return, or a
    # value that (after trimming leading whitespace) starts with '---' is an
    # authoring-time validity failure, exactly like the other unsatisfiability
    # gates in this file.
    for my $v ($id, $bp, $model, $max_turns, $write_set, $test_paths, $now_iso, @$mm) {
        return undef unless _fm_value_ok($v);
    }
    my $finding_key = defined $entry->{finding_key} ? $entry->{finding_key} : 'unclassified';
    my $round      = defined $entry->{round}      ? $entry->{round}      : 1;
    my $max_rounds = defined $entry->{max_rounds} ? $entry->{max_rounds} : 2;
    my $source     = defined $entry->{source}     ? $entry->{source}     : 'conformance';
    my $finding    = (ref $entry->{finding} eq 'HASH') ? $entry->{finding} : {};

    my $summary = _remedy_summary($action, $finding);
    my $sentence = _remedy_sentence($action, $finding);

    my $finding_json = eval { JSON::PP->new->canonical->pretty->encode($finding) };
    $finding_json = '{}' unless defined $finding_json;
    $finding_json =~ s/\s+\z//;

    # Rendered ledger markdown needs literal triple-backtick fences (AC-9 parses
    # a fenced json block out of the ## Inputs section) but bp-remediate.pl's own
    # SOURCE must carry zero backtick characters (AC-28's anti-shell-out scan).
    # Build the fence at runtime instead of writing it literally.
    my $F = chr(96) x 3;

    my $git_clause = ($action eq 'commit_lockfile')
        ? "Git may be unavailable in this container: if git cannot run, record that fact in this ledger's attempt log and stop; do not fabricate a commit."
        : '';

    my @lines;
    push @lines, '---';
    push @lines, "package: $id";
    push @lines, "blueprint: $bp";
    push @lines, "status: pending";
    push @lines, "model: $model";
    push @lines, "max_turns: $max_turns";
    push @lines, "write_set: $write_set";
    push @lines, "test_paths: $test_paths";
    push @lines, "mandated_means: $mm_flow";
    push @lines, "last_updated: $now_iso";
    push @lines, '---';
    push @lines, '';
    push @lines, "# Package $id — $summary";
    push @lines, '';
    push @lines, '## Scope';
    push @lines, '';
    push @lines, "This package exists only to close finding '$finding_key'. It must not touch anything outside write_set, and it must not widen its own scope.";
    push @lines, '';
    push @lines, '## Done criteria';
    push @lines, '';
    push @lines, $sentence;
    push @lines, '';
    push @lines, '## Inputs';
    push @lines, '';
    push @lines, 'The finding this package was authored to close, verbatim:';
    push @lines, '';
    push @lines, "${F}json";
    push @lines, $finding_json;
    push @lines, $F;
    push @lines, '';
    push @lines, "finding_key: $finding_key";
    push @lines, "source: $source";
    push @lines, "round $round of $max_rounds";
    if (defined $entry->{verdict_path} && length $entry->{verdict_path}) {
        push @lines, "originating verdict: $entry->{verdict_path}";
    }
    if (length $git_clause) { push @lines, ''; push @lines, $git_clause; }
    push @lines, '';
    push @lines, '## Pipeline';
    push @lines, '';
    push @lines, '- [ ] 1. Scout (skip if scope already maps cleanly — record the skip)';
    push @lines, '- [ ] 2. Spec written to specs/<NN-slug>-spec.md and checked against done criteria';
    push @lines, '- [ ] 3. Tests written from spec (bp-test-writer) and sanity-checked against spec';
    push @lines, '- [ ] 4. Implementation converged (bp-implementer; tests immutable; loop ≤ 4 attempts)';
    push @lines, '- [ ] 5. Validation suite green from disk (commands + exit codes recorded below)';
    push @lines, '- [ ] 6. Review ∥ red-team complete (report paths below)';
    push @lines, '- [ ] 7. Fix-batch applied (single dispatch) and re-validated';
    push @lines, '- [ ] 8. UI pass (only if package touches UI) — screenshots read, checklist applied';
    push @lines, '';
    push @lines, '## Decisions & attempt log';
    push @lines, '';
    push @lines, "$now_iso — Auto-authored by bp-remediate.pl from $source finding $finding_key (round $round/$max_rounds).";
    push @lines, '';
    push @lines, '## Next action';
    push @lines, '';
    push @lines, $sentence;
    push @lines, '';
    push @lines, '## Outputs';
    push @lines, '';
    push @lines, '## Escalation (when status: blocked)';
    push @lines, '';
    push @lines, '## Dispatch log (auto)';
    push @lines, '';
    return join("\n", @lines);
}

sub _resolve_verdict_path {
    my ($bpdir) = @_;
    return undef unless defined $bpdir && length $bpdir;
    my $runs = "$bpdir/runs";
    for my $rel ('conformance-verdict.json', 'conformance/_run.verdict.json') {
        my $p = "$runs/$rel";
        return $p if -e $p;
    }
    return undef;
}

sub author_ledger {
    my ($bpdir, $entry, $ctx) = @_;
    return undef unless defined $bpdir && ref $entry eq 'HASH';
    my $id = $entry->{id};
    return undef unless defined $id && length $id;

    my $verdict_path = _resolve_verdict_path($bpdir);
    return undef unless defined $verdict_path;

    my $dir = "$bpdir/packages";
    _make_path($dir) unless -d $dir;
    my $path = "$dir/$id.md";
    my $tmp  = "$path.tmp.$$";
    my $entry_for_render = { %$entry, verdict_path => $verdict_path };
    my $text = eval { ledger_text($entry_for_render, $ctx) };
    return undef unless defined $text;
    my $ok = 0;
    if (open my $fh, '>', $tmp) {
        if (print $fh $text) {
            if (close $fh) {
                $ok = 1 if rename $tmp, $path;
            }
        } else { close $fh; }
    }
    unless ($ok) { unlink $tmp if -e $tmp; return undef; }
    return $path;
}

# ===========================================================================
# impure I/O: read_queue / write_queue / rotate_verdict
# ===========================================================================

sub read_queue {
    my ($path) = @_;
    return undef unless defined $path && length $path;
    return undef unless -e $path;         # missing is normal (§3.8), never corrupt
    my $txt = _slurp($path);
    return { _corrupt => 1 } unless defined $txt;
    my $q = eval { JSON::PP->new->decode($txt) };
    return { _corrupt => 1 } if $@ || ref $q ne 'HASH';
    return { _corrupt => 1 } unless queue_ok($q);
    return $q;
}

sub write_queue {
    my ($path, $q) = @_;
    return 0 unless defined $path && length $path;
    my $dir = _dirname($path);
    _make_path($dir) if length($dir) && !-d $dir;
    my $tmp = "$path.tmp.$$";
    my $ok = 0;
    my $encoded = eval { JSON::PP->new->canonical->pretty->encode($q) };
    if (defined $encoded && open(my $fh, '>', $tmp)) {
        if (print $fh $encoded) {
            if (close $fh) {
                $ok = 1 if rename $tmp, $path;
            }
        } else { close $fh; }
    }
    unless ($ok) { unlink $tmp if -e $tmp; }
    return $ok;
}

# best-effort atomic merge of runs/registry.json packages._run.conformance_spawns
# back to 0 — the SAME lock file bp-orchestrator.pl's own update_registry_pkg
# uses (runs/registry.lock), so the two writers serialize safely, without
# bp-remediate.pl requiring anything beyond JSON::PP (flock is a builtin op;
# LOCK_EX/LOCK_UN are the portable POSIX values 2/8, used directly rather than
# pulling in Fcntl).
sub _registry_reset_conformance_spawns {
    my ($runs) = @_;
    return 0 unless defined $runs && length $runs;
    _make_path($runs) unless -d $runs;
    my $reg = "$runs/registry.json";
    my $ok = 0;
    if (open my $lk, '>', "$runs/registry.lock") {
        if (flock($lk, 2)) {   # LOCK_EX
            my $txt  = _slurp($reg);
            my $data = (defined $txt) ? eval { JSON::PP->new->decode($txt) } : undef;
            $data = { packages => {} } unless ref $data eq 'HASH' && ref $data->{packages} eq 'HASH';
            $data->{packages}{_run} = { %{ (ref $data->{packages}{_run} eq 'HASH') ? $data->{packages}{_run} : {} },
                                        conformance_spawns => 0 };
            my $tmp = "$reg.tmp.$$";
            if (open my $w, '>', $tmp) {
                print $w JSON::PP->new->canonical->pretty->encode($data);
                close $w;
                if (rename $tmp, $reg) { $ok = 1; } else { unlink $tmp; }
            }
            flock($lk, 8);   # LOCK_UN
        }
        close $lk;
    }
    return $ok;
}

sub rotate_verdict {
    my ($runs, $queue, $now) = @_;
    return undef unless defined $runs && ref $queue eq 'HASH';
    my $n = (defined $queue->{gate_firings} && "$queue->{gate_firings}" =~ /^\d+$/) ? $queue->{gate_firings} + 1 : 1;
    my $dir = "$runs/remediation/round-$n";
    _make_path($dir);
    my @moved;
    for my $rel ('conformance-verdict.json', 'conformance/_run.verdict.json') {
        my $src = "$runs/$rel";
        next unless -e $src;
        my ($base) = $rel =~ m{([^/]+)$};
        my $dst = "$dir/$base";
        if (rename $src, $dst) { push @moved, $dst; }
    }
    $queue->{gate_firings} = $n;
    _registry_reset_conformance_spawns($runs);
    return { moved => \@moved, round => $n };
}

1;
