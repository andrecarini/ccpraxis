#!/usr/bin/env perl
# platform: any
# t/04 — a load-modify-write race cannot defeat the
# freeze guarantee.
#
# `update` and `set-status` both LOAD a report, do work that can take real
# wall-clock time (`update`'s `--body -` BLOCKS on stdin), then WRITE a hash
# built from that stale load. Red-team (fixbatch-step7, HIGH) showed that if
# a `set-status --to triaging` lands in that window, `update`'s subsequent
# write reverts the status to `open` and erases content_sha256/frozen_at —
# silently undoing the freeze the refusal message in `update` promises, and
# leaving `verify` saying "not frozen" instead of TAMPERED.
#
# This is NOT the same subject as frontmatter-injection.t (which is about
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
#
# RENAME (12-bug-claimant-and-triaging, Decision 31): `reviewing` is renamed
# `triaging`, and any `set-status` call whose current OR target state is
# `triaging` now requires the caller's identity to come from a butler hook
# TICKET (BpHook::take_ticket('almanac-bug', ...)), keyed on sha1(name,
# argv). A ticket binds exactly one argv, so two DIFFERENT processes that
# would otherwise issue byte-identical argv (RACE2's raced pair) each need
# their OWN ticket, which means each needs its OWN distinguishable argv —
# the hook's call carries an extra `--note` flag for exactly this reason;
# it changes no behavior this file asserts on.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $A = "$S/almanac-bug.pl";
ok(-f $A, 'almanac-bug.pl exists') or BAIL_OUT('script missing');

(my $BUTLER_SCRIPTS = "$Bin/../../../butler/scripts") =~ s{\\}{/}g;
my $BPHOOK_PM = "$BUTLER_SCRIPTS/BpHook.pm";
ok(-f $BPHOOK_PM, 'BpHook.pm exists (needed to mint test tickets)') or BAIL_OUT('BpHook.pm missing');
require $BPHOOK_PM;

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
# Decision 120(c): presence in the real gitignored live store is never REQUIRED -- only that this suite leaves its count unchanged (checked below).

my $HOME = tempdir(CLEANUP => 1);
my $CFG  = tempdir(CLEANUP => 1);   # CLAUDE_CONFIG_DIR
my $BSD  = tempdir(CLEANUP => 1);   # BUTLER_STATE_DIR
for ($HOME, $CFG, $BSD) { s{\\}{/}g }

$ENV{HOME}              = $HOME;
$ENV{USERPROFILE}       = $HOME;
$ENV{ALMANAC_HOME}      = $HOME;
$ENV{CLAUDE_CONFIG_DIR} = $CFG;
$ENV{BUTLER_STATE_DIR}  = $BSD;
delete $ENV{CCPRAXIS_DATA_DIR};
delete $ENV{CLAUDE_PROJECT_DIR};

sub run {
    my (%opt) = @_;
    my $hook_env = defined $opt{hook} ? qq{ALMANAC_RACE_TEST_HOOK="$opt{hook}" } : '';
    my $cmd = qq{${hook_env}ALMANAC_HOME="$HOME" HOME="$HOME" USERPROFILE="$HOME" }
            . qq{CLAUDE_CONFIG_DIR="$CFG" BUTLER_STATE_DIR="$BSD" perl "$A" }
            . join(' ', @{ $opt{args} }) . ' 2>&1';
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
# ---------------------------------------------------------------------------
# Ticket minting (spec sec 5.4): a claim's identity comes ONLY from a butler
# hook ticket, keyed on sha1(name, argv). mint_ticket's argv must equal
# EXACTLY the argv the almanac-bug.pl subprocess receives.
# ---------------------------------------------------------------------------
my $TICKET_SEQ = 0;
sub ensure_transcript {
    my ($sid) = @_;
    my $dir = "$CFG/projects/p";
    make_path($dir) unless -d $dir;
    my $path = "$dir/$sid.jsonl";
    unless (-f $path) {
        open my $fh, '>', $path or die "fixture: cannot write transcript $path: $!";
        print {$fh} "{}\n";
        close $fh;
    }
    return $path;
}
sub mint_ticket {
    my ($session, $agent, @argv) = @_;
    my $transcript = ensure_transcript($session);
    local $ENV{BUTLER_STATE_DIR} = $BSD;
    my $ok = BpHook::write_ticket(
        { session_id => $session, tool_use_id => 'T' . (++$TICKET_SEQ),
          (defined $agent ? (agent_id => $agent) : ()),
          transcript_path => $transcript, cwd => undef },
        'almanac-bug', [ @argv ]);
    die "fixture: could not write ticket for (@argv)\n" unless $ok;
    return;
}
# run_as($session, $agent_or_undef, @args) -- mints a ticket for EXACTLY
# @args, then spawns almanac-bug.pl with that same argv (no race hook).
sub run_as {
    my ($session, $agent, @args) = @_;
    mint_ticket($session, $agent, @args);
    return run(args => [ @args ]);
}

# Writes a self-contained hook script that runs a real set-status call
# through the CLI, with no ALMANAC_RACE_TEST_HOOK of its own (no recursion).
# Its own identity ticket (for ITS exact argv, including any @{$o{extra}})
# must already have been minted by the caller before the hook is invoked.
sub write_hook {
    my (%o) = @_;
    my @extra = @{ $o{extra} || [] };
    my $extra_str = join(', ', map { qq{"$_"} } @extra);
    $extra_str = ", $extra_str" if length $extra_str;
    my ($fh, $path) = File::Temp::tempfile(SUFFIX => '.pl', UNLINK => 0);
    print {$fh} <<"HOOK";
#!/usr/bin/env perl
use strict; use warnings;
\$ENV{ALMANAC_HOME} = "$HOME";
\$ENV{HOME} = "$HOME";
\$ENV{USERPROFILE} = "$HOME";
\$ENV{CLAUDE_CONFIG_DIR} = "$CFG";
\$ENV{BUTLER_STATE_DIR} = "$BSD";
delete \$ENV{ALMANAC_RACE_TEST_HOOK};
system(\$^X, "$A", "set-status", "$o{id}", "--project", "$o{project}", "--to", "$o{to}"$extra_str);
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

    # The hook's set-status (open -> triaging) is the only identity-gated
    # call in this race: `update` itself never consults a ticket.
    mint_ticket('S1', undef, 'set-status', $id, '--project', $SCRATCH, '--to', 'triaging');
    my $hook = write_hook(id => $id, project => $SCRATCH, to => 'triaging');

    my ($rc, $out) = run(hook => $hook,
                          # --replace since 2026-08-29: a whole-body replacement
                          # must now say so. This suite is about the CAS race,
                          # not about the discard guard, so the flag keeps the
                          # subject under test unchanged -- without it the guard
                          # would refuse before the race ever ran, and RACE1
                          # would pass for entirely the wrong reason.
                          args => ['update', $id, '--project', $SCRATCH, '--replace',
                                   '--body', '"a body update racing the freeze"']);
    unlink $hook;

    isnt($rc, 0, 'RACE1: update ABORTS when the report changed underneath it mid-flight');
    like($out, qr/changed on disk/i, 'RACE1: the refusal names what happened');
    like($out, qr/[Rr]etry/, 'RACE1: the refusal tells the operator to retry');

    # The concurrent set-status (run by the hook) DID land -- that is the
    # real race outcome, and the point of the fix is that update's stale
    # write must not clobber it afterward.
    is(raw_field($path, 'status'), 'triaging',
       'RACE1: the concurrent set-status is intact -- status is triaging');
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
# RACE2 -- same shape for set-status racing set-status (a second triager
#          transition landing mid-flight of a first one).
# =============================================================================
{
    my $SCRATCH = tempdir(CLEANUP => 1);
    $SCRATCH =~ s{\\}{/}g;
    my (undef, $o) = run(args => ['file', '--project', $SCRATCH,
                                   '--title', '"origtitle"', '--body', '"original body"']);
    chomp(my $path = $o);
    my ($id) = $path =~ m{/([^/]+)\.md$};

    # First bring it to triaging for real (claimed by S1), then race two
    # `taken` transitions off of it: the hook's call and the outer call.
    # They would otherwise be byte-identical argv, but a ticket binds one
    # exact argv, so the hook's call carries a distinguishing --note flag
    # (not asserted on) purely so each gets its own ticket. Both are minted
    # for session S1 (the claimant) so the claimant check passes for either.
    run_as('S1', undef, 'set-status', $id, '--project', $SCRATCH, '--to', 'triaging');
    my $before_race = slurp($path);

    mint_ticket('S1', undef, 'set-status', $id, '--project', $SCRATCH, '--to', 'taken',
                '--note', 'race-hook');
    my $hook = write_hook(id => $id, project => $SCRATCH, to => 'taken',
                           extra => ['--note', 'race-hook']);

    mint_ticket('S1', undef, 'set-status', $id, '--project', $SCRATCH, '--to', 'taken');
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

    my ($rc, $out) = run(args => ['update', $id, '--project', $SCRATCH, '--replace',
                                   '--body', '"a perfectly normal sequential update"',
                                   '--title', '"newtitle"']);
    is($rc, 0, 'RACE3: a normal sequential update (no race) still succeeds')
        or diag "out: $out";
    is(raw_field($path, 'title'), 'newtitle', 'RACE3: the update was actually applied');

    my ($rc2, $out2) = run_as('S1', undef, 'set-status', $id, '--project', $SCRATCH, '--to', 'triaging');
    is($rc2, 0, 'RACE3: a normal sequential set-status (no race) still succeeds')
        or diag "out: $out2";
    is(raw_field($path, 'status'), 'triaging', 'RACE3: the transition was actually applied');
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
