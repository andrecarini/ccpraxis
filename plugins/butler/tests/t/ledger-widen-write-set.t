#!/usr/bin/env perl
# platform: any
# Oracle for `bp-ledger.pl widen-write-set`: the typed path by which a recorded
# re-scope (a blueprint Decision) reaches a package ledger's write_set.
#
# Why it exists: on 2026-09-24 the hook-continuity-remake driver recorded two
# re-scopes (Decisions 47 and 48) and then had no way to apply them.
# guard-blueprint-write.sh refuses a hand edit of a ledger, and
# bp-answer-decision.pl's --widen-write-set is reachable only through the
# fleet's decision queue. The verb is additive only, and it refuses any path
# that the named Decision does not contain verbatim.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $LEDGER_PL = "$Bin/../../scripts/bp-ledger.pl";
my $TEMPLATE  = "$Bin/../../../blueprint/templates/package-ledger.md";
ok(-f $LEDGER_PL && -f $TEMPLATE, 'bp-ledger.pl and the ledger template exist') or BAIL_OUT('missing inputs');

sub slurp { my ($p) = @_; open my $f, '<:raw', $p or die "$p: $!"; local $/; my $s = <$f>; close $f; $s }

sub run_cli {
    my (@args) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $out = "$dir/out";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open STDOUT, '>', $out or die; open STDERR, '>&', \*STDOUT or die;
        exec($^X, $LEDGER_PL, @args) or exit 127;
    }
    waitpid($pid, 0);
    return ($? >> 8, slurp($out));
}

# fixture() -> ($ledger, $bpdir): a ledger created through the real `create`
# verb, and a blueprint.md whose Decision 7 names two paths.
sub fixture {
    my $root = tempdir(CLEANUP => 1);
    my $bp   = "$root/demo-bp";
    make_path("$bp/packages");
    my $ledger = "$bp/packages/01-a.md";
    my ($rc, $out) = run_cli('create', '--ledger', $ledger, '--package', '01-a', '--blueprint', 'demo-bp',
                             '--template', $TEMPLATE, '--write-set', 'src/a.pl:t/a.t');
    die "fixture create failed ($rc): $out" unless $rc == 0;
    open my $w, '>:raw', "$bp/blueprint.md" or die;
    print $w "# demo-bp\n\n## Decisions\n\n| # | Decision | Decided by | Date |\n|---|---|---|---|\n"
           . "| 7 | Re-scope: package 01 also ships src/b.pm and bin/tool. | driver | 2026-09-24 |\n"
           . "| 9 | Re-scope: package 01 also owns plugins/x/tests/t/extra-case.t. | driver | 2026-09-24 |\n"
           . "| 8 | Unrelated: nothing about paths. | driver | 2026-09-24 |\n";
    close $w;
    return $ledger;
}

sub write_set { my ($l) = @_; my ($v) = slurp($l) =~ /^write_set:\s*(.*?)\s*$/m; $v }

subtest 'widens additively and logs the change in the same write' => sub {
    my $l = fixture();
    my ($rc, $out) = run_cli('widen-write-set', '--ledger', $l, '--decision', '7',
                             '--path', 'src/b.pm', '--path', 'bin/tool');
    is($rc, 0, 'exit 0') or diag($out);
    is(write_set($l), 'src/a.pl:t/a.t:src/b.pm:bin/tool', 'existing entries kept in order, new ones appended');
    like(slurp($l), qr/^- \S+ \S+ write_set widened per Decision 7: src\/b\.pm, bin\/tool$/m,
         'an attempt-log line records the Decision and the paths');
    my ($vrc, $vout) = run_cli('validate', '--ledger', $l);
    is($vrc, 0, 'the widened ledger still validates') or diag($vout);
};

subtest 'is idempotent: a path already present is not duplicated' => sub {
    my $l = fixture();
    run_cli('widen-write-set', '--ledger', $l, '--decision', '7', '--path', 'src/b.pm');
    my ($rc) = run_cli('widen-write-set', '--ledger', $l, '--decision', '7', '--path', 'src/b.pm');
    is($rc, 0, 'second call exits 0');
    is(write_set($l), 'src/a.pl:t/a.t:src/b.pm', 'src/b.pm appears once');
};

subtest 'refuses anything a Decision does not authorise, leaving the ledger untouched' => sub {
    my $l = fixture();
    my $before = slurp($l);
    my @cases = (
        [['--decision', '7', '--path', 'src/c.pm'],  qr/does not name 'src\/c\.pm'/, 'a path Decision 7 does not name'],
        [['--decision', '8', '--path', 'src/b.pm'],  qr/does not name/,              'a Decision that names no path'],
        [['--decision', '99', '--path', 'src/b.pm'], qr/Decision 99 not found/,      'an unknown Decision'],
        [['--decision', '0', '--path', 'src/b.pm'],  qr/not a positive integer/,     'a non-positive Decision id'],
        [['--decision', '7'],                        qr/missing required --path/,    'no --path'],
        [['--path', 'src/b.pm'],                     qr/missing required --decision/,'no --decision'],
        [['--decision', '7', '--path', '/etc/x'],    qr/absolute/,                   'an absolute path'],
        [['--decision', '7', '--path', 'C:/x'],      qr/absolute/,                   'a drive-letter path'],
        [['--decision', '7', '--path', 'src/../x'],  qr/'\.\.'/,                     'a .. segment'],
        [['--decision', '7', '--path', 'a:b'],       qr/contains ':'/,               'a colon (would split the set)'],
        [['--decision', '7', '--path', '*'],         qr/pure wildcard/,              'a pure wildcard'],
    );
    for my $c (@cases) {
        my ($args, $re, $what) = @$c;
        my ($rc, $out) = run_cli('widen-write-set', '--ledger', $l, @$args);
        is($rc, 3, "refused with exit 3: $what") or diag($out);
        like($out, $re, "...and says why: $what");
    }
    is(slurp($l), $before, 'the ledger is byte-for-byte unchanged after every refusal');
};

subtest 'a widened test file joins test_paths too; a non-test path does not' => sub {
    # guard-writes lets a test-writer write only under test_paths, so a
    # re-scoped test file must reach both keys (hook-continuity-remake 06).
    my $l = fixture();
    my ($tp0) = slurp($l) =~ /^test_paths:[ \t]*(.*?)[ \t]*$/m;
    my ($rc, $out) = run_cli('widen-write-set', '--ledger', $l, '--decision', '9',
                             '--path', 'plugins/x/tests/t/extra-case.t');
    is($rc, 0, 'exit 0') or diag($out);
    like(write_set($l), qr{(?:\A|:)plugins/x/tests/t/extra-case\.t\z}, 'the test file is in write_set');
    my ($tp1) = slurp($l) =~ /^test_paths:[ \t]*(.*?)[ \t]*$/m;
    like($tp1, qr{(?:\A|:)plugins/x/tests/t/extra-case\.t\z}, '...and in test_paths');
    like($tp1, qr/\A\Q$tp0\E/, 'the existing test_paths entries are kept, in order');
    run_cli('widen-write-set', '--ledger', $l, '--decision', '7', '--path', 'src/b.pm');
    my ($tp2) = slurp($l) =~ /^test_paths:[ \t]*(.*?)[ \t]*$/m;
    is($tp2, $tp1, 'a non-test path leaves test_paths untouched');
    my ($vrc, $vout) = run_cli('validate', '--ledger', $l);
    is($vrc, 0, 'the ledger still validates') or diag($vout);
};

subtest 'inflight-conflict detection survives a non-ASCII data dir (bug 20261001-234949-c44b)' => sub {
    # Regression for bp-ledger.pl's _widen_check_inflight_conflict: a non-ASCII
    # byte in the data dir (e.g. this host's own accented "Andre" profile
    # segment, here constructed in-fixture rather than relied on from the
    # environment) must not cause the in-flight-overlap check to silently miss
    # a real conflict. Full mechanism + additional cases:
    # plugins/butler/tests/t/ledger-nonascii-writeset-conflict.t.
    my $ACCENT   = "\x{c3}\x{a9}"; # raw UTF-8 bytes for e-acute (Andr\xC3\xA9)
    my $root     = tempdir(CLEANUP => 1);
    my $data_dir = "$root/Andr${ACCENT}-widen-test";
    my $other_dir = "Andr${ACCENT}-other-bp";
    make_path("$data_dir/blueprints/own-bp/packages");
    make_path("$data_dir/blueprints/$other_dir/packages");
    make_path("$data_dir/.drive-solo");

    my $own_ledger = "$data_dir/blueprints/own-bp/packages/01-own.md";
    my ($rc1, $out1) = run_cli('create', '--ledger', $own_ledger, '--package', '01-own',
                                '--blueprint', 'own-bp', '--template', $TEMPLATE,
                                '--write-set', 'src/a.pl:t/a.t');
    die "fixture: own ledger create failed ($rc1): $out1" unless $rc1 == 0;
    open my $bw, '>:raw', "$data_dir/blueprints/own-bp/blueprint.md" or die $!;
    print $bw "# own-bp\n\n## Decisions\n\n| # | Decision | Decided by | Date |\n|---|---|---|---|\n"
            . "| 7 | Re-scope: package 01 also ships src/shared.pl. | driver | 2026-10-03 |\n";
    close $bw;

    my $other_ledger = "$data_dir/blueprints/$other_dir/packages/02-other.md";
    my ($rc2, $out2) = run_cli('create', '--ledger', $other_ledger, '--package', '02-other',
                                '--blueprint', 'other-bp', '--template', $TEMPLATE,
                                '--write-set', 'src/shared.pl:t/shared.t');
    die "fixture: other ledger create failed ($rc2): $out2" unless $rc2 == 0;

    open my $ifh, '>:raw', "$data_dir/.drive-solo/inflight.json" or die $!;
    print $ifh qq({"packages":[{"blueprint":"other-bp","package":"02-other",)
             . qq("ledger":"blueprints/$other_dir/packages/02-other.md"}]});
    close $ifh;

    my ($rc, $out) = run_cli('widen-write-set', '--ledger', $own_ledger, '--decision', '7',
                              '--path', 'src/shared.pl');
    is($rc, 3, 'refused with exit 3: a genuine overlap under a non-ASCII data dir is still caught') or diag($out);
    like($out, qr/overlap in-flight.*other-bp\/02-other/, 'names the conflicting in-flight package') or diag($out);
};

subtest 'a stale inflight entry whose package is done does not refuse (bug 20261023-070425-989e)' => sub {
    # inflight.json is pruned only by bp-drive-next.pl `next`, so an entry can
    # outlive its package. The other ledger's own status decides: done/dropped
    # frees the paths; running, parked and blocked still hold them.
    for my $case ([done => 0], [dropped => 0], [running => 3], [parked => 3], [blocked => 3]) {
        my ($status, $want) = @$case;
        my $data_dir = tempdir(CLEANUP => 1);
        make_path("$data_dir/blueprints/own-bp/packages", "$data_dir/blueprints/other-bp/packages",
                  "$data_dir/.drive-solo");
        my $own_ledger = "$data_dir/blueprints/own-bp/packages/01-own.md";
        my ($rc1, $out1) = run_cli('create', '--ledger', $own_ledger, '--package', '01-own',
                                    '--blueprint', 'own-bp', '--template', $TEMPLATE,
                                    '--write-set', 'src/a.pl:t/a.t');
        die "fixture: own ledger create failed ($rc1): $out1" unless $rc1 == 0;
        open my $bw, '>:raw', "$data_dir/blueprints/own-bp/blueprint.md" or die $!;
        print $bw "# own-bp\n\n## Decisions\n\n| # | Decision | Decided by | Date |\n|---|---|---|---|\n"
                . "| 7 | Re-scope: package 01 also ships src/shared.pl. | driver | 2026-10-23 |\n";
        close $bw;
        my $other_ledger = "$data_dir/blueprints/other-bp/packages/02-other.md";
        my ($rc2, $out2) = run_cli('create', '--ledger', $other_ledger, '--package', '02-other',
                                    '--blueprint', 'other-bp', '--template', $TEMPLATE,
                                    '--write-set', 'src/shared.pl:t/shared.t');
        die "fixture: other ledger create failed ($rc2): $out2" unless $rc2 == 0;
        my $body = slurp($other_ledger);
        $body =~ s/^status:.*$/status: $status/m or die "fixture: no status line";
        open my $ow, '>:raw', $other_ledger or die $!; print $ow $body; close $ow;
        open my $ifh, '>:raw', "$data_dir/.drive-solo/inflight.json" or die $!;
        print $ifh qq({"packages":[{"blueprint":"other-bp","package":"02-other"}]});
        close $ifh;

        my ($rc, $out) = run_cli('widen-write-set', '--ledger', $own_ledger, '--decision', '7',
                                  '--path', 'src/shared.pl');
        is($rc, $want, "other package $status: widen exits $want") or diag($out);
        if ($want == 0) {
            like(write_set($own_ledger), qr{src/shared\.pl}, "  and the path landed in the write set");
        }
    }
};

done_testing();
