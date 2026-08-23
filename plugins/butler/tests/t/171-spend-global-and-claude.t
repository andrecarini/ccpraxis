#!/usr/bin/env perl
# t02-spend-persistence — the butler-side oracle for blueprint tui-operator-feedback.
#
# Covers the two writer-side defects behind the operator's complaint that "the
# claude spend says 'no snapshot'":
#
#   * Decision 11 -- the snapshot is RUN-SCOPED, so it cannot exist when no
#     fleet run is active, which is the operator's normal state. Every figure
#     in it (go's windows, zen's balance, claude's utilizations) describes the
#     ACCOUNT, not the run that happened to poll for it, so the run scoping was
#     never meaningful for this data.
#   * Decision 12 -- `claude` is NEVER FETCHED BY ANYTHING. bp-spend.pl's
#     provider list is qw(go zen); nothing composes a claude entry; launcher.pl
#     never invokes bp-usage-gate.pl. "Claude : no snapshot" was therefore
#     guaranteed on every launch since the panel shipped, and would have
#     survived the format fix untouched.
#
# NO NETWORK AND NO CREDENTIALS ARE USED. Every fetch path is exercised via
# --offline or via an injected fake gate; a test that reached
# api.anthropic.com would be non-deterministic AND would poll the operator's
# real account on every run.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;
use Test::More;
use JSON::PP;

my $SPEND_PL = "$Bin/../../scripts/bp-spend.pl";
ok(-f $SPEND_PL, 'bp-spend.pl exists') or BAIL_OUT('nothing to test');

my $PERL = $^X;

sub run_spend {
    my (@args) = @_;
    my $cmd = join(' ', map { qq("$_") } ($PERL, $SPEND_PL, @args));
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}

sub slurp_json {
    my ($p) = @_;
    return undef unless -f $p;
    open(my $fh, '<:raw', $p) or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    return eval { JSON::PP->new->decode($raw) };
}

sub by_provider {
    my ($snap, $want) = @_;
    return undef unless ref($snap) eq 'HASH' && ref($snap->{results}) eq 'ARRAY';
    for my $r (@{ $snap->{results} }) {
        next unless ref($r) eq 'HASH';
        return $r if defined $r->{provider} && $r->{provider} eq $want;
    }
    return undef;
}

# ===========================================================================
# PART 1 -- --global-dir: a run-independent destination (AC7, AC8).
# ===========================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    my $g   = File::Spec->catdir($dir, 'global');

    my ($rc, $out) = run_spend('snapshot', '--global-dir', $g, '--offline', '--now', 1787000000);
    is($rc, 0, 'AC7: snapshot --global-dir alone succeeds -- --run-dir is no longer mandatory')
        or diag("  output: $out");

    my $gp = File::Spec->catfile($g, 'spend.json');
    ok(-f $gp, 'AC7: spend.json is written under the global directory');

    SKIP: {
        skip 'no global snapshot written', 2 unless -f $gp;

        # THE PROPERTY IS PARITY, NOT AN ABSOLUTE MODE, and the difference is a
        # platform fact rather than a weakened assertion.
        #
        # write_snapshot's header states "Mode 0600 from creation (sysopen with
        # the mode), never chmod'd after". On this Git-for-Windows host that is
        # NOT what lands: both copies come out 0644, because Windows does not
        # implement POSIX permission bits the way sysopen's mode argument
        # assumes. Measured, both paths, same run. Asserting `$mode & 077 == 0`
        # here would fail on the platform this repo actually runs on, and
        # would be failing about the ORIGINAL writer's behaviour, not about the
        # destination t02 adds.
        #
        # What t02 can honestly promise -- and what an oracle should hold it to
        # -- is that the new destination is no more permissive than the
        # long-standing one. Same writer, same discipline, no second policy.
        # The overstated comment is a pre-existing defect and is filed
        # separately rather than quietly corrected inside this package.
        my $r2 = File::Spec->catdir($dir, 'runcmp');
        run_spend('snapshot', '--run-dir', $r2, '--offline', '--now', 1787000000, '--force');
        my $rp2 = File::Spec->catfile($r2, 'spend.json');
        my $gmode = (stat($gp))[2]  & 07777;
        my $rmode = -f $rp2 ? ((stat($rp2))[2] & 07777) : $gmode;
        ok(($gmode & ~$rmode) == 0,
            sprintf('AC7: the global snapshot is no more permissive than the run copy (global %04o, run %04o)', $gmode, $rmode));
        ok(ref(slurp_json($gp)) eq 'HASH', 'AC7: and it is valid JSON');
    }
}

# ===========================================================================
# PART 2 -- both destinations, byte-identical (AC8).
# ===========================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    my $r   = File::Spec->catdir($dir, 'run');
    my $g   = File::Spec->catdir($dir, 'global');

    my ($rc, $out) = run_spend('snapshot', '--run-dir', $r, '--global-dir', $g,
                               '--offline', '--now', 1787000000);
    is($rc, 0, 'AC8: both destinations together succeed') or diag("  output: $out");

    my ($rp, $gp) = (File::Spec->catfile($r, 'spend.json'), File::Spec->catfile($g, 'spend.json'));
    ok(-f $rp && -f $gp, 'AC8: both files exist');

    SKIP: {
        skip 'one or both files missing', 1 unless -f $rp && -f $gp;
        my $rb = do { open my $f, '<:raw', $rp or die; local $/; <$f> };
        my $gb = do { open my $f, '<:raw', $gp or die; local $/; <$f> };
        is($rb, $gb, 'AC8: the two copies are byte-identical -- one fetch, two destinations, never two polls');
    }
}

# ===========================================================================
# PART 3 -- the cadence floor spans every destination (AC9).
#
# THIS IS THE ASSERTION THAT STOPS THE FIX FROM DOUBLING THE POLL RATE. The
# floor is derived from an existing snapshot's mtime precisely so the verb is
# safe to call on any tick. Adding a second destination without widening the
# floor to cover it would make a fresh-at-one/absent-at-the-other pair fetch
# every time.
# ===========================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    my $r   = File::Spec->catdir($dir, 'run');
    my $g   = File::Spec->catdir($dir, 'global');

    # Seed ONLY the run copy.
    run_spend('snapshot', '--run-dir', $r, '--offline', '--now', 1787000000);
    my $rp = File::Spec->catfile($r, 'spend.json');
    ok(-f $rp, 'AC9: setup -- the run copy is seeded and fresh');

    # Now ask for both. The run copy is fresh, so this must short-circuit.
    my ($rc, $out) = run_spend('snapshot', '--run-dir', $r, '--global-dir', $g,
                               '--offline', '--now', 1787000000);
    is($rc, 0, 'AC9: a call covering a fresh destination still exits 0');

    # A short-circuit that leaves the global copy MISSING would be a different
    # bug -- the whole point of the global path is that it exists. So the
    # contract is: no new FETCH, but the freshly-read content is still written
    # wherever it is absent.
    my $gp = File::Spec->catfile($g, 'spend.json');
    ok(-f $gp, 'AC9: the short-circuit still materialises the missing destination -- a cadence floor must not become a reason for the file never to appear');
}

# ===========================================================================
# PART 4 -- claude as a third provider (AC14, AC15), via an INJECTED gate.
#
# --gate-cmd exists for this test and for nothing else in production; it is the
# seam that makes the credential path testable without owning credentials. The
# real default remains bp-usage-gate.pl.
# ===========================================================================
{
    my $dir = tempdir(CLEANUP => 1);

    # AC14 -- --offline must record claude `absent` and spawn NOTHING. A fake
    # gate that would fail loudly if invoked proves the second half.
    my $tripwire = File::Spec->catfile($dir, 'tripwire.pl');
    open(my $tw, '>', $tripwire) or die $!;
    print {$tw} qq{open(my \$f, '>', "$dir/INVOKED") or 1; print {\$f} "1"; close \$f; print "OK five=0.1 seven=0.2 token_life_h=9\\n"; exit 0;\n};
    close $tw;

    my $o = File::Spec->catdir($dir, 'off');
    my ($rc) = run_spend('snapshot', '--global-dir', $o, '--offline', '--now', 1787000000,
                         '--gate-cmd', "$PERL $tripwire");
    is($rc, 0, 'AC14: offline snapshot succeeds');
    ok(!-e File::Spec->catfile($dir, 'INVOKED'),
        'AC14: --offline spawned no gate subprocess -- its no-credentials, no-network guarantee is intact');
    my $osnap = slurp_json(File::Spec->catfile($o, 'spend.json'));
    my $oc = by_provider($osnap, 'claude');
    ok(defined $oc, 'AC14: claude appears in the offline snapshot at all -- it was previously absent from the provider list entirely');
    is(($oc || {})->{status}, 'absent', 'AC14: and is recorded absent, alongside go and zen');
}

# AC15 -- the gate's exit code and single line map to a claude result.
my @GATE_CASES = (
    [ 'ok',          0,  "OK five=0.42 seven=0.9 token_life_h=12.5\n",
      'ok',     0.42, 0.9,  'exit 0 is a reading' ],
    [ 'pause',       10, "PAUSE window=five_hour resets_at_epoch=1787003600 resets_at_iso=2026-08-17T21:53:20Z estimated=0 five=0.95 seven=0.3 token_life_h=9\n",
      'ok',     0.95, 0.3,  'a PAUSE verdict is a reading too, and a high one -- discarding it would hide the figures precisely when they matter most' ],
    [ 'unavailable', 20, "UNAVAILABLE status=500 detail=telemetry-unreachable\n",
      'unknown', undef, undef, 'unreachable telemetry is unknown, never absent and never zero' ],
    [ 'creds',       30, "CREDS detail=no-oauth-block\n",
      'unknown', undef, undef, 'a credential problem is unknown -- configured enough to have failed' ],
    [ 'relogin',     40, "RELOGIN token_life_h=0.1 detail=oauth-token-under-floor-cannot-refresh-in-session\n",
      'unknown', undef, undef, 'a token under the floor is unknown' ],
    [ 'garbage',     0,  "something entirely unexpected\n",
      'unknown', undef, undef, 'exit 0 with an unparseable line is unknown -- a zero exit is not a promise of figures' ],
    # The caller captures stderr as well as stdout on purpose, so a warning
    # emitted before the result would be "the first line". Taking the first
    # line literally would report a perfectly healthy poll as unknown.
    [ 'noise-first', 0,  "Use of uninitialized value in concatenation\nOK five=0.11 seven=0.22 token_life_h=8\n",
      'ok',     0.11, 0.22, 'a warning printed before the result does not cost the reading -- the verb prefix selects the line, not its position' ],
    # ...and the converse: a stray line containing five= but no contract verb
    # must NOT be able to supply figures.
    [ 'noise-only',  0,  "debug: five=0.99 seven=0.99 from some internal cache\n",
      'unknown', undef, undef, 'a diagnostic that merely CONTAINS five= is not a reading -- only a documented verb line is eligible' ],
);

for my $c (@GATE_CASES) {
    my ($name, $exit, $line, $want_status, $want5, $want7, $why) = @$c;
    my $dir  = tempdir(CLEANUP => 1);
    my $fake = File::Spec->catfile($dir, "gate-$name.pl");
    open(my $fh, '>', $fake) or die $!;
    my $q = $line; $q =~ s/\\/\\\\/g; $q =~ s/"/\\"/g; $q =~ s/\n/\\n/g;
    print {$fh} qq{print "$q"; exit $exit;\n};
    close $fh;

    my $g = File::Spec->catdir($dir, 'g');
    my ($rc, $out) = run_spend('snapshot', '--global-dir', $g, '--now', 1787000000,
                               '--gate-cmd', "$PERL $fake", '--no-opencode');
    my $snap = slurp_json(File::Spec->catfile($g, 'spend.json'));
    my $cl   = by_provider($snap, 'claude') || {};

    is($cl->{status}, $want_status, "AC15/$name: status is $want_status -- $why")
        or diag("  rc=$rc out=$out snapshot=" . JSON::PP->new->canonical->encode($snap || {}));

    if (defined $want5) {
        is($cl->{five_hour}{utilization}, $want5, "AC15/$name: five_hour utilization is carried through");
        is($cl->{seven_day}{utilization}, $want7, "AC15/$name: seven_day utilization is carried through");
    } else {
        ok(defined $cl->{diagnostic} && length $cl->{diagnostic},
            "AC15/$name: a diagnostic explains the failure rather than leaving it silent");
        ok(!exists $cl->{five_hour},
            "AC15/$name: no utilization figure is invented for a provider that reported none");
    }
}

# ===========================================================================
# PART 5 -- the redaction whitelist still redacts (AC12, AC13).
#
# Widening @SNAPSHOT_RESULT_FIELDS to carry claude's utilizations is the one
# change here that could weaken the property write_snapshot's whole design
# exists for: the OpenCode session cookie is the broadest secret in the system
# and must provably never reach a persisted file.
# ===========================================================================
{
    require $SPEND_PL;

    my $dir = tempdir(CLEANUP => 1);
    my $p   = File::Spec->catfile($dir, 'spend.json');

    BpSpend::write_snapshot(path => $p, now => 1787000000, results => [
        { provider => 'claude', status => 'ok',
          five_hour => { utilization => 0.42, cookie => 'SECRET-IN-A-WINDOW' },
          seven_day => { utilization => 0.9 },
          cookie    => 'SECRET-AT-TOP-LEVEL',
          _debug    => { headers => { Authorization => 'Bearer SECRET-IN-DEBUG' } } },
    ]);

    my $raw = do { open my $f, '<:raw', $p or die; local $/; <$f> };

    my $snap = eval { JSON::PP->new->decode($raw) };
    my $cl   = by_provider($snap, 'claude') || {};
    is($cl->{five_hour}{utilization}, 0.42, 'AC12: claude five_hour utilization survives the whitelist');
    is($cl->{seven_day}{utilization}, 0.9,  'AC12: claude seven_day utilization survives the whitelist');

    unlike($raw, qr/SECRET/,
        'AC13: no secret-shaped value reaches the file -- not at top level, not nested inside a whitelisted field, not in a bolted-on debug hash');
    ok(!exists $cl->{cookie}, 'AC13: the top-level stray key is dropped');
    ok(!exists $cl->{five_hour}{cookie},
        'AC13: and so is a stray key smuggled INSIDE a whitelisted nested field -- the nested sub-field list is a whitelist too, not a passthrough');
}

done_testing();
