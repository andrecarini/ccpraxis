#!/usr/bin/env perl
# 161-lifecycle-derived.t — s04-lifecycle-derived: "finished but marked running"
# becomes unwritable. Spec: .ccpraxis-local-data/blueprints/butler-and-dashboard-
# overhaul/specs/s04-lifecycle-derived-spec.md.
#
# This package is WIRING, not derivation: BpState::blueprint_lifecycle already
# implements the precedence and Decision-13 old-shape tolerance correctly and has
# ZERO production callers today. This file asserts:
#
#   AC1/AC2 (DC1/DC2) -- bp-blueprint.pl's set-meta refuses to WRITE 'running'/
#     'done' (they are derived), naming what derives them, and the authored/
#     derived word lists are split into exactly two arrays.
#   AC3/AC4 (DC3/DC4) -- no code path writes a literal status: done/running, and
#     there is exactly one production call site for BpState::blueprint_lifecycle.
#   AC5 (DC5)         -- the orchestrator/drive-next reconcile call SITES are
#     unedited (a guard, not new behavior -- see report for why it can't be red).
#   AC6 (DC6, THE FLAGGED RISK) -- archiving still works end-to-end once step 4's
#     write is gone: the gate must move to the FRESH BpState-derived value, not
#     the now-permanently-non-'done' literal field.
#   AC7 (DC7/Decision 13) -- the derivation outvotes a stale stored word both
#     ways (stale 'running' -> done; stale 'done' -> falls through to drafting).
#   AC8 (DC8)          -- templates/skills stop describing running/done as
#     authored, and stop reading the raw field for "the" status.
#
# Fixture/capture conventions are lifted verbatim from
# plugins/butler/tests/t/97-lifecycle-reconcile.t: real blueprint directories on
# disk, the real scripts run via system(), capture through a REAL temp file
# (never an in-memory scalar reopen of STDOUT -- "Bad file descriptor" on
# Git-for-Windows perl, project CLAUDE.md).

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
my $BLUEPRINT = "$SCRIPTS/bp-blueprint.pl";
my $BPSTATE   = "$SCRIPTS/BpState.pm";
my $ORCH      = "$SCRIPTS/bp-orchestrator.pl";
my $DRIVE     = "$SCRIPTS/bp-drive-next.pl";

my $TEMPLATE  = "$DIR/../../../blueprint/templates/blueprint.md";
my $MANAGE_SK = "$DIR/../../../blueprint/skills/manage/SKILL.md";
my $AUTH_SK   = "$DIR/../../../blueprint/skills/authoring-protocol/SKILL.md";
my $STATUS_SK = "$DIR/../../skills/status/SKILL.md";

ok(-f $LIFECYCLE, 'bp-lifecycle.pl exists') or BAIL_OUT('nothing to test');
ok(-f $BLUEPRINT, 'bp-blueprint.pl exists') or BAIL_OUT('nothing to test');
ok(-f $BPSTATE,   'BpState.pm exists')      or BAIL_OUT('nothing to test');

# --------------------------------------------------------------- fixtures ---
# Lifted verbatim (naming/shape) from t/97-lifecycle-reconcile.t so both files
# build the same real-world fixture shapes.

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
    return $dir;
}

# Read blueprint.md's fenced-block status the same way both scripts must.
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

sub run_lifecycle {
    my (@args) = @_;
    require File::Temp;
    my ($tfh, $tmp) = File::Temp::tempfile();
    close $tfh;
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

# Returns (rc, stdout, stderr) for a direct bp-blueprint.pl invocation.
sub run_bp_blueprint {
    my (@args) = @_;
    require File::Temp;
    my ($ofh, $otmp) = File::Temp::tempfile(); close $ofh;
    my ($efh, $etmp) = File::Temp::tempfile(); close $efh;
    open(my $so, '>&', \*STDOUT) or die "dup out: $!";
    open(my $se, '>&', \*STDERR) or die "dup err: $!";
    open(STDOUT, '>', $otmp) or die "redirect out: $!";
    open(STDERR, '>', $etmp) or die "redirect err: $!";
    my $rc = system($^X, $BLUEPRINT, @args);
    open(STDOUT, '>&', $so); open(STDERR, '>&', $se);
    close $so; close $se;
    my $out = slurp($otmp) // ''; unlink $otmp;
    my $err = slurp($etmp) // ''; unlink $etmp;
    return ($rc >> 8, $out, $err);
}

# ============================================================================
# AC1/AC2 (DC1/DC2) -- set-meta refuses to WRITE running/done.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'meta', status => 'audited', packages => []);
    my $file = "$dir/blueprint.md";

    # --- 'running' -----------------------------------------------------------
    my $before = slurp($file);
    my ($rc, $out, $err) = run_bp_blueprint('set-meta', '--file', $file,
                                            '--field', 'status', '--value', 'running');
    is($rc, 2, "AC1: set-meta --value running exits 2 (reject_error), not 0/3");
    like($err, qr/derived/i, "AC1: stderr for --value running names it DERIVED");
    like($err, qr/BpState::run_is_live/, "AC1: stderr for --value running names BpState::run_is_live");
    is(slurp($file), $before, "AC1: --value running leaves the file byte-identical");

    # --- 'done' ----------------------------------------------------------------
    ($rc, $out, $err) = run_bp_blueprint('set-meta', '--file', $file,
                                         '--field', 'status', '--value', 'done');
    is($rc, 2, "AC1: set-meta --value done exits 2 (reject_error), not 0/3");
    like($err, qr/derived/i, "AC1: stderr for --value done names it DERIVED");
    like($err, qr/BpState::blueprint_lifecycle/, "AC1: stderr for --value done names BpState::blueprint_lifecycle");
    is(slurp($file), $before, "AC1: --value done leaves the file byte-identical");

    # --- the three authored values still work: regression guard --------------
    for my $v (qw(drafting audited archived)) {
        my $d2 = make_blueprint($root, "meta-$v", status => 'audited', packages => []);
        my $f2 = "$d2/blueprint.md";
        my ($rc2, undef, $err2) = run_bp_blueprint('set-meta', '--file', $f2,
                                                    '--field', 'status', '--value', $v);
        is($rc2, 0, "AC1 regression guard: set-meta --value $v still exits 0") or diag($err2);
        is(bp_status_of($f2), $v, "AC1 regression guard: --value $v is actually written");
    }

    # --- a genuinely unrecognised value still exits 3, listing exactly the
    #     THREE authored words, not the old five ------------------------------
    my $d3 = make_blueprint($root, 'meta-bogus', status => 'audited', packages => []);
    my $f3 = "$d3/blueprint.md";
    my ($rc3, undef, $err3) = run_bp_blueprint('set-meta', '--file', $f3,
                                               '--field', 'status', '--value', 'bogus');
    is($rc3, 3, 'AC1: a genuinely unrecognised value still exits 3 (arg_error)');
    like($err3, qr/expected one of:\s*drafting, audited, archived/,
        'AC1: the unrecognised-value message lists exactly the three authored words');
    unlike($err3, qr/running,\s*done|done,\s*archived\s*$/,
        'AC1: the unrecognised-value message is not the old 5-word list');

    # --- F5 (s04 fix-batch step 7, red-team LOW): a case/whitespace variant
    #     of a derived word is refused via the EXPLANATORY exit-2 path, not
    #     the generic exit-3 one -- the write is blocked either way (that part
    #     was never broken), this is just about which message the user gets.
    for my $variant ('Done', ' RUNNING') {
        my $d4 = make_blueprint($root, "meta-variant-$variant" =~ s/\s+/_/gr, status => 'audited', packages => []);
        my $f4 = "$d4/blueprint.md";
        my $before4 = slurp($f4);
        my ($rc4, undef, $err4) = run_bp_blueprint('set-meta', '--file', $f4,
                                                    '--field', 'status', '--value', $variant);
        is($rc4, 2, "F5: set-meta --value '$variant' exits 2 (reject_error/derived), not 3 (arg_error)");
        like($err4, qr/derived/i, "F5: stderr for --value '$variant' names it DERIVED");
        is(slurp($f4), $before4, "F5: --value '$variant' leaves the file byte-identical");
    }
}

# ============================================================================
# AC2 (DC2) -- exactly two arrays, and the validator/docs read from them.
# ============================================================================
{
    my $src = slurp($BLUEPRINT);
    like($src, qr/\@BP_LIFECYCLE_AUTHORED\s*=\s*qw\(\s*drafting\s+audited\s+archived\s*\)/,
        'AC2: @BP_LIFECYCLE_AUTHORED is exactly (drafting audited archived)');
    like($src, qr/\@BP_LIFECYCLE_DERIVED\s*=\s*qw\(\s*running\s+done\s*\)/,
        'AC2: @BP_LIFECYCLE_DERIVED is exactly (running done)');
    unlike($src, qr/qw\(\s*drafting\s+audited\s+running\s+done\s+archived\s*\)/,
        'AC2: no leftover single 5-word @BP_LIFECYCLE list remains anywhere in the file');
}

# ============================================================================
# AC3 (DC3) -- source-scan: no set-meta invocation anywhere in the write_set's
# production code writes the literal 'running'/'done' as --field status's
# --value. (Test fixtures/skills prose are not scanned here -- this targets
# actual `bp_call`/`bp_call_out`/CLI invocations of set-meta.)
# ============================================================================
{
    for my $prod ([$LIFECYCLE, 'bp-lifecycle.pl'], [$BLUEPRINT, 'bp-blueprint.pl'],
                  [$ORCH, 'bp-orchestrator.pl'], [$DRIVE, 'bp-drive-next.pl']) {
        my ($path, $label) = @$prod;
        next unless -f $path;
        my $src = slurp($path);
        unlike($src, qr/field['"]\s*,\s*['"]status['"]\s*,\s*['"]--value['"]\s*,\s*['"](?:running|done)['"]/,
            "AC3: $label contains no set-meta call writing literal status running/done");
    }
}

# --- AC3 behavioral: driving reconcile never leaves status_after == 'done',
#     and never leaves the on-disk field reading literal 'done' after a
#     reconcile that touched the blueprint. ---------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac3-all-done',
        status   => 'running',
        packages => [ { pkg => '01-a', ledger => 'done', table => 'done' },
                      { pkg => '02-b', ledger => 'done', table => 'done' } ],
    );
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac3-all-done',
                                    '--data-dir', $root, '--no-archive');
    isnt($data->[0]{status_after}, 'done',
        "AC3: JSON status_after never observes literal 'done' (a --no-archive reconcile writes nothing here)");
    is($data->[0]{status_after}, 'running',
        "AC3: status_after equals status_before -- step 4 is report-only, no write happened");
    isnt(bp_status_of("$dir/blueprint.md"), 'done',
        "AC3: the on-disk field never reads literal 'done' after this reconcile");
    is(bp_status_of("$dir/blueprint.md"), 'running',
        "AC3: the on-disk field is untouched (was 'running', stays 'running') -- this is the write DC3 forbids");

    # --dry-run: same non-write guarantee, trivially -- included because §2.4
    # says dry-run and real-run must produce the IDENTICAL lifecycle/action
    # shape for this step (no branching left to test).
    my $root2 = tempdir(CLEANUP => 1);
    my $dir2  = make_blueprint($root2, 'ac3-all-done-dry',
        status   => 'audited',
        packages => [ { pkg => '01-a', ledger => 'done', table => 'done' } ],
    );
    my ($rc2, $data2) = run_lifecycle('reconcile', '--blueprint', 'ac3-all-done-dry',
                                      '--data-dir', $root2, '--no-archive', '--dry-run');
    isnt(bp_status_of("$dir2/blueprint.md"), 'done',
        'AC3: --dry-run also never leaves a literal done on disk');
}

# ============================================================================
# AC4 (DC4) -- exactly one production call site for BpState::blueprint_lifecycle,
# reused by both step 4 and step 5; %ADVANCEABLE (the local hand-written
# re-derivation of the advance gate) is gone, not merely unused.
# ============================================================================
{
    my $src = slurp($LIFECYCLE);
    like($src, qr/require\s+["']\$SCRIPT_DIR\/BpState\.pm["']/,
        'AC4: bp-lifecycle.pl requires BpState.pm');
    my @calls = ($src =~ /BpState::blueprint_lifecycle\s*\(/g);
    is(scalar(@calls), 1,
        'AC4: exactly one call site to BpState::blueprint_lifecycle in bp-lifecycle.pl (reused by steps 4 and 5)');
    unlike($src, qr/\%ADVANCEABLE/,
        'AC4: %ADVANCEABLE (the local hand-written re-derivation of the advance gate) is deleted, not left dead');
}

# ============================================================================
# AC5 (DC5) -- the orchestrator/drive-next reconcile call SITES are unedited.
# This is a REGRESSION GUARD, not new behavior: nothing about this package
# changes these two call sites (only what bp-lifecycle.pl does once invoked
# changes) -- see report for why this cannot be red against current code.
# ============================================================================
{
    my $orch_src  = slurp($ORCH);
    like($orch_src, qr/\Q'reconcile', '--blueprint', \E\$bpdir,/,
        "AC5: bp-orchestrator.pl's run_complete reconcile call is unedited (--blueprint \$bpdir)");
    like($orch_src, qr/\Q'--no-archive', '--quiet'\E/,
        "AC5: bp-orchestrator.pl's run_complete reconcile call keeps --no-archive --quiet");

    my $drive_src = slurp($DRIVE);
    like($drive_src, qr/\Q'reconcile', '--all',\E/,
        "AC5: bp-drive-next.pl's terminal-done reconcile call is unedited (--all)");
    like($drive_src, qr/\Q'--data-dir', \E\$data,\s*\Q'--archive', '--quiet'\E/,
        "AC5: bp-drive-next.pl's terminal-done reconcile call keeps --archive --quiet");
}

# ============================================================================
# AC6 (DC6) -- THE FLAGGED RISK. Archiving must still work end-to-end once
# step 4 no longer ever writes 'done': the gate (and the JSON report's
# lifecycle field) must come from the FRESH BpState call, not the literal
# stored field, which after this package can NEVER read 'done' again.
#
# The 'lifecycle' JSON key is what forces this red today (absent -> undef);
# the directory-move/on-disk assertions are the strong, end-to-end proof that
# archiving is not merely reported but ACTUALLY HAPPENS -- exactly what the
# task brief asks for ("assert the archive actually happens end-to-end, not
# that a variable was read").
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    # Authored 'running', not 'audited' -- deliberately the Decision-13-shaped
    # word (observable behavior 9's second half), not the easy case.
    my $dir  = make_blueprint($root, 'ac6-archive',
        status   => 'running',
        packages => [ { pkg => '01-a', ledger => 'done', table => 'done' },
                      { pkg => '02-b', ledger => 'dropped', table => 'dropped' } ],
    );
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac6-archive',
                                    '--data-dir', $root, '--archive');
    is($rc, 0, 'AC6: archive run exits 0');
    ok(!-d $dir, 'AC6: the blueprint directory is gone from the active listing');
    ok(-d "$root/blueprints/_archive/ac6-archive",
        'AC6: it is actually filed into _archive/ -- the move really happens, not just reported');
    ok(-f "$root/blueprints/_archive/ac6-archive/blueprint.md", 'AC6: its content moved with it');
    is(bp_status_of("$root/blueprints/_archive/ac6-archive/blueprint.md"), 'archived',
        'AC6: the archived copy on disk actually says status: archived');
    is($data->[0]{lifecycle}, 'archived',
        "AC6: the JSON report's lifecycle field reads 'archived' (this key does not exist before this package -- forces red)");
    ok((grep { $_->{kind} eq 'archive' && $_->{applied} } @{ $data->[0]{actions} }),
        'AC6: the archive is reported as an APPLIED action, not merely attempted');
}

# ============================================================================
# AC7 (DC7 / Decision 13) -- the derivation outvotes a stale stored word,
# never falls back to it, in BOTH directions.
# ============================================================================
{
    # Stale 'running' + all delivered + no live -> derivation wins -> 'done'.
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac7-stale-running',
        status   => 'running',
        packages => [ { pkg => '01-a', ledger => 'done', table => 'done' } ],
    );
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac7-stale-running',
                                    '--data-dir', $root, '--no-archive');
    is($data->[0]{lifecycle}, 'done',
        "AC7: a stale stored 'running' contradicted by all-delivered ledgers derives to 'done' (Decision 13)");
}
{
    # Old-shape 'done' + NOT all delivered + no live -> BpState's own default,
    # 'drafting' -- documented existing BpState behavior, asserted here too so
    # a future change to BpState's precedence is caught at this call site as
    # well, not only in t/159/t/160.
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac7-stale-done',
        status   => 'done',
        packages => [ { pkg => '01-a', ledger => 'done',    table => 'done' },
                      { pkg => '02-b', ledger => 'pending', table => 'pending' } ],
    );
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac7-stale-done',
                                    '--data-dir', $root, '--no-archive');
    is($data->[0]{lifecycle}, 'drafting',
        "AC7: an old-shape stored 'done' with undelivered packages falls through to BpState's default 'drafting', never trusted literally");
}
{
    # A live run beats everything, including an authored word that would
    # otherwise derive to 'done' -- BpState precedence #1 over #3, exercised
    # through the real call site this package adds.
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac7-live-beats-done',
        status   => 'audited',
        marker   => "$$\n",     # our own pid: really alive
        packages => [ { pkg => '01-a', ledger => 'done', table => 'done' } ],
    );
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac7-live-beats-done',
                                    '--data-dir', $root, '--no-archive');
    is($data->[0]{lifecycle}, 'running',
        "AC7/observable-8: a live run reports lifecycle 'running' regardless of the authored word or all-delivered ledgers");
    ok((grep { $_->{kind} eq 'skipped' } @{ $data->[0]{actions} }),
        'observable-8: the skip under a live run is still reported, not silent');
}
{
    # Observable behavior 6: one package short of delivered -> lifecycle stays
    # the unchanged authored word; no lifecycle-kind action; all_delivered 0.
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac7-one-short',
        status   => 'running',
        packages => [ { pkg => '01-a', ledger => 'done',   table => 'done' },
                      { pkg => '02-b', ledger => 'parked', table => 'parked' } ],
    );
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac7-one-short',
                                    '--data-dir', $root, '--no-archive');
    is($data->[0]{lifecycle}, 'running', 'observable-6: an undelivered package keeps lifecycle at the authored word');
    is($data->[0]{all_delivered}, 0, 'observable-6: all_delivered is false');
    ok(!(grep { $_->{kind} eq 'lifecycle' } @{ $data->[0]{actions} }),
        'observable-6: no lifecycle-kind action is reported when not all delivered');
}
{
    # F1 (s04 fix-batch step 7): authored 'done' + all packages delivered
    # must derive to 'done', not fall through to the catch-all 'drafting'.
    # Before the fix, BpState::blueprint_lifecycle's advance gate listed
    # only {audited,running}, so this authored/all-delivered combination
    # silently demoted to 'drafting' -- which meant archiving (whose gate
    # is this derived value) never fired for a finished blueprint, with no
    # error and no red test. Exercises the derivation, not source text.
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'f1-authored-done-all-delivered',
        status   => 'done',
        packages => [ { pkg => '01-a', ledger => 'done',    table => 'done' },
                      { pkg => '02-b', ledger => 'dropped', table => 'dropped' } ],
    );
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'f1-authored-done-all-delivered',
                                    '--data-dir', $root, '--no-archive');
    is($data->[0]{lifecycle}, 'done',
        "F1: authored 'done' with every package delivered derives to 'done', not demoted to 'drafting'");
}
{
    # Observable behavior 7: drafting + zero packages never advances.
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'ac7-draft-empty', status => 'drafting', packages => []);
    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'ac7-draft-empty',
                                    '--data-dir', $root, '--no-archive');
    is($data->[0]{lifecycle}, 'drafting',
        'observable-7: a drafting blueprint with zero packages never advances (zero packages is not "all delivered")');
}

# ============================================================================
# AC8 (DC8) -- templates/skills stop describing running/done as authored, and
# read the reconciler's derived field instead of the raw metadata block.
# ============================================================================
{
    my $tmpl = slurp($TEMPLATE);
    ok(defined $tmpl, 'AC8: blueprint template exists') or diag("expected $TEMPLATE");
    if (defined $tmpl) {
        like($tmpl, qr/status:\s*drafting\s+#\s*drafting\s*\|\s*audited\s*\|\s*archived\b/,
            "AC8: the template's status: comment lists only drafting | audited | archived");
        unlike($tmpl, qr/#\s*drafting\s*\|\s*audited\s*\|\s*running\s*\|\s*done\s*\|\s*archived/,
            'AC8: the template no longer lists running/done as authored options in the same comment');
    }

    my $manage = slurp($MANAGE_SK);
    ok(defined $manage, 'AC8: manage/SKILL.md exists') or diag("expected $MANAGE_SK");
    if (defined $manage) {
        like($manage, qr/--json/,
            "AC8: manage/SKILL.md's list/view sections invoke reconcile --json (not a raw metadata read)");
        like($manage, qr/lifecycle/,
            "AC8: manage/SKILL.md instructs reading the reconciler's 'lifecycle' field for the blueprint's own status");
    }

    my $status_sk = slurp($STATUS_SK);
    ok(defined $status_sk, 'AC8: butler status/SKILL.md exists') or diag("expected $STATUS_SK");
    if (defined $status_sk) {
        like($status_sk, qr/s05|out of (?:this|s04's) (?:package's )?write set|raw stored/i,
            'AC8: butler status/SKILL.md states the bp-status.sh raw-field gap explicitly (spec §2.9)');
    }

    my $authoring = slurp($AUTH_SK);
    ok(defined $authoring, 'AC8: authoring-protocol/SKILL.md exists') or diag("expected $AUTH_SK");
    if (defined $authoring) {
        # Confirmed unchanged per spec §2.10 -- this is a guard, not expected
        # red: it should already hold today and must keep holding.
        unlike($authoring, qr/set\b[^\n]{0,40}status[^\n]{0,20}\brunning\b/i,
            'AC8 guard: authoring-protocol/SKILL.md still contains no prose describing "running" as something set');
        unlike($authoring, qr/set\b[^\n]{0,40}status[^\n]{0,20}\bdone\b/i,
            'AC8 guard: authoring-protocol/SKILL.md still contains no prose describing "done" as something set');
    }
}

done_testing();
