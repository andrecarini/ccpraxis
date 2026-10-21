#!/usr/bin/env perl
# platform: any
# t/02 — bug reports are writable only through almanac-bug.pl.
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

# The guard names the almanac plugin dir it was run from, derived the way the
# guard itself derives it (bash `cd && pwd` on its own hooks/ parent), with
# the <ccpraxis> placeholder kept only as its fallback (commit caf888a).
my $ALMDIR_RE = do {
    my $d = `bash -c 'cd "\$1" && pwd' _ "$Bin/../.."`;
    chomp $d;
    length($d) ? qr{(?:\Q$d\E|<ccpraxis>/plugins/almanac)} : qr{<ccpraxis>/plugins/almanac};
};
use Test::More;
use File::Temp qw(tempdir tempfile);
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

# --- Review defect M1 -- tab-IFS field collapse: byte-exact deny text -------
# A run of tabs is one IFS delimiter and empty fields vanish, so the id/path
# fields can shift into each other's slots. Pin the exact lines, not just
# "the id appears somewhere in stderr".
{
    my $bug_id = '20260813-010203-abcd';
    my (undef, $se) = fire(ev('Edit', $R));
    my @lines = split /\n/, $se;
    ok((grep { $_ eq "  $R" } @lines),
        'M1/bug: a stderr line is exactly "  <path>" -- the path field lands in the path slot, not blank/shifted')
        or diag("stderr:\n$se");
    ok((grep { /^\s*perl $ALMDIR_RE\/scripts\/almanac-bug\.pl update \Q$bug_id\E --body -\s*$/ } @lines),
        'M1/bug: the update line reads "...almanac-bug.pl update <id> --body -" exactly -- the id field '
      . 'lands in the id slot, never the path')
        or diag("stderr:\n$se");
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

# =============================================================================
# Package 09-write-guard, spec section 4: DC7's three parts on the CLI/script
# under test, AlmanacBug -- (a) new_id collision-freedom, (b) claim_report_path
# never overwriting an existing report, (c) the two-generator decision recorded
# in a comment. Loaded once via the `do $A` convention (see
# almanac-lock-rename-retry.t:39-45): `unless (caller)` is false when a file
# runs under `do`, so the CLI's own main dispatch never fires here.
# =============================================================================
(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $A = "$S/almanac-bug.pl";
ok(-f $A, 'almanac-bug.pl exists (DC7 fixture)') or BAIL_OUT('script missing');

sub slurp_text_wg {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub read_all_lines_wg {
    my ($path) = @_;
    open(my $fh, '<', $path) or return ();
    my @l = <$fh>;
    close $fh;
    return @l;
}

sub field_of_wg {
    my ($p, $k) = @_;
    open my $f, '<:raw', $p or return undef;
    local $/;
    my $t = <$f>;
    close $f;
    return $t =~ /^\Q$k\E:\s*(.*)$/m ? $1 : undef;
}

do $A;
die "could not load almanac-bug.pl in-process: $@" if $@;

# --- AC19 / DC7a -- 10000 distinct ids in one process-second ---------------
{
    my $FIXED = 1_700_000_000;
    my %seen;
    for (1 .. 10_000) {
        my $id = AlmanacBug::new_id($FIXED);
        $seen{$id}++;
    }
    my @dupes = grep { $seen{$_} > 1 } keys %seen;
    is(scalar(@dupes), 0, 'AC19/DC7a: 10000 calls to new_id($fixed_epoch) in one process-second are all distinct')
        or diag('duplicate count: ' . scalar(@dupes));
    my @bad_shape = grep { $_ !~ /^\d{8}-\d{6}-[0-9a-f]{4}\z/ } keys %seen;
    is(scalar(@bad_shape), 0, 'AC19/DC7a: every generated id matches ^\d{8}-\d{6}-[0-9a-f]{4}$')
        or diag(join(', ', @bad_shape[0 .. (@bad_shape > 4 ? 4 : $#bad_shape)]));
}

# --- AC20 / DC7a -- claim_report_path never overwrites an existing report ---
{
    my $dir20 = tempdir(CLEANUP => 1);
    $dir20 =~ s{\\}{/}g;
    my $FIXED20 = 1_700_000_001;

    local $AlmanacBug::ID_BASE = 0x1234;
    local $AlmanacBug::ID_SEQ  = 0;
    my $predicted = AlmanacBug::new_id($FIXED20);
    $AlmanacBug::ID_SEQ = 0;   # rewind so claim_report_path mints the SAME id first

    require File::Path;
    File::Path::make_path($dir20);
    my $sentinel_bytes = "SENTINEL-DO-NOT-TOUCH\n";
    open(my $sfh, '>:raw', "$dir20/$predicted.md") or die "fixture: cannot write sentinel: $!";
    print {$sfh} $sentinel_bytes;
    close $sfh;

    my ($path, $lock) = eval { AlmanacBug::claim_report_path($dir20, $FIXED20) };
    my $claim_err = $@;
    ok(defined $path, 'AC20/DC7a: claim_report_path succeeds despite the predicted id already existing')
        or diag('err: ' . (length($claim_err) ? $claim_err : (ref($lock) ? ($lock->{message} // '(no message)') : ($lock // '(undef)'))));
    if (defined $path) {
        isnt($path, "$dir20/$predicted.md",
            'AC20: claim_report_path returns a path DIFFERENT from the pre-existing predicted id');
        $lock->release if ref($lock) && $lock->can('release');
    } else {
        fail('AC20: claim_report_path returns a path DIFFERENT from the pre-existing predicted id');
    }
    my $after = do {
        open(my $f, '<:raw', "$dir20/$predicted.md") or die "fixture: cannot reread sentinel: $!";
        local $/;
        <$f>;
    };
    is($after, $sentinel_bytes, 'AC20: the pre-existing sentinel file bytes are unchanged');
}

# --- AC21 / DC7a -- 20 back-to-back `file` CLI calls, 20 distinct reports ---
{
    my $home21 = tempdir(CLEANUP => 1);
    my $proj21 = tempdir(CLEANUP => 1);
    my @ids21;
    for my $i (1 .. 20) {
        my $cmd = qq{ALMANAC_HOME="$home21" perl "$A" file --project "$proj21" }
                . qq{--title "AC21 report $i" --body "b" 2>&1};
        my $out = `$cmd`;
        my $rc  = $? >> 8;
        is($rc, 0, "AC21/DC7a: file() call $i exits 0") or diag($out);
        chomp(my $path = $out);
        my ($id) = $path =~ m{/([^/]+)\.md$};
        push @ids21, $id if defined $id;
    }
    my %uniq21 = map { $_ => 1 } @ids21;
    is(scalar(@ids21), 20, 'AC21: 20 file() calls each produced an id we could extract');
    is(scalar(keys %uniq21), 20, 'AC21: 20 back-to-back file() calls yield 20 distinct report files');

    my $list_cmd = qq{ALMANAC_HOME="$home21" perl "$A" list --project "$proj21" 2>&1};
    my $list_out = `$list_cmd`;
    for my $id (@ids21) {
        like($list_out, qr/\Q$id\E/, "AC21: list finds report $id");
    }
}

# --- AC22 / DC7b -- a legacy-shaped id keeps working end-to-end -------------
{
    my $home22 = tempdir(CLEANUP => 1);
    my $proj22 = tempdir(CLEANUP => 1);
    my $file_cmd = qq{ALMANAC_HOME="$home22" perl "$A" file --project "$proj22" }
                 . qq{--title "AC22 legacy source" --body "b" 2>&1};
    my $out22 = `$file_cmd`;
    my $rc22  = $? >> 8;
    is($rc22, 0, 'AC22 fixture: a report was filed to relabel with a legacy id') or diag($out22);
    chomp(my $path22 = $out22);
    (my $dir22 = $path22) =~ s{/[^/]+$}{};
    my $legacy_id   = '20260813-010203-abcd';
    my $legacy_path = "$dir22/$legacy_id.md";

    {
        my $bytes = slurp_text_wg($path22);
        $bytes =~ s/^id:\s*\S+$/id: $legacy_id/m;
        open(my $wf, '>:encoding(UTF-8)', $legacy_path) or die "fixture: cannot write $legacy_path: $!";
        print {$wf} $bytes;
        close $wf;
    }
    unlink $path22;

    sub run22 {
        my (@a) = @_;
        my $c = qq{ALMANAC_HOME="$home22" perl "$A" } . join(' ', @a) . ' 2>&1';
        my $o = `$c`;
        return ($? >> 8, $o // '');
    }

    my ($rc_l22, $lout22) = run22('list', '--project', qq{"$proj22"});
    is($rc_l22, 0, 'AC22: list exits 0 for a legacy-id report');
    like($lout22, qr/\Q$legacy_id\E/, 'AC22: list finds it by the legacy id');

    my ($rc_a22) = run22('append', $legacy_id, '--project', qq{"$proj22"}, '--body', qq{"more detail"});
    is($rc_a22, 0, 'AC22: append exits 0 addressed by the legacy id');

    my ($rc_s22) = run22('set-status', $legacy_id, '--project', qq{"$proj22"}, '--to', 'dropped',
                         '--note', qq{"not reproducible"});
    is($rc_s22, 0, 'AC22: set-status --to dropped exits 0 addressed by the legacy id');

    my ($rc_v22) = run22('verify', '--project', qq{"$proj22"});
    is($rc_v22, 0, 'AC22: verify exits 0');

    ok(-f $legacy_path, 'AC22: the report is still filed at its original legacy-id file name');
    is(field_of_wg($legacy_path, 'id'), $legacy_id, 'AC22: its frontmatter id: field is unchanged');
}

# --- AC23 / DC7c -- the two-generator parity decision is recorded in a comment
{
    my @lines23 = read_all_lines_wg($A);
    my ($idx23) = grep { $lines23[$_] =~ /^\s*sub\s+new_id\b/ } 0 .. $#lines23;
    ok(defined $idx23, 'AC23 fixture: sub new_id is found in almanac-bug.pl') or diag('sub new_id not found');
    if (defined $idx23) {
        my $start23  = $idx23 > 15 ? $idx23 - 15 : 0;
        my $window23 = join('', @lines23[$start23 .. $idx23]);
        like($window23, qr/Almanac::Record/,
            'AC23/DC7c: a comment within 15 lines of sub new_id mentions Almanac::Record');
        like($window23, qr/tooling-bug-filing/,
            'AC23/DC7c: ...and mentions tooling-bug-filing');
    } else {
        fail('AC23/DC7c: a comment within 15 lines of sub new_id mentions Almanac::Record');
        fail('AC23/DC7c: ...and mentions tooling-bug-filing');
    }
}

done_testing();
