#!/usr/bin/perl
# gen-readme-tree.pl — generate/refresh the file-tree section of README.md
# from what's actually on disk, resolving descriptions from per-module
# metadata co-located with each entry.
#
# Metadata resolution (priority order, first non-empty hit wins):
#
#   1. Sidecar `.about` file — editorial override
#        - for a directory `path/foo/`, looks at `path/foo/.about`
#        - for a file `path/foo.ext`, looks at `path/foo.ext.about`
#        (one line; CR/LF/whitespace trimmed)
#
#   2. Plugin dir (matches `plugins/<name>/` exactly)
#        → `description` field of `plugins/<name>/.claude-plugin/plugin.json`
#
#   3. Skill dir (contains SKILL.md as a direct child)
#        → `description:` frontmatter of that SKILL.md (first sentence,
#          or first 60 chars if longer)
#
#   4. Script (.pl .pm .sh .ps1)
#        → second non-shebang non-blank comment line of the file (the
#          convention: line 1 = shebang or filename, line 2+ = purpose).
#          Truncated to first sentence or 80 chars.
#
#   5. Empty description (the entry appears in the tree with no comment)
#
# The `.about` override exists so newly-added entries get a sensible
# default from natural metadata, but the human can tune the editorial
# tone of any individual tree caption without touching the underlying
# source.
#
# Usage:
#   perl gen-readme-tree.pl --check       # exit 0 if README tree matches disk, 1 if drift
#   perl gen-readme-tree.pl --write       # regenerate the tree section in-place
#   perl gen-readme-tree.pl --bootstrap   # one-shot: extract descriptions from current
#                                         # README's tree and write them as `.about`
#                                         # sidecars next to each entry. Use this once
#                                         # when adopting the generator on an existing
#                                         # README so existing hand-written descriptions
#                                         # survive the first --write.
#
# Default mode is --check (safe to wire into /backup pre-flights).
#
# Tree placement: between marker comments in README.md:
#   <!-- BEGIN-FILE-TREE -->
#   ```
#   ...tree...
#   ```
#   <!-- END-FILE-TREE -->
#
# Exit codes:
#   --check:     0 = in sync, 1 = drift, 2 = error
#   --write:     0 = wrote, 2 = error
#   --bootstrap: 0 = wrote N sidecars, 2 = error

use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use Getopt::Long;
use JSON::PP;
use File::Path qw(make_path);
use File::Basename qw(dirname);

my $mode = 'check';
my $help = 0;
GetOptions(
    'check'     => sub { $mode = 'check' },
    'write'     => sub { $mode = 'write' },
    'bootstrap' => sub { $mode = 'bootstrap' },
    'help|h'    => \$help,
) or exit 2;

if ($help) {
    print "Usage: perl gen-readme-tree.pl [--check | --write | --bootstrap]\n";
    exit 0;
}

my $REPO_ROOT = abs_path("$Bin/..");
my $README    = "$REPO_ROOT/README.md";

# Excludes (relative paths or bare names).
my %EXCLUDE_DIRS = map { $_ => 1 } qw(
    .git .claude .claude-plans .ccpraxis-local-data
);
my %EXCLUDE_FILES = map { $_ => 1 } qw(
    LICENSE NOTICE .gitignore README.md nul .backup-preferences.json
    .statusline_usage_cache.json
);
my $EXCLUDE_RE = qr{^\.d5-test-};

# ── Walk ──────────────────────────────────────────────────────────
sub walk {
    my ($abs, $rel) = @_;
    opendir my $dh, $abs or do {
        warn "Cannot opendir $abs: $!\n";
        return [];
    };
    my @entries;
    while (my $e = readdir $dh) {
        next if $e eq '.' || $e eq '..';
        my $abs_child = "$abs/$e";
        my $rel_child = length($rel) ? "$rel/$e" : $e;

        if (-d $abs_child) {
            next if $EXCLUDE_DIRS{$e};
            next if $EXCLUDE_DIRS{$rel_child};
        } else {
            next if $EXCLUDE_FILES{$e};
            next if $EXCLUDE_FILES{$rel_child};
            next if $e =~ $EXCLUDE_RE;
            # `.about` files are metadata for siblings — never render.
            next if $e eq '.about';
            next if $e =~ /\.about\z/;
        }
        push @entries, {
            name   => $e,
            abs    => $abs_child,
            rel    => $rel_child,
            is_dir => (-d $abs_child) ? 1 : 0,
        };
    }
    closedir $dh;

    # Sort: strict alphabetical (files and dirs interleaved). Underscore
    # sorts before letters by default which gives us _install-bin-helper.pl
    # at the top of scripts/.
    @entries = sort { $a->{name} cmp $b->{name} } @entries;

    for my $rec (@entries) {
        $rec->{children} = $rec->{is_dir} ? walk($rec->{abs}, $rec->{rel}) : [];
    }
    return \@entries;
}

# ── Description resolution ────────────────────────────────────────
sub trim {
    my $s = shift // '';
    $s =~ s/\r//g;            # CRLF defense
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

sub describe {
    my ($abs, $rel, $is_dir) = @_;

    # 1. Sidecar `.about`.
    my $about = $is_dir ? "$abs/.about" : "$abs.about";
    if (-f $about) {
        open my $fh, '<:raw', $about or return '';
        my $line = <$fh>;
        close $fh;
        my $t = trim($line);
        return $t if length $t;
    }

    # 2. Plugin dir.
    if ($is_dir && $rel =~ m{^plugins/[^/]+\z}) {
        my $manifest = "$abs/.claude-plugin/plugin.json";
        if (-f $manifest) {
            my $d = _read_json_field($manifest, 'description');
            return _first_sentence(trim($d), 80) if defined $d && length trim($d);
        }
    }

    # 3. SKILL.md file — fall back to frontmatter description, but ONLY
    #    if the parent skill dir doesn't already have its own description
    #    (in a .about). That way each skill gets exactly one description
    #    line: on the dir if hand-tuned, on SKILL.md if relying on
    #    natural metadata. Never both.
    if (!$is_dir && $rel =~ m{/SKILL\.md\z}) {
        my $parent_abs = $abs;
        $parent_abs =~ s{/SKILL\.md$}{};
        return '' if -f "$parent_abs/.about";  # parent dir already speaks for the skill

        my $d = _read_skill_description($abs);
        return _first_sentence(trim($d), 80) if defined $d && length trim($d);
    }

    # 4. Script header.
    if (!$is_dir && $rel =~ /\.(?:pl|pm|sh|ps1)\z/) {
        my $d = _read_script_header($abs);
        return _first_sentence(trim($d), 80) if defined $d && length trim($d);
    }

    return '';
}

sub _read_json_field {
    my ($path, $field) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $data = eval { decode_json(<$fh>) };
    close $fh;
    return undef unless ref($data) eq 'HASH';
    my $v = $data->{$field};
    # decode_json returns DECODED (wide) characters; every other description
    # source in this script (.about, SKILL.md, script headers, and the README
    # itself) is read via `<:raw>` as UTF-8 *bytes*. Normalize back to bytes so
    # that a plugin description containing a non-ASCII char (e.g. an em-dash)
    # compares equal in --check instead of drifting forever (wide char vs the
    # UTF-8 bytes --write emitted).
    utf8::encode($v) if defined $v && !ref $v;
    return $v;
}

sub _read_skill_description {
    my $path = shift;
    open my $fh, '<:raw', $path or return undef;
    my @ls = <$fh>;
    close $fh;
    @ls = map { my $x = $_; $x =~ s/\r//g; $x } @ls;
    return undef unless @ls && $ls[0] =~ /^---\s*$/;

    my $desc;
    my $i = 1;
    while ($i < @ls) {
        my $l = $ls[$i];
        last if $l =~ /^---\s*$/;
        if ($l =~ /^description:\s*(.*?)\s*$/) {
            $desc = $1;
            # YAML block scalar marker (`>`, `>-`, `|`, `|-`) means the
            # actual content is on the indented lines below. Discard the
            # marker so we don't render `>- Launches a headed Chrome...`
            # as the description.
            my $is_block = ($desc =~ /^[>|][-+]?\s*$/);
            if (!length $desc || $is_block) {
                $i++;
                my @cont;
                while ($i < @ls && $ls[$i] =~ /^\s+(.+?)\s*$/) {
                    push @cont, $1;
                    $i++;
                }
                $desc = join ' ', @cont;
                last;
            }
            # Single-line value, possibly with indented continuations.
            $i++;
            while ($i < @ls && $ls[$i] =~ /^\s+\S/) {
                my $c = $ls[$i];
                $c =~ s/^\s+|\s+$//g;
                $desc .= ' ' . $c;
                $i++;
            }
            last;
        }
        $i++;
    }
    return $desc;
}

# Second-line-of-header convention: line 1 is `# <filename> — purpose`
# (or shebang), subsequent comment lines refine. We take the FIRST
# substantive description, with the convention that line 1 may be
# `# <filename> — short desc` and that itself is acceptable.
sub _read_script_header {
    my $path = shift;
    open my $fh, '<:raw', $path or return undef;
    my $line_no = 0;
    my @comments;
    while (my $line = <$fh>) {
        $line_no++;
        last if $line_no > 12;
        $line =~ s/\r//g;
        chomp $line;
        next if $line =~ /^#!/;        # shebang
        next if $line =~ /^\s*$/;      # blank
        last unless $line =~ /^\s*#\s?(.*)$/;
        push @comments, $1;
    }
    close $fh;
    return undef unless @comments;

    # If the first comment is `<filename> — desc`, take the part after `— `.
    if ($comments[0] =~ /^\S+\.(?:pl|pm|sh|ps1)\s+(?:\xE2\x80\x94|--)\s+(.+)$/) {
        return $1;
    }
    return $comments[0];
}

sub _first_sentence {
    my ($s, $cap) = @_;
    $s //= '';
    $cap //= 80;
    # First sentence (cut at `. ` or `! ` or `? `).
    if (length($s) > 20 && $s =~ /^(.{15,}?[.!?])\s/) {
        $s = $1;
    }
    # Hard cap on length.
    if (length($s) > $cap) {
        $s = substr($s, 0, $cap - 1) . "…";
    }
    return $s;
}

# ── Bootstrap mode ────────────────────────────────────────────────
# Parse current README tree → write .about sidecars for each entry
# with a non-empty description.

sub do_bootstrap {
    open my $rfh, '<:raw', $README or die "Cannot open $README: $!\n";
    my @lines = <$rfh>;
    close $rfh;

    my ($beg, $end);
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /<!--\s*BEGIN-FILE-TREE\s*-->/) { $beg = $i }
        elsif ($lines[$i] =~ /<!--\s*END-FILE-TREE\s*-->/) { $end = $i; last }
    }
    die "gen-readme-tree.pl: BEGIN-FILE-TREE / END-FILE-TREE markers not found in $README\n"
        unless defined $beg && defined $end;

    my (@tree_body, $in_fence);
    for my $i (($beg + 1) .. ($end - 1)) {
        if ($lines[$i] =~ /^```/) { $in_fence = !$in_fence; next }
        push @tree_body, $lines[$i] if $in_fence;
    }

    my $INDENT = qr/(?:\xE2\x94\x82\x20\x20\x20|\x20{4})/;
    my $MARKER = qr/(?:\xE2\x94\x9C|\xE2\x94\x94)\xE2\x94\x80\xE2\x94\x80\x20/;

    my (@stack, %parsed);
    my $root_seen = 0;
    for my $l (@tree_body) {
        $l =~ s/\r//g;
        chomp $l;
        next if $l =~ /^\s*$/;
        if (!$root_seen) { $root_seen = 1; next }
        if ($l =~ /^($INDENT*)$MARKER(.+?)(?:\s+#\s*(.*?))?\s*$/) {
            my ($indent, $name, $desc) = ($1, $2, $3 // '');
            $name =~ s/\s+$//;
            $name =~ s{/$}{};
            my $depth = 1;
            while ($indent =~ /$INDENT/g) { $depth++ }
            $#stack = $depth - 2;
            $stack[$depth - 1] = $name;
            my $full = join '/', @stack;
            $parsed{$full} = $desc if length $desc;
        }
    }

    my $written = 0;
    my $skipped = 0;
    for my $rel (sort keys %parsed) {
        my $desc = $parsed{$rel};
        my $abs  = "$REPO_ROOT/$rel";
        my $is_dir = -d $abs ? 1 : 0;

        # Decide where to put the sidecar.
        my $about_path;
        if ($is_dir) {
            $about_path = "$abs/.about";
        } elsif (-e $abs) {
            $about_path = "$abs.about";
        } else {
            warn "  skipped (path not found on disk): $rel\n";
            $skipped++;
            next;
        }

        # Don't overwrite an existing .about — assume hand-tuned.
        if (-f $about_path) {
            $skipped++;
            next;
        }

        # Skip if the description would be redundant (natural source already
        # produces an equivalent caption).
        # Cheap test: does plugin/skill/script extraction already give us
        # the same description? If yes, skip writing the sidecar — keep the
        # repo lean. If different, write the sidecar to preserve editorial.
        my $natural = '';
        # Fake the resolution by re-running it without considering .about.
        # We do it inline rather than refactoring describe(), since this
        # is a one-shot path.
        if ($is_dir && $rel =~ m{^plugins/[^/]+\z}) {
            my $m = "$abs/.claude-plugin/plugin.json";
            if (-f $m) {
                my $d = _read_json_field($m, 'description');
                $natural = _first_sentence(trim($d), 80) if defined $d;
            }
        } elsif ($is_dir && -f "$abs/SKILL.md") {
            my $d = _read_skill_description("$abs/SKILL.md");
            $natural = _first_sentence(trim($d), 80) if defined $d;
        } elsif (!$is_dir && $rel =~ /\.(?:pl|pm|sh|ps1)\z/) {
            my $d = _read_script_header($abs);
            $natural = _first_sentence(trim($d), 80) if defined $d;
        }
        if ($natural eq $desc) {
            $skipped++;
            next;
        }

        # Make parent dir if necessary (it should already exist since
        # the path is on disk, but defensive).
        make_path(dirname($about_path)) unless -d dirname($about_path);

        open my $afh, '>:raw', $about_path or do {
            warn "Cannot write $about_path: $!\n";
            $skipped++;
            next;
        };
        print $afh $desc, "\n";
        close $afh;
        $written++;
    }

    print "gen-readme-tree.pl: bootstrap wrote $written .about file(s), skipped $skipped.\n";
    print "Next: run `perl scripts/gen-readme-tree.pl --check` to confirm no drift.\n";
    exit 0;
}

# ── Render ────────────────────────────────────────────────────────
sub do_render {
    my $tree = walk($REPO_ROOT, '');

    my @nodes;  # { line, desc }

    my $emit;
    $emit = sub {
        my ($node, $prefix, $is_last) = @_;
        my $marker = $is_last
            ? "\xE2\x94\x94\xE2\x94\x80\xE2\x94\x80 "
            : "\xE2\x94\x9C\xE2\x94\x80\xE2\x94\x80 ";
        my $name = $node->{name} . ($node->{is_dir} ? '/' : '');
        my $line = $prefix . $marker . $name;
        my $desc = describe($node->{abs}, $node->{rel}, $node->{is_dir});
        $desc = trim($desc);
        push @nodes, { line => $line, desc => $desc };

        if (@{$node->{children}}) {
            my $cp = $prefix . ($is_last ? "    " : "\xE2\x94\x82   ");
            my $n  = scalar @{$node->{children}};
            for my $j (0 .. $n - 1) {
                $emit->($node->{children}[$j], $cp, ($j == $n - 1));
            }
        }
    };

    push @nodes, { line => "ccpraxis/", desc => '' };
    my $top = scalar @$tree;
    for my $j (0 .. $top - 1) {
        $emit->($tree->[$j], '', ($j == $top - 1));
    }

    # Print-width helper (UTF-8 multibyte chars count as one column each).
    my $pw = sub {
        my $s = shift;
        my $b = length $s;
        my $extra = 0;
        while ($s =~ /([\xC0-\xFF])/g) {
            my $byte = ord $1;
            if    (($byte & 0xE0) == 0xC0) { $extra += 1 }
            elsif (($byte & 0xF0) == 0xE0) { $extra += 2 }
            elsif (($byte & 0xF8) == 0xF0) { $extra += 3 }
        }
        return $b - $extra;
    };

    my $col = 0;
    for my $rec (@nodes) {
        next unless length $rec->{desc};
        my $w = $pw->($rec->{line});
        $col = $w if $w > $col;
    }
    $col = 40 if $col < 40;
    $col += 2;

    my @rendered;
    for my $rec (@nodes) {
        if (length $rec->{desc}) {
            my $cur = $pw->($rec->{line});
            my $pad = $col - $cur;
            $pad = 2 if $pad < 2;
            push @rendered, $rec->{line} . (' ' x $pad) . '# ' . $rec->{desc};
        } else {
            push @rendered, $rec->{line};
        }
    }

    return [\@nodes, join("\n", @rendered) . "\n"];
}

# ── Main ──────────────────────────────────────────────────────────
do_bootstrap() if $mode eq 'bootstrap';

my ($nodes, $new_block) = @{ do_render() };

open my $rfh, '<:raw', $README or die "Cannot open $README: $!\n";
my @lines = <$rfh>;
close $rfh;

my ($beg, $end);
for my $i (0 .. $#lines) {
    if    ($lines[$i] =~ /<!--\s*BEGIN-FILE-TREE\s*-->/) { $beg = $i }
    elsif ($lines[$i] =~ /<!--\s*END-FILE-TREE\s*-->/) { $end = $i; last }
}
unless (defined $beg && defined $end) {
    print STDERR "gen-readme-tree.pl: markers not found in $README\n";
    exit 2;
}

my ($code_beg, $code_end);
for my $i (($beg + 1) .. ($end - 1)) {
    if ($lines[$i] =~ /^```/) {
        if (!defined $code_beg) { $code_beg = $i }
        else                    { $code_end = $i; last }
    }
}
unless (defined $code_beg && defined $code_end) {
    print STDERR "gen-readme-tree.pl: no fenced code block found between markers\n";
    exit 2;
}

my $existing = join '', @lines[($code_beg + 1) .. ($code_end - 1)];

if ($mode eq 'check') {
    if ($existing eq $new_block) {
        print "gen-readme-tree.pl: OK — README tree matches disk + per-module metadata.\n";
        exit 0;
    }
    print STDERR "gen-readme-tree.pl: DRIFT — README tree section is out of date.\n";
    print STDERR "Run `perl scripts/gen-readme-tree.pl --write` to regenerate.\n";
    exit 1;
}

# --write
splice @lines, $code_beg + 1, $code_end - $code_beg - 1, $new_block;
open my $wfh, '>:raw', $README or die "Cannot write $README: $!\n";
print $wfh @lines;
close $wfh;

my $missing = grep { !length $_->{desc} && $_->{line} ne 'ccpraxis/' } @$nodes;
print "gen-readme-tree.pl: wrote $README.\n";
if ($missing) {
    print STDERR "  ($missing entr", ($missing == 1 ? 'y has' : 'ies have'),
        " no description — add a `.about` sidecar, plugin.json/SKILL.md description,\n";
    print STDERR "  or comment header to surface one.)\n";
}

exit 0;
