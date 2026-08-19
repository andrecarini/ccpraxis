#!/usr/bin/env perl
# 167-guard-bash-quote-strip.t -- oracle for t09-guard-hooks-stripping's guard-bash.sh
# changes (spec .ccpraxis-local-data/blueprints/tui-operator-feedback/specs/
# t09-guard-hooks-stripping-spec.md SS2.2/SS2.3/SS3/SS4).
#
# THIS IS GUARD-BASH.SH'S FIRST BEHAVIOR TEST, EVER (spec AC19 / scout open question 5).
# The scout confirmed only registration/route tests existed before this file
# (141-hooks-json-route-registration.t, 120-mark-wakeup-agent-dispatch.t) -- neither
# exercises guard-bash.sh's own matcher logic. This file IS the "baseline before edit"
# the ledger's done criterion 5 demands for this hook: it is a FRESHLY-AUTHORED
# baseline, not an inherited one, exactly as AC19 rules. Run once against the pre-fix
# guard-bash.sh (AC5/AC7 expected RED -- no stripping exists yet, mirroring 106's own
# documented AC-16 pattern) and once green post-fix.
#
# WRITTEN BLIND TO THE IMPLEMENTATION.
#
# jq AVAILABILITY. guard-bash.sh hard-requires jq (bp_hook_require_jq, fail-closed) --
# unlike guard-git-mutations.sh's jq-or-perl bp_json_get. jq does not exist on this
# Windows host, so every subprocess assertion below is gated behind a runtime check and
# SKIPped on a jq-less host, matching 121-guard-judge-checks.t's own documented
# convention -- a SKIP here reads as "not exercised on this host", never as a false
# green or a harness bug.
#
# TECHNIQUE NOTE (guard evasion). Every fixture reaches guard-bash.sh only as JSON
# payload TEXT in a temp file (Write tool / this test's own file writes), never as
# literal text in a Bash tool_input.command this session issues. The hook is invoked as
# a subprocess via `bash "$GPATH" < "$PFILE"`.
#
# Runs standalone: perl plugins/butler/tests/t/167-guard-bash-quote-strip.t
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP;

(my $HOOKS = "$Bin/../../hooks") =~ s{\\}{/}g;
my $GUARD  = "$HOOKS/guard-bash.sh";

ok(-f $GUARD, 'guard-bash.sh exists at plugins/butler/hooks/guard-bash.sh')
    or BAIL_OUT('subject hook missing');

my $HAVE_JQ = `command -v jq 2>/dev/null` ne '';

my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

my $pn = 0;
sub run_guard {
    my ($cmd, %extra_env) = @_;
    my $n = ++$pn;
    my $payload = $J->encode({ tool_name => 'Bash', tool_input => { command => $cmd } });
    my $pf = "$ROOT/payload.$n.json";
    open my $w, '>', $pf or die; print $w $payload; close $w;
    # bp_hook_gate requires all three of BP_LEDGER/BP_DIR/BP_PROJECT_ROOT.
    my %env = (%CLEAN_ENV, %extra_env,
               BP_LEDGER       => "$ROOT/fake-ledger.md",
               BP_DIR          => $ROOT,
               BP_PROJECT_ROOT => $ROOT,
               GPATH => fwd($GUARD), PFILE => fwd($pf));
    local %ENV = %env;
    open(my $f, '-|', 'bash', '-c', '"$GPATH" < "$PFILE" 2>&1') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    return ($? >> 8, $o);
}

# PATH containing everything on the ambient PATH EXCEPT perl (t/67's own precedent).
sub path_without {
    my ($name) = @_;
    my $d = "$ROOT/no-$name-bin";
    return fwd($d) if -d $d;
    mkdir $d or die "mkdir $d: $!";
    my %seen;
    for my $dir (split(/:/, ($CLEAN_ENV{PATH} // '')), '/usr/bin', '/bin', '/usr/local/bin') {
        next unless length $dir && -d $dir;
        opendir(my $dh, $dir) or next;
        for my $f (readdir $dh) {
            next if $f eq $name || $f =~ /^\./;
            next if $seen{$f}++;
            my $src = "$dir/$f";
            next unless -f $src && -x $src;
            symlink($src, "$d/$f");
        }
        closedir $dh;
    }
    return fwd($d);
}

# =====================================================================================
# AC1 (DC1) -- rationale comment at the site of the new code: ACCIDENT-not-ADVERSARY,
# citing precedent, naming the residual false-positive left unfixed (bare/unquoted
# mentions -- spec SS6 out-of-scope reader-veto).
# =====================================================================================
{
    my $src = do { local (@ARGV, $/) = ($GUARD); <> };
    like($src, qr/ACCIDENT/, 'AC1: guard-bash.sh source states the ACCIDENT-not-ADVERSARY threat model ruling');
    like($src, qr/ADVERSARY/i, 'AC1: ...and explicitly names ADVERSARY as the rejected alternative');
    ok(($src =~ /mark-wakeup\.sh/ || $src =~ /guard-validation-interlock\.sh/),
       'AC1: ...citing an existing documented ruling rather than re-deriving it');
}

# =====================================================================================
# AC3 (DC2) -- exactly one new stripped-match-text computation; the SAME matcher regex
# text as today, unchanged. Pinned via literal substrings of today's five `grep -Eq`
# patterns -- captured from the pre-t09 tree, must still be present verbatim.
# =====================================================================================
{
    my $src = do { local (@ARGV, $/) = ($GUARD); <> };
    ok(index($src, 'git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(checkout|switch|restore|reset|clean|rebase|merge|commit|push)\b') >= 0,
       'AC3: the git working-tree/history mutation regex is byte-identical to today');
    ok(index($src, '(^|[;&|[:space:]])git[[:space:]]+stash\b') >= 0,
       'AC3: the git stash regex is byte-identical to today');
    ok(index($src, 'rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f') >= 0,
       'AC3: the rm -rf regex is byte-identical to today');
    ok(index($src, 'firebase[[:space:]]+deploy\b') >= 0,
       'AC3: the firebase deploy regex is byte-identical to today');
    ok(index($src, 'BP_BASH_EXTRA_DENY') >= 0,
       'AC3: the BP_BASH_EXTRA_DENY extension point is byte-identical to today');
}

SKIP: {
    skip 'jq is not installed on this host; guard-bash.sh hard-requires it (bp_hook_require_jq, fail-closed)', 12
        unless $HAVE_JQ;

    # =================================================================================
    # AC5 (DC4, observable behavior 1) -- a forbidden verb ONLY inside a quoted
    # argument is ALLOWED.
    # =================================================================================
    for my $row (
        [ 'git checkout, quoted mention' => q{perl x.pl --text "don't run git checkout"} ],
        [ 'rm -rf, quoted mention'       => q{perl x.pl --text "never run rm -rf on the repo root"} ],
        [ 'firebase deploy, quoted'      => q{perl x.pl --text "CI handles firebase deploy, not us"} ],
        [ 'git stash, quoted'            => q{perl x.pl --text "a prohibited git stash destroyed a fix-batch"} ],
    ) {
        my ($label, $cmd) = @$row;
        my ($rc, $out) = run_guard($cmd);
        is($rc, 0, "AC5: $label is ALLOWED (quoted mention, not a real invocation)") or diag("hook output: $out");
    }

    # =================================================================================
    # AC6 (DC4, observable behavior 2) -- a REAL unquoted invocation is DENIED.
    # =================================================================================
    {
        my ($rc, $out) = run_guard('git checkout main');
        is($rc, 2, 'AC6: "git checkout main" (unquoted, real invocation) is DENIED');
        like($out, qr/BLOCKED:/, 'AC6: stderr contains "BLOCKED:"');
        like($out, qr/\QCommand: git checkout main\E/, 'AC6: stderr contains "Command: git checkout main"');
    }

    # =================================================================================
    # AC7 (DC1, DC4, observable behavior 3) -- a command exceeding
    # BP_GUARD_MAX_STRIP_BYTES (default 8000) whose UNQUOTED tail is a real mutation is
    # still DENIED: stripping is skipped above the cutoff, never the match.
    # =================================================================================
    {
        my $pad = 'echo "' . ('x' x 8100) . '" && git checkout main';
        ok(length($pad) > 8000, 'AC7 fixture sanity: constructed command exceeds 8000 characters');
        my ($rc, $out) = run_guard($pad);
        is($rc, 2, 'AC7: a >8000-byte command with a real unquoted mutation in its tail is DENIED (raw-fallback catches it)')
            or diag("hook output: $out");
    }

    # =================================================================================
    # AC17 (DC4, observable behavior 12) -- bp_strip_shell_noise unavailable (perl
    # absent from PATH): behavior must be IDENTICAL to pre-t09 (raw match) -- i.e. the
    # AC5 quoted-mention case, which the RAW regex also matches (no quote-awareness),
    # must DEGRADE TO DENY, exactly as today's guard-bash.sh (unmodified) already
    # behaves for this exact input. NEVER allow unconditionally.
    # =================================================================================
    {
        my $noperl = path_without('perl');
        my ($rc, $out) = run_guard(q{perl x.pl --text "don't run git checkout"}, PATH => $noperl);
        is($rc, 2, 'AC17: with perl unavailable, the quoted-mention case DEGRADES to raw-match DENY '
                 . '(today\'s pre-fix behavior) -- never silently allows')
            or diag("hook output: $out");
    }
}

done_testing();
