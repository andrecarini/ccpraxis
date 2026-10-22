package Almanac::ClaudeMdBlock;
# Almanac::ClaudeMdBlock -- a pure text-transform module that renders the note
# directory as a fenced, hashed block for CLAUDE.md, and detects hand-edits /
# git conflicts against a previously-generated block. Blueprint
# almanac-records, package 06-claude-md-block. See
# specs/06-claude-md-block-spec.md for the full contract; this file
# implements it and adds nothing beyond it.
#
# This module never discovers notes and never opens a store (S1.1). The only
# filesystem contact anywhere in this file is the read/write inside
# apply_file() / remove_block_file() (S2.9). Every other function is a pure
# transform over already-read text and records.
use strict;
use warnings;
use Digest::SHA ();
use Encode ();
use Almanac::Store ();   # for Almanac::Store::Error only -- no store method is ever called here.

our $VERSION = '1.0';

# =============================================================================
# 2.2 -- the markers (constants, exported as functions).
# =============================================================================
sub BEGIN_MARKER         { return '<!-- BEGIN GENERATED ALMANAC NOTES -- DO NOT EDIT BY HAND -->' }
sub END_MARKER            { return '<!-- END GENERATED ALMANAC NOTES -->' }
sub HASH_PREFIX            { return '<!-- almanac-notes-sha256: ' }
sub HASH_SUFFIX            { return ' -->' }
sub COVERS_BYTE_BUDGET     { return 200 }
sub TRUNCATION_MARKER      { return ' [truncated]' }

my $BEGIN_RE = qr/\A\Q<!-- BEGIN GENERATED ALMANAC NOTES -- DO NOT EDIT BY HAND -->\E\r?\z/;
my $END_RE   = qr/\A\Q<!-- END GENERATED ALMANAC NOTES -->\E\r?\z/;
my $HASH_RE  = qr/\A\Q<!-- almanac-notes-sha256: \E([0-9a-f]{64})\Q -->\E\r?\z/;

# Conflict-marker lines (S2.5), full-line, anchored at column 0, exactly
# seven characters (never eight).
my $OURS_RE   = qr/\A<{7}(?!<)(?:[ \t].*)?\r?\z/;
my $BASE_RE   = qr/\A\|{7}(?!\|)(?:[ \t].*)?\r?\z/;
my $SEP_RE    = qr/\A={7}(?!=)\r?\z/;
my $THEIRS_RE = qr/\A>{7}(?!>)(?:[ \t].*)?\r?\z/;

# =============================================================================
# small helpers
# =============================================================================
sub _die { die Almanac::Store::Error->new(@_) }

sub _trim {
    my ($s) = @_;
    return $s unless defined $s;
    my $t = $s;
    $t =~ s/\A\s+//;
    $t =~ s/\s+\z//;
    return $t;
}

# _sanitize($v) -- S2.3's three-step transform, applied to title/target/covers
# before rendering. Control chars (incl. \n \r \t) become a single space,
# runs of spaces collapse, leading/trailing space is trimmed.
sub _sanitize {
    my ($v) = @_;
    return undef unless defined $v;
    my $s = $v;
    $s =~ s/[\x00-\x1f\x7f]/ /g;
    $s =~ s/ {2,}/ /g;
    $s =~ s/\A +//;
    $s =~ s/ +\z//;
    return $s;
}

# _neutralize_structural($v) -- fix-batch MEDIUM-7: title/target cannot forge
# entry structure. Backticks and "**" are the two markers the entry-line
# shape (S2.4) relies on to delimit the title/target fields, and " -- " is
# the field separator itself; neutralising all three in title/target closes
# the in-line forgery the red-team report demonstrated, without touching
# column 0 (already unreachable per the sanitize step above).
sub _neutralize_structural {
    my ($v) = @_;
    return $v unless defined $v;
    my $s = $v;
    $s =~ s/`/'/g;
    $s =~ s/\*\*/*/g;
    $s =~ s/ -- / - /g;
    return $s;
}

# _neutralize_imports($v) -- todo 20261002-005241-39730000. The rendered
# block lands in ~/.claude/almanac-notes.md, which ~/.claude/CLAUDE.md
# @-imports, and Claude Code follows @path imports recursively from inside an
# imported file ("Imported files can recursively import other files, with a
# maximum depth of four hops", code.claude.com/docs/en/memory). Title and
# covers text reaches that file with no human review, so an "@~/.ssh/x" in a
# note's covers would be pulled into every session's context. The same page:
# "Import parsing skips Markdown code spans" -- so each @token outside an
# existing code span is wrapped in one, keeping the text readable and inert.
# An "@" glued to a preceding word character (user@example.com) is no import
# and is left alone.
sub _neutralize_imports {
    my ($v) = @_;
    return $v unless defined $v && index($v, '@') >= 0;
    my $out = '';
    # Alternate: an existing code span (kept verbatim), or plain text up to
    # the next backtick. An unmatched backtick run becomes "'" (as
    # _neutralize_structural does for title/target): left in place it could
    # pair with a span added here and re-expose the token between them.
    while (length $v) {
        if ($v =~ s/\A((`+)[^`].*?(?<!`)\2(?!`))//s) {
            $out .= $1;   # a complete code span: already inert
        } elsif ($v =~ s/\A(`+)//) {
            $out .= "'" x length($1);
        } else {
            $v =~ s/\A([^`]+)//;
            (my $text = $1) =~ s/(?<![A-Za-z0-9._%+\-])(\@[^\s`]+)/`$1`/g;
            $out .= $text;
        }
    }
    return $out;
}

# _hash_payload($payload) -- sha256_hex of the payload's UTF-8 bytes. When
# $payload is a raw byte string (Encode::is_utf8 false -- e.g. read directly
# off disk by apply_file/remove_block_file, fix-batch C-1/HIGH-2), it is
# already the exact UTF-8 octets that were (or will be) written, so hashing
# it directly reproduces the same digest without a decode/encode round trip
# that would risk mangling bytes outside the block. When $payload is an
# in-memory Perl string carrying real Unicode codepoints (Encode::is_utf8
# true -- e.g. built by render_block from note fields, or passed in by an
# apply_text caller), it is encoded first, exactly as before.
sub _hash_payload {
    my ($payload) = @_;
    my $bytes = Encode::is_utf8($payload) ? Encode::encode('UTF-8', $payload) : $payload;
    return Digest::SHA::sha256_hex($bytes);
}

# =============================================================================
# 2.6 -- covers truncation (rulings 1 and 2).
# =============================================================================
sub _resolve_budget {
    my ($b) = @_;
    return COVERS_BYTE_BUDGET() unless defined $b;
    _die(kind => 'usage', detail => 'bad_budget')
        unless $b =~ /\A[0-9]+\z/ && $b >= 16;
    return $b + 0;
}

sub _truncate_covers {
    my ($covers, $budget) = @_;
    my $marker = TRUNCATION_MARKER();
    my $oct = Encode::encode('UTF-8', $covers);
    return $covers if length($oct) <= $budget;

    my $keep = $budget - length($marker);
    my $cut  = substr($oct, 0, $keep);

    # (a) never split a UTF-8 character.
    while (length($cut) && (ord(substr($oct, length($cut), 1)) & 0xC0) == 0x80) {
        $cut = substr($cut, 0, length($cut) - 1);
    }
    my $acut = $cut;

    # (b) never split mid-word, yielding to (a) when the whole cut is one word.
    if (length($cut) && substr($oct, length($cut), 1) !~ /\A[ \t]\z/) {
        $cut =~ s/[^ \t]+\z//;
    }

    # (c) no trailing blank.
    $cut =~ s/[ \t]+\z//;

    if (length($cut)) {
        return Encode::decode('UTF-8', $cut) . $marker;
    }
    if (length($acut)) {
        return Encode::decode('UTF-8', $acut) . $marker;
    }
    return substr($marker, 1);   # the marker with its leading space stripped
}

# =============================================================================
# 2.3 -- records in: validation, sorting, sanitisation.
# =============================================================================
sub _prepare_notes {
    my ($notes) = @_;
    _die(kind => 'usage', detail => 'notes_required') unless ref($notes) eq 'ARRAY';
    _die(kind => 'refused', path => undef, detail => 'no_notes') unless @$notes;

    my @out;
    for my $rec (@$notes) {
        _die(kind => 'usage', detail => 'bad_note_record') unless ref($rec) eq 'HASH';

        my $id;
        if (defined $rec->{id} && length(_trim($rec->{id}))) {
            $id = _trim($rec->{id});
        } elsif (ref($rec->{fields}) eq 'HASH' && defined $rec->{fields}{id} && length(_trim($rec->{fields}{id}))) {
            $id = _trim($rec->{fields}{id});
        } else {
            _die(kind => 'usage', detail => 'missing_field');
        }

        _die(kind => 'usage', detail => 'bad_note_record') unless ref($rec->{fields}) eq 'HASH';
        my $f = $rec->{fields};

        my $title = _sanitize($f->{title});
        _die(kind => 'usage', detail => 'missing_field') unless defined $title && length $title;

        my $target = _sanitize($f->{target});
        _die(kind => 'usage', detail => 'missing_field') unless defined $target && length $target;

        my $audience = (defined $f->{audience} && ($f->{audience} eq 'internal' || $f->{audience} eq 'external'))
                     ? $f->{audience} : '-';

        my $covers = _sanitize($f->{covers});

        push @out, { __id => $id, title => $title, audience => $audience, target => $target, covers => $covers };
    }

    my %seen;
    for my $e (@out) {
        _die(kind => 'usage', detail => 'duplicate_id') if $seen{ $e->{__id} }++;
    }

    @out = sort { $a->{__id} cmp $b->{__id} } @out;
    return @out;
}

# =============================================================================
# 2.4 -- render_block: exact bytes, and the hash.
# =============================================================================
sub render_block {
    my (%opt) = @_;
    my $budget = _resolve_budget($opt{covers_budget});
    my @sorted = _prepare_notes($opt{notes});

    my $payload = "\n" . "## Almanac notes -- the directory\n" . "\n"
                . "Generated from the almanac note store. Edit the note, never this block.\n" . "\n";
    for my $e (@sorted) {
        # MEDIUM-6: title/target get the same byte-budget discipline as
        # covers, so a pathologically long field cannot break DC3's growth
        # bound (block size ~ note count, not note content length).
        # MEDIUM-7: neutralise before truncating, so the fields that could
        # forge entry structure never reach render, at any length.
        # Import neutralising runs AFTER truncation: a cut through a code
        # span it had added would leave an unclosed backtick, and the @token
        # behind it live again. (The target is already inside a code span.)
        my $title  = _neutralize_imports(_truncate_covers(_neutralize_structural($e->{title}), $budget));
        my $target = _truncate_covers(_neutralize_structural($e->{target}), $budget);
        my $covers_disp = (defined $e->{covers} && length $e->{covers})
                         ? _neutralize_imports(_truncate_covers($e->{covers}, $budget))
                         : '-';
        $payload .= "- **$title** ($e->{audience}) -- `$target`\n  $covers_disp\n";
    }

    my $hex  = _hash_payload($payload);
    my $line = HASH_PREFIX() . $hex . HASH_SUFFIX();
    return BEGIN_MARKER() . "\n" . $line . "\n" . $payload . END_MARKER() . "\n";
}

# =============================================================================
# 2.5 -- inspect(): the one place detection order lives.
# =============================================================================
sub inspect {
    my ($text) = @_;
    _die(kind => 'usage', detail => 'text_required') unless defined $text;

    my @lines = split /\n/, $text, -1;
    my @offsets;
    my $pos = 0;
    for my $i (0 .. $#lines) {
        push @offsets, $pos;
        $pos += length($lines[$i]);
        $pos += 1 if $i < $#lines;
    }

    my (@b, @e, @c);
    for my $i (0 .. $#lines) {
        my $l = $lines[$i];
        push @b, $i if $l =~ $BEGIN_RE;
        push @e, $i if $l =~ $END_RE;
        push @c, $i if $l =~ $OURS_RE || $l =~ $BASE_RE || $l =~ $SEP_RE || $l =~ $THEIRS_RE;
    }

    my $present    = @b ? 1 : 0;
    my $begin_line = @b ? $b[0]  : undef;
    my $end_line   = @e ? $e[-1] : undef;

    my ($start, $end);
    if ($present) {
        $start = $offsets[ $b[0] ];
        if (@e) {
            my $el = $e[-1];
            $end = $offsets[$el] + length($lines[$el]) + ($el < $#lines ? 1 : 0);
        } else {
            $end = length($text);
        }
    }

    my %state = (
        present         => $present,
        begin_count     => scalar(@b),
        end_count       => scalar(@e),
        begin_line      => $begin_line,
        end_line        => $end_line,
        start           => $start,
        end             => $end,
        stored_hash     => undef,
        computed_hash   => undef,
        payload         => undef,
        conflict_lines  => [ @c ],
    );

    # Rules 1/2: no markers at all.
    if (@b == 0 && @e == 0) {
        $state{state} = @c ? 'conflict_markers_outside_block' : 'absent';
        return \%state;
    }

    # Rules 3-7: exactly one well-formed BEGIN/END pair, correctly ordered.
    if (@b == 1 && @e == 1 && $b[0] < $e[0]) {
        my ($b0, $e0) = ($b[0], $e[0]);
        my @outside = grep { $_ < $b0 || $_ > $e0 } @c;
        my @inside  = grep { $_ > $b0 && $_ < $e0 } @c;

        if (@outside) {
            $state{state} = 'conflict_markers_outside_block';
            return \%state;
        }
        if (@inside) {
            $state{state} = 'conflict_markers';
            return \%state;
        }

        my $hash_idx = $b0 + 1;
        unless ($hash_idx <= $e0 && $lines[$hash_idx] =~ $HASH_RE) {
            $state{state} = 'hash_line_missing';
            return \%state;
        }
        my $stored_hash = $1;

        my $payload_start_line = $b0 + 2;
        my $payload = ($payload_start_line <= $e0)
                    ? substr($text, $offsets[$payload_start_line], $offsets[$e0] - $offsets[$payload_start_line])
                    : '';
        (my $norm_payload = $payload) =~ s/\r\n/\n/g;
        my $computed_hash = _hash_payload($norm_payload);

        $state{stored_hash}   = $stored_hash;
        $state{computed_hash} = $computed_hash;
        $state{payload}       = $payload;

        $state{state} = ($stored_hash eq $computed_hash) ? 'clean' : 'hand_edited';
        return \%state;
    }

    # Rules 8/9: marker structure otherwise broken.
    $state{state} = @c ? 'conflict_markers' : 'markers_malformed';
    return \%state;
}

# =============================================================================
# 2.8 -- reason() table.
# =============================================================================
my %REASON = (
    no_notes => 'No note records were supplied, so the block was left exactly as it is. '
              . 'A store that is missing or unreadable is not an empty directory; regenerate '
              . 'once the notes can be read.',
    hand_edited => 'The generated block was edited by hand. This block is generated from the '
                 . 'note records, so the edit belongs in a note: change the note, remove the '
                 . 'block, and regenerate it.',
    hash_line_missing => 'The generated block carries no integrity line, so a hand-edit cannot '
                        . 'be ruled out. Remove the block and regenerate it.',
    conflict_markers => 'The generated block contains git conflict markers, so this file is '
                       . 'mid-merge. Do not resolve them by hand: remove the block and regenerate '
                       . 'it from the note records.',
    conflict_markers_outside_block => 'This file contains git conflict markers outside the '
                                     . 'generated block. Finish the merge first; regenerating now '
                                     . 'would write into a half-merged file.',
    markers_malformed => "The generated block's markers are not a single BEGIN/END pair, so it "
                        . 'cannot be regenerated automatically. If the BEGIN marker is missing, '
                        . 'delete the stray END line by hand; otherwise remove the block and '
                        . 'regenerate it.',
);

sub reason {
    my ($detail) = @_;
    return undef unless defined $detail;
    return $REASON{$detail};
}

# =============================================================================
# 2.9 -- apply_text, remove_block, apply_file, remove_block_file.
# =============================================================================
sub apply_text {
    my (%opt) = @_;
    _die(kind => 'usage', detail => 'text_required') unless defined $opt{text};
    my $text = $opt{text};

    my $insp  = inspect($text);
    my $state = $insp->{state};
    if ($state ne 'absent' && $state ne 'clean') {
        _die(kind => 'refused', path => undef, detail => $state);
    }

    my $block = render_block(notes => $opt{notes}, covers_budget => $opt{covers_budget});

    if ($state eq 'clean') {
        return substr($text, 0, $insp->{start}) . $block . substr($text, $insp->{end});
    }

    my $t = $text;
    $t .= "\n" if length($t) && $t !~ /\n\z/;
    return length($t) ? ($t . "\n" . $block) : $block;
}

sub remove_block {
    my ($text) = @_;
    my $insp = inspect($text);
    unless ($insp->{present}) {
        return ($text, undef);
    }

    # H-2 / HIGH-1 / MEDIUM-3: a BEGIN with no well-formed END -- the END
    # line missing entirely, or the last END line sitting before the first
    # BEGIN line (a merge outcome) -- has no span per S2.9 ("first BEGIN
    # line to the last END line"). Refuse rather than inventing a span that
    # either runs to end-of-file (deleting host prose after the block) or
    # duplicates the text between end() and start() (an END-before-BEGIN
    # ordering). The well-formed cases (including a merge-duplicated block
    # with an END at or after the first BEGIN, AC-27) are unaffected.
    unless (defined $insp->{end_line} && $insp->{end_line} > $insp->{begin_line}) {
        _die(kind => 'refused', path => undef, detail => 'markers_malformed');
    }

    my $new_text = substr($text, 0, $insp->{start}) . substr($text, $insp->{end});
    my $removed  = substr($text, $insp->{start}, $insp->{end} - $insp->{start});

    if ($insp->{end} == length($text) && $new_text =~ /\n\n\z/) {
        $new_text = substr($new_text, 0, length($new_text) - 1);
    }

    return ($new_text, $removed);
}

sub _read_file {
    my ($path) = @_;
    return '' unless -e $path;
    open(my $fh, '<:raw', $path) or _die(kind => 'io', path => $path, errno => "$!");
    local $/;
    my $bytes = <$fh>;
    close($fh) or _die(kind => 'io', path => $path, errno => "$!");
    return defined($bytes) ? $bytes : '';
}

# MEDIUM-5 / N-2 / LOW-9: a fresh, unpredictable temp name per call (instead
# of the previous fixed "$path.almanac-tmp") so two concurrent syncs, or a
# pre-placed file at the old fixed name, do not collide; a short syswrite is
# looped rather than treated as fatal; the original file's mode is copied
# onto the replacement before the rename. This module's import allowlist
# (S2.0/AC-37) has no room for Fcntl, so true O_CREAT|O_EXCL exclusivity and
# an explicit fsync are not available here -- the random name is the
# mitigation this write set can reach; see the fix-batch report for the
# escalation this leaves open. This module never deletes a file (S2.0): a
# mid-write failure leaves the temp file in place rather than removing it,
# matching the file's pre-existing behaviour.
sub _write_file_atomic {
    my ($path, $bytes) = @_;

    my @st   = stat($path);
    my $mode = @st ? ($st[2] & 07777) : undef;

    my ($tmp, $fh);
    for (my $attempt = 0; $attempt < 64 && !defined($fh); $attempt++) {
        my $candidate = sprintf('%s.almanac-tmp-%d-%d-%d', $path, $$, time(), int(rand(1_000_000_000)));
        if (open(my $h, '>:raw', $candidate)) {
            ($fh, $tmp) = ($h, $candidate);
        }
    }
    _die(kind => 'io', path => $path, errno => "$!") unless defined $fh;

    my $want = length($bytes);
    my $off  = 0;
    while ($off < $want) {
        my $n = syswrite($fh, $bytes, $want - $off, $off);
        unless (defined $n) {
            my $errno = "$!";
            close($fh);
            _die(kind => 'io', path => $path, errno => $errno);
        }
        $off += $n;
    }
    unless (close($fh)) {
        _die(kind => 'io', path => $path, errno => "$!");
    }

    chmod($mode, $tmp) if defined $mode;

    unless (rename($tmp, $path)) {
        my $errno = "$!";
        _die(kind => 'io', path => $path, errno => $errno);
    }
    return 1;
}

# _reraise_with_path($err, $path) -- H-1 / LOW-8: Almanac::Store::Error
# freezes its prose line and machine block into {message} at construction
# (Store.pm), so mutating $err->{path} afterwards changes nothing that is
# ever printed. Re-raise a freshly constructed error carrying the real
# path instead.
sub _reraise_with_path {
    my ($err, $path) = @_;
    if (ref($err) && ref($err) =~ /::Error$/) {
        my %fields = %$err;
        delete $fields{message};
        delete $fields{exit_code};
        $fields{path} = $path;
        die Almanac::Store::Error->new(%fields);
    }
    die $err;
}

# apply_file(%opt) -- C-1 / HIGH-2: the host file's bytes outside the
# marker span are never decoded or re-encoded. inspect()'s marker/hash/
# conflict-line patterns are all pure ASCII and line-splitting is on "\n"
# (0x0A, which UTF-8 never embeds inside a multi-byte sequence), so
# inspect() can run directly against the raw bytes -- no full-file decode
# is needed to find the span. Only the freshly generated block (which can
# contain real Unicode from note fields) is encoded, and only that encoded
# span is spliced in; every byte before start() and after end() is an
# untouched substr() of the bytes read from disk.
sub apply_file {
    my (%opt) = @_;
    _die(kind => 'usage', detail => 'path_required') unless defined $opt{path} && length $opt{path};
    my $path = $opt{path};

    my $result = eval {
        my $bytes = _read_file($path);
        my $insp  = inspect($bytes);
        my $state = $insp->{state};
        if ($state ne 'absent' && $state ne 'clean') {
            _die(kind => 'refused', path => $path, detail => $state);
        }

        my $block       = render_block(notes => $opt{notes}, covers_budget => $opt{covers_budget});
        my $block_bytes = Encode::encode('UTF-8', $block);

        my $new_bytes;
        if ($state eq 'clean') {
            $new_bytes = substr($bytes, 0, $insp->{start}) . $block_bytes . substr($bytes, $insp->{end});
        } else {
            my $t = $bytes;
            $t .= "\n" if length($t) && $t !~ /\n\z/;
            $new_bytes = length($t) ? ($t . "\n" . $block_bytes) : $block_bytes;
        }

        # M-1: a no-op regeneration writes nothing, even on a CRLF working
        # tree -- compare after \r\n -> \n normalisation (the same
        # normalisation inspect() hashes against) rather than byte-exact,
        # so a checkout that re-normalises line endings does not make every
        # sync report changed => 1.
        (my $norm_old = $bytes)     =~ s/\r\n/\n/g;
        (my $norm_new = $new_bytes) =~ s/\r\n/\n/g;
        if ($norm_new eq $norm_old) {
            return { path => $path, state => $state, changed => 0, bytes => length($bytes) };
        }

        _write_file_atomic($path, $new_bytes);
        return { path => $path, state => $state, changed => 1, bytes => length($new_bytes) };
    };
    _reraise_with_path($@, $path) if $@;
    return $result;
}

# remove_block_file(%opt) -- C-1 / HIGH-2: works entirely in raw bytes.
# remove_block() only locates markers (ASCII, "\n"-anchored) and slices the
# text; it never needs to decode a single byte, so nothing outside (or
# even inside) the removed span is ever touched by an encode/decode round
# trip.
sub remove_block_file {
    my (%opt) = @_;
    _die(kind => 'usage', detail => 'path_required') unless defined $opt{path} && length $opt{path};
    my $path = $opt{path};

    my $result = eval {
        my $bytes = _read_file($path);
        my ($new_bytes, $removed) = remove_block($bytes);

        if ($new_bytes eq $bytes) {
            return { path => $path, changed => 0, removed => $removed };
        }

        _write_file_atomic($path, $new_bytes);
        return { path => $path, changed => 1, removed => $removed };
    };
    _reraise_with_path($@, $path) if $@;
    return $result;
}

1;
