#!/usr/bin/env perl
# 24-conformance-gate.t — b05-conformance-gate
#
# Oracle for the whole-blueprint conformance gate, written from
# specs/06-conformance-gate-spec.md (665 lines, AC-1..AC-32).
#
# TDD-RED BY DESIGN: nothing is implemented yet, so every AC below must FAIL for
# the right reason (a missing BpJudge:: function or a real assertion failure) and
# must NEVER pass vacuously. Calls into not-yet-existing code go through try1()/
# tryrun() so a missing sub fails ITS OWN test with a diag instead of aborting the
# whole file — that keeps all failures visible in a single run.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

require "$Bin/../../scripts/bp-judge.pl";
require "$Bin/../../scripts/bp-orchestrator.pl";

my $J = JSON::PP->new->canonical;

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# Call a coderef; a die (e.g. undefined sub) becomes {_died=>msg} so the
# assertion fails informatively instead of killing the test file.
sub try1 {
    my ($code) = @_;
    my $r = eval { $code->() };
    return { _died => "$@" } if $@;
    return $r;
}
sub died { my $r = shift; return (ref $r eq 'HASH' && exists $r->{_died}) ? $r->{_died} : undef }

sub field_is {
    my ($got, $key, $want, $name) = @_;
    if (my $d = died($got)) { fail($name); diag("died: $d"); return }
    is(ref $got eq 'HASH' ? $got->{$key} : undef, $want, $name);
}

sub slurp { local $/; open my $f, '<', shift or return ''; <$f> }
sub jget  { my $p = shift; my $t = slurp($p); return undef unless length $t; return eval { JSON::PP->new->decode($t) } }
sub ls_json {
    my ($dir) = @_;
    return () unless -d $dir;
    opendir my $h, $dir or return ();
    my @f = sort grep { /\.json$/ } readdir $h;
    closedir $h;
    return map { "$dir/$_" } @f;
}
sub find_any {
    my ($dir, $re) = @_;
    for my $f (ls_json($dir)) { my $o = jget($f); return ($f, $o) if $o && $J->encode($o) =~ $re }
    return (undef, undef);
}

my $ROOT = tempdir(CLEANUP => 1);
my $NOW  = 1_800_000_000;
my $bpn  = 0;

sub write_creds {
    my ($p) = @_;
    open my $f, '>:raw', $p or die;
    print $f $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-AAA-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-RRR-bbbbbbbbbbbbbbbb',
        expiresAt => ($NOW + 5 * 3600) * 1000, scopes => ['user:inference'],
        subscriptionType => 'max', rateLimitTier => 'x' } });
    close $f;
}

# pkgs = [ { name, deps, status, write_set, means, body } ]
# NOTE: the shared mk_bp in 10-judges.t:127-143 does NOT emit mandated_means; this
# local one does, which is what makes AC-7/8/9/11/12/32 expressible at all.
sub mk_bp {
    my ($pkgs) = @_;
    my $dir = "$ROOT/bp" . (++$bpn);
    make_path("$dir/packages", "$dir/runs");
    open my $b, '>', "$dir/blueprint.md" or die;
    print $b "# T$bpn\n\n## Objective\n\nTest fixture.\n\n## Package status\n\n"
           . "| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n";
    print $b "| $_->{name} | d | " . ($_->{deps} // '—') . " | sonnet | $_->{status} |\n" for @$pkgs;
    close $b;
    for my $p (@$pkgs) {
        my $means = exists $p->{means} ? $p->{means} : '[]';
        open my $l, '>', "$dir/packages/$p->{name}.md" or die;
        print $l "---\npackage: $p->{name}\nblueprint: T$bpn\nstatus: $p->{status}\n"
               . "write_set: " . ($p->{write_set} // 'src/') . "\ntest_paths: t/\n";
        print $l "mandated_means: $means\n" unless $means eq '__OMIT__';
        print $l "last_updated: 2026-07-25T00:00:00Z\n---\n# $p->{name}\n\n"
               . "## Next action\n\ngo\n\n## Decisions & attempt log\n\n"
               . ($p->{body} // "- nothing to report\n");
        close $l;
    }
    write_creds("$dir/creds.json");
    return $dir;
}

sub base_tun {
    my %o = @_;
    return { ceil5 => 85, ceil7 => 90, drain => 600, max_par => 2, cap => 5, flat => 600,
             watch_tick => 0, keeper_int => 600, keeper_bo => 120, thresh_min => 60,
             jit_lo => 0, jit_hi => 0, tele_retry => 3, usage_fail => 60,
             busy_path => "$ROOT/busy.$bpn", harvest => 'audit', resolve_cap => 1,
             corr_cap => 1, judge_to => 1800, conformance_spawn_cap => 2, %o };
}

my $USAGE_OK = $J->encode({ five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00+00:00' },
                            seven_day => { utilization => 5,  resets_at => '2099-01-01T12:00:00+00:00' } });

# one watch tick; returns what the injected seams captured
sub run_once {
    my ($dir, %o) = @_;
    my (@launched, @spawned, @builds);
    my $ok = eval {
        BpOrch::run({
            blueprint => 'T', bp_dir => $dir, creds_path => "$dir/creds.json",
            tunables  => ($o{tunables} || base_tun(%{ $o{tun} || {} })),
            once => 1, now => ($o{now} || sub { $NOW }), sleep => sub {},
            http_get  => sub { { status => 200, content => $USAGE_OK } },
            http_post => sub { { status => 200, content => '{}' } },
            launch    => sub { push @launched, $_[0]; 0 },
            spawn_judge => ($o{spawn_judge} || sub { push @spawned, $_[0]; 0 }),
            build_runner => (exists $o{build_runner} ? $o{build_runner}
                             : sub { push @builds, $_[0]; { ok => 1, exit => 0, stdout => '', stderr => '' } }),
            ($o{read_verdict} ? (read_verdict => $o{read_verdict}) : ()),
        });
        1;
    };
    return { launched => \@launched, spawned => \@spawned, builds => \@builds,
             err => ($@ ? "$@" : undef), ok => ($ok ? 1 : 0) };
}
sub tryrun      { return run_once(@_) }
sub conf_spawns { my $r = shift; return grep { ($_->{kind} // '') eq 'conformance' } @{ $r->{spawned} } }

sub seed_verdict {
    my ($dir, $kind, $pkg, $obj) = @_;
    make_path("$dir/runs/$kind");
    my $f = eval { BpOrch::judge_verdict_path("$dir/runs", $kind, $pkg) } || "$dir/runs/$kind/$pkg.verdict.json";
    open my $w, '>', $f or die;
    print $w (ref $obj ? $J->encode($obj) : $obj);
    close $w;
    return $f;
}
sub seed_deps {
    my ($dir, $content) = @_;
    make_path("$dir/runs");
    my $f = "$dir/runs/deps-check.json";
    open my $w, '>', $f or die; print $w (ref $content ? $J->encode($content) : $content); close $w;
    return $f;
}
sub verdict_of { my $dir = shift; return jget("$dir/runs/conformance-verdict.json") }
sub reviews_of { my $dir = shift; return ls_json("$dir/runs/review") }
sub notices_of { my $dir = shift; return ls_json("$dir/runs/notices") }
sub needs_you_of {
    my $dir = shift; my @o;
    for my $f (ls_json("$dir/runs/needs-you")) { push @o, jget($f) }
    return @o;
}

my $DEV_BODY_OK = "- 2026-07-25 — did the work.\n"
  . "- MEANS-DEVIATION: means=libX change=hand-rolled a substitute shim why=libX is ESM-only and this runtime is CJS, so it cannot load\n";
my $DEV_BODY_BLANK_WHY = "- MEANS-DEVIATION: means=libX change=hand-rolled a substitute shim why=\n";

# a raw judge verdict asserting one deviation against $pkg
sub raw_dev_verdict {
    my ($pkg, %o) = @_;
    return { outcome => ($o{outcome} // 'fail'), blueprint => 'T',
             deviations => [ { package => $pkg, means => ($o{means} // 'libX'),
                               observed => 'hand-rolled chat components',
                               files => [ 'src/chat/Bubble.tsx' ] } ],
             findings => ($o{findings} // []), reason => 'mandated means not evidenced' };
}

# ===========================================================================
# PART 1 — pure BpJudge functions (spec §2.1)
# ===========================================================================

# ---- AC-1: conformance_ready — all done/dropped => ready; any non-terminal => not_terminal
{
    my $g = try1(sub { BpJudge::conformance_ready({ A => { status => 'done' }, B => { status => 'dropped' } }) });
    field_is($g, 'ready', 1, 'AC-1: all done/dropped (mixed) => ready=1');
    my $n = try1(sub { BpJudge::conformance_ready({ A => { status => 'done' }, B => { status => 'running' } }) });
    field_is($n, 'ready',  0,              'AC-1: a non-terminal package => ready=0');
    field_is($n, 'reason', 'not_terminal', 'AC-1: reason=not_terminal');
}

# ---- AC-2: blocked/parked are terminal per _is_terminal(:73) but must NOT be ready
{
    my $b = try1(sub { BpJudge::conformance_ready({ A => { status => 'done' }, B => { status => 'blocked' } }) });
    field_is($b, 'ready',  0,                'AC-2: a blocked package => ready=0 though it IS terminal');
    field_is($b, 'reason', 'awaiting_human', 'AC-2: reason=awaiting_human');
    if (died($b)) { fail('AC-2: awaiting names the blocked package') }
    else { is_deeply($b->{awaiting} || [], ['B'], 'AC-2: awaiting names the blocked package') }
    my $p = try1(sub { BpJudge::conformance_ready({ A => { status => 'parked' } }) });
    field_is($p, 'reason', 'awaiting_human', 'AC-2: parked also => awaiting_human');
    my $both = try1(sub { BpJudge::conformance_ready({ A => { status => 'running' }, B => { status => 'blocked' } }) });
    field_is($both, 'reason', 'awaiting_human', 'AC-2: awaiting_human takes precedence over not_terminal');
}

# ---- AC-3: empty registry is fail-closed
{
    my $e = try1(sub { BpJudge::conformance_ready({}) });
    field_is($e, 'ready',  0,                'AC-3: empty registry => ready=0');
    field_is($e, 'reason', 'empty_registry', 'AC-3: reason=empty_registry (fail-closed)');
}

# ---- AC-7: parse_mandated_means shapes
{
    my $flow = try1(sub { BpJudge::parse_mandated_means('[assistant-ui, shadcn/ui, real CSS]') });
    if (my $d = died($flow)) { fail('AC-7: flow list parses'); diag("died: $d") }
    else { is_deeply($flow->{means}, ['assistant-ui', 'shadcn/ui', 'real CSS'], 'AC-7: flow list parses') }
    field_is($flow, 'shape', 'flow', 'AC-7: shape=flow');
    field_is($flow, 'ok',    1,      'AC-7: ok=1');

    my $empty = try1(sub { BpJudge::parse_mandated_means('[]') });
    field_is($empty, 'shape', 'flow_empty', 'AC-7: [] => shape=flow_empty');
    if (died($empty)) { fail('AC-7: [] => means=[]') } else { is_deeply($empty->{means}, [], 'AC-7: [] => means=[]') }

    my $abs = try1(sub { BpJudge::parse_mandated_means(undef) });
    field_is($abs, 'shape', 'absent', 'AC-7: undef => shape=absent');
    field_is($abs, 'ok',    1,        'AC-7: undef => ok=1 (absence is legal)');

    my $blk = try1(sub { BpJudge::parse_mandated_means("\n- a\n- b\n") });
    field_is($blk, 'shape', 'block', 'AC-7: YAML block list => shape=block');
    if (died($blk)) { fail('AC-7: block list elements') } else { is_deeply($blk->{means}, ['a', 'b'], 'AC-7: block list elements') }

    my $bad = try1(sub { BpJudge::parse_mandated_means('{a: 1, b: {c: 2}}') });
    field_is($bad, 'shape', 'unknown', 'AC-7: garbage => shape=unknown');
    field_is($bad, 'ok',    0,         'AC-7: garbage => ok=0');
    if (died($bad)) { fail('AC-7: garbage => means=[]') } else { is_deeply($bad->{means}, [], 'AC-7: garbage => means=[] (never guesses)') }
}

# ---- AC-8: quote and whitespace handling
{
    my $q = try1(sub { BpJudge::parse_mandated_means(q{["a" , 'b' ,  c  ]}) });
    if (my $d = died($q)) { fail('AC-8: quotes/whitespace stripped'); diag("died: $d") }
    else { is_deeply($q->{means}, ['a', 'b', 'c'], 'AC-8: quotes/whitespace stripped') }
}

# ---- AC-10: classify_deviation — 'review' only on a genuinely non-blank justification
{
    my %base = (package => 'b03', means => 'libX', observed => 'shim');
    is(try1(sub { BpJudge::classify_deviation({ %base, justification_present => 1, justification => 'because ESM-only' }) }),
       'review', 'AC-10: justified => review');
    is(try1(sub { BpJudge::classify_deviation({ %base, justification_present => 1, justification => '' }) }),
       'fail', 'AC-10: present but empty why => fail');
    is(try1(sub { BpJudge::classify_deviation({ %base, justification_present => 1, justification => "   \t " }) }),
       'fail', 'AC-10: present but whitespace-only why => fail');
    is(try1(sub { BpJudge::classify_deviation({ %base, justification_present => 0 }) }),
       'fail', 'AC-10: absent justification => fail');
    is(try1(sub { BpJudge::classify_deviation({ package => 'b03' }) }),
       'ignore', 'AC-10: no deviation asserted => ignore');
}

# ---- AC-13: normalize_conformance is fail-closed
{
    field_is(try1(sub { BpJudge::normalize_conformance(undef) }), 'outcome', 'error', 'AC-13: undef => error');
    field_is(try1(sub { BpJudge::normalize_conformance({ _malformed => 1 }) }), 'outcome', 'error', 'AC-13: {_malformed} => error');
    field_is(try1(sub { BpJudge::normalize_conformance({ outcome => 'frobnicate' }) }), 'outcome', 'error', 'AC-13: unrecognized outcome => error');
    field_is(try1(sub { BpJudge::normalize_conformance({}) }), 'outcome', 'error', 'AC-13: missing outcome => error');
    field_is(try1(sub { BpJudge::normalize_conformance({ outcome => 'pass',
                 findings => [ { kind => 'conformance-deviation', severity => 'block' } ] }) }),
             'outcome', 'fail', 'AC-13: pass + non-empty findings is coerced to fail');
}

# ---- AC-27 (unit): fold_deps_check folds a BLOCK into a finding, kind preserved
{
    my $rep = { generated_at => 'x', now => 'x', project => '/p',
                blocks => [ { kind => 'eol_runtime', severity => 'block', subject => 'node',
                              detail => 'node 20 is EOL', evidence => {},
                              remedy => { action => 'bump_runtime' }, needs_justification => 0 } ],
                warns  => [] };
    my $f = try1(sub { BpJudge::fold_deps_check($rep) });
    if (my $d = died($f)) { fail("AC-27: $_") for ('one BLOCK => one finding', 'no review', 'kind preserved', 'severity', 'needs_justification'); diag("died: $d") }
    else {
        is(scalar @{ $f->{findings} || [] }, 1, 'AC-27: one BLOCK => one finding');
        is(scalar @{ $f->{reviews}  || [] }, 0, 'AC-27: a BLOCK produces no review');
        is($f->{findings}[0]{kind}, 'eol_runtime', 'AC-27: b04 kind is PRESERVED so b07 can dispatch on it');
        is($f->{findings}[0]{severity}, 'block', 'AC-27: severity=block');
        is($f->{findings}[0]{needs_justification}, 0, 'AC-27: needs_justification=0');
    }
    field_is($f, 'outcome_hint', 'fail', 'AC-27: outcome_hint=fail');
}

# ---- AC-28 (unit): a WARN becomes a review, never a finding
{
    my $rep = { blocks => [], warns => [ { kind => 'fresh_version', severity => 'warn', subject => 'left-pad',
                  detail => 'published 2 days ago', evidence => {},
                  remedy => { action => 'justify' }, needs_justification => 1 } ] };
    my $f = try1(sub { BpJudge::fold_deps_check($rep) });
    if (my $d = died($f)) { fail('AC-28: one WARN => one review'); fail('AC-28: a WARN produces NO finding'); diag("died: $d") }
    else {
        is(scalar @{ $f->{reviews}  || [] }, 1, 'AC-28: one WARN => one review');
        is(scalar @{ $f->{findings} || [] }, 0, 'AC-28: a WARN produces NO finding');
    }
    field_is($f, 'outcome_hint', 'pass', 'AC-28: warns alone do not force fail');
}

# ---- AC-29 (unit): an absent report is normal
{
    my $f = try1(sub { BpJudge::fold_deps_check(undef) });
    field_is($f, 'ok', 1, 'AC-29: absent report => ok=1 (absence is legal)');
    field_is($f, 'outcome_hint', 'pass', 'AC-29: absent report does not force fail');
    if (died($f)) { fail('AC-29: absent report => no findings'); fail('AC-29: absent report => a notice') }
    else {
        is(scalar @{ $f->{findings} || [] }, 0, 'AC-29: absent report => no findings');
        cmp_ok(scalar @{ $f->{notices} || [] }, '>=', 1, 'AC-29: absent report => a notice');
    }
}

# ---- AC-30 (unit): a malformed report is fail-closed
{
    my $m = try1(sub { BpJudge::fold_deps_check({ _malformed => 1 }) });
    field_is($m, 'ok', 0, 'AC-30: malformed report => ok=0');
    field_is($m, 'outcome_hint', 'error', 'AC-30: malformed report => outcome_hint=error');
    my $n = try1(sub { BpJudge::fold_deps_check({ blocks => 'nope', warns => [] }) });
    field_is($n, 'ok', 0, 'AC-30: blocks as a non-array => ok=0');
    field_is($n, 'outcome_hint', 'error', 'AC-30: blocks as a non-array => error');
}

# ---- AC-20 (unit): the three fire-once keys and the cap
{
    is(try1(sub { BpJudge::conformance_should_spawn({ inflight => 0, verdict_present => 0, spawns => 0, cap => 2 }) }),
       1, 'AC-20: nothing in flight, no verdict, under cap => spawn');
    is(try1(sub { BpJudge::conformance_should_spawn({ inflight => 1, verdict_present => 0, spawns => 0, cap => 2 }) }),
       0, 'AC-20: already in flight => do not spawn');
    is(try1(sub { BpJudge::conformance_should_spawn({ inflight => 0, verdict_present => 1, spawns => 0, cap => 2 }) }),
       0, 'AC-20: verdict already present => do not spawn (this key survives a restart)');
    is(try1(sub { BpJudge::conformance_should_spawn({ inflight => 0, verdict_present => 0, spawns => 1, cap => 1 }) }),
       0, 'AC-20: at cap => do not spawn');
}

# ---- AC-6: run_complete gains a flag and STAYS PURE
{
    my $idle = { any_running => 0, outstanding => 0, resume_pending => 0, paused => 0, awaiting_human => 0 };
    is(try1(sub { BpOrch::run_complete({ %$idle, conformance_outstanding => 1 }) }), 0,
       'AC-6: conformance outstanding => run_complete false');
    is(try1(sub { BpOrch::run_complete({ %$idle, conformance_outstanding => 0 }) }), 1,
       'AC-6: nothing outstanding => run_complete true');
    my $src = slurp("$Bin/../../scripts/bp-orchestrator.pl");
    my ($body) = $src =~ /\nsub\s+run_complete\s*\{(.*?)\n\}/s;
    ok(defined $body, 'AC-6: run_complete body located for the static purity scan');
    if (defined $body) {
        my @io = grep { $body =~ /(?<![\w:>])\Q$_\E\s*[\(\s]/ } qw(open opendir stat readdir unlink rename);
        push @io, '-e' if $body =~ /-e\s/;
        is_deeply(\@io, [], 'AC-6: run_complete body performs NO file I/O (purity)')
            or diag("found I/O tokens: @io");
    } else { fail('AC-6: run_complete body performs NO file I/O (purity)') }
}

# ===========================================================================
# PART 2 — orchestrator integration through the injected seams (spec §2.2, §3)
# ===========================================================================

# ---- AC-4: all done => exactly one conformance spawn for pseudo-package _run
{
    my $dir = mk_bp([ { name => 'A', status => 'done' }, { name => 'B', deps => 'A', status => 'done' } ]);
    my $r = tryrun($dir);
    my @c = conf_spawns($r);
    is(scalar @c, 1, 'AC-4: exactly one conformance judge spawned when all packages are done')
        or diag("err: " . ($r->{err} // 'none'));
    is(($c[0] ? $c[0]->{pkg} : undef), '_run', 'AC-4: spawned for pseudo-package _run');
    ok(defined try1(sub { BpOrch::judge_inflight("$dir/runs", 'conformance', '_run') }),
       'AC-4: conformance in-flight marker written');
}

# ---- AC-5: a blocked package => gate skipped + notice, run still exits
{
    my $dir = mk_bp([ { name => 'A', status => 'done' }, { name => 'B', status => 'blocked' } ]);
    my $r = tryrun($dir);
    is(scalar(conf_spawns($r)), 0, 'AC-5: no conformance spawn while a package is blocked');
    my ($f, $o) = find_any("$dir/runs/notices", qr/conformance gate skipped/i);
    ok(defined $f, 'AC-5: a "conformance gate skipped" notice was written');
    is_deeply(($o ? ($o->{evidence} || {})->{awaiting} : undef), ['B'],
              'AC-5: notice evidence.awaiting names the blocked package');
}

# ---- AC-9: unparseable mandated_means => notice, gate still fires
{
    my $dir = mk_bp([ { name => 'A', status => 'done', means => '{nested: {x: 1}}' },
                      { name => 'B', status => 'done' } ]);
    my $r = tryrun($dir);
    my ($f) = find_any("$dir/runs/notices", qr/unparseable mandated_means/i);
    ok(defined $f, 'AC-9: unparseable mandated_means => a notice');
    is(scalar(conf_spawns($r)), 1, 'AC-9: an unparseable means list does not stop the gate firing');
}

# ---- AC-11 + AC-25: documented+justified deviation => review, no finding, outcome pass
{
    my $dir = mk_bp([ { name => 'b03', status => 'done', means => '[libX]', body => $DEV_BODY_OK } ]);
    seed_verdict($dir, 'conformance', '_run', raw_dev_verdict('b03', outcome => 'pass'));
    my $r = tryrun($dir, read_verdict => sub { jget("$dir/runs/conformance/_run.verdict.json") });
    my @rev = reviews_of($dir);
    is(scalar @rev, 1, 'AC-11: a justified deviation writes exactly one review record')
        or diag("err: " . ($r->{err} // 'none'));
    my $o = @rev ? (jget($rev[0]) || {}) : {};
    for my $k (qw(package coordinator original_means change why ledger_marker)) {
        ok(defined $o->{$k} && length "$o->{$k}", "AC-11: review carries required field '$k'");
    }
    like(($o->{why} // ''), qr/ESM-only/, 'AC-11: review why= carries the argued justification verbatim');
    my $v = verdict_of($dir) || {};
    is(scalar @{ $v->{findings} || [] }, 0, 'AC-11: a justified deviation produces ZERO findings');
    is($v->{outcome}, 'pass', 'AC-11: reviews alone leave outcome=pass');
    my @tmp = grep { -e } glob("$dir/runs/*.tmp* $dir/runs/review/*.tmp* $dir/runs/notices/*.tmp*");
    is_deeply(\@tmp, [], 'AC-25: no *.tmp partial files remain after the run');
}

# ---- AC-12: undocumented deviation => FAIL finding naming means + offending files
{
    my $dir = mk_bp([ { name => 'b03', status => 'done', means => '[libX]', body => "- did the work, said nothing\n" } ]);
    seed_verdict($dir, 'conformance', '_run', raw_dev_verdict('b03'));
    my $r = tryrun($dir, read_verdict => sub { jget("$dir/runs/conformance/_run.verdict.json") });
    my @rev12 = reviews_of($dir);
    is(scalar @rev12, 0, 'AC-12: an undocumented deviation writes NO review');
    my $v = verdict_of($dir) || {};
    my @f = @{ $v->{findings} || [] };
    is(scalar @f, 1, 'AC-12: exactly one finding for the undocumented deviation')
        or diag("err: " . ($r->{err} // 'none'));
    if (@f) {
        is($f[0]{kind}, 'conformance-deviation', 'AC-12: kind=conformance-deviation');
        is($f[0]{severity}, 'block', 'AC-12: severity=block');
        is(($f[0]{needs_justification} ? 1 : 0), 0, 'AC-12: needs_justification=false');
        is($f[0]{subject}, 'b03', 'AC-12: subject names the package');
        is(($f[0]{evidence} || {})->{means}, 'libX', 'AC-12: evidence.means names the deviated-from means');
        is_deeply(($f[0]{evidence} || {})->{files}, ['src/chat/Bubble.tsx'],
                  'AC-12: evidence.files names the offending files (so b07 can scope a fix)');
    } else {
        fail('AC-12: kind=conformance-deviation'); fail('AC-12: severity=block');
        fail('AC-12: needs_justification=false');  fail('AC-12: subject names the package');
        fail('AC-12: evidence.means names the deviated-from means');
        fail('AC-12: evidence.files names the offending files (so b07 can scope a fix)');
    }
    is($v->{outcome}, 'fail', 'AC-12: outcome=fail');
}

# ---- AC-10 (integration): a blank why= must NOT buy a review — no forged justification
{
    my $dir = mk_bp([ { name => 'b03', status => 'done', means => '[libX]', body => $DEV_BODY_BLANK_WHY } ]);
    seed_verdict($dir, 'conformance', '_run', raw_dev_verdict('b03'));
    tryrun($dir, read_verdict => sub { jget("$dir/runs/conformance/_run.verdict.json") });
    my @rev10 = reviews_of($dir);
    is(scalar @rev10, 0, 'AC-10: a MEANS-DEVIATION with a blank why= earns no review');
    is((verdict_of($dir) || {})->{outcome}, 'fail', 'AC-10: blank why= stays a FAIL (no silent downgrade)');
}

# ---- AC-14: the authoritative verdict is written and schema-valid, even with no raw verdict
{
    my $dir = mk_bp([ { name => 'A', status => 'done' } ]);
    # Simulate a judge that was spawned and never produced a verdict, with judge_to
    # already elapsed — the REAL timeout path (spec §3.1.5). A missing verdict on the
    # tick right after spawn is normal for a detached judge and must NOT be reported as
    # an error; only an elapsed judge_to makes it one.
    make_path("$dir/runs/conformance");
    BpOrch::mark_judge_inflight("$dir/runs", 'conformance', '_run', $NOW - 4000);
    tryrun($dir, read_verdict => sub { undef }, tun => { judge_to => 1800 });
    my $v = verdict_of($dir);
    ok(defined $v, 'AC-14: runs/conformance-verdict.json is written when the judge times out with no verdict');
    $v ||= {};
    is($v->{schema}, 'conformance-verdict/1', 'AC-14: schema=conformance-verdict/1');
    ok(exists $v->{raw_verdict_path}, 'AC-14: carries raw_verdict_path');
    # must be PRESENT-and-false, not merely absent (an absent verdict must not satisfy this)
    ok(exists $v->{raw_ok} && !$v->{raw_ok}, 'AC-14: raw_ok is present and false when the raw verdict is absent');
    is($v->{outcome}, 'error', 'AC-14: absent raw verdict => outcome=error (never a silent pass)');
    is(ref($v->{$_}), 'ARRAY', "AC-14: $_ is an array") for qw(packages findings reviews notices);
}

# ---- AC-15: channels are written by the ORCHESTRATOR — no judge Write tool involved
{
    my $dir = mk_bp([ { name => 'b03', status => 'done', means => '[libX]', body => $DEV_BODY_OK } ]);
    seed_verdict($dir, 'conformance', '_run', raw_dev_verdict('b03', outcome => 'pass'));
    tryrun($dir, read_verdict => sub { jget("$dir/runs/conformance/_run.verdict.json") });
    cmp_ok(scalar(reviews_of($dir)), '>=', 1,
           'AC-15: the review channel materializes from the injected read_verdict seam alone');
    ok(-f "$dir/runs/conformance-verdict.json",
       'AC-15: the authoritative verdict materializes with no judge process at all');
}

# ---- AC-16: injected build_runner failure => build finding + fail
{
    my $dir = mk_bp([ { name => 'A', status => 'done' } ]);
    my $calls = 0;
    tryrun($dir, build_runner => sub { $calls++; { ok => 0, exit => 1, stdout => '', stderr => 'boom' } },
                 read_verdict => sub { { outcome => 'pass', findings => [] } });
    my $v = verdict_of($dir) || {};
    is((($v->{build} || {})->{ran} ? 1 : 0), 1, 'AC-16: verdict records build.ran=true');
    # present-and-false: an absent verdict/build block must NOT satisfy this
    ok(ref $v->{build} eq 'HASH' && exists $v->{build}{ok} && !$v->{build}{ok},
       'AC-16: verdict records build.ok present and false');
    is(scalar(grep { ($_->{kind} // '') eq 'conformance-build-failure' } @{ $v->{findings} || [] }), 1,
       'AC-16: a red build yields one conformance-build-failure finding');
    is($v->{outcome}, 'fail', 'AC-16: a red build forces outcome=fail');
    cmp_ok($calls, '<=', 1, 'AC-16: build_runner is invoked at most once per gate firing');
}

# ---- AC-17: no build configured => build.ran false, deviations still decide
{
    my $dir = mk_bp([ { name => 'b03', status => 'done', means => '[libX]', body => "- silent\n" } ]);
    seed_verdict($dir, 'conformance', '_run', raw_dev_verdict('b03'));
    tryrun($dir, build_runner => undef,
                 read_verdict => sub { jget("$dir/runs/conformance/_run.verdict.json") });
    my $v = verdict_of($dir) || {};
    # present-and-false, and only meaningful if the verdict itself was written
    ok(ref $v->{build} eq 'HASH' && exists $v->{build}{ran} && !$v->{build}{ran},
       'AC-17: no build configured => build.ran present and false');
    ok(ref $v->{findings} eq 'ARRAY'
       && 0 == (grep { ($_->{kind} // '') eq 'conformance-build-failure' } @{ $v->{findings} }),
       'AC-17: findings[] exists and carries no build-derived finding');
    is($v->{outcome}, 'fail', 'AC-17: the gate can still fail on deviations alone');
}

# ---- AC-18: two consecutive ticks spawn the judge once in total
{
    my $dir = mk_bp([ { name => 'A', status => 'done' } ]);
    my $r1 = tryrun($dir);
    my $r2 = tryrun($dir);
    is(scalar(conf_spawns($r1)) + scalar(conf_spawns($r2)), 1,
       'AC-18: fire-once across two ticks (the in-flight marker suppresses the second)');
}

# ---- AC-19: restart idempotence — a verdict already on disk means never respawn
{
    my $dir = mk_bp([ { name => 'A', status => 'done' } ]);
    open my $w, '>', "$dir/runs/conformance-verdict.json" or die;
    print $w $J->encode({ schema => 'conformance-verdict/1', outcome => 'pass', generated_at => 'earlier',
                          packages => [], findings => [], reviews => [], notices => [] });
    close $w;
    my $before = slurp("$dir/runs/conformance-verdict.json");
    my $r = tryrun($dir);
    is(scalar(conf_spawns($r)), 0, 'AC-19: an existing authoritative verdict suppresses respawn after a restart');
    is(slurp("$dir/runs/conformance-verdict.json"), $before,
       'AC-19: the existing verdict is not rewritten with a fresh generated_at');
}

# ---- AC-20 (integration): at the cap, notice + exit
{
    my $dir = mk_bp([ { name => 'A', status => 'done' } ]);
    my $r = tryrun($dir, tun => { conformance_spawn_cap => 0 });
    is(scalar(conf_spawns($r)), 0, 'AC-20: a spawn cap of 0 prevents any conformance spawn');
    my ($f) = find_any("$dir/runs/notices", qr/conformance spawn cap/i);
    ok(defined $f, 'AC-20: a "conformance spawn cap reached" notice is written');
}

# ---- AC-21: NEGATIVE — the gate never pages a human (blueprint Decision #20)
{
    for my $case ([ 'fail', raw_dev_verdict('b03') ], [ 'error', undef ],
                  [ 'pass', { outcome => 'pass', findings => [] } ]) {
        my ($label, $raw) = @$case;
        my $dir = mk_bp([ { name => 'b03', status => 'done', means => '[libX]', body => "- silent\n" } ]);
        tryrun($dir, read_verdict => sub { $raw });
        is(scalar(needs_you_of($dir)), 0, "AC-21 [$label]: no needs-you decision is ever queued");
        unlike(slurp("$dir/packages/b03.md"), qr/^status:\s*(blocked|parked)/m,
               "AC-21 [$label]: the gate never flips a package to blocked/parked");
    }
}

# ---- AC-26: b07 boundary — b05 writes findings and stops
{
    my $dir = mk_bp([ { name => 'b03', status => 'done', means => '[libX]', body => "- silent\n" } ]);
    my $dag_before = slurp("$dir/blueprint.md");
    seed_verdict($dir, 'conformance', '_run', raw_dev_verdict('b03'));
    tryrun($dir, read_verdict => sub { jget("$dir/runs/conformance/_run.verdict.json") });
    # RETARGETED by b07-auto-remediation-engine (operator RULING 1, 2026-07-29).
    #
    # WAS: ok(!-e "$dir/runs/remediation-queue.json",
    #          'AC-26: b05 does NOT create runs/remediation-queue.json (that is b07)');
    #
    # Why the old form is now wrong: absence of that file was only ever a PROXY
    # for "b05 stays in its lane", and it held solely because nothing in the
    # fleet could create it. b07 is now exactly that thing, and it legitimately
    # writes the queue from the same orchestrator run this fixture drives — its
    # own oracle (t/26 AC-30) REQUIRES the write even with zero entries. So the
    # absence check had stopped testing b05's restraint and started testing
    # b07's non-existence. Obsolete boundary, not a violated b05 invariant.
    #
    # RETARGET, not a weakening — the intent is asserted directly and in two
    # independent ways, kept as ONE assertion so this file stays at 175:
    #   (a) STATIC: b05's own module carries no remediation-queue code at all,
    #       so b05 cannot create that file by any path. Stronger than the old
    #       runtime check, which a lucky ordering could have satisfied.
    #   (b) RUNTIME: whatever queue IS on disk is b07-shaped. If b05 ever
    #       authored a bespoke or malformed queue of its own, this still fails.
    my $judge_src26 = slurp("$Bin/../../scripts/bp-judge.pl");
    my $q26 = -e "$dir/runs/remediation-queue.json" ? jget("$dir/runs/remediation-queue.json") : undef;
    ok($judge_src26 !~ /remediation-queue/
       && (!defined $q26 || ($q26->{schema} // '') eq 'remediation-queue/1'),
       'AC-26: b05 stays in its lane — bp-judge.pl contains no remediation-queue code, and any queue on disk is b07-shaped (schema remediation-queue/1)');
    is(slurp("$dir/blueprint.md"), $dag_before, 'AC-26: b05 does not append to the DAG');
}

# ---- AC-27/28 (integration) + AC-31: deps-check ingestion end to end
{
    my $dir = mk_bp([ { name => 'A', status => 'done' } ]);
    my $depsf = seed_deps($dir, { generated_at => 'x', now => 'x', project => '/p',
        blocks => [ { kind => 'eol_runtime', severity => 'block', subject => 'node',
                      detail => 'node 20 is EOL', evidence => {},
                      remedy => { action => 'bump_runtime' }, needs_justification => 0 } ],
        warns => [] });
    my $before = slurp($depsf);
    tryrun($dir, read_verdict => sub { { outcome => 'pass', findings => [] } });
    my $v = verdict_of($dir) || {};
    is(scalar(grep { ($_->{kind} // '') eq 'eol_runtime' } @{ $v->{findings} || [] }), 1,
       'AC-27: a deps-check BLOCK folds into the verdict findings for b07');
    is($v->{outcome}, 'fail', 'AC-27: a deps-check BLOCK forces outcome=fail with no deviation present');
    is(slurp($depsf), $before, 'AC-31: runs/deps-check.json is byte-identical after the run (read-only)');
}
{
    my $dir = mk_bp([ { name => 'A', status => 'done' } ]);
    seed_deps($dir, { blocks => [], warns => [ { kind => 'fresh_version', severity => 'warn',
        subject => 'left-pad', detail => 'published 2 days ago', evidence => {},
        remedy => { action => 'justify' }, needs_justification => 1 } ] });
    tryrun($dir, read_verdict => sub { { outcome => 'pass', findings => [] } });
    my $v = verdict_of($dir) || {};
    is(scalar @{ $v->{findings} || [] }, 0, 'AC-28: a deps-check WARN produces no finding');
    cmp_ok(scalar(reviews_of($dir)), '>=', 1, 'AC-28: a deps-check WARN lands in the review channel');
    is($v->{outcome}, 'pass', 'AC-28: warns alone leave outcome=pass');
}

# ---- AC-29 (integration): a missing deps-check report is normal
{
    my $dir = mk_bp([ { name => 'A', status => 'done' } ]);
    ok(!-e "$dir/runs/deps-check.json", 'AC-29: the fixture genuinely has no deps-check report');
    my $r = tryrun($dir, read_verdict => sub { { outcome => 'pass', findings => [] } });
    my ($f) = find_any("$dir/runs/notices", qr/deps-check report absent/i);
    ok(defined $f, 'AC-29: a "deps-check report absent" notice is written');
    is((verdict_of($dir) || {})->{outcome}, 'pass', 'AC-29: an absent report does not change outcome');
    is($r->{err}, undef, 'AC-29: an absent report never throws');
}

# ---- AC-30 (integration): a malformed deps-check report is fail-closed
{
    my $dir = mk_bp([ { name => 'A', status => 'done' } ]);
    seed_deps($dir, '{ this is not json ');
    my $r = tryrun($dir, read_verdict => sub { { outcome => 'pass', findings => [] } });
    my ($f) = find_any("$dir/runs/notices", qr/deps-check report malformed/i);
    ok(defined $f, 'AC-30: a "deps-check report malformed" notice is written');
    is((verdict_of($dir) || {})->{outcome}, 'error', 'AC-30: a malformed report => outcome=error');
    is($r->{err}, undef, 'AC-30: a malformed report never throws');
}

# ---- AC-32: the EXPLICIT LIST is the only source of mandated means, never prose
{
    my $prose = "- we evaluated libX and hand-rolled a substitute instead of libX\n";
    my $dir = mk_bp([ { name => 'b03', status => 'done', means => '[]', body => $prose } ]);
    seed_verdict($dir, 'conformance', '_run', raw_dev_verdict('b03'));
    tryrun($dir, read_verdict => sub { jget("$dir/runs/conformance/_run.verdict.json") });
    is(scalar(grep { ($_->{kind} // '') eq 'conformance-deviation' } @{ (verdict_of($dir) || {})->{findings} || [] }), 0,
       'AC-32: prose naming libX with mandated_means: [] yields NO deviation finding');

    my $dir2 = mk_bp([ { name => 'b03', status => 'done', means => '[libX]', body => $prose } ]);
    seed_verdict($dir2, 'conformance', '_run', raw_dev_verdict('b03'));
    tryrun($dir2, read_verdict => sub { jget("$dir2/runs/conformance/_run.verdict.json") });
    is(scalar(grep { ($_->{kind} // '') eq 'conformance-deviation' } @{ (verdict_of($dir2) || {})->{findings} || [] }), 1,
       'AC-32: the same prose WITH mandated_means: [libX] yields one deviation finding');
}

# ===========================================================================
# PART 3 — regressions (harvest/resolve untouched), bp-judge.sh, agent md, docs
# ===========================================================================

# ---- AC-22: the per-package harvest default is still 'audit'
{
    is(BpJudge::harvest_mode(undef), 'audit', 'AC-22: harvest_mode(undef) is still audit');
    is(BpJudge::harvest_mode(''),    'audit', 'AC-22: harvest_mode("") is still audit');
    like(slurp("$Bin/../../scripts/bp-orchestrator.pl"),
         qr/harvest\s*=>\s*\$ENV\{BP_HARVEST_MODE\}\s*\/\/\s*'audit'/,
         'AC-22: the orchestrator tunable default is still audit');
}

# ---- AC-23/AC-24: bp-judge.sh gains conformance without breaking harvest/resolve
{
    my $sh  = "$Bin/../../scripts/bp-judge.sh";
    my $src = -r $sh ? slurp($sh) : '';
    ok(length $src, 'AC-23: bp-judge.sh is readable');
    # Parse the allow-list and check MEMBERSHIP, rather than pinning the literal
    # string `harvest|resolve|conformance)`. That form pinned the closing paren,
    # so adding a fourth kind (escalation-resolve, 2026-08-24) turned red an
    # assertion whose own description only cares that these three are accepted.
    # Same over-specification this repo has now paid for in t/115, t/145 and
    # t/26: an oracle asserting more than it means.
    my ($allow) = $src =~ /case\s+"\$KIND"\s+in\s+([a-z|\-]+)\)/;
    ok(defined $allow, 'AC-23: the KIND allow-list is parseable') or diag('no case line found');
    my %accepted = map { $_ => 1 } split /\|/, ($allow // '');
    ok(!grep({ !$accepted{$_} } qw(harvest resolve conformance)),
       'AC-23: KIND validation accepts harvest|resolve|conformance')
        or diag('allow-list: ' . ($allow // '(none)'));
    unlike($src, qr/^\[\s*-f\s*"\$LEDGER"\s*\]\s*\|\|\s*\{[^\n]*exit 1/m,
           'AC-23: the per-package ledger requirement is no longer unconditional (_run has no ledger)');
    ok(!-e "$Bin/../../templates/judge-conformance.md",
       'AC-23: no templates/judge-conformance.md exists (that path is outside the write set)');
    like($src, qr/BP_CONFORMANCE_MODEL/,     'AC-24: honors BP_CONFORMANCE_MODEL');
    like($src, qr/BP_CONFORMANCE_MAX_TURNS/, 'AC-24: honors BP_CONFORMANCE_MAX_TURNS');
    like($src, qr/conformance/,              'AC-24: has a conformance branch');
}

# ---- the new judge agent contract must exist and be initiative-scoped
{
    my $md = "$Bin/../../agents/bp-conformance-judge.md";
    ok(-f $md, 'agent contract plugins/butler/agents/bp-conformance-judge.md exists');
    my $t = -f $md ? slurp($md) : '';
    like($t, qr/^name:\s*bp-conformance-judge/m, 'agent md declares name: bp-conformance-judge');
    like($t, qr/^model:/m,         'agent md declares a model');
    like($t, qr/^maxTurns:/m,      'agent md declares maxTurns');
    like($t, qr/^tools:/m,         'agent md declares tools');
    like($t, qr/Output contract/i, 'agent md has an Output contract section');
    like($t, qr/blueprint\.md/,    'agent md is initiative-scoped (reads blueprint.md)');
    like($t, qr/mandated_means/,   'agent md checks mandated_means');
}

# ---- docs: both protocols document the gate, and the marker matches the parser literally
{
    like(slurp("$Bin/../../skills/orchestrator-protocol/SKILL.md"), qr/^###\s+Conformance gate/m,
         'orchestrator-protocol documents the conformance gate');
    like(slurp("$Bin/../../skills/orchestrator-protocol/SKILL.md"), qr/_run/,
         'orchestrator-protocol names the _run pseudo-package');
    my $cp = slurp("$Bin/../../skills/coordinator-protocol/SKILL.md");
    like($cp, qr/^##\s+Mandated means & deviations/m, 'coordinator-protocol documents the mandated-means duty');
    like($cp, qr/MEANS-DEVIATION:/,
         'coordinator-protocol states the MEANS-DEVIATION marker literally (must match the parser)');
}

# ===========================================================================
# PART 4 — regression guards for holes the coordinator's own red-team found
# (these are NOT spec ACs; they exist so a fixed vulnerability cannot silently
#  return. All three were live defects in the first implementation.)
# ===========================================================================
{
    my $hdr = "## Decisions & attempt log\n\n";
    my $line = "- MEANS-DEVIATION: means=libX change=shim why=forged\n";
    # RT-1: BOTH fence styles must hide a marker. Only ``` was handled, so a ~~~
    # fence let a forged justification through and silently suppressed remediation.
    for my $f (['```', 'backtick'], ['~~~', 'tilde']) {
        my $txt = $hdr . "$f->[0]\n" . $line . "$f->[0]\n";
        is_deeply(BpJudge::parse_means_deviations($txt), {},
                  "RT-1: a $f->[1]-fenced MEANS-DEVIATION is NOT a justification (forgery blocked)");
    }
    # a real marker still works
    ok(BpJudge::parse_means_deviations($hdr . "- MEANS-DEVIATION: means=libX change=shim why=genuine reason\n")->{libX},
       'RT-1: an unfenced marker is still parsed');
    # RT-2: CRLF ledgers must parse
    ok(BpJudge::parse_means_deviations($hdr . "- MEANS-DEVIATION: means=libX change=shim why=crlf ok\r\n")->{libX},
       'RT-2: a CRLF ledger still yields a marker');
    # RT-3: deps-check must be fail-closed on the severity FIELD, not just the array
    my $spoof = BpJudge::fold_deps_check({ blocks => [], warns => [ { kind => 'k', severity => 'block',
        subject => 's', detail => 'd', evidence => {}, remedy => { action => 'x' },
        needs_justification => 0 } ] });
    is(scalar @{ $spoof->{findings} }, 1,
       'RT-3: a warns[] entry labelled severity=block is treated as BLOCKING (no downgrade)');
    is($spoof->{outcome_hint}, 'fail', 'RT-3: and it forces outcome_hint=fail');
    # RT-4: _slug must never escape its directory
    for my $s ('../../etc/passwd', '/abs/path', 'lib/X') {
        unlike(BpOrch::_slug($s), qr{/|\.\.}, "RT-4: _slug('$s') cannot escape runs/review/");
    }
    # RT-6: every field's lookahead must name every other field. Omitting `\s+who=`
    # made `why=` swallow a trailing " who=<id>" into the justification text while
    # `who` was never captured (found by bp-reviewer).
    my $full = BpJudge::parse_means_deviations(
        $hdr . "- MEANS-DEVIATION: means=libX change=shim why=real reason who=b03-coord\n")->{libX};
    is($full->{why}, 'real reason', 'RT-6: why= stops at who= and is not polluted by it');
    is($full->{who}, 'b03-coord',   'RT-6: who= is captured');
    is($full->{change}, 'shim',     'RT-6: change= is unaffected');
    # order-independent: who= before why=
    my $alt = BpJudge::parse_means_deviations(
        $hdr . "- MEANS-DEVIATION: means=libX who=someone change=shim why=because\n")->{libX};
    is($alt->{who}, 'someone', 'RT-6: who= parsed when it precedes the other fields');
    is($alt->{why}, 'because', 'RT-6: why= parsed when who= precedes it');
    # RT-7: a missing verdict right after spawn is NOT a timeout — the run must stay
    # open rather than publishing outcome=error for the judge's whole real run time.
    {
        my $d2 = mk_bp([ { name => 'A', status => 'done' } ]);
        my $r2 = tryrun($d2, read_verdict => sub { undef }, tun => { judge_to => 1800 });
        is(scalar(conf_spawns($r2)), 1, 'RT-7: the gate still fires');
        ok(!defined verdict_of($d2),
           'RT-7: no authoritative verdict is published on the tick the judge was spawned');
    }
    # RT-5: a sloppy ledger status must not silently skip the whole gate
    is(BpJudge::conformance_ready({ A => { status => 'Done' } })->{ready}, 1,
       'RT-5: status "Done" is treated as done (a capital must not skip the gate)');
    is(BpJudge::conformance_ready({ A => { status => 'done ' } })->{ready}, 1,
       'RT-5: status "done " is treated as done (trailing space must not skip the gate)');
}

done_testing();
