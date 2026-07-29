#!/usr/bin/env perl
# b21-status-blueprint-recognition oracle. Derived from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b21-status-blueprint-recognition-spec.md
# §4.1 (test cases T1..T20, mapped to AC-1..AC-15). Written BLIND to the implementation:
# bp-status.sh is read here only as a black-box CLI (stdout/stderr/exit code captured
# separately), never opened as source. Per the spec's closing note (§4.1), T3/T4/T5/T6/T7/T10
# are the discriminating cases that MUST fail against today's unmodified bp-status.sh (missing
# `!!` section / exit 0 instead of 3 / spurious "no blueprints found" for a zero-package
# blueprint / `_archive` wrongly skipped despite having blueprint.md) -- never on a perl bug of
# this file. Several other cases (T2, T8, T11-T14, T16) fail today too, as a direct collateral
# consequence of the very same missing structural guard; that is expected and reported, not
# suppressed -- assertions here are not weakened to match a "six failures only" target.
#
# The script calls `require_cmd jq` before anything else runs, so every fixture-based case
# (T1-T18) sits inside one SKIP block gated on `command -v jq`, mirroring the idiom in
# t/62-repeat-guard.t:33,388-390 and t/09-gate.t:22,223-224. T19/T20 (live regression against
# this repo's real .ccpraxis-local-data) are nested inside a second SKIP gated on the real
# sandbox-butler-overhaul blueprint directory being present, so this file degrades gracefully
# when run outside this repo/environment.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(realpath);

(my $SCRIPT = "$Bin/../../scripts/bp-status.sh") =~ s{\\}{/}g;
(my $REPO_ROOT = realpath("$Bin/../../../..")) =~ s{\\}{/}g;

my $have_jq = do { my $o = `bash -c 'command -v jq' 2>/dev/null`; $o =~ /\S/ ? 1 : 0 };

# 80 total: 71 inside the jq-gated SKIP (T1-T18, incl. the T12/T18 stray-name loops of 3 each,
# plus the T21 embedded-newline-stray regression of 2) + 9 inside the nested live-regression
# SKIP (T19: 5, T20: 4). Both halves are fixed-length (no randomness), so this count is stable.
plan tests => 80;

sub fwd { (my $p = shift) =~ s{\\}{/}g; return $p; }

# A CLI test must control the script's environment completely -- t/09-gate.t:61-69 /
# t/62-repeat-guard.t:54-58 idiom. Strip ambient BP_* (coordinators/judges export it) and any
# ambient CCPRAXIS_DATA_DIR so every case starts from a clean, explicit environment.
my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ && $_ ne 'CCPRAXIS_DATA_DIR' } keys %ENV;

my $ROOT = tempdir(CLEANUP => 1);
my $dn = 0;
my $pn = 0;

# ---------------------------------------------------------------- fixture builders ----

sub mk_datadir {
    my $d = fwd("$ROOT/data" . (++$dn));
    make_path("$d/blueprints");
    return $d;
}

sub write_blueprint_md {
    my ($bpdir) = @_;
    make_path($bpdir);
    open my $f, '>', "$bpdir/blueprint.md" or die "write $bpdir/blueprint.md: $!";
    print $f "# Blueprint\n\nA test fixture blueprint.\n";
    close $f;
}

# blueprint.md created as a DIRECTORY, not a regular file (T14 / §2.2's "-f" clause)
sub write_blueprint_md_as_dir {
    my ($bpdir) = @_;
    make_path("$bpdir/blueprint.md");
}

sub write_pkg {
    my ($bpdir, $pkg, $status, $next) = @_;
    make_path("$bpdir/packages");
    open my $f, '>', "$bpdir/packages/$pkg.md" or die "write $bpdir/packages/$pkg.md: $!";
    print $f "---\npackage: $pkg\nstatus: $status\nlast_updated: 2026-06-24T00:00:00Z\n---\n"
           . "# $pkg\n\n## Next action\n\n$next\n";
    close $f;
}

sub mk_dir { my ($d) = @_; make_path($d); }

# ---------------------------------------------------------------- invocation ----

sub slurp {
    my ($f) = @_;
    open my $r, '<', $f or return '';
    local $/;
    my $c = <$r>;
    close $r;
    return defined $c ? $c : '';
}

# run_status(DATADIR_or_undef, ARG_or_undef, EXTRA_ENV_HASH) -> (exit, stdout, stderr)
# DATADIR undef means "do not set CCPRAXIS_DATA_DIR at all" (used only by the live T19/T20
# regression, which relies on bp_data_dir()'s BP_PROJECT_ROOT fallback).
sub run_status {
    my ($datadir, $arg, %extra_env) = @_;
    my $outf = fwd("$ROOT/out." . (++$pn) . ".txt");
    my $errf = fwd("$ROOT/err." . (++$pn) . ".txt");
    my %env = (%CLEAN_ENV, %extra_env);
    $env{CCPRAXIS_DATA_DIR} = $datadir if defined $datadir;
    local %ENV = (%env, SCRIPTPATH => fwd($SCRIPT), OUTF => $outf, ERRF => $errf);
    my @args = defined $arg ? ($arg) : ();
    open(my $f, '-|', 'bash', '-c', 'bash "$SCRIPTPATH" "$@" >"$OUTF" 2>"$ERRF"', 'h', @args)
        or die "bash: $!";
    my $discard = do { local $/; <$f> };
    close $f;
    my $rc = $? >> 8;
    return ($rc, slurp($outf), slurp($errf));
}

# ---------------------------------------------------------------- output-shape helpers ----

my $HEADER = sprintf('%-26s %-11s %-10s %-6s %-4s %s',
                      'PACKAGE', 'STATUS', 'PROC', 'AGE', 'ATT', 'NEXT ACTION');

# block_lines(OUT, NAME) -> list of lines from "== NAME" (inclusive of the column header) up
# to (not including) the blank line the script always emits at the end of a blueprint block.
# First element is always the column header; the rest are data rows.
sub block_lines {
    my ($out, $name) = @_;
    if ($out =~ /^== \Q$name\E\n((?:.*\n)*?)\n/m) {
        return split /\n/, $1;
    }
    return ();
}

sub bang_lines      { my ($out) = @_; return grep { /^!!/ } split /\n/, $out; }
sub bang_name_lines { my ($out) = @_; return grep { /^!!   \S/ } split /\n/, $out; } # 3-space indent
sub bang_stray_names {
    my ($out) = @_;
    my @names;
    for (bang_name_lines($out)) { /^!!   (.+)$/ and push @names, $1; }
    return @names;
}

sub bang_banner { return '!! UNRECOGNISED DIRECTORIES (no blueprint.md) -- NOT blueprints, NOT running:'; }
sub bang_footer { my ($data) = @_; return "!! Under $data/blueprints. Nothing was removed -- inspect and delete by hand if stale."; }

sub diag_not_blueprint_lines {
    my ($data, $name) = @_;
    return ("bp-status: '$name' is not a blueprint -- $data/blueprints/$name/blueprint.md does not exist.",
            "bp-status: the directory exists but was not run and was not removed; inspect it by hand.");
}
sub diag_no_such_line {
    my ($data, $name) = @_;
    return "bp-status: no blueprint named '$name' under $data/blueprints.";
}

sub first_index_matching {
    my ($re, @lines) = @_;
    for my $i (0 .. $#lines) { return $i if $lines[$i] =~ $re; }
    return -1;
}
sub last_index_matching {
    my ($re, @lines) = @_;
    my $last = -1;
    for my $i (0 .. $#lines) { $last = $i if $lines[$i] =~ $re; }
    return $last;
}

# =========================================================================================
SKIP: {
    skip "jq not available on this host (bp-status.sh calls require_cmd jq before anything else runs)", 71
        unless $have_jq;

    # =====================================================================================
    # T1 [AC-1, AC-15 | DC-1,7] real blueprint, two packages -> unchanged byte shape
    # =====================================================================================
    {
        my $data = mk_datadir();
        write_blueprint_md("$data/blueprints/alpha");
        write_pkg("$data/blueprints/alpha", 'p1', 'running', 'p1');
        write_pkg("$data/blueprints/alpha", 'p2', 'pending', 'p2');

        my ($rc, $out, $err) = run_status($data, undef);
        is($rc, 0, 'T1: real blueprint with 2 packages -> exit 0');
        is($err, '', 'T1: stderr empty');
        like($out, qr/^== alpha$/m, 'T1: stdout contains "== alpha"');
        my @rows = block_lines($out, 'alpha');
        is($rows[0], $HEADER, 'T1: column header matches the frozen printf format exactly');
        is(scalar(@rows) - 1, 2, 'T1: exactly 2 data rows');
        ok((grep { /^p1\s/ } @rows), 'T1: a row for package p1 is present');
        ok((grep { /^p2\s/ } @rows), 'T1: a row for package p2 is present');
    }

    # =====================================================================================
    # T2/T3/T4 [AC-2 / AC-3 / AC-4 | DC-1,2,3] shared fixture: alpha (real) + phantom/reports/
    # (stray, no blueprint.md)
    # =====================================================================================
    my ($phantom_data, $phantom_dir, $rc234, $out234, $err234);
    {
        $phantom_data = mk_datadir();
        write_blueprint_md("$phantom_data/blueprints/alpha");
        write_pkg("$phantom_data/blueprints/alpha", 'p1', 'running', 'p1');
        $phantom_dir = "$phantom_data/blueprints/phantom";
        mk_dir("$phantom_dir/reports");

        ($rc234, $out234, $err234) = run_status($phantom_data, undef);

        # ---- T2 [AC-2]: stray excluded from the listing ----
        unlike($out234, qr/^== phantom$/m, 'T2: stdout has no "== phantom" line');

        # ---- T3 [AC-3]: stray reported in the exact §2.5 !! shape ----
        my @bl = bang_lines($out234);
        is($bl[0], bang_banner(), 'T3: !! banner line matches §2.5 verbatim');
        is($bl[1], '!!   phantom', 'T3: !! name line for phantom, 3-space indent, verbatim');
        is($bl[2], bang_footer($phantom_data), 'T3: !! footer line matches §2.5 verbatim (includes <DATA>)');

        # ---- T4 [AC-4]: visual-unambiguity constraints ----
        my @all_lines = split /\n/, $out234;
        # T4a: every line of the !! section (everything from the first "!!"-prefixed line to
        # EOF) begins with "!!" -- i.e. nothing non-"!!" is interleaved after the section starts.
        # Guarded explicitly against "no !! line at all" (bang_start == -1) so a missing section
        # fails this assertion directly instead of falling through Perl's negative-index slice
        # wraparound (@arr[-1..$#arr] silently wraps to the last element, which would make this
        # assertion pass or fail for the wrong reason).
        my $bang_start = first_index_matching(qr/^!!/, @all_lines);
        if ($bang_start < 0) {
            fail('T4a: every line from the first !! line to EOF begins with "!!" (no !! line found at all)');
        } else {
            my @after_bang_start = @all_lines[$bang_start .. $#all_lines];
            is(scalar(grep { !/^!!/ } @after_bang_start), 0,
               'T4a: every line from the first !! line to EOF begins with "!!"');
        }
        ok((!grep { /^==.*phantom/ } @all_lines), 'T4b: "phantom" never appears on a line starting with "=="');
        my $header_count = () = $out234 =~ /\Q$HEADER\E/g;
        is($header_count, 1, 'T4c: the column header appears exactly once (never inside the !! section)');
        like($out234, qr/NOT blueprints, NOT running/, 'T4d: literal "NOT blueprints, NOT running" present');
        my $bang_idx = first_index_matching(qr/^!!/, @all_lines);
        my $eq_idx   = last_index_matching(qr/^== /, @all_lines);
        ok($bang_idx > $eq_idx, 'T4e: the !! banner line index is greater than every "== " line index');
    }

    # =====================================================================================
    # T21 [AC-4 regression | redteam-step6.md finding] a stray directory whose basename
    # contains an EMBEDDED NEWLINE must never let the !! section's own invariant slip: every
    # line from the first "!!" line to EOF must still start with "!!", and specifically no
    # line may start with "==" (which would look exactly like a real blueprint header). Repro
    # from the red-team report: mkdir "$(printf 'evil\n== fake-blueprint')" under blueprints/
    # defeats a naive `printf '%s\n' "!!   $NAME"` because the embedded \n splits the single
    # intended "!!   evil" line into two lines, the second of which ("== fake-blueprint")
    # carries no "!!" prefix at all and starts with "==".
    # =====================================================================================
    {
        my $data = mk_datadir();
        my $evil_name = "evil\n== fake-blueprint";
        mk_dir("$data/blueprints/$evil_name");

        my ($rc, $out, $err) = run_status($data, undef);
        my @all_lines = split /\n/, $out;

        # T21a: same shape as T4a -- every line from the first "!!" line to EOF begins with
        # "!!". Guarded against "no !! line at all" the same way T4a is, so a missing section
        # fails this assertion directly rather than via Perl's negative-index slice wraparound.
        my $bang_start = first_index_matching(qr/^!!/, @all_lines);
        if ($bang_start < 0) {
            fail('T21a: every line from the first !! line to EOF begins with "!!" (embedded-newline stray) (no !! line found at all)');
        } else {
            my @after_bang_start = @all_lines[$bang_start .. $#all_lines];
            is(scalar(grep { !/^!!/ } @after_bang_start), 0,
               'T21a: every line from the first !! line to EOF begins with "!!" (embedded-newline stray name)');
        }

        # T21b: explicitly, no line anywhere in the output starts with "==" and contains the
        # injected "fake-blueprint" text -- i.e. the embedded newline must never fabricate a
        # spoofed "== fake-blueprint" header line.
        ok((!grep { /^==.*fake-blueprint/ } @all_lines),
           'T21b: no line starting with "==" contains the newline-injected "fake-blueprint" text');
    }

    # =====================================================================================
    # T5 [AC-5 | DC-4] named arg on a stray -> loud failure
    # =====================================================================================
    {
        my ($rc, $out, $err) = run_status($phantom_data, 'phantom');
        is($rc, 3, 'T5: bp-status.sh phantom -> exit 3');
        is($out, '', 'T5: bp-status.sh phantom -> stdout empty');
        my ($l1, $l2) = diag_not_blueprint_lines($phantom_data, 'phantom');
        is($err, "$l1\n$l2\n", 'T5: stderr is exactly the 2-line diagnostic');
    }

    # =====================================================================================
    # T6 [AC-6 | DC-4] named arg, no such directory -> loud failure
    # =====================================================================================
    {
        my ($rc, $out, $err) = run_status($phantom_data, 'nope');
        is($rc, 3, 'T6: bp-status.sh nope -> exit 3');
        is($out, '', 'T6: bp-status.sh nope -> stdout empty');
        is($err, diag_no_such_line($phantom_data, 'nope') . "\n", 'T6: stderr is exactly the 1-line diagnostic');
    }

    # =====================================================================================
    # T7 [AC-7 | DC-5] real blueprint, packages/ present but EMPTY
    # =====================================================================================
    {
        my $data = mk_datadir();
        write_blueprint_md("$data/blueprints/beta");
        mk_dir("$data/blueprints/beta/packages");

        my ($rc, $out, $err) = run_status($data, undef);
        is($rc, 0, 'T7: blueprint with empty packages/ -> exit 0');
        like($out, qr/^== beta$/m, 'T7: stdout contains "== beta"');
        my @rows = block_lines($out, 'beta');
        is($rows[0], $HEADER, 'T7: column header present');
        is(scalar(@rows) - 1, 0, 'T7: zero data rows');
        unlike($out, qr/no blueprints found/, 'T7: "no blueprints found" line is ABSENT (DC-5)');
        is(scalar(bang_lines($out)), 0, 'T7: no !! section');
    }

    # =====================================================================================
    # T8 [AC-8 | DC-5] real blueprint, packages/ entirely absent
    # =====================================================================================
    {
        my $data = mk_datadir();
        write_blueprint_md("$data/blueprints/gamma");
        # no packages/ directory created at all

        my ($rc, $out, $err) = run_status($data, undef);
        is($rc, 0, 'T8: blueprint with no packages/ at all -> exit 0');
        like($out, qr/^== gamma$/m, 'T8: stdout contains "== gamma"');
        my @rows = block_lines($out, 'gamma');
        is($rows[0], $HEADER, 'T8: column header present');
        is(scalar(@rows) - 1, 0, 'T8: zero data rows');
        unlike($out, qr/no blueprints found/, 'T8: "no blueprints found" line is ABSENT (DC-5)');
        is(scalar(bang_lines($out)), 0, 'T8: no !! section');
    }

    # =====================================================================================
    # T9 [AC-9, AC-10 | DC-6] _archive/steward-plugin/blueprint.md exists, but
    # _archive/blueprint.md itself does not -> _archive on neither a "==" nor a "!!" line
    # =====================================================================================
    {
        my $data = mk_datadir();
        write_blueprint_md("$data/blueprints/alpha");
        write_pkg("$data/blueprints/alpha", 'p1', 'running', 'p1');
        write_blueprint_md("$data/blueprints/_archive/steward-plugin");

        my ($rc, $out, $err) = run_status($data, undef);
        unlike($out, qr/^== _archive$/m, 'T9: no "== _archive" line');
        unlike($out, qr/_archive/, 'T9: "_archive" never appears anywhere in stdout (neither == nor !!)');
    }

    # =====================================================================================
    # T10 [AC-11 | DC-6] a directory NAMED _archive that DOES contain blueprint.md IS listed
    # -- the discriminating test that the exclusion mechanism is structural, not name-based.
    # =====================================================================================
    {
        my $data = mk_datadir();
        write_blueprint_md("$data/blueprints/_archive");
        write_pkg("$data/blueprints/_archive", 'p1', 'running', 'p1');

        my ($rc, $out, $err) = run_status($data, undef);
        like($out, qr/^== _archive$/m, 'T10: "== _archive" IS listed when _archive/blueprint.md exists');
    }

    # =====================================================================================
    # T11 [AC-5 | DC-4,6] named arg "_archive" with no _archive/blueprint.md -> loud failure;
    # the D3 quiet-list applies only to the unsolicited !! report, never to an explicit request.
    # =====================================================================================
    {
        my $data = mk_datadir();
        mk_dir("$data/blueprints/_archive/steward-plugin"); # nested content, still no top blueprint.md

        my ($rc, $out, $err) = run_status($data, '_archive');
        is($rc, 3, 'T11: bp-status.sh _archive (no blueprint.md) -> exit 3');
        is($out, '', 'T11: bp-status.sh _archive -> stdout empty');
        my ($l1, $l2) = diag_not_blueprint_lines($data, '_archive');
        is($err, "$l1\n$l2\n", 'T11: stderr is exactly the 2-line diagnostic, naming _archive explicitly');
    }

    # =====================================================================================
    # T12 [AC-3, AC-10 | DC-2,6] three unrelated-name strays, no real blueprints -> all three
    # reported in the !! section, in glob/collation order, none on a "==" line
    # =====================================================================================
    my ($t12_data, %t12_dirs);
    {
        $t12_data = mk_datadir();
        for my $name (qw(zzz-phantom beta-copy x)) {
            $t12_dirs{$name} = "$t12_data/blueprints/$name";
            mk_dir("$t12_dirs{$name}/reports");
        }

        my ($rc, $out, $err) = run_status($t12_data, undef);
        for my $name (qw(zzz-phantom beta-copy x)) {
            unlike($out, qr/^== \Q$name\E$/m, "T12: no '== $name' line");
        }
        is_deeply([ bang_stray_names($out) ], ['beta-copy', 'x', 'zzz-phantom'],
                   'T12: all three strays appear in the !! section in shell-glob (collation) order');
    }

    # =====================================================================================
    # T13 [AC-1, AC-2 | DC-1] a stray WITH packages/p1.md but no blueprint.md is still a
    # stray; its package content is never rendered as a row anywhere in the output.
    # =====================================================================================
    my ($t13_data);
    {
        $t13_data = mk_datadir();
        write_pkg("$t13_data/blueprints/orphan", 'orphan-pkg', 'running', 'orphan-marker-xyz');

        my ($rc, $out, $err) = run_status($t13_data, undef);
        unlike($out, qr/^== orphan$/m, 'T13: no "== orphan" line despite having packages/orphan-pkg.md');
        unlike($out, qr/orphan-pkg/, 'T13: the package name "orphan-pkg" is never rendered as a row anywhere');
        unlike($out, qr/orphan-marker-xyz/, 'T13: the orphaned package\'s Next-action text never appears anywhere');
        my @names = bang_stray_names($out);
        ok((grep { $_ eq 'orphan' } @names), 'T13: "orphan" itself IS reported as a stray in the !! section');
    }

    # =====================================================================================
    # T14 [AC-1 | DC-1] blueprint.md created as a DIRECTORY (not -f) -> still a stray
    # =====================================================================================
    my ($t14_data);
    {
        $t14_data = mk_datadir();
        write_blueprint_md_as_dir("$t14_data/blueprints/gamma");

        my ($rc, $out, $err) = run_status($t14_data, undef);
        unlike($out, qr/^== gamma$/m, 'T14: no "== gamma" line when blueprint.md is a directory, not a file');
        my @names = bang_stray_names($out);
        ok((grep { $_ eq 'gamma' } @names), 'T14: "gamma" IS reported as a stray (blueprint.md-as-directory does not count)');
    }

    # =====================================================================================
    # T15 [AC-15] empty blueprints/ dir -> "no blueprints found ...", no !!, exit 0
    # =====================================================================================
    {
        my $data = mk_datadir(); # blueprints/ created empty by mk_datadir()
        my ($rc, $out, $err) = run_status($data, undef);
        is($rc, 0, 'T15: empty blueprints/ -> exit 0');
        is($err, '', 'T15: empty blueprints/ -> stderr empty');
        is($out, "no blueprints found under $data/blueprints\n", 'T15: stdout is exactly the "no blueprints found" line');
    }
    {
        # bonus coverage of §3 behavior 16's "or absent" clause (same test index; no separate
        # AC/DC is assigned to this half in the spec's table, so it augments T15 rather than
        # introducing a new numbered case)
        my $data = fwd("$ROOT/data" . (++$dn)); # note: blueprints/ deliberately NOT created
        my ($rc, $out, $err) = run_status($data, undef);
        is($rc, 0, 'T15b: entirely absent <D> -> exit 0');
        is($out, "no blueprints found under $data/blueprints\n", 'T15b: absent <D> -> same "no blueprints found" line');
    }

    # =====================================================================================
    # T16 [AC-3, AC-4 | DC-2,3] strays only, no real blueprints -> "no blueprints found ..."
    # FOLLOWED BY the !! section, exit 0
    # =====================================================================================
    {
        my $data = mk_datadir();
        mk_dir("$data/blueprints/stray1/reports");

        my ($rc, $out, $err) = run_status($data, undef);
        is($rc, 0, 'T16: strays-only -> exit 0');
        like($out, qr/no blueprints found under \Q$data\E\/blueprints/, 'T16: "no blueprints found" line present');
        my @bl = bang_lines($out);
        ok(scalar(@bl) > 0, 'T16: !! section present');
        my $no_bp_idx = first_index_matching(qr/no blueprints found/, split /\n/, $out);
        my $bang_idx  = first_index_matching(qr/^!!/, split /\n/, $out);
        ok($no_bp_idx >= 0 && $bang_idx > $no_bp_idx,
           'T16: the !! section comes AFTER the "no blueprints found" line');
    }

    # =====================================================================================
    # T17 [AC-3 | DC-2] named arg scopes the stray report away entirely
    # =====================================================================================
    {
        my $data = mk_datadir();
        write_blueprint_md("$data/blueprints/alpha");
        write_pkg("$data/blueprints/alpha", 'p1', 'running', 'p1');
        mk_dir("$data/blueprints/phantom/reports");

        my ($rc, $out, $err) = run_status($data, 'alpha');
        is($rc, 0, 'T17: bp-status.sh alpha (phantom also present) -> exit 0');
        like($out, qr/^== alpha$/m, 'T17: stdout contains "== alpha"');
        unlike($out, qr/phantom/, 'T17: "phantom" never appears anywhere (the loop never visits it)');
        is(scalar(bang_lines($out)), 0, 'T17: no !! section (named-arg scoping suppresses it entirely)');
    }

    # =====================================================================================
    # T18 [AC-14 | DC-2] non-destructive: re-stat every stray fixture used above
    # =====================================================================================
    {
        ok(-d $phantom_dir, 'T18: phantom/ (from T2/T3/T4) still exists after all prior invocations');
        for my $name (qw(zzz-phantom beta-copy x)) {
            ok(-d $t12_dirs{$name}, "T18: stray '$name' (from T12) still exists");
        }
        ok(-d "$t13_data/blueprints/orphan", 'T18: the orphan stray (from T13) still exists');
        ok(-d "$t14_data/blueprints/gamma", 'T18: the gamma stray-as-dir (from T14) still exists');
    }

    # =====================================================================================
    # T19/T20 [AC-12, AC-13 | DC-6,7] LIVE regression against this repo's real
    # .ccpraxis-local-data/blueprints/sandbox-butler-overhaul. Skips gracefully if absent.
    # =====================================================================================
    my $LIVE_BP_DIR = "$REPO_ROOT/.ccpraxis-local-data/blueprints/sandbox-butler-overhaul";
    SKIP: {
        skip "sandbox-butler-overhaul blueprint dir absent under $REPO_ROOT/.ccpraxis-local-data "
           . "(not running inside this repo's checkout)", 9
            unless -d $LIVE_BP_DIR;

        # ---- T19: bp-status.sh sandbox-butler-overhaul ----
        # NOTE: glob() in scalar context is an ITERATOR (returns one match per call, not a
        # count) -- must collect into a list first, then take scalar(@list).
        my @live_pkg_files = glob("$LIVE_BP_DIR/packages/*.md");
        my $expected_rows = scalar(@live_pkg_files);
        my ($rc19, $out19, $err19) = run_status(undef, 'sandbox-butler-overhaul', BP_PROJECT_ROOT => $REPO_ROOT);
        is($rc19, 0, 'T19: live - bp-status.sh sandbox-butler-overhaul -> exit 0');
        is($err19, '', 'T19: live - stderr empty');
        like($out19, qr/^== sandbox-butler-overhaul$/m, 'T19: live - stdout contains "== sandbox-butler-overhaul"');
        my @rows19 = block_lines($out19, 'sandbox-butler-overhaul');
        is(scalar(@rows19) - 1, $expected_rows,
           "T19: live - data-row count equals scalar(glob packages/*.md) == $expected_rows (computed, not hardcoded)");
        is(scalar(bang_lines($out19)), 0, 'T19: live - no !! section');

        # ---- T20: bp-status.sh (no arg) ----
        my ($rc20, $out20, $err20) = run_status(undef, undef, BP_PROJECT_ROOT => $REPO_ROOT);
        like($out20, qr/^== sandbox-butler-overhaul$/m, 'T20: live no-arg - "== sandbox-butler-overhaul" present');
        unlike($out20, qr/^== _archive$/m, 'T20: live no-arg - "_archive" appears on no "==" line');
        my @names20 = bang_stray_names($out20);
        ok((!grep { $_ eq '_archive' } @names20), 'T20: live no-arg - "_archive" appears on no "!!" line');
        is(scalar(bang_lines($out20)), 0, 'T20: live no-arg - no !! section at all (this repo has no strays)');
    }
}
