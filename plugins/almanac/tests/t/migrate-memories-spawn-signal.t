#!/usr/bin/env perl
# platform: any
# Todo 20261002-005241-1bbb0000: almanac-migrate-memories.pl's _spawn_note_pl
# returned `$? >> 8`, which is 0 for a child killed by a signal, so a killed
# `almanac-note.pl list` read as success with empty output and render-index
# wrote an empty global note index. A signal death must come back non-zero.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);

my $FILE_HOME = tempdir(CLEANUP => 1);
$FILE_HOME =~ s{\\}{/}g;
local $ENV{HOME}         = $FILE_HOME;
local $ENV{USERPROFILE}  = $FILE_HOME;
local $ENV{ALMANAC_HOME} = $FILE_HOME;
delete local $ENV{CLAUDE_PROJECT_DIR};
delete local $ENV{CCPRAXIS_DATA_DIR};

(my $MIGRATE_PL = "$Bin/../../scripts/almanac-migrate-memories.pl") =~ s{\\}{/}g;
require $MIGRATE_PL;   # `unless (caller)` guard: loads the subs, runs nothing
ok(defined &main::_spawn_note_pl, 'precondition: _spawn_note_pl is loadable');

my $dir = tempdir(CLEANUP => 1);
$dir =~ s{\\}{/}g;
sub fake {
    my ($name, $code) = @_;
    my $p = "$dir/$name.pl";
    open my $fh, '>', $p or die "fixture: $p: $!";
    print {$fh} $code;
    close $fh;
    return $p;
}

my ($rc, $out, $err) = main::_spawn_note_pl(fake('ok', qq{print "listed\\n"; exit 0;\n}), 'list');
is($rc, 0, 'a clean exit 0 is success');
is($out, "listed\n", '...with its stdout captured');

($rc, $out, $err) = main::_spawn_note_pl(fake('exit3', qq{print STDERR "boom\\n"; exit 3;\n}), 'list');
is($rc, 3, 'a plain non-zero exit keeps its code');
is($err, "boom\n", '...and its stderr');

($rc, $out, $err) = main::_spawn_note_pl(fake('killed', qq{kill 'KILL', \$\$; sleep 5; exit 0;\n}), 'list');
isnt($rc, 0, 'a child killed by a signal is NOT success');
is($rc, 128 + 9, '...it maps to 128+SIGKILL');
like($err, qr/killed by signal 9/, '...and says so when the child wrote nothing');

done_testing();
