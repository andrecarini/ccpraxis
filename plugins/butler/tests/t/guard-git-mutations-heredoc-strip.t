#!/usr/bin/env perl
# platform: any
# 170 -- oracle for t09-guard-hooks-stripping's
# guard-git-mutations.sh changes (spec .ccpraxis-local-data/blueprints/
# tui-operator-feedback/specs/t09-guard-hooks-stripping-spec.md SS0/SS2.4/SS3/SS4).
#
# WRITTEN BLIND TO THE IMPLEMENTATION -- from the spec only. guard-git-mutations.sh
# does not yet call bp_strip_shell_noise at the time this file is authored; every AC
# below that depends on the new heredoc-only branch is expected to FAIL against the
# pre-fix tree (the live false positive, AC12, is denied instead of allowed today),
# and every regression-lock AC is expected to PASS unchanged both before and after
# (that is the evidence a real invocation is still blocked).
#
# guard-git-mutations-quote-mask.t is a FOREIGN, already-closed package's oracle
# (a02) and is treated here as READ-ONLY reference, never edited. This file adds NEW
# coverage the t09 spec specifically calls for: the heredoc-only live instance (AC12),
# the carrier+heredoc composition (AC16), an explicit re-pin of the AC-18/AC15 shellword
# family (per the t09 test-writer brief: "pin the shellword case bash -c \"<mutation>\"
# explicitly"), the bp_strip_shell_noise-unavailable degrade (AC17), and two structural
# ACs (AC2: bp_strip_shell_noise byte-identical; AC4: the three-state walk and anchor
# selection byte-identical) via literal substring pins captured from the PRE-FIX tree.
#
# ADDENDUM -- package 08-guard-git-mutations-heredoc-false-positive (blueprint
# tooling-backlog), spec .ccpraxis-local-data/blueprints/tooling-backlog/specs/
# 08-guard-git-mutations-heredoc-false-positive-spec.md. Adds P8-AC-1..P8-AC-21 (the
# "P8-" prefix avoids colliding with this file's own pre-existing AC12/AC13/AC15/AC16
# labels, which name unrelated t09 cases): P8-AC-1..7 are new false-positive
# reproducers for _heredoc_write_only_outer($cmd), each EXPECTED TO FAIL (wrongly
# DENIED) against the pre-fix module; P8-AC-8..21 are "must still DENY" regression
# pins for piped/fed-to-a-shell and write-then-execute-in-the-same-command shapes,
# built ONLY from shapes the unmodified module already denies (Decision 45) -- none
# of them invents a new gap for the implementer to close.
#
# TECHNIQUE NOTE (guard evasion). guard-git-mutations.sh is UNGATED and denies any Bash
# tool_input.command matching its own patterns -- including THIS SESSION's own Bash
# calls. Every fixture below reaches the hook only as JSON payload TEXT written to a
# temp file by the Write tool (never as literal text in a Bash tool_input.command this
# session issues), and the hook is invoked as a subprocess via `bash "$GPATH" < "$PFILE"`
# -- exactly 106's own technique, verified safe by 106 already running green in this
# session's history.
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP;
use File::Copy qw(copy);
use Time::HiRes qw(time);

(my $HOOKS = "$Bin/../../hooks")   =~ s{\\}{/}g;
(my $SCRIPTS = "$Bin/../../scripts") =~ s{\\}{/}g;
my $GUARD  = "$HOOKS/guard-git-mutations.sh";
my $BPLIB  = "$SCRIPTS/bp-lib.sh";

ok(-f $GUARD, 'guard-git-mutations.sh exists') or BAIL_OUT('subject hook missing');
ok(-f $BPLIB, 'scripts/bp-lib.sh exists (bp_strip_shell_noise lives here)') or BAIL_OUT('bp-lib.sh missing');

my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

my $pn = 0;
sub run_guard_at {
    my ($guard_path, $cmd, %extra_env) = @_;
    my $n = ++$pn;
    my $payload = $J->encode({ tool_name => 'Bash', tool_input => { command => $cmd } });
    my $pf = "$ROOT/payload.$n.json";
    open my $w, '>', $pf or die; print $w $payload; close $w;
    local %ENV = (%CLEAN_ENV, %extra_env, GPATH => fwd($guard_path), PFILE => fwd($pf));
    open(my $f, '-|', 'bash', '-c', '"$GPATH" < "$PFILE" 2>&1') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    return ($? >> 8, $o);
}
sub run_guard { my ($cmd) = @_; return run_guard_at($GUARD, $cmd) }

# run_guard_with_payload($cmd, %extra_top_level_keys) -- sibling of run_guard
# that merges extra top-level payload keys (e.g. agent_id) alongside
# tool_name/tool_input, per spec 08 AC-7's need to exercise a subagent caller.
sub run_guard_with_payload {
    my ($cmd, %extra) = @_;
    my $n = ++$pn;
    my %payload = (tool_name => 'Bash', tool_input => { command => $cmd }, %extra);
    my $pf = "$ROOT/payload.$n.json";
    open my $w, '>', $pf or die; print $w $J->encode(\%payload); close $w;
    local %ENV = (%CLEAN_ENV, GPATH => fwd($GUARD), PFILE => fwd($pf));
    open(my $f, '-|', 'bash', '-c', '"$GPATH" < "$PFILE" 2>&1') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    return ($? >> 8, $o);
}

# =====================================================================================
# AC12 (DC4, observable behavior 8 -- THE LIVE INSTANCE)
# =====================================================================================
{
    my $cmd = qq{cat <<EOF > report.md\n... this describes why git stash is forbidden and git reset --hard destroyed a fix-batch ...\nEOF\nperl file-report.pl report.md};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 0, 'AC12: heredoc body merely MENTIONING forbidden verbs, no git invocation anywhere, is ALLOWED (the live instance)')
        or diag("hook output: $out; command was:\n$cmd");
}

# =====================================================================================
# AC13 (DC3, observable behavior 9) -- a real mutation textually adjacent to an
# UNRELATED heredoc elsewhere in the same command must still DENY.
# =====================================================================================
{
    my $cmd = qq{git stash ; cat <<EOF\nfoo\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'AC13: real "git stash" with an unrelated heredoc elsewhere in the command is DENIED')
        or diag("hook output: $out; command was:\n$cmd");
    like($out, qr/\Qgit stash\E/, 'AC13: denial "Command:" text shows the full RAW command (git stash present verbatim)');
}

# =====================================================================================
# AC16 (DC3, observable behavior 9/carrier composition) -- BOTH a bare carrier
# ($(...)) AND a heredoc marker in the same command: the carrier re-check must
# escalate the new heredoc branch to fully-raw, per spec SS2.4's own trace.
# =====================================================================================
{
    my $cmd = qq{echo \$(git reset --hard) ; cat <<EOF\nfoo\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'AC16: a command with BOTH a bare $(...) carrier and a heredoc marker is DENIED via carrier re-check escalation')
        or diag("hook output: $out; command was:\n$cmd");
}

# =====================================================================================
# AC15 (DC3, observable behavior 11 -- regression lock, AC-18 family) -- explicit
# re-pin per the test-writer brief: these must NOT regress. Redundant with 106's own
# AC-18 block by design -- verified independently here rather than assumed.
# =====================================================================================
for my $row (
    [ 'bash -c "git stash"'          => q{bash -c "git stash"} ],
    [ q{sh -c 'git reset --hard'}    => q{sh -c 'git reset --hard'} ],
    [ 'echo `git stash`'             => q{echo `git stash`} ],
    [ 'echo $(git reset --hard)'     => q{echo $(git reset --hard)} ],
) {
    my ($label, $cmd) = @$row;
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, "AC15 (pinned): $label is still DENIED after the heredoc-only fix")
        or diag("hook output: $out");
}

# =====================================================================================
# AC17/AC1/AC2/AC4 -- REMOVED (package 16 batch-B fix round). All four pinned literal
# bash source that no longer exists: guard-git-mutations.sh is now an exec shim into
# BpHook::Guards::GuardGitMutations (plugins/butler/scripts/BpHook/Guards/
# GuardGitMutations.pm), which uses BpHook::Guards::Shell::strip_noise -- a real perl
# module always require'd in-process, so AC17's "bp-lib.sh unreachable from a sibling
# hooks/ tree" failure mode cannot occur any more (the old shared bash guard library
# AC17 copied into its fixture is itself on the deletion list). guards-remake-git-mutations.t
# already documents this exact non-re-expression with reason codes, in its own header:
#   AC1  -> SRC   (header rationale text, no longer at that site)
#   AC2  -> LIB   (bp_strip_shell_noise SHA-1 pin against bp-lib.sh, a file this
#                  package never edits)
#   AC4  -> SRC   (git_scan_target's bash source, pinned as a literal substring)
#   AC17 -> OTHER (Guards::Shell is a real perl module, always require'd in-process
#                  by GuardHarness; there is no "sibling script missing" failure mode
#                  to reproduce)
# The underlying behaviors (heredoc-only mentions allow, real invocations with a
# heredoc elsewhere still deny, shellword/carrier escalation, quote-mask corpus) are
# re-expressed behaviorally in guards-remake-git-mutations.t's GG-1 corpus, which is
# explicitly built from "git-mutation-guard-reach.t section C, guard-git-mutations-
# quote-mask.t, guard-git-mutations-heredoc-strip.t (minus AC1/AC2/AC4/AC17...) and
# guard-prose-not-invocation.t". No behavior assertion is weakened.
# =====================================================================================
# Package 08 (guard-git-mutations-heredoc-false-positive), spec
# .ccpraxis-local-data/blueprints/tooling-backlog/specs/
# 08-guard-git-mutations-heredoc-false-positive-spec.md.
#
# _heredoc_write_only_outer($cmd) is a new predicate: when EVERY heredoc in $cmd is a
# terminated, allow-listed, write-only-to-a-file heredoc (cat/mkdir/ls/wc/head/tail/
# echo/printf/cd/pwd/true only, no command substitution, no process substitution), the
# existing scan pipeline runs on the command with heredoc BODIES cut out instead of the
# raw command. Labelled "P8-AC-N" below (spec table AC-N) to avoid colliding with this
# file's own pre-existing AC12/AC13/AC15/AC16 labels, which name unrelated cases.
#
# P8-AC-1..P8-AC-7 are the false-positive reproducers (DC1): each hits exactly one of
# the raw-fallback triggers the spec traces (backslash, '#'-plus-unquoted-opener,
# toolong, subagent raw-scan) on a heredoc that ONLY writes to a file. WRITTEN BLIND TO
# THE IMPLEMENTATION: each is EXPECTED TO FAIL (DENY, rc=2) against the pre-fix module,
# confirmed by hand via a throwaway probe against the unmodified tree before being
# committed here (see test-writer-1.md's AC-0 baseline).
#
# P8-AC-8..P8-AC-21 are "must still DENY" regression pins: piped/fed-into-a-shell (DC2)
# and write-then-execute-in-the-same-command (DC3) shapes. Per Decision 45, every shape
# here is one today's guard ALREADY denies (confirmed against the unmodified module) --
# none of these invents a new gap for the implementer to close.
# =====================================================================================

# ---- P8-AC-1 (DC1): backslash inside a write-only heredoc body, quoted delimiter ----
{
    my $cmd = qq{cat > probe.pl <<'EOF'\nprint "ok\\n";\n# never run git stash here\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 0, 'P8-AC-1: backslash inside a write-only (quoted-delimiter) heredoc body is ALLOWED')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-2 (DC1): append (>>), unquoted delimiter, backslash in body -------------
{
    my $cmd = qq{cat <<EOF >> notes.md\nsee C:\\temp\ngit reset --hard is what destroyed it\nEOF\n};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 0, 'P8-AC-2: >> redirect with an unquoted delimiter and a backslash in the body is ALLOWED')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-3 (DC1): '#' plus unquoted heredoc opener, write-only ------------------
{
    my $cmd = qq{cat <<EOF > notes.md\n# why git stash is banned\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 0, 'P8-AC-3: a "#" comment line inside an unquoted-opener write-only heredoc is ALLOWED')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-4 (DC1): allow-listed chain (mkdir && cat > ...) ------------------------
{
    my $cmd = qq{mkdir -p out && cat > out/r.md <<'EOF'\nfoo\\bar then git checkout main\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 0, 'P8-AC-4: an allow-listed "mkdir && cat > ..." chain with a backslash in the body is ALLOWED')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-5 (DC1): two heredocs, both write-only ----------------------------------
{
    my $cmd = qq{cat > a.md <<'EOF'\nx\\y and git stash\nEOF\ncat >> a.md <<'EOF'\ngit clean -fd\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 0, 'P8-AC-5: two write-only heredocs in one command are both ALLOWED')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-6 (DC1): over 8192 chars, write-only ------------------------------------
{
    my $cmd = "cat > big.md <<'EOF'\n" . ('x' x 9000) . "\nmentions git stash\nEOF";
    ok(length($cmd) > 8192, 'P8-AC-6 fixture sanity: constructed command exceeds 8192 characters');
    my ($rc, $out) = run_guard($cmd);
    is($rc, 0, 'P8-AC-6: a write-only heredoc over 8192 characters is ALLOWED (no toolong raw-fallback)')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-7 (DC1): subagent caller (agent_id), write-only heredoc with backslash --
{
    my $cmd = qq{cat > r.md <<'EOF'\nstep 1\\n then git commit -m wip\nEOF};
    my ($rc, $out) = run_guard_with_payload($cmd, agent_id => 'sub-1');
    is($rc, 0, 'P8-AC-7: a subagent-caller payload writing a backslash-bearing heredoc to a file is ALLOWED')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-8 (DC2): heredoc piped into bash ----------------------------------------
{
    my $cmd = qq{cat <<'EOF' | bash\ngit stash\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-8: a heredoc piped into bash with a real mutation in the body is DENIED')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-9 (DC2): heredoc piped into sh ------------------------------------------
{
    my $cmd = qq{cat <<'EOF' | sh\nprintf 'a\\n'\ngit reset --hard\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-9: a heredoc piped into sh with a real mutation in the body is DENIED')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-10 (DC2): heredoc fed as the shell's own stdin --------------------------
{
    my $cmd = qq{bash <<'EOF'\ngit stash\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-10: a heredoc fed directly into bash as its own stdin is DENIED')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-11 (DC2): redirect AND pipe together, not write-only -------------------
{
    my $cmd = qq{cat <<'EOF' > /dev/stdout | sh\ngit stash\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-11: a redirect combined with a pipe into sh is DENIED (not write-only)')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-12 (DC3): written to a file, then executed via bash in the same command -
{
    my $cmd = qq{cat > fix.sh <<'EOF'\ngit stash\nEOF\nbash fix.sh};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-12: write-then-execute (bash fix.sh) in the same command is DENIED')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-13 (DC3): written, then sourced via ". ./env.sh" -----------------------
{
    my $cmd = qq{cat > env.sh <<'EOF'\nprintf 'a\\n'\ngit reset --hard\nEOF\n. ./env.sh};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-13: write-then-source (". ./env.sh") in the same command is DENIED')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-14 (DC3): written, then sourced via "source env.sh" -------------------
{
    my $cmd = qq{cat > env.sh <<'EOF'\nprintf 'a\\n'\ngit stash\nEOF\nsource env.sh};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-14: write-then-source ("source env.sh") in the same command is DENIED')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-15 (DC3): written, chmod +x, then executed by path ---------------------
{
    my $cmd = qq{cat > fix.sh <<'EOF'\nprintf 'a\\n'\ngit clean -fd\nEOF\nchmod +x fix.sh && ./fix.sh};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-15: write-then-chmod-then-execute-by-path in the same command is DENIED')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-16 (DC3): the N4 shape, but actually executed afterward ---------------
{
    my $cmd = qq{cat > probe.pl <<'EOF'\nprint "ok\\n";\n# git stash\nEOF\nperl probe.pl};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-16: the N4 probe.pl shape, EXECUTED by perl in the same command, is DENIED')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-17 (DC3): written, then piped to bash via cat ---------------------------
{
    my $cmd = qq{cat > fix.sh <<'EOF'\ngit stash\nEOF\ncat fix.sh | bash};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-17: write-then-"cat fix.sh | bash" in the same command is DENIED')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-18 (DC3): executed on the opener line itself ---------------------------
{
    my $cmd = qq{cat > fix.sh <<'EOF' ; bash fix.sh\ngit stash\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-18: execution chained on the heredoc opener line itself is DENIED')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-19 (DC4): write-only heredoc, but a REAL mutation outside the body -----
{
    my $cmd = qq{cat > n.md <<'EOF'\nx\\y\nEOF\ngit stash};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-19: write-only heredoc followed by a real mutation outside the body is DENIED')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-20 (DC4): unquoted-delimiter body with a live command substitution -----
{
    my $cmd = qq{cat <<EOF > n.md\nx\\y \$(git stash)\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-20: an unquoted-delimiter body containing $(git stash) is DENIED (P9)')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-21 (DC2/DC4): process substitution on the redirect target --------------
{
    my $cmd = qq{cat <<'EOF' > >(bash)\nx\\y\ngit stash\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-21: a redirect target that is a process substitution (>(bash)) is DENIED (P8)')
        or diag("hook output: $out; command was:\n$cmd");
}

# =====================================================================================
# Amendment 1 (Decision 48), spec section 4.2 -- AC-24..AC-43. Pins the four bypass-fix
# refusal rules the amended spec adds to _heredoc_walk/_heredoc_write_only_outer: R1
# ('#' read in state none, M1), R2 (a none-state '<<' must be a COMPLETE opener --
# non-empty delimiter, matching close quote, boundary char after the word -- M3/F1),
# P8 amended (any backslash, '${' or '$[' anywhere in $outer, M2 + new), and P9a (no
# backslash-newline in an unquoted-delimiter body, new). It also pins three bypasses the
# architect found while designing the fix (AC-33 empty delimiter <<''; AC-34/AC-35
# arithmetic '<<' inside $[...]/${...}; AC-36 backslash-newline joining two heredoc
# bodies), F2's redefinition-trick DENY pins (AC-40/AC-41, already caught by the
# existing P10 allow-list check), and AC-37's performance pin (R1 must stop the walk at
# the FIRST none-state '#' in under 10s, not the old P4 behavior the reviewer measured
# at ~17.8s).
#
# WRITTEN BLIND TO THE IMPLEMENTATION per bp-test-writer method -- GuardGitMutations.pm
# was not read for this block; every verdict below was derived from the spec's table and
# confirmed by EXECUTING run_guard against the CURRENT tree (the implementer-1 version,
# i.e. the first-version fix WITHOUT Amendment 1's R1/R2/P8-amended/P9a/P0a/P-CAP rules).
# Per spec AC-43: AC-24, AC-25, AC-27..AC-36, AC-38 and AC-39 are EXPECTED TO FAIL (red --
# the bypass is live) against this tree; AC-37 is expected to pass its DENY assertion but
# FAIL its <10s timing assertion (red on timing only); AC-26, AC-40, AC-41 and AC-42 are
# expected to already PASS (the current tree denies/allows them correctly via P4/P10,
# which the amendment must not regress). See test-writer-2.md for the full red/green
# table confirmed against this tree.
#
# Per the spec's notation (S1), every command below is copied verbatim from the spec's
# qq{} table cell, with each bare '$' rewritten as '\$' (qq{} would otherwise try to
# interpolate it as $(, $[, ${ or $').
# =====================================================================================

# ---- P8-AC-24 (DC4): '#' read in state none immediately before an UNQUOTED opener ----
{
    my $cmd = qq{cat > g # <<EOF\ngit stash\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-24: a none-state "#" before an unquoted heredoc opener is DENIED (R1/M1)')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-25 (DC4): '#' read in state none before a QUOTED opener (reviewer shape) --
{
    my $cmd = qq{cat > g # <<'EOF'\nprintf 'a\\n'\ngit stash\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-25: a none-state "#" before a quoted heredoc opener is DENIED (R1/M1, reviewer-executed shape)')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-26 (DC4, regression pin): ';#' comment-desync before the opener ----------
# Must stay DENIED after P4 is deleted -- R1 subsumes it. Expected GREEN already (the
# current tree still denies this via P4; this pin exists so a future removal of P4
# cannot silently regress it once R1 lands).
{
    my $cmd = qq{cat > g ;# <<'EOF'\nprintf 'a\\n'\ngit stash\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-26: comment-desync (";#" before the opener) stays DENIED once P4 is deleted (R1 must subsume it)')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-27 (DC4): ANSI-C quote desync, reviewer's exact executed shape -----------
{
    my $cmd = qq{cat > f \$'\\' <<EOF'\\'\ngit stash\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-27: ANSI-C-string quote desync before a quoted opener (reviewer-executed) is DENIED (M2/R2, boundary is the closing quote)')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-28 (DC4): same desync, but R2's boundary char is a space (only P8 catches)
{
    my $cmd = qq{cat > f \$'\\' <<EOF x'\\'\ngit stash\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-28: ANSI-C-string quote desync where R2\'s boundary check passes (space) is still DENIED via P8\'s backslash rule (M2)')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-29 (DC4): quoted opener <<"EOF"x -- bare suffix after the closing quote --
{
    my $cmd = qq{cat > f <<"EOF"x\nprintf 'a\\n'\nEOFx\ngit stash\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-29: a double-quoted opener delimiter with a bare suffix (<<"EOF"x) is DENIED (reviewer-executed, R2.3)')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-30 (DC4): single-quoted opener <<'EOF'x -- bare suffix -------------------
{
    my $cmd = qq{cat > f <<'EOF'x\nprintf 'a\\n'\nEOFx\ngit stash\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-30: a single-quoted opener delimiter with a bare suffix (<<\'EOF\'x) is DENIED (M3/F1, R2.3)')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-31 (DC4): bare opener <<EOF"x" -- QUOTED suffix --------------------------
{
    my $cmd = qq{cat > f <<EOF"x"\nprintf 'a\\n'\nEOFx\ngit stash\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-31: a bare opener delimiter followed by a quoted suffix (<<EOF"x") is DENIED (F1, R2.3)')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-32 (DC4): quote in mid-word -- bash's delimiter EOF vs walker's E --------
{
    my $cmd = qq{cat > f <<E'OF'\nprintf 'a\\n'\nEOF\ngit stash\nE};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-32: a quote landing mid-word (<<E\'OF\') is DENIED (F1, R2.3 -- bash reads delimiter EOF, the walker would read E)')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-33 (DC4, new): empty delimiter <<'' -- walker skips it, bash does not ----
{
    my $cmd = qq{cat > g <<''\ncat > h <<'END'\n\nprintf 'a\\n'\ngit stash\nEND};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-33: an empty heredoc delimiter (<<\'\') is DENIED (new / R2.1 -- bash ends it at the first empty line, the walker would not see it as an opener at all)')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-34 (DC4, new): arithmetic '<<' inside $[...] ------------------------------
{
    my $cmd = qq{cat > f \$[1<<2 ]\nprintf 'a\\n'\ngit stash\n2};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-34: an arithmetic "<<" inside $[...] is DENIED (new / P8 "\$[" rule)')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-35 (DC4, new): arithmetic '<<' inside an array subscript ${a[...]} -------
{
    my $cmd = qq{cat > f \${a[1<<2 ]}\nprintf 'a\\n'\ngit stash\n2};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-35: an arithmetic "<<" inside ${a[...]} is DENIED (new / P8 "\${" rule)')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-36 (DC4, new): backslash-newline joins two lines in an unquoted body -----
{
    my $cmd = qq{cat > f <<EOF\nx\\\nEOF\ncat > g <<END\nEOF\ngit stash\nEND};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-36: backslash-newline inside an unquoted-delimiter body is DENIED (new / P9a -- bash joins "x\\" and "EOF" into one line, so the first body does not end where the walker thinks)')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-37 (DC4, performance pin): 90000 '#' padding must not blow past 10s ------
# R1 must stop the walk at the FIRST none-state '#'; the old P4 behavior (uncapped
# strip_noise calls) the reviewer measured at ~17.8s in-module must be gone.
{
    my $cmd = "cat > f <<'EOF'\nx\nEOF\ngit stash\necho " . ('#' x 90000);
    my $t0 = time();
    my ($rc, $out) = run_guard($cmd);
    my $elapsed = time() - $t0;
    is($rc, 2, 'P8-AC-37: a 90000-char "#"-padded command is DENIED')
        or diag("hook output: $out");
    ok($elapsed < 10, "P8-AC-37: run_guard returns in under 10s wall-clock (took ${elapsed}s) (M4 / R1 stops the walk at the first '#')")
        or diag("elapsed: ${elapsed}s");
}

# ---- P8-AC-38 (DC4, new / M4): over the new 262144-char walk cap, write-only --------
{
    my $cmd = "cat > big.md <<'EOF'\n" . ('x' x 300000) . "\nmentions git stash\nEOF";
    ok(length($cmd) > 262144, 'P8-AC-38 fixture sanity: constructed command exceeds 262144 characters');
    my $t0 = time();
    my ($rc, $out) = run_guard($cmd);
    my $elapsed = time() - $t0;
    is($rc, 2, 'P8-AC-38: a write-only heredoc over 262144 characters gets NO exemption and is DENIED (M4/P0a)')
        or diag("hook output: $out");
    ok($elapsed < 10, "P8-AC-38: run_guard returns in under 10s wall-clock (took ${elapsed}s)")
        or diag("elapsed: ${elapsed}s");
}

# ---- P8-AC-39 (DC4, new / M4): outer part over 8192 chars is refused (P-CAP) --------
{
    my $cmd = "cat > f <<'EOF'\nx\\y git stash\nEOF\necho '" . ('y' x 9000) . "'";
    my $t0 = time();
    my ($rc, $out) = run_guard($cmd);
    my $elapsed = time() - $t0;
    is($rc, 2, 'P8-AC-39: an outer part (outside the heredoc body) over 8192 characters is refused and DENIED (M4/P-CAP)')
        or diag("hook output: $out");
    ok($elapsed < 10, "P8-AC-39: run_guard returns in under 10s wall-clock (took ${elapsed}s)")
        or diag("elapsed: ${elapsed}s");
}

# ---- P8-AC-40 (DC2/DC4, F2/B9, regression pin): cat() {} redefinition then heredoc --
# Expected GREEN already: P10's allow-list check already refuses this (the segment's
# first raw token is "{", not "cat"), so this is a "must not regress" pin, not a new
# refusal.
{
    my $cmd = qq{cat() { bash; }; cat > f <<'EOF'\nprintf 'a\\n'\ngit stash\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-40: redefining cat() as a function before the heredoc is DENIED (F2/B9, via existing P10 allow-list check)')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-41 (DC2/DC4, F2/B9, regression pin): "function cat {}" redefinition -----
{
    my $cmd = qq{function cat { bash; }; cat > f <<'EOF'\nprintf 'a\\n'\ngit stash\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 2, 'P8-AC-41: redefining cat via "function cat { ... }" before the heredoc is DENIED (F2/B9, via existing P10 allow-list check)')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-42 (DC1, regression pin): a QUOTED '#' outside the body must NOT refuse --
# R1 only refuses a none-state '#'. A '#' inside a double-quoted filename argument is in
# state dquote, not none, so it must not trip R1 -- this stays ALLOWED (DC1 is not
# narrowed back by the amendment). Expected GREEN already on the current tree too (the
# exemption already fires here independent of R1, since R1 does not exist yet).
{
    my $cmd = qq{cat > "issue#3.md" <<'EOF'\nx\\y and git stash\nEOF};
    my ($rc, $out) = run_guard($cmd);
    is($rc, 0, 'P8-AC-42: a "#" inside a double-quoted argument (not state none) does not trip R1 -- stays ALLOWED (DC1)')
        or diag("hook output: $out; command was:\n$cmd");
}

# ---- P8-AC-43: AC-0 for this amendment -- baseline recorded in test-writer-2.md, not
# re-executed here as a runtime assertion (there is no single pass/fail oracle action
# for "record the baseline"; the table lives in the report per the spec's own wording).

# =====================================================================================
# Companion (edge case, spec SS5) -- empty tool_input.command still exits 0. Must stay
# green; not this package's concern but a fast regression check that the new branch
# did not disturb the very first guard in the function.
# =====================================================================================
{
    my ($rc, $out) = run_guard('');
    is($rc, 0, 'companion: empty tool_input.command is still ALLOWED, unaffected by this package');
}

done_testing();
