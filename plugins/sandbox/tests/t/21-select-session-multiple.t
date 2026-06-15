#!/usr/bin/env perl
# Picker with multiple session jsonl files: verify "Start a new session"
# is always option 1, sessions are ordered most-recent-first, and the
# line-prompt fallback honors the user's choice (e.g. choosing 2 yields
# RESUME of the newest existing session).

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);

plan tests => 7;

my $script = "$Bin/../../scripts/select-session.pl";
ok(-f $script, 'select-session.pl exists') or BAIL_OUT;

# Create three synthetic sessions with distinct mtimes.
my $sessions_dir = tempdir(CLEANUP => 1);

my @sessions = (
    { uuid => '11111111-1111-1111-1111-111111111111', age => 3600 },   # 1h old
    { uuid => '22222222-2222-2222-2222-222222222222', age => 60 },     # 1min old (newest)
    { uuid => '33333333-3333-3333-3333-333333333333', age => 86400 },  # 1day old (oldest)
);

for my $s (@sessions) {
    my $path = "$sessions_dir/$s->{uuid}.jsonl";
    open my $w, '>', $path or die;
    print $w qq({"type":"permission-mode","sessionId":"$s->{uuid}"}\n);
    print $w qq({"type":"user","message":{"role":"user","content":"prose prompt for session $s->{uuid}"},"sessionId":"$s->{uuid}","cwd":"/project"}\n);
    close $w;
    my $mtime = time - $s->{age};
    utime($mtime, $mtime, $path) or die "utime: $!";
}

# Drive picker via line-prompt fallback, pick choice 1 (NEW)
{
    my $out = "$sessions_dir/.pick-new";
    my $cmd = qq("$^X" "$script" --sessions-dir "$sessions_dir" --output "$out");
    open my $p, "| $cmd > /dev/null 2>&1" or die;
    print $p "1\n";
    close $p;
    open my $rfh, '<', $out or die;
    my $content = do { local $/; <$rfh> };
    chomp $content;
    is($content, 'NEW',
       'choice 1 yields NEW ("Start a new session" is always first)');
}

# Drive picker, pick choice 2 — should be the NEWEST session (UUID #2)
{
    my $out = "$sessions_dir/.pick-newest";
    my $cmd = qq("$^X" "$script" --sessions-dir "$sessions_dir" --output "$out");
    open my $p, "| $cmd > /dev/null 2>&1" or die;
    print $p "2\n";
    close $p;
    open my $rfh, '<', $out or die;
    my $content = do { local $/; <$rfh> };
    chomp $content;
    is($content, 'RESUME 22222222-2222-2222-2222-222222222222',
       'choice 2 yields RESUME of the MOST-RECENT session');
}

# Drive picker, pick choice 3 — should be middle-age (UUID #1)
{
    my $out = "$sessions_dir/.pick-middle";
    my $cmd = qq("$^X" "$script" --sessions-dir "$sessions_dir" --output "$out");
    open my $p, "| $cmd > /dev/null 2>&1" or die;
    print $p "3\n";
    close $p;
    open my $rfh, '<', $out or die;
    my $content = do { local $/; <$rfh> };
    chomp $content;
    is($content, 'RESUME 11111111-1111-1111-1111-111111111111',
       'choice 3 yields RESUME of the MIDDLE-AGE session');
}

# Drive picker, pick choice 4 — should be oldest (UUID #3)
{
    my $out = "$sessions_dir/.pick-oldest";
    my $cmd = qq("$^X" "$script" --sessions-dir "$sessions_dir" --output "$out");
    open my $p, "| $cmd > /dev/null 2>&1" or die;
    print $p "4\n";
    close $p;
    open my $rfh, '<', $out or die;
    my $content = do { local $/; <$rfh> };
    chomp $content;
    is($content, 'RESUME 33333333-3333-3333-3333-333333333333',
       'choice 4 yields RESUME of the OLDEST session');
}

# Out-of-range choice should fall back to choice 1 (NEW)
{
    my $out = "$sessions_dir/.pick-oor";
    my $cmd = qq("$^X" "$script" --sessions-dir "$sessions_dir" --output "$out");
    open my $p, "| $cmd > /dev/null 2>&1" or die;
    print $p "99\n";
    close $p;
    open my $rfh, '<', $out or die;
    my $content = do { local $/; <$rfh> };
    chomp $content;
    is($content, 'NEW',
       'out-of-range choice falls back to NEW (safer default)');
}

# Empty input → default to NEW
{
    my $out = "$sessions_dir/.pick-empty";
    my $cmd = qq("$^X" "$script" --sessions-dir "$sessions_dir" --output "$out");
    open my $p, "| $cmd > /dev/null 2>&1" or die;
    print $p "\n";
    close $p;
    open my $rfh, '<', $out or die;
    my $content = do { local $/; <$rfh> };
    chomp $content;
    is($content, 'NEW',
       'empty input defaults to NEW');
}
