#!/usr/bin/env perl
# p02-preflight-repo-check — tests for the NEW `repo.usable` preflight check.
#
# Spec: .ccpraxis-local-data/blueprints/sandbox-refuse-in-place/specs/p02-preflight-repo-check-spec.md
#
# bp-preflight.pl has NO in-process seam (%CHECK is a file-scoped `my` lexical —
# spec §1). Every AC below runs the script as a SUBPROCESS with a controlled
# BP_PROJECT_ROOT (and, where relevant, BP_ALLOW_NO_GIT) and asserts on exit
# code + the captured report text, following the house idiom in t/02-preflight.t.
#
# Capture is via a real fd-backed temp file, never an in-memory scalar filehandle
# (reopening STDOUT onto \$scalar dies "Bad file descriptor" on Git-for-Windows
# perl — see t/17-drive-next.t's capture_run comment for the same caution).
#
# Isolation requirement (spec §4): other preflight checks (creds, TLS, oauth) can
# legitimately fail or skip on any given machine, so we NEVER assert a whole-report
# exit code of 0. Every exit-2 assertion is paired with a repo.usable-FAIL-row
# assertion FROM THE SAME RUN, so the exit-2 can't be misattributed to some other
# check's unrelated failure.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir tempfile);
use File::Spec;
use Cwd qw(realpath);

my $script   = "$Bin/../../scripts/bp-preflight.pl";
my $manifest = "$Bin/../../docs/assumptions.json";

ok(-f $script,   'bp-preflight.pl exists');
ok(-f $manifest, 'assumptions.json exists');

# ── helpers ──────────────────────────────────────────────────────────────────

# run_preflight(env => {...}, args => [...]) -> ($rc, $stdout_and_stderr)
# Spawns bp-preflight.pl as a real subprocess with the given env overrides
# layered onto a snapshot of the current environment (localized — restored on
# return), redirecting its combined stdout+stderr to a temp file.
sub run_preflight {
    my (%args) = @_;
    my $envp  = $args{env}  // {};
    my @extra = @{ $args{args} // [] };

    my ($ofh, $opath) = tempfile('t27-preflightXXXXXX', TMPDIR => 1);
    close $ofh;

    local %ENV = %ENV;
    for my $k (keys %$envp) {
        if (defined $envp->{$k}) { $ENV{$k} = $envp->{$k} }
        else                     { delete $ENV{$k} }
    }

    my $cmd = join ' ', qq{"$^X"}, qq{"$script"}, @extra, '>', qq{"$opath"}, '2>&1';
    system($cmd);
    my $rc = $? >> 8;

    my $out = do {
        open my $r, '<:raw', $opath or die "cannot read $opath: $!";
        local $/;
        my $x = <$r>;
        close $r;
        defined $x ? $x : '';
    };
    unlink $opath;
    return ($rc, $out);
}

# find_row($report_text, $id) -> ($status, $detail) | (undef, undef)
# Parses a report row printed by bp-preflight.pl's `printf "[%s] %-20s %s\n"`
# (glyphs '  ok  ' / ' FAIL ' / ' skip ' — script :210-215). Returns undef,undef
# if the id never appears as a row at all (the pre-implementation state: the
# manifest has no repo.usable entry, so the loop never emits the row).
sub find_row {
    my ($out, $id) = @_;
    if ($out =~ /^\[(  ok  | FAIL | skip )\] \Q$id\E\s+(.*)$/m) {
        my ($glyph, $detail) = ($1, $2);
        my %map = ('  ok  ' => 'ok', ' FAIL ' => 'fail', ' skip ' => 'skip');
        return ($map{$glyph}, $detail);
    }
    return (undef, undef);
}

# ── fixtures ─────────────────────────────────────────────────────────────────

# AC-1 fixture: the ccpraxis checkout itself is a real, resolvable git repo.
# t/27-preflight-repo-check.t lives at plugins/butler/tests/t/, so four levels
# up is the checkout root (spec §4 AC-1: "$Bin/../../../..").
my $real_repo_root = realpath("$Bin/../../../..");

# AC-2 / AC-4 / AC-7 fixture: a plain directory with no .git at all.
my $non_repo_dir = realpath(tempdir(CLEANUP => 1));

# AC-3 fixture: the B2 shape — a `.git` FILE (not a directory) whose `gitdir:`
# target does not exist. `rev-parse --git-dir` may parse this pointer while
# every real git operation (a trivial read) fails against it.
my $b2_dir = realpath(tempdir(CLEANUP => 1));
my $missing_gitdir_target = File::Spec->catdir($b2_dir, 'nonexistent-gitdir-target');
{
    open my $gfh, '>', File::Spec->catfile($b2_dir, '.git')
        or die "cannot write B2 fixture .git file: $!";
    print $gfh "gitdir: $missing_gitdir_target\n";
    close $gfh;
}

# ── AC-1: a resolvable git repo passes ──────────────────────────────────────
# package done-criterion 1.
{
    my ($rc, $out) = run_preflight(env => { BP_PROJECT_ROOT => $real_repo_root });
    my ($status, $detail) = find_row($out, 'repo.usable');
    ok(defined $status, 'AC-1: repo.usable appears as a row for a real repo')
        or diag($out);
    is($status, 'ok', 'AC-1: repo.usable is ok for a resolvable git repo')
        or diag($out);
    like($detail // '', qr/\Q$real_repo_root\E/,
        'AC-1: detail contains the resolved root')
        or diag($detail // '(no detail — row absent)');
}

# ── AC-2: a non-repo directory fails blocking ───────────────────────────────
# package done-criterion 2.
{
    my ($rc, $out) = run_preflight(env => { BP_PROJECT_ROOT => $non_repo_dir });
    my ($status, $detail) = find_row($out, 'repo.usable');
    is($rc, 2, 'AC-2: non-repo project root exits 2')
        or diag($out);
    is($status, 'fail', 'AC-2: repo.usable FAIL row is present for a non-repo dir')
        or diag($out);
    like($detail // '', qr/\Q$non_repo_dir\E/,
        'AC-2: detail names the project path')
        or diag($detail // '(no detail — row absent)');
}

# ── AC-3: the B2 .git-file-pointing-nowhere shape fails blocking ───────────
# package done-criterion 3. This is the shape that slipped through the live
# incident: `rev-parse --git-dir` may parse the pointer while a trivial read
# (rev-parse HEAD / status --porcelain) fails against the missing target.
{
    my ($rc, $out) = run_preflight(env => { BP_PROJECT_ROOT => $b2_dir });
    my ($status, $detail) = find_row($out, 'repo.usable');
    is($rc, 2, 'AC-3: B2 .git-pointer-to-nowhere shape exits 2')
        or diag($out);
    is($status, 'fail', 'AC-3: repo.usable FAIL row is present for the B2 shape')
        or diag($out);
    like($detail // '', qr/\Q$b2_dir\E/,
        'AC-3: detail names the project path')
        or diag($detail // '(no detail — row absent)');
}

# ── AC-4: BP_ALLOW_NO_GIT=1 downgrades AC-2's fixture to non-blocking ──────
# package done-criterion 4 (downgrade half).
{
    my ($rc, $out) = run_preflight(env => {
        BP_PROJECT_ROOT  => $non_repo_dir,
        BP_ALLOW_NO_GIT  => '1',
    });
    my ($status, $detail) = find_row($out, 'repo.usable');
    ok(defined $status, 'AC-4: repo.usable row present with BP_ALLOW_NO_GIT=1')
        or diag($out);
    is($status, 'ok', 'AC-4: repo.usable is ok when BP_ALLOW_NO_GIT=1 overrides')
        or diag($out);
    like($detail // '', qr/WARNING/, 'AC-4: detail contains WARNING')
        or diag($detail // '(no detail — row absent)');
    like($detail // '', qr/BP_ALLOW_NO_GIT/, 'AC-4: detail names BP_ALLOW_NO_GIT')
        or diag($detail // '(no detail — row absent)');
    like($detail // '', qr/\Q$non_repo_dir\E/, 'AC-4: detail contains the resolved root')
        or diag($detail // '(no detail — row absent)');
    unlike($out, qr/^\s*-\s*\[repo\.usable\]/m,
        'AC-4: repo.usable is not listed in the failure summary (not the cause of any exit 2)')
        or diag($out);
}

# ── AC-5: repo.usable appears as a row in a plain run ───────────────────────
# package done-criterion 5 (wiring half): proves the manifest entry is wired
# into the manifest-driven loop, not just present as an orphan %CHECK sub
# (spec §1: an entry in %CHECK with no matching manifest id never runs and
# never appears in the report).
{
    my ($rc, $out) = run_preflight();
    my ($status, $detail) = find_row($out, 'repo.usable');
    ok(defined $status, 'AC-5: repo.usable is present as a row in a plain run')
        or diag($out);
}

# ── AC-6: the manifest entry exists with all seven fields ──────────────────
# package done-criterion 5 (manifest half).
{
    my $m = do {
        open my $fh, '<:raw', $manifest or die "cannot read $manifest: $!";
        local $/;
        JSON::PP->new->decode(<$fh>);
    };
    my ($entry) = grep { ($_->{id} // '') eq 'repo.usable' } @{ $m->{assumptions} // [] };
    ok(defined $entry, 'AC-6: assumptions.json has a repo.usable entry')
        or diag('no assumption with id "repo.usable" found');

    for my $field (qw(id what expected_contract check implement_hint surface)) {
        ok(defined $entry->{$field} && length($entry->{$field}),
            "AC-6: repo.usable manifest field '$field' is present and non-empty");
    }
    ok(ref($entry->{supported_envs}) eq 'ARRAY',
        'AC-6: repo.usable manifest field \'supported_envs\' is an array');
    is_deeply(
        [ sort @{ $entry->{supported_envs} // [] } ],
        [ 'sandbox-linux', 'win32' ],
        'AC-6: repo.usable supported_envs covers both win32 and sandbox-linux'
    );
}

# ── AC-7: BP_ALLOW_NO_GIT unset / empty / "0" must NOT override ────────────
# package done-criterion 4 (non-truthy guard half) — guards against a
# truthiness bug where any defined value (including '0' or '') would wrongly
# be treated as an override.
for my $case (
    { label => 'unset',  value => undef },
    { label => 'empty',  value => ''    },
    { label => '"0"',    value => '0'   },
) {
    my ($rc, $out) = run_preflight(env => {
        BP_PROJECT_ROOT => $non_repo_dir,
        BP_ALLOW_NO_GIT => $case->{value},
    });
    my ($status, $detail) = find_row($out, 'repo.usable');
    is($rc, 2, "AC-7: BP_ALLOW_NO_GIT=$case->{label} does not override — exits 2")
        or diag($out);
    is($status, 'fail', "AC-7: BP_ALLOW_NO_GIT=$case->{label} does not override — repo.usable still FAILs")
        or diag($out);
}

done_testing();
