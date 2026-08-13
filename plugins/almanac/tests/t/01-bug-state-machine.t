#!/usr/bin/env perl
# t/01-bug-state-machine.t — bug reports are frozen once ccpraxis picks them up.
#
# The guarantee: a report's body cannot change from `reviewing` onward, so a
# reviewer cannot have it rewritten underneath them and a `taken` report cannot
# be quietly reworded afterwards. Three layers back that up — the script
# refuses, a PreToolUse hook denies direct edits, and a sha256 recorded at
# freeze time DETECTS a write that got through anyway. The first two are
# bypassable by a determined Bash call; the third is not, because it does not
# rely on preventing anything.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $A = "$S/almanac-bug.pl";
ok(-f $A, 'almanac-bug.pl exists') or BAIL_OUT('script missing');

my $HOME = tempdir(CLEANUP => 1);
my $PROJ = tempdir(CLEANUP => 1);

sub run {
    my (@args) = @_;
    my $cmd = qq{ALMANAC_HOME="$HOME" perl "$A" } . join(' ', @args) . ' 2>&1';
    my $out = `$cmd`;
    return ($? >> 8, $out // '');
}
sub body_of {
    my ($p) = @_;
    open my $f, '<:raw', $p or return '';
    local $/; my $t = <$f>;
    return $t =~ /\A---\r?\n.*?\r?\n---\r?\n(.*)\z/s ? $1 : '';
}
sub field_of {
    my ($p, $k) = @_;
    open my $f, '<:raw', $p or return undef;
    local $/; my $t = <$f>;
    return $t =~ /^\Q$k\E:\s*(.*)$/m ? $1 : undef;
}

# ---- file ------------------------------------------------------------------
my ($rc, $out) = run('file', '--project', $PROJ, '--title', '"judge deadlocks"',
                     '--severity', 'high', '--area', 'butler', '--body', '"it exits before writing"');
is($rc, 0, 'file: creates a report') or diag $out;
chomp(my $path = $out);
ok(-f $path, 'file: the report exists on disk');
like($path, qr{/\.ccpraxis-local-data/bug-reports/[^/]+\.md$}, 'file: lands in the reports dir');
my ($id) = $path =~ m{/([^/]+)\.md$};
is(field_of($path, 'status'), 'open', 'file: starts open');
is(field_of($path, 'severity'), 'high', 'file: records severity');

# A report with no body is noise, and the script says so rather than writing it.
my ($rc_nb) = run('file', '--project', $PROJ, '--title', '"empty"');
isnt($rc_nb, 0, 'file: refuses a report with no body');

# ---- update while open -----------------------------------------------------
my ($rc_u) = run('update', $id, '--project', $PROJ, '--body', '"revised while open"');
is($rc_u, 0, 'update: allowed while open');
like(body_of($path), qr/revised while open/, 'update: the body actually changed');

# ---- freeze ----------------------------------------------------------------
my ($rc_r) = run('set-status', $id, '--project', $PROJ, '--to', 'reviewing');
is($rc_r, 0, 'set-status: open -> reviewing');
is(field_of($path, 'status'), 'reviewing', 'status is reviewing');
my $digest = field_of($path, 'content_sha256');
ok(defined $digest && length $digest, 'leaving open RECORDS a body digest');
ok(defined field_of($path, 'frozen_at'), '...and stamps frozen_at');

my ($rc_u2, $out_u2) = run('update', $id, '--project', $PROJ, '--body', '"sneaky rewrite"');
isnt($rc_u2, 0, 'update: REFUSED once reviewing');
like($out_u2, qr/frozen/i, '...and the refusal explains why');
unlike(body_of($path), qr/sneaky rewrite/, '...and the body is genuinely unchanged');

# ---- transitions -----------------------------------------------------------
my ($rc_bad, $out_bad) = run('set-status', $id, '--project', $PROJ, '--to', 'resolved');
isnt($rc_bad, 0, 'reviewing -> resolved is refused (no skipping taken)');
like($out_bad, qr/not a legal transition/, '...and names the legal targets');

my ($rc_x) = run('set-status', $id, '--project', $PROJ, '--to', 'nonsense');
isnt($rc_x, 0, 'an unknown state is refused');

is((run('set-status', $id, '--project', $PROJ, '--to', 'taken'))[0], 0, 'reviewing -> taken');
ok(defined field_of($path, 'taken_at'), 'taken stamps taken_at');
is((run('set-status', $id, '--project', $PROJ, '--to', 'resolved', '--note', '"fixed in abc123"'))[0], 0,
   'taken -> resolved');
is(field_of($path, 'resolution'), 'fixed in abc123', 'the resolution note is recorded');

my ($rc_term) = run('set-status', $id, '--project', $PROJ, '--to', 'taken');
isnt($rc_term, 0, 'resolved is TERMINAL — no transitions out of it');

# ---- hand-back unfreezes ---------------------------------------------------
# A reviewer who wants more from the filer must be able to give the report back,
# or "frozen" becomes a trap rather than a guarantee.
{
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"second"', '--body', '"b"');
    chomp(my $p2 = $o); my ($id2) = $p2 =~ m{/([^/]+)\.md$};
    run('set-status', $id2, '--project', $PROJ, '--to', 'reviewing');
    is((run('set-status', $id2, '--project', $PROJ, '--to', 'open'))[0], 0, 'reviewing -> open hands it back');
    is(field_of($p2, 'content_sha256'), undef, 'handing back CLEARS the digest');
    is((run('update', $id2, '--project', $PROJ, '--body', '"more detail"'))[0], 0,
       '...and the filer can edit again');
}

# ---- tamper detection: the layer that cannot be routed around --------------
{
    my (undef, $o) = run('file', '--project', $PROJ, '--title', '"third"', '--body', '"original body"');
    chomp(my $p3 = $o); my ($id3) = $p3 =~ m{/([^/]+)\.md$};
    run('set-status', $id3, '--project', $PROJ, '--to', 'reviewing');

    is((run('verify', '--project', $PROJ))[0], 0, 'verify: clean while nothing has been tampered with');

    # Write straight past the script and the hook, the way a determined Bash
    # call would. Neither can stop this; the digest is what catches it.
    open my $fh, '<:raw', $p3 or die; local $/; my $raw = <$fh>; close $fh;
    $raw =~ s/original body/tampered body/;
    open my $w, '>:raw', $p3 or die; print {$w} $raw; close $w;

    my ($rc_v, $out_v) = run('verify', '--project', $PROJ);
    isnt($rc_v, 0, 'verify: DETECTS an out-of-band edit to a frozen report');
    like($out_v, qr/TAMPERED/, '...and says so unmistakably');
    like((run('collect', '--project', $PROJ))[1], qr/TAMPERED|!!/,
         'collect: surfaces the integrity failure too');
}

# ---- listing ---------------------------------------------------------------
{
    my (undef, $l) = run('list', '--project', $PROJ);
    like($l, qr/judge deadlocks/, 'list: shows this project\'s reports');
    my (undef, $lj) = run('list', '--project', $PROJ, '--json');
    my $parsed = eval { JSON::PP->new->decode($lj) };
    ok(ref $parsed eq 'ARRAY', 'list --json: emits a JSON array');
    my (undef, $lo) = run('list', '--project', $PROJ, '--status', 'open');
    unlike($lo, qr/judge deadlocks/, 'list --status open: filters out the resolved one');

    # collect always includes the CURRENT project even when it is not in the
    # registry — a report filed from an unregistered project must still be
    # visible to the person standing in it. Cross-project discovery is covered
    # by the registry block below.
    my (undef, $c) = run('collect', '--project', $PROJ);
    like($c, qr/judge deadlocks/, 'collect: includes the current project unconditionally');
}

# ---- discovery: the registry, not an index, and not glob -------------------
#
# The first design kept an append-only index under the writer's $HOME. That is
# broken for the primary filer: inside a sandbox, $HOME/.claude IS the project's
# own claude-home (bind-mounted at /root/.claude), so the index write lands in
# that one project and never reaches the host — the machine-wide index would
# silently miss exactly the reports it exists to collect. Discovery now walks
# steward's machine-local project registry, the same one /steward:backup uses.
{
    my $HOME2 = tempdir(CLEANUP => 1);
    my $P1 = tempdir(CLEANUP => 1);
    my $P2 = tempdir(CLEANUP => 1);
    # A path with a SPACE. Perl's built-in glob splits its argument on
    # whitespace, so "/…/Personal Files/Job search/…" came back as fragments and
    # the directory was never read. Two of this machine's registered projects
    # have spaces, so this silently missed real reports.
    my $P3 = "$P2/proj with spaces";
    mkdir $P3 or die;

    my $reg = "$HOME2/.claude/claude-code-vault";
    for my $d ("$HOME2/.claude", $reg) { mkdir $d or die "mkdir $d: $!" }
    open my $rf, '>:raw', "$reg/.registry-local.json" or die;
    print {$rf} JSON::PP->new->canonical->encode({ version => 1, projects => {
        one     => { path => $P1 },
        spaced  => { path => $P3 },
    }});
    close $rf;

    my $run2 = sub {
        my (@a) = @_;
        my $c = qq{ALMANAC_HOME="$HOME2" perl "$A" } . join(' ', @a) . ' 2>&1';
        my $o = `$c`; return ($? >> 8, $o // '');
    };

    $run2->('file', '--project', qq{"$P1"}, '--title', '"in project one"', '--body', '"b"');
    $run2->('file', '--project', qq{"$P3"}, '--title', '"in the spaced project"', '--body', '"b"');

    my (undef, $out2) = $run2->('collect');
    like($out2, qr/in project one/,
         'collect finds a report via the registry, with no index anywhere');
    like($out2, qr/in the spaced project/,
         'collect finds one in a project whose PATH CONTAINS A SPACE (glob split these away)');

    # And nothing was written outside the projects themselves.
    ok(!-e "$HOME2/.claude/almanac", 'no index directory is created under $HOME');
    ok(!-e "$HOME2/.claude/ccpraxis/bug-index.jsonl", 'nothing is written into the live install');
}

done_testing();
