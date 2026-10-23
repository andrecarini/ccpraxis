#!/usr/bin/env perl
# platform: any
# ORACLE for blueprint judged-continuity-disarm, package 03-disarm-judge
# (specs/03-disarm-judge-spec.md sec 2.5, acceptance AC9-AC12).
#
# plugins/butler/hooks/guard-disarm-judge-readonly.sh DOES NOT EXIST YET.
# Every scenario below runs it as a real bash subprocess (never required
# in-process), via the shared GuardHarness rig the sibling guards-remake-*.t
# files already use. Until the file exists, GuardHarness's run_wrapper/
# run_shim surface that as a plain bash "No such file or directory", rc
# 127 -- a legible, non-crashing red, never a Perl error in this file.
#
# DC7: this file never spawns a real `claude`; the guard itself never spawns
# anything (it is a pure bash+perl decision, no judge dispatch happens
# here at all).
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use JSON::PP ();
use POSIX ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;
GuardHarness::isolate_env();

my $HOOK = 'guard-disarm-judge-readonly.sh';
(my $BUTLER_DIR = dirname(__FILE__) . '/../..') =~ s{\\}{/}g;
my $HOOKS_JSON = "$BUTLER_DIR/hooks/hooks.json";

sub payload_for {
    my ($cmd) = @_;
    return JSON::PP->new->utf8->canonical->encode({
        hook_event_name => 'PreToolUse',
        tool_name       => 'Bash',
        tool_input      => { command => $cmd },
    });
}

# decode_one_json($text) -- the hook's contract is EXACTLY one JSON object on
# stdout plus "\n" (2.5.3). Returns (decoded_or_undef, extra_bytes_after).
sub decode_one_json {
    my ($text) = @_;
    return (undef, $text) unless defined $text && length $text;
    my $j = JSON::PP->new->utf8;
    my $decoded = eval { $j->decode($text) };
    return (undef, $text) unless defined $decoded;
    return ($decoded, '');
}

sub decision_of {
    my ($res) = @_;
    my ($doc, undef) = decode_one_json($res->{out});
    return undef unless ref $doc eq 'HASH';
    my $hso = $doc->{hookSpecificOutput};
    return undef unless ref $hso eq 'HASH';
    return $hso;
}

# ===========================================================================
# AC9: the 33-row worked-example table (spec sec 3 B15). Each row runs with
# CCPRAXIS_DISARM_JUDGE=1 and must produce exactly the listed decision, with
# exit 0, empty stderr, hookEventName PreToolUse, a reason starting
# "disarm judge:" and at most 160 characters.
# ===========================================================================
{
    my @rows = (
        [ 'git status',                                            'allow' ],
        [ 'git log --oneline -n 20',                                'allow' ],
        [ q{git log --grep='a;b|c'},                                'allow' ],
        [ q{perl '/p/Andre/almanac/scripts/almanac-bug.pl' list --json}, 'allow' ],
        [ 'perl /p/almanac/scripts/almanac-todo.pl list',           'allow' ],
        [ '/p/almanac/scripts/almanac-bug.pl list --status open',   'allow' ],
        [ 'rm -rf /tmp/x',                                          'deny'  ],
        [ 'git commit -m x',                                        'deny'  ],
        [ 'git push',                                               'deny'  ],
        [ 'perl /p/butler/scripts/bp-drive-next.pl next',           'deny'  ],
        [ 'perl /p/almanac/scripts/almanac-bug.pl file --title x',  'deny'  ],
        [ 'perl /p/almanac/scripts/almanac-todo.pl add x',          'deny'  ],
        [ 'git status; rm -rf /tmp/x',                              'deny'  ],
        [ 'git status && rm -rf /tmp/x',                            'deny'  ],
        [ 'git status || rm -rf /tmp/x',                            'deny'  ],
        [ 'git log | head',                                         'deny'  ],
        [ 'git status & rm -rf /tmp/x',                             'deny'  ],
        [ 'git log > /tmp/x',                                       'deny'  ],
        [ 'git log >> /tmp/x',                                      'deny'  ],
        [ "git status\nrm -rf /tmp/x",                              'deny'  ],
        [ 'git log $(rm -rf /tmp/x)',                                'deny'  ],
        [ 'git log `rm -rf /tmp/x`',                                 'deny'  ],
        [ 'git log <(rm -rf /tmp/x)',                                'deny'  ],
        [ 'git log "$HOME"',                                        'deny'  ],
        [ 'git log --output=/tmp/x',                                'deny'  ],
        [ 'git log --out=/tmp/x',                                   'deny'  ],
        [ 'git log -o /tmp/x',                                      'deny'  ],
        [ q{git log '--output=/tmp/x'},                              'deny'  ],
        [ 'git log -- *.md',                                        'deny'  ],
        [ 'git -C /x log',                                          'deny'  ],
        [ 'GIT_DIR=/x git log',                                     'deny'  ],
        [ q{perl -e 'unlink 1'},                                     'deny'  ],
        [ '',                                                        'deny'  ],
    );
    is(scalar(@rows), 33, 'AC9 sanity: this file\'s own B15 fixture table has 33 rows');

    for my $row (@rows) {
        my ($cmd, $want) = @$row;
        my $res = GuardHarness::run_wrapper($HOOK, payload_for($cmd), env => { CCPRAXIS_DISARM_JUDGE => 1 });
        my $label = length($cmd) ? $cmd : '(empty)';
        is($res->{rc}, 0, "AC9 [$label]: exit 0") or diag("err: $res->{err}");
        is($res->{err} // '', '', "AC9 [$label]: stderr is empty");
        my $hso = decision_of($res);
        ok(ref $hso eq 'HASH', "AC9 [$label]: stdout decodes to one hookSpecificOutput object")
            or diag("stdout: " . ($res->{out} // ''));
        if (ref $hso eq 'HASH') {
            is($hso->{hookEventName}, 'PreToolUse', "AC9 [$label]: hookEventName is PreToolUse");
            is($hso->{permissionDecision}, $want, "AC9 [$label]: permissionDecision is $want");
            my $reason = $hso->{permissionDecisionReason} // '';
            like($reason, qr/^disarm judge:/, "AC9 [$label]: reason starts with 'disarm judge:'");
            cmp_ok(length($reason), '<=', 160, "AC9 [$label]: reason is at most 160 characters");
        }
    }
}

# ===========================================================================
# AC10: CCPRAXIS_DISARM_JUDGE unset, and again '0' -- both rm -rf and git
# status give exit 0, empty stdout; with a PATH shim logging perl, zero
# perl launches either way.
# ===========================================================================
{
    for my $mode (undef, '0') {
        my %env = defined $mode ? (CCPRAXIS_DISARM_JUDGE => $mode) : (CCPRAXIS_DISARM_JUDGE => undef);
        for my $cmd ('rm -rf /tmp/x', 'git status') {
            my $res = GuardHarness::run_shim($HOOK, payload_for($cmd), env => { %env });
            my $tag = defined $mode ? "'$mode'" : 'unset';
            is($res->{rc}, 0, "AC10 [$cmd, CCPRAXIS_DISARM_JUDGE=$tag]: exit 0") or diag("err: $res->{err}");
            is($res->{out} // '', '', "AC10 [$cmd, CCPRAXIS_DISARM_JUDGE=$tag]: stdout is empty");
            is(GuardHarness::count_lines($res->{shim_log}, 'perl'), 0,
                "AC10 [$cmd, CCPRAXIS_DISARM_JUDGE=$tag]: zero perl launches");
        }
    }
}

# ===========================================================================
# AC11: through the hooks.json registration string itself (bash -c "<cmd>",
# CLAUDE_PLUGIN_ROOT set, CCPRAXIS_DISARM_JUDGE=1) -- same decisions as AC9
# for 'git status' (allow) and 'git status; rm -rf /tmp/x' (deny).
# ===========================================================================
{
    SKIP: {
        skip('hooks.json does not exist', 2) unless -f $HOOKS_JSON;
        open(my $fh, '<:raw', $HOOKS_JSON) or skip("cannot open hooks.json: $!", 2);
        local $/;
        my $raw = <$fh>;
        close $fh;
        my $doc = eval { JSON::PP->new->utf8->decode($raw) };
        skip('hooks.json does not parse', 2) unless ref $doc eq 'HASH';

        my $reg_cmd;
        OUTER: for my $event (keys %{ $doc->{hooks} // {} }) {
            for my $group (@{ $doc->{hooks}{$event} // [] }) {
                next unless ref $group eq 'HASH' && ($group->{matcher} // '') eq 'Bash';
                for my $h (@{ $group->{hooks} // [] }) {
                    next unless ref $h eq 'HASH';
                    if (($h->{command} // '') =~ /guard-disarm-judge-readonly\.sh/) {
                        $reg_cmd = $h->{command};
                        last OUTER;
                    }
                }
            }
        }
        skip('guard-disarm-judge-readonly.sh is not yet registered in hooks.json', 2) unless defined $reg_cmd;

        for my $case (['git status', 'allow'], ['git status; rm -rf /tmp/x', 'deny']) {
            my ($cmd, $want) = @$case;
            my (undef, $stdin_path) = File::Temp::tempfile();
            open(my $sfh, '>', $stdin_path) or die $!;
            print {$sfh} payload_for($cmd);
            close $sfh;
            my (undef, $out_path) = File::Temp::tempfile();
            my (undef, $err_path) = File::Temp::tempfile();

            (my $plugin_root = "$BUTLER_DIR") =~ s{\\}{/}g;
            local %ENV = %ENV;
            $ENV{CLAUDE_PLUGIN_ROOT}    = $plugin_root;
            $ENV{CCPRAXIS_DISARM_JUDGE} = 1;

            my $pid = fork();
            die "fork: $!" unless defined $pid;
            if ($pid == 0) {
                open(STDIN,  '<', $stdin_path) or POSIX::_exit(126);
                open(STDOUT, '>', $out_path)   or POSIX::_exit(126);
                open(STDERR, '>', $err_path)   or POSIX::_exit(126);
                exec('bash', '-c', $reg_cmd);
                POSIX::_exit(127);
            }
            waitpid($pid, 0);

            my $out = GuardHarness::read_bytes($out_path) // '';
            unlink $stdin_path, $out_path, $err_path;
            my ($doc2, undef) = decode_one_json($out);
            my $got = (ref $doc2 eq 'HASH' && ref $doc2->{hookSpecificOutput} eq 'HASH')
                ? $doc2->{hookSpecificOutput}{permissionDecision} : undef;
            is($got, $want, "AC11 [$cmd via hooks.json registration]: permissionDecision is $want")
                or diag("raw out: $out");
        }
    }
}

# ===========================================================================
# AC12: a malformed payload ("not json") with CCPRAXIS_DISARM_JUDGE=1 gives
# deny.
# ===========================================================================
{
    my $res = GuardHarness::run_wrapper($HOOK, 'not json', env => { CCPRAXIS_DISARM_JUDGE => 1 });
    is($res->{rc}, 0, 'AC12: malformed payload still exits 0') or diag("err: $res->{err}");
    my $hso = decision_of($res);
    ok(ref $hso eq 'HASH', 'AC12: stdout still decodes to one hookSpecificOutput object')
        or diag("stdout: " . ($res->{out} // ''));
    is(ref $hso eq 'HASH' ? $hso->{permissionDecision} : undef, 'deny',
        'AC12: a malformed payload denies');
}

done_testing();
