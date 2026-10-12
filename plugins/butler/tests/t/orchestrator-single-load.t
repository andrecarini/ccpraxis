#!/usr/bin/env perl
# platform: any
# bp-orchestrator.pl must be loaded exactly once per process, also when it is
# the main script.
#
# Run as `perl bp-orchestrator.pl <bp>`, the file is never entered in %INC.
# Its lazy requires of bp-cache-state.pl and bp-progress.pl (resume_mode,
# _observe_cache, the progress hooks) pull files that `require
# "$DIR/bp-orchestrator.pl"` at their own top level, so the whole orchestrator
# compiled a second time: one "Subroutine ... redefined" line per sub (158 in
# where-things-go's runs/orchestrator.log, 2026-10-12), and every file-scoped
# `my` re-initialised underneath the running loop.
#
# A child process stands in for the main-script case: it loads the file under
# a non-canonical key (a relative path), deletes that key so %INC holds no
# entry for the file, exactly as for $0, and then requires both dependents.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempfile);
use Cwd qw(abs_path);

my $dir = abs_path("$Bin/../../scripts");
$dir =~ s{\\}{/}g;
ok(-f "$dir/bp-orchestrator.pl", 'bp-orchestrator.pl located');

my ($fh, $script) = tempfile(SUFFIX => '.pl', UNLINK => 1);
print {$fh} <<"PERL";
use strict; use warnings;
chdir '$dir' or die "chdir: \$!";
do './bp-orchestrator.pl' or die "load failed: \$\@ \$!";
delete \$INC{'./bp-orchestrator.pl'};    # as for \$0: no %INC entry
require '$dir/bp-cache-state.pl';
require '$dir/bp-progress.pl';
print "loaded\\n";
PERL
close $fh;

my (undef, $errf) = tempfile(UNLINK => 1);
my (undef, $outf) = tempfile(UNLINK => 1);
{
    open my $saveerr, '>&', \*STDERR or die;
    open my $saveout, '>&', \*STDOUT or die;
    open STDERR, '>', $errf or die;
    open STDOUT, '>', $outf or die;
    system($^X, '-w', $script);
    open STDERR, '>&', $saveerr or die;
    open STDOUT, '>&', $saveout or die;
}
my $rc = $? >> 8;
my $err = do { local (@ARGV, $/) = $errf; <> } // '';
my $out = do { local (@ARGV, $/) = $outf; <> } // '';

is($rc, 0, 'child loaded the orchestrator and both dependents') or diag $err;
like($out, qr/^loaded$/m, 'child reached the end');
my @redef = $err =~ /^(Subroutine \S+ redefined)/mg;
is(scalar @redef, 0, 'no sub of bp-orchestrator.pl is compiled twice')
    or diag join "\n", @redef[0 .. ($#redef < 4 ? $#redef : 4)];

done_testing;
