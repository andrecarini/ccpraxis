#!/usr/bin/env perl
# b06-sandbox-fast-test-io — the immutable test oracle.
#
# Derived ONLY from specs/07-sandbox-fast-test-io-spec.md (the 1117-line
# revision: 29 acceptance criteria, harness contract in §4.0, subtest names in
# §4.3). Nothing in this file was written by reading an implementation:
# bp-fast-store.sh did not exist when it was authored.
#
#   * bp-fast-store.sh — CLI surface (2.1), path/slug resolution (2.3), the
#     shell-unsafe guard (2.4), the pnpm-workspace.yaml rewrite rule (2.5), the .gitignore
#     append rule (2.6), the /backpack:add rendering (2.7), the exit-code table
#     and verbatim messages (2.8), the deliberate omissions (2.9), environment
#     independence (2.10) and the fixed execution order (3.1).
#   * coordinator-protocol/SKILL.md — the documented pattern (3.8 / 7).
#
# Style follows t/09-gate.t (tempdir fixture + %CLEAN_ENV scrubbing + list-form
# `bash -c` + a per-block SKIP: guard) and t/21-durable-checkpoint-commits.t
# (spit/slurp_raw scaffolding, done_testing()).
#
# House rules honoured here:
#   * every fixture lives under File::Temp::tempdir(CLEANUP => 1); /project is
#     NEVER passed as --project (spec 3.7/32 — /project/.gitignore is outside
#     this package's write set, and AC-19 asserts it is byte-identical after the
#     whole run).
#   * no test writes outside $ROOT (spec 4.0). In particular the /root
#     native-root default is pinned by a SOURCE assertion (AC-22 i), never by
#     running the script — the 24-conformance-gate.t:652-663 precedent.
#   * pnpm and node are ABSENT from this container: presence is satisfied by an
#     executable PATH stub that doubles as an AC-17 witness, and the absent case
#     is forced with PATH=<empty dir> so the criterion stays true on a host that
#     does have pnpm (spec 4.0, C2).
#   * "native path unusable" uses the ENOTDIR seam (a parent that is a regular
#     file). NEVER chmod 0555 — this suite runs as uid 0, where 0555 is still
#     writable and such a test would pass vacuously (C3).
#   * t/21:16 declares "no bash/sh -c anywhere", which t/09 and t/14 contradict
#     in practice. The artifact under test IS a bash script, so bash is probed
#     once and the shell-dependent subtests SKIP (never fail) on a bash-less
#     host, per the t/09-gate.t:223 SKIP: idiom (spec 4.0).
#
# One spec-internal conflict, reconciled here rather than silently: §2.2's
# MANDATED skeleton carries the comment lines "bp_project_root is NEVER called"
# and "bp_require_sandbox is deliberately not called", while AC-24 and AC-29
# (iii) say the source "contains no bp_require_sandbox / bp_project_root /
# BP_PROJECT_ROOT". Applied to comments those two demands are unsatisfiable
# together, so the source assertions below are made on COMMENT-STRIPPED code
# lines: no call, no reference, comments free to quote the prohibition. Same
# reconciliation for AC-23 (iii) `git ` and (v) dirname/basename/realpath, whose
# prohibitions §2.2 also spells out in a comment.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

(my $SCRIPT = "$Bin/../../scripts/bp-fast-store.sh") =~ s{\\}{/}g;
-f $SCRIPT or BAIL_OUT("missing $SCRIPT");

(my $SKILL = "$Bin/../../skills/coordinator-protocol/SKILL.md") =~ s{\\}{/}g;
# /project/.gitignore — four levels up from t/, resolved with abs_path (AC-19 ii).
my $REPO_GI = abs_path("$Bin/../../../../.gitignore") // "$Bin/../../../../.gitignore";

my $have_bash = do { my $o = `bash -c "printf bashok" 2>/dev/null`; (defined $o && $o =~ /bashok/) ? 1 : 0 };

# ---------------------------------------------------------------------------
# Verbatim strings from the spec (2.5, 2.6, 2.7). Changing any of these is a
# spec change, not a test change.
# ---------------------------------------------------------------------------
# RETARGETED 2026-08-04 (operator ruling SYN-27): pnpm 10+ silently IGNORES
# kebab-case store-dir/virtual-store-dir written to .npmrc (confirmed broken,
# spec b38-node-pnpm-toolchain 1.3). Layout (storeDir/virtualStoreDir) is
# project-scoped in a gitignored pnpm-workspace.yaml, which pnpm actually
# honours; supply-chain policy stays container-global via ENV PNPM_CONFIG_*
# in the Containerfile. bp-fast-store.sh never writes .npmrc.
my $WORKSPACE_MARKER = '# bp-fast-store: container-native pnpm store (managed lines below; keep pnpm-workspace.yaml gitignored)';
my $GI_HEADER    = '# Added by bp-fast-store.sh (container-native pnpm store/virtual-store; container-specific paths, never commit)';
my $RATIONALE    = 'container-native pnpm store via gitignored pnpm-workspace.yaml (bp-fast-store.sh); the /root store and virtual-store are wiped on container rebuild, so node_modules must be re-materialized or its symlink tree dangles';

# ---------------------------------------------------------------------------
# Local scaffolding (the spec is silent on fixture mechanics; these are ours).
# spit/slurp_raw copied from t/21-durable-checkpoint-commits.t:55-57.
# ---------------------------------------------------------------------------
sub spit { my ($p, $c) = @_; open my $f, '>:raw', $p or die "spit $p: $!"; print $f $c; close $f; return $p }
sub slurp_raw { my ($p) = @_; open my $f, '<:raw', $p or return undef; local $/; my $c = <$f>; close $f; return $c }
sub slurp { my ($p) = @_; return slurp_raw($p) // '' }
sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }            # t/09-gate.t:30

my $ROOT_RAW = tempdir(CLEANUP => 1);
my $ROOT     = abs_path($ROOT_RAW) // $ROOT_RAW;        # pwd -P vs a symlinked /tmp (spec 4)

# The repo's own .gitignore, snapshotted BEFORE anything runs (AC-19 ii), plus
# the paths outside $ROOT that a runaway run would plausibly create (AC-19 iii).
my $REPO_GI_BEFORE = slurp_raw($REPO_GI);
my @CANARIES       = ('/project/pnpm-workspace.yaml', '/project/.gitignore', '/project/node_modules',
                      '/root/.pnpm-store', '/root/my-proj-vstore', '/root/p-vstore');
my %CANARY_BEFORE  = map { ($_ => (-e $_ ? 1 : 0)) } @CANARIES;

# Copied from t/09-gate.t:61-69 (the idiom spec §4.0 makes mandatory). This
# suite is executed BY butler coordinators and harvest judges, which export BP_*
# into the test process. bp-lib.sh's bp_project_root reads BP_PROJECT_ROOT
# first, so an unscrubbed run could resolve to /project while this file believes
# it pointed the script at a tempdir — every assertion would pass vacuously AND
# the script would edit the repo's own .gitignore. Strip ALL ambient BP_* and
# pass only what each case means to test. Two exclusions beyond §4.0's line:
# CCPRAXIS_* (bp_data_dir reads CCPRAXIS_DATA_DIR — AC-29 re-supplies it as a
# decoy on purpose) and IS_SANDBOX (so AC-24's "both unset" is honest).
my %CLEAN_ENV = map { ($_ => $ENV{$_}) }
                grep { !/^BP_/ && !/^CCPRAXIS_/ && $_ ne 'IS_SANDBOX' } keys %ENV;
my $BASE_PATH = $CLEAN_ENV{PATH} // '/usr/bin:/bin';

# pnpm PATH stub (C2). It writes a witness on EVERY invocation; AC-17 asserts
# that witness never appears, i.e. the script never executed pnpm (C9 / 2.9).
my $STUB_DIR     = "$ROOT/stub";
my $STUB_WITNESS = "$ROOT/pnpm-was-executed";
my $EMPTY_PATH   = "$ROOT/empty-path";                  # AC-12: PATH with nothing in it
my $CHILD_CWD    = "$ROOT/cwd";                         # every child runs here, never in /project
make_path($STUB_DIR, $EMPTY_PATH, $CHILD_CWD);

# --- coordinator adjudication (b06, 2026-07-25) -----------------------------
# AC-12 specifies a "truly empty" PATH. That is unrunnable as written, for two
# independent reasons, neither of which any implementation could satisfy:
#   1. run_fs() below uses open($f,'-|','bash',...), and perl resolves 'bash'
#      via PATH -- with an empty PATH the exec fails and the whole file dies
#      ("bash: No such file or directory") before the script under test runs.
#   2. Even past that, the mandated #!/usr/bin/env bash shebang (AC-23 iv) makes
#      env look up bash on PATH, so the script would exit 127, never 3.
# Minimal intent-preserving fix: seed ONLY bash into the otherwise-empty PATH.
# pnpm remains absent, so AC-12's exit-3 and no-side-effects assertions still
# bite; and because no coreutils are reachable, the AC still proves that steps
# 1-5 of the execution order use bash builtins only. Escalated by the
# implementer rather than silently patched; adjudicated and applied here.
symlink((grep { -x $_ } qw(/bin/bash /usr/bin/bash))[0], "$EMPTY_PATH/bash")
    or die "cannot seed bash into EMPTY_PATH: $!";
spit("$STUB_DIR/pnpm", <<'STUB');
#!/bin/sh
# AC-17 witness (spec 4.0): appends its argv when $PNPM_WITNESS is set, then
# exits 0. bp-fast-store.sh must NEVER execute pnpm, in any form.
if [ -n "${PNPM_WITNESS:-}" ]; then
  printf 'pnpm executed with: %s\n' "$*" >> "$PNPM_WITNESS"
fi
exit 0
STUB
chmod 0755, "$STUB_DIR/pnpm";
my $STUB_PATH = "$STUB_DIR:$BASE_PATH";

# ---------------------------------------------------------------------------
# run_fs(args => [...], path => $PATH, env => {...}, cwd => $dir, pwd => $spoof)
#   -> ($exit, $stdout, $stderr)
#
# DELIBERATE DEVIATION from the suite's merged-capture idiom (t/09-gate.t:72-80
# uses `2>&1`): AC-8 pins the STDOUT contract in ISOLATION — stdout must be
# exactly the one /backpack:add line while every progress/error line goes to
# stderr — and a merge makes that unassertable. So stdout and stderr get
# separate redirects into separate files (the idiom spec §4.0 prescribes).
# List-form bash, paths via env, exit code from `$? >> 8`, diag($err) on failure.
#
# The child is cd'd into a scratch dir by default: the project dir defaults to
# `pwd -P` (2.3), and the test process may well be running inside /project.
# `pwd => X` sets the PWD *environment variable* to X while the real cwd stays
# `cwd` — the spoof AC-29 (ii) requires (bash rewrites PWD on its own `cd`, so
# the assignment has to sit in the command's env prefix, after the cd).
# ---------------------------------------------------------------------------
my %SEEN_EXIT;
my $runn = 0;
sub run_fs {
    my (%o) = @_;
    my $n  = ++$runn;
    my $of = "$ROOT/run.$n.out";
    my $ef = "$ROOT/run.$n.err";
    my %env = (%CLEAN_ENV, %{ $o{env} || {} });
    $env{PATH}         = defined $o{path} ? $o{path} : $STUB_PATH;
    $env{PNPM_WITNESS} = fwd($STUB_WITNESS);
    $env{FSPATH}       = fwd($SCRIPT);
    $env{FSOUT}        = fwd($of);
    $env{FSERR}        = fwd($ef);
    $env{FSCWD}        = fwd(defined $o{cwd} ? $o{cwd} : $CHILD_CWD);
    if (defined $o{pwd}) { $env{FSPWD} = fwd($o{pwd}) } else { delete $env{FSPWD} }
    my $out;
    {
        local %ENV = %env;
        open(my $f, '-|', 'bash', '-c',
             'cd "$FSCWD" || exit 111; '
           . 'if [ -n "${FSPWD:-}" ]; then PWD="$FSPWD" "$FSPATH" "$@" >"$FSOUT" 2>"$FSERR"; '
           . 'else "$FSPATH" "$@" >"$FSOUT" 2>"$FSERR"; fi',
             'h', @{ $o{args} || [] })
            or die "bash: $!";
        $out = do { local $/; <$f> };
        close $f;
    }
    my $exit = $? >> 8;
    $SEEN_EXIT{$exit}++;
    diag("stray output from the bash wrapper: $out") if defined $out && $out =~ /\S/;
    return ($exit, slurp($of), slurp($ef));
}

# bash_split($argtext) -> the tokens a shell produces from that literal text.
# Used by AC-11 only; stderr goes to a file so a syntax error never sprays TAP.
my $bsn = 0;
sub bash_split {
    my ($argtext) = @_;
    my $ef = "$ROOT/split." . (++$bsn) . ".err";
    my $cmd = 'set -- ' . $argtext . '; printf "%s\0" "$@"';
    my $pid = open(my $f, '-|');
    return () unless defined $pid;
    unless ($pid) {
        open(STDERR, '>', $ef) or close(STDERR);
        local %ENV = (%CLEAN_ENV);
        exec('bash', '-c', $cmd);
        exit 127;
    }
    my $o = do { local $/; <$f> };
    close $f;
    diag("bash_split stderr: " . slurp($ef)) if slurp($ef) =~ /\S/;
    return () unless defined $o;
    my @t = split /\0/, $o, -1;
    pop @t if @t && $t[-1] eq '';
    return @t;
}

# --- fixture builders -------------------------------------------------------
my $fx = 0;
sub mk_proj {                                   # a project dir with a chosen basename
    my ($base) = @_;
    $base = 'p' unless defined $base && length $base;
    my $dir = "$ROOT/w" . (++$fx) . "/$base";
    make_path($dir) unless -d $dir;
    -d $dir or die "mk_proj $dir: $!";
    return $dir;
}
sub mk_native { my $d = "$ROOT/nat" . (++$fx); return $d }     # NOT created: the script creates it
sub mk_notadir { my $p = "$ROOT/notadir" . (++$fx); spit($p, "i am a regular file, not a directory\n"); return $p }

# slug derivation, transcribed from spec 2.3 step 2.
sub slug_of {
    my ($proj) = @_;
    my $b = $proj; $b =~ s{^.*/}{};
    $b = lc $b;
    $b =~ s/[^a-z0-9]+/-/g;
    $b =~ s/^-+//; $b =~ s/-+$//;
    $b = substr($b, 0, 40);
    $b =~ s/-+$//;
    return length $b ? $b : 'project';
}

# expected pnpm-workspace.yaml bytes (spec 2.5 step 4, retargeted per SYN-27).
sub workspace_expected {
    my ($store, $vstore, @prefix) = @_;
    my $c = '';
    $c .= join("\n", @prefix) . "\n\n" if @prefix;
    return $c . "$WORKSPACE_MARKER\nstoreDir: $store\nvirtualStoreDir: $vstore\n";
}

# expected /backpack:add line (spec 2.7), including the trailing newline.
# --verify asks pnpm ITSELF where its store is (behaviour, not presence — b38
# D6) and confirms a real node_modules entry resolves into the virtual store.
sub backpack_line {
    my ($proj, $store, $vstore, $slug) = @_;
    return "/backpack:add --category 'project-setup' --name 'pnpm-install-$slug'"
         . qq{ --install 'cd "$proj" && pnpm install --frozen-lockfile'}
         . qq{ --verify 'cd "$proj" && test -d node_modules && pnpm store path 2>/dev/null | grep -q "^$store" && test -n "\$(find node_modules -mindepth 1 -maxdepth 1 -type l -exec readlink -f {} + 2>/dev/null | grep "^$vstore" | head -1)"'}
         . " --rationale '$RATIONALE'\n";
}

# every path under $dir, project-relative, sorted (AC-19 i).
sub tree_rel {
    my ($dir) = @_;
    my @out;
    my @stack = ('');
    while (@stack) {
        my $rel = pop @stack;
        my $abs = length $rel ? "$dir/$rel" : $dir;
        opendir(my $dh, $abs) or next;
        for my $e (sort grep { $_ ne '.' && $_ ne '..' } readdir $dh) {
            my $r = length $rel ? "$rel/$e" : $e;
            push @out, $r;
            push @stack, $r if -d "$dir/$r" && !-l "$dir/$r";
        }
        closedir $dh;
    }
    return [ sort @out ];
}

sub lines_of { my ($t) = @_; return [ split /\n/, (defined $t ? $t : ''), -1 ] }
# Comment-stripped source lines. See the header note: §2.2's mandated skeleton
# quotes the very identifiers AC-24 / AC-29 (iii) / AC-23 (iii),(v) forbid, so
# those source assertions are made on code lines, never on comments.
sub code_lines { my ($t) = @_; return [ grep { !/^\s*#/ } split /\n/, (defined $t ? $t : '') ] }
sub count_lines_like { my ($t, $re) = @_; return scalar grep { $_ =~ $re } @{ lines_of($t) } }

# ===========================================================================
# Everything that executes bp-fast-store.sh. Skipped, never failed, on a host
# without bash (t/09-gate.t:223-224 idiom).
# ===========================================================================
SKIP: {
    skip "bash is unavailable on this host and bp-fast-store.sh is a bash script (the shell-level contract cannot be observed without it)", 24
        unless $have_bash;

# --- AC-1 -------------------------------------------------------------------
subtest 'AC-1 cli surface: help, unknown flag, missing value, positional, equals form' => sub {
    my ($rc, $out, $err) = run_fs(args => ['--help']);
    is($rc, 0, 'AC-1: --help exits 0');
    like((split /\n/, $out)[0] // '', qr/^usage: bp-fast-store\.sh /,
         'AC-1: --help prints the usage block on stdout');
    like($out, qr/--project/,       'AC-1: usage documents --project');
    like($out, qr/--native-root/,   'AC-1: usage documents --native-root');
    like($out, qr/--store/,         'AC-1: usage documents --store');
    like($out, qr/--virtual-store/, 'AC-1: usage documents --virtual-store');

    my $bad = mk_proj('badargs');

    ($rc, $out, $err) = run_fs(args => ['--project', $bad, '--nope']);
    is($rc, 2, 'AC-1: unknown option exits 2');
    like($err, qr/^bp-fast-store: unknown option: --nope$/m, 'AC-1: verbatim unknown-option message on stderr');
    like($err, qr/^usage: bp-fast-store\.sh /m, 'AC-1: usage block follows on stderr (2.8)');
    ok(index($err, 'bp-fast-store: unknown option:') < index($err, 'usage: bp-fast-store.sh'),
       'AC-1: the specific message precedes the usage block (2.8)');
    is($out, '', 'AC-1: unknown option writes nothing to stdout');

    ($rc, $out, $err) = run_fs(args => ['--project', $bad, '--store']);
    is($rc, 2, 'AC-1: value-taking flag with no value exits 2');
    like($err, qr/requires a value/, 'AC-1: "requires a value" on stderr');
    is($out, '', 'AC-1: missing value writes nothing to stdout');

    ($rc, $out, $err) = run_fs(args => ['--project', $bad, 'positional']);
    is($rc, 2, 'AC-1: bare positional exits 2');
    like($err, qr/unexpected argument/, 'AC-1: "unexpected argument" on stderr');
    is($out, '', 'AC-1: positional writes nothing to stdout');

    is_deeply(tree_rel($bad), [], 'AC-1: no file is created in the project on any exit-2 path');

    my $proj = mk_proj('equals');
    my $nat  = mk_native();
    my ($rc1, $out1, $err1) = run_fs(args => ['--project', $proj, '--native-root', $nat]);
    my ($rc2, $out2, $err2) = run_fs(args => ["--project=$proj", "--native-root=$nat"]);
    is($rc1, 0, 'AC-1: --flag VALUE form succeeds') or diag($err1);
    is($rc2, 0, 'AC-1: --flag=VALUE form succeeds') or diag($err2);
    is($out2, $out1, 'AC-1: --project=DIR and --project DIR produce byte-identical stdout');

    done_testing();
};

# --- AC-2 -------------------------------------------------------------------
subtest 'AC-2 workspace created with storeDir + virtualStoreDir' => sub {
    my $proj = mk_proj('alpha');
    my $P    = abs_path($proj);
    my $nat  = mk_native();
    my $slug = slug_of($P);
    my $S    = "$nat/.pnpm-store";
    my $V    = "$nat/$slug-vstore";

    my ($rc, $out, $err) = run_fs(args => ['--project', $proj, '--native-root', $nat]);
    is($rc, 0, 'AC-2: exit 0') or diag($err);
    ok(-f "$P/pnpm-workspace.yaml", 'AC-2: <project>/pnpm-workspace.yaml exists');
    my $c = slurp("$P/pnpm-workspace.yaml");
    is($c, workspace_expected($S, $V),
       'AC-2: pnpm-workspace.yaml is exactly marker + storeDir + virtualStoreDir, one trailing newline');
    is(count_lines_like($c, qr/^storeDir: /),         1, 'AC-2: exactly one storeDir line');
    is(count_lines_like($c, qr/^virtualStoreDir: /), 1, 'AC-2: exactly one virtualStoreDir line');
    is(count_lines_like($c, qr/^\Q$WORKSPACE_MARKER\E$/), 1, 'AC-2: verbatim marker line present once');
    unlike($c, qr/^\s*(storeDir|virtualStoreDir)\s+:/m, 'AC-2: no space before either colon');
    like($c, qr/^storeDir: \S/m,         'AC-2: exactly one space after the storeDir colon');
    like($c, qr/^virtualStoreDir: \S/m,  'AC-2: exactly one space after the virtualStoreDir colon');

    done_testing();
};

# --- AC-3 -------------------------------------------------------------------
subtest 'AC-3 workspace rerun is byte-identical' => sub {
    my $proj = mk_proj('rerun');
    my $P    = abs_path($proj);
    my $nat  = mk_native();
    my @args = ('--project', $proj, '--native-root', $nat);

    my ($rc1, undef, $e1) = run_fs(args => \@args);
    is($rc1, 0, 'AC-3: first run exits 0') or diag($e1);
    my $first = slurp("$P/pnpm-workspace.yaml");

    my ($rc2, undef, $e2) = run_fs(args => \@args);
    is($rc2, 0, 'AC-3: second run exits 0') or diag($e2);
    my $second = slurp("$P/pnpm-workspace.yaml");

    is($second, $first, 'AC-3: pnpm-workspace.yaml is byte-identical after an identical re-run (fixed point)');
    is(count_lines_like($second, qr/^storeDir: /),        1, 'AC-3: still exactly one storeDir line');
    is(count_lines_like($second, qr/^virtualStoreDir: /), 1, 'AC-3: still exactly one virtualStoreDir line');

    done_testing();
};

# --- AC-4 -------------------------------------------------------------------
subtest 'AC-4 workspace updates managed keys and preserves unrelated keys' => sub {
    my $proj = mk_proj('preserve');
    my $P    = abs_path($proj);
    my $nat  = mk_native();
    my $slug = slug_of($P);
    my $S    = "$nat/.pnpm-store";
    my $V    = "$nat/$slug-vstore";

    spit("$P/pnpm-workspace.yaml", "packages:\n  - 'apps/*'\nstoreDir: /old/store\nlinkWorkspacePackages: true\n");

    my @args = ('--project', $proj, '--native-root', $nat);
    my ($rc, undef, $err) = run_fs(args => \@args);
    is($rc, 0, 'AC-4: exit 0') or diag($err);

    my $c = slurp("$P/pnpm-workspace.yaml");
    is($c, workspace_expected($S, $V, "packages:", "  - 'apps/*'", 'linkWorkspacePackages: true'),
       'AC-4: preserved prefix, blank line, marker, then the two managed keys (2.5 worked example)');
    is(count_lines_like($c, qr/^storeDir: /),        1, 'AC-4: exactly one storeDir line');
    is(count_lines_like($c, qr/^virtualStoreDir: /), 1, 'AC-4: exactly one virtualStoreDir line');
    like($c, qr/^storeDir: \Q$S\E$/m, 'AC-4: storeDir carries the NEW value');
    unlike($c, qr{/old/store}, 'AC-4: the old store value appears nowhere');
    like($c, qr/^\Qpackages:\E$/m, 'AC-4: unrelated key preserved verbatim');
    like($c, qr{^\QlinkWorkspacePackages: true\E$}m, 'AC-4: second unrelated key preserved verbatim');
    ok(index($c, 'packages:') < index($c, 'linkWorkspacePackages: true'),
       'AC-4: unrelated lines keep their original relative order');

    my ($rc2, undef, $e2) = run_fs(args => \@args);
    is($rc2, 0, 'AC-4: second identical run exits 0') or diag($e2);
    is(slurp("$P/pnpm-workspace.yaml"), $c, 'AC-4: a second identical run is byte-identical');

    done_testing();
};

# --- AC-5 -------------------------------------------------------------------
subtest 'AC-5 gitignore skips out-of-tree native paths' => sub {
    my $proj = mk_proj('outoftree');
    my $P    = abs_path($proj);
    my $nat  = "$ROOT/native-outside" . (++$fx);  # inside $ROOT, outside the project

    my ($rc, undef, $err) = run_fs(args => ['--project', $proj, '--native-root', $nat]);
    is($rc, 0, 'AC-5: exit 0') or diag($err);

    my $gi = slurp("$P/.gitignore");
    is($gi, "$GI_HEADER\npnpm-workspace.yaml\nnode_modules/\n",
       'AC-5: fresh .gitignore is exactly header + pnpm-workspace.yaml + node_modules/ (no leading blank line)');
    is(count_lines_like($gi, qr/^\Q$GI_HEADER\E$/), 1, 'AC-5: the header appears exactly once');
    unlike($gi, qr/\Q$nat\E/,     'AC-5: no line mentions the out-of-tree native root');
    unlike($gi, qr/\.pnpm-store/, 'AC-5: no out-of-tree store entry');
    unlike($gi, qr/-vstore/,      'AC-5: no out-of-tree virtual-store entry');

    done_testing();
};

# --- AC-6 -------------------------------------------------------------------
subtest 'AC-6 gitignore includes in-tree native paths, project-relative' => sub {
    my $proj = mk_proj('intree');
    my $P    = abs_path($proj);
    my $slug = slug_of($P);

    my ($rc, undef, $err) = run_fs(args => ['--project', $proj, '--native-root', "$P/native"]);
    is($rc, 0, 'AC-6: exit 0') or diag($err);

    my $gi = slurp("$P/.gitignore");
    is($gi, "$GI_HEADER\npnpm-workspace.yaml\nnode_modules/\nnative/.pnpm-store/\nnative/$slug-vstore/\n",
       'AC-6: header then pnpm-workspace.yaml, node_modules/, native/.pnpm-store/, native/<slug>-vstore/ in canonical order');
    unlike($gi, qr{^\./}m,       'AC-6: no leading ./ on any entry');
    unlike($gi, qr{^/}m,         'AC-6: no absolute path in .gitignore');
    unlike($gi, qr/\Q$P\E/,      'AC-6: the project prefix is stripped from the entries');
    ok(-d "$P/native/.pnpm-store", 'AC-6: the in-tree native store dir was created');

    done_testing();
};

# --- AC-7 -------------------------------------------------------------------
subtest 'AC-7 gitignore rerun adds nothing and preserves existing lines' => sub {
    # (i) a second identical run is byte-identical
    my $proj = mk_proj('girerun');
    my $P    = abs_path($proj);
    my $nat  = mk_native();
    my @args = ('--project', $proj, '--native-root', $nat);
    my ($rc1, undef, $e1) = run_fs(args => \@args);
    is($rc1, 0, 'AC-7 (i): first run exits 0') or diag($e1);
    my $first = slurp("$P/.gitignore");
    my ($rc2, undef, $e2) = run_fs(args => \@args);
    is($rc2, 0, 'AC-7 (i): second run exits 0') or diag($e2);
    is(slurp("$P/.gitignore"), $first, 'AC-7 (i): .gitignore is byte-identical after a re-run');
    is(count_lines_like($first, qr/^\Q$GI_HEADER\E$/), 1, 'AC-7 (i): still exactly one header line');

    # (ii) pre-seeded with *.log and a BARE node_modules
    my $proj2 = mk_proj('giseed');
    my $P2    = abs_path($proj2);
    my $nat2  = mk_native();
    spit("$P2/.gitignore", "*.log\nnode_modules\n");
    my ($rc3, undef, $e3) = run_fs(args => ['--project', $proj2, '--native-root', $nat2]);
    is($rc3, 0, 'AC-7 (ii): run exits 0') or diag($e3);
    my $gi2 = slurp("$P2/.gitignore");
    is($gi2, "*.log\nnode_modules\n\n$GI_HEADER\npnpm-workspace.yaml\n",
       'AC-7 (ii): existing bytes, one blank line, header, then only the missing entry (2.6 worked example)');
    is(count_lines_like($gi2, qr/^\Q*.log\E$/),       1, 'AC-7 (ii): *.log preserved verbatim');
    is(count_lines_like($gi2, qr/^node_modules$/),    1, 'AC-7 (ii): the bare node_modules line is preserved');
    is(count_lines_like($gi2, qr{^node_modules/$}),   0, 'AC-7 (ii): node_modules/ was NOT added (bare form counts as present)');
    is(count_lines_like($gi2, qr/^pnpm-workspace\.yaml$/), 1, 'AC-7 (ii): pnpm-workspace.yaml WAS added');
    is(count_lines_like($gi2, qr/^\Q$GI_HEADER\E$/),  1, 'AC-7 (ii): the header appears exactly once');

    # (iii) every candidate already present => the file is not written at all
    my $proj3 = mk_proj('gifull');
    my $P3    = abs_path($proj3);
    my $nat3  = mk_native();
    my $gi3p  = "$P3/.gitignore";
    spit($gi3p, "pnpm-workspace.yaml\nnode_modules/\n");
    my $before = slurp($gi3p);
    my $stamp  = time - 10_000;
    utime($stamp, $stamp, $gi3p) or diag("utime failed on $gi3p: $!");
    my ($rc4, undef, $e4) = run_fs(args => ['--project', $proj3, '--native-root', $nat3]);
    is($rc4, 0, 'AC-7 (iii): run exits 0') or diag($e4);
    is(slurp($gi3p), $before, 'AC-7 (iii): .gitignore is byte-identical when nothing is missing');
    is((stat($gi3p))[9], $stamp, 'AC-7 (iii): .gitignore mtime is unchanged (the file was never opened for writing)');

    done_testing();
};

# --- AC-8 -------------------------------------------------------------------
subtest 'AC-8 stdout is exactly the backpack line, chatter on stderr' => sub {
    my $proj = mk_proj('discipline');
    my $nat  = mk_native();
    my ($rc, $out, $err) = run_fs(args => ['--project', $proj, '--native-root', $nat]);
    is($rc, 0, 'AC-8: exit 0') or diag($err);

    is(count_lines_like($out, qr/./), 1, 'AC-8: stdout is exactly one line');
    like($out, qr{^/backpack:add }, 'AC-8: stdout starts with /backpack:add, no leading whitespace');
    like($out, qr/\n\z/,            'AC-8: stdout ends in a single newline');
    unlike($out, qr/\n.*\n/s,       'AC-8: stdout has no second line');

    ok(length $err, 'AC-8: stderr is non-empty (progress is reported)');
    my @bad = grep { !/^(bp-fast-store: |butler: )/ } split /\n/, $err;
    is_deeply(\@bad, [], 'AC-8: every stderr line begins with "bp-fast-store: " or "butler: "');
    unlike($err, qr{/backpack:add}, 'AC-8: the backpack line never appears on stderr');

    done_testing();
};

# --- AC-9 -------------------------------------------------------------------
subtest 'AC-9 backpack line renders byte-exact' => sub {
    my $proj = mk_proj('render');
    my $P    = abs_path($proj);
    my $nat  = mk_native();
    my $slug = slug_of($P);
    my $S    = "$nat/.pnpm-store";
    my $V    = "$nat/$slug-vstore";

    my ($rc, $out, $err) = run_fs(args => ['--project', $proj, '--native-root', $nat]);
    is($rc, 0, 'AC-9: exit 0') or diag($err);
    is($out, backpack_line($P, $S, $V, $slug),
       'AC-9: stdout equals the 2.7 rendering byte for byte (five flags, canonical order, single-quoted values)');

    done_testing();
};

# --- AC-10 ------------------------------------------------------------------
subtest 'AC-10 backpack line omits --version and path, verify checks the native store' => sub {
    my $proj = mk_proj('shape');
    my $P    = abs_path($proj);
    my $nat  = mk_native();
    my $slug = slug_of($P);
    my $S    = "$nat/.pnpm-store";
    my $V    = "$nat/$slug-vstore";

    my ($rc, $out, $err) = run_fs(args => ['--project', $proj, '--native-root', $nat]);
    is($rc, 0, 'AC-10: exit 0') or diag($err);
    chomp(my $line = $out);

    unlike($line, qr/--version/,    'AC-10: no --version flag (a hard error in backpack.pl)');
    unlike($line, qr/backpack\.json/, 'AC-10: no backpack.json path argument');
    unlike($line, qr/--path\b/,     'AC-10: no --path flag');
    unlike($line, qr/--file\b/,     'AC-10: no --file flag');
    like($line, qr{^/backpack:add --category },
         'AC-10: --category follows the slash command directly (no positional path argument)');
    like($line, qr/--category 'project-setup'/,
         "AC-10: the category token is exactly 'project-setup'");
    unlike($line, qr/project_setup/, 'AC-10: not the non-enum spelling project_setup');
    like($line, qr/\Q$S\E/,   'AC-10: --verify names the native store (pnpm store path check)');
    like($line, qr/\Q$V\E/,   'AC-10: --verify names the native virtual store, not only node_modules');
    like($line, qr/pnpm store path/, 'AC-10: --verify asks pnpm itself where its store is (behaviour, not presence)');
    like($line, qr/readlink -f/,     'AC-10: --verify resolves a real node_modules symlink target');

    done_testing();
};

# --- AC-11 ------------------------------------------------------------------
subtest 'AC-11 backpack line survives shell word-splitting without expansion' => sub {
    my $proj = mk_proj('quoting');
    my $P    = abs_path($proj);
    my $nat  = mk_native();
    my $slug = slug_of($P);
    my $S    = "$nat/.pnpm-store";
    my $V    = "$nat/$slug-vstore";

    my ($rc, $out, $err) = run_fs(args => ['--project', $proj, '--native-root', $nat]);
    is($rc, 0, 'AC-11: exit 0') or diag($err);
    chomp(my $line = $out);
    (my $argtext = $line) =~ s{^/backpack:add\s+}{};

    my @tok = bash_split($argtext);
    my $install = qq{cd "$P" && pnpm install --frozen-lockfile};
    my $verify  = qq{cd "$P" && test -d node_modules && pnpm store path 2>/dev/null | grep -q "^$S" && test -n "\$(find node_modules -mindepth 1 -maxdepth 1 -type l -exec readlink -f {} + 2>/dev/null | grep "^$V" | head -1)"};
    is(scalar @tok, 10, 'AC-11: word-splitting the argument portion yields exactly 10 tokens');
    is_deeply(\@tok,
              ['--category', 'project-setup',
               '--name',     "pnpm-install-$slug",
               '--install',  $install,
               '--verify',   $verify,
               '--rationale',$RATIONALE],
              'AC-11: the ten tokens are the five flags and their five unmangled values');
    ok(defined $tok[7] && index($tok[7], '$(find node_modules') >= 0,
       'AC-11: the --verify token still contains the LITERAL $(find node_modules  (no command substitution at paste time)');

    done_testing();
};

# --- AC-12 ------------------------------------------------------------------
subtest 'AC-12 pnpm missing aborts with exit 3 and no side effects' => sub {
    my $proj = mk_proj('nopnpm');
    my $P    = abs_path($proj);
    my $nat  = mk_native();
    my $slug = slug_of($P);

    my ($rc, $out, $err) = run_fs(args => ['--project', $proj, '--native-root', $nat],
                                  path => $EMPTY_PATH);
    is($rc, 3, 'AC-12: exit 3 when command -v pnpm fails') or diag($err);
    like($err, qr/^butler: missing required command: pnpm$/m, 'AC-12: require_cmd house line on stderr');
    like($err, qr/^bp-fast-store: pnpm is required/m,         'AC-12: the bp-fast-store line on stderr');
    is($out, '', 'AC-12: stdout is empty');
    ok(!-e "$P/pnpm-workspace.yaml", 'AC-12: no pnpm-workspace.yaml was written');
    ok(!-e "$P/.gitignore",'AC-12: no .gitignore was written');
    ok(!-e "$nat/.pnpm-store",     'AC-12: the native store dir was not created');
    ok(!-e "$nat/$slug-vstore",    'AC-12: the native virtual-store dir was not created');
    ok(!-e $nat, 'AC-12: the native root itself was not created (steps 1-5 precede any mkdir)');

    done_testing();
};

# --- AC-13 ------------------------------------------------------------------
subtest 'AC-13 pnpm PATH stub satisfies the real command -v check' => sub {
    my $proj = mk_proj('pathstub');
    my $nat  = mk_native();
    my @args = ('--project', $proj, '--native-root', $nat);

    # Same argv, two PATHs: the ONLY difference is whether pnpm is findable.
    my ($rc_no, $out_no, $err_no) = run_fs(args => \@args, path => $EMPTY_PATH);
    is($rc_no, 3, 'AC-13: with an empty PATH the command exits 3') or diag($err_no);
    is($out_no, '', 'AC-13: nothing on stdout without pnpm');

    my ($rc_yes, $out_yes, $err_yes) = run_fs(args => \@args, path => $STUB_PATH);
    is($rc_yes, 0, 'AC-13: with the stub on PATH the identical command exits 0') or diag($err_yes);
    like($out_yes, qr{^/backpack:add }, 'AC-13: and prints the backpack line');

    done_testing();
};

# --- AC-14 ------------------------------------------------------------------
subtest 'AC-14 native store parent is a regular file: exit 5 (ENOTDIR seam)' => sub {
    my $proj = mk_proj('enotdir1');
    my $P    = abs_path($proj);
    my $file = mk_notadir();                     # a REGULAR FILE used as a parent dir
    my $nat  = mk_native();

    my ($rc, $out, $err) = run_fs(args => ['--project', $proj,
                                           '--store', "$file/store",
                                           '--virtual-store', "$nat/vstore"]);
    is($rc, 5, 'AC-14: exit 5 when mkdir -p on the store path hits ENOTDIR') or diag($err);
    like($err, qr/^bp-fast-store: cannot create native store dir: /m, 'AC-14: verbatim stderr message');
    is($out, '', 'AC-14: stdout is empty');
    ok(!-e "$P/pnpm-workspace.yaml", 'AC-14: no pnpm-workspace.yaml was written');
    ok(!-e "$P/.gitignore", 'AC-14: no .gitignore was written');
    ok(-f $file, 'AC-14: the regular file used as the seam is untouched');

    done_testing();
};

# --- AC-15 ------------------------------------------------------------------
subtest 'AC-15 native virtual-store unusable: exit 5 before any project write' => sub {
    my $proj = mk_proj('enotdir2');
    my $P    = abs_path($proj);
    my $file = mk_notadir();
    my $nat  = mk_native();

    my ($rc, $out, $err) = run_fs(args => ['--project', $proj,
                                           '--store', "$nat/store",
                                           '--virtual-store', "$file/vstore"]);
    is($rc, 5, 'AC-15: exit 5 when the virtual-store parent is a regular file') or diag($err);
    like($err, qr/cannot create native virtual-store dir/, 'AC-15: verbatim stderr message');
    is($out, '', 'AC-15: stdout is empty');
    ok(!-e "$P/pnpm-workspace.yaml", 'AC-15: pnpm-workspace.yaml still does not exist (native validation precedes every project write)');
    ok(!-e "$P/.gitignore", 'AC-15: .gitignore still does not exist');

    done_testing();
};

# --- AC-16 ------------------------------------------------------------------
subtest 'AC-16 shell-unsafe and identical paths rejected with exit 2' => sub {
    my $unsafe_dollar = "$ROOT/pn\$store";
    my $unsafe_quote  = "$ROOT/pn\"store";
    my $same          = "$ROOT/samepath";

    my @cases = (
        [ 'dollar',   [ '--store', $unsafe_dollar ], qr/shell-unsafe characters/, [ $unsafe_dollar ] ],
        [ 'quote',    [ '--store', $unsafe_quote  ], qr/shell-unsafe characters/, [ $unsafe_quote  ] ],
        [ 'same path',[ '--store', $same, '--virtual-store', $same ], qr/must be different paths/, [ $same ] ],
    );
    for my $c (@cases) {
        my ($label, $extra, $re, $nots) = @$c;
        my $proj = mk_proj('unsafe');
        my $P    = abs_path($proj);
        my ($rc, $out, $err) = run_fs(args => ['--project', $proj, @$extra]);
        is($rc, 2, "AC-16 [$label]: exit 2") or diag($err);
        like($err, $re, "AC-16 [$label]: the matching stderr message");
        is($out, '', "AC-16 [$label]: stdout is empty");
        ok(!-e "$P/pnpm-workspace.yaml", "AC-16 [$label]: no pnpm-workspace.yaml");
        ok(!-e "$P/.gitignore", "AC-16 [$label]: no .gitignore");
        ok(!-e $_, "AC-16 [$label]: no native dir was created at $_") for @$nots;
    }

    done_testing();
};

# --- AC-17 ------------------------------------------------------------------
subtest 'AC-17 native dirs created, probe removed, pnpm never executed' => sub {
    my $proj = mk_proj('probe');
    my $P    = abs_path($proj);
    my $nat  = mk_native();
    my $slug = slug_of($P);
    my $S    = "$nat/.pnpm-store";
    my $V    = "$nat/$slug-vstore";

    my ($rc, $out, $err) = run_fs(args => ['--project', $proj, '--native-root', $nat]);
    is($rc, 0, 'AC-17: exit 0') or diag($err);
    ok(-d $S, 'AC-17: the native store dir exists as a directory');
    ok(-d $V, 'AC-17: the native virtual-store dir exists as a directory');
    ok(!-e "$S/.bp-fast-store-probe", 'AC-17: no probe file left behind in the store dir');
    ok(!-e "$V/.bp-fast-store-probe", 'AC-17: no probe file left behind in the virtual-store dir');
    is_deeply(tree_rel($S), [], 'AC-17: the created store dir is empty');
    is_deeply(tree_rel($V), [], 'AC-17: the created virtual-store dir is empty');
    ok(!-e $STUB_WITNESS,
       'AC-17: the pnpm stub witness does not exist -- the script never executed pnpm, in any form')
        or diag("witness contents: " . slurp($STUB_WITNESS));

    done_testing();
};

# --- AC-18 ------------------------------------------------------------------
subtest 'AC-18 existing native store contents untouched' => sub {
    my $proj = mk_proj('seeded');
    my $nat  = mk_native();
    my $S    = "$nat/store";
    my $V    = "$nat/vstore";
    make_path($S);
    my $bytes = "sentinel bytes: v1\x00\x01 keep me\n";
    spit("$S/sentinel", $bytes);

    my ($rc, undef, $err) = run_fs(args => ['--project', $proj, '--store', $S, '--virtual-store', $V]);
    is($rc, 0, 'AC-18: exit 0') or diag($err);
    ok(-f "$S/sentinel", 'AC-18: the pre-existing file in the native store still exists');
    is(slurp("$S/sentinel"), $bytes, 'AC-18: its bytes are unchanged (mkdir -p only, never a clean)');

    done_testing();
};

# --- AC-20 ------------------------------------------------------------------
subtest 'AC-20 missing project dir aborts with exit 6' => sub {
    my $missing = "$ROOT/no-such-dir-" . (++$fx);
    my ($rc, $out, $err) = run_fs(args => ['--project', $missing]);
    is($rc, 6, 'AC-20: a non-existent --project exits 6') or diag($err);
    like($err, qr/^bp-fast-store: project dir does not exist or is not a directory: /m,
         'AC-20: verbatim stderr message');
    is($out, '', 'AC-20: stdout is empty');
    ok(!-e $missing, 'AC-20: the missing project dir was not created');

    my $file = mk_notadir();
    my ($rc2, $out2, $err2) = run_fs(args => ['--project', $file]);
    is($rc2, 6, 'AC-20: a regular file as --project exits 6') or diag($err2);
    like($err2, qr/^bp-fast-store: project dir does not exist or is not a directory: /m,
         'AC-20: verbatim stderr message for the regular-file case');
    is($out2, '', 'AC-20: stdout is empty for the regular-file case');

    done_testing();
};

# --- AC-22 ------------------------------------------------------------------
subtest 'AC-22 defaults pinned in source; native-root derivation and slug' => sub {
    # (i) SOURCE assertion for the /root default (24-conformance-gate.t:652-663
    # precedent). It is pinned this way BECAUSE no test may write outside $ROOT
    # (spec 4.0) — running the script with the default would create /root dirs.
    my $src = slurp($SCRIPT);
    ok(length $src, 'AC-22 (i): the script source is readable');
    like($src, qr{(:-|=)\s*/root\b}, 'AC-22 (i): the source pins the /root native-root default');
    like($src, qr/\.pnpm-store/,     'AC-22 (i): the source pins the .pnpm-store store default');
    like($src, qr/-vstore/,          'AC-22 (i): the source pins the <slug>-vstore virtual-store default');

    # (ii)+(iii) behavioural: derivation shape and the slug, hermetically.
    my $proj = mk_proj('My Proj!');
    my $P    = abs_path($proj);
    my $nat  = "$ROOT/native" . (++$fx);
    is(slug_of($P), 'my-proj', 'AC-22 (iii): the test oracle slugs "My Proj!" to my-proj (2.3)');

    my ($rc, $out, $err) = run_fs(args => ['--project', $proj, '--native-root', $nat]);
    is($rc, 0, 'AC-22 (ii): exit 0 for a project basename with a space and a bang') or diag($err);
    my $c = slurp("$P/pnpm-workspace.yaml");
    is($c, workspace_expected("$nat/.pnpm-store", "$nat/my-proj-vstore"),
       'AC-22 (ii): pnpm-workspace.yaml names <native-root>/.pnpm-store and <native-root>/<slug>-vstore');
    like($c, qr{^storeDir: \Q$nat\E/\.pnpm-store$}m,           'AC-22 (ii): storeDir derivation');
    like($c, qr{^virtualStoreDir: \Q$nat\E/my-proj-vstore$}m, 'AC-22 (iii): the virtual store carries the slug');
    like($out, qr/--name 'pnpm-install-my-proj'/, 'AC-22 (iii): the backpack item name carries the slug');

    done_testing();
};

# --- AC-24 ------------------------------------------------------------------
subtest 'AC-24 no bp_require_sandbox gate' => sub {
    ok(!exists $CLEAN_ENV{IS_SANDBOX},  'AC-24: IS_SANDBOX is unset in every child environment');
    ok(!exists $CLEAN_ENV{BP_ALLOW_HOST},'AC-24: BP_ALLOW_HOST is unset in every child environment');

    my $proj = mk_proj('nogate');
    my $nat  = mk_native();
    my ($rc, $out, $err) = run_fs(args => ['--project', $proj, '--native-root', $nat]);
    is($rc, 0, 'AC-24: exits 0 with no sandbox env at all (bp_require_sandbox would exit 4)') or diag($err);
    isnt($rc, 4, 'AC-24: never the bp_require_sandbox exit code 4');
    like($out, qr{^/backpack:add }, 'AC-24: and the backpack line is still printed');

    my @calls = grep { /bp_require_sandbox/ } @{ code_lines(slurp($SCRIPT)) };
    is_deeply(\@calls, [], 'AC-24: no bp_require_sandbox on any code line of the source');

    done_testing();
};

# --- AC-29 (C11 / 2.10: explicit argument beats environment) ----------------
subtest 'AC-29 explicit --project beats BP_PROJECT_ROOT and a spoofed PWD' => sub {
    my $decoy = "$ROOT/decoy";
    make_path($decoy) unless -d $decoy;
    # The decoy env sits ON TOP of the mandatory %CLEAN_ENV scrub (spec 4.0).
    my %DECOY = (
        BP_PROJECT_ROOT   => $decoy,
        BP_DIR            => $decoy,
        BP_PACKAGE        => 'fake',
        BP_WRITE_SET      => 'x',
        CCPRAXIS_DATA_DIR => $decoy,
    );

    # (i) explicit --project wins.
    my $proj = mk_proj('explicit');
    my $P    = abs_path($proj);
    my $nat  = mk_native();
    my $slug = slug_of($P);
    my $S    = "$nat/.pnpm-store";
    my $V    = "$nat/$slug-vstore";
    my ($rc, $out, $err) = run_fs(args => ['--project', $proj, '--native-root', $nat],
                                  env => \%DECOY, pwd => $decoy);
    is($rc, 0, 'AC-29 (i): exit 0 with the decoy env and a spoofed PWD') or diag($err);
    ok(-f "$P/pnpm-workspace.yaml", 'AC-29 (i): the pnpm-workspace.yaml lands in the --project dir');
    is(slurp("$P/pnpm-workspace.yaml"), workspace_expected($S, $V),
       'AC-29 (i): pnpm-workspace.yaml content is exactly what --project/--native-root dictate');
    is($out, backpack_line($P, $S, $V, $slug),
       'AC-29 (i): the backpack line names the --project dir, not BP_PROJECT_ROOT');
    ok(!-e "$decoy/pnpm-workspace.yaml", 'AC-29 (i): the decoy dir gained no pnpm-workspace.yaml');
    ok(!-e "$decoy/.gitignore", 'AC-29 (i): the decoy dir gained no .gitignore');
    unlike($out, qr/\Q$decoy\E/, 'AC-29 (i): no decoy path leaks into the emitted line');

    # (ii) --project omitted: the physical cwd wins over BP_PROJECT_ROOT and PWD.
    my $proj2 = mk_proj('cwddefault');
    my $P2    = abs_path($proj2);
    my $nat2  = mk_native();
    my $slug2 = slug_of($P2);
    my $S2    = "$nat2/.pnpm-store";
    my $V2    = "$nat2/$slug2-vstore";
    my ($rc2, $out2, $err2) = run_fs(args => ['--native-root', $nat2],
                                     env => \%DECOY, cwd => $proj2, pwd => $decoy);
    is($rc2, 0, 'AC-29 (ii): exit 0 with --project omitted') or diag($err2);
    ok(-f "$P2/pnpm-workspace.yaml", 'AC-29 (ii): the working directory is configured, not BP_PROJECT_ROOT');
    is(slurp("$P2/pnpm-workspace.yaml"), workspace_expected($S2, $V2),
       'AC-29 (ii): pnpm-workspace.yaml content matches the cwd project (pwd -P is authoritative)');
    is($out2, backpack_line($P2, $S2, $V2, $slug2),
       'AC-29 (ii): the backpack line names the cwd project, not the spoofed PWD');
    ok(!-e "$decoy/pnpm-workspace.yaml", 'AC-29 (ii): the decoy dir still has no pnpm-workspace.yaml');
    ok(!-e "$decoy/.gitignore", 'AC-29 (ii): the decoy dir still has no .gitignore');
    is_deeply(tree_rel($decoy), [], 'AC-29: nothing at all was written into the decoy dir');

    # (iii) source assertions (comment-stripped code lines; see the file header).
    my $code = code_lines(slurp($SCRIPT));
    is_deeply([ grep { /bp_project_root/ } @$code ], [], 'AC-29 (iii): no bp_project_root call in the source');
    is_deeply([ grep { /bp_data_dir/ }     @$code ], [], 'AC-29 (iii): no bp_data_dir call in the source');
    is_deeply([ grep { /BP_PROJECT_ROOT/ } @$code ], [], 'AC-29 (iii): no BP_PROJECT_ROOT read in the source');

    done_testing();
};

# --- AC-19 (whole-file confinement; runs after every other invocation) ------
subtest 'AC-19 writes are confined to the project and native dirs' => sub {
    my $proj = mk_proj('confined');
    my $P    = abs_path($proj);
    my $nat  = mk_native();

    my ($rc, undef, $err) = run_fs(args => ['--project', $proj, '--native-root', $nat]);
    is($rc, 0, 'AC-19: exit 0') or diag($err);

    my $tree = tree_rel($P);
    is_deeply($tree, ['.gitignore', 'pnpm-workspace.yaml'],
              'AC-19 (i): the only paths under <project> are pnpm-workspace.yaml and .gitignore');
    is_deeply([ grep { m{(^|/)node_modules(/|$)} } @$tree ], [], 'AC-19 (i): no node_modules created');
    is_deeply([ grep { /\.tmp$/ } @$tree ], [], 'AC-19 (i): no *.tmp leftovers');
    is_deeply([ grep { /^pnpm-workspace\.yaml\..+/ } @$tree ], [], 'AC-19 (i): no pnpm-workspace.yaml.* temp file survived');
    is_deeply([ grep { /^\.gitignore\..+/ } @$tree ], [], 'AC-19 (i): no .gitignore.* temp file survived');
    is_deeply([ grep { /^\.bp-fast-store\.tmp\./ } @$tree ], [], 'AC-19 (i): no stray .bp-fast-store.tmp.* file survived');
    is_deeply([ grep { /lock/i } @$tree ], [], 'AC-19 (i): no lockfile created');

    ok(defined $REPO_GI_BEFORE, 'AC-19 (ii): the repo .gitignore was readable at file start')
        or diag("could not read $REPO_GI");
    is(slurp_raw($REPO_GI), $REPO_GI_BEFORE,
       'AC-19 (ii): /project/.gitignore is byte-identical after the entire test run');

    # (iii) nothing outside $ROOT: the paths a runaway default or an ambient
    # BP_PROJECT_ROOT would have created are in exactly the state they were in
    # before this file started.
    my @appeared = grep { !$CANARY_BEFORE{$_} && -e $_ } @CANARIES;
    is_deeply(\@appeared, [], 'AC-19 (iii): no path outside $ROOT was created by any invocation');
    ok(!-e "$CHILD_CWD/pnpm-workspace.yaml",
       'AC-19 (iii): the scratch cwd gained no pnpm-workspace.yaml (no run silently defaulted to its own cwd)');

    done_testing();
};

# --- AC-21 (whole-file exit-code audit; must run last) ----------------------
subtest 'AC-21 exit codes are a subset of {0,2,3,5,6}; never 4' => sub {
    my %allowed = map { $_ => 1 } (0, 2, 3, 5, 6);
    my @seen    = sort { $a <=> $b } keys %SEEN_EXIT;
    diag("observed exit codes: " . join(',', @seen)) if grep { !$allowed{$_} } @seen;
    is_deeply([ grep { !$allowed{$_} } @seen ], [],
              'AC-21: every exit code observed in this file is one of 0,2,3,5,6');
    ok(!exists $SEEN_EXIT{4}, 'AC-21: exit code 4 (bp_require_sandbox) is never emitted');
    cmp_ok(scalar @seen, '>=', 4,
           'AC-21: the audit is not vacuous (several distinct exit codes were actually exercised)');

    done_testing();
};

}   # end SKIP: bash-dependent subtests

# ===========================================================================
# Source-text and documentation criteria (no shell required).
# ===========================================================================

# --- AC-23 ------------------------------------------------------------------
subtest 'AC-23 source honours house rules (/dev/null, no rsync/jq/git/dirname)' => sub {
    my $src = slurp($SCRIPT);
    ok(length $src, 'AC-23: the script source is readable');

    # (i) /dev/null, never NUL (C8, the MSYS2 hazard).
    unlike($src, qr/>\s*NUL\b/, 'AC-23 (i): no redirect to NUL');
    my @targets = ($src =~ /[12]?>\s*(\S+)/g);
    is_deeply([ grep { /^NUL$/i } @targets ], [], 'AC-23 (i): no redirect target is NUL in any spelling');
    is_deeply([ grep { /null/i && $_ !~ m{^/dev/null} } @targets ], [],
              'AC-23 (i): every "null" redirect target is /dev/null');

    # (ii) forbidden mechanisms (2.9 / Decision #18).
    for my $tok (qw(rsync podman docker MountSpec jq)) {
        unlike($src, qr/\Q$tok\E/, "AC-23 (ii): the source contains no occurrence of $tok");
    }
    unlike($src, qr/--mount/, 'AC-23 (ii): the source contains no --mount');

    # (iii)+(v) checked on CODE lines only: §2.2's mandated skeleton spells the
    # dirname prohibition out in a comment, and ".gitignore" must never count as
    # a git call.
    my $code = code_lines($src);
    is_deeply([ grep { /(?:^|[\s;(&|`])git\s/ } @$code ], [],
              'AC-23 (iii): no git invocation on any code line');
    is_deeply([ grep { /(?:^|[^\w.\/-])(dirname|basename|realpath)\b/ } @$code ], [],
              'AC-23 (v): no dirname/basename/realpath call on any code line');

    # (iv) shebang + strict mode.
    is((split /\n/, $src)[0], '#!/usr/bin/env bash', 'AC-23 (iv): shebang is #!/usr/bin/env bash');
    like($src, qr/^set -euo pipefail$/m, 'AC-23 (iv): set -euo pipefail is present');

    done_testing();
};

# --- SKILL.md helpers -------------------------------------------------------
my $SKILL_SRC = slurp($SKILL);

# Every `## ` heading, in file order (a `### ` subheading is not a section).
sub skill_headings {
    my ($t) = @_;
    return [ grep { /^##[^#]/ } split /\n/, (defined $t ? $t : '') ];
}
# The body of the one new section: from its `## ` heading to the next `## `.
sub native_section {
    my ($t) = @_;
    my @l = split /\n/, (defined $t ? $t : ''), -1;
    my ($start, $end);
    for my $i (0 .. $#l) {
        if (!defined $start) { $start = $i if $l[$i] =~ /^##[^#]/ && $l[$i] =~ /native storage/i; next }
        if ($l[$i] =~ /^##[^#]/) { $end = $i - 1; last }
    }
    return '' unless defined $start;
    $end = $#l unless defined $end;
    return join("\n", @l[$start .. $end]);
}

# --- AC-25 ------------------------------------------------------------------
subtest 'AC-25 SKILL.md documents the native-storage pattern' => sub {
    ok(length $SKILL_SRC, 'AC-25: coordinator-protocol/SKILL.md is readable') or diag("missing $SKILL");
    my @native = grep { /native storage/i } @{ skill_headings($SKILL_SRC) };
    is(scalar @native, 1, 'AC-25: exactly one ## heading matches /native storage/i')
        or diag(join(' | ', @native));

    my $body = native_section($SKILL_SRC);
    ok(length $body, 'AC-25: the new section has a body');
    like($body, qr/\bstore-dir\b/,          'AC-25: the section mentions store-dir');
    like($body, qr/\bvirtual-store-dir\b/,  'AC-25: the section mentions virtual-store-dir');
    like($body, qr/\.npmrc/,                'AC-25: the section mentions .npmrc');
    like($body, qr/bp-fast-store\.sh/,      'AC-25: the section names bp-fast-store.sh');
    like($body, qr{/backpack:add},          'AC-25: the section names the /backpack:add item');
    like($body, qr/node_modules/,           'AC-25: the section mentions node_modules');
    like($body, qr/9p|bind mount/i,         'AC-25: the section explains the 9p / bind-mount cost');

    done_testing();
};

# --- AC-26 ------------------------------------------------------------------
subtest 'AC-26 SKILL.md documents validate-from-native-store and supersedes rsync' => sub {
    my $body = native_section($SKILL_SRC);
    ok(length $body, 'AC-26: the new section has a body');
    like($body, qr/validate/i,     'AC-26: the section talks about validating');
    like($body, qr/native store/i, 'AC-26: ... from the native store');

    my @paras = grep { /rsync/ } split /\n\s*\n/, $body;
    ok(scalar @paras, 'AC-26: the section mentions rsync');
    ok((grep { /supersed|retired|no longer|do not/i } @paras),
       'AC-26: rsync is named in a statement that supersedes/retires/forbids it')
        or diag(join("\n---\n", @paras));
    like($body, qr/bind volume|MountSpec/i, 'AC-26: bind volumes / MountSpec are explicitly rejected');

    done_testing();
};

# --- AC-27 ------------------------------------------------------------------
subtest 'AC-27 SKILL.md section placement and section-order non-regression' => sub {
    my $h = skill_headings($SKILL_SRC);
    # RETARGETED 2026-08-04. This pinned the file at EXACTLY 12 '## ' headings,
    # which forbade every later package from adding a top-level section to a
    # SHARED protocol document. It did not stay theoretical: b14 and b20 both
    # hit it and demoted their sections to '###' to route around it — a test
    # dictating document structure it has no stake in.
    #
    # Nothing below needs a total. The real content of AC-27 is that the new
    # section EXISTS, sits between two named neighbours, and that the
    # pre-existing sections are still present in their original relative order.
    # All three survive extension; the count did not.
    cmp_ok(scalar @$h, '>=', 12,
        'AC-27: the pre-existing sections plus this package\'s insertion are present (a FLOOR — later packages may add more)')
        or diag(join("\n", @$h));

    my ($i_native, $i_disk, $i_dep) = (-1, -1, -1);
    for my $i (0 .. $#$h) {
        $i_native = $i if $h->[$i] =~ /native storage/i;
        $i_disk   = $i if $h->[$i] =~ /disk is truth/i;
        $i_dep    = $i if $h->[$i] =~ /dependency .*version policy/i;
    }
    cmp_ok($i_disk,   '>=', 0, 'AC-27: ## Disk is truth is still present');
    cmp_ok($i_dep,    '>=', 0, 'AC-27: ## Dependency & version policy is still present');
    cmp_ok($i_native, '>',  $i_disk, 'AC-27: the new section comes AFTER ## Disk is truth');
    cmp_ok($i_native, '<',  $i_dep,  'AC-27: the new section comes BEFORE ## Dependency & version policy');

    # The 11 pre-existing sections, in their spec-recorded order (spec 1.3).
    my @expect = (qr/environment contract/i, qr/ledger discipline/i, qr/context economics/i,
                  qr/disk is truth/i, qr/dependency .*version policy/i, qr/mandated means/i,
                  qr/pipeline/i, qr/worker dispatch/i, qr/resumption/i, qr/terminal ritual/i,
                  qr/graceful stop/i);
    my @rest = grep { !/native storage/i } @$h;
    # Matched as an ordered SUBSEQUENCE rather than by exact index. The old form
    # compared @rest[0..10] positionally, so inserting any new section ANYWHERE
    # before the last one shifted every index and failed — the same
    # forbid-all-extension problem as the count above, just less obvious.
    # A subsequence check still catches a heading that is removed, renamed, or
    # reordered, which is everything this assertion was actually protecting.
    my @missing;
    my $cursor = 0;
    for my $re (@expect) {
        my $found = -1;
        for my $i ($cursor .. $#rest) {
            if ($rest[$i] =~ $re) { $found = $i; last }
        }
        if ($found < 0) { push @missing, "$re (absent, or out of order after index $cursor)" }
        else            { $cursor = $found + 1 }
    }
    is_deeply(\@missing, [],
        'AC-27: the pre-existing headings are all still present, in their original relative order');

    done_testing();
};

# --- AC-28 ------------------------------------------------------------------
subtest 'AC-28 SKILL.md documents the non-pnpm equivalent and rebuild semantics' => sub {
    my $body = native_section($SKILL_SRC);
    ok(length $body, 'AC-28: the new section has a body');

    my @knobs = grep { $body =~ /\Q$_\E/ }
                ('CARGO_HOME', 'CARGO_TARGET_DIR', 'PIP_CACHE_DIR', 'PUB_CACHE',
                 'GRADLE_USER_HOME', 'npm config set cache', 'cacheFolder');
    cmp_ok(scalar @knobs, '>=', 2, 'AC-28: at least two non-pnpm toolchain knobs are named')
        or diag("knobs found: " . join(',', @knobs));

    like($body, qr/cache|store/i,   'AC-28: the generic rule is about the tool cache/store');
    like($body, qr/native/i,        'AC-28: ... placed on native storage');
    like($body, qr/backpack/i,      'AC-28: ... plus a backpack item');
    like($body, qr/reinstall|re-install|re-materializ/i, 'AC-28: ... that reinstalls on rebuild');

    like($body, qr/wiped/i,   'AC-28: states the native dirs are wiped');
    like($body, qr/rebuild/i, 'AC-28: ... on container rebuild');
    ok((grep { /bind mount/i && /source|ledger/i } split /\n/, $body),
       'AC-28: states that source/ledgers stay on the durable bind mount');
    ok((grep { /\.npmrc/ && /never commit/i } split /\n/, $body),
       'AC-28: states that .npmrc must never be committed');

    done_testing();
};

# ===========================================================================
# AC-30..32 — regression criteria added by the COORDINATOR at step 7 (fix-batch),
# pinning three defects that the review + red-team found and that I reproduced
# independently before accepting. They are NOT in the spec's §4.1 list; they are
# review findings promoted to permanent oracle so they cannot silently return.
# ===========================================================================

subtest 'AC-30 an empty flag value is not treated as an absent flag' => sub {
    # REVIEWER BLOCKER (bp-fast-store.sh:157): `[ -z "$PROJECT_IN" ]` conflated
    # "flag absent" with "flag given empty", so `--project ''` fell back to $PWD
    # and configured the CALLER'S CWD, exit 0. Run from /project (as a coordinator
    # would) that writes /project/pnpm-workspace.yaml + /project/.gitignore — an
    # edit outside this package's write set, and exactly what spec 3.7 exists to
    # prevent.
    my $victim = mk_proj('victim');
    my ($rc, $out, $err) = run_fs(args => ['--project', ''], cwd => $victim);
    is($rc, 6, 'AC-30: --project "" exits 6 (the -d check runs on the given value)')
        or diag($err);
    is($out, '', 'AC-30: nothing is emitted on stdout');
    ok(!-e "$victim/pnpm-workspace.yaml", 'AC-30: the caller cwd did NOT get a pnpm-workspace.yaml');
    ok(!-e "$victim/.gitignore",'AC-30: the caller cwd did NOT get a .gitignore');

    # Same conflation on the native-path flags: an empty value there silently put
    # the store back on the slow bind mount, defeating the package's whole point.
    for my $flag (qw(--native-root --store --virtual-store)) {
        my $p = mk_proj('emptyflag');
        my ($r, $o2, $e2) = run_fs(args => ['--project', $p, $flag, '']);
        is($r, 2, "AC-30: $flag '' is a usage error (exit 2)") or diag($e2);
        is($o2, '', "AC-30: $flag '' emits nothing on stdout");
        ok(!-e "$p/pnpm-workspace.yaml", "AC-30: $flag '' wrote no pnpm-workspace.yaml");
    }
    done_testing();
};

subtest 'AC-31 write_atomic preserves the destination file mode' => sub {
    # REVIEWER MAJOR (bp-fast-store.sh:99-111): mv carried the temp file's umask
    # mode onto the destination, so a 0600 pnpm-workspace.yaml became 0644. This
    # would world-readable a project file that (per SYN-27) legitimately embeds
    # container-specific /root/... paths on every run.
    my $p = mk_proj('mode');
    spit("$p/pnpm-workspace.yaml", "packages:\n  - 'SECRET-package-name'\n");
    chmod 0600, "$p/pnpm-workspace.yaml" or die "chmod: $!";
    spit("$p/.gitignore", "*.log\n");
    chmod 0640, "$p/.gitignore" or die "chmod: $!";

    my ($rc, $out, $err) = run_fs(args => ['--project', $p, '--native-root', mk_native()]);
    is($rc, 0, 'AC-31: the run succeeds') or diag($err);
    is((stat("$p/pnpm-workspace.yaml"))[2] & 07777, 0600,
       'AC-31: a 0600 pnpm-workspace.yaml is still 0600 after the rewrite (not world-readable)');
    is((stat("$p/.gitignore"))[2] & 07777, 0640,
       'AC-31: a 0640 .gitignore keeps its mode');
    like(slurp("$p/pnpm-workspace.yaml"), qr/SECRET-package-name/, 'AC-31: the preserved content is still there');
    unlike($out, qr/SECRET/, 'AC-31: the sensitive content never reaches stdout');
    unlike($err, qr/SECRET/, 'AC-31: the sensitive content never reaches stderr');
    done_testing();
};

subtest 'AC-32 a config path that is a directory fails loudly, not silently' => sub {
    # RED-TEAM MEDIUM-1 (bp-fast-store.sh:106, write_atomic): when the config
    # path already existed as a DIRECTORY, `mv -f` moved the temp file INTO it
    # and returned 0, so the script exited 0 and printed the backpack line while
    # pnpm was left completely unconfigured — a silent no-op, plus a stray temp
    # file. Spec 2.8 / 3.1 require exit 6 on a failed write.
    for my $victim (qw(pnpm-workspace.yaml .gitignore)) {
        my $p = mk_proj('isdir');
        make_path("$p/$victim");
        my ($rc, $out, $err) = run_fs(args => ['--project', $p, '--native-root', mk_native()]);
        is($rc, 6, "AC-32: $victim as a directory exits 6") or diag($err);
        is($out, '', "AC-32: no backpack line is emitted when $victim could not be written");
        ok(-d "$p/$victim", "AC-32: $victim is still the directory it was");
        my @stray = grep { /^\.bp-fast-store\.tmp\./ } do {
            opendir(my $dh, "$p/$victim") or die $!; my @e = readdir($dh); closedir($dh); @e
        };
        is(scalar(@stray), 0, "AC-32: no stray temp file was left inside $victim/");
    }
    done_testing();
};

done_testing();
