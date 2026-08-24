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

# Kept distinct from $HAVE_JQ below: one case (AC17) removes perl from PATH, and
# the shim is written in perl, so that case is only meaningful with a real jq.
my $HAVE_REAL_JQ = `command -v jq 2>/dev/null` ne '';
my $HAVE_JQ = $HAVE_REAL_JQ;

# A jq SHIM, so this host stops skipping the only assertions that exercise the
# hook rather than reading it.
#
# guard-bash.sh hard-requires jq (bp_hook_require_jq, fail-closed), and jq does
# not exist on the Git-for-Windows host. The behavioural half of this file was
# therefore skipped here -- twelve assertions that never ran anywhere a developer
# could see them, on a BLOCKING guard. That is the worst place to have coverage
# that only exists in principle: a false negative here is a prohibited command
# executing, and 20260819-164901-52d3 is exactly such a gap living undetected
# behind this skip.
#
# The shim implements ONE filter -- `.tool_input.command // empty` -- because
# that is the only jq invocation in the hook. It is deliberately not a general
# jq: if the hook ever grows a second filter, the shim prints nothing, the hook
# sees an empty command and exits 0, and the DENY cases below fail loudly rather
# than passing on a stub that quietly agrees with everything.
my $SHIM_DIR;
unless ($HAVE_JQ) {
    $SHIM_DIR = tempdir(CLEANUP => 1);
    open my $s, '>', "$SHIM_DIR/jq" or die "cannot write jq shim: $!";
    print {$s} <<'SHIM';
#!/usr/bin/env perl
use strict; use warnings; use JSON::PP;
my @a = grep { $_ ne '-r' } @ARGV;
my $filter = shift(@a) // '';
die "jq shim: unsupported filter '$filter'\n"
    unless $filter eq '.tool_input.command // empty';
my $in = do { local $/; <STDIN> };
my $j = eval { JSON::PP->new->decode($in) } or exit 0;
my $v = eval { $j->{tool_input}{command} };
print $v if defined $v && !ref $v && length $v;
exit 0;
SHIM
    close $s;
    chmod 0755, "$SHIM_DIR/jq";
    $ENV{PATH} = "$SHIM_DIR" . ($^O eq 'MSWin32' ? ';' : ':') . $ENV{PATH};
    $HAVE_JQ = `command -v jq 2>/dev/null` ne '';
}
ok($HAVE_JQ, 'jq (real or shimmed) is available, so the behavioural cases below actually run');

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
    # The VERB half stays byte-identical -- that is what AC3 is for: proving the
    # set of covered commands has not silently changed.
    #
    # The ANCHOR half is deliberately no longer pinned here. It used to be, as
    # part of this same string, which meant AC3 pinned `(^|[;&|[:space:]])` --
    # precisely the boundary class almanac 20260819-164901-52d3 identifies as
    # WRONG (an invocation immediately after a quote or paren was not matched, so
    # `zsh -c 'git reset --hard'` was allowed while `sh -c ' git reset --hard'`
    # was denied, differing by one space). An oracle that pins a defect makes
    # fixing it look like a regression.
    ok(index($src, 'git[[:space:]]+stash\b') >= 0,
       'AC3: the git stash VERB regex is byte-identical to today');

    # The anchor is asserted as a PROPERTY instead: command-position openers must
    # be boundaries. `(` and `{` open a subshell or brace group, so a verb
    # immediately after one runs exactly as it would after a `;`.
    my ($base_anchor) = $src =~ /^\s*\*\)\s*ANCHOR_CLASS='([^']*)'/m;
    ok(defined $base_anchor, 'AC3b: the base anchor class is parseable from the source')
        or diag('no ANCHOR_CLASS default branch found');
    for my $ch ('(', '{', ';', '&', '|') {
        ok(index($base_anchor // '', $ch) >= 0,
           "AC3b: '$ch' is a command-position boundary in the base anchor class");
    }
    # ...and quotes are NOT, on the default path. A quote is never itself the
    # reason a shell executes what it encloses, so treating it as a boundary
    # unconditionally turns a quoted MENTION into a match -- the false-positive
    # class that makes a guard something people route around.
    for my $ch ("'", '"') {
        ok(index($base_anchor // '', $ch) < 0,
           "AC3b: [$ch] is NOT a boundary on the default path -- only when a shell "
         . "interpreter is present and the quoted span really is code");
    }
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
  SKIP: {
        # UNREPRODUCIBLE UNDER THE SHIM, and saying so beats a red line that
        # means nothing. This case removes perl from PATH to prove the hook
        # degrades to raw matching when bp_strip_shell_noise cannot run. The jq
        # shim IS perl, so removing perl also removes the hook's JSON parser: it
        # then reads an empty command and exits 0 at the `[ -n "$CMD" ]` guard,
        # never reaching a matcher. The 0 that results is not the hook silently
        # allowing a mutation -- it is the hook never seeing one.
        #
        # On a host with real jq this runs exactly as before. Skipping is
        # honest; asserting 2 here would be asserting something the harness,
        # not the hook, determines.
        skip 'jq is shimmed with perl, so removing perl from PATH also removes the '
           . 'JSON parser; this case needs a real jq', 1
            unless $HAVE_REAL_JQ;
        my $noperl = path_without('perl');
        my ($rc, $out) = run_guard(q{perl x.pl --text "don't run git checkout"}, PATH => $noperl);
        is($rc, 2, 'AC17: with perl unavailable, the quoted-mention case DEGRADES to raw-match DENY '
                 . '(today\'s pre-fix behavior) -- never silently allows')
            or diag("hook output: $out");
    }

    # =================================================================================
    # almanac 20260819-164901-52d3 -- the command-position boundary.
    #
    # Every matcher required the verb to follow start-of-string or [;&|<space>].
    # A quote or an opening paren is in neither class, so an invocation sitting
    # immediately after one was NOT matched. The report's own table, reproduced
    # here as executable cases:
    #
    #     sh -c ' git reset --hard'    DENY   (leading space)
    #     zsh -c 'git reset --hard'    ALLOW  <-- gap
    #     sh -e -c 'git reset --hard'  ALLOW  <-- gap
    #     echo $(git reset --hard)     ALLOW  <-- gap
    #
    # The first two differ by ONE SPACE. Whether a blocking guard fired depended
    # on incidental whitespace inside a quoted argument, which is not a property
    # anyone would predict or rely on.
    # =================================================================================
    for my $row (
        [ q{sh -c ' git reset --hard'},   'a shellword invocation with a leading space (already worked)' ],
        [ q{zsh -c 'git reset --hard'},   'a shellword invocation flush against the quote' ],
        [ q{sh -e -c 'git reset --hard'}, 'a shellword invocation with an intervening flag' ],
        [ q{echo $(git reset --hard)},    'a command substitution, verb flush against the paren' ],
        [ q{(git reset --hard)},          'a subshell -- `(` opens a command position' ],
        [ q{x=1; {git reset --hard; }},   'a brace group -- `{` opens a command position' ],
        [ q{(rm -rf /etc)},               'rm -rf inside a subshell' ],
    ) {
        my ($cmd, $why) = @$row;
        my ($rc, $out) = run_guard($cmd);
        is($rc, 2, "52d3: DENY -- $why") or diag("hook output: $out");
    }

    # The false-positive controls. Widening the boundary must not start matching
    # MENTIONS, which is the failure mode that makes a guard something people
    # route around rather than obey.
    for my $row (
        [ q{perl -e 'print "never git reset --hard"'}, 'a verb quoted inside prose, no shell carrier' ],
        [ q{git diff --stat},                          'read-only git' ],
        [ q{git stash list},                           'the explicitly allowed stash read' ],
        [ q{rm -rf /tmp/scratch},                      'rm -rf under /tmp' ],
    ) {
        my ($cmd, $why) = @$row;
        my ($rc, $out) = run_guard($cmd);
        is($rc, 0, "52d3 control: ALLOW -- $why") or diag("hook output: $out");
    }
}

done_testing();
