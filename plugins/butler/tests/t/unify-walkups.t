# platform: any
#
# Verifies every .ccpraxis-local-data walk-up in the write set uses
# BpDataRoot.pm's bounded rules (never ascend out of temp; never adopt home
# unless the start IS home). Spec: specs/03-unify-walkups-spec.md. Ledger:
# packages/03-unify-walkups.md. Governs Decision 3 and Decision 20 (public
# BpDataRoot::walkup/ancestors; the adapter is BpProjectRoot::bounded_walkup
# and BpProjectRoot::bounded_ancestors — the ONLY names this file calls
# directly; the underscore functions are never referenced from here).
#
# Fixture: a fake TMP nested under a fake HOME, both under one tempdir $R,
# never the real HOME/TMP or the repo's own .ccpraxis-local-data (spec §4.0).
# Every probe runs in a FRESH SUBPROCESS with a scrubbed+rebuilt environment,
# so no assertion here can pass by inheriting this process's real ambient
# state. Every `require`/`use` inside a probe is wrapped in `eval` so a
# missing file (BpDataRoot.pm gaining public functions, bp-data-root.pl not
# existing yet) reports as a not-ok assertion, never a BAIL_OUT or a died
# test file.

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Cwd ();
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use JSON::PP ();
use Encode ();
use File::Find ();

sub slashify { my ($p) = @_; return undef unless defined $p; (my $s = $p) =~ s{\\}{/}g; return $s; }

my $SCRIPTS      = slashify(Cwd::abs_path("$Bin/../../scripts"));
my $ALM_SCRIPTS  = slashify(Cwd::abs_path("$Bin/../../../almanac/scripts"));
my $BP_SCRIPTS   = slashify(Cwd::abs_path("$Bin/../../../blueprint/scripts"));

my $PROJECTROOT_PM = "$SCRIPTS/BpProjectRoot.pm";
my $DATAROOT_PM    = "$SCRIPTS/BpDataRoot.pm";
my $FEEDBACK_PL    = "$SCRIPTS/bp-feedback.pl";
my $CHECKPOINT_PL  = "$SCRIPTS/bp-checkpoint.pl";
my $CACHE_PL       = "$SCRIPTS/bp-cache-state.pl";
my $PROGRESS_PL    = "$SCRIPTS/bp-progress.pl";
my $ORCH_PL        = "$SCRIPTS/bp-orchestrator.pl";
my $SPEND_PL       = "$SCRIPTS/bp-spend.pl";
my $SESSION_PM     = "$SCRIPTS/BpSession.pm";
my $DISPATCHLOG_PL = "$SCRIPTS/bp-dispatch-log.pl";
my $DATA_ROOT_PL   = "$SCRIPTS/bp-data-root.pl";
my $BUTLER_LIB     = "$SCRIPTS/bp-lib.sh";
my $BLUEPRINT_LIB  = "$BP_SCRIPTS/bp-lib.sh";

ok(-f $PROJECTROOT_PM, 'sanity: BpProjectRoot.pm exists') or BAIL_OUT('fixture: BpProjectRoot.pm missing');

# ---------------------------------------------------------------------------
# §4.0 fixture
# ---------------------------------------------------------------------------

my $R = slashify(Cwd::abs_path(tempdir(CLEANUP => 1)));
make_path("$R/.ccpraxis-local-data/claude-home/projects");   # escape sentinel

my $H = "$R/home";
make_path("$H/.ccpraxis-local-data/claude-home/projects");

my $T = "$H/AppData/Local/Temp";                              # T holds NO marker
make_path($T);

my $C1  = "$T/probe/deep";   make_path($C1);
my $C1h = "$H/noproj/deep";  make_path($C1h);

my $P = "$T/proj";
make_path("$P/.ccpraxis-local-data/claude-home/projects", "$P/src/deep");
my $C2 = "$P/src/deep";

my $Q = "$H/proj2";
make_path("$Q/.ccpraxis-local-data", "$Q/sub");
my $CQ = "$Q/sub";

my $B1  = "$T/probe/blueprints/bp";        make_path($B1);
my $B1h = "$H/noproj/blueprints/bp";       make_path($B1h);
my $B2  = "$P/.ccpraxis-local-data/blueprints/bp"; make_path($B2);

make_path("$R/cpd", "$R/envproj", "$R/envdata/claude-home/projects", "$R/argdata", "$R/explicit");
make_path("$R/sessions");

sub write_session {
    my ($name, $cwd) = @_;
    my $f = "$R/sessions/$name.jsonl";
    open(my $fh, '>', $f) or die "write $f: $!";
    print $fh qq({"type":"permission-mode","cwd":"$cwd","sessionId":"x"}\n);
    close $fh;
    return $f;
}
my $S1  = write_session('s1',  $C1);
my $S1h = write_session('s1h', $C1h);
my $S2  = write_session('s2',  $C2);

# ---------------------------------------------------------------------------
# Subprocess plumbing
# ---------------------------------------------------------------------------

sub slurp_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined($c) ? $c : '';
}

# Redirect-to-raw-file, never a pipe (IPC::Open3 pipes were measured to mangle
# non-ASCII argv/output bytes on this host -- the fixture root sits under the
# real user's home, which contains "André" -- whereas the reopened-filehandle
# pattern below, lifted from director-args-and-root.t's run_script, is
# already proven byte-safe here).
sub _run_capture_impl {
    my (@cmd) = @_;
    my ($ofh, $opath) = tempfile('uwt-outXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $epath) = tempfile('uwt-errXXXXXX', TMPDIR => 1); close $efh;
    open(my $oldout, '>&', \*STDOUT) or die "dup STDOUT: $!";
    open(my $olderr, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDOUT, '>:raw', $opath) or do { open(STDOUT, '>&', $oldout); die "redirect STDOUT: $!" };
    open(STDERR, '>:raw', $epath) or do { open(STDERR, '>&', $olderr); die "redirect STDERR: $!" };
    my $sysrc = system(@cmd);
    open(STDOUT, '>&', $oldout) or die "restore STDOUT: $!"; close $oldout;
    open(STDERR, '>&', $olderr) or die "restore STDERR: $!"; close $olderr;
    my $out = slurp_raw($opath);
    my $err = slurp_raw($epath);
    unlink $opath, $epath;
    my $rc = ($sysrc == -1) ? -1 : ($sysrc >> 8);
    return ($rc, $out, $err);
}

my @SCRUB = qw(CLAUDE_PROJECT_DIR BP_PROJECT_ROOT CCPRAXIS_DATA_DIR CLAUDE_CONFIG_DIR ALMANAC_HOME GIT_DIR GIT_WORK_TREE);

# run_capture_in($dir, \%env_over, @cmd) -> ($rc, $stdout, $stderr)
#
# Builds the §4.0 base environment (HOME/USERPROFILE=$H, TMP/TEMP/TMPDIR=$T,
# GIT_CEILING_DIRECTORIES=$R) after scrubbing @SCRUB, then applies
# %env_over on top (a key mapped to undef deletes it; "a case adds only the
# variables it names" is satisfied because every case starts from the same
# base, never from a blank slate).
sub run_capture_in {
    my ($dir, $envover, @cmd) = @_;
    $envover ||= {};
    my $old = Cwd::getcwd();
    chdir $dir or die "chdir $dir: $!";
    local %ENV = %ENV;
    delete @ENV{@SCRUB};
    $ENV{HOME}        = $H;
    $ENV{USERPROFILE} = $H;
    $ENV{TMP}         = $T;
    $ENV{TEMP}        = $T;
    $ENV{TMPDIR}      = $T;
    $ENV{GIT_CEILING_DIRECTORIES} = $R;
    for my $k (keys %$envover) {
        if (defined $envover->{$k}) { $ENV{$k} = $envover->{$k} }
        else                        { delete $ENV{$k} }
    }
    my @r = eval { _run_capture_impl(@cmd) };
    my $caught = $@;
    chdir $old;
    die $caught if $caught;
    return @r;
}

sub trimmed { my ($s) = @_; $s = '' unless defined $s; $s =~ s/\s+\z//; return $s; }

# ---------------------------------------------------------------------------
# Probes (spec §4.0 probe table)
# ---------------------------------------------------------------------------

sub probe_bpr {
    my ($dir, $env) = @_;
    my $code = qq{
        my \$r = eval { require "$PROJECTROOT_PM"; BpProjectRoot::resolve() };
        print \$@ ? "ERR:\$@" : (defined(\$r) ? \$r : "UNDEF");
    };
    my ($rc, $out, $err) = run_capture_in($dir, $env, $^X, '-e', $code);
    return trimmed($out);
}

sub probe_dlog {
    my ($dir, $env, $arg) = @_;
    my $arg_lit = defined $arg ? qq{"$arg"} : 'undef';
    my $code = qq{
        my \$r = eval {
            require "$PROJECTROOT_PM" unless grep { m{BpProjectRoot\\.pm\$} } keys \%INC;
            require "$DISPATCHLOG_PL";
            BpDispatchLog::log_dir($arg_lit);
        };
        print \$@ ? "ERR:\$@" : (defined(\$r) ? \$r : "UNDEF");
    };
    my ($rc, $out, $err) = run_capture_in($dir, $env, $^X, '-e', $code);
    return trimmed($out);
}

sub probe_fb {
    my ($dir, $env, @args) = @_;
    return run_capture_in($dir, $env, $^X, $FEEDBACK_PL, @args);
}

sub probe_ckpt {
    my ($dir, $env, $hint) = @_;
    my $hint_lit = defined $hint ? qq{"$hint"} : 'undef';
    my $code = qq{
        my \$r = eval { require "$CHECKPOINT_PL"; BpCheckpoint::resolve_root($hint_lit) };
        print \$@ ? "ERR:\$@" : (defined(\$r) ? \$r : "UNDEF");
    };
    my ($rc, $out, $err) = run_capture_in($dir, $env, $^X, '-e', $code);
    return trimmed($out);
}

sub probe_orch {
    my ($bpdir, $env) = @_;
    my $code = qq{
        require "$ORCH_PL";
        my \$p = eval { BpOrch::_project_root_of("$bpdir") };
        my \$e1 = \$@;
        my \$l = eval { BpOrch::lifecycle_data_dir("$bpdir") };
        my \$e2 = \$@;
        print( (defined(\$p) ? \$p : "UNDEF"), "\\n", (defined(\$l) ? \$l : "UNDEF"), "\\n");
        print STDERR "\$e1|\$e2" if \$e1 || \$e2;
    };
    my ($rc, $out, $err) = run_capture_in($R, $env, $^X, '-e', $code);
    my @lines = split /\n/, $out;
    return (trimmed($lines[0]), trimmed($lines[1]));
}

sub probe_cache {
    my ($dir, $env) = @_;
    my $code = qq{
        require "$CACHE_PL";
        my \$p = eval { BpCacheState::_project_root() };
        my \$d = eval { BpCacheState::_data_dir() };
        print( (defined(\$p) ? \$p : "UNDEF"), "\\n", (defined(\$d) ? \$d : "UNDEF"), "\\n");
    };
    my ($rc, $out, $err) = run_capture_in($dir, $env, $^X, '-e', $code);
    my @lines = split /\n/, $out;
    return (trimmed($lines[0]), trimmed($lines[1]));
}

sub probe_prog {
    my ($dir, $env) = @_;
    my $code = qq{
        require "$PROGRESS_PL";
        my \$p = eval { BpProgress::_project_root() };
        my \$d = eval { BpProgress::_data_dir() };
        print( (defined(\$p) ? \$p : "UNDEF"), "\\n", (defined(\$d) ? \$d : "UNDEF"), "\\n");
    };
    my ($rc, $out, $err) = run_capture_in($dir, $env, $^X, '-e', $code);
    my @lines = split /\n/, $out;
    return (trimmed($lines[0]), trimmed($lines[1]));
}

sub probe_sess {
    my ($dir, $env, $override) = @_;
    my $ovr_lit = defined $override ? qq{"$override"} : 'undef';
    my $code = qq{
        require "$SESSION_PM";
        my \@r = eval { BpSession::transcript_roots($ovr_lit) };
        print join("\\n", \@r), "\\n";
    };
    my ($rc, $out, $err) = run_capture_in($dir, $env, $^X, '-e', $code);
    my @lines = grep { length } split /\n/, $out;
    return @lines;
}

sub probe_spend {
    my ($env, $session, $explicit) = @_;
    my $explicit_lit = defined $explicit ? qq{"$explicit"} : 'undef';
    my $session_lit  = defined $session  ? qq{"$session"}  : 'undef';
    my $code = qq{
        require "$SPEND_PL";
        my (\$r, \$s) = eval { BpSpend::Derive::resolve_data_root($explicit_lit, $session_lit) };
        print \$@ ? "ERR:\$@" : ( (defined(\$r) ? \$r : "UNDEF"), "\\n", (defined(\$s) ? \$s : "UNDEF"), "\\n" );
    };
    my ($rc, $out, $err) = run_capture_in($R, $env, $^X, '-e', $code);
    my @lines = split /\n/, $out;
    return (trimmed($lines[0]), trimmed($lines[1]));
}

sub probe_store {
    my ($dir, $env, %opt) = @_;
    my $cwd_lit = defined $opt{cwd} ? qq{"$opt{cwd}"} : qq{"$dir"};
    my $extra   = $opt{extra} // '';
    my $code = qq{
        use lib "$ALM_SCRIPTS";
        my \$r = eval { require Almanac::Store; Almanac::Store::resolve_project_root(cwd => $cwd_lit $extra) };
        print \$@ ? "ERR:\$@" : (defined(\$r) ? \$r : "UNDEF");
    };
    my ($rc, $out, $err) = run_capture_in($dir, $env, $^X, '-e', $code);
    return trimmed($out);
}

sub probe_store_scope_capability {
    my ($dir, $env, $root) = @_;
    my $code = qq{
        use lib "$ALM_SCRIPTS";
        my \$r = eval { require Almanac::Store; Almanac::Store::scope_capability('project', root => "$root", surface => 'host') };
        print \$@ ? "ERR:\$@" : (ref(\$r) eq 'HASH' && defined(\$r->{root}) ? \$r->{root} : "UNDEF");
    };
    my ($rc, $out, $err) = run_capture_in($dir, $env, $^X, '-e', $code);
    return trimmed($out);
}

sub probe_store_bounded_walk {
    my ($dir, $env, $start) = @_;
    my $code = qq{
        use lib "$ALM_SCRIPTS";
        my \$r = eval { require Almanac::Store; Almanac::Store::_bounded_walk("$start") };
        print \$@ ? "ERR:\$@" : (defined(\$r) ? \$r : "UNDEF");
    };
    my ($rc, $out, $err) = run_capture_in($dir, $env, $^X, '-e', $code);
    return trimmed($out);
}

sub probe_help {
    my ($dir, $env, @args) = @_;
    return run_capture_in($dir, $env, $^X, $DATA_ROOT_PL, @args);
}

sub probe_lib {
    my ($which, $dir, $env) = @_;
    my $lib = $which eq 'butler' ? $BUTLER_LIB : $BLUEPRINT_LIB;
    return run_capture_in($dir, $env, 'bash', '-c',
        'source "$1"; cd "$2" || exit 9; bp_project_root; bp_data_dir', '_', $lib, $dir);
}

sub probe_lib_at {
    my ($lib, $dir, $env) = @_;
    return run_capture_in($dir, $env, 'bash', '-c',
        'source "$1"; cd "$2" || exit 9; bp_project_root; bp_data_dir', '_', $lib, $dir);
}

# ---------------------------------------------------------------------------
# Git precondition (spec §4.0): each start used for AC1/AC2/AC4 rows must make
# `git -C <start> rev-parse --show-toplevel` fail under the §4.0 env, or the
# row SKIPs and names the reason. Computed once per start.
# ---------------------------------------------------------------------------

sub git_fails_in {
    my ($dir) = @_;
    my ($rc, $out, $err) = run_capture_in($dir, {}, 'git', '-C', $dir, 'rev-parse', '--show-toplevel');
    return $rc != 0;
}

my $GIT_VERSION_OK = do {
    my ($rc, $out, $err) = _run_capture_impl('git', '--version');
    $rc == 0;
};

my %GIT_PRECOND = map { $_ => git_fails_in($_) } ($C1, $C1h, $C2);

# ---------------------------------------------------------------------------
# "Not adopted" (spec §4.0): the result must not be same_path to, and have no
# path-prefix of, $H, $H/.ccpraxis-local-data, $R or $R/.ccpraxis-local-data.
# Path comparison uses BpDataRoot::same_path, loaded once here (in-process;
# never in a probe subprocess).
# ---------------------------------------------------------------------------

my $BPDATAROOT_LOADS = eval { require $DATAROOT_PM; 1 };
diag("BpDataRoot.pm failed to load: $@") unless $BPDATAROOT_LOADS;

sub same_path {
    my ($a, $b) = @_;
    return 0 unless $BPDATAROOT_LOADS;
    return eval { BpDataRoot::same_path($a, $b) } ? 1 : 0;
}

sub is_prefix_of {
    my ($prefix, $path) = @_;
    return 0 unless defined $prefix && defined $path && length $prefix && length $path;
    my $p = lc(slashify($prefix));
    my $q = lc(slashify($path));
    $p =~ s{/\z}{};
    return 1 if $q eq $p;
    return 1 if index($q, "$p/") == 0;
    return 0;
}

sub is_same_path {
    my ($got, $want, $desc) = @_;
    ok(defined $got && length $got && $got ne 'UNDEF' && same_path($got, $want),
        "$desc (same_path to " . (defined $want ? $want : 'UNDEF') . ", got " . (defined $got ? $got : 'undef') . ")");
}

sub not_adopted {
    my ($val) = @_;
    return 0 unless defined $val && length $val && $val ne 'UNDEF';
    for my $bad ($H, "$H/.ccpraxis-local-data", $R, "$R/.ccpraxis-local-data") {
        return 0 if same_path($val, $bad);
        return 0 if is_prefix_of($bad, $val);
    }
    return 1;
}

# ===========================================================================
# AC1 (DC1) / AC6 (Windows re-run) — no adoption from a temp or a home start
# ===========================================================================

sub run_ac1_family {
    my ($label) = @_;

    SKIP: {
        skip "git precondition fails: git can see a real repo from $C1", 1 unless $GIT_PRECOND{$C1};
        is(probe_bpr($C1, {}), $C1, "$label AC1: BPR from C1 gives the start (not adopted)");
    }
    SKIP: {
        skip "git precondition fails from $C1h", 1 unless $GIT_PRECOND{$C1h};
        is(probe_bpr($C1h, {}), $C1h, "$label AC1: BPR from C1h gives the start (not adopted)");
    }

    is(probe_dlog($C1, {}, undef), "$C1/.ccpraxis-local-data/.dispatch-log", "$label AC1: DLOG from C1");
    is(probe_dlog($C1h, {}, undef), "$C1h/.ccpraxis-local-data/.dispatch-log", "$label AC1: DLOG from C1h");

    {
        my ($rc, $out, $err) = probe_fb($C1, {}, '--', 'probe-text');
        is($rc, 4, "$label AC1: FB from C1 exits 4");
        like($err, qr/\[cannot locate <data>\]/, "$label AC1: FB stderr names cannot-locate");
        is($out, '', "$label AC1: FB stdout empty");
    }

    SKIP: {
        skip "git precondition fails from $C1", 1 unless $GIT_PRECOND{$C1};
        is(probe_ckpt($C1, {}, undef), $C1, "$label AC1: CKPT from C1 gives the start");
    }

    {
        my ($proot, $ldd) = probe_orch($B1, {});
        is($proot, 'UNDEF', "$label AC1: ORCH _project_root_of(B1) is undef");
        is($ldd, 'UNDEF', "$label AC1: ORCH lifecycle_data_dir(B1) is undef");
    }
    {
        my ($proot, $ldd) = probe_orch($B1h, {});
        is($proot, 'UNDEF', "$label AC1: ORCH _project_root_of(B1h) is undef");
    }

    SKIP: {
        skip "git precondition fails from $C1", 2 unless $GIT_PRECOND{$C1};
        my ($proot, $d) = probe_cache($C1, {});
        is($proot, $C1, "$label AC1: CACHE _project_root from C1");
        is($d, "$C1/.ccpraxis-local-data", "$label AC1: CACHE _data_dir from C1");
    }
    SKIP: {
        skip "git precondition fails from $C1", 2 unless $GIT_PRECOND{$C1};
        my ($proot, $d) = probe_prog($C1, {});
        is($proot, $C1, "$label AC1: PROG _project_root from C1");
        is($d, "$C1/.ccpraxis-local-data", "$label AC1: PROG _data_dir from C1");
    }

    {
        my @roots = probe_sess($C1, {});
        ok(!(grep { same_path($_, "$H/.ccpraxis-local-data/claude-home/projects") } @roots),
            "$label AC1: SESS from C1 never contains H's projects dir");
        ok(!(grep { same_path($_, "$R/.ccpraxis-local-data/claude-home/projects") } @roots),
            "$label AC1: SESS from C1 never contains R's projects dir");
    }

    {
        my ($root, $src) = probe_spend({ CLAUDE_PROJECT_DIR => "$R/cpd" }, $S1, undef);
        is($root, "$R/cpd/.ccpraxis-local-data", "$label AC1: SPEND with CLAUDE_PROJECT_DIR gives cpd data dir");
        is($src, 'CLAUDE_PROJECT_DIR', "$label AC1: SPEND source is CLAUDE_PROJECT_DIR");
    }
    {
        my ($root, $src) = probe_spend({}, $S1, undef);
        isnt($src, 'session-cwd', "$label AC1: SPEND without CLAUDE_PROJECT_DIR never reports session-cwd for a no-project start");
    }

    SKIP: {
        skip "git precondition fails from $C1", 1 unless $GIT_PRECOND{$C1};
        is(probe_store($C1, {}), $C1, "$label AC1: STORE from C1 gives the start");
    }
    SKIP: {
        skip "git precondition fails from $C1h", 1 unless $GIT_PRECOND{$C1h};
        is(probe_store($C1h, {}), $C1h, "$label AC1: STORE from C1h gives the start");
    }

    {
        my ($rc, $out, $err) = probe_help($C1, {}, '--cwd', $C1);
        is($rc, 1, "$label AC1: HELP from C1 exits 1");
        is($out, '', "$label AC1: HELP stdout empty on exit 1");
        is($err, '', "$label AC1: HELP stderr empty on exit 1");
    }

    SKIP: {
        skip "git precondition fails from $C1", 2 unless $GIT_PRECOND{$C1};
        my ($rc, $out, $err) = probe_lib('butler', $C1, {});
        my @lines = split /\n/, $out;
        is(trimmed($lines[0]), $C1, "$label AC1: LIBB line 1 from C1");
        is(trimmed($lines[1]), "$C1/.ccpraxis-local-data", "$label AC1: LIBB line 2 from C1");
    }
    SKIP: {
        skip "git precondition fails from $C1", 1 unless $GIT_PRECOND{$C1};
        my ($rc, $out, $err) = probe_lib('blueprint', $C1, {});
        my @lines = split /\n/, $out;
        is(trimmed($lines[0]), $C1, "$label AC1: LIBP line 1 from C1");
    }
}

subtest 'AC1: temp/home starts with no project adopt nothing' => sub {
    run_ac1_family('plain');
};

# ===========================================================================
# AC2 (DC2) — a project cwd resolves its own project
# ===========================================================================

subtest 'AC2: a start inside a project resolves that project' => sub {
    is(probe_bpr($C2, {}), $P, 'BPR from C2 gives P');
    is(probe_ckpt($C2, {}, undef), $P, 'CKPT from C2 gives P');
    {
        my ($proot, $d) = probe_cache($C2, {});
        is($proot, $P, 'CACHE _project_root from C2 gives P');
    }
    {
        my ($proot, $d) = probe_prog($C2, {});
        is($proot, $P, 'PROG _project_root from C2 gives P');
    }
    is(probe_store($C2, {}), $P, 'STORE from C2 gives P');
    {
        my ($rc, $out, $err) = probe_help($C2, {}, '--cwd', $C2);
        is($rc, 0, 'HELP from C2 exits 0');
        is(trimmed($out), $P, 'HELP from C2 prints P');
    }
    {
        my ($rc, $out, $err) = probe_lib('butler', $C2, {});
        my @lines = split /\n/, $out;
        is(trimmed($lines[0]), $P, 'LIBB line 1 from C2 gives P');
    }
    {
        my ($rc, $out, $err) = probe_lib('blueprint', $C2, {});
        my @lines = split /\n/, $out;
        is(trimmed($lines[0]), $P, 'LIBP line 1 from C2 gives P');
    }

    is(probe_dlog($C2, {}, undef), "$P/.ccpraxis-local-data/.dispatch-log", 'DLOG from C2');
    {
        my ($proot, $d) = probe_cache($C2, {});
        is($d, "$P/.ccpraxis-local-data", 'CACHE _data_dir from C2');
    }
    {
        my ($proot, $d) = probe_prog($C2, {});
        is($d, "$P/.ccpraxis-local-data", 'PROG _data_dir from C2');
    }

    {
        my ($rc, $out, $err) = probe_fb($C2, {}, '--', 'probe-text');
        is($rc, 0, 'FB from C2 exits 0');
        like($out, qr{^\Q$P\E/\.ccpraxis-local-data/corrections/}, 'FB stdout path is under P/.ccpraxis-local-data/corrections/');
    }

    {
        my ($proot, $ldd) = probe_orch($B2, {});
        is($proot, $P, 'ORCH _project_root_of(B2) gives P');
        is($ldd, "$P/.ccpraxis-local-data", 'ORCH lifecycle_data_dir(B2) gives P data dir');
    }

    {
        my @roots = probe_sess($C2, {});
        ok((grep { same_path($_, "$P/.ccpraxis-local-data/claude-home/projects") } @roots),
            'SESS from C2 contains P/.ccpraxis-local-data/claude-home/projects');
    }

    {
        my ($root, $src) = probe_spend({}, $S2, undef);
        is($root, "$P/.ccpraxis-local-data", 'SPEND from s2 with no CLAUDE_PROJECT_DIR gives P data dir');
        is($src, 'session-cwd', 'SPEND source is session-cwd');
    }

    is(probe_bpr($CQ, {}), $Q, 'BPR from CQ gives Q');
    is(probe_store($CQ, {}), $Q, 'STORE from CQ gives Q');
    {
        my ($rc, $out, $err) = probe_help($CQ, {}, '--cwd', $CQ);
        is(trimmed($out), $Q, 'HELP from CQ gives Q');
    }
    {
        my ($rc, $out, $err) = probe_lib('butler', $CQ, {});
        my @lines = split /\n/, $out;
        is(trimmed($lines[0]), $Q, 'LIBB from CQ gives Q');
    }
};

# ===========================================================================
# AC3 (DC3) — environment overrides keep their priority
# ===========================================================================

subtest 'AC3(a): BPR/DLOG env precedence' => sub {
    is(probe_bpr($C1, { CLAUDE_PROJECT_DIR => "$R/cpd", BP_PROJECT_ROOT => "$R/envproj" }), "$R/cpd",
        'CLAUDE_PROJECT_DIR beats BP_PROJECT_ROOT, byte-equal');
    is(probe_bpr($C1, { BP_PROJECT_ROOT => "$R/envproj" }), "$R/envproj", 'BP_PROJECT_ROOT alone');
    is(probe_bpr($C1, { CLAUDE_PROJECT_DIR => '' }), $C1, 'an empty CLAUDE_PROJECT_DIR counts as unset (walks to the start)')
        if $GIT_PRECOND{$C1};

    is(probe_dlog($C1, { CLAUDE_PROJECT_DIR => "$R/cpd", BP_PROJECT_ROOT => "$R/envproj" }, undef),
        "$R/cpd/.ccpraxis-local-data/.dispatch-log", 'DLOG follows CLAUDE_PROJECT_DIR');
    is(probe_dlog($C1, { BP_PROJECT_ROOT => "$R/envproj" }, undef),
        "$R/envproj/.ccpraxis-local-data/.dispatch-log", 'DLOG follows BP_PROJECT_ROOT');
    is(probe_dlog($C1, {}, "$R/explicit"), "$R/explicit/.ccpraxis-local-data/.dispatch-log",
        'DLOG keeps an explicit root');
};

subtest 'AC3(b): FB env precedence' => sub {
    my ($rc, $out, $err) = probe_fb($C1, { CCPRAXIS_DATA_DIR => "$R/envdata" }, '--', 'probe-text');
    is($rc, 0, 'FB with CCPRAXIS_DATA_DIR exits 0');
    like($out, qr{^\Q$R/envdata\E/corrections/}, 'FB writes under envdata');

    ($rc, $out, $err) = probe_fb($C1, { CCPRAXIS_DATA_DIR => "$R/envdata" }, '--data-dir', "$R/argdata", '--', 'probe-text');
    is($rc, 0, 'FB with --data-dir as well exits 0');
    like($out, qr{^\Q$R/argdata\E/corrections/}, 'FB --data-dir wins over CCPRAXIS_DATA_DIR');

    ($rc, $out, $err) = probe_fb($C1, { BP_PROJECT_ROOT => "$R/envproj", CLAUDE_PROJECT_DIR => "$R/cpd" }, '--', 'probe-text');
    is($rc, 4, 'FB honours neither BP_PROJECT_ROOT nor CLAUDE_PROJECT_DIR: still exits 4 from C1');
};

subtest 'AC3(c): CKPT env precedence' => sub {
    is(probe_ckpt($C1, { BP_PROJECT_ROOT => "$R/envproj" }, "$R/explicit"), "$R/explicit",
        'an explicit hint wins even with BP_PROJECT_ROOT set');
    is(probe_ckpt($C1, { BP_PROJECT_ROOT => "$R/envproj" }, undef), "$R/envproj", 'BP_PROJECT_ROOT alone');
    SKIP: {
        skip "git precondition fails from $C1", 1 unless $GIT_PRECOND{$C1};
        is(probe_ckpt($C1, { CLAUDE_PROJECT_DIR => "$R/cpd" }, undef), $C1,
            'CLAUDE_PROJECT_DIR is not honoured by CKPT: still resolves to the start');
    }
};

subtest 'AC3(d): ORCH ignores every env decoy' => sub {
    my $env = { CLAUDE_PROJECT_DIR => "$R/cpd", BP_PROJECT_ROOT => "$R/envproj", CCPRAXIS_DATA_DIR => "$R/envdata" };
    my ($p1, undef) = probe_orch($B1, $env);
    is($p1, 'UNDEF', 'ORCH from B1 still gives undef with every decoy set');
    my ($p2, undef) = probe_orch($B2, $env);
    is($p2, $P, 'ORCH from B2 still gives P with every decoy set');
};

subtest 'AC3(e): CACHE/PROG env precedence' => sub {
    {
        my ($proot, $d) = probe_cache($C1, { BP_PROJECT_ROOT => "$R/envproj" });
        is($proot, "$R/envproj", 'CACHE _project_root follows BP_PROJECT_ROOT');
        is($d, "$R/envproj/.ccpraxis-local-data", 'CACHE _data_dir follows BP_PROJECT_ROOT');
    }
    {
        my ($proot, $d) = probe_cache($C1, { BP_PROJECT_ROOT => "$R/envproj", CCPRAXIS_DATA_DIR => "$R/envdata" });
        is($d, "$R/envdata", 'CACHE _data_dir follows CCPRAXIS_DATA_DIR over the project root');
    }
    SKIP: {
        skip "git precondition fails from $C1", 1 unless $GIT_PRECOND{$C1};
        my ($proot, undef) = probe_cache($C1, { CLAUDE_PROJECT_DIR => "$R/cpd" });
        is($proot, $C1, 'CACHE does not honour CLAUDE_PROJECT_DIR: still the start');
    }
    {
        my ($proot, $d) = probe_prog($C1, { BP_PROJECT_ROOT => "$R/envproj" });
        is($proot, "$R/envproj", 'PROG _project_root follows BP_PROJECT_ROOT');
    }
};

subtest 'AC3(f): SESS env precedence' => sub {
    my @roots = probe_sess($C1, { CCPRAXIS_DATA_DIR => "$R/envdata" });
    my ($idx_env) = grep { same_path($roots[$_], "$R/envdata/claude-home/projects") } 0 .. $#roots;
    ok(defined $idx_env, 'SESS with CCPRAXIS_DATA_DIR present includes it');

    make_path("$R/argdata/claude-home/projects");
    @roots = probe_sess($C1, { CCPRAXIS_DATA_DIR => "$R/envdata" }, "$R/argdata");
    my ($idx_arg) = grep { same_path($roots[$_], "$R/argdata/claude-home/projects") } 0 .. $#roots;
    my ($idx_env2) = grep { same_path($roots[$_], "$R/envdata/claude-home/projects") } 0 .. $#roots;
    ok(defined $idx_arg && defined $idx_env2 && $idx_arg < $idx_env2,
        'the override root precedes the CCPRAXIS_DATA_DIR root');
};

subtest 'AC3(g): SPEND env precedence' => sub {
    my ($root, $src) = probe_spend({}, undef, "$R/explicit");
    is($src, 'explicit', 'an explicit root gives source explicit');
    ($root, $src) = probe_spend({ CLAUDE_PROJECT_DIR => "$R/cpd" }, $S2, undef);
    is($src, 'session-cwd', 's2 with CLAUDE_PROJECT_DIR set still gives session-cwd (walk beats env)');
};

subtest 'AC3(h): STORE env precedence (DC8)' => sub {
    is(probe_store($C2, { CLAUDE_PROJECT_DIR => "$R/cpd" }), $P, 'from C2 the walk beats CLAUDE_PROJECT_DIR');
    SKIP: {
        skip "git precondition fails from $C1", 1 unless $GIT_PRECOND{$C1};
        is(probe_store($C1, { CLAUDE_PROJECT_DIR => "$R/cpd" }), "$R/cpd", 'from C1 (no project) CLAUDE_PROJECT_DIR is used');
    }
    my $got = probe_store_scope_capability($C1, {}, "$R/explicit");
    is($got, "$R/explicit/.ccpraxis-local-data/almanac", 'scope_capability root option still bypasses the walk');
};

subtest 'AC3(i): HELP ignores every env decoy' => sub {
    my $env = { CLAUDE_PROJECT_DIR => "$R/cpd", BP_PROJECT_ROOT => "$R/envproj", CCPRAXIS_DATA_DIR => "$R/envdata" };
    my ($rc1, undef, undef) = probe_help($C1, $env, '--cwd', $C1);
    is($rc1, 1, '--cwd C1 still exits 1 with every decoy set');
    my ($rc2, $out2, undef) = probe_help($C2, $env, '--cwd', $C2);
    is($rc2, 0, '--cwd C2 still exits 0');
    is(trimmed($out2), $P, '--cwd C2 still prints P');
};

subtest 'AC3(j): LIBB/LIBP env precedence' => sub {
    {
        my ($rc, $out, $err) = probe_lib('butler', $C1, { BP_PROJECT_ROOT => "$R/envproj" });
        my @lines = split /\n/, $out;
        is(trimmed($lines[0]), "$R/envproj", 'LIBB line 1 follows BP_PROJECT_ROOT');
    }
    {
        my ($rc, $out, $err) = probe_lib('butler', $C1, { CCPRAXIS_DATA_DIR => "$R/envdata" });
        my @lines = split /\n/, $out;
        is(trimmed($lines[1]), "$R/envdata", 'LIBB line 2 follows CCPRAXIS_DATA_DIR');
    }
    SKIP: {
        skip "git precondition fails from $C1", 1 unless $GIT_PRECOND{$C1};
        my ($rc, $out, $err) = probe_lib('butler', $C1, { CLAUDE_PROJECT_DIR => "$R/cpd" });
        my @lines = split /\n/, $out;
        is(trimmed($lines[0]), $C1, 'LIBB does not honour CLAUDE_PROJECT_DIR: line 1 is the start');
    }
    {
        my ($rc, $out, $err) = probe_lib('blueprint', $C1, { BP_PROJECT_ROOT => "$R/envproj" });
        my @lines = split /\n/, $out;
        is(trimmed($lines[0]), "$R/envproj", 'LIBP line 1 follows BP_PROJECT_ROOT');
    }
};

# ===========================================================================
# AC4 (DC3, git precedence)
# ===========================================================================

subtest 'AC4: git precedes the walk-up' => sub {
    plan skip_all => 'git --version failed; cannot exercise git precedence' unless $GIT_VERSION_OK;

    my $G = "$T/gitproj";
    make_path("$G/sub/.ccpraxis-local-data", "$G/.ccpraxis-local-data");
    my ($rc, $out, $err) = _run_capture_impl('git', 'init', '--quiet', $G);
    plan skip_all => "git init failed in $G: $err" unless $rc == 0;

    is_same_path(probe_bpr("$G/sub", {}), $G, 'BPR from G/sub gives G (git beats walk)');
    is_same_path(probe_ckpt("$G/sub", {}, undef), $G, 'CKPT from G/sub gives G');
    my ($proot, undef) = probe_cache("$G/sub", {});
    is_same_path($proot, $G, 'CACHE _project_root from G/sub gives G');
    ($proot, undef) = probe_prog("$G/sub", {});
    is_same_path($proot, $G, 'PROG _project_root from G/sub gives G');
    my ($libr, $liberr) = (probe_lib('butler', "$G/sub", {}))[1];
    my @lines = split /\n/, $libr // '';
    is_same_path(trimmed($lines[0]), $G, 'LIBB line 1 from G/sub gives G');

    my ($fbrc, $fbout, undef) = probe_fb("$G/sub", {}, '--', 'probe-text');
    is($fbrc, 0, 'FB from G/sub exits 0');
    my ($fb_prefix) = $fbout =~ m{^(.*)/\.ccpraxis-local-data/corrections/};
    ok(defined($fb_prefix) && same_path($fb_prefix, $G),
        "FB writes under G/.ccpraxis-local-data (same_path; got prefix " . (defined $fb_prefix ? $fb_prefix : 'undef') . ")");
};

# ===========================================================================
# AC5 (DC1, R3) — the start IS home
# ===========================================================================

subtest 'AC5: a start equal to H adopts H (R3)' => sub {
    is(probe_bpr($H, {}), $H, 'BPR from H adopts H');
    is(probe_store($H, {}), $H, 'STORE from H adopts H');
    my ($rc, $out, undef) = probe_help($H, {}, '--cwd', $H);
    is($rc, 0, 'HELP from H exits 0');
    is(trimmed($out), $H, 'HELP from H prints H');
    my ($rc2, $libout, undef) = probe_lib('butler', $H, {});
    my @lines = split /\n/, $libout;
    is(trimmed($lines[0]), $H, 'LIBB from H adopts H');
};

# ===========================================================================
# AC6 (Windows; SKIP elsewhere) — POSIX-drive / backslash spellings
# ===========================================================================

subtest 'AC6: Windows path-form tolerance re-runs AC1' => sub {
    plan skip_all => 'Windows-only (spec §4.1 AC6)' unless $^O =~ /^(MSWin32|msys|cygwin)$/;

    (my $h_posix = $H) =~ s{^([A-Za-z]):}{'/' . lc($1)}e;
    (my $t_posix = $T) =~ s{^([A-Za-z]):}{'/' . lc($1)}e;
    (my $h_back  = $H) =~ s{/}{\\}g;

    SKIP: {
        skip 'git precondition fails from C1', 1 unless $GIT_PRECOND{$C1};
        is(probe_bpr($C1, { HOME => $h_posix, TMP => $t_posix, TEMP => $t_posix, TMPDIR => $t_posix, USERPROFILE => $h_back }),
            $C1, 'AC6/AC1: BPR from C1 under /c/... TMP+HOME and backslash USERPROFILE');
    }
    is(probe_store($C1, { HOME => $h_posix, TMP => $t_posix, TEMP => $t_posix, TMPDIR => $t_posix, USERPROFILE => $h_back }),
        $C1, 'AC6/AC1: STORE from C1 not adopted under /c/... forms')
        if $GIT_PRECOND{$C1};
    {
        my ($rc, $out, undef) = probe_help($C1, { HOME => $h_posix, TMP => $t_posix, TEMP => $t_posix, TMPDIR => $t_posix, USERPROFILE => $h_back }, '--cwd', $C1);
        is($rc, 1, 'AC6/AC1: HELP from C1 exits 1 under /c/... forms');
    }
    {
        my ($rc, $libout, undef) = probe_lib('butler', $C1, { HOME => $h_posix, TMP => $t_posix, TEMP => $t_posix, TMPDIR => $t_posix, USERPROFILE => $h_back });
        my @lines = split /\n/, $libout;
        is(trimmed($lines[0]), $C1, 'AC6/AC1: LIBB from C1 under /c/... forms') if $GIT_PRECOND{$C1};
    }
};

# ===========================================================================
# AC7 (Windows; SKIP elsewhere) — further spellings, BPR/STORE/HELP/LIBB only
# ===========================================================================

subtest 'AC7: further Windows spellings for BPR/STORE/HELP/LIBB' => sub {
    plan skip_all => 'Windows-only (spec §4.1 AC7)' unless $^O =~ /^(MSWin32|msys|cygwin)$/;

    (my $t_back = $T) =~ s{/}{\\}g;
    subtest '(a) TMP/TEMP/TMPDIR backslash form' => sub {
        SKIP: {
            skip 'git precondition fails from C1', 1 unless $GIT_PRECOND{$C1};
            is(probe_bpr($C1, { TMP => $t_back, TEMP => $t_back, TMPDIR => $t_back }), $C1, 'BPR under backslash TMP');
        }
        is(probe_store($C1, { TMP => $t_back, TEMP => $t_back, TMPDIR => $t_back }), $C1, 'STORE under backslash TMP')
            if $GIT_PRECOND{$C1};
        my ($rc, undef, undef) = probe_help($C1, { TMP => $t_back, TEMP => $t_back, TMPDIR => $t_back }, '--cwd', $C1);
        is($rc, 1, 'HELP under backslash TMP exits 1');
    };

    subtest '(b) TMP/TEMP/TMPDIR upper-cased' => sub {
        SKIP: {
            skip 'git precondition fails from C1', 1 unless $GIT_PRECOND{$C1};
            is(probe_bpr($C1, { TMP => uc($T), TEMP => uc($T), TMPDIR => uc($T) }), $C1, 'BPR under upper-cased TMP');
        }
    };

    subtest '(c) HELP --cwd in a differing spelling from TMP' => sub {
        (my $c1_posix = $C1) =~ s{^([A-Za-z]):}{'/' . lc($1)}e;
        (my $t_posix  = $T)  =~ s{^([A-Za-z]):}{'/' . lc($1)}e;
        my ($rc, $out, undef) = probe_help($C1, { TMP => $t_posix, TEMP => $t_posix, TMPDIR => $t_posix }, '--cwd', $C1);
        is($rc, 1, 'HELP: --cwd in C:/... form while TMP is /c/... still exits 1');
        (my $c1_back = $C1) =~ s{/}{\\}g;
        ($rc, $out, undef) = probe_help($C1, {}, '--cwd', $c1_back);
        is($rc, 1, 'HELP: --cwd in backslash form still exits 1');
    };

    subtest '(d) 8.3 short names' => sub {
        my $raw_tmp = $ENV{TMP} || $ENV{TEMP} || '';
        plan skip_all => "host TMP/TEMP has no 8.3 segment: $raw_tmp" unless $raw_tmp =~ /~\d/;
        my $r83 = slashify(Cwd::abs_path(tempdir(CLEANUP => 1)));
        my $h83 = "$r83/home";
        make_path("$h83/.ccpraxis-local-data");
        my $t83 = "$h83/AppData/Local/Temp";
        make_path($t83);
        # Best-effort: derive an 8.3 spelling of $t83's ancestry from the host's
        # own short-name TMP prefix; if the fixture path itself has no short
        # form (short tempdir names are the common case), this SKIPs rather
        # than asserting on an untested spelling.
        my $short = $raw_tmp;
        plan skip_all => '8.3 fixture spelling could not be derived' unless -d $short;
        pass('8.3 host precondition observed (raw TMP has a ~N segment); no further assertion without a derivable short spelling for the fixture tree');
    };
};

# ===========================================================================
# AC8 (DC1/DC2, adapter) — in-process, BpProjectRoot::bounded_walkup/_ancestors
# ===========================================================================

subtest 'AC8: bounded_walkup is the first hit of bounded_ancestors' => sub {
    local %ENV = %ENV;
    delete @ENV{@SCRUB};
    $ENV{HOME} = $H; $ENV{USERPROFILE} = $H;
    $ENV{TMP} = $T; $ENV{TEMP} = $T; $ENV{TMPDIR} = $T;

    my $loaded = eval { require $PROJECTROOT_PM; 1 };
    ok($loaded, 'BpProjectRoot.pm loads') or diag($@);

    for my $x ($C1, $C1h, $C2, $CQ, $H) {
        my $walkup    = eval { BpProjectRoot::bounded_walkup($x) };
        my $ancestors = eval { [ BpProjectRoot::bounded_ancestors($x) ] };
        ok(!$@, "bounded_walkup/bounded_ancestors callable for $x") or diag($@);
        next if $@;
        my ($first_hit) = grep { -d "$_/.ccpraxis-local-data" } @$ancestors;
        if (defined $walkup) {
            ok(defined $first_hit && same_path($walkup, $first_hit),
                "bounded_walkup($x) is the first ancestor holding .ccpraxis-local-data");
        } else {
            ok(!defined $first_hit, "bounded_walkup($x) undef matches no ancestor holding one");
        }
    }

    my $anc_c1 = eval { [ BpProjectRoot::bounded_ancestors($C1) ] } // [];
    is_deeply([ map { slashify($_) } @$anc_c1 ], [ $C1, "$T/probe" ], 'bounded_ancestors(C1) == [C1, T/probe]')
        unless $@;

    my $anc_c1h = eval { [ BpProjectRoot::bounded_ancestors($C1h) ] } // [];
    is_deeply([ map { slashify($_) } @$anc_c1h ], [ $C1h, "$H/noproj" ], 'bounded_ancestors(C1h) == [C1h, H/noproj]')
        unless $@;

    my $anc_h = eval { [ BpProjectRoot::bounded_ancestors($H) ] } // [];
    is_deeply([ map { slashify($_) } @$anc_h ], [ $H ], 'bounded_ancestors(H) == [H]')
        unless $@;
};

# ===========================================================================
# AC9 (DC1/DC2, Store mirror parity)
# ===========================================================================

subtest 'AC9(a): Store::_bounded_walk parity with BpProjectRoot::bounded_walkup' => sub {
    local %ENV = %ENV;
    delete @ENV{@SCRUB};
    $ENV{HOME} = $H; $ENV{USERPROFILE} = $H;
    $ENV{TMP} = $T; $ENV{TEMP} = $T; $ENV{TMPDIR} = $T;
    eval { require $PROJECTROOT_PM };

    for my $x ($C1, $C1h, $C2, $CQ, $H) {
        my $bpr_val = eval { BpProjectRoot::bounded_walkup($x) };
        my $store_val = probe_store_bounded_walk($x, {});
        $store_val = undef if defined($store_val) && $store_val eq 'UNDEF';
        if (!defined $bpr_val && !defined $store_val) {
            pass("both undef for $x");
        } else {
            ok(defined $bpr_val && defined $store_val && same_path($bpr_val, $store_val),
                "BpProjectRoot::bounded_walkup and Store::_bounded_walk agree for $x");
        }
    }
};

subtest 'AC9(c): Store keeps the .git marker but not a stray dotfile' => sub {
    my $r2 = slashify(Cwd::abs_path(tempdir(CLEANUP => 1)));
    my $h2 = "$r2/home2";
    make_path("$h2/.git");   # a FILE marker at home is never adopted per this AC's wording; use a dir here
    my $t2 = "$h2/AppData/Local/Temp";
    make_path($t2);
    my $x = "$t2/x"; make_path($x);
    my $env = { HOME => $h2, USERPROFILE => $h2, TMP => $t2, TEMP => $t2, TMPDIR => $t2 };
    is(probe_store_bounded_walk($x, $env), 'UNDEF', 'a .git in home is not adopted from a project-less start');

    my $g = "$t2/g"; make_path("$g/.git", "$g/y");
    is(probe_store_bounded_walk("$g/y", $env), $g, 'a .git below temp (not at home) is still adopted');
};

# ===========================================================================
# AC10 (bp-data-root.pl contract)
# ===========================================================================

subtest 'AC10: bp-data-root.pl CLI contract' => sub {
    my $before = do {
        opendir(my $dh, $R) or die "opendir $R: $!";
        my @e = sort readdir $dh;
        closedir $dh;
        \@e;
    };

    my ($rc, $out, $err) = probe_help($C1, {}, '--unknown-flag');
    is($rc, 2, 'an unknown argument exits 2');
    isnt($err, '', 'unknown argument: non-empty STDERR');
    is($out, '', 'unknown argument: empty STDOUT');

    ($rc, $out, $err) = probe_help($C1, {}, '--cwd');
    is($rc, 2, '--cwd with no value exits 2');
    isnt($err, '', '--cwd with no value: non-empty STDERR');
    is($out, '', '--cwd with no value: empty STDOUT');

    ($rc, $out, $err) = probe_help($C1, {}, '--cwd', $C1);
    is($err, '', 'exit 1 leaves STDERR empty');

    ($rc, $out, $err) = probe_help($C2, {}, '--cwd', $C2);
    is($err, '', 'exit 0 leaves STDERR empty');

    ($rc, $out, $err) = probe_help($C2, {});
    is(trimmed($out), $P, 'no --cwd: probe run with cwd C2 prints P');

    my $after = do {
        opendir(my $dh, $R) or die "opendir $R: $!";
        my @e = sort readdir $dh;
        closedir $dh;
        \@e;
    };
    is_deeply($after, $before, 'a snapshot of R is unchanged across every HELP probe');
};

# ===========================================================================
# AC11 (behaviour 7) — a lonely bp-lib.sh copy with no helper beside it
# ===========================================================================

subtest 'AC11: bp_project_root falls to $PWD when the helper is missing' => sub {
    my $lonely_dir = "$R/lonely/scripts";
    make_path($lonely_dir);
    open(my $in, '<', $BUTLER_LIB) or die "read $BUTLER_LIB: $!";
    open(my $outfh, '>', "$lonely_dir/bp-lib.sh") or die "write lonely bp-lib.sh: $!";
    local $/;
    print { $outfh } <$in>;
    close $in;
    close $outfh;

    my ($rc, $out, $err) = probe_lib_at("$lonely_dir/bp-lib.sh", $C1, {});
    my @lines = split /\n/, $out;
    is(trimmed($lines[0]), $C1, 'bp_project_root prints C1 (falls to $PWD) with no helper beside the lonely copy');
    is($rc, 0, 'exit status is 0');
    is($err, '', 'STDERR is empty');
};

# ===========================================================================
# AC12 — the two bp-lib.sh copies stay byte-identical over the shared range
# ===========================================================================

sub extract_shared_range {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "read $path: $!";
    my @lines = <$fh>;
    close $fh;
    my ($start) = grep { $lines[$_] =~ /^bp_project_root\(\) \{/ } 0 .. $#lines;
    my ($fa_start) = grep { $lines[$_] =~ /^file_age_min\(\)/ } 0 .. $#lines;
    return undef unless defined $start && defined $fa_start && $fa_start > $start;
    my $end = $fa_start;
    for my $i ($fa_start .. $#lines) {
        if ($lines[$i] =~ /^\}/) { $end = $i; last }
    }
    return join('', @lines[$start .. $end]);
}

subtest 'AC12: bp_project_root..file_age_min is byte-identical in both copies, and each names the helper' => sub {
    my $butler_range    = extract_shared_range($BUTLER_LIB);
    my $blueprint_range = extract_shared_range($BLUEPRINT_LIB);
    ok(defined $butler_range && defined $blueprint_range, 'both shared ranges extracted') or return;
    is($butler_range, $blueprint_range, 'the shared range is byte-identical in both copies');

    for my $path ($BUTLER_LIB, $BLUEPRINT_LIB) {
        open(my $fh, '<', $path) or die "read $path: $!";
        local $/;
        my $txt = <$fh>;
        close $fh;
        like($txt, qr/bp-data-root\.pl/, "$path mentions bp-data-root.pl");
    }
};

# ===========================================================================
# AC13 (hook cost) — BpDataRoot.pm is loaded only when the walk-up step runs
# ===========================================================================

subtest 'AC13: BpDataRoot.pm loads lazily, only on the walk-up step' => sub {
    my $code1 = qq{
        require "$PROJECTROOT_PM";
        \$ENV{CLAUDE_PROJECT_DIR} = "$R/cpd";
        BpProjectRoot::resolve();
        print( (grep { m{BpDataRoot\\.pm\$} } keys \%INC) ? "LOADED" : "NOTLOADED" );
    };
    my ($rc1, $out1, undef) = run_capture_in($R, { CLAUDE_PROJECT_DIR => "$R/cpd" }, $^X, '-e', $code1);
    is(trimmed($out1), 'NOTLOADED', 'CLAUDE_PROJECT_DIR set: BpDataRoot.pm never loads');

    my $code2 = qq{
        require "$PROJECTROOT_PM";
        delete \$ENV{CLAUDE_PROJECT_DIR};
        BpProjectRoot::resolve();
        print( (grep { m{BpDataRoot\\.pm\$} } keys \%INC) ? "LOADED" : "NOTLOADED" );
    };
    my ($rc2, $out2, undef) = run_capture_in($C1, {}, $^X, '-e', $code2);
    is(trimmed($out2), 'LOADED', 'no CLAUDE_PROJECT_DIR from C1: resolve() reaches the walk-up step and loads BpDataRoot.pm');
};

# ===========================================================================
# AC14 (single implementation; source scan)
# ===========================================================================

sub slurp { my ($f) = @_; open(my $fh, '<', $f) or die "read $f: $!"; local $/; return <$fh>; }

sub strip_comments {
    my ($txt) = @_;
    return join("\n", map { $_ =~ s/^\s*#.*$//; $_ } split /\n/, $txt);
}

subtest 'AC14(a): every widened caller mentions the adapter' => sub {
    for my $f ($FEEDBACK_PL, $CHECKPOINT_PL, $ORCH_PL, $CACHE_PL, $PROGRESS_PL, $SESSION_PM, $SPEND_PL) {
        my $txt = slurp($f);
        like($txt, qr/BpProjectRoot::bounded_(walkup|ancestors)/, "$f calls the adapter");
    }
};

subtest 'AC14(b): no widened caller (or the adapter) keeps its own updir loop' => sub {
    for my $f ($FEEDBACK_PL, $CHECKPOINT_PL, $ORCH_PL, $CACHE_PL, $PROGRESS_PL, $SESSION_PM, $SPEND_PL, $PROJECTROOT_PM) {
        my $txt = strip_comments(slurp($f));
        unlike($txt, qr/File::Spec->updir/, "$f: no File::Spec->updir");
    }
};

subtest 'AC14(c): neither bp-lib.sh keeps the unbounded while loop' => sub {
    for my $f ($BUTLER_LIB, $BLUEPRINT_LIB) {
        my $txt = slurp($f);
        unlike($txt, qr/while \[ "\$d" != "\/" \]/, "$f: no unbounded while loop");
    }
};

subtest 'AC14(d): the loader checks the public functions it calls (Decision 24 item 4)' => sub {
    my $txt = slurp($PROJECTROOT_PM);
    like($txt, qr/BpDataRoot::walkup/, 'BpProjectRoot.pm calls BpDataRoot::walkup');
    like($txt, qr/BpDataRoot::ancestors/, 'BpProjectRoot.pm calls BpDataRoot::ancestors');
    unlike($txt, qr/defined\s*&\s*BpDataRoot::_walkup/,
        'the load guard no longer checks the private _walkup symbol (review S3/red-team N3)');
    ok($txt =~ qr/defined\s*&\s*BpDataRoot::walkup/ && $txt =~ qr/defined\s*&\s*BpDataRoot::ancestors/,
        'the load guard is gated on both public symbols it actually calls being defined');
};

# ===========================================================================
# AC17 (Decision 22) -- bp-spend's hand-rolled session JSON reader
# (_session_recorded_cwd / _session_json_members / _session_json_scalar) must
# return the recorded cwd byte-exactly as the same string
# JSON::PP->new->utf8->decode would yield, including escapes, for a cwd
# containing a 2-byte character (an accented letter) and a 4-byte character
# (an astral-plane emoji) -- both written as raw UTF-8 (the way Claude Code
# actually writes a transcript) and via the \uXXXX escape form JSON also
# permits (the 4-byte character needs a UTF-16 surrogate pair). The bounded
# walk-up must then resolve the real fixture project from that decoded cwd.
# ===========================================================================

subtest 'AC17 (Decision 22): non-ASCII session cwd byte-exactness and end-to-end resolution' => sub {
    my $loaded_spend = eval { require $SPEND_PL; 1 };
    ok($loaded_spend, 'bp-spend.pl loads') or return;
    eval { require $PROJECTROOT_PM };

    # \x{...} always yields the Unicode CHARACTER regardless of source
    # encoding; Encode::encode('UTF-8', ...) turns each into the exact raw
    # octets Claude Code would write, kept as a plain byte string throughout
    # (never concatenated with a wide-char value) so the fixture path is
    # unambiguous, byte-for-byte, on disk.
    my $accent_bytes = Encode::encode('UTF-8', "\x{e9}");     # 2-byte UTF-8 (0xC3 0xA9)
    my $astral_bytes = Encode::encode('UTF-8', "\x{1f600}");  # 4-byte UTF-8 (0xF0 0x9F 0x98 0x80)

    my $proj_nonascii = "$T/pr${accent_bytes}j-${astral_bytes}";
    make_path("$proj_nonascii/.ccpraxis-local-data", "$proj_nonascii/src/deep");
    my $cwd_nonascii = "$proj_nonascii/src/deep";

    my $sess_raw = "$R/sessions/nonascii-raw.jsonl";
    open(my $fh1, '>:raw', $sess_raw) or die "write $sess_raw: $!";
    print $fh1 qq({"type":"permission-mode","cwd":"$cwd_nonascii","sessionId":"x"}\n);
    close $fh1;

    # The SAME real directory, named via \uXXXX escapes instead of raw bytes
    # (😀 is U+1F600's UTF-16 surrogate pair, per the JSON spec --
    # this is "one variant using \u escapes"). $T itself still carries its
    # own raw-byte ancestry (this host's real, non-ASCII home directory), so
    # this line legitimately mixes raw UTF-8 bytes and \u escapes in one
    # string value, exactly as a hand-written JSON line may.
    my $escaped_segment  = 'préj-😀';
    my $cwd_escaped_text = "$T/$escaped_segment/src/deep";
    my $sess_escaped = "$R/sessions/nonascii-escaped.jsonl";
    open(my $fh2, '>:raw', $sess_escaped) or die "write $sess_escaped: $!";
    print $fh2 qq({"type":"permission-mode","cwd":"$cwd_escaped_text","sessionId":"x"}\n);
    close $fh2;

    for my $case (
        [ 'raw UTF-8 (the way Claude Code writes it)', $sess_raw ],
        [ '\uXXXX escapes',                             $sess_escaped ],
    ) {
        my ($label, $sess_path) = @$case;
        my $raw_line = do {
            open(my $rf, '<:raw', $sess_path) or die "read $sess_path: $!";
            my $l = <$rf>;
            close $rf;
            $l =~ s/\r?\n\z//;
            $l;
        };
        my $expected = eval { JSON::PP->new->utf8->decode($raw_line)->{cwd} };
        ok(!$@, "$label: JSON::PP->new->utf8->decode succeeds on the fixture line") or diag($@);
        my $got = BpSpend::Derive::_session_recorded_cwd($sess_path);
        is($got, $expected,
            "$label: bp-spend's recorded-cwd reader returns exactly what JSON::PP->new->utf8->decode gives for cwd");
    }

    # End-to-end (Decision 22): "03 walks up from that recorded cwd, so on
    # this host the walk-up starts from a path that does not exist" -- and
    # separately, the bounded ADAPTER must resolve the real project from that
    # same decoded value. Two independent reasons this can be red today:
    #   (1) the representation bug itself: resolve_data_root's session-cwd
    #       step returns the DECODED (wide-char) cwd with ".ccpraxis-local-data"
    #       appended, which -- reproduced directly against this file, no test
    #       harness involved -- no longer STRING-COMPARES equal (via eq) to
    #       the real, byte-string filesystem path it actually names, even
    #       though same_path() and -d both still resolve it correctly today;
    #   (2) BpProjectRoot::bounded_walkup does not exist yet at all (this
    #       package's general gap; AC8/AC13/AC14a already pin this
    #       separately). Once it exists, bp-spend.pl must also be wired to
    #       call it (AC14a) for this production path to benefit from it.
    my $decoded_cwd = BpSpend::Derive::_session_recorded_cwd($sess_raw);
    my $walked = eval { BpProjectRoot::bounded_walkup($decoded_cwd) };
    my $walk_err = $@;
    ok(!$walk_err, 'bounded_walkup is callable on the decoded non-ASCII cwd (reason 2 above, if it fails)')
        or diag($walk_err);
    SKIP: {
        skip 'bounded_walkup died -- see the diagnostic above', 1 if $walk_err;
        ok(defined($walked) && same_path($walked, $proj_nonascii),
            'the bounded walk-up from the recorded (decoded) cwd resolves the real fixture project');
    }

    my ($root, $src) = BpSpend::Derive::resolve_data_root(undef, $sess_raw);
    is($root, "$proj_nonascii/.ccpraxis-local-data",
        'end-to-end (reason 1 above): resolve_data_root from the non-ASCII session cwd gives the '
        . "project's data dir, byte-exactly (not just same_path)");
    is($src, 'session-cwd', 'end-to-end: source is session-cwd');
};

# ===========================================================================
# Decision 24 (reports/03-review.md, reports/03-redteam.md) -- fix-batch reds
# ===========================================================================

# ---------------------------------------------------------------------------
# Shared fixture: a full copy of $SCRIPTS with BpProjectRoot.pm OMITTED, so
# each of the six MUST-FIX callers can be exercised exactly as the review's
# own probe did ("copy BpSession.pm alone into a temp dir") without also
# breaking every OTHER sibling require those six carry (bp-orchestrator.pl
# requires bp-govern.pl etc. unconditionally at its own top level; bp-cache-
# state.pl and bp-progress.pl each require bp-orchestrator.pl the same way).
# ---------------------------------------------------------------------------

sub build_lonely_scripts_dir {
    my $dir = "$R/lonely-scripts";
    return $dir if -d $dir;
    File::Find::find({
        no_chdir => 1,
        wanted => sub {
            my $src = $File::Find::name;
            return if $src eq $SCRIPTS;
            (my $rel = $src) =~ s{^\Q$SCRIPTS\E/?}{};
            return unless length $rel;
            return if $rel eq 'BpProjectRoot.pm';
            my $dest = "$dir/$rel";
            if (-d $src) {
                make_path($dest);
                return;
            }
            my $ddir = dirname($dest);
            make_path($ddir) unless -d $ddir;
            open(my $in, '<:raw', $src) or die "read $src: $!";
            open(my $outfh, '>:raw', $dest) or die "write $dest: $!";
            local $/;
            print { $outfh } <$in>;
            close $in;
            close $outfh;
        },
    }, $SCRIPTS);
    return $dir;
}

my $LONELY_SCRIPTS = build_lonely_scripts_dir();
ok(-d $LONELY_SCRIPTS && !-e "$LONELY_SCRIPTS/BpProjectRoot.pm",
    'fixture: lonely-scripts copy exists and omits BpProjectRoot.pm')
    or BAIL_OUT('fixture: lonely-scripts copy failed');

my $L_SESSION_PM    = "$LONELY_SCRIPTS/BpSession.pm";
my $L_FEEDBACK_PL   = "$LONELY_SCRIPTS/bp-feedback.pl";
my $L_CHECKPOINT_PL = "$LONELY_SCRIPTS/bp-checkpoint.pl";
my $L_ORCH_PL       = "$LONELY_SCRIPTS/bp-orchestrator.pl";
my $L_CACHE_PL      = "$LONELY_SCRIPTS/bp-cache-state.pl";
my $L_PROGRESS_PL   = "$LONELY_SCRIPTS/bp-progress.pl";

subtest 'Decision 24 item 1 (MUST-FIX): six callers do not die when BpProjectRoot.pm cannot be loaded' => sub {
    {
        my $code = qq{
            require "$L_SESSION_PM";
            my \@r = eval { BpSession::transcript_roots(undef) };
            print \$@ ? "ERR:\$@" : "OK";
        };
        my ($rc, $out, $err) = run_capture_in($C1, {}, $^X, '-e', $code);
        unlike($out, qr/^ERR:/, "BpSession::transcript_roots(undef) does not die (got: $out)");
    }
    {
        my $code = qq{
            require "$L_CHECKPOINT_PL";
            my \$r = eval { BpCheckpoint::resolve_root(undef) };
            print \$@ ? "ERR:\$@" : (defined(\$r) ? \$r : "UNDEF");
        };
        my ($rc, $out, $err) = run_capture_in($C1, {}, $^X, '-e', $code);
        unlike($out, qr/^ERR:/, "BpCheckpoint::resolve_root(undef) does not die (got: $out)");
        SKIP: {
            skip "git precondition fails from $C1, or the call died above", 1
                if $out =~ /^ERR:/ || !$GIT_PRECOND{$C1};
            is(trimmed($out), $C1, 'and still resolves to the cwd fallback, same as with the module present (AC1)');
        }
    }
    {
        my ($rc, $out, $err) = run_capture_in($C1, {}, $^X, $L_FEEDBACK_PL, '--', 'probe-text');
        is($rc, 4, 'bp-feedback.pl still exits its fixed exit 4 from C1 (spec Sec3 behaviour 8), not a perl die');
    }
    {
        my $code = qq{
            require "$L_ORCH_PL";
            my \$p = eval { BpOrch::_project_root_of("$B1") };
            print \$@ ? "ERR:\$@" : (defined(\$p) ? \$p : "UNDEF");
        };
        my ($rc, $out, $err) = run_capture_in($R, {}, $^X, '-e', $code);
        unlike($out, qr/^ERR:/, "BpOrch::_project_root_of does not die (got: $out)");
        is(trimmed($out), 'UNDEF', 'and still answers UNDEF for a project-less bpdir, same as with the module present (AC1)')
            unless $out =~ /^ERR:/;
    }
    {
        my $code = qq{
            require "$L_CACHE_PL";
            my \$p = eval { BpCacheState::_project_root() };
            print \$@ ? "ERR:\$@" : (defined(\$p) ? \$p : "UNDEF");
        };
        my ($rc, $out, $err) = run_capture_in($C1, {}, $^X, '-e', $code);
        unlike($out, qr/^ERR:/, "BpCacheState::_project_root does not die (got: $out)");
        SKIP: {
            skip "git precondition fails from $C1, or the call died above", 1
                if $out =~ /^ERR:/ || !$GIT_PRECOND{$C1};
            is(trimmed($out), $C1, 'and still resolves to the start, same as with the module present (AC1)');
        }
    }
    {
        my $code = qq{
            require "$L_PROGRESS_PL";
            my \$p = eval { BpProgress::_project_root() };
            print \$@ ? "ERR:\$@" : (defined(\$p) ? \$p : "UNDEF");
        };
        my ($rc, $out, $err) = run_capture_in($C1, {}, $^X, '-e', $code);
        unlike($out, qr/^ERR:/, "BpProgress::_project_root does not die (got: $out)");
        SKIP: {
            skip "git precondition fails from $C1, or the call died above", 1
                if $out =~ /^ERR:/ || !$GIT_PRECOND{$C1};
            is(trimmed($out), $C1, 'and still resolves to the start, same as with the module present (AC1)');
        }
    }
};

# ---------------------------------------------------------------------------
# Item 2: bp-orchestrator resolves a HOME-rooted blueprint dir structurally
# (red-team S1).
# ---------------------------------------------------------------------------

my $B_HOME = "$H/.ccpraxis-local-data/blueprints/bp";
make_path($B_HOME);

subtest 'Decision 24 item 2: bp-orchestrator resolves a HOME-rooted bpdir (red-team S1)' => sub {
    my ($proot, $ldd) = probe_orch($B_HOME, {});
    ok(defined($proot) && $proot ne 'UNDEF' && same_path($proot, $H),
        "_project_root_of(bpdir under H/.ccpraxis-local-data/blueprints) gives H (got: " . (defined $proot ? $proot : 'undef') . ")");
    ok(defined($ldd) && $ldd ne 'UNDEF' && same_path($ldd, "$H/.ccpraxis-local-data"),
        "lifecycle_data_dir gives H/.ccpraxis-local-data (got: " . (defined $ldd ? $ldd : 'undef') . ")");
};

# ---------------------------------------------------------------------------
# Item 3: bp-spend --json must not double-encode a non-ASCII session-cwd
# data_root (review S2).
# ---------------------------------------------------------------------------

subtest 'Decision 24 item 3: bp-spend report-session --json does not double-encode a non-ASCII data_root' => sub {
    my $accent_bytes = Encode::encode('UTF-8', "\x{e9}");
    # $T may or may not carry the utf8 flag in THIS process (Cwd::abs_path's
    # behaviour); force it to a definite byte string before concatenating
    # with another byte string, or an already-flagged $T would silently
    # upgrade $accent_bytes via Latin-1 (not UTF-8 decode), corrupting the
    # fixture path itself before bp-spend.pl ever sees it -- the same
    # normalisation bp-spend.pl's own Decision 22 boundary (utf8::encode)
    # performs at line ~2213.
    my $t_bytes = $T;
    utf8::encode($t_bytes) if utf8::is_utf8($t_bytes);
    my $proj = "${t_bytes}/spendproj-${accent_bytes}";
    make_path("$proj/.ccpraxis-local-data", "$proj/src");
    my $cwd  = "$proj/src";
    my $main = "$R/sessions/spend-nonascii.jsonl";
    open(my $fh, '>:raw', $main) or die "write $main: $!";
    print $fh qq({"type":"permission-mode","cwd":"$cwd","sessionId":"x"}\n);
    close $fh;

    my ($rc, $out, $err) = run_capture_in($R, {}, $^X, $SPEND_PL, 'report-session', '--session', $main, '--json');
    is($rc, 0, 'report-session --json exits 0') or diag("stderr: $err");

    my $decoded = eval { JSON::PP->new->utf8->decode($out) };
    ok(!$@ && ref($decoded) eq 'HASH', 'stdout decodes as a single layer of UTF-8 JSON') or diag("decode error: $@ / out: $out");

    SKIP: {
        skip 'stdout did not decode', 2 unless ref($decoded) eq 'HASH';
        # This host's OWN ambient path (this fixture sits under the real
        # user's home, "André") is not itself guaranteed to be valid UTF-8
        # bytes (Cwd may hand back the system codepage's encoding for it), so
        # neither independently re-decoding the whole path by hand NOR
        # routing the whole path through a reference encode/decode cycle is a
        # safe oracle for it -- both can (and did, empirically) garble the
        # ambient segment for reasons that have nothing to do with bp-spend.
        # Only the SUFFIX this test itself injected ("spendproj-<accent>") is
        # guaranteed valid, self-contained UTF-8, so that is the only part
        # asserted on: correctly single-encoded, it decodes back to exactly
        # one 'é' character; double-encoded (the bug), the same two bytes
        # decode as "Ã©" -- two separate mojibake characters -- instead.
        like($decoded->{data_root}, qr/spendproj-\x{e9}\/\.ccpraxis-local-data\z/,
            'the decoded data_root ends in the injected accent character exactly (single-encoded), not "Ã©" mojibake (double-encoded)');
        is($decoded->{data_root_source}, 'session-cwd', 'data_root_source is session-cwd');
    }
};

# ---------------------------------------------------------------------------
# Item 5: both bp-lib.sh copies reject a helper answer that is not a single
# line naming an existing directory (red-team S3).
# ---------------------------------------------------------------------------

subtest 'Decision 24 item 5: bp-lib.sh rejects a noisy multi-line helper answer' => sub {
    my $fakedir = "$R/fakeperl";
    make_path($fakedir);
    # The fake helper prints a WRONG answer ($R/argdata, not the caller's
    # $PWD) plus a noise line -- so accepting the multi-line answer (the bug)
    # is distinguishable from falling back to $PWD (the fix), unlike a fake
    # that happens to echo $PWD itself as its first line.
    open(my $fh, '>', "$fakedir/perl") or die "write fake perl: $!";
    print {$fh} "#!/bin/sh\nprintf '%s\\nnoise line\\n' '$R/argdata'\nexit 0\n";
    close $fh;
    chmod 0755, "$fakedir/perl";

    for my $which ([ 'butler', $BUTLER_LIB ], [ 'blueprint', $BLUEPRINT_LIB ]) {
        my ($label, $lib) = @$which;
        SKIP: {
            skip "git precondition fails from $C1", 1 unless $GIT_PRECOND{$C1};
            my $env = { PATH => "$fakedir:" . ($ENV{PATH} // '') };
            my ($rc, $out, $err) = probe_lib_at($lib, $C1, $env);
            my @lines = split /\n/, $out;
            is(trimmed($lines[0]), $C1,
                "$label: bp_project_root falls back to \$PWD (C1) rather than accepting the noisy multi-line helper answer");
        }
    }
};

# ---------------------------------------------------------------------------
# Item 6: bp-data-root.pl exits a non-usage code when BpProjectRoot.pm is
# missing (review S4).
# ---------------------------------------------------------------------------

subtest 'Decision 24 item 6: bp-data-root.pl exits a non-usage code when BpProjectRoot.pm is missing' => sub {
    my $lonely_dir = "$R/lonely-data-root";
    make_path($lonely_dir);
    open(my $in, '<:raw', $DATA_ROOT_PL) or die "read $DATA_ROOT_PL: $!";
    open(my $outfh, '>:raw', "$lonely_dir/bp-data-root.pl") or die "write lonely bp-data-root.pl: $!";
    local $/;
    print { $outfh } <$in>;
    close $in;
    close $outfh;

    my ($rc, $out, $err) = run_capture_in($C1, {}, $^X, "$lonely_dir/bp-data-root.pl", '--cwd', $C1);
    isnt($rc, 2, 'exit code is not 2 (reserved for a real usage error)');
    isnt($rc, 0, 'exit code is not 0 (the module genuinely could not be loaded)');
    isnt($err, '', 'stderr names the failure');
    is($out, '', 'stdout is empty on this failure');
};

# ---------------------------------------------------------------------------
# Item 7: Store.pm's parity test covers AC9(b) (Windows path-form spellings),
# and a source-level check fails if the mirrored stop rules drift from
# BpDataRoot's (review S1).
# ---------------------------------------------------------------------------

sub extract_sub_body {
    my ($text, $name) = @_;
    return undef unless $text =~ /^sub \Q$name\E\s*\{\n(.*?)\n\}\n/ms;
    return $1;
}

sub normalize_mirror_body {
    my ($body) = @_;
    return '' unless defined $body;
    $body =~ s/\bSW_IS_WIN\b/IS_WIN/g;
    $body =~ s/\bSW_IS_DARWIN\b/IS_DARWIN/g;
    # Order matters: BpDataRoot's public same_path() dropped its leading
    # underscore when Decision 20 made it part of the public API, while
    # every other _sw_-prefixed mirror name maps to a still-PRIVATE
    # BpDataRoot name (_sw_foo -> _foo). Handle the longer
    # _sw_same_path_any_form name (and the bare _sw_same_path call) before
    # the generic substitution, or the generic rule would wrongly strip
    # their leading underscore too.
    $body =~ s/_sw_same_path_any_form/_same_path_any_form/g;
    $body =~ s/_sw_same_path\b/same_path/g;
    $body =~ s/_sw_/_/g;
    # Strip comments line-by-line, then collapse ALL whitespace (including
    # newlines) to single spaces -- the two files format some of these
    # mirrored bodies onto a different number of lines (e.g. a one-line
    # `if (...) { pop @out if @out; next }` vs the same statement split
    # across three), which is cosmetic, not drift. Comparing on whitespace-
    # collapsed text still catches any real token-level difference.
    my @lines = split /\n/, $body;
    @lines = map { my $l = $_; $l =~ s/^\s*#.*$//; $l } @lines;
    my $joined = join(' ', @lines);
    $joined =~ s/\s+/ /g;
    # Perl's final statement in a block never needs a trailing ";" before
    # "}" -- purely a style choice, not a behaviour difference.
    $joined =~ s/;\s*\}/ }/g;
    $joined =~ s/^\s+|\s+\z//g;
    return $joined;
}

subtest 'AC9(b): Store::_bounded_walk parity under Windows path-form spellings (AC7a/b)' => sub {
    plan skip_all => 'Windows-only (spec AC7a/b spellings)' unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    (my $t_back = $T) =~ s{/}{\\}g;

    for my $spelling (
        [ '(a) backslash TMP', { TMP => $t_back, TEMP => $t_back, TMPDIR => $t_back } ],
        [ '(b) upper-cased TMP', { TMP => uc($T), TEMP => uc($T), TMPDIR => uc($T) } ],
    ) {
        my ($label, $envextra) = @$spelling;
        local %ENV = %ENV;
        delete @ENV{@SCRUB};
        $ENV{HOME} = $H; $ENV{USERPROFILE} = $H;
        $ENV{TMP} = $envextra->{TMP}; $ENV{TEMP} = $envextra->{TEMP}; $ENV{TMPDIR} = $envextra->{TMPDIR};
        eval { require $PROJECTROOT_PM };

        for my $x ($C1, $C1h, $C2, $CQ, $H) {
            my $bpr_val   = eval { BpProjectRoot::bounded_walkup($x) };
            my $store_val = probe_store_bounded_walk($x, $envextra);
            $store_val = undef if defined($store_val) && $store_val eq 'UNDEF';
            if (!defined $bpr_val && !defined $store_val) {
                pass("$label: both undef for $x");
            } else {
                ok(defined $bpr_val && defined $store_val && same_path($bpr_val, $store_val),
                    "$label: BpProjectRoot::bounded_walkup and Store::_bounded_walk agree for $x");
            }
        }
    }
};

subtest 'Decision 24 item 7: Store.pm mirrored stop-rule subs are source-identical to BpDataRoot.pm (mod naming)' => sub {
    my $store_txt = slurp("$ALM_SCRIPTS/Almanac/Store.pm");
    my $bdr_txt   = slurp($DATAROOT_PM);
    my @pairs = (
        [ '_sw_fold_ascii',          '_fold_ascii' ],
        [ '_sw_is_abs_ish',          '_is_abs_ish' ],
        [ '_sw_lex_canon',           '_lex_canon' ],
        [ '_sw_seg_eq',              '_seg_eq' ],
        [ '_sw_same_path',           'same_path' ],
        [ '_sw_real_path',           '_real_path' ],
        [ '_sw_same_path_any_form',  '_same_path_any_form' ],
        [ '_sw_compute_stops',       '_compute_stops' ],
        [ '_sw_is_stop',             '_is_stop' ],
    );
    for my $p (@pairs) {
        my ($sw_name, $bdr_name) = @$p;
        my $sw_body  = extract_sub_body($store_txt, $sw_name);
        my $bdr_body = extract_sub_body($bdr_txt, $bdr_name);
        ok(defined $sw_body, "Store.pm defines $sw_name") or next;
        ok(defined $bdr_body, "BpDataRoot.pm defines $bdr_name") or next;
        is(normalize_mirror_body($sw_body), normalize_mirror_body($bdr_body),
            "Store::$sw_name body matches BpDataRoot::$bdr_name body (mod _sw_/SW_IS_WIN naming) -- drift would fail here");
    }
};

# ---------------------------------------------------------------------------
# Item 8 (nits): a start containing ".." is canonicalised before the walk;
# an empty or relative HOME/USERPROFILE is ignored as a stop dir, and home
# is not adoptable through it (red-team N1/N2).
# ---------------------------------------------------------------------------

subtest 'Decision 24 item 8(a): a start containing .. is canonicalised before the walk' => sub {
    my $workdir = "$T/dotdot-work";
    make_path($workdir);
    my $proja = "$workdir/projA";
    make_path("$proja/.ccpraxis-local-data");

    my ($rc, $out, $err) = probe_help($proja, {}, '--cwd', '..');
    is($rc, 1, 'bp-data-root.pl --cwd .. from inside projA must not adopt projA itself as an ancestor');
    is($out, '', 'stdout is empty on exit 1');
};

subtest 'Decision 24 item 8(b): an empty or relative HOME/USERPROFILE is not adoptable as home' => sub {
    for my $case (
        [ 'empty HOME/USERPROFILE',    '' ],
        [ 'relative HOME/USERPROFILE', 'home' ],
    ) {
        my ($label, $val) = @$case;
        my $env = { HOME => $val, USERPROFILE => $val };

        SKIP: {
            skip "git precondition fails from $C1h", 1 unless $GIT_PRECOND{$C1h};
            my $got = probe_bpr($C1h, $env);
            ok(!same_path($got, $H), "$label: BPR from C1h does not adopt H (got: $got)");
        }
        SKIP: {
            skip "git precondition fails from $C1h", 1 unless $GIT_PRECOND{$C1h};
            my $got = probe_store($C1h, $env);
            ok(!same_path($got, $H), "$label: STORE from C1h does not adopt H (got: $got)");
        }
        {
            my ($rc, $out, undef) = probe_help($C1h, $env, '--cwd', $C1h);
            ok(!($rc == 0 && same_path(trimmed($out), $H)), "$label: HELP from C1h does not adopt H");
        }
        {
            my ($rc, $libout, undef) = probe_lib('butler', $C1h, $env);
            my @lines = split /\n/, $libout;
            ok(!same_path(trimmed($lines[0]), $H), "$label: LIBB from C1h does not adopt H");
        }
    }
};

done_testing();
