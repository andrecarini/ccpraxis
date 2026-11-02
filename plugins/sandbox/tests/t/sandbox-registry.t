#!/usr/bin/env perl
# platform: any
# SandboxRegistry.pm: this machine's list of sandboxed projects. The launcher
# writes it (register), /steward:backup reads it (entries).
#
# WHY. The backup now compares each sandbox's settings.json with the sandbox
# preset, and nothing recorded where the sandboxes are. The list must survive
# a project being moved or renamed (remembered answers are keyed by the
# project id, not the path), must not let a COPY of a project inherit the
# original's id, must drop projects whose directory is gone, and must rewrite
# nothing on a launch that changes nothing.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use File::Copy qw(copy);
use JSON::PP;

use lib "$Bin/../../scripts";
require_ok('SandboxRegistry') or BAIL_OUT('SandboxRegistry.pm does not load');

my $root = tempdir(CLEANUP => 1);
my $reg  = SandboxRegistry::registry_path("$root/home/.claude");
is($reg, "$root/home/.claude/ccpraxis-sandbox-projects.json", 'the registry lives in ~/.claude, named ccpraxis-sandbox-projects.json');

sub project { my ($name) = @_; my $p = "$root/$name"; make_path("$p/.ccpraxis-local-data/claude-home/.launcher"); return $p }
sub reg     { my (%o) = @_; return SandboxRegistry::register(registry => $reg, launcher => 'claude-sandbox', fold_case => 0, %o) }
sub list    { my ($l, $err) = SandboxRegistry::entries(registry => $reg, @_); die $err if $err; return $l }
sub id_of   { my ($p) = @_; my $f = SandboxRegistry::id_file(SandboxRegistry::launcher_dir_for($p));
              open my $fh, '<', $f or return undef; my $l = <$fh>; close $fh; chomp $l; $l }
sub mtime   { (stat $_[0])[9] }

my ($l0, $e0) = SandboxRegistry::entries(registry => $reg);
ok(!$e0 && !@$l0, 'no registry file yet: an empty list, no error');

# ---- register a project ----
my $a = project('alpha');
my $r1 = reg(project_path => $a, container => 'claude-alpha-1234abcd', now => 100);
ok(!$r1->{error}, 'register: no error') or diag($r1->{error});
like($r1->{id}, qr/\A[0-9a-f]{16}\z/, 'register: a 16-hex project id is minted');
is(id_of($a), $r1->{id}, 'register: the id is kept in the project, in .launcher/sandbox-id');
ok($r1->{changed}, 'register: the registry was written');
my $l1 = list();
is(scalar(@$l1), 1, 'entries: one project');
is($l1->[0]{path}, $a, 'entries: its path');
is($l1->[0]{launcher}, 'claude-sandbox', 'entries: the launcher identity that registered it');
is($l1->[0]{container}, 'claude-alpha-1234abcd', 'entries: its container');

# ---- the same launch again rewrites nothing ----
my $m = mtime($reg);
utime 1, 1, $reg;
my $r2 = reg(project_path => $a, container => 'claude-alpha-1234abcd', now => 200);
is($r2->{id}, $r1->{id}, 'register again: same id');
ok(!$r2->{changed}, 'register again: nothing changed');
is(mtime($reg), 1, 'register again: the registry file was not rewritten');

# ---- moved / renamed: the id travels, the path follows ----
my $moved = "$root/alpha-renamed";
rename $a, $moved or die "rename: $!";
my $r3 = reg(project_path => $moved, now => 300);
is($r3->{id}, $r1->{id}, 'renamed project: keeps its id (remembered answers survive)');
ok(!$r3->{reminted}, 'renamed project: not treated as a copy');
my $l3 = list();
is(scalar(@$l3), 1, 'renamed project: still one entry');
is($l3->[0]{path}, $moved, 'renamed project: the entry follows the new path');

# ---- copied: the copy gets a fresh id ----
my $copy = project('alpha-copy');
copy(SandboxRegistry::id_file(SandboxRegistry::launcher_dir_for($moved)),
     SandboxRegistry::id_file(SandboxRegistry::launcher_dir_for($copy))) or die "copy: $!";
is(id_of($copy), $r1->{id}, 'fixture: the copy carries the original id');
my $r4 = reg(project_path => $copy, now => 400);
ok($r4->{reminted}, 'copied project: reminted');
isnt($r4->{id}, $r1->{id}, 'copied project: a different id from the original');
is(id_of($copy), $r4->{id}, 'copied project: its own id file is rewritten');
is(id_of($moved), $r1->{id}, 'copied project: the original keeps its id');
is(scalar(@{ list() }), 2, 'copied project: two entries');

# ---- .launcher deleted: the entry for the path gives the id back ----
remove_tree(SandboxRegistry::launcher_dir_for($copy));
make_path(SandboxRegistry::launcher_dir_for($copy));
my $r5 = reg(project_path => $copy, now => 500);
is($r5->{id}, $r4->{id}, '.launcher deleted: the project gets its registered id back');
is(id_of($copy), $r4->{id}, '.launcher deleted: and the id file is written again');

# ---- pruned when the directory is gone ----
remove_tree($moved);
my $b = project('beta');
my $r6 = reg(project_path => $b, now => 600);
is_deeply($r6->{pruned}, [ $r1->{id} ], 'a project whose directory is gone is pruned on the next registration');
is_deeply([ sort map { $_->{path} } @{ list() } ], [ sort($copy, $b) ], 'the list holds the remaining two');

# ---- launcher identity filter (a fork's sandboxes use another preset) ----
my $fork = project('forked');
SandboxRegistry::register(registry => $reg, launcher => 'some-fork', project_path => $fork, fold_case => 0, now => 700);
is(scalar(@{ list() }), 3, 'entries without a filter: every project');
is_deeply([ map { $_->{path} } @{ list(launcher => 'claude-sandbox') } ], [ sort($copy, $b) ],
    "entries for one launcher identity: only that launcher's projects");

# ---- case folding (Windows, macOS): two spellings, one directory ----
{
    is(SandboxRegistry::_path_key("/Users/Me/Proj/", 1), SandboxRegistry::_path_key("/users/me/proj", 1),
        'fold_case on: two spellings of a path are one key (a trailing slash too)');
    isnt(SandboxRegistry::_path_key("/Users/Me/Proj", 0), SandboxRegistry::_path_key("/users/me/proj", 0),
        'fold_case off (Linux): case matters');
    is(SandboxRegistry::_path_key('C:\\Users\\Me', 1), 'c:/users/me', 'backslashes are slashes');
}

# ---- two spellings of ONE directory are not a copy ----
# (On Windows and macOS that is a non-ASCII letter in another case, which a
# byte-wise lc does not fold; a symbolic link alias is the portable stand-in.)
SKIP: {
    skip 'no symbolic links on this host', 2 if $^O =~ /^(MSWin32|cygwin|msys)$/;
    my $real  = project('one-dir');
    my $alias = "$root/one-dir-alias";
    symlink($real, $alias) or skip "symlink failed: $!", 2;
    my $first  = reg(project_path => $real,  now => 830);
    my $second = reg(project_path => $alias, now => 840);
    is($second->{id}, $first->{id}, 'same directory, another spelling: same id');
    ok(!$second->{reminted}, '... not mistaken for a copy');
    unlink $alias;
}

# ---- a non-ASCII path (the Windows host's home is C:/Users/André) ----
{
    my $nb = project("Andr\xc3\xa9-proj");          # UTF-8 bytes, as the launcher has them
    my $r = reg(project_path => $nb, now => 850);
    ok(!$r->{error}, 'non-ASCII path: registered') or diag($r->{error});
    my ($e) = grep { $_->{id} eq $r->{id} } @{ list() };
    is($e->{path}, $nb, 'non-ASCII path: entries() hands back the same bytes');
    ok(-d $e->{path}, 'non-ASCII path: ... usable for file operations');
    open my $fh, '<:raw', $reg or die; my $raw = do { local $/; <$fh> }; close $fh;
    ok(index($raw, "Andr\xc3\xa9-proj") >= 0 && index($raw, "Andr\xc3\x83\xc2\xa9") < 0,
        'non-ASCII path: stored as UTF-8 text, encoded once');
    my $again = reg(project_path => $nb, now => 860);
    ok(!$again->{changed}, 'non-ASCII path: a second registration changes nothing');
}

# ---- a corrupt registry is set aside, not trusted ----
{
    open my $fh, '>', $reg or die; print {$fh} "{ nope"; close $fh;
    my $r8 = reg(project_path => $b, now => 900);
    ok(!$r8->{error}, 'corrupt registry: register still works');
    my @aside = glob("$reg.corrupt-*");
    is(scalar(@aside), 1, 'corrupt registry: the old file is kept aside');
    is_deeply([ map { $_->{path} } @{ list() } ], [ $b ], 'corrupt registry: rebuilt from this launch');
}

done_testing();
