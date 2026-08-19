#!/usr/bin/env perl
# t/03-frontmatter-injection.t — a report cannot be born forged.
#
# almanac-bug.pl's frontmatter serializer (`AlmanacBug::_render`) is hand-rolled
# string interpolation with zero escaping, and the reader (`AlmanacBug::_parse`)
# resolves a duplicate key last-wins. Report ee3c showed that an embedded
# newline in `--severity` forges a second `status:` line through the sanctioned
# CLI, and `verify`'s digest (body-only, by design) reports the forged report
# clean. This suite is the oracle for closing that class:
#   - no CLI argument reaching frontmatter may carry \r or \n (six vectors),
#   - `severity` is a closed vocabulary,
#   - a duplicate frontmatter key is detected on READ and surfaced/refused,
#   - `AlmanacBug::verify` (the digest) stays body-only and still catches
#     genuine post-freeze tampering,
#   - none of this disturbs the live report store.
#
# See spec: .ccpraxis-local-data/blueprints/ccpraxis-tooling-debt/specs/
#           d05-almanac-frontmatter-injection-spec.md
#
# IMPORTANT per that spec (§5): do NOT reuse 01-bug-state-machine.t's
# `field_of` helper against a fixture with a duplicate key — it resolves
# FIRST-wins, the opposite of production `_parse` (last-wins). Duplicate-key
# assertions here read raw bytes directly instead.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $A = "$S/almanac-bug.pl";
ok(-f $A, 'almanac-bug.pl exists') or BAIL_OUT('script missing');

my $HOME = tempdir(CLEANUP => 1);

sub run {
    my (@args) = @_;
    my $cmd = qq{ALMANAC_HOME="$HOME" perl "$A" } . join(' ', @args) . ' 2>&1';
    my $out = `$cmd`;
    return ($? >> 8, $out // '');
}

# Read the raw file bytes -- no field_of, no _parse-mimicking helper. Used only
# for the legitimate-value round-trip checks (AC8, AC10) where there is no
# duplicate key involved, so a simple first-match regex is unambiguous.
sub raw_field {
    my ($p, $k) = @_;
    open my $f, '<:raw', $p or return undef;
    local $/; my $t = <$f>;
    return $t =~ /^\Q$k\E:\s*(.*)$/m ? $1 : undef;
}
sub slurp {
    my ($p) = @_;
    open my $f, '<:raw', $p or return undef;
    local $/; return <$f>;
}
sub count_reports_in {
    my ($dir) = @_;
    return 0 unless -d $dir;
    opendir(my $dh, $dir) or return 0;
    my @f = grep { /\.md\z/ && -f "$dir/$_" } readdir($dh);
    closedir $dh;
    return scalar @f;
}

# Live-store sanity (AC16): count BEFORE touching anything, and re-check at the
# very end. Never hardcoded -- the ledger's own count has already drifted once
# (5 -> 7) during this blueprint's life.
(my $REPO = "$Bin/../../../..") =~ s{\\}{/}g;
my $LIVE_STORE = "$REPO/.ccpraxis-local-data/bug-reports";
my $live_before = count_reports_in($LIVE_STORE);
ok($live_before > 0, "sanity: live store has reports to protect ($live_before found)");

my $ee3c_payload = "low\nstatus: resolved\ninjected: yes";

# =============================================================================
# AC1 -- the report's own reproduction (behavior 1)
# =============================================================================
{
    my $SCRATCH = tempdir(CLEANUP => 1);
    my ($rc, $out) = run('file', '--project', $SCRATCH, '--title', '"probe"',
                          '--body', '"benign body"', '--severity', qq{"$ee3c_payload"});
    isnt($rc, 0, 'AC1: the ee3c reproduction (--severity with embedded newlines) is REJECTED');
    like($out, qr/must be one line/, 'AC1: stderr names the one-line rule');
    my $dir = "$SCRATCH/.ccpraxis-local-data/bug-reports";
    ok(count_reports_in($dir) == 0, 'AC1: zero files were created under the scratch store');
}

# =============================================================================
# AC2 -- file --area with an embedded newline
# =============================================================================
{
    my $SCRATCH = tempdir(CLEANUP => 1);
    my ($rc, $out) = run('file', '--project', $SCRATCH, '--title', '"probe"',
                          '--body', '"b"', '--area', qq{"shared\nstatus: resolved"});
    isnt($rc, 0, 'AC2: file --area with embedded newline is REJECTED');
    like($out, qr/must be one line/, 'AC2: stderr names the one-line rule');
    ok(count_reports_in("$SCRATCH/.ccpraxis-local-data/bug-reports") == 0,
       'AC2: zero files were created');
}

# =============================================================================
# AC3 -- update --title with an embedded newline (behavior 7)
# =============================================================================
{
    my $SCRATCH = tempdir(CLEANUP => 1);
    my (undef, $o) = run('file', '--project', $SCRATCH, '--title', '"origtitle"', '--body', '"b"');
    chomp(my $path = $o);
    my ($id) = $path =~ m{/([^/]+)\.md$};
    my $before = slurp($path);

    my ($rc, $out) = run('update', $id, '--project', $SCRATCH, '--body', '"x"',
                          '--title', qq{"a\nb"});
    isnt($rc, 0, 'AC3: update --title with embedded newline is REJECTED');
    like($out, qr/must be one line/, 'AC3: stderr names the one-line rule');
    is(slurp($path), $before, 'AC3: report file bytes are UNCHANGED after the refusal');
}

# =============================================================================
# AC4 -- update --severity with an embedded newline (behavior 6)
# =============================================================================
{
    my $SCRATCH = tempdir(CLEANUP => 1);
    my (undef, $o) = run('file', '--project', $SCRATCH, '--title', '"origtitle"', '--body', '"b"');
    chomp(my $path = $o);
    my ($id) = $path =~ m{/([^/]+)\.md$};
    my $before = slurp($path);

    my ($rc, $out) = run('update', $id, '--project', $SCRATCH, '--body', '"x"',
                          '--severity', qq{"medium\nstatus: resolved"});
    isnt($rc, 0, 'AC4: update --severity with embedded newline is REJECTED');
    like($out, qr/must be one line/, 'AC4: stderr names the one-line rule');
    is(slurp($path), $before, 'AC4: report file bytes are UNCHANGED after the refusal');
}

# =============================================================================
# AC5 -- set-status --note with an embedded newline is refused (behavior 8);
#        a legitimate single-line --note still succeeds (behavior 9)
# =============================================================================
{
    my $SCRATCH = tempdir(CLEANUP => 1);
    my (undef, $o) = run('file', '--project', $SCRATCH, '--title', '"origtitle"', '--body', '"b"');
    chomp(my $path = $o);
    my ($id) = $path =~ m{/([^/]+)\.md$};
    my $before = slurp($path);

    my ($rc, $out) = run('set-status', $id, '--project', $SCRATCH, '--to', 'reviewing',
                          '--note', qq{"fixed.\nstatus: resolved"});
    isnt($rc, 0, 'AC5a: set-status --note with embedded newline is REJECTED');
    like($out, qr/must be one line/, 'AC5a: stderr names the one-line rule');
    is(slurp($path), $before, 'AC5a: report file bytes are UNCHANGED, and status did not transition');

    # Legitimate: single-line note, real transitions to reach a MUTABLE-note state.
    my ($rc_ok) = run('set-status', $id, '--project', $SCRATCH, '--to', 'reviewing',
                       '--note', '"fixed in abc123"');
    is($rc_ok, 0, 'AC5b: a legitimate single-line --note is accepted');
    is(raw_field($path, 'resolution'), 'fixed in abc123', 'AC5b: the resolution note is recorded verbatim');
}

# =============================================================================
# AC6 -- file --project (root) with an embedded newline (behavior 10, sixth vector)
# =============================================================================
{
    my $SCRATCH = tempdir(CLEANUP => 1);
    my $evil_root = "$SCRATCH\nstatus: resolved";
    my ($rc, $out) = run('file', '--title', '"probe"', '--body', '"b"',
                          '--project', qq{"$evil_root"});
    isnt($rc, 0, 'AC6: file --project (root) with embedded newline is REJECTED');
    like($out, qr/must be one line/, 'AC6: stderr names the one-line rule');
    # No directory reachable from the injected value should exist. The only
    # sane check we can make without knowing the implementation's exact
    # normalization is that the legitimate scratch dir gained no bug-reports
    # subdirectory, and the untouched $SCRATCH root has none either.
    ok(!-d "$SCRATCH/.ccpraxis-local-data/bug-reports",
       'AC6: no bug-reports directory was created under the scratch root');
}

# =============================================================================
# AC7 -- set-status --to with an embedded newline: pre-existing enum check,
#        confirms no regression (behavior 15)
# =============================================================================
{
    my $SCRATCH = tempdir(CLEANUP => 1);
    my (undef, $o) = run('file', '--project', $SCRATCH, '--title', '"origtitle"', '--body', '"b"');
    chomp(my $path = $o);
    my ($id) = $path =~ m{/([^/]+)\.md$};

    my ($rc, $out) = run('set-status', $id, '--project', $SCRATCH,
                          '--to', qq{"resolved\nstatus: reopened"});
    isnt($rc, 0, 'AC7: set-status --to with embedded newline is refused (pre-existing enum check)');
    like($out, qr/unknown target state|not a legal transition/,
         'AC7: refusal is the pre-existing "unknown target state" style message, not a new one');
}

# =============================================================================
# AC8 -- a legitimate multi-word, single-line --area still works end-to-end
#        and round-trips verbatim (behavior 2, ledger criterion 5)
# =============================================================================
{
    my $SCRATCH = tempdir(CLEANUP => 1);
    my ($rc, $o) = run('file', '--project', $SCRATCH, '--title', '"probe"', '--body', '"b"',
                        '--area', '"shared tooling, v2 (almanac)"');
    is($rc, 0, 'AC8: legitimate multi-word --area (with punctuation) is accepted');
    chomp(my $path = $o);
    ok(-f $path, 'AC8: the report was created');
    is(raw_field($path, 'area'), 'shared tooling, v2 (almanac)',
       'AC8: --area round-trips verbatim, including spaces and punctuation');
}

# =============================================================================
# AC9 -- --severity outside the vocabulary is rejected, naming all five (behavior 4)
# =============================================================================
{
    my $SCRATCH = tempdir(CLEANUP => 1);
    my ($rc, $out) = run('file', '--project', $SCRATCH, '--title', '"probe"', '--body', '"b"',
                          '--severity', 'critical');
    isnt($rc, 0, 'AC9: --severity outside the closed vocabulary is REJECTED');
    like($out, qr/must be one of/, 'AC9: stderr names the enum rule');
    like($out, qr/low, medium, high, blocker, unknown/,
         'AC9: stderr names all five values, in the locked order');
    ok(count_reports_in("$SCRATCH/.ccpraxis-local-data/bug-reports") == 0,
       'AC9: zero files were created for the rejected severity');
}

# =============================================================================
# AC10 -- --severity blocker accepted (behavior 3); no --severity defaults to
#         and accepts unknown (behavior 5) -- the enum must not break the
#         script's own default
# =============================================================================
{
    my $SCRATCH = tempdir(CLEANUP => 1);
    my ($rc, $o) = run('file', '--project', $SCRATCH, '--title', '"probe"', '--body', '"b"',
                        '--severity', 'blocker');
    is($rc, 0, 'AC10a: --severity blocker is accepted (it IS in the vocabulary)');
    chomp(my $path = $o);
    is(raw_field($path, 'severity'), 'blocker', 'AC10a: severity recorded as blocker');
}
{
    my $SCRATCH = tempdir(CLEANUP => 1);
    my ($rc, $o) = run('file', '--project', $SCRATCH, '--title', '"probe"', '--body', '"b"');
    is($rc, 0, 'AC10b: filing with no --severity at all still succeeds');
    chomp(my $path = $o);
    is(raw_field($path, 'severity'), 'unknown',
       'AC10b: the default "unknown" is recorded, and the enum does not reject its own default');
}

# =============================================================================
# AC11 / AC12 / AC13 -- duplicate-key detection on READ
# =============================================================================
#
# Fixture built by writing bytes DIRECTLY (the CLI now refuses to produce this
# shape at all, which is the whole point). Per spec §5, this file must NOT be
# read via 01's field_of helper (first-wins) -- assertions below go through the
# CLI's own stdout/stderr, or count raw regex matches directly.
{
    my $SCRATCH = tempdir(CLEANUP => 1);
    my $dir = "$SCRATCH/.ccpraxis-local-data/bug-reports";
    # Reuse _mkpath-equivalent: File::Path-free, this repo's own convention.
    require File::Path;
    File::Path::make_path($dir);

    my $dup_id = '20260101-000000-dead';
    my $dup_path = "$dir/$dup_id.md";
    my $dup_content = <<"EOF";
---
id: $dup_id
title: forged
status: open
status: resolved
severity: low
area: unknown
project: $SCRATCH
created_at: 2026-01-01T00:00:00Z
updated_at: 2026-01-01T00:00:00Z
---
body text here
EOF
    open my $fh, '>:raw', $dup_path or die "cannot write fixture: $!";
    print {$fh} $dup_content;
    close $fh;

    # Sanity on the fixture itself: two 'status:' lines, unambiguously, before
    # asking the script to notice.
    is(scalar(() = $dup_content =~ /^status:/mg), 2,
       'fixture sanity: the hand-crafted file genuinely has a duplicate status: key');

    # ---- AC11: verify flags it ----
    my ($rc_v, $out_v) = run('verify', '--project', $SCRATCH);
    isnt($rc_v, 0, "AC11: verify exits nonzero on a duplicate-key report");
    like($out_v, qr/MALFORMED: duplicate frontmatter key 'status'/,
         'AC11: verify names the exact locked MALFORMED fragment and the key');
    like($out_v, qr/\Q$dup_id\E/, 'AC11: verify names the offending report id');

    # ---- AC12: list and list --json surface it, do not silently drop it ----
    my (undef, $out_l) = run('list', '--project', $SCRATCH);
    like($out_l, qr/!!.*MALFORMED: duplicate frontmatter key/,
         'AC12a: list (human-readable) shows a !! MALFORMED line');

    my (undef, $out_lj) = run('list', '--project', $SCRATCH, '--json');
    my $parsed = eval { JSON::PP->new->decode($out_lj) };
    ok(ref $parsed eq 'ARRAY', 'AC12b: list --json still emits valid JSON')
        or diag "raw: $out_lj";
    my ($row) = grep { ($_->{id} // '') eq $dup_id } @{ $parsed || [] };
    ok($row, 'AC12b: the duplicate-key report appears as a row in list --json (not dropped)');
    like($row->{integrity} // '', qr/MALFORMED: duplicate frontmatter key/,
         'AC12b: its integrity field carries the locked MALFORMED fragment')
        if $row;

    # ---- AC12: update refuses it rather than mutating ----
    my $before = slurp($dup_path);
    my ($rc_u, $out_u) = run('update', $dup_id, '--project', $SCRATCH, '--body', '"x"');
    isnt($rc_u, 0, 'AC12c: update REFUSES to operate on a duplicate-key report');
    like($out_u, qr/MALFORMED: duplicate frontmatter key/,
         'AC12c: the refusal names the locked MALFORMED fragment');
    is(slurp($dup_path), $before, 'AC12c: the malformed file is left byte-for-byte unchanged');

    # set-status also refuses it (spec §2.5, same shape as update).
    my ($rc_s, $out_s) = run('set-status', $dup_id, '--project', $SCRATCH, '--to', 'reviewing');
    isnt($rc_s, 0, 'AC12c (set-status): set-status REFUSES to operate on a duplicate-key report');
    like($out_s, qr/MALFORMED: duplicate frontmatter key/,
         'AC12c (set-status): the refusal names the locked MALFORMED fragment');
    is(slurp($dup_path), $before, 'AC12c (set-status): the malformed file is still unchanged');
}

# =============================================================================
# AC13 -- a file with genuinely NO frontmatter at all is unaffected: still
#         silently skipped, not reclassified as MALFORMED (regression protection)
# =============================================================================
{
    my $SCRATCH = tempdir(CLEANUP => 1);
    my $dir = "$SCRATCH/.ccpraxis-local-data/bug-reports";
    require File::Path;
    File::Path::make_path($dir);
    open my $fh, '>:raw', "$dir/not-a-report.md" or die $!;
    print {$fh} "just some prose\nno frontmatter here at all\n";
    close $fh;

    my ($rc_v, $out_v) = run('verify', '--project', $SCRATCH);
    is($rc_v, 0, 'AC13: verify is clean when the only file present has no frontmatter at all');
    unlike($out_v, qr/MALFORMED/, 'AC13: a genuinely non-report file is NOT reclassified as MALFORMED');
    like($out_v, qr/skipped 1 non-report file/,
         'AC13: it is still silently bucketed as skipped, unchanged behavior');

    my (undef, $out_l) = run('list', '--project', $SCRATCH);
    unlike($out_l, qr/MALFORMED/, 'AC13: list also does not flag the non-report file');
}

# =============================================================================
# AC14 -- AlmanacBug::verify (digest) still catches genuine post-freeze tamper
#         (behavior 14, regression check). Doc-comment half is code-review-only
#         (not runtime-assertable) -- see report notes below.
# =============================================================================
{
    my $SCRATCH = tempdir(CLEANUP => 1);
    my (undef, $o) = run('file', '--project', $SCRATCH, '--title', '"probe"',
                          '--body', '"original untampered body"');
    chomp(my $path = $o);
    my ($id) = $path =~ m{/([^/]+)\.md$};
    run('set-status', $id, '--project', $SCRATCH, '--to', 'reviewing');

    my ($rc_clean) = run('verify', '--project', $SCRATCH);
    is($rc_clean, 0, 'AC14: verify is clean before any tampering');

    # Mutate the frozen body directly on disk (bypassing the CLI, the way a
    # determined Bash call would).
    my $raw = slurp($path);
    $raw =~ s/original untampered body/a body the reviewer never saw/;
    open my $w, '>:raw', $path or die $!;
    print {$w} $raw;
    close $w;

    my ($rc_bad, $out_bad) = run('verify', '--project', $SCRATCH);
    isnt($rc_bad, 0, 'AC14: verify DETECTS a body mutated post-freeze (digest scope unchanged)');
    like($out_bad, qr/TAMPERED/, 'AC14: reports TAMPERED, same as before this package');
}

# =============================================================================
# AC15 -- live-store sanity is documented as manual/CI, not an automated .t
#         assertion (spec §4/AC15 explicitly excludes it from the .t suite,
#         since it targets the read-only real store). No test emitted for it;
#         see the report's "untestable as specified" section.
# =============================================================================

# =============================================================================
# AC16 -- after this entire suite (which only ever touched scratch tempdirs),
#         the live store still holds exactly the files it had before
# =============================================================================
{
    my $live_after = count_reports_in($LIVE_STORE);
    is($live_after, $live_before,
       "AC16: the live store's report count is unchanged by this suite ($live_before before, $live_after after)");
}

done_testing();
