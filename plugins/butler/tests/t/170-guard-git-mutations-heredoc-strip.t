#!/usr/bin/env perl
# 170-guard-git-mutations-heredoc-strip.t -- oracle for t09-guard-hooks-stripping's
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
# 106-guard-git-mutations-quote-mask.t is a FOREIGN, already-closed package's oracle
# (a02) and is treated here as READ-ONLY reference, never edited. This file adds NEW
# coverage the t09 spec specifically calls for: the heredoc-only live instance (AC12),
# the carrier+heredoc composition (AC16), an explicit re-pin of the AC-18/AC15 shellword
# family (per the t09 test-writer brief: "pin the shellword case bash -c \"<mutation>\"
# explicitly"), the bp_strip_shell_noise-unavailable degrade (AC17), and two structural
# ACs (AC2: bp_strip_shell_noise byte-identical; AC4: the three-state walk and anchor
# selection byte-identical) via literal substring pins captured from the PRE-FIX tree.
#
# TECHNIQUE NOTE (guard evasion). guard-git-mutations.sh is UNGATED and denies any Bash
# tool_input.command matching its own patterns -- including THIS SESSION's own Bash
# calls. Every fixture below reaches the hook only as JSON payload TEXT written to a
# temp file by the Write tool (never as literal text in a Bash tool_input.command this
# session issues), and the hook is invoked as a subprocess via `bash "$GPATH" < "$PFILE"`
# -- exactly 106's own technique, verified safe by 106 already running green in this
# session's history.
#
# Runs standalone: perl plugins/butler/tests/t/170-guard-git-mutations-heredoc-strip.t
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP;
use File::Copy qw(copy);

(my $HOOKS = "$Bin/../../hooks")   =~ s{\\}{/}g;
(my $SCRIPTS = "$Bin/../../scripts") =~ s{\\}{/}g;
my $GUARD  = "$HOOKS/guard-git-mutations.sh";
my $LIBSH  = "$HOOKS/lib.sh";
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
# AC17 (DC4, observable behavior 12) -- bp_strip_shell_noise UNREACHABLE (bp-lib.sh
# absent from the sibling scripts/ dir the guard would source): the heredoc-only live
# instance (AC12) must degrade to TODAY's (pre-fix, current) behavior -- which is DENY,
# because the pre-fix escape fallback scans the raw heredoc body and its prose mentions
# "git stash" -- NEVER silently allow. This is the "fail direction never toward allow"
# requirement made concrete for this hook.
#
# Technique: a self-contained copy of the hook + hooks/lib.sh into a tempdir that
# mirrors the real hooks/ vs scripts/ sibling layout, but WITHOUT scripts/bp-lib.sh --
# so any `[ -r "$HOOK_DIR/../scripts/bp-lib.sh" ]` conditional source (per spec SS2.3)
# fails, and any call to bp_strip_shell_noise is to an undefined function. Never
# touches the real, shared scripts/bp-lib.sh (out of this package's write set).
# =====================================================================================
{
    my $tmp_root = "$ROOT/no-bplib";
    mkdir $tmp_root or die;
    mkdir "$tmp_root/hooks" or die;
    mkdir "$tmp_root/scripts" or die;   # deliberately left EMPTY -- no bp-lib.sh
    copy($GUARD, "$tmp_root/hooks/guard-git-mutations.sh") or die "copy guard: $!";
    copy($LIBSH, "$tmp_root/hooks/lib.sh") or die "copy lib.sh: $!";
    chmod 0755, "$tmp_root/hooks/guard-git-mutations.sh";
    my $copied_guard = fwd("$tmp_root/hooks/guard-git-mutations.sh");

    my $cmd = qq{cat <<EOF > report.md\n... this describes why git stash is forbidden ...\nEOF\nperl file-report.pl report.md};
    my ($rc, $out) = run_guard_at($copied_guard, $cmd);
    is($rc, 2, 'AC17: with scripts/bp-lib.sh unreachable, the live-instance heredoc case DEGRADES to raw-match DENY '
             . '(today\'s pre-fix behavior) -- never allows unconditionally')
        or diag("hook output: $out");
}

# =====================================================================================
# AC1 (DC1) -- a rationale comment sits at the site of the new branch: the ACCIDENT-not-
# ADVERSARY threat model ruling, citing precedent, and naming the residual false-positive
# shape left unfixed (backslash/# raw fallback).
# =====================================================================================
{
    my $src = do { local (@ARGV, $/) = ($GUARD); <> };
    like($src, qr/ACCIDENT/, 'AC1: guard-git-mutations.sh source states the ACCIDENT-not-ADVERSARY threat model ruling');
    like($src, qr/ADVERSARY/i, 'AC1: ...and explicitly names ADVERSARY as the rejected alternative');
    ok(($src =~ /mark-wakeup\.sh/ || $src =~ /guard-validation-interlock\.sh/),
       'AC1: ...citing an existing documented ruling (mark-wakeup.sh or guard-validation-interlock.sh) rather than re-deriving it');
    like($src, qr/backslash|#.*comment/i,
       'AC1: ...and names the residual false-positive shape left unfixed (the backslash/# raw fallback)');
}

# =====================================================================================
# AC2 (DC2, DC3) -- bp_strip_shell_noise is byte-for-byte UNMODIFIED by this package.
# Pinned via a SHA-1 of its exact function body, captured from the pre-fix tree
# (bp-lib.sh:233-328, "bp_strip_shell_noise() {" through its matching close brace).
# =====================================================================================
{
    use Digest::SHA qw(sha1_hex);
    my @lines = do { local @ARGV = ($BPLIB); <> };
    my ($start) = grep { $lines[$_] =~ /^bp_strip_shell_noise\(\)\s*\{/ } 0 .. $#lines;
    ok(defined $start, 'AC2 fixture-sanity: bp_strip_shell_noise() definition found in bp-lib.sh');
  SKIP: {
        skip 'cannot locate bp_strip_shell_noise() to hash', 1 unless defined $start;
        my $depth = 0; my $end;
        for my $i ($start .. $#lines) {
            my $l = $lines[$i];
            $depth += ($l =~ tr/\{//);
            $depth -= ($l =~ tr/\}//);
            if ($depth == 0 && $i > $start) { $end = $i; last; }
        }
        ok(defined $end, 'AC2 fixture-sanity: matching closing brace found');
      SKIP: {
            skip 'cannot locate closing brace', 1 unless defined $end;
            my $body = join('', @lines[$start .. $end]);
            is(sha1_hex($body), '9aa299cd3c5e44710d5ce029451df9ecede64880',
               'AC2: bp_strip_shell_noise() function body is BYTE-FOR-BYTE UNMODIFIED '
             . '(SHA-1 pinned from the pre-t09 tree) -- this package must not touch it, only call it');
        }
    }
}

# =====================================================================================
# AC4 (DC2, DC3) -- git_scan_target's three-state quote walk and its ANCHOR_CLASS /
# MUT_RE / STASH_RE selection are byte-for-byte UNCHANGED. Pinned via literal substring
# presence (not line offsets, since the new branch's insertion shifts every subsequent
# line number) -- captured verbatim from the pre-fix tree.
# =====================================================================================
{
    my $src = do { local (@ARGV, $/) = ($GUARD); <> };

    my $WALK = <<'WALK_END';
  local state=NONE   # NONE | SINGLE | DOUBLE
  local carrier=0
  local out="" c next
  local i=0
  while [ "$i" -lt "$len" ]; do
    c=${cmd:$i:1}
    case "$state" in
      NONE)
        case "$c" in
          "'") state=SINGLE; out+="'" ;;
          '"') state=DOUBLE; out+='"' ;;
          '`') carrier=1; out+='`' ;;
          '$')
            next=${cmd:$((i+1)):1}
            [ "$next" = "(" ] && carrier=1
            out+='$' ;;
          *) out+="$c" ;;
        esac ;;
      SINGLE)
        case "$c" in
          "'") state=NONE; out+="'" ;;
          *)   out+="X" ;;
        esac ;;
      DOUBLE)
        case "$c" in
          '"') state=NONE; out+='"' ;;
          '`') carrier=1; out+="X" ;;
          '$')
            next=${cmd:$((i+1)):1}
            [ "$next" = "(" ] && carrier=1
            out+="X" ;;
          *)   out+="X" ;;
        esac ;;
    esac
    i=$((i+1))
  done

  # 2. Unbalanced quoting (walk never returned to NONE): raw fallback.
  if [ "$state" != "NONE" ]; then
    RAW_KIND=unbalanced
    SCAN_OUT="$cmd"
    return 0
  fi
  # 3. An unquoted backtick or $( anywhere in NONE/DOUBLE: the shell would
  #    evaluate the enclosed text as CODE, so it is not a mere "mention" --
  #    raw fallback so the carried text is still scanned.
  if [ "$carrier" -eq 1 ]; then
    RAW_KIND=carrier
    SCAN_OUT="$cmd"
    return 0
  fi
  # 4. A shell/eval/xargs in command position (checked on the MASKED string,
  #    precisely so the same words appearing INSIDE someone's quoted prose do
  #    not trigger this): it re-interprets its own quoted argument as code, so
  #    e.g. `bash -c "git stash"` must still be denied. Raw fallback.
  if printf '%s' "$out" | grep -Eq '(^|[;&|[:space:]])(bash|sh|zsh|ksh|dash|eval|xargs)([[:space:]]|$)'; then
    RAW_KIND=shellword
    SCAN_OUT="$cmd"
    return 0
  fi

  SCAN_OUT="$out"
}
WALK_END

    ok(index($src, $WALK) >= 0,
       'AC4: the three-state quote walk (NONE/SINGLE/DOUBLE, carrier detection, shellword re-check) '
     . 'is present BYTE-FOR-BYTE UNCHANGED (pinned literal substring from the pre-t09 tree)')
        or diag('git_scan_target\'s quote walk was not found verbatim -- either reformatted or edited');

    like($src, qr/MASK_MAX=8192/, 'AC4: MASK_MAX is still 8192, unchanged');
    ok(index($src, 'STASH_RE="(^|${ANCHOR_CLASS})git[[:space:]]+stash') >= 0,
       'AC4: STASH_RE is still built from ANCHOR_CLASS, unchanged text');
    ok(index($src, 'MUT_RE="(^|${ANCHOR_CLASS})git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(checkout|switch|restore|reset|clean)') >= 0,
       'AC4: MUT_RE is still byte-identical, unchanged');
}

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
