#!/usr/bin/env perl
# platform: any
# ORACLE for package 22-ledger-rescope: three new bp-ledger.pl verbs that give a
# coordinator a typed path to re-scope a package ledger, so a re-scope never again
# means "drop this package and create a new one" (Decision 84, driven by the
# operator's own words: "if your solution was dropping a package and creating a new
# one, then that means there's missing functionality to allow you to do things the
# correct way. Bugfix it.").
#
# `set-write-set --ledger L --decision N --path P [--path P ...]` and
# `set-test-paths` (same shape): REPLACE the named frontmatter field wholesale
# (narrow or widen in one call, unlike the additive-only `widen-write-set`). Every
# path in the NEW set that was not already in the OLD set must appear verbatim in
# blueprint Decision N's text -- removed paths need no naming.
#
# Decision 89 (correcting Decision 84's own refusal rule, caught before commit):
# rescoping a running package between worker dispatches is exactly the use case,
# so the package's OWN in-flight membership and its OWN status of `running` are
# NOT reasons to refuse -- only status `done` or `dropped` refuse outright, ledger
# byte-identical. Separately, when the call ADDS a path (one not already in the
# field), it is refused if that added path overlaps the write_set of ANOTHER
# package listed in <data>/.drive-solo/inflight.json (the same overlap semantics
# `widen-write-set` already applies via `_widen_check_inflight_conflict`), naming
# the conflicting package and leaving the ledger byte-identical. Removing paths is
# always allowed, even when the remaining paths still overlap another in-flight
# package.
#
# `set-section --ledger L --section S (--text T | --text-file F)`: replaces the
# body of exactly one of Scope, Done criteria, Inputs, Out of scope. Every other
# heading -- an unknown name, and every section this file already gives its own
# dedicated typed verb (Pipeline via tick-step, Decisions & attempt log via
# append-attempt, Next action via set-next-action), plus Outputs and Escalation,
# which are simply outside the enumerated allow-list -- is refused. A successful
# call leaves the frontmatter byte-identical (this is new relative to the other
# mutating verbs, which are free to bump last_updated).
#
# Written from Decision 84 (.ccpraxis-local-data/blueprints/hook-continuity-remake/
# blueprint.md) and the package ledger's own CONTRACT attempt-log entry ONLY --
# never from bp-ledger.pl's implementation, which does not carry these three verbs
# yet. Fixtures follow ledger-widen-write-set.t's idiom (a ledger built through the
# real `create` verb, plus a hand-written blueprint.md whose Decision rows name the
# paths a widening is allowed to add) so this file exercises the same production
# code paths (op_create_dirname resolution, _decision_text, run_op's atomicity) a
# real coordinator would.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec ();
use JSON::PP ();
use POSIX qw(_exit);

my $LEDGER_PL = "$Bin/../../scripts/bp-ledger.pl";
my $TEMPLATE  = "$Bin/../../../blueprint/templates/package-ledger.md";
ok(-f $LEDGER_PL && -f $TEMPLATE, 'bp-ledger.pl and the ledger template exist') or BAIL_OUT('missing inputs');

# ---------------------------------------------------------------------------
# small shared helpers (fork+exec bp-ledger.pl only; STDIN from /dev/null;
# bounded with a hard alarm so a hang here can never wedge a sweep)
# ---------------------------------------------------------------------------

sub slurp {
    my ($p) = @_;
    return undef unless -f $p;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p =~ s{/+\z}{}; return $p }

sub write_json {
    my ($path, $data) = @_;
    (my $dir = $path) =~ s{[^/\\]*\z}{};
    make_path($dir) unless -d $dir;
    open my $fh, '>:raw', $path or die "open $path: $!";
    print {$fh} JSON::PP->new->utf8->canonical->encode($data);
    close $fh;
}

sub run_cli {
    my (@args) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $out = "$dir/out";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDIN, '<', File::Spec->devnull) or _exit(126);
        open(STDOUT, '>', $out) or _exit(126);
        open(STDERR, '>&', \*STDOUT) or _exit(126);
        exec($^X, $LEDGER_PL, @args) or _exit(127);
    }
    local $SIG{ALRM} = sub { kill('KILL', $pid); waitpid($pid, 0); die "run_cli: bp-ledger.pl timed out\n" };
    alarm(30);
    waitpid($pid, 0);
    alarm(0);
    return ($? >> 8, slurp($out) // '');
}

sub field {
    my ($ledger, $key) = @_;
    my ($v) = slurp($ledger) =~ /^\Q$key\E:[ \t]*(.*?)[ \t]*$/m;
    return $v;
}

sub frontmatter {
    my ($bytes) = @_;
    return $1 if $bytes =~ /\A(---\s*\n.*?\n---)/s;
    return undef;
}

sub write_blueprint {
    my ($path, @rows) = @_;   # each row: [id, text]
    open my $w, '>:raw', $path or die "open $path: $!";
    print {$w} "# bp1\n\n| # | Decision | Decided by | Date |\n|---|---|---|---|\n";
    for my $r (@rows) {
        print {$w} "| $r->[0] | $r->[1] | driver | 2026-09-25 |\n";
    }
    close $w;
}

# fixture(%opts) -> ($ledger, $bp_dir, $data_dir). Builds:
#   $data/blueprints/<blueprint>/blueprint.md   (decision rows from %opts{decisions})
#   $data/blueprints/<blueprint>/packages/<package>.md  (via the real `create` verb)
# optionally flips status (set-status) and/or seeds .drive-solo/inflight.json.
sub fixture {
    my (%o) = @_;
    my $bp_name = $o{blueprint} // 'bp1';
    my $pkg     = $o{package}   // '01-a';
    my $root    = fwd(tempdir(CLEANUP => 1));
    my $data    = "$root/data";
    my $bp_dir  = "$data/blueprints/$bp_name";
    make_path("$bp_dir/packages");
    my $ledger = "$bp_dir/packages/$pkg.md";

    my @create_args = ('create', '--ledger', $ledger, '--package', $pkg, '--blueprint', $bp_name,
                        '--template', $TEMPLATE, '--write-set', $o{write_set} // 'src/a.pl:t/a.t');
    push @create_args, ('--test-paths', $o{test_paths}) if defined $o{test_paths};
    my ($rc, $out) = run_cli(@create_args);
    die "fixture create failed ($rc): $out" unless $rc == 0;

    write_blueprint("$bp_dir/blueprint.md", @{ $o{decisions} // [] });

    if (defined $o{status}) {
        my ($rc2, $out2) = run_cli('set-status', '--ledger', $ledger, '--status', $o{status});
        die "fixture set-status failed ($rc2): $out2" unless $rc2 == 0;
    }
    if (defined $o{inflight}) {
        write_json("$data/.drive-solo/inflight.json", $o{inflight});
    }
    return ($ledger, $bp_dir, $data);
}

# fixture_pair(%opts) -> ($ledger_a, $data). Builds TWO packages under the SAME
# blueprint/data root (bp1/01-a and bp1/02-conflict), each via the real `create`
# verb, plus inflight.json listing 02-conflict (never 01-a) with its `ledger`
# field pointing at 02-conflict's real ledger path relative to the data dir --
# the shape _widen_check_inflight_conflict resolves. Used to exercise the
# Decision 89 overlap-on-add refusal (bp-ledger.pl's existing widen-write-set
# tests do not carry a conflict fixture of their own, so this one is built
# directly from _widen_check_inflight_conflict's own doc comment and code).
sub fixture_pair {
    my (%o) = @_;
    my $bp_name = 'bp1';
    my $root    = fwd(tempdir(CLEANUP => 1));
    my $data    = "$root/data";
    my $bp_dir  = "$data/blueprints/$bp_name";
    make_path("$bp_dir/packages");
    my $ledger_a = "$bp_dir/packages/01-a.md";
    my $ledger_b = "$bp_dir/packages/02-conflict.md";

    for my $spec ([$ledger_a, '01-a', $o{ws_a}, $o{test_paths_a}], [$ledger_b, '02-conflict', $o{ws_b}, undef]) {
        my ($l, $pkg, $ws, $tp) = @$spec;
        my @args = ('create', '--ledger', $l, '--package', $pkg, '--blueprint', $bp_name,
                    '--template', $TEMPLATE, '--write-set', $ws);
        push @args, ('--test-paths', $tp) if defined $tp;
        my ($rc, $out) = run_cli(@args);
        die "fixture_pair create $pkg failed ($rc): $out" unless $rc == 0;
    }

    write_blueprint("$bp_dir/blueprint.md", @{ $o{decisions} // [] });

    write_json("$data/.drive-solo/inflight.json",
        { packages => [ { blueprint => $bp_name, package => '02-conflict',
                           ledger => 'blueprints/bp1/packages/02-conflict.md', since => time() } ] });

    return ($ledger_a, $data);
}

# ===========================================================================
# set-write-set
# ===========================================================================

subtest 'set-write-set narrows: removed paths need no Decision naming' => sub {
    my ($l) = fixture(
        write_set => 'src/a.pl:t/a.t:src/extra.pl',
        decisions => [[1, 'Unrelated decision text, names nothing.']],
    );
    my ($rc, $out) = run_cli('set-write-set', '--ledger', $l, '--decision', '1',
                              '--path', 'src/a.pl', '--path', 't/a.t');
    is($rc, 0, 'exit 0 (removal alone needs no naming)') or diag($out);
    is(field($l, 'write_set'), 'src/a.pl:t/a.t', 'write_set is replaced wholesale, dropping src/extra.pl');
    my ($vrc, $vout) = run_cli('validate', '--ledger', $l);
    is($vrc, 0, 'validate passes after the narrowing') or diag($vout);
};

subtest 'set-write-set widens: every added path named verbatim in the Decision' => sub {
    my ($l) = fixture(
        write_set => 'src/a.pl:t/a.t',
        decisions => [[2, 'Re-scope: also ships src/b.pm and src/c.pm.']],
    );
    my ($rc, $out) = run_cli('set-write-set', '--ledger', $l, '--decision', '2',
                              '--path', 'src/a.pl', '--path', 't/a.t', '--path', 'src/b.pm', '--path', 'src/c.pm');
    is($rc, 0, 'exit 0') or diag($out);
    is(field($l, 'write_set'), 'src/a.pl:t/a.t:src/b.pm:src/c.pm', 'write_set is exactly the requested set');
    my ($vrc, $vout) = run_cli('validate', '--ledger', $l);
    is($vrc, 0, 'validate passes after the widening') or diag($vout);
};

subtest 'set-write-set refuses an added path the Decision does not name, leaving the ledger unchanged' => sub {
    my ($l) = fixture(
        write_set => 'src/a.pl:t/a.t',
        decisions => [[3, 'Re-scope: also ships src/b.pm only.']],
    );
    my $before = slurp($l);
    my ($rc, $out) = run_cli('set-write-set', '--ledger', $l, '--decision', '3',
                              '--path', 'src/a.pl', '--path', 't/a.t', '--path', 'src/b.pm', '--path', 'src/unnamed.pl');
    isnt($rc, 0, 'refused: src/unnamed.pl is not named by Decision 3') or diag($out);
    like($out, qr/does not name/, '...and says why');
    like($out, qr/unnamed/, '...naming the offending path');
    is(slurp($l), $before, 'the ledger is byte-for-byte unchanged after the refusal');
};

subtest 'set-write-set argument validation' => sub {
    my ($l) = fixture(
        write_set => 'src/a.pl:t/a.t',
        decisions => [[4, 'Re-scope: also ships src/b.pm.']],
    );
    my $before = slurp($l);
    my @cases = (
        [['--decision', '99', '--path', 'src/a.pl'],  qr/Decision 99 not found/,     'an unknown Decision'],
        [['--decision', '0',  '--path', 'src/a.pl'],   qr/not a positive integer/,   'a non-positive Decision id'],
        [['--decision', '4'],                          qr/missing required --path/,  'no --path'],
        [['--path', 'src/a.pl'],                       qr/missing required --decision/, 'no --decision'],
        [['--decision', '4', '--path', '/etc/x'],      qr/absolute/,                 'an absolute path'],
        [['--decision', '4', '--path', 'C:/x'],        qr/absolute/,                 'a drive-letter path'],
        [['--decision', '4', '--path', 'src/../x'],    qr/'\.\.'/,                   'a .. segment'],
        [['--decision', '4', '--path', 'a:b'],         qr/contains ':'/,             "a colon (would split the field)"],
        [['--decision', '4', '--path', '*'],           qr/pure wildcard/,            'a pure wildcard'],
    );
    for my $c (@cases) {
        my ($args, $re, $what) = @$c;
        my ($rc, $out) = run_cli('set-write-set', '--ledger', $l, @$args);
        isnt($rc, 0, "refused: $what") or diag($out);
        like($out, $re, "...and says why: $what");
    }
    is(slurp($l), $before, 'the ledger is byte-for-byte unchanged after every refusal');
};

subtest 'set-write-set SUCCEEDS while the package is listed as in flight (Decision 89)' => sub {
    my ($l) = fixture(
        write_set => 'src/a.pl:t/a.t',
        decisions => [[5, 'Re-scope: also ships src/b.pm.']],
        inflight  => { packages => [ { blueprint => 'bp1', package => '01-a', ledger => 'x', since => time() } ] },
    );
    my ($rc, $out) = run_cli('set-write-set', '--ledger', $l, '--decision', '5',
                              '--path', 'src/a.pl', '--path', 't/a.t', '--path', 'src/b.pm');
    is($rc, 0, "the package's OWN in-flight membership is not a reason to refuse (Decision 89)") or diag($out);
    is(field($l, 'write_set'), 'src/a.pl:t/a.t:src/b.pm', 'write_set updated');
    my ($vrc, $vout) = run_cli('validate', '--ledger', $l);
    is($vrc, 0, 'validate passes') or diag($vout);
};

for my $bad_status (qw(done dropped)) {
    subtest "set-write-set is refused when the ledger's own status is $bad_status" => sub {
        my ($l) = fixture(
            write_set => 'src/a.pl:t/a.t',
            decisions => [[6, 'Re-scope: also ships src/b.pm.']],
            status    => $bad_status,
        );
        my $before = slurp($l);
        my ($rc, $out) = run_cli('set-write-set', '--ledger', $l, '--decision', '6',
                                  '--path', 'src/a.pl', '--path', 't/a.t', '--path', 'src/b.pm');
        isnt($rc, 0, "refused: status $bad_status") or diag($out);
        is(slurp($l), $before, 'the ledger is byte-for-byte unchanged');
    };
}

for my $ok_status (qw(pending blocked parked running)) {
    subtest "set-write-set succeeds when the ledger's own status is $ok_status" => sub {
        my ($l) = fixture(
            write_set => 'src/a.pl:t/a.t',
            decisions => [[7, 'Re-scope: also ships src/b.pm.']],
            status    => $ok_status,
        );
        my ($rc, $out) = run_cli('set-write-set', '--ledger', $l, '--decision', '7',
                                  '--path', 'src/a.pl', '--path', 't/a.t', '--path', 'src/b.pm');
        is($rc, 0, "exit 0: status $ok_status is not in the refusal list (running succeeds per Decision 89)") or diag($out);
        is(field($l, 'write_set'), 'src/a.pl:t/a.t:src/b.pm', 'write_set updated');
        my ($vrc, $vout) = run_cli('validate', '--ledger', $l);
        is($vrc, 0, 'validate passes') or diag($vout);
    };
}

subtest 'set-write-set refuses an ADDED path that overlaps another in-flight package\'s write_set (Decision 89)' => sub {
    my ($l, undef) = fixture_pair(
        ws_a      => 'src/a.pl:t/a.t',
        ws_b      => 'src/shared.pl:t/shared.t',
        decisions => [[8, 'Re-scope: also ships src/shared.pl.']],
    );
    my $before = slurp($l);
    my ($rc, $out) = run_cli('set-write-set', '--ledger', $l, '--decision', '8',
                              '--path', 'src/a.pl', '--path', 't/a.t', '--path', 'src/shared.pl');
    isnt($rc, 0, 'refused: src/shared.pl overlaps in-flight package bp1/02-conflict\'s write_set') or diag($out);
    like($out, qr/overlap/i, '...and says why');
    like($out, qr/02-conflict/, '...naming the conflicting package');
    is(slurp($l), $before, 'the ledger is byte-for-byte unchanged after the refusal');
};

subtest 'set-write-set allows removing paths even when the REMAINING paths still overlap an in-flight package' => sub {
    my ($l, undef) = fixture_pair(
        ws_a      => 'src/a.pl:src/shared.pl:src/extra.pl',
        ws_b      => 'src/shared.pl:t/shared.t',
        decisions => [[9, 'Re-scope: unrelated decision text, names nothing.']],
    );
    my ($rc, $out) = run_cli('set-write-set', '--ledger', $l, '--decision', '9',
                              '--path', 'src/a.pl', '--path', 'src/shared.pl');
    is($rc, 0, 'succeeds: only removal, no ADDED path, even though src/shared.pl still overlaps bp1/02-conflict') or diag($out);
    is(field($l, 'write_set'), 'src/a.pl:src/shared.pl', 'write_set narrowed to exactly the requested set');
    my ($vrc, $vout) = run_cli('validate', '--ledger', $l);
    is($vrc, 0, 'validate passes') or diag($vout);
};

# ===========================================================================
# set-test-paths -- same shape as set-write-set (Decision 84 says so explicitly).
# A smaller, representative slice: the naming rule, the in-flight/status
# refusals, and that it touches test_paths and NOT write_set.
# ===========================================================================

subtest 'set-test-paths narrows and widens under the same Decision-naming rule' => sub {
    my ($l) = fixture(
        write_set  => 'src/a.pl',
        test_paths => 't/a.t:t/b.t',
        decisions  => [[8, 'Re-scope: test coverage also lives at t/c.t.']],
    );
    my $ws_before = field($l, 'write_set');

    my ($rc1, $out1) = run_cli('set-test-paths', '--ledger', $l, '--decision', '8', '--path', 't/a.t');
    is($rc1, 0, 'narrowing exit 0 (removal needs no naming)') or diag($out1);
    is(field($l, 'test_paths'), 't/a.t', 'test_paths narrowed');
    is(field($l, 'write_set'), $ws_before, 'write_set is untouched by set-test-paths');

    my ($rc2, $out2) = run_cli('set-test-paths', '--ledger', $l, '--decision', '8', '--path', 't/a.t', '--path', 't/c.t');
    is($rc2, 0, 'widening with a named path exit 0') or diag($out2);
    is(field($l, 'test_paths'), 't/a.t:t/c.t', 'test_paths widened to exactly the requested set');

    my ($rc3, $out3) = run_cli('set-test-paths', '--ledger', $l, '--decision', '8', '--path', 't/a.t', '--path', 't/unnamed.t');
    isnt($rc3, 0, 'widening with an unnamed path is refused') or diag($out3);
    like($out3, qr/does not name/, '...and says why');
    is(field($l, 'test_paths'), 't/a.t:t/c.t', 'test_paths unchanged after the refusal');

    my ($vrc, $vout) = run_cli('validate', '--ledger', $l);
    is($vrc, 0, 'validate passes on the final state') or diag($vout);
};

subtest 'set-test-paths SUCCEEDS while in flight or while status is running (Decision 89)' => sub {
    my ($l_inflight) = fixture(
        test_paths => 't/a.t',
        decisions  => [[9, 'Re-scope: test coverage also lives at t/c.t.']],
        inflight   => { packages => [ { blueprint => 'bp1', package => '01-a', ledger => 'x', since => time() } ] },
    );
    my ($rc_i, $out_i) = run_cli('set-test-paths', '--ledger', $l_inflight, '--decision', '9',
                                  '--path', 't/a.t', '--path', 't/c.t');
    is($rc_i, 0, 'succeeds while in flight (own membership is not a reason to refuse)') or diag($out_i);
    is(field($l_inflight, 'test_paths'), 't/a.t:t/c.t', 'test_paths widened');

    my ($l_running) = fixture(
        test_paths => 't/a.t',
        decisions  => [[9, 'Re-scope: test coverage also lives at t/c.t.']],
        status     => 'running',
    );
    my ($rc_r, $out_r) = run_cli('set-test-paths', '--ledger', $l_running, '--decision', '9',
                                  '--path', 't/a.t', '--path', 't/c.t');
    is($rc_r, 0, 'succeeds while status is running (rescoping between worker dispatches)') or diag($out_r);
    is(field($l_running, 'test_paths'), 't/a.t:t/c.t', 'test_paths widened');
};

for my $bad_status (qw(done dropped)) {
    subtest "set-test-paths is refused when the ledger's own status is $bad_status" => sub {
        my ($l) = fixture(
            test_paths => 't/a.t',
            decisions  => [[9, 'Re-scope: test coverage also lives at t/c.t.']],
            status     => $bad_status,
        );
        my $before = slurp($l);
        my ($rc, $out) = run_cli('set-test-paths', '--ledger', $l, '--decision', '9',
                                  '--path', 't/a.t', '--path', 't/c.t');
        isnt($rc, 0, "refused: status $bad_status") or diag($out);
        is(slurp($l), $before, 'ledger byte-unchanged');
    };
}

subtest 'set-test-paths refuses an ADDED path that overlaps another in-flight package\'s write_set (Decision 89, shared with set-write-set)' => sub {
    my ($l, undef) = fixture_pair(
        ws_a         => 'src/a.pl',
        test_paths_a => 'tests/t/a.t',
        ws_b         => 'tests/t/shared.t',
        decisions    => [[9, 'Re-scope: test coverage also lives at tests/t/shared.t.']],
    );
    my $before = slurp($l);
    my ($rc, $out) = run_cli('set-test-paths', '--ledger', $l, '--decision', '9',
                              '--path', 'tests/t/a.t', '--path', 'tests/t/shared.t');
    isnt($rc, 0, 'refused: tests/t/shared.t overlaps in-flight package bp1/02-conflict\'s write_set') or diag($out);
    like($out, qr/overlap/i, '...and says why');
    like($out, qr/02-conflict/, '...naming the conflicting package');
    is(slurp($l), $before, 'the ledger is byte-for-byte unchanged after the refusal');
};

# ===========================================================================
# set-section
# ===========================================================================

# section_body($bytes, $heading) -> the text strictly between "## $heading" and
# the next "## " heading (or EOF). Simple, non-fence-aware: every fixture ledger
# in this block is fence-free, so this is adequate for reading back what was
# written without depending on bp-ledger.pl's own internal section-location code.
sub section_body {
    my ($bytes, $heading) = @_;
    if ($bytes =~ /^\Q## $heading\E[ \t]*\n(.*?)(?=\n## |\z)/ms) { return $1 }
    return undef;
}

sub fixture_for_section {
    my (%o) = @_;
    my ($l) = fixture(%o);
    if ($o{with_out_of_scope}) {
        my $bytes = slurp($l);
        die "no Inputs/Pipeline seam to splice into" unless
            $bytes =~ s/(\n## Pipeline\n)/\n## Out of scope\n\n<None yet.>\n$1/;
        open my $w, '>:raw', $l or die $!;
        print {$w} $bytes;
        close $w;
    }
    return $l;
}

for my $case (
    ['Scope',         'A brand-new Scope, written by set-section.'],
    ['Done criteria',  "Criterion one.\nCriterion two."],
    ['Inputs',         'Decision 10, plus plugins/butler/scripts/bp-ledger.pl.'],
) {
    my ($section, $text) = @$case;
    subtest "set-section replaces the body of '$section' and leaves the frontmatter byte-identical" => sub {
        my $l = fixture_for_section();
        my $before = slurp($l);
        my $fm_before = frontmatter($before);
        ok(defined $fm_before, 'sanity: fixture has a frontmatter block');

        my ($rc, $out) = run_cli('set-section', '--ledger', $l, '--section', $section, '--text', $text);
        is($rc, 0, "exit 0: $section") or diag($out);

        my $after = slurp($l);
        is(frontmatter($after), $fm_before, 'frontmatter is byte-identical after a successful set-section');

        my $body = section_body($after, $section);
        ok(defined $body, "section '$section' is still present");
        like($body, qr/\Q$text\E/, '...and contains the new text');

        for my $other (grep { $_ ne $section } ('Scope', 'Done criteria', 'Inputs')) {
            is(section_body($after, $other), section_body($before, $other), "section '$other' is untouched");
        }

        my ($vrc, $vout) = run_cli('validate', '--ledger', $l);
        is($vrc, 0, 'validate passes') or diag($vout);
    };
}

subtest "set-section replaces the body of 'Out of scope' via --text-file" => sub {
    my $l = fixture_for_section(with_out_of_scope => 1);
    my $before = slurp($l);
    my $fm_before = frontmatter($before);
    ok(defined(section_body($before, 'Out of scope')), 'sanity: fixture carries an Out of scope section');

    my $dir = tempdir(CLEANUP => 1);
    my $tf  = "$dir/text.txt";
    open my $w, '>:raw', $tf or die $!;
    print {$w} "Explicitly excludes anything touching bp-blueprint.pl.";
    close $w;

    my ($rc, $out) = run_cli('set-section', '--ledger', $l, '--section', 'Out of scope', '--text-file', $tf);
    is($rc, 0, 'exit 0') or diag($out);

    my $after = slurp($l);
    is(frontmatter($after), $fm_before, 'frontmatter is byte-identical');
    like(section_body($after, 'Out of scope'), qr/bp-blueprint\.pl/, 'the new text landed in Out of scope');

    my ($vrc, $vout) = run_cli('validate', '--ledger', $l);
    is($vrc, 0, 'validate passes') or diag($vout);
};

subtest 'set-section refuses an unknown section name, leaving the ledger unchanged' => sub {
    my $l = fixture_for_section();
    my $before = slurp($l);
    my ($rc, $out) = run_cli('set-section', '--ledger', $l, '--section', 'Nonexistent Heading', '--text', 'x');
    isnt($rc, 0, 'refused') or diag($out);
    is(slurp($l), $before, 'ledger byte-unchanged');
};

for my $section ('Pipeline', 'Decisions & attempt log', 'Next action', 'Outputs', 'Escalation') {
    subtest "set-section refuses '$section' (owned by its own dedicated verb / outside the allow-list)" => sub {
        my $l = fixture_for_section();
        my $before = slurp($l);
        my ($rc, $out) = run_cli('set-section', '--ledger', $l, '--section', $section, '--text', 'x');
        isnt($rc, 0, "refused: $section") or diag($out);
        is(slurp($l), $before, 'ledger byte-unchanged');
    };
}

subtest 'set-section requires exactly one of --text or --text-file' => sub {
    my $l = fixture_for_section();
    my $before = slurp($l);

    my ($rc1, $out1) = run_cli('set-section', '--ledger', $l, '--section', 'Scope');
    isnt($rc1, 0, 'refused: neither --text nor --text-file') or diag($out1);
    like($out1, qr/missing required/, '...and says why');

    my $dir = tempdir(CLEANUP => 1);
    my $tf  = "$dir/text.txt";
    open my $w, '>:raw', $tf or die $!;
    print {$w} 'x';
    close $w;
    my ($rc2, $out2) = run_cli('set-section', '--ledger', $l, '--section', 'Scope', '--text', 'x', '--text-file', $tf);
    isnt($rc2, 0, 'refused: both --text and --text-file') or diag($out2);

    is(slurp($l), $before, 'ledger byte-unchanged after either refusal');
};

# ===========================================================================
# widen-write-set --edit-target (Decision 87, task 33 joining package 22).
# Task 25's behaviour -- a widened test file also joins test_paths, turning an
# EDIT TARGET into an immutable oracle -- blocked package 21's fixes to three
# tests. --edit-target widens write_set ONLY, never test_paths; without it,
# today's behaviour is unchanged; the Decision-naming rule still applies
# either way; and set-test-paths (Decision 84) is the sanctioned recovery path
# for a file mistakenly widened into test_paths by a PLAIN widen-write-set.
# ===========================================================================

# NOTE: op_widen_write_set only recognises a path as a TEST path (the one that
# also joins test_paths, per Decision 87's "task 25's behaviour") when it
# matches `(?:\A|/)tests/t/[^/]+\.t\z` -- the shape guard-writes' own test-vs-
# write split uses. A bare `t/a.t` does NOT match that shape, so every fixture
# below that needs "a widened .t path" uses a `.../tests/t/NAME.t`-shaped
# string, verified against the CURRENT (already-implemented) plain verb.

subtest 'widen-write-set --edit-target widens write_set only; test_paths is byte-identical' => sub {
    my ($l) = fixture(
        write_set  => 'src/a.pl',
        test_paths => 'plugins/demo/tests/t/a.t',
        decisions  => [[10, 'Re-scope: also ships plugins/demo/tests/t/extra.t.']],
    );
    my $tp_before = field($l, 'test_paths');
    my ($rc, $out) = run_cli('widen-write-set', '--ledger', $l, '--decision', '10',
                              '--path', 'plugins/demo/tests/t/extra.t', '--edit-target');
    is($rc, 0, 'exit 0') or diag($out);
    is(field($l, 'write_set'), 'src/a.pl:plugins/demo/tests/t/extra.t', 'the .t path joined write_set');
    is(field($l, 'test_paths'), $tp_before, 'test_paths is byte-identical to before the call');
    my ($vrc, $vout) = run_cli('validate', '--ledger', $l);
    is($vrc, 0, 'validate passes') or diag($vout);
};

subtest "widen-write-set WITHOUT --edit-target keeps today's behaviour: a widened .t path joins test_paths too" => sub {
    my ($l) = fixture(
        write_set  => 'src/a.pl',
        test_paths => 'plugins/demo/tests/t/a.t',
        decisions  => [[11, 'Re-scope: also ships plugins/demo/tests/t/extra2.t.']],
    );
    my ($rc, $out) = run_cli('widen-write-set', '--ledger', $l, '--decision', '11',
                              '--path', 'plugins/demo/tests/t/extra2.t');
    is($rc, 0, 'exit 0') or diag($out);
    is(field($l, 'write_set'), 'src/a.pl:plugins/demo/tests/t/extra2.t', 'the .t path joined write_set');
    is(field($l, 'test_paths'), 'plugins/demo/tests/t/a.t:plugins/demo/tests/t/extra2.t',
       '...and joined test_paths too (unchanged from today)');
};

subtest '--edit-target on a non-test path behaves exactly like the plain verb' => sub {
    my ($l_flag) = fixture(
        write_set  => 'src/a.pl',
        test_paths => 'plugins/demo/tests/t/a.t',
        decisions  => [[12, 'Re-scope: also ships src/b.pm.']],
    );
    my ($rc_flag, $out_flag) = run_cli('widen-write-set', '--ledger', $l_flag, '--decision', '12',
                                        '--path', 'src/b.pm', '--edit-target');
    is($rc_flag, 0, 'exit 0 with --edit-target') or diag($out_flag);

    my ($l_plain) = fixture(
        write_set  => 'src/a.pl',
        test_paths => 'plugins/demo/tests/t/a.t',
        decisions  => [[12, 'Re-scope: also ships src/b.pm.']],
    );
    my ($rc_plain, $out_plain) = run_cli('widen-write-set', '--ledger', $l_plain, '--decision', '12', '--path', 'src/b.pm');
    is($rc_plain, 0, 'exit 0 without --edit-target') or diag($out_plain);

    is(field($l_flag, 'write_set'), field($l_plain, 'write_set'), 'write_set ends up identical either way');
    is(field($l_flag, 'test_paths'), field($l_plain, 'test_paths'), 'test_paths ends up identical either way (a non-test path never touches it)');
};

subtest 'widen-write-set --edit-target still refuses a path the Decision does not name, leaving the ledger unchanged' => sub {
    my ($l) = fixture(
        write_set  => 'src/a.pl',
        test_paths => 'plugins/demo/tests/t/a.t',
        decisions  => [[13, 'Re-scope: only names plugins/demo/tests/t/named.t.']],
    );
    my $before = slurp($l);
    my ($rc, $out) = run_cli('widen-write-set', '--ledger', $l, '--decision', '13',
                              '--path', 'plugins/demo/tests/t/unnamed.t', '--edit-target');
    isnt($rc, 0, 'refused: the unnamed .t path is not named by Decision 13') or diag($out);
    like($out, qr/does not name/, '...and says why');
    is(slurp($l), $before, 'the ledger is byte-for-byte unchanged after the refusal');
};

subtest 'set-test-paths is the recovery path for a file a plain widen-write-set mistakenly added to test_paths' => sub {
    my ($l) = fixture(
        write_set  => 'src/a.pl',
        test_paths => 'plugins/demo/tests/t/a.t',
        decisions  => [[14, 'Re-scope: also ships plugins/demo/tests/t/mistake.t.']],
    );
    my ($rc1, $out1) = run_cli('widen-write-set', '--ledger', $l, '--decision', '14',
                                '--path', 'plugins/demo/tests/t/mistake.t');
    is($rc1, 0, 'setup: plain widen-write-set adds the .t path to write_set AND test_paths') or diag($out1);
    is(field($l, 'write_set'), 'src/a.pl:plugins/demo/tests/t/mistake.t', 'sanity: write_set carries the .t path');
    is(field($l, 'test_paths'), 'plugins/demo/tests/t/a.t:plugins/demo/tests/t/mistake.t',
       'sanity: test_paths carries the .t path too');

    my $ws_before = field($l, 'write_set');
    my ($rc2, $out2) = run_cli('set-test-paths', '--ledger', $l, '--decision', '14', '--path', 'plugins/demo/tests/t/a.t');
    is($rc2, 0, 'set-test-paths removes the mistaken path from test_paths (removal needs no naming)') or diag($out2);
    is(field($l, 'test_paths'), 'plugins/demo/tests/t/a.t', 'test_paths no longer carries the mistaken path');
    is(field($l, 'write_set'), $ws_before, 'write_set is untouched by the recovery');

    my ($vrc, $vout) = run_cli('validate', '--ledger', $l);
    is($vrc, 0, 'validate passes') or diag($vout);
};

# ===========================================================================
# set-escalation (bug 20261022-115951-2e6f): set-section still refuses
# Escalation, so this is the one sanctioned writer of that section. The
# template heading carries a suffix ("## Escalation (when status: blocked)").
# ===========================================================================

sub escalation_body {
    my ($bytes) = @_;
    return $1 if $bytes =~ /^## Escalation[^\n]*\n(.*?)(?=\n## |\z)/ms;
    return undef;
}

subtest 'set-escalation replaces the Escalation body and the ledger still validates' => sub {
    my $l = fixture_for_section();
    my $text = "Blocked on the tree interlock.\nNeeds: nothing from the operator; retry after 02 lands.";
    my ($rc, $out) = run_cli('set-escalation', '--ledger', $l, '--text', $text);
    is($rc, 0, 'exit 0') or diag($out);
    my $body = escalation_body(slurp($l));
    like($body, qr/\A\s*\QBlocked on the tree interlock.\E\nNeeds: nothing/, 'the new body is in place');
    unlike($body, qr/What is blocked, what was tried/, 'the template placeholder is gone');
    my ($vrc, $vout) = run_cli('validate', '--ledger', $l);
    is($vrc, 0, 'validate passes') or diag($vout);
};

for my $case (
    ['a heading line',       "Fine first line.\n## Pipeline"],
    ['a forged checkbox',    "- [x] done, honest"],
    ['only whitespace',      "  \n  "],
) {
    my ($what, $text) = @$case;
    subtest "set-escalation refuses $what and leaves the ledger byte-identical" => sub {
        my $l = fixture_for_section();
        my $before = slurp($l);
        my ($rc, $out) = run_cli('set-escalation', '--ledger', $l, '--text', $text);
        is($rc, 3, 'exit 3 (argument fault)') or diag($out);
        is(slurp($l), $before, 'ledger byte-identical');
    };
}

subtest 'set-section still refuses Escalation' => sub {
    my $l = fixture_for_section();
    my ($rc, $out) = run_cli('set-section', '--ledger', $l, '--section', 'Escalation', '--text', 'x');
    is($rc, 3, 'exit 3') or diag($out);
};

done_testing();
