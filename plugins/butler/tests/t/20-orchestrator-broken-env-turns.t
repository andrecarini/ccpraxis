#!/usr/bin/env perl
# b01-orchestrator-broken-env-turns — the immutable test oracle.
#
# Derived ONLY from specs/02-orchestrator-broken-env-turns-spec.md (AC-1..AC-26).
# Three defects are covered here:
#   (a/b) exec-not-found sentinel -> fleet-wide `broken-env` manual pause
#   (c/c2/d) terminal-event classification -> turn continuation w/ adaptive budget,
#            and `turn-starved` after 3 fruitless exhaustions
#   (e) per-tick runs/.tunables overlay (max_par, default_max_turns)
#
# Style follows t/06 (pure-sub asserts) and t/08 (mk_bp / run_once loop driving).
# Every sub call that may not exist yet is funnelled through sc()/lv() so a single
# missing implementation reports as one failing assertion rather than aborting the
# whole file — the failure text then names the missing behaviour directly.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

require "$Bin/../../scripts/bp-orchestrator.pl";

my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
my $NOW  = time;
my $FIX  = "$Bin/../../../../.ccpraxis-local-data/blueprints/sandbox-butler-overhaul/fixtures/b01-terminal-events";

# scalar call guard: returns the value, or a "DIED: ..." string on exception.
sub sc { my $c = shift; my $r = eval { $c->() }; return $@ ? 'DIED: ' . ((split /\n/, $@)[0]) : $r }
# hashref-field guard: returns $h->{$k} when $h is a hash, else a diagnostic string.
sub hv { my ($h, $k) = @_; return ref($h) eq 'HASH' ? $h->{$k} : "NOT-A-HASH($h)" }

# ===========================================================================
# PASS 1 — pure subs (§2.2 / §2.3 / §2.4 / §2.5). No filesystem, no loop.
# ===========================================================================

# ---- AC-14: widen_max_turns exact values (§2.4, floor via int) -------------
is(sc(sub { BpOrch::widen_max_turns(100, 100) }), 150, 'AC-14 widen(100,100)=150');
is(sc(sub { BpOrch::widen_max_turns(150, 100) }), 200, 'AC-14 widen(150,100)=200 (225 capped to 2*initial)');
is(sc(sub { BpOrch::widen_max_turns(200, 100) }), 200, 'AC-14 widen(200,100)=200 (at ceiling)');
is(sc(sub { BpOrch::widen_max_turns(80, 80) }),   120, 'AC-14 widen(80,80)=120');
is(sc(sub { BpOrch::widen_max_turns(120, 80) }),  160, 'AC-14 widen(120,80)=160 (180 capped)');
is(sc(sub { BpOrch::widen_max_turns(160, 80) }),  160, 'AC-14 widen(160,80)=160 (at ceiling)');
is(sc(sub { BpOrch::widen_max_turns(101, 100) }), 151, 'AC-14 widen(101,100)=151 (int() floors 151.5)');
is(sc(sub { BpOrch::widen_max_turns(200, 50) }),  200, 'AC-14 widen never shrinks below current');

# ---- AC-8: terminal_verdict truth table (PURE, total) ---------------------
{
    my $mt = sc(sub { BpOrch::terminal_verdict({ type => 'result', subtype => 'error_max_turns',
                                                 terminal_reason => 'max_turns', is_error => JSON::PP::true,
                                                 num_turns => 160, session_id => 'sess-abc' }) });
    is(hv($mt, 'verdict'),    'max_turns', 'AC-8 subtype=error_max_turns -> max_turns');
    is(hv($mt, 'subtype'),    'error_max_turns', 'AC-8 verdict carries subtype');
    is(hv($mt, 'num_turns'),  160,         'AC-8 verdict carries num_turns');
    is(hv($mt, 'session_id'), 'sess-abc',  'AC-8 verdict carries session_id');

    my $tr = sc(sub { BpOrch::terminal_verdict({ type => 'result', terminal_reason => 'max_turns' }) });
    is(hv($tr, 'verdict'), 'max_turns', 'AC-8 terminal_reason=max_turns (no subtype) -> max_turns');

    is(hv(sc(sub { BpOrch::terminal_verdict({ type => 'result', subtype => 'success' }) }), 'verdict'),
       'success', 'AC-8 subtype=success -> success');
    is(hv(sc(sub { BpOrch::terminal_verdict({ type => 'result', subtype => 'error_other' }) }), 'verdict'),
       'error', 'AC-8 subtype=error_other -> error');
    is(hv(sc(sub { BpOrch::terminal_verdict({ type => 'assistant', subtype => 'error_max_turns' }) }), 'verdict'),
       'unknown', 'AC-8 type ne result -> unknown (even with a max_turns subtype)');
    is(hv(sc(sub { BpOrch::terminal_verdict({}) }), 'verdict'),        'unknown', 'AC-8 empty hash -> unknown');
    is(hv(sc(sub { BpOrch::terminal_verdict(undef) }), 'verdict'),     'unknown', 'AC-8 undef -> unknown');
    is(hv(sc(sub { BpOrch::terminal_verdict('a string') }), 'verdict'),'unknown', 'AC-8 non-ref scalar -> unknown');
    is(hv(sc(sub { BpOrch::terminal_verdict([1,2,3]) }), 'verdict'),   'unknown', 'AC-8 arrayref -> unknown');

    my $u = sc(sub { BpOrch::terminal_verdict(undef) });
    is_deeply([sort keys %{ ref($u) eq 'HASH' ? $u : {} }],
              [sort qw(verdict subtype num_turns session_id)],
              'AC-8 return shape always has exactly the four keys');
}

# ---- AC-21: snapshot_progressed PURE table (§2.3) -------------------------
is(sc(sub { BpOrch::snapshot_progressed({status=>'a',checkboxes=>2}, {status=>'b',checkboxes=>2}) }), 1,
   'AC-21 status changed -> 1');
is(sc(sub { BpOrch::snapshot_progressed({status=>'a',checkboxes=>2}, {status=>'a',checkboxes=>3}) }), 1,
   'AC-21 checkbox count increased -> 1');
is(sc(sub { BpOrch::snapshot_progressed({status=>'a',checkboxes=>2}, {status=>'a',checkboxes=>2}) }), 0,
   'AC-21 identical -> 0');
is(sc(sub { BpOrch::snapshot_progressed({status=>'a',checkboxes=>2}, {status=>'a',checkboxes=>1}) }), 0,
   'AC-21 checkbox count DECREASED -> 0 (strict >)');
is(sc(sub { BpOrch::snapshot_progressed(undef, {status=>'a',checkboxes=>2}) }), 0,
   'AC-21 no snapshot -> 0 (cannot prove progress)');
is(sc(sub { BpOrch::snapshot_progressed({status=>'a',checkboxes=>2,jsonl_size=>100,ledger_mtime=>10},
                                        {status=>'a',checkboxes=>2,jsonl_size=>900000,ledger_mtime=>10}) }), 0,
   'AC-21 jsonl_size growth ALONE -> 0 (jsonl is not a progress signal)');
is(sc(sub { BpOrch::snapshot_progressed({status=>'a',checkboxes=>2,jsonl_size=>100,ledger_mtime=>10},
                                        {status=>'a',checkboxes=>2,jsonl_size=>100,ledger_mtime=>99999}) }), 0,
   'AC-21 ledger_mtime bump ALONE -> 0 (a bare ledger touch is not progress)');

# ---- AC-11 / AC-12: effective_attempts + watchdog_verdict purity ----------
is(sc(sub { BpOrch::effective_attempts(5, 1) }), 4, 'AC-11 effective_attempts(5,1)=4');
is(sc(sub { BpOrch::effective_attempts(5, 0) }), 5, 'AC-11 effective_attempts(5,0)=5');
is(sc(sub { BpOrch::effective_attempts(5, undef) }), 5, 'AC-11 effective_attempts(5,undef)=5 (no-regression default)');
is(sc(sub { BpOrch::effective_attempts(undef, undef) }), 0, 'AC-11 effective_attempts(undef,undef)=0');
is(sc(sub { BpOrch::effective_attempts(1, 4) }), 0, 'AC-11 effective_attempts floors at 0');
is(BpOrch::watchdog_verdict({alive=>0, attempts=>4, cap=>5}), 'relaunch',
   'AC-11 dead + effective attempts 4 < cap 5 -> relaunch (cap not consumed)');
is(BpOrch::watchdog_verdict({alive=>1, progress=>'growing', attempts=>1, cap=>5}), 'none',
   'AC-12 watchdog unchanged: alive+growing -> none');
is(BpOrch::watchdog_verdict({alive=>1, progress=>'flat', attempts=>1, cap=>5}), 'cold-relaunch',
   'AC-12 watchdog unchanged: alive+flat under cap -> cold-relaunch');
is(BpOrch::watchdog_verdict({alive=>1, progress=>'flat', attempts=>5, cap=>5}), 'block',
   'AC-12 watchdog unchanged: alive+flat at cap -> block');
is(BpOrch::watchdog_verdict({alive=>0, attempts=>5, cap=>5}), 'block',
   'AC-12 watchdog unchanged: dead at cap -> block');

# ===========================================================================
# PASS 1b — impure-but-loopless helpers (§2.2 / §2.3 / §2.4 / §2.6).
# ===========================================================================

sub spit { my ($p, $c) = @_; open my $f, '>:raw', $p or die "spit $p: $!"; print $f $c; close $f; return $p }
sub slurp_raw { my ($p) = @_; open my $f, '<:raw', $p or return undef; local $/; my $c = <$f>; close $f; return $c }

my $UJ = JSON::PP->new->utf8->canonical;

# Ground truth for the two terminal shapes: the measured fixtures under
# fixtures/b01-terminal-events/ when present, else a byte-equivalent canonical
# re-encoding (canonical ordering reproduces the landmine: `type` is NOT first).
sub fixture_line {
    my ($name, $fallback) = @_;
    my $raw = slurp_raw("$FIX/$name");
    if (defined $raw) { $raw =~ s/\s+\z//; return $raw if length $raw }
    return $UJ->encode($fallback);
}
my $MAXT_LINE = fixture_line('max-turns.jsonl', {
    errors => ['Reached maximum number of turns (1)'], is_error => JSON::PP::true,
    num_turns => 2, permission_denials => [], session_id => 'REDACTED-SESSION-ID',
    stop_reason => 'tool_use', subtype => 'error_max_turns', terminal_reason => 'max_turns',
    type => 'result', uuid => '219ca868-a3c4-4f60-8c6d-4872a3f41786' });
my $SUCC_LINE = fixture_line('success.jsonl', {
    api_error_status => undef, is_error => JSON::PP::false, num_turns => 1,
    permission_denials => [], result => 'ok', session_id => 'REDACTED-SESSION-ID',
    stop_reason => 'end_turn', subtype => 'success', terminal_reason => 'completed',
    type => 'result', uuid => '9b58db68-ea87-40ee-b1e0-d00eaafb4354' });

# ---- AC-9 landmine #1: key order. `type` is not the first key on the line. -
unlike($MAXT_LINE, qr/^\{"type"/, 'AC-9 max-turns fixture does NOT begin with "type" (prefix grep would miss it)');
like($MAXT_LINE, qr/^\{"[a-z_]+":/,      'AC-9 max-turns fixture is a JSON object line');
like($MAXT_LINE, qr/"type":"result"/,    'AC-9 max-turns fixture carries type=result mid-line');
unlike($SUCC_LINE, qr/^\{"type"/, 'AC-9 success fixture does NOT begin with "type" either');

# ---- AC-9: _last_jsonl_obj total-ness over hostile inputs ------------------
{
    my $runs = "$ROOT/jl"; mkdir $runs;

    is(sc(sub { defined BpOrch::_last_jsonl_obj($runs, 'nosuch') ? 'DEFINED' : 'UNDEF' }), 'UNDEF',
       'AC-9 missing jsonl file -> undef (never dies)');

    spit("$runs/empty.jsonl", '');
    is(sc(sub { defined BpOrch::_last_jsonl_obj($runs, 'empty') ? 'DEFINED' : 'UNDEF' }), 'UNDEF',
       'AC-9 zero-byte jsonl -> undef');

    spit("$runs/blank.jsonl", "\n\n   \n\t\n\n");
    is(sc(sub { defined BpOrch::_last_jsonl_obj($runs, 'blank') ? 'DEFINED' : 'UNDEF' }), 'UNDEF',
       'AC-9 all-blank jsonl -> undef');

    spit("$runs/trunc.jsonl", qq({"type":"assistant"}\n{"is_error":true,"type":"resu\n));
    is(sc(sub { defined BpOrch::_last_jsonl_obj($runs, 'trunc') ? 'DEFINED' : 'UNDEF' }), 'UNDEF',
       'AC-9 truncated final line -> undef (eval-guarded decode, never dies)');

    spit("$runs/notobj.jsonl", qq({"type":"result","subtype":"success"}\n[1,2,3]\n));
    is(sc(sub { defined BpOrch::_last_jsonl_obj($runs, 'notobj') ? 'DEFINED' : 'UNDEF' }), 'UNDEF',
       'AC-9 last non-empty line is not a HASH ref -> undef (does not fall back to an earlier line)');

    spit("$runs/scalar.jsonl", qq("just a string"\n));
    is(sc(sub { defined BpOrch::_last_jsonl_obj($runs, 'scalar') ? 'DEFINED' : 'UNDEF' }), 'UNDEF',
       'AC-9 last line decodes to a scalar -> undef');

    # positive: the measured max-turns line, preceded by noise and followed by blanks.
    spit("$runs/mt.jsonl", qq({"type":"assistant","message":{}}\n$MAXT_LINE\n\n  \n));
    my $mt = sc(sub { BpOrch::_last_jsonl_obj($runs, 'mt') });
    is(hv($mt, 'type'),    'result',           'AC-9 decodes the last NON-EMPTY line (trailing blanks skipped)');
    is(hv($mt, 'subtype'), 'error_max_turns',  'AC-9 decoded max-turns subtype');
    is(hv($mt, 'terminal_reason'), 'max_turns','AC-9 decoded max-turns terminal_reason');
    is(hv($mt, 'num_turns'), 2,                'AC-9 decoded max-turns num_turns');
    is(hv(sc(sub { BpOrch::terminal_verdict(BpOrch::_last_jsonl_obj($runs, 'mt')) }), 'verdict'),
       'max_turns', 'AC-9 real max-turns fixture end-to-end -> max_turns (key order irrelevant)');

    spit("$runs/ok.jsonl", qq({"type":"assistant","message":{}}\n$SUCC_LINE\n));
    is(hv(sc(sub { BpOrch::_last_jsonl_obj($runs, 'ok') }), 'subtype'), 'success',
       'AC-9 decoded success subtype');
    is(hv(sc(sub { BpOrch::terminal_verdict(BpOrch::_last_jsonl_obj($runs, 'ok')) }), 'verdict'),
       'success', 'AC-9 real success fixture end-to-end -> success (NOT max_turns)');
}

# ---- AC-21 support: ledger_checkboxes (§2.3) ------------------------------
# bpdir factory shared by the loopless helpers below and by the loop passes.
my $bpn = 0;
sub mk_bp {
    my ($pkgs, $registry) = @_;                # pkgs = [ [name, deps, status, write_set, extra_fm, body] ]
    my $dir = "$ROOT/bp" . (++$bpn);
    mkdir $dir; mkdir "$dir/packages"; mkdir "$dir/runs";
    open my $b, '>', "$dir/blueprint.md" or die;
    print $b "# T$bpn\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n";
    print $b "| $_->[0] | d | $_->[1] | sonnet | $_->[2] |\n" for @$pkgs;
    close $b;
    write_ledger($dir, @$_) for @$pkgs;
    if ($registry) { spit("$dir/runs/registry.json", $J->encode({ packages => $registry })); }
    spit("$dir/creds.json", $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-SCN-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-SCNREF-bbbbbbbbbbbbbbbb',
        expiresAt => ($NOW + 5*3600) * 1000, scopes => ['user:inference'],
        subscriptionType => 'max', rateLimitTier => 'x' } }));
    return $dir;
}
sub write_ledger {
    my ($dir, $name, $deps, $status, $ws, $extra_fm, $body) = @_;
    $ws //= "p/$name/"; $extra_fm //= ''; $body //= '';
    open my $l, '>', "$dir/packages/$name.md" or die;
    print $l "---\npackage: $name\nblueprint: T\nstatus: $status\nwrite_set: $ws\ntest_paths: $ws\n"
           . $extra_fm . "last_updated: 2026-06-24T00:00:00Z\n---\n# $name\n\n## Next action\n\ngo\n" . $body;
    close $l;
}

{
    my $dir = mk_bp([['cb', '-', 'in-progress', 'p/cb/', "max_turns: 100\n",
        join("\n", '## Pipeline', '- [x] one', '- [X] two', '  - [x] three (indented)',
             '- [ ] four', '- [-] five', 'prose - [x] not at line start', '')]]);

    is(sc(sub { BpOrch::ledger_checkboxes($dir, 'cb') }), 3,
       'AC-21 ledger_checkboxes counts /^\s*-\s*\[[xX]\]/ only (3 of 6 candidate lines)');
    is(sc(sub { BpOrch::ledger_checkboxes($dir, 'nosuch') }), 0,
       'AC-21 missing ledger -> 0 (never dies)');

    # launch_snapshot shape (§2.3)
    spit("$dir/runs/cb.jsonl", "x" x 4096);
    my $snap = sc(sub { BpOrch::launch_snapshot($dir, "$dir/runs", 'cb', $NOW) });
    is(hv($snap, 'status'),     'in-progress', 'launch_snapshot.status = ledger status at launch');
    is(hv($snap, 'checkboxes'), 3,             'launch_snapshot.checkboxes = ledger_checkboxes');
    is(hv($snap, 'jsonl_size'), 4096,          'launch_snapshot.jsonl_size = jsonl byte size (diagnostics only)');
    is(hv($snap, 'at'),         $NOW,          'launch_snapshot.at = the passed now');
    ok((hv($snap, 'ledger_mtime') // 0) > 0,   'launch_snapshot.ledger_mtime is a real epoch');
    is_deeply([sort keys %{ ref($snap) eq 'HASH' ? $snap : {} }],
              [sort qw(status checkboxes jsonl_size ledger_mtime at)],
              'launch_snapshot returns exactly the five documented keys');

    # A snapshot of an unlaunched/unknown package must not die.
    my $s0 = sc(sub { BpOrch::launch_snapshot($dir, "$dir/runs", 'ghost', $NOW) });
    is(hv($s0, 'status'),     '', 'launch_snapshot of a package with no ledger -> status ""');
    is(hv($s0, 'checkboxes'), 0,  'launch_snapshot of a package with no ledger -> checkboxes 0');
    is(hv($s0, 'jsonl_size'), 0,  'launch_snapshot with no jsonl -> jsonl_size 0');
}

# ---- AC-16: initial_max_turns (§2.4) --------------------------------------
{
    my $dir = mk_bp([['has',  '-', 'pending', 'p/has/',  "max_turns: 100\n"],
                     ['none', '-', 'pending', 'p/none/', ''],
                     ['zero', '-', 'pending', 'p/zero/', "max_turns: 0\n"],
                     ['junk', '-', 'pending', 'p/junk/', "max_turns: abc\n"],
                     ['neg',  '-', 'pending', 'p/neg/',  "max_turns: -5\n"]]);

    is(sc(sub { BpOrch::initial_max_turns($dir, 'has', {}) }), 100,
       'AC-16 ledger max_turns: 100 -> 100');
    is(sc(sub { BpOrch::initial_max_turns($dir, 'none', {}) }), 80,
       'AC-16 no ledger max_turns, no tunable -> 80');
    is(sc(sub { BpOrch::initial_max_turns($dir, 'zero', {}) }), 80,
       'AC-16 ledger max_turns: 0 -> falls back to 80 (not 0)');
    is(sc(sub { BpOrch::initial_max_turns($dir, 'junk', {}) }), 80,
       'AC-16 ledger max_turns: abc -> falls back to 80');
    is(sc(sub { BpOrch::initial_max_turns($dir, 'neg', {}) }), 80,
       'AC-16 ledger max_turns: -5 -> falls back to 80 (must match /^\d+$/)');
    is(sc(sub { BpOrch::initial_max_turns($dir, 'none', { default_max_turns => 120 }) }), 120,
       'AC-16 tunable default_max_turns overrides the hard 80 default');
    is(sc(sub { BpOrch::initial_max_turns($dir, 'has', { default_max_turns => 120 }) }), 100,
       'AC-16 ledger max_turns wins over default_max_turns (author intent)');
    is(sc(sub { BpOrch::initial_max_turns($dir, 'ghost', {}) }), 80,
       'AC-16 unknown package (no ledger) -> 80, never dies');
}

# ---- AC-16 / AC-24: _tunables overlay, whitelist and robustness (§2.6) ----
{
    my $dir  = mk_bp([['t', '-', 'pending', 'p/t/', '']]);
    my $runs = "$dir/runs";
    delete local $ENV{BP_MAX_PARALLEL};
    delete local $ENV{BP_DEFAULT_MAX_TURNS};

    my $base = sc(sub { BpOrch::_tunables() });
    is(hv($base, "max_par"), 3, "AC-24 zero-arg _tunables() still yields the env/default max_par of 3");

    my $tf = "$runs/.tunables";
    my @bad = ('not json', '[]', '{"max_par":"lots"}', '{"max_par":0}', '{"max_par":-1}',
               '{"totally_unknown":9}', '{"max_par":null}', '{"max_par":2.5}', '', '{"max_par":');
    for my $b (@bad) {
        spit($tf, $b);
        is(hv(sc(sub { BpOrch::_tunables($runs) }), "max_par"), 3,
           "AC-24 .tunables = '$b' leaves max_par at the env/default 3 (never dies)");
    }
    unlink $tf;
    is(hv(sc(sub { BpOrch::_tunables($runs) }), "max_par"), 3,
       "AC-24 absent .tunables -> max_par 3 (b23 raised the default from 2)");

    spit($tf, '{"max_par":4}');
    is(hv(sc(sub { BpOrch::_tunables($runs) }), 'max_par'), 4,
       'AC-22 .tunables {"max_par":4} overlays max_par');
    spit($tf, '{"default_max_turns":120}');
    is(hv(sc(sub { BpOrch::_tunables($runs) }), 'default_max_turns'), 120,
       'AC-16 .tunables {"default_max_turns":120} overlays default_max_turns');
    is(sc(sub { BpOrch::initial_max_turns($dir, 't', BpOrch::_tunables($runs)) }), 120,
       'AC-16 initial_max_turns honours the .tunables default_max_turns -> 120');

    # whitelist is EXACTLY max_par + default_max_turns (§10 out-of-scope).
    spit($tf, '{"max_par":4,"watch_tick":9999,"cap":99,"flat":11,"thresh_min":7,"broken_env_thresh":99}');
    my $t = sc(sub { BpOrch::_tunables($runs) });
    is(hv($t, 'max_par'), 4, 'AC-24 whitelisted key still applied alongside ignored ones');
    is(hv($t, 'watch_tick'), hv($base, 'watch_tick'),        'AC-24 watch_tick is NOT overlayable');
    is(hv($t, 'cap'),        hv($base, 'cap'),               'AC-24 cap is NOT overlayable');
    is(hv($t, 'flat'),       hv($base, 'flat'),              'AC-24 flat is NOT overlayable');
    is(hv($t, 'thresh_min'), hv($base, 'thresh_min'),        'AC-24 thresh_min is NOT overlayable');
    is(hv($t, 'broken_env_thresh'), hv($base, 'broken_env_thresh'),
       'AC-24 broken_env_thresh is NOT overlayable via .tunables');

    # the explicit-$file seam used by the loop tests below.
    unlink $tf;
    spit("$dir/elsewhere.json", '{"max_par":7}');
    is(hv(sc(sub { BpOrch::_tunables($runs, "$dir/elsewhere.json") }), 'max_par'), 7,
       'AC-23 explicit $file arg overrides the default runs/.tunables path');
    is(hv(sc(sub { BpOrch::_tunables($runs, "$dir/nope.json") }), "max_par"), 3,
       'AC-23 explicit $file arg pointing at a missing file -> defaults, never dies');
}

# ===========================================================================
# LOOP HARNESS — drives the real BpOrch::run through injected clock / usage /
# launch seams, exactly as t/08 and t/11 do. No network, no real `claude`.
# ===========================================================================

my $DEAD_PID = 2_000_000_000;      # out of range -> kill 0 fails -> not alive
my $USAGE_OK = $J->encode({ five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00+00:00' },
                            seven_day => { utilization => 5,  resets_at => '2099-01-01T12:00:00+00:00' } });

sub tun {
    my ($dir, %o) = @_;
    return { ceil5=>85, ceil7=>90, drain=>600, max_par=>2, cap=>5, flat=>600, watch_tick=>0,
             keeper_int=>600, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0,
             tele_retry=>3, usage_fail=>60, busy_path=>"$dir/busy",
             harvest=>'audit', resolve_cap=>1, corr_cap=>1, judge_to=>100000, judge_spawn_cap=>3, %o };
}

# go(dir => $d, ...) -> (\@launched, $err). @launched records {pkg,kind,args} per
# invocation of the launch seam. rcs => [...] feeds return codes in CALL order
# (order-independent of package naming); the last value repeats once exhausted.
# no_launch => 1 omits the seam entirely so the DEFAULT closure is exercised.
sub go {
    my (%o) = @_;
    my $dir = $o{dir};
    my (@L, $err);
    my $rcs = $o{rcs};
    my $i   = 0;
    my $seam = sub {
        my ($a) = @_;
        push @L, { pkg => $a->{pkg}, kind => $a->{kind}, args => [ @{ $a->{args} || [] } ] };
        return $o{launch}->($a) if $o{launch};
        return 0 unless $rcs;
        my $rc = defined $rcs->[$i] ? $rcs->[$i] : $rcs->[-1];
        $i++;
        return $rc;
    };
    eval {
        BpOrch::run({
            blueprint => 'T', bp_dir => $dir, creds_path => "$dir/creds.json",
            (exists $o{tunables}      ? (tunables      => $o{tunables})      : ()),
            (exists $o{tunables_file} ? (tunables_file => $o{tunables_file}) : ()),
            once      => (exists $o{once} ? $o{once} : 1),
            now       => ($o{now}   || sub { $NOW }),
            sleep     => ($o{sleep} || sub { }),
            http_get  => sub { { status => 200, content => $USAGE_OK } },
            http_post => sub { { status => 200, content => '{}' } },
            ($o{no_launch} ? () : (launch => $seam)),
        });
        1;
    } or $err = $@;
    return (\@L, ($err // ''));
}

sub decisions {
    my ($dir) = @_;
    my $d = "$dir/runs/needs-you";
    return () unless -d $d;
    opendir my $h, $d or return ();
    my @f = sort grep { /\.json$/ } readdir $h;
    closedir $h;
    return map { { file => $_, obj => (eval { $UJ->decode(slurp_raw("$d/$_") // '{}') } || {}) } } @f;
}
sub decisions_of { my ($dir, $kind) = @_; return grep { ($_->{obj}{kind} // '') eq $kind } decisions($dir) }
sub log_events {
    my ($dir) = @_;
    my $c = slurp_raw("$dir/runs/orchestrator.log");
    return () unless defined $c;
    return map { eval { $UJ->decode($_) } || {} } grep { /\S/ } split /\n/, $c;
}
sub log_of  { my ($dir, $type) = @_; return grep { ($_->{type} // '') eq $type } log_events($dir) }
sub reg_of  { my ($dir, $pkg)  = @_; my $r = eval { BpOrch::read_registry("$dir/runs") } || {};
              return (ref($r->{$pkg}) eq 'HASH' ? $r->{$pkg} : {}) }
sub argval  { my ($args, $flag) = @_; $args ||= [];
              for my $n (0 .. $#$args) { return $args->[$n+1] if $args->[$n] eq $flag } return undef }
sub set_terminal   { my ($dir,$pkg,$line) = @_; spit("$dir/runs/$pkg.jsonl", qq({"type":"assistant","message":{}}\n$line\n)) }
sub set_checkboxes { my ($dir,$pkg,$n) = @_; my $f = "$dir/packages/$pkg.md"; my $t = slurp_raw($f) // '';
                     $t =~ s/\n## Pipeline\n.*\z//s; spit($f, $t . "\n## Pipeline\n" . join('', map { "- [x] step $_\n" } 1..$n)) }
sub keep_dead      { my ($dir,$pkg) = @_; sub { BpOrch::update_registry_pkg("$dir/runs", $pkg,
                       { pid => $DEAD_PID, status => 'running', session_id => "sid-$pkg" }); 0 } }
my $SNAP_2 = { status => 'pending', checkboxes => 2, jsonl_size => 10, ledger_mtime => $NOW - 100, at => $NOW - 100 };
my $PIPE_2 = "## Pipeline\n- [x] a\n- [x] b\n";

# ===========================================================================
# PASS 2 — (a)/(b): exec-not-found sentinel and the fleet-wide broken-env trip.
# ===========================================================================

# ---- AC-1: the DEFAULT launch closure never shifts the -1 sentinel --------
{
    my $dir = mk_bp([['solo', '-', 'pending', 'solo/', '']]);
    my $eb  = "$ROOT/emptybin"; mkdir $eb;      # PATH with no `bash` => execvp fails => system() == -1
    my ($L, $err);
    { local $ENV{PATH} = $eb; ($L, $err) = go(dir => $dir, tunables => tun($dir), no_launch => 1); }
    is($err, '', 'AC-1 the tick survives an unrunnable launcher');
    my @lf = log_of($dir, 'launch_failed');
    is(scalar @lf, 1, 'AC-1 exactly one launch_failed event from the default closure');
    my $rc = @lf ? (defined $lf[0]{rc} ? $lf[0]{rc} : 'MISSING') : 'NO-EVENT';
    is($rc, -1, 'AC-1 launch_failed rc is exactly the exec-not-found sentinel -1');
    isnt($rc, 72057594037927935, 'AC-1 rc is NOT the mangled (-1 >> 8) garbage value');
    ok(defined $BpOrch::LAST_EXEC_ERROR && length "$BpOrch::LAST_EXEC_ERROR",
       'AC-1 $LAST_EXEC_ERROR holds the errno string from the failed system()');
}

# ---- AC-4 (real-errno branch): default closure, 3 failures in one tick ----
{
    my $dir = mk_bp([map { ["e$_", '-', 'pending', "e$_/", ''] } 1..3]);
    my $eb  = "$ROOT/emptybin"; mkdir $eb;
    my ($L, $err);
    { local $ENV{PATH} = $eb; ($L, $err) = go(dir => $dir, tunables => tun($dir, max_par => 3), no_launch => 1); }
    is($err, '', 'AC-4 the trip tick survives three unrunnable launches');
    my @d = decisions_of($dir, 'broken-env');
    is(scalar @d, 1, 'AC-4 default closure: 3 consecutive exec failures -> one broken-env decision');
    my $ctx = @d ? ($d[0]{obj}{context} // '') : '';
    like($ctx,   qr/3 consecutive launch attempts/, 'AC-4 context names the observed streak count 3');
    like($ctx,   qr/last errno: \S/,                'AC-4 context carries the errno tail');
    unlike($ctx, qr/errno unavailable/,             'AC-4 the REAL errno is used when $LAST_EXEC_ERROR is set');
}

# ---- AC-2 / AC-3 / AC-4 (fallback branch) / AC-7 -------------------------
{
    my $dir = mk_bp([map { ["b$_", '-', 'pending', "b$_/", ''] } 1..3]);
    my ($L, $err) = go(dir => $dir, tunables => tun($dir, max_par => 3), rcs => [-1, -1, -1]);
    is($err, '', 'AC-2 the trip tick completes without dying');
    is(scalar @$L, 3, 'AC-2 all three packages were attempted inside the trip tick');

    my $p = eval { BpOrch::read_paused("$dir/runs") };
    ok($p, 'AC-2 runs/.paused exists after the 3rd consecutive exec failure');
    is((ref($p) eq 'HASH' && $p->{manual}) ? 1 : 0, 1, 'AC-2 the pause is manual => 1 (no auto-resume)');
    my $reason = ref($p) eq 'HASH' ? ($p->{reason} // '') : '';
    ok(length $reason, 'AC-2 the pause carries a non-empty reason');
    like($reason, qr/broken-env/, 'AC-2 the pause reason names broken-env');

    my @all = decisions($dir);
    is(scalar @all, 1, 'AC-2 exactly ONE needs-you decision filed by the trip');
    my $o = @all ? $all[0]{obj} : {};
    is(($o->{kind}    // ''), 'broken-env', 'AC-2 decision kind is broken-env');
    is(($o->{package} // ''), '_fleet',     'AC-2 decision package is the literal string _fleet');
    like((@all ? $all[0]{file} : ''), qr/^_fleet--.+\.json$/, 'AC-2 filename is _fleet--<shortid>.json');
    ok(defined $o->{blueprint},  'AC-2 decision carries blueprint');
    ok(defined $o->{created_at}, 'AC-2 decision carries created_at');
    like(($o->{question} // ''), qr/3 times in a row/, 'AC-2 question names the streak count');

    like(($o->{context} // ''), qr/3 consecutive launch attempts/, 'AC-4 context names the streak count');
    like(($o->{context} // ''), qr/last errno: exec failed \(errno unavailable\)/,
         'AC-4 an INJECTED closure leaves $LAST_EXEC_ERROR undef -> documented fallback text');

    for my $other (qw(reauth pause-creds stuck-package harvest-spawn-failure turn-starved)) {
        isnt(($o->{kind} // ''), $other, "AC-7 broken-env kind is distinct from $other");
    }

    # AC-3 — the pause must STOP the thrash. Assert on LATER ticks: the gate is
    # evaluated at the top of a tick, so the trip tick itself proves nothing.
    my $after = 0;
    for my $n (1 .. 4) {
        my ($L2, $e2) = go(dir => $dir, tunables => tun($dir, max_par => 3), launch => sub { $after++; -1 });
        is($e2, '', "AC-3 post-trip tick $n completes without dying");
    }
    is($after, 0, 'AC-3 ZERO launch attempts across 4 further ticks (the manual pause gate short-circuits)');
    my @still = decisions_of($dir, 'broken-env');
    is(scalar @still, 1, 'AC-3 still exactly one broken-env decision (queue_needs_you dedupes on package+kind)');
}

# ---- AC-5: any non-sentinel rc resets the consecutive-failure streak ------
{
    for my $case ([[-1,-1,0,-1,-1], 'rc 0 (a successful launch)'],
                  [[-1,-1,3,-1,-1], 'rc 3 (an ordinary non-zero exit)']) {
        my ($rcs, $label) = @$case;
        my $dir = mk_bp([map { ["r$_", '-', 'pending', "r$_/", ''] } 1..5]);
        my ($L, $err) = go(dir => $dir, tunables => tun($dir, max_par => 5), rcs => $rcs);
        is($err, '', "AC-5 tick completes with $label in the middle");
        is(scalar @$L, 5, "AC-5 five launch attempts made [$label]");
        my @d = decisions_of($dir, 'broken-env');
        is(scalar @d, 0, "AC-5 NO broken-env decision — $label reset the streak (max run of -1 is 2)");
        ok(!-e "$dir/runs/.paused", "AC-5 no manual pause written [$label]");
    }
    my $dir = mk_bp([map { ["c$_", '-', 'pending', "c$_/", ''] } 1..5]);
    my ($L, $err) = go(dir => $dir, tunables => tun($dir, max_par => 5), rcs => [-1,-1,-1,-1,-1]);
    my @d = decisions_of($dir, 'broken-env');
    is(scalar @d, 1, 'AC-5 control: five CONSECUTIVE -1s in the same fixture DO trip broken-env');
}

# ---- AC-6: the streak accumulates across all three launch sites -----------
{
    my $dir = mk_bp([['wedged', '-', 'pending', 'wg/', ''],
                     ['deadp',  '-', 'pending', 'dp/', ''],
                     ['freshp', '-', 'pending', 'fp/', '']],
                    { wedged => { attempt=>1, pid=>$$,        session_id=>'sid-w', status=>'running' },
                      deadp  => { attempt=>1, pid=>$DEAD_PID, session_id=>'sid-d', status=>'running' } });
    # wedged: alive pid + a jsonl that has not grown and has been quiet > flat
    # => progress 'flat' => the cold-wedged relaunch site (1036) from tick 2 on.
    spit("$dir/runs/wedged.jsonl", 'x' x 100);
    utime($NOW - 5000, $NOW - 5000, "$dir/runs/wedged.jsonl");
    my $ticks = 0;
    my ($L, $err) = go(dir => $dir, tunables => tun($dir, max_par => 3), once => 0, rcs => [-1],
                       sleep => sub { die "STOP\n" if ++$ticks >= 4 });
    my %kinds = map { ($_->{kind} // '?') => 1 } @$L;
    ok($kinds{'cold-wedged'},               'AC-6 the cold-wedged launch site (1036) was exercised');
    ok($kinds{warm} || $kinds{cold},        'AC-6 the watchdog-relaunch launch site (1055) was exercised');
    ok($kinds{fresh},                       'AC-6 the fresh launch site (1085) was exercised');
    my @d = decisions_of($dir, 'broken-env');
    is(scalar @d, 1, 'AC-6 one shared streak fed by all three sites reaches 3 -> exactly one broken-env trip');
}

# ===========================================================================
# PASS 3 — (c)/(c2)/(d): terminal classification, continuation, turn-starved.
# ===========================================================================

# ---- AC-10 + AC-13: max_turns WITH progress -> widen and continue ---------
{
    my $dir = mk_bp([['p', '-', 'pending', 'pp/', "max_turns: 100\n", "## Pipeline\n- [x] a\n- [x] b\n- [x] c\n"]],
                    { p => { attempt=>1, pid=>$DEAD_PID, session_id=>'sid-x', status=>'running',
                             launch_snapshot => $SNAP_2 } });          # snapshot saw 2 boxes, ledger now has 3
    set_terminal($dir, 'p', $MAXT_LINE);
    my ($L, $err) = go(dir => $dir, tunables => tun($dir), launch => keep_dead($dir, 'p'));
    is($err, '', 'AC-10 tick completes');
    is(scalar @$L, 1, 'AC-10 the turn-exhausted package WITH progress is relaunched');
    is((@$L ? $L->[0]{pkg} : ''), 'p', 'AC-10 the relaunch targets that package');

    my $r = reg_of($dir, 'p');
    is(($r->{turn_continuations} // 0),  1, 'AC-10 turn_continuations went 0 -> 1');
    is(($r->{turn_exhaust_streak} // -1), 0, 'AC-10 turn_exhaust_streak is 0 (progress observed)');

    my @tc = log_of($dir, 'turn_continuation');
    is(scalar @tc, 1, 'AC-10 exactly one turn_continuation event logged');
    my $e = @tc ? $tc[0] : {};
    is(($e->{package}   // ''), 'p', 'AC-10 turn_continuation names the package');
    is(($e->{num_turns} // ''), 2,   'AC-10 turn_continuation carries the terminal num_turns from the fixture');
    is(($e->{from}      // ''), 100, 'AC-10 turn_continuation from = the current budget (ledger max_turns 100)');
    is(($e->{to}        // ''), 150, 'AC-10 turn_continuation to = the widened budget');

    is(argval((@$L ? $L->[0]{args} : []), '--max-turns'), 150,
       'AC-13 the relaunch args carry the adjacent pair (--max-turns, 150)');
    is(($r->{max_turns} // 0), 150, 'AC-13 registry packages.p.max_turns persisted as 150');
    my $sn = $r->{launch_snapshot};
    is((ref($sn) eq 'HASH' ? $sn->{checkboxes} : 'NONE'), 3,
       'B5 a fresh launch_snapshot (checkboxes=3) was persisted on the successful relaunch');
}

# ---- AC-11: the give-up cap is not consumed by continuations --------------
{
    my $dir = mk_bp([['p', '-', 'pending', 'pp/', '']],
                    { p => { attempt=>5, pid=>$DEAD_PID, session_id=>'sid-x', status=>'running',
                             turn_continuations => 1 } });
    my ($L, $err) = go(dir => $dir, tunables => tun($dir, cap => 5));
    is($err, '', 'AC-11 tick completes');
    is(scalar @$L, 1, 'AC-11 attempt=5 cap=5 turn_continuations=1 -> effective 4 -> relaunched, not blocked');
    my @blk = log_of($dir, 'watchdog_block');
    is(scalar @blk, 0, 'AC-11 no watchdog_block event emitted');
    unlike((slurp_raw("$dir/packages/p.md") // ''), qr/^status:\s*blocked/m, 'AC-11 the ledger is NOT marked blocked');
    my @rl = log_of($dir, 'watchdog_relaunch');
    is((@rl ? ($rl[0]{attempts} // 'MISSING') : 'NO-EVENT'), 5,
       'AC-11 the log still reports the RAW attempts (5), not the effective count (no test churn)');
}

# ---- AC-15: adaptive budget end-to-end, launches 1..5 --------------------
{
    my $dir = mk_bp([['seq', '-', 'pending', 'sq/', "max_turns: 100\n", $PIPE_2]]);
    my @budgets;
    my $boxes = 2;
    for my $n (1 .. 5) {
        my ($L, $err) = go(dir => $dir, tunables => tun($dir, cap => 5), launch => sub {
            my $att = (reg_of($dir, 'seq')->{attempt} // 0) + 1;   # bp-launch.sh bumps attempt unconditionally
            BpOrch::update_registry_pkg("$dir/runs", 'seq',
                { attempt => $att, pid => $DEAD_PID, status => 'running', session_id => 'sid-seq' });
            0;
        });
        is(scalar @$L, 1, "AC-15 launch $n happened");
        push @budgets, (@$L ? argval($L->[0]{args}, '--max-turns') : 'NO-LAUNCH');
        set_terminal($dir, 'seq', $MAXT_LINE);   # burned the budget ...
        set_checkboxes($dir, 'seq', ++$boxes);   # ... but ticked one more checkbox (progress)
    }
    is_deeply(\@budgets, [undef, 150, 200, 200, 200],
       'AC-15 --max-turns on launches 1..5 is (none),150,200,200,200 — converges at 2 x initial');
    is((reg_of($dir, 'seq')->{turn_continuations} // 0), 4, 'AC-15 turn_continuations after launch 5 is 4');
    is((reg_of($dir, 'seq')->{attempt} // 0), 5, 'AC-15 the raw attempt counter still reached 5 ...');
    is(sc(sub { BpOrch::effective_attempts(5, 4) }), 1, 'AC-15 ... but effective_attempts(5,4) is 1 — cap untouched');
}

# ---- AC-17 / AC-18 / AC-19: no progress -> streak 1, 2, then turn-starved -
{
    my $dir = mk_bp([['np', '-', 'pending', 'np/', "max_turns: 100\n", $PIPE_2]],
                    { np => { attempt=>7, pid=>$DEAD_PID, session_id=>'sid-x', status=>'running',
                              launch_snapshot => $SNAP_2 } });        # snapshot == current ledger state
    set_terminal($dir, 'np', $MAXT_LINE);

    for my $n (1 .. 2) {
        my ($L, $err) = go(dir => $dir, tunables => tun($dir, cap => 99), launch => keep_dead($dir, 'np'));
        is($err, '', "AC-17 exhaustion $n tick completes");
        is(scalar @$L, 1, "AC-17 exhaustion $n (no progress) still relaunches — streak below threshold");
        is(argval((@$L ? $L->[0]{args} : []), '--max-turns'), undef,
           "AC-17 exhaustion $n relaunch carries NO --max-turns (no widening without progress)");
        is((reg_of($dir, 'np')->{turn_exhaust_streak} // 0), $n, "AC-17 turn_exhaust_streak is $n");
        is((reg_of($dir, 'np')->{turn_continuations} // 0), 0,
           "AC-17 turn_continuations still 0 after exhaustion $n (a fruitless attempt burns the cap)");
        my @d = decisions_of($dir, 'turn-starved');
        is(scalar @d, 0, "AC-17 no turn-starved decision after exhaustion $n");
        ok(!-e "$dir/runs/.paused", "AC-17 no manual pause after exhaustion $n");
    }
    my @ev = log_of($dir, 'turn_exhausted_no_progress');
    is(scalar @ev, 2, 'AC-17 one turn_exhausted_no_progress event per exhaustion');
    is((@ev ? ($ev[-1]{streak} // 'MISSING') : 'NO-EVENT'), 2, 'AC-17 the event carries the running streak');

    # third occurrence -> turn-starved, and NO relaunch on that tick.
    my ($L3, $e3) = go(dir => $dir, tunables => tun($dir, cap => 99), launch => keep_dead($dir, 'np'));
    is($e3, '', 'AC-18 the turn-starved tick completes without dying');
    is(scalar @$L3, 0, 'AC-18 the launch closure was NOT invoked for the package on the 3rd exhaustion');
    my @d = decisions_of($dir, 'turn-starved');
    is(scalar @d, 1, 'AC-18 exactly one turn-starved decision filed');
    my $o = @d ? $d[0]{obj} : {};
    is(($o->{kind}    // ''), 'turn-starved', 'AC-18 decision kind is the literal turn-starved');
    is(($o->{package} // ''), 'np',           'AC-18 decision package is the starved package');
    like((@d ? $d[0]{file} : ''), qr/^np--.+\.json$/, 'AC-18 filename is <pkg>--<shortid>.json');
    my $p = eval { BpOrch::read_paused("$dir/runs") };
    is((ref($p) eq 'HASH' && $p->{manual}) ? 1 : 0, 1, 'AC-18 runs/.paused written with manual => 1');
    like((ref($p) eq 'HASH' ? ($p->{reason} // '') : ''), qr/turn-starved/, 'AC-18 the pause reason names turn-starved');

    like(($o->{context}  // ''), qr/3 consecutive turn exhaustions/, 'AC-19 context names the exhaustion count');
    like(($o->{context}  // ''), qr/attempts=/,                      'AC-19 context carries attempts=');
    like(($o->{context}  // ''), qr/last num_turns=/,                'AC-19 context carries last num_turns=');
    like(($o->{question} // ''), qr/3 times in a row/,               'AC-19 question names the exhaustion count');

    for my $other (qw(reauth pause-creds stuck-package harvest-spawn-failure broken-env)) {
        isnt(($o->{kind} // ''), $other, "AC-7 turn-starved kind is distinct from $other");
    }
}

# ---- AC-20: progress resets the streak; a terminal success clears it too --
{
    my $dir = mk_bp([['rs', '-', 'pending', 'rs/', "max_turns: 100\n", $PIPE_2]],
                    { rs => { attempt=>1, pid=>$DEAD_PID, session_id=>'sid-x', status=>'running',
                              launch_snapshot => $SNAP_2 } });
    set_terminal($dir, 'rs', $MAXT_LINE);
    my $relaunch = keep_dead($dir, 'rs');
    go(dir => $dir, tunables => tun($dir, cap => 99), launch => $relaunch);   # 1: no progress
    go(dir => $dir, tunables => tun($dir, cap => 99), launch => $relaunch);   # 2: no progress
    is((reg_of($dir, 'rs')->{turn_exhaust_streak} // 0), 2, 'AC-20 streak is 2 before the progressing run');
    set_checkboxes($dir, 'rs', 3);                                           # 3: this run made progress
    go(dir => $dir, tunables => tun($dir, cap => 99), launch => $relaunch);
    is((reg_of($dir, 'rs')->{turn_exhaust_streak} // -1), 0, 'AC-20 an exhaustion WITH progress resets the streak to 0');
    go(dir => $dir, tunables => tun($dir, cap => 99), launch => $relaunch);   # 4: no progress again
    is((reg_of($dir, 'rs')->{turn_exhaust_streak} // 0), 1, 'AC-20 streak is 1 after the final no-progress exhaustion');
    my @d = decisions_of($dir, 'turn-starved');
    is(scalar @d, 0, 'AC-20 no turn-starved decision — the streak never reached 3');
    ok(!-e "$dir/runs/.paused", 'AC-20 no manual pause across the reset sequence');
}
{
    my $dir = mk_bp([['sx', '-', 'pending', 'sx/', "max_turns: 100\n", $PIPE_2]],
                    { sx => { attempt=>1, pid=>$DEAD_PID, session_id=>'sid-x', status=>'running',
                              turn_exhaust_streak => 2, launch_snapshot => $SNAP_2 } });
    set_terminal($dir, 'sx', $SUCC_LINE);                # a terminal SUCCESS, not an exhaustion
    my ($L, $err) = go(dir => $dir, tunables => tun($dir, cap => 99), launch => keep_dead($dir, 'sx'));
    is($err, '', 'AC-20 tick with a terminal success completes');
    is((reg_of($dir, 'sx')->{turn_exhaust_streak} // -1), 0, 'AC-20 a terminal success clears turn_exhaust_streak (B9b)');
    my @tc = log_of($dir, 'turn_continuation');
    is(scalar @tc, 0, 'AC-20 a success is NOT a turn continuation');
    is((reg_of($dir, 'sx')->{turn_continuations} // 0), 0, 'AC-20 a success does not grant a continuation');
}

# ===========================================================================
# PASS 4 — (e): the runs/.tunables overlay, live, per tick.
# NOTE: these MUST NOT inject $opt->{tunables} — per §2.6 an injected hash means
# runs/.tunables is never read, which would make the assertions vacuous.
# ===========================================================================

{
    local $ENV{HOME} = $ROOT;                 # contain any default busy_path
    delete local $ENV{BP_MAX_PARALLEL};
    delete local $ENV{BP_DEFAULT_MAX_TURNS};

    # ---- AC-22 -----------------------------------------------------------
    {
        my $dir = mk_bp([map { ["m$_", '-', 'pending', "m$_/", ''] } 1..5]);
        spit("$dir/runs/.tunables", '{"max_par":4}');
        my ($L, $err) = go(dir => $dir);
        is($err, '', 'AC-22 a tick with a live runs/.tunables completes');
        is(scalar @$L, 4, 'AC-22 runs/.tunables {"max_par":4} raises the per-tick launch cap to 4');
    }
    {
        my $dir = mk_bp([map { ["n$_", '-', 'pending', "n$_/", ''] } 1..5]);
        my ($L, $err) = go(dir => $dir);
        is(scalar @$L, 3, "AC-22 with no .tunables and BP_MAX_PARALLEL unset the cap is the default 3 (b23 raised it from 2)");
    }

    # ---- AC-23: the re-read happens per TICK, not once at boot -----------
    {
        my $dir = mk_bp([map { ["v$_", '-', 'pending', "v$_/", ''] } 1..6]);
        my $tick = 0;
        my @rec;
        my $launch = sub {
            my ($a) = @_;
            push @rec, { pkg => $a->{pkg}, tick => $tick };
            BpOrch::update_registry_pkg("$dir/runs", $a->{pkg},
                { pid => $$, status => 'running', attempt => 1, session_id => "sid-$a->{pkg}" });
            open my $w, '>>', "$dir/runs/$a->{pkg}.jsonl" or return 0; print $w 'x'; close $w;
            0;
        };
        my ($L, $err) = go(dir => $dir, once => 0, launch => $launch, sleep => sub {
            $tick++;
            spit("$dir/runs/.tunables", '{"max_par":4}') if $tick == 1;
            die "STOP\n" if $tick >= 2;
        });
        my $t0 = grep { $_->{tick} == 0 } @rec;
        my $t1 = grep { $_->{tick} == 1 } @rec;
        is($t0, 3, "AC-23 tick 1 launches 3 (no .tunables yet -> default max_par 3)");
        is($t1, 1, 'AC-23 tick 2 launches 1 more — .tunables raised max_par to 4 and 3 are already live');
        is(scalar @rec, 4, 'AC-23 four packages live in total after the mid-run bump');
    }

    # ---- AC-24: hostile .tunables never breaks a tick --------------------
    for my $bad ('not json', '[]', '{"max_par":"lots"}', '{"max_par":0}', '{"max_par":-1}', '{"totally_unknown":9}') {
        my $dir = mk_bp([map { ["z$_", '-', 'pending', "z$_/", ''] } 1..4]);
        spit("$dir/runs/.tunables", $bad);
        my ($L, $err) = go(dir => $dir);
        is($err, '', "AC-24 the tick completes with .tunables = '$bad'");
        is(scalar @$L, 3, "AC-24 .tunables = '$bad' leaves the launch cap at the env/default 3");
    }

    # ---- AC-25: an injected tunables hash wins entirely (t/08, t/11 shape)
    {
        my $dir = mk_bp([map { ["y$_", '-', 'pending', "y$_/", ''] } 1..5]);
        spit("$dir/runs/.tunables", '{"max_par":9}');
        my ($L, $err) = go(dir => $dir, tunables => tun($dir, max_par => 1));
        is($err, '', 'AC-25 a tick with an injected tunables hash completes');
        is(scalar @$L, 1, 'AC-25 injection wins — runs/.tunables is not read at all');
    }
}

# ---- AC-26: a normal run is byte-identical to today ----------------------
{
    # b41 FIXTURE EXTENSION (assertions unchanged): the warm/cold call now reads transcript
    # activity plus a recorded cache observation, not the ledger's mtime. This scenario's
    # point is that a normal run's args are byte-identical to today, so it must still be a
    # genuinely WARM case — which now means supplying the inputs warm is actually made of.
    my $dir = mk_bp([['norm', '-', 'pending', 'nm/', '']],
                    { norm => { attempt=>1, pid=>$DEAD_PID, session_id=>'sid-x', status=>'running',
                                cache_observations => [ { age_min => 0, hit => 1 } ] } });
    {
        my @tm = gmtime(time);
        my $iso = sprintf('%04d-%02d-%02dT%02d:%02d:%02d.000Z',
                          $tm[5]+1900, $tm[4]+1, $tm[3], $tm[2], $tm[1], $tm[0]);
        open my $tr, '>', "$dir/runs/norm.jsonl" or die;
        print $tr $J->encode({ type => 'assistant', timestamp => $iso,
                               message => { usage => { cache_read_input_tokens => 999,
                                                       cache_creation_input_tokens => 0 } } }), "\n";
        close $tr;
    }
    my ($L, $err) = go(dir => $dir, tunables => tun($dir));
    is($err, '', 'AC-26 a normal tick completes');
    is(scalar @$L, 1, 'AC-26 the normal warm relaunch still happens');
    is_deeply((@$L ? $L->[0]{args} : []), ['--resume-session', 'sid-x'],
       'AC-26 args unchanged from today: no --max-turns when the registry holds no max_turns');
    my %types = map { ($_->{type} // '') => 1 } log_events($dir);
    ok(!$types{turn_continuation},          'AC-26 no turn_continuation event on a normal run');
    ok(!$types{turn_exhausted_no_progress}, 'AC-26 no turn_exhausted_no_progress event on a normal run');
    ok(!$types{registry_update_lost},       'AC-26 no registry_update_lost event on a normal run');
    my @d = decisions($dir);
    is(scalar @d, 0, 'AC-26 no needs-you decisions on a normal run');
    ok(!-e "$dir/runs/.paused", 'AC-26 no pause on a normal run');
    my $r = reg_of($dir, 'norm');
    is((exists $r->{turn_continuations}  ? 'PRESENT' : 'ABSENT'), 'ABSENT', 'AC-26 turn_continuations not written on a normal run');
    is((exists $r->{turn_exhaust_streak} ? 'PRESENT' : 'ABSENT'), 'ABSENT', 'AC-26 turn_exhaust_streak not written on a normal run');
    is((exists $r->{max_turns}           ? 'PRESENT' : 'ABSENT'), 'ABSENT', 'AC-26 registry max_turns not written on a normal run');
    # §3 B5 is the specific normative rule and it DOES add one field on rc==0.
    # (AC-26's blanket "no new registry keys written" conflicts with B5 — see report.)
    ok(ref($r->{launch_snapshot}) eq 'HASH', 'B5 launch_snapshot IS persisted on a successful launch (§3 B5)');
}

done_testing();
