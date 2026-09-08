#!/usr/bin/env perl
# t/179 -- hardening fixes from the agent-telemetry/02-dispatch-record-attribution
# red-team report (.ccpraxis-local-data/blueprints/agent-telemetry/reports/02-redteam.md).
#
# Four fixes, four sections below:
#   1. $ID_RE anchor bypass (M1)      -- "..\n"/".\n" must be rejected, not
#      slip past both the character-class check AND the explicit '.'/'..'
#      reject, the way a trailing newline did under `$` (vs `\z`).
#   2. Oversized --budget-seconds silently disables staleness (H1) -- a
#      huge (or non-finite, library-level) budget must fall back to the
#      default staleness threshold, not switch staleness off forever.
#   3. `finish` fabricating a duration into history.jsonl (H2b) -- a record
#      with no usable started_at must still be closeable by `finish`, but
#      with no fabricated duration_seconds and NO history.jsonl line.
#   4. `finish` re-persisting unvalidated attribution (H2d) -- a hand-edited
#      record carrying a path-shaped blueprint/package or an out-of-vocab
#      role must be REFUSED by `finish` (exit 2, naming the field), not
#      silently written back to disk.
#
# HOUSE PATTERN reused verbatim from t/177/t/136: run_cli() shells out with
# CCPRAXIS_DISPATCH_LOG_TEST_NOW=1 so --now is honored and no test sleeps.
# Every probe uses a fresh File::Temp root via --root; the live
# .ccpraxis-local-data/.dispatch-log/ is never touched.
#
# Runs standalone: perl plugins/butler/tests/t/179-dispatch-log-hardening.t
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP ();

my $SCRIPT = "$Bin/../../scripts/bp-dispatch-log.pl";
ok(-f $SCRIPT, "harness: $SCRIPT exists") or BAIL_OUT("script missing");

# Also load as a library so we can probe stale_after_seconds/is_stale
# directly at the pure-function level (fix #2 covers hand-edited records
# too, not just the CLI's own --budget-seconds guard).
my $LOADED = do { local $@; eval { require $SCRIPT }; !$@ };
ok($LOADED, 'harness: bp-dispatch-log.pl requires cleanly as a library');

sub run_cli {
    my (@args) = @_;
    my $tmp = tempdir(CLEANUP => 1);
    my ($out_f, $err_f) = ("$tmp/out", "$tmp/err");
    my $q = sub { my $a = shift; $a =~ s/"/\\"/g; return qq("$a") };
    my $cmd = join(' ', 'perl', $q->($SCRIPT), map { $q->($_) } @args);
    system(qq{CCPRAXIS_DISPATCH_LOG_TEST_NOW=1 $cmd > "$out_f" 2> "$err_f"});
    my $rc = ($? == -1) ? undef : ($? >> 8);
    my $out = _slurp($out_f);
    my $err = _slurp($err_f);
    return ($rc, $out, $err);
}
sub _slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined($c) ? $c : '';
}
sub record_file  { my ($root, $id) = @_; return "$root/.ccpraxis-local-data/.dispatch-log/$id.json" }
sub history_file { my ($root)      = @_; return "$root/.ccpraxis-local-data/.dispatch-log/history.jsonl" }

sub plant_record {
    my ($root, $id, $json) = @_;
    make_path("$root/.ccpraxis-local-data/.dispatch-log");
    open my $fh, '>', record_file($root, $id) or die "open: $!";
    print {$fh} $json;
    close $fh;
}

# ===========================================================================
# 1. $ID_RE anchor bypass (M1) -- "\n"-suffixed '.'/'..' must be refused.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    for my $bad ("..\n", ".\n") {
        my $label = ($bad =~ /\n/) ? (($bad eq "..\n") ? q(".."+LF) : q("."+LF)) : $bad;
        my ($rc, undef, $err) = run_cli('start', '--id', 'z1', '--worker-type', 'wt',
                                          '--blueprint', $bad, '--now', '1000', '--root', $root);
        is($rc, 2, "fix1: --blueprint $label is REFUSED (exit 2), not stored past the reject");
        like($err // '', qr/invalid shape/, "fix1: --blueprint $label refusal says 'invalid shape'");
        ok(!-e record_file($root, 'z1'), "fix1: --blueprint $label -- no record file written");
    }
    for my $bad ("..\n", ".\n") {
        my ($rc, undef, $err) = run_cli('start', '--id', 'z2', '--worker-type', 'wt',
                                          '--package', $bad, '--now', '1000', '--root', $root);
        is($rc, 2, 'fix1: --package "..\n"-shaped value is REFUSED (exit 2)');
        like($err // '', qr/invalid shape/, 'fix1: --package refusal says invalid shape');
    }
    # \z tightens --id too (task note): a trailing-newline id must also be refused.
    my ($rc3, undef, $err3) = run_cli('start', '--id', "abc\n", '--worker-type', 'wt',
                                        '--now', '1000', '--root', $root);
    isnt($rc3, 0, 'fix1: --id with a trailing newline is refused (the same \\z tightening)');
    like($err3 // '', qr/invalid shape/, 'fix1: --id trailing-newline refusal says invalid shape');

    # Contrast: legitimate values with no trailing newline still work.
    my ($rc4) = run_cli('start', '--id', 'z3', '--worker-type', 'wt', '--blueprint', 'ok-bp',
                          '--package', 'ok.pkg', '--now', '1000', '--root', $root);
    is($rc4, 0, 'fix1: an ordinary --blueprint/--package (no trailing newline) still exits 0');
}

# ===========================================================================
# 2. Oversized --budget-seconds no longer silently disables staleness (H1).
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my ($rc1) = run_cli('start', '--id', 'h1', '--worker-type', 'wt',
                          '--budget-seconds', '999999999999999999999',
                          '--now', '1000', '--root', $root);
    is($rc1, 0, 'fix2: start with an absurd --budget-seconds still exits 0 (not refused outright)');

    my (undef, $out2) = run_cli('list', '--now', '999999999', '--root', $root);
    like($out2, qr/\bh1\b/, 'fix2: list still shows h1');
    like($out2, qr/stale:\s*true\b/,
         'fix2: CANONICAL -- an absurd budget no longer suppresses staleness; list marks h1 stale: true '
       . '(this is exactly the H1 reproduction from the red-team report, now fixed)');

    # Contrast: a small, honest budget at the same clock is ALSO stale --
    # proves the fix did not just flip the boolean, it makes the two
    # converge on the same (correct) answer.
    my $root2 = tempdir(CLEANUP => 1);
    run_cli('start', '--id', 'h2', '--worker-type', 'wt', '--budget-seconds', '1800',
            '--now', '1000', '--root', $root2);
    my (undef, $out3) = run_cli('list', '--now', '999999999', '--root', $root2);
    like($out3, qr/stale:\s*true\b/, 'fix2: contrast -- an honest small budget is ALSO stale: true at this clock');
}

# Library-level: stale_after_seconds/is_stale must fall back to the default
# for a non-finite or absurdly large budget on a HAND-EDITED record too --
# the report's point that the fix belongs at the point of use, not only the
# CLI's own regex.
{
    no warnings 'once';  # $BpDispatchLog::DEFAULT_BUDGET_SECONDS is referenced only here
    my $default_threshold = $BpDispatchLog::STALE_BUDGET_MULTIPLE * $BpDispatchLog::DEFAULT_BUDGET_SECONDS;
    for my $budget (1e21, 999999999999999999999, 9**9**9) {  # 9**9**9 overflows to Inf in Perl
        is(BpDispatchLog::stale_after_seconds($budget), $default_threshold,
           "fix2 CANONICAL: stale_after_seconds($budget) falls back to the default threshold "
         . "($default_threshold), not a threshold scaled by the huge/non-finite budget itself");
    }
    # And the boundary itself: exactly at the cap still scales normally,
    # proving this is a ceiling, not an accidental blanket fallback.
    is(BpDispatchLog::stale_after_seconds($BpDispatchLog::MAX_BUDGET_SECONDS),
       $BpDispatchLog::STALE_BUDGET_MULTIPLE * $BpDispatchLog::MAX_BUDGET_SECONDS,
       'fix2: a budget exactly AT the cap still scales normally (this is a ceiling, not a blanket override)');
    is(BpDispatchLog::stale_after_seconds($BpDispatchLog::MAX_BUDGET_SECONDS + 1),
       $default_threshold,
       'fix2: one second past the cap falls back to the default');
    # A realistic budget used elsewhere on this run (3000s) must be
    # completely unaffected.
    is(BpDispatchLog::stale_after_seconds(3000), $BpDispatchLog::STALE_BUDGET_MULTIPLE * 3000,
       'fix2: a real-world budget (3000s) scales normally, unaffected by the cap');

    my $rec = { status => 'running', started_at => 1000, budget_seconds => 999999999999999999999 };
    ok(BpDispatchLog::is_stale($rec, 1000 + $default_threshold + 1),
       'fix2: is_stale() on a hand-edited record with an absurd budget is TRUE past the default threshold '
     . '(not suppressed by the bogus budget) -- the fix is at the point of use, per the task instructions');
}

# ===========================================================================
# 3. `finish` no longer fabricates a duration into history.jsonl (H2b).
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    plant_record($root, 'g1',
        '{"id":"g1","worker_type":"bp-implementer","status":"running","budget_seconds":1800,"note":null}');
    # no started_at key at all.

    my ($rc, $out, $err) = run_cli('finish', '--id', 'g1', '--status', 'done',
                                     '--now', '1800000000', '--root', $root);
    is($rc, 0, 'fix3: finish on a record with no started_at still exits 0 (closes, does not strand it)');
    unlike($err // '', qr/uninitialized value/i,
           'fix3: no "uninitialized value" Perl warning on stderr (was a contract break -- stdout+stderr parsed)');

    my $rec = JSON::PP->new->decode(_slurp(record_file($root, 'g1')));
    is($rec->{status}, 'done', 'fix3: the record IS closed (status=done) despite no usable started_at');
    ok(!exists $rec->{duration_seconds},
       'fix3 CANONICAL: NO fabricated duration_seconds is persisted to the record '
     . '(this is the defect: previously duration_seconds:1800000000 was written)');

    ok(!-e history_file($root), 'fix3 CANONICAL: no history.jsonl file is created at all')
        or do {
            my $h = _slurp(history_file($root));
            is($h, '', 'fix3 CANONICAL: history.jsonl has NO line for this finish (permanent median skew, avoided)');
        };

    # Same with a non-numeric started_at (the second reproduction in the report).
    my $root2 = tempdir(CLEANUP => 1);
    plant_record($root2, 'g2',
        '{"id":"g2","worker_type":"bp-implementer","status":"running","started_at":"soon","budget_seconds":1800,"note":null}');
    my ($rc2, undef, $err2) = run_cli('finish', '--id', 'g2', '--status', 'done',
                                        '--now', '1800000000', '--root', $root2);
    is($rc2, 0, 'fix3: non-numeric started_at ("soon") -- finish still exits 0');
    unlike($err2 // '', qr/isn't numeric/i, 'fix3: no "isn\'t numeric" Perl warning on stderr');
    my $rec2 = JSON::PP->new->decode(_slurp(record_file($root2, 'g2')));
    ok(!exists $rec2->{duration_seconds}, 'fix3: no fabricated duration_seconds for a non-numeric started_at either');
    ok(!-e history_file($root2), 'fix3: no history.jsonl for the non-numeric-started_at case either');

    # Contrast: a record WITH a usable started_at is completely unaffected.
    my $root3 = tempdir(CLEANUP => 1);
    run_cli('start', '--id', 'ok1', '--worker-type', 'wt', '--now', '1000', '--root', $root3);
    my ($rc3, $out3) = run_cli('finish', '--id', 'ok1', '--status', 'done', '--now', '2000', '--root', $root3);
    is($rc3, 0, 'fix3 contrast: a normal finish (usable started_at) still exits 0');
    like($out3, qr/duration_seconds=1000\b/, 'fix3 contrast: a normal finish still reports the real duration');
    my $h3 = _slurp(history_file($root3));
    like($h3, qr/"duration_seconds":1000\b/, 'fix3 contrast: a normal finish still appends history.jsonl as before');
}

# ===========================================================================
# 4. `finish` refuses to re-persist unvalidated attribution (H2d).
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $planted = '{"blueprint":"../../../etc","budget_seconds":1800,"id":"x9","note":null,'
                . '"package":"..","role":"overseer","started_at":1000,"status":"running","worker_type":"wt"}';
    plant_record($root, 'x9', $planted);

    my ($rc, $out, $err) = run_cli('finish', '--id', 'x9', '--status', 'done', '--now', '2000', '--root', $root);
    is($rc, 2, 'fix4 CANONICAL: finish on a record with path-shaped blueprint is REFUSED (exit 2), not written back');
    like($err // '', qr/blueprint/, 'fix4: refusal names the offending field (blueprint)');
    like($err // '', qr/invalid shape/, "fix4: refusal says 'invalid shape'");

    my $after = _slurp(record_file($root, 'x9'));
    is($after, $planted, 'fix4 CANONICAL: the on-disk record is byte-identical after the refusal -- '
                        . 'no laundering, no silent strip, no re-persisted done/duration_seconds');
    is(_slurp(history_file($root)), '', 'fix4: no history.jsonl line is appended on a refused finish');

    # role is checked too, independently of blueprint/package.
    my $root2 = tempdir(CLEANUP => 1);
    my $planted2 = '{"budget_seconds":1800,"id":"x10","note":null,"role":"overseer",'
                 . '"started_at":1000,"status":"running","worker_type":"wt"}';
    plant_record($root2, 'x10', $planted2);
    my ($rc2, undef, $err2) = run_cli('finish', '--id', 'x10', '--status', 'done', '--now', '2000', '--root', $root2);
    is($rc2, 2, 'fix4: finish on a record with an out-of-vocabulary role is also REFUSED (exit 2)');
    like($err2 // '', qr/role/, 'fix4: refusal names the offending field (role)');
    is(_slurp(record_file($root2, 'x10')), $planted2,
       'fix4: the on-disk record with the bad role is also byte-identical after the refusal');

    # Contrast (AC25-equivalent, re-pinned here): finish on a record with
    # VALID attribution (written via `start`, so already validated) is
    # completely unaffected and still succeeds.
    my $root3 = tempdir(CLEANUP => 1);
    run_cli('start', '--id', 'ok2', '--worker-type', 'wt', '--blueprint', 'bp', '--package', 'pk',
            '--role', 'judge', '--now', '1000', '--root', $root3);
    my ($rc3) = run_cli('finish', '--id', 'ok2', '--status', 'done', '--now', '2000', '--root', $root3);
    is($rc3, 0, 'fix4 contrast: finish on a validly-attributed record still exits 0');
    my $rec3 = JSON::PP->new->decode(_slurp(record_file($root3, 'ok2')));
    is($rec3->{blueprint}, 'bp', 'fix4 contrast: valid blueprint is preserved as before');
    is($rec3->{role}, 'judge', 'fix4 contrast: valid role is preserved as before');
}

done_testing();
