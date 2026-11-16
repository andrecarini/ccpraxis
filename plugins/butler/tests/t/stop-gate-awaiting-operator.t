#!/usr/bin/env perl
# platform: any
# The Stop gate and a session waiting only on the operator (bug
# 20261116-130711-f800).
#
# 2026-11-13..16: a supervising session waited 62 hours for the operator to
# answer two inbox items. Nothing could progress without the operator, yet
# continuity was on and the gate forced a hold cycle: 239 wake-ups for
# nothing. Operator ruling 2026-11-16: continuity is on while there is work to
# do and off when there is none; everything left waiting on the operator is no
# work left, the same as all work done.
#
# The fix (G8d decides, G11a acts): when the session's own almanac thread has
# no task `doing` and at least one task `blocked` on an unanswered inbox item
# (in the thread's project, or in another project of steward's registry), and
# no subagent runs, the gate DENIES with a handoff text modelled on the
# far-pause branch: the items named, the off with a gate-minted reason, a
# TaskStop line for watchers, a Handoff line. Continuity stays armed until the
# session runs off. The gate writes an offer record the disarm judge checks,
# and the evidence digest reads each named item's live status. The judge
# contract carries the matching approve rule.
#
# AO1  same-project unanswered item: handoff text, armed, record, logged
# AO2  the item lives in another REGISTERED project: handoff names it
# AO3  a stray background task does not block the offer; TaskStop names it
# AO4  a legacy `decision` store item counts like an inbox one
# AO5  each Stop replaces the session's previous offer record
# DN1  a task `doing` on the thread: ordinary text with the hint
# DN2  the item is answered: ordinary text
# DN3  blocked_on resolves nowhere: ordinary text
# DN4  the item is only in an UNREGISTERED project: ordinary text
# DN5  the session has no thread: hint has a <thread> placeholder
# DN6  a running subagent blocks the offer: running text with the hint
# DN7  a task blocked with no blocked_on: ordinary text
# DN8  a task naming an item but not marked blocked: ordinary text
# DG   the disarm digest shows each offered item's live status, wherever it is
# JC   bp-disarm-judge.md pins the approve rule for this off
#
# In-process: BpHook::StopGate::run against temp state, data, project and
# home dirs. Never touches the real ~/.claude.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
(my $A = "$Bin/../../../almanac/scripts") =~ s{\\}{/}g;
my $AGENT_MD = "$Bin/../../agents/bp-disarm-judge.md";

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_|BUTLER_|ALMANAC_)/ } keys %ENV;
my $HOME_TMP = tempdir(CLEANUP => 1);
($ENV{HOME} = "$HOME_TMP/decoy-home") =~ s{\\}{/}g;
$ENV{USERPROFILE} = $ENV{HOME};
$ENV{ALMANAC_HOME} = $ENV{HOME};
make_path($ENV{HOME});

require "$S/BpHook.pm";
require "$S/BpHook/StopGate.pm";
{
    local @INC = ($A, @INC);
    require Almanac::Thread;
    require "$A/almanac-inbox.pl";
}

my $SEQ = 0;

sub slurp {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

sub spew {
    my ($p, $c) = @_;
    open(my $fh, '>:raw', $p) or die "write $p: $!";
    print {$fh} $c;
    close $fh;
}

sub new_project {
    my ($name) = @_;
    my $t = tempdir(CLEANUP => 1);
    (my $root = "$t/$name") =~ s{\\}{/}g;
    make_path("$root/.ccpraxis-local-data");
    return $root;
}

# Registers project roots in steward's machine-local registry, the one
# `almanac bug collect` and /pending walk.
sub register {
    my (@roots) = @_;
    my $dir = "$ENV{HOME}/.claude/claude-code-vault";
    make_path($dir);
    my %p = map { ('slug' . (++$SEQ)) => { path => $_ } } @roots;
    spew("$dir/.registry-local.json", JSON::PP->new->utf8->canonical->encode({ projects => \%p }));
}

sub world {
    my (%o) = @_;
    my $t = tempdir(CLEANUP => 1);
    (my $state = "$t/state") =~ s{\\}{/}g;
    my $proj = new_project('proj');
    my $tp = "$t/transcript.jsonl";
    spew($tp, qq({"type":"user","message":{"role":"user","content":"start"}}\n));
    my $sid = 'ao-' . (++$SEQ);
    my $w = { state => $state, proj => $proj, data => "$proj/.ccpraxis-local-data", tp => $tp, sid => $sid };
    with_env($w, sub { BpHook::arm($sid, role => 'manual', by => 'arm-on-entry') or die 'arm failed' });
    unless ($o{no_thread}) {
        Almanac::Thread::create_thread('supervise', owner_kind => 'session', owner_id => $sid,
            actor => 'session', root => $proj);
        $w->{thread} = 'supervise';
    }
    return $w;
}

sub with_env {
    my ($w, $code) = @_;
    local $ENV{BUTLER_STATE_DIR}  = $w->{state};
    local $ENV{CCPRAXIS_DATA_DIR} = $w->{data};
    return $code->();
}

sub inbox_item {
    my ($root, %o) = @_;
    my $rec = Almanac::Inbox::file(title => $o{title} // 'which way?', root => $root);
    Almanac::Inbox::answer($rec->{id}, answer => 'that way', root => $root) if $o{answered};
    return $rec->{id};
}

sub task {
    my ($w, %o) = @_;
    my $t = Almanac::Thread::add_task($w->{thread}, title => $o{title} // 'a step', actor => 'session',
        root => $w->{proj}, (defined $o{blocked_on} ? (blocked_on => $o{blocked_on}) : ()));
    Almanac::Thread::set_task_status($w->{thread}, $t->{id}, $o{status}, actor => 'session', root => $w->{proj})
        if defined $o{status} && $o{status} ne 'pending';
    return $t->{id};
}

sub stop {
    my ($w, %extra) = @_;
    my %p = (session_id => $w->{sid}, hook_event_name => 'Stop',
             stop_hook_active => JSON::PP::false(), cwd => $w->{proj}, transcript_path => $w->{tp});
    $p{background_tasks} = $extra{background_tasks} if $extra{background_tasks};
    my (undef, $epath) = tempfile();
    open(my $saved, '>&', \*STDERR) or die;
    close STDERR;
    open(STDERR, '>', $epath) or die;
    my $rc = with_env($w, sub { eval { BpHook::StopGate::run(\%p) } });
    my $died = $@;
    close STDERR;
    open(STDERR, '>&', $saved) or die;
    my $err = slurp($epath);
    unlink $epath;
    diag("run died: $died") if $died;
    my ($tok) = $err =~ /Stop token: ([0-9a-f]{8})/;
    return { rc => (defined $rc && $rc == 2 ? 2 : 0), err => $err, token => $tok };
}

sub armed   { my ($w) = @_; return with_env($w, sub { BpHook::is_armed($w->{sid}) }) }
sub reasons { my ($w) = @_; return slurp("$w->{state}/continuity/reasons.log") }
sub offer_dir { my ($w) = @_; return "$w->{data}/butler-awaiting-operator" }
sub offers {
    my ($w) = @_;
    opendir(my $dh, offer_dir($w)) or return ();
    my @f = sort grep { /\A[0-9a-f]{8}\.json\z/ } readdir $dh;
    closedir $dh;
    return @f;
}
sub offer {
    my ($w, $t) = @_;
    return undef unless defined $t;
    my $raw = slurp(offer_dir($w) . "/$t.json");
    return length $raw ? eval { JSON::PP->new->utf8->decode($raw) } : undef;
}

my $HANDOFF = qr/everything left waits on the operator/;
my $HINT    = qr/Waiting only on the operator\? That is no work left; never hold for it/;

register();    # an empty registry to start with

# ===========================================================================
# AO1 -- the incident: every remaining step waits on the operator.
# ===========================================================================
{
    my $w = world();
    my $id = inbox_item($w->{proj}, title => 'ship the redesign now?');
    my $tk = task($w, status => 'blocked', blocked_on => $id);
    task($w, title => 'done step', status => 'done');

    my $r = stop($w);
    is($r->{rc}, 2, 'AO1: the stop is refused: continuity must be turned off, not left on');
    ok(armed($w), 'AO1: and continuity stays armed until the session runs off');
    like($r->{err}, $HANDOFF, 'AO1: the handoff text says everything left waits on the operator');
    like($r->{err}, qr/task \Q$tk\E blocked on inbox item \Q$id\E/, 'AO1: naming the task and the inbox item');
    like($r->{err}, qr/^Handoff: the operator must answer inbox item \Q$id\E \("ship the redesign now\?"\); that answer resumes the work\.$/m,
        'AO1: a Handoff line says what the operator must answer');
    like($r->{err}, qr/do not hold for it/, 'AO1: it says not to hold');
    unlike($r->{err}, qr/butler-hold/, 'AO1: and offers no hold command');
    my $t = $r->{token};
    ok(defined $t, 'AO1: a stop token is printed');
    like($r->{err}, qr/^  butler-continuity off --reason 'awaiting operator, offer \Q$t\E: \Q$id\E' --token \Q$t\E$/m,
        'AO1: the off command carries the gate-minted reason and the token');
    like($r->{err}, qr/off-confirm/, 'AO1: and names the two-step off');
    like($r->{err}, qr/TaskStop/, 'AO1: it tells the session to stop its watchers');
    like($r->{err}, qr/^End your turn with the Handoff line above\.$/m, 'AO1: and to end with the Handoff line');

    my $doc = offer($w, $t);
    ok(ref $doc eq 'HASH', 'AO1: an offer record is written under the project data dir, named by the token');
    is($doc->{reason}, "awaiting operator, offer $t: $id", 'AO1: the record carries the exact reason');
    is($doc->{session_id}, $w->{sid}, 'AO1: and the session');
    like($doc->{valid_until_utc} // '', qr/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, 'AO1: and a validity window');
    is($doc->{items}[0]{id}, $id, 'AO1: the record names the item');
    like($doc->{items}[0]{path} // '', qr{/\.ccpraxis-local-data/almanac/inbox/\Q$id\E\.md\z}, 'AO1: with its inbox file path');
    is_deeply($doc->{items}[0]{tasks}, [$tk], 'AO1: and the task blocked on it');

    my @l = grep { /\tawaiting-operator\t/ } split /\n/, reasons($w);
    is(scalar(@l), 1, 'AO1: reasons.log has one awaiting-operator line');
    like($l[0] // '', qr/\tgate\tawaiting-operator\t.*\Q$tk\E.*\Q$id\E/, 'AO1: logged by the gate, naming task and item');

    # DG -- the digest reads the item's live state from its file.
    my $dg = `perl "$S/bp-disarm-digest.pl" "$w->{proj}" 2>&1`;
    like($dg, qr/^## Awaiting-operator offers .*\(\d+\)$/m, 'DG: the digest has an awaiting-operator offers section');
    like($dg, qr/reason: awaiting operator, offer \Q$t\E: \Q$id\E/, 'DG: naming the offer and its reason');
    like($dg, qr/item \Q$id\E \[now: unanswered\]/, 'DG: and the item as unanswered now');

    Almanac::Inbox::answer($id, answer => 'go', root => $w->{proj});
    my $dg2 = `perl "$S/bp-disarm-digest.pl" "$w->{proj}" 2>&1`;
    like($dg2, qr/item \Q$id\E \[now: answered\]/, 'DG: once answered, the digest says so (the judge must reject)');

    my $r2 = stop($w);
    is($r2->{rc}, 2, 'AO1: once the operator answers, the stop is refused as before');
    unlike($r2->{err}, $HANDOFF, 'AO1: with the ordinary text, not the handoff');
    is(scalar(my @none = offers($w)), 0, 'AO1: and the stale offer record is swept');
}

# ===========================================================================
# AO2 / DN4 -- the item lives in another project.
# ===========================================================================
{
    my $w = world();
    my $other = new_project('acx');
    my $id = inbox_item($other);
    task($w, status => 'blocked', blocked_on => $id);

    my $r = stop($w);
    is($r->{rc}, 2, 'DN4: an item only in an UNREGISTERED project: refused');
    unlike($r->{err}, $HANDOFF, 'DN4: with the ordinary text');
    like($r->{err}, $HINT, 'DN4: which carries the hint');

    register($w->{proj}, $other);
    my $r2 = stop($w);
    like($r2->{err}, $HANDOFF, 'AO2: an unanswered item in another REGISTERED project gets the handoff');
    like($r2->{err}, qr/^Handoff: the operator must answer inbox item \Q$id\E .* in \S*acx;/m, 'AO2: the Handoff names its project');
    my $doc = offer($w, $r2->{token});
    like($doc->{items}[0]{path} // '', qr{acx/\.ccpraxis-local-data/almanac/inbox/\Q$id\E\.md\z}, 'AO2: the record points at the other project\'s file');
    my @l = grep { /\tawaiting-operator\t/ } split /\n/, reasons($w);
    like($l[-1] // '', qr/\Q$id\E \(in [^)]*acx\)/, 'AO2: the log names the project holding the item');

    my $dg = `perl "$S/bp-disarm-digest.pl" "$w->{proj}" 2>&1`;
    like($dg, qr/item \Q$id\E \[now: unanswered\]/, 'DG: the digest reads the other project\'s item');

    # A hand-made record pointing at a file that is not an inbox item.
    make_path(offer_dir($w));
    my $fake = offer_dir($w) . '/0badc0de.json';
    spew($fake, JSON::PP->new->utf8->encode({ offer => '0badc0de', reason => 'x', valid_until_utc => 'x',
        items => [ { id => '20261116-000000-beef', path => "$w->{proj}/notes.md" } ] }));
    spew("$w->{proj}/notes.md", "---\nstatus: unanswered\n---\n");
    my $dg2 = `perl "$S/bp-disarm-digest.pl" "$w->{proj}" 2>&1`;
    like($dg2, qr/item 20261116-000000-beef \[now: not an inbox item file\]/, 'DG: a path outside an inbox store is not trusted');

    Almanac::Inbox::answer($id, answer => 'go', root => $other);
    unlike(stop($w)->{err}, $HANDOFF, 'AO2: answered over there: ordinary text again');
    register();
}

# ===========================================================================
# AO3 -- a stray background task does not block the offer.
# ===========================================================================
{
    my $w = world();
    task($w, status => 'blocked', blocked_on => inbox_item($w->{proj}));
    my $r = stop($w, background_tasks => [ { id => 'bwatch1', type => 'shell', status => 'running' } ]);
    is($r->{rc}, 2, 'AO3: refused');
    like($r->{err}, $HANDOFF, 'AO3: a running background task (not a subagent) still gets the handoff');
    like($r->{err}, qr/TaskStop tool \(bwatch1\)/, 'AO3: and the TaskStop line names the watcher');
    unlike($r->{err}, qr/butler-hold/, 'AO3: no hold is offered for it');
}

# ===========================================================================
# AO4 -- a not-yet-migrated legacy `decision` store counts too.
# ===========================================================================
{
    my $w = world();
    my $store = Almanac::Store->open(scope => 'project', type => 'decision', root => $w->{proj});
    my $rec = $store->create(fields => { title => 'old q', status => 'unanswered', created => '2026-11-01T00:00:00Z' },
                             order => [qw(title status created)]);
    task($w, status => 'blocked', blocked_on => $rec->{id});
    like(stop($w)->{err}, $HANDOFF, 'AO4: an unanswered item in the legacy decision store counts');
}

# ===========================================================================
# AO5 -- one live record per session.
# ===========================================================================
{
    my $w = world();
    task($w, status => 'blocked', blocked_on => inbox_item($w->{proj}));
    my $t1 = stop($w)->{token};
    my $t2 = stop($w)->{token};
    isnt($t1, $t2, 'AO5: each refusal mints a fresh token');
    is_deeply([ offers($w) ], ["$t2.json"], 'AO5: only the latest offer record survives');
}

# ===========================================================================
# DN -- not only waiting on the operator.
# ===========================================================================
{
    my $w = world();
    task($w, status => 'blocked', blocked_on => inbox_item($w->{proj}));
    task($w, title => 'still working', status => 'doing');
    my $r = stop($w);
    is($r->{rc}, 2, 'DN1: a task doing on the thread: refused');
    ok(armed($w), 'DN1: continuity on');
    unlike($r->{err}, $HANDOFF, 'DN1: no handoff');
    is(scalar(my @none = offers($w)), 0, 'DN1: no offer record');
    unlike(reasons($w), qr/\tawaiting-operator\t/, 'DN1: nothing logged as awaiting-operator');
    like($r->{err}, $HINT, 'TXT: the idle text carries the hint');
    like($r->{err}, qr/^  almanac thread status supervise <task> blocked; almanac thread edit supervise <task> --blocked-on <inbox-id>$/m,
        'TXT: naming the session\'s own thread and the exact commands');
    like($r->{err}, qr/end the turn, and the gate offers the off:$/m, 'TXT: pointing at the off path');
    my @l = split /\n/, $r->{err};
    is(scalar(@l), 8, 'TXT: the idle text stays at Decision 8\'s 8 lines');
    is_deeply([ grep { length($_) > 160 } @l ], [], 'TXT: every line within 160 characters');
}
{
    # A 64-character thread name would push the command line past 160: the
    # hint falls back to the <thread> placeholder rather than overflow.
    my $w = world(no_thread => 1);
    my $long = 'a' x 64;
    Almanac::Thread::create_thread($long, owner_kind => 'session', owner_id => $w->{sid}, actor => 'session', root => $w->{proj});
    my $r = stop($w);
    like($r->{err}, qr/^  almanac thread status <thread> <task> blocked;/m, 'TXT: an over-long thread name falls back to <thread>');
    is_deeply([ grep { length($_) > 160 } split /\n/, $r->{err} ], [], 'TXT: still within 160 characters');
}
{
    my $w = world();
    task($w, status => 'blocked', blocked_on => inbox_item($w->{proj}, answered => 1));
    unlike(stop($w)->{err}, $HANDOFF, 'DN2: the item is answered: no handoff');
}
{
    my $w = world();
    task($w, status => 'blocked', blocked_on => '20261116-000000-dead');
    my $r = stop($w);
    is($r->{rc}, 2, 'DN3: blocked_on resolving to no inbox item anywhere: refused');
    unlike($r->{err}, $HANDOFF, 'DN3: no handoff');
}
{
    my $w = world(no_thread => 1);
    my $r = stop($w);
    is($r->{rc}, 2, 'DN5: no thread: refused');
    like($r->{err}, qr/almanac thread status <thread> <task> blocked/, 'DN5: the hint uses a <thread> placeholder');
}
{
    my $w = world();
    task($w, status => 'blocked', blocked_on => inbox_item($w->{proj}));
    my $r = stop($w, background_tasks => [ { id => 'agentx1', type => 'subagent', status => 'running' } ]);
    is($r->{rc}, 2, 'DN6: a running subagent: refused');
    unlike($r->{err}, $HANDOFF, 'DN6: a running subagent blocks the handoff');
    like($r->{err}, qr/work is still running: agentx1/, 'DN6: the running text names it');
    like($r->{err}, $HINT, 'TXT: the running-work text carries the hint too');
}
{
    my $w = world();
    task($w, status => 'blocked');
    unlike(stop($w)->{err}, $HANDOFF, 'DN7: a task blocked on nothing named: no handoff');
}
{
    my $w = world();
    task($w, status => 'pending', blocked_on => inbox_item($w->{proj}));
    unlike(stop($w)->{err}, $HANDOFF, 'DN8: a task naming an item but not marked blocked: no handoff');
}

# ===========================================================================
# JC -- the disarm judge's contract pins the approve rule for this off.
# ===========================================================================
{
    my $src = slurp($AGENT_MD);
    ok(length $src, 'JC setup: bp-disarm-judge.md is readable');
    like($src, qr/Everything left waiting on the operator justifies going off, the same as "all the work is\s+done"/,
        'JC: waiting only on the operator is a justified off, the same as all work done');
    like($src, qr/genuinely the operator's, and nothing else in the session's goal can progress/,
        'JC: the rule names both conditions');
    like($src, qr/awaiting operator, offer <id>: <item-id>, <item-id>/, 'JC: the reason shape the gate mints');
    like($src, qr{\.ccpraxis-local-data/butler-awaiting-operator/<id>\.json}, 'JC: the offer record path');
    like($src, qr/Verify, never trust the claim/, 'JC: the judge must verify, not trust');
    like($src, qr/\[now: unanswered\]/, 'JC: it checks the digest\'s live status of every item');
    like($src, qr/not a technical question the session could settle itself/, 'JC: and that the item is genuinely the operator\'s');
    my @lines = split /\n/, $src;
    my %pinned = (2 => 'name: bp-disarm-judge', 4 => 'model: sonnet', 5 => 'effort: medium',
                  6 => 'maxTurns: 400', 7 => 'tools: Read, Grep, Glob, Bash');
    for my $ln (sort { $a <=> $b } keys %pinned) {
        (my $got = $lines[$ln - 1] // '') =~ s/\r\z//;
        is($got, $pinned{$ln}, "JC: frontmatter line $ln unchanged");
    }
}

done_testing();
