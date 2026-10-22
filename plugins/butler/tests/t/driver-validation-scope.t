#!/usr/bin/env perl
# platform: any
# Oracle for blueprint hook-continuity-remake, package 29 (BP_VALIDATE_LEDGER
# opt-in scoping). Derived from
# .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 29-driver-validation-scope-spec.md sections 2-5 and the package ledger's
# done criteria. The named-ledger resolution behaviour under test
# (_named_validation_ledger, _resolve_named_ledger, and the driver-branch
# integration point) does not exist yet in the guard module at write time:
# every AC below is expected to fail for that reason (missing scoping, not a
# harness defect) until the implementer lands it. Fixture SHAPES (worker
# marker JSON, binding JSON, ledger frontmatter, coordinator marker) are
# copied from interlock-write-set-scope.t's own helpers of the same names,
# which the spec's section 4 names explicitly as the convention to follow --
# never derived from GuardBash.pm's source, which this file's harness never
# reads.
#
# Coordinator review addition: every AC that relies on a fixture's worker
# marker being recognised as "live" now runs
# assert_live_writer_precondition() first, against the SAME fixture with a
# plain command carrying no BP_VALIDATE_LEDGER prefix -- proving the marker
# really is live under today's B-1/B-5 rule (right session_id, fresh mtime,
# writer subagent_type, correct data dir) before the naming-specific
# assertion is judged. AC-3's and AC-2/AC-4's package-name checks were
# audited for a different vacuity: a resolvable BP_VALIDATE_LEDGER value
# necessarily contains its own package/blueprint name, and today's fallback
# deny text echoes the whole input command, so a naive qr/pa-alpha/-style
# match can pass by quoting the input back rather than by testing real
# overlap logic. AC-3's such check was removed (not required by the spec's
# own AC-3 row); AC-2's kept "fx-bp" check (required by the row) carries a
# recorded caveat pointing at the pc-gamma check and the precondition
# control as the real signal. AC-10's two no-writer/allow cases each gained
# a same-fixture, writer-now-present companion that must deny, so "no writer
# -> allow" cannot be mistaken for "always allow".
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname basename);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

my $BUTLER_DIR = dirname(__FILE__) . '/../..';
my $GUARDBASH_MODULE = "$BUTLER_DIR/scripts/BpHook/Guards/GuardBash.pm";

# ---------------------------------------------------------------------------
# fixture packages (spec sec 4, "Fixture packages"). A and C overlap via the
# shared plugins/fx/alpha/ prefix; B is disjoint from both.
# ---------------------------------------------------------------------------
my %PKG = (
    A => { bp => 'fx-bp', pkg => 'pa-alpha', ws => 'plugins/fx/alpha/:plugins/fx/tests/t/alpha.t' },
    B => { bp => 'fx-bp', pkg => 'pb-beta',  ws => 'plugins/fx/beta.pm' },
    C => { bp => 'fx-bp', pkg => 'pc-gamma', ws => 'plugins/fx/alpha/x.pm' },
);
my $ALPHA_T = 'plugins/fx/tests/t/alpha.t';

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
sub tempdir_n {
    my $t = tempdir(CLEANUP => 1);
    (my $n = $t) =~ s{\\}{/}g;
    return $n;
}

sub payload {
    my (%o) = @_;
    my $p = { tool_name => 'Bash', tool_input => { command => $o{cmd} } };
    $p->{session_id}      = $o{session_id}      if exists $o{session_id};
    $p->{agent_id}        = $o{agent_id}         if exists $o{agent_id};
    $p->{transcript_path} = $o{transcript_path}  if exists $o{transcript_path};
    return $p;
}

sub gb {
    my ($p, %env) = @_;
    return GuardHarness::run_module('Guards::GuardBash', $p, env => \%env);
}

# write_worker_marker($data_n, $tuid, %f) -- same shape as
# interlock-write-set-scope.t's helper of the same name.
sub write_worker_marker {
    my ($data_n, $tuid, %f) = @_;
    make_path("$data_n/.drive-solo/workers");
    my $rec = {
        at            => ($f{at} // time()),
        session_id    => $f{session_id},
        subagent_type => $f{subagent_type},
        tool_use_id   => $tuid,
    };
    my $path = "$data_n/.drive-solo/workers/$tuid";
    open(my $fh, '>:raw', $path) or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode($rec) . "\n";
    close $fh;
    if (exists $f{mtime}) { utime($f{mtime}, $f{mtime}, $path) }
    return $path;
}

# write_binding($data_n, $tuid, %f) -- same shape as
# interlock-write-set-scope.t's helper of the same name.
sub write_binding {
    my ($data_n, $tuid, %f) = @_;
    make_path("$data_n/.drive-solo/bindings");
    my $rec = {
        at            => ($f{at} // time()),
        blueprint     => $f{blueprint},
        package       => $f{package},
        session_id    => $f{session_id},
        source        => 'bind-dispatch',
        subagent_type => ($f{subagent_type} // 'bp-test-writer'),
        tool_use_id   => $tuid,
    };
    open(my $fh, '>:raw', "$data_n/.drive-solo/bindings/$tuid.json") or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode($rec) . "\n";
    close $fh;
}

# write_ledger($data_n, $bp, $pkg, $ws_line) -- $ws_line undef omits the
# "write_set:" key entirely (AC-8f); '' writes an empty value.
sub write_ledger {
    my ($data_n, $bp, $pkg, $ws_line) = @_;
    make_path("$data_n/blueprints/$bp/packages");
    my $wsline = defined($ws_line) ? "write_set: $ws_line\n" : '';
    my $content = "---\npackage: $pkg\nblueprint: $bp\nstatus: running\n${wsline}---\n\n# x\n";
    open(my $fh, '>:raw', "$data_n/blueprints/$bp/packages/$pkg.md") or die $!;
    print {$fh} $content;
    close $fh;
}

# write_meta_json($transcript_path, $sid, $aid, $tuid) -- the caller identity
# file, same shape as interlock-write-set-scope.t.
sub write_meta_json {
    my ($transcript_path, $sid, $aid, $tuid) = @_;
    my $dir = dirname($transcript_path) . "/$sid/subagents";
    make_path($dir);
    open(my $fh, '>:raw', "$dir/agent-$aid.meta.json") or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode({ toolUseId => $tuid });
    close $fh;
}

# write_coordinator_marker($bp_dir, $pkg, $content) -- unchanged from
# guards-remake-bash.t's/interlock-write-set-scope.t's own helper of the
# same name.
sub write_coordinator_marker {
    my ($bp_dir, $pkg, $content) = @_;
    make_path("$bp_dir/runs");
    open(my $fh, '>:raw', "$bp_dir/runs/$pkg.active-worker") or die $!;
    print {$fh} $content;
    close $fh;
}

# write_inflight($data_n, [[bp, pkg], ...]) -- the new fixture this package's
# spec adds (sec 4): .drive-solo/inflight.json, decoding to a HASH whose
# "packages" is an ARRAY of { blueprint, package, ledger, since }.
sub write_inflight {
    my ($data_n, $pairs) = @_;
    make_path("$data_n/.drive-solo");
    my @entries = map {
        my ($bp, $pkg) = @$_;
        { blueprint => $bp, package => $pkg, ledger => "$bp/packages/$pkg.md", since => time() }
    } @$pairs;
    my $rec = { packages => \@entries, updated_at => time() };
    open(my $fh, '>:raw', "$data_n/.drive-solo/inflight.json") or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode($rec) . "\n";
    close $fh;
}

# write_inflight_raw($data_n, $bytes) -- a deliberately unparseable
# inflight.json (AC-8d).
sub write_inflight_raw {
    my ($data_n, $bytes) = @_;
    make_path("$data_n/.drive-solo");
    open(my $fh, '>:raw', "$data_n/.drive-solo/inflight.json") or die $!;
    print {$fh} $bytes;
    close $fh;
}

sub setup_pkg_ledger {
    my ($data_n, $key) = @_;
    my $p = $PKG{$key};
    write_ledger($data_n, $p->{bp}, $p->{pkg}, $p->{ws});
}

# setup_a_inflight($data_n) -- A's ledger written and A present in
# inflight.json. The default "A is in flight" fixture the spec's section 4
# says holds "unless a case says otherwise".
sub setup_a_inflight {
    my ($data_n) = @_;
    setup_pkg_ledger($data_n, 'A');
    write_inflight($data_n, [[$PKG{A}{bp}, $PKG{A}{pkg}]]);
}

# named_a_cmd($data_n, $rest) -- the spec sec 4 default named command,
# naming A in its relative form, with $rest appended after "perl".
sub named_a_cmd {
    my ($data_n, $rest) = @_;
    $rest //= $ALPHA_T;
    my $rel = basename($data_n) . "/blueprints/$PKG{A}{bp}/packages/$PKG{A}{pkg}.md";
    return "BP_VALIDATE_LEDGER=$rel perl $rest";
}

sub deny_lines {
    my ($err) = @_;
    my @lines = split /\n/, $err;
    pop @lines while @lines && $lines[-1] eq '';
    return @lines;
}

# assert_live_writer_precondition($data_n, $sid, $label, %o) -- coordinator
# review control. Every AC below that relies on a fixture's worker marker
# actually being recognised as "live" by _gb_d (right session_id, fresh
# mtime, writer subagent_type, correct CCPRAXIS_DATA_DIR) runs this FIRST,
# against the SAME fixture, with a plain command carrying no
# BP_VALIDATE_LEDGER prefix at all (or, for a subagent caller, %o's
# agent_id/transcript_path so the SAME caller identity is used). Today's
# B-1/B-5 rule denies unconditionally whenever a live writer exists, so this
# must be rc 2 on today's code regardless of what the real (named) case
# under test expects -- if it is NOT rc 2, the fixture's "live writer" was
# never live in the first place (wrong session_id, stale mtime, a
# non-writer subagent_type, the wrong data dir, or a payload that does not
# make role() resolve to 'driver'/the intended caller), and whatever the
# real assertion below reports would be vacuous.
sub assert_live_writer_precondition {
    my ($data_n, $sid, $label, %o) = @_;
    my $ctrl_cmd = $o{cmd} // "perl $ALPHA_T";
    my %p = (cmd => $ctrl_cmd, session_id => $sid);
    $p{agent_id}        = $o{agent_id}        if exists $o{agent_id};
    $p{transcript_path} = $o{transcript_path} if exists $o{transcript_path};
    my $res = gb(payload(%p), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 2,
        "$label precondition: same fixture, plain command, no BP_VALIDATE_LEDGER -> deny under "
      . "TODAY's code (the fixture's live writer really is recognised as live)")
        or diag("precondition failed -- rc was $res->{rc}, err was: $res->{err}");
    return $res;
}

# ===========================================================================
# AC-1 -- Named A, live worker bound to B (disjoint) -> rc 0.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac1-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-1 setup: session armed driver');

    setup_a_inflight($data_n);
    setup_pkg_ledger($data_n, 'B');

    my $worker_tuid = 'AC1WORKERB';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-test-writer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-test-writer');

    assert_live_writer_precondition($data_n, $sid, 'AC-1');

    my $res = gb(payload(cmd => named_a_cmd($data_n), session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 0, 'AC-1: driver names A, disjoint live writer in B -> allow');
}

# ===========================================================================
# AC-2 -- Named A, live bp-implementer bound to C (overlap) -> rc 2, naming
# the overlapping package/blueprint, budget-checked.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac2-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-2 setup: session armed driver');

    setup_a_inflight($data_n);
    setup_pkg_ledger($data_n, 'C');

    my $worker_tuid = 'AC2WORKERC';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{C}{bp}, package => $PKG{C}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');

    assert_live_writer_precondition($data_n, $sid, 'AC-2');

    my $res = gb(payload(cmd => named_a_cmd($data_n), session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 2, 'AC-2: driver names A, overlapping live writer in C -> deny');
    like($res->{err}, qr/BLOCKED \(validation interlock\)/, 'AC-2: message carries the validation-interlock label');
    like($res->{err}, qr/pc-gamma/, 'AC-2: message names the overlapping package pc-gamma (never present in the named command, which names pa-alpha -- not an echo of the input)');
    # NOTE (non-vacuity caveat): "fx-bp" is required by the spec's own AC-2
    # row, but every resolvable BP_VALIDATE_LEDGER value necessarily embeds
    # the literal string "blueprints/fx-bp/..." (all three fixture packages
    # share one blueprint), and today's fallback deny text echoes the whole
    # input command ("Not run: <cmd>"). So this one assertion alone would
    # pass even from a pure echo, both today and after the fix -- it is the
    # pc-gamma assertion above (never present in the command) plus the
    # precondition control above that carry the real, non-vacuous signal.
    like($res->{err}, qr/fx-bp/,    'AC-2: message names the blueprint fx-bp');
    my @lines = deny_lines($res->{err});
    cmp_ok(scalar(@lines), '<=', 2, 'AC-2: stderr is at most 2 non-empty lines');
    for my $l (@lines) {
        cmp_ok(length($l), '<=', 160, 'AC-2: each stderr line is at most 160 chars');
    }
}

# ===========================================================================
# AC-3 -- Named A, live writer bound to A itself -> rc 2 (self-overlap).
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac3-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-3 setup: session armed driver');

    setup_a_inflight($data_n);

    my $worker_tuid = 'AC3WORKERA';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{A}{bp}, package => $PKG{A}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');

    assert_live_writer_precondition($data_n, $sid, 'AC-3');

    my $res = gb(payload(cmd => named_a_cmd($data_n), session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 2, 'AC-3: a different worker bound to the named package A -> deny (self-overlap)');
    # No message-content assertion here (the spec's AC-3 row requires only
    # rc 2): the named command's own BP_VALIDATE_LEDGER value necessarily
    # contains the literal string "pa-alpha", and today's fallback deny text
    # echoes the whole input command ("Not run: <cmd>") -- so a
    # qr/pa-alpha/ check on $res->{err} would pass by simply quoting the
    # input back, never by testing that the deny is because of the
    # self-overlap. Asserting it would be pure vacuity; removed rather than
    # kept as a decoration.
}

# ===========================================================================
# AC-4 -- Named A, workers B (name sorts first) and C both live -> rc 2
# naming pc-gamma; a disjoint record does not end the scan.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac4-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-4 setup: session armed driver');

    setup_a_inflight($data_n);
    setup_pkg_ledger($data_n, 'B');
    setup_pkg_ledger($data_n, 'C');

    my $worker_b_tuid = 'AAA4WORKERB';
    write_worker_marker($data_n, $worker_b_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_b_tuid,
        blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');

    my $worker_c_tuid = 'ZZZ4WORKERC';
    write_worker_marker($data_n, $worker_c_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_c_tuid,
        blueprint => $PKG{C}{bp}, package => $PKG{C}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');

    ok(($worker_b_tuid lt $worker_c_tuid), 'AC-4 setup: worker B tuid sorts before worker C tuid');

    assert_live_writer_precondition($data_n, $sid, 'AC-4');

    my $res = gb(payload(cmd => named_a_cmd($data_n), session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 2, 'AC-4: scan continues past the disjoint B record to the overlapping C record -> deny');
    like($res->{err}, qr/pc-gamma/, 'AC-4: message names pc-gamma, not pb-beta');
    unlike($res->{err}, qr/pb-beta/, 'AC-4: message does not name the disjoint pb-beta');
}

# ===========================================================================
# AC-5 -- same fixture as AC-1 (disjoint B live), command without the
# BP_VALIDATE_LEDGER prefix -> rc 2, fallback text (today's behaviour).
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac5-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-5 setup: session armed driver');

    setup_a_inflight($data_n);
    setup_pkg_ledger($data_n, 'B');

    my $worker_tuid = 'AC5WORKERB';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-test-writer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-test-writer');

    my $res = gb(payload(cmd => "perl $ALPHA_T", session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 2, 'AC-5: unnamed command, disjoint live writer still present -> deny (today\'s rule)');
    like($res->{err}, qr/a write-capable worker \(/, 'AC-5: fallback text');
}

# ===========================================================================
# AC-6 -- Named A, disjoint B live; a full-sweep runner invocation (no path
# operand, --fast, or two-or-more path operands), each prefixed -> rc 2 for
# each (S-1: a full sweep denies while any writer is live, named or not).
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac6-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-6 setup: session armed driver');

    setup_a_inflight($data_n);
    setup_pkg_ledger($data_n, 'B');

    my $worker_tuid = 'AC6WORKERB';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');

    assert_live_writer_precondition($data_n, $sid, 'AC-6');

    for my $rest (
        'scripts/run-tests.pl',
        'scripts/run-tests.pl --fast',
        'scripts/run-tests.pl plugins/fx plugins/other',
    ) {
        my $res = gb(payload(cmd => named_a_cmd($data_n, $rest), session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 2, "AC-6: named A, disjoint B live, full sweep '$rest' -> deny (S-1)");
    }
}

# ===========================================================================
# AC-7 -- Named A, disjoint B live, a runner call with exactly one path
# operand -> rc 0 (boundary of S-1: not a full sweep).
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac7-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-7 setup: session armed driver');

    setup_a_inflight($data_n);
    setup_pkg_ledger($data_n, 'B');

    my $worker_tuid = 'AC7WORKERB';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');

    assert_live_writer_precondition($data_n, $sid, 'AC-7');

    my $res = gb(
        payload(cmd => named_a_cmd($data_n, "scripts/run-tests.pl $ALPHA_T"), session_id => $sid),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res->{rc}, 0, 'AC-7: named A, disjoint B live, single path operand -> allow');
}

# ===========================================================================
# AC-8 -- Named but unresolvable, disjoint B live -> rc 2, fallback text, in
# every one of the spec's eleven unresolvable variants.
# ===========================================================================
sub ac8_case {
    my (%o) = @_;
    my $data_n = tempdir_n();
    my $sid = "ac8-$o{label}-sid";
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), "AC-8 ($o{label}) setup: session armed driver");

    setup_pkg_ledger($data_n, 'B');
    my $worker_tuid = "AC8WORKER-$o{label}";
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');

    assert_live_writer_precondition($data_n, $sid, "AC-8 ($o{label})");

    $o{setup}->($data_n) if $o{setup};
    my $cmd = $o{cmd}->($data_n);

    my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 2, "AC-8 ($o{label}): unresolvable name -> deny (fallback)");
    like($res->{err}, qr/a write-capable worker \(/, "AC-8 ($o{label}): fallback text");
}

ac8_case(
    label => 'a-outside-data-dir',
    setup => \&setup_a_inflight,
    cmd   => sub {
        my ($data_n) = @_;
        my $other = tempdir_n();
        return "BP_VALIDATE_LEDGER=$other/blueprints/$PKG{A}{bp}/packages/$PKG{A}{pkg}.md perl $ALPHA_T";
    },
);
ac8_case(
    label => 'b-not-in-inflight',
    setup => sub {
        my ($data_n) = @_;
        write_ledger($data_n, 'fx-bp', 'pz-zeta', 'plugins/fx/zeta.pm');
        setup_a_inflight($data_n);
    },
    cmd => sub {
        my ($data_n) = @_;
        my $rel = basename($data_n) . '/blueprints/fx-bp/packages/pz-zeta.md';
        return "BP_VALIDATE_LEDGER=$rel perl $ALPHA_T";
    },
);
ac8_case(
    label => 'c-no-inflight-file',
    setup => sub { my ($data_n) = @_; setup_pkg_ledger($data_n, 'A') },
    cmd   => sub { my ($data_n) = @_; return named_a_cmd($data_n) },
);
ac8_case(
    label => 'd-inflight-not-json',
    setup => sub {
        my ($data_n) = @_;
        setup_pkg_ledger($data_n, 'A');
        write_inflight_raw($data_n, 'not json');
    },
    cmd => sub { my ($data_n) = @_; return named_a_cmd($data_n) },
);
ac8_case(
    label => 'e-ledger-missing',
    setup => sub {
        my ($data_n) = @_;
        write_inflight($data_n, [[$PKG{A}{bp}, $PKG{A}{pkg}]]);
        # deliberately no ledger file written for fx-bp/pa-alpha.
    },
    cmd => sub { my ($data_n) = @_; return named_a_cmd($data_n) },
);
ac8_case(
    label => 'f-ledger-no-write-set',
    setup => sub {
        my ($data_n) = @_;
        write_ledger($data_n, 'fx-bp', 'pa-alpha', undef);
        write_inflight($data_n, [[$PKG{A}{bp}, $PKG{A}{pkg}]]);
    },
    cmd => sub { my ($data_n) = @_; return named_a_cmd($data_n) },
);
ac8_case(
    label => 'g-expansion-value',
    setup => \&setup_a_inflight,
    cmd   => sub { return "BP_VALIDATE_LEDGER=\$HOME/x.md perl $ALPHA_T" },
);
ac8_case(
    label => 'h-empty-value',
    setup => \&setup_a_inflight,
    cmd   => sub { return "BP_VALIDATE_LEDGER= perl $ALPHA_T" },
);
ac8_case(
    label => 'i-no-shape-match',
    setup => \&setup_a_inflight,
    cmd   => sub { return "BP_VALIDATE_LEDGER=foo.md perl $ALPHA_T" },
);
ac8_case(
    label => 'j-invalid-member-name',
    setup => \&setup_a_inflight,
    cmd   => sub {
        my ($data_n) = @_;
        my $rel = basename($data_n) . '/blueprints/fx-bp/packages/..x.md';
        return "BP_VALIDATE_LEDGER=$rel perl $ALPHA_T";
    },
);
ac8_case(
    label => 'k-duplicate-assignment',
    setup => \&setup_a_inflight,
    cmd   => sub {
        my ($data_n) = @_;
        my $rel = basename($data_n) . '/blueprints/fx-bp/packages/pa-alpha.md';
        return "BP_VALIDATE_LEDGER=$rel BP_VALIDATE_LEDGER=$rel perl $ALPHA_T";
    },
);

# ===========================================================================
# AC-9 -- Named A, a live writer whose own binding is missing -> rc 2
# (B-5 fallback).
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac9-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-9 setup: session armed driver');

    setup_a_inflight($data_n);

    my $worker_tuid = 'AC9WORKER';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    # deliberately no bindings/AC9WORKER.json

    assert_live_writer_precondition($data_n, $sid, 'AC-9');

    my $res = gb(payload(cmd => named_a_cmd($data_n), session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 2, 'AC-9: live writer with no binding file -> deny (B-5 fallback, conservative)');
    like($res->{err}, qr/a write-capable worker \(/, 'AC-9: fallback text');
}

# ===========================================================================
# AC-10 -- no live writer at all (no workers dir) -> rc 0, both when named
# resolvably and when named unresolvably. Unresolvable names never deny on
# their own.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac10a-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-10a setup: session armed driver');
    setup_a_inflight($data_n);
    # deliberately no .drive-solo/workers dir at all.

    my $res = gb(payload(cmd => named_a_cmd($data_n), session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 0, 'AC-10a: named A, no workers dir -> allow');

    # Non-vacuity companion: the SAME data dir and session, with a live
    # writer now added, must deny -- proving AC-10a's allow above is really
    # because no writer exists, not because this fixture always allows.
    # Deliberately an UNNAMED command here (not named_a_cmd()): a disjoint
    # writer bound to B plus a NAMED command is exactly AC-1's shape, which
    # this package's own feature makes ALLOW once implemented -- that would
    # make this companion flip to a false red on a correct implementation,
    # not prove anything. An unnamed command still falls back to today's
    # unconditional B-1 rule (any live writer denies, named or not; see
    # AC-5/AC-11/AC-12), so it stays a deny both before and after the fix.
    setup_pkg_ledger($data_n, 'B');
    my $worker_tuid = 'AC10AWORKER';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');
    my $res_after = gb(payload(cmd => "perl $ALPHA_T", session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res_after->{rc}, 2, 'AC-10a (non-vacuity control): same fixture, a live writer now present, unnamed command -> deny');
}
{
    my $data_n = tempdir_n();
    my $sid = 'ac10b-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-10b setup: session armed driver');
    setup_a_inflight($data_n);
    # deliberately no .drive-solo/workers dir at all.

    my $other = tempdir_n();
    my $cmd = "BP_VALIDATE_LEDGER=$other/blueprints/$PKG{A}{bp}/packages/$PKG{A}{pkg}.md perl $ALPHA_T";
    my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 0, 'AC-10b: named unresolvably, no workers dir -> allow (unresolvable never denies alone)');

    # Non-vacuity companion: same data dir/session, with a live writer now
    # added -- must deny, proving the allow above is really because no
    # writer exists, not because an unresolvable name (or, equally, a plain
    # unnamed command) always allows regardless of live writers. Uses a
    # plain UNNAMED command rather than re-running $cmd or named_a_cmd():
    # a disjoint writer bound to B plus a NAMED-and-resolvable command is
    # AC-1's shape, which this package's own feature makes ALLOW once
    # implemented, so re-using a resolvable name here would flip this
    # companion to a false red on a correct implementation. An unnamed
    # command still falls back to today's unconditional B-1 rule, so it
    # stays a deny both before and after the fix.
    setup_pkg_ledger($data_n, 'B');
    my $worker_tuid = 'AC10BWORKER';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');
    my $res_after = gb(payload(cmd => "perl $ALPHA_T", session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res_after->{rc}, 2, 'AC-10b (non-vacuity control): same fixture, a live writer now present, unnamed command -> deny');
}

# ===========================================================================
# AC-11 -- AC-5's fixture, harness env ALSO sets BP_VALIDATE_LEDGER to A's
# valid path (never on the command) -> rc 2 (the hook process's own %ENV is
# never consulted for the name).
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac11-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-11 setup: session armed driver');

    setup_a_inflight($data_n);
    setup_pkg_ledger($data_n, 'B');

    my $worker_tuid = 'AC11WORKERB';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-test-writer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-test-writer');

    my $rel = basename($data_n) . "/blueprints/$PKG{A}{bp}/packages/$PKG{A}{pkg}.md";
    my $res = gb(
        payload(cmd => "perl $ALPHA_T", session_id => $sid),
        CCPRAXIS_DATA_DIR => $data_n,
        BP_VALIDATE_LEDGER => $rel,
    );
    is($res->{rc}, 2, 'AC-11: BP_VALIDATE_LEDGER set in the hook env but not on the command -> treated as unnamed -> deny');
    like($res->{err}, qr/a write-capable worker \(/, 'AC-11: fallback text (env value never consulted)');
}

# ===========================================================================
# AC-12 -- AC-1's fixture, the assignment not at the leading position
# ("true &&" / "env ") -> rc 2 for each (treated as unnamed).
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac12-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-12 setup: session armed driver');

    setup_a_inflight($data_n);
    setup_pkg_ledger($data_n, 'B');

    my $worker_tuid = 'AC12WORKERB';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-test-writer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-test-writer');

    my $rel = basename($data_n) . "/blueprints/$PKG{A}{bp}/packages/$PKG{A}{pkg}.md";
    for my $cmd (
        "true && BP_VALIDATE_LEDGER=$rel perl $ALPHA_T",
        "env BP_VALIDATE_LEDGER=$rel perl $ALPHA_T",
    ) {
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 2, "AC-12: non-leading assignment '$cmd' -> treated as unnamed -> deny");
        like($res->{err}, qr/a write-capable worker \(/, "AC-12: fallback text for '$cmd'");
    }
}

# ===========================================================================
# AC-13 -- AC-1's fixture, the value accepted in every quoting/separator
# form the spec lists -> rc 0 for each.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac13-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-13 setup: session armed driver');

    setup_a_inflight($data_n);
    setup_pkg_ledger($data_n, 'B');

    my $worker_tuid = 'AC13WORKERB';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-test-writer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-test-writer');

    assert_live_writer_precondition($data_n, $sid, 'AC-13');

    my $rel = basename($data_n) . "/blueprints/$PKG{A}{bp}/packages/$PKG{A}{pkg}.md";
    my $abs = "$data_n/blueprints/$PKG{A}{bp}/packages/$PKG{A}{pkg}.md";
    (my $bs_abs = $abs) =~ s{/}{\\}g;

    my @cases = (
        [ "BP_VALIDATE_LEDGER=$abs perl $ALPHA_T"          => 'absolute unquoted form' ],
        [ "BP_VALIDATE_LEDGER='$rel' perl $ALPHA_T"        => 'single-quoted value' ],
        [ qq{BP_VALIDATE_LEDGER="$rel" perl $ALPHA_T}      => 'double-quoted value, no expansion' ],
        [ "BP_VALIDATE_LEDGER='$bs_abs' perl $ALPHA_T"     => 'backslash-separated absolute form (single-quoted)' ],
        [ "FOO=1 BP_VALIDATE_LEDGER=$rel perl $ALPHA_T"    => 'after another leading assignment' ],
    );
    for my $c (@cases) {
        my ($cmd, $label) = @$c;
        my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
        is($res->{rc}, 0, "AC-13 ($label): resolves to A, disjoint B live -> allow") or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-13f -- only when $data_n matches ^([A-Za-z]):/, the "/<letter>/..." POSIX
# form of the absolute path is also accepted -> rc 0. Skipped otherwise.
# ===========================================================================
SKIP: {
    my $data_n = tempdir_n();
    my $sid = 'ac13f-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-13f setup: session armed driver');

    skip('AC-13f: data dir is not drive-letter-absolute on this host', 1)
        unless $data_n =~ m{^([A-Za-z]):/};
    my $letter = lc($1);
    (my $rest = $data_n) =~ s{^[A-Za-z]:}{};

    setup_a_inflight($data_n);
    setup_pkg_ledger($data_n, 'B');

    my $worker_tuid = 'AC13FWORKERB';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-test-writer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-test-writer');

    assert_live_writer_precondition($data_n, $sid, 'AC-13f');

    my $val = "/$letter$rest/blueprints/$PKG{A}{bp}/packages/$PKG{A}{pkg}.md";
    my $cmd = "BP_VALIDATE_LEDGER=$val perl $ALPHA_T";
    my $res = gb(payload(cmd => $cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 0, 'AC-13f: POSIX drive-letter form of the absolute path resolves -> allow') or diag("cmd: $cmd");
}

# ===========================================================================
# AC-14 -- a subagent caller bound to A whose command names B's ledger (B in
# flight), with a live writer overlapping A but disjoint from B -> rc 2. Its
# own binding governs; BP_VALIDATE_LEDGER cannot rescope it.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac14-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-14 setup: session armed driver');

    setup_pkg_ledger($data_n, 'A');
    setup_pkg_ledger($data_n, 'B');
    setup_pkg_ledger($data_n, 'C');
    write_inflight($data_n, [[$PKG{A}{bp}, $PKG{A}{pkg}], [$PKG{B}{bp}, $PKG{B}{pkg}]]);

    my $caller_tuid = 'AC14CALLER';
    write_binding($data_n, $caller_tuid,
        blueprint => $PKG{A}{bp}, package => $PKG{A}{pkg}, session_id => $sid);

    my $worker_tuid = 'AC14WORKERC';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{C}{bp}, package => $PKG{C}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');

    my $transcript = "$data_n/transcript.jsonl";
    write_meta_json($transcript, $sid, 'AC14AID', $caller_tuid);

    assert_live_writer_precondition($data_n, $sid, 'AC-14',
        agent_id => 'AC14AID', transcript_path => $transcript);

    my $rel_b = basename($data_n) . "/blueprints/$PKG{B}{bp}/packages/$PKG{B}{pkg}.md";
    my $cmd = "BP_VALIDATE_LEDGER=$rel_b perl $ALPHA_T";
    my $res = gb(
        payload(cmd => $cmd, session_id => $sid, agent_id => 'AC14AID', transcript_path => $transcript),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res->{rc}, 2, 'AC-14: subagent bound to A names B, but its own binding (overlapping C) governs -> deny');
}

# ===========================================================================
# AC-15 -- AC-1's fixture plus a fresh coordinator tree marker
# (blueprints/<bp>/runs/<p>.active-worker) -> rc 2 with the tree-interlock
# text, unaffected by the driver naming A.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac15-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-15 setup: session armed driver');

    setup_a_inflight($data_n);
    setup_pkg_ledger($data_n, 'B');

    my $worker_tuid = 'AC15WORKERB';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-test-writer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-test-writer');

    assert_live_writer_precondition($data_n, $sid, 'AC-15');

    write_coordinator_marker("$data_n/blueprints/$PKG{A}{bp}", 'px', 'bp-implementer');

    my $res = gb(payload(cmd => named_a_cmd($data_n), session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res->{rc}, 2, 'AC-15: fresh coordinator tree marker present -> deny');
    like($res->{err}, qr/BLOCKED \(tree interlock\)/, 'AC-15: message carries the tree-interlock label');
    like($res->{err}, qr/not a reason to park or block/, 'AC-15: message says waiting is not a reason to park');
}

# ===========================================================================
# AC-16 -- Named A, overlapping C live, a "perl -c" syntax check -> rc 0
# (Decision 92's exemption stays independent of naming).
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac16-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-16 setup: session armed driver');

    setup_a_inflight($data_n);
    setup_pkg_ledger($data_n, 'C');

    my $worker_tuid = 'AC16WORKERC';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid,
        blueprint => $PKG{C}{bp}, package => $PKG{C}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');

    assert_live_writer_precondition($data_n, $sid, 'AC-16');

    my $res = gb(
        payload(cmd => named_a_cmd($data_n, 'perl -c plugins/fx/alpha/a.pm'), session_id => $sid),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res->{rc}, 0, 'AC-16: named A, overlapping C live, but "perl -c ..." stays exempt -> allow');
}

# ===========================================================================
# AC-17 -- source pin: GuardBash.pm never reads $ENV{BP_VALIDATE_LEDGER}. The
# name comes only from the command text.
# ===========================================================================
{
    ok(-f $GUARDBASH_MODULE, "AC-17 setup: $GUARDBASH_MODULE exists on disk");
    open(my $fh, '<', $GUARDBASH_MODULE) or die "cannot read $GUARDBASH_MODULE: $!";
    local $/;
    my $src = <$fh>;
    close $fh;
    unlike($src, qr/\$ENV\{\s*['"]?BP_VALIDATE_LEDGER['"]?\s*\}/,
        'AC-17: GuardBash.pm source contains no $ENV{BP_VALIDATE_LEDGER} read');
}

done_testing();
