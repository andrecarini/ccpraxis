#!/usr/bin/env perl
# platform: windows
# ORACLE for package 11-ac-loss-clean-suspend-cycle (blueprint tooling-backlog),
# AC-8 and AC-14 of .ccpraxis-local-data/blueprints/tooling-backlog/specs/
# 11-ac-loss-clean-suspend-cycle-spec.md sec 2.5/3.5/3.9/3.10: the
# director's (`bp-drive-next.pl next`) ac_check wiring -- the new
# `ac-stand-down` action, the resume path, and the non-regression baseline
# (state=ac, probe=ac prints exactly the pre-existing action).
#
# bp-drive-next.pl does NOT yet have ac_check wired in, and BpAcWatch.pm
# does not exist at all. Run as a REAL SUBPROCESS (spec AC-8's own wording:
# "subprocess, fixture data dir"), so until this package's implementer adds
# the ac_check call, every "expired" fixture below produces whatever
# bp-drive-next.pl prints TODAY for that data dir (most likely an
# in-flight/need-order/run-package action, never ac-stand-down) -- a
# legible mismatch, not a crash.
#
# Written BLIND to any implementation file: derived only from spec 2.5 (the
# ac_check pseudocode and the ac-stand-down JSON shape) and 3.5/3.9/3.10.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use Cwd qw(getcwd);

my $S = "$Bin/../../scripts"; $S =~ s{\\}{/}g;
my $SCRIPT = "$S/bp-drive-next.pl";

my $J = JSON::PP->new->canonical;

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

sub slurp {
    my ($p) = @_;
    return '' unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

sub write_json {
    my ($path, $data) = @_;
    make_path(File::Basename::dirname($path));
    open my $fh, '>:raw', $path or die "write_json $path: $!";
    print $fh $J->encode($data);
    close $fh;
}
use File::Basename ();

# make_bp_dir(data, name, \@pkgs) -- mirrors drive-next.t's own helper.
sub make_bp_dir {
    my ($data, $name, $pkgs) = @_;
    my $bp = "$data/blueprints/$name";
    make_path("$bp/packages");
    my $md = "# $name\n\n## Package status\n\n"
           . "| pkg | deliverable | depends_on | model | status |\n"
           . "|-----|-------------|------------|-------|--------|\n";
    for my $p (@$pkgs) {
        my $deps = (ref $p->{deps} eq 'ARRAY' && @{$p->{deps}}) ? join(', ', @{$p->{deps}}) : '—';
        $md .= "| $p->{key} | thing | $deps | sonnet | $p->{status} |\n";
    }
    open my $bfh, '>:raw', "$bp/blueprint.md" or die $!;
    print $bfh $md;
    close $bfh;
    for my $p (@$pkgs) {
        my $ws = $p->{write_set} // "blueprints/$name/$p->{key}/";
        open my $lfh, '>:raw', "$bp/packages/$p->{key}.md" or die $!;
        print $lfh "---\npackage: $p->{key}\nblueprint: $name\nstatus: $p->{status}\n"
                 . "model: sonnet\nmax_turns: 80\nwrite_set: $ws\n"
                 . "test_paths: $ws\nlast_updated: 2028-01-01T00:00:00Z\n---\n\n# $p->{key}\n";
        close $lfh;
    }
    return $bp;
}

sub write_ac_state {
    my ($data, $h) = @_;
    make_path("$data/.drive-solo");
    open my $fh, '>:raw', "$data/.drive-solo/ac-state.json" or die $!;
    print $fh $J->encode($h);
    close $fh;
}

sub write_probe_file {
    my ($reading) = @_;
    my (undef, $pf) = tempfile();
    open my $fh, '>', $pf or die $!;
    print {$fh} "$reading\n";
    close $fh;
    return $pf;
}

# run_next(\@args, \%env_over) -> ($rc, $out, $err)
sub run_next {
    my ($args, $env_over) = @_;
    $env_over //= {};
    my (undef, $opath) = tempfile();
    my (undef, $epath) = tempfile();

    local %ENV = %ENV;
    for my $k (keys %$env_over) {
        if (defined $env_over->{$k}) { $ENV{$k} = $env_over->{$k} } else { delete $ENV{$k} }
    }
    $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
    $ENV{CCPRAXIS_USAGE_VERDICT_JSON} = '{"action":"ok"}'
        unless exists $env_over->{CCPRAXIS_USAGE_VERDICT_JSON};

    open(my $oldout, '>&', \*STDOUT) or die "dup STDOUT: $!";
    open(my $olderr, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDOUT, '>', $opath) or do { open(STDOUT, '>&', $oldout); die "redirect STDOUT: $!" };
    open(STDERR, '>', $epath) or do { open(STDERR, '>&', $olderr); die "redirect STDERR: $!" };
    my $sysrc = system($^X, $SCRIPT, @$args);
    open(STDOUT, '>&', $oldout) or die "restore STDOUT: $!"; close $oldout;
    open(STDERR, '>&', $olderr) or die "restore STDERR: $!"; close $olderr;

    my $out = slurp($opath);
    my $err = slurp($epath);
    unlink $opath, $epath;
    return (($sysrc == -1 ? -1 : $sysrc >> 8), $out, $err);
}

# ===========================================================================
# AC-8 (DC1): next with state pre-seeded "expired" and probe file "dc"
# prints a single-line {"action":"ac-stand-down",...}. No keep-awake
# 'active' call is implied (checked indirectly: no keepawake.pid is created
# by this call, since BpAcWatch::standdown_director_side only ever
# RELEASES, never asserts).
# ===========================================================================
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bp-ac', [
        { key => 'p1', status => 'pending', write_set => 'ac/p1/' },
    ]);
    write_ac_state($data, {
        v => 1, phase => 'expired', source => 'dc', probed_at => time() - 1,
        dc_since => time() - 400, grace_until => time() - 100,
        reconnected_at => undef, reconnect_basis => undef, updated_at => time() - 1,
    });
    my $pf = write_probe_file('dc');

    my ($rc, $out, $err) = run_next(['next', '--scope', 'bp-ac'], {
        CCPRAXIS_DATA_DIR      => $data,
        CCPRAXIS_AC_PROBE_FILE => $pf,
    });
    is($rc, 0, 'AC-8: next exits 0 even for the ac-stand-down action');
    my @lines = grep { length } split /\n/, $out;
    is(scalar(@lines), 1, 'AC-8: stdout is exactly one line') or diag("stdout was:\n$out");
    my $act = eval { $J->decode($lines[0] // '') };
    ok(defined $act, 'AC-8: stdout is valid JSON') or diag("stdout was:\n$out");
    is($act->{action} // '', 'ac-stand-down', 'AC-8: the action is ac-stand-down')
        if defined $act;
    ok(!-f "$data/.drive-solo/keepawake.pid",
        'AC-8: no keepawake.pid was created by this call (no "active" keep-awake call)');
}

# ===========================================================================
# AC-8 (non-regression): the same fixture with state "ac" and probe "ac"
# prints the SAME action bp-drive-next.pl printed before this package (a
# need-order action, since there is no order.json yet) -- i.e. the ac_check
# wiring is a true no-op on the ordinary AC-powered path.
# ===========================================================================
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bp-ac2', [
        { key => 'p1', status => 'pending', write_set => 'ac2/p1/' },
    ]);
    make_bp_dir($data, 'bp-ac3', [
        { key => 'q1', status => 'pending', write_set => 'ac3/q1/' },
    ]);
    write_ac_state($data, { v => 1, phase => 'ac', source => 'ac', probed_at => time() });
    my $pf = write_probe_file('ac');

    my ($rc, $out, $err) = run_next(['next', '--scope', 'bp-ac2,bp-ac3'], {
        CCPRAXIS_DATA_DIR      => $data,
        CCPRAXIS_AC_PROBE_FILE => $pf,
    });
    is($rc, 0, 'AC-8 non-regression: next exits 0');
    chomp(my $line = $out);
    my $act = eval { $J->decode($line) };
    ok(defined $act, 'AC-8 non-regression: stdout is valid JSON') or diag("stdout was: $out");
    is($act->{action} // '', 'need-order', 'AC-8 non-regression: action is need-order, unaffected by ac_check')
        if defined $act;
}

# ===========================================================================
# AC-14 (DC4, DC6): next with phase "reconnected" removes the marker, logs
# RESUME then RESUMED, leaves phase ac, and prints a NORMAL (non-
# ac-stand-down) action.
# ===========================================================================
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bp-r', [
        { key => 'p1', status => 'pending', write_set => 'r/p1/' },
    ]);
    make_path("$data/.drive-solo");
    open my $mfh, '>:raw', "$data/.drive-solo/ac-standdown.json" or die $!;
    print $mfh '{"v":1,"since":0,"since_iso":"-","reason":"x","inflight":[]}';
    close $mfh;
    write_json("$data/.drive-solo/order.json", { order => ['bp-r'], recorded_at => time() });
    write_ac_state($data, {
        v => 1, phase => 'reconnected', source => 'ac', probed_at => time(),
        dc_since => time() - 600, grace_until => time() - 300, reconnected_at => time(),
        reconnect_basis => 'ac', updated_at => time(),
    });
    my $pf = write_probe_file('ac');

    my ($rc, $out, $err) = run_next(['next', '--scope', 'bp-r'], {
        CCPRAXIS_DATA_DIR      => $data,
        CCPRAXIS_AC_PROBE_FILE => $pf,
    });
    is($rc, 0, 'AC-14: next exits 0 on the resume turn');
    chomp(my $line = $out);
    my $act = eval { $J->decode($line) };
    ok(defined $act, 'AC-14: stdout is valid JSON') or diag("stdout was: $out");
    isnt($act->{action} // '', 'ac-stand-down', 'AC-14: the printed action is a normal one, not ac-stand-down')
        if defined $act;
    ok(!-e "$data/.drive-solo/ac-standdown.json", 'AC-14: the stand-down marker is removed');
    my $log = slurp("$data/.drive-solo/ac-cycle.log");
    like($log, qr/RESUME\b/, 'AC-14: the log carries a RESUME line') if length $log;
    like($log, qr/RESUMED\b/, 'AC-14: the log carries a RESUMED line') if length $log;
}

# ===========================================================================
# AC-14 (DC1, "premature re-arm"): next with phase "monitoring" and probe
# "dc" prints ac-stand-down again, not a normal action.
# ===========================================================================
{
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bp-m', [
        { key => 'p1', status => 'pending', write_set => 'm/p1/' },
    ]);
    write_ac_state($data, { v => 1, phase => 'monitoring', source => 'dc', probed_at => time() });
    my $pf = write_probe_file('dc');

    my ($rc, $out, $err) = run_next(['next', '--scope', 'bp-m'], {
        CCPRAXIS_DATA_DIR      => $data,
        CCPRAXIS_AC_PROBE_FILE => $pf,
    });
    is($rc, 0, 'AC-14 premature re-arm: next exits 0');
    chomp(my $line = $out);
    my $act = eval { $J->decode($line) };
    ok(defined $act, 'AC-14 premature re-arm: stdout is valid JSON') or diag("stdout was: $out");
    is($act->{action} // '', 'ac-stand-down', 'AC-14 premature re-arm: still ac-stand-down while on battery')
        if defined $act;
}

done_testing();
