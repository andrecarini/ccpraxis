#!/usr/bin/env perl
# platform: host
# promote.pl --keep-key: a settings.json unit the caller was asked about and
# answered "leave it" (/steward:backup's skip) stays exactly as ~/.claude has
# it for that run, even where promotion would otherwise update it (the live
# value is one the payload once had). Other units are promoted as usual.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempdir tempfile);
use JSON::PP;

my $PROMOTE = "$Bin/../../../../scripts/promote.pl";

sub write_bytes { my ($p, $c) = @_; make_path(dirname($p)); open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $c; close $fh; }
sub read_json   { my ($p) = @_; open my $fh, '<:raw', $p or die "$p: $!"; local $/; return decode_json(<$fh>); }

my $TMP = tempdir(CLEANUP => 1);
my %GENV = (GIT_CONFIG_GLOBAL => "$TMP/gitconfig", GIT_CONFIG_NOSYSTEM => '1', GIT_TERMINAL_PROMPT => '0',
            GIT_AUTHOR_NAME => 'K', GIT_AUTHOR_EMAIL => 'k@example.invalid',
            GIT_COMMITTER_NAME => 'K', GIT_COMMITTER_EMAIL => 'k@example.invalid');
write_bytes("$TMP/gitconfig", "[init]\n\tdefaultBranch = main\n");

sub git {
    my ($dir, @args) = @_;
    local @ENV{ keys %GENV } = values %GENV;
    system('git', '-c', 'core.autocrlf=false', '-C', $dir, @args) == 0 or die "git @args failed\n";
}

sub run {
    my (@args) = @_;
    local @ENV{ keys %GENV } = values %GENV;
    my ($efh, $ename) = tempfile(UNLINK => 1);
    close $efh;
    open(my $saved, '>&', \*STDERR) or die;
    open(STDERR, '>', $ename) or die;
    my $out = '';
    if (open(my $fh, '-|', $^X, $PROMOTE, @args)) { local $/; $out = <$fh> // ''; close $fh; }
    my $rc = $? >> 8;
    open(STDERR, '>&', $saved);
    return ($rc, $out);
}

# A dev clone whose payload moved from "old" to "new" values, a live install
# promoted at the old commit, and a ~/.claude/settings.json still holding the
# old values -- so promotion would update every one of them.
sub fixture {
    my ($n) = @_;
    my $base  = "$TMP/f$n";
    my $clone = "$base/clone";
    my $home  = "$base/home";
    make_path($clone, "$home/.claude");
    git($clone, 'init', '-q');
    write_bytes("$clone/global-config/settings.json",
        JSON::PP->new->canonical->encode({ a => 'old', b => 'old', env => { X => 'old', Y => 'old' } }) . "\n");
    git($clone, 'add', '-A');
    git($clone, 'commit', '-q', '-m', 'v1');
    {
        local @ENV{ keys %GENV } = values %GENV;
        system('git', 'clone', '-q', '--no-hardlinks', $clone, "$home/.claude/ccpraxis") == 0 or die "clone\n";
    }
    write_bytes("$clone/global-config/settings.json",
        JSON::PP->new->canonical->encode({ a => 'new', b => 'new', env => { X => 'new', Y => 'new' } }) . "\n");
    git($clone, 'commit', '-q', '-am', 'v2');
    write_bytes("$home/.claude/settings.json",
        JSON::PP->new->canonical->encode({ a => 'old', b => 'old', env => { X => 'old', Y => 'old' } }) . "\n");
    return ($clone, $home);
}

{
    my ($clone, $home) = fixture(1);
    my ($rc, $out) = run('--clone', $clone, '--home', $home);
    is($rc, 0, 'baseline: promote exits 0') or diag($out);
    my $s = read_json("$home/.claude/settings.json");
    is($s->{a}, 'new', 'baseline: without --keep-key the old value is updated (non-vacuity)');
}

{
    my ($clone, $home) = fixture(2);
    my ($rc, $out) = run('--clone', $clone, '--home', $home, '--keep-key', 'a', '--keep-key', 'env.X');
    is($rc, 0, 'keep: promote exits 0') or diag($out);
    my $s = read_json("$home/.claude/settings.json");
    is($s->{a}, 'old', 'keep: a kept key is left exactly as ~/.claude has it');
    is($s->{b}, 'new', 'keep: a key not named is promoted as usual');
    is($s->{env}{X}, 'old', 'keep: a kept dotted unit is left alone');
    is($s->{env}{Y}, 'new', 'keep: its sibling unit is promoted');
    like($out, qr/^  kept-local a \(asked\)$/m, 'keep: the report says the key was kept because it was asked');
    like($out, qr/^  kept-local env\.X \(asked\)$/m, 'keep: ...and the dotted unit too');
}

{
    my ($clone, $home) = fixture(3);
    my ($rc, $out) = run('--clone', $clone, '--home', $home, '--keep-key', 'env');
    is($rc, 0, 'parent: promote exits 0') or diag($out);
    my $s = read_json("$home/.claude/settings.json");
    is_deeply($s->{env}, { X => 'old', Y => 'old' }, 'parent: keeping a parent keeps every unit under it');
    is($s->{a}, 'new', 'parent: other keys are promoted');
}

{
    my ($rc, $out) = run('--keep-key');
    is($rc, 3, '--keep-key without a value is a usage error');
    my ($rc2, $help) = run('--help');
    like($help, qr/--keep-key KEY/, 'the usage text documents --keep-key');
}

done_testing();
