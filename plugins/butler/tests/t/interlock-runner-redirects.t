#!/usr/bin/env perl
# platform: any
# Oracle for blueprint hook-continuity-remake, package 34-runner-redirect-
# operands (Decisions 112/113). Derived from .ccpraxis-local-data/blueprints/
# hook-continuity-remake/specs/34-runner-redirect-operands-spec.md sections
# 2-5 and the package ledger's done criteria (DC1-DC6). _blank_data_heredocs
# does NOT exist yet in the guard module at write time, and today's
# _is_full_sweep_runner/_validation_shaped have the three bugs the spec
# describes (redirects counted as operands, heredoc bodies matched as
# commands, no per-line/per-invocation classification) -- every AC below
# that exercises the fix is expected to FAIL for that reason (missing/wrong
# behaviour, not a harness defect) until the implementer lands it. Fixture
# SHAPES (worker marker JSON, binding JSON, ledger frontmatter, inflight.json)
# are copied from interlock-write-set-scope.t and driver-validation-scope.t,
# which the spec's section 4 names explicitly as the fixture vocabulary to
# reuse -- never derived from GuardBash.pm's source, which this file's
# harness never reads for its own logic (only the two named private subs are
# called directly, exactly as the spec's section 4 instructs).
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
# fixture packages (same vocabulary as interlock-write-set-scope.t /
# driver-validation-scope.t). A and C overlap via the shared plugins/fx/
# alpha/ prefix; B is disjoint from both.
# ---------------------------------------------------------------------------
my %PKG = (
    A => { bp => 'fx-bp', pkg => 'pa-alpha', ws => 'plugins/fx/alpha/:plugins/fx/tests/t/alpha.t' },
    B => { bp => 'fx-bp', pkg => 'pb-beta',  ws => 'plugins/fx/beta.pm' },
    C => { bp => 'fx-bp', pkg => 'pc-gamma', ws => 'plugins/fx/alpha/x.pm' },
);
my $ALPHA_T = 'plugins/fx/tests/t/alpha.t';
my $RUNNER  = 'scripts/run-tests.pl';

# ---------------------------------------------------------------------------
# helpers (copied shapes -- see file header)
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

sub write_ledger {
    my ($data_n, $bp, $pkg, $ws_line) = @_;
    make_path("$data_n/blueprints/$bp/packages");
    my $wsline = defined($ws_line) ? "write_set: $ws_line\n" : '';
    my $content = "---\npackage: $pkg\nblueprint: $bp\nstatus: running\n${wsline}---\n\n# x\n";
    open(my $fh, '>:raw', "$data_n/blueprints/$bp/packages/$pkg.md") or die $!;
    print {$fh} $content;
    close $fh;
}

sub write_meta_json {
    my ($transcript_path, $sid, $aid, $tuid) = @_;
    my $dir = dirname($transcript_path) . "/$sid/subagents";
    make_path($dir);
    open(my $fh, '>:raw', "$dir/agent-$aid.meta.json") or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode({ toolUseId => $tuid });
    close $fh;
}

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

sub setup_pkg_ledger {
    my ($data_n, $key) = @_;
    my $p = $PKG{$key};
    write_ledger($data_n, $p->{bp}, $p->{pkg}, $p->{ws});
}

sub setup_a_inflight {
    my ($data_n) = @_;
    setup_pkg_ledger($data_n, 'A');
    write_inflight($data_n, [[$PKG{A}{bp}, $PKG{A}{pkg}]]);
}

# named_a_cmd($data_n, $rest) -- BP_VALIDATE_LEDGER=<A ledger, relative>
# leading word, same convention as driver-validation-scope.t's helper of
# the same name.
sub named_a_cmd {
    my ($data_n, $rest) = @_;
    my $rel = basename($data_n) . "/blueprints/$PKG{A}{bp}/packages/$PKG{A}{pkg}.md";
    return "BP_VALIDATE_LEDGER=$rel perl $rest";
}

# ---------------------------------------------------------------------------
# fixture builders for the two-caller (subagent / driver) shape reused across
# many ACs below: A is the caller's own package, B is a live, disjoint
# write-capable worker (bp-implementer) in the same session.
# ---------------------------------------------------------------------------
sub setup_subagent_vs_disjoint_b {
    my ($label) = @_;
    my $data_n = tempdir_n();
    my $sid = "$label-sid";
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), "$label setup: session armed driver");
    setup_pkg_ledger($data_n, 'A');
    setup_pkg_ledger($data_n, 'B');
    my $caller_tuid = "$label-CALLER";
    write_binding($data_n, $caller_tuid, blueprint => $PKG{A}{bp}, package => $PKG{A}{pkg}, session_id => $sid);
    my $worker_tuid = "$label-WORKERB";
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid, blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');
    my $transcript = "$data_n/transcript.jsonl";
    write_meta_json($transcript, $sid, "$label-AID", $caller_tuid);
    return { data_n => $data_n, sid => $sid, transcript => $transcript, aid => "$label-AID" };
}

sub subagent_result {
    my ($fx, $cmd) = @_;
    return gb(
        payload(cmd => $cmd, session_id => $fx->{sid}, agent_id => $fx->{aid}, transcript_path => $fx->{transcript}),
        CCPRAXIS_DATA_DIR => $fx->{data_n},
    );
}

sub setup_driver_vs_disjoint_b {
    my ($label) = @_;
    my $data_n = tempdir_n();
    my $sid = "$label-sid";
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), "$label setup: session armed driver");
    setup_a_inflight($data_n);
    setup_pkg_ledger($data_n, 'B');
    my $worker_tuid = "$label-WORKERB";
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid, blueprint => $PKG{B}{bp}, package => $PKG{B}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');
    return { data_n => $data_n, sid => $sid };
}

sub driver_result {
    my ($fx, $rest) = @_;
    my $cmd = named_a_cmd($fx->{data_n}, $rest);
    return gb(payload(cmd => $cmd, session_id => $fx->{sid}), CCPRAXIS_DATA_DIR => $fx->{data_n});
}

# named_a_cmd_raw($data_n, $rest) -- like named_a_cmd, but $rest already
# includes its own leading "perl" text (used for AC-23's multi-invocation
# commands, where the "perl" belongs to the FIRST runner call only).
sub named_a_cmd_raw {
    my ($data_n, $rest) = @_;
    my $rel = basename($data_n) . "/blueprints/$PKG{A}{bp}/packages/$PKG{A}{pkg}.md";
    return "BP_VALIDATE_LEDGER=$rel $rest";
}

# _slugify($label) -- lower-cased, non-alnum squashed to "-", for building a
# short, filesystem/tuid-safe fixture label out of an arbitrary test label.
sub _slugify {
    my ($s) = @_;
    (my $v = lc($s // '')) =~ s/[^a-z0-9]+/-/g;
    $v =~ s/^-+|-+$//g;
    return $v;
}

sub assert_full_sweep_deny {
    my ($res, $pkgname, $bpname, $label) = @_;
    is($res->{rc}, 2, "$label: rc 2 (full sweep denied)");
    my $line1 = 'BLOCKED (validation interlock): a multi-file or full sweep reads every '
        . 'in-flight worker\'s files, so it is denied while any write-capable worker is live.';
    like($res->{err}, qr/\Q$line1\E/, "$label: exact full-sweep line (AC-6)");
    like($res->{err},
        qr/^Live writer: bp-implementer, package \Q$pkgname\E of blueprint \Q$bpname\E\. Name exactly one test file to get write-set scoping instead\.$/m,
        "$label: live-writer line names $pkgname/$bpname (AC-6)");
    unlike($res->{err}, qr/overlap/, "$label: full-sweep text never says 'overlap' (AC-6)");
}

# setup_subagent_vs_overlapping_c($label) -- same shape as
# setup_subagent_vs_disjoint_b, but the live writer is bound to C, which
# OVERLAPS the caller's own package A (spec/AC-7's fixture). Reused by the
# Decision-115 M-1/M-2 assertions below, which only need "denied because a
# live writer overlaps", not any particular deny-text shape.
sub setup_subagent_vs_overlapping_c {
    my ($label) = @_;
    my $data_n = tempdir_n();
    my $sid = "$label-sid";
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), "$label setup: session armed driver");
    setup_pkg_ledger($data_n, 'A');
    setup_pkg_ledger($data_n, 'C');
    my $caller_tuid = "$label-CALLER";
    write_binding($data_n, $caller_tuid, blueprint => $PKG{A}{bp}, package => $PKG{A}{pkg}, session_id => $sid);
    my $worker_tuid = "$label-WORKERC";
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid, blueprint => $PKG{C}{bp}, package => $PKG{C}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');
    my $transcript = "$data_n/transcript.jsonl";
    write_meta_json($transcript, $sid, "$label-AID", $caller_tuid);
    return { data_n => $data_n, sid => $sid, transcript => $transcript, aid => "$label-AID" };
}

# ===========================================================================
# bootstrap: load BpHook::Guards::GuardBash exactly once, through the SAME
# require-by-relative-path GuardHarness::run_module always uses, so every
# later direct call to a private sub below sees the one-and-only loaded copy
# (never a second require under a different %INC key, which would re-run
# the module's own BEGIN block and print "subroutine redefined" warnings
# into a later gb() call's captured stderr).
# ===========================================================================
{
    GuardHarness::fresh_state();
    ok(GuardHarness::arm('bootstrap-sid', 'driver'), 'bootstrap: session armed driver');
    my $boot = gb(payload(cmd => 'echo bootstrap'), session_id => 'bootstrap-sid');
    ok(defined $boot, 'bootstrap: GuardBash module loaded via GuardHarness::run_module');
}

my $has_blank = defined &BpHook::Guards::GuardBash::_blank_data_heredocs;
ok($has_blank, 'setup: BpHook::Guards::GuardBash::_blank_data_heredocs exists')
    or diag('not yet implemented -- every AC below calling it directly fails for that reason');

sub fsr { return BpHook::Guards::GuardBash::_is_full_sweep_runner($_[0]) ? 1 : 0 }
sub vshaped { return BpHook::Guards::GuardBash::_validation_shaped($_[0]) ? 1 : 0 }
sub blank { return $has_blank ? BpHook::Guards::GuardBash::_blank_data_heredocs($_[0]) : undef }

# ===========================================================================
# AC-1 (DC1) -- redirects/redirect combos never count as path operands.
# ===========================================================================
{
    my $base = "perl $RUNNER $ALPHA_T";
    my @suffixes = (
        '> out.txt', '>out.txt', '>> out.txt', '>>out.txt', '2> err.txt', '2>err.txt',
        '2>/dev/null', '2>> err.txt', '< /dev/null', '</dev/null', '2>&1', '1>&2', '>&2',
        '> out.txt 2>&1', '&> out.txt', '&>out.txt', '&>> out.txt', '>| out.txt',
        '> out.txt 2>&1 | tail -5', '2>&1 &',
    );
    for my $suf (@suffixes) {
        my $cmd = "$base $suf";
        is(fsr($cmd), 0, "AC-1: '$suf' suffix -> not a full sweep");
    }
    is(fsr("perl $RUNNER 2>/dev/null $ALPHA_T"), 0, 'AC-1: redirect BEFORE the operand -> not a full sweep');
}

# ===========================================================================
# AC-2 (DC1) -- subagent path: single-file + redirect -> allow.
# ===========================================================================
{
    my $fx = setup_subagent_vs_disjoint_b('ac2');
    for my $suf ('> out.txt 2>&1', '2>/dev/null', '&> out.txt', '< /dev/null') {
        my $cmd = "perl $RUNNER $ALPHA_T $suf";
        my $res = subagent_result($fx, $cmd);
        is($res->{rc}, 0, "AC-2: subagent, '$suf' -> allow");
    }
}

# ===========================================================================
# AC-3 (DC1) -- driver path (BP_VALIDATE_LEDGER): single-file + redirect ->
# allow.
# ===========================================================================
{
    my $fx = setup_driver_vs_disjoint_b('ac3');
    for my $suf ('> out.txt 2>&1', '2>/dev/null', '&> out.txt', '< /dev/null') {
        my $res = driver_result($fx, "$RUNNER $ALPHA_T $suf");
        is($res->{rc}, 0, "AC-3: driver, '$suf' -> allow");
    }
}

# ===========================================================================
# AC-4 (DC2) -- no operand, --fast, or 2+ operands (any redirects) is a full
# sweep.
# ===========================================================================
my @AC4_SUFFIXES = (
    '> out.txt 2>&1',
    '--fast > out.txt 2>&1',
    '--fast 2>&1 | tail -5',
    'plugins/fx plugins/other > out.txt',
    'plugins/fx 2>/dev/null plugins/other',
    'plugins/fx &> log plugins/other',
);
{
    for my $suf (@AC4_SUFFIXES) {
        my $cmd = "perl $RUNNER $suf";
        is(fsr($cmd), 1, "AC-4: '$suf' -> full sweep");
    }
}

# ===========================================================================
# AC-5 (DC2) + AC-6 (DC3) -- every AC-4 command denies on both paths, with
# the exact full-sweep text.
# ===========================================================================
{
    my $fx_sub = setup_subagent_vs_disjoint_b('ac56sub');
    for my $suf (@AC4_SUFFIXES) {
        my $cmd = "perl $RUNNER $suf";
        my $res = subagent_result($fx_sub, $cmd);
        assert_full_sweep_deny($res, $PKG{B}{pkg}, $PKG{B}{bp}, "AC-5/6 (subagent, '$suf')");
    }
    my $fx_drv = setup_driver_vs_disjoint_b('ac56drv');
    for my $suf (@AC4_SUFFIXES) {
        my $res = driver_result($fx_drv, "$RUNNER $suf");
        assert_full_sweep_deny($res, $PKG{B}{pkg}, $PKG{B}{bp}, "AC-5/6 (driver, '$suf')");
    }
}

# ===========================================================================
# AC-7 (DC3) -- overlapping live writer keeps the unchanged overlap text,
# even for a full-sweep command against the SAME writer.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac7-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-7 setup: session armed driver');
    setup_pkg_ledger($data_n, 'A');
    setup_pkg_ledger($data_n, 'C');
    my $caller_tuid = 'AC7CALLER';
    write_binding($data_n, $caller_tuid, blueprint => $PKG{A}{bp}, package => $PKG{A}{pkg}, session_id => $sid);
    my $worker_tuid = 'AC7WORKERC';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');
    write_binding($data_n, $worker_tuid, blueprint => $PKG{C}{bp}, package => $PKG{C}{pkg}, session_id => $sid, subagent_type => 'bp-implementer');
    my $transcript = "$data_n/transcript.jsonl";
    write_meta_json($transcript, $sid, 'AC7AID', $caller_tuid);

    my $res1 = gb(
        payload(cmd => "perl $RUNNER $ALPHA_T", session_id => $sid, agent_id => 'AC7AID', transcript_path => $transcript),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res1->{rc}, 2, 'AC-7: overlapping writer, single-file call -> deny');
    # The byte-identical text spec sec 2.4 pins is the line BEFORE it passes
    # through Common::fit (still unchanged per spec sec 2.4's own table) --
    # fit() truncates anything over 160 chars, and this fixture's own
    # package/blueprint/role names put the full line at 188 chars. Pinning
    # the fit()-transformed line (rather than shortening the fixture names,
    # which would stop exercising the real deny-text length this guard
    # actually produces in practice) keeps the assertion exact without
    # weakening it.
    my $overlap_line_full = "BLOCKED (validation interlock): package $PKG{C}{pkg} of blueprint $PKG{C}{bp} has a "
        . 'write-capable worker (bp-implementer) in flight whose write set overlaps yours; this run could report a false red.';
    my $overlap_line = BpHook::Guards::Common::fit($overlap_line_full);
    like($res1->{err}, qr/\Q$overlap_line\E/, 'AC-7: exact overlap line (post-fit, per spec sec 2.4)');
    # 2026-10-22: a coordinator given only the line above parked its package
    # as awaiting a human; the refusal now says what to do instead.
    like($res1->{err}, qr/not a reason to park or block/,
        'overlap refusal tells the caller to wait, not to park');

    my $res2 = gb(
        payload(cmd => "perl $RUNNER --fast", session_id => $sid, agent_id => 'AC7AID', transcript_path => $transcript),
        CCPRAXIS_DATA_DIR => $data_n,
    );
    is($res2->{rc}, 2, 'AC-7: overlapping writer, --fast -> deny');
    like($res2->{err}, qr/\Q$overlap_line\E/, 'AC-7: --fast against overlapping writer -> overlap text (not full-sweep)');
    unlike($res2->{err}, qr/multi-file or full sweep/, 'AC-7: --fast against overlapping writer -> no full-sweep line');
}

# ===========================================================================
# AC-8 (DC4) -- _blank_data_heredocs blanks only body lines; the opener and
# terminator lines, and the line count, are unchanged.
# ===========================================================================
{
    my @cases = (
        [ "cat > f <<WORD\nperl t/x.t\nWORD\n",   "cat > f <<WORD\n\nWORD\n",   'bare <<WORD' ],
        [ "cat > f <<'WORD'\nperl t/x.t\nWORD\n", "cat > f <<'WORD'\n\nWORD\n", "<<'WORD'" ],
        [ "cat > f <<\"WORD\"\nperl t/x.t\nWORD\n", "cat > f <<\"WORD\"\n\nWORD\n", '<<"WORD"' ],
        [ "cat > f << WORD\nperl t/x.t\nWORD\n",  "cat > f << WORD\n\nWORD\n",  '<< WORD (spaced)' ],
        [ "cat > f <<\\WORD\nperl t/x.t\nWORD\n", "cat > f <<\\WORD\n\nWORD\n", '<<\\WORD' ],
        [ "cat > f <<-WORD\n\tperl t/x.t\n\tWORD\n", "cat > f <<-WORD\n\n\tWORD\n", '<<-WORD (dash, tab-stripped terminator)' ],
    );
    for my $c (@cases) {
        my ($input, $expected, $label) = @$c;
        my $got = blank($input);
        is($got, $expected, "AC-8: $label -- body blanked, opener/terminator/line-count unchanged")
            or diag("input: " . ($input // '<undef>') . "\ngot: " . (defined $got ? $got : '<undef>'));
    }
}

# ===========================================================================
# AC-9 (DC4) -- two heredocs, consumed in opening order; non-body lines
# (including a later run-tests.pl mention buried in the SECOND body) are
# untouched.
# ===========================================================================
{
    my $input = "cat <<A >a; cat <<'B' >b\nperl t/x.t\nA\nperl scripts/run-tests.pl\nB\necho done";
    my $expected = "cat <<A >a; cat <<'B' >b\n\nA\n\nB\necho done";
    is(blank($input), $expected, 'AC-9: two heredocs opened on one line -- both bodies blanked in order, echo done left intact');

    my $input2 = "cmd <<A <<B\nbody-A\nA\nbody-B\nB";
    my $expected2 = "cmd <<A <<B\n\nA\n\nB";
    is(blank($input2), $expected2, 'AC-9: cmd <<A <<B (two bodies, same opening line) behaves the same');
}

# ===========================================================================
# AC-10 (DC4) -- unterminated heredocs are failure-safe (unchanged); a
# terminated-then-unterminated pair blanks only the terminated one; an
# unterminated body with a backtick is still validation-shaped.
# ===========================================================================
{
    my $c1 = "cat > f <<'EOF'\nperl t/x.t\n";
    is(blank($c1), $c1, 'AC-10: no terminator line at all -> unchanged');

    my $c2 = "cat > f <<'EOF'\nperl t/x.t\nEOFX";
    is(blank($c2), $c2, 'AC-10: terminator line does not match the word exactly (EOFX vs EOF) -> unchanged');

    my $c3 = "cat > f <<'EOF'\n" . "\x60perl t/x.t\x60" . "\n";
    is(vshaped($c3), 1, 'AC-10: unterminated heredoc with a backtick body -> still validation-shaped');

    my $c4 = "cat <<A >a; cat <<B >b\nbody1\nA\nbody2";
    my $expected4 = "cat <<A >a; cat <<B >b\n\nA\nbody2";
    is(blank($c4), $expected4, 'AC-10: first heredoc terminated (blanked), second unterminated (left as-is)');
}

# ===========================================================================
# AC-11 (DC4) -- a command whose only validation-looking text is inside a
# DATA heredoc body is not validation-shaped.
# ===========================================================================
{
    my @bodies = (
        [ "Run \x60perl scripts/run-tests.pl --fast\x60 before merging." => 'backtick body' ],
        [ 'see $(perl scripts/run-tests.pl)'                            => 'command-substitution body' ],
        [ q{use perl -e 'x' then perl t/x.t}                            => 'perl -e mention body' ],
        [ 'eval perl t/x.t'                                             => 'eval mention body' ],
        [ q{bash -c 'perl t/x.t'}                                       => 'bash -c mention body' ],
    );
    for my $b (@bodies) {
        my ($body, $label) = @$b;
        my $cmd = "cat > f <<'EOF'\n$body\nEOF";
        is(vshaped($cmd), 0, "AC-11: quoted heredoc body ($label) -> not validation-shaped");
    }

    {
        my $body = $bodies[0][0];
        my $cmd = "cat > f <<'EOF'\n$body\nEOF";
        local $ENV{BP_GUARD_MAX_STRIP_BYTES} = '10';
        is(vshaped($cmd), 0, 'AC-11: backtick body, over-cap (BP_GUARD_MAX_STRIP_BYTES small) -> still not validation-shaped');
    }

    for my $b (@bodies[2, 3, 4]) {
        my ($body, $label) = @$b;
        my $cmd = "cat > f <<EOF\n$body\nEOF";
        is(vshaped($cmd), 0, "AC-11: unquoted heredoc, body without backtick/\$( ($label) -> not validation-shaped");
    }
}

# ===========================================================================
# AC-12 (DC4) -- a command line that itself runs a test stays
# validation-shaped, whether or not a heredoc is also present.
# ===========================================================================
{
    my @cases = (
        "perl t/x.t <<EOF\nhello\nEOF",
        "perl t/x.t <<'EOF'\nhello\nEOF",
        "cat > f <<'EOF' && perl t/x.t\nsome \x60prose\x60\nEOF",
        "cat > f <<'EOF'\nsome \x60prose\x60\nEOF\nperl scripts/run-tests.pl",
    );
    for my $cmd (@cases) {
        is(vshaped($cmd), 1, "AC-12: opening/other command line runs a test -> validation-shaped (cmd: $cmd)");
    }
}

# ===========================================================================
# AC-13 (DC4, DC5) -- a non-data heredoc (D1 or D2 fails) is left unchanged
# by _blank_data_heredocs and stays validation-shaped.
# ===========================================================================
{
    my @cases = (
        [ "cat <<EOF\n\$(perl t/x.t)\nEOF"              => 'unquoted heredoc, body has $( (D1 fails)' ],
        [ "cat <<EOF\n\x60perl t/x.t\x60\nEOF"           => 'unquoted heredoc, body has a backtick (D1 fails)' ],
        [ "bash <<'EOF'\n\x60x\x60 perl t/x.t\nEOF"       => 'quoted heredoc, but command text has "bash" (D2 fails)' ],
        [ "cat <<'EOF' | bash\n\x60x\x60 perl t/x.t\nEOF" => 'quoted heredoc, command text has "bash" via pipe (D2 fails)' ],
    );
    for my $c (@cases) {
        my ($cmd, $label) = @$c;
        is(blank($cmd), $cmd, "AC-13: $label -> _blank_data_heredocs unchanged");
        is(vshaped($cmd), 1, "AC-13: $label -> still validation-shaped");
    }
}

# ===========================================================================
# AC-14 (DC4, end to end) -- driver main thread, live writer present:
# the AC-11 backtick-body command is allowed; the un-heredoc'd control (a
# real invocation on the opening line) is denied.
# ===========================================================================
{
    my $data_n = tempdir_n();
    my $sid = 'ac14-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-14 setup: session armed driver');
    my $worker_tuid = 'AC14WORKER';
    write_worker_marker($data_n, $worker_tuid, session_id => $sid, subagent_type => 'bp-implementer');

    my $allow_cmd = "cat > f <<'EOF'\n"
        . "Run \x60perl scripts/run-tests.pl --fast\x60 before merging.\nEOF";
    my $res_allow = gb(payload(cmd => $allow_cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res_allow->{rc}, 0, 'AC-14: driver main thread, live writer present, data-heredoc body -> allow');

    my $control_cmd = "perl t/x.t <<'EOF'\n\x60x\x60\nEOF";
    my $res_control = gb(payload(cmd => $control_cmd, session_id => $sid), CCPRAXIS_DATA_DIR => $data_n);
    is($res_control->{rc}, 2, 'AC-14 (control): a real invocation on the opening line -> deny');
}

# ===========================================================================
# AC-15 (DC4) -- here-strings, quoted "<<", bit-shift, and a shell comment
# never look like a heredoc opener.
# ===========================================================================
{
    my @cases = (
        [ "cat <<<\"perl t/x.t\"\nperl t/x.t"        => 'here-string (<<<)' ],
        [ "echo \"<<EOF\"\nperl t/x.t\nEOF"          => '<<EOF inside double quotes' ],
        [ "echo \$((1 << 2))\nperl t/x.t"            => 'bit-shift operator' ],
        [ "echo hi # <<EOF\nperl t/x.t\nEOF"         => '<<EOF inside a shell comment' ],
    );
    for my $c (@cases) {
        my ($cmd, $label) = @$c;
        is(blank($cmd), $cmd, "AC-15: $label -> no heredoc opener recognised, unchanged");
    }
}

# ===========================================================================
# AC-16 (DC5) -- identity for commands with no "<<"; undef/'' round-trip
# without warnings or death.
# ===========================================================================
{
    is(blank("perl $RUNNER"), "perl $RUNNER", 'AC-16: no "<<" in the command -> identity');
    is(blank(''), '', 'AC-16: empty string -> identity');

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $u = eval { blank(undef) };
    my $died = $@;
    ok(!$died, 'AC-16: undef input never dies') or diag("died: $died");
    is($u, undef, 'AC-16: undef input -> undef output');
    is(scalar(@warnings), 0, 'AC-16: undef input -> no warnings');
}

# ===========================================================================
# AC-17 (DC5) -- existing interlock/hook-core tests keep passing.
# Review M-4 (34-review.md) / Decision 115: a test file that spawns sibling
# .t files violates Decision 11 ("a test never runs a test") and is exactly
# what turns plugins/butler/tests/t/tests-never-run-tests.t red. The five
# regression files this AC named are evidence the driver already gathers by
# running the full sweep itself -- recorded in the package ledger, not
# re-run from inside this file.
# ===========================================================================

# ===========================================================================
# AC-18 (DC6, multi-line) -- a runner not on the last line, or joined by a
# backslash-newline continuation, is still classified correctly.
# ===========================================================================
{
    is(fsr("echo start\nperl $RUNNER --fast"), 1, 'AC-18: --fast, not on the last line -> full sweep');
    is(fsr("perl $RUNNER\necho done"), 1, 'AC-18: no operand, not on the last line -> full sweep');
    is(fsr("echo start\nperl $RUNNER plugins/fx plugins/other\necho done"), 1,
        'AC-18: two operands, middle line -> full sweep');
    is(fsr("echo start\nperl $RUNNER $ALPHA_T\necho done"), 0,
        'AC-18: single-file, middle line -> not a full sweep');
    is(fsr("perl $RUNNER \\\n  $ALPHA_T"), 0,
        'AC-18: backslash-newline continuation, single file -> not a full sweep');
    is(fsr("perl $RUNNER plugins/fx \\\n  plugins/other"), 1,
        'AC-18: backslash-newline continuation, two operands -> full sweep');
}

# ===========================================================================
# AC-19 (DC6, every invocation) -- the command is a full sweep if ANY
# invocation, in any separator-delimited segment on any line, is one.
# ===========================================================================
{
    is(fsr("perl $RUNNER $ALPHA_T && perl $RUNNER"), 1,
        'AC-19: first invocation single-file, second invocation bare -> full sweep');
    is(fsr("perl $RUNNER $ALPHA_T; perl $RUNNER --fast"), 1,
        'AC-19: ";"-separated, second invocation --fast -> full sweep');
    is(fsr("perl $RUNNER $ALPHA_T > out.txt 2>&1 || perl $RUNNER a.t b.t"), 1,
        'AC-19: "||"-separated, second invocation two operands -> full sweep');
    is(fsr("perl $RUNNER $ALPHA_T\nperl $RUNNER --fast"), 1,
        'AC-19: newline-separated, second invocation --fast -> full sweep');
    is(fsr("perl $RUNNER $ALPHA_T && perl $RUNNER plugins/fx/tests/t/beta.t"), 0,
        'AC-19 (control): two single-file invocations -> not a full sweep');
}

# ===========================================================================
# AC-20 (DC6, redirect target is not an invocation).
# ===========================================================================
{
    is(fsr("perl t/x.t > scripts/run-tests.pl"), 0, 'AC-20: runner path only as a ">" redirect target -> not an invocation');
    is(fsr("perl t/x.t 2>run-tests.pl.log"), 0, 'AC-20: runner-ish name as an attached "2>" target -> not an invocation');
    is(fsr("perl t/x.t >> logs/run-tests.pl.out 2>&1"), 0, 'AC-20: runner-ish name inside a ">>" target path -> not an invocation');
    is(fsr("perl $RUNNER $ALPHA_T > run-tests.pl.log"), 0,
        'AC-20: real single-file invocation PLUS a runner-ish redirect target -> still not a full sweep');
    is(fsr("perl t/x.t > out.txt"), 0, 'AC-20: no runner at all -> not an invocation');
}

# ===========================================================================
# AC-21 (DC6, data heredoc body is not an invocation).
# ===========================================================================
{
    my $c1 = "cat > f <<'EOF'\nperl $RUNNER --fast\nEOF\nperl $RUNNER $ALPHA_T";
    is(fsr($c1), 0, 'AC-21: --fast invocation only inside a data heredoc body -> not counted; remaining single-file invocation -> not a full sweep');

    my $c2 = "bash <<'EOF'\nperl $RUNNER --fast\nEOF";
    is(fsr($c2), 1, 'AC-21: --fast invocation inside a NON-data heredoc body (fed to a shell) -> counted -> full sweep');

    my $c3 = "cat > f <<'EOF'\nperl $RUNNER --fast\n";
    is(fsr($c3), 1, 'AC-21: unterminated heredoc -> fails safe -- body counted as command text -> full sweep');
}

# ===========================================================================
# AC-22 (DC6, today's tail semantics preserved).
# ===========================================================================
{
    is(fsr(q{perl t/x.t --note "see scripts/run-tests.pl"}), 0,
        'AC-22: quoted mention, trailing quote remainder counts as ONE operand (today\'s tail semantics) -> not a full sweep');
    is(fsr('timeout 3600 perl scripts/run-tests.pl'), 1,
        'AC-22: "timeout N perl scripts/run-tests.pl" with no operand -> full sweep');
}

# ===========================================================================
# AC-23 (DC6, DC3, end to end).
# ===========================================================================
{
    my $fx = setup_driver_vs_disjoint_b('ac23a');
    my $res1 = gb(
        payload(cmd => named_a_cmd_raw($fx->{data_n}, "perl $RUNNER $ALPHA_T > out.txt 2>&1 && perl $RUNNER --fast"), session_id => $fx->{sid}),
        CCPRAXIS_DATA_DIR => $fx->{data_n},
    );
    assert_full_sweep_deny($res1, $PKG{B}{pkg}, $PKG{B}{bp}, 'AC-23 (driver, redirected first + --fast second)');

    my $fx2 = setup_driver_vs_disjoint_b('ac23b');
    my $res2 = gb(
        payload(cmd => named_a_cmd_raw($fx2->{data_n}, "perl $RUNNER $ALPHA_T\nperl $RUNNER"), session_id => $fx2->{sid}),
        CCPRAXIS_DATA_DIR => $fx2->{data_n},
    );
    assert_full_sweep_deny($res2, $PKG{B}{pkg}, $PKG{B}{bp}, 'AC-23 (driver, newline-separated, second bare)');

    my $fx3 = setup_subagent_vs_disjoint_b('ac23c');
    my $cmd3 = "cat > f <<'EOF'\nperl $RUNNER --fast\nEOF\nperl $RUNNER $ALPHA_T";
    my $res3 = subagent_result($fx3, $cmd3);
    is($res3->{rc}, 0, 'AC-23 (subagent): --fast only inside a data heredoc body, real invocation is single-file -> allow');
}

# ===========================================================================
# M-1 (review 34-review.md; Decision 115, supersedes 114) -- Decision 114's
# bounded D2 window (stop scanning at the last heredoc terminator) reopens
# the exact stdin/eval consumers D2 exists to catch: a command-substitution
# heredoc later eval'd from a variable, a `read` heredoc later eval'd from a
# variable, and a heredoc body piped into a shell. Each of these commands
# must be VALIDATION-SHAPED -- and, against a live writer whose write set
# OVERLAPS the caller's own (setup_subagent_vs_overlapping_c), denied -- even
# though the runner mention is inside a heredoc body, because the body is
# genuinely executed as a command by the statement that follows it.
# ===========================================================================
{
    my @cases = (
        [ "x=\$(cat <<'EOF'\nperl $RUNNER --fast\nEOF\n); eval \"\$x\""
            => 'command-substitution heredoc captured then eval\'d' ],
        [ "read -r -d '' x <<'EOF'\nperl $RUNNER --fast\nEOF\neval \"\$x\""
            => 'read heredoc captured then eval\'d' ],
        [ "cat <<'EOF' | bash\nperl $RUNNER --fast\nEOF"
            => 'heredoc body piped into bash' ],
    );
    for my $c (@cases) {
        my ($cmd, $label) = @$c;
        is(vshaped($cmd), 1, "M-1: $label -> validation-shaped (cmd: $cmd)");
        my $fx = setup_subagent_vs_overlapping_c('m1-' . _slugify($label));
        my $res = subagent_result($fx, $cmd);
        is($res->{rc}, 2, "M-1: $label, overlapping live writer -> deny");
    }
}

# ===========================================================================
# M-2 (review 34-review.md; Decision 115) -- a quoted heredoc delimiter
# containing "-" or "." (still legal per the OPENER grammar) must not hide a
# real test line that follows the terminator. Each of these is a file write
# followed by a real test run and must be VALIDATION-SHAPED / denied against
# an overlapping live writer.
# ===========================================================================
{
    my @cases = (
        [ "cat > f <<'END-DOC'\nprose \x60x\x60\nEND-DOC\nperl $RUNNER --fast"
            => 'quoted delimiter with a hyphen (END-DOC)' ],
        [ "cat > f <<'EOF.md'\nprose \x60x\x60\nEOF.md\nperl t/x.t"
            => 'quoted delimiter with a dot (EOF.md)' ],
    );
    for my $c (@cases) {
        my ($cmd, $label) = @$c;
        is(vshaped($cmd), 1, "M-2: $label -> validation-shaped (cmd: $cmd)");
        my $fx = setup_subagent_vs_overlapping_c('m2-' . _slugify($label));
        my $res = subagent_result($fx, $cmd);
        is($res->{rc}, 2, "M-2: $label, overlapping live writer -> deny");
    }
}

# ===========================================================================
# M-3 (review 34-review.md; Decision 115) -- a redirect glued directly to the
# runner token ("run-tests.pl&>log") must still be dropped, exactly like a
# spaced one; all three run a full sweep.
# ===========================================================================
{
    for my $c (
        [ "perl $RUNNER&>log"  => 'glued &>' ],
        [ "perl $RUNNER>log"   => 'glued >' ],
        [ "perl $RUNNER>|log"  => 'glued >|' ],
    ) {
        my ($cmd, $label) = @$c;
        is(fsr($cmd), 1, "M-3: $label -- glued redirect on the runner token -> full sweep (cmd: $cmd)");
    }
}

# ===========================================================================
# S-3 (review 34-review.md; Decision 115) -- an unrecognised "<<WORD" opener
# (here, a quoted delimiter containing a space, which the OPENER grammar
# does not accept) must fail safe: the text after it is never blanked, so it
# still counts as ordinary command text (and a real runner line inside it is
# still classified as an invocation).
# ===========================================================================
{
    my $cmd = "cat <<'END DOC'\nperl $RUNNER --fast\nEND DOC";
    is(blank($cmd), $cmd, 'S-3: unrecognised opener (quoted delimiter with a space) -> body never blanked, kept as command text');
    is(fsr($cmd), 1, 'S-3: the real runner line inside that unblanked text is still classified as a full-sweep invocation');
}

done_testing();
