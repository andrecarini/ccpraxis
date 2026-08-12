#!/usr/bin/env perl
# t/110-ledger-budget-fixbatch.t -- regression tests for the a03-ledger-budget-irreducible
# step-6 fix-batch (reviewer-step6.md MAJOR + red-team-step6.md MAJOR-1/MAJOR-2). Derived from
# the pipeline-step-7 dispatch, not the original spec (those cases are already pinned by the
# IMMUTABLE t/109-ledger-budget-irreducible.t, which this file does not touch or duplicate).
#
# Three findings, three groups of cases below:
#
#   DR  (red-team MAJOR-2): ensure_dir_exists('C:foo/bar') -- a drive-RELATIVE Windows path (a
#       colon with NO separator right after it) -- must be REFUSED, not silently treated as a
#       plain relative path segment. Demonstrated by the red-team to create a stray "C:foo"
#       directory relative to the process CWD. Exercised as a direct in-process unit call
#       (require'd, same technique the red-team used) -- never through a live rotate/--ledger
#       invocation with a drive-relative path, for the same reason the red-team gave: Windows
#       drive-relative resolution depends on per-drive "current directory" process state that is
#       not safely controllable from a test harness, and a wrong guess risks writing onto the
#       real C: drive.
#
#   LK  (reviewer MAJOR / red-team MINOR-2, same defect, consolidated): run_op's real-write
#       success path must call $post_cb BEFORE releasing the ledger's flock, matching the no-op
#       path and op_rotate's $finalize_budget_state. Pinned as a SOURCE-INVARIANT (the ordering
#       of two literal call sites in run_op's real-write branch) -- a true concurrent-process race
#       is not deterministically reproducible in a portable sequential test harness (the reviewer
#       said so explicitly), so the regression test asserts the code shape that makes the race
#       impossible, not the race's absence under load.
#
#   MK  (red-team MAJOR-1): the cross-process suppression marker (<ledger>.budget-state) must not
#       be trusted forever/unconditionally. A forged marker (planted directly, bypassing rotate
#       entirely -- the red-team's exact demonstrated attack) or one whose "notified" claim has
#       aged past its trust window must fail toward RE-NOTIFYING (noisy), never toward permanent
#       silence.
#
# ISOLATION: same discipline as t/109 -- every bp-ledger.pl invocation runs via
# `bash -c 'cd "$WD" && perl ...'` under an explicit, fresh, otherwise-empty scratch directory,
# and DR's direct ensure_dir_exists() call runs after an explicit chdir into its own fresh,
# otherwise-empty scratch directory, verified empty again afterward. Fixtures are anchored under
# the native Windows TEMP dir (HostCaps::tempdir_args), never /tmp, and every ledger path used has
# the required ".../packages/<pkg>.md" shape with a sibling reports/.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path getcwd);
use HostCaps qw(tempdir_args);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $BUTLER = fwd(abs_path("$Bin/../..") // "$Bin/../..");
my $SCRIPT = "$BUTLER/scripts/bp-ledger.pl";
ok(-e $SCRIPT, "HARNESS: bp-ledger.pl present at $SCRIPT") or BAIL_OUT("subject script missing: $SCRIPT");

my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

my $ROOT = tempdir(tempdir_args(), CLEANUP => 1);
my $pn = 0;
my $dn = 0;

sub fresh_dir {
    my $d = "$ROOT/w" . (++$dn);
    mkdir $d or die "mkdir $d: $!";
    return $d;
}

sub write_file {
    my ($path, $bytes) = @_;
    open my $w, '>', $path or die "write $path: $!";
    binmode $w;
    print $w $bytes;
    close $w or die "close $path: $!";
    return $path;
}

sub read_file {
    my ($path) = @_;
    open my $r, '<', $path or return undef;
    binmode $r;
    local $/;
    my $c = <$r>;
    close $r;
    return defined $c ? $c : '';
}

sub run_pl {
    my ($args, %o) = @_;
    my $cwd = $o{cwd} // fresh_dir();
    my %extra_env = %{ $o{env} // {} };
    my $n    = ++$pn;
    my $outf = "$ROOT/out.$n";
    my $errf = "$ROOT/err.$n";
    write_file($outf, '');
    write_file($errf, '');
    local %ENV = (%CLEAN_ENV, %extra_env,
                  LGT_SCRIPT => fwd($SCRIPT), LGT_OUT => fwd($outf), LGT_ERR => fwd($errf), LGT_WD => fwd($cwd));
    my $rc = system('bash', '-c',
        'cd "$LGT_WD" && timeout 60 perl "$LGT_SCRIPT" "$@" > "$LGT_OUT" 2> "$LGT_ERR"',
        'bp-ledger', @$args);
    return ($rc >> 8, read_file($outf) // '', read_file($errf) // '');
}

sub filler_entry {
    my ($date, $n) = @_;
    return "- ${date}T00:00:00Z -- " . ('A' x $n);
}

sub ledger_bytes {
    my (%o) = @_;
    my $entries = $o{entries} // [ '- 2026-01-01T00:00:00Z -- placeholder entry' ];
    my $status  = $o{status} // 'running';
    return join("\n",
        '---',
        'package: fixture-pkg',
        'blueprint: fixture-bp',
        "status: $status",
        'write_set:',
        '  - plugins/butler/scripts/bp-ledger.pl',
        'last_updated: 2026-01-01T00:00:00Z',
        '---',
        '',
        '# fixture-pkg',
        '',
        '## Next action',
        '',
        'Do the next thing.',
        '',
        '## Pipeline',
        '',
        '- [x] 1. first step',
        '',
        '## Decisions & attempt log',
        '',
        join("\n", @$entries),
        '',
        '## Outputs',
        '',
        '- ran something',
        '',
        '## Escalation (when status: blocked)',
        '',
        '_(none)_',
        '',
    );
}

sub stage_ledger {
    my ($bytes, %o) = @_;
    my $pkg   = $o{pkg}   // 'fixture-pkg';
    my $bpdir = $o{bpdir} // fresh_dir();
    mkdir "$bpdir/packages" unless -d "$bpdir/packages";
    mkdir "$bpdir/reports"  unless -d "$bpdir/reports";
    return write_file("$bpdir/packages/$pkg.md", $bytes);
}

# Over-budget-but-reducible: enough to trip the >40000-byte check in $budget_check without any
# rotate ever needing to run for it.
my @OVER_BUDGET_ENTRIES = map { filler_entry(sprintf('2026-02-%02d', $_), 4200) } (1 .. 10);

# Genuinely irreducible (floor alone exceeds budget) -- same shape as t/109's IRREDUCIBLE_ENTRIES,
# reconstructed here rather than shared (t/109 is immutable and not a module).
my @IRREDUCIBLE_ENTRIES = map { filler_entry(sprintf('2026-03-%02d', $_), 8600) } (1 .. 5);

# =====================================================================================
# DR -- drive-relative Windows paths must be refused by ensure_dir_exists, not silently
# treated as a plain relative path (red-team step6 MAJOR-2).
# =====================================================================================
{
    my $work = fresh_dir();
    my $orig_cwd = getcwd();
    chdir($work) or die "chdir $work: $!";

    # Guarded require: bp-ledger.pl is explicitly written to be require'able (the dispatch
    # block at the bottom is gated on `unless (caller)`, the same shape ledger-guard.sh's
    # embedded validator already relies on) -- this is not a private hack.
    eval { require $SCRIPT; 1 } or do {
        chdir($orig_cwd);
        BAIL_OUT("DR: could not require bp-ledger.pl for direct unit test: $@");
    };

    my $r1 = main::ensure_dir_exists('C:foo/bar');
    is($r1, 0, 'DR-1: ensure_dir_exists("C:foo/bar") (drive-relative, no separator after the colon) is REFUSED');

    my $r2 = main::ensure_dir_exists('D:another\\thing');
    is($r2, 0, 'DR-2: ensure_dir_exists("D:another\\thing") (drive-relative, backslash form) is REFUSED');

    opendir(my $dh, $work) or die "opendir $work: $!";
    my @entries = grep { !/^\.\.?$/ } readdir($dh);
    closedir($dh);
    is_deeply(\@entries, [],
        'DR-3 (regression): NOTHING was created relative to the cwd for either drive-relative call '
      . '-- this is the exact stray the red-team demonstrated ("C:foo/bar" created a literal '
      . '"C:foo" directory under the process cwd before this fix)');

    # Sanity: the drive-ABSOLUTE fix (spec 2.4, already covered by t/109 CASE7) is untouched --
    # confirm the refusal is specific to the drive-relative shape, not an over-broad regression.
    ok(main::ensure_dir_exists("$work/absok/sub/dir"), 'DR-4: an ordinary relative-to-caller absolute path still succeeds (no over-broad refusal)');
    ok(-d "$work/absok/sub/dir", 'DR-4: ...and the directory really was created');

    chdir($orig_cwd) or die "chdir back to $orig_cwd: $!";
}

# =====================================================================================
# LK -- run_op's real-write success path must call $post_cb BEFORE releasing the flock
# (reviewer step6 MAJOR / red-team MINOR-2, same defect).
# =====================================================================================
{
    open(my $fh, '<', $SCRIPT) or die "read $SCRIPT: $!";
    local $/;
    my $src = <$fh>;
    close $fh;

    $src =~ /^sub run_op \{(.*?)^\}/ms;
    my $run_op_body = $1;
    ok(defined $run_op_body && length($run_op_body) > 0, 'LK FIXTURE-SANITY: run_op sub body extracted from source');

    # The real-write success path is the LAST occurrence of "$post_cb->($new) if $post_cb;" and
    # the LAST occurrence of "flock($lk, LOCK_UN)" in run_op (the no-op path's flock is only
    # implicit, via process exit -- it never calls flock(LOCK_UN) explicitly).
    my @post_cb_pos = ();
    while ($run_op_body =~ /\$post_cb->\(\$new\) if \$post_cb;/g) { push @post_cb_pos, pos($run_op_body) }
    my @unlock_pos = ();
    while ($run_op_body =~ /flock\(\$lk,\s*LOCK_UN\)/g) { push @unlock_pos, pos($run_op_body) }

    ok(scalar(@post_cb_pos) >= 1, 'LK FIXTURE-SANITY: run_op calls $post_cb at least once');
    ok(scalar(@unlock_pos) == 1, 'LK FIXTURE-SANITY: run_op calls flock(LOCK_UN) exactly once (the real-write success path)');

    ok($post_cb_pos[-1] < $unlock_pos[0],
        'LK (regression, reviewer step6 MAJOR / red-team MINOR-2): the real-write path\'s $post_cb call now '
      . 'appears BEFORE flock($lk, LOCK_UN) in the source -- previously it ran AFTER the unlock, an '
      . 'inconsistency with the no-op path and with op_rotate\'s own $finalize_budget_state (always '
      . 'called before its flock(LOCK_UN))')
        or diag("post_cb positions: @post_cb_pos; unlock positions: @unlock_pos");
}

# =====================================================================================
# MK -- the suppression marker must fail toward NOISY, never permanently silent
# (red-team step6 MAJOR-1).
# =====================================================================================

# MK-1: the red-team's exact demonstrated attack -- plant "irreducible notified" directly,
# WITHOUT ever running rotate, and WITHOUT a timestamp (exactly what they wrote). Must NOT
# suppress: a marker with no verifiable freshness is untrusted.
{
    my $bpdir = fresh_dir();
    my $path  = stage_ledger(ledger_bytes(entries => \@OVER_BUDGET_ENTRIES), bpdir => $bpdir, pkg => 'mk1-pkg');
    my $marker_path = "$path.budget-state";
    write_file($marker_path, "irreducible notified\n");
    ok(-e $marker_path, 'MK-1 FIXTURE-SANITY: forged marker planted, no rotate ever ran');

    my $t = write_file("$ROOT/mk1-text.txt", 'append after a forged marker, no real rotate');
    my ($rc, $out, $err) = run_pl(['append-attempt', '--ledger', $path, '--text-file', $t]);
    is($rc, 0, 'MK-1: the append still exits 0 (a forged marker must never turn into a refusal either)');
    ok(length($err) > 0,
        'MK-1 (regression, red-team MAJOR-1): a forged marker with NO timestamp does NOT silently '
      . 'suppress the notice -- the exact attack the red-team demonstrated end-to-end is now noisy')
        or diag("stderr was empty; forged marker silently suppressed the notice");
}

# MK-2: a forged marker claiming a FAR-FUTURE timestamp (gaming a naive "is it fresh" check by
# lying about when it was written) must also fail toward noisy, not silent.
{
    my $bpdir = fresh_dir();
    my $path  = stage_ledger(ledger_bytes(entries => \@OVER_BUDGET_ENTRIES), bpdir => $bpdir, pkg => 'mk2-pkg');
    my $marker_path = "$path.budget-state";
    write_file($marker_path, "irreducible notified 9999999999\n");

    my $t = write_file("$ROOT/mk2-text.txt", 'append after a forged future-timestamped marker');
    my ($rc, $out, $err) = run_pl(['append-attempt', '--ledger', $path, '--text-file', $t]);
    is($rc, 0, 'MK-2: the append still exits 0');
    ok(length($err) > 0,
        'MK-2 (regression, red-team MAJOR-1): a forged marker with a FAR-FUTURE timestamp does not '
      . 'buy permanent trust either -- a future stamp is treated as untrusted, not extra-fresh');
}

# MK-3: a GENUINE marker (written by a real irreducible rotate) still suppresses correctly within
# its trust window -- the fix must not turn the feature into permanent noise (this is the
# suppression behaviour t/109 CASE5 already pins end-to-end; repeated narrowly here only to prove
# MK-1/MK-2 didn't break the legitimate case by being over-broad).
{
    my $bpdir = fresh_dir();
    my $path  = stage_ledger(ledger_bytes(entries => \@IRREDUCIBLE_ENTRIES), bpdir => $bpdir, pkg => 'mk3-pkg');
    my ($rrc, $rout, $rerr) = run_pl(['rotate', '--ledger', $path]);
    is($rrc, 0, 'MK-3 setup: the genuine irreducible rotate exits 0');

    my $t1 = write_file("$ROOT/mk3-text1.txt", 'first append after a genuine irreducible rotate');
    my ($rc1, $out1, $err1) = run_pl(['append-attempt', '--ledger', $path, '--text-file', $t1]);
    is($rc1, 0, 'MK-3: first post-rotate append exits 0');
    ok(length($err1) > 0, 'MK-3: the FIRST append after a genuine irreducible rotate emits the notice');

    my $t2 = write_file("$ROOT/mk3-text2.txt", 'second append after a genuine irreducible rotate');
    my ($rc2, $out2, $err2) = run_pl(['append-attempt', '--ledger', $path, '--text-file', $t2]);
    is($rc2, 0, 'MK-3: second post-rotate append exits 0');
    is($err2, '', 'MK-3: the SECOND append is still silent -- a genuine, freshly-written marker is trusted '
                 . 'within its window; MK-1/MK-2 did not turn suppression off entirely');
}

# MK-4: the trust window is enforced, not merely present as an unused knob -- with the TTL forced
# to 0 (BP_LEDGER_BUDGET_MARKER_TTL, a test-only seam mirroring BP_LEDGER_FAIL_RENAME), even a
# GENUINE marker written moments ago must re-notify rather than suppress.
{
    my $bpdir = fresh_dir();
    my $path  = stage_ledger(ledger_bytes(entries => \@IRREDUCIBLE_ENTRIES), bpdir => $bpdir, pkg => 'mk4-pkg');
    my ($rrc, $rout, $rerr) = run_pl(['rotate', '--ledger', $path]);
    is($rrc, 0, 'MK-4 setup: the genuine irreducible rotate exits 0');

    my $t1 = write_file("$ROOT/mk4-text1.txt", 'first append, TTL forced to 0');
    my ($rc1, $out1, $err1) = run_pl(['append-attempt', '--ledger', $path, '--text-file', $t1],
        env => { BP_LEDGER_BUDGET_MARKER_TTL => '0' });
    is($rc1, 0, 'MK-4: first append (TTL=0) exits 0');
    ok(length($err1) > 0, 'MK-4: first append (TTL=0) emits the notice');

    my $t2 = write_file("$ROOT/mk4-text2.txt", 'second append, TTL forced to 0');
    my ($rc2, $out2, $err2) = run_pl(['append-attempt', '--ledger', $path, '--text-file', $t2],
        env => { BP_LEDGER_BUDGET_MARKER_TTL => '0' });
    is($rc2, 0, 'MK-4: second append (TTL=0) exits 0');
    ok(length($err2) > 0,
        'MK-4 (regression, red-team MAJOR-1): with the trust window forced to 0, even a GENUINE, '
      . 'freshly-written marker re-notifies on the very next call -- proves the TTL mechanism is '
      . 'load-bearing, not a knob that happens to never fire');
}

done_testing();
