#!/usr/bin/env perl
# platform: any
# GlobalClaudeMd: ~/.claude/CLAUDE.md is the shared payload file plus the
# host's own part. Pure functions, so every platform's answer is checked on
# every host by passing the platform explicitly.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use GlobalClaudeMd ();

is(GlobalClaudeMd::SHARED_RELPATH, 'global-config/CLAUDE.md', 'the shared file is global-config/CLAUDE.md');
is(GlobalClaudeMd::host_part_relpath('windows'), 'global-config/CLAUDE.windows.md', 'windows part');
is(GlobalClaudeMd::host_part_relpath('darwin'),  'global-config/CLAUDE.macos.md',   'macOS part');
is(GlobalClaudeMd::host_part_relpath('linux'),   undef,                             'linux has no part');
is_deeply([ GlobalClaudeMd::all_part_relpaths() ],
    [ 'global-config/CLAUDE.md', 'global-config/CLAUDE.macos.md', 'global-config/CLAUDE.windows.md' ],
    'all parts, shared first');

is(GlobalClaudeMd::render("a\n", "b\n"),   "a\n\nb\n",   'shared, blank line, part');
is(GlobalClaudeMd::render("a",   "b\n"),   "a\n\nb\n",   'a shared file without a final newline still gets one blank line');
is(GlobalClaudeMd::render("a\n", undef),   "a\n",        'no part: the shared file byte for byte');
is(GlobalClaudeMd::render("a\n", ''),      "a\n",        'empty part: the shared file byte for byte');
is(GlobalClaudeMd::render("a\r\n", "b\r\n"), "a\r\n\r\nb\r\n", 'CRLF shared file: CRLF separator');
is(GlobalClaudeMd::render('', "b\n"),      "b\n",        'empty shared file: just the part');

my %files = (
    'global-config/CLAUDE.md'         => "shared\n",
    'global-config/CLAUDE.windows.md' => "win\n",
    'global-config/CLAUDE.macos.md'   => "mac\n",
);
my $read = sub { $files{ $_[0] } };
is(GlobalClaudeMd::render_with($read, 'windows'), "shared\n\nwin\n", 'render_with: windows gets only its part');
is(GlobalClaudeMd::render_with($read, 'darwin'),  "shared\n\nmac\n", 'render_with: macOS gets only its part');
is(GlobalClaudeMd::render_with($read, 'linux'),   "shared\n",        'render_with: linux gets the shared file');

delete $files{'global-config/CLAUDE.macos.md'};
is(GlobalClaudeMd::render_with($read, 'darwin'), "shared\n", 'render_with: a payload from before the split renders as the shared file');
delete $files{'global-config/CLAUDE.md'};
is(GlobalClaudeMd::render_with($read, 'darwin'), undef, 'render_with: no shared file, no payload');

# The real payload: every part exists, and no part tells the reader to pick a
# platform section -- the selection is made by promote, not by the reader.
my $root = "$Bin/../../../..";
for my $rel (GlobalClaudeMd::all_part_relpaths()) {
    ok(-f "$root/$rel", "payload part exists: $rel");
    open my $fh, '<:raw', "$root/$rel" or next;
    local $/;
    my $c = <$fh>;
    unlike($c, qr/follow the section (?:below )?that matches/i, "$rel does not ask the reader to pick a platform section");
}

done_testing();
