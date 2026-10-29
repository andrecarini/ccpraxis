#!/usr/bin/env perl
# backfill-test-platform.pl -- blueprint test-platform-split, package
# 02-backfill-scan. A ONE-TIME migration aid (Decision 3): it scans .t files
# for nine textual signals of host-specific test behavior, proposes a
# platform marker (`windows` or `any`, never `linux` -- the conservative
# default, spec D3) for every file that does not already carry a legal one,
# and, given --apply, inserts exactly one marker comment line per file.
#
# Nothing in scripts/run-tests.pl or any runtime path ever calls this script
# or re-implements its signal table -- it is invoked by a human/coordinator a
# handful of times total, and the file-content changes it produces (not the
# tool itself) are what later packages consume.
#
# Full contract: .ccpraxis-local-data/blueprints/test-platform-split/specs/
# 02-backfill-scan-spec.md. Existing markers are read ONLY through package
# 01's plugins/butler/tests/lib/TestPlatform.pm -- this script never
# re-implements the marker grammar.
#
# Usage:
#   perl scripts/backfill-test-platform.pl --dry-run [GLOB ...]
#   perl scripts/backfill-test-platform.pl --apply   [GLOB ...]
#
# Exactly one of --dry-run/--apply is required (neither or both -> usage
# error, exit 2). --help/-h prints usage to STDOUT and exits 0. With no
# positional GLOB, the default is plugins/*/tests/t/*.t resolved under the
# repo root via this script's OWN location (FindBin), independent of the
# caller's cwd -- this is what lets the fixture-driven unit test point the
# tool at a disposable directory without a separate "test mode".
#
# The review gate (done-criterion 3's "reviewed before it is applied") is
# procedural, not mechanical: this tool does not require a prior --dry-run to
# have run and keeps no persisted state across invocations (spec D5). The
# coordinator/driver runs --dry-run, reads the report, and only then runs
# --apply -- a deliberate scope boundary, not an oversight.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempfile);
use File::Basename qw(dirname);
use File::Glob qw(bsd_glob);
use Cwd qw(abs_path);

use lib "$Bin/../plugins/butler/tests/lib";
use TestPlatform ();

my $ROOT_ABS = abs_path("$Bin/..");

# =============================================================================
# The signal table -- the ONE place any of these nine literals appears. Every
# other code path in this file reads from this array; no signal literal is
# duplicated anywhere else (enforced by the oracle's AC-2).
# =============================================================================
my @SIGNALS = (
    { name => 'msys2-arg-conv-excl', pattern => qr/MSYS2_ARG_CONV_EXCL/ },
    { name => 'cp1252-or-bom',       pattern => qr/\bCP1252\b|\bBOM\b/ },
    { name => 'mswin32-or-cygwin',   pattern => qr/\bMSWin32\b|\bcygwin\b/i },
    { name => 'cygpath',             pattern => qr/\bcygpath\b/i },
    { name => 'podman-machine',      pattern => qr/podman\s+machine/i },
    { name => 'nul-device',          pattern => qr/\bNUL\b/ },
    { name => 'drive-root',          pattern => qr/drive[- ]?root/i },
    { name => 'powershell-or-ps1',   pattern => qr/powershell|\.ps1|ES_DISPLAY_REQUIRED|keep-?awake/i },
    { name => 'win32-namespace',     pattern => qr/\bWin32::/ },
);

# =============================================================================
# CLI parsing
# =============================================================================
sub usage_text {
    return <<'USAGE';
usage: perl scripts/backfill-test-platform.pl --dry-run|--apply [GLOB ...]

Scans .t files for nine textual signals of host-specific test behavior and proposes a platform marker for every file that does not already carry a legal one (package 01's TestPlatform.pm parser decides "legal").

  --dry-run    scan and print the report; write nothing
  --apply      scan, print the report, and insert exactly one "# platform: windows" or "# platform: any" line into every file classified windows or any. Files already carrying a legal marker, or a marker-shaped-but-invalid line, are left untouched either way.
  --help, -h   print this message and exit 0

Exactly one of --dry-run/--apply is required; giving neither or both is a usage error (exit 2).

With no positional GLOB, the default is plugins/*/tests/t/*.t resolved under the repo root, independent of the caller's current directory.

This is a one-time migration aid (blueprint test-platform-split, Decision 3): nothing in scripts/run-tests.pl or any runtime path ever calls it.
USAGE
}

my ($dry_run, $apply, $help) = (0, 0, 0);
my @glob_args;
for my $a (@ARGV) {
    if    ($a eq '--dry-run')            { $dry_run = 1 }
    elsif ($a eq '--apply')              { $apply   = 1 }
    elsif ($a eq '--help' || $a eq '-h') { $help    = 1 }
    else                                 { push @glob_args, $a }
}

if ($help) {
    print usage_text();
    exit 0;
}

if ($dry_run == $apply) {
    # neither given (0 == 0) or both given (1 == 1) -- either way, a usage
    # error, and nothing may reach STDOUT before scanning has even started.
    print STDERR usage_text();
    exit 2;
}

# =============================================================================
# Helpers
# =============================================================================

# trim($s) -- strip leading/trailing [ \t] only (spec section 2).
sub trim {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/^[ \t]+//;
    $s =~ s/[ \t]+$//;
    return $s;
}

# truncate80($s) -- spec section 2, exactly.
sub truncate80 {
    my ($s) = @_;
    return (length($s) > 80) ? (substr($s, 0, 77) . '...') : $s;
}

# relpath($abs) -- forward-slash path relative to the repo root, matching
# scripts/run-tests.pl's own _relpath convention (plain abs2rel, no
# realpath -- a fixture path outside the repo tree, e.g. under a
# File::Temp dir, legitimately relativizes to something like
# "../../../../tmp/xxx/tests/t/foo.t", which is fine: nothing in the oracle
# pins an exact value, only "no backslashes" and correct basenames).
sub relpath {
    my ($abs) = @_;
    my $rel = File::Spec->abs2rel($abs, $ROOT_ABS);
    $rel =~ s{\\}{/}g;
    return $rel;
}

# dedupe_key($path) -- case-folded, forward-slash form used only to collapse
# duplicates from overlapping GLOBs; Windows filesystems are case-insensitive
# so two globs spelled with different case must still collapse to one file.
sub dedupe_key {
    my ($path) = @_;
    my $abs = File::Spec->rel2abs($path);
    $abs =~ s{\\}{/}g;
    return lc($abs);
}

# read_file_raw($path) -- undef on any open failure; '' for a genuinely
# empty file. Full slurp, ':raw' -- no decoding layer anywhere in this tool.
sub read_file_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return defined($bytes) ? $bytes : '';
}

# compute_insertion($bytes) -> ($offset, $eol, $needs_leading_sep) -- spec
# section 2, "Marker insertion": BOM (if present) is skipped for the shebang
# check but is NOT itself consumed by the insertion point (the marker still
# lands right after it, since the shebang line, if any, begins right where
# the BOM ends and we insert past that whole line). No shebang -> offset 0,
# before everything, BOM or not.
#
# $needs_leading_sep is true only for the degenerate case of a file whose
# first line is a shebang with NO trailing newline anywhere in the file (a
# shebang-only file, or one using bare-\r line endings throughout). Without
# it, the insertion point falls at end-of-bytes with nothing separating the
# shebang text from the marker, gluing them into one corrupted physical line
# (e.g. "#!/usr/bin/env perl# platform: windows") that TestPlatform's
# line-anchored marker regex can never recognise -- breaking both AC-10 (every
# other byte unchanged) and idempotence (a second run never sees it as
# already-marked). The caller prepends $eol before the marker line whenever
# this is true.
sub compute_insertion {
    my ($bytes) = @_;
    my $off = 0;
    $off = 3 if substr($bytes, 0, 3) eq "\xEF\xBB\xBF";
    my $needs_leading_sep = 0;
    if (substr($bytes, $off, 2) eq '#!') {
        my $nl = index($bytes, "\n", $off);
        if ($nl == -1) {
            $needs_leading_sep = 1;
            $off = length($bytes);
        } else {
            $off = $nl + 1;
        }
    }
    my $first_nl = index($bytes, "\n");
    my $eol = "\n";
    $eol = "\r\n" if $first_nl > 0 && substr($bytes, $first_nl - 1, 1) eq "\r";
    return ($off, $eol, $needs_leading_sep);
}

# write_atomic($abs_path, $new_content) -> ($ok, $attr_warning).
# $ok is 1 on success, 0 on any failure (nothing else is meaningful when
# $ok is 0). Temp file in the SAME directory, then rename() over the
# original -- the original is never touched until the rename succeeds (spec
# section 2).
#
# The temp-file-then-rename sequence replaces the original's directory entry
# wholesale, so the new inode carries the TEMP file's own attributes, not the
# original's -- on Windows this silently clears a pre-existing read-only DOS
# attribute with no trace in the report. $attr_warning is undef on a clean
# write, or a short string when the write itself succeeded but the original
# file's mode could not be restored afterward -- a permission change the
# operator did not ask for and was not told about is the problem, not the
# write (fix-batch A3); the caller decides how to surface it.
sub write_atomic {
    my ($abs_path, $new_content) = @_;
    my $dir = dirname($abs_path);
    my @orig_stat = stat($abs_path);
    my $orig_mode = @orig_stat ? ($orig_stat[2] & 07777) : undef;

    my ($fh, $tmp_path) = eval { tempfile('backfillXXXXXX', DIR => $dir, SUFFIX => '.tmp', UNLINK => 0) };
    return (0, undef) unless $fh;
    binmode $fh;
    my $ok = print {$fh} $new_content;
    $ok = 0 unless close $fh;
    unless ($ok) {
        unlink $tmp_path;
        return (0, undef);
    }
    unless (rename($tmp_path, $abs_path)) {
        unlink $tmp_path;
        return (0, undef);
    }

    my $attr_warning;
    if (defined $orig_mode && !chmod($orig_mode, $abs_path)) {
        $attr_warning = 'original file mode/attributes could not be restored after write';
    }
    return (1, $attr_warning);
}

# =============================================================================
# Gather the target file list: positional GLOBs (unioned, deduped by absolute
# path), or the default plugins/*/tests/t/*.t under the repo root.
# =============================================================================
my @patterns = @glob_args ? @glob_args : ("$ROOT_ABS/plugins/*/tests/t/*.t");
my (%seen, @files);
for my $pat (@patterns) {
    # bsd_glob(), NOT the builtin glob() -- the builtin word-splits its
    # PATTERN argument on whitespace (csh-style), so any space-containing
    # path (e.g. a real checkout under "C:\Users\Andre\Personal Files")
    # silently loses every file under it with no diagnosable symptom beyond
    # an unrelated "read failed" error on a bogus half-pattern. bsd_glob()
    # does not split its argument at all.
    for my $m (bsd_glob($pat)) {
        my $key = dedupe_key($m);
        next if $seen{$key}++;
        push @files, File::Spec->rel2abs($m);
    }
}
@files = sort { dedupe_key($a) cmp dedupe_key($b) } @files;

# =============================================================================
# Scan + classify + (if --apply) write.
# =============================================================================
my %buckets = (windows => [], any => [], 'already-marked' => [], 'needs-review' => []);
my (@errors, @attr_warnings);

for my $abs (@files) {
    my $bytes = read_file_raw($abs);
    if (!defined $bytes) {
        push @errors, { relpath => relpath($abs), reason => 'read failed' };
        next;
    }

    my $prefix = TestPlatform::read_prefix($abs);
    my $marker = TestPlatform::parse_marker($prefix);

    if ($marker->{outcome} eq 'legal') {
        push @{ $buckets{'already-marked'} },
            { relpath => relpath($abs), existing => $marker->{value} };
        next;
    }
    if ($marker->{outcome} eq 'invalid') {
        push @{ $buckets{'needs-review'} },
            { relpath => relpath($abs), reason => $marker->{reason} };
        next;
    }

    # outcome eq 'absent' -- only here does the signal table run, over the
    # file's FULL content (a different, unbounded scan from TestPlatform's
    # own 4096-byte marker read -- spec section 2).
    my @hits;
    for my $sig (@SIGNALS) {
        if ($bytes =~ $sig->{pattern}) {
            my $offset = $-[0];
            my $before = substr($bytes, 0, $offset);
            my $line_no = 1 + ($before =~ tr/\n//);
            # The reported text is the WHOLE physical line the match falls
            # on (from its own start, not from the match offset onward) --
            # this is what nth_line_trimmed()'s own contract in the oracle
            # pins, and what the truncate80 exerciser fixture requires: a
            # match deep inside a long line must still report that line's
            # leading characters, truncated from column 0.
            my $line_start = rindex($before, "\n");
            $line_start = ($line_start == -1) ? 0 : $line_start + 1;
            my ($line) = substr($bytes, $line_start) =~ /^([^\n]*)/;
            push @hits, { name => $sig->{name}, line_no => $line_no,
                          text => truncate80(trim($line)) };
        }
    }
    my $value = @hits ? 'windows' : 'any';
    my $entry = { relpath => relpath($abs), signals => \@hits };

    if ($apply) {
        my ($off, $eol, $needs_leading_sep) = compute_insertion($bytes);
        my $marker_line = ($needs_leading_sep ? $eol : '') . "# platform: $value" . $eol;
        my $new_content = substr($bytes, 0, $off) . $marker_line . substr($bytes, $off);
        my ($ok, $attr_warning) = write_atomic($abs, $new_content);
        if ($ok) {
            push @{ $buckets{$value} }, $entry;
            push @attr_warnings, { relpath => relpath($abs), reason => $attr_warning }
                if defined $attr_warning;
        } else {
            push @errors, { relpath => relpath($abs), reason => 'write failed' };
        }
    } else {
        push @{ $buckets{$value} }, $entry;
    }
}

for my $bucket (keys %buckets) {
    @{ $buckets{$bucket} } = sort { $a->{relpath} cmp $b->{relpath} } @{ $buckets{$bucket} };
}

# =============================================================================
# Report -- pinned format, spec section 2. Four headers always printed, in
# this order, even when empty.
# =============================================================================
my $scanned = 0;
$scanned += scalar(@{ $buckets{$_} }) for qw(windows any already-marked needs-review);

my @out;
push @out, sprintf('=== windows (%d files) ===', scalar(@{ $buckets{windows} }));
for my $e (@{ $buckets{windows} }) {
    push @out, "  $e->{relpath}";
    for my $sig (@{ $e->{signals} }) {
        push @out, sprintf('      %s: %s (line %d)', $sig->{name}, $sig->{text}, $sig->{line_no});
    }
}
push @out, '';

push @out, sprintf('=== any (%d files) ===', scalar(@{ $buckets{any} }));
push @out, "  $_->{relpath}" for @{ $buckets{any} };
push @out, '';

push @out, sprintf('=== already-marked (%d files) ===', scalar(@{ $buckets{'already-marked'} }));
push @out, "  $_->{relpath} (existing: $_->{existing})" for @{ $buckets{'already-marked'} };
push @out, '';

push @out, sprintf('=== needs-review (%d files) ===', scalar(@{ $buckets{'needs-review'} }));
push @out, "  $_->{relpath} (reason: $_->{reason})" for @{ $buckets{'needs-review'} };
push @out, '';

my $footer = sprintf('TOTAL: %d scanned, %d windows, %d any, %d already-marked, %d needs-review',
    $scanned, scalar(@{ $buckets{windows} }), scalar(@{ $buckets{any} }),
    scalar(@{ $buckets{'already-marked'} }), scalar(@{ $buckets{'needs-review'} }));
$footer .= sprintf(', errors: %d', scalar(@errors)) if @errors;
push @out, $footer;

# Named per-file detail for errors and attribute-restoration warnings
# (fix-batch A4/A3) -- a bare "errors: N" on a run touching hundreds of files
# is unactionable; an operator needs to know WHICH file and WHY without
# diffing the whole tree by hand. Deliberately NOT one of the four pinned
# bucket headers (no "(<n> files)" suffix, so it does not match the header
# regex the report parser keys on) -- these sections are omitted entirely
# when empty, unlike the four always-printed buckets, since the overwhelming
# majority of runs have zero of either.
if (@errors) {
    @errors = sort { $a->{relpath} cmp $b->{relpath} } @errors;
    push @out, '';
    push @out, sprintf('=== errors (%d) ===', scalar(@errors));
    push @out, "  $_->{relpath} ($_->{reason})" for @errors;
}
if (@attr_warnings) {
    @attr_warnings = sort { $a->{relpath} cmp $b->{relpath} } @attr_warnings;
    push @out, '';
    push @out, sprintf('=== attr-warnings (%d) ===', scalar(@attr_warnings));
    push @out, "  $_->{relpath} ($_->{reason})" for @attr_warnings;
}

print join("\n", @out), "\n";

exit(@errors ? 1 : 0);
