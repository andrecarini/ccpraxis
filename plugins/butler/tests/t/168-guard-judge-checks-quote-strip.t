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
sub path_without_jq {
    my $d = "$ROOT/no-jq-bin";
    return fwd($d) if -d $d;
    mkdir $d or die "mkdir $d: $!";
    my %seen;
    for my $dir (split(/:/, $ENV{PATH} // ''), '/usr/bin', '/bin', '/usr/local/bin') {
        next unless length $dir && -d $dir;
        opendir(my $dh, $dir) or next;
        for my $f (readdir $dh) {
            next if $f eq 'jq' || $f =~ /^\./;
            next if $seen{$f}++;
            my $src = "$dir/$f";
            next unless -f $src && -x $src;
            symlink($src, "$d/$f");
        }
        closedir $dh;
    }
    return fwd($d);
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
    ok(index($src, '(^|[;&|[:space:](])([^[:space:];&|]*/)?(pnpm|npm|yarn)[[:space:]]+(run[[:space:]]+)?(lint|build|test)\b') >= 0,
       'AC3: the pnpm/npm/yarn lint|build|test denylist regex is byte-identical to today');
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
