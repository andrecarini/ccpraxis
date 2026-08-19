#!/usr/bin/env perl
# 163-no-duplicate-test-numbers.t — d01-test-numbering-collisions: this
# package's own acceptance oracle.
#
# NOTE ON SCOPE (spec §2.5, explicit): this is an ordinary test-writer
# deliverable proving THIS PACKAGE's own done-criteria, not "a numbering
# convention or guard hook" (out of scope, ledger). It happens to also catch
# a FUTURE duplicate as an incidental side effect of testing today's
# done-criteria the same way any other package's oracle would — that is not
# this package claiming to have "solved" recurrence, and this file must not
# be mistaken for a pre-commit/CI guard.
#
# Written BLIND to the implementation of the renames themselves — directly
# from specs/d01-test-numbering-collisions-spec.md and the two 2026-08-19
# driver corrections recorded in the package ledger's attempt log:
#   (1) the spec's Tier-0 untracked/tracked conflict is FALSE — all 18
#       source files are tracked; plain `git mv` applies uniformly.
#   (2) pair 20 is resolved by the driver at Tier 4 (alphabetical):
#       20-deps-check.t keeps the number; 20-orchestrator-broken-env-turns.t
#       renumbers to 154.
#
# Fixture/mechanics conventions (real files on disk, real `git ls-files` for
# the repo-wide citation sweep, `perl -c` for the compile check, capture via
# a REAL temp file never an in-memory STDOUT reopen) lifted from
# t/153-no-drift-to-repair.t and t/00-oracle-hygiene.t.
#
# Directory listing uses opendir/readdir throughout, NEVER perl's built-in
# glob() — glob() splits on whitespace and this host's paths contain
# non-ASCII characters (project CLAUDE.md).

use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

my $DIR  = dirname(abs_path(do { (my $f = __FILE__) =~ s{\\}{/}g; $f }));
my $ROOT = abs_path("$DIR/../../../..");   # repo root: t -> tests -> butler -> plugins -> root
my $TDIR = abs_path("$DIR");                # plugins/butler/tests/t itself

ok(-d $TDIR, 'sanity: plugins/butler/tests/t exists') or BAIL_OUT('nothing to test');
ok(-d $ROOT && -f "$ROOT/CLAUDE.md", 'sanity: repo root resolved correctly (CLAUDE.md found there)')
    or BAIL_OUT("repo root mis-resolved as $ROOT");

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# ============================================================================
# SECTION 1 (DC1 / AC1-2). A GENERAL scan of plugins/butler/tests/t/ — every
# file, not a hardcoded list of nine — shows every leading number unique.
# This is the package's headline claim; a hardcoded nine-pair list would
# stay green forever even if a TENTH collision appeared tomorrow, which is
# exactly the "assertion that cannot fail" shape this package exists to
# avoid. opendir/readdir only (never glob()) per the non-ASCII-path landmine.
# ============================================================================
{
    opendir(my $dh, $TDIR) or BAIL_OUT("cannot opendir $TDIR: $!");
    my @entries = readdir $dh;
    closedir $dh;

    my @t_files = sort grep { -f "$TDIR/$_" && /\.t\z/ } @entries;
    ok(scalar(@t_files) > 100,
       'SECTION 1 sanity: the directory scan itself found a plausible number of .t files ('
     . scalar(@t_files) . ') — a broken/empty scan cannot pass the rest of this section vacuously')
        or diag('directory scan found suspiciously few files; check $TDIR resolution');

    my %by_number;
    my @unnumbered;
    for my $f (@t_files) {
        if ($f =~ /^(\d+)-/) {
            push @{ $by_number{$1} }, $f;
        } else {
            push @unnumbered, $f;
        }
    }
    is(scalar(@unnumbered), 0,
       'SECTION 1: every .t file in the directory follows the NN-slug.t house numbering convention ('
     . join(', ', @unnumbered) . ')');

    my @dupes = sort { $a <=> $b } grep { scalar(@{ $by_number{$_} }) > 1 } keys %by_number;
    is(scalar(@dupes), 0,
       'SECTION 1 (DC1, general): no leading number in plugins/butler/tests/t/ is shared by two or '
     . 'more files — offending numbers: '
     . join('; ', map { "$_ => [" . join(', ', @{ $by_number{$_} }) . "]" } @dupes));
}

# ============================================================================
# SECTION 2 (DC1, AC2 specific / DC3). The nine collision numbers each
# resolve to exactly one file; the winner keeps its number, the loser has
# moved to its §2.1 new number, and its old basename no longer exists in the
# directory at all. Table locked by spec §2.1, with the two 2026-08-19
# driver corrections applied (plain git mv for all 18; pair 20 resolved to
# 20-deps-check.t keeping the number).
# ============================================================================
my @pairs = (
    { num => 20,  winner => '20-deps-check.t',
                  loser  => '20-orchestrator-broken-env-turns.t',  new => '154-orchestrator-broken-env-turns.t' },
    { num => 79,  winner => '79-contract-idle-window.t',
                  loser  => '79-worker-backend-dispatcher.t',      new => '155-worker-backend-dispatcher.t' },
    { num => 80,  winner => '80-rate-limit-attempt-isolation.t',
                  loser  => '80-worker-jail-isolation.t',          new => '156-worker-jail-isolation.t' },
    { num => 81,  winner => '81-usage-poll-cadence.t',
                  loser  => '81-opencode-worker-runtime.t',        new => '157-opencode-worker-runtime.t' },
    { num => 82,  winner => '82-orphaned-judge-recovery.t',
                  loser  => '82-worker-model-preference.t',        new => '158-worker-model-preference.t' },
    { num => 98,  winner => '98-write-guard-primitive.t',
                  loser  => '98-status-read-api.t',                new => '159-status-read-api.t' },
    { num => 99,  winner => '99-write-guard-sites.t',
                  loser  => '99-status-read-api-regressions.t',    new => '160-status-read-api-regressions.t' },
    { num => 101, winner => '101-guard-writes-specificity.t',
                  loser  => '101-lifecycle-derived.t',             new => '161-lifecycle-derived.t' },
    { num => 108, winner => '108-match-any-divergence.t',
                  loser  => '108-status-vocabulary-seventh.t',     new => '162-status-vocabulary-seventh.t' },
);

for my $p (@pairs) {
    ok(-f "$TDIR/$p->{winner}", "SECTION 2 (#$p->{num}): winner $p->{winner} exists");
    ok(!-f "$TDIR/$p->{loser}",
       "SECTION 2 (#$p->{num}): loser's OLD basename $p->{loser} no longer exists in the directory");
    ok(-f "$TDIR/$p->{new}",
       "SECTION 2 (#$p->{num}): loser's NEW path $p->{new} exists");
}

# ============================================================================
# SECTION 3 (DC2 / AC3, §2.4's completeness proof). Repo-wide: no surviving
# citation of any of the nine old-loser basenames, anywhere under the
# spec's search roots, except the two named pre-authorized exclusions
# (§2.3), which must still carry the OLD text unchanged.
#
# Coverage is TWO scans, combined:
#   (a) `git ls-files` (tracked files only) restricted to plugins/**,
#       docs/**, CLAUDE.md, skills/**. .git/ is excluded by construction
#       (git ls-files never lists it).
#   (b) a live opendir/readdir recursion of .ccpraxis-local-data/blueprints/,
#       done SEPARATELY because that whole tree is gitignored
#       (.gitignore:19) -- `git ls-files` can NEVER return anything from it,
#       so folding it into (a)'s root list (as a prior revision of this file
#       did) produces a search that *claims* to cover live blueprints but
#       structurally cannot: it silently contributes zero files no matter
#       how many stale citations exist there. That was a real, confirmed gap
#       (red-team MEDIUM-1, 2026-08-19): 772 lines of hits in
#       _archive/ alone, invisible to (a). opendir/readdir only, per the
#       non-ASCII-path landmine (never glob(), which splits on whitespace).
#
# _archive/** is walked but its findings are DISCARDED, not searched at all:
# an archived blueprint is an immutable historical record of a finished
# initiative, and its specs legitimately name old basenames because that is
# what those specs said at the time they were written and executed. The
# defect this section fixes was never "the archive has old names" -- it is
# that the oracle *claimed* a coverage of .ccpraxis-local-data/blueprints/
# that it structurally could not deliver. Excluding _archive/ by directory
# prefix restores honesty about scope without rewriting frozen history.
# ============================================================================
{
    my @roots = ('plugins', 'docs', 'CLAUDE.md', 'skills');
    my $file_list = `cd "$ROOT" && git ls-files -- @roots 2>&1`;
    my @tracked = grep { length } split /\r?\n/, $file_list;
    ok(scalar(@tracked) > 400,
       'SECTION 3 sanity: git ls-files over the tracked search roots found a plausible number of files ('
     . scalar(@tracked) . ')') or diag("git ls-files output: $file_list");

    # Live blueprints: NOT under git (gitignored), so walked directly.
    # _archive/ is excluded here by directory-name check, not searched at
    # all -- see the section header comment for why.
    my @blueprint_files;
    {
        my $bp_root = "$ROOT/.ccpraxis-local-data/blueprints";
        my @stack = ($bp_root);
        while (my $dir = pop @stack) {
            opendir(my $dh, $dir) or next;
            for my $entry (readdir $dh) {
                next if $entry eq '.' || $entry eq '..';
                my $abs = "$dir/$entry";
                if (-d $abs) {
                    next if $entry eq '_archive';
                    push @stack, $abs;
                } elsif (-f $abs) {
                    my $rel = $abs;
                    $rel =~ s{\A\Q$ROOT\E[\\/]}{};
                    $rel =~ s{\\}{/}g;
                    push @blueprint_files, $rel;
                }
            }
            closedir $dh;
        }
    }
    ok(scalar(@blueprint_files) > 0,
       'SECTION 3 sanity: the live .ccpraxis-local-data/blueprints/ scan (excluding _archive/) found at '
     . 'least one file (' . scalar(@blueprint_files) . ') -- this is the assertion that catches the '
     . 'illusory-coverage class of defect: a broken/empty walk here must not pass the rest of this '
     . 'section vacuously, the same way git ls-files silently returning zero for a gitignored root did')
        or diag('live blueprint scan found zero files; check .ccpraxis-local-data/blueprints/ resolution');

    my @searched = (@tracked, @blueprint_files);

    # Pre-authorized exclusions (§2.3/§2.4): these must be found, and must
    # still contain the OLD text verbatim (deliberately left, not
    # accidentally missed).
    my %exempt_files = (
        'plugins/butler/tests/t/148-registry-runtime-only.t' => 1,
        'plugins/butler/tests/t/67-wait-shape-guard.t'        => 1,
        # THIS FILE, added 2026-08-19 by driver adjudication. The scan below
        # greps every tracked file for each loser's OLD basename -- and this
        # oracle's own @pairs table must NAME those basenames in order to
        # search for them. So it found itself, nine times, and reported its own
        # data as nine surviving citations. Tautological, not a real hit: the
        # failure message even named the culprit ("found in:
        # plugins/butler/tests/t/163-no-duplicate-test-numbers.t").
        #
        # Exempting the whole file is the right scope rather than a narrower
        # line-level skip: every occurrence of an old basename in here is by
        # construction part of the search definition, so there is no class of
        # genuine stale citation inside this file that the exemption could
        # hide. The implementer hit this, flagged it as a suspected wrong test,
        # and did NOT edit the immutable oracle -- which is why it is corrected
        # here rather than worked around there.
        'plugins/butler/tests/t/163-no-duplicate-test-numbers.t' => 1,
    );

    # d01's own package/spec/report files legitimately name the old
    # basenames -- they describe the rename itself. A directory/prefix scope
    # (rather than listing each report filename) means a ninth report added
    # later is covered automatically instead of needing a new line here; it
    # is still narrow enough that a stale citation in an unrelated live
    # blueprint package (d02-d05, or a future one) is NOT hidden by it.
    my @exempt_prefixes = (
        '.ccpraxis-local-data/blueprints/ccpraxis-tooling-debt/packages/d01-test-numbering-collisions.md',
        '.ccpraxis-local-data/blueprints/ccpraxis-tooling-debt/specs/d01-test-numbering-collisions-spec.md',
        '.ccpraxis-local-data/blueprints/ccpraxis-tooling-debt/reports/d01-test-numbering-collisions/',
    );
    my $is_exempt_by_prefix = sub {
        my ($rel) = @_;
        for my $pfx (@exempt_prefixes) {
            return 1 if $rel eq $pfx || index($rel, $pfx) == 0;
        }
        return 0;
    };

    for my $p (@pairs) {
        my @hits;
        for my $rel (@searched) {
            next if $exempt_files{$rel};
            next if $is_exempt_by_prefix->($rel);
            my $abs = "$ROOT/$rel";
            next unless -f $abs;
            my $content = slurp($abs);
            next unless defined $content;
            push @hits, $rel if index($content, $p->{loser}) >= 0;
        }
        is(scalar(@hits), 0,
           "SECTION 3 (DC2, #$p->{num}): zero surviving citations of old basename $p->{loser} "
         . '(outside the pre-authorized exclusions) -- found in: ' . join(', ', @hits));
    }

    # The two exclusions themselves: confirm they still exist and still
    # carry the OLD text they were authorized to keep (a citation-scan
    # assertion that never matched anything would be silently vacuous —
    # this pins the detector to two REAL, currently-present strings).
    my $c148 = slurp("$ROOT/plugins/butler/tests/t/148-registry-runtime-only.t");
    like($c148, qr/Renumbered from the ledger's original t\/99 to t\/118, then to t\/148/,
         'SECTION 3 exclusion: 148-registry-runtime-only.t:9 keeps its historical "t/99" note unchanged '
       . '(not a live citation of either current t/99 file)');

    my $c67 = slurp("$ROOT/plugins/butler/tests/t/67-wait-shape-guard.t");
    like($c67, qr{plugins/butler/tests/t/20-turns\.t},
         'SECTION 3 exclusion: 67-wait-shape-guard.t:391 keeps its decayed "t/20-turns.t" fixture '
       . 'string unchanged (never a real file under any name)');
}

# ============================================================================
# SECTION 4 (DC2 / AC4, bare-number citation split, §2.3's rule). Four
# concrete bare-number citations the spec/scout identified by exact
# file:context as resolving to a LOSING file: each MUST now read the new
# bare number. Matched by unique surrounding text (not line number, which a
# content edit could shift), so each regex is proven able to match today's
# (pre-rename) text before being trusted to detect tomorrow's.
# ============================================================================
{
    my @loser_citations = (
        { file => 'plugins/butler/scripts/BpState.pm',
          desc => 'BpState.pm: "word\" (t/NN, observable-6)" resolves to 101-lifecycle-derived.t (a loser)',
          re_old => qr/\(t\/101, observable-6\)/,
          re_new => qr/\(t\/161, observable-6\)/ },
        { file => 'plugins/butler/scripts/BpState.pm',
          desc => 'BpState.pm: "(t/NN AC7 \"ac7-stale-done\"), not" resolves to 101-lifecycle-derived.t (a loser)',
          re_old => qr/\(t\/101 AC7 "ac7-stale-done"\), not/,
          re_new => qr/\(t\/161 AC7 "ac7-stale-done"\), not/ },
        { file => 'plugins/butler/scripts/BpState.pm',
          desc => 'BpState.pm: "comments: t/NN\'s DC1 scans" resolves to 98-status-read-api.t (a loser)',
          re_old => qr/comments: t\/98's DC1 scans/,
          re_new => qr/comments: t\/159's DC1 scans/ },
        { file => 'plugins/butler/tests/t/120-mark-wakeup-agent-dispatch.t',
          desc => '120: "t/NN:361/435/440, track-dispatch.sh:24)" resolves to 79-worker-backend-dispatcher.t (a loser)',
          re_old => qr/t\/79:361\/435\/440, track-dispatch\.sh:24\)/,
          re_new => qr/t\/155:361\/435\/440, track-dispatch\.sh:24\)/ },
    );

    for my $c (@loser_citations) {
        my $content = slurp("$ROOT/$c->{file}");
        ok(defined $content, "SECTION 4 sanity: $c->{file} is readable") or next;
        ok($content =~ $c->{re_old} || $content =~ $c->{re_new},
           "SECTION 4 non-vacuity ($c->{desc}): the detector pattern matches either the pre- or "
         . 'post-rename text (proves the regex is not simply broken)')
            or diag("neither pattern matched in $c->{file}");
        like($content, $c->{re_new},
             "SECTION 4 (DC2, loser-resolved bare citation): $c->{desc} -- now cites the new bare number");
    }

    # Complementary WINNER-side checks: a bare citation resolving to the
    # WINNING file of a pair must stay UNCHANGED (spec §2.3) -- leaving it
    # alone is the correct outcome, not an oversight, and this is exactly as
    # testable as "must change".
    my @winner_citations = (
        { file => 'plugins/butler/scripts/BpState.pm',
          desc => 'BpState.pm:277 "(t/101 AC7 \"ac7-stale-done\": an old-shape" resolves to 101-guard-writes-specificity.t (the winner)',
          re   => qr/\(t\/101 AC7 "ac7-stale-done": an old-shape/ },
        { file => 'plugins/butler/tests/t/111-keepawake-shared.t',
          desc => '111: "match_any needed t/108 to guard its two" resolves to 108-match-any-divergence.t (the winner)',
          re   => qr/match_any needed t\/108 to guard its two/ },
        { file => 'plugins/butler/tests/t/84-green-baseline.t',
          desc => "84: \"t/80's C12\" resolves to 80-rate-limit-attempt-isolation.t (the winner)",
          re   => qr/t\/80's C12/ },
    );
    for my $c (@winner_citations) {
        my $content = slurp("$ROOT/$c->{file}");
        ok(defined $content, "SECTION 4 sanity: $c->{file} is readable") or next;
        like($content, $c->{re},
             "SECTION 4 (winner-resolved bare citation left correctly unchanged): $c->{desc}");
    }
}

# ============================================================================
# SECTION 5 (DC5-adjacent, this package's own file-count invariant). A
# rename must not add or lose a file: the pre-rename count of tracked .t
# files in this directory, PLUS this oracle itself, is the post-rename
# count. Pre-rename count independently confirmed via `git ls-files` at
# test-writing time: 131. 131 + 1 (this file) = 132.
# ============================================================================
{
    opendir(my $dh, $TDIR) or BAIL_OUT("cannot opendir $TDIR: $!");
    my @all_t = grep { -f "$TDIR/$_" && /\.t\z/ } readdir $dh;
    closedir $dh;
    is(scalar(@all_t), 132,
       'SECTION 5: plugins/butler/tests/t/ holds exactly 132 .t files -- 131 confirmed pre-rename '
     . '(git ls-files, test-writing time) plus this oracle itself; a rename must not add or lose a file');
}

# ============================================================================
# SECTION 6 (this package's own "renamed file still runs" check, spec
# observable 10's spirit). Every renamed file that exists compiles cleanly
# under `perl -c` -- a rename that produces a file perl cannot execute is
# worse than the collision it replaced. Syntax-only (no test logic
# executed), real subprocess, real temp file capture (never an in-memory
# STDOUT reopen -- project CLAUDE.md).
# ============================================================================
{
    require File::Temp;
    for my $p (@pairs) {
        my $path = "$TDIR/$p->{new}";
        SKIP: {
            skip "SECTION 6 (#$p->{num}): $p->{new} does not exist yet -- covered by SECTION 2's presence check", 1
                unless -f $path;
            my ($tfh, $tmp) = File::Temp::tempfile();
            close $tfh;
            open(my $saved, '>&', \*STDOUT) or die "dup: $!";
            open(STDOUT, '>', $tmp) or die "redirect: $!";
            my $rc = system($^X, '-c', $path);
            open(STDOUT, '>&', $saved);
            close $saved;
            unlink $tmp;
            is($rc, 0, "SECTION 6 (#$p->{num}): $p->{new} compiles cleanly (perl -c)");
        }
    }
}

done_testing();
