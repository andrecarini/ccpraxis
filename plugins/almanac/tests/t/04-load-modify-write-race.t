#!/usr/bin/env perl
# t/04-load-modify-write-race.t — a load-modify-write race cannot defeat the
# freeze guarantee.
#
# `update` and `set-status` both LOAD a report, do work that can take real
# wall-clock time (`update`'s `--body -` BLOCKS on stdin), then WRITE a hash
# built from that stale load. Red-team (fixbatch-step7, HIGH) showed that if
# a `set-status --to reviewing` lands in that window, `update`'s subsequent
# write reverts the status to `open` and erases content_sha256/frozen_at —
# silently undoing the freeze the refusal message in `update` promises, and
# leaving `verify` saying "not frozen" instead of TAMPERED.
#
# This is NOT the same subject as 03-frontmatter-injection.t (which is about
# a single CLI call forging frontmatter through unescaped values) — this is
# about two CONCURRENT calls, so it gets its own file per the driver's
# instruction.
#
# DETERMINISM: real concurrent processes on this platform (Git-for-Windows
# perl, no working flock — see the script's own comments) cannot be timed
# reliably enough for a non-flaky assertion. Instead this uses a seam the
# fix itself introduces for exactly this purpose: ALMANAC_RACE_TEST_HOOK
# names a perl script that almanac-bug.pl runs (list-form system(), no
# shell quoting) immediately after `update`/`set-status` load a report and
# before they do anything else — i.e. inside the real load-modify-write
# window, not a stand-in for it. The hook makes an ordinary, real
# `set-status` call through the same CLI a genuine second process would use.
# That is deterministic (no timing dependency) while still exercising the
# actual code path the race lives in, not merely asserting a helper exists.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $A = "$S/almanac-bug.pl";
ok(-f $A, 'almanac-bug.pl exists') or BAIL_OUT('script missing');

my $HOME = tempdir(CLEANUP => 1);

sub run {
    my (%opt) = @_;
    my $hook_env = defined $opt{hook} ? qq{ALMANAC_RACE_TEST_HOOK="$opt{hook}" } : '';
    my $cmd = qq{${hook_env}ALMANAC_HOME="$HOME" perl "$A" } . join(' ', @{ $opt{args} }) . ' 2>&1';
    my $out = `$cmd`;
    return ($? >> 8, $out // '');
}

sub slurp {
    my ($p) = @_;
    open my $f, '<:raw', $p or return undef;
    local $/; return <$f>;
}
sub raw_field {
    my ($p, $k) = @_;
    my $t = slurp($p) // return undef;
    return $t =~ /^\Q$k\E:\s*(.*)$/m ? $1 : undef;
}
sub count_reports_in {
    my ($dir) = @_;
    return 0 unless -d $dir;
    opendir(my $dh, $dir) or return 0;
    my @f = grep { /\.md\z/ && -f "$dir/$_" } readdir($dh);
    closedir $dh;
    return scalar @f;
}

# Live-store sanity — this suite must never touch it either.
(my $REPO = "$Bin/../../../..") =~ s{\\}{/}g;
my $LIVE_STORE = "$REPO/.ccpraxis-local-data/bug-reports";
my $live_before = count_reports_in($LIVE_STORE);
ok($live_before > 0, "sanity: live store has reports to protect ($live_before found)");

# Writes a self-contained hook script that runs a real set-status call
# through the CLI, with no ALMANAC_RACE_TEST_HOOK of its own (no recursion).
sub write_hook {
    my (%o) = @_;
    my ($fh, $path) = File::Temp::tempfile(SUFFIX => '.pl', UNLINK => 0);
    print {$fh} <<"HOOK";
#!/usr/bin/env perl
use strict; use warnings;
\$ENV{ALMANAC_HOME} = "$HOME";
delete \$ENV{ALMANAC_RACE_TEST_HOOK};
system(\$^X, "$A", "set-status", "$o{id}", "--project", "$o{project}", "--to", "$o{to}");
HOOK
    close $fh;
    return $path;
}

# =============================================================================
# RACE1 -- a set-status landing inside `update`'s load-modify-write window
#          is NOT silently reverted; `update` aborts loudly instead.
# =============================================================================
{
    my $SCRATCH = tempdir(CLEANUP => 1);
    $SCRATCH =~ s{\\}{/}g;
    my (undef, $o) = run(args => ['file', '--project', $SCRATCH,
                                   '--title', '"origtitle"', '--body', '"original body"']);
    chomp(my $path = $o);
    my ($id) = $path =~ m{/([^/]+)\.md$};

    my $hook = write_hook(id => $id, project => $SCRATCH, to => 'reviewing');

    my ($rc, $out) = run(hook => $hook,
                          args => ['update', $id, '--project', $SCRATCH,
                                   '--body', '"a body update racing the freeze"']);
    unlink $hook;

    isnt($rc, 0, 'RACE1: update ABORTS when the report changed underneath it mid-flight');
    like($out, qr/changed on disk/i, 'RACE1: the refusal names what happened');
    like($out, qr/[Rr]etry/, 'RACE1: the refusal tells the operator to retry');

    # The concurrent set-status (run by the hook) DID land -- that is the
    # real race outcome, and the point of the fix is that update's stale
    # write must not clobber it afterward.
    is(raw_field($path, 'status'), 'reviewing',
       'RACE1: the concurrent set-status is intact -- status is reviewing');
    ok(defined raw_field($path, 'content_sha256') && length raw_field($path, 'content_sha256'),
       'RACE1: content_sha256 was NOT erased by the stale update write');
    ok(defined raw_field($path, 'frozen_at') && length raw_field($path, 'frozen_at'),
       'RACE1: frozen_at was NOT erased by the stale update write');
    is(raw_field($path, 'title'), 'origtitle',
       'RACE1: the racing update never applied its own change either -- no partial write');

    # verify must see this as correctly frozen, not "not frozen" (which is
    # exactly the silent-failure mode the race produced before the fix).
    my ($rc_v, $out_v) = run(args => ['verify', '--project', $SCRATCH]);
    is($rc_v, 0, 'RACE1: verify is clean -- the surviving state is genuinely frozen, not corrupted');
    unlike($out_v, qr/not frozen/, 'RACE1: verify does not say "not frozen" (the old silent-failure symptom)');
}

# =============================================================================
# RACE2 -- same shape for set-status racing set-status (a second reviewer
#          transition landing mid-flight of a first one).
# =============================================================================
{
    my $SCRATCH = tempdir(CLEANUP => 1);
    $SCRATCH =~ s{\\}{/}g;
    my (undef, $o) = run(args => ['file', '--project', $SCRATCH,
                                   '--title', '"origtitle"', '--body', '"original body"']);
    chomp(my $path = $o);
    my ($id) = $path =~ m{/([^/]+)\.md$};

    # First bring it to reviewing for real, then race two transitions off
    # of it: the hook takes it to `taken`, the outer call also tries `taken`.
    run(args => ['set-status', $id, '--project', $SCRATCH, '--to', 'reviewing']);
    my $before_race = slurp($path);

    my $hook = write_hook(id => $id, project => $SCRATCH, to => 'taken');
    my ($rc, $out) = run(hook => $hook,
                          args => ['set-status', $id, '--project', $SCRATCH, '--to', 'taken']);
    unlink $hook;

    isnt($rc, 0, 'RACE2: the racing set-status ABORTS rather than double-applying/clobbering');
    like($out, qr/changed on disk/i, 'RACE2: the refusal names what happened');

    is(raw_field($path, 'status'), 'taken',
       'RACE2: the hook\'s set-status (the one that actually landed first) is intact');
    ok(defined raw_field($path, 'taken_at') && length raw_field($path, 'taken_at'),
       'RACE2: taken_at was stamped by the surviving transition');
}

# =============================================================================
# RACE3 -- no false positives: an ordinary SEQUENTIAL update (no concurrent
#          write in between) still succeeds exactly as before this fix.
# =============================================================================
{
    my $SCRATCH = tempdir(CLEANUP => 1);
    $SCRATCH =~ s{\\}{/}g;
    my (undef, $o) = run(args => ['file', '--project', $SCRATCH,
                                   '--title', '"origtitle"', '--body', '"original body"']);
    chomp(my $path = $o);
    my ($id) = $path =~ m{/([^/]+)\.md$};

    my ($rc, $out) = run(args => ['update', $id, '--project', $SCRATCH,
                                   '--body', '"a perfectly normal sequential update"',
                                   '--title', '"newtitle"']);
    is($rc, 0, 'RACE3: a normal sequential update (no race) still succeeds')
        or diag "out: $out";
    is(raw_field($path, 'title'), 'newtitle', 'RACE3: the update was actually applied');

    my ($rc2, $out2) = run(args => ['set-status', $id, '--project', $SCRATCH, '--to', 'reviewing']);
    is($rc2, 0, 'RACE3: a normal sequential set-status (no race) still succeeds')
        or diag "out: $out2";
    is(raw_field($path, 'status'), 'reviewing', 'RACE3: the transition was actually applied');
}

# =============================================================================
# Live-store sanity, again, at the end.
# =============================================================================
{
    my $live_after = count_reports_in($LIVE_STORE);
    is($live_after, $live_before,
       "live store's report count is unchanged by this suite ($live_before before, $live_after after)");
}

done_testing();
