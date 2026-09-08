#!/usr/bin/env perl
# 24-backup-closeout.t -- oracle for blueprint backup-driver, package
# 05-closeout-and-report (scripts/backup/Closeout.pm).
#
# Spec: .ccpraxis-local-data/blueprints/backup-driver/specs/05-closeout-and-report-spec.md
# Scout: .ccpraxis-local-data/blueprints/backup-driver/reports/05-closeout-and-report/scout-step1.md
#
# Written BLIND to any implementation of Closeout.pm: only the spec, the scout
# report, the SHIPPED scripts/backup/Run.pm, the sibling oracles (t/22, t/23)
# and StewardTest.pm were read. scripts/backup/Closeout.pm is not read or
# stubbed by this file, and this file does not create it.
#
# Harness design (t/13/t/20/t/21/t/22/t/23 local-spawner precedent):
#   * `open '-|', $^X, scripts/backup.pl, 'run', @args`, stderr via a real
#     File::Temp file (never an in-memory scalar).
#   * Three stubs (vault-sync.pl, check-plugins.pl, claude-binary-backup.pl)
#     are written into a scratch <home>/.claude/ccpraxis install at the exact
#     paths Closeout.pm resolves. Each stub's first action is to append its
#     own name + full @ARGV to $ENV{CLOSEOUT_TEST_LOG} -- the call-count /
#     call-order / argv oracle. Each stub then copies a per-(subcommand,
#     call-index) fixture FILE from $ENV{CLOSEOUT_TEST_FIXTURE_DIR} to stdout
#     VERBATIM (:raw, no JSON re-encode) -- this is what makes non-ASCII
#     fixtures byte-exact end to end. A fixture body may be prefixed
#     "EXIT:<n>\n" (non-zero exit), "UNPARSEABLE\n" (junk stdout) or
#     "SIGNAL\n" (the stub kills itself); an absent stub file simulates
#     "cannot spawn" (S8).
#   * The skip marker is NOT a script: fixtures create/omit
#     "<cwd>/.claude/backup-skip" directly on disk.
#   * Cross-phase fixtures (preflight/export/vault outcomes) are seeded by
#     hand-writing a run-state file (the t/21 AC20 / t/22 AC27 / t/23
#     "state-file surgery" precedent) -- BACKUP_PHASE_DIR holds ONLY
#     Closeout.pm, so "preflight"/"export"/"vault" are never discovered or
#     executing phases; get_phase_item reads $state->{phases}{OTHER} as a
#     plain (possibly-absent) hash key regardless.
#   * "cwd" matters here (unlike any earlier phase): Closeout.pm resolves
#     Cwd::cwd() itself (B2), so every scenario chdir()s into a dedicated
#     scratch directory before spawning backup.pl and chdir()s back
#     immediately after -- verified empirically on this host (raw \xNN UTF-8
#     bytes survive chdir()/getcwd()/a spawned child's own Cwd::cwd() call
#     byte-for-byte, both under ASCII and non-ASCII scratch roots).
#   * Non-ASCII fixtures: built from raw \xNN byte literals in THIS file's
#     source (never `use utf8`, never a literal non-ASCII source character),
#     verified by raw substring search against UNDECODED bytes of stdout, the
#     state file and the argv log -- never merely decode_json()+string-eq,
#     which would hide a double-encode.
#
# AC -> test name mapping (grep "AC<n>:" for every assertion of a given
# criterion; several criteria share one scenario the way t/23 does):
#   AC1  phase_spec via direct require, no engine: name/order/resumable/title,
#        no truthy crash_preserves_items
#   AC2  perl -c clean on Closeout.pm and this file
#   AC3  MEGA scenario: unregistered+marker-absent+trackable non-empty ->
#        exactly one project_registration decision, 3 choices, exit 10,
#        resume_token present
#   AC4  unregistered + trackable EMPTY -> zero decisions, exit 0, offered
#        false, trackable_paths == []
#   AC5  unregistered + marker PRESENT -> zero decisions, detect-trackable
#        never spawned, skip_marker fields, registration_skip_marker note
#   AC6  registered:true -> zero decisions, registered+slug reported,
#        detect-trackable never spawned
#   AC7  MEGA scenario resume(register_now) -> follow_up_actions has
#        invoke_setup_project with the pinned cwd; no file created under cwd;
#        vault-sync.pl register never spawned
#   AC8  dont_ask_again -> follow_up_actions has create_skip_marker; marker
#        file does NOT exist on disk afterwards
#   AC9  PLUGINS scenario: missing_plugins status, exit 1, 2 missing entries
#        -> exactly 2 decisions in ONE needs_decision batch, kind
#        plugin_install, ids closeout.plugin_install.<san>, choices
#        install/skip; exit 1 is NOT a unit failure
#   AC10 status ok / no_config -> zero decisions/follow-ups;
#        missing_marketplaces -> add_marketplace follow-ups + note, zero
#        decisions; extra_installed reported, no follow-up
#   AC11 aggregate: every decision seen anywhere validates against
#        Backup::Run::validate_decision(phase=>closeout), kind in exactly
#        {project_registration, plugin_install}; static scan for any other
#        @Backup::Run::DECISION_KINDS literal
#   AC12 MEGA (present) + ABSENT scenario: sources all "present"/all "absent",
#        spot-checked mapped fields, never rendered as empty/success
#   AC13 the single aggregate HASH/ARRAY/CODE/GLOB/SCALAR/Regexp(0x...) regex
#        over every scenario's raw stdout+state bytes collected in this file;
#        trackable_paths exact array; missing_names; preferences.applied[0].key
#   AC14 MEGA vault_projects: 3 statuses -> synced/errored/conflicted, one
#        not_reached/skipped (no project.<tok> item), one unrecognised ->
#        errored with raw status preserved
#   AC15 SNAPSHOTS scenario: count 3 -> newest_id/version; count 0 -> nulls,
#        error null; corrupt newest (manifest null) -> no die; revert_command
#        exact string
#   AC16 EXEC-COUNT scenario: pause+resume, each of the four scripts spawned
#        exactly once across BOTH invocations combined
#   AC17 NON-ASCII CWD scenario: byte-identical --cwd argv, marker probe at
#        the byte-exact path, report cwd byte-identical in stdout+state,
#        survives pause/resume (pinned cwd, B10)
#   AC18 non-ASCII on the other 3 axes: trackable[].path (MEGA), plugin key
#        (PLUGINS), snapshot manifest.version (SNAPSHOTS) -- each independent
#   AC19 CANARY scenario: a cross-phase value never reaches any child argv;
#        positive allow-list check on every logged --cwd/--settings/
#        --installed/--marketplaces value
#   AC20 MUTATES-NOTHING scenario: full scratch-tree snapshot before/after;
#        static scan for filesystem-mutating / git / network operations in
#        Closeout.pm's own source
#   AC21 SIGNAL scenario: a signal-killed check-plugins.pl is not exit 0;
#        plugins.error set, unit_failures.plugins set, phase failed (exit 20)
#   AC22 THREE-OUTCOMES scenario: unspawnable / exit-2 / exit-0-unparseable
#        each produce a DIFFERENT unit_failures.registration message; none
#        reads as "not registered"; none decides; none dies
#   AC23 ENVIRONMENT scenario: HOME/USERPROFILE unset, and $root absent ->
#        exit 20 (never 1/phase_died), report note still present
#   AC24 report structure: hashref, every required top-level key present
#        (including the all-failed path), schema_version==1, no markdown
#        bullet/heading markers in any value
#   AC25 ALL-FAILED scenario: exit 20, report note present, unit_failures
#        names each failed unit; DUPNOTE scenario: the last report note wins
#   AC26 PARITY scenario: four-column header+separator, one row per
#        5.7/6/6.6/7, phase/module cells fixed, exactly 4 cells per row
#   AC27 ISOLATION: real HOME/USERPROFILE captured before any override; no
#        scratch path equals or is derived from them
#
# Extra coverage requested by the dispatch, beyond the numbered ACs:
#   - static scan: Closeout.pm requires/uses none of Run.pm/Preflight.pm/
#     Export.pm/Vault.pm
#   - a vault.project_list entry that is not a hashref, or is missing 'tok',
#     is skipped without dying (the Vault.pm MAJOR 4 lesson, applied here)

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Cwd ();
use File::Path qw(make_path);
use File::Find qw(find);
use File::Temp qw(tempfile);
use JSON::PP;
use Encode qw(decode FB_CROAK);
use StewardTest qw(ok is like unlike diag done_testing temproot make_machine write_text read_text path_exists);

my $CLOSEOUT_SRC  = "$Bin/../../../../scripts/backup/Closeout.pm";
my $RUNPM         = "$Bin/../../../../scripts/backup/Run.pm";
my $BACKUP_SCRIPT = "$Bin/../../../../scripts/backup.pl";
my $PARITY_FILE   = "$Bin/../../../../.ccpraxis-local-data/blueprints/backup-driver/reports/parity/05-closeout-and-report.md";

sub isnt {
    my ($got, $exp, $name) = @_;
    my $cond = !((defined $got && defined $exp && $got eq $exp) || (!defined $got && !defined $exp));
    ok($cond, $name) or diag("  got:          " . (defined $got ? "[$got]" : "undef")
                           . "\n  expected NOT: " . (defined $exp ? "[$exp]" : "undef"));
    return $cond;
}

my $CLOSEOUT_EXISTS = -f $CLOSEOUT_SRC ? 1 : 0;
ok($CLOSEOUT_EXISTS, 'scripts/backup/Closeout.pm exists on disk')
    or diag('scripts/backup/Closeout.pm is absent -- every behavioral test below will fail for this reason');
ok(-f $RUNPM, 'scripts/backup/Run.pm exists on disk (package 01, shipped)');
ok(-f $BACKUP_SCRIPT, 'scripts/backup.pl exists on disk (package 01, shipped)');

my $RUNPM_OK = 0;
{
    local $@;
    $RUNPM_OK = eval { require $RUNPM; 1 };
    diag("Run.pm did not load cleanly: " . ($@ || 'unknown error')) unless $RUNPM_OK;
}

my $CLOSEOUT_LOADED = 0;
if ($CLOSEOUT_EXISTS) {
    local $@;
    $CLOSEOUT_LOADED = eval { require $CLOSEOUT_SRC; 1 };
    diag("Closeout.pm did not load cleanly: " . ($@ || 'unknown error')) unless $CLOSEOUT_LOADED;
}

# The operator's real HOME/USERPROFILE, captured before ANY scenario overrides
# them -- AC27's isolation oracle.
my $REAL_HOME        = $ENV{HOME};
my $REAL_USERPROFILE = $ENV{USERPROFILE};

# Running tallies used by the aggregate checks near the end of this file.
my @ALL_DECISIONS_SEEN;
my @ALL_STDOUT_RAW;
my @ALL_STATE_RAW;
sub record_decisions { push @ALL_DECISIONS_SEEN, @_; }

# ===========================================================================
# AC2 -- perl -c is clean on both files, compiled standalone by THIS test.
# ===========================================================================
sub _compile_check {
    my ($file, $label) = @_;
    unless (-f $file) {
        ok(0, "AC2: perl -c is clean on $label (file not found)");
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
    ok($rc == 0, "AC2: perl -c exits 0 for $label") or diag($err);
    unlike($err, qr/syntax error|Compilation failed/, "AC2: perl -c on $label reports no syntax error / compilation failure")
        or diag($err);
}
_compile_check($CLOSEOUT_SRC, 'scripts/backup/Closeout.pm');
_compile_check("$Bin/24-backup-closeout.t", 'plugins/steward/tests/t/24-backup-closeout.t (this file)');

# ===========================================================================
# AC1 -- phase_spec, requiring the module directly (as a property of
# Closeout.pm's OWN source, verified separately by the static scan below --
# not by whether THIS test process happens to have Run.pm loaded).
# ===========================================================================
{
    if ($CLOSEOUT_LOADED) {
        my $spec = eval { Backup::Phase::Closeout::phase_spec() };
        if (ref($spec) eq 'HASH') {
            is($spec->{name}, 'closeout', 'AC1: phase_spec name == closeout');
            is($spec->{order} + 0, 400, 'AC1: phase_spec order == 400');
            ok($spec->{resumable} ? 1 : 0, 'AC1: phase_spec resumable is true');
            ok(defined($spec->{title}) && length($spec->{title}), 'AC1: phase_spec has a non-empty title');
            ok(!$spec->{crash_preserves_items}, 'AC1: phase_spec has no truthy crash_preserves_items (deliberately not declared)');
        } else {
            ok(0, "AC1: phase_spec name == closeout ($@)");
            ok(0, 'AC1: phase_spec order == 400');
            ok(0, 'AC1: phase_spec resumable is true');
            ok(0, 'AC1: phase_spec has a non-empty title');
            ok(0, 'AC1: phase_spec has no truthy crash_preserves_items');
        }
    } else {
        ok(0, 'AC1: phase_spec name == closeout (Closeout.pm did not load)');
        ok(0, 'AC1: phase_spec order == 400 (Closeout.pm did not load)');
        ok(0, 'AC1: phase_spec resumable is true (Closeout.pm did not load)');
        ok(0, 'AC1: phase_spec has a non-empty title (Closeout.pm did not load)');
        ok(0, 'AC1: phase_spec has no truthy crash_preserves_items (Closeout.pm did not load)');
    }
}

# ===========================================================================
# Static source scan: no engine require, no other phase require, no literal
# git invocation, no decision-kind literal other than the two permitted ones
# (AC11 static half), and AC20's mutation scan (no filesystem-mutating /
# system / network primitive anywhere in Closeout.pm's own source).
# ===========================================================================
{
    my $src = $CLOSEOUT_EXISTS ? (read_text($CLOSEOUT_SRC) // '') : '';

    if ($CLOSEOUT_EXISTS) {
        for my $forbidden (qw(Run.pm Preflight.pm Export.pm Vault.pm)) {
            (my $re_name = $forbidden) =~ s/\./\\./;
            unlike($src, qr/\b(?:use|require)\s+["']?(?:[\w:]*[\\\/])?\Q$forbidden\E["']?/,
                "AC1: Closeout.pm source contains no use/require of $forbidden");
        }
        unlike($src, qr/(['"])git\1/, 'AC20: Closeout.pm source contains no quoted "git" literal');

        ok($RUNPM_OK, 'AC11: Run.pm (for @Backup::Run::DECISION_KINDS) loaded for the source scan')
            or diag('cannot enumerate the closed kind set without Run.pm');
        if ($RUNPM_OK) {
            my %permitted = (project_registration => 1, plugin_install => 1);
            for my $kind (Backup::Run::DECISION_KINDS()) {
                next if $permitted{$kind};
                unlike($src, qr/(['"])\Q$kind\E\1/, "AC11: Closeout.pm source contains no decision-kind literal '$kind'");
            }
            like($src, qr/project_registration/, "AC11: Closeout.pm source DOES contain 'project_registration'");
            like($src, qr/plugin_install/, "AC11: Closeout.pm source DOES contain 'plugin_install'");
        }

        # AC20 -- no filesystem-mutating / process-spawning primitive of its
        # own. (_run_capture's list-form open '-|' for READING a child's
        # stdout is fine and expected; so is its OWN mandated (spec S2.9)
        # File::Temp stderr-capture dance -- `open(STDERR, '>', $ename)` /
        # `unlink $ename` against a bare File::Temp::tempfile() lexical are
        # not a mutation of anything durable, and are explicitly excluded
        # from AC20's own dynamic scratch-tree-snapshot check ("File::Temp
        # artefacts already removed"). NOTE (untestable-as-literally-written,
        # reported per the dispatch instructions): S4's AC20 text names a
        # blanket "no open .../no unlink" static scan, but S2.9 simultaneously
        # mandates verbatim duplication of _run_capture, which itself must
        # contain exactly that idiom -- no implementation can satisfy both a
        # literal blanket ban and S2.9 at once. Narrowed here to catch a
        # WRITE-mode open or unlink whose TARGET is a literal/interpolated
        # STRING (a real path -- $home/$root/$cwd derived or hard-coded),
        # while tolerating a write-mode open/unlink against a bare lexical
        # scalar (the File::Temp idiom). The dynamic full-tree snapshot below
        # remains the authoritative "mutates nothing" oracle regardless.
        unlike($src, qr/open\s*\([^;]*?,\s*["']>{1,2}["']\s*,\s*["']/s,
            'AC20: Closeout.pm source contains no write-mode open targeting a literal/interpolated path string');
        unlike($src, qr/\bunlink\s*\(?\s*["']/,
            'AC20: Closeout.pm source contains no unlink(...) targeting a literal/interpolated path string');
        for my $sub (qw(mkdir make_path rename remove_tree symlink chmod truncate)) {
            unlike($src, qr/\b\Q$sub\E\s*\(/, "AC20: Closeout.pm source contains no $sub(...) call");
        }
        unlike($src, qr/\bsystem\s*\(/, 'AC20: Closeout.pm source contains no system(...) call');
        unlike($src, qr/\bqx\s*[\/\{\(\[]/, 'AC20: Closeout.pm source contains no qx// backtick-equivalent');
        unlike($src, qr/\`[^\`]*\`/, 'AC20: Closeout.pm source contains no literal backtick string');
    } else {
        ok(0, "AC1: Closeout.pm source contains no use/require of $_") for qw(Run.pm Preflight.pm Export.pm Vault.pm);
        ok(0, 'AC20: Closeout.pm source contains no quoted "git" literal');
        ok(0, 'AC11: every non-permitted decision-kind literal is absent (Closeout.pm not found)');
        ok(0, 'AC20: Closeout.pm source contains no write-mode open targeting a literal/interpolated path string (Closeout.pm not found)');
        ok(0, 'AC20: Closeout.pm source contains no unlink(...) targeting a literal/interpolated path string (Closeout.pm not found)');
        ok(0, "AC20: Closeout.pm source contains no $_(...) call (Closeout.pm not found)")
            for qw(mkdir make_path rename remove_tree symlink chmod truncate system);
        ok(0, 'AC20: Closeout.pm source contains no qx// backtick-equivalent (Closeout.pm not found)');
        ok(0, 'AC20: Closeout.pm source contains no literal backtick string (Closeout.pm not found)');
    }
}

# ===========================================================================
# Non-ASCII byte constants -- raw \xNN literals, never `use utf8`, never a
# literal non-ASCII source character. \xC3\xA9 is the two-byte UTF-8
# encoding of U+00E9 (e-acute).
# ===========================================================================
my $EACUTE = "\xC3\xA9";

# widen_bytes($raw_utf8_bytes) -> the CHARACTER-space (decoded) equivalent,
# for comparison against anything that passed through decode_json (see the
# BYTE/CHARACTER SPACE note above set_fixture). IMPORTANT: never call
# Encode::decode(..., FB_CROAK()) directly on a variable you still need --
# with a true CHECK argument, decode() overwrites its SECOND ARGUMENT IN
# PLACE (a well-documented Encode gotcha: after the call the original is
# left holding only the unconsumed remainder, typically ''). `my ($b) = @_`
# below already copies, so widen_bytes() is safe to call on any raw-bytes
# variable without silently emptying it.
sub widen_bytes {
    my ($b) = @_;
    return decode('UTF-8', $b, FB_CROAK());
}
# CHARACTER-space counterpart (see the BYTE/CHARACTER SPACE note above
# set_fixture): the same code point, decoded, for comparisons against
# anything that passed through decode_json (i.e. anything read via
# $resp->{json} or a decisions/notes structure derived from it).
my $EACUTE_WIDE = widen_bytes($EACUTE);

# S2.10 point 3's global invariant, promoted to file scope so both the
# aggregate AC13 check (near file end) and ITEM3's dedicated scenario share
# EXACTLY the same pattern.
my $STRINGIFIED_REF_RE = qr/\b(?:HASH|ARRAY|CODE|GLOB|SCALAR|Regexp)\(0x[0-9a-fA-F]+\)/;

# ===========================================================================
# Stub wrapped scripts. Each logs its own name + full @ARGV to
# $ENV{CLOSEOUT_TEST_LOG} as its FIRST action, then serves a per-(key,
# call-index) fixture FILE from $ENV{CLOSEOUT_TEST_FIXTURE_DIR} verbatim
# (:raw, byte-exact, no JSON re-encode). "key" is the subcommand for
# vault-sync.pl (is-registered / detect-trackable), "list" for
# claude-binary-backup.pl, and the script's own basename for check-plugins.pl
# (whose argv has no bare subcommand).
# ===========================================================================
my $GENERIC_STUB_TEMPLATE = <<'PERL';
use strict;
use warnings;
my $SCRIPT_NAME = '___SCRIPT_NAME___';
my $log = $ENV{CLOSEOUT_TEST_LOG};
if (defined $log && length $log) {
    open my $lfh, '>>:raw', $log or die "cannot append to log: $!";
    print {$lfh} "$SCRIPT_NAME @ARGV\n";
    close $lfh;
}
my $cmd = (@ARGV && $ARGV[0] !~ /^--/) ? $ARGV[0] : '';
my $dir = $ENV{CLOSEOUT_TEST_FIXTURE_DIR};
unless (defined $dir && length $dir) {
    print '{"status":"error","error":"closeout test stub: no fixture dir configured"}';
    exit 1;
}
my $key = length($cmd) ? $cmd : $SCRIPT_NAME;
my $ctr_file = "$dir/.ctr.$key";
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
for my $cand ("$dir/$key.$n.resp", "$dir/$key.resp") {
    if (-f $cand) { $resp_file = $cand; last; }
}
unless (defined $resp_file) {
    print '{"status":"error","error":"closeout test stub: no fixture for key=' . $key . ' call=' . $n . '"}';
    exit 1;
}
open my $rfh, '<:raw', $resp_file or die "cannot read resp: $!";
local $/; my $body = <$rfh>; close $rfh;
if ($body =~ /\ASIGNAL\n/) {
    kill 'KILL', $$;
    exit 9;   # unreachable on this host, kept as a defensive fallback
}
if ($body =~ /\AEXIT:(-?\d+)\n(.*)\z/s) {
    print $2;
    exit $1 + 0;
}
if ($body =~ /\AUNPARSEABLE\n(.*)\z/s) {
    print (length($1) ? $1 : "not-json-{{{");
    exit 0;
}
if ($body =~ /\ASTDERRWARN:([^\n]*)\n(.*)\z/s) {
    print STDERR "$1\n";
    print $2;
    exit 0;
}
print $body;
exit 0;
PERL

sub _stub_for {
    my ($script_name) = @_;
    (my $t = $GENERIC_STUB_TEMPLATE) =~ s/___SCRIPT_NAME___/$script_name/;
    return $t;
}

sub write_stub_scripts {
    my ($root) = @_;
    write_text("$root/plugins/steward/scripts/vault-sync.pl", _stub_for('vault-sync.pl'));
    write_text("$root/plugins/steward/scripts/check-plugins.pl", _stub_for('check-plugins.pl'));
    write_text("$root/plugins/steward/scripts/claude-binary-backup.pl", _stub_for('claude-binary-backup.pl'));
}

sub copy_closeout_into {
    my ($phase_dir) = @_;
    make_path($phase_dir);
    return 0 unless $CLOSEOUT_EXISTS;
    write_text("$phase_dir/Closeout.pm", read_text($CLOSEOUT_SRC));
    return 1;
}

# ===========================================================================
# BYTE/CHARACTER SPACE, stated once (coordinator ruling on this file, matching
# P17): every non-ASCII literal in this file ($EACUTE and anything built from
# it) is RAW UTF-8 BYTES, never a decoded Perl character string. Two spaces
# exist and must never be mixed:
#   - BYTE space: raw stdout text ($resp->{out}, @ALL_STDOUT_RAW), raw state-
#     file text (@ALL_STATE_RAW), and the stub argv log -- none of these are
#     ever decode_json()'d by this file, so a raw-byte literal is compared
#     directly (eq/index) against them, correctly.
#   - CHARACTER space: any value read back out of $resp->{json} (decode_json
#     ALWAYS treats its input as UTF-8 bytes and decodes to characters --
#     that is what backup.pl's stdout legitimately contains, since a report
#     field that started as raw UTF-8 bytes round-trips through JSON::PP's
#     encoder-with-no->utf8 unchanged). A raw-byte literal must be
#     Encode::decode('UTF-8', ..., FB_CROAK())'d into this space before it is
#     compared against a decoded structure (hash values, decision fields) --
#     see $EACUTE_WIDE below and its per-scenario *_wide siblings.
# set_fixture() itself writes in BYTE space throughout: JSON::PP's encoder is
# called WITHOUT ->utf8 (matching backup.pl's own convention, S1.8), so a raw-
# byte $EACUTE embedded in fixture data is written to disk unchanged -- never
# re-encoded, which is what a bare ->utf8->encode on already-raw bytes did
# before this fix (each byte re-interpreted as a Latin-1 codepoint and
# UTF-8-encoded AGAIN, corrupting the fixture before Closeout.pm ever read it).
#
# ===========================================================================
# Fixture helpers.
# ===========================================================================
sub set_fixture {
    my ($fx_dir, $name, $data, %opts) = @_;
    make_path($fx_dir);
    my $body;
    if ($opts{signal}) {
        $body = "SIGNAL\n";
    } elsif ($opts{unparseable}) {
        $body = "UNPARSEABLE\n" . (defined $opts{unparseable_body} ? $opts{unparseable_body} : 'not-json-{{{');
    } elsif ($opts{stderr_warn}) {
        my $inner = ref($data) ? JSON::PP->new->canonical->encode($data) : $data;
        $body = "STDERRWARN:$opts{stderr_warn}\n$inner";
    } else {
        $body = ref($data) ? JSON::PP->new->canonical->encode($data) : $data;
        $body = "EXIT:$opts{exit}\n$body" if defined $opts{exit};
    }
    write_text("$fx_dir/$name", $body);
}

sub fixture_name {
    my ($key, $idx) = @_;
    return defined($idx) ? "$key.$idx.resp" : "$key.resp";
}

sub mk_is_registered {
    my (%o) = @_;
    my $h = { registered => ($o{registered} ? JSON::PP::true : JSON::PP::false), cwd => $o{cwd} };
    $h->{slug} = $o{slug} if exists $o{slug};
    return $h;
}
sub mk_detect_trackable {
    my (%o) = @_;
    return { cwd => $o{cwd}, trackable => ($o{trackable} // []) };
}
sub mk_trackable_entry {
    my (%o) = @_;
    return { path => $o{path}, type => ($o{type} // 'file'), size => ($o{size} // 10) + 0,
             exists => JSON::PP::true };
}
sub mk_plugin_entry {
    my (%o) = @_;
    return { plugin => $o{plugin}, name => $o{name}, marketplace => $o{marketplace},
             installed => ($o{installed} ? JSON::PP::true : JSON::PP::false),
             marketplace_registered => ($o{marketplace_registered} ? JSON::PP::true : JSON::PP::false) };
}
sub mk_check_plugins {
    my (%o) = @_;
    return { status => $o{status}, enabled => ($o{enabled} // []), missing => ($o{missing} // []),
             missing_marketplaces => ($o{missing_marketplaces} // []),
             extra_installed => ($o{extra_installed} // []) };
}
sub mk_manifest {
    my (%o) = @_;
    return { manifest_version => 1, id => $o{id}, version => $o{version}, source_path => 'C:/fake/claude.exe',
             sha256 => 'deadbeef', size => 100, os => 'MSWin32', captured_at_utc => ($o{captured_at_utc} // '2026-09-01T00:00:00Z'),
             binary_filename => 'claude.exe' };
}
sub mk_snapshot_entry {
    my (%o) = @_;
    return { id => $o{id}, path => ($o{path} // "/snap/$o{id}"), corrupt => ($o{corrupt} ? JSON::PP::true : JSON::PP::false),
             manifest => (exists $o{manifest} ? $o{manifest} : mk_manifest(id => $o{id}, version => ($o{version} // '1.0.0'))) };
}
sub mk_snapshot_list {
    my (%o) = @_;
    return { status => ($o{status} // 'ok'), count => $o{count}, snapshots => ($o{snapshots} // []) };
}

# ===========================================================================
# Scenario scaffold.
# ===========================================================================
sub setup_root {
    my (%opts) = @_;
    my $scratch = temproot();
    my $home    = make_machine($scratch, $opts{machine_name} // 'host');
    my $root    = "$home/.claude/ccpraxis";
    make_path("$root/plugins/steward/scripts");
    make_path("$root/global-config");
    make_path("$home/.claude/plugins");

    write_stub_scripts($root);

    my $phase_dir = "$scratch/phases";
    copy_closeout_into($phase_dir);

    my $fixture_dir = "$scratch/fixtures";
    make_path($fixture_dir);

    my $cwd = $opts{cwd} // "$scratch/proj";
    make_path($cwd) unless -d $cwd;

    return {
        scratch     => $scratch,
        home        => $home,
        root        => $root,
        phase_dir   => $phase_dir,
        fixture_dir => $fixture_dir,
        state_path  => "$scratch/state/run.json",
        log_path    => "$scratch/log.txt",
        cwd         => $cwd,
    };
}

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
        HOME                      => $r->{home},
        USERPROFILE               => $r->{home},
        BACKUP_RUN_STATE          => $r->{state_path},
        BACKUP_PHASE_DIR          => $r->{phase_dir},
        CLOSEOUT_TEST_LOG         => $r->{log_path},
        CLOSEOUT_TEST_FIXTURE_DIR => $r->{fixture_dir},
    );
    for my $k (keys %extra) { $env{$k} = $extra{$k}; }
    return \%env;
}

# run_backup: chdir()s into $r->{cwd} (Cwd::cwd() is what Closeout.pm's B2
# resolves), spawns, then chdir()s back -- always, even on error.
sub run_backup {
    my ($r, $extra_env, @args) = @_;
    my $env = scenario_env($r, %{ $extra_env // {} });
    my $orig = Cwd::getcwd();
    if (defined $r->{cwd}) {
        chdir($r->{cwd}) or die "cannot chdir to $r->{cwd}: $!";
    }
    my $resp = eval { _spawn($env, 'run', @args) };
    my $err = $@;
    if (defined $r->{cwd}) {
        chdir($orig) or warn "cannot chdir back to $orig: $!";
    }
    die $err if $err;
    push @ALL_STDOUT_RAW, $resp->{out} if defined $resp->{out};
    return $resp;
}

sub answer_and_resume {
    my ($r, $resp, %answers) = @_;
    my $token = $resp->{json}{resume_token};
    my @args = ('--resume', $token);
    for my $id (sort keys %answers) { push @args, '--answer', "$id=$answers{$id}"; }
    return run_backup($r, {}, @args);
}

sub read_state {
    my ($path) = @_;
    my $raw = read_text($path);
    return undef unless defined $raw;
    push @ALL_STATE_RAW, $raw;
    return eval { decode_json($raw) };
}

sub write_state_raw {
    my ($path, $data) = @_;
    my $json = JSON::PP->new->canonical->pretty->encode($data);
    write_text($path, $json);
}

# seed_state -- Contract-C-shaped run-state, hand-written so preflight/export/
# vault outcomes can be seeded WITHOUT those modules ever being discovered
# phases (BACKUP_PHASE_DIR holds only Closeout.pm). get_phase_item reads
# $state->{phases}{OTHER} as a plain, possibly-absent hash key.
sub seed_state {
    my (%opts) = @_;
    my $now = time;
    my $state = {
        format       => 1,
        run_id       => ($opts{run_id} // 'deadbeefcafef00d'),
        started_at   => $now,
        updated_at   => $now,
        status       => ($opts{status} // 'running'),
        phase_order  => ['closeout'],
        phase_index  => 0,
        phases       => {
            closeout => {
                status => ($opts{closeout_status} // 'pending'), started_at => undef, completed_at => undef,
                error => undef, items => ($opts{closeout_items} // {}), scratch => {},
            },
        },
        token_seq    => ($opts{token_seq} // 0),
        consumed_seq => ($opts{consumed_seq} // 0),
        pending      => ($opts{pending} // undef),
        answers      => ($opts{answers} // {}),
        notes        => ($opts{notes} // []),
    };
    for my $phase (qw(preflight export vault)) {
        my $items_key = "${phase}_items";
        if (exists $opts{$items_key}) {
            my $src = $opts{$items_key};
            my %items;
            if (defined $src) {
                %items = map { $_ => { at => $now, data => $src->{$_} } } keys %$src;
            }
            $state->{phases}{$phase} = {
                status => 'complete', started_at => $now, completed_at => $now, error => undef,
                items => \%items, scratch => {},
            } if defined $src;
        }
    }
    return $state;
}

sub log_lines {
    my ($log_path) = @_;
    my $raw = read_text($log_path);
    return () unless defined $raw;
    return grep { length $_ } split /\n/, $raw;
}
sub log_line_count { return scalar(log_lines($_[0])); }
sub count_matching { my ($log_path, $re) = @_; return scalar(grep { /$re/ } log_lines($log_path)); }

sub decisions_of { my ($resp) = @_; return @{ $resp->{json}{decisions} // [] }; }
sub find_decision { my ($decisions, $id) = @_; for my $d (@$decisions) { return $d if ($d->{id} // '') eq $id; } return undef; }
sub choice_ids { my ($d) = @_; return map { $_->{id} } @{ $d->{choices} // [] }; }
sub has_choice { my ($d, $id) = @_; return (grep { $_ eq $id } choice_ids($d)) ? 1 : 0; }

sub report_from_notes {
    my ($notes) = @_;
    my $r;
    for my $n (@{ $notes // [] }) {
        $r = $n->{value} if ref($n) eq 'HASH' && (($n->{key} // '') eq 'report');
    }
    return $r;
}
sub find_note { my ($notes, $key) = @_; for my $n (@{ $notes // [] }) { return $n if ref($n) eq 'HASH' && (($n->{key} // '') eq $key); } return undef; }
sub find_all_notes { my ($notes, $key) = @_; return grep { ref($_) eq 'HASH' && (($_->{key} // '') eq $key) } @{ $notes // [] }; }

# snapshot_tree($root) -> { path => { size => N, mtime => N }, ... }
# COORDINATOR ITEM 5: the original returned PATHS ONLY and every caller diffed
# ONE direction (new files only), so an in-place modification (same path,
# different bytes/mtime, e.g. a truncate+rewrite that leaves the file's own
# existence unchanged) or a deletion (a path present before and silently
# gone after) was invisible to this oracle. This is what the spec's own
# AC20 text asks for verbatim: "a recursive snapshot (path -> size -> mtime)
# taken before and after". Callers must diff BOTH directions (added AND
# removed keys) and additionally compare size/mtime for every path present
# in both snapshots.
sub snapshot_tree {
    my ($root) = @_;
    return {} unless -d $root;
    my %snap;
    find({ wanted => sub {
        return unless -f $_;
        my @st = stat($_);
        $snap{$File::Find::name} = { size => $st[7], mtime => $st[9] };
    }, no_chdir => 1 }, $root);
    return \%snap;
}

# _ac20_excluded($path, $r) -- the deliberate, documented exclusion list: the
# run-state file (Contract C's sole durable side effect), the stubs' own
# argv-log file, and the stubs' own per-fixture call-counter files. Nothing
# else may legitimately change.
sub _ac20_excluded {
    my ($path, $r) = @_;
    return 1 if $path eq $r->{state_path};
    return 1 if $path eq $r->{log_path};
    return 1 if $path =~ /\.ctr\./;
    return 0;
}

# assert_tree_unchanged($before, $after, $r, $label) -- diffs BOTH
# directions (added and removed paths) plus an in-place-modification check
# (size/mtime) for every path common to both snapshots, all against the
# SAME exclusion list.
sub assert_tree_unchanged {
    my ($before, $after, $r, $label) = @_;
    my @added   = grep { !exists $before->{$_} } keys %$after;
    my @removed = grep { !exists $after->{$_} }  keys %$before;
    my @unexpected_added   = grep { !_ac20_excluded($_, $r) } @added;
    my @unexpected_removed = grep { !_ac20_excluded($_, $r) } @removed;
    is(scalar(@unexpected_added), 0, "$label: no unexpected file was CREATED anywhere under the scratch root")
        or diag('created: ' . join(', ', @unexpected_added));
    is(scalar(@unexpected_removed), 0, "$label: no file was DELETED anywhere under the scratch root")
        or diag('deleted: ' . join(', ', @unexpected_removed));

    my @modified;
    for my $path (keys %$before) {
        next unless exists $after->{$path};
        next if _ac20_excluded($path, $r);
        my ($b, $a) = ($before->{$path}, $after->{$path});
        push @modified, "$path (size $b->{size}->$a->{size}, mtime $b->{mtime}->$a->{mtime})"
            if $b->{size} != $a->{size} || $b->{mtime} != $a->{mtime};
    }
    is(scalar(@modified), 0, "$label: no file under the scratch root was modified in place (size and mtime both unchanged)")
        or diag('modified: ' . join('; ', @modified));
}

# _mint_ids mirror (spec S2.11): sanitiser applied to a single, non-colliding
# key. Scaffolding only -- NOT a copy of Closeout.pm's own implementation.
sub expected_mint_id {
    my ($prefix, $key) = @_;
    (my $san = $key) =~ s/[^A-Za-z0-9_.:-]/_/g;
    $san = '_' unless length $san;
    return length($prefix) ? "$prefix.$san" : $san;
}

my @REQUIRED_REPORT_KEYS = qw(
    schema_version run_id phase sources ccpraxis_sync marketplaces preferences
    vault_projects current_project_registration plugins snapshots
    follow_up_actions unit_failures degraded
);

sub assert_required_report_keys {
    my ($report, $label) = @_;
    unless (ref($report) eq 'HASH') {
        ok(0, "$label: report is a hashref");
        return;
    }
    ok(1, "$label: report is a hashref");
    for my $k (@REQUIRED_REPORT_KEYS) {
        ok(exists $report->{$k}, "$label: report has required top-level key '$k'");
    }
}

# ===========================================================================
# COORDINATOR ITEM 1 -- a numeric report field (S2.5's snapshots.count : <int>,
# and other numerically-valued fields such as trackable[].size and a per-
# project detail.applied count) must be JSON-ENCODED AS A BARE NUMBER, never
# a quoted string. This is a JSON-TYPE check, not a value check: comparing a
# decoded Perl scalar with `is($got + 0, $expected, ...)` (as this file
# originally did) coerces "3" and 3 to the same comparison and CANNOT see a
# defect where every number that round-trips through _widen_utf8/_gi/_gpi
# comes back PV-only (a JSON::PP encoder with no ->utf8, per backup.pl:71 and
# S1.8, then serialises that PV as a quoted string). backup.pl's own encoder
# is JSON::PP->new->canonical->encode (compact, no ->pretty), so a bare
# number is byte-adjacent to its neighbouring key with no intervening quotes
# or whitespace -- checked here directly against the RAW stdout bytes
# ($resp->{out}), never against the decode_json()'d structure, which is
# exactly the byte/character-space discipline established earlier in this
# file (see the note above set_fixture).
# ===========================================================================
sub assert_bare_json_number {
    my ($raw, $key, $value, $label) = @_;
    my $quoted_pat = qr/"\Q$key\E":"\Q$value\E"/;
    my $bare_pat   = qr/"\Q$key\E":\Q$value\E(?=[,}\]])/;
    unlike($raw, $quoted_pat, "$label: '$key' is not JSON-encoded as a quoted string");
    like($raw, $bare_pat, "$label: '$key' is JSON-encoded as a bare number (not stringified by _widen_utf8)");
}

# ===========================================================================
# AC3 / AC7 / AC12 (present) / AC13 (trackable_paths/detail) / AC14 / AC15
# (partial) / AC18 (trackable path + vault slug + manifest version axes) --
# one MEGA scenario: an unregistered cwd with 2 trackable paths, every
# cross-phase outcome seeded and present, 5 vault projects covering every
# `class` mapping outcome, 3 snapshots.
# ===========================================================================
{
    my $r = setup_root();
    my $base = 'mega-project';
    # Override cwd to end in a KNOWN basename for the decision-title check.
    $r->{cwd} = "$r->{scratch}/$base";
    make_path($r->{cwd});

    my $t1_path = 'CLAUDE.md';
    my $t2_path = "docs/notes-$EACUTE.md";   # AC18: non-ASCII trackable[].path
    my $t2_path_wide = widen_bytes($t2_path);   # CHARACTER space, for decoded-report/decision comparisons

    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0),
        mk_is_registered(registered => 0, cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('detect-trackable', 0),
        mk_detect_trackable(cwd => $r->{cwd}, trackable => [
            mk_trackable_entry(path => $t1_path, type => 'file'),
            mk_trackable_entry(path => $t2_path, type => 'file'),
        ]));
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0),
        mk_check_plugins(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list', 0),
        mk_snapshot_list(status => 'ok', count => 3, snapshots => [
            mk_snapshot_entry(id => 'snap-C', version => "1.2.$EACUTE", captured_at_utc => '2026-09-08T03:00:00Z'),
            mk_snapshot_entry(id => 'snap-B', version => '1.1.0', captured_at_utc => '2026-09-07T00:00:00Z'),
            mk_snapshot_entry(id => 'snap-A', version => '1.0.0', captured_at_utc => '2026-09-06T00:00:00Z'),
        ]));

    my $vault_slug_eacute = "proj-$EACUTE";   # AC18: non-ASCII slug axis
    my $vault_slug_wide = widen_bytes($vault_slug_eacute);   # CHARACTER space, for lookups against $report (decode_json'd)
    my $state = seed_state(
        preflight_items => {
            settings_outcome    => { skip_keys => [], preferences_saved => [], answers => {} },
            remote_integration  => { note => 'seeded-ri' },
            clone_live          => { note => 'seeded-cl' },
            marketplace_outcome => {
                export_to_repo => [], remove_from_repo => [], use_live => [], keep => [],
                instructions => [], preferences_saved => [], answers => {},
            },
        },
        export_items => {
            file_status      => [ { path => 'x', status => 'ok' } ],
            settings_merge   => {
                status => 'merged', merge_rule => 'export-wins',
                preferences_applied  => [ { key => 'model', relation => 'only_right', action => 'apply', source => 'export', effect => 'set' } ],
                preferences_ignored  => [],
                skip_keys_unmatched  => [],
            },
            file_outcome      => { copied => 1 },
            container_outcome => { copied => 0 },
            sensitive_scan    => { findings => [] },
            staged            => { count => 1 },
            committed         => { sha => 'abc123' },
            pushed            => { pushed => JSON::PP::true, remote => 'origin' },
        },
        vault_items => {
            vault_check  => { checked => 1 },
            todos        => { pulled => 0, committed => 0 },
            project_list => [
                { slug => 'p-synced',    path => '/p1', project_exists => JSON::PP::true, tok => 'tok1', last_synced_before => undef },
                { slug => 'p-errored',   path => '/p2', project_exists => JSON::PP::true, tok => 'tok2', last_synced_before => undef },
                { slug => 'p-conflict',  path => '/p3', project_exists => JSON::PP::true, tok => 'tok3', last_synced_before => undef },
                { slug => 'p-unreached', path => '/p4', project_exists => JSON::PP::true, tok => 'tok4', last_synced_before => undef },
                { slug => $vault_slug_eacute, path => '/p5', project_exists => JSON::PP::true, tok => 'tok5', last_synced_before => undef },
                'not-a-hashref',                                            # edge case: skipped, never dereferenced
                { slug => 'p-no-tok', path => '/p6', project_exists => JSON::PP::true },   # edge case: missing tok, skipped
            ],
            'project.tok1' => { status => 'committed_and_pushed', slug => 'p-synced',   applied => 1 },
            'project.tok2' => { status => 'drift',                slug => 'p-errored',  applied => 0 },
            'project.tok3' => { status => 'aborted',               slug => 'p-conflict', applied => 0 },
            # tok4: deliberately NO project.tok4 item -- "never reached".
            'project.tok5' => { status => 'something_never_seen_before', slug => $vault_slug_eacute, applied => 1 },
        },
    );
    write_state_raw($r->{state_path}, $state);

    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, 'AC3: unregistered+marker-absent+non-empty trackable -> exit 10 (needs_decision)')
        or diag($resp->{out} . $resp->{err});
    is(($resp->{json}{status} // ''), 'needs_decision', 'AC3: status is needs_decision');
    ok(defined($resp->{json}{resume_token}) && length($resp->{json}{resume_token}), 'AC3: a resume_token is present');

    my @decisions = decisions_of($resp);
    record_decisions(@decisions);
    is(scalar(@decisions), 1, 'AC3: exactly one decision is emitted');
    if (@decisions) {
        my $d = $decisions[0];
        is($d->{kind}, 'project_registration', "AC3: decision kind eq 'project_registration'");
        is($d->{id}, 'closeout.project_registration', "AC3: decision id eq 'closeout.project_registration'");
        is($d->{phase}, 'closeout', "AC3: decision phase eq 'closeout'");
        my @cids = sort(choice_ids($d));
        is_deeply_ids(\@cids, [qw(dont_ask_again not_now register_now)], 'AC3: exactly the 3 choice ids register_now/not_now/dont_ask_again');
        like($d->{title}, qr/^register '\Q$base\E' for vault backup\? \(2 trackable path\(s\)\)$/,
            'AC3: decision title has the exact documented shape with N=2');
        # AC13 -- decision detail contains both literal trackable paths.
        ok(index($d->{detail} // '', $t1_path) >= 0, 'AC13: decision detail contains the first trackable path literally');
        ok(index($d->{detail} // '', $t2_path_wide) >= 0, 'AC13: decision detail contains the second (non-ASCII) trackable path literally (character space -- decision comes from decode_json)');
        ok(index($resp->{out}, $t2_path) >= 0, 'AC18: raw stdout bytes contain the non-ASCII trackable path byte-exact');
    } else {
        for my $lbl (qw(kind id phase choices title detail-t1 detail-t2 stdout-bytes)) {
            ok(0, "AC3/AC13/AC18: $lbl (no decision emitted)");
        }
    }

    my $resp2 = answer_and_resume($r, $resp, 'closeout.project_registration' => 'register_now');
    is($resp2->{exit}, 0, 'AC7: (setup) resuming with register_now completes the run') or diag($resp2->{out} . $resp2->{err});

    my $notes = $resp2->{json}{notes};
    my $report = report_from_notes($notes);
    assert_required_report_keys($report, 'AC24/MEGA');

    if (ref($report) eq 'HASH') {
        # AC7 -- follow-up action recorded; the driver performs no registration.
        my @setup_actions = grep { ref($_) eq 'HASH' && (($_->{action} // '') eq 'invoke_setup_project') } @{ $report->{follow_up_actions} // [] };
        is(scalar(@setup_actions), 1, 'AC7: exactly one invoke_setup_project follow-up action');
        is(($setup_actions[0]{cwd} // ''), $r->{cwd}, 'AC7: the follow-up action carries the pinned cwd') if @setup_actions;
        ok(!defined($report->{current_project_registration}{error}) || !length($report->{current_project_registration}{error}),
            'AC7: no error is recorded for the registration unit on this path');

        # AC13 -- trackable_paths exact array, in order.
        my $tp = $report->{current_project_registration}{trackable_paths} // [];
        is_deeply_ids($tp, [$t1_path, $t2_path_wide], 'AC13: trackable_paths is exactly [t1, t2] in order (character space -- report comes from decode_json)');

        # AC12 present + spot-checked mapped fields.
        is_deeply_ids([sort keys %{ $report->{sources} // {} }], [qw(export preflight vault)], 'AC12: sources has the three phase keys');
        is(($report->{sources}{preflight} // ''), 'present', 'AC12: sources.preflight is "present"');
        is(($report->{sources}{export} // ''), 'present', 'AC12: sources.export is "present"');
        is(($report->{sources}{vault} // ''), 'present', 'AC12: sources.vault is "present"');
        ok(defined($report->{ccpraxis_sync}), 'AC12: ccpraxis_sync is non-null when preflight/export are present');
        ok(defined($report->{marketplaces}), 'AC12: marketplaces is non-null when preflight is present');
        is(ref($report->{ccpraxis_sync}{pushed}), 'HASH', 'AC12: ccpraxis_sync.pushed carries export.pushed verbatim (spot check)') ;
        ok(($report->{ccpraxis_sync}{pushed}{pushed} // '') eq JSON::PP::true, 'AC12: ccpraxis_sync.pushed.pushed is the seeded true value')
            if ref($report->{ccpraxis_sync}{pushed}) eq 'HASH';
        is(ref($report->{marketplaces}), 'HASH', 'AC12: marketplaces carries preflight.marketplace_outcome verbatim (spot check)');
        is(($report->{marketplaces}{export_to_repo} // 'MISSING'), $report->{marketplaces}{export_to_repo}, 'AC12: (sanity) marketplaces.export_to_repo key exists')
            if ref($report->{marketplaces}) eq 'HASH';
        ok(exists $report->{marketplaces}{export_to_repo}, 'AC12: marketplaces has the seeded export_to_repo key') if ref($report->{marketplaces}) eq 'HASH';

        # AC13 -- preferences.applied[0].key spot check (structured, field read).
        my $applied0 = $report->{preferences}{applied}[0];
        is(ref($applied0), 'HASH', 'AC13: preferences.applied[0] is a hashref');
        is(($applied0->{key} // ''), 'model', 'AC13: preferences.applied[0].key is the seeded value') if ref($applied0) eq 'HASH';

        # AC14 -- vault_projects classes.
        my @vp = @{ $report->{vault_projects}{projects} // [] };
        is(scalar(@vp), 5, 'AC14: vault_projects.projects has 5 well-formed entries (the 2 malformed ones are skipped)');
        my %by_slug = map { ($_->{slug} // '') => $_ } @vp;
        is(($by_slug{'p-synced'}{class} // ''), 'synced', 'AC14: committed_and_pushed -> class synced');
        is(($by_slug{'p-errored'}{class} // ''), 'errored', 'AC14: drift -> class errored');
        is(($by_slug{'p-conflict'}{class} // ''), 'conflicted', 'AC14: aborted -> class conflicted');
        is(($by_slug{'p-unreached'}{status} // ''), 'not_reached', 'AC14: an entry with no project.<tok> item -> status not_reached');
        is(($by_slug{'p-unreached'}{class} // ''), 'skipped', 'AC14: not_reached -> class skipped');
        is(($by_slug{$vault_slug_wide}{status} // ''), 'something_never_seen_before', 'AC14: unrecognised status is preserved verbatim');
        is(($by_slug{$vault_slug_wide}{class} // ''), 'errored', 'AC14: an unrecognised status maps to class errored (fail closed)');
        ok(index($resp2->{out}, $vault_slug_eacute) >= 0, 'AC18: raw stdout bytes contain the non-ASCII vault slug byte-exact');
        my $state_after = read_state($r->{state_path});
        ok(index(($ALL_STATE_RAW[-1] // ''), $vault_slug_eacute) >= 0, 'AC18: the state file contains the non-ASCII vault slug byte-exact');

        # AC15 -- snapshots (partial: full count-0/corrupt coverage in its own scenario).
        is(($report->{snapshots}{count} // ''), 3, 'AC15: snapshots.count == 3 (VALUE, not type -- see ITEM1 below for the JSON-type check)');
        assert_bare_json_number($resp2->{out}, 'count', 3, 'ITEM1');
        assert_bare_json_number($resp2->{out}, 'size', 10, 'ITEM1 (current_project_registration.trackable[].size)');
        assert_bare_json_number($resp2->{out}, 'applied', 1, 'ITEM1 (cross-phase: vault_projects.projects[].detail.applied)');
        is(($report->{snapshots}{newest_id} // ''), 'snap-C', 'AC15: newest_id == snapshots[0].id');
        is(($report->{snapshots}{newest_version} // ''), "1.2.$EACUTE_WIDE", 'AC15: newest_version == snapshots[0].manifest.version (non-ASCII, AC18, character space)');
        is($report->{snapshots}{revert_command},
           'perl ${CLAUDE_PLUGIN_ROOT}/scripts/claude-binary-backup.pl restore --latest',
           'AC15: revert_command is the exact documented constant string');
    } else {
        ok(0, 'AC7/AC12/AC13/AC14/AC15/AC18: report is present (report missing entirely)');
    }

    # AC7 -- no file created under the pinned cwd, and vault-sync.pl register
    # is never spawned.
    is(count_matching($r->{log_path}, qr/^vault-sync\.pl\s+register\b/), 0, 'AC7: vault-sync.pl register is never spawned');
}

# is_deeply_ids -- tiny array-of-scalars equality helper (StewardTest has no
# is_deeply). Order-sensitive.
sub is_deeply_ids {
    my ($got, $exp, $name) = @_;
    my $ok = (ref($got) eq 'ARRAY') && (ref($exp) eq 'ARRAY') && (scalar(@$got) == scalar(@$exp));
    if ($ok) {
        for my $i (0 .. $#$exp) {
            $ok = 0 unless defined($got->[$i]) && defined($exp->[$i]) && $got->[$i] eq $exp->[$i];
        }
    }
    ok($ok, $name) or diag("  got:      [" . join(', ', map { defined($_) ? $_ : 'undef' } @{ $got // [] }) . "]\n"
                          . "  expected: [" . join(', ', map { defined($_) ? $_ : 'undef' } @{ $exp // [] }) . "]");
    return $ok;
}

# ===========================================================================
# AC4 -- unregistered + trackable EMPTY -> zero decisions, exit 0, offered
# false, trackable_paths == [].
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), mk_is_registered(registered => 0, cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('detect-trackable', 0), mk_detect_trackable(cwd => $r->{cwd}, trackable => []));
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), mk_check_plugins(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 0));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'AC4: unregistered + empty trackable -> exit 0 (no decision)') or diag($resp->{out} . $resp->{err});
    is(scalar(decisions_of($resp)), 0, 'AC4: zero decisions') if ref($resp->{json}{decisions}) eq 'ARRAY';

    my $report = report_from_notes($resp->{json}{notes});
    if (ref($report) eq 'HASH') {
        is(($report->{current_project_registration}{offered} ? 1 : 0), 0, 'AC4: current_project_registration.offered is false');
        is_deeply_ids($report->{current_project_registration}{trackable_paths} // ['UNSET'], [], 'AC4: trackable_paths == []');
    } else {
        ok(0, 'AC4: current_project_registration.offered is false (report missing)');
        ok(0, 'AC4: trackable_paths == [] (report missing)');
    }
}

# ===========================================================================
# AC5 -- unregistered + skip marker PRESENT -> zero decisions, detect-
# trackable never spawned, skip_marker_present/path reported, a
# registration_skip_marker note.
# ===========================================================================
{
    my $r = setup_root();
    make_path("$r->{cwd}/.claude");
    write_text("$r->{cwd}/.claude/backup-skip", '');

    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), mk_is_registered(registered => 0, cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), mk_check_plugins(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 0));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'AC5: unregistered + marker present -> exit 0 (no decision)') or diag($resp->{out} . $resp->{err});
    is(scalar(decisions_of($resp)), 0, 'AC5: zero decisions') if ref($resp->{json}{decisions}) eq 'ARRAY';
    is(count_matching($r->{log_path}, qr/^vault-sync\.pl\s+detect-trackable\b/), 0, 'AC5: detect-trackable is never spawned when the marker is present');

    my $report = report_from_notes($resp->{json}{notes});
    if (ref($report) eq 'HASH') {
        ok($report->{current_project_registration}{skip_marker_present} ? 1 : 0, 'AC5: skip_marker_present is true');
        like(($report->{current_project_registration}{skip_marker_path} // ''), qr{/\.claude/backup-skip$}, 'AC5: skip_marker_path ends /.claude/backup-skip');
    } else {
        ok(0, 'AC5: skip_marker_present is true (report missing)');
        ok(0, 'AC5: skip_marker_path ends /.claude/backup-skip (report missing)');
    }
    ok(defined(find_note($resp->{json}{notes}, 'registration_skip_marker')), 'AC5: a registration_skip_marker note exists (mentioned, not silently honoured -- SKILL.md:448/471-475)');
}

# ===========================================================================
# AC6 -- already registered -> zero decisions, registered+slug reported,
# detect-trackable never spawned.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), mk_is_registered(registered => 1, slug => 'already-here', cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), mk_check_plugins(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 0));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'AC6: already-registered -> exit 0 (no decision)') or diag($resp->{out} . $resp->{err});
    is(scalar(decisions_of($resp)), 0, 'AC6: zero decisions') if ref($resp->{json}{decisions}) eq 'ARRAY';
    is(count_matching($r->{log_path}, qr/^vault-sync\.pl\s+detect-trackable\b/), 0, 'AC6: detect-trackable is never spawned when already registered');

    my $report = report_from_notes($resp->{json}{notes});
    if (ref($report) eq 'HASH') {
        ok($report->{current_project_registration}{registered} ? 1 : 0, 'AC6: registered is true');
        is(($report->{current_project_registration}{slug} // ''), 'already-here', 'AC6: the reported slug matches');
    } else {
        ok(0, 'AC6: registered is true (report missing)');
        ok(0, 'AC6: the reported slug matches (report missing)');
    }
}

# ===========================================================================
# AC8 -- "dont_ask_again" produces a create_skip_marker follow-up; the
# marker file itself does NOT exist on disk afterwards (the driver records
# the intent; the wrapper acts -- ruling C1).
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), mk_is_registered(registered => 0, cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('detect-trackable', 0),
        mk_detect_trackable(cwd => $r->{cwd}, trackable => [ mk_trackable_entry(path => 'CLAUDE.md') ]));
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), mk_check_plugins(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 0));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, 'AC8: (setup) pauses on the registration decision') or diag($resp->{out} . $resp->{err});
    my $resp2 = answer_and_resume($r, $resp, 'closeout.project_registration' => 'dont_ask_again');
    is($resp2->{exit}, 0, 'AC8: resuming with dont_ask_again completes the run') or diag($resp2->{out} . $resp2->{err});

    my $report = report_from_notes($resp2->{json}{notes});
    my $marker_path = "$r->{cwd}/.claude/backup-skip";
    if (ref($report) eq 'HASH') {
        my @skip_actions = grep { ref($_) eq 'HASH' && (($_->{action} // '') eq 'create_skip_marker') } @{ $report->{follow_up_actions} // [] };
        is(scalar(@skip_actions), 1, 'AC8: exactly one create_skip_marker follow-up action');
        is(($skip_actions[0]{path} // ''), $marker_path, 'AC8: the follow-up action names <cwd>/.claude/backup-skip') if @skip_actions;
    } else {
        ok(0, 'AC8: exactly one create_skip_marker follow-up action (report missing)');
    }
    ok(!path_exists($marker_path), 'AC8: the marker file does NOT exist on disk after -- the driver never creates it (mutates-nothing, S1.3/S7)');
}

# ===========================================================================
# AC9 / AC10 / AC13 (missing_names) / AC18 (plugin key axis) -- the PLUGINS
# scenario. Registration pre-resolved (registered:true) so only the plugin
# batch pauses.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), mk_is_registered(registered => 1, slug => 'reg', cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 0));

    my $plugin_a = "demo-$EACUTE\@demo-market";   # AC18: non-ASCII plugin key axis
    my $plugin_a_wide = widen_bytes($plugin_a);   # CHARACTER space, for comparisons against the decoded report
    my $plugin_b = 'other-plugin@other-market';
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0),
        mk_check_plugins(
            status  => 'missing_plugins',
            enabled => [],
            missing => [
                mk_plugin_entry(plugin => $plugin_a, name => "demo-$EACUTE", marketplace => 'demo-market'),
                mk_plugin_entry(plugin => $plugin_b, name => 'other-plugin', marketplace => 'other-market'),
            ],
            missing_marketplaces => [ mk_plugin_entry(plugin => 'mp-plugin@mp-market', name => 'mp-plugin', marketplace => 'mp-market') ],
            extra_installed => [ { plugin => 'extra-plugin@extra-market', note => 'installed locally but not in enabledPlugins config' } ],
        ),
        exit => 1);

    my $state = seed_state(export_items => {
        file_status    => [1],
        settings_merge => {
            status => 'merged', merge_rule => 'export-wins',
            preferences_applied => [ { key => 'other.key', relation => 'only_right', action => 'apply', source => 'export', effect => 'set' } ],
            preferences_ignored => [], skip_keys_unmatched => [],
        },
    });
    write_state_raw($r->{state_path}, $state);

    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, "AC9: check-plugins.pl exit 1 (status:missing_plugins) is treated as success, not a failure -- run pauses (needs_decision, backup.pl exit 10)")
        or diag($resp->{out} . $resp->{err});
    my @decisions = decisions_of($resp);
    record_decisions(@decisions);
    is(scalar(@decisions), 2, 'AC9: exactly two decisions in one needs_decision batch');
    my $id_a = expected_mint_id('closeout.plugin_install', $plugin_a);
    my $id_b = expected_mint_id('closeout.plugin_install', $plugin_b);
    my $d_a = find_decision(\@decisions, $id_a);
    my $d_b = find_decision(\@decisions, $id_b);
    ok(defined($d_a), "AC9: decision id $id_a is present");
    ok(defined($d_b), "AC9: decision id $id_b is present");
    for my $d (grep { defined } ($d_a, $d_b)) {
        is($d->{kind}, 'plugin_install', "AC9: decision $d->{id} kind eq plugin_install");
        my @cids = sort(choice_ids($d));
        is_deeply_ids(\@cids, [qw(install skip)], "AC9: decision $d->{id} has exactly choices install/skip");
    }

    my $resp2 = answer_and_resume($r, $resp, $id_a => 'install', $id_b => 'skip');
    is($resp2->{exit}, 0, 'AC9: (setup) resuming with both answers completes the run') or diag($resp2->{out} . $resp2->{err});

    my $report = report_from_notes($resp2->{json}{notes});
    if (ref($report) eq 'HASH') {
        ok(!exists($report->{unit_failures}{plugins}), 'AC9: check-plugins exit 1 (missing_plugins) is NOT recorded in unit_failures');
        my $names = $report->{plugins}{missing_names} // [];
        is_deeply_ids([sort @$names], [sort ($plugin_a_wide, $plugin_b)], 'AC13: plugins.missing_names is exactly missing[].plugin (character space)');
        ok(index($resp2->{out}, $plugin_a) >= 0, 'AC18: raw stdout bytes contain the non-ASCII plugin key byte-exact');
        my @install_actions = grep { ref($_) eq 'HASH' && (($_->{action} // '') eq 'install_plugin') && (($_->{plugin} // '') eq $plugin_a_wide) } @{ $report->{follow_up_actions} // [] };
        is(scalar(@install_actions), 1, 'AC9: an install_plugin follow-up exists for the plugin answered "install"');
        my @skip_install = grep { ref($_) eq 'HASH' && (($_->{action} // '') eq 'install_plugin') && (($_->{plugin} // '') eq $plugin_b) } @{ $report->{follow_up_actions} // [] };
        is(scalar(@skip_install), 0, 'AC9: no install_plugin follow-up for the plugin answered "skip"');

        # AC10 -- missing_marketplaces produces add_marketplace follow-up + note, zero decisions; extra_installed reported, no follow-up.
        my @add_mp = grep { ref($_) eq 'HASH' && (($_->{action} // '') eq 'add_marketplace') } @{ $report->{follow_up_actions} // [] };
        is(scalar(@add_mp), 1, 'AC10: exactly one add_marketplace follow-up for missing_marketplaces');
        ok(defined(find_note($resp2->{json}{notes}, 'plugin_missing_marketplaces')) || defined(find_note($resp2->{json}{notes}, 'missing_marketplaces')),
            'AC10: a note mentions missing_marketplaces (some note key does)') or diag(join(', ', map { $_->{key} // '?' } @{ $resp2->{json}{notes} // [] }));
        my @extra_in_report = @{ $report->{plugins}{extra_installed} // [] };
        is(scalar(@extra_in_report), 1, 'AC10: extra_installed appears in the report');
        my @extra_actions = grep { ref($_) eq 'HASH' && (($_->{plugin} // '') eq 'extra-plugin@extra-market') } @{ $report->{follow_up_actions} // [] };
        is(scalar(@extra_actions), 0, 'AC10: extra_installed produces NO follow-up action');
    } else {
        ok(0, 'AC9/AC10/AC13/AC18: report present (report missing entirely)');
    }
    ok(scalar(grep { ($_->{kind} // '') eq 'plugin_install' } @decisions) == 2 && scalar(grep { ($_->{kind} // '') ne 'plugin_install' } @decisions) == 0,
        'AC10: no missing_marketplaces/extra_installed entry ever produces its own decision (only the 2 missing[] decisions exist)');
}

# ===========================================================================
# AC10 (status ok / no_config) -- separately: zero decisions, zero follow-ups.
# ===========================================================================
for my $status (qw(ok no_config)) {
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), mk_is_registered(registered => 1, slug => 'reg', cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 0));
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), mk_check_plugins(status => $status));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, "AC10: check-plugins status:$status -> exit 0 (no decision)") or diag($resp->{out} . $resp->{err});
    is(scalar(decisions_of($resp)), 0, "AC10: status:$status -> zero decisions") if ref($resp->{json}{decisions}) eq 'ARRAY';
    my $report = report_from_notes($resp->{json}{notes});
    if (ref($report) eq 'HASH') {
        my $fu = $report->{follow_up_actions} // [];
        my @plugin_fu = grep { ref($_) eq 'HASH' && (($_->{action} // '') eq 'install_plugin') } @$fu;
        is(scalar(@plugin_fu), 0, "AC10: status:$status -> zero plugin_install follow-ups");
    } else {
        ok(0, "AC10: status:$status -> zero plugin_install follow-ups (report missing)");
    }
}

# ===========================================================================
# AC15 -- snapshots: count 0 -> nulls with error:null; a corrupt newest
# (manifest:null, corrupt:true) -> no die, newest_version:null.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), mk_is_registered(registered => 1, slug => 'reg', cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), mk_check_plugins(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 0));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'AC15: (setup) count:0 run completes') or diag($resp->{out} . $resp->{err});
    my $report = report_from_notes($resp->{json}{notes});
    if (ref($report) eq 'HASH') {
        is(($report->{snapshots}{count} // 'UNSET'), 0, 'AC15: count 0 -> snapshots.count == 0 (VALUE, not type -- see ITEM1 below)');
        assert_bare_json_number($resp->{out}, 'count', 0, 'ITEM1 (count:0)');
        ok(!defined($report->{snapshots}{newest_id}), 'AC15: count 0 -> newest_id is null');
        ok(!defined($report->{snapshots}{newest_version}), 'AC15: count 0 -> newest_version is null');
        ok(!defined($report->{snapshots}{error}), 'AC15: count 0 is a normal state -> snapshots.error is null (SKILL.md: not an error)');
    } else {
        ok(0, 'AC15: count 0 report fields (report missing)');
    }
}
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), mk_is_registered(registered => 1, slug => 'reg', cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), mk_check_plugins(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list', 0),
        mk_snapshot_list(status => 'ok', count => 1, snapshots => [ mk_snapshot_entry(id => 'corrupt-1', corrupt => 1, manifest => undef) ]));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'AC15: a corrupt newest snapshot does not die (exit 0)') or diag($resp->{out} . $resp->{err});
    my $report = report_from_notes($resp->{json}{notes});
    if (ref($report) eq 'HASH') {
        is(($report->{snapshots}{newest_id} // ''), 'corrupt-1', 'AC15: newest_id is present even when corrupt');
        ok(!defined($report->{snapshots}{newest_version}), 'AC15: newest_version is null when manifest is null (never autovivified)');
        ok($report->{snapshots}{newest_corrupt} ? 1 : 0, 'AC15: newest_corrupt is true');
    } else {
        ok(0, 'AC15: corrupt-newest report fields (report missing)');
    }
}

# ===========================================================================
# AC16 -- execution counting across pause/resume: each of the 4 scripts is
# spawned EXACTLY ONCE across both invocations combined.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), mk_is_registered(registered => 0, cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('detect-trackable', 0),
        mk_detect_trackable(cwd => $r->{cwd}, trackable => [ mk_trackable_entry(path => 'CLAUDE.md') ]));
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), mk_check_plugins(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 1, snapshots => [ mk_snapshot_entry(id => 's1') ]));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, 'AC16: (setup) pauses on the registration decision') or diag($resp->{out} . $resp->{err});
    is(count_matching($r->{log_path}, qr/^vault-sync\.pl\s+is-registered\b/), 1, 'AC16: is-registered spawned exactly once BEFORE resume');
    is(count_matching($r->{log_path}, qr/^vault-sync\.pl\s+detect-trackable\b/), 1, 'AC16: detect-trackable spawned exactly once BEFORE resume');
    is(count_matching($r->{log_path}, qr/^check-plugins\.pl\b/), 0, 'AC16: check-plugins.pl NOT spawned before the registration decision resolves (B8 pause ordering)');

    my $resp2 = answer_and_resume($r, $resp, 'closeout.project_registration' => 'not_now');
    is($resp2->{exit}, 0, 'AC16: resuming with not_now completes the run') or diag($resp2->{out} . $resp2->{err});

    is(count_matching($r->{log_path}, qr/^vault-sync\.pl\s+is-registered\b/), 1, 'AC16: is-registered spawned exactly once ACROSS BOTH invocations combined (no re-spawn on resume)');
    is(count_matching($r->{log_path}, qr/^vault-sync\.pl\s+detect-trackable\b/), 1, 'AC16: detect-trackable spawned exactly once across both invocations combined');
    is(count_matching($r->{log_path}, qr/^check-plugins\.pl\b/), 1, 'AC16: check-plugins.pl spawned exactly once across both invocations combined');
    is(count_matching($r->{log_path}, qr/^claude-binary-backup\.pl\s+list\b/), 1, 'AC16: claude-binary-backup.pl spawned exactly once across both invocations combined');
    ok(defined(report_from_notes($resp2->{json}{notes})), 'AC16: the final stdout carries a report note');
}

# ===========================================================================
# AC17 -- non-ASCII CWD: byte-identical --cwd argv, a marker created at the
# byte-exact path, report.cwd byte-identical in stdout AND the state file,
# survives pause/resume unchanged (B10, the pinned cwd).
# ===========================================================================
{
    my $scratch = temproot();
    my $cwd = "$scratch/caf$EACUTE-project";
    my $r = setup_root(cwd => $cwd);
    my $cwd_wide = widen_bytes($r->{cwd});   # CHARACTER space, for the decoded-report comparison below
    # Overwrite the scratch root used for setup so both live under the SAME
    # temproot as the eacute cwd (setup_root already made its own scratch --
    # harmless; $r->{cwd} is what run_backup() chdir()s into, and that is
    # what matters here).
    make_path("$r->{cwd}/.claude");
    write_text("$r->{cwd}/.claude/backup-skip", '');   # AC17: a real marker at the byte-exact non-ASCII path

    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), mk_is_registered(registered => 0, cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), mk_check_plugins(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 0));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'AC17: (setup) skip-marker present at the non-ASCII cwd -> no decision, exit 0') or diag($resp->{out} . $resp->{err});

    ok(count_matching($r->{log_path}, qr/\Q$r->{cwd}\E/) >= 1, 'AC17: the logged --cwd argv is byte-identical to the non-ASCII fixture path');
    my $report = report_from_notes($resp->{json}{notes});
    if (ref($report) eq 'HASH') {
        is(($report->{current_project_registration}{cwd} // ''), $cwd_wide, 'AC17: report.current_project_registration.cwd is byte-identical in stdout (character space)');
    } else {
        ok(0, 'AC17: report.current_project_registration.cwd is byte-identical in stdout (report missing)');
    }
    my $state = read_state($r->{state_path});
    ok(index(($ALL_STATE_RAW[-1] // ''), $r->{cwd}) >= 0, 'AC17: the state file contains the non-ASCII cwd byte-exact');
}
{
    # AC17 (continued) -- the SAME non-ASCII cwd, this time surviving a real
    # pause/resume (B10: cwd pinned at U1, never re-resolved).
    my $scratch = temproot();
    my $cwd = "$scratch/proj-caf$EACUTE";
    my $r = setup_root(cwd => $cwd);
    my $cwd_wide = widen_bytes($r->{cwd});   # CHARACTER space, for decoded-report comparisons below

    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), mk_is_registered(registered => 0, cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('detect-trackable', 0),
        mk_detect_trackable(cwd => $r->{cwd}, trackable => [ mk_trackable_entry(path => 'CLAUDE.md') ]));
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), mk_check_plugins(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 0));

    my $resp = run_backup($r, {});
    is($resp->{exit}, 10, 'AC17: (setup, pause/resume variant) pauses on the registration decision') or diag($resp->{out} . $resp->{err});
    if (my @decisions = decisions_of($resp)) {
        ok(index(($decisions[0]{data}{cwd} // ''), $EACUTE_WIDE) >= 0, 'AC17: the paused decision data.cwd carries the non-ASCII bytes (character space -- decisions[] comes from decode_json)')
    }

    my $resp2 = answer_and_resume($r, $resp, 'closeout.project_registration' => 'not_now');
    is($resp2->{exit}, 0, 'AC17: resume completes') or diag($resp2->{out} . $resp2->{err});
    my $report2 = report_from_notes($resp2->{json}{notes});
    if (ref($report2) eq 'HASH') {
        is(($report2->{current_project_registration}{cwd} // ''), $cwd_wide, 'AC17: the pinned cwd survives pause/resume unchanged (B10, character space)');
    } else {
        ok(0, 'AC17: the pinned cwd survives pause/resume unchanged (report missing)');
    }
}

# ===========================================================================
# AC19 -- no value read from $ctx ever reaches a child. A distinctive
# cross-phase value (never process-environment-derived) must never appear in
# any logged argv. Plus a positive allow-list check on flag values.
# ===========================================================================
{
    my $r = setup_root();
    my $canary = 'CANARY-e6f3-must-never-reach-argv';
    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), mk_is_registered(registered => 1, slug => $canary, cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), mk_check_plugins(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 0));
    my $state = seed_state(vault_items => {
        vault_check  => { checked => 1 },
        project_list => [ { slug => $canary, path => '/x', project_exists => JSON::PP::true, tok => 'ctok', last_synced_before => undef } ],
        'project.ctok' => { status => 'committed_and_pushed', slug => $canary },
    });
    write_state_raw($r->{state_path}, $state);

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'AC19: (setup) run completes') or diag($resp->{out} . $resp->{err});
    my $log_raw = read_text($r->{log_path}) // '';
    is(index($log_raw, $canary), -1, 'AC19: a value obtained only via get_phase_item/answers/get_item never reaches any child argv');

    # Positive allow-list: every logged --cwd/--settings/--installed/
    # --marketplaces value must be derived from the scratch HOME or cwd.
    my @bad;
    for my $line (log_lines($r->{log_path})) {
        my @tok = split ' ', $line;
        for (my $i = 0; $i < @tok; $i++) {
            if ($tok[$i] =~ /^--(?:cwd|settings|installed|marketplaces)$/ && $i + 1 < @tok) {
                my $val = $tok[$i + 1];
                push @bad, "$tok[$i]=$val" unless index($val, $r->{home}) >= 0 || index($val, $r->{cwd}) >= 0;
            }
        }
    }
    is(scalar(@bad), 0, 'AC19: every logged --cwd/--settings/--installed/--marketplaces value is derived from the scratch HOME or cwd')
        or diag('unexpected argv values: ' . join(', ', @bad));
}

# ===========================================================================
# AC20 -- mutates nothing: a full happy-path run under a scratch HOME/cwd,
# recursive scratch-tree snapshot before vs after.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), mk_is_registered(registered => 0, cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('detect-trackable', 0),
        mk_detect_trackable(cwd => $r->{cwd}, trackable => [ mk_trackable_entry(path => 'CLAUDE.md') ]));
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0),
        mk_check_plugins(status => 'missing_plugins', missing => [ mk_plugin_entry(plugin => 'p@m', name => 'p', marketplace => 'm') ]), exit => 1);
    set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 1, snapshots => [ mk_snapshot_entry(id => 's1') ]));

    my $before = snapshot_tree($r->{scratch});
    my $resp1 = run_backup($r, {});
    is($resp1->{exit}, 10, 'AC20: (setup) pauses on the registration decision') or diag($resp1->{out} . $resp1->{err});
    my $resp2 = answer_and_resume($r, $resp1, 'closeout.project_registration' => 'register_now');
    is($resp2->{exit}, 10, 'AC20: (setup) then pauses on the plugin batch') or diag($resp2->{out} . $resp2->{err});
    my $id = expected_mint_id('closeout.plugin_install', 'p@m');
    my $resp3 = answer_and_resume($r, $resp2, $id => 'install');
    is($resp3->{exit}, 0, 'AC20: (setup) resuming with the plugin answer completes the run') or diag($resp3->{out} . $resp3->{err});
    my $after = snapshot_tree($r->{scratch});

    assert_tree_unchanged($before, $after, $r, 'AC20/ITEM5');
}

# ===========================================================================
# COORDINATOR ITEM 2 -- a non-UTF-8 byte on the FAILURE path must not
# destroy backup.pl's stdout. _stdout_or_stderr_snippet clamps a failing
# child's raw stdout/stderr to 200 bytes on a UTF-8-safe BOUNDARY
# (_trim_utf8_tail), but never VALIDATES the bytes it clamps -- unlike the
# success path, which sanitises every value through _sanitize_utf8 before it
# reaches $ctx. A single genuinely-invalid UTF-8 byte (0xFF is never a valid
# UTF-8 lead OR continuation byte, in any position -- unlike $EACUTE, a
# well-formed two-byte sequence: this is deliberately NOT a real character)
# therefore propagates unsanitised into unit_failures/notes/phases[].error,
# and since backup.pl's own stdout encoder has no ->utf8 (S1.8) it does not
# validate either -- but any consumer that DOES decode with ->utf8 (this
# test's own decode_json, and any real wrapper) fails to parse the WHOLE
# JSON object, losing the report together with everything else in the same
# invocation.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), mk_is_registered(registered => 1, slug => 'reg', cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 0));
    # check-plugins.pl fails (exit 2, outside {0,1}) while emitting one byte
    # that can NEVER be valid UTF-8 on its own, and stdout that is also not
    # JSON -- both needed to reach _stdout_or_stderr_snippet's raw-clamp
    # path rather than the (sanitising) JSON-error-body path.
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), "\xFFbroken-not-json-and-not-utf8", exit => 2);

    my $resp = run_backup($r, {});
    my $parsed = eval { decode_json($resp->{out}) };
    ok(defined($parsed) && ref($parsed) eq 'HASH',
        'ITEM2: a child that fails while emitting a non-UTF-8 byte still leaves backup.pl stdout as exactly one parseable JSON object')
        or diag("decode_json error: " . ($@ // '(no error captured)') . "; raw stdout (first 300 bytes): " . substr($resp->{out} // '', 0, 300));
}

# ===========================================================================
# COORDINATOR ITEM 3 -- a REF-VALUED $@ from the report-assembly eval must
# never leak a raw reference into the report. Closeout.pm's _run_u6_report
# catches `eval { _assemble_report(...) }` and does `$err =~ s/\s+\z//;` on
# whatever $@ holds before embedding it into FIVE report fields
# (current_project_registration.error, plugins.error, snapshots.error,
# unit_failures.report via _record_failure, and the SAME value again inside
# _degraded_report's own unit_failures copy). AC13's fixture-driven
# aggregate cannot see this site (no fixture ever makes $@ a ref); this
# scenario drives it directly, in-process, the way t/22's make_direct_ctx
# already established for exactly this kind of synthetic-$ctx probe: a
# get_phase_item closure that DIES WITH A HASHREF (mirroring Run.pm's own
# `die { code => ..., message => ... }` convention) the moment
# _assemble_report first calls it. HOME/USERPROFILE point at a machine with
# no <home>/.claude/ccpraxis, so run_phase's own B1 sets $env_error and
# skips U1-U5 entirely -- U6 (_run_u6_report/_assemble_report) is reached
# with NO real child process needed at all.
#
# EMPIRICAL FINDING (verified against the shipped module before writing
# this assertion, not assumed): `s/\s+\z//` only MUTATES its target when the
# pattern actually MATCHES, and a bare reference's default stringification
# ("HASH(0x...)") never contains trailing whitespace -- so $err never
# flattens to text; ref($err) survives, unchanged, all the way into the
# report. The regex-based unlike() below is kept (it is what the
# coordinator asked this scenario to feed AC13 with, and it is the correct
# backstop if the mechanism ever DOES produce literal "HASH(0x...)" text);
# it is expected to PASS here, reported explicitly rather than hidden. The
# schema violation that DOES reproduce is narrower and just as real: the
# field is a REF at all, where S2.5 declares every one of these <string|null>.
# ===========================================================================
sub make_direct_ctx_closeout {
    my %items;
    my @notes;
    my $ctx = {
        run_id     => 'directctx-item3-0001',
        phase      => 'closeout',
        state_path => '/dev/null',
        answers    => {},
        is_done    => sub { my ($k) = @_; return exists $items{$k} ? 1 : 0; },
        get_item   => sub { my ($k) = @_; return exists $items{$k} ? $items{$k} : undef; },
        checkpoint => sub { my ($k, $d) = @_; $items{$k} = $d; return 1; },
        scratch    => {},
        note       => sub { my ($k, $v) = @_; push @notes, { phase => 'closeout', key => $k, value => $v }; return 1; },
        decision   => sub {
            my (%fields) = @_;
            $fields{phase} = 'closeout';
            if ($RUNPM_OK) {
                my ($ok_v, $reason) = Backup::Run::validate_decision(\%fields);
                die "Backup::Run: invalid decision constructed by phase 'closeout': $reason\n" unless $ok_v;
            }
            return { %fields };
        },
        get_phase_item => sub { die { code => 'synthetic_ref_die', message => 'ITEM3: deliberately ref-valued $@' }; },
    };
    return ($ctx, \%items, \@notes);
}
{
    if ($CLOSEOUT_LOADED) {
        my $scratch = temproot();
        my $home = make_machine($scratch, 'item3host');
        # Deliberately do NOT create <home>/.claude/ccpraxis.
        local $ENV{HOME} = $home;
        local $ENV{USERPROFILE} = $home;
        my ($ctx, $items, $notes) = make_direct_ctx_closeout();
        my $result = eval { Backup::Phase::Closeout::run_phase($ctx) };
        ok(!$@, "ITEM3: (setup) run_phase itself does not die even though get_phase_item dies with a ref (caught by _run_u6_report's own eval)")
            or diag('run_phase died: ' . (ref($@) ? ref($@) . ' ref' : $@));

        my $report_note;
        for my $n (@$notes) { $report_note = $n->{value} if (($n->{key} // '') eq 'report'); }
        ok(defined($report_note), 'ITEM3: (setup) a report note is still emitted despite the ref-valued $@');

        if (defined $report_note) {
            my $encoded = eval { JSON::PP->new->canonical->encode($report_note) };
            ok(defined $encoded, 'ITEM3: (setup) the report note itself is JSON-encodable') or diag($@);
            if (defined $encoded) {
                push @ALL_STDOUT_RAW, $encoded;   # feed the shared aggregate AC13 check too, per the dispatch
                unlike($encoded, $STRINGIFIED_REF_RE,
                    'ITEM3: a ref-valued $@ does not get stringified into a HASH(0x...)/ARRAY(0x...) pattern anywhere in the report (see EMPIRICAL FINDING above -- this is EXPECTED TO PASS)');
                for my $path ([qw(current_project_registration error)], [qw(plugins error)], [qw(snapshots error)]) {
                    my ($top, $key) = @$path;
                    my $v = $report_note->{$top}{$key};
                    is(ref($v), '', "ITEM3: report.$top.$key is never a reference (S2.5 declares it <string|null>)")
                        or diag("$top.$key is a '" . ref($v) . "' reference: " . JSON::PP->new->canonical->encode({ v => $v }));
                }
                my $uf_report = $report_note->{unit_failures}{report};
                is(ref($uf_report), '', 'ITEM3: report.unit_failures.report is never a reference (S2.5: unit_failures values are messages/strings)')
                    or diag("unit_failures.report is a '" . ref($uf_report) . "' reference: " . JSON::PP->new->canonical->encode({ v => $uf_report }));
            } else {
                ok(0, "ITEM3: report.$_ is never a reference (report not encodable)")
                    for ('current_project_registration.error', 'plugins.error', 'snapshots.error', 'unit_failures.report');
            }
        } else {
            ok(0, 'ITEM3: the encoded report contains no stringified ref (report note missing)');
            ok(0, "ITEM3: report.$_ is never a reference (report missing)")
                for ('current_project_registration.error', 'plugins.error', 'snapshots.error', 'unit_failures.report');
        }
    } else {
        ok(0, 'ITEM3: (Closeout.pm did not load)') for 1 .. 7;
    }
}

# ===========================================================================
# COORDINATOR ITEM 4 (the reviewer's MAJOR) -- a wrong-shaped cross-phase
# item must make the run terminate NON-ZERO, and the exit code must AGREE
# with report.unit_failures. _assemble_report accumulates shape failures
# into a LOCAL @shape_failures array and folds them into %uf (returned
# embedded in the report as report.unit_failures.report) but never calls
# _record_failure to persist them into the DURABLE checkpoint-backed ledger
# -- so run_phase's own terminal check (which reads ONLY the durable ledger)
# never sees them, and the run reports exit 0/status:complete while the
# report it just emitted names a problem.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), mk_is_registered(registered => 1, slug => 'reg', cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), mk_check_plugins(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 0));
    my $state = seed_state(preflight_items => {
        settings_outcome   => { skip_keys => [], preferences_saved => [], answers => {} },
        remote_integration => 'not-a-hashref-but-a-plain-string',
    });
    write_state_raw($r->{state_path}, $state);

    my $resp = run_backup($r, {});
    isnt($resp->{exit}, 0, 'ITEM4 (MAJOR): a wrong-shaped cross-phase item (preflight.remote_integration not a hashref) makes the run terminate non-zero')
        or diag($resp->{out} . $resp->{err});
    is($resp->{exit}, 20, 'ITEM4 (MAJOR): ...and specifically exit 20 (complete_with_failures), never a silent 0')
        or diag($resp->{out} . $resp->{err});

    my $report = report_from_notes($resp->{json}{notes});
    if (ref($report) eq 'HASH') {
        my $report_names_a_problem = (ref($report->{unit_failures}) eq 'HASH'
            && exists($report->{unit_failures}{report}) && length($report->{unit_failures}{report} // '')) ? 1 : 0;
        ok($report_names_a_problem, 'ITEM4 (MAJOR): (setup) report.unit_failures.report does name the shape problem')
            or diag('unit_failures: ' . JSON::PP->new->canonical->encode($report->{unit_failures} // {}));
        my $run_says_failed = ($resp->{exit} != 0) ? 1 : 0;
        is($report_names_a_problem, $run_says_failed,
            'ITEM4 (MAJOR): the exit code and report.unit_failures agree on whether the run failed');
    } else {
        ok(0, 'ITEM4 (MAJOR): (setup) report.unit_failures.report does name the shape problem (report missing)');
        ok(0, 'ITEM4 (MAJOR): the exit code and report.unit_failures agree (report missing)');
    }
}

# ===========================================================================
# COORDINATOR ITEM 6 -- exercise the already-built but never-invoked
# stderr_warn fixture helper: spec S5's "check-plugins.pl printing a warning
# to stderr (it does, on an unexpected installed_plugins.json schema) while
# exiting 0 with valid stdout JSON is a success" edge case. A COVERAGE gap,
# not a defect -- expected to PASS.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), mk_is_registered(registered => 1, slug => 'reg', cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 0));
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), mk_check_plugins(status => 'ok'),
        stderr_warn => 'Warning: installed_plugins.json has unexpected schema. Treating as empty.');

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'ITEM6: check-plugins.pl printing a warning to stderr while exiting 0 with valid stdout JSON is still a success (spec S5)')
        or diag($resp->{out} . $resp->{err});
    my $report = report_from_notes($resp->{json}{notes});
    if (ref($report) eq 'HASH') {
        ok(!exists($report->{unit_failures}{plugins}), 'ITEM6: a stderr warning alone is not recorded as a plugins unit failure');
        is(($report->{plugins}{status} // ''), 'ok', 'ITEM6: plugins.status is still "ok" despite the stderr warning');
    } else {
        ok(0, 'ITEM6: a stderr warning alone is not recorded as a plugins unit failure (report missing)');
        ok(0, 'ITEM6: plugins.status is still "ok" despite the stderr warning (report missing)');
    }
}

# ===========================================================================
# AC21 -- a signal-killed check-plugins.pl is NOT treated as exit 0/status ok.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), mk_is_registered(registered => 1, slug => 'reg', cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 0));
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), undef, signal => 1);

    my $resp = run_backup($r, {});
    is($resp->{exit}, 20, 'AC21: a signal-killed check-plugins.pl degrades the run (exit 20), never read as success') or diag($resp->{out} . $resp->{err});
    my $report = report_from_notes($resp->{json}{notes});
    if (ref($report) eq 'HASH') {
        ok(defined($report->{plugins}{error}) && length($report->{plugins}{error}), 'AC21: plugins.error is set');
        ok(exists($report->{unit_failures}{plugins}), 'AC21: unit_failures.plugins is set');
        isnt(($report->{plugins}{status} // ''), 'ok', 'AC21: plugins.status is never reported as "ok" for a signal-killed child');
    } else {
        ok(0, 'AC21: plugins.error is set (report missing)');
        ok(0, 'AC21: unit_failures.plugins is set (report missing)');
        ok(0, 'AC21: plugins.status is never "ok" (report missing)');
    }
    ok(defined($report), 'AC21: the report is still emitted on this failure path');
}

# ===========================================================================
# AC22 -- three distinct registration-probe failure modes never collapse.
# ===========================================================================
{
    my @messages;

    # (a) unspawnable vault-sync.pl.
    {
        my $r = setup_root();
        unlink("$r->{root}/plugins/steward/scripts/vault-sync.pl");
        set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), mk_check_plugins(status => 'ok'));
        set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 0));
        my $resp = run_backup($r, {});
        my $report = report_from_notes($resp->{json}{notes});
        is(scalar(decisions_of($resp)), 0, 'AC22a: unspawnable vault-sync.pl -> zero decisions') if ref($resp->{json}{decisions}) eq 'ARRAY';
        isnt($resp->{exit}, 1, 'AC22a: unspawnable vault-sync.pl never dies (exit != 1/phase_died)');
        if (ref($report) eq 'HASH') {
            ok(!($report->{current_project_registration}{registered} ? 1 : 0), 'AC22a: never falsely read as "registered"');
            push @messages, ($report->{current_project_registration}{error} // $report->{unit_failures}{registration} // '');
        } else { push @messages, ''; }
    }
    # (b) spawned with a non-zero, non-parseable-relevant exit (exit 2).
    {
        my $r = setup_root();
        set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), '{}', exit => 2);
        set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), mk_check_plugins(status => 'ok'));
        set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 0));
        my $resp = run_backup($r, {});
        my $report = report_from_notes($resp->{json}{notes});
        is(scalar(decisions_of($resp)), 0, 'AC22b: exit-2 is-registered -> zero decisions') if ref($resp->{json}{decisions}) eq 'ARRAY';
        isnt($resp->{exit}, 1, 'AC22b: exit-2 is-registered never dies');
        if (ref($report) eq 'HASH') {
            ok(!($report->{current_project_registration}{registered} ? 1 : 0), 'AC22b: never falsely read as "registered"');
            push @messages, ($report->{current_project_registration}{error} // $report->{unit_failures}{registration} // '');
        } else { push @messages, ''; }
    }
    # (c) spawned, exit 0, unparseable stdout.
    {
        my $r = setup_root();
        set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), undef, unparseable => 1);
        set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), mk_check_plugins(status => 'ok'));
        set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 0));
        my $resp = run_backup($r, {});
        my $report = report_from_notes($resp->{json}{notes});
        is(scalar(decisions_of($resp)), 0, 'AC22c: exit-0-unparseable is-registered -> zero decisions') if ref($resp->{json}{decisions}) eq 'ARRAY';
        isnt($resp->{exit}, 1, 'AC22c: exit-0-unparseable is-registered never dies');
        if (ref($report) eq 'HASH') {
            ok(!($report->{current_project_registration}{registered} ? 1 : 0), 'AC22c: never falsely read as "registered"');
            push @messages, ($report->{current_project_registration}{error} // $report->{unit_failures}{registration} // '');
        } else { push @messages, ''; }
    }

    isnt($messages[0], $messages[1], 'AC22: unspawnable vs exit-2 produce DIFFERENT unit_failures.registration messages');
    isnt($messages[1], $messages[2], 'AC22: exit-2 vs exit-0-unparseable produce DIFFERENT unit_failures.registration messages');
    isnt($messages[0], $messages[2], 'AC22: unspawnable vs exit-0-unparseable produce DIFFERENT unit_failures.registration messages');
    ok(length($messages[0]) && length($messages[1]) && length($messages[2]), 'AC22: all three failure messages are non-empty');
}

# ===========================================================================
# AC23 -- environmental degradation never aborts: HOME/USERPROFILE both
# unset, and separately $root ("<home>/.claude/ccpraxis") absent.
# ===========================================================================
{
    my $r = setup_root();
    my $resp = run_backup($r, { HOME => undef, USERPROFILE => undef });
    is($resp->{exit}, 20, 'AC23: missing HOME/USERPROFILE degrades (exit 20), never dies') or diag($resp->{out} . $resp->{err});
    isnt(($resp->{json}{status} // ''), 'error', 'AC23: missing HOME/USERPROFILE is not reported as an internal error/die');
    unlike(($resp->{json}{error}{code} // ''), qr/phase_died/, 'AC23: missing HOME/USERPROFILE never produces phase_died');
    my $report = report_from_notes($resp->{json}{notes});
    ok(defined($report), 'AC23: a report note is still present when HOME/USERPROFILE are unset');
    if (ref($report) eq 'HASH') {
        ok(($report->{degraded} ? 1 : 0) || exists($report->{unit_failures}{environment}), 'AC23: report.degraded or unit_failures.environment is set');
    }
}
{
    my $scratch = temproot();
    my $home = make_machine($scratch, 'host2');
    # Deliberately do NOT create <home>/.claude/ccpraxis.
    my $phase_dir = "$scratch/phases";
    copy_closeout_into($phase_dir);
    my $cwd = "$scratch/proj";
    make_path($cwd);
    my $r = {
        scratch => $scratch, home => $home, root => "$home/.claude/ccpraxis",
        phase_dir => $phase_dir, fixture_dir => "$scratch/fixtures",
        state_path => "$scratch/state/run.json", log_path => "$scratch/log.txt", cwd => $cwd,
    };
    make_path($r->{fixture_dir});
    my $resp = run_backup($r, {});
    is($resp->{exit}, 20, 'AC23: missing $root degrades (exit 20), never dies') or diag($resp->{out} . $resp->{err});
    unlike(($resp->{json}{error}{code} // ''), qr/phase_died/, 'AC23: missing $root never produces phase_died');
    my $report = report_from_notes($resp->{json}{notes});
    ok(defined($report), 'AC23: a report note is still present when $root is absent');
}

# ===========================================================================
# AC25 -- report emitted on the ALL-FAILED path too, and the DUPNOTE
# last-wins contract (S2.2's accepted consequence).
# ===========================================================================
{
    my $r = setup_root();
    unlink("$r->{root}/plugins/steward/scripts/vault-sync.pl");
    unlink("$r->{root}/plugins/steward/scripts/check-plugins.pl");
    unlink("$r->{root}/plugins/steward/scripts/claude-binary-backup.pl");

    my $resp = run_backup($r, {});
    is($resp->{exit}, 20, 'AC25: every unit failing -> exit 20 (complete_with_failures)') or diag($resp->{out} . $resp->{err});
    my $report = report_from_notes($resp->{json}{notes});
    assert_required_report_keys($report, 'AC24/all-failed');
    if (ref($report) eq 'HASH') {
        ok(exists($report->{unit_failures}{registration}), 'AC25: unit_failures names the registration unit');
        ok(exists($report->{unit_failures}{plugins}), 'AC25: unit_failures names the plugins unit');
        ok(exists($report->{unit_failures}{snapshots}), 'AC25: unit_failures names the snapshots unit');
    } else {
        ok(0, 'AC25: unit_failures names the registration unit (report missing)');
        ok(0, 'AC25: unit_failures names the plugins unit (report missing)');
        ok(0, 'AC25: unit_failures names the snapshots unit (report missing)');
    }
}
{
    # DUPNOTE -- simulate a mid-execution kill that already persisted an OLD
    # report note (S2.2's accepted consequence). A bare `run` re-entry (no
    # --resume) sees phases.closeout.status == "running" (not "paused"),
    # wipes items (crash_preserves_items not declared), and re-runs
    # everything -- possibly leaving TWO 'report' notes. Contract: the LAST
    # one is authoritative.
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), mk_is_registered(registered => 1, slug => 'reg', cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), mk_check_plugins(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 0));

    my $state = seed_state(
        status          => 'running',
        closeout_status => 'running',
        closeout_items  => {},
        notes           => [ { phase => 'closeout', key => 'report', value => {
            schema_version => 1, run_id => 'OLD-FAKE-RUN-ID-FROM-A-PRIOR-DEATH', phase => 'closeout',
            sources => { preflight => 'absent', export => 'absent', vault => 'absent' },
            ccpraxis_sync => undef, marketplaces => undef,
            preferences => { applied => [], ignored => [], skip_keys => [], skip_keys_unmatched => [], saved => [] },
            vault_projects => { todos => undef, projects => [] },
            current_project_registration => { cwd => 'STALE', registered => JSON::PP::false, slug => undef,
                skip_marker_present => JSON::PP::false, skip_marker_path => 'STALE', offered => JSON::PP::false,
                choice => undef, trackable => [], trackable_paths => [], error => undef },
            plugins => { status => undef, enabled => [], missing => [], missing_marketplaces => [], extra_installed => [],
                missing_names => [], answers => {}, error => undef },
            snapshots => { count => undef, newest_id => undef, newest_version => undef, newest_captured_at_utc => undef,
                newest_corrupt => JSON::PP::false, revert_command => 'STALE', error => 'stale' },
            follow_up_actions => [], unit_failures => {}, degraded => JSON::PP::true,
        } } ],
    );
    write_state_raw($r->{state_path}, $state);

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'DUPNOTE: (setup) the crash-simulated re-entry completes cleanly') or diag($resp->{out} . $resp->{err});
    my @report_notes = find_all_notes($resp->{json}{notes}, 'report');
    ok(scalar(@report_notes) >= 1, 'DUPNOTE: at least one report note is present after a simulated mid-execution kill');
    my $last_report = report_from_notes($resp->{json}{notes});
    if (ref($last_report) eq 'HASH') {
        isnt(($last_report->{run_id} // ''), 'OLD-FAKE-RUN-ID-FROM-A-PRIOR-DEATH', 'DUPNOTE: the LAST report note is read, not the stale seeded one (S2.2 contract)');
        is(($last_report->{run_id} // ''), ($resp->{json}{run_id} // ''), 'DUPNOTE: the last report note carries the CURRENT run_id');
    } else {
        ok(0, 'DUPNOTE: the last report note is read, not the stale seeded one (report missing)');
    }
}

# ===========================================================================
# AC12 (absent half) -- with NO earlier-phase items at all, sources are all
# "absent" and the report never implies emptiness/success.
# ===========================================================================
{
    my $r = setup_root();
    set_fixture($r->{fixture_dir}, fixture_name('is-registered', 0), mk_is_registered(registered => 1, slug => 'reg', cwd => $r->{cwd}));
    set_fixture($r->{fixture_dir}, fixture_name('check-plugins.pl', 0), mk_check_plugins(status => 'ok'));
    set_fixture($r->{fixture_dir}, fixture_name('list', 0), mk_snapshot_list(status => 'ok', count => 0));
    my $state = seed_state();   # no preflight_items/export_items/vault_items keys at all
    write_state_raw($r->{state_path}, $state);

    my $resp = run_backup($r, {});
    is($resp->{exit}, 0, 'AC12: (setup) no earlier-phase items -> run completes') or diag($resp->{out} . $resp->{err});
    my $report = report_from_notes($resp->{json}{notes});
    if (ref($report) eq 'HASH') {
        is(($report->{sources}{preflight} // ''), 'absent', 'AC12: sources.preflight is "absent" when preflight never ran');
        is(($report->{sources}{export} // ''), 'absent', 'AC12: sources.export is "absent" when export never ran');
        is(($report->{sources}{vault} // ''), 'absent', 'AC12: sources.vault is "absent" when vault never ran');
        ok(!defined($report->{ccpraxis_sync}), 'AC12: ccpraxis_sync is null (not "nothing was pushed") when both sources are absent');
        ok(!defined($report->{marketplaces}), 'AC12: marketplaces is null when preflight is absent');
        is_deeply_ids($report->{vault_projects}{projects} // ['UNSET'], [], 'AC12: vault_projects.projects is [] (not omitted) when vault is absent');
        ok(!defined($report->{vault_projects}{todos}), 'AC12: vault_projects.todos is null when vault is absent');
        is_deeply_ids($report->{preferences}{applied} // ['UNSET'], [], 'AC12: preferences.applied is [] when export is absent');
        is_deeply_ids($report->{preferences}{ignored} // ['UNSET'], [], 'AC12: preferences.ignored is [] when export is absent');
    } else {
        ok(0, 'AC12: absent-sources report fields (report missing)');
    }
    is(scalar(@{ $resp->{json}{phases} // [] }), 1, 'AC12 (edge case): closeout is the only discovered phase in this harness -- sources reflect run-state seeding, not discovery');
}

# ===========================================================================
# AC26 -- the parity file, per Decision 13's fixed four-cell row shape.
# ===========================================================================
{
    ok(-f $PARITY_FILE, 'AC26: reports/parity/05-closeout-and-report.md exists')
        or diag("expected at: $PARITY_FILE");
    my $raw = read_text($PARITY_FILE);
    if (defined $raw) {
        my @lines = grep { /\S/ } split /\r?\n/, $raw;
        my @rows = grep { /^\s*\|.*\|\s*$/ } @lines;
        ok(scalar(@rows) >= 2, 'AC26: at least a header row and a separator row are present');
        my $sep_idx;
        for my $i (0 .. $#rows) { if ($rows[$i] =~ /^\s*\|(?:\s*-{2,}\s*\|){4}\s*$/) { $sep_idx = $i; last; } }
        ok(defined($sep_idx), 'AC26: a |---|---|---|---| separator row is present') or diag(join("\n", @rows));
        my @data_rows = defined($sep_idx) ? @rows[$sep_idx + 1 .. $#rows] : ();
        my %step_seen;
        my $all_four_cells = 1;
        my $all_phase_closeout = 1;
        my $all_module_correct = 1;
        for my $row (@data_rows) {
            (my $stripped = $row) =~ s/^\s*\|//;
            $stripped =~ s/\|\s*$//;
            my @cells = split /\|/, $stripped, -1;
            $all_four_cells = 0 unless scalar(@cells) == 4;
            next unless scalar(@cells) == 4;
            my ($step, $phase, $module, $note) = @cells;
            $step_seen{$step} = 1 if defined $step;
            $all_phase_closeout = 0 unless defined($phase) && $phase eq 'closeout';
            $all_module_correct = 0 unless defined($module) && $module eq 'scripts/backup/Closeout.pm';
        }
        ok($all_four_cells, 'AC26: every data row splits to exactly the four-cell shape');
        ok($all_phase_closeout, "AC26: every data row's second cell is 'closeout'");
        ok($all_module_correct, "AC26: every data row's third cell is 'scripts/backup/Closeout.pm'");
        for my $step (qw(5.7 6 6.6 7)) {
            ok($step_seen{$step}, "AC26: a data row exists for absorbed step '$step' (string equality, unpadded)");
        }
        my %count_by_step;
        for my $row (@data_rows) {
            (my $stripped = $row) =~ s/^\s*\|//; $stripped =~ s/\|\s*$//;
            my @cells = split /\|/, $stripped, -1;
            $count_by_step{$cells[0]}++ if @cells == 4 && defined $cells[0];
        }
        my $exactly_one_each = 1;
        for my $step (qw(5.7 6 6.6 7)) { $exactly_one_each = 0 unless ($count_by_step{$step} // 0) == 1; }
        ok($exactly_one_each, 'AC26: exactly one data row per absorbed step (5.7/6/6.6/7)');
    } else {
        ok(0, 'AC26: parity file readable (file not found)');
        for (1 .. 7) { ok(0, 'AC26: (parity file structural check -- file not found)'); }
    }
}

# ===========================================================================
# AC27 -- isolation: the real HOME/USERPROFILE never appear in any produced
# path across every scenario above.
# ===========================================================================
{
    ok((defined($REAL_HOME) && length($REAL_HOME)) || (defined($REAL_USERPROFILE) && length($REAL_USERPROFILE)),
        'AC27: (setup) the real HOME or USERPROFILE was actually captured (non-empty) before any scenario override');
    my $real_leaks = 0;
    for my $raw (@ALL_STDOUT_RAW, @ALL_STATE_RAW) {
        next unless defined $raw;
        $real_leaks++ if defined($REAL_HOME) && length($REAL_HOME) && index($raw, $REAL_HOME) >= 0;
        $real_leaks++ if defined($REAL_USERPROFILE) && length($REAL_USERPROFILE) && index($raw, $REAL_USERPROFILE) >= 0
            && (!defined($REAL_HOME) || $REAL_USERPROFILE ne $REAL_HOME);
    }
    is($real_leaks, 0, 'AC27: the real HOME/USERPROFILE never appear in any scenario\'s stdout or state-file bytes');
}

# ===========================================================================
# AC13 -- the aggregate HASH/ARRAY/CODE/GLOB/SCALAR/Regexp(0x...) stringified-
# ref check, over EVERY scenario's raw stdout and state-file bytes collected
# above, as ONE assertion (the highest-value check in this package: the
# blueprint named one site; check-plugins.pl and settings-export-merge add at
# least two more).
# ===========================================================================
{
    my $bad = 0;
    my @offenders;
    for my $raw (@ALL_STDOUT_RAW, @ALL_STATE_RAW) {
        next unless defined $raw;
        if ($raw =~ /($STRINGIFIED_REF_RE)/) { $bad++; push @offenders, $1; }
    }
    is($bad, 0, 'AC13: no stringified-hashref/arrayref/coderef pattern (HASH(0x...) etc.) appears anywhere across every scenario\'s stdout or state bytes')
        or diag('offenders: ' . join(', ', @offenders[0 .. (5 < $#offenders ? 5 : $#offenders)]));
    ok(scalar(@ALL_STDOUT_RAW) > 10, 'AC13: (sanity) a meaningful number of scenarios contributed stdout bytes to this aggregate check');
}

# ===========================================================================
# AC11 -- aggregate: every decision seen anywhere in this file validates
# against Backup::Run::validate_decision with phase=>closeout, and its kind
# is one of exactly the two permitted kinds.
# ===========================================================================
{
    ok(scalar(@ALL_DECISIONS_SEEN) >= 3, 'AC11: (sanity) this file recorded a meaningful number of decisions to aggregate-check')
        or diag('total decisions recorded: ' . scalar(@ALL_DECISIONS_SEEN));
    my %seen_kind;
    my $all_valid = 1;
    for my $d (@ALL_DECISIONS_SEEN) {
        $seen_kind{ $d->{kind} // '?' }++;
        if ($RUNPM_OK) {
            my ($ok_v, $reason) = Backup::Run::validate_decision($d);
            unless ($ok_v) { $all_valid = 0; diag("invalid decision id=" . ($d->{id} // '?') . ": $reason"); }
        }
    }
    ok($all_valid, 'AC11: every decision recorded in this file validates against Backup::Run::validate_decision');
    my @other_kinds = grep { $_ ne 'project_registration' && $_ ne 'plugin_install' } keys %seen_kind;
    is(scalar(@other_kinds), 0, 'AC11: every decision kind seen anywhere is one of exactly {project_registration, plugin_install}')
        or diag('unexpected kinds: ' . join(', ', @other_kinds));
}

done_testing();
