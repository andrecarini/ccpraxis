#!/usr/bin/env perl
# platform: host
# Bug 20261121-234250-39b1: an unanswered inbox item in ANOTHER project was
# invisible in the statusline everywhere else, because the global-counts
# snapshot had no inbox section and row 1 drew only the current project's
# flag. The snapshot now lists every project's unanswered items, and row 1
# draws them in the other counters' shape (operator, 2026-11-22): "<flag> P·G",
# P this project's, G the other projects'; "<flag> G" when P is 0. The current
# project is never counted twice.
#
# Scaffolding is a trimmed copy of statusline-counters-layout.t's (tput/git
# shims, a scrubbed temp HOME, a timeout-bounded spawn); never the real
# ~/.claude, the vault or this repo's .ccpraxis-local-data.
use strict;
use warnings;
use FindBin qw($Bin);
unless (grep { -x "$_/timeout" } split /:/, ($ENV{PATH} // q{})) {
    $ENV{PATH} = "$Bin/../../../../scripts/test-bin:" . ($ENV{PATH} // q{})
        if -x "$Bin/../../../../scripts/test-bin/timeout";
}
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP ();
use Encode qw(encode decode);
use Cwd ();

my $STATUSLINE  = "$Bin/../../../../scripts/statusline.pl";
my $ALMANAC_DIR = "$Bin/../../../almanac/scripts";
my $INBOX_CLI   = "$ALMANAC_DIR/almanac-inbox.pl";

# This process never writes under the operator's home either.
my $SCRATCH_HOME = tempdir(CLEANUP => 1);
$ENV{HOME} = $ENV{USERPROFILE} = $ENV{ALMANAC_HOME} = $SCRATCH_HOME;

sub nslash { my ($p) = @_; $p =~ s{\\}{/}g; $p =~ s{/\z}{} if length($p) > 1; return $p }
sub spew_raw {
    my ($path, $bytes) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print {$fh} $bytes;
    close $fh;
}
sub strip_sgr { my $s = shift; $s = '' unless defined $s; $s =~ s/\033\[[^m]*m//g; return $s }
sub first_line { my $s = shift; $s = '' unless defined $s; my ($l) = split /\n/, $s, 2; return defined($l) ? $l : '' }

my $SHIM_DIR = nslash(tempdir(CLEANUP => 1));
spew_raw("$SHIM_DIR/tput", "#!/bin/sh\necho 200\n");
spew_raw("$SHIM_DIR/stty", "#!/bin/sh\nexit 1\n");
spew_raw("$SHIM_DIR/git",  "#!/bin/sh\nexit 1\n");
chmod 0755, "$SHIM_DIR/tput", "$SHIM_DIR/stty", "$SHIM_DIR/git";

my $CLEAN_DATA = nslash(tempdir(CLEANUP => 1));
my @SCRUB_ENV = qw(CLAUDE_PROJECT_DIR ALMANAC_HOME ALMANAC_SURFACE BUTLER_STATE_DIR COLUMNS);

# render(cwd => $dir, home => $home, sandbox => 0|1) -> row 1, SGR stripped,
# as UTF-8 bytes.
sub render {
    my (%o) = @_;
    my ($infh, $inpath) = tempfile();
    binmode $infh, ':raw';
    print {$infh} JSON::PP->new->utf8->encode({
        model          => { display_name => 'Claude Sonnet 5', id => 'claude-sonnet-5' },
        workspace      => { current_dir => $o{cwd} },
        context_window => { used_percentage => 10, context_window_size => 200_000 },
    });
    close $infh;
    local %ENV = %ENV;
    $ENV{PATH} = "$SHIM_DIR:$ENV{PATH}";
    delete $ENV{$_} for @SCRUB_ENV;
    $ENV{HOME} = $ENV{USERPROFILE} = $o{home};
    $ENV{CCPRAXIS_DATA_DIR} = $CLEAN_DATA;
    if ($o{sandbox}) { $ENV{CCPRAXIS_SANDBOX} = '1' } else { delete $ENV{CCPRAXIS_SANDBOX} }
    my $out = `timeout 20 perl "$STATUSLINE" < "$inpath" 2>/dev/null`;
    unlink $inpath;
    return $o{raw} ? first_line($out) : strip_sgr(first_line($out));
}

sub mk_proj {
    my ($leaf) = @_;
    my $d = nslash(tempdir(CLEANUP => 1)) . "/$leaf";
    make_path("$d/.git", "$d/.ccpraxis-local-data");
    return $d;
}
sub mk_home { my $h = nslash(tempdir(CLEANUP => 1)); make_path("$h/.claude"); return $h }

# write_snapshot($home, [ [ $path, $open ], ... ]) -- a valid schema-1
# snapshot carrying an inbox section (paths as UTF-8 bytes).
sub write_snapshot {
    my ($home, $entries) = @_;
    my $open = 0;
    $open += $_->[1] for @$entries;
    my $doc = {
        generated_at => '2026-11-22T00:00:00Z', schema => 1,
        todo => { open => 0, done => 0, total => 0 }, note => { total => 0 },
        inbox => { open => $open,
                   projects => [ map { { path => decode('UTF-8', $_->[0]), open => $_->[1] } } @$entries ] },
    };
    spew_raw("$home/.claude/almanac-global-counts.json", JSON::PP->new->utf8->canonical->encode($doc) . "\n");
}

my $ALMANAC_OK = eval { require $INBOX_CLI; 1 };
diag("almanac-inbox.pl did not load: $@") unless $ALMANAC_OK;
sub seed_unanswered {
    my ($root, $n) = @_;
    Almanac::Inbox::file(root => $root, title => "item $_") for 1 .. $n;
}

my $F = encode('UTF-8', chr(0x2691));
my $D = encode('UTF-8', chr(0x00B7));   # the counters' P-dot-G separator
sub flags { my ($row) = @_; my @m = ($row =~ /\Q$F\E/g); return scalar @m }

SKIP: {
    skip('almanac-inbox.pl did not load', 15) unless $ALMANAC_OK;

    my $P_HERE  = mk_proj('here-proj');
    my $P_OTHER = mk_proj('acxpraxis');
    my $P_THIRD = mk_proj('third-proj');
    seed_unanswered($P_HERE, 2);

    # One other project: "<flag> 2-dot-1"; this project's two are not counted again.
    my $H1 = mk_home();
    write_snapshot($H1, [ [ $P_HERE, 2 ], [ $P_OTHER, 1 ] ]);
    my $row = render(cwd => $P_HERE, home => $H1);
    like($row, qr/\Q$F\E 2\Q$D\E1(?!\S)/,
        'one other project: "<flag> 2-dot-1", this project first, the others after the dot')
        or diag("row 1 = [$row]");
    is(flags($row), 1, 'one other project: one flag, as every counter has one glyph');
    unlike($row, qr/ in /, 'one other project: no project name or " in " text');

    # No item in this project: the others' count alone, faded like the other
    # counters' elsewhere-only form.
    my $P_EMPTY = mk_proj('empty-proj');
    my $rowe = render(cwd => $P_EMPTY, home => $H1);
    like($rowe, qr/\Q$F\E 3(?!\S)/,
        'seen from a project with no items, both others count, with no dot: "<flag> 3"')
        or diag("row 1 = [$rowe]");
    is(flags($rowe), 1, '...and that is the only flag');

    # Colour: with items here the flag sits on the warning background; with
    # none here it is faded, with no background (operator, 2026-11-22). The
    # SGR run that opens the flag is read from the raw row.
    my $sgr_before_flag = sub {
        my ($raw) = @_;
        return undef unless $raw =~ /((?:\e\[[0-9;]*m)+)\Q$F\E/;
        return $1;
    };
    my $raw_here  = $sgr_before_flag->(render(cwd => $P_HERE,  home => $H1, raw => 1));
    my $raw_empty = $sgr_before_flag->(render(cwd => $P_EMPTY, home => $H1, raw => 1));
    ok(defined $raw_here && $raw_here =~ /\e\[48;/, 'items here: the flag has a background colour')
        or diag('SGR = [' . ($raw_here // 'none') . ']');
    ok(defined $raw_empty && $raw_empty !~ /\e\[48;/, 'none here: the flag has no background (faded)')
        or diag('SGR = [' . ($raw_empty // 'none') . ']');
    isnt($raw_empty, $raw_here, 'none here: the flag is drawn in different colours from the local-items flag');

    # Several other projects: one total after the dot.
    my $H2 = mk_home();
    write_snapshot($H2, [ [ $P_HERE, 2 ], [ $P_OTHER, 1 ], [ $P_THIRD, 4 ] ]);
    my $row2 = render(cwd => $P_HERE, home => $H2);
    like($row2, qr/\Q$F\E 2\Q$D\E5(?!\S)/,
        'two other projects: "<flag> 2-dot-5"')
        or diag("row 1 = [$row2]");

    # Only this project has items: nothing extra.
    my $H3 = mk_home();
    write_snapshot($H3, [ [ $P_HERE, 2 ] ]);
    my $row3 = render(cwd => $P_HERE, home => $H3);
    is(flags($row3), 1, 'only this project has items: one flag') or diag("row 1 = [$row3]");
    unlike($row3, qr/\Q$D\E/, '...and no dot');

    # No snapshot inbox at all: nothing extra (a pre-fix snapshot).
    my $H4 = mk_home();
    spew_raw("$H4/.claude/almanac-global-counts.json",
        '{"generated_at":"2026-11-22T00:00:00Z","note":{"total":0},"schema":1,"todo":{"done":0,"open":0,"total":0}}' . "\n");
    my $row4 = render(cwd => $P_EMPTY, home => $H4);
    is(flags($row4), 0, 'a snapshot without an inbox section draws no flag') or diag("row 1 = [$row4]");

    # Sandbox: the snapshot's host paths never match the mount, so the current
    # project is recognised by its base name. The same snapshot on the host
    # shows that entry, because there it is a different path.
    my $H5 = mk_home();
    my $twin = nslash(tempdir(CLEANUP => 1)) . '/host-side/empty-proj';
    write_snapshot($H5, [ [ $twin, 2 ], [ $P_OTHER, 1 ] ]);
    my $rows = render(cwd => $P_EMPTY, home => $H5, sandbox => 1);
    like($rows, qr/\Q$F\E 1(?!\S)/, 'sandbox: another project still shows, and the entry named like the current project is left out') or diag("row 1 = [$rows]");
    is(flags($rows), 1, 'sandbox: one flag');
    my $rowh = render(cwd => $P_EMPTY, home => $H5);
    like($rowh, qr/\Q$F\E 3(?!\S)/, 'host: the same entry is another project (a different path) and counts')
        or diag("row 1 = [$rowh]");
}

# End to end: filing through the real CLI in one project refreshes the
# snapshot, and the statusline of another project shows the item.
SKIP: {
    skip('almanac-inbox.pl did not load', 3) unless $ALMANAC_OK;
    my $H = mk_home();
    my $P_A = mk_proj('watcher');
    my $P_B = mk_proj("Andr\xc3\xa9-proj");
    my ($fo, $fe);
    {
        local $ENV{HOME} = $H;
        local $ENV{USERPROFILE} = $H;
        local $ENV{ALMANAC_HOME} = $H;
        my (undef, $errpath) = tempfile();
        $fo = `perl "$INBOX_CLI" file --root "$P_B" --title "Approve the protected path?" 2>"$errpath"`;
        is($? >> 8, 0, 'end to end: almanac-inbox.pl file in project B exits 0');
        open my $eh, '<:raw', $errpath; local $/; $fe = <$eh>; close $eh; unlink $errpath;
        is($fe // '', '', 'end to end: the CLI warns about nothing (the refresh succeeded)');
    }
    my $row = render(cwd => $P_A, home => $H);
    like($row, qr/\Q$F\E 1(?!\S)/,
        'end to end: project A\'s statusline counts B\'s item (B has a non-ASCII path)')
        or diag("row 1 = [$row]");
}

done_testing();
