#!/usr/bin/env perl
# 20-deps-check.t — BpDepsCheck::run classifies dependency/runtime-version governance
# violations (EOL runtimes, undeclared toolchains, missing/uncommitted lockfiles, freshly
# published pins) into BLOCK/WARN findings per spec 05-dependency-version-governance §4
# (AC1-AC17); every impure dependency (now/http/git) is injected so no test touches the
# real clock, the real network, or /project's own dangling-worktree .git.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;

require "$Bin/../../scripts/bp-deps-check.pl";

plan tests => 90;

# ---------------------------------------------------------------------------
# Reference clock (spec §4): all fixtures use --now=2026-07-01T00:00:00Z unless
# an AC explicitly overrides it (AC2 uses 2026-01-01T00:00:00Z).
# ---------------------------------------------------------------------------
use constant NOW     => 1782864000;  # 2026-07-01T00:00:00Z
use constant NOW_JAN => 1767225600;  # 2026-01-01T00:00:00Z

# ---------------------------------------------------------------------------
# Small local scaffolding helpers (spec is silent on fixture mechanics; ours).
# ---------------------------------------------------------------------------

sub write_file {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "cannot write $path: $!";
    print {$fh} $content;
    close $fh;
    return $path;
}

sub write_json {
    my ($path, $data) = @_;
    return write_file($path, JSON::PP->new->canonical->encode($data));
}

# make_backpack($path, @items) -- writes a v2-schema backpack.json ({items:[...]})
sub make_backpack {
    my ($path, @items) = @_;
    write_json($path, { items => \@items });
    return $path;
}

sub init_git {
    my ($dir) = @_;
    system('git', '-C', $dir, 'init', '-q') == 0
        or die "git init failed in $dir";
}

sub git_commit_all {
    my ($dir, $msg) = @_;
    $msg //= 'fixture commit';
    system('git', '-C', $dir, 'add', '-A') == 0
        or die "git add failed in $dir";
    system('git', '-C', $dir, '-c', 'user.email=t@t', '-c', 'user.name=t',
           'commit', '-q', '-m', $msg) == 0
        or die "git commit failed in $dir";
}

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "cannot read $path: $!";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

# find_kind(\@findings, $kind) -> list of findings whose kind matches
sub find_kind {
    my ($arr, $kind) = @_;
    return grep { ref($_) eq 'HASH' && (($_->{kind} // '') eq $kind) } @$arr;
}

# safe_arr($report, $key) -> arrayref, defaulting to [] so a malformed report
# never crashes the *test* (the checker's own malformed-output is a bug the
# assertions below will already have caught; this just keeps the harness alive).
sub safe_arr {
    my ($report, $key) = @_;
    return (ref($report) eq 'HASH' && ref($report->{$key}) eq 'ARRAY')
        ? $report->{$key} : [];
}

# http() coderef that dies loudly if invoked -- for fixtures that must never
# touch a registry. A degradation-aware implementation will catch the die and
# turn it into a registry_unavailable WARN, which the surrounding assertions
# (blocks/warns must be empty) will then catch anyway.
sub http_forbidden {
    return sub {
        my @args = @_;
        die "TEST FIXTURE ERROR: http() invoked unexpectedly with (@args) -- "
          . "this fixture must never touch the network";
    };
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

# AC1 / AC2 / AC14 / AC15(block case): EOL node (.nvmrc=20), declared via
# backpack under curl-script/node22 (DAME-shaped, but matched by name), with a
# committed package-lock.json in a real temp git repo.
sub build_eol_block_fixture {
    my $dir    = tempdir(CLEANUP => 1);
    my $bp_dir = tempdir(CLEANUP => 1);
    write_file("$dir/.nvmrc", "20\n");
    write_json("$dir/package.json", { name => 'fixture', version => '1.0.0' });
    write_json("$dir/package-lock.json", { lockfileVersion => 3 });
    init_git($dir);
    git_commit_all($dir, 'initial commit');
    my $backpack = "$bp_dir/backpack.json";
    make_backpack($backpack, { category => 'curl-script', name => 'node22' });
    return ($dir, $backpack);
}

# AC3: current node (24), NOT declared (empty backpack), committed lockfile.
sub build_undeclared_runtime_fixture {
    my $dir    = tempdir(CLEANUP => 1);
    my $bp_dir = tempdir(CLEANUP => 1);
    write_file("$dir/.nvmrc", "24\n");
    write_json("$dir/package.json", { name => 'fixture', version => '1.0.0' });
    write_json("$dir/package-lock.json", { lockfileVersion => 3 });
    init_git($dir);
    git_commit_all($dir, 'initial commit');
    my $backpack = "$bp_dir/backpack.json";
    make_backpack($backpack);   # items: []
    return ($dir, $backpack);
}

# AC4 (DAME regression): current node (22), backpack item filed under category
# "curl-script" with name "node22" -- must be matched by NAME, not category.
# No manifest at all, so no lockfile requirement is even in play.
sub build_dame_regression_fixture {
    my $dir    = tempdir(CLEANUP => 1);
    my $bp_dir = tempdir(CLEANUP => 1);
    write_file("$dir/.nvmrc", "22\n");
    my $backpack = "$bp_dir/backpack.json";
    make_backpack($backpack, { category => 'curl-script', name => 'node22' });
    return ($dir, $backpack);
}

# AC5 / AC6 / AC11 / AC12 / AC13 / AC15(clean case): current node (24),
# declared, committed lockfile, one exactly-pinned npm dependency "foo" whose
# publish date (and version string) are parametrized. Returns the http stub
# that answers the npm registry request for "foo" so tests can override the
# freshness result deterministically.
sub build_pinned_dep_fixture {
    my (%args) = @_;
    my $pkg_version  = $args{pkg_version}  // '1.2.3';
    my $publish_date = $args{publish_date} // '2026-06-01T00:00:00.000Z';
    my $dir    = tempdir(CLEANUP => 1);
    my $bp_dir = tempdir(CLEANUP => 1);
    write_file("$dir/.nvmrc", "24\n");
    write_json("$dir/package.json", {
        name => 'fixture', version => '1.0.0',
        dependencies => { foo => $pkg_version },
    });
    write_json("$dir/package-lock.json", { lockfileVersion => 3 });
    init_git($dir);
    git_commit_all($dir, 'initial commit');
    my $backpack = "$bp_dir/backpack.json";
    make_backpack($backpack, { category => 'other', name => 'node' });
    my $http = sub {
        my ($method, $url, $headers) = @_;
        if ($url =~ m{registry\.npmjs\.org/foo}) {
            return { status => 200, content => JSON::PP->new->encode({
                'dist-tags' => { latest => $pkg_version },
                time        => { $pkg_version => $publish_date },
            }) };
        }
        die "TEST FIXTURE ERROR: unexpected http call in pinned-dep fixture: $method $url";
    };
    return ($dir, $backpack, $http);
}

# AC8: manifest present, no accepted lockfile at all. Declared, current node.
sub build_lockfile_missing_fixture {
    my $dir    = tempdir(CLEANUP => 1);
    my $bp_dir = tempdir(CLEANUP => 1);
    write_file("$dir/.nvmrc", "24\n");
    write_json("$dir/package.json", { name => 'fixture', version => '1.0.0' });
    my $backpack = "$bp_dir/backpack.json";
    make_backpack($backpack, { category => 'other', name => 'node' });
    return ($dir, $backpack);
}

# AC9: real temp git repo, package.json + package-lock.json present but
# NEVER added/committed (untracked). Declared node so only the lockfile
# check is exercised; no .nvmrc, so runtime version is unknown (no EOL noise).
sub build_lockfile_uncommitted_fixture {
    my $dir    = tempdir(CLEANUP => 1);
    my $bp_dir = tempdir(CLEANUP => 1);
    init_git($dir);
    write_json("$dir/package.json", { name => 'fixture', version => '1.0.0' });
    write_json("$dir/package-lock.json", { lockfileVersion => 3 });
    my $backpack = "$bp_dir/backpack.json";
    make_backpack($backpack, { category => 'other', name => 'node' });
    return ($dir, $backpack);
}

# AC10: identical files to AC9's fixture, but NO git repo at all.
sub build_no_git_lockfile_fixture {
    my $dir    = tempdir(CLEANUP => 1);
    my $bp_dir = tempdir(CLEANUP => 1);
    write_json("$dir/package.json", { name => 'fixture', version => '1.0.0' });
    write_json("$dir/package-lock.json", { lockfileVersion => 3 });
    my $backpack = "$bp_dir/backpack.json";
    make_backpack($backpack, { category => 'other', name => 'node' });
    return ($dir, $backpack);
}

# ---------------------------------------------------------------------------
# AC1 (done-crit a): EOL runtime -> BLOCK
# ---------------------------------------------------------------------------
{
    my ($dir, $backpack) = build_eol_block_fixture();
    my ($report, $rc) = BpDepsCheck::run({
        project => $dir, backpack => $backpack, out => undef,
        now => NOW, http => http_forbidden(),
    });
    my $blocks = safe_arr($report, 'blocks');
    my $warns  = safe_arr($report, 'warns');
    is(scalar(find_kind($blocks, 'eol_runtime')), 1,
       'AC1: exactly one eol_runtime BLOCK for .nvmrc=20 against the 2026-07-01 reference date');
    my ($f) = find_kind($blocks, 'eol_runtime');
    $f ||= {};
    is($f->{severity}, 'block', 'AC1: eol_runtime finding severity is block');
    is($f->{subject}, 'node@20', 'AC1: eol_runtime finding subject is node@20');
    is($f->{remedy}{action}, 'bump_runtime', 'AC1: remedy action is bump_runtime');
    is($f->{remedy}{to}, '24', 'AC1: remedy targets node 24 (the current LTS successor)');
    ok(!$f->{needs_justification}, 'AC1: BLOCK finding has needs_justification false');
    is(scalar(@$blocks), 1, 'AC1: no other BLOCK findings in an otherwise-declared, committed fixture');
    is(scalar(@$warns), 0, 'AC1: no WARN findings either');
    is($rc, 2, 'AC1: exit code 2 on a BLOCK finding');
}

# ---------------------------------------------------------------------------
# AC2: EOL detection is date-driven (embedded table stores dates, not a flag)
# ---------------------------------------------------------------------------
{
    my ($dir, $backpack) = build_eol_block_fixture();
    my ($report, $rc) = BpDepsCheck::run({
        project => $dir, backpack => $backpack, out => undef,
        now => NOW_JAN, http => http_forbidden(),
    });
    my $blocks = safe_arr($report, 'blocks');
    my $warns  = safe_arr($report, 'warns');
    is(scalar(find_kind($blocks, 'eol_runtime')) + scalar(find_kind($warns, 'eol_runtime')), 0,
       'AC2: no eol_runtime finding as of 2026-01-01 (node 20 EOLs 2026-04-30) -- proves the table stores dates, not a boolean');
    is($rc, 0, 'AC2: exit 0 -- nothing else in the fixture blocks either');
}

# ---------------------------------------------------------------------------
# AC3 (b): runtime present but undeclared -> BLOCK
# ---------------------------------------------------------------------------
{
    my ($dir, $backpack) = build_undeclared_runtime_fixture();
    my ($report, $rc) = BpDepsCheck::run({
        project => $dir, backpack => $backpack, out => undef,
        now => NOW, http => http_forbidden(),
    });
    my $blocks = safe_arr($report, 'blocks');
    is(scalar(find_kind($blocks, 'undeclared_runtime')), 1,
       'AC3: exactly one undeclared_runtime BLOCK for node 24 with an empty backpack');
    my ($f) = find_kind($blocks, 'undeclared_runtime');
    $f ||= {};
    is($f->{severity}, 'block', 'AC3: undeclared_runtime finding severity is block');
    is($f->{subject}, 'node', 'AC3: undeclared_runtime finding subject is node');
    is($f->{remedy}{action}, 'declare_backpack', 'AC3: remedy action is declare_backpack');
    ok(!$f->{needs_justification}, 'AC3: BLOCK finding has needs_justification false');
    is(scalar(@$blocks), 1, 'AC3: no other BLOCK findings (node 24 is current, lockfile committed)');
    is($rc, 2, 'AC3: exit code 2 on a BLOCK finding');
}

# ---------------------------------------------------------------------------
# AC4 (b, DAME regression): declaration matched by NAME, never by category
# ---------------------------------------------------------------------------
{
    my ($dir, $backpack) = build_dame_regression_fixture();
    my ($report, $rc) = BpDepsCheck::run({
        project => $dir, backpack => $backpack, out => undef,
        now => NOW, http => http_forbidden(),
    });
    my $blocks = safe_arr($report, 'blocks');
    is(scalar(find_kind($blocks, 'undeclared_runtime')), 0,
       'AC4: name-matched backpack item (curl-script/node22) counts as declaring node -- no undeclared_runtime BLOCK');
    is(scalar(@$blocks), 0,
       'AC4: no BLOCK findings at all (node 22 is current and declared by name, exact DAME-failure guard)');
    is($rc, 0, 'AC4: exit 0');
}

# ---------------------------------------------------------------------------
# AC5 (c): version published <7 days before ref date -> WARN + needs_justification
# ---------------------------------------------------------------------------
{
    my ($dir, $backpack, $http) = build_pinned_dep_fixture(
        pkg_version => '1.2.3', publish_date => '2026-06-28T00:00:00.123Z', # 3 days old
    );
    my ($report, $rc) = BpDepsCheck::run({
        project => $dir, backpack => $backpack, out => undef,
        now => NOW, http => $http,
    });
    my $blocks = safe_arr($report, 'blocks');
    my $warns  = safe_arr($report, 'warns');
    is(scalar(find_kind($warns, 'fresh_version')), 1,
       'AC5: exactly one fresh_version WARN for foo@1.2.3 published 3 days before the reference date');
    my ($f) = find_kind($warns, 'fresh_version');
    $f ||= {};
    is($f->{severity}, 'warn', 'AC5: fresh_version finding severity is warn');
    ok($f->{needs_justification}, 'AC5: fresh_version WARN has needs_justification true');
    is($f->{remedy}{action}, 'justify', 'AC5: fresh_version remedy action is justify');
    like($f->{subject}, qr{foo}, 'AC5: fresh_version finding subject references the flagged package (foo)');
    is(scalar(find_kind($blocks, 'fresh_version')), 0, 'AC5: fresh_version never appears as a BLOCK');
    is(scalar(@$blocks), 0, 'AC5: no BLOCK findings from a <7-day-old pinned dependency');
    is($rc, 0, 'AC5: exit 0 (WARN only, no BLOCK)');
}

# ---------------------------------------------------------------------------
# AC6 (c, boundary): >=7 days old is clean
# ---------------------------------------------------------------------------
{
    my ($dir, $backpack, $http) = build_pinned_dep_fixture(
        pkg_version => '1.2.3', publish_date => '2026-06-01T00:00:00.000Z', # 30 days old
    );
    my ($report, $rc) = BpDepsCheck::run({
        project => $dir, backpack => $backpack, out => undef,
        now => NOW, http => $http,
    });
    my $warns = safe_arr($report, 'warns');
    is(scalar(find_kind($warns, 'fresh_version')), 0,
       'AC6: no fresh_version WARN when the pinned dependency is 30 days old (>= 7-day threshold)');
    is($rc, 0, 'AC6: exit 0');
}

# ---------------------------------------------------------------------------
# AC7 (c, parser): fractional seconds of differing precision are parsed
# ---------------------------------------------------------------------------
{
    is(BpDepsCheck::parse_iso8601('2018-04-09T01:10:45.796Z'), 1523236245,
       'AC7: parse_iso8601 handles milliseconds (.796) -> correct epoch');
    is(BpDepsCheck::parse_iso8601('2026-05-14T19:25:26.443000Z'), 1778786726,
       'AC7: parse_iso8601 handles microseconds (.443000) -> correct epoch');
    is(BpDepsCheck::parse_iso8601('2026-07-01T00:00:00Z'), 1782864000,
       'AC7: parse_iso8601 handles no fractional seconds at all -> correct epoch');
}

# ---------------------------------------------------------------------------
# AC8 (d): manifest present, no accepted lockfile -> BLOCK
# ---------------------------------------------------------------------------
{
    my ($dir, $backpack) = build_lockfile_missing_fixture();
    my ($report, $rc) = BpDepsCheck::run({
        project => $dir, backpack => $backpack, out => undef,
        now => NOW, http => http_forbidden(),
    });
    my $blocks = safe_arr($report, 'blocks');
    is(scalar(find_kind($blocks, 'lockfile_missing')), 1,
       'AC8: exactly one lockfile_missing BLOCK when package.json exists with no accepted lockfile');
    my ($f) = find_kind($blocks, 'lockfile_missing');
    $f ||= {};
    is($f->{severity}, 'block', 'AC8: lockfile_missing finding severity is block');
    is($f->{remedy}{action}, 'create_lockfile', 'AC8: remedy action is create_lockfile');
    is(scalar(@$blocks), 1, 'AC8: no other BLOCK findings (node declared and current)');
    is($rc, 2, 'AC8: exit code 2');
}

# ---------------------------------------------------------------------------
# AC9 (d): lockfile present but untracked in git -> BLOCK
# ---------------------------------------------------------------------------
{
    my ($dir, $backpack) = build_lockfile_uncommitted_fixture();
    my ($report, $rc) = BpDepsCheck::run({
        project => $dir, backpack => $backpack, out => undef,
        now => NOW, http => http_forbidden(),
    });
    my $blocks = safe_arr($report, 'blocks');
    is(scalar(find_kind($blocks, 'lockfile_uncommitted')), 1,
       'AC9: exactly one lockfile_uncommitted BLOCK when package-lock.json is untracked');
    my ($f) = find_kind($blocks, 'lockfile_uncommitted');
    $f ||= {};
    is($f->{severity}, 'block', 'AC9: lockfile_uncommitted finding severity is block');
    is($f->{remedy}{action}, 'commit_lockfile', 'AC9: remedy action is commit_lockfile');
    is(scalar(@$blocks), 1,
       'AC9: no other BLOCK findings (node declared, version unknown so no EOL block)');
    is($rc, 2, 'AC9: exit code 2');
}

# ---------------------------------------------------------------------------
# AC10 (d, degradation): non-git project -> WARN, never BLOCK
# ---------------------------------------------------------------------------
{
    my ($dir, $backpack) = build_no_git_lockfile_fixture();
    my ($report, $rc) = BpDepsCheck::run({
        project => $dir, backpack => $backpack, out => undef,
        now => NOW, http => http_forbidden(),
    });
    my $blocks = safe_arr($report, 'blocks');
    my $warns  = safe_arr($report, 'warns');
    is(scalar(find_kind($warns, 'git_unavailable')), 1,
       'AC10: exactly one git_unavailable WARN when the project is not a git repo at all');
    my ($f) = find_kind($warns, 'git_unavailable');
    $f ||= {};
    is($f->{severity}, 'warn', 'AC10: git_unavailable finding severity is warn');
    ok($f->{needs_justification}, 'AC10: git_unavailable WARN has needs_justification true');
    is(scalar(find_kind($blocks, 'lockfile_uncommitted')), 0,
       'AC10: no lockfile_uncommitted BLOCK is manufactured from the checker\'s own blindness');
    is(scalar(@$blocks), 0, 'AC10: no BLOCK findings at all when git is unavailable');
    is($rc, 0, 'AC10: exit 0 (WARN only)');
}

# ---------------------------------------------------------------------------
# AC11 (e): fully compliant project -> clean report, exit 0
# ---------------------------------------------------------------------------
{
    my ($dir, $backpack, $http) = build_pinned_dep_fixture(
        pkg_version => '2.0.0', publish_date => '2026-06-01T00:00:00.000Z', # 30 days old
    );
    my ($report, $rc) = BpDepsCheck::run({
        project => $dir, backpack => $backpack, out => undef,
        now => NOW, http => $http,
    });
    is(scalar(@{ safe_arr($report, 'blocks') }), 0, 'AC11: blocks empty for a fully compliant project');
    is(scalar(@{ safe_arr($report, 'warns') }), 0, 'AC11: warns empty for a fully compliant project');
    is($rc, 0, 'AC11: exit 0');
}

# ---------------------------------------------------------------------------
# AC12 (f): offline (status=>0) degrades to WARN, never BLOCK, never crashes
# ---------------------------------------------------------------------------
{
    my ($dir, $backpack) = build_pinned_dep_fixture(pkg_version => '2.0.0');
    my $offline_http = sub { return { status => 0, content => '' } };
    my ($report, $rc);
    my $ok = eval {
        ($report, $rc) = BpDepsCheck::run({
            project => $dir, backpack => $backpack, out => undef,
            now => NOW, http => $offline_http,
        });
        1;
    };
    ok($ok, 'AC12: run() does not die when http reports status=>0 (offline/connection failure)')
        or diag("died with: $@");
    my $blocks = safe_arr($report, 'blocks');
    my $warns  = safe_arr($report, 'warns');
    is(scalar(find_kind($warns, 'registry_unavailable')), 1,
       'AC12: exactly one registry_unavailable WARN when http returns status=>0');
    my ($f) = find_kind($warns, 'registry_unavailable');
    $f ||= {};
    is($f->{severity}, 'warn', 'AC12: registry_unavailable finding severity is warn');
    is($f->{remedy}{action}, 'none', 'AC12: registry_unavailable remedy action is none');
    ok($f->{needs_justification}, 'AC12: registry_unavailable WARN has needs_justification true');
    is(scalar(@$blocks), 0, 'AC12: blocks remain empty when offline (never a BLOCK)');
    is($rc, 0, 'AC12: exit 0 despite the offline registry');
}

# ---------------------------------------------------------------------------
# AC13 (f): malformed (non-JSON) registry body degrades to WARN, never crashes
# ---------------------------------------------------------------------------
{
    my ($dir, $backpack) = build_pinned_dep_fixture(pkg_version => '2.0.0');
    my $malformed_http = sub { return { status => 200, content => 'not json' } };
    my ($report, $rc);
    my $ok = eval {
        ($report, $rc) = BpDepsCheck::run({
            project => $dir, backpack => $backpack, out => undef,
            now => NOW, http => $malformed_http,
        });
        1;
    };
    ok($ok, 'AC13: run() does not die when the registry body is not valid JSON')
        or diag("died with: $@");
    my $blocks = safe_arr($report, 'blocks');
    my $warns  = safe_arr($report, 'warns');
    is(scalar(find_kind($warns, 'registry_unavailable')), 1,
       'AC13: exactly one registry_unavailable WARN for a malformed registry body');
    my ($f) = find_kind($warns, 'registry_unavailable');
    $f ||= {};
    is($f->{severity}, 'warn', 'AC13: registry_unavailable finding severity is warn');
    is(scalar(@$blocks), 0, 'AC13: blocks remain empty for a malformed registry body');
    is($rc, 0, 'AC13: exit 0');
}

# ---------------------------------------------------------------------------
# AC14: output file shape + severity/needs_justification invariants
# ---------------------------------------------------------------------------
{
    my ($dir, $backpack) = build_eol_block_fixture();
    my $out_dir  = tempdir(CLEANUP => 1);
    my $out_file = "$out_dir/deps-check.json";
    BpDepsCheck::run({
        project => $dir, backpack => $backpack, out => $out_file,
        now => NOW, http => http_forbidden(),
    });
    ok(-e $out_file, 'AC14: --out file was written to disk');
    my $decoded = eval { JSON::PP->new->decode(slurp($out_file)) };
    ok(defined($decoded), 'AC14: written output file parses as valid JSON') or diag("decode error: $@");
    $decoded ||= {};
    ok(exists $decoded->{blocks},       'AC14: output has a blocks key');
    ok(exists $decoded->{warns},        'AC14: output has a warns key');
    ok(exists $decoded->{generated_at}, 'AC14: output has a generated_at key');
    ok(exists $decoded->{now},          'AC14: output has a now key');
    ok(exists $decoded->{project},      'AC14: output has a project key');
    my @out_blocks = @{ (ref $decoded->{blocks} eq 'ARRAY') ? $decoded->{blocks} : [] };
    my @out_warns  = @{ (ref $decoded->{warns}  eq 'ARRAY') ? $decoded->{warns}  : [] };
    ok(scalar(@out_blocks) > 0, 'AC14: blocks array is non-empty for this fixture (invariant check below is not vacuous)');
    my $blocks_invariant_ok = 1;
    for my $b (@out_blocks) {
        $blocks_invariant_ok = 0 unless (($b->{severity} // '') eq 'block') && !$b->{needs_justification};
    }
    ok($blocks_invariant_ok, 'AC14: every finding in blocks has severity=block and needs_justification=false');
    my $warns_invariant_ok = 1;
    for my $w (@out_warns) {
        $warns_invariant_ok = 0 unless (($w->{severity} // '') eq 'warn') && $w->{needs_justification};
    }
    ok($warns_invariant_ok, 'AC14: every finding in warns has severity=warn and needs_justification=true');
}

# ---------------------------------------------------------------------------
# AC15: exit-code contract (0 clean / 2 block / 1 usage error)
# ---------------------------------------------------------------------------
{
    my ($clean_dir, $clean_bp, $clean_http) = build_pinned_dep_fixture(
        pkg_version => '2.0.0', publish_date => '2026-06-01T00:00:00.000Z',
    );
    my (undef, $rc_clean) = BpDepsCheck::run({
        project => $clean_dir, backpack => $clean_bp, out => undef,
        now => NOW, http => $clean_http,
    });
    is($rc_clean, 0, 'AC15: exit 0 for a fully compliant project');

    my ($block_dir, $block_bp) = build_eol_block_fixture();
    my (undef, $rc_block) = BpDepsCheck::run({
        project => $block_dir, backpack => $block_bp, out => undef,
        now => NOW, http => http_forbidden(),
    });
    is($rc_block, 2, 'AC15: exit 2 for a project with a BLOCK finding');

    # Usage error: --project is required (spec §2.1); omit it entirely.
    my $script = "$Bin/../../scripts/bp-deps-check.pl";
    system($^X, $script);
    my $exit_bad = $? >> 8;
    is($exit_bad, 1, 'AC15: exit 1 for a usage error (missing required --project flag)');
}

# ---------------------------------------------------------------------------
# AC16 (g): doctrine inserted into the authoring-protocol SKILL.md
# (ASCII-only substring checks -- deliberately avoids matching the literal
# "≥" glyph so the assertions aren't sensitive to source-file byte encoding).
# ---------------------------------------------------------------------------
{
    my $path = "$Bin/../../../../plugins/blueprint/skills/authoring-protocol/SKILL.md";
    my $c = slurp($path);
    like($c, qr{\QRecord runtime/version choices up front\E},
         'AC16: authoring-protocol contains the "Record runtime/version choices up front" bullet');
    like($c, qr{\Qlatest LTS/stable\E},
         'AC16: authoring-protocol policy names latest LTS/stable');
    like($c, qr{\Q7 days old\E},
         'AC16: authoring-protocol policy states the >=7-days-old rule');
    like($c, qr{\Qnever EOL\E},
         'AC16: authoring-protocol policy states never EOL');
    like($c, qr{\Qdeclared in the backpack\E},
         'AC16: authoring-protocol policy states declared in the backpack');
}

# ---------------------------------------------------------------------------
# AC17 (g): doctrine inserted into the butler coordinator-protocol SKILL.md
# ---------------------------------------------------------------------------
{
    my $path = "$Bin/../../../../plugins/butler/skills/coordinator-protocol/SKILL.md";
    my $c = slurp($path);
    like($c, qr{\Q## Dependency & version policy\E},
         'AC17: coordinator-protocol has the "Dependency & version policy" section heading');
    like($c, qr{\Qlatest LTS/stable\E},
         'AC17: coordinator-protocol policy names latest LTS/stable');
    like($c, qr{\Q7 days old\E},
         'AC17: coordinator-protocol policy states the >=7-days-old rule');
    like($c, qr{\Qnever EOL\E},
         'AC17: coordinator-protocol policy states never EOL');
    like($c, qr{/backpack:add},
         'AC17: coordinator-protocol names the backpack-declaration duty via /backpack:add');
    like($c, qr{\Qrecorded AND argued\E},
         'AC17: coordinator-protocol requires deviations be recorded AND argued in the ledger');
    like($c, qr{\Qdeviation is a failure, not a judgment call\E},
         'AC17: coordinator-protocol states a silent deviation is a failure, not a judgment call');
}
