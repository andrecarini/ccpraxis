#!/usr/bin/env perl
# t/109-ledger-budget-irreducible.t -- a03-ledger-budget-irreducible oracle.
# Derived ONLY from
# .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/specs/a03-ledger-budget-irreducible-spec.md
# section 3 (the 8 enumerated cases), section 2 (what to build) and section 1 (ground truth).
#
# WRITTEN BLIND TO THE IMPLEMENTATION of the fix. The spec deliberately leaves the suppression
# mechanism open ("any mechanism that survives across processes is acceptable" -- section 2.1), so
# nothing here asserts a marker file, an env var, or any other internal representation. Every
# assertion is against OBSERVABLE behaviour only: exit codes, stderr shape, and file contents.
#
# READ SECTION 1 BEFORE TRUSTING THE PACKAGE DESCRIPTION: append-attempt does NOT refuse over
# budget, and never has (emit_err only prints; it never exits). This file never asserts a refusal --
# doing so would be asserting a behaviour change the spec explicitly rules out (section 4).
#
# THREE THINGS EXPECTED TO FAIL AGAINST HEAD, for the reasons the spec names:
#   - CASE2 / CASE4: the budget/irreducible notices currently reuse the exact
#     `bp-ledger: <op>: <path>: <message>` shape the four error helpers (arg_error/io_error/
#     reject_error/notfound_error) emit, and carry no stable machine-readable token (spec 2.1/2.2).
#   - CASE5/CASE6 (suppression): today there is no cross-process suppression at all -- every
#     `bp-ledger.pl` invocation is a fresh process and re-emits the notice on every over-budget
#     append (spec 2.1, second bullet).
#   - CASE7: `ensure_dir_exists` (bp-ledger.pl:698-710) treats a Windows drive-absolute path
#     (`C:/...`) as relative (`$dir =~ m{^/}` never matches), rebuilding the whole target tree under
#     the process's CWD instead of at the drive-absolute location, then failing later when the real
#     target still doesn't exist (spec 1c). Reproduced for real -- this is a regression test for an
#     artifact that was actually produced, not a hypothetical.
#   - CASE8: the documented one-stderr-line invariant (bp-ledger.pl:20) is currently violated on a
#     rotate that is BOTH irreducible AND still moves some (non-floor) entries and then hits an I/O
#     failure: the irreducible notice plus the io_error are two lines (spec 1d).
# CASE1 (plain in-budget append) and the "diagnosis wording preserved" / "rotate exits 0"
# sub-assertions of CASE3/CASE4 are expected to ALREADY PASS at HEAD -- said so explicitly at each
# site below, never silently assumed.
#
# ISOLATION, load-bearing: `ensure_dir_exists`'s bug (case 1c/CASE7) recreates its target tree
# RELATIVE TO THE SUBPROCESS'S OWN CWD. Every `bp-ledger.pl` invocation below is therefore run via
# `bash -c 'cd "$WD" && perl ...'` with an EXPLICIT, fresh, otherwise-empty scratch directory as
# $WD -- never the directory this test file (or the coordinator) happens to be invoked from. Without
# this, a naive test run risks depositing a stray "./C:/..." tree in the real repository, exactly the
# landmine documented in the project CLAUDE.md.
#
# Fixtures are anchored under the native Windows TEMP dir (HostCaps::tempdir_args), never /tmp:
# rotate requires the ledger path be of the exact shape ".../packages/<pkg>.md" or it exits 3 before
# doing anything (reproduced), and every fixture built here has that shape plus a sibling reports/.
# Nothing here ever opens a real blueprint's ledger for writing.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
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

# run_pl(\@args, cwd => $dir, env => {...}) -- ALWAYS runs under an explicit, isolated CWD (see
# ISOLATION note above). stdout/stderr captured via separate temp files (never by reopening STDOUT
# onto an in-memory scalar -- Git-for-Windows perl dies "Bad file descriptor" there).
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

# =====================================================================================
# Fixture scaffolding
# =====================================================================================

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

# .../<bpdir>/packages/<pkg>.md, WITH a sibling reports/ dir already present (but never
# reports/ledger-history/ itself -- CASE3/CASE7 need that to genuinely not exist yet).
sub stage_ledger {
    my ($bytes, %o) = @_;
    my $pkg   = $o{pkg}   // 'fixture-pkg';
    my $bpdir = $o{bpdir} // fresh_dir();
    mkdir "$bpdir/packages" unless -d "$bpdir/packages";
    mkdir "$bpdir/reports"  unless -d "$bpdir/reports";
    return write_file("$bpdir/packages/$pkg.md", $bytes);
}

my @SMALL_ENTRIES = (
    '- 2026-01-01T00:00:00Z -- small entry one',
    '- 2026-01-02T00:00:00Z -- small entry two',
);

# ~42,269 decisions bytes: over the 40,000-byte budget, but the floor (--keep 5, default) alone
# is well under budget -- a rotate CAN reduce this. Used for CASE2 (over-budget-but-reducible
# append) and CASE3 (a rotate that actually succeeds).
my @REDUCIBLE_ENTRIES = map { filler_entry(sprintf('2026-02-%02d', $_), 4200) } (1 .. 10);

# ~43,134 decisions bytes across exactly 5 (== the default --keep floor) non-marker entries: the
# floor ALONE already exceeds the 40,000-byte budget, so rotate can never reduce it -- genuinely
# irreducible. Used for CASE4/CASE5/CASE6 (none of which should ever move an entry, so none of them
# exercise ensure_dir_exists -- kept orthogonal to CASE7's defect on purpose).
my @IRREDUCIBLE_ENTRIES = map { filler_entry(sprintf('2026-03-%02d', $_), 8600) } (1 .. 5);

# 3 small OLD entries (eligible to move) + the same 5-entry irreducible floor: the floor alone is
# already over budget, so this is STILL irreducible overall (unreachable=1), but the 3 small
# entries above the floor DO get moved (@moved non-empty) -- the exact combination CASE8 needs to
# reach the write path (and thus RENAME_FN / ensure_dir_exists) while still being irreducible.
my @OLI_OLD_SMALL = map { filler_entry(sprintf('2026-04-%02d', $_), 50) } (1 .. 3);
my @OLI_ENTRIES    = (@OLI_OLD_SMALL, @IRREDUCIBLE_ENTRIES);

ok(scalar(@REDUCIBLE_ENTRIES) == 10, 'FIXTURE-SANITY: reducible fixture has 10 entries');
ok(scalar(@IRREDUCIBLE_ENTRIES) == 5, 'FIXTURE-SANITY: irreducible fixture has exactly the default --keep floor (5) entries');
ok(scalar(@OLI_ENTRIES) == 8, 'FIXTURE-SANITY: one-line-invariant fixture has 3 movable + 5 floor entries');

my ($REDUCIBLE_APPEND_TOKEN, $IRREDUCIBLE_APPEND_TOKEN);

# =====================================================================================
# CASE1 (spec sec3 #1): a normal append to an in-budget ledger -- exit 0, no notice.
# EXPECTED TO ALREADY PASS AT HEAD: the in-budget path is untouched by this package.
# =====================================================================================
{
    my $bpdir = fresh_dir();
    my $path  = stage_ledger(ledger_bytes(entries => \@SMALL_ENTRIES), bpdir => $bpdir);
    my $before_sz = -s $path;
    ok($before_sz <= 40000, "CASE1 FIXTURE-SANITY: in-budget fixture is <=40,000 bytes ($before_sz)");

    my $textfile = write_file("$ROOT/case1-text.txt", 'a normal in-budget attempt');
    my ($rc, $out, $err) = run_pl(['append-attempt', '--ledger', $path, '--text-file', $textfile]);

    is($rc, 0, 'CASE1: exit 0');
    is($err, '', 'CASE1: no notice on stderr for an in-budget append (expected to already pass at HEAD)');
    like(read_file($path), qr/a normal in-budget attempt/, 'CASE1: the new entry text landed');
}

# =====================================================================================
# CASE2 (spec sec3 #2): an append to an over-budget-but-reducible ledger -- exit 0, write lands,
# notice emitted, notice distinguishable from an error line (spec 2.1) and machine-readable (2.2).
# =====================================================================================
{
    my $bpdir = fresh_dir();
    my $path  = stage_ledger(ledger_bytes(entries => \@REDUCIBLE_ENTRIES), bpdir => $bpdir);
    my $before_sz = -s $path;
    ok($before_sz > 40000, "CASE2 FIXTURE-SANITY: reducible-over-budget fixture is >40,000 bytes ($before_sz)");

    my $textfile = write_file("$ROOT/case2-text.txt", 'an attempt against an over-budget-but-reducible ledger');
    my ($rc, $out, $err) = run_pl(['append-attempt', '--ledger', $path, '--text-file', $textfile]);

    is($rc, 0, 'CASE2: append-attempt still exits 0 over budget (never refuses -- spec 1a)');
    ok((-s $path) > $before_sz, 'CASE2: the write actually landed (file grew)');
    like(read_file($path), qr/an attempt against an over-budget-but-reducible ledger/, 'CASE2: new entry text is present');
    ok(length($err) > 0, 'CASE2: a notice was emitted on stderr');
    unlike($err, qr/^bp-ledger: append-attempt: \Q$path\E: /,
        'CASE2: the notice does NOT reuse the `bp-ledger: <op>: <path>: <message>` error shape (spec 2.1)');
    like($err, qr/^bp-ledger: append-attempt: [A-Z][A-Z0-9_-]{2,}:/,
        'CASE2: the notice carries a stable, greppable machine-readable token right after the op prefix (spec 2.2)');
    ($REDUCIBLE_APPEND_TOKEN) = ($err =~ /^bp-ledger: append-attempt: ([A-Z][A-Z0-9_-]{2,}):/);
}

# =====================================================================================
# CASE3 (spec sec3 #3): a rotate that succeeds -- entries move to
# reports/ledger-history/<pkg>.md, ledger lands at/under budget, exit 0.
# =====================================================================================
{
    my $bpdir = fresh_dir();
    my $path  = stage_ledger(ledger_bytes(entries => \@REDUCIBLE_ENTRIES), bpdir => $bpdir, pkg => 'case3-pkg');
    my $hist_path = "$bpdir/reports/ledger-history/case3-pkg.md";
    ok(!-e $hist_path, 'CASE3 FIXTURE-SANITY: history file does not pre-exist');
    ok(!-d "$bpdir/reports/ledger-history", 'CASE3 FIXTURE-SANITY: reports/ledger-history/ does not exist yet');

    my $work = fresh_dir();
    my ($rc, $out, $err) = run_pl(['rotate', '--ledger', $path], cwd => $work);

    is($rc, 0, 'CASE3: a reducible rotate exits 0');
    ok((-s $path) <= 40000, 'CASE3: the ledger lands at/under budget after rotate');
    ok(-e $hist_path, 'CASE3: the history file was created at reports/ledger-history/<pkg>.md');
    my $hist_bytes = read_file($hist_path);
    ok(defined $hist_bytes && length($hist_bytes) > 0, 'CASE3: the history file received moved content');
    like($hist_bytes // '', qr/AAAA/, 'CASE3: the moved entry text is present in history');

    opendir(my $dh, $work) or die "opendir $work: $!";
    my @stray = grep { /^[A-Za-z]:$/ } readdir($dh);
    closedir($dh);
    is_deeply(\@stray, [], 'CASE3: no stray drive-letter directory was created relative to the isolated process cwd');
}

# =====================================================================================
# CASE4 (spec sec3 #4): a rotate that is irreducible -- the status is NOT an error, the notice
# carries the machine-readable token, and the diagnosis wording is preserved (done-criterion 4).
# "exits 0" and "diagnosis wording preserved" are EXPECTED TO ALREADY PASS at HEAD; the token/shape
# assertions are expected to FAIL.
# =====================================================================================
{
    my $bpdir = fresh_dir();
    my $path  = stage_ledger(ledger_bytes(entries => \@IRREDUCIBLE_ENTRIES), bpdir => $bpdir, pkg => 'case4-pkg');
    my $before_sz = -s $path;
    ok($before_sz > 40000, "CASE4 FIXTURE-SANITY: irreducible fixture is >40,000 bytes ($before_sz)");

    my $work = fresh_dir();
    my ($rc, $out, $err) = run_pl(['rotate', '--ledger', $path], cwd => $work);

    is($rc, 0, 'CASE4: an irreducible rotate is NOT an error -- exits 0 (as read by spec 1a; expected to already pass at HEAD)');
    ok(length($err) > 0, 'CASE4: a notice was emitted on stderr');
    unlike($err, qr/^bp-ledger: rotate: \Q$path\E: /,
        'CASE4: the notice does NOT reuse the `bp-ledger: <op>: <path>: <message>` error shape (spec 2.1)');
    like($err, qr/^bp-ledger: rotate: [A-Z][A-Z0-9_-]{2,}:/,
        'CASE4: the notice carries a stable, greppable machine-readable token right after the op prefix (spec 2.2)');
    like($err, qr/dropping mandated retention or losing the record/,
        'CASE4 (done-criterion 4): the diagnosis wording is preserved verbatim (expected to already pass at HEAD)');
    is((-s $path), $before_sz, 'CASE4: with nothing eligible to move, the ledger is left byte-unchanged');
}

# =====================================================================================
# CASE5 (spec sec3 #5): repeat-suppression -- two successive appends after an irreducible rotate
# emit the notice ONCE, not twice. Asserted across SEPARATE processes (each run_pl call is a fresh
# `bp-ledger.pl` invocation).
# =====================================================================================
{
    my $bpdir = fresh_dir();
    my $path  = stage_ledger(ledger_bytes(entries => \@IRREDUCIBLE_ENTRIES), bpdir => $bpdir, pkg => 'case5-pkg');

    my ($rrc) = run_pl(['rotate', '--ledger', $path]);
    is($rrc, 0, 'CASE5 setup: the irreducible rotate that (per spec 2.1) should establish the suppression marker exits 0');

    my $t1 = write_file("$ROOT/case5-text1.txt", 'first attempt after irreducible rotate');
    my ($rc1, $out1, $err1) = run_pl(['append-attempt', '--ledger', $path, '--text-file', $t1]);
    is($rc1, 0, 'CASE5: the first post-rotate append exits 0');
    ok(length($err1) > 0, 'CASE5 (1st of 2 separate processes): the FIRST append after an irreducible rotate emits the notice');
    ($IRREDUCIBLE_APPEND_TOKEN) = ($err1 =~ /^bp-ledger: append-attempt: ([A-Z][A-Z0-9_-]{2,}):/);

    my $t2 = write_file("$ROOT/case5-text2.txt", 'second attempt after irreducible rotate');
    my ($rc2, $out2, $err2) = run_pl(['append-attempt', '--ledger', $path, '--text-file', $t2]);
    is($rc2, 0, 'CASE5: the second post-rotate append exits 0');
    is($err2, '',
        'CASE5 (2nd of 2 SEPARATE processes): the SECOND append is silent -- suppression must survive across '
      . 'processes (a per-process flag is explicitly NOT acceptable, spec 2.1)');

    my $after = read_file($path);
    like($after, qr/first attempt after irreducible rotate/, 'CASE5: the first (notice-emitting) append text still landed');
    like($after, qr/second attempt after irreducible rotate/, 'CASE5: the second (silent) append text still landed -- silence is not a refusal');
}

# =====================================================================================
# CASE6 (spec sec3 #6): suppression is not stale -- once the ledger is back under budget, a
# further append is silent; if it goes over again, the notice returns (spec 2.1's own bullet:
# "stale suppression is a worse defect than the noise it replaces").
# =====================================================================================
{
    my $bpdir = fresh_dir();
    my $path  = stage_ledger(ledger_bytes(entries => \@IRREDUCIBLE_ENTRIES), bpdir => $bpdir, pkg => 'case6-pkg');

    my ($rrc) = run_pl(['rotate', '--ledger', $path]);
    is($rrc, 0, 'CASE6 setup: the irreducible rotate that establishes the marker exits 0');

    my $t1 = write_file("$ROOT/case6-text1.txt", 'first attempt, establishes suppression');
    run_pl(['append-attempt', '--ledger', $path, '--text-file', $t1]);   # consumes the one-time notice

    # "The ledger later drops under budget" (spec 2.1's own example of a change that must
    # un-suppress it): simulate an external trim overwriting the ledger with a small, in-budget
    # one under the same identity -- the spec leaves the actual mechanism open, so this is the
    # observable EFFECT of that bullet, not a guess at internals.
    write_file($path, ledger_bytes(entries => \@SMALL_ENTRIES, status => 'running'));
    ok((-s $path) <= 40000, 'CASE6 FIXTURE-SANITY: the ledger is genuinely back under budget after the external shrink');

    my $t2 = write_file("$ROOT/case6-text2.txt", 'attempt while genuinely under budget');
    my ($rc2, $out2, $err2) = run_pl(['append-attempt', '--ledger', $path, '--text-file', $t2]);
    is($rc2, 0, 'CASE6: append while under budget exits 0');
    is($err2, '', 'CASE6 (1st half): a further append is silent once the ledger is genuinely back under budget');

    # Push it back over budget with a single large append -- the notice must return, not stay
    # suppressed by whatever state survived from the earlier irreducible rotate.
    my $bigfile = write_file("$ROOT/case6-big.txt", 'Z' x 42000);
    my ($rc3, $out3, $err3) = run_pl(['append-attempt', '--ledger', $path, '--text-file', $bigfile]);
    is($rc3, 0, 'CASE6: the append that pushes the ledger back over budget still exits 0');
    ok(length($err3) > 0,
        'CASE6 (2nd half): once the ledger goes over budget again, the notice RETURNS -- stale suppression is '
      . 'a worse defect than the noise it replaces (spec 2.1)');
}

# =====================================================================================
# CASE7 (spec sec3 #7): ensure_dir_exists with a drive-absolute path creates the directory at the
# drive root, and creates NOTHING relative to the cwd. Regression test for a stray "./C:" tree
# actually produced (spec 1c).
# =====================================================================================
{
    my $bpdir = fresh_dir();
    my $path  = stage_ledger(ledger_bytes(entries => \@REDUCIBLE_ENTRIES), bpdir => $bpdir, pkg => 'case7-pkg');
    ok($path =~ m{^[A-Za-z]:[/\\]},
        "CASE7 FIXTURE-SANITY: the ledger path is drive-absolute ($path) -- the exact shape spec 1c reproduces against");
    my $hist_path = "$bpdir/reports/ledger-history/case7-pkg.md";
    ok(!-d "$bpdir/reports/ledger-history",
        'CASE7 FIXTURE-SANITY: reports/ledger-history/ does not exist yet -- ensure_dir_exists must create it from scratch');

    my $work = fresh_dir();
    my ($rc, $out, $err) = run_pl(['rotate', '--ledger', $path], cwd => $work);

    is($rc, 0, 'CASE7: rotate exits 0 -- the drive-absolute history directory was created at the correct location');
    ok(-d "$bpdir/reports/ledger-history", 'CASE7: the REAL reports/ledger-history/ directory now exists at the drive-absolute path');
    ok(-e $hist_path, 'CASE7: the history file itself exists at the correct drive-absolute path');

    opendir(my $dh, $work) or die "opendir $work: $!";
    my @entries = grep { !/^\.\.?$/ } readdir($dh);
    closedir($dh);
    my @stray = grep { /^[A-Za-z]:$/ } @entries;
    is_deeply(\@stray, [],
        'CASE7 (regression, spec 1c): NOTHING appears relative to the process cwd -- no stray "./C:" tree '
      . '(a real artifact reproduced against HEAD, not a hypothetical)');
    is(scalar(@entries), 0, 'CASE7: the isolated cwd is completely empty after rotate -- rotate wrote nothing relative to it at all');
}

# =====================================================================================
# CASE8 (spec sec3 #8): the one-line invariant -- a rotate that hits an I/O failure while
# irreducible emits exactly one stderr line (spec 1d / 2.5).
# =====================================================================================
{
    my $bpdir = fresh_dir();
    my $path  = stage_ledger(ledger_bytes(entries => \@OLI_ENTRIES), bpdir => $bpdir, pkg => 'case8-pkg');
    my $before_sz = -s $path;
    ok($before_sz > 40000, "CASE8 FIXTURE-SANITY: the fixture is over budget ($before_sz bytes) with entries both eligible to move AND irreducible overall");

    my $work = fresh_dir();
    my ($rc, $out, $err) = run_pl(['rotate', '--ledger', $path], cwd => $work, env => { BP_LEDGER_FAIL_RENAME => '1' });

    isnt($rc, 0, 'CASE8 FIXTURE-SANITY: the injected I/O failure is actually reached and reported as a non-zero exit');
    is($rc, 4, 'CASE8: the exit code is the fixed I/O-failure code 4 (exit-code vocabulary is unchanged -- spec is explicit this must not move)');
    my @lines = split /\n/, $err, -1;
    pop @lines if @lines && $lines[-1] eq '';
    is(scalar(@lines), 1,
        'CASE8: exactly ONE stderr line on a rotate that is both irreducible AND hits an I/O failure -- the '
      . 'documented invariant (bp-ledger.pl:20 "stderr on any non-zero exit is EXACTLY ONE line") holds')
        or diag("stderr was:\n$err");
}

# =====================================================================================
# CROSS-CASE (spec sec 2.2): the three outcomes in the table are distinguished by a token per
# outcome -- the reducible-append token (CASE2) and the irreducible-append token (CASE5's first
# call) must actually be DIFFERENT tokens, not the same notice reused for two different states.
# =====================================================================================
{
    my $tokens_differ = (defined $REDUCIBLE_APPEND_TOKEN && defined $IRREDUCIBLE_APPEND_TOKEN
                          && $REDUCIBLE_APPEND_TOKEN ne $IRREDUCIBLE_APPEND_TOKEN) ? 1 : 0;
    ok($tokens_differ,
        'CROSS-CASE (spec 2.2): the reducible-outcome and irreducible-outcome append notices carry DIFFERENT '
      . 'machine-readable tokens')
        or diag('reducible token: ' . (defined $REDUCIBLE_APPEND_TOKEN ? $REDUCIBLE_APPEND_TOKEN : '(none captured)')
              . '; irreducible-append token: ' . (defined $IRREDUCIBLE_APPEND_TOKEN ? $IRREDUCIBLE_APPEND_TOKEN : '(none captured)'));
}

done_testing();
