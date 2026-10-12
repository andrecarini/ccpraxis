#!/usr/bin/env perl
# platform: any
# ORACLE for hook-continuity-remake package 09's A14 lazy-absorption shim
# (Almanac::LegacyQueue, new module): L1-L14 of
# .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 09-question-queue-spec.md sections 2.1, 2.2 and 4.1. Derived only from that
# spec text plus the already-implemented almanac-records package 08 store
# (Almanac::Store, Almanac::Record, Almanac::Lock, almanac-inbox.pl), which
# the spec names explicitly as the shared machinery this shim sits on top of.
# NOT derived from reading the shim itself, which this package's write set
# has not written yet -- LQ_absorb()/LQ_legacy_path() below turn a missing
# module or sub into a legible, non-crashing failure rather than letting this
# whole file die, exactly like the almanac-decision-crud.t OC()-style seam.
#
# Runs standalone: perl this file
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use Cwd ();
use Encode ();
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep);

# ---------------------------------------------------------------------------
# no real user state: every in-process call below passes an explicit root
# (a fresh tempdir), and the handful of child perl processes this file spawns
# (L7's barrier scenario) are handed that same explicit root on argv, never
# relying on a cwd walk -- but they are chdir'd into it anyway, defensively,
# since a store call with no explicit root falls back to walking from cwd.
# ---------------------------------------------------------------------------
my $FILE_HOME = tempdir(CLEANUP => 1);
$FILE_HOME =~ s{\\}{/}g;
local $ENV{HOME}         = $FILE_HOME;
local $ENV{USERPROFILE}  = $FILE_HOME;
local $ENV{ALMANAC_HOME} = $FILE_HOME;
delete local $ENV{CLAUDE_PROJECT_DIR};
delete local $ENV{CCPRAXIS_DATA_DIR};
delete local $ENV{BP_PROJECT_ROOT};
delete local $ENV{BP_LEDGER};

(my $ALM_DIR = "$Bin/../../scripts") =~ s{\\}{/}g;
my $INBOX_PL = "$ALM_DIR/almanac-inbox.pl";
my $LEGACYQ_PM  = "$ALM_DIR/Almanac/LegacyQueue.pm";

ok(-f $INBOX_PL, 'precondition: almanac-inbox.pl exists (almanac-records package 08, already implemented)')
    or diag('almanac-inbox.pl is missing -- everything below that goes through it will fail for that reason');

{
    local $@;
    do $INBOX_PL if -f $INBOX_PL;
    diag("almanac-inbox.pl failed to load: $@") if $@;
}

# Almanac::Store is shared infra from package 08, named explicitly by this
# package's spec (section 2.7: "Store.pm needs no code change") -- require it
# directly (adding $ALM_DIR to @INC, the same directory almanac-inbox.pl's
# own BEGIN block would unshift) rather than relying on that file's `do` to
# pull it in as a side effect, since it does not exist yet and must not
# crash the whole run when it is missing (house pattern: per-assertion
# failure, never a file-level die).
unshift @INC, $ALM_DIR;
eval { require Almanac::Store };
diag("Almanac::Store failed to load: $@") if $@;

ok(-f $LEGACYQ_PM, 'precondition (expected to fail until this package writes it): Almanac/LegacyQueue.pm exists on disk')
    or diag("missing: $LEGACYQ_PM -- every LQ_absorb()/LQ_legacy_path() call below will report a legible "
          . 'module_missing failure rather than crashing this file');

my $LQ_LOADED;
sub lq_require {
    return $LQ_LOADED if defined $LQ_LOADED;
    local $@;
    $LQ_LOADED = eval { require $LEGACYQ_PM; 1 } ? 1 : 0;
    return $LQ_LOADED;
}

# LQ_absorb($store, %opt) -> \%report, NEVER dies or crashes this file even
# when the module or the sub is missing.
sub lq_absorb {
    my ($store, %opt) = @_;
    return { state => 'failed', reason => 'module_missing' } unless lq_require();
    my $rep = eval { Almanac::LegacyQueue::absorb($store, %opt) };
    return (ref $rep eq 'HASH') ? $rep
         : { state => 'failed', reason => 'died', message => (defined $@ ? "$@" : 'unknown') };
}

sub lq_legacy_path {
    my ($store) = @_;
    return undef unless lq_require();
    return eval { Almanac::LegacyQueue::legacy_path($store) };
}

# ---------------------------------------------------------------------------
# scaffolding
# ---------------------------------------------------------------------------
sub slurp_raw {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub write_raw {
    my ($p, $bytes) = @_;
    open my $fh, '>:raw', $p or die "fixture: cannot write $p: $!";
    print {$fh} $bytes;
    close $fh;
}

# norm_root($p) -- canonicalises an EXISTING directory the same way Store's
# own _canonical_path does (Cwd::abs_path, forward slashes, uppercase drive
# letter), matching almanac-store-crud.t's own norm_path() -- so a root built
# from File::Temp::tempdir (which this host hands back in a POSIX-mount
# spelling, e.g. /tmp/xxx) compares equal to the C:/... form Store itself
# produces, rather than merely folding backslashes.
sub norm_root {
    my ($p) = @_;
    my $abs = Cwd::abs_path($p);
    $abs = $p unless defined $abs;
    $abs =~ s{\\}{/}g;
    $abs =~ s{/\z}{};
    $abs =~ s{^([a-zA-Z]):}{uc($1) . ':'}e;
    return $abs;
}

# fold_path($p) -- the same slash/case folding as norm_root(), WITHOUT
# Cwd::abs_path, for paths that may not exist on disk (e.g. a legacy_path()
# result after its file has been renamed away) and so cannot be abs_path'd.
sub fold_path {
    my ($p) = @_;
    return '' unless defined $p;
    (my $f = $p) =~ s{\\}{/}g;
    $f =~ s{/\z}{};
    $f =~ s{^([a-zA-Z]):}{uc($1) . ':'}e;
    return $f;
}

sub legacy_path_for {
    my ($root) = @_;
    return norm_root($root) . '/.ccpraxis-local-data/.subagent-guard/questions.md';
}

sub inbox_dir_for {
    return norm_root($_[0]) . '/.ccpraxis-local-data/almanac/inbox';
}

sub open_store {
    my ($root) = @_;
    return Almanac::Store->open(scope => 'project', type => 'inbox', root => $root);
}

sub mk_root {
    my $t = tempdir(CLEANUP => 1);
    return norm_root($t);
}

sub read_all_lines {
    my ($path) = @_;
    open(my $fh, '<', $path) or return ();
    my @l = <$fh>;
    close $fh;
    return @l;
}

# ---------------------------------------------------------------------------
# Isolation guard (house convention): snapshot the REAL repo store before
# anything runs, compared again at L14.
# ---------------------------------------------------------------------------
(my $REPO_ROOT = "$Bin/../../../..") =~ s{\\}{/}g;
sub snapshot_dir {
    my ($dir) = @_;
    my %seen;
    return { exists => 0, entries => \%seen } unless -d $dir;
    my @stack = ($dir);
    while (my $d = pop @stack) {
        opendir(my $dh, $d) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $full = "$d/$e";
            if (-d $full) { push @stack, $full; next }
            my @st = stat $full;
            (my $rel = $full) =~ s{\\}{/}g;
            $seen{$rel} = ($st[9] // 0) . ':' . ($st[7] // 0);
        }
        closedir $dh;
    }
    return { exists => 1, entries => \%seen };
}
sub real_snapshot {
    return {
        guard    => snapshot_dir("$REPO_ROOT/.ccpraxis-local-data/.subagent-guard"),
        decision => snapshot_dir("$REPO_ROOT/.ccpraxis-local-data/almanac/inbox"),
    };
}
my $REAL_BEFORE = real_snapshot();

# =============================================================================
# L1/L2 -- a seeded legacy file with a stamped line, an unstamped line, a
# UTF-8 non-ASCII line, a blank line and a non-"- " line: absorbed into
# exactly 3 unanswered decisions, and the legacy file renamed byte-identical.
# =============================================================================
my ($P1, $ACCENTED_TITLE, $SEED_BYTES);
{
    $P1 = mk_root();
    make_path("$P1/.ccpraxis-local-data/.subagent-guard");
    $ACCENTED_TITLE = "caf\x{e9} decis\x{e3}o?";
    my $accented_bytes = Encode::encode('UTF-8', $ACCENTED_TITLE);
    my @seed = (
        '- [2020-01-01T00:00:00Z] Stamped question?',
        '- Unstamped question?',
        '- ' . $accented_bytes,
        '',
        'just some other line, never a question',
    );
    $SEED_BYTES = join("\n", @seed) . "\n";
    write_raw(legacy_path_for($P1), $SEED_BYTES);

    my $list = eval { Almanac::Inbox::list_items(root => $P1) };
    ok(!$@, 'L1 fixture: list_items(root => P) does not die') or diag("error: $@");
    my @recs = (ref $list eq 'ARRAY') ? @$list : ();
    is(scalar(@recs), 3, 'L1: a seeded 5-line legacy file (1 stamped, 1 unstamped, 1 non-ASCII, '
                        . '1 blank, 1 non-question) absorbs into exactly 3 unanswered decisions');
    ok(!(grep { $_->{fields}{status} ne 'unanswered' } @recs), 'L1: all 3 are unanswered')
        if @recs == 3;

    my ($stamped) = grep { defined $_->{fields}{title} && $_->{fields}{title} eq 'Stamped question?' } @recs;
    my ($unstamped) = grep { defined $_->{fields}{title} && $_->{fields}{title} eq 'Unstamped question?' } @recs;
    my ($accented) = grep { defined $_->{fields}{title} && $_->{fields}{title} eq $ACCENTED_TITLE } @recs;
    ok(defined $stamped, 'L1: the stamped title is present');
    ok(defined $unstamped, 'L1: the unstamped title is present');
    ok(defined $accented, 'L1: the non-ASCII title round-trips character-for-character');
    is($stamped->{fields}{created}, '2020-01-01T00:00:00Z', 'L1: the stamped line\'s created equals its stamp')
        if defined $stamped;
    like($unstamped->{fields}{created} // '', qr/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/,
         'L1: the unstamped line\'s created is a fresh ISO stamp') if defined $unstamped;

    ok(!-e legacy_path_for($P1), 'L2: questions.md is gone after absorption');
    my $migrated = slurp_raw("$P1/.ccpraxis-local-data/.subagent-guard/questions.md.migrated");
    is($migrated, $SEED_BYTES, 'L2: questions.md.migrated is byte-identical to the seed (renamed, not rewritten)');
}

# =============================================================================
# L3 -- a re-open: ids/revs unchanged, .migrated unchanged, no .migrated.2,
# and absorb() itself now reports 'absent' (the legacy file it would touch is
# already gone).
# =============================================================================
{
    my $before = eval { Almanac::Inbox::list_items(root => $P1) };
    my %before_rev = map { $_->{id} => $_->{rev} } (ref $before eq 'ARRAY' ? @$before : ());
    my $migrated_before = slurp_raw("$P1/.ccpraxis-local-data/.subagent-guard/questions.md.migrated");

    my $after = eval { Almanac::Inbox::list_items(root => $P1) };
    my %after_rev = map { $_->{id} => $_->{rev} } (ref $after eq 'ARRAY' ? @$after : ());
    is_deeply(\%after_rev, \%before_rev, 'L3: a re-open leaves every id\'s rev unchanged');

    my $migrated_after = slurp_raw("$P1/.ccpraxis-local-data/.subagent-guard/questions.md.migrated");
    is($migrated_after, $migrated_before, 'L3: .migrated is unchanged by the re-open');
    ok(!-e "$P1/.ccpraxis-local-data/.subagent-guard/questions.md.migrated.2", 'L3: no .migrated.2 was created');

    my $store3 = open_store($P1);
    my $report3 = lq_absorb($store3);
    is($report3->{state}, 'absent', 'L3: absorb() itself now reports state absent (the file it renamed is gone)');
}

# =============================================================================
# L4 -- a re-created legacy file with 1 brand-new line and 1 line identical
# to an earlier one: the new one files, the identical one does not (already
# == 1), the file becomes .migrated.2, and .migrated stays untouched.
# =============================================================================
{
    my $migrated_before = slurp_raw("$P1/.ccpraxis-local-data/.subagent-guard/questions.md.migrated");
    my $new_seed = "- Unstamped question?\n- Brand new re-created line?\n";
    write_raw(legacy_path_for($P1), $new_seed);

    my $store4 = open_store($P1);
    my $report4 = lq_absorb($store4);
    is($report4->{state}, 'absorbed', 'L4: re-opening a re-created file absorbs again');
    is($report4->{already}, 1, 'L4: the one identical line is not re-filed (already == 1)');

    my $list = eval { Almanac::Inbox::list_items(root => $P1) };
    my @recs = (ref $list eq 'ARRAY') ? @$list : ();
    is(scalar(@recs), 4, 'L4: the total is now 4 (3 original + 1 genuinely new)');
    ok((grep { defined $_->{fields}{title} && $_->{fields}{title} eq 'Brand new re-created line?' } @recs),
       'L4: the new line was filed');

    ok(!-e legacy_path_for($P1), 'L4: questions.md is gone again');
    ok(-f "$P1/.ccpraxis-local-data/.subagent-guard/questions.md.migrated.2", 'L4: questions.md.migrated.2 exists');
    is(slurp_raw("$P1/.ccpraxis-local-data/.subagent-guard/questions.md.migrated"), $migrated_before,
       'L4: the ORIGINAL .migrated is untouched');
    is(slurp_raw("$P1/.ccpraxis-local-data/.subagent-guard/questions.md.migrated.2"), $new_seed,
       'L4: .migrated.2 is byte-identical to the re-created seed');
}

# =============================================================================
# L5 -- no .subagent-guard/ directory at all (the operator cleared it by
# hand): open succeeds, the list is empty, the directory stays absent, and
# absorb() reports absent.
# =============================================================================
{
    my $P5 = mk_root();
    my $list = eval { Almanac::Inbox::list_items(root => $P5) };
    ok(!$@, 'L5: list_items() on a project with no .subagent-guard/ at all does not die') or diag("error: $@");
    is_deeply($list, [], 'L5: the list is empty');
    ok(!-d "$P5/.ccpraxis-local-data/.subagent-guard", 'L5: the directory is still absent (absorb creates nothing)');

    my $report5 = lq_absorb(open_store($P5));
    is($report5->{state}, 'absent', 'L5: absorb() reports state absent');
}

# =============================================================================
# L6 -- a 0-byte legacy file is renamed to .migrated, with 0 filed.
# =============================================================================
{
    my $P6 = mk_root();
    make_path("$P6/.ccpraxis-local-data/.subagent-guard");
    write_raw(legacy_path_for($P6), '');

    my $report6 = lq_absorb(open_store($P6));
    is($report6->{state}, 'absorbed', 'L6: a 0-byte legacy file still absorbs (renames) cleanly');
    is($report6->{filed}, 0, 'L6: 0 questions were filed');
    ok(!-e legacy_path_for($P6), 'L6: the 0-byte questions.md is gone');
    ok(-f "$P6/.ccpraxis-local-data/.subagent-guard/questions.md.migrated", 'L6: questions.md.migrated exists');
    is(slurp_raw("$P6/.ccpraxis-local-data/.subagent-guard/questions.md.migrated"), '',
       'L6: .migrated is itself 0 bytes');
}

# =============================================================================
# L7 -- 4 concurrent openers, released by a barrier file, each absorbing the
# same 3-line legacy file: exactly 3 decisions result, one .migrated, no
# .migrated.2.
# =============================================================================
{
    my $P7 = mk_root();
    make_path("$P7/.ccpraxis-local-data/.subagent-guard");
    write_raw(legacy_path_for($P7), "- concurrent one?\n- concurrent two?\n- concurrent three?\n");

    my $harness_dir = tempdir(CLEANUP => 1);
    (my $barrier = "$harness_dir/barrier") =~ s{\\}{/}g;
    my $child_script = "$harness_dir/child.pl";
    open(my $cfh, '>', $child_script) or die "cannot write $child_script: $!";
    print {$cfh} <<'PERL';
use strict; use warnings;
my ($decision_pl, $root, $barrier_file, $out_file) = @ARGV;
chdir($root) or exit(125);
my $deadline = time() + 20;
until (-e $barrier_file || time() > $deadline) { select(undef, undef, undef, 0.02) }
{ local $@; do $decision_pl; if ($@) { open(my $fh, '>', $out_file); print {$fh} "ERR $@"; exit 0 } }
my $list = Almanac::Inbox::list_items(root => $root);
open(my $ofh, '>', $out_file) or exit(126);
print {$ofh} scalar(@$list), "\n";
close $ofh;
PERL
    close $cfh;

    my @pids;
    my @outs;
    for my $i (1 .. 4) {
        my $out = "$harness_dir/out$i.txt";
        push @outs, $out;
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            exec($^X, $child_script, $INBOX_PL, $P7, $barrier, $out);
            POSIX::_exit(127);
        }
        push @pids, $pid;
    }
    open(my $bfh, '>', $barrier) or die "cannot write barrier: $!";
    close $bfh;

    my $deadline = time() + 25;
    for my $pid (@pids) {
        while (time() < $deadline) {
            my $w = waitpid($pid, WNOHANG);
            last if $w == $pid;
            sleep(0.05);
        }
    }

    my @counts;
    for my $out (@outs) {
        my $c = slurp_raw($out);
        push @counts, defined($c) ? $c : 'MISSING';
    }
    unless (ok((grep { /^3\s*$/ } @counts) == 4, 'L7: all 4 concurrent openers observed exactly 3 decisions')) {
        diag("child outputs: " . join(', ', @counts));
    }

    my $final = eval { Almanac::Inbox::list_items(root => $P7) };
    is(scalar(@{ (ref $final eq 'ARRAY') ? $final : [] }), 3, 'L7: the final store holds exactly 3 decisions');
    ok(-f "$P7/.ccpraxis-local-data/.subagent-guard/questions.md.migrated", 'L7: exactly one rename happened (.migrated exists)');
    ok(!-e "$P7/.ccpraxis-local-data/.subagent-guard/questions.md.migrated.2", 'L7: no .migrated.2 was created (no double rename)');
}

# =============================================================================
# L8 -- copying .migrated back to questions.md and re-opening: 0 new,
# already == 3, and the file becomes .migrated.2.
# =============================================================================
{
    my $P8 = mk_root();
    make_path("$P8/.ccpraxis-local-data/.subagent-guard");
    my $seed8 = "- half-failure one?\n- half-failure two?\n- half-failure three?\n";
    write_raw(legacy_path_for($P8), $seed8);
    lq_absorb(open_store($P8));   # first absorption -> .migrated

    my $migrated8 = slurp_raw("$P8/.ccpraxis-local-data/.subagent-guard/questions.md.migrated");
    write_raw(legacy_path_for($P8), $migrated8 // $seed8);

    my $report8 = lq_absorb(open_store($P8));
    is($report8->{state}, 'absorbed', 'L8: copying .migrated back and re-opening absorbs again');
    is($report8->{filed}, 0, 'L8: 0 new decisions are filed');
    is($report8->{already}, 3, 'L8: already == 3 (all three lines are identical repeats)');
    ok(-f "$P8/.ccpraxis-local-data/.subagent-guard/questions.md.migrated.2",
       'L8: the copied-back file becomes .migrated.2');
}

# =============================================================================
# L9 -- with this test itself holding the legacy file's lock, absorb() with
# lock_timeout_ms => 0 returns lock_timeout, the file is intact, 0 filed, and
# it never dies.
# =============================================================================
{
    my $P9 = mk_root();
    make_path("$P9/.ccpraxis-local-data/.subagent-guard");
    write_raw(legacy_path_for($P9), "- lock-held question?\n");

    require Almanac::Lock;
    my ($held_lock, $lock_err) = Almanac::Lock->acquire(legacy_path_for($P9), verb => 'test-hold');
    ok(defined $held_lock, 'L9 fixture: this test acquired the legacy file\'s own lock')
        or diag('lock acquire failed: ' . (ref $lock_err eq 'HASH' ? ($lock_err->{kind} // 'unknown') : 'unknown'));

    my $report9;
    my $died = !eval { $report9 = lq_absorb(open_store($P9), lock_timeout_ms => 0); 1 };
    ok(!$died, 'L9: absorb() with the lock held elsewhere does not die');
    is(ref($report9) eq 'HASH' ? $report9->{state} : undef, 'failed', 'L9: absorb() reports state failed');
    # Spec sec 2.1 step 3 states the disjunction explicitly: "If that fails,
    # return lock_timeout (or io)". Held from the SAME process via a
    # differently-spelled path string, Lock's own %HELD reentrancy cache (a
    # same-process, string-keyed check) misses, so the underlying open() hits
    # a real OS-level sharing conflict on the identical file and reports io
    # rather than a clean flock-poll timeout -- both are the spec's own
    # named outcomes for this failure mode, not a weaker assertion.
    my $reason9 = ref($report9) eq 'HASH' ? $report9->{reason} : undef;
    ok(defined($reason9) && ($reason9 eq 'lock_timeout' || $reason9 eq 'io'),
       'L9: ...reason is lock_timeout or io (spec sec 2.1 step 3\'s own disjunction)')
        or diag('got: ' . (defined $reason9 ? $reason9 : 'undef'));

    ok(-f legacy_path_for($P9), 'L9: while the lock is held, the legacy file is still intact (not renamed)');
    my $list9_held = eval { Almanac::Inbox::list_items(root => $P9) };
    is(scalar(@{ (ref $list9_held eq 'ARRAY') ? $list9_held : [] }), 0,
       'L9: while the lock is held, nothing is filed (the timed-out absorb touched nothing)');

    $held_lock->release if defined $held_lock;

    # Spec sec 2.2: EVERY open absorbs a still-present legacy file -- so once
    # the lock is released, the NEXT open (this list_items call) absorbs
    # the one still-unrenamed line exactly once.
    my $list9_after = eval { Almanac::Inbox::list_items(root => $P9) };
    is(scalar(@{ (ref $list9_after eq 'ARRAY') ? $list9_after : [] }), 1,
       'L9: after the lock is released, the next open absorbs the legacy file exactly once (1 record)');
}

# =============================================================================
# L10 -- an absorbed decision is answered, then its identical raw line
# reappears in a re-created legacy file: it stays answered, with its answer.
# =============================================================================
{
    my $P10 = mk_root();
    make_path("$P10/.ccpraxis-local-data/.subagent-guard");
    write_raw(legacy_path_for($P10), "- decide this?\n");
    my $list10a = eval { Almanac::Inbox::list_items(root => $P10) };
    my ($rec10) = (ref $list10a eq 'ARRAY') ? @$list10a : ();
    ok(defined $rec10, 'L10 fixture: the line absorbed into one decision') or diag("error: $@");

    SKIP: {
        skip 'L10: fixture absorption did not produce a record', 2 unless defined $rec10;
        my ($answered, $changed) = eval { Almanac::Inbox::answer($rec10->{id}, root => $P10, answer => 'go with A') };
        ok(!$@, 'L10 fixture: answer() on the absorbed decision does not die') or diag("error: $@");

        write_raw(legacy_path_for($P10), "- decide this?\n");   # identical raw line, re-created
        lq_absorb(open_store($P10));

        my $reread = eval { Almanac::Inbox::read_item($rec10->{id}, root => $P10) };
        is(ref($reread) eq 'HASH' ? $reread->{fields}{status} : undef, 'answered',
           'L10: the decision is still answered after the identical line re-appears');
        is(ref($reread) eq 'HASH' ? $reread->{fields}{answer} : undef, 'go with A',
           'L10: ...with its original answer, never reset');
    }
}

# =============================================================================
# L11 -- the comment block immediately above `sub absorb` names a removal
# condition.
# =============================================================================
{
    if (-f $LEGACYQ_PM) {
        my @lines = read_all_lines($LEGACYQ_PM);
        my $absorb_line;
        for my $i (0 .. $#lines) {
            if ($lines[$i] =~ /^\s*sub\s+absorb\b/) { $absorb_line = $i; last }
        }
        my $found = 0;
        if (defined $absorb_line) {
            my $i = $absorb_line - 1;
            while ($i >= 0 && $lines[$i] =~ /^\s*#/) {
                $found = 1 if $lines[$i] =~ /^\s*#.*Removal condition:/;
                $i--;
            }
        }
        ok($found, 'L11: the comment block directly above sub absorb names a "Removal condition:"')
            or diag(defined $absorb_line ? 'no matching comment line found directly above sub absorb'
                                          : 'sub absorb not found in the file');
    } else {
        fail('L11: the comment block directly above sub absorb names a "Removal condition:"');
    }
}

# =============================================================================
# L12 / AC6 -- almanac-inbox.pl has exactly one Almanac::LegacyQueue::absorb(
# call, exactly one ->open( call and exactly one migrate_legacy_store( call,
# ALL inside sub open_inbox, with migrate preceding absorb (spec 2.1's
# "migrate_legacy_store($store) ... then Almanac::LegacyQueue::absorb($store)").
# =============================================================================
{
    my @lines = read_all_lines($INBOX_PL);
    my (@absorb_hits, @open_hits, @migrate_hits, $od_start, $od_end);
    for my $i (0 .. $#lines) {
        next if $lines[$i] =~ /^\s*#/;   # a prose comment mentioning the call is not a call
        push @absorb_hits, $i + 1  if $lines[$i] =~ /Almanac::LegacyQueue::absorb\s*\(/;
        push @open_hits, $i + 1    if $lines[$i] =~ /->open\s*\(/;
        push @migrate_hits, $i + 1 if $lines[$i] =~ /\bmigrate_legacy_store\s*\(/;
        if (!defined($od_start) && $lines[$i] =~ /^\s*sub\s+open_inbox\b/) {
            $od_start = $i + 1;
            for my $j ($i + 1 .. $#lines) {
                if ($lines[$j] =~ /^\s*sub\s+\w+/) { $od_end = $j; last }
            }
            $od_end = scalar(@lines) unless defined $od_end;
        }
    }
    unless (is(scalar(@absorb_hits), 1, 'L12: exactly one Almanac::LegacyQueue::absorb( call in the file')) {
        diag("lines: " . join(',', @absorb_hits));
    }
    unless (is(scalar(@open_hits), 1, 'L12: exactly one ->open( call in the file')) {
        diag("lines: " . join(',', @open_hits));
    }
    unless (is(scalar(@migrate_hits), 1, 'AC6: exactly one migrate_legacy_store( call in the file')) {
        diag("lines: " . join(',', @migrate_hits));
    }
    if (defined($od_start) && @absorb_hits == 1) {
        ok($absorb_hits[0] >= $od_start && $absorb_hits[0] <= $od_end,
           "L12: the sole absorb( call (line $absorb_hits[0]) lives inside sub open_inbox ($od_start..$od_end)");
    } else {
        fail('L12: the sole absorb( call lives inside sub open_inbox');
    }
    if (defined($od_start) && @migrate_hits == 1) {
        ok($migrate_hits[0] >= $od_start && $migrate_hits[0] <= $od_end,
           "AC6: the sole migrate_legacy_store( call (line $migrate_hits[0]) lives inside sub open_inbox ($od_start..$od_end)");
    } else {
        fail('AC6: the sole migrate_legacy_store( call lives inside sub open_inbox');
    }
    if (@migrate_hits == 1 && @absorb_hits == 1) {
        ok($migrate_hits[0] < $absorb_hits[0],
           "AC6: migrate_legacy_store( (line $migrate_hits[0]) precedes Almanac::LegacyQueue::absorb( (line $absorb_hits[0]))");
    } else {
        fail('AC6: migrate_legacy_store( precedes Almanac::LegacyQueue::absorb(');
    }
}

# =============================================================================
# B13 (second case) / AC28 -- an unmigrated A/decision/ plus a legacy
# questions.md with no inbox store yet: the FIRST open migrates A/decision ->
# A/inbox, THEN absorbs the legacy queue into A/inbox -- never into A/decision.
# =============================================================================
{
    my $PMA = mk_root();
    make_path("$PMA/.ccpraxis-local-data/.subagent-guard");
    write_raw(legacy_path_for($PMA), "- migrate then absorb?\n");

    # seed an unmigrated legacy decision store with one pre-existing record.
    my $legacy_dir = "$PMA/.ccpraxis-local-data/almanac/decision";
    make_path($legacy_dir);
    eval {
        my $lstore = Almanac::Store->open(scope => 'project', type => 'decision', root => $PMA);
        $lstore->create(id => 'pre-existing', fields => { title => 'pre-existing', status => 'unanswered', created => '2020-01-01T00:00:00Z' },
                         order => [qw(title status created)]);
    };
    ok(!$@, 'B13/AC28 fixture: a pre-existing legacy decision record exists in A/decision') or diag("error: $@");

    my $list_ma = eval { Almanac::Inbox::list_items(root => $PMA) };
    ok(!$@, 'B13/AC28: list_items() on an unmigrated project with a legacy queue does not die') or diag("error: $@");
    my @recs_ma = (ref $list_ma eq 'ARRAY') ? @$list_ma : ();
    ok(!-d $legacy_dir, 'B13/AC28: A/decision no longer exists after the first open');
    ok(-d "$PMA/.ccpraxis-local-data/almanac/inbox", 'B13/AC28: A/inbox exists after the first open');
    is(scalar(@recs_ma), 2, 'B13/AC28: A/inbox holds both the migrated pre-existing record and the absorbed legacy-queue line');
    ok((grep { $_->{id} eq 'pre-existing' } @recs_ma), 'B13/AC28: the pre-existing record migrated across by id');
    ok((grep { defined $_->{fields}{title} && $_->{fields}{title} eq 'migrate then absorb?' } @recs_ma),
       'B13/AC28: the legacy-queue line was absorbed into A/inbox (never into A/decision)');
    ok(!-e legacy_path_for($PMA), 'B13/AC28: questions.md is gone after absorption');
}

# =============================================================================
# L13 -- legacy_path(open_inbox(root => P)) has the pinned shape and
# starts with P's own canonical form.
# =============================================================================
{
    my $P13 = mk_root();
    my $store13 = eval { Almanac::Inbox::open_inbox(root => $P13) };
    ok(!$@ && defined $store13, 'L13 fixture: open_inbox(root => P) does not die') or diag("error: $@");
    my $path13 = defined($store13) ? lq_legacy_path($store13) : undef;
    ok(defined $path13, 'L13: legacy_path() returns a defined path') or diag('legacy_path() returned undef');
    if (defined $path13) {
        # fold_path(), not norm_root(): this file may not exist on disk (it
        # never has to, for legacy_path() to name it), so it cannot be run
        # through Cwd::abs_path -- fold slashes/case only, and canonicalise
        # the OTHER side (P13, which does exist) with norm_root() so the two
        # forms are comparable regardless of which mount spelling this host's
        # tempdir handed back.
        my $norm13 = fold_path($path13);
        like($norm13, qr{/\.ccpraxis-local-data/\.subagent-guard/questions\.md\z},
             'L13: the path ends with /.ccpraxis-local-data/.subagent-guard/questions.md');
        ok(index($norm13, norm_root($P13)) == 0, 'L13: the path starts with P\'s own canonical form');
    }
}

# =============================================================================
# L14 -- hermeticity: the real repo's store is unchanged by this whole file.
# =============================================================================
{
    is_deeply(real_snapshot(), $REAL_BEFORE,
       'L14: the real repo\'s .ccpraxis-local-data/.subagent-guard/ and almanac/inbox/ are unchanged');
}

done_testing();
