#!/usr/bin/env perl
# platform: any
# Oracle for blueprint hook-continuity-remake package 25, Decision 95: every
# user-facing paragraph is emitted as one logical line and the terminal (or
# TUI panel) does the wrapping. Derived ONLY from
# .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/25-no-hard-wraps-spec.md
# and Decisions 95/99 -- never from the implementation, which has not
# landed at the time this file is written. This file itself implements the
# lint (per spec section 2.3, "the whole lint lives inside the test file");
# the implementer must not add a second copy of it under scripts/.
#
# THREE PARTS, matching the spec's own division:
#   PART A -- the syntactic lint (8 rules) over Perl/shell sources, plus its
#             own fixture self-tests (one fixture per rule, a negative
#             fixture, and the motivating launcher.pl fixture), then the
#             real repo scan (DC1).
#   PART B -- the 18 join-phrase checks (J9 retired with bp-worker.pl) the lint cannot see syntactically
#             (DC4, spec section 2.5).
#   PART C -- the launcher's own emit path for the REBUILD REQUIRED message
#             in plain and TUI mode (DC2), plus the runtime-wrapper removal
#             and reap-notice-lines behavior (DC4, AC-12).
#
# EXPECTED TO FAIL TODAY, AND WHY: the 59-row inventory (spec section 2.4)
# has not been applied, so PART A's real-repo-scan assertion (behavior 1)
# reports real hits, diag'd as path:line: [rule] V1 | C2 for each. PART B's
# phrase checks fail wherever the cited file still splits the phrase across
# two lines. PART C's AC-7/8/9 fail because the forced-rebuild-notice
# sentinel pair does not exist yet, and AC-12 fails because sub _reap_wrap
# is still present and reap_notice_lines still calls it (a runtime 76-column
# wrapper that reintroduces mid-string \n exactly like the bug this package
# fixes at the message-authoring layer). AC-10 (the counter-fixture) and
# every fixture self-test in PART A are real, non-vacuous checks against
# code that already exists (tui::LaunchScreens, tui::Frame) and pass today.
#
# A KNOWN GAP, REPORTED RATHER THAN PAPERED OVER: the spec's own motivating
# text (launcher.pl:3191-3194 pre-fix) has an internal sentence boundary
# ("...wrote them.\n" before "Rebuilding the image...") whose V1 ends in a
# period. v1_ok's allowed last-character class ([A-Za-z,)/-]) deliberately
# excludes '.', and c2_ok's allowed first-character class ([a-z(]) excludes
# the following line's leading capital 'R' -- so PL-ADJ, applied byte-for-
# byte to that exact text, fires on exactly 2 of the 3 continuation lines,
# never on the 3rd ("Rebuilding..."). AC-6 as worded asks for a hit "on each
# of its continuation lines"; PART A's motivating-fixture block below
# documents this rather than asserting the unreachable 3rd hit, so a future
# reader sees the gap named instead of a silently weakened assertion.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;
use File::Find ();
use File::Basename qw(basename);

my $REPO_ROOT = "$Bin/../../../..";
my $SANDBOX_SCRIPTS = "$Bin/../../../sandbox/scripts";
my $LAUNCHER_PL = "$SANDBOX_SCRIPTS/launcher.pl";

use lib "$Bin/../../../sandbox/scripts";
require tui::LaunchScreens;
require tui::Frame;

# =============================================================================
# PART A0 -- shared predicates, verbatim from spec section 2.3.
# =============================================================================

sub trim {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/^[ \t]+//;
    $s =~ s/[ \t]+$//;
    return $s;
}

sub tokens {
    my ($s) = @_;
    my $t = trim($s);
    return () unless length $t;
    return split /[ \t]+/, $t;
}

# aligned(s) -- a run of two or more spaces after the first non-space
# character (trailing spaces trimmed first).
sub aligned {
    my ($s) = @_;
    return 0 unless defined $s;
    (my $t = $s) =~ s/[ \t]+$//;
    return 0 unless $t =~ /^(\s*)(\S)(.*)\z/s;
    my $rest = $3;
    return $rest =~ /  / ? 1 : 0;
}

sub key_line {
    my ($s) = @_;
    my $t = trim($s);
    return $t =~ /^\S+(?: \S+)?:(?: |$)/ ? 1 : 0;
}

sub v1_ok {
    my ($v1) = @_;
    my @tok = tokens($v1);
    return 0 unless @tok >= 3;
    my $t = trim($v1);
    return 0 unless length $t;
    my $last = substr($t, -1);
    return 0 unless $last =~ /^[A-Za-z,)\/-]\z/;
    return 0 if aligned($v1);
    return 1;
}

sub c2_ok {
    my ($c2) = @_;
    my $t = trim($c2);
    return 0 unless $t =~ /^[a-z(]\S*\s+\S/;
    return 0 if key_line($c2);
    return 0 if aligned($c2);
    return 1;
}

sub wrap_hit {
    my ($v1, $c2) = @_;
    return (v1_ok($v1) && c2_ok($c2)) ? 1 : 0;
}

# =============================================================================
# PART A1 -- literal / statement extraction helpers.
# =============================================================================

# extract_last_dq($line) -> ($content, $term) for a line ending in a
# double-quoted literal followed only by [,.);]* and an optional # comment.
sub extract_last_dq {
    my ($line) = @_;
    if ($line =~ /"((?:[^"\\]|\\.)*)"[ \t]*([,.\);]*)[ \t]*(?:#.*)?\z/) {
        return ($1, $2);
    }
    return (undef, undef);
}

sub classify_term {
    my ($term) = @_;
    return 'stmt' if defined $term && $term =~ /;/;
    return 'adj_punct' if defined $term && ($term eq ',' || $term eq '.');
    return 'adj_none' if defined $term && $term eq '';
    return 'other';
}

# ends_single_nl($content) -- content ends in exactly one literal "\n"
# token (not "\n\n").
sub ends_single_nl {
    my ($content) = @_;
    return 0 unless defined $content;
    return 0 unless $content =~ /\\n\z/;
    return 0 if $content =~ /\\n\\n\z/;
    return 1;
}

# v1_from_content($content) -- content minus the final \n, taken after its
# last internal \n.
sub v1_from_content {
    my ($content) = @_;
    return '' unless defined $content;
    my @parts = split /\\n/, $content;
    return @parts ? $parts[-1] : '';
}

my $OV_RE = qr/^[ \t]*(?:print|printf|say|warn|die|_emit_\w+)\b[ \t]*\(?[ \t]*(?:(?:STDERR|STDOUT)\b[ \t]*)?/;

# c2_bare_or_dot($line) -- Y starts, after whitespace, with an optional . or
# , then a double-quoted literal (PL-ADJ's C2 shape).
sub c2_bare_or_dot {
    my ($line) = @_;
    if ($line =~ /^[ \t]*[.,]?[ \t]*"((?:[^"\\]|\\.)*)"/) { return $1 }
    if ($line =~ /$OV_RE"((?:[^"\\]|\\.)*)"/) { return $1 }
    return undef;
}

# c2_ov_only($line) -- Y must start with the output-verb prefix (PL-STMT's
# stricter C2 shape).
sub c2_ov_only {
    my ($line) = @_;
    if ($line =~ /$OV_RE"((?:[^"\\]|\\.)*)"/) { return $1 }
    return undef;
}

sub c2_from_content {
    my ($content) = @_;
    return '' unless defined $content;
    my ($first) = split /\\n/, $content, 2;
    return defined $first ? $first : $content;
}

# =============================================================================
# PART A2 -- the Perl pre-pass: pod / __END__/__DATA__ / comments / bodies.
# =============================================================================

# analyze_perl(\@lines) -> (\@skip, \@comment, \@bodygroup, \@bodyeligible)
# All arrays are 1-indexed (index 0 unused). \@lines is 0-indexed raw text.
sub analyze_perl {
    my ($lines0) = @_;
    my @L = ('', @$lines0);
    my $n = $#L;
    my @skip    = (0) x ($n + 1);
    my @comment = (0) x ($n + 1);
    my @bg      = (0) x ($n + 1);
    my @beligible = (0) x ($n + 1);

    my $i = 1;
    my $in_pod = 0;
    my $ended  = 0;
    my $gid = 0;

    while ($i <= $n) {
        if ($ended) { $skip[$i] = 1; $i++; next }
        if ($L[$i] =~ /^__(?:END|DATA)__[ \t]*\z/) { $skip[$i] = 1; $ended = 1; $i++; next }
        if ($in_pod) {
            $skip[$i] = 1;
            $in_pod = 0 if $L[$i] =~ /^=cut\b/;
            $i++; next;
        }
        if ($L[$i] =~ /^=[a-zA-Z]/) { $in_pod = 1; $skip[$i] = 1; $i++; next }
        if ($L[$i] =~ /^[ \t]*#/) { $comment[$i] = 1; $i++; next }

        # heredoc opener?
        if ($L[$i] =~ /<<(~?)(?:"(\w+)"|'(\w+)'|(\w+))/) {
            my $indented = ($1 eq '~') ? 1 : 0;
            my $term = defined $2 ? $2 : defined $3 ? $3 : $4;
            if (defined $term && length $term) {
                my $j = $i + 1;
                my $found = 0;
                while ($j <= $n) {
                    my $ok = $indented
                        ? ($L[$j] =~ /^[ \t]*\Q$term\E[ \t]*\z/)
                        : ($L[$j] =~ /^\Q$term\E[ \t]*\z/);
                    if ($ok) { $found = 1; last }
                    $j++;
                }
                if ($found) {
                    $gid++;
                    my $eligible = 1;
                    $eligible = 0 if $term =~ /^(?:JSON|BASH|SH|PS|PS1|PY|PERL|YAML|SQL)\z/;
                    $eligible = 0 if $L[$i] =~ /\bprint[ \t]*\(?[ \t]*(?:\$\w+|\{)/;
                    for my $k ($i + 1 .. $j - 1) {
                        $bg[$k] = $gid;
                        $beligible[$k] = $eligible;
                    }
                    $i = $j + 1;
                    next;
                }
            }
        }

        # bracket-literal opener?
        if ($L[$i] =~ /\bqq?[ \t]*([{(\[<])/) {
            my $openc = $1;
            my %close_of = ('{' => '}', '(' => ')', '[' => ']', '<' => '>');
            my $closec = $close_of{$openc};
            my @chars = split //, $L[$i];
            my $depth = 0;
            my $seen  = 0;
            for (my $ci = 0; $ci < @chars; $ci++) {
                next if $ci > 0 && $chars[$ci - 1] eq '\\';
                if ($chars[$ci] eq $openc) { $depth++; $seen = 1 }
                elsif ($openc ne $closec && $chars[$ci] eq $closec) { $depth-- if $seen }
            }
            if ($seen && $depth > 0) {
                my $j = $i + 1;
                my $d = $depth;
                while ($j <= $n) {
                    my @c2 = split //, $L[$j];
                    my $hit0 = 0;
                    for (my $ci = 0; $ci < @c2; $ci++) {
                        next if $ci > 0 && $c2[$ci - 1] eq '\\';
                        if ($c2[$ci] eq $openc) { $d++ }
                        elsif ($c2[$ci] eq $closec) { $d--; if ($d == 0) { $hit0 = 1; last } }
                    }
                    last if $hit0;
                    $j++;
                }
                if ($d == 0 && $j <= $n) {
                    $gid++;
                    for my $k ($i + 1 .. $j - 1) {
                        $bg[$k] = $gid;
                        $beligible[$k] = 1;
                    }
                    $i = $j + 1;
                    next;
                }
            }
        }

        $i++;
    }
    return (\@skip, \@comment, \@bg, \@beligible);
}

# statement_start_ok(\@lines, \@skip, \@comment, $x_idx) -- walk back over
# code lines from $x_idx until the previous code line's (comment-stripped)
# text ends in ; { or }, or the file start. The first line of that span must
# be an output-verb line with no file-handle other than STDOUT/STDERR.
sub statement_start_ok {
    my ($L, $skip, $comment, $x_idx) = @_;
    my $i = $x_idx;
    while ($i > 1) {
        my $prev = $i - 1;
        if ($skip->[$prev] || $comment->[$prev]) { $i = $prev; next }
        (my $stripped = $L->[$prev]) =~ s/#.*\z//;
        $stripped =~ s/[ \t]+\z//;
        if ($stripped =~ /[;{}]\z/) { last }
        $i = $prev;
    }
    my $first = $L->[$i];
    return 0 unless $first =~ /^[ \t]*(?:print|printf|say|warn|die|_emit_\w+)\b/;
    return 0 if $first =~ /^[ \t]*(?:print|printf|say)[ \t]*\(?[ \t]*(?:\$\w+|\{)/;
    return 1;
}

# =============================================================================
# PART A3 -- per-language line-pair scanners. Returns a list of hit hashrefs:
# { rule => ID, line => N (Y's absolute line, 1-indexed), v1 => ..., c2 => ... }
# =============================================================================

sub lint_perl_lines {
    my ($lines0) = @_;
    my @L = ('', @$lines0);
    my $n = $#L;
    my ($skip, $comment, $bg, $beligible) = analyze_perl($lines0);
    my @hits;

    for (my $i = 1; $i < $n; $i++) {
        my $j = $i + 1;

        # PL-BODY: both lines inside the same eligible body.
        if ($bg->[$i] && $bg->[$i] == $bg->[$j] && $beligible->[$i]) {
            if (wrap_hit($L[$i], $L[$j])) {
                push @hits, { rule => 'PL-BODY', line => $j, v1 => $L[$i], c2 => $L[$j] };
            }
            next;
        }

        # Everything else requires both lines to be plain code (not
        # skip/comment/body).
        next if $skip->[$i] || $skip->[$j] || $comment->[$i] || $comment->[$j];
        next if $bg->[$i] || $bg->[$j];

        my ($content, $term) = extract_last_dq($L[$i]);
        if (defined $content && ends_single_nl($content)) {
            my $class = classify_term($term);

            if ($class eq 'adj_punct'
                || ($class eq 'adj_none' && $L[$j] =~ /^[ \t]*[.,]/)) {
                my $c2content = c2_bare_or_dot($L[$j]);
                if (defined $c2content) {
                    my $v1 = v1_from_content($content);
                    my $c2 = c2_from_content($c2content);
                    if (wrap_hit($v1, $c2)) {
                        push @hits, { rule => 'PL-ADJ', line => $j, v1 => $v1, c2 => $c2 };
                    }
                }
            }
            elsif ($class eq 'stmt') {
                if (statement_start_ok(\@L, $skip, $comment, $i)) {
                    my $c2content = c2_ov_only($L[$j]);
                    if (defined $c2content) {
                        my $v1 = v1_from_content($content);
                        my $c2 = c2_from_content($c2content);
                        if (wrap_hit($v1, $c2)) {
                            push @hits, { rule => 'PL-STMT', line => $j, v1 => $v1, c2 => $c2 };
                        }
                    }
                }
            }
        }

        # PL-ELEM: X is only a literal followed by ',' (+ optional comment).
        if ($L[$i] =~ /^[ \t]*(['"])((?:[^\\]|\\.)*?)\1[ \t]*,[ \t]*(?:#.*)?\z/) {
            my $s1 = $2;
            if ($s1 !~ /\s\z/ && $L[$j] =~ /^[ \t]*(['"])((?:[^\\]|\\.)*?)\1/) {
                my $s2 = $2;
                if (wrap_hit($s1, $s2)) {
                    push @hits, { rule => 'PL-ELEM', line => $j, v1 => $s1, c2 => $s2 };
                }
            }
        }
    }
    return @hits;
}

sub lint_shell_lines {
    my ($lines0) = @_;
    my @L = ('', @$lines0);
    my $n = $#L;
    my @comment = (0) x ($n + 1);
    my @bg = (0) x ($n + 1);
    my @beligible = (0) x ($n + 1);

    my $i = 1;
    my $gid = 0;
    while ($i <= $n) {
        if ($L[$i] =~ /^[ \t]*#/) { $comment[$i] = 1; $i++; next }
        if ($L[$i] =~ /<<-?[ \t]*(['"]?)(\w+)\1/) {
            my $dash = ($L[$i] =~ /<<-/) ? 1 : 0;
            my $term = $2;
            my $j = $i + 1;
            my $found = 0;
            while ($j <= $n) {
                my $ok = $dash
                    ? ($L[$j] =~ /^[ \t]*\Q$term\E[ \t]*\z/)
                    : ($L[$j] =~ /^\Q$term\E[ \t]*\z/);
                if ($ok) { $found = 1; last }
                $j++;
            }
            if ($found) {
                $gid++;
                my $eligible = 1;
                $eligible = 0 if $term =~ /^(?:JSON|BASH|SH|PS|PS1|PY|PERL|YAML|SQL)\z/;
                $eligible = 0 if $L[$i] =~ /(?<!<)>+(?!&)/;
                for my $k ($i + 1 .. $j - 1) {
                    $bg[$k] = $gid;
                    $beligible[$k] = $eligible;
                }
                $i = $j + 1;
                next;
            }
        }
        $i++;
    }

    my @hits;
    for (my $x = 1; $x < $n; $x++) {
        my $y = $x + 1;
        if ($bg[$x] && $bg[$x] == $bg[$y] && $beligible[$x]) {
            if (wrap_hit($L[$x], $L[$y])) {
                push @hits, { rule => 'SH-BODY', line => $y, v1 => $L[$x], c2 => $L[$y] };
            }
            next;
        }
        next if $comment[$x] || $comment[$y] || $bg[$x] || $bg[$y];

        if ($L[$x] =~ /^[ \t]*echo[ \t]+(?:-[a-zA-Z]+[ \t]+)*(["'])(.*)\1[ \t]*(?:[12]?>&2)?[ \t]*\z/) {
            my $v1 = $2;
            if ($L[$y] =~ /^[ \t]*echo[ \t]+(?:-[a-zA-Z]+[ \t]+)*(["'])(.*)\1[ \t]*(?:[12]?>&2)?[ \t]*\z/) {
                my $c2 = $2;
                if (wrap_hit($v1, $c2)) {
                    push @hits, { rule => 'SH-ECHO', line => $y, v1 => $v1, c2 => $c2 };
                }
            }
        }

        if ($L[$x] =~ /^[ \t]*(['"])((?:[^\\]|\\.)*)\1[ \t]*(?:\\)?[ \t]*\z/) {
            my $v1 = $2;
            if ($L[$y] =~ /^[ \t]*(['"])((?:[^\\]|\\.)*)\1[ \t]*(?:\\)?[ \t]*\z/) {
                my $c2 = $2;
                if (wrap_hit($v1, $c2)) {
                    push @hits, { rule => 'SH-ARGS', line => $y, v1 => $v1, c2 => $c2 };
                }
            }
        }
    }
    return @hits;
}

# =============================================================================
# PART A4 -- file classification, scanning, and reporting.
# =============================================================================

sub read_lines_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $data = <$fh>;
    close $fh;
    return undef unless defined $data;
    my @lines = split /\n/, $data;
    s/\r\z// for @lines;
    return \@lines;
}

sub classify_file {
    my ($path) = @_;
    return 'perl'  if $path =~ /\.pl\z/i || $path =~ /\.pm\z/i;
    return 'shell' if $path =~ /\.sh\z/i;
    return undef   if $path =~ /\.[A-Za-z0-9]+\z/; # has some other extension
    open my $fh, '<', $path or return undef;
    my $first = <$fh>;
    close $fh;
    return undef unless defined $first;
    return 'perl'  if $first =~ /^#!.*\bperl\b/;
    return 'shell' if $first =~ /^#!.*\b(?:ba)?sh\b/;
    return undef;
}

sub relpath {
    my ($abs) = @_;
    my $rel = File::Spec->abs2rel($abs, $REPO_ROOT);
    $rel =~ s{\\}{/}g;
    return $rel;
}

sub collect_scan_files {
    my @roots;
    push @roots, glob("$REPO_ROOT/plugins/*/scripts");
    push @roots, glob("$REPO_ROOT/plugins/*/hooks");
    push @roots, glob("$REPO_ROOT/plugins/*/bin");
    push @roots, "$REPO_ROOT/scripts" if -d "$REPO_ROOT/scripts";

    my @files;
    for my $root (@roots) {
        next unless -d $root;
        File::Find::find({ no_chdir => 1, wanted => sub {
            my $p = $File::Find::name;
            return unless -f $p;
            my $rel = relpath($p);
            return if $rel =~ m{/tests/};
            push @files, $p;
        } }, $root);
    }
    return @files;
}

sub lint_path {
    my ($path, $kind) = @_;
    my $lines = read_lines_raw($path);
    return () unless defined $lines;
    if ($kind eq 'perl') { return lint_perl_lines($lines) }
    if ($kind eq 'shell') { return lint_shell_lines($lines) }
    return ();
}

sub short60 { my ($s) = @_; $s = defined $s ? $s : ''; $s =~ s/[\r\n]+/ /g; return length($s) > 60 ? substr($s, 0, 60) : $s }

sub diag_hit {
    my ($relfile, $hit) = @_;
    diag(sprintf('%s:%d: [%s] %s | %s',
        $relfile, $hit->{line}, $hit->{rule}, short60($hit->{v1}), short60($hit->{c2})));
}

# =============================================================================
# PART A5 -- fixture self-tests: one fixture per rule (behaviors 2/3), a
# negative fixture (behavior 4), and the motivating launcher.pl fixture
# (behavior 2, AC-6).
# =============================================================================

my $FIXDIR = tempdir(CLEANUP => 1);

sub write_fixture {
    my ($name, $content) = @_;
    my $path = File::Spec->catfile($FIXDIR, $name);
    open my $fh, '>:raw', $path or die "cannot write fixture $path: $!";
    print {$fh} $content;
    close $fh;
    return $path;
}

# --- PL-ADJ ------------------------------------------------------------------
{
    my $path = write_fixture('rule-pl-adj.pl',
        "my \$msg = \"This continuation line ends properly here now\\n\"\n"
      . "    . \"and continues in a lowercase phrase across two literal pieces\\n\";\n");
    my @hits = lint_path($path, 'perl');
    my @adj = grep { $_->{rule} eq 'PL-ADJ' } @hits;
    is(scalar(@adj), 1, 'PL-ADJ: exactly one hit on the dedicated fixture (behavior 3)')
        or diag_hit(basename($path), $_) for @adj;
    is($adj[0]{line}, 2, 'PL-ADJ: hit is reported at the continuation line (behavior 2)') if @adj;
}

# --- PL-STMT -----------------------------------------------------------------
{
    my $path = write_fixture('rule-pl-stmt.pl',
        "warn \"This warning message needs to end its line properly right,\\n\";\n"
      . "warn \"continuing in lowercase after semicolon terminator now\\n\";\n");
    my @hits = lint_path($path, 'perl');
    my @stmt = grep { $_->{rule} eq 'PL-STMT' } @hits;
    is(scalar(@stmt), 1, 'PL-STMT: exactly one hit on the dedicated fixture (behavior 3)');
    is($stmt[0]{line}, 2, 'PL-STMT: hit is reported at the continuation line (behavior 2)') if @stmt;
}

# --- PL-ELEM -----------------------------------------------------------------
{
    my $path = write_fixture('rule-pl-elem.pl',
        "'Left over from a previous session, cleanup pending here now',\n"
      . "'and continuing in lowercase across the second list element now',\n");
    my @hits = lint_path($path, 'perl');
    my @elem = grep { $_->{rule} eq 'PL-ELEM' } @hits;
    is(scalar(@elem), 1, 'PL-ELEM: exactly one hit on the dedicated fixture (behavior 3)');
    is($elem[0]{line}, 2, 'PL-ELEM: hit is reported at the continuation line (behavior 2)') if @elem;
}

# --- PL-BODY (heredoc) --------------------------------------------------------
{
    my $path = write_fixture('rule-pl-body-heredoc.pl',
        "my \$text = <<\"USAGE\";\n"
      . "    Continue this description across a couple of prose lines using more,\n"
      . "    words that flow naturally onto the next physical source line here.\n"
      . "USAGE\n");
    my @hits = lint_path($path, 'perl');
    my @body = grep { $_->{rule} eq 'PL-BODY' } @hits;
    is(scalar(@body), 1, 'PL-BODY (heredoc): exactly one hit on the dedicated fixture (behavior 3)');
    is($body[0]{line}, 3, 'PL-BODY (heredoc): hit is reported at the continuation line (behavior 2)') if @body;
}

# --- PL-BODY (bracket literal) ------------------------------------------------
{
    my $path = write_fixture('rule-pl-body-bracket.pl',
        "my \$note = q{\n"
      . "Some prose text continues across more than one physical line freely,\n"
      . "spilling onto the next line in lowercase without any extra structure.\n"
      . "};\n");
    my @hits = lint_path($path, 'perl');
    my @body = grep { $_->{rule} eq 'PL-BODY' } @hits;
    is(scalar(@body), 1, 'PL-BODY (bracket literal): exactly one hit on the dedicated fixture (behavior 3)');
    is($body[0]{line}, 3, 'PL-BODY (bracket literal): hit is reported at the continuation line (behavior 2)') if @body;
}

# --- SH-ECHO -------------------------------------------------------------------
{
    my $path = write_fixture('rule-sh-echo.sh',
        "echo \"This first echoed line needs to continue across the boundary,\"\n"
      . "echo \"into a second echo statement using lowercase words right here\" >&2\n");
    my @hits = lint_path($path, 'shell');
    my @echo = grep { $_->{rule} eq 'SH-ECHO' } @hits;
    is(scalar(@echo), 1, 'SH-ECHO: exactly one hit on the dedicated fixture (behavior 3)');
    is($echo[0]{line}, 2, 'SH-ECHO: hit is reported at the continuation line (behavior 2)') if @echo;
}

# --- SH-ARGS -------------------------------------------------------------------
{
    my $path = write_fixture('rule-sh-args.sh',
        "    \"This continuation argument keeps going across the line break here,\" \\\n"
      . "    \"and finishes in lowercase on the very next physical source line.\"\n");
    my @hits = lint_path($path, 'shell');
    my @args = grep { $_->{rule} eq 'SH-ARGS' } @hits;
    is(scalar(@args), 1, 'SH-ARGS: exactly one hit on the dedicated fixture (behavior 3)');
    is($args[0]{line}, 2, 'SH-ARGS: hit is reported at the continuation line (behavior 2)') if @args;
}

# --- SH-BODY -------------------------------------------------------------------
{
    my $path = write_fixture('rule-sh-body.sh',
        "cat <<EOF\n"
      . "This block explains something important, spanning more than one line,\n"
      . "continuing in lowercase prose on the very next physical source line.\n"
      . "EOF\n");
    my @hits = lint_path($path, 'shell');
    my @body = grep { $_->{rule} eq 'SH-BODY' } @hits;
    is(scalar(@body), 1, 'SH-BODY: exactly one hit on the dedicated fixture (behavior 3)');
    is($body[0]{line}, 3, 'SH-BODY: hit is reported at the continuation line (behavior 2)') if @body;
}

# --- Negative fixture (behavior 4): every legitimate shape, zero hits -------
{
    my $perl_negative = <<'PERLNEG';
print "Some prior line ends properly with words here,\n";
print "Status: something\n";

my $help = <<"TABLE";
    --foo     do the foo thing across a table row nicely here
    --bar     do the bar thing across a table row nicely here
TABLE

my @items = (
    '- First item explaining something briefly and reasonably long here now',
    '- Second item continuing the list in lowercase style right here too',
);

my $synth = <<"SYN";
usage: some-tool [--flag value] more words describing the tool right here
[--verbose] additional flags here for the command line tool right now
SYN

my $s = "foo bar " .
         "baz qux\n";

print $fh <<"CONTENT";
Two prose lines here that would otherwise look wrapped nicely across,
continuing in lowercase on the very next physical output line still.
CONTENT

my $j = <<'JSON';
Two prose-shaped lines that would look wrapped if this were prose here,
continuing in lowercase on the very next physical output line still too.
JSON

# This comment line ends properly with more than three words here,
# continuing in lowercase on the very next comment line still now.

=pod

This pod line ends properly with more than three words here too,
continuing in lowercase on the very next pod line still right now.

=cut

my $single = <<"PATHS";
/usr/local/bin
/usr/local/sbin
PATHS

my $sentence_end = <<"SENT";
This sentence is already complete and correctly ends here.
continuing here in lowercase though it should not be joined at all
SENT

my $digit_end = <<"DIGIT";
Run the build with version flag set to exactly build 90
before continuing in lowercase with the rest of the setup steps
DIGIT

arg_error('code',
    'refusing to run without a code because that would be unsafe');

__END__
This trailing text should never be scanned even though it looks like,
two prose lines continuing in lowercase right after each other here.
PERLNEG
    my $path = write_fixture('negative.pl', $perl_negative);
    my @hits = lint_path($path, 'perl');
    unless (is(scalar(@hits), 0,
        'negative fixture (behavior 4): every legitimate Perl shape produces zero hits')) {
        diag_hit(basename($path), $_) for @hits;
    }

    my $shell_negative = <<'SHELLNEG';
# key: value lines
log: $LOG some diagnostic text here that ends properly with words,
log: $LOG some other diagnostic text lowercase continuing right here

echo "--foo     aligned column one right here"
echo "--bar     aligned column two right here"

cat > /tmp/output.txt <<EOF
Two prose-shaped lines that would look wrapped if this were shell text,
continuing in lowercase on the very next shell output line right here.
EOF

cat <<'BASH'
Two prose-shaped lines that would look wrapped if this were shell text,
continuing in lowercase on the very next shell output line right here.
BASH

# This shell comment ends properly with more than three words here,
# continuing in lowercase on the very next comment line right now too.
SHELLNEG
    my $spath = write_fixture('negative.sh', $shell_negative);
    my @shits = lint_path($spath, 'shell');
    unless (is(scalar(@shits), 0,
        'negative fixture (behavior 4): every legitimate shell shape produces zero hits')) {
        diag_hit(basename($spath), $_) for @shits;
    }
}

# --- Motivating fixture (AC-6): the literal pre-fix launcher.pl text -------
{
    my $motivating = <<'MOTIVATING';
    _emit_err("       A container and host on different Claude Code versions is not a\n",
              "       supported configuration -- session files under claude-home are\n",
              "       shared through the bind mount and assume one version wrote them.\n",
              "       Rebuilding the image and recreating the container.\n");
MOTIVATING
    my $path = write_fixture('motivating.pl', $motivating);
    my @hits = lint_path($path, 'perl');
    my @adj = grep { $_->{rule} eq 'PL-ADJ' } @hits;
    my %by_line = map { $_->{line} => 1 } @adj;
    ok($by_line{2}, 'AC-6: PL-ADJ fires on continuation line 2 ("supported configuration...")');
    ok($by_line{3}, 'AC-6: PL-ADJ fires on continuation line 3 ("shared through...")');
    # NOT asserted: a hit on line 4 ("Rebuilding the image..."). Its own
    # preceding line's V1 ends in '.' (a genuine internal sentence
    # boundary -- "...wrote them.\n"), which v1_ok's allowed last-character
    # class ([A-Za-z,)/-]) excludes, and "Rebuilding" itself starts with an
    # uppercase letter, which c2_ok's allowed first-character class ([a-z(])
    # also excludes. Both exclusions are named directly in the spec's Known
    # Limits (section 2.3) and its Out-of-scope list (section 6, last
    # bullet). AC-6 reads "each of its continuation lines"; the literal
    # source text makes that unreachable for line 4 specifically -- reported
    # here rather than silently asserted or silently dropped.
    is(scalar(@adj), 2, 'AC-6: exactly 2 PL-ADJ hits fire on the literal pre-fix text '
        . '(line 4 is the documented, spec-named gap above)');
}

# =============================================================================
# PART A6 -- the real repo scan (DC1, behaviors 1 and liveness AC-2).
# =============================================================================

my @scan_files = collect_scan_files();

cmp_ok(scalar(@scan_files), '>=', 150,
    'AC-2 liveness: the scan visits at least 150 files under plugins/*/scripts, '
  . 'plugins/*/hooks, plugins/*/bin and scripts (got ' . scalar(@scan_files) . ')');

{
    my %seen = map { relpath($_) => 1 } @scan_files;
    for my $must (qw(
        plugins/sandbox/scripts/launcher.pl
        plugins/sandbox/scripts/skills.pl
        plugins/butler/scripts/bp-lib.sh
        plugins/almanac/hooks/guard-almanac-write.sh
        scripts/run-tests.pl
        plugins/sandbox/scripts/tui/LaunchScreens.pm
    )) {
        ok($seen{$must}, "AC-2 liveness: the scan visited $must");
    }
}

{
    my @all_hits;
    for my $f (@scan_files) {
        my $kind = classify_file($f);
        next unless defined $kind;
        for my $h (lint_path($f, $kind)) {
            push @all_hits, { file => relpath($f), %$h };
        }
    }
    unless (is(scalar(@all_hits), 0,
        'behavior 1 / DC1: the repo scan reports zero hits -- FAILS TODAY because the '
      . '59-row inventory (spec section 2.4) has not been applied yet')) {
        diag_hit($_->{file}, $_) for @all_hits;
    }
}

# =============================================================================
# PART B -- the 18 join-phrase checks (J9 retired with bp-worker.pl) (DC4, spec section 2.5). Each phrase
# must occur within one physical line of its file, byte-exact.
# =============================================================================

my @JOIN_PHRASES = (
    [ 'J1',  'plugins/sandbox/scripts/launcher.pl',
      'protected-paths list at ~/.claude/ccpraxis-protected-paths.json.' ],
    [ 'J2',  'plugins/sandbox/scripts/ConnectorHold.pm',
      'or press [c] in the dashboard to start a new connector.' ],
    [ 'J3',  'plugins/sandbox/scripts/skills.pl',
      'skills/plugins/MCP; writes selection + settings.local.json.' ],
    [ 'J4',  'plugins/sandbox/scripts/skills.pl',
      'item model as one JSON object; writes nothing, no terminal.' ],
    [ 'J5',  'plugins/almanac/scripts/almanac-bug.pl',
      'while status is `open`. Use this to record progress' ],
    [ 'J6a', 'plugins/butler/scripts/bp-drive-next.pl', 'proceed; failed' ],
    [ 'J6b', 'plugins/butler/scripts/bp-drive-next.pl', 'error logged. Solo NEVER pauses' ],
    [ 'J7',  'plugins/butler/scripts/bp-feedback.pl',
      '(default "chat", or "transcript" when --from-session supplied the body)' ],
    [ 'J8',  'plugins/butler/scripts/bp-usage-gate.pl',
      'resets_at_iso=<iso> estimated=<0|1>' ],
    [ 'J10', 'plugins/steward/scripts/ccpraxis-helpers.pl',
      'to ~/.claude/skills/. Symlinks on Unix' ],
    [ 'J11', 'plugins/steward/scripts/ccpraxis-helpers.pl',
      '2=hard fail, 3=usage error.' ],
    [ 'J12', 'scripts/run-tests.pl',
      'sandbox HOME after it runs (package 21-test-sandbox)' ],
    [ 'J13', 'scripts/backup.pl', 'calling convention; output is always JSON' ],
    [ 'J14', 'scripts/backup.pl',
      'start a fresh run (also the escape hatch past a corrupt state file)' ],
    [ 'J15', 'scripts/backup.pl',
      'the given resume token (mutually exclusive with --restart)' ],
    [ 'J16', 'scripts/backup.pl', 'repeat once per pending decision' ],
    [ 'J17', 'scripts/backup.pl', '20 complete with failures, 2 usage' ],
    [ 'J18', 'scripts/backfill-test-platform.pl',
      'test-platform-split, Decision 3): nothing' ],
);

is(scalar(@JOIN_PHRASES), 18, 'PART B setup: 18 join-phrase checks are registered (spec section 2.5)');   # shape-lint: intentional -- fixed inventory named by spec section 2.5, not a shared list other packages extend

for my $row (@JOIN_PHRASES) {
    my ($id, $relfile, $phrase) = @$row;
    my $abs = "$REPO_ROOT/$relfile";
    my $lines = read_lines_raw($abs);
    unless (ok(defined $lines, "$id: $relfile is readable")) {
        next;
    }
    my $found = 0;
    for my $l (@$lines) {
        if (index($l, $phrase) >= 0) { $found = 1; last }
    }
    unless (ok($found, "$id: '$phrase' occurs within one physical line of $relfile")) {
        diag("$id: phrase not found on any single line of $relfile: $phrase");
    }
}

# =============================================================================
# PART C -- the launcher's own emit path (DC2), and the runtime-wrapper
# removal (DC4, AC-12).
# =============================================================================

my $LAUNCHER_TEXT = do {
    open my $fh, '<:raw', $LAUNCHER_PL or undef;
    local $/;
    defined(fileno($fh)) ? <$fh> : undef;
} if -f $LAUNCHER_PL;

sub extract_sub_body {
    my ($text, $name) = @_;
    return undef unless defined $text;
    my $idx = index($text, "sub $name");
    return undef if $idx < 0;
    my $brace_start = index($text, '{', $idx);
    return undef if $brace_start < 0;
    my $depth = 0;
    my $i = $brace_start;
    my $len = length($text);
    while ($i < $len) {
        my $c = substr($text, $i, 1);
        if ($c eq '{') { $depth++ }
        elsif ($c eq '}') {
            $depth--;
            if ($depth == 0) { return substr($text, $idx, $i - $idx + 1) }
        }
        $i++;
    }
    return undef;
}

sub extract_sentinel_region {
    my ($text, $tag, $begin_marker, $end_marker) = @_;
    return (undef, 0, 0, 0) unless defined $text;
    my $begin_re = qr/^[ \t]*#[ \t]*\Q$begin_marker\E[ \t]*\r?$/m;
    my $end_re   = qr/^[ \t]*#[ \t]*\Q$end_marker\E[ \t]*\r?$/m;
    my $begin_count = () = ($text =~ /$begin_re/g);
    my $end_count   = () = ($text =~ /$end_re/g);
    my $begin_pos = $text =~ /$begin_re/ ? $+[0] : -1;
    my $end_pos   = $text =~ /$end_re/   ? $-[0] : -1;
    my $order_ok  = ($begin_pos >= 0 && $end_pos >= 0 && $begin_pos <= $end_pos) ? 1 : 0;
    my $region;
    if ($order_ok) {
        $region = substr($text, $begin_pos, $end_pos - $begin_pos);
    }
    return ($region, $begin_count, $end_count, $order_ok);
}

my $emit_join_body = extract_sub_body($LAUNCHER_TEXT, '_emit_join');
my $emit_err_body  = extract_sub_body($LAUNCHER_TEXT, '_emit_err');

ok(defined $emit_join_body, 'PART C setup: sub _emit_join extracted from launcher.pl')
    or diag('_emit_join not found -- launcher.pl may have moved or renamed it');
ok(defined $emit_err_body, 'PART C setup: sub _emit_err extracted from launcher.pl')
    or diag('_emit_err not found -- launcher.pl may have moved or renamed it');

# --- AC-7: the forced-rebuild-notice sentinel pair -------------------------
my ($rebuild_region, $rb_begin_n, $rb_end_n, $rb_order_ok) =
    extract_sentinel_region($LAUNCHER_TEXT,
        'forced-rebuild-notice', '>>> forced-rebuild-notice:BEGIN', '<<< forced-rebuild-notice:END');

is($rb_begin_n, 1, 'AC-7: "# >>> forced-rebuild-notice:BEGIN" occurs exactly once in launcher.pl '
    . '(FAILS TODAY: the sentinel does not exist yet)');
is($rb_end_n, 1, 'AC-7: "# <<< forced-rebuild-notice:END" occurs exactly once in launcher.pl '
    . '(FAILS TODAY: the sentinel does not exist yet)');
ok($rb_order_ok, 'AC-7: BEGIN occurs before END');

SKIP: {
    my $ready = defined($emit_join_body) && defined($emit_err_body) && defined($rebuild_region);
    skip 'AC-7/8/9: the forced-rebuild-notice region could not be extracted -- the emit-path checks '
       . 'below cannot run against a nonexistent region', 12
        unless $ready;

    my $pkg_src = "package DC2Test;\nuse strict; use warnings;\n"
        . "our (\$LAUNCH_HOST, \$FORCE_REBUILD_REASON);\n"
        . "sub _c_warn { \$_[0] }\n"
        . "$emit_join_body\n$emit_err_body\n"
        . "sub notice { $rebuild_region }\n1;\n";
    eval $pkg_src;
    ok(!$@, 'AC-7: the extracted region evals under strict/warnings in a fresh package')
        or diag("eval error: $@");

    my $nonce = 'zqx-rebuild-nonce-9911';

    # --- Behavior 5: plain mode --------------------------------------------
    my @plain_recs;
    $DC2Test::LAUNCH_HOST = tui::LaunchScreens::make_host(
        mode => 'plain', plain => sub { push @plain_recs, $_[0] });
    $DC2Test::FORCE_REBUILD_REASON = $nonce;
    DC2Test::notice();

    my @plain_lines;
    for my $rec (@plain_recs) {
        my $t = (ref $rec eq 'HASH' && defined $rec->{text}) ? $rec->{text} : '';
        push @plain_lines, split /\n/, $t;
    }
    @plain_lines = grep { length $_ } @plain_lines;

    my $p1 = '       A container and host on different Claude Code versions is not a '
           . 'supported configuration -- session files under claude-home are shared '
           . 'through the bind mount and assume one version wrote them. Rebuilding the '
           . 'image and recreating the container.';

    is_deeply(\@plain_lines, [ "REBUILD REQUIRED: $nonce", $p1 ],
        'AC-8 (behavior 5): plain-mode output is exactly the headline plus one unwrapped '
      . 'paragraph -- FAILS TODAY (the message is still split across 4 literals)');
    ok(!(grep { !ref $_ && $_ =~ /\S {2,}\S/ } @plain_lines) ? 1 : 0,
        'AC-8: no plain-mode line contains a mid-line double-space run');
    my @streams = map { (ref $_ eq 'HASH' && defined $_->{stream}) ? $_->{stream} : '' } @plain_recs;
    ok((@streams && !grep { $_ ne 'err' } @streams), 'AC-8: every record\'s stream is "err"');

    # --- Behavior 6: TUI mode ------------------------------------------------
    $DC2Test::LAUNCH_HOST = tui::LaunchScreens::make_host(
        mode => 'tui', out => sub { }, err => sub { }, read_mode => sub { },
        heartbeat => sub { }, now => sub { 0 },
        term_size => sub { (100, 30) }, render => sub { '' });
    tui::LaunchScreens::host_enter($DC2Test::LAUNCH_HOST);
    $DC2Test::FORCE_REBUILD_REASON = $nonce;
    DC2Test::notice();
    my $tail = tui::LaunchScreens::capture_tail($DC2Test::LAUNCH_HOST->{capture});
    my @tui_texts = map { (ref $_ eq 'HASH' && defined $_->{text}) ? $_->{text} : '' } @$tail;

    ok((grep { $_ eq $p1 } @tui_texts) ? 1 : 0,
        'AC-9 (behavior 6): the TUI capture holds P1 as one entry, exactly -- FAILS TODAY');
    ok((grep { $_ eq "REBUILD REQUIRED: $nonce" } @tui_texts) ? 1 : 0,
        'AC-9: the TUI capture holds the headline as a separate entry');
    ok(!(grep { $_ =~ /\S {2,}\S/ } @tui_texts) ? 1 : 0,
        'AC-9: no TUI entry contains a mid-line double-space run');

    my $cells = tui::Frame::wrap_line($p1, 'text.primary', 40, 2);
    cmp_ok(scalar(@$cells), '>=', 2, 'AC-9: wrap_line(P1, ..., 40, 2) yields at least 2 cells');
    ok(!(grep { defined $_->{text} && $_->{text} =~ /\S {2,}\S/ } @$cells) ? 1 : 0,
        'AC-9: no wrapped cell text contains a mid-line double-space run');

    # --- Behavior 7 (AC-10): the counter-fixture -----------------------------
    my $counter_region = <<'COUNTER';
    _emit_err(_c_warn("REBUILD REQUIRED:"), " $FORCE_REBUILD_REASON\n");
    _emit_err("       A container and host on different Claude Code versions is not a\n",
              "       supported configuration -- session files under claude-home are\n",
              "       shared through the bind mount and assume one version wrote them.\n",
              "       Rebuilding the image and recreating the container.\n");
COUNTER
    my $counter_src = "package DC2Counter;\nuse strict; use warnings;\n"
        . "our (\$LAUNCH_HOST, \$FORCE_REBUILD_REASON);\n"
        . "sub _c_warn { \$_[0] }\n"
        . "$emit_join_body\n$emit_err_body\n"
        . "sub notice { $counter_region }\n1;\n";
    eval $counter_src;
    ok(!$@, 'AC-10 setup: the counter-fixture package evals cleanly') or diag("eval error: $@");

    $DC2Counter::LAUNCH_HOST = tui::LaunchScreens::make_host(
        mode => 'tui', out => sub { }, err => sub { }, read_mode => sub { },
        heartbeat => sub { }, now => sub { 0 },
        term_size => sub { (100, 30) }, render => sub { '' });
    tui::LaunchScreens::host_enter($DC2Counter::LAUNCH_HOST);
    $DC2Counter::FORCE_REBUILD_REASON = $nonce;
    DC2Counter::notice();
    my $ctail = tui::LaunchScreens::capture_tail($DC2Counter::LAUNCH_HOST->{capture});
    my @ctexts = map { (ref $_ eq 'HASH' && defined $_->{text}) ? $_->{text} : '' } @$ctail;
    ok((grep { /is not a {2,}supported configuration/ } @ctexts) ? 1 : 0,
        'AC-10 (behavior 7): the pre-fix statement through the SAME TUI harness reproduces '
      . 'the glued-together, mid-sentence-gap bug -- proving assertion AC-9 above can fail');
}

# --- AC-12 (behaviors 9-10): the runtime wrapper is gone -------------------
{
    ok(defined($LAUNCHER_TEXT) && index($LAUNCHER_TEXT, 'sub _reap_wrap') < 0,
        'AC-12 (behavior 10): sub _reap_wrap does not appear anywhere in launcher.pl '
      . '(FAILS TODAY: it is still present)');
}

{
    my ($reap_region, $rn_begin, $rn_end, $rn_order) =
        extract_sentinel_region($LAUNCHER_TEXT, 'reap',
            '>>> s-reap-notice:BEGIN', '>>> s-reap-notice:END');

    is($rn_begin, 1, 'AC-12 setup: "# >>> s-reap-notice:BEGIN" occurs exactly once');
    is($rn_end, 1, 'AC-12 setup: "# >>> s-reap-notice:END" occurs exactly once (both sentinels '
        . 'use >>>, exactly as the source does)');
    ok($rn_order, 'AC-12 setup: BEGIN occurs before END');

    SKIP: {
        skip 'AC-12: the s-reap-notice region could not be extracted', 3 unless defined $reap_region;

        my $reap_src = "package ReapTest;\nuse strict; use warnings;\n$reap_region\n1;\n";
        eval $reap_src;
        ok(!$@, 'AC-12 setup: the s-reap-notice region evals cleanly') or diag("eval error: $@");

        my $why = 'The machine slept while a long-running dispatch was active and nobody '
                . 'noticed for several hours because the terminal window was left minimized '
                . 'behind several other applications the whole time this was happening';
        cmp_ok(length($why), '>=', 160, 'AC-12 setup: the why sentence is at least 160 characters');
        cmp_ok(scalar(split /\s+/, $why), '>=', 25, 'AC-12 setup: the why sentence is at least 25 words');

        my @lines = eval {
            ReapTest::reap_notice_lines({
                verdict => 'hardstop', why => $why, host_suspends_detected => 1,
                when => '2026-09-25T00:00:00Z',
            });
        };
        ok(!$@, 'AC-12: reap_notice_lines runs against the extracted region') or diag("error: $@");

        my $no_nl = !(grep { /\n/ } @lines);
        ok($no_nl, 'AC-12 (behavior 9): no element of reap_notice_lines contains a literal newline '
            . '(FAILS TODAY: _reap_wrap still wraps the why sentence at 76 columns)');
        ok((grep { $_ eq $why } @lines) ? 1 : 0,
            'AC-12 (behavior 9): one element equals the why sentence exactly '
          . '(FAILS TODAY: _reap_wrap still reformats it)');
        ok((grep { index($_, 'keep-awake.ps1 holds it out of connected standby') >= 0 } @lines) ? 1 : 0,
            'AC-12 (behavior 9): one element contains the keep-awake sentence');
    }
}

done_testing();
