#!/usr/bin/env perl
# platform: any
# SandboxSettings.pm: what a container create does to the sandbox's own
# settings.json and CLAUDE.md, and the backups that protect them.
#
# WHY. A Rebuild copied the sandbox preset over claude-home/settings.json and
# the rendered CLAUDE.md over claude-home/CLAUDE.md, so every change made
# inside the sandbox was discarded with no merge, no backup and a prompt that
# only mentioned the image and the container. A recreate that was not a
# Rebuild even copied back the OLD preset. And answering "Continue" re-asked
# on every launch. These cases drive the module directly against throwaway
# files: no launcher, no container.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;

use lib "$Bin/../../scripts";
require_ok('SandboxSettings') or BAIL_OUT('SandboxSettings.pm does not load');

my $J = JSON::PP->new->utf8->canonical->pretty;
sub put  { my ($p, $d) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} (ref $d ? $J->encode($d) : $d); close $fh; }
sub raw  { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $c = <$fh>; close $fh; $c }
sub json { my ($p) = @_; my $c = raw($p); return defined $c ? JSON::PP->new->utf8->decode($c) : undef }
sub backups { my ($l) = @_; my $r = SandboxSettings::backups_root($l); return () unless -d $r;
              opendir my $dh, $r or return (); my @d = sort grep { !/^\./ } readdir $dh; closedir $dh; return @d }

sub sandbox {
    my $root = tempdir(CLEANUP => 1);
    my $home = "$root/claude-home";
    my $l    = "$home/.launcher";
    make_path($l, "$root/container");
    return { root => $root, home => $home, launcher => $l,
             target => "$home/settings.json", base => "$l/container-settings.json",
             preset => "$root/container/settings.json",
             md => "$home/CLAUDE.md", last_render => "$l/container-CLAUDE.md" };
}

sub run_merge {
    my ($s, $answer, $now) = @_;
    my @asked;
    my $r = SandboxSettings::merge_settings(
        target => $s->{target}, base => $s->{base}, preset => $s->{preset},
        backup_dir => SandboxSettings::backup_dir_maker($s->{launcher}, $now // 1_800_000_000),
        resolve => sub { push @asked, $_[0]{name}; return $answer },
    );
    return ($r, \@asked);
}

# ---------------------------------------------------------------------------
# first create: no settings.json yet
# ---------------------------------------------------------------------------
{
    my $s = sandbox();
    put($s->{preset}, qq({"a" : 1}\n));
    my ($r) = run_merge($s);
    is($r->{status}, 'created', 'first create: status created');
    is(raw($s->{target}), qq({"a" : 1}\n), 'first create: the preset bytes, as they are');
    is(raw($s->{base}), qq({"a" : 1}\n), 'first create: the preset is recorded as the base');
    ok($r->{base_recorded} && !defined $r->{backup}, 'first create: base recorded, nothing to back up');
    is(scalar(my @none = backups($s->{launcher})), 0, 'first create: no backup directory');
}

# ---------------------------------------------------------------------------
# Rebuild after changes on both sides: the 3-way merge, with a backup
# ---------------------------------------------------------------------------
{
    my $s = sandbox();
    my $old_preset = { model => 'opus', theme => 'dark', env => { A => '1', B => '1' }, gone => 1, both => 'b' };
    my $new_preset = { model => 'opus', theme => 'light', env => { A => '1', B => '1', C => 'new' }, both => 'preset' };
    my $sandbox    = { model => 'sonnet', theme => 'dark', env => { A => 'mine', B => '1' }, gone => 1,
                       both => 'sandbox', added => 'by-me' };
    put($s->{base}, $old_preset);
    put($s->{preset}, $new_preset);
    put($s->{target}, $sandbox);
    my $before = raw($s->{target});

    my ($r, $asked) = run_merge($s, undef, 1_800_000_000);
    is($r->{status}, 'merged', 'rebuild: status merged');
    my $got = json($s->{target});
    is($got->{model}, 'sonnet', 'rebuild: a key only the sandbox changed is kept');
    is($got->{added}, 'by-me', 'rebuild: a key only the sandbox added is kept');
    is($got->{theme}, 'light', 'rebuild: a key only the preset changed is taken');
    ok(!exists $got->{gone}, 'rebuild: a key only the preset removed is removed');
    is_deeply($got->{env}, { A => 'mine', B => '1', C => 'new' }, 'rebuild: env.A kept from the sandbox, env.C taken from the preset');
    is($got->{both}, 'sandbox', 'rebuild: a key both changed keeps the sandbox value by default');
    is_deeply($asked, [ 'both' ], 'rebuild: only the key both changed was asked about');

    my @b = backups($s->{launcher});
    is(scalar(@b), 1, 'rebuild: one backup directory');
    is($b[0], '20270115T080000Z', 'rebuild: named by the UTC time of the create');
    my $bk = SandboxSettings::backups_root($s->{launcher}) . "/$b[0]/settings.json";
    is($r->{backup}, $bk, 'rebuild: the result names the backup');
    is(raw($bk), $before, 'rebuild: the backup holds the old file byte for byte');
    is_deeply(json($s->{base}), $new_preset, 'rebuild: the current preset is the new base');

    # Second create straight after: nothing new on either side.
    my ($r2) = run_merge($s, undef, 1_800_000_100);
    is($r2->{status}, 'unchanged', 'create again with nothing new: unchanged');
    is(scalar(my @one = backups($s->{launcher})), 1, '... and no second backup');
}

{
    my $s = sandbox();
    put($s->{base},   { both => 'b' });
    put($s->{preset}, { both => 'preset' });
    put($s->{target}, { both => 'sandbox' });
    my ($r) = run_merge($s, 'take');
    is(json($s->{target})->{both}, 'preset', 'answer "take": the preset value replaces the sandbox value');
    is($r->{conflicts}[0]{choice}, 'take', '... and the result records the choice');
}

# ---------------------------------------------------------------------------
# a recreate that is not a Rebuild takes the CURRENT preset
# ---------------------------------------------------------------------------
{
    my $s = sandbox();
    my $old = { theme => 'dark', model => 'opus' };
    put($s->{base}, $old);
    put($s->{target}, $old);                       # the sandbox never touched it
    put($s->{preset}, { theme => 'light', model => 'opus', newKey => 1 });
    my ($r) = run_merge($s);
    is_deeply(json($s->{target}), { theme => 'light', model => 'opus', newKey => 1 },
        'recreate: an untouched sandbox ends up with the current preset, not the stale per-project copy');
    is_deeply(json($s->{base}), { theme => 'light', model => 'opus', newKey => 1 }, 'recreate: the base moves to the current preset');
}

# ---------------------------------------------------------------------------
# no base (the sandbox predates the record): differences are asked about
# ---------------------------------------------------------------------------
{
    my $s = sandbox();
    put($s->{preset}, { a => 2, theirs => 1 });
    put($s->{target}, { a => 1, mine => 1 });
    my ($r, $asked) = run_merge($s);
    ok($r->{base_missing}, 'no base: reported');
    is_deeply($asked, [ 'a' ], 'no base: a key both have with different values is asked about');
    is_deeply(json($s->{target}), { a => 1, mine => 1, theirs => 1 }, 'no base: the sandbox value kept, the preset-only key added');
}

# ---------------------------------------------------------------------------
# unreadable files
# ---------------------------------------------------------------------------
{
    my $s = sandbox();
    put($s->{preset}, { a => 1 });
    put($s->{target}, "{ not json\n");
    my ($r) = run_merge($s);
    is($r->{status}, 'replaced_unreadable', 'unparseable sandbox file: replaced');
    is(raw($r->{backup}), "{ not json\n", '... after a backup of exactly what was there');
    is_deeply(json($s->{target}), { a => 1 }, '... with the preset');
    like($r->{warning}, qr/did not parse/, '... and a warning to show');
}
{
    my $s = sandbox();
    put($s->{base}, { a => 0 });
    put($s->{preset}, "{ broken\n");
    put($s->{target}, { a => 5 });
    my ($r) = run_merge($s);
    is($r->{status}, 'preset_unreadable', 'unparseable preset: reported');
    is_deeply(json($s->{target}), { a => 5 }, '... the sandbox file is left alone');
    is_deeply(json($s->{base}), { a => 0 }, '... and the base does not move, so the next create tries again');
    ok(!$r->{base_recorded}, '... base_recorded is 0');
}

# ---------------------------------------------------------------------------
# CLAUDE.md: regenerated, an edited copy backed up first
# ---------------------------------------------------------------------------
{
    my $s = sandbox();
    my $mk = SandboxSettings::backup_dir_maker($s->{launcher}, 1_800_000_000);
    put($s->{last_render}, "old render\n");
    put($s->{md}, "old render\nmy own line\n");
    my $r = SandboxSettings::refresh_claude_md(target => $s->{md}, last_render => $s->{last_render},
                                               render => "new render\n", backup_dir => $mk);
    is(raw($r->{backup}), "old render\nmy own line\n", 'CLAUDE.md edited in the sandbox: backed up before it is replaced');
    is(raw($s->{md}), "new render\n", '... and replaced with the current render');
    is(raw($s->{last_render}), "new render\n", '... which becomes the last render');

    my $s2 = sandbox();
    put($s2->{last_render}, "old render\n");
    put($s2->{md}, "old render\n");
    my $r2 = SandboxSettings::refresh_claude_md(target => $s2->{md}, last_render => $s2->{last_render},
        render => "new render\n", backup_dir => SandboxSettings::backup_dir_maker($s2->{launcher}, 1));
    ok(!defined $r2->{backup}, 'CLAUDE.md as last rendered: no backup');
    is(raw($s2->{md}), "new render\n", '... just the new render');

    my $s3 = sandbox();
    put($s3->{md}, "hand-written\n");
    my $r3 = SandboxSettings::refresh_claude_md(target => $s3->{md}, last_render => $s3->{last_render},
        render => "render\n", backup_dir => SandboxSettings::backup_dir_maker($s3->{launcher}, 1));
    ok(defined $r3->{backup}, 'no record of a last render, and the copy differs from the current one: backed up');

    # one create, two files: one backup directory
    my $s4 = sandbox();
    my $mk4 = SandboxSettings::backup_dir_maker($s4->{launcher}, 1_800_000_000);
    put($s4->{md}, "edited\n");
    put($s4->{last_render}, "render\n");
    SandboxSettings::refresh_claude_md(target => $s4->{md}, last_render => $s4->{last_render}, render => "r2\n", backup_dir => $mk4);
    put($s4->{base}, { a => 1 }); put($s4->{preset}, { a => 2 }); put($s4->{target}, { a => 1, b => 1 });
    SandboxSettings::merge_settings(target => $s4->{target}, base => $s4->{base}, preset => $s4->{preset}, backup_dir => $mk4);
    my @b = backups($s4->{launcher});
    is(scalar(@b), 1, 'CLAUDE.md and settings.json backed up by one create share one directory');
    ok(-f SandboxSettings::backups_root($s4->{launcher}) . "/$b[0]/CLAUDE.md"
       && -f SandboxSettings::backups_root($s4->{launcher}) . "/$b[0]/settings.json", '... holding both files');

    # two creates in the same second do not mix
    my $mk5 = SandboxSettings::backup_dir_maker($s4->{launcher}, 1_800_000_000);
    like($mk5->(), qr/20270115T080000Z-2\z/, 'a second create in the same second gets its own directory');
}

# ---------------------------------------------------------------------------
# the declined-preset memory
# ---------------------------------------------------------------------------
{
    my %c = (saved => "aaa\n", current => 'bbb');
    is(SandboxSettings::drift_state(%c), 'changed', 'drift: saved differs from current, nothing declined: changed (ask)');
    is(SandboxSettings::drift_state(%c, declined => "bbb\n"), 'declined', 'drift: this version was declined: do not ask');
    is(SandboxSettings::drift_state(%c, current => 'ccc', declined => 'bbb'), 'changed', 'drift: a NEWER version than the declined one asks again');
    is(SandboxSettings::drift_state(saved => 'bbb', current => 'bbb', declined => 'x'), 'none', 'drift: up to date: none');
    is(SandboxSettings::drift_state(saved => undef, current => 'bbb'), 'none', 'drift: no saved record is not drift');
}

# ---------------------------------------------------------------------------
# apply_units: the backup's "revert this sandbox to the preset's value"
# ---------------------------------------------------------------------------
{
    my $s = sandbox();
    put($s->{target}, { model => 'sonnet', env => { A => 'mine', B => 'keep' }, extra => 1, other => 'untouched' });
    my $before = raw($s->{target});
    my $r = SandboxSettings::apply_units(
        target => $s->{target}, backup_dir => SandboxSettings::backup_dir_maker($s->{launcher}, 1_800_000_000),
        units  => [ { name => 'model', path => ['model'], found => 1, value => 'opus' },
                    { name => 'env.A', path => ['env', 'A'], found => 1, value => '1' },
                    { name => 'extra', path => ['extra'], found => 0 } ],
    );
    ok(!defined $r->{error}, 'revert: no error') or diag($r->{error});
    is_deeply(json($s->{target}), { model => 'opus', env => { A => '1', B => 'keep' }, other => 'untouched' },
        'revert: each unit takes the preset value (or goes), nothing else changes');
    is(raw($r->{backup}), $before, 'revert: the old file is backed up first');
    my $missing = SandboxSettings::apply_units(target => "$s->{root}/nope.json",
        backup_dir => SandboxSettings::backup_dir_maker($s->{launcher}, 1), units => []);
    like($missing->{error}, qr/does not exist/, 'revert: a missing file is an error, not a new file');
}

done_testing();
