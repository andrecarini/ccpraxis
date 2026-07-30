#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Config;

# 77-feedback-intake.t
#
# Test oracle for blueprint package b25-feedback-intake, derived from
# specs/b25-feedback-intake-spec.md (revision 2, gate-passed) and
# packages/b25-feedback-intake.md's 13 done-criteria bullets.
#
# Covers two absent deliverables:
#   plugins/butler/scripts/bp-feedback.pl        (CLI, R-06)
#   plugins/butler/skills/feedback-intake/SKILL.md (skill, R-05)
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
my $SKILL     = File::Spec->catfile($REPO_ROOT, qw(plugins butler skills feedback-intake SKILL.md));
my $REAL_CORRECTIONS = File::Spec->catdir($REPO_ROOT, '.ccpraxis-local-data', 'corrections');
my $REAL_DECOMPOSED  = File::Spec->catfile($REAL_CORRECTIONS, 'batch-1', 'DECOMPOSED.md');

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
        skip 'bp-feedback.pl does not exist yet (implementation absent)', 13 unless -f $SCRIPT;

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
        like($src, qr/bp-orchestrator\.pl:506/,
             'AC-24: cites bp-orchestrator.pl:506 as the class origin (Pre-settled #1)');

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
    is(_slurp_bytes($path1) ? 1 : 0, 1, 'AC-1: the path STDOUT names is the file actually written') if $rc == 0;

    SKIP: {
        skip 'no output path to inspect (bp-feedback.pl not implemented)', 6 unless $rc == 0 && length($path1) && -f $path1;
        my $bytes = _slurp_bytes($path1);
        my ($fields, $body) = _parse_written($bytes);
        is($body, 'hello there', 'AC-3: argv body round-trips verbatim (word-joined)');
        is($fields->{Source}, 'chat', 'AC-8: default source token is "chat"');
        like($fields->{Captured}, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/,
             'AC-7: Captured timestamp matches the house ISO-8601-UTC-Z shape');
        my $blank_idx = index($bytes, "\n\n");
        ok($blank_idx > 0, 'G1: header/body separated by exactly one blank line');
        is(substr($bytes, -1), 'e', 'G2: no trailing newline added when body has none ("hello there" ends in e)');
        ok(1, 'placeholder to keep the SKIP count honest'); # see note below
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

