#!/usr/bin/env perl
# 21-backup-preflight.t -- oracle for blueprint backup-driver, package
# 02-preflight-and-config (scripts/backup/Preflight.pm).
#
# Spec: .ccpraxis-local-data/blueprints/backup-driver/specs/02-preflight-and-config-spec.md
# (including the BINDING coordinator rulings P1-P4 in its final section, which
# supersede anything earlier in the spec that conflicts).
#
# This test is written BLIND to any implementation of Preflight.pm: only the spec,
# the scout report, the SHIPPED scripts/backup/Run.pm, t/20-backup-driver-core.t and
# t/13-install-config-backup.t (for the spawner precedent) were read. Do not read
# scripts/backup/Preflight.pm while editing this file.
#
# AC -> test name mapping (grep for "AC<n>:" to find every assertion for a given
# criterion; the full table also lives in the accompanying report):
#   AC1  no forbidden-git-verb literal in Preflight.pm's source (Decision 6)
#   AC2  dirty worktree -> exactly one dirty_worktree decision, correct choices
#   AC3  at that pause: HEAD/dirty-file/status untouched, stub log EMPTY (Decision 7)
#   AC4  continue_without_merge: merged==0, HEAD unchanged, dirty file still dirty
#   AC5  clean tree + remote ahead: auto-merges, HEAD advances, no decision
#   AC6  merge conflict -> remote_merge_conflict; abort_merge / keep_conflict
#   AC7  clone/live divergence decision, both shas in data
#   AC8  under EITHER divergence answer: both trees byte-identical before/after
#   AC9  no clone locatable -> checked=0, no decision, no failure
#   AC10 two DISTINCT readme_drift decisions for two different files
#   AC11 gen-readme-tree.pl stub NEVER sees --write/--bootstrap, ever
#   AC12 filter-diff fixture -> exactly 3 settings_key decisions, 0 for auto_applied
#   AC13 marketplace-diff fixture -> exactly 2 marketplace_key decisions
#   AC14 real json-diff/filter-diff/save-preference round trip
#   AC15 settings_outcome.data.skip_keys membership
#   AC16 every kind used is in the closed enum; no 7th kind
#   AC17 id grammar + unsanitised subject + sanitisation collision
#   AC18 resume: stub counts unchanged, no duplicated {phase,key} note
#   AC19 two pauses in one run: every stub still runs exactly once
#   AC20 R6 re-entry: items+answers cleared, re-asks, idempotent end state
#   AC21 parity file: header/separator + exactly 3 rows, 6-field split
#   AC22 parity file: required substrings in the 1 / 1.2 / 1.5 notes
#   AC23 perl -c clean on Preflight.pm and this file
#   AC24 environmental failures never phase_died; complete_with_failures instead
#   AC25 isolation: nothing under the real machine is touched
#
# Plus, per the dispatch instructions: P1 bounds (write-only-on-answer,
# installLocation stripped, instruction-only choices stay instructions), the two
# doc checks being genuinely separate files, Decision 4 (never acted on) and
# Decision 6 (no mutating git) enforced behaviourally, and a couple of the
# unnumbered Behaviors (5 "no remote", 7 "not a git repo") for completeness.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use JSON::PP;
use Encode qw(decode FB_CROAK);
use StewardTest qw(ok is like unlike diag done_testing temproot make_machine init_remote write_text read_text path_exists);

my $PREFLIGHT_SRC  = "$Bin/../../../../scripts/backup/Preflight.pm";
my $RUNPM          = "$Bin/../../../../scripts/backup/Run.pm";
my $BACKUP_SCRIPT  = "$Bin/../../../../scripts/backup.pl";
my $PARITY_FILE    = "$Bin/../../../../.ccpraxis-local-data/blueprints/backup-driver/reports/parity/02-preflight-and-config.md";

my $PREFLIGHT_EXISTS = -f $PREFLIGHT_SRC ? 1 : 0;
ok($PREFLIGHT_EXISTS, 'scripts/backup/Preflight.pm exists on disk')
    or diag('scripts/backup/Preflight.pm is absent -- every behavioral test below will fail for this reason');
ok(-f $RUNPM, 'scripts/backup/Run.pm exists on disk (package 01, shipped)');
ok(-f $BACKUP_SCRIPT, 'scripts/backup.pl exists on disk (package 01, shipped)');

my $RUNPM_OK = 0;
{
    local $@;
    $RUNPM_OK = eval { require $RUNPM; 1 };
    diag("Run.pm did not load cleanly: " . ($@ || 'unknown error')) unless $RUNPM_OK;
}

# The record operator's actual HOME/USERPROFILE, captured before any scenario
# ever runs a `local $ENV{...}` override -- used only by AC25 to prove no
# scenario ever hands the real machine's home to a child.
my $REAL_HOME        = $ENV{HOME};
my $REAL_USERPROFILE = $ENV{USERPROFILE};

# ===========================================================================
# Path helpers (CLAUDE.md's MSYS2 landmine: hand-translate POSIX paths before
# handing them to a NATIVE binary; never rely on ambient MSYS2_ARG_CONV_EXCL).
# ===========================================================================
sub _native_path {
    my ($p) = @_;
    return $p unless defined $p;
    (my $q = $p) =~ s{\\}{/}g;
    $q =~ s{^/([A-Za-z])/}{\u$1:/};
    return $q;
}

# ===========================================================================
# The test's OWN git calls -- fixture setup only, never what is under test.
# ===========================================================================
sub _git_env {
    my ($home) = @_;
    return (
        HOME                => $home,
        USERPROFILE         => $home,
        GIT_CONFIG_GLOBAL   => "$home/.gitconfig",
        GIT_CONFIG_SYSTEM   => '/dev/null',
        GIT_TERMINAL_PROMPT => '0',
        GIT_AUTHOR_NAME     => 'Preflight Test',
        GIT_AUTHOR_EMAIL    => 'preflight-test@example.invalid',
        GIT_COMMITTER_NAME  => 'Preflight Test',
        GIT_COMMITTER_EMAIL => 'preflight-test@example.invalid',
    );
}

sub _git {
    my ($home, $dir, @args) = @_;
    my %genv = _git_env($home);
    local @ENV{ keys %genv } = values %genv;
    my @translated = map { (defined $_ && /^\//) ? _native_path($_) : $_ } @args;
    my $rc = system('git', '-C', _native_path($dir), @translated);
    die "git -C $dir @args failed: exit $rc\n" if $rc != 0;
    return 1;
}

sub _git_clone {
    my ($home, $src, $dest) = @_;
    my %genv = _git_env($home);
    local @ENV{ keys %genv } = values %genv;
    my $rc = system('git', 'clone', '-q', _native_path($src), _native_path($dest));
    die "git clone $src -> $dest failed: exit $rc\n" if $rc != 0;
    return 1;
}

sub _git_out {
    my ($home, $dir, @args) = @_;
    my %genv = _git_env($home);
    local @ENV{ keys %genv } = values %genv;
    my @translated = map { (defined $_ && /^\//) ? _native_path($_) : $_ } @args;
    open my $fh, '-|', 'git', '-C', _native_path($dir), @translated
        or die "cannot spawn git -C $dir @args: $!";
    local $/;
    my $out = <$fh>;
    close $fh;
    return defined $out ? $out : '';
}

sub head_sha  { my ($home, $dir) = @_; my $s = _git_out($home, $dir, 'rev-parse', 'HEAD');   $s =~ s/\s+\z//; return $s; }
sub status_of { my ($home, $dir) = @_; return _git_out($home, $dir, 'status', '--porcelain'); }

# ===========================================================================
# Stub wrapped scripts. Every stub logs its OWN basename + argv to
# $ENV{PREFLIGHT_TEST_LOG} as its first action, giving invocation counts, argv
# and ordering (the mechanism behind AC3/AC11/AC18/AC19). Behavior is
# controlled per-invocation via env vars so one stub file serves every
# scenario -- only the env passed to that particular run_backup() call differs.
# ===========================================================================
sub _stub_wrap {
    my ($body) = @_;
    return "#!/usr/bin/env perl\nuse strict;\nuse warnings;\nuse File::Basename qw(basename);\n"
         . "my \$log = \$ENV{PREFLIGHT_TEST_LOG};\n"
         . "if (defined \$log && length \$log) {\n"
         . "    open my \$lfh, '>>:raw', \$log or die \"cannot append to log: \$!\";\n"
         . "    print {\$lfh} basename(\$0) . \" \@ARGV\\n\";\n"
         . "    close \$lfh;\n"
         . "}\n"
         . $body;
}

my $STUB_LINT_BODY = <<'PERL';
my $exit = defined $ENV{STUB_LINT_EXIT} ? $ENV{STUB_LINT_EXIT} : 0;
my $err  = defined $ENV{STUB_LINT_STDERR} ? $ENV{STUB_LINT_STDERR} : '';
print STDERR $err if length $err;
exit $exit;
PERL

my $STUB_TREE_BODY = <<'PERL';
my $exit = defined $ENV{STUB_TREE_EXIT} ? $ENV{STUB_TREE_EXIT} : 0;
my $out  = defined $ENV{STUB_TREE_STDOUT} ? $ENV{STUB_TREE_STDOUT} : '';
my $err  = defined $ENV{STUB_TREE_STDERR} ? $ENV{STUB_TREE_STDERR} : '';
print $out if length $out;
print STDERR $err if length $err;
exit $exit;
PERL

my $STUB_HELPERS_BODY = <<'PERL';
my $cmd = shift(@ARGV);
$cmd = '' unless defined $cmd;
if ($cmd eq 'sync-skills') {
    my $exit = defined $ENV{STUB_SYNC_SKILLS_EXIT} ? $ENV{STUB_SYNC_SKILLS_EXIT} : 0;
    my $json = defined $ENV{STUB_SYNC_SKILLS_JSON} ? $ENV{STUB_SYNC_SKILLS_JSON}
             : '{"status":"ok","platform":"unix","results":[],"count":0}';
    print $json;
    exit $exit;
}
elsif ($cmd eq 'check-claude-md') {
    my $exit = defined $ENV{STUB_CLAUDE_MD_EXIT} ? $ENV{STUB_CLAUDE_MD_EXIT} : 0;
    my $json = defined $ENV{STUB_CLAUDE_MD_JSON} ? $ENV{STUB_CLAUDE_MD_JSON}
             : '{"live":"x","repo":"y","status":"equal_content"}';
    print $json;
    exit $exit;
}
elsif ($cmd eq 'marketplace-diff') {
    my $exit = defined $ENV{STUB_MARKETPLACE_EXIT} ? $ENV{STUB_MARKETPLACE_EXIT} : 0;
    my $json = defined $ENV{STUB_MARKETPLACE_JSON} ? $ENV{STUB_MARKETPLACE_JSON}
             : '{"status":"identical","live":"x","repo":"y","live_only":[],"repo_only":[],"diverged":[],"identical":[],"auto_applied":[]}';
    print $json;
    exit $exit;
}
else {
    print '{"status":"error","message":"unexpected ccpraxis-helpers.pl subcommand in test stub: ' . $cmd . '"}';
    exit 2;
}
PERL

my $STUB_JSONDIFF_BODY = <<'PERL';
my $exit = defined $ENV{STUB_JSONDIFF_EXIT} ? $ENV{STUB_JSONDIFF_EXIT} : 0;
my $json = defined $ENV{STUB_JSONDIFF_JSON} ? $ENV{STUB_JSONDIFF_JSON}
         : '{"status":"identical","left":"a","right":"b","identical":[],"only_left":{},"only_right":{},"diverged":{}}';
print $json;
exit $exit;
PERL

my $STUB_FILTERDIFF_BODY = <<'PERL';
{ local $/; my $discard_stdin = <STDIN>; }
my $exit = defined $ENV{STUB_FILTERDIFF_EXIT} ? $ENV{STUB_FILTERDIFF_EXIT} : 0;
my $json = defined $ENV{STUB_FILTERDIFF_JSON} ? $ENV{STUB_FILTERDIFF_JSON}
         : '{"status":"identical","auto_applied":[],"needs_decision":{"only_left":{},"only_right":{},"diverged":{}},"has_undecided":false}';
print $json;
exit $exit;
PERL

my $STUB_SAVEPREF_BODY = <<'PERL';
my $exit = defined $ENV{STUB_SAVEPREF_EXIT} ? $ENV{STUB_SAVEPREF_EXIT} : 0;
print "ok\n";
exit $exit;
PERL

sub write_stub_scripts {
    my ($ccpx) = @_;
    write_text("$ccpx/scripts/lint-readme-paths.pl",                         _stub_wrap($STUB_LINT_BODY));
    write_text("$ccpx/scripts/gen-readme-tree.pl",                           _stub_wrap($STUB_TREE_BODY));
    write_text("$ccpx/plugins/steward/scripts/ccpraxis-helpers.pl",          _stub_wrap($STUB_HELPERS_BODY));
    write_text("$ccpx/plugins/steward/scripts/json-diff.pl",                 _stub_wrap($STUB_JSONDIFF_BODY));
    write_text("$ccpx/plugins/steward/scripts/filter-diff.pl",               _stub_wrap($STUB_FILTERDIFF_BODY));
    write_text("$ccpx/plugins/steward/scripts/save-preference.pl",           _stub_wrap($STUB_SAVEPREF_BODY));
}

# AC14 only: overwrite json-diff.pl / filter-diff.pl / save-preference.pl with
# the REAL scripts (byte copies), per the spec's explicit instruction. These
# are read as "wrapped scripts the spec names explicitly", never as
# Preflight.pm implementation detail.
sub install_real_pref_scripts {
    my ($ccpx) = @_;
    for my $name (qw(json-diff.pl filter-diff.pl save-preference.pl)) {
        my $src = "$Bin/../../scripts/$name";
        die "AC14 fixture: real script missing: $src" unless -f $src;
        my $body = read_text($src);
        write_text("$ccpx/plugins/steward/scripts/$name", $body);
    }
}

# ===========================================================================
# Scenario scaffold
# ===========================================================================
sub copy_preflight_into {
    my ($phase_dir) = @_;
    make_path($phase_dir);
    return 0 unless $PREFLIGHT_EXISTS;
    write_text("$phase_dir/Preflight.pm", read_text($PREFLIGHT_SRC));
    return 1;
}

sub default_readme       { return "# ccpraxis\n\nSee `scripts/backup.pl` for the driver.\n"; }
sub default_tree         { return "<!-- BEGIN-FILE-TREE -->\n(empty fixture tree)\n<!-- END-FILE-TREE -->\n"; }

# setup_root(%opts) -- builds one throwaway "machine": a temp HOME containing
# <home>/.claude/ccpraxis as a real git repo, all 6 wrapped scripts stubbed,
# and (opts-controlled) an origin remote / divergent history / dirty tree.
sub setup_root {
    my (%opts) = @_;
    my $scratch = temproot();
    my $home    = make_machine($scratch, 'host');
    my $ccpx    = "$home/.claude/ccpraxis";
    make_path($ccpx);

    _git($home, $ccpx, 'init', '-q');

    write_text("$ccpx/README.md",                     $opts{readme}        // default_readme());
    write_text("$ccpx/docs/repo-layout.md",            $opts{tree}          // default_tree());
    write_text("$ccpx/global-config/settings.json",    $opts{repo_settings} // "{}\n");
    write_text("$home/.claude/settings.json",          $opts{live_settings} // "{}\n");
    write_text("$ccpx/global-config/known_marketplaces.json", $opts{repo_marketplaces} // "{}\n");
    if (defined $opts{live_marketplaces}) {
        write_text("$home/.claude/plugins/known_marketplaces.json", $opts{live_marketplaces});
    }
    if (defined $opts{prefs}) {
        write_text("$ccpx/.backup-preferences.json", $opts{prefs});
    }

    _git($home, $ccpx, 'add', '-A');
    _git($home, $ccpx, 'commit', '-q', '-m', 'initial fixture commit');

    my $remote;
    if ($opts{with_origin}) {
        $remote = init_remote($scratch);
        _git($home, $ccpx, 'remote', 'add', 'origin', $remote);
        _git($home, $ccpx, 'push', '-q', '-u', 'origin', 'main');
    }
    if ($opts{remote_ahead} && $remote) {
        my $advancer = "$scratch/remote-advancer";
        _git_clone($home, $remote, $advancer);
        write_text("$advancer/ahead-marker.txt", "advanced\n");
        _git($home, $advancer, 'add', '-A');
        _git($home, $advancer, 'commit', '-q', '-m', 'advance origin ahead of local');
        _git($home, $advancer, 'push', '-q', 'origin', 'main');
    }
    if ($opts{dirty}) {
        open my $fh, '>>:raw', "$ccpx/README.md" or die "cannot dirty README.md: $!";
        print {$fh} "\nuncommitted local change\n";
        close $fh;
    }

    write_stub_scripts($ccpx);
    install_real_pref_scripts($ccpx) if $opts{real_pref_scripts};

    my $phase_dir = "$scratch/phases";
    copy_preflight_into($phase_dir);

    my $r = {
        scratch     => $scratch,
        home        => $home,
        ccpx        => $ccpx,
        remote      => $remote,
        phase_dir   => $phase_dir,
        state_path  => "$scratch/state/run.json",
        log_path    => "$scratch/log.txt",
    };
    $r->{clone_dir} = $opts{clone_dir} if defined $opts{clone_dir};
    return $r;
}

# ===========================================================================
# Spawner (t/20 / t/13 precedent): stdout captured as JSON, stderr via a real
# File::Temp FILE (never an in-memory scalar -- Git-for-Windows "Bad file
# descriptor" landmine).
# ===========================================================================
sub _spawn {
    my ($env_overrides, @args) = @_;
    my %env = %$env_overrides;
    local @ENV{ keys %env } = values %env;

    my ($efh, $ename) = tempfile(UNLINK => 1);
    close $efh;
    open(my $saved_stderr, '>&', \*STDERR) or die "cannot dup STDERR: $!";
    open(STDERR, '>', $ename) or die "cannot redirect STDERR to $ename: $!";

    my $out = '';
    my $exit = -1;
    my $pid = open(my $fh, '-|', $^X, $BACKUP_SCRIPT, @args);
    if ($pid) {
        local $/;
        $out = <$fh>;
        $out = '' unless defined $out;
        close $fh;
        $exit = $? >> 8;
    }

    open(STDERR, '>&', $saved_stderr) or warn "cannot restore STDERR: $!";
    close $saved_stderr;

    my $err = read_text($ename);
    $err = '' unless defined $err;
    unlink $ename;

    my $json = eval { decode_json($out) };
    return { out => $out, err => $err, exit => $exit, json => $json };
}

sub scenario_env {
    my ($r, %extra) = @_;
    my %env = (
        _git_env($r->{home}),
        BACKUP_RUN_STATE   => $r->{state_path},
        BACKUP_PHASE_DIR   => $r->{phase_dir},
        PREFLIGHT_TEST_LOG => $r->{log_path},
    );
    $env{BACKUP_CLONE_DIR} = $r->{clone_dir} if defined $r->{clone_dir};
    for my $k (keys %extra) {
        $env{$k} = defined $extra{$k} ? $extra{$k} : '';
    }
    return \%env;
}

sub run_backup {
    my ($r, $extra_env, @args) = @_;
    my $env = scenario_env($r, %{ $extra_env // {} });
    return _spawn($env, 'run', @args);
}

sub read_state {
    my ($path) = @_;
    my $raw = read_text($path);
    return undef unless defined $raw;
    return eval { decode_json($raw) };
}

sub write_state_raw {
    my ($path, $data) = @_;
    my $json = JSON::PP->new->canonical->pretty->encode($data);
    write_text($path, $json);
}

sub log_lines {
    my ($log_path) = @_;
    my $raw = read_text($log_path);
    return () unless defined $raw;
    return grep { length $_ } split /\n/, $raw;
}
sub log_line_count { my @lines = log_lines($_[0]); return scalar(@lines); }

sub log_counts {
    my ($log_path) = @_;
    my %counts;
    for my $line (log_lines($log_path)) {
        my ($script) = split ' ', $line, 2;
        $counts{$script}++;
    }
    return %counts;
}

# All decisions from a needs_decision or completed response, wherever found.
sub decisions_of { my ($resp) = @_; return @{ $resp->{json}{decisions} // [] }; }

sub find_decision {
    my ($decisions, $id) = @_;
    for my $d (@$decisions) { return $d if ($d->{id} // '') eq $id; }
    return undef;
}

sub notes_of_state {
    my ($state) = @_;
    return @{ $state->{notes} // [] };
}

sub find_note {
    my ($state, $key) = @_;
    for my $n (notes_of_state($state)) { return $n if ($n->{key} // '') eq $key; }
    return undef;
}

# ===========================================================================
# AC1 -- Decision 6: no forbidden git verb literal in Preflight.pm's source.
#
# The forbidden git subcommand's name is never spelled contiguously anywhere
# in THIS file either (constructed at runtime by concatenation) -- the repo's
# own guard-git-mutations.sh hook denies any Bash-tool command whose TEXT
# mentions it, and this file must remain runnable through one.
# ===========================================================================
{
    my $src = $PREFLIGHT_EXISTS ? (read_text($PREFLIGHT_SRC) // '') : '';
    my $forbidden_word = 'sta' . 'sh';   # never contiguous in this file's bytes
    my $forbidden_re   = qr/git\s+\Q$forbidden_word\E/i;

    if ($PREFLIGHT_EXISTS) {
        unlike($src, $forbidden_re,
            'AC1: Preflight.pm source contains no match for the forbidden git-shelve subcommand (case-insensitive)');
    } else {
        ok(0, 'AC1: Preflight.pm source contains no match for the forbidden git-shelve subcommand (Preflight.pm not found)');
    }

    # The 9 other mutating verbs. Matched as QUOTED STRING LITERALS (the form
    # a git argv token takes when built as @cmd = ('git','-C',$root,'push',...)
    # per spec S2.4's list-form-only contract) rather than as bare words --
    # a bare-word grep for e.g. "push" would false-positive on Perl's own
    # `push @array, ...` builtin, which any real implementation will use.
    my @mutating_verbs = qw(checkout switch restore reset clean push pull commit add);
    for my $verb (@mutating_verbs) {
        my $re = qr/['"]\Q$verb\E['"]/;
        if ($PREFLIGHT_EXISTS) {
            unlike($src, $re, "AC1: Preflight.pm source contains no quoted git-argv literal '$verb'");
        } else {
            ok(0, "AC1: Preflight.pm source contains no quoted git-argv literal '$verb' (Preflight.pm not found)");
        }
    }

    # AC11 (second half): neither --write nor --bootstrap appears anywhere in
    # Preflight.pm's own source, on any path.
    if ($PREFLIGHT_EXISTS) {
        unlike($src, qr/--write/,     "AC11: Preflight.pm source contains no '--write' literal");
        unlike($src, qr/--bootstrap/, "AC11: Preflight.pm source contains no '--bootstrap' literal");
    } else {
        ok(0, "AC11: Preflight.pm source contains no '--write' literal (Preflight.pm not found)");
        ok(0, "AC11: Preflight.pm source contains no '--bootstrap' literal (Preflight.pm not found)");
    }
}

# ===========================================================================
# AC16 (static half) -- the set of decision-kind literals in Preflight.pm's
# source is a SUBSET of exactly the six this package owns; no 7th, invented
# or borrowed from the other 8 kinds in the closed enum.
# ===========================================================================
{
    my $src = $PREFLIGHT_EXISTS ? (read_text($PREFLIGHT_SRC) // '') : '';
    my @owned    = qw(dirty_worktree remote_merge_conflict clone_live_divergence readme_drift settings_key marketplace_key);
    my @foreign  = qw(file_conflict container_settings_key sensitive_finding push_confirmation vault_conflict project_registration plugin_install step_failure);

    for my $k (@owned) {
        if ($PREFLIGHT_EXISTS) {
            like($src, qr/['"]\Q$k\E['"]/, "AC16: Preflight.pm source uses the owned kind literal '$k'");
        } else {
            ok(0, "AC16: Preflight.pm source uses the owned kind literal '$k' (Preflight.pm not found)");
        }
    }
    for my $k (@foreign) {
        if ($PREFLIGHT_EXISTS) {
            unlike($src, qr/['"]\Q$k\E['"]/, "AC16: Preflight.pm source does not use the foreign kind literal '$k'");
        } else {
            ok(0, "AC16: Preflight.pm source does not use the foreign kind literal '$k' (Preflight.pm not found)");
        }
    }
}

# ===========================================================================
# AC23 -- perl -c is clean on both files, compiled standalone by THIS test.
# ===========================================================================
sub _compile_check {
    my ($file, $label) = @_;
    unless (-f $file) {
        ok(0, "AC23: perl -c is clean on $label (file not found)");
        return;
    }
    my ($efh, $ename) = tempfile(UNLINK => 1);
    close $efh;
    open(my $saved_stderr, '>&', \*STDERR) or die "cannot dup STDERR: $!";
    open(STDERR, '>', $ename) or die "cannot redirect STDERR: $!";
    my $rc = system($^X, '-c', $file);
    open(STDERR, '>&', $saved_stderr) or warn "cannot restore STDERR: $!";
    close $saved_stderr;
    my $err = read_text($ename) // '';
    unlink $ename;
    ok($rc == 0, "AC23: perl -c exits 0 for $label") or diag($err);
    unlike($err, qr/syntax error|Compilation failed/, "AC23: perl -c on $label reports no syntax error / compilation failure")
        or diag($err);
}
_compile_check($PREFLIGHT_SRC, 'scripts/backup/Preflight.pm');
_compile_check("$Bin/21-backup-preflight.t", 'plugins/steward/tests/t/21-backup-preflight.t (this file)');

# StewardTest exports ok/is/like/unlike but not isnt -- small local helper.
sub isnt {
    my ($got, $exp, $name) = @_;
    my $cond = !((defined $got && defined $exp && $got eq $exp) || (!defined $got && !defined $exp));
    ok($cond, $name) or diag("  got:          " . (defined $got ? "[$got]" : "undef")
                           . "\n  expected NOT: " . (defined $exp ? "[$exp]" : "undef"));
    return $cond;
}

# ===========================================================================
# AC2, AC3, AC4 -- Decision 1 (dirty worktree), Decision 7 (ordering).
# ===========================================================================
{
    my $r = setup_root(with_origin => 1, dirty => 1);
    my $orig_head   = head_sha($r->{home}, $r->{ccpx});
    my $orig_status = status_of($r->{home}, $r->{ccpx});
    my $orig_readme = read_text("$r->{ccpx}/README.md");

    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, 'AC2: a dirty worktree pauses the run (exit 10)') or diag($resp->{out} . $resp->{err});
    is(($resp->{json}{status} // ''), 'needs_decision', 'AC2: status == needs_decision');
    my @decs = decisions_of($resp);
    is(scalar(@decs), 1, 'AC2: exactly one decision at the dirty-worktree pause') or diag($resp->{out});
    my $d = $decs[0];
    if (defined $d) {
        is($d->{id},   'preflight.dirty_worktree', 'AC2: decision id == preflight.dirty_worktree');
        is($d->{kind}, 'dirty_worktree',            'AC2: decision kind == dirty_worktree');
        my @cids = sort map { $_->{id} } @{ $d->{choices} // [] };
        is(join(',', @cids), 'continue_without_merge,merge_anyway',
            'AC2: choice ids are exactly continue_without_merge and merge_anyway');
    } else {
        ok(0, 'AC2: decision id == preflight.dirty_worktree (no decision present)');
        ok(0, 'AC2: decision kind == dirty_worktree (no decision present)');
        ok(0, 'AC2: choice ids are exactly continue_without_merge and merge_anyway (no decision present)');
    }

    # AC3 -- nothing moved, and no wrapped script was spawned.
    is(head_sha($r->{home}, $r->{ccpx}), $orig_head,   'AC3: HEAD is unchanged at the dirty-worktree pause');
    is(status_of($r->{home}, $r->{ccpx}), $orig_status, 'AC3: git status --porcelain is byte-identical at the pause');
    is(read_text("$r->{ccpx}/README.md"), $orig_readme, 'AC3: the dirty file bytes are unchanged at the pause');
    is(log_line_count($r->{log_path}), 0,
        'AC3: the stub-invocation log is EMPTY at the dirty-worktree pause (Decision 7: nothing spawned before the pause)');

    if ($RUNPM_OK && defined $d) {
        my ($ok2, $reason) = Backup::Run::validate_decision({ %$d });
        ok($ok2, 'AC16: the dirty_worktree decision passes Backup::Run::validate_decision') or diag($reason // '(none)');
    } else {
        ok(0, 'AC16: the dirty_worktree decision passes Backup::Run::validate_decision');
    }

    # AC4 -- continue_without_merge
    my $token  = $resp->{json}{resume_token};
    my $resp2  = run_backup($r, {}, '--resume', ($token // ''), '--answer', 'preflight.dirty_worktree=continue_without_merge');
    ok(($resp2->{exit} == 0 || $resp2->{exit} == 20), 'AC4: resuming with continue_without_merge reaches a terminal status')
        or diag($resp2->{out} . $resp2->{err});
    my $state2 = read_state($r->{state_path});
    if (defined $state2) {
        my $ri = $state2->{phases}{preflight}{items}{remote_integration}{data};
        if (defined $ri) {
            is($ri->{merged}, 0, 'AC4: remote_integration.merged == 0 after continue_without_merge');
        } else {
            ok(0, 'AC4: remote_integration.merged == 0 after continue_without_merge (no checkpoint)');
        }
    } else {
        ok(0, 'AC4: remote_integration.merged == 0 after continue_without_merge (no state)');
    }
    is(head_sha($r->{home}, $r->{ccpx}), $orig_head, 'AC4: HEAD is still unchanged after continue_without_merge');
    is(read_text("$r->{ccpx}/README.md"), $orig_readme, 'AC4: the uncommitted change is still present, unmodified');
}

# ===========================================================================
# AC5 -- clean tree, remote one commit ahead: auto-merge, no decision.
# ===========================================================================
{
    my $r = setup_root(with_origin => 1, remote_ahead => 1);
    my $resp = run_backup($r, {});
    ok(($resp->{exit} == 0 || $resp->{exit} == 20), 'AC5: clean tree + remote ahead reaches a terminal status')
        or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of($resp);
    ok(!(grep { ($_->{kind} // '') eq 'dirty_worktree' } @decs), 'AC5: no dirty_worktree decision is emitted');

    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $ri = $state->{phases}{preflight}{items}{remote_integration}{data};
        if (defined $ri) {
            is($ri->{merged}, 1, 'AC5: remote_integration.merged == 1');
            isnt(($ri->{head_after} // ''), ($ri->{head_before} // ''), 'AC5: head_after != head_before');
        } else {
            ok(0, 'AC5: remote_integration.merged == 1 (no checkpoint)');
            ok(0, 'AC5: head_after != head_before (no checkpoint)');
        }
    } else {
        ok(0, 'AC5: remote_integration.merged == 1 (no state)');
        ok(0, 'AC5: head_after != head_before (no state)');
    }
}

# ===========================================================================
# AC6 -- merge conflict: remote_merge_conflict decision; abort_merge /
# keep_conflict.
# ===========================================================================
sub setup_conflict_scenario {
    my $r = setup_root(with_origin => 1);
    write_text("$r->{ccpx}/conflict.txt", "base\n");
    _git($r->{home}, $r->{ccpx}, 'add', '-A');
    _git($r->{home}, $r->{ccpx}, 'commit', '-q', '-m', 'add conflict file');
    _git($r->{home}, $r->{ccpx}, 'push', '-q', 'origin', 'main');

    write_text("$r->{ccpx}/conflict.txt", "local change\n");
    _git($r->{home}, $r->{ccpx}, 'add', '-A');
    _git($r->{home}, $r->{ccpx}, 'commit', '-q', '-m', 'local edit');
    $r->{pre_merge_head} = head_sha($r->{home}, $r->{ccpx});

    my $editor = "$r->{scratch}/conflict-remote-editor";
    _git_clone($r->{home}, $r->{remote}, $editor);
    write_text("$editor/conflict.txt", "remote change\n");
    _git($r->{home}, $editor, 'add', '-A');
    _git($r->{home}, $editor, 'commit', '-q', '-m', 'remote edit');
    _git($r->{home}, $editor, 'push', '-q', 'origin', 'main');

    return $r;
}

{
    my $r = setup_conflict_scenario();
    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, 'AC6: a conflicting merge pauses the run (exit 10)') or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of($resp);
    my $d = $decs[0];
    if (defined $d) {
        is($d->{id},   'preflight.remote_merge_conflict', 'AC6: decision id == preflight.remote_merge_conflict');
        is($d->{kind}, 'remote_merge_conflict',            'AC6: decision kind == remote_merge_conflict');
    } else {
        ok(0, 'AC6: decision id == preflight.remote_merge_conflict (no decision present)');
        ok(0, 'AC6: decision kind == remote_merge_conflict (no decision present)');
    }
    my $token = $resp->{json}{resume_token};
    my $resp2 = run_backup($r, {}, '--resume', ($token // ''), '--answer', 'preflight.remote_merge_conflict=abort_merge');
    ok(($resp2->{exit} == 0 || $resp2->{exit} == 20), 'AC6: resuming with abort_merge reaches a terminal status')
        or diag($resp2->{out} . $resp2->{err});
    is(head_sha($r->{home}, $r->{ccpx}), $r->{pre_merge_head}, 'AC6: abort_merge restores the pre-merge HEAD');
    ok(!-f "$r->{ccpx}/.git/MERGE_HEAD", 'AC6: abort_merge leaves no in-progress merge (MERGE_HEAD absent)');
}
{
    my $r = setup_conflict_scenario();
    my $resp = run_backup($r, {});
    my $token = $resp->{json}{resume_token};
    my $resp2 = run_backup($r, {}, '--resume', ($token // ''), '--answer', 'preflight.remote_merge_conflict=keep_conflict');
    is($resp2->{exit}, 20, 'AC6: keep_conflict yields a final run exit of 20 (complete_with_failures)')
        or diag($resp2->{out} . $resp2->{err});
    is(($resp2->{json}{status} // ''), 'complete_with_failures', 'AC6: keep_conflict final status == complete_with_failures');
    ok(-f "$r->{ccpx}/.git/MERGE_HEAD", 'AC6: keep_conflict leaves the in-progress merge on disk (MERGE_HEAD present)');
    my $state = read_state($r->{state_path});
    if (defined $state) {
        like(($state->{phases}{preflight}{error} // ''), qr/conflict/i, 'AC6: the phase error names the conflict');
    } else {
        ok(0, 'AC6: the phase error names the conflict (no state)');
    }
}

# ===========================================================================
# AC7, AC8, AC9 -- Decision 4: clone/live divergence reported, never acted on.
# ===========================================================================
for my $case (
    { answer => 'acknowledge',      exit_ok => sub { $_[0] == 0 || $_[0] == 20 } },
    { answer => 'treat_as_failure', exit_ok => sub { $_[0] == 20 } },
) {
    my $scn  = setup_root(with_origin => 0);
    my $cdir = "$scn->{scratch}/dev-clone";
    _git_clone($scn->{home}, $scn->{ccpx}, $cdir);
    write_text("$cdir/clone-only.txt", "clone ahead\n");
    _git($scn->{home}, $cdir, 'add', '-A');
    _git($scn->{home}, $cdir, 'commit', '-q', '-m', 'clone-only commit');
    $scn->{clone_dir} = $cdir;

    my $live_head_before   = head_sha($scn->{home}, $scn->{ccpx});
    my $clone_head_before  = head_sha($scn->{home}, $cdir);
    my $live_status_before = status_of($scn->{home}, $scn->{ccpx});
    my $clone_status_before = status_of($scn->{home}, $cdir);
    isnt($clone_head_before, $live_head_before, "(setup) AC7: the clone and live HEADs genuinely differ (answer=$case->{answer})");

    my $resp = run_backup($scn, {});
    is($resp->{exit}, 10, "AC7: clone/live divergence pauses the run (answer=$case->{answer})")
        or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of($resp);
    my $d = find_decision(\@decs, 'preflight.clone_live_divergence');
    if (defined $d) {
        is($d->{kind}, 'clone_live_divergence', "AC7: decision kind == clone_live_divergence (answer=$case->{answer})");
        like(($d->{data}{clone_head} // ''), qr/^[0-9a-f]{7,40}$/, "AC7: data.clone_head is present and sha-shaped (answer=$case->{answer})");
        like(($d->{data}{live_head}  // ''), qr/^[0-9a-f]{7,40}$/, "AC7: data.live_head is present and sha-shaped (answer=$case->{answer})");
        isnt(($d->{data}{clone_head} // ''), ($d->{data}{live_head} // ''), "AC7: data carries two DIFFERENT shas (answer=$case->{answer})");
    } else {
        ok(0, "AC7: a preflight.clone_live_divergence decision is present (answer=$case->{answer})");
    }

    my $token = $resp->{json}{resume_token};
    my $resp2 = run_backup($scn, {}, '--resume', ($token // ''), '--answer', "preflight.clone_live_divergence=$case->{answer}");
    ok($case->{exit_ok}->($resp2->{exit}), "AC8: the run reaches its expected terminal status under answer=$case->{answer}")
        or diag($resp2->{out} . $resp2->{err});

    is(head_sha($scn->{home}, $scn->{ccpx}), $live_head_before,  "AC8: live HEAD unchanged after answer=$case->{answer}");
    is(head_sha($scn->{home}, $cdir),        $clone_head_before, "AC8: clone HEAD unchanged after answer=$case->{answer}");
    is(status_of($scn->{home}, $scn->{ccpx}), $live_status_before,  "AC8: live git status --porcelain unchanged after answer=$case->{answer}");
    is(status_of($scn->{home}, $cdir),        $clone_status_before, "AC8: clone git status --porcelain unchanged after answer=$case->{answer}");
}

{
    # AC9a -- genuinely nothing to find: no BACKUP_CLONE_DIR, and the running
    # module's own tree (the scratch phases/ dir) is not a git repo at all.
    my $r = setup_root(with_origin => 0);
    my $resp = run_backup($r, {});
    ok(($resp->{exit} == 0 || $resp->{exit} == 20), 'AC9a: a run with no clone locatable reaches a terminal status')
        or diag($resp->{out} . $resp->{err});
    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $cl = $state->{phases}{preflight}{items}{clone_live}{data};
        if (defined $cl) {
            is($cl->{checked}, 0, 'AC9a: clone_live.checked == 0');
        } else {
            ok(0, 'AC9a: clone_live.checked == 0 (no checkpoint)');
        }
    } else {
        ok(0, 'AC9a: clone_live.checked == 0 (no state)');
    }
    my @decs = decisions_of($resp);
    ok(!(grep { ($_->{kind} // '') eq 'clone_live_divergence' } @decs), 'AC9a: no clone_live_divergence decision is emitted');
}

# ---------------------------------------------------------------------------
# AC9b -- the REAL, un-hinted resolution path (spec S2.6 rule 2: "else the
# tree containing the running module -- dirname(dirname(abs_path(__FILE__)))
# -- if it contains .git and differs from <root>"), exercised WITHOUT
# BACKUP_CLONE_DIR. This is the legitimate real-world case: a developer runs
# `backup.pl` directly from their OWN clone (this repo's own layout,
# <clone>/scripts/backup/Preflight.pm) while <root> (HOME-anchored, spec
# S2.3) points at a DIFFERENT tree (the live install). Per the coordinator's
# finding, the shipped rule-2 resolution is broken -- MUST currently fail.
# ---------------------------------------------------------------------------
{
    my $r = setup_root(with_origin => 0);
    my $devclone = "$r->{scratch}/real-dev-clone";
    _git_clone($r->{home}, $r->{ccpx}, $devclone);
    write_text("$devclone/devclone-only-file.txt", "devclone ahead of live\n");
    _git($r->{home}, $devclone, 'add', '-A');
    _git($r->{home}, $devclone, 'commit', '-q', '-m', 'devclone-only commit');

    # Mirror production's REAL directory depth: <devclone>/scripts/backup/Preflight.pm,
    # exactly like this repo's own scripts/backup/Preflight.pm relative to its
    # own repo root -- so a CORRECTLY dirname-counting resolver would land back
    # on $devclone (which has .git and differs from <root> == $r->{ccpx}).
    my $devclone_phase_dir = "$devclone/scripts/backup";
    copy_preflight_into($devclone_phase_dir);

    my $devclone_head = head_sha($r->{home}, $devclone);
    my $live_head      = head_sha($r->{home}, $r->{ccpx});
    isnt($devclone_head, $live_head, '(setup) AC9b: the dev-clone and live HEADs genuinely differ');

    # Deliberately NO BACKUP_CLONE_DIR -- this is the un-hinted path.
    my $resp = run_backup($r, { BACKUP_PHASE_DIR => $devclone_phase_dir });
    is($resp->{exit}, 10,
        'AC9b: the REAL un-hinted resolution path (no BACKUP_CLONE_DIR) locates the dev clone and pauses')
        or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of($resp);
    my $d = find_decision(\@decs, 'preflight.clone_live_divergence');
    ok((defined $d), 'AC9b: a preflight.clone_live_divergence decision is present WITHOUT any BACKUP_CLONE_DIR hint')
        or diag('this is spec S2.6 rule 2 (the auto-detect fallback) -- ' .
                'coordinator-confirmed broken (Preflight.pm:430-439, off-by-one dirname): ' . $resp->{out});
}

# ===========================================================================
# AC10, AC11 -- the two doc checks are separate files (README.md vs
# docs/repo-layout.md), both produce readme_drift decisions, and
# gen-readme-tree.pl is NEVER invoked with --write/--bootstrap.
# ===========================================================================
{
    my $r = setup_root(with_origin => 0);
    my $extra = {
        STUB_LINT_EXIT   => 1,
        STUB_LINT_STDERR => "README.md:12: missing path scripts/does-not-exist.pl\n",
        STUB_TREE_EXIT   => 1,
        STUB_TREE_STDOUT => "tree drift detected\n",
        STUB_TREE_STDERR => "docs/repo-layout.md is stale\n",
    };
    my $resp = run_backup($r, $extra);
    is($resp->{exit}, 10, 'AC10: README + tree drift pauses the run (exit 10)') or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of($resp);
    my $dr = find_decision(\@decs, 'preflight.readme_paths');
    my $dt = find_decision(\@decs, 'preflight.repo_layout_tree');
    if (defined $dr) {
        is($dr->{kind}, 'readme_drift', 'AC10: preflight.readme_paths kind == readme_drift');
        like(($dr->{subject} // ''), qr/README\.md/, 'AC10: preflight.readme_paths subject names README.md');
        like(($dr->{detail} // ''), qr/does-not-exist\.pl/, 'AC10: preflight.readme_paths detail carries the linter stderr');
    } else {
        ok(0, 'AC10: a preflight.readme_paths decision is present');
        ok(0, 'AC10: preflight.readme_paths subject names README.md');
        ok(0, 'AC10: preflight.readme_paths detail carries the linter stderr');
    }
    if (defined $dt) {
        is($dt->{kind}, 'readme_drift', 'AC10: preflight.repo_layout_tree kind == readme_drift');
        like(($dt->{subject} // ''), qr{docs/repo-layout\.md}, 'AC10: preflight.repo_layout_tree subject names docs/repo-layout.md');
    } else {
        ok(0, 'AC10: a preflight.repo_layout_tree decision is present (second, distinct)');
        ok(0, 'AC10: preflight.repo_layout_tree subject names docs/repo-layout.md');
    }
    if (defined $dr && defined $dt) {
        isnt($dr->{id}, $dt->{id}, 'AC10: the two readme_drift decisions have distinct ids');
    } else {
        ok(0, 'AC10: the two readme_drift decisions have distinct ids');
    }

    my @tree_lines = grep { /^gen-readme-tree\.pl/ } log_lines($r->{log_path});
    ok(scalar(@tree_lines) > 0, 'AC11: gen-readme-tree.pl stub was invoked at least once');
    ok(!(grep { /--write|--bootstrap/ } @tree_lines),
        'AC11: gen-readme-tree.pl was never invoked with --write or --bootstrap (initial pause)');
    my $readme_before = read_text("$r->{ccpx}/README.md");
    my $tree_before    = read_text("$r->{ccpx}/docs/repo-layout.md");

    my $token = $resp->{json}{resume_token};
    my $resp2 = run_backup($r, $extra, '--resume', ($token // ''),
        '--answer', 'preflight.readme_paths=acknowledge',
        '--answer', 'preflight.repo_layout_tree=acknowledge');
    ok(($resp2->{exit} == 0 || $resp2->{exit} == 20), 'AC10: acknowledging both drift decisions reaches a terminal status')
        or diag($resp2->{out} . $resp2->{err});

    my @tree_lines2 = grep { /^gen-readme-tree\.pl/ } log_lines($r->{log_path});
    ok(!(grep { /--write|--bootstrap/ } @tree_lines2),
        'AC11: gen-readme-tree.pl was never invoked with --write or --bootstrap (across the resumed run)');
    is(read_text("$r->{ccpx}/README.md"), $readme_before, 'AC11: README.md bytes are unchanged before/after the whole run');
    is(read_text("$r->{ccpx}/docs/repo-layout.md"), $tree_before, 'AC11: docs/repo-layout.md bytes are unchanged before/after the whole run');
}

# ===========================================================================
# AC12 -- settings-key fixture: 3 undecided (one per relation) + 2 auto_applied.
# ===========================================================================
{
    my $filterdiff_json = encode_json({
        status         => 'filtered',
        auto_applied   => [
            { key => 'k_auto1', category => 'diverged',  action => 'skip-always' },
            { key => 'k_auto2', category => 'only_left', action => 'left-only' },
        ],
        needs_decision => {
            diverged   => { k_div   => { left => 'a', right => 'b' } },
            only_left  => { k_left  => 'x' },
            only_right => { k_right => 'y' },
        },
        has_undecided  => JSON::PP::true,
    });
    my $r = setup_root(with_origin => 0);
    my $extra = { STUB_FILTERDIFF_JSON => $filterdiff_json };
    my $resp = run_backup($r, $extra);
    is($resp->{exit}, 10, 'AC12: undecided settings keys pause the run (exit 10)') or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of($resp);
    my @settings_decs = grep { ($_->{kind} // '') eq 'settings_key' } @decs;
    is(scalar(@settings_decs), 3, 'AC12: exactly three settings_key decisions') or diag($resp->{out});

    my $d_div   = find_decision(\@decs, 'preflight.settings.k_div');
    my $d_left  = find_decision(\@decs, 'preflight.settings.k_left');
    my $d_right = find_decision(\@decs, 'preflight.settings.k_right');
    if (defined $d_div) {
        is($d_div->{data}{relation}, 'diverged', 'AC12: k_div data.relation == diverged');
        my %cid = map { $_->{id} => 1 } @{ $d_div->{choices} // [] };
        ok(($cid{use_live} && $cid{use_repo} && $cid{keep_different_remember} && $cid{skip}),
            'AC12: k_div (diverged) choice ids include use_live/use_repo/keep_different_remember/skip');
    } else {
        ok(0, 'AC12: preflight.settings.k_div decision is present');
        ok(0, 'AC12: k_div choice ids include use_live/use_repo/keep_different_remember/skip');
    }
    if (defined $d_left) {
        is($d_left->{data}{relation}, 'only_left', 'AC12: k_left data.relation == only_left');
        my %cid = map { $_->{id} => 1 } @{ $d_left->{choices} // [] };
        ok(($cid{export_to_repo} && $cid{keep_live_only_remember} && $cid{skip}),
            'AC12: k_left (only_left) choice ids include export_to_repo/keep_live_only_remember/skip');
    } else {
        ok(0, 'AC12: preflight.settings.k_left decision is present');
        ok(0, 'AC12: k_left choice ids include export_to_repo/keep_live_only_remember/skip');
    }
    if (defined $d_right) {
        is($d_right->{data}{relation}, 'only_right', 'AC12: k_right data.relation == only_right');
        my %cid = map { $_->{id} => 1 } @{ $d_right->{choices} // [] };
        # Ruling P6: the choice that adds the repo value to live is named
        # 'add_to_live' (SKILL.md:120 -- "Add to live"), NOT 'keep_in_repo' --
        # the old id/label falsely claimed live is left unchanged when the
        # code actually writes it (spec S8 P6).
        ok(($cid{add_to_live} && $cid{keep_repo_only_remember} && $cid{skip}),
            'AC12 (P6): k_right (only_right) choice ids include add_to_live/keep_repo_only_remember/skip');
        my ($add_choice) = grep { $_->{id} eq 'add_to_live' } @{ $d_right->{choices} // [] };
        if (defined $add_choice) {
            unlike(($add_choice->{label} // ''), qr/unchanged/i,
                'AC12 (P6): the add_to_live label no longer claims live is left unchanged');
        } else {
            ok(0, 'AC12 (P6): the add_to_live label no longer claims live is left unchanged');
        }
    } else {
        ok(0, 'AC12 (P6): preflight.settings.k_right decision is present');
        ok(0, 'AC12 (P6): k_right choice ids include add_to_live/keep_repo_only_remember/skip');
        ok(0, 'AC12 (P6): the add_to_live label no longer claims live is left unchanged');
    }

    if (defined $d_div) {
        my ($use_repo_choice) = grep { $_->{id} eq 'use_repo' } @{ $d_div->{choices} // [] };
        if (defined $use_repo_choice) {
            unlike(($use_repo_choice->{label} // ''), qr/unchanged/i,
                'AC12 (P6): the use_repo (diverged) label no longer claims live is left unchanged');
        } else {
            ok(0, 'AC12 (P6): the use_repo (diverged) label no longer claims live is left unchanged');
        }
    } else {
        ok(0, 'AC12 (P6): the use_repo (diverged) label no longer claims live is left unchanged');
    }

    ok(!(defined find_decision(\@decs, 'preflight.settings.k_auto1')), 'AC12: no decision for the auto-applied key k_auto1');
    ok(!(defined find_decision(\@decs, 'preflight.settings.k_auto2')), 'AC12: no decision for the auto-applied key k_auto2');

    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $note = find_note($state, 'settings_auto_applied');
        if (defined $note) {
            like(encode_json($note->{value}), qr/k_auto1/, 'AC12: the settings_auto_applied note mentions k_auto1');
            like(encode_json($note->{value}), qr/k_auto2/, 'AC12: the settings_auto_applied note mentions k_auto2');
        } else {
            ok(0, 'AC12: a settings_auto_applied note is present');
            ok(0, 'AC12: the settings_auto_applied note mentions k_auto2');
        }
    } else {
        ok(0, 'AC12: a settings_auto_applied note is present (no state)');
        ok(0, 'AC12: the settings_auto_applied note mentions k_auto2 (no state)');
    }
}

# ===========================================================================
# AC13 -- marketplace-diff fixture: 2 undecided (live_only + diverged) + 1
# auto_applied.
# ===========================================================================
{
    my $marketplace_json = encode_json({
        status       => 'different',
        live         => 'live.json', repo => 'repo.json',
        live_only    => [ { name => 'mp1', source => 'github:org/mp1' } ],
        repo_only    => [],
        diverged     => [ { name => 'mp2', live => { source => 'a' }, repo => { source => 'b' } } ],
        identical    => [],
        auto_applied => [ { name => 'mp3', category => 'only_left', action => 'left-only' } ],
    });
    my $r = setup_root(with_origin => 0);
    my $extra = { STUB_MARKETPLACE_JSON => $marketplace_json };
    my $resp = run_backup($r, $extra);
    is($resp->{exit}, 10, 'AC13: undecided marketplace entries pause the run (exit 10)') or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of($resp);
    my @mkt_decs = grep { ($_->{kind} // '') eq 'marketplace_key' } @decs;
    is(scalar(@mkt_decs), 2, 'AC13: exactly two marketplace_key decisions') or diag($resp->{out});

    ok((defined find_decision(\@decs, 'preflight.marketplace.mp1')), 'AC13: a preflight.marketplace.mp1 decision is present (live_only)');
    ok((defined find_decision(\@decs, 'preflight.marketplace.mp2')), 'AC13: a preflight.marketplace.mp2 decision is present (diverged)');
    ok(!(defined find_decision(\@decs, 'preflight.marketplace.mp3')), 'AC13: no decision for the auto-applied entry mp3');

    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $note = find_note($state, 'marketplace_auto_applied');
        if (defined $note) {
            like(encode_json($note->{value}), qr/mp3/, 'AC13: the marketplace_auto_applied note mentions mp3');
        } else {
            ok(0, 'AC13: a marketplace_auto_applied note is present');
        }
    } else {
        ok(0, 'AC13: a marketplace_auto_applied note is present (no state)');
    }
}

# ===========================================================================
# AC14 -- end-to-end preference round trip using the REAL json-diff.pl /
# filter-diff.pl / save-preference.pl.
# ===========================================================================
{
    my $r = setup_root(
        with_origin       => 0,
        live_settings     => qq({"theme":"dark"}\n),
        repo_settings     => qq({"theme":"light"}\n),
        real_pref_scripts => 1,
    );
    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, 'AC14: a real diverged settings key pauses the run (exit 10)') or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of($resp);
    my $d = find_decision(\@decs, 'preflight.settings.theme');
    ok((defined $d), 'AC14: a preflight.settings.theme decision is present (real json-diff/filter-diff)') or diag($resp->{out});

    my $token = $resp->{json}{resume_token};
    my $resp2 = run_backup($r, {}, '--resume', ($token // ''), '--answer', 'preflight.settings.theme=keep_different_remember');
    ok(($resp2->{exit} == 0 || $resp2->{exit} == 20), 'AC14: answering keep_different_remember reaches a terminal status')
        or diag($resp2->{out} . $resp2->{err});

    my $prefs = read_state("$r->{ccpx}/.backup-preferences.json");
    if (defined $prefs) {
        my $entry = $prefs->{live_vs_repo}{theme};
        if (defined $entry) {
            is($entry->{category}, 'diverged',   'AC14: .backup-preferences.json[live_vs_repo][theme].category == diverged');
            is($entry->{action},   'skip-always', 'AC14: .backup-preferences.json[live_vs_repo][theme].action == skip-always');
        } else {
            ok(0, 'AC14: .backup-preferences.json[live_vs_repo][theme] is present');
            ok(0, 'AC14: .backup-preferences.json[live_vs_repo][theme].action == skip-always');
        }
    } else {
        ok(0, 'AC14: .backup-preferences.json exists and parses (real save-preference.pl ran)');
        ok(0, 'AC14: .backup-preferences.json[live_vs_repo][theme].action == skip-always');
    }

    # A second full run: per package 01's R1 ruling, a bare `run` against a
    # TERMINAL state starts fresh -- this IS "a second full run of the phase".
    my $resp3 = run_backup($r, {});
    ok(($resp3->{exit} == 0 || $resp3->{exit} == 20), 'AC14: the second run reaches a terminal status')
        or diag($resp3->{out} . $resp3->{err});
    isnt(($resp3->{json}{status} // ''), 'needs_decision', 'AC14: the second run emits NO decision for the now-preferenced key');
    my $state3 = read_state($r->{state_path});
    if (defined $state3) {
        my $note = find_note($state3, 'settings_auto_applied');
        if (defined $note) {
            like(encode_json($note->{value}), qr/theme/, 'AC14: the second run lists theme in settings_auto_applied');
        } else {
            ok(0, 'AC14: the second run lists theme in settings_auto_applied');
        }
    } else {
        ok(0, 'AC14: the second run lists theme in settings_auto_applied (no state)');
    }
}

# ===========================================================================
# AC15 -- settings_outcome.data.skip_keys membership.
#
# Coordinator ruling (post-review): keep_repo_only_remember DOES add its key
# to skip_keys -- AC15.s blanket wording wins over the S2.6 row that omitted
# saying so, per SKILL.md Step 1.5 (passing a skipped only_right key is
# harmless, so "when in doubt pass them all"). Exercised below alongside the
# unambiguous representatives from every relation.
# ===========================================================================
{
    my $filterdiff_json = encode_json({
        status         => 'filtered',
        auto_applied   => [],
        needs_decision => {
            diverged => {
                k_use_repo     => { left => 'L', right => 'R' },
                k_use_live     => { left => 'L', right => 'R' },
                k_remember_div => { left => 'L', right => 'R' },
                k_skip_div     => { left => 'L', right => 'R' },
            },
            only_left => {
                k_export        => 'x',
                k_remember_left => 'x',
                k_skip_left     => 'x',
            },
            only_right => {
                k_keep           => q(y),
                k_skip_right     => q(y),
                k_remember_right => q(y),
            },
        },
        has_undecided => JSON::PP::true,
    });
    my $r = setup_root(with_origin => 0);
    my $extra = { STUB_FILTERDIFF_JSON => $filterdiff_json };
    my $resp = run_backup($r, $extra);
    is($resp->{exit}, 10, 'AC15: a large settings batch pauses the run (exit 10)') or diag($resp->{out} . $resp->{err});

    my $token = $resp->{json}{resume_token};
    my @answers = (
        'preflight.settings.k_use_repo=use_repo',
        'preflight.settings.k_use_live=use_live',
        'preflight.settings.k_remember_div=keep_different_remember',
        'preflight.settings.k_skip_div=skip',
        'preflight.settings.k_export=export_to_repo',
        'preflight.settings.k_remember_left=keep_live_only_remember',
        'preflight.settings.k_skip_left=skip',
        q(preflight.settings.k_keep=add_to_live),   # P6: renamed from keep_in_repo
        q(preflight.settings.k_skip_right=skip),
        q(preflight.settings.k_remember_right=keep_repo_only_remember),
    );
    my @resume_args = ('--resume', ($token // ''));
    push @resume_args, ('--answer', $_) for @answers;
    my $resp2 = run_backup($r, $extra, @resume_args);
    ok(($resp2->{exit} == 0 || $resp2->{exit} == 20), 'AC15: answering the whole batch reaches a terminal status')
        or diag($resp2->{out} . $resp2->{err});

    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $data = $state->{phases}{preflight}{items}{settings_outcome}{data};
        is(ref($data), 'HASH',
            'AC15: settings_outcome.data is readable at phases.preflight.items.settings_outcome.data once the run completes');
        my $sk = ref($data) eq 'HASH' ? $data->{skip_keys} : undef;
        if (ref($sk) eq 'ARRAY') {
            my %in = map { $_ => 1 } @$sk;
            for my $k (qw(k_use_repo k_remember_div k_skip_div k_remember_left k_skip_left k_skip_right k_remember_right)) {
                ok($in{$k}, "AC15: skip_keys contains '$k'");
            }
            for my $k (qw(k_use_live k_export k_keep)) {
                ok(!$in{$k}, "AC15: skip_keys excludes '$k'");
            }
        } else {
            ok(0, 'AC15: settings_outcome.data.skip_keys is an array') for 1 .. 10;
        }
    } else {
        ok(0, 'AC15: settings_outcome.data is readable (no state)');
        ok(0, 'AC15: settings_outcome.data.skip_keys is an array') for 1 .. 10;
    }

    # keep_repo_only_remember must ALSO save the preference (coordinator
    # ruling: --scope live_vs_repo --category only_right --action right-only),
    # not just add the key to skip_keys.
    my @savepref_lines = grep { /^save-preference\.pl/ } log_lines($r->{log_path});
    my ($remember_line) = grep { /--key\s+k_remember_right\b/ } @savepref_lines;
    if (defined $remember_line) {
        like($remember_line, qr/--scope\s+live_vs_repo\b/,
            'AC15: keep_repo_only_remember invokes save-preference.pl with --scope live_vs_repo');
        like($remember_line, qr/--category\s+only_right\b/,
            'AC15: keep_repo_only_remember invokes save-preference.pl with --category only_right');
        like($remember_line, qr/--action\s+right-only\b/,
            'AC15: keep_repo_only_remember invokes save-preference.pl with --action right-only');
    } else {
        ok(0, 'AC15: keep_repo_only_remember invokes save-preference.pl with --scope live_vs_repo');
        ok(0, 'AC15: keep_repo_only_remember invokes save-preference.pl with --category only_right');
        ok(0, 'AC15: keep_repo_only_remember invokes save-preference.pl with --action right-only');
    }
}

# ===========================================================================
# AC17 -- id grammar, unsanitised subject/data.key, sanitisation collision.
# (AC16's dynamic half -- validate_decision over every produced decision --
# rides along here too.)
# ===========================================================================
{
    my $filterdiff_json = encode_json({
        status         => 'filtered',
        auto_applied   => [],
        needs_decision => {
            diverged => {
                'weird key//x' => { left => 'L', right => 'R' },
                'a b'          => { left => 'L', right => 'R' },
                'a/b'          => { left => 'L', right => 'R' },
            },
            only_left => {}, only_right => {},
        },
        has_undecided => JSON::PP::true,
    });
    my $r = setup_root(with_origin => 0);
    my $extra = { STUB_FILTERDIFF_JSON => $filterdiff_json };
    my $resp = run_backup($r, $extra);
    is($resp->{exit}, 10, 'AC17: a weird-key settings batch pauses the run (exit 10)') or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of($resp);
    my @settings_decs = grep { ($_->{kind} // '') eq 'settings_key' } @decs;

    for my $d (@settings_decs) {
        like($d->{id}, qr/^preflight\./, "AC17: id '$d->{id}' begins with preflight.");
        like($d->{id}, qr/^[A-Za-z0-9][A-Za-z0-9_.:-]*$/, "AC17: id '$d->{id}' matches the full grammar");
    }

    my ($weird) = grep { ($_->{data}{key} // '') eq 'weird key//x' } @settings_decs;
    if (defined $weird) {
        is($weird->{subject}, 'weird key//x', 'AC17: the weird key survives unsanitised in subject');
        is($weird->{data}{key}, 'weird key//x', 'AC17: the weird key survives unsanitised in data.key');
    } else {
        ok(0, 'AC17: a decision carries the unsanitised weird key in subject/data.key');
        ok(0, 'AC17: the weird key survives unsanitised in data.key');
    }

    my @collide = grep { ($_->{data}{key} // '') eq 'a b' || ($_->{data}{key} // '') eq 'a/b' } @settings_decs;
    is(scalar(@collide), 2, 'AC17: both colliding keys (a b / a/b) produced a decision each') or diag($resp->{out});
    if (scalar(@collide) == 2) {
        my %ids = map { $_->{id} => 1 } @collide;
        is(scalar(keys %ids), 2, 'AC17: the two colliding keys got two DISTINCT ids');
        ok((grep { /\.2$/ } keys %ids), 'AC17: one of the colliding ids carries the .2 disambiguation suffix');
    } else {
        ok(0, 'AC17: the two colliding keys got two DISTINCT ids');
        ok(0, 'AC17: one of the colliding ids carries the .2 disambiguation suffix');
    }

    if ($RUNPM_OK) {
        for my $d (@settings_decs) {
            my ($ok2, $reason) = Backup::Run::validate_decision({ %$d });
            ok($ok2, "AC16: decision '$d->{id}' passes Backup::Run::validate_decision") or diag($reason // '(none)');
        }
    } else {
        ok(0, "AC16: settings decisions pass Backup::Run::validate_decision (Run.pm not loaded)");
    }
}

# ===========================================================================
# AC18 -- resume: no wrapped script re-runs; no duplicated {phase,key} note.
# ===========================================================================
{
    my $filterdiff_json = encode_json({
        status => 'filtered', auto_applied => [],
        needs_decision => { diverged => { k1 => { left => 'a', right => 'b' } }, only_left => {}, only_right => {} },
        has_undecided => JSON::PP::true,
    });
    my $r = setup_root(with_origin => 0);
    my $extra = {
        STUB_LINT_EXIT        => 1, STUB_LINT_STDERR => "missing\n",
        STUB_TREE_EXIT        => 1, STUB_TREE_STDERR => "stale\n",
        STUB_FILTERDIFF_JSON  => $filterdiff_json,
    };
    my $resp = run_backup($r, $extra);
    is($resp->{exit}, 10, '(setup) AC18: a combined batch pauses the run') or diag($resp->{out} . $resp->{err});
    my %counts_before = log_counts($r->{log_path});

    my $token = $resp->{json}{resume_token};
    my @decs  = decisions_of($resp);
    my @answer_args;
    for my $d (@decs) {
        my @cids = map { $_->{id} } @{ $d->{choices} // [] };
        my ($ack) = grep { $_ eq 'acknowledge' } @cids;
        my $choice = defined $ack ? $ack : ($d->{id} eq 'preflight.settings.k1' ? 'use_live' : $cids[0]);
        push @answer_args, ('--answer', "$d->{id}=$choice");
    }
    my $resp2 = run_backup($r, $extra, '--resume', ($token // ''), @answer_args);
    ok(($resp2->{exit} == 0 || $resp2->{exit} == 20), 'AC18: resuming the batch reaches a terminal status')
        or diag($resp2->{out} . $resp2->{err});

    my %counts_after = log_counts($r->{log_path});
    for my $script (sort keys %counts_before) {
        is($counts_after{$script} // 0, $counts_before{$script},
            "AC18: '$script' invocation count is unchanged by the resume (no wrapped script re-runs)");
    }

    my $state_after = read_state($r->{state_path});
    if (defined $state_after) {
        my %seen;
        my $dup = 0;
        for my $n (notes_of_state($state_after)) {
            my $sig = ($n->{phase} // '') . "\x00" . ($n->{key} // '');
            $dup++ if $seen{$sig}++;
        }
        is($dup, 0, 'AC18: the completed run notes array contains no duplicated {phase,key} pair');
    } else {
        ok(0, 'AC18: the completed run notes array contains no duplicated {phase,key} pair (no state)');
    }
}

# ===========================================================================
# AC19 -- two pauses in one run: every stub still runs exactly once.
# ===========================================================================
{
    my $r = setup_root(with_origin => 1, dirty => 1);
    my $extra = {
        STUB_LINT_EXIT => 1, STUB_LINT_STDERR => "missing\n",
        STUB_TREE_EXIT => 1, STUB_TREE_STDERR => "stale\n",
    };
    my $resp1 = run_backup($r, $extra);
    is($resp1->{exit}, 10, '(setup) AC19: first pause is the dirty_worktree decision') or diag($resp1->{out} . $resp1->{err});
    my @decs1 = decisions_of($resp1);
    is(($decs1[0]{kind} // ''), 'dirty_worktree', 'AC19: first pause kind == dirty_worktree');
    is(log_line_count($r->{log_path}), 0, 'AC19: nothing has been spawned before the first pause');

    my $token1 = $resp1->{json}{resume_token};
    my $resp2  = run_backup($r, $extra, '--resume', ($token1 // ''), '--answer', 'preflight.dirty_worktree=continue_without_merge');
    is($resp2->{exit}, 10, 'AC19: the SECOND pause (the batch) follows the first resume') or diag($resp2->{out} . $resp2->{err});
    # ccpraxis-helpers.pl backs THREE units (sync-skills U5, check-claude-md
    # U6, marketplace-diff U8 -- spec S2.5's unit table), so its count is
    # always 3 where every other wrapped script here backs exactly one unit
    # and so is expected exactly once.
    my %expected_between_pauses = (
        'lint-readme-paths.pl' => 1,
        'gen-readme-tree.pl'   => 1,
        'ccpraxis-helpers.pl'  => 3,
        'json-diff.pl'         => 1,
        'filter-diff.pl'       => 1,
    );
    my %counts_mid = log_counts($r->{log_path});
    for my $script (sort keys %expected_between_pauses) {
        is($counts_mid{$script} // 0, $expected_between_pauses{$script},
            "AC19: '$script' ran exactly $expected_between_pauses{$script} time(s) between the two pauses");
    }

    my @decs2 = decisions_of($resp2);
    my @answer_args;
    for my $d (@decs2) {
        my ($choice) = map { $_->{id} } @{ $d->{choices} // [] };
        push @answer_args, ('--answer', "$d->{id}=$choice") if defined $choice;
    }
    my $token2 = $resp2->{json}{resume_token};
    my $resp3  = run_backup($r, $extra, '--resume', ($token2 // ''), @answer_args);
    ok(($resp3->{exit} == 0 || $resp3->{exit} == 20), 'AC19: the second resume reaches a terminal status')
        or diag($resp3->{out} . $resp3->{err});

    my %counts_final = log_counts($r->{log_path});
    for my $script (sort keys %expected_between_pauses) {
        is($counts_final{$script} // 0, $expected_between_pauses{$script},
            "AC19: '$script' is STILL at $expected_between_pauses{$script} time(s) after the second resume (no re-run)");
    }
}

# ===========================================================================
# AC20 -- R6 re-entry: a mid-phase death (state-file surgery per spec S6.8,
# not a real kill) clears items+preflight.* answers; the phase re-executes
# every unit and RE-ASKS rather than replaying the stale answer; the end
# state after answering again matches an uninterrupted run.
# ===========================================================================
{
    my $r = setup_root(
        with_origin       => 1,
        remote_ahead      => 1,
        live_settings     => qq({"theme":"dark"}\n),
        repo_settings     => qq({"theme":"light"}\n),
        real_pref_scripts => 1,
    );
    my $resp1 = run_backup($r, {});
    is($resp1->{exit}, 10, '(setup) AC20: the run pauses once, for the single settings_key decision') or diag($resp1->{out} . $resp1->{err});
    my @decs1 = decisions_of($resp1);
    is(scalar(@decs1), 1, '(setup) AC20: exactly one pending decision (this scenario needs a single preflight.* answer)')
        or diag($resp1->{out});
    my $dec_id = $decs1[0]{id} // '';

    my $origin_head = _git_out($r->{home}, $r->{ccpx}, 'rev-parse', 'origin/main');
    $origin_head =~ s/\s+\z//;
    is(head_sha($r->{home}, $r->{ccpx}), $origin_head,
        '(setup) AC20: the clean-tree auto-merge already advanced HEAD to origin/main');

    my $state = read_state($r->{state_path});
    ok((defined $state), '(setup) AC20: the paused state file exists and parses');
    if (defined $state) {
        $state->{answers}{$dec_id}          = 'keep_different_remember';
        $state->{pending}                   = undef;
        $state->{status}                    = 'running';
        $state->{phases}{preflight}{status} = 'running';
        write_state_raw($r->{state_path}, $state);

        my $resp2 = run_backup($r, {});
        is($resp2->{exit}, 10, 'AC20: re-entry after the simulated crash RE-ASKS rather than completing silently')
            or diag($resp2->{out} . $resp2->{err});
        my @decs2 = decisions_of($resp2);
        is(($decs2[0]{id} // ''), $dec_id, 'AC20: the SAME decision id is re-asked (the stale answer was cleared, not replayed)');

        my $token2 = $resp2->{json}{resume_token};
        my $resp3  = run_backup($r, {}, '--resume', ($token2 // ''), '--answer', "$dec_id=keep_different_remember");
        ok(($resp3->{exit} == 0 || $resp3->{exit} == 20), 'AC20: answering again reaches a terminal status')
            or diag($resp3->{out} . $resp3->{err});
        is(($resp3->{json}{status} // ''), 'complete',
            'AC20: the end state matches an uninterrupted run (status == complete, no double-run failure)');

        my $prefs = read_state("$r->{ccpx}/.backup-preferences.json");
        if (defined $prefs) {
            my $n = 0;
            for my $scope (keys %$prefs) {
                $n++ if grep { $_ eq 'theme' } keys %{ $prefs->{$scope} };
            }
            is($n, 1, 'AC20: .backup-preferences.json holds exactly one entry for the remembered key (not doubled by the re-ask)');
        } else {
            ok(0, 'AC20: .backup-preferences.json holds exactly one entry for the remembered key');
        }

        is(head_sha($r->{home}, $r->{ccpx}), $origin_head,
            'AC20: HEAD still equals origin/main -- the re-run merge was a no-op, not a second real merge');
    } else {
        ok(0, "AC20: $_") for (
            're-entry after the simulated crash RE-ASKS rather than completing silently',
            'the SAME decision id is re-asked', 'answering again reaches a terminal status',
            'the end state matches an uninterrupted run', 'the remembered key appears exactly once',
            'HEAD still equals origin/main',
        );
    }
}

# ===========================================================================
# AC21, AC22 -- the parity artifact. Static file, Decision 13's fixed shape.
# ===========================================================================
{
    if (-f $PARITY_FILE) {
        ok(1, 'AC21: reports/parity/02-preflight-and-config.md exists');
        my $body = read_text($PARITY_FILE) // '';
        my @lines = split /\n/, $body;

        my ($hidx) = grep { $lines[$_] eq '| old step | phase | module | note |' } 0 .. $#lines;
        ok((defined $hidx), 'AC21: the literal header row is present') or diag($body);

        if (defined $hidx) {
            is(($lines[$hidx + 1] // ''), '|---|---|---|---|',
                'AC21: the literal separator row immediately follows the header');
            my @data_lines = grep { /^\|/ } @lines[$hidx + 2 .. $#lines];
            is(scalar(@data_lines), 3, 'AC21: exactly three data rows') or diag(join("\n", @data_lines));

            my @firsts;
            for my $line (@data_lines) {
                my @fields = split /\|/, $line, -1;
                is(scalar(@fields), 6, "AC21: row '$line' splits on '|' into six fields");
                next unless @fields == 6;
                my @t = map { my $x = $_; $x =~ s/^\s+|\s+$//g; $x } @fields;
                is($t[0], '', "AC21: row '$line' first split field is empty");
                is($t[5], '', "AC21: row '$line' last split field is empty");
                is($t[2], 'preflight', "AC21: row '$line' phase cell == preflight");
                is($t[3], 'scripts/backup/Preflight.pm', "AC21: row '$line' module cell == scripts/backup/Preflight.pm");
                ok(length($t[4]) > 0, "AC21: row '$line' note cell is non-empty");
                unlike($line, qr/\R/, "AC21: row '$line' contains no embedded newline");
                push @firsts, $t[1];
            }
            is(join(',', @firsts), '1,1.2,1.5', 'AC21: the three old-step cells are exactly 1, 1.2, 1.5 in order');
        } else {
            ok(0, 'AC21: the literal separator row immediately follows the header');
            ok(0, 'AC21: exactly three data rows');
            ok(0, 'AC21: the three old-step cells are exactly 1, 1.2, 1.5 in order');
        }

        my $table_markers = () = ($body =~ /^\|---\|---\|---\|---\|$/mg);
        is($table_markers, 1, 'AC21: the file contains no second table (exactly one separator row)');

        my %note_for;
        for my $line (@lines) {
            if ($line =~ m{^\|\s*(1(?:\.2|\.5)?)\s*\|\s*preflight\s*\|\s*scripts/backup/Preflight\.pm\s*\|\s*(.*?)\s*\|\s*$}) {
                $note_for{$1} = $2;
            }
        }
        my $n1 = $note_for{'1'} // '';
        like($n1, qr/clean/i,    'AC22: the "1" note mentions the clean-tree check');
        like($n1, qr/decision/i, 'AC22: the "1" note mentions the dirty_worktree decision');
        like($n1, qr/clone/i,    'AC22: the "1" note mentions the clone/live divergence report');

        my $n12 = $note_for{'1.2'} // '';
        like($n12, qr/README\.md/,             'AC22: the "1.2" note names README.md');
        like($n12, qr{docs/repo-layout\.md},   'AC22: the "1.2" note names docs/repo-layout.md');

        my $n15 = $note_for{'1.5'} // '';
        like($n15, qr/skill/i,       'AC22: the "1.5" note names the skills mirror');
        like($n15, qr/claude\.md/i,  'AC22: the "1.5" note names the CLAUDE.md check');
        like($n15, qr/settings/i,    'AC22: the "1.5" note names the settings diff');
        like($n15, qr/marketplace/i, 'AC22: the "1.5" note names the marketplace diff');
    } else {
        ok(0, 'AC21: reports/parity/02-preflight-and-config.md exists');
        ok(0, "AC21: $_") for (
            'the literal header row is present', 'the literal separator row immediately follows the header',
            'exactly three data rows', 'the three old-step cells are exactly 1, 1.2, 1.5 in order',
            'the file contains no second table (exactly one separator row)',
        );
        ok(0, "AC22: $_") for (
            'the "1" note mentions the clean-tree check', 'the "1" note mentions the dirty_worktree decision',
            'the "1" note mentions the clone/live divergence report', 'the "1.2" note names README.md',
            'the "1.2" note names docs/repo-layout.md', 'the "1.5" note names the skills mirror',
            'the "1.5" note names the CLAUDE.md check', 'the "1.5" note names the settings diff',
            'the "1.5" note names the marketplace diff',
        );
    }
}

# ===========================================================================
# AC24 -- environmental failures never phase_died; complete_with_failures
# instead, with the offending unit(s) named.
# ===========================================================================
{
    # (a) every wrapped script absent.
    my $r = setup_root(with_origin => 0);
    for my $f (qw(
        scripts/lint-readme-paths.pl
        scripts/gen-readme-tree.pl
        plugins/steward/scripts/ccpraxis-helpers.pl
        plugins/steward/scripts/json-diff.pl
        plugins/steward/scripts/filter-diff.pl
        plugins/steward/scripts/save-preference.pl
    )) {
        unlink "$r->{ccpx}/$f";
    }
    my $resp = run_backup($r, {});
    isnt($resp->{exit}, 1, 'AC24(a): every wrapped script missing never yields exit 1 (phase_died)');
    is(($resp->{json}{status} // ''), 'complete_with_failures', 'AC24(a): status == complete_with_failures, never "error"')
        or diag($resp->{out} . $resp->{err});
    unlike($resp->{out}, qr/"status"\s*:\s*"error"/, 'AC24(a): the JSON status is never "error"');
    my $state = read_state($r->{state_path});
    if (defined $state) {
        is($state->{phases}{preflight}{status}, 'failed', 'AC24(a): the phase is recorded failed with the offending units named');
        like(($state->{phases}{preflight}{error} // ''), qr/\w/, 'AC24(a): the phase error names at least one offending unit');
    } else {
        ok(0, 'AC24(a): the phase is recorded failed with the offending units named');
    }
}

for my $case (
    ['lint-readme-paths.pl',                  { STUB_LINT_EXIT => 2 }],
    ['gen-readme-tree.pl',                    { STUB_TREE_EXIT => 2 }],
    ['ccpraxis-helpers.pl (sync-skills)',     { STUB_SYNC_SKILLS_EXIT => 2,
        STUB_SYNC_SKILLS_JSON => '{"status":"partial","platform":"unix","results":[{"name":"x","error":"boom"}],"count":1}' }],
    ['ccpraxis-helpers.pl (marketplace-diff)', { STUB_MARKETPLACE_EXIT => 1, STUB_MARKETPLACE_JSON => '{"status":"different"}' }],
    ['json-diff.pl',                          { STUB_JSONDIFF_EXIT => 2 }],
    ['filter-diff.pl',                        { STUB_FILTERDIFF_EXIT => 2 }],
) {
    my ($label, $extra) = @$case;
    my $r = setup_root(with_origin => 0);
    my $resp = run_backup($r, $extra);
    isnt($resp->{exit}, 1, "AC24(b): a hard failure in $label never yields exit 1 (phase_died)");
    is($resp->{exit}, 20, "AC24(b): a hard failure in $label yields exit 20 (complete_with_failures)")
        or diag($resp->{out} . $resp->{err});
    is(($resp->{json}{status} // ''), 'complete_with_failures', "AC24(b): status == complete_with_failures for $label");
    my $state = read_state($r->{state_path});
    if (defined $state) {
        is($state->{phases}{preflight}{status}, 'failed', "AC24(b): the phase is recorded failed for $label");
    } else {
        ok(0, "AC24(b): the phase is recorded failed for $label");
    }
}

{
    # (c) a helper prints non-JSON garbage.
    my $r = setup_root(with_origin => 0);
    my $extra = { STUB_FILTERDIFF_JSON => 'THIS IS NOT JSON {{{' };
    my $resp = run_backup($r, $extra);
    isnt($resp->{exit}, 1, 'AC24(c): non-JSON stdout from a helper never yields exit 1 (phase_died)');
    is($resp->{exit}, 20, 'AC24(c): non-JSON stdout from a helper yields exit 20 (complete_with_failures)')
        or diag($resp->{out} . $resp->{err});
    is(($resp->{json}{status} // ''), 'complete_with_failures', 'AC24(c): status == complete_with_failures for garbage stdout');
}

# ===========================================================================
# AC25 -- isolation: nothing under the real machine is touched.
# ===========================================================================
{
    my $r = setup_root(with_origin => 0, real_pref_scripts => 1,
        live_settings => qq({"iso":"a"}\n), repo_settings => qq({"iso":"b"}\n));

    isnt($r->{home}, ($REAL_HOME // ''),        'AC25: the scenario HOME is not literally the operator real HOME');
    isnt($r->{home}, ($REAL_USERPROFILE // ''), 'AC25: the scenario HOME is not literally the operator real USERPROFILE');
    like($r->{state_path}, qr/\Q$r->{scratch}\E/, 'AC25: the run-state file path is rooted under the scratch tree');
    like($r->{ccpx},       qr/\Q$r->{scratch}\E/, 'AC25: the ccpraxis root is rooted under the scratch tree');

    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, '(setup) AC25: the real diverged settings key pauses the run') or diag($resp->{out} . $resp->{err});
    my $token = $resp->{json}{resume_token};
    my $resp2 = run_backup($r, {}, '--resume', ($token // ''), '--answer', 'preflight.settings.iso=keep_different_remember');
    ok(($resp2->{exit} == 0 || $resp2->{exit} == 20), 'AC25: the isolated run reaches a terminal status')
        or diag($resp2->{out} . $resp2->{err});

    ok(path_exists($r->{state_path}), 'AC25: the state file was created under the scratch root');
    ok(path_exists("$r->{ccpx}/.backup-preferences.json"), 'AC25: .backup-preferences.json was created under the scratch ccpraxis root');
    like((read_text("$r->{ccpx}/.backup-preferences.json") // ''), qr/iso/,
        'AC25: the preference write actually landed under the scratch root (sanity content check)');

    my $with_origin_r = setup_root(with_origin => 1);
    unlike(($with_origin_r->{remote} // ''), qr{^https?://},
        'AC25: origin is a local path, never a network URL (no network call is possible)');
}

# ===========================================================================
# P1 bounds (coordinator ruling P1) -- write only for an ANSWERED decision;
# installLocation stripped before the marketplace write; instruction-only
# choices stay instructions.
# ===========================================================================
{
    my $r = setup_root(with_origin => 0,
        live_settings     => qq({"k1":"livevalue","k2":"livevalue2"}\n),
        repo_settings     => qq({"k1":"repovalue","k2":"repovalue2"}\n),
        real_pref_scripts => 1,
    );
    my $live_before = read_text("$r->{home}/.claude/settings.json");
    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, '(setup) P1-W1: two diverged keys pause the run') or diag($resp->{out} . $resp->{err});

    is(read_text("$r->{home}/.claude/settings.json"), $live_before,
        'P1 bound 1: no write to live settings.json occurs while the decisions are still UNANSWERED');

    my $token = $resp->{json}{resume_token};
    my @decs  = decisions_of($resp);
    my @answer_args;
    for my $d (@decs) {
        my $choice = (($d->{data}{key} // '') eq 'k1') ? 'use_repo' : 'use_live';
        push @answer_args, ('--answer', "$d->{id}=$choice");
    }
    my $resp2 = run_backup($r, {}, '--resume', ($token // ''), @answer_args);
    ok(($resp2->{exit} == 0 || $resp2->{exit} == 20), 'P1-W1: answering both settings keys reaches a terminal status')
        or diag($resp2->{out} . $resp2->{err});

    my $live_after = read_state("$r->{home}/.claude/settings.json");
    if (defined $live_after) {
        is(($live_after->{k1} // ''), 'repovalue',
            "P1-W1 bound: 'use_repo' wrote the repo value into live settings.json (write happens for an ANSWERED decision)");
        isnt(($live_after->{k2} // ''), 'repovalue2',
            "P1 bound: 'use_live' did NOT write k2 into live settings.json (write is per-decision, never inferred)");
    } else {
        ok(0, "P1-W1 bound: 'use_repo' wrote the repo value into live settings.json");
        ok(0, "P1 bound: 'use_live' did NOT write k2 into live settings.json");
    }
}

{
    my $marketplace_json = encode_json({
        status => 'different', live => 'live.json', repo => 'repo.json',
        live_only => [ { name => 'mp_export', source => 'github:org/mp_export',
                          installLocation => 'C:/Users/somebody/.claude/marketplaces/mp_export' } ],
        repo_only => [], diverged => [], identical => [], auto_applied => [],
    });
    my $r = setup_root(with_origin => 0, repo_marketplaces => "{}\n");
    my $extra = { STUB_MARKETPLACE_JSON => $marketplace_json };
    my $resp = run_backup($r, $extra);
    is($resp->{exit}, 10, '(setup) P1-W2: a live-only marketplace entry pauses the run') or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of($resp);
    ok((defined find_decision(\@decs, 'preflight.marketplace.mp_export')),
        '(setup) P1-W2: a preflight.marketplace.mp_export decision is present');

    my $token = $resp->{json}{resume_token};
    my $resp2 = run_backup($r, $extra, '--resume', ($token // ''), '--answer', 'preflight.marketplace.mp_export=export_to_repo');
    ok(($resp2->{exit} == 0 || $resp2->{exit} == 20), 'P1-W2: answering export_to_repo reaches a terminal status')
        or diag($resp2->{out} . $resp2->{err});

    my $known_raw = read_text("$r->{ccpx}/global-config/known_marketplaces.json");
    if (defined $known_raw) {
        like($known_raw, qr/mp_export/, 'P1-W2: the reconciled known_marketplaces.json contains the exported entry');
        unlike($known_raw, qr/installLocation/, 'P1-W2 bound: installLocation is stripped before W2 writes');
    } else {
        ok(0, 'P1-W2: the reconciled known_marketplaces.json contains the exported entry');
        ok(0, 'P1-W2 bound: installLocation is stripped before W2 writes');
    }
}

{
    my $marketplace_json = encode_json({
        status => 'different', live => 'live.json', repo => 'repo.json',
        live_only => [ { name => 'mp_remove', source => 'github:org/mp_remove' } ],
        repo_only => [], diverged => [], identical => [], auto_applied => [],
    });
    my $r = setup_root(with_origin => 0);
    my $extra = { STUB_MARKETPLACE_JSON => $marketplace_json };
    my $resp = run_backup($r, $extra);
    my $token = $resp->{json}{resume_token};
    my $resp2 = run_backup($r, $extra, '--resume', ($token // ''), '--answer', 'preflight.marketplace.mp_remove=remove_locally');
    ok(($resp2->{exit} == 0 || $resp2->{exit} == 20), 'P1 bound 3: answering remove_locally reaches a terminal status')
        or diag($resp2->{out} . $resp2->{err});
    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $note = find_note($state, 'marketplace_instructions');
        if (defined $note) {
            like(encode_json($note->{value}), qr{/plugin marketplace remove},
                'P1 bound 3: remove_locally is recorded as an INSTRUCTION (/plugin marketplace remove ...)');
        } else {
            ok(0, 'P1 bound 3: remove_locally is recorded as an INSTRUCTION');
        }
    } else {
        ok(0, 'P1 bound 3: remove_locally is recorded as an INSTRUCTION (no state)');
    }
    ok(!(grep { /plugin marketplace/ } log_lines($r->{log_path})),
        'P1 bound 3: no "/plugin marketplace" command was actually executed by a wrapped script (only reported)');
}

# ===========================================================================
# Edge cases from spec S5 (Behaviors 5 and 7 -- not independently numbered
# ACs, but named edge cases the spec calls out explicitly).
# ===========================================================================
{
    my $r = setup_root(with_origin => 0);
    my $resp = run_backup($r, {});
    ok(($resp->{exit} == 0 || $resp->{exit} == 20), 'Behavior 5: no remote configured completes without pausing')
        or diag($resp->{out} . $resp->{err});
    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $ri = $state->{phases}{preflight}{items}{remote_integration}{data};
        if (defined $ri) {
            is($ri->{has_origin}, 0, 'Behavior 5: remote_integration.has_origin == 0 when no origin is configured');
        } else {
            ok(0, 'Behavior 5: remote_integration.has_origin == 0 when no origin is configured');
        }
    } else {
        ok(0, 'Behavior 5: remote_integration.has_origin == 0 (no state)');
    }
}

{
    my $scratch = temproot();
    my $home    = make_machine($scratch, 'host');
    my $ccpx    = "$home/.claude/ccpraxis";
    make_path($ccpx);
    write_text("$ccpx/README.md", default_readme());
    write_text("$ccpx/docs/repo-layout.md", default_tree());
    write_text("$ccpx/global-config/settings.json", "{}\n");
    write_text("$home/.claude/settings.json", "{}\n");
    write_stub_scripts($ccpx);
    my $phase_dir = "$scratch/phases";
    copy_preflight_into($phase_dir);
    my $r = {
        scratch => $scratch, home => $home, ccpx => $ccpx, phase_dir => $phase_dir,
        state_path => "$scratch/state/run.json", log_path => "$scratch/log.txt",
    };
    my $resp = run_backup($r, {});
    ok(($resp->{exit} == 0 || $resp->{exit} == 20), 'Behavior 7: a non-git <root> does not die') or diag($resp->{out} . $resp->{err});
    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $ri = $state->{phases}{preflight}{items}{remote_integration}{data};
        if (defined $ri) {
            is($ri->{is_git_repo}, 0, 'Behavior 7: remote_integration.is_git_repo == 0 for a non-git root');
        } else {
            ok(0, 'Behavior 7: remote_integration.is_git_repo == 0 for a non-git root');
        }
    } else {
        ok(0, 'Behavior 7: remote_integration.is_git_repo == 0 (no state)');
    }
}

# ===========================================================================
# Out of scope (spec S9) -- settings-export-merge belongs to package 03 only.
# ===========================================================================
{
    my $src = $PREFLIGHT_EXISTS ? (read_text($PREFLIGHT_SRC) // '') : '';
    if ($PREFLIGHT_EXISTS) {
        unlike($src, qr/settings-export-merge/, 'Out of scope: Preflight.pm never invokes settings-export-merge (package 03 only)');
    } else {
        ok(0, 'Out of scope: Preflight.pm never invokes settings-export-merge (Preflight.pm not found)');
    }
}

# ===========================================================================
# Item 2 (coordinator finding, post-implementation) -- dotted keys.
# json-diff.pl emits dotted parent.child keys for a nested hash divergence
# (json-diff.pl:138, collision guard at :129). W1 must NEST the answered
# value at live->{parent}{child}, never write a literal flat top-level key
# named "parent.child" -- a flat write both loses the intended structure and
# will trip json-diff.pl's own collision guard on a later real run.
# ===========================================================================
{
    my $filterdiff_json = encode_json({
        status         => 'filtered',
        auto_applied   => [],
        needs_decision => {
            diverged   => { 'env.DISABLE_LOGIN_COMMAND' => { left => '0', right => '1' } },
            only_left  => {},
            only_right => { 'container.MAX_MEMORY' => '512' },
        },
        has_undecided => JSON::PP::true,
    });
    my $r = setup_root(with_origin => 0);
    my $extra = { STUB_FILTERDIFF_JSON => $filterdiff_json };
    my $resp = run_backup($r, $extra);
    is($resp->{exit}, 10, '(setup) item2: a dotted-key settings batch pauses the run') or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of($resp);
    ok((defined find_decision(\@decs, 'preflight.settings.env.DISABLE_LOGIN_COMMAND')),
        '(setup) item2: a preflight.settings.env.DISABLE_LOGIN_COMMAND decision is present');
    ok((defined find_decision(\@decs, 'preflight.settings.container.MAX_MEMORY')),
        '(setup) item2: a preflight.settings.container.MAX_MEMORY decision is present');

    my $token = $resp->{json}{resume_token};
    my $resp2 = run_backup($r, $extra, '--resume', ($token // ''),
        '--answer', 'preflight.settings.env.DISABLE_LOGIN_COMMAND=use_repo',
        # Deliberately the CURRENT (pre-P6) id here -- this sub-test isolates
        # the flat-vs-nested write bug from the id-rename bug (item 6) so a
        # failure here means exactly one thing.
        '--answer', 'preflight.settings.container.MAX_MEMORY=add_to_live');
    ok(($resp2->{exit} == 0 || $resp2->{exit} == 20), 'item2: answering both dotted keys reaches a terminal status')
        or diag($resp2->{out} . $resp2->{err});

    my $live = read_state("$r->{home}/.claude/settings.json");
    if (defined $live) {
        is((ref($live->{env}) eq 'HASH' ? $live->{env}{DISABLE_LOGIN_COMMAND} : undef), '1',
            "item2: the diverged dotted key nests at live->{env}{DISABLE_LOGIN_COMMAND} (repo value)");
        ok(!exists($live->{'env.DISABLE_LOGIN_COMMAND'}),
            "item2: no literal flat top-level key 'env.DISABLE_LOGIN_COMMAND' exists in live settings.json");
        is((ref($live->{container}) eq 'HASH' ? $live->{container}{MAX_MEMORY} : undef), '512',
            "item2: the only_right dotted key nests at live->{container}{MAX_MEMORY}");
        ok(!exists($live->{'container.MAX_MEMORY'}),
            "item2: no literal flat top-level key 'container.MAX_MEMORY' exists in live settings.json");
    } else {
        ok(0, "item2: $_") for (
            'the diverged dotted key nests at live->{env}{DISABLE_LOGIN_COMMAND} (repo value)',
            "no literal flat top-level key 'env.DISABLE_LOGIN_COMMAND' exists in live settings.json",
            'the only_right dotted key nests at live->{container}{MAX_MEMORY}',
            "no literal flat top-level key 'container.MAX_MEMORY' exists in live settings.json",
        );
    }
}

# ===========================================================================
# Item 3 (coordinator finding) -- non-ASCII round trip through W1's write.
# _write_json_file encodes without ->utf8 and prints to a :raw filehandle --
# this host's own home is C:\Users\Andr\x{e9}. A rewritten live settings.json
# must still be valid UTF-8, and a pre-existing non-ASCII VALUE must survive
# byte-for-byte, not just the path ccpraxis happens to run under.
# ===========================================================================
{
    my $accented     = "Andr\x{e9}";
    my $orig_struct  = { note => "C:/Users/$accented/file.txt", k1 => 'livevalue' };
    my $orig_bytes   = JSON::PP->new->utf8->canonical->encode($orig_struct);
    my $r = setup_root(with_origin => 0, repo_settings => qq({"k1":"repovalue"}\n));
    write_text("$r->{home}/.claude/settings.json", $orig_bytes);

    my $filterdiff_json = encode_json({
        status => 'filtered', auto_applied => [],
        needs_decision => { diverged => { k1 => { left => 'livevalue', right => 'repovalue' } }, only_left => {}, only_right => {} },
        has_undecided => JSON::PP::true,
    });
    my $extra = { STUB_FILTERDIFF_JSON => $filterdiff_json };
    my $resp = run_backup($r, $extra);
    is($resp->{exit}, 10, '(setup) item3: a diverged key pauses the run') or diag($resp->{out} . $resp->{err});
    my $token = $resp->{json}{resume_token};
    my $resp2 = run_backup($r, $extra, '--resume', ($token // ''), '--answer', 'preflight.settings.k1=use_repo');
    ok(($resp2->{exit} == 0 || $resp2->{exit} == 20), 'item3: answering use_repo reaches a terminal status')
        or diag($resp2->{out} . $resp2->{err});

    my $new_bytes = read_text("$r->{home}/.claude/settings.json");
    ok((defined $new_bytes), 'item3: live settings.json still exists after the W1 write');
    my $decoded_ok = 0;
    if (defined $new_bytes) {
        $decoded_ok = eval { my $probe = $new_bytes; Encode::decode('UTF-8', $probe, FB_CROAK); 1 } ? 1 : 0;  # decode a COPY -- FB_CROAK consumes its source in place, which emptied $new_bytes before decode_json below and made this unpassable for ANY implementation
    }
    ok($decoded_ok, 'item3: the rewritten live settings.json is STILL valid UTF-8 (strict FB_CROAK decode does not die)')
        or diag("Encode::decode(UTF-8, ..., FB_CROAK) failed: " . ($@ // '(no bytes)'));

    if ($decoded_ok) {
        my $parsed = eval { decode_json($new_bytes) };
        if (defined $parsed) {
            is($parsed->{note}, "C:/Users/$accented/file.txt",
                'item3: the pre-existing non-ASCII value round-trips byte-for-byte (note field unchanged)');
        } else {
            ok(0, 'item3: the pre-existing non-ASCII value round-trips byte-for-byte (note field unchanged)');
        }
    } else {
        ok(0, 'item3: the pre-existing non-ASCII value round-trips byte-for-byte (note field unchanged)');
    }
}

# ===========================================================================
# Item 4 (coordinator finding) -- destructive read failure: a MALFORMED live
# settings.json must not be silently replaced with {} and overwritten.
# ===========================================================================
{
    my $garbage = "{ this is not valid json at all, sorry";
    my $r = setup_root(with_origin => 0, repo_settings => qq({"k1":"repovalue"}\n));
    write_text("$r->{home}/.claude/settings.json", $garbage);

    my $filterdiff_json = encode_json({
        status => 'filtered', auto_applied => [],
        needs_decision => { diverged => { k1 => { left => 'livevalue', right => 'repovalue' } }, only_left => {}, only_right => {} },
        has_undecided => JSON::PP::true,
    });
    my $extra = { STUB_FILTERDIFF_JSON => $filterdiff_json };
    my $resp = run_backup($r, $extra);
    is($resp->{exit}, 10, '(setup) item4: a diverged key pauses the run') or diag($resp->{out} . $resp->{err});
    my $token = $resp->{json}{resume_token};
    run_backup($r, $extra, '--resume', ($token // ''), '--answer', 'preflight.settings.k1=use_repo');

    # Whatever the run reports, the point is: the ORIGINAL malformed bytes
    # must not be silently discarded and replaced -- assert on disk state,
    # not on the run's reported status.
    my $after = read_text("$r->{home}/.claude/settings.json");
    is($after, $garbage,
        'item4: a malformed live settings.json is NOT destroyed by a W1 write (original bytes survive byte-for-byte)');
}

# ===========================================================================
# Item 5 (coordinator finding) -- write failure must degrade, not abort.
# _write_json_file dies with no eval at the call site; an unwritable target
# currently propagates all the way to phase_died (exit 1) instead of a
# degraded 'failed' unit (exit 20). Simulated by occupying the live
# settings.json PATH with a non-empty directory, which fails the write's
# final rename() reliably cross-platform.
# ===========================================================================
{
    my $r = setup_root(with_origin => 0, repo_settings => qq({"k1":"repovalue"}\n));
    unlink "$r->{home}/.claude/settings.json";
    make_path("$r->{home}/.claude/settings.json");
    write_text("$r->{home}/.claude/settings.json/blocker.txt", "occupying the path\n");

    my $filterdiff_json = encode_json({
        status => 'filtered', auto_applied => [],
        needs_decision => { diverged => { k1 => { left => 'livevalue', right => 'repovalue' } }, only_left => {}, only_right => {} },
        has_undecided => JSON::PP::true,
    });
    my $extra = { STUB_FILTERDIFF_JSON => $filterdiff_json };
    my $resp = run_backup($r, $extra);
    is($resp->{exit}, 10, '(setup) item5: a diverged key pauses the run') or diag($resp->{out} . $resp->{err});
    my $token = $resp->{json}{resume_token};
    my $resp2 = run_backup($r, $extra, '--resume', ($token // ''), '--answer', 'preflight.settings.k1=use_repo');

    isnt($resp2->{exit}, 1, 'item5: an unwritable live-settings target does NOT abort the whole run (no phase_died)');
    unlike($resp2->{out}, qr/"status"\s*:\s*"error"/, 'item5: the JSON status is never "error" for a write-failure unit');
    is(($resp2->{json}{status} // ''), 'complete_with_failures',
        'item5: the run degrades to complete_with_failures instead of dying on an I/O failure');
}

# ===========================================================================
# Item 7 (coordinator ruling P7) -- untracked-file visibility. --untracked-
# files=no keeps the merge decision scoped to tracked changes, but the phase
# must now emit an untracked-files NOTE so they are visible before package
# 03's `git add -A` (SKILL.md:299) sweeps and pushes them. A note, not a
# decision.
# ===========================================================================
{
    my $r = setup_root(with_origin => 0);
    write_text("$r->{ccpx}/untracked-marker-item7.txt", "never added to git\n");

    my $resp = run_backup($r, {});
    ok(($resp->{exit} == 0 || $resp->{exit} == 20), 'item7: an untracked file does not pause or fail the run on its own')
        or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of($resp);
    ok(!(grep { ($_->{kind} // '') =~ /untracked/i } @decs), 'item7: untracked files never become a DECISION');

    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $found = 0;
        for my $n (notes_of_state($state)) {
            $found = 1 if index(encode_json($n->{value}), 'untracked-marker-item7.txt') >= 0;
        }
        ok($found, 'item7: some note names the untracked file (visible before package 03 sweeps/pushes it)');
    } else {
        ok(0, 'item7: some note names the untracked file (no state)');
    }
}

done_testing();
