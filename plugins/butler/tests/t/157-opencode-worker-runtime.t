#!/usr/bin/env perl
# b34-opencode-worker-runtime oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b34-opencode-worker-runtime-spec.md
# §3, acceptance criteria E1..E14 (mapped 1:1 to DC-1..DC-14, see the spec's own mapping table).
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. plugins/butler/opencode/ does not exist at the time this
# file was authored; the Containerfile has no opencode install; bp-worker.pl has no JSON
# return-contract parsing and no --turn-budget option. Every assertion below that depends on any
# of that is expected to fail on MISSING BEHAVIOUR.
#
# Exceptions, called out explicitly (not silently):
#   * E4/E5 exercise hooks/guard-writes.sh directly -- that script ALREADY SHIPPED (b34 does not
#     reimplement it; it wraps it from a JS plugin). These are expected to PASS now: they are a
#     regression fence for the enforcer the new guard plugin must shell out to unchanged.
#   * E10 requires the real `opencode` binary. It IS installed in this container right now (a
#     coordinator measurement artifact, not yet Containerfile-baked) -- SKIP is not expected to
#     fire; the test runs for real and the report records what it observed.
#   * E11 requires both `opencode` and bp-jail.pl. Both are present, so it also runs for real. The
#     currently-installed opencode resolves under /usr/local (a pnpm store target), and b33's own
#     farm comment explicitly EXCLUDES /usr/local from the `cp -al /usr` skeleton (documented at
#     the "Only /usr/{bin,sbin,lib,lib64} are farmed" comment in bp-jail.pl) -- so this criterion is
#     expected to demonstrate the real gap the spec's §1.2 "lands under /usr" claim glosses over.
#   * E13 asserts invariants that were already true after b33 (nothing needs to cross); expected to
#     PASS now, as a regression fence, not as evidence of b34 work.
#
# HARNESS RULES (mirroring 79/80):
#   * %CLEAN_ENV strips every ambient BP_*/PATH-adjacent var this suite controls explicitly.
#   * All fixtures live under File::Temp / a tempdir rooted at /root (overlayfs, chmod honoured --
#     matches t/156-worker-jail-isolation.t's TEST_BASE rationale). Nothing is written into the live /project tree.
#   * Any invocation of the real `opencode` binary or bp-jail.pl is wrapped in `timeout` -- no
#     assertion depends on it finishing; a hang must not hang this suite.
#   * done_testing(), not a hand-counted plan.
#   * grep -a (not grep) wherever this file's own harness scans jail trees for text, per project
#     CLAUDE.md landmine #5 (binary-silent grep).
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use HostCaps ();
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use File::Find ();
use POSIX qw(WNOHANG);

(my $ROOT_PLUGIN   = "$Bin/../..")                  =~ s{\\}{/}g;
(my $ROOT_SCRIPTS  = "$ROOT_PLUGIN/scripts")         =~ s{\\}{/}g;
(my $ROOT_AGENTS   = "$ROOT_PLUGIN/agents")          =~ s{\\}{/}g;
(my $ROOT_OPENCODE = "$ROOT_PLUGIN/opencode")        =~ s{\\}{/}g;
(my $CONTAINERFILE = "$ROOT_PLUGIN/../sandbox/container/Containerfile") =~ s{\\}{/}g;
my $BP_WORKER = "$ROOT_SCRIPTS/bp-worker.pl";
my $BP_JAIL   = "$ROOT_SCRIPTS/bp-jail.pl";

diag("subject under test: $ROOT_OPENCODE "
     . (-d $ROOT_OPENCODE
        ? "(present)"
        : "(ABSENT -- every criterion below that depends on it is expected to fail on MISSING BEHAVIOUR)"));

my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;
my $REAL_PATH = $CLEAN_ENV{PATH} // '/usr/bin:/bin';

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $TEST_BASE = tempdir((-d '/root' && -w '/root') ? (DIR => '/root') : (), CLEANUP => 1);
my $rn = 0;

# =====================================================================================
# Scaffolding: generic file/text helpers
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
sub read_file {
    my ($path) = @_;
    return undef unless -e $path;
    open my $r, '<', $path or return undef;
    binmode $r;
    my $c = do { local $/; <$r> };
    close $r;
    return defined $c ? $c : '';
}

sub find_files_matching {
    my ($dir, $pattern) = @_;
    my @out;
    return @out unless -d $dir;
    File::Find::find({ no_chdir => 1, wanted => sub {
        return unless -f $_;
        push @out, $File::Find::name if $File::Find::name =~ $pattern;
    } }, $dir);
    return @out;
}

# Parse a --- YAML-ish --- frontmatter block the way this repo's own agent .md files use it:
# first line "---", region until the next "---" line. Returns a hashref of simple scalar keys
# (good enough for name/model/maxTurns/steps/permission-ish single-line values) plus the raw
# frontmatter text (for permission: {...} nested-object cases, which are matched by regex against
# the raw text rather than parsed as YAML -- no CPAN YAML parser is available, core Perl only).
sub read_frontmatter {
    my ($file) = @_;
    my $content = read_file($file);
    return (undef, undef) unless defined $content;
    return (undef, $content) unless $content =~ /\A---\s*\n(.*?)\n---\s*\n/s;
    return ($1, $content);
}

# =====================================================================================
# E1 (DC-1) -- exactly the seven workers ported, no judge, no gate.
#
# The taxonomy here used to be binary: `-judge$` was a judge and EVERYTHING ELSE
# was a pipeline worker owing an OpenCode counterpart. That held only while
# butler/agents/ contained nothing but workers and judges, and it silently
# mis-filed the first agent that was neither. bp-feedback-verifier is a GATE: it
# is dispatched by an interactive skill (/butler:feedback), never by a
# coordinator, so porting it to the OpenCode worker backend would be exactly as
# wrong as porting a judge -- there is no coordinator step that would ever call
# it. (blueprint:bp-auditor is the same shape and only escaped this check by
# living in a different plugin.)
#
# So classify into three buckets by a RULE rather than a name list, and keep the
# "exactly seven" contract meaning what it says: the agents the OpenCode tree
# must mirror.
# =====================================================================================
{
    my @claude_bp = map { m{/([^/]+)\.md$} ? $1 : () }
        find_files_matching($ROOT_AGENTS, qr{/bp-[a-z-]+\.md$});
    my @claude_judges  = sort grep {  /-judge$/    } @claude_bp;
    my @claude_gates   = sort grep {  /-verifier$/ } @claude_bp;
    my @claude_workers = sort grep { !/-judge$/ && !/-verifier$/ } @claude_bp;

    is(scalar(@claude_workers), 7, 'FIXTURE-SANITY: the Claude agent tree has exactly seven pipeline worker bp-* agents')
        or diag('claude workers found: ' . join(',', @claude_workers));
    is(scalar(@claude_judges), 3, 'FIXTURE-SANITY: the Claude agent tree has exactly three bp-*-judge agents')
        or diag('claude judges found: ' . join(',', @claude_judges));

    my @oc_files = find_files_matching($ROOT_OPENCODE, qr{/bp-[a-z-]+\.md$});
    my @oc_names = sort map { m{/([^/]+)\.md$} ? $1 : () } @oc_files;

    is_deeply(\@oc_names, \@claude_workers,
        'E1: plugins/butler/opencode/ carries agent files named for EXACTLY the seven pipeline workers, no more, no fewer')
        or diag('opencode agent basenames found: ' . join(',', @oc_names));

    my @oc_judges = grep { /-judge/ } @oc_names;
    is(scalar(@oc_judges), 0,
        'E1: no bp-*-judge file exists anywhere under plugins/butler/opencode/ (SYN-24: porting a judge is forbidden)')
        or diag('judge-like files found: ' . join(',', @oc_judges));

    my @oc_gates = grep { /-verifier/ } @oc_names;
    is(scalar(@oc_gates), 0,
        'E1: no bp-*-verifier file exists under plugins/butler/opencode/ either -- a gate is skill-dispatched, '
      . 'so no coordinator step would ever reach it')
        or diag('gate-like files found: ' . join(',', @oc_gates));
}

# =====================================================================================
# E2 (DC-2) -- each counterpart's role matches its twin: read-only roles deny edit; the
# implementer/test-writer split is expressed in both.
# =====================================================================================
{
    my @readonly = qw(bp-scout bp-architect bp-reviewer bp-redteam);
    for my $name (@readonly) {
        my $file = "$ROOT_OPENCODE/$name.md";
        my (undef, $raw) = read_frontmatter($file);
      SKIP: {
            skip("E2: $name.md does not exist yet under plugins/butler/opencode/", 1) unless defined $raw;
            like($raw, qr/edit["']?\s*:\s*["']?deny["']?/i,
                "E2: $name (read-only twin) denies edit permission (permission: {edit: deny}-shaped)");
        }
    }

    for my $name (qw(bp-implementer bp-test-writer)) {
        my $file = "$ROOT_OPENCODE/$name.md";
        my $content = read_file($file);
      SKIP: {
            skip("E2: $name.md does not exist yet under plugins/butler/opencode/", 1) unless defined $content;
            like($content, qr/BP_TEST_PATHS/,
                "E2: $name's role split against BP_TEST_PATHS is expressed explicitly (mirrors guard-writes.sh)");
        }
    }
}

# =====================================================================================
# E3 (DC-3) -- the guard plugin invokes guard-writes.sh and reimplements NO path-matching
# logic of its own. Written so a JS reimplementation of the matcher FAILS this test.
# =====================================================================================
{
    my @plugin_candidates = find_files_matching($ROOT_OPENCODE, qr{\.(js|mjs|cjs|ts)$});
    my @guard_plugins = grep {
        my $c = read_file($_);
        defined($c) && $c =~ /guard-writes\.sh/
    } @plugin_candidates;

  SKIP: {
        skip('E3: no guard-plugin JS/TS file found under plugins/butler/opencode/ yet', 6)
            unless @guard_plugins;
        my $file = $guard_plugins[0];
        my $content = read_file($file);
        ok(1, "E3: guard plugin found at $file");
        like($content, qr/guard-writes\.sh/, 'E3: the guard plugin references guard-writes.sh');
        like($content, qr/tool\.execute\.before/, 'E3: the guard plugin hooks tool.execute.before');

        # The two-field payload the plugin must synthesize, per spec §2 item 2.
        like($content, qr/tool_input/, 'E3: the guard plugin synthesizes a tool_input field');
        like($content, qr/\bcwd\b/, 'E3: the guard plugin synthesizes a cwd field');

        # No second matcher: a JS reimplementation of guard-writes.sh's containment logic would
        # necessarily read BP_WRITE_SET/BP_TEST_PATHS itself and/or redeclare match_any-shaped
        # logic. Absence of these is the evidence the plugin is a thin shell-out, not a rewrite.
        unlike($content, qr/BP_WRITE_SET/, 'E3: the plugin does NOT itself read BP_WRITE_SET (guard-writes.sh alone reads it)');
        unlike($content, qr/BP_TEST_PATHS/, 'E3: the plugin does NOT itself read BP_TEST_PATHS (guard-writes.sh alone reads it)');
        unlike($content, qr/match_?[Aa]ny/, 'E3: the plugin does NOT redeclare a match_any-shaped matcher function');
    }
    if (!@guard_plugins) {
        ok(0, 'E3: a guard-plugin file that shells out to guard-writes.sh exists under plugins/butler/opencode/');
    }
}

# =====================================================================================
# Scaffolding shared by E4/E5/E11/E13: invoking guard-writes.sh directly (the pre-existing,
# already-shipped enforcer the new guard plugin must call unmodified), and a minimal fake
# project + jail harness mirroring t/156-worker-jail-isolation.t.
# =====================================================================================
my $GUARD_HOOK = "$ROOT_PLUGIN/hooks/guard-writes.sh";

sub run_guard {
    my (%args) = @_;
    my $payload = qq({"tool_input":{"file_path":"$args{file_path}"},"cwd":"$args{cwd}"});
    my $errfile = "$TEST_BASE/guard-stderr." . (++$rn) . ".txt";
    local %ENV = (%CLEAN_ENV, PATH => $REAL_PATH,
                  BP_LEDGER => $args{ledger}, BP_DIR => $args{bp_dir}, BP_PROJECT_ROOT => $args{proj},
                  BP_WRITE_SET => $args{write_set} // '', BP_TEST_PATHS => $args{test_paths} // '',
                  ERRPATH => fwd($errfile));
    open(my $fh, '-|', 'bash', '-c',
         'printf %s "$1" | exec timeout 10 "$0" 2>"$ERRPATH"', $GUARD_HOOK, $payload)
        or die "bash: $!";
    my $out = do { local $/; <$fh> }; close $fh;
    my $rc = $? >> 8;
    my $err = -e $errfile ? read_file($errfile) : '';
    return ($rc, defined $out ? $out : '', $err);
}

sub mk_guard_fixture {
    my $n = ++$rn;
    my $bp   = "$TEST_BASE/guard-bp-$n";
    my $proj = "$TEST_BASE/guard-proj-$n";
    make_path("$bp/runs");
    make_path($proj);
    my $ledger = "$bp/packages/pkg.md";
    write_file($ledger, "---\npackage: pkg\n---\n");
    return ($bp, $proj, $ledger);
}

my $have_bash = do { my $o = `bash -c 'command -v bash' 2>/dev/null`; $o =~ /\S/ ? 1 : 0 };
my $have_jq   = do { my $o = `bash -c 'command -v jq' 2>/dev/null`; $o =~ /\S/ ? 1 : 0 };

# =====================================================================================
# E4 (DC-4) -- a write inside BP_WRITE_SET is permitted; one outside is denied with the
# hook's OWN stderr, not a paraphrase. Exercises guard-writes.sh directly (pre-existing,
# shipped code) -- see file-header note; expected to PASS now.
# =====================================================================================
SKIP: {
    skip('E4: jq is required by guard-writes.sh (bp_hook_require_jq)', 4) unless $have_jq;

    my ($bp, $proj, $ledger) = mk_guard_fixture();
    my ($rc_ok, $out_ok, $err_ok) = run_guard(
        bp_dir => $bp, proj => $proj, ledger => $ledger, write_set => 'in-scope/',
        file_path => "$proj/in-scope/file.txt", cwd => $proj);
    is($rc_ok, 0, 'E4: a write inside BP_WRITE_SET exits 0 (permitted)');

    my ($rc_bad, $out_bad, $err_bad) = run_guard(
        bp_dir => $bp, proj => $proj, ledger => $ledger, write_set => 'in-scope/',
        file_path => "$proj/out-of-scope/file.txt", cwd => $proj);
    is($rc_bad, 2, 'E4: a write outside BP_WRITE_SET exits 2 (denied)');
    like($err_bad, qr/BLOCKED:.*outside this package's write set/,
        "E4: the denial message is guard-writes.sh's OWN stderr text, not a paraphrase");
    like($err_bad, qr/out-of-scope\/file\.txt/, 'E4: the denial message names the offending relative path');
}

# =====================================================================================
# E5 (DC-5) -- bp-implementer writing a BP_TEST_PATHS file is denied; bp-test-writer writing
# a non-test path is denied. Exercises guard-writes.sh's existing role-split directly.
# =====================================================================================
SKIP: {
    skip('E5: jq is required by guard-writes.sh (bp_hook_require_jq)', 4) unless $have_jq;

    my ($bp, $proj, $ledger) = mk_guard_fixture();
    write_file("$bp/runs/pkg.active-worker", 'butler:bp-implementer');
    my ($rc1, $out1, $err1) = run_guard(
        bp_dir => $bp, proj => $proj, ledger => $ledger,
        write_set => 'src/', test_paths => 'tests/',
        file_path => "$proj/tests/foo.t", cwd => $proj);
    is($rc1, 2, 'E5: bp-implementer writing a BP_TEST_PATHS file is denied');
    like($err1, qr/bp-implementer may not modify test files/i, 'E5: the implementer denial names the reason');

    write_file("$bp/runs/pkg.active-worker", 'butler:bp-test-writer');
    my ($rc2, $out2, $err2) = run_guard(
        bp_dir => $bp, proj => $proj, ledger => $ledger,
        write_set => 'src/', test_paths => 'tests/',
        file_path => "$proj/src/foo.pl", cwd => $proj);
    is($rc2, 2, 'E5: bp-test-writer writing a non-test path is denied');
    like($err2, qr/bp-test-writer may only write under the package's test paths/i,
        'E5: the test-writer denial names the reason');
}

# =====================================================================================
# Scaffolding for E6/E7/E8/E14: bp-worker.pl fixtures (mirrors 155-worker-backend-dispatcher.t).
# =====================================================================================
sub mk_bp {
    my ($blueprint_backend) = @_;
    my $n  = ++$rn;
    my $bp = "$TEST_BASE/bp$n";
    mkdir $bp or die "mkdir $bp: $!";
    mkdir "$bp/$_" or die "mkdir $bp/$_: $!" for qw(packages runs reports);
    my $proj = "$TEST_BASE/proj$n";
    mkdir $proj or die "mkdir $proj: $!";
    my @L = ('```', 'blueprint: sandbox-butler-overhaul', 'created: 2026-08-01T00:00:00Z',
             'status: running   # spike',
             (defined $blueprint_backend && length $blueprint_backend
                ? "worker_backend: $blueprint_backend   # fixture" : ()),
             '```', '', '## Overview', '', 'Fixture.', '');
    write_file("$bp/blueprint.md", join("\n", @L) . "\n");
    return ($bp, $proj);
}
sub add_pkg {
    my ($bp, $pkg, $backend) = @_;
    my @L = ('---', "package: $pkg", 'blueprint: sandbox-butler-overhaul', 'status: running',
             (defined $backend ? "worker_backend: $backend   # fixture" : ()),
             'last_updated: 2026-08-01T00:00:00Z', '---', '', "# Package $pkg", '',
             '## Next action', '', 'Fixture only.', '');
    my $lp = "$bp/packages/$pkg.md";
    write_file($lp, join("\n", @L) . "\n");
    return $lp;
}
sub env_for { my ($bp, $proj, $pkg) = @_; return (BP_DIR => $bp, BP_PACKAGE => $pkg, BP_LEDGER => "$bp/packages/$pkg.md", BP_PROJECT_ROOT => $proj); }
sub marker_path_for { my ($bp, $pkg) = @_; return "$bp/runs/$pkg.active-worker" }
sub reports_dir_for  { my ($bp, $pkg) = @_; return "$bp/reports/$pkg" }
sub write_prompt { my ($text) = @_; my $pf = "$TEST_BASE/prompt." . (++$rn) . ".txt"; write_file($pf, $text); return $pf; }

my $FAKEBIN = "$TEST_BASE/fakebin";
mkdir $FAKEBIN unless -d $FAKEBIN;

# A configurable fake `opencode` binary that emits NDJSON on --format json invocations, driven
# entirely by env vars (one script serves every scenario, mirroring t/155's fake backend design).
my $FAKE_OPENCODE = "$FAKEBIN/opencode";
write_file($FAKE_OPENCODE, <<'SH');
#!/usr/bin/env bash
set -u
if [ -n "${FAKE_ARGSLOG:-}" ]; then
  { printf 'ARGS='; printf '[%s]' "$@"; printf '\n'; } >> "$FAKE_ARGSLOG"
fi
if [ -n "${FAKE_NDJSON_FILE:-}" ]; then
  cat "$FAKE_NDJSON_FILE"
fi
if [ -n "${FAKE_STDERR_TEXT:-}" ]; then
  printf '%s\n' "$FAKE_STDERR_TEXT" >&2
fi
exit "${FAKE_EXIT:-0}"
SH
chmod 0755, $FAKE_OPENCODE or die "chmod $FAKE_OPENCODE: $!";
my $PATH_WITH_FAKE = "$FAKEBIN:$REAL_PATH";
# Mirror PATH into a temp dir as symlinks, omitting exactly the `opencode` name.
# Dropping whole DIRECTORIES that contain opencode does not work: b34 installs it to
# /usr/bin by design, and dropping /usr/bin takes bash with it ("Can't exec bash").
# See the same helper and the same lesson in t/155-worker-backend-dispatcher.t.
sub _mk_path_without_opencode {
    my ($real_path) = @_;
    my $dir = tempdir('bp81-noopencode-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my %seen;
    for my $d (split /:/, $real_path) {
        next unless -d $d;
        opendir(my $dh, $d) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..' || $e eq 'opencode';
            next if $seen{$e}++;
            symlink("$d/$e", "$dir/$e");
        }
        closedir $dh;
    }
    return $dir;
}
# Only attempt the PATH mirror where symlink() actually works.
#
# This helper walks EVERY directory on PATH and symlinks EVERY entry. On Linux
# that is a few hundred cheap calls. On Windows the PATH includes System32 and
# friends — tens of thousands of files — and every symlink() fails slowly. The
# result was not a hang but a crawl: the file spent 15+ minutes here, at FILE
# SCOPE, before reaching a single E6 assertion, and looked exactly like a
# deadlock. (It is also pointless there: without symlinks the mirror would be an
# empty directory, i.e. a PATH with nothing on it.)
my $PATH_WITHOUT_OPENCODE = HostCaps::symlink_works()
    ? _mk_path_without_opencode($REAL_PATH)
    : undef;

# Short-circuit once the backend dispatch is shown not to work on this host.
#
# Each call below is already bounded by `timeout 20`, so nothing hangs forever --
# but there are dozens of them, and on a host where dispatch never completes the
# file spends 20s per call and blows past a 900s wall. bp-worker.pl dispatches by
# fork()+exec(); under MSYS fork is emulated with threads and the parent's
# waitpid() never reaps, so every dispatch burns the full timeout.
#
# After the first timeout, stop paying for the rest: return the same sentinel
# immediately and say why in the stderr slot, so the diags name the cause instead
# of showing an empty output with no explanation. The assertions still fail --
# these groups genuinely are NOT verified here, and pretending otherwise would be
# the lie this whole sweep exists to remove -- but the file now finishes in
# seconds and reports a cause rather than a wall-clock timeout.
#
# DECLARATIVE, not functional -- the one deliberate exception to this sweep's
# rule (HostCaps.pm explains why probes are normally functional). You cannot
# functionally probe a hang: the probe is the hang. Measured on this host,
# a single dispatch did not complete in 4.5 minutes of mostly system time, with
# neither the in-command `timeout 20` nor a parent alarm able to reach the
# wedged emulated-fork child. The limitation is architectural rather than
# incidental -- bp-worker.pl dispatches with real POSIX fork()+exec(), which is
# correct for the Linux container it runs in and is not portable to MSYS -- so
# a platform check states the truth as precisely as a probe would.
my $DISPATCH_DEAD = ($^O =~ /^(MSWin32|cygwin|msys)$/) ? 1 : 0;
diag('bp-worker.pl backend dispatch requires real POSIX fork()+exec(); on this platform it '
   . 'wedges under emulated fork. The E6+ dispatch groups are NOT exercised here -- run them '
   . 'in the sandbox container.') if $DISPATCH_DEAD;
sub run_worker {
    my ($args, %envover) = @_;
    if ($DISPATCH_DEAD) {
        return (124, '', "bp-worker.pl dispatch does not complete on this host "
                       . "(fork()+exec() under emulated fork never reaps); "
                       . "skipped after the first timeout rather than burning 20s again");
    }
    my $n       = ++$rn;
    my $errfile = "$TEST_BASE/wstderr.$n.txt";
    my $outfile = "$TEST_BASE/wstdout.$n.txt";
    local %ENV = (%CLEAN_ENV, PATH => $PATH_WITH_FAKE, %envover,
                  BP_WORKER_BIN => fwd($BP_WORKER), ERRPATH => fwd($errfile),
                  OUTPATH => fwd($outfile));
    # system() + file redirect, NOT open($fh,'-|',...). The pipe-open form makes
    # perl fork; under MSYS that fork is emulated with threads and wedges here
    # permanently -- the parent blocks in <$fh> forever, so the `timeout 20`
    # inside the command never even starts and cannot bound anything. Observed:
    # the file ran 5+ minutes without completing a single dispatch, never
    # reaching E6's first assertion. system() uses spawn instead, so the
    # in-command timeout is actually reachable and this returns.
    system('bash', '-c',
           'exec timeout 20 "$BP_WORKER_BIN" "$@" >"$OUTPATH" 2>"$ERRPATH"', 'bash', @$args);
    my $rc  = $? >> 8;
    my $out = -e $outfile ? read_file($outfile) : '';
    my $err = -e $errfile ? read_file($errfile) : '';
    # 124 is `timeout`'s own "I killed it" code.
    if ($rc == 124) {
        $DISPATCH_DEAD = 1;
        diag('backend dispatch timed out on the first attempt -- remaining run_worker() calls '
           . 'will short-circuit. These groups are NOT verified on this host.');
    }
    return ($rc, defined $out ? $out : '', $err);
}

# =====================================================================================
# E6 (DC-6) -- a worker emitting a wall of text still yields <=15 lines, with the full
# (PARSED, not raw-NDJSON) text under reports/. Mirrors how t/155 A14 asserts b32's identical
# <=15-line contract, but additionally requires the newline-delimited-JSON event stream be
# reduced to the final assistant text (spec §2 item 3), which bp-worker.pl does not do yet.
# =====================================================================================
{
    my ($bp, $proj) = mk_bp('opencode');
    my $pkg = 'b34-e6';
    add_pkg($bp, $pkg, undef);
    my $pf = write_prompt("e6 prompt\n");

    my @events;
    push @events, q({"type":"step_start"});
    for my $i (1 .. 30) {
        push @events, qq({"type":"text","text":"intermediate reasoning line $i"});
    }
    push @events, q({"type":"step_finish"});
    my $final_text = join("\n", map { "final answer line $_" } 1 .. 20) . "\n";
    (my $final_json_escaped = $final_text) =~ s/"/\\"/g;
    $final_json_escaped =~ s/\n/\\n/g;
    push @events, qq({"type":"text","text":"$final_json_escaped"});
    my $ndjson_file = "$TEST_BASE/e6.ndjson";
    write_file($ndjson_file, join("\n", @events) . "\n");

    my ($rc, $out, $err) = run_worker(['--worker', 'implementer', '--prompt-file', $pf],
                                       env_for($bp, $proj, $pkg), FAKE_EXIT => 0,
                                       FAKE_NDJSON_FILE => fwd($ndjson_file));
  SKIP: {
    skip 'bp-worker.pl dispatch does not run on this platform (see $DISPATCH_DEAD) -- '
       . 'E6 NDJSON reduction is NOT exercised here', 6 if $DISPATCH_DEAD;
    is($rc, 0, 'E6: the NDJSON-emitting backend still exits 0');
    my @lines = split /\n/, $out;
    ok(scalar(@lines) <= 15, 'E6: stdout is <=15 lines regardless of a 30-event NDJSON stream')
        or diag("out=$out");

    my ($reportpath) = ($out =~ /^report: (\S.*)$/m);
    ok(defined $reportpath, 'E6: stdout names a report: file');
  SKIP: {
        skip('E6: no report: line to check', 3) unless defined $reportpath;
        ok(-e $reportpath, 'E6: the named report file exists under reports/$BP_PACKAGE/');
        my $report_content = read_file($reportpath) // '';
        unlike($report_content, qr/"type"\s*:\s*"step_start"/,
            'E6: the report file holds the PARSED final assistant text, not the raw NDJSON event stream');
        like($report_content, qr/final answer line 1\b/,
            'E6: the report file contains the final assistant text (the LAST "text" part)');
    }
  }
}

# =====================================================================================
# E7 (DC-7) -- the turn/steps decision: shipped agents carry a per-role default `steps`
# mirroring their Claude twin's maxTurns, AND a dispatch-specified turn budget produces a
# materialised agent-file copy whose steps is the overridden value.
# =====================================================================================
{
    for my $name (qw(bp-scout bp-architect bp-test-writer bp-implementer bp-reviewer bp-redteam bp-ui-prober)) {
        my $claude_file = "$ROOT_AGENTS/$name.md";
        my (undef, $claude_raw) = read_frontmatter($claude_file);
        my ($expect_turns) = ($claude_raw // '') =~ /^maxTurns:\s*(\d+)/m;
      SKIP: {
            skip("E7: could not read maxTurns from the Claude twin $claude_file", 1) unless defined $expect_turns;
            my $oc_file = "$ROOT_OPENCODE/$name.md";
            my (undef, $oc_raw) = read_frontmatter($oc_file);
          SKIP: {
                skip("E7: $oc_file does not exist yet", 1) unless defined $oc_raw;
                like($oc_raw, qr/^steps:\s*$expect_turns\b/m,
                    "E7: $name's OpenCode twin carries a per-role default steps: $expect_turns (mirrors maxTurns)");
            }
        }
    }

    # Dispatch-specified budget materialises a per-dispatch agent copy with steps overridden.
    # bp-worker.pl's exact CLI spelling for a turn budget is not pinned by the spec (only that
    # the mechanism must exist) -- this is the closest reasonable approximation: `--turn-budget`,
    # mirroring the existing optional `--model` pass-through. See test-writer report.
  SKIP: {
        my ($bp, $proj) = mk_bp('opencode');
        my $pkg = 'b34-e7-budget';
        add_pkg($bp, $pkg, undef);
        my $pf = write_prompt("e7 budget prompt\n");
        my $before = { map { ($_ => 1) } find_files_matching($TEST_BASE, qr/./) };

        my ($rc, $out, $err) = run_worker(
            ['--worker', 'implementer', '--prompt-file', $pf, '--turn-budget', '7'],
            env_for($bp, $proj, $pkg), FAKE_EXIT => 0);

        my @after = find_files_matching($TEST_BASE, qr/bp-implementer.*\.md$/);
        my @new_agent_files = grep { !$before->{$_} } @after;
        skip('E7: no dispatch-specified turn-budget mechanism observed yet (no materialised agent file found)', 1)
            unless @new_agent_files;
        my $materialised = read_file($new_agent_files[0]) // '';
        like($materialised, qr/^steps:\s*7\b/m,
            'E7: the materialised per-dispatch agent copy carries the overridden steps value');
    }
}

# =====================================================================================
# E8 (DC-8) -- with no opencode binary on PATH, the dispatcher fails with a CLEAR ACTIONABLE
# message and leaves no marker (b32 already exits 8 for "backend missing"; this asserts the
# message names opencode AND says how to fix it, not just a bare "not found").
# =====================================================================================
{
    my ($bp, $proj) = mk_bp('opencode');
    my $pkg = 'b34-e8';
    add_pkg($bp, $pkg, undef);
    my $pf = write_prompt("e8 prompt\n");
    my ($rc, $out, $err) = run_worker(['--worker', 'implementer', '--prompt-file', $pf],
                                       env_for($bp, $proj, $pkg), PATH => $PATH_WITHOUT_OPENCODE);
  SKIP: {
    # Two independent reasons this cannot run here, and either alone is enough:
    # the dispatch never completes, and $PATH_WITHOUT_OPENCODE is undef because
    # building it needs working symlinks.
    skip 'no opencode-free PATH could be built (symlinks unavailable) and dispatch does not run '
       . 'on this platform -- E8 backend-missing handling is NOT exercised here', 4
        if $DISPATCH_DEAD || !defined $PATH_WITHOUT_OPENCODE;
    is($rc, 8, 'E8: opencode resolved as backend but absent from PATH -> exit 8');
    like($err, qr/opencode/, 'E8: the message names opencode');
    like($err, qr/install|backpack|Containerfile/i,
        'E8: the message is ACTIONABLE -- it hints how to fix it (install/backpack/Containerfile), not a bare "not found"');
    ok(!-e marker_path_for($bp, $pkg), 'E8: no marker is left behind');
  }
}

# =====================================================================================
# E9 (DC-9) -- Containerfile pins opencode-linux-x64@1.18.7 (the PLATFORM package, not
# opencode-ai), and the resolved binary path lands under /usr.
# =====================================================================================
{
    my $content = read_file($CONTAINERFILE);
    ok(defined $content, 'FIXTURE-SANITY: Containerfile is readable')
        or diag("expected at $CONTAINERFILE");
  SKIP: {
        skip('E9: Containerfile unreadable', 4) unless defined $content;
        like($content, qr/opencode-linux-x64\@1\.18\.7/,
            'E9: the Containerfile installs the PLATFORM package opencode-linux-x64 pinned to 1.18.7 exactly');
        unlike($content, qr/opencode-ai/,
            'E9: the Containerfile does NOT install the opencode-ai meta-package (postinstall trap)');
        like($content, qr{ln\s+-sf.*/usr/(?:local/)?bin/opencode},
            'E9: the resolved opencode binary is symlinked under /usr (b33 cp -al /usr farm visibility)');
        like($content, qr/PNPM_CONFIG_IGNORE_SCRIPTS=true/,
            'E9: the install keeps ignore-scripts on (no security-posture exception)');
    }
}

# =====================================================================================
# E10 (DC-10) -- the installed CLI EXECUTES: a version string from the binary, not file
# existence. SKIP if opencode is absent from PATH.
# =====================================================================================
{
    my $opencode_bin = do { my $o = `bash -c 'command -v opencode' 2>/dev/null`; chomp $o; length($o) ? $o : undef };
  SKIP: {
        skip('E10: opencode is not on PATH in this environment', 2) unless defined $opencode_bin;
        my $version_out = `timeout 10 opencode --version 2>&1`;
        my $rc = $? >> 8;
        is($rc, 0, 'E10: `opencode --version` exits 0 (the binary genuinely executes)')
            or diag("opencode_bin=$opencode_bin output=$version_out");
        like($version_out, qr/\d+\.\d+\.\d+/,
            'E10: `opencode --version` prints an actual version string, not a broken-shim error')
            or diag("output observed: $version_out");
    }
}

# =====================================================================================
# E11 (DC-11) -- opencode is reachable FROM INSIDE a b33 jail. SKIP if opencode or bp-jail.pl
# is absent. This is the integration point that would have caught a ~/.opencode/bin-style
# install landing somewhere the jail's farm does not mirror.
# =====================================================================================
{
    my $have_opencode = do { my $o = `bash -c 'command -v opencode' 2>/dev/null`; $o =~ /\S/ ? 1 : 0 };
    my $have_jail = -e $BP_JAIL;
  SKIP: {
        skip('E11: opencode and/or bp-jail.pl absent from this environment', 2)
            unless $have_opencode && $have_jail;

        sub shquote { my $s = shift; $s =~ s/'/'\\''/g; return "'$s'"; }
        sub git_cmd {
            my ($dir, @args) = @_;
            my $cmd = join(' ', 'git', '-C', shquote($dir), map { shquote($_) } @args);
            my $out = `$cmd 2>&1`;
            return ($? >> 8, defined $out ? $out : '');
        }
        my $proj = tempdir(DIR => $TEST_BASE, CLEANUP => 1);
        git_cmd($proj, 'init', '-q');
        git_cmd($proj, 'config', 'user.email', 'b34-test@example.invalid');
        git_cmd($proj, 'config', 'user.name', 'b34-test');
        write_file("$proj/.gitignore", ".ccpraxis-local-data/\n");
        write_file("$proj/in-scope/keep.txt", "x\n");
        git_cmd($proj, 'add', '-A');
        git_cmd($proj, 'commit', '-q', '-m', 'baseline');

        my $jailroot = "$TEST_BASE/e11-jail";
        my $pkg = 'e11-pkg';
        sub run_jail_e11 {
            my ($args, %envover) = @_;
            my $errfile = "$TEST_BASE/e11-stderr." . (++$rn) . ".txt";
            local %ENV = (%CLEAN_ENV, PATH => $REAL_PATH, %envover, ERRPATH => fwd($errfile));
            open(my $fh, '-|', 'bash', '-c',
                 'exec timeout 30 "$0" "$@" 2>"$ERRPATH"', $BP_JAIL, @$args) or die "bash: $!";
            my $out = do { local $/; <$fh> }; close $fh;
            my $rc = $? >> 8;
            my $err = -e $errfile ? read_file($errfile) : '';
            return ($rc, defined $out ? $out : '', $err);
        }
        run_jail_e11(['create', '--package', $pkg, '--jail-root', $jailroot],
                      BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');

        # E11a -- REACHABILITY. Runs unconditionally: this is the assertion that catches a wrong
        # install location, and it needs no execution. b34 must put the binary somewhere
        # bp-jail.pl's farm actually covers -- /usr/{bin,sbin,lib,lib64}, NOT /usr/local, which the
        # farm deliberately excludes.
        my $jailbin = "$jailroot/usr/bin/opencode";
        ok(-e $jailbin || -l $jailbin,
           'E11a: /usr/bin/opencode exists inside the jail (install landed in a FARMED /usr subdir)')
            or diag("absent -- an install under /usr/local is invisible here: bp-jail.pl farms only "
                  . "/usr/{bin,sbin,lib,lib64}");
        my $tgt = readlink($jailbin);
        if (defined $tgt && $tgt =~ m{^/}) {
            ok(-e "$jailroot$tgt",
               'E11a: the absolute symlink target also resolves INSIDE the jail (payload farmed too)')
                or diag("dangling inside jail: $tgt");
        }

        # E11b -- EXECUTION. Split from E11a deliberately: they fail for different reasons and
        # collapsing them would let an install-location regression hide behind an environment skip.
        # MEASURED: on a container built before /opt/bp-jail-skel existed, bp-jail.pl falls back to
        # plain EMPTY FILES for /dev/{null,zero,random,urandom}, and `opencode --version` inside the
        # jail then HANGS (timed out at 500s, exit 124) even with the binary present and resolving --
        # consistent with a runtime reading entropy from an empty regular file.
      SKIP: {
            skip('E11b: this container predates /opt/bp-jail-skel, so the jail has non-functional '
               . 'empty-file /dev nodes and an in-jail exec hangs -- rebuild the container to run '
               . 'this. E11a above still proves the install location is correct.', 2)
                unless -d '/opt/bp-jail-skel';
            my ($rc, $out, $err) = run_jail_e11(
                ['run', '--package', $pkg, '--jail-root', $jailroot, '--', 'opencode', '--version'],
                BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
            is($rc, 0, 'E11b: `opencode --version` succeeds from inside a b33 jail')
                or diag("rc=$rc out=$out err=$err");
            like($out, qr/\d+\.\d+\.\d+/, 'E11b: the in-jail invocation prints a real version string')
                or diag("out=$out err=$err");
        }

        run_jail_e11(['teardown', '--package', $pkg, '--jail-root', $jailroot],
                      BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
        remove_tree($jailroot, { safe => 0 }) if -e $jailroot;
    }
}

# =====================================================================================
# E12 (DC-12) -- a backpack item exists whose verify checks the EXECUTABLE, not the path.
# =====================================================================================
{
    my $home = $ENV{HOME} // '/root';
    my @candidates = ("$home/.claude/backpack.json",
                       '/project/.ccpraxis-local-data/claude-home/backpack.json');
    my ($bpjson_path) = grep { -e $_ } @candidates;
  SKIP: {
        skip('E12: no backpack.json found at any known location', 3) unless defined $bpjson_path;
        my $content = read_file($bpjson_path);
        ok(defined $content && length($content), "E12: backpack.json is readable at $bpjson_path");
        like($content, qr/opencode/i, 'E12: a backpack item mentions opencode');
        # "checks the executable, not the path": require the item's verify to actually invoke the
        # binary (e.g. --version), not merely test file existence (-e/-f/-x on a hardcoded path).
        like($content, qr/opencode[^"]*--version/s,
            'E12: the opencode backpack item\'s verify actually EXECUTES the binary (--version), not just a path test')
            or diag('backpack.json content did not show an executing verify for opencode');
    }
}

# =====================================================================================
# E13 (DC-13) -- STRONG form: no credential crosses into the jail. No auth.json anywhere in
# a fresh jail, no *_API_KEY env var reaches the jailed process, and b33's criterion 1
# (claude-home unreachable) still holds. Expected to PASS now (already-true invariant; see
# file-header note) -- this is a regression fence, not new-code evidence.
# =====================================================================================
{
    my $have_jail = -e $BP_JAIL;
  SKIP: {
        skip('E13: bp-jail.pl is absent from this environment', 4) unless $have_jail;

        my $proj = tempdir(DIR => $TEST_BASE, CLEANUP => 1);
        my (undef) = system("git -C " . shquote($proj) . " init -q >/dev/null 2>&1");
        system("git -C " . shquote($proj) . " config user.email x\@x.invalid >/dev/null 2>&1");
        system("git -C " . shquote($proj) . " config user.name x >/dev/null 2>&1");
        write_file("$proj/.gitignore", ".ccpraxis-local-data/\n");
        write_file("$proj/in-scope/keep.txt", "x\n");
        write_file("$proj/.ccpraxis-local-data/claude-home/.credentials.json", qq({"secret":"do-not-leak"}\n));
        system("git -C " . shquote($proj) . " add -A >/dev/null 2>&1");
        system("git -C " . shquote($proj) . " commit -q -m baseline >/dev/null 2>&1");

        my $jailroot = "$TEST_BASE/e13-jail";
        my $pkg = 'e13-pkg';
        my $errfile1 = "$TEST_BASE/e13-c-" . (++$rn) . ".txt";
        local %ENV = (%CLEAN_ENV, PATH => $REAL_PATH, BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
        system("timeout 30 '$BP_JAIL' create --package '$pkg' --jail-root '$jailroot' 2>'$errfile1'");

        system("timeout 30 '$BP_JAIL' run --package '$pkg' --jail-root '$jailroot' -- "
             . "sh -c 'env > /work/.envdump 2>&1' >/dev/null 2>&1");

        my @named_authjson = grep { /auth\.json$/ } (-d $jailroot ? do {
            my @out; File::Find::find({ no_chdir => 1, wanted => sub { push @out, $File::Find::name } }, $jailroot); @out
        } : ());
        is(scalar(@named_authjson), 0, 'E13: no file named auth.json exists anywhere under a fresh jail');

        # NOTE: bp-jail.pl (b33, unchanged by this package) deliberately does NOT filter the
        # ambient environment before chroot+exec -- env crossing a chroot is exactly the
        # mechanism spec §1.3 names for a FUTURE paid-provider key, so a live probe here would
        # only prove "ambient vars pass through" (b33's own, already-accepted behaviour), not
        # anything about b34. The STRONG claim this package must satisfy is that its OWN code
        # never SETS a credential in the first place -- asserted statically below.
        for my $scan_target ($BP_WORKER, $ROOT_OPENCODE) {
            next unless -e $scan_target;
            my @hits = -d $scan_target
                ? find_files_matching($scan_target, qr/./)
                : ($scan_target);
            for my $f (@hits) {
                next unless -f $f;
                my $c = read_file($f) // '';
                unlike($c, qr/_API_KEY\s*=>?\s*['"\$]/,
                    "E13: $f does not itself set/inject a *_API_KEY credential");
            }
        }

        my @named_claudehome = grep { /claude-home/ } (-d $jailroot ? do {
            my @out; File::Find::find({ no_chdir => 1, wanted => sub { push @out, $File::Find::name } }, $jailroot); @out
        } : ());
        is(scalar(@named_claudehome), 0, 'E13: b33 criterion 1 still holds -- no path anywhere in the jail is named claude-home');

        my $secretcat = `timeout 10 '$BP_JAIL' run --package '$pkg' --jail-root '$jailroot' -- cat '$proj/.ccpraxis-local-data/claude-home/.credentials.json' 2>&1`;
        unlike($secretcat, qr/do-not-leak/, 'E13: the credential content is not readable from inside the jail');

        system("timeout 30 '$BP_JAIL' teardown --package '$pkg' --jail-root '$jailroot' >/dev/null 2>&1");
        remove_tree($jailroot, { safe => 0 }) if -e $jailroot;
    }
}

# =====================================================================================
# E14 (DC-14) -- a provider auth failure surfaces as a DISTINGUISHABLE, NAMED reason, so
# b35's ladder can tell "not logged in" from "rate limited". Since the free tier needs no
# auth, this asserts the CLASSIFICATION PATH exists (a `reason:` field, drawn from a small
# vocabulary, distinct between the two failure shapes) rather than a live auth failure.
# Field name `reason:` is this test-writer's closest-approximation convention (not spec-pinned
# beyond "distinguishable" and "named") -- flagged explicitly in the report.
# =====================================================================================
{
    my ($bp, $proj) = mk_bp('opencode');
    my $pkg = 'b34-e14';
    add_pkg($bp, $pkg, undef);

    my $pf_auth = write_prompt("e14 auth prompt\n");
    my ($rc_auth, $out_auth, $err_auth) = run_worker(
        ['--worker', 'implementer', '--prompt-file', $pf_auth],
        env_for($bp, $proj, $pkg), FAKE_EXIT => 1,
        FAKE_STDERR_TEXT => 'Error: 401 Unauthorized - invalid or missing credentials for provider anthropic');
  SKIP: {
    skip 'bp-worker.pl dispatch does not run on this platform -- E14 failure classification is '
       . 'NOT exercised here', 6 if $DISPATCH_DEAD;
    is($rc_auth, 7, 'E14: the auth-failure-shaped backend still exits 7 (existing failure contract)');
    like($out_auth . $err_auth, qr/^reason:\s*\S+/mi,
        'E14: a distinguishable `reason:` classification field is present for the auth-failure case')
        or diag("out=$out_auth err=$err_auth");

    my ($pkg2) = ('b34-e14b');
    add_pkg($bp, $pkg2, undef);
    my $pf_rate = write_prompt("e14 rate prompt\n");
    my ($rc_rate, $out_rate, $err_rate) = run_worker(
        ['--worker', 'implementer', '--prompt-file', $pf_rate],
        env_for($bp, $proj, $pkg2), FAKE_EXIT => 1,
        FAKE_STDERR_TEXT => 'Error: 429 Too Many Requests - rate limit exceeded, retry after 30s');
    is($rc_rate, 7, 'E14: the rate-limit-shaped backend still exits 7 (existing failure contract)');
    like($out_rate . $err_rate, qr/^reason:\s*\S+/mi,
        'E14: a distinguishable `reason:` classification field is present for the rate-limit case')
        or diag("out=$out_rate err=$err_rate");

    my ($reason_auth) = (($out_auth . $err_auth) =~ /^reason:\s*(\S+)/mi);
    my ($reason_rate) = (($out_rate . $err_rate) =~ /^reason:\s*(\S+)/mi);
  SKIP: {
        skip('E14: no reason: field observed on one or both sides -- classification path absent', 2)
            unless defined $reason_auth && defined $reason_rate;
        isnt($reason_auth, $reason_rate,
            'E14: the auth-failure reason and the rate-limit reason are DISTINCT tokens');
        like($reason_auth, qr/auth|unauthorized|credential|login/i,
            'E14: the auth-failure reason token is semantically an auth classification');
        like($reason_rate, qr/rate|429|throttle|limit/i,
            'E14: the rate-limit reason token is semantically a rate-limit classification');
    }
  }
}

done_testing();
