#!/usr/bin/env perl
# t02-spend-persistence — the sandbox-side oracle for blueprint tui-operator-feedback.
#
# Closes half of the operator's second complaint, verbatim: "the claude spend
# says 'no snapshot' and 'no active run to report spend for'".
#
# THE DEFECT THIS FILE EXISTS FOR (blueprint Decision 10) is not that spend is
# never written -- it is that THE WRITER AND THE READER DISAGREE ON THE FORMAT.
# BpSpend::write_snapshot emits an ARRAY under `results`, each element keyed by
# a `provider` FIELD. SpendPanel::status indexes its argument by provider KEY.
# launcher.pl's _gather_spend hands the decoded file straight in with no
# translation, so a snapshot carrying REAL figures renders as absent. That was
# true for the fleet path too, which is why "spend has never been persisted"
# was an incomplete diagnosis: persistence alone would not have worked.
#
# Conventions honoured from this suite (t/44's header states them):
#   * launcher.pl is NEVER require'd -- source-text slurp + regex only, plus
#     `perl -c` in a subprocess. PART 3's assertions are therefore WEAKER than
#     PART 1/2's and are labelled as such rather than dressed up as behaviour.
#   * pure logic under test lives in a real module (SpendPanel.pm) precisely so
#     it CAN be called.
#   * no real clock -- `now` is always supplied.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use JSON::PP;

my $SCRIPTS_DIR   = "$Bin/../../scripts";
my $LAUNCHER_PATH = "$SCRIPTS_DIR/launcher.pl";

my $SP_OK = eval { require SpendPanel;            1 };
my $DS_OK = eval { require tui::DashboardScreen;  1 };
ok($SP_OK, 'SpendPanel.pm loads')                or diag("  require failed: $@");
ok($DS_OK, 'tui/DashboardScreen.pm loads')       or diag("  require failed: $@");

my $LSRC = do { local $/; open(my $fh, '<', $LAUNCHER_PATH) or die "open $LAUNCHER_PATH: $!"; <$fh> };
ok(length($LSRC) > 0, 'launcher.pl was read as source text');

# The exact bytes BpSpend::write_snapshot produces, hand-written here rather
# than generated, so this file states the writer's contract independently
# instead of agreeing with whatever the writer currently happens to do.
my $WRITER_FORMAT = {
    generated_at => '2026-08-17T20:53:20Z',
    results      => [
        { provider => 'go',     status => 'ok', five_hour => { used => 42,  limit => 100 },
                                                weekly    => { used => 300, limit => 1000 } },
        { provider => 'zen',    status => 'ok', balance => '12.34', budget => '50.00' },
        { provider => 'claude', status => 'ok', five_hour => { utilization => 0.42 },
                                                seven_day => { utilization => 0.9 } },
    ],
};

# ===========================================================================
# PART 1 -- SpendPanel::from_snapshot: the translation that was designed and
# never built. SpendPanel.pm's own header already names the intended composer
# ("composed by launcher.pl from BpSpend::fetch() for go/zen, and from
# bp-usage-gate.pl's own $parsed for claude"), so this is the missing piece of
# a stated design, not a new one.
# ===========================================================================
my $HAS_ADAPTER = $SP_OK && SpendPanel->can('from_snapshot') ? 1 : 0;
ok($HAS_ADAPTER, 'SpendPanel::from_snapshot exists');

# The remainder of PART 1 is gated on the sub EXISTING, not merely on the
# module loading. Without the gate a missing sub aborts the file at the first
# unguarded call and every later assertion -- including the ones that would
# tell a reader WHAT is wrong -- never runs. A red file should still say
# everything it knows.
SKIP: {
    skip 'SpendPanel::from_snapshot is not implemented', 15 unless $HAS_ADAPTER;

    my $spend = eval { SpendPanel::from_snapshot($WRITER_FORMAT) };
    is(ref($spend), 'HASH', 'AC1: from_snapshot returns a hash for a writer-format snapshot')
        or diag("  died: $@");

    SKIP: {
        skip 'no hash returned', 5 unless ref($spend) eq 'HASH';
        is(ref($spend->{go}),  'HASH', 'AC1: go is reachable by KEY, which is what status() indexes');
        is(ref($spend->{zen}), 'HASH', 'AC1: zen is reachable by key');
        is($spend->{go}{five_hour}{used},  42,      'AC1: go figures survive the translation intact');
        is($spend->{zen}{balance},         '12.34', 'AC1: zen figures survive the translation intact');
        is($spend->{claude}{five_hour}{utilization}, 0.42, 'AC1: claude utilizations survive the translation intact');
    }

    # THE END-TO-END PROOF, and the assertion this whole package turns on.
    # Before the adapter these same figures produced go=absent, zen=disabled,
    # claude=unreadable -- verified from disk, and indistinguishable from
    # "nothing was ever fetched".
    my $info = eval { SpendPanel::status(SpendPanel::from_snapshot($WRITER_FORMAT), 1787000000) };
    SKIP: {
        skip 'status() did not return', 3 unless ref($info) eq 'HASH';
        is($info->{go}{state},     'ok', 'AC1: real go figures render as ok, not absent');
        is($info->{zen}{state},    'ok', 'AC1: real zen figures render as ok, not disabled');
        is($info->{claude}{state}, 'ok', 'AC1: real claude figures render as ok, not unreadable');
    }

    # AC2 -- an unrecognised provider is DROPPED, never guessed at. A snapshot
    # written by a newer bp-spend.pl must not be able to inject a key here.
    my $odd = SpendPanel::from_snapshot({ results => [
        { provider => 'go', status => 'ok' },
        { provider => 'gemini', status => 'ok' },
        { status => 'ok' },                       # no provider at all
    ] });
    ok(!exists $odd->{gemini}, 'AC2: an unrecognised provider is dropped rather than carried through');
    is(scalar(grep { $_ ne 'zen_enabled' } keys %$odd), 1,
        'AC2: only the recognised provider survives -- a result with no provider adds nothing');

    # AC3 -- a provider ABSENT from results must be ABSENT from the output.
    # Materialising it as {} would be a different statement: status() reads a
    # missing key and a present-but-empty hash differently, and an empty hash
    # says "we looked and found nothing" where undef says "we never looked".
    my $partial = SpendPanel::from_snapshot({ results => [ { provider => 'go', status => 'ok' } ] });
    ok(!exists $partial->{zen},    'AC3: a provider missing from results is not materialised as an empty hash');
    ok(!exists $partial->{claude}, 'AC3: the same for claude');

    # AC4 -- zen_enabled. This key never appears in the persisted format, and
    # defaulting it to 0 renders a successfully-fetched zen as `disabled`,
    # which is exactly the wrong word for "we have figures".
    is(SpendPanel::from_snapshot({ results => [ { provider => 'zen', status => 'ok' } ] })->{zen_enabled}, 1,
        'AC4: a non-absent zen result enables the zen meter');
    is(SpendPanel::from_snapshot({ results => [ { provider => 'zen', status => 'absent' } ] })->{zen_enabled}, 0,
        'AC4: an absent zen result leaves it disabled');
    is(SpendPanel::from_snapshot({ results => [] })->{zen_enabled}, 0,
        'AC4: no zen result at all leaves it disabled');
}

# ===========================================================================
# PART 2 -- totality. SpendPanel.pm's contract is "never dies on any input",
# and from_snapshot is on the render path, so a die here blanks the dashboard
# rather than one field.
# ===========================================================================
SKIP: {
    skip 'SpendPanel::from_snapshot is not implemented', 5 unless $HAS_ADAPTER;

    for my $bad (undef, 'nonsense', [], { results => 'not-an-array' }, { results => [ 'scalar' ] }) {
        my $label = !defined $bad ? 'undef' : (ref($bad) ? (ref($bad) . ' ' . encode_json_safe($bad)) : "'$bad'");
        my $got = eval { SpendPanel::from_snapshot($bad) };
        is(ref($got), 'HASH', "AC5: malformed input ($label) yields a hash rather than dying");
    }
}

sub encode_json_safe {
    my ($v) = @_;
    my $s = eval { JSON::PP->new->canonical->encode($v) };
    return defined $s ? $s : '?';
}

# ===========================================================================
# PART 3 -- launcher wiring. SOURCE-TEXT ASSERTIONS ONLY. This suite never
# require's launcher.pl, so these establish that the code says the right thing,
# not that it does it. Stated plainly rather than implied.
# ===========================================================================
like($LSRC, qr/SpendPanel::from_snapshot/,
    'AC10 (source-text): _gather_spend translates the persisted snapshot instead of passing it straight to status()');
like($LSRC, qr/_spend_global_snapshot|global_dir|spend_sampler/,
    'AC11 (source-text): a run-independent spend path exists, so the panel is not empty whenever no fleet run is active');
like($LSRC, qr/spend_sampler_forked/,
    'AC12 (source-text): the spend sampler fork event is named for what a fork establishes -- a process exists');
unlike($LSRC, qr/log_ev\(\s*'spend_sampler_started'/,
    'AC12 (source-text): and NOT for what it does not establish. t01 renamed resources_sampler_started for this exact reason; the identical mistake is available here in the identical shape');
# Named for the SPEND sampler specifically. The first draft of this check
# allowed `sampler_start_outcome` as an alternative and passed immediately --
# on t01's RESOURCES sampler, which this package does not touch. An assertion
# satisfied by code the package did not write proves nothing about it.
like($LSRC, qr/spend_sampler_start_failed/,
    'AC17 (source-text): a spend sampler that fails to fork has its reason carried outward, not logged and discarded');

my $out = `perl -c "$LAUNCHER_PATH" 2>&1`;
like($out, qr/syntax OK/, 'AC18: launcher.pl still compiles');

# ===========================================================================
# PART 4 -- Decision 2: no colon in any value text this package introduces.
# ===========================================================================
SKIP: {
    skip 'tui/DashboardScreen.pm did not load', 1 unless $DS_OK;

    # The fallback sentence "no active run to report spend for" is REMOVED by
    # this package (spec S5.2): under Decision 11 it describes a state that is
    # no longer the reason the panel is empty.
    my $DSRC = do { local $/; open(my $fh, '<', "$SCRIPTS_DIR/tui/DashboardScreen.pm") or die $!; <$fh> };
    unlike($DSRC, qr/'no active run to report spend for'/,
        'AC13: the run-shaped fallback sentence is gone -- it named the wrong absence');
}

done_testing();
