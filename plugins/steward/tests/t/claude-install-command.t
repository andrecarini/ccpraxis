#!/usr/bin/env perl
# platform: any
# `ccpraxis binary install-command` (claude-binary-backup.pl): the one
# install command for the claude on PATH, chosen by the script.
#
# WHY. /steward:update's Step 7 listed every OS's installer command
# ("Windows native: powershell ... install.ps1", "macOS/Linux native: curl ...
# install.sh") plus npm and brew, and asked the agent to detect the install
# method and pick a line. Every host was handed every other host's command.
# The detection and the pick now happen here; the skill runs what this prints.
#
# HERMETIC: HOME, PATH and --binary point into a tempdir; CLAUDE_BINARY_OS
# (the script's test seam) picks the OS the command is chosen for. Nothing is
# installed or run -- the script only prints.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use Config;

my $SCRIPT = "$Bin/../../scripts/claude-binary-backup.pl";
my $SKILL  = "$Bin/../../skills/update/SKILL.md";
ok(-f $SCRIPT, 'claude-binary-backup.pl exists') or BAIL_OUT('script missing');

# PATH is overridden per run, so the perl to spawn must be an absolute path.
my $PERL = $^X =~ m{[\\/]} ? $^X : $Config{perlpath};
my $WINDOWS_HOST = $^O =~ /^(MSWin32|cygwin|msys)$/ ? 1 : 0;
my $T    = tempdir(CLEANUP => 1);
our $HOME = "$T/home";

sub touch_exe {
    my ($p) = @_;
    (my $d = $p) =~ s{/[^/]+\z}{};
    make_path($d);
    open my $fh, '>', $p or die "write $p: $!";
    print {$fh} "#!/bin/sh\necho '0.0.0 (Claude Code)'\n";
    close $fh;
    chmod 0755, $p;
}

# run(\%env, @args) -> ($exit, $json)
sub run {
    my ($env, @args) = @_;
    local $ENV{HOME} = $HOME;
    local $ENV{USERPROFILE} = $HOME;
    local $ENV{PATH} = exists $env->{PATH} ? $env->{PATH} : $ENV{PATH};
    local $ENV{CLAUDE_BINARY_OS} = $env->{os} if defined $env->{os};
    open my $fh, q{-|}, $PERL, $SCRIPT, 'install-command', @args or die "spawn: $!";
    local $/;
    my $out = <$fh> // '';
    close $fh;
    return ($? >> 8, (eval { decode_json($out) } // { raw => $out }));
}

# --- native ---------------------------------------------------------------
touch_exe("$HOME/.local/bin/claude");
my ($rc, $r) = run({ os => 'macos' }, '--version', '2.1.305', '--binary', "$HOME/.local/bin/claude");
is($rc, 0, 'native on macOS: exit 0') or diag(explain($r));
is($r->{method}, 'native', 'native on macOS: ~/.local/bin/claude is a native install');
is($r->{command}, 'curl -fsSL https://claude.ai/install.sh | bash -s 2.1.305',
    'native on macOS: the install.sh command, pinned');

($rc, $r) = run({ os => 'linux' }, '--version', '2.1.305', '--binary', "$HOME/.local/bin/claude");
is($r->{command}, 'curl -fsSL https://claude.ai/install.sh | bash -s 2.1.305', 'native on Linux: the same command');

touch_exe("$HOME/.local/bin/claude.exe");
($rc, $r) = run({ os => 'windows' }, '--version', '2.1.305', '--binary', "$HOME/.local/bin/claude.exe");
is($rc, 0, 'native on Windows: exit 0') or diag(explain($r));
is($r->{method}, 'native', 'native on Windows: ~/.local/bin/claude.exe is a native install');
is($r->{command}, q{powershell -Command "& ([scriptblock]::Create((irm https://claude.ai/install.ps1))) 2.1.305"},
    'native on Windows: the install.ps1 command, pinned');
unlike($r->{command}, qr/install\.sh/, 'native on Windows: never the POSIX installer');

SKIP: {
    skip 'symlinks: the macOS/Linux native layout', 2 if $WINDOWS_HOST;
    make_path("$HOME/.local/share/claude/versions", "$T/bin2");
    touch_exe("$HOME/.local/share/claude/versions/2.1.301");
    symlink("$HOME/.local/share/claude/versions/2.1.301", "$T/bin2/claude") or die "symlink: $!";
    ($rc, $r) = run({ os => 'macos', PATH => "$T/bin2" }, '--version', '2.1.305');
    is($r->{method}, 'native', 'native: found on PATH, resolved into ~/.local/share/claude/');
    is($r->{binary_path}, "$T/bin2/claude", 'native: binary_path is what PATH found');
}

# --- PATH search ------------------------------------------------------------
($rc, $r) = run({ os => ($WINDOWS_HOST ? 'windows' : 'macos'), PATH => "$HOME/.local/bin" }, '--version', '2.1.305');
is($r->{method}, 'native', 'PATH search: finds ~/.local/bin/claude without --binary') or diag(explain($r));

($rc, $r) = run({ os => 'macos', PATH => "$T/empty" }, '--version', '2.1.305');
is($rc, 1, 'no claude on PATH: exit 1');
is($r->{method}, 'unknown', 'no claude on PATH: method unknown');
ok(!defined $r->{command}, 'no claude on PATH: no command');
like($r->{note} // '', qr/no claude found on PATH/, 'no claude on PATH: the note says so');

# --- npm ------------------------------------------------------------------
touch_exe("$T/npm/lib/node_modules/\@anthropic-ai/claude-code/cli.js");
($rc, $r) = run({ os => 'macos' }, '--version', '2.1.305',
    '--binary', "$T/npm/lib/node_modules/\@anthropic-ai/claude-code/cli.js");
is($rc, 0, 'npm: exit 0');
is($r->{method}, 'npm', 'npm: a claude under node_modules is an npm install');
is($r->{command}, 'npm install -g @anthropic-ai/claude-code@2.1.305', 'npm: the npm command, pinned');

make_path("$T/AppData/npm/node_modules/\@anthropic-ai/claude-code");
touch_exe("$T/AppData/npm/claude.cmd");
($rc, $r) = run({ os => 'windows' }, '--version', '2.1.305', '--binary', "$T/AppData/npm/claude.cmd");
is($r->{method}, 'npm', 'npm on Windows: a claude.cmd shim beside node_modules/@anthropic-ai/claude-code');

SKIP: {
    skip 'symlinks: npm prefix ~/.local', 1 if $WINDOWS_HOST;
    make_path("$T/npmhome/.local/bin");
    touch_exe("$T/npmhome/.local/lib/node_modules/\@anthropic-ai/claude-code/cli.js");
    symlink("$T/npmhome/.local/lib/node_modules/\@anthropic-ai/claude-code/cli.js", "$T/npmhome/.local/bin/claude")
        or die "symlink: $!";
    local $HOME = "$T/npmhome";
    ($rc, $r) = run({ os => 'macos' }, '--version', '2.1.305', '--binary', "$T/npmhome/.local/bin/claude");
    is($r->{method}, 'npm', 'npm with prefix ~/.local: the shim at ~/.local/bin/claude is npm, not native');
}

# --- brew -----------------------------------------------------------------
touch_exe("$T/opt/homebrew/Caskroom/claude-code/2.1.290/claude");
($rc, $r) = run({ os => 'macos' }, '--version', '2.1.305',
    '--binary', "$T/opt/homebrew/Caskroom/claude-code/2.1.290/claude");
is($rc, 1, 'brew: exit 1 (no command)');
is($r->{method}, 'brew', 'brew: a claude under Caskroom is a Homebrew install');
ok(!defined $r->{command}, 'brew: no command, since Homebrew cannot pin a version');
like($r->{note} // '', qr/cannot be pinned/, 'brew: the note says why');

# --- unknown --------------------------------------------------------------
touch_exe("$T/elsewhere/claude");
($rc, $r) = run({ os => 'macos' }, '--version', '2.1.305', '--binary', "$T/elsewhere/claude");
is($rc, 1, 'unknown: exit 1');
is($r->{method}, 'unknown', 'unknown: a claude nowhere recognisable');
ok(!defined $r->{command}, 'unknown: no command');

# --- the version reaches a shell command, so only a version shape passes ----
for my $bad ('2.1', 'latest', '2.1.3; rm -rf ~', '2.1.3 && x', '$(id)') {
    ($rc, $r) = run({ os => 'macos' }, '--version', $bad, '--binary', "$HOME/.local/bin/claude");
    is($rc, 3, "version '$bad' is rejected with exit 3");
}
($rc, $r) = run({ os => 'macos' }, '--version', '2.2.0-beta.1', '--binary', "$HOME/.local/bin/claude");
is($rc, 0, 'a pre-release version shape is accepted');
($rc, $r) = run({ os => 'macos' }, '--binary', "$HOME/.local/bin/claude");
is($rc, 3, '--version is required');

# --- the skill runs the script instead of listing every OS's command --------
{
    open my $fh, '<:raw', $SKILL or BAIL_OUT("read $SKILL: $!");
    local $/;
    my $s = <$fh>;
    close $fh;
    like($s, qr/ccpraxis binary install-command --version <SELECTED>/, 'SKILL: Step 7 runs install-command');
    unlike($s, qr/install\.ps1|install\.sh/, 'SKILL: no per-OS installer command is listed');
    unlike($s, qr/Windows native|macOS\/Linux native/, 'SKILL: no "pick the line for your OS" list');
}

done_testing();
