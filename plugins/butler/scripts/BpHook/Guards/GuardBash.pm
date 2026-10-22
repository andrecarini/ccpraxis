# BpHook::Guards::GuardBash -- the merged Bash PreToolUse guard (package 14
# of blueprint hook-continuity-remake), successor to the old separate
# headless-background, judge-checks and validation-interlock Bash guards,
# now merged into hooks/guard-bash.sh.
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 14-guards-remake-spec.md sec 3.1. Architecture:
# plugins/butler/docs/hook-architecture.md ("guard-bash" successor row).
#
# run($p, @args) never calls exit, never dies on purpose, never spawns a
# process (no system/exec/backtick/qx/pipe-open). Prints only through
# BpHook::deny(@lines). Never re-parses the payload (BpHook::parse_count()
# is unchanged by run()). Session facts come only from the core
# (BpHook::session_id/agent_id/role/is_armed/data_dir) -- no drive-solo/
# continuity/run-state/current.json file is read directly, no
# $CLAUDE_CODE_SESSION_ID is read (Decision 3). Fail direction after the
# wrapper's prefilter: open (return 0) on any internal ambiguity, except
# where a rule below says otherwise (none do, in this successor).
package BpHook::Guards::GuardBash;
use strict;
use warnings;
use JSON::PP ();
use File::Basename qw(dirname basename);
use File::Spec ();
use Cwd ();
use Time::HiRes ();

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

my $TUID_NAME_RE = qr/^[A-Za-z0-9_-]{1,128}$/;

# ---------------------------------------------------------------------------
# small helpers, local to this module.
# ---------------------------------------------------------------------------

sub _is_true_json {
    my ($v) = @_;
    return 0 unless defined $v;
    return $v ? 1 : 0 if ref $v;
    return ($v eq 'true' || $v eq '1') ? 1 : 0;
}

sub _digits_or_default {
    my ($v, $default) = @_;
    return $default unless defined $v && length $v;
    return $default unless $v =~ /^[0-9]+$/;
    return $v + 0;
}

sub _sanitize {
    my ($s, $max) = @_;
    return '' unless defined $s;
    # NIT-4 (24-interlock-scope-review): keep '.', which _valid_member_name
    # allows in a package/blueprint name -- stripping it mangled the name
    # shown in the deny text.
    (my $v = $s) =~ s/[^A-Za-z0-9_.-]//g;
    return substr($v, 0, $max);
}

sub _read_bytes {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# marker mtime freshness. $policy is 'fresh' (future or unreadable mtime
# counts as fresh, spec 2.5 -- own/driver markers) or 'stale' (future or
# unreadable mtime counts as stale, spec 3.1(b)/GB-10 -- the tree-wide
# interlock, so a foreign marker with clock-skewed or unknown mtime never
# wedges the whole tree). $stale_min is the already-normalised positive
# integer.
sub _fresh_mtime {
    my ($path, $stale_min, $policy) = @_;
    $policy = 'fresh' unless defined $policy;
    my @st = stat($path);
    if (!@st) {
        return $policy eq 'stale' ? 0 : 1; # unreadable
    }
    my $mtime = $st[9];
    if (!defined $mtime) {
        return $policy eq 'stale' ? 0 : 1;
    }
    my $now = time();
    if ($mtime > $now) {
        return $policy eq 'stale' ? 0 : 1; # future mtime
    }
    my $age_min = ($now - $mtime) / 60;
    return 1 if $age_min < $stale_min;
    return 0;
}

sub _stale_min {
    my $v = $ENV{CCPRAXIS_VALIDATION_STALE_MIN};
    return _digits_or_default($v, 180) > 0 ? _digits_or_default($v, 180) : 180;
}

# ---------------------------------------------------------------------------
# MATCH_TEXT / anchor computation shared by GB-a and GB-c (spec sec 3.1
# "MATCH_TEXT and anchor class").
# ---------------------------------------------------------------------------
sub _match_text_and_reason {
    my ($cmd) = @_;
    my $max = _digits_or_default($ENV{BP_GUARD_MAX_STRIP_BYTES}, 8000);
    $max = 8000 unless $max > 0;
    if (length($cmd) <= $max) {
        # m8: reuse Common's shared shell/eval/heredoc-into-shell detector
        # instead of an inline copy of just the "-c" half.
        if (BpHook::Guards::Common::is_shell_or_eval_invocation($cmd)) {
            return ($cmd, 'shellword');
        }
        if (BpHook::Guards::Common::line_match(qr/\x60|\$\(/, $cmd)) {
            return ($cmd, 'carrier');
        }
        my $stripped = BpHook::Guards::Shell::strip_noise($cmd);
        if (defined $stripped && length $stripped) {
            return ($stripped, 'plain');
        }
    }
    return ($cmd, 'plain');
}

sub _anchor_for {
    my ($reason) = @_;
    return '(^|[;&|\s\'"\x60({])' if $reason eq 'shellword';
    return '(^|[;&|\s\x60({])'    if $reason eq 'carrier';
    return '(^|[;&|\s({])';
}

# ---------------------------------------------------------------------------
# GB-a -- coordinator denials. BP_LEDGER non-empty, any BP_ROLE.
# ---------------------------------------------------------------------------
sub _gb_a {
    my ($p, $cmd) = @_;
    return undef unless defined $ENV{BP_LEDGER} && length $ENV{BP_LEDGER};

    my ($match_text, $reason) = _match_text_and_reason($cmd);
    my $A = _anchor_for($reason);
    my $GITOPT = BpHook::Guards::Common::git_opt_re();
    my $cmd_line = 'Command: ' . BpHook::Guards::Common::echo_cmd($cmd);

    # 1: git working-tree / history mutations.
    if (BpHook::Guards::Common::line_match(
            qr/${A}git[[:space:]]+${GITOPT}(checkout|switch|restore|reset|clean|rebase|merge|commit|push)\b/,
            $match_text))
    {
        return [
            'BLOCKED: git working-tree/history mutations are reserved for the orchestrator. Coordinators and workers change files only via Edit/Write.',
            $cmd_line,
        ];
    }

    # 2: git stash (list/show excepted). The negative lookahead is checked
    # against the SAME occurrence, not the whole command (redteam M3), so
    # "git stash list && git stash pop" still denies on the pop.
    if (BpHook::Guards::Common::line_match(
            qr/${A}git[[:space:]]+${GITOPT}stash\b(?![[:space:]]+(list|show)\b)/, $match_text))
    {
        return [
            'BLOCKED: git stash mutations are forbidden in coordinator sessions (list/show are fine).',
            $cmd_line,
        ];
    }

    # 3: rm -rf outside the allowed roots.
    if (BpHook::Guards::Common::line_match(qr/${A}rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f/, $match_text)
        || BpHook::Guards::Common::line_match(qr/${A}rm[[:space:]]+-[a-zA-Z]*f[a-zA-Z]*r/, $match_text))
    {
        my $bp_dir = $ENV{BP_DIR};
        my $exempt = (index($match_text, '/tmp/') >= 0)
            || (index($match_text, 'integration_test/screenshots') >= 0)
            || (defined $bp_dir && length $bp_dir && index($match_text, $bp_dir) >= 0);
        unless ($exempt) {
            return [
                'BLOCKED: rm -rf is only allowed under /tmp, the blueprint dir, or the test screenshot dir; record unexpected state in the ledger instead.',
                $cmd_line,
            ];
        }
    }

    # 4: deploys / publishing.
    if (BpHook::Guards::Common::line_match(qr/${A}firebase[[:space:]]+deploy\b/, $match_text)
        || BpHook::Guards::Common::line_match(qr/${A}gcloud[[:space:]][^;|&]*deploy\b/, $match_text)
        || BpHook::Guards::Common::line_match(qr/${A}npm[[:space:]]+publish\b/, $match_text))
    {
        return [
            'BLOCKED: deploys and publishing never happen from coordinator sessions (CI-only by project policy).',
            $cmd_line,
        ];
    }

    # 5: BP_BASH_EXTRA_DENY.
    my $extra = $ENV{BP_BASH_EXTRA_DENY};
    if (defined $extra && length $extra) {
        my $compiled = eval { qr/$extra/ };
        if (defined $compiled && BpHook::Guards::Common::line_match($compiled, $match_text)) {
            return [
                'BLOCKED: the command matches the BP_BASH_EXTRA_DENY policy.',
                $cmd_line,
            ];
        }
    }

    return undef;
}

# ---------------------------------------------------------------------------
# GB-b -- headless background. BP_LEDGER non-empty.
# ---------------------------------------------------------------------------
sub _gb_b {
    my ($p, $cmd, $ti) = @_;
    return undef unless defined $ENV{BP_LEDGER} && length $ENV{BP_LEDGER};
    return undef unless ref $ti eq 'HASH' && _is_true_json($ti->{run_in_background});
    return undef if defined BpHook::sole_invocation($cmd, 'butler-hold');

    my $role = $ENV{BP_ROLE};
    my $who;
    if (!defined $role || $role eq '' || $role eq 'coordinator') {
        $who = 'coordinator';
    }
    else {
        $who = "\x60" . _sanitize($role, 32) . "\x60";
    }
    return [
        "BLOCKED: run_in_background is forbidden in a headless $who: ending the turn ends the process, so its notification never arrives.",
        'Run it in the foreground and wait for the result in this turn; only a command that is exactly one butler-hold call may run in the background.',
    ];
}

# ---------------------------------------------------------------------------
# GB-c -- judge checks. BP_LEDGER non-empty, BP_ROLE eq harvest-judge.
# ---------------------------------------------------------------------------
sub _gb_c {
    my ($p, $cmd) = @_;
    return undef unless defined $ENV{BP_LEDGER} && length $ENV{BP_LEDGER};
    my $role = $ENV{BP_ROLE};
    return undef unless defined $role && $role eq 'harvest-judge';

    my ($match_text, undef) = _match_text_and_reason($cmd);
    my $plain_anchor = _anchor_for('plain');
    if (BpHook::Guards::Common::line_match(
            qr/${plain_anchor}([^\s;&|]*\/)?(pnpm|npm|yarn)[[:space:]]+(run[[:space:]]+)?(lint|build|test)\b/,
            $match_text))
    {
        return [
            'BLOCKED: harvest judges verify a declared checks: entry from its recorded evidence, never by re-running it.',
            'Command: ' . BpHook::Guards::Common::echo_cmd($cmd),
        ];
    }
    return undef;
}

# ---------------------------------------------------------------------------
# GB-d -- validation interlock.
# ---------------------------------------------------------------------------
my $VALIDATION_RE = qr/
    (^|[;&|\s'"\x60(])(pnpm|npm|yarn)[[:space:]]+(run[[:space:]]+)?(test|build|lint)\b
  | (^|[;&|\s'"\x60(])npx[[:space:]]+(vitest|jest|mocha|playwright)\b
  | (^|[;&|\s'"\x60(])(pytest|prove)\b
  | (^|[;&|\s'"\x60(])(go|cargo|flutter|dart)[[:space:]]+(test|analyze)\b
  | (^|[;&|'"\x60(]|\$\()[\x20\t]*perl[[:space:]]+(-[^[:space:]]+[[:space:]]+)*([^\s;&|]*\/)?run-tests\.pl\b
  | (^|[;&|])[[:space:]]*([^\s;&|]*\/)?run-tests\.pl\b
  | (^|[;&|'"\x60(]|\$\()[\x20\t]*perl[[:space:]]+(-[^[:space:]]+[[:space:]]+)*\S*\.t\b
/x;
# never-halt 03 S7: alternatives 5 and 7 above are perl in COMMAND POSITION
# only (start of text/segment, after a separator, an opening quote/paren/
# backtick, or a "$(" substitution start) -- NOT after arbitrary whitespace,
# so "grep perl x.t"/"echo perl x.t" no longer match (redteam S7). A quote
# char stays a valid anchor: interlock-write-set-scope.t AC-18 pins
# `perl -e 'system("perl t/x.t")'` as validation-shaped via exactly this
# raw-matched, quote-preceded "perl t/x.t" inside the eval'd code, and that
# is a genuinely different command actually being run, not a mere mention.
# The shape-normalising predicate (_perl_test_run) covers every wrapped/
# backslash/aliased form these two alternatives used to catch only via the
# bare-whitespace anchor.

# redteam M1: command substitution ($(...)), a bare subshell ((...)), and a
# shell/eval in command position (bash -c '...') each hide the real
# validation command from strip_noise's quote/heredoc blanking, so those
# three shapes must be matched against the RAW command, exactly like
# GuardBash's own GB-a shellword/carrier escape (spec sec 3.1).
#
# 24-interlock-scope B-8/B-9/B-10: the raw-vs-stripped decision now probes
# the STRIPPED text for a backtick/$(/bare-paren, not the raw command, so a
# quoted argument (e.g. ledger note text) that merely contains one of those
# characters does not switch matching to the raw command. Two triggers still
# force raw matching: is_shell_or_eval_invocation on the raw command
# (unchanged), and a raw command that carries "<<" together with a backtick
# or "$(" (an unquoted heredoc body still expands at shell level even though
# strip_noise blanks it).
#
# 24-interlock-scope-review M-2: an interpreter eval (perl/node/python
# invoked with -e, -E or -c) hides its real payload from strip_noise's own
# quote blanking exactly like the shell -c escape above, so it forces raw
# matching too.
my $INTERP_EVAL_RE = qr/(^|[;&|\s])(perl|node|python3?)[[:space:]]+(-[^\s]+[[:space:]]+)*-[A-Za-z]*[eEc]\b/;

# 34-runner-redirect-operands sec 2.2 -- a shell/interpreter/eval word
# anywhere in a command's non-body text means the heredoc body(ies) may be
# consumed as a real script (stdin, a pipe after the terminator, or a
# captured-then-eval'd copy), so blanking is disabled for the whole command
# (D2, deliberately coarse/global -- spec sec 2.2).
my $SHELLISH_RE = qr/(^|[;&|\s(\x60'"])(?:[^\s;&|'"]*\/)?
                     (?:(?:ba|z|k|da|fi)?sh|pwsh|powershell|perl|node|python3?|ruby|eval|source|\.)
                     (?=[\s;&|)'"]|$)/x;

# 34-runner-redirect-operands review M-1 -- the D2-widening half of
# $SHELLISH_RE: a plain interpreter-runs-a-file mention (perl/node/python/
# ruby with a script argument) does not widen the window on its own (that
# is Decision 114's still-valid case, AC-21/23); eval/source/./a bare shell
# DOES, because it can consume a heredoc body as a script.
my $SHELLISH_NARROW_RE = qr/(^|[;&|\s(\x60'"])(?:[^\s;&|'"]*\/)?
                     (?:(?:ba|z|k|da|fi)?sh|pwsh|powershell|eval|source|\.)
                     (?=[\s;&|)'"]|$)/x;

# A command-text line that ends in a pipe/&&/||  -- or has more '(' than
# ')' -- leaves its statement open past that line, so whatever consumes a
# heredoc's body may sit on a LATER line than its own terminator
# (`cat <<'EOF' |` ... `EOF` ... `bash`; `x=$(cat <<'EOF'` ... `EOF` ...
# `); eval "$x"`). Checked only up to the last terminator (review M-1).
my $LINE_LEFT_OPEN_RE = qr/(?:\|\||&&|\|&|\|)[ \t]*$/;

# REDIR_OP -- spec sec 2.1 "REDIRECT DROP". Alternatives listed longest
# first within each digit-optional/no-digit group so a token like "&>>" is
# never partially matched as "&>" with a stray ">" left over.
my $REDIR_OP = qr/^(?:[0-9]*(?:<<<|<<-|>>|>\||>&|<<|<&|<>|>|<)|&>>|&>)/;

# OPENER (spec sec 2.2, narrowed by 34-runner-redirect-operands review M-2)
# -- the heredoc-word alternatives are tried quoted-forms-first
# (single/double/backslash all -> quoted=1), then the bare form
# (quoted=0); the lookahead after the word requires end-of-line,
# whitespace, or one of ; & | < > ). The quoted/backslash WORD class is
# [A-Za-z0-9_]+, matching Shell::strip_noise's own delimiter grammar
# exactly (not the wider [A-Za-z0-9_.-]+ the spec originally gave) -- a
# delimiter strip_noise cannot parse (e.g. <<'END-DOC') must stay
# unrecognised here too, or its body silently falls back to today's
# (safe) behaviour instead of a phantom blank (M-2).
my $HEREDOC_OPENER_RE = qr/^<<(-)?[ \t]*
    (?:'([A-Za-z0-9_]+)'
      |"([A-Za-z0-9_]+)"
      |\\([A-Za-z0-9_]+)
      |([A-Za-z_][A-Za-z0-9_]*))
    (?=[\s;&|<>)]|$)/x;

# _drop_redirects(@tok) -> @kept -- spec sec 2.1 "REDIRECT DROP". Pure,
# private. Walks tokens left to right; a token that IS (wholly or partly) a
# redirect operator drops itself, and drops the next token too when the
# operator consumed the whole token (its target is then a separate token).
sub _drop_redirects {
    my (@tok) = @_;
    my @kept;
    my $i = 0;
    while ($i < @tok) {
        my $t = $tok[$i];
        if ($t =~ $REDIR_OP) {
            my $rest = substr($t, length($&));
            $i += ($rest eq '') ? 2 : 1;
            next;
        }
        push @kept, $t;
        $i++;
    }
    return @kept;
}

# _try_heredoc_opener($line, $pos) -> ($newpos, \%opener) | (undef, undef).
# Pure, private. $line must have "<<" at $pos.
sub _try_heredoc_opener {
    my ($line, $pos) = @_;
    my $rest = substr($line, $pos);
    if ($rest =~ $HEREDOC_OPENER_RE) {
        my $dash = $1 ? 1 : 0;
        my ($word, $quoted);
        if    (defined $2) { $word = $2; $quoted = 1; }
        elsif (defined $3) { $word = $3; $quoted = 1; }
        elsif (defined $4) { $word = $4; $quoted = 1; }
        elsif (defined $5) { $word = $5; $quoted = 0; }
        return ($pos + length($&), { word => $word, dash => $dash, quoted => $quoted });
    }
    return (undef, undef);
}

# _blank_data_heredocs_impl($cmd) -> $text. May die (caught by the
# _blank_data_heredocs wrapper); pure otherwise, never touches the
# filesystem. Implements the scanner/OPENER/data-heredoc rules of spec
# sec 2.2 exactly.
sub _blank_data_heredocs_impl {
    my ($cmd) = @_;
    my @lines = split /\n/, $cmd, -1;
    my $n = scalar @lines;
    my @is_body = (0) x $n;
    my @recorded;
    my $quote = 'none';
    my @pending;
    my $i = 0;
    my $abort = 0;
    # never-halt 03 S7: a "$(" opened WHILE inside a double quote (the
    # standard "$(cat <<'EOF' ... EOF)" idiom) starts a nested command
    # substitution, which real shells parse with FRESH quoting -- a heredoc
    # operator right after it is a real heredoc, not literal dquote text.
    # Each stack frame remembers the quote state to resume on the matching
    # unquoted ")", plus how many unquoted "(" it has seen since (so an
    # inner subshell/grouping paren doesn't close it early).
    my @qstack;

    OUTER: while ($i < $n) {
        my $line = $lines[$i];
        my $len = length($line);
        my $pos = 0;
        LINE: while ($pos < $len) {
            my $c = substr($line, $pos, 1);
            if ($quote eq 'squote') {
                $quote = 'none' if $c eq "'";
                $pos++;
                next LINE;
            }
            if ($quote eq 'dquote') {
                if ($c eq '\\') { $pos += 2; next LINE; }
                if (substr($line, $pos, 2) eq '$(') {
                    push @qstack, { ret => 'dquote', depth => 0 };
                    $quote = 'none';
                    $pos += 2;
                    next LINE;
                }
                $quote = 'none' if $c eq '"';
                $pos++;
                next LINE;
            }
            # quote eq 'none'
            if (@qstack && $c eq '(') { $qstack[-1]{depth}++; $pos++; next LINE }
            if (@qstack && $c eq ')') {
                if ($qstack[-1]{depth} > 0) { $qstack[-1]{depth}--; $pos++; next LINE }
                my $frame = pop @qstack;
                $quote = $frame->{ret};
                $pos++;
                next LINE;
            }
            if ($c eq "'") { $quote = 'squote'; $pos++; next LINE; }
            if ($c eq '"') { $quote = 'dquote'; $pos++; next LINE; }
            if ($c eq '\\') {
                if ($pos == $len - 1) {
                    if (@pending) { $abort = 1; last LINE; }
                    $pos++;
                    next LINE;
                }
                $pos += 2;
                next LINE;
            }
            if ($c eq '#') {
                my $prev = $pos == 0 ? '' : substr($line, $pos - 1, 1);
                if ($pos == 0 || $prev =~ /[;&|\s(]/) {
                    $pos = $len;
                    next LINE;
                }
                $pos++;
                next LINE;
            }
            if (substr($line, $pos, 3) eq '<<<') {
                $pos += 3;
                next LINE;
            }
            if (substr($line, $pos, 2) eq '<<') {
                my ($newpos, $opener) = _try_heredoc_opener($line, $pos);
                if (defined $opener) {
                    push @pending, $opener;
                    $pos = $newpos;
                    next LINE;
                }
                # S-3 fail-safe: this "<<"/"<<-" LOOKED like it was trying
                # to open a heredoc (quote, backslash, or word character
                # right after it) but no valid opener parsed (e.g.
                # <<E"OF", <<'END DOC', <<"$X", <<'EOF'x). Silently skipping
                # 2 chars and continuing to scan the intended body as
                # ordinary command lines risks a later, unrelated line
                # being read as a phantom terminator and blanking real
                # command text -- abort instead (review S-3).
                my $probe = substr($line, $pos + 2);
                $probe =~ s/^-//;
                $probe =~ s/^[ \t]*//;
                if ($probe =~ /^['"\\]/ || $probe =~ /^[A-Za-z0-9_]/) {
                    $abort = 1;
                    last LINE;
                }
                $pos += 2;
                next LINE;
            }
            $pos++;
        }
        last OUTER if $abort;
        $i++;
        if (@pending && $quote eq 'none') {
            my $cursor = $i;
            for my $h (@pending) {
                my $body_start = $cursor;
                my $term_idx;
                for (my $j = $cursor; $j < $n; $j++) {
                    my $term = $lines[$j];
                    $term =~ s/^\t+// if $h->{dash};
                    if ($term eq $h->{word}) { $term_idx = $j; last; }
                }
                if (!defined $term_idx) { $abort = 1; last; }
                for my $k ($body_start .. $term_idx - 1) { $is_body[$k] = 1; }
                push @recorded, { %$h, body_start => $body_start, body_end => $term_idx };
                $cursor = $term_idx + 1;
            }
            $i = $cursor unless $abort;
        }
        last OUTER if $abort;
    }
    $abort = 1 if $quote ne 'none' || @pending || @qstack;

    return $cmd unless @recorded;

    # D2 (global): no line of the command text (every line that is not a
    # recorded body line) may match $SHELLISH_RE. Decision 115 (review
    # M-1) supersedes Decision 114's plain terminator-bounded window: that
    # bound assumed nothing after the last terminator can consume a
    # heredoc body, which is false for `eval`/`source`/`.`/a shell word, an
    # interpreter's -e/-E/-c, or a statement left open across the
    # terminator (a trailing pipe/&&/||, or an unbalanced paren) --
    # `x=$(cat <<'EOF' ... EOF); eval "$x"` and `cat <<'EOF' | ... EOF
    # bash` both still run the body. The window widens to the WHOLE
    # command when either of those holds; otherwise it stays bounded to
    # the last terminator (keeps AC-21/23 -- a plain, unrelated
    # `perl scripts/run-tests.pl <file>` line after the heredoc closes
    # does not widen).
    my $last_term = 0;
    for my $h (@recorded) { $last_term = $h->{body_end} if $h->{body_end} > $last_term; }

    my $widen = 0;
    for my $li (0 .. $n - 1) {
        next if $is_body[$li];
        if ($lines[$li] =~ $SHELLISH_NARROW_RE
            || BpHook::Guards::Common::line_match($INTERP_EVAL_RE, $lines[$li]))
        {
            $widen = 1;
            last;
        }
    }
    if (!$widen) {
        for my $li (0 .. $last_term) {
            next if $is_body[$li];
            my $l = $lines[$li];
            my $opens  = () = $l =~ /\(/g;
            my $closes = () = $l =~ /\)/g;
            if ($l =~ $LINE_LEFT_OPEN_RE || $opens > $closes) {
                $widen = 1;
                last;
            }
        }
    }
    my $d2_end = $widen ? ($n - 1) : $last_term;
    for my $li (0 .. $d2_end) {
        next if $is_body[$li];
        return $cmd if $lines[$li] =~ $SHELLISH_RE;
    }

    my @out = @lines;
    for my $h (@recorded) {
        my $body = join("\n", @lines[$h->{body_start} .. $h->{body_end} - 1]);
        my $has_backtick_or_sub = ($body =~ /\x60|\$\(/) ? 1 : 0;
        next unless $h->{quoted} || !$has_backtick_or_sub; # D1
        for my $k ($h->{body_start} .. $h->{body_end} - 1) { $out[$k] = ''; }
    }
    return join("\n", @out);
}

# 34-runner-redirect-operands review S-2 -- one heredoc scan per command,
# reused across the (up to) two callers within one guard invocation
# (_validation_shaped and _is_full_sweep_runner commonly share the same
# $cmd). Bounded to a handful of entries: one hook process only ever
# blanks a small, fixed number of distinct command strings (never
# unbounded, since it exits after run()).
my %BLANK_CACHE;

# Above this many bytes the per-character scan cost is not worth paying;
# skip blanking and treat the whole command as command text (fails safe --
# the pre-package-34 behaviour for any input this large).
my $BLANK_MAX_BYTES = 65536;

# _blank_data_heredocs($cmd) -> $text. Spec sec 2.2. Never dies: any
# internal error returns $cmd unchanged. undef -> undef, '' -> ''.
sub _blank_data_heredocs {
    my ($cmd) = @_;
    return $cmd unless defined $cmd;
    return $cmd if index($cmd, '<<') < 0; # fast path
    return $cmd if length($cmd) > $BLANK_MAX_BYTES; # S-2 size cap
    return $BLANK_CACHE{$cmd} if exists $BLANK_CACHE{$cmd};
    my $out = eval { _blank_data_heredocs_impl($cmd) };
    $out = $cmd unless defined $out;
    %BLANK_CACHE = () if scalar(keys %BLANK_CACHE) > 8;
    $BLANK_CACHE{$cmd} = $out;
    return $out;
}

sub _validation_shaped {
    my ($cmd) = @_;
    my $H = _blank_data_heredocs($cmd);
    my $vtext;
    # 24-interlock-scope-review S-3: cap the strip_noise walk the same way
    # GB-a's own _match_text_and_reason does; over the cap, match raw (the
    # conservative direction and the pre-24 behaviour for paren-bearing
    # text).
    my $max = _digits_or_default($ENV{BP_GUARD_MAX_STRIP_BYTES}, 8000);
    $max = 8000 unless $max > 0;
    if (length($cmd) > $max) {
        $vtext = $H;
    }
    else {
        my $stripped = BpHook::Guards::Shell::strip_noise($cmd);
        my $probe = (defined $stripped && length $stripped) ? $stripped : $H;
        if (BpHook::Guards::Common::is_shell_or_eval_invocation($H)
            || BpHook::Guards::Common::line_match(qr/\x60|\$\(|\(/, $probe)
            || (BpHook::Guards::Common::line_match(qr/<</, $H)
                && BpHook::Guards::Common::line_match(qr/\x60|\$\(/, $H))
            || BpHook::Guards::Common::line_match($INTERP_EVAL_RE, $H)
            # 34-runner-redirect-operands review M-1: _blank_data_heredocs
            # left a "<<" heredoc UNBLANKED (D1/D2 said its body is real
            # command text, e.g. a body piped into a shell with no
            # backtick/$( of its own) -- Shell::strip_noise does not know
            # about D1/D2 and unconditionally blanks a quoted heredoc's
            # body, so trusting $probe here would silently lose exactly
            # the text D2 says must stay live. Match raw instead.
            || (index($H, '<<') >= 0 && $H eq $cmd))
        {
            $vtext = $H;
        }
        else {
            $vtext = $probe;
        }
    }
    $vtext = _neutralize_perl_syntax_checks($vtext);
    $vtext =~ s/\\\n/ /g;
    return 1 if BpHook::Guards::Common::line_match($VALIDATION_RE, $vtext);
    return _perl_test_run($cmd);
}

# redteam-3 M2: the exception thrown by _hyg_deadline_check() (BpHook::
# Guards::GuardBash, further below), caught ONLY by _gb_h_impl and (never-
# halt 03 N5) by _perl_test_run above's caller-of-_hyg_commands -- never by
# an outer eval that would otherwise fail OPEN on it like any other internal
# error. A deadline must fail CLOSED. Not a bare string, so a real die()
# elsewhere can never be mistaken for it. Declared here (ahead of every
# user, textually) because it is a lexical `my`: a sub compiled before its
# declaration cannot see it.
my $HYG_DEADLINE_MARKER = { hyg_deadline_exceeded => 1 };

# ---------------------------------------------------------------------------
# never-halt 03 -- shape-normalising test-run predicate (bug 8288, spec sec
# 2.3). Purely ADDITIVE to $VALIDATION_RE above: it only ever turns "not
# validation-shaped" into "validation-shaped". Reuses GB-h's own tokenizer
# stack (BpHook::_segments/_tokenize_words, _hyg_reduce/_hyg_commands via
# shell -c / eval recursion, _hyg_scan_redirects) so every lexical shape
# GB-h already understands (forward-slash, backslash, C:/, /c/, quoted,
# perl.exe, a leading env assignment, -I/-M/-m option words, a wrapper like
# timeout/bash -c) is recognised here too, without re-deriving any of it.
# ---------------------------------------------------------------------------

# _word_text($w) -> defined-or-undef text of a tokenized word ($w is a hash
# with literal/raw/tail keys, as returned by BpHook::_tokenize_words /
# _hyg_reduce). Mirrors _hyg_command_name's own literal-or-safe-raw-dequote
# fallback (redteam-2 S5), but keeps any leading directory part and
# extension -- callers here need the whole path text, not a bare command
# name.
sub _word_text {
    my ($w) = @_;
    return undef unless ref $w eq 'HASH';
    return $w->{literal} if defined $w->{literal};
    if (defined $w->{raw} && _hyg_raw_safe($w->{raw})) {
        return _hyg_dequote($w->{raw});
    }
    return undef;
}

# _perl_cluster_code_text($opt_word_text) -> $code | undef. never-halt 03
# S6/review SHOULD-FIX 1/S2(b): a leading-dash option cluster carries perl
# CODE on the command line (an "e"/"E" letter) rather than a script
# operand -- walked left to right (never a single regex) because a
# value-taking letter (i I M m x d D C F) consumes the rest of the cluster
# as ITS OWN value first, and a bare digit is itself a glued numeric value
# (e.g. the "0777" of "-ln0777e'print'") rather than a letter to test.
# Returns the GLUED code text (possibly '') the moment "e"/"E" is found, or
# undef when no such letter is reachable (a value-letter or end of cluster
# was hit first).
sub _perl_cluster_code_text {
    my ($t) = @_;
    return undef unless defined $t && $t =~ /^-(.*)$/s;
    my $rest = $1;
    my $len = length $rest;
    for my $pos (0 .. $len - 1) {
        my $c = substr($rest, $pos, 1);
        return substr($rest, $pos + 1) if $c eq 'e' || $c eq 'E';
        return undef if $c =~ /^[iIMmxdDCF]$/;
    }
    return undef;
}

# _perl_opt_walk(\@words, $start) -> ($script_idx | undef, $is_syntax_check,
# $code_text | undef). Spec sec 2.3 step 3's option walk, shared verbatim by
# the test-run predicate below (over an argv already redirect-scanned) and
# by the --ledger flag-source reader (over the raw segment's own tokenized
# words). $is_syntax_check is also true for "-MO=.../-MO:..." (compile-only,
# never a test run -- reuses the same "definitely not a test run, skip" verb
# as the original "-c" flag, per Decision 36 S6). $code_text is defined iff
# an "e"/"E" cluster was found (S6/S2(b)): the perl code given directly on
# the command line, glued or taken from the immediately following word when
# nothing is glued -- so a caller can tell "no script operand, and the code
# never touches a test file" (S6: allow) apart from "the code itself
# do/require/runtests a test file" (S2(b): still a test run).
sub _perl_opt_walk {
    my ($words, $start, $opts) = @_;
    $opts ||= {};
    my $keep_unpredictable = $opts->{keep_unpredictable} ? 1 : 0;
    my $i = defined $start ? $start : 0;
    my $n = scalar @$words;
    while ($i < $n) {
        my $t = _word_text($words->[$i]);
        if (!defined $t) {
            # never-halt 09-gb-h-residuals sec 3.14 (Decision 38): a caller
            # that opts in (_perl_test_run only) keeps an unpredictable word
            # as the script index, PROVIDED it doesn't look like an option
            # (raw text starting with '-') -- an unpredictable thing that
            # LOOKS like an option is still too ambiguous to walk past, so
            # that case still aborts exactly like today.
            if ($keep_unpredictable) {
                my $raw = $words->[$i]{raw};
                return ($i, 0, undef) unless defined $raw && $raw =~ /^-/;
            }
            return (undef, 0, undef);
        }
        if ($t eq '--') { $i++; last }
        if ($t =~ /^-[wWXtT]*c[wWXtT]*$/) { return (undef, 1, undef) }
        if ($t =~ /^-MO[=:]/)             { return (undef, 1, undef) }
        my $code = _perl_cluster_code_text($t);
        if (defined $code) {
            if ($code eq '' && $i + 1 < $n) {
                my $nx = _word_text($words->[$i + 1]);
                $code = $nx if defined $nx;
            }
            return (undef, 0, $code);
        }
        if ($t =~ /^-[IMm]$/) { $i += 2; next }
        if ($t =~ /^-./)      { $i++; next }
        last;
    }
    return (undef, 0, undef) if $i >= $n;
    return ($i, 0, undef);
}

# _perl_binary_name($name) -> 0|1. never-halt 03 N4: perl binary names
# beyond a bare "perl"/"perl.exe" (already folded by _hyg_command_name) --
# a versioned copy (perl5, perl5.36.0, ...) and the Windows GUI build
# (wperl/wperl.exe).
sub _perl_binary_name {
    my ($name) = @_;
    return 0 unless defined $name;
    return 1 if $name eq 'perl' || $name eq 'wperl';
    return 1 if $name =~ /^perl5(?:\.\d+)*$/;
    return 0;
}

# _runner_or_dot_t_name($name, $is_winfam) -> 0|1. never-halt 03 S4: a
# command's own (already folded/basename'd/case-normalised) name is the
# runner or a .t file outright -- direct exec/shebang, or a thin wrapper
# _hyg_reduce/_hyg_commands already unwrapped down to this name. On
# Windows-family perls only, an 8.3 alias basename (~N.pl / ~N.t) is judged
# the same way, lexically, without depending on a real alias existing on
# disk.
sub _runner_or_dot_t_name {
    my ($name, $is_winfam) = @_;
    return 0 unless defined $name;
    return 1 if $name eq 'run-tests.pl';
    return 1 if $name =~ /\.t$/;
    return 1 if $is_winfam && $name =~ /~\d+\.(?:pl|t)$/i;
    return 0;
}

# never-halt 09-gb-h-residuals sec 3.14 (Decision 38) -- rule (a): a RAW
# word's own text (quotes stripped, backslash turned to forward slash) is
# test-run-shaped by itself: it ends in ".t" (case-insensitive on
# Windows-family perls) or its basename is "run-tests.pl". Independent of
# whether the word is predictable -- "plugins/fx/tests/t/*.t" and
# "$D/alpha.t" both qualify this way, without resolving $D at all.
sub _d38_raw_is_test_shaped {
    my ($raw, $is_winfam) = @_;
    return 0 unless defined $raw;
    (my $rf = $raw) =~ s/['"]//g;
    $rf =~ tr{\\}{/};
    return 1 if $is_winfam ? ($rf =~ /\.t$/i) : ($rf =~ /\.t$/);
    (my $base = $rf) =~ s{.*/}{};
    $base = lc($base) if $is_winfam;
    return 1 if $base eq 'run-tests.pl';
    return 0;
}

# never-halt 09-gb-h-residuals sec 3.14 (Decision 38) -- rule (b): NAME gets
# a test-run-shaped value in one of two ways within the SAME command text
# (every segment of BpHook::_segments($cmd)): a leading NAME=value word of
# any segment (including right after "export"), or a segment shaped
# "for NAME in W1 W2 ..." where any Wi is test-shaped by rule (a).
sub _d38_name_resolves_test_shaped {
    my ($cmd, $name, $is_winfam) = @_;
    return 0 unless defined $cmd && defined $name && length $name;
    my @segs = eval { BpHook::_segments($cmd) };
    return 0 unless @segs;
    for my $seg (@segs) {
        next unless defined $seg && length $seg;
        my $words = BpHook::_tokenize_words($seg);
        next unless ref $words eq 'ARRAY' && @$words;

        my $wi = 0;
        $wi++ if defined $words->[0]{literal} && $words->[0]{literal} eq 'export';
        # never-halt 09-gb-h-residuals SHOULD-FIX 6 (reviewer S2): walk
        # EVERY leading "NAME=value" word of the segment, not just the
        # first -- "X=1 S=plugins/fx/tests/t/a.t; perl "$S"" has two
        # leading assignments, and checking only the first (X) never
        # consults S's value, letting a real test run past the interlock.
        while ($wi < @$words) {
            my $raw = $words->[$wi]{raw};
            last unless defined $raw && $raw =~ /^[A-Za-z_][A-Za-z0-9_]*=/;
            if ($raw =~ /^\Q$name\E=(.*)$/s) {
                return 1 if _d38_raw_is_test_shaped($1, $is_winfam);
            }
            $wi++;
        }

        if (@$words >= 4
            && defined $words->[0]{literal} && $words->[0]{literal} eq 'for'
            && defined $words->[1]{literal} && $words->[1]{literal} eq $name
            && defined $words->[2]{literal} && $words->[2]{literal} eq 'in')
        {
            for my $j (3 .. $#$words) {
                my $raw = $words->[$j]{raw};
                next unless defined $raw;
                return 1 if _d38_raw_is_test_shaped($raw, $is_winfam);
            }
        }
    }
    return 0;
}

# _perl_test_run($cmd) -> 0|1. Never dies (wrapped in eval); a parse failure
# other than the shared deadline marker fails open (0), leaving the
# existing regex's verdict untouched. A deadline hit fails CLOSED (N5): the
# fast-path test already established this command plausibly runs a test, so
# treat it as validation-shaped rather than letting an oversize/adversarial
# command slip past the interlock unexamined. Never writes to
# $HYG_TARGETS_CACHE.
sub _perl_test_run {
    my ($cmd) = @_;
    my $r = eval {
        return 0 unless defined $cmd;
        # M1: "xargs ... perl" and "find ... perl" are test runs even with
        # no .t/run-tests.pl text at all on the line (e.g. a bare `ls | xargs
        # -n1 /usr/bin/perl`) -- widen the fast path for exactly that pair of
        # shapes, never generally. S4: an 8.3 alias basename (~N.pl/~N.t)
        # never contains a literal ".t" or "run-tests.pl" substring either.
        return 0
            unless $cmd =~ /\.t\b/i
                || $cmd =~ /run-tests\.pl/i
                || $cmd =~ /\bprove\b/i
                || $cmd =~ /~\d+\.(?:pl|t)\b/i
                || ($cmd =~ /\bw?perl/i && ($cmd =~ /\bxargs\b/i || $cmd =~ /\bfind\b/i));

        my $deadline = _hyg_deadline_at(2);
        my $is_winfam = _hyg_is_winfam();
        for my $e (_hyg_commands($cmd, 0, $deadline)) {
            next unless ref $e eq 'HASH';
            my $name = _hyg_command_name($e->{name});
            next unless defined $name;

            # S4: the command itself, already unwrapped, is the runner or a
            # .t file (direct exec/shebang, or a thin wrapper _hyg_reduce
            # already stripped).
            return 1 if _runner_or_dot_t_name($name, $is_winfam);

            # S3: `prove`, bare or perl-launched, is a test run outright --
            # it has no ".t operand" of its own to walk for.
            if ($name eq 'prove' || $name eq 'prove.bat') { return 1 }

            # M1: xargs/find hand a filename to perl on a LATER word, never
            # as perl's own script operand -- a perl-variant word anywhere
            # in THIS command's own argv is enough.
            if ($name eq 'xargs' || $name eq 'find') {
                for my $aw (@{ $e->{argv} || [] }) {
                    my $an = _hyg_command_name($aw);
                    return 1 if defined $an && _perl_binary_name($an);
                }
                next;
            }

            # S1: a wrapper _hyg_reduce/_hyg_commands doesn't unwrap
            # (setsid, ionice, chrt, taskset, flock, watch, strace, ltrace,
            # unbuffer, parallel, script, su) leaves ITS OWN name here --
            # scan (bounded) its own argv for the first perl-variant or
            # runner/.t-shaped word and evaluate from there.
            if (_hyg_wrapper_name($name)) {
                my @aw = @{ $e->{argv} || [] };
                my $bound = ($#aw > 7) ? 7 : $#aw;
                for my $ix (0 .. $bound) {
                    my $w = $aw[$ix];
                    my $an = _hyg_command_name($w);
                    next unless defined $an;
                    if (_runner_or_dot_t_name($an, $is_winfam)) { return 1 }
                    if (_perl_binary_name($an)) {
                        my @rest = @aw[$ix + 1 .. $#aw];
                        my ($ops2, undef) = _hyg_scan_redirects(\@rest);
                        my ($idx2, $is_c2, $code2) = _perl_opt_walk($ops2, 0);
                        next if $is_c2;
                        if (defined $code2) {
                            if ($code2 =~ /\b(?:do|require|runtests)\b/) {
                                return 1 if $cmd =~ /\.t\b/i || $cmd =~ /run-tests\.pl/i;
                            }
                            last;
                        }
                        if (!defined $idx2) { last }
                        my $s2 = _word_text($ops2->[$idx2]);
                        if (defined $s2 && $s2 ne '-') {
                            (my $f2 = $s2) =~ tr{\\}{/};
                            (my $b2 = $f2) =~ s{.*/}{};
                            $b2 = lc($b2) if $is_winfam;
                            return 1 if _runner_or_dot_t_name($b2, $is_winfam);
                        }
                        last;
                    }
                }
                next;
            }

            next unless _perl_binary_name($name);

            my ($ops, undef) = _hyg_scan_redirects($e->{argv} || []);
            # never-halt 09-gb-h-residuals sec 3.14 (Decision 38): opt in to
            # keeping an unpredictable, non-option-looking script word as
            # the index (instead of aborting the walk) -- D38's own rules
            # below decide whether it counts as a test run, rather than the
            # old blanket "whole command mentions .t" fallback.
            my ($idx, $is_c, $code) = _perl_opt_walk($ops, 0, { keep_unpredictable => 1 });
            next if $is_c;

            if (defined $code) {
                # S2(b): code-mode is a test run only when the code itself
                # opens/requires a test file -- plain code-on-the-command-
                # line (S6) is not, even if a .t happens to be named
                # elsewhere on the line (as a data argument, e.g. -pi).
                if ($code =~ /\b(?:do|require|runtests)\b/) {
                    return 1 if $cmd =~ /\.t\b/i || $cmd =~ /run-tests\.pl/i;
                }
                next;
            }

            if (!defined $idx) {
                # S2(a)/M1: no predictable script word -- stdin/pipe/
                # redirect-only argv, or an argv that ends after the
                # options. Fall back to whether the WHOLE command mentions a
                # .t file, the runner, or a tests/t/ directory.
                return 1 if $cmd =~ /\.t\b/i || $cmd =~ /run-tests\.pl/i || $cmd =~ m{tests/t/}i;
                next;
            }

            my $s = _word_text($ops->[$idx]);

            if (!defined $s && !(defined $ops->[$idx]{literal})
                && defined $ops->[$idx]{raw})
            {
                # D38: the script word's own text is unpredictable (a
                # variable, command substitution or glob) -- it counts as a
                # test run ONLY via rule (a) (its own raw text is .t-/
                # runner-shaped) or rule (b) (it is exactly $NAME/${NAME},
                # and NAME resolves to a .t-/runner-shaped value elsewhere
                # in the same command). Mere MENTION of ".t" anywhere else
                # on the line (e.g. inside a --text value) is not enough.
                my $raw_idx = $ops->[$idx]{raw};
                if (_d38_raw_is_test_shaped($raw_idx, $is_winfam)) { return 1 }
                my $name_var;
                if ($raw_idx =~ /^"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"$/
                    || $raw_idx =~ /^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$/)
                { $name_var = $1 }
                elsif ($raw_idx =~ /^"\$([A-Za-z_][A-Za-z0-9_]*)"$/
                    || $raw_idx =~ /^\$([A-Za-z_][A-Za-z0-9_]*)$/)
                { $name_var = $1 }
                if (defined $name_var
                    && _d38_name_resolves_test_shaped($cmd, $name_var, $is_winfam))
                {
                    return 1;
                }
                next;
            }
            # S2(a): _hyg_scan_redirects only drops OUTPUT-shaped redirects
            # (it exists to find write TARGETS) -- an input redirect ("<",
            # possibly fd-prefixed) is left in $ops untouched, so it can
            # surface here as the "script word" for "perl < x.t"/"perl -
            # < x.t". Treat it exactly like the "-" (stdin) case.
            if (!defined $s || $s eq '-' || $s =~ $REDIR_OP) {
                return 1 if $cmd =~ /\.t\b/i || $cmd =~ /run-tests\.pl/i || $cmd =~ m{tests/t/}i;
                next;
            }

            # M2: the tokenizer's own literal for an UNQUOTED backslash
            # (e.g. "scripts\run-tests.pl") consumes the backslash as a
            # real shell escape of the next character, losing the
            # Windows-style separator meaning this predicate is meant to
            # recognise -- fold from the word's RAW text (quote-stripped,
            # backslash-to-forward-slash) the same way
            # _runner_basename_matches does, so the two readers agree.
            my $raw_s = $ops->[$idx]{raw};
            my $base;
            if (defined $raw_s) {
                (my $rf = $raw_s) =~ s/['"]//g;
                $rf =~ tr{\\}{/};
                ($base = $rf) =~ s{.*/}{};
            }
            else {
                (my $folded = $s) =~ tr{\\}{/};
                ($base = $folded) =~ s{.*/}{};
            }
            $base = lc($base) if $is_winfam;
            return 1 if _runner_or_dot_t_name($base, $is_winfam);
            # S3: `perl /path/to/prove x.t` launches prove as perl's own
            # script -- the same as a bare/absolute `prove` invocation.
            return 1 if $base eq 'prove' || $base eq 'prove.bat';
        }
        return 0;
    };
    if ($@) {
        my $err = $@;
        return 1 if ref $err eq 'HASH' && $err == $HYG_DEADLINE_MARKER;
        return 0;
    }
    return $r ? 1 : 0;
}

# _hyg_wrapper_name($name) -> 0|1. never-halt 03 S1: process wrappers
# _hyg_reduce doesn't know how to unwrap (it stops at env/timeout/nice/
# sudo/stdbuf/command/time/builtin/exec/nohup and the shell keywords), so
# they surface here as the command's own name.
sub _hyg_wrapper_name {
    my ($name) = @_;
    return 0 unless defined $name;
    return $name =~ /^(?:setsid|ionice|chrt|taskset|flock|watch|strace|ltrace|unbuffer|parallel|script|su)$/
        ? 1 : 0;
}

# 24-interlock-scope B-7: a perl invocation carrying a syntax-check flag
# (an option token, between "perl" and its script operand, matching
# ^-[wWXtT]*c[wWXtT]*$) is never validation-shaped. Judged per invocation --
# "perl -c a.t && perl b.t" is still validation-shaped through its second
# invocation, because the neutralisation only blanks the ONE matched perl
# invocation that carries the flag.
my $PERL_INVOCATION_RE = qr/(^|[;&|])([\x20\t]*)perl\b((?:[\x20\t]+[^\s;&|]+)*)/m;

sub _neutralize_perl_syntax_checks {
    my ($text) = @_;
    return $text unless defined $text && length $text;
    my $out = $text;
    $out =~ s{$PERL_INVOCATION_RE}{
        my ($sep, $ws, $rest) = ($1, $2, $3);
        my $has_c = 0;
        # never-halt 03 S6 + review SHOULD-FIX 1: mirror _perl_opt_walk's own
        # "no script operand" rule here, so a bare "perl" invocation carrying
        # e/E (code on the command line) or -MO=/-MO:: (compile-only) is
        # blanked the same way "-c" already is -- there is no ".t operand"
        # for $VALIDATION_RE's own perl alternatives to find.
        my $no_script = 0;
        for my $tok (split /[\x20\t]+/, $rest) {
            next unless length $tok;
            last unless $tok =~ /^-/;
            if ($tok =~ /^-[wWXtT]*c[wWXtT]*$/) { $has_c = 1; last }
            if ($tok =~ /^-MO[=:]/)             { $no_script = 1; last }
            if (defined _perl_cluster_code_text($tok)) { $no_script = 1; last }
        }
        # 24-interlock-scope-review M-1: a command substitution, backtick or
        # process substitution among $rest's operands still runs a real
        # command at shell level even though the outer "perl -c ..." itself
        # never executes its script -- never blank those operands away.
        $has_c = 0 if $rest =~ /\x60|\$\(|[<>]\(/;
        $no_script = 0 if $rest =~ /\x60|\$\(|[<>]\(/;
        # never-halt 03 S6 vs interlock-write-set-scope.t AC-18: a second
        # "perl" word inside the code (system("perl t/x.t"), a nested
        # eval, ...) is a genuinely different invocation actually being
        # run, not a mere data argument -- never blank it away just
        # because the OUTER perl's own e/E cluster carries no script of
        # its own.
        $no_script = 0 if $rest =~ /\bperl\b/i;
        ($has_c || $no_script)
            ? ($sep . (' ' x (length($ws) + length('perl') + length($rest))))
            : ($sep . $ws . 'perl' . $rest);
    }ge;
    return $out;
}

# tree-wide scan (b), shared by the coordinator and driver branches.
sub _tree_check {
    my ($p, $cmd, $data, $root, $self, $stale_min) = @_;
    return undef unless defined $data && length $data && -d $data;
    return undef unless defined $root && length $root && -d $root;

    if (defined $ENV{CCPRAXIS_TREE_INTERLOCK_OFF} && $ENV{CCPRAXIS_TREE_INTERLOCK_OFF} eq '1') {
        return undef;
    }
    my $hatch = "$data/.tree-interlock-off";
    if (-e $hatch) {
        my $ttl = _digits_or_default($ENV{CCPRAXIS_TREE_INTERLOCK_OFF_TTL_MIN}, 60);
        $ttl = 60 unless $ttl > 0;
        $ttl = 1440 if $ttl > 1440;
        my @st = stat($hatch);
        my $honoured = 1;
        if (@st && defined $st[9]) {
            my $mtime = $st[9];
            my $now = time();
            if ($mtime <= $now) {
                my $age_min = ($now - $mtime) / 60;
                $honoured = ($age_min < $ttl) ? 1 : 0;
            }
            else {
                $honoured = 0; # future-dated hatch: not honoured
            }
        }
        if ($honoured) {
            return undef;
        }
        unlink($hatch);
    }

    opendir(my $dh, $root) or return undef;
    my @subdirs = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir $dh;

    my @candidates;
    for my $sub (@subdirs) {
        my $rundir = "$root/$sub/runs";
        next unless -d $rundir;
        opendir(my $rdh, $rundir) or next;
        my @files = sort grep { /\.active-worker$/ } readdir($rdh);
        closedir $rdh;
        for my $f (@files) {
            push @candidates, "$rundir/$f";
        }
    }
    @candidates = sort @candidates;

    my $n = 0;
    for my $c (@candidates) {
        next if defined $self && $c eq $self;
        next unless -f $c;
        $n++;
        return undef if $n > 32;
        next unless _fresh_mtime($c, $stale_min, 'stale');
        my $content = _read_bytes($c);
        next unless defined $content && length $content;
        my $role = BpHook::Guards::Common::is_writer($content);
        next unless defined $role;
        my $pkg = basename($c);
        $pkg =~ s/\.active-worker$//;
        my $bpname = basename(dirname(dirname($c)));
        return [
            $role,
            _sanitize($bpname, 64),
            _sanitize($pkg, 64),
        ];
    }
    return undef;
}

# ---------------------------------------------------------------------------
# 24-interlock-scope Decision 85/92 -- write-set overlap (mirrors
# bp-ledger.pl's _widen_ws_prefixes/_widen_prefix_related exactly, AC-15) and
# binding resolution (spec sec 2.2). Pure/private helpers plus the one
# public entry point.
# ---------------------------------------------------------------------------
sub _widen_ws_prefixes {
    my ($paths) = @_;
    my @out;
    return @out unless ref $paths eq 'ARRAY';
    for my $p (@$paths) {
        next unless defined $p && !ref($p) && length $p;
        (my $q = $p) =~ s/\*.*$//;
        $q =~ s{/+$}{};
        push @out, $q;
    }
    return @out;
}

sub _widen_ws_is_ci {
    return ($^O =~ /^(?:msys|MSWin32|cygwin|darwin)$/) ? 1 : 0;
}

sub _widen_ws_fold {
    my ($s) = @_;
    return $s unless _widen_ws_is_ci();
    (my $v = $s) =~ tr/A-Z/a-z/;
    return $v;
}

sub _widen_prefix_related {
    my ($a, $b) = @_;
    $a = _widen_ws_fold($a);
    $b = _widen_ws_fold($b);
    return 1 if $a eq $b;
    return 1 if $a eq '' || $b eq '';
    return 1 if index("$b/", "$a/") == 0;
    return 1 if index("$a/", "$b/") == 0;
    return 0;
}

# write_sets_overlap(\@ws_a, \@ws_b) -> 1 | 0. Pure: never touches the
# filesystem, never dies. A non-arrayref argument counts as an empty list.
sub write_sets_overlap {
    my ($ws_a, $ws_b) = @_;
    my @pa = _widen_ws_prefixes($ws_a);
    my @pb = _widen_ws_prefixes($ws_b);
    for my $x (@pa) {
        for my $y (@pb) {
            return 1 if _widen_prefix_related($x, $y);
        }
    }
    return 0;
}

sub _valid_member_name {
    my ($v) = @_;
    return 0 unless defined $v && !ref($v) && length $v;
    return 0 unless $v =~ /^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/;
    return 0 if index($v, '..') >= 0;
    return 1;
}

# _read_ledger_write_set($data_n, $bp, $pkg) -> \@entries | undef. The
# ledger-read half of _resolve_binding, split out so the caller can memoise
# it by "$bp/$pkg" (24-interlock-scope-review S-2) -- two workers bound to
# the same package must not read the same ledger file twice in one run.
sub _read_ledger_write_set {
    my ($data_n, $bp, $pkg) = @_;
    my $lraw = _read_bytes("$data_n/blueprints/$bp/packages/$pkg.md");
    return undef unless defined $lraw && length $lraw;
    my @lines = split /\n/, $lraw;
    return undef unless @lines;
    (my $first = $lines[0]) =~ s/[ \t\r]+$//;
    return undef unless $first eq '---';

    my $ws_val;
    for my $i (1 .. $#lines) {
        (my $l = $lines[$i]) =~ s/\r$//;
        last if $l eq '---';
        if (!defined $ws_val && $l =~ /^write_set:[\x20\t]*(.*?)[\x20\t]*$/) {
            $ws_val = $1;
        }
    }
    return undef unless defined $ws_val;
    my @ws = grep { length } split /:/, $ws_val;
    return undef unless @ws;
    return \@ws;
}

# _ledger_scope_paths($data_n, $bp, $pkg) -> \@entries | undef.
# never-halt 09-gb-h-residuals sec 2.2/3.13 (Decision 36 N6): the named
# ledger's write_set entries PLUS its test_paths entries -- reads the
# frontmatter exactly as _read_ledger_write_set does. A missing
# "test_paths:" key contributes nothing (not an error).
sub _ledger_scope_paths {
    my ($data_n, $bp, $pkg) = @_;
    return undef unless defined $data_n && length $data_n;
    return undef unless _valid_member_name($bp) && _valid_member_name($pkg);
    my $lraw = _read_bytes("$data_n/blueprints/$bp/packages/$pkg.md");
    return undef unless defined $lraw && length $lraw;
    my @lines = split /\n/, $lraw;
    return undef unless @lines;
    (my $first = $lines[0]) =~ s/[ \t\r]+$//;
    return undef unless $first eq '---';

    my ($ws_val, $tp_val);
    for my $i (1 .. $#lines) {
        (my $l = $lines[$i]) =~ s/\r$//;
        last if $l eq '---';
        if (!defined $ws_val && $l =~ /^write_set:[\x20\t]*(.*?)[\x20\t]*$/) { $ws_val = $1 }
        if (!defined $tp_val && $l =~ /^test_paths:[\x20\t]*(.*?)[\x20\t]*$/) { $tp_val = $1 }
    }
    return undef unless defined $ws_val;
    my @out = grep { length } split /:/, $ws_val;
    return undef unless @out;
    if (defined $tp_val && length $tp_val) {
        push @out, grep { length } split /:/, $tp_val;
    }
    return \@out;
}

# _resolve_binding($data_n, $tuid) -> { blueprint, package, write_set =>
# [entries] } | undef. Spec sec 2.2. Never dies; any parse/read failure is
# an undef (conservative fallback upstream).
sub _resolve_binding {
    my ($data_n, $tuid) = @_;
    return undef unless defined $tuid && $tuid =~ $TUID_NAME_RE;
    my $braw = _read_bytes("$data_n/.drive-solo/bindings/$tuid.json");
    return undef unless defined $braw && length $braw;
    my $rec = eval { JSON::PP->new->utf8->decode($braw) };
    return undef unless ref $rec eq 'HASH';
    my ($bp, $pkg) = ($rec->{blueprint}, $rec->{package});
    return undef unless _valid_member_name($bp) && _valid_member_name($pkg);

    my $ws = _read_ledger_write_set($data_n, $bp, $pkg);
    return undef unless defined $ws;
    return { blueprint => $bp, package => $pkg, write_set => $ws };
}

# _resolve_binding_cached($data_n, $tuid, \%ledger_cache) -> same shape as
# _resolve_binding(), but the ledger half is memoised in %ledger_cache
# (keyed "$bp/$pkg") across the calls made within one _gb_d invocation
# (24-interlock-scope-review S-2 -- "cached per run call ... by ledger
# path").
sub _resolve_binding_cached {
    my ($data_n, $tuid, $ledger_cache) = @_;
    return undef unless defined $tuid && $tuid =~ $TUID_NAME_RE;
    my $braw = _read_bytes("$data_n/.drive-solo/bindings/$tuid.json");
    return undef unless defined $braw && length $braw;
    my $rec = eval { JSON::PP->new->utf8->decode($braw) };
    return undef unless ref $rec eq 'HASH';
    my ($bp, $pkg) = ($rec->{blueprint}, $rec->{package});
    return undef unless _valid_member_name($bp) && _valid_member_name($pkg);

    my $key = "$bp/$pkg";
    my $ws;
    if (exists $ledger_cache->{$key}) {
        $ws = $ledger_cache->{$key};
    }
    else {
        $ws = _read_ledger_write_set($data_n, $bp, $pkg);
        $ledger_cache->{$key} = $ws;
    }
    return undef unless defined $ws;
    return { blueprint => $bp, package => $pkg, write_set => $ws };
}

# ---------------------------------------------------------------------------
# 29-driver-validation-scope -- the driver's opt-in BP_VALIDATE_LEDGER=<path>
# scoping (spec sec 2.1/2.2), and (never-halt 03) the equivalent --ledger/
# --ledger=<path> flag on the leading run-tests.pl invocation. The name is
# read only from the command text (BpHook::_tokenize_words), never from the
# hook process's own %ENV.
# ---------------------------------------------------------------------------
sub _fold_path {
    my ($s) = @_;
    return '' unless defined $s;
    (my $v = $s) =~ tr{\\}{/};
    $v =~ s{/+$}{};
    if ($v =~ m{^/([A-Za-z])/(.*)$}) {
        $v = "$1:/$2";
    }
    $v = lc($v) if _widen_ws_is_ci();
    return $v;
}

# _validate_ledger_value($v) -> 0|1. Spec sec 2.2's shared "validate(v)":
# defined, non-empty, and free of shell-meaningful characters.
sub _validate_ledger_value {
    my ($v) = @_;
    return 0 unless defined $v && length $v;
    return 0 if $v =~ /[\s;&|<>()]/;
    return 1;
}

# _runner_basename_matches($raw_text) -> 0|1. never-halt 03 Decision 36 M2/
# N2: the ONE shared runner-recognition reader for a word's RAW text (quotes
# and backslash intact) -- strips ' and " characters (a quoted runner word,
# "scripts/run-tests.pl" or 'scripts/run-tests.pl', dequotes to plain text
# this way since the tokenizer's own literal already stripped matched-pair
# quotes with no escapes), folds backslash to forward slash (an unquoted
# Windows-style "scripts\run-tests.pl"), then compares the basename to
# "run-tests.pl" case-insensitively on Windows-family perls -- the SAME case
# rule _perl_test_run's own script-basename check uses, so the two readers
# can never disagree about which basename ends a scoped run (N2).
sub _runner_basename_matches {
    my ($raw) = @_;
    return 0 unless defined $raw;
    (my $t = $raw) =~ s/['"]//g;
    $t =~ tr{\\}{/};
    (my $base = $t) =~ s{.*/}{};
    $base = lc($base) if _hyg_is_winfam();
    return $base eq 'run-tests.pl' ? 1 : 0;
}

# _scoped_test_operand($cmd) -> $text | undef. never-halt 09-gb-h-residuals
# sec 3.13 (Decision 36 N6): reads segment 0 of BpHook::_segments($cmd),
# tokenised and reduced (drops leading NAME= assignments and wrappers), and
# returns the single scoped test-file/runner-flag text this run names, or
# undef when there isn't exactly one.
sub _scoped_test_operand {
    my ($cmd) = @_;
    my $r = eval {
        return undef unless defined $cmd && length $cmd;
        my @segs = BpHook::_segments($cmd);
        my $seg0 = $segs[0];
        return undef unless defined $seg0 && length $seg0;
        my $words = BpHook::_tokenize_words($seg0);
        return undef unless ref $words eq 'ARRAY' && @$words;
        my ($name_word, $argv, undef) = _hyg_reduce($words);
        return undef unless defined $name_word;
        $argv ||= [];
        my $name = _hyg_command_name($name_word);
        my $is_winfam = _hyg_is_winfam();

        my $S;
        my @after_pool;
        if (defined $name && _perl_binary_name($name)) {
            my ($idx, $is_c, $code) = _perl_opt_walk($argv, 0);
            return undef if $is_c || defined $code || !defined $idx;
            $S = $argv->[$idx];
            @after_pool = @$argv[$idx + 1 .. $#$argv];
        }
        else {
            $S = $name_word;
            @after_pool = @$argv;
        }
        return undef unless defined $S;

        my $test_shaped = sub {
            my ($text) = @_;
            return 0 unless defined $text;
            (my $tt = $text) =~ tr{\\}{/};
            return $is_winfam ? ($tt =~ /\.t$/i ? 1 : 0) : ($tt =~ /\.t$/ ? 1 : 0);
        };

        if (_runner_basename_matches($S->{raw})) {
            my @positionals;
            my $j = 0;
            my $m = scalar @after_pool;
            while ($j < $m) {
                my $w = $after_pool[$j];
                # Redirects are not operands: the same REDIRECT DROP rule as
                # _drop_redirects (an operator that is the whole token also
                # takes its target token). Without it, "x.t > out.txt 2>&1"
                # counted three positionals, the operand came back undef, and
                # the driver's BP_VALIDATE_LEDGER scoping refused an in-scope
                # file (bug 20261012-033433-4cba).
                my $wraw = $w->{raw};
                if (defined $wraw && $wraw =~ $REDIR_OP) {
                    my $rest = substr($wraw, length($&));
                    $j += ($rest eq '') ? 2 : 1;
                    next;
                }
                my $lit = $w->{literal};
                if (defined $lit && ($lit eq '--ledger' || $lit eq '--jobs')) { $j += 2; next }
                my $probe = defined $lit ? $lit : $w->{raw};
                if (defined $probe && $probe =~ /^-/) { $j++; next }
                push @positionals, $w;
                $j++;
            }
            return undef unless @positionals == 1;
            my $text = _word_text($positionals[0]);
            return undef unless defined $text;
            (my $tt = $text) =~ tr{\\}{/};
            return $tt if $test_shaped->($tt);
            return undef;
        }

        my $text = _word_text($S);
        return undef unless defined $text;
        (my $tt = $text) =~ tr{\\}{/};
        return $tt if $test_shaped->($tt);
        return undef;
    };
    return undef if $@;
    return $r;
}

# _operand_in_scope($operand, $data_n, \@scope_paths) -> 0|1.
# never-halt 09-gb-h-residuals sec 3.13: normalises the operand to
# repo-relative (an absolute path must fold under dirname($data_n)), then
# checks it against every scope-path entry (normalised the same way
# write_sets_overlap's own callers do, via _widen_ws_prefixes).
sub _operand_in_scope {
    my ($operand, $data_n, $scope_paths) = @_;
    return 0 unless defined $operand && length $operand;
    return 0 unless ref $scope_paths eq 'ARRAY' && @$scope_paths;
    my $op = $operand;
    $op =~ s{^\./}{};
    my $rel;
    if (_hyg_is_abs($op)) {
        my $folded = _fold_path($op);
        my $root = dirname($data_n);
        $root =~ tr{\\}{/};
        my $froot = _fold_path($root) . '/';
        return 0 unless index($folded, $froot) == 0;
        $rel = substr($folded, length($froot));
    }
    else {
        $rel = $op;
    }
    # never-halt 09-gb-h-residuals MUST-FIX 4 (red-team M1): a ".." segment
    # anywhere in the (already root-relativised) operand means the true,
    # collapsed target is NOT what a bare prefix comparison would see --
    # "plugins/fx/alpha/../tests/t/beta.t" prefix-matches scope
    # "plugins/fx/alpha/" even though it really resolves to
    # "plugins/fx/tests/t/beta.t", outside that scope. Rather than teach
    # _fold_path to collapse "." / ".." (which would also have to reject
    # a ".." that walks above the root), treat ANY operand containing a
    # ".." segment as definitionally out of scope -- the smaller, more
    # targeted fix: a real in-scope operand never needs one.
    (my $norm_rel = $rel) =~ tr{\\}{/};
    return 0 if $norm_rel =~ m{(^|/)\.\.(/|$)};
    my $frel = _fold_path($rel);
    for my $e (_widen_ws_prefixes($scope_paths)) {
        next unless length $e;
        my $fe = _fold_path($e);
        next unless length $fe;
        return 1 if $frel eq $fe;
        return 1 if index($frel, "$fe/") == 0;
    }
    return 0;
}

# _flag_ledger_values($trimmed) -> list of contributed --ledger/--ledger=
# values (undef included, spec sec 2.2 "FLG"), read ONLY from the leading
# runner invocation of the command's FIRST segment (BpHook::_segments), so a
# --ledger after "&&"/";"/a pipe, or on a bare .t rather than on run-tests.pl
# itself, is never read (AC-12). Runs the segment through _hyg_reduce first
# (never-halt 03 N1) so a wrapper (timeout 600, env, nice, sudo, ...) ahead
# of the runner invocation does not hide it.
sub _flag_ledger_values {
    my ($trimmed) = @_;
    my @out = eval {
        return () unless defined $trimmed && length $trimmed;
        my @segs = BpHook::_segments($trimmed);
        my $seg0 = $segs[0];
        return () unless defined $seg0 && length $seg0;
        my $words = BpHook::_tokenize_words($seg0);
        return () unless ref $words eq 'ARRAY' && @$words;

        my ($name_word, $argv, undef) = _hyg_reduce($words);
        return () unless defined $name_word;
        my @w = ($name_word, @$argv);
        my $n = scalar @w;

        my $name = _hyg_command_name($name_word);
        my $s_idx;
        if (defined $name && $name eq 'perl') {
            my ($idx, $is_c, $code) = _perl_opt_walk(\@w, 1);
            return () if $is_c || defined $code || !defined $idx;
            $s_idx = $idx;
        }
        else {
            return () unless _runner_basename_matches($name_word->{raw});
            $s_idx = 0;
        }
        return () unless _runner_basename_matches($w[$s_idx]->{raw});

        my @vals;
        my $j = $s_idx + 1;
        while ($j < $n) {
            my $lit = $w[$j]{literal};
            if (defined $lit && $lit eq '--ledger') {
                push @vals, ($j + 1 < $n) ? $w[$j + 1]{literal} : undef;
                $j += 2;
                next;
            }
            if (defined $lit && $lit =~ /^--ledger=(.*)$/s) {
                push @vals, $1;
                $j++;
                next;
            }
            $j++;
        }
        return @vals;
    };
    return () if $@;
    return @out;
}

# _named_validation_ledger($cmd) -> ($state, $value). $state is one of
# 'absent', 'value', 'bad'. Never dies (spec 2.1: "on any internal failure
# it returns ('bad', undef)"). Draws from two sources (spec sec 2.2): the
# leading BP_VALIDATE_LEDGER= prefix assignment (PFX, unchanged), and a
# --ledger/--ledger= flag on the leading runner invocation (FLG, new).
sub _named_validation_ledger {
    my ($cmd) = @_;
    my @r = eval {
        return ('bad', undef) unless defined $cmd && length $cmd;
        (my $trimmed = $cmd) =~ s/^[\x20\t]+//;
        my $words = BpHook::_tokenize_words($trimmed);
        return ('bad', undef) unless ref $words eq 'ARRAY';
        my @prefix;
        for my $w (@$words) {
            last unless ref $w eq 'HASH' && defined $w->{raw}
                && $w->{raw} =~ /^[A-Za-z_][A-Za-z0-9_]*=/;
            push @prefix, $w;
        }
        my @pfx_matches = grep { index($_->{raw}, 'BP_VALIDATE_LEDGER=') == 0 } @prefix;
        my @flg = _flag_ledger_values($trimmed);

        return ('bad', undef) if @pfx_matches > 1;
        return ('bad', undef) if @flg > 1;
        return ('absent', undef) if @pfx_matches == 0 && @flg == 0;

        my $pval;
        if (@pfx_matches == 1) {
            my $mw = $pfx_matches[0];
            return ('bad', undef) unless defined $mw->{literal};
            $pval = substr($mw->{literal}, length('BP_VALIDATE_LEDGER='));
        }
        my $fval = (@flg == 1) ? $flg[0] : undef;

        my $final_val;
        if (@pfx_matches == 1 && @flg == 0) {
            return ('bad', undef) unless _validate_ledger_value($pval);
            $final_val = $pval;
        }
        elsif (@pfx_matches == 0 && @flg == 1) {
            return ('bad', undef) unless _validate_ledger_value($fval);
            $final_val = $fval;
        }
        else {
            # both present: both must validate AND resolve to the same path.
            return ('bad', undef)
                unless _validate_ledger_value($pval) && _validate_ledger_value($fval);
            return ('bad', undef) unless _fold_path($pval) eq _fold_path($fval);
            $final_val = $pval;
        }

        # never-halt 03 S5: the scope named on segment 0 must not cover a
        # later &&/;/|-joined segment that is ITSELF validation-shaped --
        # otherwise one scoped invocation could smuggle in a specific,
        # differently-targeted invocation under the same allow (a single
        # OTHER .t file, or a non-run-tests.pl test runner like `prove`,
        # neither of which _is_full_sweep_runner's own whole-command scan
        # would ever catch on its own). When that scan ALREADY flags the
        # whole command as a full sweep (e.g. a later bare/--fast/
        # multi-operand run-tests.pl segment), the smuggled invocation is
        # caught there instead, with the more specific full-sweep message --
        # interlock-runner-redirects.t AC-23 pins that message for exactly
        # this shape, so S5 must not pre-empt it with a bare 'bad'.
        unless (_is_full_sweep_runner($cmd)) {
            my @segs = BpHook::_segments($trimmed);
            for my $si (1 .. $#segs) {
                next unless defined $segs[$si] && length $segs[$si];
                return ('bad', undef) if _validation_shaped($segs[$si]);
            }
        }
        return ('value', $final_val);
    };
    return ('bad', undef) if $@;
    return @r;
}

# _resolve_named_ledger($data_n, $value, \%ledger_cache) -> { blueprint,
# package, write_set } | undef. Spec sec 2.2. Never dies.
sub _resolve_named_ledger {
    my ($data_n, $value, $ledger_cache) = @_;
    my $r = eval {
        return undef unless defined $data_n && length $data_n;
        return undef unless defined $value && length $value;
        (my $v = $value) =~ tr{\\}{/};
        $v =~ s{^\./}{};
        return undef unless $v =~ m{^(.+)/blueprints/([^/]+)/packages/([^/]+)\.md$};
        my ($prefix, $bp, $pkg) = ($1, $2, $3);
        return undef unless _valid_member_name($bp) && _valid_member_name($pkg);

        my $fp = _fold_path($prefix);
        return undef
            unless $fp eq _fold_path(basename($data_n)) || $fp eq _fold_path($data_n);

        my $iraw = _read_bytes("$data_n/.drive-solo/inflight.json");
        return undef unless defined $iraw && length $iraw;
        my $idata = eval { JSON::PP->new->utf8->decode($iraw) };
        return undef unless ref $idata eq 'HASH' && ref $idata->{packages} eq 'ARRAY';
        my $found = 0;
        for my $e (@{ $idata->{packages} }) {
            next unless ref $e eq 'HASH';
            if (defined $e->{blueprint} && defined $e->{package}
                && $e->{blueprint} eq $bp && $e->{package} eq $pkg)
            {
                $found = 1;
                last;
            }
        }
        return undef unless $found;

        my $key = "$bp/$pkg";
        my $ws;
        if (exists $ledger_cache->{$key}) {
            $ws = $ledger_cache->{$key};
        }
        else {
            $ws = _read_ledger_write_set($data_n, $bp, $pkg);
            $ledger_cache->{$key} = $ws;
        }
        return undef unless defined $ws;
        return { blueprint => $bp, package => $pkg, write_set => $ws };
    };
    return undef if $@;
    return $r;
}

# _is_full_sweep_runner($cmd) -> true iff ANY run-tests.pl invocation, in
# any separator-delimited segment on any line, invokes it with no path
# operand, with --fast, or with two-or-more path operands
# (24-interlock-scope-review S-1; 34-runner-redirect-operands DC6/spec
# sec 2.1 -- every invocation is classified, on the heredoc-blanked text,
# with redirects already dropped). Write-set scoping approximates what a
# run WRITES; a full or multi-plugin sweep also READS every other
# in-flight worker's half-written files, so it is denied by presence of
# any live writer alone, regardless of write-set overlap.
my $RUNNER_SEPARATOR_RE = qr/(?:;|(?<![<>])&(?!>)|(?<!>)\|)/;


# 34-runner-redirect-operands review M-3 -- a redirect glued directly onto
# the runner token (no space: "run-tests.pl&>log", "run-tests.pl>log",
# "run-tests.pl>|log") must be split off BEFORE _drop_redirects runs, or it
# survives as the runner token's own trailing text and is unshifted back
# into @tail afterwards, uncoupled from the drop -- which then always
# fail-opens it into a single-operand (never full-sweep) reading no matter
# what the operator is.
sub _split_glued_redirect {
    my (@tok) = @_;
    my @out;
    for my $t (@tok) {
        if ($t =~ m{^(.*(?:^|/)run-tests\.pl)([<>&|].*)$}) {
            my ($head, $tail) = ($1, $2);
            if ($tail =~ $REDIR_OP) {
                push @out, $head, $tail;
                next;
            }
        }
        push @out, $t;
    }
    return @out;
}

sub _is_full_sweep_runner {
    my ($cmd) = @_;
    return 0 unless defined $cmd;
    return 0 if index($cmd, 'run-tests.pl') < 0; # fast path: one index call
    my $text = _blank_data_heredocs($cmd);
    $text =~ s/\\\n/ /g;
    for my $line (split /\n/, $text) {
        for my $seg (split $RUNNER_SEPARATOR_RE, $line) {
            next unless defined $seg;
            my @tok = grep { length } split /\s+/, $seg;
            @tok = _split_glued_redirect(@tok);
            my @kept = _drop_redirects(@tok);
            my $k;
            for my $idx (0 .. $#kept) {
                if (_runner_basename_matches($kept[$idx])) { $k = $idx; last; }
            }
            next unless defined $k;
            my @tail = @kept[$k + 1 .. $#kept];
            # never-halt 03 Decision 36 M2: a matched-pair-quoted (or
            # unquoted, possibly backslash-separated) runner token is
            # self-contained -- compute its glued suffix from the
            # NORMALISED text, so a trailing quote CHARACTER never survives
            # as a phantom operand. An ODD quote count means this token is
            # a FRAGMENT of a larger quoted argument the naive whitespace
            # split tore in two (e.g. --note "see scripts/run-tests.pl") --
            # keep computing $rem from the raw text there, preserving
            # today's tail semantics exactly (interlock-runner-redirects.t
            # AC-22).
            my $quotes_in_k = () = $kept[$k] =~ /['"]/g;
            my $rem;
            if ($quotes_in_k % 2 == 0) {
                (my $kn = $kept[$k]) =~ s/['"]//g;
                $kn =~ tr{\\}{/};
                if ($kn =~ m{(?:^|/)run-tests\.pl(.*)$}) { $rem = $1; }
            }
            elsif ($kept[$k] =~ m{(?:^|/)run-tests\.pl(.*)$}) { $rem = $1; }
            unshift @tail, $rem if defined $rem && length $rem;
            # never-halt 03 Decision 36 M2: a quoted runner word/flag value
            # ("scripts/run-tests.pl", '--fast') and a backslash-separated
            # runner word (scripts\run-tests.pl) must read the same as their
            # unquoted/forward-slash forms -- strip quote characters from
            # every tail token once, up front (the runner word itself was
            # already matched, quote-aware, above).
            @tail = map { (my $x = $_) =~ s/['"]//g; $x } @tail;
            return 1 if grep { /^--fast\b/ } @tail;
            # never-halt 03 / Decision 35 Q2: the VALUE of a value-taking
            # runner flag (--ledger P, --jobs N) is not a path operand --
            # skip it together with its flag, so it is never miscounted as
            # a second (or the only) operand.
            my @args;
            my $skip_next = 0;
            for my $t (@tail) {
                if ($skip_next) { $skip_next = 0; next; }
                if ($t =~ /^--(?:ledger|jobs)$/) { $skip_next = 1; next; }
                next if $t =~ /^--?/;
                # never-halt 03 Decision 36 M3: any runner operand that
                # carries a glob metacharacter is many files, not one --
                # and one that LOOKS like a path (has a directory
                # component) but doesn't end in .t is a directory sweep.
                # A bare token with neither shape (e.g. a stray leftover
                # quote character from an already-consumed argument, AC-22's
                # "kept" tail semantics) is left alone.
                return 1 if $t =~ /[*?\[{]/;
                if ($t =~ m{/}) {
                    (my $tb = $t) =~ s{.*/}{};
                    $tb = lc($tb) if _hyg_is_winfam();
                    return 1 unless $tb =~ /\.t$/i;
                }
                push @args, $t;
            }
            return 1 if @args == 0 || @args >= 2;
        }
    }
    return 0;
}

sub _gb_d {
    my ($p, $cmd) = @_;
    return undef unless _validation_shaped($cmd);

    my $stale_min = _stale_min();
    my $cmd_line = 'Not run: ' . BpHook::Guards::Common::echo_cmd($cmd)
        . "; retry when the worker returns (marker ages out after $stale_min min).";
    my $tree_cmd_line = 'Not run: ' . BpHook::Guards::Common::echo_cmd($cmd)
        . "; retry when that worker returns (marker ages out after $stale_min min).";

    my $ledger = $ENV{BP_LEDGER};
    my $bp_dir = $ENV{BP_DIR};

    if (defined $ledger && length $ledger && defined $bp_dir && length $bp_dir) {
        # coordinator branch
        my $pkg = (defined $ENV{BP_PACKAGE} && length $ENV{BP_PACKAGE}) ? $ENV{BP_PACKAGE} : 'pkg';
        (my $bp_dir_n = $bp_dir) =~ tr{\\}{/};
        $bp_dir_n =~ s{/+$}{};
        my $marker = "$bp_dir_n/runs/$pkg.active-worker";
        if (-f $marker) {
            my $content = _read_bytes($marker);
            if (defined $content && length $content) {
                my $role = BpHook::Guards::Common::is_writer($content);
                if (defined $role && _fresh_mtime($marker, $stale_min)) {
                    return [
                        "BLOCKED (validation interlock): a write-capable worker ($role) is in flight; running this now can report a false red.",
                        $cmd_line,
                    ];
                }
            }
        }

        my $parent = dirname($bp_dir_n);
        if (basename($parent) eq 'blueprints') {
            my $root = $parent;
            my $self = "$root/" . basename($bp_dir_n) . "/runs/$pkg.active-worker";
            my $data = dirname($root);
            my $found = _tree_check($p, $cmd, $data, $root, $self, $stale_min);
            if (defined $found) {
                my ($role, $bpname, $pkgname) = @$found;
                return [
                    "BLOCKED (tree interlock): $role of blueprint $bpname package $pkgname is mid-edit in this working tree; this run could report a false red.",
                    $tree_cmd_line,
                ];
            }
        }
        return undef;
    }

    if (!defined $ledger || !length $ledger) {
        my $role = BpHook::role($p);
        if ($role eq 'driver') {
            my $data = BpHook::data_dir($p);
            return undef unless defined $data && length $data;
            (my $data_n = $data) =~ tr{\\}{/};
            $data_n =~ s{/+$}{};
            my $workers_dir = "$data_n/.drive-solo/workers";
            if (-d $workers_dir) {
                my $sid = BpHook::session_id($p);
                my $aid = BpHook::agent_id($p);
                my $own_binding;
                if (defined $aid) {
                    $own_binding = BpHook::Guards::Common::subagent_tool_use_id($p);
                    return undef unless defined $own_binding; # fail open: cannot tell subagent apart
                }
                opendir(my $wdh, $workers_dir);
                if ($wdh) {
                    my @names = sort grep { $_ =~ $TUID_NAME_RE } readdir($wdh);
                    closedir $wdh;
                    my $seen = 0;
                    my %ledger_ws_cache; # "$bp/$pkg" -> \@entries|undef, memoised for this call (S-2).
                    my $caller_ws;        # defined only when the caller's own
                                          # write set resolved -- write-set scoping
                                          # (Decision 85) applies only then.
                    my $caller_ws_tried = 0; # resolve the caller's own binding
                                              # lazily, only once a live writer
                                              # is actually found (S-2).
                    my $full_sweep;
                    for my $name (@names) {
                        my $full = "$workers_dir/$name";
                        next unless -f $full;
                        $seen++;
                        last if $seen > 32;
                        next if defined $own_binding && $name eq $own_binding;
                        my $content = _read_bytes($full);
                        next unless defined $content && length $content;
                        my $data_rec = eval { JSON::PP->new->utf8->decode($content) };
                        next unless ref $data_rec eq 'HASH';
                        next unless defined $data_rec->{session_id} && defined $sid
                            && $data_rec->{session_id} eq $sid;
                        my $role_writer = BpHook::Guards::Common::is_writer($data_rec->{subagent_type});
                        next unless defined $role_writer;
                        next unless _fresh_mtime($full, $stale_min);

                        # S-2: only now, with a live writer confirmed, pay
                        # for resolving the caller's own binding -- and only
                        # once per call.
                        if (!$caller_ws_tried) {
                            if (defined $own_binding) {
                                $caller_ws_tried = 1;
                                my $caller_resolved = _resolve_binding_cached($data_n, $own_binding, \%ledger_ws_cache);
                                $caller_ws = $caller_resolved->{write_set} if defined $caller_resolved;
                                $full_sweep = _is_full_sweep_runner($cmd) if defined $caller_ws;
                            }
                            elsif (!defined $aid) {
                                # 29-driver-validation-scope: the driver main
                                # thread has no binding of its own, but may
                                # opt in to the same scoping via a leading
                                # BP_VALIDATE_LEDGER=<ledger> assignment, or
                                # (never-halt 03) a --ledger/--ledger=<path>
                                # on the leading run-tests.pl invocation.
                                $caller_ws_tried = 1;
                                my ($st, $val) = _named_validation_ledger($cmd);
                                if ($st eq 'value') {
                                    my $r = _resolve_named_ledger($data_n, $val, \%ledger_ws_cache);
                                    if (defined $r) {
                                        if (_is_full_sweep_runner($cmd)) {
                                            $caller_ws = $r->{write_set};
                                        }
                                        else {
                                            # never-halt 09-gb-h-residuals sec
                                            # 3.13 (Decision 36 N6): naming A
                                            # does not scope an operand that
                                            # belongs to some OTHER package --
                                            # the scoped operand must itself
                                            # be a member of A's own
                                            # test_paths/write_set.
                                            my $operand = _scoped_test_operand($cmd);
                                            my $is_member = 0;
                                            if (defined $operand) {
                                                my $scope_paths = _ledger_scope_paths(
                                                    $data_n, $r->{blueprint}, $r->{package});
                                                $is_member = _operand_in_scope($operand, $data_n, $scope_paths)
                                                    if defined $scope_paths;
                                            }
                                            if ($is_member) {
                                                $caller_ws = $r->{write_set};
                                            }
                                            else {
                                                # never-halt 09-gb-h-residuals
                                                # sec 3.13: kept short on
                                                # purpose (the codebase's
                                                # usual interlock-message
                                                # length), so it survives
                                                # Common::fit()'s 160-char
                                                # budget for realistic
                                                # pkg/role names intact --
                                                # the original, spec-literal
                                                # wording ran well past 160
                                                # chars even before the
                                                # package name, and fit()
                                                # would truncate it mid-
                                                # sentence.
                                                my $pkgname_n6 = _sanitize($r->{package}, 64);
                                                return [
                                                    BpHook::Guards::Common::fit(
                                                        "BLOCKED (validation interlock): this test file is outside package ${pkgname_n6}'s test_paths/write_set; a write-capable worker ($role_writer) is in flight."),
                                                    BpHook::Guards::Common::fit($cmd_line),
                                                ];
                                            }
                                        }
                                    }
                                }
                                $full_sweep = _is_full_sweep_runner($cmd) if defined $caller_ws;
                            }
                        }

                        if (defined $caller_ws) {
                            # write-set-scoped subagent (B-3/B-4/B-5/B-6).
                            my $w_resolved = _resolve_binding_cached($data_n, $name, \%ledger_ws_cache);
                            if (!defined $w_resolved) {
                                # B-5: the other worker's footprint is
                                # unknown -- conservative fallback deny.
                                return [
                                    "BLOCKED (validation interlock): a write-capable worker ($role_writer) is in flight; running this now can report a false red.",
                                    $cmd_line,
                                ];
                            }
                            # 34-runner-redirect-operands sec 2.4: overlap
                            # wins over the full-sweep text when both are
                            # true against the same writer (keeps today's
                            # output for every case where the overlap claim
                            # is true).
                            if (write_sets_overlap($caller_ws, $w_resolved->{write_set})) {
                                my $bpname  = _sanitize($w_resolved->{blueprint}, 64);
                                my $pkgname = _sanitize($w_resolved->{package}, 64);
                                return [
                                    "BLOCKED (validation interlock): package $pkgname of blueprint $bpname has a write-capable worker ($role_writer) in flight whose write set overlaps yours; this run could report a false red.",
                                    # A coordinator that read only the line
                                    # above parked its package as needing a
                                    # human (judged-continuity-disarm/01,
                                    # 2026-10-22): say what to do.
                                    "This clears when that worker finishes. It is not a reason to park or block: do other work meanwhile, or record the pending run in ## Next action, keep the ledger running, and retry after your own next worker returns.",
                                    $cmd_line,
                                ];
                            }
                            # S-1: a full/multi-plugin sweep reads every
                            # in-flight worker's files regardless of write-set
                            # overlap, so it is denied by mere presence of a
                            # live writer.
                            if ($full_sweep) {
                                my $bpname  = _sanitize($w_resolved->{blueprint}, 64);
                                my $pkgname = _sanitize($w_resolved->{package}, 64);
                                return [
                                    'BLOCKED (validation interlock): a multi-file or full sweep reads every in-flight worker\'s files, so it is denied while any write-capable worker is live.',
                                    "Live writer: $role_writer, package $pkgname of blueprint $bpname. Name exactly one test file to get write-set scoping instead.",
                                    $cmd_line,
                                ];
                            }
                            next; # B-4 disjoint: scan continues past this record.
                        }

                        # B-1 (driver main thread) / B-3 (own binding
                        # unresolvable): today's session-wide behaviour.
                        return [
                            "BLOCKED (validation interlock): a write-capable worker ($role_writer) is in flight; running this now can report a false red.",
                            $cmd_line,
                        ];
                    }
                }
            }

            my $root = "$data_n/blueprints";
            my $found = _tree_check($p, $cmd, $data_n, $root, undef, $stale_min);
            if (defined $found) {
                my ($rl, $bpname, $pkgname) = @$found;
                return [
                    "BLOCKED (tree interlock): $rl of blueprint $bpname package $pkgname is mid-edit in this working tree; this run could report a false red.",
                    $tree_cmd_line,
                ];
            }
            return undef;
        }
    }

    return undef;
}

# ---------------------------------------------------------------------------
# GB-h -- "hygiene": deny cd/pushd anywhere in the command, statically
# resolvable writes/deletes/moves outside the repo root and the temp dir, and
# deletes/moves of protected roots (.git, .ccpraxis-local-data, the repo
# root, the home dir, or an ancestor of one). never-halt package
# 01-worker-bash-hygiene, spec 01-worker-bash-hygiene-spec.md. Decisions 3, 4,
# 10, 11, 14.
#
# Placed between GB-c and GB-d in run()'s rule list (spec sec 2.2). Never
# spawns a process. Fails open (returns undef) on any internal error, an
# unresolvable target, a missing/relative-without-cwd target, or an R that
# cannot be determined for (b).
# ---------------------------------------------------------------------------

my $HYG_HINT_TEXT = 'If the operator asked for this, ask them to run it themselves with the ! prefix.';

sub _hyg_is_winfam { return ($^O =~ /^(?:MSWin32|msys|cygwin)$/) ? 1 : 0 }

# redteam S1: the old path-run class '[^\s;&|()\'"\x60]*' does not exclude
# '{' / '}', so a run of braces re-scans itself from every '{' -- quadratic.
# Excluding them here makes each run non-overlapping (linear). redteam S3:
# on Windows-family perls, `type RM` resolves case-insensitively, so the
# name group is matched case-insensitively there too (paired with
# _hyg_command_name's fold).
# redteam-3 S4: the .exe suffix itself must fold case too on a Windows-
# family perl ("rm.EXE"), not just the verb name -- a shell there resolves
# both case-insensitively.
# never-halt 09-gb-h-residuals sec 3.11 (Decision 33): unlink, shred, dd,
# sort and curl are added to both alternations, with the same .exe/case
# rules as every other trigger verb.
my $HYG_TRIGGER_RE = _hyg_is_winfam()
    ? qr/(?:^|[;&|\s(){}\x60'"])(?:[^\s;&|()'"\x60{}]*\/)?(?i:cd|pushd|rm|rmdir|mv|cp|ln|touch|mkdir|tee|sed|perl|truncate|unlink|shred|dd|sort|curl)(?i:\.exe)?(?=[\s;&|()'"\x60]|$)|>/
    : qr/(?:^|[;&|\s(){}\x60'"])(?:[^\s;&|()'"\x60{}]*\/)?(?:cd|pushd|rm|rmdir|mv|cp|ln|touch|mkdir|tee|sed|perl|truncate|unlink|shred|dd|sort|curl)(?:\.exe)?(?=[\s;&|()'"\x60]|$)|>/;

sub _hyg_is_abs {
    my ($v) = @_;
    return 0 unless defined $v && length $v;
    return 1 if $v =~ m{^/};
    return 1 if _hyg_is_winfam() && $v =~ m{^[A-Za-z]:/};
    return 0;
}

sub _hyg_fold_key {
    my ($k) = @_;
    return $k unless defined $k;
    return $k unless _hyg_is_winfam();
    (my $v = $k) =~ tr/A-Z/a-z/;
    return $v;
}

# ---------------------------------------------------------------------------
# Word-value / raw safety (spec sec 2.6).
# ---------------------------------------------------------------------------
sub _hyg_raw_safe {
    my ($raw) = @_;
    return 0 unless defined $raw;
    my $len = length($raw);
    my $i = 0;
    my $q = 'none';
    while ($i < $len) {
        my $c = substr($raw, $i, 1);
        if ($q eq 'squote') {
            $q = 'none' if $c eq "'";
            $i++;
            next;
        }
        if ($q eq 'dquote') {
            if ($c eq '\\' && $i + 1 < $len) { $i += 2; next }
            return 0 if $c eq '$' || $c eq "\x60";
            $q = 'none' if $c eq '"';
            $i++;
            next;
        }
        if ($c eq "'") { $q = 'squote'; $i++; next }
        if ($c eq '"') { $q = 'dquote'; $i++; next }
        if ($c eq '\\' && $i + 1 < $len) { $i += 2; next }
        return 0 if $c eq '$' || $c eq "\x60";
        return 0 if $c eq '*' || $c eq '?' || $c eq '[' || $c eq '{';
        $i++;
    }
    return 0 if $q ne 'none';
    return 1;
}

sub _hyg_dequote {
    my ($raw) = @_;
    return '' unless defined $raw;
    my $len = length($raw);
    my $out = '';
    my $i = 0;
    my $q = 'none';
    while ($i < $len) {
        my $c = substr($raw, $i, 1);
        if ($q eq 'squote') {
            if ($c eq "'") { $q = 'none'; $i++; next }
            $out .= $c;
            $i++;
            next;
        }
        if ($q eq 'dquote') {
            if ($c eq '\\' && $i + 1 < $len) {
                my $nc = substr($raw, $i + 1, 1);
                if ($nc =~ /[\$"\\\n]/ || $nc eq "\x60") { $out .= $nc; $i += 2; next }
                $out .= $c;
                $i++;
                next;
            }
            if ($c eq '"') { $q = 'none'; $i++; next }
            $out .= $c;
            $i++;
            next;
        }
        if ($c eq "'") { $q = 'squote'; $i++; next }
        if ($c eq '"') { $q = 'dquote'; $i++; next }
        if ($c eq '\\' && $i + 1 < $len) { $out .= substr($raw, $i + 1, 1); $i += 2; next }
        $out .= $c;
        $i++;
    }
    return $out;
}

# _hyg_word_from_raw($raw) -> \%word, built directly from a RAW substring
# synthesised while splitting a redirect out of a larger word (Decision 19
# MUST bullets 1-2). Left with literal undef -- and so unresolvable -- when
# $raw carries an unquoted variable/glob/backtick; _hyg_resolve and the
# Decision-19-ruling glob-prefix code below already know how to fall back
# from raw alone in that case.
sub _hyg_word_from_raw {
    my ($raw) = @_;
    return { raw => undef, literal => undef, tail => undef } unless defined $raw && length $raw;
    return { raw => $raw, literal => undef, tail => undef } unless _hyg_raw_safe($raw);
    my $lit = _hyg_dequote($raw);
    my $tail;
    if ($lit =~ m{(?:^|/)([^/]+)$}) { $tail = $1 if length $1 }
    return { raw => $raw, literal => $lit, tail => $tail };
}

# _hyg_find_word_redirect($raw) -> ($prefix, $digits, $op, $rest) | (). Scans
# $raw quote-aware for the first unquoted, unescaped redirect operator
# (Decision 19 MUST bullet 1: redteam M1). At the very start of the word a
# leading digit run is still an fd number (bash's own rule -- digits count
# only when they are the ENTIRE word so far); anywhere later in the word,
# any digits immediately before the operator are ordinary text and stay in
# $prefix (an "operand"), matching real bash tokenising of e.g. "abc2>file".
sub _hyg_find_word_redirect {
    my ($raw) = @_;
    return () unless defined $raw;
    my $len = length($raw);
    my $i = 0;
    my $q = 'none';
    while ($i < $len) {
        my $c = substr($raw, $i, 1);
        if ($q eq 'squote') { $q = 'none' if $c eq "'"; $i++; next }
        if ($q eq 'dquote') {
            if ($c eq '\\' && $i + 1 < $len) { $i += 2; next }
            $q = 'none' if $c eq '"';
            $i++;
            next;
        }
        if ($c eq "'") { $q = 'squote'; $i++; next }
        if ($c eq '"') { $q = 'dquote'; $i++; next }
        if ($c eq '\\' && $i + 1 < $len) { $i += 2; next }
        if ($i == 0) {
            # redteam S5: an optional named-fd "{word}" prefix before the
            # operator (e.g. "{fd}>file"). One-time cost at word start only
            # (never per-character), so this substr copy is not the M3
            # quadratic hazard.
            my $rest = substr($raw, $i);
            if ($rest =~ /^(\{[A-Za-z_]\w*\})?([0-9]*)(<<<|<<-|<<|<&|<>|<|>>|>\||&>>|&>|>&|>)/) {
                my ($fdname, $digits, $op) = ($1, $2, $3);
                my $oplen = length($fdname // '') + length($digits) + length($op);
                return ('', $digits, $op, substr($raw, $oplen));
            }
        }
        else {
            # Decision 22 M3: a BOUNDED window (every real operator here is
            # at most 3 chars) instead of substr($raw, $i) -- copying the
            # rest of the word at EVERY character made this quadratic
            # (redteam-2 M3: 400 KB -> 21.9s, 1 MB -> 238s).
            my $window = substr($raw, $i, 3);
            if ($window =~ /^(<<<|<<-|<<|<&|<>|<|>>|>\||&>>|&>|>&|>)/) {
                my $op = $1;
                return (substr($raw, 0, $i), '', $op, substr($raw, $i + length($op)));
            }
        }
        $i++;
    }
    return ();
}

# _hyg_find_word_redirects($raw) -> ($lead, \@redirects) | (). redteam-2 S1:
# bash ends a WORD at the FIRST unquoted redirect operator, so more than one
# operator can appear glued in a single raw word ("a>b>c", "FOO=1>/out/f").
# Loops _hyg_find_word_redirect over the remainder after each operator so
# every redirect in the chain is found, not only the first; each entry's
# eventual classification (fd-dup vs a real file target) is still decided
# later, per redirect, by _hyg_classify_redirect.
sub _hyg_find_word_redirects {
    my ($raw) = @_;
    return () unless defined $raw;
    my @first = _hyg_find_word_redirect($raw);
    return () unless @first;
    my ($lead, $digits, $op, $rest) = @first;
    my @redirs;
    while (1) {
        my @next = _hyg_find_word_redirect($rest);
        if (@next) {
            my ($target_raw, $ndigits, $nop, $nrest) = @next;
            push @redirs, { digits => $digits, op => $op, target_raw => $target_raw };
            ($digits, $op, $rest) = ($ndigits, $nop, $nrest);
            next;
        }
        push @redirs, { digits => $digits, op => $op, target_raw => $rest };
        last;
    }
    return ($lead, \@redirs);
}

# _hyg_redirect_targets_in_word($raw, $next_word) -> (\@targets, $lead,
# $consumed_next). Classifies every redirect _hyg_find_word_redirects finds
# in $raw into a write target (or none, for a bare fd-dup); only the LAST
# redirect in the chain may consume $next_word (a separate following word)
# when its own target text is empty.
sub _hyg_redirect_targets_in_word {
    my ($raw, $next_word) = @_;
    return ([], $raw, 0) unless defined $raw;
    my ($lead, $redirs) = _hyg_find_word_redirects($raw);
    return ([], $raw, 0) unless $redirs && @$redirs;
    my @targets;
    my $consumed_next = 0;
    for my $j (0 .. $#$redirs) {
        my $r = $redirs->[$j];
        my ($is_output, $fd_dup, $shape_op, $classified_rest) = _hyg_classify_redirect($r->{op}, $r->{target_raw});
        next if $fd_dup;
        my $is_last = ($j == $#$redirs);
        my $target_word;
        if (length($classified_rest)) {
            $target_word = _hyg_word_from_raw($classified_rest);
        }
        elsif ($is_last && defined $next_word) {
            $target_word = $next_word;
            $consumed_next = 1;
        }
        if ($is_output && defined $target_word) {
            my $shape = ($shape_op eq '>>' || $shape_op eq '&>>') ? '>>' : '>';
            push @targets, { kind => 'write', shape => $shape, word => $target_word };
        }
    }
    return (\@targets, $lead, $consumed_next);
}

# _hyg_classify_redirect($op, $rest_raw) -> ($is_output, $fd_dup, $shape,
# $rest_raw). redteam S5: ">&" (not ">&N"/">&-") is a real output redirect to
# a file, and "<>" (read-write, creates the file) counts as output too. A
# bare ">&" with the target glued right after it (">&file", no space) has
# its target under the leading '&'; a bare "&" with nothing after it (a
# separate following word is the real target) is left for the caller.
sub _hyg_classify_redirect {
    my ($op, $rest_raw) = @_;
    if ($op eq '>&') {
        # a bare fd number/dash right after ">&" is a descriptor dup, never
        # a file target ('>&2', '>&-', '>&1-'); anything else (a path) is a
        # real output target.
        return (1, 1, $op, $rest_raw) if $rest_raw =~ /^(?:[0-9]+-?|-)$/;
        return (1, 0, $op, $rest_raw);
    }
    return (1, 0, $op, $rest_raw) if $op eq '<>';
    my $is_output = ($op =~ /^(?:>>|>\||&>>|&>|>)$/) ? 1 : 0;
    return ($is_output, 0, $op, $rest_raw);
}

# _hyg_rewrite_clobber_redirect($text) -> $text with every unquoted ">|"
# rewritten to "> " (redteam S4). BpHook::_segments splits unconditionally
# on a bare "|", so an unrewritten ">|" is torn into two "commands" and its
# target is lost; converting it to a plain ">" first (before _segments ever
# sees it) keeps the target parseable and only gives up the no-clobber-
# override semantics, which this rule has no way to represent anyway.
sub _hyg_rewrite_clobber_redirect {
    my ($t) = @_;
    return $t unless defined $t && index($t, '>|') >= 0;
    my $len = length($t);
    my $out = '';
    my $i = 0;
    my $q = 'none';
    while ($i < $len) {
        my $c = substr($t, $i, 1);
        if ($q eq 'squote') { $out .= $c; $q = 'none' if $c eq "'"; $i++; next }
        if ($q eq 'dquote') {
            if ($c eq '\\' && $i + 1 < $len) { $out .= $c . substr($t, $i + 1, 1); $i += 2; next }
            $out .= $c;
            $q = 'none' if $c eq '"';
            $i++;
            next;
        }
        if ($c eq "'") { $q = 'squote'; $out .= $c; $i++; next }
        if ($c eq '"') { $q = 'dquote'; $out .= $c; $i++; next }
        if ($c eq '\\' && $i + 1 < $len) { $out .= $c . substr($t, $i + 1, 1); $i += 2; next }
        if ($c eq '>' && $i + 1 < $len && substr($t, $i + 1, 1) eq '|') { $out .= '> '; $i += 2; next }
        $out .= $c;
        $i++;
    }
    return $out;
}

# _hyg_raw_value_and_flags($raw) -> ($value, \@flags). Mirrors
# BpHook::_tokenize_words's own per-character word-value/predictability walk
# (BpHook.pm ~1192-1254), applied to a single already-isolated word's raw
# text, so GB-h can recover a literal prefix or suffix around an unquoted
# variable/glob without re-tokenising a whole segment.
sub _hyg_raw_value_and_flags {
    my ($raw) = @_;
    return ('', []) unless defined $raw;
    my $len = length($raw);
    my $value = '';
    my @flags;
    my $first = 1;
    my $i = 0;
    while ($i < $len) {
        my $cc = substr($raw, $i, 1);
        if ($cc eq "'") {
            $i++;
            while ($i < $len && substr($raw, $i, 1) ne "'") {
                $value .= substr($raw, $i, 1);
                push @flags, 0;
                $i++;
            }
            $i++ if $i < $len;
            $first = 0;
            next;
        }
        if ($cc eq '"') {
            $i++;
            while ($i < $len && substr($raw, $i, 1) ne '"') {
                my $c2 = substr($raw, $i, 1);
                if ($c2 eq '\\' && $i + 1 < $len) {
                    $value .= substr($raw, $i + 1, 1);
                    push @flags, 1;
                    $i += 2;
                    next;
                }
                my $f = ($c2 eq '$' || $c2 eq "\x60") ? 1 : 0;
                $value .= $c2;
                push @flags, $f;
                $i++;
            }
            $i++ if $i < $len;
            $first = 0;
            next;
        }
        if ($cc eq '\\' && $i + 1 < $len) {
            $value .= substr($raw, $i + 1, 1);
            push @flags, 0;
            $i += 2;
            $first = 0;
            next;
        }
        if ($cc eq '$' || $cc eq "\x60" || $cc eq '*' || $cc eq '?' || $cc eq '[' || $cc eq '{') {
            $value .= $cc;
            push @flags, 1;
            $i++;
            $first = 0;
            next;
        }
        if ($cc eq '~' && $first) {
            $value .= $cc;
            push @flags, 1;
            $i++;
            $first = 0;
            next;
        }
        $value .= $cc;
        push @flags, 0;
        $i++;
        $first = 0;
    }
    return ($value, \@flags);
}

# _hyg_glob_prefix_word($raw) -> (\%word, $remainder) | (undef, $remainder).
# Decision 19 RULING (4(c) vs 4(d)): the literal text before the FIRST
# unquoted glob/variable character, with any trailing '/' or '/.' stripped,
# as a fully-literal word -- so "rm -rf .git/*" can still be checked against
# the protected-root list even though ".git/*" itself is unresolvable.
# $remainder is the raw text from that first glob/variable character to the
# end (redteam-2 S3: callers need it to tell a PURE match-all glob like "*"
# from an ordinary partial one like "*.tmp"). The word half of the return is
# undef when there is no glob/variable, or nothing precedes it.
sub _hyg_glob_prefix_word {
    my ($raw) = @_;
    return (undef, undef) unless defined $raw;
    my ($value, $flags) = _hyg_raw_value_and_flags($raw);
    my $idx;
    for my $k (0 .. $#$flags) { if ($flags->[$k]) { $idx = $k; last } }
    return (undef, undef) unless defined $idx;
    my $remainder = substr($value, $idx);
    my $prefix = substr($value, 0, $idx);
    my $changed = 1;
    while ($changed) {
        $changed = 0;
        if ($prefix =~ s{/\.$}{}) { $changed = 1 }
        elsif ($prefix =~ s{/$}{}) { $changed = 1 }
    }
    return (undef, $remainder) unless length $prefix;
    return ({ literal => $prefix, raw => $prefix, tail => undef }, $remainder);
}

# _hyg_predictable_tail($raw) -> $tail | undef (redteam S7): the tokenizer's
# own 'tail' field is undef whenever the value ends in '/' (no characters
# survive after the last slash) or has no slash at all with no cwd to
# resolve against. Recompute it here after stripping a trailing run of '/'
# and '/.' units first, so "$X/.git/" and "rm -rf .git/" still expose
# ".git" as their predictable last component.
sub _hyg_predictable_tail {
    my ($raw) = @_;
    return undef unless defined $raw;
    my ($value, $flags) = _hyg_raw_value_and_flags($raw);
    my $vlen = length($value);
    my $changed = 1;
    while ($changed && $vlen > 0) {
        $changed = 0;
        if ($vlen >= 2 && substr($value, $vlen - 2, 2) eq '/.') { $vlen -= 2; $changed = 1; next }
        if (substr($value, $vlen - 1, 1) eq '/') { $vlen -= 1; $changed = 1; next }
    }
    return undef unless $vlen > 0;
    $value = substr($value, 0, $vlen);
    $flags = [ @{$flags}[0 .. $vlen - 1] ];
    my $lastslash = -1;
    for (my $k = 0; $k < length($value); $k++) { $lastslash = $k if substr($value, $k, 1) eq '/' }
    my $tailstr = ($lastslash >= 0) ? substr($value, $lastslash + 1) : $value;
    return undef unless length $tailstr;
    my $start = $lastslash + 1;
    for my $k ($start .. $#$flags) { return undef if $flags->[$k] }
    return $tailstr;
}

# _hyg_fit_tail($prefix, $path, $suffix) -> one line, at most 160 chars,
# built so that Common::fit()'s own front-truncation never has to run on it
# (reviewer S2: fit() cuts from the front, which throws away exactly the
# path TAIL -- the protected component -- that path_echo kept on purpose).
# Truncates $path from the FRONT (keeping its tail) to whatever budget is
# left after $prefix and $suffix, instead.
sub _hyg_fit_tail {
    my ($prefix, $path, $suffix) = @_;
    $prefix = '' unless defined $prefix;
    $path   = '' unless defined $path;
    $suffix = '' unless defined $suffix;
    my $budget = 160 - length($prefix) - length($suffix);
    return $prefix . $path . $suffix if $budget >= length($path);
    return $prefix . $path . $suffix if $budget <= 3;
    return $prefix . '...' . substr($path, -($budget - 3)) . $suffix;
}

# _hyg_resolve(\%word, $cwd_bytes, \%ctx) -> ($D, $K) | (). Spec sec 2.6.
sub _hyg_resolve {
    my ($word, $cwd_bytes, $ctx) = @_;
    return () unless ref $word eq 'HASH';
    my $value;
    if (defined $word->{literal}) {
        $value = BpHook::_to_bytes($word->{literal});
    }
    else {
        my $raw = $word->{raw};
        return () unless defined $raw;
        if ($raw eq '~') {
            return () unless defined $ctx->{home1};
            $value = BpHook::_to_bytes($ctx->{home1});
        }
        elsif ($raw =~ m{^~/(.*)$}s) {
            my $rest = $1;
            return () unless _hyg_raw_safe($rest);
            return () unless defined $ctx->{home1};
            $value = BpHook::_to_bytes($ctx->{home1}) . '/' . BpHook::_to_bytes(_hyg_dequote($rest));
        }
        elsif (_hyg_raw_safe($raw)) {
            $value = BpHook::_to_bytes(_hyg_dequote($raw));
        }
        else {
            return ();
        }
    }
    return () unless defined $value && length $value;

    my $D;
    if (_hyg_is_abs($value)) {
        $D = BpHook::Guards::Common::resolve_path($value, undef);
    }
    else {
        return () unless defined $cwd_bytes && length $cwd_bytes && _hyg_is_abs($cwd_bytes);
        $D = BpHook::Guards::Common::resolve_path($value, $cwd_bytes);
    }
    return () unless defined $D;
    my $K = BpHook::Guards::Common::canon($D);
    $K = '' unless defined $K;
    $K = '/' if $K eq '';
    $K = _hyg_fold_key($K);
    return ($D, $K);
}

sub _hyg_root_dk {
    my ($root) = @_;
    return () unless defined $root && length $root;
    my $D = BpHook::Guards::Common::resolve_path($root, undef);
    return () unless defined $D;
    my $K = BpHook::Guards::Common::canon($D);
    $K = '' unless defined $K;
    $K = '/' if $K eq '';
    $K = _hyg_fold_key($K);
    return ($D, $K);
}

sub _hyg_never_target {
    my ($D) = @_;
    return 0 unless defined $D;
    return 1 if $D =~ m{^/dev/(?:null|stdout|stderr|stdin|tty)$};
    return 1 if $D =~ m{^/dev/fd/[0-9]+$};
    # never-halt 09-gb-h-residuals sec 3.8 (r2-N3): /dev/tcp/HOST/PORT and
    # /dev/udp/HOST/PORT are bash's pseudo-device network redirection, never
    # a resolvable filesystem write target.
    return 1 if $D =~ m{^/dev/(?:tcp|udp)/};
    return 0;
}

# _hyg_inside($D, $K, $root) -- "D equals root or lies under it" (spec 2.6).
sub _hyg_inside {
    my ($D, $K, $root) = @_;
    return 0 unless defined $D && defined $K && defined $root && length $root;
    my $Droot = BpHook::Guards::Common::resolve_path($root, undef);
    return 0 unless defined $Droot;
    my $Kroot = BpHook::Guards::Common::canon($Droot);
    $Kroot = '' unless defined $Kroot;
    $Kroot = '/' if $Kroot eq '';
    $Kroot = _hyg_fold_key($Kroot);

    return 1 if $Kroot eq $K;
    if (substr($Kroot, -1) eq '/') {
        return 1 if index($K, $Kroot) == 0;
    }
    else {
        return 1 if index($K, "$Kroot/") == 0;
    }

    my @stroot = eval { stat($Droot) };
    return 0 unless @stroot;
    my ($rdev, $rino) = ($stroot[0], $stroot[1]);
    return 0 unless $rdev || $rino;

    # A bare DRIVE root (never bare POSIX "/", which spec sec 2.6 explicitly
    # excludes) is the top of one physical volume: every path stat()able on
    # that same volume shares its device number, whatever POSIX alias
    # (/tmp, an 8.3 short name, ...) it is spelled through. A device-only
    # match against the nearest existing ancestor of D is therefore
    # sufficient proof of containment here, without walking or comparing
    # inodes.
    if (_hyg_is_winfam() && $Kroot =~ m{^[a-z]:/$} && $rdev) {
        my $vcand = $D;
        my $vE;
        for (1 .. 64) {
            if (-e $vcand) { $vE = $vcand; last }
            my $parent = $vcand;
            $parent =~ s{/[^/]*$}{};
            last if $parent eq $vcand || $parent eq '';
            $vcand = $parent;
        }
        if (defined $vE) {
            my @vs = eval { stat($vE) };
            return 1 if @vs && $vs[0] == $rdev;
        }
    }

    # review M3 / redteam S9: spec 2.6 step 2 skips the identity fallback
    # when "ino == 0" (native MSWin32 perl's stat() reports dev as the drive
    # number -- nonzero -- and ino as 0), not merely when both are zero. On
    # such a perl every existing path on the same drive would otherwise
    # compare equal to every root via the ancestor-chain walk below.
    return 0 unless $rino;

    my $cand = $D;
    my $E;
    for (1 .. 64) {
        if (-e $cand) { $E = $cand; last }
        my $parent = $cand;
        $parent =~ s{/[^/]*$}{};
        last if $parent eq $cand || $parent eq '';
        $cand = $parent;
    }
    return 0 unless defined $E;

    my @chain = ($E);
    my $walk = $E;
    for (1 .. 64) {
        my $parent = $walk;
        $parent =~ s{/[^/]*$}{};
        last if $parent eq $walk || $parent eq '';
        push @chain, $parent;
        $walk = $parent;
    }
    for my $anc (@chain) {
        my @s = eval { stat($anc) };
        next unless @s;
        return 1 if $s[0] == $rdev && $s[1] == $rino;
    }
    return 0;
}

# _hyg_lexical_inside($K, $root) -- the cheap, no-stat half of _hyg_inside
# alone (Decision 22 M3, D19 SHOULD "lexical before stat"): a pure string
# containment test, used to try every candidate root's fast path FIRST,
# before any of them is allowed to fall through to a stat-based walk.
sub _hyg_lexical_inside {
    my ($K, $root) = @_;
    return 0 unless defined $K && defined $root && length $root;
    my $Droot = BpHook::Guards::Common::resolve_path($root, undef);
    return 0 unless defined $Droot;
    my $Kroot = BpHook::Guards::Common::canon($Droot);
    $Kroot = '' unless defined $Kroot;
    $Kroot = '/' if $Kroot eq '';
    $Kroot = _hyg_fold_key($Kroot);
    return 1 if $Kroot eq $K;
    if (substr($Kroot, -1) eq '/') { return index($K, $Kroot) == 0 ? 1 : 0 }
    return index($K, "$Kroot/") == 0 ? 1 : 0;
}

# _hyg_root_identity($root) -> \%id | undef. Decision 22 M3: precomputes,
# ONCE per _gb_h_impl call, everything _hyg_protected_hit needs to answer
# "is this FIXED root (R or a home dir) at-or-under a given TARGET" without
# re-walking the root's own ancestor chain and re-stat'ing it for every
# target -- the report's 90s/25000-operand bottleneck (each target used to
# re-walk R's/home's fixed chain from scratch). {K} is the root's own
# canonical key; {ids} is the set of (dev:ino) for every ancestor in its
# chain (an ino==0 ancestor is never added -- review M3/S9's skip, mirrored
# here); {vdev} is the device of the root's nearest EXISTING ancestor, for
# the same bare-drive-root shortcut _hyg_inside uses (gated, at the call
# site, on the TARGET's key being a bare drive letter).
sub _hyg_root_identity {
    my ($root) = @_;
    return undef unless defined $root && length $root;
    my $Droot = BpHook::Guards::Common::resolve_path($root, undef);
    return undef unless defined $Droot;
    my $Kroot = BpHook::Guards::Common::canon($Droot);
    $Kroot = '' unless defined $Kroot;
    $Kroot = '/' if $Kroot eq '';
    $Kroot = _hyg_fold_key($Kroot);

    my %ids;
    my $vdev;
    my $cand = $Droot;
    my $E;
    for (1 .. 64) {
        if (-e $cand) { $E = $cand; last }
        my $parent = $cand;
        $parent =~ s{/[^/]*$}{};
        last if $parent eq $cand || $parent eq '';
        $cand = $parent;
    }
    if (defined $E) {
        my @chain = ($E);
        my $walk = $E;
        for (1 .. 64) {
            my $parent = $walk;
            $parent =~ s{/[^/]*$}{};
            last if $parent eq $walk || $parent eq '';
            push @chain, $parent;
            $walk = $parent;
        }
        for my $anc (@chain) {
            my @s = eval { stat($anc) };
            next unless @s;
            $vdev = $s[0] unless defined $vdev;
            $ids{"$s[0]:$s[1]"} = 1 if $s[1];
        }
    }
    return { D => $Droot, K => $Kroot, ids => \%ids, vdev => $vdev };
}

# ---------------------------------------------------------------------------
# Roots (spec sec 2.7).
# ---------------------------------------------------------------------------
sub _hyg_root_via_git {
    my ($cwd) = @_;
    return undef unless defined $cwd && length $cwd;
    my $dir = $cwd;
    $dir =~ s{/+$}{};
    for (1 .. 64) {
        return $dir if -e "$dir/.git";
        last if $dir eq '' || $dir eq '/';
        last if $dir =~ m{^[A-Za-z]:$};
        my $parent = $dir;
        $parent =~ s{/[^/]*$}{};
        $parent = '/' if $parent eq '' && $dir =~ m{^/};
        last if $parent eq $dir;
        $dir = $parent;
    }
    return undef;
}

sub _hyg_ctx {
    my ($p) = @_;
    my $cwd;
    if (ref $p eq 'HASH' && defined $p->{cwd} && !ref($p->{cwd}) && length $p->{cwd}) {
        my $c = BpHook::_to_bytes($p->{cwd});
        $cwd = $c if _hyg_is_abs($c);
    }

    my $R;
    for my $envname (qw(CLAUDE_PROJECT_DIR BP_PROJECT_ROOT)) {
        last if defined $R;
        my $v = $ENV{$envname};
        next unless defined $v && length $v;
        my $c = BpHook::_to_bytes($v);
        $R = $c if _hyg_is_abs($c);
    }
    if (!defined $R && defined $cwd) {
        $R = _hyg_root_via_git($cwd);
    }

    my @tmp;
    my %seen_tmp;
    for my $v (eval { File::Spec->tmpdir }, $ENV{TMP}, $ENV{TEMP}, $ENV{TMPDIR}) {
        next unless defined $v && length $v;
        my $b = BpHook::_to_bytes($v);
        next unless _hyg_is_abs($b);
        my $k = BpHook::Guards::Common::canon($b);
        $k = '' unless defined $k;
        $k = '/' if $k eq '';
        $k = _hyg_fold_key($k);
        next if $seen_tmp{$k}++;
        push @tmp, $b;
    }

    my @home;
    for my $v ($ENV{HOME}, $ENV{USERPROFILE}) {
        next unless defined $v && length $v;
        my $b = BpHook::_to_bytes($v);
        push @home, $b if _hyg_is_abs($b);
    }

    # Decision 22 M3: resolve/stat R and each HOME identity ONCE per call
    # (not once per target), de-duplicated by canonical key -- HOME and
    # USERPROFILE are frequently the same directory.
    my $R_id;
    $R_id = _hyg_root_identity($R) if defined $R;
    my @home_ids;
    my %seen_home_key;
    for my $h (@home) {
        my $id = _hyg_root_identity($h);
        next unless defined $id;
        next if $seen_home_key{ $id->{K} }++;
        push @home_ids, $id;
    }

    return {
        R        => $R,
        tmp      => \@tmp,
        home     => \@home,
        home1    => (@home ? $home[0] : undef),
        cwd      => $cwd,
        R_id     => $R_id,
        home_ids => \@home_ids,
    };
}

# ---------------------------------------------------------------------------
# Home aliases, (c) only (spec sec 2.8).
# ---------------------------------------------------------------------------
# redteam-2 M2 helper: true iff $s carries an unquoted/unescaped glob
# metachar, so the caller knows to leave the word raw-but-unresolved
# (letting the Decision 19 glob-prefix check below run) instead of building
# a fully literal path where the glob character would become ordinary text.
sub _hyg_word_has_unquoted_glob {
    my ($s) = @_;
    return 0 unless defined $s && length $s;
    return $s =~ /[*?\[{]/ ? 1 : 0;
}

# redteam-2 M2: shared constructor for every home-alias branch below. When
# $rest has a glob character, the alias must still reach the glob-prefix
# check (Decision 19 ruling) -- "rm -rf ~/*"/'"$HOME"/*' were being resolved
# straight to a literal "<home>/*" path, which is neither home nor an
# ancestor of it, so the deny never fired.
sub _hyg_home_alias_word {
    my ($home1, $rest) = @_;
    $rest = '' unless defined $rest;
    if (_hyg_word_has_unquoted_glob($rest)) {
        return { literal => undef, raw => $home1 . $rest, tail => undef };
    }
    return { literal => $home1 . $rest, raw => $home1 . $rest, tail => undef };
}

sub _hyg_home_alias {
    my ($w, $ctx) = @_;
    return undef unless ref $w eq 'HASH';
    my $home1 = $ctx->{home1};
    return undef unless defined $home1;
    my $raw = $w->{raw};
    return undef unless defined $raw;

    if ($raw eq '~' || $raw eq '~/') {
        return { literal => $home1, raw => $home1, tail => undef };
    }

    # redteam-3 S3: "~{,.bak}" -- a bare "~" directly glued to an unquoted
    # brace list. "~/(.*)" below requires a literal "/" first, which a
    # brace list right after "~" never has, so this needs its own branch
    # (checked BEFORE it) or "mv ~ ~.bak"'s brace expansion of home itself
    # is never classified as a home alias at all.
    if ($raw =~ /^~(\{.*)$/s) {
        my $rest = $1;
        return _hyg_home_alias_word($home1, $rest) if _hyg_word_has_unquoted_glob($rest);
        return undef;
    }

    # redteam-2 M2: "~/*", "~/.*" etc -- same carve-out as the quoted/bare
    # $HOME forms below. Kept as its own branch since a bare "~" resolves
    # through a different path in _hyg_resolve than $HOME/${HOME}.
    if ($raw =~ m{^~/(.*)$}s) {
        my $rest = $1;
        return _hyg_home_alias_word($home1, '/' . $rest) if _hyg_word_has_unquoted_glob($rest);
        return undef;
    }

    # review M2 / redteam N4: the variable itself may be quoted while the
    # rest of the word (a following /... or, redteam-3 S3, a following
    # unquoted brace list) is bare, e.g. "$HOME"/x, "${USERPROFILE}"/x/..
    # or "$HOME"{,.bak} -- recognise that shape directly, not only a
    # wholly-quoted word.
    if ($raw =~ /^"(\$\{?(?:HOME|USERPROFILE)\}?)"(.*)$/) {
        my $rest = $2;
        return _hyg_home_alias_word($home1, $rest)
            if $rest eq '' || $rest =~ m{^/} || $rest =~ /^\{/;
        return undef;
    }
    if ($raw =~ /^"(%USERPROFILE%)"(.*)$/i) {
        my $rest = $2;
        return _hyg_home_alias_word($home1, $rest)
            if $rest eq '' || $rest =~ m{^[/\\]} || $rest =~ /^\{/;
        return undef;
    }

    my $body = $raw;
    if ($body =~ /^"(.*)"$/s) { $body = $1 }

    if ($body =~ /^%USERPROFILE%(.*)$/is) {
        my $rest = $1;
        return _hyg_home_alias_word($home1, $rest)
            if $rest eq '' || $rest =~ m{^[/\\]} || $rest =~ /^\{/;
        return undef;
    }
    if ($body =~ /^\$\{?(?:HOME|USERPROFILE)\}?(.*)$/) {
        my $rest = $1;
        return _hyg_home_alias_word($home1, $rest)
            if $rest eq '' || $rest =~ m{^/} || $rest =~ /^\{/;
        return undef;
    }
    return undef;
}

# ---------------------------------------------------------------------------
# Redirect / operand parsing (spec sec 2.5).
# ---------------------------------------------------------------------------
sub _hyg_scan_redirects {
    my ($argv) = @_;
    my @operands;
    my @targets;
    my $n = scalar @$argv;
    my $i = 0;
    while ($i < $n) {
        my $w = $argv->[$i];
        my $raw = $w->{raw};
        my ($found_targets, $lead, $consumed_next) = defined $raw
            ? _hyg_redirect_targets_in_word($raw, ($i + 1 < $n) ? $argv->[$i + 1] : undef)
            : ([], undef, 0);
        if (!@$found_targets) {
            push @operands, $w;
            $i++;
            next;
        }
        # redteam M1/S1: a redirect operator glued to a preceding word (no
        # space) still leaves that prefix as a real operand of the command;
        # more than one redirect can be glued into the same word (S1).
        push @operands, _hyg_word_from_raw($lead) if length($lead);
        push @targets, @$found_targets;
        $i += $consumed_next ? 2 : 1;
    }
    return (\@operands, \@targets);
}

sub _hyg_positional {
    my ($operands, $consuming) = @_;
    $consuming ||= {};
    my @pos;
    my %captured;
    my $dd = 0;
    my $i = 0;
    my $n = scalar @$operands;
    while ($i < $n) {
        my $w = $operands->[$i];
        my $lit = $w->{literal};
        if (!$dd && defined $lit && $lit eq '--') { $dd = 1; $i++; next }
        my $probe = defined $lit ? $lit : $w->{raw};
        if (!$dd && defined $probe && $probe =~ /^-/) {
            if (defined $lit && $consuming->{$lit}) {
                $captured{$lit} = ($i + 1 < $n) ? $operands->[$i + 1] : undef;
                $i += 2;
                next;
            }
            $i++;
            next;
        }
        push @pos, $w;
        $i++;
    }
    return (\@pos, \%captured);
}

# redteam M4: every target-directory form of mv/cp/ln -- "-t DIR", "-tDIR",
# "-rt DIR" (a short-option cluster ending in 't'), "-ftDIR", "--target-
# directory DIR" and "--target-directory=DIR" -- must be recognised, or the
# real SOURCE (possibly ".git") is misread as the destination and (c) never
# sees it as a write at all.
sub _hyg_mvcp_dest {
    my ($operands) = @_;
    my $dest_word;
    my @rest;
    my $dd  = 0;
    my $n   = scalar @$operands;
    my $i   = 0;
    while ($i < $n) {
        my $w   = $operands->[$i];
        my $lit = $w->{literal};
        if (!$dd && defined $lit && $lit eq '--') { $dd = 1; push @rest, $w; $i++; next }
        # redteam-2 S2: GNU getopt_long accepts any UNAMBIGUOUS PREFIX of
        # --target-directory ("--t", "--targ", "--target", ...), with or
        # without an inline "=value" -- not only the full spelling.
        if (!$dd && defined $lit && $lit =~ /^(--[A-Za-z-]+)(?:=(.*))?$/
            && length($1) >= 3 && index('--target-directory', $1) == 0)
        {
            my $val = $2;
            if (defined $val) {
                $dest_word = { literal => $val, raw => $val, tail => undef } if length $val;
                $i++;
                next;
            }
            $dest_word = ($i + 1 < $n) ? $operands->[$i + 1] : undef;
            $i += ($i + 1 < $n) ? 2 : 1;
            next;
        }
        if (!$dd && defined $lit && $lit =~ /^-[A-Za-z]*t(.*)$/) {
            my $remainder = $1;
            if (length $remainder) {
                $dest_word = { literal => $remainder, raw => $remainder, tail => undef };
                $i++;
                next;
            }
            $dest_word = ($i + 1 < $n) ? $operands->[$i + 1] : undef;
            $i += ($i + 1 < $n) ? 2 : 1;
            next;
        }
        push @rest, $w;
        $i++;
    }
    my ($pos, undef) = _hyg_positional(\@rest, { '-S' => 1 });
    return ($dest_word, $pos);
}

sub _hyg_command_name {
    my ($w) = @_;
    return undef unless ref $w eq 'HASH';
    my $s = defined $w->{literal} ? $w->{literal} : $w->{tail};
    if (!defined $s && defined $w->{raw} && _hyg_raw_safe($w->{raw})) {
        # redteam-2 S5: the shared BpHook tokenizer marks ANY backslash
        # escape inside double quotes as unpredictable, even one whose
        # escaped char has no special shell meaning (a literal Windows path
        # backslash, e.g. "C:\Git\...\rm.exe") -- GuardBash's own dequoter
        # (_hyg_dequote) knows the narrower real rule (only \$ \` \" \\ and
        # \newline are real escapes), so fall back to it before giving up.
        $s = _hyg_dequote($w->{raw});
    }
    return undef unless defined $s;
    (my $b = $s) =~ s{.*[/\\]}{};
    $b =~ s/\.exe$//i;
    # redteam S3: this host's shell resolves RM/TOUCH/etc case-
    # insensitively on Windows-family perls (case-insensitive filesystem).
    $b = lc($b) if _hyg_is_winfam();
    return $b;
}

# ---------------------------------------------------------------------------
# Simple-command reduction and shell -c / eval recursion (spec sec 2.4).
# ---------------------------------------------------------------------------
sub _hyg_reduce {
    my ($words) = @_;
    my @w = @$words;
    my $n = scalar @w;
    return (undef, undef, []) if $n == 0;

    if (defined $w[0]{literal} && $w[0]{literal} =~ /^(\(+)(.*)$/) {
        my $rest = $2;
        if (length $rest) {
            $w[0] = { literal => $rest, raw => $w[0]{raw}, tail => $w[0]{tail} };
        }
        else {
            shift @w;
            $n--;
        }
    }

    my @prefix_targets;
    my $i = 0;
    my $progress = 1;
    while ($progress && $i < $n) {
        $progress = 0;
        while ($i < $n && defined $w[$i]{literal} && $w[$i]{literal} =~ /^(?:\(|\{|!)$/) { $i++; $progress = 1 }
        # redteam-2 S1: an assignment word can carry an embedded redirect with
        # no space ("FOO=1>/out/f"); recover any real write targets from it
        # via the same chain-aware helper the command word and argv scan use,
        # rather than just discarding the whole word.
        while ($i < $n && defined $w[$i]{raw} && $w[$i]{raw} =~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
            my $raw_i = $w[$i]{raw};
            my $next_w = ($i + 1 < $n) ? $w[$i + 1] : undef;
            my ($targets, undef, $consumed_next) = _hyg_redirect_targets_in_word($raw_i, $next_w);
            push @prefix_targets, @$targets;
            $i += $consumed_next ? 2 : 1;
            $progress = 1;
        }
        while ($i < $n) {
            # review M1 / redteam M2 / redteam-2 S1: a redirect at the very
            # start of a word in the command prefix is skipped here so the
            # COMMAND WORD can still be found, but it must not simply
            # vanish -- record it (and any further redirect glued after it)
            # as targets too, so "> f", "exec > f", "FOO=1 > f" and
            # ">a>/out/f echo" all still deny.
            my $raw = $w[$i]{raw};
            last unless defined $raw;
            my ($targets, $lead, $consumed_next) = _hyg_redirect_targets_in_word($raw, ($i + 1 < $n) ? $w[$i + 1] : undef);
            last unless @$targets && $lead eq '';
            push @prefix_targets, @$targets;
            $i += $consumed_next ? 2 : 1;
            $progress = 1;
        }
        last unless $i < $n;
        my $lit = $w[$i]{literal};
        last unless defined $lit;
        # redteam-2 S4 / redteam-3 S4: this host's shell resolves wrapper
        # keywords (env/nice/sudo/...) case-insensitively too, on Windows-
        # family perls -- fold before every keyword comparison below. Also
        # strip a path prefix and a ".exe" suffix (case-insensitively) the
        # same way _hyg_command_name does, so "/usr/bin/env" and "env.exe"
        # are recognised as "env" too, not just a bare "env" word.
        my $lit_fold = $lit;
        $lit_fold =~ s{.*[/\\]}{};
        $lit_fold =~ s/\.exe$//i;
        $lit_fold = lc($lit_fold) if _hyg_is_winfam();
        if ($lit_fold =~ /^(?:builtin|exec|nohup|then|do|else|elif|if|while|until)$/) {
            $i++;
            $progress = 1;
            next;
        }
        # redteam S3: `command -p` / `time -p` unwrap to the real command
        # exactly like the bare keyword, plus their own optional -p.
        # redteam-3 S4: `command -- rm ...` must skip the "--" too, or it
        # is mistaken for the real command word.
        if ($lit_fold eq 'command' || $lit_fold eq 'time') {
            $i++;
            $progress = 1;
            $i++ if $i < $n && defined $w[$i]{literal} && ($w[$i]{literal} eq '-p' || $w[$i]{literal} eq '--');
            next;
        }
        if ($lit_fold eq 'env') {
            $i++;
            $progress = 1;
            while ($i < $n && defined $w[$i]{literal} && $w[$i]{literal} =~ /^-/) {
                my $opt = $w[$i]{literal};
                if ($opt eq '--') { $i++; last }
                elsif ($opt eq '-i' || $opt eq '--ignore-environment') { $i++ }
                elsif ($opt eq '-u' || $opt eq '-C' || $opt eq '--unset' || $opt eq '--chdir') { $i += 2 }
                elsif ($opt =~ /^(?:-u|--unset=|-C|--chdir=)/) { $i++ }
                else { $i++ }
            }
            while ($i < $n && defined $w[$i]{raw} && $w[$i]{raw} =~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
                my $raw_i = $w[$i]{raw};
                my $next_w = ($i + 1 < $n) ? $w[$i + 1] : undef;
                my ($targets, undef, $consumed_next) = _hyg_redirect_targets_in_word($raw_i, $next_w);
                push @prefix_targets, @$targets;
                $i += $consumed_next ? 2 : 1;
            }
            next;
        }
        if ($lit_fold eq 'timeout') {
            $i++;
            $progress = 1;
            while ($i < $n && defined $w[$i]{literal} && $w[$i]{literal} =~ /^-/) {
                my $opt = $w[$i]{literal};
                if ($opt =~ /^(?:--kill-after=|--signal=)/) { $i++ }
                elsif ($opt eq '-k' || $opt eq '-s' || $opt eq '--kill-after' || $opt eq '--signal') { $i++; $i++ if $i < $n }
                else { $i++ }
            }
            $i++ if $i < $n;
            next;
        }
        # redteam S3/redteam-2 S4: nice's own adjustment may be "-n N", "-nN"
        # (glued digits), a bare negative/positive number, or
        # "--adjustment[=N]".
        if ($lit_fold eq 'nice') {
            $i++;
            $progress = 1;
            while ($i < $n && defined $w[$i]{literal} && $w[$i]{literal} =~ /^-/) {
                my $opt = $w[$i]{literal};
                if ($opt eq '-n') { $i += 2 }
                elsif ($opt eq '--adjustment') { $i++; $i++ if $i < $n }
                elsif ($opt =~ /^(?:--adjustment=|-[0-9])/) { $i++ }
                elsif ($opt =~ /^-n[0-9]+$/) { $i++ }
                else { last }
            }
            next;
        }
        # redteam-2 S4: stdbuf's -i/-o/-e may take its value glued ("-o0")
        # or as a separate following word ("-o 0"). redteam-3 S4: same for
        # the long forms --input/--output/--error, glued with "=" or not.
        if ($lit_fold eq 'stdbuf') {
            $i++;
            $progress = 1;
            while ($i < $n && defined $w[$i]{literal}
                && $w[$i]{literal} =~ /^(?:-[ioe]|--(?:input|output|error)(?:=.*)?)/) {
                my $opt = $w[$i]{literal};
                if ($opt =~ /^(?:-[ioe]|--(?:input|output|error))$/) { $i += 2 }
                else { $i++ }
            }
            next;
        }
        # redteam-2 S4: sudo's own options that take a value (-u/-g/-C/-D/
        # -h/-p/-r/-t/-U) must consume that following word too, or it is
        # mistaken for the real command name (e.g. "sudo -u root rm ...").
        # redteam-3 S4: same for the long forms (--user root), space-
        # separated; a "--opt=value" glued form is already just one word.
        if ($lit_fold eq 'sudo') {
            $i++;
            $progress = 1;
            while ($i < $n && defined $w[$i]{literal} && $w[$i]{literal} =~ /^-/) {
                my $opt = $w[$i]{literal};
                if ($opt =~ /^-[ugCDhprtU]$/) { $i += 2 }
                elsif ($opt =~ /^--(?:user|group|host|prompt|close-from|chdir|directory)$/) { $i += 2 }
                else { $i++ }
            }
            next;
        }
    }

    return (undef, undef, \@prefix_targets) unless $i < $n;
    my $name_word = $w[$i];
    my $consumed_next_for_name = 0;
    # redteam-2 M1: a redirect glued directly onto the COMMAND-NAME word
    # itself ("cat>f", "echo>f", "exec>f", "tee>f") is never found by the
    # prefix loop above (its lead text is non-empty, not a bare redirect),
    # and hyg_targets only scans argv -- so split it here: the literal
    # prefix becomes the real name word, and the redirect(s) become targets.
    if (defined $name_word->{raw}) {
        my $next_w = ($i + 1 < $n) ? $w[$i + 1] : undef;
        my ($targets, $lead, $consumed_next) = _hyg_redirect_targets_in_word($name_word->{raw}, $next_w);
        if (@$targets && length($lead)) {
            push @prefix_targets, @$targets;
            $name_word = _hyg_word_from_raw($lead);
            $consumed_next_for_name = $consumed_next;
        }
    }
    my @argv = @w[$i + 1 + $consumed_next_for_name .. $n - 1];
    return ($name_word, \@argv, \@prefix_targets);
}

sub _hyg_find_shellc_script {
    my ($argv) = @_;
    my $n = scalar @$argv;
    my $ci;
    # never-halt 09-gb-h-residuals sec 3.10 (r2-N7/review N3): walk argv in
    # ORDER and stop at the first predictable non-option word -- a "-c"
    # appearing AFTER the script operand (e.g. "bash x.sh -c cd") is never
    # bash's own -c, it's an argument to the script.
    for (my $idx = 0; $idx < $n; $idx++) {
        my $lit = $argv->[$idx]{literal};
        if (!defined $lit) { next }
        if ($lit eq '--') { last }
        if ($lit eq '-o' || $lit eq '+o' || $lit eq '-O' || $lit eq '+O'
            || $lit eq '--rcfile' || $lit eq '--init-file')
        {
            $idx++;
            next;
        }
        # never-halt 09-gb-h-residuals MUST-FIX 3 (reviewer M2): a clustered
        # short-option form ending in 'o'/'O' (e.g. "-eo", "-euo", "+xo")
        # ALSO takes an operand word, the same as a bare "-o"/"+o"/"-O"/"+O"
        # -- without this, "bash -eo pipefail -c 'cd x'" misreads "pipefail"
        # as the first predictable non-option word and never finds the real
        # "-c" script.
        if ($lit =~ /^[-+][a-zA-Z]*[oO]$/) {
            $idx++;
            next;
        }
        if ($lit =~ /^[-+]/) {
            if ($lit =~ /^-[a-zA-Z]*c[a-zA-Z]*$/) { $ci = $idx; last }
            next;
        }
        last; # first predictable non-option word: no -c beyond this point
    }
    return undef unless defined $ci;
    for my $idx ($ci + 1 .. $n - 1) {
        my $w = $argv->[$idx];
        my $lit = $w->{literal};
        next if defined $lit && $lit =~ /^-/;
        return $lit if defined $lit;
        my $raw = $w->{raw};
        return undef unless defined $raw;
        if ($raw =~ /^'(.*)'$/s) { return $1 }
        if ($raw =~ /^"(.*)"$/s) { return $1 }
        return $raw;
    }
    return undef;
}

sub _hyg_join_eval_words {
    my ($argv) = @_;
    return undef unless @$argv;
    my @parts;
    for my $w (@$argv) {
        if (defined $w->{literal}) { push @parts, $w->{literal} }
        else {
            my $raw = $w->{raw};
            return undef unless defined $raw;
            push @parts, _hyg_dequote($raw);
        }
    }
    return join(' ', @parts);
}

# Package 02, spec sec 2.2 "Targets": a one-entry, per-process cache shared
# between _gb_h and _gb_w, so a single Bash command is scanned by
# hyg_targets() at most once when both rules run for it. Keyed on a byte-
# equality check of the command text; never persisted across processes.
my $HYG_TARGETS_CACHE = { cmd => undef, targets => undef, deadline_at => undef };

sub _hyg_deadline_check {
    my ($deadline_at) = @_;
    return unless defined $deadline_at;
    die $HYG_DEADLINE_MARKER if Time::HiRes::time() > $deadline_at;
}

# _hyg_commands($text, $depth) -> list of [$name_word, @argv_words]. TEST
# SEAM (spec sec 2.1): called by its package name, never through a cached
# code ref. $deadline_at (redteam-3 M2, optional) is an absolute
# Time::HiRes::time() value; checked at each segment's loop boundary (never
# per character) and propagated into shell -c / eval recursion.
sub _hyg_commands {
    my ($text, $depth, $deadline_at) = @_;
    $depth = 0 unless defined $depth;
    return () if $depth > 3;
    return () unless defined $text;
    (my $t = $text) =~ s/\\\n//g;
    # redteam S4: rewrite an unquoted ">|" to a plain ">" BEFORE _segments
    # ever splits on the bare '|' it contains, or the clobber redirect's
    # target is torn into a separate "command" and lost.
    $t = _hyg_rewrite_clobber_redirect($t);
    my @segs = BpHook::_segments($t);
    my @out;
    for my $seg (@segs) {
        _hyg_deadline_check($deadline_at);
        next unless defined $seg && length $seg;
        my $words = BpHook::_tokenize_words($seg);
        next unless ref $words eq 'ARRAY' && @$words;
        my ($name_word, $argv, $prefix_targets) = _hyg_reduce($words);
        $argv           ||= [];
        $prefix_targets ||= [];
        next unless defined $name_word || @$argv || @$prefix_targets;
        push @out, { name => $name_word, argv => $argv, prefix_targets => $prefix_targets };

        my $name = _hyg_command_name($name_word);
        next unless defined $name;
        if ($name =~ /^(?:sh|bash|zsh|ksh|dash)$/) {
            my $script = _hyg_find_shellc_script($argv);
            push @out, _hyg_commands($script, $depth + 1, $deadline_at) if defined $script;
        }
        elsif ($name eq 'eval') {
            my $script = _hyg_join_eval_words($argv);
            push @out, _hyg_commands($script, $depth + 1, $deadline_at) if defined $script;
        }
    }
    return @out;
}

# hyg_targets($cmd, $deadline_at) -> list of \%t. Public: package 02 reuses
# this. $deadline_at (redteam-3 M2, optional) is threaded into _hyg_commands
# and re-checked once per command below.
sub hyg_targets {
    my ($cmd, $deadline_at) = @_;
    my @out;
    my @commands = _hyg_commands($cmd, 0, $deadline_at);
    for my $entry (@commands) {
        _hyg_deadline_check($deadline_at);
        next unless ref $entry eq 'HASH';
        push @out, @{ $entry->{prefix_targets} || [] };
        my @argv = @{ $entry->{argv} || [] };
        my ($operands, $redirects) = _hyg_scan_redirects(\@argv);
        push @out, @$redirects;

        my $name = _hyg_command_name($entry->{name});
        next unless defined $name;

        if ($name eq 'cd' || $name eq 'pushd') {
            push @out, { kind => 'cd', shape => $name, word => undef };
            next;
        }
        if ($name eq 'rm' || $name eq 'rmdir') {
            my ($pos, undef) = _hyg_positional($operands, {});
            push @out, map { { kind => 'delete', shape => $name, word => $_ } } @$pos;
            next;
        }
        if ($name eq 'mv') {
            my ($dest, $pos) = _hyg_mvcp_dest($operands);
            my @sources;
            if (!defined $dest && @$pos == 1) {
                # redteam-2 S8: "mv .git{,.bak}" (the standard backup idiom)
                # has only ONE positional, an unquoted brace list -- bash
                # expands it into BOTH the move source (before the comma)
                # and the destination (after it), so classify this single
                # word as both instead of only the write-shaped destination
                # heuristic below.
                my $braw = $pos->[0]{raw};
                if (defined $braw && $braw =~ /(?<!\\)\{[^{}]*,[^{}]*\}/) {
                    $dest = $pos->[0];
                    @sources = ($pos->[0]);
                }
            }
            if (!defined $dest && @$pos) {
                $dest = $pos->[-1];
                @sources = @$pos[0 .. $#$pos - 1];
            }
            elsif (defined $dest && !@sources) {
                @sources = @$pos;
            }
            push @out, { kind => 'write', shape => 'mv', word => $dest } if defined $dest;
            push @out, map { { kind => 'move', shape => 'mv', word => $_ } } @sources;
            next;
        }
        if ($name eq 'cp') {
            my ($dest, $pos) = _hyg_mvcp_dest($operands);
            $dest = $pos->[-1] if !defined $dest && @$pos;
            push @out, { kind => 'write', shape => 'cp', word => $dest } if defined $dest;
            next;
        }
        if ($name eq 'ln') {
            my ($dest, $pos) = _hyg_mvcp_dest($operands);
            if (!defined $dest && @$pos >= 2) { $dest = $pos->[-1] }
            push @out, { kind => 'write', shape => 'ln', word => $dest } if defined $dest;
            next;
        }
        if ($name eq 'touch') {
            # Decision 19 false denial: --reference FILE names a READ
            # source, never a write target.
            my ($pos, undef) = _hyg_positional($operands, { '-d' => 1, '-t' => 1, '-r' => 1, '--reference' => 1 });
            push @out, map { { kind => 'write', shape => 'touch', word => $_ } } @$pos;
            next;
        }
        if ($name eq 'mkdir') {
            my ($pos, undef) = _hyg_positional($operands, { '-m' => 1 });
            push @out, map { { kind => 'write', shape => 'mkdir', word => $_ } } @$pos;
            next;
        }
        if ($name eq 'tee') {
            my ($pos, undef) = _hyg_positional($operands, {});
            push @out, map { { kind => 'write', shape => 'tee', word => $_ } } @$pos;
            next;
        }
        if ($name eq 'truncate') {
            # Decision 19 false denial: --reference FILE is a read source.
            my ($pos, undef) = _hyg_positional($operands, { '-s' => 1, '-r' => 1, '--reference' => 1 });
            push @out, map { { kind => 'write', shape => 'truncate', word => $_ } } @$pos;
            next;
        }
        # never-halt 09-gb-h-residuals sec 3.11 (Decision 33): unlink, shred,
        # dd of=, sort -o and curl -o classifiers.
        if ($name eq 'unlink') {
            my ($pos, undef) = _hyg_positional($operands, {});
            push @out, map { { kind => 'delete', shape => 'unlink', word => $_ } } @$pos;
            next;
        }
        if ($name eq 'shred') {
            my $has_u = 0;
            for my $w (@$operands) {
                my $lit = $w->{literal};
                next unless defined $lit && $lit =~ /^-/;
                $has_u = 1 if $lit eq '-u' || $lit eq '--remove' || $lit =~ /^--remove=/;
                $has_u = 1 if $lit =~ /^-[fvxz]*u[fvxz]*$/;
            }
            my ($pos, undef) = _hyg_positional($operands,
                { '-n' => 1, '-s' => 1, '--iterations' => 1, '--size' => 1, '--random-source' => 1 });
            my $kind = $has_u ? 'delete' : 'write';
            push @out, map { { kind => $kind, shape => 'shred', word => $_ } } @$pos;
            next;
        }
        if ($name eq 'dd') {
            for my $w (@$operands) {
                my $lit = $w->{literal};
                next unless defined $lit && $lit =~ /^of=(.*)$/s;
                my $val = $1;
                next unless length $val;
                # never-halt 09-gb-h-residuals SHOULD-FIX 5 (reviewer S1):
                # $val is a plain substring of the whole "of=..." word's
                # already-resolved literal, so a leading "~" in it never got
                # the tokenizer's own word-START unpredictable treatment
                # (that only fires for a real word's first character --
                # here the first character of the WHOLE word is "o"). Without
                # this, "dd of=~/x" resolves against the repo root instead
                # of being recognised as $HOME/x, unlike every other
                # tilde-prefixed write target. Re-synthesize the same
                # {literal=>undef, raw=>...} shape the tokenizer gives a
                # genuine leading-"~" word, so _hyg_resolve's existing
                # "~"/"~/..." raw branches (and _hyg_home_alias) apply here
                # too.
                my $tword = ($val eq '~' || $val =~ m{^~/})
                    ? { literal => undef, raw => $val, tail => undef }
                    : { literal => $val, raw => $val, tail => undef };
                push @out, { kind => 'write', shape => 'dd of=', word => $tword };
            }
            next;
        }
        if ($name eq 'sort') {
            my @t_sort;
            my $dd = 0;
            my $nn = scalar @$operands;
            my $j = 0;
            while ($j < $nn) {
                my $w = $operands->[$j];
                my $lit = $w->{literal};
                if (!$dd && defined $lit && $lit eq '--') { $dd = 1; $j++; next }
                if (!$dd && defined $lit) {
                    if ($lit eq '-o' || $lit eq '--output') {
                        my $val = ($j + 1 < $nn) ? $operands->[$j + 1] : undef;
                        push @t_sort, $val if defined $val;
                        $j += 2;
                        next;
                    }
                    if ($lit =~ /^--output=(.*)$/s) {
                        my $v = $1;
                        push @t_sort, { literal => $v, raw => $v, tail => undef } if length $v;
                        $j++;
                        next;
                    }
                    if ($lit =~ /^-([bdfgiMhnRrcCsuVz]*)o(.*)$/s) {
                        my $rest = $2;
                        if (length $rest) {
                            push @t_sort, { literal => $rest, raw => $rest, tail => undef };
                            $j++;
                            next;
                        }
                        my $val = ($j + 1 < $nn) ? $operands->[$j + 1] : undef;
                        push @t_sort, $val if defined $val;
                        $j += 2;
                        next;
                    }
                    if ($lit eq '-k' || $lit eq '-t' || $lit eq '-S' || $lit eq '-T') { $j += 2; next }
                }
                $j++;
            }
            push @out, map { { kind => 'write', shape => 'sort -o', word => $_ } } @t_sort;
            next;
        }
        if ($name eq 'curl') {
            my @t_curl;
            my $dd = 0;
            my $nn = scalar @$operands;
            my $j = 0;
            while ($j < $nn) {
                my $w = $operands->[$j];
                my $lit = $w->{literal};
                if (!$dd && defined $lit && $lit eq '--') { $dd = 1; $j++; next }
                if (!$dd && defined $lit) {
                    if ($lit eq '-o' || $lit eq '--output') {
                        my $val = ($j + 1 < $nn) ? $operands->[$j + 1] : undef;
                        push @t_curl, $val if defined $val && !(defined $val->{literal} && $val->{literal} eq '-');
                        $j += 2;
                        next;
                    }
                    if ($lit =~ /^--output=(.*)$/s) {
                        my $v = $1;
                        push @t_curl, { literal => $v, raw => $v, tail => undef } if length($v) && $v ne '-';
                        $j++;
                        next;
                    }
                    if ($lit =~ /^-([sSLfkvIiNq#]*)o(.*)$/s) {
                        my $rest = $2;
                        if (length $rest) {
                            push @t_curl, { literal => $rest, raw => $rest, tail => undef } unless $rest eq '-';
                            $j++;
                            next;
                        }
                        my $val = ($j + 1 < $nn) ? $operands->[$j + 1] : undef;
                        push @t_curl, $val if defined $val && !(defined $val->{literal} && $val->{literal} eq '-');
                        $j += 2;
                        next;
                    }
                    if ($lit eq '-O') { $j++; next }
                }
                $j++;
            }
            push @out, map { { kind => 'write', shape => 'curl -o', word => $_ } } @t_curl;
            next;
        }
        if ($name eq 'sed') {
            my $has_i  = 0;
            my $has_ef = 0;
            for my $w (@$operands) {
                my $lit = $w->{literal};
                next unless defined $lit && $lit =~ /^-/;
                $has_i  = 1 if $lit =~ /^-[a-zA-Z]*i/ || $lit =~ /^--in-place/;
                $has_ef = 1 if $lit =~ /^(?:-e|-f|--expression|--file)$/ || $lit =~ /^--expression=/ || $lit =~ /^--file=/;
                # redteam M5: code glued directly onto -e/-f ("-e's/a/b/'")
                # still counts as inline code, not a separate script/file.
                # never-halt 09-gb-h-residuals sec 3.9 (r2-N2): widened to
                # "-[nrsuzE]*[ef].+" so an in-place suffix letter group
                # placed BEFORE the e/f ("-Ee's/a/b/'", "-ne's/a/b/p'") is
                # still recognised as glued code -- an "i" in that position
                # (e.g. "-ie ...") is still an in-place SUFFIX, not code.
                $has_ef = 1 if $lit =~ /^-[nrsuzE]*[ef].+/;
            }
            if ($has_i) {
                my ($pos, undef) = _hyg_positional($operands, { '-e' => 1, '-f' => 1, '-l' => 1 });
                my @files = @$pos;
                shift @files unless $has_ef;
                push @out, map { { kind => 'write', shape => 'sed -i', word => $_ } } @files;
            }
            next;
        }
        if ($name eq 'perl') {
            my $has_i    = 0;
            my $has_code = 0;
            my $j        = 0;
            my $m        = scalar @$operands;
            while ($j < $m) {
                my $lit = $operands->[$j]{literal};
                last unless defined $lit && $lit =~ /^-/;
                # redteam M5: -I/-M/-m take a value, either glued or as a
                # separate following word, and must not end the switch scan.
                if ($lit =~ /^-[IMm]/) {
                    $j++;
                    $j++ if $lit =~ /^-[IMm]$/ && $j < $m;
                    next;
                }
                $has_i = 1 if $lit =~ /^-[pnlaswWtT0-9]*i/;
                # code glued directly onto -e/-E ("-e's/a/b/'", "-es/a/b/")
                # consumes nothing else -- the code is already in this word.
                if ($lit =~ /^-[pnlaswWtTi0-9]*[eE].+/) {
                    $has_code = 1;
                    $j++;
                    next;
                }
                if ($lit eq '-e' || $lit eq '-E' || $lit =~ /^-[pnlaswWtTi0-9]*[eE]$/) {
                    $has_code = 1;
                    $j += 2;
                    next;
                }
                $j++;
            }
            if ($has_i) {
                my @after = @$operands[$j .. $m - 1];
                my ($pos, undef) = _hyg_positional(\@after, {});
                my @files = @$pos;
                shift @files unless $has_code;
                push @out, map { { kind => 'write', shape => 'perl -i', word => $_ } } @files;
            }
            next;
        }
    }
    return @out;
}

sub _hyg_c_lines {
    my ($shape, $shown, $cmd_line, $hint_ok) = @_;
    # reviewer S2/S4: build line 1 within budget HERE, keeping the path's
    # tail (the protected component that explains the deny), so Common::
    # fit()'s later front-truncation is a no-op and never throws it away.
    my $prefix = "BLOCKED: $shape of a protected path (.git, .ccpraxis-local-data, the repo root, the home dir, or a parent of one): ";
    my @lines = (
        _hyg_fit_tail($prefix, $shown, ''),
        'Instead: remove or move only the specific files you created inside it, by absolute path; never the directory itself.',
        $cmd_line,
    );
    push @lines, $HYG_HINT_TEXT if $hint_ok;
    return \@lines;
}

sub _hyg_protected_hit {
    my ($D, $ctx) = @_;
    return 0 unless defined $D;
    my $last = $D;
    $last =~ s{.*/}{};
    my $last_f = _hyg_fold_key($last);
    return 1 if $last_f eq '.git' || $last_f eq '.ccpraxis-local-data';

    my @ids = grep { defined } ($ctx->{R_id}, @{ $ctx->{home_ids} || [] });
    return 0 unless @ids;

    my $K = BpHook::Guards::Common::canon($D);
    $K = '' unless defined $K;
    $K = '/' if $K eq '';
    $K = _hyg_fold_key($K);

    # Decision 22 M3: the cheap lexical check first, against every
    # precomputed root -- "is R/home (fixed) at-or-under this TARGET".
    for my $id (@ids) {
        return 1 if $id->{K} eq $K;
        if (substr($K, -1) eq '/') { return 1 if index($id->{K}, $K) == 0 }
        else { return 1 if index($id->{K}, "$K/") == 0 }
    }

    # Stat-based fallback: an alias spelling (8.3, a different mount of the
    # same volume) that only an identity check can prove. ONE stat of the
    # TARGET here (not a repeated walk of R's/home's own fixed chain, which
    # was the report's 90s/25000-operand bottleneck -- that chain is already
    # precomputed once, in _hyg_root_identity via _hyg_ctx).
    my @sD = eval { stat($D) };
    return 0 unless @sD;
    my ($ddev, $dino) = ($sD[0], $sD[1]);
    if (_hyg_is_winfam() && $K =~ m{^[a-z]:/$} && $ddev) {
        for my $id (@ids) { return 1 if defined $id->{vdev} && $id->{vdev} == $ddev }
    }
    # review M3/S9: ino==0 skips the identity fallback entirely, mirrored
    # from _hyg_inside.
    return 0 unless $dino;
    for my $id (@ids) {
        return 1 if $id->{ids}{"$ddev:$dino"};
    }
    return 0;
}

# redteam-3 S2: is $remainder (the raw text from _hyg_glob_prefix_word's
# first unquoted glob/variable character onward) a glob that matches
# EVERYTHING in its directory -- so a bare "*" and a brace list still count,
# but so does "./*/" (a trailing slash stripped first) and "[!.]*"/"[^.]*"
# (a bracket that only negates ".", which still matches every other name).
# An ordinary partial glob like "*.tmp" must still fail this (Decision 4(d):
# a false denial costs more than the rare case).
sub _hyg_is_pure_match_all {
    my ($remainder) = @_;
    return 0 unless defined $remainder;
    (my $r = $remainder) =~ s{/+$}{};
    return 0 unless length $r;
    return 1 if $r =~ /^\.?[*?]+$/;
    return 1 if $r =~ /^\{.*\}$/;
    return 1 if $r =~ /^\.?(?:\[!?\.?\]|\[![^\]]*\]|[*?])+$/;
    return 0;
}

sub _hyg_check_c {
    my ($t, $ctx, $cmd_line, $hint_ok) = @_;
    my $w = $t->{word};
    return undef unless ref $w eq 'HASH';
    my $use_word = _hyg_home_alias($w, $ctx);
    $use_word = $w unless defined $use_word;

    my ($D, $K) = _hyg_resolve($use_word, $ctx->{cwd}, $ctx);
    if (defined $D) {
        return undef unless _hyg_protected_hit($D, $ctx);
        return _hyg_c_lines($t->{shape}, $D, $cmd_line, $hint_ok);
    }

    # Decision 19 RULING (4(c) vs 4(d)): the target is unresolvable as a
    # whole (an unquoted glob or variable in it), but its literal text --
    # before that glob/variable -- may still name a protected root or lie
    # directly inside one ("rm -rf .git/*"); the text check wins over 4(d)'s
    # unresolvable-target allowance.
    my ($prefix_word, $remainder) = _hyg_glob_prefix_word($use_word->{raw});
    my $is_pure = _hyg_is_pure_match_all($remainder);
    if (defined $prefix_word) {
        my ($PD, undef) = _hyg_resolve($prefix_word, $ctx->{cwd}, $ctx);
        if (defined $PD) {
            my $plast = $PD;
            $plast =~ s{.*/}{};
            my $plast_f = _hyg_fold_key($plast);
            if ($plast_f eq '.git' || $plast_f eq '.ccpraxis-local-data') {
                # redteam-2 S3: a .git/.ccpraxis-local-data prefix keeps
                # denying ANY glob remainder, per Decision 19's own examples
                # (.git/*, .ccpraxis-local-data/*).
                return _hyg_c_lines($t->{shape}, (defined $w->{raw} ? $w->{raw} : ''), $cmd_line, $hint_ok);
            }
            if (_hyg_protected_hit($PD, $ctx)) {
                # redteam-2 S3 (SHOULD, false denials): the repo root/home/an
                # ancestor of one denies only when the remainder is a PURE
                # match-all glob (*, .*, ?*, or a brace list) -- an ordinary
                # partial glob like "*.tmp" must still be allowed (Decision
                # 4(d): a false denial costs more than the rare case).
                return _hyg_c_lines($t->{shape}, (defined $w->{raw} ? $w->{raw} : ''), $cmd_line, $hint_ok)
                    if $is_pure;
            }
        }
    }
    elsif ($is_pure && defined $ctx->{cwd}) {
        # redteam-3 S2 (AC-51/AC-52): an EMPTY literal prefix -- the glob
        # starts at the word's very first character ("*", "[!.]*", "~{...}"
        # falls through here too via _hyg_home_alias above) -- is judged
        # against the cwd ITSELF, since that is where bash will expand it.
        # _hyg_protected_hit(D, ctx) already answers exactly "does D equal
        # or lie ABOVE R/home" (spec's contains(D, root)), which is the
        # right relation for "does deleting everything under cwd also take
        # out R or a home dir".
        my $cwdD = BpHook::Guards::Common::resolve_path($ctx->{cwd}, undef);
        if (defined $cwdD && _hyg_protected_hit($cwdD, $ctx)) {
            return _hyg_c_lines($t->{shape}, (defined $w->{raw} ? $w->{raw} : ''), $cmd_line, $hint_ok);
        }
    }

    # redteam S7: recompute the predictable basename after stripping a
    # trailing '/' or '/.' run, since the tokenizer's own 'tail' is undef
    # for those (and for a bare word with no cwd) even though the last
    # literal component is unambiguous.
    my $tail = _hyg_predictable_tail($use_word->{raw});
    $tail = $w->{tail} unless defined $tail;
    return undef unless defined $tail;
    my $tail_f = _hyg_fold_key($tail);
    return undef unless $tail_f eq '.git' || $tail_f eq '.ccpraxis-local-data';
    return _hyg_c_lines($t->{shape}, (defined $w->{raw} ? $w->{raw} : ''), $cmd_line, $hint_ok);
}

sub _hyg_check_b {
    my ($t, $ctx, $cmd_line, $hint_ok) = @_;
    my $w = $t->{word};
    return undef unless ref $w eq 'HASH';
    my ($D, $K) = _hyg_resolve($w, $ctx->{cwd}, $ctx);
    return undef unless defined $D;
    return undef if _hyg_never_target($D);

    # Decision 22 M3 (D19 SHOULD, "lexical before stat"): try every
    # candidate root's cheap STRING-ONLY containment test first, before any
    # of them is allowed to fall through to a stat-based ancestor walk of
    # the TARGET -- otherwise a target lexically inside TMP still pays R's
    # full stat walk first (redteam-2 M3 shape 3: touch under many deep TMP
    # paths, only one target actually outside the sandbox).
    return undef if _hyg_lexical_inside($K, $ctx->{R});
    for my $tmp (@{ $ctx->{tmp} }) {
        return undef if _hyg_lexical_inside($K, $tmp);
    }
    # Fallback: an alias spelling (8.3, a different mount of the same
    # volume) that only the full stat-based identity check can prove.
    return undef if _hyg_inside($D, $K, $ctx->{R});
    for my $tmp (@{ $ctx->{tmp} }) {
        return undef if _hyg_inside($D, $K, $tmp);
    }
    my $prefix = "BLOCKED: $t->{shape} writes outside the repo and the temp dir: ";
    my @lines = (
        _hyg_fit_tail($prefix, $D, ''),
        'Instead: write inside the repo or under the temp dir (TMP/TEMP, where the session scratchpad lives), by absolute path.',
        $cmd_line,
    );
    push @lines, $HYG_HINT_TEXT if $hint_ok;
    return \@lines;
}

# Decision 22 M3 RULING: replaces Decision 19's cap-abstain clause -- GB-h
# never abstains because of BP_GUARD_MAX_STRIP_BYTES (AC-21/AC-22 stand: a
# legitimate large command is still parsed and, if it triggers a real
# hygiene deny, denied). Instead a command over this size is denied outright
# with a remedy, before any of the expensive parsing below runs.
my $HYG_MAX_CMD_BYTES = 256 * 1024;

# redteam-2 S5: a quote-aware version of the old "tr/\\'\"//d" relaxed
# trigger fallback. Deleting every backslash was right for an UNQUOTED
# escape ("r\m" -> "rm", AC-19c) but wrong for a backslash that is a literal
# Windows path separator inside a quoted string ('C:\...\rm.exe') -- deleting
# THOSE glued the path into one run with no separator before the verb,
# hiding it from the trigger. Map backslash to '/' only where it is NOT
# acting as an escape (inside single quotes always; inside double quotes,
# only when it does not precede one of \$ ` " \\ or a newline); elsewhere
# (unquoted, or a real double-quote escape) consume it as bash itself would.
sub _hyg_relaxed_trigger_text {
    my ($cmd) = @_;
    return '' unless defined $cmd;
    my $len = length($cmd);
    my $out = '';
    my $q = 'none';
    my $i = 0;
    while ($i < $len) {
        my $c = substr($cmd, $i, 1);
        if ($q eq 'squote') {
            if ($c eq "'") { $q = 'none'; $i++; next }
            $out .= ($c eq '\\') ? '/' : $c;
            $i++;
            next;
        }
        if ($q eq 'dquote') {
            if ($c eq '"') { $q = 'none'; $i++; next }
            if ($c eq '\\' && $i + 1 < $len) {
                my $nc = substr($cmd, $i + 1, 1);
                if ($nc =~ /[\$"\\\n]/ || $nc eq "\x60") {
                    # redteam-3 S4: a REAL double-quote escape of a
                    # backslash ("\\" -> a single literal "\") is still a
                    # Windows path separator to the trigger regex, which
                    # only recognises "/" as a path separator -- map it to
                    # "/" here too (unlike the OTHER real escapes -- \$ \"
                    # \` \newline -- which stay as their literal char).
                    $out .= ($nc eq '\\') ? '/' : $nc;
                    $i += 2;
                    next;
                }
                $out .= '/';
                $i++;
                next;
            }
            $out .= $c;
            $i++;
            next;
        }
        if ($c eq "'") { $q = 'squote'; $i++; next }
        if ($c eq '"') { $q = 'dquote'; $i++; next }
        if ($c eq '\\' && $i + 1 < $len) { $out .= substr($cmd, $i + 1, 1); $i += 2; next }
        $out .= $c;
        $i++;
    }
    return $out;
}

# redteam-3 M2/S1: the shared over-size remedy, also reused (Decision 23) as
# the fail-closed message when the wall-clock deadline expires, and (S1)
# when BpHook's own stdin read was truncated.
sub _hyg_oversize_lines {
    my ($cmd, $hint_ok) = @_;
    my @lines = (
        'BLOCKED: this Bash command is over 256 KiB, too large to parse safely for the hygiene checks.',
        'Instead: write it to a script file in the repo or temp dir, then run that script file.',
        'Command: ' . BpHook::Guards::Common::echo_cmd($cmd),
    );
    push @lines, $HYG_HINT_TEXT if $hint_ok;
    return \@lines;
}

# Decision 26 (1): the pre-decode deny BpHook::main() calls when it has
# already seen (from the RAW bytes alone, before any JSON decode) that this
# Bash payload is over the raw-size cap or was truncated by its own stdin
# read. No decoded payload exists yet at this point (that is the whole
# point -- no decoder ever runs), so the command text is unknown and the
# same over-size remedy is used without a command echo or the driver-only
# hint (both need a decoded payload/role to compute safely).
sub deny_oversize_raw {
    my @fitted = map { BpHook::Guards::Common::fit($_) } @{ _hyg_oversize_lines(undef, 0) };
    return BpHook::deny(@fitted);
}

# redteam-3 M2 / Decision 24: GB-h's wall-clock deadline, in seconds from its
# own entry. BP_GUARD_DEADLINE_SECONDS may only LOWER it -- a value that
# isn't a positive number, or is above the 5s ceiling, is ignored -- so no
# environment can lengthen the scan past the hook's own timeout and turn a
# slow command into an allow.
my $HYG_DEADLINE_CEILING = 5;

sub _hyg_deadline_seconds {
    my $v = $ENV{BP_GUARD_DEADLINE_SECONDS};
    return $HYG_DEADLINE_CEILING unless defined $v && length $v;
    return $HYG_DEADLINE_CEILING unless $v =~ /^[0-9]+(?:\.[0-9]+)?$/;
    return $HYG_DEADLINE_CEILING if $v <= 0 || $v > $HYG_DEADLINE_CEILING;
    return $v + 0;
}

# never-halt 09-gb-h-residuals sec 2.2/3.1 (r4-S2): the deadline is measured
# from the HOOK PROCESS's own start (BpHook::started_at(), stamped as the
# first statement of BpHook::main()), not from this rule's own entry -- a
# slow decode under load must not hand GB-h/GB-w/_perl_test_run a fresh
# budget as if no time had passed. $cap (optional) additionally bounds how
# far past "now" the deadline may sit (used by _perl_test_run's own, lower,
# 2s budget) -- BP_GUARD_DEADLINE_SECONDS can only shrink either number,
# never lengthen the process-start-derived one.
sub _hyg_deadline_at {
    my ($cap) = @_;
    my $S   = _hyg_deadline_seconds();
    my $now = Time::HiRes::time();
    my $t0  = BpHook::started_at();
    my $pd  = (defined $t0 && $t0 <= $now) ? $t0 + $S : $now + $S;
    if (defined $cap) {
        my $capped = ($cap < $S) ? $cap : $S;
        my $want   = $now + $capped;
        return ($want < $pd) ? $want : $pd;
    }
    return $pd;
}

sub _gb_h_impl {
    my ($p, $cmd, $ti) = @_;
    # review S2: reset the cross-call cache as the FIRST statement of every
    # _gb_h_impl call, before any return -- a stale entry (e.g. one filled
    # under an already-expired deadline by a prior call in this process,
    # before GB-h itself failed open) must never be visible to _gb_w's hit
    # test. Only a fresh fill by THIS call's own hyg_targets() scan below may
    # populate it again.
    $HYG_TARGETS_CACHE = { cmd => undef, targets => undef, deadline_at => undef };
    # redteam-3 M2: work on a BYTE copy for the whole rest of this call --
    # see BpHook::_segments's comment for why a decoded non-ASCII string
    # makes every substr()/index() walk downstream quadratic.
    utf8::encode($cmd) if utf8::is_utf8($cmd);

    my ($mt, undef) = _match_text_and_reason($cmd);
    my $triggered = BpHook::Guards::Common::line_match($HYG_TRIGGER_RE, $mt);
    unless ($triggered) {
        # redteam M3: Shell::strip_noise blanks quoted/escaped spans (that's
        # right for GB-a/GB-c's git-verb matching), but it also blanks a
        # quoted or backslash-escaped COMMAND NAME ("\rm", '"rm"', "r\m",
        # "'r'm"), hiding it from the trigger even though hyg_targets (run
        # via the real tokenizer, which DOES dequote these) classifies it
        # correctly once we get there. Re-check a de-escaped/de-quoted copy
        # of the raw command as a fallback trigger; the real parse below
        # still respects quoting/escaping properly either way.
        my $relaxed = _hyg_relaxed_trigger_text($cmd);
        $triggered = BpHook::Guards::Common::line_match($HYG_TRIGGER_RE, $relaxed);
    }
    return undef unless $triggered;

    my $ledger    = $ENV{BP_LEDGER};
    my $is_ledger = defined $ledger && length $ledger;
    my $role      = BpHook::role($p);
    return undef unless $is_ledger || $role eq 'driver';

    my $hint_ok_early = (!$is_ledger && !defined BpHook::agent_id($p)) ? 1 : 0;

    # redteam-3 S1: a Bash call whose payload BpHook itself already knows was
    # truncated (its own 8 MiB stdin cap) is never trustworthy enough to
    # parse for real -- deny with the same remedy, instead of failing open
    # on a garbled/incomplete command.
    if (defined $ENV{BP_PAYLOAD_TRUNCATED} && $ENV{BP_PAYLOAD_TRUNCATED} eq '1') {
        return _hyg_oversize_lines($cmd, $hint_ok_early);
    }

    if (length($cmd) > $HYG_MAX_CMD_BYTES) {
        return _hyg_oversize_lines($cmd, $hint_ok_early);
    }

    my $pm = (ref $p eq 'HASH') ? $p->{permission_mode} : undef;
    my $bypass = (defined $pm && !ref($pm) && ($pm eq 'bypassPermissions' || $pm eq 'dontAsk')) ? 1 : 0;

    my $deadline_at = _hyg_deadline_at();
    # never-halt 09-gb-h-residuals sec 3.1: checked right after the deadline
    # is computed and before _hyg_ctx -- a process-start deadline that has
    # ALREADY expired (a slow decode under load) must deny a triggered
    # command at once, never spend more wall-clock computing context first.
    if (Time::HiRes::time() > $deadline_at) { return _hyg_oversize_lines($cmd, $hint_ok_early) }
    my $ctx         = _hyg_ctx($p);
    my $hint_ok     = (!$is_ledger && !defined BpHook::agent_id($p)) ? 1 : 0;
    my $cmd_line    = 'Command: ' . BpHook::Guards::Common::echo_cmd($cmd);

    # redteam-3 M2: the deadline is caught HERE, never by the outer _gb_h
    # eval (which fails OPEN on any die) -- a deadline must fail CLOSED.
    my @targets = eval { hyg_targets($cmd, $deadline_at) };
    if (my $err = $@) {
        return _hyg_oversize_lines($cmd, $hint_ok) if ref $err && $err == $HYG_DEADLINE_MARKER;
        die $err; # a real internal error: let the outer _gb_h eval fail open
    }
    # Package 02: cache this scan for _gb_w, which runs right after this rule
    # for the same command -- this must never change what _gb_h itself
    # verdicts, only save _gb_w a repeat hyg_targets() call.
    $HYG_TARGETS_CACHE = { cmd => $cmd, targets => \@targets, deadline_at => $deadline_at };

    for my $t (@targets) {
        if (Time::HiRes::time() > $deadline_at) { return _hyg_oversize_lines($cmd, $hint_ok) }
        next unless $t->{kind} eq 'delete' || $t->{kind} eq 'move';
        my $lines = _hyg_check_c($t, $ctx, $cmd_line, $hint_ok);
        return $lines if defined $lines;
    }

    unless ($bypass) {
        for my $t (@targets) {
            if (Time::HiRes::time() > $deadline_at) { return _hyg_oversize_lines($cmd, $hint_ok) }
            next unless $t->{kind} eq 'cd';
            my @lines = (
                "BLOCKED: $t->{shape} changes the working directory, which unattended runs never do (also inside chains, subshells and bash -c).",
                'Instead: stay where you are and use absolute paths, git -C <dir> <verb>, or the tool\'s own path argument.',
                $cmd_line,
            );
            push @lines, $HYG_HINT_TEXT if $hint_ok;
            return \@lines;
        }

        if (defined $ctx->{R}) {
            for my $t (@targets) {
                if (Time::HiRes::time() > $deadline_at) { return _hyg_oversize_lines($cmd, $hint_ok) }
                next unless $t->{kind} eq 'write' || $t->{kind} eq 'delete';
                my $lines = _hyg_check_b($t, $ctx, $cmd_line, $hint_ok);
                return $lines if defined $lines;
            }
        }
    }

    return undef;
}

sub _gb_h {
    my ($p, $cmd, $ti) = @_;
    my $lines = eval { _gb_h_impl($p, $cmd, $ti) };
    return undef if $@;
    return $lines;
}

# ---------------------------------------------------------------------------
# GB-w -- package 02 (spec 02-bash-write-set-spec.md sec 2.2). For a
# bound, write-capable subagent -- or, Decision 32's amendment to Q2, a
# coordinator context whose active-worker marker names a writer -- judges
# every resolvable in-repo write/delete/move target the same way
# WriteGuards' Edit guard would (BpHook::WriteGuards::may_write, the seam
# package 02 extracted). Runs after GB-h, so a protected-root or cd denial
# always wins first and GB-w never re-judges a target GB-h already denied.
# ---------------------------------------------------------------------------
sub _gb_w_require_writeguards {
    return 1 if grep { m{(?:^|/)WriteGuards\.pm$} } keys %INC;
    require "$SELF_DIR/../WriteGuards.pm";
    return 1;
}

# _gb_w_mkdir_ancestor_ok($R, $root, $D) -- Q3's mkdir allowance: true iff D
# (already known to be a denied mkdir target, lexically under root) is an
# ancestor of some write_set or test_paths pattern of a package in $R. A
# bare `mkdir -p` for a new file's directory would otherwise be a false
# denial Edit never has.
sub _gb_w_mkdir_ancestor_ok {
    my ($R, $root, $D) = @_;
    my $Rc = BpHook::Guards::Common::canon($root);
    my $Dc = BpHook::Guards::Common::canon($D);
    return 0 unless defined $Rc && length $Rc && defined $Dc && length $Dc;
    # never-halt 09-gb-h-residuals sec 3.12 (02-review N1): $ci is computed
    # FIRST, then used for both the equality and the prefix test below -- a
    # case-insensitive host must fold BOTH comparisons, not just the later
    # pattern match, or an upper-cased ancestor spelling never matches $Rc
    # at all and this returns 0 before $ci is even consulted. REL is still
    # taken from $Dc (the ORIGINAL-case string) by length, matching $Rc's.
    my $ci = eval { BpHook::WriteGuards::_is_ci() } ? 1 : 0;
    my ($Rc_cmp, $Dc_cmp) = $ci ? (lc($Rc), lc($Dc)) : ($Rc, $Dc);
    my $REL;
    if ($Dc_cmp eq $Rc_cmp)                    { $REL = '' }
    elsif (index($Dc_cmp, "$Rc_cmp/") == 0)    { $REL = substr($Dc, length($Rc) + 1) }
    else                                        { return 0 }
    return 0 unless length $REL;
    my $cand = $REL . '/';
    my $cand_m = $ci ? lc($cand) : $cand;
    for my $P (@{ $R->{packages} || [] }) {
        for my $field (qw(write_set test_paths)) {
            my $v = $P->{$field};
            next unless defined $v && length $v;
            for my $pat (split /:/, $v, -1) {
                next if $pat eq '';
                my $pat_m = $ci ? lc($pat) : $pat;
                return 1 if index($pat_m, $cand_m) == 0;
            }
        }
    }
    return 0;
}

my $GB_W_INSTEAD_LINE = 'Instead (Bash): put scratch output and mutation copies under the temp dir or '
                      . 'the session scratchpad; repo files outside your scope are not yours to change.';

sub _gb_w_impl {
    my ($p, $cmd, $ti) = @_;
    utf8::encode($cmd) if utf8::is_utf8($cmd);

    my ($mt, undef) = _match_text_and_reason($cmd);
    my $triggered = BpHook::Guards::Common::line_match($HYG_TRIGGER_RE, $mt);
    unless ($triggered) {
        my $relaxed = _hyg_relaxed_trigger_text($cmd);
        $triggered = BpHook::Guards::Common::line_match($HYG_TRIGGER_RE, $relaxed);
    }
    return undef unless $triggered;

    # review S4: WriteGuards::resolve() is expensive (inflight.json plus
    # every in-flight ledger's frontmatter) -- never require/run it for a
    # payload that cannot possibly become a confined context. Only a
    # coordinator context (BP_LEDGER set) or a driver-armed session (the
    # driver's own Bash calls, and every subagent it dispatches -- both
    # share the driver's armed session_id) can resolve() to anything but
    # undef; every other role (manual/unarmed/judge-without-ledger) always
    # would.
    my $ledger_env = $ENV{BP_LEDGER};
    my $could_resolve = (defined $ledger_env && length $ledger_env) ? 1 : 0;
    $could_resolve = 1 if !$could_resolve && eval { BpHook::role($p) eq 'driver' };
    return undef unless $could_resolve;

    _gb_w_require_writeguards();
    my $R = eval { BpHook::WriteGuards::resolve($p) };
    return undef unless ref $R eq 'HASH';

    # Decision 33 (consolidating review M2 / redteam M1): _gb_w applies
    # exactly when WriteGuards::resolve() yields a context in which the Edit
    # guard would confine this agent -- every bound subagent (whatever its
    # agent_type), and every coordinator context, with or without an
    # active-worker marker. Never a role-listed set of its own: Edit and
    # Bash can never disagree about a bound agent (Decision 32 Q2). Every
    # other resolve() kind (sole, refused, refused_bound, exempt_reports)
    # and driver mode (no agent binding, the driver's own main session)
    # abstain here, exactly as may_write's own allow_dirs/root logic would
    # leave them unconfined.
    my $scoped = 0;
    $scoped = 1 if $R->{mode} eq 'subagent' && defined($R->{kind}) && $R->{kind} eq 'bound';
    $scoped = 1 if $R->{mode} eq 'coordinator';
    return undef unless $scoped;

    my $root = $R->{root};
    return undef unless defined $root && length $root;

    my ($targets, $deadline_at);
    if (ref $HYG_TARGETS_CACHE eq 'HASH' && defined($HYG_TARGETS_CACHE->{cmd}) && $HYG_TARGETS_CACHE->{cmd} eq $cmd) {
        $targets     = $HYG_TARGETS_CACHE->{targets};
        $deadline_at = $HYG_TARGETS_CACHE->{deadline_at};
    }
    else {
        $deadline_at = _hyg_deadline_at();
        my @t = eval { hyg_targets($cmd, $deadline_at) };
        if (my $err = $@) {
            return _hyg_oversize_lines($cmd, 0) if ref $err && $err == $HYG_DEADLINE_MARKER;
            die $err; # a real internal error: the outer _gb_w eval fails open
        }
        $targets = \@t;
    }

    my $cwd;
    if (ref $p eq 'HASH' && defined $p->{cwd} && !ref($p->{cwd}) && length $p->{cwd}) {
        my $c = BpHook::_to_bytes($p->{cwd});
        $cwd = $c if _hyg_is_abs($c);
    }
    # spec sec 2.2 "Resolution context": a cd anywhere in the command makes
    # the payload cwd untrustworthy for a relative target later in the same
    # command -- clear it, exactly as GB-h's own bypass-mode cd handling
    # assumes, so a relative target after a cd is unresolvable rather than
    # judged against the wrong directory.
    if (grep { ref($_) eq 'HASH' && defined($_->{kind}) && $_->{kind} eq 'cd' } @$targets) {
        $cwd = undef;
    }

    my $home1;
    for my $v ($ENV{HOME}, $ENV{USERPROFILE}) {
        next unless defined $v && length $v;
        my $b = BpHook::_to_bytes($v);
        if (_hyg_is_abs($b)) { $home1 = $b; last }
    }
    my $rctx = { home1 => $home1 };
    my ($rootD, $rootK) = _hyg_root_dk($root);

    my %judged_ok;
    for my $t (@$targets) {
        if (Time::HiRes::time() > $deadline_at) { return _hyg_oversize_lines($cmd, 0) }
        next unless $t->{kind} eq 'write' || $t->{kind} eq 'delete' || $t->{kind} eq 'move';

        my ($D, $K) = _hyg_resolve($t->{word}, $cwd, $rctx);
        next unless defined $D; # unresolvable target: allowed through (Decision 4(d))

        next if _hyg_never_target($D);

        # Repo scope: only a target statically inside WriteGuards' own root
        # is judged here -- temp, the scratchpad and home lie outside it.
        # review S3: decided LEXICALLY only, no per-target stat walk -- a
        # target that is not a lexical descendant of root is never a repo
        # write GB-w need judge (Decision 22 M3).
        next unless _hyg_lexical_inside($K, $root);
        next if defined($rootK) && $K eq $rootK; # the root itself is GB-h (c)'s concern

        next if $judged_ok{$K};

        my $v = BpHook::WriteGuards::may_write($R, $D, $p);
        if ($v->{allow}) { $judged_ok{$K} = 1; next }

        # review M1: the mkdir allowance is a verdict about THIS shape only
        # (an ancestor-of-scope mkdir), never a fact about the path itself --
        # memoising it as $judged_ok{$K} let a later rm/mv of the same path
        # ride the memo through. Never mark $K allowed here.
        if ($t->{shape} eq 'mkdir' && _gb_w_mkdir_ancestor_ok($R, $root, $D)) {
            next;
        }

        my @lines = @{ $v->{lines} || [] };
        # Decision 33/S1: the sec 2.3 "Instead (Bash)" + Command remedy is
        # relocation advice -- it only fits a write-set-scope denial (the
        # file is fine, just outside this package's scope; move the write).
        # Every other may_write denial (test-modify, writer-scope, sibling
        # ledger, 8.3, root-scope, refused/bound) already carries its own
        # correct remedy, and for those Bash must match Edit's lines
        # byte-for-byte -- appending relocation advice there would be wrong
        # (a protected test file is not "yours to relocate") and is what
        # broke AC-14/S1's Edit-parity check.
        if (grep { m/is outside (?:this package's write set|the write set of every package in flight)/ } @lines) {
            push @lines, $GB_W_INSTEAD_LINE;
            push @lines, 'Command: ' . BpHook::Guards::Common::echo_cmd($cmd);
        }
        return \@lines;
    }

    return undef;
}

sub _gb_w {
    my ($p, $cmd, $ti) = @_;
    my $lines = eval { _gb_w_impl($p, $cmd, $ti) };
    return undef if $@;
    return $lines;
}

# ---------------------------------------------------------------------------
# run($p, @args) -> 0 | 2.
# ---------------------------------------------------------------------------
# Decision 25 (2): a Bash payload whose raw size (BEFORE any decode) exceeds
# 1 MiB is denied outright with the existing over-size remedy. A real
# BpHook truncation only ever happens at 8 MiB (_read_stdin_bulk's own cap),
# always over this 1 MiB threshold, so the truncated-payload case below is
# folded into the same cap rather than treated as a separate size.
my $HYG_RAW_CAP_BYTES = 1024 * 1024;

sub run {
    my ($p, @args) = @_;
    # redteam-3 S1 / Decision 25 (2): when BpHook's own stdin read was
    # truncated (its 8 MiB cap), BpHook::load_payload() discards the decoded
    # payload entirely (payload() returns {}) -- so $p carries no
    # tool_name/tool_input, and no session_id, by the time it gets here;
    # every check below would otherwise fail OPEN on what looks like "not a
    # Bash call". Decision 25 supersedes the old non-ledger-only scoping
    # (guards-remake-bash.t's SH-7, amended): a truncated payload is denied
    # in EVERY role, including a coordinator, because truncation only ever
    # happens at 8 MiB -- always over the 1 MiB raw-size cap this same
    # ruling adds below.
    if (defined $ENV{BP_PAYLOAD_TRUNCATED} && $ENV{BP_PAYLOAD_TRUNCATED} eq '1') {
        my $cmd_for_msg = (ref $p eq 'HASH' && ref $p->{tool_input} eq 'HASH') ? $p->{tool_input}{command} : undef;
        my @fitted = map { BpHook::Guards::Common::fit($_) } @{ _hyg_oversize_lines($cmd_for_msg, 0) };
        return BpHook::deny(@fitted);
    }
    $p = {} unless ref $p eq 'HASH';
    return 0 unless defined $p->{tool_name} && $p->{tool_name} eq 'Bash';
    my $ti = $p->{tool_input};
    return 0 unless ref $ti eq 'HASH';
    my $cmd = $ti->{command};
    return 0 unless defined $cmd && !ref($cmd) && length $cmd;

    # Decision 25 (2): the raw-size deny itself, scoped to a Bash call (never
    # Edit/Write/other guards -- BpHook::raw_length() is payload-wide, but
    # only THIS guard, having already confirmed tool_name eq 'Bash' above,
    # acts on it), in every role, before any of the real parsing below.
    my $raw_len = BpHook::raw_length();
    if (defined $raw_len && $raw_len > $HYG_RAW_CAP_BYTES) {
        my @fitted = map { BpHook::Guards::Common::fit($_) } @{ _hyg_oversize_lines($cmd, 0) };
        return BpHook::deny(@fitted);
    }

    for my $rule (\&_gb_a, \&_gb_b, \&_gb_c, \&_gb_h, \&_gb_w, \&_gb_d) {
        my $lines = eval { $rule->($p, $cmd, $ti) };
        if (defined $lines) {
            my @fitted = map { BpHook::Guards::Common::fit($_) } @$lines;
            return BpHook::deny(@fitted);
        }
    }
    return 0;
}

1;
