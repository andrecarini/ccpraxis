#!/usr/bin/env perl
# platform: any
# The dashboard's [c] (launch a claude session in a NEW window) on macOS.
#
# On Windows [c] opens a Windows Terminal window running
# `claude-sandbox --session <project>`. On macOS it used to do the same --
# wt.exe and powershell.exe, neither of which exists there -- so [c] failed
# with the "Windows Terminal was not found" screen. macOS now writes a
# single-use 0700 .command file into the launcher's temp dir and runs
# `open -a Terminal <file>`: LaunchServices, not Apple Events, so no
# Automation permission and no TCC prompt.
#
# NEVER OPENS A WINDOW. The pure pieces live in Dashboard.pm and are called
# directly; the launcher's two subs are sliced out of its source and run with
# the subprocess seam (_capture_out_err) replaced by a recorder, the house
# technique for launcher.pl, which is a script and is never require'd.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir tempfile);
use Dashboard ();

# ---------------------------------------------------------------------------
# Dashboard::spawn_argv('terminal') and sh_quote
# ---------------------------------------------------------------------------
is_deeply(Dashboard::spawn_argv('terminal', { file => '/t/x.command' }), ['open', '-a', 'Terminal', '/t/x.command'],
    'spawn_argv(terminal): open -a Terminal <file>');
ok(!defined Dashboard::spawn_argv('terminal', {}), 'spawn_argv(terminal) with no file -> undef (nothing to open)');
is_deeply(Dashboard::spawn_argv('wt', { cmd => ['a'] }), ['wt.exe', '-w', 'new', 'a'],
    'spawn_argv(wt) is unchanged');
is(Dashboard::sh_quote("it's a dir"), q{'it'\''s a dir'}, 'sh_quote closes, escapes and reopens a single quote');

# ---------------------------------------------------------------------------
# terminal_command_script: run the generated script for real under bash
# (macOS /bin/bash is 3.2), with a harmless command in place of the connector.
# ---------------------------------------------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $proj = "$root/it's a project";
    mkdir $proj or die "mkdir: $!";
    my $out  = "$root/out";
    my $script = Dashboard::terminal_command_script({
        cmd => ['/bin/sh', '-c', 'printf "%s|%s|%s" "$PWD" "$CCPRAXIS_CONTAINER_CLI" "$1" > "$2"', 'sh', "arg 'q' \$HOME", $out],
        cwd => $proj,
        env => { CCPRAXIS_CONTAINER_CLI => 'podman', 'not ok' => 'skipped', EMPTY => undef },
    });
    like($script, qr/\A#!\/bin\/bash\n/, 'script: bash shebang');
    like($script, qr/^rm -f -- "\$0"$/m, 'script: removes itself first');
    unlike($script, qr/not ok/, 'script: an env name that is not a shell identifier is not written');
    my $file = "$root/s.command";
    open my $fh, '>', $file or die; print {$fh} $script; close $fh; chmod 0700, $file;
    my $rc = system('/bin/bash', $file);
    is($rc, 0, 'script: runs cleanly under /bin/bash');
    my $got = do { open my $f, '<', $out or die "out: $!"; local $/; <$f> };
    is($got, "$proj|podman|arg 'q' \$HOME",
        'script: starts in the project dir, carries the env, and passes every argument through verbatim');
    ok(!-e $file, 'script: the .command file is gone after it ran');
    ok(!defined Dashboard::terminal_command_script({ cmd => [] }), 'script: no command -> undef');
}

# ---------------------------------------------------------------------------
# launcher.pl: dispatch and the darwin spawn, with the subprocess recorded
# ---------------------------------------------------------------------------
my $LAUNCHER = "$Bin/../../scripts/launcher.pl";
open my $lfh, '<:raw', $LAUNCHER or BAIL_OUT("cannot read $LAUNCHER: $!");
my $SRC = do { local $/; <$lfh> };
close $lfh;
sub sub_text { my ($n) = @_; my ($t) = $SRC =~ /(\nsub\s+\Q$n\E\s*\{.*?\n\}\n)/s; return $t }

my $dispatch = sub_text('_spawn_session');
my $spawn    = sub_text('_spawn_session_terminal_app');
my $hint     = sub_text('_spawn_session_hint');
ok(defined $dispatch && defined $spawn && defined $hint, 'launcher.pl defines the three [c] subs');
like($dispatch // '', qr/return _spawn_session_terminal_app\(\) if \$\^O eq 'darwin';/,
    '_spawn_session sends darwin to Terminal.app before any wt.exe lookup');
like($dispatch // '', qr/return _spawn_session_hint\([^)]*\) unless \$WINDOWS_FAMILY;/,
    '...and any other non-Windows host to the by-hand hint');
{
    my $code = join "\n", grep { !/^\s*#/ } split /\n/, $SRC;
    unlike($code, qr/\bosascript\b/, 'launcher.pl never drives Terminal through osascript (no Apple Events / TCC prompt)');
}

SKIP: {
    skip 'could not slice the launcher subs', 9 unless defined $spawn && defined $hint;
    my $tmp = tempdir(CLEANUP => 1);
    our (@CALLS, @EVENTS, $NEXT_STATUS);
    my $code = q{
        package SpawnSlice;
        use strict; use warnings;
        use File::Temp ();
        my $SAMPLER_TMPDIR = $main::TMP;
        my $LAUNCHER_PL    = '/opt/ccpraxis/plugins/sandbox/scripts/launcher.pl';
        my $PROJECT_PATH   = '/Users/u/My Project';
        sub log_ev { push @main::EVENTS, [@_] }
        sub _trim_err { my ($s) = @_; $s =~ s/\s+/ /g; $s }
        sub _capture_out_err { push @main::CALLS, [@_]; return ($main::NEXT_STATUS, '', $main::NEXT_STATUS ? 'boom' : '') }
    } . $spawn . $hint . "\n1;\n";
    our $TMP = $tmp;
    no warnings 'once';
    *Term::ReadKey::ReadKey  = sub { 'x' } unless defined &Term::ReadKey::ReadKey;
    *Term::ReadKey::ReadMode = sub { 1 }   unless defined &Term::ReadKey::ReadMode;
    my $ok = eval $code;
    ok($ok, 'the sliced subs compile') or diag($@);
    skip 'slice did not compile', 8 unless $ok;

    # success: open -a Terminal is asked to open a 0700 .command in the temp dir
    $NEXT_STATUS = 0;
    my $r = SpawnSlice::_spawn_session_terminal_app();
    ok(!defined $r, 'success returns nothing (the dashboard does not need a repaint)');
    is(scalar(@CALLS), 1, 'exactly one subprocess: the open');
    my ($open, $dash_a, $app, $file) = @{ $CALLS[0] || [] };
    is_deeply([$open, $dash_a, $app], ['open', '-a', 'Terminal'], 'it is `open -a Terminal`');
    like($file // '', qr{\A\Q$tmp\E/claude-session-\w+\.command\z}, '...on a .command file in the launcher temp dir');
    is(sprintf('%04o', (stat $file)[2] & 07777), '0700', '...created 0700');
    my $text = do { open my $f, '<', $file or die; local $/; <$f> };
    like($text, qr{^exec '[^']*perl[^']*' '/opt/ccpraxis/plugins/sandbox/scripts/launcher\.pl' '--session' '/Users/u/My Project'$}m,
        '...which execs this checkout\'s launcher.pl --session <project>');

    # failure: the file is removed and the operator gets the by-hand command
    @CALLS = ();
    $NEXT_STATUS = 1 << 8;
    my ($efh, $epath) = tempfile(UNLINK => 1);
    open my $saved, '>&', \*STDERR or die;
    open STDERR, '>', $epath or die;
    open my $saved_out, '>&', \*STDOUT or die;
    open STDOUT, '>', File::Spec->devnull or die;
    $r = SpawnSlice::_spawn_session_terminal_app();
    open STDERR, '>&', $saved or die;
    open STDOUT, '>&', $saved_out or die;
    my $err = do { open my $f, '<', $epath or die; local $/; <$f> };
    my ($failed_file) = map { $_->[3] } @CALLS;
    is($r, 'redraw', 'a failed open falls back to the hint and asks for a repaint');
    ok(defined $failed_file && !-e $failed_file, '...the unused .command file is removed');
    like($err, qr/claude-sandbox --session '\/Users\/u\/My Project'/, '...and the hint names the exact command to run');
}

done_testing();
