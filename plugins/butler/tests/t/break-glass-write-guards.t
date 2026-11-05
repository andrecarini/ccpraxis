#!/usr/bin/env perl
# platform: any
# No butler (or almanac) write guard refuses the Stop gate's break-glass file.
#
# Operator ruling 2026-11-05: break-glass is the exit for a tooling defect and
# is always honoured. The Stop gate asks for the file to be created with the
# Write tool at <data>/butler-break-glass/<session>.json (or, with no project
# data dir, <state>/break-glass/<session>.json). Before this fix the writes
# guard refused it to every subagent whose package write set did not cover it
# (bound, sole, refused, refused_bound, exempt_reports): the file is under the
# project root, so it fell through to the write-set check.
#
# WG1  may_write allows the session's own break-glass file for the driver and
#      for every subagent kind
# WG2  and only that file: another session's file, a sibling name, a nested
#      path, and the bare directory keep their old verdict
# WG3  the real Write-matching hook wrappers (writes, ledger, blueprint-write,
#      continuity-state, gate-shutdown, almanac-write) exit 0 for both
#      break-glass paths, armed or not, from the main session or a subagent,
#      with prefilter words (blueprint, continuity, packages) in the payload
#
# Every state root is a fresh temp dir; HOME/USERPROFILE are decoys.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP ();

(my $BUTLER = "$Bin/../..") =~ s{\\}{/}g;
(my $PLUGINS = "$Bin/../../..") =~ s{\\}{/}g;
my $S = "$BUTLER/scripts";

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_|BUTLER_)/ } keys %ENV;
my $TMP = tempdir(CLEANUP => 1);
$TMP =~ s{\\}{/}g;
$ENV{HOME} = $ENV{USERPROFILE} = "$TMP/decoy-home";
$ENV{ALMANAC_HOME} = $ENV{HOME};
make_path($ENV{HOME});

unshift @INC, $S;
require "$S/BpHook.pm";
require "$S/BpHook/WriteGuards.pm";

my $J = JSON::PP->new->utf8->canonical;

# ===========================================================================
# WG1 / WG2 -- the pure verdict, over every resolve() shape that has a data dir.
# ===========================================================================
my $root = '/c/wgproj';
my $data = "$root/.ccpraxis-local-data";
my $SID  = 'wg-11111111-2222';
my $P1 = { package => '01-x', blueprint => 'bpx', bpdir => "$data/blueprints/bpx",
           ledger => "$data/blueprints/bpx/packages/01-x.md", write_set => 'src/**', test_paths => 't/**' };

sub R {
    my ($mode, $kind, %o) = @_;
    return {
        mode => $mode, kind => $kind, root => $root, data => $data,
        allow_dirs => $o{allow_dirs} // [], deny_dirs => $o{deny_dirs} // [],
        packages => $o{packages} // [ $P1 ], worker => $o{worker} // '',
        actor => $mode, agent_type => '', inflight => $o{inflight} // 1,
        bound => $o{bound},
    };
}

my %SHAPES = (
    'driver single'           => R('driver', 'single', allow_dirs => [ $data ],
                                   deny_dirs => [ "$data/.drive-solo", "$data/.subagent-guard", "$data/claude-home", "$data/bug-reports" ]),
    'subagent bound'          => R('subagent', 'bound', allow_dirs => [ $P1->{bpdir} ]),
    'subagent sole'           => R('subagent', 'sole', allow_dirs => [ $P1->{bpdir} ]),
    'subagent bound test-writer' => R('subagent', 'bound', allow_dirs => [ $P1->{bpdir} ], worker => 'bp-test-writer'),
    'subagent refused'        => R('subagent', 'refused', inflight => 2),
    'subagent refused_bound'  => R('subagent', 'refused_bound', packages => [], bound => { blueprint => 'bpx', package => '01-x' }),
    'subagent exempt_reports' => R('subagent', 'exempt_reports', packages => []),
);

my $own = "$data/butler-break-glass/$SID.json";
for my $name (sort keys %SHAPES) {
    my $v = BpHook::WriteGuards::may_write($SHAPES{$name}, $own, { session_id => $SID });
    ok($v->{allow}, "WG1 ($name): the session's own break-glass file is allowed")
        or diag(join(' | ', @{ $v->{lines} || [] }));
}
{
    # Windows form of the same path, as the gate prints it (C:/...).
    my $v = BpHook::WriteGuards::may_write($SHAPES{'subagent refused'}, "C:/wgproj/.ccpraxis-local-data/butler-break-glass/$SID.json",
                                           { session_id => $SID });
    ok($v->{allow}, 'WG1: the drive-letter form the gate prints is allowed too');
}

for my $case (
    [ 'another session\'s file', "$data/butler-break-glass/wg-other.json" ],
    [ 'a sibling name',          "$data/butler-break-glass/$SID.json.bak" ],
    [ 'a nested path',           "$data/butler-break-glass/x/$SID.json" ],
    [ 'the directory itself',    "$data/butler-break-glass" ],
    [ 'another data-dir file',   "$data/notes.md" ],
) {
    my ($label, $path) = @$case;
    for my $name ('subagent refused', 'subagent bound', 'subagent exempt_reports') {
        my $v = BpHook::WriteGuards::may_write($SHAPES{$name}, $path, { session_id => $SID });
        ok(!$v->{allow}, "WG2 ($name): $label is still refused");
    }
}
{
    my $v = BpHook::WriteGuards::may_write($SHAPES{'subagent refused'}, $own, { session_id => 'wg-someone-else' });
    ok(!$v->{allow}, 'WG2: the file named for a different session than the payload\'s is still refused');
    my $c = BpHook::WriteGuards::may_write({ %{ $SHAPES{'subagent bound'} }, data => undef }, $own, { session_id => $SID });
    ok(!$c->{allow}, 'WG2: with no data dir (the coordinator shape) nothing is exempted');
}

# ===========================================================================
# WG3 -- the real wrappers, end to end.
# ===========================================================================
my $BASH = do { my $p = `bash -c "command -v bash"`; chomp $p; $p };
BAIL_OUT('cannot resolve bash') unless length $BASH;

my @HOOKS = (
    "$BUTLER/hooks/guard-writes.sh",
    "$BUTLER/hooks/ledger-guard.sh",
    "$BUTLER/hooks/guard-blueprint-write.sh",
    "$BUTLER/hooks/guard-continuity-state.sh",
    "$BUTLER/hooks/gate-shutdown.sh",
    "$PLUGINS/almanac/hooks/guard-almanac-write.sh",
);
ok(-f $_, "WG3 setup: $_ exists") for @HOOKS;

my $state = "$TMP/state";
my $proj  = "$TMP/project";
my $pdata = "$proj/.ccpraxis-local-data";
make_path($pdata, $state);
my $sid = 'wg-' . sprintf('%08x', int(rand(0xffffffff)));

sub run_hook {
    my ($hook, $payload) = @_;
    my ($pfh, $pp) = tempfile(DIR => $TMP);
    binmode $pfh;
    print {$pfh} $J->encode($payload);
    close $pfh;
    my (undef, $op) = tempfile(DIR => $TMP);
    my (undef, $ep) = tempfile(DIR => $TMP);
    local $ENV{BUTLER_STATE_DIR}  = $state;
    local $ENV{CCPRAXIS_DATA_DIR} = $pdata;
    local $ENV{CLAUDE_PLUGIN_ROOT} = $BUTLER;
    system(qq{timeout 30 "$BASH" "$hook" < "$pp" > "$op" 2> "$ep"});
    my $rc = $? >> 8;
    open(my $fh, '<:raw', $ep);
    local $/;
    my $err = <$fh> // '';
    close $fh;
    return ($rc, $err);
}

my $content = $J->encode({ token => 'deadbeef', action => 'off',
    reason => 'off-confirm refused by a permission check; both blueprints and packages done, continuity stuck' });

for my $armed (0, 1) {
    if ($armed) {
        local $ENV{BUTLER_STATE_DIR} = $state;
        BpHook::arm($sid, role => 'manual', by => 'arm-on-entry') or die 'arm failed';
    }
    (my $state_bg = "$state/continuity/break-glass/$sid.json");
    for my $path ("$pdata/butler-break-glass/$sid.json", $state_bg) {
        for my $agent (undef, 'a0123456789abcdef') {
            my $payload = {
                session_id => $sid, hook_event_name => 'PreToolUse', tool_name => 'Write',
                tool_input => { file_path => $path, content => $content },
                cwd => $proj, transcript_path => "$TMP/transcript.jsonl",
                (defined $agent ? (agent_id => $agent, agent_type => 'general-purpose') : ()),
            };
            my $who = (defined $agent ? 'a subagent' : 'the main session') . ($armed ? ', armed' : ', unarmed')
                    . ($path eq $state_bg ? ', state-dir path' : ', data-dir path');
            for my $hook (@HOOKS) {
                (my $hn = $hook) =~ s{.*/}{};
                my ($rc, $err) = run_hook($hook, $payload);
                is($rc, 0, "WG3 ($hn, $who): the break-glass Write is not refused") or diag($err);
            }
        }
    }
}

done_testing();
