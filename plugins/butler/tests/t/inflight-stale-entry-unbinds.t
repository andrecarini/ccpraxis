#!/usr/bin/env perl
# platform: any
# Regression for bug 20261104-164548-2d3a: once every blueprint was done,
# bp-drive-next.pl never wrote its inflight.json prune back (only the
# hand-out block did), so a finished package stayed in the set forever.
# BpHook::BindDispatch then bound every later dispatch to that single entry,
# and BpHook::WriteGuards refused every edit those subagents made
# (refused_bound) -- including unrelated ad-hoc work after the run. The
# binding record outlives the set, so emptying the file by hand did not
# release the subagents already dispatched.
#
# Pins:
#   D1  `next` returning done writes the pruned set back: a terminal entry is
#       gone from inflight.json afterwards, and a live entry is kept.
#   B1  a dispatch made while the ONLY in-flight entry is terminal gets no
#       binding, and its writes are judged as unbound (no in-flight work, so
#       no package scope): resolve() is undef and an edit is allowed.
#   B2  the same for an entry whose blueprint is parked, and for an entry
#       whose ledger is gone.
#   B3  an explicit "Ledger:" line naming the terminal package is still bound
#       to it and still refused (Decision 69 A3 is kept).
#   B4  an unbound subagent with a parked-blueprint entry as the only member
#       is not scoped to it (WriteGuards' own count ignores the entry).
#   B5  control: a live sole entry is still bound and scoped, as before.
#
# Runs standalone: perl plugins/butler/tests/t/inflight-stale-entry-unbinds.t
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path remove_tree);
use JSON::PP ();
use Cwd ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

my $J   = JSON::PP->new->utf8->canonical;
my $NOW = 1_830_297_600;

(my $TEST_DIR = Cwd::abs_path(dirname(__FILE__))) =~ s{\\}{/}g;
my $SCRIPT = "$TEST_DIR/../../scripts/bp-drive-next.pl";

# The guard cases need a project root OUTSIDE the temp dir: WriteGuards
# allows every subagent to write under temp, which would make an
# "edit allowed" assertion pass for the wrong reason. Same idiom as
# guards-per-subagent.t: a scratch dir beside this file, removed at END.
my $SCRATCH_ROOT = "$TEST_DIR/.scratch-inflight-stale-$$";
make_path($SCRATCH_ROOT);
my $SEQ = 0;
END { remove_tree($SCRATCH_ROOT, { safe => 1 }) if defined $SCRATCH_ROOT && -d $SCRATCH_ROOT }

# ---------------------------------------------------------------------------
# IO helpers
# ---------------------------------------------------------------------------
sub write_bytes {
    my ($path, $bytes) = @_;
    (my $dir = $path) =~ s{[/\\][^/\\]*\z}{};
    make_path($dir) if length($dir) && !-d $dir;
    open(my $fh, '>:raw', $path) or die "cannot write $path: $!";
    print {$fh} $bytes;
    close $fh;
}
sub read_bytes {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub write_json { my ($p, $d) = @_; write_bytes($p, $J->encode($d) . "\n") }
sub read_json  { my $r = read_bytes($_[0]); return defined $r ? eval { $J->decode($r) } : undef }

sub write_blueprint {
    my ($data, $bp, $status) = @_;
    my $fence = chr(96) x 3;
    write_bytes("$data/blueprints/$bp/blueprint.md",
        "# $bp\n\n$fence\nblueprint: $bp\ncreated: 2028-01-01\n"
      . "last_updated: 2028-01-01T00:00:00Z\nstatus: $status\n$fence\n\n## Objective\n\nfixture\n\n"
      . "## Package status\n\n| pkg | deliverable | depends_on | model |\n|-----|-----|-----|-----|\n\n"
      . "## Harvest log\n\n## Incidents\n");
}
sub write_ledger {
    my ($data, $bp, $pkg, $status, $ws) = @_;
    write_bytes("$data/blueprints/$bp/packages/$pkg.md",
        "---\npackage: $pkg\nblueprint: $bp\nstatus: $status\nwrite_set: $ws\ntest_paths: t/$pkg/\n"
      . "last_updated: 2028-01-01T00:00:00Z\n---\n\n## Next action\n\nx\n\n## Decisions & attempt log\n\nx\n\n"
      . "## Pipeline\n\nx\n\n## Outputs\n\nx\n\n## Escalation\n\nx\n");
}
sub write_inflight {
    my ($data, @members) = @_;
    write_json("$data/.drive-solo/inflight.json", {
        packages => [ map { { blueprint => $_->[0], package => $_->[1], ledger => 'x', since => 1 } } @members ],
        updated_at => 1,
    });
}
sub inflight_pairs {
    my ($data) = @_;
    my $s = read_json("$data/.drive-solo/inflight.json");
    return undef unless ref $s eq 'HASH' && ref $s->{packages} eq 'ARRAY';
    return [ sort map { "$_->{blueprint}/$_->{package}" } @{ $s->{packages} } ];
}

# ===========================================================================
# D1: the director writes its prune back on the done path.
# ===========================================================================
{
    my $loaded = do { local $@; my $ok = eval { require $SCRIPT; 1 }; diag("require bp-drive-next.pl: $@") unless $ok; $ok };
    ok($loaded, 'D1 setup: bp-drive-next.pl loads');

    SKIP: {
        skip 'D1: bp-drive-next.pl did not load', 5 unless $loaded;

        my $data = tempdir(CLEANUP => 1);
        $data =~ s{\\}{/}g;
        # B: the finished blueprint whose package the set still lists.
        write_blueprint($data, 'B', 'audited');
        write_ledger($data, 'B', 'p1', 'done', 'src/b/');
        # C: out of scope, with a running package -- a LIVE entry the prune
        # must keep (the prune is project-level, not scope-level).
        write_blueprint($data, 'C', 'audited');
        write_ledger($data, 'C', 'q1', 'running', 'src/c/');
        my $dsdir = "$data/.drive-solo";
        make_path($dsdir);
        write_json("$dsdir/order.json",     { order => ['B'], recorded_at => $NOW });
        write_json("$dsdir/announced.json", { announced => ['B'] });
        write_inflight($data, [ 'B', 'p1' ], [ 'C', 'q1' ]);

        my ($ofh, $opath) = tempfile('isu-outXXXXXX', TMPDIR => 1); close $ofh;
        my ($efh, $epath) = tempfile('isu-errXXXXXX', TMPDIR => 1); close $efh;
        open my $oldout, '>&STDOUT' or die "dup STDOUT: $!";
        open my $olderr, '>&STDERR' or die "dup STDERR: $!";
        open STDOUT, '>:raw', $opath or die "reopen STDOUT: $!";
        open STDERR, '>:raw', $epath or die "reopen STDERR: $!";
        my $rc = eval {
            BpDrive::run([ 'next', '--scope', 'B' ], {
                data_dir             => $data,
                now                  => sub { $NOW },
                verdict              => sub { { action => 'ok' } },
                spawn                => sub { },
                kill_pid             => sub { },
                powershell_available => sub { 0 },
            });
        };
        my $err = $@;
        open STDOUT, '>&', $oldout or die "restore STDOUT: $!"; close $oldout;
        open STDERR, '>&', $olderr or die "restore STDERR: $!"; close $olderr;
        my $out = read_bytes($opath) // '';
        unlink $opath, $epath;

        is($err, '', 'D1: next does not die');
        is($rc, 0, 'D1: next exits 0');
        chomp(my $line = $out);
        my $act = eval { $J->decode($line) } || {};
        is($act->{action}, 'done', 'D1: next returns done (every blueprint in scope is finished)');
        my $pairs = inflight_pairs($data);
        ok(ref $pairs eq 'ARRAY' && !grep({ $_ eq 'B/p1' } @$pairs),
            'D1: the terminal entry B/p1 is gone from inflight.json after a done call')
            or diag('inflight.json: ' . (read_bytes("$dsdir/inflight.json") // '<missing>'));
        is_deeply($pairs, ['C/q1'], 'D1: the live entry C/q1 is kept');
    }
}

# ===========================================================================
# Guard fixtures
# ===========================================================================
my $REQUIRE_OK = eval { require "BpHook/WriteGuards.pm"; 1 };
ok($REQUIRE_OK, 'guard setup: BpHook::WriteGuards loads') or diag($@);

# guard_fixture(%o) -> { R, D, X, sid }. A project root outside temp, an
# armed driver session, and an empty inflight set the case fills in.
sub guard_fixture {
    my $R = "$SCRATCH_ROOT/proj-" . (++$SEQ);
    my $D = "$R/.ccpraxis-local-data";
    make_path("$D/.drive-solo/bindings", "$D/blueprints");
    my $sid = "isu-sid-$SEQ";
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my $X = "$R-transcripts";
    make_path("$X/$sid/subagents");
    return { R => $R, D => $D, X => $X, sid => $sid };
}
sub env_for {
    my ($fx) = @_;
    return { CCPRAXIS_DATA_DIR => $fx->{D}, TMPDIR => undef, TEMP => undef, TMP => undef,
             LOCALAPPDATA => undef, BP_PROJECT_ROOT => undef, CLAUDE_PROJECT_DIR => undef };
}
sub dispatch {
    my ($fx, $tuid, $prompt) = @_;
    my $p = { hook_event_name => 'PreToolUse', tool_name => 'Agent', session_id => $fx->{sid},
              tool_use_id => $tuid, cwd => $fx->{R},
              tool_input => { subagent_type => 'general-purpose', prompt => $prompt // 'Fix an unrelated typo.' } };
    return GuardHarness::run_module('BindDispatch', $p, env => env_for($fx));
}
sub binding_of {
    my ($fx, $tuid) = @_;
    return read_json("$fx->{D}/.drive-solo/bindings/$tuid.json");
}
# a subagent write payload; $tuid undef = a subagent with no meta.json at all
sub sub_write {
    my ($fx, $aid, $tuid, $rel) = @_;
    write_json("$fx->{X}/$fx->{sid}/subagents/agent-$aid.meta.json", { toolUseId => $tuid }) if defined $tuid;
    return { hook_event_name => 'PreToolUse', tool_name => 'Write', session_id => $fx->{sid},
             agent_id => $aid, agent_type => 'general-purpose',
             transcript_path => "$fx->{X}/$fx->{sid}.jsonl", cwd => $fx->{R},
             tool_input => { file_path => "$fx->{R}/$rel", content => "x\n" } };
}
sub wg_writes { my ($fx, $p) = @_; return GuardHarness::run_module('WriteGuards', $p, env => env_for($fx), args => ['writes']) }
sub wg_resolve {
    my ($fx, $payload) = @_;
    return undef unless $REQUIRE_OK;
    my $env = env_for($fx);
    local %ENV = %ENV;
    for my $k (keys %$env) { if (defined $env->{$k}) { $ENV{$k} = $env->{$k} } else { delete $ENV{$k} } }
    BpHook::load_payload($J->encode($payload));
    return eval { BpHook::WriteGuards::resolve(BpHook::payload()) };
}
sub ledger_line { my ($fx, $bp, $pkg) = @_; return ".ccpraxis-local-data/blueprints/$bp/packages/$pkg.md" }

# ===========================================================================
# B1: the only in-flight entry is terminal -> no binding, writes judged as
# unbound. Before the fix: bound to bpx/p9, then refused_bound.
# ===========================================================================
{
    my $fx = guard_fixture();
    write_blueprint($fx->{D}, 'bpx', 'audited');
    write_ledger($fx->{D}, 'bpx', 'p9', 'done', 'src/p9/');
    write_inflight($fx->{D}, [ 'bpx', 'p9' ]);

    my $r = dispatch($fx, 'toolu_b1');
    is($r->{rc}, 0, 'B1: the dispatch is allowed');
    ok(!-e "$fx->{D}/.drive-solo/bindings/toolu_b1.json",
        'B1: no binding is recorded for a dispatch made while the only in-flight entry is terminal')
        or diag('binding: ' . (read_bytes("$fx->{D}/.drive-solo/bindings/toolu_b1.json") // ''));

    my $w = sub_write($fx, 'b1aaa', 'toolu_b1', 'tools/unrelated.pl');
    my $res = wg_resolve($fx, $w);
    ok(!defined $res, 'B1: the subagent resolves as unbound with nothing in flight (no guard scope)')
        or diag('resolve kind: ' . (ref $res eq 'HASH' ? ($res->{kind} // '?') : '?'));
    my $wr = wg_writes($fx, $w);
    is($wr->{rc}, 0, 'B1: its edit of an unrelated project file is allowed');
    unlike($wr->{err} // '', qr/bound to package/, 'B1: no "bound to package" refusal');
}

# ===========================================================================
# B2: parked blueprint, and a missing ledger -- also never auto-bound.
# ===========================================================================
{
    my $fx = guard_fixture();
    write_blueprint($fx->{D}, 'bpp', 'parked');
    write_ledger($fx->{D}, 'bpp', 'p1', 'running', 'src/p1/');
    write_inflight($fx->{D}, [ 'bpp', 'p1' ]);
    my $r = dispatch($fx, 'toolu_b2a');
    is($r->{rc}, 0, 'B2(parked): the dispatch is allowed');
    ok(!-e "$fx->{D}/.drive-solo/bindings/toolu_b2a.json",
        'B2(parked): no binding to a package of a parked blueprint');

    my $fx2 = guard_fixture();
    write_blueprint($fx2->{D}, 'bpg', 'audited');
    make_path("$fx2->{D}/blueprints/bpg/packages");
    write_inflight($fx2->{D}, [ 'bpg', 'p-gone' ]);
    my $r2 = dispatch($fx2, 'toolu_b2b');
    is($r2->{rc}, 0, 'B2(no ledger): the dispatch is allowed');
    ok(!-e "$fx2->{D}/.drive-solo/bindings/toolu_b2b.json",
        'B2(no ledger): no binding to a package whose ledger is gone');
}

# ===========================================================================
# B3: an explicit Ledger: line naming the terminal package is still bound
# and still refused (Decision 69 A3).
# ===========================================================================
{
    my $fx = guard_fixture();
    write_blueprint($fx->{D}, 'bpx', 'audited');
    write_ledger($fx->{D}, 'bpx', 'p9', 'done', 'src/p9/');
    write_inflight($fx->{D}, [ 'bpx', 'p9' ]);

    my $r = dispatch($fx, 'toolu_b3', "Redo it.\nLedger: " . ledger_line($fx, 'bpx', 'p9') . "\n");
    is($r->{rc}, 0, 'B3: the explicitly declared dispatch is allowed');
    my $b = binding_of($fx, 'toolu_b3');
    is(ref $b eq 'HASH' ? $b->{package} : undef, 'p9', 'B3: it is bound to the declared terminal package');

    my $w = sub_write($fx, 'b3aaa', 'toolu_b3', 'src/p9/x.pl');
    my $res = wg_resolve($fx, $w);
    is(ref $res eq 'HASH' ? $res->{kind} : undef, 'refused_bound', 'B3: resolve kind is refused_bound');
    my $wr = wg_writes($fx, $w);
    is($wr->{rc}, 2, 'B3: its edits are refused');
    like($wr->{err} // '', qr{bound to package bpx/p9}, 'B3: the refusal names the bound package');
}

# ===========================================================================
# B4: an UNBOUND subagent with a parked-blueprint entry as the sole member is
# not scoped to it. Before the fix WriteGuards counted it (its ledger alone is
# usable) and confined the subagent to that package's write set.
# ===========================================================================
{
    my $fx = guard_fixture();
    write_blueprint($fx->{D}, 'bpp', 'parked');
    write_ledger($fx->{D}, 'bpp', 'p1', 'running', 'src/p1/');
    write_inflight($fx->{D}, [ 'bpp', 'p1' ]);

    my $w = sub_write($fx, 'b4aaa', undef, 'tools/unrelated.pl');
    my $res = wg_resolve($fx, $w);
    ok(!defined $res, 'B4: a parked blueprint\'s entry does not count as in flight for an unbound subagent')
        or diag('resolve kind: ' . (ref $res eq 'HASH' ? ($res->{kind} // '?') : '?'));
    is(wg_writes($fx, $w)->{rc}, 0, 'B4: its edit outside that package\'s write set is allowed');
}

# ===========================================================================
# B5: control -- a live sole entry is still bound and scoped.
# ===========================================================================
{
    my $fx = guard_fixture();
    write_blueprint($fx->{D}, 'bpl', 'audited');
    write_ledger($fx->{D}, 'bpl', 'p1', 'running', 'src/p1/');
    write_inflight($fx->{D}, [ 'bpl', 'p1' ]);

    my $r = dispatch($fx, 'toolu_b5');
    is($r->{rc}, 0, 'B5: the dispatch is allowed');
    my $b = binding_of($fx, 'toolu_b5');
    is(ref $b eq 'HASH' ? $b->{package} : undef, 'p1', 'B5: bound to the live sole member, as before');

    my $in  = wg_writes($fx, sub_write($fx, 'b5aaa', 'toolu_b5', 'src/p1/x.pl'));
    is($in->{rc}, 0, 'B5: an in-set edit is allowed');
    my $out = wg_writes($fx, sub_write($fx, 'b5aaa', 'toolu_b5', 'tools/unrelated.pl'));
    is($out->{rc}, 2, 'B5: an out-of-set edit is still refused');
}

done_testing();
