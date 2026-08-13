#!/usr/bin/env perl
# b17-answer-decision-completeness oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b17-answer-decision-completeness-spec.md
# (the four verified defects in section 0, the C1..C8 acceptance criteria in section 2).
#
# WRITTEN AGAINST THE CURRENT bp-answer-decision.pl, WHICH HAS NONE OF THE FOUR FIXES:
#   1. no cold lever      -- `session_id` appears nowhere in the script; `reset` cannot clear it.
#   2. no write-set widen -- options are exactly --action/--note/--decision/--package/--bp-dir.
#   3. unknown kinds      -- kind_family() knows only reauth|contract-drift as 'fleet'; every other
#                            kind (including 'broken-env', which IS fleet-family in the real
#                            producer) silently defaults to 'package' with no validation at all.
#   4. --note dropped     -- append_human_decision(...) if $plan->{relaunch}, true only for
#                            relaunch/reset; accept/drop silently discard the note and exit 0.
# Every assertion below is expected to FAIL NOW against one of these four gaps -- never against a
# Perl exception, a missing module, or a wrong path (the script exists and runs fine today; it is
# simply incomplete). Where a sub-test currently PASSES (e.g. C2, C7's relaunch/reset cases, C5's
# package-family kinds), that is because the corresponding half of the defect does not exist for
# that input -- it is kept as the paired guard so an over-eager fix cannot regress it.
#
# =====================================================================================
# INTERFACE PINNED BY THIS ORACLE (nothing below exists on disk yet, so this oracle -- not any
# implementation -- fixes the contract, per the spec's "implementer's choice" wording):
#
#   - Cold lever (deliverable 1.1): `--action reset` (both --decision and direct --package modes)
#     CLEARS the package's registry `session_id` (absent, JSON null, or empty string all count as
#     "cleared" -- this oracle does not prescribe the JSON representation). `--action relaunch`
#     MUST NOT touch it.
#   - Write-set widening (deliverable 1.2): a new `--widen-write-set PATH` option (repeatable
#     semantics not required by this oracle -- one call, one path) that ADDS to the package
#     ledger's frontmatter `write_set:` value (colon-separated, per bp-lib.sh's match_any/registry
#     convention already in this repo), going through bp-ledger.pl rather than a second raw
#     frontmatter writer.
#   - Narrowing refusal (deliverable 1.2 / C4): a new `--set-write-set VALUE` option (full-
#     replacement semantics) that must be REFUSED outright -- named deliberately without the words
#     "narrow"/"replace"/"additive" so a generic "unknown option" pre-fix failure cannot
#     accidentally satisfy the refusal-wording assertion below.
#   - Kind coverage (deliverable 1.3): every kind bp-orchestrator.pl's OWN producers actually queue
#     (derived below, not hand-typed) must route to a deterministic outcome; anything else must
#     fail loudly, changing nothing.
#   - Note persistence (deliverable 1.4): `--note` persists into the ledger's "## Human decision"
#     section on every one of relaunch/reset/accept/drop.
#
# =====================================================================================
# MANDATORY VACUITY GATE (spec section 2's own standing rule):
#   - C1/C2 are opposites ("always clear" passes C1, fails C2; "never clear" the reverse) and are
#     asserted in the SAME block below, against the REAL bp-resume-sweep.sh verdict (not just the
#     registry mutation): C1's fixture is built so that, absent the fix, the sweep would call it
#     warm-resume (transcript fresh, cache_observations hit, session_id present) -- a fix that
#     "always clears" would still pass C1 (cold) but a script that never clears at all is caught by
#     the SAME fixture failing to go cold. C2 reuses the identical warm fixture through `relaunch`
#     and requires the sweep STILL says warm-resume.
#   - C3/C4 are asserted together (adjacent blocks, same starting fixture): C3 first proves the
#     named path was actually added (positive), THEN that every pre-existing path survived
#     byte-identically; C4 then proves an explicit narrow/replace attempt is refused with a
#     specifically-worded cause, not merely "unknown option".
#   - C5 first derives the kind list from bp-orchestrator.pl's OWN queue_needs_you/
#     _enter_pause_manual/_block_and_queue call sites (never a hand-typed list that would drift),
#     then exercises each; C6 uses a kind that is asserted (via the SAME derivation) to be ABSENT
#     from that list, so the "unknown kind" case can never accidentally collide with a real one.
#   - C7 asserts the note's presence PER ACTION, individually, for relaunch/reset/accept/drop --
#     an aggregate assertion would pass with accept/drop still silently dropping it, which IS the
#     regression defect 4 is.
#   - C8 is negative-only ("nothing silently discarded"); each sub-case first asserts the script
#     accepted the input (positive gate) before asserting the failure/refusal it must produce when
#     it cannot honour that input.
#
# NO SKIP appears anywhere below except ONE block explicitly gated on `jq` (bp-resume-sweep.sh's
# own hard dependency, via bp-lib.sh's require_cmd), and that gate is preceded by an `ok(...)`
# assertion of jq's presence so a missing jq fails loudly and names what went unverified, rather
# than silently vanishing as a false green.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use Cwd qw(abs_path);

my $BUTLER = abs_path("$Bin/../..");
my $SCRIPT = "$BUTLER/scripts/bp-answer-decision.pl";
my $SWEEP  = "$BUTLER/scripts/bp-resume-sweep.sh";
my $LEDGER_API = "$BUTLER/scripts/bp-ledger.pl";
my $ORCH_SRC   = "$BUTLER/scripts/bp-orchestrator.pl";

require $SCRIPT;   # loads BpAnswer + BpOrch (the CLI requires bp-orchestrator.pl)

my $J = JSON::PP->new->canonical;

diag("subject under test: $SCRIPT (present); none of the four b17 fixes exist yet -- every "
   . "assertion below that currently fails is expected absence-of-implementation, not a crash.");

# =====================================================================================
# Scaffolding (house style per t/13, t/85)
# =====================================================================================

sub write_file {
    my ($p, $c) = @_;
    (my $d = $p) =~ s{[\\/][^\\/]+$}{};
    make_path($d) unless -d $d;
    open my $fh, '>:raw', $p or die "$p: $!";
    print $fh $c;
    close $fh;
}
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return ''; local $/; my $c = <$fh>; close $fh; $c }
sub read_registry {
    my ($bpdir) = @_;
    my $txt = slurp("$bpdir/runs/registry.json");
    return {} unless length $txt;
    my $d = eval { JSON::PP->new->decode($txt) };
    return (ref $d eq 'HASH') ? $d : {};
}

sub shq { my ($s) = @_; $s =~ s/'/'\\''/g; return "'$s'"; }
sub run_cli {
    my ($bpdir, @args) = @_;
    my $cmd = join ' ', map { shq($_) } ($^X, $SCRIPT, 'bp', '--bp-dir', $bpdir, @args);
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}

# mk_bp(%o) -> ($bpdir, $decision_id, $pkg). Mirrors t/13's helper: one package ledger,
# a registry, and (unless no_decision => 1) one queued needs-you decision of $kind.
sub mk_bp {
    my (%o) = @_;
    my $pkg   = $o{pkg}    // 'alpha';
    my $kind  = $o{kind}   // 'stuck-package';
    my $wset  = $o{write_set} // "p/$pkg/";
    my $status= $o{status} // 'blocked';
    my $bpdir = tempdir(CLEANUP => 1);
    write_file("$bpdir/packages/$pkg.md",
        "---\npackage: $pkg\nblueprint: bp\nstatus: $status\nwrite_set: $wset\n"
      . "last_updated: 2020-01-01T00:00:00Z\n---\n\n# $pkg\n\n"
      . "## Next action\n\nResolve the park.\n\n## Decisions & attempt log\n\n_(none yet)_\n\n"
      . "## Pipeline\n\n- [ ] 1. do it\n\n## Outputs\n\n_(none yet)_\n\n## Escalation\n\n_(none)_\n");
    write_file("$bpdir/runs/registry.json", $J->encode({ packages => { $pkg => ($o{registry} // { status => $status, attempt => 3, pid => 4321 }) } }));
    write_file("$bpdir/runs/.paused", $J->encode({ reason => 'x', manual => JSON::PP::true, created_at => 10 })) if $o{paused};
    my $id;
    unless ($o{no_decision}) {
        $id = "$pkg--" . ($o{id_suffix} // 'abc123');
        write_file("$bpdir/runs/needs-you/$id.json",
            $J->encode({ package => ($o{decision_package} // $pkg), blueprint => 'bp', kind => $kind,
                         question => 'Decide.', context => 'looped', created_at => 10 }));
    }
    return ($bpdir, $id, $pkg);
}

# =====================================================================================
# C1 + C2 -- the cold lever, asserted together against bp-resume-sweep.sh's REAL verdict.
#
# Both fixtures give the package a "maximally warm" starting point (recent transcript,
# session_id present, a matching cache-hit observation) -- the SAME shape bp-cache-state.pl's own
# oracle (t/85) uses to prove "warm" is reachable at all, so a hardcoded-cold sweep could not
# accidentally satisfy C1. C1 then answers with `reset` and requires the sweep flips to
# cold-start; C2 answers with plain `relaunch` on the identical fixture and requires the sweep
# STILL says warm-resume -- proving the lever is reset-specific, not blanket.
# =====================================================================================
{
    my $has_jq = (system('jq --version >/dev/null 2>&1') == 0) ? 1 : 0;
    # See t/64: jq is a container dependency. Its absence means bp-resume-sweep.sh
    # cannot run here at all (bp-lib.sh's require_cmd hard-exits), so the C1/C2
    # groups are unexercised -- report that as missing coverage, not as a defect.
    SKIP: {
        skip 'jq is not installed on this host -- bp-resume-sweep.sh cannot run, C1/C2 NOT exercised', 1
            unless $has_jq;
        pass('environment has jq (bp-resume-sweep.sh hard-requires it via bp-lib.sh require_cmd)');
    }

    sub warm_fixture {
        my (%o) = @_;
        my $now = time;
        my $recent_epoch = $now - 5 * 60;   # 5 minutes ago -- comfortably inside the warm window
        my ($bpdir, undef, $pkg) = mk_bp(
            pkg => $o{pkg} // 'alpha', kind => 'stuck-package', status => 'blocked',
            no_decision => 1,
            registry => { status => 'blocked', attempt => 3, pid => 2_000_000_000,
                          session_id => 'sess-warm', cache_observations => [ { age_min => 5, hit => JSON::PP::true } ] },
        );
        my @g = gmtime($recent_epoch);
        my $iso = sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $g[5]+1900,$g[4]+1,$g[3],$g[2],$g[1],$g[0]);
        write_file("$bpdir/runs/$pkg.jsonl",
            $J->encode({ type => 'assistant', timestamp => $iso, session_id => 'sess-warm',
                         message => { role => 'assistant', usage => { input_tokens => 2,
                              cache_read_input_tokens => 500, cache_creation_input_tokens => 0, output_tokens => 1 } } }) . "\n");
        return $bpdir, $pkg;
    }

    sub run_sweep {
        my ($root_parent, $bp) = @_;
        my $cmd = join ' ', map { shq($_) } ('bash', $SWEEP, $bp);
        local $ENV{CCPRAXIS_DATA_DIR} = $root_parent;
        my $out = `$cmd 2>&1`;
        return ($? >> 8, $out);
    }

    # C1: reset must clear session_id AND flip the sweep's real verdict to cold.
    {
        my ($bpdir, $pkg) = warm_fixture(pkg => 'c1pkg');
        my $root = tempdir(CLEANUP => 1);
        # bp-resume-sweep.sh globs $DATA/blueprints/*/packages/*.md -- relocate the fixture under
        # that exact convention rather than duplicating it a second way.
        make_path("$root/blueprints");
        rename $bpdir, "$root/blueprints/bp" or die "relocate fixture: $!";
        $bpdir = "$root/blueprints/bp";

        my ($rc, $out) = run_cli($bpdir, '--package', $pkg, '--action', 'reset', '--note', 'Cold-start please.');
        is($rc, 0, 'C1: reset exits 0') or diag($out);

        my $reg = read_registry($bpdir);
        my $sid = $reg->{packages}{$pkg}{session_id};
        ok(!(defined $sid && length $sid), 'C1: session_id is absent/null/empty from the registry entry after reset')
            or diag('session_id = ' . (defined $sid ? "'$sid'" : 'undef'));

      SKIP: {
            skip 'jq is not available -- cannot verify the real bp-resume-sweep.sh verdict (see the ok() above)', 2
                unless $has_jq;
            my ($src, $sout) = run_sweep($root, 'bp');
            is($src, 0, 'C1: bp-resume-sweep.sh (dry run) exits 0') or diag($sout);
            like($sout, qr/cold-start/,
                'C1: bp-resume-sweep.sh classifies the package COLD after reset (the cold lever '
              . 'actually works end to end -- not just a registry field mutation)')
                or diag("sweep output:\n$sout");
            unlike($sout, qr/warm-resume/,
                'C1: the sweep output must NOT say warm-resume once the lever has fired');
        }
    }

    # C2: plain relaunch on the identical warm fixture must PRESERVE session_id and the sweep
    # must STILL say warm-resume -- the paired opposite of C1.
    {
        my ($bpdir, $pkg) = warm_fixture(pkg => 'c2pkg');
        my $root = tempdir(CLEANUP => 1);
        make_path("$root/blueprints");
        rename $bpdir, "$root/blueprints/bp" or die "relocate fixture: $!";
        $bpdir = "$root/blueprints/bp";

        my ($rc, $out) = run_cli($bpdir, '--package', $pkg, '--action', 'relaunch', '--note', 'Just retry.');
        is($rc, 0, 'C2: relaunch exits 0') or diag($out);

        my $reg = read_registry($bpdir);
        is($reg->{packages}{$pkg}{session_id}, 'sess-warm',
            'C2: a plain relaunch PRESERVES session_id -- "always clear" would fail this');

      SKIP: {
            skip 'jq is not available -- cannot verify the real bp-resume-sweep.sh verdict (see the ok() above)', 1
                unless $has_jq;
            my ($src, $sout) = run_sweep($root, 'bp');
            like($sout, qr/warm-resume/,
                'C2: bp-resume-sweep.sh STILL classifies the package WARM after a plain relaunch '
              . '(pairs with C1: a lever that always clears would fail this)')
                or diag("sweep output:\n$sout");
        }
    }
}

# =====================================================================================
# C3 + C4 -- write-set widening is additive-only, goes through bp-ledger.pl, and an explicit
# narrow/replace attempt is refused with a specifically-worded cause.
# =====================================================================================
{
    # A raw-write-to-ledger census of bp-answer-decision.pl's OWN source: today there is exactly
    # one (append_human_decision's corrective-note writer). If write-set widening were implemented
    # as a second, independent frontmatter writer (the exact thing the spec forbids -- "not a
    # second frontmatter writer"), this count would rise to 2. It must stay 1: the widen path is
    # required to go through bp-ledger.pl (a separate file, so its own writer does not count here).
    my $src = slurp($SCRIPT);
    my $raw_ledger_writes = () = ($src =~ /open\s*\(?\s*my\s*\$\w+\s*,\s*['"]>:raw['"]/g);
    is($raw_ledger_writes, 1,
        'C3: bp-answer-decision.pl still has exactly ONE raw ">:raw" file writer (the existing '
      . 'corrective-note writer) -- write-set widening must not add a second frontmatter writer '
      . 'of its own; it must call through bp-ledger.pl instead');

    # C3 positive: --widen-write-set adds the new path and preserves every existing path
    # byte-identically.
    {
        my ($bpdir, undef, $pkg) = mk_bp(pkg => 'wide1', write_set => 'p/wide1/:configs/shared.yaml', no_decision => 1);
        my $before = slurp("$bpdir/packages/$pkg.md");

        my ($rc, $out) = run_cli($bpdir, '--package', $pkg, '--action', 'relaunch', '--widen-write-set', 'p/extra-file.md');
        is($rc, 0, 'C3: widen exits 0') or diag($out);

        my $after = slurp("$bpdir/packages/$pkg.md");
        like($after, qr/^write_set:.*p\/extra-file\.md/m, 'C3: the named path was actually added to write_set');
        like($after, qr/^write_set:.*p\/wide1\//m,          'C3: the pre-existing path p/wide1/ survives');
        like($after, qr/^write_set:.*configs\/shared\.yaml/m, 'C3: the pre-existing path configs/shared.yaml survives');

        # Byte-identical survival of the REST of the file (everything outside the write_set line).
        my @before_lines = split /\n/, $before, -1;
        my @after_lines  = split /\n/, $after, -1;
        my @before_rest = grep { $_ !~ /^write_set:/ } @before_lines;
        my @after_rest  = grep { $_ !~ /^write_set:/ } @after_lines;
        is_deeply(\@after_rest, \@before_rest,
            'C3: every non-write_set line of the ledger survives byte-identically (additive-only, '
          . 'not a rewrite)');

        # The write must go through bp-ledger.pl's own invariants: a validate pass proves the
        # result is a well-formed ledger by the SAME rules the sanctioned writer enforces.
        my $vcmd = join ' ', map { shq($_) } ($^X, $LEDGER_API, 'validate', '--ledger', "$bpdir/packages/$pkg.md");
        my $vout = `$vcmd 2>&1`;
        is($? >> 8, 0, 'C3: the widened ledger still passes bp-ledger.pl validate') or diag($vout);
    }

    # C4: an explicit attempt to REPLACE write_set (not add to it) is refused with a cause that
    # specifically names the reason -- not just "unknown option". The flag name deliberately
    # avoids the words narrow/replace/additive so a generic "unrecognised option" pre-fix message
    # cannot accidentally satisfy the wording assertion below.
    {
        my ($bpdir, undef, $pkg) = mk_bp(pkg => 'wide2', write_set => 'p/wide2/:configs/shared.yaml', no_decision => 1);
        my $before = slurp("$bpdir/packages/$pkg.md");

        my ($rc, $out) = run_cli($bpdir, '--package', $pkg, '--action', 'relaunch', '--set-write-set', 'p/only-this/');
        isnt($rc, 0, 'C4: an attempt to REPLACE write_set is refused (non-zero exit)') or diag($out);
        like($out, qr/write.set/i, 'C4: the refusal names write_set');
        like($out, qr/narrow|replace|additive/i,
            'C4: the refusal states the SPECIFIC cause (narrowing/replacing is unsupported) -- not '
          . 'merely "unknown option" (which would not contain any of these words)')
            or diag("actual message: $out");

        my $after = slurp("$bpdir/packages/$pkg.md");
        is($after, $before, 'C4: a refused narrow/replace attempt changes NOTHING in the ledger');
    }
}

# =====================================================================================
# C5 + C6 -- every kind the orchestrator's OWN producers can queue gets a deterministic outcome;
# an unknown kind fails loudly and changes nothing. The kind list is DERIVED from
# bp-orchestrator.pl's actual queue_needs_you / _enter_pause_manual / _block_and_queue call sites
# -- never hand-typed -- so it cannot drift from the real producers as b01/b09/b11/b16 add more.
# =====================================================================================
# e02 §4 AC5 / done-criterion 5: this used to duplicate known_kinds()'s OWN
# source-scanning regex here as a second, independent copy -- a second copy of
# the exact bug e02 closes (both blind to 'dag-stalled', built via a builder
# function outside any scanned window; and, worse, e02's own addition of a
# 10th positional `category` literal at every _block_and_queue call site made
# this duplicate regex start capturing the CATEGORY string instead of the
# KIND string, since its `_block_and_queue` branch simply grabs the LAST
# quoted literal before `);` -- a live drift this local copy could never have
# caught on its own). MOVE, don't duplicate: call BpAnswer::known_kinds()
# directly (already `require`d above) so C5/C6 exercise the real, registry-
# backed derivation -- including 'dag-stalled' -- instead of a second,
# drift-prone copy of it.
my @KINDS = BpAnswer::known_kinds();
ok(scalar(@KINDS) >= 6, 'C5: the derived kind list is non-trivial (derivation actually found producers)')
    or diag('derived kinds: ' . join(',', @KINDS));
diag('C5/C6: kinds derived from bp-orchestrator.pl producers: ' . join(', ', @KINDS));

# Fleet-family kinds are those bp-orchestrator.pl queues with package => '_fleet' (broken-env,
# reauth, contract-drift all use _enter_pause_manual with a fleet-level pause). Everything else
# derived is a real per-package park.
my %FLEET_KIND = map { $_ => 1 } qw(reauth contract-drift broken-env);

for my $kind (@KINDS) {
    if ($FLEET_KIND{$kind}) {
        my ($bpdir, $id) = mk_bp(pkg => 'zzz', kind => $kind, decision_package => '_fleet', paused => 1, no_decision => 1);
        my $did = "_fleet--x1";
        write_file("$bpdir/runs/needs-you/$did.json",
            $J->encode({ package => '_fleet', blueprint => 'bp', kind => $kind, question => '?', created_at => 10 }));
        my ($rc, $out) = run_cli($bpdir, '--decision', $did);   # default action: resume
        is($rc, 0, "C5: fleet-family kind '$kind' produces a deterministic (successful) outcome") or diag($out);
        ok(!-f "$bpdir/runs/.paused", "C5: '$kind' resume actually clears runs/.paused");
    } else {
        my ($bpdir, $id, $pkg) = mk_bp(pkg => 'zzz', kind => $kind);
        my ($rc, $out) = run_cli($bpdir, '--decision', $id);   # default action: relaunch
        is($rc, 0, "C5: package-family kind '$kind' produces a deterministic (successful) outcome") or diag($out);
    }
}

# C6: a kind that is (per the SAME derivation) NOT among the real producers must fail loudly and
# change nothing -- never silently succeed as if it were 'stuck-package'.
{
    my $bogus = 'totally-bogus-kind-xyz';
    ok(!(grep { $_ eq $bogus } @KINDS), 'C6 setup: the chosen bogus kind is genuinely absent from the derived producer list');

    my ($bpdir, $id, $pkg) = mk_bp(pkg => 'zzz', kind => $bogus);
    my $before = slurp("$bpdir/packages/$pkg.md");
    my ($rc, $out) = run_cli($bpdir, '--decision', $id);
    isnt($rc, 0, "C6: an unknown kind ('$bogus') fails loudly (non-zero exit), never silently succeeds")
        or diag($out);
    like($out, qr/\Q$bogus\E/, 'C6: the failure message names the offending kind (actionable)')
        or diag("actual message: $out");
    my $after = slurp("$bpdir/packages/$pkg.md");
    is($after, $before, 'C6: an unknown kind changes NOTHING in the ledger');
    ok(-f "$bpdir/runs/needs-you/$id.json", 'C6: an unknown kind leaves the queued decision in place (not consumed)');
}

# =====================================================================================
# C7 -- --note persists on EVERY action, asserted PER ACTION individually. An aggregate assertion
# would pass with accept/drop still silently dropping the note, which IS the regression defect 4
# is. relaunch/reset are expected to ALREADY pass today (append_human_decision already fires for
# both); accept/drop are expected to FAIL today (the `if $plan->{relaunch}` gate at :268 skips
# them).
# =====================================================================================
for my $case (
    { action => 'relaunch', note => 'Note for relaunch case.' },
    { action => 'reset',    note => 'Note for reset case.' },
    { action => 'accept',   note => 'Note for accept case.' },
    { action => 'drop',     note => 'Note for drop case.' },
) {
    my ($bpdir, $id, $pkg) = mk_bp(pkg => "note_$case->{action}", kind => 'stuck-package');
    my ($rc, $out) = run_cli($bpdir, '--decision', $id, '--action', $case->{action}, '--note', $case->{note});
    is($rc, 0, "C7 ($case->{action}): exit 0") or diag($out);
    my $ledger = slurp("$bpdir/packages/$pkg.md");
    like($ledger, qr/\Q$case->{note}\E/,
        "C7 ($case->{action}): the --note text persists into the ledger -- INDIVIDUALLY asserted, "
      . "not aggregated with the other three actions");
}

# =====================================================================================
# C8 -- nothing is silently discarded. Each sub-case first asserts the script ACCEPTED the input
# (positive gate) before asserting it must refuse (non-zero exit / stated refusal) rather than
# exit 0 having quietly failed to honour it.
# =====================================================================================
{
    # (a) The defect-4 shape restated as a general invariant: accept+note must never land as
    # "exit 0 AND note absent" -- either it honours the note (exit 0, note present -- see C7) or
    # it must refuse (non-zero). The disjunction is the general principle C8 asks for; C7 above
    # already pins which side of it the fix must land on for accept specifically.
    my ($bpdir, $id, $pkg) = mk_bp(pkg => 'c8accept', kind => 'stuck-package');
    my ($rc, $out) = run_cli($bpdir, '--decision', $id, '--action', 'accept', '--note', 'Must not vanish.');
    my $ledger = slurp("$bpdir/packages/$pkg.md");
    my $note_present = ($ledger =~ /Must not vanish\./) ? 1 : 0;
    ok($rc == 0, 'C8(a) positive gate: --action accept --note is ACCEPTED input (exit 0 today)') or diag($out);
    ok(!($rc == 0 && !$note_present),
        'C8(a): accept+note is never "exit 0 with the note silently discarded" -- this is exactly '
      . 'the defect-4 shape restated as a general invariant');

    # (b) --widen-write-set with a blank/empty path: the script has already demonstrated (C3) that
    # it recognises and acts on --widen-write-set for a real value, so this is a case it "accepts"
    # the FLAG for but cannot honour the VALUE -- it must refuse, not silently no-op leaving
    # write_set unchanged with exit 0 and no explanation.
    my ($bpdir2, undef, $pkg2) = mk_bp(pkg => 'c8widen', write_set => 'p/c8widen/', no_decision => 1);
    my $before2 = slurp("$bpdir2/packages/$pkg2.md");
    my ($rc2, $out2) = run_cli($bpdir2, '--package', $pkg2, '--action', 'relaunch', '--widen-write-set', '');
    isnt($rc2, 0, 'C8(b): --widen-write-set "" (a value the script cannot honour) is refused, not a silent no-op')
        or diag($out2);
    like($out2, qr/empty|blank/i, 'C8(b): the refusal specifically names the empty/blank value as the cause')
        or diag("actual message: $out2");
    my $after2 = slurp("$bpdir2/packages/$pkg2.md");
    is($after2, $before2, 'C8(b): a refused empty widen changes NOTHING in the ledger');
}

done_testing();
