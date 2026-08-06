#!/usr/bin/env perl
use strict;
use warnings;
use utf8;   # this source embeds literal em-dash (U+2014) SKILL.md/DECOMPOSED.md literals;
            # see coordinator-corrections.md's own account of the em-dash byte/char bug.
# Give STDOUT/STDERR a UTF-8 output layer BEFORE Test::More/Test2 initialise
# (their TAP formatter dups the handle it prints through at import time, so a
# binmode() issued later as an ordinary runtime statement never reaches it --
# a plain `binmode(STDOUT, ...)` placed after `use Test::More;` is silently
# too late no matter where it sits in the source). This is what actually
# fixes "Wide character in print at .../Test2/Formatter/TAP.pm" for the
# em-dash/multiplication-sign literals this file prints in test names.
BEGIN { binmode(STDOUT, ':encoding(UTF-8)'); binmode(STDERR, ':encoding(UTF-8)'); }
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Config;
# T-M builds synthetic transcripts and compares captured bytes. `use utf8`
# above means the literals in this file are CHARACTER strings, so anything
# compared against a file's contents has to be encoded first -- hence encode().
use Encode qw(encode);
use JSON::PP ();

# 77-feedback.t  (was 77-feedback-intake.t)
#
# Test oracle for blueprint package b25-feedback-intake, derived from
# specs/b25-feedback-intake-spec.md (revision 2, gate-passed) and
# packages/b25-feedback-intake.md's 13 done-criteria bullets.
#
# Covers two absent deliverables:
#   plugins/butler/scripts/bp-feedback.pl        (CLI, R-06)
#   plugins/butler/skills/feedback/SKILL.md (skill, R-05; renamed from
#     feedback-intake/ when the skill gained the paste-it-as-the-argument
#     entry point and became /butler:feedback)
# Neither exists yet, on purpose: this file is the immutable oracle a
# later implementer works against, authored blind to any implementation.
#
# AC groups (test-plan groups from the spec, section "t/77 -- test plan"):
#   T-A  source lint (no subprocess)
#   T-B  happy paths: argv / stdin / --source / header shape / verbatim body
#   T-C  batch selection: empty -> batch-1; open reused; closed -> next
#        created (closed left byte-identical); numeric ordering; --batch
#        override onto a closed batch
#   T-D  numbering + no-overwrite: max+1, gaps never filled, zero-byte
#        squatter left alone
#   T-E  concurrency (SKIP unless fork available)
#   T-F  refusals: C0/DEL bytes, tab/LF/CR preserved, invalid UTF-8
#   T-G  failure paths F1-F16 (F13/F14/F15/F16 SKIPped -- see notes there;
#        untestable black-box under this container's root privilege)
#   T-H  red-team surface: huge paste, </dev/null no-hang, symlinked batch
#        dir, symlinked target filename, corrections/<batch> as a file
#   T-I  blueprint provenance: --blueprint / BP_BLUEPRINT / scan-0/1/2
#   T-J  SKILL.md: frontmatter, structure, required literals L1-L33,
#        prohibited strings
#   T-K  drift (SKIP-guarded on real corrections/batch-1/DECOMPOSED.md):
#        D-a..D-e structural properties only -- never a total, a line
#        number, Source universality, per-finding Disposition, or
#        monotonic IDs (G4 of the spec; A0 of coordinator-corrections.md)
#
# Hermeticity: every CLI invocation gets --data-dir pointed at a fresh
# File::Temp::tempdir(CLEANUP => 1); $ENV{CCPRAXIS_DATA_DIR} is scrubbed
# file-wide (deleted, or set to the same tempdir) so a flag-parsing bug
# cannot fall through to the real tree; $ENV{BP_BLUEPRINT} is deleted
# file-wide and only ever locally re-set inside a bare block for the one
# group that tests it. The real corrections/ tree is snapshotted
# (recursive path => bytes) before the first test and compared identical
# after the last one, SKIP-guarded on its presence (it is gitignored and
# untracked -- absent on a fresh clone or the Windows host).

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

my $HERE      = abs_path(__FILE__);
my $REPO_ROOT = abs_path(File::Spec->catdir(dirname($HERE), ('..') x 4));
my $SCRIPT    = File::Spec->catfile($REPO_ROOT, qw(plugins butler scripts bp-feedback.pl));
my $SKILL     = File::Spec->catfile($REPO_ROOT, qw(plugins butler skills feedback SKILL.md));
my $VERIFIER  = File::Spec->catfile($REPO_ROOT, qw(plugins butler agents bp-feedback-verifier.md));
my $REAL_CORRECTIONS = File::Spec->catdir($REPO_ROOT, '.ccpraxis-local-data', 'corrections');
my $REAL_DECOMPOSED  = File::Spec->catfile($REAL_CORRECTIONS, 'batch-1', 'DECOMPOSED.md');
my $LIVE_ORCHESTRATOR = File::Spec->catfile($REPO_ROOT, qw(plugins butler scripts bp-orchestrator.pl));

ok(-d $REPO_ROOT, "sanity: repo root resolved ($REPO_ROOT)");

# Hermeticity belt-and-braces (spec: "t/77 -- test plan" / Hermeticity).
delete $ENV{CCPRAXIS_DATA_DIR};
delete $ENV{BP_BLUEPRINT};

# ---------------------------------------------------------------------------
# Scaffolding
# ---------------------------------------------------------------------------

sub _slurp_bytes {
    my ($path) = @_;
    return undef unless -f $path;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $d = <$fh>;
    close $fh;
    return defined $d ? $d : '';
}

# UTF-8-decoded text read, for literal/heading comparisons against SKILL.md
# and DECOMPOSED.md (both contain non-ASCII, e.g. em-dash headings).
sub _slurp_text {
    my ($path) = @_;
    return undef unless -f $path;
    open my $fh, '<:encoding(UTF-8)', $path or return undef;
    local $/;
    my $d = <$fh>;
    close $fh;
    return defined $d ? $d : '';
}

# Functional symlink probe. Perl on Windows *implements* symlink() -- so a
# bare `eval { symlink(...) }` capability check reports "supported" -- but the
# call still fails at runtime: a dangling target is ENOENT (Windows must know
# at creation time whether the link is to a file or a directory), and a link
# that does get created is not reported by -l the way the CLI's own checks
# assume. The T-H symlink group therefore used to `die "symlink: $!"` on the
# Windows host, killing the whole FILE mid-subtest and taking T-I, T-J and T-K
# down with it -- including every SKILL.md assertion. Probe for real behaviour
# (make a link to a real dir AND to a dangling path, and require -l on both)
# and SKIP loudly instead, so the coverage gap is visible rather than either
# faked green or catastrophically red.
my $SYMLINK_WORKS = do {
    my $probe = tempdir(CLEANUP => 1);
    my $real  = File::Spec->catdir($probe, 'real');
    make_path($real);
    my $ok = eval {
        symlink($real, File::Spec->catdir($probe, 'to-real')) or die "to-real: $!\n";
        symlink(File::Spec->catfile($probe, 'nope'), File::Spec->catdir($probe, 'dangling'))
            or die "dangling: $!\n";
        (-l File::Spec->catdir($probe, 'to-real') && -l File::Spec->catdir($probe, 'dangling')) ? 1 : 0;
    };
    $ok ? 1 : 0;
};

# Does $dir have an ancestor containing .ccpraxis-local-data? F9 asserts that
# <data> resolution FAILS, which presumes the scratch dir has no such ancestor.
# On the Windows host that presumption is false: Git Bash maps /tmp to
# C:\Users\<user>\AppData\Local\Temp, so every tempdir() sits under
# C:\Users\<user>\, and a real ~/.ccpraxis-local-data there makes the walk-up
# succeed -- turning F9 red AND writing a stray corrections/ tree into the
# user's home. Detect the broken premise and skip rather than mis-report.
sub _has_data_ancestor {
    my ($dir) = @_;
    $dir = abs_path($dir) // $dir;
    while (1) {
        return $dir if -d File::Spec->catdir($dir, '.ccpraxis-local-data');
        my $parent = abs_path(File::Spec->catdir($dir, File::Spec->updir));
        last if !defined $parent || $parent eq $dir;
        $dir = $parent;
    }
    return undef;
}

sub _write_bytes {
    my ($path, $bytes) = @_;
    make_path(dirname($path));
    open my $fh, '>:raw', $path or die "scaffold write $path: $!";
    print {$fh} $bytes;
    close $fh or die "scaffold close $path: $!";
}

# Recursive manifest of a directory: relpath => bytes, for regular files
# only (symlinks are stat'd separately where a test cares). undef if the
# dir does not exist. Used to prove "byte-identical" and "entry set
# unchanged" without depending on mtimes/line-numbers/counts.
sub _dir_manifest {
    my ($dir) = @_;
    return undef unless -d $dir;
    my %manifest;
    my @stack = ('');
    while (@stack) {
        my $rel = pop @stack;
        my $abs = length($rel) ? File::Spec->catdir($dir, $rel) : $dir;
        opendir my $dh, $abs or next;
        for my $ent (readdir $dh) {
            next if $ent eq '.' || $ent eq '..';
            my $relent = length($rel) ? "$rel/$ent" : $ent;
            my $absent = File::Spec->catfile($dir, $relent);
            if (-d $absent && !-l $absent) {
                push @stack, $relent;
            } elsif (-f $absent) {
                $manifest{$relent} = _slurp_bytes($absent);
            } else {
                # symlink, dangling link, or other special entry: record
                # its presence and (if resolvable) target, never its bytes.
                $manifest{$relent} = -l $absent ? ('SYMLINK->' . (readlink($absent) // '?')) : 'SPECIAL';
            }
        }
        closedir $dh;
    }
    return \%manifest;
}

# Redirect this process's own STDIN/STDOUT/STDERR onto real temp files
# around a list-form system(), then restore -- the mechanism the spec
# mandates (no IPC::Open3, which deadlocks on the 2 MiB payload; no
# in-memory scalar handles, which die "Bad file descriptor" under
# Git-for-Windows perl per the project CLAUDE.md).
sub _run_capture {
    my (%a) = @_;
    my $in  = File::Temp->new; binmode $in;
    print {$in} (defined $a{stdin} ? $a{stdin} : '');
    close $in;
    my $out = File::Temp->new; close $out;
    my $err = File::Temp->new; close $err;

    open(my $oi, '<&', \*STDIN)  or die "dup STDIN: $!";
    open(my $oo, '>&', \*STDOUT) or die "dup STDOUT: $!";
    open(my $oe, '>&', \*STDERR) or die "dup STDERR: $!";

    open(STDIN,  '<', "$in")  or die "reopen STDIN: $!";
    open(STDOUT, '>', "$out") or die "reopen STDOUT: $!";
    open(STDERR, '>', "$err") or die "reopen STDERR: $!";

    my $rc = system(@{ $a{cmd} });

    open(STDIN,  '<&', $oi) or die "restore STDIN: $!";
    open(STDOUT, '>&', $oo) or die "restore STDOUT: $!";
    open(STDERR, '>&', $oe) or die "restore STDERR: $!";

    my $exit = ($rc == -1) ? -1 : ($rc >> 8);
    return ($exit, _slurp_bytes("$out"), _slurp_bytes("$err"));
}

# run_cli(stdin => $bytes, args => [...], cwd => $dir) -> ($rc, $out, $err)
# The spec's mandated helper: (stdin, args) -> ($rc, $out, $err) via
# list-form system($^X, $SCRIPT, @args). An optional cwd temporarily
# chdirs for the duration of the call (used only by the F9 <data>
# resolution test, restored immediately after).
sub run_cli {
    my (%a) = @_;
    if (defined $a{cwd}) {
        my $save = Cwd::getcwd();
        chdir $a{cwd} or die "chdir $a{cwd}: $!";
        my @r = _run_capture(cmd => [$^X, $SCRIPT, @{ $a{args} || [] }], stdin => $a{stdin});
        chdir $save or die "chdir back $save: $!";
        return @r;
    }
    return _run_capture(cmd => [$^X, $SCRIPT, @{ $a{args} || [] }], stdin => $a{stdin});
}

# Split a written feedback file into (header-fields-hashref, body-bytes).
# Header/body are separated by exactly one blank line (G1/G2); split on
# the FIRST "\n\n" only, since the body itself may legitimately contain
# blank lines.
sub _parse_written {
    my ($bytes) = @_;
    return (undef, undef) unless defined $bytes;
    my $idx = index($bytes, "\n\n");
    return ({}, $bytes) if $idx < 0;   # no header at all (not expected from the CLI's own writes)
    my $header = substr($bytes, 0, $idx);
    my $body   = substr($bytes, $idx + 2);
    my %fields;
    for my $line (split /\n/, $header) {
        if ($line =~ /^\*\*(Captured|Source|Blueprint):\*\*\s?(.*)$/) {
            $fields{$1} = $2;
        }
    }
    return (\%fields, $body);
}

sub _batch_dir { my ($tmp, $n) = @_; return File::Spec->catdir($tmp, 'corrections', "batch-$n"); }

# Create an OPEN batch (no DECOMPOSED.md) with the given pre-existing
# feedback files (name => bytes).
sub _make_open_batch {
    my ($tmp, $n, %files) = @_;
    my $dir = _batch_dir($tmp, $n);
    make_path($dir);
    _write_bytes(File::Spec->catfile($dir, $_), $files{$_}) for keys %files;
    return $dir;
}

# Create a CLOSED batch (has DECOMPOSED.md) with the given pre-existing
# feedback files.
sub _make_closed_batch {
    my ($tmp, $n, %files) = @_;
    my $dir = _make_open_batch($tmp, $n, %files);
    _write_bytes(File::Spec->catfile($dir, 'DECOMPOSED.md'), "# batch-$n decomposition (fixture)\n");
    return $dir;
}

# ---------------------------------------------------------------------------
# Real corrections/ guard -- snapshot before, compared after (SKIP-guarded)
# ---------------------------------------------------------------------------

my $HAVE_REAL_CORRECTIONS = -d $REAL_CORRECTIONS;
my $real_snapshot_before  = $HAVE_REAL_CORRECTIONS ? _dir_manifest($REAL_CORRECTIONS) : undef;

# ===========================================================================
# T-A -- source lint (no subprocess)
# ===========================================================================

subtest 'T-A source lint (criteria 1,5,6,7 shape)' => sub {
    ok(-f $SCRIPT, "bp-feedback.pl exists at the write-set path ($SCRIPT)")
        or diag("not yet implemented -- expected until step 4 of the pipeline");

    SKIP: {
        skip 'bp-feedback.pl does not exist yet (implementation absent)', 15 unless -f $SCRIPT;

        my ($crc, $cout, $cerr) = _run_capture(cmd => [$^X, '-c', $SCRIPT]);
        is($crc, 0, 'AC-lint: perl -c exits 0');
        like($cerr, qr/syntax OK/, 'AC-lint: perl -c reports syntax OK');

        my $src = _slurp_bytes($SCRIPT);
        like($src, qr/^#!\/usr\/bin\/env perl/, 'AC-lint: shebang is #!/usr/bin/env perl');
        like($src, qr/use strict/,   'AC-lint: use strict present');
        like($src, qr/use warnings/, 'AC-lint: use warnings present');
        unlike($src, qr/use v5\.\d/, 'AC-lint: no use v5.x pragma (spec: universal list omits it)');

        ok(index($src, '\x00-\x08\x0B\x0C\x0E-\x1F\x7F') >= 0,
           'AC-24: literal C0/DEL character class is hardcoded verbatim');

        # AC-24 citation (coordinator fix #2, post-gate): content-anchored,
        # deliberately NOT line-anchored. bp-orchestrator.pl is a live file
        # edited by several concurrently-running packages -- its C0-class
        # line moved TWICE inside a single work session (:506 -> :763 -> :764,
        # touched by b08/b09 mid-run). A verified LINE NUMBER citation would
        # make t/77 go red every time an unrelated package edits that file --
        # exactly the failure mode this blueprint's SYN-11 warns against
        # (a package judged by failures it does not own). So: assert the
        # FILENAME is cited (no line number required), and separately assert
        # the live file contains the class literal by CONTENT SEARCH, never
        # by index. (Contrast AC-CIT-1 just below/in T-K: that one *is*
        # correctly line-anchored, because DECOMPOSED.md is not edited by
        # other packages the way bp-orchestrator.pl is, and the skill's own
        # text names a specific line -- verifying it is the whole point.)
        like($src, qr/bp-orchestrator\.pl/,
             'AC-24: cites bp-orchestrator.pl (by filename) as the class origin (Pre-settled #1); no line number is required');
        SKIP: {
            skip 'live bp-orchestrator.pl is absent', 1 unless -f $LIVE_ORCHESTRATOR;
            my $orch_src = _slurp_bytes($LIVE_ORCHESTRATOR);
            ok(index($orch_src, '\x00-\x08\x0B\x0C\x0E-\x1F\x7F') >= 0,
               'AC-24: the live bp-orchestrator.pl still contains the C0/DEL class literal today (found by content search, not by line index)');
        }

        unlike($src, qr/Getopt::Long/, 'AC-lint: does not use Getopt::Long (Pre-settled #5)');
        unlike($src, qr/ledger-guard\.sh/, 'AC-lint: never sources/execs ledger-guard.sh (Pre-settled #1)');
        unlike($src, qr/-t\s*STDIN/, 'AC-lint: never uses -t STDIN (Pre-settled #5)');
        unlike($src, qr/>>/, 'AC-lint: no append-mode write anywhere (G2: never appends to an existing file)');
        unlike($src, qr/--file\b/, 'AC-lint: no --file mode (dropped scope, spec CLI contract)');

        ok(index($src, 'O_EXCL') >= 0, 'AC-27: uses O_EXCL for name reservation (G1)');
    }
};

# ===========================================================================
# T-B -- happy paths: argv / stdin / --source / header shape / verbatim body
# ===========================================================================

subtest 'T-B happy paths (criteria 1,2,3)' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    local $ENV{CCPRAXIS_DATA_DIR} = $tmp;

    # AC-1/AC-2: one invocation, argv text, exits 0, STDOUT is exactly one line.
    my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, 'hello there']);
    is($rc, 0, 'AC-1: argv text -> exit 0');
    like($out, qr/^\S.*\n\z/s, 'AC-2: STDOUT is exactly one newline-terminated line');
    is(() = ($out =~ /\n/g), 1, 'AC-2: STDOUT contains exactly one newline (one line, nothing else)');
    my $path1 = $out; chomp $path1;

    SKIP: {
        skip 'no output path to inspect (bp-feedback.pl not implemented)', 5 unless $rc == 0 && length($path1) && -f $path1;
        is(-f $path1 ? 1 : 0, 1, 'AC-1: the path STDOUT names is the file actually written');
        my $bytes = _slurp_bytes($path1);
        my ($fields, $body) = _parse_written($bytes);
        is($body, 'hello there', 'AC-3: argv body round-trips verbatim (word-joined)');
        is($fields->{Source}, 'chat', 'AC-8: default source token is "chat"');
        like($fields->{Captured}, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/,
             'AC-7: Captured timestamp matches the house ISO-8601-UTC-Z shape');
        is(substr($bytes, -1), 'e', 'G2: no trailing newline added when body has none ("hello there" ends in e)');
    }

    # AC-4: stdin round-trip with CRLF + non-ASCII + zero trailing newline.
    my $stdin_body = "Caf\x{c3}\x{a9} line one\r\nline two, no trailing newline.";
    ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp], stdin => $stdin_body);
    is($rc, 0, 'AC-4: stdin-only invocation -> exit 0');
    my $path2 = $out; chomp $path2;
    SKIP: {
        skip 'no output path to inspect (bp-feedback.pl not implemented)', 2 unless $rc == 0 && length($path2) && -f $path2;
        my (undef, $body2) = _parse_written(_slurp_bytes($path2));
        is($body2, $stdin_body, 'AC-4: stdin body round-trips byte-for-byte (CRLF + non-ASCII + no trailing newline preserved)');
        is(substr($body2, -1), '.', 'G2: last byte of a no-trailing-newline stdin body is preserved exactly');
    }

    # AC-5: argv wins over stdin; stdin must never be read when argv present.
    ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, 'argv wins'], stdin => 'STDIN SHOULD NOT APPEAR');
    is($rc, 0, 'AC-5: argv+stdin both present -> exit 0');
    my $path3 = $out; chomp $path3;
    SKIP: {
        skip 'no output path to inspect (bp-feedback.pl not implemented)', 1 unless $rc == 0 && length($path3) && -f $path3;
        my (undef, $body3) = _parse_written(_slurp_bytes($path3));
        is($body3, 'argv wins', 'AC-5: body is the argv text; stdin is never read when argv is present');
    }

    # AC-8: --source file renders **Source:** file.
    ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--source', 'file', 'from a file']);
    is($rc, 0, 'AC-8: --source file -> exit 0');
    my $path4 = $out; chomp $path4;
    SKIP: {
        skip 'no output path to inspect (bp-feedback.pl not implemented)', 1 unless $rc == 0 && length($path4) && -f $path4;
        my ($fields4) = _parse_written(_slurp_bytes($path4));
        is($fields4->{Source}, 'file', 'AC-8: --source file renders as **Source:** file');
    }

    # AC-6: --help exits 0, usage on STDOUT, nothing required on STDERR.
    ($rc, $out, $err) = run_cli(args => ['--help']);
    is($rc, 0, 'AC-6: --help exits 0');
    like($out, qr/bp-feedback/i, 'AC-6: --help prints usage naming the program on STDOUT');
};

# ===========================================================================
# T-C -- batch selection (the open/closed rule; the gate's central fixture)
# ===========================================================================

subtest 'T-C batch selection (criterion 4; AC-12..AC-16)' => sub {
    # (a) corrections/ absent entirely -> batch-1 created and used.
    {
        my $tmp = tempdir(CLEANUP => 1);
        local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, 'first ever feedback']);
        is($rc, 0, 'AC-12: corrections/ absent -> exit 0');
        my $path = $out; chomp $path;
        is($path, File::Spec->catfile(_batch_dir($tmp, 1), 'feedback-1.txt'),
           'AC-12: corrections/ absent -> batch-1/feedback-1.txt created and used');
    }

    # (b) batch-1 open (no DECOMPOSED.md, has feedback-1.txt) -> reused, no new dir.
    {
        my $tmp = tempdir(CLEANUP => 1);
        local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
        _make_open_batch($tmp, 1, 'feedback-1.txt' => "pre-existing\r\n");
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, 'second feedback']);
        is($rc, 0, 'AC-13: newest batch open -> exit 0');
        my $path = $out; chomp $path;
        is($path, File::Spec->catfile(_batch_dir($tmp, 1), 'feedback-2.txt'),
           'AC-13: newest OPEN batch is reused (feedback-2.txt lands in batch-1, no batch-2 created)');
        ok(!-d _batch_dir($tmp, 2), 'AC-13: no batch-2 directory was created while batch-1 is open');
    }

    # (c) batch-1 closed -> batch-2 created and used; batch-1 left byte-identical.
    {
        my $tmp = tempdir(CLEANUP => 1);
        local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
        _make_closed_batch($tmp, 1, 'feedback-1.txt' => "closed batch evidence\r\n");
        my $before = _dir_manifest(_batch_dir($tmp, 1));
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, 'third feedback']);
        is($rc, 0, 'AC-14: newest batch closed -> exit 0 (not a failure path)');
        my $path = $out; chomp $path;
        is($path, File::Spec->catfile(_batch_dir($tmp, 2), 'feedback-1.txt'),
           'AC-14: newest batch closed -> batch-2 created and used (never appended into the closed batch)');
        is_deeply(_dir_manifest(_batch_dir($tmp, 1)), $before,
             'AC-14: the closed batch-1 entry set and every file\'s bytes are unchanged');
    }

    # (d) batch-2 closed + batch-10 open -> batch-10 used (numeric, not lexical).
    {
        my $tmp = tempdir(CLEANUP => 1);
        local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
        _make_closed_batch($tmp, 2, 'feedback-1.txt' => 'x');
        _make_open_batch($tmp, 10, 'feedback-1.txt' => 'y');
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, 'numeric ordering']);
        is($rc, 0, 'AC-15: numeric resolution -> exit 0');
        my $path = $out; chomp $path;
        is($path, File::Spec->catfile(_batch_dir($tmp, 10), 'feedback-2.txt'),
           'AC-15: batch-10 (numerically newest, open) is used, not batch-2 (lexically it would sort first)');
    }

    # (e) batch-2 closed + batch-10 closed -> batch-11 created (numeric max+1).
    {
        my $tmp = tempdir(CLEANUP => 1);
        local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
        _make_closed_batch($tmp, 2,  'feedback-1.txt' => 'x');
        _make_closed_batch($tmp, 10, 'feedback-1.txt' => 'y');
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, 'both closed']);
        is($rc, 0, 'AC-15: both closed -> exit 0');
        my $path = $out; chomp $path;
        is($path, File::Spec->catfile(_batch_dir($tmp, 11), 'feedback-1.txt'),
           'AC-15: batch-11 = numeric max(2,10)+1, created and used');
    }

    # (f) --batch batch-1 with batch-1 closed -> honoured (explicit override).
    {
        my $tmp = tempdir(CLEANUP => 1);
        local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
        _make_closed_batch($tmp, 1, 'feedback-1.txt' => 'x');
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--batch', 'batch-1', 'explicit override']);
        is($rc, 0, 'AC-16: --batch overrides onto a closed batch -> exit 0 (not refused)');
        my $path = $out; chomp $path;
        is($path, File::Spec->catfile(_batch_dir($tmp, 1), 'feedback-2.txt'),
           'AC-16: --batch batch-1 writes into the closed batch-1, honouring explicit operator intent');
        ok(!-d _batch_dir($tmp, 2), 'AC-16: no batch-2 was created when --batch named batch-1 explicitly');
    }
};

# ===========================================================================
# T-D -- numbering and no-overwrite
# ===========================================================================

subtest 'T-D numbering and no-overwrite (criterion 4; AC-17..AC-20)' => sub {
    # max+1, gaps never filled.
    {
        my $tmp = tempdir(CLEANUP => 1);
        local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
        _make_open_batch($tmp, 1, 'feedback-1.txt' => 'a', 'feedback-3.txt' => 'c');
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--batch', 'batch-1', 'gap test']);
        is($rc, 0, 'AC-17: gap present (1,3) -> exit 0');
        my $path = $out; chomp $path;
        is($path, File::Spec->catfile(_batch_dir($tmp, 1), 'feedback-4.txt'),
           'AC-17: next file is feedback-4.txt = max(1,3)+1; the gap at 2 is never filled');
        is(_slurp_bytes(File::Spec->catfile(_batch_dir($tmp, 1), 'feedback-1.txt')), 'a',
           'AC-18: pre-existing feedback-1.txt is byte-identical after the run');
        is(_slurp_bytes(File::Spec->catfile(_batch_dir($tmp, 1), 'feedback-3.txt')), 'c',
           'AC-18: pre-existing feedback-3.txt is byte-identical after the run');
        ok(!-e File::Spec->catfile(_batch_dir($tmp, 1), 'feedback-2.txt'),
           'AC-17: the gap slot feedback-2.txt was never created');
    }

    # Zero-byte squatter (crash-degradation shape, G1's documented degradation):
    # a pre-existing zero-byte feedback-4.txt is counted by the numbering scan
    # like any other occupant and is never written through.
    {
        my $tmp = tempdir(CLEANUP => 1);
        local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
        _make_open_batch($tmp, 1, 'feedback-3.txt' => 'c', 'feedback-4.txt' => '');
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--batch', 'batch-1', 'past the squatter']);
        is($rc, 0, 'AC-19: zero-byte squatter present -> exit 0');
        my $path = $out; chomp $path;
        is($path, File::Spec->catfile(_batch_dir($tmp, 1), 'feedback-5.txt'),
           'AC-19: numbering steps past the occupied feedback-4.txt slot to feedback-5.txt');
        is(-s File::Spec->catfile(_batch_dir($tmp, 1), 'feedback-4.txt'), 0,
           'AC-19: the zero-byte squatter is left untouched (still zero bytes, never opened for write)');
    }
};

# ===========================================================================
# T-E -- concurrency (criterion 6; AC-26). SKIP unless fork is available.
# ===========================================================================

subtest 'T-E concurrency (criterion 6; AC-26)' => sub {
    plan skip_all => 'no fork/pseudofork available on this perl/platform'
        unless $Config{d_fork} || $Config{d_pseudofork};

    my $tmp = tempdir(CLEANUP => 1);
    local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
    _make_open_batch($tmp, 1);

    my $K = 5;
    my @pids;
    for my $i (1 .. $K) {
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            open(STDIN,  '<', File::Spec->devnull) or die $!;
            open(STDOUT, '>', File::Spec->catfile($tmp, "child-$i.out")) or die $!;
            open(STDERR, '>', File::Spec->catfile($tmp, "child-$i.err")) or die $!;
            exec($^X, $SCRIPT, '--data-dir', $tmp, '--batch', 'batch-1', "concurrent payload $i");
            exit 97; # exec itself failed to launch (not "script exited non-zero")
        }
        push @pids, $pid;
    }
    waitpid($_, 0) for @pids;

    my $manifest = _dir_manifest(_batch_dir($tmp, 1));
    my @feedback_files = sort grep { /^feedback-\d+\.txt$/ } keys %$manifest;
    is(scalar(@feedback_files), $K, "AC-26: $K concurrent invocations produce exactly $K distinct feedback-N.txt files (no lost writer, no collision)");

    my %payload_seen;
    for my $f (@feedback_files) {
        my (undef, $body) = _parse_written($manifest->{$f});
        $payload_seen{$body // ''}++ if defined $body;
    }
    is(scalar(keys %payload_seen), $K, 'AC-26: all K payloads are present and distinct (no overwrite, no truncation)');

    my @residue = grep { /\.tmp\.\d+\z/ } keys %$manifest;
    is(scalar(@residue), 0, 'AC-25/AC-26: no *.tmp.<pid> residue survives concurrent invocations');
};

# ===========================================================================
# T-F -- refusals: C0/DEL bytes; tab/LF/CR preserved; invalid UTF-8
# ===========================================================================

subtest 'T-F refusals (criterion 5; AC-21..AC-23)' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
    _make_open_batch($tmp, 1);

    for my $byte (0x00, 0x01, 0x1F, 0x7F) {
        my $body = 'before' . chr($byte) . 'after';
        my $before_count = scalar(grep { /^feedback-\d+\.txt$/ } keys %{ _dir_manifest(_batch_dir($tmp, 1)) });
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--batch', 'batch-1'], stdin => $body);
        is($rc, 3, sprintf('AC-21: control byte 0x%02X in body -> exit 3', $byte));
        is($out, '', sprintf('AC-21: 0x%02X refusal -> STDOUT empty', $byte));
        like($err, qr/^bp-feedback: /, sprintf('AC-21: 0x%02X refusal message prefixed "bp-feedback: "', $byte));
        my $hexlit = sprintf('0x%02X', $byte);
        like($err, qr/\Q$hexlit\E/, sprintf('F7: message names the offending byte (%s)', $hexlit));
        my $after_count = scalar(grep { /^feedback-\d+\.txt$/ } keys %{ _dir_manifest(_batch_dir($tmp, 1)) });
        is($after_count, $before_count, sprintf('AC-21: 0x%02X refusal -> nothing written (file count unchanged)', $byte));
    }

    # AC-22: tab / LF / CR are permitted and byte-preserved exactly.
    my $ok_body = "col1\tcol2\r\nsecond line\r";
    my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--batch', 'batch-1'], stdin => $ok_body);
    is($rc, 0, 'AC-22: tab/LF/CR body -> exit 0 (not refused)');
    my $path = $out; chomp $path;
    SKIP: {
        skip 'no output path to inspect (bp-feedback.pl not implemented)', 1 unless $rc == 0 && length($path) && -f $path;
        my (undef, $written_body) = _parse_written(_slurp_bytes($path));
        is($written_body, $ok_body, 'AC-22: tab/CR/LF preserved byte-for-byte in the written body');
    }

    # AC-23: invalid UTF-8 (a lone continuation byte, no C0/DEL present) -> exit 5.
    my $bad_utf8 = "before\x80after";
    ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--batch', 'batch-1'], stdin => $bad_utf8);
    is($rc, 5, 'AC-23: invalid UTF-8 body -> exit 5');
    is($out, '', 'AC-23: invalid UTF-8 -> STDOUT empty');
    like($err, qr/^bp-feedback: /, 'AC-23: invalid UTF-8 message prefixed "bp-feedback: "');
};

# ===========================================================================
# T-G -- failure paths F1-F16 (criterion 7; AC-6,28,29)
# ===========================================================================

subtest 'T-G failure paths F1..F12 (criterion 7; AC-28,29)' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
    _make_open_batch($tmp, 1);

    # F1: unknown option.
    my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--batch', 'batch-1', '--bogus-flag', 'x']);
    is($rc, 1, 'F1: unknown option -> exit 1');
    like($err, qr/\[unknown option\]/, 'F1: message carries the [unknown option] fragment');
    like($err, qr/--bogus-flag/, 'F1: message names the offending flag');

    # F2: option missing its value (--batch is the last token).
    ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--batch']);
    is($rc, 1, 'F2: --batch with no value -> exit 1');
    like($err, qr/\[--batch requires a value\]/, 'F2: message carries the [--batch requires a value] fragment');

    # F3: invalid batch name.
    for my $bad ('../escape', '.', '..', 'has a space') {
        ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--batch', $bad, 'text']);
        is($rc, 1, "F3: --batch '$bad' -> exit 1");
        like($err, qr/\[invalid batch name\]/, "F3: --batch '$bad' message carries the [invalid batch name] fragment");
    }

    # F4: invalid source token.
    ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--source', 'bad token', 'text']);
    is($rc, 1, 'F4: --source with an invalid token -> exit 1');
    like($err, qr/\[invalid source token\]/, 'F4: message carries the [invalid source token] fragment');

    # F5: --blueprint empty.
    ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--blueprint', '', 'text']);
    is($rc, 1, 'F5: --blueprint "" -> exit 1');
    like($err, qr/\[--blueprint requires a value\]/, 'F5: message carries the [--blueprint requires a value] fragment');

    # F6: no content from any source (empty stdin, no argv).
    ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--batch', 'batch-1'], stdin => '');
    is($rc, 2, 'F6: empty stdin, no argv -> exit 2');
    like($err, qr/\[no feedback text\]/, 'F6: message carries the [no feedback text] fragment');
    # whitespace-only body is likewise "no content".
    ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--batch', 'batch-1'], stdin => "   \n\t \r\n");
    is($rc, 2, 'F6: whitespace-only stdin -> exit 2 (no non-whitespace byte)');

    # F7: control-byte message contract (byte + offset + actionable phrasing).
    ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--batch', 'batch-1'], stdin => "abc\x00def");
    is($rc, 3, 'F7: NUL in body -> exit 3');
    like($err, qr/\[refusing to write control byte\]/, 'F7: message carries the [refusing to write control byte] fragment');
    like($err, qr/0x00/, 'F7: message names the byte value (0x00)');
    like($err, qr/offset/i, 'F7: message names an offset');

    # F8: invalid UTF-8 message contract.
    ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--batch', 'batch-1'], stdin => "abc\xC3\x28def");
    is($rc, 5, 'F8: malformed UTF-8 sequence -> exit 5');
    like($err, qr/\[input is not valid UTF-8\]/, 'F8: message carries the [input is not valid UTF-8] fragment');

    # F9: <data> unresolvable -- run from a scratch dir outside any git repo,
    # with no --data-dir and no CCPRAXIS_DATA_DIR.
    {
        local $ENV{CCPRAXIS_DATA_DIR};
        delete $ENV{CCPRAXIS_DATA_DIR};
        my $scratch = tempdir(CLEANUP => 1); # normally: not a git repo, no .ccpraxis-local-data ancestor
        my $ancestor = _has_data_ancestor($scratch);
        SKIP: {
            skip "F9 premise broken on this host: $scratch has a .ccpraxis-local-data ancestor at $ancestor, "
               . 'so <data> resolution correctly SUCCEEDS via walk-up and there is nothing to fail', 2
                if defined $ancestor;
            ($rc, $out, $err) = run_cli(args => ['unresolvable data dir'], cwd => $scratch);
            is($rc, 4, 'F9: <data> unresolvable (no flag, no env, no git toplevel, no walk-up match) -> exit 4');
            like($err, qr/\[cannot locate <data>\]/, 'F9: message carries the [cannot locate <data>] fragment');
        }
    }

    # F10: --data-dir path exists but is not a directory.
    my $plain_file = File::Spec->catfile($tmp, 'not-a-directory');
    _write_bytes($plain_file, 'x');
    ($rc, $out, $err) = run_cli(args => ['--data-dir', $plain_file, 'text']);
    is($rc, 4, 'F10: --data-dir names a plain file -> exit 4');
    like($err, qr/\[--data-dir is not a directory\]/, 'F10: message carries the [--data-dir is not a directory] fragment');

    # F11: <data>/corrections/<batch> exists and is not a directory.
    my $tmp11 = tempdir(CLEANUP => 1);
    make_path(File::Spec->catdir($tmp11, 'corrections'));
    _write_bytes(File::Spec->catfile($tmp11, 'corrections', 'batch-1'), 'not a directory');
    ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp11, '--batch', 'batch-1', 'text']);
    is($rc, 4, 'F11: batch-1 exists as a plain file -> exit 4');
    like($err, qr/exists and is not a directory/, 'F11: message carries the "exists and is not a directory" fragment');

    # F12: make_path failure -- corrections/ itself is a plain file, so creating
    # corrections/batch-1 fails structurally (ENOTDIR), independent of privilege.
    my $tmp12 = tempdir(CLEANUP => 1);
    _write_bytes(File::Spec->catfile($tmp12, 'corrections'), 'blocks make_path with ENOTDIR');
    ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp12, 'text']);
    is($rc, 4, 'F12: corrections/ itself is a plain file -> make_path fails -> exit 4');
    like($err, qr/\[make_path\]/, 'F12: message carries the [make_path] fragment');

    # F13/F14/F15/F16: NOT independently exercised here. F13 (reservation fails
    # with anything but EEXIST) and F15 (temp write fails) are permission-bound
    # in the general case, and this container runs as root -- chmod-based
    # denial does not apply to root, so they cannot be induced deterministically
    # without a privilege-independent structural trigger, and none exists for
    # these two (EEXIST is the only structural error O_EXCL/print/close can hit
    # here). F14 (1000 consecutive EEXIST) is reachable only under a true,
    # sustained race across concurrent writers; the numbering scan computes
    # n_start from existing files directly, so pre-creating 1000 sequential
    # names is absorbed by the scan itself rather than exercising the retry
    # loop. F16's "rename fails" branch has no external hook point: the
    # reserve-write-publish sequence is internal to one CLI invocation with no
    # black-box point to inject a mid-flight collision. Reported here rather
    # than faked; F16's OTHER clause ("$final is non-empty and not ours") is
    # structurally impossible to reach because $final is always this same
    # process's freshly-reserved, still-zero-byte placeholder at publish time.
    ok(1, 'F13/F14/F15/F16: documented as untestable black-box under this environment (see comment above)');
};

# ===========================================================================
# T-H -- red-team surface
# ===========================================================================

subtest 'T-H red-team surface (all criteria; cross-cutting)' => sub {
    # Huge paste: 2 MiB stdin round-trips byte-identical, no cap/truncation.
    {
        my $tmp = tempdir(CLEANUP => 1);
        local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
        _make_open_batch($tmp, 1);
        # Built via pack('C*', ...) rather than a \x{E9} escape under `use
        # utf8`, deliberately dodging the Perl UTF8-flag trap: a codepoint
        # < 256 written as \x{E9} is stored as Latin-1 with the internal
        # UTF8 flag OFF, so "utf8::encode(...) if utf8::is_utf8(...)" never
        # fires and the RAW single byte 0xE9 -- an invalid standalone UTF-8
        # sequence -- ends up on the wire, which trips AC-23's invalid-UTF-8
        # refusal (exit 5) instead of exercising size handling (exit 0) --
        # i.e. the fixture would demand both exit 0 (here) and exit 5
        # (AC-23) for the same bytes, which no implementation can satisfy.
        # pack('C*', 0xC3, 0xA9) is unambiguously the two valid UTF-8 bytes
        # for U+00E9 (e-acute), with no flag interpretation involved at all.
        my $eacute = pack('C*', 0xC3, 0xA9);
        my $chunk  = "The operator's words, verbatim, non-ASCII caf${eacute}. ";
        my $huge   = $chunk x 50000; # ~2.3 MiB, valid UTF-8 throughout
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--batch', 'batch-1'], stdin => $huge);
        is($rc, 0, 'red-team: huge paste (>2 MiB) -> exit 0, no size cap');
        my $path = $out; chomp $path;
        SKIP: {
            skip 'no output path to inspect (bp-feedback.pl not implemented)', 1 unless $rc == 0 && length($path) && -f $path;
            my (undef, $written) = _parse_written(_slurp_bytes($path));
            is($written, $huge, 'red-team: huge paste round-trips byte-identical (no truncation, no mangling)');
        }
    }

    # </dev/null shape: empty stdin, no argv -> exit 2, must never hang.
    {
        my $tmp = tempdir(CLEANUP => 1);
        local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
        _make_open_batch($tmp, 1);
        my $hung = 0;
        my ($rc, $out, $err);
        eval {
            local $SIG{ALRM} = sub { $hung = 1; die "alarm\n" };
            alarm(20);
            ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--batch', 'batch-1'], stdin => '');
            alarm(0);
        };
        alarm(0);
        ok(!$hung, 'red-team: empty stdin + no argv never hangs (a -t STDIN detector would; F6 exit path must not)');
        is($rc, 2, 'red-team: empty stdin + no argv -> exit 2, promptly') unless $hung;
    }

    # Symlinked batch dir resolving to a real directory: accepted, observable note.
    SKIP: {
        skip 'symlink() does not work functionally on this platform (see $SYMLINK_WORKS probe) '
           . '-- symlinked-batch-dir coverage NOT exercised here', 5 unless $SYMLINK_WORKS;
        {
            my $tmp = tempdir(CLEANUP => 1);
            local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
            my $target = File::Spec->catdir($tmp, 'real-storage');
            make_path($target);
            make_path(File::Spec->catdir($tmp, 'corrections'));
            symlink($target, File::Spec->catdir($tmp, 'corrections', 'batch-1'))
                or die "symlink: $!";
            my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, 'via a symlinked batch dir']);
            is($rc, 0, 'red-team: symlinked batch dir resolving to a real dir -> exit 0 (accepted)');
            like($err, qr/symlink/i, 'red-team: STDERR carries an observability note naming the symlink');
            ok(-f File::Spec->catfile($target, 'feedback-1.txt'),
               'red-team: the write lands in the symlink TARGET, not as a broken link at the batch path');
        }

        # Symlinked batch dir to nothing (dangling): F11, exit 4, nothing written.
        {
            my $tmp = tempdir(CLEANUP => 1);
            local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
            make_path(File::Spec->catdir($tmp, 'corrections'));
            symlink(File::Spec->catfile($tmp, 'does-not-exist-anywhere'),
                    File::Spec->catdir($tmp, 'corrections', 'batch-1')) or die "symlink: $!";
            my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--batch', 'batch-1', 'text']);
            is($rc, 4, 'red-team: batch dir is a dangling symlink -> F11, exit 4');
            like($err, qr/exists and is not a directory|not a directory/i, 'red-team: dangling-symlink-as-batch-dir message names the problem');
        }
    }

    # Symlinked (dangling) target filename at the exact n_start slot: never
    # followed, never removed; numbering steps to the next name.
    SKIP: {
        skip 'symlink() does not work functionally on this platform (see $SYMLINK_WORKS probe) '
           . '-- squatting-dangling-symlink coverage NOT exercised here', 3 unless $SYMLINK_WORKS;
        my $tmp = tempdir(CLEANUP => 1);
        local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
        _make_open_batch($tmp, 1);
        my $squat = File::Spec->catfile(_batch_dir($tmp, 1), 'feedback-1.txt');
        symlink(File::Spec->catfile($tmp, 'nowhere'), $squat) or die "symlink: $!";
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--batch', 'batch-1', 'past a dangling symlink']);
        is($rc, 0, 'red-team: dangling symlink squats feedback-1.txt -> exit 0, steps over it');
        my $path = $out; chomp $path;
        is($path, File::Spec->catfile(_batch_dir($tmp, 1), 'feedback-2.txt'),
           'red-team: numbering steps to feedback-2.txt without following/removing the dangling symlink');
        ok(-l $squat, 'red-team: the dangling symlink at feedback-1.txt is untouched (still a symlink)');
    }

    # Body that looks like a header: written verbatim, never parsed/escaped.
    {
        my $tmp = tempdir(CLEANUP => 1);
        local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
        _make_open_batch($tmp, 1);
        my $tricky = "**Captured:** 1999-01-01T00:00:00Z\n**Source:** forged\n\nthis is the real body";
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--batch', 'batch-1'], stdin => $tricky);
        is($rc, 0, 'red-team: body that looks like a header -> exit 0 (not rejected, not specially parsed)');
        my $path = $out; chomp $path;
        SKIP: {
            skip 'no output path to inspect (bp-feedback.pl not implemented)', 1 unless $rc == 0 && length($path) && -f $path;
            my $raw = _slurp_bytes($path);
            ok(index($raw, $tricky) >= 0, 'red-team: the header-shaped body appears verbatim in the written file, unescaped');
        }
    }

    # Non-ASCII path component (Andre), per the project CLAUDE.md landmine.
    {
        my $tmp = tempdir(CLEANUP => 1);
        my $andre_dir = File::Spec->catdir($tmp, "Andr\x{e9}-data");
        make_path($andre_dir);
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $andre_dir, 'non-ascii data-dir path']);
        is($rc, 0, 'red-team: --data-dir containing non-ASCII (Andre) works, path passed through unmodified');
    }
};

# ===========================================================================
# T-I -- blueprint provenance (criterion 3; AC-9,10,11)
# ===========================================================================

sub _blueprint_md_running {
    my ($name, $status) = @_;
    return "# $name\n\n"
         . "```\n"
         . "blueprint: $name\n"
         . "created: 2026-01-01\n"
         . "status: $status         # drafting | audited | running | done | archived -- comment must be stripped\n"
         . "```\n\n## Objective\n\nfixture blueprint for t/77.\n";
}

subtest 'T-I blueprint provenance (criterion 3; AC-9,10,11)' => sub {
    # Zero running -> field omitted, no STDERR note, exit 0.
    {
        my $tmp = tempdir(CLEANUP => 1);
        local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
        _write_bytes(File::Spec->catfile($tmp, 'blueprints', 'idle-one', 'blueprint.md'),
                     _blueprint_md_running('idle-one', 'done'));
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, 'zero running']);
        is($rc, 0, 'AC-10: zero running blueprints -> exit 0');
        my $path = $out; chomp $path;
        SKIP: {
            skip 'no output path to inspect (bp-feedback.pl not implemented)', 1 unless $rc == 0 && length($path) && -f $path;
            my ($fields) = _parse_written(_slurp_bytes($path));
            ok(!exists $fields->{Blueprint}, 'AC-10: **Blueprint:** field is omitted entirely when zero are running');
        }
        is($err, '', 'AC-10: zero running -> nothing on STDERR');
    }

    # Exactly one running -> field present, that name.
    {
        my $tmp = tempdir(CLEANUP => 1);
        local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
        _write_bytes(File::Spec->catfile($tmp, 'blueprints', 'solo-runner', 'blueprint.md'),
                     _blueprint_md_running('solo-runner', 'running'));
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, 'one running']);
        is($rc, 0, 'AC-9: exactly one running blueprint -> exit 0');
        my $path = $out; chomp $path;
        SKIP: {
            skip 'no output path to inspect (bp-feedback.pl not implemented)', 1 unless $rc == 0 && length($path) && -f $path;
            my ($fields) = _parse_written(_slurp_bytes($path));
            is($fields->{Blueprint}, 'solo-runner', 'AC-9: **Blueprint:** names the single running blueprint (found via the fenced status: running scan, comment stripped)');
        }
    }

    # Two running -> field omitted, STDERR note, exit 0 (not an error).
    {
        my $tmp = tempdir(CLEANUP => 1);
        local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
        _write_bytes(File::Spec->catfile($tmp, 'blueprints', 'runner-a', 'blueprint.md'), _blueprint_md_running('runner-a', 'running'));
        _write_bytes(File::Spec->catfile($tmp, 'blueprints', 'runner-b', 'blueprint.md'), _blueprint_md_running('runner-b', 'running'));
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, 'two running']);
        is($rc, 0, 'AC-11: two running blueprints -> exit 0 (ambiguity never costs the feedback)');
        my $path = $out; chomp $path;
        SKIP: {
            skip 'no output path to inspect (bp-feedback.pl not implemented)', 1 unless $rc == 0 && length($path) && -f $path;
            my ($fields) = _parse_written(_slurp_bytes($path));
            ok(!exists $fields->{Blueprint}, 'AC-11: **Blueprint:** field is omitted entirely when >= 2 are running');
        }
        like($err, qr/2 blueprints are running/, 'AC-11: STDERR carries an observable note naming the count');
        like($err, qr/blueprint provenance omitted/, 'AC-11: STDERR note explains the field was omitted');
    }

    # --blueprint wins unconditionally, even with zero running and no env var.
    {
        my $tmp = tempdir(CLEANUP => 1);
        local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--blueprint', 'explicit-name', 'explicit wins']);
        is($rc, 0, 'AC-9: --blueprint explicit -> exit 0');
        my $path = $out; chomp $path;
        SKIP: {
            skip 'no output path to inspect (bp-feedback.pl not implemented)', 1 unless $rc == 0 && length($path) && -f $path;
            my ($fields) = _parse_written(_slurp_bytes($path));
            is($fields->{Blueprint}, 'explicit-name', 'AC-9: --blueprint <name> is used verbatim, unconditionally, with no existence check');
        }
    }

    # BP_BLUEPRINT env wins over the scan, but --blueprint still wins over env.
    {
        my $tmp = tempdir(CLEANUP => 1);
        local $ENV{CCPRAXIS_DATA_DIR} = $tmp;
        _write_bytes(File::Spec->catfile($tmp, 'blueprints', 'scanned-one', 'blueprint.md'),
                     _blueprint_md_running('scanned-one', 'running'));
        {
            local $ENV{BP_BLUEPRINT} = 'env-name';
            my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, 'env beats scan']);
            is($rc, 0, 'AC-9: BP_BLUEPRINT set -> exit 0');
            my $path = $out; chomp $path;
            SKIP: {
                skip 'no output path to inspect (bp-feedback.pl not implemented)', 1 unless $rc == 0 && length($path) && -f $path;
                my ($fields) = _parse_written(_slurp_bytes($path));
                is($fields->{Blueprint}, 'env-name', 'AC-9: $ENV{BP_BLUEPRINT} wins over the scan result (resolution order: --blueprint > env > scan)');
            }
        }
        {
            local $ENV{BP_BLUEPRINT} = 'env-name';
            my ($rc, $out, $err) = run_cli(args => ['--data-dir', $tmp, '--blueprint', 'flag-name', 'flag beats env']);
            is($rc, 0, 'AC-9: --blueprint + BP_BLUEPRINT both set -> exit 0');
            my $path = $out; chomp $path;
            SKIP: {
                skip 'no output path to inspect (bp-feedback.pl not implemented)', 1 unless $rc == 0 && length($path) && -f $path;
                my ($fields) = _parse_written(_slurp_bytes($path));
                is($fields->{Blueprint}, 'flag-name', 'AC-9: --blueprint wins unconditionally over $ENV{BP_BLUEPRINT}');
            }
        }
    }
};

# ===========================================================================
# T-J -- SKILL.md: frontmatter, structure, required literals, prohibitions
# ===========================================================================

subtest 'T-J SKILL.md content (criteria 8..12; AC-34..46)' => sub {
    ok(-f $SKILL, "SKILL.md exists at the write-set path ($SKILL)")
        or diag('not yet implemented -- expected until step 4 of the pipeline');

    # No sibling references/ dir or scripts/assets -- house shape is one file.
    my $skill_dir = dirname($SKILL);
    ok(!-d File::Spec->catdir($skill_dir, 'references'),
       'AC-34: no references/ sibling (house shape: single-file skill)');

    SKIP: {
        skip 'SKILL.md does not exist yet (implementation absent)', 60 unless -f $SKILL;

        my $text = _slurp_text($SKILL);
        my @lines = split /\n/, $text;
        # Range widened from the original 150-180 when the skill absorbed the
        # invariants, the two entry paths, and the phase 2.5 question round.
        # The ceiling is the skill-writing guide's 500-line budget with room to
        # spare; the floor still catches a gutting.
        cmp_ok(scalar(@lines), '>=', 200, 'AC-34: SKILL.md is >= 200 lines (house size for a doc-heavy protocol skill)');
        cmp_ok(scalar(@lines), '<=', 400, 'AC-34: SKILL.md is <= 400 lines (guide budget is 500)');

        # Frontmatter: exactly three keys.
        my ($fm) = $text =~ /\A---\n(.*?)\n---\n/s;
        ok(defined $fm, 'AC-35: frontmatter block (--- ... ---) present');
        SKIP: {
            skip 'no frontmatter block to inspect', 7 unless defined $fm;
            like($fm, qr/^name:\s*feedback\s*$/m, 'AC-35: frontmatter name: feedback');
            # The argument-hint carries the operator's own entry contract: the
            # command is prefixed to the feedback itself. Assert the paste
            # affordance is advertised, not a frozen string.
            like($fm, qr/^argument-hint:.*\bfeedback\b/mi,
                 'AC-35: argument-hint advertises pasting the feedback (not just a batch name)');
            like($fm, qr/^argument-hint:.*\bbatch\b/mi,
                 'AC-35: argument-hint still advertises the resume-a-batch form');
            like($fm, qr/^description:/m, 'AC-35: frontmatter has a description key');
            unlike($fm, qr/^allowed-tools:/m, 'AC-35: no allowed-tools key (spec: exactly three keys, nothing else)');
            unlike($fm, qr/^model:/m, 'AC-35: no model key (spec: exactly three keys, nothing else)');
            my @keys = ($fm =~ /^([A-Za-z][A-Za-z-]*):/mg);
            is_deeply([sort @keys], [sort qw(name description argument-hint)],
                      'AC-35: frontmatter has EXACTLY name/description/argument-hint, nothing else');
            my ($desc) = $fm =~ /^description:\s*(.*(?:\n(?!\S[\w-]*:).*)*)/m;
            $desc //= '';
            like($desc, qr/Use whenever/i, 'AC-35: description carries a "Use whenever..." trigger clause');
            like($desc, qr/short, direct feedback/i, 'AC-41: frontmatter description also carries the exclusion clause (short, direct feedback...)');
            like($desc, qr/handled immediately/i, 'AC-41: frontmatter description exclusion clause completes ...handled immediately');
        }

        # Required literals -- exact substrings, presence only, "somewhere in SKILL.md".
        my @literals = (
            ['L1',  '## Phase 1 — Batch'],
            ['L2',  '## Phase 2 — Decompose'],
            ['L3',  '## Phase 3 — Verify'],
            ['L4',  '## Phase 4 — Author'],
            ['L5',  'Raw files are never edited'],
            ['L6',  'The decomposition is a single file'],
            ['L7',  'basis marker'],
            ['L8',  'VERIFIED'],
            ['L9',  'REPORTED'],
            ['L10', 'REPORTED (self-caveated)'],
            ['L11', 'context-less and read-only'],
            ['L12', 'authored from the decomposition, never from the raw files'],
            ['L13', '## Overlap with in-flight packages'],
            ['L14', 'note the overlap and propose a follow-on'],
            ['L15', "never edit a running package's criteria"],
            ['L16a', 'covers'],
            ['L16b', 'gap for a follow-on'],
            ['L17', '## Deduplication discipline'],
            ['L18', 'the divergence is recorded rather than silently resolved'],
            ['L19', 'uniques are named explicitly'],
            ['L20', '### Verifier brief'],   # moved under Phase 3, where it is used
            ['L21-1', 'Verdict'],
            ['L21-2', 'Omissions'],
            ['L21-3', 'Distortions'],
            ['L21-4', 'Fabrications'],
            ['L21-5', 'Deduplication errors'],
            ['L21-6', 'Traceability gaps'],
            ['L21-7', 'Coverage'],
            ['L22', 'CHANGES REQUIRED'],
            ['L23', '12 omissions and 5 distortions'],
            ['L24', '## When NOT to use this skill'],
            ['L25a', 'short, direct feedback'],
            ['L25b', 'handled immediately'],
            ['L26', 'bp-feedback.pl'],
            ['L27', 'applied to two findings'],
            ['L28', 'DECOMPOSED.md:16'],
            ['L29', 'does not contain that statement'],
            ['L30', 'never renumbered'],
            ['L31-1', '## How to read this'],
            ['L31-2', '## Operator rulings collected while decomposing'],
            ['L31-3', '## Overlap map'],
            ['L31-4', '## Proposed package grouping'],
            ['L31-5', '## Open items'],
            ['L31-6', '## Audit trail'],
            ['L32a', 'a decomposed batch is closed'],
            ['L32b', 'opens the next batch'],
            ['L33a', 'operator instruction'],
            ['L33b', 'operator testimony'],
            ['L33c', 'not a closed list'],

            # --- Added when the skill absorbed the practice learned on DAME. ---
            # Each of these encodes a loss that actually happened; a literal
            # check is the cheapest thing that fails if one is edited away.

            # Cross-cutting invariants (stated once, near the top).
            ['L34',  '## Invariants'],
            ['L35',  'Modality is preserved in both directions'],
            ['L36',  'is sufficient basis to schedule the work'],
            ['L37',  'Authorship is tracked separately from evidence'],
            ['L38',  'Prefer a check that can fail'],

            # The batched question round -- its own phase, because mid-flight
            # questions are a defect against the operator's working model.
            ['L39',  '## Phase 2.5 — Question'],
            ['L40',  'ONE batched round'],
            # Name the mechanism, not just the discipline: "ask in one round"
            # without naming AskUserQuestion left the agent free to ask in
            # prose, which is neither batched nor answerable in seconds.
            ['L40b', 'AskUserQuestion'],
            ['L40c', 'at most four questions per call'],
            ['L41',  '[Q→resolved]'],
            ['L42',  'provenance table'],
            ['L43',  'A second round is a process failure'],

            # Per-finding requirements beyond the basis marker.
            ['L44',  '**Verbatim:**'],
            ['L45',  'An interrogative is a finding'],
            ['L46',  'agent-originated flag'],
            ['L47',  'Three dispositions, not two'],
            ['L48',  'tracked, out of scope, with the'],
            ['L49',  'Measured evidence, not recollection'],
            ['L50',  'inference'],
            ['L51',  q{grep -c '^### '}],

            # Modality drift: the eighth verifier bucket. Neither an omission
            # nor a distortion of any single claim -- it inverts the BATCH's
            # modality while every finding still reads correctly, so without
            # its own bucket it has nowhere to be reported.
            ['L52',  'Modality drift'],
            ['L53',  'refinement, not rejection'],
            ['L54',  'eight parts'],

            # Verbatim capture route + the two gates after authoring.
            ['L55',  '--from-session'],
            ['L56',  'butler:bp-feedback-verifier'],
            ['L57',  'blueprint:bp-auditor'],
            ['L58',  'Dispatch only when the operator says so'],

            # The backup gap: gitignored AND only vault-backed. Stated so
            # nobody reads a clean `git status` as "the evidence is safe".
            ['L59',  'gitignored'],
            ['L60',  '/steward:backup'],
        );
        for my $l (@literals) {
            my ($id, $lit) = @$l;
            ok(index($text, $lit) >= 0, "SKILL.md literal $id present: \"$lit\"");
        }
        like($text, qr/what I did NOT check/i, 'L21-7: the "what I did NOT check" coverage label is present (full form beyond the word "Coverage")');

        # Prohibited strings -- corrected-wrong figures this package's own
        # ledger caught; reproducing one would be self-refuting.
        for my $bad ('applied to three', '3×', '57 findings') {
            is(index($text, $bad), -1, "SKILL.md never reproduces the corrected-wrong figure: \"$bad\"");
        }

        # No argument-placeholder token. Claude Code substitutes one IN PLACE,
        # so a placeholder anywhere in this body would splice the operator's
        # entire pasted batch into the middle of the instructions -- and this
        # skill's whole entry contract is "the argument IS a long message".
        # With no placeholder the arguments are appended once at the end,
        # which is also where the argv fallback wants them.
        unlike($text, qr/\$ARGUMENTS|\$\{ARGUMENTS|\$\d\b/,
               'AC-34: SKILL.md carries no argument-placeholder token (it would be substituted in place, '
             . 'splicing a whole pasted feedback batch into the middle of the instructions)');
    }
};

# ===========================================================================
# T-K -- drift: artifact-side structural properties (criterion 13; AC-47..51)
# SKIP-guarded throughout: corrections/ is gitignored+untracked and absent
# on a fresh clone or the Windows host.
# ===========================================================================

subtest 'T-K drift (criterion 13; AC-47..51)' => sub {
    SKIP: {
        skip 'real corrections/batch-1/DECOMPOSED.md absent on this machine (gitignored, fresh clone / Windows host)', 1
            unless -f $REAL_DECOMPOSED;

        my $doc = _slurp_text($REAL_DECOMPOSED);
        my @doclines = split /\n/, $doc;

        # D-a: required section-name prefixes, matched at LINE START, order not
        # asserted, no line numbers pinned (the real file moved by hundreds of
        # lines during this very package's run).
        for my $prefix (
            '## How to read this',
            '## Operator rulings collected while decomposing',
            '## Overlap map',
            '## Proposed package grouping',
            '## Open items',
            '## Audit trail',
        ) {
            my $found = grep { index($_, $prefix) == 0 } @doclines;
            ok($found, "AC-47/D-a: real DECOMPOSED.md has a line-start prefix \"$prefix\" (no line number asserted)");
        }

        # D-b: the Audit trail records a verdict and a fix count (literals only).
        like($doc, qr/CHANGES REQUIRED/, 'AC-48/D-b: Audit trail records the verdict CHANGES REQUIRED');
        like($doc, qr/12\s+omissions/,   'AC-48/D-b: Audit trail records 12 omissions');
        # NB: "5 distortions" wraps across a markdown line break in the real
        # file ("...and 5\ndistortions."); \s+ tolerates the wrap without
        # pinning to any particular line number.
        like($doc, qr/5\s+distortions/,  'AC-48/D-b: Audit trail records 5 distortions (tolerant of the real file\'s line wrap)');

        # D-c: every finding (### heading) carries a basis marker, matched
        # UNANCHORED (never ^\*\*Basis -- TUI-01/TUI-02 carry it mid-line,
        # after **Source:** on the same line). No finding TOTAL is asserted;
        # only that the violation count is zero.
        my @blocks = split /^### /m, $doc;
        shift @blocks; # discard preamble before the first finding heading
        my $violations = 0;
        for my $block (@blocks) {
            my $has_basis    = $block =~ /\*\*\s*Basis\s*[: ]/i;
            my $has_evidence = $block =~ /\*\*\s*Evidence\s*\([^)]*\)\s*:?\s*\*\*/i;
            $violations++ unless $has_basis || $has_evidence;
        }
        is($violations, 0, 'AC-49/D-c: every finding carries a basis marker under the tolerant unanchored matcher (0 violations; finding COUNT itself is not asserted)');

        # D-d: the three documented classes are present; vocabulary is
        # explicitly open (operator instruction / operator testimony also
        # occur) -- never asserted as a closed set.
        ok(index($doc, 'VERIFIED') >= 0, 'AC-50/D-d: basis class literal "VERIFIED" present');
        ok(index($doc, 'REPORTED') >= 0, 'AC-50/D-d: basis class literal "REPORTED" present');
        ok(index($doc, 'REPORTED (self-caveated)') >= 0, 'AC-50/D-d: basis class literal "REPORTED (self-caveated)" present');
        ok(index($doc, 'operator instruction') >= 0, 'AC-50/D-d: open-vocabulary class "operator instruction" present (vocabulary is open, not closed)');
        ok(index($doc, 'operator testimony') >= 0,   'AC-50/D-d: open-vocabulary class "operator testimony" present (vocabulary is open, not closed)');

        # D-e: REPORTED (self-caveated) applied at >= 2 sites beyond its
        # definition line -- tolerant of both renderings (period-inside-bold
        # at one site, colon-bold/plain-class at the other). Asserted as
        # ">= 2", NEVER "== 2" and NEVER "== 3": the artifact drifts.
        my @sites = ($doc =~ /\*\*\s*Basis\s*:?\s*\*{0,2}\s*REPORTED \(self-caveated\)/g);
        cmp_ok(scalar(@sites), '>=', 2, 'AC-50/D-e: REPORTED (self-caveated) applied at >= 2 sites (never == 2, never == 3)');

        # AC-CIT-1 -- G3 citation integrity (coordinator fix, post-gate):
        # SKILL.md's L28 literal ("DECOMPOSED.md:16" today) is a citation to a
        # SPECIFIC LINE. A test that only checks the literal string is present
        # cannot tell if that line has drifted to mean something else --
        # exactly LIVE-07's own point ("Line-number citations go stale within
        # hours in a concurrently-edited tree"). So: parse the cited line
        # number OUT OF SKILL.md itself (never hardcode 16 here), then verify
        # THAT line, in the real DECOMPOSED.md, is actually the class
        # DEFINITION -- structurally distinguished from an application by its
        # leading "- **Basis: ...**" list-bullet form (the two application
        # sites read inline, with no leading "- "). This check follows the
        # citation rather than a fixed number, so it stays meaningful even
        # after the artifact moves again.
        SKIP: {
            skip 'SKILL.md does not exist yet (implementation absent) -- nothing to parse a citation out of', 1
                unless -f $SKILL;
            my $skill_text = _slurp_text($SKILL);
            my ($cited_line) = $skill_text =~ /DECOMPOSED\.md:(\d+)/;
            SKIP: {
                skip 'SKILL.md does not cite a DECOMPOSED.md:<N> line number', 1 unless defined $cited_line;
                my $cited_text = $doclines[$cited_line - 1];
                my $is_definition = defined($cited_text)
                    && $cited_text =~ /^\s*-\s*\*\*\s*Basis\s*:\s*REPORTED \(self-caveated\)\s*\*\*/;
                ok($is_definition,
                    "AC-CIT-1/G3: SKILL.md cites DECOMPOSED.md:$cited_line for the REPORTED (self-caveated) "
                  . "class definition, and that line IS the definition today")
                    or diag("DECOMPOSED.md:$cited_line reads: " . (defined $cited_text ? $cited_text : '<line does not exist>')
                          . "\nThe artifact drifted: SKILL.md's citation no longer points at the class definition "
                          . "and needs updating (this is not a test bug -- update the citation, not this check).");
            }
        }

        # Negative assertions (AC-51): what this test group must NOT find, per
        # G4's "MUST NOT assert" list -- the skill's superset (traceability,
        # explicit not-checked coverage) is absent from THIS artifact today.
        unlike($doc, qr/Traceability gaps/, 'AC-51: real Audit trail has no "Traceability gaps" section (skill-side requirement only, per G4)');
        unlike($doc, qr/what I did NOT check/i, 'AC-51: real Audit trail has no explicit not-checked coverage statement (skill-side requirement only, per G4)');
        # (No finding total, no line number, no Source universality, no
        # per-finding Disposition, and no monotonic-ID assertion appear
        # ANYWHERE in this test file -- verified by inspection, not asserted
        # here, since asserting their absence in the artifact would itself
        # be a fragile, spec-violating total/line-number-shaped check.)
    }
};

# ===========================================================================
# T-L -- the verifier agent. Phase 3's whole claim is "read-only": the value
# of the pass comes from the verifier being unable to quietly fix what it
# should be reporting. An instruction saying so is not that guarantee -- the
# TOOL LIST is. These assertions exist so a well-meaning future edit that adds
# Write "so it can save its report" fails loudly instead of silently converting
# the gate into another editor.
# ===========================================================================

subtest 'T-L verifier agent contract (read-only enforced by tools, not by prose)' => sub {
    ok(-f $VERIFIER, "bp-feedback-verifier.md exists ($VERIFIER)");
    SKIP: {
        skip 'verifier agent file absent', 9 unless -f $VERIFIER;
        my $text = _slurp_text($VERIFIER);
        my ($fm) = $text =~ /\A---\n(.*?)\n---\n/s;
        ok(defined $fm, 'verifier has a frontmatter block');
        SKIP: {
            skip 'no frontmatter to inspect', 8 unless defined $fm;
            like($fm, qr/^name:\s*bp-feedback-verifier\s*$/m, 'frontmatter name: bp-feedback-verifier');
            like($fm, qr/^description:/m, 'frontmatter has a description');

            my ($tools) = $fm =~ /^tools:\s*(.+)$/m;
            ok(defined $tools, 'frontmatter declares a tools list');
            SKIP: {
                skip 'no tools list to inspect', 5 unless defined $tools;
                my %granted = map { $_ => 1 } grep { length } split /[,\s]+/, $tools;
                # Read/Grep/Glob are what "read the raw files, re-verify the
                # cited code" actually needs.
                ok($granted{Read}, 'verifier is granted Read');
                ok($granted{Grep}, 'verifier is granted Grep');
                # The three that would let it mutate anything, including the
                # decomposition it is judging.
                for my $forbidden (qw(Write Edit Bash)) {
                    ok(!$granted{$forbidden},
                       "verifier is NOT granted $forbidden -- read-only is structural, not requested");
                }
            }
        }

        # The eighth bucket has to be in the agent's own contract, not only in
        # the skill that dispatches it: a caller who trims the brief must not
        # be able to silently drop it.
        ok(index($text, 'Modality drift') >= 0, 'verifier contract names the Modality drift bucket');
        ok(index($text, 'what I did NOT check') >= 0, 'verifier contract requires an explicit not-checked statement');
    }
};

# ===========================================================================
# T-M -- --from-session: the verbatim-capture route. The point of this route
# is that the operator's bytes never pass through an agent, so these tests are
# byte-equality tests, deliberately using bodies that break the obvious
# shortcuts (a leading POSIX path would be eaten by "strip a leading /token";
# an embedded closing tag would truncate a non-greedy match).
# ===========================================================================

subtest 'T-M --from-session verbatim transcript capture' => sub {
    my $SID = '11111111-2222-3333-4444-555555555555';

    # Build a transcript under <data>/claude-home/projects/<proj>/<sid>.jsonl,
    # the sandbox-side layout the CLI searches.
    my $mk = sub {
        my (@entries) = @_;
        my $tmp  = tempdir(CLEANUP => 1);
        my $data = File::Spec->catdir($tmp, '.ccpraxis-local-data');
        my $proj = File::Spec->catdir($data, 'claude-home', 'projects', 'p');
        make_path($proj);
        make_path(File::Spec->catdir($data, 'corrections'));
        my $json = JSON::PP->new->utf8->canonical;
        my $body = join '', map { $json->encode($_) . "\n" } @entries;
        _write_bytes(File::Spec->catfile($proj, "$SID.jsonl"), $body);
        return $data;
    };
    my $cmd_entry = sub {
        my ($args) = @_;
        my $c = "<command-message>butler:feedback</command-message>\n"
              . "<command-name>/butler:feedback</command-name>";
        $c .= "\n<command-args>$args</command-args>" if defined $args;
        return { type => 'user', message => { role => 'user', content => $c } };
    };
    my $typed_entry = sub {
        my ($t) = @_;
        return { type => 'user', promptSource => 'typed',
                 message => { role => 'user', content => $t } };
    };

    # A body that defeats both naive shortcuts at once, plus non-ASCII so the
    # character/byte boundary is exercised rather than assumed.
    my $tricky = "/c/Users/André/notes.md is wrong.\n"
               . "1. The header says </command-args> — literally.\n"
               . "2. At least 5 variants.\nRegressions?";
    my $tricky_bytes = encode('UTF-8', $tricky);

    {
        my $data = $mk->($typed_entry->('an OLDER message that must not win'),
                         { type => 'user', message => { role => 'user',
                             content => '<local-command-stdout>noise</local-command-stdout>' } },
                         $cmd_entry->($tricky));
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $data,
            '--from-session', $SID, '--command', 'butler:feedback']);
        is($rc, 0, 'command-args route -> exit 0');
        my $path = $out; chomp $path;
        my $got = _slurp_bytes($path);
        ok(defined $got, 'capture file written');
        my ($hdr, $body) = defined $got ? split(/\n\n/, $got, 2) : ('', '');
        is($body, $tricky_bytes,
           'body is byte-identical to the operator\'s <command-args> payload '
         . '(leading POSIX path intact, embedded </command-args> intact, UTF-8 intact)');
        like($hdr, qr/^\*\*Source:\*\* transcript$/m,
             'provenance records the transcript route without being told to');
        like($err, qr/verbatim/, 'STDERR reports the verbatim capture and its byte count');
    }

    # A bare invocation must NOT silently reach back and capture an older
    # message: capturing the wrong turn is worse than capturing nothing,
    # because nothing is visible and wrong is not.
    {
        my $data = $mk->($typed_entry->('an older message that must NOT be captured'),
                         $cmd_entry->(undef));
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $data,
            '--from-session', $SID, '--command', 'butler:feedback']);
        is($rc, 2, 'bare /butler:feedback (no args) -> exit 2, not a stale capture');
        ok(!-d File::Spec->catdir($data, 'corrections', 'batch-1'),
           'bare invocation writes nothing at all');
    }

    # No --command: fall back to the last plainly-typed message, skipping the
    # injected local-command bookkeeping entries.
    {
        my $data = $mk->($typed_entry->('first'),
                         { type => 'user', message => { role => 'user',
                             content => '<command-name>/model</command-name>' } },
                         $typed_entry->('the last typed message'));
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $data, '--from-session', $SID]);
        is($rc, 0, 'no --command -> typed-message route, exit 0');
        my $path = $out; chomp $path;
        my $got = _slurp_bytes($path) // '';
        my (undef, $body) = split(/\n\n/, $got, 2);
        is($body, 'the last typed message', 'takes the LAST typed message, ignoring injected command entries');
    }

    # Unfindable transcript: warn, fall back to argv, and downgrade the
    # recorded provenance -- a fallback capture must not claim to be verbatim.
    {
        my $data = $mk->($cmd_entry->('unused'));
        my ($rc, $out, $err) = run_cli(args => ['--data-dir', $data,
            '--from-session', 'no-such-session', 'body from argv']);
        is($rc, 0, 'unfindable transcript -> falls back to argv, exit 0');
        like($err, qr/\[transcript\]/, 'STDERR carries a [transcript] diagnostic');
        my $path = $out; chomp $path;
        my $got = _slurp_bytes($path) // '';
        my ($hdr, $body) = split(/\n\n/, $got, 2);
        is($body, 'body from argv', 'argv body captured');
        like($hdr, qr/^\*\*Source:\*\* chat$/m,
             'provenance downgraded to chat -- a fallback never claims Source: transcript');
    }

    # Shape gates.
    {
        my ($rc, $out, $err) = run_cli(args => ['--command', 'butler:feedback', 'x']);
        is($rc, 1, '--command without --from-session -> usage error');
        like($err, qr/\[--command requires --from-session\]/, 'message names the missing dependency');
    }
    {
        my ($rc, $out, $err) = run_cli(args => ['--from-session', "bad/../id", 'x']);
        is($rc, 1, 'path-shaped session id rejected');
        like($err, qr/\[invalid session id\]/, 'message names the invalid session id');
    }
};

# ===========================================================================
# Hermeticity guard: the real corrections/ tree must be byte-identical
# before and after this entire run (AC-53). SKIP-guarded on its presence.
# ===========================================================================

SKIP: {
    skip 'real corrections/ absent on this machine (gitignored, fresh clone / Windows host)', 1
        unless $HAVE_REAL_CORRECTIONS;
    is_deeply(_dir_manifest($REAL_CORRECTIONS), $real_snapshot_before,
        'AC-53: real corrections/ tree (recursive entry set + every file\'s bytes) is unchanged after the full run -- proves no test in this file wrote a real batch-N');
}

done_testing();

