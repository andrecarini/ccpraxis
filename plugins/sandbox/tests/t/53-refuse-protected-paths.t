#!/usr/bin/env perl
# Oracle tests for q03-launcher-refusal, derived from
#   .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/q03-launcher-refusal-spec.md
#
# IMMUTABLE ORACLE: written from the spec BEFORE the implementation exists.
# launcher.pl does not yet carry the q03:protected-path-decision sentinel
# region at authoring time -- this file is EXPECTED to show a large block of
# "not ok" until q03 lands. Do not weaken these assertions to make a future
# implementation's life easier.
#
# FOUR COORDINATOR RULINGS applied here (see the task brief for q03-launcher-
# refusal step 3; recorded inline at each affected AC too):
#   R3 -- <live>/plugins reports marketplace-install/exact (AC-15), NOT
#         "corrected" to ccpraxis-install. Spec is upheld as written.
#   R4 -- the marketplace-install/marketplace-source advice text in spec
#         S4.6 ("git clone --no-hardlinks {root} <your-clone-dir>") is
#         AMENDED: {root} need not be a git repo root (in the flagship
#         <live>/plugins case it is not -- the repo root is <live>). AC-28's
#         sentinels for these two reasons assert the AMENDED intent via
#         stable substrings, not a verbatim paragraph.
#   R5 -- AC-6 asserts R2 SEMANTICALLY (workcopy_route(/workcopy_refusal_
#         outcome( calls + the two exit statements, all after the new call
#         site), NOT as a byte-exact :231-242 literal -- nine later sandbox
#         packages also edit launcher.pl and a byte-exact pin would go red
#         for reasons unrelated to q03.
#   (failure-mode ruling) -- the harness does NOT BAIL_OUT when the sentinel
#         region is absent (unlike spec S6.2's literal harness). BAIL_OUT
#         would abort the whole file and hide the other 40+ ACs. Structural
#         ACs that prove absence (AC-2, AC-10) run as ok(0, ...); ACs that
#         need the extracted decision sub are gated behind SKIP blocks keyed
#         off $DECIDE, with a skip reason naming the missing region.
#
# All paths in this file are FABRICATED (/home/u/..., /opt/...). Every
# filesystem/env seam (registry/extra_list/env/exists/read_file/fold_case/
# windows) is injected. No test in this file touches the real filesystem,
# the real %ENV, the real $ENV{HOME}, or the real known_marketplaces.json
# (AC-12, AC-50). The only subprocess this file spawns is `perl -c
# launcher.pl` (AC-8/AC-9) -- never launcher.pl itself, never a container CLI.
#
# Criterion mapping (see also the full AC -> test-name table in
#   reports/q03-launcher-refusal/test-writer-step3.md):
#   AC-1..9    : Group A -- wiring/structure (source assertions on launcher.pl)
#   AC-10..12  : Group B -- extraction harness
#   AC-13..22  : Group C -- the refusing targets, one per reason code
#   AC-23..25  : Group D -- precedence (P0/P1/P2)
#   AC-26..33  : Group E -- message content
#   AC-34..37  : Group F -- degradation (Decision #6)
#   AC-38..40  : Group G -- C6 no-regression
#   AC-41..44  : Group H -- Decision #3, no override
#   AC-45..48  : Group I -- documentation
#   AC-49..50  : Group J -- suite hygiene

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Cwd qw(abs_path);
use File::Temp qw(tempfile);
use ProtectedPaths qw(path_relation protected_roots target_self_codes normalize_path);
use CcpraxisWorkCopy qw(workcopy_route);

# =====================================================================
# Environment resolution -- BAIL_OUT is reserved for a genuinely broken
# environment (cannot read launcher.pl, cannot resolve the repo root), never
# for the expected-absent q03 sentinel region (see ruling above).
# =====================================================================
my $repo_root = abs_path("$Bin/../../../..");
BAIL_OUT("cannot resolve repo root from $Bin/../../../..") unless defined $repo_root;

my $LAUNCHER = "$Bin/../../scripts/launcher.pl";
open my $lfh, '<:raw', $LAUNCHER or BAIL_OUT("cannot read launcher.pl: $!");
my @lines = <$lfh>;
close $lfh;
my $src = join '', @lines;

# =====================================================================
# Small local helpers (test scaffolding only).
# =====================================================================

# Build a regex that matches a phrase with arbitrary whitespace (including a
# line-wrap newline) between its words, so a step-8 prose re-wrap can't
# spuriously break a substring assertion (S4.7's own stated rationale).
sub _sentinel_re {
    my ($phrase) = @_;
    my $pat = join('\s+', map { quotemeta $_ } split /\s+/, $phrase);
    return qr/$pat/;
}

my $SKIP_REASON = 'q03 protected_path_outcome decision region not found (or failed to eval) '
                 . 'in launcher.pl -- implementation pending (TDD red phase)';

# =====================================================================
# Group A -- wiring and structure (source assertions on launcher.pl)
# =====================================================================

# ---- AC-1 ----
my $PP_USE_LINE = 'use ProtectedPaths qw(path_relation protected_roots target_self_codes normalize_path);';
{
    my $count = () = $src =~ /\Q$PP_USE_LINE\E/g;
    is($count, 1, "AC-1: launcher.pl contains exactly one line 'use ProtectedPaths qw(path_relation protected_roots target_self_codes normalize_path);'");
    my $pp_idx = index($src, $PP_USE_LINE);
    my $wc_use_idx = index($src, 'use CcpraxisWorkCopy qw(');
    ok(($pp_idx >= 0 && $wc_use_idx >= 0 && $pp_idx > $wc_use_idx),
       "AC-1: the ProtectedPaths use line's byte offset is greater than 'use CcpraxisWorkCopy qw(' (it comes after)");
}

# ---- AC-2 ----
my $BEGIN_SENTINEL = '# >>> q03:protected-path-decision:BEGIN';
my $END_SENTINEL   = '# <<< q03:protected-path-decision:END';
my ($begin_idx, $end_idx);
{
    my $begin_count = () = $src =~ /\Q$BEGIN_SENTINEL\E/g;
    my $end_count   = () = $src =~ /\Q$END_SENTINEL\E/g;
    is($begin_count, 1, "AC-2: the BEGIN sentinel '$BEGIN_SENTINEL' occurs exactly once in launcher.pl");
    is($end_count, 1,   "AC-2: the END sentinel '$END_SENTINEL' occurs exactly once in launcher.pl");
    $begin_idx = index($src, $BEGIN_SENTINEL);
    $end_idx   = index($src, $END_SENTINEL);
    ok(($begin_idx >= 0 && $end_idx >= 0 && $begin_idx < $end_idx),
       "AC-2: the BEGIN sentinel appears before the END sentinel");
}

# ---- AC-3 ----
my @pp_call_idxs_outside;
{
    my @all;
    my $pos = 0;
    while ((my $i = index($src, 'protected_path_outcome(', $pos)) >= 0) {
        push @all, $i;
        $pos = $i + 1;
    }
    @pp_call_idxs_outside = grep {
        my $i = $_;
        !(defined $begin_idx && $begin_idx >= 0 && defined $end_idx && $end_idx >= 0
          && $i >= $begin_idx && $i <= $end_idx);
    } @all;
    is(scalar(@pp_call_idxs_outside), 1,
       "AC-3: exactly one call to protected_path_outcome( exists outside the sentinel region");
}
my $workcopy_route_call_idx = index($src, 'workcopy_route(');
ok((@pp_call_idxs_outside == 1 && $workcopy_route_call_idx >= 0
    && $pp_call_idxs_outside[0] < $workcopy_route_call_idx),
   "AC-3: the protected_path_outcome( call site's byte offset is less than the workcopy_route( call's (R1 ordering)");

# ---- AC-4 ----
# NOTE: the "only key" exclusivity clause this assertion originally carried was
# removed -- AC-53/AC-56/AC-57 require the same call to also pass
# live_install_hint, env and extra_list_path, so registry_path can no longer be
# the sole key. Do not restore the exclusivity; it would contradict those ACs.
like($src,
     qr/protected_path_outcome\(\s*\$PROJECT_PATH\s*,\s*\{\s*registry_path\s*=>\s*"\$CLAUDE_HOST_CONFIG\/plugins\/known_marketplaces\.json"/,
     'AC-4: the call site passes $PROJECT_PATH first and a hash ref containing registry_path => "$CLAUDE_HOST_CONFIG/plugins/known_marketplaces.json"');

# ---- AC-5 ----
{
    my $anchor_idx = index($src, 'my $LIVE_CCPRAXIS_ROOT');
    ok((@pp_call_idxs_outside == 1 && $anchor_idx >= 0 && $pp_call_idxs_outside[0] > $anchor_idx),
       'AC-5: the call site\'s byte offset is greater than \'my $LIVE_CCPRAXIS_ROOT\' (it runs after the anchor derivation)');
}

# ---- AC-6 (R5: semantic check, NOT a byte-exact :231-242 literal -- see
#       header rationale; nine later packages also write launcher.pl) ----
like($src, qr/workcopy_route\(/, 'AC-6: launcher.pl still contains the workcopy_route( call (R2 fail-safe)');
like($src, qr/workcopy_refusal_outcome\(/, 'AC-6: launcher.pl still contains the workcopy_refusal_outcome( call (R2 fail-safe)');
like($src, qr/print STDERR \$o->\{message\}/, 'AC-6: launcher.pl still contains the statement print STDERR $o->{message}');
like($src, qr/exit\(\$o->\{exit_code\} \|\| 1\)/, 'AC-6: launcher.pl still contains the statement exit($o->{exit_code} || 1)');
ok((@pp_call_idxs_outside == 1 && $workcopy_route_call_idx >= 0
    && $workcopy_route_call_idx > $pp_call_idxs_outside[0]),
   'AC-6: the retained workcopy_route( call site appears AFTER the new protected_path_outcome( call site (R1/R2 ordering)');

# ---- AC-7 ----
like($src, qr/print STDERR \$_, "\\n" for \@\{\s*\$pp->\{warnings\}\s*\}/,
     'AC-7: the call block prints every warnings element to STDERR (print STDERR $_, "\n" for @{ $pp->{warnings} }) before the refusal branch');
like($src, qr/if\s*\(\s*\$pp->\{refuse\}\s*\)\s*\{\s*print STDERR \$pp->\{message\}, "\\n";\s*exit\(\s*\$pp->\{exit_code\}\s*\|\|\s*1\s*\);\s*\}/s,
     'AC-7: the refusal branch body is exactly "print STDERR $pp->{message}, \"\\n\"; exit($pp->{exit_code} || 1);"');

# ---- AC-8 / AC-9 -- perl -c, File::Temp capture (never an in-memory scalar
#       filehandle -- t/42 AC-L1 idiom). The only subprocess this file spawns.
{
    my ($tfh, $tfname) = tempfile(UNLINK => 1);
    close $tfh;
    my $cmd = sprintf('"%s" -c "%s" > "%s" 2>&1', $^X, $LAUNCHER, $tfname);
    system($cmd);
    my $rc = $? >> 8;
    open my $rfh, '<', $tfname or BAIL_OUT("cannot read perl -c capture file: $!");
    local $/;
    my $output = <$rfh>;
    close $rfh;
    is($rc, 0, 'AC-8: launcher.pl `perl -c` exits 0') or diag("perl -c output:\n$output");

    my @warnings = grep { /\S/ && !/syntax OK\s*$/ } split /\n/, ($output // '');
    is_deeply(\@warnings, [], 'AC-9: `perl -c` emits no warnings beyond the "syntax OK" line')
        or diag("unexpected perl -c output:\n" . join("\n", @warnings));
}

# =====================================================================
# Group B -- extraction harness
# =====================================================================

my ($region) = $src =~ /^\# >>> q03:protected-path-decision:BEGIN\b.*?\n(.*?)^\# <<< q03:protected-path-decision:END\b/ms;

# ---- AC-10 ---- (no BAIL_OUT -- see header ruling; ok(0, ...) proves absence)
my $DECIDE;
if (!defined $region) {
    ok(0, "AC-10: the text between the sentinels evals cleanly into a fresh package under use strict/warnings (sentinel region not found in launcher.pl)");
    ok(0, "AC-10: the resulting package ->can('protected_path_outcome') (sentinel region not found in launcher.pl)");
} else {
    my $harness = "package Q03Decision;\nuse strict;\nuse warnings;\n"
                . "use ProtectedPaths qw(path_relation protected_roots target_self_codes normalize_path);\n"
                . $region . "\n1;\n";
    my $eval_ok = eval $harness;   ## no critic
    my $eval_err = $@;
    ok($eval_ok, "AC-10: the text between the sentinels evals cleanly into a fresh package under use strict/warnings")
        or diag("eval error: $eval_err");
    if ($eval_ok) {
        $DECIDE = Q03Decision->can('protected_path_outcome');
        ok(defined $DECIDE, "AC-10: the resulting package Q03Decision->can('protected_path_outcome')");
    } else {
        ok(0, "AC-10: the resulting package Q03Decision->can('protected_path_outcome') (region failed to eval)");
    }
}

# ---- AC-11 -- region invariants R-I1..R-I5 ----
if (!defined $region) {
    ok(0, "AC-11 (R-I1): extracted region references no launcher file-scope lexical (region not found)");
    ok(0, "AC-11 (R-I2): extracted region contains no exit/die/warn/print/open/filetest/system/backtick (region not found)");
    ok(0, 'AC-11 (R-I3): extracted region contains no %ENV / $ENV{ access (region not found)');
    ok(0, "AC-11 (R-I4): extracted region contains no use/require statement (region not found)");
    ok(0, "AC-11 (R-I5): every sub defined in the region is protected_path_outcome or _pp_* (region not found)");
} else {
    my @forbidden_lexicals = ('$PROJECT_PATH', '$HOST_PLUGINS_DIR', '$LIVE_CCPRAXIS_ROOT',
                               '$HOME', '$CLAUDE_HOST_CONFIG', '$WINDOWS_FAMILY', '$PODMAN');
    my @lex_hits = grep { index($region, $_) >= 0 } @forbidden_lexicals;
    ok(scalar(@lex_hits) == 0, "AC-11 (R-I1): extracted region references no launcher file-scope lexical")
        or diag('hits: ' . join(', ', @lex_hits));

    my $has_forbidden_call = ($region =~ /\b(exit|die|warn|print|open|system)\s*[\(\s]/
                               || $region =~ /`/
                               || $region =~ /(?<![A-Za-z0-9_])-[edf]\s+[\$\(]/) ? 1 : 0;
    ok(!$has_forbidden_call, "AC-11 (R-I2): extracted region contains no exit/die/warn/print/open/filetest/system/backtick");

    my $has_env = ($region =~ /\$ENV\{/ || $region =~ /\%ENV\b/) ? 1 : 0;
    ok(!$has_env, 'AC-11 (R-I3): extracted region contains no %ENV / $ENV{ access');

    my $has_use = ($region =~ /^\s*(use|require)\b/m) ? 1 : 0;
    ok(!$has_use, "AC-11 (R-I4): extracted region contains no use/require statement");

    my @sub_names = $region =~ /^\s*sub\s+(\w+)/mg;
    my @bad_names = grep { !/^(?:protected_path_outcome|_pp_\w+)$/ } @sub_names;
    ok((scalar(@sub_names) > 0 && scalar(@bad_names) == 0),
       "AC-11 (R-I5): every sub defined in the region is named protected_path_outcome or _pp_*")
        or diag('sub names found: ' . join(', ', @sub_names));
}

# =====================================================================
# Shared fixture (spec S3 canonical fixture) -- fabricated paths, injected
# seams only. Reused across Groups B(AC-12)/C/D/E/F/G below.
# =====================================================================

my $tripwire = sub { die "test touched the filesystem\n" };
my $ENVF = sub {
    my %e = (CLAUDE_CONFIG_DIR => '/home/u/.claude', HOME => '/home/u');
    return $e{ $_[0] };
};
my $REG = {
    'gh-one'         => { source => { source => 'github', repo => 'o/r' },
                           installLocation => '/home/u/.claude/plugins/marketplaces/gh-one' },
    'ccpraxis-local' => { source => { source => 'directory', path => '/home/u/.claude/ccpraxis/plugins' },
                           installLocation => '/home/u/.claude/ccpraxis/plugins' },
    'ext-one'        => { source => { source => 'directory', path => '/opt/ext-src' },
                           installLocation => '/opt/ext-install' },
};
my %O = (
    registry   => $REG,
    extra_list => ['/opt/protected-one'],
    env        => $ENVF,
    exists     => $tripwire,
    read_file  => $tripwire,
    fold_case  => 0,
    windows    => 0,
);

# The eleven refusing scenarios (B1..B11) + the two C6 passthrough scenarios
# (B12/B13), each tagged with the AC it primarily serves in Groups C/D/G.
my @B = (
    { id => 'B1',  ac => 'AC-13', target => '/home/u/.claude',
      refuse => 1, reason => 'claude-home', root => '/home/u/.claude', relation => 'exact' },
    { id => 'B2',  ac => 'AC-14', target => '/home/u/.claude/plugins',
      refuse => 1, reason => 'claude-home', root => '/home/u/.claude', relation => 'descendant' },
    { id => 'B3',  ac => 'AC-15', target => '/home/u/.claude/ccpraxis/plugins',
      refuse => 1, reason => 'marketplace-install', root => '/home/u/.claude/ccpraxis/plugins', relation => 'exact' },
    { id => 'B4',  ac => 'AC-19', target => '/home/u/.claude/ccpraxis/plugins/sandbox',
      refuse => 1, reason => 'ccpraxis-install', root => '/home/u/.claude/ccpraxis', relation => 'descendant' },
    { id => 'B5',  ac => 'AC-18', target => '/home/u/.claude/ccpraxis',
      refuse => 1, reason => 'ccpraxis-install', root => '/home/u/.claude/ccpraxis', relation => 'exact' },
    { id => 'B6',  ac => 'AC-16', target => '/opt/ext-install',
      refuse => 1, reason => 'marketplace-install', root => '/opt/ext-install', relation => 'exact' },
    { id => 'B7',  ac => 'AC-17', target => '/opt/ext-src',
      refuse => 1, reason => 'marketplace-source', root => '/opt/ext-src', relation => 'exact' },
    { id => 'B8',  ac => 'AC-20', target => '/opt/protected-one',
      refuse => 1, reason => 'user-configured', root => '/opt/protected-one', relation => 'exact' },
    { id => 'B9',  ac => 'AC-22', target => '/opt',
      refuse => 1, reason => 'marketplace-install', root => '/opt/ext-install', relation => 'ancestor' },
    { id => 'B10', ac => 'AC-21', target => '/',
      refuse => 1, reason => 'drive-root', root => undef, relation => undef },
    { id => 'B11', ac => 'AC-23', target => '/home/u',
      refuse => 1, reason => 'user-home', root => undef, relation => undef },
);
my @FIXTURE_TARGETS = ((map { $_->{target} } @B), '/home/u/src/ccpraxis', '/home/u/work/myproject');

sub _try_decide {
    my ($target, $opts) = @_;
    my $out = eval { $DECIDE->($target, $opts) };
    my $err = $@;
    return (($err eq '' && ref($out) eq 'HASH') ? 1 : 0, $out, $err);
}

# ---- AC-12 ----
SKIP: {
    skip "$SKIP_REASON (AC-12)", scalar(@FIXTURE_TARGETS) unless defined $DECIDE;
    for my $t (@FIXTURE_TARGETS) {
        my ($ok, undef, $err) = _try_decide($t, \%O);
        ok($ok, "AC-12: protected_path_outcome('$t') with die-tripwire exists/read_file seams returns without touching the filesystem")
            or diag("error: $err");
    }
}

# =====================================================================
# Group C (AC-13..22) + Group D AC-23 -- the refusing targets, 4-tuple check
# =====================================================================

sub check_decision {
    my ($ac, $id, $target, $want) = @_;
    my ($ok, $got, $err) = _try_decide($target, \%O);
    if (!$ok) {
        ok(0, "$ac: protected_path_outcome('$target') [$id] refuse == $want->{refuse}");
        ok(0, "$ac: protected_path_outcome('$target') [$id] reason");
        ok(0, "$ac: protected_path_outcome('$target') [$id] root");
        ok(0, "$ac: protected_path_outcome('$target') [$id] relation");
        diag("decision call failed for '$target': $err") if $err;
        return undef;
    }
    is($got->{refuse}, $want->{refuse}, "$ac: protected_path_outcome('$target') [$id] refuse == $want->{refuse}");
    is($got->{reason}, $want->{reason}, "$ac: protected_path_outcome('$target') [$id] reason");
    is($got->{root}, $want->{root}, "$ac: protected_path_outcome('$target') [$id] root");
    is($got->{relation}, $want->{relation}, "$ac: protected_path_outcome('$target') [$id] relation");
    return $got;
}

SKIP: {
    skip "$SKIP_REASON (AC-13..23)", scalar(@B) * 4 unless defined $DECIDE;
    for my $b (@B) {
        check_decision($b->{ac}, $b->{id}, $b->{target}, $b);
    }
}

# ---- AC-24 (unconditional -- plain path_relation, no launcher region needed) ----
is(path_relation('/home/u/.claude', '/home/u/.claude/ccpraxis', \%O), 'ancestor',
   "AC-24: path_relation('/home/u/.claude','/home/u/.claude/ccpraxis') eq 'ancestor' -- a lower-rank root WAS matching (P1 still chose claude-home per AC-13)");

# ---- AC-25 (unconditional -- plain path_relation) ----
for my $pair (['/home/u/.claude/ccpraxis', 'ccpraxis-install'],
              ['/home/u/.claude', 'claude-home'],
              ['/home/u/.claude/ccpraxis/plugins', 'marketplace-install']) {
    my ($root, $reason) = @$pair;
    is(path_relation('/home/u/.claude/ccpraxis/plugins/sandbox', $root, \%O), 'descendant',
       "AC-25: path_relation(AC-19 target, '$root' [$reason]) eq 'descendant' -- all three tied roots relate as descendant; P2 chose the lowest reason rank");
}

# =====================================================================
# Group E -- message content (AC-26..33)
# =====================================================================

my $FIELD_ROOT_PREFIX     = '  ' . 'protected root' . ' : ';
my $FIELD_RELATION_PREFIX = '  ' . 'relation' . (' ' x 7) . ': ';
my $FIELD_REASON_PREFIX   = '  ' . 'reason' . (' ' x 9) . ': ';
my $ROOT_FIELD_MARK       = 'protected root' . ' :';
my $RELATION_FIELD_MARK   = 'relation' . (' ' x 7) . ':';
my %RELATION_PHRASE = (
    exact      => 'exact (the path you gave IS this protected root)',
    descendant => 'descendant (the path you gave is INSIDE this protected root)',
    ancestor   => 'ancestor (the path you gave CONTAINS this protected root)',
);

# ---- AC-26 ----
SKIP: {
    skip "$SKIP_REASON (AC-26)", scalar(@B) * 3 unless defined $DECIDE;
    for my $b (@B) {
        my ($ok, $got, $err) = _try_decide($b->{target}, \%O);
        if (!$ok) {
            ok(0, "AC-26: $b->{id} message is defined and non-empty");
            ok(0, "AC-26: $b->{id} message has no trailing newline");
            ok(0, "AC-26: $b->{id} message contains the target verbatim on its own indented line");
            diag("decision call failed for '$b->{target}': $err") if $err;
            next;
        }
        my $msg = $got->{message};
        ok((defined $msg && length $msg), "AC-26: $b->{id} ('$b->{target}') message is defined and non-empty");
        ok((defined $msg && $msg !~ /\n\z/), "AC-26: $b->{id} ('$b->{target}') message has no trailing newline");
        my $target_line = '  ' . $b->{target};
        ok((defined $msg && index($msg, $target_line) >= 0),
           "AC-26: $b->{id} ('$b->{target}') message contains the target verbatim on its own indented line");
    }
}

# ---- AC-27 -- 8 targets: all 5 root-based reason codes + all 3 relations ----
my @AC27_IDS = qw(B1 B2 B3 B4 B5 B7 B8 B9);
SKIP: {
    skip "$SKIP_REASON (AC-27)", scalar(@AC27_IDS) * 3 unless defined $DECIDE;
    for my $id (@AC27_IDS) {
        my ($b) = grep { $_->{id} eq $id } @B;
        my ($ok, $got, $err) = _try_decide($b->{target}, \%O);
        if (!$ok) {
            ok(0, "AC-27: $id protected-root field line");
            ok(0, "AC-27: $id relation field line");
            ok(0, "AC-27: $id reason field line");
            diag("decision call failed for '$b->{target}': $err") if $err;
            next;
        }
        my $msg = $got->{message} // '';
        ok(index($msg, $FIELD_ROOT_PREFIX . $b->{root}) >= 0,
           "AC-27: $id message contains '  protected root : $b->{root}'");
        ok(index($msg, $FIELD_RELATION_PREFIX . $RELATION_PHRASE{ $b->{relation} }) >= 0,
           "AC-27: $id message contains the correct S4.2 relation phrase for '$b->{relation}'");
        ok(index($msg, $FIELD_REASON_PREFIX . $b->{reason}) >= 0,
           "AC-27: $id message contains '  reason         : $b->{reason}'");
    }
}

# ---- AC-28 -- explanation + advice sentinel, one per root-based reason code ----
my %REASON_TARGET = (
    'ccpraxis-install'    => '/home/u/.claude/ccpraxis',
    'claude-home'         => '/home/u/.claude',
    'marketplace-install' => '/home/u/.claude/ccpraxis/plugins',
    'marketplace-source'  => '/opt/ext-src',
    'user-configured'     => '/opt/protected-one',
    'drive-root'          => '/',
    'user-home'           => '/home/u',
);
my %EXPLANATION_SENTINEL = (
    'ccpraxis-install'    => 'Its plugins, skills and launcher are in use right now',
    'claude-home'         => 'Bind-mounting it into a container would expose all of it read-write',
    'marketplace-install' => 'corrupt the installed plugin tree Claude Code is loading from',
    'marketplace-source'  => 'Claude Code loads plugins straight out of it',
    'user-configured'     => 'your own protected-paths list at',
);
my %ADVICE_SENTINEL = (
    'ccpraxis-install' => 'Work on a separate clone instead',
    'claude-home'      => 'Open the specific project directory you meant to work in',
    'user-configured'  => 'remove it from',
);

SKIP: {
    skip "$SKIP_REASON (AC-28)", 14 unless defined $DECIDE;

    for my $reason (qw(ccpraxis-install claude-home user-configured)) {
        my ($ok, $got, $err) = _try_decide($REASON_TARGET{$reason}, \%O);
        if (!$ok || !defined $got->{message}) {
            ok(0, "AC-28: $reason message contains its S4.5 explanation sentinel");
            ok(0, "AC-28: $reason message contains its S4.6 advice sentinel");
            diag("decision call failed for reason '$reason': $err") if $err;
            next;
        }
        like($got->{message}, _sentinel_re($EXPLANATION_SENTINEL{$reason}),
             "AC-28: $reason message contains its S4.5 explanation sentinel");
        like($got->{message}, _sentinel_re($ADVICE_SENTINEL{$reason}),
             "AC-28: $reason message contains its S4.6 advice sentinel");
    }

    # R4 AMENDED advice for marketplace-install / marketplace-source: the
    # spec's literal "git clone --no-hardlinks {root} <your-clone-dir>" is
    # wrong here ({root} need not be a git repo root -- in the flagship
    # <live>/plugins case the repo root is <live>, not <live>/plugins). The
    # amended text must point at the repository CONTAINING {root}, keep
    # --no-hardlinks, and keep the "Open the specific project directory you
    # meant to work in" line. We assert stable substrings of the amended
    # intent, not a verbatim paragraph -- the implementer/step-8 write the
    # final prose.
    for my $reason (qw(marketplace-install marketplace-source)) {
        my ($ok, $got, $err) = _try_decide($REASON_TARGET{$reason}, \%O);
        if (!$ok || !defined $got->{message}) {
            ok(0, "AC-28: $reason message contains its S4.5 explanation sentinel");
            ok(0, "AC-28 (R4): $reason advice contains 'Open the specific project directory you meant to work in'");
            ok(0, "AC-28 (R4): $reason advice contains --no-hardlinks");
            ok(0, "AC-28 (R4): $reason advice talks about cloning the repository, not the bare subdirectory");
            diag("decision call failed for reason '$reason': $err") if $err;
            next;
        }
        like($got->{message}, _sentinel_re($EXPLANATION_SENTINEL{$reason}),
             "AC-28: $reason message contains its S4.5 explanation sentinel");
        like($got->{message}, _sentinel_re('Open the specific project directory you meant to work in'),
             "AC-28 (R4): $reason advice contains 'Open the specific project directory you meant to work in'");
        like($got->{message}, qr/--no-hardlinks/,
             "AC-28 (R4): $reason advice contains --no-hardlinks");
        like($got->{message}, qr/\brepository\b/i,
             "AC-28 (R4): $reason advice talks about cloning the repository, not the bare subdirectory");
    }
}

# ---- AC-29 ----
SKIP: {
    skip "$SKIP_REASON (AC-29)", 2 unless defined $DECIDE;
    my ($ok, $got, $err) = _try_decide('/home/u/.claude/ccpraxis', \%O);
    if (!$ok || !defined $got->{message}) {
        ok(0, "AC-29: ccpraxis-install message contains 'git clone --no-hardlinks /home/u/.claude/ccpraxis <your-clone-dir>'");
        ok(0, "AC-29: ccpraxis-install message explains why --no-hardlinks is required");
        diag("decision call failed: $err") if $err;
    } else {
        like($got->{message}, qr/git clone --no-hardlinks \Q\/home\/u\/.claude\/ccpraxis\E\s+<your-clone-dir>/,
             "AC-29: ccpraxis-install message contains 'git clone --no-hardlinks /home/u/.claude/ccpraxis <your-clone-dir>'");
        like($got->{message}, _sentinel_re('The --no-hardlinks flag is required'),
             "AC-29: ccpraxis-install message explains why --no-hardlinks is required");
    }
}

# ---- AC-30 ----
SKIP: {
    skip "$SKIP_REASON (AC-30)", 2 unless defined $DECIDE;
    my ($ok, $got, $err) = _try_decide('/home/u/.claude', \%O);
    if (!$ok || !defined $got->{message}) {
        ok(0, "AC-30: claude-home message contains the 'Open the specific project directory you meant to work in' advice");
        ok(0, "AC-30: claude-home message does not contain 'git clone'");
        diag("decision call failed: $err") if $err;
    } else {
        like($got->{message}, _sentinel_re('Open the specific project directory you meant to work in'),
             "AC-30: claude-home message contains the 'Open the specific project directory you meant to work in' advice");
        unlike($got->{message}, qr/git clone/, "AC-30: claude-home message does not contain 'git clone'");
    }
}

# ---- AC-31 ----
SKIP: {
    skip "$SKIP_REASON (AC-31)", 6 unless defined $DECIDE;
    my ($ok, $got, $err) = _try_decide('/', \%O);
    if (!$ok || !defined $got->{message}) {
        ok(0, "AC-31: drive-root message begins 'claude-sandbox will not sandbox a filesystem root:'");
        ok(0, "AC-31: drive-root message contains 'reason         : drive-root'");
        ok(0, "AC-31: drive-root message contains the 'Open the specific project directory' advice");
        ok(0, "AC-31: drive-root message contains no 'protected root :' line");
        ok(0, "AC-31: drive-root message contains no 'relation       :' line");
        ok(0, "AC-31: drive-root message contains no 'marketplace' or 'known_marketplaces.json' mention");
        diag("decision call failed: $err") if $err;
    } else {
        my $msg = $got->{message};
        like($msg, qr/^claude-sandbox will not sandbox a filesystem root:/,
             "AC-31: drive-root message begins 'claude-sandbox will not sandbox a filesystem root:'");
        ok(index($msg, $FIELD_REASON_PREFIX . 'drive-root') >= 0,
           "AC-31: drive-root message contains 'reason         : drive-root'");
        like($msg, _sentinel_re('Open the specific project directory'),
             "AC-31: drive-root message contains the 'Open the specific project directory' advice");
        ok(index($msg, $ROOT_FIELD_MARK) == -1, "AC-31: drive-root message contains no 'protected root :' line");
        ok(index($msg, $RELATION_FIELD_MARK) == -1, "AC-31: drive-root message contains no 'relation       :' line");
        ok((index($msg, 'marketplace') == -1 && index($msg, 'known_marketplaces.json') == -1),
           "AC-31: drive-root message contains no 'marketplace' or 'known_marketplaces.json' mention");
    }
}

# ---- AC-32 ----
SKIP: {
    skip "$SKIP_REASON (AC-32)", 6 unless defined $DECIDE;
    my ($ok, $got, $err) = _try_decide('/home/u', \%O);
    if (!$ok || !defined $got->{message}) {
        ok(0, "AC-32: user-home message begins 'claude-sandbox will not sandbox your home directory:'");
        ok(0, "AC-32: user-home message contains 'reason         : user-home'");
        ok(0, "AC-32: user-home message contains the 'Open the specific project directory' advice");
        ok(0, "AC-32: user-home message contains no 'protected root :' line");
        ok(0, "AC-32: user-home message contains no 'relation       :' line");
        ok(0, "AC-32: user-home message contains no 'marketplace' or 'known_marketplaces.json' mention");
        diag("decision call failed: $err") if $err;
    } else {
        my $msg = $got->{message};
        like($msg, qr/^claude-sandbox will not sandbox your home directory:/,
             "AC-32: user-home message begins 'claude-sandbox will not sandbox your home directory:'");
        ok(index($msg, $FIELD_REASON_PREFIX . 'user-home') >= 0,
           "AC-32: user-home message contains 'reason         : user-home'");
        like($msg, _sentinel_re('Open the specific project directory'),
             "AC-32: user-home message contains the 'Open the specific project directory' advice");
        ok(index($msg, $ROOT_FIELD_MARK) == -1, "AC-32: user-home message contains no 'protected root :' line");
        ok(index($msg, $RELATION_FIELD_MARK) == -1, "AC-32: user-home message contains no 'relation       :' line");
        ok((index($msg, 'marketplace') == -1 && index($msg, 'known_marketplaces.json') == -1),
           "AC-32: user-home message contains no 'marketplace' or 'known_marketplaces.json' mention");
    }
}

# ---- AC-33 ----
SKIP: {
    skip "$SKIP_REASON (AC-33)", scalar(@B) * 3 unless defined $DECIDE;
    for my $b (@B) {
        my ($ok, $got, $err) = _try_decide($b->{target}, \%O);
        if (!$ok || !defined $got->{message}) {
            ok(0, "AC-33: $b->{id} message contains the no-override paragraph");
            ok(0, "AC-33: $b->{id} message ends with 'Aborting.'");
            ok(0, "AC-33: $b->{id} message is 7-bit ASCII");
            diag("decision call failed for '$b->{target}': $err") if $err;
            next;
        }
        my $msg = $got->{message};
        like($msg, _sentinel_re('There is no override: no flag and no environment variable'),
             "AC-33: $b->{id} message contains the no-override paragraph");
        like($msg, qr/Aborting\.\z/, "AC-33: $b->{id} message ends with 'Aborting.'");
        ok(($msg !~ /[^\x00-\x7f]/), "AC-33: $b->{id} message is 7-bit ASCII");
    }
}

# =====================================================================
# Group F -- degradation (Decision #6) (AC-34..37)
# =====================================================================

my %O_BROKEN = (%O, registry => undef);   # supplied-but-broken -> registry-shape error

# ---- AC-34 ----
SKIP: {
    skip "$SKIP_REASON (AC-34)", 3 unless defined $DECIDE;
    my ($ok, $got, $err) = _try_decide('/home/u/.claude', \%O_BROKEN);
    if (!$ok) {
        ok(0, "AC-34: refuse == 1 with a broken registry"); ok(0, "AC-34: reason eq 'claude-home'"); ok(0, "AC-34: warnings non-empty");
        diag("decision call failed: $err") if $err;
    } else {
        is($got->{refuse}, 1, "AC-34: refuse == 1 with a broken registry, target /home/u/.claude");
        is($got->{reason}, 'claude-home', "AC-34: reason eq 'claude-home' -- a broken source never shrinks the refusal");
        ok(scalar(@{ $got->{warnings} // [] }) > 0, "AC-34: warnings is non-empty");
    }
}

# ---- AC-35 ----
SKIP: {
    skip "$SKIP_REASON (AC-35)", 3 unless defined $DECIDE;
    my ($ok, $got, $err) = _try_decide('/home/u/work/myproject', \%O_BROKEN);
    if (!$ok) {
        ok(0, "AC-35: refuse == 0 with a broken registry"); ok(0, "AC-35: message undef"); ok(0, "AC-35: warnings non-empty");
        diag("decision call failed: $err") if $err;
    } else {
        is($got->{refuse}, 0, "AC-35: refuse == 0 with a broken registry, target /home/u/work/myproject -- errors alone are not fatal");
        is($got->{message}, undef, "AC-35: message is undef");
        ok(scalar(@{ $got->{warnings} // [] }) > 0, "AC-35: warnings is non-empty");
    }
}

# ---- AC-36 ----
SKIP: {
    skip "$SKIP_REASON (AC-36)", 3 unless defined $DECIDE;
    my ($ok, $got, $err) = _try_decide('/home/u/.claude', \%O_BROKEN);
    if (!$ok) {
        ok(0, "AC-36: every warning line matches ^claude-sandbox: and has no embedded newline");
        ok(0, "AC-36: the last warning line is the 'still enforcing' line");
        ok(0, "AC-36: N in the still-enforcing line equals scalar \@{ protected_roots(\\%O)->{roots} }");
        diag("decision call failed: $err") if $err;
    } else {
        my @w = @{ $got->{warnings} // [] };
        my $bad = grep { !/^claude-sandbox: / || /\n/ } @w;
        is($bad, 0, "AC-36: every warning line matches ^claude-sandbox: and has no embedded newline");
        my $last = $w[-1] // '';
        like($last, qr/^claude-sandbox: the protected-path guard is still enforcing the (\d+) protected root\(s\) it did resolve; a failed source never relaxes it\.?\z/,
             "AC-36: the last warning line is the 'still enforcing the N protected root(s)' line");
        my ($n) = $last =~ /enforcing the (\d+) protected/;
        my $actual = scalar @{ protected_roots(\%O_BROKEN)->{roots} };
        is($n, $actual, "AC-36: N equals scalar \@{ protected_roots(\\%O_BROKEN)->{roots} } (currently $actual)");
    }
}

# ---- AC-37 ----
SKIP: {
    skip "$SKIP_REASON (AC-37)", 4 unless defined $DECIDE;
    my $REG15 = { map { ("bad$_" => "not-a-hash-$_") } (1 .. 15) };
    my %O37 = (%O, registry => $REG15);
    my ($ok, $got, $err) = _try_decide('/home/u/work/myproject', \%O37);
    if (!$ok) {
        ok(0, "AC-37: exactly 12 warning lines (10 + 1 overflow + 1 still-enforcing)");
        ok(0, "AC-37: exactly 10 per-error WARNING lines");
        ok(0, "AC-37: exactly one overflow ('...and 5 more...') line, 11th of 12");
        ok(0, "AC-37: the still-enforcing line is last");
        diag("decision call failed: $err") if $err;
    } else {
        my @w = @{ $got->{warnings} // [] };
        is(scalar(@w), 12, "AC-37: exactly 12 warning lines (10 + 1 overflow + 1 still-enforcing) for 15 malformed registry entries");
        my $warn_n = grep { /^claude-sandbox: WARNING: protected-path source \[/ } @w;
        is($warn_n, 10, "AC-37: exactly 10 per-error WARNING lines");
        like($w[10] // '', qr/^claude-sandbox: WARNING: \.\.\. and 5 more protected-path source problem\(s\)\.?\z/,
             "AC-37: exactly one overflow ('...and 5 more...') line, 11th of 12");
        like($w[11] // '', qr/^claude-sandbox: the protected-path guard is still enforcing/,
             "AC-37: the still-enforcing line is last");
    }
}

# =====================================================================
# Group G -- C6 no-regression (AC-38..40)
# =====================================================================

# ---- AC-38 ----
SKIP: {
    skip "$SKIP_REASON (AC-38)", 3 unless defined $DECIDE;
    my ($ok, $got, $err) = _try_decide('/home/u/src/ccpraxis', \%O);
    if (!$ok) {
        ok(0, "AC-38: refuse == 0 for a ccpraxis clone outside the install");
        ok(0, "AC-38: message undef");
        ok(0, "AC-38: warnings empty");
        diag("decision call failed: $err") if $err;
    } else {
        is($got->{refuse}, 0, "AC-38: refuse == 0 for a ccpraxis clone outside the install (/home/u/src/ccpraxis)");
        is($got->{message}, undef, "AC-38: message is undef");
        is(scalar(@{ $got->{warnings} // [] }), 0, "AC-38: warnings is empty");
    }
}

# ---- AC-39 ----
SKIP: {
    skip "$SKIP_REASON (AC-39)", 3 unless defined $DECIDE;
    my ($ok, $got, $err) = _try_decide('/home/u/work/myproject', \%O);
    if (!$ok) {
        ok(0, "AC-39: refuse == 0 for an ordinary unrelated project");
        ok(0, "AC-39: message undef");
        ok(0, "AC-39: warnings empty");
        diag("decision call failed: $err") if $err;
    } else {
        is($got->{refuse}, 0, "AC-39: refuse == 0 for an ordinary unrelated project (/home/u/work/myproject)");
        is($got->{message}, undef, "AC-39: message is undef");
        is(scalar(@{ $got->{warnings} // [] }), 0, "AC-39: warnings is empty");
    }
}

# ---- AC-40 (unconditional -- CcpraxisWorkCopy::workcopy_route already exists,
#       does not depend on the q03 launcher region) ----
is(workcopy_route('/home/u/src/ccpraxis', {
        live_install_hint => '/home/u/.claude/ccpraxis',
        exists            => sub { 0 },
        realpath          => sub { $_[0] },
    }), 'passthrough',
    "AC-40: CcpraxisWorkCopy::workcopy_route is still 'passthrough' for the ccpraxis-clone-outside-the-install target (R2 fail-safe)");
is(workcopy_route('/home/u/work/myproject', {
        live_install_hint => '/home/u/.claude/ccpraxis',
        exists            => sub { 0 },
        realpath          => sub { $_[0] },
        git_commondir     => sub { undef },
    }), 'passthrough',
    "AC-40: CcpraxisWorkCopy::workcopy_route is still 'passthrough' for the ordinary-project target (R2 fail-safe)");

# =====================================================================
# Group H -- Decision #3, structural proof that no override exists
# (AC-41..44, all unconditional/source-based)
# =====================================================================

# ---- AC-41 ----
unlike($src, qr/(force|override|bypass|unsafe|allow|skip|ignore)[-_ ]?(protect|refus|guard)/i,
       "AC-41: no match for /(force|override|bypass|unsafe|allow|skip|ignore)[-_ ]?(protect|refus|guard)/i anywhere in launcher.pl");
unlike($src, qr/(protect|refus|guard)[-_ ]?(force|override|bypass|off|disable)/i,
       "AC-41: no match for /(protect|refus|guard)[-_ ]?(force|override|bypass|off|disable)/i anywhere in launcher.pl");

# ---- AC-42 -- Decision #3, REWRITTEN (03-resources-reader-model fix-batch,
#       step 7) -- see reports/03-resources-reader-model/{reviewer,redteam}.md
#       and packages/03-resources-reader-model.md's 2026-08-07 ruling.
#
#       ORIGINAL FORM (retired): a byte-identical index($src,$ARG_BLOCK)>=0
#       pin against a literal copy of the while(@argv) block. Its own comment
#       said "arg parsing is explicitly out of scope for q03" -- it was a
#       self-discipline check for a package that had already shipped, and it
#       went red the moment 03-resources-reader-model legitimately added a
#       --resources-sampler branch (spec E4: the write set forbids new files,
#       so the detached sampler had to be a re-exec of launcher.pl through a
#       new arg branch). A byte-identical pin FORBIDS every later package
#       from ever extending arg parsing again -- package 08 also owns
#       launcher.pl and will add its own flags -- so simply re-baselining it
#       with --resources-sampler pasted in would just re-arm the identical
#       trap one package later. Byte-identity was never the security
#       property here; it was a change-detector that outlived the package it
#       was guarding, and it is deliberately NOT restored below.
#
#       The actual security intent -- no argument branch can defeat the
#       protected-path refusal -- is asserted DIRECTLY and durably instead:
#       (1) no arg branch performs a side-effecting/unsafe action itself (the
#           block only ever assigns scalars or pushes to @POSITIONAL -- never
#           exit/system/exec/backtick/unlink/a write-mode open), so no branch
#           can act before the refusal gate is ever reached; and
#       (2) the SAME single, unconditional protected_path_outcome( call
#           governs every mode the arg parser can set -- it is not
#           conditioned on any mode flag, and it precedes both mode-specific
#           dispatch points (--session's connector-mode branch and
#           --resources-sampler's sampler-mode dispatch) by byte offset.
#       Together these survive a legitimate new --flag exactly the way
#       AC-41/AC-43/AC-44 already do, while still catching the one thing
#       AC-42 ever actually needed to catch: a branch that bypasses the gate.
{
    # Local brace-balance helper -- t/53 has no shared one (t/44's _balanced,
    # duplicated here rather than shared across files per each oracle's
    # self-containment convention).
    my $_balanced = sub {
        my ($s, $from) = @_;
        my $i = index($s, '{', $from);
        return undef if $i < 0;
        my $depth = 0; my $len = length($s); my $j = $i;
        for (; $j < $len; $j++) {
            my $c = substr($s, $j, 1);
            if    ($c eq '{') { $depth++; }
            elsif ($c eq '}') { $depth--; last if $depth == 0; }
        }
        return undef if $depth != 0;
        return substr($s, $i, $j - $i + 1);
    };
    my $anchor = index($src, 'while (@argv) {');
    ok($anchor >= 0, 'AC-42: launcher.pl source contains the while (@argv) { arg-parser block');
    my $arg_block = $anchor >= 0 ? $_balanced->($src, $anchor) : undef;
    ok(defined $arg_block, 'AC-42: the while (@argv) { ... } block is brace-balance extractable');

    if (defined $arg_block) {
        # (1) no branch performs a side-effecting/unsafe action directly.
        my @forbidden = (
            [ 'exit',              qr/\bexit\s*\(/ ],
            [ 'system',            qr/\bsystem\s*\(/ ],
            [ 'exec',              qr/\bexec\s*\(/ ],
            [ 'a backtick spawn',  qr/`/ ],
            [ 'unlink',            qr/\bunlink\b/ ],
            [ 'a write-mode open', qr/open\s*\([^)]*['"]>{1,2}['"]/ ],
        );
        for my $f (@forbidden) {
            my ($label, $qr) = @$f;
            unlike($arg_block, $qr,
                "AC-42: no while(\@argv) branch introduces $label -- the arg parser only ever records intent (scalars / \@POSITIONAL), never acts before the refusal gate");
        }
    } else {
        fail("AC-42: no while(\@argv) branch introduces $_")
            for ('exit', 'system', 'exec', 'a backtick spawn', 'unlink', 'a write-mode open');
    }

    # (2) the refusal gate governs every parsed mode: exactly one
    #     unconditional protected_path_outcome( call site, preceding both
    #     mode-specific dispatch points by byte offset.
    my $n_gate_calls = () = $src =~ /\bprotected_path_outcome\s*\(/g;
    is($n_gate_calls, 1, 'AC-42: protected_path_outcome( appears exactly once -- one gate, not a per-mode alternate');

    my $gate_pos = ($src =~ /\bprotected_path_outcome\s*\(/) ? $-[0] : undef;
    ok(defined $gate_pos, 'AC-42: the protected_path_outcome( call site is locatable');

    if (defined $gate_pos) {
        my $win_start = $gate_pos >= 400 ? $gate_pos - 400 : 0;
        my $before = substr($src, $win_start, $gate_pos - $win_start);
        unlike($before, qr/\b(SESSION_MODE|RESOURCES_SAMPLER_MODE)\b/,
            'AC-42: the protected_path_outcome( call is not itself conditioned on any mode flag (SESSION_MODE / RESOURCES_SAMPLER_MODE)');
    } else {
        fail('AC-42: the protected_path_outcome( call is not itself conditioned on any mode flag (SESSION_MODE / RESOURCES_SAMPLER_MODE)');
    }

    my $session_dispatch_pos = ($src =~ /\$SESSION_MODE\s*\|\|\s*length\s+\$RESUME_SESSION/) ? $-[0] : undef;
    my $sampler_dispatch_pos = ($src =~ /RESOURCES_SAMPLER_MODE[^\n]*\)\s*\{[^\n]*\n[^\n]*_resources_sampler_main/) ? $-[0] : undef;

    if (defined $gate_pos && defined $session_dispatch_pos) {
        ok($gate_pos < $session_dispatch_pos,
            'AC-42: protected_path_outcome( precedes the --session connector-mode dispatch by byte offset -- --session cannot skip the refusal gate');
    } else {
        fail('AC-42: protected_path_outcome( precedes the --session connector-mode dispatch by byte offset');
    }
    if (defined $gate_pos && defined $sampler_dispatch_pos) {
        ok($gate_pos < $sampler_dispatch_pos,
            'AC-42: protected_path_outcome( precedes the --resources-sampler dispatch by byte offset -- --resources-sampler cannot skip the refusal gate');
    } else {
        fail('AC-42: protected_path_outcome( precedes the --resources-sampler dispatch by byte offset');
    }
}

# ---- AC-43 ----
{
    my @env_names;
    while ($src =~ /\$ENV\{\s*['"]?(\w+)['"]?\s*\}/g) { push @env_names, $1; }
    my @bad = grep { /PROTECT|REFUS|GUARD|OVERRIDE|FORCE|BYPASS|UNSAFE/i } @env_names;
    is(scalar(@bad), 0,
       'AC-43: no $ENV{...} name in launcher.pl matches /PROTECT|REFUS|GUARD|OVERRIDE|FORCE|BYPASS|UNSAFE/i')
        or diag('matches: ' . join(', ', @bad));
}

# ---- AC-44 -- the refusal branch is unconditional ----
{
    my ($call_line_idx) = grep { $lines[$_] =~ /protected_path_outcome\(\s*\$PROJECT_PATH\b/ } (0 .. $#lines);
    my ($block_open_idx, $block_close_idx);
    if (defined $call_line_idx) {
        for (my $i = $call_line_idx; $i >= 0 && $i >= $call_line_idx - 5; $i--) {
            if ($lines[$i] =~ /^\{\s*$/) { $block_open_idx = $i; last; }
        }
        if (defined $block_open_idx) {
            for my $i ($block_open_idx + 1 .. $#lines) {
                if ($lines[$i] =~ /^\}\s*$/) { $block_close_idx = $i; last; }
            }
        }
    }
    if (defined $block_open_idx && defined $block_close_idx) {
        my $block_text = join('', @lines[$block_open_idx .. $block_close_idx]);
        my ($refuse_body) = $block_text =~ /if\s*\(\s*\$pp->\{refuse\}\s*\)\s*\{(.*?)\n\s*\}/s;
        if (defined $refuse_body) {
            ok(($refuse_body !~ /\b(if|unless|return|last|next|eval)\b/),
               "AC-44: the refusal branch body contains no if/unless/return/last/next/eval");
        } else {
            ok(0, "AC-44: the refusal branch body contains no if/unless/return/last/next/eval (refusal branch not found)");
        }
        my $exit_count = () = $block_text =~ /\bexit\s*\(/g;
        is($exit_count, 1, "AC-44: exit appears exactly once inside the whole call block");
    } else {
        ok(0, "AC-44: the refusal branch body contains no if/unless/return/last/next/eval (call block not found)");
        ok(0, "AC-44: exit appears exactly once inside the whole call block (call block not found)");
    }
}

# =====================================================================
# Group I -- documentation (AC-45..48)
# =====================================================================

my $DOC = "$Bin/../../docs/protected-paths.md";
my $doc_text;
if (open my $dfh, '<:raw', $DOC) {
    local $/;
    $doc_text = <$dfh>;
    close $dfh;
}

# ---- AC-45 -- names all four Decision #4 sources ----
for my $probe (
    ['installLocation',                        'installLocation'],
    ["source.path (directory source)",         'source.path'],
    ['the Claude home (CLAUDE_CONFIG_DIR / ~/.claude)', 'CLAUDE_CONFIG_DIR'],
    ['the ccpraxis live install anchor',       '(?:ccpraxis|live) install'],
) {
    my ($label, $pat) = @$probe;
    if (defined $doc_text) {
        like($doc_text, qr/$pat/i, "AC-45: docs/protected-paths.md names the source '$label'");
    } else {
        ok(0, "AC-45: docs/protected-paths.md names the source '$label' (doc file does not exist yet)");
    }
}

# ---- AC-46 -- names the three refusing relations + unrelated launches ----
for my $rel (qw(exact descendant ancestor unrelated)) {
    if (defined $doc_text) {
        like($doc_text, qr/\b\Q$rel\E\b/, "AC-46: docs/protected-paths.md names the relation '$rel'");
    } else {
        ok(0, "AC-46: docs/protected-paths.md names the relation '$rel' (doc file does not exist yet)");
    }
}

# ---- AC-47 -- names all seven reason codes ----
for my $code (qw(ccpraxis-install claude-home marketplace-install marketplace-source
                 user-configured drive-root user-home)) {
    if (defined $doc_text) {
        like($doc_text, qr/\Q$code\E/, "AC-47: docs/protected-paths.md names the reason code '$code'");
    } else {
        ok(0, "AC-47: docs/protected-paths.md names the reason code '$code' (doc file does not exist yet)");
    }
}

# ---- AC-48 -- documents the extra list ----
for my $probe (
    ['the literal extra-list path', qr/\$\{CLAUDE_CONFIG_DIR:-~\/\.claude\}\/ccpraxis-protected-paths\.json/],
    ['JSON array of absolute paths', qr/JSON array/i],
    ['absent file is an empty list, not an error', qr/(?:absent|missing).{0,40}(?:not an error|empty list)|empty list.{0,40}(?:absent|missing)/is],
    ['a malformed file is an error', qr/malformed/i],
    ['there is no override', qr/no override/i],
) {
    my ($label, $re) = @$probe;
    if (defined $doc_text) {
        like($doc_text, $re, "AC-48: docs/protected-paths.md documents $label");
    } else {
        ok(0, "AC-48: docs/protected-paths.md documents $label (doc file does not exist yet)");
    }
}

# =====================================================================
# Group J -- suite hygiene (AC-49..50)
# =====================================================================

open my $sfh, '<:raw', $0 or die "cannot reopen own test file $0: $!";
my @slines = <$sfh>;
close $sfh;
my $stext = join('', @slines);

# Scope the "forbidden content" scans to everything BEFORE this Group J
# section, not the whole file: Group J's own assertions necessarily contain
# the words "podman"/"docker"/"TestSandbox"/"$ENV{HOME}" in their id strings
# and regex literals (to describe what they check for), and AC-11's R-I1
# lexical-name list legitimately contains the literal string '$PODMAN' as
# DATA (the launcher's own variable name, unrelated to spawning a container
# CLI). A whole-file substring scan would self-defeat on both. Scanning only
# the substantive Groups A-I content sidesteps this without weakening what
# actually matters: that the test LOGIC never spawns a container / never
# spawns launcher.pl as a program / never reads the real $ENV{HOME}.
my ($groupj_idx) = grep { $slines[$_] =~ /^\# Group J -- suite hygiene/ } (0 .. $#slines);
my @scan_lines = defined $groupj_idx ? @slines[0 .. $groupj_idx - 1] : @slines;
my $scan_text = join('', @scan_lines);
my @scan_code_lines = map { my $x = $_; $x =~ s/#.*$//; $x } @scan_lines;
my $scan_code = join('', @scan_code_lines);

# ---- AC-49 ----
like($scan_text, qr/use FindBin qw\(\$Bin\)/, 'AC-49: t/53 uses "use FindBin qw($Bin);"');
like($scan_text, qr/use lib "\$Bin\/\.\.\/\.\.\/scripts"/, 'AC-49: t/53 uses "use lib \"$Bin/../../scripts\";"');
like($scan_text, qr/abs_path\("\$Bin\/\.\.\/\.\.\/\.\.\/\.\."\)/, 'AC-49: t/53 resolves the repo root as abs_path("$Bin/../../../..")');
like($scan_text, qr/BAIL_OUT/, 'AC-49: t/53 has a BAIL_OUT guard');
{
    # The only subprocess call permitted anywhere in this file is the
    # whitelisted `perl -c launcher.pl` compile check (AC-8/AC-9). Pinning
    # "exactly one system( call site, and it is the -c one" proves "never
    # references podman/docker, never spawns launcher.pl as a program,
    # never a TestSandbox-driven container spawn" all at once, without a
    # blanket word-ban that would trip over legitimate DATA occurrences
    # (see the scoping comment above).
    my @system_calls = ($scan_code =~ /\bsystem\s*\(/g);
    is(scalar(@system_calls), 1,
       'AC-49: t/53 contains exactly one system( call site (the whitelisted `perl -c` compile check)');
    like($scan_code, qr/sprintf\('"%s" -c "%s"[^\n]*\$LAUNCHER/,
         'AC-49: the sole system( call site is `perl -c` against $LAUNCHER, not a real launch');
}
unlike($scan_code, qr/\bpodman\b/, 'AC-49: t/53 never references a container CLI by name (podman) in code');
unlike($scan_code, qr/\bdocker\b/, 'AC-49: t/53 never references a container CLI by name (docker) in code');
unlike($scan_code, qr/\bTestSandbox\b/, 'AC-49: t/53 never references a TestSandbox-driven container spawn');
{
    my @nonblank = grep { $_ !~ /^\s*$/ } @slines;
    like($nonblank[-1], qr/^\s*done_testing\(\);\s*$/, 'AC-49: t/53 ends with done_testing() (no fixed plan)');
}

# ---- AC-50 ----
unlike($scan_code, qr/\$ENV\{\s*['"]?HOME['"]?\s*\}/, 'AC-50: t/53 never references the real $ENV{HOME}');
unlike($scan_code, qr/\bglob\s*\(\s*['"]~/, 'AC-50: t/53 never globs the real home directory via ~');
like($scan_code, qr/exists\s*=>/, 'AC-50: t/53 always supplies an injected exists seam (never the module default)');
like($scan_code, qr/read_file\s*=>/, 'AC-50: t/53 always supplies an injected read_file seam (never the module default)');

# =====================================================================
# Group K -- security fix-batch (AC-51..67)
#
# Extends the q03 oracle for eight fixes on top of the already-implemented
# base package (AC-1..50, 267 ok / 0 not ok at authoring time):
#   CRITICAL-1(a) -- an env-independent 'ccpraxis-install' root, threaded
#                    into protected_path_outcome via a new live_install_hint
#                    option (AC-51..53).
#   CRITICAL-1(b) -- the authoritative-home env seam that closes the
#                    CLAUDE_CONFIG_DIR/HOME decoy bypass (AC-54..56).
#   MAJOR-3       -- pin extra_list_path alongside registry_path so
#                    CLAUDE_CONFIG_DIR cannot silently void the Decision #5
#                    user list (AC-57..58).
#   MINOR-5       -- warning-line sanitisation against a hostile registry
#                    key forging a second claude-sandbox: line or injecting
#                    ANSI/control bytes (AC-59..61).
#   MINOR-7       -- _pp_explanation fallback for an unmapped reason code
#                    (AC-62).
#   reviewer MINOR -- the "still enforcing" trailer must always be LAST in
#                    warnings, even when it collides with the
#                    unnormalizable-target warning (AC-63).
#   R4 (already ruled) -- marketplace-install/marketplace-source advice:
#                    at most one 'git clone' occurrence (AC-64, expected to
#                    already pass -- confirms the earlier ruling landed)
#                    and no message line over 80 columns (AC-65, new).
#   reviewer MAJOR -- docs/protected-paths.md's false claim that the
#                    ccpraxis-install root is derived only from the
#                    launcher's own path (AC-66..67).
#
# As in Group B, a not-yet-existing capability is asserted via an explicit
# ok(0, ...) fallback, never a SKIP: block -- Test::More's skip() reports as
# "ok # skip" in TAP, which would NOT show up as red and would defeat the
# whole point of an oracle written before the implementation.
# =====================================================================

# Isolate the protected_path_outcome( call block's own source text (from its
# call site to the retained workcopy_route( call site that follows it, per
# R1/R2 ordering already pinned by AC-3/AC-6) -- reused by several
# structural ACs below so each of them inspects exactly the right call site
# and never accidentally matches the *other* call block (workcopy_route(
# already legitimately carries live_install_hint => $LIVE_CCPRAXIS_ROOT,
# and a whole-file grep would false-positive against it).
my $PP_CALL_BLOCK_TEXT = '';
if (@pp_call_idxs_outside == 1 && $workcopy_route_call_idx >= 0
    && $workcopy_route_call_idx > $pp_call_idxs_outside[0]) {
    $PP_CALL_BLOCK_TEXT = substr($src, $pp_call_idxs_outside[0],
                                  $workcopy_route_call_idx - $pp_call_idxs_outside[0]);
}

# ---- AC-51 / AC-52 / AC-53 -- CRITICAL-1(a): live_install_hint ----
my %O_HINT = (
    registry          => {},              # resolves NOTHING on its own
    extra_list        => [],
    env               => sub { return undef },   # no CLAUDE_CONFIG_DIR/HOME/USERPROFILE
    exists            => $tripwire,
    read_file         => $tripwire,
    fold_case         => 0,
    windows           => 0,
    live_install_hint => '/tmp/anchor/ccpraxis',
);
{
    my ($ok, $got, $err) = _try_decide('/tmp/anchor/ccpraxis', \%O_HINT);
    if (!$ok) {
        ok(0, "AC-51: protected_path_outcome('/tmp/anchor/ccpraxis') refuses via live_install_hint even though registry => {} resolves nothing");
        ok(0, "AC-51: reason eq 'ccpraxis-install'");
        ok(0, "AC-51: root eq the live_install_hint path");
        ok(0, "AC-51: relation eq 'exact'");
        diag("decision call failed: $err") if $err;
    } else {
        is($got->{refuse}, 1, "AC-51: protected_path_outcome('/tmp/anchor/ccpraxis') refuses via live_install_hint even though registry => {} resolves nothing");
        is($got->{reason}, 'ccpraxis-install', "AC-51: reason eq 'ccpraxis-install'");
        is($got->{root}, '/tmp/anchor/ccpraxis', "AC-51: root eq the live_install_hint path");
        is($got->{relation}, 'exact', "AC-51: relation eq 'exact' for the hint path itself");
    }
}
{
    my ($ok, $got, $err) = _try_decide('/tmp/anchor/ccpraxis/plugins/sandbox', \%O_HINT);
    if (!$ok) {
        ok(0, "AC-52: protected_path_outcome('/tmp/anchor/ccpraxis/plugins/sandbox') refuses via live_install_hint even though registry => {} resolves nothing");
        ok(0, "AC-52: reason eq 'ccpraxis-install'");
        ok(0, "AC-52: root eq the live_install_hint path (the reported root is the hint path)");
        ok(0, "AC-52: relation eq 'descendant'");
        diag("decision call failed: $err") if $err;
    } else {
        is($got->{refuse}, 1, "AC-52: protected_path_outcome('/tmp/anchor/ccpraxis/plugins/sandbox') refuses via live_install_hint even though registry => {} resolves nothing");
        is($got->{reason}, 'ccpraxis-install', "AC-52: reason eq 'ccpraxis-install'");
        is($got->{root}, '/tmp/anchor/ccpraxis', "AC-52: root eq the live_install_hint path (the reported root is the hint path)");
        is($got->{relation}, 'descendant', "AC-52: relation eq 'descendant'");
    }
}
like($PP_CALL_BLOCK_TEXT, qr/live_install_hint\s*=>\s*\$LIVE_CCPRAXIS_ROOT/,
     "AC-53: the protected_path_outcome( call block in launcher.pl passes live_install_hint => \$LIVE_CCPRAXIS_ROOT");

# ---- AC-54 / AC-55 / AC-56 -- CRITICAL-1(b): the authoritative-home env seam ----
my $ENV_SEAM_MAKER = eval { Q03Decision->can('_pp_env_seam') };
if ($ENV_SEAM_MAKER) {
    my $seam_a = eval { $ENV_SEAM_MAKER->({ HOME => '/tmp/decoy' }, '/tmp/real') };
    is((ref $seam_a eq 'CODE' ? eval { $seam_a->('HOME') } : undef), '/tmp/real',
       "AC-54: _pp_env_seam({HOME=>'/tmp/decoy'}, '/tmp/real')->('HOME') eq '/tmp/real' -- the authoritative home wins");
    my $seam_b = eval { $ENV_SEAM_MAKER->({ HOME => '/tmp/decoy' }, undef) };
    is((ref $seam_b eq 'CODE' ? eval { $seam_b->('HOME') } : undef), '/tmp/decoy',
       "AC-54: with the authoritative arg undef, _pp_env_seam falls back to the env hashref's HOME");
    my $seam_c = eval { $ENV_SEAM_MAKER->({ HOME => '/tmp/decoy' }, '') };
    is((ref $seam_c eq 'CODE' ? eval { $seam_c->('HOME') } : undef), '/tmp/decoy',
       "AC-54: with the authoritative arg '' (empty string), _pp_env_seam falls back to the env hashref's HOME");
    my $seam_d = eval { $ENV_SEAM_MAKER->({ HOME => '/tmp/decoy', USERPROFILE => '/tmp/up' }, '/tmp/real') };
    is((ref $seam_d eq 'CODE' ? eval { $seam_d->('USERPROFILE') } : undef), '/tmp/up',
       "AC-54: another key (USERPROFILE) passes through from the env hashref unchanged, not overridden by the authoritative-home arg");

    my $bypass_seam = eval { $ENV_SEAM_MAKER->({ HOME => '/tmp/decoy' }, '/tmp/real') };
    my %O55 = (
        registry   => {},
        extra_list => [],
        env        => (ref $bypass_seam eq 'CODE' ? $bypass_seam : sub { return undef }),
        exists     => $tripwire,
        read_file  => $tripwire,
        fold_case  => 0,
        windows    => 0,
    );
    my ($ok, $got, $err) = _try_decide('/tmp/real/.claude', \%O55);
    if (!$ok) {
        ok(0, "AC-55: refuse == 1 for /tmp/real/.claude when env => _pp_env_seam({HOME=>'/tmp/decoy'}, '/tmp/real') -- the bypass is closed");
        ok(0, "AC-55: reason eq 'claude-home' -- driven by the authoritative /tmp/real, not the raw hashref's /tmp/decoy");
        diag("decision call failed: $err") if $err;
    } else {
        is($got->{refuse}, 1, "AC-55: refuse == 1 for /tmp/real/.claude even though the raw env hashref says HOME=/tmp/decoy -- driven via the _pp_env_seam coderef (the exact bypass: without the fix this is refuse=0)");
        is($got->{reason}, 'claude-home', "AC-55: reason eq 'claude-home' -- HOME resolves to /tmp/real per the authoritative seam, not /tmp/decoy");
    }
} else {
    ok(0, "AC-54: _pp_env_seam(\$env_hashref, \$authoritative_home)->('HOME') prefers the authoritative home when defined and non-empty (sub not found in extracted region)");
    ok(0, "AC-54: _pp_env_seam falls back to the env hashref's HOME when the authoritative arg is undef (sub not found)");
    ok(0, "AC-54: _pp_env_seam falls back to the env hashref's HOME when the authoritative arg is '' (sub not found)");
    ok(0, "AC-54: _pp_env_seam passes through a non-HOME key (USERPROFILE) unchanged (sub not found)");
    ok(0, "AC-55: refuse == 1 for /tmp/real/.claude when driven via _pp_env_seam -- the bypass is closed (sub not found)");
    ok(0, "AC-55: reason eq 'claude-home' (sub not found)");
}
like($PP_CALL_BLOCK_TEXT, qr/\benv\s*=>/,
     "AC-56: the protected_path_outcome( call block in launcher.pl passes an env => key (the authoritative-home seam)");

# ---- AC-57 / AC-58 -- MAJOR-3: pin extra_list_path ----
like($PP_CALL_BLOCK_TEXT, qr/extra_list_path\s*=>\s*"[^"]+"/,
     "AC-57: the protected_path_outcome( call block passes an explicit extra_list_path key (Decision #5 pin, so CLAUDE_CONFIG_DIR cannot silently void the user list)");
{
    my ($reg_prefix)   = $PP_CALL_BLOCK_TEXT =~ /registry_path\s*=>\s*"\$\{?(\w+)\}?/;
    my ($extra_prefix) = $PP_CALL_BLOCK_TEXT =~ /extra_list_path\s*=>\s*"\$\{?(\w+)\}?/;
    ok((defined $reg_prefix && defined $extra_prefix && $reg_prefix eq $extra_prefix),
       "AC-58: registry_path and extra_list_path are built from the same authoritative-home prefix variable (not \$HOST_PLUGINS_DIR for one and a module default for the other)")
        or diag('registry_path prefix: ' . (defined $reg_prefix ? $reg_prefix : '<none>')
              . ', extra_list_path prefix: ' . (defined $extra_prefix ? $extra_prefix : '<none>'));
}

# ---- AC-59 / AC-60 / AC-61 -- MINOR-5: warning-line sanitisation ----
{
    # A hostile marketplace registry key: embedded LF, CR, an ANSI escape and
    # a bell byte, plus an attempted forged second "claude-sandbox:" line --
    # the exact attack class the fix must neutralise.
    my $HOSTILE_KEY = "evil\nclaude-sandbox: FORGED-LINE-INJECTED\r\x1b[31mFAKE\x07bell";
    my %O59 = (
        registry   => { $HOSTILE_KEY => 'not-a-hash' },   # -> one registry-entry error
        extra_list => [],
        env        => sub { my %e = (HOME => '/home/u'); return $e{ $_[0] } },
        exists     => $tripwire,
        read_file  => $tripwire,
        fold_case  => 0,
        windows    => 0,
    );
    my ($ok, $got, $err) = _try_decide('/home/u/work/myproject', \%O59);
    if (!$ok) {
        ok(0, "AC-59: no warning element contains an embedded newline, carriage return or ESC byte");
        ok(0, "AC-60: no warning element contains any other control byte in [\\x00-\\x08\\x0b-\\x1f\\x7f]");
        ok(0, "AC-61: the count of claude-sandbox:-prefixed physical lines equals the number of warning array elements");
        diag("decision call failed: $err") if $err;
    } else {
        my @w = @{ $got->{warnings} // [] };
        my $has_nl_cr_esc = grep { /\n|\r|\x1b/ } @w;
        is($has_nl_cr_esc, 0,
           "AC-59: no warning element contains an embedded newline, carriage return, or ESC byte (hostile registry key: LF/CR/ESC/forged-prefix attempt)")
            or diag('offending warnings: ' . join(' | ', map { my $x = $_; $x =~ s/[\x00-\x1f\x7f]/./g; $x } @w));

        my $has_ctrl = grep { /[\x00-\x08\x0b-\x1f\x7f]/ } @w;
        is($has_ctrl, 0,
           "AC-60: no warning element contains any other control byte in [\\x00-\\x08\\x0b-\\x1f\\x7f] (e.g. the injected bell byte)")
            or diag('offending warnings: ' . join(' | ', map { my $x = $_; $x =~ s/[\x00-\x1f\x7f]/./g; $x } @w));

        # Simulate what actually lands on STDERR (print STDERR $_, "\n" for
        # @warnings, per S2.7): join with "\n" and split back into physical
        # lines. If sanitisation strips embedded newlines, this count equals
        # scalar(@w); if it does not, the hostile key's embedded
        # "\nclaude-sandbox: FORGED-LINE-INJECTED" forges an extra line that
        # also matches the claude-sandbox: prefix, inflating the count.
        my @printed_lines = split /\n/, join("\n", @w);
        my $prefixed_count = grep { /^claude-sandbox: / } @printed_lines;
        is($prefixed_count, scalar(@w),
           "AC-61: the count of claude-sandbox:-prefixed physical lines equals the number of warning array elements (no forged extra prefix line smuggled inside one element)");
    }
}

# ---- AC-62 -- MINOR-7: _pp_explanation fallback ----
{
    my $EXPL_FN = eval { Q03Decision->can('_pp_explanation') };
    if ($EXPL_FN) {
        my $result = eval { $EXPL_FN->('future-reason') };
        my $err = $@;
        ok((defined $result && length $result),
           "AC-62: _pp_explanation('future-reason') returns a non-empty string for an unknown/unmapped reason code (no undef, no unsubstituted {explanation} placeholder)")
            or diag('got: ' . (defined $result ? "'$result'" : 'undef') . ($err ? " (eval error: $err)" : ''));
    } else {
        ok(0, "AC-62: _pp_explanation('future-reason') returns a non-empty string for an unknown reason code (sub not found)");
    }
}

# ---- AC-63 -- reviewer MINOR: the "still enforcing" trailer is always LAST ----
{
    my %O63 = (
        registry   => undef,      # supplied-but-broken -> registry-shape error
        extra_list => [],
        env        => sub { my %e = (HOME => '/home/u'); return $e{ $_[0] } },
        exists     => $tripwire,
        read_file  => $tripwire,
        fold_case  => 0,
        windows    => 0,
    );
    # A whitespace-only target: normalize_path returns undef for it (S2.4's
    # guard), so this ALSO trips the unnormalizable-target warning -- forcing
    # the registry error and that warning to co-occur, unlike existing AC-36
    # which only covers the registry-error-alone case.
    my ($ok, $got, $err) = _try_decide('   ', \%O63);
    if (!$ok) {
        ok(0, "AC-63: the final warnings element is the 'still enforcing' line even when a registry error and the unnormalizable-target warning co-occur");
        diag("decision call failed: $err") if $err;
    } else {
        my @w = @{ $got->{warnings} // [] };
        ok(scalar(@w) >= 2,
           "AC-63: warnings has multiple elements when a registry error and the unnormalizable-target warning co-occur")
            or diag('warnings: ' . join(' | ', @w));
        my $last = $w[-1] // '';
        like($last, qr/^claude-sandbox: the protected-path guard is still enforcing the \d+ protected root\(s\) it did resolve; a failed source never relaxes it\.?\z/,
             "AC-63: the final warnings element is the 'still enforcing' line even when a registry error and the unnormalizable-target warning co-occur (existing AC-36 only covers the registry-error-alone case)")
            or diag('last warning was: ' . $last);
    }
}

# ---- AC-64 / AC-65 -- R4 advice prose ----
{
    # A moderate (27-char) root: long enough that the CURRENT single-line
    # advice template (S4.6's marketplace-install/-source branch, which
    # interpolates {root} mid-sentence with no wrapping) blows past 80
    # columns, short enough that any reasonably line-wrapped fix (e.g. the
    # root on its own indented line) would comfortably fit under 80.
    my $AC64_INSTALL_ROOT = '/home/user/repo/plugin-dir';
    my $AC64_SOURCE_ROOT  = '/home/user/repo/source-dir';
    my $REG64 = {
        'mkt' => { source          => { source => 'directory', path => $AC64_SOURCE_ROOT },
                   installLocation => $AC64_INSTALL_ROOT },
    };
    my %O64 = (
        registry   => $REG64,
        extra_list => [],
        env        => sub { my %e = (HOME => '/h64'); return $e{ $_[0] } },
        exists     => $tripwire,
        read_file  => $tripwire,
        fold_case  => 0,
        windows    => 0,
    );
    for my $case (
        [ $AC64_INSTALL_ROOT, 'marketplace-install' ],
        [ $AC64_SOURCE_ROOT,  'marketplace-source'  ],
    ) {
        my ($target, $want_reason) = @$case;
        my ($ok, $got, $err) = _try_decide($target, \%O64);
        if (!$ok || !defined $got->{message} || ($got->{reason} // '') ne $want_reason) {
            ok(0, "AC-64: $want_reason advice section contains at most one occurrence of 'git clone'");
            ok(0, "AC-65: $want_reason message contains no line exceeding 80 characters");
            diag("decision call failed or reason mismatch for '$target': " . ($err || ($got->{reason} // 'undef')));
            next;
        }
        my $msg = $got->{message};
        my $gc_count = () = ($msg =~ /git clone/g);
        ok($gc_count <= 1,
           "AC-64: $want_reason advice section contains at most one occurrence of 'git clone' (no repeated instruction)");

        my @long_lines = grep { length($_) > 80 } split /\n/, $msg;
        is(scalar(@long_lines), 0,
           "AC-65: $want_reason message contains no line exceeding 80 characters (root='$target', " . length($target) . ' chars)')
            or diag('long lines: ' . join(' | ', map { length($_) . ':' . $_ } @long_lines));
    }
}

# ---- AC-66 / AC-67 -- reviewer MAJOR: docs/protected-paths.md is factually wrong ----
{
    if (defined $doc_text) {
        # Scope to source (d)'s own table row (bounded by the next row's "| e
        # |" marker) so this cannot false-positive against the unrelated
        # "registry entry" (Decision #6 error code) or "the registry file...
        # is pinned to" (registry_path-pinning paragraph) text living
        # elsewhere in the doc -- both measured to sit within a naive
        # proximity window of this row.
        my ($row_d) = $doc_text =~ /\|\s*d\s*\|(.*?)\|\s*e\s*\|/s;
        $row_d //= '';
        like($row_d, qr/registry entry|registry-derived|from the registry/i,
             "AC-66: docs/protected-paths.md's source (d) row states the ccpraxis-install root comes from the registry entry");
        like($row_d, qr/abs_path\(__FILE__\)|__FILE__/,
             "AC-66: docs/protected-paths.md's source (d) row additionally names the launcher's own abs_path(__FILE__)-derived anchor (so the root survives an unreadable registry)");
        unlike($doc_text, qr/ccpraxis live install anchor,\s*derived from the running launcher's own path/i,
               "AC-67: docs/protected-paths.md no longer contains the old single-source claim ('...derived from the running launcher's own path') with no registry mention");
    } else {
        ok(0, "AC-66: docs/protected-paths.md's source (d) row states the ccpraxis-install root comes from the registry entry (doc file does not exist yet)");
        ok(0, "AC-66: docs/protected-paths.md's source (d) row additionally names the launcher's own abs_path(__FILE__)-derived anchor (doc file does not exist yet)");
        ok(0, "AC-67: docs/protected-paths.md no longer contains the old single-source claim (doc file does not exist yet)");
    }
}

# =====================================================================
# Group L -- 03-resources-reader-model fix-batch, step 7 (AC-68)
#
# Dispatch item 7 ("sampler mode vs the refusal gate"), found by the driver
# while diagnosing the AC-42 regression above: --resources-sampler dispatches
# via $RESOURCES_SAMPLER_MODE, set during arg parsing. AC-42 already proves
# protected_path_outcome( is unconditional and precedes both mode-specific
# dispatch points by byte offset; this group adds the complementary half --
# that nothing capable of WRITING under $LAUNCHER_DIR (make_path,
# _write_file_atomic, or the sampler entry points themselves) can execute
# before that same gate. Sampler mode bind-mounts nothing and creates no
# container, so it carries no containment risk in itself -- the residual
# concern is narrower: could it still WRITE a snapshot under a
# project-derived $LAUNCHER_DIR for a project the gate would have refused?
# This group answers no and records why, rather than leaving it unstated.
# =====================================================================

# ---- AC-68 ----
{
    my $gate_pos = ($src =~ /\bprotected_path_outcome\s*\(/) ? $-[0] : undef;
    ok(defined $gate_pos, 'AC-68: the protected_path_outcome( call site is locatable (setup for the ordering checks below)');

    my @write_capable = (
        [ 'make_path($LAUNCHER_DIR)',  qr/make_path\s*\(\s*\$LAUNCHER_DIR\s*\)/ ],
        [ '_write_file_atomic(',       qr/_write_file_atomic\s*\(/ ],
        [ '_resources_sampler_main(',  qr/_resources_sampler_main\s*\(/ ],
        [ '_resources_sampler_start(', qr/_resources_sampler_start\s*\(/ ],
    );
    for my $w (@write_capable) {
        my ($label, $qr) = @$w;
        my $pos = ($src =~ $qr) ? $-[0] : undef;
        if (defined $gate_pos && defined $pos) {
            ok($pos > $gate_pos,
                "AC-68: the first occurrence of $label is AFTER protected_path_outcome( by byte offset -- nothing that can write under \$LAUNCHER_DIR runs before the refusal gate has had a chance to exit");
        } elsif (defined $gate_pos && !defined $pos) {
            pass("AC-68: $label does not appear in launcher.pl at all (vacuously after the gate)");
        } else {
            fail("AC-68: the first occurrence of $label is AFTER protected_path_outcome( by byte offset");
        }
    }

    # The one thing that DOES run before the gate in sampler mode is the
    # required-flag validation (missing/malformed --sampler-container or
    # --sampler-owner-pid => print + exit 2) -- confirmed here to write
    # nothing: it only prints to STDERR and exits, never touches
    # $LAUNCHER_DIR / the filesystem.
    my $pre_gate = defined $gate_pos ? substr($src, 0, $gate_pos) : $src;
    my ($presampler_block) = $pre_gate =~ /if\s*\(\s*\$RESOURCES_SAMPLER_MODE\s*\)\s*\{(.*?)\n\}/s;
    ok(defined $presampler_block,
        'AC-68: the pre-gate $RESOURCES_SAMPLER_MODE required-flag validation block is locatable (the only sampler-mode-specific code that runs before the refusal gate)');
    if (defined $presampler_block) {
        unlike($presampler_block, qr/\$LAUNCHER_DIR|_write_file_atomic|make_path/,
            'AC-68: the pre-gate required-flag validation block never touches $LAUNCHER_DIR / writes a file -- it only validates two flags and may exit(2)');
    } else {
        fail('AC-68: the pre-gate required-flag validation block never touches $LAUNCHER_DIR / writes a file');
    }
}

done_testing();
