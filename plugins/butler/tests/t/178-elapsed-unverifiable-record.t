#!/usr/bin/env perl
# t/178 -- `elapsed` must not FABRICATE an uptime for a record it cannot evaluate.
#
# Found while driving agent-telemetry/02. `elapsed_seconds($started_at, $now)` is
# a plain subtraction (t/136 B1/B2 pin that, deliberately, including the
# unclamped backward-clock case). When a `running` record has no usable
# `started_at`, `$now - undef` evaluates to `$now` -- so `elapsed` printed
# `elapsed_seconds: 1788899644`, reporting an agent as having run for ~56 years,
# and emitted an uninitialized-value warning on the way.
#
# That is not cosmetic. The whole point of this telemetry is a DRIVER-SIDE uptime
# that can be trusted (agent-telemetry Decision 7, which exists because one
# dispatch burned ~4h while self-reporting 47 minutes). A path that invents an
# uptime is worse than one that admits it does not know.
#
# The author already recognised the hazard and guarded the `list` site -- its own
# comment says the guard exists so "no fabricated elapsed_seconds: 0 is printed
# for a record that has no real answer". The `elapsed` site was missed.
#
# Fix reuses this function's OWN existing vocabulary for an unevaluable record:
# `UNVERIFIABLE: ...` on stdout, exit 4 -- exactly what a missing record already
# does -- rather than inventing a new marker.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;

my $SCRIPT = 'plugins/butler/scripts/bp-dispatch-log.pl';
ok(-f $SCRIPT, "harness: $SCRIPT exists") or BAIL_OUT("script missing");

sub mk_root {
    my (%rec) = @_;
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/.ccpraxis-local-data/.dispatch-log");
    my $id = $rec{id};
    my @pairs = map { "\"$_\":" . (($rec{$_} =~ /^-?\d+(?:\.\d+)?$/) ? $rec{$_} : "\"$rec{$_}\"") }
                sort keys %rec;
    open my $fh, '>', "$root/.ccpraxis-local-data/.dispatch-log/$id.json" or die $!;
    print $fh '{' . join(',', @pairs) . '}';
    close $fh;
    return $root;
}

# run($root, $id) -> ($stdout, $stderr, $exit)
sub run_elapsed {
    my ($root, $id) = @_;
    my $out = File::Spec->catfile($root, 'o.txt');
    my $err = File::Spec->catfile($root, 'e.txt');
    my $rc  = system("perl $SCRIPT elapsed --root \"$root\" --id $id > \"$out\" 2> \"$err\"");
    my $exit = ($rc & 127) ? (128 + ($rc & 127)) : ($rc >> 8);
    my $slurp = sub { open my $f, '<', $_[0] or return ''; local $/; my $t = <$f>; close $f; defined $t ? $t : '' };
    return ($slurp->($out), $slurp->($err), $exit);
}

# --- A. missing started_at: the motivating case -------------------------------
{
    my $root = mk_root(id => 'bad1', status => 'running', worker_type => 'wt');
    my ($out, $err, $exit) = run_elapsed($root, 'bad1');

    is($exit, 4, 'A1: exits 4 (UNVERIFIABLE), not 0, for a running record with no started_at');
    like($out, qr/UNVERIFIABLE/, 'A2: stdout says UNVERIFIABLE, reusing this function\'s own vocabulary');
    unlike($out, qr/elapsed_seconds:\s*\d/,
        'A3 CANONICAL: NO fabricated elapsed_seconds number is printed -- this is the defect');
    unlike($err, qr/uninitialized/i,
        'A4: no "uninitialized value" warning on stderr');
    is($err, '', 'A5: stderr is completely silent');
}

# --- B. non-numeric started_at ------------------------------------------------
{
    my $root = mk_root(id => 'bad2', status => 'running', worker_type => 'wt', started_at => 'abc');
    my ($out, $err, $exit) = run_elapsed($root, 'bad2');

    is($exit, 4, 'B1: exits 4 for a non-numeric started_at');
    like($out, qr/UNVERIFIABLE/, 'B2: stdout says UNVERIFIABLE');
    unlike($out, qr/elapsed_seconds:\s*\d/, 'B3: no fabricated number for a non-numeric started_at');
    is($err, '', 'B4: stderr silent');
}

# --- C. NON-VACUITY: a valid record must still work exactly as before ---------
# Without this, A and B could pass by breaking `elapsed` for everything.
{
    my $root = mk_root(id => 'good1', status => 'running', worker_type => 'wt',
                       started_at => 1000, budget_seconds => 1800);
    my ($out, $err, $exit) = run_elapsed($root, 'good1');

    is($exit, 0, 'C1: a well-formed record still exits 0');
    like($out, qr/elapsed_seconds:\s*\d+/, 'C2 NON-VACUITY: a real elapsed_seconds IS still printed');
    like($out, qr/id:\s*good1/,      'C3: id still printed');
    like($out, qr/budget_seconds:\s*1800/, 'C4: budget_seconds still printed');
    is($err, '', 'C5: stderr silent for the healthy path too');
}

# --- D. a MISSING record keeps its existing behaviour -------------------------
# The fix reuses this path's vocabulary; it must not change it.
{
    my $root = mk_root(id => 'present', status => 'running', worker_type => 'wt', started_at => 1000);
    my ($out, $err, $exit) = run_elapsed($root, 'absent');

    is($exit, 4, 'D1: a genuinely missing record still exits 4 (unchanged)');
    like($out, qr/UNVERIFIABLE: no record for absent/, 'D2: its existing message is unchanged');
}

done_testing();
