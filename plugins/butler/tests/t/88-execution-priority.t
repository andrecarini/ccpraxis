#!/usr/bin/env perl
# t/88-execution-priority.t — immutable oracle for b44-execution-priority.
# Tests B1..B10 from specs/b44-execution-priority-spec.md §4.
# (B11 — no collateral damage to t/06 / t/17 — is verified by the coordinator
# separately, not asserted inside this file.)
#
# Neither BpOrch::order_ready nor priority-reading exists yet in either script,
# so most tests here MUST fail right now — that is the correct starting state.
#
# Safety: module-level `require` + direct function calls ONLY. Never invoke
# either script's `main` path; never spawn launcher.pl / bp-launch.sh / a
# container. STDERR captured via File::Temp only (never an in-memory scalar —
# Git-for-Windows perl fails "Bad file descriptor" on that).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempfile);

# ── require both scripts as modules (guarded: must not die the whole file) ──
my $ORCH_PATH  = "$Bin/../../scripts/bp-orchestrator.pl";
my $DRIVE_PATH = "$Bin/../../scripts/bp-drive-next.pl";

my $ORCH_LOADED = do { local $@; eval { require $ORCH_PATH }; !$@ };
ok($ORCH_LOADED, 'setup: bp-orchestrator.pl requires cleanly as a module')
    or diag("require failed: $@");

my $DRIVE_LOADED = do { local $@; eval { require $DRIVE_PATH }; !$@ };
ok($DRIVE_LOADED, 'setup: bp-drive-next.pl requires cleanly as a module')
    or diag("require failed: $@");

# ── helper: call BpOrch::order_ready without letting an undefined-sub die
#    take down the whole file. Returns ($listref_or_undef, $error_or_undef).
sub try_order_ready {
    my ($ready, $meta) = @_;
    my @out;
    my $ok = eval { @out = BpOrch::order_ready($ready, $meta); 1 };
    return $ok ? (\@out, undef) : (undef, $@);
}

# ── helper: capture STDERR produced by a coderef via a real temp file (never
#    an in-memory scalar filehandle — landmine #2 / SYN-noted Windows failure).
sub capture_stderr {
    my ($code) = @_;
    my ($efh, $epath) = tempfile('t88-errXXXXXX', TMPDIR => 1);
    close $efh;
    open my $olderr, '>&STDERR' or die "dup STDERR: $!";
    open STDERR, '>:raw', $epath or do { open STDERR, '>&', $olderr; die "reopen STDERR: $!" };
    my @ret;
    my $ok = eval { @ret = $code->(); 1 };
    my $err_died = $@;
    open STDERR, '>&', $olderr or die "restore STDERR: $!";
    close $olderr;
    my $captured = do {
        open my $r, '<:raw', $epath or die "read stderr capture: $!";
        local $/; my $x = <$r>; close $r; defined $x ? $x : '';
    };
    unlink $epath;
    return (\@ret, $captured, $ok, $err_died);
}

# =============================================================================
# B1 — no-priority regression (DC-1): identical to sort of the same names.
# =============================================================================
{
    my $meta = {
        charlie => { deps => [], write_set => 'p/charlie/' },
        alpha   => { deps => [], write_set => 'p/alpha/' },
        echo    => { deps => [], write_set => 'p/echo/' },
        delta   => { deps => [], write_set => 'p/delta/' },
        bravo   => { deps => [], write_set => 'p/bravo/' },
    };
    my ($out, $err) = try_order_ready(
        [qw(charlie alpha echo delta bravo)], $meta
    );
    ok(defined $out, 'B1: order_ready callable with no priority annotations at all')
        or diag("order_ready died: $err");
    if (defined $out) {
        is_deeply($out, [qw(alpha bravo charlie delta echo)],
            'B1: no-priority regression — order is literal alphabetical sort, and $ready[0] would be the sort-first pkg');
    } else {
        fail('B1: order_ready must exist to prove the no-priority regression');
    }
}

# =============================================================================
# B2 — lower priority sorts first (DC-2): 30/10/20 over c/a/b -> b,c,a.
# =============================================================================
{
    my $meta = {
        # Coordinator fix at step 4: the spec's B2 wording ("priorities 30, 10, 20
        # over names c, a, b -> order b(10), c(20), a(30)") is self-contradictory —
        # that mapping gives c=30, a=10, b=20, whose correct order is [a,b,c], i.e.
        # exactly alphabetical, which defeats the criterion. The EXPECTATION [b,c,a]
        # is the intended one (priority must beat alphabetical); the fixture was the
        # wrong half. Corrected here: b=10, c=20, a=30.
        a => { deps => [], write_set => 'p/a/', priority => 30 },
        b => { deps => [], write_set => 'p/b/', priority => 10 },
        c => { deps => [], write_set => 'p/c/', priority => 20 },
    };
    my ($out, $err) = try_order_ready([qw(c a b)], $meta);
    ok(defined $out, 'B2: order_ready callable with explicit numeric priorities') or diag($err);
    # Unconditional (coordinator, step-3 gate): a bare `if defined $out` makes the
    # criterion's ONLY substantive assertion silently vanish when order_ready is
    # absent, so the plan count shifts and the criterion yields no TDD signal.
    is_deeply($out // [], [qw(b c a)],
        'B2: lower priority first — b(10), c(20), a(30), beating alphabetical');
}

# =============================================================================
# B3 — equal priorities fall back to alphabetical (DC-2).
# =============================================================================
{
    my $meta = {
        c => { deps => [], write_set => 'p/c/', priority => 5 },
        a => { deps => [], write_set => 'p/a/', priority => 5 },
        b => { deps => [], write_set => 'p/b/', priority => 5 },
    };
    my ($out, $err) = try_order_ready([qw(c a b)], $meta);
    ok(defined $out, 'B3: order_ready callable with equal priorities') or diag($err);
    is_deeply($out // [], [qw(a b c)],
        'B3: equal priorities fall back to alphabetical (a, b, c)');
}

# =============================================================================
# B4 — mixed default and explicit (DC-2): annotated<100 ahead of every
# un-annotated; annotated>100 behind every un-annotated; un-annotated block
# stays internally alphabetical.
# =============================================================================
{
    my $meta = {
        g => { deps => [], write_set => 'p/g/', priority => 50 },   # explicit < 100
        k => { deps => [], write_set => 'p/k/', priority => 150 },  # explicit > 100
        e => { deps => [], write_set => 'p/e/' },                    # un-annotated -> 100
        a => { deps => [], write_set => 'p/a/' },                    # un-annotated -> 100
        c => { deps => [], write_set => 'p/c/' },                    # un-annotated -> 100
    };
    my ($out, $err) = try_order_ready([qw(g k e a c)], $meta);
    ok(defined $out, 'B4: order_ready callable with mixed default/explicit') or diag($err);
    is_deeply($out // [], [qw(g a c e k)],
        'B4: explicit<100 (g) ahead of default block (a,c,e alphabetical) ahead of explicit>100 (k)');
}

# =============================================================================
# B5 — malformed is non-fatal and logged (DC-3): '', '1.5', 'high', '1e3', '+5'.
# Each treated as the default (100); one STDERR line names pkg + raw value;
# never dies. Positioned between an explicit-1 and an explicit-200 package so
# the "treated as literally 100" claim is provable, not just alphabetical luck.
# =============================================================================
for my $bad ('', '1.5', 'high', '1e3', '+5') {
    my $meta = {
        lo  => { deps => [], write_set => 'p/lo/',  priority => 1 },
        bad => { deps => [], write_set => 'p/bad/', priority => $bad },
        hi  => { deps => [], write_set => 'p/hi/',  priority => 200 },
    };
    my ($ret, $stderr, $ok, $died) = capture_stderr(sub {
        return try_order_ready([qw(hi bad lo)], $meta);
    });
    # Same correction as B6: assert on try_order_ready's own return, not on whether
    # the (never-dying) coderef died.
    my ($out, $inner_err) = @{ $ret || [] };
    ok(defined $out, "B5: order_ready returns for malformed priority " . (length($bad) ? "'$bad'" : "'' (empty)"))
        or diag("order_ready died: " . ($inner_err // $died // 'not implemented'));
    if (defined $out) {
        is_deeply($out, [qw(lo bad hi)],
            "B5: malformed '$bad' is ordered exactly as default 100 (between lo=1 and hi=200)");
    } else {
        fail("B5: order_ready must return a list for malformed '$bad'") if $ok;
    }
    like($stderr, qr/\bbad\b/, "B5: STDERR names the package 'bad' for malformed value '$bad'");
    if (length $bad) {
        like($stderr, qr/\Q$bad\E/, "B5: STDERR includes the offending raw value '$bad'");
    } else {
        like($stderr, qr/priority/i, "B5: STDERR mentions priority for the empty-string case");
    }
}

# =============================================================================
# B6 — negative is legal, not malformed (DC-3): -5 ahead of 0 and every default;
# no malformed-value warning produced.
# =============================================================================
{
    my $meta = {
        neg => { deps => [], write_set => 'p/neg/', priority => -5 },
        zer => { deps => [], write_set => 'p/zer/', priority => 0 },
        d1  => { deps => [], write_set => 'p/d1/' },
        d2  => { deps => [], write_set => 'p/d2/' },
    };
    my ($ret, $stderr, $ok, $died) = capture_stderr(sub {
        return try_order_ready([qw(d2 d1 zer neg)], $meta);
    });
    # Coordinator, step-3 gate: `$ok` here is capture_stderr's — whether the CODEREF
    # died. try_order_ready traps internally and never dies, so `ok($ok, ...)` was
    # asserting that a sub which cannot die didn't die: true forever, implementation
    # or not. Derive liveness from try_order_ready's own return instead. Before this
    # fix B6 contributed ZERO failing assertions and gave no TDD signal at all.
    my ($out, $inner_err) = @{ $ret || [] };
    ok(defined $out, 'B6: order_ready callable with a legal negative priority')
        or diag("order_ready died: " . ($inner_err // $died // 'not implemented'));
    is_deeply($out // [], [qw(neg zer d1 d2)],
        'B6: negative (-5) sorts ahead of 0, which sorts ahead of every default (100)');
    is($stderr, '', 'B6: no malformed-value warning is produced for a legal negative integer');
}

# =============================================================================
# B7 — priority never promotes the ineligible (DC-4). Three sub-cases, each
# with the high-priority package pinned to -999; it must be wholly ABSENT from
# the ready set, never merely ranked low.
# =============================================================================
{
    # (a) unmet dependency
    my $meta_a = {
        hi => { deps => ['x'], write_set => 'p/hi/', priority => -999 },
        x  => { deps => [],    write_set => 'p/x/' },
        ok => { deps => [],    write_set => 'p/ok/', priority => 100 },
    };
    my $status_a = { hi => 'pending', x => 'pending', ok => 'pending' };
    my @ready_a = eval { BpOrch::ready_packages($meta_a, $status_a, []) };
    my $died_a  = $@;
    ok(!$died_a, 'B7(a): ready_packages does not die') or diag($died_a);
    ok(!(grep { $_ eq 'hi' } @ready_a),
        'B7(a): -999-priority package with an unmet dependency is ABSENT from the ready set');
    # Coordinator fix at step 4: 'x' is a filler dependency that is itself pending
    # with no deps of its own, so it is GENUINELY eligible — the original ['ok']
    # expectation asserted an exclusion the pre-existing deps_met logic never makes,
    # and would have forced a wrong "fix" to dependency semantics this package is
    # explicitly forbidden to touch. What B7(a) must prove is that 'hi' is absent
    # (asserted above); the eligible remainder is ok + x.
    is_deeply([sort @ready_a], ['ok', 'x'],
        'B7(a): the eligible remainder (ok, x) is unaffected by hi\'s -999 priority');
}
{
    # (b) write-set overlapping a running package
    my $meta_b = {
        hi  => { deps => [], write_set => 'p/run/sub/', priority => -999 },
        run => { deps => [], write_set => 'p/run/' },
        ok  => { deps => [], write_set => 'p/ok/', priority => 100 },
    };
    my $status_b = { hi => 'pending', run => 'running', ok => 'pending' };
    my @ready_b = eval { BpOrch::ready_packages($meta_b, $status_b, ['run']) };
    my $died_b  = $@;
    ok(!$died_b, 'B7(b): ready_packages does not die') or diag($died_b);
    ok(!(grep { $_ eq 'hi' } @ready_b),
        'B7(b): -999-priority package overlapping a running write-set is ABSENT from the ready set');
    is_deeply([sort @ready_b], ['ok'],
        'B7(b): the next eligible package (ok) is chosen, unaffected by hi\'s priority');
}
{
    # (c) status not pending: done / running / blocked / parked
    for my $st (qw(done running blocked parked)) {
        my $meta_c = {
            hi => { deps => [], write_set => 'p/hi/', priority => -999 },
            ok => { deps => [], write_set => 'p/ok/', priority => 100 },
        };
        my $status_c = { hi => $st, ok => 'pending' };
        my @ready_c = eval { BpOrch::ready_packages($meta_c, $status_c, []) };
        my $died_c  = $@;
        ok(!$died_c, "B7(c/$st): ready_packages does not die") or diag($died_c);
        ok(!(grep { $_ eq 'hi' } @ready_c),
            "B7(c/$st): -999-priority package with status '$st' is ABSENT from the ready set");
        is_deeply([sort @ready_c], ['ok'],
            "B7(c/$st): the next eligible package (ok) is chosen, unaffected by hi's priority");
    }
}

# =============================================================================
# B8 — one rule, two callers (DC-5).
# =============================================================================
{
    ok(defined &BpOrch::order_ready, 'B8: BpOrch::order_ready is defined (the sole implementation)');

    my $meta = {
        z => { deps => [], write_set => 'p/z/', priority => 5 },
        a => { deps => [], write_set => 'p/a/' },
        m => { deps => [], write_set => 'p/m/', priority => 5 },
    };
    my $status  = { z => 'pending', a => 'pending', m => 'pending' };
    my @orch_r  = eval { BpOrch::ready_packages($meta, $status, []) };
    my $died1   = $@;
    my @drive_r = eval { BpDrive::ready_packages($meta, $status, []) };
    my $died2   = $@;
    ok(!$died1, 'B8: BpOrch::ready_packages does not die') or diag($died1);
    ok(!$died2, 'B8: BpDrive::ready_packages does not die') or diag($died2);
    is_deeply(\@orch_r, \@drive_r,
        'B8: BpOrch::ready_packages and BpDrive::ready_packages return the SAME list for the same inputs')
        unless $died1 || $died2;

    # bp-drive-next.pl must not grow a second copy of the priority-sort rule; it
    # must delegate to BpOrch instead.
    open my $fh, '<', $DRIVE_PATH or die "cannot read $DRIVE_PATH: $!";
    local $/;
    my $src = <$fh>;
    close $fh;

    like($src, qr/BpOrch::order_ready/,
        'B8: bp-drive-next.pl source delegates to BpOrch::order_ready (does not reimplement it)');
    unlike($src, qr/sort\s*\{[^}]*priority[^}]*\}(?!.*BpOrch::order_ready)/s,
        'B8: bp-drive-next.pl source has no second sort-by-priority block outside a BpOrch delegation');
}

# =============================================================================
# B9 — determinism (DC-6): repeated calls, and different insertion/list order,
# yield identical output. Perl hash key order is randomised per-process, so
# this proves the rule doesn't ride on incidental hash order.
# =============================================================================
{
    my $meta = {
        delta => { deps => [], write_set => 'p/delta/', priority => 10 },
        alpha => { deps => [], write_set => 'p/alpha/' },
        gamma => { deps => [], write_set => 'p/gamma/', priority => 10 },
        beta  => { deps => [], write_set => 'p/beta/',  priority => -3 },
    };

    my ($r1) = try_order_ready([qw(delta alpha gamma beta)], $meta);
    my ($r2) = try_order_ready([qw(delta alpha gamma beta)], $meta);
    my ($r3) = try_order_ready([qw(delta alpha gamma beta)], $meta);
    ok(defined $r1 && defined $r2 && defined $r3, 'B9: order_ready callable for repeated-call check');
    if (defined $r1 && defined $r2 && defined $r3) {
        is_deeply($r1, $r2, 'B9: same $meta ordered twice returns identical lists');
        is_deeply($r2, $r3, 'B9: same $meta ordered a third time still returns the identical list');
    }

    # A differently-ordered @ready input list (the practical analogue of
    # "different hash insertion order", since $meta itself is a hash whose key
    # order is randomised by Perl regardless of literal source order).
    my ($r4) = try_order_ready([qw(beta gamma alpha delta)], $meta);
    my ($r5) = try_order_ready([qw(alpha beta delta gamma)], $meta);
    ok(defined $r4 && defined $r5, 'B9: order_ready callable with differently-ordered input lists');
    if (defined $r1 && defined $r4 && defined $r5) {
        is_deeply($r1, $r4, 'B9: differently-ordered @ready input (variant 1) yields the same output list');
        is_deeply($r1, $r5, 'B9: differently-ordered @ready input (variant 2) yields the same output list');
    }
}

# =============================================================================
# B10 — SYN-26's order is reproducible (DC-7). Fixture (NOT the live
# blueprint.md): b09, b32, b33, b38 all eligible; b32/b33/b38 annotated ahead
# of b09. Assert director yields b32, b33, b38 before b09.
# =============================================================================
{
    my $meta = {
        b09 => { deps => [], write_set => 'p/b09/' },                 # un-annotated -> 100
        b32 => { deps => [], write_set => 'p/b32/', priority => 10 },
        b33 => { deps => [], write_set => 'p/b33/', priority => 20 },
        b38 => { deps => [], write_set => 'p/b38/', priority => 30 },
    };
    my $status = { b09 => 'pending', b32 => 'pending', b33 => 'pending', b38 => 'pending' };
    my @ready  = eval { BpOrch::ready_packages($meta, $status, []) };
    my $died   = $@;
    ok(!$died, 'B10: ready_packages does not die on the SYN-26 fixture') or diag($died);
    is_deeply(\@ready, [qw(b32 b33 b38 b09)],
        'B10: annotated chain (b32,b33,b38) is selected before the un-annotated b09 (the concrete SYN-26 motivator)')
        unless $died;
}

done_testing();
