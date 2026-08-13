#!/usr/bin/env perl
# ORACLE for b01-backpack-install-accounting criterion 4 (spec section 2.3,
# cases 4/5/6/7 of spec section 3), written BLIND to any implementation --
# backpack.pl at HEAD has no `depends_on` field, no topological ordering, no
# cycle detection, and no dangling-reference check. Do NOT weaken these
# assertions to make a future implementation's life easier.
#
# Schema addition under test: an OPTIONAL `depends_on` field on an item, a
# JSON array of "category:name" strings (the same key shape `install`'s
# per-item disposition already uses, e.g. "curl-script:gh") naming other
# items in the SAME file that must install first.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);

my $BP = "$Bin/../../scripts/backpack.pl";
ok(-f $BP, 'backpack.pl exists') or BAIL_OUT('script missing');

unless (system('bash -c "exit 0" >/dev/null 2>&1') == 0) {
    plan skip_all => 'bash not available on this host';
}

my $dir = tempdir(CLEANUP => 1);

sub write_backpack {
    my ($path, @items) = @_;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh encode_json({ version => 2, items => \@items });
    close $fh;
}

# run_bp(@args) -> ($combined_out, $rc, $timed_out) -- bounded to 20s so a
# broken cycle detector (infinite loop) cannot hang this suite. Same pattern
# as backpack.pl's own diagnose_verify(): pipe-open + alarm + hard SIGKILL.
sub run_bp {
    my (@args) = @_;
    my $pid = open(my $fh, '-|');
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDIN, '<', '/dev/null');
        open(STDERR, '>&', \*STDOUT);
        exec($^X, $BP, @args);
        CORE::exit(127);
    }
    my @lines;
    my $timed_out = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 20;
        @lines = <$fh>;
        alarm 0;
    };
    if ($@) { $timed_out = 1; kill 'KILL', $pid; }
    alarm 0;
    close $fh;   # reaps the child; sets $? -- do NOT waitpid again afterward (that would
                 # reap a nonexistent process and clobber $? with an undefined value)
    my $rc = $timed_out ? -1 : ($? >> 8);
    return (join('', @lines), $rc, $timed_out);
}

# ---------------------------------------------------------------------------
# Case 4 (spec section 3 #4): a dependent installs after its dependency
# REGARDLESS of file order. File order below is deliberately reversed (B,
# the dependent, listed first; A, the dependency, listed second) so a naive
# file-order install would get this backwards.
# ---------------------------------------------------------------------------
{
    my $log = "$dir/case4.log";
    my $mA  = "$dir/case4-markA";
    my $mB  = "$dir/case4-markB";
    unlink $log, $mA, $mB;

    my $itemB = { category => 'other', name => 'depB',
        install => qq{echo B >> "$log" && touch "$mB"},
        verify  => qq{test -f "$mB"},
        depends_on => [ 'other:depA' ] };
    my $itemA = { category => 'other', name => 'depA',
        install => qq{echo A >> "$log" && touch "$mA"},
        verify  => qq{test -f "$mA"} };

    my $path = "$dir/case4.json";
    write_backpack($path, $itemB, $itemA);   # B (the dependent) FIRST in the file

    my ($out, $rc, $timed_out) = run_bp('install', $path);
    ok(!$timed_out, 'case4: install terminates (does not hang)');
    is($rc, 0, 'case4: install exits 0 when both items succeed') or diag("  got:\n$out");

    open my $fh, '<', $log or die "read $log: $!";
    my @order = map { chomp; $_ } <$fh>;
    close $fh;
    is_deeply(\@order, ['A', 'B'],
        'case4: execution order is A-then-B (dependency-order), even though the file lists B-then-A')
        or diag("  log contents: @order\n  full output:\n$out");
}

# ---------------------------------------------------------------------------
# Case 5 (spec section 3 #5): a cycle is reported and NAMES the cycle,
# never hangs, never silently drops the members.
#
# DELIBERATELY named to avoid the substring "cycle" in either item's own
# name (loopa/loopb, not cyclex/cycley) -- an earlier draft of this fixture
# used names containing "cycle", which made `like($out, qr/cycle/i)` pass
# on nothing more than the item's OWN label leaking into the output, whether
# or not a cycle was ever actually detected. Also deliberately built so
# BOTH items would independently install and verify successfully (their
# install touches a marker file, verify checks for it) if depends_on were
# simply ignored -- so an implementation that does nothing about cycles
# exits 0 with two ordinary OK lines, not a coincidental non-zero exit.
# That is the "silently drops" failure mode the spec warns about, and this
# fixture is shaped so only REAL cycle detection can turn it red-for-cause.
# ---------------------------------------------------------------------------
{
    my $mP = "$dir/case5-markP";
    my $mQ = "$dir/case5-markQ";
    unlink $mP, $mQ;
    my $itemP = { category => 'other', name => 'loopa',
                  install => qq{touch "$mP"}, verify => qq{test -f "$mP"},
                  depends_on => [ 'other:loopb' ] };
    my $itemQ = { category => 'other', name => 'loopb',
                  install => qq{touch "$mQ"}, verify => qq{test -f "$mQ"},
                  depends_on => [ 'other:loopa' ] };
    my $path = "$dir/case5.json";
    write_backpack($path, $itemP, $itemQ);

    my ($out, $rc, $timed_out) = run_bp('install', $path);
    ok(!$timed_out, 'case5: a dependency cycle does not hang the install pass') or diag("  got:\n$out");
    isnt($rc, 0, 'case5: a dependency cycle exits non-zero (not a silent, successful no-op)') or diag("  got:\n$out");
    like($out, qr/\b(?:cycle|circular)\b/i, 'case5: the error names the cycle (mentions "cycle"/"circular")')
        or diag("  got:\n$out");
    like($out, qr/other:loopa/, 'case5: the cycle report names the first member');
    like($out, qr/other:loopb/, 'case5: the cycle report names the second member');
    unlike($out, qr/^OK: other:loopa$/m, 'case5: the cyclic item is never silently marked OK');
    unlike($out, qr/^OK: other:loopb$/m, 'case5: neither cyclic item is silently marked OK');
}

# ---------------------------------------------------------------------------
# Case 6 (spec section 3 #6): a dangling depends_on reference (naming an
# item that is not declared anywhere in the file) is reported, not silently
# ignored.
# ---------------------------------------------------------------------------
{
    my $itemZ = { category => 'other', name => 'danglez', install => 'true', verify => 'false',
                  depends_on => [ 'other:ghost-does-not-exist' ] };
    my $path = "$dir/case6.json";
    write_backpack($path, $itemZ);

    my ($out, $rc, $timed_out) = run_bp('install', $path);
    ok(!$timed_out, 'case6: a dangling reference does not hang the install pass');
    isnt($rc, 0, 'case6: a dangling depends_on reference exits non-zero') or diag("  got:\n$out");
    like($out, qr/other:danglez/, 'case6: the report names the item with the dangling reference');
    like($out, qr/other:ghost-does-not-exist/,
        'case6: the report names the missing (dangling) dependency target');
}

# ---------------------------------------------------------------------------
# Case 7 (spec section 3 #7): backward compatibility -- entries with no
# depends_on at all still load and install unchanged (file order preserved,
# nothing rejected).
# ---------------------------------------------------------------------------
{
    my $log = "$dir/case7.log";
    my $m1  = "$dir/case7-mark1";
    my $m2  = "$dir/case7-mark2";
    unlink $log, $m1, $m2;

    my $item1 = { category => 'other', name => 'plain1',
        install => qq{echo ONE >> "$log" && touch "$m1"}, verify => qq{test -f "$m1"} };
    my $item2 = { category => 'other', name => 'plain2',
        install => qq{echo TWO >> "$log" && touch "$m2"}, verify => qq{test -f "$m2"} };
    my $path = "$dir/case7.json";
    write_backpack($path, $item1, $item2);   # neither entry has depends_on

    my ($out, $rc, $timed_out) = run_bp('install', $path);
    ok(!$timed_out, 'case7: a depends_on-free file terminates normally');
    is($rc, 0, 'case7: a depends_on-free file installs successfully, unchanged') or diag("  got:\n$out");
    like($out, qr/^INSTALL: other:plain1$/m, 'case7: item without depends_on still gets an INSTALL line');
    like($out, qr/^OK: other:plain1$/m,       'case7: item without depends_on still gets an OK line');
    like($out, qr/^OK: other:plain2$/m,       'case7: the second depends_on-free item also installs');

    open my $fh, '<', $log or die "read $log: $!";
    my @order = map { chomp; $_ } <$fh>;
    close $fh;
    is_deeply(\@order, ['ONE', 'TWO'],
        'case7: with no depends_on anywhere, file order is preserved exactly as today');
}

done_testing();
