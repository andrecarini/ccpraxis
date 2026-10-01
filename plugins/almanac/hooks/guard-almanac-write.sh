#!/usr/bin/env bash
# guard-almanac-write.sh — every almanac-owned store is script-owned.
#
# TWO THINGS THIS HOOK PROTECTS, BY PATH SHAPE, NOT BY AN ENUMERATED LIST:
#
#   1. bug reports          <project>/.ccpraxis-local-data/bug-reports/<id>.md
#   2. almanac record stores <project>/.ccpraxis-local-data/almanac/<type>/...
#                             <home>/.claude/claude-code-vault/almanac/<type>/...
#
# Both have a state machine or a compare-and-swap lock that a direct Edit/Write
# would bypass outright, so this denies Edit/Write/MultiEdit/NotebookEdit
# against either shape and points at the script that owns it instead. Bug
# reports freeze once picked up (open -> triaging -> taken -> resolved |
# declined); stores are protected by Almanac::Lock plus a sealed digest, and
# almanac-bug.pl verify reports either kind of out-of-band write.
#
# Bash is covered too (package 13): the same classifier judges write/delete/
# move/copy targets parsed out of a raw shell command (redirects, sed -i,
# perl -i, tee, mv, cp, ln, rm, rmdir, truncate, touch, an interpreter
# one-liner) using butler's BpHook::Guards::GuardBash::hyg_targets, loaded by
# an eval-require from the sibling plugin directory. See hooks.json's "Bash"
# matcher entry.
#
# NOT bp_hook_gate'd, deliberately. That helper requires BP_LEDGER/BP_DIR/
# BP_PROJECT_ROOT, which only bp-launch.sh exports — so a gated hook is inert
# in exactly the sessions that hit this most: an ordinary agent working in
# some unrelated project. Shipped via this plugin's hooks.json rather than a
# host settings file, so any project with almanac enabled gets it.
#
# Reading is untouched. Fails OPEN on anything unexpected — empty/broken
# input, a payload with no path, a perl that dies at startup — because a
# guard that wedges an unrelated project's session is worse than an
# unguarded edit; the sealed digest (almanac-bug.pl verify) still detects the
# out-of-band write regardless. That layer does not depend on prevention.
# The Bash branch fails open the same way, including when butler is absent
# or GuardBash's public interface changes shape (sec 2.6 of the spec).
#
# COST DISCIPLINE (DC6, budget 50ms median). Every Edit/Write in every
# session pays for this hook, so it is built in two stages: a bash-only
# prefilter that spawns NOTHING (no cat, no perl, no jq) for the overwhelming
# majority of edits that touch neither root, and a single perl process (core
# JSON::PP only) for the rest. harness-facts (g) measured a bash spawn at
# ~30.6ms and one perl parse at a further ~46-47ms — paying the perl cost on
# every call would blow the budget outright, which is why the prefilter must
# complete with no process spawned at all. For Bash, a narrower stage 1b
# (builtins only) also skips the perl spawn when the command and cwd carry
# no marker even though some other field of the payload (transcript_path,
# description) does.
#
# FIX-BATCH (post-review 09): the perl->bash field separator is \x1f, not a
# tab -- tab is IFS *whitespace*, so `IFS=$'\t' read` collapsed empty fields
# (every bug denial's TYPE is empty) and shifted every field after it. \x1f
# is never IFS whitespace, so an empty field stays a real, distinct field.
# The classifier is also segment-based now (not one big regex against the
# joined path), so it can: (a) resolve a relative path against the payload's
# own `cwd` before classifying; (b) strip a Windows trailing dot/space from
# any non-`.`/`..` segment, matching what CreateFileW itself does; (c) treat
# an 8.3 short-name segment (`CCPRAX~1`) as equal to the long literal it is
# a legal abbreviation of, using the same basis test
# BpHook::WriteGuards::_seg_eq_base uses (first up-to-6 alphanumerics of the
# long name, folded) -- no filesystem access, so this holds even for a path
# that is never opened.
set -u

# Stage 0: read the payload with a bash BUILTIN — no cat, no $(...), no pipe,
# no external command. -N is the buffered form, required on a non-tty. Any
# read status (timeout, short read, EOF) is tolerated; an empty payload just
# fails open below.
IFS= read -r -N 8388608 -t 10 P
[ -n "${P:-}" ] || exit 0

# Stage 1: the prefilter. A case-insensitive bash builtin match for either
# root's literal substring, OR the 8.3 short-name PREFIX either store
# segment can shorten to (S2, post-review 09 -- corrected). `.ccpraxis-local-
# data` -> `CCPRAX~n`, `claude-code-vault` -> `CLAUDE~n` (Windows 8.3 names
# take the first up-to-6 alphanumerics of the long name, then `~`, then a
# digit). A bare `~` was tried first and rejected: ANDR~1 (the shortened
# form of this very host's own username) is itself `~digit`, and it sits in
# the path of every session scratchpad and %TEMP% file, so that trigger
# spawned perl on ordinary, harmless paths and lost the zero-spawn-on-a-miss
# property for a common case. A short name on some OTHER ancestor segment
# (ANDR~1 on the way to a claude-code-vault that is spelled out in full)
# still matches via the plain literal substring above -- only the STORE
# segment's OWN shortening needs its own trigger. None present -> exit 0, no
# process spawned.
# FIX-BATCH (post red-team 13, B1): a glob (`.ccpraxis-*`), a quote split
# mid-literal (`".ccpraxis-local-"data`) or an escaped separator
# (`local\-data`) all defeat the two root literals above while leaving the
# STORE LEAF NAME (`bug-reports`, `almanac`) fully intact -- every bypass
# demonstrated in the red-team report still contains one of those leaf
# names verbatim. Widen the trigger to them too. This only ever adds perl
# spawns (never removes a deny) and stays zero-spawn for an unrelated
# command (AC15: `git status` matches none of these).
shopt -s nocasematch
# FIX-BATCH (post review-2 MF2 / red-team-2 B1): the strip must run BEFORE
# the match, not only in Stage 1b below -- a quote-split or backslash-
# escaped separator that defeats the ROOT literal (`.ccpraxis-local-"data`,
# `local\-data`) still has the leaf name intact in the raw text, but a
# double quote-split that breaks the LEAF too (`"bug-"reports`) needs the
# stripped copy tested as well. Matching only `$P` left the strip at :122
# dead code for Stage 1's own purposes, since Stage 1 already exited above
# it on a miss. Builtins only; can only add perl spawns, never remove a deny.
case "$P${P//[\'\"\\]/}" in
  *ccpraxis-local-data*|*claude-code-vault*|*'ccprax~'*|*'claude~'*|*bug-reports*|*almanac*|*code-vault*) ;;
  *) exit 0 ;;
esac

# Stage 1b (Bash only, builtins only, spawns nothing). Narrows the trigger
# to the two fields that can actually name a write target -- tool_input.
# command and the payload's top-level cwd -- so a Bash call whose
# transcript_path or description merely MENTIONS a marker, with neither the
# command nor the cwd touching a store, still spawns no perl. Conservative
# by construction: if the command extraction fails for any reason, fall
# through to stage 2 instead of guessing.
RE_TOOL_IS_BASH='"tool_name"[[:space:]]*:[[:space:]]*"Bash"'
RE_JSON_STR_COMMAND='"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
RE_JSON_STR_CWD='"cwd"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
if [[ $P =~ $RE_TOOL_IS_BASH ]]; then
  if [[ $P =~ $RE_JSON_STR_COMMAND ]]; then
    CMD1B=${BASH_REMATCH[1]}
    CWD1B=""
    if [[ $P =~ $RE_JSON_STR_CWD ]]; then
      CWD1B=${BASH_REMATCH[1]}
    fi
    COMBINED1B="$CMD1B$CWD1B"
    # S5/B1: a quote injected mid-literal (`.ccpraxis-local-"data"`) or a
    # backslash before a path separator defeats a literal substring match
    # even though the two would be the SAME path once the shell strips
    # them. Also test a quote/backslash-stripped copy, builtins only.
    STRIPPED1B=${COMBINED1B//[\'\"\\]/}
    case "$COMBINED1B$STRIPPED1B" in
      *ccpraxis-local-data*|*claude-code-vault*|*'ccprax~'*|*'claude~'*|*bug-reports*|*almanac*|*code-vault*) ;;
      *) exit 0 ;;
    esac
  fi
fi

# The hook's own directory, computed with builtins only (no dirname). Passed
# to perl as argv[0] so the Bash path can eval-require GuardBash.pm from the
# sibling butler plugin without depending on $0 or CLAUDE_PLUGIN_ROOT (which
# is only set by Claude Code itself, not by this file's own test harness).
case "${BASH_SOURCE[0]}" in
  */*) HOOKDIR="${BASH_SOURCE[0]%/*}" ;;
  *)   HOOKDIR="." ;;
esac

# Stage 2: the slow path. One perl process, core JSON::PP (+ Time::HiRes for
# GuardBash's deadline) only. It prints exactly one line, "DENY<0x1f>...", on
# a match, and nothing otherwise — including on a decode failure, an
# unrecognised tool, an empty path, or a perl that fails to start at all (a
# broken PERL5OPT). Its stderr is discarded; a crash here must never look
# like a deny.
OUT=$(printf "%s" "$P" | perl -MJSON::PP -MTime::HiRes -e '
    local $/;
    my $raw = <STDIN>;
    my $j = eval { JSON::PP->new->decode($raw) };
    exit 0 unless $j;
    my $t = $j->{tool_name} // "";
    my $hookdir = defined $ARGV[0] ? $ARGV[0] : ".";

    # normalize_segments($raw_path) -> ($drive, $prefix, @segments)
    #
    # \ -> /; a run of / collapses to one, except a leading // which is kept
    # as //; ./ segments vanish; a trailing dot/space run on any segment
    # OTHER than "." or ".." is stripped first (S1 -- what CreateFileW does,
    # so the guard sees the same name the filesystem will); ../ segments are
    # then resolved lexically against whatever real segment precedes them.
    sub normalize_segments {
        my ($raw_p) = @_;
        (my $q = $raw_p) =~ s{\\}{/}g;
        my $lead2 = ($q =~ m{^//}) ? 1 : 0;
        my $drive = "";
        if ($q =~ s{^([A-Za-z]:)}{}) { $drive = $1; }
        my $rooted = ($q =~ m{^/}) ? 1 : 0;
        (my $body = $q) =~ s{^/+}{};
        $body =~ s{/+}{/}g;
        my @raw_parts = split(m{/}, $body);
        my @out;
        for my $seg (@raw_parts) {
            next if $seg eq "";
            if ($seg ne "." && $seg ne "..") {
                $seg =~ s/[. ]+\z//;
                next if $seg eq "";
            }
            if ($seg eq ".") {
                next;
            } elsif ($seg eq "..") {
                if (@out && $out[-1] ne "..") { pop @out } else { push @out, $seg }
            } else {
                push @out, $seg;
            }
        }
        my $prefix = $lead2 ? "//" : ($rooted ? "/" : "");
        return ($drive, $prefix, @out);
    }

    # seg_match($segment, $literal_target) -> 0|1 -- exact (case-insensitive)
    # match, OR an 8.3 short-name basis match (S2): a short segment matches
    # iff its stem (before ~N) equals the first up-to-6 alphanumeric
    # characters of the target, both folded and stripped of everything else.
    # Pure string comparison -- no filesystem access, so this holds for a
    # path that is never opened.
    sub seg_match {
        my ($seg, $target) = @_;
        return 0 unless defined $seg && defined $target;
        return 1 if lc($seg) eq lc($target);
        if ($seg =~ /^[^~\/]{1,6}~[0-9]+(?:\.[^.\/]{0,3})?\z/) {
            (my $stem = $seg) =~ s/~.*\z//s;
            my $stem_f = lc($stem);  $stem_f  =~ s/[^a-z0-9]//g;
            my $basis_f = lc($target); $basis_f =~ s/[^a-z0-9]//g;
            my $want = (length($basis_f) >= 6) ? substr($basis_f, 0, 6) : $basis_f;
            return (length($stem_f) && $stem_f eq $want) ? 1 : 0;
        }
        return 0;
    }

    # seg_glob_match($segment, $literal_target) -> 0|1 (spec 2.3, "Segment
    # matching"). Only used for UNRESOLVABLE (raw) text: a segment containing
    # an unescaped *, ?, [ or a one-level {a,b,...} brace list matches the
    # target iff the pattern (converted case-insensitively) matches the
    # whole target, and the pattern does not begin with */?/[ when the
    # target begins with "." (bash does not glob a leading dot).
    sub glob_to_regex {
        my ($g) = @_;
        my $out = "";
        my $i = 0;
        my $len = length($g);
        while ($i < $len) {
            my $c = substr($g, $i, 1);
            if ($c eq "\\" && $i + 1 < $len) { $out .= quotemeta(substr($g, $i + 1, 1)); $i += 2; next; }
            if ($c eq "*") { $out .= "[^/]*"; $i++; next; }
            if ($c eq "?") { $out .= "[^/]"; $i++; next; }
            if ($c eq "[") {
                my $close = index($g, "]", $i + 1);
                if ($close >= 0) { $out .= substr($g, $i, $close - $i + 1); $i = $close + 1; next; }
                $out .= quotemeta($c); $i++; next;
            }
            if ($c eq "{") {
                my $close = index($g, "}", $i + 1);
                if ($close >= 0) {
                    my $inner = substr($g, $i + 1, $close - $i - 1);
                    if ($inner =~ /,/ && $inner !~ /[{}]/) {
                        my @alts = split /,/, $inner, -1;
                        $out .= "(?:" . join("|", map { quotemeta($_) } @alts) . ")";
                        $i = $close + 1; next;
                    }
                }
                $out .= quotemeta($c); $i++; next;
            }
            $out .= quotemeta($c); $i++;
        }
        return $out;
    }
    sub seg_glob_match {
        my ($seg, $target) = @_;
        return 0 unless defined $seg && defined $target;
        return 0 unless $seg =~ /(?<!\\)[*?\[]/ || $seg =~ /(?<!\\)\{[^{}]*,[^{}]*\}/;
        return 0 if $target =~ /^\./ && $seg =~ /^[*?\[]/;
        my $pat = glob_to_regex($seg);
        return 0 unless length $pat;
        return ($target =~ /^(?:$pat)\z/i) ? 1 : 0;
    }

    # seg_match_u($segment, $target, $allow_glob) -- exact/8.3 match, OR (when
    # $allow_glob) a glob/brace pattern match. $allow_glob is set only for
    # UNRESOLVABLE (raw) target text (spec 2.3).
    sub seg_match_u {
        my ($seg, $target, $allow_glob) = @_;
        return 1 if seg_match($seg, $target);
        return $allow_glob ? seg_glob_match($seg, $target) : 0;
    }

    sub match_seq_u {
        my ($allow_glob, $segs, $i, @targets) = @_;
        for my $k (0 .. $#targets) {
            return 0 unless defined $segs->[$i + $k];
            return 0 unless seg_match_u($segs->[$i + $k], $targets[$k], $allow_glob);
        }
        return 1;
    }

    sub match_seq {
        my ($segs, $i, @targets) = @_;
        return match_seq_u(0, $segs, $i, @targets);
    }

    # path_has_store_prefix(\@segs, $allow_glob) -> 0|1. The SAME
    # distinguishing path-context test Rule A of classify_segments() uses
    # (a full store-root SEQUENCE -- ".ccpraxis-local-data"+"bug-reports",
    # ".ccpraxis-local-data"+"almanac", or ".claude"+"claude-code-vault"+
    # "almanac" -- appearing together, in order, anywhere in the segments),
    # but without Rule A requiring a "followed by >=1 more segment", so it
    # also matches when the sequence IS the whole path (a bare cd to a store
    # root). FB14 (Decision 43 over-deny fix): this replaces a bare
    # leaf-name-anywhere test that wrongly matched "plugins/almanac" or
    # "~/.claude" + "almanac-notes.md" just because one segment happened to
    # share a word with a store name -- the full sequence is the only thing
    # that actually identifies a protected store.
    sub path_has_store_prefix {
        my ($segs, $allow_glob) = @_;
        my $n = scalar @$segs;
        for my $i (0 .. $n - 1) {
            last if $i + 2 > $n;
            return 1 if match_seq_u($allow_glob, $segs, $i, ".ccpraxis-local-data", "bug-reports");
            return 1 if match_seq_u($allow_glob, $segs, $i, ".ccpraxis-local-data", "almanac");
        }
        for my $i (0 .. $n - 1) {
            last if $i + 3 > $n;
            return 1 if match_seq_u($allow_glob, $segs, $i, ".claude", "claude-code-vault", "almanac");
        }
        return 0;
    }

    # classify_segments(\@segs, $allow_glob, $entry_kind, $entry_shape)
    #   -> ($kind, $rule, $rest_start) | ()
    # Rules A/B/C of spec 2.3, shared by the Edit path (allow_glob=0, no
    # entry kind/shape gating since every Edit target is judged) and the
    # Bash path.
    sub classify_segments {
        my ($segs, $allow_glob, $entry_kind, $entry_shape) = @_;
        my $n = scalar @$segs;
        # Rule A: a store-root sequence anywhere, followed by >=1 more segment.
        for my $i (0 .. $n - 1) {
            last if $i + 2 > $n - 1;
            if (match_seq_u($allow_glob, $segs, $i, ".ccpraxis-local-data", "bug-reports")) {
                return ("bug", "A", $i + 2);
            }
        }
        for my $i (0 .. $n - 1) {
            last if $i + 2 > $n - 1;
            if (match_seq_u($allow_glob, $segs, $i, ".ccpraxis-local-data", "almanac")) {
                return ("store", "A", $i + 2);
            }
        }
        for my $i (0 .. $n - 1) {
            last if $i + 3 > $n - 1;
            if (match_seq_u($allow_glob, $segs, $i, ".claude", "claude-code-vault", "almanac")) {
                return ("store", "A", $i + 3);
            }
        }
        # Rule B: the text IS a store root (ends exactly with the sequence).
        my $b_eligible = defined($entry_kind)
            && ( $entry_kind eq "delete" || $entry_kind eq "move"
                 || ($entry_kind eq "write" && defined($entry_shape) && $entry_shape =~ /^(?:mv|cp|ln)\z/) );
        if ($b_eligible) {
            if ($n >= 2 && match_seq_u($allow_glob, $segs, $n - 2, ".ccpraxis-local-data", "bug-reports")) {
                return ("bug", "B", $n);
            }
            if ($n >= 2 && match_seq_u($allow_glob, $segs, $n - 2, ".ccpraxis-local-data", "almanac")) {
                return ("store", "B", $n);
            }
            if ($n >= 3 && match_seq_u($allow_glob, $segs, $n - 3, ".claude", "claude-code-vault", "almanac")) {
                return ("store", "B", $n);
            }
        }
        # Rule C: the text IS a container (ends exactly with it); delete/move only.
        if (defined($entry_kind) && ($entry_kind eq "delete" || $entry_kind eq "move")) {
            if ($n >= 1 && seg_match_u($segs->[$n - 1], ".ccpraxis-local-data", $allow_glob)) {
                return ("root", "C", $n);
            }
            if ($n >= 2 && seg_match_u($segs->[$n - 2], ".claude", $allow_glob)
                        && seg_match_u($segs->[$n - 1], "claude-code-vault", $allow_glob)) {
                return ("root", "C", $n);
            }
        }
        return ();
    }

    # ==========================================================================
    # FIX-BATCH (3rd pass, architectural): shared helpers used by the cd-
    # target extractor, the cwd-persistence join, and the cp/mv/ln scope
    # check below -- all three now go through this ONE quote-aware tokenizer
    # (tokenize_simple, defined further down next to the interpreter rule it
    # was built for) instead of each running its own raw-text regex. Defined
    # here because Perl subs are visible throughout the enclosing block
    # regardless of textual order; tokenize_simple itself is still defined
    # near Rule I since that is where it originated.
    # ==========================================================================

    # _norm_cmp($s) -> a comparison-only normal form: backslash -> slash,
    # quote characters removed, one trailing slash run removed, folded.
    # Never used for the DENY path displayed/classified path -- only to
    # decide "is this the same word" between two independently-captured
    # strings (a GuardBash word vs. a token this file re-tokenized itself).
    sub _norm_cmp {
        my ($s) = @_;
        return "" unless defined $s;
        (my $t = $s) =~ s{\\}{/}g;
        $t =~ tr/\x27"//d;
        $t =~ s{/+\z}{} unless $t eq "/";
        return lc($t);
    }

    # find_simple_segments($toks, $pos, $text) -> list of { s, e, text },
    # splitting a tokenize_simple() stream into simple-command segments on
    # any of the boundary tokens it already emits as single-char tokens
    # (; & | ( ) `). Shared by the cd-target extractor and the cp/mv/ln
    # scope check so both see "one simple command" the same way.
    sub find_simple_segments {
        my ($toks, $pos, $text) = @_;
        my @segs;
        my $n = scalar @$toks;
        my $start = 0;
        for (my $i = 0; $i <= $n; $i++) {
            my $is_boundary = ($i == $n) || ($toks->[$i] =~ /^[;&|()\x60\n]\z/);
            if ($is_boundary) {
                if ($i > $start) {
                    my $s_char = $pos->[$start];
                    my $e_char = $pos->[$i - 1] + length($toks->[$i - 1]);
                    push @segs, { s => $start, e => $i - 1, text => substr($text, $s_char, $e_char - $s_char) };
                }
                $start = $i + 1;
            }
        }
        return @segs;
    }

    # cd_target_is_marker($raw_target) -> 0|1. Tests a cd/pushd TARGET
    # (quotes/backslashes still attached, exactly as captured from the
    # token stream) the same way the write-target classifier judges a real
    # write target: strip quotes, segment it (normalize_segments turns a
    # backslash into a path separator), and run path_has_store_prefix() --
    # the SAME full-sequence test classify_segments() Rule A uses -- with
    # glob tolerance. FB14 (Decision 43): this is deliberately NOT a bare
    # leaf-name-anywhere test; "plugins/almanac" or "~/.claude" sharing a
    # word with a store name must not count as a store match.
    sub cd_target_is_marker {
        my ($raw_target) = @_;
        return 0 unless defined $raw_target && length $raw_target;
        # FB13: strip quote characters only -- a backslash must survive this
        # step so normalize_segments() (called just below) gets to turn it
        # into a path separator (\ -> /), the same as every other path this
        # file classifies. Deleting the backslash outright (as the old tr//d
        # set did) collapsed a Windows-style target like
        # "C:\P\.ccpraxis-local-data\bug-reports" into one run-on segment
        # with no separators at all, so the leaf-name match never fired.
        (my $stripped = $raw_target) =~ tr/\x27"//d;
        return 0 unless length $stripped;
        my ($drive, $prefix, @segs) = normalize_segments($stripped);
        return path_has_store_prefix(\@segs, 1);
    }

    # extract_cd_targets($hcmd) -> list of resolved cd/pushd target strings,
    # one per simple-command segment that is a cd/pushd invocation. Replaces
    # the single raw-text regex that only recognised a bare "cd TARGET"
    # right after a separator (MF1/BL1): this walks every segment via the
    # shared tokenizer, so it sees a cd behind "{", "then", "else", "do",
    # "builtin", "command", "time" or "!", past "--"/"-P"/"-L"-style option
    # words, and resolves a $VAR target against a NAME=value assignment that
    # was its own whole segment earlier in the same command line.
    sub extract_cd_targets {
        my ($hc) = @_;
        my ($toks, $pos) = tokenize_simple($hc);
        my @segs = find_simple_segments($toks, $pos, $hc);
        my %assign;
        my @targets;
        for my $seg (@segs) {
            if ($seg->{e} == $seg->{s} && $toks->[$seg->{s}] =~ /^([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/s) {
                $assign{$1} = dequote_simple($2);
            }
            my $vi = $seg->{s};
            while ($vi <= $seg->{e} && $toks->[$vi] =~ /^[A-Za-z_][A-Za-z0-9_]*=/) { $vi++; }
            while ($vi <= $seg->{e} && $toks->[$vi] =~ /^(?:\{|then|else|do|builtin|command|time|!|if|elif|while|until)\z/i) { $vi++; }
            next if $vi > $seg->{e};
            (my $cbase = $toks->[$vi]) =~ s{.*[/\\]}{};
            $cbase =~ s/\.exe\z//i;
            next unless $cbase =~ /^(?:cd|pushd)\z/i;
            my $wi = $vi + 1;
            while ($wi <= $seg->{e} && $toks->[$wi] =~ /^-/) { $wi++; }
            next if $wi > $seg->{e};
            my $tgt = $toks->[$wi];
            my $dq = dequote_simple($tgt);
            if ($dq =~ /^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?\z/ && defined $assign{$1}) {
                push @targets, $assign{$1};
            } else {
                push @targets, $tgt;
            }
        }
        return @targets;
    }

    # resolve_cd_chain($cwd, @cd_targets) -> effective absolute path (or
    # undef) after applying every extracted cd target in order against
    # $cwd. "." is a no-op once normalised; a relative target is appended;
    # an absolute one replaces. Used for item 3 (cwd persistence) so a cd
    # that does not actually leave a protected store (`cd .`, a `..` then
    # back into a sibling of the store) does not blind the relative-write
    # join the way the old any_cd flag used to.
    sub resolve_cd_chain {
        my ($cwd, @cd_targets) = @_;
        my $cur = $cwd;
        for my $t (@cd_targets) {
            next unless defined $t && length $t;
            # FB13 (same fix as cd_target_is_marker, line ~437): strip quote
            # characters only -- a backslash must survive so
            # normalize_segments() below turns it into a path separator.
            (my $stripped = $t) =~ tr/\x27"//d;
            next unless length $stripped;
            if ($stripped =~ m{^/} || $stripped =~ m{^[A-Za-z]:}) {
                $cur = $stripped;
            } elsif (defined $cur) {
                $cur = "$cur/$stripped";
            } else {
                next;
            }
            my ($d, $p, @s) = normalize_segments($cur);
            $cur = "$d$p" . join("/", @s);
        }
        return $cur;
    }

    # find_cpmvln_scope($hcmd, $dest_cmp) -> the simple-command segment TEXT
    # that performs the cp/mv/ln writing to $dest_cmp, or undef. SF1: the
    # old M4 check scanned the whole command for a store leaf name, which
    # denied unrelated text after an unquoted "&&". This localises the scan
    # to the one segment whose own token list contains the destination word
    # GuardBash already identified, using the same tokenizer/segmenter as
    # the cd extractor above.
    sub find_cpmvln_scope {
        my ($hc, $dest_cmp) = @_;
        return undef unless defined $dest_cmp && length $dest_cmp;
        my ($toks, $pos) = tokenize_simple($hc);
        my @segs = find_simple_segments($toks, $pos, $hc);
        for my $seg (@segs) {
            for my $ti ($seg->{s} .. $seg->{e}) {
                return $seg->{text} if _norm_cmp($toks->[$ti]) eq $dest_cmp;
            }
        }
        return undef;
    }

    # extract_substitutions($text) -> list of inner-code strings found
    # inside every top-level $(...) or `...` span (MF5): the plain
    # whitespace tokenizer reads a double-quoted "$(...)" as one opaque
    # token and never looks inside it, so a double-quoted assignment to a
    # substitution running an interpreter one-liner hid the interpreter
    # word completely. Quote-aware: a single-quoted span is skipped
    # outright -- bash never expands a substitution inside single quotes.
    sub _scan_balanced_paren {
        my ($text, $start) = @_;
        my $len = length($text);
        my $depth = 1;
        my $i = $start;
        my $q = "none";
        while ($i < $len && $depth > 0) {
            my $c = substr($text, $i, 1);
            if ($q eq "squote") { $i++; $q = "none" if $c eq "\x27"; next; }
            if ($q eq "dquote") {
                if ($c eq "\\" && $i + 1 < $len) { $i += 2; next; }
                $q = "none" if $c eq "\"";
                $i++; next;
            }
            if ($c eq "\x27") { $q = "squote"; $i++; next; }
            if ($c eq "\"") { $q = "dquote"; $i++; next; }
            if ($c eq "\\" && $i + 1 < $len) { $i += 2; next; }
            if ($c eq "(") { $depth++; $i++; next; }
            if ($c eq ")") { $depth--; $i++; next; }
            $i++;
        }
        return (substr($text, $start, $i - $start - 1), $i);
    }
    sub extract_substitutions {
        my ($text) = @_;
        my @out;
        my $len = length($text);
        my $i = 0;
        my $q = "none";
        while ($i < $len) {
            my $c = substr($text, $i, 1);
            if ($q eq "squote") { $i++; $q = "none" if $c eq "\x27"; next; }
            if ($q eq "dquote") {
                if ($c eq "\\" && $i + 1 < $len) { $i += 2; next; }
                if (substr($text, $i, 2) eq "\$(") {
                    my ($inner, $newi) = _scan_balanced_paren($text, $i + 2);
                    push @out, $inner if defined $inner;
                    $i = $newi; next;
                }
                # MF5: a backtick span is ALSO command-substituted inside
                # double quotes (unlike $(...), it is never itself quote-
                # balanced against the outer dquote, so this just scans to
                # the next backtick regardless of the enclosing state).
                if ($c eq "\x60") {
                    my $close = index($text, "\x60", $i + 1);
                    if ($close >= 0) {
                        push @out, substr($text, $i + 1, $close - $i - 1);
                        $i = $close + 1; next;
                    }
                }
                $q = "none" if $c eq "\"";
                $i++; next;
            }
            if ($c eq "\x27") { $q = "squote"; $i++; next; }
            if ($c eq "\"") { $q = "dquote"; $i++; next; }
            if ($c eq "\\" && $i + 1 < $len) { $i += 2; next; }
            if (substr($text, $i, 2) eq "\$(") {
                my ($inner, $newi) = _scan_balanced_paren($text, $i + 2);
                push @out, $inner if defined $inner;
                $i = $newi; next;
            }
            if ($c eq "\x60") {
                my $close = index($text, "\x60", $i + 1);
                if ($close >= 0) {
                    push @out, substr($text, $i + 1, $close - $i - 1);
                    $i = $close + 1; next;
                }
            }
            $i++;
        }
        return @out;
    }

    # ==========================================================================
    # Edit/Write/MultiEdit/NotebookEdit -- behaviourally unchanged.
    # ==========================================================================
    if ($t =~ /^(Edit|Write|MultiEdit|NotebookEdit)$/) {
        my $ti = $j->{tool_input} // {};
        my $p = $ti->{file_path} // $ti->{notebook_path} // "";
        exit 0 unless length $p;

        # S3 (relative paths): resolve against the payloads own cwd BEFORE
        # normalising, when the path is neither rooted (/, \) nor drive-qualified
        # (X:...).
        (my $check = $p) =~ s{\\}{/}g;
        unless ($check =~ m{^/} || $check =~ m{^[A-Za-z]:}) {
            my $cwd = $j->{cwd} // "";
            if (length $cwd) {
                (my $cwdc = $cwd) =~ s{\\}{/}g;
                $cwdc =~ s{/+\z}{};
                $p = "$cwdc/$p";
            }
        }

        my ($drive, $prefix, @segs) = normalize_segments($p);
        my $norm = "$drive$prefix" . join("/", @segs);
        exit 0 unless @segs;

        my ($kind, $rule, $rest_start) = classify_segments(\@segs, 0, undef, undef);
        exit 0 unless defined $kind;

        my @rest = @segs[$rest_start .. $#segs];
        my $type = "";
        if ($kind eq "store" && @rest >= 2) {
            $type = $rest[0];
        }
        my $base = $segs[-1];
        my $id = "";
        if ($base =~ /^(.+)\.md\z/i) {
            $id = $1;
        }

        print "DENY\x1f$kind\x1f$t\x1f$type\x1f$id\x1f$norm\n";
        exit 0;
    }

    exit 0 unless $t eq "Bash";

    # ==========================================================================
    # Bash (spec sec 2.3/2.4).
    # ==========================================================================
    my $ti = $j->{tool_input} // {};
    my $cmd = $ti->{command};
    exit 0 unless defined $cmd && !ref($cmd) && length $cmd;
    utf8::encode($cmd) if utf8::is_utf8($cmd);

    my $cwd = $j->{cwd};
    undef $cwd if ref($cwd) || !defined($cwd) || !length($cwd);
    if (defined $cwd) {
        (my $cwdc = $cwd) =~ s{\\}{/}g;
        $cwdc =~ s{/+\z}{};
        if ($cwdc =~ m{^/} || $cwdc =~ m{^[A-Za-z]:}) { $cwd = $cwdc; }
        else { undef $cwd; }
    }

    # ---- heredoc body removal (spec 2.4) -----------------------------------
    sub find_heredoc_word {
        my ($line) = @_;
        my $len = length($line);
        my $i = 0;
        my $q = "none";
        while ($i < $len) {
            my $c = substr($line, $i, 1);
            if ($q eq "squote") { $q = "none" if $c eq "\x27"; $i++; next; }
            if ($q eq "dquote") {
                if ($c eq "\\" && $i + 1 < $len) { $i += 2; next; }
                $q = "none" if $c eq "\"";
                $i++; next;
            }
            if ($c eq "\x27") { $q = "squote"; $i++; next; }
            if ($c eq "\"") { $q = "dquote"; $i++; next; }
            if ($c eq "\\" && $i + 1 < $len) { $i += 2; next; }
            if ($c eq "<" && $i + 1 < $len && substr($line, $i + 1, 1) eq "<") {
                # S1: a here-string (`<<<`) is never a heredoc opener, and
                # neither is a `<<` immediately preceded by a digit (an
                # arithmetic left-shift, e.g. `$((1<<2))`) -- a real heredoc
                # operator is never written either way. Skip past the
                # operator without starting a heredoc scan.
                if ($i + 2 < $len && substr($line, $i + 2, 1) eq "<") { $i += 3; next; }
                if ($i > 0 && substr($line, $i - 1, 1) =~ /[0-9]/) { $i += 2; next; }
                my $k = $i + 2;
                my $dash = 0;
                if ($k < $len && substr($line, $k, 1) eq "-") { $dash = 1; $k++; }
                while ($k < $len && substr($line, $k, 1) =~ /\s/) { $k++; }
                my $qc = "";
                if ($k < $len && (substr($line, $k, 1) eq "\x27" || substr($line, $k, 1) eq "\"")) {
                    $qc = substr($line, $k, 1); $k++;
                }
                my $start = $k;
                while ($k < $len) {
                    my $cc = substr($line, $k, 1);
                    last if length($qc) && $cc eq $qc;
                    last if !length($qc) && $cc =~ /[\s;&|()<>]/;
                    $k++;
                }
                my $word = substr($line, $start, $k - $start);
                return [$word, $dash] if length $word;
            }
            $i++;
        }
        return undef;
    }
    sub strip_heredocs {
        my ($c) = @_;
        my @lines = split /\n/, $c, -1;
        my @out;
        my $i = 0;
        while ($i <= $#lines) {
            my $line = $lines[$i];
            my $hw = find_heredoc_word($line);
            push @out, $line;
            $i++;
            if (defined $hw) {
                my ($w, $dash) = @$hw;
                while ($i <= $#lines) {
                    my $cand = $lines[$i];
                    my $probe = $dash ? ($cand =~ s/^\t+//r) : $cand;
                    $i++;
                    last if $probe eq $w;
                }
            }
        }
        return join("\n", @out);
    }
    my $hcmd = strip_heredocs($cmd);

    # ---- naive quote-aware whitespace/metacharacter tokenizer (rule I) -----
    # M1/B2 (review+red-team): a word in COMMAND POSITION starts at the
    # start of text, after whitespace, OR after an unquoted semicolon,
    # ampersand, pipe, open/close paren or backtick -- shapes like
    # true;python -c CODE, (python -c CODE), a backtick-wrapped
    # python -c CODE, and true|perl -e CODE all glue the interpreter word
    # onto a boundary character with no whitespace. Treat each such
    # boundary character as its own one-character token so the interpreter
    # basename test downstream (which just scans every token) sees "python"
    # as a token in its own right rather than as a suffix of "true;python".
    sub tokenize_simple {
        my ($text) = @_;
        my (@toks, @pos);
        my $len = length($text);
        my $i = 0;
        while ($i < $len) {
            # FB11 (newline-as-separator): skip ordinary whitespace silently,
            # but a bare newline is a statement boundary exactly like ";" --
            # emit it as its own one-character token rather than swallowing
            # it, so find_simple_segments (which splits on this same set of
            # boundary tokens) sees a cd on one line and a write on the next
            # as two separate simple commands.
            while ($i < $len && substr($text, $i, 1) =~ /[ \t\r]/) { $i++; }
            last if $i >= $len;
            my $c0 = substr($text, $i, 1);
            if ($c0 =~ /[;&|()`\n]/) {
                push @toks, $c0; push @pos, $i;
                $i++;
                next;
            }
            my $start = $i;
            my $q = "none";
            while ($i < $len) {
                my $c = substr($text, $i, 1);
                if ($q eq "squote") { $i++; $q = "none" if $c eq "\x27"; next; }
                if ($q eq "dquote") {
                    if ($c eq "\\" && $i + 1 < $len) { $i += 2; next; }
                    $i++; $q = "none" if $c eq "\""; next;
                }
                last if $c =~ /\s/;
                last if $c =~ /[;&|()`]/;
                if ($c eq "\x27") { $q = "squote"; $i++; next; }
                if ($c eq "\"") { $q = "dquote"; $i++; next; }
                if ($c eq "\\" && $i + 1 < $len) { $i += 2; next; }
                $i++;
            }
            push @toks, substr($text, $start, $i - $start);
            push @pos, $start;
        }
        return (\@toks, \@pos);
    }

    # dequote_simple($word) -> content with one matching layer of single or
    # double quote removed (no escape processing beyond that -- good enough
    # to recurse the interpreter rule over a bash -c "..." / sh -c CODE
    # argument).
    sub dequote_simple {
        my ($w) = @_;
        return $1 if $w =~ /^"(.*)"\z/s;
        return $1 if $w =~ /^\x27(.*)\x27\z/s;
        return $w;
    }

    # ---- Rule I: interpreter one-liner (spec 2.4) --------------------------
    sub interpreter_rule {
        my ($hc, $depth) = @_;
        $depth //= 0;
        return undef if $depth > 3; # M1/B2: bounded shell-wrapper recursion
        my ($toks, $pos) = tokenize_simple($hc);
        my $n = scalar @$toks;
        for (my $k = 0; $k < $n; $k++) {
            my $word = $toks->[$k];
            (my $base = $word) =~ s{.*[/\\]}{};
            $base =~ s/\.exe\z//i;
            my $interp;
            if    ($base =~ /^perl\z/i)                 { $interp = "perl"; }
            elsif ($base =~ /^python3?(?:\.\d+)?\z/i)   { $interp = "python"; }
            elsif ($base =~ /^py\z/i)                   { $interp = "python"; }
            elsif ($base =~ /^node\z/i)                 { $interp = "node"; }
            elsif ($base =~ /^ruby\z/i)                 { $interp = "ruby"; }
            elsif ($base =~ /^(?:powershell|pwsh)\z/i)  { $interp = "powershell"; }
            elsif ($base =~ /^(?:bash|sh|zsh|dash|ksh)\z/i) { $interp = "shell"; }
            else { next; }

            # M1/B2: a bash -c "..." / sh -c CODE argument hides its own
            # interpreter word inside one quoted token that the plain
            # whitespace tokenizer never looks inside. Recurse into its
            # dequoted content, depth-bounded above.
            if ($interp eq "shell") {
                for (my $j3 = $k + 1; $j3 < $n; $j3++) {
                    my $w3 = $toks->[$j3];
                    last unless $w3 =~ /^-/ || $w3 eq "-c";
                    if ($w3 eq "-c" || $w3 eq "--command") {
                        my $arg = $toks->[$j3 + 1];
                        if (defined $arg) {
                            my $inner = interpreter_rule(dequote_simple($arg), $depth + 1);
                            return $inner if $inner;
                        }
                        last;
                    }
                }
                next;
            }

            my $j2 = $k + 1;
            my $flag_idx;
            my $hint_from_flag = 0;
            while ($j2 < $n) {
                my $w = $toks->[$j2];
                last unless $w =~ /^-/;
                my $is_flag = 0;
                my $takes_value = 0;
                if ($interp eq "perl") {
                    $is_flag = 1 if $w =~ /^-[A-Za-z0-9]*[eE]/;
                    $hint_from_flag = 1 if $w =~ /^-[A-Za-z0-9]*i/;
                    $takes_value = 1 if !$is_flag && $w =~ /^-[Ix]\z/;
                } elsif ($interp eq "python") {
                    # M1/#3: no \z -- python accepts code glued directly
                    # onto the flag (`-c"import os..."`), which the
                    # whitespace/quote-aware tokenizer leaves as one token.
                    $is_flag = 1 if $w =~ /^-[A-Za-z]*c/;
                    $takes_value = 1 if !$is_flag && $w =~ /^-[WXm]\z/;
                } elsif ($interp eq "node") {
                    $is_flag = 1 if $w eq "-e" || $w eq "-p" || $w eq "--eval" || $w eq "--print" || $w =~ /^--eval=/;
                } elsif ($interp eq "ruby") {
                    $is_flag = 1 if $w =~ /^-[A-Za-z]*e/;
                    $hint_from_flag = 1 if $w =~ /^-[A-Za-z]*i/;
                } elsif ($interp eq "powershell") {
                    $is_flag = 1 if $w =~ /^-{1,2}(?:c|command)\z/i;
                }
                if ($is_flag) { $flag_idx = $j2; last; }
                $j2++;
                $j2++ if $takes_value;
            }
            next unless defined $flag_idx;

            my $code_region = substr($hc, $pos->[$flag_idx]);
            my $store_re = qr/(?:\.ccpraxis-local-data|ccprax~\d+)[\\\/]+(bug-reports|almanac)\b|(?:claude-code-vault|claude~\d+)[\\\/]+(almanac)\b/i;
            next unless $code_region =~ $store_re;
            my $root_kind_tag = defined($1) ? $1 : $2;
            my $lit_start = $-[0];
            my $kind = (lc($root_kind_tag) eq "bug-reports") ? "bug" : "store";

            my $has_hint = $hint_from_flag;
            $has_hint ||= ($code_region =~ /\b(?:unlink|rename|truncate|rmtree|remove_tree|sysopen|rmdir|rmSync|unlinkSync|renameSync|writeFile|writeFileSync|appendFile|appendFileSync|copyFile|copyFileSync|truncateSync|createWriteStream|write_text|write_bytes|spew|spew_utf8|spew_raw)\b/);
            $has_hint ||= ($code_region =~ /\bos\.(?:remove|unlink|rename|replace|truncate|rmdir|removedirs)\b/);
            $has_hint ||= ($code_region =~ /\bshutil\.\w+/);
            $has_hint ||= ($code_region =~ /\b(?:copy|move)\s*\(/);
            $has_hint ||= ($code_region =~ /\.write\s*\(/);
            $has_hint ||= ($code_region =~ /[\x27"]\s*(?:\+?>|\+<)/);
            $has_hint ||= ($code_region =~ /[\x27"](?=[rwaxbt+]{1,3}[\x27"])(?=[^\x27"]*[wax+])[rwaxbt+]{1,3}[\x27"]/);
            if ($interp eq "powershell") {
                # M5: the write/delete vocabulary of PowerShell itself, since the
                # perl/python/node/ruby hints above never match it.
                $has_hint ||= ($code_region =~ /\b(?:Remove-Item|ri|del|erase|ren|Rename-Item|Move-Item|mi|Copy-Item|ci|Set-Content|sc|Out-File|Clear-Content|clc)\b/i);
                $has_hint ||= ($code_region =~ />/);
            }
            next unless $has_hint;

            my $rest = substr($code_region, $lit_start);
            $rest =~ /^([^\x27"\s]*)/;
            my $pathlit = $1;
            my ($drive, $prefix, @segs) = normalize_segments($pathlit);
            my $norm = "$drive$prefix" . join("/", @segs);

            my ($type, $id) = ("", "");
            for my $si (0 .. $#segs) {
                if (lc($segs[$si]) eq "almanac") {
                    if (defined $segs[$si + 1] && $segs[$si + 1] =~ /^[A-Za-z0-9-]+\z/) {
                        $type = $segs[$si + 1];
                        if (defined $segs[$si + 2] && $segs[$si + 2] =~ /^(.+)\.md\z/i) {
                            $id = $1;
                        }
                    }
                    last;
                }
            }

            my $shape = "$interp $toks->[$flag_idx]";
            return { kind => $kind, tool => "Bash ($shape)", type => $type, id => $id, path => $norm };
        }
        return undef;
    }

    my $ideny = interpreter_rule($hcmd);
    unless ($ideny) {
        # MF5 (item 5): an interpreter one-liner inside $(...) or a backtick
        # span is invisible to the plain tokenizer, which reads a double-
        # quoted "$(...)" as one opaque token. Pull the inner text out of
        # every top-level substitution and run the same rule over each one,
        # reusing the depth bound already built into interpreter_rule.
        for my $sub (extract_substitutions($hcmd)) {
            $ideny = interpreter_rule($sub, 1);
            last if $ideny;
        }
    }
    if ($ideny) {
        print "DENY\x1f$ideny->{kind}\x1f$ideny->{tool}\x1f$ideny->{type}\x1f$ideny->{id}\x1f$ideny->{path}\n";
        exit 0;
    }

    # ---- load the parser (butler, sibling plugin directory) ---------------
    my $gb = "$hookdir/../../butler/scripts/BpHook/Guards/GuardBash.pm";
    my $ok = eval { require $gb; 1 } && defined &BpHook::Guards::GuardBash::hyg_targets;
    exit 0 unless $ok;

    my @targets = eval { BpHook::Guards::GuardBash::hyg_targets($cmd, Time::HiRes::time() + 3) };
    exit 0 if $@;

    my $any_cd = 0;
    for my $e (@targets) {
        $any_cd = 1 if ref($e) eq "HASH" && (($e->{kind} // "") eq "cd");
    }
    # M2: `env -C DIR cmd...` / `sudo -D DIR cmd...` change the effective
    # cwd for the wrapped command, but GuardBash consumes the flag silently
    # and never emits a kind=>"cd" entry for it. Treat it like an explicit
    # cd: this disables the (wrong) cwd join below for a relative literal
    # and lets the Rule E relative-write check below see it.
    $any_cd = 1 if $cmd =~ /(?:^|[\s;&|(])(?:env|sudo)\b[^;&|]*\s(?:-C|--chdir(?:=\S+)?|-D)\b/;

    # FIX-BATCH (item 3, architectural): resolve $cwd through every cd this
    # command performs, textually, BEFORE deciding whether a relative write
    # joins against it. MF3/MJ3: the old code disabled the cwd join outright
    # whenever any_cd was set, so `cd . && rm a.md` and a raw/glob target
    # under an already-in-store cwd were never joined at all. A cd that is a
    # no-op (".") or that returns to the same directory still resolves back
    # to the same effective path here, so this is strictly more precise than
    # the old all-or-nothing any_cd gate -- it does not depend on the
    # command text itself repeating a store-name substring.
    my @cd_targets = extract_cd_targets($hcmd);

    # ---- Rule E: cd then a relative write, with a marker in the cd
    # argument itself (Decision 41 / S3) ------------------------------------
    # S3: the marker must be in the `cd`/`pushd` TARGET itself, not merely
    # present somewhere else in the command text (a `cat` of a store path,
    # an echo, a comment) -- otherwise `cd /tmp && cat <store-path>` denies
    # for no reason, since the store is only being READ.
    #
    # Runs BEFORE the main targets loop below (architectural change, item
    # 3): a cd whose own target already names a store/container (AC10, an
    # absolute `cd <store> && rm a.md`) must still get this own "Bash (cd)"
    # / root-kind message, which names the relative write text verbatim --
    # the main loop EFFECTIVE_CWD join (right after this block) would
    # otherwise resolve the same write to an absolute path first and answer
    # with the more specific bug/store template instead, changing the
    # wording for a case this file already had a dedicated, tested message
    # for. A cd that does NOT itself name a marker (a bare ".", a relative
    # subdir, or no cd at all) falls through here with no deny, and is
    # handled below by the cwd-aware join instead.
    if ($any_cd) {
        my $has_marker = 0;
        # item 2 (MF1/BL1): extract_cd_targets walks every simple-command
        # segment via the shared tokenizer, so it recognises "cd --", a
        # "cd" behind "{"/"then"/"builtin"/"command"/"time", a $VAR target
        # resolved against a same-line assignment, and tests each target
        # with cd_target_is_marker, whose quote/backslash-stripped, glob-
        # tolerant segment match -- the same machinery the write-target
        # classifier uses, rather than a single raw-text regex.
        for my $cd_tgt (@cd_targets) {
            if (cd_target_is_marker($cd_tgt)) {
                $has_marker = 1;
                last;
            }
        }
        unless ($has_marker) {
            # M2: the directory argument of env -C/sudo -D is a cd target
            # too.
            while ($hcmd =~ /(?:^|[\s;&|(])(?:env|sudo)\b[^;&|]*?\s(?:-C|--chdir(?:=)?|-D)[= ]?(\S+)/g) {
                my $cd_tgt = $1;
                if ($cd_tgt =~ /ccpraxis-local-data|claude-code-vault|ccprax~\d+|claude~\d+/i) {
                    $has_marker = 1;
                    last;
                }
            }
        }
        if ($has_marker) {
            for my $entry (@targets) {
                next unless ref($entry) eq "HASH";
                my $ekind = $entry->{kind} // "";
                next unless $ekind eq "write" || $ekind eq "delete" || $ekind eq "move";
                next if (($entry->{shape} // "") eq "mkdir");
                my $w = $entry->{word};
                next unless ref($w) eq "HASH";
                my $text;
                if (defined $w->{literal}) { $text = $w->{literal}; }
                elsif (defined $w->{raw}) { ($text = $w->{raw}) =~ tr/\x27"//d; }
                else { next; }
                next if $text =~ m{^/};
                next if $text =~ m{^[A-Za-z]:};
                next if $text =~ /^~/;
                next if $text =~ /^\$/;
                print "DENY\x1froot\x1f" . "Bash (cd)" . "\x1f\x1f\x1f$text\n";
                exit 0;
            }
        }
    }

    # item 3 (MF3/MJ3, architectural): resolve $cwd through every cd this
    # command performs, textually, BEFORE deciding whether a relative write
    # joins against it. The old code disabled the cwd join outright whenever
    # any_cd was set, so `cd . && rm a.md` and a raw/glob target under an
    # already-in-store cwd were never joined at all. A cd that is a no-op
    # (".") or that returns to the same directory still resolves back to the
    # same effective path here, so this is strictly more precise than the
    # old all-or-nothing any_cd gate -- it does not depend on the command
    # text itself repeating a store-name substring. Only reached when Rule E
    # above did not already deny.
    my $EFFECTIVE_CWD = defined($cwd) ? resolve_cd_chain($cwd, @cd_targets) : undef;

    for my $entry (@targets) {
        next unless ref($entry) eq "HASH";
        my $ekind = $entry->{kind} // "";
        next unless $ekind eq "write" || $ekind eq "delete" || $ekind eq "move";
        my $eshape = $entry->{shape};
        next if defined($eshape) && $eshape eq "mkdir";

        my $w = $entry->{word};
        next unless ref($w) eq "HASH";

        my ($text, $allow_glob);
        if (defined $w->{literal}) {
            $text = $w->{literal};
            $allow_glob = 0;
            (my $check = $text) =~ s{\\}{/}g;
            unless ($check =~ m{^/} || $check =~ m{^[A-Za-z]:} || !defined($EFFECTIVE_CWD)) {
                $text = "$EFFECTIVE_CWD/$text";
            }
        } elsif (defined $w->{raw}) {
            ($text = $w->{raw}) =~ tr/\x27"//d;
            $allow_glob = 1;
            # item 3: a raw/glob target (sed -i on *.md, rm -f ./*) also
            # resolves against the effective cwd -- it never did before,
            # which is why a glob under an already-in-store cwd allowed.
            (my $rcheck = $text) =~ s{\\}{/}g;
            unless ($rcheck =~ m{^/} || $rcheck =~ m{^[A-Za-z]:} || !defined($EFFECTIVE_CWD)) {
                $text = "$EFFECTIVE_CWD/$text";
            }
        } else {
            next;
        }

        my ($drive, $prefix, @segs) = normalize_segments($text);
        next unless @segs;

        # MF1: when the write target was joined against EFFECTIVE_CWD above, a
        # glob character living in one of the cd targets that built that cwd
        # chain must also enable glob-tolerant matching here -- otherwise a
        # literal write joined onto a globby cd chain is classified without
        # glob tolerance even though the chain itself may only resolve via a
        # glob/brace match (seg_glob_match).
        my $cd_glob = (grep { defined $_ && /[*?[{]/ } @cd_targets) ? 1 : 0;
        my ($kind, $rule, $rest_start) = classify_segments(\@segs, ($allow_glob || $cd_glob), $ekind, $eshape);

        # M4: Rule C only fires for delete/move, so `cp -r SRC .ccpraxis-
        # local-data/` (a WRITE whose destination is exactly the container
        # root) falls through classify_segments entirely -- yet it still
        # writes INTO the store if SRC names a store leaf directory (its
        # whole contents land inside the container) or is "the whole
        # directory" (a trailing `/.`). A destination ending with one more
        # segment (.ccpraxis-local-data/bug-reports) is already the job of
        # Rule A; this only covers the exact-root case Rule A/B/C all miss.
        # `cp x.md .ccpraxis-local-data/` (spec behaviour 18) stays allowed
        # because its source matches neither pattern.
        if (!defined($kind) && defined($eshape) && $eshape =~ /^(?:cp|mv|ln)\z/) {
            my $dest_is_container =
                (@segs >= 1 && seg_match_u($segs[-1], ".ccpraxis-local-data", $allow_glob))
                || (@segs >= 2 && seg_match_u($segs[-2], ".claude", $allow_glob)
                               && seg_match_u($segs[-1], "claude-code-vault", $allow_glob));
            if ($dest_is_container) {
                # item 4 (MF4/SF1): scope the source scan to the OWN simple-
                # command segment of this cp/mv/ln -- found by matching the
                # destination word GuardBash already identified against the
                # segmentation built from the same tokenizer -- instead of
                # the whole command text, so a destination followed by an
                # unquoted `&&` and unrelated text no longer denies on that
                # unrelated text. Also tolerate a trailing slash, `-T`/
                # `--no-target-directory`, and a `./`-suffixed source.
                my $dest_raw_text = defined($w->{literal}) ? $w->{literal}
                                   : (defined($w->{raw}) ? $w->{raw} : "");
                my $scope = find_cpmvln_scope($hcmd, _norm_cmp($dest_raw_text));
                if (defined $scope) {
                    my $has_T = ($scope =~ /(?:^|\s)-[A-Za-z]*T[A-Za-z]*\b/ || $scope =~ /(?:^|\s)--no-target-directory\b/);
                    my $src_hit = ($scope =~ m{(?:^|[\s\x27"/])(?:bug-reports|almanac)/*(?:[\s\x27"]|\z)}i
                                || $scope =~ m{(?:^|[\s\x27"])\S*/\.(?:/+)?(?:[\s\x27"]|\z)});
                    if ($has_T || $src_hit) {
                        $kind = "root";
                        $rule = "C";
                        $rest_start = scalar(@segs);
                    }
                }
            }
        }
        next unless defined $kind;

        my $norm = "$drive$prefix" . join("/", @segs);
        my ($type, $id) = ("", "");
        if ($rule eq "A") {
            my @rest = @segs[$rest_start .. $#segs];
            if ($kind eq "store" && @rest >= 2) { $type = $rest[0]; }
            my $base = $segs[-1];
            if ($base =~ /^(.+)\.md\z/i) { $id = $1; }
        }

        my $shape_disp = defined($eshape) ? $eshape : $ekind;
        print "DENY\x1f$kind\x1f" . "Bash ($shape_disp)" . "\x1f$type\x1f$id\x1f$norm\n";
        exit 0;
    }

    exit 0;
' "$HOOKDIR" 2>/dev/null)

case "$OUT" in
  DENY$'\x1f'*) ;;
  *) exit 0 ;;
esac

IFS=$'\x1f' read -r _TAG KIND TOOL TYPE ID NPATH <<< "$OUT"

if [ "$KIND" = "bug" ]; then
  {
    echo "BLOCKED: $TOOL on a bug report. These are written only through almanac-bug.pl."
    echo
    echo "  $NPATH"
    echo
    echo "A report's body is FROZEN once it leaves 'open' — that is what lets a reviewer read it without the filer rewriting it underneath them, and what makes 'taken' mean something. A direct edit would bypass both the state machine and the sha256 recorded at freeze time."
    echo
    echo "  While still open, revise it:"
    echo "    perl <ccpraxis>/plugins/almanac/scripts/almanac-bug.pl update $ID --body -"
    echo
    echo "  Already triaging/taken? It is deliberately immutable. File a follow-up:"
    echo "    perl <ccpraxis>/plugins/almanac/scripts/almanac-bug.pl file --title \"...\" --body -"
    echo
    if [[ "$TOOL" == Bash* ]]; then
      echo "  Change its status:  perl <ccpraxis>/plugins/almanac/scripts/almanac-bug.pl set-status $ID --to <state>"
      echo
    fi
    echo "  Check state:  almanac-bug.pl list        (this project)"
    echo "                almanac-bug.pl verify      (digests still intact?)"
  } >&2
  exit 2
fi

if [ "$KIND" = "root" ]; then
  {
    echo "BLOCKED: $TOOL would delete, move, or write through a directory that holds bug reports or almanac records."
    echo
    echo "  $NPATH"
    echo
    echo "Bug reports are written only through almanac-bug.pl (file | update | append | set-status), and almanac records only through their own scripts (almanac-todo.pl, almanac-note.pl, almanac-task.pl, almanac-decision.pl). Run the script verb for the record you meant, and use absolute paths instead of cd."
    echo
    echo "Any write that did not go through the scripts is reported by:  perl <ccpraxis>/plugins/almanac/scripts/almanac-bug.pl verify"
  } >&2
  exit 2
fi

# kind == store — the verb map, keyed by lc(type). ${TYPE,,} is a bash
# builtin (no extra process on the deny path, unlike a printf|tr pipeline).
TYPE_LC=${TYPE,,}
case "$TYPE_LC" in
  todo)        SCRIPT="almanac-todo.pl";     VERBS="create | edit | complete | reopen | delete" ;;
  note)        SCRIPT="almanac-note.pl";     VERBS="create | edit | promote | delete" ;;
  task)        SCRIPT="almanac-task.pl";     VERBS="add | edit | status | move-first | move-last | reorder" ;;
  task-focus)  SCRIPT="almanac-task.pl";     VERBS="focus | unfocus" ;;
  decision)    SCRIPT="almanac-decision.pl"; VERBS="file | answer" ;;
  "")
    SCRIPT="almanac-<type>.pl"
    VERBS="(the script for the store you meant)"
    ;;
  *)
    SCRIPT="almanac-$TYPE_LC.pl"
    VERBS="(no verb map for this type -- the script that owns '$TYPE_LC' by naming convention; run it without arguments for its verbs)"
    ;;
esac

if [ -n "$TYPE" ]; then
  TYPE_LINE="  store type: $TYPE"
else
  TYPE_LINE="  store type: (none -- a file directly under the almanac root)"
fi

{
  echo "BLOCKED: $TOOL on an almanac record store. Almanac records are written only through their scripts."
  echo
  echo "  $NPATH"
  echo
  echo "$TYPE_LINE"
  if [ -n "$ID" ]; then
    echo "  record id:  $ID"
  fi
  echo "  use:        perl <ccpraxis>/plugins/almanac/scripts/$SCRIPT  $VERBS"
  echo
  echo "A direct edit bypasses the store's lock, its compare-and-swap and its seal. Any write that did not go"
  echo "through the script is reported by:  perl <ccpraxis>/plugins/almanac/scripts/almanac-bug.pl verify"
} >&2

exit 2
