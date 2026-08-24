#!/usr/bin/env perl
# 62-tui-adapter-contract.t — the TUI panel-adapter contract's ENFORCEMENT,
# for blueprint unified-tui-design-system, package 01-adapter-contract
# (specs/01-adapter-contract-spec.md). Written BLIND to any doc /
# launcher.pl implementation beyond what launcher.pl already looks like
# today — directly from the spec — so this serves as an ORACLE rather than
# an echo of whatever the doc-writer/implementer eventually write. Do NOT
# weaken an assertion here to make a future implementation's life easier.
#
# WHAT THIS GUARDS (spec S1). launcher.pl carries seven `_gather_*` panel
# adapters, all called from the dashboard's render/state tick. Rule 1 of the
# doctrine this test enforces is "never fork, spawn or block on the render
# tick". A purely TEXTUAL scan of a `sub _gather_*` BODY cannot prove that:
# `_gather_resources`'s own body contains no spawn construct at all — the
# backticks live in same-file helpers it calls (`_resources_probes`,
# `_powershell_json`). So this guard FOLLOWS CALLS: for every discovered
# adapter it computes the transitive same-file call closure and flags a
# spawn construct found anywhere in that closure (spec S2.2.4). A body-local
# scan would find zero violations and make the whole package vacuous — see
# spec S1's "critical structural fact" and S7-E1.
#
# HARD CONSTRAINTS honoured here (spec S2.2, AC-10):
#   * launcher.pl is SLURPED as source text only — never require'd, do'ne,
#     or executed (t/102-tui-output-hygiene.t's established convention).
#   * No network, no container I/O, no podman, no launcher.pl spawn.
#   * Fixtures live only under File::Temp::tempdir(CLEANUP => 1).
#   * No `prove` on this host — runs standalone via `perl <file>`.
#
# NO SHAPE PINS (AC-6, Decision 15): no count over the discovered adapter
# set anywhere, no is_deeply over it. Non-vacuity is carried by (a) a >=1
# discovery floor, (b) a named-membership floor (_gather_spend and
# _gather_resources are among the discovered — not a shape pin: it forbids
# nothing from being ADDED, only deleting one of those two names can turn it
# red, and that IS a signal worth having; spec S4 AC-6's own note), and (c)
# the synthetic-fixture self-test below (spec S3-C), which proves the
# analyser catches direct / two-hop / cyclic / piped-open spawns and ignores
# comments / qualified calls / unreached code — independent of launcher.pl's
# current content, so it is stale-proof.
#
# THE WAIVER LIST (spec S2.2.5) lives in this file, not a separate data
# file, because package 03's write set includes this test but no data file.
# It is not a pardon: emptying it is package 03's on-disk proof of landing.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

my $SCRIPTS  = "$Bin/../../scripts";
my $LAUNCHER = "$SCRIPTS/launcher.pl";
my $DOC      = "$Bin/../../docs/tui-adapter-contract.md";

# ===========================================================================
# Scaffolding
# ===========================================================================

# slurp($path) -> file contents as bytes, or undef. Used for launcher.pl,
# the doc, and the synthetic fixture alike — NONE of them are ever
# require'd/do'ne/executed, only read as text (spec S2.2, AC-10).
sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

# ===========================================================================
# The analyser (spec S2.2). Implemented inline — the write set has exactly
# two files (the doc and this test), and there is no module to put it in.
# ===========================================================================

# _balanced_braces($src, $from) -> the '{'...'}' substring balanced from the
# first '{' at-or-after $from, or undef if unbalanced. Verbatim shape reused
# from t/102-tui-output-hygiene.t:63-77 / t/59-fleet-event-source.t.
sub _balanced_braces {
    my ($src, $from) = @_;
    my $idx = index($src, '{', $from);
    return undef if $idx < 0;
    my $depth = 0;
    my $i     = $idx;
    my $len   = length($src);
    for (; $i < $len; $i++) {
        my $c = substr($src, $i, 1);
        if    ($c eq '{') { $depth++; }
        elsif ($c eq '}') { $depth--; last if $depth == 0; }
    }
    return undef if $depth != 0;
    return substr($src, $idx, $i - $idx + 1);
}

# _blank_noncode($src) -> $src2, SAME NUMBER OF LINES as the input (so line
# numbers computed against the blanked text stay usable in failure
# messages). Two passes (spec S2.2.1):
#
#   A. POD — blank (replace with '', keep the newline) every line from a
#      line matching /^=[a-zA-Z]/ through the following /^=cut\b/ inclusive.
#      (launcher.pl carries no POD today; cheap insurance regardless.)
#
#   B. comments, per line:
#      1. a whole-line `#...` comment (/^(\s*)#/) is blanked outright to its
#         leading whitespace. This alone handles launcher.pl's dense
#         full-line prose commentary that DISCUSSES backticks/forking/
#         spawning — launcher.pl:4509-4520, 4540-4549, 4690-4700 are the
#         live cases this must survive (see the "prose" fixture row below).
#      2. otherwise the line is scanned left to right tracking three
#         toggles (single-quote / double-quote / backtick), where a
#         character preceded by a backslash never toggles anything, and is
#         truncated at the first '#' that is outside all three, not
#         preceded by '$' (so $#array survives), and is at column 0 or
#         preceded by whitespace.
#
# STATED LIMITS (spec S2.2.1, recorded here per the spec's instruction): a
# '#' inside q{}/qq{}/m{}/qw() delimiters is not modelled, and a quote
# character inside a regex character class can desynchronise the toggles
# for the rest of that one line. Both fail SAFE for this guard — the worst
# case is a comment survives, which can only produce a false POSITIVE (a
# named, line-numbered failure a human sees), never a silent pass.
#
# CORRECTED (test-writer fix-batch, redteam H-10 / reviewer MINOR-2): an
# earlier draft of this comment claimed "neither pattern occurs in
# launcher.pl today". That is FALSE, in two places, though harmlessly so:
#   * A close relative of the char-class pattern — an ESCAPED quote
#     immediately before a line's end — occurs at launcher.pl:1439
#     (`$s =~ s/"/\\"/g;`) and :1442 (`$s =~ s/'/'\\''/g;`). Each leaves
#     this pass's in_dq/in_sq toggle stuck ON for the rest of THAT physical
#     line (the per-line reset below means it never bleeds into the next
#     line). It is harmless TODAY only because neither line carries a
#     trailing '#' for the stuck toggle to hide — not because the desync
#     doesn't happen.
#   * A close relative of the q{}-delimiter pattern — a bare apostrophe in
#     prose INSIDE a multi-line q{} literal — occurs at launcher.pl:352
#     ("Claude Code's own configuration home") and :369 ("Claude Code's
#     configuration, and every other project on the machine"). Same
#     per-line-reset mechanism, and additionally neither of those subs
#     (`_pp_explanation`/`_pp_advice`) is reachable from any `_gather_*`
#     adapter's closure, so it cannot affect this guard's real findings
#     even if it did desync.
# Net: the SAFE-FAILURE property (a comment survives, never a silent pass)
# holds either way; only the "doesn't occur" claim was wrong, and it is
# corrected here rather than softened.
sub _blank_noncode {
    my ($src) = @_;
    my @lines = split /\n/, $src, -1;

    # Pass H: heredocs (H-2). A heredoc BODY is DATA, never Perl -- blank
    # every line of it (same line count) BEFORE Pass A/B ever see it. This
    # must run FIRST: a '=word'-shaped line inside heredoc content would
    # otherwise run Pass A's POD blanker to EOF (killing every real sub
    # after the heredoc — H-8's heredoc variant), and an unmatched column-0
    # '}' inside heredoc content would otherwise desync brace-counting in
    # _balanced_braces and silently TRUNCATE a body, hiding a spawn (spec
    # S5's "brace confusion ... fail[s] loudly ... rather than silently
    # truncating a body" is only true once this pass exists — see redteam
    # H-2, which demonstrated the previous truncation with zero failure of
    # any kind). Recognises <<'TAG', <<"TAG", <<TAG and the indented
    # <<~TAG form (terminator line may itself be indented for that form).
    #
    # STATED LIMIT: a line that is itself a whole-line comment (/^\s*#/) is
    # never treated as an opener, specifically so a comment like
    # "# <<< q03:protected-path-decision:END" (a real marker already
    # present in launcher.pl) cannot be misread as a heredoc opening
    # "q03" bareword tag -- that misreading would otherwise consume every
    # line to EOF hunting a lone "q03" terminator that will never appear.
    # A <<TAG-shaped trailing comment on a CODE line is not specially
    # guarded against (would need full expression parsing to distinguish
    # from a real opener); no such line exists in launcher.pl today
    # (verified — the only three '<<' occurrences in the file are the one
    # genuine heredoc at launcher.pl:3493 and the two full-line '# <<<'
    # markers this guard is written against).
    {
        my $tag;
        my $indented = 0;
        for my $l (@lines) {
            if (defined $tag) {
                my $is_term = $indented
                    ? ($l =~ /^\s*\Q$tag\E\s*$/)
                    : ($l =~ /^\Q$tag\E\s*$/);
                $l = '';
                $tag = undef if $is_term;
                next;
            }
            next if $l =~ /^\s*#/;   # whole-line comment: never an opener
            if ($l =~ /<<(~?)\s*(?:(['"])([A-Za-z_]\w*)\2|([A-Za-z_]\w*))/) {
                $indented = ($1 eq '~') ? 1 : 0;
                $tag      = defined($3) ? $3 : $4;
            }
        }
    }

    # Pass A: POD.
    my $in_pod = 0;
    for my $l (@lines) {
        if (!$in_pod && $l =~ /^=[a-zA-Z]/) {
            $in_pod = 1;
            $l = '';
            next;
        }
        if ($in_pod) {
            my $was_cut = ($l =~ /^=cut\b/);
            $l = '';
            $in_pod = 0 if $was_cut;
            next;
        }
    }

    # Pass B: comments.
    for my $l (@lines) {
        if ($l =~ /^(\s*)#/) {
            $l = $1;
            next;
        }
        my $len = length($l);
        my ($in_sq, $in_dq, $in_bt) = (0, 0, 0);
        my $cut_at;
        for (my $i = 0; $i < $len; $i++) {
            my $c    = substr($l, $i, 1);
            my $prev = $i > 0 ? substr($l, $i - 1, 1) : '';
            next if $prev eq '\\';   # escaped char never toggles anything
            if ($c eq "'" && !$in_dq && !$in_bt) { $in_sq = !$in_sq; next; }
            if ($c eq '"' && !$in_sq && !$in_bt) { $in_dq = !$in_dq; next; }
            if ($c eq '`' && !$in_sq && !$in_dq) { $in_bt = !$in_bt; next; }
            if ($c eq '#' && !$in_sq && !$in_dq && !$in_bt) {
                my $preceding = $i > 0 ? substr($l, $i - 1, 1) : '';
                next if $preceding eq '$';
                if ($i == 0 || $preceding =~ /\s/) {
                    $cut_at = $i;
                    last;
                }
            }
        }
        $l = substr($l, 0, $cut_at) if defined $cut_at;
    }

    return join("\n", @lines);
}

# _subs($blanked) -> \%subs { name => { start_line, start_pos } }.
# launcher.pl is a script, and every top-level `sub` in it starts at column
# 0 — find every /^sub\s+([A-Za-z_]\w*)\s*\{/m match (spec S2.2.2).
#
# STATED LIMITS (spec S2.2.2, UPDATED by the test-writer fix-batch): a sub
# defined at an indent, or a `sub` keyword at column 0 inside a (non-heredoc)
# string, would still defeat this. Two things that USED to be limits no
# longer are:
#   * A heredoc body whose line begins with `}` no longer desyncs
#     brace-counting — Pass H in `_blank_noncode` (H-2) blanks heredoc
#     bodies before this function ever sees them, so their braces never
#     enter the count.
#   * A genuine one-line sub (`sub log_ev { LaunchLog::event($LAUNCH_LOG,
#     @_) }`, launcher.pl:773, one of 11 such subs in launcher.pl today) no
#     longer fails extraction — `_get_body` below accepts a single-line
#     body as well as a multi-line one ending `}` at column 0 (H-4).
#
# launcher.pl has exactly one heredoc (launcher.pl:3493-3503, an inline bash
# install script) and it IS inside a sub — `s03_run_launch_gate`, which opens
# at launcher.pl:3260. (An earlier draft of this comment, and spec S2.2.2,
# both claimed it sat at top-level flow before any sub. That is wrong; the
# driver checked. Corrected here so nobody inherits the wrong reason to feel
# safe.) Its braces balance on a single line (`cleanup() { ...; }`) and it
# contains no `#`, so even without Pass H it would not have desynced
# anything today — but Pass H now makes that true STRUCTURALLY rather than
# by the heredoc's current, coincidental content.
#
# What makes an actual desync acceptable rather than a latent trap: the
# failure is loud, not silent. The two structural validations below
# hard-FAIL naming the sub if an extraction desyncs, and the B-B10
# cross-check fails if a `_gather_*` sub goes missing from the parsed node
# set. Nothing here degrades to a quiet skip — which is the one way a
# violator could hide (see also H-4(b) below, which closes the one place
# that WAS a quiet skip: an extraction failure inside an adapter's closure,
# not at the top level, used to silently drop that member's findings from
# the per-adapter tally even though the standalone failure above still
# fired).
sub _subs {
    my ($blanked) = @_;
    my %subs;
    while ($blanked =~ /^sub\s+([A-Za-z_]\w*)\s*\{/mg) {
        my $name       = $1;
        my $start_pos  = $-[0];
        my $before     = substr($blanked, 0, $start_pos);
        my $start_line = 1 + (() = $before =~ /\n/g);
        $subs{$name} = { start_line => $start_line, start_pos => $start_pos };
    }
    return \%subs;
}

# _get_body($name, $subs, $blanked, $cache, $failed, $reporter) -> the
# blanked body text for sub $name, brace-matched and VALIDATED (spec
# S2.2.2), memoized in $cache. A body that fails validation is a HARD
# failure naming the sub (B-B9), reported via $reporter (defaults to
# Test::More's real fail()) at most once per sub via $failed, never
# silently skipped, because a silent skip is exactly how a violator would
# hide. $reporter is a swap point used ONLY by the H-4(b) self-test below
# (section C), so a DELIBERATELY malformed synthetic fixture can drive this
# exact function and assert on the failure without a real fail() call
# turning THIS suite's own exit code red for an intentional fixture.
sub _get_body {
    my ($name, $subs, $blanked, $cache, $failed, $reporter) = @_;
    $reporter ||= \&fail;
    return $cache->{$name} if exists $cache->{$name};

    my $info = $subs->{$name};
    return undef unless $info;

    my $body = _balanced_braces($blanked, $info->{start_pos});
    my $ok   = 1;
    if (!defined $body) {
        $ok = 0;
    } else {
        my @lines = split /\n/, $body;
        # H-4(a): a genuine ONE-LINE sub body (e.g. `sub log_ev {
        # LaunchLog::event($LAUNCH_LOG, @_) }`, launcher.pl:773 — 11 such
        # subs exist in launcher.pl today) is a valid extraction even
        # though its single line is not "'}' alone at column 0" — it is
        # "... }" at the end of the line. Multi-line bodies still require
        # the last line to be a bare column-0 '}'.
        if (!@lines
            || ($lines[-1] !~ /^\}\s*$/
                && !(@lines == 1 && $lines[0] =~ /\}\s*$/))) {
            $ok = 0;                              # last line must be '}' at column 0
        } else {
            for my $i (1 .. $#lines) {
                if ($lines[$i] =~ /^sub\s+\w+/) {  # did not swallow the next sub
                    $ok = 0;
                    last;
                }
            }
        }
    }

    if (!$ok) {
        $reporter->("body extraction failed for sub '$name' (unbalanced braces, or the extracted "
           . "body did not end with a column-0 '}' (nor was it a valid one-line body), or it "
           . "swallowed a following 'sub' — see spec S2.2.2's validation rules) (B-B9)")
            unless $failed->{$name}++;
        $cache->{$name} = undef;
        return undef;
    }

    $cache->{$name} = $body;
    return $body;
}

# _edges_from($body, $all_names) -> @callee_names. Only SAME-FILE subs are
# nodes (spec S2.2.4) — a qualified call (Resources::gather(...)) or a
# method call ($x->foo(...)) is never an edge; the ':' in the lookbehind is
# what keeps `Resources::gather(` from linking to a hypothetical same-file
# `sub gather`.
sub _edges_from {
    my ($body, $all_names) = @_;
    my @callees;
    for my $v (@$all_names) {
        if ($body =~ /(?<![\w:>\$\@%&])\Q$v\E\s*\(/ || $body =~ /\\?&\s*\Q$v\E\b/) {
            push @callees, $v;
        }
    }
    return @callees;
}

# _closure($root, ..., $reporter) -> @members, an iterative worklist walk
# with a %seen{name} guard (spec S2.2.4), so a cycle (a calls b, b calls a)
# TERMINATES. The closure includes the root. $reporter is passed straight
# through to _get_body (see its doc comment) — optional, defaults to the
# real fail().
sub _closure {
    my ($root, $subs, $blanked, $all_names, $cache, $failed, $reporter) = @_;
    my %seen;
    my @queue = ($root);
    my @order;
    while (@queue) {
        my $name = shift @queue;
        next if $seen{$name}++;
        push @order, $name;
        my $body = _get_body($name, $subs, $blanked, $cache, $failed, $reporter);
        next unless defined $body;
        for my $v (_edges_from($body, $all_names)) {
            push @queue, $v unless $seen{$v};
        }
    }
    return @order;
}

# _spawns($body, $start_line) -> @findings, each
# { construct => <label>, line => <1-based line in launcher.pl>, snippet }.
# Runs on the BLANKED body (spec S2.2.3) — comments are already blanked, so
# a prose mention of "fork"/"backtick"/"spawn" cannot fire.
sub _spawns {
    my ($body, $start_line) = @_;
    my @findings;

    my $line_of = sub {
        my ($pos)  = @_;
        my $before = substr($body, 0, $pos);
        my $nl     = () = $before =~ /\n/g;
        return $start_line + $nl;
    };
    my $snippet_at = sub {
        my ($pos) = @_;
        my $ls = rindex($body, "\n", $pos);
        $ls = $ls < 0 ? 0 : $ls + 1;
        my $le = index($body, "\n", $pos);
        $le = length($body) if $le < 0;
        my $s = substr($body, $ls, $le - $ls);
        $s =~ s/^\s+|\s+$//g;
        return $s;
    };

    # backticks — any backtick character.
    while ($body =~ /`/g) {
        my $pos = $-[0];
        push @findings, { construct => 'backticks', line => $line_of->($pos), snippet => $snippet_at->($pos) };
    }
    # qx — quoted-word operator with any delimiter.
    while ($body =~ /(?<![\w:>\$\@%])qx\s*[\(\{\[<\/\|!#'"]/g) {
        my $pos = $-[0];
        push @findings, { construct => 'qx', line => $line_of->($pos), snippet => $snippet_at->($pos) };
    }
    # system — requires a call shape, so `podman system df` in a string never matches.
    while ($body =~ /(?<![\w:>\$\@%&-])system\s*(?:\(|['"\$\@])/g) {
        my $pos = $-[0];
        push @findings, { construct => 'system', line => $line_of->($pos), snippet => $snippet_at->($pos) };
    }
    # exec — so `podman exec -it ...` in a string never matches.
    while ($body =~ /(?<![\w:>\$\@%&-])exec\s*(?:\(|['"\$\@])/g) {
        my $pos = $-[0];
        push @findings, { construct => 'exec', line => $line_of->($pos), snippet => $snippet_at->($pos) };
    }
    # fork — covers fork(), fork;, = fork at EOL, defined(my $p = fork).
    while ($body =~ /(?<![\w:>\$\@%&-])fork\s*(?:\(|;|\)|,|$)/mg) {
        my $pos = $-[0];
        push @findings, { construct => 'fork', line => $line_of->($pos), snippet => $snippet_at->($pos) };
    }
    # readpipe — the named operator backticks are literal sugar for
    # (perlfunc). Uses the same lookbehind as the other bare-word
    # detectors above, so `Foo::readpipe(...)` (a qualified call to some
    # OTHER package's sub of that name) still cannot match (H-3).
    while ($body =~ /(?<![\w:>\$\@%&-])readpipe\b/g) {
        my $pos = $-[0];
        push @findings, { construct => 'readpipe', line => $line_of->($pos), snippet => $snippet_at->($pos) };
    }
    # CORE::-qualified builtins (H-3). Every lookbehind above deliberately
    # excludes a preceding ':' so `Resources::gather(` never links to a
    # same-file `sub gather` in _edges_from — but that same exclusion means
    # `CORE::system(...)` (preceded by the second ':' of 'CORE::') would
    # otherwise never match ANY of the patterns above. Rather than loosen
    # those shared lookbehinds (which would reopen the qualified-call hole
    # this whole guard depends on), CORE::-qualified forms get their own
    # explicit, unrelated pattern. No lookbehind needed here: 'CORE::' is
    # not a package a hypothetical same-file sub could plausibly be
    # confused with, and \b already stops '&CORE::system(...)' (the '&'
    # sigil) from hiding it, since \b matches the boundary right before 'C'
    # regardless of what precedes it.
    while ($body =~ /\bCORE::(system|exec|fork|readpipe)\b/g) {
        my $pos = $-[0];
        push @findings, { construct => $1, line => $line_of->($pos), snippet => $snippet_at->($pos) };
    }
    # open2/open3.
    while ($body =~ /(?<![\w:>\$\@%&-])open[23]\s*\(/g) {
        my $pos = $-[0];
        push @findings, { construct => 'open2/open3', line => $line_of->($pos), snippet => $snippet_at->($pos) };
    }
    while ($body =~ /IPC::Open[23]/g) {
        my $pos = $-[0];
        push @findings, { construct => 'open2/open3', line => $line_of->($pos), snippet => $snippet_at->($pos) };
    }
    # piped open — 2-arg and 3-arg, '-|' and '|-'. Only the SECOND argument
    # is examined, so `open my $fh, '<', "a|b"` cannot false-positive, and
    # it must not fire on the ordinary reads the conforming adapters already
    # do (_tail_lines, _gather_spend, _read_file's plain '<'/':raw' opens).
    #
    # H-5 widening over the original three-exact-alternation predicate:
    #   * arg-2 is now a prefix/suffix test, so a trailing I/O layer
    #     ('-|:encoding(UTF-8)', '|-:raw') still matches while plain '<',
    #     '<:raw', '>' and '>>' still cannot (none of those contain '|').
    #   * arg-2 may be qq?{...}-delimited, not just quote-delimited.
    #   * if arg-2 is a BARE SCALAR VARIABLE (mode not resolvable
    #     statically — e.g. `open my $fh, $mode, $PODMAN, 'stats'`, or the
    #     2-arg form `open my $fh, $cmd or return` where the whole command
    #     string, pipe-or-not, lives in a variable) this deliberately fails
    #     LOUD rather than silently missing it: we cannot prove such a call
    #     is safe, and a false positive here is a human seeing a named,
    #     line-numbered finding they can inspect (and waive, with a reason,
    #     if genuinely benign) — a false NEGATIVE would be a fork nobody
    #     sees. No such call exists in launcher.pl today (verified: every
    #     `open` in the file uses a literal mode string); this is
    #     forward-looking coverage for exactly the "$mode = platform switch"
    #     idiom a background sampler (package 03) might reach for.
    while ($body =~ /(?<![\w:>\$\@%&-])open\b/g) {
        my $mpos   = $-[0];
        my $limit  = $mpos + 300;
        my $semi   = index($body, ';', $mpos);
        my $winend = ($semi >= 0 && $semi < $limit) ? $semi : $limit;
        $winend = length($body) if $winend > length($body);
        my $window = substr($body, $mpos, $winend - $mpos);

        my $arg2;
        if ($window =~ /\bopen\b[^,;]*,\s*(['"])([^'"]*)\1/) {
            $arg2 = $2;
        } elsif ($window =~ /\bopen\b[^,;]*,\s*qq?\{([^}]*)\}/) {
            $arg2 = $1;
        }

        if (defined $arg2) {
            if ($arg2 =~ /^\s*-?\|/ || $arg2 =~ /^\s*\|-/ || $arg2 =~ /\|\s*$/) {
                push @findings, { construct => 'piped open', line => $line_of->($mpos), snippet => $snippet_at->($mpos) };
            }
        } elsif ($window =~ /\bopen\b[^,;]*,\s*(\$\w+)\b/) {
            push @findings, {
                construct => 'piped open (variable mode, flagged conservatively)',
                line      => $line_of->($mpos),
                snippet   => $snippet_at->($mpos),
            };
        }
    }

    # Dedup identical (construct, line) pairs: a single command-substitution
    # backtick pair produces two raw matches (open + close backtick) on the
    # same source line — report the violation once, not twice.
    my %seen_finding;
    return grep {
        my $key = "$_->{construct}|$_->{line}";
        !$seen_finding{$key}++;
    } @findings;
}

# _section($doc, $heading_pat) -> the text of the "^## <heading_pat>" section,
# from its heading line through the next "^## " heading or EOF (spec S2.1's
# "a section is the text from its heading to the next heading or EOF").
sub _section {
    my ($doc, $heading_pat) = @_;
    return undef unless $doc =~ /^##\s+$heading_pat.*$/m;
    my $start = $-[0];
    my $after = $+[0];
    my $rest  = substr($doc, $after);
    if ($rest =~ /^##\s+/m) {
        my $end_rel = $-[0];
        return substr($doc, $start, ($after - $start) + $end_rel);
    }
    return substr($doc, $start);
}

# ===========================================================================
# A. Doc (spec S3-A). Doc missing -> B-A1 fails and B-A2..B-A5 are SKIPped
# with a counted diag (B-A6). This block does NOT gate the launcher block
# below, which always runs.
#
# EXPECTED TODAY: plugins/sandbox/docs/tui-adapter-contract.md does not
# exist yet — the doc-writer runs next. So this block's failures/skips are
# the CORRECT red for this package right now, not a bug in this test.
# ===========================================================================
# $doc_text/$doc_present are declared at FILE scope (not just inside the
# SKIP block below) because H-7's waiver-corroboration check (section B)
# also needs the doc's '## Waivers' section text.
my ($doc_text, $doc_present);
SKIP: {
    $doc_text    = (-f $DOC) ? slurp($DOC) : undef;
    $doc_present = defined($doc_text) && length($doc_text) > 0;

    ok($doc_present, "doc: $DOC exists and is non-empty (B-A1)")
        or diag("  plugins/sandbox/docs/tui-adapter-contract.md has not been written yet");

    # KEEP IN SYNC with the assertion count in this block below:
    #   B-A2: 4 (one per Rule N heading)
    #   B-A3: 4 rules * (1 length + 3 patterns) = 16
    #   B-A4: 2 sections * (1 exists + 2 patterns) = 6
    #   B-A5: 1
    # total = 27
    my $SKIP_N = 27;
    skip("doc missing/unreadable at $DOC -- skipping $SKIP_N doc-content assertions (B-A2..B-A5); "
       . "the launcher-guard block below still runs", $SKIP_N)
        unless $doc_present;

    # B-A2: each Rule N heading exists, independently — no total asserted,
    # so a later Rule 5 must not turn this red.
    for my $n (1 .. 4) {
        ok($doc_text =~ /^##\s+Rule\s+$n\b/m, "doc: heading '## Rule $n' is present (B-A2)");
    }

    # B-A3: each Rule N section is >= 200 chars and matches ALL of its
    # required patterns (spec S2.1's table) — one assertion per pattern so a
    # failure names the rule AND the missing pattern.
    my %RULE_PATTERNS = (
        1 => [ [ qr/\bfork\b/i,           'fork'                 ],
               [ qr/\bspawn/i,            'spawn'                ],
               [ qr/render[- ]tick/i,     'render-tick'          ] ],
        2 => [ [ qr/\bread/i,             'read'                 ],
               [ qr/maintain/i,           'maintain'             ],
               [ qr/\bwrit/i,             'writ'                 ] ],
        3 => [ [ qr/fresh/i,              'fresh'                ],
               [ qr/stale/i,              'stale'                ],
               [ qr/timestamp|mtime|\bage\b/i, 'timestamp|mtime|age' ] ],
        4 => [ [ qr/absen/i,              'absen'                ],
               [ qr/broken/i,             'broken'               ],
               [ qr/distinguish/i,        'distinguish'          ] ],
    );
    for my $n (1 .. 4) {
        my $section = _section($doc_text, "Rule\\s+$n\\b");
        $section = '' unless defined $section;
        ok(length($section) >= 200, "doc: Rule $n section is >= 200 characters (B-A3)");
        for my $pat (@{ $RULE_PATTERNS{$n} }) {
            my ($re, $label) = @$pat;
            ok($section =~ $re, "doc: Rule $n section matches required pattern '$label' (B-A3)");
        }
    }

    # B-A4: Enforcement / Waivers sections exist and match their rows.
    my %SECTION_PATTERNS = (
        Enforcement => [ [ qr/62-tui-adapter-contract\.t/,   '62-tui-adapter-contract.t'   ],
                         [ qr/transitive|call graph|reachab/i, 'transitive|call graph|reachab' ] ],
        Waivers     => [ [ qr/waiv/i, 'waiv' ],
                         [ qr/\b03\b/, '03'  ] ],
    );
    for my $heading (qw(Enforcement Waivers)) {
        my $section = _section($doc_text, $heading);
        ok(defined($section) && length($section) > 0, "doc: '## $heading' section is present (B-A4)");
        $section = '' unless defined $section;
        for my $pat (@{ $SECTION_PATTERNS{$heading} }) {
            my ($re, $label) = @$pat;
            ok($section =~ $re, "doc: '## $heading' section matches required pattern '$label' (B-A4)");
        }
    }

    # B-A5: the worked example is named somewhere in the doc.
    ok($doc_text =~ /_gather_spend/, 'doc: mentions _gather_spend somewhere (B-A5)');
}

# ===========================================================================
# B. Guard over launcher.pl (spec S3-B). Runs regardless of the doc block.
# ===========================================================================

my $LAUNCHER_TEXT = (-f $LAUNCHER) ? slurp($LAUNCHER) : undef;
unless (defined $LAUNCHER_TEXT && length $LAUNCHER_TEXT) {
    BAIL_OUT("launcher.pl unreadable or empty at $LAUNCHER -- the guard is meaningless without it (B-B1)");
}
ok(1, "setup: launcher.pl was read as source text ($LAUNCHER) (B-B1)");

my $BLANKED = _blank_noncode($LAUNCHER_TEXT);

my $SUBS      = _subs($BLANKED);
my @ALL_NAMES = sort keys %$SUBS;
my @ADAPTERS  = sort grep { /^_gather_/ } @ALL_NAMES;

# B-B2: discovery floor -- the enforced set is WHATEVER DISCOVERY RETURNED;
# there is no hardcoded enforcement list anywhere in this file.
cmp_ok(scalar(@ADAPTERS), '>=', 1,
    'discovery: at least one _gather_* adapter sub was found in launcher.pl (B-B2, no hardcoded list)');

# B-B3: named-membership floor (NOT a shape pin -- spec S4 AC-6's "Why (b)
# is not a shape pin"). This forbids nothing from being ADDED; only
# DELETING one of these two named adapters can turn it red, and that IS a
# signal worth having (neither is scheduled for deletion by this blueprint).
ok((grep { $_ eq '_gather_spend' } @ADAPTERS) ? 1 : 0,
    'discovery floor: _gather_spend (the Rule-1 worked example, cited in this package Scope) is among the discovered adapters (B-B3)');
ok((grep { $_ eq '_gather_resources' } @ADAPTERS) ? 1 : 0,
    'discovery floor: _gather_resources (the waived violator, cited in done-criterion 4) is among the discovered adapters (B-B3)');

# B-B10: cross-check -- every _gather_* name found by a raw grep of the
# blanked source is present in the parsed node set from _subs().
my @raw_gather_names;
while ($BLANKED =~ /^sub\s+(_gather_\w+)/mg) {
    push @raw_gather_names, $1;
}
for my $name (@raw_gather_names) {
    ok(exists $SUBS->{$name},
        "cross-check: raw grep found 'sub $name', present in the parsed node set (B-B10)")
        or diag("  sub $name was matched by /^sub\\s+(_gather_\\w+)/mg but _subs() did not record it");
}

# ---------------------------------------------------------------------------
# WAIVER LIST — adapters known non-conforming when this guard was written.
#
# An entry keeps the suite GREEN for a violation we have already decided to fix
# elsewhere. It is not a pardon: the entry's REMOVAL is the on-disk proof that
# the fix landed. Two rules keep it from rotting:
#   * a waived adapter that is STILL violating -> reported, suite stays green;
#   * a waived adapter that is now CONFORMING  -> the suite goes RED as a STALE
#     WAIVER, so the fixing package cannot land green without deleting its entry.
# A waiver that silently outlives its violation is a hole, not a waiver.
#
# Do NOT add an entry to make a new adapter pass. Fix the adapter.
# ---------------------------------------------------------------------------
my %WAIVED = (
);

# _adapter_verdict($adapter, $subs, $blanked, $all_names, $waived, $reporter)
#   -> \%verdict { status => 'clean' | 'violation' | 'waived_violation'
#                         | 'stale_waiver' | 'extraction_unknown',
#                  findings => \@findings, failed_subs => \@names }
#
# Computes what B-B4..B-B9 would report for ONE adapter WITHOUT itself
# calling ok/fail/pass -- the caller decides how to report the verdict.
# This is NOT a body-local scan of the adapter alone -- see spec S1's
# "critical structural fact": _gather_resources's own body carries no spawn
# construct; the backticks live only in _resources_probes/_powershell_json,
# reached solely by following calls (spec S2.2.4).
#
# Split out (H-4(b) / reviewer SHOULD-FIX) so the SAME logic real
# launcher.pl uses (section B below) can also be driven, in section C,
# against a synthetic closure containing a deliberately malformed body --
# and asserted on via its returned status -- without a real fail() call
# from inside that deliberately-broken fixture turning THIS suite's own
# exit code red. $reporter defaults to Test::More's real \&fail and is
# threaded straight through to _get_body/_closure (see their doc comments);
# only the H-4(b) self-test substitutes a non-failing recorder.
#
# 'extraction_unknown' is itself H-4(b)'s fix: previously, a body-extraction
# failure anywhere in an adapter's closure fired ONE standalone, named
# fail() inside _get_body (B-B9) -- loud -- but the per-adapter tally below
# would then silently go on to report "zero forbidden-spawn findings" (or a
# "known non-conforming, here is the ONE finding we did see") for that same
# adapter, because _closure()/_get_body()'s "next unless defined $body"
# means the failed member's own findings AND its entire further subtree are
# simply missing from @findings. That reads as a clean bill of health for a
# subtree the guard admits it could not see -- a silent downgrade at the
# adapter-verdict level even though the sub-level failure was loud. Any
# extraction failure inside the closure now short-circuits straight to
# 'extraction_unknown' instead.
sub _adapter_verdict {
    my ($adapter, $subs, $blanked, $all_names, $waived, $reporter) = @_;
    $reporter ||= \&fail;
    my $cache  = {};
    my $failed = {};
    my @closure_members = _closure($adapter, $subs, $blanked, $all_names, $cache, $failed, $reporter);

    my @findings;
    for my $member (@closure_members) {
        my $body = _get_body($member, $subs, $blanked, $cache, $failed, $reporter);   # B-B9 fires here on failure
        next unless defined $body;
        for my $f (_spawns($body, $subs->{$member}{start_line})) {
            $f->{defining_sub} = $member;
            push @findings, $f;
        }
    }

    my @failed_subs = sort keys %$failed;
    if (@failed_subs) {
        return { status => 'extraction_unknown', findings => \@findings, failed_subs => \@failed_subs };
    }

    if (exists $waived->{$adapter}) {
        return { status => (@findings ? 'waived_violation' : 'stale_waiver'), findings => \@findings, failed_subs => [] };
    }
    return { status => (@findings ? 'violation' : 'clean'), findings => \@findings, failed_subs => [] };
}

# B-B4/B-B5/B-B6/B-B9(H-4b): per adapter, report the verdict computed above.
for my $adapter (@ADAPTERS) {
    my $v = _adapter_verdict($adapter, $SUBS, $BLANKED, \@ALL_NAMES, \%WAIVED);

    if ($v->{status} eq 'extraction_unknown') {
        # H-4(b): loud, and DISTINCT from a clean/waived pass -- see
        # _adapter_verdict's doc comment above for why this branch exists.
        fail(sprintf(
            "%s: body extraction failed for %s inside this adapter's transitive closure -- "
          . "conformance is UNKNOWN, not proven (the standalone body-extraction failure above "
          . "names the exact sub, B-B9); this adapter's own findings may be incomplete because "
          . "that sub's subtree could not be walked (H-4b)",
            $adapter, join(', ', @{ $v->{failed_subs} })));
        next;
    }

    if ($v->{status} eq 'waived_violation') {
        # B-B5: still violating, waived -- suite stays green.
        my $f = $v->{findings}[0];
        pass(sprintf(
            "%s: known non-conforming (waived) -- forbidden spawn `%s` reached via %s at launcher.pl:%d -- %s",
            $adapter, $f->{construct}, $f->{defining_sub}, $f->{line}, $WAIVED{$adapter}));
        for my $g (@{ $v->{findings} }) {
            diag(sprintf("  %s: %s reached via %s at launcher.pl:%d -- %s",
                $adapter, $g->{construct}, $g->{defining_sub}, $g->{line}, $g->{snippet}));
        }
    } elsif ($v->{status} eq 'stale_waiver') {
        # B-B6: stale waiver -- now conforming, per THIS same-file guard.
        # H-1: the message used to unconditionally instruct deleting the
        # %WAIVED entry, reading "zero findings" as "the fix landed". It
        # isn't -- this guard is same-file only (spec S6, declined on the
        # record), so "zero findings" ALSO means "the spawn moved behind a
        # module boundary this guard cannot see" (Resources.pm/RunState.pm,
        # a coderef, a string-dispatched call). Package 03's cheapest
        # refactor -- moving the probe bodies into Resources.pm -- produces
        # exactly this same "zero findings" result while the fork is still
        # on the render tick. Deletion is valid ONLY together with package
        # 03's own done-criteria 1 and 4, never on this test's silence alone.
        fail(sprintf(
            "%s: STALE WAIVER -- zero forbidden-spawn findings across its transitive SAME-FILE "
          . "closure. Before deleting the %%WAIVED entry for %s: this guard cannot see a spawn "
          . "moved behind a module boundary (Resources.pm/RunState.pm), a coderef, or a "
          . "string-dispatched call -- zero findings here is necessary but NOT sufficient proof "
          . "the fork left the render tick. Deletion is valid together with package "
          . "03-resources-reader-model's own done-criteria 1 (the sampler writes a snapshot; "
          . "%s only reads, no spawn of any kind) and 4 (probe starvation off the render tick, "
          . "proven by its own slow-probe test) -- not on this test's silence by itself.",
            $adapter, $adapter, $adapter));
    } elsif ($v->{status} eq 'violation') {
        # B-B4: real, non-waived violation.
        my $f = $v->{findings}[0];
        fail(sprintf(
            "%s: forbidden spawn `%s` reached via %s at launcher.pl:%d -- an adapter must not "
          . "fork, spawn or block on the render tick (docs/tui-adapter-contract.md Rule 1)",
            $adapter, $f->{construct}, $f->{defining_sub}, $f->{line}));
        for my $g (@{ $v->{findings} }) {
            diag(sprintf("  %s: %s reached via %s at launcher.pl:%d -- %s",
                $adapter, $g->{construct}, $g->{defining_sub}, $g->{line}, $g->{snippet}));
        }
    } else {
        ok(1, "$adapter: zero forbidden-spawn findings across its transitive same-file call closure (B-B4)");
    }
}

# B-B7/B-B8: waiver hygiene -- every key names a currently-discovered
# adapter (else it is a stale/unknown waiver), every reason is >= 20 chars
# and names package 03. Deliberately NO assertion anywhere on %WAIVED's size
# or non-emptiness (AC-8) -- package 03 legitimately empties this hash and
# must stay green when it does.
#
# H-7: additionally, every key must be named inside the doc's '## Waivers'
# section text -- widening %WAIVED is meant to be a DOCUMENTED act, not a
# one-line test edit, and none of B-B7/B-B8 (both satisfiable by the same
# edit that adds the entry) prevented that. Still non-counting -- it checks
# NAMES, not a total -- and trivially satisfied when %WAIVED is empty, so
# package 03 deleting its entry stays green with no doc edit required.
# Skipped (not failed) when the doc itself is missing/unreadable, matching
# B-A6's posture: the launcher guard must still mean something standalone.
my $waivers_section = $doc_present ? _section($doc_text, 'Waivers') : undef;
$waivers_section = '' unless defined $waivers_section;
for my $key (sort keys %WAIVED) {
    my $reason = $WAIVED{$key};
    ok((grep { $_ eq $key } @ADAPTERS) ? 1 : 0,
        "waiver key check: %WAIVED key '$key' names a currently-discovered adapter, not a stale/unknown one (B-B7)")
        or diag("  '$key' is not in \@ADAPTERS -- it was renamed or deleted and the waiver was left behind");
    ok((defined($reason) && length($reason) >= 20 && $reason =~ /\b03\b/) ? 1 : 0,
        "waiver hygiene: %WAIVED{$key} reason is >= 20 chars and names package 03 (B-B8)")
        or diag("  reason was: " . (defined $reason ? $reason : '<undef>'));
  SKIP: {
        skip("doc missing/unreadable at $DOC -- skipping H-7's waiver-corroboration check for '$key'", 1)
            unless $doc_present;
        ok(index($waivers_section, $key) >= 0,
            "waiver corroboration: %WAIVED key '$key' is named in docs/tui-adapter-contract.md's '## Waivers' section (H-7)")
            or diag("  '$key' does not appear in the doc's Waivers section text -- widening %WAIVED is meant to be a documented act, not a one-line test edit");
    }
}

# AC-11 housekeeping: this package never edits launcher.pl -- confirm the
# copy on disk is still exactly what B-B1 read, i.e. this guard is read-only.
is(slurp($LAUNCHER), $LAUNCHER_TEXT,
    'housekeeping: launcher.pl on disk is unchanged by running this guard (AC-11)');

# ===========================================================================
# C. Analyser self-test — synthetic fixture (spec S3-C). Independent of
# launcher.pl's current content: this is the STALE-PROOF non-vacuity proof.
# ===========================================================================
{
    my $fixture_src = <<'FIXTURE_SRC';
sub _gather_clean {
    my $p = shift;
    open my $fh, '<', $p or return;
    close $fh;
    open my $fh2, '<:raw', $p or return;
    close $fh2;
    return 1;
}

sub _gather_direct {
    my $out = `echo hi`;
    return $out;
}

sub _hop_a {
    return _hop_b();
}

sub _hop_b {
    my $out = `echo hop`;
    return $out;
}

sub _gather_twohop {
    return _hop_a();
}

sub _cyc_a {
    return _cyc_b();
}

sub _cyc_b {
    system("x");
    return _cyc_a();
}

sub _gather_cycle {
    return _cyc_a();
}

sub _gather_prose {
    # we must never fork, spawn or use backticks here
    my $x = 1;  # no backticks
    return $x;
}

sub _gather_pipes {
    open(my $fh, '-|', 'x');
    return $fh;
}

sub gather_stuff {
    my $out = `echo qualified`;
    return $out;
}

sub _gather_qualified {
    return Other::gather_stuff(1);
}

sub _unreached_dirty {
    my $out = `echo unreached`;
    return $out;
}

sub _gather_pipe2 {
    open(FH, "cmd |");
    return 1;
}

sub _gather_heredoc {
    my $script = <<'BASH';
HB=""
# start the heartbeat block {
  echo hi
}
BASH
    my $out = `podman stats`;
    return $out;
}

sub _gather_readpipe {
    my $o = readpipe "echo hi";
    return $o;
}

sub _gather_core_system {
    CORE::system("x");
    return 1;
}

sub _gather_core_exec {
    CORE::exec("x");
    return 1;
}

sub _gather_core_fork {
    CORE::fork();
    return 1;
}

sub _gather_core_readpipe {
    my $o = CORE::readpipe("x");
    return $o;
}

sub _gather_oneliner {
    return _one_liner();
}

sub _one_liner { return `x`; }

sub _gather_pipe_layer {
    open my $fh, '-|:encoding(UTF-8)', 'x';
    return $fh;
}

sub _gather_pipe_qq {
    open my $fh, qq{-|}, 'x';
    return $fh;
}

sub _gather_pipe_var {
    my $mode = '-|';
    open my $fh, $mode, 'x';
    return $fh;
}

sub _gather_pipe_2arg_var {
    my $cmd = "x |";
    open my $fh, $cmd or return;
    return $fh;
}
FIXTURE_SRC

    my $tmpdir        = tempdir(CLEANUP => 1);
    my $fixture_path  = "$tmpdir/fixture-launcher.pl";
    open my $wfh, '>', $fixture_path or die "fixture setup: cannot write $fixture_path: $!";
    print $wfh $fixture_src;
    close $wfh;

    my $fixture_text = slurp($fixture_path);
    ok(defined($fixture_text) && length($fixture_text) > 0,
        'fixture: setup -- synthetic file was written and read back under File::Temp');

    my $fblanked   = _blank_noncode($fixture_text);
    my $fsubs      = _subs($fblanked);
    my @fall_names = sort keys %$fsubs;

    for my $root (qw(_gather_clean _gather_direct _gather_twohop _gather_cycle
                      _gather_prose _gather_pipes _gather_qualified _gather_pipe2
                      _gather_heredoc _gather_readpipe _gather_core_system
                      _gather_core_exec _gather_core_fork _gather_core_readpipe
                      _gather_oneliner _gather_pipe_layer _gather_pipe_qq
                      _gather_pipe_var _gather_pipe_2arg_var)) {
        ok(exists $fsubs->{$root}, "fixture: sub $root was discovered by _subs()");
    }

    my $fcache  = {};
    my $ffailed = {};
    my %fcl_cache;   # root -> \@findings, memoized so a closure isn't recomputed per row
    my $findings_for = sub {
        my ($root) = @_;
        return @{ $fcl_cache{$root} } if exists $fcl_cache{$root};
        my @members = _closure($root, $fsubs, $fblanked, \@fall_names, $fcache, $ffailed);
        my @f;
        for my $m (@members) {
            my $body = _get_body($m, $fsubs, $fblanked, $fcache, $ffailed);
            next unless defined $body;
            for my $find (_spawns($body, $fsubs->{$m}{start_line})) {
                $find->{defining_sub} = $m;
                push @f, $find;
            }
        }
        $fcl_cache{$root} = \@f;
        return @f;
    };

    # _gather_clean: only '<' / '<:raw' reads -> no finding.
    my @f_clean = $findings_for->('_gather_clean');
    is(scalar(@f_clean), 0,
        'fixture: _gather_clean (plain and :raw reads only) yields no spawn finding');

    # _gather_direct: a backtick in its own body.
    my @f_direct = $findings_for->('_gather_direct');
    ok((grep { $_->{construct} eq 'backticks' && $_->{defining_sub} eq '_gather_direct' } @f_direct) ? 1 : 0,
        'fixture: _gather_direct -- backticks finding attributed to _gather_direct itself');

    # _gather_twohop -> _hop_a -> _hop_b (the backtick).
    my @f_twohop = $findings_for->('_gather_twohop');
    ok((grep { $_->{construct} eq 'backticks' && $_->{defining_sub} eq '_hop_b' } @f_twohop) ? 1 : 0,
        'fixture: _gather_twohop -- two-hop closure reaches the backtick defined in _hop_b');

    # _gather_cycle -> _cyc_a <-> _cyc_b (cycle), system() lives in _cyc_b.
    # If _closure()'s %seen guard were missing, the call above (already
    # made, via $findings_for) would never have returned -- the worklist
    # would grow forever chasing _cyc_a <-> _cyc_b. No alarm/timeout
    # machinery is used anywhere in this file; simply reaching this
    # assertion IS the termination proof (spec S3-C's B-C2), structural
    # rather than monitored.
    my @f_cycle = $findings_for->('_gather_cycle');
    ok((grep { $_->{construct} eq 'system' && $_->{defining_sub} eq '_cyc_b' } @f_cycle) ? 1 : 0,
        'fixture: _gather_cycle -- cyclic closure terminates (structural %seen guard) and still finds the system() in _cyc_b');

    # _gather_prose: comment-only mentions of fork/spawn/backticks -> no finding.
    my @f_prose = $findings_for->('_gather_prose');
    is(scalar(@f_prose), 0,
        'fixture: _gather_prose -- full-line and trailing comments mentioning fork/backticks/spawn are blanked, no false-positive finding');

    # _gather_pipes: 3-arg '-|' piped open.
    my @f_pipes = $findings_for->('_gather_pipes');
    ok((grep { $_->{construct} eq 'piped open' && $_->{defining_sub} eq '_gather_pipes' } @f_pipes) ? 1 : 0,
        q{fixture: _gather_pipes -- open(my $fh, '-|', 'x') is detected as piped open});

    # _gather_qualified: Other::gather_stuff(...) is a QUALIFIED call, not a
    # same-file edge, so the same-file gather_stuff's backtick is never reached.
    my @f_qualified = $findings_for->('_gather_qualified');
    is(scalar(@f_qualified), 0,
        'fixture: _gather_qualified -- a qualified call (Other::gather_stuff) is not a same-file edge, so its backtick is never reached');

    # _unreached_dirty: a backtick reachable from no adapter -> never
    # surfaces as a finding for ANY fixture adapter.
    my @fixture_adapters  = grep { /^_gather_/ } @fall_names;
    my $unreached_leaked  = 0;
    for my $r (@fixture_adapters) {
        my @f = $findings_for->($r);
        $unreached_leaked = 1 if grep { $_->{defining_sub} eq '_unreached_dirty' } @f;
    }
    ok(!$unreached_leaked,
        'fixture: _unreached_dirty -- a backtick in a sub reachable from no adapter never surfaces as a finding');

    # _gather_pipe2: 2-arg pipe-at-end-of-string form.
    my @f_pipe2 = $findings_for->('_gather_pipe2');
    ok((grep { $_->{construct} eq 'piped open' && $_->{defining_sub} eq '_gather_pipe2' } @f_pipe2) ? 1 : 0,
        q{fixture: _gather_pipe2 -- open(FH, "cmd |") (2-arg pipe form) is detected as piped open});

    # _gather_heredoc (H-2): a heredoc containing a lone column-0 '}' (and a
    # '#' line with a brace, which would otherwise be blanked by the
    # comment pass and desync the count) must NOT truncate the body -- the
    # backtick AFTER the heredoc must still be found.
    my @f_heredoc = $findings_for->('_gather_heredoc');
    ok((grep { $_->{construct} eq 'backticks' && $_->{defining_sub} eq '_gather_heredoc' } @f_heredoc) ? 1 : 0,
        'fixture: _gather_heredoc (H-2) -- a heredoc with a lone column-0 "}" does not truncate the body; the backtick reached AFTER the heredoc is still found');

    # readpipe (H-3): the named operator backticks are literal sugar for.
    my @f_readpipe = $findings_for->('_gather_readpipe');
    ok((grep { $_->{construct} eq 'readpipe' && $_->{defining_sub} eq '_gather_readpipe' } @f_readpipe) ? 1 : 0,
        'fixture: _gather_readpipe (H-3) -- readpipe EXPR is detected');

    # CORE::-qualified builtins (H-3) -- every other lookbehind's leading
    # ':' exclusion would otherwise hide all four of these.
    my @f_core_system = $findings_for->('_gather_core_system');
    ok((grep { $_->{construct} eq 'system' && $_->{defining_sub} eq '_gather_core_system' } @f_core_system) ? 1 : 0,
        'fixture: _gather_core_system (H-3) -- CORE::system(...) is detected');
    my @f_core_exec = $findings_for->('_gather_core_exec');
    ok((grep { $_->{construct} eq 'exec' && $_->{defining_sub} eq '_gather_core_exec' } @f_core_exec) ? 1 : 0,
        'fixture: _gather_core_exec (H-3) -- CORE::exec(...) is detected');
    my @f_core_fork = $findings_for->('_gather_core_fork');
    ok((grep { $_->{construct} eq 'fork' && $_->{defining_sub} eq '_gather_core_fork' } @f_core_fork) ? 1 : 0,
        'fixture: _gather_core_fork (H-3) -- CORE::fork() is detected');
    my @f_core_readpipe = $findings_for->('_gather_core_readpipe');
    ok((grep { $_->{construct} eq 'readpipe' && $_->{defining_sub} eq '_gather_core_readpipe' } @f_core_readpipe) ? 1 : 0,
        'fixture: _gather_core_readpipe (H-3) -- CORE::readpipe(...) is detected');

    # _gather_oneliner (H-4a): a genuine ONE-LINE sub body must extract
    # successfully -- proving it is neither a false body-extraction failure
    # nor a silently pruned subtree.
    my @f_oneliner = $findings_for->('_gather_oneliner');
    ok((grep { $_->{construct} eq 'backticks' && $_->{defining_sub} eq '_one_liner' } @f_oneliner) ? 1 : 0,
        q{fixture: _gather_oneliner (H-4a) -- a genuine one-line sub body (sub _one_liner { return `x`; }) extracts successfully and its backtick is reached});

    # H-5: widened piped-open coverage.
    my @f_pipe_layer = $findings_for->('_gather_pipe_layer');
    ok((grep { $_->{construct} eq 'piped open' && $_->{defining_sub} eq '_gather_pipe_layer' } @f_pipe_layer) ? 1 : 0,
        q{fixture: _gather_pipe_layer (H-5) -- open my $fh, '-|:encoding(UTF-8)', 'x' (mode plus an I/O layer) is detected as piped open});
    my @f_pipe_qq = $findings_for->('_gather_pipe_qq');
    ok((grep { $_->{construct} eq 'piped open' && $_->{defining_sub} eq '_gather_pipe_qq' } @f_pipe_qq) ? 1 : 0,
        q{fixture: _gather_pipe_qq (H-5) -- open my $fh, qq{-|}, 'x' (qq{}-delimited mode) is detected as piped open});
    my @f_pipe_var = $findings_for->('_gather_pipe_var');
    ok((grep { $_->{construct} eq 'piped open (variable mode, flagged conservatively)' && $_->{defining_sub} eq '_gather_pipe_var' } @f_pipe_var) ? 1 : 0,
        q{fixture: _gather_pipe_var (H-5) -- open my $fh, $mode, 'x' (mode held in a variable, not statically resolvable) fails LOUD rather than being silently missed});
    my @f_pipe_2arg_var = $findings_for->('_gather_pipe_2arg_var');
    ok((grep { $_->{construct} eq 'piped open (variable mode, flagged conservatively)' && $_->{defining_sub} eq '_gather_pipe_2arg_var' } @f_pipe_2arg_var) ? 1 : 0,
        q{fixture: _gather_pipe_2arg_var (H-5) -- open my $fh, $cmd or return (2-arg form, command string held in a variable) fails LOUD rather than being silently missed});
}

# ===========================================================================
# D. H-4(b) / reviewer SHOULD-FIX — malformed-body extraction failure path.
# A SEPARATE synthetic fixture (deliberately malformed, so it cannot share
# the well-formed fixture above) drives _adapter_verdict() -- the EXACT
# function section B uses against real launcher.pl -- with a RECORDING
# reporter in place of the real fail(), proving BOTH halves of B-B9's
# "never a silent skip" claim: (1) the malformed sub is named in a loud
# failure, and (2) the OWNING adapter's verdict is 'extraction_unknown',
# never a misleadingly clean/waived pass -- the actual hazard the spec's
# "never a silent skip" language defends against (reviewer SHOULD-FIX).
# ===========================================================================
{
    my $broken_src = <<'BROKEN_SRC';
sub _gather_broken {
    return _broken_helper();
}

sub _broken_helper {
    my $x = 1;
    return $x; }
BROKEN_SRC

    my $btmpdir = tempdir(CLEANUP => 1);
    my $bpath   = "$btmpdir/fixture-broken.pl";
    open my $bwfh, '>', $bpath or die "fixture setup: cannot write $bpath: $!";
    print $bwfh $broken_src;
    close $bwfh;

    my $btext = slurp($bpath);
    ok(defined($btext) && length($btext) > 0,
        'fixture: H-4b setup -- the deliberately-malformed synthetic file was written and read back under File::Temp');

    my $bblanked = _blank_noncode($btext);
    my $bsubs    = _subs($bblanked);
    my @ball     = sort keys %$bsubs;

    ok((exists $bsubs->{_gather_broken} && exists $bsubs->{_broken_helper}) ? 1 : 0,
        'fixture: H-4b -- both _gather_broken and _broken_helper were discovered by _subs() (the malformation is in body EXTRACTION, not sub discovery)');

    my @captured_fails;
    my $recorder = sub { push @captured_fails, "@_"; };

    my $v = _adapter_verdict('_gather_broken', $bsubs, $bblanked, \@ball, {}, $recorder);

    ok((grep { /_broken_helper/ } @captured_fails) ? 1 : 0,
        'fixture: H-4b -- a malformed body (_broken_helper: last line "return $x; }" is not a bare column-0 "}") fires a named body-extraction failure (B-B9)');

    is($v->{status}, 'extraction_unknown',
        'fixture: H-4b -- an adapter whose closure contains a malformed body is reported as conformance UNKNOWN, never a misleadingly clean or waived verdict');

    is(scalar(@{ $v->{failed_subs} }), 1,
        'fixture: H-4b -- exactly the one malformed sub is named in failed_subs (fixture-local count)');
    is($v->{failed_subs}[0], '_broken_helper',
        'fixture: H-4b -- failed_subs names _broken_helper specifically');
}

done_testing();
