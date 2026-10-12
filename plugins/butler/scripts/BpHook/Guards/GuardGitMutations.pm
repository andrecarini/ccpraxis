# BpHook::Guards::GuardGitMutations -- denies git working-tree/history
# mutations (git stash; git checkout/switch/restore/reset/clean) in every
# session, plus a second, run-scoped registration (package 14 of blueprint
# hook-continuity-remake), successor to guard-git-mutations.sh (both of its
# registrations).
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 14-guards-remake-spec.md sec 3.2. Architecture:
# plugins/butler/docs/hook-architecture.md ("guard-git-mutations" successor
# row).
#
# run($p, @args) never calls exit, never dies on purpose, never spawns a
# process (no system/exec/backtick/qx/pipe-open). Prints only through
# BpHook::deny(@lines). Never re-parses the payload (BpHook::parse_count()
# is unchanged by run()). Session facts come only from the core
# (BpHook::session_id/is_armed) -- no drive-solo/continuity/run-state/
# current.json file is read directly, no $CLAUDE_CODE_SESSION_ID is read
# (Decision 3). Fail direction: open (return 0) on any internal ambiguity.
package BpHook::Guards::GuardGitMutations;
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd ();

my $SELF_DIR;
{
    my $f = __FILE__;
    $f = Cwd::abs_path($f) // $f;
    $SELF_DIR = dirname($f);
}
require "$SELF_DIR/../../BpHook.pm"
    unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
require "$SELF_DIR/Common.pm"
    unless grep { m{(?:^|/)Guards/Common\.pm$} } keys %INC;
require "$SELF_DIR/Shell.pm"
    unless grep { m{(?:^|/)Guards/Shell\.pm$} } keys %INC;

my $MASK_MAX = 8192;

# Package 08 Amendment 1 (Decision 48), spec sec 2.1 P0a. Bounds the only
# uncapped work _heredoc_write_only_outer does: the linear walk over $cmd.
my $HEREDOC_WALK_MAX = 262144;

# Odd-punctuation heredoc delimiter (line 294 of the source hook), and the
# "unquoted heredoc opener" check (source line 246). Both operate per-line
# (grep -E semantics), against the RAW command.
my $UNQUOTED_HD_OPENER_RE = qr/<<-?[ \t]*([^'"]|$)/;
my $ODD_HD_DELIM_RE = qr/<<-?[ \t]*([^A-Za-z0-9_'" \t]|'[A-Za-z0-9_]*[^A-Za-z0-9_']|"[A-Za-z0-9_]*[^A-Za-z0-9_"]|[A-Za-z0-9_]*[^A-Za-z0-9_'" \t])/;

my $SHELLWORD_WORD_RE = qr/
    (^|[;&|\s])(bash|sh|zsh|ksh|dash|eval|xargs)([\s]|$)
  | (^|[;&|\s])(perl|ruby|node)[\s]+-e([\s]|$)
  | (^|[;&|\s])(python|python3)[\s]+-c([\s]|$)
/x;

# Package 08 (guard-git-mutations-heredoc-false-positive). Allow-list of
# simple commands a write-only heredoc command may be composed of; none of
# these execute their arguments. Spec sec 2.1 P10.
my %HEREDOC_ALLOWED_VERB = map { ($_ => 1) }
    qw(cat mkdir ls wc head tail echo printf cd pwd true);

# ---------------------------------------------------------------------------
# _heredoc_walk($cmd) -> ($outer, \@openers) on success, or the empty list
# () on refusal (Amendment 1, spec sec 2.1 W). A state machine similar in
# its transitions to BpHook::Guards::Shell::strip_noise (none/squote/dquote/
# heredoc -- the old "comment" state is gone, see R1 below), but its OUTPUT
# differs: non-heredoc text is copied through unchanged (never masked), each
# heredoc opener token is replaced by the same number of spaces, and every
# heredoc body line plus its terminator line is removed entirely (newline
# included); the newline ending the opener line is kept. One extension over
# strip_noise: a final line with no trailing newline that equals the
# delimiter also counts as terminated.
#
# Each element of @openers is a hashref: { delim, quoted, offset, line,
# body, terminated }, where offset/line are positions in $outer.
#
# Refuses (returns ()), and stops the walk at once, on:
#   R1: a '#' read in state 'none' (not inside a quote, heredoc body, or the
#       second half of a backslash pair already consumed). Removes the old
#       comment-state machine and its predecessor test entirely.
#   R2: a '<<' read in state 'none' that is not a COMPLETE opener -- a
#       non-empty delimiter, a matching closing quote if one was opened,
#       then end-of-input or one of the boundary chars (space/tab/newline/
#       ;/&/|/</>/(/)) immediately after. The walker never falls back to
#       treating an incomplete '<<' as plain text.
#
# Linear time (S2): the outer line index of each opener comes from a
# running newline counter updated by the $append closure below, never by
# recounting $out.
#
# Pure. Never dies on purpose, never spawns a process.
# ---------------------------------------------------------------------------
sub _heredoc_walk {
    my ($cmd) = @_;
    my @c = split //, $cmd, -1;
    my $n = scalar @c;
    my $out = '';
    my $nl_count = 0;
    my $state = 'none'; # none | squote | dquote | heredoc
    my ($hd_delim, $hd_quoted, $hd_tabs, $hd_pending) = ('', 0, 0, 0);
    my @openers;
    my $cur;      # record for the heredoc currently being read
    my $line = ''; # raw text of the current heredoc line, no trailing \n
    my $body = ''; # raw body text accumulated for $cur
    my $i = 0;

    my $append = sub {
        my ($chunk) = @_;
        $out .= $chunk;
        $nl_count += ($chunk =~ tr/\n//);
    };

    while ($i < $n) {
        my $ch = $c[$i];

        if ($state eq 'heredoc') {
            if ($ch eq "\n") {
                my $chk = $line;
                $chk =~ s/^\t+// if $hd_tabs;
                if ($chk eq $hd_delim) {
                    $cur->{terminated} = 1;
                    $cur->{body} = $body;
                    $state = 'none';
                }
                else {
                    $body .= $line . "\n";
                }
                $line = '';
                $i++;
                next;
            }
            $line .= $ch;
            $i++;
            next;
        }

        if ($state eq 'squote') {
            $append->($ch);
            $state = 'none' if $ch eq "\x27";
            $i++;
            next;
        }

        if ($state eq 'dquote') {
            if ($ch eq "\\" && $i + 1 < $n) {
                $append->($ch . $c[$i + 1]);
                $i += 2;
                next;
            }
            if ($ch eq "\$" && $i + 1 < $n && $c[$i + 1] eq '(') {
                my $depth = 1;
                my $j = $i + 2;
                my $buf = "\$(";
                while ($j < $n && $depth > 0) {
                    my $cj = $c[$j];
                    $depth++ if $cj eq '(';
                    $depth-- if $cj eq ')';
                    $buf .= $cj;
                    $j++;
                }
                $append->($buf);
                $i = $j;
                next;
            }
            if ($ch eq "\x60") {
                my $j = $i + 1;
                my $buf = "\x60";
                while ($j < $n && $c[$j] ne "\x60") { $buf .= $c[$j]; $j++ }
                if ($j < $n) { $buf .= $c[$j]; $j++ }
                $append->($buf);
                $i = $j;
                next;
            }
            $append->($ch);
            $state = 'none' if $ch eq q{"};
            $i++;
            next;
        }

        # state 'none'
        if ($hd_pending && $ch eq "\n") {
            $append->("\n");
            $i++;
            $state = 'heredoc';
            $hd_pending = 0;
            $line = '';
            $body = '';
            next;
        }
        if ($ch eq "\x27") { $state = 'squote'; $append->($ch); $i++; next }
        if ($ch eq q{"})   { $state = 'dquote'; $append->($ch); $i++; next }
        if ($ch eq "\\" && $i + 1 < $n) { $append->($ch . $c[$i + 1]); $i += 2; next }
        if ($ch eq '#') {
            return ();                                              # R1
        }
        if ($ch eq '<' && $i + 1 < $n && $c[$i + 1] eq '<') {
            my $j = $i + 2;
            my $tabs = 0;
            if ($j < $n && $c[$j] eq '-') { $tabs = 1; $j++ }
            $j++ while ($j < $n && $c[$j] =~ /[ \t]/);
            my $q = '';
            if ($j < $n && ($c[$j] eq "\x27" || $c[$j] eq q{"})) { $q = $c[$j]; $j++ }
            my $delim = '';
            $delim .= $c[$j++] while ($j < $n && $c[$j] =~ /[A-Za-z0-9_]/);
            return () unless length($delim);                        # R2.1
            if (length($q)) {
                return () unless ($j < $n && $c[$j] eq $q);          # R2.2
                $j++;
            }
            if ($j < $n) {
                return () unless $c[$j] =~ /[ \t\n;&|<>()]/;         # R2.3
            }
            my $offset = length($out);
            my $line_idx = $nl_count;
            $append->(' ' x ($j - $i));
            $i = $j;
            $hd_delim  = $delim;
            $hd_quoted = length($q) ? 1 : 0;
            $hd_tabs   = $tabs;
            $hd_pending = 1;
            $cur = {
                delim => $delim, quoted => $hd_quoted, offset => $offset,
                line => $line_idx, body => '', terminated => 0,
            };
            push @openers, $cur;
            next;
        }
        $append->($ch);
        $i++;
    }

    if ($state eq 'heredoc') {
        my $chk = $line;
        $chk =~ s/^\t+// if $hd_tabs;
        if ($chk eq $hd_delim) {
            $cur->{terminated} = 1;
            $cur->{body} = $body;
        }
        else {
            $cur->{body} = $body . $line;
        }
    }

    return ($out, \@openers);
}

# ---------------------------------------------------------------------------
# _heredoc_segments($m) -> list of [start, end) half-open character ranges,
# splitting $m at every top-level ';', '&', '|', '(', ')' or newline.
# Whitespace-only ranges are kept here and filtered by the caller.
# ---------------------------------------------------------------------------
sub _heredoc_segments {
    my ($m) = @_;
    my @ranges;
    my $len = length($m);
    my $start = 0;
    for (my $i = 0; $i < $len; $i++) {
        my $ch = substr($m, $i, 1);
        if ($ch eq ';' || $ch eq '&' || $ch eq '|' || $ch eq '(' || $ch eq ')' || $ch eq "\n") {
            push @ranges, [$start, $i] if $i > $start;
            $start = $i + 1;
        }
    }
    push @ranges, [$start, $len] if $len > $start;
    return @ranges;
}

sub _heredoc_segment_for {
    my ($ranges, $offset) = @_;
    for my $r (@$ranges) {
        return $r if $offset >= $r->[0] && $offset < $r->[1];
    }
    return undef;
}

sub _heredoc_first_token {
    my ($raw) = @_;
    my ($tok) = $raw =~ /^\s*(\S+)/;
    return $tok;
}

# ---------------------------------------------------------------------------
# _heredoc_has_stdout_redirect($raw_seg, $m_seg) -> true iff $m_seg contains
# a stdout redirect operator (">" or ">>", optionally "1>"/"1>>") at the
# start of a token, followed (after optional raw spaces) by a non-empty
# target whose first character is not '&', '(', '>' or '|'. Spec sec 2.1 P11.
# ---------------------------------------------------------------------------
sub _heredoc_has_stdout_redirect {
    my ($raw_seg, $m_seg) = @_;
    while ($m_seg =~ /(?:^|[\s])1?(>>?)/g) {
        my $rest_start = pos($m_seg);
        my $rest = substr($raw_seg, $rest_start);
        $rest =~ s/^[ \t]+//;
        next unless length($rest);
        my $first = substr($rest, 0, 1);
        return 1 unless $first =~ /[&(>|]/;
    }
    return 0;
}

# ---------------------------------------------------------------------------
# _heredoc_write_only_outer($cmd) -> $outer | undef. Spec sec 2.1. Pure, no
# I/O, never dies on purpose. undef means "no exemption, behave exactly as
# today" (the fail-closed direction). A defined $outer is $cmd with every
# heredoc body (and its opener token) cut out, ready to be re-scanned by the
# existing, unchanged pipeline.
# ---------------------------------------------------------------------------
sub _heredoc_write_only_outer {
    my ($cmd) = @_;
    return undef unless defined $cmd && !ref($cmd);

    return undef unless index($cmd, '<<') >= 0;                # P0
    return undef if length($cmd) > $HEREDOC_WALK_MAX;           # P0a
    return undef if index($cmd, "\r") >= 0;                     # P1
    return undef if index($cmd, '<<<') >= 0;                    # P2
    return undef if BpHook::Guards::Common::line_match($ODD_HD_DELIM_RE, $cmd); # P3

    # P4 deleted (Amendment 1, M1/M4): R1 in _heredoc_walk refuses every
    # case P4 caught (a none-state '#'), and P4 was the source of the
    # uncapped strip_noise calls. The label stays retired.

    my ($outer, $openers) = _heredoc_walk($cmd);                # W
    return undef unless defined $outer;                         # walk refused (R1/R2)
    return undef unless @$openers;                              # P5
    return undef if grep { !$_->{terminated} } @$openers;        # P6

    my %seen_line;
    for my $o (@$openers) {                                     # P7
        return undef if $seen_line{ $o->{line} }++;
    }

    return undef if index($outer, '$(') >= 0;                   # P8
    return undef if index($outer, "\x60") >= 0;
    return undef if index($outer, '<(') >= 0;
    return undef if index($outer, '>(') >= 0;
    return undef if index($outer, "\\") >= 0;                   # P8 (M2)
    return undef if index($outer, '${') >= 0;                   # P8 (new)
    return undef if index($outer, '$[') >= 0;                   # P8 (new)

    for my $o (@$openers) {                                     # P9
        next if $o->{quoted};
        return undef if index($o->{body}, '$(') >= 0;
        return undef if index($o->{body}, "\x60") >= 0;
    }

    for my $o (@$openers) {                                     # P9a (new)
        next if $o->{quoted};
        return undef if index($o->{body}, "\\\n") >= 0;
    }

    return undef if length($outer) > $MASK_MAX;                 # P-CAP (new)

    my $m = BpHook::Guards::Shell::strip_noise($outer);         # S
    return undef unless defined $m && length($m) == length($outer);
    my @ranges = _heredoc_segments($m);

    for my $r (@ranges) {                                       # P10
        my $raw = substr($outer, $r->[0], $r->[1] - $r->[0]);
        next unless $raw =~ /\S/;
        my $tok = _heredoc_first_token($raw);
        return undef unless defined $tok && $HEREDOC_ALLOWED_VERB{$tok};
    }

    for my $o (@$openers) {                                     # P11
        my $seg = _heredoc_segment_for(\@ranges, $o->{offset});
        return undef unless $seg;
        my $raw_seg = substr($outer, $seg->[0], $seg->[1] - $seg->[0]);
        my $tok = _heredoc_first_token($raw_seg);
        return undef unless defined $tok && $tok eq 'cat';
        my $m_seg = substr($m, $seg->[0], $seg->[1] - $seg->[0]);
        return undef unless _heredoc_has_stdout_redirect($raw_seg, $m_seg);
    }

    return $outer;
}

# ---------------------------------------------------------------------------
# _git_scan_target($cmd) -> ($scan, $raw_kind). Faithful port of
# git_scan_target() in plugins/butler/hooks/guard-git-mutations.sh (lines
# 97-453), operating on Perl characters instead of bash's byte string, with
# BpHook::Guards::Shell::strip_noise standing in for bp_strip_shell_noise.
# ---------------------------------------------------------------------------
sub _git_scan_target {
    my ($cmd) = @_;

    # Package 08: a write-only heredoc (every heredoc terminated, allow-
    # listed, never executed) is re-scanned with its bodies cut out, so the
    # raw-fallback triggers below never see mutation-shaped text that only
    # ever gets written to a file. See _heredoc_write_only_outer's own doc.
    my $outer = _heredoc_write_only_outer($cmd);
    return _git_scan_target($outer) if defined $outer;

    my $len = length($cmd);

    # 1. Over-long command: raw fallback without even walking it.
    if ($len > $MASK_MAX) {
        return ($cmd, 'toolong');
    }

    my $has_bs   = (index($cmd, "\\") >= 0) ? 1 : 0;
    my $has_hash = (index($cmd, '#') >= 0)  ? 1 : 0;
    my $has_hd   = (index($cmd, '<<') >= 0) ? 1 : 0;

    my $go_to_walk = 1;
    if ($has_bs) {
        if ($has_hash || $has_hd) {
            return ($cmd, 'escape');
        }
        (my $bs_probe = $cmd) =~ s/\\\n//g;
        if (index($bs_probe, "\\") >= 0) {
            return ($cmd, 'escape');
        }
        # every backslash is a line continuation -> fall through
    }
    elsif ($has_hash) {
        if (!$has_hd) {
            return ($cmd, 'escape');
        }
        if (BpHook::Guards::Common::line_match($UNQUOTED_HD_OPENER_RE, $cmd)) {
            return ($cmd, 'escape');
        }
        # falls through to the heredoc branch, carrying G2
    }

    if ($has_hd) {
        if (index($cmd, "\r") >= 0) {
            return ($cmd, 'escape');
        }
        if (BpHook::Guards::Common::line_match($ODD_HD_DELIM_RE, $cmd)) {
            return ($cmd, 'escape');
        }
        my $hd_stripped = BpHook::Guards::Shell::strip_noise($cmd);
        if (!defined $hd_stripped || !length $hd_stripped) {
            return ($cmd, 'escape');
        }
        if ($has_hash) {
            (my $hashed_cmd = $cmd) =~ s/#/q/g;
            my $hd_alt = BpHook::Guards::Shell::strip_noise($hashed_cmd);
            if (!defined $hd_alt || !length $hd_alt) {
                return ($cmd, 'escape');
            }
            (my $a = $hd_stripped) =~ s/[^ ]/x/g;
            (my $b = $hd_alt) =~ s/[^ ]/x/g;
            if ($a ne $b) {
                return ($cmd, 'escape');
            }
        }
        if (BpHook::Guards::Common::line_match(qr/\x60|\$\(/, $hd_stripped)) {
            return ($cmd, 'carrier');
        }
        if (BpHook::Guards::Common::line_match($SHELLWORD_WORD_RE, $hd_stripped)) {
            return ($cmd, 'shellword');
        }
        return ($hd_stripped, 'heredoc');
    }

    # 5. The three-state quote walk.
    my @chars = split //, $cmd, -1;
    my $n = scalar @chars;
    my $state = 'NONE'; # NONE | SINGLE | DOUBLE
    my $carrier = 0;
    my $out = '';
    my ($qbuf, $qhaswhite, $qadjacent) = ('', 0, 0);
    my $adj_re = qr/(^|[;&|\s({])git[\s]+$/;
    my $i = 0;
    while ($i < $n) {
        my $c = $chars[$i];
        if ($state eq 'NONE') {
            if ($c eq "'") {
                $state = 'SINGLE'; $qbuf = ''; $qhaswhite = 0;
                $qadjacent = ($out =~ $adj_re) ? 1 : 0;
            }
            elsif ($c eq '"') {
                $state = 'DOUBLE'; $qbuf = ''; $qhaswhite = 0;
                $qadjacent = ($out =~ $adj_re) ? 1 : 0;
            }
            elsif ($c eq "\x60") {
                $carrier = 1; $out .= "\x60";
            }
            elsif ($c eq '$') {
                my $next = ($i + 1 < $n) ? $chars[$i + 1] : '';
                $carrier = 1 if $next eq '(';
                $out .= '$';
            }
            else {
                $out .= $c;
            }
        }
        elsif ($state eq 'SINGLE') {
            if ($c eq "'") {
                $state = 'NONE';
                if ($qhaswhite == 0 && $qadjacent == 1) {
                    $out .= $qbuf;
                }
                else {
                    $out .= "'" . ($qbuf =~ s/./X/gr) . "'";
                }
            }
            elsif ($c eq ' ' || $c eq "\t" || $c eq "\n") {
                $qhaswhite = 1; $qbuf .= $c;
            }
            else {
                $qbuf .= $c;
            }
        }
        elsif ($state eq 'DOUBLE') {
            if ($c eq '"') {
                $state = 'NONE';
                if ($qhaswhite == 0 && $qadjacent == 1) {
                    $out .= $qbuf;
                }
                else {
                    $out .= '"' . ($qbuf =~ s/./X/gr) . '"';
                }
            }
            elsif ($c eq "\x60") {
                $carrier = 1; $qbuf .= $c;
            }
            elsif ($c eq '$') {
                my $next = ($i + 1 < $n) ? $chars[$i + 1] : '';
                $carrier = 1 if $next eq '(';
                $qbuf .= $c;
            }
            elsif ($c eq ' ' || $c eq "\t" || $c eq "\n") {
                $qhaswhite = 1; $qbuf .= $c;
            }
            else {
                $qbuf .= $c;
            }
        }
        $i++;
    }

    # 2. Unbalanced quoting.
    if ($state ne 'NONE') {
        return ($cmd, 'unbalanced');
    }
    # 3. An unquoted backtick or $( anywhere.
    if ($carrier) {
        return ($cmd, 'carrier');
    }
    # 4. shell/eval/xargs/perl|ruby|node -e/python -c in command position.
    (my $out_nc = $out) =~ s/\\\n//g;
    if (BpHook::Guards::Common::line_match($SHELLWORD_WORD_RE, $out_nc)) {
        return ($cmd, 'shellword');
    }

    return ($out, 'masked');
}

sub _anchor_for {
    my ($reason) = @_;
    return '(^|[;&|\s\'"\x60({])' if $reason eq 'shellword';
    return '(^|[;&|\s\x60({])'    if $reason eq 'carrier';
    return '(^|[;&|\s({])';
}

# ---------------------------------------------------------------------------
# run($p, @args) -> 0 | 2.
# ---------------------------------------------------------------------------
sub run {
    my ($p, @args) = @_;
    $p = {} unless ref $p eq 'HASH';
    return 0 unless BpHook::payload_ok();

    if (grep { $_ eq '--only-during-butler-run' } @args) {
        my $ledger = $ENV{BP_LEDGER};
        my $applies = (defined $ledger && length $ledger)
            || BpHook::is_armed(BpHook::session_id($p));
        return 0 unless $applies;
    }

    my $ti = $p->{tool_input};
    return 0 unless ref $ti eq 'HASH';
    my $cmd = $ti->{command};
    return 0 unless defined $cmd && !ref($cmd) && length $cmd;

    my ($scan, $raw_kind) = _git_scan_target($cmd);
    my $anchor = _anchor_for($raw_kind);
    my $cmd_line = 'Command: ' . BpHook::Guards::Common::echo_cmd($cmd);

    my $gitopt = BpHook::Guards::Common::git_opt_re();
    # redteam H2 ("git -C <dir>"/"git -c k=v" past the flags-only group) and
    # M3 (the list/show exemption checked against the whole scan instead of
    # the matched occurrence) both apply here, mirroring GuardBash's fix.
    my $stash_re = qr/${anchor}git[\s]+${gitopt}stash\b(?![\s]+(list|show)\b)/;
    my $mut_re   = qr/${anchor}git[\s]+${gitopt}(checkout|switch|restore|reset|clean)\b/;

    if (BpHook::Guards::Common::line_match($stash_re, $scan))
    {
        return BpHook::deny(
            BpHook::Guards::Common::fit(
                q{BLOCKED: git stash is forbidden: it silently removes uncommitted work; use 'git diff' to inspect ('git stash list/show' are allowed).}
            ),
            BpHook::Guards::Common::fit($cmd_line),
        );
    }

    if (BpHook::Guards::Common::line_match($mut_re, $scan)) {
        return BpHook::deny(
            BpHook::Guards::Common::fit(
                'BLOCKED: git checkout/switch/restore/reset/clean are forbidden: each can discard uncommitted work; change files only via Edit/Write.'
            ),
            BpHook::Guards::Common::fit($cmd_line),
        );
    }

    # Package 35 / Decision 117: a subagent payload (agent_id present) is
    # denied every git verb that mutates the index, refs or history, or
    # talks to a remote -- the driver's own verdicts (above) are unchanged
    # for everyone, including the driver, which never reaches this block.
    if (defined BpHook::agent_id($p)) {
        if (_subagent_git_index_mutation($scan, $anchor, $gitopt)) {
            return BpHook::deny(
                BpHook::Guards::Common::fit(
                    'BLOCKED: a subagent cannot change the git index, refs or history, or talk to a remote; the driver owns git.'
                ),
                BpHook::Guards::Common::fit($cmd_line),
            );
        }
    }

    return 0;
}

# ---------------------------------------------------------------------------
# _subagent_git_index_mutation($scan, $anchor, $gitopt) -> true iff some
# line of $scan invokes a Decision-117/118 mutating git verb. $scan is the
# already-masked command (quotes/heredoc/backtick-handled by
# _git_scan_target). Operates per-line, grep -E semantics, mirroring the
# rest of this module. Every occurrence on a line is inspected (package
# 35 fix-batch M1), not just the first, so a chained good-faith sequence
# such as "git apply --check p && git apply --index p" is still denied on
# its second invocation even though its first is read-only.
# ---------------------------------------------------------------------------
sub _subagent_git_index_mutation {
    my ($scan, $anchor, $gitopt) = @_;

    # Verbs denied unconditionally, in any form: straightforward
    # index/ref/history mutators with no read-only sense. The boundary is
    # (?![-\w]), not \b, so a hyphenated plumbing verb that never touches
    # the index/refs/history is not swept in: merge-file, merge-tree,
    # merge-base, commit-tree, commit-graph (fix-batch S1).
    my $bare_re = qr/${anchor}git[\s]+${gitopt}(add|rm|mv|commit|update-index|update-ref|read-tree|merge|rebase|cherry-pick|revert|am|push|pull|fetch|stage|bisect|gc|prune|repack|filter-branch|replace)(?![-\w])/;
    return 1 if BpHook::Guards::Common::line_match($bare_re, $scan);

    # Verbs whose own arguments decide the verdict (Decision 118). Every
    # occurrence on the line is walked (while (...) =~ /$re/g), not just
    # the leftmost -- fix-batch M1. $anchor carries its own capture group
    # (group 1), so each verb's "rest of the invocation" capture is group 2.
    my @qualified = (
        [qr/${anchor}git[\s]+${gitopt}apply(?![-\w])([^;&|)\n]*)/,         \&_apply_rest_is_mutating],
        [qr/${anchor}git[\s]+${gitopt}branch(?![-\w])([^;&|)\n]*)/,        \&_branch_rest_is_mutating],
        [qr/${anchor}git[\s]+${gitopt}tag(?![-\w])([^;&|)\n]*)/,           \&_tag_rest_is_mutating],
        [qr/${anchor}git[\s]+${gitopt}notes(?![-\w])([^;&|)\n]*)/,         \&_notes_rest_is_mutating],
        [qr/${anchor}git[\s]+${gitopt}worktree(?![-\w])([^;&|)\n]*)/,      \&_worktree_rest_is_mutating],
        [qr/${anchor}git[\s]+${gitopt}submodule(?![-\w])([^;&|)\n]*)/,     \&_submodule_rest_is_mutating],
        [qr/${anchor}git[\s]+${gitopt}remote(?![-\w])([^;&|)\n]*)/,        \&_remote_rest_is_mutating],
        [qr/${anchor}git[\s]+${gitopt}config(?![-\w])([^;&|)\n]*)/,        \&_config_rest_is_mutating],
        [qr/${anchor}git[\s]+${gitopt}symbolic-ref(?![-\w])([^;&|)\n]*)/,  \&_symbolic_ref_rest_is_mutating],
        [qr/${anchor}git[\s]+${gitopt}reflog(?![-\w])([^;&|)\n]*)/,        \&_reflog_rest_is_mutating],
    );
    for my $line (split /\n/, $scan) {
        for my $q (@qualified) {
            my ($re, $classifier) = @$q;
            while ($line =~ /$re/g) {
                my $rest = defined $2 ? $2 : '';
                return 1 if $classifier->($rest);
            }
        }
    }

    return 0;
}

# ---------------------------------------------------------------------------
# _strip_redirects($rest) -> $rest with shell redirection tokens (and their
# targets, whether attached or space-separated) removed, so a redirect is
# never mistaken for a positional argument (fix-batch M2 point 1). Order
# matters: the fd-duplication and &> forms are stripped before the plain
# ">"/">>" form, which would otherwise eat into them.
# ---------------------------------------------------------------------------
sub _strip_redirects {
    my ($rest) = @_;
    return '' unless defined $rest;
    $rest =~ s/\d*>&\d+//g;       # 2>&1, >&2 -- no filename target
    $rest =~ s/&>\s*\S*//g;       # &>file, &> file
    $rest =~ s/\d*>>?\s*\S*//g;   # >file, >>file, 2>/dev/null, > out.txt
    $rest =~ s/<\s*\S*//g;        # <file
    return $rest;
}

# ---------------------------------------------------------------------------
# Per-verb qualifier classifiers. Each takes the raw text following the
# verb (up to the next shell separator) and returns true iff that
# invocation mutates the index, refs, history or a remote per Decision 118.
# ---------------------------------------------------------------------------

sub _apply_rest_is_mutating {
    my ($rest) = @_;
    return 0 unless defined $rest && length $rest;
    return 1 if $rest =~ /(?:^|\s)(?:--cached|--index)(?:\s|=|$)/;
    return 1 if $rest =~ /(?:^|\s)(?:-3|--3way)(?:\s|$)/;
    return 0;
}

sub _branch_rest_is_mutating {
    my ($rest) = @_;
    $rest = _strip_redirects($rest);
    return 0 unless defined $rest && length $rest;

    my $mutating_re    = qr/^(?:-d|-D|--delete|-m|-M|--move|-c|-C|--copy|-f|--force|-u|--set-upstream-to(?:=.*)?|--unset-upstream|--edit-description|-t|--track|--no-track|--create-reflog)$/;
    my $list_flag_re   = qr/^(?:-a|--all|-r|--remotes|-l|--list|-v|-vv|--verbose|--show-current)$/;
    my $list_eq_re     = qr/^(?:--sort=.*|--format=.*)$/;
    my $ref_arg_flag_re = qr/^(?:--contains|--no-contains|--merged|--no-merged|--points-at)$/; # takes a ref argument

    my @tokens = grep { length } split /\s+/, $rest;
    my $list_mode = 0;
    while (@tokens) {
        my $tok = shift @tokens;
        return 1 if $tok =~ $mutating_re;
        if ($tok =~ $list_flag_re || $tok =~ $list_eq_re) {
            $list_mode = 1;
            next;
        }
        if ($tok =~ $ref_arg_flag_re) {
            $list_mode = 1;
            shift @tokens if @tokens && $tokens[0] !~ /^-/;
            next;
        }
        if ($tok =~ /^-/) {
            # An unrecognised flag: fail open on the flag itself (fix-batch
            # M2 point 3) -- but it does not, by itself, license a
            # positional branch-name argument that follows.
            next;
        }
        # A positional token: a glob pattern once a listing flag has put us
        # in list mode (e.g. "branch --list 'feat*'"), otherwise a branch
        # name to create/rename onto.
        return 1 unless $list_mode;
    }
    return 0;
}

sub _tag_rest_is_mutating {
    my ($rest) = @_;
    my @tokens = grep { length } split /\s+/, (defined $rest ? $rest : '');
    return 0 unless @tokens; # bare "git tag" -- listing form, allow
    return 0 if $tokens[0] =~ /^(?:-l|--list)$/;
    return 1;
}

sub _notes_rest_is_mutating {
    my ($rest) = @_;
    my @tokens = grep { length } split /\s+/, (defined $rest ? $rest : '');
    return 1 unless @tokens; # no subcommand -- not one of the two allowed forms
    return 0 if $tokens[0] =~ /^(?:list|show)$/;
    return 1;
}

sub _worktree_rest_is_mutating {
    my ($rest) = @_;
    my @tokens = grep { length } split /\s+/, (defined $rest ? $rest : '');
    return 0 unless @tokens; # bare "git worktree" lists worktrees
    return 0 if $tokens[0] eq 'list';
    return 1;
}

sub _submodule_rest_is_mutating {
    my ($rest) = @_;
    my @tokens = grep { length } split /\s+/, (defined $rest ? $rest : '');
    return 0 unless @tokens; # bare "git submodule" -- status-like listing
    return 0 if $tokens[0] eq 'status';
    return 1;
}

sub _remote_rest_is_mutating {
    my ($rest) = @_;
    my @tokens = grep { length } split /\s+/, (defined $rest ? $rest : '');
    return 0 unless @tokens; # bare "git remote" -- allow
    my $i = 0;
    $i++ if $tokens[0] eq '-v'; # "git remote -v" stays a listing form
    return 0 unless exists $tokens[$i]; # nothing after -v -- allow
    return 0 if $tokens[$i] =~ /^(?:show|get-url)$/;
    return 1;
}

sub _config_rest_is_mutating {
    my ($rest) = @_;
    my @tokens = grep { length } split /\s+/, (defined $rest ? $rest : '');
    return 0 unless @tokens; # bare "git config" -- allow (not a write)
    my $deny_flag_re = qr/^(?:--unset(?:-all)?|--add|--replace-all|--rename-section|--remove-section|-e|--edit)$/;
    my $positional_count = 0;
    for my $tok (@tokens) {
        return 1 if $tok =~ $deny_flag_re;
        $positional_count++ unless $tok =~ /^-/;
    }
    return 1 if $positional_count >= 2; # "config <key> <value>" write form
    return 0;
}

sub _symbolic_ref_rest_is_mutating {
    my ($rest) = @_;
    my @tokens = grep { length } split /\s+/, (defined $rest ? $rest : '');
    return 0 unless @tokens; # bare invocation -- read attempt, allow
    my $positional_count = 0;
    for my $tok (@tokens) {
        return 1 if $tok =~ /^(?:-d|--delete)$/;
        $positional_count++ unless $tok =~ /^-/;
    }
    return 1 if $positional_count >= 2; # a write (ref + new target)
    return 0;
}

sub _reflog_rest_is_mutating {
    my ($rest) = @_;
    my @tokens = grep { length } split /\s+/, (defined $rest ? $rest : '');
    return 0 unless @tokens; # bare "git reflog" -- allow
    return 0 if $tokens[0] eq 'show';
    return 1;
}

1;
