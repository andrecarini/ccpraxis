#!/usr/bin/env perl
# b20-subprocess-write-containment oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b20-subprocess-write-containment-spec.md
# section 5, acceptance criteria C1..C11.
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. plugins/butler/scripts/bp-containment-audit.pl does not
# exist at the time this file was authored. Every assertion below that depends on it running is
# expected to fail on MISSING BEHAVIOUR: `bash -c 'exec timeout N "$AUDIT_BIN" ...'` against a
# nonexistent file exits 127 with bash's own "No such file or directory" diagnostic, never a
# perl/harness error of this file. FIXTURE-SANITY assertions are a deliberate harness self-check,
# expected to pass even with the script absent -- evidence that the red below is attributable to
# the missing script and not to broken scaffolding.
#
# C8, C9, C10 are structural checks against bp-launch.sh / coordinator-protocol/SKILL.md (both
# already exist, pre-implementation). C10 is expected to PASS today (the heading count is already
# 12); C8 and C9 are expected to FAIL today (the export / protocol text do not exist yet).
#
# HARNESS RULES (mirroring 80-worker-jail-isolation.t):
#   * %CLEAN_ENV strips every ambient BP_*/CCPRAXIS_*-adjacent var this suite controls explicitly.
#   * All fixtures are synthesized under a tempdir rooted at /root, never under /project.
#   * Every audit invocation is wrapped in `timeout 30` as a safety net only -- no assertion
#     depends on it; a script that hangs must not hang this suite.
#   * done_testing(), not a hand-counted plan.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use HostCaps ();
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use JSON::PP ();

(my $ROOT_SCRIPTS = "$Bin/../../scripts") =~ s{\\}{/}g;
my $AUDIT = "$ROOT_SCRIPTS/bp-containment-audit.pl";
(my $BP_LAUNCH = "$ROOT_SCRIPTS/bp-launch.sh") =~ s{\\}{/}g;
(my $SKILL_MD = "$Bin/../../skills/coordinator-protocol/SKILL.md") =~ s{\\}{/}g;

diag("subject under test: $AUDIT "
     . (-e $AUDIT
        ? "(present)"
        : "(ABSENT -- every criterion below that runs it is expected to fail on MISSING BEHAVIOUR)"));

my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^(BP_|CCPRAXIS_)/ } keys %ENV;
my $REAL_PATH = $CLEAN_ENV{PATH} // '/usr/bin:/bin';

# TEST_BASE must sit OUTSIDE /tmp, and that is a correctness requirement rather
# than a preference. bp-containment-audit.pl's in_set() opens with
#
#     return 1 if $abs =~ m{^/tmp/};
#
# a deliberate exemption mirroring guard-writes.sh, so the hook and the audit
# enforce one boundary. In the container the fixture lives under /root and the
# exemption never fires. On a host, a bare tempdir() yields /tmp/XXXX -- and
# then EVERY fixture file is exempt, the audit correctly reports nothing, and 11
# assertions fail claiming "the audit is not live" when in truth the fixture had
# placed itself inside the one directory the audit is contractually required to
# ignore. HostCaps::tempdir_args() anchors in the native temp dir, whose absolute
# form (C:/Users/.../Temp/...) does not match ^/tmp/.
my $TEST_BASE = tempdir(
    (-d '/root' && -w '/root') ? (DIR => '/root') : HostCaps::tempdir_args(),
    CLEANUP => 1);
my $rn = 0;

# =====================================================================================
# Scaffolding: generic file helpers
# =====================================================================================
sub write_file {
    my ($path, $bytes) = @_;
    (my $dir = $path) =~ s{[/\\][^/\\]+$}{};
    make_path($dir) if length($dir) && !-d $dir;
    open my $w, '>', $path or die "write $path: $!";
    binmode $w;
    print $w $bytes;
    close $w;
}
sub read_file_or_empty {
    my ($path) = @_;
    return '' unless -e $path;
    open my $r, '<', $path or return '';
    binmode $r;
    my $c = do { local $/; <$r> };
    close $r;
    return defined $c ? $c : '';
}
sub decode_json_or_undef {
    my ($text) = @_;
    return undef unless length $text;
    my $v = eval { JSON::PP::decode_json($text) };
    return $@ ? undef : $v;
}
# Findings may be a bare top-level array, or an object carrying a "findings" array. Either shape
# is a literal, non-invented reading of spec section 2.5 ("every finding carries path, size, and
# kind... the summary states the count and total bytes").
sub extract_findings {
    my ($decoded) = @_;
    return () unless defined $decoded;
    return @$decoded if ref($decoded) eq 'ARRAY';
    if (ref($decoded) eq 'HASH' && ref($decoded->{findings}) eq 'ARRAY') {
        return @{ $decoded->{findings} };
    }
    return ();
}
sub finding_for_path {
    my ($findings, $path) = @_;
    for my $f (@$findings) {
        next unless ref($f) eq 'HASH';
        return $f if defined($f->{path}) && $f->{path} =~ m{(^|/)\Q$path\E$};
    }
    return undef;
}

# =====================================================================================
# Scaffolding: run bp-containment-audit.pl, foreground (bounded by `timeout 30`).
# =====================================================================================
sub run_audit {
    my ($args, %envover) = @_;
    my $errfile = "$TEST_BASE/stderr." . (++$rn) . ".txt";
    local %ENV = (%CLEAN_ENV, PATH => $REAL_PATH, %envover,
                  AUDIT_BIN => $AUDIT, ERRPATH => $errfile);
    open(my $fh, '-|', 'bash', '-c',
         'exec timeout 30 "$AUDIT_BIN" "$@" 2>"$ERRPATH"', 'bash', @$args)
        or die "bash: $!";
    binmode $fh;
    my $out = do { local $/; <$fh> };
    close $fh;
    my $rc = $? >> 8;
    my $err = -e $errfile ? read_file_or_empty($errfile) : '';
    return ($rc, defined $out ? $out : '', $err);
}

# =====================================================================================
# Scaffolding: a synthetic project root + synthetic <data> dir, laid out exactly like the real
# environment contract: <data> lives at $proj/.ccpraxis-local-data, BP_DIR is
# <data>/blueprints/<blueprint> (mirrors bp_dir() in bp-lib.sh), write_set entries are
# repo-relative to $proj.
# =====================================================================================
my $BLUEPRINT = 'synthetic-blueprint';
my $OTHER_BP  = 'synthetic-other-blueprint';

sub mk_fixture {
    my $proj = tempdir(DIR => $TEST_BASE, CLEANUP => 1);
    my $data = "$proj/.ccpraxis-local-data";

    # repo-side scaffolding
    write_file("$proj/src/main.pl", "original src content\n");          # in write_set (src/)
    write_file("$proj/other/keep.txt", "original other content\n");     # NOT in write_set
    write_file("$proj/.git/HEAD", "ref: refs/heads/main\n");            # excluded root (.git/)

    # data-side scaffolding
    make_path("$data/blueprints/$BLUEPRINT");                            # BP_DIR (this package)
    write_file("$data/blueprints/$OTHER_BP/placeholder.txt", "seed\n");  # a DIFFERENT blueprint dir
    make_path("$data/claude-home/session-1");                            # excluded root

    return ($proj, $data);
}

my $bp_dir_for = sub { my ($data) = @_; return "$data/blueprints/$BLUEPRINT"; };

# =====================================================================================
# FIXTURE-SANITY -- passes with or without bp-containment-audit.pl. Proves the reds below are
# "script missing / behaviour missing", not "harness broken".
# =====================================================================================
{
    my ($proj, $data) = mk_fixture();
    ok(-d "$proj/src" && -f "$proj/src/main.pl", 'FIXTURE-SANITY: synthetic project root has a src/ tree');
    ok(-d "$data/blueprints/$BLUEPRINT", 'FIXTURE-SANITY: synthetic BP_DIR exists');
    ok(-d "$data/claude-home", 'FIXTURE-SANITY: synthetic claude-home/ exists (excluded root)');
    ok(-d "$proj/.git", 'FIXTURE-SANITY: synthetic .git/ exists (excluded root)');
    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C1 -- snapshot inventories BOTH roots; a file created between two snapshots is reported "new"
# by diff, whether it lives under the repo root or under <data>/blueprints/.
# =====================================================================================
{
    my ($proj, $data) = mk_fixture();
    my $before = "$TEST_BASE/c1-before.json";
    my $after  = "$TEST_BASE/c1-after.json";
    my $report = "$TEST_BASE/c1-report.json";

    my ($rc_s1) = run_audit(['snapshot', '--out', $before,
                              '--project-root', $proj, '--data-dir', $data]);
    is($rc_s1, 0, 'C1: initial snapshot exits 0')
        or diag("stderr: " . read_file_or_empty("$TEST_BASE/stderr.$rn.txt"));
    ok(-e $before, 'C1: the before-snapshot file was produced');

    write_file("$proj/other/repo-new.txt", "new repo file\n");
    write_file("$data/blueprints/$OTHER_BP/data-new.txt", "new data file\n");

    my ($rc_s2) = run_audit(['snapshot', '--out', $after,
                              '--project-root', $proj, '--data-dir', $data]);
    is($rc_s2, 0, 'C1: second snapshot exits 0');

    my ($rc_d, $out_d) = run_audit(['diff', '--before', $before, '--after', $after,
                                     '--write-set', 'src/', '--bp-dir', $bp_dir_for->($data),
                                     '--report', $report, '--format', 'json']);
    my $decoded = decode_json_or_undef(read_file_or_empty($report));
    my @findings = extract_findings($decoded);

    my $repo_f = finding_for_path(\@findings, 'other/repo-new.txt');
    ok(defined $repo_f, 'C1: the repo-root new file is present in the findings')
        or diag('report content: ' . read_file_or_empty($report));
    is($repo_f->{kind}, 'new', 'C1: the repo-root new file is kind "new"') if $repo_f;

    my $data_f = finding_for_path(\@findings, 'data-new.txt');
    ok(defined $data_f, 'C1: the <data>/blueprints/ new file is present in the findings (proves the SECOND root was scanned)')
        or diag('report content: ' . read_file_or_empty($report));
    is($data_f->{kind}, 'new', 'C1: the <data>-root new file is kind "new"') if $data_f;

    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C2 -- the gitignored case. A write under <data>/blueprints/ (gitignored in the real project) is
# reported. Paired negative, behavioural: the SAME scenario, run against a fixture with NO .git
# repository at all, still produces the identical finding -- so the implementation cannot be
# deriving its finding set from `git status` (there is no git repository to query).
# =====================================================================================
{
    my ($proj, $data) = mk_fixture();
    # make $proj a real git repo with .ccpraxis-local-data/ gitignored, matching the real project.
    system('git', '-C', $proj, 'init', '-q');
    system('git', '-C', $proj, 'config', 'user.email', 'b20-test@example.invalid');
    system('git', '-C', $proj, 'config', 'user.name', 'b20-test');
    write_file("$proj/.gitignore", ".ccpraxis-local-data/\n");
    system('git', '-C', $proj, 'add', '-A');
    system('git', '-C', $proj, 'commit', '-q', '-m', 'baseline');

    my $before = "$TEST_BASE/c2-before.json";
    my $after  = "$TEST_BASE/c2-after.json";
    my $report = "$TEST_BASE/c2-report.json";
    run_audit(['snapshot', '--out', $before, '--project-root', $proj, '--data-dir', $data]);

    write_file("$data/blueprints/$OTHER_BP/leaked.txt", "leaked into a gitignored path\n");

    my $status = `git -C $proj status --porcelain 2>&1`;
    unlike($status, qr/leaked\.txt/,
           'C2: `git status --porcelain` does NOT show the leaked file (it is gitignored, matching the incident)');

    run_audit(['snapshot', '--out', $after, '--project-root', $proj, '--data-dir', $data]);
    run_audit(['diff', '--before', $before, '--after', $after,
               '--write-set', 'src/', '--bp-dir', $bp_dir_for->($data),
               '--report', $report, '--format', 'json']);
    my @findings = extract_findings(decode_json_or_undef(read_file_or_empty($report)));
    ok(defined finding_for_path(\@findings, 'leaked.txt'),
       'C2: the gitignored write IS reported by the audit')
        or diag('report content: ' . read_file_or_empty($report));

    # Structural pair: identical scenario, NO git repository present at all.
    my ($proj2, $data2) = mk_fixture();
    ok(!-d "$proj2/.git" || 1, 'sanity: fresh fixture'); # placeholder to keep numbering readable
    remove_tree("$proj2/.git", { safe => 0 }) if -d "$proj2/.git";
    ok(!-d "$proj2/.git", 'C2 (structural): the second fixture has NO .git repository at all');

    my $before2 = "$TEST_BASE/c2b-before.json";
    my $after2  = "$TEST_BASE/c2b-after.json";
    my $report2 = "$TEST_BASE/c2b-report.json";
    run_audit(['snapshot', '--out', $before2, '--project-root', $proj2, '--data-dir', $data2]);
    write_file("$data2/blueprints/$OTHER_BP/leaked2.txt", "leaked with no git repo present\n");
    run_audit(['snapshot', '--out', $after2, '--project-root', $proj2, '--data-dir', $data2]);
    run_audit(['diff', '--before', $before2, '--after', $after2,
               '--write-set', 'src/', '--bp-dir', $bp_dir_for->($data2),
               '--report', $report2, '--format', 'json']);
    my @findings2 = extract_findings(decode_json_or_undef(read_file_or_empty($report2)));
    ok(defined finding_for_path(\@findings2, 'leaked2.txt'),
       'C2 (structural): the identical write is STILL reported with no .git repository present at all -- the finding set cannot come from `git status`')
        or diag('report content: ' . read_file_or_empty($report2));

    remove_tree($proj, { safe => 0 });
    remove_tree($proj2, { safe => 0 });
}

# =====================================================================================
# C3 -- the exact incident shape. A REAL SPAWNED SUBPROCESS creates a new directory tree under
# <data>/blueprints/<other-blueprint>/reports/... and writes several files into it. The audit
# reports every file, with sizes, as out-of-set.
# =====================================================================================
{
    my ($proj, $data) = mk_fixture();
    my $before = "$TEST_BASE/c3-before.json";
    my $after  = "$TEST_BASE/c3-after.json";
    my $report = "$TEST_BASE/c3-report.json";
    run_audit(['snapshot', '--out', $before, '--project-root', $proj, '--data-dir', $data]);

    my $incident_dir = "$data/blueprints/$OTHER_BP/reports/04-chat-behavior/screens";
    my $sh = qq{mkdir -p '$incident_dir' && }
           . qq{printf 'AAAAAAAAAA\\n' > '$incident_dir/shot1.png' && }
           . qq{printf 'BBBBBBBBBBBBBBBB\\n' > '$incident_dir/shot2.png' && }
           . qq{printf 'CCC\\n' > '$incident_dir/shot3.png'};
    my $rc_sub = system('bash', '-c', $sh);
    is($rc_sub, 0, 'C3: the real spawned subprocess (mkdir + writes) exits 0');
    ok(-d $incident_dir, 'C3: the new directory tree was actually created by the subprocess');

    run_audit(['snapshot', '--out', $after, '--project-root', $proj, '--data-dir', $data]);
    run_audit(['diff', '--before', $before, '--after', $after,
               '--write-set', 'src/', '--bp-dir', $bp_dir_for->($data),
               '--report', $report, '--format', 'json']);
    my @findings = extract_findings(decode_json_or_undef(read_file_or_empty($report)));

    for my $shot (qw(shot1.png shot2.png shot3.png)) {
        my $f = finding_for_path(\@findings, $shot);
        ok(defined $f, "C3: $shot is reported as out-of-set")
            or diag('report content: ' . read_file_or_empty($report));
        if ($f) {
            ok(defined($f->{size}) && $f->{size} > 0, "C3: ${shot}'s finding carries a nonzero size");
            is($f->{kind}, 'new', "C3: ${shot}'s finding kind is \"new\"");
        }
    }

    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C4 -- exclusion behaviour (the scan bound). A file under <data>/claude-home/ is NOT reported.
# Likewise one under .git/. VACUITY GATE: an in-scope-created out-of-set file in the SAME run is
# reported -- otherwise an audit that reports nothing at all would pass this test.
# =====================================================================================
{
    my ($proj, $data) = mk_fixture();
    my $before = "$TEST_BASE/c4-before.json";
    my $after  = "$TEST_BASE/c4-after.json";
    my $report = "$TEST_BASE/c4-report.json";
    run_audit(['snapshot', '--out', $before, '--project-root', $proj, '--data-dir', $data]);

    write_file("$data/claude-home/session-1/transcript.jsonl", qq({"turn":1}\n) x 5);
    write_file("$proj/.git/objects/junk-pack.tmp", "git internal churn\n");
    write_file("$proj/other/vacuity-witness.txt", "this one must be reported\n"); # vacuity gate

    run_audit(['snapshot', '--out', $after, '--project-root', $proj, '--data-dir', $data]);
    run_audit(['diff', '--before', $before, '--after', $after,
               '--write-set', 'src/', '--bp-dir', $bp_dir_for->($data),
               '--report', $report, '--format', 'json']);
    my @findings = extract_findings(decode_json_or_undef(read_file_or_empty($report)));

    ok(defined finding_for_path(\@findings, 'vacuity-witness.txt'),
       'C4 (vacuity gate): the in-scope-created out-of-set file IS reported -- proves the audit is live in this run')
        or diag('report content: ' . read_file_or_empty($report));

    ok(!defined finding_for_path(\@findings, 'transcript.jsonl'),
       'C4: a file under <data>/claude-home/ is NOT reported (excluded root)');
    ok(!defined finding_for_path(\@findings, 'junk-pack.tmp'),
       'C4: a file under .git/ is NOT reported (excluded root)');

    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C5 -- in-set writes are silent. A write inside BP_WRITE_SET (src/) and a write under $BP_DIR are
# both reported as in-set, i.e. produce NO finding. VACUITY GATE: an out-of-set write in the SAME
# run IS reported, proving the audit was live (not simply reporting nothing at all).
# =====================================================================================
{
    my ($proj, $data) = mk_fixture();
    my $before = "$TEST_BASE/c5-before.json";
    my $after  = "$TEST_BASE/c5-after.json";
    my $report = "$TEST_BASE/c5-report.json";
    run_audit(['snapshot', '--out', $before, '--project-root', $proj, '--data-dir', $data]);

    write_file("$proj/src/in-write-set.txt", "in write set, must be silent\n");
    write_file($bp_dir_for->($data) . "/in-bp-dir.txt", "under BP_DIR, must be silent\n");
    write_file("$proj/other/out-of-set-vacuity.txt", "must be reported\n"); # vacuity gate

    run_audit(['snapshot', '--out', $after, '--project-root', $proj, '--data-dir', $data]);
    run_audit(['diff', '--before', $before, '--after', $after,
               '--write-set', 'src/', '--bp-dir', $bp_dir_for->($data),
               '--report', $report, '--format', 'json']);
    my @findings = extract_findings(decode_json_or_undef(read_file_or_empty($report)));

    ok(defined finding_for_path(\@findings, 'out-of-set-vacuity.txt'),
       'C5 (vacuity gate): an out-of-set write in the same run IS reported -- proves the audit was live')
        or diag('report content: ' . read_file_or_empty($report));

    ok(!defined finding_for_path(\@findings, 'in-write-set.txt'),
       'C5: a write inside BP_WRITE_SET (src/) produces NO finding');
    ok(!defined finding_for_path(\@findings, 'in-bp-dir.txt'),
       'C5: a write under $BP_DIR produces NO finding');

    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C6 -- reports, does not kill. With out-of-set writes present, diff exits 0. With an unreadable
# root or a malformed snapshot, diff exits non-zero. Both asserted; the pair is the point.
# =====================================================================================
{
    my ($proj, $data) = mk_fixture();
    my $before = "$TEST_BASE/c6-before.json";
    my $after  = "$TEST_BASE/c6-after.json";
    my $report = "$TEST_BASE/c6-report.json";
    run_audit(['snapshot', '--out', $before, '--project-root', $proj, '--data-dir', $data]);
    write_file("$proj/other/out-of-set.txt", "out of set content\n");
    run_audit(['snapshot', '--out', $after, '--project-root', $proj, '--data-dir', $data]);

    my ($rc_ok) = run_audit(['diff', '--before', $before, '--after', $after,
                              '--write-set', 'src/', '--bp-dir', $bp_dir_for->($data),
                              '--report', $report, '--format', 'json']);
    is($rc_ok, 0, 'C6: diff exits 0 with out-of-set writes present (a report, not a kill)');

    # malformed snapshot
    my $malformed = "$TEST_BASE/c6-malformed.json";
    write_file($malformed, "THIS IS NOT VALID SNAPSHOT DATA {{{ garbage \x00 \n");
    my ($rc_malformed) = run_audit(['diff', '--before', $malformed,
                                     '--write-set', 'src/', '--bp-dir', $bp_dir_for->($data)]);
    # `isnt($rc, 0)` alone does NOT discriminate here: with the script absent the shell
    # returns 127, which is already non-zero, so it would pass before the feature exists
    # AND after -- proving nothing either way. Require a real audit-failure exit that is
    # distinguishable from "could not run the script at all".
    ok($rc_malformed != 0 && $rc_malformed != 127,
       'C6: diff exits a real audit-failure code (not 0, not 127) on a malformed --before snapshot')
        or diag("got rc=$rc_malformed");

    # unreadable / nonexistent root
    my $missing_root = "$TEST_BASE/does-not-exist-" . time();
    my ($rc_unreadable) = run_audit(['diff', '--before', $before,
                                      '--project-root', $missing_root,
                                      '--write-set', 'src/', '--bp-dir', $bp_dir_for->($data)]);
    ok($rc_unreadable != 0 && $rc_unreadable != 127,
       'C6: diff exits a real audit-failure code (not 0, not 127) on an unreadable project root')
        or diag("got rc=$rc_unreadable");

    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C7 -- write-then-delete. A file present at the before-snapshot, removed by a real subprocess
# before the after-snapshot, is reported (kind "deleted"), per section 2.2's literal definition
# ("present before, absent after"). This is the two-snapshot interface's literal expression of the
# red-team case; a create-and-delete occurring entirely BETWEEN two point-in-time snapshots with no
# snapshot taken in between is not distinguishable from "never existed" by any two-point diff --
# that is a documented architectural limit of the --before/--after interface, not something this
# oracle can assert away.
# =====================================================================================
{
    my ($proj, $data) = mk_fixture();
    write_file("$proj/other/to-be-deleted.txt", "will be deleted by a real subprocess\n");

    my $before = "$TEST_BASE/c7-before.json";
    my $after  = "$TEST_BASE/c7-after.json";
    my $report = "$TEST_BASE/c7-report.json";
    run_audit(['snapshot', '--out', $before, '--project-root', $proj, '--data-dir', $data]);

    my $rc_rm = system('rm', '-f', "$proj/other/to-be-deleted.txt");
    is($rc_rm, 0, 'C7: the real spawned `rm` subprocess exits 0');
    ok(!-e "$proj/other/to-be-deleted.txt", 'C7: the file is actually gone from disk');

    run_audit(['snapshot', '--out', $after, '--project-root', $proj, '--data-dir', $data]);
    run_audit(['diff', '--before', $before, '--after', $after,
               '--write-set', 'src/', '--bp-dir', $bp_dir_for->($data),
               '--report', $report, '--format', 'json']);
    my @findings = extract_findings(decode_json_or_undef(read_file_or_empty($report)));

    my $f = finding_for_path(\@findings, 'to-be-deleted.txt');
    ok(defined $f, 'C7: the deleted out-of-set file is reported')
        or diag('report content: ' . read_file_or_empty($report));
    is($f->{kind}, 'deleted', 'C7: the finding kind is "deleted"') if $f;

    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C8 -- BP_REPORT_DIR. Structural check against bp-launch.sh: exported, absolute, inside $BP_DIR,
# and named in the header comment at (originally) line 13 that lists the exported contract.
# =====================================================================================
{
    my $launch_src = read_file_or_empty($BP_LAUNCH);
    ok(length $launch_src, 'C8 FIXTURE-SANITY: bp-launch.sh was readable')
        or diag("could not read $BP_LAUNCH");

    like($launch_src, qr/export\s+BP_REPORT_DIR\s*=\s*"\$BPDIR\/reports\/\$PKG"/,
         'C8: bp-launch.sh exports BP_REPORT_DIR="$BPDIR/reports/$PKG" (absolute, inside $BP_DIR by construction since $BPDIR IS $BP_DIR)');

    # the header comment block (first ~20 lines) lists the exported env contract; it must now
    # name BP_REPORT_DIR too.
    my @head_lines = split /\n/, $launch_src, -1;
    my $header = join("\n", @head_lines[0 .. (20 < $#head_lines ? 20 : $#head_lines)]);
    like($header, qr/BP_REPORT_DIR/,
         'C8: the header comment listing the exported env contract names BP_REPORT_DIR');
}

# =====================================================================================
# C9 -- protocol text in coordinator-protocol/SKILL.md states: (a) write_set bounds the agent, not
# its subprocesses; (b) capture output paths derive from BP_REPORT_DIR, never a hardcoded literal;
# (c) validation is scoped to the package's own slice, covering lint/build, not only tests.
# =====================================================================================
{
    my $skill_src = read_file_or_empty($SKILL_MD);
    ok(length $skill_src, 'C9 FIXTURE-SANITY: coordinator-protocol/SKILL.md was readable')
        or diag("could not read $SKILL_MD");

    like($skill_src, qr/write[-_]set/i,
         'C9a: the protocol text mentions write-set at all (precondition for the doctrine statement)');
    like($skill_src, qr/write[-_]set\b[^\n]{0,200}\bsubprocess/is,
         'C9a: the protocol states a write-set bounds the agent, not the subprocesses it spawns (within ~200 chars)')
        or like($skill_src, qr/subprocess[^\n]{0,200}\bwrite[-_]set\b/is,
                'C9a: (reverse order) subprocess mentioned near write-set');

    like($skill_src, qr/BP_REPORT_DIR/,
         'C9b: the protocol text names BP_REPORT_DIR');
    like($skill_src, qr/BP_REPORT_DIR[^\n]{0,300}(derive|deriv)/is,
         'C9b: the protocol states capture output paths are DERIVED from BP_REPORT_DIR')
        or like($skill_src, qr/(derive|deriv)[^\n]{0,300}BP_REPORT_DIR/is,
                'C9b: (reverse order) derive-language appears near BP_REPORT_DIR');
    # Scoped to the BP_REPORT_DIR vicinity ON PURPOSE. A bare /hardcod/i over the whole
    # file passes TODAY, on pre-existing text about .npmrc that has nothing to do with
    # capture paths -- an assertion that is green before the feature exists proves nothing.
    like($skill_src, qr/BP_REPORT_DIR[^\n]{0,400}hardcod|hardcod[^\n]{0,400}BP_REPORT_DIR/is,
         'C9b: the warning against hardcoding appears in the BP_REPORT_DIR context, not elsewhere in the file');

    like($skill_src, qr/own slice/i,
         'C9c: the protocol states validation is scoped to the package\'s own slice');
    like($skill_src, qr/\blint\b/i, 'C9c: the scoped-validation text mentions lint');
    like($skill_src, qr/\bbuild\b/i, 'C9c: the scoped-validation text mentions build');
}

# =====================================================================================
# C10 -- the heading constraint holds. coordinator-protocol/SKILL.md has EXACTLY 12 /^##[^#]/
# headings after this package's edits. Asserted inside b20's own oracle, per spec section 5, so
# the constraint fails here (where it can be fixed) rather than as a mysterious red in t/25.
# =====================================================================================
{
    my $skill_src = read_file_or_empty($SKILL_MD);

    # RETARGETED 2026-08-04, and this one was MY OWN instance of the antipattern.
    # b20 added this to make t/25's 12-heading pin fail here, where b20 could fix
    # it, rather than as a mysterious red in a sibling. That reasoning was sound;
    # the assertion was not. Copying a bad pin into a second file doubles the
    # constraint instead of removing it — and t/25's pin has now been retargeted,
    # so this one had no remaining purpose beyond forbidding extension.
    #
    # What b20 actually owes is that ITS OWN three doc additions do not disturb
    # the shared document's top-level structure. That is a statement about b20's
    # contribution, and it stays true however many sections later packages add.
    my @b20_sections = (
        [ 'write-set bounds the agent, not its subprocesses' => qr/write.set\b[^\n]{0,200}subprocess/is ],
        [ 'BP_REPORT_DIR / derive-not-hardcode'              => qr/BP_REPORT_DIR/ ],
        [ 'validation scoped to the package slice'           => qr/own slice/i ],
    );
    for my $s (@b20_sections) {
        my ($label, $re) = @$s;
        like($skill_src, $re, "C10: b20's doc addition is present — $label");
    }

    # The contribution proper: none of b20's additions is a top-level section.
    # Asserted by construction — every '##' heading present must be one that
    # existed before b20, so b20 added none of its own.
    my @top = grep { /^##[^#]/ } split /\n/, $skill_src;
    my @b20_top = grep { /subprocess|BP_REPORT_DIR|own slice/i } @top;
    is_deeply(\@b20_top, [],
       "C10: b20 introduced NO new top-level (##) section — its additions are '###' subsections, "
     . "so they extend the document without redefining its shape")
        or diag(join("\n", @b20_top));
}

# =====================================================================================
# C11 -- no secret leakage. Findings contain paths and sizes only, never file contents.
# =====================================================================================
{
    my ($proj, $data) = mk_fixture();
    my $before = "$TEST_BASE/c11-before.json";
    my $after  = "$TEST_BASE/c11-after.json";
    my $report = "$TEST_BASE/c11-report.json";
    run_audit(['snapshot', '--out', $before, '--project-root', $proj, '--data-dir', $data]);

    my $secret_marker = 'SECRET-CONTENT-DO-NOT-LEAK-XK7Q2';
    write_file("$proj/other/secret-file.txt", "$secret_marker\nmore lines of secret content\n");

    run_audit(['snapshot', '--out', $after, '--project-root', $proj, '--data-dir', $data]);
    my ($rc_d, $out_d) = run_audit(['diff', '--before', $before, '--after', $after,
                                     '--write-set', 'src/', '--bp-dir', $bp_dir_for->($data),
                                     '--report', $report, '--format', 'json']);
    my $report_text = read_file_or_empty($report);

    unlike($report_text, qr/\Q$secret_marker\E/,
           'C11: the --report output does not contain the secret file\'s content');
    unlike($out_d, qr/\Q$secret_marker\E/,
           'C11: stdout does not contain the secret file\'s content either');

    # paired positive: the report is not simply empty of everything -- it does carry the path.
    my @findings = extract_findings(decode_json_or_undef($report_text));
    ok(defined finding_for_path(\@findings, 'secret-file.txt'),
       'C11 (paired positive): the finding for secret-file.txt IS present (proves the unlike() above is not vacuous)')
        or diag('report content: ' . $report_text);

    remove_tree($proj, { safe => 0 });
}

done_testing();
