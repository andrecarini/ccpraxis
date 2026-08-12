#!/usr/bin/env perl
# t/101-guard-writes-specificity.t — a02-api-and-guard-defects, DEFECT 1.
# guard-writes.sh classifies a path as "a test" by test_paths prefix-match ALONE
# (hooks/lib.sh:92 match_any, called from guard-writes.sh:46), so a broad
# test_paths prefix ("plugins/butler/") swallows a narrower write_set entry
# ("plugins/butler/scripts/bp-blueprint.pl") and bp-implementer is wrongly denied
# its own source file. Spec §2.1 / AC-1..AC-4 / observable behaviors 1-6.
#
# guard-writes.sh is GATED (bp_hook_gate: hooks/lib.sh:9) -- it no-ops entirely
# unless BP_LEDGER, BP_DIR and BP_PROJECT_ROOT are ALL set. Every invocation here
# sets all three explicitly so the hook actually runs its logic; a test that
# forgot one of them would pass vacuously (exit 0 no matter what).
#
# WRITTEN BLIND TO THE IMPLEMENTATION of the specificity-ranking fix. Today's
# guard-writes.sh:45-46 does a bare `match_any "$REL" "$BP_TEST_PATHS"`, with no
# concept of "more specific pattern wins" -- so AC-1 (implementer writing its own
# write_set-listed file under a broader test_paths prefix) is expected to FAIL
# against the pre-change tree: today it exits 2, this file asserts 0.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
use HostCaps qw(tempdir_args);

(my $HOOKS = "$Bin/../../hooks") =~ s{\\}{/}g;
my $GUARD  = "$HOOKS/guard-writes.sh";

my $have_jq = do { my $o = `bash -c 'command -v jq' 2>/dev/null`; $o =~ /\S/ ? 1 : 0 };

my $J    = JSON::PP->new->canonical;
# guard-writes.sh treats ANYTHING under /tmp/ as always-allowed (its own
# always-allowed clause, mirroring bp-containment-audit.pl's in_set()). A bare
# File::Temp::tempdir() on this host's perl already resolves to /tmp/XXXX, so
# the fake BP_PROJECT_ROOT/BP_DIR trees built below would sit INSIDE the one
# path the guard is contractually required to wave through -- every case,
# including the ones this file asserts should be DENIED, would then exit 0
# for the wrong reason, and pass vacuously. Anchor in the native Windows temp
# dir instead (HostCaps::tempdir_args(), the same technique documented in
# t/72-subprocess-containment.t), whose absolute form does not match /tmp/*.
my $ROOT = tempdir(tempdir_args(), CLEANUP => 1);
sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

# guard-writes.sh classifies FP as absolute only via a bash `case "$FP" in
# /*)` test. A raw File::Temp path forwarded to "C:/Users/..." never matches
# that (no leading "/"). Measured: bash's own `realpath -m` does NOT convert
# an already-Windows-absolute path to POSIX form here -- it hands "C:/x" back
# unchanged, since MSYS accepts that spelling as absolute too -- so the fix
# is the house hand-translation (mirrors HostCaps::git_path's drive-letter
# rule, run in reverse): "C:/Users/x" -> "/c/Users/x". Needed for BOTH the
# fake BP_PROJECT_ROOT/BP_DIR trees (mk_env, below) AND the jq-shim directory
# put on PATH just below -- a Windows-form shim path fed straight into PATH
# breaks bash's ':'-separated parsing (the drive letter's own colon splits it
# mid-path).
sub to_posix {
    my ($p) = @_;
    $p = fwd($p);
    $p =~ s{^([A-Za-z]):(?=/|\z)}{'/' . lc($1)}e;
    return $p;
}

# guard-writes.sh is fail-closed on a missing real jq (bp_hook_require_jq),
# and this host (Git for Windows) ships none -- confirmed by the driver
# (`bin.jq  n/a on win32`). Rather than skip_all (a green file that asserts
# nothing is worse than no test), drop a minimal perl stand-in named "jq" on
# a shim PATH directory used ONLY for the hook subprocess below. It answers
# exactly the two queries guard-writes.sh actually issues --
# `.tool_input.file_path // .tool_input.notebook_path // empty` and
# `.cwd // empty` -- via a small dotted-path/`//`-fallback evaluator over
# JSON::PP, not a real jq language implementation. When a real jq IS present
# (e.g. inside the sandbox container) it is preferred and this stub is never
# put on PATH, so the same file exercises the real binary there.
my $JQ_PATH_PREFIX;
unless ($have_jq) {
    my $shim = "$ROOT/jq-shim";
    mkdir $shim or die "mkdir $shim: $!";
    open my $jq, '>', "$shim/jq" or die "open shim jq: $!";
    print $jq <<'PERL';
#!/usr/bin/env perl
# Minimal jq stand-in for t/101 ONLY. Understands exactly the query shape
# guard-writes.sh issues: `-r 'PATH1 // PATH2 // ... // empty'`, where each
# PATHn is a dotted `.a.b.c` lookup into the JSON object on stdin. Prints the
# first defined non-empty scalar found, or nothing (matching `jq -r ... empty`).
use strict;
use warnings;
use JSON::PP;
binmode(STDIN, ':raw');
binmode(STDOUT, ':raw');
my $expr;
for my $a (@ARGV) {
    next if $a eq '-r';
    $expr = $a;
}
my $raw = do { local $/; <STDIN> };
my $doc = eval { JSON::PP->new->utf8->decode($raw) };
my $result;
if (ref $doc eq 'HASH' && defined $expr) {
    for my $term (split m{\s*//\s*}, $expr) {
        $term =~ s/^\s+|\s+$//g;
        last if $term eq 'empty';
        (my $path = $term) =~ s/^\.//;
        my $v = $doc;
        for my $k (split /\./, $path) {
            $v = (ref $v eq 'HASH') ? $v->{$k} : undef;
            last unless defined $v;
        }
        if (defined $v && !ref($v) && $v ne '') { $result = $v; last; }
    }
}
if (defined $result) {
    utf8::encode($result) if utf8::is_utf8($result);
    print $result, "\n";
}
exit 0;
PERL
    close $jq;
    chmod 0755, "$shim/jq";
    $JQ_PATH_PREFIX = to_posix($shim);
}

my $pn = 0;

# Build a fresh fake "project" tree (BP_PROJECT_ROOT) and a fake blueprint dir
# (BP_DIR, disjoint from the project tree). Returns (project_root, bp_dir).
my $envn = 0;
sub mk_env {
    my $n = ++$envn;
    my $proj = "$ROOT/proj$n";
    my $bpd  = "$ROOT/bpdir$n";
    mkdir $proj or die; mkdir $bpd or die; mkdir "$bpd/runs" or die;
    return (to_posix($proj), to_posix($bpd));
}

sub write_marker {
    my ($bpd, $pkg, $worker) = @_;
    open my $f, '>', "$bpd/runs/$pkg.active-worker" or die; print $f $worker; close $f;
}

# run guard-writes.sh with a payload + BP_* env; returns (exit, stdout, stderr)
sub run_guard {
    my ($payload, %env) = @_;
    my $n  = ++$pn;
    my $pf = "$ROOT/payload.$n.json";
    open my $w, '>', $pf or die; print $w $payload; close $w;
    local %ENV = (%CLEAN_ENV, %env, GPATH => fwd($GUARD), PFILE => fwd($pf));
    if (defined $JQ_PATH_PREFIX) {
        $ENV{PATH} = $JQ_PATH_PREFIX . ":" . ($CLEAN_ENV{PATH} // $ENV{PATH} // '/usr/bin:/bin');
    }
    open(my $f, '-|', 'bash', '-c', '"$GPATH" < "$PFILE" 2>&1') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    return ($? >> 8, $o);
}

sub edit_payload {
    my ($proj, $rel) = @_;
    return $J->encode({ tool_name => 'Edit', cwd => $proj,
                         tool_input => { file_path => "$proj/$rel" } });
}

# ── AC-1: write_set entry more specific than test_paths prefix -> bp-implementer allowed ──
{
    my ($proj, $bpd) = mk_env();
    write_marker($bpd, 'pkg', 'butler:bp-implementer');
    my %env = (BP_LEDGER => "$bpd/packages/pkg.md", BP_DIR => $bpd, BP_PROJECT_ROOT => $proj,
               BP_PACKAGE => 'pkg',
               BP_TEST_PATHS => 'plugins/butler/',
               BP_WRITE_SET  => 'plugins/butler/scripts/bp-blueprint.pl');
    my ($rc, $out) = run_guard(edit_payload($proj, 'plugins/butler/scripts/bp-blueprint.pl'), %env);
    is($rc, 0, 'AC-1: implementer writing a write_set-listed file under a broader test_paths prefix -> allowed')
        or diag("guard output: $out");
}

# ── AC-2: same env, a genuine test file (matched only by test_paths) -> still denied,
#          and the message names both the file and the matched pattern ────────────────
{
    my ($proj, $bpd) = mk_env();
    write_marker($bpd, 'pkg', 'butler:bp-implementer');
    my %env = (BP_LEDGER => "$bpd/packages/pkg.md", BP_DIR => $bpd, BP_PROJECT_ROOT => $proj,
               BP_PACKAGE => 'pkg',
               BP_TEST_PATHS => 'plugins/butler/',
               BP_WRITE_SET  => 'plugins/butler/scripts/bp-blueprint.pl');
    my ($rc, $out) = run_guard(edit_payload($proj, 'plugins/butler/tests/t/42-x.t'), %env);
    is($rc, 2, 'AC-2: implementer writing an actual test file (test_paths-only match) -> denied');
    like($out, qr/may not modify test files/, 'AC-2: denial names "test files"');
    like($out, qr/plugins\/butler\/tests\/t\/42-x\.t/, 'AC-2: denial names the file');
    like($out, qr/plugins\/butler\//, 'AC-2: denial names the matched test_paths pattern');
}

# ── AC-3: a tie (write_set also contains the test_paths prefix, this package's own
#          real frontmatter shape) -> ties go to test_paths; oracle stays immutable ──
{
    my ($proj, $bpd) = mk_env();
    write_marker($bpd, 'pkg', 'butler:bp-implementer');
    my %env = (BP_LEDGER => "$bpd/packages/pkg.md", BP_DIR => $bpd, BP_PROJECT_ROOT => $proj,
               BP_PACKAGE => 'pkg',
               BP_TEST_PATHS => 'plugins/butler/tests/t/',
               BP_WRITE_SET  => 'plugins/butler/scripts/bp-blueprint.pl:plugins/butler/tests/t/');
    my ($rc, $out) = run_guard(edit_payload($proj, 'plugins/butler/tests/t/50-x.t'), %env);
    is($rc, 2, 'AC-3: tie between test_paths and write_set -> test_paths wins, write denied')
        or diag("guard output: $out");
}

# ── AC-4: under AC-1's environment, bp-test-writer writing the write_set-listed file
#          -> denied (a file the package names as a write target is not the
#          test-writer's to edit -- a deliberate behaviour change) ─────────────────
{
    my ($proj, $bpd) = mk_env();
    write_marker($bpd, 'pkg', 'butler:bp-test-writer');
    my %env = (BP_LEDGER => "$bpd/packages/pkg.md", BP_DIR => $bpd, BP_PROJECT_ROOT => $proj,
               BP_PACKAGE => 'pkg',
               BP_TEST_PATHS => 'plugins/butler/',
               BP_WRITE_SET  => 'plugins/butler/scripts/bp-blueprint.pl');
    my ($rc, $out) = run_guard(edit_payload($proj, 'plugins/butler/scripts/bp-blueprint.pl'), %env);
    is($rc, 2, 'AC-4: bp-test-writer denied on a file the package names as a write target')
        or diag("guard output: $out");
    like($out, qr/may only write under the package.s test paths/, 'AC-4: denial names the test-writer scope rule');
}

# ── ORACLE-GAP (redteam MAJOR-2, step6): write_set names a GENUINE test file
#    more specifically than a test_paths prefix -> bp-implementer must still be
#    DENIED. AC-1 (above) exercises a NON-test file (bp-blueprint.pl) winning
#    on specificity, which is correct and deliberate; this row is the case AC-1
#    does NOT distinguish -- a write_set pattern that itself names a test under
#    the very directory test_paths already protects. Measured: HEAD=DENY(2),
#    working tree=ALLOW(0). This is the immutable-oracle guarantee: an
#    implementer that can win a specificity race onto its own judge invalidates
#    every green result this package has produced. ─────────────────────────
{
    my ($proj, $bpd) = mk_env();
    write_marker($bpd, 'pkg', 'butler:bp-implementer');
    my %env = (BP_LEDGER => "$bpd/packages/pkg.md", BP_DIR => $bpd, BP_PROJECT_ROOT => $proj,
               BP_PACKAGE => 'pkg',
               BP_TEST_PATHS => 'plugins/butler/tests/t/',
               BP_WRITE_SET  => 'plugins/butler/scripts/bp-blueprint.pl:plugins/butler/tests/t/106-guard-git-mutations-quote-mask.t');
    my ($rc, $out) = run_guard(
        edit_payload($proj, 'plugins/butler/tests/t/106-guard-git-mutations-quote-mask.t'), %env);
    is($rc, 2, 'ORACLE-GAP(MAJOR-2): write_set naming a genuine test file more specifically than test_paths -> implementer still DENIED')
        or diag("guard output: $out");
}

# ── ORACLE-GAP (redteam MAJOR-2, step6): the same skew reached via the
#    sanctioned "--widen-write-set" unblock shape (additive, documented safe).
#    Widening write_set to explicitly include the test_paths directory PLUS
#    one specific test file must not flip that one file from protected to
#    writable while its sibling test stays protected. Measured: HEAD=DENY(2)
#    for the widened file, working tree=ALLOW(0). ──────────────────────────
{
    my ($proj, $bpd) = mk_env();
    write_marker($bpd, 'pkg', 'butler:bp-implementer');
    my %env = (BP_LEDGER => "$bpd/packages/pkg.md", BP_DIR => $bpd, BP_PROJECT_ROOT => $proj,
               BP_PACKAGE => 'pkg',
               BP_TEST_PATHS => 'plugins/butler/tests/t/',
               BP_WRITE_SET  => 'plugins/butler/scripts/bp-blueprint.pl:plugins/butler/tests/t/:plugins/butler/tests/t/106-guard-git-mutations-quote-mask.t');
    my ($rc, $out) = run_guard(
        edit_payload($proj, 'plugins/butler/tests/t/106-guard-git-mutations-quote-mask.t'), %env);
    is($rc, 2, 'ORACLE-GAP(MAJOR-2): --widen-write-set shape naming a test file -> that file stays DENIED to the implementer')
        or diag("guard output: $out");
    my ($rc2, $out2) = run_guard(
        edit_payload($proj, 'plugins/butler/tests/t/17-drive-next.t'), %env);
    is($rc2, 2, 'ORACLE-GAP(MAJOR-2): a sibling test NOT named in write_set stays DENIED (control)')
        or diag("guard output: $out2");
}

# ── behavior 5: BP_TEST_PATHS unset/empty -> classification IN_TESTS=1 for every path,
#                exactly as today (implementer denied everything under it, i.e. denied
#                nothing extra beyond write_set membership: a write_set hit still allows) ──
{
    my ($proj, $bpd) = mk_env();
    write_marker($bpd, 'pkg', 'butler:bp-implementer');
    my %env = (BP_LEDGER => "$bpd/packages/pkg.md", BP_DIR => $bpd, BP_PROJECT_ROOT => $proj,
               BP_PACKAGE => 'pkg',
               BP_TEST_PATHS => '',
               BP_WRITE_SET  => 'plugins/butler/scripts/bp-blueprint.pl');
    my ($rc, $out) = run_guard(edit_payload($proj, 'plugins/butler/scripts/bp-blueprint.pl'), %env);
    is($rc, 0, 'behavior5: empty BP_TEST_PATHS -> implementer write to a write_set file still allowed')
        or diag("guard output: $out");
}

# ── behavior 6: paths under $BP_DIR or /tmp still short-circuit to exit 0; a path
#                outside BP_PROJECT_ROOT still exits 2 (both untouched by the fix) ──
{
    my ($proj, $bpd) = mk_env();
    write_marker($bpd, 'pkg', 'butler:bp-implementer');
    my %env = (BP_LEDGER => "$bpd/packages/pkg.md", BP_DIR => $bpd, BP_PROJECT_ROOT => $proj,
               BP_PACKAGE => 'pkg', BP_TEST_PATHS => 'plugins/butler/', BP_WRITE_SET => '');
    my $ledger_payload = $J->encode({ tool_name => 'Edit', cwd => $bpd,
                                       tool_input => { file_path => "$bpd/packages/pkg.md" } });
    my ($rc1) = run_guard($ledger_payload, %env);
    is($rc1, 0, 'behavior6: a write under BP_DIR itself still short-circuits to exit 0');

    my $outside = $J->encode({ tool_name => 'Edit', cwd => $proj,
                                tool_input => { file_path => '/definitely/outside/the/project/x.pl' } });
    my ($rc2, $out2) = run_guard($outside, %env);
    is($rc2, 2, 'behavior6: a write outside BP_PROJECT_ROOT still exits 2');
    like($out2, qr/outside the project root/, 'behavior6: denial names "outside the project root"');
}

# ── AC-1 regression sibling: same env but the marker is missing entirely (no
#    active-worker file) -> the coordinator itself (no worker role restriction),
#    write_set match alone governs ────────────────────────────────────────────
{
    my ($proj, $bpd) = mk_env();
    # no marker written
    my %env = (BP_LEDGER => "$bpd/packages/pkg.md", BP_DIR => $bpd, BP_PROJECT_ROOT => $proj,
               BP_PACKAGE => 'pkg',
               BP_TEST_PATHS => 'plugins/butler/',
               BP_WRITE_SET  => 'plugins/butler/scripts/bp-blueprint.pl');
    my ($rc, $out) = run_guard(edit_payload($proj, 'plugins/butler/scripts/bp-blueprint.pl'), %env);
    is($rc, 0, 'no active-worker marker: write_set-listed file still allowed (coordinator, no role restriction)')
        or diag("guard output: $out");
}

done_testing();
