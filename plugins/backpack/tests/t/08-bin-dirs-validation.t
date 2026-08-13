#!/usr/bin/env perl
# Oracle for b02-backpack-owns-path — DC1 (schema) + DC2 (cmd_add authoring
# path). Derived from
# .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/specs/b02-backpack-owns-path-spec.md
# section 2.1 (validate_backpack's new bin_dirs block) and 2.2 (cmd_add
# --bin_dirs). This file is NEW — it does not touch 01-07, which are other
# packages' immutable oracles.
#
# AC1: validate_backpack rejects each bin_dirs violation, one case per rule.
# AC2: cmd_add --bin_dirs add/update/preserve/replace semantics.
#
# This is a HEAD-run: everything below is expected to be RED until the
# implementation lands bin_dirs support at all (today, `bin_dirs` is not a
# schema field, `validate` never mentions it, and `add` has no --bin_dirs
# flag — GetOptionsFromArray will simply ignore the unknown option's value
# silently unless the implementation defines it).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);

my $BP = $ENV{BP_UNDER_TEST} // "$Bin/../../scripts/backpack.pl";
ok(-f $BP, 'backpack.pl under test exists') or BAIL_OUT('script missing');

unless (system('bash -c "exit 0" >/dev/null 2>&1') == 0) {
    plan skip_all => 'bash not available on this host';
}

my $dir = tempdir(CLEANUP => 1);

sub item {
    my ($name, %extra) = @_;
    return { category => 'other', name => $name, install => 'true', verify => 'true', %extra };
}

sub write_backpack {
    my ($path, @items) = @_;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh encode_json({ version => 2, items => \@items });
    close $fh;
}

# Never dies -- returns undef on any failure so a missing-behavior red does
# not abort the rest of the test file (a subsequent block must still run and
# report its own red, not be silently skipped by an uncaught die()).
sub read_backpack {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return eval { decode_json($raw) };
}

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
    close $fh;
    my $rc = $timed_out ? -1 : ($? >> 8);
    return (join('', @lines), $rc);
}

# ===========================================================================
# AC1 — validate_backpack rejects each bin_dirs violation, one case per rule.
# Each case is a SEPARATE file/item so a wrong message on one case can't be
# masked by a right message on another (avoids the "one shared fixture"
# vacuity failure mode).
# ===========================================================================

{
    my $path = "$dir/ac1-non-array.json";
    write_backpack($path, item('a', bin_dirs => 'not-an-array'));
    my ($out, $rc) = run_bp('validate', $path);
    like($out, qr/^STATUS: invalid$/m, 'AC1a: non-array bin_dirs -> STATUS: invalid') or diag($out);
    is($rc, 1, 'AC1a: non-array bin_dirs -> exit 1');
    ok(index($out, "items[0].bin_dirs: must be an array") >= 0,
        'AC1a: error names the item and the exact rule violated') or diag($out);
}

{
    my $path = "$dir/ac1-relative.json";
    write_backpack($path, item('a', bin_dirs => ['relative/path']));
    my ($out, $rc) = run_bp('validate', $path);
    like($out, qr/^STATUS: invalid$/m, 'AC1b: relative bin_dirs entry -> STATUS: invalid') or diag($out);
    is($rc, 1, 'AC1b: relative bin_dirs entry -> exit 1');
    ok(index($out, "items[0].bin_dirs entry: must be an absolute path (starting with '/')") >= 0,
        'AC1b: error names the item and the absolute-path rule') or diag($out);
}

for my $case (
    [ 'colon',      '/opt/tools:x' ],
    [ 'quote',      '/opt/tools"x' ],
    [ 'backtick',   '/opt/tools`x' ],
    [ 'dollar',     '/opt/tools$x' ],
    [ 'whitespace', '/opt/tools x' ],
) {
    my ($label, $entry) = @$case;
    my $path = "$dir/ac1-$label.json";
    write_backpack($path, item('a', bin_dirs => [$entry]));
    my ($out, $rc) = run_bp('validate', $path);
    like($out, qr/^STATUS: invalid$/m, "AC1c[$label]: forbidden character -> STATUS: invalid") or diag($out);
    is($rc, 1, "AC1c[$label]: forbidden character -> exit 1");
    my $expected = q{items[0].bin_dirs entry: must not contain ':', '"', '$', backtick, or whitespace};
    ok(index($out, $expected) >= 0,
        "AC1c[$label]: error is the SAME shared forbidden-character message (not the absolute-path one)")
        or diag($out);
    # Non-vacuity: this entry IS absolute, so a buggy implementation that only
    # ever emits the absolute-path message (never distinguishing the two
    # rules) must fail this specific assertion.
    ok(index($out, "must be an absolute path") < 0,
        "AC1c[$label]: the absolute-path rule does NOT also fire (this entry starts with '/')")
        or diag($out);
}

{
    my $path = "$dir/ac1-control.json";
    write_backpack($path, item('a', bin_dirs => ["/opt/tools\x01x"]));
    my ($out, $rc) = run_bp('validate', $path);
    like($out, qr/^STATUS: invalid$/m, 'AC1d: control character -> STATUS: invalid') or diag($out);
    is($rc, 1, 'AC1d: control character -> exit 1');
    ok(index($out, "items[0].bin_dirs entry: must not contain control/escape characters") >= 0,
        'AC1d: error is the control/escape-character message (push_text_issues, rule 1)') or diag($out);
}

{
    # A valid bin_dirs entry must NOT be rejected — the negative-space check
    # that keeps AC1 from being satisfiable by an implementation that just
    # rejects everything bin_dirs-shaped.
    my $path = "$dir/ac1-valid.json";
    write_backpack($path, item('a', bin_dirs => ['/opt/tools/flutter/bin']));
    my ($out, $rc) = run_bp('validate', $path);
    like($out, qr/^STATUS: ok$/m, 'AC1e: a well-formed absolute bin_dirs entry validates clean') or diag($out);
    is($rc, 0, 'AC1e: exit 0');
}

# ===========================================================================
# AC2 — cmd_add --bin_dirs add/update/preserve/replace semantics.
# ===========================================================================

sub find_item {
    my ($bp, $cat, $name) = @_;
    for my $t (@{ $bp->{items} }) {
        return $t if $t->{category} eq $cat && $t->{name} eq $name;
    }
    return undef;
}

sub slurp_or_undef {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# Each AC2 sub-case is independent and defensive: a missing/unreadable file
# after a failed `add` records an explicit fail() (never a silent skip, never
# an uncaught die that would abort every later block in this file too) and
# returns early rather than chaining undef through is_deeply.
sub ac2_block {
    my $path = "$dir/ac2.json";

    # -- add: new entry, two --bin_dirs occurrences -> array of both --------
    my ($out1, $rc1) = run_bp('add', $path,
        '--category', 'other', '--name', 'gh',
        '--install', 'true', '--verify', 'true',
        '--bin_dirs', '/opt/tools/x', '--bin_dirs', '/opt/tools/y');
    is($rc1, 0, 'AC2a: add with --bin_dirs succeeds') or diag($out1);
    like($out1, qr/^STATUS: added$/m, 'AC2a: STATUS: added') or diag($out1);

    my $bp1 = read_backpack($path);
    my $it1 = $bp1 ? find_item($bp1, 'other', 'gh') : undef;
    unless (ok(defined $it1, 'AC2a: entry exists after add')) {
        fail('AC2a: repeated --bin_dirs occurrences accumulate into the array, in given order (skipped: no entry to inspect)');
        fail('AC2b/c/d/e: skipped -- AC2a did not produce a readable entry to build on');
        return;
    }
    is_deeply($it1->{bin_dirs}, ['/opt/tools/x', '/opt/tools/y'],
        'AC2a: repeated --bin_dirs occurrences accumulate into the array, in given order');

    # -- update, --bin_dirs OMITTED -> preserved -----------------------------
    my ($out2, $rc2) = run_bp('add', $path,
        '--category', 'other', '--name', 'gh',
        '--install', 'true', '--verify', 'command -v gh');
    is($rc2, 0, 'AC2b: update without --bin_dirs succeeds') or diag($out2);
    like($out2, qr/^STATUS: updated$/m, 'AC2b: STATUS: updated') or diag($out2);

    my $bp2 = read_backpack($path);
    my $it2 = $bp2 ? find_item($bp2, 'other', 'gh') : undef;
    if (ok(defined $it2, 'AC2b: entry still exists after update')) {
        is_deeply($it2->{bin_dirs}, ['/opt/tools/x', '/opt/tools/y'],
            'AC2b: omitting --bin_dirs on update PRESERVES the existing array unchanged');
        is($it2->{verify}, 'command -v gh', 'AC2b: ...while the field that WAS given (verify) did change');
    } else {
        fail('AC2b: preserve-on-omit skipped -- no readable entry');
        fail('AC2b: verify-field-changed skipped -- no readable entry');
    }

    # -- update, --bin_dirs given (single value) -> REPLACES, not appends ---
    my ($out3, $rc3) = run_bp('add', $path,
        '--category', 'other', '--name', 'gh',
        '--install', 'true', '--verify', 'command -v gh',
        '--bin_dirs', '/opt/tools/z');
    is($rc3, 0, 'AC2c: update with a different --bin_dirs succeeds') or diag($out3);

    my $bp3 = read_backpack($path);
    my $it3 = $bp3 ? find_item($bp3, 'other', 'gh') : undef;
    if (ok(defined $it3, 'AC2c: entry still exists after replace')) {
        is_deeply($it3->{bin_dirs}, ['/opt/tools/z'],
            'AC2c: a NEW --bin_dirs set REPLACES the old array wholesale (not appended, not merged)');
    } else {
        fail('AC2c: replace-semantics skipped -- no readable entry');
    }

    # -- new entry, --bin_dirs never given -> field absent entirely ----------
    my ($out4, $rc4) = run_bp('add', $path,
        '--category', 'other', '--name', 'no-bindirs',
        '--install', 'true', '--verify', 'true');
    is($rc4, 0, 'AC2d: add without --bin_dirs succeeds') or diag($out4);
    my $bp4 = read_backpack($path);
    my $it4 = $bp4 ? find_item($bp4, 'other', 'no-bindirs') : undef;
    if (ok(defined $it4, 'AC2d: entry exists after add-without-bin_dirs')) {
        ok(!exists $it4->{bin_dirs},
            'AC2d: an entry never given --bin_dirs has NO bin_dirs key at all (not an empty array)');
    } else {
        fail('AC2d: absent-field-on-omit skipped -- no readable entry');
    }

    # -- validation: add rejects an invalid bin_dirs entry, and does not write
    my $before = slurp_or_undef($path);

    my ($out5, $rc5) = run_bp('add', $path,
        '--category', 'other', '--name', 'gh',
        '--install', 'true', '--verify', 'true',
        '--bin_dirs', 'relative/not/absolute');
    isnt($rc5, 0, 'AC2e: add with an invalid (relative) --bin_dirs entry fails') or diag($out5);
    ok(index(lc($out5), 'bin_dirs') >= 0,
        'AC2e: the failure message names bin_dirs') or diag($out5);

    my $after = slurp_or_undef($path);
    ok(defined $before && defined $after && $before eq $after,
        'AC2e: a rejected add does not modify the file at all')
        or diag(sprintf("before defined=%s after defined=%s", (defined $before?1:0), (defined $after?1:0)));
}
ac2_block();

done_testing();
