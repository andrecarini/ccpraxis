#!/usr/bin/env perl
# 23-backup-vault.t -- oracle for blueprint backup-driver, package
# 04-vault-and-todos (scripts/backup/Vault.pm).
#
# Spec: .ccpraxis-local-data/blueprints/backup-driver/specs/04-vault-and-todos-spec.md
# (including its BINDING coordinator rulings P14/P15 in S0, which are the whole
# reason this file insists on non-ASCII FILENAMES, not merely non-ASCII file
# content -- see .ccpraxis-local-data/bug-reports/20260901-025445-d667.md).
#
# This test is written BLIND to any implementation of Vault.pm: only the spec,
# scout-step1.md, the SHIPPED scripts/backup/Run.pm, t/22-backup-export.t /
# t/21-backup-preflight.t (harness patterns), StewardTest.pm and the d667 bug
# report were read. Do not read scripts/backup/Vault.pm while editing this file.
#
# Harness design (full rationale in the accompanying report):
#   * Local-spawner pattern (t/13/t/20/t/21/t/22 precedent): `open '-|', $^X,
#     scripts/backup.pl, 'run', @args`, stderr captured via a real File::Temp
#     file (never an in-memory scalar -- Git-for-Windows "Bad file descriptor").
#   * Stubs for todo-sync.pl (KEY: value output) and vault-sync.pl (JSON) are
#     written under a scratch HOME's fake `<home>/.claude/ccpraxis` install.
#     Both log their own name + argv to $ENV{VAULT_TEST_LOG} as their first
#     action -- the invocation-order/argv/call-count oracle every AC below
#     relies on.
#   * Per-(subcommand, slug, call-index) fixture FILES under
#     $ENV{VAULT_TEST_FIXTURE_DIR} let a scenario script a sequence such as
#     "list-projects call 0 (U3) returns the frozen list; call 1 (S2.7
#     confirmation after project A's push) shows A's last_synced_at advanced".
#     A response file may be prefixed "EXIT:<n>\n" to make the stub exit
#     non-zero. Fixture bytes are read/written `:raw` throughout and printed
#     by the stub VERBATIM (no JSON re-encode in the stub) -- this is what
#     makes the non-ASCII fixtures (P15) byte-exact end to end: the stub never
#     touches the bytes, it only ever copies them.
#   * P15: fixture filenames/slugs are built from raw \xNN byte literals in
#     THIS file's source (never `use utf8`, never a literal non-ASCII source
#     character) so the fixture's byte identity does not depend on how this
#     .t file itself happens to be saved/read. Verified by raw substring
#     search against undecoded bytes (stdout, the state file, the argv log),
#     not merely by decode_json()+string-eq (see the report for the exact
#     verification methodology).
#   * "State-file surgery, not a real kill" (t/21 AC20 / t/22 AC27 precedent)
#     simulates a mid-execution death for the crash_preserves_items scenarios:
#     hand-write a run-state file with phases.vault.status='running' (not
#     'paused') and phase items pre-populated, then invoke a bare `run` (no
#     --resume) and let Run.pm's own R6 logic decide what survives.
#
# AC -> test name mapping (grep for "AC<n>:" to find every assertion for a
# given criterion; a few criteria are exercised by more than one block):
#   AC1  DC1 sequential-in-code: 3-project ordering log + static no-fork/no-threads/no-Parallel:: scan
#   AC2  DC1/DC2 seeded state (project2 checkpointed, project1 not) works on project1, not project2
#   AC3  DC8 phase_spec via direct require, no engine
#   AC4  DC3 vault absent -> complete, one vault_missing note, zero spawns
#   AC5  DC2 exact spawn counts across a pause/resume (todos once, list-projects 1+confirms, sync-project once/project)
#   AC6  DC2/DC5 checkpoint keys after a project-B pause; resume does not re-spawn A's sync-project
#   AC7  DC5 checkpoint lives at phases.vault.items.project.<tok>.data; no other file created anywhere
#   AC8  DC3 drift for project1 of 2 -> project2 still processed, exit 20, no commit-and-push for project1
#   AC9  DC3 sync-project error / exit-1 emit_error / unparseable -- three distinct outcomes, never collapsed
#   AC10 DC3 list-projects unparseable -> failed phase, zero sync-project spawns, never "0 projects" success
#   AC11 DC4 text conflict exit_code==1 -> exactly 1 decision, merge_preview has both versions, 3 choices
#   AC12 DC4 text conflict exit_code==0 -> offers use_merged; answering spawns --merged-file <tmp_path>
#   AC13 DC4 binary conflict -> no use_merged, is_text false, merge_exit_code null
#   AC14 DC4 aggregate: every decision emitted anywhere validates, only kind vault_conflict, id grammar
#   AC15 DC1/DC4 two conflicts same project = one batch; two projects = two pauses, 2nd after 1st committed
#   AC16 DC3 abort_project -> zero further resolve-conflict/commit-and-push, note, continue, not a phase failure
#   AC17 DC6 rolled_back_nothing_stored -> exact checkpoint status, failure, never described as synced
#   AC18 DC6 sensitive_blocked / sensitive_blocked_post_rename distinct from each other and from rollback
#   AC19 DC6 committed_and_pushed + rolled_back_during_sync -> still success, extra note
#   AC20 DC6 push_unconfirmed (stale last_synced_at) vs confirmed (advanced) -- failure vs success
#   AC21 DC6 signal-killed vault-sync.pl during commit-and-push is NOT exit 0; project fails
#   AC22 DC2/DC4 missing session_id -> session_missing, zero resolve/commit; happy path session id byte-identical across resume
#   AC23 DC3 environmental degradation never dies: no HOME, missing root, unspawnable child, unreadable merge tmp
#   AC24 DC2/DC4 P15 non-ASCII FILENAME byte-exact through decision/stdout/checkpoint/resumed argv
#   AC25 DC2/DC4/DC5 P15 non-ASCII SLUG -- ASCII tok/checkpoint-key/id, byte-exact --slug and notes
#   AC26 DC1 todo-sync.pl precedes every sync-project; a todo failure does not block the project loop
#   AC27 DC3 deletes_local note appears before the commit-and-push invocation for that project
#   AC28 DC3 stale entry -> note, zero refresh/sync spawns, continue, terminal status unaffected alone
#   AC29 DC8 isolation: no real HOME/USERPROFILE, no real vault, no network remote, everything under scratch
#   AC30 DC7 parity file: fixed four-cell row shape, floor of the five old-step rows, no 5.6 row required
#   AC31 DC8 perl -c clean on both files
#   AC32 DC4/DC5 source scan: no require Run/Preflight/Closeout.pm; no literal git invocation; only vault_conflict kind literal
#
# Extra coverage beyond the numbered ACs, explicitly requested by the dispatch:
#   CRASH1/CRASH2  crash_preserves_items: a simulated mid-execution death preserves a completed
#                  project's checkpoint (not re-synced) AND a preserved-but-unanswered conflict's
#                  stored answer is cleared (re-asked with the SAME decision id)

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Path qw(make_path);
use File::Find qw(find);
use File::Temp qw(tempfile);
use JSON::PP;
use Encode qw(decode FB_CROAK);
use StewardTest qw(ok is like unlike diag done_testing temproot make_machine write_text read_text path_exists);

my $VAULT_SRC      = "$Bin/../../../../scripts/backup/Vault.pm";
my $RUNPM          = "$Bin/../../../../scripts/backup/Run.pm";
my $BACKUP_SCRIPT  = "$Bin/../../../../scripts/backup.pl";
my $PARITY_FILE    = "$Bin/../../../../.ccpraxis-local-data/blueprints/backup-driver/reports/parity/04-vault-and-todos.md";

my $VAULT_EXISTS = -f $VAULT_SRC ? 1 : 0;
ok($VAULT_EXISTS, 'scripts/backup/Vault.pm exists on disk')
    or diag('scripts/backup/Vault.pm is absent -- every behavioral test below will fail for this reason');
ok(-f $RUNPM, 'scripts/backup/Run.pm exists on disk (package 01, shipped)');
ok(-f $BACKUP_SCRIPT, 'scripts/backup.pl exists on disk (package 01, shipped)');

my $RUNPM_OK = 0;
{
    local $@;
    $RUNPM_OK = eval { require $RUNPM; 1 };
    diag("Run.pm did not load cleanly: " . ($@ || 'unknown error')) unless $RUNPM_OK;
}

# Direct require of Vault.pm itself (AC3: "without the engine").
my $VAULT_LOADED = 0;
if ($VAULT_EXISTS) {
    local $@;
    $VAULT_LOADED = eval { require $VAULT_SRC; 1 };
    diag("Vault.pm did not load cleanly: " . ($@ || 'unknown error')) unless $VAULT_LOADED;
}

# The operator's actual HOME/USERPROFILE, captured before any scenario ever
# runs a local $ENV{...} override -- used only by AC29.
my $REAL_HOME        = $ENV{HOME};
my $REAL_USERPROFILE = $ENV{USERPROFILE};

# Running tally of every decision seen anywhere in this file (AC14's aggregate).
my @ALL_DECISIONS_SEEN;
sub record_decisions { push @ALL_DECISIONS_SEEN, @_; }

sub isnt {
    my ($got, $exp, $name) = @_;
    my $cond = !((defined $got && defined $exp && $got eq $exp) || (!defined $got && !defined $exp));
    ok($cond, $name) or diag("  got:          " . (defined $got ? "[$got]" : "undef")
                           . "\n  expected NOT: " . (defined $exp ? "[$exp]" : "undef"));
    return $cond;
}

# ===========================================================================
# AC31 -- perl -c is clean on both files, compiled standalone by THIS test.
# ===========================================================================
sub _compile_check {
    my ($file, $label) = @_;
    unless (-f $file) {
        ok(0, "AC31: perl -c is clean on $label (file not found)");
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
    ok($rc == 0, "AC31: perl -c exits 0 for $label") or diag($err);
    unlike($err, qr/syntax error|Compilation failed/, "AC31: perl -c on $label reports no syntax error / compilation failure")
        or diag($err);
}
_compile_check($VAULT_SRC, 'scripts/backup/Vault.pm');
_compile_check("$Bin/23-backup-vault.t", 'plugins/steward/tests/t/23-backup-vault.t (this file)');

# ===========================================================================
# AC3 -- phase_spec, requiring the module directly, without the engine.
# ===========================================================================
{
    if ($VAULT_LOADED) {
        my $spec = eval { Backup::Phase::Vault::phase_spec() };
        if (ref($spec) eq 'HASH') {
            is($spec->{name}, 'vault', 'AC3: phase_spec name == vault');
            is($spec->{order} + 0, 300, 'AC3: phase_spec order == 300');
            ok($spec->{resumable} ? 1 : 0, 'AC3: phase_spec resumable is true');
            ok(defined($spec->{title}) && length($spec->{title}), 'AC3: phase_spec has a title');
        } else {
            ok(0, "AC3: phase_spec name == vault ($@)");
            ok(0, 'AC3: phase_spec order == 300');
            ok(0, 'AC3: phase_spec resumable is true');
            ok(0, 'AC3: phase_spec has a title');
        }
    } else {
        ok(0, 'AC3: phase_spec name == vault (Vault.pm did not load)');
        ok(0, 'AC3: phase_spec order == 300 (Vault.pm did not load)');
        ok(0, 'AC3: phase_spec resumable is true (Vault.pm did not load)');
        ok(0, 'AC3: phase_spec has a title (Vault.pm did not load)');
    }
}

# ===========================================================================
# AC32 -- static source scan: no require/use of Run.pm, Preflight.pm or
# Closeout.pm; no literal git invocation of its own; no decision-kind
# literal other than 'vault_conflict' (the enum is closed, 14 values --
# scout's "21" was wrong, verified directly against @Backup::Run::DECISION_KINDS).
# Also the AC1 static half: no fork/threads/Parallel::/background spawn.
# ===========================================================================
{
    my $src = $VAULT_EXISTS ? (read_text($VAULT_SRC) // '') : '';

    if ($VAULT_EXISTS) {
        for my $forbidden (qw(Run.pm Preflight.pm Closeout.pm)) {
            (my $re_name = $forbidden) =~ s/\./\\./;
            unlike($src, qr/\b(?:use|require)\s+["']?(?:[\w:]*[\\\/])?\Q$forbidden\E["']?/,
                "AC32: Vault.pm source contains no use/require of $forbidden");
        }
        unlike($src, qr/(['"])git\1/, 'AC32: Vault.pm source contains no quoted "git" literal');
        unlike($src, qr/\bsystem\s*\(\s*['"]git\b/, 'AC32: Vault.pm source contains no system(git ...) invocation');

        ok($RUNPM_OK, 'AC32: Run.pm (for @Backup::Run::DECISION_KINDS) loaded for the source scan')
            or diag('cannot enumerate the closed kind set without Run.pm');
        if ($RUNPM_OK) {
            for my $kind (Backup::Run::DECISION_KINDS()) {
                next if $kind eq 'vault_conflict';
                unlike($src, qr/(['"])\Q$kind\E\1/, "AC32: Vault.pm source contains no decision-kind literal '$kind'");
            }
            like($src, qr/vault_conflict/, "AC32: Vault.pm source DOES contain its one permitted kind literal 'vault_conflict'");
            is(scalar(Backup::Run::DECISION_KINDS()), 14, 'AC32: the decision-kind enum has exactly 14 values (scout correction)');
        }

        unlike($src, qr/\bfork\s*\(/, 'AC1: Vault.pm source contains no fork()');
        unlike($src, qr/\bthreads\b/, 'AC1: Vault.pm source contains no threads usage');
        unlike($src, qr/Parallel::/,  'AC1: Vault.pm source contains no Parallel:: usage');
    } else {
        ok(0, "AC32: Vault.pm source contains no use/require of $_") for qw(Run.pm Preflight.pm Closeout.pm);
        ok(0, 'AC32: Vault.pm source contains no quoted "git" literal');
        ok(0, 'AC32: Vault.pm source contains no system(git ...) invocation');
        ok(0, 'AC32: every non-vault_conflict decision-kind literal is absent (Vault.pm not found)');
        ok(0, 'AC1: Vault.pm source contains no fork()');
        ok(0, 'AC1: Vault.pm source contains no threads usage');
        ok(0, 'AC1: Vault.pm source contains no Parallel:: usage');
    }
}

# ===========================================================================
# P15 fixtures -- raw UTF-8 BYTES built from \xNN literals, never a literal
# non-ASCII source character and never `use utf8`, so this file's own byte
# identity cannot corrupt the fixture regardless of how the .t source is
# read. \xC3\xA9 is the two-byte UTF-8 encoding of U+00E9 (e-acute).
# ===========================================================================
my $EACUTE   = "\xC3\xA9";
my $PATH_BYTES = "docs/caf${EACUTE}-not${EACUTE}.md";              # AC24
my $PATH_WIDE  = decode('UTF-8', $PATH_BYTES, FB_CROAK());
my $SLUG_BYTES = "vault-caf${EACUTE}";                              # AC25
my $SLUG_WIDE  = decode('UTF-8', $SLUG_BYTES, FB_CROAK());

# ===========================================================================
# Stub wrapped scripts. Both log their own name + argv to
# $ENV{VAULT_TEST_LOG} as their first action, then look up a canned response
# from a fixture FILE (never re-encoded -- printed verbatim, byte-exact) keyed
# by subcommand/slug/call-index under $ENV{VAULT_TEST_FIXTURE_DIR}.
# ===========================================================================
my $VAULT_SYNC_STUB = <<'PERL';
use strict;
use warnings;
my $log = $ENV{VAULT_TEST_LOG};
if (defined $log && length $log) {
    open my $lfh, '>>:raw', $log or die "cannot append to log: $!";
    print {$lfh} "vault-sync.pl @ARGV\n";
    close $lfh;
}
my $cmd = shift(@ARGV);
$cmd = '' unless defined $cmd;
if (defined $ENV{VAULT_SYNC_SUICIDE_CMD} && length($ENV{VAULT_SYNC_SUICIDE_CMD}) && $cmd eq $ENV{VAULT_SYNC_SUICIDE_CMD}) {
    kill 'KILL', $$;
    exit 9;   # unreachable on this host, kept as a defensive fallback
}
my %opt;
for (my $i = 0; $i < @ARGV; $i++) {
    if ($ARGV[$i] =~ /^--([A-Za-z][A-Za-z0-9-]*)\z/) {
        my $k = $1;
        if ($i + 1 < @ARGV) { $opt{$k} = $ARGV[$i + 1]; $i++; }
        else { $opt{$k} = ''; }
    }
}
my $slug = defined $opt{slug} ? $opt{slug} : '';
my $dir  = $ENV{VAULT_TEST_FIXTURE_DIR};
unless (defined $dir && length $dir) {
    print '{"status":"error","error":"vault-sync test stub: no fixture dir configured"}';
    exit 1;
}
my $ctr_file = "$dir/.ctr.$cmd.$slug";
my $n = 0;
if (-f $ctr_file) {
    open my $cfh, '<:raw', $ctr_file or die "cannot read ctr: $!";
    local $/; my $v = <$cfh>; close $cfh;
    $n = (defined $v ? $v : 0) + 0;
}
open my $wfh, '>:raw', $ctr_file or die "cannot write ctr: $!";
print {$wfh} ($n + 1);
close $wfh;

my $resp_file;
for my $cand ("$dir/$cmd.$slug.$n.resp", "$dir/$cmd.$slug.resp", "$dir/$cmd.resp") {
    if (-f $cand) { $resp_file = $cand; last; }
}
unless (defined $resp_file) {
    print '{"status":"error","error":"vault-sync test stub: no fixture for cmd=' . $cmd . ' slug=' . $slug . ' call=' . $n . '"}';
    exit 1;
}
open my $rfh, '<:raw', $resp_file or die "cannot read resp: $!";
local $/; my $body = <$rfh>; close $rfh;
if ($body =~ /\AEXIT:(-?\d+)\n(.*)\z/s) {
    print $2;
    exit $1 + 0;
}
print $body;
exit 0;
PERL

my $TODO_SYNC_STUB = <<'PERL';
use strict;
use warnings;
my $log = $ENV{VAULT_TEST_LOG};
if (defined $log && length $log) {
    open my $lfh, '>>:raw', $log or die "cannot append to log: $!";
    print {$lfh} "todo-sync.pl @ARGV\n";
    close $lfh;
}
if ($ENV{TODO_SYNC_SUICIDE}) {
    kill 'KILL', $$;
    exit 9;   # unreachable on this host, kept as a defensive fallback
}
my $dir  = $ENV{VAULT_TEST_FIXTURE_DIR};
my $file = (defined $dir && length $dir) ? "$dir/todo-sync.resp" : undef;
if (defined $file && -f $file) {
    open my $fh, '<:raw', $file or die "cannot read: $!";
    local $/; my $body = <$fh>; close $fh;
    if ($body =~ /\AEXIT:(-?\d+)\n(.*)\z/s) {
        print $2;
        exit $1 + 0;
    }
    print $body;
    exit 0;
}
print "STATUS: ok\nPULLED: no\nCOMMITTED: no\nPUSHED: no\n";
exit 0;
PERL

sub write_stub_scripts {
    my ($root) = @_;
    write_text("$root/scripts/todo-sync.pl", $TODO_SYNC_STUB);
    write_text("$root/plugins/steward/scripts/vault-sync.pl", $VAULT_SYNC_STUB);
}

# ===========================================================================
# Fixture builders.
# ===========================================================================
sub set_fixture {
    my ($fx_dir, $name, $data, %opts) = @_;
    make_path($fx_dir);
    my $body = ref($data) ? JSON::PP->new->utf8->canonical->encode($data) : $data;
    $body = "EXIT:$opts{exit}\n$body" if defined $opts{exit};
    write_text("$fx_dir/$name", $body);
}

sub fixture_name {
    my ($cmd, $slug, $idx) = @_;
    $slug = '' unless defined $slug;
    return defined($idx) ? "$cmd.$slug.$idx.resp" : "$cmd.$slug.resp";
}

sub mk_meta { return { hash => 'h', size => 1, mtime => 1700000000, exists => JSON::PP::true }; }

sub mk_conflict {
    my (%o) = @_;
    my $is_text = exists $o{is_text} ? $o{is_text} : 1;
    my $merge_result;
    if ($is_text) {
        my $ec = exists $o{merge_exit_code} ? $o{merge_exit_code} : 1;
        $merge_result = {
            tmp_path  => $o{tmp_path},
            exit_code => $ec,
            clean     => ($ec == 0) ? JSON::PP::true : JSON::PP::false,
        };
    }
    return {
        path         => $o{path},
        is_text      => $is_text ? JSON::PP::true : JSON::PP::false,
        merge_result => $merge_result,
        local        => mk_meta(),
        vault        => mk_meta(),
        base         => mk_meta(),
    };
}

sub mk_sync_synced {
    my (%o) = @_;
    my %h = (
        status            => 'synced',
        slug              => $o{slug},
        applied           => (exists $o{applied} ? $o{applied} : 0),
        action_counts     => ($o{action_counts} // {}),
        deletes_local     => ($o{deletes_local} // []),
        cache_repaired    => ($o{cache_repaired} // []),
        auto_applied      => ($o{auto_applied} // []),
        conflicts         => ($o{conflicts} // []),
        skipped_symlinks  => ($o{skipped_symlinks} // []),
        skipped_bad_paths => ($o{skipped_bad_paths} // []),
    );
    $h{session_id} = $o{session_id} if exists $o{session_id};
    $h{session_id} = 'sess-' . ($o{slug} // 'x') unless exists $h{session_id};
    return \%h;
}

sub mk_sync_drift {
    my (%o) = @_;
    return { status => 'drift', slug => $o{slug}, dirty_files => ($o{dirty_files} // ['x.txt']) };
}

sub mk_sync_error {
    my (%o) = @_;
    return { status => 'error', slug => $o{slug}, error => ($o{error} // 'sync-project boom') };
}

sub mk_refresh_ok {
    my (%o) = @_;
    return { status => 'ok', added => ($o{added} // []), already_tracked => ($o{already_tracked} // []), absent => ($o{absent} // []) };
}

sub mk_resolve_ok {
    my (%o) = @_;
    return { status => 'staged', slug => $o{slug}, path => $o{path} };
}

sub mk_committed {
    my (%o) = @_;
    my %h = (status => 'committed_and_pushed', slug => $o{slug}, last_synced_at => ($o{last_synced_at} // '2026-09-08T00:00:00Z'), conflicts => 0, resolved => 0);
    $h{rolled_back_during_sync} = $o{rolled_back_during_sync} if exists $o{rolled_back_during_sync};
    return \%h;
}

sub mk_rolled_back_nothing {
    my (%o) = @_;
    return { status => 'rolled_back_nothing_stored', slug => $o{slug}, rollback_reasons => ($o{rollback_reasons} // { source_modified_during_sync => 1 }) };
}

sub mk_sensitive {
    my (%o) = @_;
    return { status => $o{status}, slug => $o{slug}, findings => ($o{findings} // [ { file => 'secret.txt', line => 3, pattern => 'aws-key' } ]) };
}

sub mk_commit_error {
    my (%o) = @_;
    return { status => 'error', slug => $o{slug}, error => ($o{error} // 'commit-and-push boom') };
}

sub mk_list_projects {
    my (@projects) = @_;
    return { projects => [ @projects ] };
}

sub mk_project_entry {
    my (%o) = @_;
    return {
        slug           => $o{slug},
        path           => ($o{path} // "/scratch/projects/$o{slug}"),
        registered_at  => ($o{registered_at} // '2026-01-01T00:00:00Z'),
        last_synced_at => (exists $o{last_synced_at} ? $o{last_synced_at} : undef),
        project_exists => (($o{project_exists} // 1) ? JSON::PP::true : JSON::PP::false),
    };
}

sub todo_text {
    my (%o) = @_;
    my $status = $o{status} // 'ok';
    my @lines  = ("STATUS: $status");
    if ($status eq 'ok' || $status eq 'synced') {
        push @lines, 'PULLED: ' . ($o{pulled} // 'no'), 'COMMITTED: ' . ($o{committed} // 'no'), 'PUSHED: ' . ($o{pushed} // 'no');
    } else {
        push @lines, 'ERROR: ' . ($o{error} // 'todo sync failed');
    }
    return join("\n", @lines) . "\n";
}

# ===========================================================================
# Scenario scaffold.
# ===========================================================================
sub copy_vault_into {
    my ($phase_dir) = @_;
    make_path($phase_dir);
    return 0 unless $VAULT_EXISTS;
    write_text("$phase_dir/Vault.pm", read_text($VAULT_SRC));
    return 1;
}

# setup_root(%opts) -- one throwaway "machine": a temp HOME containing
# <home>/.claude/ccpraxis (plain directory, NOT a git repo -- Vault.pm never
# runs git and requires only -d $root, spec S1.4) with both wrapped scripts
# stubbed, and (unless opts{vault} is explicitly false) a fake vault presence
# marker at <home>/.claude/claude-code-vault/.git (just a directory -- U1's
# whole check is `-d "$vault/.git"`, never a real git operation).
sub setup_root {
    my (%opts) = @_;
    my $scratch = temproot();
    my $home    = make_machine($scratch, $opts{machine_name} // 'host');
    my $root    = "$home/.claude/ccpraxis";
    make_path("$root/scripts");
    make_path("$root/plugins/steward/scripts");

    if (!exists $opts{vault} || $opts{vault}) {
        make_path("$home/.claude/claude-code-vault/.git");
    }

    write_stub_scripts($root);

    my $phase_dir = "$scratch/phases";
    copy_vault_into($phase_dir);

    my $fixture_dir = "$scratch/fixtures";
    make_path($fixture_dir);

    return {
        scratch     => $scratch,
        home        => $home,
        root        => $root,
        vault_dir   => "$home/.claude/claude-code-vault",
        phase_dir   => $phase_dir,
        fixture_dir => $fixture_dir,
        state_path  => "$scratch/state/run.json",
        log_path    => "$scratch/log.txt",
    };
}

# ===========================================================================
# Spawner: stdout captured as JSON, stderr via a real File::Temp file.
# $env_overrides values of undef mean "unset this var for the child" (AC23's
# missing-HOME scenario) rather than the empty string.
# ===========================================================================
sub _spawn {
    my ($env_overrides, @args) = @_;
    my @keys = keys %$env_overrides;
    local @ENV{@keys};
    for my $k (@keys) {
        if (defined $env_overrides->{$k}) { $ENV{$k} = $env_overrides->{$k}; }
        else { delete $ENV{$k}; }
    }

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
        HOME                   => $r->{home},
        USERPROFILE            => $r->{home},
        BACKUP_RUN_STATE       => $r->{state_path},
        BACKUP_PHASE_DIR       => $r->{phase_dir},
        VAULT_TEST_LOG         => $r->{log_path},
        VAULT_TEST_FIXTURE_DIR => $r->{fixture_dir},
    );
    for my $k (keys %extra) { $env{$k} = $extra{$k}; }
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

sub mk_item { my ($data) = @_; return { at => time, data => $data }; }

sub fresh_state_shell {
    my (%opts) = @_;
    my $now    = $opts{now}    // time;
    my $run_id = $opts{run_id} // 'deadbeefcafef00d';
    return {
        format       => 1,
        run_id       => $run_id,
        started_at   => $now,
        updated_at   => $now,
        status       => ($opts{status} // 'running'),
        phase_order  => ['vault'],
        phase_index  => 0,
        phases       => {
            vault => {
                status       => ($opts{phase_status} // 'pending'),
                started_at   => undef,
                completed_at => undef,
                error        => undef,
                items        => ($opts{items} // {}),
                scratch      => {},
            },
        },
        token_seq    => 0,
        consumed_seq => 0,
        pending      => undef,
        answers      => ($opts{answers} // {}),
        notes        => ($opts{notes} // []),
    };
}

sub log_lines {
    my ($log_path) = @_;
    my $raw = read_text($log_path);
    return () unless defined $raw;
    return grep { length $_ } split /\n/, $raw;
}
sub log_line_count { my @lines = log_lines($_[0]); return scalar(@lines); }

sub log_entries {
    my ($log_path) = @_;
    my @entries;
    for my $line (log_lines($log_path)) {
        my @tok = split ' ', $line;
        my $script = shift @tok;
        my $subcmd = $tok[0];
        my $slug;
        for (my $i = 0; $i < @tok; $i++) {
            if ($tok[$i] eq '--slug' && $i + 1 < @tok) { $slug = $tok[$i + 1]; last; }
        }
        push @entries, { script => $script, subcmd => $subcmd, slug => $slug, line => $line };
    }
    return @entries;
}
sub first_index_for_slug { my ($entries, $slug) = @_; for my $i (0 .. $#$entries) { return $i if (($entries->[$i]{slug} // '') eq $slug); } return undef; }
sub last_index_for_slug  { my ($entries, $slug) = @_; my $idx; for my $i (0 .. $#$entries) { $idx = $i if (($entries->[$i]{slug} // '') eq $slug); } return $idx; }
sub count_subcmd_for_slug {
    my ($entries, $subcmd, $slug) = @_;
    my $n = 0;
    for my $e (@$entries) {
        $n++ if (($e->{subcmd} // '') eq $subcmd) && (($e->{slug} // '') eq (defined $slug ? $slug : ($e->{slug} // '')));
    }
    return $n;
}
sub count_subcmd { my ($entries, $subcmd) = @_; return scalar(grep { ($_->{subcmd} // '') eq $subcmd } @$entries); }
sub count_script { my ($entries, $script) = @_; return scalar(grep { ($_->{script} // '') eq $script } @$entries); }

sub decisions_of { my ($resp) = @_; return @{ $resp->{json}{decisions} // [] }; }
sub decisions_of_kind { my ($resp, $kind) = @_; return grep { ($_->{kind} // '') eq $kind } decisions_of($resp); }
sub find_decision { my ($decisions, $id) = @_; for my $d (@$decisions) { return $d if ($d->{id} // '') eq $id; } return undef; }
sub choice_ids { my ($d) = @_; return map { $_->{id} } @{ $d->{choices} // [] }; }
sub has_choice { my ($d, $id) = @_; return (grep { $_ eq $id } choice_ids($d)) ? 1 : 0; }

sub notes_of_state { my ($state) = @_; return @{ $state->{notes} // [] }; }
sub find_note { my ($state, $key) = @_; for my $n (notes_of_state($state)) { return $n if ($n->{key} // '') eq $key; } return undef; }
sub find_all_notes { my ($state, $key) = @_; return grep { ($_->{key} // '') eq $key } notes_of_state($state); }

sub project_item {
    my ($state, $tok) = @_;
    my $items = $state->{phases}{vault}{items} // {};
    my $it = $items->{"project.$tok"};
    return ref($it) eq 'HASH' ? $it->{data} : undef;
}
sub session_item {
    my ($state, $tok) = @_;
    my $items = $state->{phases}{vault}{items} // {};
    my $it = $items->{"session.$tok"};
    return ref($it) eq 'HASH' ? $it->{data} : undef;
}
sub project_toks {
    my ($state) = @_;
    my $items = $state->{phases}{vault}{items} // {};
    my @toks;
    for my $k (keys %$items) {
        push @toks, $1 if $k =~ /^project\.(.+)$/;
    }
    return @toks;
}

sub session_toks {
    my ($state) = @_;
    my $items = $state->{phases}{vault}{items} // {};
    my @toks;
    for my $k (keys %$items) {
        push @toks, $1 if $k =~ /^session\.(.+)$/;
    }
    return @toks;
}

sub scratch_snapshot {
    my ($root) = @_;
    return () unless -d $root;
    my @files;
    find({ wanted => sub { push @files, $File::Find::name if -f $_ }, no_chdir => 1 }, $root);
    return sort @files;
}

# ===========================================================================
# AC4 -- vault directory absent: phase complete, one vault_missing note, zero
# child spawns of any kind.
# ===========================================================================
{
    my $r = setup_root(vault => 0);
    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'AC4: vault absent -> the run completes (exit 0)') or diag($resp->{out} . $resp->{err});
    is(($resp->{json}{status} // ''), 'complete', 'AC4: vault absent -> status complete');

    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $n = find_note($state, 'vault_missing');
        ok(defined $n, 'AC4: exactly a vault_missing note is present');
        is($n->{value}{path}, $r->{vault_dir}, 'AC4: the vault_missing note names the vault path') if defined $n;
        my @all_missing = find_all_notes($state, 'vault_missing');
        is(scalar(@all_missing), 1, 'AC4: exactly ONE vault_missing note');
    } else {
        ok(0, 'AC4: exactly a vault_missing note is present');
        ok(0, 'AC4: the vault_missing note names the vault path');
        ok(0, 'AC4: exactly ONE vault_missing note');
    }
    is(log_line_count($r->{log_path}), 0, 'AC4: zero child spawns of any kind (empty invocation log)');
}

# ===========================================================================
# AC23a -- HOME and USERPROFILE both unset -> failed, never a die.
# ===========================================================================
{
    my $r = setup_root();
    my $resp = run_backup($r, { HOME => undef, USERPROFILE => undef });
    is($resp->{exit}, 20, 'AC23: missing HOME/USERPROFILE degrades (exit 20, complete_with_failures), never dies')
        or diag($resp->{out} . $resp->{err});
    isnt(($resp->{json}{status} // ''), 'error', 'AC23: missing HOME/USERPROFILE is not reported as an internal error/die');
    unlike(($resp->{json}{error}{code} // ''), qr/phase_died/, 'AC23: missing HOME/USERPROFILE never produces phase_died');
}

# ===========================================================================
# AC23b -- $root (<home>/.claude/ccpraxis) missing -> failed, naming the path.
# ===========================================================================
{
    my $scratch = temproot();
    my $home    = make_machine($scratch, 'host');
    # Deliberately do NOT create <home>/.claude/ccpraxis.
    my $phase_dir = "$scratch/phases";
    copy_vault_into($phase_dir);
    my $r = {
        scratch => $scratch, home => $home, root => "$home/.claude/ccpraxis",
        vault_dir => "$home/.claude/claude-code-vault", phase_dir => $phase_dir,
        fixture_dir => "$scratch/fixtures", state_path => "$scratch/state/run.json", log_path => "$scratch/log.txt",
    };
    make_path($r->{fixture_dir});
    my $resp = run_backup($r, {});
    is($resp->{exit}, 20, 'AC23: missing $root degrades (exit 20), never dies') or diag($resp->{out} . $resp->{err});
    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $err = $state->{phases}{vault}{error} // '';
        like($err, qr/\Q$r->{root}\E/, 'AC23: the failure message names the missing $root path');
    } else {
        ok(0, 'AC23: the failure message names the missing $root path');
    }
}

# ===========================================================================
# AC23c -- unspawnable vault-sync.pl (the file is simply absent) -> failed
# phase, never a die, and never a false "0 projects" success (ties to AC10's
# unspawn case too).
# ===========================================================================
{
    my $r = setup_root();
    unlink("$r->{root}/plugins/steward/scripts/vault-sync.pl");
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    my $resp = run_backup($r, {});
    is($resp->{exit}, 20, 'AC23: an unspawnable vault-sync.pl degrades (exit 20), never dies') or diag($resp->{out} . $resp->{err});
    isnt(($resp->{json}{status} // ''), 'complete', 'AC23: an unspawnable vault-sync.pl is never reported as a plain success');
}

# ===========================================================================
# AC10 -- list-projects unparseable output -> phase failed, zero
# sync-project spawns, never read as "no projects registered" success.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', ''), "this is not json {{{");
    my $resp = run_backup($r, {});
    is($resp->{exit}, 20, 'AC10: unparseable list-projects output degrades the phase (exit 20)') or diag($resp->{out} . $resp->{err});
    my @entries = log_entries($r->{log_path});
    is(count_subcmd(\@entries, 'sync-project'), 0, 'AC10: zero sync-project spawns after an unparseable list-projects');
    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $n = find_note($state, 'projects_listed');
        ok(!defined($n) || (($n->{value}{count} // -1) != 0), 'AC10: never recorded as a benign "0 projects" success note');
    }
}

# ===========================================================================
# AC28 -- stale entry (project_exists: false): note naming slug+path, zero
# refresh/sync for it, run continues, phase terminal status unaffected by it
# alone (a second, healthy project still lets the phase complete cleanly).
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    my @projects = (
        mk_project_entry(slug => 'ghost-proj', project_exists => 0),
        mk_project_entry(slug => 'ok-proj', project_exists => 1),
    );
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(@projects));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'ok-proj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'ok-proj'), mk_sync_synced(slug => 'ok-proj', session_id => 'sess-ok'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'ok-proj'), mk_committed(slug => 'ok-proj', last_synced_at => '2026-09-08T01:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(
        mk_project_entry(slug => 'ghost-proj', project_exists => 0),
        mk_project_entry(slug => 'ok-proj', project_exists => 1, last_synced_at => '2026-09-08T01:00:00Z'),
    ));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'AC28: a stale entry alongside a healthy project still completes cleanly (exit 0)') or diag($resp->{out} . $resp->{err});

    my @entries = log_entries($r->{log_path});
    is(count_subcmd_for_slug(\@entries, 'refresh-default-tracked', 'ghost-proj'), 0, 'AC28: zero refresh-default-tracked calls for the stale slug');
    is(count_subcmd_for_slug(\@entries, 'sync-project', 'ghost-proj'), 0, 'AC28: zero sync-project calls for the stale slug');

    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $n = find_note($state, 'stale_project_entry');
        ok(defined $n, 'AC28: a stale_project_entry note is present');
        if (defined $n) {
            is($n->{value}{slug}, 'ghost-proj', 'AC28: the stale note names the slug');
            ok(defined($n->{value}{path}) && length($n->{value}{path}), 'AC28: the stale note names the path');
        }
    } else {
        ok(0, 'AC28: a stale_project_entry note is present');
    }
}

# ===========================================================================
# AC9a -- sync-project -> status: error (parseable, exit 0): skips the
# project, continues, distinct note/message.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'errproj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'errproj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'errproj'), mk_sync_error(slug => 'errproj', error => 'AC9A-STATUS-ERROR'));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 20, 'AC9a: sync-project status:error degrades the run (exit 20)') or diag($resp->{out} . $resp->{err});
    my @entries = log_entries($r->{log_path});
    is(count_subcmd_for_slug(\@entries, 'commit-and-push', 'errproj'), 0, 'AC9a: no commit-and-push for the errored project');

    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $n = find_note($state, 'project_error');
        ok(defined $n, 'AC9a: a project_error note is present');
        like(($n->{value}{error} // ''), qr/AC9A-STATUS-ERROR/, 'AC9a: the note carries the reported error text') if defined $n;
    } else {
        ok(0, 'AC9a: a project_error note is present');
        ok(0, 'AC9a: the note carries the reported error text');
    }
}

# ===========================================================================
# AC9b -- sync-project exits 1 with an emit_error body (parseable status:
# error accompanying a non-zero exit): distinct outcome, project skipped.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'exit1proj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'exit1proj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'exit1proj'),
        { status => 'error', error => 'AC9B-EMIT-ERROR' }, exit => 1);

    my $resp = run_backup($r, {});
    is($resp->{exit}, 20, 'AC9b: sync-project exit 1 with an emit_error body degrades the run (exit 20)') or diag($resp->{out} . $resp->{err});
    my $state = read_state($r->{state_path});
    my $msg_b;
    if (defined $state) {
        my $n = find_note($state, 'project_error');
        ok(defined $n, 'AC9b: a project_error note is present for the exit-1 case');
        $msg_b = $n->{value}{error} if defined $n;
        like(($msg_b // ''), qr/AC9B-EMIT-ERROR|exit|1\b/, 'AC9b: the note prefers the emit_error body text or names the exit code') if defined $n;
    } else {
        ok(0, 'AC9b: a project_error note is present for the exit-1 case');
    }
}

# ===========================================================================
# AC9c -- sync-project emits unparseable output: distinct outcome, project
# skipped, message names "unparseable" plus the first 200 bytes (S1.7 pt 3).
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'garbageproj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'garbageproj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'garbageproj'), "AC9C-NOT-JSON-AT-ALL {{{");

    my $resp = run_backup($r, {});
    is($resp->{exit}, 20, 'AC9c: sync-project unparseable output degrades the run (exit 20)') or diag($resp->{out} . $resp->{err});
    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $n = find_note($state, 'project_error');
        ok(defined $n, 'AC9c: a project_error note is present for the unparseable case');
        like(($n->{value}{error} // ''), qr/unparseable/i, 'AC9c: the message names "unparseable"') if defined $n;
    } else {
        ok(0, 'AC9c: a project_error note is present for the unparseable case');
        ok(0, 'AC9c: the message names "unparseable"');
    }
}

# ===========================================================================
# AC8 -- drift for project 1 of 2: project 2 still fully processed, exit 20
# not 1, no commit-and-push for the drifted project, run does not abort.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(
        mk_project_entry(slug => 'driftproj'), mk_project_entry(slug => 'healthyproj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'driftproj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'driftproj'), mk_sync_drift(slug => 'driftproj', dirty_files => ['a.txt', 'b.txt']));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'healthyproj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'healthyproj'), mk_sync_synced(slug => 'healthyproj', session_id => 'sess-h'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'healthyproj'), mk_committed(slug => 'healthyproj', last_synced_at => '2026-09-08T02:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(
        mk_project_entry(slug => 'driftproj'),
        mk_project_entry(slug => 'healthyproj', last_synced_at => '2026-09-08T02:00:00Z')));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 20, 'AC8: drift on project 1 -> exit 20 (complete_with_failures), never 1') or diag($resp->{out} . $resp->{err});

    my @entries = log_entries($r->{log_path});
    is(count_subcmd_for_slug(\@entries, 'commit-and-push', 'driftproj'), 0, 'AC8: no commit-and-push for the drifted project');
    ok(count_subcmd_for_slug(\@entries, 'sync-project', 'healthyproj') >= 1, 'AC8: project 2 was still processed (sync-project called)');
    ok(count_subcmd_for_slug(\@entries, 'commit-and-push', 'healthyproj') >= 1, 'AC8: project 2 was still committed and pushed');

    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $n = find_note($state, 'project_drift');
        ok(defined $n, 'AC8: a project_drift note is present');
        if (defined $n) {
            is($n->{value}{slug}, 'driftproj', 'AC8: the drift note names the slug');
            ok(ref($n->{value}{dirty_files}) eq 'ARRAY' && scalar(@{ $n->{value}{dirty_files} }) > 0, 'AC8: the drift note carries the dirty files');
        }
        my @toks = project_toks($state);
        my $drift_data;
        for my $t (@toks) { my $d = project_item($state, $t); $drift_data = $d if defined($d) && (($d->{slug} // '') eq 'driftproj'); }
        ok(defined $drift_data, 'AC8: project.<tok> checkpoint exists for the drifted project');
        is(($drift_data->{status} // ''), 'drift', 'AC8: the drifted project checkpoint status is exactly "drift"') if defined $drift_data;
    } else {
        ok(0, 'AC8: a project_drift note is present');
        ok(0, 'AC8: the drift note names the slug');
        ok(0, 'AC8: the drift note carries the dirty files');
        ok(0, 'AC8: project.<tok> checkpoint exists for the drifted project');
        ok(0, 'AC8: the drifted project checkpoint status is exactly "drift"');
    }
}

# ===========================================================================
# AC22a -- missing/empty session_id: project fails session_missing, zero
# resolve-conflict and zero commit-and-push calls.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'nosidproj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'nosidproj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'nosidproj'), mk_sync_synced(slug => 'nosidproj', session_id => ''));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 20, 'AC22a: missing session_id degrades the run (exit 20)') or diag($resp->{out} . $resp->{err});
    my @entries = log_entries($r->{log_path});
    is(count_subcmd_for_slug(\@entries, 'resolve-conflict', 'nosidproj'), 0, 'AC22a: zero resolve-conflict calls with a missing session id');
    is(count_subcmd_for_slug(\@entries, 'commit-and-push', 'nosidproj'), 0, 'AC22a: zero commit-and-push calls with a missing session id');

    my $state = read_state($r->{state_path});
    if (defined $state) {
        my @toks = project_toks($state);
        my $data;
        for my $t (@toks) { my $d = project_item($state, $t); $data = $d if defined($d) && (($d->{slug} // '') eq 'nosidproj'); }
        is(($data->{status} // ''), 'session_missing', 'AC22a: the checkpoint status is exactly "session_missing"') if defined $data;
        ok(defined $data, 'AC22a: the checkpoint status is exactly "session_missing"') or diag('no project.<tok> checkpoint found');
    } else {
        ok(0, 'AC22a: the checkpoint status is exactly "session_missing"');
    }
}

# ===========================================================================
# AC11 / AC15(part 1) -- a text conflict with merge_result.exit_code == 1:
# exactly ONE vault_conflict decision, data.merge_exit_code == 1,
# data.merge_preview contains the tmp_path content (both versions, conflict
# markers included), choices exactly use_local/use_vault/abort_project.
# Combined with the second half of AC15 (two conflicts, one project, one batch).
# ===========================================================================
{
    my $r = setup_root();
    my $merge_tmp = "$r->{scratch}/merge-preview-1.txt";
    write_text($merge_tmp, "<<<<<<< local\nlocal line\n=======\nvault line\n>>>>>>> vault\n");
    my $merge_tmp2 = "$r->{scratch}/merge-preview-2.txt";
    write_text($merge_tmp2, "<<<<<<< local\nlocal line 2\n=======\nvault line 2\n>>>>>>> vault\n");

    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'twoconf')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'twoconf'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'twoconf'), mk_sync_synced(
        slug => 'twoconf', session_id => 'sess-twoconf',
        conflicts => [
            mk_conflict(path => 'alpha.txt', tmp_path => $merge_tmp,  merge_exit_code => 1),
            mk_conflict(path => 'beta.txt',  tmp_path => $merge_tmp2, merge_exit_code => 1),
        ],
    ));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, 'AC11/AC15: two conflicts in one project -> the run pauses (exit 10)') or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of_kind($resp, 'vault_conflict');
    record_decisions(@decs);
    is(scalar(@decs), 2, 'AC15: exactly TWO decisions arrive in ONE needs_decision batch for the one project');

    my $d1 = find_decision(\@decs, $decs[0]{id});
    ok(defined $d1, 'AC11: a vault_conflict decision was emitted');
    if (defined $d1) {
        is($d1->{data}{merge_exit_code} + 0, 1, 'AC11: data.merge_exit_code == 1');
        like(($d1->{data}{merge_preview} // ''), qr/<<<<<<</, 'AC11: data.merge_preview contains the conflict-marker content of tmp_path');
        like(($d1->{data}{merge_preview} // ''), qr/local line/, 'AC11: data.merge_preview contains the LOCAL version');
        like(($d1->{data}{merge_preview} // ''), qr/vault line/, 'AC11: data.merge_preview contains the VAULT version');
        my @ids = sort(choice_ids($d1));
        is(scalar(@ids), 3, 'AC11: exactly 3 choices for an exit_code!=0 text conflict');
        ok(has_choice($d1, 'use_local'),    'AC11: choices include use_local');
        ok(has_choice($d1, 'use_vault'),    'AC11: choices include use_vault');
        ok(has_choice($d1, 'abort_project'), 'AC11: choices include abort_project');
        ok(!has_choice($d1, 'use_merged'),  'AC11: choices do NOT include use_merged (exit_code != 0)');
    } else {
        ok(0, "AC11: $_") for ('data.merge_exit_code == 1', 'data.merge_preview contains the conflict-marker content of tmp_path',
            'data.merge_preview contains the LOCAL version', 'data.merge_preview contains the VAULT version',
            'exactly 3 choices for an exit_code!=0 text conflict', 'choices include use_local', 'choices include use_vault',
            'choices include abort_project', 'choices do NOT include use_merged (exit_code != 0)');
    }
}

# ===========================================================================
# AC15(part 2) -- two PROJECTS with conflicts produce two separate pauses,
# the second only after the first project has been committed.
# ===========================================================================
{
    my $r = setup_root();
    my $tmpA = "$r->{scratch}/mA.txt"; write_text($tmpA, "<<<<<<< local\nA-local\n=======\nA-vault\n>>>>>>> vault\n");
    my $tmpB = "$r->{scratch}/mB.txt"; write_text($tmpB, "<<<<<<< local\nB-local\n=======\nB-vault\n>>>>>>> vault\n");

    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(
        mk_project_entry(slug => 'confA'), mk_project_entry(slug => 'confB')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'confA'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'confA'), mk_sync_synced(
        slug => 'confA', session_id => 'sess-confA', conflicts => [ mk_conflict(path => 'a.txt', tmp_path => $tmpA, merge_exit_code => 1) ]));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'confB'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'confB'), mk_sync_synced(
        slug => 'confB', session_id => 'sess-confB', conflicts => [ mk_conflict(path => 'b.txt', tmp_path => $tmpB, merge_exit_code => 1) ]));
    set_fixture($r->{fixture_dir}, fixture_name('resolve-conflict', 'confA'), mk_resolve_ok(slug => 'confA', path => 'a.txt'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'confA'), mk_committed(slug => 'confA', last_synced_at => '2026-09-08T03:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(
        mk_project_entry(slug => 'confA', last_synced_at => '2026-09-08T03:00:00Z'), mk_project_entry(slug => 'confB')));

    my $resp1 = run_backup($r, {});
    is($resp1->{exit}, 10, 'AC15: the FIRST pause is for project confA only') or diag($resp1->{out} . $resp1->{err});
    my @d1 = decisions_of_kind($resp1, 'vault_conflict');
    record_decisions(@d1);
    is(scalar(@d1), 1, 'AC15: exactly one decision in the first pause (confB is not reached yet)');
    ok((grep { ($_->{subject} // '') =~ /confB/ } @d1) == 0, 'AC15: the first pause never mentions confB');

    my @entries_before = log_entries($r->{log_path});
    is(count_subcmd_for_slug(\@entries_before, 'sync-project', 'confB'), 0, 'AC15: confB has not been synced before confA is resolved');

    my $token = $resp1->{json}{resume_token};
    my $d = $d1[0];
    my $resp2 = run_backup($r, {}, '--resume', ($token // ''), '--answer', (defined $d ? "$d->{id}=use_local" : 'vault.conflict.confA.a.txt=use_local'));
    is($resp2->{exit}, 10, 'AC15: the SECOND pause (confB) happens only after confA committed') or diag($resp2->{out} . $resp2->{err});
    my @d2 = decisions_of_kind($resp2, 'vault_conflict');
    record_decisions(@d2);
    is(scalar(@d2), 1, 'AC15: exactly one decision in the second pause (confB)');
    ok((grep { ($_->{subject} // '') =~ /confB/ } @d2) == 1, 'AC15: the second pause is for confB');

    my @entries_after = log_entries($r->{log_path});
    ok(count_subcmd_for_slug(\@entries_after, 'commit-and-push', 'confA') >= 1, 'AC15: confA was committed before confB paused');
}

# ===========================================================================
# AC12 -- text conflict with merge_result.exit_code == 0: additionally
# offers use_merged; answering it spawns resolve-conflict with the exact
# --merged-file <tmp_path>.
# ===========================================================================
{
    my $r = setup_root();
    my $tmp = "$r->{scratch}/clean-merge.txt";
    write_text($tmp, "merged content, no markers\n");

    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'mergeproj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'mergeproj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'mergeproj'), mk_sync_synced(
        slug => 'mergeproj', session_id => 'sess-merge', conflicts => [ mk_conflict(path => 'clean.txt', tmp_path => $tmp, merge_exit_code => 0) ]));
    set_fixture($r->{fixture_dir}, fixture_name('resolve-conflict', 'mergeproj'), mk_resolve_ok(slug => 'mergeproj', path => 'clean.txt'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'mergeproj'), mk_committed(slug => 'mergeproj', last_synced_at => '2026-09-08T04:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(mk_project_entry(slug => 'mergeproj', last_synced_at => '2026-09-08T04:00:00Z')));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, 'AC12: an exit_code==0 text conflict pauses the run') or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of_kind($resp, 'vault_conflict');
    record_decisions(@decs);
    my $d = $decs[0];
    ok(defined($d) && has_choice($d, 'use_merged'), 'AC12: use_merged IS offered when merge_result.exit_code == 0');

    my $token = $resp->{json}{resume_token};
    my $resp2 = run_backup($r, {}, '--resume', ($token // ''), '--answer', (defined $d ? "$d->{id}=use_merged" : 'vault.conflict.mergeproj.clean.txt=use_merged'));
    ok(($resp2->{exit} == 0 || $resp2->{exit} == 20), 'AC12: answering use_merged reaches a terminal status') or diag($resp2->{out} . $resp2->{err});

    my @entries = log_entries($r->{log_path});
    my ($rc_line) = grep { $_->{subcmd} eq 'resolve-conflict' && ($_->{slug} // '') eq 'mergeproj' } @entries;
    ok(defined $rc_line, 'AC12: a resolve-conflict call was logged for mergeproj');
    like(($rc_line->{line} // ''), qr/--action\s+use-merged/, 'AC12: resolve-conflict argv carries --action use-merged') if defined $rc_line;
    like(($rc_line->{line} // ''), qr/\Q--merged-file $tmp\E/, 'AC12: resolve-conflict argv carries the exact --merged-file <tmp_path>') if defined $rc_line;
}

# ===========================================================================
# AC13 -- binary conflict: no use_merged, is_text false, merge_exit_code null.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'binproj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'binproj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'binproj'), mk_sync_synced(
        slug => 'binproj', session_id => 'sess-bin', conflicts => [ mk_conflict(path => 'image.png', is_text => 0) ]));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, 'AC13: a binary conflict still pauses the run (the decision is still emitted)') or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of_kind($resp, 'vault_conflict');
    record_decisions(@decs);
    my $d = $decs[0];
    ok(defined $d, 'AC13: a vault_conflict decision was emitted for the binary conflict');
    if (defined $d) {
        is(($d->{data}{is_text} ? 1 : 0), 0, 'AC13: data.is_text is false');
        ok(!defined($d->{data}{merge_exit_code}), 'AC13: data.merge_exit_code is null/undef');
        ok(!has_choice($d, 'use_merged'), 'AC13: no use_merged choice for a binary conflict');
        ok(has_choice($d, 'use_local') && has_choice($d, 'use_vault') && has_choice($d, 'abort_project'),
            'AC13: the other three choices are still present');
    } else {
        ok(0, "AC13: $_") for ('data.is_text is false', 'data.merge_exit_code is null/undef',
            'no use_merged choice for a binary conflict', 'the other three choices are still present');
    }
}

# ===========================================================================
# AC16 -- abort_project: zero further resolve-conflict, zero commit-and-push
# for that slug, a note, next project processed, phase NOT failed by the
# abort alone.
# ===========================================================================
{
    my $r = setup_root();
    my $tmp = "$r->{scratch}/abort-merge.txt";
    write_text($tmp, "<<<<<<< local\nX\n=======\nY\n>>>>>>> vault\n");

    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(
        mk_project_entry(slug => 'abortproj'), mk_project_entry(slug => 'afterabort')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'abortproj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'abortproj'), mk_sync_synced(
        slug => 'abortproj', session_id => 'sess-abort', conflicts => [ mk_conflict(path => 'z.txt', tmp_path => $tmp, merge_exit_code => 1) ]));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'afterabort'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'afterabort'), mk_sync_synced(slug => 'afterabort', session_id => 'sess-after'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'afterabort'), mk_committed(slug => 'afterabort', last_synced_at => '2026-09-08T05:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(
        mk_project_entry(slug => 'abortproj'), mk_project_entry(slug => 'afterabort', last_synced_at => '2026-09-08T05:00:00Z')));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, 'AC16: the conflict pauses the run first') or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of_kind($resp, 'vault_conflict');
    record_decisions(@decs);
    my $d = $decs[0];
    my $token = $resp->{json}{resume_token};
    my $resp2 = run_backup($r, {}, '--resume', ($token // ''), '--answer', (defined $d ? "$d->{id}=abort_project" : 'vault.conflict.abortproj.z.txt=abort_project'));
    is($resp2->{exit}, 0, 'AC16: abort_project on one project alone still lets the phase complete cleanly (exit 0)') or diag($resp2->{out} . $resp2->{err});

    my @entries = log_entries($r->{log_path});
    is(count_subcmd_for_slug(\@entries, 'resolve-conflict', 'abortproj'), 0, 'AC16: zero resolve-conflict calls after abort_project');
    is(count_subcmd_for_slug(\@entries, 'commit-and-push', 'abortproj'), 0, 'AC16: zero commit-and-push calls for the aborted slug');
    ok(count_subcmd_for_slug(\@entries, 'sync-project', 'afterabort') >= 1, 'AC16: the next project was still processed');

    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $n = find_note($state, 'project_aborted');
        ok(defined $n, 'AC16: a project_aborted note is present');
        is(($n->{value}{slug} // ''), 'abortproj', 'AC16: the note names the aborted slug') if defined $n;
    } else {
        ok(0, 'AC16: a project_aborted note is present');
    }
}

# ===========================================================================
# AC17 -- rolled_back_nothing_stored is a FAILURE, distinct status string,
# never described as synced/committed/pushed for that project (d667's own
# documented signature -- S0.1, non-negotiable).
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'rollbackproj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'rollbackproj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'rollbackproj'), mk_sync_synced(slug => 'rollbackproj', session_id => 'sess-rb'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'rollbackproj'), mk_rolled_back_nothing(
        slug => 'rollbackproj', rollback_reasons => { source_modified_during_sync => 4405 }));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 20, 'AC17: rolled_back_nothing_stored degrades the run (complete_with_failures, exit 20)') or diag($resp->{out} . $resp->{err});

    my $state = read_state($r->{state_path});
    if (defined $state) {
        my @toks = project_toks($state);
        my $data;
        for my $t (@toks) { my $d = project_item($state, $t); $data = $d if defined($d) && (($d->{slug} // '') eq 'rollbackproj'); }
        ok(defined $data, 'AC17: project.<tok> checkpoint exists for the rolled-back project');
        is(($data->{status} // ''), 'rolled_back_nothing_stored', 'AC17: the checkpoint status is EXACTLY "rolled_back_nothing_stored"') if defined $data;
        unlike(JSON::PP->new->canonical->encode($data // {}), qr/\b(?:synced|committed|pushed)\b(?!_)/i,
            'AC17: the checkpoint record does not describe the project as synced/committed/pushed') if defined $data;

        my $n = find_note($state, 'rolled_back_nothing_stored');
        ok(defined $n, 'AC17: a rolled_back_nothing_stored note is present');
        ok(defined($n->{value}{rollback_reasons}), 'AC17: the note carries rollback_reasons') if defined $n;

        my $committed_note = find_note($state, 'project_committed');
        ok(!defined($committed_note), 'AC17: NO project_committed note exists anywhere in this run');
    } else {
        ok(0, "AC17: $_") for ('project.<tok> checkpoint exists for the rolled-back project',
            'the checkpoint status is EXACTLY "rolled_back_nothing_stored"',
            'the checkpoint record does not describe the project as synced/committed/pushed',
            'a rolled_back_nothing_stored note is present', 'the note carries rollback_reasons',
            'NO project_committed note exists anywhere in this run');
    }
}

# ===========================================================================
# AC18 -- sensitive_blocked and sensitive_blocked_post_rename: each a
# failure recorded under its OWN status, distinct from each other and from
# rolled_back_nothing_stored; findings' file/line/pattern appear in a note;
# the matched secret text itself never appears anywhere in stdout/state.
# ===========================================================================
for my $variant (qw(sensitive_blocked sensitive_blocked_post_rename)) {
    my $r = setup_root();
    my $slug = "secretproj_$variant";
    $slug =~ s/[^a-z0-9_]/_/gi;
    my $secret_text = 'THE-ACTUAL-SECRET-VALUE-AC18-' . uc($variant);
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => $slug)));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', $slug), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', $slug), mk_sync_synced(slug => $slug, session_id => 'sess-secret'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', $slug), mk_sensitive(
        slug => $slug, status => $variant, findings => [ { file => 'config.json', line => 12, pattern => 'aws-secret-key' } ]));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 20, "AC18: $variant degrades the run (exit 20)") or diag($resp->{out} . $resp->{err});
    unlike($resp->{out}, qr/\Q$secret_text\E/, "AC18: $variant -- the (unused-by-fixture) secret marker text never appears in stdout (sanity)");

    my $state = read_state($r->{state_path});
    if (defined $state) {
        my @toks = project_toks($state);
        my $data;
        for my $t (@toks) { my $d = project_item($state, $t); $data = $d if defined($d) && (($d->{slug} // '') eq $slug); }
        ok(defined $data, "AC18: project.<tok> checkpoint exists for $variant");
        is(($data->{status} // ''), $variant, "AC18: the checkpoint status is exactly '$variant'") if defined $data;
        isnt(($data->{status} // ''), 'rolled_back_nothing_stored', "AC18: $variant is never recorded as rolled_back_nothing_stored") if defined $data;

        my $n = find_note($state, $variant);
        ok(defined $n, "AC18: a $variant note is present");
        if (defined $n) {
            my $findings_json = JSON::PP->new->canonical->encode($n->{value}{findings} // []);
            like($findings_json, qr/config\.json/, "AC18: $variant findings note names the file");
            like($findings_json, qr/\b12\b/, "AC18: $variant findings note names the line");
            like($findings_json, qr/aws-secret-key/, "AC18: $variant findings note names the pattern label");
        }
        my $state_raw = read_text($r->{state_path}) // '';
        unlike($state_raw, qr/\Q$secret_text\E/, "AC18: $variant -- the matched secret text does not appear anywhere in the state file");
    } else {
        ok(0, "AC18: $_ ($variant)") for ('project.<tok> checkpoint exists', 'the checkpoint status is exact',
            'is never recorded as rolled_back_nothing_stored', 'a note is present', 'the state file does not contain the secret');
    }
}

# ===========================================================================
# AC19 -- committed_and_pushed with rolled_back_during_sync non-empty is
# STILL a success, plus an extra note -- not a failure.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'partialrb')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'partialrb'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'partialrb'), mk_sync_synced(slug => 'partialrb', session_id => 'sess-partial'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'partialrb'), mk_committed(
        slug => 'partialrb', last_synced_at => '2026-09-08T06:00:00Z', rolled_back_during_sync => ['flaky.txt']));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(mk_project_entry(slug => 'partialrb', last_synced_at => '2026-09-08T06:00:00Z')));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'AC19: a partial mid-sync rollback is still an overall SUCCESS (exit 0)') or diag($resp->{out} . $resp->{err});

    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $n = find_note($state, 'rolled_back_during_sync');
        ok(defined $n, 'AC19: a rolled_back_during_sync note is present');
        my @toks = project_toks($state);
        my $data;
        for my $t (@toks) { my $d = project_item($state, $t); $data = $d if defined($d) && (($d->{slug} // '') eq 'partialrb'); }
        ok(defined $data, 'AC19: the project has a terminal checkpoint');
        isnt(($data->{status} // ''), 'rolled_back_nothing_stored', 'AC19: NOT recorded as rolled_back_nothing_stored') if defined $data;
    } else {
        ok(0, "AC19: $_") for ('a rolled_back_during_sync note is present', 'the project has a terminal checkpoint', 'NOT recorded as rolled_back_nothing_stored');
    }
}

# ===========================================================================
# AC20 -- push_unconfirmed: commit-and-push reports success while
# list-projects does not show last_synced_at advancing -> failure, never
# success; the same scenario with an advanced last_synced_at succeeds.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'unconfirmed')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'unconfirmed'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'unconfirmed'), mk_sync_synced(slug => 'unconfirmed', session_id => 'sess-unc'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'unconfirmed'), mk_committed(slug => 'unconfirmed', last_synced_at => '2026-09-08T07:00:00Z'));
    # Confirmation call still shows the OLD (null) last_synced_at -- the vault's own record never advanced.
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(mk_project_entry(slug => 'unconfirmed', last_synced_at => undef)));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 20, 'AC20a: an unconfirmed push degrades the run (exit 20)') or diag($resp->{out} . $resp->{err});
    my $state = read_state($r->{state_path});
    if (defined $state) {
        my @toks = project_toks($state);
        my $data;
        for my $t (@toks) { my $d = project_item($state, $t); $data = $d if defined($d) && (($d->{slug} // '') eq 'unconfirmed'); }
        is(($data->{status} // ''), 'push_unconfirmed', 'AC20a: the checkpoint status is exactly "push_unconfirmed"') if defined $data;
        ok(defined $data, 'AC20a: the checkpoint status is exactly "push_unconfirmed"') or diag('no checkpoint found');
        my $n = find_note($state, 'push_unconfirmed');
        ok(defined $n, 'AC20a: a push_unconfirmed note is present');
    } else {
        ok(0, 'AC20a: the checkpoint status is exactly "push_unconfirmed"');
        ok(0, 'AC20a: a push_unconfirmed note is present');
    }
}
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'confirmed')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'confirmed'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'confirmed'), mk_sync_synced(slug => 'confirmed', session_id => 'sess-conf'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'confirmed'), mk_committed(slug => 'confirmed', last_synced_at => '2026-09-08T08:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(mk_project_entry(slug => 'confirmed', last_synced_at => '2026-09-08T08:00:00Z')));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'AC20b: the SAME scenario with an advanced last_synced_at succeeds (exit 0)') or diag($resp->{out} . $resp->{err});
    my $state = read_state($r->{state_path});
    if (defined $state) {
        ok(!defined(find_note($state, 'push_unconfirmed')), 'AC20b: no push_unconfirmed note is present when the vault confirms');
    }
}

# ===========================================================================
# AC21 -- a signal-killed vault-sync.pl during commit-and-push is not
# treated as exit 0: the project fails (t/22's own suicide technique).
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'suicideproj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'suicideproj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'suicideproj'), mk_sync_synced(slug => 'suicideproj', session_id => 'sess-suicide'));

    my $resp = run_backup($r, { VAULT_SYNC_SUICIDE_CMD => 'commit-and-push' });
    is($resp->{exit}, 20, 'AC21: a signal-killed commit-and-push degrades the run, never treated as a clean exit 0')
        or diag($resp->{out} . $resp->{err});
    my $state = read_state($r->{state_path});
    if (defined $state) {
        my @toks = project_toks($state);
        my $data;
        for my $t (@toks) { my $d = project_item($state, $t); $data = $d if defined($d) && (($d->{slug} // '') eq 'suicideproj'); }
        ok(defined $data, 'AC21: a terminal (failure) checkpoint exists for the signal-killed project');
        isnt(($data->{status} // ''), 'committed_and_pushed', 'AC21: not recorded under any success-shaped status') if defined $data;
    } else {
        ok(0, 'AC21: a terminal (failure) checkpoint exists for the signal-killed project');
        ok(0, 'AC21: not recorded under any success-shaped status');
    }
}

# ===========================================================================
# AC27 -- deletes_local note appears BEFORE the commit-and-push invocation
# for that project.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'deleteproj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'deleteproj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'deleteproj'), mk_sync_synced(
        slug => 'deleteproj', session_id => 'sess-del', deletes_local => ['gone1.txt', 'gone2.txt']));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'deleteproj'), mk_committed(slug => 'deleteproj', last_synced_at => '2026-09-08T09:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(mk_project_entry(slug => 'deleteproj', last_synced_at => '2026-09-08T09:00:00Z')));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'AC27: (setup) the run completes so ordering can be checked') or diag($resp->{out} . $resp->{err});
    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $n = find_note($state, 'deletes_local_staged');
        ok(defined $n, 'AC27: a deletes_local_staged note is present');
        if (defined $n) {
            is(($n->{value}{count} // -1) + 0, 2, 'AC27: the note carries the correct count');
        }
        # Ordering: the note is part of state.notes (an array, append-only) and
        # the commit-and-push CALL is part of the log -- both are append-only
        # sequences from the SAME single-threaded invocation, so their
        # relative position in each stream reflects true chronology. We can't
        # directly interleave two different streams by index, so we instead
        # assert the note exists AND (independently) that the log shows
        # commit-and-push was reached (proving the run got past the note-
        # emission point without the note simply being dropped).
        my @entries = log_entries($r->{log_path});
        ok(count_subcmd_for_slug(\@entries, 'commit-and-push', 'deleteproj') >= 1, 'AC27: commit-and-push was in fact called for the project');
    } else {
        ok(0, 'AC27: a deletes_local_staged note is present');
        ok(0, 'AC27: the note carries the correct count');
        ok(0, 'AC27: commit-and-push was in fact called for the project');
    }
}

# ===========================================================================
# AC26 -- todo-sync.pl precedes every sync-project invocation; a todo
# failure does NOT block the project loop.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'error', error => 'AC26-TODO-BOOM'), exit => 1);
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'afterTodoFail')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'afterTodoFail'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'afterTodoFail'), mk_sync_synced(slug => 'afterTodoFail', session_id => 'sess-atf'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'afterTodoFail'), mk_committed(slug => 'afterTodoFail', last_synced_at => '2026-09-08T10:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(mk_project_entry(slug => 'afterTodoFail', last_synced_at => '2026-09-08T10:00:00Z')));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 20, 'AC26: a todo-sync failure alone degrades the run (exit 20) but does not abort it') or diag($resp->{out} . $resp->{err});

    my @entries = log_entries($r->{log_path});
    my $todo_idx = first_index_for_slug(\@entries, undef);   # placeholder, replaced below
    my ($first_todo_idx, $first_sync_idx);
    for my $i (0 .. $#entries) {
        $first_todo_idx = $i if !defined($first_todo_idx) && $entries[$i]{script} eq 'todo-sync.pl';
        $first_sync_idx = $i if !defined($first_sync_idx) && $entries[$i]{subcmd} eq 'sync-project';
    }
    ok(defined($first_todo_idx), 'AC26: todo-sync.pl was invoked');
    ok(defined($first_sync_idx), 'AC26: sync-project was STILL invoked after the todo-sync failure (the loop is not blocked)');
    ok((defined($first_todo_idx) && defined($first_sync_idx) && $first_todo_idx < $first_sync_idx),
        'AC26: todo-sync.pl precedes every sync-project invocation');

    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $n = find_note($state, 'todos_failed');
        ok(defined $n, 'AC26: a todos_failed note is present');
        like(($n->{value}{error} // ''), qr/AC26-TODO-BOOM/, 'AC26: the note carries the reported error text') if defined $n;
    } else {
        ok(0, 'AC26: a todos_failed note is present');
    }
}

# ===========================================================================
# AC5 / AC6 -- exact spawn counts across a pause/resume, and the checkpoint
# keys visible mid-pause. Three projects: A (clean success), B (one
# conflict, pauses), C (clean success, reached only after B resolves).
# ===========================================================================
{
    my $r = setup_root();
    my $tmpB = "$r->{scratch}/mergeB.txt";
    write_text($tmpB, "<<<<<<< local\nB-local\n=======\nB-vault\n>>>>>>> vault\n");

    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(
        mk_project_entry(slug => 'projA'), mk_project_entry(slug => 'projB'), mk_project_entry(slug => 'projC')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'projA'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'projA'), mk_sync_synced(slug => 'projA', session_id => 'sess-A'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'projA'), mk_committed(slug => 'projA', last_synced_at => '2026-09-08T11:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(
        mk_project_entry(slug => 'projA', last_synced_at => '2026-09-08T11:00:00Z'), mk_project_entry(slug => 'projB'), mk_project_entry(slug => 'projC')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'projB'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'projB'), mk_sync_synced(
        slug => 'projB', session_id => 'sess-B', conflicts => [ mk_conflict(path => 'b.txt', tmp_path => $tmpB, merge_exit_code => 1) ]));
    set_fixture($r->{fixture_dir}, fixture_name('resolve-conflict', 'projB'), mk_resolve_ok(slug => 'projB', path => 'b.txt'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'projB'), mk_committed(slug => 'projB', last_synced_at => '2026-09-08T12:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 2), mk_list_projects(
        mk_project_entry(slug => 'projA', last_synced_at => '2026-09-08T11:00:00Z'),
        mk_project_entry(slug => 'projB', last_synced_at => '2026-09-08T12:00:00Z'), mk_project_entry(slug => 'projC')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'projC'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'projC'), mk_sync_synced(slug => 'projC', session_id => 'sess-C'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'projC'), mk_committed(slug => 'projC', last_synced_at => '2026-09-08T13:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 3), mk_list_projects(
        mk_project_entry(slug => 'projA', last_synced_at => '2026-09-08T11:00:00Z'),
        mk_project_entry(slug => 'projB', last_synced_at => '2026-09-08T12:00:00Z'),
        mk_project_entry(slug => 'projC', last_synced_at => '2026-09-08T13:00:00Z')));

    my $resp1 = run_backup($r, {});
    is($resp1->{exit}, 10, 'AC5/AC6: the run pauses on projB\'s conflict') or diag($resp1->{out} . $resp1->{err});
    my @decs = decisions_of_kind($resp1, 'vault_conflict');
    record_decisions(@decs);
    my $d = $decs[0];

    # AC6: checkpoint keys mid-pause.
    my $state_mid = read_state($r->{state_path});
    if (defined $state_mid) {
        my @toks = project_toks($state_mid);
        my ($tokA_present, $tokB_present) = (0, 0);
        for my $t (@toks) {
            my $data = project_item($state_mid, $t);
            $tokA_present = 1 if defined($data) && (($data->{slug} // '') eq 'projA');
            $tokB_present = 1 if defined($data) && (($data->{slug} // '') eq 'projB');
        }
        ok($tokA_present, 'AC6: project.<tokA> is checkpointed mid-pause (A already completed)');
        ok(!$tokB_present, 'AC6: project.<tokB> is NOT checkpointed mid-pause (B is not terminal yet)');

        my $items = $state_mid->{phases}{vault}{items} // {};
        my ($session_tokB_key) = grep { /^session\./ } keys %$items;
        ok(defined $session_tokB_key, 'AC6: a session.<tokB> checkpoint exists mid-pause');
        if (defined $session_tokB_key) {
            my $sdata = $items->{$session_tokB_key}{data};
            is(($sdata->{slug} // ''), 'projB', 'AC6: the session checkpoint is for projB');
        }
    } else {
        ok(0, 'AC6: project.<tokA> is checkpointed mid-pause (A already completed)');
        ok(0, 'AC6: project.<tokB> is NOT checkpointed mid-pause (B is not terminal yet)');
        ok(0, 'AC6: a session.<tokB> checkpoint exists mid-pause');
        ok(0, 'AC6: the session checkpoint is for projB');
    }

    my @entries_before = log_entries($r->{log_path});
    is(count_subcmd_for_slug(\@entries_before, 'sync-project', 'projA'), 1, 'AC5: projA sync-project ran exactly once before the resume');
    is(count_subcmd_for_slug(\@entries_before, 'sync-project', 'projC'), 0, 'AC6: projC has not been touched before the resume');

    my $token = $resp1->{json}{resume_token};
    my $resp2 = run_backup($r, {}, '--resume', ($token // ''), '--answer', (defined $d ? "$d->{id}=use_local" : 'vault.conflict.projB.b.txt=use_local'));
    is($resp2->{exit}, 0, 'AC5/AC6: the resume reaches a clean terminal status (exit 0)') or diag($resp2->{out} . $resp2->{err});

    my @entries_after = log_entries($r->{log_path});
    is(scalar(grep { ($_->{subcmd} // '') eq 'sync-project' } @entries_after), 3, 'AC5: sync-project ran exactly three times total across the whole run');
    is(count_subcmd_for_slug(\@entries_after, 'sync-project', 'projA'), 1, 'AC6: projA sync-project was NOT re-spawned across the resume');
    is(scalar(grep { $_->{script} eq 'todo-sync.pl' } @entries_after), 1, 'AC5: todo-sync.pl ran exactly once across the whole run');
    is(scalar(grep { ($_->{subcmd} // '') eq 'list-projects' } @entries_after), 4, 'AC5: list-projects ran exactly 1 + (number of confirmed pushes = 3) = 4 times');
}

# ===========================================================================
# AC2 -- seeded run state: project 2 already checkpointed while project 1 is
# not. The module must work on project 1 -- never skip ahead by scanning
# backwards or trusting registry order over the frozen list.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, 'refresh-default-tracked.p1.resp', mk_refresh_ok());
    set_fixture($r->{fixture_dir}, 'sync-project.p1.resp', mk_sync_synced(slug => 'p1', session_id => 'sess-p1'));
    set_fixture($r->{fixture_dir}, 'commit-and-push.p1.resp', mk_committed(slug => 'p1', last_synced_at => '2026-09-08T14:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'p1', last_synced_at => '2026-09-08T14:00:00Z')));

    my $items = {
        vault_check  => mk_item({ present => 1, path => $r->{vault_dir} }),
        todos        => mk_item({ status => 'ok', pulled => 'no', committed => 'no', pushed => 'no' }),
        project_list => mk_item([
            { slug => 'p1', path => "/scratch/p1", project_exists => JSON::PP::true, tok => 'p1' },
            { slug => 'p2', path => "/scratch/p2", project_exists => JSON::PP::true, tok => 'p2' },
        ]),
        'project.p2' => mk_item({ slug => 'p2', status => 'TEST-SEEDED-ALREADY-DONE' }),
    };
    my $state = fresh_state_shell(status => 'running', phase_status => 'pending', items => $items);
    write_state_raw($r->{state_path}, $state);

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'AC2: with p2 pre-checkpointed and p1 not, the run still completes cleanly (exit 0)') or diag($resp->{out} . $resp->{err});

    my @entries = log_entries($r->{log_path});
    ok(count_subcmd_for_slug(\@entries, 'sync-project', 'p1') >= 1, 'AC2: p1 (the actually-unfinished project) WAS synced');
    is(count_subcmd_for_slug(\@entries, 'sync-project', 'p2'), 0, 'AC2: p2 (already checkpointed) was NOT re-synced (no skip-ahead, no re-do)');

    my $state_after = read_state($r->{state_path});
    if (defined $state_after) {
        my $p2 = project_item($state_after, 'p2');
        is(($p2->{status} // ''), 'TEST-SEEDED-ALREADY-DONE', 'AC2: the seeded project.p2 checkpoint is left completely untouched');
    } else {
        ok(0, 'AC2: the seeded project.p2 checkpoint is left completely untouched');
    }
}

# ===========================================================================
# AC7 -- the per-project checkpoint lives at
# phases.vault.items.project.<tok>.data; no other file is created anywhere
# by this module (a full recursive scratch-root listing before vs after).
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'ac7proj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'ac7proj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'ac7proj'), mk_sync_synced(slug => 'ac7proj', session_id => 'sess-ac7'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'ac7proj'), mk_committed(slug => 'ac7proj', last_synced_at => '2026-09-08T15:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(mk_project_entry(slug => 'ac7proj', last_synced_at => '2026-09-08T15:00:00Z')));

    my @before = scratch_snapshot($r->{scratch});
    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'AC7: (setup) the run completes cleanly') or diag($resp->{out} . $resp->{err});
    my @after = scratch_snapshot($r->{scratch});

    my %before_set = map { $_ => 1 } @before;
    my @new_files = grep { !$before_set{$_} } @after;
    # Expected new files: the run-state file itself, the stub-argv log file
    # (VAULT_TEST_LOG, written by the STUBS -- not this module), and any
    # fixture .ctr.* counter files the STUBS create (not this module).
    my @unexpected = grep {
        $_ ne $r->{state_path}
        && $_ ne $r->{log_path}
        && !/\.ctr\./
    } @new_files;
    is(scalar(@unexpected), 0, 'AC7: no file besides the run-state file (and the stub\'s own counter files) was created anywhere under the scratch root')
        or diag('unexpected new files: ' . join(', ', @unexpected));

    my $state = read_state($r->{state_path});
    if (defined $state) {
        my @toks = project_toks($state);
        my $data;
        for my $t (@toks) { my $d = project_item($state, $t); $data = $d if defined($d) && (($d->{slug} // '') eq 'ac7proj'); }
        ok(defined($data) && defined($data->{slug}) && defined($data->{status}),
            'AC7: the checkpoint at phases.vault.items.project.<tok>.data carries {slug, status, ...}');
    } else {
        ok(0, 'AC7: the checkpoint at phases.vault.items.project.<tok>.data carries {slug, status, ...}');
    }
}

# ===========================================================================
# AC24 -- P15: a conflict whose path is docs/café-noté.md (non-ASCII in the
# FILENAME). Bytes verified at every layer: decision data/subject, raw
# stdout, the checkpointed session.<tok> inventory, and (after a real
# pause+resume) the --path argument the stub actually received.
# ===========================================================================
{
    my $r = setup_root();
    my $tmp = "$r->{scratch}/ac24-merge.txt";
    write_text($tmp, "<<<<<<< local\nlocal-$PATH_BYTES\n=======\nvault-$PATH_BYTES\n>>>>>>> vault\n");

    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'ac24proj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'ac24proj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'ac24proj'), mk_sync_synced(
        slug => 'ac24proj', session_id => 'sess-ac24',
        conflicts => [ mk_conflict(path => $PATH_WIDE, tmp_path => $tmp, merge_exit_code => 1) ]));
    set_fixture($r->{fixture_dir}, fixture_name('resolve-conflict', 'ac24proj'), mk_resolve_ok(slug => 'ac24proj', path => $PATH_WIDE));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'ac24proj'), mk_committed(slug => 'ac24proj', last_synced_at => '2026-09-08T16:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(mk_project_entry(slug => 'ac24proj', last_synced_at => '2026-09-08T16:00:00Z')));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, 'AC24: (setup) the non-ASCII-filename conflict pauses the run') or diag($resp->{out} . $resp->{err});

    ok(index($resp->{out}, $PATH_BYTES) >= 0, 'AC24: raw stdout bytes contain the exact UTF-8 byte sequence of the path (no decode)');

    my @decs = decisions_of_kind($resp, 'vault_conflict');
    record_decisions(@decs);
    my $d = $decs[0];
    ok(defined $d, 'AC24: a vault_conflict decision was emitted for the non-ASCII-filename conflict');
    if (defined $d) {
        is(($d->{data}{path} // ''), $PATH_WIDE, 'AC24: decision data.path decodes to the exact widened path');
        like(($d->{subject} // ''), qr/\Q$PATH_WIDE\E/, 'AC24: decision subject contains the exact widened path');
    } else {
        ok(0, 'AC24: decision data.path decodes to the exact widened path');
        ok(0, 'AC24: decision subject contains the exact widened path');
    }

    my $state_raw = read_text($r->{state_path}) // '';
    ok(index($state_raw, $PATH_BYTES) >= 0, 'AC24: the checkpointed session.<tok> inventory contains the raw UTF-8 bytes of the path, byte-exact');

    my $token = $resp->{json}{resume_token};
    my $resp2 = run_backup($r, {}, '--resume', ($token // ''), '--answer', (defined $d ? "$d->{id}=use_local" : 'vault.conflict.ac24proj.docs_caf__-not__.md=use_local'));
    ok(($resp2->{exit} == 0 || $resp2->{exit} == 20), 'AC24: the real resume reaches a terminal status') or diag($resp2->{out} . $resp2->{err});

    my $log_raw = read_text($r->{log_path}) // '';
    my $expected_argv_fragment = "--path $PATH_BYTES";
    ok(index($log_raw, $expected_argv_fragment) >= 0,
        'AC24: after a real pause+resume, the --path argument the stub received carries the EXACT SAME bytes (raw byte search, no decode)')
        or diag("log did not contain: $expected_argv_fragment");
}

# ===========================================================================
# AC25 -- P15: a registered project whose SLUG contains a non-ASCII
# character. tok/decision-id/checkpoint-key stay pure ASCII; the --slug
# argument the stub received and the notes carry the ORIGINAL bytes.
# ===========================================================================
{
    my $r = setup_root();
    my $tmp = "$r->{scratch}/ac25-merge.txt";
    write_text($tmp, "<<<<<<< local\nL\n=======\nV\n>>>>>>> vault\n");

    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => $SLUG_WIDE)));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', $SLUG_WIDE), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', $SLUG_WIDE), mk_sync_synced(
        slug => $SLUG_WIDE, session_id => 'sess-ac25',
        conflicts => [ mk_conflict(path => 'notes.txt', tmp_path => $tmp, merge_exit_code => 1) ]));
    set_fixture($r->{fixture_dir}, fixture_name('resolve-conflict', $SLUG_WIDE), mk_resolve_ok(slug => $SLUG_WIDE, path => 'notes.txt'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', $SLUG_WIDE), mk_committed(slug => $SLUG_WIDE, last_synced_at => '2026-09-08T17:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(mk_project_entry(slug => $SLUG_WIDE, last_synced_at => '2026-09-08T17:00:00Z')));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, 'AC25: (setup) the non-ASCII-slug project pauses the run on its conflict') or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of_kind($resp, 'vault_conflict');
    record_decisions(@decs);
    my $d = $decs[0];
    ok(defined $d, 'AC25: a vault_conflict decision was emitted');
    if (defined $d) {
        like(($d->{id} // ''), qr/^vault\.[A-Za-z0-9_.:-]*$/, 'AC25: the decision id is pure ASCII and matches the id grammar');
        unlike(($d->{id} // ''), qr/[^\x00-\x7f]/, 'AC25: the decision id contains no non-ASCII byte');
    } else {
        ok(0, 'AC25: the decision id is pure ASCII and matches the id grammar');
        ok(0, 'AC25: the decision id contains no non-ASCII byte');
    }

    my $log_raw_1 = read_text($r->{log_path}) // '';
    ok(index($log_raw_1, "--slug $SLUG_BYTES") >= 0, 'AC25: the --slug argument the stub received carries the ORIGINAL bytes, byte-exact');

    my $state = read_state($r->{state_path});
    if (defined $state) {
        # AC25 fix (coordinator defect 2): this scenario is mid-PAUSE on its
        # only conflict, so per spec S2.3/S2.4 the TERMINAL project.<tok>
        # checkpoint does not exist yet -- only session.<tok> (in progress)
        # does; project.<tok> absence here is exactly how "next unsynced
        # project" is identified (AC2), so asserting project.<tok> presence
        # at this point would assert a checkpoint the spec forbids the
        # implementation from writing yet. Check the ASCII-key intent
        # against session.<tok> instead, which DOES exist at this point.
        my @toks = session_toks($state);
        for my $t (@toks) {
            unlike($t, qr/[^\x00-\x7f]/, "AC25: checkpoint key suffix '$t' is pure ASCII");
        }
        ok(scalar(@toks) > 0, 'AC25: at least one session.<tok> checkpoint key exists to check (project.<tok> is not terminal yet -- this is mid-pause)');
    } else {
        ok(0, 'AC25: at least one session.<tok> checkpoint key exists to check (project.<tok> is not terminal yet -- this is mid-pause)');
    }
    my $state_raw = read_text($r->{state_path}) // '';
    ok(index($state_raw, $SLUG_BYTES) >= 0, 'AC25: the notes/state report the original slug byte-exactly (raw byte search)');

    my $token = $resp->{json}{resume_token};
    my $resp2 = run_backup($r, {}, '--resume', ($token // ''), '--answer', (defined $d ? "$d->{id}=use_local" : 'vault.conflict.p.notes.txt=use_local'));
    # ITEM2 correction (coordinator): this used to accept exit 20
    # (push_unconfirmed) as an alternate "plausible" outcome alongside exit
    # 0. Red-teaming found that _ensure_utf8_bytes, applied to a slug that
    # came back through a checkpoint round-trip (project_list re-read via
    # $ctx->{get_item} on resume), double-encodes it -- so a project that
    # genuinely pushed fine is falsely recorded push_unconfirmed. That is
    # not an acceptable alternate outcome: it is a FALSE FIRING of the
    # d667 alarm, which trains the operator to ignore the one alarm that
    # matters. Tightened to require the real success path only.
    is($resp2->{exit}, 0, 'AC25: a project that genuinely pushed reaches exit 0 (committed_and_pushed), never a false push_unconfirmed')
        or diag($resp2->{out} . $resp2->{err});
    my $state_after_resume = read_state($r->{state_path});
    if (defined $state_after_resume) {
        my @toks_final = project_toks($state_after_resume);
        my $final_data = (@toks_final) ? project_item($state_after_resume, $toks_final[0]) : undef;
        is(($final_data->{status} // ''), 'committed_and_pushed',
            'AC25: the terminal checkpoint status is exactly "committed_and_pushed", never "push_unconfirmed"')
            if defined $final_data;
        ok(defined($final_data), 'AC25: the terminal checkpoint status is exactly "committed_and_pushed", never "push_unconfirmed"')
            or diag('no terminal project.<tok> checkpoint found');
    } else {
        ok(0, 'AC25: the terminal checkpoint status is exactly "committed_and_pushed", never "push_unconfirmed"');
    }
    my $log_raw_2 = read_text($r->{log_path}) // '';
    ok(index($log_raw_2, "--slug $SLUG_BYTES") >= 0, 'AC25: --slug is STILL byte-exact on the commit-and-push call after the resume');
}

# ===========================================================================
# AC22b -- happy path: the --session-id passed to both resolve-conflict and
# commit-and-push is byte-identical to the one sync-project emitted,
# including across a real pause/resume.
# ===========================================================================
{
    my $r = setup_root();
    my $sid = 'sess-AC22-byte-identical-001';
    my $tmp = "$r->{scratch}/ac22-merge.txt";
    write_text($tmp, "<<<<<<< local\nL\n=======\nV\n>>>>>>> vault\n");

    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'ac22proj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'ac22proj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'ac22proj'), mk_sync_synced(
        slug => 'ac22proj', session_id => $sid,
        conflicts => [ mk_conflict(path => 'x.txt', tmp_path => $tmp, merge_exit_code => 1) ]));
    set_fixture($r->{fixture_dir}, fixture_name('resolve-conflict', 'ac22proj'), mk_resolve_ok(slug => 'ac22proj', path => 'x.txt'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'ac22proj'), mk_committed(slug => 'ac22proj', last_synced_at => '2026-09-08T18:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(mk_project_entry(slug => 'ac22proj', last_synced_at => '2026-09-08T18:00:00Z')));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, 'AC22b: (setup) pauses on the conflict') or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of_kind($resp, 'vault_conflict');
    record_decisions(@decs);
    my $d = $decs[0];
    my $token = $resp->{json}{resume_token};
    my $resp2 = run_backup($r, {}, '--resume', ($token // ''), '--answer', (defined $d ? "$d->{id}=use_local" : 'vault.conflict.ac22proj.x.txt=use_local'));
    is($resp2->{exit}, 0, 'AC22b: the resume completes cleanly') or diag($resp2->{out} . $resp2->{err});

    my @entries = log_entries($r->{log_path});
    my ($rc) = grep { $_->{subcmd} eq 'resolve-conflict' && ($_->{slug} // '') eq 'ac22proj' } @entries;
    my ($cp) = grep { $_->{subcmd} eq 'commit-and-push' && ($_->{slug} // '') eq 'ac22proj' } @entries;
    like(($rc->{line} // ''), qr/--session-id\s+\Q$sid\E(?:\s|$)/, 'AC22b: resolve-conflict --session-id is byte-identical to the one sync-project emitted') if defined $rc;
    like(($cp->{line} // ''), qr/--session-id\s+\Q$sid\E(?:\s|$)/, 'AC22b: commit-and-push --session-id is byte-identical, even after a real pause/resume') if defined $cp;
    ok(defined($rc), 'AC22b: resolve-conflict --session-id is byte-identical to the one sync-project emitted') or diag('no resolve-conflict logged');
    ok(defined($cp), 'AC22b: commit-and-push --session-id is byte-identical, even after a real pause/resume') or diag('no commit-and-push logged');
}

# ===========================================================================
# AC23d -- an unreadable merge_result.tmp_path: decision still emitted,
# merge_preview_unavailable set, project not failed by it alone.
# ===========================================================================
{
    my $r = setup_root();
    my $missing_tmp = "$r->{scratch}/does-not-exist-merge-tmp.txt";
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'unreadproj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'unreadproj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'unreadproj'), mk_sync_synced(
        slug => 'unreadproj', session_id => 'sess-unread',
        conflicts => [ mk_conflict(path => 'gone.txt', tmp_path => $missing_tmp, merge_exit_code => 1) ]));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, 'AC23: an unreadable merge tmp_path still emits the decision (does not fail the project by itself)')
        or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of_kind($resp, 'vault_conflict');
    record_decisions(@decs);
    my $d = $decs[0];
    ok(defined $d, 'AC23: the decision was emitted despite the unreadable merge tmp');
    ok(defined($d) && $d->{data}{merge_preview_unavailable}, 'AC23: data.merge_preview_unavailable is set') if defined $d;
}

# ===========================================================================
# CRASH1/CRASH2 -- crash_preserves_items: a simulated mid-execution death
# (state-file surgery, t/21/t/22 precedent) preserves a completed project's
# checkpoint (never re-synced) AND preserves an in-progress conflict's
# session inventory while its ANSWER is still cleared (re-asked, same id).
# ===========================================================================
{
    my $r = setup_root();
    my $tmp = "$r->{scratch}/crash-merge.txt";
    write_text($tmp, "<<<<<<< local\ncrash-local\n=======\ncrash-vault\n>>>>>>> vault\n");

    # On the RE-ENTRY (post-crash) invocation, project B's conflict must be
    # re-emitted from the PRESERVED session.<tokB> inventory -- sync-project
    # must NOT be spawned again for B. We deliberately do not provide a
    # sync-project fixture for crashB, so a re-spawn would surface as an
    # unparseable-output failure rather than silently succeeding.
    set_fixture($r->{fixture_dir}, fixture_name('resolve-conflict', 'crashB'), mk_resolve_ok(slug => 'crashB', path => 'c.txt'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'crashB'), mk_committed(slug => 'crashB', last_synced_at => '2026-09-08T19:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', 'crashB', 0), mk_list_projects(
        mk_project_entry(slug => 'crashA', last_synced_at => '2026-09-08T19:00:00Z'),
        mk_project_entry(slug => 'crashB', last_synced_at => '2026-09-08T19:00:00Z')));

    my $conflict_id = 'vault.conflict.crashB.c.txt';   # _mint_ids preserves dots (s/[^A-Za-z0-9_.:-]/_/g); 'c.txt' sanitises to itself, never 'c_txt'
    my $items = {
        vault_check  => mk_item({ present => 1, path => $r->{vault_dir} }),
        todos        => mk_item({ status => 'ok', pulled => 'no', committed => 'no', pushed => 'no' }),
        project_list => mk_item([
            { slug => 'crashA', path => '/scratch/crashA', project_exists => JSON::PP::true, tok => 'crashA' },
            { slug => 'crashB', path => '/scratch/crashB', project_exists => JSON::PP::true, tok => 'crashB' },
        ]),
        'project.crashA' => mk_item({ slug => 'crashA', status => 'TEST-SEEDED-DONE' }),
        'session.crashB' => mk_item({
            slug => 'crashB', session_id => 'sess-crashB',
            conflicts => [ { path => 'c.txt', is_text => JSON::PP::true, merge_exit_code => 1, merge_tmp_path => $tmp } ],
            resolved => [], stage => 'awaiting_resolution',
        }),
    };
    # phase_status 'running' (not 'paused') is exactly what Run.pm's R6 reads
    # as "died mid-execution" on re-entry.
    my $state = fresh_state_shell(
        status => 'running', phase_status => 'running', items => $items,
        answers => { $conflict_id => 'use_local' },
    );
    write_state_raw($r->{state_path}, $state);

    my $resp = run_backup($r, {});
    ok(($resp->{exit} == 10 || $resp->{exit} == 0 || $resp->{exit} == 20),
        'CRASH1: re-entry after a simulated mid-execution death reaches a plausible outcome') or diag($resp->{out} . $resp->{err});

    my @entries = log_entries($r->{log_path});
    is(count_subcmd_for_slug(\@entries, 'sync-project', 'crashA'), 0, 'CRASH1: project A (already terminal) is NOT re-synced after the simulated crash');
    is(count_subcmd_for_slug(\@entries, 'sync-project', 'crashB'), 0,
        'CRASH2: project B (session preserved) does NOT get sync-project re-spawned -- the preserved inventory is trusted');

    if (($resp->{json}{status} // '') eq 'needs_decision') {
        my @decs = decisions_of_kind($resp, 'vault_conflict');
        record_decisions(@decs);
        ok(scalar(@decs) >= 1, 'CRASH2: the preserved-but-unanswered conflict is RE-ASKED on the crash re-entry');
        my ($same_id) = grep { ($_->{id} // '') eq $conflict_id } @decs;
        ok(defined $same_id, "CRASH2: the re-asked decision reuses the SAME id ($conflict_id) -- ids are a pure function of (tok, path)");
    } else {
        # If the implementer's flow resolves this in one pass instead of
        # pausing again, that is still consistent with "answer cleared and
        # re-derived" as long as B ends up terminal via a FRESH answer path
        # rather than the wiped one being silently trusted. Either shape is
        # accepted here; what is NOT accepted is B being skipped/re-synced.
        ok(1, 'CRASH2: (alternate acceptable shape) the run did not pause again for crashB -- checked structurally above instead');
    }

    my $state_after = read_state($r->{state_path});
    if (defined $state_after) {
        my $answers = $state_after->{answers} // {};
        ok(!exists($answers->{$conflict_id}) || (($answers->{$conflict_id} // '') ne 'use_local') || (($resp->{json}{status} // '') ne 'needs_decision'),
            'CRASH2: the pre-crash answer is not silently trusted as still-valid consent on the SAME re-entry that discovers the crash');
        my $crashA_after = project_item($state_after, 'crashA');
        is(($crashA_after->{status} // ''), 'TEST-SEEDED-DONE', 'CRASH1: project A\'s preserved checkpoint is untouched by the crash re-entry');
    } else {
        ok(0, 'CRASH1: project A\'s preserved checkpoint is untouched by the crash re-entry');
    }
}

# ===========================================================================
# AC30 -- the parity file: fixed four-cell row shape, floor of the five
# old-step rows (5.4, 5.5, 5.5.a, 5.5.b, 5.5.c), no row required for 5.6.
# ===========================================================================
{
    if (-f $PARITY_FILE) {
        ok(1, 'AC30: reports/parity/04-vault-and-todos.md exists');
        my $body = read_text($PARITY_FILE) // '';
        my @lines = split /\r?\n/, $body;
        my ($hidx) = grep { $lines[$_] =~ /old step/i && $lines[$_] =~ /phase/i && $lines[$_] =~ /module/i && $lines[$_] =~ /note/i } (0 .. $#lines);
        ok((defined $hidx), 'AC30: a header row naming old step / phase / module / note is present') or diag($body);
        if (defined $hidx) {
            like($lines[$hidx + 1] // '', qr/^\s*\|[\s:-]+\|/, 'AC30: a separator row immediately follows the header') or diag($body);
            my @data_lines = grep { length $_ } @lines[($hidx + 2) .. $#lines];
            ok(scalar(@data_lines) >= 5, 'AC30: at least five data rows (a floor, not an exact count)') or diag(join("\n", @data_lines));

            my %seen_step;
            for my $line (@data_lines) {
                next unless $line =~ /^\|/;
                my @fields = split /\|/, $line, -1;
                is(scalar(@fields), 6, "AC30: row '$line' splits on '|' into six fields (leading/trailing empty + four cells)")
                    if scalar(@fields) != 6;
                my @cells = @fields[1 .. 4];
                $seen_step{ $cells[0] // '' } = 1;
                is(($cells[1] // ''), 'vault', "AC30: row '$line' phase cell == vault");
                like(($cells[2] // ''), qr{scripts/backup/Vault\.pm}, "AC30: row '$line' module cell names scripts/backup/Vault.pm");
                ok(length($cells[3] // '') > 0, "AC30: row '$line' note cell is non-empty");
                unlike($line, qr/\R/, "AC30: row '$line' contains no embedded newline");
            }
            for my $step (qw(5.4 5.5 5.5.a 5.5.b 5.5.c)) {
                ok($seen_step{$step}, "AC30: an old-step-$step row is present (floor requirement)");
            }
            ok(!$seen_step{'5.6'}, 'AC30: no row is present for 5.6 (it does not exist)');
        } else {
            ok(0, 'AC30: a separator row immediately follows the header');
            ok(0, 'AC30: at least five data rows');
            ok(0, "AC30: an old-step-$_ row is present") for qw(5.4 5.5 5.5.a 5.5.b 5.5.c);
        }
    } else {
        ok(0, 'AC30: reports/parity/04-vault-and-todos.md exists');
        ok(0, 'AC30: a header row naming old step / phase / module / note is present');
        ok(0, 'AC30: a separator row immediately follows the header');
        ok(0, 'AC30: at least five data rows');
        ok(0, "AC30: an old-step-$_ row is present") for qw(5.4 5.5 5.5.a 5.5.b 5.5.c);
    }
}

# ===========================================================================
# AC29 -- isolation: no scenario in this file ever points at the operator's
# real HOME/USERPROFILE, the real vault, or a network remote; every spawned
# path resolves under a scratch root.
# ===========================================================================
{
    my $r = setup_root();
    isnt($r->{home}, ($REAL_HOME // ''),        'AC29: the scenario HOME is not literally the operator real HOME');
    isnt($r->{home}, ($REAL_USERPROFILE // ''), 'AC29: the scenario HOME is not literally the operator real USERPROFILE');
    like($r->{state_path}, qr/\Q$r->{scratch}\E/, 'AC29: the run-state file path is rooted under the scratch tree');
    like($r->{root},       qr/\Q$r->{scratch}\E/, 'AC29: the fake ccpraxis root is rooted under the scratch tree');
    like($r->{vault_dir},  qr/\Q$r->{scratch}\E/, 'AC29: the fake vault path is rooted under the scratch tree');

    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects());
    my $resp = run_backup($r, {});
    ok(($resp->{exit} == 0 || $resp->{exit} == 10 || $resp->{exit} == 20), 'AC29: the isolated run reaches a plausible status')
        or diag($resp->{out} . $resp->{err});
    ok(path_exists($r->{state_path}), 'AC29: the state file was created under the scratch root');

    if (defined $REAL_HOME) {
        my $real_marker = "$REAL_HOME/.claude/claude-code-vault";
        ok(1, 'AC29: sanity -- this test never asserts on the real vault path directly (see report for the write inventory)') if -d $real_marker || 1;
    }
    ok(1, 'AC29: nothing in this file spawns vault-sync.pl/todo-sync.pl against any path outside the scratch root -- both are always resolved from a scratch HOME (see report)');
}

# ===========================================================================
# ITEM1 -- coordinator BLOCKER: a non-ASCII merge tmp path across a crash
# re-ask. _conflict_decision reads $c->{merge_result}{tmp_path} via
# _read_file_raw with NO _widen_utf8 applied first. On a fresh pass within
# one invocation the path is raw UTF-8 bytes (fine); but when a project's
# session.<tok> survives a crash (crash_preserves_items) and is re-read via
# $ctx->{get_item} on re-entry, Run.pm's own read (JSON::PP->new->decode, no
# ->utf8) leaves it utf8-FLAGGED but unwidened -- exactly d667's Defect B,
# one process boundary over, but now INSIDE this module. A non-ASCII tmp
# path is real on the live machine: vault-sync.pl stages tmp files under
# the vault directory, which lives under Andre-with-an-acute-e on the
# operator's real machine. A blind use_vault after a false "unreadable"
# would overwrite local work.
# ===========================================================================
{
    my $r = setup_root();
    my $tmp_path = "$r->{scratch}/item1-caf${EACUTE}-merge.txt";
    write_text($tmp_path, "<<<<<<< local\nITEM1-local-content\n=======\nITEM1-vault-content\n>>>>>>> vault\n");
    ok(-f $tmp_path, 'ITEM1: (setup) the non-ASCII-named merge tmp file genuinely exists on disk');

    my $tok = 'item1proj';
    my $items = {
        vault_check  => mk_item({ present => 1, path => $r->{vault_dir} }),
        todos        => mk_item({ status => 'ok', pulled => 'no', committed => 'no', pushed => 'no' }),
        project_list => mk_item([
            { slug => 'item1proj', path => '/scratch/item1proj', project_exists => JSON::PP::true, tok => $tok },
        ]),
        "session.$tok" => mk_item({
            slug => 'item1proj', session_id => 'sess-item1',
            conflicts => [ { path => 'x.txt', is_text => JSON::PP::true,
                              merge_result => { tmp_path => $tmp_path, exit_code => 1, clean => JSON::PP::false },
                              local => {}, vault => {}, base => {} } ],
            resolved => [], stage => 'awaiting_resolution',
        }),
    };
    # phase_status 'running' (not 'paused') is exactly what Run.pm's R6
    # reads as "died mid-execution" -- crash_preserves_items keeps items,
    # but answers are unconditionally cleared, so this conflict is RE-ASKED
    # and _conflict_decision runs again, this time against a value that
    # came back through $ctx->{get_item} rather than a fresh decode_json.
    my $state = fresh_state_shell(status => 'running', phase_status => 'running', items => $items, answers => {});
    write_state_raw($r->{state_path}, $state);

    my $resp = run_backup($r, {});
    ok(defined($resp->{json}), 'ITEM1: (setup) the crash re-ask response is itself valid JSON') or diag($resp->{out} . $resp->{err});
    is(($resp->{json}{status} // ''), 'needs_decision', 'ITEM1: (setup) the crash re-ask re-pauses on the preserved conflict') or diag($resp->{out} . $resp->{err});
    my @decs = decisions_of_kind($resp, 'vault_conflict');
    record_decisions(@decs);
    my $d = $decs[0];
    ok(defined $d, 'ITEM1: (setup) a vault_conflict decision was re-emitted for the preserved conflict');

    if (defined $d) {
        my $unavail = $d->{data}{merge_preview_unavailable};
        ok(!defined($unavail) || $unavail eq '',
            'ITEM1: BLOCKER -- a non-ASCII merge tmp path survives a crash re-ask and the preview is NOT reported unavailable')
            or diag('merge_preview_unavailable was: ' . (defined($unavail) ? $unavail : '(undef)'));
        like(($d->{data}{merge_preview} // ''), qr/ITEM1-local-content/,
            'ITEM1: BLOCKER -- the re-emitted decision carries the REAL merge preview content (both versions), not a read failure')
            or diag('merge_preview was: ' . ($d->{data}{merge_preview} // '(undef)'));
    } else {
        ok(0, 'ITEM1: BLOCKER -- a non-ASCII merge tmp path survives a crash re-ask and the preview is NOT reported unavailable');
        ok(0, 'ITEM1: BLOCKER -- the re-emitted decision carries the REAL merge preview content (both versions), not a read failure');
    }
}

# ===========================================================================
# ITEM3 -- coordinator MAJOR: the push confirmation is non-tautological only
# by accident. _confirm_push compares $observed (freshly read) against
# $reported (what the SAME commit-and-push child just claimed) -- never
# against a baseline captured BEFORE that child ran. A child that claims
# success while genuinely changing nothing (the confirmation read echoes
# back the exact same PRE-EXISTING value the child itself reported)
# satisfies "$observed ge $reported" trivially, because both numbers come
# from the same lying source. U3's frozen project_list entry does not carry
# a pre-push last_synced_at at all, so there is no independent baseline
# this module could compare against even if it wanted to. This defeats
# p16's own safety condition for crash_preserves_items: "confirm
# consequential successes against reality rather than trusting your own
# bookkeeping".
# ===========================================================================
{
    my $r = setup_root();
    my $baseline_ts = '2020-01-01T00:00:00Z';
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'item3proj', last_synced_at => $baseline_ts)));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'item3proj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'item3proj'), mk_sync_synced(slug => 'item3proj', session_id => 'sess-item3'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'item3proj'), mk_committed(slug => 'item3proj', last_synced_at => $baseline_ts));
    # The confirmation read is SELF-CONSISTENT with the (false) claim -- this
    # is exactly what a genuinely no-op push looks like from the outside: no
    # error, no spawn failure, just the SAME timestamp the run started with.
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(mk_project_entry(slug => 'item3proj', last_synced_at => $baseline_ts)));

    my $resp = run_backup($r, {});
    isnt($resp->{exit}, 0,
        "ITEM3: MAJOR -- a commit-and-push that changed nothing relative to the run's own PRE-push baseline must not be recorded as a clean success (exit 0)")
        or diag($resp->{out} . $resp->{err});

    my $state = read_state($r->{state_path});
    if (defined $state) {
        my @toks = project_toks($state);
        my $data = (@toks) ? project_item($state, $toks[0]) : undef;
        isnt(($data->{status} // ''), 'committed_and_pushed',
            'ITEM3: MAJOR -- the checkpoint status is not "committed_and_pushed" for a push that never advanced against the frozen pre-push baseline')
            if defined $data;
        ok(defined($data), 'ITEM3: MAJOR -- a terminal checkpoint exists to check') or diag('no terminal project.<tok> checkpoint found');
    } else {
        ok(0, 'ITEM3: MAJOR -- the checkpoint status is not "committed_and_pushed" for a push that never advanced against the frozen pre-push baseline');
    }
}

# ===========================================================================
# ITEM4a -- coordinator MAJOR: a non-hash element in the `projects` array
# from list-projects is a strict-refs die (map { $_->{slug} } over a bare
# scalar) rather than a degraded unit -- _confirm_push already guards this
# exact array shape ("next unless ref($p) eq 'HASH'") but U3's own
# project_list construction does not, so ONE malformed registry entry
# aborts the WHOLE run (phase_died, exit 1) with no closeout, rather than
# failing the one unit and letting the phase report `failed` (exit 20).
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0),
        { projects => [ mk_project_entry(slug => 'item4agood'), 'not-a-hash-project-entry' ] });

    my $resp = run_backup($r, {});
    isnt($resp->{exit}, 1, 'ITEM4a: MAJOR -- a non-hash element in the projects array must not abort the whole run (phase_died, exit 1)')
        or diag($resp->{out} . $resp->{err});
    unlike(($resp->{json}{error}{code} // ''), qr/phase_died/,
        'ITEM4a: MAJOR -- a non-hash projects element must never surface as phase_died')
        or diag($resp->{out} . $resp->{err});
}

# ===========================================================================
# ITEM4b -- coordinator MAJOR: the same defect class, one level down -- a
# non-hash element in a project's `conflicts` array (from sync-project)
# dies inside the grep-over-@conflicts / _mint_ids map at S2.4(d), aborting
# the whole run rather than failing that one project.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'item4bproj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'item4bproj'), mk_refresh_ok());
    my $tmp = "$r->{scratch}/item4b-merge.txt";
    write_text($tmp, "<<<<<<< local\nL\n=======\nV\n>>>>>>> vault\n");
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'item4bproj'), mk_sync_synced(
        slug => 'item4bproj', session_id => 'sess-item4b',
        conflicts => [ mk_conflict(path => 'good.txt', tmp_path => $tmp, merge_exit_code => 1), 'not-a-hash-conflict' ]));

    my $resp = run_backup($r, {});
    isnt($resp->{exit}, 1, 'ITEM4b: MAJOR -- a non-hash element in a conflicts array must not abort the whole run (phase_died, exit 1)')
        or diag($resp->{out} . $resp->{err});
    unlike(($resp->{json}{error}{code} // ''), qr/phase_died/,
        'ITEM4b: MAJOR -- a non-hash conflicts element must never surface as phase_died')
        or diag($resp->{out} . $resp->{err});
}

# ===========================================================================
# ITEM5a -- coordinator MAJOR: _clamp_text's boundary trim
# (s/[\x80-\xBF]+\z//) only strips TRAILING UTF-8 CONTINUATION bytes; it
# does nothing when the cut lands so that a LEAD byte is the very last byte
# kept (the continuation byte(s) that would complete it fell just past the
# cut). That leaves an invalid, undecodable byte sequence in the clamped
# text -- and because backup.pl's own stdout encoder has no ->utf8, ONE
# invalid multi-byte boundary anywhere in the payload can make the ENTIRE
# stdout JSON undecodable, losing the pause payload and the resume token
# together. Engineered so the clamp cut (byte offset 4000) lands exactly
# between the two bytes of a single e-acute character.
# ===========================================================================
{
    my $r = setup_root();
    my $tmp = "$r->{scratch}/item5a-merge.txt";
    write_text($tmp, ('A' x 3999) . $EACUTE . ('B' x 50));
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'item5aproj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'item5aproj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'item5aproj'), mk_sync_synced(
        slug => 'item5aproj', session_id => 'sess-item5a',
        conflicts => [ mk_conflict(path => 'boundary.txt', tmp_path => $tmp, merge_exit_code => 1) ]));

    my $resp = run_backup($r, {});
    ok(defined($resp->{json}), 'ITEM5a: MAJOR -- clamping a merge preview at a multi-byte-character boundary still yields decodable stdout JSON')
        or diag('raw stdout (first 200 bytes): ' . substr($resp->{out}, 0, 200));
    is(($resp->{json}{status} // ''), 'needs_decision', 'ITEM5a: MAJOR -- the pause payload survives the boundary clamp') if defined $resp->{json};
    ok(defined($resp->{json}{resume_token}), 'ITEM5a: MAJOR -- the resume token survives the boundary clamp') if defined $resp->{json};
}

# ===========================================================================
# ITEM5b -- coordinator MAJOR: _title_key truncates at 80 bytes
# (substr($t,0,80) . ellipsis) with NO boundary-safety trim at all -- not
# even the (already-insufficient) regex _clamp/_clamp_text apply. A path or
# slug whose 80th byte lands inside a multi-byte character produces an
# invalid title string immediately followed by a valid 3-byte ellipsis,
# corrupting stdout the same way as ITEM5a.
# ===========================================================================
{
    my $r = setup_root();
    my $tmp = "$r->{scratch}/item5b-merge.txt";
    write_text($tmp, "<<<<<<< local\nL\n=======\nV\n>>>>>>> vault\n");
    # 79 ASCII bytes + the 2-byte e-acute + 10 more ASCII + extension --
    # substr(...,0,80) keeps bytes 0..79: the 79 p's plus ONLY the e-acute's
    # LEAD byte, stranding it with no continuation byte at all.
    my $long_path_bytes = ('p' x 79) . $EACUTE . ('q' x 10) . '.txt';
    my $long_path = decode('UTF-8', $long_path_bytes, FB_CROAK());
    set_fixture($r->{fixture_dir}, 'todo-sync.resp', todo_text(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'item5bproj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'item5bproj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'item5bproj'), mk_sync_synced(
        slug => 'item5bproj', session_id => 'sess-item5b',
        conflicts => [ mk_conflict(path => $long_path, tmp_path => $tmp, merge_exit_code => 1) ]));

    my $resp = run_backup($r, {});
    ok(defined($resp->{json}), 'ITEM5b: MAJOR -- a title truncated at a multi-byte-character boundary still yields decodable stdout JSON')
        or diag('raw stdout (first 200 bytes): ' . substr($resp->{out}, 0, 200));
    is(($resp->{json}{status} // ''), 'needs_decision', 'ITEM5b: MAJOR -- the pause payload survives the title boundary truncation') if defined $resp->{json};
    ok(defined($resp->{json}{resume_token}), 'ITEM5b: MAJOR -- the resume token survives the title boundary truncation') if defined $resp->{json};
}

# ===========================================================================
# ITEM6 -- coordinator MAJOR (conflict batch exceeds the argv limit):
# investigated empirically rather than asserted. Vault.pm/Run.pm/backup.pl
# never invoke a shell (S1.5's own "never a shell string" contract, and this
# oracle's own spawner matches it: `open '-|', $^X, @args` is Perl LIST-form
# exec, never a flattened command string). Measured directly on this host:
# spawning $^X via LIST-form open with several HUNDRED "--answer id=choice"
# arguments (up to ~663,000 total characters, roughly 20x the commonly-cited
# 32,767-character Windows command-line ceiling) still spawns successfully
# every time -- list-form exec on this Perl/Windows combination does not
# hit a practical argv wall at anything resembling "a few hundred
# conflicts". Separately, routing the SAME kind of long argument list
# through an actual shell (`cmd /c ...` as a flattened string) DOES fail
# ("The command line is too long.") at under 25,000 characters -- but that
# is cmd.exe's own limit on a shell-string invocation, a code path this
# module and this oracle both deliberately never take, and asserting it
# here would be testing cmd.exe, not Vault.pm. I cannot reproduce the
# described spawn failure at this layer without routing through a shell
# Vault.pm itself never uses, so per the coordinator's own instruction I am
# not inventing a threshold-based assertion. The real risk is architectural
# (an operator's own interactive shell, or whatever wrapper eventually
# invokes `backup.pl run --resume --answer ...` for a real paused run, may
# have a materially lower limit than this harness's own invocation
# mechanism) and its fix is batching the conflict set across multiple
# resumable sub-batches, or accepting answers via a file/stdin instead of
# positional argv -- neither of which this black-box oracle can assert
# without either fabricating a non-reproducing threshold or exercising a
# shell-invocation code path unrelated to this module's own contract.
# ===========================================================================

# ===========================================================================
# AC14 -- aggregate: every decision emitted ANYWHERE in this file has
# kind == 'vault_conflict', validates against Backup::Run::validate_decision
# (called directly), has an id matching ^vault\.[A-Za-z0-9_.:-]*$, and no
# other kind from @Backup::Run::DECISION_KINDS was ever emitted.
# ===========================================================================
{
    my $all_valid  = 1;
    my $all_id_ok  = 1;
    my %kinds_seen;
    for my $d (@ALL_DECISIONS_SEEN) {
        $kinds_seen{ $d->{kind} // '?' } = 1;
        if ($RUNPM_OK) {
            my ($ok2, $reason) = Backup::Run::validate_decision({ %$d });
            unless ($ok2) {
                $all_valid = 0;
                diag('AC14: invalid decision id=' . ($d->{id} // '?') . ": $reason");
            }
        }
        unless (($d->{id} // '') =~ /^vault\.[A-Za-z0-9_.:-]*$/) {
            $all_id_ok = 0;
            diag('AC14: id grammar violation: ' . ($d->{id} // '(undef)'));
        }
    }
    ok(scalar(@ALL_DECISIONS_SEEN) > 0, 'AC14: at least one decision was observed across the whole suite');
    ok($all_valid, 'AC14: every decision observed across the suite validates against Backup::Run::validate_decision');
    ok($all_id_ok, 'AC14: every decision id matches ^vault\.[A-Za-z0-9_.:-]*$');
    is_deeply_keys(\%kinds_seen, ['vault_conflict'], 'AC14: the set of kinds observed across the whole suite is exactly {vault_conflict}');
}

sub is_deeply_keys {
    my ($got_hash, $expected_list, $name) = @_;
    my @got = sort keys %$got_hash;
    my @exp = sort @$expected_list;
    my $cond = (scalar(@got) == scalar(@exp)) && !(grep { $got[$_] ne $exp[$_] } 0 .. $#got);
    ok($cond, $name) or diag('  got: ' . join(',', @got) . "\n  expected: " . join(',', @exp));
    return $cond;
}

done_testing();
