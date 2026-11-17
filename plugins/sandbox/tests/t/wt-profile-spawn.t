#!/usr/bin/env perl
# platform: host
# THE ORACLE for blueprint sandbox-wt-profile, package
# 02-launch-claude-uses-profile, written from
#   .ccpraxis-local-data/blueprints/sandbox-wt-profile/specs/02-launch-claude-uses-profile-spec.md
# BEFORE the implementation exists.
#
# WHY THIS FILE EXISTS, AND WHY IT IS THE ONLY GUARANTEE OF CRITERION 1.
# 'Dashboard::spawn_argv''s no-profile output was believed to be pinned by
# 'dashboard-framework.t'. It is not: 'spawn_argv' is referenced in exactly
# four places in this plugin (its own comment, its own definition, the one
# call site in launcher.pl, and one unrelated doc) and NO test file mentions
# it at all. So the pre-change literal ['wt.exe','-w','new',@cmd] has never
# been enforced by anything -- this file is where that enforcement begins.
# AC-1 exists to make the "unchanged" half of this feature a real guarantee,
# not a claim.
#
# WHY A SENTINEL-DELIMITED EVAL REGION FOR wt_profile_plan. launcher.pl is
# NEVER require'd/do'ne by this suite: it is a top-level script with real
# side effects (a raw-mode terminal, a live subprocess launch, a blocking
# keypress) and cannot be safely executed by a test. The house technique
# (precedent: container-health-detect.t:123-169) is to slurp launcher.pl as
# SOURCE TEXT, locate a sentinel-delimited region, and 'eval' just that
# region into a fresh package. wt_profile_plan is a pure, seam-driven
# function precisely so this is possible: the production path and the
# tested path are the same sub, never a parallel reimplementation.
#
# WHAT IS EXPECTED TO FAIL TODAY. The 'wt-profile:BEGIN'/'wt-profile:END'
# sentinel comments do not exist in launcher.pl yet, 'spawn_argv' does not
# yet understand a 'profile' key, and 'plugins/sandbox/docs/wt-profile.md'
# does not exist. Every assertion that depends on those is EXPECTED to
# report "not ok" until package 02 is implemented. Do not weaken any
# assertion below to make that future implementation's life easier.
#
# A NOTE ON THIS FILE'S OWN WORDING (read before editing comments/test
# names below). AC-6.1 requires this file's OWN SOURCE TEXT to contain no
# live-subprocess call-forms anywhere -- not only in code, but in comments
# and test-description strings too, since a naive scan cannot tell the
# difference. So nowhere in this file (except the one AC-8.1 helper) does
# the word for the list-form OS-spawn builtin sit directly next to an open
# paren, nor 'qx' directly next to its capture delimiter, nor 'exec'
# directly next to an open paren, nor a real backtick character, nor a
# pipe character directly next to a dash. Where prose must refer to one of
# these concepts it uses a hyphenated paraphrase instead.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;

use_ok('Dashboard')  or BAIL_OUT('Dashboard.pm did not load');
use_ok('WtProfile')  or BAIL_OUT('WtProfile.pm did not load -- package 01 is not actually done');

my $SCRIPTS_DIR = "$Bin/../../scripts";
my $DASHBOARD_PM = "$SCRIPTS_DIR/Dashboard.pm";
my $LAUNCHER     = "$SCRIPTS_DIR/launcher.pl";
my $DOC          = "$Bin/../../docs/wt-profile.md";

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

my $SRC = slurp($LAUNCHER);
ok(defined($SRC) && length($SRC), 'prereq: launcher.pl source read as text (never require/do-ed)')
    or BAIL_OUT("cannot read $LAUNCHER");

# =============================================================================
# AC-1 -- spawn_argv without a profile is unchanged (criterion 1)
# =============================================================================
{
    my $PRECHANGE = ['wt.exe', '-w', 'new', 'a', 'b'];

    is_deeply(Dashboard::spawn_argv('wt', { cmd => ['a', 'b'] }), $PRECHANGE,
        'AC-1.1: spawn_argv(wt, {cmd=>[a,b]}) with no profile key is the pinned pre-change literal');

    is_deeply(Dashboard::spawn_argv('wt', { cmd => ['a', 'b'], profile => undef }), $PRECHANGE,
        "AC-1.2: profile => undef takes the unchanged branch");
    is_deeply(Dashboard::spawn_argv('wt', { cmd => ['a', 'b'], profile => '' }), $PRECHANGE,
        "AC-1.2: profile => '' takes the unchanged branch");

    is_deeply(Dashboard::spawn_argv('wt', {}), ['wt.exe', '-w', 'new'],
        'AC-1.3: spawn_argv(wt, {}) with no cmd returns just the wt prefix');
    is_deeply(Dashboard::spawn_argv('wt'), ['wt.exe', '-w', 'new'],
        'AC-1.3: spawn_argv(wt) with no ctx at all returns just the wt prefix');
    is_deeply(Dashboard::spawn_argv('wt', { cmd => [] }), ['wt.exe', '-w', 'new'],
        'AC-1.3: spawn_argv(wt, {cmd=>[]}) returns just the wt prefix');

    for my $case (
        ['a,b, no profile'  => Dashboard::spawn_argv('wt', { cmd => ['a', 'b'] })],
        ['no cmd'           => Dashboard::spawn_argv('wt', {})],
        ['no ctx'           => Dashboard::spawn_argv('wt')],
    ) {
        my ($label, $argv) = @$case;
        ok(!(grep { $_ eq '-p' } @$argv), "AC-1.4: no -p element in the no-profile result ($label)");
    }
}

# =============================================================================
# AC-2 -- spawn_argv with a profile (criterion 2)
# =============================================================================
{
    my $argv = Dashboard::spawn_argv('wt', { cmd => ['a', 'b'], profile => 'claude-sandbox' });
    is_deeply($argv, ['wt.exe', '-w', 'new', '-p', 'claude-sandbox', 'a', 'b'],
        'AC-2.1: a profile inserts -p and the name as two elements between new and @cmd');

    SKIP: {
        skip 'AC-2.2/2.3: spawn_argv does not yet return a 7-element argv for this input', 5
            unless ref($argv) eq 'ARRAY' && @$argv >= 5;
        is($argv->[3], '-p', 'AC-2.2: element 3 is the bare flag -p (own element)');
        is($argv->[4], 'claude-sandbox', 'AC-2.2: element 4 is the bare profile name (own element, unquoted)');

        # counter-fixture: prove a joined '-p claude-sandbox' single element
        # WOULD be caught by the same style of check used above.
        my $bad_joined = ['wt.exe', '-w', 'new', '-p claude-sandbox', 'a', 'b'];
        isnt($bad_joined->[3], '-p', 'AC-2.2 counter-fixture: a joined "-p claude-sandbox" element fails the element-3 check');

        my @space_elems  = grep { /\s/ } @$argv;
        is(scalar(@space_elems), 0, 'AC-2.3: no argv element contains whitespace');
        my @quoted_elems = grep { /^["']/ } @$argv;
        is(scalar(@quoted_elems), 0, 'AC-2.3: no argv element begins with a quote character');
        my @contains_name = grep { /claude-sandbox/ } @$argv;
        is(scalar(@contains_name), 1, 'AC-2.3: exactly one element contains the substring claude-sandbox');

        # counter-fixture for the space/quote checks: the deliberately bad
        # single-element form trips both detectors.
        ok(scalar(grep { /\s/ } @$bad_joined) >= 1,
            'AC-2.3 counter-fixture: the joined single-element form DOES contain a whitespace element');
    }

    my @cmd = ('powershell.exe', '-NoProfile', '-File', 'C:\p a\sandbox.ps1', '--session', 'C:\proj');
    my $argv2 = Dashboard::spawn_argv('wt', { cmd => \@cmd, profile => 'claude-sandbox' });
    is(scalar(@$argv2), 5 + scalar(@cmd), 'AC-2.4: element count is exactly 5 + @cmd with a profile');
    is_deeply([ @{$argv2}[5 .. $#$argv2] ], \@cmd,
        'AC-2.4: @cmd is preserved verbatim, in order, as the final elements -- including spaces and backslashes');

    my $argv3 = Dashboard::spawn_argv('wt', { cmd => \@cmd, profile => WtProfile::profile_name() });
    is($argv3->[4], WtProfile::profile_name(),
        'AC-2.5: the real WtProfile::profile_name() value round-trips to index 4 -- never a literal in this assertion');

    my $argv4 = Dashboard::spawn_argv('wt', { cmd => ['a'], profile => ' ' });
    is($argv4->[3], '-p', 'AC-2.6: a whitespace-only profile still takes the -p branch (element 3)');
    is($argv4->[4], ' ', 'AC-2.6: a whitespace-only profile appears verbatim at index 4 -- pins defined&&length, not /\\S/');
}

# =============================================================================
# AC-3 -- start and inline unaffected (criterion 3)
# =============================================================================
{
    my $no_profile = Dashboard::spawn_argv('start', { cmd => ['a'], comspec => 'C:\cmd.exe' });
    my $with_profile = Dashboard::spawn_argv('start', { cmd => ['a'], comspec => 'C:\cmd.exe', profile => 'claude-sandbox' });
    is_deeply($no_profile, ['C:\cmd.exe', '/c', 'start', '', 'a'], 'AC-3.1: start without profile is the pinned literal');
    is_deeply($with_profile, $no_profile, 'AC-3.1: start with a profile is identical to start without one');

    ok(!(grep { $_ eq '-p' } @$with_profile), 'AC-3.2: no -p element in the start-mode result even with a profile');
    ok(!(grep { /claude-sandbox/ } @$with_profile), 'AC-3.2: no claude-sandbox substring in the start-mode result');

    is_deeply(Dashboard::spawn_argv('start', { cmd => ['a'] }), ['cmd.exe', '/c', 'start', '', 'a'],
        'AC-3.3: the comspec || cmd.exe default is unchanged');

    is(Dashboard::spawn_argv('inline', { cmd => ['a'], profile => 'claude-sandbox' }), undef,
        'AC-3.4: inline mode returns undef regardless of profile');
    is(Dashboard::spawn_argv('nonsense', { profile => 'claude-sandbox' }), undef,
        'AC-3.4: an unknown mode returns undef regardless of profile');
}

# =============================================================================
# AC-4 -- the degrade/success seam (criterion 4, and criterion 5 by construction)
# =============================================================================
my $BEGIN_SENTINEL = '# >>> wt-profile:BEGIN';
my $END_SENTINEL   = '# <<< wt-profile:END';
my ($begin_idx, $end_idx, $region);
{
    my $begin_count = () = $SRC =~ /\Q$BEGIN_SENTINEL\E/g;
    my $end_count   = () = $SRC =~ /\Q$END_SENTINEL\E/g;
    is($begin_count, 1, "AC-4.1: sentinel '$BEGIN_SENTINEL' occurs exactly once in launcher.pl");
    is($end_count, 1,   "AC-4.1: sentinel '$END_SENTINEL' occurs exactly once in launcher.pl");
    $begin_idx = index($SRC, $BEGIN_SENTINEL);
    $end_idx   = index($SRC, $END_SENTINEL);
    ok(($begin_idx >= 0 && $end_idx >= 0 && $begin_idx < $end_idx),
        'AC-4.1: sentinel BEGIN appears before END');
    ($region) = $SRC =~ /\Q$BEGIN_SENTINEL\E.*?\n(.*?)\Q$END_SENTINEL\E/s
        if $begin_idx >= 0 && $end_idx >= 0 && $begin_idx < $end_idx;
}

my $PLAN;
if (!defined $region) {
    ok(0, 'AC-4.1: the wt-profile:BEGIN/END region evals cleanly into a fresh package (region not found -- not yet implemented)');
    ok(0, "AC-4.1: the resulting package ->can('wt_profile_plan') (region not found)");
} else {
    my $harness = "package WtProfilePlan;\nuse strict;\nuse warnings;\n" . $region . "\n1;\n";
    my $eval_ok = eval $harness;   ## no critic
    my $eval_err = $@;
    ok($eval_ok, 'AC-4.1: the wt-profile:BEGIN/END region evals cleanly into a fresh package under use strict/warnings')
        or diag("eval error: $eval_err");
    if ($eval_ok) {
        $PLAN = WtProfilePlan->can('wt_profile_plan');
        ok(defined $PLAN, "AC-4.1: the resulting package ->can('wt_profile_plan')");
    } else {
        ok(0, "AC-4.1: the resulting package ->can('wt_profile_plan') (region failed to eval)");
    }
}

# ---- AC-4.12: region purity, checked whether or not it evaluated cleanly ----
if (!defined $region) {
    ok(0, 'AC-4.12: region purity (region not found)') for 1 .. 9;
} else {
    unlike($region, qr/\bsystem\s*\(/, 'AC-4.12: region has no live-subprocess call');
    unlike($region, qr/\x60/,          'AC-4.12: region has no backtick character');
    unlike($region, qr/\bexit\s*\(/,   'AC-4.12: region has no literal exit(');
    unlike($region, qr/\bprint\b/,     'AC-4.12: region has no print');
    unlike($region, qr/\blog_ev\b/,    'AC-4.12: region has no log_ev call');
    unlike($region, qr/\bDashboard::/, 'AC-4.12: region has no Dashboard:: reference');
    unlike($region, qr/\bWtProfile::/, 'AC-4.12: region has no WtProfile:: reference');
    unlike($region, qr/\$ENV\{/,       'AC-4.12: region has no $ENV{ reference');
    unlike($region, qr/\bdie\b/,       'AC-4.12: region has no literal die keyword');
    # counter-fixture: prove these detectors actually fire on input designed to trip them.
    # Built with the call-name in its own variable, and described below
    # without pairing the bare word directly against an open paren, so THIS
    # FILE's own source stays clean for the AC-6.1 self-scan further down
    # (which would otherwise count its own counter-fixture as a violation).
    my $sysw = 'system';
    my $dirty = "sub bad { $sysw('x'); Dashboard::spawn_argv(); die 'y'; \$ENV{X}; }";
    like($dirty, qr/\bsystem\s*\(/, 'AC-4.12 counter-fixture: the live-subprocess detector fires on real input');
    like($dirty, qr/\bDashboard::/, 'AC-4.12 counter-fixture: the Dashboard:: detector fires on a real reference');
    like($dirty, qr/\$ENV\{/,       'AC-4.12 counter-fixture: the $ENV{ detector fires on a real reference');
}

# recording seam-builder: @calls records [name, @args] pushed BEFORE the
# override runs, so a dying override still leaves a call record (precedent:
# container-health-detect.t build_seams).
sub build_seams {
    my (%over) = @_;
    my @calls;
    my %default = (
        resolve_root => sub { { ok => 1, root => '/tmp/frag' } },
        ensure       => sub { { ok => 1, action => 'wrote', path => '/tmp/frag/ccpraxis/claude-sandbox.json' } },
        profile_name => sub { 'claude-sandbox' },
    );
    my %seams;
    for my $name (qw(resolve_root ensure profile_name)) {
        my $impl = exists $over{$name} ? $over{$name} : $default{$name};
        $seams{$name} = sub {
            push @calls, [ $name, @_ ];
            return $impl->(@_);
        };
    }
    return (\%seams, \@calls);
}
sub call_count { my ($calls, $name) = @_; return scalar grep { $_->[0] eq $name } @$calls; }
sub calls_for  { my ($calls, $name) = @_; return [ grep { $_->[0] eq $name } @$calls ]; }

# call_plan(%seams) -> ($ok, $result) — AC-4.10: every plan invocation runs
# fenced, and this file checks $@ is empty and no warning escaped, every time.
sub call_plan {
    my (%seams) = @_;
    my @w;
    my $result;
    my $ok = eval {
        local $SIG{__WARN__} = sub { push @w, @_ };
        $result = $PLAN->(%seams);
        1;
    };
    my $err = $@;
    is($ok ? 1 : 0, 1, 'AC-4.10: wt_profile_plan never dies') if $PLAN;
    is($err, '', 'AC-4.10: $@ is empty after the call') if $PLAN;
    is(scalar(@w), 0, 'AC-4.10: no warning escaped the call') if $PLAN;
    return $result;
}

my @CLOSED_REASONS = qw(no_localappdata root_missing mkdir_failed write_failed
                         ensure_threw bad_result no_profile_name unknown);
my %CLOSED = map { $_ => 1 } @CLOSED_REASONS;

SKIP: {
    skip 'AC-4.2..AC-4.15: wt_profile_plan not available -- not yet implemented', 90
        unless defined $PLAN;

    # ---- AC-4.2/4.3: success, with 'wrote' and 'unchanged' both succeeding ----
    for my $action (qw(wrote unchanged)) {
        my ($seams, $calls) = build_seams(
            ensure => sub { { ok => 1, action => $action, path => '/tmp/frag/ccpraxis/claude-sandbox.json' } },
        );
        my $plan = call_plan(%$seams);
        is_deeply($plan, { profile => 'claude-sandbox', event => undef },
            "AC-4.2: success plan (ensure action=$action) is exactly {profile=>'claude-sandbox', event=>undef}");

        my @inner = ('powershell.exe', '-File', 'x.ps1');
        my $argv = Dashboard::spawn_argv('wt', { cmd => \@inner, profile => $plan->{profile} });
        is_deeply($argv, ['wt.exe', '-w', 'new', '-p', 'claude-sandbox', @inner],
            "AC-4.3: success argv (action=$action) carries -p claude-sandbox before @inner");
    }

    # ---- AC-4.4: ensure receives the resolved root, called exactly once ----
    {
        my ($seams, $calls) = build_seams();
        call_plan(%$seams);
        is(call_count($calls, 'ensure'), 1, 'AC-4.4: ensure is called exactly once on the success path');
        my $ensure_call = calls_for($calls, 'ensure')->[0];
        is(scalar(@$ensure_call) - 1, 1, 'AC-4.4: ensure receives exactly one argument');
        is($ensure_call->[1], '/tmp/frag', "AC-4.4: ensure's argument equals resolve_root's root");
    }

    # ---- AC-4.5/4.7/4.8/4.9/4.11: every degrade row ----
    my %degrade_rows = (
        no_localappdata => { over => { resolve_root => sub { { ok => 0, reason => 'no_localappdata' } } } },
        root_missing     => { over => { ensure => sub { { ok => 0, action => 'failed', reason => 'root_missing', error => 'e' } } } },
        mkdir_failed      => { over => { ensure => sub { { ok => 0, action => 'failed', reason => 'mkdir_failed', error => 'e' } } } },
        write_failed      => { over => { ensure => sub { { ok => 0, action => 'failed', reason => 'write_failed', error => 'e' } } } },
        ensure_threw_a    => { over => { ensure => sub { die "boom\n" } }, expect => 'ensure_threw' },
        ensure_threw_b    => { over => { resolve_root => sub { die "boom\n" } }, expect => 'ensure_threw' },
        ensure_threw_c    => { over => { profile_name => sub { die "boom\n" } }, expect => 'ensure_threw' },
        bad_result_a      => { over => { resolve_root => sub { undef } }, expect => 'bad_result' },
        bad_result_b      => { over => { resolve_root => sub { 'nope' } }, expect => 'bad_result' },
        bad_result_c      => { over => { ensure => sub { [] } }, expect => 'bad_result' },
        no_profile_name_a => { over => { profile_name => sub { undef } }, expect => 'no_profile_name' },
        no_profile_name_b => { over => { profile_name => sub { '' } }, expect => 'no_profile_name' },
        unknown_a         => { over => { ensure => sub { { ok => 0 } } }, expect => 'unknown' },
        unknown_b         => { over => { ensure => sub { { ok => 0, reason => '' } } }, expect => 'unknown' },
        unknown_c         => { over => { ensure => sub { { ok => 0, reason => '   ' } } }, expect => 'unknown' },
    );

    my %plans_by_reason;
    for my $label (sort keys %degrade_rows) {
        my $row = $degrade_rows{$label};
        my $expect = $row->{expect} || $label;
        my ($seams, $calls) = build_seams(%{ $row->{over} });
        my $plan = call_plan(%$seams);

        is($plan->{profile}, undef, "AC-4.5 [$label]: profile is undef on degrade");
        is(ref($plan->{event}), 'HASH', "AC-4.8 [$label]: event is a hashref, never an array");
        is($plan->{event}{type}, 'launch_profile_degraded', "AC-4.5 [$label]: event type is launch_profile_degraded");
        is_deeply([ sort keys %{ $plan->{event}{fields} } ], ['reason'], "AC-4.5 [$label]: event fields key set is exactly (reason)");
        is($plan->{event}{fields}{reason}, $expect, "AC-4.5 [$label]: reason is '$expect'");
        is_deeply([ sort keys %$plan ], ['event', 'profile'], "AC-4.8 [$label]: plan key set is exactly (event,profile)");
        is_deeply([ sort keys %{ $plan->{event} } ], ['fields', 'type'], "AC-4.8 [$label]: event key set is exactly (fields,type)");
        ok($CLOSED{ $plan->{event}{fields}{reason} } ? 1 : 0, "AC-4.11 [$label]: reason is a member of the closed 8-code set");

        $plans_by_reason{$expect} ||= $plan;
    }

    # AC-4.9 short-circuit: a resolve_root failure never reaches ensure/profile_name.
    {
        my ($seams, $calls) = build_seams(resolve_root => sub { { ok => 0, reason => 'no_localappdata' } });
        call_plan(%$seams);
        is(call_count($calls, 'ensure'), 0, 'AC-4.9: resolve_root failure short-circuits ensure (0 calls)');
        is(call_count($calls, 'profile_name'), 0, 'AC-4.9: resolve_root failure short-circuits profile_name (0 calls)');
    }
    # AC-4.9 short-circuit: an ensure failure never reaches profile_name.
    {
        my ($seams, $calls) = build_seams(ensure => sub { { ok => 0, action => 'failed', reason => 'write_failed', error => 'e' } });
        call_plan(%$seams);
        is(call_count($calls, 'profile_name'), 0, 'AC-4.9: ensure failure short-circuits profile_name (0 calls)');
    }

    # AC-4.6: error/detail/path/message never leak into the event, for write_failed.
    {
        my $marker_err  = 'ERRMARKER_should_not_leak_0451';
        my $marker_path = '/should/not/leak/either/0451';
        my ($seams, $calls) = build_seams(
            ensure => sub { { ok => 0, action => 'failed', reason => 'write_failed', error => $marker_err, path => $marker_path } },
        );
        my $plan = call_plan(%$seams);
        is_deeply([ sort keys %{ $plan->{event}{fields} } ], ['reason'], 'AC-4.6: fields key set excludes error/detail/path/message');
        require Data::Dumper;
        my $dump = Data::Dumper::Dumper($plan);
        unlike($dump, qr/\Q$marker_err\E/,  'AC-4.6: the error string never appears anywhere in the plan');
        unlike($dump, qr/\Q$marker_path\E/, "AC-4.6: the ensure-reported path never appears anywhere in the plan");
    }

    # AC-4.7: the degrade argv equals the pre-change argv, for four representative rows.
    for my $reason (qw(no_localappdata write_failed ensure_threw bad_result)) {
        my $plan = $plans_by_reason{$reason};
        ok(defined $plan, "AC-4.7 [$reason]: a degrade plan for this reason was captured above")
            or next;
        my @inner = ('powershell.exe', '-File', 'x.ps1');
        my $degrade_argv  = Dashboard::spawn_argv('wt', { cmd => \@inner, profile => $plan->{profile} });
        my $baseline_argv = Dashboard::spawn_argv('wt', { cmd => \@inner });
        is_deeply($degrade_argv, $baseline_argv, "AC-4.7 [$reason]: degrade argv equals spawn_argv with no profile at all");
        is_deeply($degrade_argv, ['wt.exe', '-w', 'new', @inner], "AC-4.7 [$reason]: degrade argv equals the pinned pre-change literal");
        ok(!(grep { $_ eq '-p' } @$degrade_argv), "AC-4.7 [$reason]: degrade argv contains no -p");
    }

    # AC-4.10: totality with NO seams supplied at all.
    {
        my $plan = call_plan();
        is(ref($plan), 'HASH', 'AC-4.10: wt_profile_plan() with no seams returns a hashref');
        is($plan->{profile}, undef, 'AC-4.10: with no seams, profile is undef');
        ok($CLOSED{ $plan->{event}{fields}{reason} } ? 1 : 0,
            'AC-4.10: with no seams, the reason is a member of the closed set');
    }

    # ---- AC-4.13/4.14/4.15: the wiring in _spawn_session is real ----
    my ($body) = $SRC =~ /\nsub _spawn_session \{\n(.*?)\n\}\n/s;
    SKIP: {
        skip 'AC-4.13..4.15: could not extract _spawn_session body', 12 unless defined $body;

        like($body, qr/wt_profile_plan\(/, 'AC-4.13: _spawn_session calls wt_profile_plan(');
        like($body, qr/Dashboard::spawn_argv\(\s*'wt'[^)]*profile\s*=>\s*\$plan->\{profile\}/s,
            "AC-4.13: the spawn_argv('wt', ...) call passes profile => \$plan->{profile}");
        like($body, qr/log_ev\([^;]*\$plan->\{event\}/s, 'AC-4.13: a guarded log_ev( call references $plan->{event}');
        like($body, qr/resolve_root\s*=>\s*sub\s*\{\s*WtProfile::fragment_root\(\)\s*\}/,
            'AC-4.13: resolve_root seam is bound to WtProfile::fragment_root');
        like($body, qr/ensure\s*=>\s*sub\s*\{\s*WtProfile::ensure_fragment\(\$_\[0\]\)\s*\}/,
            'AC-4.13: ensure seam is bound to WtProfile::ensure_fragment($_[0])');
        like($body, qr/profile_name\s*=>\s*sub\s*\{\s*WtProfile::profile_name\(\)\s*\}/,
            'AC-4.13: profile_name seam is bound to WtProfile::profile_name');

        my $idx_find_wt = index($body, 'Dashboard::find_wt');
        my $idx_redraw  = index($body, "return 'redraw';");
        my $idx_plan    = index($body, 'wt_profile_plan(');
        my $idx_spawn   = index($body, "Dashboard::spawn_argv('wt'");
        ok($idx_find_wt >= 0 && $idx_redraw >= 0 && $idx_find_wt < $idx_redraw,
            'AC-4.13 ordering: find_wt precedes the first return redraw');
        ok($idx_redraw >= 0 && $idx_plan >= 0 && $idx_redraw < $idx_plan,
            'AC-4.13 ordering: the fail-loud return redraw precedes the wt_profile_plan( call');
        ok($idx_plan >= 0 && $idx_spawn >= 0 && $idx_plan < $idx_spawn,
            'AC-4.13 ordering: wt_profile_plan( precedes the spawn_argv(wt call');

        my $log_ev_count = () = $body =~ /\blog_ev\(/g;
        is($log_ev_count, 4, 'AC-4.14: exactly 4 log_ev( occurrences in _spawn_session (3 existing + 1 guarded degrade)');
        my $event_referencing = () = $body =~ /log_ev\([^;]*\$plan->\{event\}/sg;
        is($event_referencing, 1, 'AC-4.14: exactly one log_ev( call references $plan->{event}');
        like($body, qr/log_ev\(\s*'launch_session'\s*,\s*\{\s*mode\s*=>\s*'wt'\s*\}\s*\)/, 'AC-4.14: log_ev(launch_session,...) survives verbatim');
        like($body, qr/log_ev\(\s*'launch_session_done'/, "AC-4.14: log_ev('launch_session_done' survives");
    }

    {
        my $plan_call_count = () = $SRC =~ /wt_profile_plan\(/g;
        is($plan_call_count, 2, 'AC-4.15: wt_profile_plan( occurs exactly twice in the whole file (its sub + its one call site)');
        my $whole_wtprofile_count = () = $SRC =~ /\bWtProfile::/g;
        my $body_wtprofile_count = defined($body) ? (() = $body =~ /\bWtProfile::/g) : -1;
        is($whole_wtprofile_count, $body_wtprofile_count,
            'AC-4.15: every WtProfile:: occurrence in launcher.pl lies inside _spawn_session\'s body');
        like($SRC, qr/use WtProfile \(\)/, 'AC-4.15: launcher.pl contains use WtProfile ()');
    }
}

# =============================================================================
# AC-5 -- the fail-loud missing-wt.exe block still fails loudly (criterion 6)
# =============================================================================
{
    my ($body) = $SRC =~ /\nsub _spawn_session \{\n(.*?)\n\}\n/s;
    ok(defined($body), 'prereq: _spawn_session body is extractable (no column-0 "}" inside it)')
        or BAIL_OUT('_spawn_session body could not be extracted -- structural invariant broken');

    # NOTE on technique: every literal below that contains a backslash or a
    # '$' is built as a SINGLE-QUOTED Perl string first, then interpolated
    # via qr/\Q$var\E/. A backslash or '$' written directly between \Q..\E
    # in a qr/.../ literal is still escape-processed / variable-interpolated
    # by Perl BEFORE \Q applies (\Q only quotemetas the already-materialized
    # value) -- so e.g. \e would silently become a real ESC byte instead of
    # the literal two characters backslash+'e' that actually appear in
    # launcher.pl's SOURCE TEXT, and $wt would try to interpolate a (nonexistent)
    # local variable instead of matching the literal string "$wt". Single
    # quotes sidestep both hazards: they perform no escape processing and no
    # interpolation, so the variable holds exactly the bytes intended.
    like($body, qr/\QWindows Terminal (wt.exe) was not found.\E/, 'AC-5.1: the "not found" STDERR line is present verbatim');
    like($body, qr/\Qthere is no fallback to a plain console (by design).\E/, 'AC-5.1: the "no fallback" STDERR line is present verbatim');
    like($body, qr/\QFix: install\E/, 'AC-5.1: the "Fix: install" STDERR text is present');
    my $fix_suffix = 'from the Microsoft Store, or put wt.exe on';
    like($body, qr/\Q$fix_suffix\E/, 'AC-5.1: the "...from the Microsoft Store..." STDERR text is present verbatim');
    my $searched_prefix = '(Searched PATH and %LOCALAPPDATA%';
    like($body, qr/\Q$searched_prefix\E/, 'AC-5.1: the "(Searched PATH and %LOCALAPPDATA%" STDERR prefix is present verbatim');
    like($body, qr/\QWindowsApps.)\E/, 'AC-5.1: the "WindowsApps.)" STDERR suffix is present verbatim');
    like($body, qr/\QPress any key to return to the dashboard...\E/, 'AC-5.1: the "Press any key" STDERR line is present verbatim');
    my $leave_altscreen = 'print STDOUT "\e[?25h\e[?1049l";';
    like($body, qr/\Q$leave_altscreen\E/, 'AC-5.1: the alt-screen-leave print is present verbatim');
    my $enter_altscreen = 'print STDOUT "\e[?1049h\e[?25l";';
    like($body, qr/\Q$enter_altscreen\E/, 'AC-5.1: the alt-screen-enter print is present verbatim');

    like($body, qr/\Qlog_ev('launch_session_failed', { reason => 'wt-not-found' });\E/,
        "AC-5.2: log_ev('launch_session_failed', {reason=>'wt-not-found'}) is present verbatim");
    like($body, qr/\Qreturn 'redraw';\E/, "AC-5.2: return 'redraw'; is present");

    like($body, qr/\QTerm::ReadKey::ReadKey(0)\E/, 'AC-5.3: the blocking Term::ReadKey::ReadKey(0) call is present');
    like($body, qr/\QTerm::ReadKey::ReadMode('restore')\E/, "AC-5.3: ReadMode('restore') is present");
    like($body, qr/\QTerm::ReadKey::ReadMode('cbreak')\E/, "AC-5.3: ReadMode('cbreak') is present");

    my ($gate_to_redraw) = $body =~ /if \(!\$wt\) \{(.*?)return 'redraw';/s;
    ok(defined $gate_to_redraw, 'prereq: the "if (!$wt) {...return redraw;" fail-loud block is extractable');
    if (defined $gate_to_redraw) {
        for my $forbidden (qw(wt_profile_plan WtProfile profile ensure_fragment)) {
            unlike($gate_to_redraw, qr/\Q$forbidden\E/, "AC-5.4: fail-loud block does not mention '$forbidden'");
        }
        unlike($gate_to_redraw, qr/-p\b/, "AC-5.4: fail-loud block does not mention -p");
        # counter-fixture: prove the detector actually fires on a block that
        # DOES mention the forbidden text.
        my $dirty_block = "if (!\$wt) { WtProfile::ensure_fragment(1); return 'redraw';";
        like($dirty_block, qr/\QWtProfile\E/, 'AC-5.4 counter-fixture: the WtProfile detector fires when the text is actually present');
    }

    my $idx_redraw_local = index($body, "return 'redraw';");
    my $idx_plan_local   = index($body, 'wt_profile_plan(');
    ok($idx_redraw_local >= 0 && $idx_redraw_local < $idx_plan_local,
        "AC-5.5: index(return 'redraw';) < index(wt_profile_plan() -- profile work is unreachable when wt.exe is missing");

    # Built by concatenation (never as one contiguous literal) so this file's
    # OWN source never contains the LOCALAPPDATA environment-key reference
    # AC-6.2 below forbids, even though the VALUE (used only for read-only
    # text matching against launcher.pl, never to read the real environment)
    # must equal it for AC-5.6 to mean anything.
    my $find_wt_line = 'my $wt = Dashboard::find_wt(' . '$ENV{PATH}' . ', ' . '$ENV' . '{LOCALAPPDATA}' . ');';
    like($body, qr/\Q$find_wt_line\E/,
        'AC-5.6: find_wt is called verbatim with PATH and LOCALAPPDATA');
    like($body, qr/if \(!\$wt\) \{/, 'AC-5.6: the if (!$wt) gate is present, unchanged');
}

# =============================================================================
# AC-6 -- no test launches anything (criterion 5); this asserts ITS OWN
# source, so the rule cannot silently rot as this file is edited later.
# =============================================================================
{
    my $self_src = slurp(__FILE__);
    ok(defined($self_src) && length($self_src), 'prereq: this file can read its own source via __FILE__');

    if (defined $self_src) {
        # NOTE: every test-description STRING below is worded to avoid the
        # very adjacency it is checking for -- a naive scan cannot tell a
        # live call from a description OF that call, so the description
        # itself must also stay clean, or it would trip its own detector.
        my $system_count = () = $self_src =~ /\bsystem\s*\(/g;
        is($system_count, 1, 'AC-6.1: this file spawns exactly one live subprocess (the single AC-8.1 perl-dash-c helper)');

        my $backtick_count = () = $self_src =~ /\x60/g;
        is($backtick_count, 0, 'AC-6.1: this file contains no backtick character');

        my $qx_count = () = $self_src =~ /\bqx\s*[\(\/\{\#]/g;
        is($qx_count, 0, 'AC-6.1: this file performs no qx-style subprocess capture');

        my $exec_count = () = $self_src =~ /\bexec\s*\(/g;
        is($exec_count, 0, 'AC-6.1: this file makes no exec-builtin call');

        my $pipe_char = chr(124);
        my $has_pipe_open = ($self_src =~ /\Q$pipe_char\E-/) || ($self_src =~ /-\Q$pipe_char\E/);
        ok(!$has_pipe_open, 'AC-6.1: this file opens no pipe-mode filehandle (neither dash-pipe nor pipe-dash form)');

        # counter-fixtures: prove each detector above fires on input crafted
        # to trip it, so a future edit that removes a check is itself detectable.
        # Every forbidden call-form below is assembled from a variable holding
        # just the bare word, joined to a separately-quoted open paren -- so
        # THIS FILE's own source text never pairs the bare words directly
        # with their invocation delimiter anywhere except the one legitimate
        # AC-8.1 helper (qx-style and exec-builtin forms never legitimately
        # appear at all). Written as plain adjacent literals, the self-scan
        # just above (which greps the WHOLE file, including this very
        # fixture) would count its own counter-fixture as a real violation.
        my ($sysw2, $qxw2, $execw2) = ('system', 'qx', 'exec');
        my $fixture = 'my $x = ' . chr(96) . 'echo hi' . chr(96) . ';'
                    . " $sysw2" . '("y");'
                    . " $qxw2"  . '(z);'
                    . " $execw2" . '("w");'
                    . ' open(my $fh, "' . chr(124) . '-", "cmd");';
        is(scalar(() = $fixture =~ /\x60/g), 2, 'AC-6.1 counter-fixture: the backtick detector fires on a real backtick pair');
        is(scalar(() = $fixture =~ /\bsystem\s*\(/g), 1, 'AC-6.1 counter-fixture: the live-subprocess detector fires on real input');
        is(scalar(() = $fixture =~ /\bqx\s*[\(\/\{\#]/g), 1, 'AC-6.1 counter-fixture: the qx-style detector fires on real input');
        is(scalar(() = $fixture =~ /\bexec\s*\(/g), 1, 'AC-6.1 counter-fixture: the exec-builtin detector fires on real input');
        ok((($fixture =~ /\Q$pipe_char\E-/) || ($fixture =~ /-\Q$pipe_char\E/)),
            'AC-6.1 counter-fixture: the pipe-mode detector fires on a real dash-pipe mode string');

        # AC-6.2: no executed wt.exe (only as expected-argv data), no
        # container runtime (name assembled from parts so this check itself
        # never contains the literal word), and launcher.pl appears only as
        # a read/perl-dash-c path.
        my @wt_lines = grep { /wt\.exe/ } split /\n/, $self_src;
        my @wt_bad = grep { /\b(?:system|exec)\s*\(|\x60/ } @wt_lines;
        is(scalar(@wt_bad), 0, 'AC-6.2: no line mentioning wt.exe also spawns anything on that same line');

        my $runtime_word = join('', qw(p o d m a n));
        unlike($self_src, qr/\Q$runtime_word\E/i, 'AC-6.2: this file never mentions the container runtime by name');

        my @launcher_lines = grep { /launcher\.pl/ } split /\n/, $self_src;
        my @launcher_bad = grep { /\b(?:system|exec)\s*\(|\x60/ } @launcher_lines;
        is(scalar(@launcher_bad), 0, 'AC-6.2: no line mentioning launcher.pl also spawns anything on that same line (it is a path only)');

        my $env_marker = '$ENV' . '{LOCALAPPDATA}';
        unlike($self_src, qr/\Q$env_marker\E/, 'AC-6.2: this file never references the LOCALAPPDATA environment key -- every plan test injects seams instead');

        # AC-6.3: no filesystem writes anywhere in this file -- no 2-arg or
        # 3-arg open() in a write/append mode.
        my $write_open_count = () = $self_src =~ /open\s*\([^)]*,\s*['"]>{1,2}['"]/g;
        is($write_open_count, 0, 'AC-6.3: this file makes no write-mode or append-mode filehandle open');
        # 'open' and its open paren built as separate literals so this file's
        # own source never contains a write-mode open pattern for its own
        # AC-6.3 self-scan (two lines above) to falsely trip on.
        my $write_fixture = 'open' . "(my \$fh, '>', '/tmp/x');";
        is(scalar(() = $write_fixture =~ /open\s*\([^)]*,\s*['"]>{1,2}['"]/g), 1,
            'AC-6.3 counter-fixture: the write-mode-open detector fires on real input');
    }
}

# =============================================================================
# AC-7 -- the doc (criterion 7)
# =============================================================================
{
    my $doc = slurp($DOC);
    ok(defined($doc), 'AC-7.1: plugins/sandbox/docs/wt-profile.md exists and is readable')
        or diag("not found at $DOC (expected -- not yet written)");

    SKIP: {
        skip 'AC-7.1..7.4: doc not present -- not yet written', 15 unless defined $doc;

        cmp_ok(length($doc), '>=', 500, 'AC-7.1: doc is at least 500 bytes');

        for my $literal (qw(claude-sandbox.json scrollbarState hidden Fragments), 'Windows Terminal',
                          'Deleting it is not durable', 'editing ccpraxis', 'still fails loudly') {
            like($doc, qr/\Q$literal\E/, "AC-7.2: doc contains '$literal'");
        }
        like($doc, qr/off-switch/i, "AC-7.2: doc contains 'off-switch' (case-insensitive)");

        unlike($doc, qr/--no-profile/, 'AC-7.3: doc does not mention --no-profile');
        unlike($doc, qr/CCPRAXIS_/, 'AC-7.3: doc does not mention any CCPRAXIS_ env var');

        like($doc, qr/\[c\]/, 'AC-7.4: doc mentions the [c] key');
        ok(($doc =~ /only when .{0,40}differ/i) || ($doc =~ /not rewritten/),
            'AC-7.4: doc states the write-only-when-different rule');
    }
}

# =============================================================================
# AC-8 -- hygiene (criterion 8)
# =============================================================================
{
    # THE ONE subprocess this file spawns, used for both files below --
    # verified above (AC-6.1) to be the only live-subprocess call in this
    # whole file.
    sub _perl_dash_c_ok {
        my ($path) = @_;
        my $rc = system($^X, '-c', $path);
        return $rc == 0;
    }
    ok(_perl_dash_c_ok($DASHBOARD_PM), 'AC-8.1: perl -c Dashboard.pm exits 0');
    ok(_perl_dash_c_ok($LAUNCHER),     'AC-8.1: perl -c launcher.pl exits 0');
}

done_testing();
