#!/usr/bin/env perl
# platform: host
# Oracle for blueprint package 02-backfill-scan (blueprint test-platform-split).
# Derived ONLY from
# .ccpraxis-local-data/blueprints/test-platform-split/specs/02-backfill-scan-spec.md
# (section 4's AC-1..AC-12, section 5's 19-row worked oracle table, section 6's
# edge cases). NOT derived from any implementation: scripts/backfill-test-
# platform.pl does not exist on disk at the time this file is written, and this
# file must never create it -- that is the implementer's job, under a review
# the driver performs separately. This file also never touches any real
# plugins/*/tests/t/*.t file: every scan/classify/apply exercised below runs
# against disposable File::Temp fixtures, except the two places the spec itself
# demands a real-tree read (AC-3's default-glob count, and the standing
# durability assertion for done-criterion 4) -- both of those are --dry-run
# reads only, or (for the standing assertion) a pure TestPlatform::parse_marker
# sweep with no subprocess and no write at all.
#
# WRITTEN BLIND, AND DELIBERATELY WITHOUT A BAIL_OUT ON THE MISSING SCRIPT.
# Every tool invocation below goes through run_tool(), a plain subprocess
# spawn (perl "$IMPL" @args, output captured via redirected temp files, never
# by reopening this process's own STDOUT/STDERR onto an in-memory scalar).
# A missing scripts/backfill-test-platform.pl therefore fails the SPAWN, not
# this test file: perl itself prints "Can't open perl script ..." to STDERR
# and exits 2, and every assertion below simply compares its own expectation
# against that (wrong) observed behaviour and fails normally, with the rest of
# the file continuing to run and report its own count. One coincidence is
# worth flagging up front rather than let it look like a false pass: perl's
# OWN "script not found" exit code (2) happens to equal this tool's PINNED
# usage-error exit code, so the two usage-error checks below (neither flag /
# both flags given) pass on their exit-code assertion alone even before the
# tool exists. Each of those blocks carries a second assertion (STDOUT stays
# empty) that is not subject to the same coincidence, but neither the
# exit-code check nor the STDOUT check would, by itself, prove the tool is
# actually implemented -- see the report for how this was verified instead
# (every other assertion in this file, all mutation/classification/idempotence
# checks, unambiguously traces to the missing script or the not-yet-applied
# backfill).
#
# AC -> block mapping (spec section 4):
#   AC-1  -> PART 5's SIGNAL FIXTURES sub-block (9 signals x positive fixture,
#            each asserted for host classification + exact signal name)
#   AC-2  -> PART 1 (source-level single-table check + its own counter-fixture)
#   AC-3  -> PART 3 (default GLOB against the real repo tree)
#   AC-4  -> PART 5's "footer sums" assertions, on both the 29-fixture dir and
#            (via PART 3) the real tree
#   AC-5  -> PART 5's dry-run zero-byte-write hash comparison
#   AC-6  -> PART 6 (four headers always printed, pinned line shapes, sort
#            order) plus PART 5's per-file/per-signal line-shape checks
#   AC-7  -> PART 5's post-apply-#1 TestPlatform sweep (every originally-absent
#            fixture now parses legal)
#   AC-8  -> PART 5's apply-#2 block (idempotence: hash-unchanged, zero
#            second-round host/any, and TestPlatform's own `raw` array
#            length used to rule out a stacked duplicate marker)
#   AC-9  -> PART 5 (row18, the needs-review fixture, checked untouched after
#            both applies)
#   AC-10 -> PART 5's INSERTION-MECHANICS rows (shebang / no-shebang / CRLF /
#            non-ASCII / empty), each verified by exact expected-byte equality
#   AC-11 -> PART 8 (perl -c) -- the second half ("this file itself exits 0
#            with zero not-ok") is validated by re-running this file after
#            implementation, not asserted here (it cannot assert its own
#            future exit code)
#   AC-12 -> PART 4, the standing tree assertion -- MUST fail today (zero
#            files carry a marker yet) and is expected to go green only after
#            the real one-time --apply lands on the live tree
#
# MANDATORY VACUITY GATE (this blueprint's own standing rule):
#   - Every one of the nine @SIGNALS entries gets BOTH a positive fixture
#     (PART 5, SIGNAL FIXTURES) and a negative counter-fixture (immediately
#     alongside it) proving the detector does not fire on prose that merely
#     resembles the trigger text.
#   - AC-2's "no literal leaks outside the table" detector is proven non-
#     vacuous against a fabricated source string engineered to leak, entirely
#     independent of whether the real (currently absent) implementation exists.
#   - Every sweep over a collection (the 29-fixture dir, the real tree) also
#     asserts the collection is non-empty, with a floor well below every
#     historically measured real-tree count so it cannot be satisfied by an
#     accidentally-empty glob.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Basename qw(basename);
use Cwd qw(abs_path);

use lib "$Bin/../lib";
my $MODULE_PM = "$Bin/../lib/TestPlatform.pm";
ok(-f $MODULE_PM, 'TestPlatform.pm exists at plugins/butler/tests/lib/TestPlatform.pm (package 01, already shipped)');
my $TP_LOAD_ERR;
eval { require TestPlatform; 1 } or do { $TP_LOAD_ERR = $@ };
ok(!defined $TP_LOAD_ERR, 'TestPlatform.pm loads with no compile/runtime error')
    or diag("load error: $TP_LOAD_ERR");

my $REPO_ROOT = abs_path("$Bin/../../../..");
my $IMPL      = "$REPO_ROOT/scripts/backfill-test-platform.pl";

# =============================================================================
# PART 0 -- helpers
# =============================================================================

# quote_arg($s) -- wraps $s for a Windows cmd.exe command line (doubling any
# embedded double quote). None of this file's fixture paths are expected to
# contain a literal '"', but every argument is quoted unconditionally anyway.
sub quote_arg {
    my ($s) = @_;
    $s =~ s/"/""/g;
    return qq{"$s"};
}

sub slurp_text {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $t = <$fh>;
    close $fh;
    return defined($t) ? $t : '';
}

# run_tool(@args) -> ($rc, $stdout, $stderr)
# Spawns "$^X $IMPL @args" via cmd.exe redirection into two throwaway temp
# files (never by reopening this process's own STDOUT/STDERR -- that fails
# with "Bad file descriptor" on this host's Git-for-Windows perl). $rc is the
# child's real exit code (system()'s $? >> 8), or -1 if the spawn itself could
# not even start (vanishingly unlikely for cmd.exe + perl, both always present
# on this host).
sub run_tool {
    my (@args) = @_;
    my ($ofh, $opath) = tempfile(UNLINK => 1);
    close $ofh;
    my ($efh, $epath) = tempfile(UNLINK => 1);
    close $efh;
    my $cmdline = join(' ', map { quote_arg($_) } ($^X, $IMPL, @args))
                . ' > ' . quote_arg($opath) . ' 2> ' . quote_arg($epath);
    system($cmdline);
    my $raw = $?;
    my $rc  = ($raw == -1) ? -1 : ($raw >> 8);
    my $out = slurp_text($opath);
    my $err = slurp_text($epath);
    unlink $opath, $epath;
    return ($rc, $out, $err);
}

sub write_file {
    my ($path, $bytes) = @_;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print {$fh} $bytes;
    close $fh;
}

sub read_file_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $t = <$fh>;
    close $fh;
    return defined($t) ? $t : '';
}

# marker_line($value, $eol) -- builds "# platform: $value" + $eol. Written as
# a single physical source line (the '#' is never the first non-whitespace
# character of ANY line in THIS file) specifically so this oracle's own
# source text never accidentally satisfies TestPlatform's marker regex when
# the standing-tree assertion (PART 4) freshly globs and scans
# plugins/*/tests/t/*.t -- which includes this very file.
sub marker_line {
    my ($value, $eol) = @_;
    $eol //= "\n";
    return "# platform: $value$eol";
}

# miscased_marker_line($value) -- the row-18 fixture: wrong-case keyword,
# which TestPlatform's LOOSE (case-insensitive) pattern recognises as
# marker-shaped-but-invalid ('malformed-marker-line'), never as 'absent'.
sub miscased_marker_line {
    my ($value) = @_;
    return "# Platform: $value\n";
}

sub marker_result {
    my ($path) = @_;
    return TestPlatform::parse_marker(TestPlatform::read_prefix($path));
}

# nth_line_trimmed($content, $n) -- the exact text the report is pinned to
# print for a signal match on line $n of $content: the whole line, trimmed of
# leading/trailing space/tab, truncated to 80 chars (spec's truncate80/trim).
sub nth_line_trimmed {
    my ($content, $n) = @_;
    my @lines = split /\r?\n/, $content, -1;
    my $line = $lines[$n - 1];
    return undef unless defined $line;
    $line =~ s/^[ \t]+//;
    $line =~ s/[ \t]+$//;
    if (length($line) > 80) { $line = substr($line, 0, 77) . '...' }
    return $line;
}

sub count_substr {
    my ($haystack, $needle) = @_;
    return 0 unless length $needle;
    my $n = 0;
    my $pos = 0;
    while ((my $i = index($haystack, $needle, $pos)) >= 0) {
        $n++;
        $pos = $i + length($needle);
    }
    return $n;
}

# parse_report($text) -- pinned line-shape regexes straight from spec section
# 2's "Report format" block. Returns a hashref: header_order (arrayref, in
# the order headers appeared), counts (bucket name -> the header's own <n>),
# footer (undef or {scanned,host,any,already_marked,needs_review,errors}),
# files (bucket name -> arrayref of {relpath, existing|reason (if
# applicable), signals (arrayref of {name,text,line}, host only)}).
sub parse_report {
    my ($text) = @_;
    my %result = (
        header_order => [],
        counts       => {},
        footer       => undef,
        files        => { host => [], any => [], 'already-marked' => [], 'needs-review' => [] },
    );
    my @lines = split /\n/, $text;
    my $cur_bucket;
    my $cur_file;
    for my $line (@lines) {
        if ($line =~ /^===\s+(\S+)\s+\((\d+)\s+files\)\s+===\s*$/) {
            $cur_bucket = $1;
            push @{ $result{header_order} }, $cur_bucket;
            $result{counts}{$cur_bucket} = $2 + 0;
            $cur_file = undef;
            next;
        }
        if ($line =~ /^TOTAL:\s*(\d+)\s+scanned,\s*(\d+)\s+host,\s*(\d+)\s+any,\s*(\d+)\s+already-marked,\s*(\d+)\s+needs-review(?:,\s*errors:\s*(\d+))?\s*$/) {
            $result{footer} = {
                scanned        => $1 + 0,
                host           => $2 + 0,
                any            => $3 + 0,
                already_marked => $4 + 0,
                needs_review   => $5 + 0,
                errors         => defined($6) ? $6 + 0 : 0,
            };
            next;
        }
        next unless defined $cur_bucket;
        if ($line =~ /^\s{3,}(\S[\w-]*):\s(.*)\s\(line\s(\d+)\)\s*$/) {
            push @{ $cur_file->{signals} }, { name => $1, text => $2, line => $3 + 0 } if $cur_file;
            next;
        }
        if ($line =~ /^  (\S.*)$/) {
            my $rest = $1;
            my $entry = { signals => [] };
            if ($cur_bucket eq 'already-marked' && $rest =~ /^(.*)\s\(existing:\s*(\S+)\)$/) {
                $entry->{relpath} = $1; $entry->{existing} = $2;
            } elsif ($cur_bucket eq 'needs-review' && $rest =~ /^(.*)\s\(reason:\s*(\S+)\)$/) {
                $entry->{relpath} = $1; $entry->{reason} = $2;
            } else {
                $entry->{relpath} = $rest;
            }
            push @{ $result{files}{$cur_bucket} }, $entry;
            $cur_file = $entry;
            next;
        }
    }
    return \%result;
}

sub find_entry_by_basename {
    my ($list, $base) = @_;
    for my $e (@$list) {
        return $e if $e->{relpath} =~ m{(?:^|/)\Q$base\E$};
    }
    return undef;
}

# =============================================================================
# PART 1 (AC-2) -- the signal table is one data structure; no signal literal
# duplicated elsewhere in the file.
# =============================================================================
{
    my $src = '';
    if (open my $fh, '<:raw', $IMPL) {
        local $/;
        $src = <$fh>;
        close $fh;
    }
    ok(length($src) > 0, 'AC-2 precondition: scripts/backfill-test-platform.pl has readable source '
                        . '(expected to fail today -- the file does not exist yet)');

    my ($table) = ($src =~ /\@SIGNALS\s*=\s*\((.*?)\n\);/s);
    ok(defined $table, 'AC-2: a single "my @SIGNALS = ( ... );" table block is located in the source');
    $table //= '';

    my $outside = $src;
    if (length($table) && (my $idx = index($src, $table)) >= 0) {
        $outside = substr($src, 0, $idx) . substr($src, $idx + length($table));
    }

    # The nine literals pinned EXACTLY as spec section 2's own code block
    # writes them (regex source text, not just the bare keyword) -- this is
    # what "no signal literal appears a second time anywhere else" means.
    my @LITERALS = (
        'MSYS2_ARG_CONV_EXCL',
        '\bCP1252\b|\bBOM\b',
        '\bMSWin32\b|\bcygwin\b',
        '\bcygpath\b',
        'podman\s+machine',
        '\bNUL\b',
        'drive[- ]?root',
        'powershell|\.ps1|ES_DISPLAY_REQUIRED|keep-?awake',
        '\bWin32::',
    );
    for my $lit (@LITERALS) {
        is(count_substr($table, $lit), 1,
            "AC-2: literal '$lit' appears exactly once inside the \@SIGNALS table");
        is(count_substr($outside, $lit), 0,
            "AC-2: literal '$lit' does not appear anywhere outside the \@SIGNALS table");
    }

    # AC-2 counter-fixture -- proves the "leaks outside the table" detector
    # itself actually fires, entirely independent of whether the real
    # (currently absent) implementation exists.
    {
        my $fake_src = "my \@SIGNALS = (\n"
                     . "    { name => 'msys2-arg-conv-excl', pattern => qr/MSYS2_ARG_CONV_EXCL/ },\n"
                     . ");\n"
                     . "# oops, mentions MSYS2_ARG_CONV_EXCL again down here, outside the table\n";
        my ($fake_table) = ($fake_src =~ /\@SIGNALS\s*=\s*\((.*?)\n\);/s);
        ok(defined $fake_table, 'AC-2 counter-fixture setup: fake table block located');
        my $fake_outside = $fake_src;
        if (defined $fake_table) {
            my $idx = index($fake_src, $fake_table);
            $fake_outside = substr($fake_src, 0, $idx) . substr($fake_src, $idx + length($fake_table));
        }
        is(count_substr($fake_table, 'MSYS2_ARG_CONV_EXCL'), 1,
            'AC-2 counter-fixture: the literal is correctly counted once INSIDE the fake table');
        is(count_substr($fake_outside, 'MSYS2_ARG_CONV_EXCL'), 1,
            'AC-2 counter-fixture: the "leaks outside the table" detector DOES fire (count 1, not 0) '
          . 'on data engineered to leak -- proving the detector above is not a tautology');
    }
}

# =============================================================================
# PART 2 -- CLI usage contract: exactly one of --dry-run/--apply required.
# =============================================================================
{
    my ($rc, $out, $err) = run_tool();
    is($rc, 2, 'usage: neither --dry-run nor --apply given -> exit 2');
    is($out, '', 'usage: neither flag given -> nothing printed to STDOUT (fails before any scanning)');

    ($rc, $out, $err) = run_tool('--dry-run', '--apply');
    is($rc, 2, 'usage: both --dry-run and --apply given -> exit 2');
    is($out, '', 'usage: both flags given -> nothing printed to STDOUT (fails before any scanning)');

    ($rc, $out, $err) = run_tool('--help');
    is($rc, 0, 'usage: --help exits 0');
    ok(length($out) > 0, 'usage: --help prints its message to STDOUT');
    is($err, '', 'usage: --help prints nothing to STDERR');

    ($rc, $out, $err) = run_tool('-h');
    is($rc, 0, 'usage: -h exits 0 (same as --help)');
    ok(length($out) > 0, 'usage: -h prints its message to STDOUT');
}

# =============================================================================
# PART 3 (AC-3) -- no positional GLOB defaults to plugins/*/tests/t/*.t under
# the repo root, resolved via the SCRIPT's own location, independent of the
# caller's cwd. --dry-run only: this reads the real tree but writes nothing.
# =============================================================================
{
    my @expected = sort glob("$REPO_ROOT/plugins/*/tests/t/*.t");
    ok(scalar(@expected) >= 200,
        'AC-3 non-vacuity: at least 200 real .t files were found by a fresh glob() at assertion time '
      . '(got ' . scalar(@expected) . ') -- a floor far below every historically measured count '
      . '(322-348), guarding only against a broken glob path, never pinning the drifting true count');

    my ($rc, $out, $err) = run_tool('--dry-run');
    is($rc, 0, 'AC-3: --dry-run with no positional GLOB exits 0 against the real tree');
    if ($out =~ /^TOTAL:\s*(\d+)\s+scanned/m) {
        is($1 + 0, scalar(@expected),
            'AC-3: the default-glob scanned count matches a fresh, independently-computed glob() '
          . 'at assertion time -- never a hardcoded literal');
    } else {
        fail('AC-3: no "TOTAL: N scanned" line found in the default-glob --dry-run report');
    }
    my $r = parse_report($out);
    if ($r->{footer}) {
        my $sum = $r->{footer}{host} + $r->{footer}{any}
                + $r->{footer}{already_marked} + $r->{footer}{needs_review};
        is($sum, $r->{footer}{scanned},
            'AC-4 (real tree): the footer\'s four bucket counts sum to <scanned>');
    } else {
        fail('AC-4 (real tree): could not parse a TOTAL footer line from the default-glob report');
    }
}

# =============================================================================
# PART 4 (AC-12 / done-criterion 4, the durable/standing form) -- every .t
# under a FRESH glob("plugins/*/tests/t/*.t") parses TestPlatform's own
# parse_marker() as outcome 'legal'. MUST fail today: zero files carry a
# marker yet. Goes green only after the real, one-time --apply lands on the
# live tree. No subprocess, no write -- a pure TestPlatform read.
# =============================================================================
{
    my @real_files = sort glob("$REPO_ROOT/plugins/*/tests/t/*.t");
    ok(scalar(@real_files) >= 200,
        'standing sweep non-vacuity: at least 200 real .t files found (got ' . scalar(@real_files) . ') '
      . '-- same floor as AC-3, guarding the glob path rather than pinning the drifting count');

    my @offenders;
    for my $f (@real_files) {
        my $outcome = marker_result($f)->{outcome};
        push @offenders, "$f ($outcome)" if $outcome ne 'legal';
    }
    is(scalar(@offenders), 0,
        'done-criterion 4 (standing, durable): every .t under a freshly-globbed '
      . 'plugins/*/tests/t/*.t parses TestPlatform::parse_marker outcome legal -- expected to fail '
      . 'today (zero files carry a marker yet) and to pass only after the real --apply has run')
        or diag('offenders (' . scalar(@offenders) . ' of ' . scalar(@real_files) . "):\n  "
              . join("\n  ", @offenders));
}

# =============================================================================
# PART 5 -- the 29-fixture dir: classification (AC-1/4/6), zero-write dry-run
# (AC-5), insertion mechanics (AC-10), post-apply legality (AC-7), idempotence
# (AC-8), and the needs-review/already-marked non-rewrite guarantees (AC-9).
# =============================================================================

my $FIXDIR = tempdir(CLEANUP => 1);
my $TDIR   = "$FIXDIR/tests/t";
make_path($TDIR);

# --- fixture table -----------------------------------------------------------
# Every row is spec section 5's worked oracle table (rows 1-19, using this
# file's own row numbers as a stem) plus: one shebang-free minimal one-liner
# per signal for AC-1's "minimal fixture" wording, one negative counter-
# fixture per signal (so a detector cannot pass by matching everything), one
# table-order-vs-match-order disambiguator, one first-match-only-and-once-
# per-signal-name disambiguator, and one truncate80 exerciser.
my @FIXTURES;

push @FIXTURES, {
    file => 'row01-msys2-shebang.t',
    content => "#!/usr/bin/env perl\n# uses MSYS2_ARG_CONV_EXCL\n",
    bucket => 'host', signals => [['msys2-arg-conv-excl', 2]],
    after => "#!/usr/bin/env perl\n" . marker_line('host') . "# uses MSYS2_ARG_CONV_EXCL\n",
};
push @FIXTURES, {
    file => 'row01b-msys2-oneline.t',
    content => "# uses MSYS2_ARG_CONV_EXCL\n",
    bucket => 'host', signals => [['msys2-arg-conv-excl', 1]],
    after => marker_line('host') . "# uses MSYS2_ARG_CONV_EXCL\n",
};
push @FIXTURES, {
    file => 'row02-cp1252.t',
    content => "# talks about CP1252 decoding\n",
    bucket => 'host', signals => [['cp1252-or-bom', 1]],
    after => marker_line('host') . "# talks about CP1252 decoding\n",
};
push @FIXTURES, {
    file => 'row03-bom.t',
    content => "# mentions a BOM\n",
    bucket => 'host', signals => [['cp1252-or-bom', 1]],
    after => marker_line('host') . "# mentions a BOM\n",
};
push @FIXTURES, {
    file => 'row04-mswin32.t',
    content => q{# checks the special var eq 'MSWin32'} . "\n",
    bucket => 'host', signals => [['mswin32-or-cygwin', 1]],
    after => marker_line('host') . q{# checks the special var eq 'MSWin32'} . "\n",
};
push @FIXTURES, {
    file => 'row05-cygwin.t',
    content => "# runs under cygwin\n",
    bucket => 'host', signals => [['mswin32-or-cygwin', 1]],
    after => marker_line('host') . "# runs under cygwin\n",
};
push @FIXTURES, {
    file => 'row06-cygpath.t',
    content => "# shells out to cygpath -w\n",
    bucket => 'host', signals => [['cygpath', 1]],
    after => marker_line('host') . "# shells out to cygpath -w\n",
};
push @FIXTURES, {
    file => 'row07-podman-machine.t',
    content => "# starts a podman machine\n",
    bucket => 'host', signals => [['podman-machine', 1]],
    after => marker_line('host') . "# starts a podman machine\n",
};
push @FIXTURES, {
    file => 'row08-nul.t',
    content => "# writes to NUL\n",
    bucket => 'host', signals => [['nul-device', 1]],
    after => marker_line('host') . "# writes to NUL\n",
};
push @FIXTURES, {
    file => 'row09-drive-root.t',
    content => "# guards against a drive-root stray\n",
    bucket => 'host', signals => [['drive-root', 1]],
    after => marker_line('host') . "# guards against a drive-root stray\n",
};
push @FIXTURES, {
    file => 'row10-any-top.t',
    content => "use strict;\nuse warnings;\n",
    bucket => 'any', signals => [],
    after => marker_line('any') . "use strict;\nuse warnings;\n",
};
push @FIXTURES, {
    file => 'row11-any-shebang.t',
    content => "#!/usr/bin/env perl\nuse strict;\n",
    bucket => 'any', signals => [],
    after => "#!/usr/bin/env perl\n" . marker_line('any') . "use strict;\n",
};
push @FIXTURES, {
    file => 'row12-any-noshebang.t',
    content => "use strict;\n",
    bucket => 'any', signals => [],
    after => marker_line('any') . "use strict;\n",
};
push @FIXTURES, {
    file => 'row13-any-crlf.t',
    content => "#!/usr/bin/env perl\r\nuse strict;\r\n",
    bucket => 'any', signals => [],
    after => "#!/usr/bin/env perl\r\n" . marker_line('any', "\r\n") . "use strict;\r\n",
};
{
    my $nonascii = "# caf" . "\xC3\xA9" . " " . "\xE2\x80\x94" . " non-ascii comment\n";
    push @FIXTURES, {
        file => 'row14-any-nonascii.t',
        content => $nonascii,
        bucket => 'any', signals => [],
        after => marker_line('any') . $nonascii,
    };
}
push @FIXTURES, {
    file => 'row15-already-marked.t',
    content => marker_line('any'),
    bucket => 'already-marked', existing => 'any',
    after => marker_line('any'),
};
push @FIXTURES, {
    file => 'row16-empty.t',
    content => '',
    bucket => 'any', signals => [],
    after => marker_line('any'),
};
push @FIXTURES, {
    file => 'row17-null-word.t',
    content => "# NULL, not the device\n",
    bucket => 'any', signals => [],
    after => marker_line('any') . "# NULL, not the device\n",
};
push @FIXTURES, {
    file => 'row18-needs-review.t',
    content => miscased_marker_line('host'),
    bucket => 'needs-review', reason => 'malformed-marker-line',
    after => miscased_marker_line('host'),
};
push @FIXTURES, {
    file => 'row19-multi-signal.t',
    content => "# uses cygpath and starts a podman machine\n",
    bucket => 'host', signals => [['cygpath', 1], ['podman-machine', 1]],
    after => marker_line('host') . "# uses cygpath and starts a podman machine\n",
};
push @FIXTURES, {
    file => 'row20-powershell.t',
    content => "# invokes powershell.exe to check status\n",
    bucket => 'host', signals => [['powershell-or-ps1', 1]],
    after => marker_line('host') . "# invokes powershell.exe to check status\n",
};
push @FIXTURES, {
    file => 'row21-ps1-ext.t',
    content => "# runs helper.ps1 on a schedule\n",
    bucket => 'host', signals => [['powershell-or-ps1', 1]],
    after => marker_line('host') . "# runs helper.ps1 on a schedule\n",
};
push @FIXTURES, {
    file => 'row22-es-display-required.t',
    content => "# sets ES_DISPLAY_REQUIRED during the session\n",
    bucket => 'host', signals => [['powershell-or-ps1', 1]],
    after => marker_line('host') . "# sets ES_DISPLAY_REQUIRED during the session\n",
};
push @FIXTURES, {
    file => 'row23-keepawake-noHyphen.t',
    content => "# calls the keepawake helper script directly\n",
    bucket => 'host', signals => [['powershell-or-ps1', 1]],
    after => marker_line('host') . "# calls the keepawake helper script directly\n",
};
push @FIXTURES, {
    file => 'row24-keep-awake-hyphen.t',
    content => "# keep-awake.ps1 exits on that alone\n",
    bucket => 'host', signals => [['powershell-or-ps1', 1]],
    after => marker_line('host') . "# keep-awake.ps1 exits on that alone\n",
};
push @FIXTURES, {
    file => 'row25-win32-namespace.t',
    content => "# uses Win32::Process to spawn a native command\n",
    bucket => 'host', signals => [['win32-namespace', 1]],
    after => marker_line('host') . "# uses Win32::Process to spawn a native command\n",
};
# fix-batch A2 -- a shebang line with NO trailing newline anywhere in the
# file. Before the fix, compute_insertion() glued the marker directly onto
# the shebang bytes with no separator, corrupting the shebang and producing
# a line TestPlatform's marker regex could never recognise (breaking both
# AC-10 and idempotence). The correct output starts a clean second line: the
# fixture's own trailing newline is SYNTHESISED by the insertion, not present
# in "content" -- this file genuinely has zero bytes after "perl".
push @FIXTURES, {
    file => 'row26-shebang-no-newline.t',
    content => '#!/usr/bin/env perl',
    bucket => 'any', signals => [],
    after => "#!/usr/bin/env perl\n" . marker_line('any'),
};

# --- negative counter-fixtures: one per signal, proving the detector does
# not fire on merely-similar prose (nul-device's negative is row17 above).
push @FIXTURES, {
    file => 'neg01-msys2.t',
    content => "# mentions msys2_arg_conv_excl in lowercase prose, not the real thing\n",
    bucket => 'any', signals => [],
    after => marker_line('any') . "# mentions msys2_arg_conv_excl in lowercase prose, not the real thing\n",
};
push @FIXTURES, {
    file => 'neg02-cp1252-bom.t',
    content => "# something about cp1252 and a bom here, both lowercase\n",
    bucket => 'any', signals => [],
    after => marker_line('any') . "# something about cp1252 and a bom here, both lowercase\n",
};
push @FIXTURES, {
    file => 'neg03-mswin-cygwin.t',
    content => "# just mentions windows generally, nothing more specific\n",
    bucket => 'any', signals => [],
    after => marker_line('any') . "# just mentions windows generally, nothing more specific\n",
};
push @FIXTURES, {
    file => 'neg04-cygpath.t',
    content => "# uses cygdrive style path handling, not the other tool\n",
    bucket => 'any', signals => [],
    after => marker_line('any') . "# uses cygdrive style path handling, not the other tool\n",
};
push @FIXTURES, {
    file => 'neg05-podman-machine.t',
    content => "# starts a podman container here, not a machine of any kind\n",
    bucket => 'any', signals => [],
    after => marker_line('any') . "# starts a podman container here, not a machine of any kind\n",
};
push @FIXTURES, {
    file => 'neg06-drive-root.t',
    content => "# the c drive holds many files somewhere near the root of the tree\n",
    bucket => 'any', signals => [],
    after => marker_line('any') . "# the c drive holds many files somewhere near the root of the tree\n",
};
push @FIXTURES, {
    file => 'neg07-powershell.t',
    content => "# a note about power settings and keeping the machine busy, nothing platform specific\n",
    bucket => 'any', signals => [],
    after => marker_line('any') . "# a note about power settings and keeping the machine busy, nothing platform specific\n",
};
push @FIXTURES, {
    file => 'neg08-win32.t',
    content => "# mentions win32 generally and Win32 without the namespace colon\n",
    bucket => 'any', signals => [],
    after => marker_line('any') . "# mentions win32 generally and Win32 without the namespace colon\n",
};

# --- nuance fixtures: table-order vs match-order, first-match-only ----------
push @FIXTURES, {
    file => 'nuance01-order-reversed.t',
    content => "# starts a podman machine, and also shells out to cygpath -w\n",
    bucket => 'host', signals => [['cygpath', 1], ['podman-machine', 1]],
    after => marker_line('host') . "# starts a podman machine, and also shells out to cygpath -w\n",
};
{
    my $c = "# line one, nothing special here yet\n"
          . "MSYS2_ARG_CONV_EXCL first appears on this very line\n"
          . "MSYS2_ARG_CONV_EXCL appears again down here too\n";
    push @FIXTURES, {
        file => 'nuance02-first-line-only.t',
        content => $c,
        bucket => 'host', signals => [['msys2-arg-conv-excl', 2]],
        after => marker_line('host') . $c,
    };
}
{
    my $pad = 'x' x 90;
    my $line = "$pad NUL trailer text that pushes this line well past eighty characters total";
    my $c = "$line\n";
    push @FIXTURES, {
        file => 'nuance03-truncation.t',
        content => $c,
        bucket => 'host', signals => [['nul-device', 1]],
        after => marker_line('host') . $c,
        expect_text => { 1 => substr($line, 0, 77) . '...' },
    };
}

for my $fx (@FIXTURES) {
    write_file("$TDIR/$fx->{file}", $fx->{content});
}

my $n_fixtures = scalar @FIXTURES;
ok($n_fixtures > 20, "PART 5 non-vacuity: built more than 20 fixtures (got $n_fixtures)");

my %before_dry = map { $_->{file} => read_file_raw("$TDIR/$_->{file}") } @FIXTURES;

# --- dry-run: classification, report shape, zero writes ---------------------
{
    my ($rc, $out, $err) = run_tool('--dry-run', "$TDIR/*.t");
    is($rc, 0, 'PART 5 dry-run: exits 0 (no per-file errors in this fixture set)');

    my %after_dry = map { $_->{file} => read_file_raw("$TDIR/$_->{file}") } @FIXTURES;
    my @mutated = grep { $before_dry{$_} ne $after_dry{$_} } map { $_->{file} } @FIXTURES;
    is(scalar(@mutated), 0,
        'AC-5: --dry-run wrote zero bytes to any fixture file (content-hash-equivalent comparison)')
        or diag('mutated under --dry-run: ' . join(', ', @mutated));

    my $r = parse_report($out);
    ok(defined $r->{footer}, 'PART 5 dry-run: a TOTAL footer line was found and parsed');

    is_deeply([sort @{ $r->{header_order} }], [sort qw(host any already-marked needs-review)],
        'AC-6: all four pinned bucket headers are present');
    is(scalar(@{ $r->{header_order} }), 4, 'AC-6: exactly four bucket headers printed, no duplicates');

    if ($r->{footer}) {
        is($r->{footer}{scanned}, $n_fixtures, 'AC-3/AC-4: scanned count equals the fixture count');
        my $sum = $r->{footer}{host} + $r->{footer}{any}
                + $r->{footer}{already_marked} + $r->{footer}{needs_review};
        is($sum, $r->{footer}{scanned}, 'AC-4: the four bucket counts sum to <scanned>');
    }

    for my $fx (@FIXTURES) {
        my $entry = find_entry_by_basename($r->{files}{ $fx->{bucket} }, $fx->{file});
        ok(defined $entry, "AC-1/AC-6: $fx->{file} is listed under bucket '$fx->{bucket}'")
            or next;
        ok($entry->{relpath} !~ /\\/, "AC-6: $fx->{file}'s reported relpath uses forward slashes only");

        if ($fx->{bucket} eq 'host') {
            my @got_names = map { $_->{name} } @{ $entry->{signals} };
            my @want_names = map { $_->[0] } @{ $fx->{signals} };
            is_deeply(\@got_names, \@want_names,
                "AC-1/AC-6: $fx->{file} reports exactly the expected signal name(s), in table order");
            my @got_lines = map { $_->{line} } @{ $entry->{signals} };
            my @want_lines = map { $_->[1] } @{ $fx->{signals} };
            is_deeply(\@got_lines, \@want_lines,
                "$fx->{file}: reported line number(s) match the expected first-occurrence line(s)");
            if ($fx->{expect_text}) {
                for my $sig (@{ $entry->{signals} }) {
                    my $want = $fx->{expect_text}{ $sig->{line} };
                    next unless defined $want;
                    is($sig->{text}, $want,
                        "$fx->{file}: reported signal text is truncated/trimmed exactly per spec's truncate80/trim");
                }
            }
        } elsif ($fx->{bucket} eq 'already-marked') {
            is($entry->{existing}, $fx->{existing}, "$fx->{file}: reported existing value matches");
        } elsif ($fx->{bucket} eq 'needs-review') {
            is($entry->{reason}, $fx->{reason}, "$fx->{file}: reported reason matches TestPlatform's own reason");
        } else {
            is(scalar(@{ $entry->{signals} }), 0, "$fx->{file} (any): no signal detail lines reported");
        }
    }
}

# --- apply #1: insertion mechanics (AC-10), post-apply legality (AC-7),
# needs-review/already-marked non-rewrite (AC-9) ------------------------------
{
    my ($rc, $out, $err) = run_tool('--apply', "$TDIR/*.t");
    is($rc, 0, 'PART 5 apply#1: exits 0');

    for my $fx (@FIXTURES) {
        my $got = read_file_raw("$TDIR/$fx->{file}");
        is($got, $fx->{after}, "AC-10/AC-9: $fx->{file} content after --apply matches the pinned expectation exactly");
    }

    # AC-7: every originally-absent fixture (host/any) now parses legal,
    # through TestPlatform -- never a second regex -- with the correct value.
    for my $fx (grep { $_->{bucket} eq 'host' || $_->{bucket} eq 'any' } @FIXTURES) {
        my $r = marker_result("$TDIR/$fx->{file}");
        is($r->{outcome}, 'legal', "AC-7: $fx->{file} parses TestPlatform outcome legal after apply#1");
        is($r->{value}, $fx->{bucket}, "AC-7: $fx->{file}'s legal value equals its classified bucket");
        is(scalar(@{ $r->{raw} }), 1, "AC-7: $fx->{file} carries exactly one marker line (no duplicate)");
    }

    # AC-9: the needs-review fixture is never touched, and remains classified
    # invalid/malformed-marker-line -- never silently folded into
    # already-marked or re-marked.
    {
        my ($fx) = grep { $_->{bucket} eq 'needs-review' } @FIXTURES;
        my $r = marker_result("$TDIR/$fx->{file}");
        is($r->{outcome}, 'invalid', 'AC-9: the needs-review fixture is still outcome invalid after apply#1');
        is($r->{reason}, 'malformed-marker-line', 'AC-9: ... with the same reason as before');
    }

    # already-marked fixture: byte-identical, never opened for writing.
    {
        my ($fx) = grep { $_->{bucket} eq 'already-marked' } @FIXTURES;
        is(read_file_raw("$TDIR/$fx->{file}"), $fx->{content},
            'AC-3 (observable behavior 3): the already-marked fixture is byte-for-byte unchanged after apply#1');
    }
}

my %after_apply1 = map { $_->{file} => read_file_raw("$TDIR/$_->{file}") } @FIXTURES;

# --- apply #2: idempotence (AC-8) -------------------------------------------
{
    my ($rc, $out, $err) = run_tool('--apply', "$TDIR/*.t");
    is($rc, 0, 'PART 5 apply#2: exits 0');

    my $r = parse_report($out);
    if ($r->{footer}) {
        is($r->{footer}{host}, 0, 'AC-8: second apply run classifies zero files as host');
        is($r->{footer}{any}, 0, 'AC-8: second apply run classifies zero files as any');
        my $expect_already = scalar(grep { $_->{bucket} eq 'host' || $_->{bucket} eq 'any' } @FIXTURES) + 1;
        is($r->{footer}{already_marked}, $expect_already,
            'AC-8: second run\'s already-marked count covers every previously host/any file plus the original one');
        is($r->{footer}{needs_review}, 1, 'AC-8: the needs-review fixture is still needs-review, not already-marked');
    } else {
        fail('AC-8: could not parse a TOTAL footer from the second apply run');
    }

    my @mutated;
    for my $fx (@FIXTURES) {
        my $now = read_file_raw("$TDIR/$fx->{file}");
        push @mutated, $fx->{file} if $now ne $after_apply1{ $fx->{file} };
    }
    is(scalar(@mutated), 0,
        'AC-8: applying twice is a no-op -- every file\'s content after run 2 equals its content after run 1')
        or diag('mutated on second apply: ' . join(', ', @mutated));

    for my $fx (grep { $_->{bucket} eq 'host' || $_->{bucket} eq 'any' } @FIXTURES) {
        my $r2 = marker_result("$TDIR/$fx->{file}");
        is($r2->{outcome}, 'legal', "AC-8: $fx->{file} still parses legal after the second apply");
        is(scalar(@{ $r2->{raw} }), 1,
            "AC-8: $fx->{file} still carries exactly one marker line -- no second marker was stacked on top "
          . "(checked via TestPlatform's own raw-match count, not a second regex)");
    }
}

# =============================================================================
# PART 6 (AC-6) -- headers always printed even when a bucket is empty; files
# within a bucket sorted lexicographically; overlapping GLOBs dedupe.
# =============================================================================
{
    my $D = tempdir(CLEANUP => 1);
    make_path("$D/tests/t");
    my $TD2 = "$D/tests/t";
    write_file("$TD2/aaa-first-any.t", "use strict;\n");
    write_file("$TD2/zzz-second-any.t", "use warnings;\n");
    write_file("$TD2/mmm-windows.t", "# talks about CP1252 decoding\n");

    my ($rc, $out, $err) = run_tool('--dry-run', "$TD2/*.t");
    is($rc, 0, 'PART 6: dry-run over a 3-file, two-empty-bucket set exits 0');
    my $r = parse_report($out);

    is_deeply([sort @{ $r->{header_order} }], [sort qw(host any already-marked needs-review)],
        'AC-6: all four headers print even when two of the four buckets are empty');
    if ($r->{footer}) {
        is($r->{footer}{already_marked}, 0, 'AC-6: already-marked header shows 0 (still printed, per PART 6 header-order check above)');
        is($r->{footer}{needs_review}, 0, 'AC-6: needs-review header shows 0 (still printed, per PART 6 header-order check above)');
        is($r->{footer}{host}, 1, 'AC-6: host bucket has exactly 1 (non-vacuous -- proves it is not always 0)');
        is($r->{footer}{any}, 2, 'AC-6: any bucket has exactly 2 (non-vacuous -- proves it is not always 0)');
    }

    my @any_basenames = map { (split m{/}, $_->{relpath})[-1] } @{ $r->{files}{any} };
    is_deeply(\@any_basenames, ['aaa-first-any.t', 'zzz-second-any.t'],
        'AC-6: files within the "any" bucket are sorted lexicographically by relpath, '
      . 'independent of the order fixtures were created on disk');

    # dedupe by absolute path: two overlapping GLOBs over the same 3 files
    # must not double-count.
    my ($rc2, $out2, $err2) = run_tool('--dry-run', "$TD2/*.t", "$TD2/a*.t");
    is($rc2, 0, 'PART 6 (dedupe): dry-run with two overlapping GLOBs exits 0');
    if ($out2 =~ /^TOTAL:\s*(\d+)\s+scanned/m) {
        is($1 + 0, 3, 'PART 6 (dedupe): overlapping GLOBs collapse to 3 unique files, not 4');
    } else {
        fail('PART 6 (dedupe): no TOTAL line found');
    }
}

# =============================================================================
# PART 7 -- per-file read error: recorded, run continues, exit 1; a
# genuinely-nonexistent explicit path (never touched by glob-existence
# checks, per Perl's own glob() semantics on a literal non-wildcard pattern)
# is the reliable way to force an open() failure on this host, unlike a
# directory-shaped ".t" entry (verified: open() on a directory SUCCEEDS on
# this host's perl, and only read() fails -- an unreliable trigger for an
# implementation that checks only open()'s return value).
# =============================================================================
{
    my $D = tempdir(CLEANUP => 1);
    make_path("$D/tests/t");
    my $TD3 = "$D/tests/t";
    write_file("$TD3/ok-file.t", "use strict;\n");
    my $ghost = "$TD3/does-not-exist-nowhere.t";
    ok(!-e $ghost, 'PART 7 setup: the explicit ghost path genuinely does not exist on disk');

    my ($rc, $out, $err) = run_tool('--dry-run', "$TD3/*.t", $ghost);
    is($rc, 1, 'PART 7: a per-file read error yields exit 1');

    my $r = parse_report($out);
    if ($r->{footer}) {
        is($r->{footer}{scanned}, 1,
            'PART 7 (judgment call -- see report): <scanned> counts only the successfully-classified file, '
          . 'excluding the one that errored, so the four-bucket-sum invariant (AC-4) holds unconditionally');
        my $sum = $r->{footer}{host} + $r->{footer}{any}
                + $r->{footer}{already_marked} + $r->{footer}{needs_review};
        is($sum, $r->{footer}{scanned}, 'AC-4 holds even on a run with a per-file error');
        is($r->{footer}{errors}, 1, 'PART 7: the footer carries an "errors: 1" suffix');
    } else {
        fail('PART 7: could not parse a TOTAL footer from the error-run report');
    }
    ok((find_entry_by_basename($r->{files}{any}, 'ok-file.t')
        || find_entry_by_basename($r->{files}{host}, 'ok-file.t')),
        'PART 7: the run continues past the errored file -- the other real file is still classified');

    # fix-batch A4 -- a bare "errors: N" on the footer is unactionable across
    # 349 files; the report must NAME which file failed and why, under its
    # own heading (deliberately not one of the four "(<n> files)" bucket
    # headers, so it does not perturb AC-6's header-count/order checks).
    ok((grep { /does-not-exist-nowhere\.t \(read failed\)/ } split /\n/, $out),
        'AC A4: the report names the specific failing file and its reason (not just a bare count)');
}

# =============================================================================
# PART 9 (fix-batch C, "the --apply write-failure path is untested") --
# forces write_atomic()'s tempfile()/rename() to fail for real, via a genuine
# Windows ACL deny (icacls) on the fixture directory's write/append-data
# rights for the current user. The DOS read-only attribute (chmod 444) does
# NOT force this path -- verified empirically: rename() silently succeeds
# over a read-only destination file on this host (that gap is fix-batch A3,
# covered separately below) -- an ACL deny on the DIRECTORY is what actually
# blocks tempfile() creation, which is the real failure this exercises.
# Windows-only (icacls does not exist elsewhere); skipped on any other $^O.
# =============================================================================
# No fixed plan is declared in this file (done_testing() at EOF), so a
# not-applicable environment is handled with a plain conditional rather than
# Test::More's SKIP: idiom (which exists to preserve a pre-declared count) --
# either branch below still contributes real, counted assertions.
{
    my $is_windows = ($^O =~ /^(MSWin32|cygwin|msys)$/);
    my $denied = 0;
    my $D; my $TD9; my $win_td9; my $user = '';

    if ($is_windows) {
        $D = tempdir(CLEANUP => 1);
        make_path("$D/tests/t");
        $TD9 = "$D/tests/t";
        write_file("$TD9/wf.t", "use strict;\n");
        $user = $ENV{USERNAME} // $ENV{USER} // '';

        # icacls is a NATIVE binary and needs a native Windows path -- $TD9
        # is this host's own POSIX-mount form (e.g. "/tmp/xxxxx/tests/t"),
        # which MSYS2's own argv translation silently fixes up for a BARE
        # path argument, but NOT once MSYS2_ARG_CONV_EXCL is set below to
        # protect the "/deny" flag from that same translation mangling it
        # into a bogus path. Hand-translating here (project CLAUDE.md's
        # documented technique) is correct under either conversion state;
        # relying on the implicit translation is what created the "/deny"
        # bug in the first place.
        chomp(my $cygpath_out = `cygpath -m "$TD9" 2>/dev/null`);
        $win_td9 = (length $cygpath_out) ? $cygpath_out : $TD9;

        # MSYS2_ARG_CONV_EXCL scoped to this one native-binary call -- icacls
        # is native, and its "/deny" argument must reach it byte-for-byte,
        # not word-split into a bogus path of its own.
        local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
        system('icacls', $win_td9, '/deny', "$user:(WD,AD)");
        $denied = ($? == 0);
    }

    if ($is_windows && $denied) {
        my ($rc, $out, $err) = run_tool('--apply', "$TD9/*.t");

        {
            local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
            system('icacls', $win_td9, '/remove:d', $user);
        }

        is($rc, 1, 'PART 9: a forced write failure (ACL-denied target directory) yields exit 1');
        my $r = parse_report($out);
        if ($r->{footer}) {
            is($r->{footer}{errors}, 1, 'PART 9: the footer carries an "errors: 1" suffix for the write failure');
        } else {
            fail('PART 9: could not parse a TOTAL footer from the write-failure run');
        }
        ok((grep { /wf\.t \(write failed\)/ } split /\n/, $out),
            'PART 9 (A4): the named-errors section identifies wf.t as (write failed)');
        is(read_file_raw("$TD9/wf.t"), "use strict;\n",
            'PART 9: the original file is byte-identical after a failed write -- temp-file-then-rename never touched it');
    } else {
        ok(1, 'PART 9: not applicable on this platform, or icacls /deny did not report success -- '
             . 'the write-failure path could not be reliably forced here (recorded, not faked)')
            for 1 .. 4;
        diag('PART 9 skipped: is_windows=' . ($is_windows ? 1 : 0) . ' denied=' . $denied)
            unless $is_windows && $denied;
    }
}

# =============================================================================
# PART 10 (fix-batch A1) -- a GLOB pattern naming a directory whose path
# contains a space is scanned correctly, not silently word-split. The bare
# builtin glob() treats its PATTERN STRING as csh-style words, so a space in
# the path splits it into two bogus fragments and the real file is never
# globbed at all -- the only symptom is an unrelated, unlocatable "read
# failed" bump. bsd_glob() does not split its argument.
# =============================================================================
{
    my $D = tempdir(CLEANUP => 1);
    my $SPACEDIR = "$D/space dir/tests/t";
    make_path($SPACEDIR);
    write_file("$SPACEDIR/spaced-file.t", "use strict;\n");

    my ($rc, $out, $err) = run_tool('--dry-run', "$SPACEDIR/*.t");
    is($rc, 0, 'AC A1: --dry-run over a space-containing directory exits 0 (not the bare-glob word-split failure)');
    my $r = parse_report($out);
    ok(defined(find_entry_by_basename($r->{files}{any}, 'spaced-file.t')),
        'AC A1: the file under the space-containing path is actually classified, not silently dropped');
    if ($r->{footer}) {
        is($r->{footer}{scanned}, 1,
            'AC A1: scanned count is 1, not 0 (the bare-glob bug reports 0 scanned plus a spurious error)');
        is($r->{footer}{errors}, 0, 'AC A1: no spurious "read failed" error from a mis-split GLOB pattern');
    } else {
        fail('AC A1: could not parse a TOTAL footer from the space-path run');
    }
}

# =============================================================================
# PART 11 (fix-batch A3) -- a pre-existing read-only file's attribute survives
# --apply. Reproduced and confirmed reliable on this host via chmod(0444, ...)
# (unlike PART 9's write-failure fixture, the DOS read-only bit IS how Windows
# actually represents chmod's effect here, and it round-trips through
# write_atomic()'s restore-mode-after-rename step deterministically).
# =============================================================================
{
    my $D = tempdir(CLEANUP => 1);
    make_path("$D/tests/t");
    my $TD11 = "$D/tests/t";
    my $ro_path = "$TD11/ro-file.t";
    write_file($ro_path, "use strict;\n");
    my $chmod_ok = chmod(0444, $ro_path);

    SKIP_RO: {
        unless ($chmod_ok) {
            ok(1, 'PART 11: chmod(0444, ...) did not report success on this host -- '
                 . 'read-only-preservation could not be reliably forced here (recorded, not faked)')
                for 1 .. 3;
            last SKIP_RO;
        }

        my @before_stat = stat($ro_path);
        my $before_mode = $before_stat[2] & 07777;

        my ($rc, $out, $err) = run_tool('--apply', "$TD11/*.t");
        is($rc, 0, 'PART 11: --apply on a read-only fixture still exits 0 (attribute preservation is not a failure)');

        my @after_stat = stat($ro_path);
        my $after_mode = @after_stat ? ($after_stat[2] & 07777) : undef;
        is($after_mode, $before_mode,
            'AC A3: the read-only attribute survives --apply -- mode after equals mode before, byte-for-byte')
            or diag(sprintf('before=%04o after=%s', $before_mode, defined($after_mode) ? sprintf('%04o', $after_mode) : 'undef'));

        chmod(0644, $ro_path); # restore write access so File::Temp can clean up $D
        is(read_file_raw($ro_path), "# platform: any\nuse strict;\n",
            'PART 11: the marker was still correctly inserted despite the file having been read-only');
    }
}

# =============================================================================
# PART 8 (AC-11, first half) -- perl -c on the implementation.
# =============================================================================
{
    my ($ofh, $opath) = tempfile(UNLINK => 1);
    close $ofh;
    my ($efh, $epath) = tempfile(UNLINK => 1);
    close $efh;
    my $cmdline = join(' ', map { quote_arg($_) } ($^X, '-c', $IMPL))
                . ' > ' . quote_arg($opath) . ' 2> ' . quote_arg($epath);
    system($cmdline);
    my $rc = ($? == -1) ? -1 : ($? >> 8);
    is($rc, 0, 'AC-11: perl -c scripts/backfill-test-platform.pl exits 0');
    unlink $opath, $epath;
}

done_testing();
