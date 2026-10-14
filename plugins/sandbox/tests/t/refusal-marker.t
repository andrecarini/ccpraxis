#!/usr/bin/env perl
# platform: any
# RefusalMarker: a .claude-sandbox-refuse file makes the launcher and bootstrap
# refuse a path -- here, above it, or up to $SCAN_DEPTH levels below it -- and
# its own text is the refusal message. `allow-launcher:` lines let one named
# launcher past one marker. Also pins, structurally, that both entry points run
# the check before they write anything, and that there is no env override.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use RefusalMarker qw(MARKER_NAME parse_marker find_refusal refusal_message);

sub spew {
    my ($file, $text) = @_;
    open my $fh, '>:raw', $file or die "write $file: $!";
    print $fh $text;
    close $fh;
}

sub fresh {
    my $root = tempdir(CLEANUP => 1);
    $root =~ s{\\}{/}g;
    make_path("$root/a/b/c/d");
    return $root;
}

# --- parse_marker ----------------------------------------------------------

{
    my $m = parse_marker("allow-launcher: Fork-Sandbox\n\n  Use fork-sandbox here.\nSecond line.\n  ALLOW-LAUNCHER :other\n");
    is_deeply($m->{allow}, ['fork-sandbox', 'other'], 'parse: allow ids extracted, lowercased, any position, any case');
    is($m->{message}, "Use fork-sandbox here.\nSecond line.", 'parse: allow lines removed, message trimmed, inner newlines kept');
}
{
    my $m = parse_marker("line one\r\nline two\x1b[31m red\x07\r\n");
    is($m->{message}, "line one\nline two [31m red", 'parse: CRLF normalised, ESC/BEL and other control bytes become spaces');
    is_deeply($m->{allow}, [], 'parse: no allow lines -> empty list');
}
{
    my $m = parse_marker("allow-launcher: two words\n");
    is_deeply($m->{allow}, [], 'parse: an allow line with more than one token is not an allow line');
    is($m->{message}, 'allow-launcher: two words', '... and stays in the message');
}
is(parse_marker('')->{message}, '', 'parse: empty marker -> empty message');

# --- find_refusal: where markers are found --------------------------------

{
    my $r = fresh();
    is(find_refusal("$r/a/b"), undef, 'no marker anywhere -> undef');
}
{
    my $r = fresh();
    spew("$r/a/b/" . MARKER_NAME, "here msg\n");
    my $h = find_refusal("$r/a/b");
    is($h->{relation}, 'here', 'marker in the target itself -> here');
    is($h->{message}, 'here msg', '... message is the marker text');
    is($h->{marker}, "$r/a/b/" . MARKER_NAME, '... marker path reported');
}
{
    my $r = fresh();
    spew("$r/a/" . MARKER_NAME, "above msg");
    my $h = find_refusal("$r/a/b/c");
    is($h->{relation}, 'above', 'marker two levels up -> above');
    is($h->{dir}, "$r/a", '... the marked directory is reported');
}
{
    my $r = fresh();
    spew("$r/a/b/" . MARKER_NAME, "below1");
    is(find_refusal("$r/a")->{relation}, 'below', 'marker one level below -> below');
}
{
    my $r = fresh();
    spew("$r/a/b/c/" . MARKER_NAME, "below2");
    my $h = find_refusal("$r/a");
    is($h->{relation}, 'below', 'marker two levels below -> below (default depth 2)');
}
{
    # The documented limit, pinned so it cannot change silently in either
    # direction: deeper than $SCAN_DEPTH is not scanned.
    my $r = fresh();
    spew("$r/a/b/c/d/" . MARKER_NAME, "below3");
    is(find_refusal("$r/a"), undef, 'marker three levels below is NOT detected at the default depth');
    ok(find_refusal("$r/a", { scan_depth => 3 }), '... and is detected when scan_depth is 3');
    is($RefusalMarker::SCAN_DEPTH, 2, 'default scan depth is 2');
}
{
    my $r = fresh();
    spew("$r/a/" . MARKER_NAME, "outer");
    spew("$r/a/b/" . MARKER_NAME, "inner");
    is(find_refusal("$r/a/b")->{message}, 'inner', 'here wins over above');
    is(find_refusal("$r/a/b/c")->{message}, 'inner', 'nearest ancestor wins');
}
{
    my $r = fresh();
    make_path("$r/a/" . MARKER_NAME);
    is(find_refusal("$r/a"), undef, 'a DIRECTORY named like the marker does not count');
}
{
    my $r = fresh();
    spew("$r/a/" . MARKER_NAME, "x");
    ok(find_refusal("$r/a/b/"), 'trailing slash on the target is tolerated');
    (my $bs = "$r/a/b") =~ s{/}{\\}g;
    ok(find_refusal($bs), 'backslash-separated target is tolerated');
}

# --- find_refusal: allow-launcher -----------------------------------------

{
    my $r = fresh();
    spew("$r/a/" . MARKER_NAME, "allow-launcher: fork-sandbox\nfenced");
    ok(find_refusal("$r/a/b"), 'default launcher id is not allowed by a marker naming another launcher');
    is(find_refusal("$r/a/b", { launcher_id => 'fork-sandbox' }), undef, 'the named launcher passes');
    is(find_refusal("$r/a/b", { launcher_id => 'FORK-Sandbox' }), undef, 'launcher id compares case-insensitively');
    {
        local $RefusalMarker::LAUNCHER_ID = 'fork-sandbox';
        is(find_refusal("$r/a/b"), undef, 'a fork changing $LAUNCHER_ID passes without passing an option');
    }
}
{
    my $r = fresh();
    spew("$r/a/" . MARKER_NAME, "allow-launcher: fork-sandbox\nouter");
    spew("$r/a/b/c/" . MARKER_NAME, "inner, no allow");
    my $h = find_refusal("$r/a/b", { launcher_id => 'fork-sandbox' });
    ok($h, 'being allowed past one marker never lets a launcher past another');
    is($h->{message}, 'inner, no allow', '... the other marker is the one reported');
}
is($RefusalMarker::LAUNCHER_ID, 'claude-sandbox', 'ccpraxis presents itself as claude-sandbox');

# --- refusal_message -------------------------------------------------------

{
    my $hit = { marker => '/x/' . MARKER_NAME, dir => '/x', relation => 'above', message => 'Go use the other tool.' };
    my $t = refusal_message($hit, '/x/y');
    like($t, qr/\Aclaude-sandbox will not run here:/, 'message names the launcher');
    like($t, qr{\n  /x/y\n}, 'message names the target');
    like($t, qr{a directory above it carries a refusal marker}, 'message explains the relation');
    like($t, qr{\n  /x/\Q${\ MARKER_NAME}\E\n}, 'message names the marker file');
    like($t, qr{Go use the other tool\.\n\nAborting\.\z}, 'marker text is printed, then Aborting');
    like(refusal_message({ %$hit, message => '' }, '/x/y'), qr/The marker gives no reason/, 'empty marker text gets a default');
    like(refusal_message($hit, '/x/y', 'fork-sandbox'), qr/\Afork-sandbox will not run here/, 'launcher id is overridable');
}

# --- structural: both entry points check before writing -------------------

sub slurp {
    my ($f) = @_;
    open my $fh, '<:raw', $f or die "read $f: $!";
    local $/;
    return scalar <$fh>;
}

{
    my $src = slurp("$Bin/../../scripts/launcher.pl");
    my $check = index($src, 'RefusalMarker::find_refusal($PROJECT_PATH)');
    ok($check > 0, 'launcher.pl calls find_refusal on the project path');
    my $data  = index($src, 'my $CCPRAXIS_DATA ');
    my $route = index($src, 'workcopy_route($PROJECT_PATH');
    ok($data > 0 && $check < $data, 'launcher.pl checks before it derives the per-project data dir');
    ok($route > 0 && $check < $route, 'launcher.pl checks before the work-copy route');
}
{
    my $src = slurp("$Bin/../../scripts/bootstrap.pl");
    my $check = index($src, 'RefusalMarker::find_refusal($PROJECT_PATH)');
    ok($check > 0, 'bootstrap.pl calls find_refusal on the project path');
    my $first_write = index($src, 'make_path(');
    ok($first_write > 0 && $check < $first_write, 'bootstrap.pl checks before its first make_path');
}
{
    my $src = slurp("$Bin/../../scripts/RefusalMarker.pm");
    unlike($src, qr/\$ENV\{|%ENV/, 'RefusalMarker reads no environment variable (no env override)');
}

done_testing();
