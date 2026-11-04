#!/usr/bin/env perl
# platform: any
# Oracle for package 16-cutover batch A (blueprint hook-continuity-remake),
# specs/16-cutover-spec.md A-1, A-2, A-3 (sec 2.5, sec 4 "Batch A"). Proves:
# (A-1) an absolute "Ledger: <path>" line canon-equal to a member's full
# ledger path binds -- plain, backslashed, "/c/..." and (when
# $CASE_INSENSITIVE=1) upper-cased forms; the upper-cased form is denied as
# "none" when $CASE_INSENSITIVE=0; (A-2) an absolute line under a different
# data dir, and one naming a non-member, are denied as "none"; two Ledger
# lines (one relative, one absolute) naming two members are denied as
# "many"; the relative form still binds; (A-3) the public accessors
# BpHook::BindDispatch::member_ok/resolve_data_dir/inflight_members exist
# and agree with their private twins (_member_ok/_resolve_data_dir/
# _inflight_members) on a fixture table, and BpHook/WriteGuards.pm's source
# names no BindDispatch::_ private sub.
#
# WRITTEN BLIND TO THE IMPLEMENTATION: derived only from the spec text
# above and the existing R9-D67 "Ledger:" line convention already pinned in
# dispatch-binding.t (12-dispatch-binding), never from reading
# BindDispatch.pm or WriteGuards.pm. The canon() rule and the three public
# accessor names/signatures are the spec's own literal contract (2.5), not
# an implementation detail inferred by reading code.
#
# canon() and the public accessors DO NOT EXIST YET at the time this file is
# written -- every case below that depends on them is expected to fail on
# MISSING BEHAVIOUR, never a harness crash: GuardHarness::run_module()
# mirrors BpHook::main()'s own require-and-call contract (a module that
# fails to canon-match simply falls through to its existing "none"/"many"
# denial exactly as it does today), and each accessor precondition is
# checked with `defined &Sub` before it is ever called.
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;
GuardHarness::isolate_env();

my $BUTLER_DIR = dirname(__FILE__) . '/../..';
my $J = JSON::PP->new->utf8->canonical;

# ---------------------------------------------------------------------------
# Byte / JSON I/O helpers.
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
sub write_json { my ($path, $data) = @_; write_bytes($path, $J->encode($data) . "\n") }
sub read_json {
    my ($p) = @_;
    my $raw = read_bytes($p);
    return undef unless defined $raw;
    return eval { $J->decode($raw) };
}

# ---------------------------------------------------------------------------
# fresh_data() -- a tempdir/data root, forward-slashed.
# ---------------------------------------------------------------------------
sub fresh_data {
    my $t = tempdir(CLEANUP => 1);
    (my $d = "$t/data") =~ s{\\}{/}g;
    make_path($d);
    return $d;
}

sub write_inflight {
    my ($data, @members) = @_;
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
sub write_current {
    my ($data, $bp, $pkg) = @_;
    make_path("$data/.drive-solo");
    write_json("$data/.drive-solo/current.json", { blueprint => $bp, package => $pkg, recorded_at => 1 });
}
sub bindings_dir { my ($data) = @_; return "$data/.drive-solo/bindings" }

# ---------------------------------------------------------------------------
# ledger_line($data, $bp, $pkg) -- today's RELATIVE rule (basename(data) +
# blueprints/.../packages/....md), unchanged (2.5 "today's rule").
# ---------------------------------------------------------------------------
sub ledger_line {
    my ($data, $bp, $pkg) = @_;
    (my $b = $data) =~ s{\\}{/}g;
    $b =~ s{/+\z}{};
    my $L = (split m{/}, $b)[-1];
    return "$L/blueprints/$bp/packages/$pkg.md";
}

# ---------------------------------------------------------------------------
# ledger_abs($data, $bp, $pkg) -- the ABSOLUTE form from spec sec 2.5:
# "$data/blueprints/$bp/packages/$pkg.md".
# ---------------------------------------------------------------------------
sub ledger_abs {
    my ($data, $bp, $pkg) = @_;
    (my $b = $data) =~ s{\\}{/}g;
    $b =~ s{/+\z}{};
    return "$b/blueprints/$bp/packages/$pkg.md";
}

# ---------------------------------------------------------------------------
# canon-form helpers (2.5): backslash form, "/c/..." form, uppercase form.
# ---------------------------------------------------------------------------
sub to_backslash { my ($s) = @_; (my $t = $s) =~ s{/}{\\}g; return $t }
sub to_slash_c_form {
    my ($s) = @_;
    if ($s =~ m{^([A-Za-z]):/(.*)\z}) { return '/' . lc($1) . '/' . $2 }
    return $s; # not a drive-letter path -- caller skips this form
}
sub to_upper { my ($s) = @_; return uc($s) }

sub ledger_decl { my (@a) = @_; return 'Ledger: ' . ledger_line(@a) }
sub ledger_decl_abs_form {
    my ($form, $data, $bp, $pkg) = @_;
    return 'Ledger: ' . $form->(ledger_abs($data, $bp, $pkg));
}

# ---------------------------------------------------------------------------
# payload(%o) -- a Task/Agent PreToolUse payload (mirrors dispatch-binding.t
# 12-dispatch-binding's own payload()).
# ---------------------------------------------------------------------------
sub payload {
    my (%o) = @_;
    my $ti = {};
    $ti->{subagent_type} = $o{subagent_type} if exists $o{subagent_type};
    $ti->{prompt}        = $o{prompt}        if exists $o{prompt};
    my $p = { tool_name => $o{tool_name} // 'Task', tool_input => $ti };
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
# require BpHook::BindDispatch once, so $CASE_INSENSITIVE can be pinned per
# case and the private/public twins can be called directly for A-3. Fails
# legibly (not a harness crash) if the module cannot be loaded at all.
# ---------------------------------------------------------------------------
my $BD_REQUIRE_OK = eval { require BpHook::BindDispatch; 1 };
ok($BD_REQUIRE_OK, 'precondition: BpHook::BindDispatch can be required')
    or diag("require failed: $@");

# ===========================================================================
# A-1: absolute Ledger-line forms bind to the named member.
# ===========================================================================
SKIP: {
    skip 'A-1: BpHook::BindDispatch not requirable', 1 unless $BD_REQUIRE_OK;

    # -- plain absolute, backslashed, and "/c/..." forms: all bind to P (p2-b) --
    {
        local $BpHook::BindDispatch::CASE_INSENSITIVE = 1;
        my @forms = (
            [ sub { $_[0] }, 'plain absolute path' ],
            [ \&to_backslash, 'every / as \\' ],
        );
        my $data0 = fresh_data();
        push @forms, [ \&to_slash_c_form, '/c/... form' ] if to_slash_c_form(ledger_abs($data0, 'bpx', 'p2-b')) ne ledger_abs($data0, 'bpx', 'p2-b');

        for my $spec (@forms) {
            my ($form, $label) = @$spec;
            my $data = fresh_data();
            my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
            write_inflight($data, @members);
            (my $sid_suffix = $label) =~ s/[^A-Za-z0-9]+/-/g;
            my $sid = "a1-$sid_suffix";
            GuardHarness::fresh_state();
            GuardHarness::arm($sid, 'driver');
            my %env = (CCPRAXIS_DATA_DIR => $data, BUTLER_CONCURRENCY => '1');

            my $prompt = ledger_decl_abs_form($form, $data, 'bpx', 'p2-b') . "\n";
            my $res = bd(payload(session_id => $sid, tool_use_id => 'T1', prompt => $prompt), env => \%env);
            is($res->{rc}, 0, "A-1: absolute form ($label) binds -- rc 0");
            my $rec = read_json(bindings_dir($data) . '/T1.json');
            is(ref $rec eq 'HASH' ? $rec->{package} : undef, 'p2-b', "A-1: absolute form ($label) bound to P (p2-b)");
        }
    }

    # -- uppercase copy, CASE_INSENSITIVE=1: binds to P --
    {
        local $BpHook::BindDispatch::CASE_INSENSITIVE = 1;
        my $data = fresh_data();
        my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
        write_inflight($data, @members);
        my $sid = 'a1-upper-ci1';
        GuardHarness::fresh_state();
        GuardHarness::arm($sid, 'driver');
        my %env = (CCPRAXIS_DATA_DIR => $data, BUTLER_CONCURRENCY => '1');

        my $prompt = ledger_decl_abs_form(\&to_upper, $data, 'bpx', 'p2-b') . "\n";
        my $res = bd(payload(session_id => $sid, tool_use_id => 'T1', prompt => $prompt), env => \%env);
        is($res->{rc}, 0, 'A-1: an upper-cased absolute form binds with $CASE_INSENSITIVE=1');
        my $rec = read_json(bindings_dir($data) . '/T1.json');
        is(ref $rec eq 'HASH' ? $rec->{package} : undef, 'p2-b', 'A-1: upper-cased form (CI=1) bound to P (p2-b)');
    }

    # -- uppercase copy, CASE_INSENSITIVE=0: denied as "none" --
    {
        local $BpHook::BindDispatch::CASE_INSENSITIVE = 0;
        my $data = fresh_data();
        my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
        write_inflight($data, @members);
        my $sid = 'a1-upper-ci0';
        GuardHarness::fresh_state();
        GuardHarness::arm($sid, 'driver');
        my %env = (CCPRAXIS_DATA_DIR => $data, BUTLER_CONCURRENCY => '1');

        my $prompt = ledger_decl_abs_form(\&to_upper, $data, 'bpx', 'p2-b') . "\n";
        my $res = bd(payload(session_id => $sid, tool_use_id => 'T1', prompt => $prompt), env => \%env);
        is($res->{rc}, 2, 'A-1: an upper-cased absolute form is denied with $CASE_INSENSITIVE=0');
        like($res->{err}, qr/\bnone\b/i, 'A-1: the CASE_INSENSITIVE=0 upper-case denial uses the "none" text');
    }
}

# ===========================================================================
# A-2: cross-data-dir absolute lines, non-member absolute lines, mixed
# relative+absolute "many", and the relative form still binding.
# ===========================================================================
SKIP: {
    skip 'A-2: BpHook::BindDispatch not requirable', 1 unless $BD_REQUIRE_OK;
    local $BpHook::BindDispatch::CASE_INSENSITIVE = 1;

    # -- an absolute Ledger line for member P under a DIFFERENT data dir: none --
    {
        my $data  = fresh_data();
        my $data2 = fresh_data();
        my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
        write_inflight($data, @members);
        my $sid = 'a2-otherdatadir';
        GuardHarness::fresh_state();
        GuardHarness::arm($sid, 'driver');
        my %env = (CCPRAXIS_DATA_DIR => $data, BUTLER_CONCURRENCY => '1');

        my $prompt = 'Ledger: ' . ledger_abs($data2, 'bpx', 'p2-b') . "\n";
        my $res = bd(payload(session_id => $sid, tool_use_id => 'T1', prompt => $prompt), env => \%env);
        is($res->{rc}, 2, 'A-2: an absolute line for P under a different data dir is denied');
        like($res->{err}, qr/\bnone\b/i, 'A-2: the different-data-dir denial uses the "none" text');
        ok(!-e (bindings_dir($data) . '/T1.json'), 'A-2: nothing written for the different-data-dir case');
    }

    # -- an absolute Ledger line naming a non-member: none --
    {
        my $data = fresh_data();
        my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
        write_inflight($data, @members);
        my $sid = 'a2-nonmember';
        GuardHarness::fresh_state();
        GuardHarness::arm($sid, 'driver');
        my %env = (CCPRAXIS_DATA_DIR => $data, BUTLER_CONCURRENCY => '1');

        my $prompt = 'Ledger: ' . ledger_abs($data, 'bpx', 'p3-c') . "\n";
        my $res = bd(payload(session_id => $sid, tool_use_id => 'T1', prompt => $prompt), env => \%env);
        is($res->{rc}, 2, 'A-2: an absolute line naming a non-member is denied');
        like($res->{err}, qr/\bnone\b/i, 'A-2: the non-member absolute-line denial uses the "none" text');
    }

    # -- two Ledger lines, one relative + one absolute, naming both members: many --
    {
        my $data = fresh_data();
        my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
        write_inflight($data, @members);
        my $sid = 'a2-many-mixed';
        GuardHarness::fresh_state();
        GuardHarness::arm($sid, 'driver');
        my %env = (CCPRAXIS_DATA_DIR => $data, BUTLER_CONCURRENCY => '1');

        my $prompt = ledger_decl($data, 'bpx', 'p1-a') . "\n"
                   . 'Ledger: ' . ledger_abs($data, 'bpx', 'p2-b') . "\n";
        my $res = bd(payload(session_id => $sid, tool_use_id => 'T1', prompt => $prompt), env => \%env);
        is($res->{rc}, 2, 'A-2: a relative line plus an absolute line naming both members is denied');
        like($res->{err}, qr/too many/i, 'A-2: the mixed relative+absolute two-member denial uses the "too many" text');
        ok(!-e (bindings_dir($data) . '/T1.json'), 'A-2: nothing written for the mixed too-many case');
    }

    # -- regression: the relative form still binds exactly as before --
    {
        my $data = fresh_data();
        my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
        write_inflight($data, @members);
        my $sid = 'a2-relative-regression';
        GuardHarness::fresh_state();
        GuardHarness::arm($sid, 'driver');
        my %env = (CCPRAXIS_DATA_DIR => $data, BUTLER_CONCURRENCY => '1');

        my $prompt = ledger_decl($data, 'bpx', 'p2-b') . "\n";
        my $res = bd(payload(session_id => $sid, tool_use_id => 'T1', prompt => $prompt), env => \%env);
        is($res->{rc}, 0, 'A-2 (regression): the relative Ledger: form still binds');
        my $rec = read_json(bindings_dir($data) . '/T1.json');
        is(ref $rec eq 'HASH' ? $rec->{package} : undef, 'p2-b', 'A-2 (regression): bound to p2-b via the relative form');
    }
}

# ===========================================================================
# A-3: public accessors member_ok/resolve_data_dir/inflight_members exist
# and agree with their private twins on a fixture table; WriteGuards.pm's
# source names no BindDispatch::_ private sub.
# ===========================================================================
SKIP: {
    skip 'A-3: BpHook::BindDispatch not requirable', 1 unless $BD_REQUIRE_OK;

    # -- member_ok / _member_ok --
    {
        my $has_pub = defined &BpHook::BindDispatch::member_ok;
        ok($has_pub, 'A-3: BpHook::BindDispatch::member_ok exists (public accessor)');
        my $has_priv = defined &BpHook::BindDispatch::_member_ok;
        ok($has_priv, 'A-3 precondition: BpHook::BindDispatch::_member_ok exists (the sub it must wrap)');

        my @fixtures = (
            { bp => 'bpx', pkg => 'p1-a' },
            { bp => '',    pkg => 'p1-a' },
            { bp => 'bpx', pkg => '' },
            { bp => 'bpx', pkg => '../x' },
            {},
            undef,
        );
        SKIP: {
            skip 'A-3: member_ok/_member_ok not both defined', scalar(@fixtures) unless $has_pub && $has_priv;
            for my $i (0 .. $#fixtures) {
                my $v = $fixtures[$i];
                my $pub_died  = !eval { BpHook::BindDispatch::member_ok($v); 1 };
                my $pub  = $pub_died  ? 'DIED' : (BpHook::BindDispatch::member_ok($v) ? 1 : 0);
                my $priv_died = !eval { BpHook::BindDispatch::_member_ok($v); 1 };
                my $priv = $priv_died ? 'DIED' : (BpHook::BindDispatch::_member_ok($v) ? 1 : 0);
                is($pub, $priv, "A-3: member_ok agrees with _member_ok on fixture $i");
            }
        }
    }

    # -- resolve_data_dir / _resolve_data_dir --
    {
        my $has_pub = defined &BpHook::BindDispatch::resolve_data_dir;
        ok($has_pub, 'A-3: BpHook::BindDispatch::resolve_data_dir exists (public accessor)');
        my $has_priv = defined &BpHook::BindDispatch::_resolve_data_dir;
        ok($has_priv, 'A-3 precondition: BpHook::BindDispatch::_resolve_data_dir exists (the sub it must wrap)');

        my $tmp = fresh_data();
        my @fixtures = ($tmp, '', undef, 'relative/path', "$tmp/", 'C:\\Users\\x\\data');
        SKIP: {
            skip 'A-3: resolve_data_dir/_resolve_data_dir not both defined', scalar(@fixtures) unless $has_pub && $has_priv;
            for my $i (0 .. $#fixtures) {
                my $v = $fixtures[$i];
                my $pub_died  = !eval { BpHook::BindDispatch::resolve_data_dir($v); 1 };
                my $pub  = $pub_died  ? 'DIED' : (BpHook::BindDispatch::resolve_data_dir($v) // '(undef)');
                my $priv_died = !eval { BpHook::BindDispatch::_resolve_data_dir($v); 1 };
                my $priv = $priv_died ? 'DIED' : (BpHook::BindDispatch::_resolve_data_dir($v) // '(undef)');
                is($pub, $priv, "A-3: resolve_data_dir agrees with _resolve_data_dir on fixture $i");
            }
        }
    }

    # -- inflight_members / _inflight_members --
    {
        my $has_pub = defined &BpHook::BindDispatch::inflight_members;
        ok($has_pub, 'A-3: BpHook::BindDispatch::inflight_members exists (public accessor)');
        my $has_priv = defined &BpHook::BindDispatch::_inflight_members;
        ok($has_priv, 'A-3 precondition: BpHook::BindDispatch::_inflight_members exists (the sub it must wrap)');

        my @data_fixtures;
        {
            my $d = fresh_data();
            push @data_fixtures, [ $d, 'no inflight.json, no current.json' ];
        }
        {
            my $d = fresh_data();
            write_inflight($d, { bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
            push @data_fixtures, [ $d, 'a valid 2-member inflight.json' ];
        }
        {
            my $d = fresh_data();
            make_path("$d/.drive-solo");
            write_bytes("$d/.drive-solo/inflight.json", '{not json');
            write_current($d, 'bpx', 'p1-a');
            push @data_fixtures, [ $d, 'malformed inflight.json falling back to current.json' ];
        }
        {
            my $d = fresh_data();
            write_current($d, 'bpx', 'p1-a');
            push @data_fixtures, [ $d, 'current.json only' ];
        }

        SKIP: {
            skip 'A-3: inflight_members/_inflight_members not both defined', scalar(@data_fixtures) unless $has_pub && $has_priv;
            for my $f (@data_fixtures) {
                my ($d, $label) = @$f;
                my (@pub, @priv);
                my $pub_died  = !eval { @pub  = BpHook::BindDispatch::inflight_members($d); 1 };
                my $priv_died = !eval { @priv = BpHook::BindDispatch::_inflight_members($d); 1 };
                is($pub_died, $priv_died, "A-3: inflight_members and _inflight_members die-or-not agree ($label)");
                my @pub_sorted  = sort map { (ref($_) eq 'HASH' ? "$_->{bp}:$_->{pkg}" : 'NOTHASH') } @pub;
                my @priv_sorted = sort map { (ref($_) eq 'HASH' ? "$_->{bp}:$_->{pkg}" : 'NOTHASH') } @priv;
                is_deeply(\@pub_sorted, \@priv_sorted, "A-3: inflight_members agrees with _inflight_members ($label)");
            }
        }
    }

    # -- WriteGuards.pm source names no BindDispatch::_ private sub --
    {
        my $wg = "$BUTLER_DIR/scripts/BpHook/WriteGuards.pm";
        ok(-f $wg, 'A-3 precondition: BpHook/WriteGuards.pm exists on disk');
      SKIP: {
            skip 'A-3: WriteGuards.pm missing', 1 unless -f $wg;
            my $src = read_bytes($wg) // '';
            unlike($src, qr/BindDispatch::_/, 'A-3: WriteGuards.pm source contains no BindDispatch::_ (public accessors only)');
        }
    }
}

$? = 0;
done_testing();
