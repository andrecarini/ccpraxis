#!/usr/bin/env perl
# 97-lifecycle-reconcile.t — bp-lifecycle.pl, the derived-state reconciler.
#
# The defect this file pins down, stated once:
#
#   A blueprint carried four records of the same facts — the package ledgers,
#   blueprint.md's package-status TABLE, runs/registry.json, and blueprint.md's
#   own `status:` — and nothing kept them in agreement. Only the ledgers are
#   written by the thing that does the work. `sandbox-butler-overhaul` sat at
#   `status: running` with all 77 packages `done`; its registry.json still
#   claimed six running coordinators days after they died; its runs/.orchestrator
#   held a pid from a container that had been reaped. Every one of those was
#   found by a human reading files by hand.
#
# So the contract under test is: THE LEDGERS ARE THE TRUTH, everything else is
# repaired to match on observation, and a live run is never touched.
#
# These tests build real blueprint directories on disk and run the real script,
# because the bugs live in the file formats (blueprint.md's metadata is a fenced
# block, NOT `---` frontmatter — reading it the wrong way silently disables the
# whole lifecycle advance, which is a mistake this suite has already caught once).

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Cwd qw(abs_path);

my $DIR       = dirname(abs_path(do { (my $f = __FILE__) =~ s{\\}{/}g; $f }));
my $SCRIPTS   = "$DIR/../../scripts";
my $LIFECYCLE = "$SCRIPTS/bp-lifecycle.pl";

ok(-f $LIFECYCLE, 'bp-lifecycle.pl exists') or BAIL_OUT('nothing to test');

# --------------------------------------------------------------- fixtures ---

sub write_file {
    my ($path, $content) = @_;
    make_path(dirname($path)) unless -d dirname($path);
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh $content;
    close $fh;
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# A blueprint.md with the real shapes: a FENCED metadata block (not frontmatter)
# and a package-status table whose header carries `depends_on` (which is how
# bp-blueprint.pl locates it).
sub blueprint_md {
    my (%o) = @_;
    my $status = $o{status} // 'running';
    my $rows   = '';
    for my $p (@{ $o{packages} || [] }) {
        $rows .= "| $p->{pkg} | thing | — | sonnet | $p->{table} |\n";
    }
    return <<"MD";
# Test Blueprint

```
blueprint: $o{name}
created: 2026-01-01
last_updated: 2026-01-01T00:00Z
status: $status        # drafting | audited | running | done | archived
```

## Objective

Test fixture.

## Package status

| pkg | deliverable | depends_on | model | status |
|-----|-------------|------------|-------|--------|
$rows
## Harvest log

## Incidents

MD
}

sub ledger_md {
    my (%o) = @_;
    return <<"MD";
---
package: $o{pkg}
blueprint: $o{blueprint}
status: $o{status}
last_updated: 2026-01-01T00:00Z
---

# Package $o{pkg}

## Next action

None.
MD
}

# Build <root>/blueprints/<name>/ with ledgers, table, and optional run state.
# `packages` is [ { pkg, ledger, table } ] — ledger and table statuses are given
# SEPARATELY so drift between them can be constructed on purpose.
sub make_blueprint {
    my ($root, $name, %o) = @_;
    my $dir = "$root/blueprints/$name";
    make_path("$dir/packages");
    my @pkgs = @{ $o{packages} || [] };
    write_file("$dir/blueprint.md", blueprint_md(name => $name, status => $o{status} // 'running',
                                                 packages => \@pkgs));
    for my $p (@pkgs) {
        write_file("$dir/packages/$p->{pkg}.md",
                   ledger_md(pkg => $p->{pkg}, blueprint => $name, status => $p->{ledger}));
    }
    if (exists $o{marker}) {
        make_path("$dir/runs");
        write_file("$dir/runs/.orchestrator", $o{marker});
    }
    if ($o{registry}) {
        make_path("$dir/runs");
        require JSON::PP;
        write_file("$dir/runs/registry.json",
                   JSON::PP->new->canonical->pretty->encode($o{registry}));
    }
    return $dir;
}

sub run_lifecycle {
    my (@args) = @_;
    require File::Temp;
    my ($tfh, $tmp) = File::Temp::tempfile();
    close $tfh;
    # Capture through a REAL temp file, never an in-memory scalar handle:
    # Git-for-Windows perl fails that with "Bad file descriptor" (project
    # CLAUDE.md). Run exactly once — running twice would make every
    # already-applied mutation idempotent-by-accident and hide real bugs.
    open(my $saved, '>&', \*STDOUT) or die "dup: $!";
    open(STDOUT, '>', $tmp) or die "redirect: $!";
    my $rc = system($^X, $LIFECYCLE, @args, '--json');
    open(STDOUT, '>&', $saved);
    close $saved;
    my $out = slurp($tmp) // '';
    unlink $tmp;
    require JSON::PP;
    my $data = eval { JSON::PP->new->decode($out) };
    return ($rc >> 8, $data, $out);
}

# Read blueprint.md's fenced-block status the same way the script must.
sub bp_status_of {
    my ($file) = @_;
    my $c = slurp($file) // '';
    return '' unless $c =~ /^```\s*\n((?:.*\n)*?)^```\s*$/m;
    my $b = $1;
    return '' unless $b =~ /^status:[ \t]*([^\n#]*)/m;
    my $v = $1;
    $v =~ s/\s+\z//;
    return $v;
}

# ============================================================================
# 1. The headline case: every package done, blueprint still says running.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'all-done',
        status   => 'running',
        packages => [ { pkg => '01-a', ledger => 'done', table => 'done' },
                      { pkg => '02-b', ledger => 'done', table => 'done' } ],
    );

    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'all-done',
                                    '--data-dir', $root, '--no-archive');
    is($rc, 0, 'all-done: exit 0');
    # RE-WITNESSED for s04-lifecycle-derived (driver ruling 2026-08-14): DC3
    # forbids writing a literal `status: done`, so the stored field is no
    # longer where this guarantee is observable. Same guarantee (the
    # lifecycle ADVANCES to `done` without anyone asking) -- new witness (the
    # reconciler's derived `lifecycle` JSON field, not the raw stored word).
    is($data->[0]{lifecycle}, 'done',
       'all packages done -> lifecycle derives running -> done WITHOUT anyone asking');
    is($data->[0]{all_delivered}, 1, 'all_delivered reported');
    # AMENDED for s05-retire-reconciler-drift-paths (AC-5): the pseudo-action
    # push for kind 'lifecycle' is deleted outright -- $r{lifecycle} and
    # $r{all_delivered} (already asserted above) carry this information as
    # top-level fields now, so the absence claim below is paired, in the SAME
    # block, with the behavioral claim that the derivation itself still
    # advances -- not merely that the action list shrank.
    ok(!(grep { $_->{kind} eq 'lifecycle' } @{ $data->[0]{actions} }),
       's05 AC-5: no actions entry ever reports kind "lifecycle" -- the pseudo-action push is gone');
    is($data->[0]{lifecycle}, 'done',
       's05 AC-5: paired behavioral check -- the SAME fixture still derives lifecycle => "done" with no action announcing it');
}

# ============================================================================
# 2. One package short -> nothing advances. The guard against over-eagerness.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'one-parked',
        status   => 'running',
        packages => [ { pkg => '01-a', ledger => 'done',   table => 'done' },
                      { pkg => '02-b', ledger => 'parked', table => 'parked' } ],
    );
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'one-parked',
                                    '--data-dir', $root, '--no-archive');
    is($rc, 0, 'one-parked: exit 0');
    is(bp_status_of("$dir/blueprint.md"), 'running',
       'a parked package is terminal but NOT delivered -> blueprint stays running');
    is($data->[0]{all_delivered}, 0, 'all_delivered is false');
}

# ============================================================================
# 3. `drafting` is never advanced, even with zero unfinished packages.
#    A half-authored blueprint must not be declared finished.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'draft', status => 'drafting', packages => []);
    my ($rc) = run_lifecycle('reconcile', '--blueprint', 'draft',
                             '--data-dir', $root, '--no-archive');
    is(bp_status_of("$dir/blueprint.md"), 'drafting',
       'a drafting blueprint with no packages is NOT advanced (zero packages is not "all delivered")');
}

# ============================================================================
# 4. Stale orchestrator marker is cleared; a LIVE one freezes everything.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    # A pid that cannot be alive. 4194304 is above the default Linux pid_max and
    # is not a live Windows pid either.
    my $dir = make_blueprint($root, 'stale-marker',
        status   => 'running',
        marker   => "4194304\n",
        packages => [ { pkg => '01-a', ledger => 'done', table => 'done' } ],
    );
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'stale-marker',
                                    '--data-dir', $root, '--no-archive');
    ok(!-e "$dir/runs/.orchestrator", 'a marker whose pid is dead is removed');
    is($data->[0]{live}, 0, 'the run is reported not-live');
    # RE-WITNESSED for s04-lifecycle-derived (driver ruling 2026-08-14): same
    # guarantee (advancement survives a stale-marker sweep), new witness.
    is($data->[0]{lifecycle}, 'done', 'and the lifecycle still advances');
}
{
    my $root = tempdir(CLEANUP => 1);
    # Our own pid IS alive, so this stands in for a live orchestrator.
    my $dir = make_blueprint($root, 'live-run',
        status   => 'running',
        marker   => "$$\n",
        packages => [ { pkg => '01-a', ledger => 'done', table => 'pending' } ],
    );
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'live-run',
                                    '--data-dir', $root, '--no-archive');
    ok(-e "$dir/runs/.orchestrator", 'a LIVE run keeps its marker');
    is($data->[0]{live}, 1, 'the run is reported live');
    is(bp_status_of("$dir/blueprint.md"), 'running',
       'a live run owns its own state: nothing is advanced under it');
    ok((grep { $_->{kind} eq 'skipped' } @{ $data->[0]{actions} }),
       'and the skip is reported rather than silent');
}

# ============================================================================
# 5. Table drift: RETIRED for s05-retire-reconciler-drift-paths (AC-6), not
#    re-pointed. This block used to assert step 2's repair-fails shape
#    (retargeted for s03, see git history). Step 2 (read_table + the
#    'table_drift' action-kind + the bp_call_out('set-status', ...) call
#    site) is DELETED OUTRIGHT by this package -- there is no code path left
#    in bp-lifecycle.pl for a re-pointed assertion here to observe beyond
#    what plugins/butler/tests/t/153-no-drift-to-repair.t already covers
#    end-to-end (observable behavior 2: an old-shape blueprint with a
#    disagreeing table column reconciles clean, the table cell is
#    byte-unchanged, and -- the headline live-defect fix -- the blueprint
#    still actually archives). Recorded here per the ledger's own "recorded
#    in the report as retired, with the reason" option (Done Criterion 3):
#      - original location: this file, former :284-309 (pre-s05)
#      - retired assertions' subject: step 2's table-drift repair-fails
#        behavior (stale cell stays 'pending'; the failed repair attempt is
#        recorded as an error string 'could not set table status')
#      - reason: step 2 itself (read_table, the table_drift action-kind, the
#        set-status call site) is deleted; the guarantee that an old-shape
#        table no longer blocks reconciliation is re-proven by t/153's
#        unrepresentability thesis (observable behavior 2), which additionally
#        proves the STRONGER live-defect claim this block never could: that
#        archiving itself is no longer silently blocked by the now-impossible
#        error this block used to assert.
# ============================================================================

# ============================================================================
# 6. Registry drift: the exact sandbox-butler-overhaul shape — registry says
#    running/pending long after the ledgers went done, and carries dead pids.
#
# SPLIT for s05-retire-reconciler-drift-paths (AC-7), not retired wholesale.
# Step 3 did two unrelated things under one name: status-reconciliation (dead
# for every in-scope reader -- bp-orchestrator.pl::_load_state never consults
# registry status, per the spec's §1 finding) and pid-clearing (independently
# live: bp-orchestrator.pl:198-201 names bp-lifecycle.pl "the only clearer" of
# a terminal package's stray pid, and bp-status.sh:100 consumes that same
# column for its PROC display). So:
#   - RETIRED (subject deleted, same recorded-reason treatment as AC-6): the
#     two is($reg->{...}{status}, 'done', ...) assertions -- status
#     reconciliation no longer exists as code.
#   - REPLACED, in the same block, by a byte-unchanged assertion on the
#     'status' field where the fixture authors one (pairs the new absence
#     with a behavioral check, per observable behavior 3).
#   - SURVIVE UNCHANGED IN SUBSTANCE (only their witness changes): the "no
#     pid" and "attempt preserved" assertions, and the action-kind check --
#     grep { $_->{kind} eq 'registry_drift' } becomes
#     grep { $_->{kind} eq 'stale_pid' }.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'registry-drift',
        status   => 'running',
        packages => [ { pkg => '01-a', ledger => 'done', table => 'done' },
                      { pkg => '02-b', ledger => 'done', table => 'done' } ],
        registry => { packages => {
            '01-a' => { status => 'running', pid => 203741, attempt => 2 },
            '02-b' => { status => 'pending', pid => 203999, attempt => 1 },
        } },
    );
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'registry-drift',
                                    '--data-dir', $root, '--no-archive');
    require JSON::PP;
    my $reg = JSON::PP->new->decode(slurp("$dir/runs/registry.json"));
    is($reg->{packages}{'01-a'}{status}, 'running',
       's05 AC-7: registry status is NEVER reconciled -- byte-unchanged (still the pre-run authored value "running"), not repaired to the ledger');
    is($reg->{packages}{'02-b'}{status}, 'pending',
       's05 AC-7: same, for the second entry -- "pending" survives untouched too');
    ok(!exists $reg->{packages}{'01-a'}{pid},
       'a terminal package keeps no pid — a reused pid would redraw a dead run as live');
    is($reg->{packages}{'01-a'}{attempt}, 2, 'unrelated registry fields are preserved, not rewritten');
    ok((grep { $_->{kind} eq 'stale_pid' } @{ $data->[0]{actions} }),
       's05 AC-7: the surviving pid-clearing half is reported under the new, honest kind name "stale_pid"');
    ok(!(grep { $_->{kind} eq 'registry_drift' } @{ $data->[0]{actions} }),
       's05 AC-7: the old combined kind name "registry_drift" never appears again');
}

# ============================================================================
# 7. --dry-run changes nothing at all.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'dry',
        status   => 'running',
        marker   => "4194304\n",
        packages => [ { pkg => '01-a', ledger => 'done', table => 'pending' } ],
        registry => { packages => { '01-a' => { status => 'running', pid => 1 } } },
    );
    my $before_md  = slurp("$dir/blueprint.md");
    my $before_reg = slurp("$dir/runs/registry.json");

    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'dry',
                                    '--data-dir', $root, '--no-archive', '--dry-run');
    is(slurp("$dir/blueprint.md"),      $before_md,  '--dry-run leaves blueprint.md byte-identical');
    is(slurp("$dir/runs/registry.json"), $before_reg, '--dry-run leaves registry.json byte-identical');
    ok(-e "$dir/runs/.orchestrator", '--dry-run leaves even a stale marker in place');
    # RECOMPUTED for s05-retire-reconciler-drift-paths (AC-8), not left at a
    # loosened `>= 3`. The `dry` fixture above carries a stale marker, a
    # table-drift row (01-a: ledger done, table pending), and a terminal
    # package's stray registry pid. With step 2 (table_drift) and step 3's
    # status half (registry_drift) both deleted, the table-drift row now
    # produces ZERO actions -- asserted below as zero, not merely uncounted --
    # so the exact surviving count is 2: stale_marker (the marker) and
    # stale_pid (01-a's stray pid, since its ledger status 'done' is
    # terminal). The exact count is paired with explicit absence checks so a
    # regression that silently drops one of the two real actions cannot hide
    # behind an unrelated one reappearing.
    is(scalar @{ $data->[0]{actions} }, 2,
       's05 AC-8: --dry-run reports exactly 2 actions (stale_marker, stale_pid) -- not >= 3, recomputed for the deleted kinds');
    ok((grep { $_->{kind} eq 'stale_marker' } @{ $data->[0]{actions} }),
       's05 AC-8: stale_marker is one of the two');
    ok((grep { $_->{kind} eq 'stale_pid' } @{ $data->[0]{actions} }),
       's05 AC-8: stale_pid is the other of the two');
    ok(!(grep { $_->{kind} eq 'table_drift' } @{ $data->[0]{actions} }),
       's05 AC-8: no table_drift action appears -- the table-drift row in this fixture produces zero actions, asserted as zero');
    ok(!(grep { $_->{kind} eq 'registry_drift' } @{ $data->[0]{actions} }),
       's05 AC-8: no registry_drift action appears -- the combined kind name is gone');
    ok(!(grep { $_->{kind} eq 'lifecycle' } @{ $data->[0]{actions} }),
       's05 AC-8: no lifecycle pseudo-action appears');
    ok(!(grep { $_->{applied} } @{ $data->[0]{actions} }), 'nothing is marked applied under --dry-run');
}

# ============================================================================
# 8. Archiving: on for a delivered blueprint, off for anything else, and never
#    a delete.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'to-archive',
        status   => 'running',
        packages => [ { pkg => '01-a', ledger => 'done', table => 'done' } ],
    );
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'to-archive',
                                    '--data-dir', $root, '--archive');
    is($rc, 0, 'archive run: exit 0');
    ok(!-d $dir, 'the blueprint is no longer in the active listing');
    ok(-d "$root/blueprints/_archive/to-archive", 'it is in _archive/ — moved, never deleted');
    ok(-f "$root/blueprints/_archive/to-archive/blueprint.md", 'its content came with it');
    # RE-WITNESSED for s04-lifecycle-derived (driver ruling 2026-08-14): same
    # guarantee (advancement all the way to `archived`), new witness. Note
    # `archived` IS still a literal write (DC6 keeps archiving machine-written
    # -- only `running`/`done` become unwritable), so bp_status_of would still
    # agree here; the JSON field is used anyway for consistency with the
    # other three re-witnessed assertions in this file.
    is($data->[0]{lifecycle}, 'archived',
       'and it records `archived`, so where it lives and what it says agree');
}
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'not-yet',
        status   => 'running',
        packages => [ { pkg => '01-a', ledger => 'done',    table => 'done' },
                      { pkg => '02-b', ledger => 'blocked', table => 'blocked' } ],
    );
    my ($rc) = run_lifecycle('reconcile', '--blueprint', 'not-yet',
                             '--data-dir', $root, '--archive');
    ok(-d $dir, 'a blueprint with a blocked package is never archived, even with --archive');
}

# ============================================================================
# 8b (F3, s04 fix-batch step 7). The archive-rollback failure branch flips
# blueprint.md back to 'audited' when the move fails, but before this fix it
# never updated $r{status_after} to match -- the JSON report kept claiming
# whatever the pre-run authored word had been (possibly 'running'), lying
# about what this reconcile actually wrote.
#
# A genuine end-to-end filesystem failure of move_dir (rename AND the
# copy+remove fallback both failing) could not be forced reliably from this
# Windows test host: every mechanism tried -- an open filehandle on a file
# inside the source tree (default Windows/MSYS Perl sharing allows read,
# unlink AND rename of the locked file regardless), chdir'ing into the
# source directory first, chmod'ing the destination's parent read-only, and
# a >400-character destination path (long-path support is enabled on this
# machine) -- still let the move succeed. Forcing it via icacls hit the
# known non-ASCII-path/cmd.exe mangling landmine (project CLAUDE.md) and
# risks leaving an undeletable ACL-denied temp directory behind, which is
# worse than not having this assertion. So this is a source-anchored
# regression guard instead of a black-box behavioral one: it pins the exact
# line the fix added, in the exact branch it belongs to, so reverting the
# fix (deleting that line) fails this test immediately.
# ============================================================================
{
    my $lc_src = slurp($LIFECYCLE);
    ok(defined $lc_src, 'F3: bp-lifecycle.pl source is readable for the regression guard')
        or diag("expected $LIFECYCLE");
    if (defined $lc_src) {
        # Anchor on the surrounding rollback branch: the rollback write
        # (set-meta --value audited) up through the 'archive failed' error
        # push, a window that exists exactly once in this file (AC1 above
        # already pins @BP_LIFECYCLE_AUTHORED elsewhere, so this specific
        # bp_call/'archive failed' pairing is unambiguous). Within that
        # window, $r{status_after} must be (re)assigned to 'audited' -- the
        # fix -- so this cannot pass by matching an unrelated status_after
        # assignment elsewhere in the file (e.g. line ~374's initial value,
        # or the success branch's 'archived').
        if ($lc_src =~ /(--value',\s*'audited'\s*\).*?archive failed)/s) {
            my $window = $1;
            like($window, qr/status_after\}\s*=\s*'audited'\s*;/,
                "F3: the archive-rollback branch sets \$r{status_after} = 'audited' between the rollback write and "
              . "the 'archive failed' error, so status_after reflects this reconcile's own last write, not the "
              . "pre-run authored word");
        } else {
            fail("F3: could not locate the archive-rollback branch (rollback write .. 'archive failed') to check");
        }
    }
}

# ============================================================================
# 9. --all skips _archive/ and non-blueprint strays rather than choking.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    make_blueprint($root, 'real', status => 'running',
                   packages => [ { pkg => '01-a', ledger => 'done', table => 'done' } ]);
    make_path("$root/blueprints/_archive/old");
    write_file("$root/blueprints/_archive/old/blueprint.md", blueprint_md(name => 'old', status => 'archived'));
    make_path("$root/blueprints/a-stray-dir");     # no blueprint.md

    my ($rc, $data) = run_lifecycle('reconcile', '--all', '--data-dir', $root, '--no-archive');
    is($rc, 0, '--all: exit 0 with a stray and an archive present');
    my @names = sort map { $_->{blueprint} } @$data;
    is_deeply(\@names, ['real'], '--all visits real blueprints only: not _archive/, not strays');
}

# ============================================================================
# 10. Robustness: a corrupt registry is reported, never silently rewritten,
#     and must not block the rest of the reconciliation.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'bad-reg',
        status   => 'running',
        packages => [ { pkg => '01-a', ledger => 'done', table => 'done' } ],
    );
    make_path("$dir/runs");
    write_file("$dir/runs/registry.json", "{ this is not json ");
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'bad-reg',
                                    '--data-dir', $root, '--no-archive');
    is(slurp("$dir/runs/registry.json"), "{ this is not json ",
       'an unparseable registry is left exactly as found');
    ok(scalar @{ $data->[0]{errors} }, 'and the problem is reported as an error');
    is($rc, 2, 'exit 2 signals "something could not be reconciled"');
}

done_testing();
