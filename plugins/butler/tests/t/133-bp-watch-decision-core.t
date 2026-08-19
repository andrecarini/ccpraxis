#!/usr/bin/env perl
# 133-bp-watch-decision-core.t — IMMUTABLE ORACLE for w01-bp-watch's pure
# decision core (package BpWatch in plugins/butler/scripts/bp-watch.pl).
#
# Spec: .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/specs/
#       w01-bp-watch-spec.md §2.1 (interfaces), §3 (behaviors), §4 (AC).
#
# bp-watch.pl DOES NOT EXIST YET at the time this file is written (test-writer
# runs before the implementer). `require $SCRIPT` is therefore expected to
# fail; caught with eval (house pattern — t/159-status-read-api.t), so every
# BpWatch:: call below dies "Undefined subroutine", $got stays undef, and each
# `is()`/`ok()` fails as a genuine not-ok — the RIGHT reason: missing behavior,
# never a scaffolding bug of this file's own making.
#
# THE FOUR INVARIANTS ARE THE HEART OF THIS FILE. Sections B/C/D/E pin them
# SEPARATELY, each with its own falsifiable assertion and its own counter-
# fixture, so a partial implementation reads as partial rather than as a
# single pass/fail blob. Section F pins the umbrella rule (§0) directly.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $SCRIPT = "$Bin/../../scripts/bp-watch.pl";
my $REQUIRE_ERROR = '';
my $LOADED = do {
    local $@;
    eval { require $SCRIPT };
    $REQUIRE_ERROR = $@;
    !$@;
};

ok($LOADED, 'A1: bp-watch.pl requires cleanly as (at least) package BpWatch')
    or diag("require died with: $REQUIRE_ERROR");

for my $sub (qw(is_terminal_status read_packages_dir blueprint_settled
                all_pids_alive artifact_snapshot artifact_changed
                resolve_condition format_change_line)) {
    ok(defined &{"BpWatch::$sub"}, "A2: BpWatch::$sub is defined");
}

sub write_ledger {
    my ($dir, $id, $status_line) = @_;
    make_path("$dir/packages");
    my $body = "---\npackage: $id\n";
    $body .= "$status_line\n" if defined $status_line;
    $body .= "---\n\nbody\n";
    open my $fh, '>', "$dir/packages/$id.md" or die "write $id.md: $!";
    print {$fh} $body;
    close $fh;
}

# ===========================================================================
# B. INVARIANT 1 — allowlist the TERMINAL set only (done|dropped|blocked|
#    parked). Everything else, including unknown free text, is LIVE.
#
#    Falsifiable by: an implementation that allowlists the LIVE set instead
#    (the shipped bug) would answer TRUE for 'converging' below — B3 would
#    fail. An implementation that always returns false would fail B1/B2/B4-B7
#    (never terminal for a real terminal word). Both directions are covered.
# ===========================================================================
{
    for my $word (qw(done dropped blocked parked)) {
        my $got = eval { BpWatch::is_terminal_status($word) };
        ok($got, "B1: is_terminal_status('$word') is true (allowlisted terminal word)");
    }
    for my $word (qw(pending running reviewing)) {
        my $got = eval { BpWatch::is_terminal_status($word) };
        ok(!$got, "B2: is_terminal_status('$word') is false (a LIVE word, not terminal)");
    }
    # THE EXACT FAILURE STRING from the package history (w01-bp-watch.md:32).
    my $got_converging = eval { BpWatch::is_terminal_status('converging') };
    ok(!$got_converging,
       "B3 INVARIANT-1 CANONICAL: is_terminal_status('converging') is false — free text a "
     . "coordinator actually wrote must never be read as terminal (this exact string shipped "
     . "as a false-settled bug once already)");
    for my $bad (undef, '') {
        my $got = eval { BpWatch::is_terminal_status($bad) };
        ok(!$got, 'B4: is_terminal_status(undef/empty) is false, never terminal');
    }
    # A completely novel free-text word never seen before must ALSO be LIVE —
    # proves the function is a positive allowlist, not a hand-maintained
    # blocklist that happens to catch today's known bad words.
    my $got_novel = eval { BpWatch::is_terminal_status('zzz-never-seen-before-xyz') };
    ok(!$got_novel, 'B5: an entirely novel free-text status is LIVE, not terminal — '
                   . 'proves is_terminal_status is a POSITIVE allowlist, not a denylist');
}

# ===========================================================================
# C. INVARIANT 2 — the package denominator comes from packages/*.md, NEVER
#    registry.json (which only knows LAUNCHED packages).
#
#    Falsifiable by: an implementation reading registry.json for the
#    denominator would report only 2 packages (or trust their 'done' claim)
#    instead of 5 — C2/C3 would fail. The registry.json in this fixture is
#    DELIBERATELY WRONG (claims p1/p2 done, which is even true, but the
#    denominator itself is what's under test) to prove it is never consulted.
# ===========================================================================
{
    my $bp = tempdir(CLEANUP => 1);
    write_ledger($bp, 'p1', 'status: done');
    write_ledger($bp, 'p2', 'status: done');
    write_ledger($bp, 'p3', 'status: pending');   # never launched
    write_ledger($bp, 'p4', 'status: pending');   # never launched
    write_ledger($bp, 'p5', 'status: pending');   # never launched
    make_path("$bp/runs");
    # registry.json knows only the 2 LAUNCHED packages, and claims both done —
    # a deliberately-inflated, deliberately-limited registry.
    open my $rfh, '>', "$bp/runs/registry.json" or die;
    print {$rfh} '{"p1":{"status":"done"},"p2":{"status":"done"}}';
    close $rfh;

    my $pkgs = eval { BpWatch::read_packages_dir($bp) };
    is(ref $pkgs, 'ARRAY', 'C1: read_packages_dir returns an arrayref');
    is(scalar(@{ $pkgs || [] }), 5,
       'C2 INVARIANT-2 CANONICAL: denominator is 5 (from packages/*.md), NOT 2 (registry.json\'s '
     . 'launched-only count) — the exact false-settled shape from the package history '
     . '("all registry entries terminal" reachable with 3 of 5 never run)');

    my $settled = eval { BpWatch::blueprint_settled($pkgs) };
    ok(!$settled,
       'C3: blueprint_settled is FALSE — p3/p4/p5 are pending (never launched, absent from '
     . 'registry.json entirely), so the blueprint must NOT read as settled even though every '
     . 'registry.json entry claims done');

    # Counter-fixture: registry.json ABSENT entirely must not change the
    # answer either (nothing here reads it, so its presence/absence/content
    # are all irrelevant) — the negative-space form of the same proof.
    unlink "$bp/runs/registry.json";
    my $pkgs2 = eval { BpWatch::read_packages_dir($bp) };
    is(scalar(@{ $pkgs2 || [] }), 5,
       'C4: denominator is STILL 5 with registry.json deleted entirely — proves the file is '
     . 'never opened for this purpose, not merely misread when present');
}
{
    # A blueprint where every package genuinely IS terminal -> settled true.
    # Without this positive case, C3 alone could pass under an implementation
    # that always returns blueprint_settled=false.
    my $bp = tempdir(CLEANUP => 1);
    write_ledger($bp, 'a', 'status: done');
    write_ledger($bp, 'b', 'status: dropped');
    my $pkgs = eval { BpWatch::read_packages_dir($bp) };
    my $settled = eval { BpWatch::blueprint_settled($pkgs) };
    ok($settled, 'C5: blueprint_settled is TRUE when every packages/*.md entry is genuinely '
                . 'terminal — proves C3\'s false answer is attributable to the 3 pending '
                . 'packages, not to a function that always says false');
}
{
    # Empty packages dir -> vacuously settled, matching bp-wait-for-decision's
    # documented convention (spec §2.1).
    my $bp = tempdir(CLEANUP => 1);
    make_path("$bp/packages");
    my $pkgs = eval { BpWatch::read_packages_dir($bp) };
    is(scalar(@{ $pkgs || [] }), 0, 'C6: no packages/*.md -> empty list');
    my $settled = eval { BpWatch::blueprint_settled($pkgs) };
    ok($settled, 'C7: blueprint_settled([]) is vacuously true (empty-list convention, spec §2.1)');
}
{
    # A ledger that fails to parse (no frontmatter at all) -> status undef,
    # NEVER silently dropped from the denominator, and undef is never terminal.
    my $bp = tempdir(CLEANUP => 1);
    make_path("$bp/packages");
    open my $fh, '>', "$bp/packages/broken.md" or die;
    print {$fh} "just prose, no frontmatter delimiter at all\n";
    close $fh;
    write_ledger($bp, 'ok1', 'status: done');
    my $pkgs = eval { BpWatch::read_packages_dir($bp) };
    is(scalar(@{ $pkgs || [] }), 2,
       'C8: an unparseable ledger is STILL counted in the denominator (2 entries), never '
     . 'silently dropped');
    my ($broken) = grep { $_->{id} eq 'broken' } @{ $pkgs || [] };
    ok(defined $broken, 'C9: the broken ledger produced an entry at all');
    ok(!defined $broken->{status}, 'C10: ...with status => undef (unparseable, not terminal, not "0")');
    my $settled = eval { BpWatch::blueprint_settled($pkgs) };
    ok(!$settled, 'C11: blueprint_settled is FALSE — an unparseable entry must never let the '
                 . 'blueprint read as settled just because the OTHER entry is done');
}
{
    # Whitespace/CRLF trimming must match bp-watchdog.pl's exact regex shape
    # (spec §5 edge case): "status: done  " (trailing spaces) -> 'done', not
    # left un-trimmed or misread as a non-terminal value.
    my $bp = tempdir(CLEANUP => 1);
    write_ledger($bp, 'p', "status: done  ");
    my $pkgs = eval { BpWatch::read_packages_dir($bp) };
    my ($p) = grep { $_->{id} eq 'p' } @{ $pkgs || [] };
    is($p->{status}, 'done', 'C12: trailing whitespace after the status word is trimmed');

    my $bp2 = tempdir(CLEANUP => 1);
    write_ledger($bp2, 'p', "status: donefoo");
    my $pkgs2 = eval { BpWatch::read_packages_dir($bp2) };
    my ($p2) = grep { $_->{id} eq 'p' } @{ $pkgs2 || [] };
    my $terminal = eval { BpWatch::is_terminal_status($p2->{status}) };
    ok(!$terminal, 'C13: "donefoo" (word-boundary violation) never matches "done" as terminal — '
                  . 'guards against a looser regex than bp-watchdog.pl\'s /^status:\\s*(\\S+)/');
}

# ===========================================================================
# D. INVARIANT 3 — liveness is PID-SCOPED (via BpRunState::pid_alive), NEVER
#    a name-grep.
#
#    Falsifiable two ways, both asserted: (1) a structural grep of the SOURCE
#    proves no second kill(0,...)/tasklist reimplementation exists (the exact
#    shape of the shipped bug — `ps -eo args | grep -c '[c]laude'` — would
#    show up as a second liveness primitive); (2) the PURE all_pids_alive
#    function, given an INJECTED pid_alive callback, correctly reports 1/0/
#    undef so death detection can genuinely fire (the shipped bug's headline
#    claim was that it never could).
# ===========================================================================
{
    my $src = do { local (@ARGV, $/) = ($SCRIPT); -f $SCRIPT ? <> : undef };
    ok(defined $src, 'D0: bp-watch.pl source is readable') or diag('bp-watch.pl absent');

    if (defined $src) {
        # Strip comments/POD-ish prose lines first, so a header discussing the
        # invariant in prose (as this very file's header does) cannot itself
        # trip the check.
        my $code = join "\n", map { /^\s*#/ ? '' : $_ } split /\n/, $src, -1;
        unlike($code, qr/\bkill\s*\(\s*0\s*,/,
           'D1 INVARIANT-3 CANONICAL: source contains no bare kill(0, ...) call of its own — '
         . 'liveness must be REUSED from BpRunState::pid_alive (bp-runstate.pl:59-69), never '
         . 'reimplemented ad hoc');
        unlike($code, qr/\btasklist\b/,
           'D2: source contains no direct tasklist invocation of its own, for the same reason');
        unlike($code, qr/grep\s+(-c\s+)?['"]?\[?c\]?laude/,
           'D3: source contains no name-grep for a claude process — the EXACT shape of the '
         . 'shipped bug (ps -eo args | grep -c \'[c]laude\'), which matched every bash '
         . 'tool-call process through the shell-snapshot path and could NEVER have fired');
        like($code, qr/pid_alive/,
           'D4: source actually references pid_alive at all — a file that reuses NOTHING '
         . 'named pid_alive cannot be reusing BpRunState\'s implementation');
    } else {
        fail('D1 INVARIANT-3 CANONICAL: cannot check source (file absent)');
        fail('D2: cannot check source (file absent)');
        fail('D3: cannot check source (file absent)');
        fail('D4: cannot check source (file absent)');
    }
}
{
    # all_pids_alive: pure function, injected pid_alive_fn. Death detection
    # must genuinely fire the moment ANY pid is dead — not "eventually", not
    # "only if all are dead".
    my $all_alive = sub { 1 };
    my $one_dead  = sub { my $p = shift; return $p == 222 ? 0 : 1 };
    my $all_dead  = sub { 0 };

    is(eval { BpWatch::all_pids_alive([111, 222, 333], $all_alive) }, 1,
       'D5: all_pids_alive -> 1 when every pid reports alive');
    is(eval { BpWatch::all_pids_alive([111, 222, 333], $one_dead) }, 0,
       'D6 INVARIANT-3 LIVENESS CANONICAL: all_pids_alive -> 0 the MOMENT ANY ONE pid is dead — '
     . 'this is the death-detection feature that "could never have fired" under the shipped '
     . 'name-grep bug; here, with a real per-pid check, it fires immediately');
    is(eval { BpWatch::all_pids_alive([111, 222, 333], $all_dead) }, 0,
       'D7: all_pids_alive -> 0 when every pid is dead');
    my $got_empty = eval { BpWatch::all_pids_alive([], $all_alive) };
    ok(!defined $got_empty,
       'D8: all_pids_alive([]) -> undef ("not applicable"), NEVER 1 ("confirmed alive") — an '
     . 'empty pid list must not be read as a positive liveness confirmation');
}

# ===========================================================================
# E. INVARIANT 4 — progress is scoped to the WATCHED SUBJECT's own artefacts,
#    never a tree-wide newest-mtime scan.
#
#    Falsifiable by: artifact_snapshot/artifact_changed operate ONLY on the
#    explicit \@paths list handed in — a sibling package's file, never named
#    in that list, must be invisible to both functions no matter how recently
#    it changed. This is the LIVE defect named in bp-watchdog.pl:102-136.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/watched-pkg");
    make_path("$root/sibling-pkg");
    my $watched_file  = "$root/watched-pkg/ledger.md";
    my $sibling_file  = "$root/sibling-pkg/ledger.md";
    open my $f1, '>', $watched_file or die; print {$f1} "v1\n"; close $f1;
    open my $f2, '>', $sibling_file or die; print {$f2} "v1\n"; close $f2;

    my $before = eval { BpWatch::artifact_snapshot([$watched_file]) };
    is(ref $before, 'HASH', 'E1: artifact_snapshot returns a hashref');
    ok(exists $before->{$watched_file}, 'E2: snapshot keys on the configured path');
    ok(!exists $before->{$sibling_file},
       'E3 INVARIANT-4 CANONICAL: the snapshot does NOT contain the sibling package\'s file at '
     . 'all — it was never in the configured @paths list. A tree-wide scan (bp-watchdog.pl\'s '
     . 'live defect) would see it; a subject-scoped one cannot');

    # Touch ONLY the sibling file (simulates an unrelated package's own ledger
    # write — exactly the shape that manufactured false PROGRESS verdicts,
    # per the package's own dispatch-log entries).
    sleep 1;   # ensure a distinguishable mtime tick on filesystems with 1s resolution
    open my $f3, '>>', $sibling_file or die; print {$f3} "touched\n"; close $f3;
    my $after_sibling_touch = eval { BpWatch::artifact_snapshot([$watched_file]) };
    my $changed_from_sibling = eval {
        BpWatch::artifact_changed($before, $after_sibling_touch)
    };
    ok(!$changed_from_sibling,
       'E4 INVARIANT-4 CANONICAL: touching the SIBLING file produces NO detected change for '
     . 'the watched subject — proves the scan is not tree-wide. This is the exact scenario '
     . '(a driver\'s own ledger edit) that manufactured VERDICT: PROGRESS under bp-watchdog.pl '
     . 'while a real 4-hour stall was in progress');

    # NOW touch the actually-watched file -> must be detected.
    open my $f4, '>>', $watched_file or die; print {$f4} "touched\n"; close $f4;
    my $after_watched_touch = eval { BpWatch::artifact_snapshot([$watched_file]) };
    my $changed_from_watched = eval {
        BpWatch::artifact_changed($before, $after_watched_touch)
    };
    ok($changed_from_watched,
       'E5: touching the WATCHED file IS detected — E4\'s negative result is attributable to '
     . 'subject-scoping, not to a function that never detects any change at all');
}
{
    # Missing path -> undef, never 0 (0 would collide with a real epoch-0 mtime).
    my $root = tempdir(CLEANUP => 1);
    my $missing = "$root/does-not-exist.md";
    my $snap = eval { BpWatch::artifact_snapshot([$missing]) };
    ok(exists $snap->{$missing}, 'E6: a missing path still gets an entry in the snapshot');
    ok(!defined $snap->{$missing},
       'E7: ...and its value is undef, not 0 — 0 would be misread as "always changed" against '
     . 'a real epoch-0 mtime');

    # undef -> defined ("appeared") counts as a change.
    my $before = { $missing => undef };
    open my $fh, '>', $missing or die; close $fh;
    my $after = eval { BpWatch::artifact_snapshot([$missing]) };
    ok(eval { BpWatch::artifact_changed($before, $after) },
       'E8: a path going from undef (absent) to defined (appeared) counts as a change');
}

# ===========================================================================
# F. THE UMBRELLA RULE (§0) — resolve_condition, the single combinator every
#    invariant hangs off. Priority order per spec §2.1, evaluated top-down,
#    first match wins. Section F1 is the CANONICAL invariant-9 test: total
#    uncertainty must resolve to undef (keep polling), never 'terminal'.
# ===========================================================================
{
    # F1 — THE CANONICAL TEST the red-team brief (pipeline step 6) is aimed
    # at: "find an input where the watcher concludes finished wrongly." This
    # one must not exist. Falsifiable: any implementation that defaults an
    # unset/undef field to a "confirmed" reading (Perl truthiness treating
    # undef pids_alive as 0, for instance) will return 'workers-gone' or
    # 'terminal' here instead of undef.
    my $got = eval { BpWatch::resolve_condition({
        status => undef, prior_status => undef,
        pids_alive => undef, artifact_changed => 0, bound_hit => 0,
    }) };
    ok(!defined $got,
       'F1 UMBRELLA-RULE CANONICAL (invariant 9): total uncertainty (everything undef/false, '
     . 'nothing has actually expired) -> undef (keep polling), NEVER \'terminal\' — the direct '
     . 'test the umbrella rule exists to make impossible to fail silently');
}
{
    # F2 — rule 1: a terminal status wins outright, regardless of every other
    # signal (even a simultaneous bound_hit).
    my $got = eval { BpWatch::resolve_condition({
        status => 'done', prior_status => 'running',
        pids_alive => 0, artifact_changed => 1, bound_hit => 1,
    }) };
    is($got, 'terminal', 'F2: a terminal status wins over every other simultaneous signal');
}
{
    # F3 — invariant 1 threaded through resolve_condition directly: a
    # non-allowlisted status (even one that LOOKS terminal-ish) never
    # produces 'terminal'.
    my $got = eval { BpWatch::resolve_condition({
        status => 'converging', prior_status => 'running',
        pids_alive => undef, artifact_changed => 0, bound_hit => 0,
    }) };
    isnt($got, 'terminal',
        'F3: resolve_condition never returns \'terminal\' for the free-text \'converging\' '
      . 'status, threading invariant 1 through the combinator directly');
}
{
    # F4 — rule 2: pids_alive defined and == 0 -> workers-gone, when no
    # terminal status is present.
    my $got = eval { BpWatch::resolve_condition({
        status => 'pending', prior_status => 'pending',
        pids_alive => 0, artifact_changed => 0, bound_hit => 0,
    }) };
    is($got, 'workers-gone', 'F4: pids_alive==0 (defined, confirmed dead) -> workers-gone');
}
{
    # F5 — THE undef-vs-0 DISTINCTION IS LOAD-BEARING (spec §2.1's own
    # warning: "Perl truthiness alone would treat undef as false and misfire
    # here"). pids_alive => undef must NEVER reach the workers-gone rule.
    my $got = eval { BpWatch::resolve_condition({
        status => 'pending', prior_status => 'pending',
        pids_alive => undef, artifact_changed => 0, bound_hit => 0,
    }) };
    isnt($got, 'workers-gone',
        'F5 CANONICAL undef-vs-0: pids_alive => undef ("not applicable", no pid axis '
      . 'configured) must NEVER be misread as \'workers-gone\' — this is the exact bug the '
      . 'spec calls out by name (bare Perl truthiness treating undef as false)');
    ok(!defined $got, 'F5b: ...and with every other signal also false/undef, the whole '
                      . 'call resolves to undef (keep polling), not any verdict at all');
}
{
    # F6 — rule 3: artifact_changed -> 'artifact', when no terminal/workers-gone.
    my $got = eval { BpWatch::resolve_condition({
        status => 'pending', prior_status => 'pending',
        pids_alive => 1, artifact_changed => 1, bound_hit => 0,
    }) };
    is($got, 'artifact', 'F6: artifact_changed (true) -> artifact');
}
{
    # F7 — rule 4: status-change ONLY when both status and prior_status are
    # defined and differ, and status is non-terminal (else rule 1 already won).
    my $got = eval { BpWatch::resolve_condition({
        status => 'reviewing', prior_status => 'running',
        pids_alive => 1, artifact_changed => 0, bound_hit => 0,
    }) };
    is($got, 'status-change', 'F7: a non-terminal status differing from prior -> status-change');

    my $got_same = eval { BpWatch::resolve_condition({
        status => 'running', prior_status => 'running',
        pids_alive => 1, artifact_changed => 0, bound_hit => 0,
    }) };
    isnt($got_same, 'status-change',
        'F8: an UNCHANGED status (same as prior) never fires status-change');

    my $got_no_prior = eval { BpWatch::resolve_condition({
        status => 'running', prior_status => undef,
        pids_alive => 1, artifact_changed => 0, bound_hit => 0,
    }) };
    isnt($got_no_prior, 'status-change',
        'F9: an undefined prior_status (nothing to compare against yet) never fires '
      . 'status-change — an unknown prior is not evidence of a change');
}
{
    # F10 — rule 5: bound_hit, last resort, only when nothing else fired.
    my $got = eval { BpWatch::resolve_condition({
        status => 'pending', prior_status => 'pending',
        pids_alive => 1, artifact_changed => 0, bound_hit => 1,
    }) };
    is($got, 'bound', 'F10: bound_hit (true), nothing else fired -> bound');
}
{
    # F11 — priority: artifact beats bound when both are simultaneously true.
    my $got = eval { BpWatch::resolve_condition({
        status => 'pending', prior_status => 'pending',
        pids_alive => 1, artifact_changed => 1, bound_hit => 1,
    }) };
    is($got, 'artifact', 'F11: artifact_changed beats bound_hit when both fire simultaneously '
                        . '(priority order, spec §2.1)');
}
{
    # F12 — priority: workers-gone beats artifact and bound.
    my $got = eval { BpWatch::resolve_condition({
        status => 'pending', prior_status => 'pending',
        pids_alive => 0, artifact_changed => 1, bound_hit => 1,
    }) };
    is($got, 'workers-gone', 'F12: workers-gone (rule 2) beats artifact/bound (rules 3/5)');
}

# ===========================================================================
# G. format_change_line — criterion 4 dedup: one line per CHANGE, not per poll.
# ===========================================================================
{
    my $snap1 = { status => 'running', pids_alive => 1, artifact_changed_flag => 0 };
    my $snap2 = { status => 'running', pids_alive => 1, artifact_changed_flag => 0 };
    my $line_same = eval { BpWatch::format_change_line($snap1, $snap2) };
    ok(!defined $line_same,
       'G1 CANONICAL DEDUP: two identical consecutive snapshots -> undef (no line) — a poll '
     . 'tick where nothing moved must print nothing, never a repeated "nothing changed" line');

    my $snap3 = { status => 'done', pids_alive => 1, artifact_changed_flag => 0 };
    my $line_diff = eval { BpWatch::format_change_line($snap1, $snap3) };
    ok(defined $line_diff,
       'G2: a snapshot pair that DOES differ (status changed) -> a defined line — G1\'s undef '
     . 'is attributable to genuine sameness, not a function that always returns undef');
    ok(length($line_diff // '') > 0, 'G3: the produced line is non-empty text');
}

done_testing();
