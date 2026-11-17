#!/usr/bin/env perl
# platform: any
# Oracle for plugins/butler/scripts/bp-model-check.pl, the AC-17
# cross-file model/effort set-agreement check, and the bp-auditor.md / hooks.json /
# .claude/settings.json documentation & registration assertions
# (04-model-effort-ledger-validation).
#
# Derived ONLY from
# .ccpraxis-local-data/blueprints/coordinator-context-discipline/specs/04-model-effort-ledger-validation-spec.md
# section 2.4/2.6/2.7/3 (B-41..B-53, AC-17..AC-22). WRITTEN BLIND TO ANY IMPLEMENTATION:
# bp-model-check.pl does not exist at authoring time, so every CLI/module-surface assertion below
# is expected to fail on MISSING BEHAVIOUR, never on a bug in this file. The set-agreement check
# (AC-17) is written to PARSE the three sources rather than hardcode the expected sets a second
# time -- per the ledger's own explicit instruction to the test-writer -- so it too fails honestly
# (a missing @BpModelCheck::MODELS/@EFFORTS parses as undef/empty, which correctly disagrees with
# bp-ledger.pl's real @MODELS/@EFFORTS).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use JSON::PP;
use POSIX qw(WIFEXITED WEXITSTATUS);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $TESTS    = fwd("$Bin");
my $BUTLER   = fwd(abs_path("$Bin/../..")       // "$Bin/../..");
my $PROJ     = fwd(abs_path("$Bin/../../../..") // "$Bin/../../../..");
my $SCRIPT   = "$BUTLER/scripts/bp-model-check.pl";
my $LEDGERPL = "$BUTLER/scripts/bp-ledger.pl";
my $LAUNCHSH = "$BUTLER/scripts/bp-launch.sh";
my $AUDITOR  = "$PROJ/plugins/blueprint/agents/bp-auditor.md";
my $HOOKSJ   = "$BUTLER/hooks/hooks.json";
my $SETTINGSJ = "$PROJ/.claude/settings.json";
my $GUARD    = "$BUTLER/hooks/guard-blueprint-write.sh";

diag("subject under test: $SCRIPT " . (-e $SCRIPT ? "(present)" : "(ABSENT -- CLI/module-surface assertions below are expected to fail on a MISSING FILE)"));

my $J = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

my $PERL_ABS = do {
    local $ENV{PATH} = $CLEAN_ENV{PATH};
    chomp(my $p = `command -v perl 2>/dev/null`);
    ($p && -x $p) ? $p : 'perl';
};

sub write_file {
    my ($path, $bytes) = @_;
    (my $dir = $path) =~ s{[/\\][^/\\]*\z}{};
    if (length($dir) && !-d $dir) {
        my @parts = split m{/}, $dir;
        my $acc = '';
        for my $p (@parts) {
            $acc = length($acc) ? "$acc/$p" : $p;
            mkdir $acc unless -d $acc;
        }
    }
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
    my $c = do { local $/; <$r> };
    close $r;
    return defined $c ? $c : '';
}

my $pn = 0;
sub run_exec {
    my ($abs, $argv, %env) = @_;
    my $n = ++$pn;
    my $outf = write_file("$ROOT/out.$n", '');
    my $errf = write_file("$ROOT/err.$n", '');
    local %ENV = (%CLEAN_ENV, %env);
    my $exit = -1;
    eval {
        local $SIG{ALRM} = sub { die "alarm\n" };
        alarm 30;
        open(local *CHOUT, '>', $outf) or die "open $outf: $!";
        open(local *CHERR, '>', $errf) or die "open $errf: $!";
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            open(STDIN, '<', '/dev/null');
            open(STDOUT, '>&', \*CHOUT) or exit 126;
            open(STDERR, '>&', \*CHERR) or exit 126;
            exec($abs, @$argv) or exit 127;
        }
        waitpid($pid, 0);
        $exit = ($? == -1) ? -1 : WIFEXITED($?) ? WEXITSTATUS($?) : -1;
        alarm 0;
        1;
    } or do { alarm 0; $exit = -1; };
    return ($exit, read_file($outf) // '', read_file($errf) // '');
}

sub run_check { my (@args) = @_; return run_exec($PERL_ABS, [$SCRIPT, @args]); }

# =====================================================================================
# AC-17 (D-B, B-49): the model/effort sets agree across sources, by PARSING them -- never
# by re-hardcoding the expected sets here.
# =====================================================================================
sub parse_qw_after {
    my ($text, $marker_re) = @_;
    return undef unless defined $text;
    my ($list) = $text =~ /$marker_re\s*=\s*qw\(([^)]*)\)/s;
    return undef unless defined $list;
    return [ grep { length } split /\s+/, $list ];
}

my $ledger_src = read_file($LEDGERPL);
my $check_src  = read_file($SCRIPT);
my $launch_src = read_file($LAUNCHSH);

my $ledger_models  = parse_qw_after($ledger_src, qr/\@MODELS/);
my $ledger_efforts = parse_qw_after($ledger_src, qr/\@EFFORTS/);
my $check_models   = parse_qw_after($check_src,  qr/\@MODELS/);
my $check_efforts  = parse_qw_after($check_src,  qr/\@EFFORTS/);

ok(defined $ledger_models && @$ledger_models,
   "AC-17: bp-ledger.pl declares a non-empty \@MODELS (found via parse, not hardcoded)");
ok(defined $ledger_efforts && @$ledger_efforts,
   "AC-17: bp-ledger.pl declares a non-empty \@EFFORTS");

is_deeply([ sort @{ $check_models  // [] } ], [ sort @{ $ledger_models  // [] } ],
   "AC-17/B-49: bp-model-check.pl's \@MODELS agrees with bp-ledger.pl's \@MODELS");
is_deeply([ sort @{ $check_efforts // [] } ], [ sort @{ $ledger_efforts // [] } ],
   "AC-17/B-49: bp-model-check.pl's \@EFFORTS agrees with bp-ledger.pl's \@EFFORTS");

# bp-launch.sh:71's case arm -- efforts only (D-A: effort has a real upstream anchor there;
# model does not, per spec §5.1 limitation 4).
my ($launch_arm) = defined $launch_src
    ? ($launch_src =~ /case\s+"\$EFFORT"\s+in\s*\n\s*([a-z|]+)\)/s)
    : ();
my $launch_efforts = defined $launch_arm ? [ split /\|/, $launch_arm ] : undef;
ok(defined $launch_efforts && @$launch_efforts,
   "AC-17: bp-launch.sh's effort case arm is present and parses");
is_deeply([ sort @{ $launch_efforts // [] } ], [ sort @{ $ledger_efforts // [] } ],
   "AC-17: bp-launch.sh's effort case arm agrees with bp-ledger.pl's \@EFFORTS");
is_deeply([ sort @{ $launch_efforts // [] } ], [ sort @{ $check_efforts  // [] } ],
   "AC-17: bp-launch.sh's effort case arm agrees with bp-model-check.pl's \@EFFORTS");

# =====================================================================================
# B-49: require-ing the script does not execute the CLI, and exposes the two arrays.
# =====================================================================================
{
    my $driver = "$ROOT/require-driver.pl";
    write_file($driver, <<'PERL');
my $target = $ENV{BWA_TARGET};
require $target;
print "MODELS=" . join(',', @BpModelCheck::MODELS) . "\n";
print "EFFORTS=" . join(',', @BpModelCheck::EFFORTS) . "\n";
print "OK\n";
PERL
    my ($rc, $out, $err) = run_exec($PERL_ABS, [$driver], BWA_TARGET => fwd($SCRIPT));
    is($rc, 0, "B-49: require-ing bp-model-check.pl from another perl process exits 0 (no CLI ran)");
    like($out, qr/^OK$/m, "B-49: the driver reached its own end (require did not exit/die/run a CLI)");
    like($out, qr/^MODELS=\S+/m, "B-49: \@BpModelCheck::MODELS is exposed and non-empty after require");
    like($out, qr/^EFFORTS=\S+/m, "B-49: \@BpModelCheck::EFFORTS is exposed and non-empty after require");
}

# =====================================================================================
# Fixtures for bp-model-check.pl audit (AC-18, AC-19).
# =====================================================================================
sub write_ledger {
    my ($pkgdir, $pkg, %fm) = @_;
    my @lines = ('---');
    for my $k (qw(package blueprint status model effort write_set last_updated)) {
        next unless exists $fm{$k};
        push @lines, "$k: $fm{$k}";
    }
    push @lines, '---', "# Package $pkg", '', '## Next action', '', '## Escalation', '';
    write_file("$pkgdir/$pkg.md", join("\n", @lines));
}

sub fresh_bp {
    my $dir = tempdir(DIR => $ROOT, CLEANUP => 1);
    my $bp = fwd("$dir/blueprint.md");
    write_file($bp, "# Blueprint: fixture-bp\n");
    my $pkgdir = "$dir/packages";
    mkdir $pkgdir;
    return (fwd($bp), fwd($pkgdir));
}

# =====================================================================================
# AC-18 (B-41, B-42, B-43): clean dir exits 0 with a summary; a bad model/effort exits 1
# naming package/field/value/accepted-set.
# =====================================================================================
{
    my ($bp, $pkgdir) = fresh_bp();
    write_ledger($pkgdir, '01-a', package => '01-a', blueprint => 'fixture-bp',
                 status => 'pending', model => 'sonnet', effort => 'medium',
                 write_set => 'x.pl', last_updated => '2026-01-01T00:00:00Z');
    write_ledger($pkgdir, '02-b', package => '02-b', blueprint => 'fixture-bp',
                 status => 'pending', model => 'opus', effort => 'high',
                 write_set => 'y.pl', last_updated => '2026-01-01T00:00:00Z');
    my ($rc, $out, $err) = run_check('audit', '--blueprint', $bp);
    is($rc, 0, "AC-18/B-41: audit on an all-clean packages dir exits 0");
    like($out, qr/^bp-model-check:/, "AC-18/B-41: stdout begins with 'bp-model-check:'");
    is($err, '', "AC-18/B-41: stderr empty on a clean audit");
}
{
    my ($bp, $pkgdir) = fresh_bp();
    write_ledger($pkgdir, '01-badmodel', package => '01-badmodel', blueprint => 'fixture-bp',
                 status => 'pending', model => 'fable', effort => 'medium',
                 write_set => 'x.pl', last_updated => '2026-01-01T00:00:00Z');
    my ($rc, $out, $err) = run_check('audit', '--blueprint', $bp);
    is($rc, 1, "AC-18/B-42: a bad model exits 1");
    is($out, '', "AC-18/B-42: stdout empty on a flagged audit");
    like($err, qr/01-badmodel/, "AC-18/B-42: stderr names the package");
    like($err, qr/\bmodel\b/, "AC-18/B-42: stderr names the field 'model'");
    like($err, qr/\bfable\b/, "AC-18/B-42: stderr names the bad value 'fable'");
    like($err, qr/sonnet.*opus.*haiku|sonnet, opus, haiku/, "AC-18/B-42: stderr names the accepted model set");
}
{
    my ($bp, $pkgdir) = fresh_bp();
    write_ledger($pkgdir, '01-badeffort', package => '01-badeffort', blueprint => 'fixture-bp',
                 status => 'pending', model => 'sonnet', effort => 'turbo',
                 write_set => 'x.pl', last_updated => '2026-01-01T00:00:00Z');
    my ($rc, $out, $err) = run_check('audit', '--blueprint', $bp);
    is($rc, 1, "AC-18/B-43: a bad effort exits 1");
    like($err, qr/01-badeffort/, "AC-18/B-43: stderr names the package");
    like($err, qr/\beffort\b/, "AC-18/B-43: stderr names the field 'effort'");
    like($err, qr/\bturbo\b/, "AC-18/B-43: stderr names the bad value 'turbo'");
    like($err, qr/low, medium, high, xhigh, max/, "AC-18/B-43: stderr names the accepted effort set");
}

# =====================================================================================
# AC-19 (B-44, B-45, B-46, B-47, B-48): absence is not flagged; skips are not fatal;
# usage/IO errors exit 2.
# =====================================================================================
{
    my ($bp, $pkgdir) = fresh_bp();
    write_ledger($pkgdir, '01-noneither', package => '01-noneither', blueprint => 'fixture-bp',
                 status => 'pending', write_set => 'x.pl', last_updated => '2026-01-01T00:00:00Z');
    my ($rc) = run_check('audit', '--blueprint', $bp);
    is($rc, 0, "AC-19/B-44: a ledger with neither model: nor effort: is clean, exit 0 as the only ledger");
}
{
    my ($bp, $pkgdir) = fresh_bp();
    write_ledger($pkgdir, '01-emptymodel', package => '01-emptymodel', blueprint => 'fixture-bp',
                 status => 'pending', model => '', effort => 'medium',
                 write_set => 'x.pl', last_updated => '2026-01-01T00:00:00Z');
    my ($rc) = run_check('audit', '--blueprint', $bp);
    is($rc, 0, "AC-19/B-45: an empty model: value is not reported");
}
{
    my ($bp, $pkgdir) = fresh_bp();
    write_file("$pkgdir/01-bodyonly.md", join("\n",
        '---', 'package: 01-bodyonly', 'blueprint: fixture-bp', 'status: pending',
        'write_set: x.pl', 'last_updated: 2026-01-01T00:00:00Z', '---',
        '# Package 01-bodyonly', '', 'model: fable  <- this is BODY prose, not frontmatter', ''));
    my ($rc) = run_check('audit', '--blueprint', $bp);
    is($rc, 0, "AC-19/B-46: a 'model:' line only in the BODY is not read; audit stays clean");
}
{
    my ($bp, $pkgdir) = fresh_bp();
    write_ledger($pkgdir, '01-a', package => '01-a', blueprint => 'fixture-bp',
                 status => 'pending', model => 'sonnet', effort => 'medium',
                 write_set => 'x.pl', last_updated => '2026-01-01T00:00:00Z');
    write_file("$pkgdir/notes.txt", "model: fable\neffort: turbo\n");     # non-.md: must be skipped
    my ($rc) = run_check('audit', '--blueprint', $bp);
    is($rc, 0, "AC-19/B-48: a non-.md file in the packages dir is skipped, not fatal");
}
{
    # Missing --blueprint.
    my ($rc, $out, $err) = run_check('audit');
    is($rc, 2, "AC-19/B-47: a missing --blueprint exits 2");
    is($out, '', "AC-19/B-47: stdout empty on usage error");
}
{
    # Unknown argument.
    my ($bp, undef) = fresh_bp();
    my ($rc) = run_check('audit', '--blueprint', $bp, '--bogus-flag', 'x');
    is($rc, 2, "AC-19/B-47: an unrecognised argument exits 2");
}
{
    # Unreadable blueprint file.
    my ($rc) = run_check('audit', '--blueprint', "$ROOT/no-such-blueprint.md");
    is($rc, 2, "AC-19/B-47: an unreadable --blueprint file exits 2");
}
{
    # Missing packages dir.
    my $dir = tempdir(DIR => $ROOT, CLEANUP => 1);
    my $bp = fwd("$dir/blueprint.md");
    write_file($bp, "# Blueprint: fixture-bp\n");
    my ($rc) = run_check('audit', '--blueprint', $bp);
    is($rc, 2, "AC-19/B-47: a missing packages dir exits 2");
}

# =====================================================================================
# AC-20 (B-50): bp-auditor.md carries the new hunt-list item with its required literals,
# and the existing bp-checks.pl audit item is byte-unchanged.
# =====================================================================================
{
    my $text = read_file($AUDITOR);
    ok(defined $text, "AC-20: bp-auditor.md is readable");
  SKIP: {
        skip('AC-20: bp-auditor.md unreadable', 4) unless defined $text;
        like($text, qr/\Qbp-model-check.pl audit --blueprint\E/,
             "AC-20/B-50: bp-auditor.md contains the literal 'bp-model-check.pl audit --blueprint'");
        like($text, qr/REQUIRED pass/, "AC-20/B-50: ...and the literal 'REQUIRED pass' within the new item");
        like($text, qr/Output NOT supplied/, "AC-20/B-50: ...and the literal 'Output NOT supplied'");

        # The EXISTING bp-checks.pl audit item, pinned verbatim (read from disk at authoring
        # time, 2026-09-23) -- must survive this package's addition byte-for-byte. Its
        # command line has since moved off the cwd-relative `plugins/butler/scripts/`
        # (which resolves only inside a ccpraxis checkout) onto the sibling-plugin path
        # (blueprint-skill-script-paths.t); everything else is the original text.
        my $existing_item = <<'ITEM';
- **Write-set-implied checks** — REQUIRED pass. **You cannot run it, and you must not pretend to.**

  ```
  perl "${CLAUDE_PLUGIN_ROOT}"/../butler/scripts/bp-checks.pl audit --blueprint <blueprint.md>
  ```

  **This instruction used to read "run it, do not eyeball it", and you have no Bash tool** — your `tools:` line is `Read, Grep, Glob, Write`, deliberately, because your containment to the blueprint files is the instrument. So the instruction was unfollowable as written, and audit-07 of `butler-gate-ergonomics` found it had been hand-derived for **seven consecutive rounds**, each one reporting a result nobody executed.

  The check stays REQUIRED; what changed is who runs it. **The dispatcher runs it and gives you the output.** Your job is to use it and to refuse to proceed without it:

  - Output supplied → treat it as authoritative and report each omission as a finding naming the package and the check.
  - **Output NOT supplied → that is itself a FINDING**, and a blocking one. Say plainly that the required check was not run and that your verdict cannot cover it. Do not hand-derive it from the ledgers and present the result as if it were the command's; a derived answer and an executed one are not the same claim, and the whole point of this check is that it is mechanical.

  Exit 1 means some package omits a check its own write set implies. Exit 0 with *"no checks-table"* is **not** a failure — the table is project-supplied by design (this toolchain is stack-agnostic; its own blueprints are pure Perl and declare none), and a blueprint without one implies nothing.

  The same rule covers anything else you are asked to execute: **an agent asked to run what it cannot run should report the gap, never simulate the result.**

  This moves detection from execution time to **authoring time**, which is where it is cheap. The failure it prevents is a defect that sits latent until the closing gate and surfaces as an ownerless mystery on whichever package happens to run last — long after the package that caused it closed. Attribution for one such lint error needed a `git log -S`.
ITEM
        $existing_item =~ s/\s+\z//;
        (my $norm_text = $text) =~ s/\r\n/\n/g;
        (my $norm_item = $existing_item) =~ s/\r\n/\n/g;
        ok(index($norm_text, $norm_item) >= 0,
           "AC-20/B-50: the existing 'Write-set-implied checks' item is byte-for-byte unchanged");
    }
}

# =====================================================================================
# AC-21 (B-51, B-52, B-53): hooks.json registers the guard; no pre-existing block's
# hooks array changes; .claude/settings.json is unchanged and does not name the guard.
# =====================================================================================
{
    my $raw = read_file($HOOKSJ);
    my $decoded = eval { $J->decode($raw) };
    ok(ref $decoded eq 'HASH', "AC-21/B-51: hooks.json parses as JSON");
    my @pretooluse = ref $decoded eq 'HASH' && ref $decoded->{hooks} eq 'HASH'
                     && ref $decoded->{hooks}{PreToolUse} eq 'ARRAY'
                   ? @{ $decoded->{hooks}{PreToolUse} } : ();

    # Retargeted per package 16's batch B (Decision 34): the old ledger-create guard
    # is on the deletion list, merged into guard-blueprint-write.sh (package
    # 02's design doc, "Inventory"). B-51's live successor is
    # guard-blueprint-write.sh's own registration in the same block.
    my ($ledger_create_block) = grep {
        ref $_ eq 'HASH' && ($_->{matcher} // '') eq 'Edit|Write|MultiEdit|NotebookEdit'
        && ref $_->{hooks} eq 'ARRAY'
        && grep { ref $_ eq 'HASH' && defined $_->{command} && $_->{command} =~ /guard-blueprint-write\.sh/ }
           @{ $_->{hooks} }
    } @pretooluse;
    ok(defined $ledger_create_block,
       "AC-21/B-51: hooks.json has a PreToolUse block, matcher Edit|Write|MultiEdit|NotebookEdit, "
     . "whose hooks array names guard-blueprint-write.sh (successor to the old ledger-create guard)");

    # B-52: no PRE-EXISTING guard-writes.sh/ledger-guard.sh block gained the
    # ledger-creation guard's command (it landed in guard-blueprint-write.sh
    # instead, package 13's own merge, not spliced into the writes/ledger
    # block).
    for my $block (@pretooluse) {
        next unless ref $block eq 'HASH' && ref $block->{hooks} eq 'ARRAY';
        my @cmds = map { $_->{command} // '' } grep { ref $_ eq 'HASH' } @{ $block->{hooks} };
        next unless grep { /guard-writes\.sh|ledger-guard\.sh/ } @cmds;
        ok(!(grep { /guard-ledger-create/ } @cmds),
           "AC-21/B-52: the guard-writes.sh/ledger-guard.sh block's hooks array does NOT gain the old ledger-create guard");
    }
}
{
    my $raw = read_file($SETTINGSJ);
    my $decoded = eval { $J->decode($raw) };
    ok(ref $decoded eq 'HASH', "AC-21/B-53: .claude/settings.json parses as JSON");
    my @pretooluse = ref $decoded eq 'HASH' && ref $decoded->{hooks} eq 'HASH'
                     && ref $decoded->{hooks}{PreToolUse} eq 'ARRAY'
                   ? @{ $decoded->{hooks}{PreToolUse} } : ();
    ok((grep {
            ref $_ eq 'HASH' && ($_->{matcher} // '') eq 'Bash'
            && ref $_->{hooks} eq 'ARRAY'
            && grep { ref $_ eq 'HASH' && ($_->{command} // '') =~ /guard-git-mutations\.sh/ } @{ $_->{hooks} }
        } @pretooluse),
       "AC-21/B-53: .claude/settings.json still contains the pre-existing guard-git-mutations.sh/Bash block");
    my @all_cmds = map { ref $_ eq 'HASH' && ref $_->{hooks} eq 'ARRAY'
                          ? map { $_->{command} // '' } grep { ref $_ eq 'HASH' } @{ $_->{hooks} } : () }
                   @pretooluse;
    ok(!(grep { /guard-ledger-create/ } @all_cmds),
       "AC-21/B-53: .claude/settings.json does NOT name the old ledger-create guard");
}

# =====================================================================================
# AC-22 (partial): syntax sanity, cheap enough to assert here even though the full
# validation-suite criterion belongs to the package's `checks:` pipeline, not this file.
# =====================================================================================
SKIP: {
    skip('AC-22: bp-model-check.pl not present yet', 1) unless -e $SCRIPT;
    my ($rc, $out, $err) = run_exec($PERL_ABS, ['-c', $SCRIPT]);
    is($rc, 0, "AC-22: perl -c bp-model-check.pl is syntax-clean");
}
SKIP: {
    skip('AC-22: guard-blueprint-write.sh not present yet', 1) unless -e $GUARD;
    my $BASH_ABS = do {
        local $ENV{PATH} = $CLEAN_ENV{PATH};
        chomp(my $p = `command -v bash 2>/dev/null`);
        ($p && -x $p) ? $p : 'bash';
    };
    my ($rc, $out, $err) = run_exec($BASH_ABS, ['-n', $GUARD]);
    is($rc, 0, "AC-22: bash -n guard-blueprint-write.sh is syntax-clean");
}

done_testing();
