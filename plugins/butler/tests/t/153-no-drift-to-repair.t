#!/usr/bin/env perl
# 153-no-drift-to-repair.t — s05-retire-reconciler-drift-paths: the copies
# ARE unrepresentable, which is the whole thesis.
#
# Renumbered from the ledger's original t/102 to t/153 by the 2026-08-14
# driver: plugins/butler/tests/t/102-set-test-paths.t already exists, and
# butler's t/ already carries three tracked duplicate-number pairs (98, 99,
# 108) -- filed as almanac report 20260814-093030-2d3f. 153 is free.
#
# THE HEADLINE LIVE DEFECT (spec §0), asserted end to end, not inferred:
# s03 hard-retired bp-blueprint.pl's op_set_status unconditionally. Any
# old-shape blueprint.md (status column present, values stale relative to
# the ledgers) makes reconcile_one's (former) step 2 call that retired verb,
# push the failure into $r{errors}, and step 5's archive gate
# (if ($opt->{archive} && $lifecycle eq 'done' && !@{ $r{errors} })) then
# silently refuses to archive -- forever, with nothing telling the operator
# why. This initiative's OWN blueprint is in that exact shape right now.
# Deleting step 2 (and step 3's dead status-reconciliation half) is what
# RESTORES archiving. AC-9 below proves it: the fixture directory actually
# MOVES into _archive/ -- a directory-existence assertion, never an
# inference from "no error occurred".
#
# Written BLIND to bp-lifecycle.pl's implementation, directly from
# specs/s05-retire-reconciler-drift-paths-spec.md, so this is an oracle, not
# an echo.
#
# Fixture/capture conventions are lifted verbatim from
# plugins/butler/tests/t/97-lifecycle-reconcile.t and
# plugins/butler/tests/t/101-lifecycle-derived.t: real blueprint directories
# on disk, the real scripts run via system(), capture through a REAL temp
# file (never an in-memory scalar reopen of STDOUT -- "Bad file descriptor"
# on Git-for-Windows perl, project CLAUDE.md). Blueprint metadata is a FENCED
# code block, never `---` frontmatter (driver's fixture-shape constraint --
# a frontmatter fixture silently yields an empty authored value).
#
# NEVER run against the live blueprint tree: every fixture here builds its
# own tempdir() and passes an explicit --data-dir naming it.

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
my $STATUS_SH = "$SCRIPTS/bp-status.sh";
my $PLUGINS   = "$DIR/../../..";

ok(-f $LIFECYCLE, 'bp-lifecycle.pl exists') or BAIL_OUT('nothing to test');
ok(-f $STATUS_SH, 'bp-status.sh exists')    or BAIL_OUT('nothing to test');

# --------------------------------------------------------------- fixtures ---
# Copied verbatim (shape) from t/97-lifecycle-reconcile.t / t/101-lifecycle-
# derived.t so all three files build the same real-world fixture shapes.

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

# A blueprint.md with the real shapes: a FENCED metadata block (never
# frontmatter) and an OLD-SHAPE package-status table (the column s03 dropped
# from the template, but which still exists on real, unmigrated data --
# including this initiative's own blueprint.md).
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

# Table cell for one package, straight off the package-status table row.
# AMENDED 2026-08-14 by driver adjudication -- the original could not work.
# It anchored with \z under /m, but /m only re-points ^ and $ at line
# boundaries; \z remains ABSOLUTE end-of-string. So a table row that was not
# the very last thing in the file could never match, and worse, the \s* before
# it spans newlines, so for a row nearer the end the capture reached PAST the
# table and returned a later line's text. Proven: on a two-row fixture the old
# pattern returned NO MATCH for the first row and captured "## Harvest log" for
# the second.
#
# Anchoring on $ under /m matches the row's own line, and the trailing
# optional | consumes the closing pipe of a markdown table row so the capture
# is the last CELL rather than whatever follows it.
sub table_cell_of {
    my ($md, $pkg) = @_;
    return undef unless $md =~ /^[^\n]*\Q$pkg\E[^\n]*?\|\s*([^\|\n]*?)\s*\|?[ \t]*$/m;
    my $v = $1;
    $v =~ s/^\s+|\s+\z//g;
    return $v;
}

# ============================================================================
# AC-9 (DC4 + headline live-defect fix). An old-shape blueprint (fenced
# status: running, a package table whose status column disagrees with EVERY
# ledger, all ledgers done, and a runs/registry.json entry whose status also
# disagrees) reconciles clean end-to-end WITH --archive and the directory
# actually moves into _archive/.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'old-shape-archive',
        status   => 'running',
        packages => [ { pkg => '01-a', ledger => 'done', table => 'pending' },
                      { pkg => '02-b', ledger => 'done', table => 'pending' } ],
        registry => { packages => {
            '01-a' => { status => 'running', attempt => 1 },
            '02-b' => { status => 'pending', attempt => 1 },
        } },
    );

    ok(-d $dir, 'sanity: the old-shape fixture exists before reconcile');

    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'old-shape-archive',
                                    '--data-dir', $root, '--archive');

    is($rc, 0, 'AC-9: reconcile against an old-shape blueprint with --archive exits 0 (was: silently blocked by a now-retired set-status call)');
    ok(defined $data && ref($data) eq 'ARRAY' && @$data, 'AC-9: reconcile produced a JSON report')
        or diag("raw output was not parseable JSON");
    is_deeply($data->[0]{errors}, [], 'AC-9: $r{errors} is empty -- the retired set-status call never fires, so nothing fails')
        if defined $data;
    # AMENDED 2026-08-14 by driver adjudication. This asserted 'done', which
    # CONTRADICTED an already-passing pin in a sibling oracle:
    # plugins/butler/tests/t/97-lifecycle-reconcile.t:416 requires 'archived'
    # for this same successful-archive scenario, and that is the correct value --
    # archiving rewrites the authored word to 'archived', so the derived value
    # follows it. Written from the spec's AC-9 prose without reconciling against
    # t/97's existing pin; the implementer hit the disagreement and flagged it
    # rather than editing the oracle or coding around it.
    #
    # THE GUARANTEE IS UNCHANGED and is the point of the assertion: the derived
    # value is computed from the ledgers, NOT from either stale copy (the table
    # mismatch or the registry mismatch this fixture deliberately plants). Only
    # the expected word moves, to the one the archive step legitimately produces.
    is($data->[0]{lifecycle}, 'archived',
       'AC-9: the derived lifecycle reads "archived" after a successful archive, computed from the ledgers and untouched by either stale copy (the table mismatch, the registry mismatch)')
        if defined $data;

    # THE LIVE-BUG FIX, MADE OBSERVABLE: a directory-existence assertion, not
    # an inference from "no error occurred". Before this package, the retired
    # set-status call's failure landed in $r{errors} and the archive gate
    # (bp-lifecycle.pl:501, !@{ $r{errors} }) silently refused to move
    # anything -- this exact fixture shape would have left $dir untouched.
    ok(!-d $dir, 'AC-9 (the live-bug fix): the old-shape blueprint directory is GONE from its original location -- archiving actually happened');
    ok(-d "$root/blueprints/_archive/old-shape-archive",
       'AC-9 (the live-bug fix): it actually MOVED into _archive/ -- not merely "no error", a real directory move');
    ok(-f "$root/blueprints/_archive/old-shape-archive/blueprint.md",
       'AC-9: its content came with it');

    # Paired absence checks: the now-deleted action kinds never appear on the
    # path to a successful archive of exactly this shape (belt-and-suspenders
    # for AC-1/AC-2/AC-3, which are more exhaustively covered by t/97's
    # recomputed dry-run block, but worth re-confirming on THIS fixture since
    # it is the one that used to fail).
    if (defined $data) {
        ok(!(grep { $_->{kind} eq 'table_drift' } @{ $data->[0]{actions} || [] }),
           'AC-9: no table_drift action on the archiving run either');
        ok(!(grep { $_->{kind} eq 'registry_drift' } @{ $data->[0]{actions} || [] }),
           'AC-9: no registry_drift action on the archiving run either');
        ok(!(grep { $_->{kind} eq 'lifecycle' } @{ $data->[0]{actions} || [] }),
           'AC-9: no lifecycle pseudo-action on the archiving run either');
    }
}

# ============================================================================
# AC-9 (second half). The SAME fixture shape, re-run fresh with --no-archive:
# the table cell and the registry `status` value are byte-identical to their
# authored values afterward -- proving "read correctly, no repair step
# involved", not merely "didn't error".
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'old-shape-no-archive',
        status   => 'running',
        packages => [ { pkg => '01-a', ledger => 'done', table => 'pending' },
                      { pkg => '02-b', ledger => 'done', table => 'pending' } ],
        registry => { packages => {
            '01-a' => { status => 'running', attempt => 1 },
            '02-b' => { status => 'pending', attempt => 1 },
        } },
    );
    my $before_md  = slurp("$dir/blueprint.md");
    my $before_reg = slurp("$dir/runs/registry.json");

    my ($rc, $data) = run_lifecycle('reconcile', '--blueprint', 'old-shape-no-archive',
                                    '--data-dir', $root, '--no-archive');
    is($rc, 0, 'AC-9/--no-archive: exit 0');
    is_deeply($data->[0]{errors}, [], 'AC-9/--no-archive: $r{errors} is empty')
        if defined $data;

    my $after_md  = slurp("$dir/blueprint.md");
    my $after_reg = slurp("$dir/runs/registry.json");

    is($after_md, $before_md,
       'AC-9/--no-archive: blueprint.md is BYTE-IDENTICAL after reconcile -- the stale table cell is read, never repaired');
    is($after_reg, $before_reg,
       'AC-9/--no-archive: runs/registry.json is BYTE-IDENTICAL after reconcile -- the disagreeing status field is read, never repaired');

    # Narrower, field-level re-statement of the same guarantee (belt-and-
    # suspenders against a byte-identity check that could pass vacuously if
    # the whole file were somehow untouched by coincidence rather than by
    # design -- these pin the SPECIFIC fields the old repair logic used to
    # rewrite).
    is(table_cell_of($after_md, '01-a'), 'pending',
       'AC-9/--no-archive: the 01-a table cell specifically still reads its authored "pending" -- never repaired to "done"');
    require JSON::PP;
    my $reg = JSON::PP->new->decode($after_reg);
    is($reg->{packages}{'01-a'}{status}, 'running',
       'AC-9/--no-archive: the 01-a registry status specifically still reads its authored "running" -- never reconciled to "done"');
}

# ============================================================================
# NON-VACUITY counter-check for AC-9: prove this fixture shape and this
# reconcile invocation are the ones that USED to fail before this package,
# by exercising the exact retired call directly. If bp-blueprint.pl's
# set-status verb were ever un-retired, this sub-test would need updating --
# that is the point: it anchors AC-9's "was silently blocked" claim to a
# concrete, checkable fact rather than to prose.
# ============================================================================
{
    my $BP_BLUEPRINT = "$SCRIPTS/bp-blueprint.pl";
    ok(-f $BP_BLUEPRINT, 'sanity: bp-blueprint.pl exists');
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'set-status-probe',
        status   => 'running',
        packages => [ { pkg => '01-a', ledger => 'done', table => 'pending' } ],
    );
    require File::Temp;
    my ($tfh, $tmp) = File::Temp::tempfile();
    close $tfh;
    open(my $saved, '>&', \*STDOUT) or die "dup: $!";
    open(STDOUT, '>', $tmp) or die "redirect: $!";
    my $rc = system($^X, $BP_BLUEPRINT, 'set-status', '--file', "$dir/blueprint.md",
                     '--pkg', '01-a', '--status', 'done');
    open(STDOUT, '>&', $saved);
    close $saved;
    unlink $tmp;
    $rc >>= 8;
    isnt($rc, 0, 'non-vacuity: bp-blueprint.pl set-status is STILL retired and fails on every call (s03) -- this is why step 2 could never succeed, and why deleting it is the fix, not a regression');
}

# ============================================================================
# AC-10 (DC4). Every `set-meta --field status --value X` call site remaining
# in bp-lifecycle.pl uses only X ∈ {archived, audited} -- never running,
# never done. Static/behavioral source check, not a fixture run.
# ============================================================================
{
    my $src = slurp($LIFECYCLE);
    ok(defined $src, 'AC-10: bp-lifecycle.pl source is readable') or BAIL_OUT("expected $LIFECYCLE");
    my @values;
    while ($src =~ /set-meta['"]?\s*,\s*[^)]*?--field['"]?\s*,\s*'status'\s*,\s*[^)]*?--value['"]?\s*,\s*'([a-zA-Z]+)'/gs) {
        push @values, $1;
    }
    ok(scalar(@values) >= 2, "AC-10: found at least 2 set-meta --field status --value call sites to scan (found " . scalar(@values) . ")")
        or diag('this floor exists so an extractor that finds ZERO call sites (e.g. a pattern typo) cannot pass this section vacuously');
    my @bad = grep { $_ ne 'archived' && $_ ne 'audited' } @values;
    is(scalar(@bad), 0, "AC-10: every set-meta --field status --value call site in bp-lifecycle.pl uses only 'archived' or 'audited' (found: @values)");

    # Counter-fixture (non-vacuity proof): the SAME regex, run against a
    # synthetic snippet with a deliberate 'running'/'done' violation, MUST
    # detect it -- otherwise the clean result above is meaningless.
    my $poison = <<'PERL';
bp_call('set-meta', '--file', $bpmd, '--field', 'status', '--value', 'running');
bp_call('set-meta', '--file', $bpmd, '--field', 'status', '--value', 'archived');
PERL
    my @poison_values;
    while ($poison =~ /set-meta['"]?\s*,\s*[^)]*?--field['"]?\s*,\s*'status'\s*,\s*[^)]*?--value['"]?\s*,\s*'([a-zA-Z]+)'/gs) {
        push @poison_values, $1;
    }
    is(scalar(@poison_values), 2, 'AC-10 counter-fixture: extractor finds both synthetic call sites');
    my $poison_bad = grep { $_ ne 'archived' && $_ ne 'audited' } @poison_values;
    is($poison_bad, 1, 'AC-10 counter-fixture: the scanner DOES flag a deliberately-poisoned "running" value (proves it can go red, not merely a vacuous pass)');
}

# ============================================================================
# AC-12 (DC4). bp-status.sh's self-heal of a stale marker, exercised END TO
# END: the real script, invoked against a scratch CCPRAXIS_DATA_DIR, not a
# unit-level call into bp-lifecycle.pl alone.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_blueprint($root, 'status-sh-selfheal',
        status   => 'running',
        marker   => "4194304\n",   # a pid that cannot be alive (above Linux pid_max; not a live Windows pid)
        packages => [ { pkg => '01-a', ledger => 'done', table => 'done' } ],
    );
    ok(-e "$dir/runs/.orchestrator", 'sanity: the stale marker exists before bp-status.sh runs');

    require File::Temp;
    my ($tfh, $tmp) = File::Temp::tempfile();
    close $tfh;
    my ($efh, $etmp) = File::Temp::tempfile();
    close $efh;

    local $ENV{CCPRAXIS_DATA_DIR} = $root;
    open(my $saved_out, '>&', \*STDOUT) or die "dup: $!";
    open(my $saved_err, '>&', \*STDERR) or die "dup: $!";
    open(STDOUT, '>', $tmp)  or die "redirect: $!";
    open(STDERR, '>', $etmp) or die "redirect: $!";
    my $rc = system('bash', $STATUS_SH, 'status-sh-selfheal');
    open(STDOUT, '>&', $saved_out);
    open(STDERR, '>&', $saved_err);
    close $saved_out; close $saved_err;
    $rc >>= 8;
    my $out = slurp($tmp)  // '';
    my $err = slurp($etmp) // '';
    unlink $tmp; unlink $etmp;

    is($rc, 0, "AC-12: bp-status.sh exits 0 against a scratch data dir") or diag("stdout: $out\nstderr: $err");
    like($out, qr/status-sh-selfheal/, 'AC-12: bp-status.sh reported the blueprint by name')
        or diag("stdout: $out\nstderr: $err");
    ok(!-e "$dir/runs/.orchestrator",
       'AC-12: the dead-pid marker is REMOVED by bp-status.sh\'s own pre-report reconcile call -- self-heal on observation still works end to end, real subprocess, real files');
}

# ============================================================================
# AC-15 / DC6 (§2.6 grep guard). The literal strings table_drift and
# registry_drift appear in NEITHER bp-lifecycle.pl NOR any other file under
# plugins/, outside _archive/ fixture paths and outside t/97/t/153
# themselves (whose retirement commentary is permitted -- required, even --
# to name the removed kinds).
# ============================================================================
{
    my @needles = ('table_drift', 'registry_drift');
    my $t97  = "$DIR/97-lifecycle-reconcile.t";
    my $t153 = "$DIR/153-no-drift-to-repair.t";
    my %exempt = map { abs_path($_) => 1 } grep { -f $_ } ($t97, $t153);

    my @files;
    my @stack = ($PLUGINS);
    while (@stack) {
        my $d = pop @stack;
        opendir(my $dh, $d) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $p = "$d/$e";
            if (-d $p) {
                next if $e =~ /^_archive\z/;
                push @stack, $p;
            } elsif (-f $p) {
                next unless $e =~ /\.(pl|pm|sh|md|t)\z/;
                push @files, $p;
            }
        }
        closedir $dh;
    }
    ok(scalar(@files) > 50, 'AC-15: scanned a plausible number of plugins/ files (' . scalar(@files) . ')')
        or diag('too few files found -- the directory walk itself may be broken');

    my $lc_src = slurp($LIFECYCLE);
    ok(defined $lc_src, 'AC-15: bp-lifecycle.pl is readable for the grep guard');
    for my $needle (@needles) {
        ok((defined $lc_src && $lc_src !~ /\Q$needle\E/), "AC-15: bp-lifecycle.pl contains no literal '$needle'");
    }

    my @violations;
    for my $f (sort @files) {
        my $af = abs_path($f) // $f;
        next if $exempt{$af};
        my $raw = slurp($f);
        next unless defined $raw && length $raw;
        for my $needle (@needles) {
            push @violations, "$f ($needle)" if $raw =~ /\Q$needle\E/;
        }
    }
    is(scalar(@violations), 0,
       'AC-15: no file under plugins/ (outside _archive/ fixtures and t/97 / t/153 themselves) contains "table_drift" or "registry_drift": '
     . join(', ', @violations));

    # non-vacuity: the scanner must be ABLE to find these strings -- confirm
    # against bp-lifecycle.pl's own git-tracked test neighbour that still
    # legitimately carries the string in exempted commentary (t/97, itself),
    # i.e. that the pattern-match mechanics work at all.
    my $t97_src = slurp($t97);
    like($t97_src, qr/registry_drift/, 'AC-15 non-vacuity: the needle-matching mechanics themselves work (t/97 still legitimately names the retired kind in its own retirement commentary)')
        if defined $t97_src;
}

# ============================================================================
# AC-8 (DC1-corrected, cross-checked here too). No bp_call_out('set-status',
# ...) call anywhere in bp-lifecycle.pl -- the retired verb is never invoked,
# full stop, not merely "the action kind it used to log is gone".
# ============================================================================
{
    my $src = slurp($LIFECYCLE);
    ok(defined $src, 'sanity: bp-lifecycle.pl source readable');
    ok((defined $src && $src !~ /bp_call(?:_out)?\(\s*'set-status'/),
       'AC-8: bp-lifecycle.pl never calls the retired set-status verb, anywhere');
}

# ============================================================================
# AC-14 (DC5). bp-status.sh's two reconcile call sites (named-blueprint and
# --all branches) are byte-identical in their flags: --no-archive --quiet.
# "Updated to the surviving verb" means "verified as already correct," not
# "changed" -- reconcile was always the only verb.
# ============================================================================
{
    my $src = slurp($STATUS_SH);
    ok(defined $src, 'AC-14: bp-status.sh source readable') or BAIL_OUT("expected $STATUS_SH");
    my @call_sites = ($src =~ /(reconcile\s+(?:--blueprint\s+"\$ONLY_BP"|--all)\s+\\\s*\n\s*--no-archive\s+--quiet)/g);
    is(scalar(@call_sites), 2, 'AC-14: exactly two reconcile call sites found (named-blueprint and --all branches)');
    ok((!grep { $_ !~ /--no-archive/ || $_ !~ /--quiet/ } @call_sites),
       'AC-14: both call sites carry exactly --no-archive --quiet -- unchanged from before this package');
}

# ============================================================================
# read_table orphan (§2.3): the sub itself is deleted, not just its call
# site -- "dead code left in place is a claim that it might still be
# needed" is this package's own charter.
# ============================================================================
{
    my $src = slurp($LIFECYCLE);
    ok(defined $src, 'sanity: bp-lifecycle.pl source readable (read_table check)');
    ok((defined $src && $src !~ /sub\s+read_table\b/),
       'read_table is deleted outright, not merely made unreachable');
}

done_testing();
