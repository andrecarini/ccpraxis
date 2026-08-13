#!/usr/bin/env perl
# t/02-write-guard.t — bug reports are writable only through almanac-bug.pl.
#
# The state machine's freeze is only as good as the ban on editing around it, so
# a PreToolUse hook denies Edit/Write/MultiEdit/NotebookEdit against the reports
# directory — the same shape butler uses to protect blueprint.md.
#
# It is deliberately NOT bp_hook_gate'd. That helper needs BP_LEDGER/BP_DIR/
# BP_PROJECT_ROOT, exported only by bp-launch.sh, so a gated hook is inert in
# exactly the sessions that file bug reports: an ordinary agent in an unrelated
# project. Shipped via this plugin's own hooks.json rather than a host settings
# file, so any project with almanac enabled is covered.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;

(my $H = "$Bin/../../hooks") =~ s{\\}{/}g;
my $GUARD = "$H/guard-almanac-write.sh";
ok(-f $GUARD, 'guard-almanac-write.sh exists') or BAIL_OUT('hook missing');
ok(-x $GUARD, 'guard-almanac-write.sh is executable');

my $J = JSON::PP->new->canonical;
sub fire {
    my ($payload) = @_;
    my ($fh, $tmp) = File::Temp::tempfile('alm-XXXXXX', TMPDIR => 1);
    print {$fh} $J->encode($payload); close $fh;
    my $err = "$tmp.err";
    my $rc  = system(qq{bash "$GUARD" < "$tmp" 2> "$err"});
    my $se  = do { open my $f, '<', $err or return ($rc >> 8, ''); local $/; <$f> // '' };
    unlink $tmp, $err;
    return ($rc >> 8, $se);
}
sub ev {
    my ($tool, $path) = @_;
    my $key = $tool eq 'NotebookEdit' ? 'notebook_path' : 'file_path';
    return { hook_event_name=>'PreToolUse', tool_name=>$tool, tool_input=>{ $key => $path } };
}

my $R = '/c/Development/Someproject/.ccpraxis-local-data/bug-reports/20260813-010203-abcd.md';

for my $tool (qw(Edit Write MultiEdit NotebookEdit)) {
    my ($rc, $se) = fire(ev($tool, $R));
    is($rc, 2, "$tool on a bug report is DENIED");
    like($se, qr/BLOCKED/, "$tool denial says BLOCKED");
}

{   # The denial has to be actionable, or it just blocks work.
    my (undef, $se) = fire(ev('Edit', $R));
    like($se, qr/almanac-bug\.pl update/, 'the denial gives the update verb for an open report');
    like($se, qr/almanac-bug\.pl file/,   'the denial gives the follow-up route for a frozen one');
    like($se, qr/20260813-010203-abcd/,   'the denial names the report id');
}

# Everything else is untouched. A guard that leaked into ordinary edits would be
# turned off within a day, and it must never block a project's real work.
for my $p (
    '/c/Development/Someproject/src/main.rs',
    '/c/Development/Someproject/.ccpraxis-local-data/blueprints/x/blueprint.md',
    '/c/Development/Someproject/bug-reports/notes.md',          # similar name, wrong place
    '/c/Development/Someproject/.ccpraxis-local-data/guidance/x.md',
) {
    my ($rc) = fire(ev('Write', $p));
    is($rc, 0, "Write to $p is allowed");
}

{   # Reading a report is always fine — triage depends on it.
    my ($rc) = fire({ hook_event_name=>'PreToolUse', tool_name=>'Read',
                      tool_input=>{ file_path=>$R } });
    is($rc, 0, 'Read on a bug report is allowed');
    my ($rc2) = fire({ hook_event_name=>'PreToolUse', tool_name=>'Bash',
                       tool_input=>{ command=>"cat $R" } });
    is($rc2, 0, 'Bash is not inspected by this hook (the digest catches tampering instead)');
}

{   # Fail-open on junk: wedging an unrelated project's session is worse than an
    # unguarded edit, especially since the digest still detects the write.
    my ($rc) = fire({ hook_event_name=>'PreToolUse', tool_name=>'Edit', tool_input=>{} });
    is($rc, 0, 'a payload with no path fails open');
    my ($fh, $tmp) = File::Temp::tempfile('alm-XXXXXX', TMPDIR => 1);
    print {$fh} "not json at all"; close $fh;
    my $rc2 = system(qq{bash "$GUARD" < "$tmp" 2>/dev/null}); unlink $tmp;
    is($rc2 >> 8, 0, 'an unparseable payload fails open');
}

{   # Windows path separators must resolve the same way.
    my ($rc) = fire(ev('Edit', 'C:\\Development\\P\\.ccpraxis-local-data\\bug-reports\\x.md'));
    is($rc, 2, 'a backslashed Windows path is still recognised as a report');
}

{   # Not gated — it must fire with no BP_* contract present, which is the only
    # environment a reporting agent in another project ever has.
    my $src = do { open my $f, '<', $GUARD or die; local $/; <$f> };
    unlike($src, qr/^\s*bp_hook_gate\s*$/m, 'the hook does not call bp_hook_gate');
    like($src, qr/NOT bp_hook_gate'd/i, '...and records why, so nobody adds one');
}

{   # The registration is the load-bearing half: an unregistered hook is prose.
    my $hj = "$H/hooks.json";
    ok(-f $hj, 'hooks.json exists');
    my $cfg = eval { JSON::PP->new->decode(do { open my $f,'<',$hj or die; local $/; <$f> }) };
    ok($cfg, 'hooks.json is valid JSON');
    my @cmds;
    for my $blk (@{ $cfg->{hooks}{PreToolUse} || [] }) {
        push @cmds, map { $_->{command} // '' } @{ $blk->{hooks} || [] };
    }
    ok(scalar(grep { /guard-almanac-write\.sh/ } @cmds),
       'hooks.json registers the write guard as a PreToolUse hook');
    my ($blk) = @{ $cfg->{hooks}{PreToolUse} || [] };
    like($blk->{matcher} // '', qr/Edit/,  'its matcher covers Edit');
    like($blk->{matcher} // '', qr/Write/, 'and Write');
}

done_testing();
