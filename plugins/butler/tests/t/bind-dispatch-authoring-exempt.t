#!/usr/bin/env perl
# platform: any
# Oracle for package 26-unbound-authoring-agents (blueprint hook-continuity-remake),
# Decision 98 / ledger .ccpraxis-local-data/blueprints/hook-continuity-remake/
# packages/26-unbound-authoring-agents.md Done criteria 1-3.
#
# BpHook::BindDispatch does NOT yet implement the allowlist exemption at the
# time this file is written -- every allow-side assertion below is expected
# to FAIL today (the dispatch will be denied like any other), while every
# deny-side assertion is expected to PASS today already (today's rule).
#
# WRITTEN BLIND TO THE IMPLEMENTATION: derived only from the ledger's Scope
# text above and the already-shipped package-12 dispatch-binding.t fixture
# idiom (payload()/bd()/write_inflight()/expected_deny_text(), reused here
# rather than imported, per that file's own "scaffolding is yours to write"
# convention -- this file does not require or read dispatch-binding.t).
#
# Allowlist under test (Decision 98, pinned exactly):
#   blueprint:bp-auditor, butler:bp-feedback-verifier, Explore, claude-code-guide
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname basename);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use Cwd ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

# ---------------------------------------------------------------------------
# Ambient isolation for the whole file, up front (binding lesson from
# dispatch-binding.t: isolate before any arm() call).
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;
GuardHarness::isolate_env();

my $J = JSON::PP->new->utf8->canonical;

# ---------------------------------------------------------------------------
# byte / JSON I/O helpers.
# ---------------------------------------------------------------------------
sub read_bytes {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub write_bytes {
    my ($path, $bytes) = @_;
    (my $dir = $path) =~ s{[/\\][^/\\]*\z}{};
    make_path($dir) if length($dir) && !-d $dir;
    open(my $fh, '>:raw', $path) or die "cannot write $path: $!";
    print {$fh} $bytes;
    close $fh;
}
sub read_json {
    my ($p) = @_;
    my $raw = read_bytes($p);
    return undef unless defined $raw;
    return eval { $J->decode($raw) };
}
sub write_json {
    my ($path, $data) = @_;
    write_bytes($path, $J->encode($data) . "\n");
}

# ---------------------------------------------------------------------------
# Fixture helpers for the .drive-solo/ area this hook reads/writes (mirrors
# dispatch-binding.t's own fresh_data/write_inflight/ledger_line idiom).
# ---------------------------------------------------------------------------
sub fresh_data {
    my $t = tempdir(CLEANUP => 1);
    (my $d = "$t/data") =~ s{\\}{/}g;
    make_path($d);
    return $d;
}

sub ledger_line {
    my ($data, $bp, $pkg) = @_;
    (my $b = $data) =~ s{\\}{/}g;
    $b =~ s{/+\z}{};
    my $L = basename($b);
    return "$L/blueprints/$bp/packages/$pkg.md";
}

sub write_inflight {
    my ($data, @members) = @_; # each { bp => ..., pkg => ... }
    make_path("$data/.drive-solo");
    write_json("$data/.drive-solo/inflight.json", {
        packages => [ map { { blueprint => $_->{bp}, package => $_->{pkg}, ledger => 'ignored-by-hook', since => 1 } } @members ],
        updated_at => 1,
    });
    # Bug 20261104-164548-2d3a: the hook no longer auto-binds a member whose
    # ledger is missing or terminal (BpState::inflight_unbindable), so every
    # member listed here gets a live ledger unless the case wrote its own.
    for my $m (@members) {
        my $lp = "$data/blueprints/$m->{bp}/packages/$m->{pkg}.md";
        next if -e $lp;
        make_path("$data/blueprints/$m->{bp}/packages");
        open(my $lfh, '>:raw', $lp) or die "cannot write $lp: $!";
        print {$lfh} "---\npackage: $m->{pkg}\nblueprint: $m->{bp}\nstatus: running\n"
                   . "write_set: src/$m->{pkg}/\n---\n";
        close $lfh;
    }
}

sub bindings_dir     { my ($data) = @_; return "$data/.drive-solo/bindings" }
sub bindings_history { my ($data) = @_; return "$data/.drive-solo/bindings.jsonl" }

sub binding_files {
    my ($data) = @_;
    my $d = bindings_dir($data);
    my @files = -d $d ? sort glob("$d/*.json") : ();
    return wantarray ? @files : scalar(@files);
}
sub history_lines {
    my ($data) = @_;
    my $raw = read_bytes(bindings_history($data));
    my @lines = defined $raw ? (grep { length } split /\n/, $raw) : ();
    return wantarray ? @lines : scalar(@lines);
}

# ---------------------------------------------------------------------------
# expected_deny_text($data, @members) -- today's B8 denial text for a member
# set in set order (package 12 spec sec 3, B8; $MAX_LISTED = 4).
# ---------------------------------------------------------------------------
sub expected_deny_text {
    my ($data, @members) = @_;
    my $n = scalar @members;
    my $MAX_LISTED = 4;
    my @lines = ("With $n packages in flight a dispatch prompt must name exactly one ledger path:");
    my $shown = $n > $MAX_LISTED ? $MAX_LISTED : $n;
    for my $i (0 .. $shown - 1) {
        push @lines, "  " . ledger_line($data, $members[$i]{bp}, $members[$i]{pkg});
    }
    push @lines, "  ...and " . ($n - $MAX_LISTED) . " more" if $n > $MAX_LISTED;
    return join("\n", @lines) . "\n";
}

# ---------------------------------------------------------------------------
# payload(%o) -- a Task/Agent PreToolUse payload with no Ledger line (i.e.
# no prompt naming any in-flight package's ledger path -- "no Ledger line"
# per the ledger's Scope wording).
# ---------------------------------------------------------------------------
sub payload {
    my (%o) = @_;
    my $ti = {};
    $ti->{subagent_type} = $o{subagent_type} if exists $o{subagent_type};
    $ti->{prompt}        = $o{prompt}        if exists $o{prompt};
    my $p = { tool_name => $o{tool_name} // 'Agent', tool_input => $ti };
    $p->{hook_event_name} = $o{event} // 'PreToolUse' unless $o{no_event_name};
    $p->{session_id}  = $o{session_id}  if exists $o{session_id};
    $p->{agent_id}    = $o{agent_id}    if exists $o{agent_id};
    $p->{tool_use_id} = $o{tool_use_id} if exists $o{tool_use_id};
    $p->{cwd}         = $o{cwd}         if exists $o{cwd};
    return $p;
}

sub bd {
    my ($p, %opts) = @_;
    return GuardHarness::run_module('BindDispatch', $p, env => ($opts{env} // {}), args => ($opts{args} // []));
}

# ---------------------------------------------------------------------------
# fixture() -- 3 packages in flight (>= 2, per the ledger's "2 or more"),
# armed driver, coordinator env absent (CCPRAXIS_DATA_DIR only, no
# BP_LEDGER/BP_BLUEPRINT/BP_PACKAGE) so this is the ordinary "several
# packages in flight, ambiguous dispatch" situation package 12 already
# covers -- the only variable under test here is subagent_type.
# ---------------------------------------------------------------------------
my $SEQ = 0;
sub fixture {
    my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' }, { bp => 'bpx', pkg => 'p3-c' });
    my $data = fresh_data();
    write_inflight($data, @members);
    my $sid = 'authexempt-sid-' . (++$SEQ);
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data, BUTLER_CONCURRENCY => '1');
    return { data => $data, members => \@members, sid => $sid, env => \%env };
}

my @ALLOWLIST = ('blueprint:bp-auditor', 'butler:bp-feedback-verifier', 'Explore', 'claude-code-guide');

# ===========================================================================
# Decision 101 M1 (package 26 review): Done criterion 2 ("a new entry needs
# a test change") was previously only checked via near-miss enumeration
# below, which pins the 4 EXISTING strings but says nothing about a genuine
# 5th ADDITION -- %EXEMPT_TYPE is a private lexical, so a new member could
# be added to production code and every assertion in this file would stay
# green. Read the list back through a public accessor instead, so it must
# be enumerable and adding an entry breaks this exact assertion on purpose.
# ===========================================================================
eval { require "BpHook/BindDispatch.pm" }
    unless grep { m{(?:^|/)BpHook/BindDispatch\.pm\z} } keys %INC;
my $HAS_EXEMPT_TYPES_FN = defined &BpHook::BindDispatch::exempt_types;
ok($HAS_EXEMPT_TYPES_FN,
    'BindDispatch exposes a public exempt_types() accessor returning the WHOLE allowlist (Decision 101 M1)');
my @got_exempt_types = $HAS_EXEMPT_TYPES_FN
    ? sort { $a cmp $b } eval { BpHook::BindDispatch::exempt_types() }
    : ();
# shape-lint: intentional -- Decision 101 M1 requires this exact list so
# that adding a 5th allowlisted type breaks this assertion on purpose; it is
# the pin, not an accident.
is_deeply(\@got_exempt_types, [ sort { $a cmp $b } @ALLOWLIST ],
    'exempt_types() returns exactly the Decision 98 4-entry allowlist -- a new entry must fail this');

# ===========================================================================
# Done criterion 1 (allow side): each allowlisted subagent_type, no Ledger
# line, is allowed and writes no binding.
# ===========================================================================
for my $type (@ALLOWLIST) {
    my $fx = fixture();
    my $res = bd(payload(session_id => $fx->{sid}, tool_use_id => 'T1', subagent_type => $type, prompt => 'nothing named here'),
        env => $fx->{env});
    is($res->{rc}, 0, "allow($type): rc 0 with no Ledger line and several packages in flight");
    is($res->{err}, '', "allow($type): stderr empty");
    ok(!-e (bindings_dir($fx->{data}) . '/T1.json'), "allow($type): no lookup binding file is written");
    is(scalar(binding_files($fx->{data})), 0, "allow($type): bindings dir gains no file");
    is(scalar(history_lines($fx->{data})), 0, "allow($type): bindings.jsonl gains no line");
}

# Same allowlist, exercised as a fork/subagent dispatch shape (agent_id set),
# per package 12 AC-13's "fork follows the same rule" precedent -- the
# exemption must not be main-thread-only.
for my $type (@ALLOWLIST) {
    my $fx = fixture();
    my $res = bd(payload(session_id => $fx->{sid}, tool_use_id => 'T1', agent_id => 'a1', subagent_type => $type,
        prompt => 'nothing named here'), env => $fx->{env});
    is($res->{rc}, 0, "allow($type, fork shape): rc 0 with no Ledger line");
    ok(!-e (bindings_dir($fx->{data}) . '/T1.json'), "allow($type, fork shape): no binding file is written");
}

# ===========================================================================
# Done criterion 1 (deny side): non-allowlisted types keep today's rule --
# denied with today's exact message, nothing written.
# ===========================================================================
for my $type ('butler:bp-implementer', 'general-purpose') {
    my $fx = fixture();
    my $res = bd(payload(session_id => $fx->{sid}, tool_use_id => 'T1', subagent_type => $type, prompt => 'nothing named here'),
        env => $fx->{env});
    is($res->{rc}, 2, "deny($type): rc 2, today's rule unchanged");
    is($res->{err}, expected_deny_text($fx->{data}, @{ $fx->{members} }), "deny($type): today's exact denial text");
    is($res->{out}, '', "deny($type): stdout empty");
    ok(!-e (bindings_dir($fx->{data}) . '/T1.json'), "deny($type): no binding file is written");
    is(scalar(history_lines($fx->{data})), 0, "deny($type): no history line is written");
}

# ===========================================================================
# Done criterion 2: the allowlist is pinned exactly -- a near-miss of any
# allowlisted string (wrong case, missing/altered namespace, or an extra
# suffix) is NOT exempt and is denied exactly like any other type. This is
# the guard against a future addition silently widening the list without a
# test change.
# ===========================================================================
my @NEAR_MISSES = (
    'bp-auditor',                   # blueprint:bp-auditor without its namespace
    'Blueprint:bp-auditor',         # namespace re-cased
    'Butler:bp-feedback-verifier',  # namespace re-cased
    'butler:bp-feedback-verifie',   # truncated by one character
    'explore',                      # Explore, lower-cased
    'EXPLORE',                      # Explore, upper-cased
    'claude-code-guide-extra',      # claude-code-guide with an extra suffix
    'claude_code_guide',            # claude-code-guide, hyphens to underscores
);
for my $type (@NEAR_MISSES) {
    my $fx = fixture();
    my $res = bd(payload(session_id => $fx->{sid}, tool_use_id => 'T1', subagent_type => $type, prompt => 'nothing named here'),
        env => $fx->{env});
    is($res->{rc}, 2, "pinned($type): a near-miss of an allowlisted string is still denied");
    is($res->{err}, expected_deny_text($fx->{data}, @{ $fx->{members} }), "pinned($type): today's exact denial text");
    ok(!-e (bindings_dir($fx->{data}) . '/T1.json'), "pinned($type): no binding file is written");
}

# ===========================================================================
# Done criterion 3 (narrow re-check, not a replacement for the full sweep):
# an allowlisted type does not disturb an ordinary bound dispatch alongside
# it in the same in-flight set -- a plain dispatch naming a ledger path
# still binds exactly as package 12 specifies.
# ===========================================================================
{
    my $fx = fixture();
    my $res = bd(payload(session_id => $fx->{sid}, tool_use_id => 'T2',
        prompt => ledger_line($fx->{data}, 'bpx', 'p2-b')), env => $fx->{env});
    is($res->{rc}, 0, 'regression: an ordinary dispatch naming a ledger path still binds');
    my $rec = read_json(bindings_dir($fx->{data}) . '/T2.json');
    is(ref $rec eq 'HASH' ? $rec->{package} : undef, 'p2-b', 'regression: bound to the named package');
}

done_testing();
