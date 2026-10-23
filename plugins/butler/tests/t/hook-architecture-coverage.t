#!/usr/bin/env perl
# platform: any
# Oracle for the coverage test package 02-hook-architecture must ship
# (blueprint hook-continuity-remake). Derived ONLY from
# .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/02-hook-architecture-spec.md
# (AC1-AC17). WRITTEN BLIND to any implementation of the design document: the design doc this
# package also writes does not exist on disk yet at authoring time, so the real-tree assertions
# below (AC15, AC17) are EXPECTED to fail on "DOC missing", never on a bug in this file.
#
# coverage_failures(\%paths) is the pure routine the spec's 2.7 requires: no process spawn (no
# system, exec, backticks, qx or piped open), only File::Temp tempdirs get written to, and every
# failure string is tagged [C1]..[C14] naming the offending key/heading/value.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;
use File::Basename qw(basename dirname);
use JSON::PP;

my $ROOT = "$Bin/../../../..";

# ---------------------------------------------------------------------------
# Small IO helpers. No process spawn anywhere in this file.
# ---------------------------------------------------------------------------
sub read_utf8 {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    open(my $fh, '<:encoding(UTF-8)', $path) or return undef;
    local $/;
    my $text = <$fh>;
    close $fh;
    return undef unless defined $text;
    $text =~ s/\r\n/\n/g;
    $text =~ s/\r/\n/g;
    return $text;
}

sub write_utf8 {
    my ($path, $text) = @_;
    open(my $fh, '>:encoding(UTF-8)', $path) or die "write $path: $!";
    print $fh $text;
    close $fh;
    return $path;
}

sub decode_json_file {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    my $text = read_utf8($path);
    return undef unless defined $text;
    my $data = eval { JSON::PP->new->decode($text) };
    return $data;
}

sub list_hooks_dir_files {
    my ($dir) = @_;
    return () unless defined $dir && -d $dir;
    opendir(my $dh, $dir) or return ();
    my @files;
    for my $e (readdir $dh) {
        next if $e eq '.' || $e eq '..';
        my $full = File::Spec->catfile($dir, $e);
        push @files, $e if -f $full;
    }
    closedir $dh;
    return sort @files;
}

sub root_from_hooks_dir {
    my ($hooks_dir) = @_;
    return undef unless defined $hooks_dir;
    my $d = $hooks_dir;
    $d = dirname($d) for (1 .. 3);
    return $d;
}

sub trim { my ($s) = @_; return '' unless defined $s; $s =~ s/^\s+|\s+$//g; return $s; }

sub strip_backticks {
    my ($s) = @_;
    $s = trim($s);
    $s =~ s/^`//;
    $s =~ s/`$//;
    return trim($s);
}

sub words_count {
    my ($s) = @_;
    return 0 unless defined $s;
    my @w = grep { length } split /\s+/, trim($s);
    return scalar @w;
}

# ---------------------------------------------------------------------------
# JSON registration parsing (2.3 script-token rules; 5 "missing/unexpected
# JSON structure": no "hooks" key -> zero registrations, not an error).
# ---------------------------------------------------------------------------
sub compute_script_token {
    my ($type, $command) = @_;
    if (!defined $type || $type ne 'command') {
        return defined $type ? "type:$type" : trim($command // '');
    }
    return trim($command // '') unless defined $command;
    for my $tok (split /\s+/, $command) {
        (my $stripped = $tok) =~ s/^["']//;
        $stripped =~ s/["']$//;
        if ($stripped =~ /\.(sh|pl)$/) {
            my @parts = split m{/}, $stripped;
            return $parts[-1];
        }
    }
    return trim($command);
}

sub parse_registrations_from_json_struct {
    my ($data, $source) = @_;
    my @regs;
    return @regs unless ref $data eq 'HASH' && ref $data->{hooks} eq 'HASH';
    for my $event (sort keys %{ $data->{hooks} }) {
        my $groups = $data->{hooks}{$event};
        next unless ref $groups eq 'ARRAY';
        for my $group (@$groups) {
            my $matcher = defined $group->{matcher} ? $group->{matcher} : '';
            my $hooks = $group->{hooks};
            next unless ref $hooks eq 'ARRAY';
            for my $h (@$hooks) {
                my $script = compute_script_token($h->{type}, $h->{command});
                push @regs, { source => $source, event => $event, matcher => $matcher, script => $script };
            }
        }
    }
    return @regs;
}

sub reg_key {
    my ($r) = @_;
    return "registration:$r->{source}|$r->{event}|$r->{matcher}|$r->{script}";
}

# ---------------------------------------------------------------------------
# DOC heading/section helpers (2.1).
# ---------------------------------------------------------------------------
sub all_headings {
    my ($text) = @_;
    my @out;
    my @lines = split /\n/, $text;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^##\s+(.*?)\s*$/) {
            push @out, { idx => $i, text => $1 };
        }
    }
    return @out;
}

sub extract_section {
    my ($text, $heading) = @_;
    my @lines = split /\n/, $text;
    for my $i (0 .. $#lines) {
        next unless $lines[$i] =~ /^##\s+(.*?)\s*$/ && $1 eq $heading;
        my $end = $#lines;
        for my $j ($i + 1 .. $#lines) {
            if ($lines[$j] =~ /^##\s+/) { $end = $j - 1; last }
        }
        return join("\n", @lines[$i .. $end]);
    }
    return undef;
}

# Canonical H1-H12 table (spec 2.1).
my @HEADINGS = (
    [ 'H1',  '## Inventory',                              [5, 6, 14, 38, 40] ],
    [ 'H2',  '## BpHook core API',                         [2, 3, 12, 20, 33, 46] ],
    [ 'H3',  '## Arm state storage and format',            [2, 18, 25, 36] ],
    [ 'H4',  '## Holder protocol',                         [1, 9, 44] ],
    [ 'H5',  '## Reason log',                              [7] ],
    [ 'H6',  '## Stop gate denial text',                   [1, 6, 8] ],
    [ 'H7',  '## Operator off versus agent off',           [25, 36, 37] ],
    [ 'H8',  '## Concurrency binding store and switch',    [16, 19, 31] ],
    [ 'H9',  '## Guard message budgets and early exits',   [3, 12, 20, 33] ],
    [ 'H10', '## Skill line budgets',                      [19, 24] ],
    [ 'H11', '## Deletion list',                           [6, 21, 26, 34, 43] ],
    [ 'H12', '## NEEDS-OPERATOR forks',                    [13, 32] ],
);

sub heading_text_only { my ($h) = @_; (my $t = $h) =~ s/^##\s+//; return $t }

# ---------------------------------------------------------------------------
# H1 row parsing (2.3).
# ---------------------------------------------------------------------------
sub parse_registration_rest {
    my ($rest) = @_;
    my $b1 = index($rest, '[');
    my $b2 = rindex($rest, ']');
    return undef if $b1 < 0 || $b2 < 0 || $b2 < $b1;
    my $before = trim(substr($rest, 0, $b1));
    my $matcher = substr($rest, $b1 + 1, $b2 - $b1 - 1);
    my $after = trim(substr($rest, $b2 + 1));
    my @before_parts = split /\s+/, $before;
    return undef unless @before_parts >= 2;
    my $source = shift @before_parts;
    my $event = join(' ', @before_parts);
    return ($source, $event, $matcher, $after);
}

sub parse_h1_rows {
    my ($h1_text) = @_;
    return () unless defined $h1_text;
    my @lines = split /\n/, $h1_text;
    my @rows;
    my $i = 0;
    while ($i <= $#lines) {
        my $line = $lines[$i];
        if ($line =~ /^###\s+(file|registration):\s*(.*?)\s*$/) {
            my ($kind, $rest) = ($1, $2);
            my $header_idx = $i;
            my $end = $#lines;
            for my $j ($header_idx + 1 .. $#lines) {
                if ($lines[$j] =~ /^#{2,3}\s+/) { $end = $j - 1; last }
            }
            my @body = @lines[$header_idx + 1 .. $end];
            my @nb = grep { $body[$_] =~ /\S/ } (0 .. $#body);
            my $row = { kind => $kind, rest => $rest, errors => [] };
            if (@nb >= 1 && $body[ $nb[0] ] =~ /^verdict:\s*(.*)$/) {
                $row->{verdict_raw} = trim($1);
            }
            else {
                push @{ $row->{errors} }, 'missing verdict line';
            }
            if (@nb >= 2 && $body[ $nb[1] ] =~ /^reason:\s*(.*)$/) {
                my @parts = ($1);
                my $k = $nb[1] + 1;
                while ($k <= $#body) {
                    last unless $body[$k] =~ /\S/;
                    push @parts, $body[$k];
                    $k++;
                }
                $row->{reason_text} = join(' ', @parts);
            }
            else {
                push @{ $row->{errors} }, 'missing reason line';
            }

            if ($kind eq 'file') {
                $row->{key}      = "file:$rest";
                $row->{own_path} = "plugins/butler/hooks/$rest";
            }
            else {
                my @p = parse_registration_rest($rest);
                if (@p) {
                    @{$row}{qw(source event matcher script)} = @p;
                    $row->{key} = "registration:$p[0]|$p[1]|$p[2]|$p[3]";
                }
            }

            if (defined $row->{verdict_raw}) {
                my $v = $row->{verdict_raw};
                if ($v eq 'keep' || $v eq 'delete') {
                    $row->{verdict_type} = $v;
                }
                elsif ($v =~ /^merge into\s*(.*)$/) {
                    my $target = strip_backticks($1);
                    if (length $target) {
                        $row->{verdict_type} = 'merge';
                        $row->{target}       = $target;
                    }
                    else {
                        push @{ $row->{errors} }, 'merge into with no target';
                    }
                }
                else {
                    push @{ $row->{errors} }, "invalid verdict '$v'";
                }
            }
            if (defined $row->{reason_text} && words_count($row->{reason_text}) < 8) {
                push @{ $row->{errors} }, 'reason under 8 words';
            }

            push @rows, $row;
            $i = $end + 1;
            next;
        }
        $i++;
    }
    return @rows;
}

# ---------------------------------------------------------------------------
# blueprint.md parsing (2.3 "Parsing blueprint.md").
# ---------------------------------------------------------------------------
sub parse_blueprint {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    my $text = read_utf8($path);
    return undef unless defined $text;
    my %pkg_ws;
    my $cur_id;
    for my $line (split /\n/, $text) {
        if ($line =~ /^###\s+(\d\d-[a-z0-9-]+)/) {
            $cur_id = $1;
        }
        elsif ($line =~ /^-\s*\*\*write_set:\*\*\s*`([^`]*)`/) {
            next unless defined $cur_id;
            push @{ $pkg_ws{$cur_id} }, split /:/, $1;
        }
    }
    return \%pkg_ws;
}

sub flatten_write_entries {
    my ($pkg_ws) = @_;
    return () unless defined $pkg_ws;
    return map { @$_ } values %$pkg_ws;
}

sub pkg_entries_matching {
    my ($pkg_ws, $prefix_re) = @_;
    return () unless defined $pkg_ws;
    my @out;
    for my $id (keys %$pkg_ws) {
        push @out, @{ $pkg_ws->{$id} } if $id =~ $prefix_re;
    }
    return @out;
}

sub target_valid {
    my (%a) = @_;
    my $target = $a{target};
    return 0 if defined $a{own_path} && $target eq $a{own_path};
    if ($target =~ m{^plugins/butler/hooks/([^/]+)$}) {
        return 1 if $a{file_keep_set}{$1};
    }
    return 1 if $a{write_exact}{$target};
    for my $prefix (@{ $a{write_prefixes} }) {
        return 1 if index($target, $prefix) == 0;
    }
    return 0;
}

# ---------------------------------------------------------------------------
# fact-line lookup (2.2).
# ---------------------------------------------------------------------------
sub get_fact_line {
    my ($section_text, $key) = @_;
    return undef unless defined $section_text;
    for my $line (split /\n/, $section_text) {
        if ($line =~ /^\Q$key\E:\s*(.*)$/) {
            return strip_backticks($1);
        }
    }
    return undef;
}

# ---------------------------------------------------------------------------
# H6 fenced block (2.5).
# ---------------------------------------------------------------------------
sub first_fenced_block {
    my ($section_text) = @_;
    return undef unless defined $section_text;
    my @lines = split /\n/, $section_text;
    my $start;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^```/) { $start = $i; last }
    }
    return undef unless defined $start;
    for my $j ($start + 1 .. $#lines) {
        if ($lines[$j] =~ /^```/) {
            return [ @lines[ $start + 1 .. $j - 1 ] ];
        }
    }
    return undef;
}

# ---------------------------------------------------------------------------
# H9/H10 table rows, H11 bullets (2.4).
# ---------------------------------------------------------------------------
sub parse_pipe_rows {
    my ($section_text, $ncols) = @_;
    return () unless defined $section_text;
    my @rows;
    my $re = $ncols == 3
        ? qr/^\|\s*(\S+)\s*\|\s*(\S+)\s*\|\s*(.+?)\s*\|\s*$/
        : qr/^\|\s*(\S+)\s*\|\s*(\S+)\s*\|\s*$/;
    for my $line (split /\n/, $section_text) {
        my $t = trim($line);
        if (my @m = ($t =~ $re)) {
            push @rows, \@m;
        }
    }
    return @rows;
}

sub parse_h11_bullets {
    my ($section_text) = @_;
    return () unless defined $section_text;
    my @out;
    for my $line (split /\n/, $section_text) {
        if ($line =~ /^-\s*`([^`]+)`/) {
            push @out, $1;
        }
    }
    return @out;
}

# ---------------------------------------------------------------------------
# H12 subsections (2.6).
# ---------------------------------------------------------------------------
sub parse_h12_subsections {
    my ($h12_text) = @_;
    return {} unless defined $h12_text;
    my @lines = split /\n/, $h12_text;
    my %out;
    for my $i (0 .. $#lines) {
        next unless $lines[$i] =~ /^###\s+(D-\d+)\b/;
        my $id = $1;
        my $end = $#lines;
        for my $j ($i + 1 .. $#lines) {
            if ($lines[$j] =~ /^#{2,3}\s+/) { $end = $j - 1; last }
        }
        my $block = join("\n", @lines[ $i + 1 .. $end ]);
        $out{$id} = $block;
    }
    return \%out;
}

# ---------------------------------------------------------------------------
# THE ROUTINE: coverage_failures(\%paths). Spawns no process, writes nothing.
# ---------------------------------------------------------------------------
sub coverage_failures {
    my ($paths) = @_;
    my @f;

    my $doc_path = $paths->{doc};
    unless (defined $doc_path && -f $doc_path) {
        push @f, "[C1] DOC missing: " . (defined $doc_path ? $doc_path : '(undef)');
        return @f;
    }
    my $doc_text = read_utf8($doc_path);
    unless (defined $doc_text) {
        push @f, "[C1] DOC unreadable: $doc_path";
        return @f;
    }

    my @regs;
    for my $k (qw(hooks_json settings_json)) {
        my $p = $paths->{$k};
        if (!defined $p || !-f $p) {
            push @f, "[C1] $k missing: " . (defined $p ? $p : '(undef)');
            next;
        }
        my $data = decode_json_file($p);
        if (!defined $data) {
            push @f, "[C1] $k malformed: $p";
            next;
        }
        push @regs, parse_registrations_from_json_struct($data, basename($p));
    }

    my @hook_files = list_hooks_dir_files($paths->{hooks_dir});

    my %disk;
    $disk{"file:$_"} = 1 for @hook_files;
    $disk{ reg_key($_) } = 1 for @regs;

    my @h1_rows = parse_h1_rows(extract_section($doc_text, 'Inventory'));

    my %row_key_count;
    my %file_keep_set;
    for my $row (@h1_rows) {
        next unless defined $row->{key};
        $row_key_count{ $row->{key} }++;
        if ($row->{kind} eq 'file' && $row->{verdict_type} && $row->{verdict_type} eq 'keep') {
            $file_keep_set{ $row->{rest} } = 1;
        }
    }

    # C1: every disk key needs a row.
    for my $key (sort keys %disk) {
        push @f, "[C1] missing row for key '$key'" unless $row_key_count{$key};
    }

    # C2: stale / duplicate rows.
    for my $key (sort keys %row_key_count) {
        push @f, "[C2] stale row: '$key'" unless $disk{$key};
        push @f, "[C2] duplicate row: '$key'" if $row_key_count{$key} > 1;
    }

    # C3: verdict/reason shape per row.
    for my $row (@h1_rows) {
        my $rowid = defined $row->{key} ? $row->{key} : "$row->{kind}:$row->{rest}";
        for my $err (@{ $row->{errors} }) {
            push @f, "[C3] $err in row '$rowid'";
        }
    }

    # blueprint.md (may be absent).
    my $pkg_ws = parse_blueprint($paths->{blueprint});
    my %write_exact = map { $_ => 1 } grep { !/\/$/ } flatten_write_entries($pkg_ws);
    my @write_prefixes =
        grep { /^plugins\/butler\/hooks\/next\// }
        grep { /\/$/ } flatten_write_entries($pkg_ws);

    # C4: merge target validity.
    for my $row (@h1_rows) {
        next unless defined $row->{verdict_type} && $row->{verdict_type} eq 'merge';
        my $rowid = defined $row->{key} ? $row->{key} : "$row->{kind}:$row->{rest}";
        my $ok = target_valid(
            target         => $row->{target},
            own_path       => $row->{own_path},
            file_keep_set  => \%file_keep_set,
            write_exact    => \%write_exact,
            write_prefixes => \@write_prefixes,
        );
        push @f, "[C4] invalid merge target '$row->{target}' in row '$rowid'" unless $ok;
    }

    # C5: headings present exactly once.
    my @all_h = all_headings($doc_text);
    my %h_count;
    $h_count{ $_->{text} }++ for @all_h;
    for my $spec (@HEADINGS) {
        my (undef, $full, undef) = @$spec;
        my $text = heading_text_only($full);
        my $n = $h_count{$text} || 0;
        push @f, "[C5] missing heading '$full'" if $n == 0;
        push @f, "[C5] duplicate heading '$full' (count=$n)" if $n > 1;
    }

    # C6: decision citations per section.
    for my $spec (@HEADINGS) {
        my (undef, $full, $decisions) = @$spec;
        my $text = heading_text_only($full);
        my $section = extract_section($doc_text, $text);
        next unless defined $section;
        for my $n (@$decisions) {
            unless ($section =~ /\bDecision\s+$n\b/) {
                push @f, "[C6] section '$full' missing citation 'Decision $n'";
            }
        }
    }

    my $h3 = extract_section($doc_text, 'Arm state storage and format');
    my $h4 = extract_section($doc_text, 'Holder protocol');
    my $h5 = extract_section($doc_text, 'Reason log');
    my $h6 = extract_section($doc_text, 'Stop gate denial text');
    my $h7 = extract_section($doc_text, 'Operator off versus agent off');
    my $h8 = extract_section($doc_text, 'Concurrency binding store and switch');
    my $h2 = extract_section($doc_text, 'BpHook core API');
    my $h9 = extract_section($doc_text, 'Guard message budgets and early exits');
    my $h10 = extract_section($doc_text, 'Skill line budgets');
    my $h11 = extract_section($doc_text, 'Deletion list');
    my $h12 = extract_section($doc_text, 'NEEDS-OPERATOR forks');

    # C7: fact lines.
    if (defined $h3) {
        my $v = get_fact_line($h3, 'arm-state-path');
        push @f, "[C7] missing or empty 'arm-state-path' in H3" unless defined $v && length $v;
    }
    if (defined $h4) {
        my $v = get_fact_line($h4, 'holder-reinvocation');
        push @f, "[C7] invalid holder-reinvocation '" . (defined $v ? $v : '') . "' in H4"
            unless defined $v && $v =~ /^(replace|extend)$/;
        push @f, "[C7] H4 missing 'harness-facts.md' reference" unless $h4 =~ /harness-facts\.md/;
        push @f, "[C7] H4 missing '(e)' reference" unless $h4 =~ /\(e\)/;
    }
    if (defined $h5) {
        my $v = get_fact_line($h5, 'reason-log');
        push @f, "[C7] missing or empty 'reason-log' in H5" unless defined $v && length $v;
    }
    if (defined $h7) {
        my $v = get_fact_line($h7, 'off-check');
        if (!defined $v || !length $v) {
            push @f, "[C7] missing or empty 'off-check' in H7";
        }
        elsif (defined $pkg_ws) {
            # Post-cutover form too: package 16 flattened hooks/next/(guards/) into hooks/.
            my %pkg04 = map { my $f = $_; $f =~ s{/hooks/next/(?:guards/)?}{/hooks/}; ($_ => 1, $f => 1) }
                        pkg_entries_matching($pkg_ws, qr/^04-/);
            push @f, "[C7] off-check '$v' is not a package 04-* write_set file entry"
                unless $pkg04{$v};
        }
    }
    if (defined $h8) {
        my $bs = get_fact_line($h8, 'binding-store');
        push @f, "[C7] missing or empty 'binding-store' in H8" unless defined $bs && length $bs;
        my $sw = get_fact_line($h8, 'concurrency-switch');
        push @f, "[C7] missing or empty 'concurrency-switch' in H8" unless defined $sw && length $sw;
    }

    # C8: H6 fenced denial block.
    if (defined $h6) {
        my $body = first_fenced_block($h6);
        if (!defined $body) {
            push @f, "[C8] no fenced block found in H6";
        }
        else {
            my $n = scalar @$body;
            push @f, "[C8] fenced block has $n lines (need 3-8)" if $n < 3 || $n > 8;
            my $joined = join("\n", @$body);
            for my $req ('butler-hold', 'butler-continuity off --reason', 'butler-continuity emergency-stop --reason') {
                push @f, "[C8] H6 fenced block missing required text '$req'"
                    unless index($joined, $req) >= 0;
            }
            for my $bad (qw(stop-ok bp-watch bp-continuity run-finished force-stop STOP_OK MAX_BLOCKS silence)) {
                push @f, "[C8] H6 fenced block contains forbidden text '$bad'"
                    if index($joined, $bad) >= 0;
            }
        }
    }

    # C9: H2 required substrings.
    if (defined $h2) {
        my $lc = lc $h2;
        for my $sub ('payload', 'coordinator', 'driver', 'reporter', 'manual', 'fork', 'arm', 'holder', 'disarm_otp', '[ -f') {
            push @f, "[C9] H2 missing required substring '$sub'" unless index($lc, lc $sub) >= 0;
        }
    }

    # C10: H9 rows, one per surviving guard.
    if (defined $h9) {
        my %disk_scripts = map { $_->{script} => 1 } @regs;
        my %required;
        for my $row (@h1_rows) {
            next unless $row->{kind} eq 'file';
            if (   $row->{verdict_type}
                && $row->{verdict_type} eq 'keep'
                && $row->{rest} =~ /\.sh$/
                && $disk_scripts{ $row->{rest} })
            {
                $required{ $row->{rest} } = 1;
            }
            if ($row->{verdict_type} && $row->{verdict_type} eq 'merge' && $row->{target} =~ /\.sh$/) {
                my @parts = split m{/}, $row->{target};
                $required{ $parts[-1] } = 1;
            }
        }
        my %found;
        for my $r (parse_pipe_rows($h9, 3)) {
            my ($script, $n, $cond) = @$r;
            $found{$script} = 1;
            push @f, "[C10] invalid N '$n' for row '$script'" unless $n =~ /^\d+$/;
            push @f, "[C10] empty early-exit condition for row '$script'" unless length trim($cond);
        }
        for my $s (sort keys %required) {
            push @f, "[C10] missing H9 row for '$s'" unless $found{$s};
        }
    }

    # C11: H10 rows, one per package-15-* SKILL.next.md entry. Needs blueprint.
    if (defined $pkg_ws) {
        my @required = grep { /SKILL\.next\.md$/ } pkg_entries_matching($pkg_ws, qr/^15-/);
        if (@required) {
            my %found;
            if (defined $h10) {
                for my $r (parse_pipe_rows($h10, 2)) {
                    my ($path, $n) = @$r;
                    $found{$path} = 1;
                    push @f, "[C11] invalid N '$n' for row '$path'" unless $n =~ /^\d+$/ && $n > 0;
                }
            }
            for my $p (sort @required) {
                push @f, "[C11] missing H10 row for '$p'" unless $found{$p};
            }
        }
    }

    # C12: H11 deletion list.
    if (defined $h11) {
        my $root_for_paths = root_from_hooks_dir($paths->{hooks_dir});
        my @bullets = parse_h11_bullets($h11);
        my %listed = map { $_ => 1 } @bullets;
        for my $path (@bullets) {
            my $full = defined $root_for_paths ? "$root_for_paths/$path" : $path;
            push @f, "[C12] deletion list path does not exist on disk: '$path'" unless -e $full;
        }
        for my $row (@h1_rows) {
            next unless $row->{kind} eq 'file';
            next unless defined $row->{verdict_type};
            if ($row->{verdict_type} eq 'delete' || $row->{verdict_type} eq 'merge') {
                push @f, "[C12] deletion list missing '$row->{own_path}'" unless $listed{ $row->{own_path} };
            }
            elsif ($row->{verdict_type} eq 'keep') {
                push @f, "[C12] deletion list lists kept file '$row->{own_path}'" if $listed{ $row->{own_path} };
            }
        }
    }

    # C13: unnamed new files cited by backtick. Needs blueprint.
    if (defined $pkg_ws) {
        my $root_for_paths = root_from_hooks_dir($paths->{hooks_dir});
        my %seen;
        while ($doc_text =~ /`((?:plugins|skills|scripts)\/[^\s`<>*]+\.(?:sh|pl|pm|t|md|json))`/g) {
            my $token = $1;
            next if $seen{$token}++;
            my $full = defined $root_for_paths ? "$root_for_paths/$token" : $token;
            next if -e $full;
            next if $write_exact{$token};
            next if grep { index($token, $_) == 0 } @write_prefixes;
            push @f, "[C13] unnamed new file: record a re-scope request, Decision 29 ('$token')";
        }
    }

    # C14: NEEDS-OPERATOR forks, ids from harness_facts.
    my $hf_text = read_utf8($paths->{harness_facts});
    if (defined $hf_text) {
        my @ids = ($hf_text =~ /^###\s+(D-\d+)\b/mg);
        my $subs = parse_h12_subsections($h12);
        for my $id (@ids) {
            my $block = $subs->{$id};
            if (!defined $block) {
                push @f, "[C14] missing H12 subsection for '$id'";
                next;
            }
            my ($q)  = ($block =~ /^question:\s*(.*)$/m);
            my ($y)  = ($block =~ /^if yes:\s*(.*)$/m);
            my ($n)  = ($block =~ /^if no:\s*(.*)$/m);
            my ($as) = ($block =~ /^assumed:\s*(.*)$/m);
            push @f, "[C14] '$id' missing non-empty 'question:'" unless defined $q && length trim($q);
            push @f, "[C14] '$id' missing non-empty 'if yes:'" unless defined $y && length trim($y);
            push @f, "[C14] '$id' missing non-empty 'if no:'" unless defined $n && length trim($n);
            push @f, "[C14] '$id' invalid 'assumed:' value '" . (defined $as ? $as : '') . "'"
                unless defined $as && trim($as) =~ /^(yes|no)$/;
        }
    }

    return @f;
}

# ---------------------------------------------------------------------------
# Fixture builder (spec section 4). One tempdir tree per test run; each
# negative case works from a fresh COPY so mutations never leak between
# cases.
# ---------------------------------------------------------------------------
sub build_fixture {
    my $root = tempdir(CLEANUP => 1);
    mkdir "$root/plugins"                  or die $!;
    mkdir "$root/plugins/butler"           or die $!;
    mkdir "$root/plugins/butler/hooks"     or die $!;
    mkdir "$root/plugins/butler/tests"     or die $!;
    mkdir "$root/plugins/butler/tests/t"   or die $!;
    mkdir "$root/.claude"                  or die $!;

    write_utf8("$root/plugins/butler/hooks/a.sh", "#!/usr/bin/env bash\nexit 0\n");
    write_utf8("$root/plugins/butler/hooks/b.sh", "#!/usr/bin/env bash\nexit 0\n");
    write_utf8("$root/plugins/butler/hooks/c.pl", "#!/usr/bin/env perl\n");
    write_utf8("$root/plugins/butler/tests/t/sample-fixture-a.t", "1;\n");
    write_utf8("$root/plugins/butler/tests/t/sample-fixture-b.t", "1;\n");

    my $hooks_json = {
        hooks => {
            PreToolUse => [
                { matcher => 'Bash', hooks => [ { type => 'command', command => 'bash "${X}/hooks/a.sh"' } ] },
            ],
            PostToolUse => [
                { matcher => 'Task', hooks => [ { type => 'command', command => 'bash "${X}/hooks/b.sh"' } ] },
            ],
        },
    };
    my $settings_json = {
        hooks => {
            PreToolUse => [
                { matcher => 'Bash', hooks => [ { type => 'command', command => '"$Y"/hooks/a.sh' } ] },
            ],
            Stop => [
                { hooks => [ { type => 'command', command => '"$Y"/hooks/c.pl' } ] },
            ],
        },
    };
    write_utf8("$root/plugins/butler/hooks/hooks.json", JSON::PP->new->encode($hooks_json));
    write_utf8("$root/.claude/settings.json", JSON::PP->new->encode($settings_json));

    write_utf8(
        "$root/blueprint.md",
        <<'BP'
### 04-fixture-off -- fixture package for off-check
- **write_set:** `plugins/fixture/off-check.sh:plugins/fixture/other-file.txt`

### 15-fixture-skills -- fixture package for skill budgets
- **write_set:** `plugins/fixture/skills/demo/SKILL.next.md:plugins/butler/hooks/next/:plugins/fixture/scripts/ExactTarget.pm`
BP
    );

    write_utf8(
        "$root/harness-facts.md",
        "### D-1 -- fixture item one\n\n### D-2 -- fixture item two\n"
    );

    write_utf8("$root/doc.md", clean_doc_text());

    return {
        doc           => "$root/doc.md",
        hooks_dir     => "$root/plugins/butler/hooks",
        hooks_json    => "$root/plugins/butler/hooks/hooks.json",
        settings_json => "$root/.claude/settings.json",
        blueprint     => "$root/blueprint.md",
        harness_facts => "$root/harness-facts.md",
        _root         => $root,
    };
}

sub clean_doc_text {
    return <<'DOC';
## Inventory

Every hook file and registration on disk is listed below with a verdict and a reason
(Decision 5, Decision 6, Decision 14, Decision 38, Decision 40).

### file: a.sh
verdict: keep
reason: kept because it still guards a live path that later packages depend on today.

### file: b.sh
verdict: delete
reason: retired because its behaviour is fully replaced by the new hook core design.

### file: c.pl
verdict: merge into `plugins/butler/hooks/a.sh`
reason: folded into the surviving guard since both checks run on the same event trigger.

### file: hooks.json
verdict: keep
reason: kept because it is the plugin's own hook registry file the new design still reads.

### registration: hooks.json PreToolUse [Bash] a.sh
verdict: keep
reason: this registration stays exactly as written pending the cutover package review.

### registration: hooks.json PostToolUse [Task] b.sh
verdict: delete
reason: removed alongside its script since nothing else needs this registration path.

### registration: settings.json PreToolUse [Bash] a.sh
verdict: keep
reason: settings.json keeps this entry so the clone keeps working every commit here.

### registration: settings.json Stop [] c.pl
verdict: merge into `plugins/butler/hooks/a.sh`
reason: the stop registration folds into the same surviving guard as the file itself.

## BpHook core API

The core parses the payload once. The payload's session_id decides the role: coordinator,
driver, reporter or manual. A fork is a subagent dispatched for unrelated work; it must never
inherit the driver's arm state. Each perl hook is registered guarded as
`[ -f "$f" ] || exit 0; exec perl "$f"`, so a missing script never blocks. The holder and the
disarm_otp record are read through this core (Decision 2, Decision 3, Decision 12, Decision 20,
Decision 33, Decision 46).

## Arm state storage and format

Arm state is stored per session, keyed by the payload session_id (Decision 2, Decision 18,
Decision 25, Decision 36).

arm-state-path: plugins/fixture/state/arm.json

## Holder protocol

The holder never blocks Stop merely because background_tasks lists something (Decision 1,
Decision 9, Decision 44). See harness-facts.md item (e) for the background-task wake evidence.

holder-reinvocation: replace

## Reason log

Every off and emergency-stop reason is appended here (Decision 7).

reason-log: plugins/fixture/state/reason.log

## Stop gate denial text

The gate's denial is at most 8 lines (Decision 1, Decision 6, Decision 8):

```
Run `butler-hold` first.
Then `butler-continuity off --reason "<why>"`.
Or `butler-continuity emergency-stop --reason "<defect>"` for a real defect.
```

## Operator off versus agent off

The off-check tells an operator off apart from an agent off (Decision 25, Decision 36,
Decision 37).

off-check: plugins/fixture/off-check.sh

## Concurrency binding store and switch

The binding store and the Decision 19 switch (Decision 16, Decision 19, Decision 31):

binding-store: plugins/fixture/state/bindings.json
concurrency-switch: FIXTURE_SWITCH

## Guard message budgets and early exits

Every surviving guard has a message budget and an early-exit condition (Decision 3,
Decision 12, Decision 20, Decision 33).

| a.sh | 5 | payload has no matching tool_use_id |

## Skill line budgets

Each skill's line budget for stop/continuity guidance (Decision 19, Decision 24):

| plugins/fixture/skills/demo/SKILL.next.md | 40 |

## Deletion list

Files and tests package 16 deletes (Decision 6, Decision 21, Decision 26, Decision 34,
Decision 43):

- `plugins/butler/hooks/b.sh`
- `plugins/butler/hooks/c.pl`
- `plugins/butler/tests/t/sample-fixture-a.t`
- `plugins/butler/tests/t/sample-fixture-b.t`

## NEEDS-OPERATOR forks

Each NEEDS-OPERATOR item states which outcome the design assumed (Decision 13, Decision 32).

### D-1
question: Does /compact change the session id in-process?
if yes: nothing changes; the payload session_id still governs.
if no: nothing changes either, since the design never reads the env var.
assumed: no

### D-2
question: Does the in-process $CLAUDE_CODE_SESSION_ID follow the new id after /clear?
if yes: nothing changes; the design keys on the payload session_id.
if no: nothing changes; the design never trusts the env var.
assumed: no
DOC
}

# ---------------------------------------------------------------------------
# Mutation helpers for the negative fixtures.
# ---------------------------------------------------------------------------
sub remove_row_block {
    my ($text, $header_line) = @_;
    my @lines = split /\n/, $text;
    for my $i (0 .. $#lines) {
        next unless $lines[$i] eq $header_line;
        my $end = $#lines;
        for my $j ($i + 1 .. $#lines) {
            if ($lines[$j] =~ /^#{2,3}\s+/) { $end = $j - 1; last }
        }
        splice(@lines, $i, $end - $i + 1);
        return join("\n", @lines);
    }
    die "remove_row_block: header not found: '$header_line'";
}

sub replace_line {
    my ($text, $needle_re, $replacement) = @_;
    my @lines = split /\n/, $text;
    my $found = 0;
    for my $line (@lines) {
        if ($line =~ $needle_re) {
            $line = $replacement;
            $found = 1;
        }
    }
    die "replace_line: pattern not found" unless $found;
    return join("\n", @lines);
}

sub delete_line {
    my ($text, $needle_re) = @_;
    my @lines = split /\n/, $text;
    my @out = grep { $_ !~ $needle_re } @lines;
    die "delete_line: pattern not found" if @out == @lines;
    return join("\n", @out);
}

sub mutate_doc {
    my ($fixture, $mutator) = @_;
    my $orig = read_utf8($fixture->{doc});
    my $mutated = $mutator->($orig);
    my %copy = %$fixture;
    $copy{doc} = "$fixture->{_root}/doc-mutated-" . int(rand(1_000_000)) . ".md";
    write_utf8($copy{doc}, $mutated);
    return \%copy;
}

sub has_failure_like {
    my ($failures, $tag, $needle) = @_;
    for my $f (@$failures) {
        return 1 if index($f, $tag) == 0 && index($f, $needle) >= 0;
    }
    return 0;
}

# ===========================================================================
# AC1 -- [C1] every disk key needs a row.
# ===========================================================================
{
    my $fx = build_fixture();
    my @clean = coverage_failures($fx);
    ok(!grep { /^\[C1\]/ } @clean, 'AC1: clean fixture has no [C1] failures')
        or diag(join("\n", @clean));

    # (i) remove a file: row.
    my $m1 = mutate_doc($fx, sub { remove_row_block($_[0], '### file: b.sh') });
    my @f1 = coverage_failures($m1);
    ok(has_failure_like(\@f1, '[C1]', "'file:b.sh'"),
        'AC1(i): removing the file:b.sh row is caught by [C1] naming that key');

    # (ii) remove the registration: row for the cross-source duplicate script
    # in only ONE source (a.sh is registered from both hooks.json and
    # settings.json; drop the hooks.json copy).
    my $m2 = mutate_doc($fx, sub { remove_row_block($_[0], '### registration: hooks.json PreToolUse [Bash] a.sh') });
    my @f2 = coverage_failures($m2);
    ok(has_failure_like(\@f2, '[C1]', "'registration:hooks.json|PreToolUse|Bash|a.sh'"),
        'AC1(ii): removing one cross-source registration row is caught by [C1] naming that exact key');

    # (iii) add an extra file to the fixture hooks dir with no row.
    my %fx3 = %$fx;
    write_utf8("$fx->{_root}/plugins/butler/hooks/extra-unlisted.sh", "#!/usr/bin/env bash\n");
    my @f3 = coverage_failures(\%fx3);
    ok(has_failure_like(\@f3, '[C1]', "'file:extra-unlisted.sh'"),
        'AC1(iii): an unlisted extra hooks-dir file is caught by [C1] naming that key');
    unlink "$fx->{_root}/plugins/butler/hooks/extra-unlisted.sh";
}

# ===========================================================================
# AC2 -- [C2] stale row / duplicate row.
# ===========================================================================
{
    my $fx = build_fixture();

    # Stale row: rename file:b.sh's row key to something not on disk, by
    # renaming the heading only (leaves a row whose key matches nothing).
    my $m1 = mutate_doc($fx, sub {
        replace_line($_[0], qr/^### file: b\.sh$/, '### file: nonexistent-stale.sh');
    });
    my @f1 = coverage_failures($m1);
    ok(has_failure_like(\@f1, '[C2]', "'file:nonexistent-stale.sh'"),
        'AC2: a row whose key matches nothing on disk fails as a stale row');

    # Duplicate row: insert a second file:a.sh row block INSIDE the Inventory
    # section (a row placed after it, per spec 5, would not count at all).
    my $m2 = mutate_doc($fx, sub {
        my $text = shift;
        $text =~ s/(^### file: a\.sh\nverdict: keep\nreason:[^\n]*\n)/$1\n### file: a.sh\nverdict: keep\nreason: duplicated on purpose to trip the duplicate-row check here.\n/m;
        return $text;
    });
    my @f2 = coverage_failures($m2);
    ok(has_failure_like(\@f2, '[C2]', "'file:a.sh'"),
        'AC2: two rows sharing one key fail as a duplicate row');
}

# ===========================================================================
# AC3 -- [C3] verdict/reason shape.
# ===========================================================================
{
    my $fx = build_fixture();

    my $m1 = mutate_doc($fx, sub { replace_line($_[0], qr/^verdict: keep$/, 'verdict: frobnicate') });
    my @f1 = coverage_failures($m1);
    ok(has_failure_like(\@f1, '[C3]', 'frobnicate'), 'AC3: verdict frobnicate fails [C3]');

    my $m2 = mutate_doc($fx, sub { replace_line($_[0], qr/^verdict: merge into `plugins\/butler\/hooks\/a\.sh`$/, 'verdict: merge into') });
    my @f2 = coverage_failures($m2);
    ok(has_failure_like(\@f2, '[C3]', 'merge into with no target'), 'AC3: "merge into" with no target fails [C3]');

    my $m3 = mutate_doc($fx, sub {
        replace_line($_[0],
            qr/^reason: kept because it still guards a live path that later packages depend on today\.$/,
            'reason:');
    });
    my @f3 = coverage_failures($m3);
    ok(has_failure_like(\@f3, '[C3]', 'reason under 8 words'), 'AC3: an empty reason fails [C3] as under 8 words');

    my $m4 = mutate_doc($fx, sub {
        replace_line($_[0],
            qr/^reason: kept because it still guards a live path that later packages depend on today\.$/,
            'reason: onlyoneword');
    });
    my @f4 = coverage_failures($m4);
    ok(has_failure_like(\@f4, '[C3]', 'reason under 8 words'), 'AC3: a 1-word reason fails [C3] as under 8 words');
}

# ===========================================================================
# AC4 -- [C4] merge target validity.
# ===========================================================================
{
    my $fx = build_fixture();
    my @clean = coverage_failures($fx);
    ok(!grep { /^\[C4\]/ } @clean, 'AC4: clean fixture (type-a merge target) has no [C4] failures')
        or diag(join("\n", @clean));

    # (i) target names nothing valid at all.
    my $m1 = mutate_doc($fx, sub {
        replace_line($_[0],
            qr/^verdict: merge into `plugins\/butler\/hooks\/a\.sh`$/,
            'verdict: merge into `plugins/butler/hooks/nonexistent-guard.sh`');
    });
    my @f1 = coverage_failures($m1);
    ok(has_failure_like(\@f1, '[C4]', 'nonexistent-guard.sh'),
        'AC4(i): a merge target naming nothing on any list fails [C4]');

    # (ii) target = a file whose own verdict is delete (not keep -> type-a fails).
    my $m2 = mutate_doc($fx, sub {
        replace_line($_[0],
            qr/^verdict: merge into `plugins\/butler\/hooks\/a\.sh`$/,
            'verdict: merge into `plugins/butler/hooks/b.sh`');
    });
    my @f2 = coverage_failures($m2);
    ok(has_failure_like(\@f2, '[C4]', 'plugins/butler/hooks/b.sh'),
        'AC4(ii): a merge target pointing at a delete-verdict file fails [C4]');

    # (iii) target = the row's own file.
    my $m3 = mutate_doc($fx, sub {
        replace_line($_[0],
            qr/^verdict: merge into `plugins\/butler\/hooks\/a\.sh`$/,
            'verdict: merge into `plugins/butler/hooks/c.pl`');
    });
    my @f3 = coverage_failures($m3);
    ok(has_failure_like(\@f3, '[C4]', 'plugins/butler/hooks/c.pl'),
        "AC4(iii): a merge target equal to the row's own file fails [C4]");

    # Positive: an exact write_set file entry passes.
    my $p1 = mutate_doc($fx, sub {
        replace_line($_[0],
            qr/^verdict: merge into `plugins\/butler\/hooks\/a\.sh`$/,
            'verdict: merge into `plugins/fixture/scripts/ExactTarget.pm`');
    });
    my @g1 = coverage_failures($p1);
    ok(!grep { /^\[C4\]/ } @g1, 'AC4 positive: exact write_set file entry passes [C4]')
        or diag(join("\n", grep { /^\[C4\]/ } @g1));

    # Positive: a path under a plugins/butler/hooks/next/ write_set prefix passes.
    my $p2 = mutate_doc($fx, sub {
        replace_line($_[0],
            qr/^verdict: merge into `plugins\/butler\/hooks\/a\.sh`$/,
            'verdict: merge into `plugins/butler/hooks/next/newfile.sh`');
    });
    my @g2 = coverage_failures($p2);
    ok(!grep { /^\[C4\]/ } @g2, 'AC4 positive: a hooks/next/ prefix write_set entry passes [C4]')
        or diag(join("\n", grep { /^\[C4\]/ } @g2));
}

# ===========================================================================
# AC5 -- [C5] every heading present exactly once.
# ===========================================================================
{
    my $fx = build_fixture();

    my $m1 = mutate_doc($fx, sub {
        my $text = shift;
        $text =~ s/^## Holder protocol\n.*?(?=^## )//ms;
        return $text;
    });
    my @f1 = coverage_failures($m1);
    ok(has_failure_like(\@f1, '[C5]', "'## Holder protocol'"), 'AC5: deleting ## Holder protocol is caught by [C5]');

    my $m2 = mutate_doc($fx, sub {
        my $text = shift;
        $text .= "\n## Reason log\n\nreason-log: plugins/fixture/state/other.log\n";
        return $text;
    });
    my @f2 = coverage_failures($m2);
    ok(has_failure_like(\@f2, '[C5]', "'## Reason log'"), 'AC5: duplicating ## Reason log is caught by [C5]');
}

# ===========================================================================
# AC6 -- [C6] each section cites every required Decision.
# ===========================================================================
{
    my $fx = build_fixture();
    my @clean = coverage_failures($fx);
    ok(!grep { /^\[C6\]/ } @clean, 'AC6: clean fixture cites every required Decision')
        or diag(join("\n", grep { /^\[C6\]/ } @clean));

    my $m1 = mutate_doc($fx, sub {
        my $text = shift;
        $text =~ s/Decision 1, Decision 6, Decision 8/Decision 1, Decision 6/;
        return $text;
    });
    my @f1 = coverage_failures($m1);
    ok(has_failure_like(\@f1, '[C6]', "'Decision 8'"), 'AC6: stripping Decision 8 from H6 is caught by [C6]');
}

# ===========================================================================
# AC7 -- [C7] fact lines.
# ===========================================================================
{
    my $fx = build_fixture();
    my @clean = coverage_failures($fx);
    ok(!grep { /^\[C7\]/ } @clean, 'AC7: clean fixture has valid fact lines')
        or diag(join("\n", grep { /^\[C7\]/ } @clean));

    my $m1 = mutate_doc($fx, sub { replace_line($_[0], qr/^holder-reinvocation: replace$/, 'holder-reinvocation: maybe') });
    my @f1 = coverage_failures($m1);
    ok(has_failure_like(\@f1, '[C7]', "'maybe'"), 'AC7: holder-reinvocation: maybe fails [C7]');

    my $m2 = mutate_doc($fx, sub { delete_line($_[0], qr/\(e\)/) });
    my @f2 = coverage_failures($m2);
    ok(has_failure_like(\@f2, '[C7]', "'(e)'"), 'AC7: H4 without an (e) reference fails [C7]');

    my $m3 = mutate_doc($fx, sub { replace_line($_[0], qr/^off-check: plugins\/fixture\/off-check\.sh$/, 'off-check: plugins/fixture/off-limits.sh') });
    my @f3 = coverage_failures($m3);
    ok(has_failure_like(\@f3, '[C7]', 'plugins/fixture/off-limits.sh'), 'AC7: off-check outside package 04-*\'s write set fails [C7]');

    my $m4 = mutate_doc($fx, sub { delete_line($_[0], qr/^reason-log: /) });
    my @f4 = coverage_failures($m4);
    ok(has_failure_like(\@f4, '[C7]', "'reason-log'"), 'AC7: a missing reason-log: line fails [C7]');
}

# ===========================================================================
# AC8 -- [C8] H6 fenced denial block.
# ===========================================================================
{
    my $fx = build_fixture();
    my @clean = coverage_failures($fx);
    ok(!grep { /^\[C8\]/ } @clean, 'AC8: clean fixture has a valid H6 fenced block')
        or diag(join("\n", grep { /^\[C8\]/ } @clean));

    my $m1 = mutate_doc($fx, sub {
        my $text = shift;
        $text =~ s/(```\nRun `butler-hold` first\.\n)/$1extra one\nextra two\nextra three\nextra four\nextra five\nextra six\n/;
        return $text;
    });
    my @f1 = coverage_failures($m1);
    ok(has_failure_like(\@f1, '[C8]', 'need 3-8'), 'AC8: a 9+-line fenced block fails [C8]');

    my $m2 = mutate_doc($fx, sub {
        delete_line($_[0], qr/^Or `butler-continuity emergency-stop --reason "<defect>"` for a real defect.$/);
    });
    my @f2 = coverage_failures($m2);
    ok(has_failure_like(\@f2, '[C8]', "'butler-continuity emergency-stop --reason'"), 'AC8: a block missing "emergency-stop --reason" fails [C8]');

    my $m3 = mutate_doc($fx, sub {
        replace_line($_[0],
            qr/^Run `butler-hold` first\.$/,
            'Run `butler-hold` first, never via .stop-ok.');
    });
    my @f3 = coverage_failures($m3);
    ok(has_failure_like(\@f3, '[C8]', "'stop-ok'"), 'AC8: a block containing ".stop-ok" fails [C8]');

    my $m4 = mutate_doc($fx, sub {
        my $text = shift;
        $text =~ s/```\nRun `butler-hold` first\..*?```\n//s;
        return $text;
    });
    my @f4 = coverage_failures($m4);
    ok(has_failure_like(\@f4, '[C8]', 'no fenced block'), 'AC8: H6 with no fenced block at all fails [C8]');
}

# ===========================================================================
# AC9 -- [C9] H2 required substrings.
# ===========================================================================
{
    my $fx = build_fixture();
    my @clean = coverage_failures($fx);
    ok(!grep { /^\[C9\]/ } @clean, 'AC9: clean fixture H2 has every required substring')
        or diag(join("\n", grep { /^\[C9\]/ } @clean));

    my $m1 = mutate_doc($fx, sub {
        my $text = shift;
        $text =~ s/A fork is a subagent dispatched for unrelated work; it must never/A subagent dispatched for unrelated work must never/;
        return $text;
    });
    my @f1 = coverage_failures($m1);
    ok(has_failure_like(\@f1, '[C9]', "'fork'"), 'AC9: removing the word "fork" from H2 fails [C9]');
}

# ===========================================================================
# AC10 -- [C10] H9 rows, one per surviving guard.
# ===========================================================================
{
    my $fx = build_fixture();
    my @clean = coverage_failures($fx);
    ok(!grep { /^\[C10\]/ } @clean, 'AC10: clean fixture H9 covers every surviving guard')
        or diag(join("\n", grep { /^\[C10\]/ } @clean));

    my $m1 = mutate_doc($fx, sub { delete_line($_[0], qr/^\| a\.sh \| 5 \|/) });
    my @f1 = coverage_failures($m1);
    ok(has_failure_like(\@f1, '[C10]', "'a.sh'"), 'AC10: removing the required a.sh row fails [C10]');

    my $m2 = mutate_doc($fx, sub { replace_line($_[0], qr/^\| a\.sh \| 5 \|.*$/, '| a.sh | many | payload has no matching tool_use_id |') });
    my @f2 = coverage_failures($m2);
    ok(has_failure_like(\@f2, '[C10]', "'many'"), 'AC10: an N of "many" fails [C10]');
}

# ===========================================================================
# AC11 -- [C11] H10 rows, one per package-15 SKILL.next.md entry.
# ===========================================================================
{
    my $fx = build_fixture();
    my @clean = coverage_failures($fx);
    ok(!grep { /^\[C11\]/ } @clean, 'AC11: clean fixture H10 covers the required SKILL.next.md entry')
        or diag(join("\n", grep { /^\[C11\]/ } @clean));

    my $m1 = mutate_doc($fx, sub { delete_line($_[0], qr/^\| plugins\/fixture\/skills\/demo\/SKILL\.next\.md \|/) });
    my @f1 = coverage_failures($m1);
    ok(has_failure_like(\@f1, '[C11]', 'SKILL.next.md'), 'AC11: dropping the required H10 row fails [C11]');

    my $m2 = mutate_doc($fx, sub {
        replace_line($_[0],
            qr/^\| plugins\/fixture\/skills\/demo\/SKILL\.next\.md \| 40 \|$/,
            '| plugins/fixture/skills/demo/SKILL.next.md | 0 |');
    });
    my @f2 = coverage_failures($m2);
    ok(has_failure_like(\@f2, '[C11]', "'0'"), 'AC11: N = 0 fails [C11]');
}

# ===========================================================================
# AC12 -- [C12] H11 deletion list.
# ===========================================================================
{
    my $fx = build_fixture();
    my @clean = coverage_failures($fx);
    ok(!grep { /^\[C12\]/ } @clean, 'AC12: clean fixture H11 is exact and every path exists')
        or diag(join("\n", grep { /^\[C12\]/ } @clean));

    my $m1 = mutate_doc($fx, sub {
        my $text = shift;
        $text .= "";
        return $text =~ s/^- `plugins\/butler\/hooks\/b\.sh`$/- `plugins\/butler\/hooks\/does-not-exist.sh`\n- `plugins\/butler\/hooks\/b.sh`/mr;
    });
    my @f1 = coverage_failures($m1);
    ok(has_failure_like(\@f1, '[C12]', 'does-not-exist.sh'), 'AC12: listing a nonexistent path fails [C12]');

    my $m2 = mutate_doc($fx, sub { delete_line($_[0], qr/^- `plugins\/butler\/hooks\/b\.sh`$/) });
    my @f2 = coverage_failures($m2);
    ok(has_failure_like(\@f2, '[C12]', 'plugins/butler/hooks/b.sh'), 'AC12: omitting a deleted file from H11 fails [C12]');

    my $m3 = mutate_doc($fx, sub {
        my $text = shift;
        $text .= "\n" unless $text =~ /\n\z/;
        return $text =~ s/^(- `plugins\/butler\/hooks\/b\.sh`)$/$1\n- `plugins\/butler\/hooks\/a.sh`/mr;
    });
    my @f3 = coverage_failures($m3);
    ok(has_failure_like(\@f3, '[C12]', 'plugins/butler/hooks/a.sh'), 'AC12: listing a kept file in H11 fails [C12]');
}

# ===========================================================================
# AC13 -- [C13] unnamed new files cited by backtick.
# ===========================================================================
{
    my $fx = build_fixture();
    my @clean = coverage_failures($fx);
    ok(!grep { /^\[C13\]/ } @clean, 'AC13: clean fixture names no unapproved new file')
        or diag(join("\n", grep { /^\[C13\]/ } @clean));

    my $m1 = mutate_doc($fx, sub {
        my $text = shift;
        $text .= "\nSee also `plugins/butler/scripts/BpInvented.pm` for the invented module.\n";
        return $text;
    });
    my @f1 = coverage_failures($m1);
    ok(has_failure_like(\@f1, '[C13]', 'BpInvented.pm'), 'AC13: naming an unapproved new file fails [C13]');
}

# ===========================================================================
# AC14 -- [C14] NEEDS-OPERATOR forks track harness_facts ids.
# ===========================================================================
{
    my $fx = build_fixture();
    my @clean = coverage_failures($fx);
    ok(!grep { /^\[C14\]/ } @clean, 'AC14: clean fixture covers every harness_facts D-N id')
        or diag(join("\n", grep { /^\[C14\]/ } @clean));

    my $m1 = mutate_doc($fx, sub {
        my $text = shift;
        $text =~ s/^### D-2\nquestion:.*?assumed: no\n//ms;
        return $text;
    });
    my @f1 = coverage_failures($m1);
    ok(has_failure_like(\@f1, '[C14]', "'D-2'"), 'AC14: removing the ### D-2 subsection fails [C14]');

    my $m2 = mutate_doc($fx, sub {
        replace_line($_[0], qr/^assumed: no$/, 'assumed: maybe');
    });
    my @f2 = coverage_failures($m2);
    ok(has_failure_like(\@f2, '[C14]', "'maybe'"), "AC14: assumed: maybe fails [C14]");
}

# ===========================================================================
# AC15 -- real-copy mutation of the real DOC (when present).
# ===========================================================================
{
    my $real_doc = "$ROOT/plugins/butler/docs/hook-architecture.md";
    my $ok = 0;
    my @diag_lines;
    if (-f $real_doc) {
        my $text = read_utf8($real_doc);
        my @file_heads = ($text =~ /^(### file: .+)$/mg);
        my @reg_heads  = ($text =~ /^(### registration: .+)$/mg);
        if (@file_heads && @reg_heads) {
            my $mutated = remove_row_block($text, $file_heads[0]);
            $mutated = remove_row_block($mutated, $reg_heads[0]);
            my $tmp = tempdir(CLEANUP => 1);
            my $mutated_path = "$tmp/hook-architecture-mutated.md";
            write_utf8($mutated_path, $mutated);
            my %real_paths = (
                doc           => $mutated_path,
                hooks_dir     => "$ROOT/plugins/butler/hooks",
                hooks_json    => "$ROOT/plugins/butler/hooks/hooks.json",
                settings_json => "$ROOT/.claude/settings.json",
                blueprint     => "$ROOT/.ccpraxis-local-data/blueprints/hook-continuity-remake/blueprint.md",
                harness_facts => "$ROOT/plugins/butler/docs/harness-facts.md",
            );
            $real_paths{blueprint} = undef unless -f $real_paths{blueprint};
            my @failures = coverage_failures(\%real_paths);
            (my $file_key = $file_heads[0]) =~ s/^### file: //;
            $file_key = "file:$file_key";
            my $reg_rest = $reg_heads[0];
            $reg_rest =~ s/^### registration: //;
            my @rp = parse_registration_rest($reg_rest);
            my $c1_hits = grep { index($_, '[C1]') == 0 && index($_, "'$file_key'") >= 0 } @failures;
            my $reg_key_expected = @rp ? "registration:$rp[0]|$rp[1]|$rp[2]|$rp[3]" : '(unparsed)';
            $c1_hits += grep { index($_, '[C1]') == 0 && index($_, "'$reg_key_expected'") >= 0 } @failures;
            $ok = ($c1_hits >= 2);
            push @diag_lines, @failures unless $ok;
        }
        else {
            push @diag_lines, "[C1] real DOC has no ### file: or ### registration: rows to mutate: $real_doc";
        }
    }
    else {
        push @diag_lines, "[C1] DOC missing: plugins/butler/docs/hook-architecture.md";
    }
    ok($ok, 'AC15: mutating the real DOC to drop its first file: and registration: rows produces two [C1] failures naming those keys');
    diag($_) for @diag_lines;
}

# ===========================================================================
# AC16 -- conventions: test-naming-hygiene R1-R4, platform marker, no
# process spawn, tempdir-only writes.
# ===========================================================================
{
    my $self_path = "$Bin/" . basename(__FILE__);
    my $src = read_utf8($self_path);
    ok(defined $src, 'AC16: this file can read its own source for a static self-check');

    my @lines = split /\n/, $src;
    is($lines[0], '#!/usr/bin/env perl', 'AC16: line 1 is the perl shebang');
    is($lines[1], '# platform: any', 'AC16: line 2 is "# platform: any"');

    my $basename = basename($self_path);
    like($basename, qr/^[a-z][a-z0-9-]*\.t$/, 'AC16 (R1): basename is lowercase kebab-case with no numeric prefix');
    (my $stem = $basename) =~ s/\.t$//;
    like($stem, qr/^[a-z0-9]+(-[a-z0-9]+)+$/, 'AC16 (R4): basename has at least two hyphen-separated words');

    my @siblings = grep { basename($_) eq $basename } glob("$ROOT/plugins/*/tests/t/*.t");
    is(scalar(@siblings), 1, 'AC16 (R2): basename is unique across every plugin test dir');

    my $header = '';
    for my $l (@lines) {
        last unless $l =~ /^#/;
        $header .= "$l\n";
    }
    my $q = quotemeta $stem;
    my $self_ref = $header =~ /(?<![A-Za-z0-9_-])$q(?:\.t|(?![A-Za-z0-9_.-]))/;
    ok(!$self_ref, 'AC16 (R3): header never repeats this file\'s own basename');

    # Heredoc bodies (<<'DOC' ... DOC) are inert string content, not code --
    # exclude their line ranges from the spawn scan below.
    my %in_heredoc;
    for my $i (0 .. $#lines) {
        next unless $lines[$i] =~ /<<(['"]?)(\w+)\1\s*;?\s*$/;
        my $term = $2;
        for my $j ($i + 1 .. $#lines) {
            if ($lines[$j] =~ /^\Q$term\E$/) {
                $in_heredoc{$_} = 1 for ($i + 1 .. $j);
                last;
            }
        }
    }

    # Strip single- and double-quoted string bodies before scanning, so a
    # backtick that is only fixture STRING CONTENT (e.g. 'merge into
    # `plugins/...`') is never mistaken for the backtick operator.
    sub _strip_quoted_for_scan {
        my ($line) = @_;
        $line =~ s/'(?:[^'\\]|\\.)*'//g;
        $line =~ s/"(?:[^"\\]|\\.)*"//g;
        return $line;
    }

    # For the backtick-specific check only: also strip //-delimited regex
    # literals (qr/m/s use them and legitimately match a literal backtick
    # character), so only a REAL bare backtick-quote operator can trip it.
    sub _strip_regex_literals_for_scan {
        my ($line) = @_;
        # s/pattern/replacement/flags has THREE '/' delimiters -- strip that
        # whole three-field form first, then the plain two-slash m//, qr// form.
        $line =~ s{\bs/(?:\\.|[^/\\\n])*/(?:\\.|[^/\\\n])*/[a-z]*}{}g;
        $line =~ s{/(?:\\.|[^/\\\n])*/}{}g;
        return $line;
    }

    my @spawn_hits;
    for my $i (0 .. $#lines) {
        next if $in_heredoc{$i};
        my $l = $lines[$i];
        next if $l =~ /^\s*#/;
        my $stripped = _strip_quoted_for_scan($l);
        push @spawn_hits, $l if $stripped =~ /\bsystem\s*\(|\bexec\s*\(|\bqx[\/\(\{]/;
        push @spawn_hits, $l if _strip_regex_literals_for_scan($stripped) =~ /`/;
        push @spawn_hits, $l if $stripped =~ /open\s*\([^,]*,\s*['"]?\s*\|/;
    }
    unless (ok(!@spawn_hits, 'AC16: no system/exec/backtick/qx/piped-open process spawn anywhere in this file')) {
        diag($_) for @spawn_hits;
    }

    my @root_write_hits;
    for my $l (@lines) {
        next if $l =~ /^\s*#/;
        push @root_write_hits, $l if $l =~ /open\s*\([^)]*['"](>{1,2}|\+[<>])/ && $l =~ /\$ROOT/;
    }
    unless (ok(!@root_write_hits, 'AC16: no write-mode open() references $ROOT (writes stay inside tempdir())')) {
        diag($_) for @root_write_hits;
    }
}

# ===========================================================================
# AC17 -- real tree green (except the doc-missing exception recorded now).
# ===========================================================================
{
    my $bp_path = "$ROOT/.ccpraxis-local-data/blueprints/hook-continuity-remake/blueprint.md";
    my %real_paths = (
        doc           => "$ROOT/plugins/butler/docs/hook-architecture.md",
        hooks_dir     => "$ROOT/plugins/butler/hooks",
        hooks_json    => "$ROOT/plugins/butler/hooks/hooks.json",
        settings_json => "$ROOT/.claude/settings.json",
        blueprint     => (-f $bp_path ? $bp_path : undef),
        harness_facts => "$ROOT/plugins/butler/docs/harness-facts.md",
    );
    my @failures = coverage_failures(\%real_paths);
    ok(scalar(@failures) == 0,
        'AC17: the real tree is green under coverage_failures (today\'s only allowed exception is the missing DOC)');
    diag($_) for @failures;
}

# ===========================================================================
# AC-20 (blueprint where-things-go, package 10-gatherer-and-digest spec
# sec 4): narrower, dedicated checks on top of AC17's whole-tree sweep above
# -- every backticked repo path cited in the real hook-architecture.md
# exists on disk, and the H9 "Guard message budgets and early exits" row for
# session-start-nudge.sh (which package 10 edits the prose of, but must
# leave numerically well-formed) still has a numeric N and a non-empty
# early-exit condition.
# ===========================================================================
{
    my $real_doc = "$ROOT/plugins/butler/docs/hook-architecture.md";
    ok(-f $real_doc, 'AC-20 precondition: plugins/butler/docs/hook-architecture.md exists')
        or BAIL_OUT('hook-architecture.md missing');
    my $text = read_utf8($real_doc);
    ok(defined $text, 'AC-20 precondition: hook-architecture.md is readable as UTF-8')
        or BAIL_OUT('hook-architecture.md unreadable');

    my %seen_token;
    my @missing_backtick_paths;
    while ($text =~ /`((?:plugins|skills|scripts)\/[^\s`<>*]+\.(?:sh|pl|pm|t|md|json))`/g) {
        my $token = $1;
        next if $seen_token{$token}++;
        push @missing_backtick_paths, $token unless -e "$ROOT/$token";
    }
    is(scalar(@missing_backtick_paths), 0,
        'AC-20: every backticked repo path in the real hook-architecture.md exists on disk')
        or diag(join("\n", @missing_backtick_paths));

    my $h9 = extract_section($text, 'Guard message budgets and early exits');
    ok(defined $h9, 'AC-20 precondition: the "Guard message budgets and early exits" (H9) section exists')
        or BAIL_OUT('H9 section missing from hook-architecture.md');
    SKIP: {
        skip 'AC-20: H9 section missing, cannot find its session-start-nudge.sh row', 2 unless defined $h9;
        my ($row) = grep { $_->[0] eq 'session-start-nudge.sh' } parse_pipe_rows($h9, 3);
        ok(defined $row, 'AC-20: the H9 row for session-start-nudge.sh is present')
            or diag('no H9 row named session-start-nudge.sh');
        SKIP: {
            skip 'AC-20: no session-start-nudge.sh H9 row to check the shape of', 1 unless defined $row;
            my (undef, $n, $cond) = @$row;
            ok($n =~ /^\d+$/ && length(trim($cond // '')),
                "AC-20: the session-start-nudge.sh H9 row keeps a numeric N ('$n') and a non-empty condition")
                or diag("N='" . ($n // '') . "' condition='" . ($cond // '') . "'");
        }
    }
}

done_testing();
