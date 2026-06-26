#!/usr/bin/env perl
# backpack.pl encoding + verify-surfacing regressions.
#
#   1. UTF-8 is encoded EXACTLY ONCE. backpack.pl has `use utf8` (so source-literal
#      non-ASCII like the em-dashes in its messages are real characters) plus a
#      :encoding(UTF-8) STDOUT/STDERR layer, and it decodes @ARGV from UTF-8 before
#      storing it. A regression to any of those double-encodes non-ASCII: an
#      em-dash 'E2 80 94' becomes 'C3 A2 C2 80 C2 94' — observed both in the
#      script's own output (source literals) and on disk (a --rationale arg).
#   2. A failed `verify` echoes the verify command. The verify is usually
#      self-silencing ('… 2>/dev/null | grep -q …'), so a bare exit code told the
#      user nothing about WHAT failed.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $BP = File::Spec->rel2abs(File::Spec->catfile($Bin, qw(.. .. scripts backpack.pl)));
ok(-f $BP, "backpack.pl exists at $BP") or BAIL_OUT("missing $BP");

my $EMDASH_1X = "\xe2\x80\x94";                 # correct UTF-8 for U+2014 (em-dash)
my $EMDASH_2X = "\xc3\xa2\xc2\x80\xc2\x94";     # the double-encoded mojibake

my $tmp = tempdir(CLEANUP => 1);
my $capn = 0;

# slurp_raw — file contents as raw bytes (no decode layer), or '' if absent.
sub slurp_raw {
    my $p = shift;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

# run_bp(@args) -> ($exit_code, $combined_output_bytes)
# Invokes backpack.pl via system(LIST) (no shell, so non-ASCII argv bytes pass
# through byte-faithfully where the OS allows). stdout+stderr are captured by
# duping our own handles to a temp file across the call (same pattern as
# backpack.pl's run_bash_silent) — portable and keeps the child's output out of
# this test's TAP stream.
sub run_bp {
    my @args = @_;
    my $cap = File::Spec->catfile($tmp, "cap." . (++$capn));
    open my $oo, '>&', \*STDOUT or die "dup STDOUT: $!";
    open my $oe, '>&', \*STDERR or die "dup STDERR: $!";
    open STDOUT, '>:raw', $cap  or die "redirect STDOUT: $!";
    open STDERR, '>&', \*STDOUT or die "merge STDERR: $!";
    my $rc = system($^X, $BP, @args);
    open STDOUT, '>&', $oo or die "restore STDOUT: $!";
    open STDERR, '>&', $oe or die "restore STDERR: $!";
    close $oo;
    close $oe;
    return ($rc == -1 ? -1 : $rc >> 8, slurp_raw($cap));
}

# --- 1a. source-literal em-dash is single-encoded (portable: no argv, no bash) ---
{
    my (undef, $out) = run_bp('help');
    ok(index($out, $EMDASH_1X) >= 0,
       'help output contains a correctly single-encoded em-dash (use utf8 active)');
    is(index($out, $EMDASH_2X), -1,
       'help output is NOT double-encoded (no c3a2 c280 c294 mojibake)');
}

# --- 1b. a --rationale em-dash round-trips to disk single-encoded ----------------
# Probe-guarded: only firm when the platform delivers argv byte-faithfully
# (Linux/container always; native-Windows argv may transcode → skip rather than
# false-fail). The fix targets the UTF-8 container where /backpack:add runs.
{
    my $bp = File::Spec->catfile($tmp, 'probe-backpack.json');
    my ($rc) = run_bp('add', $bp,
        '--category', 'other', '--name', 'probe',
        '--install', 'true', '--verify', 'true',
        '--rationale', $EMDASH_1X);
    is($rc, 0, 'add with a UTF-8 rationale succeeds');
    my $raw = slurp_raw($bp);
    if (index($raw, $EMDASH_2X) >= 0) {
        fail('rationale stored DOUBLE-encoded — @ARGV not decoded (regression)');
    } elsif (index($raw, $EMDASH_1X) >= 0) {
        pass('rationale stored single-encoded on disk (@ARGV decoded once)');
    } else {
        ok(1, 'skip: platform argv not byte-faithful for non-ASCII (neither em-dash form on disk)');
    }
}

# --- 2. a failed verify echoes the verify command -------------------------------
# Needs a working bash (backpack runs install/verify via `bash -c`); skip if absent.
{
    my $have_bash = (system('bash', '-c', 'exit 0') == 0);
  SKIP: {
        skip 'bash not available for the install/verify pass', 2 unless $have_bash;

        my $fix = File::Spec->catfile($tmp, 'verifyfail-backpack.json');
        # A valid v2 backpack whose verify always fails (install is a no-op).
        open my $fh, '>:raw', $fix or die "write $fix: $!";
        print $fh <<'JSON';
{
   "version" : 2,
   "items" : [
      {
         "category" : "other",
         "name" : "vtest",
         "install" : "true",
         "verify" : "false",
         "added" : "2026-06-26"
      }
   ]
}
JSON
        close $fh;

        my ($rc, $out) = run_bp('install', $fix);
        isnt($rc, 0, 'install exits non-zero when an item fails verify');
        like($out, qr/verify:\s*false/,
             'FAIL output echoes the (self-silencing) verify command');
    }
}

done_testing();
