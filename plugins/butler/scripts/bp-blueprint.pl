#!/usr/bin/env perl
# bp-blueprint.pl — the deterministic blueprint.md write/read API (b43-blueprint-write-api).
#
# Six typed, surgical write ops (add-package, set-status, set-deps, add-decision,
# set-decision, set-field) plus five read ops (show, deps, status, decisions, ready) over the
# package-status table `bp-orchestrator.pl`'s BpOrch::parse_dag reads. See:
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b43-blueprint-write-api-spec.md
#
# WHY THIS EXISTS: every hand-splice of blueprint.md to date has been correct by luck,
# never by construction (spec preamble). This API makes "correct by construction" the
# only path: atomic temp+rename under flock, refuse-rather-than-guess validation, and
# the SAME parser (BpOrch::parse_dag) the orchestrator reads with -- never a second,
# drifting implementation (spec §2.3, the b12/b13 lesson).
#
# :raw ONLY, throughout. NEVER add an :encoding(UTF-8) layer -- the file carries
# Andr\x{e9}-class paths and multi-byte status glyphs as raw bytes; decoding them and
# re-encoding on write would corrupt the byte-identical round trip (spec G11 / landmine 2).
#
# Exit codes (not part of the oracle's contract, but kept consistent with bp-ledger.pl's
# shape): 0 success, 2 validation refusal (byte-identical file), 3 usage/argument error
# (nothing read), 4 I/O/lock/atomicity failure (byte-identical), 5 target not found.
#
# Core Perl only: strict, warnings, Getopt::Long, Fcntl(:flock), File::Basename. The two
# REAL parsers/validators (BpOrch::parse_dag / BpOrch::resolve_dep_token, both living in
# bp-orchestrator.pl) are `require`d, never reimplemented (spec §2.3).
use strict;
use warnings;
use Getopt::Long qw(GetOptionsFromArray);
use Fcntl qw(:flock);
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# abs_path, NOT bare dirname(__FILE__): invoked as `perl plugins/butler/scripts/bp-blueprint.pl`
# from the repo root, __FILE__ is RELATIVE, so $DIR is relative, and `require "$DIR/..."` searches
# @INC — which has not contained '.' since perl 5.26. The script then dies with
# "Can't locate plugins/butler/scripts/bp-orchestrator.pl in @INC" for every real invocation.
# t/86 did not catch it because the harness supplies its own @INC. bp-drive-next.pl already uses
# this form; bp-validate-dag.pl has the same latent bug, masked by callers passing `-I.`.
my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; abs_path($f) // $f });

# The REAL parser/resolver. Never reimplement BpOrch::parse_dag or
# BpOrch::resolve_dep_token -- this is the b12/b13 lesson restated (spec §2.3).
require "$DIR/bp-orchestrator.pl";

# bp-validate-dag.pl shares BpOrch::resolve_dep_token (it only (re)defines it "unless
# already defined" -- bp-orchestrator.pl already defines it, so this require is a no-op
# on that function and exists here so both scripts are provably consuming the one real
# implementation, not two that could drift (spec §2.3's "do not grow a second one").
require "$DIR/bp-validate-dag.pl";

# =====================================================================================
# The six-glyph status vocabulary (spec §1, counted from the live file 2026-08-03).
# =====================================================================================

my $G_DONE      = "\xE2\x9C\x85"; # U+2705 white heavy check mark
my $G_PENDING   = "\xE2\xAC\x9C"; # U+2B1C white large square
my $G_RUNNING   = "\xF0\x9F\x94\xA7"; # U+1F527 wrench
my $G_REVIEWING = "\xF0\x9F\x94\x8D"; # U+1F50D magnifying glass
my $G_BLOCKED   = "\xE2\x9B\x94"; # U+26D4 no entry
my $G_PARKED    = "\xE2\x8F\xB8"; # U+23F8 pause

my @STATUS_VALUES = (
    "$G_DONE done", "$G_PENDING pending", "$G_RUNNING running",
    "$G_REVIEWING reviewing", "$G_BLOCKED blocked", "$G_PARKED parked",
);
my %WORD2GLYPH = (
    done => $G_DONE, pending => $G_PENDING, running => $G_RUNNING,
    reviewing => $G_REVIEWING, blocked => $G_BLOCKED, parked => $G_PARKED,
);

# Accepts either the full "GLYPH word" form (one of @STATUS_VALUES, exact byte match)
# or the bare word alone (normalized to its canonical glyph form). Returns the
# canonical string, or undef if $raw matches neither.
sub normalize_status {
    my ($raw) = @_;
    return undef unless defined $raw;
    return $raw if grep { $_ eq $raw } @STATUS_VALUES;
    return "$WORD2GLYPH{$raw} $raw" if exists $WORD2GLYPH{$raw};
    return undef;
}

my $PKG_ID_RE = qr/^[A-Za-z0-9][A-Za-z0-9_.-]*$/;
my $DEP_TOK_RE = qr/^[A-Za-z0-9][A-Za-z0-9_.-]*$/;

# =====================================================================================
# stderr / exit helpers -- one line, one framing convention: `bp-blueprint: <sub>: ...`
# =====================================================================================

sub emit_err {
    my ($m) = @_;
    $m =~ s/[\r\n]+/ /g;
    print STDERR $m . "\n";
}
sub arg_error      { my ($sub, $msg) = @_; emit_err("bp-blueprint: $sub: $msg"); exit 3 }
sub io_error       { my ($sub, $msg) = @_; emit_err("bp-blueprint: $sub: $msg"); exit 4 }
sub reject_error   { my ($sub, $msg) = @_; emit_err("bp-blueprint: $sub: $msg"); exit 2 }
sub notfound_error { my ($sub, $msg) = @_; emit_err("bp-blueprint: $sub: $msg"); exit 5 }

# =====================================================================================
# Byte-level I/O.
# =====================================================================================

sub _today {
    my @t = gmtime(time);
    return sprintf('%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3]);
}

sub _slurp {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $r = <$fh>;
    close $fh;
    return defined $r ? $r : '';
}

# =====================================================================================
# Table location -- mirrors BpOrch::parse_dag's own latch/terminator EXACTLY (spec §1.1):
# the first `|`-row containing the literal "depends_on" is the header; the table ends
# at the first subsequent non-`|` line. split(..., -1) keeps a trailing empty element
# so join("\n", @lines) round-trips a file byte-for-byte when nothing in it changes.
# =====================================================================================

sub _table_cols {
    my ($ln) = @_;
    $ln =~ s/^\s*\|//; $ln =~ s/\|\s*$//;
    my @c = split /\|/, $ln, -1;
    s/^\s+//, s/\s+$// for @c;
    return @c;
}

sub locate_table {
    my ($B) = @_;
    my @lines = split /\n/, $B, -1;
    my $hdr_i;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^\s*\|/ && $lines[$i] =~ /depends_on/) { $hdr_i = $i; last }
    }
    return undef unless defined $hdr_i;
    my $end_i = scalar(@lines);
    for my $i ($hdr_i + 1 .. $#lines) {
        if ($lines[$i] !~ /^\s*\|/) { $end_i = $i; last }
    }
    return {
        lines => \@lines,
        hdr_i => $hdr_i,
        end_i => $end_i,
        cols  => [ _table_cols($lines[$hdr_i]) ],
    };
}

sub _is_sep_row { return $_[0] =~ /^\s*\|[\s:|-]+\|?\s*$/ }

# =====================================================================================
# Decisions-section location & shape detection (b42-decision-context-split-spec §4).
# Header recognition WIDENS to also match "## Synthesis Decisions" -- "## Decisions"
# behaviour is unchanged, this only broadens what else counts as the same section.
# Shape is detected by CONTENT, never configuration: a `|`-row immediately followed by
# a `|---`-style separator row means the section is a markdown TABLE (b42's target
# shape); anything else is the legacy BULLET list op_add_decision has always assumed.
# =====================================================================================

my $DECISIONS_HEAD_RE = qr/^##\s+(?:Synthesis\s+)?Decisions\b/i;

# Returns ($start_i, $end_i): $start_i is the header line index, $end_i is the index of
# the next `## ` line (or EOF). Returns (undef, undef) if no such section exists.
sub locate_decisions_bounds {
    my ($lines_ref) = @_;
    my $start;
    for my $i (0 .. $#$lines_ref) {
        if ($lines_ref->[$i] =~ $DECISIONS_HEAD_RE) { $start = $i; last }
    }
    return (undef, undef) unless defined $start;
    my $end = scalar(@$lines_ref);
    for my $i ($start + 1 .. $#$lines_ref) {
        if ($lines_ref->[$i] =~ /^##\s/) { $end = $i; last }
    }
    return ($start, $end);
}

# If the Decisions section (bounded by $start/$end, both from locate_decisions_bounds)
# is table-shaped, returns a hashref describing it: { hdr_i, sep_i, end_i, cols }. Returns
# undef if the section is bullet-shaped (or empty) -- i.e. no `|`-row + separator pair.
sub decisions_table_info {
    my ($lines_ref, $start, $end) = @_;
    for my $i ($start + 1 .. $end - 1) {
        next unless $lines_ref->[$i] =~ /^\s*\|/;
        next unless defined $lines_ref->[$i + 1] && _is_sep_row($lines_ref->[$i + 1]);
        my $hdr_i = $i;
        my $sep_i = $i + 1;
        # The table runs to the END OF THE SECTION, not to the first non-`|` line.
        # Measured on sandbox-butler-overhaul: its 26 decisions are written as THREE
        # `|`-row blocks separated by blank lines. Stopping at the first gap saw only the
        # first 15, so set-decision refused SYN-16..SYN-26 as "not found" -- a migration
        # driven by it would have rewritten 15 rows and then aborted on a half-migrated
        # table. Blank lines between blocks are cosmetic in markdown; they do not start a
        # new table, so a gap must not end this one.
        my $end_i = $end;
        return { hdr_i => $hdr_i, sep_i => $sep_i, end_i => $end_i,
                 cols  => [ _table_cols($lines_ref->[$hdr_i]) ] };
    }
    return undef;
}

# The column that holds the decision's prose: whichever header cell mentions "decision"
# (case-insensitively, matching the target `| # | Decision |` shape), else the last
# column of a >=2-column table. Returns undef if neither applies (e.g. a 1-column table).
sub decisions_text_col {
    my ($cols) = @_;
    for my $i (0 .. $#$cols) { return $i if $cols->[$i] =~ /decision/i; }
    return $#$cols if @$cols >= 2;
    return undef;
}

# Row index (into $lines_ref) of the decisions-table row whose first cell trims to
# exactly $id, or undef. $tbl is a decisions_table_info() result.
sub decisions_find_row {
    my ($lines_ref, $tbl, $id) = @_;
    for my $i ($tbl->{sep_i} + 1 .. $tbl->{end_i} - 1) {
        next unless defined $lines_ref->[$i] && $lines_ref->[$i] =~ /^\s*\|/;
        next if _is_sep_row($lines_ref->[$i]);   # a later block may repeat the separator
        my @c = _table_cols($lines_ref->[$i]);
        next unless defined $c[0];
        (my $rid = $c[0]) =~ s/^\s+//; $rid =~ s/\s+$//;
        return $i if $rid eq $id;
    }
    return undef;
}

# Row index (into $tbl->{lines}) whose first column trims to exactly $pkg, or undef.
sub find_row_index {
    my ($tbl, $pkg) = @_;
    my @lines = @{ $tbl->{lines} };
    for my $i ($tbl->{hdr_i} + 1 .. $tbl->{end_i} - 1) {
        next if _is_sep_row($lines[$i]);
        my @c = _table_cols($lines[$i]);
        next unless defined $c[0];
        (my $id = $c[0]) =~ s/^\s+//; $id =~ s/\s+$//;
        return $i if $id eq $pkg;
    }
    return undef;
}

sub col_index {
    my ($tbl, $name) = @_;
    my @cols = @{ $tbl->{cols} };
    for my $i (0 .. $#cols) { return $i if lc($cols[$i]) eq lc($name) }
    return undef;
}

# Replace ONE cell of a `|`-delimited row by column index, preserving every other
# cell's original bytes (spacing, non-ASCII) verbatim -- only the target cell changes.
sub replace_cell {
    my ($line, $col_idx, $new_val) = @_;
    my $inner = $line;
    $inner =~ s/^\s*\|//;
    $inner =~ s/\|\s*$//;
    my @cells = split /\|/, $inner, -1;
    return undef if $col_idx > $#cells;
    $cells[$col_idx] = " $new_val ";
    return '|' . join('|', @cells) . '|';
}

# A field value that cannot land in a `|`-delimited cell / bullet line without
# corrupting structure: no CR/LF, no literal pipe.
sub field_safe { my ($s) = @_; return defined($s) && $s !~ /[\r\n|]/ }

# Split a --deps value on the SAME separator parse_dag uses (spec §1.1: /[,\s]+/),
# keep only tokens that look like a package id, dedupe preserving first occurrence.
sub split_dep_tokens {
    my ($raw) = @_;
    my @out; my %seen;
    for my $t (split /[,\s]+/, (defined $raw ? $raw : '')) {
        next unless length $t;
        next unless $t =~ $DEP_TOK_RE;
        next if $seen{$t}++;
        push @out, $t;
    }
    return @out;
}

# Resolve every token in @tokens against the REAL resolver (BpOrch::resolve_dep_token,
# spec §2.3 -- "call it; do not copy it"). $names is a hashref whose KEYS are the
# universe of real package ids (parse_dag's own dag is exactly this shape). Returns
# (\@canon, \@bad) where @bad holds the tokens that resolved to 'ambiguous' or 'none'.
sub resolve_deps {
    my ($tokens, $names) = @_;
    my (@canon, @bad, %seen);
    for my $tok (@$tokens) {
        my ($how, $name) = BpOrch::resolve_dep_token($tok, $names);
        if ($how eq 'exact' || $how eq 'normalized') {
            next if $seen{$name}++;
            push @canon, $name;
        } else {
            push @bad, $tok;
        }
    }
    return (\@canon, \@bad);
}

my $EMDASH = "\xE2\x80\x94";

sub deps_cell_text {
    my (@canon) = @_;
    return @canon ? join(', ', @canon) : $EMDASH;
}

# =====================================================================================
# The shared write algorithm -- mirrors bp-ledger.pl's run_op shape (spec §2.3):
# flock, read, mutate (validation lives INSIDE $mutate_cb, which returns (undef, $why)
# to refuse), atomic temp+rename. Never touches the file at all on refusal.
# =====================================================================================

sub run_write {
    my ($sub, $path, $mutate_cb) = @_;

    my $lockpath = "$path.lock";
    open(my $lk, '>', $lockpath) or io_error($sub, "cannot open lock file $lockpath: $!");
    flock($lk, LOCK_EX) or io_error($sub, "cannot acquire lock on $lockpath: $!");

    my $orig = _slurp($path);
    unless (defined $orig) {
        close $lk;
        io_error($sub, "cannot read $path: $!");
    }

    my ($new, $why) = $mutate_cb->($orig);
    unless (defined $new) {
        close $lk;
        reject_error($sub, $why);
    }

    if ($new eq $orig) {
        flock($lk, LOCK_UN);
        close $lk;
        exit 0;
    }

    my $tmp = "$path.tmp.$$";
    open(my $w, '>:raw', $tmp) or do { close $lk; io_error($sub, "cannot open temp file $tmp: $!") };
    print {$w} $new or do { close $w; unlink $tmp; close $lk; io_error($sub, "write to $tmp failed: $!") };
    close($w) or do { unlink $tmp; close $lk; io_error($sub, "close $tmp failed: $!") };

    unless (rename($tmp, $path)) {
        unlink $tmp;
        close $lk;
        io_error($sub, "rename $tmp -> $path failed: $!");
    }

    flock($lk, LOCK_UN);
    close $lk;
    exit 0;
}

# =====================================================================================
# Write ops.
# =====================================================================================

# -------------------------------------------------------------------------------------
# op_init — CREATE blueprint.md from a template.
#
# WHY THIS EXISTS. `guard-blueprint-write.sh` denies Write/Edit to ANY blueprint.md
# path -- including one that does not exist yet -- while /blueprint:create step 4 said
# "Write blueprint.md from templates/blueprint.md". The documented create flow was
# therefore impossible to execute as written, and every author had to route around the
# guard via Bash: exactly the hand-splice the guard exists to prevent, through a door
# the hook cannot see. Prose said one thing, the mechanism enforced another.
#
# The template path is a PARAMETER, never derived here. bp-blueprint.pl ships in the
# butler plugin; the template ships in the blueprint plugin, and installed plugins live
# in separate cache trees -- so a cross-plugin path would resolve on a dev checkout and
# break on a real install. The caller (which owns the template) passes it in.
# -------------------------------------------------------------------------------------
sub op_init {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt,
            'file=s', 'template=s', 'name=s', 'created=s'); }
    arg_error('init', 'unrecognised option') unless $ok;
    arg_error('init', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file template name)) {
        arg_error('init', "missing required --$r") unless defined $opt{$r};
    }
    unless (field_safe($opt{name})) {
        arg_error('init', '--name contains a pipe or newline');
    }
    unless ($opt{name} =~ /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/) {
        arg_error('init', "--name '$opt{name}' is not kebab-case (a-z, 0-9, single hyphens)");
    }

    my $path = $opt{file};

    # REFUSE rather than overwrite. An existing blueprint is somebody's initiative;
    # re-running init must never be the thing that destroys it.
    if (-e $path) {
        reject_error('init', "$path already exists -- refusing to overwrite an existing blueprint. "
                           . 'Use the typed verbs (add-package, add-decision, set-section) to modify it.');
    }

    my $tpl = _slurp($opt{template});
    defined $tpl or io_error('init', "cannot read template $opt{template}: $!");

    # A template that does not carry the metadata block is not a blueprint template;
    # substituting into it would silently produce a file parse_dag cannot read.
    unless ($tpl =~ /^blueprint:\s*\S/m) {
        reject_error('init', "template $opt{template} has no `blueprint:` metadata line -- "
                           . 'refusing to guess its shape');
    }

    my $created = $opt{created};
    unless (defined $created && length $created) {
        my @t = gmtime(time);
        $created = sprintf('%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3]);
    }
    unless (field_safe($created)) {
        arg_error('init', '--created contains a pipe or newline');
    }

    # STRIP TEMPLATE PLACEHOLDER ROWS. The template ships illustrative table rows --
    # `| 01-<slug> | <one line> | — | sonnet | pending |` and `| 1 | <e.g. ...> |`.
    # Left in place, BpOrch::parse_dag reads `01-<slug>` as a REAL package with no
    # ledger, so a brand-new blueprint fails its own DAG validation and every author
    # has to remember to delete rows by hand. A data row carrying an angle-bracket
    # placeholder is by definition not real content; header and separator rows are
    # never touched.
    {
        my @keep;
        for my $ln (split /\n/, $tpl, -1) {
            if ($ln =~ /^\s*\|/ && !_is_sep_row($ln) && $ln =~ /<[^>]*>/) {
                next;   # illustrative row from the template
            }
            push @keep, $ln;
        }
        $tpl = join("\n", @keep);
    }

    $tpl =~ s/^blueprint:\s*.*$/blueprint: $opt{name}/m;
    $tpl =~ s/^created:\s*.*$/created: $created/m;
    $tpl =~ s/^last_updated:\s*.*$/last_updated: $created/m;
    $tpl =~ s/^status:\s*\S+/status: drafting/m;

    my $dir = dirname($path);
    if (length $dir && !-d $dir) {
        require File::Path;
        File::Path::make_path($dir)
            or io_error('init', "cannot create directory $dir: $!");
    }

    # Same atomic discipline as run_write: temp + rename under flock. Not run_write
    # itself, which slurps the target first and so cannot create one.
    my $lockpath = "$path.lock";
    open(my $lk, '>', $lockpath) or io_error('init', "cannot open lock file $lockpath: $!");
    flock($lk, LOCK_EX) or io_error('init', "cannot acquire lock on $lockpath: $!");

    # Re-check under the lock: two authors racing must not both "create" it.
    if (-e $path) {
        close $lk;
        reject_error('init', "$path already exists (created concurrently) -- refusing to overwrite");
    }

    my $tmp = "$path.tmp.$$";
    open(my $w, '>:raw', $tmp) or do { close $lk; io_error('init', "cannot open temp file $tmp: $!") };
    print {$w} $tpl or do { close $w; unlink $tmp; close $lk; io_error('init', "write to $tmp failed: $!") };
    close($w) or do { unlink $tmp; close $lk; io_error('init', "close $tmp failed: $!") };
    unless (rename($tmp, $path)) {
        unlink $tmp;
        close $lk;
        io_error('init', "rename $tmp -> $path failed: $!");
    }
    flock($lk, LOCK_UN);
    close $lk;
    exit 0;
}

# -------------------------------------------------------------------------------------
# op_set_section — replace the BODY of a `## ` prose section.
#
# The other write verbs are all typed edits to the package-status table and the
# decisions table. The NARRATIVE sections (Objective, Constraints & known hazards, Key
# references, the per-package blocks) had no verb at all -- so an author filling in a
# freshly-initialised template still had to hand-splice, and the guard still refused.
# This closes that loop: every mutation of blueprint.md now has a typed, atomic path.
#
# Structural sections are REFUSED here on purpose. "Package status" and "Decisions" are
# tables the orchestrator's parse_dag reads; they have their own validated verbs, and
# letting free text overwrite them would reintroduce exactly the corruption this API
# exists to make impossible.
# -------------------------------------------------------------------------------------
my %SECTION_REFUSED = map { lc($_) => 1 } (
    'Package status',   # add-package / set-status / set-field / set-deps own this
    'Decisions',        # add-decision / set-decision own this
    'Harvest log',      # orchestrator-only, written during execution
);

sub op_set_section {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'section=s', 'text-file=s'); }
    arg_error('set-section', 'unrecognised option') unless $ok;
    arg_error('set-section', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file section text-file)) {
        arg_error('set-section', "missing required --$r") unless defined $opt{$r};
    }

    my $want = $opt{section};
    if ($SECTION_REFUSED{ lc $want }) {
        arg_error('set-section',
            "section '$want' is structured state with its own typed verbs -- refusing. "
          . 'Use add-package/set-status/set-field/set-deps or add-decision/set-decision.');
    }

    my $body = _slurp($opt{'text-file'});
    defined $body or io_error('set-section', "cannot read --text-file $opt{'text-file'}: $!");

    # New text may not introduce a `## ` heading: that would silently restructure the
    # document and could manufacture a second "Package status" the parser then latches
    # onto (the SYN-14 failure shape, one level up).
    if ($body =~ /^##\s/m) {
        arg_error('set-section',
            '--text-file contains a `## ` heading; that would restructure the document. '
          . 'Set one section at a time.');
    }

    run_write('set-section', $opt{file}, sub {
        my ($orig) = @_;

        # Match this `## <section>` up to the next `## ` at line start, or EOF.
        my $q = quotemeta $want;
        unless ($orig =~ /^##[ \t]+$q[ \t]*$/m) {
            return (undef, "no `## $want` section found in $opt{file} -- refusing to invent one. "
                         . 'Sections come from the template; check the exact heading text.');
        }

        $body =~ s/\s*\z//;                    # normalise trailing whitespace
        my $new = $orig;
        # `[ \t]*` not `\s*` after the heading: `\s*` also matches the newline, so the
        # capture swallowed the blank line that follows and every set-section added
        # another one. Caught by diffing the bytes, not by reading the regex.
        $new =~ s{(^##[ \t]+$q[ \t]*\n)(.*?)(?=^##[ \t]|\z)}{$1\n$body\n\n}ms;
        return ($new, undef);
    });
}

# -------------------------------------------------------------------------------------
# op_set_meta — set a field in the blueprint's own metadata block.
#
# The lifecycle field `status:` (drafting -> audited -> running -> done -> archived) is
# documented in the template and had NO verb: set-field only edits package-status TABLE
# rows and rejects these values outright. So advancing a blueprint's own lifecycle -- the
# last step of /blueprint:create -- required a hand-splice, which is precisely what this
# API exists to prevent. Found by hitting it while authoring a real blueprint.
# -------------------------------------------------------------------------------------
my @BP_LIFECYCLE = qw(drafting audited running done archived);
my %META_FIELDS  = map { $_ => 1 } qw(blueprint created last_updated status execution_mode);

sub op_set_meta {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'field=s', 'value=s'); }
    arg_error('set-meta', 'unrecognised option') unless $ok;
    arg_error('set-meta', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file field value)) {
        arg_error('set-meta', "missing required --$r") unless defined $opt{$r};
    }
    unless ($META_FIELDS{ $opt{field} }) {
        arg_error('set-meta', "--field '$opt{field}' is not a metadata field; expected one of: "
                            . join(', ', sort keys %META_FIELDS));
    }
    unless (field_safe($opt{value})) {
        arg_error('set-meta', '--value contains a pipe or newline');
    }
    if ($opt{field} eq 'status' && !grep { $_ eq $opt{value} } @BP_LIFECYCLE) {
        arg_error('set-meta', "--value '$opt{value}' is not a blueprint lifecycle status; expected one of: "
                            . join(', ', @BP_LIFECYCLE));
    }

    run_write('set-meta', $opt{file}, sub {
        my ($orig) = @_;
        my $f = quotemeta $opt{field};

        # The metadata block is the fenced ``` block near the top. Only ever touch a
        # `field:` line inside it -- a `status:` elsewhere (a package ledger quoted in
        # prose, say) must not be rewritten.
        unless ($orig =~ /^```\s*\n(?:.*\n)*?^$f:/m) {
            return (undef, "no `$opt{field}:` line found in the metadata block of $opt{file}");
        }

        my $new = $orig;
        my $done = 0;
        # Preserve any trailing `# comment` the template carries on the line.
        $new =~ s{^($f:)([ \t]*)([^\n#]*)(#[^\n]*)?$}{
            $done++ ? "$1$2$3" . ($4 // '')
                    : $1 . ($2 || ' ') . $opt{value} . (defined $4 ? "        $4" : '')
        }me;
        return (undef, "could not rewrite `$opt{field}:`") unless $done;
        return ($new, undef);
    });
}

sub op_add_package {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt,
          'file=s', 'pkg=s', 'deliverable=s', 'deps=s', 'model=s', 'status=s'); }
    arg_error('add-package', 'unrecognised option') unless $ok;
    arg_error('add-package', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file pkg deliverable)) {
        arg_error('add-package', "missing required --$r") unless defined $opt{$r};
    }

    my $pkg = $opt{pkg};
    unless (field_safe($pkg) && $pkg =~ $PKG_ID_RE) {
        arg_error('add-package',
            "--pkg '$pkg' cannot form a contiguous table row (must match $PKG_ID_RE, no pipe/newline)");
    }
    unless (field_safe($opt{deliverable})) {
        arg_error('add-package', '--deliverable contains a pipe or newline; would break the table row');
    }

    my $status = defined $opt{status} ? normalize_status($opt{status}) : "$G_PENDING pending";
    unless (defined $status) {
        arg_error('add-package',
            "--status '$opt{status}' is not one of the six recognised statuses");
    }
    if (defined $opt{model} && !field_safe($opt{model})) {
        arg_error('add-package', '--model contains a pipe or newline; would break the table row');
    }

    run_write('add-package', $opt{file}, sub {
        my ($orig) = @_;
        my $tbl = locate_table($orig);
        return (undef, "no package-status table found (no 'depends_on' column header)") unless $tbl;

        return (undef, "package '$pkg' already exists in the table") if defined find_row_index($tbl, $pkg);

        my $dag = BpOrch::parse_dag($orig);
        my @tokens = defined $opt{deps} ? split_dep_tokens($opt{deps}) : ();
        my ($canon, $bad) = resolve_deps(\@tokens, $dag);
        return (undef, "--deps names package id(s) that do not resolve: " . join(', ', @$bad)) if @$bad;

        my %fields = (
            pkg         => $pkg,
            deliverable => $opt{deliverable},
            depends_on  => deps_cell_text(@$canon),
            status      => $status,
            model       => defined $opt{model} ? $opt{model} : '',
        );
        my @row_cells = map { $fields{lc $_} // '' } @{ $tbl->{cols} };
        my $row = '| ' . join(' | ', @row_cells) . ' |';

        my @lines = @{ $tbl->{lines} };
        splice(@lines, $tbl->{end_i}, 0, $row);
        return (join("\n", @lines), undef);
    });
}

sub op_set_status {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'pkg=s', 'status=s'); }
    arg_error('set-status', 'unrecognised option') unless $ok;
    arg_error('set-status', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file pkg status)) {
        arg_error('set-status', "missing required --$r") unless defined $opt{$r};
    }

    my $status = normalize_status($opt{status});
    unless (defined $status) {
        arg_error('set-status',
            "--status '$opt{status}' is not one of the six recognised statuses "
          . '(done, pending, running, reviewing, blocked, parked -- glyph-prefixed or bare)');
    }
    my $pkg = $opt{pkg};

    run_write('set-status', $opt{file}, sub {
        my ($orig) = @_;
        my $tbl = locate_table($orig);
        return (undef, "no package-status table found (no 'depends_on' column header)") unless $tbl;
        my $ci = col_index($tbl, 'status');
        return (undef, "table has no 'status' column") unless defined $ci;
        my $ri = find_row_index($tbl, $pkg);
        return (undef, "no such package '$pkg' in the table") unless defined $ri;

        my @lines = @{ $tbl->{lines} };
        my $new_line = replace_cell($lines[$ri], $ci, $status);
        return (undef, "internal error replacing the status cell for '$pkg'") unless defined $new_line;
        $lines[$ri] = $new_line;
        return (join("\n", @lines), undef);
    });
}

sub op_set_deps {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'pkg=s', 'deps=s'); }
    arg_error('set-deps', 'unrecognised option') unless $ok;
    arg_error('set-deps', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file pkg)) {
        arg_error('set-deps', "missing required --$r") unless defined $opt{$r};
    }
    my $pkg = $opt{pkg};

    run_write('set-deps', $opt{file}, sub {
        my ($orig) = @_;
        my $tbl = locate_table($orig);
        return (undef, "no package-status table found (no 'depends_on' column header)") unless $tbl;
        my $ci = col_index($tbl, 'depends_on');
        return (undef, "table has no 'depends_on' column") unless defined $ci;
        my $ri = find_row_index($tbl, $pkg);
        return (undef, "no such package '$pkg' in the table") unless defined $ri;

        my $dag = BpOrch::parse_dag($orig);
        delete $dag->{$pkg};   # a package cannot depend on itself
        my @tokens = split_dep_tokens($opt{deps});
        my ($canon, $bad) = resolve_deps(\@tokens, $dag);
        return (undef, "--deps names package id(s) that do not resolve: " . join(', ', @$bad)) if @$bad;

        my @lines = @{ $tbl->{lines} };
        my $new_line = replace_cell($lines[$ri], $ci, deps_cell_text(@$canon));
        return (undef, "internal error replacing the depends_on cell for '$pkg'") unless defined $new_line;
        $lines[$ri] = $new_line;
        return (join("\n", @lines), undef);
    });
}

sub op_add_decision {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'id=s', 'text=s', 'decided=s', 'date=s'); }
    arg_error('add-decision', 'unrecognised option') unless $ok;
    arg_error('add-decision', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file id text)) {
        arg_error('add-decision', "missing required --$r") unless defined $opt{$r};
    }
    unless (field_safe($opt{id})) {
        arg_error('add-decision', '--id contains a pipe or newline');
    }
    # SYN-14 hazard (spec §1.1 / §3 G3): parse_dag latches onto the FIRST `|`-row
    # containing the literal "depends_on" as the header. A decision whose text
    # carries that token risks becoming (or masquerading as) a second such row/
    # table, mis-routing the whole run. Refused mechanically, naming SYN-14.
    if (index($opt{text}, 'depends_on') >= 0) {
        arg_error('add-decision',
            "--text contains the literal token 'depends_on' (SYN-14 hazard: parse_dag latches onto the "
          . 'FIRST |-row containing that token as its table header -- a second one mis-routes the whole '
          . 'run). Rephrase without the literal token.');
    }

    my $text = $opt{text};
    $text =~ s/[\r\n]+/ /g;
    my $entry = "- $opt{id}: $text";

    run_write('add-decision', $opt{file}, sub {
        my ($orig) = @_;
        my @lines = split /\n/, $orig, -1;
        my ($start, $end) = locate_decisions_bounds(\@lines);
        return (undef, "no '## Decisions' section found") unless defined $start;
        # A table-shaped section (b42's target shape) must never receive an appended
        # bullet -- that would corrupt the table silently. Refuse instead; editing an
        # existing row is set-decision's job, and creating new rows is out of scope here.
        # TABLE-SHAPED: append a ROW, don't refuse.
        #
        # This used to refuse outright, which left a hole nobody could get through:
        # `add-decision` would not append to a table and `set-decision` requires a row
        # that already exists -- so a table-shaped Decisions section could never receive
        # a NEW decision. b42 converted the shape and did not update the appender, and
        # the refusal message pointed at a verb that cannot create rows. A freshly
        # initialised blueprint (whose template ships the table shape) was therefore
        # un-authorable through the API, which is what forced hand-splicing.
        if (my $tbl = decisions_table_info(\@lines, $start, $end)) {
            my $ci = decisions_text_col($tbl->{cols});
            return (undef, 'decisions table has no identifiable text column') unless defined $ci;

            return (undef, "a decision with id '$opt{id}' already exists; use set-decision to edit it")
                if defined decisions_find_row(\@lines, $tbl, $opt{id});

            # Fill by COLUMN HEADER, not by position: the table's shape is the
            # blueprint author's, and assuming a fixed 4-column layout is how a
            # generic API silently corrupts a project-specific one.
            my @cells;
            for my $i (0 .. $#{ $tbl->{cols} }) {
                if    ($i == 0)   { push @cells, $opt{id} }
                elsif ($i == $ci) { push @cells, $opt{text} }
                elsif ($tbl->{cols}[$i] =~ /decided|by|who/i)  { push @cells, $opt{decided} // 'user' }
                elsif ($tbl->{cols}[$i] =~ /date|when/i)       { push @cells, $opt{date} // _today() }
                else                                           { push @cells, '' }
            }
            my $row = '| ' . join(' | ', @cells) . ' |';

            # Insert immediately after the last CONTIGUOUS row, not at the section's
            # end_i. On a freshly initialised blueprint the table is header+separator
            # followed by a blank line, and appending at end_i put the row AFTER that
            # blank -- which terminates the table, so the row was orphaned and invisible
            # to the parser. Found by reading the emitted bytes, not the code.
            my $ins = $tbl->{sep_i} + 1;
            $ins++ while defined $lines[$ins]
                      && $lines[$ins] =~ /^\s*\|/
                      && !_is_sep_row($lines[$ins]);
            splice(@lines, $ins, 0, $row);
            return (join("\n", @lines), undef);
        }
        my $insert_at = $end;
        $insert_at-- if $insert_at > 0 && $lines[$insert_at - 1] eq '';
        splice(@lines, $insert_at, 0, $entry);
        return (join("\n", @lines), undef);
    });
}

sub op_set_decision {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'id=s', 'text=s'); }
    arg_error('set-decision', 'unrecognised option') unless $ok;
    arg_error('set-decision', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file id text)) {
        arg_error('set-decision', "missing required --$r") unless defined $opt{$r};
    }
    unless (field_safe($opt{id})) {
        arg_error('set-decision', '--id contains a pipe or newline');
    }
    unless (field_safe($opt{text})) {
        arg_error('set-decision', '--text contains a pipe or newline');
    }
    # SYN-14 hazard, identical wording class to op_add_decision (spec §4): the decisions
    # table sits ABOVE the real depends_on/DAG header, so a --text carrying the literal
    # token risks becoming (or masquerading as) a second such row and mis-routing parse_dag.
    if (index($opt{text}, 'depends_on') >= 0) {
        arg_error('set-decision',
            "--text contains the literal token 'depends_on' (SYN-14 hazard: parse_dag latches onto the "
          . 'FIRST |-row containing that token as its table header -- a second one mis-routes the whole '
          . 'run). Rephrase without the literal token.');
    }

    # Best-effort pre-check outside the lock: an unknown --id is refused up front (exit 3,
    # via arg_error, file never opened for writing) rather than only discovered inside the
    # write transaction. The mutate callback below re-derives this under the lock and is
    # the actual source of truth -- this pre-check only makes the common case a clean,
    # argument-validation-style refusal instead of a generic write-transaction rejection.
    {
        my $pre = _slurp($opt{file});
        if (defined $pre) {
            my @lines = split /\n/, $pre, -1;
            my ($start, $end) = locate_decisions_bounds(\@lines);
            if (defined $start) {
                my $tbl = decisions_table_info(\@lines, $start, $end);
                if ($tbl && !defined decisions_find_row(\@lines, $tbl, $opt{id})) {
                    arg_error('set-decision', "no decision with id '$opt{id}' found in the table");
                }
            }
        }
    }

    run_write('set-decision', $opt{file}, sub {
        my ($orig) = @_;
        my @lines = split /\n/, $orig, -1;
        my ($start, $end) = locate_decisions_bounds(\@lines);
        return (undef, "no '## Decisions' section found") unless defined $start;
        my $tbl = decisions_table_info(\@lines, $start, $end);
        return (undef, "the Decisions section is not table-shaped; set-decision requires a table")
            unless $tbl;
        my $ci = decisions_text_col($tbl->{cols});
        return (undef, "decisions table has no identifiable text column") unless defined $ci;
        my $ri = decisions_find_row(\@lines, $tbl, $opt{id});
        return (undef, "no decision with id '$opt{id}' found in the table") unless defined $ri;

        # When the decision text is the LAST column, everything after the preceding `|` IS the
        # text -- including any unescaped `|` the prose happens to contain. replace_cell splits
        # on `|` and rewrites one field, so on such a row it overwrote only the first fragment
        # and left the rest of the old prose trailing behind the new text.
        #
        # Measured: SYN-14 of sandbox-butler-overhaul is the one decision of 26 whose text
        # carries an internal pipe. Replacing its cell produced a 1,338-byte row holding the new
        # statement AND the tail of the original. Silent corruption of the row this op exists to
        # rewrite, so it is handled here rather than left to callers to pre-sanitise.
        my $new_line;
        if ($ci == $#{ $tbl->{cols} }) {
            my @c = _table_cols($lines[$ri]);
            my @keep = @c[0 .. $ci - 1];
            $new_line = '| ' . join(' | ', @keep, $opt{text}) . ' |';
        }
        else {
            # Interior column: one field, one replacement -- the same helper set-deps uses.
            $new_line = replace_cell($lines[$ri], $ci, $opt{text});
        }
        return (undef, "internal error replacing the decision text cell for '$opt{id}'")
            unless defined $new_line;
        $lines[$ri] = $new_line;
        return (join("\n", @lines), undef);
    });
}

sub op_set_field {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { };
      $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'pkg=s', 'field=s', 'value=s'); }
    arg_error('set-field', 'unrecognised option') unless $ok;
    arg_error('set-field', 'unexpected extra arguments: ' . join(' ', @args)) if @args;
    for my $r (qw(file pkg field value)) {
        arg_error('set-field', "missing required --$r") unless defined $opt{$r};
    }
    my ($pkg, $field, $value) = @opt{qw(pkg field value)};

    if (lc($field) eq 'status') {
        my $status = normalize_status($value);
        arg_error('set-field', "--value '$value' is not one of the six recognised statuses")
            unless defined $status;
        return op_set_status_direct($opt{file}, $pkg, $status);
    }
    if (lc($field) eq 'depends_on') {
        return op_set_deps('--file', $opt{file}, '--pkg', $pkg, '--deps', $value);
    }
    unless (field_safe($value)) {
        arg_error('set-field', "--value contains a pipe or newline; would break the table row");
    }

    run_write('set-field', $opt{file}, sub {
        my ($orig) = @_;
        my $tbl = locate_table($orig);
        return (undef, "no package-status table found (no 'depends_on' column header)") unless $tbl;
        my $ci = col_index($tbl, $field);
        return (undef, "table has no '$field' column") unless defined $ci;
        my $ri = find_row_index($tbl, $pkg);
        return (undef, "no such package '$pkg' in the table") unless defined $ri;

        my @lines = @{ $tbl->{lines} };
        my $new_line = replace_cell($lines[$ri], $ci, $value);
        return (undef, "internal error replacing the '$field' cell for '$pkg'") unless defined $new_line;
        $lines[$ri] = $new_line;
        return (join("\n", @lines), undef);
    });
}

# set-field's status arm reuses set-status's own write op (already-normalized status).
sub op_set_status_direct {
    my ($file, $pkg, $status) = @_;
    run_write('set-field', $file, sub {
        my ($orig) = @_;
        my $tbl = locate_table($orig);
        return (undef, "no package-status table found (no 'depends_on' column header)") unless $tbl;
        my $ci = col_index($tbl, 'status');
        return (undef, "table has no 'status' column") unless defined $ci;
        my $ri = find_row_index($tbl, $pkg);
        return (undef, "no such package '$pkg' in the table") unless defined $ri;
        my @lines = @{ $tbl->{lines} };
        my $new_line = replace_cell($lines[$ri], $ci, $status);
        return (undef, "internal error replacing the status cell for '$pkg'") unless defined $new_line;
        $lines[$ri] = $new_line;
        return (join("\n", @lines), undef);
    });
}

# =====================================================================================
# Read ops -- equally important (spec §2.2): a coordinator must be able to fetch its
# own block without slurping the whole file. `show` is bounded well under 8 KB (G8).
# =====================================================================================

sub _read_or_die {
    my ($sub, $file) = @_;
    my $b = _slurp($file);
    io_error($sub, "cannot read $file: $!") unless defined $b;
    return $b;
}

sub row_fields {
    my ($tbl, $ri) = @_;
    my @c = _table_cols($tbl->{lines}[$ri]);
    my %f;
    my @cols = @{ $tbl->{cols} };
    for my $i (0 .. $#cols) {
        my $v = defined $c[$i] ? $c[$i] : '';
        $f{$cols[$i]} = $v;
    }
    return \%f;
}

sub op_show {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { }; $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'pkg=s'); }
    arg_error('show', 'unrecognised option') unless $ok;
    for my $r (qw(file pkg)) { arg_error('show', "missing required --$r") unless defined $opt{$r}; }

    my $B = _read_or_die('show', $opt{file});
    my $tbl = locate_table($B);
    notfound_error('show', "no package-status table found") unless $tbl;
    my $ri = find_row_index($tbl, $opt{pkg});
    notfound_error('show', "no such package '$opt{pkg}' in the table") unless defined $ri;

    my $f = row_fields($tbl, $ri);
    for my $col (@{ $tbl->{cols} }) {
        print "$col: $f->{$col}\n";
    }
    exit 0;
}

sub op_deps {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { }; $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'pkg=s'); }
    arg_error('deps', 'unrecognised option') unless $ok;
    for my $r (qw(file pkg)) { arg_error('deps', "missing required --$r") unless defined $opt{$r}; }

    my $B = _read_or_die('deps', $opt{file});
    my $dag = BpOrch::parse_dag($B);
    notfound_error('deps', "no such package '$opt{pkg}' in the table") unless exists $dag->{ $opt{pkg} };
    print "$_\n" for @{ $dag->{ $opt{pkg} } };
    exit 0;
}

sub op_status {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { }; $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'pkg=s'); }
    arg_error('status', 'unrecognised option') unless $ok;
    arg_error('status', 'missing required --file') unless defined $opt{file};

    my $B = _read_or_die('status', $opt{file});
    my $tbl = locate_table($B);
    notfound_error('status', "no package-status table found") unless $tbl;
    my $ci = col_index($tbl, 'status');
    notfound_error('status', "table has no 'status' column") unless defined $ci;

    if (defined $opt{pkg}) {
        my $ri = find_row_index($tbl, $opt{pkg});
        notfound_error('status', "no such package '$opt{pkg}' in the table") unless defined $ri;
        my @c = _table_cols($tbl->{lines}[$ri]);
        print "$c[$ci]\n";
        exit 0;
    }
    for my $i ($tbl->{hdr_i} + 1 .. $tbl->{end_i} - 1) {
        next if _is_sep_row($tbl->{lines}[$i]);
        my @c = _table_cols($tbl->{lines}[$i]);
        next unless defined $c[0] && length $c[0];
        print "$c[0]: $c[$ci]\n";
    }
    exit 0;
}

sub op_decisions {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { }; $ok = GetOptionsFromArray(\@args, \%opt, 'file=s', 'id=s'); }
    arg_error('decisions', 'unrecognised option') unless $ok;
    arg_error('decisions', 'missing required --file') unless defined $opt{file};

    my $B = _read_or_die('decisions', $opt{file});
    my @lines = split /\n/, $B, -1;
    my ($start, $end) = locate_decisions_bounds(\@lines);
    notfound_error('decisions', "no '## Decisions' section found") unless defined $start;

    # Shape-aware, for the same reason set-decision is: a decisions section may be a bullet list
    # or a markdown table. Reading only bullets against a table printed nothing and exited 0 --
    # a silent vacuous success, indistinguishable from "this blueprint has no decisions".
    my @found;
    my $tbl = decisions_table_info(\@lines, $start, $end);
    if ($tbl) {
        my $col = decisions_text_col($tbl->{cols});
        notfound_error('decisions', 'decisions table has no column holding the decision text')
            unless defined $col;
        for my $i ($tbl->{sep_i} + 1 .. $tbl->{end_i} - 1) {
            next unless defined $lines[$i] && $lines[$i] =~ /^\s*\|/;
            next if _is_sep_row($lines[$i]);
            my @cells = _table_cols($lines[$i]);
            next unless @cells > $col;
            my $id = $cells[0];
            next unless defined $id && $id =~ /^\S+$/;
            push @found, [ $id, $cells[$col] ];
        }
    }
    else {
        for my $i ($start + 1 .. $end - 1) {
            next unless $lines[$i] =~ /^-\s*(\S+?):\s*(.*)$/;
            push @found, [ $1, $2 ];
        }
    }

    my @sel = defined $opt{id} ? grep { $_->[0] eq $opt{id} } @found : @found;

    # Never exit 0 having found nothing: an empty result is either a bad --id or a section shape
    # this op cannot read, and both must be distinguishable from a genuinely empty section.
    if (!@sel) {
        notfound_error('decisions', "no decision with id '$opt{id}' found") if defined $opt{id};
        notfound_error('decisions',
            'decisions section contains no readable entries (neither `- ID: text` bullets nor a table row)')
            if !@found;
    }

    print "$_->[0]: $_->[1]\n" for @sel;
    exit 0;
}

sub op_ready {
    my @args = @_;
    my %opt;
    my $ok;
    { local $SIG{__WARN__} = sub { }; $ok = GetOptionsFromArray(\@args, \%opt, 'file=s'); }
    arg_error('ready', 'unrecognised option') unless $ok;
    arg_error('ready', 'missing required --file') unless defined $opt{file};

    my $B = _read_or_die('ready', $opt{file});
    my $tbl = locate_table($B);
    notfound_error('ready', "no package-status table found") unless $tbl;
    my $sci = col_index($tbl, 'status');
    notfound_error('ready', "table has no 'status' column") unless defined $sci;

    my $dag = BpOrch::parse_dag($B);
    my %status;
    for my $i ($tbl->{hdr_i} + 1 .. $tbl->{end_i} - 1) {
        next if _is_sep_row($tbl->{lines}[$i]);
        my @c = _table_cols($tbl->{lines}[$i]);
        next unless defined $c[0] && length $c[0];
        $status{ $c[0] } = ($c[$sci] // '') =~ /\bdone\b/ ? 'done' : 'pending';
    }
    for my $pkg (sort keys %$dag) {
        next unless ($status{$pkg} // '') ne 'done';
        my $deps_ok = 1;
        for my $d (@{ $dag->{$pkg} }) { $deps_ok = 0 unless ($status{$d} // '') eq 'done'; }
        print "$pkg\n" if $deps_ok;
    }
    exit 0;
}

# =====================================================================================
# Main.
# =====================================================================================

my %DISPATCH = (
    'init'         => \&op_init,
    'set-meta'     => \&op_set_meta,
    'set-section'  => \&op_set_section,
    'add-package'  => \&op_add_package,
    'set-status'   => \&op_set_status,
    'set-deps'     => \&op_set_deps,
    'add-decision' => \&op_add_decision,
    'set-decision' => \&op_set_decision,
    'set-field'    => \&op_set_field,
    'show'         => \&op_show,
    'deps'         => \&op_deps,
    'status'       => \&op_status,
    'decisions'    => \&op_decisions,
    'ready'        => \&op_ready,
);

my $sub = shift @ARGV;
if (!defined $sub || $sub eq '') {
    arg_error('(none)', 'missing subcommand; expected one of: ' . join(', ', sort keys %DISPATCH));
}
unless (exists $DISPATCH{$sub}) {
    arg_error($sub, "unknown subcommand '$sub'; expected one of: " . join(', ', sort keys %DISPATCH));
}
$DISPATCH{$sub}->(@ARGV);
exit 0;
