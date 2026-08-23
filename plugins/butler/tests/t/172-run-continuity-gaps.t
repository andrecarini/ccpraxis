#!/usr/bin/env perl
# t10-run-continuity-gaps -- the oracle for blueprint tui-operator-feedback.
#
# Two filed reports about a run's own lifecycle, both closed here, and both
# closed the SAME WAY: by ending a silence rather than by adding a refusal.
#
#   20260819-123218-45c3 -- the Stop gate verifies a pause is WELL-FORMED
#     (watcher pid alive and fingerprinted, deadline in the future) but never
#     that any work is pending. A backgrounded sleep loop armed solely to
#     satisfy the gate passes every check. Observed live: a run idled roughly
#     seven hours before the operator noticed.
#
#   20260819-145104-4651 -- a manually-driven blueprint can complete fully and
#     never be archivable. reconcile reported all_delivered:1 with an EMPTY
#     action list, exited 0, printed nothing, and looked exactly like success.
#
# DONE-CRITERION 4 IS THE CONSTRAINT THAT SHAPES BOTH FIXES: neither may block a
# correct run. Both guards sit on the path every driver takes, and a wrong
# refusal is strictly worse than the gap it closes -- so PART 1 and PART 3 spend
# most of their assertions proving that nothing was made refusable.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Test::More;
use JSON::PP;

my $RS  = "$Bin/../../scripts/bp-runstate.pl";
my $LC  = "$Bin/../../scripts/bp-lifecycle.pl";
ok(-f $RS, 'bp-runstate.pl exists')  or BAIL_OUT('missing');
ok(-f $LC, 'bp-lifecycle.pl exists') or BAIL_OUT('missing');

# ---------------------------------------------------------------------------
# A live watcher we control. Deliberately a real process: the whole point of
# the pause contract is that the pid is verified, so a fabricated one would
# exercise a different path.
# ---------------------------------------------------------------------------
my $WATCHER = fork();
if (defined $WATCHER && $WATCHER == 0) { sleep 900; exit 0 }
ok(defined $WATCHER && $WATCHER > 0, 'a live watcher process is available') or BAIL_OUT('no fork');
END { kill('KILL', $WATCHER) if defined $WATCHER && $WATCHER > 0 }

sub rs {
    my ($root, @args) = @_;
    my $cmd = join(' ', map { qq("$_") } ('perl', $RS, @args, '--root', $root));
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out // '');
}
sub newroot { my $r = tempdir(CLEANUP => 1); make_path("$r/.ccpraxis-local-data"); return $r }
sub status_of {
    my ($root) = @_;
    my (undef, $out) = rs($root, 'status');
    return eval { JSON::PP->new->decode($out) } || {};
}

# ===========================================================================
# PART 1 -- the hollow pause WARNS and never refuses.
# ===========================================================================
my $FUTURE = time + 1800;
{
    my $root = newroot();
    rs($root, 'activate', '--reason', 'x');

    my ($rc, $out) = rs($root, 'pause', '--watcher-pid', $WATCHER, '--until', $FUTURE);
    is($rc, 0,
        'AC1: a pause with nothing declared is still GRANTED -- done-criterion 4, a wrong refusal here blocks a correct run');
    like($out, qr/WARNING/,
        'AC1: but it warns, at the moment the driver can still fix it');
    like($out, qr/live pid is not evidence/,
        'AC1: and the warning names the actual gap -- a verified pid is not evidence that work is in flight');
    is(status_of($root)->{state}, 'paused',
        'AC1: the pause really did take effect; the warning is not a disguised refusal');
    is(status_of($root)->{hollow_pause}, 1,
        'AC1: and the state RECORDS that it was hollow, so a later reader need not rediscover it');
}

# AC2 -- a declared watch is accepted silently. Without this, AC1 would be
# satisfied by a warning that fires unconditionally, which teaches a driver to
# ignore it.
{
    my $root = newroot();
    rs($root, 'activate', '--reason', 'x');
    my ($rc, $out) = rs($root, 'pause', '--watcher-pid', $WATCHER, '--until', $FUTURE,
                        '--watching', 'bp-implementer for t10, task abc123');
    is($rc, 0, 'AC2: a pause that names its work is granted');
    unlike($out, qr/WARNING/,
        'AC2: and does NOT warn -- a warning that always fires is a warning nobody reads');
    is(status_of($root)->{hollow_pause}, 0, 'AC2: and is not recorded as hollow');
    is(status_of($root)->{watching}, 'bp-implementer for t10, task abc123',
        'AC2: the declaration is kept verbatim');
}

# AC3 -- a timer-shaped declaration is not a declaration. This is the case the
# report actually described: a watcher armed solely to satisfy the gate.
for my $timerish ('sleep', 'timer', 'wait', 'nothing', 'n/a', '--') {
    my $root = newroot();
    rs($root, 'activate', '--reason', 'x');
    my ($rc, $out) = rs($root, 'pause', '--watcher-pid', $WATCHER, '--until', $FUTURE,
                        '--watching', $timerish);
    is($rc, 0, "AC3 [$timerish]: still granted -- never a refusal");
    like($out, qr/describes a timer, not work/,
        "AC3 [$timerish]: a watcher described only as a timer IS only a timer, and is warned about");
}

# AC4 -- every pre-existing refusal still refuses. The warning must not have
# loosened the checks that were already doing real work.
{
    my $root = newroot();
    rs($root, 'activate', '--reason', 'x');

    my ($rc1) = rs($root, 'pause', '--watcher-pid', 999999, '--until', $FUTURE);
    isnt($rc1, 0, 'AC4: a watcher pid that is not running is still REFUSED');

    my ($rc2) = rs($root, 'pause', '--watcher-pid', $WATCHER, '--until', time - 5);
    isnt($rc2, 0, 'AC4: a deadline in the past is still REFUSED');

    my ($rc3) = rs($root, 'pause', '--watcher-pid', $WATCHER);
    isnt($rc3, 0, 'AC4: a missing deadline is still REFUSED -- an unbounded pause never resumes');

    # ...and a declared watch cannot buy past any of them.
    my ($rc4) = rs($root, 'pause', '--watcher-pid', 999999, '--until', $FUTURE,
                   '--watching', 'a very real worker indeed');
    isnt($rc4, 0,
        'AC4: --watching does not launder a dead watcher -- it is a label, never a credential');
}

# ===========================================================================
# PART 2 -- the settled-but-unaudited blueprint SPEAKS.
# ===========================================================================
sub mkbp {
    my (%o) = @_;
    my $root = tempdir(CLEANUP => 1);
    my $bps  = "$root/.ccpraxis-local-data/blueprints";
    my $dir  = "$bps/$o{name}";
    make_path("$dir/packages", "$dir/runs");
    # A BLUEPRINT'S STATUS LIVES IN A FENCED CODE BLOCK, NOT IN YAML
    # FRONTMATTER -- a package ledger's does, and a blueprint's does not.
    # This project's own CLAUDE.md records the trap by name: a frontmatter
    # fixture silently yields an EMPTY authored status, so the whole
    # never-audited branch is skipped and the test passes or fails for a reason
    # that has nothing to do with the code. The first draft of this file did
    # exactly that, and six assertions failed with `status_before: ""`.
    # Shape copied from t/161-lifecycle-derived.t's blueprint_md, as that
    # CLAUDE.md entry instructs.
    open(my $b, '>', "$dir/blueprint.md") or die $!;
    print {$b} "# $o{name}\n\n```\nblueprint: $o{name}\ncreated: 2026-01-01\n"
             . "last_updated: 2026-01-01T00:00Z\n"
             . "status: $o{status}        # drafting | audited | running | done | archived\n"
             . "```\n\n## Objective\n\nTest fixture.\n";
    close $b;
    for my $p (@{ $o{pkgs} || [] }) {
        open(my $f, '>', "$dir/packages/$p->{name}.md") or die $!;
        print {$f} "---\npackage: $p->{name}\nblueprint: $o{name}\nstatus: $p->{status}\n"
                 . "last_updated: 2026-01-01T00:00:00Z\n---\n\n# body\n";
        close $f;
    }
    open(my $r, '>', "$dir/runs/registry.json") or die $!; print {$r} '{"packages":{}}'; close $r;
    return ($root, $dir);
}

sub reconcile {
    my ($root, $name, @extra) = @_;
    my $cmd = join(' ', map { qq("$_") }
        ('perl', $LC, 'reconcile', '--blueprint', $name,
         '--data-dir', "$root/.ccpraxis-local-data", '--dry-run', @extra));
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out // '');
}

{
    my ($root) = mkbp(name => 'stuck', status => 'drafting',
        pkgs => [ { name => 'p1', status => 'done' }, { name => 'p2', status => 'done' } ]);

    my ($rc, $json) = reconcile($root, 'stuck', '--json');
    is($rc, 0, 'AC5: reconcile still exits 0 -- being stuck is a state to report, not an error');

    my $r = eval { JSON::PP->new->decode($json) };
    ok(ref($r) eq 'ARRAY' && @$r, 'AC5: and returns a report') or diag("  out: $json");
  SKIP: {
        skip('no report', 4) unless ref($r) eq 'ARRAY' && @$r;
        is($r->[0]{all_delivered}, 1, 'AC5 precondition: every package is delivered');
        cmp_ok(scalar(@{ $r->[0]{actions} || [] }), '>', 0,
            'AC5: the action list is NO LONGER EMPTY -- the empty list was the whole defect, because it exited 0 and looked exactly like success');
        my ($blocked) = grep { ($_->{kind} // '') eq 'blocked' } @{ $r->[0]{actions} };
        ok($blocked, 'AC5: and it says it is BLOCKED');
        is(($blocked || {})->{reason}, 'never-audited',
            'AC5: naming the actual reason, so a future reader does not have to derive it');
    }

    # AC6 -- the HUMAN path was the silent one too. print_report skips a
    # blueprint with no actions and no errors, so this printed nothing at all.
    my (undef, $text) = reconcile($root, 'stuck');
    like($text, qr/stuck/,  'AC6: the human report names the blueprint at all, where it used to print nothing');
    like($text, qr/blocked/, 'AC6: and says blocked');
    like($text, qr/drafting/, 'AC6: and quotes the field that is actually holding it');
}

# AC7 -- THE AUDIT GATE IS NOT BACKDATED. Done-criterion 3 forbids writing
# `audited` for a blueprint that was never audited: that is the failure this
# would be papering over, and it is worse than the bug.
{
    my ($root, $dir) = mkbp(name => 'stuck2', status => 'drafting',
        pkgs => [ { name => 'p1', status => 'done' } ]);
    my $before = do { open my $f, '<', "$dir/blueprint.md" or die; local $/; <$f> };
    reconcile($root, 'stuck2', '--json');
    reconcile($root, 'stuck2');
    my $after = do { open my $f, '<', "$dir/blueprint.md" or die; local $/; <$f> };
    is($after, $before,
        'AC7: blueprint.md is byte-identical afterwards -- reconcile reports the block and writes NOTHING');
    # Not anchored at end-of-line: the status line legitimately carries the
    # vocabulary comment (`# drafting | audited | running | done | archived`),
    # which is exactly the shape the real blueprint.md uses.
    like($after, qr/^status:[ \t]*drafting\b/m,
        'AC7: specifically, status is still drafting and was not advanced to audited');
}

# AC8 -- the diagnostic fires only for the case it describes. A guard that
# fires everywhere is noise, and noise is how a real signal gets ignored.
my @NOT_STUCK = (
    [ 'audited, all delivered', 'audited',  [ { name => 'p1', status => 'done' } ] ],
    [ 'drafting, work still open', 'drafting', [ { name => 'p1', status => 'done' },
                                                 { name => 'p2', status => 'converging' } ] ],
    [ 'drafting, nothing delivered', 'drafting', [ { name => 'p1', status => 'pending' } ] ],
);
for my $c (@NOT_STUCK) {
    my ($label, $status, $pkgs) = @$c;
    my ($root) = mkbp(name => 'other', status => $status, pkgs => $pkgs);
    my (undef, $json) = reconcile($root, 'other', '--json');
    my $r = eval { JSON::PP->new->decode($json) } || [];
    my $blocked = (ref($r) eq 'ARRAY' && @$r)
                ? scalar(grep { ($_->{kind} // '') eq 'blocked' } @{ $r->[0]{actions} || [] }) : 0;
    is($blocked, 0, "AC8 [$label]: no never-audited diagnostic -- it fires only for the case it describes");
}

# ===========================================================================
# PART 3 -- neither fix can block a correct run (done-criterion 4), asserted
# as one statement rather than left implied by the cases above.
# ===========================================================================
{
    my $root = newroot();
    rs($root, 'activate', '--reason', 'x');
    my ($rc) = rs($root, 'pause', '--watcher-pid', $WATCHER, '--until', $FUTURE);
    is($rc, 0, 'AC9: the pause path added no new refusal');

    my ($root2) = mkbp(name => 'ok', status => 'audited',
        pkgs => [ { name => 'p1', status => 'done' } ]);
    my ($rc2) = reconcile($root2, 'ok', '--json');
    is($rc2, 0, 'AC9: the reconcile path added no new failing exit');
}

done_testing();
