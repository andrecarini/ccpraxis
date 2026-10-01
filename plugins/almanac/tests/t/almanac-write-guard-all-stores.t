#!/usr/bin/env perl
# platform: any
# Blueprint almanac-records, package 09: guard-almanac-write.sh classifies
# EVERY almanac store path (project and global, known and unknown record
# types), not only bug reports, and Almanac::Store's new seal sidecar plus
# almanac-bug.pl's widened `verify` give layer three -- the hash-based
# tamper detector -- the same reach. See specs/09-write-guard-spec.md.
#
# Isolation, per spec section 4: every spawn below sets ALMANAC_HOME and HOME
# to a tempdir and never touches the real stores (proven at the end, AC18).
# Guard payload paths are synthetic and are never opened -- the guard classifies
# a string, it does not stat anything.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path ();
use JSON::PP;
use Digest::SHA qw(sha256_hex);
use Encode ();
use Time::HiRes ();
use Cwd ();

(my $H = "$Bin/../../hooks")   =~ s{\\}{/}g;
(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
use lib "$Bin/../../scripts";

my $GUARD = "$H/guard-almanac-write.sh";
my $BUG   = "$S/almanac-bug.pl";
ok(-f $GUARD, 'guard-almanac-write.sh exists') or BAIL_OUT('hook missing');
ok(-f $BUG,   'almanac-bug.pl exists')         or BAIL_OUT('script missing');

my $STORE_PM = "$S/Almanac/Store.pm";
ok(-f $STORE_PM, 'Almanac::Store module file exists at plugins/almanac/scripts/Almanac/Store.pm')
    or diag('Almanac/Store.pm has not been widened with the seal yet -- every [S] assertion below '
          . 'is expected to fail for exactly that reason, not any other.');

my $STORE_LOAD_ERR;
eval { require Almanac::Store; 1 } or do { $STORE_LOAD_ERR = $@ };
ok(!defined $STORE_LOAD_ERR, 'Almanac::Store requires cleanly') or diag("load error: $STORE_LOAD_ERR");

# =============================================================================
# scaffolding
# =============================================================================
sub slurp_raw {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub slurp_text {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub read_all_lines {
    my ($path) = @_;
    open(my $fh, '<', $path) or return ();
    my @l = <$fh>;
    close $fh;
    return @l;
}

sub field0 {
    my ($text, $key) = @_;
    return undef unless defined $text;
    return $1 if $text =~ /^\Q$key\E:\s(\S+)$/m;
    return undef;
}

# fire($payload) -> ($rc, $stdout, $stderr) -- a real bash spawn of the guard,
# both streams captured to temp files (never an in-memory scalar reopen, per
# CLAUDE.md's Windows landmine list). Payloads are encoded ->utf8 so a
# non-ASCII path travels as the same raw UTF-8 bytes a real hook payload
# would carry, and AC3's byte-identity check is meaningful.
my $J = JSON::PP->new->canonical->utf8;

sub fire {
    my ($payload) = @_;
    my (undef, $tmp) = tempfile('alm-XXXXXX', TMPDIR => 1);
    open(my $fh, '>:raw', $tmp) or die "cannot write $tmp: $!";
    print {$fh} $J->encode($payload);
    close $fh;
    my $outp = "$tmp.out";
    my $errp = "$tmp.err";
    my $rc = system(qq{bash "$GUARD" < "$tmp" > "$outp" 2> "$errp"});
    my $out = slurp_raw($outp);
    my $err = slurp_raw($errp);
    unlink $tmp, $outp, $errp;
    return ($rc >> 8, (defined $out ? $out : ''), (defined $err ? $err : ''));
}

sub ev {
    my ($tool, $path) = @_;
    my $key = $tool eq 'NotebookEdit' ? 'notebook_path' : 'file_path';
    return { hook_event_name => 'PreToolUse', tool_name => $tool, tool_input => { $key => $path } };
}

# run_pl($script, @args) -> { rc, out, err } -- a real perl subprocess.
sub run_pl {
    my ($pl, @args) = @_;
    my (undef, $outpath) = tempfile('alm-XXXXXX', TMPDIR => 1);
    my (undef, $errpath) = tempfile('alm-XXXXXX', TMPDIR => 1);
    my $argstr = join(' ', map { qq{"$_"} } @args);
    system(qq{perl "$pl" $argstr > "$outpath" 2> "$errpath"});
    my $rc  = $? >> 8;
    my $out = slurp_text($outpath);
    my $err = slurp_text($errpath);
    unlink $outpath, $errpath;
    return { rc => $rc, out => (defined $out ? $out : ''), err => (defined $err ? $err : '') };
}

# bugrun($home, @args) -> ($rc, $combined_output) -- almanac-bug.pl under a
# tempdir ALMANAC_HOME, combined stdout+stderr (house convention, matches
# bug-state-machine.t's own `run`).
sub bugrun {
    my ($home, @args) = @_;
    my $argstr = join(' ', map { qq{"$_"} } @args);
    my $cmd = qq{ALMANAC_HOME="$home" perl "$BUG" $argstr 2>&1};
    my $out = `$cmd`;
    return ($? >> 8, (defined $out ? $out : ''));
}
sub bugrun_verify { my ($home, @args) = @_; return bugrun($home, 'verify', @args) }

sub median {
    my @s = sort { $a <=> $b } @_;
    my $n = scalar @s;
    return undef unless $n;
    return $n % 2 ? $s[$n >> 1] : ($s[$n / 2 - 1] + $s[$n / 2]) / 2;
}
sub p90 {
    my @s = sort { $a <=> $b } @_;
    return undef unless @s;
    my $idx = int(0.9 * (scalar(@s) - 1));
    return $s[$idx];
}

sub snapshot_tree {
    my ($dir) = @_;
    my %snap;
    return \%snap unless -d $dir;
    my @stack = ($dir);
    while (@stack) {
        my $d = pop @stack;
        opendir(my $dh, $d) or next;
        for my $e (readdir($dh)) {
            next if $e eq '.' || $e eq '..';
            my $full = "$d/$e";
            if (-d $full) { push @stack, $full }
            else {
                my @st = stat($full);
                $snap{$full} = defined($st[7]) ? "$st[7]:$st[9]" : 'unstattable';
            }
        }
        closedir $dh;
    }
    return \%snap;
}

# =============================================================================
# AC18 (isolation) -- snapshot the REAL stores now, before anything else runs.
# The real HOME is taken from the test process HERE, before any override.
# =============================================================================
my $REAL_HOME = $ENV{HOME} // $ENV{USERPROFILE} // '';
(my $REPO = "$Bin/../../../..") =~ s{\\}{/}g;
my @SNAP_DIRS = (
    "$REPO/.ccpraxis-local-data/almanac",
    "$REAL_HOME/.claude/claude-code-vault/almanac",
    "$REAL_HOME/.ccpraxis-local-data/almanac",
);
my @SNAP_BEFORE = map { snapshot_tree($_) } @SNAP_DIRS;

my $SURFACE = eval { Almanac::Store::surface() };
$SURFACE = 'host' unless defined $SURFACE;

# =============================================================================
# AC1 (DC1, DC2) -- every known/unknown type, every sidecar shape, every tool.
# =============================================================================
my %SCRIPT_FOR = (
    todo => 'almanac-todo.pl', note => 'almanac-note.pl', task => 'almanac-task.pl',
    'task-focus' => 'almanac-task.pl', decision => 'almanac-decision.pl',
);
sub script_for { my ($t) = @_; return $SCRIPT_FOR{$t} // "almanac-$t.pl" }

my @PROJECT_TYPES = qw(todo note task task-focus decision zzz-future);
my @GLOBAL_TYPES  = qw(todo note zzz-future);

for my $shape (
    ['project', '/c/Development/Someproject/.ccpraxis-local-data/almanac', \@PROJECT_TYPES],
    ['global',  '/c/Users/tester/.claude/claude-code-vault/almanac',        \@GLOBAL_TYPES],
) {
    my ($label, $base, $types) = @$shape;
    for my $type (@$types) {
        my $id   = "rec-$type";
        my $path = "$base/$type/$id.md";
        for my $tool (qw(Edit Write MultiEdit NotebookEdit)) {
            my ($rc, $out, $err) = fire(ev($tool, $path));
            is($rc, 2, "AC1 [$label/$type/$tool]: rc is 2");
            is($out, '', "AC1 [$label/$type/$tool]: stdout is empty");
            like($err, qr/BLOCKED/, "AC1 [$label/$type/$tool]: stderr matches /BLOCKED/");
            my $script = script_for($type);
            like($err, qr/\Q$script\E/, "AC1 [$label/$type/$tool]: stderr names $script");
            like($err, qr/\Q$id\E/, "AC1 [$label/$type/$tool]: stderr contains the id");
        }
    }
}

# =============================================================================
# AC2 (DC2) -- sidecars, journals, temp files, and a file directly under the
# almanac root.
# =============================================================================
{
    my $base = '/c/Development/Someproject/.ccpraxis-local-data/almanac';
    my @sidecars = (
        "$base/todo/rec1.md.lock",
        "$base/todo/rec1.md.lock.holder",
        "$base/todo/rec1.md.seal",
        "$base/todo/.store.lock",
        "$base/todo/.reorder-journal.json",
        "$base/todo/rec1.md.tmp.1-abcd",
        "$base/x.md",
    );
    for my $p (@sidecars) {
        my ($rc, $out, $err) = fire(ev('Edit', $p));
        is($rc, 2, "AC2: Edit on $p is denied");
        like($err, qr/BLOCKED/, "AC2: Edit on $p names BLOCKED");
    }
}

# =============================================================================
# AC3 (DC2) -- case, backslashes, `..` segments, relative paths, non-ASCII.
# =============================================================================
{
    my @cases = (
        '.CCPRAXIS-LOCAL-DATA/Almanac/Todo/x.md',
        'C:\Development\P\.ccpraxis-local-data\almanac\note\x.md',
        '/c/P/.ccpraxis-local-data/x/../almanac/task/x.md',
        '.ccpraxis-local-data/almanac/todo/x.md',
        '/workspace/.ccpraxis-local-data/almanac/decision/x.md',
    );
    for my $p (@cases) {
        my ($rc) = fire(ev('Edit', $p));
        is($rc, 2, "AC3: Edit on '$p' is denied");
    }

    my $odd_name = "Andr\x{e9}";
    my $odd_path = "/c/Users/$odd_name/P/.ccpraxis-local-data/almanac/note/x.md";
    my ($rc, $out, $err) = fire(ev('Edit', $odd_path));
    is($rc, 2, 'AC3: the non-ASCII path is denied');
    my $expect_bytes = Encode::encode('UTF-8', $odd_path);
    ok(index($err, $expect_bytes) >= 0, "AC3: stderr contains the path's UTF-8 bytes unchanged")
        or diag('stderr (hex): ' . unpack('H*', $err) . "\nexpected substring (hex): " . unpack('H*', $expect_bytes));
}

# =============================================================================
# AC4 (DC1, no over-reach) -- every B4 path is allowed, including lookalikes
# and a store path that appears only inside content.
# =============================================================================
{
    my @b4 = (
        '.ccpraxis-local-data/almanac-old/x.md',
        'src/almanac/todo/x.md',
        '.ccpraxis-local-data/notes/x.md',
        '/c/Users/tester/.claude/claude-code-vault/notes/x.md',
        '/c/Users/tester/.claude/almanac-state/chart-reminder/sess1.t/x.json',
        '/c/Users/tester/.claude/almanac-notes.md',
        '/c/Development/ccpraxis/plugins/almanac/scripts/almanac-bug.pl',
    );
    for my $p (@b4) {
        for my $tool (qw(Write Edit)) {
            my ($rc, $out, $err) = fire(ev($tool, $p));
            is($rc, 0, "AC4: $tool on $p is allowed");
            is($out, '', "AC4: $tool on $p -- stdout empty");
        }
    }

    my ($rc2, $out2) = fire({
        hook_event_name => 'PreToolUse', tool_name => 'Write',
        tool_input => { file_path => '/c/P/src/x.md', content => '/c/P/.ccpraxis-local-data/almanac/todo/a.md' },
    });
    is($rc2, 0, 'AC4: a store path appearing only inside content is allowed');
    is($out2, '', 'AC4: ...with empty stdout');
}

# =============================================================================
# AC5 (DC3) -- reading is untouched.
# =============================================================================
{
    my $p = '/c/Development/Someproject/.ccpraxis-local-data/almanac/todo/x.md';
    for my $tool (qw(Read Grep Glob Bash)) {
        my ($key, $val) = $tool eq 'Bash' ? ('command', "cat $p") : ('file_path', $p);
        my ($rc, $out) = fire({ hook_event_name => 'PreToolUse', tool_name => $tool, tool_input => { $key => $val } });
        is($rc, 0, "AC5: $tool on a store path is allowed");
        is($out, '', "AC5: $tool -- stdout empty");
    }
}

# =============================================================================
# AC6 (DC4) -- fail-open: empty stdin, non-JSON, truncated JSON, empty
# tool_input, and a broken perl (PERL5OPT) must never become a deny.
# =============================================================================
{
    my (undef, $tmp) = tempfile('alm-XXXXXX', TMPDIR => 1);
    open(my $fh, '>', $tmp) or die $!;
    close $fh;
    my $rc = system(qq{bash "$GUARD" < "$tmp" > /dev/null 2>/dev/null});
    is($rc >> 8, 0, 'AC6: empty stdin fails open');

    open($fh, '>', $tmp) or die $!;
    print {$fh} 'not json';
    close $fh;
    $rc = system(qq{bash "$GUARD" < "$tmp" > /dev/null 2>/dev/null});
    is($rc >> 8, 0, 'AC6: an unparseable payload fails open');

    open($fh, '>', $tmp) or die $!;
    print {$fh} '{"tool_name":"Ed';
    close $fh;
    $rc = system(qq{bash "$GUARD" < "$tmp" > /dev/null 2>/dev/null});
    is($rc >> 8, 0, 'AC6: truncated JSON fails open');
    unlink $tmp;

    my ($rc4) = fire({ hook_event_name => 'PreToolUse', tool_name => 'Edit', tool_input => {} });
    is($rc4, 0, 'AC6: Edit with an empty tool_input fails open');

    {
        local $ENV{PERL5OPT} = '-MNoSuchModuleZq9';
        my $storepath = '/c/Development/Someproject/.ccpraxis-local-data/almanac/todo/x.md';
        my ($rc5) = fire(ev('Edit', $storepath));
        is($rc5, 0, 'AC6: a store-path Edit with a perl that dies at startup (PERL5OPT) still fails open');
    }
}

# =============================================================================
# AC7 (DC4, DC6) -- bash -n succeeds; no cat/jq/perl token before nocasematch.
# =============================================================================
{
    my $rc = system(qq{bash -n "$GUARD"});
    is($rc >> 8, 0, 'AC7: bash -n on the guard exits 0');

    my @lines = read_all_lines($GUARD);
    my ($nc_idx) = grep { $lines[$_] =~ /nocasematch/ } 0 .. $#lines;
    ok(defined $nc_idx, 'AC7 fixture: a line containing "nocasematch" exists');
    if (defined $nc_idx) {
        my @before = @lines[0 .. $nc_idx - 1];
        my @bad;
        for my $i (0 .. $#before) {
            my $l = $before[$i];
            next if $l =~ /^\s*#/;
            push @bad, "line " . ($i + 1) . ": $l" if $l =~ /\$\(cat\b/ || $l =~ /\bjq\b/ || $l =~ /\bcat\b/ || $l =~ /\bperl\b/;
        }
        is(scalar(@bad), 0, 'AC7: no $(cat, jq, cat or perl token occurs before the nocasematch line')
            or diag(@bad);
    } else {
        fail('AC7: no $(cat, jq, cat or perl token occurs before the nocasematch line');
    }
}

# =============================================================================
# AC8 (DC6) -- timing: guard median under 50ms, or under 10ms over a
# contended baseline.
# =============================================================================
{
    my $ascii_1k = ('the quick brown fox jumped over the lazy dog. ' x 22);
    $ascii_1k = substr($ascii_1k, 0, 1024);
    my $payload = {
        hook_event_name => 'PreToolUse', tool_name => 'Edit',
        tool_input => { file_path => '/c/Development/Someproject/src/main.rs', old_string => $ascii_1k, new_string => $ascii_1k },
    };
    my (undef, $ptmp) = tempfile('alm-XXXXXX', TMPDIR => 1);
    open(my $pfh, '>:raw', $ptmp) or die $!;
    print {$pfh} $J->encode($payload);
    close $pfh;

    my (undef, $empty_sh) = tempfile('alm-empty-XXXXXX', TMPDIR => 1, SUFFIX => '.sh');
    open(my $efh, '>', $empty_sh) or die $!;
    print {$efh} "#!/usr/bin/env bash\nexit 0\n";
    close $efh;

    for (1 .. 5) {
        system(qq{bash "$GUARD" < "$ptmp" > /dev/null 2>/dev/null});
        system(qq{bash "$empty_sh" < "$ptmp" > /dev/null 2>/dev/null});
    }

    my (@g_times, @b_times);
    for (1 .. 100) {
        my $t0 = Time::HiRes::time();
        system(qq{bash "$GUARD" < "$ptmp" > /dev/null 2>/dev/null});
        push @g_times, (Time::HiRes::time() - $t0) * 1000;

        my $t1 = Time::HiRes::time();
        system(qq{bash "$empty_sh" < "$ptmp" > /dev/null 2>/dev/null});
        push @b_times, (Time::HiRes::time() - $t1) * 1000;
    }
    unlink $ptmp, $empty_sh;

    my $med_g = median(@g_times);
    my $med_b = median(@b_times);
    diag(sprintf('AC8: guard median=%.2fms p90=%.2fms; baseline median=%.2fms p90=%.2fms',
        $med_g, p90(@g_times), $med_b, p90(@b_times)));

    if ($med_b >= 40) {
        ok(($med_g - $med_b) < 10,
            sprintf('AC8: contended host (baseline median %.2fms >= 40ms) -- guard adds under 10ms over baseline', $med_b));
    } else {
        ok($med_g < 50, sprintf('AC8: guard median (%.2fms) is under 50ms', $med_g));
    }
}

# =============================================================================
# AC9 (DC6, DC4) -- a 1 MiB Write outside both roots is allowed in under 1s.
# =============================================================================
{
    my $big = 'x' x (1024 * 1024);
    my $payload = {
        hook_event_name => 'PreToolUse', tool_name => 'Write',
        tool_input => { file_path => '/c/P/src/big.md', content => $big },
    };
    my (undef, $tmp) = tempfile('alm-XXXXXX', TMPDIR => 1);
    open(my $fh, '>:raw', $tmp) or die $!;
    print {$fh} $J->encode($payload);
    close $fh;

    my $t0 = Time::HiRes::time();
    my $rc = system(qq{bash "$GUARD" < "$tmp" > /dev/null 2>/dev/null});
    my $elapsed_ms = (Time::HiRes::time() - $t0) * 1000;
    unlink $tmp;

    is($rc >> 8, 0, 'AC9: a 1 MiB Write outside both roots is allowed');
    ok($elapsed_ms < 1000, sprintf('AC9: completed in %.1fms (< 1000ms)', $elapsed_ms));
    diag(sprintf('AC9: elapsed %.1fms', $elapsed_ms));
}

# =============================================================================
# AC11 [S] (DC5) -- seal semantics: create/update leave a one-line seal; the
# ON_BEFORE_RENAME seam sees a two-line seal and OLD record bytes; delete
# removes the record and its seal, keeping .lock/.lock.holder.
# =============================================================================
{
    my $root11 = tempdir(CLEANUP => 1);
    $root11 =~ s{\\}{/}g;
    my $store11 = eval { Almanac::Store->open(scope => 'project', type => 'note', root => $root11) };
    ok(defined $store11, 'AC11 fixture: store opens') or diag("error: $@");

    my $rec = eval { $store11->create(id => 'ac11', fields => { t => '1' }, order => ['t']) } if defined $store11;
    ok(defined $rec, 'AC11 fixture: create() succeeds') or diag("error: $@");

    SKIP: {
        skip 'AC11: create() did not return a record, nothing to seal-check', 12 unless defined $rec;

        my $seal_path = "$rec->{path}.seal";
        ok(-f $seal_path, 'AC11/B7: create() leaves a .seal file');
        my @seal1 = read_all_lines($seal_path);
        is(scalar(@seal1), 1, 'AC11/B7: the seal has exactly one line after create()');
        (my $l1 = $seal1[0] // '') =~ s/\s+\z//;
        is($l1, sha256_hex(slurp_raw($rec->{path}) // ''), 'AC11/B7: the seal line equals sha256_hex of the record bytes');

        my $updated = eval { $store11->update('ac11', expect => $rec, set => { t => '2' }) };
        ok(defined $updated, 'AC11 fixture: update() succeeds') or diag("error: $@");
        my @seal2 = read_all_lines($seal_path);
        is(scalar(@seal2), 1, 'AC11/B7: the seal has exactly one line after update()');
        (my $l2 = $seal2[0] // '') =~ s/\s+\z//;
        is($l2, sha256_hex(slurp_raw($rec->{path}) // ''), 'AC11/B7: ...equal to the NEW record bytes');

        my ($seam_seal, $seam_record, $seam_fired);
        {
            local $Almanac::Store::ON_BEFORE_RENAME = sub {
                my ($path, $tmp, $verb) = @_;
                $seam_fired  = 1;
                $seam_seal   = slurp_raw("$path.seal");
                $seam_record = slurp_raw($path);
            };
            my $before_bytes = slurp_raw($rec->{path});
            my $updated2 = eval { $store11->update('ac11', expect => $updated, set => { t => '3' }) } if defined $updated;
            ok($seam_fired, 'AC11/B7 fixture: the ON_BEFORE_RENAME seam fired');
            ok(defined $updated2, 'AC11 fixture: the seam-observed update() itself completed') or diag("error: $@");
            my @seam_lines = defined($seam_seal) ? split(/\n/, $seam_seal) : ();
            is(scalar(@seam_lines), 2, 'AC11/B7: at the seam, the seal holds two lines (new, old)');
            is($seam_record, $before_bytes, 'AC11/B7: at the seam, the record file still holds the OLD bytes');

            my $deleted = eval { $store11->delete('ac11', expect => $updated2) } if defined $updated2;
            ok($deleted, 'AC11/B7 fixture: delete() succeeds') or diag("error: $@");
            ok(!-f $rec->{path}, 'AC11/B7: the record file is gone after delete()');
            ok(!-f $seal_path, 'AC11/B7: the .seal file is gone after delete()');
        }
    }
}

# =============================================================================
# AC12 [S] (DC5) -- check_seal()'s five states; record_files_in() ignores
# every sidecar.
# =============================================================================
{
    my $root12 = tempdir(CLEANUP => 1);
    $root12 =~ s{\\}{/}g;
    my $store12 = eval { Almanac::Store->open(scope => 'project', type => 'note', root => $root12) };
    my $rec = eval { $store12->create(id => 'ac12', fields => { t => '1' }, order => ['t']) } if defined $store12;
    ok(defined $rec, 'AC12 fixture: create() succeeds') or diag("error: $@");

    SKIP: {
        skip 'AC12: create() did not return a record', 6 unless defined $rec;

        my $r1 = eval { Almanac::Store::check_seal($rec->{path}) };
        is(ref($r1) eq 'HASH' ? $r1->{state} : undef, 'intact', 'AC12: check_seal() is intact for a record matching line 1')
            or diag("error: $@");

        my $cur_digest = sha256_hex(slurp_raw($rec->{path}));
        open(my $fh, '>', "$rec->{path}.seal") or die $!;
        print {$fh} (('0' x 64) . "\n" . $cur_digest . "\n");
        close $fh;
        my $r2 = eval { Almanac::Store::check_seal($rec->{path}) };
        is(ref($r2) eq 'HASH' ? $r2->{state} : undef, 'intact', 'AC12: check_seal() is intact for a record matching line 2');

        open($fh, '>', "$rec->{path}.seal") or die $!;
        print {$fh} (('a' x 64) . "\n");
        close $fh;
        my $r3 = eval { Almanac::Store::check_seal($rec->{path}) };
        is(ref($r3) eq 'HASH' ? $r3->{state} : undef, 'tampered', 'AC12: check_seal() is tampered when nothing matches');

        unlink "$rec->{path}.seal";
        my $r4 = eval { Almanac::Store::check_seal($rec->{path}) };
        is(ref($r4) eq 'HASH' ? $r4->{state} : undef, 'unsealed', 'AC12: check_seal() is unsealed with no seal file');

        open($fh, '>', "$rec->{path}.seal") or die $!;
        print {$fh} "xyz\n";
        close $fh;
        my $r5 = eval { Almanac::Store::check_seal($rec->{path}) };
        is(ref($r5) eq 'HASH' ? $r5->{state} : undef, 'bad_seal', 'AC12: check_seal() is bad_seal for a garbage seal');

        my $dir12 = $store12->dir;
        for my $extra (qw(.store.lock .store.lock.holder ac12.md.lock ac12.md.lock.holder ac12.md.tmp.1-abcd .reorder-journal.json)) {
            open(my $sf, '>', "$dir12/$extra") or die $!;
            print {$sf} "irrelevant\n";
            close $sf;
        }
        my @files = eval { Almanac::Store::record_files_in($dir12) };
        my @basenames = sort map { (split m{[/\\]})[-1] } @files;
        is_deeply(\@basenames, ['ac12.md'], 'AC12: record_files_in() returns only the .md record, ignoring every sidecar');
    }
}

# =============================================================================
# AC13 / AC14 (DC5, DC2) -- one real record per type (including an unknown
# type discovered by directory shape, not a type list); verify's counts;
# per-type tamper/restore; then one sanctioned mutation per type keeps verify
# green.
# =============================================================================
{
    my $home13 = tempdir(CLEANUP => 1);
    $home13 =~ s{\\}{/}g;
    my $proj13 = tempdir(CLEANUP => 1);
    $proj13 =~ s{\\}{/}g;

    my %created;

    my $r_todo = run_pl("$S/almanac-todo.pl", 'create', '--title', 'AC13 todo', '--root', $proj13);
    is($r_todo->{rc}, 0, 'AC13 fixture: project todo created') or diag($r_todo->{err});
    $created{todo} = { id => field0($r_todo->{out}, 'id') };

    my $r_note = run_pl("$S/almanac-note.pl", 'create', '--title', 'AC13 note', '--root', $proj13);
    is($r_note->{rc}, 0, 'AC13 fixture: project note created') or diag($r_note->{err});
    $created{note} = { id => field0($r_note->{out}, 'id') };

    my $r_task = run_pl("$S/almanac-task.pl", 'add', '--title', 'AC13 task', '--root', $proj13);
    is($r_task->{rc}, 0, 'AC13 fixture: project task created') or diag($r_task->{err});
    $created{task} = { id => field0($r_task->{out}, 'id') };

    my $sess13 = 'ac13-session';
    my $r_focus = run_pl("$S/almanac-task.pl", 'focus', '--root', $proj13, '--session', $sess13);
    is($r_focus->{rc}, 0, 'AC13 fixture: project task-focus created (via focus)') or diag($r_focus->{err});
    $created{'task-focus'} = { id => $sess13 };

    my $r_dec = run_pl("$S/almanac-decision.pl", 'file', '--title', 'AC13 decision?', '--root', $proj13);
    is($r_dec->{rc}, 0, 'AC13 fixture: project decision created') or diag($r_dec->{err});
    $created{decision} = { id => field0($r_dec->{out}, 'id') };

    SKIP: {
        skip 'AC13: global scope unavailable on a container surface', 2 if $SURFACE eq 'container';
        my $r_gtodo = run_pl("$S/almanac-todo.pl", 'create', '--title', 'AC13 global todo', '--global', '--home', $home13);
        is($r_gtodo->{rc}, 0, 'AC13 fixture: global todo created') or diag($r_gtodo->{err});
        $created{'global-todo'} = { id => field0($r_gtodo->{out}, 'id') };

        my $r_gnote = run_pl("$S/almanac-note.pl", 'create', '--title', 'AC13 global note', '--global', '--home', $home13);
        is($r_gnote->{rc}, 0, 'AC13 fixture: global note created') or diag($r_gnote->{err});
        $created{'global-note'} = { id => field0($r_gnote->{out}, 'id') };
    }

    my $store_zzz = eval { Almanac::Store->open(scope => 'project', type => 'zzz-future', root => $proj13) };
    ok(defined $store_zzz, 'AC13 fixture: an UNKNOWN type (zzz-future) store opens by directory shape alone') or diag("error: $@");
    my $rec_zzz = eval { $store_zzz->create(id => 'ac13-zzz', fields => { t => '1' }, order => ['t']) } if defined $store_zzz;
    ok(defined $rec_zzz, 'AC13 fixture: zzz-future record created') or diag("error: $@");
    $created{'zzz-future'} = { id => 'ac13-zzz' } if defined $rec_zzz;

    my $expected_k = scalar(keys %created);

    my ($rc_v0, $out_v0) = bugrun_verify($home13, '--project', $proj13);
    is($rc_v0, 0, 'AC13: verify --project exits 0 before any tamper') or diag($out_v0);
    like($out_v0, qr/checked 0 report\(s\)/, 'AC13: prints "checked 0 report(s)"') or diag($out_v0);
    like($out_v0, qr/checked \Q$expected_k\E almanac record\(s\)/,
        "AC13: prints \"checked $expected_k almanac record(s)\"") or diag($out_v0);

    for my $type (sort keys %created) {
        my $id = $created{$type}{id};
        next unless defined $id;
        my ($scope_dir, $tpart) = $type =~ /^global-(.+)$/
            ? ("$home13/.claude/claude-code-vault/almanac", $1)
            : ("$proj13/.ccpraxis-local-data/almanac", $type);
        my $path = "$scope_dir/$tpart/$id.md";
        unless (ok(-f $path, "AC13 fixture: [$type] record file exists at the expected path ($path)")) {
            next;
        }
        my $before = slurp_raw($path);
        open(my $fh, '>>:raw', $path) or die $!;
        print {$fh} 'x';
        close $fh;

        my ($rc_t, $out_t) = bugrun_verify($home13, '--project', $proj13);
        isnt($rc_t, 0, "AC13: [$type] verify exits nonzero after appending one byte");
        my @tampered_hits = ($out_t =~ /^\s*\Q$tpart\E\/\Q$id\E:\s*TAMPERED/mg);
        ok(scalar(@tampered_hits) >= 1, "AC13: [$type] a TAMPERED line names $tpart/$id") or diag($out_t);
        my @all_tampered = ($out_t =~ /TAMPERED/g);
        is(scalar(@all_tampered), 1, "AC13: [$type] no OTHER TAMPERED line appears") or diag($out_t);

        open($fh, '>:raw', $path) or die $!;
        print {$fh} $before;
        close $fh;
        my ($rc_r) = bugrun_verify($home13, '--project', $proj13);
        is($rc_r, 0, "AC13: [$type] verify exits 0 again after restoring the original bytes");
    }

    # AC14 -- one sanctioned mutation per type, then verify is green.
    for my $m (
        ['todo',         'todo edit',       sub { run_pl("$S/almanac-todo.pl", 'edit', $created{todo}{id}, '--title', 'AC14 todo edited', '--root', $proj13) }],
        ['note',         'note edit',       sub { run_pl("$S/almanac-note.pl", 'edit', $created{note}{id}, '--title', 'AC14 note edited', '--root', $proj13) }],
        ['task',         'task status',     sub { run_pl("$S/almanac-task.pl", 'status', $created{task}{id}, 'doing', '--root', $proj13) }],
        ['task-focus',   'second focus',    sub { run_pl("$S/almanac-task.pl", 'focus', '--root', $proj13, '--session', $sess13) }],
        ['decision',     'decision answer', sub { run_pl("$S/almanac-decision.pl", 'answer', $created{decision}{id}, '--answer', 'go ahead', '--root', $proj13) }],
    ) {
        my ($needs_type, $label, $code) = @$m;
        next unless defined $created{$needs_type}{id};
        my $r = $code->();
        is($r->{rc}, 0, "AC14 fixture: $label mutation exits 0") or diag($r->{err});
    }
    if (defined $rec_zzz) {
        my $u = eval { $store_zzz->update('ac13-zzz', expect => $rec_zzz, set => { t => '2' }) };
        ok(defined $u, 'AC14 fixture: a Store update() for zzz-future succeeds') or diag("error: $@");
    }

    my ($rc_v14, $out_v14) = bugrun_verify($home13, '--project', $proj13);
    is($rc_v14, 0, 'AC14/DC5: verify exits 0 after one sanctioned mutation per type') or diag($out_v14);
}

# =============================================================================
# AC15 (DC5) -- unsealed is not a failure; an orphan seal is ignored; a
# garbage seal on a REAL record is a failure.
# =============================================================================
{
    my $home15 = tempdir(CLEANUP => 1);
    $home15 =~ s{\\}{/}g;
    my $root15 = tempdir(CLEANUP => 1);
    $root15 =~ s{\\}{/}g;
    my $store15 = eval { Almanac::Store->open(scope => 'project', type => 'todo', root => $root15) };
    my $rec = eval { $store15->create(id => 'ac15', fields => { title => 'x' }, order => ['title']) } if defined $store15;
    ok(defined $rec, 'AC15 fixture: create() succeeds') or diag("error: $@");

    SKIP: {
        skip 'AC15: create() did not return a record', 5 unless defined $rec;
        unlink "$rec->{path}.seal";

        my ($rc_v1, $out_v1) = bugrun_verify($home15, '--project', $root15);
        is($rc_v1, 0, 'AC15: verify exits 0 with one unsealed record');
        like($out_v1, qr/unsealed 1 almanac record\(s\)/, 'AC15: reports "unsealed 1 almanac record(s)"') or diag($out_v1);

        open(my $fh, '>', "$store15->{dir}/orphan.md.seal") or die $!;
        print {$fh} (('0' x 64) . "\n");
        close $fh;
        my ($rc_v2, $out_v2) = bugrun_verify($home15, '--project', $root15);
        is($rc_v2, 0, 'AC15: an orphan seal with no record does not fail verify');
        unlike($out_v2, qr/unsealed 2/, 'AC15: the orphan seal is NOT counted as an unsealed record');

        my $rec2 = eval { $store15->create(id => 'ac15b', fields => { title => 'y' }, order => ['title']) };
        ok(defined $rec2, 'AC15 fixture: a second record is created') or diag("error: $@");
        if (defined $rec2) {
            open($fh, '>', "$rec2->{path}.seal") or die $!;
            print {$fh} "garbage\n";
            close $fh;
            my ($rc_v3, $out_v3) = bugrun_verify($home15, '--project', $root15);
            isnt($rc_v3, 0, 'AC15: a garbage seal on a real record fails verify');
            like($out_v3, qr/BAD SEAL/, 'AC15: reports BAD SEAL') or diag($out_v3);
        } else {
            fail('AC15: a garbage seal on a real record fails verify');
            fail('AC15: reports BAD SEAL');
        }
    }
}

# =============================================================================
# AC16 (DC5) -- a second registered project's tampered todo is found via
# --project P; a tampered bug report and a tampered store record are both
# reported in one run.
# =============================================================================
{
    my $home16 = tempdir(CLEANUP => 1);
    $home16 =~ s{\\}{/}g;
    my $proj16 = tempdir(CLEANUP => 1);
    $proj16 =~ s{\\}{/}g;
    my $p2 = tempdir(CLEANUP => 1);
    $p2 =~ s{\\}{/}g;

    my $reg = "$home16/.claude/claude-code-vault";
    File::Path::make_path($reg);
    open(my $rf, '>:raw', "$reg/.registry-local.json") or die $!;
    print {$rf} JSON::PP->new->canonical->encode({ version => 1, projects => { p2 => { path => $p2 } } });
    close $rf;

    my $rt = run_pl("$S/almanac-todo.pl", 'create', '--title', 'AC16 p2 todo', '--root', $p2);
    is($rt->{rc}, 0, 'AC16 fixture: a todo exists in the second (registry-discovered) project') or diag($rt->{err});
    my $tid   = field0($rt->{out}, 'id');
    my $tpath = "$p2/.ccpraxis-local-data/almanac/todo/$tid.md";
    ok(-f $tpath, 'AC16 fixture: the P2 todo record file exists');
    open(my $fh, '>>:raw', $tpath) or die $!;
    print {$fh} 'x';
    close $fh;

    my ($rc_f, $out_f) = bugrun($home16, 'file', '--project', $proj16, '--title', 'AC16 report', '--body', 'b');
    is($rc_f, 0, 'AC16 fixture: a bug report exists in project P') or diag($out_f);
    chomp(my $rpath = $out_f);
    my ($rid) = $rpath =~ m{/([^/]+)\.md$};
    bugrun($home16, 'set-status', $rid, '--project', $proj16, '--to', 'declined');
    open($fh, '>>:raw', $rpath) or die $!;
    print {$fh} 'TAMPERED-BYTES';
    close $fh;

    my ($rc_v, $out_v) = bugrun_verify($home16, '--project', $proj16);
    isnt($rc_v, 0, 'AC16: verify --project P exits nonzero with a tampered todo in P2 AND a tampered report in P');
    like($out_v, qr{\Qtodo/$tid\E:\s*TAMPERED}, 'AC16: names the tampered P2 todo') or diag($out_v);
    like($out_v, qr/\Q$rid\E/, 'AC16: also names the tampered bug report') or diag($out_v);
}

# =============================================================================
# AC17 (DC5) -- a record locked by another process for 8s gives UNVERIFIED and
# a bounded (< 6s) verify.
# =============================================================================
{
    my $home17 = tempdir(CLEANUP => 1);
    $home17 =~ s{\\}{/}g;
    my $root17 = tempdir(CLEANUP => 1);
    $root17 =~ s{\\}{/}g;
    my $workdir17 = tempdir(CLEANUP => 1);
    $workdir17 =~ s{\\}{/}g;

    my $store17 = eval { Almanac::Store->open(scope => 'project', type => 'todo', root => $root17) };
    my $rec = eval { $store17->create(id => 'ac17', fields => { title => 'x' }, order => ['title']) } if defined $store17;
    ok(defined $rec, 'AC17 fixture: create() succeeds') or diag("error: $@");

    SKIP: {
        skip 'AC17: create() did not return a record', 3 unless defined $rec;
        open(my $fh, '>>:raw', $rec->{path}) or die $!;
        print {$fh} 'x';
        close $fh;

        my $holder = "$workdir17/ac17-holder.pl";
        open(my $cf, '>', $holder) or die $!;
        print {$cf} <<'HOLDER';
#!/usr/bin/env perl
use strict;
use warnings;
my ($scripts_dir, $path, $sentinel) = @ARGV;
local @INC = ($scripts_dir, @INC);
require Almanac::Lock;
my ($lock, $err) = Almanac::Lock->acquire($path, verb => 'ac17-holder');
open(my $sf, '>', $sentinel) or die $!;
print {$sf} ($lock ? "OK\n" : "FAIL\n");
close $sf;
sleep(8);
$lock->release if $lock;
HOLDER
        close $cf;

        my $sentinel = "$workdir17/sentinel.txt";
        system(qq{perl "$holder" "$S" "$rec->{path}" "$sentinel" > "$workdir17/holder-log.txt" 2>&1 &});
        my $waited = 0;
        while (!-f $sentinel && $waited < 5) {
            Time::HiRes::sleep(0.1);
            $waited += 0.1;
        }
        ok(-f $sentinel, 'AC17 fixture: the holder child signalled it holds the lock')
            or diag('holder log: ' . (slurp_text("$workdir17/holder-log.txt") // '(none)'));

        my $t0 = Time::HiRes::time();
        my ($rc_v, $out_v) = bugrun_verify($home17, '--project', $root17);
        my $elapsed = Time::HiRes::time() - $t0;
        isnt($rc_v, 0, 'AC17: verify exits nonzero while the record is locked by another process');
        like($out_v, qr/UNVERIFIED/, 'AC17: reports UNVERIFIED for the locked record') or diag($out_v);
        ok($elapsed < 6, sprintf('AC17: verify finished within 6s (took %.2fs)', $elapsed));
    }
}

# =============================================================================
# Review defect M1 -- tab-IFS field collapse (bash's `read` with IFS set to a
# single whitespace character still collapses runs and strips empty fields),
# so an empty type/id can shift the id/path/type into each other's slot.
# Pin the exact lines a sidecar denial and a root-level-file denial must
# produce, not merely "the type/id appears somewhere in stderr".
# =============================================================================
{
    my $sidecar_path = '/c/Development/Someproject/.ccpraxis-local-data/almanac/todo/rec1.md.lock';
    my (undef, undef, $err) = fire(ev('Edit', $sidecar_path));
    my @lines = split /\n/, $err;
    ok((grep { $_ eq '  store type: todo' } @lines),
        'M1/sidecar: the type line reads exactly "  store type: todo"') or diag("stderr:\n$err");
    ok(!(grep { /^\s*record id:/ } @lines),
        'M1/sidecar: NO "record id:" line appears -- a sidecar has no id, and the type must never leak into it')
        or diag("stderr:\n$err");
    ok((grep { /^\s*use:\s+perl <ccpraxis>\/plugins\/almanac\/scripts\/almanac-todo\.pl\s+create \| edit \| complete \| reopen \| delete\s*$/ } @lines),
        'M1/sidecar: the use: line names almanac-todo.pl with its REAL verbs, not shifted by the missing id field')
        or diag("stderr:\n$err");

    my $rootfile_path = '/c/Development/Someproject/.ccpraxis-local-data/almanac/x.md';
    my (undef, undef, $err2) = fire(ev('Edit', $rootfile_path));
    my @lines2 = split /\n/, $err2;
    ok((grep { $_ eq '  store type: (none -- a file directly under the almanac root)' } @lines2),
        'M1/root-file: the type line is exactly the "(none -- ...)" text -- an empty type is not shifted away')
        or diag("stderr:\n$err2");
    ok((grep { $_ eq '  record id:  x' } @lines2),
        'M1/root-file: the id line is exactly "  record id:  x" -- the id landed in the id slot')
        or diag("stderr:\n$err2");
}

# =============================================================================
# Review defect S1 -- Win32 strips a trailing "." or " " from a path
# component before the OS ever sees it, so a payload path carrying one still
# resolves to the real store on disk and must be denied, even though it does
# not literally contain the store's path substring.
# =============================================================================
{
    my @s1_cases = (
        'C:\Development\P\.ccpraxis-local-data.\almanac \todo\x.md',
        '/c/P/.ccpraxis-local-data./almanac/todo/x.md',
        '/c/P/.ccpraxis-local-data/almanac /todo/x.md',
    );
    for my $p (@s1_cases) {
        my ($rc) = fire(ev('Edit', $p));
        is($rc, 2, "S1: a trailing dot/space path segment still denies -- '$p'");
    }
}

# =============================================================================
# Review defect S2 -- an 8.3 short-name segment (e.g. CCPRAX~1 for
# .ccpraxis-local-data) resolves to the same real directory on this volume
# and must be denied, matched textually (no filesystem resolution required).
# =============================================================================
{
    my @s2_cases = (
        'C:\P\CCPRAX~1\almanac\todo\x.md',
        '/c/P/CCPRAX~1/almanac/todo/x.md',
    );
    for my $p (@s2_cases) {
        my ($rc) = fire(ev('Edit', $p));
        is($rc, 2, "S2: an 8.3 short-name segment still denies -- '$p'");
    }
}

# =============================================================================
# Review defect S3 -- a relative file_path must be resolved against the
# payload's own `cwd` before classification, not only matched when it happens
# to already contain the literal store substring.
# =============================================================================
{
    my ($rc1) = fire({
        hook_event_name => 'PreToolUse', tool_name => 'Edit',
        tool_input => { file_path => 'todo/x.md' }, cwd => '/c/P/.ccpraxis-local-data/almanac',
    });
    is($rc1, 2, 'S3: a relative path resolved against a cwd already inside the almanac dir is denied');

    my ($rc2) = fire({
        hook_event_name => 'PreToolUse', tool_name => 'Edit',
        tool_input => { file_path => '../almanac/todo/x.md' }, cwd => '/c/P/.ccpraxis-local-data/notes',
    });
    is($rc2, 2, 'S3: a relative ../ path resolved against cwd reaches the almanac dir and is denied');
}

# =============================================================================
# Review defect S4 -- verify lists records first and checks them later; a
# record that vanishes in between must not report UNREADABLE or fail the run
# (the same false-positive class the locked tampered re-check already
# removes). Reproduced deterministically: several large preceding records
# make the per-record loop take measurably longer than a short background
# delete, which targets only the LAST-sorted (and therefore last-checked)
# record.
# =============================================================================
{
    my $home_s4    = tempdir(CLEANUP => 1); $home_s4    =~ s{\\}{/}g;
    my $root_s4    = tempdir(CLEANUP => 1); $root_s4    =~ s{\\}{/}g;
    my $workdir_s4 = tempdir(CLEANUP => 1); $workdir_s4 =~ s{\\}{/}g;
    my $store_s4 = eval { Almanac::Store->open(scope => 'project', type => 'note', root => $root_s4) };
    ok(defined $store_s4, 'S4 fixture: store opens') or diag("error: $@");

    SKIP: {
        skip 'S4: store did not open', 3 unless defined $store_s4;
        my $big = ('y' x (12 * 1024 * 1024));
        for my $i (1 .. 12) {
            my $r = eval { $store_s4->create(id => sprintf('aaa-slow-%02d', $i), fields => { t => '1' }, order => ['t'], body => $big) };
            ok(defined $r, "S4 fixture: slow preceding record $i created") or diag("error: $@");
        }
        my $target = eval { $store_s4->create(id => 'zzz-target', fields => { t => '1' }, order => ['t']) };
        ok(defined $target, 'S4 fixture: the target record (sorts and checks last) is created') or diag("error: $@");

        my $deleter = "$workdir_s4/s4-deleter.pl";
        open(my $df, '>', $deleter) or die $!;
        print {$df} <<'DELETER';
#!/usr/bin/env perl
use strict;
use warnings;
use Time::HiRes qw(sleep);
my ($path, $sealpath) = @ARGV;
sleep(0.1);
unlink $path;
unlink $sealpath;
DELETER
        close $df;
        system(qq{perl "$deleter" "$target->{path}" "$target->{path}.seal" > "$workdir_s4/deleter-log.txt" 2>&1 &});

        my ($rc_v, $out_v) = bugrun_verify($home_s4, '--project', $root_s4);
        is($rc_v, 0, 'S4: verify does not fail when a record vanishes between listing and its check '
                    . '(a simulated concurrent delete)') or diag($out_v);
        unlike($out_v, qr/UNREADABLE/, 'S4: no UNREADABLE line is reported for the vanished record') or diag($out_v);

        # Non-vacuity: confirm the deleter genuinely ran (a bounded poll, since
        # bugrun_verify's own return does not guarantee the background deleter's
        # 0.1s sleep has already elapsed) -- otherwise the two assertions above
        # would pass trivially because the record never vanished at all.
        my $gone = 0;
        for (1 .. 40) {
            if (!-e $target->{path}) { $gone = 1; last }
            Time::HiRes::sleep(0.1);
        }
        ok($gone, 'S4 non-vacuity: the background deleter genuinely removed the target record '
                 . '(the race was actually exercised, not a no-op)')
            or diag('deleter log: ' . (slurp_text("$workdir_s4/deleter-log.txt") // '(none)'));
    }
}

# =============================================================================
# Review defect S5 -- `file` must exit exactly 2, never 255, when it cannot
# claim a report id. Forced deterministically (no ID_BASE guessing needed): a
# plain FILE sits where the bug-reports DIRECTORY belongs, so
# claim_report_path's own _mkpath fails on its very first, unconditional step.
# =============================================================================
{
    my $home_s5 = tempdir(CLEANUP => 1); $home_s5 =~ s{\\}{/}g;
    my $root_s5 = tempdir(CLEANUP => 1); $root_s5 =~ s{\\}{/}g;
    File::Path::make_path("$root_s5/.ccpraxis-local-data");
    open(my $fh, '>', "$root_s5/.ccpraxis-local-data/bug-reports") or die $!;
    print {$fh} "blocking file, not a directory\n";
    close $fh;

    my ($rc, $out) = bugrun($home_s5, 'file', '--project', $root_s5, '--title', 'S5 probe', '--body', 'b');
    is($rc, 2, 'S5: file exits exactly 2 when it cannot claim a report id (its directory is blocked by a file)')
        or diag("rc=$rc out=$out");
    like($out, qr/could not claim a report id/, 'S5: the message names the failure') or diag($out);
}

# =============================================================================
# Review defect S6 -- the seal must never bless the bytes it is REPLACING as
# a valid alternate digest when those bytes were already tampered before this
# write started. A crash right at the seam (before rename) must leave the
# seal unable to vouch for the pre-write (tampered) bytes.
# =============================================================================
{
    my $root_s6 = tempdir(CLEANUP => 1);
    $root_s6 =~ s{\\}{/}g;
    my $store_s6 = eval { Almanac::Store->open(scope => 'project', type => 'note', root => $root_s6) };
    my $rec1 = eval { $store_s6->create(id => 's6', fields => { t => '1' }, order => ['t']) } if defined $store_s6;
    ok(defined $rec1, 'S6 fixture: create() succeeds') or diag("error: $@");

    SKIP: {
        skip 'S6: create() did not return a record', 5 unless defined $rec1;

        open(my $fh, '>>:raw', $rec1->{path}) or die $!;
        print {$fh} 'TAMPER-BYTES';
        close $fh;
        my $tampered_bytes  = slurp_raw($rec1->{path});
        my $tampered_digest = sha256_hex($tampered_bytes);

        my $pre = eval { Almanac::Store::check_seal($rec1->{path}) };
        is(ref($pre) eq 'HASH' ? $pre->{state} : undef, 'tampered', 'S6 fixture: the record reads as tampered before the sanctioned write');

        my $tampered_read = eval { $store_s6->read('s6') };
        ok(defined $tampered_read, 'S6 fixture: read() after tampering succeeds (reading performs no integrity check)')
            or diag("error: $@");

        my $seam_seal_lines;
        {
            local $Almanac::Store::ON_BEFORE_RENAME = sub {
                my ($path, $tmp, $verb) = @_;
                my @lines = read_all_lines("$path.seal");
                $seam_seal_lines = [ map { my $l = $_; $l =~ s/\s+\z//; $l } @lines ];
            };
            my $updated = eval { $store_s6->update('s6', expect => $tampered_read, set => { t => '2' }) } if defined $tampered_read;
            ok(defined $updated, 'S6 fixture: the sanctioned update completes') or diag("error: $@");
        }
        ok(defined $seam_seal_lines, 'S6 fixture: the ON_BEFORE_RENAME seam captured the seal contents')
            or diag('nothing captured');

        my @bless_hits = grep { $_ eq $tampered_digest } @{ $seam_seal_lines // [] };
        is(scalar(@bless_hits), 0,
            'S6: the seal never blesses the pre-write (tampered) digest as a valid alternate -- a crash '
          . 'right here must not let those tampered bytes read back as intact')
            or diag('seam seal lines: ' . join(', ', @{ $seam_seal_lines // [] }) . '; tampered digest: ' . $tampered_digest);
    }
}

# =============================================================================
# AC18 (isolation) -- the real stores are untouched by this whole file.
# =============================================================================
{
    my @after = map { snapshot_tree($_) } @SNAP_DIRS;
    for my $i (0 .. $#SNAP_DIRS) {
        is_deeply($after[$i], $SNAP_BEFORE[$i], "AC18: $SNAP_DIRS[$i] is unchanged by this suite");
    }
}

done_testing();
