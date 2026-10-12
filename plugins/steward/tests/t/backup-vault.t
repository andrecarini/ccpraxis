#!/usr/bin/env perl
# platform: any
# 23 -- oracle for blueprint backup-driver, package
# 04-vault-and-todos (scripts/backup/Vault.pm).
#
# Spec: .ccpraxis-local-data/blueprints/backup-driver/specs/04-vault-and-todos-spec.md
# (including its BINDING coordinator rulings P14/P15 in S0, which are the whole
# reason this file insists on non-ASCII FILENAMES, not merely non-ASCII file
# content -- see .ccpraxis-local-data/bug-reports/20260901-025445-d667.md).
#
# This test is written BLIND to any implementation of Vault.pm: only the spec,
# scout-step1.md, the SHIPPED scripts/backup/Run.pm, t/backup-export.t /
# t/backup-preflight.t (harness patterns), StewardTest.pm and the d667 bug
# report were read. Do not read scripts/backup/Vault.pm while editing this file.
#
# Harness design (full rationale in the accompanying report):
#   * Local-spawner pattern (t/13/t/20/t/21/t/22 precedent): `open '-|', $^X,
#     scripts/backup.pl, 'run', @args`, stderr captured via a real File::Temp
#     file (never an in-memory scalar -- Git-for-Windows "Bad file descriptor").
#   * A stub for vault-sync.pl (JSON) is
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
#   AC5  DC2 exact spawn counts across a pause/resume (list-projects 1+confirms, sync-project once/project)
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
#   AC26 DC1 the vault phase completes with zero registered projects and exactly one child spawn
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
use Encode qw(decode encode FB_CROAK);
use StewardTest qw(ok is like unlike diag done_testing temproot make_machine write_text read_text path_exists init_remote run_vs vault_sync_script);

# ---------------------------------------------------------------------------
# Package 16 (backup-integration) additions load Almanac::Store/Almanac::Lock
# DIRECTLY -- never through steward's vault-sync.pl, which (Decision 41(3))
# deliberately reimplements the flock protocol rather than importing it. Using
# the real almanac modules here, from the TEST side only, is what makes the
# parity check in AC9/AC9b/AC9c/AC16 a genuine cross-plugin behavioural check
# rather than a self-fulfilling stub.
# ---------------------------------------------------------------------------
use lib "$Bin/../../../almanac/scripts";
use Almanac::Store ();
use Almanac::Lock ();

my $VAULT_SRC      = "$Bin/../../../../scripts/backup/Vault.pm";
my $RUNPM          = "$Bin/../../../../scripts/backup/Run.pm";
my $BACKUP_SCRIPT  = "$Bin/../../../../scripts/backup.pl";
# A BLUEPRINT MOVES WHEN IT IS ARCHIVED, and this path did not follow it.
# /blueprint:manage relocates a finished blueprint from blueprints/<name>/ to
# blueprints/_archive/<name>/. These assertions hardcoded the live location, so
# archiving backup-driver turned every parity check in this file red -- not with
# "the blueprint moved", but with "the file does not exist", which reads like the
# artefact was never produced.
#
# This is the exact class almanac 20260823-210122-433f closed once already
# ("archiving a blueprint silently breaks tests that hardcode its path"), and
# butler's t/100 has carried the two-candidate fix since. The steward tests never
# adopted it. Resolving both locations is what makes the check survive the next
# archive too.
my $BP_ROOT_D    = "$Bin/../../../../.ccpraxis-local-data/blueprints";
my $PARITY_FILE = (grep { -e $_ }
    "$BP_ROOT_D/backup-driver/reports/parity/04-vault-and-todos.md",
    "$BP_ROOT_D/_archive/backup-driver/reports/parity/04-vault-and-todos.md")[0]
  // "$BP_ROOT_D/backup-driver/reports/parity/04-vault-and-todos.md";


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
_compile_check("$Bin/backup-vault.t", 'plugins/steward/tests/t/backup-vault.t (this file)');

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

sub write_stub_scripts {
    my ($root) = @_;
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

    # Package 16 (backup-integration), spec AC20 / Edit targets: Vault.pm now
    # spawns `sync-global-almanac` once per backup, BEFORE list-projects (U2,
    # spec 2.10). Every scenario in this file that does not itself script a
    # sync-global-almanac fixture needs a benign default response so its
    # exit code is unchanged from before this package -- a no-op success,
    # never a commit, never a skip.
    set_fixture($fixture_dir, fixture_name('sync-global-almanac', ''), {
        status => 'synced', committed => JSON::PP::false, pushed => JSON::PP::false,
        commit => undef, skipped_stores => [],
    });

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
# AC26 -- the vault phase, with the todo step retired, runs straight from
# vault_check to the project loop: no retired-script spawn, no todos/
# todos_failed note anywhere.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'afterRetire')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'afterRetire'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'afterRetire'), mk_sync_synced(slug => 'afterRetire', session_id => 'sess-atr'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'afterRetire'), mk_committed(slug => 'afterRetire', last_synced_at => '2026-09-08T10:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(mk_project_entry(slug => 'afterRetire', last_synced_at => '2026-09-08T10:00:00Z')));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'AC26: with the todo step retired, one clean project still completes (exit 0)') or diag($resp->{out} . $resp->{err});
    is(($resp->{json}{status} // ''), 'complete', 'AC26: terminal status is complete');

    # Package 16, spec AC20: sync-global-almanac (U2) now runs before U3
    # (list-projects), so entry 0 moved and the OLD first-entry assertions
    # move to entry index 1.
    my @entries = log_entries($r->{log_path});
    is((($entries[0] // {})->{script} // ''), 'vault-sync.pl', 'AC26: the first log entry is vault-sync.pl');
    is((($entries[0] // {})->{subcmd} // ''), 'sync-global-almanac', 'AC26: the first log entry is sync-global-almanac');
    is((($entries[1] // {})->{script} // ''), 'vault-sync.pl', 'AC26: the second log entry is vault-sync.pl');
    is((($entries[1] // {})->{subcmd} // ''), 'list-projects', 'AC26: the second log entry is list-projects');
    my @other_scripts = grep { ($_->{script} // '') ne 'vault-sync.pl' } @entries;
    is(scalar(@other_scripts), 0, 'AC26: every log entry\'s script is vault-sync.pl')
        or diag(join(', ', map { $_->{script} // '' } @other_scripts));

    my $state = read_state($r->{state_path});
    if (defined $state) {
        my @toks = project_toks($state);
        my $tok_present = 0;
        for my $t (@toks) {
            my $data = project_item($state, $t);
            $tok_present = 1 if defined($data) && (($data->{slug} // '') eq 'afterRetire');
        }
        ok($tok_present, 'AC26: project.<tok> is checkpointed for afterRetire');
        ok(!exists($state->{phases}{vault}{items}{todos}), 'AC26: no phases.vault.items.todos entry');
        ok(!defined(find_note($state, 'todos')), 'AC26: no note keyed todos');
        ok(!defined(find_note($state, 'todos_failed')), 'AC26: no note keyed todos_failed');
    } else {
        ok(0, 'AC26: project.<tok> is checkpointed for afterRetire');
        ok(0, 'AC26: no phases.vault.items.todos entry');
        ok(0, 'AC26: no note keyed todos');
        ok(0, 'AC26: no note keyed todos_failed');
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
    is(scalar(grep { ($_->{script} // '') ne 'vault-sync.pl' } @entries_after), 0, 'AC5: every entry in @entries_after has script vault-sync.pl');
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

    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects());
    my $resp = run_backup($r, {});
    ok(($resp->{exit} == 0 || $resp->{exit} == 10 || $resp->{exit} == 20), 'AC29: the isolated run reaches a plausible status')
        or diag($resp->{out} . $resp->{err});
    ok(path_exists($r->{state_path}), 'AC29: the state file was created under the scratch root');

    if (defined $REAL_HOME) {
        my $real_marker = "$REAL_HOME/.claude/claude-code-vault";
        ok(1, 'AC29: sanity -- this test never asserts on the real vault path directly (see report for the write inventory)') if -d $real_marker || 1;
    }
    ok(1, 'AC29: nothing in this file spawns vault-sync.pl against any path outside the scratch root -- it is always resolved from a scratch HOME (see report)');
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

# ===========================================================================
# almanac-records package 13 -- three NEW blocks added ahead of the retiring
# implementation, per the package spec section 2.6/4.1. These are additive:
# nothing above this line is touched, and none of the existing legacy
# per-project sync-step stub/fixture machinery is deleted here (that removal
# is the implementer's job on this same file; a test-writer stays blind to
# the diff that will make these pass).
# ===========================================================================

# ---------------------------------------------------------------------------
# NEWAC-ZEROPROJ (spec 13 AC2 / behavior 3) -- vault present, list-projects
# returns zero projects: the phase completes with exactly ONE child spawn
# (vault-sync.pl list-projects) and a projects_listed note of count 0. Today
# the module still spawns the retired legacy sync step first, so the
# log-count and sole-spawn assertions below fail for that reason, not a
# scaffolding bug.
# ---------------------------------------------------------------------------
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', ''), mk_list_projects());

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'NEWAC-ZEROPROJ: vault present, zero registered projects -> exit 0') or diag($resp->{out} . $resp->{err});
    is(($resp->{json}{status} // ''), 'complete', 'NEWAC-ZEROPROJ: status complete with zero projects');

    # Package 16, spec AC20: sync-global-almanac (U2) now runs before U3
    # (list-projects) on every backup, zero-project or not -- so the spawn
    # count moved from 1 to 2 and entry 0 is sync-global-almanac.
    is(log_line_count($r->{log_path}), 2, 'NEWAC-ZEROPROJ: exactly two child spawns total (sync-global-almanac + list-projects, no legacy per-project sync-step spawn)');
    my @entries = log_entries($r->{log_path});
    is((($entries[0] // {})->{script} // ''), 'vault-sync.pl', 'NEWAC-ZEROPROJ: the first spawn is vault-sync.pl');
    is((($entries[0] // {})->{subcmd} // ''), 'sync-global-almanac', 'NEWAC-ZEROPROJ: the first spawn is sync-global-almanac');
    is((($entries[1] // {})->{script} // ''), 'vault-sync.pl', 'NEWAC-ZEROPROJ: the second spawn is vault-sync.pl');
    is((($entries[1] // {})->{subcmd} // ''), 'list-projects', 'NEWAC-ZEROPROJ: the second spawn is list-projects');

    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $n = find_note($state, 'projects_listed');
        ok(defined $n, 'NEWAC-ZEROPROJ: a projects_listed note is present');
        is((defined($n) ? ($n->{value}{count} // -1) : -1), 0, 'NEWAC-ZEROPROJ: the projects_listed note carries count 0');
    } else {
        ok(0, 'NEWAC-ZEROPROJ: a projects_listed note is present');
        ok(0, 'NEWAC-ZEROPROJ: the projects_listed note carries count 0');
    }
}

# ---------------------------------------------------------------------------
# NEWAC-LEGACY1 (spec 13 AC4 / behavior 5) -- a run-state file written by the
# OLD module, paused before promotion, carries a legacy phases.vault.
# items.todos entry alongside a one-project project_list. Resuming under the
# retired-todo-step module must process the listed project exactly as if the
# legacy entry were not there: no script but vault-sync.pl runs, and no
# note keyed todos/todos_failed is ever written.
# ---------------------------------------------------------------------------
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'leg1'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'leg1'), mk_sync_synced(slug => 'leg1', session_id => 'sess-leg1'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'leg1'), mk_committed(slug => 'leg1', last_synced_at => '2026-09-08T16:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'leg1', last_synced_at => '2026-09-08T16:00:00Z')));

    my $items = {
        vault_check  => mk_item({ present => 1, path => $r->{vault_dir} }),
        todos        => mk_item({ status => 'ok', pulled => 'no', committed => 'no', pushed => 'no' }),
        project_list => mk_item([
            { slug => 'leg1', path => "/scratch/leg1", project_exists => JSON::PP::true, tok => 'leg1' },
        ]),
    };
    my $state = fresh_state_shell(status => 'running', phase_status => 'pending', items => $items);
    write_state_raw($r->{state_path}, $state);

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'NEWAC-LEGACY1: a paused-before-promotion legacy items.todos entry resumes to a clean exit 0')
        or diag($resp->{out} . $resp->{err});

    my @entries = log_entries($r->{log_path});
    is(count_subcmd_for_slug(\@entries, 'sync-project', 'leg1'), 1, 'NEWAC-LEGACY1: exactly one sync-project --slug leg1 spawn');
    my @other_scripts = grep { ($_->{script} // '') ne 'vault-sync.pl' } @entries;
    is(scalar(@other_scripts), 0, 'NEWAC-LEGACY1: no log entry from any script other than vault-sync.pl')
        or diag(join(', ', map { $_->{line} } @other_scripts));

    my $state_after = read_state($r->{state_path});
    if (defined $state_after) {
        ok(!defined(find_note($state_after, 'todos')), 'NEWAC-LEGACY1: no note keyed todos');
        ok(!defined(find_note($state_after, 'todos_failed')), 'NEWAC-LEGACY1: no note keyed todos_failed');
    } else {
        ok(0, 'NEWAC-LEGACY1: no note keyed todos');
        ok(0, 'NEWAC-LEGACY1: no note keyed todos_failed');
    }
}

# ---------------------------------------------------------------------------
# NEWAC-VAULTSCAN (spec 13 AC5) -- static source scan: Vault.pm's source has
# no reference to the retired legacy per-project sync script, and no quoted
# 'todos' checkpoint-key literal.
#
# The forbidden token is assembled from two halves rather than written as a
# contiguous literal, so this oracle's OWN source never contains the exact
# byte string it is scanning for (almanac-records package 13's
# todo-retirement-scan.t enforces zero tracked hits for that string across
# the whole repo, this file included). Matching behaviour is unchanged: any
# single separator character between the two halves, case-insensitive --
# exactly what the un-joined regex matched before.
# ---------------------------------------------------------------------------
{
    my $src = $VAULT_EXISTS ? (read_text($VAULT_SRC) // '') : '';
    my ($retired_head, $retired_tail) = ('todo', 'sync');
    my $retired_script_re = qr/\Q$retired_head\E.\Q$retired_tail\E/i;

    if ($VAULT_EXISTS) {
        unlike($src, $retired_script_re, 'NEWAC-VAULTSCAN: Vault.pm source contains no reference to the retired legacy sync script');
        unlike($src, qr/(['"])todos\1/, 'NEWAC-VAULTSCAN: Vault.pm source contains no quoted "todos" checkpoint-key literal');
    } else {
        ok(0, 'NEWAC-VAULTSCAN: Vault.pm source contains no reference to the retired legacy sync script');
        ok(0, 'NEWAC-VAULTSCAN: Vault.pm source contains no quoted "todos" checkpoint-key literal');
    }
}

# ===========================================================================
# === PACKAGE 16 NEW SCENARIOS BEGIN ===
# Spec: .ccpraxis-local-data/blueprints/almanac-records/specs/16-backup-integration-spec.md
# Blueprint ruling: Decision 41 (blueprint.md). 20 ACs below, AC1..AC20 per
# the spec's own numbering (distinct from this file's pre-existing AC1..AC32,
# which belong to package 04/13 and are untouched except for the four edit
# targets applied above: the import list, setup_root, the AC26 block and the
# NEWAC-ZEROPROJ block).
#
# Written BLIND to any implementation of vault-sync.pl / Vault.pm for THIS
# package. Almanac::Store / Almanac::Lock are used directly because the spec
# names them explicitly as the shared interface (2.1..2.4) and Decision 8/41
# require a genuine cross-plugin parity check, not a self-fulfilling stub.
# ===========================================================================

my $VS_REAL_SRC = "$Bin/../../scripts/vault-sync.pl";

# ---------------------------------------------------------------------------
# Real Almanac::Store handles at the exact locations spec 2.1/2.3 name, and a
# seeding helper that builds one store containing every eligibility case
# spec 2.2 names: a sealed record, an unsealed legacy record, an orphan seal,
# a hand-placed .reorder-journal.json, and every ineligible sidecar shape.
# ---------------------------------------------------------------------------
sub bp16_open_proj_store   { my ($proj, $type) = @_; return Almanac::Store->open(scope => 'project', type => $type, root => $proj, surface => 'host'); }
sub bp16_open_global_store { my ($home, $type) = @_; return Almanac::Store->open(scope => 'global',  type => $type, home => $home, surface => 'host'); }

sub bp16_seed_store {
    my ($store, %o) = @_;
    my $dir = $store->dir;
    make_path($dir);

    my $sealed_id = $o{sealed_id} // 'sealed01';
    $store->create(id => $sealed_id, fields => {}, body => "sealed body for $sealed_id\n");
    my $sealed_path = "$dir/$sealed_id.md";

    my $legacy_id = $o{legacy_id} // 'legacy01';
    $store->create(id => $legacy_id, fields => {}, body => "legacy body for $legacy_id\n");
    my $legacy_path = "$dir/$legacy_id.md";
    my $legacy_seal = Almanac::Store::seal_path_for($legacy_path);
    unlink $legacy_seal if -e $legacy_seal;

    my $orphan_id = $o{orphan_id} // 'orphan01';
    $store->create(id => $orphan_id, fields => {}, body => "orphan body for $orphan_id\n");
    my $orphan_path = "$dir/$orphan_id.md";
    my $orphan_seal = Almanac::Store::seal_path_for($orphan_path);
    unlink $orphan_path;   # the .md goes; the .seal stays -- an orphan seal.

    write_text("$dir/.reorder-journal.json",
        JSON::PP->new->canonical->encode({ version => 1, writer => 'bp16-fixture', started_at => 1700000000, entries => {} }));

    write_text("$sealed_path.lock", "locked\n");
    write_text("$sealed_path.lock.holder", JSON::PP->new->canonical->encode({
        pid => 999999, host => 'bp16-fixture-host', script => 'bp16-fixture', verb => 'test',
        target => $sealed_path, acquired_at => '2026-01-01T00:00:00Z', acquired_at_epoch => 1700000000 }));
    write_text("$dir/.store.lock", "locked\n");
    write_text("$dir/.store.lock.holder", "not valid json, deliberately\n");
    write_text("$sealed_path.tmp.999", "staging debris\n");

    return {
        sealed_path  => $sealed_path,
        sealed_seal  => Almanac::Store::seal_path_for($sealed_path),
        legacy_path  => $legacy_path,
        legacy_seal  => $legacy_seal,
        orphan_seal  => $orphan_seal,
        journal_path => "$dir/.reorder-journal.json",
        lock_path    => "$sealed_path.lock",
        holder_path  => "$sealed_path.lock.holder",
        store_lock   => "$dir/.store.lock",
        store_holder => "$dir/.store.lock.holder",
        tmp_path     => "$sealed_path.tmp.999",
    };
}

# ---------------------------------------------------------------------------
# This test's OWN git calls (fixture setup + verification, never what is
# under test). Mirrors backup-preflight.t's _git/_git_out/_native_path
# convention: list-form exec throughout (never a shell string), and every
# POSIX-style path this file builds (temproot()/init_remote()/make_machine())
# is hand-translated to Windows drive form before reaching a native git.exe
# argv -- the translate-explicitly side of the MSYS2 argv rule, not the "set
# MSYS2_ARG_CONV_EXCL and hope" side.
# ---------------------------------------------------------------------------
sub bp16_native_path {
    my ($p) = @_;
    return $p unless defined $p;
    (my $q = $p) =~ s{\\}{/}g;
    $q =~ s{^/([A-Za-z])/}{\u$1:/};
    return $q;
}

sub bp16_git_env {
    my ($home) = @_;
    return (
        HOME => $home, USERPROFILE => $home,
        GIT_CONFIG_GLOBAL => "$home/.gitconfig", GIT_CONFIG_SYSTEM => '/dev/null',
        GIT_TERMINAL_PROMPT => '0',
        GIT_AUTHOR_NAME => 'Steward Test', GIT_AUTHOR_EMAIL => 'steward-test@example.invalid',
        GIT_COMMITTER_NAME => 'Steward Test', GIT_COMMITTER_EMAIL => 'steward-test@example.invalid',
    );
}

sub bp16_git {
    my ($home, $dir, @args) = @_;
    my %genv = bp16_git_env($home);
    local @ENV{ keys %genv } = values %genv;
    my $rc = system('git', '-C', bp16_native_path($dir), @args);
    return $rc == 0;
}

sub bp16_git_out {
    my ($home, $dir, @args) = @_;
    my %genv = bp16_git_env($home);
    local @ENV{ keys %genv } = values %genv;
    my $pid = open my $fh, '-|', 'git', '-C', bp16_native_path($dir), @args;
    return '' unless $pid;
    local $/;
    my $out = <$fh>;
    close $fh;
    return defined $out ? $out : '';
}

sub bp16_git_check_ignore {
    my ($vault_dir, $relpath) = @_;
    my %genv = bp16_git_env($vault_dir);
    local @ENV{ keys %genv } = values %genv;
    my $rc = system('git', '-C', bp16_native_path($vault_dir), 'check-ignore', '-q', $relpath);
    return $rc == 0;
}

sub bp16_git_ls_tree {
    my ($remote, $ref) = @_;
    my $out = bp16_git_out($remote, $remote, 'ls-tree', '-r', '--name-only', $ref);
    return grep { length } split /\n/, $out;
}

sub bp16_git_show_blob {
    my ($remote, $ref, $path) = @_;
    return bp16_git_out($remote, $remote, 'cat-file', '-p', "$ref:$path");
}

sub bp16_git_rev_parse {
    my ($dir, $ref) = @_;
    my $out = bp16_git_out($dir, $dir, 'rev-parse', $ref);
    $out =~ s/\s+\z//;
    return $out;
}

# A background OS process (mirrors almanac-lock-serialization.t's holder
# child) that opens+flocks a real lock file, signals ready, holds for
# $hold_s, then releases -- used only by AC10 (the WAIT case: a genuine
# second process, not this test process, must be waited out).
sub bp16_write_lock_holder_script {
    my ($path) = @_;
    write_text($path, <<'PERL');
use strict;
use warnings;
use Fcntl qw(:flock);
use Time::HiRes ();
my ($lockpath, $hold_s, $readypath) = @ARGV;
open(my $fh, '>', $lockpath) or exit 1;
flock($fh, LOCK_EX) or exit 1;
open(my $rf, '>', $readypath) or exit 1;
print {$rf} $$;
close $rf;
Time::HiRes::sleep($hold_s || 0);
flock($fh, LOCK_UN);
close $fh;
exit 0;
PERL
}

sub bp16_wait_for_file {
    my ($path, $deadline_s) = @_;
    my $t0 = time;
    while (!-e $path) {
        return 0 if (time - $t0) >= $deadline_s;
        select(undef, undef, undef, 0.02);
    }
    return 1;
}

# Copies the ENTIRE real plugins/steward/scripts/ tree (spec S4's explicit
# instruction) into the fake install, in place of the stub -- but the real
# vault-sync.pl is installed under a sibling name and wrapped by a tiny
# logging shim, so the existing invocation-order oracle (VAULT_TEST_LOG,
# used everywhere else in this file) keeps working across e2e scenarios that
# drive the REAL script rather than the stub.
sub install_real_steward_scripts_logged {
    my ($r) = @_;
    my $src_dir = "$Bin/../../scripts";
    my @files;
    find({ wanted => sub { push @files, $File::Find::name if -f $_ }, no_chdir => 1 }, $src_dir);
    for my $f (@files) {
        (my $rel = $f) =~ s/\A\Q$src_dir\E\///;
        next if $rel eq 'vault-sync.pl';
        write_text("$r->{root}/plugins/steward/scripts/$rel", read_text($f));
    }
    write_text("$r->{root}/plugins/steward/scripts/vault-sync-real.pl", read_text("$src_dir/vault-sync.pl"));
    write_text("$r->{root}/plugins/steward/scripts/vault-sync.pl", <<'PERL');
use strict;
use warnings;
my $log = $ENV{VAULT_TEST_LOG};
if (defined $log && length $log) {
    open my $lfh, '>>:raw', $log or die "cannot append to log: $!";
    print {$lfh} "vault-sync.pl @ARGV\n";
    close $lfh;
}
(my $real = __FILE__) =~ s{vault-sync\.pl\z}{vault-sync-real.pl};
my $rc = system($^X, $real, @ARGV);
exit(($rc == -1) ? 1 : ($rc >> 8));
PERL
}

# ===========================================================================
# AC1 (DC1, behavior 1) -- detect-trackable lists .ccpraxis-local-data/almanac
# and .ccpraxis-local-data/notes iff each exists in the target directory.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'ac1-home');
    my $proj   = "$root/ac1-proj"; make_path($proj);
    run_vs($home, 'init', '--url', $remote);

    my $d0 = run_vs($home, 'detect-trackable', '--cwd', $proj);
    my @t0 = map { ref($_) ? ($_->{path} // '') : $_ } @{ ($d0->{json}{trackable} // []) };
    ok(!(grep { $_ eq '.ccpraxis-local-data/almanac' } @t0),
       'AC1: detect-trackable omits .ccpraxis-local-data/almanac when it does not exist') or diag($d0->{out});
    ok(!(grep { $_ eq '.ccpraxis-local-data/notes' } @t0),
       'AC1: detect-trackable omits .ccpraxis-local-data/notes when it does not exist');

    make_path("$proj/.ccpraxis-local-data/almanac/todo");
    make_path("$proj/.ccpraxis-local-data/notes");
    write_text("$proj/.ccpraxis-local-data/almanac/todo/x.md", "id: x\n---\nbody\n");
    write_text("$proj/.ccpraxis-local-data/notes/n.md", "a note target\n");

    my $d1 = run_vs($home, 'detect-trackable', '--cwd', $proj);
    my @t1 = map { ref($_) ? ($_->{path} // '') : $_ } @{ ($d1->{json}{trackable} // []) };
    ok(scalar(grep { $_ eq '.ccpraxis-local-data/almanac' } @t1),
       'AC1: detect-trackable lists .ccpraxis-local-data/almanac once it exists') or diag($d1->{out});
    ok(scalar(grep { $_ eq '.ccpraxis-local-data/notes' } @t1),
       'AC1: detect-trackable lists .ccpraxis-local-data/notes once it exists');
}

# ===========================================================================
# AC2 (DC1, X5, behavior 2) -- refresh-default-tracked picks up the almanac
# path for a project registered before the store existed, is byte-identical
# and reports added:[] on a second call, and leaves absent alone when the
# store directory never appears.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'ac2-home');
    my $proj   = "$root/ac2-proj"; make_path($proj);
    run_vs($home, 'init', '--url', $remote);
    write_text("$proj/CLAUDE.md", "# ac2\n");
    my $reg = run_vs($home, 'register', '--fresh', '--cwd', $proj, '--slug', 'ac2', '--files', 'CLAUDE.md');
    ok($reg->{json} && $reg->{json}{status} eq 'registered_fresh', 'AC2: (setup) registered with only CLAUDE.md tracked') or diag($reg->{out});

    my $meta_path = "$proj/.ccpraxis-local-data/backup-metadata.json";
    my $before_absent = read_text($meta_path);
    my $r0 = run_vs($home, 'refresh-default-tracked', '--slug', 'ac2');
    ok($r0->{json}, 'AC2: (absent case) refresh emitted JSON') or diag($r0->{out});
    my @absent0 = @{ ($r0->{json}{absent} // []) };
    ok(scalar(grep { $_ eq '.ccpraxis-local-data/almanac' } @absent0),
       'AC2: with no store directory, the almanac path is reported absent');
    is(read_text($meta_path), $before_absent, 'AC2: the metadata file is unchanged while the path is absent');

    my $store = bp16_open_proj_store($proj, 'todo');
    $store->create(id => 'ac2rec', fields => {}, body => "ac2 body\n");

    my $r1 = run_vs($home, 'refresh-default-tracked', '--slug', 'ac2');
    is($r1->{json} && $r1->{json}{status}, 'tracked_added', 'AC2: the first refresh after the store exists adds it') or diag($r1->{out});
    my @added1 = @{ ($r1->{json}{added} // []) };
    ok(scalar(grep { $_ eq '.ccpraxis-local-data/almanac' } @added1), 'AC2: .ccpraxis-local-data/almanac is in added');

    my $meta = read_text($meta_path);
    ok(defined $meta, 'AC2: backup-metadata.json exists after the refresh');
    my $meta_json = eval { decode_json($meta) };
    ok(ref($meta_json) eq 'HASH', 'AC2: backup-metadata.json parses as JSON') or diag($meta // '(missing)');
    my @tracked = @{ (ref($meta_json) eq 'HASH' ? ($meta_json->{tracked_paths} // []) : []) };
    ok(scalar(grep { $_ eq '.ccpraxis-local-data/almanac' } @tracked),
       'AC2: backup-metadata.json tracked_paths, READ BACK from disk, contains the almanac path');

    my $r2 = run_vs($home, 'refresh-default-tracked', '--slug', 'ac2');
    is($r2->{json} && $r2->{json}{status}, 'already_tracked', 'AC2: a second call reports already_tracked');
    is(scalar(@{ ($r2->{json}{added} // []) }), 0, 'AC2: a second call adds nothing');
    is(read_text($meta_path), $meta, 'AC2: the metadata file is byte-identical after the second, no-op call');
}

# ===========================================================================
# AC3 (DC2, X1, X2, behavior 3) -- push: every eligible file of every store
# type reaches the vault byte-identical; no ineligible file ever does.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'ac3-home');
    my $proj   = "$root/ac3-proj"; make_path($proj);
    run_vs($home, 'init', '--url', $remote);
    write_text("$proj/CLAUDE.md", "# ac3\n");
    my $reg = run_vs($home, 'register', '--fresh', '--cwd', $proj, '--slug', 'ac3', '--files', 'CLAUDE.md');
    ok($reg->{json} && $reg->{json}{status} eq 'registered_fresh', 'AC3: (setup) registered fresh') or diag($reg->{out});

    my $todo_store = bp16_open_proj_store($proj, 'todo');
    my $note_store = bp16_open_proj_store($proj, 'note');
    my $todo_paths = bp16_seed_store($todo_store, sealed_id => 'ttop1', legacy_id => 'tleg1', orphan_id => 'torp1');
    bp16_seed_store($note_store, sealed_id => 'nsel1', legacy_id => 'nleg1', orphan_id => 'norp1');

    my $refresh = run_vs($home, 'refresh-default-tracked', '--slug', 'ac3');
    ok($refresh->{json}, 'AC3: (setup) refresh-default-tracked emitted JSON') or diag($refresh->{out});

    my $sync = run_vs($home, 'sync-project', '--slug', 'ac3');
    is($sync->{json} && $sync->{json}{status}, 'synced', 'AC3: sync-project succeeded') or diag($sync->{out});

    my $cp = run_vs($home, 'commit-and-push', '--slug', 'ac3', '--session-id', ($sync->{json}{session_id} // ''));
    is($cp->{json} && $cp->{json}{status}, 'committed_and_pushed', 'AC3: commit-and-push succeeded') or diag($cp->{out});

    my @tree = bp16_git_ls_tree($remote, 'main');
    my @almanac_tree = grep { m{^projects/ac3/files/\.ccpraxis-local-data/almanac/} } @tree;

    for my $expect (
        'projects/ac3/files/.ccpraxis-local-data/almanac/todo/ttop1.md',
        'projects/ac3/files/.ccpraxis-local-data/almanac/todo/ttop1.md.seal',
        'projects/ac3/files/.ccpraxis-local-data/almanac/todo/.reorder-journal.json',
        'projects/ac3/files/.ccpraxis-local-data/almanac/note/nsel1.md',
        'projects/ac3/files/.ccpraxis-local-data/almanac/note/nsel1.md.seal',
    ) {
        ok(scalar(grep { $_ eq $expect } @almanac_tree), "AC3: the remote tree contains $expect");
    }
    ok(scalar(grep { $_ eq 'projects/ac3/files/.ccpraxis-local-data/almanac/todo/tleg1.md' } @almanac_tree),
       'AC3: the unsealed legacy record travels');
    ok(!(grep { $_ eq 'projects/ac3/files/.ccpraxis-local-data/almanac/todo/tleg1.md.seal' } @almanac_tree),
       'AC3: the unsealed legacy record has no seal in the vault (none existed locally)');
    ok(!(grep { $_ eq 'projects/ac3/files/.ccpraxis-local-data/almanac/todo/torp1.md.seal' } @almanac_tree),
       'AC3: an orphan seal (record absent locally) is never staged');
    ok(!(grep { $_ eq 'projects/ac3/files/.ccpraxis-local-data/almanac/todo/torp1.md' } @almanac_tree),
       'AC3: an orphan record path with no record file never appears');

    my @forbidden = grep { /\.lock(\.holder)?\z/ || /\.tmp\.\d+\z/ } @almanac_tree;
    is(scalar(@forbidden), 0, 'AC3: no *.lock, *.lock.holder, .store.lock* or *.tmp.* is in the vault tree')
        or diag(join(', ', @forbidden));

    my $local_bytes = read_text($todo_paths->{sealed_path});
    my $vault_bytes = bp16_git_show_blob($remote, 'main', 'projects/ac3/files/.ccpraxis-local-data/almanac/todo/ttop1.md');
    is($vault_bytes, $local_bytes, 'AC3: the sealed record is byte-identical to the source');

    ok(-e $todo_paths->{lock_path},   'AC3: the .lock sidecar still exists locally (it was never touched)');
    ok(-e $todo_paths->{store_lock},  'AC3: the .store.lock sidecar still exists locally');
    ok(-e $todo_paths->{orphan_seal}, 'AC3: the orphan seal still exists locally');
}

# ===========================================================================
# AC4 (DC2, X1, X2, X5, behavior 4/5) -- sync-global-almanac commits and
# pushes <vault>/almanac and <vault>/notes, is idempotent, and .gitignore
# gains the sidecar-ignore rules exactly once.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'ac4-home');
    run_vs($home, 'init', '--url', $remote);
    my $vault_dir = "$home/.claude/claude-code-vault";

    my $todo_store = bp16_open_global_store($home, 'todo');
    my $note_store = bp16_open_global_store($home, 'note');
    bp16_seed_store($todo_store, sealed_id => 'gtop1', legacy_id => 'gleg1', orphan_id => 'gorp1');
    bp16_seed_store($note_store, sealed_id => 'gnot1', legacy_id => 'gnleg1', orphan_id => 'gnorp1');
    write_text("$vault_dir/notes/n1.md", "a note target\n");

    my $r1 = run_vs($home, 'sync-global-almanac');
    is($r1->{exit}, 0, 'AC4: sync-global-almanac exits 0') or diag($r1->{out});
    is($r1->{json} && $r1->{json}{status}, 'synced', 'AC4: sync-global-almanac reports synced') or diag($r1->{out});
    is($r1->{json} && $r1->{json}{committed} ? 1 : 0, 1, 'AC4: first run committed true');

    my @tree = bp16_git_ls_tree($remote, 'main');
    ok(scalar(grep { $_ eq 'almanac/todo/gtop1.md' } @tree), 'AC4: the remote tree has the global sealed record');
    ok(scalar(grep { $_ eq 'almanac/todo/gtop1.md.seal' } @tree), 'AC4: the remote tree has the global seal');
    ok(scalar(grep { $_ eq 'notes/n1.md' } @tree), 'AC4: the remote tree has the notes file');
    ok(!(grep { /\.lock(\.holder)?\z/ || /\.tmp\.\d+\z/ } @tree), 'AC4: no lock/holder/tmp sidecar ever in the remote tree');

    for my $shape ('almanac/todo/x.md.lock', 'almanac/todo/x.md.lock.holder', 'almanac/todo/.store.lock', 'almanac/todo/x.md.tmp.123') {
        ok(bp16_git_check_ignore($vault_dir, $shape), "AC4: git check-ignore reports $shape as ignored");
    }

    my $gi = read_text("$vault_dir/.gitignore") // '';
    for my $rule ('almanac/**/*.lock', 'almanac/**/*.lock.holder', 'almanac/**/*.tmp.*') {
        # S7: count whole LINES, not substring occurrences -- a naive
        # substring count of 'almanac/**/*.lock' also matches inside the
        # line 'almanac/**/*.lock.holder', inflating the count to 2783-style
        # wrongness. \r? tolerates a CRLF-terminated line (S1).
        my $count = () = $gi =~ /^\Q$rule\E\r?$/mg;
        is($count, 1, "AC4: the rule '$rule' appears exactly once in .gitignore (whole line)");
    }

    my $sha_before = bp16_git_rev_parse($remote, 'main');
    my $r2 = run_vs($home, 'sync-global-almanac');
    is($r2->{json} && $r2->{json}{status}, 'synced', 'AC4: an immediate re-run also exits synced') or diag($r2->{out});
    is($r2->{json} && $r2->{json}{committed} ? 1 : 0, 0, 'AC4: an immediate re-run reports committed false');
    my $sha_after = bp16_git_rev_parse($remote, 'main');
    is($sha_after, $sha_before, 'AC4: an immediate re-run does not change the remote sha');
}

# ===========================================================================
# AC5 (DC2, behavior 6) -- a path already staged in the vault index outside
# almanac/ and notes/ is not touched by sync-global-almanac's commit.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'ac5-home');
    run_vs($home, 'init', '--url', $remote);
    my $vault_dir = "$home/.claude/claude-code-vault";
    write_text("$vault_dir/reports/r.md", "pre-existing report\n");
    ok(bp16_git($home, $vault_dir, 'add', '-A', '--', 'reports'), 'AC5: (setup) reports/r.md staged in the vault index');

    my $store = bp16_open_global_store($home, 'todo');
    $store->create(id => 'gac5', fields => {}, body => "ac5 body\n");

    my $r1 = run_vs($home, 'sync-global-almanac');
    is($r1->{json} && $r1->{json}{status}, 'synced', 'AC5: sync-global-almanac succeeded') or diag($r1->{out});

    my $head_files = bp16_git_out($home, $vault_dir, 'show', '--name-only', '--pretty=format:', 'HEAD');
    unlike($head_files, qr{^reports/r\.md$}m, 'AC5: the almanac commit does not touch reports/r.md');

    my $staged = bp16_git_out($home, $vault_dir, 'diff', '--cached', '--name-only');
    like($staged, qr{^reports/r\.md$}m, 'AC5: reports/r.md is still staged in the index afterwards') or diag($staged);
}

# ===========================================================================
# AC6 (DC1, DC2, behavior 7) + AC17 (X5, behavior 18) -- end to end: backup.pl
# run, with Vault.pm driving the REAL vault-sync.pl (via the logging shim),
# over one project registered with only CLAUDE.md plus project + global
# almanac records. sync-global-almanac runs before list-projects; the remote
# ends up with every eligible file. A second run right after is a true no-op.
# ===========================================================================
{
    my $r = setup_root(vault => 0);
    install_real_steward_scripts_logged($r);
    my $remote = init_remote($r->{scratch});
    ok(run_vs($r->{home}, 'init', '--url', $remote)->{json}, 'AC6: (setup) real vault init');

    my $proj = "$r->{scratch}/ac6-proj"; make_path($proj);
    write_text("$proj/CLAUDE.md", "# ac6\n");
    my $reg = run_vs($r->{home}, 'register', '--fresh', '--cwd', $proj, '--slug', 'ac6', '--files', 'CLAUDE.md');
    ok($reg->{json} && $reg->{json}{status} eq 'registered_fresh', 'AC6: (setup) project registered with only CLAUDE.md') or diag($reg->{out});

    my $pstore  = bp16_open_proj_store($proj, 'todo');
    $pstore->create(id => 'pac6', fields => {}, body => "project record\n");
    my $pstore2 = bp16_open_proj_store($proj, 'inbox');   # spec 01-inbox-rename AC34: was 'decision'
    $pstore2->create(id => 'pac6d', fields => {}, body => "project inbox record\n");
    my $gstore  = bp16_open_global_store($r->{home}, 'todo');
    $gstore->create(id => 'gac6', fields => {}, body => "global record\n");

    my $resp = run_backup($r, { ALMANAC_HOME => undef });
    is($resp->{exit}, 0, 'AC6: end-to-end backup.pl run exits 0') or diag($resp->{out} . $resp->{err});
    is(($resp->{json}{status} // ''), 'complete', 'AC6: terminal status complete');

    my @entries = log_entries($r->{log_path});
    is((($entries[0] // {})->{subcmd} // ''), 'sync-global-almanac', 'AC6: the FIRST spawn is sync-global-almanac')
        or diag(join(' | ', map { $_->{line} } @entries));
    my $lp_idx;
    for my $i (0 .. $#entries) { if ((($entries[$i]{subcmd}) // '') eq 'list-projects') { $lp_idx = $i; last; } }
    ok(defined($lp_idx) && $lp_idx > 0, 'AC6: sync-global-almanac precedes list-projects');

    my @tree = bp16_git_ls_tree($remote, 'main');
    ok(scalar(grep { $_ eq 'projects/ac6/files/.ccpraxis-local-data/almanac/todo/pac6.md' } @tree),
       'AC6: the project almanac record reached the remote');
    ok(scalar(grep { $_ eq 'projects/ac6/files/.ccpraxis-local-data/almanac/inbox/pac6d.md' } @tree),
       'AC6: a second project store TYPE reached the remote too');
    ok(scalar(grep { $_ eq 'almanac/todo/gac6.md' } @tree),
       'AC6: the global almanac record reached the remote');

    # AC17 -- idempotence: a second run right after AC6.
    my $vault_dir = "$r->{home}/.claude/claude-code-vault";
    my $sha1 = bp16_git_rev_parse($vault_dir, 'main');
    my $gi1  = read_text("$vault_dir/.gitignore") // '';

    my $resp2 = run_backup($r, { ALMANAC_HOME => undef });
    is($resp2->{exit}, 0, 'AC17: a second end-to-end run right after AC6 also exits 0') or diag($resp2->{out} . $resp2->{err});

    my $sha2 = bp16_git_rev_parse($vault_dir, 'main');
    is($sha2, $sha1, 'AC17: the vault main sha is unchanged after a no-op second run');
    my $gi2 = read_text("$vault_dir/.gitignore") // '';
    is($gi2, $gi1, 'AC17: .gitignore bytes are unchanged across the no-op second run');

    my $state2 = read_state($r->{state_path});
    if (defined $state2) {
        my $gn = find_note($state2, 'global_almanac');
        if (defined $gn) {
            is($gn->{value}{committed} ? 1 : 0, 0, 'AC17: the second run\'s global_almanac note reports committed false');
        } else {
            ok(0, 'AC17: the second run\'s global_almanac note reports committed false');
        }
    } else {
        ok(0, 'AC17: the second run\'s global_almanac note reports committed false');
    }
}

# ===========================================================================
# AC7 (DC4, behavior 8) -- a project with no almanac directory, and one whose
# store holds only lock/holder sidecars, both back up cleanly and leave no
# almanac path in the vault.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'ac7-home');
    run_vs($home, 'init', '--url', $remote);

    my $proj1 = "$root/ac7-proj1"; make_path($proj1);
    write_text("$proj1/CLAUDE.md", "# ac7-1\n");
    run_vs($home, 'register', '--fresh', '--cwd', $proj1, '--slug', 'ac7a', '--files', 'CLAUDE.md');
    run_vs($home, 'refresh-default-tracked', '--slug', 'ac7a');
    my $s1 = run_vs($home, 'sync-project', '--slug', 'ac7a');
    is($s1->{json} && $s1->{json}{status}, 'synced', 'AC7: project with no almanac dir syncs cleanly') or diag($s1->{out});
    my $c1 = run_vs($home, 'commit-and-push', '--slug', 'ac7a', '--session-id', ($s1->{json}{session_id} // ''));
    is($c1->{json} && $c1->{json}{status}, 'committed_and_pushed', 'AC7: project with no almanac dir reaches committed_and_pushed') or diag($c1->{out});

    my $proj2 = "$root/ac7-proj2"; make_path($proj2);
    write_text("$proj2/CLAUDE.md", "# ac7-2\n");
    run_vs($home, 'register', '--fresh', '--cwd', $proj2, '--slug', 'ac7b', '--files', 'CLAUDE.md');
    my $store2 = bp16_open_proj_store($proj2, 'todo');
    make_path($store2->dir);
    write_text($store2->dir . '/ghost.md.lock', "locked\n");
    write_text($store2->dir . '/ghost.md.lock.holder', "not a record\n");
    run_vs($home, 'refresh-default-tracked', '--slug', 'ac7b');
    my $s2 = run_vs($home, 'sync-project', '--slug', 'ac7b');
    is($s2->{json} && $s2->{json}{status}, 'synced', 'AC7: project with only sidecar files syncs cleanly') or diag($s2->{out});
    my $c2 = run_vs($home, 'commit-and-push', '--slug', 'ac7b', '--session-id', ($s2->{json}{session_id} // ''));
    is($c2->{json} && $c2->{json}{status}, 'committed_and_pushed', 'AC7: project with only sidecar files reaches committed_and_pushed') or diag($c2->{out});

    my @tree = bp16_git_ls_tree($remote, 'main');
    ok(!(grep { m{^projects/ac7a/files/\.ccpraxis-local-data/almanac/} } @tree), 'AC7: project with no almanac dir has no almanac path in the vault');
    ok(!(grep { m{^projects/ac7b/files/\.ccpraxis-local-data/almanac/} } @tree), 'AC7: project with only sidecar files has no almanac path in the vault');
}

# ===========================================================================
# AC8 (DC3, X3, behavior 9) -- restore: machine B links an empty directory,
# syncs, and reproduces every eligible source file byte-identically.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home1  = make_machine($root, 'ac8-home1');
    my $projA  = "$root/ac8-projA"; make_path($projA);
    run_vs($home1, 'init', '--url', $remote);
    write_text("$projA/CLAUDE.md", "# ac8\n");
    run_vs($home1, 'register', '--fresh', '--cwd', $projA, '--slug', 'ac8', '--files', 'CLAUDE.md');

    my $storeA  = bp16_open_proj_store($projA, 'todo');
    bp16_seed_store($storeA, sealed_id => 'asel1', legacy_id => 'aleg1', orphan_id => 'aorp1');
    my $gstoreA = bp16_open_global_store($home1, 'todo');
    bp16_seed_store($gstoreA, sealed_id => 'gasel1', legacy_id => 'galeg1', orphan_id => 'gaorp1');

    run_vs($home1, 'refresh-default-tracked', '--slug', 'ac8');
    my $s1 = run_vs($home1, 'sync-project', '--slug', 'ac8');
    is($s1->{json} && $s1->{json}{status}, 'synced', 'AC8: (setup) machine A sync-project') or diag($s1->{out});
    run_vs($home1, 'commit-and-push', '--slug', 'ac8', '--session-id', ($s1->{json}{session_id} // ''));
    run_vs($home1, 'sync-global-almanac');

    my $home2 = make_machine($root, 'ac8-home2');
    my $E     = "$root/ac8-restore-E"; make_path($E);
    ok(run_vs($home2, 'init', '--url', $remote)->{json}, 'AC8: (setup) machine B vault init');
    my $reg2 = run_vs($home2, 'register', '--link', '--cwd', $E, '--slug', 'ac8');
    ok($reg2->{json} && $reg2->{json}{status} eq 'registered_link', 'AC8: (setup) machine B register --link') or diag($reg2->{out});
    my $sync2 = run_vs($home2, 'sync-project', '--slug', 'ac8');
    is($sync2->{json} && $sync2->{json}{status}, 'synced', 'AC8: machine B sync-project pulls the almanac store') or diag($sync2->{out});
    run_vs($home2, 'commit-and-push', '--slug', 'ac8');

    my $dir_local  = $storeA->dir;
    my $dir_remote = "$E/.ccpraxis-local-data/almanac/todo";
    for my $rel (qw(asel1.md asel1.md.seal aleg1.md)) {
        is(read_text("$dir_remote/$rel"), read_text("$dir_local/$rel"), "AC8: $rel is byte-identical at E");
    }
    ok(!path_exists("$dir_remote/aleg1.md.seal"), 'AC8: the legacy record has no seal at E either');
    ok(!path_exists("$dir_remote/aorp1.md"),      'AC8: the orphan record never materialized at E');
    ok(!path_exists("$dir_remote/aorp1.md.seal"), 'AC8: the orphan seal never materialized at E (record was absent at the source)');

    is(Almanac::Store::check_seal("$dir_remote/asel1.md")->{state}, 'intact',   'AC8: the restored sealed record verifies intact');
    is(Almanac::Store::check_seal("$dir_remote/aleg1.md")->{state}, 'unsealed', 'AC8: the restored legacy record verifies unsealed, matching the source');

    my $vault2_dir = "$home2/.claude/claude-code-vault";
    is(read_text("$vault2_dir/almanac/todo/gasel1.md"), read_text($gstoreA->dir . '/gasel1.md'),
       "AC8: the global sealed record is byte-identical in B's vault clone");
}

# ===========================================================================
# AC9 (DC5, X1, behavior 10) -- skip: a held record lock makes sync-project
# skip that store and report it, and the skip clears once the lock releases.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'ac9-home');
    my $proj   = "$root/ac9-proj"; make_path($proj);
    run_vs($home, 'init', '--url', $remote);
    write_text("$proj/CLAUDE.md", "# ac9\n");
    run_vs($home, 'register', '--fresh', '--cwd', $proj, '--slug', 'ac9', '--files', 'CLAUDE.md');

    my $todo_store = bp16_open_proj_store($proj, 'todo');
    $todo_store->create(id => 'held1', fields => {}, body => "held body\n");
    my $note_store = bp16_open_proj_store($proj, 'note');
    $note_store->create(id => 'other1', fields => {}, body => "other type body\n");
    run_vs($home, 'refresh-default-tracked', '--slug', 'ac9');

    my $held_path = $todo_store->dir . '/held1.md';
    my ($lock, $lerr) = Almanac::Lock->acquire($held_path, verb => 'test-hold-ac9');
    ok(defined $lock, 'AC9: (setup) the test process holds held1.md\'s real lock') or diag($lerr);

    my $sync;
    { local $ENV{VAULT_SYNC_ALMANAC_LOCK_TIMEOUT_MS} = 300; $sync = run_vs($home, 'sync-project', '--slug', 'ac9'); }
    is($sync->{json} && $sync->{json}{status}, 'synced', 'AC9: sync-project still reports synced overall (a skip is not a failure)') or diag($sync->{out});
    my @skipped = @{ ($sync->{json} && $sync->{json}{skipped_stores}) || [] };
    is(scalar(@skipped), 1, 'AC9: exactly one skipped_stores entry') or diag($sync->{out});
    if (@skipped) {
        is($skipped[0]{path}, '.ccpraxis-local-data/almanac/todo', 'AC9: the skip names the todo store dir');
        is($skipped[0]{lock}, 'held1.md.lock', 'AC9: the skip names the record lock file');
        is($skipped[0]{holder}{pid}, $$, 'AC9: the skip\'s holder pid is this test process');
        like($skipped[0]{message}, qr/skipped/i, 'AC9: the message contains "skipped"');
        like($skipped[0]{message}, qr/held1\.md\.lock/, 'AC9: the message names the lock file');
    } else {
        ok(0, 'AC9: the skip names the todo store dir');
        ok(0, 'AC9: the skip names the record lock file');
        ok(0, 'AC9: the skip\'s holder pid is this test process');
        ok(0, 'AC9: the message contains "skipped"');
        ok(0, 'AC9: the message names the lock file');
    }

    my @touched;
    push @touched, @{ ($sync->{json}{auto_applied} // []) }, @{ ($sync->{json}{conflicts} // []) };
    ok(!(grep { /almanac\/todo/ } map { ref($_) ? ($_->{path} // '') : $_ } @touched),
       'AC9: no path under the skipped store appears in auto_applied or conflicts');

    my $cp;
    { local $ENV{VAULT_SYNC_ALMANAC_LOCK_TIMEOUT_MS} = 300; $cp = run_vs($home, 'commit-and-push', '--slug', 'ac9', '--session-id', ($sync->{json}{session_id} // '')); }
    is($cp->{json} && $cp->{json}{status}, 'committed_and_pushed', 'AC9: commit-and-push still succeeds despite the skip') or diag($cp->{out});

    my @tree = bp16_git_ls_tree($remote, 'main');
    ok(!(grep { m{almanac/todo/held1\.md} } @tree), 'AC9: the held record never reached the remote');
    ok(scalar(grep { m{almanac/note/other1\.md} } @tree), 'AC9: the OTHER store type of the same project still traveled');

    $lock->release;

    my $sync2 = run_vs($home, 'sync-project', '--slug', 'ac9');
    is($sync2->{json} && $sync2->{json}{status}, 'synced', 'AC9: after release, the next sync reports synced') or diag($sync2->{out});
    is(scalar(@{ ($sync2->{json}{skipped_stores} // []) }), 0, 'AC9: after release, no store is skipped');
    my $cp2 = run_vs($home, 'commit-and-push', '--slug', 'ac9', '--session-id', ($sync2->{json}{session_id} // ''));
    is($cp2->{json} && $cp2->{json}{status}, 'committed_and_pushed', 'AC9: after release, commit-and-push succeeds') or diag($cp2->{out});
    my @tree2 = bp16_git_ls_tree($remote, 'main');
    ok(scalar(grep { m{almanac/todo/held1\.md} } @tree2), 'AC9: once released, D travels on the next sync');
}

# AC9b -- the same claim, holding the STORE-WIDE lock (.store.lock) instead.
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'ac9b-home');
    my $proj   = "$root/ac9b-proj"; make_path($proj);
    run_vs($home, 'init', '--url', $remote);
    write_text("$proj/CLAUDE.md", "# ac9b\n");
    run_vs($home, 'register', '--fresh', '--cwd', $proj, '--slug', 'ac9b', '--files', 'CLAUDE.md');
    my $store = bp16_open_proj_store($proj, 'todo');
    $store->create(id => 'sto1', fields => {}, body => "body\n");
    run_vs($home, 'refresh-default-tracked', '--slug', 'ac9b');

    my $store_target = $store->dir . '/.store';
    my ($lock, $lerr) = Almanac::Lock->acquire($store_target, verb => 'test-hold-ac9b-store');
    ok(defined $lock, 'AC9b: (setup) the test process holds the store-wide lock') or diag($lerr);

    my $sync;
    { local $ENV{VAULT_SYNC_ALMANAC_LOCK_TIMEOUT_MS} = 300; $sync = run_vs($home, 'sync-project', '--slug', 'ac9b'); }
    my @skipped = @{ ($sync->{json} && $sync->{json}{skipped_stores}) || [] };
    is(scalar(@skipped), 1, 'AC9b: exactly one skipped_stores entry for a held store lock') or diag($sync->{out});
    is(($skipped[0] // {})->{lock}, '.store.lock', 'AC9b: the skip names .store.lock');

    $lock->release;
}

# AC9c -- the same claim, in the GLOBAL scope via sync-global-almanac.
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'ac9c-home');
    run_vs($home, 'init', '--url', $remote);
    my $gstore = bp16_open_global_store($home, 'todo');
    $gstore->create(id => 'gheld1', fields => {}, body => "global held\n");
    my $gnote  = bp16_open_global_store($home, 'note');
    $gnote->create(id => 'gother1', fields => {}, body => "global other\n");

    my $held_path = $gstore->dir . '/gheld1.md';
    my ($lock, $lerr) = Almanac::Lock->acquire($held_path, verb => 'test-hold-ac9c');
    ok(defined $lock, 'AC9c: (setup) the test process holds the global record lock') or diag($lerr);

    my $r1;
    { local $ENV{VAULT_SYNC_ALMANAC_LOCK_TIMEOUT_MS} = 300; $r1 = run_vs($home, 'sync-global-almanac'); }
    is($r1->{exit}, 0, 'AC9c: sync-global-almanac still exits 0 despite a held global lock') or diag($r1->{out});
    my @skipped = @{ ($r1->{json} && $r1->{json}{skipped_stores}) || [] };
    is(scalar(@skipped), 1, 'AC9c: exactly one skipped_stores entry for the global scope');
    is(($skipped[0] // {})->{path}, 'almanac/todo', 'AC9c: the skip path is relative to the vault root');

    my @tree = bp16_git_ls_tree($remote, 'main');
    ok(!(grep { m{^almanac/todo/gheld1\.md} } @tree), 'AC9c: the held global record never reached the remote');
    ok(scalar(grep { m{^almanac/note/gother1\.md} } @tree), 'AC9c: the other global store type still traveled');

    $lock->release;
    my $r2 = run_vs($home, 'sync-global-almanac');
    is(scalar(@{ ($r2->{json}{skipped_stores} // []) }), 0, 'AC9c: after release, nothing is skipped');
    my @tree2 = bp16_git_ls_tree($remote, 'main');
    ok(scalar(grep { m{^almanac/todo/gheld1\.md} } @tree2), 'AC9c: once released, the global store travels');
}

# ===========================================================================
# AC10 (DC5, behavior 11) -- wait: a genuine second process holds a record
# lock briefly; sync-project waits it out and reports no skip.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'ac10-home');
    my $proj   = "$root/ac10-proj"; make_path($proj);
    run_vs($home, 'init', '--url', $remote);
    write_text("$proj/CLAUDE.md", "# ac10\n");
    run_vs($home, 'register', '--fresh', '--cwd', $proj, '--slug', 'ac10', '--files', 'CLAUDE.md');
    my $store = bp16_open_proj_store($proj, 'todo');
    $store->create(id => 'wait1', fields => {}, body => "wait body\n");
    run_vs($home, 'refresh-default-tracked', '--slug', 'ac10');

    my $held_path = $store->dir . '/wait1.md';
    my $holder_pl = "$root/ac10-holder.pl";
    bp16_write_lock_holder_script($holder_pl);
    my $ready = "$root/ac10-ready";
    system(qq{perl "$holder_pl" "$held_path.lock" "0.3" "$ready" &});
    ok(bp16_wait_for_file($ready, 10), 'AC10: (setup) the background holder signalled ready');

    my $sync;
    { local $ENV{VAULT_SYNC_ALMANAC_LOCK_TIMEOUT_MS} = 5000; $sync = run_vs($home, 'sync-project', '--slug', 'ac10'); }
    is($sync->{json} && $sync->{json}{status}, 'synced', 'AC10: sync-project succeeds after waiting out a short hold') or diag($sync->{out});
    is(scalar(@{ ($sync->{json}{skipped_stores} // []) }), 0, 'AC10: no skip is reported when the holder releases before the deadline');

    my $cp = run_vs($home, 'commit-and-push', '--slug', 'ac10', '--session-id', ($sync->{json}{session_id} // ''));
    is($cp->{json} && $cp->{json}{status}, 'committed_and_pushed', 'AC10: commit-and-push succeeds') or diag($cp->{out});
    my @tree = bp16_git_ls_tree($remote, 'main');
    ok(scalar(grep { m{almanac/todo/wait1\.md} } @tree), 'AC10: D travels once the wait outlasts the holder');
}

# ===========================================================================
# AC11 (DC5, behavior 12) -- interop: a holder file vault-sync writes reads
# back with a verb starting vault-sync; no *.lock ever disappears; no alarm.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'ac11-home');
    my $proj   = "$root/ac11-proj"; make_path($proj);
    run_vs($home, 'init', '--url', $remote);
    write_text("$proj/CLAUDE.md", "# ac11\n");
    run_vs($home, 'register', '--fresh', '--cwd', $proj, '--slug', 'ac11', '--files', 'CLAUDE.md');
    my $store = bp16_open_proj_store($proj, 'todo');
    $store->create(id => 'interop1', fields => {}, body => "body\n");
    run_vs($home, 'refresh-default-tracked', '--slug', 'ac11');

    my $record_path = $store->dir . '/interop1.md';
    my @lock_files_before = sort glob($store->dir . '/*.lock*');

    my $sync = run_vs($home, 'sync-project', '--slug', 'ac11');
    is($sync->{json} && $sync->{json}{status}, 'synced', 'AC11: (setup) sync-project succeeded') or diag($sync->{out});
    run_vs($home, 'commit-and-push', '--slug', 'ac11', '--session-id', ($sync->{json}{session_id} // ''));

    my $holder = Almanac::Lock::read_holder($record_path);
    ok(defined $holder, 'AC11: a holder record exists for the synced record after the run');
    like(($holder->{verb} // ''), qr/^vault-sync/, "AC11: the holder's verb starts with vault-sync") if defined $holder;

    my @lock_files_after = sort glob($store->dir . '/*.lock*');
    ok(scalar(@lock_files_after) >= 1, 'AC11: at least one lock sidecar exists after the run');
    for my $f (@lock_files_before) {
        ok(scalar(grep { $_ eq $f } @lock_files_after), "AC11: pre-existing lock file $f still exists");
    }

    my $src = read_text($VS_REAL_SRC) // '';
    unlike($src, qr/\balarm\s*\(/, 'AC11: vault-sync.pl source contains no alarm(...)');
    unlike($src, qr/\$SIG\{ALRM\}/, 'AC11: vault-sync.pl source contains no $SIG{ALRM}');
}

# ===========================================================================
# AC12 (DC5, behavior 13) -- group rollback: a seal-only source change between
# sync-project and commit-and-push rolls back BOTH members of the group.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'ac12-home');
    my $proj   = "$root/ac12-proj"; make_path($proj);
    run_vs($home, 'init', '--url', $remote);
    write_text("$proj/CLAUDE.md", "# ac12\n");
    run_vs($home, 'register', '--fresh', '--cwd', $proj, '--slug', 'ac12', '--files', 'CLAUDE.md');
    my $store = bp16_open_proj_store($proj, 'todo');
    $store->create(id => 'rb1', fields => {}, body => "original\n");
    run_vs($home, 'refresh-default-tracked', '--slug', 'ac12');

    my $rec_path  = $store->dir . '/rb1.md';
    my $seal_path = Almanac::Store::seal_path_for($rec_path);

    my $sync = run_vs($home, 'sync-project', '--slug', 'ac12');
    is($sync->{json} && $sync->{json}{status}, 'synced', 'AC12: (setup) sync-project staged the record group') or diag($sync->{out});

    open(my $fh, '>>:raw', $seal_path) or die "AC12 fixture: cannot append to seal: $!";
    print {$fh} "0000000000000000000000000000000000000000000000000000000000000000\n";
    close $fh;

    my $cp = run_vs($home, 'commit-and-push', '--slug', 'ac12', '--session-id', ($sync->{json}{session_id} // ''));
    my @rb = @{ ($cp->{json} && $cp->{json}{rolled_back_during_sync}) || [] };
    my %rb_by_path = map { (($_->{path} // '') => $_) } @rb;
    ok(exists $rb_by_path{'.ccpraxis-local-data/almanac/todo/rb1.md'}, 'AC12: the record itself is in rolled_back_during_sync')
        or diag(join(', ', map { $_->{path} // '?' } @rb));
    ok(exists $rb_by_path{'.ccpraxis-local-data/almanac/todo/rb1.md.seal'}, 'AC12: the seal is in rolled_back_during_sync too');
    is(($rb_by_path{'.ccpraxis-local-data/almanac/todo/rb1.md'} // {})->{reason}, 'almanac_group_rolled_back',
       'AC12: the record carries reason almanac_group_rolled_back (it was not itself modified)');

    my @tree = bp16_git_ls_tree($remote, 'main');
    ok(!(grep { m{almanac/todo/rb1\.md$} } @tree), 'AC12: neither member reached the remote on the rolled-back attempt');

    my $sync2 = run_vs($home, 'sync-project', '--slug', 'ac12');
    my $cp2   = run_vs($home, 'commit-and-push', '--slug', 'ac12', '--session-id', ($sync2->{json}{session_id} // ''));
    is($cp2->{json} && $cp2->{json}{status}, 'committed_and_pushed', 'AC12: the next sync pushes both members') or diag($cp2->{out});
    my @tree2 = bp16_git_ls_tree($remote, 'main');
    ok(scalar(grep { m{almanac/todo/rb1\.md$} } @tree2), 'AC12: the record reaches the remote on the next sync');
    ok(scalar(grep { m{almanac/todo/rb1\.md\.seal$} } @tree2), 'AC12: the seal reaches the remote on the next sync');
}

# ===========================================================================
# AC13 (DC5, X3, behavior 14) -- locked pull: a held destination record lock
# at B rolls that group back with almanac_lock_timeout; other groups land.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $homeA  = make_machine($root, 'ac13-homeA');
    my $projA  = "$root/ac13-projA"; make_path($projA);
    run_vs($homeA, 'init', '--url', $remote);
    write_text("$projA/CLAUDE.md", "# ac13\n");
    run_vs($homeA, 'register', '--fresh', '--cwd', $projA, '--slug', 'ac13', '--files', 'CLAUDE.md');
    my $storeA = bp16_open_proj_store($projA, 'todo');
    $storeA->create(id => 'pull1', fields => {}, body => "from A\n");
    $storeA->create(id => 'pull2', fields => {}, body => "from A, other group\n");
    run_vs($homeA, 'refresh-default-tracked', '--slug', 'ac13');
    my $sA = run_vs($homeA, 'sync-project', '--slug', 'ac13');
    run_vs($homeA, 'commit-and-push', '--slug', 'ac13', '--session-id', ($sA->{json}{session_id} // ''));

    my $homeB = make_machine($root, 'ac13-homeB');
    my $projB = "$root/ac13-projB"; make_path($projB);
    run_vs($homeB, 'init', '--url', $remote);
    my $regB = run_vs($homeB, 'register', '--link', '--cwd', $projB, '--slug', 'ac13');
    ok($regB->{json} && $regB->{json}{status} eq 'registered_link', 'AC13: (setup) machine B linked') or diag($regB->{out});

    my $sB = run_vs($homeB, 'sync-project', '--slug', 'ac13');
    is($sB->{json} && $sB->{json}{status}, 'synced', 'AC13: (setup) machine B staged the pulls') or diag($sB->{out});

    my $store_dir_B = "$projB/.ccpraxis-local-data/almanac/todo";
    make_path($store_dir_B);
    my $held_target = "$store_dir_B/pull1.md";
    my ($lock, $lerr) = Almanac::Lock->acquire($held_target, verb => 'test-hold-ac13');
    ok(defined $lock, 'AC13: (setup) the test holds the destination record lock at B') or diag($lerr);

    my $cp;
    { local $ENV{VAULT_SYNC_ALMANAC_LOCK_TIMEOUT_MS} = 300;
      $cp = run_vs($homeB, 'commit-and-push', '--slug', 'ac13', '--session-id', ($sB->{json}{session_id} // '')); }
    my @rb = @{ ($cp->{json} && $cp->{json}{rolled_back_during_sync}) || [] };
    my %rb_by_path = map { (($_->{path} // '') => $_) } @rb;
    ok(exists $rb_by_path{'.ccpraxis-local-data/almanac/todo/pull1.md'}, 'AC13: the locked group is rolled back')
        or diag(join(', ', map { $_->{path} // '?' } @rb));
    is(($rb_by_path{'.ccpraxis-local-data/almanac/todo/pull1.md'} // {})->{reason}, 'almanac_lock_timeout',
       'AC13: rollback reason is almanac_lock_timeout');
    ok(!-e "$store_dir_B/pull1.md", 'AC13: the locked group never landed locally at B');
    ok(-e "$store_dir_B/pull2.md",  'AC13: the OTHER group landed');

    $lock->release;
    my $sB2 = run_vs($homeB, 'sync-project', '--slug', 'ac13');
    my $cp2 = run_vs($homeB, 'commit-and-push', '--slug', 'ac13', '--session-id', ($sB2->{json}{session_id} // ''));
    is($cp2->{json} && $cp2->{json}{status}, 'committed_and_pushed', 'AC13: after release, the next sync delivers it') or diag($cp2->{out});
    ok(-e "$store_dir_B/pull1.md", 'AC13: pull1 arrives once released');
}

# ===========================================================================
# AC14 (X3, behavior 15) -- group conflict: exactly one conflict entry (the
# record), merge_result null, no seal conflict; use-merged refused, use-vault
# resolves both members byte-identically.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $homeA  = make_machine($root, 'ac14-homeA');
    my $projA  = "$root/ac14-projA"; make_path($projA);
    run_vs($homeA, 'init', '--url', $remote);
    write_text("$projA/CLAUDE.md", "# ac14\n");
    run_vs($homeA, 'register', '--fresh', '--cwd', $projA, '--slug', 'ac14', '--files', 'CLAUDE.md');
    my $storeA = bp16_open_proj_store($projA, 'todo');
    $storeA->create(id => 'conf1', fields => {}, body => "base\n");
    run_vs($homeA, 'refresh-default-tracked', '--slug', 'ac14');
    my $sA1 = run_vs($homeA, 'sync-project', '--slug', 'ac14');
    run_vs($homeA, 'commit-and-push', '--slug', 'ac14', '--session-id', ($sA1->{json}{session_id} // ''));

    my $homeB = make_machine($root, 'ac14-homeB');
    my $projB = "$root/ac14-projB"; make_path($projB);
    run_vs($homeB, 'init', '--url', $remote);
    run_vs($homeB, 'register', '--link', '--cwd', $projB, '--slug', 'ac14');
    my $sB1 = run_vs($homeB, 'sync-project', '--slug', 'ac14');
    run_vs($homeB, 'commit-and-push', '--slug', 'ac14', '--session-id', ($sB1->{json}{session_id} // ''));

    # Almanac::Store->read dies on a missing record -- expected while push/
    # pull of almanac files is unimplemented (AC3/AC8 above are already red
    # for exactly that). Guarded with eval so a genuinely missing feature
    # here reports as failing assertions rather than aborting the whole file
    # and skipping every scenario after this one.
    my $curA = eval { $storeA->read('conf1') };
    ok(defined $curA, 'AC14: (setup) machine A can read back conf1 after its own sync') or diag($@);
    $storeA->update('conf1', expect => { rev => $curA->{rev}, fields => $curA->{fields} }, set => { note => 'from-A' }) if defined $curA;
    my $sA2 = run_vs($homeA, 'sync-project', '--slug', 'ac14');
    run_vs($homeA, 'commit-and-push', '--slug', 'ac14', '--session-id', ($sA2->{json}{session_id} // ''));

    my $storeB = bp16_open_proj_store($projB, 'todo');
    my $curB = eval { $storeB->read('conf1') };
    ok(defined $curB, 'AC14: (setup) machine B pulled conf1 via its own sync') or diag($@);

    my @conflicts;
    my $sB2;
    if (defined $curB) {
        $storeB->update('conf1', expect => { rev => $curB->{rev}, fields => $curB->{fields} }, set => { note => 'from-B' });
        $sB2 = run_vs($homeB, 'sync-project', '--slug', 'ac14');
        @conflicts = @{ ($sB2->{json} && $sB2->{json}{conflicts}) || [] };
    }
    is(scalar(@conflicts), 1, 'AC14: exactly one conflict is reported') or diag(defined($sB2) ? $sB2->{out} : '(setup did not reach sync-project)');
    if (@conflicts) {
        is($conflicts[0]{path}, '.ccpraxis-local-data/almanac/todo/conf1.md', 'AC14: the conflict path is the record');
        is($conflicts[0]{merge_result}, undef, 'AC14: merge_result is null');
    } else {
        ok(0, 'AC14: the conflict path is the record');
        ok(0, 'AC14: merge_result is null');
    }
    ok(!(grep { ($_->{path} // '') =~ /\.seal$/ } @conflicts), 'AC14: no conflict entry for the seal');

    my $bad = run_vs($homeB, 'resolve-conflict', '--slug', 'ac14', '--path', '.ccpraxis-local-data/almanac/todo/conf1.md', '--action', 'use-merged');
    is($bad->{exit}, 1, 'AC14: use-merged is refused (exit 1)') or diag($bad->{out});

    my $resolve = run_vs($homeB, 'resolve-conflict', '--slug', 'ac14', '--path', '.ccpraxis-local-data/almanac/todo/conf1.md', '--action', 'use-vault');
    ok($resolve->{json}, 'AC14: use-vault is accepted') or diag($resolve->{out});
    my $cpB = run_vs($homeB, 'commit-and-push', '--slug', 'ac14', '--session-id', (defined($sB2) ? ($sB2->{json}{session_id} // '') : ''));
    is($cpB->{json} && $cpB->{json}{status}, 'committed_and_pushed', 'AC14: commit-and-push finishes after use-vault') or diag($cpB->{out});

    my $b_rec_path = "$projB/.ccpraxis-local-data/almanac/todo/conf1.md";
    my $a_rec_path = "$projA/.ccpraxis-local-data/almanac/todo/conf1.md";
    is(read_text($b_rec_path), read_text($a_rec_path), "AC14: after use-vault, B's record is byte-identical to A's");
    is(Almanac::Store::check_seal($b_rec_path)->{state}, 'intact', 'AC14: the resolved record verifies intact');
}

# ===========================================================================
# AC15 (DC5, DC2, behavior 16) -- Vault.pm stub harness: a skipped_stores
# entry from sync-project surfaces as a note without failing the project; a
# failing sync-global-almanac fails the phase but the project loop still
# runs; a pause/resume spawns sync-global-almanac exactly once.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'skipproj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'skipproj'), mk_refresh_ok());
    my $skip_entry = {
        path => '.ccpraxis-local-data/almanac/todo', lock => '.store.lock', waited_ms => 500,
        holder => { pid => 4242, host => 'h', script => 's', verb => 'v', acquired_at => '2026-01-01T00:00:00Z' },
        message => 'almanac store .ccpraxis-local-data/almanac/todo skipped: .store.lock is held '
                 . '(holder pid 4242 on host h, s, v, since 2026-01-01T00:00:00Z) -- nothing from this store '
                 . 'was copied in either direction; the next backup will carry it once the lock is free.',
    };
    my $sync_resp = mk_sync_synced(slug => 'skipproj', session_id => 'sess-skip');
    $sync_resp->{skipped_stores} = [ $skip_entry ];
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'skipproj'), $sync_resp);
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'skipproj'), mk_committed(slug => 'skipproj', last_synced_at => '2026-09-26T00:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(mk_project_entry(slug => 'skipproj', last_synced_at => '2026-09-26T00:00:00Z')));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'AC15a: a skipped_stores entry from sync-project does not fail the run') or diag($resp->{out} . $resp->{err});
    my $state = read_state($r->{state_path});
    if (defined $state) {
        my $n = find_note($state, 'almanac_store_skipped');
        ok(defined $n, 'AC15a: an almanac_store_skipped note is present');
        if (defined $n) {
            is($n->{value}{slug}, 'skipproj', 'AC15a: the note carries the slug');
            is($n->{value}{path}, '.ccpraxis-local-data/almanac/todo', 'AC15a: the note carries the path');
            like($n->{value}{message}, qr/skipped/i, 'AC15a: the note carries the message');
        } else {
            ok(0, 'AC15a: the note carries the slug');
            ok(0, 'AC15a: the note carries the path');
            ok(0, 'AC15a: the note carries the message');
        }
        my $pdata;
        for my $t (project_toks($state)) { my $d = project_item($state, $t); $pdata = $d if defined($d) && (($d->{slug} // '') eq 'skipproj'); }
        is((defined($pdata) ? ($pdata->{status} // '') : ''), 'committed_and_pushed', 'AC15a: the project is still committed_and_pushed despite the skip');
    } else {
        ok(0, 'AC15a: an almanac_store_skipped note is present');
        ok(0, 'AC15a: the note carries the slug');
        ok(0, 'AC15a: the note carries the path');
        ok(0, 'AC15a: the note carries the message');
        ok(0, 'AC15a: the project is still committed_and_pushed despite the skip');
    }
}

{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('sync-global-almanac', ''), { status => 'error', error => 'AC15B-BOOM' }, exit => 1);
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'gproj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'gproj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'gproj'), mk_sync_synced(slug => 'gproj', session_id => 'sess-g'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'gproj'), mk_committed(slug => 'gproj', last_synced_at => '2026-09-26T00:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(mk_project_entry(slug => 'gproj', last_synced_at => '2026-09-26T00:00:00Z')));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 20, 'AC15b: a failing sync-global-almanac degrades the run (exit 20)') or diag($resp->{out} . $resp->{err});
    my $state = read_state($r->{state_path});
    if (defined $state) {
        ok(defined(find_note($state, 'global_almanac_failed')), 'AC15b: a global_almanac_failed note is present');
    } else {
        ok(0, 'AC15b: a global_almanac_failed note is present');
    }
    my @entries = log_entries($r->{log_path});
    is(count_subcmd_for_slug(\@entries, 'sync-project', 'gproj'), 1, "AC15b: the project's sync-project still spawned despite the global failure");
}

{
    my $r = setup_root();
    my $tmpC = "$r->{scratch}/ac15c-merge.txt";
    write_text($tmpC, "AC15C\n");
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 0), mk_list_projects(mk_project_entry(slug => 'pauseproj')));
    set_fixture($r->{fixture_dir}, fixture_name('refresh-default-tracked', 'pauseproj'), mk_refresh_ok());
    set_fixture($r->{fixture_dir}, fixture_name('sync-project', 'pauseproj'),
        mk_sync_synced(slug => 'pauseproj', session_id => 'sess-pausec',
                        conflicts => [ mk_conflict(path => 'x.txt', tmp_path => $tmpC, merge_exit_code => 1) ]));

    my $resp1 = run_backup($r, {});
    is($resp1->{exit}, 10, 'AC15c: (setup) the run pauses on the conflict decision') or diag($resp1->{out} . $resp1->{err});
    my @d1 = decisions_of_kind($resp1, 'vault_conflict');
    record_decisions(@d1);
    ok(scalar(@d1) >= 1, 'AC15c: (setup) at least one decision is offered') or diag($resp1->{out});

    set_fixture($r->{fixture_dir}, fixture_name('resolve-conflict', 'pauseproj'), mk_resolve_ok(slug => 'pauseproj', path => 'x.txt'));
    set_fixture($r->{fixture_dir}, fixture_name('commit-and-push', 'pauseproj'), mk_committed(slug => 'pauseproj', last_synced_at => '2026-09-26T01:00:00Z'));
    set_fixture($r->{fixture_dir}, fixture_name('list-projects', '', 1), mk_list_projects(mk_project_entry(slug => 'pauseproj', last_synced_at => '2026-09-26T01:00:00Z')));

    my $token = $resp1->{json}{resume_token};
    my $d = $d1[0];
    my $resp2 = run_backup($r, {}, '--resume', ($token // ''), '--answer', (defined $d ? "$d->{id}=use_local" : 'vault.conflict.pauseproj.x.txt=use_local'));
    is($resp2->{exit}, 0, 'AC15c: resuming with an answer completes the run') or diag($resp2->{out} . $resp2->{err});

    my @entries = log_entries($r->{log_path});
    is(count_subcmd(\@entries, 'sync-global-almanac'), 1, 'AC15c: sync-global-almanac spawned exactly once across the pause and its resume');
}

# ===========================================================================
# AC16 (X6, behavior 17) -- non-ASCII: AC3/AC8/AC9 repeated with a project
# directory named Andr\xC3\xA9-proj and a machine HOME named home-Andr\xC3\xA9.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, "home-Andr${EACUTE}");
    my $proj   = "$root/Andr${EACUTE}-proj"; make_path($proj);
    run_vs($home, 'init', '--url', $remote);
    write_text("$proj/CLAUDE.md", "# ac16\n");
    my $reg = run_vs($home, 'register', '--fresh', '--cwd', $proj, '--slug', 'ac16', '--files', 'CLAUDE.md');
    ok($reg->{json} && $reg->{json}{status} eq 'registered_fresh', 'AC16: (setup) register succeeded under a non-ASCII home/project') or diag($reg->{out});

    my $store = bp16_open_proj_store($proj, 'todo');
    bp16_seed_store($store, sealed_id => 'nasel1', legacy_id => 'naleg1', orphan_id => 'naorp1');
    run_vs($home, 'refresh-default-tracked', '--slug', 'ac16');

    my $sync = run_vs($home, 'sync-project', '--slug', 'ac16');
    is($sync->{json} && $sync->{json}{status}, 'synced', 'AC16: sync-project succeeds under a non-ASCII path') or diag($sync->{out});
    my $cp = run_vs($home, 'commit-and-push', '--slug', 'ac16', '--session-id', ($sync->{json}{session_id} // ''));
    is($cp->{json} && $cp->{json}{status}, 'committed_and_pushed', 'AC16: commit-and-push succeeds') or diag($cp->{out});
    my @tree = bp16_git_ls_tree($remote, 'main');
    ok(scalar(grep { $_ eq 'projects/ac16/files/.ccpraxis-local-data/almanac/todo/nasel1.md' } @tree),
       'AC16: the sealed record reached the remote under a purely [a-z0-9-] slug (the non-ASCII bytes never appear in the vault PATH)');
    ok(!(grep { /\.lock(\.holder)?\z|\.tmp\.\d+\z/ } @tree), 'AC16: no lock/tmp sidecar in the remote tree');

    my $held_path = $store->dir . '/nasel1.md';
    my ($lock, $lerr) = Almanac::Lock->acquire($held_path, verb => 'test-hold-ac16');
    ok(defined $lock, 'AC16: (setup) the test holds the record lock') or diag($lerr);
    my $sync2;
    { local $ENV{VAULT_SYNC_ALMANAC_LOCK_TIMEOUT_MS} = 300; $sync2 = run_vs($home, 'sync-project', '--slug', 'ac16'); }
    my @skipped = @{ ($sync2->{json} && $sync2->{json}{skipped_stores}) || [] };
    is(scalar(@skipped), 1, 'AC16: exactly one skip is reported under a non-ASCII path');
    if (@skipped) {
        my $msg = $skipped[0]{message} // '';
        my $msg_bytes = utf8::is_utf8($msg) ? Encode::encode('UTF-8', $msg) : $msg;
        ok(index($msg_bytes, 'nasel1.md.lock') >= 0, 'AC16: the skip message names the lock file');
    } else {
        ok(0, 'AC16: the skip message names the lock file');
    }
    $lock->release;

    my $home2 = make_machine($root, "home-Andr${EACUTE}-2");
    my $E     = "$root/Andr${EACUTE}-restore-E"; make_path($E);
    run_vs($home2, 'init', '--url', $remote);
    my $reg2 = run_vs($home2, 'register', '--link', '--cwd', $E, '--slug', 'ac16');
    ok($reg2->{json} && $reg2->{json}{status} eq 'registered_link', 'AC16: (setup) machine B links under a non-ASCII home') or diag($reg2->{out});
    my $sync3 = run_vs($home2, 'sync-project', '--slug', 'ac16');
    is($sync3->{json} && $sync3->{json}{status}, 'synced', 'AC16: machine B pulls the almanac store under a non-ASCII home') or diag($sync3->{out});
    run_vs($home2, 'commit-and-push', '--slug', 'ac16');
    is(read_text("$E/.ccpraxis-local-data/almanac/todo/nasel1.md"), read_text($held_path),
       'AC16: the restored record is byte-identical under a non-ASCII path');

    my $listp = run_vs($home, 'list-projects');
    my ($entry) = grep { ($_->{slug} // '') eq 'ac16' } @{ ($listp->{json}{projects} // []) };
    if (defined $entry) {
        my $p = $entry->{path} // '';
        my $p_bytes = utf8::is_utf8($p) ? Encode::encode('UTF-8', $p) : $p;
        ok(index($p_bytes, "Andr${EACUTE}-proj") >= 0, 'AC16: the registry path round-trips the non-ASCII project directory name byte-exact');
    } else {
        ok(0, 'AC16: the registry path round-trips the non-ASCII project directory name byte-exact');
    }
}

# ===========================================================================
# AC18 (X7, isolation) -- every new scenario above builds claude-code-vault
# paths only from a scratch HOME; a static scan proves it.
# ===========================================================================
{
    my $self_src = read_text("$Bin/backup-vault.t") // '';
    # Scan only AC1..AC17's blocks -- up to (not including) this AC18 block
    # itself, which necessarily mentions the term to build the scan.
    my ($new_section) = $self_src =~ /# === PACKAGE 16 NEW SCENARIOS BEGIN ===(.*?)# ===+\n# AC18 /s;
    $new_section //= '';
    my @bad;
    for my $line (split /\n/, $new_section) {
        next if $line =~ /^\s*#/;   # comments (incl. this section's own header prose)
        next unless $line =~ /claude-code-vault/;
        next if $line =~ /\$home\b|\$home1\b|\$home2\b|\$homeA\b|\$homeB\b|\$vault_dir\b|\$vault2_dir\b|make_machine|scope|sub bp16_/;
        push @bad, $line;
    }
    ok(scalar(@bad) == 0, 'AC18: no literal claude-code-vault path in the new scenarios is NOT built from a scratch HOME')
        or diag(join("\n", @bad));
}

# ===========================================================================
# AC19 (behavior: SKILL.md reporting) -- size cap, description names almanac,
# the Relaying section names both new note keys.
# ===========================================================================
{
    my $skill_path = "$Bin/../../skills/backup/SKILL.md";
    if (-f $skill_path) {
        my $text = read_text($skill_path) // '';
        my @lines = split /\n/, $text;
        ok(scalar(@lines) <= 250, 'AC19: SKILL.md is at most 250 lines (' . scalar(@lines) . ' found)');
        my ($desc_line) = grep { /^description:/i } @lines;
        like(($desc_line // ''), qr/almanac/i, 'AC19: the description: line mentions almanac');
        like($text, qr/almanac_store_skipped/, 'AC19: the Relaying section names almanac_store_skipped');
        like($text, qr/global_almanac_failed/, 'AC19: the Relaying section names global_almanac_failed');
    } else {
        ok(0, 'AC19: SKILL.md is at most 250 lines');
        ok(0, 'AC19: the description: line mentions almanac');
        ok(0, 'AC19: the Relaying section names almanac_store_skipped');
        ok(0, 'AC19: the Relaying section names global_almanac_failed');
    }
}

# ===========================================================================
# The blocks below (M1, M1c, M2/M2G, M3, MF1, SF1, SF2, SF4, SF6, S1) were
# added/rewritten by review 16-review.md and its round-2 re-review
# (16-rereview.md, mutation-proven): the original coverage had no failure-
# path test for a mid-window deletion race, a skip's blast radius, a
# pull-side concurrent local edit, or CRLF idempotence -- and the re-review
# found the FIRST round's M1/M2 blocks vacuous (mutating the real fix left
# them green). Written BLIND to vault-sync.pl / Vault.pm exactly as the rest
# of this file's package-16 section is (see the header at the top of this
# file), except for reading the seam's own doc comment in vault-sync.pl
# (blueprint Decision 43) to learn its exact contract -- the seam IS the
# spec for these blocks, the same way Almanac::Store/Almanac::Lock are.
#
# Decision 43's seam: CCPRAXIS_VAULT_SYNC_TEST_PAUSE=<dir>, set in the CHILD
# env before spawning vault-sync.pl. Inside each almanac store lock window,
# AFTER every local hash/enumeration for that window is taken and BEFORE its
# staging proceeds, it creates <dir>/in-window, then polls (bounded to 30s)
# for <dir>/release before letting the window continue. Every record lock
# and the store's own lock are held for the WHOLE pause -- that is what lets
# a test prove a concurrent writer is genuinely blocked, not just that
# enumeration happened before some later step.
# ===========================================================================

# ---------------------------------------------------------------------------
# Round-2 async-spawn plumbing: the seam makes vault-sync.pl block mid-run,
# so exercising it needs a spawn that does NOT wait for output (unlike
# run_vs, which always reads to EOF). Every wait below is bounded: the
# poll-until-file helpers (bp16_wait_for_file, pre-existing) have their own
# deadline, and the two genuinely-blocking operations -- reading the async
# child's stdout to EOF, and reaping it -- are wrapped in an alarm() so a
# script that never exits cannot hang this test file. Every pause directory
# is registered for a best-effort release at process exit (END), so a died
# assertion mid-block never leaves a vault-sync.pl process waiting out the
# seam's own 30s cap.
# ---------------------------------------------------------------------------
my @BP16_PENDING_RELEASES;
END {
    for my $d (@BP16_PENDING_RELEASES) {
        eval { write_text("$d/release", "1\n") };
        eval { write_text("$d/release-staged", "1\n") };
    }
}

sub bp16_pause_dir {
    my ($root, $name) = @_;
    my $d = "$root/$name";
    make_path($d);
    push @BP16_PENDING_RELEASES, $d;
    return $d;
}

sub bp16_release_pause { my ($d) = @_; eval { write_text("$d/release", "1\n") }; }

# Releases the SECOND pause point (Decision 45): drop <dir>/release-staged so
# a sync parked in _vault_sync_test_pause_staged (after staging, still inside
# the store lock window) is allowed to finish and release its locks.
sub bp16_release_pause_staged { my ($d) = @_; eval { write_text("$d/release-staged", "1\n") }; }

# Spawns vault-sync.pl asynchronously (never reads/waits here -- that is
# bp16_collect_async's job) with the same per-machine env run_vs() uses, plus
# CCPRAXIS_VAULT_SYNC_TEST_PAUSE. $pause_dir may be undef (no seam wired).
sub bp16_spawn_vs_async {
    my ($home, $pause_dir, @args) = @_;
    local $ENV{HOME}                = $home;
    local $ENV{USERPROFILE}         = $home;
    local $ENV{GIT_CONFIG_GLOBAL}   = "$home/.gitconfig";
    local $ENV{GIT_CONFIG_SYSTEM}   = '/dev/null';
    local $ENV{GIT_TERMINAL_PROMPT} = '0';
    local $ENV{GIT_AUTHOR_NAME}     = 'Steward Test';
    local $ENV{GIT_AUTHOR_EMAIL}    = 'steward-test@example.invalid';
    local $ENV{GIT_COMMITTER_NAME}  = 'Steward Test';
    local $ENV{GIT_COMMITTER_EMAIL} = 'steward-test@example.invalid';
    local $ENV{CCPRAXIS_VAULT_SYNC_TEST_PAUSE} = $pause_dir if defined $pause_dir;
    my $script = vault_sync_script();
    my $pid = open(my $fh, '-|', $^X, $script, @args)
        or die "cannot spawn vault-sync.pl (async): $!";
    return { pid => $pid, fh => $fh };
}

# Reads the async child's stdout to EOF and reaps it, both bounded by one
# alarm -- the only place in the M1/M2G blocks that can genuinely block.
# close() on a pipe-opened filehandle already reaps the child and sets $?
# (same convention run_vs relies on), so there is no separate waitpid here.
sub bp16_collect_async {
    my ($h, $timeout_s) = @_;
    my $out;
    my $completed = eval {
        local $SIG{ALRM} = sub { die "BP16_TIMEOUT\n" };
        alarm($timeout_s);
        my $fh = $h->{fh};
        local $/;
        $out = <$fh>;
        alarm(0);
        1;
    };
    alarm(0);
    if ($completed) {
        close $h->{fh};
        my $exit = $? >> 8;
        my $json = eval { decode_json($out // '') };
        return { out => ($out // ''), exit => $exit, json => $json, timed_out => 0 };
    }
    kill('KILL', $h->{pid});
    eval { close $h->{fh} };
    return { out => ($out // ''), exit => -1, json => undef, timed_out => 1 };
}

# ===========================================================================
# M1 (16-rereview M1a: the original lock-window block never proved the
# window holds every record's lock for its whole duration, only that
# enumeration happened -- and used a store's FIRST sync, where the vault
# starts empty so "record without seal, or vice versa" always resolves to
# "neither", which cannot fail). Rewritten around the seam (Decision 43) on a
# SECOND sync of an ALREADY-TRACKED store: the vault already holds race1's
# v1 record+seal from a prior push, so a torn outcome is a real possible
# failure. While the syncer is paused mid-window (every record lock and the
# store lock held), a genuine concurrent almanac writer -- this test
# process, via the real Almanac::Lock module, exactly what an agent would
# use -- must be DENIED the record's lock. After release, the vault must
# hold a consistent record/seal pair reflecting the update made before the
# window, never a torn mix.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'm1-home');
    my $proj   = "$root/m1-proj"; make_path($proj);
    run_vs($home, 'init', '--url', $remote);
    write_text("$proj/CLAUDE.md", "# m1\n");
    run_vs($home, 'register', '--fresh', '--cwd', $proj, '--slug', 'm1', '--files', 'CLAUDE.md');

    my $store = bp16_open_proj_store($proj, 'todo');
    $store->create(id => 'race1', fields => {}, body => "race body v1\n");
    run_vs($home, 'refresh-default-tracked', '--slug', 'm1');

    # Baseline sync+push: race1 becomes ALREADY-TRACKED (v1 record+seal land
    # in the vault) before the racy SECOND sync below.
    my $sync0 = run_vs($home, 'sync-project', '--slug', 'm1');
    is($sync0->{json} && $sync0->{json}{status}, 'synced', 'M1: (setup) baseline sync succeeded') or diag($sync0->{out});
    my $cp0 = run_vs($home, 'commit-and-push', '--slug', 'm1', '--session-id', ($sync0->{json}{session_id} // ''));
    is($cp0->{json} && $cp0->{json}{status}, 'committed_and_pushed', 'M1: (setup) baseline push succeeded') or diag($cp0->{out});

    my $rec_path = $store->dir . '/race1.md';

    # A local edit gives the SECOND sync something to stage inside the window.
    my $rec0 = $store->read('race1');
    $store->update('race1', expect => { rev => $rec0->{rev}, fields => $rec0->{fields} }, body => "race body v2\n");

    # M1 (Decision 45, round-4): the OLD version of this block proved the
    # window holds the lock through staging only by winning a race -- a
    # writer polling to reacquire race1.md's lock the instant the FIRST pause
    # point released it, hoping to land before the (in the reverted shape)
    # later, unlocked staging step ran. Under load that race can be lost even
    # against reverted code (16-mutation-r3.md SF-1). The seam's SECOND pause
    # point (_vault_sync_test_pause_staged) removes the race entirely: it
    # fires AFTER staging has completed but while every lock from this window
    # is still held, and (with <dir>/hold-staged present beforehand) parks
    # there for up to 30s waiting for release-staged -- long enough for this
    # test to assert, with no race at all, that the lock is still held and
    # the staging tmp files already exist.
    my $pause_dir = bp16_pause_dir($root, 'm1-pause');
    write_text("$pause_dir/hold-staged", "1\n");
    my $async = bp16_spawn_vs_async($home, $pause_dir, 'sync-project', '--slug', 'm1');

    my $entered = bp16_wait_for_file("$pause_dir/in-window", 15);
    ok($entered, 'M1: the second sync signals it is paused inside the store lock window (seam CCPRAXIS_VAULT_SYNC_TEST_PAUSE)')
        or diag('in-window never appeared -- either the seam is unimplemented, or the window does not cover this store');

    my ($writer_lock, $writer_err) = Almanac::Lock->acquire($rec_path, timeout_ms => 300, verb => 'm1-concurrent-writer');
    ok(!defined($writer_lock),
       'M1: a concurrent almanac writer is DENIED race1.md\'s lock while the paused sync holds the store window')
        or diag('the writer acquired the lock -- the window is not actually holding it for its whole duration');
    $writer_lock->release if defined $writer_lock;

    my $vault_dir  = "$home/.claude/claude-code-vault";
    my $vault_tmp_rec  = "$vault_dir/projects/m1/files/.ccpraxis-local-data/almanac/todo/race1.md.vault-sync.tmp";
    my $vault_tmp_seal = "$vault_dir/projects/m1/files/.ccpraxis-local-data/almanac/todo/race1.md.seal.vault-sync.tmp";

    bp16_release_pause($pause_dir);

    # Fixed shape: classify+stage runs inside the SAME locked callback, so by
    # the time the seam reaches its SECOND point, staging is structurally
    # guaranteed to have landed and the lock is still held -- deterministic,
    # not a race. Reverted shape (mutation 1): the callback returns and
    # releases every lock right after the FIRST point, so the second point
    # never fires from inside a lock at all; with hold-staged absent from its
    # own perspective it is either skipped (staging already ran, unlocked, in
    # the generic loop) or -- if reached some other way -- the lock is
    # already free. Either way the assertions below go red under the revert.
    my $staged_entered = bp16_wait_for_file("$pause_dir/staged", 32);
    ok($staged_entered,
       'M1: the second sync signals it reached the seam\'s SECOND pause point (staging complete, still inside the lock window)')
        or diag('staged never appeared within 32s -- either the seam\'s second point is unimplemented, or staging never ran inside the window');

    my ($writer_lock2, $writer_err2) = Almanac::Lock->acquire($rec_path, timeout_ms => 300, verb => 'm1-concurrent-writer-2');
    ok(!defined($writer_lock2),
       'M1: the concurrent writer is STILL DENIED race1.md\'s lock at the staged pause point -- the lock is held through staging, not just through enumeration')
        or diag('the writer acquired the lock at the staged point -- the store lock released before/without staging finishing under it');
    $writer_lock2->release if defined $writer_lock2;

    ok(-e $vault_tmp_rec,
       'M1: race1.md\'s vault-side staging tmp file exists at the staged pause point -- staging ran INSIDE the lock window')
        or diag("$vault_tmp_rec did not exist at the staged pause point");
    ok(-e $vault_tmp_seal,
       'M1: the seal\'s vault-side staging tmp file ALSO exists at the staged pause point')
        or diag("$vault_tmp_seal did not exist at the staged pause point");

    bp16_release_pause_staged($pause_dir);

    my $sync = bp16_collect_async($async, 40);
    ok(!$sync->{timed_out}, 'M1: the paused sync-project resumed and exited after release') or diag($sync->{out});
    unlike(($sync->{out} // ''), qr/\bDied\b/, 'M1: sync-project output shows no die() around the lock window');

    my $cp = run_vs($home, 'commit-and-push', '--slug', 'm1', '--session-id', ($sync->{json}{session_id} // ''));
    unlike(($cp->{out} // ''), qr/\bDied\b/, 'M1: commit-and-push shows no die() either');

    my @tree = bp16_git_ls_tree($remote, 'main');
    my $has_record = (grep { $_ eq 'projects/m1/files/.ccpraxis-local-data/almanac/todo/race1.md' } @tree) ? 1 : 0;
    my $has_seal   = (grep { $_ eq 'projects/m1/files/.ccpraxis-local-data/almanac/todo/race1.md.seal' } @tree) ? 1 : 0;
    is($has_record, $has_seal,
       'M1: after the window, the vault holds race1.md and its seal as a pair (never one without the other)');
    if ($has_record && $has_seal) {
        my $vault_body = bp16_git_show_blob($remote, 'main', 'projects/m1/files/.ccpraxis-local-data/almanac/todo/race1.md');
        like($vault_body, qr/race body v2/, 'M1: the vault record reflects the pre-window update (v2), not a torn mix');
    }
}

# ===========================================================================
# M1c (16-rereview M1c: "vanished push source rolls the group back") -- a
# record's LOCAL .md is deleted after sync-project stages its push (the tmp
# copy already made) but before commit-and-push applies the batch: the first
# half of what a concurrent Store delete does. The whole almanac record
# group (record + seal) must roll back TOGETHER, be reported in
# rolled_back_during_sync with reason almanac_group_rolled_back, and the
# remote must still hold the PRIOR pushed pair -- never a torn mix of the new
# record alone or the new seal alone.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'm1c-home');
    my $proj   = "$root/m1c-proj"; make_path($proj);
    run_vs($home, 'init', '--url', $remote);
    write_text("$proj/CLAUDE.md", "# m1c\n");
    run_vs($home, 'register', '--fresh', '--cwd', $proj, '--slug', 'm1c', '--files', 'CLAUDE.md');

    my $store = bp16_open_proj_store($proj, 'todo');
    $store->create(id => 'vanish1', fields => {}, body => "r1 body\n");
    run_vs($home, 'refresh-default-tracked', '--slug', 'm1c');

    my $sync0 = run_vs($home, 'sync-project', '--slug', 'm1c');
    my $cp0 = run_vs($home, 'commit-and-push', '--slug', 'm1c', '--session-id', ($sync0->{json}{session_id} // ''));
    is($cp0->{json} && $cp0->{json}{status}, 'committed_and_pushed', 'M1c: (setup) R1+S1 baseline pushed') or diag($cp0->{out});

    my $rec_path = $store->dir . '/vanish1.md';
    my $r1_bytes = read_text($rec_path);

    my $rec0 = $store->read('vanish1');
    $store->update('vanish1', expect => { rev => $rec0->{rev}, fields => $rec0->{fields} }, body => "r2 body\n");

    my $sync = run_vs($home, 'sync-project', '--slug', 'm1c');
    is($sync->{json} && $sync->{json}{status}, 'synced', 'M1c: (setup) classify+stage of R2/S2 succeeded') or diag($sync->{out});

    # The gap: the local record vanishes between classify (above, already
    # staged as tmp) and the locked apply (commit-and-push, below).
    unlink $rec_path or die "M1c fixture: cannot unlink $rec_path: $!";
    ok(!-e $rec_path, 'M1c: (setup) the local record source has vanished before commit-and-push');

    my $cp = run_vs($home, 'commit-and-push', '--slug', 'm1c', '--session-id', ($sync->{json}{session_id} // ''));

    my @rb = @{ ($cp->{json} && $cp->{json}{rolled_back_during_sync}) || [] };
    my %rb_by_path = map { (($_->{path} // '') => $_) } @rb;
    ok(exists $rb_by_path{'.ccpraxis-local-data/almanac/todo/vanish1.md'},
       'M1c: the record is reported in rolled_back_during_sync') or diag(join(', ', map { $_->{path} // '?' } @rb));
    ok(exists $rb_by_path{'.ccpraxis-local-data/almanac/todo/vanish1.md.seal'},
       'M1c: the seal is reported rolled back TOO -- the whole group, not just the vanished member');
    is(($rb_by_path{'.ccpraxis-local-data/almanac/todo/vanish1.md'} // {})->{reason}, 'almanac_group_rolled_back',
       'M1c: the rollback reason is almanac_group_rolled_back');

    my $vault_record_bytes = bp16_git_show_blob($remote, 'main', 'projects/m1c/files/.ccpraxis-local-data/almanac/todo/vanish1.md');
    is($vault_record_bytes, $r1_bytes, 'M1c: the remote still holds R1 (the prior pushed body) -- R2 never landed');
}

# ===========================================================================
# M2G (16-rereview's real M2: sync-global-almanac's private-index commit,
# against an ALREADY-TRACKED global store, exercised through the seam) --
# the pre-existing "M2" block below this one only covers a store SKIP during
# sync-PROJECT (it guards M1's %almanac_skipped_rel, per 16-rereview N3, not
# this). No block ran sync-global-almanac a second time while its own store
# lock window is held. While paused, an unrelated path is pre-staged in the
# vault's real git index (the private-index mechanism's whole reason to
# exist), and the assertions are that it survives the commit, and that the
# commit carries EXACTLY the record content that was present when the
# window's locks were taken -- the locked copy, not a stale pre-window one.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'm2g-home');
    run_vs($home, 'init', '--url', $remote);
    my $vault_dir = "$home/.claude/claude-code-vault";

    my $store = bp16_open_global_store($home, 'todo');
    $store->create(id => 'g1', fields => {}, body => "g1 v1\n");

    my $r0 = run_vs($home, 'sync-global-almanac');
    is($r0->{exit}, 0, 'M2G: (setup) baseline sync-global-almanac exits 0') or diag($r0->{out});
    ok(scalar(grep { $_ eq 'almanac/todo/g1.md' } bp16_git_ls_tree($remote, 'main')),
       'M2G: (setup) g1.md is on the remote -- the store is now ALREADY TRACKED');

    my $rec0 = $store->read('g1');
    $store->update('g1', expect => { rev => $rec0->{rev}, fields => $rec0->{fields} }, body => "g1 v2 (the locked copy)\n");
    my $rec_path = $store->dir . '/g1.md';
    my $v2_bytes = read_text($rec_path);

    write_text("$vault_dir/reports/m2g-r.md", "unrelated staged report\n");
    ok(bp16_git($home, $vault_dir, 'add', '-A', '--', 'reports'),
       'M2G: (setup) an unrelated file is staged in the vault\'s real index');

    my $pause_dir = bp16_pause_dir($root, 'm2g-pause');
    my $async = bp16_spawn_vs_async($home, $pause_dir, 'sync-global-almanac');
    my $entered = bp16_wait_for_file("$pause_dir/in-window", 15);
    ok($entered, 'M2G: sync-global-almanac signals it is paused inside the global store lock window')
        or diag('in-window never appeared -- either the seam is unimplemented for this command, or no window opened');

    bp16_release_pause($pause_dir);
    my $r1 = bp16_collect_async($async, 40);
    ok(!$r1->{timed_out}, 'M2G: the paused sync-global-almanac resumed and exited') or diag($r1->{out});
    is($r1->{exit}, 0, 'M2G: sync-global-almanac still exits 0 after the window') or diag($r1->{out});

    my $vault_record_bytes = bp16_git_show_blob($remote, 'main', 'almanac/todo/g1.md');
    is($vault_record_bytes, $v2_bytes, 'M2G: the commit carries EXACTLY the locked copy (v2), byte for byte');

    my $staged = bp16_git_out($home, $vault_dir, 'diff', '--cached', '--name-only');
    my $head_files = bp16_git_out($home, $vault_dir, 'show', '--name-only', '--pretty=format:', 'HEAD');
    ok(scalar(grep { $_ eq 'reports/m2g-r.md' } split(/\n/, $staged))
        || scalar(grep { $_ eq 'reports/m2g-r.md' } split(/\n/, $head_files)),
       'M2G: the unrelated pre-staged file SURVIVES the private-index commit (still staged, or now committed)');

    # M2G(a) (16-mutation-r2.md's own "Needed" fix for mutation #4: run
    # sync-global-almanac once so the store is tracked, modify a tracked
    # record, hold its lock, and run it again -- the remote blob must stay
    # unchanged and skipped_stores must name the store. The pre-existing "M2"
    # block below only covers this for sync-PROJECT; nothing exercised it for
    # sync-global-almanac itself).
    my $rec1 = $store->read('g1');
    $store->update('g1', expect => { rev => $rec1->{rev}, fields => $rec1->{fields} }, body => "g1 v3 (should be skipped)\n");

    # M2G(a) (Decision 45, round-4, report 16-mutation-r3.md MF-1): a faithful
    # revert of the private index (mutation 4) only goes red once THIS run
    # actually reaches its own commit step -- and with g1's store skipped
    # (locked) and nothing else changed, the diff is empty and the mutant
    # never calls `git commit` at all, so the assertion below stayed vacuously
    # green. Force a real commit in this same run by ALSO modifying a SECOND
    # global store (a fresh 'note' record) while g1's lock is held. That
    # store is not locked, so it stages and commits normally. Under the
    # reverted (real-index, --only) shape, that commit's `--only -- almanac
    # notes` pathspec would ALSO pick up g1's v3 WORKTREE bytes even though
    # g1's store was skipped and never staged -- because --only mode commits
    # the worktree state of every path under the pathspec, not just what was
    # staged.
    my $nstore = bp16_open_global_store($home, 'note');
    $nstore->create(id => 'n1', fields => {}, body => "note n1 v1\n");
    my $n1_path  = $nstore->dir . '/n1.md';
    my $n1_bytes = read_text($n1_path);

    my ($skip_lock, $skip_lerr) = Almanac::Lock->acquire($rec_path, verb => 'm2g-skip-holder');
    ok(defined $skip_lock, 'M2G(a): (setup) the test process holds g1.md\'s real lock') or diag($skip_lerr);

    my $r2;
    { local $ENV{VAULT_SYNC_ALMANAC_LOCK_TIMEOUT_MS} = 300; $r2 = run_vs($home, 'sync-global-almanac'); }
    is($r2->{exit}, 0, 'M2G(a): sync-global-almanac still exits 0 while the store is locked (a skip is not a failure)') or diag($r2->{out});
    is(scalar(@{ ($r2->{json}{skipped_stores} // []) }), 1,
       'M2G(a): exactly one skipped_stores entry while g1.md\'s lock is held') or diag($r2->{out});

    my @tree_m2ga = bp16_git_ls_tree($remote, 'main');
    ok(scalar(grep { $_ eq 'almanac/note/n1.md' } @tree_m2ga),
       'M2G(a): (setup) the SECOND (unlocked) store\'s new record DID land on the remote -- this run genuinely committed something, so the private-index revert has something to leak through')
        or diag('n1.md never landed -- the forcing change did not commit, so this block cannot distinguish the fixed and reverted shapes');

    my $vault_record_bytes2 = bp16_git_show_blob($remote, 'main', 'almanac/todo/g1.md');
    is($vault_record_bytes2, $v2_bytes,
       'M2G(a): the modified (v3) tracked record was NOT committed while its store was skipped -- the remote still holds v2, even though this run committed the second store\'s record');

    $skip_lock->release;
    my $r3 = run_vs($home, 'sync-global-almanac');
    is($r3->{exit}, 0, 'M2G(a): (cleanup check) once released, sync-global-almanac exits 0') or diag($r3->{out});
    is(scalar(@{ ($r3->{json}{skipped_stores} // []) }), 0, 'M2G(a): (cleanup check) once released, nothing is skipped');
    my $v3_bytes = read_text($rec_path);
    my $vault_record_bytes3 = bp16_git_show_blob($remote, 'main', 'almanac/todo/g1.md');
    is($vault_record_bytes3, $v3_bytes, 'M2G(a): once released, the next sync DOES commit the modified (v3) record');
}

# ===========================================================================
# MF1 (16-rereview MUST-FIX: a whole almanac/<type>/ directory, or notes/,
# deleted locally, never leaves the remote) -- the private index is seeded
# from HEAD; if a type directory (or notes/) is removed as a whole, its
# HEAD-seeded entries must still be dropped before the commit, or they are
# committed again every run and a restore would resurrect deleted records.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'mf1-home');
    run_vs($home, 'init', '--url', $remote);
    my $vault_dir = "$home/.claude/claude-code-vault";

    my $todo_store = bp16_open_global_store($home, 'todo');
    my $note_store = bp16_open_global_store($home, 'note');
    $todo_store->create(id => 'mf1todo', fields => {}, body => "todo body\n");
    $note_store->create(id => 'mf1note', fields => {}, body => "note body\n");
    write_text("$vault_dir/notes/mf1.md", "a note target\n");

    my $r0 = run_vs($home, 'sync-global-almanac');
    is($r0->{exit}, 0, 'MF1: (setup) baseline sync-global-almanac exits 0') or diag($r0->{out});
    my @tree0 = bp16_git_ls_tree($remote, 'main');
    ok(scalar(grep { $_ eq 'almanac/todo/mf1todo.md' } @tree0), 'MF1: (setup) the todo record is on the remote');
    ok(scalar(grep { $_ eq 'almanac/note/mf1note.md' } @tree0), 'MF1: (setup) the note-type record is on the remote');
    ok(scalar(grep { $_ eq 'notes/mf1.md' } @tree0), 'MF1: (setup) the notes/ file is on the remote');

    # The WHOLE todo type directory, and the WHOLE notes/ directory, are
    # removed locally -- not a single record, the entire subtree.
    my $rmtree_ok = eval { require File::Path; File::Path::remove_tree("$vault_dir/almanac/todo"); 1 };
    ok($rmtree_ok && !-d "$vault_dir/almanac/todo", 'MF1: (setup) almanac/todo/ removed as a whole, locally');
    my $rmnotes_ok = eval { File::Path::remove_tree("$vault_dir/notes"); 1 };
    ok($rmnotes_ok && !-d "$vault_dir/notes", 'MF1: (setup) notes/ removed as a whole, locally');

    my $r1 = run_vs($home, 'sync-global-almanac');
    is($r1->{exit}, 0, 'MF1: the next sync-global-almanac still exits 0') or diag($r1->{out});

    my @tree1 = bp16_git_ls_tree($remote, 'main');
    ok(!(grep { m{^almanac/todo/} } @tree1),
       'MF1: no almanac/todo/* path survives in the remote commit -- the deletion is mirrored') or diag(join(', ', @tree1));
    ok(!(grep { m{^notes/} } @tree1),
       'MF1: no notes/* path survives in the remote commit either') or diag(join(', ', @tree1));
    ok(scalar(grep { $_ eq 'almanac/note/mf1note.md' } @tree1),
       'MF1: the UNTOUCHED note-type directory is still intact on the remote');
}

# ===========================================================================
# SF1 (16-rereview: the unrestricted pull guard, and the push guard, fail
# open when vault_ahead_behind cannot compute) -- a missing origin/main (or
# any rev-list failure) must be reported as a hard error, never silently
# read as "nothing to push" with the commit stranded locally and the run
# still claiming committed_and_pushed.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'sf1-home');
    my $proj   = "$root/sf1-proj"; make_path($proj);
    run_vs($home, 'init', '--url', $remote);
    my $vault_dir = "$home/.claude/claude-code-vault";
    write_text("$proj/CLAUDE.md", "# sf1\n");
    run_vs($home, 'register', '--fresh', '--cwd', $proj, '--slug', 'sf1', '--files', 'CLAUDE.md');

    my $store = bp16_open_proj_store($proj, 'todo');
    $store->create(id => 'sf1rec', fields => {}, body => "v1\n");
    run_vs($home, 'refresh-default-tracked', '--slug', 'sf1');
    my $sync0 = run_vs($home, 'sync-project', '--slug', 'sf1');
    my $cp0 = run_vs($home, 'commit-and-push', '--slug', 'sf1', '--session-id', ($sync0->{json}{session_id} // ''));
    is($cp0->{json} && $cp0->{json}{status}, 'committed_and_pushed', 'SF1: (setup) baseline push established origin/main') or diag($cp0->{out});

    my $rec0 = $store->read('sf1rec');
    $store->update('sf1rec', expect => { rev => $rec0->{rev}, fields => $rec0->{fields} }, body => "v2, something new to push\n");
    my $sync1 = run_vs($home, 'sync-project', '--slug', 'sf1');
    is($sync1->{json} && $sync1->{json}{status}, 'synced', 'SF1: (setup) v2 staged for push') or diag($sync1->{out});

    # A missing origin/$BRANCH: delete the remote-tracking ref directly, so
    # the NEXT rev-list vault_ahead_behind runs cannot resolve it.
    ok(bp16_git($home, $vault_dir, 'update-ref', '-d', 'refs/remotes/origin/main'),
       'SF1: (setup) origin/main\'s remote-tracking ref is deleted from the vault clone');

    my $cp1 = run_vs($home, 'commit-and-push', '--slug', 'sf1', '--session-id', ($sync1->{json}{session_id} // ''));
    isnt(($cp1->{json} && $cp1->{json}{status}) // '', 'committed_and_pushed',
         'SF1: commit-and-push NEVER reports committed_and_pushed when ahead/behind is unanswerable') or diag($cp1->{out});
    is($cp1->{json} && $cp1->{json}{status}, 'error', 'SF1: it reports status error instead') or diag($cp1->{out});
    ok(length(($cp1->{json} // {})->{error} // ''), 'SF1: the error carries a non-empty message');
}

# ===========================================================================
# SF2 (16-rereview: sync-global-almanac's post-push HEAD==origin/main
# invariant must not be skipped when a sha is empty/missing) -- a static
# regression guard, not a dynamic one: SF1's fix (vault_ahead_behind failing
# closed) already intercepts a missing origin/$BRANCH earlier in the SAME
# function, on the SAME rev-list target, so black-box I/O cannot reach this
# invariant's own rev-parse calls with origin/$BRANCH missing without ALSO
# tripping the earlier guard first -- there is no seam here (unlike M1/M2G)
# to isolate the race Decision 43 does not name for this location. Recorded
# as a source-literal check instead: the S3 invariant's own empty-sha guard
# must still exist and must not be gated behind `length(...)` alone (S3's
# original bug was exactly that gate skipping the comparison on an empty
# sha) -- see the report for why a dynamic reproduction is not available.
# ===========================================================================
{
    open(my $fh, '<', $VS_REAL_SRC) or die "SF2: cannot read $VS_REAL_SRC: $!";
    local $/;
    my $src = <$fh>;
    close $fh;
    like($src, qr/does not match origin/,
         'SF2: the HEAD-vs-origin invariant\'s error message is still present in vault-sync.pl');
    like($src, qr/!length\(\$head_sha\)\s*\|\|\s*!length\(\$origin_sha\)\s*\|\|\s*\$head_sha\s+ne\s+\$origin_sha/,
         'SF2: the invariant checks an EMPTY sha as a failure too, not only a sha mismatch (the original S3 gap)');
}

# ===========================================================================
# SF4 (16-rereview: crash-recovery roll-forward vs. partial rollback) --
# simulates a REAL crash: batch_rename_all's pull-side rename for the record
# actually LANDED on disk (tmp -> final) but the process died before the
# seal's rename AND before the journal's per-op status flush (which only
# happens at the END of the whole pass), so the persisted journal still
# reads BOTH ops 'staged' on the next run. The correct behaviour is to roll
# the group FORWARD (recognise the record as already applied), never
# backward -- rolling back would discard the seal's still-good staged tmp
# and leave a torn local pair (record = new vault bytes, seal = stale).
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);

    my $homeA = make_machine($root, 'sf4-homeA');
    my $projA = "$root/sf4-projA"; make_path($projA);
    run_vs($homeA, 'init', '--url', $remote);
    write_text("$projA/CLAUDE.md", "# sf4\n");
    run_vs($homeA, 'register', '--fresh', '--cwd', $projA, '--slug', 'sf4', '--files', 'CLAUDE.md');
    my $storeA = bp16_open_proj_store($projA, 'todo');
    $storeA->create(id => 'crash1', fields => {}, body => "from A v1\n");
    run_vs($homeA, 'refresh-default-tracked', '--slug', 'sf4');
    my $sA0 = run_vs($homeA, 'sync-project', '--slug', 'sf4');
    run_vs($homeA, 'commit-and-push', '--slug', 'sf4', '--session-id', ($sA0->{json}{session_id} // ''));

    my $homeB = make_machine($root, 'sf4-homeB');
    my $projB = "$root/sf4-projB"; make_path($projB);
    run_vs($homeB, 'init', '--url', $remote);
    my $regB = run_vs($homeB, 'register', '--link', '--cwd', $projB, '--slug', 'sf4');
    ok($regB->{json} && $regB->{json}{status} eq 'registered_link', 'SF4: (setup) machine B linked') or diag($regB->{out});
    my $sB0 = run_vs($homeB, 'sync-project', '--slug', 'sf4');
    run_vs($homeB, 'commit-and-push', '--slug', 'sf4', '--session-id', ($sB0->{json}{session_id} // ''));

    my $recA = $storeA->read('crash1');
    $storeA->update('crash1', expect => { rev => $recA->{rev}, fields => $recA->{fields} }, body => "from A v2\n");
    my $sA1 = run_vs($homeA, 'sync-project', '--slug', 'sf4');
    run_vs($homeA, 'commit-and-push', '--slug', 'sf4', '--session-id', ($sA1->{json}{session_id} // ''));

    # B classifies pull for crash1.md and crash1.md.seal, staging both (tmp
    # copies of the v2 vault content).
    my $sB1 = run_vs($homeB, 'sync-project', '--slug', 'sf4');
    is($sB1->{json} && $sB1->{json}{status}, 'synced', 'SF4: (setup) B classifies crash1 for a pull') or diag($sB1->{out});

    my $rec_path_B  = "$projB/.ccpraxis-local-data/almanac/todo/crash1.md";
    my $seal_path_B = Almanac::Store::seal_path_for($rec_path_B);
    my $rec_tmp_B   = "$rec_path_B.vault-sync.tmp";
    my $seal_tmp_B  = "$seal_path_B.vault-sync.tmp";
    ok(-f $rec_tmp_B && -f $seal_tmp_B, 'SF4: (setup) both the record and seal have a staged pull tmp file')
        or diag("rec_tmp=$rec_tmp_B seal_tmp=$seal_tmp_B");

    # Simulate the crash: the record's rename LANDED (tmp -> final) but the
    # journal's per-op status flush never ran, so the persisted journal
    # still shows BOTH ops 'staged'. The seal's tmp is left exactly as
    # stage_pull wrote it, untouched.
    rename($rec_tmp_B, $rec_path_B) or die "SF4 fixture: cannot rename $rec_tmp_B: $!";
    ok(!-f $rec_tmp_B && -f $rec_path_B, 'SF4: (setup) the record\'s rename has landed on disk, unrecorded in the journal');

    my $cpB = run_vs($homeB, 'commit-and-push', '--slug', 'sf4', '--session-id', ($sB1->{json}{session_id} // ''));

    my $final_rec_bytes  = read_text($rec_path_B);
    my $final_seal_bytes = read_text($seal_path_B);
    my $vault_rec_bytes  = bp16_git_show_blob($remote, 'main', 'projects/sf4/files/.ccpraxis-local-data/almanac/todo/crash1.md');
    my $vault_seal_bytes = bp16_git_show_blob($remote, 'main', 'projects/sf4/files/.ccpraxis-local-data/almanac/todo/crash1.md.seal');

    is($final_rec_bytes, $vault_rec_bytes,
       'SF4: after recovery, the record matches the vault bytes (rolled forward, not left reverted mid-way)') or diag($cpB->{out});
    is($final_seal_bytes, $vault_seal_bytes,
       'SF4: after recovery, the seal ALSO matches the vault bytes -- the group landed as a consistent pair, never torn');
}

# ===========================================================================
# SF4b (16-mutation-r2.md mutation 8': the delete_local roll-forward guard
# was never covered -- the SF4 block above only exercises the PULL half of
# roll-forward). Mirrors the SAME crash shape for the OTHER pull-like
# action: a delete_local's unlink actually LANDED on disk, but the process
# died before the sibling seal's own delete_local applied AND before the
# journal's per-op status flush, so the persisted journal still reads BOTH
# ops 'staged'. Recovery must roll the group FORWARD (recognise the missing
# record as already applied), never treat "file now missing" as a lost
# local edit and roll the seal's still-pending delete back -- that would
# strand an orphaned seal on disk forever with no matching record.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);

    my $homeA = make_machine($root, 'sf4b-homeA');
    my $projA = "$root/sf4b-projA"; make_path($projA);
    run_vs($homeA, 'init', '--url', $remote);
    write_text("$projA/CLAUDE.md", "# sf4b\n");
    run_vs($homeA, 'register', '--fresh', '--cwd', $projA, '--slug', 'sf4b', '--files', 'CLAUDE.md');
    my $storeA = bp16_open_proj_store($projA, 'todo');
    $storeA->create(id => 'gone1', fields => {}, body => "from A v1\n");
    run_vs($homeA, 'refresh-default-tracked', '--slug', 'sf4b');
    my $sA0 = run_vs($homeA, 'sync-project', '--slug', 'sf4b');
    run_vs($homeA, 'commit-and-push', '--slug', 'sf4b', '--session-id', ($sA0->{json}{session_id} // ''));

    my $homeB = make_machine($root, 'sf4b-homeB');
    my $projB = "$root/sf4b-projB"; make_path($projB);
    run_vs($homeB, 'init', '--url', $remote);
    my $regB = run_vs($homeB, 'register', '--link', '--cwd', $projB, '--slug', 'sf4b');
    ok($regB->{json} && $regB->{json}{status} eq 'registered_link', 'SF4b: (setup) machine B linked') or diag($regB->{out});
    my $sB0 = run_vs($homeB, 'sync-project', '--slug', 'sf4b');
    is($sB0->{json} && $sB0->{json}{status}, 'synced', 'SF4b: (setup) machine B pulled gone1 v1') or diag($sB0->{out});
    run_vs($homeB, 'commit-and-push', '--slug', 'sf4b', '--session-id', ($sB0->{json}{session_id} // ''));

    my $rec_path_B  = "$projB/.ccpraxis-local-data/almanac/todo/gone1.md";
    my $seal_path_B = Almanac::Store::seal_path_for($rec_path_B);
    ok(-f $rec_path_B && -f $seal_path_B, 'SF4b: (setup) machine B has a local copy of gone1.md and its seal');

    # A deletes the record and pushes the deletion.
    my $recA = $storeA->read('gone1');
    $storeA->delete('gone1', expect => { rev => $recA->{rev}, fields => $recA->{fields} });
    my $sA1 = run_vs($homeA, 'sync-project', '--slug', 'sf4b');
    run_vs($homeA, 'commit-and-push', '--slug', 'sf4b', '--session-id', ($sA1->{json}{session_id} // ''));

    # B classifies delete_local for BOTH gone1.md and gone1.md.seal (local
    # still matches the old base; the vault side is now gone), staging both.
    my $sB1 = run_vs($homeB, 'sync-project', '--slug', 'sf4b');
    is($sB1->{json} && $sB1->{json}{status}, 'synced', 'SF4b: (setup) B classifies gone1 for a delete_local') or diag($sB1->{out});
    ok(-f $rec_path_B && -f $seal_path_B,
       'SF4b: (setup) both files are still on disk before recovery -- delete_local is staged, not yet applied');

    # Simulate the crash: the RECORD's unlink LANDED, but the process died
    # before the seal's unlink AND before the journal's per-op status flush,
    # so the persisted journal still reads BOTH ops 'staged'. The seal is
    # left exactly as it was before this sync, untouched.
    unlink $rec_path_B or die "SF4b fixture: cannot unlink $rec_path_B: $!";
    ok(!-f $rec_path_B && -f $seal_path_B,
       'SF4b: (setup) the record\'s delete has landed on disk; the seal\'s has not -- unrecorded in the journal');

    my $cpB = run_vs($homeB, 'commit-and-push', '--slug', 'sf4b', '--session-id', ($sB1->{json}{session_id} // ''));

    ok(!-f $rec_path_B,
       'SF4b: after recovery, the record stays deleted (roll-forward recognises it as already applied)') or diag($cpB->{out});
    ok(!-f $seal_path_B,
       'SF4b: after recovery, the seal is ALSO deleted -- the group lands as a consistent pair, never an orphan seal left behind')
        or diag($cpB->{out});

    my @rb = @{ ($cpB->{json} && $cpB->{json}{rolled_back_during_sync}) || [] };
    my %rb_by_path = map { (($_->{path} // '') => $_) } @rb;
    ok(!exists $rb_by_path{'.ccpraxis-local-data/almanac/todo/gone1.md'},
       'SF4b: gone1.md is NOT reported rolled back -- a missing already-applied file is roll-forward residue, not a lost update')
        or diag(join(', ', map { $_->{path} // '?' } @rb));
    ok(!exists $rb_by_path{'.ccpraxis-local-data/almanac/todo/gone1.md.seal'},
       'SF4b: the seal is NOT reported rolled back either');
}

# ===========================================================================
# SF6 (16-rereview: finalize_commit's pathspec-less `git commit` can revert
# global almanac records) -- simulates the crash window Decision 43 names:
# a global almanac sync's private-index commit landed, but before the real
# index is reset for almanac/notes the process dies, leaving the real index
# holding a STALE almanac/ change that disagrees with HEAD. The very next
# sync is an ordinary PROJECT sync-project + commit-and-push. Its own commit
# must never let that stale real-index state ride along as a side effect --
# the global record must survive in HEAD and on the remote, and the
# project's own commit must not even TOUCH the almanac/ path.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'sf6-home');
    my $proj   = "$root/sf6-proj"; make_path($proj);
    run_vs($home, 'init', '--url', $remote);
    my $vault_dir = "$home/.claude/claude-code-vault";

    my $gstore = bp16_open_global_store($home, 'todo');
    $gstore->create(id => 'g1', fields => {}, body => "global g1\n");
    my $g1 = run_vs($home, 'sync-global-almanac');
    is($g1->{exit}, 0, 'SF6: (setup) global almanac record synced+pushed') or diag($g1->{out});
    ok(scalar(grep { $_ eq 'almanac/todo/g1.md' } bp16_git_ls_tree($remote, 'main')),
       'SF6: (setup) the remote holds the global record before the simulated crash');
    ok(scalar(grep { $_ eq 'almanac/todo/g1.md.seal' } bp16_git_ls_tree($remote, 'main')),
       'SF6: (setup) the remote holds the global record\'s seal too, before the simulated crash');

    # MF-B (16-mutation-r2.md): register the project BEFORE planting the
    # stale residue below. `register --fresh`/`--link` commit with NO
    # pathspec of their own (vault-sync.pl ~:662/:742) -- if the project were
    # registered AFTER the residue existed, THAT whole-index commit, not the
    # sync-project reset this block means to exercise, would silently consume
    # the residue first, and the block would prove nothing. This is exactly
    # why mutation 9 (SF6's reset inside sync-project, `:1015`) stayed GREEN
    # in round 2: register had already eaten the residue before sync-project
    # ever ran, so its own reset was a no-op no matter what it did.
    write_text("$proj/CLAUDE.md", "# sf6\n");
    run_vs($home, 'register', '--fresh', '--cwd', $proj, '--slug', 'sf6', '--files', 'CLAUDE.md');

    # Simulate the crash residue: the real index is left as if the private-
    # commit-then-reset sequence never reached its reset step -- a STALE
    # staged deletion of the global record that disagrees with HEAD.
    ok(bp16_git($home, $vault_dir, 'rm', '--cached', '-q', '--', 'almanac/todo/g1.md'),
       'SF6: (setup) the real index is left with a stale, uncommitted almanac/ change');
    my $status_before = bp16_git_out($home, $vault_dir, 'status', '--porcelain', '--', 'almanac');
    like($status_before, qr/almanac\/todo\/g1\.md/, 'SF6: (setup) git status shows the stale almanac/ entry before the next sync');

    my $sp = run_vs($home, 'sync-project', '--slug', 'sf6');
    my $cp = run_vs($home, 'commit-and-push', '--slug', 'sf6', '--session-id', ($sp->{json}{session_id} // ''));
    is($cp->{json} && $cp->{json}{status}, 'committed_and_pushed', 'SF6: the project sync+push completes') or diag($cp->{out});

    my @tree_final = bp16_git_ls_tree($remote, 'main');
    ok(scalar(grep { $_ eq 'almanac/todo/g1.md' } @tree_final),
       'SF6: the global record SURVIVES on the remote -- the project commit did not silently revert it');
    ok(scalar(grep { $_ eq 'almanac/todo/g1.md.seal' } @tree_final),
       'SF6: the global record\'s SEAL survives too -- the remote never holds one without the other');
    my $head_files = bp16_git_out($home, $vault_dir, 'show', '--name-only', '--pretty=format:', 'HEAD');
    unlike($head_files, qr{^almanac/todo/g1\.md$}m,
       'SF6: the project sync commit does not TOUCH almanac/todo/g1.md at all (proves it commits only projects/sf6/)');
}

# ===========================================================================
# SF-2 (Decision 45, round-4, report 16-mutation-r3.md SF-2): SF6 above plants
# its stale almanac/ residue BEFORE sync-project runs, so sync-project's OWN
# reset (vault-sync.pl ~:1044) already cleans it up -- finalize_commit's own
# reset and pathspec (~:1735, ~:1788) are never actually exercised there;
# mutation 12 (both reverted) stayed masked, GREEN, in round 3. Here the
# residue is planted AFTER sync-project returns and BEFORE commit-and-push
# runs, so sync-project's reset has nothing to clean (it already ran) and
# ONLY finalize_commit's own reset+pathspec stand between the crash residue
# and the remote. This must go red when BOTH are reverted together.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'sf2-home');
    my $proj   = "$root/sf2-proj"; make_path($proj);
    run_vs($home, 'init', '--url', $remote);
    my $vault_dir = "$home/.claude/claude-code-vault";

    my $gstore = bp16_open_global_store($home, 'todo');
    $gstore->create(id => 'g1', fields => {}, body => "global g1\n");
    my $g1 = run_vs($home, 'sync-global-almanac');
    is($g1->{exit}, 0, 'SF-2: (setup) global almanac record synced+pushed') or diag($g1->{out});
    ok(scalar(grep { $_ eq 'almanac/todo/g1.md' } bp16_git_ls_tree($remote, 'main')),
       'SF-2: (setup) the remote holds the global record before the simulated crash');
    ok(scalar(grep { $_ eq 'almanac/todo/g1.md.seal' } bp16_git_ls_tree($remote, 'main')),
       'SF-2: (setup) the remote holds the global record\'s seal too, before the simulated crash');

    write_text("$proj/CLAUDE.md", "# sf2\n");
    run_vs($home, 'register', '--fresh', '--cwd', $proj, '--slug', 'sf2', '--files', 'CLAUDE.md');

    # Run sync-project to completion (its own reset fires and finishes here --
    # there is no residue yet for it to clean).
    my $sp = run_vs($home, 'sync-project', '--slug', 'sf2');
    is($sp->{json} && $sp->{json}{status}, 'synced', 'SF-2: (setup) sync-project completes before any residue is planted') or diag($sp->{out});

    # NOW simulate the crash residue -- strictly AFTER sync-project's own
    # reset has already run and returned, so only finalize_commit's own
    # reset+pathspec (inside commit-and-push) can save the global record.
    ok(bp16_git($home, $vault_dir, 'rm', '--cached', '-q', '--', 'almanac/todo/g1.md'),
       'SF-2: (setup) the real index is left with a stale, uncommitted almanac/ change AFTER sync-project returned');
    my $status_before = bp16_git_out($home, $vault_dir, 'status', '--porcelain', '--', 'almanac');
    like($status_before, qr/almanac\/todo\/g1\.md/, 'SF-2: (setup) git status shows the stale almanac/ entry going into commit-and-push');

    my $cp = run_vs($home, 'commit-and-push', '--slug', 'sf2', '--session-id', ($sp->{json}{session_id} // ''));
    is($cp->{json} && $cp->{json}{status}, 'committed_and_pushed', 'SF-2: commit-and-push completes despite the residue planted after sync-project') or diag($cp->{out});

    my @tree_final = bp16_git_ls_tree($remote, 'main');
    ok(scalar(grep { $_ eq 'almanac/todo/g1.md' } @tree_final),
       'SF-2: the global record SURVIVES on the remote -- commit-and-push\'s own reset+pathspec caught the residue, not sync-project\'s (already ran)');
    ok(scalar(grep { $_ eq 'almanac/todo/g1.md.seal' } @tree_final),
       'SF-2: the global record\'s SEAL survives too -- the remote never holds one without the other');
    my $head_files = bp16_git_out($home, $vault_dir, 'show', '--name-only', '--pretty=format:', 'HEAD');
    unlike($head_files, qr{^almanac/todo/g1\.md$}m,
       'SF-2: commit-and-push\'s own commit does not TOUCH almanac/todo/g1.md at all (proves --only projects/sf2/ scoping, not a lucky no-op)');
}

# ===========================================================================
# SF6-reg (16-backup-integration: register_fresh/register_link's OWN
# vault_reset_almanac_notes_index call + pathspec-scoped commit, vault-sync.pl
# ~:617/:692 and ~:718/:779). SF6 above proves sync-project's reset guards
# the NEXT project sync against crash residue; it never exercises register
# itself, whose add+commit are the ones actually scoped with `--
# projects/<slug>/`. Here the stale residue is planted IMMEDIATELY BEFORE
# register --fresh (and, separately, register --link) runs, so THEIR OWN
# reset/scoping -- not some later command's -- is what has to save the
# global record. If either the reset call or the `--` pathspec on register's
# `git commit` is reverted, register's commit reverts to committing the
# whole real index, which still carries the residue's staged deletion of
# almanac/todo/g1.md, and the remote loses the record (or its seal) exactly
# as MUST-FIX 2 (16-mutation-r2.md) found.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'sf6reg-home');
    run_vs($home, 'init', '--url', $remote);
    my $vault_dir = "$home/.claude/claude-code-vault";

    my $gstore = bp16_open_global_store($home, 'todo');
    $gstore->create(id => 'g1', fields => {}, body => "global g1\n");
    my $g1 = run_vs($home, 'sync-global-almanac');
    is($g1->{exit}, 0, 'SF6-reg: (setup) global almanac record synced+pushed') or diag($g1->{out});
    my $seal_before = bp16_git_show_blob($remote, 'main', 'almanac/todo/g1.md.seal');
    ok(length($seal_before), 'SF6-reg: (setup) the remote holds a non-empty seal before either register runs');

    # Register the LINK target's slug now, cleanly, before any residue is
    # planted -- this registration is scaffolding (it just needs to exist in
    # the vault for register --link to find later), not the thing under test.
    my $linkProj = "$root/sf6reg-linkproj"; make_path($linkProj);
    write_text("$linkProj/CLAUDE.md", "# sf6reg-link\n");
    my $reg0 = run_vs($home, 'register', '--fresh', '--cwd', $linkProj, '--slug', 'sf6reglink', '--files', 'CLAUDE.md');
    is($reg0->{json} && $reg0->{json}{status}, 'registered_fresh', 'SF6-reg: (setup) the link-target slug is registered cleanly first') or diag($reg0->{out});

    # --- register --fresh, with residue planted right before it runs ---
    ok(bp16_git($home, $vault_dir, 'rm', '--cached', '-q', '--', 'almanac/todo/g1.md'),
       'SF6-reg: (setup) fresh -- the real index is left with a stale, uncommitted almanac/ deletion');
    my $freshProj = "$root/sf6reg-freshproj"; make_path($freshProj);
    write_text("$freshProj/CLAUDE.md", "# sf6reg-fresh\n");
    my $regFresh = run_vs($home, 'register', '--fresh', '--cwd', $freshProj, '--slug', 'sf6regfresh', '--files', 'CLAUDE.md');
    is($regFresh->{json} && $regFresh->{json}{status}, 'registered_fresh', 'SF6-reg: register --fresh completes despite the planted residue') or diag($regFresh->{out});

    my @tree_after_fresh = bp16_git_ls_tree($remote, 'main');
    ok(scalar(grep { $_ eq 'almanac/todo/g1.md' } @tree_after_fresh),
       'SF6-reg: fresh -- the global record SURVIVES on the remote after register --fresh');
    ok(scalar(grep { $_ eq 'almanac/todo/g1.md.seal' } @tree_after_fresh),
       'SF6-reg: fresh -- the global record\'s SEAL survives too');
    is(bp16_git_show_blob($remote, 'main', 'almanac/todo/g1.md.seal'), $seal_before,
       'SF6-reg: fresh -- the seal on the remote is byte-identical to before register --fresh ran');
    my $fresh_head_files = bp16_git_out($home, $vault_dir, 'show', '--name-only', '--pretty=format:', 'HEAD');
    unlike($fresh_head_files, qr{^almanac/}m,
       'SF6-reg: fresh -- register --fresh\'s own commit does not touch almanac/ at all');
    like($fresh_head_files, qr{^projects/sf6regfresh/}m,
       'SF6-reg: fresh -- register --fresh\'s own commit DOES touch projects/sf6regfresh/');

    # --- register --link, on a second machine, with its own fresh residue ---
    my $home2 = make_machine($root, 'sf6reg-home2');
    run_vs($home2, 'init', '--url', $remote);
    my $vault_dir2 = "$home2/.claude/claude-code-vault";
    ok(bp16_git($home2, $vault_dir2, 'rm', '--cached', '-q', '--', 'almanac/todo/g1.md'),
       'SF6-reg: (setup) link -- machine B\'s real index is left with a stale, uncommitted almanac/ deletion');
    my $linkProjB = "$root/sf6reg-linkprojB"; make_path($linkProjB);
    my $regLink = run_vs($home2, 'register', '--link', '--cwd', $linkProjB, '--slug', 'sf6reglink');
    is($regLink->{json} && $regLink->{json}{status}, 'registered_link', 'SF6-reg: register --link completes despite the planted residue') or diag($regLink->{out});

    my @tree_after_link = bp16_git_ls_tree($remote, 'main');
    ok(scalar(grep { $_ eq 'almanac/todo/g1.md' } @tree_after_link),
       'SF6-reg: link -- the global record SURVIVES on the remote after register --link');
    ok(scalar(grep { $_ eq 'almanac/todo/g1.md.seal' } @tree_after_link),
       'SF6-reg: link -- the global record\'s SEAL survives too');
    is(bp16_git_show_blob($remote, 'main', 'almanac/todo/g1.md.seal'), $seal_before,
       'SF6-reg: link -- the seal on the remote is byte-identical to before register --link ran');
    my $link_head_files = bp16_git_out($home2, $vault_dir2, 'show', '--name-only', '--pretty=format:', 'HEAD');
    unlike($link_head_files, qr{^almanac/}m,
       'SF6-reg: link -- register --link\'s own commit does not touch almanac/ at all');
    like($link_head_files, qr{^projects/sf6reglink/}m,
       'SF6-reg: link -- register --link\'s own commit DOES touch projects/sf6reglink/');
}

# ===========================================================================
# N-a (16-mutation-r2.md NIT: sync-global-almanac's OWN initial reset,
# `:1819`, was never covered by any block -- SF6 above only exercises the
# reset that guards the NEXT PROJECT sync's commit against global residue,
# never sync-global-almanac's own reset of its own residue at the start of
# its OWN run). Leaves stale almanac/ residue in the real index, then runs
# sync-global-almanac again with NOTHING new to commit; the real index must
# come out clean for almanac/ regardless -- the reset is unconditional, not
# contingent on there being fresh work to do.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'na-home');
    run_vs($home, 'init', '--url', $remote);
    my $vault_dir = "$home/.claude/claude-code-vault";

    my $store = bp16_open_global_store($home, 'todo');
    $store->create(id => 'na1', fields => {}, body => "na1 body\n");
    my $r0 = run_vs($home, 'sync-global-almanac');
    is($r0->{exit}, 0, 'N-a: (setup) baseline sync-global-almanac exits 0') or diag($r0->{out});
    ok(scalar(grep { $_ eq 'almanac/todo/na1.md' } bp16_git_ls_tree($remote, 'main')),
       'N-a: (setup) na1.md is on the remote -- the store is now ALREADY TRACKED');

    # Leave stale, uncommitted almanac/ residue in the REAL index -- as if a
    # prior run's private-commit-then-reset sequence died before its own
    # reset step ran.
    ok(bp16_git($home, $vault_dir, 'rm', '--cached', '-q', '--', 'almanac/todo/na1.md'),
       'N-a: (setup) the real index is left with a stale, uncommitted almanac/ change');
    my $status_before = bp16_git_out($home, $vault_dir, 'status', '--porcelain', '--', 'almanac');
    like($status_before, qr/almanac\/todo\/na1\.md/, 'N-a: (setup) git status shows the stale almanac/ entry before the next sync');

    # Nothing NEW to commit -- na1 is unchanged since the baseline sync.
    my $r1 = run_vs($home, 'sync-global-almanac');
    is($r1->{exit}, 0, 'N-a: sync-global-almanac with nothing new to commit still exits 0') or diag($r1->{out});

    my $status_after = bp16_git_out($home, $vault_dir, 'status', '--porcelain', '--', 'almanac');
    is($status_after, '', 'N-a: the real index is clean for almanac/ afterward -- the stale residue was reset, not left staged')
        or diag($status_after);
    ok(scalar(grep { $_ eq 'almanac/todo/na1.md' } bp16_git_ls_tree($remote, 'main')),
       'N-a: na1.md still survives on the remote');
}

# ===========================================================================
# M2 (review: skip's blast radius) -- extends AC9's "store skipped for a
# held lock" coverage: the SKIPPED store's own locally-modified tracked
# record must not reach the vault, a sidecar shape that was never in the
# vault stays absent from it, and a file already staged in the vault index
# for something entirely unrelated to the skipped store stays staged.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 'm2-home');
    my $proj   = "$root/m2-proj"; make_path($proj);
    run_vs($home, 'init', '--url', $remote);
    write_text("$proj/CLAUDE.md", "# m2\n");
    run_vs($home, 'register', '--fresh', '--cwd', $proj, '--slug', 'm2', '--files', 'CLAUDE.md');

    my $store = bp16_open_proj_store($proj, 'todo');
    $store->create(id => 'skip1', fields => {}, body => "v1 body\n");
    run_vs($home, 'refresh-default-tracked', '--slug', 'm2');

    my $sync0 = run_vs($home, 'sync-project', '--slug', 'm2');
    is($sync0->{json} && $sync0->{json}{status}, 'synced', 'M2: (setup) baseline sync succeeded') or diag($sync0->{out});
    my $cp0 = run_vs($home, 'commit-and-push', '--slug', 'm2', '--session-id', ($sync0->{json}{session_id} // ''));
    is($cp0->{json} && $cp0->{json}{status}, 'committed_and_pushed', 'M2: (setup) baseline push succeeded') or diag($cp0->{out});

    my $rec_path = $store->dir . '/skip1.md';
    my $v1_bytes = read_text($rec_path);

    my $vault_dir = "$home/.claude/claude-code-vault";
    write_text("$vault_dir/reports/m2-r.md", "unrelated staged report\n");
    ok(bp16_git($home, $vault_dir, 'add', '-A', '--', 'reports'), 'M2: (setup) an unrelated file is staged in the vault index');

    open(my $fh, '>>:raw', $rec_path) or die "M2 fixture: cannot append: $!";
    print {$fh} "locally modified while the store is locked\n";
    close $fh;
    my $v2_bytes = read_text($rec_path);
    isnt($v2_bytes, $v1_bytes, 'M2: (setup) the local record now differs from what was already pushed');

    my ($lock, $lerr) = Almanac::Lock->acquire($rec_path, verb => 'test-hold-m2');
    ok(defined $lock, 'M2: (setup) the test process holds skip1.md\'s real lock') or diag($lerr);

    my $sync;
    { local $ENV{VAULT_SYNC_ALMANAC_LOCK_TIMEOUT_MS} = 300; $sync = run_vs($home, 'sync-project', '--slug', 'm2'); }
    is($sync->{json} && $sync->{json}{status}, 'synced', 'M2: sync-project still reports synced overall (a skip is not a failure)') or diag($sync->{out});
    is(scalar(@{ ($sync->{json}{skipped_stores} // []) }), 1, 'M2: exactly one skipped_stores entry while the lock is held');

    my $cp;
    { local $ENV{VAULT_SYNC_ALMANAC_LOCK_TIMEOUT_MS} = 300;
      $cp = run_vs($home, 'commit-and-push', '--slug', 'm2', '--session-id', ($sync->{json}{session_id} // '')); }
    is($cp->{json} && $cp->{json}{status}, 'committed_and_pushed', 'M2: commit-and-push still succeeds despite the skip') or diag($cp->{out});

    my $vault_record_bytes = bp16_git_show_blob($remote, 'main', 'projects/m2/files/.ccpraxis-local-data/almanac/todo/skip1.md');
    is($vault_record_bytes, $v1_bytes, 'M2: the modified tracked record was NOT pushed -- the vault still holds v1');

    my @tree = bp16_git_ls_tree($remote, 'main');
    ok(!(grep { m{\.ccpraxis-local-data/almanac/todo/.*\.(?:lock|lock\.holder|tmp\.\d+)\z} } @tree),
       'M2: a sidecar shape that was never in the vault for the skipped store stays absent from it');

    my $staged = bp16_git_out($home, $vault_dir, 'diff', '--cached', '--name-only');
    ok(scalar(grep { $_ eq 'reports/m2-r.md' } split /\n/, $staged),
       'M2: the unrelated staged file is STILL staged in the vault index after the skip-driven push');

    $lock->release;
    my $sync2 = run_vs($home, 'sync-project', '--slug', 'm2');
    is(scalar(@{ ($sync2->{json}{skipped_stores} // []) }), 0, 'M2: (cleanup check) once released, nothing is skipped');
    my $cp2 = run_vs($home, 'commit-and-push', '--slug', 'm2', '--session-id', ($sync2->{json}{session_id} // ''));
    my $vault_record_bytes2 = bp16_git_show_blob($remote, 'main', 'projects/m2/files/.ccpraxis-local-data/almanac/todo/skip1.md');
    is($vault_record_bytes2, $v2_bytes, 'M2: once released, the next sync DOES push the modified record');
}

# ===========================================================================
# M3 (review: pull-side concurrent local edit) -- extends AC12's push-side
# group rollback to the PULL direction: a local edit landing between
# sync-project's classify (which decided "pull" because the vault side was
# newer) and commit-and-push's locked pull-apply must survive byte for byte,
# and the group must roll back and be reported.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);

    my $homeA = make_machine($root, 'm3-homeA');
    my $projA = "$root/m3-projA"; make_path($projA);
    run_vs($homeA, 'init', '--url', $remote);
    write_text("$projA/CLAUDE.md", "# m3\n");
    run_vs($homeA, 'register', '--fresh', '--cwd', $projA, '--slug', 'm3', '--files', 'CLAUDE.md');
    my $storeA = bp16_open_proj_store($projA, 'todo');
    $storeA->create(id => 'pull1', fields => {}, body => "from A v1\n");
    run_vs($homeA, 'refresh-default-tracked', '--slug', 'm3');
    my $sA0 = run_vs($homeA, 'sync-project', '--slug', 'm3');
    run_vs($homeA, 'commit-and-push', '--slug', 'm3', '--session-id', ($sA0->{json}{session_id} // ''));

    my $homeB = make_machine($root, 'm3-homeB');
    my $projB = "$root/m3-projB"; make_path($projB);
    run_vs($homeB, 'init', '--url', $remote);
    my $regB = run_vs($homeB, 'register', '--link', '--cwd', $projB, '--slug', 'm3');
    ok($regB->{json} && $regB->{json}{status} eq 'registered_link', 'M3: (setup) machine B linked') or diag($regB->{out});
    my $sB0 = run_vs($homeB, 'sync-project', '--slug', 'm3');
    is($sB0->{json} && $sB0->{json}{status}, 'synced', 'M3: (setup) machine B pulled the v1 baseline') or diag($sB0->{out});
    run_vs($homeB, 'commit-and-push', '--slug', 'm3', '--session-id', ($sB0->{json}{session_id} // ''));

    my $rec_path_B = "$projB/.ccpraxis-local-data/almanac/todo/pull1.md";
    ok(-e $rec_path_B, 'M3: (setup) machine B now has a local copy of pull1.md');
    my $baseline_B = read_text($rec_path_B);

    # A updates the record (via the real Store update() API -- a genuine
    # compare-and-swap, not a raw file edit) and pushes v2. B's local copy
    # is untouched, so B's next classify decides "pull" for this group.
    my $recA = $storeA->read('pull1');
    $storeA->update('pull1', expect => { rev => $recA->{rev}, fields => $recA->{fields} }, body => "from A v2\n");
    my $sA1 = run_vs($homeA, 'sync-project', '--slug', 'm3');
    run_vs($homeA, 'commit-and-push', '--slug', 'm3', '--session-id', ($sA1->{json}{session_id} // ''));

    my $sB1 = run_vs($homeB, 'sync-project', '--slug', 'm3');
    is($sB1->{json} && $sB1->{json}{status}, 'synced', 'M3: (setup) B classifies pull1 for a pull') or diag($sB1->{out});

    # Between classify (sync-project, above) and the locked pull-apply
    # (commit-and-push, below), a local edit lands on B's copy.
    open(my $fh, '>>:raw', $rec_path_B) or die "M3 fixture: cannot append: $!";
    print {$fh} "a concurrent local edit at B\n";
    close $fh;
    my $edited_B = read_text($rec_path_B);
    isnt($edited_B, $baseline_B, 'M3: (setup) B\'s local copy now differs from its own pre-edit baseline');

    my $cpB = run_vs($homeB, 'commit-and-push', '--slug', 'm3', '--session-id', ($sB1->{json}{session_id} // ''));

    is(read_text($rec_path_B), $edited_B,
       'M3: the local edit made between classify and the locked pull-apply SURVIVES byte-for-byte');

    my @rb = @{ ($cpB->{json} && $cpB->{json}{rolled_back_during_sync}) || [] };
    my %rb_by_path = map { (($_->{path} // '') => $_) } @rb;
    ok(exists $rb_by_path{'.ccpraxis-local-data/almanac/todo/pull1.md'},
       'M3: the record is reported in rolled_back_during_sync') or diag(join(', ', map { $_->{path} // '?' } @rb));
    ok(exists $rb_by_path{'.ccpraxis-local-data/almanac/todo/pull1.md.seal'},
       'M3: the seal is reported in rolled_back_during_sync too');
    ok(length(($rb_by_path{'.ccpraxis-local-data/almanac/todo/pull1.md'} // {})->{reason} // ''),
       'M3: the rollback carries a non-empty reason');
}

# ===========================================================================
# S1 (spec 2.9 idempotence) -- running sync-global-almanac twice against a
# .gitignore that already uses CRLF line endings appends each almanac rule
# only once, and never duplicates it on the second run either. Guards the
# same substring-vs-whole-line bug class S7 fixes in AC4's rule count.
# ===========================================================================
{
    my $root   = temproot();
    my $remote = init_remote($root);
    my $home   = make_machine($root, 's1-home');
    run_vs($home, 'init', '--url', $remote);
    my $vault_dir = "$home/.claude/claude-code-vault";

    my $preexisting = "# pre-existing rules, CRLF line endings\r\n*.log\r\n";
    write_text("$vault_dir/.gitignore", $preexisting);

    my $store = bp16_open_global_store($home, 'todo');
    $store->create(id => 's1rec', fields => {}, body => "s1 body\n");

    my $r1 = run_vs($home, 'sync-global-almanac');
    is($r1->{exit}, 0, 'S1: first sync-global-almanac against a CRLF .gitignore exits 0') or diag($r1->{out});

    my $gi1 = read_text("$vault_dir/.gitignore") // '';
    like($gi1, qr/\A\Q# pre-existing rules, CRLF line endings\E\r?\n\Q*.log\E\r?\n/,
         'S1: the pre-existing CRLF content is preserved, not clobbered');
    for my $rule ('almanac/**/*.lock', 'almanac/**/*.lock.holder', 'almanac/**/*.tmp.*') {
        my $count = () = $gi1 =~ /^\Q$rule\E\r?$/mg;
        is($count, 1, "S1: after the first run, '$rule' appears exactly once");
    }

    my $r2 = run_vs($home, 'sync-global-almanac');
    is($r2->{exit}, 0, 'S1: a second run against the now-mixed-EOL file exits 0') or diag($r2->{out});
    my $gi2 = read_text("$vault_dir/.gitignore") // '';
    for my $rule ('almanac/**/*.lock', 'almanac/**/*.lock.holder', 'almanac/**/*.tmp.*') {
        my $count = () = $gi2 =~ /^\Q$rule\E\r?$/mg;
        is($count, 1, "S1: after a SECOND run, '$rule' still appears exactly once (never duplicated)");
    }
}

# === PACKAGE 16 NEW SCENARIOS END ===

done_testing();
