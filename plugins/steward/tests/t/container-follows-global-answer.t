#!/usr/bin/env perl
# platform: windows
# Oracle for blueprint tooling-fixes, package 16-container-follows-global-answer
# (scripts/backup/Export.pm, plugins/steward/skills/backup/SKILL.md).
#
# Spec: .ccpraxis-local-data/blueprints/tooling-fixes/specs/16-container-follows-global-answer-spec.md
#
# Written BLIND to any implementation of the follow-rule change: only the
# spec, the harness conventions of backup-export.t and backup-driver-core.t
# (read for fixture/mock patterns, not for Export.pm's internals), and the
# shipped scripts/backup/Run.pm were consulted. Do not read scripts/backup/
# Export.pm while editing this file -- it is the implementation under test.
#
# At the time this file was written, _do_container_diff unconditionally
# mints a container_settings_key decision for every needs_decision item and
# never reads the preflight settings_outcome at all, so every FOLLOW
# assertion below is expected to fail until the implementer wires the rule.
#
# Spec-AC -> section mapping (grep "SECTION" to jump):
#   SECTION A   AC1/AC3 (DC1): use_live/export_to_repo x diverged/only_left
#               all four pairings follow; no decision minted; global value
#               lands in the container settings.
#   SECTION A2  AC2 (DC1): export_to_repo + only_left with an OBJECT value
#               is written whole (not ->{left}-unwrapped).
#   SECTION B   AC4 (DC2): container_followed_global note + container_outcome
#               checkpoint's followed_global, in diverged-sorted-then-
#               only_left-sorted order; absent when nothing followed.
#   SECTION C   AC5/AC11 (DC3): every other answer shape, no answer, and
#               only_right keys still decide exactly as today.
#   SECTION D   AC6/AC7 (DC4): a global_vs_container preference wins over
#               the follow rule, using the REAL filter-diff.pl/json-diff.pl
#               and a real .backup-preferences.json; ANY existing preference
#               entry for a key blocks the follow, even when its stored
#               category does not match the key's current relation.
#   SECTION E   AC8/AC9 (DC5): pause/resume determinism -- followed key F
#               applied exactly once; resume does not re-read settings_outcome
#               (state-file surgery between invocations proves this).
#   SECTION F   AC12 (DC6): SKILL.md row/report wording.
#
# Not covered (documented in the handback report): AC10 (id-collision
# stability) and the R6-crash edge case -- both lower priority than the six
# behaviors above and not required by this package's dispatch.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use JSON::PP;
use Encode qw(decode FB_CROAK);
use StewardTest qw(ok is like unlike diag done_testing temproot make_machine init_remote write_text read_text path_exists);

my $EXPORT_SRC      = "$Bin/../../../../scripts/backup/Export.pm";
my $RUNPM           = "$Bin/../../../../scripts/backup/Run.pm";
my $BACKUP_SCRIPT   = "$Bin/../../../../scripts/backup.pl";
my $REAL_JSONDIFF   = "$Bin/../../../../plugins/steward/scripts/json-diff.pl";
my $REAL_FILTERDIFF = "$Bin/../../../../plugins/steward/scripts/filter-diff.pl";
my $SKILL_MD        = "$Bin/../../../../plugins/steward/skills/backup/SKILL.md";

my $EXPORT_EXISTS = -f $EXPORT_SRC ? 1 : 0;
ok($EXPORT_EXISTS, 'scripts/backup/Export.pm exists on disk')
    or diag('scripts/backup/Export.pm is absent -- every behavioral test below will fail for this reason');
ok(-f $RUNPM, 'scripts/backup/Run.pm exists on disk (shipped)');
ok(-f $BACKUP_SCRIPT, 'scripts/backup.pl exists on disk (shipped)');
ok(-f $REAL_JSONDIFF, 'plugins/steward/scripts/json-diff.pl exists on disk (shipped, unchanged by this package)');
ok(-f $REAL_FILTERDIFF, 'plugins/steward/scripts/filter-diff.pl exists on disk (shipped, unchanged by this package)');

sub isnt {
    my ($got, $exp, $name) = @_;
    my $cond = !((defined $got && defined $exp && $got eq $exp) || (!defined $got && !defined $exp));
    ok($cond, $name) or diag("  got:          " . (defined $got ? "[$got]" : "undef")
                           . "\n  expected NOT: " . (defined $exp ? "[$exp]" : "undef"));
    return $cond;
}

# ===========================================================================
# AC-COMPILE -- sanity, not a spec AC: perl -c is clean on Export.pm and on
# this file.
# ===========================================================================
sub _compile_check {
    my ($file, $label) = @_;
    unless (-f $file) { ok(0, "perl -c is clean on $label (file not found)"); return; }
    my ($efh, $ename) = tempfile(UNLINK => 1);
    close $efh;
    open(my $saved_stderr, '>&', \*STDERR) or die "cannot dup STDERR: $!";
    open(STDERR, '>', $ename) or die "cannot redirect STDERR: $!";
    my $rc = system($^X, '-c', $file);
    open(STDERR, '>&', $saved_stderr) or warn "cannot restore STDERR: $!";
    close $saved_stderr;
    my $err = read_text($ename) // '';
    unlink $ename;
    ok($rc == 0, "perl -c exits 0 for $label") or diag($err);
}
_compile_check($EXPORT_SRC, 'scripts/backup/Export.pm');
_compile_check("$Bin/container-follows-global-answer.t", 'this file');

my $RUNPM_OK = 0;
{ local $@; $RUNPM_OK = eval { require $RUNPM; 1 }; diag("Run.pm did not load cleanly: " . ($@ || 'unknown')) unless $RUNPM_OK; }

my $EXPORT_LOADED = 0;
if ($EXPORT_EXISTS) {
    local $@;
    $EXPORT_LOADED = eval { require $EXPORT_SRC; 1 };
    diag("Export.pm did not load cleanly: " . ($@ || 'unknown error')) unless $EXPORT_LOADED;
}

# ===========================================================================
# Path/git plumbing -- same technique as backup-export.t (MSYS2 landmine:
# hand-translate POSIX paths before handing them to native git).
# ===========================================================================
sub _native_path {
    my ($p) = @_;
    return $p unless defined $p;
    (my $q = $p) =~ s{\\}{/}g;
    $q =~ s{^/([A-Za-z])/}{\u$1:/};
    return $q;
}

sub _git_env {
    my ($home) = @_;
    return (
        HOME => $home, USERPROFILE => $home,
        GIT_CONFIG_GLOBAL => "$home/.gitconfig", GIT_CONFIG_SYSTEM => '/dev/null',
        GIT_TERMINAL_PROMPT => '0',
        GIT_AUTHOR_NAME => 'Container Follows Test', GIT_AUTHOR_EMAIL => 'cft@example.invalid',
        GIT_COMMITTER_NAME => 'Container Follows Test', GIT_COMMITTER_EMAIL => 'cft@example.invalid',
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

# ===========================================================================
# Stub wrapped scripts -- same convention/shape as backup-export.t.
# ===========================================================================
sub _stub_wrap {
    my ($body) = @_;
    return "#!/usr/bin/env perl\nuse strict;\nuse warnings;\nuse File::Basename qw(basename);\n"
         . "my \$log = \$ENV{EXPORT_TEST_LOG};\n"
         . "if (defined \$log && length \$log) {\n"
         . "    open my \$lfh, '>>:raw', \$log or die \"cannot append to log: \$!\";\n"
         . "    print {\$lfh} basename(\$0) . \" \@ARGV\\n\";\n"
         . "    close \$lfh;\n"
         . "}\n"
         . $body;
}

my $STUB_SYNC_BODY = <<'PERL';
my $exit = defined $ENV{STUB_SYNC_EXIT} ? $ENV{STUB_SYNC_EXIT} : 0;
my $json = defined $ENV{STUB_SYNC_JSON} ? $ENV{STUB_SYNC_JSON} : '[]';
print $json;
exit $exit;
PERL

my $STUB_HELPERS_BODY = <<'PERL';
my $cmd = shift(@ARGV);
$cmd = '' unless defined $cmd;
if ($cmd eq 'settings-export-merge') {
    my $exit = defined $ENV{STUB_MERGE_EXIT} ? $ENV{STUB_MERGE_EXIT} : 0;
    my $json = defined $ENV{STUB_MERGE_JSON} ? $ENV{STUB_MERGE_JSON}
             : '{"status":"merged","live":"x","repo":"y","merge_rule":"preference-aware-live-wins-preserve-repo-only","preferences_file":"z","preferences_applied":[],"preferences_ignored":[],"skip_keys_unmatched":[]}';
    print $json;
    exit $exit;
}
else {
    print '{"status":"error","error":{"code":"usage","message":"unexpected ccpraxis-helpers.pl subcommand: ' . $cmd . '"}}';
    exit 3;
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
my $json;
if (defined $ENV{STUB_FILTERDIFF_JSON_FILE} && length $ENV{STUB_FILTERDIFF_JSON_FILE} && -f $ENV{STUB_FILTERDIFF_JSON_FILE}) {
    open my $fh, '<:raw', $ENV{STUB_FILTERDIFF_JSON_FILE} or die "stub filter-diff: cannot read payload file: $!";
    local $/; $json = <$fh>; close $fh;
}
elsif (defined $ENV{STUB_FILTERDIFF_JSON}) {
    $json = $ENV{STUB_FILTERDIFF_JSON};
}
else {
    $json = '{"status":"identical","auto_applied":[],"needs_decision":{"only_left":{},"only_right":{},"diverged":{}},"has_undecided":false}';
}
print $json;
exit $exit;
PERL

my $STUB_SAVEPREF_BODY = <<'PERL';
my $exit = defined $ENV{STUB_SAVEPREF_EXIT} ? $ENV{STUB_SAVEPREF_EXIT} : 0;
print "ok\n";
exit $exit;
PERL

my $STUB_SENSITIVE_BODY = <<'PERL';
my $exit = defined $ENV{STUB_SENSITIVE_EXIT} ? $ENV{STUB_SENSITIVE_EXIT} : 0;
my $out  = defined $ENV{STUB_SENSITIVE_STDOUT} ? $ENV{STUB_SENSITIVE_STDOUT} : "No sensitive data found.\n";
print $out;
exit $exit;
PERL

sub write_stub_scripts {
    my ($ccpx) = @_;
    write_text("$ccpx/plugins/steward/scripts/sync-export.pl",      _stub_wrap($STUB_SYNC_BODY));
    write_text("$ccpx/plugins/steward/scripts/ccpraxis-helpers.pl", _stub_wrap($STUB_HELPERS_BODY));
    write_text("$ccpx/plugins/steward/scripts/json-diff.pl",        _stub_wrap($STUB_JSONDIFF_BODY));
    write_text("$ccpx/plugins/steward/scripts/filter-diff.pl",      _stub_wrap($STUB_FILTERDIFF_BODY));
    write_text("$ccpx/plugins/steward/scripts/save-preference.pl",  _stub_wrap($STUB_SAVEPREF_BODY));
    write_text("$ccpx/plugins/steward/scripts/sensitive-check.pl",  _stub_wrap($STUB_SENSITIVE_BODY));
}

# SECTION D needs the REAL json-diff.pl/filter-diff.pl in place of the
# stubs, so filter-diff.pl's own preference logic is what is under test.
sub install_real_diff_scripts {
    my ($ccpx) = @_;
    write_text("$ccpx/plugins/steward/scripts/json-diff.pl",   read_text($REAL_JSONDIFF));
    write_text("$ccpx/plugins/steward/scripts/filter-diff.pl", read_text($REAL_FILTERDIFF));
}

my $GIT_STUB_PL = <<'PERL';
#!/usr/bin/env perl
use strict; use warnings;
my $log = $ENV{EXPORT_TEST_LOG};
if (defined $log && length $log) {
    open my $lfh, '>>:raw', $log or die "cannot append to log: $!";
    print {$lfh} "GITBIN @ARGV\n";
    close $lfh;
}
my $rc = system('git', @ARGV);
if ($rc == -1) { print STDERR "git-stub: cannot exec git\n"; exit 127; }
exit($rc >> 8);
PERL

my $GIT_STUB_CMD = <<'CMD';
@echo off
perl "%~dp0git-stub.pl" %*
exit /b %ERRORLEVEL%
CMD

sub write_git_stub {
    my ($scratch) = @_;
    write_text("$scratch/git-stub.pl", $GIT_STUB_PL);
    write_text("$scratch/git-stub.cmd", $GIT_STUB_CMD);
    return "$scratch/git-stub.cmd";
}

# ===========================================================================
# fresh_state_shell / seed_preflight_outcome -- same handoff technique as
# backup-export.t: the run-state file is written directly so the preflight
# settings_outcome item exists without Preflight.pm ever running.
# ===========================================================================
sub fresh_state_shell {
    my (%opts) = @_;
    my $now    = $opts{now}    // time;
    my $run_id = $opts{run_id} // 'c0ffeec0ffeec0ff';
    return {
        format => 1, run_id => $run_id, started_at => $now, updated_at => $now,
        status => 'running', phase_order => ['export'], phase_index => 0,
        phases => { export => { status => 'pending', started_at => undef, completed_at => undef, error => undef, items => {}, scratch => {} } },
        token_seq => 0, consumed_seq => 0, pending => undef, answers => {}, notes => [],
    };
}

sub write_state_raw {
    my ($path, $data) = @_;
    write_text($path, JSON::PP->new->canonical->pretty->encode($data));
}

sub seed_preflight_outcome {
    my ($state_path, $data_or_undef) = @_;
    my $state = fresh_state_shell();
    if (defined $data_or_undef) {
        $state->{phases}{preflight} = {
            status => 'complete', started_at => time, completed_at => time, error => undef,
            items  => { settings_outcome => { at => time, data => $data_or_undef } },
            scratch => {},
        };
    }
    write_state_raw($state_path, $state);
    return $state;
}

sub copy_export_into {
    my ($phase_dir) = @_;
    make_path($phase_dir);
    return 0 unless $EXPORT_EXISTS;
    write_text("$phase_dir/Export.pm", read_text($EXPORT_SRC));
    return 1;
}

sub setup_root {
    my (%opts) = @_;
    my $scratch = temproot();
    my $home    = make_machine($scratch, $opts{machine_name} // 'host');
    my $ccpx    = "$home/.claude/ccpraxis";
    make_path($ccpx);

    _git($home, $ccpx, 'init', '-q');

    write_text("$ccpx/README.md", "# ccpraxis\n");
    write_text("$ccpx/global-config/settings.json", $opts{repo_settings} // "{}\n");
    write_text("$ccpx/global-config/known_marketplaces.json", "{}\n");
    write_text("$home/.claude/settings.json", $opts{live_settings} // "{}\n");

    if (exists $opts{container_settings}) {
        write_text("$ccpx/plugins/sandbox/container/settings.json", $opts{container_settings})
            if defined $opts{container_settings};
    } else {
        write_text("$ccpx/plugins/sandbox/container/settings.json", "{}\n");
    }

    if (defined $opts{prefs}) {
        write_text("$ccpx/.backup-preferences.json", $opts{prefs});
    }

    write_stub_scripts($ccpx);
    install_real_diff_scripts($ccpx) if $opts{real_diff};

    _git($home, $ccpx, 'add', '-A');
    _git($home, $ccpx, 'commit', '-q', '-m', 'initial fixture commit');

    my $phase_dir = "$scratch/phases";
    copy_export_into($phase_dir);
    my $git_stub = write_git_stub($scratch);

    return {
        scratch => $scratch, home => $home, ccpx => $ccpx,
        phase_dir => $phase_dir, git_stub => $git_stub,
        state_path => "$scratch/state/run.json", log_path => "$scratch/log.txt",
    };
}

sub _spawn {
    my ($env_overrides, @args) = @_;
    my %env = %$env_overrides;
    local @ENV{ keys %env } = values %env;

    my ($efh, $ename) = tempfile(UNLINK => 1);
    close $efh;
    open(my $saved_stderr, '>&', \*STDERR) or die "cannot dup STDERR: $!";
    open(STDERR, '>', $ename) or die "cannot redirect STDERR to $ename: $!";

    my $out = ''; my $exit = -1;
    my $pid = open(my $fh, '-|', $^X, $BACKUP_SCRIPT, @args);
    if ($pid) {
        local $/; $out = <$fh>; $out = '' unless defined $out;
        close $fh; $exit = $? >> 8;
    }

    open(STDERR, '>&', $saved_stderr) or warn "cannot restore STDERR: $!";
    close $saved_stderr;
    my $err = read_text($ename); $err = '' unless defined $err;
    unlink $ename;

    my $json = eval { decode_json($out) };
    return { out => $out, err => $err, exit => $exit, json => $json };
}

sub scenario_env {
    my ($r, %extra) = @_;
    my %env = (
        _git_env($r->{home}),
        BACKUP_RUN_STATE => $r->{state_path},
        BACKUP_PHASE_DIR => $r->{phase_dir},
        EXPORT_TEST_LOG  => $r->{log_path},
        BACKUP_GIT_BIN   => $r->{git_stub},
    );
    for my $k (keys %extra) { $env{$k} = defined $extra{$k} ? $extra{$k} : ''; }
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

sub log_lines {
    my ($log_path) = @_;
    my $raw = read_text($log_path);
    return () unless defined $raw;
    return grep { length $_ } split /\n/, $raw;
}

sub decisions_of { my ($resp) = @_; return @{ $resp->{json}{decisions} // [] }; }
sub decisions_of_kind {
    my ($resp, $kind) = @_;
    return grep { ($_->{kind} // '') eq $kind } decisions_of($resp);
}
sub find_decision {
    my ($decisions, $id) = @_;
    for my $d (@$decisions) { return $d if ($d->{id} // '') eq $id; }
    return undef;
}
sub notes_of_state { my ($state) = @_; return @{ $state->{notes} // [] }; }
sub find_note {
    my ($state, $key) = @_;
    for my $n (notes_of_state($state)) { return $n if ($n->{key} // '') eq $key; }
    return undef;
}
sub note_values_json {
    my ($state, $key) = @_;
    return join("\n", map { encode_json($_->{value}) } grep { ($_->{key} // '') eq $key } notes_of_state($state));
}

# Structural equality via a CANONICAL encoder -- encode_json's hash key
# order depends on how the hash was built (decode_json vs. a literal), so
# two JSON-equal values can produce different byte strings from the plain
# functional encode_json. Every exact-match structural assertion below goes
# through this so a key-order artifact of MY fixture construction never
# masquerades as a real (or missing) behavior.
my $CANON = JSON::PP->new->canonical;
sub canon_json { my ($x) = @_; return $CANON->encode($x); }

# Drains a trailing push_confirmation pause with 'abort' (backup-export.t
# finish_after_content_change precedent) -- the container write under test
# is a worktree change and legitimately pauses for push consent; these
# scenarios are about the write/decision/note content, not the push.
sub finish_after_content_change {
    my ($r, $extra, $resp) = @_;
    return $resp unless (($resp->{json}{status} // '') eq 'needs_decision');
    my @pc = decisions_of_kind($resp, 'push_confirmation');
    return $resp unless @pc;
    my $d = $pc[0];
    my $token = $resp->{json}{resume_token};
    return run_backup($r, $extra, '--resume', ($token // ''), '--answer',
        (defined $d ? "$d->{id}=abort" : 'export.push_confirmation=abort'));
}

sub read_container {
    my ($r) = @_;
    my $raw = read_text("$r->{ccpx}/plugins/sandbox/container/settings.json");
    return defined $raw ? eval { decode_json($raw) } : undef;
}

# ===========================================================================
# SECTION A -- AC1/AC3 (DC1): every follow-eligible pairing follows: no
# container_settings_key decision minted, global value lands in container.
# ===========================================================================
{
    my $filterdiff_json = encode_json({
        status => 'filtered', auto_applied => [],
        needs_decision => {
            diverged   => {
                'aaa_first' => { left => 'A1', right => 'A0' },   # export_to_repo? no -- diverged pairs with use_live/export_to_repo both tested below
                'zzz_last'  => { left => 'Z1', right => 'Z0' },
            },
            only_left  => {
                'bbb_early' => 'B1',
                'mmm_mid'   => 'M1',
            },
            only_right => {},
        },
        has_undecided => JSON::PP::true,
    });
    my $r = setup_root(with_origin => 0, container_settings => qq({"KEEP":"x"}\n));
    seed_preflight_outcome($r->{state_path}, {
        skip_keys => [], preferences_saved => [],
        answers => {
            aaa_first => 'export_to_repo',   # diverged, export_to_repo -> follows
            zzz_last  => 'use_live',         # diverged, use_live -> follows
            bbb_early => 'export_to_repo',   # only_left, export_to_repo -> follows
            mmm_mid   => 'use_live',         # only_left, use_live -> follows
        },
    });
    my $extra = { STUB_FILTERDIFF_JSON => $filterdiff_json };
    my $resp = run_backup($r, $extra);
    record_decisions_noop();
    my @container_decs = decisions_of_kind($resp, 'container_settings_key');
    is(scalar(@container_decs), 0, 'SECTION A (AC1/AC3): no container_settings_key decision is minted for any of the four followed keys')
        or diag(encode_json(\@container_decs));
    ok(($resp->{json}{status} // '') ne 'needs_decision' || scalar(decisions_of_kind($resp, 'push_confirmation')) > 0,
        'SECTION A: the only pause (if any) is push_confirmation, never a container_settings_key batch')
        or diag($resp->{out});

    my $resp2 = finish_after_content_change($r, $extra, $resp);
    ok(($resp2->{exit} == 0 || $resp2->{exit} == 20), 'SECTION A: the run reaches a terminal status after the follow writes')
        or diag($resp2->{out} . $resp2->{err});

    my $container = read_container($r);
    if (defined $container) {
        is($container->{aaa_first}, 'A1', 'SECTION A: diverged+export_to_repo writes the global (left) value');
        is($container->{zzz_last},  'Z1', 'SECTION A: diverged+use_live writes the global (left) value');
        is($container->{bbb_early}, 'B1', 'SECTION A: only_left+export_to_repo writes the global value');
        is($container->{mmm_mid},   'M1', 'SECTION A: only_left+use_live writes the global value');
        is($container->{KEEP}, 'x', 'SECTION A: a pre-existing unrelated container key is preserved');
    } else {
        ok(0, "SECTION A: $_") for (
            'diverged+export_to_repo writes the global (left) value',
            'diverged+use_live writes the global (left) value',
            'only_left+export_to_repo writes the global value',
            'only_left+use_live writes the global value',
            'a pre-existing unrelated container key is preserved',
        );
    }

    # ---- SECTION B (AC4/DC2): the note and checkpoint from this same run ----
    my $state = read_state($r->{state_path});
    if (defined $state) {
        my @follow_notes = grep { ($_->{key} // '') eq 'container_followed_global' } notes_of_state($state);
        is(scalar(@follow_notes), 1, 'SECTION B (AC4): exactly one container_followed_global note')
            or diag(encode_json(\@follow_notes));
        if (@follow_notes == 1) {
            my $value = $follow_notes[0]{value};
            my @expected = (
                { key => 'aaa_first', relation => 'diverged',   answer => 'export_to_repo' },
                { key => 'zzz_last',  relation => 'diverged',   answer => 'use_live' },
                { key => 'bbb_early', relation => 'only_left',  answer => 'export_to_repo' },
                { key => 'mmm_mid',   relation => 'only_left',  answer => 'use_live' },
            );
            is(canon_json($value), canon_json(\@expected),
                'SECTION B (AC4): the note value is the followed set, diverged-sorted then only_left-sorted')
                or diag(encode_json($value));
            my $co = $state->{phases}{export}{items}{container_outcome}{data} // {};
            is(canon_json($co->{followed_global} // []), canon_json(\@expected),
                'SECTION B (AC4): container_outcome checkpoint followed_global deep-equals the note value');
        } else {
            ok(0, 'SECTION B (AC4): the note value is the followed set in order');
            ok(0, 'SECTION B (AC4): container_outcome checkpoint followed_global deep-equals the note value');
        }
        # SECTION B (AC6/B6): the container_diff checkpoint ALSO carries
        # followed_global, from the SAME invocation that minted the (empty)
        # decision set.
        my $cd = $state->{phases}{export}{items}{container_diff}{data} // {};
        my @cd_followed = @{ $cd->{followed_global} // [] };
        is(scalar(@cd_followed), 4, 'SECTION B (AC6): container_diff checkpoint followed_global has all four entries');
    } else {
        ok(0, 'SECTION B (AC4): exactly one container_followed_global note');
        ok(0, 'SECTION B (AC4): the note value is the followed set in order');
        ok(0, 'SECTION B (AC4): container_outcome checkpoint followed_global deep-equals the note value');
        ok(0, 'SECTION B (AC6): container_diff checkpoint followed_global has all four entries');
    }
}
sub record_decisions_noop { }

# ===========================================================================
# SECTION A2 -- AC2 (DC1): an only_left OBJECT value is written whole, not
# ->{left}-unwrapped; a plain-scalar only_left value also follows.
# ===========================================================================
{
    my $filterdiff_json = encode_json({
        status => 'filtered', auto_applied => [],
        needs_decision => {
            diverged  => {},
            only_left => { timeFormat => '24h', modelSettings => { a => 1 } },
            only_right => {},
        },
        has_undecided => JSON::PP::true,
    });
    my $r = setup_root(with_origin => 0, container_settings => qq({}\n));
    seed_preflight_outcome($r->{state_path}, {
        skip_keys => [], preferences_saved => [],
        answers => { timeFormat => 'export_to_repo', modelSettings => 'export_to_repo' },
    });
    my $extra = { STUB_FILTERDIFF_JSON => $filterdiff_json };
    my $resp = run_backup($r, $extra);
    my @container_decs = decisions_of_kind($resp, 'container_settings_key');
    is(scalar(@container_decs), 0, 'SECTION A2 (AC2): no decision for either followed key');

    my $resp2 = finish_after_content_change($r, $extra, $resp);
    ok(($resp2->{exit} == 0 || $resp2->{exit} == 20), 'SECTION A2: reaches a terminal status') or diag($resp2->{out} . $resp2->{err});

    my $container = read_container($r);
    if (defined $container) {
        is($container->{timeFormat}, '24h', 'SECTION A2 (AC2): scalar only_left value written');
        is(canon_json($container->{modelSettings} // {}), canon_json({ a => 1 }),
            'SECTION A2 (AC2): an only_left OBJECT value is written whole, not unwrapped to ->{left}');
    } else {
        ok(0, "SECTION A2: $_") for ('scalar only_left value written', 'object only_left value written whole');
    }
}

# ===========================================================================
# SECTION B2 -- AC4 negative: a run with no followed key carries no
# container_followed_global note.
# ===========================================================================
{
    my $filterdiff_json = encode_json({
        status => 'filtered', auto_applied => [],
        needs_decision => { diverged => { k1 => { left => 'L', right => 'R' } }, only_left => {}, only_right => {} },
        has_undecided => JSON::PP::true,
    });
    my $r = setup_root(with_origin => 0, container_settings => qq({"k1":"R"}\n));
    seed_preflight_outcome($r->{state_path}, { skip_keys => [], preferences_saved => [], answers => { k1 => 'use_repo' } });
    my $extra = { STUB_FILTERDIFF_JSON => $filterdiff_json };
    my $resp = run_backup($r, $extra);
    is($resp->{exit}, 10, '(setup) SECTION B2: an unfollowed diverged key pauses with a decision') or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of_kind($resp, 'container_settings_key');
    is(scalar(@decs), 1, 'SECTION B2: exactly one decision (k1 not followed because answered use_repo)');
    my $d = $decs[0];
    my $token = $resp->{json}{resume_token};
    my $resp2 = run_backup($r, $extra, '--resume', ($token // ''), '--answer', (defined $d ? "$d->{id}=skip" : 'export.container.k1=skip'));
    ok(($resp2->{exit} == 0 || $resp2->{exit} == 20), 'SECTION B2: reaches a terminal status');
    my $state = read_state($r->{state_path});
    ok((defined $state && !defined find_note($state, 'container_followed_global')),
        'SECTION B2 (AC4 negative): a run with nothing followed carries no container_followed_global note');
}

# ===========================================================================
# SECTION C -- AC5/AC11 (DC3): every other answer shape, no answer, and
# only_right keys still decide exactly as today; no follow note.
# ===========================================================================
{
    my $filterdiff_json = encode_json({
        status => 'filtered', auto_applied => [],
        needs_decision => {
            diverged => {
                k_use_repo       => { left => 'L1', right => 'R1' },
                k_skip            => { left => 'L2', right => 'R2' },
                k_remember        => { left => 'L3', right => 'R3' },
                k_no_answer_div   => { left => 'L4', right => 'R4' },
            },
            only_left => {
                k_no_answer_left  => 'L5',
            },
            only_right => {
                k_only_right_live => 'C1',
                k_only_right_add  => 'C2',
            },
        },
        has_undecided => JSON::PP::true,
    });
    my $r = setup_root(with_origin => 0, container_settings => qq({"k_only_right_live":"C1","k_only_right_add":"C2"}\n));
    seed_preflight_outcome($r->{state_path}, {
        skip_keys => [], preferences_saved => [],
        answers => {
            k_use_repo         => 'use_repo',
            k_skip              => 'skip',
            k_remember          => 'keep_different_remember',
            # k_no_answer_div / k_no_answer_left: deliberately absent.
            k_only_right_live  => 'use_live',   # only_right -- answer is irrelevant, always asked
            k_only_right_add   => 'add_to_live',
        },
    });
    my $extra = { STUB_FILTERDIFF_JSON => $filterdiff_json };
    my $resp = run_backup($r, $extra);
    is($resp->{exit}, 10, '(setup) SECTION C (AC5): the batch pauses the run') or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of_kind($resp, 'container_settings_key');
    is(scalar(@decs), 7, 'SECTION C (AC5): all seven keys still mint a container_settings_key decision')
        or diag(encode_json(\@decs));

    for my $key (qw(k_use_repo k_skip k_remember k_no_answer_div)) {
        my $d = (grep { ($_->{data}{key} // '') eq $key } @decs)[0];
        if (defined $d) {
            is($d->{id}, "export.container.$key", "SECTION C (AC5): $key decision id matches grammar");
            my %cid = map { $_->{id} => 1 } @{ $d->{choices} // [] };
            ok(($cid{propagate_to_container} && $cid{keep_container} && $cid{keep_different_remember} && $cid{skip}),
                "SECTION C (AC5): $key (diverged) choice set is unchanged from today");
        } else {
            ok(0, "SECTION C (AC5): a decision exists for diverged key $key");
            ok(0, "SECTION C (AC5): $key (diverged) choice set is unchanged from today");
        }
    }
    {
        my $d = (grep { ($_->{data}{key} // '') eq 'k_no_answer_left' } @decs)[0];
        if (defined $d) {
            my %cid = map { $_->{id} => 1 } @{ $d->{choices} // [] };
            ok(($cid{add_to_container} && $cid{keep_global_only_remember} && $cid{skip}),
                'SECTION C (AC5): k_no_answer_left (only_left) choice set is unchanged from today');
        } else {
            ok(0, 'SECTION C (AC5): a decision exists for k_no_answer_left');
        }
    }
    for my $key (qw(k_only_right_live k_only_right_add)) {
        my $d = (grep { ($_->{data}{key} // '') eq $key } @decs)[0];
        if (defined $d) {
            my %cid = map { $_->{id} => 1 } @{ $d->{choices} // [] };
            ok(($cid{remove_from_container} && $cid{keep_container_only_remember} && $cid{skip}),
                "SECTION C (AC5): $key (only_right) choice set is unchanged from today, regardless of its live-vs-repo answer");
        } else {
            ok(0, "SECTION C (AC5): a decision exists for only_right key $key");
        }
    }

    my $container_before = read_container($r);
    is(canon_json($container_before // {}), canon_json({ k_only_right_live => 'C1', k_only_right_add => 'C2' }),
        'SECTION C (AC5): the container file is unchanged by invocation 1 (nothing applied before being answered)')
        or diag('container raw: ' . (read_text("$r->{ccpx}/plugins/sandbox/container/settings.json") // '(undef)'));

    my $state1 = read_state($r->{state_path});
    ok((defined $state1 && !defined find_note($state1, 'container_followed_global')),
        'SECTION C (AC5): no container_followed_global note before (or without) any follow');
}

# ===========================================================================
# SECTION C2 -- AC11 (degrade): settings_outcome with no answers key, and
# separately answers => [] (not a hash) -- every item still asked, no unit
# failure, no follow note.
# ===========================================================================
for my $degrade_case (
    { label => 'no answers key at all', data => { skip_keys => [], preferences_saved => [] } },
    { label => 'answers is an array, not a hash', data => { skip_keys => [], preferences_saved => [], answers => [] } },
) {
    my $filterdiff_json = encode_json({
        status => 'filtered', auto_applied => [],
        needs_decision => { diverged => { dk => { left => 'L', right => 'R' } }, only_left => {}, only_right => {} },
        has_undecided => JSON::PP::true,
    });
    my $r = setup_root(with_origin => 0, container_settings => qq({"dk":"R"}\n));
    seed_preflight_outcome($r->{state_path}, $degrade_case->{data});
    my $extra = { STUB_FILTERDIFF_JSON => $filterdiff_json };
    my $resp = run_backup($r, $extra);
    isnt(($resp->{json}{status} // ''), 'failed', "SECTION C2 (AC11, $degrade_case->{label}): the unit does not fail")
        or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of_kind($resp, 'container_settings_key');
    is(scalar(@decs), 1, "SECTION C2 (AC11, $degrade_case->{label}): the key is still asked as a decision");
    my $state = read_state($r->{state_path});
    ok((defined $state && !defined find_note($state, 'container_followed_global')),
        "SECTION C2 (AC11, $degrade_case->{label}): no container_followed_global note");
}

# ===========================================================================
# SECTION D -- AC6/AC7 (DC4): a global_vs_container preference wins over the
# follow rule. Uses the REAL json-diff.pl/filter-diff.pl (unchanged by this
# package) and a real .backup-preferences.json, exactly as Export.pm's
# existing (unmodified) U5 invokes them.
# ===========================================================================
{
    my $prefs = encode_json({
        global_vs_container => {
            prefOnly => { category => 'only_left', action => 'left-only' },
            prefDiv  => { category => 'diverged',  action => 'skip-always' },
        },
    });
    my $r = setup_root(
        with_origin        => 0,
        real_diff          => 1,
        repo_settings      => qq({"prefOnly":"g","prefDiv":"g2"}\n),
        container_settings => qq({"prefDiv":"c2"}\n),
        prefs              => $prefs,
    );
    seed_preflight_outcome($r->{state_path}, {
        skip_keys => [], preferences_saved => [],
        answers => { prefOnly => 'export_to_repo', prefDiv => 'use_live' },
    });
    # settings-export-merge stays stubbed, so global-config is not altered
    # by this scenario (AC6's own instruction).
    my $resp = run_backup($r, {});
    my @decs = decisions_of_kind($resp, 'container_settings_key');
    is(scalar(@decs), 0, 'SECTION D (AC6): neither preferenced key gets a container_settings_key decision')
        or diag(encode_json(\@decs));

    my $resp2 = finish_after_content_change($r, {}, $resp);
    ok(($resp2->{exit} == 0 || $resp2->{exit} == 20), 'SECTION D (AC6): reaches a terminal status') or diag($resp2->{out} . $resp2->{err});

    is(read_text("$r->{ccpx}/plugins/sandbox/container/settings.json"), qq({"prefDiv":"c2"}\n),
        'SECTION D (AC6): the container settings file is byte-unchanged -- the preference, not the follow rule, applied');

    my $state = read_state($r->{state_path});
    ok((defined $state && !defined find_note($state, 'container_followed_global')),
        'SECTION D (AC6): no container_followed_global note (the preference pre-empted both candidates)');
    ok((defined $state && length(note_values_json($state, 'container_auto_applied')) > 0),
        'SECTION D (AC6): a container_auto_applied note lists the preference-matched keys')
        or diag(defined $state ? encode_json($state->{notes}) : 'no state');
}

# ---- AC7 companion: ANY existing preference entry blocks the follow, even
# when its stored category does not match the key's current relation ----
{
    my $prefs = encode_json({
        global_vs_container => {
            prefDiv => { category => 'only_left', action => 'left-only' },   # mismatched: relation is actually diverged
        },
    });
    my $r = setup_root(
        with_origin        => 0,
        real_diff          => 1,
        repo_settings      => qq({"prefDiv":"g2"}\n),
        container_settings => qq({"prefDiv":"c2"}\n),
        prefs              => $prefs,
    );
    seed_preflight_outcome($r->{state_path}, {
        skip_keys => [], preferences_saved => [],
        answers => { prefDiv => 'use_live' },
    });
    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, '(setup) SECTION D (AC7): a category-mismatched preference still pauses with a decision') or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of_kind($resp, 'container_settings_key');
    is(scalar(@decs), 1, 'SECTION D (AC7): ANY existing preference entry blocks the follow -- a decision is still minted despite the category mismatch')
        or diag(encode_json(\@decs));

    my $container = read_container($r);
    is(($container // {})->{prefDiv}, 'c2', 'SECTION D (AC7): the container value is untouched -- preference presence (not category match) is what counts');
}

# ===========================================================================
# SECTION E -- AC8/AC9 (DC5): pause/resume determinism. Followed key F +
# non-followed key N; invocation 1 pauses with exactly one decision (N);
# invocation 2 resumes, applying F and N together in one write. AC9: state-
# file surgery on settings_outcome between invocations does not change
# invocation 2's behaviour, because _do_container_outcome never re-reads it.
# ===========================================================================
sub run_section_e {
    my (%opts) = @_;
    my $filterdiff_json = encode_json({
        status => 'filtered', auto_applied => [],
        needs_decision => { diverged => { F => { left => 'FGLOBAL', right => 'FCONTAINER' } }, only_left => { N => 'NVAL' }, only_right => {} },
        has_undecided => JSON::PP::true,
    });
    my $r = setup_root(with_origin => 0, container_settings => qq({"F":"FCONTAINER"}\n));
    seed_preflight_outcome($r->{state_path}, { skip_keys => [], preferences_saved => [], answers => { F => 'use_live' } }); # N: no answer
    my $extra = { STUB_FILTERDIFF_JSON => $filterdiff_json };
    my $resp1 = run_backup($r, $extra);
    return ($r, $extra, $resp1);
}

{
    my ($r, $extra, $resp1) = run_section_e();
    is($resp1->{exit}, 10, '(setup) SECTION E (AC8): invocation 1 pauses') or diag($resp1->{out} . $resp1->{err});
    my @decs = decisions_of_kind($resp1, 'container_settings_key');
    is(scalar(@decs), 1, 'SECTION E (AC8): exactly one container_settings_key decision (for N, not F)')
        or diag(encode_json(\@decs));
    # Picked by data.key, never decs[0] -- until the follow rule exists,
    # BOTH F and N mint a decision here, and F may sort first.
    my ($d) = grep { ($_->{data}{key} // '') eq 'N' } @decs;

    is(read_text("$r->{ccpx}/plugins/sandbox/container/settings.json"), qq({"F":"FCONTAINER"}\n),
        'SECTION E (AC8): the container file is unchanged by invocation 1');

    my $state1 = read_state($r->{state_path});
    if (defined $state1) {
        my $cd = $state1->{phases}{export}{items}{container_diff}{data} // {};
        is(canon_json($cd->{followed_global} // []),
            canon_json([ { key => 'F', relation => 'diverged', answer => 'use_live' } ]),
            'SECTION E (AC8): container_diff checkpoint already records F as followed, before any answer');
        ok(!defined(find_note($state1, 'container_followed_global')),
            'SECTION E (AC8): no container_followed_global note yet (U6 has not run)');
    } else {
        ok(0, 'SECTION E (AC8): container_diff checkpoint already records F as followed');
        ok(0, 'SECTION E (AC8): no container_followed_global note yet');
    }

    my $token = $resp1->{json}{resume_token};
    my $resp2 = run_backup($r, $extra, '--resume', ($token // ''),
        '--answer', (defined $d ? "$d->{id}=add_to_container" : 'export.container.N=add_to_container'));
    isnt($resp2->{exit}, 4, 'SECTION E (AC8): invocation 2 is accepted (not exit 4 answer_missing/answer_unknown_id)')
        or diag($resp2->{out} . $resp2->{err});

    my $resp3 = finish_after_content_change($r, $extra, $resp2);
    ok(($resp3->{exit} == 0 || $resp3->{exit} == 20), 'SECTION E (AC8): invocation 2 reaches a terminal status') or diag($resp3->{out} . $resp3->{err});

    my $container = read_container($r);
    if (defined $container) {
        is($container->{F}, 'FGLOBAL', 'SECTION E (AC8): F was written with the global value');
        is($container->{N}, 'NVAL',    'SECTION E (AC8): N was written per its answer');
    } else {
        ok(0, "SECTION E (AC8): $_") for ('F was written with the global value', 'N was written per its answer');
    }

    my $state3 = read_state($r->{state_path});
    if (defined $state3) {
        my @follow_notes = grep { ($_->{key} // '') eq 'container_followed_global' } notes_of_state($state3);
        is(scalar(@follow_notes), 1, 'SECTION E (AC8): exactly one container_followed_global note across the whole run');
        my $co = $state3->{phases}{export}{items}{container_outcome}{data} // {};
        my @co_f = @{ $co->{followed_global} // [] };
        is(scalar(@co_f), 1, 'SECTION E (AC8): container_outcome.followed_global lists F exactly once');
    } else {
        ok(0, 'SECTION E (AC8): exactly one container_followed_global note across the whole run');
        ok(0, 'SECTION E (AC8): container_outcome.followed_global lists F exactly once');
    }
}

# ---- AC9: corrupt settings_outcome between invocations -- resume unaffected ----
{
    my ($r, $extra, $resp1) = run_section_e();
    is($resp1->{exit}, 10, '(setup) SECTION E (AC9): invocation 1 pauses');
    my @decs = decisions_of_kind($resp1, 'container_settings_key');
    # Picked by data.key, never decs[0] -- see AC8 scenario above.
    my ($d) = grep { ($_->{data}{key} // '') eq 'N' } @decs;
    my $token = $resp1->{json}{resume_token};

    # State-file surgery (backup-export.t AC27 precedent): remove F's
    # answer from the checkpointed preflight settings_outcome, simulating a
    # corrupted/edited checkpoint between pause and resume.
    my $state = read_state($r->{state_path});
    if (defined $state) {
        delete $state->{phases}{preflight}{items}{settings_outcome}{data}{answers}{F};
        write_state_raw($r->{state_path}, $state);
    } else {
        ok(0, 'SECTION E (AC9): precondition -- state file exists for surgery');
    }

    my $resp2 = run_backup($r, $extra, '--resume', ($token // ''),
        '--answer', (defined $d ? "$d->{id}=add_to_container" : 'export.container.N=add_to_container'));
    isnt($resp2->{exit}, 4, 'SECTION E (AC9): invocation 2 is still accepted despite the edited settings_outcome')
        or diag($resp2->{out} . $resp2->{err});
    unlike(encode_json($resp2->{json} // {}), qr/answer_missing|answer_unknown_id/,
        'SECTION E (AC9): no answer_missing/answer_unknown_id -- the decision ids did not drift');

    my $resp3 = finish_after_content_change($r, $extra, $resp2);
    ok(($resp3->{exit} == 0 || $resp3->{exit} == 20), 'SECTION E (AC9): reaches a terminal status') or diag($resp3->{out} . $resp3->{err});

    my $container = read_container($r);
    is(($container // {})->{F}, 'FGLOBAL',
        'SECTION E (AC9): F is STILL written with the global value -- _do_container_outcome never re-read settings_outcome')
        or diag(encode_json($container // {}));
    my $state3 = read_state($r->{state_path});
    ok((defined $state3 && defined find_note($state3, 'container_followed_global')),
        'SECTION E (AC9): F is still listed in the container_followed_global note');
}

# ===========================================================================
# SECTION F -- AC12 (DC6): SKILL.md wording names the follow rule.
# ===========================================================================
{
    my $skill = -f $SKILL_MD ? (read_text($SKILL_MD) // '') : undef;
    if (defined $skill) {
        my @rows = grep { /^\|\s*container_settings_key\s*\|/ } split /\n/, $skill;
        if (@rows) {
            like($rows[0], qr/container_followed_global/, 'SECTION F (AC12): the container_settings_key row mentions container_followed_global');
            like($rows[0], qr/use[_-]live/i, 'SECTION F (AC12): the container_settings_key row mentions use-live/use_live');
            like($rows[0], qr/export[_-]to[_-]repo/i, 'SECTION F (AC12): the container_settings_key row mentions export-to-repo/export_to_repo');
            my @cells = split /\|/, $rows[0];
            is(scalar(grep { length($_) } @cells) >= 1 ? 1 : 0, 1, 'SECTION F (AC12): the row is non-empty')
        } else {
            ok(0, "SECTION F (AC12): $_") for (
                'the container_settings_key row mentions container_followed_global',
                'the container_settings_key row mentions use-live/use_live',
                'the container_settings_key row mentions export-to-repo/export_to_repo',
            );
        }
        my @settings_rows = grep { /^\|\s*settings_key\s*\|/ } split /\n/, $skill;
        if (@settings_rows) {
            like($settings_rows[0], qr/container/i, 'SECTION F (AC12): the settings_key row mentions the container follow-through');
        } else {
            ok(0, 'SECTION F (AC12): the settings_key row mentions the container follow-through');
        }
        like($skill, qr/## Relaying the report/, 'SECTION F (AC12): SKILL.md has a Relaying the report section');
        if ($skill =~ /## Relaying the report(.*?)(\n## |\z)/s) {
            like($1, qr/container_followed_global/, 'SECTION F (AC12): the Relaying the report section mentions container_followed_global');
        } else {
            ok(0, 'SECTION F (AC12): the Relaying the report section mentions container_followed_global');
        }
    } else {
        ok(0, "SECTION F (AC12): $_") for (
            'the container_settings_key row mentions container_followed_global',
            'the container_settings_key row mentions use-live/use_live',
            'the container_settings_key row mentions export-to-repo/export_to_repo',
            'the settings_key row mentions the container follow-through',
            'SKILL.md has a Relaying the report section',
            'the Relaying the report section mentions container_followed_global',
        );
    }
}

done_testing();
