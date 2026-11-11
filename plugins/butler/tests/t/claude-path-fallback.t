#!/usr/bin/env perl
# platform: any
# bug 6568: bp_find_claude_in / bp_ensure_claude_on_path (bp-lib.sh) -- the
# sandbox-only PATH fallback that lets butler's own entry points
# (bp-orchestrate.sh, bp-hooks-selftest.sh) find a claude install at a known
# sandbox location even when the invoking shell never sourced the profile
# that normally puts it on PATH (e.g. a plain `podman exec <ctr> bash -lc
# '...'`, which is exactly what the bug report's restart used). This locks
# only the PATH-resolution seam -- a fake `claude` executable stands in for
# the real one, no sandbox/orchestrator/claude session involved.
#
# Non-vacuity: run this file against the pre-fix bp-lib.sh (neither
# bp_find_claude_in nor bp_ensure_claude_on_path exist yet) and every `call`
# below returns empty stdout with a non-zero exit (bash: command not found),
# so every is()/ok() against a real pass value fails. This is not a
# hypothetical -- `git stash` the bp-lib.sh fix and re-run to see it fail.
use strict;
use warnings;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use Test::More;

(my $LIB = "$Bin/../../scripts/bp-lib.sh") =~ s{\\}{/}g;
-f $LIB or BAIL_OUT("missing $LIB");

my $tmp = tempdir(CLEANUP => 1);
my $bindir_real = "$tmp/real/.local/bin";
my $bindir_other = "$tmp/other/.local/bin";
for my $d ($bindir_real, $bindir_other) {
    mkdir_p($d);
}
sub mkdir_p {
    my ($d) = @_;
    my @parts = split m{/}, $d;
    my $cur = '';
    for my $p (@parts) {
        next if $p eq '';
        $cur .= "/$p";
        mkdir $cur unless -d $cur;
    }
}

open(my $fh, '>', "$bindir_real/claude") or die "write fake claude: $!";
print $fh "#!/usr/bin/env bash\necho fake-claude-$$\n";
close $fh;
chmod 0755, "$bindir_real/claude";
my $MISSING_DIR = "$tmp/nowhere/.local/bin"; # deliberately never created

# run_bash ENV_HASHREF CODE -> (stdout, exit_code)
# ENV_HASHREF entries with value undef mean "ensure unset". Everything else
# in the parent %ENV is inherited unless explicitly unset here, matching how
# a real sandbox shell would see it.
sub run_bash {
    my ($env, $code) = @_;
    local %ENV = %ENV;
    delete $ENV{IS_SANDBOX};
    delete $ENV{BP_ALLOW_HOST};
    delete $ENV{BP_CLAUDE_PATH_CANDIDATES};
    for my $k (keys %$env) {
        if (defined $env->{$k}) { $ENV{$k} = $env->{$k}; }
        else { delete $ENV{$k}; }
    }
    $ENV{LIB} = $LIB;
    my $out = `bash -c 'source "\$LIB" >/dev/null 2>&1; $code' 2>&1`;
    my $exit = $? >> 8;
    $out =~ s/\s+\z//;
    return ($out, $exit);
}

# --- bp_find_claude_in: pure search, never touches PATH -----------------
my ($out, $exit) = run_bash({}, qq{bp_find_claude_in "$bindir_real:$bindir_other"});
is($out, $bindir_real, 'bp_find_claude_in returns the first candidate dir that has an executable claude');
is($exit, 0, 'bp_find_claude_in exits 0 on a hit');

($out, $exit) = run_bash({}, qq{bp_find_claude_in "$MISSING_DIR:$bindir_other"});
is($out, '', 'bp_find_claude_in prints nothing when no candidate has claude');
isnt($exit, 0, 'bp_find_claude_in exits non-zero when no candidate has claude');

# --- bp_ensure_claude_on_path: sandbox-gated, PATH-mutating wrapper ------

# 1) Sandbox + claude missing from PATH + present in a candidate dir -> PATH
#    gets the candidate dir prepended, and `command -v claude` then resolves
#    to the fake binary. This is the exact bug-6568 scenario: a podman exec
#    shell with a stripped PATH.
($out, $exit) = run_bash(
    { IS_SANDBOX => '1', PATH => '/usr/bin:/bin', BP_CLAUDE_PATH_CANDIDATES => "$MISSING_DIR:$bindir_real" },
    'bp_ensure_claude_on_path; echo "RC=$?"; command -v claude'
);
is($exit, 0, 'bp_ensure_claude_on_path: bash call itself succeeds');
like($out, qr/RC=0/, 'bp_ensure_claude_on_path returns 0 once it finds claude in a candidate dir');
like($out, qr{\Q$bindir_real\E/claude}, 'after the call, command -v claude resolves to the fake binary via the prepended dir');

# 2) Sandbox + claude already on PATH -> no-op, still succeeds, PATH
#    untouched (bp_ensure_claude_on_path must not blow away a working PATH).
($out, $exit) = run_bash(
    { IS_SANDBOX => '1', PATH => "$bindir_real:/usr/bin:/bin", BP_CLAUDE_PATH_CANDIDATES => $MISSING_DIR },
    'bp_ensure_claude_on_path; echo "RC=$?"; echo "PATH=$PATH"'
);
like($out, qr/RC=0/, 'bp_ensure_claude_on_path no-ops (returns 0) when claude is already resolvable');
like($out, qr{^PATH=\Q$bindir_real\E:/usr/bin:/bin}m, 'PATH is left exactly as-is when claude was already found');

# 3) Sandbox + claude nowhere (not on PATH, not in any candidate) -> fails,
#    names the paths it searched, PATH left untouched.
($out, $exit) = run_bash(
    { IS_SANDBOX => '1', PATH => '/usr/bin:/bin', BP_CLAUDE_PATH_CANDIDATES => "$MISSING_DIR:$tmp/also-nowhere" },
    'bp_ensure_claude_on_path; echo "RC=$?"'
);
like($out, qr/RC=1/, 'bp_ensure_claude_on_path returns 1 when claude is nowhere to be found');
like($out, qr/\Q$MISSING_DIR\E/, 'the failure names the first searched directory');
like($out, qr{\Q$tmp\E/also-nowhere}, 'the failure names the second searched directory too');

# 4) Host (no IS_SANDBOX, no BP_ALLOW_HOST): must NOT touch PATH even though
#    a candidate has a hit -- the fix is sandbox-only, host behaviour is
#    unchanged (constraint from the bug report: never change host behaviour).
($out, $exit) = run_bash(
    { PATH => '/usr/bin:/bin', BP_CLAUDE_PATH_CANDIDATES => $bindir_real },
    'bp_ensure_claude_on_path; echo "RC=$?"; echo "PATH=$PATH"'
);
like($out, qr/RC=1/, 'on the host (no IS_SANDBOX/BP_ALLOW_HOST), bp_ensure_claude_on_path refuses rather than searching');
like($out, qr{^PATH=/usr/bin:/bin$}m, 'host PATH is left completely untouched');

# 5) BP_ALLOW_HOST=1 opts a host shell into the same sandbox behaviour,
#    mirroring bp_require_sandbox's own override.
($out, $exit) = run_bash(
    { BP_ALLOW_HOST => '1', PATH => '/usr/bin:/bin', BP_CLAUDE_PATH_CANDIDATES => $bindir_real },
    'bp_ensure_claude_on_path; echo "RC=$?"'
);
like($out, qr/RC=0/, 'BP_ALLOW_HOST=1 opts into the same PATH search as the sandbox');

done_testing();
