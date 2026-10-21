#!/usr/bin/env perl
# platform: any
# 04-blueprint-title-verb oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/test-naming-hygiene/specs/04-blueprint-title-verb-spec.md
# (11 ACs, mapped to DC1..DC6).
#
# The new verb does not exist yet: `bp-blueprint.pl set-title` is not in %DISPATCH, so
# EVERY invocation below exits 3 today with "unknown subcommand 'set-title'" on stderr,
# regardless of what a given test case wants to exercise. WRITTEN BLIND TO ANY
# implementation of the verb itself -- only the pre-existing shared scaffolding
# (run_write, field_safe, %META_FIELDS, the exit-code scheme) was read as context, since
# the spec explicitly cites that as the terrain a new verb must fit into.
#
# Several cases below happen to want exit code 3 (or, for the guard check, are entirely
# independent of this verb) -- those alone would coincidentally PASS today even with
# nothing implemented. Every such case therefore ALSO asserts stderr content (a mention
# of --file/--title, or a spec-quoted refusal phrase) that "unknown subcommand" cannot
# satisfy, so the case still fails today for the right reason: missing behavior, not a
# lucky exit-code coincidence.
#
# :raw ONLY throughout -- fixtures and comparisons operate on raw bytes, matching the
# subject script's own :raw discipline (spec §2.7 / DC4's byte-identity requirement).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use JSON::PP;
use Digest::MD5 qw(md5_hex);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $BUTLER = fwd(abs_path("$Bin/../..") // "$Bin/../..");
my $PROJ   = fwd(abs_path("$Bin/../../../..") // "$Bin/../../../..");
my $SCRIPT = "$BUTLER/scripts/bp-blueprint.pl";
my $HOOKSJ = "$BUTLER/hooks/hooks.json";

diag("subject under test: $SCRIPT "
     . (-e $SCRIPT ? "(present)"
                    : "(ABSENT -- every assertion below is expected to fail on MISSING BEHAVIOUR)"));

my $ROOT = tempdir(CLEANUP => 1);
my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;
my $pn = 0;
my $dn = 0;

# =====================================================================================
# Scaffolding (this file's own copy, matching every sibling .t's self-contained pattern
# -- e.g. plugins/butler/tests/t/set-test-paths.t, blueprint-write-api.t).
# =====================================================================================

sub write_file {
    my ($path, $bytes) = @_;
    open my $w, '>:raw', $path or die "write $path: $!";
    print $w $bytes;
    close $w or die "close $path: $!";
    return $path;
}

sub read_file {
    my ($path) = @_;
    open my $r, '<:raw', $path or return undef;
    local $/;
    my $c = <$r>;
    close $r;
    return defined $c ? $c : '';
}

sub digest_of { md5_hex(read_file($_[0]) // '') }

sub fresh_dir { my $d = "$ROOT/w" . (++$dn); mkdir $d or die "mkdir $d: $!"; return $d }

sub stage_bytes {
    my ($bytes, $name) = @_;
    $name = 'blueprint.md' unless defined $name;
    my $d = fresh_dir();
    return write_file("$d/$name", $bytes);
}

# All exit codes observed from a 'set-title' invocation, across the whole file -- feeds
# AC3's negative assertion (exit 5 is reserved elsewhere and must never fire here).
my @ALL_SET_TITLE_RC;

sub run_pl {
    my ($args) = @_;
    my $n = ++$pn;
    my ($outf, $errf) = ("$ROOT/out.$n", "$ROOT/err.$n");
    write_file($outf, '');
    write_file($errf, '');
    local %ENV = (%CLEAN_ENV, BSTV_SCRIPT => fwd($SCRIPT), BSTV_OUT => fwd($outf), BSTV_ERR => fwd($errf));
    my $rc = system('bash', '-c',
        'timeout 30 perl "$BSTV_SCRIPT" "$@" > "$BSTV_OUT" 2> "$BSTV_ERR"', 'bp-blueprint', @$args);
    my ($code, $out, $err) = ($rc >> 8, read_file($outf) // '', read_file($errf) // '');
    push @ALL_SET_TITLE_RC, $code if @$args && $args->[0] eq 'set-title';
    return ($code, $out, $err);
}

sub run_hook {
    my ($hook_path, $payload) = @_;
    my $n = ++$pn;
    my $pf   = write_file("$ROOT/payload.$n.json", $payload);
    my $outf = write_file("$ROOT/hout.$n", '');
    my $errf = write_file("$ROOT/herr.$n", '');
    local %ENV = (%CLEAN_ENV, BSTV_HOOK => fwd($hook_path), BSTV_IN => fwd($pf),
                  BSTV_OUT => fwd($outf), BSTV_ERR => fwd($errf));
    my $rc = system('bash', '-c',
        'timeout 30 bash "$BSTV_HOOK" < "$BSTV_IN" > "$BSTV_OUT" 2> "$BSTV_ERR"');
    return ($rc >> 8, read_file($outf) // '', read_file($errf) // '');
}

# Independent (non-implementation) re-derivation of the spec §2.2 fence-aware H1 scan,
# used ONLY to check the FINAL FILE STATE the real verb produced (AC6c) -- this is test
# oracle logic over observable output, not a copy of the subject's internals.
sub count_h1_candidates {
    my ($bytes) = @_;
    my @lines = split /\n/, $bytes, -1;
    my $in_fence = 0;
    my $n = 0;
    for my $line (@lines) {
        if ($line =~ /^```/) { $in_fence = !$in_fence; next }
        next if $in_fence;
        $n++ if $line =~ /^#(?!#)[ \t]+\S/;
    }
    return $n;
}

# =====================================================================================
# Fixtures. Every one carries at least one raw non-ASCII byte (Andr\xC3\xA9-class or the
# em-dash \xE2\x80\x94), matching blueprint-write-api.t's own convention, so a stray
# :encoding(UTF-8) layer regression would corrupt a byte-identity assertion rather than
# pass silently.
# =====================================================================================

# Canonical shape: single H1 on line 1, no fence anywhere.
sub base_fixture {
    return join("\n",
        '# <Blueprint Title>',
        '',
        '## Package status',
        '',
        '| pkg | deliverable | depends_on | model |',
        '|---|---|---|---|',
        "| b01 | first thing Andr\xC3\xA9 | \xE2\x80\x94 | sonnet |",
        '',
        '## Decisions',
        '',
        '- an earlier decision, no hazard token here.',
        '',
    );
}

# A fenced metadata block (shape of templates/blueprint.md's metadata fence)
# containing single-`#`-prefixed comment lines that a
# fence-blind scan would miscount as extra H1 candidates. Genuine H1 on line 1.
sub fence_fixture {
    return join("\n",
        '# <Blueprint Title>',
        '',
        '```',
        '# owner: platform                     <!-- optional blueprint-level comment -->',
        '# notes:                              <!-- optional, may span lines;',
        "#   continued comment line, still inside the fence; Andr\xC3\xA9's.",
        '```',
        '',
        '## Package status',
        '',
        '| pkg | deliverable | depends_on | model |',
        '|---|---|---|---|',
        "| b01 | first thing | \xE2\x80\x94 | sonnet |",
        '',
    );
}

# No `# ` heading anywhere outside a fenced block (the one inside the fence must not count).
sub no_h1_fixture {
    return join("\n",
        'Not a heading at all',
        '',
        "some prose with a non-ascii byte: Andr\xC3\xA9",
        '```',
        '# owner: platform',
        '```',
        'trailing prose, still no real heading',
        '',
    );
}

# The only `# ` heading is present but NOT on line 1 (it is on line 3, 1-based).
sub h1_not_line1_fixture {
    return join("\n",
        'Not a heading',
        '',
        '# Actual Heading Text',
        '',
        "more prose Andr\xC3\xA9",
        '',
    );
}

# Two non-fenced `# `-shaped lines: a genuine H1 on line 1 AND a second one later.
sub multi_h1_fixture {
    return join("\n",
        '# First Heading',
        '',
        "prose Andr\xC3\xA9",
        '# Second Heading',
        '',
        'trailing',
        '',
    );
}

# An UNTERMINATED fence (odd delimiter count) opened before any real heading -- the
# boolean toggle stays "in fence" for the rest of the document (§5, edge cases), so the
# only H1-shaped line after the fence-open is never collected -> "no H1 found", not a
# crash and not a false positive.
sub odd_fence_fixture {
    return join("\n",
        'Not a heading',
        '',
        '```',
        '# looks like an H1 but is inside an unterminated fence',
        "more content Andr\xC3\xA9",
        '',
    );
}

# =====================================================================================
# AC1 (DC1) / observable behavior 1: successful set-title, exit 0, line 1 becomes
# EXACTLY "# <new title>" (eq, not a substring match), every other line unchanged.
# =====================================================================================
{
    my $path = stage_bytes(base_fixture());
    my ($rc, $out, $err) = run_pl(['set-title', '--file', $path, '--title', 'New Title']);
    is($rc, 0, 'AC1: set-title --title "New Title" exits 0') or diag("stderr: $err");
    my $after = read_file($path);
    my @lines = split /\n/, $after, -1;
    is($lines[0], '# New Title', 'AC1: line 1 is EXACTLY "# New Title" (eq, not substring)');
}

# =====================================================================================
# AC2 (DC1) / observable behaviors 5 & 6: usage vs I/O failures get the documented code,
# AND stderr must actually name the missing option -- "unknown subcommand" cannot.
# =====================================================================================
{
    my $path = stage_bytes(base_fixture());

    my ($rc1, $o1, $e1) = run_pl(['set-title', '--title', 'X']);
    is($rc1, 3, 'AC2: missing --file exits 3');
    like($e1, qr/--file/i, 'AC2: stderr names --file for a missing --file');

    my ($rc2, $o2, $e2) = run_pl(['set-title', '--file', $path]);
    is($rc2, 3, 'AC2: missing --title exits 3');
    like($e2, qr/--title/i, 'AC2: stderr names --title for a missing --title');

    my $missing = fwd("$ROOT/does/not/exist/blueprint.md");
    my ($rc3, $o3, $e3) = run_pl(['set-title', '--file', $missing, '--title', 'X']);
    is($rc3, 4, 'AC2: a --file that does not exist on disk exits 4');
    like($e3, qr/cannot read|no such file/i, 'AC2: stderr names the read failure, not "unknown subcommand"');

    my ($rc4) = run_pl(['set-title', '--file', $path, '--title', 'X', '--bogus-opt', 'y']);
    is($rc4, 3, 'AC2: an unrecognised option exits 3');
}

# =====================================================================================
# AC3 (DC1): negative assertion -- exit code 5 (reserved for read-verb "not found") is
# NEVER emitted by any set-title invocation exercised anywhere in this suite.
# =====================================================================================
# (checked at the very end of this file, after every other block has run and pushed
# into @ALL_SET_TITLE_RC.)

# =====================================================================================
# AC4 (DC2) / observable behavior 3: --title containing "|" -> exit 3, digest of the
# untouched file unchanged, and stderr actually references --title / the constraint.
# =====================================================================================
{
    my $path = stage_bytes(base_fixture());
    my $before = digest_of($path);
    my ($rc, $out, $err) = run_pl(['set-title', '--file', $path, '--title', 'Bad|Title']);
    is($rc, 3, 'AC4: --title containing "|" exits 3');
    is(digest_of($path), $before, 'AC4: file digest unchanged (nothing opened/written)');
    like($err, qr/--title/i, 'AC4: stderr names --title');
    like($err, qr/pipe|newline|\|/i, 'AC4: stderr names the validation reason (pipe/newline), matching field_safe\'s style');
}

# =====================================================================================
# AC5 (DC2) / observable behavior 4: --title containing an embedded newline -> exit 3,
# digest unchanged.
# =====================================================================================
{
    my $path = stage_bytes(base_fixture());
    my $before = digest_of($path);
    my ($rc, $out, $err) = run_pl(['set-title', '--file', $path, '--title', "Bad\nTitle"]);
    is($rc, 3, 'AC5: --title containing an embedded newline exits 3');
    is(digest_of($path), $before, 'AC5: file digest unchanged');
    like($err, qr/--title/i, 'AC5: stderr names --title');
}

# =====================================================================================
# AC6 (DC3) / observable behavior 2: idempotence. Two identical calls: both exit 0; the
# digest after call 2 equals the digest after call 1 (no rewrite, no duplication); the
# final file has EXACTLY ONE non-fenced single-`#` heading line.
# =====================================================================================
{
    my $path = stage_bytes(base_fixture());
    my ($rc1, $o1, $e1) = run_pl(['set-title', '--file', $path, '--title', 'Same Title']);
    is($rc1, 0, 'AC6: first call exits 0') or diag("stderr: $e1");
    my $digest1 = digest_of($path);

    my ($rc2, $o2, $e2) = run_pl(['set-title', '--file', $path, '--title', 'Same Title']);
    is($rc2, 0, 'AC6: second, identical call also exits 0') or diag("stderr: $e2");
    is(digest_of($path), $digest1, 'AC6: digest after call 2 equals digest after call 1 (no rewrite)');

    is(count_h1_candidates(read_file($path)), 1,
       'AC6: exactly one non-fenced single-# heading line in the final file (no duplicate heading)');
}

# =====================================================================================
# AC7 (DC4): the strongest byte-identity form. Splice the ORIGINAL fixture's own lines,
# replacing ONLY line 0 with "# " . $new_title, rejoin with "\n" -- an expected string
# built independently of the subject -- and assert FULL STRING EQUALITY against what
# set-title actually produced.
# =====================================================================================
{
    my $orig_bytes = base_fixture();
    my $path = stage_bytes($orig_bytes);
    my $new_title = "Renamed \xC3\x89dition"; # raw UTF-8 bytes for capital-E-acute, non-ASCII
    my ($rc, $out, $err) = run_pl(['set-title', '--file', $path, '--title', $new_title]);
    is($rc, 0, 'AC7: mutating call exits 0') or diag("stderr: $err");

    my @orig_lines = split /\n/, $orig_bytes, -1;
    $orig_lines[0] = '# ' . $new_title;
    my $expected = join("\n", @orig_lines);

    is(read_file($path), $expected,
       'AC7: full-string equality against an independently-spliced expected value '
     . '(every byte outside line 1 is provably untouched)');
}

# =====================================================================================
# AC8 (DC4) / observable behavior 10: same full-string-equality proof, but on the
# fence-shaped fixture -- proves the in-fence single-# comment lines survive byte-for-
# byte (the fence-tracking hazard from spec §1), not merely "exit 0, no crash".
# =====================================================================================
{
    my $orig_bytes = fence_fixture();
    my $path = stage_bytes($orig_bytes);
    my $new_title = 'Fence-Safe Title';
    my ($rc, $out, $err) = run_pl(['set-title', '--file', $path, '--title', $new_title]);
    is($rc, 0, 'AC8: set-title against the fence-shaped fixture exits 0') or diag("stderr: $err");

    my @orig_lines = split /\n/, $orig_bytes, -1;
    $orig_lines[0] = '# ' . $new_title;
    my $expected = join("\n", @orig_lines);

    is(read_file($path), $expected,
       'AC8: full-string equality -- only line 1 changed, in-fence comment lines byte-identical');
}

# =====================================================================================
# AC9 (DC1/DC4) / observable behaviors 7, 8, 9: the three refusal shapes. Each exits 2
# and leaves the file's digest unchanged; stderr names the specific shape (spec-quoted
# wording), which "unknown subcommand" text can never satisfy.
# =====================================================================================
{
    # behavior 7: no H1 anywhere outside a fence.
    my $path = stage_bytes(no_h1_fixture());
    my $before = digest_of($path);
    my ($rc, $out, $err) = run_pl(['set-title', '--file', $path, '--title', 'X']);
    is($rc, 2, 'AC9(no-H1): exits 2');
    is(digest_of($path), $before, 'AC9(no-H1): file digest unchanged');
    like($err, qr/no H1/i, 'AC9(no-H1): stderr says no H1 was found');
    like($err, qr/fenced/i, 'AC9(no-H1): stderr mentions the fenced-block scope');
}
{
    # behavior 8: an H1-shaped line exists but not on line 1 (line 3, 1-based, in this fixture).
    my $path = stage_bytes(h1_not_line1_fixture());
    my $before = digest_of($path);
    my ($rc, $out, $err) = run_pl(['set-title', '--file', $path, '--title', 'X']);
    is($rc, 2, 'AC9(not-line-1): exits 2');
    is(digest_of($path), $before, 'AC9(not-line-1): file digest unchanged');
    like($err, qr/not line 1|not on line 1/i, 'AC9(not-line-1): stderr says it is not on line 1');
    like($err, qr/\bline 3\b/, 'AC9(not-line-1): stderr names the actual 1-based line number (3)');
}
{
    # behavior 9: valid H1 on line 1 PLUS a second, non-fenced `# `-shaped line elsewhere.
    my $path = stage_bytes(multi_h1_fixture());
    my $before = digest_of($path);
    my ($rc, $out, $err) = run_pl(['set-title', '--file', $path, '--title', 'X']);
    is($rc, 2, 'AC9(ambiguous): exits 2');
    is(digest_of($path), $before, 'AC9(ambiguous): file digest unchanged');
    like($err, qr/2 .*heading|headings found/i, 'AC9(ambiguous): stderr says more than one was found');
    like($err, qr/which is the title|refusing to guess/i, 'AC9(ambiguous): stderr says it refuses to guess');
}

# =====================================================================================
# AC10 (DC5) / observable behavior 11: guard-blueprint-write.sh denies a direct Write to
# any */blueprint.md path, UNAFFECTED by set-title's existence (verb-agnostic, path
# match only). No set-title-specific assertion here by design (spec §4, AC10).
# =====================================================================================
{
    my $raw = read_file($HOOKSJ);
    my $J = JSON::PP->new->canonical;
    my $decoded = eval { $J->decode($raw) };
    ok(ref $decoded eq 'HASH', 'AC10: hooks.json parses as JSON');

    my @pretooluse = ref $decoded eq 'HASH' && ref $decoded->{hooks} eq 'HASH'
                     && ref $decoded->{hooks}{PreToolUse} eq 'ARRAY'
                   ? @{ $decoded->{hooks}{PreToolUse} } : ();
    my @commands;
    for my $block (@pretooluse) {
        next unless ref $block eq 'HASH' && ref $block->{hooks} eq 'ARRAY';
        for my $h (@{ $block->{hooks} }) {
            push @commands, $h->{command} if ref $h eq 'HASH' && defined $h->{command};
        }
    }
    my ($blueprint_hook_cmd) = grep { /blueprint/i } @commands;
    ok(defined $blueprint_hook_cmd, 'AC10: hooks.json registers a PreToolUse hook whose command mentions "blueprint"');

  SKIP: {
        skip('no blueprint-targeting hook registered -- see prior assertion', 1)
            unless defined $blueprint_hook_cmd;
        my ($hook_path) = $blueprint_hook_cmd =~ /"([^"]*\.sh)"/;
        $hook_path =~ s/\$\{CLAUDE_PLUGIN_ROOT\}/$BUTLER/ if defined $hook_path;
        skip("could not extract a hook script path from: $blueprint_hook_cmd", 1)
            unless defined $hook_path && -e $hook_path;

        my $fake_bp = fwd("$ROOT/some/dir/blueprint.md");
        my $deny_payload = $J->encode({ tool_name => 'Write', cwd => $PROJ,
                            tool_input => { file_path => $fake_bp, content => 'direct hand-edit attempt' } });
        my ($rc1, $out1, $err1) = run_hook($hook_path, $deny_payload);
        isnt($rc1, 0, 'AC10: guard-blueprint-write.sh DENIES a direct Write to a */blueprint.md path '
                     . '(unaffected by set-title existing or not -- verb-agnostic, path-based)');
    }
}

# =====================================================================================
# Edge cases (spec §5), beyond the 11 numbered ACs.
# =====================================================================================

# Empty file (zero bytes): split(-1) yields one empty element, no H1 match -> "no H1
# found" refusal (exit 2), not a crash.
{
    my $path = stage_bytes('');
    my ($rc, $out, $err) = run_pl(['set-title', '--file', $path, '--title', 'X']);
    is($rc, 2, 'EDGE(empty-file): a zero-byte file refuses with exit 2, not a crash');
}

# --title empty / whitespace-only is LEGAL (passes field_safe); line 1 becomes exactly
# "# " followed by whatever whitespace (or nothing) was given -- no trimming.
{
    my $path = stage_bytes(base_fixture());
    my ($rc, $out, $err) = run_pl(['set-title', '--file', $path, '--title', '']);
    is($rc, 0, 'EDGE(empty-title): an empty --title is legal, exits 0') or diag("stderr: $err");
    my @lines = split /\n/, read_file($path), -1;
    is($lines[0], '# ', 'EDGE(empty-title): line 1 is exactly "# " (no trimming)');
}
{
    my $path = stage_bytes(base_fixture());
    my ($rc, $out, $err) = run_pl(['set-title', '--file', $path, '--title', '   ']);
    is($rc, 0, 'EDGE(whitespace-title): a whitespace-only --title is legal, exits 0') or diag("stderr: $err");
    my @lines = split /\n/, read_file($path), -1;
    is($lines[0], '#    ', 'EDGE(whitespace-title): line 1 is exactly "# " + the 3 spaces given');
}

# A title containing literal backticks (incl. 3+ in a row) is always preceded by "# " on
# its line -- can never itself become a fence delimiter, so it must not desync fence
# parity for the NEXT invocation (spec §2.3's "designed-in safety property" / §5).
{
    my $path = stage_bytes(base_fixture());
    my $backtick_title = 'Title with ```triple backticks``` inside';
    my ($rc1, $o1, $e1) = run_pl(['set-title', '--file', $path, '--title', $backtick_title]);
    is($rc1, 0, 'EDGE(backticks): a --title containing ``` exits 0') or diag("stderr: $e1");
    my @lines = split /\n/, read_file($path), -1;
    is($lines[0], "# $backtick_title", 'EDGE(backticks): line 1 holds the backticks verbatim');

    my ($rc2, $o2, $e2) = run_pl(['set-title', '--file', $path, '--title', 'After Backticks']);
    is($rc2, 0, 'EDGE(backticks): a SECOND set-title call after a backtick-laden line 1 still '
              . 'succeeds (fence parity not desynchronized by the previous title)') or diag("stderr: $e2");
}

# An unterminated (odd-count) fence is conservative: it under-collects rather than
# mis-collects, tending toward "no H1 found" rather than a wrong replacement.
{
    my $path = stage_bytes(odd_fence_fixture());
    my ($rc, $out, $err) = run_pl(['set-title', '--file', $path, '--title', 'X']);
    is($rc, 2, 'EDGE(odd-fence): an unterminated fence refuses conservatively (exit 2), no crash');
}

# =====================================================================================
# AC3 (DC1), evaluated last: exit code 5 must never appear among every set-title
# invocation this file made, across every case above.
# =====================================================================================
ok(!(grep { $_ == 5 } @ALL_SET_TITLE_RC),
   'AC3: exit code 5 (reserved for read-verb "not found") is never emitted by set-title '
 . '(' . scalar(@ALL_SET_TITLE_RC) . ' set-title invocations checked)');

done_testing();
