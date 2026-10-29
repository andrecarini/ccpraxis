#!/usr/bin/env perl
# platform: any
# Immutable oracle for the core generator surface of Almanac::ClaudeMdBlock
# (blueprint almanac-records, package 06-claude-md-block): render_block,
# apply_text, remove_block, the byte-budget truncation algorithm, the
# sha256 integrity hash, sort order and duplicate-id refusal, empty-notes
# refusal, content-outside-markers preservation, byte-identical no-op
# regeneration, and non-ASCII note content. The conflict-vs-hand-edit
# detection ladder has its own oracle: almanac-claude-md-conflicts.t. See
# specs/06-claude-md-block-spec.md -- AC numbers in test names refer to
# that file's section 4 table.
#
# HOUSE PATTERN for a not-yet-built module: every call into
# Almanac::ClaudeMdBlock is wrapped in eval{} so "Undefined subroutine" /
# "Can't locate" is a caught, reported failure for THIS assertion rather
# than an abort of the whole file -- every assertion below is expected to
# fail for exactly that reason right now, not for a fixture defect of this
# file's own making.
#
# This module is a PURE text transform (spec S1.2/S2.0): it is never given
# a real store, so every fixture here is either a hand-built record hashref
# or a File::Temp::tempdir(CLEANUP => 1). No real CLAUDE.md is ever opened
# for writing -- see the AC-39 tripwire at top and bottom of this file.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path ();
use Digest::SHA qw(sha256_hex);
use Encode ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
use lib "$Bin/../../scripts";

my $MOD_PM = "$S/Almanac/ClaudeMdBlock.pm";

# ---------------------------------------------------------------------------
# AC-39 tripwire (house rule): snapshot the repo's OWN CLAUDE.md before this
# file does anything, and again at the very end. Read-only -- this file
# never constructs a WRITE path into it. Every other CLAUDE.md-shaped path
# used below is rooted at a tempdir variable ($D).
# ---------------------------------------------------------------------------
sub slurp_raw {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

(my $REPO = "$Bin/../../../..") =~ s{\\}{/}g;
my $REAL_CLAUDE_MD = "$REPO/CLAUDE.md";  # TRIPWIRE-READ, never written
my $before_bytes = slurp_raw($REAL_CLAUDE_MD);  # TRIPWIRE-READ
ok(defined $before_bytes && length($before_bytes) > 0,
   'sanity: repo CLAUDE.md is readable before this file runs')
    or diag("could not read $REAL_CLAUDE_MD");
my $before_len  = defined($before_bytes) ? length($before_bytes)      : undef;
my $before_hash = defined($before_bytes) ? sha256_hex($before_bytes)  : undef;

# ---------------------------------------------------------------------------
# module presence / load
# ---------------------------------------------------------------------------
ok(-f $MOD_PM, 'Almanac::ClaudeMdBlock module file exists at plugins/almanac/scripts/Almanac/ClaudeMdBlock.pm')
    or diag('Almanac/ClaudeMdBlock.pm is not present yet -- every assertion below is '
          . 'expected to fail for exactly that reason, not any other.');

my $LOAD_ERR;
eval { require Almanac::ClaudeMdBlock; 1 } or do { $LOAD_ERR = $@ };
ok(!defined $LOAD_ERR, 'Almanac::ClaudeMdBlock requires cleanly')
    or diag("load error: $LOAD_ERR");

# ---------------------------------------------------------------------------
# scaffolding
# ---------------------------------------------------------------------------

# call_scalar($sub, @args) -> ($result, $err) -- scalar-context call, caught.
sub call_scalar {
    my ($sub, @args) = @_;
    no strict 'refs';
    my $r = eval { &{"Almanac::ClaudeMdBlock::$sub"}(@args) };
    return ($r, $@);
}

# call_list($sub, @args) -> (\@results, $err) -- list-context call, caught.
sub call_list {
    my ($sub, @args) = @_;
    no strict 'refs';
    my @r = eval { &{"Almanac::ClaudeMdBlock::$sub"}(@args) };
    return (\@r, $@);
}

sub err_kind   { my ($e) = @_; return (ref($e) && ref($e) =~ /::Error$/) ? $e->{kind}   : undef }
sub err_detail { my ($e) = @_; return (ref($e) && ref($e) =~ /::Error$/) ? $e->{detail} : undef }
sub err_path   { my ($e) = @_; return (ref($e) && ref($e) =~ /::Error$/) ? $e->{path}   : undef }
sub err_errno  { my ($e) = @_; return (ref($e) && ref($e) =~ /::Error$/) ? $e->{errno}  : undef }

# machine_block_field($message, $key) -- the spec S2.8 grammar, never prose.
sub machine_block_field {
    my ($msg, $key) = @_;
    return undef unless defined $msg;
    return $1 if "$msg" =~ /^\s{2}\Q$key\E:\s(\S+)$/m;
    return undef;
}

# is_real_eq($got, $expected, $name) -- like is(), but a plain is($a,$b)
# with both sides undef would PASS on a module that does not exist yet
# (the is(undef,undef) vacuous-pass class of bug named in this task's
# self-audit instruction). Used for every "byte-identical" / round-trip
# assertion where $got is itself the product of a call under test.
sub is_real_eq {
    my ($got, $expected, $name) = @_;
    if (!defined $got) {
        fail("$name (call returned undef -- module missing/incomplete, not a fixture bug)");
        return;
    }
    is($got, $expected, $name);
}

sub mk_rec {
    my (%o) = @_;
    my %fields;
    $fields{title}    = $o{title}    if exists $o{title};
    $fields{audience} = $o{audience} if exists $o{audience};
    $fields{target}   = $o{target}   if exists $o{target};
    $fields{covers}   = $o{covers}   if exists $o{covers};
    $fields{created}  = $o{created}  // '2026-01-01T00:00:00Z';
    $fields{id}       = $o{fields_id} if exists $o{fields_id};
    my %rec = (
        path => $o{path} // '/fake/path.md',
        rev  => $o{rev}  // 1,
        rank => $o{rank} // 1,
        fields => \%fields,
        body => $o{body},
    );
    $rec{id} = $o{id} if exists $o{id};
    return \%rec;
}

# ---------------------------------------------------------------------------
# constants pinned by the spec (S2.2, S2.6) -- hardcoded independently of
# the module under test, since these literals are the contract, not an
# echo of whatever the module happens to return.
# ---------------------------------------------------------------------------
my $BEGIN_MARKER  = '<!-- BEGIN GENERATED ALMANAC NOTES -- DO NOT EDIT BY HAND -->';
my $END_MARKER    = '<!-- END GENERATED ALMANAC NOTES -->';
my $HASH_PREFIX   = '<!-- almanac-notes-sha256: ';
my $HASH_SUFFIX   = ' -->';
my $COVERS_BUDGET = 200;
my $TRUNC_MARKER  = ' [truncated]';
my @ALL_DETAIL_TOKENS = qw(no_notes hand_edited hash_line_missing conflict_markers
                            conflict_markers_outside_block markers_malformed);

# build_payload(@entries) -> $payload -- the spec S2.4 formula, built
# independently of the module (ground truth for AC-4/AC-5 fixtures).
sub build_payload {
    my (@entries) = @_;
    my $body = "\n" . "## Almanac notes -- the directory\n" . "\n"
             . "Generated from the almanac note store. Edit the note, never this block.\n" . "\n";
    for my $e (@entries) {
        my ($title, $audience, $target, $covers) = @$e;
        $covers = '-' unless defined $covers && length $covers;
        $body .= "- **$title** ($audience) -- `$target`\n  $covers\n";
    }
    return $body;
}
sub build_block {
    my (@entries) = @_;
    my $payload = build_payload(@entries);
    my $hex = sha256_hex(Encode::encode('UTF-8', $payload));
    return "$BEGIN_MARKER\n$HASH_PREFIX$hex$HASH_SUFFIX\n$payload$END_MARKER\n";
}

# fixture note pair, ids reversed in array order -- exercises AC-2's sort.
my @N2 = (
    mk_rec(id => '20260101-000000-aaaa0002', title => 'Second note', audience => 'internal',
           target => 'notes/second.md', covers => 'covers the second thing'),
    mk_rec(id => '20260101-000000-aaaa0001', title => 'First note', audience => 'external',
           target => 'notes/first.md', covers => 'covers the first thing'),
);

# =============================================================================
# MR / AC-36 -- module shape: no output on require, all symbols defined,
# $VERSION.
# =============================================================================
{
    my $cmd = qq{perl -I "$S" -e "require Almanac::ClaudeMdBlock;" 2>&1};
    my $out = `$cmd`;
    my $rc  = $? >> 8;
    is($out, '', 'AC-36: require-ing the module produces no output on STDOUT or STDERR');
    is($rc, 0, 'AC-36: require-ing the module does not exit non-zero');

    for my $sub (qw(render_block apply_text remove_block inspect apply_file
                     remove_block_file reason BEGIN_MARKER END_MARKER
                     COVERS_BYTE_BUDGET TRUNCATION_MARKER)) {
        ok(Almanac::ClaudeMdBlock->can($sub), "AC-36: Almanac::ClaudeMdBlock defines $sub");
    }
    is($Almanac::ClaudeMdBlock::VERSION, '1.0', 'AC-36: $VERSION is exactly \'1.0\'');
}

# =============================================================================
# AC-37 -- grep: import allowlist and forbidden literals (S2.0).
# =============================================================================
{
    if (-f $MOD_PM) {
        open my $fh, '<', $MOD_PM or die "cannot open $MOD_PM: $!";
        my @lines = <$fh>;
        close $fh;
        my $src = join('', @lines);

        my @uses = grep { /^\s*(use|require)\s+/ } @lines;
        my @allowed = (
            qr/^\s*use\s+strict\b/, qr/^\s*use\s+warnings\b/,
            qr/^\s*use\s+Digest::SHA\b/, qr/^\s*use\s+Encode\b/,
            qr/^\s*use\s+Almanac::Store\b/,
        );
        my @bad_imports = grep { my $l = $_; !grep { $l =~ $_ } @allowed } @uses;
        unless (ok(@bad_imports == 0, 'AC-37: imports confined to strict/warnings/Digest::SHA/Encode/Almanac::Store')) {
            diag($_) for @bad_imports;
        }

        my @forbidden_calls;
        my @forbidden_literals = ('->open(', '->list(', '->read(', '->create(', '->update(', '->delete(',
                                   'opendir', 'readdir', 'unlink', 'mkdir');
        for my $pat (@forbidden_literals) {
            push @forbidden_calls, $pat if index($src, $pat) >= 0;
        }
        ok(@forbidden_calls == 0, 'AC-37: no Store method literals, no opendir/readdir/unlink/mkdir')
            or diag("found: @forbidden_calls");

        my @bad_lines;
        for my $i (0 .. $#lines) {
            my $l = $lines[$i];
            next if $l =~ /^\s*#/;
            push @bad_lines, "$MOD_PM:" . ($i + 1) . ": $l" if $l =~ /\bexit\s*\(|\bexit\s+\d/;
            push @bad_lines, "$MOD_PM:" . ($i + 1) . ": $l" if $l =~ /\bprint\b|\bprintf\b|\bwarn\s*(\(|["'])/;
        }
        unless (ok(@bad_lines == 0, 'AC-37: no exit/print/printf/warn')) { diag($_) for @bad_lines }

        ok(index($src, 'Almanac::Lock') < 0, 'AC-37: Almanac::Lock is not named');
        for my $lit (qw(/run/.containerenv /.dockerenv ALMANAC_SURFACE)) {
            ok(index($src, $lit) < 0, "AC-37: literal '$lit' does not appear");
        }
    } else {
        fail("AC-37: $_") for ('import allowlist', 'no forbidden Store/filesystem calls',
                                'no exit/print/printf/warn', 'no Almanac::Lock',
                                'no container-detection literals');
    }
}

# =============================================================================
# AC-38 -- perl -c sanity (checks: line), included here for parity.
# =============================================================================
{
    my $cmd = qq{perl -I "$S" -c "$MOD_PM" 2>&1};
    my $out = `$cmd`;
    my $rc  = $? >> 8;
    is($rc, 0, 'AC-38: perl -c ClaudeMdBlock.pm succeeds with -I plugins/almanac/scripts and no other -I')
        or diag("output: $out");
}

# =============================================================================
# AC-1 -- render_block shape.
# =============================================================================
{
    my ($block, $err) = call_scalar('render_block', notes => \@N2);
    ok(defined $block, 'AC-1: render_block(notes => \@N2) returns a string') or diag("error: $err");
    if (defined $block) {
        my @lines = split /\n/, $block, -1;
        pop @lines if @lines && $lines[-1] eq '';
        is($lines[0], $BEGIN_MARKER, 'AC-1: first line is BEGIN_MARKER()');
        like($lines[1], qr/\A<!-- almanac-notes-sha256: [0-9a-f]{64} -->\z/, 'AC-1: second line matches the hash-line regex');
        is($lines[-1], $END_MARKER, 'AC-1: last line is END_MARKER()');
        is(substr($block, -1), "\n", 'AC-1: block ends with exactly one trailing newline');
        ok(substr($block, 0, -1) !~ /\n\z/, 'AC-1: not two trailing newlines');
        ok(index($block, "\r") < 0, 'AC-1: block contains no \r');
    } else {
        fail('AC-1: first line is BEGIN_MARKER()');
        fail('AC-1: second line matches the hash-line regex');
        fail('AC-1: last line is END_MARKER()');
        fail('AC-1: block ends with exactly one trailing newline');
        fail('AC-1: block contains no \r');
    }
}

# =============================================================================
# AC-2 -- sort order is inside the module; array order does not matter.
# =============================================================================
{
    my ($b1, $err1) = call_scalar('render_block', notes => [ @N2 ]);
    my ($b2, $err2) = call_scalar('render_block', notes => [ reverse @N2 ]);
    is_real_eq($b1, $b2, 'AC-2: render_block is byte-identical regardless of caller array order') if defined $b1;
    fail('AC-2: render_block is byte-identical regardless of caller array order (first call failed)') unless defined $b1;
    if (defined $b1) {
        # Spec S6 (out of scope) forbids rendering a note's id -- so the
        # order check must key on a field the module actually renders.
        # 'First note' carries id ...aaaa0001, 'Second note' carries
        # ...aaaa0002; ASCII-ascending id sort puts 0001 before 0002
        # regardless of caller array order (that's the property under test).
        my $i1 = index($b1, 'First note');
        my $i2 = index($b1, 'Second note');
        ok($i1 >= 0 && $i2 >= 0 && $i1 < $i2, 'AC-2: id-0001 entry (First note) appears before id-0002 entry (Second note)');
    } else {
        fail('AC-2: id-0001 entry (First note) appears before id-0002 entry (Second note)');
    }
}

# =============================================================================
# AC-3 -- payload line count and per-line shape.
# =============================================================================
for my $n (1, 2, 5) {
    my @notes = map {
        mk_rec(id => sprintf('20260101-000000-bbbb%04d', $_), title => "Note $_",
               audience => 'internal', target => "notes/n$_.md", covers => "covers $_")
    } (1 .. $n);
    my ($block, $err) = call_scalar('render_block', notes => \@notes);
    if (defined $block) {
        my @lines = split /\n/, $block, -1;
        pop @lines if @lines && $lines[-1] eq '';
        my @payload_lines = @lines[2 .. $#lines - 1];
        is(scalar(@payload_lines), 5 + 2 * $n, "AC-3: payload has 5 + 2*$n lines for N=$n");
        my @entry_lines = @payload_lines[5 .. $#payload_lines];
        my $ok_shape = 1;
        for (my $i = 0; $i < @entry_lines; $i += 2) {
            $ok_shape = 0 unless $entry_lines[$i]   =~ /\A- \*\*.+\*\* \((internal|external|-)\) -- `.+`\z/;
            $ok_shape = 0 unless $entry_lines[$i+1] =~ /\A  .+\z/;
        }
        ok($ok_shape, "AC-3: each entry occupies exactly two lines matching the entry-line shape (N=$n)");
    } else {
        fail("AC-3: payload has 5 + 2*$n lines for N=$n (render_block failed: $err)");
        fail("AC-3: each entry occupies exactly two lines matching the entry-line shape (N=$n)");
    }
}

# =============================================================================
# AC-4 -- hash formula sanity on a checked-in fixture the module never wrote
# (the fresh-clone case): ground truth for AC-5's mutation tests.
# =============================================================================
my @AC4_ENTRIES = (['A title', 'internal', 'notes/x.md', 'what it covers']);
my $AC4_BLOCK = build_block(@AC4_ENTRIES);
{
    my ($stored_hex) = $AC4_BLOCK =~ /\A<!-- BEGIN[^\n]*\n<!-- almanac-notes-sha256: ([0-9a-f]{64}) -->\n/;
    ok(defined $stored_hex, 'AC-4 fixture sanity: the hash-checked-in fixture has a well-formed hash line');
    my ($payload) = $AC4_BLOCK =~ /\A.*?\n.*?\n(.*)\Q$END_MARKER\E\n\z/s;
    ok(defined $payload, 'AC-4 fixture sanity: the payload span is extractable');
    if (defined $stored_hex && defined $payload) {
        is(sha256_hex(Encode::encode('UTF-8', $payload)), $stored_hex,
           'AC-4: sha256_hex of the payload equals the hex captured from the hash line');
    } else {
        fail('AC-4: sha256_hex of the payload equals the hex captured from the hash line');
    }
}

# =============================================================================
# AC-5 -- the hash does not cover the markers; mutation changes the verdict.
# =============================================================================
{
    my ($state_clean) = call_scalar('inspect', $AC4_BLOCK);
    is(ref($state_clean) eq 'HASH' ? $state_clean->{state} : undef, 'clean',
       'AC-5: mutating nothing leaves inspect() reporting clean (stored_hash eq computed_hash)');

    (my $mutated_begin = $AC4_BLOCK) =~ s/\Q$BEGIN_MARKER\E\n/$BEGIN_MARKER   \n/;
    my ($state_begin) = call_scalar('inspect', $mutated_begin);
    # NOT a bare isnt(undef, 'clean') -- that would pass vacuously while
    # inspect() is simply missing. Require a real state value first, so this
    # assertion fails for the right reason until inspect() actually exists.
    if (ref($state_begin) eq 'HASH' && defined $state_begin->{state}) {
        isnt($state_begin->{state}, 'clean',
             'AC-5: trailing spaces on the BEGIN marker line change inspect()\'s verdict away from clean');
    } else {
        fail('AC-5: trailing spaces on the BEGIN marker line change inspect()\'s verdict away from clean (inspect() unavailable)');
    }

    my $fake_hex = ('0' x 63) . '1';
    (my $mutated_hash = $AC4_BLOCK) =~ s/almanac-notes-sha256: [0-9a-f]{64} -->/almanac-notes-sha256: $fake_hex -->/;
    my ($state_hash) = call_scalar('inspect', $mutated_hash);
    is(ref($state_hash) eq 'HASH' ? $state_hash->{state} : undef, 'hand_edited',
       'AC-5: replacing the hash line with a different valid-looking hash reports hand_edited');
}

# =============================================================================
# AC-6 -- apply_text is idempotent on its own output.
# =============================================================================
for my $T ('', "A\n", "# Title\n\nprose\n") {
    my ($first, $err1) = call_scalar('apply_text', text => $T, notes => \@N2);
    if (!defined $first) {
        fail("AC-6: apply_text applied twice returns byte-identical output (T=" . length($T) . " bytes) [$err1]");
        next;
    }
    my ($second, $err2) = call_scalar('apply_text', text => $first, notes => \@N2);
    is_real_eq($second, $first, "AC-6: apply_text applied twice returns byte-identical output (T=" . length($T) . " bytes)");
}

# =============================================================================
# AC-7 -- apply_file no-op: second call changed=>0, bytes identical, mtime
# unchanged (proves no write occurred).
# =============================================================================
{
    my $D = tempdir(CLEANUP => 1);
    $D =~ s{\\}{/}g;
    my $path = "$D/CLAUDE.md";

    my ($r1, $err1) = call_scalar('apply_file', path => $path, notes => \@N2);
    ok(defined $r1 && ref($r1) eq 'HASH' && $r1->{changed} == 1, 'AC-7: first apply_file returns changed => 1')
        or diag("error: $err1");

    my $bytes1 = -f $path ? slurp_raw($path) : undef;
    my @st1 = -f $path ? stat($path) : ();
    my $mtime1 = @st1 ? $st1[9] : undef;

    my ($r2, $err2) = call_scalar('apply_file', path => $path, notes => \@N2);
    ok(defined $r2 && ref($r2) eq 'HASH' && $r2->{changed} == 0, 'AC-7: second identical apply_file returns changed => 0')
        or diag("error: $err2");

    my $bytes2 = -f $path ? slurp_raw($path) : undef;
    my @st2 = -f $path ? stat($path) : ();
    my $mtime2 = @st2 ? $st2[9] : undef;

    is_real_eq($bytes2, $bytes1, 'AC-7: the file\'s bytes are identical across both calls') if defined $bytes1;
    fail('AC-7: the file\'s bytes are identical across both calls') unless defined $bytes1;
    if (defined $mtime1 && defined $mtime2) {
        is($mtime2, $mtime1, 'AC-7: the file\'s mtime is unchanged by the no-op second call');
    } else {
        fail('AC-7: the file\'s mtime is unchanged by the no-op second call');
    }
}

# =============================================================================
# AC-8 -- content outside the markers is never touched (prose both sides).
# =============================================================================
{
    my ($block0, $errb) = call_scalar('render_block', notes => \@N2);
    my $before_prose = "before\n\nprose\n";
    my $after_prose  = "\nafter\n\nmore\n";
    my $fixture = defined($block0) ? ($before_prose . $block0 . $after_prose) : undef;

    my $changed_notes = [
        mk_rec(id => '20260101-000000-aaaa0002', title => 'Second note CHANGED', audience => 'internal',
               target => 'notes/second.md', covers => 'covers the second thing'),
        mk_rec(id => '20260101-000000-aaaa0001', title => 'First note', audience => 'external',
               target => 'notes/first.md', covers => 'covers the first thing'),
    ];

    if (defined $fixture) {
        my ($insp) = call_scalar('inspect', $fixture);
        if (ref($insp) eq 'HASH' && defined $insp->{start} && defined $insp->{end}) {
            my ($new, $err) = call_scalar('apply_text', text => $fixture, notes => $changed_notes);
            if (defined $new) {
                is_real_eq(substr($new, 0, $insp->{start}), substr($fixture, 0, $insp->{start}),
                           'AC-8: every byte before the block\'s start is unchanged');
                my $orig_tail = substr($fixture, $insp->{end});
                my $tail_len  = length($orig_tail);
                is_real_eq(substr($new, -$tail_len), $orig_tail,
                           'AC-8: every byte after the (old) block\'s end is unchanged');
            } else {
                fail('AC-8: every byte before the block\'s start is unchanged');
                fail('AC-8: every byte after the (old) block\'s end is unchanged');
            }
        } else {
            fail('AC-8: every byte before the block\'s start is unchanged (inspect() unavailable)');
            fail('AC-8: every byte after the (old) block\'s end is unchanged (inspect() unavailable)');
        }
    } else {
        fail('AC-8: every byte before the block\'s start is unchanged (render_block unavailable)');
        fail('AC-8: every byte after the (old) block\'s end is unchanged (render_block unavailable)');
    }
}

# =============================================================================
# AC-9 -- covers truncation at 199/200/201 ASCII bytes.
# =============================================================================
{
    for my $len (199, 200) {
        my $covers = 'x' x $len;
        my $rec = mk_rec(id => '20260101-000000-cccc0001', title => 'T', audience => 'internal',
                          target => 'notes/t.md', covers => $covers);
        my ($block, $err) = call_scalar('render_block', notes => [$rec]);
        if (defined $block) {
            ok(index($block, "$covers\n") >= 0, "AC-9: covers of $len ASCII bytes renders verbatim");
            ok(index($block, $TRUNC_MARKER) < 0, "AC-9: covers of $len ASCII bytes has no [truncated] marker");
        } else {
            fail("AC-9: covers of $len ASCII bytes renders verbatim ($err)");
            fail("AC-9: covers of $len ASCII bytes has no [truncated] marker");
        }
    }

    # 201 bytes, word boundary exactly at the keep point (keep = 200-12 = 188):
    # 188 'a's, a space at byte index 188, then 12 more 'b's (201 total).
    my $covers201 = ('a' x 188) . ' ' . ('b' x 12);
    is(length($covers201), 201, 'AC-9 fixture sanity: covers201 is 201 bytes');
    my $rec = mk_rec(id => '20260101-000000-cccc0002', title => 'T', audience => 'internal',
                      target => 'notes/t.md', covers => $covers201);
    my ($block, $err) = call_scalar('render_block', notes => [$rec]);
    if (defined $block) {
        my ($rendered) = $block =~ /\n  (.+)\n\Q$END_MARKER\E\n\z/;
        ok(defined $rendered, 'AC-9: the truncated covers line is extractable from the block');
        if (defined $rendered) {
            ok(length(Encode::encode('UTF-8', $rendered)) <= 200, 'AC-9: 201-byte covers renders <= 200 UTF-8 bytes');
            like($rendered, qr/\Q$TRUNC_MARKER\E\z/, 'AC-9: 201-byte covers ends with the truncation marker');
            my ($prefix) = $rendered =~ /\A(.*)\Q$TRUNC_MARKER\E\z/;
            ok(defined $prefix && $prefix =~ /\S\z/, 'AC-9: text before the marker has no trailing space');
            is($prefix, 'a' x 188, 'AC-9: text before the marker is the 188-byte prefix ending at the word boundary');
        } else {
            fail('AC-9: 201-byte covers renders <= 200 UTF-8 bytes');
            fail('AC-9: 201-byte covers ends with the truncation marker');
            fail('AC-9: text before the marker has no trailing space');
            fail('AC-9: text before the marker is the 188-byte prefix ending at the word boundary');
        }
    } else {
        fail("AC-9: the truncated covers line is extractable from the block ($err)");
    }
}

# =============================================================================
# AC-10 -- multi-byte character never split; single overlong word split at a
# character boundary.
# =============================================================================
{
    # (a) a 3-byte char (em dash, U+2014) straddling the natural cut point.
    my $emdash = "\x{2014}";
    my $covers = ('a' x 198) . $emdash . (' padding text after the character here');
    my $rec = mk_rec(id => '20260101-000000-dddd0001', title => 'T', audience => 'internal',
                      target => 'notes/t.md', covers => $covers);
    my ($block, $err) = call_scalar('render_block', notes => [$rec]);
    if (defined $block) {
        my ($rendered) = $block =~ /\n  (.+)\n\Q$END_MARKER\E\n\z/;
        ok(defined $rendered, 'AC-10: straddled covers line is extractable');
        if (defined $rendered) {
            my $decoded = eval { Encode::decode('UTF-8', Encode::encode('UTF-8', $rendered), Encode::FB_CROAK()) };
            ok(defined $decoded, 'AC-10: straddled-character result survives an FB_CROAK UTF-8 round trip');
            ok(index($rendered, "\x{FFFD}") < 0, 'AC-10: straddled-character result contains no U+FFFD');
        } else {
            fail('AC-10: straddled-character result survives an FB_CROAK UTF-8 round trip');
            fail('AC-10: straddled-character result contains no U+FFFD');
        }
    } else {
        fail("AC-10: straddled covers line is extractable ($err)");
    }

    # (b) one 400-byte word made entirely of a 3-byte character -- forces the
    # character-boundary split of step (a) since step (b) cannot find a space.
    my $one_word = $emdash x 134;  # 402 bytes, no spaces anywhere
    my $rec2 = mk_rec(id => '20260101-000000-dddd0002', title => 'T', audience => 'internal',
                       target => 'notes/t.md', covers => $one_word);
    my ($block2, $err2) = call_scalar('render_block', notes => [$rec2]);
    if (defined $block2) {
        my ($rendered2) = $block2 =~ /\n  (.+)\n\Q$END_MARKER\E\n\z/;
        if (defined $rendered2) {
            ok(length(Encode::encode('UTF-8', $rendered2)) <= 200, 'AC-10: one 400-byte multi-byte word renders <= 200 UTF-8 bytes');
            my $decoded2 = eval { Encode::decode('UTF-8', Encode::encode('UTF-8', $rendered2), Encode::FB_CROAK()) };
            ok(defined $decoded2, 'AC-10: one 400-byte multi-byte word survives an FB_CROAK UTF-8 round trip');
        } else {
            fail('AC-10: one 400-byte multi-byte word renders <= 200 UTF-8 bytes');
            fail('AC-10: one 400-byte multi-byte word survives an FB_CROAK UTF-8 round trip');
        }
    } else {
        fail("AC-10: one 400-byte multi-byte word case ($err2)");
    }
}

# =============================================================================
# AC-11 -- constants and bad_budget refusal.
# =============================================================================
{
    my ($budget, $eb) = call_scalar('COVERS_BYTE_BUDGET');
    is($budget, 200, 'AC-11: COVERS_BYTE_BUDGET() is 200');
    my ($marker, $em) = call_scalar('TRUNCATION_MARKER');
    is($marker, ' [truncated]', 'AC-11: TRUNCATION_MARKER() is \' [truncated]\'');

    for my $bad (15, 'x') {
        my (undef, $err) = call_scalar('render_block', notes => \@N2, covers_budget => $bad);
        is(err_kind($err), 'usage', "AC-11: covers_budget => '$bad' dies kind usage");
        is(err_detail($err), 'bad_budget', "AC-11: covers_budget => '$bad' dies detail bad_budget");
    }
}

# =============================================================================
# AC-12 -- block growth is linear in note count with a fixed per-note delta.
# =============================================================================
{
    my %len_by_n;
    for my $n (1, 2, 10) {
        my @notes = map {
            mk_rec(id => sprintf('20260101-000000-eeee%04d', $_), title => 'Same title',
                   audience => 'internal', target => 'notes/same.md', covers => ('c' x 5000))
        } (1 .. $n);
        my ($block, $err) = call_scalar('render_block', notes => \@notes);
        $len_by_n{$n} = defined($block) ? length($block) : undef;
        ok(defined($block) && length($block) <= 600 + $n * 400,
           "AC-12: N=$n block does not exceed 600 + N*400 bytes")
            or diag(defined($block) ? ('length=' . length($block)) : "render_block failed: $err");
    }
    if (defined $len_by_n{1} && defined $len_by_n{2} && defined $len_by_n{10}) {
        my $delta_1_2  = $len_by_n{2} - $len_by_n{1};
        my $delta_avg  = ($len_by_n{10} - $len_by_n{2}) / 8;
        is($delta_avg, $delta_1_2, 'AC-12: the per-note byte delta is identical between N=1->2 and N=2->10');
    } else {
        fail('AC-12: the per-note byte delta is identical between N=1->2 and N=2->10');
    }
}

# =============================================================================
# AC-13 -- a hand-edited block is refused; nothing is written; no temp file.
# =============================================================================
{
    (my $hand_edited = $AC4_BLOCK) =~ s/what it covers/what it covers, edited by hand/;

    my (undef, $err1) = call_scalar('apply_text', text => $hand_edited, notes => \@N2);
    is(err_kind($err1), 'refused', 'AC-13: apply_text on a hand-edited block dies kind refused');
    is(err_detail($err1), 'hand_edited', 'AC-13: apply_text on a hand-edited block dies detail hand_edited');

    my $D = tempdir(CLEANUP => 1);
    $D =~ s{\\}{/}g;
    my $path = "$D/CLAUDE.md";
    open my $fh, '>:raw', $path or die "cannot write fixture: $!";
    print {$fh} Encode::encode('UTF-8', $hand_edited);
    close $fh;
    my $before = slurp_raw($path);

    my (undef, $err2) = call_scalar('apply_file', path => $path, notes => \@N2);
    is(err_kind($err2), 'refused', 'AC-13: apply_file on a hand-edited block dies kind refused');
    is(err_detail($err2), 'hand_edited', 'AC-13: apply_file on a hand-edited block dies detail hand_edited');

    my $after = slurp_raw($path);
    is_real_eq($after, $before, 'AC-13: apply_file leaves the file\'s bytes byte-identical on refusal');

    opendir(my $dh, $D) or die "cannot opendir $D: $!";
    my @tmp = grep { /\.almanac-tmp\z/ } readdir($dh);
    closedir $dh;
    is(scalar(@tmp), 0, 'AC-13: apply_file leaves no *.almanac-tmp file in the directory');
}

# =============================================================================
# AC-14 -- reason() table.
# =============================================================================
{
    my ($sentence, $err) = call_scalar('reason', 'hand_edited');
    is($sentence,
       'The generated block was edited by hand. This block is generated from the note records, so the edit belongs in a note: change the note, remove the block, and regenerate it.',
       'AC-14: reason(\'hand_edited\') returns exactly the S2.8 sentence');

    for my $tok (@ALL_DETAIL_TOKENS) {
        my ($s) = call_scalar('reason', $tok);
        ok(defined($s) && length($s), "AC-14: reason('$tok') is a defined non-empty string");
    }
    my ($unknown) = call_scalar('reason', 'nope');
    is($unknown, undef, "AC-14: reason('nope') is undef for an unknown token");
}

# =============================================================================
# AC-15 -- restoration from a hand-edited block is byte-identical to the
# block generated from the same records, reconstructed via the public API
# alone (never hand-assembled by this test).
# =============================================================================
{
    my ($original, $eo) = call_scalar('render_block', notes => \@N2);
    if (defined $original) {
        (my $edited = $original) =~ s/(covers the first thing)/$1, edited by hand/;
        ok($edited ne $original, 'AC-15 fixture sanity: the edited block differs from the original');

        my ($removed, $er) = call_list('remove_block', $edited);
        my ($new_text, undef) = @{ $removed || [] };
        ok(defined $new_text, 'AC-15: remove_block on a hand-edited block succeeds') or diag("error: $er");

        if (defined $new_text) {
            my ($restored, $ea) = call_scalar('apply_text', text => $new_text, notes => \@N2);
            # Assert generically via inspect()+substr rather than hardcoding
            # the placement-rule separator, since $new_text's shape (empty,
            # or with trailing prose) is not pinned by this test.
            my ($insp) = call_scalar('inspect', $restored);
            if (defined $restored && ref($insp) eq 'HASH' && defined $insp->{start} && defined $insp->{end}) {
                is_real_eq(substr($restored, $insp->{start}, $insp->{end} - $insp->{start}), $original,
                           'AC-15: the restored block is byte-identical to the block generated before the edit');
            } else {
                fail('AC-15: the restored block is byte-identical to the block generated before the edit');
            }
        } else {
            fail('AC-15: the restored block is byte-identical to the block generated before the edit');
        }
    } else {
        fail("AC-15: render_block fixture unavailable ($eo)");
    }
}

# =============================================================================
# AC-16 -- remove_block(apply_text(...)) round-trips; markerless text is
# unchanged; remove_block_file leaves the file byte-identical.
# =============================================================================
for my $T ('', "A\n", "A\n\nB\n", "# H\n\npara\n") {
    my ($applied, $ea) = call_scalar('apply_text', text => $T, notes => \@N2);
    if (defined $applied) {
        my ($rr, $er) = call_list('remove_block', $applied);
        my ($new_text) = @{ $rr || [] };
        is_real_eq($new_text, $T, "AC-16: remove_block(apply_text(T)) restores T byte-identically (T=" . length($T) . " bytes)");
    } else {
        fail("AC-16: remove_block(apply_text(T)) restores T byte-identically (T=" . length($T) . " bytes) [$ea]");
    }
}
{
    my $markerless = "just some prose\nwith no block\n";
    my ($rr, $er) = call_list('remove_block', $markerless);
    my ($new_text, $removed) = @{ $rr || [] };
    is_real_eq($new_text, $markerless, 'AC-16: remove_block on markerless text returns the text unchanged');
    is($removed, undef, 'AC-16: remove_block on markerless text returns undef as the removed span');

    my $D = tempdir(CLEANUP => 1);
    $D =~ s{\\}{/}g;
    my $path = "$D/CLAUDE.md";
    open my $fh, '>:raw', $path or die "cannot write fixture: $!";
    print {$fh} "before\n";
    close $fh;
    my $pre_apply = slurp_raw($path);
    my ($ra, $eaf) = call_scalar('apply_file', path => $path, notes => \@N2);
    my ($rf, $erf) = call_scalar('remove_block_file', path => $path);
    my $post_remove = -f $path ? slurp_raw($path) : undef;
    is_real_eq($post_remove, $pre_apply, 'AC-16: remove_block_file leaves the file byte-identical to its pre-apply_file state');
}

# =============================================================================
# AC-17 -- notes => [] refuses (no_notes); apply_file against a populated
# block leaves the file untouched.
# =============================================================================
{
    my (undef, $e1) = call_scalar('render_block', notes => []);
    is(err_kind($e1), 'refused', 'AC-17: render_block(notes => []) dies kind refused');
    is(err_detail($e1), 'no_notes', 'AC-17: render_block(notes => []) dies detail no_notes');

    my (undef, $e2) = call_scalar('apply_text', text => '', notes => []);
    is(err_kind($e2), 'refused', 'AC-17: apply_text(notes => []) dies kind refused');
    is(err_detail($e2), 'no_notes', 'AC-17: apply_text(notes => []) dies detail no_notes');

    my $D = tempdir(CLEANUP => 1);
    $D =~ s{\\}{/}g;
    my $path = "$D/CLAUDE.md";
    call_scalar('apply_file', path => $path, notes => \@N2);
    my $before_bytes2 = -f $path ? slurp_raw($path) : undef;

    my (undef, $e3) = call_scalar('apply_file', path => $path, notes => []);
    is(err_kind($e3), 'refused', 'AC-17: apply_file(notes => []) against a populated block dies kind refused');
    is(err_detail($e3), 'no_notes', 'AC-17: apply_file(notes => []) against a populated block dies detail no_notes');

    my $after_bytes2 = -f $path ? slurp_raw($path) : undef;
    is_real_eq($after_bytes2, $before_bytes2, 'AC-17: apply_file leaves the file byte-identical after the no_notes refusal');

    my ($insp) = call_scalar('inspect', defined($after_bytes2) ? Encode::decode('UTF-8', $after_bytes2) : undef);
    is(ref($insp) eq 'HASH' ? $insp->{state} : undef, 'clean', 'AC-17: the block still inspects as clean after the refusal');

    opendir(my $dh, $D) or die "cannot opendir $D: $!";
    my @tmp = grep { /\.almanac-tmp\z/ } readdir($dh);
    closedir $dh;
    is(scalar(@tmp), 0, 'AC-17: the directory contains no temp file after the refusal');
}

# =============================================================================
# AC-18 -- notes absent/undef/non-arrayref dies usage/notes_required,
# distinct from no_notes.
# =============================================================================
{
    my (undef, $e1) = call_scalar('render_block');
    is(err_kind($e1), 'usage', 'AC-18: notes absent dies kind usage');
    is(err_detail($e1), 'notes_required', 'AC-18: notes absent dies detail notes_required');

    for my $bad (undef, {}, 'x') {
        my (undef, $e) = call_scalar('render_block', notes => $bad);
        my $label = !defined($bad) ? 'undef' : (ref($bad) eq 'HASH' ? '{}' : "'$bad'");
        is(err_kind($e), 'usage', "AC-18: notes => $label dies kind usage");
        is(err_detail($e), 'notes_required', "AC-18: notes => $label dies detail notes_required");
    }
}

# =============================================================================
# AC-19 -- per-record validation refusals.
# =============================================================================
{
    my $no_title = mk_rec(id => 'x1', audience => 'internal', target => 'notes/x.md');
    my (undef, $e1) = call_scalar('render_block', notes => [$no_title]);
    is(err_kind($e1), 'usage', 'AC-19: record with no title dies kind usage');
    is(err_detail($e1), 'missing_field', 'AC-19: record with no title dies detail missing_field');

    my $no_target = mk_rec(id => 'x2', title => 'T', audience => 'internal');
    my (undef, $e2) = call_scalar('render_block', notes => [$no_target]);
    is(err_kind($e2), 'usage', 'AC-19: record with no target dies kind usage');
    is(err_detail($e2), 'missing_field', 'AC-19: record with no target dies detail missing_field');

    my $bad_fields = { id => 'x3', fields => 'not a hashref' };
    my (undef, $e3) = call_scalar('render_block', notes => [$bad_fields]);
    is(err_kind($e3), 'usage', 'AC-19: record whose fields is not a hashref dies kind usage');
    is(err_detail($e3), 'bad_note_record', 'AC-19: record whose fields is not a hashref dies detail bad_note_record');

    my $no_id = { fields => { title => 'T', audience => 'internal', target => 'notes/x.md' } };
    my (undef, $e4) = call_scalar('render_block', notes => [$no_id]);
    is(err_kind($e4), 'usage', 'AC-19: record with no id anywhere dies kind usage');
    is(err_detail($e4), 'missing_field', 'AC-19: record with no id anywhere dies detail missing_field');

    my $dup1 = mk_rec(id => 'dup', title => 'T1', audience => 'internal', target => 'notes/a.md');
    my $dup2 = mk_rec(id => 'dup', title => 'T2', audience => 'internal', target => 'notes/b.md');
    my (undef, $e5) = call_scalar('render_block', notes => [$dup1, $dup2]);
    is(err_kind($e5), 'usage', 'AC-19: two records sharing an id die kind usage');
    is(err_detail($e5), 'duplicate_id', 'AC-19: two records sharing an id die detail duplicate_id');
}

# =============================================================================
# AC-20 -- bogus/absent audience renders '-'; missing covers renders '  -'.
# =============================================================================
{
    my $sideways = mk_rec(id => 'y1', title => 'T', audience => 'sideways', target => 'notes/y1.md');
    my ($b1, $e1) = call_scalar('render_block', notes => [$sideways]);
    ok(defined $b1, 'AC-20: bogus audience does not die') or diag("error: $e1");
    like($b1, qr/\(-\)/, 'AC-20: bogus audience renders as (-)') if defined $b1;

    my $noaud = mk_rec(id => 'y2', title => 'T', target => 'notes/y2.md');
    my ($b2, $e2) = call_scalar('render_block', notes => [$noaud]);
    ok(defined $b2, 'AC-20: absent audience does not die') or diag("error: $e2");
    like($b2, qr/\(-\)/, 'AC-20: absent audience renders as (-)') if defined $b2;

    my $nocov = mk_rec(id => 'y3', title => 'T', audience => 'internal', target => 'notes/y3.md');
    my ($b3, $e3) = call_scalar('render_block', notes => [$nocov]);
    ok(defined $b3, 'AC-20: no covers does not die') or diag("error: $e3");
    like($b3, qr/\n  -\n/, 'AC-20: record with no covers renders its second line as exactly "  -"') if defined $b3;
}

# =============================================================================
# AC-21 -- non-ASCII round-trip through apply_file, including a non-ASCII
# tempdir component.
# =============================================================================
{
    my $D = tempdir(CLEANUP => 1);
    $D =~ s{\\}{/}g;
    my $rec = mk_rec(id => 'z1', title => "Andr\x{e9} \x{2014} the note", audience => 'internal',
                      target => 'notes/z1.md', covers => "Andr\x{e9}'s notes \x{2014} covers this");
    my $path = "$D/CLAUDE.md";
    my ($r, $err) = call_scalar('apply_file', path => $path, notes => [$rec]);
    ok(defined $r, 'AC-21: apply_file with non-ASCII note content succeeds') or diag("error: $err");
    if (defined $r) {
        my $bytes = slurp_raw($path);
        ok(index($bytes, "Ã©") < 0, 'AC-21: the file\'s raw bytes contain no mojibake (no "Ã©")');
        ok(index($bytes, Encode::encode('UTF-8', "\x{e9}")) >= 0, 'AC-21: the file\'s raw bytes contain the correct 2-byte UTF-8 sequence for e-acute');
        my $decoded = Encode::decode('UTF-8', $bytes);
        my ($insp) = call_scalar('inspect', $decoded);
        is(ref($insp) eq 'HASH' ? $insp->{state} : undef, 'clean', 'AC-21: re-read and inspected, the block is clean');
    } else {
        fail('AC-21: the file\'s raw bytes contain no mojibake (no "Ã©")');
        fail('AC-21: the file\'s raw bytes contain the correct 2-byte UTF-8 sequence for e-acute');
        fail('AC-21: re-read and inspected, the block is clean');
    }

    # non-ASCII tempdir component
    my $ND = "$D/Andr\x{e9}";
    # The directory is created from $ND's UTF-8 bytes below, but $ND itself
    # holds e-acute as the single byte 0xE9, and that byte form is what
    # apply_file hands the filesystem. APFS (macOS) only has the UTF-8 name,
    # so on darwin $ND is utf8::upgrade'd: same characters, UTF-8 bytes on
    # the way to the filesystem, as a real macOS path would arrive.
    utf8::upgrade($ND) if $^O eq 'darwin';
    my $ok_mkdir = eval { File::Path::make_path(Encode::encode('UTF-8', $ND)); 1 };
    SKIP: {
        skip('could not create a non-ASCII directory on this filesystem', 3) unless $ok_mkdir && -d Encode::encode('UTF-8', $ND);
        my $path2 = "$ND/CLAUDE.md";
        my ($r2, $err2) = call_scalar('apply_file', path => $path2, notes => [$rec]);
        ok(defined $r2, 'AC-21: apply_file succeeds when the directory itself has a non-ASCII component') or diag("error: $err2");
        if (defined $r2) {
            my $bytes2 = slurp_raw(Encode::encode('UTF-8', $path2));
            ok(defined($bytes2) && index($bytes2, "Ã©") < 0, 'AC-21: non-ASCII-dir case: no mojibake in the file');
            my $decoded2 = defined($bytes2) ? Encode::decode('UTF-8', $bytes2) : undef;
            my ($insp2) = defined($decoded2) ? call_scalar('inspect', $decoded2) : (undef);
            is(ref($insp2) eq 'HASH' ? $insp2->{state} : undef, 'clean', 'AC-21: non-ASCII-dir case: re-read and inspected, the block is clean');
        } else {
            fail('AC-21: non-ASCII-dir case: no mojibake in the file');
            fail('AC-21: non-ASCII-dir case: re-read and inspected, the block is clean');
        }
    }
}

# =============================================================================
# AC-23 -- covers containing \n, \r, \t, NUL renders as one line.
# =============================================================================
{
    my $dirty = "line one\nline two\rline three\tline four\x00end";
    my $rec = mk_rec(id => 'w1', title => 'T', audience => 'internal', target => 'notes/w1.md', covers => $dirty);
    my ($block, $err) = call_scalar('render_block', notes => [$rec]);
    ok(defined $block, 'AC-23: covers with control chars does not die') or diag("error: $err");
    if (defined $block) {
        my @lines = split /\n/, $block, -1;
        pop @lines if @lines && $lines[-1] eq '';
        is(scalar(@lines) - 3, 5 + 2 * 1, 'AC-23: payload line count is still 5 + 2*N with control chars sanitised away');
        ok(index($block, "\r") < 0, 'AC-23: no \r survives into the block');
        ok(index($block, "\x00") < 0, 'AC-23: no NUL survives into the block');
        like($block, qr/line one line two line three line four end/, 'AC-23: control chars each became a single space');
    } else {
        fail('AC-23: payload line count is still 5 + 2*N with control chars sanitised away');
        fail('AC-23: no \r survives into the block');
        fail('AC-23: no NUL survives into the block');
        fail('AC-23: control chars each became a single space');
    }
}

# =============================================================================
# AC-35 -- apply_file on a nonexistent path creates it; a missing parent dies
# io.
# =============================================================================
{
    my $D = tempdir(CLEANUP => 1);
    $D =~ s{\\}{/}g;
    my $path = "$D/CLAUDE.md";
    ok(!-f $path, 'AC-35 fixture sanity: the path does not exist yet');
    my ($r, $err) = call_scalar('apply_file', path => $path, notes => \@N2);
    ok(defined $r && ref($r) eq 'HASH' && $r->{changed} == 1, 'AC-35: apply_file on a nonexistent path returns changed => 1')
        or diag("error: $err");
    ok(-f $path, 'AC-35: apply_file on a nonexistent path creates the file');

    my $missing_parent = "$D/does/not/exist/CLAUDE.md";
    my (undef, $err2) = call_scalar('apply_file', path => $missing_parent, notes => \@N2);
    is(err_kind($err2), 'io', 'AC-35: apply_file with a missing parent directory dies kind io');
    ok(defined(err_path($err2)), 'AC-35: the io error carries a path');
    ok(defined(err_errno($err2)), 'AC-35: the io error carries an errno');
    ok(!-f $missing_parent, 'AC-35: nothing is created when the parent directory is missing');
}

# =============================================================================
# AC-39 tripwire (part 2): structural self-grep and unchanged-CLAUDE.md check.
# =============================================================================
{
    open my $fh, '<', $0 or die "cannot reopen self: $!";
    my @lines = <$fh>;
    close $fh;
    my @bad;
    for my $i (0 .. $#lines) {
        my $l = $lines[$i];
        next unless $l =~ /CLAUDE\.md/;
        next if $l =~ /TRIPWIRE-READ/;      # the one sanctioned read-only reference
        next if $l =~ /^\s*#/;              # prose comments
        next if $l =~ /AC-39|sanity:/;      # this check's own/adjacent prose (Test::More descriptions)
        next if $l =~ /\$D2?\/CLAUDE\.md|\$ND\/CLAUDE\.md|\$D\/does\/not\/exist\/CLAUDE\.md/;  # tempdir-rooted
        push @bad, "$0:" . ($i + 1) . ": $l";
    }
    unless (ok(@bad == 0, 'AC-39: every CLAUDE.md reference in this file is tempdir-rooted or the sanctioned read-only tripwire')) {
        diag($_) for @bad;
    }

    my $after_bytes = slurp_raw($REAL_CLAUDE_MD);  # TRIPWIRE-READ
    is(defined($after_bytes) ? length($after_bytes) : undef, $before_len,
       'AC-39: the repo\'s own CLAUDE.md byte length is unchanged after this file ran');
    is(defined($after_bytes) ? sha256_hex($after_bytes) : undef, $before_hash,
       'AC-39: the repo\'s own CLAUDE.md sha256 is unchanged after this file ran');
}

# =============================================================================
# Fix-batch regressions (driver edit, 2026-09-23; the ruling is in this
# package's ledger). Each pins a defect review or red-team reproduced: bytes
# outside the block survive undecoded (C-1); remove_block refuses a missing
# or reversed END marker instead of deleting or duplicating prose (HIGH-1,
# MEDIUM-3); title and target are bounded (MEDIUM-6) and cannot forge entry
# structure (MEDIUM-7).
# =============================================================================
{
    my $D = tempdir(CLEANUP => 1);
    $D =~ s{\\}{/}g;
    my $path  = "$D/CLAUDE.md";
    my $prose = "caf\xE9 latin1 prose\n";            # not valid UTF-8
    open my $w, '>:raw', $path or die "write $path: $!";
    print $w $prose;
    close $w;
    my ($r, $err) = call_scalar('apply_file', path => $path, notes => \@N2);
    ok(ref($r) eq 'HASH', 'regression C-1: apply_file accepts a host file that is not valid UTF-8') or diag("error: $err");
    my $after = slurp_raw($path) // '';
    is(index($after, $prose), 0, 'regression C-1: non-UTF-8 prose before the block survives byte-for-byte');
}
{
    my ($block, $err0) = call_scalar('render_block', notes => \@N2);
    ok(defined $block, 'regression HIGH-1 fixture: render_block') or diag("error: $err0");
    (my $no_end = $block // '') =~ s/^\Q$END_MARKER\E\n//m;
    my (undef, $err1) = call_list('remove_block', "before\n${no_end}AFTER PROSE\n");
    is(err_detail($err1), 'markers_malformed', 'regression HIGH-1: remove_block with no END marker refuses instead of deleting to end of file');

    (my $body = $block // '') =~ s/^\Q$END_MARKER\E\n//m;
    my (undef, $err2) = call_list('remove_block', "$END_MARKER\nPROSE-X\n$body");
    is(err_detail($err2), 'markers_malformed', 'regression MEDIUM-3: remove_block with END before BEGIN refuses instead of duplicating prose');
}
{
    my @long = (mk_rec(id => '20260101-000000-aaaa0009', title => ('t' x 20000),
                       audience => 'internal', target => ('g' x 10000), covers => 'c'));
    my ($block, $err) = call_scalar('render_block', notes => \@long);
    ok(defined $block, 'regression MEDIUM-6 fixture: render_block with a huge title and target') or diag("error: $err");
    cmp_ok(length($block // ''), '<=', 600 + 400, 'regression MEDIUM-6: one note still renders within 600 + N*400 bytes');

    my @forge = (mk_rec(id => '20260101-000000-aaaa0010', title => 'x -- `secrets.md` - **Fake** (external)',
                        audience => 'internal', target => 'a.md', covers => 'c'));
    my ($fb, $ferr) = call_scalar('render_block', notes => \@forge);
    ok(defined $fb, 'regression MEDIUM-7 fixture: render_block with a structure-forging title') or diag("error: $ferr");
    unlike($fb // '', qr/`secrets\.md`/, 'regression MEDIUM-7: a title cannot introduce a backticked target');
    unlike($fb // '', qr/\*\*Fake\*\*/, 'regression MEDIUM-7: a title cannot introduce a bold entry title');
}

done_testing();
