#!/usr/bin/env perl
# platform: any
# The disarm judge's evidence digest (bug 20261023-130606-a417). The judge
# used to collect open bugs, todos, blueprint states and git state itself
# with tool calls, overran its time bound twice on ccpraxis and never reached
# a verdict, so no agent could disarm. bp-disarm-digest.pl now gathers those
# facts from disk and bp-judge-disarm.sh puts them in the judge's prompt.
#
# Checked here: each section reports exactly the open records of a fixture
# project and skips closed ones; a missing store or a non-repo degrades to a
# note instead of dying; the wrapper's prompt carries the digest; and both
# processes cap the bound at 105 s, under the 120 s default limit of the
# foreground Bash call that runs off-confirm.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $DIGEST  = "$S/bp-disarm-digest.pl";
my $WRAPPER = "$S/bp-judge-disarm.sh";

sub spit {
    my ($p, $body) = @_;
    (my $d = $p) =~ s{/[^/]*\z}{};
    make_path($d);
    open(my $fh, '>:raw', $p) or die "$p: $!";
    print {$fh} $body;
    close $fh;
}
sub rec { my (%f) = @_; return "---\n" . join('', map { "$_: $f{$_}\n" } sort keys %f) . "---\nbody\n" }

my $P = tempdir(CLEANUP => 1);
$P =~ s{\\}{/}g;
my $D = "$P/.ccpraxis-local-data";
spit("$D/bug-reports/20261001-000000-aaaa.md", rec(id => 'x', status => 'open',    title => 'Open bug one'));
spit("$D/bug-reports/20261001-000000-bbbb.md", rec(id => 'x', status => 'fixed',   title => 'Fixed bug'));
spit("$D/bug-reports/20261001-000000-cccc.md", rec(id => 'x', status => 'triaging', title => 'Claimed bug'));
spit("$D/almanac/todo/t1.md",  rec(id => 't1', status => 'open', title => 'Open todo'));
spit("$D/almanac/todo/t2.md",  rec(id => 't2', status => 'done', title => 'Done todo'));
spit("$D/almanac/inbox/q1.md", rec(id => 'q1', status => 'unanswered', title => 'Waiting question'));
spit("$D/almanac/inbox/q2.md", rec(id => 'q2', status => 'answered',   title => 'Settled question'));
spit("$D/blueprints/bp-a/blueprint.md", "# A\n\n```\nblueprint: bp-a\nstatus: audited\n```\n");
spit("$D/blueprints/bp-a/packages/01-x.md", rec(package => '01-x', status => 'done'));
spit("$D/blueprints/bp-a/packages/02-y.md", rec(package => '02-y', status => 'running'));

my $out = `perl "$DIGEST" "$P" 2>&1`;
is($? >> 8, 0, 'the digest exits 0');
like($out, qr/^## Open bug reports \(2\)$/m,          'bugs: open and triaging count, fixed does not');
like($out, qr/aaaa \[open\] Open bug one/,             'bugs: the open report is listed with its status');
like($out, qr/cccc \[triaging\] Claimed bug/,          'bugs: a triaging report is listed');
unlike($out, qr/Fixed bug/,                            'bugs: a fixed report is not');
like($out, qr/^## Open todos \(1\)$/m,                 'todos: only the open one counts');
unlike($out, qr/Done todo/,                            'todos: a done todo is not listed');
like($out, qr/q1 \[unanswered\] Waiting question/,     'inbox: the unanswered item is listed');
unlike($out, qr/Settled question/,                     'inbox: an answered item is not');
like($out, qr/bp-a \[audited\]: 1 done, 1 running; not finished: 02-y=running/,
                                                       'blueprints: lifecycle, counts and the unfinished package');
like($out, qr/^## git status\n  unavailable$/m,        'git: a non-repo degrades to "unavailable"');

my $bare = tempdir(CLEANUP => 1);
my $out2 = `perl "$DIGEST" "$bare" 2>&1`;
is($? >> 8, 0, 'a project with no stores still exits 0');
like($out2, qr/no store at/, 'and says which store is missing rather than claiming none are open');
like(`perl "$DIGEST" "$bare/nope" 2>&1`, qr/digest unavailable/, 'a missing root says the digest is unavailable');

# The wrapper puts the digest in the judge's prompt (stub run: no claude).
{
    my $vdir = tempdir(CLEANUP => 1);
    $vdir =~ s{\\}{/}g;
    local $ENV{CCPRAXIS_DISARM_JUDGE_STUB} = 'approve';
    my $err = `bash "$WRAPPER" deadbeef "$vdir/deadbeef.verdict.json" "$P" "ship it" "all done" "nothing left" 2>&1`;
    my $argv = '';
    if (open(my $fh, '<:raw', "$vdir/deadbeef.argv")) { local $/; $argv = <$fh>; close $fh }
    my @a = split /\0/, $argv;
    my $prompt = $a[4] // '';
    ok(length $prompt, 'the wrapper recorded its dispatch argv') or diag($err);
    like($prompt, qr/Open bug one/,      'the prompt carries the digest\'s open bug');
    like($prompt, qr/Waiting question/,  'the prompt carries the digest\'s unanswered inbox item');
    like($prompt, qr/Judge from it first/, 'the prompt tells the judge to work from the digest');
}

# Both sides cap the bound at 105 s.
{
    open(my $fh, '<:raw', $WRAPPER) or die $!; local $/; my $w = <$fh>; close $fh;
    like($w, qr/T=105 ;;/, 'bp-judge-disarm.sh defaults T to 105');
    like($w, qr/-gt 105 \]/, 'and clamps anything above 105');
    open($fh, '<:raw', "$S/butler-continuity.pl") or die $!; my $c = <$fh>; close $fh;
    like($c, qr/my \$T = 105;/, 'butler-continuity.pl waits on the same 105 s default');
    like($c, qr/\$traw <= 105\)/, 'and clamps the override the same way');
}

done_testing();
