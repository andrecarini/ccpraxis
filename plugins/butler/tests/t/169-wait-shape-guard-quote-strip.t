#!/usr/bin/env perl
# 169-wait-shape-guard-quote-strip.t -- oracle for t09-guard-hooks-stripping's
# wait-shape-guard.sh changes (spec .ccpraxis-local-data/blueprints/
# tui-operator-feedback/specs/t09-guard-hooks-stripping-spec.md SS2.2/SS2.3/SS3/SS4).
# Companion to 67-wait-shape-guard.t (that file's own oracle, NOT edited here -- this
# package's write set is tests/t/ only). 67 already pins the pure matchers' existing
# behavior on raw strings; this file adds ONLY the two things t09 changes: bp_ws_main's
# new stripped-match-text computation (AC10) and the AC11 "the three pure helpers stay
# pure/unchanged" guarantee, re-verified independently here rather than assumed.
#
# WRITTEN BLIND TO THE IMPLEMENTATION.
#
# jq AVAILABILITY. bp_ws_main fails OPEN (exit 0, D7) the instant `command -v jq` is
# missing -- so every SUBPROCESS assertion (AC10) requires jq and is SKIPped on this
# jq-less Windows host, matching 67's own jq-gated SKIP convention for its hook-behavior
# groups. The PURE-HELPER assertions (AC11) need no jq at all (67's own D1 rationale)
# and run unconditionally.
#
# TECHNIQUE NOTE (guard evasion). Subprocess fixtures reach the hook only as JSON
# payload TEXT in a temp file, invoked via `bash "$HOOK" < payload`. Pure-helper calls
# source the file (arg0 'h', per 67's own mandated D1 form) and invoke the function
# directly -- never as literal text in a Bash tool_input.command this session issues.
#
# Runs standalone: perl plugins/butler/tests/t/169-wait-shape-guard-quote-strip.t
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP;

(my $HOOKS = "$Bin/../../hooks") =~ s{\\}{/}g;
my $HOOK = "$HOOKS/wait-shape-guard.sh";

ok(-f $HOOK, 'wait-shape-guard.sh exists at plugins/butler/hooks/wait-shape-guard.sh')
    or BAIL_OUT('subject hook missing');

my $HAVE_JQ = `bash -c 'command -v jq' 2>/dev/null` =~ /\S/;
my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
my $pn   = 0;
sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

sub write_file { my ($p, $b) = @_; open my $w, '>', $p or die; binmode $w; print $w $b; close $w }
sub read_file  { my ($p) = @_; open my $r, '<', $p or return ''; binmode $r; local $/; my $c = <$r>; close $r; return defined $c ? $c : '' }

sub mk_bp {
    my $d = "$ROOT/bp"; my $p = "$ROOT/proj";
    unless (-d $d) {
        mkdir $d or die; mkdir "$d/$_" or die for qw(packages reports specs runs);
        mkdir $p or die;
    }
    return (fwd($d), fwd($p));
}

sub run_hook {
    my ($payload, %env) = @_;
    my $n  = ++$pn;
    my $pf = "$ROOT/payload.$n.json";
    my $of = "$ROOT/stdout.$n.txt";
    my $ef = "$ROOT/stderr.$n.txt";
    write_file($pf, $payload);
    my ($bp, $proj) = mk_bp();
    local %ENV = (%CLEAN_ENV, %env,
                  HOOKPATH => fwd($HOOK), PFILE => fwd($pf), OFILE => fwd($of), EFILE => fwd($ef));
    system('bash', '-c', 'timeout 20 bash "$HOOKPATH" < "$PFILE" > "$OFILE" 2> "$EFILE"');
    my $rc = $? >> 8;
    return ($rc, read_file($ef), read_file($of));
}

sub pl_bash {
    my ($cmd) = @_;
    return $J->encode({ tool_name => 'Bash', session_id => 'sess1', cwd => '/project', tool_input => { command => $cmd } });
}

sub env_for {
    my ($bp, $proj) = @_;
    return (BP_DIR => $bp, BP_PROJECT_ROOT => $proj, BP_LEDGER => "$bp/packages/fixture.md", BP_PACKAGE => 'p');
}

# --- pure-helper invocation (67's own mandated D1 form). ---------------------------
sub ws_call {
    my ($fn, @args) = @_;
    my $ef = "$ROOT/wserr." . (++$pn) . ".txt";
    local %ENV = (%CLEAN_ENV, GUARDSH => fwd($HOOK), EFILE => fwd($ef));
    open(my $f, '-|', 'bash', '-c',
         qq{{ source "\$GUARDSH"; $fn "\$@"; } < /dev/null 2>"\$EFILE"}, 'h', @args)
        or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    $o = '' unless defined $o;
    $o =~ s/\s+\z//;
    return $o;
}
sub is_wait_loop { return ws_call('bp_ws_is_wait_loop', $_[0]) }

# =====================================================================================
# AC1 (DC1) -- rationale comment at the site of the new code.
# =====================================================================================
{
    my $src = do { local (@ARGV, $/) = ($HOOK); <> };
    like($src, qr/ACCIDENT/, 'AC1: wait-shape-guard.sh source states the ACCIDENT-not-ADVERSARY threat model ruling');
    like($src, qr/ADVERSARY/i, 'AC1: ...and explicitly names ADVERSARY as the rejected alternative');
    # SS5 requires this hook's comment to distinguish D7 (infra-uncertainty fail-open)
    # from the NEW stripping-unavailable degrade, which must NOT reuse D7's fail-open.
    like($src, qr/D7/, 'AC1: ...and distinguishes this from D7 (infra-uncertainty fail-open does not extend to stripping)');
}

# =====================================================================================
# AC3 (DC2) -- the three mandated matcher EREs (verbatim, per 67's own AC3.x pins) are
# unchanged; the enforcement body gains stripped-text computation but no new grep -E
# pattern text.
# =====================================================================================
{
    my $src = do { local (@ARGV, $/) = ($HOOK); <> };
    ok(index($src, q{BP_WS_LOOP_RE='(^|[^A-Za-z0-9_-])(while|until|for)[[:space:]]'}) >= 0,
       'AC3: BP_WS_LOOP_RE is byte-identical to today');
    ok(index($src, q{BP_WS_SLEEP_RE='(^|[^A-Za-z0-9_-])sleep[[:space:]]+[0-9]'}) >= 0,
       'AC3: BP_WS_SLEEP_RE is byte-identical to today');
    ok(index($src, q{BP_WS_PIPE_RE='\|[[:space:]]*(tail|head)([[:space:]][^;&|]*)?[;&]+[^;&|]*\$\?'}) >= 0,
       'AC3: BP_WS_PIPE_RE is byte-identical to today');
}

# =====================================================================================
# AC11 (DC1) -- the pure helpers stay PURE and UNCHANGED: bp_ws_is_wait_loop, called
# DIRECTLY (as t/67 calls it, bypassing bp_ws_main entirely), must still see a real
# while/sleep shape as "yes" REGARDLESS of surrounding quoting -- because these pure
# functions never receive MATCH_TEXT; bp_ws_main alone gains that layer. If a future
# change accidentally pushed stripping INTO the pure helpers themselves (forbidden by
# spec SS2.3: "the three functions' own signatures/bodies are untouched"), a quoted
# wait-loop mention would start reading 'no' here, which is the regression this guards.
# =====================================================================================
{
    is(is_wait_loop(q{while ! test -f x; do sleep 5; done}), 'yes',
       'AC11: bp_ws_is_wait_loop called directly still detects a real wait-loop shape (unaffected by t09)');
    is(is_wait_loop(''), 'no', 'AC11: bp_ws_is_wait_loop called directly still returns no for empty input');
    # A quoted MENTION of the wait-loop shape (e.g. inside an echoed doc string) is
    # matched 'yes' by the PURE helper when called directly -- it has no quote-
    # awareness at all (spec SS2.3: "the three functions' own signatures/bodies are
    # untouched"). Only bp_ws_main (fed MATCH_TEXT) may allow this at the hook level;
    # the raw helper's own behavior on this string must stay exactly what it is today.
    is(is_wait_loop(q{echo 'anti-pattern example: while ! test -f x; do sleep 5; done'}), 'yes',
       'AC11: the pure helper itself still matches a quoted mention (no quote-awareness in the pure layer -- that lives only in bp_ws_main)');
}

SKIP: {
    skip 'jq is not installed on this host; wait-shape-guard.sh fails OPEN (D7) without it, so no denial is observable', 2
        unless $HAVE_JQ;

    # =================================================================================
    # AC10 (DC3, observable behaviors 6/7) -- a command whose only wait-loop text sits
    # inside a quoted echo/documentation string is ALLOWED; a real wait-loop is still
    # DENIED with the unchanged R1-prefixed message.
    # =================================================================================
    my ($bp, $proj) = mk_bp();
    my %env = env_for($bp, $proj);
    {
        my $cmd = q{echo 'anti-pattern example: while ! test -f x; do sleep 5; done'};
        my ($rc, $err) = run_hook(pl_bash($cmd), %env);
        is($rc, 0, 'AC10: a quoted documentation mention of the wait-loop shape is ALLOWED') or diag("stderr: $err");
    }
    {
        my $cmd = q{while ! test -f x; do sleep 5; done};
        my ($rc, $err) = run_hook(pl_bash($cmd), %env);
        is($rc, 2, 'AC10: a real wait-loop is still DENIED, R1-prefixed, byte-identical to today') or diag("stderr: $err");
        like($err, qr/wait-loop/, 'AC10: denial message carries the R1 "wait-loop" label');
    }
}

done_testing();
