#!/usr/bin/env perl
# s02-registry-runtime-only: runs/registry.json becomes strictly runtime-only.
# Its `status` key is removed from every writer/reader inside this package's
# write set (bp-orchestrator.pl, bp-lib.sh; bp-baseline.pl needs no change
# per the spec's own finding). Written BLIND to the implementation, directly
# from specs/s02-registry-runtime-only-spec.md, so it is an oracle rather
# than an echo.
#
# Renumbered from the ledger's original t/99 to t/118, then to t/148 by the
# 2026-08-14 driver (both 99 and 118 already collide with tracked butler
# test files) -- see the package ledger's attempt log.
#
# Coverage: DC1 (source scan + known-gap allowlist), DC2 (_load_state
# outcomes), DC3 (registry_get refuses 'status'), DC4 (Decision 13: registry
# never wins, structurally, no warning), DC6 (this file's own scenario
# coverage), DC7 lives in plugins/sandbox/tests/t/45-run-state.t (out of this
# file's reach by design -- RunState.pm is sandbox's file, not butler's).
# DC5/DC8 (whole-suite baselines) are coordinator-side checks, recorded in
# the step-3 report, not self-tested here (same convention as t/98's DC7).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $SCRIPTS_DIR = "$Bin/../../scripts";
my $ORCH_PATH   = "$SCRIPTS_DIR/bp-orchestrator.pl";
my $LIB_PATH    = "$SCRIPTS_DIR/bp-lib.sh";
my $LAUNCH_PATH = "$SCRIPTS_DIR/bp-launch.sh";
my $GATESTOP_PATH   = "$Bin/../../hooks/gate-stop.sh";
my $LIFECYCLE_PATH  = "$SCRIPTS_DIR/bp-lifecycle.pl";
my $ANSWER_PATH     = "$SCRIPTS_DIR/bp-answer-decision.pl";
my $SWEEP_PATH      = "$SCRIPTS_DIR/bp-resume-sweep.sh";

require $ORCH_PATH;   # package BpOrch

my $J = JSON::PP->new;

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>:raw', $path or die "write_file($path): $!";
    print $fh $content;
    close $fh;
}

# ===========================================================================
# Source-scan machinery (own copy in this file, per the driver's note that
# t/45-run-state.t's _balanced/extract_block is the precedent to PORT, not a
# cross-file dependency).
# ===========================================================================

# strip_comments($src) -> $src with every #-to-end-of-line comment blanked
# out (kept as an equal-length run of spaces so byte offsets/line numbers in
# any diagnostic stay meaningful). Best-effort, same convention as t/45.
sub strip_comments {
    my ($src) = @_;
    $src =~ s/#[^\n]*//g;
    return $src;
}

# extract_calls($src, $name) -> list of the full "(...)" text (including the
# parens) for every call site of $name(...) found in $src, via a paren-depth
# walk (never a naive non-greedy regex, which would stop at the first nested
# ')'). $src should already have comments stripped.
sub extract_calls {
    my ($src, $name) = @_;
    my @calls;
    while ($src =~ /\b\Q$name\E\s*\(/g) {
        my $paren_pos = pos($src) - 1;
        my $depth = 1;
        my $i = $paren_pos + 1;
        my $len = length($src);
        for (; $i < $len && $depth > 0; $i++) {
            my $c = substr($src, $i, 1);
            if    ($c eq '(') { $depth++; }
            elsif ($c eq ')') { $depth--; }
        }
        push @calls, substr($src, $paren_pos, $i - $paren_pos) if $depth == 0;
    }
    return @calls;
}

# ===========================================================================
# 1. DC1 / behavior 7: bp-orchestrator.pl source scan -- no update_registry_pkg
#    / _upd_pkg call site anywhere in the file has a literal `status` key.
# ===========================================================================
{
    my $raw = slurp($ORCH_PATH);
    ok(defined $raw && length $raw, 'bp-orchestrator.pl is readable on disk')
        or BAIL_OUT("cannot read $ORCH_PATH");
    my $src = strip_comments($raw);

    my @calls = (extract_calls($src, 'update_registry_pkg'), extract_calls($src, '_upd_pkg'));
    ok(scalar(@calls) >= 3, "DC1/behavior7: found at least 3 update_registry_pkg/_upd_pkg call sites to scan (found " . scalar(@calls) . ")")
        or diag("this floor exists so an extractor that finds ZERO calls (e.g. a name typo) cannot pass this section vacuously");

    my $violations = 0;
    for my $call (@calls) {
        my $ok = ($call !~ /(?<!\w)status\s*=>/);
        $violations++ unless $ok;
        ok($ok, "DC1/behavior7: call site does not contain a literal 'status =>' key: " . substr($call, 0, 80) . (length($call) > 80 ? '...' : ''));
    }
    is($violations, 0, 'DC1/behavior7: zero update_registry_pkg/_upd_pkg call sites in bp-orchestrator.pl write a status key');

    # Counter-fixture (non-vacuity proof): the SAME extractor + regex, run
    # against a synthetic snippet with a deliberate violation, MUST detect it.
    # If this fails, the scanner itself is broken (e.g. the regex or the
    # paren-walk), and the clean result above would be meaningless.
    my $poison = strip_comments(<<'PERL');
sub demo {
    update_registry_pkg($runs, $pkg, { attempt => 0, status => 'pending' });
    _upd_pkg($runs, $log, $pkg, { turn_exhaust_streak => 0 });
}
PERL
    my @poison_calls = (extract_calls($poison, 'update_registry_pkg'), extract_calls($poison, '_upd_pkg'));
    is(scalar(@poison_calls), 2, 'DC1/behavior7 counter-fixture: extractor finds both synthetic call sites');
    my $poison_violations = grep { /(?<!\w)status\s*=>/ } @poison_calls;
    is($poison_violations, 1, 'DC1/behavior7 counter-fixture: the scanner DOES flag a deliberately-poisoned call site (proves it can go red, not merely a vacuous pass)');
}

# ===========================================================================
# 2. DC1: bp-lib.sh's registry schema doc comment (:94-95) must no longer
#    list `status` among the documented registry.json fields.
# ===========================================================================
{
    my $raw = slurp($LIB_PATH);
    ok(defined $raw && length $raw, 'bp-lib.sh is readable on disk') or BAIL_OUT("cannot read $LIB_PATH");
    # The doc comment is the two lines above `registry_path()`, separated
    # from it by a single blank line.
    if ($raw =~ /((?:^#[^\n]*\n)+)\n*registry_path\(\)/m) {
        my $doc = $1;
        unlike($doc, qr/\bstatus\b/, 'DC1: the registry.json schema doc comment above registry_path() no longer lists "status" among its fields');
    } else {
        fail('DC1: could not locate the registry.json schema doc comment above registry_path() to check it');
    }
}

# ===========================================================================
# 3. DC1 / behavior 8: known-gap allowlist. Four writers named in the spec's
#    §1 table sit OUTSIDE this package's write set and are pinned as a named,
#    tested, non-silent gap -- NOT fixed here. A fifth, real, PRE-EXISTING
#    writer (bp-resume-sweep.sh:98) was found independently by this
#    test-writer while verifying the spec's table against the tree (grep for
#    every `registry_merge(`/`update_registry_pkg(`/`_upd_pkg(`/
#    `write_registry(` call site under plugins/butler/) -- it is not in the
#    spec's table, so it is added here as a 5th allowlist entry (flagged in
#    the step-3 report for the driver to fold into the ledger's Escalation
#    section) rather than silently causing this test to be permanently red
#    for a file s02's write set cannot touch.
# ===========================================================================
my @ALLOWLIST = (
    { label => 'bp-launch.sh:150 (launch-time status:"running")', path => $LAUNCH_PATH,
      pattern => qr/status:"running"/ },
    { label => 'gate-stop.sh:~150 (best-effort status sync, jq {status:$st})', path => $GATESTOP_PATH,
      pattern => qr/\{status:\$st\}/ },
    { label => 'bp-lifecycle.pl:449 (reconcile_one drift repair, $entry->{status} = ...)', path => $LIFECYCLE_PATH,
      pattern => qr/\$entry->\{status\}\s*=\s*\$by_pkg\{\$pkg\}/ },
    { label => 'bp-answer-decision.pl:706 (status => $plan->{ledger_status})', path => $ANSWER_PATH,
      pattern => qr/status\s*=>\s*\$plan->\{ledger_status\}/ },
    # REMOVED 2026-08-14 by driver adjudication. This entry pinned
    # bp-resume-sweep.sh:98's status write as "still present (the gap is real,
    # not stale)" -- i.e. it asserted a DEFECT AS CORRECT, which is one of the
    # twelve oracle-defect shapes catalogued in this run. That was the RIGHT
    # call when written: the file sat outside s02's write set, and pinning the
    # gap loudly beat letting the suite go permanently red for something the
    # package could not touch. The test-writer flagged it for the driver rather
    # than hiding it, which is why it is being corrected here instead of
    # shipping.
    #
    # The driver then WIDENED s02's write_set to include
    # plugins/butler/scripts/bp-resume-sweep.sh, precisely because DC1 ("no code
    # path writes a status key") was otherwise unsatisfiable. With the file in
    # scope, this entry contradicts DC1, so it is dropped -- which hands
    # bp-resume-sweep.sh to the exhaustive out-of-allowlist scan below, where it
    # must now prove it does NOT write registry status.
    #
    # The four entries above stay. They are genuinely outside this package's
    # write set and remain deliberately-documented, tested gaps.
);

{
    for my $w (@ALLOWLIST) {
        my $raw = slurp($w->{path});
        ok(defined $raw && length $raw, "behavior8: $w->{label} -- file readable") or next;
        like($raw, $w->{pattern}, "behavior8: $w->{label} still matches its cited status-write pattern (the gap is real, not stale)");
    }
}

# behavior8, second half: no file OUTSIDE the allowlist + bp-orchestrator.pl
# (already exhaustively scanned in section 1) writes registry status, via any
# of the four real write funnels this codebase uses:
#   - update_registry_pkg(...) / _upd_pkg(...) literal hash with status=>
#     (Perl, extracted the same way as section 1)
#   - write_registry(...) (Perl, the raw-encode-and-write primitive; paired
#     with a nearby ->{status} = assignment mutating the registry hash)
#   - registry_merge CALLNAME ... (bash function-call form, not the `()`
#     definition) whose trailing JSON argument contains "status"
#   - a raw jq filter (bash) targeting `.packages[$pkg]` whose filter string
#     also contains "status" (gate-stop.sh's own shape, generalized)
{
    my %allow_path = map { $_->{path} => 1 } @ALLOWLIST;
    $allow_path{$ORCH_PATH} = 1;   # exhaustively scanned in section 1 already

    my @scan_dirs = ($SCRIPTS_DIR, "$Bin/../../hooks");
    my @files;
    for my $d (@scan_dirs) {
        next unless -d $d;
        opendir(my $dh, $d) or next;
        for my $f (readdir $dh) {
            next if $f =~ /^\./;
            next unless $f =~ /\.(pl|pm|sh)\z/;
            push @files, "$d/$f";
        }
        closedir $dh;
    }
    ok(scalar(@files) > 20, 'behavior8: scanned a plausible number of butler scripts/hooks files (' . scalar(@files) . ')')
        or diag('too few files found -- the directory scan itself may be broken (opendir path wrong?)');

    my $unexpected = 0;
    for my $f (sort @files) {
        next if $allow_path{$f};
        my $raw = slurp($f);
        next unless defined $raw && length $raw;
        my $src = strip_comments($raw);
        my @hits;

        if ($f =~ /\.(pl|pm)\z/) {
            for my $call (extract_calls($src, 'update_registry_pkg'), extract_calls($src, '_upd_pkg')) {
                push @hits, "update_registry_pkg/_upd_pkg call with status=> : " . substr($call, 0, 100)
                    if $call =~ /(?<!\w)status\s*=>/;
            }
            if ($src =~ /\bwrite_registry\s*\(/ && $src =~ /->\{status\}\s*=(?!=)/) {
                push @hits, 'calls write_registry(...) AND assigns ->{status} = ... somewhere in the file';
            }
        } elsif ($f =~ /\.sh\z/) {
            # bash CALL form: "registry_merge" followed by whitespace then a
            # quote/variable (never "registry_merge()" or "registry_merge ()",
            # which is the function DEFINITION, already excluded by requiring
            # the char right after the word to be whitespace-then-not-paren).
            while ($src =~ /\bregistry_merge[ \t]+(?!\()/g) {
                my $from = pos($src);
                # capture a bounded span (function calls in this codebase are
                # never longer than a handful of lines) up to the next
                # top-level statement terminator or a hard cap.
                my $span = substr($src, $from, 600);
                $span =~ s/\n[ \t]*\n.*//s;   # stop at the first blank line
                push @hits, "registry_merge call span contains 'status': " . substr($span, 0, 100) if $span =~ /status/;
            }
            # raw jq writing .packages[$pkg] with a status field in the same
            # filter string (gate-stop.sh's own shape, generalized to catch a
            # copy-paste elsewhere).
            while ($src =~ /\.packages\[\$\w+\]\s*=/g) {
                my $from = pos($src);
                my $span = substr($src, $from, 200);
                push @hits, "jq .packages[\$pkg] = ... filter contains 'status': " . substr($span, 0, 100) if $span =~ /status/;
            }
        }

        if (@hits) {
            $unexpected++;
            fail("behavior8: $f is NOT in the allowlist but matches a registry-status-write pattern: " . join(' | ', @hits));
        }
    }
    is($unexpected, 0, 'behavior8: no file outside the allowlist (+ bp-orchestrator.pl, scanned exhaustively in section 1) writes registry status anywhere under plugins/butler/scripts or plugins/butler/hooks');
}

# ===========================================================================
# 4. DC3 / behavior 6: registry_get(bp, pkg, "status") refuses -- prints
#    nothing to stdout, a one-line error to stderr, non-zero exit. Any other
#    field is unchanged (jq-dependent value round-trip is $have_jq-gated,
#    matching this suite's existing house convention, e.g. t/09-gate.t).
# ===========================================================================
{
    my $have_jq = do { my $o = `bash -c 'command -v jq' 2>/dev/null`; (defined $o && $o =~ /\S/) ? 1 : 0 };
    my $root = tempdir(CLEANUP => 1);
    my $bp = 'bp1';
    make_path("$root/blueprints/$bp/runs");
    write_file("$root/blueprints/$bp/runs/registry.json", $J->encode({ packages => { p1 => { status => 'done', attempt => 3, pid => 111 } } }));

    my $script = <<"SH";
set -eu
export CCPRAXIS_DATA_DIR="$root"
. "$LIB_PATH"
registry_get "$bp" p1 status
SH
    my $tmp_script = "$root/run-status.sh";
    write_file($tmp_script, $script);
    my $stdout = `bash "$tmp_script" 2>"$root/stderr-status.txt"`;
    my $rc = $? >> 8;
    my $stderr = slurp("$root/stderr-status.txt") // '';

    is($stdout, '', "DC3/behavior6: registry_get(...,'status') prints nothing to stdout");
    like($stderr, qr/registry_get.*'status'.*not a registry field/s,
        "DC3/behavior6: registry_get(...,'status') prints the specific refusal message to stderr (a generic 'jq: command not found' error -- which this host, lacking jq, would ALSO produce today -- must NOT satisfy this assertion; only the literal refusal wording does)");
    isnt($rc, 0, "DC3/behavior6: registry_get(...,'status') exits non-zero");

  SKIP: {
        skip 'jq not available on this host -- the non-status-field round-trip needs a real jq to fetch a value', 1 unless $have_jq;
        my $script2 = <<"SH2";
set -eu
export CCPRAXIS_DATA_DIR="$root"
. "$LIB_PATH"
registry_get "$bp" p1 attempt
SH2
        my $tmp2 = "$root/run-attempt.sh";
        write_file($tmp2, $script2);
        my $out2 = `bash "$tmp2" 2>"$root/stderr-attempt.txt"`;
        chomp $out2;
        is($out2, '3', "DC3/behavior6: registry_get(...,'attempt') is unchanged -- still returns the real value");
    }
}

# ===========================================================================
# Fixture helpers for _load_state (DC2/DC4): a minimal single-package
# blueprint dir, byte-compatible with bp-orchestrator.pl's own reader
# (parse_dag wants a "| pkg | ... | depends_on | ... |" markdown table;
# ledger_fm wants a "---\nstatus: X\n---" frontmatter block).
# ===========================================================================
sub blueprint_md_for {
    my (@pkgs) = @_;
    my $rows = join("\n", map { "| $_ | thing | - | sonnet | pending |" } @pkgs);
    return "# T\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n$rows\n";
}

sub write_ledger {
    my ($bpdir, $pkg, $status) = @_;
    make_path("$bpdir/packages");
    write_file("$bpdir/packages/$pkg.md",
        "---\npackage: $pkg\nblueprint: T\nstatus: $status\nwrite_set: p/$pkg/\ntest_paths: p/$pkg/\nlast_updated: 2026-06-24T00:00:00Z\n---\n\n# $pkg\n");
}

sub write_registry_raw {
    my ($bpdir, $data_or_text) = @_;
    make_path("$bpdir/runs");
    my $text = ref($data_or_text) ? $J->encode($data_or_text) : $data_or_text;
    write_file("$bpdir/runs/registry.json", $text);
}

# ===========================================================================
# 5. DC2 / behavior 2: ledger status wins over a CONTRADICTING registry
#    status -- outright, not merely deprioritized.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $bpdir = "$root/bp-contradict";
    make_path($bpdir);
    write_file("$bpdir/blueprint.md", blueprint_md_for('p1'));
    write_ledger($bpdir, 'p1', 'blocked');
    write_registry_raw($bpdir, { packages => { p1 => { status => 'done', pid => 123 } } });

    my ($meta, $status, $att, $pid, $sid) = BpOrch::_load_state($bpdir, "$bpdir/runs");
    is($status->{p1}, 'blocked', 'DC2/behavior2: ledger says blocked, registry contradicts with done -> ledger wins outright');
}

# ===========================================================================
# 6. DC2 / behavior 3 + DC4: no ledger file at all, registry claims "done" --
#    the registry must NEVER be consulted, even as a last resort (this is the
#    Decision-13-mandated change). DC4 additionally requires this to be a
#    STRUCTURAL guarantee, not a logged one: nothing in the path may emit a
#    "used the registry" (or equivalent) warning/log line -- captured via
#    $SIG{__WARN__} and via the orchestrator log file itself, both asserted
#    empty of any registry-status-consultation trace.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $bpdir = "$root/bp-noledger";
    make_path($bpdir);
    write_file("$bpdir/blueprint.md", blueprint_md_for('p1'));
    # Deliberately no packages/p1.md at all.
    write_registry_raw($bpdir, { packages => { p1 => { status => 'done', pid => 999 } } });

    my @warnings;
    my ($meta, $status, $att, $pid, $sid);
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        ($meta, $status, $att, $pid, $sid) = BpOrch::_load_state($bpdir, "$bpdir/runs");
    }
    is($status->{p1}, 'pending', 's02/DC4 (Decision 13): no ledger file + registry claims "done" -> \'pending\', the registry is NEVER consulted even as a last resort');
    is(scalar(@warnings), 0, 's02/DC4: _load_state emitted zero Perl warnings while resolving this package (no "used the registry" side-channel)');
    ok(!-e "$bpdir/runs/orchestrator.log", 's02/DC4: _load_state itself writes no log line at all (it is a pure reader) -- structural, not merely unlogged-by-omission');
}

# ===========================================================================
# 7. DC2 / behavior 4: a registry entry for a package with NO corresponding
#    blueprint.md DAG row (and no ledger file) contributes nothing to the
#    result -- structurally unreachable (the loop is `for my $pkg (keys
#    %$dag)`), never crashes, never appears.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $bpdir = "$root/bp-phantom";
    make_path($bpdir);
    write_file("$bpdir/blueprint.md", blueprint_md_for('p1'));
    write_ledger($bpdir, 'p1', 'running');
    write_registry_raw($bpdir, { packages => {
        p1 => { status => 'done' },
        'ghost-pkg-not-in-dag' => { status => 'done', pid => 42 },
    } });

    my ($meta, $status, $att, $pid, $sid) = eval { BpOrch::_load_state($bpdir, "$bpdir/runs") };
    ok(!$@, 'DC2/behavior4: _load_state does not die on a registry-only phantom entry') or diag($@);
    is($status->{p1}, 'running', 'DC2/behavior4: the real DAG package still resolves correctly (sanity)');
    ok(!exists $status->{'ghost-pkg-not-in-dag'}, "DC2/behavior4: the phantom registry-only key contributes nothing to \%status");
    ok(!exists $meta->{'ghost-pkg-not-in-dag'}, "DC2/behavior4: the phantom registry-only key contributes nothing to \%meta");
}

# ===========================================================================
# 8. DC2 / behavior 5: a truncated/malformed runs/registry.json does not die
#    -- every package's status resolves from its ledger (or 'pending' if
#    absent), identical to a missing registry file. Pre-existing via
#    read_registry's eval-wrapped decode; this pins it against regression.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $bpdir = "$root/bp-corrupt";
    make_path($bpdir);
    write_file("$bpdir/blueprint.md", blueprint_md_for('p1', 'p2'));
    write_ledger($bpdir, 'p1', 'running');
    # p2 has no ledger -> must resolve to 'pending', same as the missing-registry case.
    write_registry_raw($bpdir, "{not valid json at all");

    my ($meta, $status, $att, $pid, $sid) = eval { BpOrch::_load_state($bpdir, "$bpdir/runs") };
    ok(!$@, 'DC2/behavior5: _load_state does not die on a truncated/malformed registry.json') or diag($@);
    is($status->{p1}, 'running', 'DC2/behavior5: p1 (has a ledger) still resolves from its ledger despite the corrupt registry');
    is($status->{p2}, 'pending', 'DC2/behavior5: p2 (no ledger) resolves to "pending", identical to a missing registry file');
}

# ===========================================================================
# 9. DC6 / behavior 1: writers omit the key -- direct update_registry_pkg
#    calls with the CORRECTED field sets (per spec §2.1's three cleaned-up
#    call sites), asserting the resulting entry never gains a status key and
#    that pre-existing OTHER fields on the same entry are preserved
#    (shallow merge, unchanged).
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $bpdir = "$root/bp-writer";
    my $runs = "$bpdir/runs";
    make_path($runs);
    # Pre-existing entry with an OTHER field (pid) that must survive the merge.
    write_registry_raw($bpdir, { packages => { p1 => { pid => 4242, model => 'sonnet' } } });

    # Corrected :2788 call site shape (attempt reset, no status).
    my $ok1 = BpOrch::update_registry_pkg($runs, 'p1', { attempt => 0 });
    ok($ok1, 'DC6/behavior1: update_registry_pkg(corrected :2788 shape) returns success');
    my $reg1 = $J->decode(slurp("$runs/registry.json"));
    ok(!exists $reg1->{packages}{p1}{status}, 'DC6/behavior1: the resulting entry has no status key');
    is($reg1->{packages}{p1}{attempt}, 0, 'DC6/behavior1: attempt was written');
    is($reg1->{packages}{p1}{pid}, 4242, 'DC6/behavior1: the PRE-EXISTING pid field survives the shallow merge, untouched');
    is($reg1->{packages}{p1}{model}, 'sonnet', 'DC6/behavior1: the pre-existing model field survives too');

    # Corrected :3162 call site shape (corrective cycle reset, no status).
    my $ok2 = BpOrch::update_registry_pkg($runs, 'p1', { attempt => 0, harvest => '', corrective_attempts => 1, harvest_defer_blockers => '' });
    ok($ok2, 'DC6/behavior1: update_registry_pkg(corrected :3162 shape) returns success');
    my $reg2 = $J->decode(slurp("$runs/registry.json"));
    ok(!exists $reg2->{packages}{p1}{status}, 'DC6/behavior1: still no status key after the corrective-cycle write');
    is($reg2->{packages}{p1}{corrective_attempts}, 1, 'DC6/behavior1: corrective_attempts was written');
    is($reg2->{packages}{p1}{pid}, 4242, 'DC6/behavior1: pid STILL survives after a second shallow merge');

    # The :3995 call site (_block_and_queue) is deleted entirely per spec --
    # verified structurally in section 3's source scan (no update_registry_pkg
    # call with a status key anywhere), and end-to-end in section 10 below.
}

# ===========================================================================
# 10. DC6 / behavior 1 (reaching _block_and_queue directly): a run()-level
#     fixture does NOT reach the :3995/:4484 call site -- verified while
#     writing this file: t/06-orchestrator.t's own T-orphan shape only
#     exercises orphan_escalations (files a needs-you decision for a package
#     ALREADY blocked in its own ledger), which never calls
#     update_registry_pkg at all. _block_and_queue is reached only from the
#     watchdog/resolve-judge attempt-cap paths (:2797/:3195/:3255) or a
#     direct call -- t/115-escalation-categories.t (an existing, immutable,
#     OUT-OF-WRITE-SET oracle) already calls BpOrch::_block_and_queue
#     directly with a 9/10-positional-arg signature specifically because the
#     production call sites are deep inside multi-hundred-line watchdog
#     blocks. This test follows that SAME precedent (same call shape) rather
#     than inventing a new fixture path, per the spec's "reuse ... helpers
#     rather than inventing new ones" instruction.
#
#     *** CONFLICT FOUND, FLAGGED IN THE STEP-3 REPORT, NOT SILENTLY WORKED
#     AROUND: *** t/115-escalation-categories.t:326 ("D3: valid category --
#     registry flips to blocked") asserts
#     `is($reg->{packages}{$pkg}{status}, 'blocked', ...)` directly on the
#     OUTCOME of this exact call site. Once bp-orchestrator.pl's :4484
#     `update_registry_pkg($runs, $pkg, { status => 'blocked' })` is deleted
#     per spec §2.1, that key can never be 'blocked' again, and t/115's D3
#     assertion WILL turn red -- t/115 is neither in this package's
#     write_set nor its test_paths, so this test-writer cannot fix it, and
#     the spec does not name t/115 anywhere (unlike its explicit, deliberate
#     callouts for t/13-answer-decision.t and t/97-lifecycle-reconcile.t,
#     which it says must stay green UNCHANGED because their producers are
#     untouched -- t/115's producer, by contrast, IS touched by this
#     package). This is a genuine spec gap for the driver, not an oracle
#     defect: the assertion below is the CORRECT, spec-mandated outcome;
#     t/115:326 is the one that becomes wrong.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $bpdir = "$root/bp-blk";
    my $pkg = 'blk1';
    make_path("$bpdir/packages");
    make_path("$bpdir/runs");
    write_file("$bpdir/blueprint.md", "# T\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n| $pkg | x | - | sonnet | pending |\n");
    write_file("$bpdir/packages/$pkg.md",
        "---\npackage: $pkg\nblueprint: T\nstatus: pending\nwrite_set: p/$pkg/\ntest_paths: p/$pkg/\nlast_updated: 2026-06-24T00:00:00Z\n---\n# $pkg\n");
    my $runs = "$bpdir/runs";
    my $log  = "$runs/orchestrator.log";

    BpOrch::_block_and_queue($bpdir, $runs, $log, 'T', $pkg, 'stuck', time, 'question?', 'stuck-package', 'scoping');

    # AMENDED 2026-08-14 by driver adjudication -- a SEQUENCING conflict, not a
    # defect in either side. This section was written at step 3, when the spec
    # still implied _block_and_queue would keep touching the registry with a
    # non-status payload. The step-4 spec amendment then ruled the :4484 write
    # DELETED OUTRIGHT: its only reader (_load_state:2194's fallback) is removed
    # by this same package under Decision 13, so the write has zero readers and
    # keeping it would retain exactly the mirror Decision 12 forbids. Under that
    # ruling _block_and_queue makes NO registry write at all, so the original
    # "the package reached the registry" assertion demanded the very thing the
    # amendment deleted. The implementer hit the contradiction and flagged it
    # instead of coding around it, which is why this is a correction rather
    # than a silently-weakened oracle.
    #
    # NON-VACUITY IS PRESERVED, JUST RE-WITNESSED. That assertion's job was to
    # prove the call had actually been exercised rather than no-op'd. The
    # registry can no longer serve as that witness, but the LEDGER can:
    # _block_and_queue still flips the package to blocked (pinned independently
    # at plugins/butler/tests/t/115-escalation-categories.t:324, which this
    # package leaves untouched). So the exercised-ness check moves to the ledger
    # and the no-status check stays, now stated over whatever the registry holds.
    my $led_raw    = slurp("$bpdir/packages/$pkg.md");
    my ($led_stat) = (defined $led_raw && $led_raw =~ /^status:\s*(\S+)/m) ? ($1) : ('');
    is($led_stat, 'blocked',
       'DC6/behavior1 (_block_and_queue): the LEDGER flipped to blocked -- proves the call was '
     . 'exercised, not a no-op (the registry can no longer witness this: its write was deleted)');
    if (-e "$runs/registry.json") {
        my $reg = $J->decode(slurp("$runs/registry.json"));
        ok(!exists $reg->{packages}{$pkg}{status},
           'DC6/behavior1 (_block_and_queue): no status key for this package in the registry -- '
         . 'the :4484 call site was DELETED per the spec amendment, not merely emptied');
    } else {
        pass('DC6/behavior1 (_block_and_queue): no registry.json at all -- the strongest form of '
           . '"no status key", since the deleted :4484 write was this call path'."'".'s only registry touch');
    }
}

done_testing();
