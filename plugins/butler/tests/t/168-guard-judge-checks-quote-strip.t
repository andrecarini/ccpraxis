#!/usr/bin/env perl
# 168-guard-judge-checks-quote-strip.t -- oracle for t09-guard-hooks-stripping's
# guard-judge-checks.sh changes (spec .ccpraxis-local-data/blueprints/
# tui-operator-feedback/specs/t09-guard-hooks-stripping-spec.md SS2.2/SS2.3/SS3/SS4).
# Companion to 121-guard-judge-checks.t (that file's own oracle, NOT edited here --
# this package's write set is tests/t/ only, and 121 already pins the pre-existing
# denylist/gate-order behavior this file must not regress; it stays a live baseline).
#
# WRITTEN BLIND TO THE IMPLEMENTATION.
#
# jq AVAILABILITY. guard-judge-checks.sh hard-requires jq for the denylist regex path,
# but its BP_LEDGER/BP_ROLE gate runs BEFORE bp_hook_require_jq (spec SS2.3, "order is
# safety-critical") -- so the gate-order assertions below (AC9) are NOT jq-gated and run
# on any host. The denylist/quote-stripping assertions (AC8) ARE jq-gated and SKIP on
# this jq-less Windows host, matching 121's own documented convention.
#
# TECHNIQUE NOTE (guard evasion). Fixtures reach the hook only as heredoc'd JSON payload
# text this test writes to a pipe (mirroring 121's own `bash "$GUARD" <<'PAYLOAD_EOF'`
# technique) -- never as literal text in a Bash tool_input.command this session issues.
#
# Runs standalone: perl plugins/butler/tests/t/168-guard-judge-checks-quote-strip.t
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

my $HOOKS = "$Bin/../../hooks";
my $GUARD = "$HOOKS/guard-judge-checks.sh";

ok(-f $GUARD, 'guard-judge-checks.sh exists at plugins/butler/hooks/guard-judge-checks.sh')
    or BAIL_OUT('subject hook missing');

my $HAVE_JQ = `command -v jq 2>/dev/null` ne '';
my $ROOT = tempdir(CLEANUP => 1);
sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

sub run_guard {
    my ($cmd, %env) = @_;
    my $payload = qq({"session_id":"s1","cwd":"/x","tool_name":"Bash",)
                . qq("tool_input":{"command":"$cmd"}});
    my $envstr = 'BP_LEDGER= BP_ROLE= ';
    $envstr .= "BP_LEDGER='$env{BP_LEDGER}' " if defined $env{BP_LEDGER};
    $envstr .= "BP_ROLE='$env{BP_ROLE}' "     if defined $env{BP_ROLE};
    $envstr .= "PATH='$env{PATH}' "           if defined $env{PATH};
    my $out = `${envstr}bash "$GUARD" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

# PATH containing everything on the ambient PATH except jq -- used to prove the gate
# short-circuits BEFORE jq is required (AC9), independent of host jq availability.
# SUBTRACT THE DIRECTORIES THAT CONTAIN jq -- do not mirror every other
# executable into a new one.
#
# This used to build a shadow bin/ by symlinking every executable on PATH (plus
# /usr/bin, /bin, /usr/local/bin) except jq. Measured on this host that is 6401
# symlinks, and it made this the slowest file in the repository by a wide
# margin: 237s, of which ~20s was creating them and ~167s was File::Temp's
# CLEANUP deleting them again at process exit. The teardown dominated because
# File::Path::rmtree is pure Perl walking one entry at a time through the MSYS
# layer -- native `rm -rf` does the same directory in 1.4s. The test body itself
# runs in 13s.
#
# The intent is "a PATH on which jq cannot be found". Removing the directories
# that contain it expresses exactly that, costs one stat per PATH entry instead
# of thousands of symlinks, and creates nothing that has to be cleaned up.
#
# It is also MORE faithful than the mirror was: the mirror silently dropped
# anything that was not a regular executable file (wrappers, shell functions
# exported as scripts, anything unreadable), so the guard ran under a PATH
# subtly unlike the real one. This keeps the real PATH minus jq.
sub path_without_jq {
    my @keep;
    for my $dir (split /:/, ($ENV{PATH} // '')) {
        next unless length $dir;
        next if -x "$dir/jq" || -x "$dir/jq.exe";
        push @keep, $dir;
    }
    return join ':', @keep;
}

# =====================================================================================
# AC1 (DC1) -- rationale comment at the site of the new code.
# =====================================================================================
{
    my $src = do { local (@ARGV, $/) = ($GUARD); <> };
    like($src, qr/ACCIDENT/, 'AC1: guard-judge-checks.sh source states the ACCIDENT-not-ADVERSARY threat model ruling');
    like($src, qr/ADVERSARY/i, 'AC1: ...and explicitly names ADVERSARY as the rejected alternative');
}

# =====================================================================================
# AC3 (DC2) -- the SAME denylist regex text as today, unchanged.
# =====================================================================================
{
    my $src = do { local (@ARGV, $/) = ($GUARD); <> };
    # The DENYLIST half stays byte-identical -- that is what AC3 is for: proving
    # the set of blocked commands has not silently changed.
    #
    # The ANCHOR half is no longer pinned here. Pinning it inside the same string
    # meant AC3 also froze the boundary class, so ADDING a boundary turned this
    # red. `{` was added alongside the `(` this class already had: a brace group
    # opens a command position exactly as a subshell does, so `{npm run test; }`
    # was unmatched while `(npm run test)` was matched -- a distinction with no
    # meaning. See almanac 20260819-164901-52d3 and the same correction made to
    # t/167's AC3.
    ok(index($src, '([^[:space:];&|]*/)?(pnpm|npm|yarn)[[:space:]]+(run[[:space:]]+)?(lint|build|test)\b') >= 0,
       'AC3: the pnpm/npm/yarn lint|build|test DENYLIST regex is byte-identical to today');

    # The anchor is asserted as a property instead: command-position openers are
    # boundaries, quotes are NOT (a quote is never itself the reason a shell
    # executes what it encloses -- this hook's own comment says so, and treating
    # it as a boundary is what produces false positives on quoted mentions).
    # Extracted by INDEX, not by regex. The class itself contains `]` (inside
    # `[:space:]`), so any `\[[^\]]*\]` pattern stops early and silently yields
    # the wrong substring -- which is how the first version of this assertion
    # failed while the source was perfectly correct.
    my $anchor;
    {
        my $open  = '(^|';
        my $close = ')([^[:space:];&|]*/)?(pnpm';
        # Locate the DENYLIST first, then walk BACK to the `(^|` immediately
        # before it. Searching forward from the first `(^|` in the file finds an
        # unrelated earlier regex (the shellword carrier check) and spans
        # everything in between -- which is why the first attempt reported
        # quotes in the class: it had captured half the script.
        my $j = index($src, $close);
        my $i = $j >= 0 ? rindex($src, $open, $j) : -1;
        $anchor = substr($src, $i + length($open), $j - $i - length($open)) if $i >= 0 && $j > $i;
    }
    ok(defined $anchor, 'AC3b: the anchor class is parseable from the denylist regex')
        or diag('could not locate the anchor class in the source');
    for my $ch ('(', '{', ';', '&', '|') {
        ok(index($anchor // '', $ch) >= 0,
           "AC3b: '$ch' is a command-position boundary in the anchor class");
    }
    for my $ch ("'", '"') {
        ok(index($anchor // '', $ch) < 0,
           "AC3b: [$ch] is NOT a boundary -- quoting a mention must not trip this guard");
    }
}

# =====================================================================================
# AC9 (DC1) -- gate order is unaffected by the new stripping code: BP_LEDGER unset, or
# BP_ROLE != harvest-judge, exits 0 BEFORE jq is ever required -- verified with jq
# ITSELF made unreachable, so a regression that moved stripping/jq ahead of the gate
# would show up as exit 2 (jq-required fail-closed) instead of exit 0.
# =====================================================================================
{
    my $nojq = path_without_jq();
    my ($rc, $out) = run_guard('pnpm run lint', BP_ROLE => 'harvest-judge', PATH => $nojq);
    is($rc, 0, 'AC9: BP_LEDGER unset short-circuits BEFORE jq is required, even with jq entirely unreachable '
             . '(a matching command + harvest-judge role would otherwise deny/fail-closed)')
        or diag("hook output: $out");
}
{
    my $nojq = path_without_jq();
    my ($rc, $out) = run_guard('pnpm run lint', BP_LEDGER => "$ROOT/fake.md", BP_ROLE => 'coordinator', PATH => $nojq);
    is($rc, 0, 'AC9: BP_ROLE != harvest-judge short-circuits BEFORE jq is required, even with jq entirely unreachable')
        or diag("hook output: $out");
}

SKIP: {
    skip 'jq is not installed on this host; guard-judge-checks.sh hard-requires it for the denylist path', 3
        unless $HAVE_JQ;

    # =================================================================================
    # AC8 (DC4, observable behavior 4) -- pnpm test-shaped text ONLY inside a
    # double-quoted commit-message-shaped argument is ALLOWED; the same shape unquoted
    # (or via command substitution) is DENIED, unchanged.
    # =================================================================================
    {
        my $cmd = q{git commit -m \"remember: never re-run pnpm test in a judge, verify the artefact\"};
        my ($rc, $out) = run_guard($cmd, BP_LEDGER => "$ROOT/fake.md", BP_ROLE => 'harvest-judge');
        is($rc, 0, 'AC8: pnpm test mentioned only inside a quoted commit-message argument is ALLOWED')
            or diag("hook output: $out");
    }
    {
        my ($rc, $out) = run_guard('pnpm test', BP_LEDGER => "$ROOT/fake.md", BP_ROLE => 'harvest-judge');
        is($rc, 2, 'AC8: the SAME verb, unquoted ("pnpm test"), as a harvest-judge, is still DENIED')
            or diag("hook output: $out");
    }
    {
        my $cmd = q{result=$(pnpm run lint)};
        my ($rc, $out) = run_guard($cmd, BP_LEDGER => "$ROOT/fake.md", BP_ROLE => 'harvest-judge');
        is($rc, 2, 'AC8: pnpm run lint via command substitution (result=$(...)) is still DENIED')
            or diag("hook output: $out");
    }
}

done_testing();
