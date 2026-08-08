#!/usr/bin/env perl
# =============================================================================
# t/03-beacon-behaviour.t -- oracle File B for package 09-beacon-adopts-tokens
# (blueprint unified-tui-design-system).
#
# Groups: AC-B (end-to-end behaviour, subprocess-driven), AC-P (the resume path,
#         pure), AC-D5 (a real missing-library launch does not die).
#
# TWO RUNS THAT MUST NEVER HAPPEN HERE, and the scaffolding that prevents them:
#
#   1. EXEC'ING THE OPERATOR'S REAL `claude`. NO CASE IN THIS FILE MAY SELECT A
#      RECORD WITH A VALID UUID (spec AC-B3). Every fixture record below carries
#      a deliberately INVALID session_id, so even a mis-typed stdin line lands on
#      claude-beacon.pl's pre-exec refusal instead of on a dispatch. Resume-argv
#      correctness is AC-P's job, and AC-P tests the PURE command constructor --
#      ps_encoded_command() -- never the exec.
#
#   2. RUNNING beacon.pl AGAINST THE OPERATOR'S REAL VAULT. Every subprocess gets
#      HOME and USERPROFILE pointed at a File::Temp tempdir holding a STUB
#      beacon.pl, exactly as t/01-list-sandbox-fallback.t already does.
#
# Written from the spec, against an implementation that does not exist yet.
# =============================================================================

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec ();
use File::Copy qw(copy);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Encode ();
use MIME::Base64 qw(decode_base64);
use JSON::PP ();
use POSIX qw(strftime);

my $SCRIPT = File::Spec->rel2abs(
    File::Spec->catfile($Bin, '..', '..', 'scripts', 'claude-beacon.pl'));
$SCRIPT =~ s{\\}{/}g;
ok(-f $SCRIPT, "claude-beacon.pl found at $SCRIPT") or BAIL_OUT('nothing to test');

my $ESC = chr(27);

# ---------------------------------------------------------------------------
# AC-B0 -- the harness.
# ---------------------------------------------------------------------------

sub t_ts {
    my ($secs_ago) = @_;
    return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time() - $secs_ago));
}

# Every session_id here is INVALID on purpose -- see the header. The first is
# literally 'not-a-uuid' because AC-B3 selects it.
sub t_fixture_records {
    return [
        { session_id => 'not-a-uuid', schema_version => 1, project_slug => 'alpha',
          project_slug => 'alpha', label => 'alpha work', summary => undef,
          scope => 'host', cwd => 'C:/w/alpha', git_root => undef,
          host_project_path => 'C:/w/alpha', last_active_at => t_ts(3600),
          created_at => t_ts(7200), tags => [] },
        { session_id => 'also-not-a-uuid', schema_version => 1, project_slug => 'bravo',
          project_slug => 'bravo', label => 'bravo work', summary => undef,
          scope => 'sandbox', cwd => '/project', git_root => undef,
          host_project_path => 'C:/w/bravo', last_active_at => t_ts(86400),
          created_at => t_ts(90000), tags => [] },
    ];
}

# t_make_home(%opts) -> $home -- a tempdir standing in for HOME, carrying a stub
# beacon.pl at the path claude-beacon.pl looks for it (spec AC-B0). With
# stub => 0 the tree is built WITHOUT beacon.pl, which is AC-B4's third case.
sub t_make_home {
    my (%opt) = @_;
    my $with_stub = exists $opt{stub} ? $opt{stub} : 1;

    my $home = tempdir(CLEANUP => 1);
    $home =~ s{\\}{/}g;

    my $scripts = "$home/.claude/ccpraxis/plugins/beacon/scripts";
    make_path($scripts) unless -d $scripts;

    my $fixture_path = "$home/fixture.json";
    {
        open my $fh, '>:raw', $fixture_path or die "cannot write fixture: $!";
        print $fh JSON::PP->new->canonical->utf8->encode(t_fixture_records());
        close $fh;
    }

    if ($with_stub) {
        my $log = "$home/argv.log";
        my $stub = <<"STUB";
#!/usr/bin/env perl
# STUB beacon.pl -- records its argv and answers `list` from a fixture file.
use strict;
use warnings;
open my \$lf, '>>', '$log' or die "stub: cannot log: \$!";
print \$lf join(' ', \@ARGV), "\\n";
close \$lf;
my \$cmd = \@ARGV ? \$ARGV[0] : '';
if (\$cmd eq 'list') {
    open my \$fh, '<:raw', '$fixture_path' or exit 1;
    local \$/;
    my \$json = <\$fh>;
    close \$fh;
    binmode STDOUT;
    print \$json;
    exit 0;
}
exit 0;
STUB
        open my $fh, '>:raw', "$scripts/beacon.pl" or die "cannot write stub: $!";
        print $fh $stub;
        close $fh;
    }

    return $home;
}

# t_run($home, \@args, $stdin) -> ($out, $err, $rc). IPC::Open3 with piped
# stdin/stdout/stderr, so -t STDIN and -t STDOUT are both false in the child and
# the non-TTY path runs. Both pipes are drained; the outputs here are a handful
# of lines, far below the pipe buffer.
sub t_run {
    my ($home, $args, $stdin, %opt) = @_;
    my $script = $opt{script} || $SCRIPT;
    local $ENV{HOME}        = $home;
    local $ENV{USERPROFILE} = $home;
    local $ENV{NO_COLOR}    = '1';

    my $err_fh = gensym;
    my ($in_fh, $out_fh);
    my $pid = open3($in_fh, $out_fh, $err_fh, $^X, $script, @$args);
    print {$in_fh} (defined $stdin ? $stdin : '');
    close $in_fh;
    my $out = do { local $/; <$out_fh> };
    close $out_fh;
    my $err = do { local $/; <$err_fh> };
    close $err_fh;
    waitpid($pid, 0);
    my $rc = $? >> 8;
    return (defined $out ? $out : '', defined $err ? $err : '', $rc);
}

# =============================================================================
# AC-B -- end-to-end behaviour (done criterion 2: existing behaviour unchanged).
# =============================================================================

my $B1_HOME;   # reused by AC-B5, which reads the argv.log AC-B1 produced

subtest 'AC-B1: the non-TTY listing works' => sub {
    $B1_HOME = t_make_home();
    my ($out, $err, $rc) = t_run($B1_HOME, ['--no-sync'], "q\n");

    is($rc, 0, 'AC-B1: q on the numbered prompt exits 0');
    ok(index($out, 'Beacons (') >= 0, 'AC-B1: stdout carries the "Beacons (N):" header')
        or diag("stdout was: $out\nstderr was: $err");
    for my $needle ('alpha', 'bravo', 'alpha work', 'bravo work', '[host]', '[sandbox]') {
        ok(index($out, $needle) >= 0, "AC-B1: the numbered list carries '$needle'");
    }
    ok(index($out, 'Select [1-') >= 0, 'AC-B1: the "Select [1-N] or q to quit: " prompt is printed');
};

subtest 'AC-B2: selection rejects out of range' => sub {
    my $home = t_make_home();

    my ($o1, $e1, $r1) = t_run($home, ['--no-sync'], "99\n");
    is($r1, 1, 'AC-B2: an out-of-range selection exits 1');
    ok(index($e1, 'Invalid selection.') >= 0,
        'AC-B2: an out-of-range selection reports "Invalid selection."')
        or diag("stderr was: $e1");

    my ($o2, $e2, $r2) = t_run($home, ['--no-sync'], "abc\n");
    is($r2, 1, 'AC-B2: a non-numeric selection exits 1');
    ok(index($e2, 'Invalid selection.') >= 0,
        'AC-B2: a non-numeric selection reports "Invalid selection."')
        or diag("stderr was: $e2");

    my ($o3, $e3, $r3) = t_run($home, ['--no-sync'], "\n");
    is($r3, 0, 'AC-B2: an empty selection exits 0');
    ok(index($e3, 'Invalid selection.') < 0,
        'AC-B2: an empty selection reports no error');
};

subtest 'AC-B3: resume is refused on a bad record, before any exec' => sub {
    # The fixture's first record carries session_id 'not-a-uuid' precisely so
    # that selecting it exercises the pre-exec refusal and NOT a dispatch.
    my $home = t_make_home();
    my ($out, $err, $rc) = t_run($home, ['--no-sync'], "1\n");
    is($rc, 1, 'AC-B3: selecting a record with a malformed session_id exits 1');
    ok(index($err, 'refusing to dispatch') >= 0,
        'AC-B3: the refusal names itself ("refusing to dispatch"), before any exec')
        or diag("stderr was: $err");
};

subtest 'AC-B4: argv, help and the missing-binary path' => sub {
    my $home = t_make_home();

    my ($h_out, $h_err, $h_rc) = t_run($home, ['--help'], '');
    is($h_rc, 0, 'AC-B4: --help exits 0');
    for my $needle ('Usage: claude-beacon', 'u                        unbeacon', 'q or esc') {
        ok(index($h_out, $needle) >= 0, "AC-B4: the help block carries '$needle'");
    }

    my ($b_out, $b_err, $b_rc) = t_run($home, ['--bogus'], '');
    is($b_rc, 1, 'AC-B4: an unknown argument exits 1');
    ok(index($b_err, 'unknown argument') >= 0,
        'AC-B4: an unknown argument reports "unknown argument"')
        or diag("stderr was: $b_err");

    my $bare = t_make_home(stub => 0);
    my ($m_out, $m_err, $m_rc) = t_run($bare, ['--no-sync'], "q\n");
    is($m_rc, 1, 'AC-B4: a missing beacon.pl exits 1');
    ok(index($m_err, 'cannot find beacon.pl at') >= 0,
        'AC-B4: the missing-binary message names the path it looked at')
        or diag("stderr was: $m_err");
    ok(index($m_err, 'enabledPlugins') >= 0,
        'AC-B4: the missing-binary message carries the installation hint');
};

subtest 'AC-B5: beacon.pl is invoked exactly as before' => sub {
    ok(defined $B1_HOME, 'AC-B5: AC-B1 ran and left a home to inspect')
        or return;

    my $log_path = "$B1_HOME/argv.log";
    ok(-f $log_path, 'AC-B5: the stub beacon.pl was actually invoked (argv.log exists)')
        or do {
            diag('AC-B5: no argv.log. Either beacon.pl was never spawned, or it was '
                 . 'resolved from somewhere other than '
                 . '$HOME/.claude/ccpraxis/plugins/beacon/scripts (spec AC-B0).');
            return;
        };

    my $log = do { open my $fh, '<:raw', $log_path or die $!; local $/; <$fh> };
    my @lines = grep { length } split /\n/, $log;

    ok((grep { $_ eq 'list --format json --scope host' } @lines) ? 1 : 0,
        'AC-B5: beacon.pl was invoked as `list --format json --scope host`, unchanged')
        or diag('argv.log held: ' . join(' | ', @lines));

    ok(!(grep { $_ eq 'sync-vault' } @lines) ? 1 : 0,
        'AC-B5: with --no-sync, sync-vault is NOT invoked');

    # A run WITHOUT --no-sync: sync-vault must precede the list.
    my $home2 = t_make_home();
    t_run($home2, [], "q\n");
    my $log2 = do {
        open my $fh, '<:raw', "$home2/argv.log" or return fail('AC-B5: no argv.log for the syncing run');
        local $/;
        <$fh>;
    };
    my @l2 = grep { length } split /\n/, $log2;
    my ($i_sync) = grep { $l2[$_] eq 'sync-vault' } 0 .. $#l2;
    my ($i_list) = grep { $l2[$_] eq 'list --format json --scope host' } 0 .. $#l2;
    ok(defined $i_sync && defined $i_list && $i_sync < $i_list,
        'AC-B5: without --no-sync, a sync-vault call precedes the list call')
        or diag('argv.log held: ' . join(' | ', @l2));

    # §2.6 rule 8: nothing the render path produced may reach the subprocess.
    my @tainted = grep {
        index($_, $ESC) >= 0 || index($_, '?') >= 0 || /[^\x20-\x7E]/
    } (@lines, @l2);
    is(scalar(@tainted), 0,
        'AC-B5: no logged argv carries an escape byte, a "?" substitution or any '
        . 'rendered decoration -- no rendered value reached a subprocess (§2.6 rule 8)'
        . (@tainted ? ' -- offenders: ' . join(' | ', @tainted) : ''));
};

subtest 'AC-B6: the pre-existing beacon suite is still present' => sub {
    my $old = File::Spec->catfile($Bin, '01-list-sandbox-fallback.t');
    ok(-f $old, 'AC-B6: t/01-list-sandbox-fallback.t still exists');
    diag('AC-B6: t/01 exercises beacon.pl, which this package does not touch. '
         . 'The real check is the validation run of §7, which runs it from disk.');
};

# =============================================================================
# AC-D5 -- a real missing-library launch does not die (done criterion 1's
# degrade path). Hosted here because it needs a subprocess.
# =============================================================================

subtest 'AC-D5: a real missing-library launch degrades rather than dies' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    $tmp =~ s{\\}{/}g;
    my $dest_dir = "$tmp/plugins/beacon/scripts";
    make_path($dest_dir) unless -d $dest_dir;

    # Deliberately do NOT create $tmp/plugins/sandbox, so the load block's -d
    # guard fails FOR REAL rather than by a flag flip.
    ok(!-d "$tmp/plugins/sandbox",
        'AC-D5: the copied tree has no plugins/sandbox -- the -d guard fails for real');

    my $dest = "$dest_dir/claude-beacon.pl";
    copy($SCRIPT, $dest) or BAIL_OUT("AC-D5: cannot copy claude-beacon.pl: $!");

    my $home = t_make_home();
    my ($out, $err, $rc) = t_run($home, ['--no-sync'], "q\n", script => $dest);

    is($rc, 0, 'AC-D5: with the shared library genuinely absent, the launcher exits 0')
        or diag("stderr was: $err");
    ok(index($out, 'Beacons (') >= 0,
        'AC-D5: the numbered list still prints with the shared library absent')
        or diag("stdout was: $out");
    ok(index($out, 'alpha') >= 0 && index($out, 'bravo') >= 0,
        'AC-D5: both fixture beacons are still listed');
    is(index($out, $ESC), -1,
        'AC-D5: the degraded output carries no ESC byte at all');
    is(index($err, 'Theme'), -1,
        'AC-D5: the failed load neither warns nor dies about Theme -- a warn on a '
        . "TUI's stderr paints over the frame (§1.3)")
        or diag("stderr was: $err");
};

# =============================================================================
# AC-P -- the resume path, PURE (done criterion 2). No exec, ever.
#
# In-process, so it needs the §2.9 entry-point guard for the same reason File A
# does: requiring an unguarded claude-beacon.pl would spawn beacon.pl against
# the operator's real vault and exit() out from under the harness.
# =============================================================================

my $RAW = do {
    open my $fh, '<:raw', $SCRIPT or BAIL_OUT("cannot read $SCRIPT: $!");
    local $/;
    <$fh>;
};
my $SRC = join "\n", map { /^\s*#/ ? '' : $_ } split /\n/, $RAW, -1;

my $HAS_GUARD = ($SRC =~ /^\s*main\s*\(\s*\)\s+unless\s+caller\s*;/m) ? 1 : 0;
my $LOADED    = 0;
my $LOAD_ERR  = '';
if ($HAS_GUARD) {
    $LOADED = eval { require $SCRIPT; 1 } ? 1 : 0;
    $LOAD_ERR = $@ if !$LOADED;
}

sub t_unavailable {
    my ($label, @subs) = @_;
    if (!$HAS_GUARD) {
        fail("$label -- claude-beacon.pl carries no `main() unless caller` "
             . "entry-point guard (spec §2.9), so it cannot be required in-process");
        return 1;
    }
    if (!$LOADED) {
        my $e = $LOAD_ERR;
        $e =~ s/\s+\z//;
        fail("$label -- require of claude-beacon.pl failed: $e");
        return 1;
    }
    no strict 'refs';
    my @missing = grep { !defined &{"main::$_"} } @subs;
    if (@missing) {
        fail("$label -- claude-beacon.pl defines no " . join(', ', map { "$_()" } @missing));
        return 1;
    }
    return 0;
}

subtest 'AC-P1: UUID validation' => sub {
    return if t_unavailable('AC-P1: valid_session_id()', 'valid_session_id');

    my $lc = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
    my $uc = uc $lc;

    for my $good ($lc, $uc) {
        my $r = eval { main::valid_session_id($good) };
        ok(!$@ && $r, "AC-P1: '$good' is accepted");
    }
    for my $bad ('', 'not-a-uuid', '3f2504e0-4f89-41d3-9a0c-0305e82c330',
                 "$lc\n", '3f2504e0-4f89-41d3-9a0c') {
        my $r = eval { main::valid_session_id($bad) };
        my $shown = $bad; $shown =~ s/\n/\\n/g;
        ok(!$@ && !$r, "AC-P1: '$shown' is rejected");
    }
    my $r = eval { main::valid_session_id(undef) };
    ok(!$@ && !$r, 'AC-P1: undef is rejected, and does not die');
};

subtest 'AC-P2: the PowerShell resume command is byte-identical to today\'s' => sub {
    return if t_unavailable('AC-P2: ps_encoded_command()', 'ps_encoded_command');

    my $cwd = "C:/Users/Andr\x{00E9}/work";
    my $sid = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
    my $b64 = main::ps_encoded_command($cwd, $sid);

    like($b64, qr{\A[A-Za-z0-9+/=]+\z},
        'AC-P2: the encoded command is pure base64 ASCII, so it survives the argv hop');

    my $cmd = Encode::decode('UTF-16LE', decode_base64($b64));
    is($cmd,
       "Set-Location -LiteralPath 'C:/Users/Andr\x{00E9}/work'; & claude --resume $sid",
       'AC-P2: the decoded UTF-16LE command round-trips a non-ASCII cwd unchanged');
};

subtest 'AC-P3: apostrophe escaping' => sub {
    return if t_unavailable('AC-P3: ps_encoded_command()', 'ps_encoded_command');

    my $sid = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
    my $cmd = Encode::decode('UTF-16LE',
                             decode_base64(main::ps_encoded_command("C:/Users/O'Brien/work", $sid)));
    ok(index($cmd, "O''Brien") >= 0,
        "AC-P3: an apostrophe in the cwd is doubled for PowerShell's single-quoted literal");
    my $quotes = () = $cmd =~ /'/g;
    is($quotes % 2, 0,
        'AC-P3: the command carries an even number of single quotes -- the literal closes');
};

subtest 'AC-P4: ps_encoded_command is total' => sub {
    return if t_unavailable('AC-P4: ps_encoded_command()', 'ps_encoded_command');

    for my $case ([undef, undef, 'undef, undef'], [{}, [], 'a hashref and an arrayref']) {
        my ($a, $b, $label) = @$case;
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        my $got = eval { main::ps_encoded_command($a, $b) };
        my $died = $@;
        ok(!$died, "AC-P4: ps_encoded_command($label) does not die"
            . ($died ? " -- died: $died" : ''));
        ok(defined $got && !ref($got), "AC-P4: ps_encoded_command($label) returns a string");
        is(scalar(@warnings), 0,
            "AC-P4: ps_encoded_command($label) does not warn"
            . (@warnings ? " -- warned: $warnings[0]" : ''));
    }
};

done_testing();
