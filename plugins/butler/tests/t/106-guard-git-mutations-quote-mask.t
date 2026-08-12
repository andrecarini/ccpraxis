#!/usr/bin/env perl
# t/106-guard-git-mutations-quote-mask.t — a02-api-and-guard-defects, DEFECT 6.
#
# guard-git-mutations.sh greps the WHOLE command STRING (:48, :56), so prose that
# merely QUOTES/mentions "git stash" or "git reset --hard" inside e.g. a
# `--text "..."` argument is blocked exactly like a real invocation. Spec §2.7 /
# AC-16..AC-20.
#
# THIS HOOK IS NOT GATED. It is registered in .claude/settings.json and guards
# THIS driving session's own git calls right now (t/61 C5b guards that
# registration). This file invokes it ONLY as a subprocess with crafted
# payloads on stdin -- it never touches this session's real git state, and every
# invocation below is fully self-contained (its own tempdir, its own env).
#
# WRITTEN BLIND TO THE IMPLEMENTATION. AC-16 (the reported case: a --text
# argument merely quoting "git stash") is expected to FAIL against the
# pre-change tree -- today the raw-string grep denies it. Every AC-17/18/19/20
# case is a "must still behave exactly as today" regression guard and is
# expected to PASS unchanged (both hooks pre- and post-fix must deny/allow these
# identically, per spec §5.1's self-affecting-hook containment).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP;

(my $HOOKS = "$Bin/../../hooks") =~ s{\\}{/}g;
my $GUARD  = "$HOOKS/guard-git-mutations.sh";

my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

# Strip ALL ambient BP_* (this test may itself run inside a coordinator/judge
# session that exports them) -- the hook is deliberately ungated, so an
# inherited var must not change what these cases exercise. Mirrors t/98's
# %CLEAN_ENV discipline (that file's own comment documents the failure mode).
my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

my $pn = 0;
sub run_guard {
    my ($cmd) = @_;
    my $n = ++$pn;
    my $payload = $J->encode({ tool_name => 'Bash', tool_input => { command => $cmd } });
    my $pf = "$ROOT/payload.$n.json";
    open my $w, '>', $pf or die; print $w $payload; close $w;
    local %ENV = (%CLEAN_ENV, GPATH => fwd($GUARD), PFILE => fwd($pf));
    open(my $f, '-|', 'bash', '-c', '"$GPATH" < "$PFILE" 2>&1') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    return ($? >> 8, $o);
}

# ── AC-16: the REPORTED case -- --text merely QUOTES "git stash" in prose ───────
{
    my $cmd = q{perl bp-blueprint.pl add-decision --file f --id 20 --text "a prohibited git stash destroyed a completed fix-batch"};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 0, 'AC-16: add-decision --text merely quoting "git stash" in prose is ALLOWED') or diag("hook output: $out");
}
{
    my $cmd = q{git commit -m "stop reaching for git stash"};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 0, 'AC-16(sibling): git commit -m mentioning "git stash" in the message is ALLOWED') or diag("hook output: $out");
}

# ── AC-19: read-only / commit forms stay allowed (must never regress) ──────────
for my $cmd (
    q{git commit -F -},
    q{git diff},
    q{git status},
    q{git stash list},
    q{git stash show},
) {
    my ($rc, $out) = run_guard($cmd);
    is($rc, 0, "AC-19: '$cmd' is ALLOWED") or diag("hook output: $out");
}

# ── AC-17: real prohibited mutations stay DENIED, each asserted individually ───
for my $cmd (
    q{git stash},
    q{git stash push -u},
    q{foo && git stash},
    q{git checkout main},
    q{git reset --hard},
    q{git clean -fd},
    q{git restore .},
    q{git switch -c x},
) {
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, "AC-17: '$cmd' is DENIED") or diag("hook output: $out");
}

# ── AC-18: a shell/eval in command position forces the RAW scan -- the quoted
#           argument would be re-interpreted as code, so it must stay denied ───
{
    my ($rc, $out) = run_guard(q{bash -c "git stash"});
    is($rc, 2, 'AC-18: bash -c "git stash" is DENIED (shell in command position)') or diag("hook output: $out");
}
{
    my ($rc, $out) = run_guard(q{sh -c 'git reset --hard'});
    is($rc, 2, 'AC-18: sh -c \'git reset --hard\' is DENIED (shell in command position)') or diag("hook output: $out");
}
{
    # unquoted backtick whose body names a prohibited mutation -> the shell would
    # evaluate it as code, so this is denied via the raw-scan fallback.
    my $cmd = 'echo `git stash`';
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'AC-18: unquoted backtick body naming "git stash" is DENIED') or diag("hook output: $out");
}
{
    # unquoted $(...) whose body names a prohibited mutation.
    my $cmd = 'echo $(git reset --hard)';
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'AC-18: unquoted $(...) body naming "git reset --hard" is DENIED') or diag("hook output: $out");
}

# ── AC-20: masking-failure fallbacks degrade to raw matching, never to "allow" ──
{
    # Unbalanced quoting -- the walk never returns to NONE -> raw fallback.
    # The raw string contains a real prohibited mutation, so it must stay denied.
    my $cmd = q{git stash "};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'AC-20: unbalanced-quote command containing a real mutation is DENIED (raw fallback)') or diag("hook output: $out");
}
{
    # >8192-character command -> raw fallback per spec §2.7. Pad with a long,
    # innocuous quoted prefix, end with a real prohibited mutation in command
    # position so the raw scan (not the masked one) is what catches it.
    my $pad = 'echo "' . ('x' x 8200) . '" && git stash';
    ok(length($pad) > 8192, 'AC-20 fixture sanity: the constructed command exceeds 8192 characters');
    my ($rc, $out) = run_guard($pad);
    is($rc, 2, 'AC-20: a >8192-character command containing a real mutation is DENIED (raw fallback)') or diag("hook output: $out");
}

# ── ORACLE-GAP (redteam BLOCKER-1 / reviewer B1, step6): the masking automaton
#    has no comment state and no backslash-escape state, so a BALANCED-looking
#    mask can hide a real, executable, unquoted prohibited mutation. Each row
#    below is a real trigger measured HEAD=DENY(2), working-tree=ALLOW(0) —
#    i.e. this file previously ran green through all of them. Comment lines are
#    ordinary Bash `#` comments (this hook has no comment-awareness at all).
{
    my @rows = (
        [ "apostrophe-comment / stash"   => qq{# don't panic\ngit stash\n# that's it} ],
        [ "apostrophe-comment / checkout"=> qq{# it's a checkpoint\ngit checkout -- .\n# we're done} ],
        [ "apostrophe-comment / reset"   => qq{# we'll reset later\ngit reset --hard HEAD\n# don't repeat} ],
        [ "apostrophe-comment / clean"   => qq{# don't wait\ngit clean -fd\n# that's it} ],
        [ "heredoc-wrapped apostrophes"  =>
            qq{cat <<EOF > n.md\nit's fine\nEOF\ngit stash\ncat <<EOF >> n.md\nthat's all\nEOF} ],
        [ q{backslash-escaped single-quote ($'...') around stash} =>
            q{echo don\'t ; git stash ; echo ok\'} ],
        [ 'backslash-escaped double-quote around clean' =>
            q{: \" ; git clean -fd ; : \"} ],
        [ q{ANSI-C $'...' quoting around stash} =>
            q{echo $'\'' ; git stash ; echo $'\''} ],
    );
    for my $row (@rows) {
        my ($label, $cmd) = @$row;
        my ($rc, $out) = run_guard($cmd);
        is($rc, 2, "ORACLE-GAP(BLOCKER-1): $label -- real mutation must stay DENIED")
            or diag("hook output: $out; command was:\n$cmd");
    }
}

# ── ORACLE-GAP (reviewer B1, step6): a backslash-escaped quote INSIDE a
#    quoted string, then a chained real mutation, then ANOTHER backslash-
#    escaped-quote string. The trailing clause is load-bearing per the
#    reviewer's own note -- without it the parity error self-cancels the
#    OTHER way and the case denies; WITH it, HEAD=DENY(2), working
#    tree=ALLOW(0). Assert the EXACT shape, not a simplification of it.
{
    my $cmd = q{git commit -m "a\"b" && git stash && echo "z\"w"};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'ORACLE-GAP(reviewer B1): escaped-quote / stash / escaped-quote chain must stay DENIED')
        or diag("hook output: $out");
}

# ── Controls (must NOT regress under any fix for the above): ordinary,
#    legitimate multi-line git usage stays ALLOWED. A future fix that buys
#    safety by denying everything fails these. ─────────────────────────────
{
    my ($rc, $out) = run_guard(q{git commit -F -});
    is($rc, 0, 'ORACLE-GAP control: plain git commit -F - stays ALLOWED') or diag("hook output: $out");
}
{
    my $cmd = qq{git add plugins/butler/tests/t/106-guard-git-mutations-quote-mask.t\ngit commit -m "add oracle-gap coverage for BLOCKER-1"};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 0, 'ORACLE-GAP control: legitimate multi-line add+commit stays ALLOWED') or diag("hook output: $out");
}
{
    my $cmd = q{perl bp-blueprint.pl add-decision --file f --id 21 --text "never run git stash on a dirty tree"};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 0, 'ORACLE-GAP control: prose-only mention of a prohibited verb stays ALLOWED') or diag("hook output: $out");
}
{
    my ($rc, $out) = run_guard(q{git stash list});
    is($rc, 0, 'ORACLE-GAP control: explicitly-allowed read-only "git stash list" stays ALLOWED') or diag("hook output: $out");
}

# ── AC-32 (existing, must-not-regress companions from spec observable-behavior 32) ──
{
    my $payload = $J->encode({ tool_name => 'Bash', tool_input => { command => '' } });
    my $pf = "$ROOT/payload." . (++$pn) . ".json";
    open my $w, '>', $pf or die; print $w $payload; close $w;
    local %ENV = (%CLEAN_ENV, GPATH => fwd($GUARD), PFILE => fwd($pf));
    open(my $f, '-|', 'bash', '-c', '"$GPATH" < "$PFILE" 2>&1') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    is($? >> 8, 0, 'companion: empty tool_input.command is ALLOWED (unchanged)');
}

done_testing();
