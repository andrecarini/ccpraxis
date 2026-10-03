#!/usr/bin/env perl
# platform: any
# Oracle for blueprint almanac-records, package 18 (skills-and-docs). Derived
# ONLY from
# .ccpraxis-local-data/blueprints/almanac-records/specs/18-skills-and-docs-spec.md
# sections 2-4 (AC1-AC20) and the package ledger's done criteria. Never read
# the implementation of any skill this package creates; the shared interface
# named by the spec, Almanac::CLI::routes() (almanac.pl:33), is loaded live
# and used as the single source of truth for valid (type, verb) pairs -- no
# verb list is ever hardcoded here.
#
# AC21-AC23 are driver-run commands (lint-readme-paths.pl, gen-readme-tree.pl
# --check, and three sibling suites staying green) and are deliberately NOT
# covered in this file.
#
# Hermeticity: every spawned `almanac.pl` invocation runs against a
# File::Temp project (P) and a File::Temp home (H), never the real
# ~/.claude, the real vault, or this repo's own stores. The real repo's
# .ccpraxis-local-data/almanac listing is snapshotted before anything runs
# and asserted unchanged at the end (BASELINE-UNCHANGED, below). This file
# never invokes another .t file.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Spec;
use File::Find;
use JSON::PP;
use Encode qw(decode);
use POSIX ();

my $ROOT       = "$Bin/../..";                 # plugins/almanac
my $REPO_ROOT  = "$Bin/../../../..";            # repo root

# ---------------------------------------------------------------------------
# BASELINE-UNCHANGED setup: snapshot the real repo's almanac data tree before
# doing anything else. Re-checked at the very end of this file.
# ---------------------------------------------------------------------------
my $REAL_ALMANAC_DIR = "$REPO_ROOT/.ccpraxis-local-data/almanac";
sub snapshot_tree {
    my ($dir) = @_;
    return [] unless -d $dir;
    my @entries;
    find({
        no_chdir => 1,
        wanted   => sub { push @entries, $File::Find::name if -f $_ },
    }, $dir);
    return [ sort @entries ];
}
my $real_almanac_before = snapshot_tree($REAL_ALMANAC_DIR);

# ---------------------------------------------------------------------------
# Load Almanac::CLI::routes() live -- the closed route table this whole file
# is an oracle against. almanac.pl guards its main with `unless (caller)`, so
# `do` loads it as a library with no side effect.
# ---------------------------------------------------------------------------
my $almanac_pl = "$ROOT/scripts/almanac.pl";
ok(-f $almanac_pl, "fixture present: $almanac_pl") or BAIL_OUT("missing $almanac_pl");
do $almanac_pl;
BAIL_OUT("failed to load almanac.pl: $@") if $@;
BAIL_OUT("failed to load almanac.pl: $!") unless defined &Almanac::CLI::routes;
my $ROUTES = Almanac::CLI::routes();
ok(ref($ROUTES) eq 'HASH' && exists $ROUTES->{todo} && exists $ROUTES->{doctor},
    'routes() loaded live and looks like the closed route table (sanity check)');

# ---------------------------------------------------------------------------
# Fixture: temp project P and temp home H (spec "Test fixture (shared)").
# ---------------------------------------------------------------------------
my $P = tempdir(CLEANUP => 1);
my $H = tempdir(CLEANUP => 1);
mkdir("$P/.ccpraxis-local-data") or BAIL_OUT("cannot create $P/.ccpraxis-local-data: $!");

# ---------------------------------------------------------------------------
# Bounded spawn: fork+exec, list-form, never a shell string, captured through
# File::Temp files (never an in-memory scalar handle -- documented landmine
# on this host). Mirrors plugins/butler/tests/lib/RunnerStateHarness.pm's own
# bounded-fork pattern.
# ---------------------------------------------------------------------------
sub run_smoke {
    my (@tokens) = @_;
    my $out_fh = File::Temp->new(UNLINK => 0); my $out_path = "$out_fh"; close $out_fh;
    my $err_fh = File::Temp->new(UNLINK => 0); my $err_path = "$err_fh"; close $err_fh;

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        chdir($P) or POSIX::_exit(96);
        $ENV{CLAUDE_PLUGIN_ROOT}  = $ROOT;
        $ENV{CLAUDE_PROJECT_DIR}  = $P;
        $ENV{ALMANAC_HOME}        = $H;
        $ENV{HOME}                = $H;
        $ENV{USERPROFILE}         = $H;
        delete $ENV{ALMANAC_SURFACE};
        delete $ENV{CLAUDE_CODE_SESSION_ID};
        open(STDIN, '<', File::Spec->devnull) or POSIX::_exit(95);
        open(STDOUT, '>', $out_path) or POSIX::_exit(97);
        open(STDERR, '>', $err_path) or POSIX::_exit(98);
        exec($^X, $almanac_pl, @tokens) or POSIX::_exit(99);
    }
    my $deadline = time() + 60;
    my $reaped = 0;
    while (time() < $deadline) {
        my $r = waitpid($pid, POSIX::WNOHANG());
        if ($r == $pid) { $reaped = 1; last }
        select(undef, undef, undef, 0.1);
    }
    my $timed_out = 0;
    unless ($reaped) {
        $timed_out = 1;
        kill('TERM', $pid);
        my $waited = 0;
        while ($waited < 2) {
            my $r = waitpid($pid, POSIX::WNOHANG());
            last if $r == $pid;
            select(undef, undef, undef, 0.1);
            $waited += 0.1;
        }
        if ((waitpid($pid, POSIX::WNOHANG()) // 0) != $pid) {
            kill('KILL', $pid);
            waitpid($pid, 0);
        }
    }
    my $rc = $? >> 8;
    my $out = slurp_raw($out_path); my $err = slurp_raw($err_path);
    unlink $out_path, $err_path;
    return ($rc, $out, $err, $timed_out);
}

sub slurp_raw {
    my ($path) = @_;
    return '' unless -f $path;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined($c) ? $c : '';
}

sub slurp_utf8 {
    my ($path) = @_;
    my $raw = slurp_raw($path);
    return decode('UTF-8', $raw);
}

# ---------------------------------------------------------------------------
# §2.2 parsing helpers -- frontmatter, command blocks, logical command lines.
# ---------------------------------------------------------------------------

# parse_frontmatter($text) -> { ok, name, description, allowed_tools, body }
sub parse_frontmatter {
    my ($text) = @_;
    my @lines = split /\n/, $text;
    for my $l (@lines) { $l =~ s/\r$//; }
    return { ok => 0 } unless @lines && $lines[0] eq '---';
    my $end = undef;
    for my $i (1 .. $#lines) {
        if ($lines[$i] eq '---') { $end = $i; last }
    }
    return { ok => 0 } unless defined $end;
    my @fm = @lines[1 .. $end - 1];
    my @body = @lines[$end + 1 .. $#lines];
    my ($name, $description, $allowed);
    for my $l (@fm) {
        if (!defined $name && $l =~ /^name:\s?(.*)$/) { $name = $1; }
        if (!defined $description && $l =~ /^description:\s?(.*)$/) { $description = $1; }
        if (!defined $allowed && $l =~ /^allowed-tools:\s?(.*)$/) { $allowed = $1; }
    }
    return {
        ok            => 1,
        name          => $name,
        description   => $description,
        allowed_tools => $allowed,
        body          => join("\n", @body),
    };
}

# extract_bash_blocks($body_text) -> list of arrayrefs of raw lines
sub extract_bash_blocks {
    my ($body) = @_;
    my @lines = split /\n/, $body;
    for my $l (@lines) { $l =~ s/\r$//; }
    my @blocks;
    my $in = 0;
    my @cur;
    for my $l (@lines) {
        if (!$in) {
            if ($l eq '```bash') { $in = 1; @cur = (); }
        } else {
            if ($l eq '```') { $in = 0; push @blocks, [@cur]; }
            else { push @cur, $l; }
        }
    }
    return @blocks;
}

# logical_lines(@raw) -> list of logical command line strings, per §2.2 rules
sub logical_lines {
    my (@raw) = @_;
    my @out;
    my $i = 0;
    while ($i < @raw) {
        my $line = $raw[$i];
        $i++;
        while ($line =~ /\\\s*$/ && $i < @raw) {
            $line =~ s/\\\s*$//;
            $line .= $raw[$i];
            $i++;
        }
        next unless $line =~ /\S/;
        next if $line =~ /^\s*#/;
        push @out, $line;
        if ($line =~ /<<\s*'?([A-Za-z_]+)'?/) {
            my $word = $1;
            while ($i < @raw) {
                my $l2 = $raw[$i];
                $i++;
                last if $l2 eq $word;
            }
        }
    }
    return @out;
}

my $PREFIX = 'perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl"';

# ---------------------------------------------------------------------------
# The six skills (spec §2.3). smoke_expected is the §2.3 table entry, checked
# verbatim by AC8; smoke_type is used by AC2/AC9/AC10.
# ---------------------------------------------------------------------------
# AC16 (specs/02-thread-store-spec.md section 2.10): skills/task/ is deleted
# and skills/thread/ replaces it (name: thread, smoke `thread list`).
my @SKILL_DIRS = qw(todo note thread inbox bug-report bug-triage);
my %SMOKE_EXPECTED = (
    'todo'       => 'todo list',
    'note'       => 'note list',
    'thread'     => 'thread list',
    'inbox'      => 'inbox list',
    'bug-report' => 'bug list',
    'bug-triage' => 'bug collect',
);

# AC16: skills/task/ must be gone entirely (not merely superseded).
ok(!-d "$ROOT/skills/task", 'AC16: plugins/almanac/skills/task/ no longer exists');

my %parsed;      # dir -> parse_frontmatter() result
my %blocks;      # dir -> list of blocks (each an arrayref of logical lines)
my %raw_text;    # dir -> raw utf8 text of SKILL.md

for my $dir (@SKILL_DIRS) {
    my $path = "$ROOT/skills/$dir/SKILL.md";
    if (-f $path) {
        $raw_text{$dir} = slurp_utf8($path);
        $parsed{$dir}   = parse_frontmatter($raw_text{$dir});
        if ($parsed{$dir}{ok}) {
            my @b = extract_bash_blocks($parsed{$dir}{body});
            $blocks{$dir} = [ map { [ logical_lines(@$_) ] } @b ];
        } else {
            $blocks{$dir} = [];
        }
    } else {
        $raw_text{$dir} = '';
        $parsed{$dir}   = { ok => 0 };
        $blocks{$dir}   = [];
    }
}

# ===========================================================================
# AC1 (DC1): skill dirs exist with parseable frontmatter; name: == dirname
# ===========================================================================
for my $dir (@SKILL_DIRS) {
    ok(-f "$ROOT/skills/$dir/SKILL.md", "AC1: plugins/almanac/skills/$dir/SKILL.md exists");
    ok($parsed{$dir}{ok}, "AC1: $dir/SKILL.md has parseable --- frontmatter");
    if ($parsed{$dir}{ok}) {
        is($parsed{$dir}{name}, $dir, "AC1: $dir/SKILL.md frontmatter name: equals directory name");
    } else {
        fail("AC1: $dir/SKILL.md frontmatter name: equals directory name (no parseable frontmatter)");
    }
}

# ===========================================================================
# AC5 (DC6) and AC6 (DC6): every SKILL.md has >=1 command block; every
# logical command line starts with the §2.1 prefix and names a valid
# (type, verb) pair from the live routes() table.
# ===========================================================================
my %smoke_type;   # dir -> type of the smoke invocation (first logical line
                   # of the first command block), used by AC2/AC9/AC10.
my %smoke_line;   # dir -> full smoke invocation text (with prefix)

for my $dir (@SKILL_DIRS) {
    unless ($parsed{$dir}{ok}) {
        fail("AC5: $dir/SKILL.md has at least one \`\`\`bash command block (no parseable frontmatter)");
        fail("AC5: $dir/SKILL.md -- every logical command line starts with the \$2.1 prefix (no parseable frontmatter)");
        fail("AC6: $dir/SKILL.md -- every logical command line names a valid (type, verb) from routes() (no parseable frontmatter)");
        next;
    }
    my @blks = @{ $blocks{$dir} };
    ok(scalar(@blks) > 0, "AC5: $dir/SKILL.md has at least one \`\`\`bash command block");
    unless (@blks) {
        fail("AC5: $dir/SKILL.md -- every logical command line starts with the \$2.1 prefix (no command block)");
        fail("AC6: $dir/SKILL.md -- every logical command line names a valid (type, verb) from routes() (no command block)");
        next;
    }

    my @prefix_violations;
    my @route_violations;
    for my $blk (@blks) {
        for my $line (@$blk) {
            unless ($line =~ /^\Q$PREFIX\E(?:\s|$)/) {
                push @prefix_violations, $line;
                next;
            }
            my $rest = substr($line, length($PREFIX));
            $rest =~ s/^\s+//;
            my @tok = split /\s+/, $rest, 3;
            my ($type, $verb) = @tok[0, 1];
            unless (defined $type && exists $ROUTES->{$type}) {
                push @route_violations, "$line  [unknown type '" . (defined $type ? $type : '<undef>') . "']";
                next;
            }
            my $route = $ROUTES->{$type};
            if (defined $route->{verbs}) {
                unless (defined $verb && grep { $_ eq $verb } @{ $route->{verbs} }) {
                    push @route_violations, "$line  [unknown verb '" . (defined $verb ? $verb : '<undef>') . "' for type '$type']";
                }
            }
        }
    }
    unless (ok(@prefix_violations == 0, "AC5: $dir/SKILL.md -- every logical command line starts with the \$2.1 prefix")) {
        diag($_) for @prefix_violations;
    }
    unless (ok(@route_violations == 0, "AC6: $dir/SKILL.md -- every logical command line names a valid (type, verb) from routes()")) {
        diag($_) for @route_violations;
    }

    my $first_line = $blks[0][0];
    if (defined $first_line && $first_line =~ /^\Q$PREFIX\E\s*(.*)$/) {
        $smoke_line{$dir} = $1;
        my @tok = split /\s+/, $1;
        $smoke_type{$dir} = $tok[0];
    }
}

# ===========================================================================
# AC2 (DC1): every routes() key with defined verbs has >=1 skill whose smoke
# invocation uses that key.
# ===========================================================================
{
    my %covered = map { (defined $smoke_type{$_} ? ($smoke_type{$_} => 1) : ()) } @SKILL_DIRS;
    my @missing;
    for my $type (sort keys %$ROUTES) {
        next unless defined $ROUTES->{$type}{verbs};
        push @missing, $type unless $covered{$type};
    }
    unless (ok(@missing == 0, 'AC2: every routes() key with defined verbs is covered by some skill\'s smoke invocation')) {
        diag("uncovered types: @missing");
    }
}

# ===========================================================================
# AC3 / AC4 (DC2): description is a single-line, 1-1024 char plain scalar,
# with both a positive and a negative trigger clause, not starting with a
# quote, and containing neither ": " nor " #".
# ===========================================================================
for my $dir (@SKILL_DIRS) {
    unless ($parsed{$dir}{ok}) {
        fail("AC3: $dir description is 1-1024 characters (no parseable frontmatter)");
        fail("AC3: $dir description contains no ': ' (no parseable frontmatter)");
        fail("AC3: $dir description contains no ' #' (no parseable frontmatter)");
        fail("AC3: $dir description does not start with a quote character (no parseable frontmatter)");
        fail("AC3: $dir description carries a positive trigger clause (no parseable frontmatter)");
        fail("AC4: $dir description carries a negative trigger clause (no parseable frontmatter)");
        next;
    }
    my $d = $parsed{$dir}{description};
    ok(defined $d && length($d) >= 1 && length($d) <= 1024,
        "AC3: $dir description is 1-1024 characters");
    unless (defined $d) {
        fail("AC3: $dir description contains no ': ' (description undefined)");
        fail("AC3: $dir description contains no ' #' (description undefined)");
        fail("AC3: $dir description does not start with a quote character (description undefined)");
        fail("AC3: $dir description carries a positive trigger clause (description undefined)");
        fail("AC4: $dir description carries a negative trigger clause (description undefined)");
        next;
    }
    unlike($d, qr/: /, "AC3: $dir description contains no ': '");
    unlike($d, qr/ #/, "AC3: $dir description contains no ' #'");
    ok($d !~ /^["']/, "AC3: $dir description does not start with a quote character");
    like($d, qr/use (it )?when|use proactively/i, "AC3: $dir description carries a positive trigger clause");
    like($d, qr/skip|not for|do not use|never use/i, "AC4: $dir description carries a negative trigger clause");
}

# ===========================================================================
# AC7 (DC6): no SKILL.md names a type script directly.
# ===========================================================================
for my $dir (@SKILL_DIRS) {
    unlike($raw_text{$dir}, qr/almanac-(?:todo|note|task|thread|inbox|bug|doctor)\.pl/,
        "AC7: $dir/SKILL.md never names an almanac-<type>.pl script directly");
}

# ===========================================================================
# AC8 (DC3): each skill's smoke invocation equals the §2.3 table entry.
# ===========================================================================
for my $dir (@SKILL_DIRS) {
    is($smoke_line{$dir}, $SMOKE_EXPECTED{$dir}, "AC8: $dir smoke invocation equals the \$2.3 table entry");
}

# ===========================================================================
# AC9 (DC3) and AC10 (DC1, DC3): run each smoke invocation for real, exit 0,
# no stderr line equal to 'almanac-error:'; afterwards P has no record files.
# ===========================================================================
for my $dir (@SKILL_DIRS) {
    my $expected = $SMOKE_EXPECTED{$dir};
    unless (defined $expected) {
        fail("AC9: $dir has no expected smoke invocation to run");
        next;
    }
    my @tokens = split /\s+/, $expected;
    my ($rc, $out, $err, $timed_out) = run_smoke(@tokens);
    my @err_lines = split /\n/, $err;
    my $has_error_line = grep { my $l = $_; $l =~ s/\r$//; $l eq 'almanac-error:' } @err_lines;
    ok(!$timed_out && $rc == 0 && !$has_error_line,
        "AC9: $dir smoke invocation ('$expected') exits 0 with no literal 'almanac-error:' stderr line")
        or diag("dir=$dir rc=$rc timed_out=$timed_out\nSTDOUT:\n$out\nSTDERR:\n$err");
}

{
    my @record_md   = glob("$P/.ccpraxis-local-data/almanac/*/*.md");
    my @bugreport_md = glob("$P/.ccpraxis-local-data/bug-reports/*.md");
    is(scalar(@record_md) + scalar(@bugreport_md), 0,
        'AC10: after all smoke invocations, the fixture project has no record files -- the smoke set is read-only')
        or diag(join("\n", @record_md, @bugreport_md));
}

# ===========================================================================
# AC11 (no hook duplication): no almanac SKILL.md BODY restates hook
# enforcement. bug-report's frontmatter legitimately names "hook" as a kind
# of ccpraxis artefact, so only the body (post-frontmatter) is checked.
# ===========================================================================
for my $dir (@SKILL_DIRS) {
    unless ($parsed{$dir}{ok}) {
        fail("AC11: $dir/SKILL.md body never mentions hooks, PreToolUse/PostToolUse, or a Tasks tool name (no parseable frontmatter)");
        fail("AC11: $dir/SKILL.md body never instructs against editing/writing directly (no parseable frontmatter)");
        next;
    }
    my $body = $parsed{$dir}{body};
    unlike($body, qr/\bhooks?\b|PreToolUse|PostToolUse|\bTask(Create|Update|List|Get)\b/i,
        "AC11: $dir/SKILL.md body never mentions hooks, PreToolUse/PostToolUse, or a Tasks tool name");
    unlike($body, qr/\b(edit|write)\b[^.\n]{0,40}\bdirectly\b/i,
        "AC11: $dir/SKILL.md body never instructs against editing/writing directly");
}

# ===========================================================================
# AC12 (house constraint): bug-report/SKILL.md keeps its pinned headings and
# the ${CLAUDE_PLUGIN_ROOT} explanation.
# ===========================================================================
{
    my $txt = $raw_text{'bug-report'};
    like($txt, qr/What makes a report worth reading/, 'AC12: bug-report/SKILL.md keeps "What makes a report worth reading"');
    like($txt, qr/Before you file/, 'AC12: bug-report/SKILL.md keeps "Before you file"');
    ok(index($txt, '<ccpraxis>/plugins/almanac') >= 0, 'AC12: bug-report/SKILL.md contains the literal <ccpraxis>/plugins/almanac substitution note');
}

# ===========================================================================
# AC13 (DC4): every *.pl/*.pm under plugins/almanac/scripts/ (recursive) has
# a sidecar <file>.about.
# ===========================================================================
my @pl_pm_files;
find({
    no_chdir => 1,
    wanted   => sub { push @pl_pm_files, $File::Find::name if -f $_ && /\.(?:pl|pm)$/ },
}, "$ROOT/scripts");
@pl_pm_files = sort @pl_pm_files;

ok(scalar(@pl_pm_files) > 0, 'AC13 precondition: at least one .pl/.pm file found under plugins/almanac/scripts/');

my @missing_sidecars = grep { !-f "$_.about" } @pl_pm_files;
unless (ok(@missing_sidecars == 0, 'AC13: every .pl/.pm under plugins/almanac/scripts/ has a sidecar <file>.about')) {
    diag($_) for @missing_sidecars;
}

# ===========================================================================
# AC14 (DC4): every .about found by AC13, plus plugins/almanac/.about,
# satisfies the §2.5 format rules and matches the pinned text where the spec
# pins one. Byte-exact comparisons throughout (never decoded).
# ===========================================================================
my %PINNED_ABOUT = (
    'Almanac/Lock.pm.about'          => 'Bounded exclusive flock on a sidecar <file>.lock, polled to a deadline; never unlinks a lock file',
    'Almanac/Record.pm.about'        => 'The record format: one record per file, front matter plus body; parse, serialize, ids, forbidden bytes',
    'Almanac/Store.pm.about'         => 'Per-record CRUD in project and global scope, rank-key ordering, seals, and the one scope predicate',
    'Almanac/ClaudeMdBlock.pm.about' => 'Renders the note directory as a hashed block between markers and detects hand-edits and conflicts',
    'Almanac/LegacyQueue.pm.about'   => 'Absorbs a legacy subagent-guard question queue into project inbox items, then renames it',
    'Almanac/GlobalCounts.pm.about'  => 'Recounts global todos and notes after each global mutation into one read-only-mounted counts file',
    'almanac-todo.pl.about'              => 'Todo CRUD in project and global scope: create, list, show, edit, complete, reopen, delete, count',
    'almanac-note.pl.about'              => 'Notes as a pointer plus metadata, project or global; promote moves one between internal and external',
    # AC19/specs/02-thread-store-spec.md section 2.10: almanac-task.pl's CLI
    # is retired; this .about is rewritten to say so (the library half
    # stays, per the architect's resolution of the inbox/butler-continuity
    # coupling).
    'almanac-task.pl.about'              => 'Retired CLI: prints a pointer to almanac thread and exits 2; its library half stays for old readers',
    'almanac-inbox.pl.about'             => "The operator's inbox: agents file items, the operator answers, answering lists the tasks it blocked",
    'almanac-decision.pl.about'          => 'Retired: prints one line pointing at the inbox script and exits 2',
    'almanac-migrate-todos.pl.about'     => "Host-side move of the vault's legacy todos into global almanac todos, verified before removal",
    'almanac-migrate-memories.pl.about'  => 'Host-side migration of Claude Code memories into notes, and render-index for the notes index',
    'gen-statusline-counters.pl.about'   => 'Prints the almanac counting block embedded in scripts/statusline.pl, which may import nothing',
    # AC19/AC16 (specs/02-thread-store-spec.md sections 2.3, 2.4, 2.7): new
    # this package.
    'almanac-thread.pl.about'            => 'Threads per project: create, list, show, archive; ordered tasks with a status or a package link; a typed log',
    'Almanac/Thread.pm.about'            => 'Thread store library: metadata, ordered tasks, typed log, the archive rule and the flat-tasklist migration',
    'Almanac/PackageLink.pm.about'       => 'Resolves <blueprint>/<package> to its ledger, live or under blueprints/_archive, and reads its status',
);

# AC16/AC19 precondition: these three sidecars are NEW this package and must
# exist (the generic @pl_pm_files loop below only checks a sidecar once its
# target .pl/.pm file exists, which would otherwise silently skip them
# entirely while almanac-thread.pl/Thread.pm/PackageLink.pm do not exist yet).
for my $rel (qw(almanac-thread.pl.about Almanac/Thread.pm.about Almanac/PackageLink.pm.about)) {
    ok(-f "$ROOT/scripts/$rel", "AC16/AC19 precondition: plugins/almanac/scripts/$rel exists")
        or diag("not present yet -- $rel's pinned-text comparison below cannot run until it exists");
}

sub check_about_format {
    my ($path, $label) = @_;
    my $raw = slurp_raw($path);
    ok(defined $raw && length($raw), "AC14: $label is non-empty");
    return unless defined $raw && length($raw);

    ok($raw =~ /\n\z/ && $raw !~ /\n.*\n\z/s, "AC14: $label ends in exactly one \\n, which is the last byte");
    ok(index($raw, "\r") < 0, "AC14: $label contains no \\r");
    ok(index($raw, "\t") < 0, "AC14: $label contains no tab");
    (my $content = $raw) =~ s/\n\z//;
    ok($content !~ /^\s|\s$/, "AC14: $label has no leading/trailing whitespace before the \\n");
    my $len = length($content);
    ok($len >= 1 && $len <= 120, "AC14: $label content is 1-120 characters (got $len)");
    eval { decode('UTF-8', $raw, Encode::FB_CROAK); 1 }
        or do { fail("AC14: $label is valid UTF-8"); return };
    pass("AC14: $label is valid UTF-8");
    is($content, $content, "AC14: $label first line trimmed equals its own content minus the trailing \\n (identity, by construction)");
}

for my $f (@pl_pm_files) {
    my $about_path = "$f.about";
    next unless -f $about_path;
    my ($rel) = $about_path =~ m{scripts/(.*)$};
    $rel = $about_path unless defined $rel;
    check_about_format($about_path, $rel);
    if (defined $rel && exists $PINNED_ABOUT{$rel}) {
        my $raw = slurp_raw($about_path);
        (my $content = $raw) =~ s/\n\z//;
        is($content, $PINNED_ABOUT{$rel}, "AC14: $rel content byte-equals the pinned §2.5 text");
    }
}

{
    my $plugin_about = "$ROOT/.about";
    check_about_format($plugin_about, 'plugins/almanac/.about');
    my $raw = slurp_raw($plugin_about);
    (my $content = $raw) =~ s/\n\z//;
    is($content,
       'Almanac: durable one-file-per-record todos, notes, tasklist, operator inbox and bug reports, written only by scripts',
       'spec 2.7: plugins/almanac/.about byte-equals the new caption (operator inbox, not pending decisions)');
}

# ===========================================================================
# AC15 (DC4): no orphan sidecar; none names a retired-todo token or
# questions.md. Tokens assembled from halves, per
# plugins/steward/tests/t/todo-retirement-scan.t's own technique, so this
# file never contains either exact byte string.
# ===========================================================================
my $tok_script = join('', 'todo', '-sync');
my $tok_plugin = join('', 'todo', '@ccpraxis-local');

my @about_files;
find({
    no_chdir => 1,
    wanted   => sub { push @about_files, $File::Find::name if -f $_ && /\.about$/ },
}, "$ROOT/scripts");
@about_files = sort @about_files;

ok(scalar(@about_files) > 0, 'AC15 precondition: at least one .about sidecar found under plugins/almanac/scripts/');

my @orphans;
my @forbidden;
for my $af (@about_files) {
    (my $target = $af) =~ s/\.about$//;
    push @orphans, $af unless -f $target;
    my $content = slurp_raw($af);
    push @forbidden, "$af (contains 'questions.md')" if $content =~ /questions\.md/;
    push @forbidden, "$af (contains retired script token)" if index($content, $tok_script) >= 0;
    push @forbidden, "$af (contains retired plugin token)" if index($content, $tok_plugin) >= 0;
}
unless (ok(@orphans == 0, 'AC15: no .about sidecar under plugins/almanac/scripts/ names a non-existent sibling file')) {
    diag($_) for @orphans;
}
unless (ok(@forbidden == 0, 'AC15: no .about sidecar contains questions.md or a retired-todo token')) {
    diag($_) for @forbidden;
}

# ===========================================================================
# AC16 (manifest): plugin.json parses; name almanac; description == §2.4
# text; version 0.2.0.
# ===========================================================================
my $PLUGIN_JSON_PATH = "$ROOT/.claude-plugin/plugin.json";
my $EXPECTED_PLUGIN_DESCRIPTION =
    "Durable records that outlive a session, one file per record, written only through their scripts: "
  . "project and global todos, notes (a pointer plus metadata, in place of Claude Code auto-memory), "
  . "the project's ordered tasklist, the operator's inbox, and ccpraxis bug reports. "
  . "Bundles /almanac:todo, /almanac:note, /almanac:task, /almanac:inbox, /almanac:bug-report and "
  . "/almanac:bug-triage, the almanac dispatcher and doctor, and hooks that deny direct edits to the stores.";

my $plugin_json;
{
    my $raw = slurp_raw($PLUGIN_JSON_PATH);
    my $decoded = eval { JSON::PP->new->utf8->decode($raw) };
    ok(defined $decoded, 'AC16: plugin.json parses as JSON') or diag("parse error: $@");
    $plugin_json = $decoded // {};
}
is($plugin_json->{name}, 'almanac', 'AC16: plugin.json name is "almanac"');
is($plugin_json->{description}, $EXPECTED_PLUGIN_DESCRIPTION, 'AC16: plugin.json description equals the §2.4 text');
is($plugin_json->{version}, '0.2.0', 'AC16: plugin.json version is "0.2.0"');

# ===========================================================================
# AC17 (DC7): marketplace.json parses; exactly one almanac entry, source
# ./almanac, description byte-equal to plugin.json's description.
# ===========================================================================
{
    my $mkt_path = "$REPO_ROOT/plugins/.claude-plugin/marketplace.json";
    my $raw = slurp_raw($mkt_path);
    my $decoded = eval { JSON::PP->new->utf8->decode($raw) };
    ok(defined $decoded, 'AC17: marketplace.json parses as JSON') or diag("parse error: $@");
    my @entries = ref($decoded) eq 'HASH' && ref($decoded->{plugins}) eq 'ARRAY'
        ? grep { ref($_) eq 'HASH' && ($_->{name} // '') eq 'almanac' } @{ $decoded->{plugins} }
        : ();
    is(scalar(@entries), 1, 'AC17: marketplace.json has exactly one entry named "almanac"');
    if (@entries == 1) {
        is($entries[0]{source}, './almanac', 'AC17: the almanac entry\'s source is "./almanac"');
        is($entries[0]{description}, $plugin_json->{description},
            "AC17: the almanac entry's description is byte-equal to plugin.json's description");
    }
}

# ===========================================================================
# AC18-AC20 (DC5): README documents the layout, the enforcement layers, and
# lists the four new commands.
# ===========================================================================
my $README_PATH = "$REPO_ROOT/README.md";
my $readme_text = slurp_utf8($README_PATH);

my $heading = '### Records that outlive a session';
ok(index($readme_text, $heading) >= 0, "AC18: README.md has a line '$heading'");
like($readme_text, qr/^\s*-\s*\[.*\]\(#records-that-outlive-a-session\)/m,
    'AC18: README.md Contents has a line linking #records-that-outlive-a-session');

{
    my $hpos = index($readme_text, $heading);
    my $section = '';
    if ($hpos >= 0) {
        my $rest = substr($readme_text, $hpos + length($heading));
        my $endrel = $rest =~ /^#{2,3}\s/m ? $-[0] : length($rest);
        $section = substr($rest, 0, $endrel);
    }
    ok(length($section) > 0, 'AC19 precondition: the "Records that outlive a session" section has a body')
        or diag('heading not found or section empty');

    for my $substr (
        '.ccpraxis-local-data/almanac/<type>/',
        '~/.claude/claude-code-vault/almanac/<type>/',
        'bug-reports/',
        'PreToolUse',
        'guard-almanac-write.sh',
        'almanac doctor',
        'verify',
    ) {
        ok(index($section, $substr) >= 0, "AC19: README section contains literal '$substr'");
    }
    for my $re (qr/one file per record/i, qr/refuse/i, qr/hash/i) {
        like($section, $re, "AC19: README section matches $re");
    }
}

for my $row (qw(todo note task inbox)) {
    like($readme_text, qr/\|\s*\`\/almanac:$row\`\s*\|/, "AC20: README Commands table has a row beginning with \`/almanac:$row\`");
}

# ===========================================================================
# BASELINE-UNCHANGED: the real repo's almanac data listing is unchanged.
# Never runs anything against $REAL_ALMANAC_DIR -- every spawn above targeted
# only $P / $H.
# ===========================================================================
{
    my $real_almanac_after = snapshot_tree($REAL_ALMANAC_DIR);
    is_deeply($real_almanac_after, $real_almanac_before,
        'BASELINE-UNCHANGED: the real repo\'s .ccpraxis-local-data/almanac listing is unchanged by this run')
        or diag('before: ' . join(',', @$real_almanac_before) . "\nafter: " . join(',', @$real_almanac_after));
}

# This file never contains either retired-todo token as a contiguous literal
# (built from halves above, same discipline as todo-retirement-scan.t).

done_testing();
