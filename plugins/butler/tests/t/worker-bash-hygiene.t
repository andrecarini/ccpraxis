#!/usr/bin/env perl
# platform: any
# Oracle for blueprint never-halt, package 01-worker-bash-hygiene
# (specs/01-worker-bash-hygiene-spec.md, sec 4, AC-1..AC-18). Exercises the
# new GB-h rule (Decision 4 (a)-(d)) added to GuardBash.pm's run() between
# GB-c and GB-d.
#
# WRITTEN BLIND TO THE IMPLEMENTATION: derived only from the spec text and
# Decisions 3, 4, 10, 11, 14, 18 (blueprint.md). GuardBash.pm's _gb_h,
# hyg_targets, _hyg_commands and _hyg_resolve DO NOT EXIST YET at the time
# this file is written -- every case below is expected RED until the
# implementer adds GB-h, EXCEPT the "allow" halves of AC-2/AC-6/AC-7/AC-10,
# which already pass today because nothing new denies them yet (that is not
# vacuous: AC-1/AC-4/AC-5/AC-8/etc. pin the corresponding deny side, and this
# file's own AC-12 fail-open case proves the deny side is not a pre-existing
# accident).
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Find qw(find);
use File::Spec ();
use Cwd ();
use JSON::PP ();
use Time::HiRes ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

(my $DIRNAME = dirname(__FILE__)) =~ s{\\}{/}g;
my $BUTLER_DIR = "$DIRNAME/../..";
(my $REPO_ROOT = Cwd::abs_path("$DIRNAME/../../../..") // "$DIRNAME/../../../..") =~ s{\\}{/}g;

# BpHook::Guards::Common already exists (package 14) and is reused, not
# changed, by this package -- its echo_cmd()/fit() are the exact functions
# GB-h's own messages go through (spec sec 3), so this file uses them to
# build expected text instead of re-implementing truncation rules.
require BpHook::Guards::Common;
# BpHook::Guards::GuardBash already exists too; requiring it here (rather
# than only implicitly via GuardHarness::run_module's first call) is what
# makes the AC-12 seam ("local *BpHook::Guards::GuardBash::_hyg_commands")
# safe regardless of block order below.
require BpHook::Guards::GuardBash;
# BpHook::ArmOnEntry (package 07 of blueprint hook-continuity-remake) is a
# read-only dependency reused as-is for AC-45's blast-radius check: report
# 3's M1 finding is that a broken whole-text mask ARMS an ordinary session
# as a driver via director_next_call(), never GB-h-specific, so this pins it
# directly against ArmOnEntry's own sub, the same way AC-42 pins
# BpHook::_segments()/invocations() directly.
require BpHook::ArmOnEntry;

sub read_bytes {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# ===========================================================================
# Fixtures (spec sec 4, "Fixtures"). One base tempdir B, then B/repo (with
# .git/, .ccpraxis-local-data/ and sub/), B/tmp-fixture-longname,
# B/home-fixture-longname, B/outside-fixture-longname.
# ===========================================================================
my $BASE_TMPDIR = tempdir(CLEANUP => 1);
(my $B = $BASE_TMPDIR) =~ s{\\}{/}g;
$B =~ s{/+\z}{};

my $REPO    = "$B/repo";
my $TMPFIX  = "$B/tmp-fixture-longname";
my $HOMEFIX = "$B/home-fixture-longname";
my $OUTSIDE = "$B/outside-fixture-longname";
my $CCPDIR  = "$REPO/.ccpraxis-local-data";
my $GITDIR  = "$REPO/.git";
my $SUBDIR  = "$REPO/sub";

make_path($GITDIR, $CCPDIR, $SUBDIR, $TMPFIX, $HOMEFIX, $OUTSIDE);

ok(-d $REPO && -d $GITDIR && -d $CCPDIR && -d $SUBDIR, 'fixture setup: repo tree exists');
ok(-d $TMPFIX && -d $HOMEFIX && -d $OUTSIDE, 'fixture setup: tmp/home/outside fixtures exist');

# ---------------------------------------------------------------------------
# Callers (spec sec 4, "Callers"). One shared armed driver session serves
# both the subagent and driver-main callers (role() only looks at
# session_id; agent_id is a separate payload field).
# ---------------------------------------------------------------------------
my $STATE_BASE = GuardHarness::fresh_state();
my $DRIVER_SID = 'wbh-driver-sid';
ok(GuardHarness::arm($DRIVER_SID, 'driver'), 'fixture setup: driver session armed');

my @CALLERS = (
    { name => 'subagent',    session_id => $DRIVER_SID, agent_id => 'agent1', ledger => undef,          hint => 0 },
    { name => 'driver-main', session_id => $DRIVER_SID, agent_id => undef,    ledger => undef,          hint => 1 },
    { name => 'coordinator', session_id => undef,        agent_id => undef,    ledger => '/x/ledger.md', hint => 0 },
);
sub caller_by_name { my ($n) = @_; my ($c) = grep { $_->{name} eq $n } @CALLERS; return $c }

# ---------------------------------------------------------------------------
# payload(%o) -- a Bash tool_input payload (guards-remake-bash.t's own shape,
# plus permission_mode).
# ---------------------------------------------------------------------------
sub payload {
    my (%o) = @_;
    my $ti = { command => $o{cmd} };
    $ti->{run_in_background} = $o{run_in_background} if exists $o{run_in_background};
    my $p = { tool_name => 'Bash', tool_input => $ti };
    $p->{session_id}      = $o{session_id}      if exists $o{session_id};
    $p->{agent_id}        = $o{agent_id}         if exists $o{agent_id};
    $p->{cwd}             = $o{cwd}              if exists $o{cwd};
    $p->{permission_mode} = $o{permission_mode}  if exists $o{permission_mode};
    return $p;
}

# ---------------------------------------------------------------------------
# run_for($caller, $cmd, %o) -- GuardHarness::run_module for Guards::GuardBash,
# with the fixture env overlay Decision 11(12)/(13) and sec 4 require, and
# the payload cwd defaulted to B/repo unless %o overrides it. %o:
#   env => {}, cwd => $path, no_cwd => 1, permission_mode => STR,
#   run_in_background => JSON::PP::true()/false()
# ---------------------------------------------------------------------------
sub run_for {
    my ($c, $cmd, %o) = @_;
    my %env = (
        CLAUDE_PROJECT_DIR => $REPO,
        TMP  => $TMPFIX, TEMP => $TMPFIX, TMPDIR => $TMPFIX,
        HOME => $HOMEFIX, USERPROFILE => $HOMEFIX,
        CCPRAXIS_DATA_DIR => $CCPDIR,
    );
    $env{BP_LEDGER} = $c->{ledger} if defined $c->{ledger};
    %env = (%env, %{ $o{env} // {} });

    my %pargs = (cmd => $cmd);
    if ($o{no_cwd}) { }
    elsif (exists $o{cwd}) { $pargs{cwd} = $o{cwd} }
    else { $pargs{cwd} = $REPO }
    $pargs{session_id}        = $c->{session_id}        if defined $c->{session_id};
    $pargs{agent_id}          = $c->{agent_id}          if defined $c->{agent_id};
    $pargs{permission_mode}   = $o{permission_mode}     if exists $o{permission_mode};
    $pargs{run_in_background} = $o{run_in_background}   if exists $o{run_in_background};

    return GuardHarness::run_module('Guards::GuardBash', payload(%pargs), env => \%env);
}

# ---------------------------------------------------------------------------
# Exact deny-message line-1 builders (spec sec 3, B-1/B-2/B-3).
# ---------------------------------------------------------------------------
sub b1_line1 {
    my ($shape) = @_;
    return "BLOCKED: $shape changes the working directory, which unattended runs never do (also inside chains, subshells and bash -c).";
}
my $HINT_TEXT = 'If the operator asked for this, ask them to run it themselves with the ! prefix.';

# ===========================================================================
# Windows-only path forms (spec sec 4: "obtained with cygpath -m, cygpath -u,
# cygpath -w and cygpath -d, and skipped with a reason when cygpath is
# missing or the short form equals the long form"). AND: the driver's own
# risk check (Decision 18 Q3 / spec sec 5) -- verify Git-for-Windows perl's
# stat (dev, ino) is stable and non-zero across a directory's long, 8.3 and
# /tmp forms BEFORE writing cases that rely on it.
# ===========================================================================
my $HAVE_CYGPATH = do { my $v = `cygpath --version 2>/dev/null`; (defined $v && length $v) ? 1 : 0 };

sub cyg {
    my @flags_and_path = @_;
    my $path = pop @flags_and_path;
    return undef unless $HAVE_CYGPATH;
    my $flags = join ' ', map { "-$_" } @flags_and_path;
    my $out = `cygpath $flags "$path" 2>/dev/null`;
    return undef unless defined $out;
    chomp $out;
    return length($out) ? $out : undef;
}

my $IS_WINFAM = ($^O =~ /^(?:MSWin32|msys|cygwin)$/) ? 1 : 0;
my $SKIP_WIN_REASON;
if (!$IS_WINFAM)        { $SKIP_WIN_REASON = 'not a Windows-family perl' }
elsif (!$HAVE_CYGPATH)  { $SKIP_WIN_REASON = 'cygpath is not available on this host' }
else {
    my $short = cyg('d', $OUTSIDE);
    my $long  = cyg('w', $OUTSIDE);
    if (!defined $short || !defined $long) {
        $SKIP_WIN_REASON = 'cygpath could not produce a short/long form for the outside fixture';
    }
    else {
        (my $sn = $short) =~ s{\\}{/}g;
        (my $ln = $long)  =~ s{\\}{/}g;
        $SKIP_WIN_REASON = 'the 8.3 short form equals the long form on this host (short names disabled?)'
            if lc($sn) eq lc($ln);
    }
}

# --- the inode-stability risk check (Decision 18 Q3), reported unconditionally ---
{
    my $inode_ok = 0;
    my $reason = '';
    if (!$IS_WINFAM) {
        $reason = 'not a Windows-family perl -- identity fallback is a Windows-only concern here';
        $inode_ok = 1; # nothing to verify off Windows
    }
    else {
        my @s_long = stat($TMPFIX);
        my $tmp_native_form = $TMPFIX; # already forward-slash, native to this fixture
        my $short_tmp = cyg('d', $TMPFIX);
        my $posix_tmp;
        if ($TMPFIX =~ m{^([A-Za-z]):/(.*)$}) { $posix_tmp = '/' . lc($1) . '/' . $2 }
        if (@s_long && $s_long[0] && $s_long[1]) {
            my $dev = $s_long[0]; my $ino = $s_long[1];
            my $ok = 1;
            if (defined $short_tmp) {
                (my $sf = $short_tmp) =~ s{\\}{/}g;
                my @s2 = stat($sf);
                $ok &&= (@s2 && $s2[0] == $dev && $s2[1] == $ino);
            }
            if (defined $posix_tmp && -d $posix_tmp) {
                my @s3 = stat($posix_tmp);
                $ok &&= (@s3 && $s3[0] == $dev && $s3[1] == $ino);
            }
            $inode_ok = $ok ? 1 : 0;
            $reason = $ok
                ? "stat($TMPFIX) = (dev=$dev, ino=$ino), stable and non-zero across its short/posix forms"
                : "stat($TMPFIX) = (dev=$dev, ino=$ino) did NOT agree across its short/posix aliases";
        }
        else {
            $reason = 'stat() on the tmp fixture returned a zero/undef dev or ino';
        }
    }
    ok($inode_ok, "risk check (Decision 18 Q3): $reason");
}

my %OUTSIDE_FORMS;
my %TMP_FORMS;
my %HOME_FORMS;
unless ($SKIP_WIN_REASON) {
    %OUTSIDE_FORMS = (c => cyg('m', $OUTSIDE), u => cyg('u', $OUTSIDE), w => cyg('w', $OUTSIDE), d => cyg('s','m',$OUTSIDE));
    %TMP_FORMS     = (c => cyg('m', $TMPFIX),  u => cyg('u', $TMPFIX),  w => cyg('w', $TMPFIX),  d => cyg('s','m',$TMPFIX));
    %HOME_FORMS    = (c => cyg('m', $HOMEFIX), u => cyg('u', $HOMEFIX), w => cyg('w', $HOMEFIX), d => cyg('s','m',$HOMEFIX));
}

sub win_case {
    my ($code) = @_;
    SKIP: {
        skip($SKIP_WIN_REASON, 1) if $SKIP_WIN_REASON;
        $code->();
    }
}

# ===========================================================================
# AC-1 / AC-2 -- (a) directory-change denial, and its allow-list, all 3
# callers.
# ===========================================================================
{
    my @deny_cases = (
        ['cd X && git status'    => 'cd'],
        ['cd X; ls'              => 'cd'],
        ['(cd X && make)'        => 'cd'],
        [q{bash -c "cd X && ls"} => 'cd'],
        ['pushd X'               => 'pushd'],
    );
    my @allow_cases = ('git -C X status', 'ls X', 'ls cd', q{echo "then cd X"});

    for my $caller (@CALLERS) {
        for my $c (@deny_cases) {
            my ($cmd, $shape) = @$c;
            my $res = run_for($caller, $cmd);
            is($res->{rc}, 2, "AC-1: $caller->{name} '$cmd' -> deny") or diag("cmd: $cmd");
            my @lines = split /\n/, $res->{err};
            is($lines[0] // '', b1_line1($shape),
               "AC-1: $caller->{name} '$cmd' -> line 1 is B-1 with shape '$shape'");
        }
        for my $cmd (@allow_cases) {
            my $res = run_for($caller, $cmd);
            is($res->{rc}, 0, "AC-2: $caller->{name} '$cmd' -> allow") or diag("cmd: $cmd");
        }
    }
}

# ===========================================================================
# AC-3 -- message format: line budget (4 w/ hint for driver-main, 3 with no
# hint text for subagent/coordinator), <=160 chars/line, line 3 is
# "Command: <echo>". One (a), one (b), one (c) deny per caller.
# ===========================================================================
{
    my %reps = (
        a => 'cd X && ls',
        b => "touch $OUTSIDE/f",
        c => 'rm -rf .git',
    );
    # Coordinators (BP_LEDGER set) have their own GB-a "rm -rf" rule, which
    # wins over GB-h's protected-path message (spec Sec 3 B-4). Use a
    # protected-root fixture GB-a does not intercept (no mv rule in GB-a) so
    # this block still exercises GB-h's B-3 shape for the coordinator caller.
    my %coord_reps = (%reps, c => "mv $REPO $TMPFIX/x");
    for my $caller (@CALLERS) {
        my $is_coord = ($caller->{name} eq 'coordinator');
        for my $shape_key (qw(a b c)) {
            my $cmd = $is_coord ? $coord_reps{$shape_key} : $reps{$shape_key};
            my $res = run_for($caller, $cmd);
            next unless is($res->{rc}, 2, "AC-3 setup: $caller->{name} ($shape_key) '$cmd' -> deny");
            my @lines = split /\n/, $res->{err};
            pop @lines while @lines && $lines[-1] eq '';
            if ($caller->{hint}) {
                is(scalar(@lines), 4, "AC-3: $caller->{name} ($shape_key) has exactly 4 lines");
                is($lines[3] // '', $HINT_TEXT, "AC-3: $caller->{name} ($shape_key) line 4 is the hint text");
            }
            else {
                is(scalar(@lines), 3, "AC-3: $caller->{name} ($shape_key) has exactly 3 lines");
                unlike($res->{err}, qr/! prefix/, "AC-3: $caller->{name} ($shape_key) carries no '! prefix' text");
            }
            is($lines[2] // '', 'Command: ' . BpHook::Guards::Common::echo_cmd($cmd),
               "AC-3: $caller->{name} ($shape_key) line 3 is 'Command: <echo>'");
            for my $i (0 .. $#lines) {
                cmp_ok(length($lines[$i]), '<=', 160, "AC-3: $caller->{name} ($shape_key) line " . ($i+1) . " length <= 160");
            }
        }
    }
}

# ===========================================================================
# AC-4 / AC-6 -- (b) outside-the-sandbox denial and its allow set.
# ===========================================================================
my @WRITE_SHAPES = (
    ['rm'       => sub { my ($t) = @_; "rm $t" },                        'rm'],
    ['rmdir'    => sub { my ($t) = @_; "rmdir $t" },                     'rmdir'],
    ['touch'    => sub { my ($t) = @_; "touch $t" },                     'touch'],
    ['mkdir -p' => sub { my ($t) = @_; "mkdir -p $t" },                  'mkdir'],
    ['echo >'   => sub { my ($t) = @_; "echo x > $t" },                  '>'],
    ['echo >>'  => sub { my ($t) = @_; "echo x >> $t" },                 '>>'],
    ['tee'      => sub { my ($t) = @_; "echo x | tee $t" },              'tee'],
    ['sed -i'   => sub { my ($t) = @_; "sed -i 's/a/b/' $t" },           'sed -i'],
    ['perl -i'  => sub { my ($t) = @_; "perl -pi -e 's/a/b/' $t" },      'perl -i'],
    ['truncate' => sub { my ($t) = @_; "truncate -s 0 $t" },             'truncate'],
);
my @MVCP_SHAPES = (
    ['mv' => sub { my ($s, $d) = @_; "mv $s $d" },       'mv'],
    ['cp' => sub { my ($s, $d) = @_; "cp $s $d" },       'cp'],
    ['ln' => sub { my ($s, $d) = @_; "ln -s $s $d" },    'ln'],
);

{
    for my $caller (@CALLERS) {
        for my $s (@WRITE_SHAPES) {
            my ($label, $build, $shape) = @$s;
            my $cmd = $build->("$OUTSIDE/f");
            my $res = run_for($caller, $cmd);
            is($res->{rc}, 2, "AC-4: $caller->{name} $label outside -> deny") or diag("cmd: $cmd");
            if ($caller->{name} ne 'coordinator') {
                my @lines = split /\n/, $res->{err};
                like($lines[0] // '', qr/^\QBLOCKED: $shape writes outside the repo and the temp dir: \E.*f$/,
                     "AC-4: $caller->{name} $label -> B-2 line 1, shape '$shape', target ending in last component");
            }
        }
        for my $s (@MVCP_SHAPES) {
            my ($label, $build, undef) = @$s;
            my $cmd = $build->("$REPO/a", "$OUTSIDE/b");
            is(run_for($caller, $cmd)->{rc}, 2, "AC-4: $caller->{name} $label destination outside -> deny") or diag("cmd: $cmd");
        }
    }
}

{
    for my $caller (@CALLERS) {
        for my $s (@WRITE_SHAPES) {
            my ($label, $build, undef) = @$s;
            for my $td (["$REPO/f" => 'repo absolute'], ['f' => 'relative (cwd repo)'], ["$TMPFIX/f" => 'tmp absolute']) {
                my ($target, $desc) = @$td;
                my $cmd = $build->($target);
                is(run_for($caller, $cmd)->{rc}, 0, "AC-6: $caller->{name} $label -> allow ($desc)") or diag("cmd: $cmd");
            }
        }
        for my $s (@MVCP_SHAPES) {
            my ($label, $build, undef) = @$s;
            my $cmd = $build->("$REPO/a", "$REPO/b");
            is(run_for($caller, $cmd)->{rc}, 0, "AC-6: $caller->{name} $label repo->repo -> allow") or diag("cmd: $cmd");
        }
        for my $form (qw(c u d)) {
            win_case(sub {
                my $base = $TMP_FORMS{$form};
                unless (defined $base) { fail("AC-6: $caller->{name} TMP $form form -> cygpath produced no value"); return }
                my $res = run_for($caller, "touch $base/f");
                is($res->{rc}, 0, "AC-6: $caller->{name} touch TMP ($form form) -> allow");
            });
        }
    }
}

# ===========================================================================
# AC-5 -- Windows-only outside-target forms (C:/, /c/, single-quoted
# backslash, 8.3), for touch/echo>/rm, all 3 callers.
# ===========================================================================
{
    my @shapes = (
        ['touch'   => sub { my ($t) = @_; "touch $t" }],
        ['echo x >' => sub { my ($t) = @_; "echo x > $t" }],
        ['rm'      => sub { my ($t) = @_; "rm $t" }],
    );
    for my $caller (@CALLERS) {
        for my $form (qw(c u d)) {
            for my $s (@shapes) {
                my ($label, $build) = @$s;
                win_case(sub {
                    my $base = $OUTSIDE_FORMS{$form};
                    unless (defined $base) { fail("AC-5: $caller->{name} $label ($form form) -> cygpath produced no value"); return }
                    my $res = run_for($caller, $build->("$base/f"));
                    is($res->{rc}, 2, "AC-5: $caller->{name} $label outside ($form form) -> deny");
                });
            }
        }
        for my $s (@shapes) {
            my ($label, $build) = @$s;
            win_case(sub {
                my $base = $OUTSIDE_FORMS{w};
                unless (defined $base) { fail("AC-5: $caller->{name} $label (backslash form) -> cygpath produced no value"); return }
                my $target = "$base\\f";
                my $res = run_for($caller, $build->("'$target'"));
                is($res->{rc}, 2, "AC-5: $caller->{name} $label outside (single-quoted backslash form) -> deny");
            });
        }
    }
}

# ===========================================================================
# AC-7 -- never-a-target redirects allow; relative target resolves against
# the payload cwd; an absent cwd never falls back to the process cwd.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    for my $cmd (
        'perl x.pl > /dev/null 2>&1',
        'perl x.pl 2>/dev/null',
        'perl x.pl >&2',
        'perl x.pl | tee /dev/stderr',
    ) {
        is(run_for($driver_main, $cmd)->{rc}, 0, "AC-7: driver-main '$cmd' -> allow (never-a-target)") or diag("cmd: $cmd");
    }
    is(run_for($driver_main, 'touch f', cwd => $OUTSIDE)->{rc}, 2,
       'AC-7: driver-main touch f, payload cwd OUTSIDE -> deny (relative resolves against payload cwd)');
    is(run_for($driver_main, 'touch f', no_cwd => 1)->{rc}, 0,
       'AC-7: driver-main touch f, no cwd in payload -> allow (never falls back to process cwd)');
}

# ===========================================================================
# AC-8 -- (c) protected roots, denied everywhere, including inside the repo.
# ===========================================================================
{
    my @common_cases = (
        "rm -rf $CCPDIR",
        "rm -rf $OUTSIDE/.ccpraxis-local-data",
        'rm -rf .git',
        'rm -rf .git/',
        'rmdir .git',
        "mv $REPO $TMPFIX/x",
        'rm -rf ~',
        'rm -rf ~/',
        'rm -rf %USERPROFILE%',
        'rm -rf .',
        'rm -rf ..',
        'rm -rf "$X/.git"',
    );
    push @common_cases, ($IS_WINFAM ? 'rm -rf C:/' : 'rm -rf /');

    for my $name (qw(subagent driver-main)) {
        my $caller = caller_by_name($name);
        for my $cmd (@common_cases) {
            my $res = run_for($caller, $cmd);
            is($res->{rc}, 2, "AC-8: $name '$cmd' -> deny") or diag("cmd: $cmd");
            my @lines = split /\n/, $res->{err};
            like($lines[0] // '', qr/^BLOCKED: .*of a protected path/, "AC-8: $name '$cmd' -> B-3 line 1");
        }
    }

    win_case(sub {
        my $base = $HOME_FORMS{w};
        unless (defined $base) { fail('AC-8: driver-main rm -rf HOME backslash form -> cygpath produced no value'); return }
        my $driver_main = caller_by_name('driver-main');
        my $res = run_for($driver_main, "rm -rf '$base'");
        is($res->{rc}, 2, 'AC-8: driver-main rm -rf HOME backslash form -> deny');
    });
    win_case(sub {
        my $base = $HOME_FORMS{u};
        unless (defined $base) { fail('AC-8: driver-main rm -rf HOME /c/ form -> cygpath produced no value'); return }
        my $driver_main = caller_by_name('driver-main');
        my $res = run_for($driver_main, "rm -rf $base");
        is($res->{rc}, 2, 'AC-8: driver-main rm -rf HOME /c/ form -> deny');
    });

    my $coord = caller_by_name('coordinator');
    for my $cmd ('rm -r .git', "mv $REPO $TMPFIX/x") {
        my $res = run_for($coord, $cmd);
        is($res->{rc}, 2, "AC-8: coordinator '$cmd' -> deny") or diag("cmd: $cmd");
        my @lines = split /\n/, $res->{err};
        like($lines[0] // '', qr/of a protected path/, "AC-8: coordinator '$cmd' -> B-3 line 1");
    }
    for my $cmd ('rm -rf .git', "rm -rf $OUTSIDE/.ccpraxis-local-data") {
        is(run_for($coord, $cmd)->{rc}, 2, "AC-8: coordinator '$cmd' -> deny (any message, B-4)") or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-9 -- (c) applies inside the repo and inside TMP, for driver main.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    is(run_for($driver_main, "rm -rf $TMPFIX/p/.git")->{rc}, 2, 'AC-9: rm -rf under TMP targeting .git -> deny');
    is(run_for($driver_main, "rm -r $REPO/sub/.ccpraxis-local-data")->{rc}, 2, 'AC-9: rm -r under repo targeting .ccpraxis-local-data -> deny');
    is(run_for($driver_main, "rm -rf $REPO/sub/x")->{rc}, 0, 'AC-9: rm -rf ordinary file under repo -> allow');
    is(run_for($driver_main, "rm -rf $TMPFIX/p/x")->{rc}, 0, 'AC-9: rm -rf ordinary file under TMP -> allow');
}

# ===========================================================================
# AC-10 -- unresolvable targets never denied by (b) or (c) (Decision 4(d)).
# ===========================================================================
{
    for my $name (qw(subagent driver-main)) {
        my $caller = caller_by_name($name);
        for my $cmd (
            'rm "$VAR"', 'rm $(cmd)', 'rm -rf "$VAR"',
            'touch "$D/f"', 'echo x > "$OUT"',
            "rm $OUTSIDE/*.log",
        ) {
            is(run_for($caller, $cmd)->{rc}, 0, "AC-10: $name '$cmd' -> allow (unresolvable/glob)") or diag("cmd: $cmd");
        }
    }
    my $coord = caller_by_name('coordinator');
    for my $cmd ('rm "$VAR"', 'rm $(cmd)') {
        is(run_for($coord, $cmd)->{rc}, 0, "AC-10: coordinator '$cmd' -> allow") or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-11 -- prefilter: an unarmed, non-ledger session runs none of GB-h.
# ===========================================================================
{
    my $sid = 'wbh-unarmed-sid';
    for my $cmd ('cd X && ls', "touch $OUTSIDE/f", 'rm -rf ~') {
        my $res = GuardHarness::run_shim('guard-bash.sh', payload(cmd => $cmd, session_id => $sid), env => {});
        is($res->{rc}, 0, "AC-11: run_shim, unarmed/no-ledger, '$cmd' -> rc 0");
        is($res->{err}, '', "AC-11: run_shim, unarmed/no-ledger, '$cmd' -> empty stderr");
        is(GuardHarness::count_lines($res->{shim_log}, 'perl'), 0, "AC-11: run_shim, unarmed/no-ledger, '$cmd' -> 0 perl launches");
    }
    for my $cmd ('cd X && ls', "touch $OUTSIDE/f", 'rm -rf ~') {
        my $res = GuardHarness::run_module('Guards::GuardBash', payload(cmd => $cmd, session_id => $sid), env => {});
        is($res->{rc}, 0, "AC-11: run_module, unarmed sid, no BP_LEDGER, '$cmd' -> allow");
    }
    ok(GuardHarness::arm('wbh-manual-sid', 'manual'), 'AC-11 setup: session armed manual');
    for my $cmd ('cd X && ls', "touch $OUTSIDE/f", 'rm -rf ~') {
        my $res = GuardHarness::run_module('Guards::GuardBash', payload(cmd => $cmd, session_id => 'wbh-manual-sid'), env => {});
        is($res->{rc}, 0, "AC-11: run_module, manual-armed sid, no BP_LEDGER, '$cmd' -> allow");
    }
}

# ===========================================================================
# AC-12 -- fail-open (sec 2.1 test seam). _hyg_commands redefined to die ->
# GB-h allows silently; after the redefinition ends, the same commands deny
# again (proves the case is not vacuous).
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    {
        no warnings 'redefine';
        local *BpHook::Guards::GuardBash::_hyg_commands = sub { die "AC-12 injected failure\n" };
        for my $cmd ('cd X && ls', "touch $OUTSIDE/f") {
            my $res = run_for($driver_main, $cmd);
            is($res->{rc}, 0, "AC-12: fail-open, '$cmd' -> rc 0 with _hyg_commands injected to die");
            is($res->{out}, '', "AC-12: fail-open, '$cmd' -> empty stdout");
            is($res->{err}, '', "AC-12: fail-open, '$cmd' -> empty stderr");
        }
    }
    for my $cmd ('cd X && ls', "touch $OUTSIDE/f") {
        my $res = run_for($driver_main, $cmd);
        is($res->{rc}, 2, "AC-12: after the redefinition ends, '$cmd' -> rc 2 (the fail-open case is not vacuous)");
    }
}

# ===========================================================================
# AC-13 -- permission mode (Decision 14 / Decision 18 Q1). bypassPermissions
# and dontAsk skip (a)/(b); every other value (or absent) applies them.
# (c) stays active even under bypassPermissions.
# ===========================================================================
{
    for my $caller (@CALLERS) {
        for my $mode (qw(bypassPermissions dontAsk)) {
            for my $c (['cd X && ls' => 'cd'], ["touch $OUTSIDE/f" => 'touch']) {
                my ($cmd, $shape) = @$c;
                my $res = run_for($caller, $cmd, permission_mode => $mode);
                is($res->{rc}, 0, "AC-13: $caller->{name} $shape under $mode -> allow ((a)/(b) skipped)") or diag("cmd: $cmd");
            }
        }
        for my $mode (qw(default acceptEdits plan)) {
            for my $c (['cd X && ls' => 'cd'], ["touch $OUTSIDE/f" => 'touch']) {
                my ($cmd, $shape) = @$c;
                my $res = run_for($caller, $cmd, permission_mode => $mode);
                is($res->{rc}, 2, "AC-13: $caller->{name} $shape under $mode -> deny") or diag("cmd: $cmd");
            }
        }
        for my $c (['cd X && ls' => 'cd'], ["touch $OUTSIDE/f" => 'touch']) {
            my ($cmd, $shape) = @$c;
            my $res = run_for($caller, $cmd);
            is($res->{rc}, 2, "AC-13: $caller->{name} $shape, no permission_mode field -> deny") or diag("cmd: $cmd");
        }
    }
    my $driver_main = caller_by_name('driver-main');
    my $res = run_for($driver_main, 'rm -rf .git', permission_mode => 'bypassPermissions');
    is($res->{rc}, 2, 'AC-13: driver-main rm -rf .git under bypassPermissions still denies (Decision 18 Q1: (c) stays active)');
}

# ===========================================================================
# AC-14 -- repo-root resolution: with CLAUDE_PROJECT_DIR/BP_PROJECT_ROOT both
# unset, R is found by walking up from cwd to the nearest .git; when no
# ancestor holds one, R is undef and (b) is skipped, but (a) still applies.
# ===========================================================================
{
    my %env_noroot = (
        TMP  => $TMPFIX, TEMP => $TMPFIX, TMPDIR => $TMPFIX,
        HOME => $HOMEFIX, USERPROFILE => $HOMEFIX,
        CCPRAXIS_DATA_DIR => $CCPDIR,
        CLAUDE_PROJECT_DIR => undef, BP_PROJECT_ROOT => undef,
    );
    my $res1 = GuardHarness::run_module('Guards::GuardBash',
        payload(cmd => "touch $REPO/f", cwd => $SUBDIR, session_id => $DRIVER_SID), env => \%env_noroot);
    is($res1->{rc}, 0, 'AC-14: cwd B/repo/sub, no CLAUDE_PROJECT_DIR/BP_PROJECT_ROOT, touch B/repo/f -> allow (R found via .git walk-up)');

    my $res2 = GuardHarness::run_module('Guards::GuardBash',
        payload(cmd => "touch $OUTSIDE/f", cwd => $SUBDIR, session_id => $DRIVER_SID), env => \%env_noroot);
    is($res2->{rc}, 2, 'AC-14: same fixture, touch OUTSIDE/f -> deny (R found via .git walk-up)');

    my $res3 = GuardHarness::run_module('Guards::GuardBash',
        payload(cmd => "touch $OUTSIDE/g", cwd => $OUTSIDE, session_id => $DRIVER_SID), env => \%env_noroot);
    is($res3->{rc}, 0, 'AC-14: cwd OUTSIDE (no ancestor .git), touch OUTSIDE/g -> allow ((b) skipped when R undef)');

    my $res4 = GuardHarness::run_module('Guards::GuardBash',
        payload(cmd => 'cd X && ls', cwd => $OUTSIDE, session_id => $DRIVER_SID), env => \%env_noroot);
    is($res4->{rc}, 2, 'AC-14: cwd OUTSIDE (R undef), cd X && ls -> deny ((a) unaffected by R)');
}

# ===========================================================================
# AC-15 -- precedence: GB-a/GB-b messages win over GB-h; GB-h wins over GB-d.
# ===========================================================================
{
    my $coord = caller_by_name('coordinator');

    my $res1 = run_for($coord, 'git checkout main && cd X');
    is($res1->{rc}, 2, 'AC-15: coordinator "git checkout main && cd X" -> deny');
    like($res1->{err}, qr/git working-tree\/history mutations/, 'AC-15: GB-a message wins over B-1');
    unlike($res1->{err}, qr/changes the working directory/, 'AC-15: B-1 text is NOT also printed');

    my $tmp = tempdir(CLEANUP => 1);
    (my $bp_dir = "$tmp/bp") =~ s{\\}{/}g;
    make_path("$bp_dir/runs");
    open(my $fh, '>:raw', "$bp_dir/runs/pkg1.active-worker") or die $!;
    print {$fh} 'bp-implementer';
    close $fh;
    my $res2 = run_for($coord, 'cd X && pnpm run test', env => { BP_DIR => $bp_dir, BP_PACKAGE => 'pkg1' });
    is($res2->{rc}, 2, 'AC-15: coordinator, fresh writer marker, "cd X && pnpm run test" -> deny');
    like($res2->{err}, qr/changes the working directory/, 'AC-15: B-1 message wins over the validation interlock');
    unlike($res2->{err}, qr/a write-capable worker \(/, 'AC-15: the validation-interlock text is NOT also printed');

    my $res3 = run_for($coord, 'sleep 1 && cd X', run_in_background => JSON::PP::true());
    is($res3->{rc}, 2, 'AC-15: coordinator, background "sleep 1 && cd X" -> deny');
    like($res3->{err}, qr/run_in_background/, "AC-15: GB-b's message wins (names run_in_background)");
}

# ===========================================================================
# AC-17 -- no ccpraxis hook or hook module ever emits permissionDecision ask
# (Decision 10).
# ===========================================================================
{
    my @scan_roots = (
        glob("$REPO_ROOT/plugins/*/hooks"),
        "$REPO_ROOT/plugins/butler/scripts/BpHook.pm",
        "$REPO_ROOT/plugins/butler/scripts/BpHook",
        "$REPO_ROOT/scripts/hooks",
        "$REPO_ROOT/global-config/settings.json",
        "$REPO_ROOT/.claude/settings.json",
    );
    my @files;
    for my $r (@scan_roots) {
        next unless defined $r && -e $r;
        if (-f $r) { push @files, $r; next }
        find(sub { push @files, $File::Find::name if -f $_ }, $r);
    }
    @files = map { (my $x = $_) =~ s{\\}{/}g; $x } @files;

    ok(scalar(@files) > 0, 'AC-17 setup: the scanned file set is non-empty');
    ok((scalar grep { m{/guard-bash\.sh$} } @files), 'AC-17 setup: scanned set includes guard-bash.sh');
    ok((scalar grep { m{/GuardBash\.pm$} } @files), 'AC-17 setup: scanned set includes GuardBash.pm');

    for my $f (@files) {
        my $src = read_bytes($f);
        next unless defined $src;
        unlike($src, qr/permissionDecision.{0,200}?['"]ask['"]/s,
               "AC-17: $f never emits permissionDecision ask") or diag("file: $f");
    }
}

# ===========================================================================
# AC-18 -- source hygiene (carried by existing SH-2 in guards-remake-bash.t;
# re-pinned here so this file's own criterion table is self-contained).
# ===========================================================================
{
    my $module = "$REPO_ROOT/plugins/butler/scripts/BpHook/Guards/GuardBash.pm";
    ok(-f $module, 'AC-18 precondition: GuardBash.pm exists on disk');
  SKIP: {
        skip 'AC-18: GuardBash.pm missing', 1 unless -f $module;
        my $src = read_bytes($module) // '';
        (my $stripped = $src) =~ s/^\s*#.*$//mg;
        unlike($stripped, qr/\bsystem\s*\(|\bexec\s*\(|\bexec\s+\S|`|\bqx\b|open\s*\([^)]*\|/,
               'AC-18: GuardBash.pm source never spawns (no system/exec/backtick/qx/pipe-open)');
    }
}

# ===========================================================================
# Decision 19 (reports/01-review.md, reports/01-redteam.md) regression
# batch. WRITTEN FROM THE REPORTS' OWN PROBE PAYLOADS, not from reading the
# implementation: every case below is quoted or paraphrased directly from a
# review/red-team finding. Everything here is expected RED until the
# implementer's Decision-19 fix batch lands, except where a case is
# explicitly marked as a paired control.
# ===========================================================================

# ===========================================================================
# AC-19 -- MUST list, bullets 1-6 (Decision 19). One case per bullet, taken
# from the reports' own probe tables.
# ===========================================================================

# 19a (redteam M1): a redirect operator glued to the preceding word (no
# space) must still be recognised as a redirect.
{
    my $driver_main = caller_by_name('driver-main');
    for my $cmd ("echo x>$OUTSIDE/f", qq{echo "x">>$OUTSIDE/f}) {
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-19a (redteam M1, MUST): '$cmd' -> deny (glued redirect)")
            or diag("cmd: $cmd");
    }
}

# 19b (review M1 / redteam M2, MUST): a redirect at the start of a word, or
# a segment that is only a redirect (no command word), must still deny.
{
    my $driver_main = caller_by_name('driver-main');
    for my $cmd (
        "> $OUTSIDE/f",
        ">>$OUTSIDE/f echo x",
        "exec > $OUTSIDE/f",
        "exec 2>$OUTSIDE/log",
        "(echo x) > $OUTSIDE/f",
        "FOO=1 > $OUTSIDE/f",
    ) {
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-19b (review M1/redteam M2, MUST): '$cmd' -> deny (prefix/command-less redirect)")
            or diag("cmd: $cmd");
    }
}

# 19c (redteam M3, MUST): a quoted or escaped command name must not hide the
# command from the trigger.
{
    my $driver_main = caller_by_name('driver-main');
    my @rm_like = ('\rm -rf .git', q{"rm" -rf .git}, 'r\m -rf .git', q{'r'm -rf .git});
    for my $cmd (@rm_like) {
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-19c (redteam M3, MUST): '$cmd' -> deny (quoted/escaped rm)")
            or diag("cmd: $cmd");
    }
    my $touch_cmd = '\touch ' . "$OUTSIDE/f";
    is(run_for($driver_main, $touch_cmd)->{rc}, 2, "AC-19c (redteam M3, MUST): '$touch_cmd' -> deny (escaped touch)")
        or diag("cmd: $touch_cmd");
    for my $cmd ('\cd x', q{"cd" x}) {
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-19c (redteam M3, MUST): '$cmd' -> deny (quoted/escaped cd)")
            or diag("cmd: $cmd");
    }
}

# 19d (redteam M4, MUST): every cp/mv/ln target-directory form.
{
    my $driver_main = caller_by_name('driver-main');
    for my $cmd (
        "cp --target-directory $OUTSIDE a",
        "cp -t$OUTSIDE a",
        "cp -rt $OUTSIDE a",
        "cp --target-directory=$OUTSIDE a",
    ) {
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-19d (redteam M4, MUST): '$cmd' -> deny (cp target-directory forms)")
            or diag("cmd: $cmd");
    }
    # mv's target-directory forms must not let the real source (.git, a
    # protected root) escape (c) by being mis-parsed as the destination.
    for my $cmd (
        "mv --target-directory $TMPFIX/x .git",
        "mv -t$TMPFIX/x .git",
        "mv -ft$TMPFIX/x .git",
    ) {
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-19d (redteam M4, MUST): '$cmd' -> deny (mv target-directory forms, .git as real source)")
            or diag("cmd: $cmd");
    }
}

# 19e (redteam M5, MUST): code glued to -e must not hide the file operand of
# perl -pi / sed -i.
{
    my $driver_main = caller_by_name('driver-main');
    for my $cmd (
        qq{perl -pi -e's/a/b/' $OUTSIDE/f},
        qq{perl -I lib -pi -e 's/a/b/' $OUTSIDE/f},
        qq{sed -i -e's/a/b/' $OUTSIDE/f},
        "sed -i -es/a/b/ $OUTSIDE/f",
    ) {
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-19e (redteam M5, MUST): '$cmd' -> deny (glued -e)")
            or diag("cmd: $cmd");
    }
}

# 19f (review M2 / redteam N4, MUST): a quoted $HOME/$USERPROFILE alias
# followed directly by a slash must still be recognised as the home alias.
{
    my $driver_main = caller_by_name('driver-main');
    for my $cmd (q{rm -rf "$HOME"/}, q{rm -rf "${USERPROFILE}"/x/..}) {
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-19f (review M2/redteam N4, MUST): '$cmd' -> deny (quoted home alias + slash)")
            or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-20 -- MUST bullet 7 (review M3 / redteam S9): ino==0 must skip the
# stat-identity fallback entirely (spec 2.6 step 2 says "ino == 0", not
# "dev == 0 && ino == 0" -- the current code's "unless $rdev || $rino"
# already handles the both-zero case correctly, so this must reproduce the
# real bug shape: native MSWin32's stat(), where dev is the nonzero drive
# number and ino is 0). This host's hook perl reports stable non-zero
# inodes (proven by the risk check above), so the bug is not otherwise
# observable here; it is forced by overriding CORE::GLOBAL::stat to always
# report (dev=1, ino=0) and recompiling GuardBash.pm under it.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    is(run_for($driver_main, "touch $REPO/f")->{rc}, 0, 'AC-20 baseline: touch inside repo -> allow (real stat)');

    my $modfile = 'BpHook/Guards/GuardBash.pm';
    {
        local *CORE::GLOBAL::stat = sub { return (1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) };
        delete $INC{$modfile};
        my $ok = eval { require $modfile; 1 };
        ok($ok, 'AC-20 setup: GuardBash.pm recompiles under a forced (dev=1, ino=0) stat()') or diag($@);

        if ($ok) {
            my $res_b = run_for($driver_main, "touch $OUTSIDE/f");
            is($res_b->{rc}, 2, 'AC-20 (review M3/redteam S9, MUST): ino==0 -> (b) still denies an outside write (identity fallback must be skipped, not falsely matched)');
            my $res_c = run_for($driver_main, "rm -rf $REPO/sub/x");
            is($res_c->{rc}, 0, 'AC-20 (review M3/redteam S9, MUST): ino==0 -> (c) must not falsely deny an ordinary existing file');
        }
        else {
            fail('AC-20: ino==0 -> (b) still denies an outside write') ;
            fail('AC-20: ino==0 -> (c) must not falsely deny an ordinary existing file');
        }
    }
    # restore the real GuardBash.pm for every test after this block.
    delete $INC{$modfile};
    my $restored = eval { require $modfile; 1 };
    ok($restored, 'AC-20 teardown: GuardBash.pm recompiles under the real stat() again') or diag($@);
}

# ===========================================================================
# AC-21 -- ALSO MUST (redteam S1): the prefilter regex must not be quadratic.
# A 64 KB run of '{' on line 1 must not come close to the hook's 15s timeout;
# bound it well under that at 2s, using the in-process call (run_for/
# GuardHarness::run_module) so spawn cost never dominates the measurement.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my $braces = '{' x 65536; # 64 KiB run, the report's own repro size
    my $cmd = ": '$braces'\ntouch $OUTSIDE/f";
    my $t0 = Time::HiRes::time();
    my $res = run_for($driver_main, $cmd);
    my $elapsed = Time::HiRes::time() - $t0;
    cmp_ok($elapsed, '<', 2, 'AC-21 (redteam S1, ALSO MUST): 64 KiB brace-run command completes in under 2s in-process (was 17.9s)');
    is($res->{rc}, 2, 'AC-21: ...and the deny on line 2 (touch outside) still fires once the prefilter is linear');
}

# ===========================================================================
# AC-22 -- SUPERSEDED by Decision 22's M3 ruling (reports/01-redteam-2.md),
# which replaces Decision 19's cap-abstain clause: "GB-h never abstains
# because of BP_GUARD_MAX_STRIP_BYTES and AC-21 stands". The previous
# expectation here (an explicitly-set cap makes GB-h abstain/allow) is now
# the WRONG verdict -- a padded `rm -rf .git` past an explicit
# BP_GUARD_MAX_STRIP_BYTES must still be DENIED. This is the one existing
# assertion pair this fix-batch changes, per that ruling.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my $cmd = 'rm -rf .git # ' . ('x' x 400); # well over a small cap
    my $res_capped = run_for($driver_main, $cmd, env => { BP_GUARD_MAX_STRIP_BYTES => 50 });
    is($res_capped->{rc}, 2, 'AC-22 (Decision 22 M3 ruling, supersedes reviewer S1/Decision 19): an explicit BP_GUARD_MAX_STRIP_BYTES no longer makes GB-h abstain -- still denies')
        or diag("cmd length: " . length($cmd));
    my $res_uncapped = run_for($driver_main, $cmd, env => { BP_GUARD_MAX_STRIP_BYTES => 100000 });
    is($res_uncapped->{rc}, 2, 'AC-22: same command, cap raised above its length -> still denies (consistent regardless of the cap)');
}

# ===========================================================================
# AC-23 -- SHOULD (redteam S3): unwrap common prefixes before reading the
# command name; on Windows-family perls, match names case-insensitively.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    for my $cmd (
        'env -u X rm -rf .git',
        'command -p rm -rf .git',
        'time -p rm -rf .git',
        'nice -5 rm -rf .git',
        "nice --adjustment=5 touch $OUTSIDE/f",
        "stdbuf -o0 touch $OUTSIDE/f",
        'sudo rm -rf .git',
    ) {
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-23 (redteam S3, SHOULD): '$cmd' -> deny (wrapper prefix unwrapped)")
            or diag("cmd: $cmd");
    }
    SKIP: {
        skip('AC-23 case-insensitive names: not a Windows-family perl', 2) unless $IS_WINFAM;
        is(run_for($driver_main, 'RM -rf .git')->{rc}, 2, 'AC-23 (redteam S3, SHOULD): RM -rf .git -> deny (case-insensitive on Windows-family)');
        is(run_for($driver_main, "TOUCH $OUTSIDE/f")->{rc}, 2, 'AC-23 (redteam S3, SHOULD): TOUCH outside -> deny (case-insensitive on Windows-family)');
    }
}

# ===========================================================================
# AC-24 -- SHOULD (redteam S4/S5): >|, >&FILE, <> and {fd}> redirect forms.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    for my $cmd (
        "echo x >| $OUTSIDE/f",
        "echo x >& $OUTSIDE/f",
        "echo x >&$OUTSIDE/f",
        "exec 3<>$OUTSIDE/f",
        "{fd}>$OUTSIDE/f",
    ) {
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-24 (redteam S4/S5, SHOULD): '$cmd' -> deny (redirect form)")
            or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-25 -- SHOULD (reviewer S2/S4): the B-3 message keeps the target path's
# tail -- including the protected component -- instead of truncating it
# away; this also makes AC-3's length bound falsifiable (reviewer S4).
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my $deep = "$REPO/plugins/butler/tests/t/some/deeply/nested/fixture/dir/.git";
    make_path(dirname($deep));
    my $cmd = "rm -rf $deep";
    my $res = run_for($driver_main, $cmd);
    is($res->{rc}, 2, 'AC-25 setup: rm -rf of a deeply nested .git -> deny') or diag("cmd: $cmd");
    my @lines = split /\n/, $res->{err};
    like($lines[0] // '', qr/\.git$/, 'AC-25 (reviewer S2/S4, SHOULD): B-3 line 1 keeps the tail, ending in the protected component, not truncated with "..."');
    unlike($lines[0] // '', qr/\.\.\.\z/, 'AC-25: B-3 line 1 does not end in a bare "..." (the length bound is not tautological)');
}

# ===========================================================================
# AC-26 -- SHOULD (redteam N10): the same-volume rule must not fire across
# volumes. Soft-skips when this host has no second drive letter to probe.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my ($repo_drive) = ($REPO =~ m{^([A-Za-z]):});
    if ($IS_WINFAM && defined $repo_drive) {
        $repo_drive = uc($repo_drive);
        my $other;
        for my $L ('C' .. 'Z') {
            next if $L eq $repo_drive;
            if (-d "$L:/") { $other = $L; last }
        }
        if (defined $other) {
            is(run_for($driver_main, "rm -rf $other:/")->{rc}, 0,
               "AC-26 (redteam N10, SHOULD): rm -rf $other:/ (a different volume from the repo) -> allow, not matched by the same-volume rule");
        }
        else {
            pass('AC-26: skipped, no second drive letter found on this host');
        }
    }
    else {
        pass('AC-26: skipped, not a Windows-family perl or no repo drive letter to compare against');
    }
}

# ===========================================================================
# AC-27 -- Decision 19 RULING (4(c) vs 4(d)): a literal protected-root
# prefix with a pure-glob remainder is still denied; the text check wins
# over the unresolvable-target allowance.
# ===========================================================================
{
    for my $name (qw(subagent driver-main)) {
        my $caller = caller_by_name($name);
        for my $cmd ('rm -rf .git/*', 'rm -rf .ccpraxis-local-data/*', q{rm -rf "$X/.git/"}) {
            is(run_for($caller, $cmd)->{rc}, 2, "AC-27 (Decision 19 ruling): $name '$cmd' -> deny (literal protected-root prefix wins over 4(d))")
                or diag("cmd: $cmd");
        }
    }
}

# ===========================================================================
# AC-28 -- Decision 19 FALSE DENIALS to fix: > /dev/tty, and
# touch/truncate --reference FILE (the reference is a read source, not a
# write target).
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    is(run_for($driver_main, 'echo x > /dev/tty')->{rc}, 0,
       'AC-28 (Decision 19 false denial): echo x > /dev/tty -> allow (never a target)');
    is(run_for($driver_main, "touch --reference $OUTSIDE/ref $REPO/f")->{rc}, 0,
       'AC-28 (Decision 19 false denial): touch --reference OUTSIDE-file REPO-file -> allow (the reference is a read source)');
    is(run_for($driver_main, "truncate --reference $OUTSIDE/ref $REPO/f")->{rc}, 0,
       'AC-28 (Decision 19 false denial): truncate --reference OUTSIDE-file REPO-file -> allow (the reference is a read source)');
}

# ===========================================================================
# Decision 22 (reports/01-redteam-2.md) fix-batch 2 regression batch.
# WRITTEN FROM THE REPORT'S OWN PROBE PAYLOADS, not from reading the
# implementation. Everything below is expected RED until the implementer's
# Decision-22 fix batch lands, except where marked as a paired control.
# ===========================================================================

# ===========================================================================
# AC-29 -- M1 (MUST): a redirect glued to the COMMAND-NAME word (no space
# between the name and the operator) must still be recognised.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    for my $row (
        ["cat>$OUTSIDE/f <<'EOF'" => "cat>$OUTSIDE/f <<'EOF'\nhi\nEOF"],
        ["echo>$OUTSIDE/f hi"     => "echo>$OUTSIDE/f hi"],
        ["exec>$OUTSIDE/f"        => "exec>$OUTSIDE/f"],
        ["tee>$OUTSIDE/f"         => "tee>$OUTSIDE/f"],
    ) {
        my ($label, $cmd) = @$row;
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-29 (redteam-2 M1, MUST): '$label' -> deny (redirect glued to command name)")
            or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-30 -- M2 (MUST): home-alias globs must reach the glob-prefix check, in
# default mode AND under bypassPermissions (Decision 18 Q1: (c) stays active
# everywhere).
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my @cmds = ('rm -rf ~/*', 'rm -rf ~/.*', q{rm -rf "$HOME"/*}, 'rm -rf $HOME/*', 'rm -rf ${HOME}/*');
    for my $cmd (@cmds) {
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-30 (redteam-2 M2, MUST): '$cmd' -> deny (default mode)")
            or diag("cmd: $cmd");
        is(run_for($driver_main, $cmd, permission_mode => 'bypassPermissions')->{rc}, 2,
           "AC-30 (redteam-2 M2, MUST): '$cmd' -> deny under bypassPermissions ((c) stays active)")
            or diag("cmd: $cmd");
    }
    # control: the equivalent literal HOME path with a pure glob remainder
    # must keep denying too (already pinned by AC-27; repeated here as the
    # sibling of the alias forms above).
    is(run_for($driver_main, "rm -rf $HOMEFIX/*")->{rc}, 2,
       'AC-30 control: rm -rf <H>/* (literal HOME path) -> deny');
}

# ===========================================================================
# AC-31 -- M3 (RULING): a Bash command over 256 KiB is denied by GB-h with a
# remedy telling the worker to write it to a script file, and this holds
# regardless of BP_GUARD_MAX_STRIP_BYTES (which no longer causes an
# abstain -- see the updated AC-22 above).
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my $CAP = 256 * 1024;
    my $over_cap_cmd = 'rm -rf .git # ' . ('x' x ($CAP + 4096));
    ok(length($over_cap_cmd) > $CAP, 'AC-31 fixture sanity: the constructed command exceeds 256 KiB');
    my $res = run_for($driver_main, $over_cap_cmd);
    is($res->{rc}, 2, 'AC-31 (redteam-2 M3 RULING): a >256 KiB command is DENIED, not parsed-and-allowed')
        or diag('cmd length: ' . length($over_cap_cmd));
    like($res->{err}, qr/script file/i,
         'AC-31: the >256 KiB denial names the remedy (write it to a script file)')
        or diag("stderr: $res->{err}");

    # BP_GUARD_MAX_STRIP_BYTES set explicitly, well under the command's own
    # length, must NOT turn this into an abstain (Decision 22 supersedes
    # Decision 19's cap-abstain clause).
    my $res_env = run_for($driver_main, $over_cap_cmd, env => { BP_GUARD_MAX_STRIP_BYTES => 100 });
    is($res_env->{rc}, 2, 'AC-31: an explicit BP_GUARD_MAX_STRIP_BYTES does not turn the >256 KiB denial into an abstain');
}

# ===========================================================================
# AC-32 -- M3 timing: each of the report's three shapes, sized just under
# 256 KiB (so it takes the NORMAL parse-and-deny path, not the over-cap
# remedy path), must return its verdict in under 5s. Measures the in-process
# hook call alone with Time::HiRes, never subprocess/spawn cost.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my $CAP    = 256 * 1024;
    my $TARGET = $CAP - 4096; # just under the cap

    # Shape 1: a long single word before .git.
    {
        my $pad = 'a' x ($TARGET - length('rm -rf  .git'));
        my $cmd = "rm -rf $pad .git";
        ok(length($cmd) < $CAP, 'AC-32 shape 1 fixture sanity: under the 256 KiB cap');
        my $t0 = Time::HiRes::time();
        my $res = run_for($driver_main, $cmd);
        my $elapsed = Time::HiRes::time() - $t0;
        cmp_ok($elapsed, '<', 5, 'AC-32 (redteam-2 M3 timing): shape 1 (long single word before .git) completes under 5s')
            or diag("elapsed: $elapsed s, cmd length: " . length($cmd));
        is($res->{rc}, 2, 'AC-32: shape 1 still denies (protected root .git)');
    }

    # Shape 2: many existing rm operands plus .git.
    {
        my $op = "$REPO/sub";
        my $n = int(($TARGET - 10) / (length($op) + 1));
        my $cmd = 'rm -f ' . join(' ', ($op) x $n) . ' .git';
        ok(length($cmd) < $CAP, 'AC-32 shape 2 fixture sanity: under the 256 KiB cap');
        my $t0 = Time::HiRes::time();
        my $res = run_for($driver_main, $cmd);
        my $elapsed = Time::HiRes::time() - $t0;
        cmp_ok($elapsed, '<', 5, 'AC-32 (redteam-2 M3 timing): shape 2 (many existing rm operands plus .git) completes under 5s')
            or diag("elapsed: $elapsed s, cmd length: " . length($cmd) . ", operand count: $n");
        is($res->{rc}, 2, 'AC-32: shape 2 still denies (protected root .git)');
    }

    # Shape 3: touch with many deep TMP paths plus an outside target.
    {
        my $deep = join('/', ('d') x 30);
        my $op = "$TMPFIX/$deep";
        my $n = int(($TARGET - length("$OUTSIDE/f") - 10) / (length($op) + 1));
        my $cmd = 'touch ' . join(' ', ($op) x $n) . " $OUTSIDE/f";
        ok(length($cmd) < $CAP, 'AC-32 shape 3 fixture sanity: under the 256 KiB cap');
        my $t0 = Time::HiRes::time();
        my $res = run_for($driver_main, $cmd);
        my $elapsed = Time::HiRes::time() - $t0;
        cmp_ok($elapsed, '<', 5, 'AC-32 (redteam-2 M3 timing): shape 3 (touch, many deep TMP paths, plus an outside target) completes under 5s')
            or diag("elapsed: $elapsed s, cmd length: " . length($cmd) . ", operand count: $n");
        is($res->{rc}, 2, 'AC-32: shape 3 still denies (outside-sandbox write)');
    }
}

# ===========================================================================
# AC-33 -- S1 (SHOULD): two redirects in one word, and a redirect glued to an
# assignment, must not be lost -- bash ends a word at the FIRST '>'.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    for my $cmd (
        "echo x>a>$OUTSIDE/f",
        "echo x >a>$OUTSIDE/f",
        ">a>$OUTSIDE/f echo",
        "echo x 2>&1>$OUTSIDE/f",
        "FOO=1>$OUTSIDE/f echo hi",
        "FOO=1>$OUTSIDE/f",
        "env X=1>$OUTSIDE/f touch a",
    ) {
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-33 (redteam-2 S1, SHOULD): '$cmd' -> deny (redirect after the first '>')")
            or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-34 -- S2 (SHOULD): mv/cp --target=DIR / --target DIR / --t=DIR (GNU
# unambiguous-prefix) forms must not let the real operand escape (b)/(c).
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    for my $cmd (
        "mv --target=$TMPFIX/x .git",
        "mv --target $TMPFIX/x .git",
    ) {
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-34 (redteam-2 S2, SHOULD): '$cmd' -> deny (mv --target forms, .git as real source)")
            or diag("cmd: $cmd");
    }
    is(run_for($driver_main, "mv --t=$TMPFIX/x .git", permission_mode => 'bypassPermissions')->{rc}, 2,
       'AC-34 (redteam-2 S2, SHOULD): mv --t=DIR .git under bypassPermissions -> deny (c stays active)')
        or diag('cmd: mv --t=... .git');
    for my $cmd ("cp --target=$OUTSIDE a", "cp --target $OUTSIDE a") {
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-34 (redteam-2 S2, SHOULD): '$cmd' -> deny (cp --target forms, dest outside)")
            or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-35 -- S3 (SHOULD, false denials): rm -f of an ordinary partial glob in
# the repo root/home/an ancestor must ALLOW; only a pure match-all glob, or a
# .git/.ccpraxis-local-data prefix, still denies.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my $OTHERDIR = "$B/other-fixture-longname";
    make_path($OTHERDIR);

    is(run_for($driver_main, 'rm -f ./*.tmp')->{rc}, 0,
       'AC-35 (redteam-2 S3, SHOULD): rm -f ./*.tmp (cwd repo) -> allow (partial glob, not pure match-all)');
    is(run_for($driver_main, "rm -f $REPO/*.tmp")->{rc}, 0,
       'AC-35 (redteam-2 S3, SHOULD): rm -f <R>/*.tmp -> allow (partial glob)');
    is(run_for($driver_main, 'rm -f ../repo/*.tmp', cwd => $OTHERDIR)->{rc}, 0,
       'AC-35 (redteam-2 S3, SHOULD): rm -f ../repo/*.tmp -> allow (partial glob, relative)');
    is(run_for($driver_main, "rm -f $HOMEFIX/*.log")->{rc}, 0,
       'AC-35 (redteam-2 S3, SHOULD): rm -f <H>/*.log -> allow (partial glob)');

    # controls: these still deny -- .git/.ccpraxis-local-data keep denying any
    # glob, and R/HOME with a PURE match-all glob remainder still deny.
    for my $cmd ('rm -rf .git/*', 'rm -rf .ccpraxis-local-data/*', "rm -rf $REPO/*", 'rm -rf ~/*') {
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-35 control: '$cmd' -> still deny (protected prefix or pure match-all glob)")
            or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-36 -- S4 (SHOULD): wrapper unwrap must handle sudo -u, nice -nN, stdbuf
# with a spaced option value, and case-insensitive command names on
# Windows-family perls.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    for my $cmd ('sudo -u root rm -rf .git', 'nice -n5 rm -rf .git', "stdbuf -o 0 touch $OUTSIDE/f") {
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-36 (redteam-2 S4, SHOULD): '$cmd' -> deny (wrapper unwrapped)")
            or diag("cmd: $cmd");
    }
    SKIP: {
        skip('AC-36 uppercase wrapper names: not a Windows-family perl', 3) unless $IS_WINFAM;
        is(run_for($driver_main, 'ENV rm -rf .git')->{rc}, 2, 'AC-36 (redteam-2 S4, SHOULD): ENV rm -rf .git -> deny (case-insensitive wrapper)');
        is(run_for($driver_main, 'NICE rm -rf .git')->{rc}, 2, 'AC-36 (redteam-2 S4, SHOULD): NICE rm -rf .git -> deny (case-insensitive wrapper)');
        is(run_for($driver_main, 'TIMEOUT 5 rm -rf .git')->{rc}, 2, 'AC-36 (redteam-2 S4, SHOULD): TIMEOUT 5 rm -rf .git -> deny (case-insensitive wrapper)');
    }
}

# ===========================================================================
# AC-37 -- S5 (SHOULD): a quoted backslash Windows path to the rm binary must
# still be recognised as an rm invocation (Windows-family only -- the
# backslash-preserving relaxed-fallback path is a Windows-only concern).
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    SKIP: {
        skip('AC-37: not a Windows-family perl', 2) unless $IS_WINFAM;
        is(run_for($driver_main, q{'C:\Program Files\Git\usr\bin\rm.exe' -rf .git})->{rc}, 2,
           'AC-37 (redteam-2 S5, SHOULD): single-quoted backslash path to rm.exe -rf .git -> deny');
        is(run_for($driver_main, q{"C:\Git\usr\bin\rm.exe" -rf .git})->{rc}, 2,
           'AC-37 (redteam-2 S5, SHOULD): double-quoted backslash path to rm.exe -rf .git -> deny');
    }
}

# ===========================================================================
# AC-38 -- S6 (RULING, in scope with M4): "$( ... )" and a backtick INSIDE
# double quotes are parsed as commands by every guard, same as unquoted.
# guard-prose-not-invocation.t (unedited) must stay green alongside this.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    is(run_for($driver_main, qq{X="\$(cd $OUTSIDE && ls)"})->{rc}, 2,
       'AC-38 (redteam-2 S6 RULING): X="$(cd <O> && ls)" -> deny, same as the unquoted form');
    is(run_for($driver_main, q{echo "$(rm -rf .git)"})->{rc}, 2,
       'AC-38 (redteam-2 S6 RULING): echo "$(rm -rf .git)" -> deny (protected root inside a quoted command substitution)');
    is(run_for($driver_main, qq{echo "\x60cd $OUTSIDE\x60"})->{rc}, 2,
       'AC-38 (redteam-2 S6 RULING): backtick command substitution inside double quotes -> deny (cd)');
    is(run_for($driver_main, qq{echo "\$(echo x>$OUTSIDE/f)"})->{rc}, 2,
       'AC-38 (redteam-2 S6 RULING): echo "$(echo x><O>/f)" -> deny (write outside the sandbox inside a quoted command substitution)');
}

# ===========================================================================
# AC-39 -- S7 (the heredoc mask is per-line, so a quote opened on an EARLIER
# line is invisible to it): an apparent "<<EOF" that is actually still
# inside a quote opened on a previous line is NOT a real heredoc, so a real
# command on a later line (rm -rf .git) must still be recognised and denied.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    for my $cmd (
        qq{echo 'abc\n<<EOF'\nrm -rf .git},
        qq{echo "a\n<<EOF"\nrm -rf .git},
    ) {
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-39 (redteam-2 S7, SHOULD): quote opened on an earlier line swallows the apparent heredoc -> 'rm -rf .git' on the next line still denies")
            or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-40 -- S8 (SHOULD): mv .git{,.bak} (the standard backup idiom, an
# unquoted brace list) must classify .git as a real move SOURCE too, not
# only as the destination.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    is(run_for($driver_main, 'mv .git{,.bak}')->{rc}, 2,
       'AC-40 (redteam-2 S8, SHOULD): mv .git{,.bak} -> deny (.git is a move source via the brace list)');
}

# ===========================================================================
# AC-41 -- M4 (MUST, BpHook.pm): the whole-text heredoc/quote mask must
# treat "$(...)"/backtick inside double quotes as opening a fresh, unquoted
# frame (S6's frame stack), so a heredoc INSIDE that substitution is
# recognised and its body is stripped again, exactly as HEAD (pre-batch-1)
# behaved for these canonical commit/PR-body shapes. Rows quoted directly
# from reports/01-redteam-2.md's M4 table.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');

    # Row 1: an odd quote INSIDE the heredoc body must not desync the whole
    # command into treating "cd x" as a real, later command.
    my $row1 = qq{git commit -m "\$(cat <<'EOF'\nHe said "hi\ncd x\nEOF\n)"};
    is(run_for($driver_main, $row1)->{rc}, 0,
       'AC-41 (redteam-2 M4, MUST): commit -m with an odd-quote heredoc body containing "cd x" -> allow (body not parsed as commands)')
        or diag("cmd: $row1");

    # Row 2: same shape, body contains an apparent outside-write redirect.
    my $row2 = qq{git commit -m "\$(cat <<'EOF'\nUse "--flag\n> $OUTSIDE/x\nEOF\n)"};
    is(run_for($driver_main, $row2)->{rc}, 0,
       'AC-41 (redteam-2 M4, MUST): commit -m with an odd-quote heredoc body containing "> <O>/x" -> allow (body not parsed as commands)')
        or diag("cmd: $row2");

    # Row 3: a quote opened on the line BEFORE the heredoc operator.
    my $row3 = qq{echo 'a\nb' && cat <<EOF\ncd x\nEOF};
    is(run_for($driver_main, $row3)->{rc}, 0,
       "AC-41 (redteam-2 M4, MUST): a single quote opened on the line before '<<EOF' -> allow (heredoc still recognised, body stripped)")
        or diag("cmd: $row3");

    # Row 4: same, double-quoted, with a real (in-sandbox) redirect on the
    # heredoc-starting line itself.
    my $row4 = qq{echo "x\ny" ; cat <<'EOF' > f\ncd x\nEOF};
    is(run_for($driver_main, $row4)->{rc}, 0,
       "AC-41 (redteam-2 M4, MUST): a double quote opened on the line before, heredoc target inside the repo -> allow")
        or diag("cmd: $row4");
}

# ===========================================================================
# AC-42 -- M4 (MUST, BpHook.pm) blast-radius check: BpHook::_segments() and
# BpHook::invocations() must not yield a heredoc body line as its own
# segment/invocation once the whole-text mask is fixed. Calls BpHook's own
# subs directly (BpHook.pm is transitively loaded by
# `require BpHook::Guards::GuardBash` above) -- this is deliberately NOT
# routed through GuardBash, because the report's blast-radius finding is
# that _segments/invocations are shared by every guard, not GB-h-specific.
# ===========================================================================
{
    my $cmd = qq{git commit -m "\$(cat <<'EOF'\nHe said "hi\ngit push --force origin main\nEOF\n)"};
    my @segs = BpHook::_segments($cmd);
    ok(!(grep { /git push --force origin main/ } @segs),
       'AC-42 (redteam-2 M4, MUST): _segments() never yields the heredoc body line as its own segment')
        or diag('segments: ' . join(' | ', map { "[$_]" } @segs));

    my @invs = BpHook::invocations($cmd, 'git');
    is(scalar(@invs), 1,
       'AC-42 (redteam-2 M4, MUST): invocations($cmd, "git") finds only the outer commit, not the body "git push" line')
        or diag('invocation count: ' . scalar(@invs));
}

# ===========================================================================
# Fix-batch 3 (Decision 23, reports/01-redteam-3.md). AC-43 onward.
#
# SEAM ASSUMED, NOT YET IN THE IMPLEMENTATION (report M2's "add a wall-clock
# deadline to GB-h"): this file assumes the implementer exposes the deadline
# as the environment variable BP_GUARD_DEADLINE_SECONDS, read the same way
# BP_GUARD_MAX_STRIP_BYTES already is (an explicit env override of GB-h's
# ~5s default, consumed once per _gb_h call). AC-49 below pins that seam by
# name. If the implementer instead adds a package variable
# ($BpHook::Guards::GuardBash::DEADLINE_SECONDS or similar), AC-49 is the one
# test in this file that needs to change to match, and nothing else here
# depends on the seam's shape.
# ===========================================================================

# ===========================================================================
# AC-43 -- M1 (MUST): chaining a commit and a PR in one call, with an
# apostrophe inside the FIRST heredoc body, is ordinary and must ALLOW in
# both default mode and under bypassPermissions (Decision 18 Q1 only lifts
# (a)/(b) under bypass; this row has no cd/outside-write, so both modes
# behave the same). Row quoted from reports/01-redteam-3.md's M1 table row 1.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my $row1 = q{git commit -m "$(cat <<'EOF'
first: it's here
EOF
)" && gh pr create --title t --body "$(cat <<'EOF'
- Run `cd plugins && make`
- `rm -rf .git` never
EOF
)"};
    is(run_for($driver_main, $row1)->{rc}, 0,
       'AC-43 (redteam-3 M1, MUST): commit-then-PR with an apostrophe in the first heredoc body -> allow (default mode)')
        or diag("cmd: $row1");
    is(run_for($driver_main, $row1, permission_mode => 'bypassPermissions')->{rc}, 0,
       'AC-43 (redteam-3 M1, MUST): same command -> allow under bypassPermissions too')
        or diag("cmd: $row1");
}

# ===========================================================================
# AC-44 -- M1 (MUST): the two-heredoc form and the comment-led form must
# ALLOW. Rows quoted from reports/01-redteam-3.md's M1 table rows 4 and 6.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my $two_heredoc = qq{cat > $TMPFIX/a <<'EOF'
don't
EOF
cat > $TMPFIX/b <<'EOF'
cd x
EOF};
    is(run_for($driver_main, $two_heredoc)->{rc}, 0,
       'AC-44 (redteam-3 M1, MUST): two heredocs, an apostrophe in the first body, "cd x" only in the second body -> allow')
        or diag("cmd: $two_heredoc");

    my $comment_led = q{# don't
cat <<EOF
cd x
EOF};
    is(run_for($driver_main, $comment_led)->{rc}, 0,
       'AC-44 (redteam-3 M1, MUST): a comment with an apostrophe before a real heredoc whose body says "cd x" -> allow')
        or diag("cmd: $comment_led");
}

# ===========================================================================
# AC-45 -- M1 (MUST) blast-radius: a heredoc body that MENTIONS
# "bp-drive-next.pl next" must not make BpHook::ArmOnEntry::director_next_call
# report a real director call (the ArmOnEntry over-arming finding). Calls
# ArmOnEntry's own sub directly, the same way AC-42 calls _segments/
# invocations directly -- this is deliberately not GB-h-specific.
# ===========================================================================
{
    my $row_a = q{git commit -m "$(cat <<'EOF'
Don't re-arm twice
EOF
)" && gh pr create --title t --body "$(cat <<'EOF'
Run `bp-drive-next.pl next` to resume.
EOF
)"};
    is(BpHook::ArmOnEntry::director_next_call($row_a), 0,
       'AC-45 (redteam-3 M1, MUST): a heredoc body mentioning "bp-drive-next.pl next" inside a commit+PR call -> director_next_call is 0')
        or diag("cmd: $row_a");

    my $row_b = q{# Let's file it
cat > /tmp/n.md <<'EOF'
bp-drive-next.pl next
EOF};
    is(BpHook::ArmOnEntry::director_next_call($row_b), 0,
       'AC-45 (redteam-3 M1, MUST): a comment-led heredoc body mentioning "bp-drive-next.pl next" -> director_next_call is 0')
        or diag("cmd: $row_b");

    # non-vacuous control: a REAL, unquoted director call is still detected.
    is(BpHook::ArmOnEntry::director_next_call('bp-drive-next.pl next'), 1,
       'AC-45 control: a real, bare "bp-drive-next.pl next" call still reports director_next_call == 1 (not vacuous)');
}

# ===========================================================================
# AC-46 -- M1 (MUST) bypass: an odd quote inside a REAL heredoc's body must
# not let a later real command hide inside what the mask (mis)treats as
# still-quoted text. Row quoted from reports/01-redteam-3.md's M1 table,
# first "bypass:" row -- Decision 23 requires this one to flip from the
# report's ALLOW to DENY.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my $bypass = q{cat <<'EOF'
it's
EOF
echo '<<X'
rm -rf .git};
    is(run_for($driver_main, $bypass)->{rc}, 2,
       'AC-46 (redteam-3 M1, MUST): the cat-it\'s-EOF-then-rm bypass is DENIED, not allowed')
        or diag("cmd: $bypass");
}

# ===========================================================================
# AC-47 -- M1 (MUST): BpHook::_segments() must never yield a heredoc-body
# line or a comment line as its own segment. Calls _segments() directly
# (BpHook.pm is transitively loaded), the same style as AC-42.
# ===========================================================================
{
    my $cmd = q{# don't leak MARKERCOMMENT
cat <<'EOF'
MARKERBODY
EOF
echo ok};
    my @segs = BpHook::_segments($cmd);
    ok(!(grep { /MARKERCOMMENT/ } @segs),
       'AC-47 (redteam-3 M1, MUST): _segments() never yields a comment line as its own segment')
        or diag('segments: ' . join(' | ', map { "[$_]" } @segs));
    ok(!(grep { /MARKERBODY/ } @segs),
       'AC-47 (redteam-3 M1, MUST): _segments() never yields a heredoc-body line as its own segment')
        or diag('segments: ' . join(' | ', map { "[$_]" } @segs));
}

# ===========================================================================
# AC-48 -- M2 (MUST): cost is bounded even with non-ASCII text and with many
# real operands. Each of the report's four shapes must return a verdict in
# under 6s (5s deadline + margin), measured alone with Time::HiRes, never
# subprocess/spawn cost. Sizes and shapes are quoted from reports/
# 01-redteam-3.md's M2 tables.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my $CAP = 256 * 1024;

    # Shape 1: a 128k-character heredoc body with exactly one non-ASCII
    # character (report M2(a) row 2: 128645 chars measured 30.6s pre-fix).
    {
        my $filler = 'x' x 128000;
        my $body = "\x{2014}" . $filler; # one em dash, then ASCII filler
        my $cmd = "cat > $REPO/doc.md <<'EOF'\n$body\nEOF";
        ok(length($cmd) > 100000, 'AC-48 shape 1 fixture sanity: over 100k characters');
        my $t0 = Time::HiRes::time();
        my $res = run_for($driver_main, $cmd);
        my $elapsed = Time::HiRes::time() - $t0;
        cmp_ok($elapsed, '<', 6, 'AC-48 (redteam-3 M2, MUST): 128k-char heredoc with one non-ASCII char completes under 6s')
            or diag("elapsed: $elapsed s, cmd length: " . length($cmd));
        is($res->{rc}, 0, 'AC-48: shape 1 still allows (write inside the repo)');
    }

    # Shape 2: the non-ASCII 256 KiB end-to-end payload (report M2(a)/(b):
    # "rm -r -f .git # <262 128 x é>", timed out at 60s end-to-end pre-fix).
    {
        my $target = $CAP - 4096;
        my $prefix = 'rm -rf .git # ';
        my $pad = "\x{e9}" x ($target - length($prefix));
        my $cmd = $prefix . $pad;
        ok(length($cmd) < $CAP, 'AC-48 shape 2 fixture sanity: under the 256 KiB cap');
        my $t0 = Time::HiRes::time();
        my $res = run_for($driver_main, $cmd);
        my $elapsed = Time::HiRes::time() - $t0;
        cmp_ok($elapsed, '<', 6, 'AC-48 (redteam-3 M2, MUST): non-ASCII ~256 KiB payload (rm -rf .git # <é...>) completes under 6s')
            or diag("elapsed: $elapsed s, cmd length: " . length($cmd));
        is($res->{rc}, 2, 'AC-48: shape 2 still denies (protected root .git)');
    }

    # Shape 3: rm -f ~/x ~/x ... ~/* at about 256 KiB (report M2(b) row).
    {
        my $target = $CAP - 4096;
        my $op = '~/x';
        my $n = int(($target - length('rm -f  ~/*')) / (length($op) + 1));
        my $cmd = 'rm -f ' . join(' ', ($op) x $n) . ' ~/*';
        ok(length($cmd) < $CAP, 'AC-48 shape 3 fixture sanity: under the 256 KiB cap');
        my $t0 = Time::HiRes::time();
        my $res = run_for($driver_main, $cmd);
        my $elapsed = Time::HiRes::time() - $t0;
        cmp_ok($elapsed, '<', 6, 'AC-48 (redteam-3 M2, MUST): rm -f ~/x ... ~/* at ~256 KiB completes under 6s')
            or diag("elapsed: $elapsed s, cmd length: " . length($cmd) . ", operand count: $n");
        is($res->{rc}, 2, 'AC-48: shape 3 still denies (home-alias match-all glob)');
    }

    # Shape 4: touch with long-form TMP paths (report M2(b) row: 400
    # long-form temp-dir operands).
    {
        my $long_dir = "$TMPFIX/claude/x";
        make_path($long_dir);
        my $cmd = 'touch ' . join(' ', map { "$long_dir/f$_" } (1 .. 400));
        my $t0 = Time::HiRes::time();
        my $res = run_for($driver_main, $cmd);
        my $elapsed = Time::HiRes::time() - $t0;
        cmp_ok($elapsed, '<', 6, 'AC-48 (redteam-3 M2, MUST): touch with 400 long-form TMP-path operands completes under 6s')
            or diag("elapsed: $elapsed s, cmd length: " . length($cmd));
        is($res->{rc}, 0, 'AC-48: shape 4 still allows (all targets under TMP)');
    }
}

# ===========================================================================
# AC-49 -- M2 (MUST): the deadline itself works. With the deadline seam
# (BP_GUARD_DEADLINE_SECONDS -- see the SEAM ASSUMED note above) set to an
# artificially tiny value, an ordinary, well-under-the-256KiB-cap command
# that would normally ALLOW quickly must instead be DENIED with the existing
# over-size remedy (fail-closed on expiry, report M2 fix item 2).
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my $ordinary_cmd = 'touch ' . join(' ', map { "$REPO/f$_" } (1 .. 3000));
    ok(length($ordinary_cmd) < 256 * 1024, 'AC-49 fixture sanity: the ordinary command is well under the 256 KiB cap');

    my $res_tiny = run_for($driver_main, $ordinary_cmd, env => { BP_GUARD_DEADLINE_SECONDS => '0.0001' });
    is($res_tiny->{rc}, 2,
       'AC-49 (redteam-3 M2, MUST): an artificially tiny deadline denies an ordinary large command (fail-closed)')
        or diag("stdout: $res_tiny->{out}\nstderr: $res_tiny->{err}");
    like($res_tiny->{err}, qr/script file/i,
         'AC-49: the deadline denial names the existing over-size remedy (write it to a script file)')
        or diag("stderr: $res_tiny->{err}");

    my $res_normal = run_for($driver_main, $ordinary_cmd);
    is($res_normal->{rc}, 0,
       'AC-49 control: without an artificially tiny deadline, the same command allows (the deny above is not vacuous)');
}

# ===========================================================================
# AC-50 -- S1 (SHOULD): when BpHook's stdin read was truncated
# ($ENV{BP_PAYLOAD_TRUNCATED} = 1, simulating _read_stdin_bulk's own 8 MiB
# truncation flag), GB-h must DENY with the over-size remedy instead of
# failing open on the now-empty/garbled payload.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my $res = run_for($driver_main, 'touch f', env => { BP_PAYLOAD_TRUNCATED => '1' });
    is($res->{rc}, 2,
       'AC-50 (redteam-3 S1, SHOULD): a truncated stdin payload denies a Bash call with the over-size remedy')
        or diag("stdout: $res->{out}\nstderr: $res->{err}");
    like($res->{err}, qr/script file/i,
         'AC-50: the truncated-payload denial names the over-size remedy')
        or diag("stderr: $res->{err}");

    my $res_control = run_for($driver_main, 'touch f');
    is($res_control->{rc}, 0,
       'AC-50 control: without BP_PAYLOAD_TRUNCATED, the same command allows (the deny above is not vacuous)');
}

# ===========================================================================
# AC-51 -- S2 (SHOULD): './*/' and '[!.]*' count as pure match-all globs
# (trailing slash stripped; a bracket that negates only '.' still matches
# everything), so they are judged like a bare '*' with cwd at R -> deny.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    for my $cmd ('rm -rf ./*/', 'rm -rf [!.]*') {
        is(run_for($driver_main, $cmd)->{rc}, 2,
           "AC-51 (redteam-3 S2, SHOULD): '$cmd' with cwd at R -> deny (pure match-all glob)")
            or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-52 -- S2 (SHOULD): a bare 'rm -rf *' (empty literal prefix) is judged
# against the cwd: denied when the cwd resolves to R, a HOME root, or an
# ancestor of either; allowed when the cwd is a subdirectory of R.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    is(run_for($driver_main, 'rm -rf *')->{rc}, 2,
       'AC-52 (redteam-3 S2, SHOULD): rm -rf * with cwd == R -> deny');
    is(run_for($driver_main, 'rm -rf *', cwd => $HOMEFIX)->{rc}, 2,
       'AC-52 (redteam-3 S2, SHOULD): rm -rf * with cwd == HOME -> deny');
    is(run_for($driver_main, 'rm -rf *', cwd => $B)->{rc}, 2,
       'AC-52 (redteam-3 S2, SHOULD): rm -rf * with cwd == an ancestor of R -> deny');
    is(run_for($driver_main, 'rm -rf *', cwd => $SUBDIR)->{rc}, 0,
       'AC-52 (redteam-3 S2, SHOULD): rm -rf * with cwd == a subdirectory of R -> allow');
}

# ===========================================================================
# AC-53 -- S3 (SHOULD): a home alias combined with a brace list must classify
# like the literal home path plus the brace (mv ~ ~.bak expands to moving
# home itself).
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    is(run_for($driver_main, 'mv ~{,.bak}')->{rc}, 2,
       'AC-53 (redteam-3 S3, SHOULD): mv ~{,.bak} -> deny (brace expansion moves home)');
    is(run_for($driver_main, q{mv "$HOME"{,.bak}})->{rc}, 2,
       'AC-53 (redteam-3 S3, SHOULD): mv "$HOME"{,.bak} -> deny (quoted HOME alias plus brace list)');
}

# ===========================================================================
# AC-54 -- S4 (SHOULD): command-name and wrapper near misses. Case-
# insensitive .exe matching is a Windows-family-only concern (SKIP off
# Windows, same style as AC-36/AC-37); the env/long-option wrapper forms are
# portable.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');

    SKIP: {
        skip('AC-54 case-insensitive .exe matching: not a Windows-family perl', 3) unless $IS_WINFAM;
        is(run_for($driver_main, 'rm.EXE -rf .git')->{rc}, 2,
           'AC-54 (redteam-3 S4, SHOULD): rm.EXE -rf .git -> deny (case-insensitive .exe trigger)');
        is(run_for($driver_main, 'RM.exe -rf .git')->{rc}, 2,
           'AC-54 (redteam-3 S4, SHOULD): RM.exe -rf .git -> deny (case-insensitive command name)');
        my $win_bs_path = '"C:\\\\Git\\\\usr\\\\bin\\\\rm.exe" -rf .git';
        is(run_for($driver_main, $win_bs_path)->{rc}, 2,
           'AC-54 (redteam-3 S4, SHOULD): a quoted \\\\ (escaped backslash) Windows path to rm.exe -> deny')
            or diag("cmd: $win_bs_path");
    }

    for my $cmd ('/usr/bin/env rm -rf .git', 'sudo --user root rm -rf .git', 'command -- rm -rf .git') {
        is(run_for($driver_main, $cmd)->{rc}, 2,
           "AC-54 (redteam-3 S4, SHOULD): '$cmd' -> deny (wrapper unwrapped)")
            or diag("cmd: $cmd");
    }
    is(run_for($driver_main, "stdbuf --output=L touch $OUTSIDE/f")->{rc}, 2,
       'AC-54 (redteam-3 S4, SHOULD): stdbuf --output=L touch <O>/f -> deny (long-option wrapper form)');
}

# ===========================================================================
# AC-55 -- S5 (SHOULD): ANSI-C $'...' quoting must not desync the tokenizer.
# One bypass row (an escaped quote inside $'...' followed by a real command)
# must DENY; one ordinary $'...' use (no injection) must still ALLOW.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my $bypass = q{printf $'it\'s'; rm -rf .git};
    is(run_for($driver_main, $bypass)->{rc}, 2,
       'AC-55 (redteam-3 S5, SHOULD): printf $\'it\\\'s\'; rm -rf .git -> deny ($\'...\' quoting does not hide the real command)')
        or diag("cmd: $bypass");

    my $ordinary = q{echo $'line1\nline2'};
    is(run_for($driver_main, $ordinary)->{rc}, 0,
       'AC-55 control: an ordinary $\'...\' use with no injection still allows (not vacuous)')
        or diag("cmd: $ordinary");
}

# ===========================================================================
# Decision 25 (hook-input decode cost). BpHook::load_payload/payload()/
# payload_ok() are used directly as the seam for AC-56/AC-57/AC-58 (no named
# helper such as "BpHook::_decode_hook_json" exists as of this writing; if
# the implementer introduces one, that is an internal refactor -- the public
# load_payload/payload contract pinned here is the one Decision 25 itself
# names). AC-59/AC-60 go through run_for()/GuardHarness::run_module exactly
# like every other AC in this file, since they are GB-h (GuardBash) behaviour.
# ===========================================================================

# ---------------------------------------------------------------------------
# timed_load_payload($raw) -- BpHook::load_payload($raw), wall-clock timed
# with Time::HiRes around the decode ALONE, bounded by an 8s alarm so a
# still-slow (pre-fix) decode of a ~1 MiB non-ASCII payload cannot hang this
# file for minutes. The alarm's die is swallowed by load_payload's OWN inner
# eval (it wraps the JSON::PP decode call), so load_payload returns normally
# either way; this wrapper's own eval is defensive in case some future
# implementation lets the die propagate further.
# ---------------------------------------------------------------------------
sub timed_load_payload {
    my ($raw) = @_;
    my $t0 = Time::HiRes::time();
    local $SIG{ALRM} = sub { die "timed_load_payload: 8s bound hit\n" };
    alarm(8);
    eval { BpHook::load_payload($raw) };
    alarm(0);
    return Time::HiRes::time() - $t0;
}

# (package 09-gb-h-residuals, AC-17 / spec sec 3.15: timed_run_for had no
# caller and is deleted here, along with its own doc block above. AC-59
# observes rc/timing through real_entry_main()/with_decode_counter() below,
# never through this now-removed helper.)

# ===========================================================================
# AC-56 -- Decision 25 (1): decoder equivalence. Whatever BpHook uses to
# decode hook input must return a structure deep-equal to
# JSON::PP->new->utf8->decode($raw) for valid UTF-8 input, across the shapes
# Decision 25 names.
# ===========================================================================
{
    my @cases = (
        ['ascii only'                              => 'echo hello world 123'],
        ['2-byte character (U+00E9)'                => "caf\x{e9} note \x{e9} end"],
        ['3-byte character (U+2014)'                => "note \x{2014} dash end"],
        ['4-byte / astral character (U+1F600)'      => "emoji \x{1F600} end"],
        ['escaped quotes/backslashes/control near non-ASCII'
                                                     => "she said \"hi\"\ttab\\\\slash\x{e9}end"],
    );
    for my $c (@cases) {
        my ($label, $text) = @$c;
        my $raw = JSON::PP->new->utf8->canonical->encode(
            { tool_name => 'Bash', tool_input => { command => $text }, session_id => 'x' });
        BpHook::load_payload($raw);
        my $got = BpHook::payload();
        my $expected = JSON::PP->new->utf8->decode($raw);
        is_deeply($got, $expected,
            "AC-56 (Decision 25 (1)): decode of '$label' equals JSON::PP->new->utf8->decode")
            or diag("label: $label");
        ok(BpHook::payload_ok(), "AC-56: '$label' decodes successfully (payload_ok true)");
    }

    # Input that already carries \uXXXX escapes (surrogate pair for the
    # astral character), built with JSON::PP's OWN ->ascii mode so the raw
    # bytes on the wire are pure ASCII text containing literal é and
    # 😀 sequences -- exactly the shape Decision 25 names.
    {
        my $text = "caf\x{e9} and \x{1F600} together";
        my $raw = JSON::PP->new->ascii->canonical->encode(
            { tool_name => 'Bash', tool_input => { command => $text }, session_id => 'x' });
        like($raw, qr/\\u00e9/i, 'AC-56 fixture sanity: raw text literally carries a é escape');
        like($raw, qr/\\ud83d\\ude00/i, 'AC-56 fixture sanity: raw text literally carries the astral surrogate pair');
        BpHook::load_payload($raw);
        my $got = BpHook::payload();
        my $expected = JSON::PP->new->utf8->decode($raw);
        is_deeply($got, $expected,
            'AC-56 (Decision 25 (1)): decode of pre-escaped é/😀 input equals JSON::PP->new->utf8->decode');
        ok(BpHook::payload_ok(), 'AC-56: pre-escaped input decodes successfully');
    }

    # Non-ASCII object keys.
    {
        my $raw = JSON::PP->new->utf8->canonical->encode(
            { tool_name => 'Bash', tool_input => { command => 'echo hi', "caf\x{e9}_meta" => 1 }, session_id => 'x' });
        BpHook::load_payload($raw);
        my $got = BpHook::payload();
        my $expected = JSON::PP->new->utf8->decode($raw);
        is_deeply($got, $expected,
            'AC-56 (Decision 25 (1)): decode with a non-ASCII object key equals JSON::PP->new->utf8->decode');
        ok(exists $got->{tool_input}{"caf\x{e9}_meta"}, 'AC-56: the non-ASCII key itself is present and correctly decoded');
    }
}

# ===========================================================================
# AC-57 -- Decision 25 (1): invalid UTF-8 falls back to today's handling.
# Pin the CURRENT observable outcome (payload_ok false, payload() {}) for one
# invalid-UTF-8 payload, so a future fast-path change is not allowed to
# change this fallback's behaviour.
# ===========================================================================
{
    my $bad = "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bad" . "\xFF" . "byte\"}}";
    BpHook::load_payload($bad);
    is(BpHook::payload_ok(), 0, 'AC-57 (Decision 25 (1)): invalid UTF-8 -> payload_ok() false, as today');
    is_deeply(BpHook::payload(), {}, 'AC-57: invalid UTF-8 -> payload() {} (today\'s fallback), unchanged by the fast path');
}

# ===========================================================================
# AC-58 -- Decision 28 correction of Decision 27's own oracle: an absolute
# bound on a fresh-child decode is flaky by design under the runner's
# parallel load (project CLAUDE.md: contention inflates timings; the driver
# measured the 1 MiB U+00E9 decode exceeding 4s under -j6 while it takes 2.3s
# alone). The property this test exists to catch is a return to the
# super-linear decode (32s at 512 KiB pre-fix), not a specific wall-clock
# number. So: in the SAME fresh child perl process (a real hook is always a
# fresh process), time BpHook::load_payload on two payloads of the SAME raw
# byte length -- pure ASCII, and all U+00E9 -- and assert the non-ASCII time
# is at most 4x the ASCII time (guarding against a near-zero ASCII baseline
# with max(ascii, 0.05)), plus an absolute backstop under 12s so a genuinely
# hung decode still fails in bounded time. Both payloads must decode
# successfully (payload_ok == 1). Bounded by a 60s timeout on the whole
# child (never redirected to NUL) so a still-slow decode fails this
# assertion in bounded time instead of hanging the file.
#
# Package 09-gb-h-residuals, AC-17 / spec sec 3.15: the child times
# load_payload THREE times per payload and reports the MINIMUM of the three
# (Decision 34 -- a single timing under -jN runner contention is flaky by
# construction; the minimum is the closest approximation to an unloaded
# cost this in-process child can produce without a dedicated quiescent
# host). The ratio and backstop assertions below consume those minimums.
# The whole-child alarm rises from 30s to 60s to cover three decodes per
# payload instead of one.
# ===========================================================================
{
    my $n = 524288; # 2 bytes/char -> ~1,048,576 bytes of command text alone
    my $cmd_utf8  = "\x{e9}" x $n;
    my $cmd_ascii = 'a' x (2 * $n); # same raw byte count as the utf8 command text
    my $raw_utf8  = JSON::PP->new->utf8->canonical->encode(
        { tool_name => 'Bash', tool_input => { command => $cmd_utf8 }, session_id => 'x' });
    my $raw_ascii = JSON::PP->new->utf8->canonical->encode(
        { tool_name => 'Bash', tool_input => { command => $cmd_ascii }, session_id => 'x' });
    cmp_ok(length($raw_utf8), '>', 1024 * 1024 * 0.9, 'AC-58 fixture sanity: utf8 raw payload is roughly 1 MiB');
    cmp_ok(abs(length($raw_utf8) - length($raw_ascii)), '<', 16,
        'AC-58 fixture sanity: ascii and utf8 raw payloads have the same raw byte length');

    my (undef, $ascii_path) = tempfile();
    open(my $afh, '>:raw', $ascii_path) or die "AC-58: cannot write ascii payload fixture: $!";
    print {$afh} $raw_ascii;
    close $afh;
    my (undef, $utf8_path) = tempfile();
    open(my $ufh, '>:raw', $utf8_path) or die "AC-58: cannot write utf8 payload fixture: $!";
    print {$ufh} $raw_utf8;
    close $ufh;

    my $scripts_dir = "$BUTLER_DIR/scripts";
    my $child_code = <<'PERL';
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
require BpHook;
require Time::HiRes;
my ($ascii_path, $utf8_path) = @ARGV;
for my $pair ([ascii => $ascii_path], [utf8 => $utf8_path]) {
    my ($label, $path) = @$pair;
    open(my $fh, '<:raw', $path) or die "child: cannot open $label payload: $!";
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $min_elapsed;
    my $ok_count = 0;
    for (1 .. 3) {
        my $t0 = Time::HiRes::time();
        BpHook::load_payload($raw);
        my $elapsed = Time::HiRes::time() - $t0;
        $min_elapsed = $elapsed if !defined($min_elapsed) || $elapsed < $min_elapsed;
        $ok_count++ if BpHook::payload_ok();
    }
    print "ELAPSED_\U$label\E=$min_elapsed\n";
    print "PAYLOAD_OK_\U$label\E=" . (($ok_count == 3) ? 1 : 0) . "\n";
}
PERL

    my @cmd = ($^X, '-I', $scripts_dir, '-e', $child_code, $ascii_path, $utf8_path);
    my $pid = open(my $ph, '-|');
    die "AC-58: fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDIN, '<', '/dev/null') or CORE::exit(126);
        exec(@cmd);
        CORE::exit(127);
    }
    my $timed_out = 0;
    my $child_out;
    {
        local $SIG{ALRM} = sub { $timed_out = 1; kill('KILL', $pid); die "AC-58: 60s timeout hit\n" };
        alarm(60);
        eval { local $/; $child_out = <$ph>; };
        alarm(0);
    }
    close $ph;
    waitpid($pid, 0);

    ok(!$timed_out, 'AC-58: the child perl process completed within the 60s timeout');
    my ($ascii_elapsed) = ($child_out // '') =~ /^ELAPSED_ASCII=([\d.eE+-]+)/m;
    my ($ascii_ok)      = ($child_out // '') =~ /^PAYLOAD_OK_ASCII=(\d+)/m;
    my ($utf8_elapsed)  = ($child_out // '') =~ /^ELAPSED_UTF8=([\d.eE+-]+)/m;
    my ($utf8_ok)       = ($child_out // '') =~ /^PAYLOAD_OK_UTF8=(\d+)/m;

    diag("AC-58: ascii elapsed=" . (defined $ascii_elapsed ? $ascii_elapsed : '<undef>') . "s, "
        . "utf8 elapsed=" . (defined $utf8_elapsed ? $utf8_elapsed : '<undef>') . 's');

    my $ascii_baseline = defined $ascii_elapsed ? $ascii_elapsed : 999;
    my $utf8_time      = defined $utf8_elapsed  ? $utf8_elapsed  : 999;
    my $ratio_cap = 4 * ($ascii_baseline > 0.05 ? $ascii_baseline : 0.05);
    cmp_ok($utf8_time, '<=', $ratio_cap,
        "AC-58 (Decision 28): the U+00E9 decode is at most 4x the same-length ASCII decode (ascii=${ascii_baseline}s, cap=${ratio_cap}s)")
        or diag("child output: " . ($child_out // '<undef>'));
    cmp_ok($utf8_time, '<', 12,
        'AC-58 (Decision 28): absolute backstop -- the U+00E9 decode finishes under 12s even under load')
        or diag("child output: " . ($child_out // '<undef>'));
    is($ascii_ok, 1,
        'AC-58: the fresh child process decoded the ASCII payload successfully (payload_ok == 1)')
        or diag("child output: " . ($child_out // '<undef>'));
    is($utf8_ok, 1,
        'AC-58: the fresh child process decoded the U+00E9 payload successfully (payload_ok == 1)')
        or diag("child output: " . ($child_out // '<undef>'));
}

# ===========================================================================
# AC-59 -- Decision 25 (2), corrected by Decision 27: pre-decode deny in
# every role, driven through the REAL entry path (BpHook::main, exactly as
# AC-61 drives it, via real_entry_main()/with_decode_counter() below) so
# Decision 26's raw-length check -- which must run BEFORE any decode -- is
# what is actually exercised, rather than GuardHarness::run_module's own
# reimplementation of that sequence. Keeps the three roles, the rc=2
# verdict, qr/script file/i, and the under-4s bound; adds Decision 27's own
# requirement, that JSON::PP::decode is called 0 times.
# ===========================================================================
{
    my $n = 524288; # ~1 MiB of command text, same fixture shape as AC-58

    my $driver_main = caller_by_name('driver-main');
    my $coordinator = caller_by_name('coordinator');

    my @role_cases = (
        ['driver main session'          => $driver_main, {}],
        ['coordinator (BP_LEDGER set)'  => $coordinator, {}],
        ['bypassPermissions'            => $driver_main, { permission_mode => 'bypassPermissions' }],
    );
    for my $rc_case (@role_cases) {
        my ($label, $caller, $extra) = @$rc_case;
        my %env = real_entry_env($caller);
        my $raw = big_command_json($n, session_id => $DRIVER_SID, %$extra);
        my ($res_and_elapsed, $decode_calls) = with_decode_counter(sub {
            my ($res, $elapsed) = real_entry_main($raw, %env);
            return [$res, $elapsed];
        });
        my ($res, $elapsed) = @$res_and_elapsed;
        cmp_ok($elapsed, '<', 4,
            "AC-59 (Decision 25 (2)): $label -> verdict returns well under 4s (no full decode)")
            or diag("elapsed: $elapsed s; rc=$res->{rc}; died=" . ($res->{died} // ''));
        is($res->{rc}, 2, "AC-59: $label -> a >1 MiB raw Bash payload is denied")
            or diag("stdout: $res->{out}\nstderr: $res->{err}\ndied: " . ($res->{died} // ''));
        like($res->{err}, qr/script file/i,
            "AC-59: $label -> the deny names the existing over-size remedy (write it to a script file)")
            or diag("stderr: $res->{err}");
        is($decode_calls, 0,
            "AC-59 (Decision 27): $label -> no JSON::PP::decode call happened at all (seam: local *JSON::PP::decode wrap)")
            or diag("decode_calls: $decode_calls");
    }
}

# ===========================================================================
# AC-60 -- Decision 25 (3): the 256 KiB cap counts UTF-8 BYTES of the
# command, not characters. 150000 copies of U+00E9 is 150000 characters
# (under 256 Ki = 262144 characters) but 300000 bytes (over the 256 KiB
# cap) -- must be denied by the cap specifically. A 100000-character ASCII
# command with a benign body stays under the cap in both counts and is not
# denied at all.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');

    my $n_chars = 150000;
    ok($n_chars < 256 * 1024, 'AC-60 fixture sanity: 150000 is under 256 Ki characters');
    my $over_cmd = 'touch ' . ("\x{e9}" x $n_chars);
    my $over_cmd_bytes = do { my $c = $over_cmd; utf8::upgrade($c); utf8::encode($c); length $c };
    cmp_ok($over_cmd_bytes, '>', 256 * 1024,
        'AC-60 fixture sanity: the same command is over 256 KiB once counted as UTF-8 bytes');
    my $res_over = run_for($driver_main, $over_cmd);
    is($res_over->{rc}, 2, 'AC-60 (Decision 25 (3)): 150000xU+00E9 (300000 bytes) -> denied');
    like($res_over->{err}, qr/over 256 ?Ki?B/i,
        'AC-60: the denial specifically names the 256 KiB cap, not some other GB-h rule')
        or diag("stderr: $res_over->{err}");

    my $ascii_cmd = 'echo ' . ('a' x 100000);
    ok(length($ascii_cmd) < 256 * 1024, 'AC-60 fixture sanity: the ASCII command is under the cap in characters too');
    my $res_ascii = run_for($driver_main, $ascii_cmd);
    is($res_ascii->{rc}, 0,
        'AC-60: a 100000-character ASCII command with a benign body stays under the cap and is allowed');
}

# ===========================================================================
# Decision 26 (correction of Decision 25). Driver's review of the Decision 25
# implementation found: load_payload() still decodes FIRST, unconditionally,
# then GuardBash::run() checks BpHook::raw_length() only AFTER that decode
# already happened -- so an 8 MiB (or truncated) Bash payload still pays the
# full decode cost before the over-size deny ever fires. Required property:
# such a payload is denied WITHOUT any JSON decoder running, in every role.
# Also: the JSON::PP::utf8 slow-fallback path (today unconditional) must stop
# running above 64 KiB raw, so one invalid byte cannot force the slow path
# onto a large payload.
#
# "Real hook entry path" for this file: BpHook::main() itself (the exact
# function run-hook.sh's spawned perl one-liner calls: read stdin, decide the
# module, load_payload, require, dispatch to run()) -- not
# GuardHarness::run_module (which reimplements that sequence for
# convenience) and not a real bash subprocess (redundant spawn-time noise on
# a Windows host, and the fix's write_set is BpHook.pm/GuardBash.pm only --
# guard-bash.sh/run-hook.sh are not in this package's write_set). This
# matches hook-core-api.t's own A19 pattern: redirect *STDIN to a real file,
# call BpHook::main('Guards::GuardBash') directly, read back BpHook::main()'s
# own return value and whatever GuardBash's run()->BpHook::deny() wrote to
# STDERR.
# ===========================================================================

# ---------------------------------------------------------------------------
# real_entry_main($raw, %env) -- BpHook::main('Guards::GuardBash') through
# its own real stdin-read/load_payload/dispatch order, wall-clock timed
# (Time::HiRes), bounded by a hard alarm backstop ($backstop_seconds,
# default 8, same convention as timed_load_payload above) so a
# still-slow decode fails this file's own timing assertions instead of
# hanging the whole run. Returns ({ rc, err }, elapsed_seconds).
#
# CAUTION for callers with a multi-MB non-ASCII payload: BpHook::load_payload
# wraps EACH of its own decode attempts in its own eval(), so an alarm that
# fires WHILE the fast (already-implemented Decision 25) path's regex
# substitution is still running does NOT abort load_payload -- that eval just
# catches the die, treats the fast path as "failed", and falls through to the
# OLD unconditional slow JSON::PP->new->utf8->decode() path, which is the
# ORIGINAL quadratic-for-non-ASCII cost Decision 25 exists to avoid (32.2s
# measured at only 524 KB pre-fix) -- i.e. an alarm that fires mid-fast-path
# does not bound this call's total time, it makes it dramatically WORSE.
# Measured on this host: the (already-fixed) fast path alone takes ~2.2s at
# 1 MiB, ~4.5s at 2 MiB, ~16s at 4 MiB, ~36s at 8 MiB of all-non-ASCII
# command text -- callers driving an 8 MiB-scale fixture through this sub
# MUST pass a $backstop_seconds comfortably above that (60s used below), so
# the backstop only ever fires as a true last-resort, never mid-fast-path.
# ---------------------------------------------------------------------------
sub real_entry_main {
    my ($raw, %env) = @_;
    my $backstop_seconds = delete $env{__backstop_seconds};
    $backstop_seconds = 8 unless defined $backstop_seconds;
    local %ENV = %ENV;
    for my $k (keys %env) {
        if (defined $env{$k}) { $ENV{$k} = $env{$k} } else { delete $ENV{$k} }
    }

    my (undef, $in_path)  = tempfile();
    open(my $ifh, '>:raw', $in_path) or die "real_entry_main: cannot write stdin fixture: $!";
    print {$ifh} $raw;
    close $ifh;
    my (undef, $out_path) = tempfile();
    my (undef, $err_path) = tempfile();

    local *STDIN;
    open(STDIN, '<:raw', $in_path) or die "real_entry_main: cannot open stdin fixture: $!";
    open(my $saved_out, '>&', \*STDOUT) or die "real_entry_main: dup STDOUT: $!";
    open(my $saved_err, '>&', \*STDERR) or die "real_entry_main: dup STDERR: $!";
    open(STDOUT, '>', $out_path) or die "real_entry_main: redirect STDOUT: $!";
    open(STDERR, '>', $err_path) or die "real_entry_main: redirect STDERR: $!";

    local $SIG{__WARN__} = sub { }; # exactly like GuardHarness::run_module: BpHook::main's
                                     # own $SIG{__WARN__} writes to hook-errors.log, not here

    my $t0 = Time::HiRes::time();
    local $SIG{ALRM} = sub { die "real_entry_main: ${backstop_seconds}s hard alarm hit\n" };
    alarm($backstop_seconds);
    my $ret = eval { BpHook::main('Guards::GuardBash') };
    my $died = $@;
    alarm(0);
    my $elapsed = Time::HiRes::time() - $t0;

    open(STDOUT, '>&', $saved_out) or die "real_entry_main: restore STDOUT: $!";
    open(STDERR, '>&', $saved_err) or die "real_entry_main: restore STDERR: $!";
    close $saved_out;
    close $saved_err;
    close STDIN;

    my $err = read_bytes($err_path) // '';
    my $out = read_bytes($out_path) // '';
    unlink $in_path, $out_path, $err_path;

    my $rc = (defined $ret && !length($died)) ? $ret : 0;
    return ({ rc => $rc, out => $out, err => $err, died => $died }, $elapsed);
}

# ---------------------------------------------------------------------------
# real_entry_env($caller) -- the env overlay real_entry_main() needs to reach
# GuardBash's own role()/BP_LEDGER checks, mirroring run_for()'s env exactly
# (same $STATE_BASE/$REPO/$TMPFIX/$HOMEFIX/$CCPDIR fixtures already built at
# the top of this file) plus BUTLER_STATE_DIR so BpHook::role() can resolve
# the caller's armed-driver record.
# ---------------------------------------------------------------------------
sub real_entry_env {
    my ($c) = @_;
    my %env = (
        BUTLER_STATE_DIR  => $STATE_BASE,
        CLAUDE_PROJECT_DIR => $REPO,
        TMP => $TMPFIX, TEMP => $TMPFIX, TMPDIR => $TMPFIX,
        HOME => $HOMEFIX, USERPROFILE => $HOMEFIX,
        CCPRAXIS_DATA_DIR => $CCPDIR,
    );
    $env{BP_LEDGER} = $c->{ledger} if defined $c->{ledger};
    return %env;
}

# ---------------------------------------------------------------------------
# big_command_json($n_chars, %extra) -- a canonical-encoded Bash tool_input
# payload whose command is $n_chars copies of U+00E9 (non-ASCII-heavy, same
# fixture shape as AC-58/AC-59), with session_id/tool_input/tool_name key
# order fixed by JSON::PP's ->canonical (alphabetical: session_id sorts
# before tool_input/tool_name), so session_id lands within any small prefix
# of the raw bytes regardless of how large the command text is. %extra keys
# (session_id) are merged onto the payload hash before encoding.
# ---------------------------------------------------------------------------
sub big_command_json {
    my ($n_chars, %extra) = @_;
    my $cmd = "\x{e9}" x $n_chars;
    my $p = { tool_name => 'Bash', tool_input => { command => $cmd } };
    $p->{session_id}      = $extra{session_id}      if defined $extra{session_id};
    $p->{permission_mode} = $extra{permission_mode} if defined $extra{permission_mode};
    return JSON::PP->new->utf8->canonical->encode($p);
}

# ---------------------------------------------------------------------------
# with_decode_counter($code) -- runs $code->() with JSON::PP::decode wrapped
# to count real calls, without changing its behaviour (goto &$orig preserves
# @_ and $self, so every call still does exactly what it always did).
# Returns ($result_of_code, $decode_calls).
# ---------------------------------------------------------------------------
sub with_decode_counter {
    my ($code) = @_;
    my $orig = \&JSON::PP::decode;
    my $calls = 0;
    no warnings 'redefine';
    local *JSON::PP::decode = sub { $calls++; goto &$orig };
    my $result = $code->();
    return ($result, $calls);
}

# ===========================================================================
# AC-61 -- Decision 26 (1): an 8 MiB Bash payload (well under the
# _read_stdin_bulk 8 MiB+1 truncation cap, so this case is NOT truncated --
# denied purely on raw size) is denied with the over-size remedy in under 1s,
# through the real entry path, in the driver role and the coordinator role,
# and NO JSON decoder call happens at all.
# ===========================================================================
{
    my $n_chars = 3_900_000; # ~2 bytes/char -> ~7.8 MB of command text alone
    my $raw = big_command_json($n_chars, session_id => $DRIVER_SID);
    cmp_ok(length($raw), '>', 7 * 1024 * 1024, 'AC-61 fixture sanity: raw payload is several MiB');
    cmp_ok(length($raw), '<', 8 * 1024 * 1024, 'AC-61 fixture sanity: raw payload stays under the 8 MiB read-truncation cap');

    my $driver      = caller_by_name('driver-main');
    my $coordinator = caller_by_name('coordinator');
    for my $rc_case (
        ['driver role'      => $driver],
        ['coordinator role' => $coordinator],
    ) {
        my ($label, $caller) = @$rc_case;
        my %env = real_entry_env($caller);
        # 90s backstop, not 8s: on this host the ALREADY-implemented Decision
        # 25 fast path alone measures ~36s at 8 MiB of non-ASCII command text
        # (see real_entry_main's own comment) -- a tighter backstop would
        # fire MID-fast-path and cascade into the far slower pre-Decision-25
        # path instead of bounding anything.
        $env{__backstop_seconds} = 90;
        my ($res_and_elapsed, $decode_calls) = with_decode_counter(sub {
            my ($res, $elapsed) = real_entry_main($raw, %env);
            return [$res, $elapsed];
        });
        my ($res, $elapsed) = @$res_and_elapsed;
        cmp_ok($elapsed, '<', 1,
            "AC-61 (Decision 26 (1)): $label -> an 8 MiB Bash payload is denied in under 1s through the real entry path")
            or diag("elapsed: $elapsed s (bounded at 90s); rc=$res->{rc}; died=$res->{died}");
        is($res->{rc}, 2, "AC-61: $label -> the 8 MiB Bash payload is denied")
            or diag("out: $res->{out}\nerr: $res->{err}\ndied: $res->{died}");
        like($res->{err}, qr/script file/i,
            "AC-61: $label -> the deny names the existing over-size remedy (write it to a script file)")
            or diag("err: $res->{err}");
        is($decode_calls, 0,
            "AC-61 (Decision 26 (1)): $label -> no JSON::PP::decode call happened at all (seam: local *JSON::PP::decode wrap)")
            or diag("decode_calls: $decode_calls");
    }
}

# ===========================================================================
# AC-62 -- Decision 26 (1), the truncated-by-_read_stdin_bulk variant: a
# payload whose raw bytes exceed the 8 MiB+1 cap is genuinely truncated by
# BpHook::_read_stdin_bulk itself (which sets $ENV{BP_PAYLOAD_TRUNCATED}=1),
# not just "denied for being over 1 MiB" -- driven cheaply through the SAME
# real_entry_main() seam (an extra few thousand bytes of stdin costs nothing
# extra to write/read). Denied in under 1s, in both roles, with no decode.
# ===========================================================================
{
    my $n_chars = 4_300_000; # ~8.6 MB of command text alone -> raw > 8 MiB+1
    my $raw = big_command_json($n_chars, session_id => $DRIVER_SID);
    cmp_ok(length($raw), '>', 8 * 1024 * 1024 + 1,
        'AC-62 fixture sanity: raw payload exceeds the 8 MiB+1 _read_stdin_bulk cap');

    my $driver      = caller_by_name('driver-main');
    my $coordinator = caller_by_name('coordinator');
    for my $rc_case (
        ['driver role'      => $driver],
        ['coordinator role' => $coordinator],
    ) {
        my ($label, $caller) = @$rc_case;
        my %env = real_entry_env($caller);
        # 90s backstop -- see AC-61's comment; _read_stdin_bulk truncates to
        # exactly 8 MiB regardless of how much more stdin this fixture sends,
        # so the (already-fixed) fast path still has a full 8 MiB to scan.
        $env{__backstop_seconds} = 90;
        my ($res_and_elapsed, $decode_calls) = with_decode_counter(sub {
            my ($res, $elapsed) = real_entry_main($raw, %env);
            return [$res, $elapsed];
        });
        my ($res, $elapsed) = @$res_and_elapsed;
        cmp_ok($elapsed, '<', 1,
            "AC-62 (Decision 26 (1)): $label -> an over-8-MiB (truncated) Bash payload is denied in under 1s")
            or diag("elapsed: $elapsed s (bounded at 90s); rc=$res->{rc}; died=$res->{died}");
        is($res->{rc}, 2, "AC-62: $label -> the truncated Bash payload is denied")
            or diag("out: $res->{out}\nerr: $res->{err}\ndied: $res->{died}");
        like($res->{err}, qr/script file/i,
            "AC-62: $label -> the deny names the existing over-size remedy")
            or diag("err: $res->{err}");
        is($decode_calls, 0,
            "AC-62: $label -> no JSON::PP::decode call happened for the truncated payload either")
            or diag("decode_calls: $decode_calls");
    }
}

# ===========================================================================
# AC-63 -- Decision 26 (2): a roughly 900 KB payload with ONE invalid UTF-8
# byte inside the command string (well over the new 64 KiB slow-fallback
# ceiling) finishes BpHook::load_payload() in under 4s. Pins that
# payload_ok() ends up 0 (undecodable), not a slow success -- i.e. this is
# NOT a case where the invalid byte should somehow still decode; it is
# exactly today's fallback outcome, just required to be FAST at this size.
# The command is padded with non-ASCII text (not plain ASCII) so this
# exercises the same "large non-ASCII scan" cost path Decision 25/26 are
# about, not a trivially-fast all-ASCII string.
# ===========================================================================
{
    my $pad_chars = 460_000; # ~920 KB of valid 2-byte UTF-8 padding
    my $cmd = "\x{e9}" x $pad_chars;
    my $p = { tool_name => 'Bash', tool_input => { command => $cmd }, session_id => 'x' };
    my $raw = JSON::PP->new->utf8->canonical->encode($p);
    # Splice ONE invalid byte (0xFF, never a valid UTF-8 lead or continuation
    # byte) into the middle of the encoded command text, replacing one byte
    # of a multi-byte sequence there (so it is a genuinely invalid sequence,
    # not an appended trailing byte the fast-path's tail check would trivially
    # catch without ever touching the bulk of the padding).
    my $mid = int(length($raw) / 2);
    substr($raw, $mid, 1) = "\xFF";
    cmp_ok(length($raw), '>', 1024 * 1024 * 0.8, 'AC-63 fixture sanity: raw payload is roughly 900 KB');

    my $elapsed = timed_load_payload($raw);
    cmp_ok($elapsed, '<', 4,
        'AC-63 (Decision 26 (2)): a ~900 KB payload with one invalid UTF-8 byte finishes load_payload under 4s')
        or diag("elapsed: $elapsed s (bounded at 8s)");
    is(BpHook::payload_ok(), 0,
        'AC-63: the invalid byte makes payload_ok() false (undecodable), not a slow success');
}

# ===========================================================================
# AC-64 -- Decision 26 (2), small-payload fallback unchanged: a small (well
# under 64 KiB) payload with a lone UTF-16 surrogate escape must still be
# repaired and decode successfully, exactly as today. Already pinned by
# hook-core-api.t's R6-M2 block (a lone/paired surrogate escape, well under
# any size ceiling this package adds) -- referenced here rather than
# duplicated, per this file's own AC-16 convention of not re-executing
# another oracle's fixtures inline.
# ===========================================================================
pass('AC-64: small-payload (<64 KiB) lone-surrogate repair is covered by hook-core-api.t R6-M2 ("a payload with a lone UTF-16 surrogate escape still decodes"); not duplicated here, since Decision 26 (2) does not change behaviour under the 64 KiB ceiling');

# ===========================================================================
# AC-65 -- Decision 26 (1) scope check: the pre-decode Bash-only deny must
# NOT bleed into other guards -- a roughly 2 MiB Write-shaped payload (no
# tool_name "Bash" anywhere) still goes through the normal decode path and
# comes out payload_ok() true. Bounded generously (not a speed assertion;
# Decision 25's fast path already makes this quick, but the property this
# pins is "it still decodes at all", not a timing bound).
# ===========================================================================
{
    my $n_chars = 1_000_000; # ~2 MB of non-ASCII content text alone
    my $content = "\x{e9}" x $n_chars;
    my $p = { tool_name => 'Write', tool_input => { file_path => '/repo/big.txt', content => $content }, session_id => 'x' };
    my $raw = JSON::PP->new->utf8->canonical->encode($p);
    cmp_ok(length($raw), '>', 1024 * 1024, 'AC-65 fixture sanity: raw Write payload is over 1 MiB');

    # NOT timed_load_payload()/its 8s bound: that bound is tuned for AC-58's
    # ~1 MiB fixture. This fixture is valid, fully-decodable UTF-8 (unlike
    # AC-63's), so an alarm firing mid-fast-path here would hit the exact
    # cascade real_entry_main's own comment warns about (the fast path's own
    # eval swallows the alarm's die and falls through to the pre-Decision-25
    # quadratic slow path) -- a much worse outcome than just "the assertion
    # below fails". This is not a timing assertion at all (see block comment
    # above), so a generous 45s backstop is purely a hang-guard, never
    # expected to fire on a working fast path.
    my $t0 = Time::HiRes::time();
    local $SIG{ALRM} = sub { die "AC-65: 45s hang-guard hit\n" };
    alarm(45);
    eval { BpHook::load_payload($raw) };
    alarm(0);
    my $elapsed = Time::HiRes::time() - $t0;
    ok(BpHook::payload_ok(), 'AC-65 (Decision 26 (1) scope): a ~2 MiB Write-shaped payload still decodes (payload_ok true) -- the Bash-only deny does not bleed into other guards')
        or diag("elapsed: $elapsed s (bounded at 45s)");
    my $got = BpHook::payload();
    is($got->{tool_name}, 'Write', 'AC-65: the decoded payload really is the Write-shaped fixture, not a leftover from an earlier block');
}

# ===========================================================================
# small_command_json($cmd, %o) -- a canonical-encoded Bash tool_input payload
# for an ordinary-sized command, built through the SAME payload() shape
# run_for() uses (cmd/session_id/agent_id/cwd/permission_mode), for use with
# real_entry_main() (BpHook::main('Guards::GuardBash') itself) rather than
# GuardHarness::run_module. Defaults session_id to the armed driver session
# and cwd to B/repo, matching run_for()'s own defaults, so a caller only
# needs to pass permission_mode when it wants bypassPermissions/dontAsk.
# ===========================================================================
sub small_command_json {
    my ($cmd, %o) = @_;
    my %pargs = (cmd => $cmd, session_id => $DRIVER_SID, cwd => $REPO, %o);
    return JSON::PP->new->utf8->canonical->encode(payload(%pargs));
}

# ===========================================================================
# AC-66..AC-69 -- Decision 29 (red-team 4, MUST M1): a command substitution
# opening inside a word must NOT split that word, so the whole word -- with
# its literal ".git"/".ccpraxis-local-data" tail -- is still judged by (c)'s
# "unresolvable target, tail is a protected root" rule (spec sec 2.3/2.5,
# line ~228). Driven through the REAL entry path (BpHook::main, exactly as
# AC-61/AC-59 drive it via real_entry_main()), in the driver-main role, in
# BOTH default mode and bypassPermissions (Decision 18 Q1: (c) stays active
# under bypass, so these rows must deny in both modes -- unlike the (a)/(b)
# rows AC-13 exercises).
#
# WRITTEN BLIND TO THE FIX: BpHook.pm's _segments()/_tokenize frame-open
# branches, at the time this test is written, still flush the enclosing
# word's buffer when a $(...)/backtick/<()/>() frame opens (reports/
# 01-redteam-4.md, MUST M1). Every DENY row below is therefore expected RED
# now (rc=0, allowed) until BpHook.pm stops doing that.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my %env = real_entry_env($driver_main);

    # M1 report table rows, quoted verbatim (the mv destination /tmp/g does
    # not need to exist: (c) fires on the SOURCE being a protected root
    # regardless of the destination).
    my @deny_rows = (
        ['pwd-quoted'        => q{rm -rf "$(pwd)/.git"}],
        ['rev-parse-quoted'  => q{rm -rf "$(git rev-parse --show-toplevel)/.git"}],
        ['ccpraxis-quoted'   => q{rm -r -f "$(pwd)/.ccpraxis-local-data"}],
        ['mv-rev-parse'      => q{mv "$(git rev-parse --show-toplevel)/.git" /tmp/g}],
        ['backtick-quoted'   => q{rm -rf "`pwd`/.git"}],
        # Unquoted: the report's own table lists this row's root cause as
        # predating this package (word boundaries in bash are whitespace,
        # not quotes, so it splits the same way the quoted forms did before
        # this fix) -- included here per this package's own scoping because
        # the minimal fix (drop the buffer flush) touches all four frame-open
        # branches, quoted and unquoted alike (report's "Where" section), so
        # the same mechanism that repairs the quoted rows repairs this one.
        ['pwd-unquoted'      => q{rm -rf $(pwd)/.git}],
    );

    for my $mode_case (
        ['default mode'         => undef,                 'AC-66'],
        ['bypassPermissions'    => 'bypassPermissions',    'AC-67'],
    ) {
        my ($mode_label, $mode, $ac) = @$mode_case;
        for my $row (@deny_rows) {
            my ($row_label, $cmd) = @$row;
            my %o = defined($mode) ? (permission_mode => $mode) : ();
            my $raw = small_command_json($cmd, %o);
            my ($res, $elapsed) = real_entry_main($raw, %env);
            is($res->{rc}, 2,
                "$ac (redteam-4 M1, Decision 29): $row_label under $mode_label -> '$cmd' is denied (word not split by the substitution frame)")
                or diag("cmd: $cmd\nrc: $res->{rc}\nout: $res->{out}\nerr: $res->{err}\ndied: " . ($res->{died} // ''));
        }
    }

    # AC-68 -- Decision 22 S6 still holds after the fix: the substitution
    # BODY is still parsed as its own command, so a delete hidden inside
    # $(...) is denied on its own account, in both modes.
    for my $mode_case (
        ['default mode'         => undef],
        ['bypassPermissions'    => 'bypassPermissions'],
    ) {
        my ($mode_label, $mode) = @$mode_case;
        my $cmd = q{echo "$(rm -rf .git)"};
        my %o = defined($mode) ? (permission_mode => $mode) : ();
        my $raw = small_command_json($cmd, %o);
        my ($res, $elapsed) = real_entry_main($raw, %env);
        is($res->{rc}, 2,
            "AC-68 (Decision 22 S6, still true after Decision 29's fix): '$cmd' under $mode_label -> the substitution body is its own command and is still denied")
            or diag("rc: $res->{rc}\nout: $res->{out}\nerr: $res->{err}\ndied: " . ($res->{died} // ''));
    }

    # AC-69 -- controls: ordinary, benign command-substitution use stays
    # allowed, in both modes, so the M1 fix does not turn every $(...) into a
    # deny. `cd "$(dirname "$0")" && pwd` is judged by the file's own
    # existing (a) rules for this role (AC-1: cd is denied for every caller
    # in default/acceptEdits/plan/absent modes; AC-13: (a) is skipped under
    # bypassPermissions/dontAsk) -- recorded here as today's verdict for that
    # shape, not invented for this block.
    my @allow_rows_both_modes = (
        ['echo-date'   => q{echo "$(date)/x"}],
        ['git-C-pwd'   => q{git -C "$(pwd)" status}],
        ['rm-mktemp'   => q{rm -f "$(mktemp)"}],
    );
    for my $mode_case (
        ['default mode'         => undef],
        ['bypassPermissions'    => 'bypassPermissions'],
    ) {
        my ($mode_label, $mode) = @$mode_case;
        my %o = defined($mode) ? (permission_mode => $mode) : ();
        for my $row (@allow_rows_both_modes) {
            my ($row_label, $cmd) = @$row;
            my $raw = small_command_json($cmd, %o);
            my ($res, $elapsed) = real_entry_main($raw, %env);
            is($res->{rc}, 0,
                "AC-69: $row_label under $mode_label -> '$cmd' stays allowed (benign command substitution)")
                or diag("cmd: $cmd\nrc: $res->{rc}\nout: $res->{out}\nerr: $res->{err}\ndied: " . ($res->{died} // ''));
        }
    }
    {
        my $cd_cmd = q{cd "$(dirname "$0")" && pwd};
        my $raw_default = small_command_json($cd_cmd);
        my ($res_default, undef) = real_entry_main($raw_default, %env);
        is($res_default->{rc}, 2,
            "AC-69: cd-with-substitution under default mode -> '$cd_cmd' is denied, per AC-1's existing (a) cd rule for every caller")
            or diag("cmd: $cd_cmd\nrc: $res_default->{rc}\nout: $res_default->{out}\nerr: $res_default->{err}\ndied: " . ($res_default->{died} // ''));

        my $raw_bypass = small_command_json($cd_cmd, permission_mode => 'bypassPermissions');
        my ($res_bypass, undef) = real_entry_main($raw_bypass, %env);
        is($res_bypass->{rc}, 0,
            "AC-69: cd-with-substitution under bypassPermissions -> '$cd_cmd' is allowed, per AC-13's existing (a)-is-skipped-under-bypass rule")
            or diag("cmd: $cd_cmd\nrc: $res_bypass->{rc}\nout: $res_bypass->{out}\nerr: $res_bypass->{err}\ndied: " . ($res_bypass->{died} // ''));
    }
}

# ===========================================================================
# AC-16 -- existing suites stay green. NOT re-executed inside this file
# (each is its own multi-hundred-assertion oracle with its own fixtures and
# hermeticity guarantees; running them as a perl-in-perl subprocess sweep
# here would just duplicate scripts/run-tests.pl for no additional
# assurance). Verified directly, per file, with "perl <file>":
# guards-remake-bash.t, guard-bash-quote-strip.t, driver-validation-scope.t,
# interlock-runner-redirects.t, interlock-write-set-scope.t,
# guards-remake-track-dispatch.t, git-guard-subagent-index.t,
# hook-registration-resilience.t, hooks-reach-non-ccpraxis-project.t,
# fork-guard.t, fork-guard-bash-cost.t, checkpoint-hardening.t, and
# plugins/sandbox/tests/t/shared-claude-json-concurrency.t. write-guard-
# authoring-reports.t and hooks-selftest.t (unedited) are named by the spec
# too, for the same reason: run standalone, not embedded here.
# ===========================================================================
pass('AC-16: existing-suite regression is verified by running each file directly (see comment above), not re-executed in this file');

# ===========================================================================
# Package 09-gb-h-residuals (specs/09-gb-h-residuals-spec.md). AC-70 onward.
# WRITTEN BLIND TO THE IMPLEMENTATION, same convention as the rest of this
# file: GuardBash.pm/BpHook.pm's package-09 changes (the _hyg_deadline_at
# process-start seam, the <<\WORD/arithmetic/paren-depth lexer changes, the
# alarm pass-through, the /dev/tcp|udp fix, the sed/bash-c/write-tool
# classifier fixes, and the GB-w mkdir-ancestor case fold) DO NOT EXIST YET
# at the time this block is written -- every case below is expected RED
# until the implementer lands it, EXCEPT where a comment says otherwise
# (the spec's own AC-16-equivalent "pin" rows, and AC-82's housekeeping
# check). This file's own running AC-N numbering continues from AC-69; the
# spec's OWN "AC-2".."AC-17" labels (specs/09-gb-h-residuals-spec.md sec 4)
# are cited in parentheses alongside each new AC-NN below so the mapping to
# the spec is traceable.
# ===========================================================================

# ===========================================================================
# AC-70 (spec AC-2, sec 3.1 rows 1-2) -- the GB-h deadline is measured from
# BpHook::main's process-start stamp ($BpHook::MAIN_STARTED_AT), not from
# GB-h's own entry. Forcing the stamp to 30s in the past must deny a
# TRIGGERED command at once (fail-closed, well past the ~5s default), while
# leaving an UNtriggered command allowed; once the local scope ends, the
# triggered command allows again (the stamp does not leak into later calls).
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    {
        local $BpHook::MAIN_STARTED_AT = time() - 30;
        my $res_triggered = run_for($driver_main, 'touch f');
        is($res_triggered->{rc}, 2,
           'AC-70 (spec AC-2, sec 3.1 row 1): MAIN_STARTED_AT 30s in the past -> a triggered command denies at once (today: allows, the seam is not read)')
            or diag("err: $res_triggered->{err}");
        like($res_triggered->{err}, qr/script file/i,
           'AC-70 (spec AC-2, sec 3.1 row 1): the deadline denial names the existing over-size remedy');

        my $res_untriggered = run_for($driver_main, 'ls');
        is($res_untriggered->{rc}, 0,
           'AC-70 (spec AC-2, sec 3.1 row 1): the same stale stamp does not deny an UNtriggered command');
    }

    my $res_after = run_for($driver_main, 'touch f');
    is($res_after->{rc}, 0,
       'AC-70 (spec AC-2, sec 3.1 row 2): once the local scope ends, the same triggered command allows again (the stamp does not leak)');
}

# ===========================================================================
# AC-71 (spec AC-3, sec 2.2/4) -- through a FRESH child process (bounded by a
# 60s timeout), using the real_entry_env fixture for driver-main, two ~1 MiB
# payloads (description padded with U+00E9) each carry a command just under
# 256 KiB. The child times BpHook::load_payload(raw) alone (T_dec), then
# BpHook::main('Guards::GuardBash') with STDIN on the same raw bytes
# (T_main). T_main must stay within T_dec's own decode cost plus a fixed
# margin -- NOT decode cost plus a FRESH 5s GB-h budget, which is what
# TODAY's code gives (deadline computed at GB-h entry, after the decode).
# ===========================================================================
{
    my $CAP = 256 * 1024;
    my $target = $CAP - 4096;

    # Shape 1: rm -f ~/x ~/x ... ~/*, same construction as AC-48 shape 3
    # (worker-bash-hygiene.t's own package-01 AC numbering) -- a home-alias
    # match-all glob with many operands, denied regardless of the deadline.
    my $op = '~/x';
    my $n_ops = int(($target - length('rm -f  ~/*')) / (length($op) + 1));
    my $cmd1 = 'rm -f ' . join(' ', ($op) x $n_ops) . ' ~/*';
    ok(length($cmd1) < $CAP, 'AC-71 fixture sanity: shape 1 command is under the 256 KiB cap');

    # Shape 2: perl plugins/fx/tests/t/x.t; echo x>a>a>a...
    my $prefix2 = 'perl plugins/fx/tests/t/x.t; echo x';
    my $filler2 = '>a' x int(($target - length($prefix2)) / 2);
    my $cmd2 = $prefix2 . $filler2;
    ok(length($cmd2) < $CAP, 'AC-71 fixture sanity: shape 2 command is under the 256 KiB cap');

    my $desc = "\x{e9}" x 380000; # ~760000 bytes once UTF-8 encoded

    my @shapes = (
        [ shape1 => $cmd1, 2 ],
        [ shape2 => $cmd2, undef ],
    );

    my $scripts_dir = "$BUTLER_DIR/scripts";
    my $child_code = <<'PERL';
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
require BpHook;
require Time::HiRes;
my ($payload_path) = @ARGV;
open(my $fh, '<:raw', $payload_path) or die "child: cannot open payload: $!";
local $/;
my $raw = <$fh>;
close $fh;

my $t_dec0 = Time::HiRes::time();
eval { BpHook::load_payload($raw) };
my $t_dec = Time::HiRes::time() - $t_dec0;

open(my $ifh, '<:raw', $payload_path) or die "child: cannot reopen payload for stdin: $!";
local *STDIN;
open(STDIN, '<&', $ifh) or die "child: cannot dup stdin: $!";

open(my $saved_out, '>&', \*STDOUT) or die "child: dup STDOUT: $!";
open(my $saved_err, '>&', \*STDERR) or die "child: dup STDERR: $!";
open(STDOUT, '>', '/dev/null') or die "child: redirect STDOUT: $!";
open(STDERR, '>', '/dev/null') or die "child: redirect STDERR: $!";

my $t_main0 = Time::HiRes::time();
my $ret = eval { BpHook::main('Guards::GuardBash') };
my $died = $@;
my $t_main = Time::HiRes::time() - $t_main0;

open(STDOUT, '>&', $saved_out) or die "child: restore STDOUT: $!";
open(STDERR, '>&', $saved_err) or die "child: restore STDERR: $!";

my $rc = (defined $ret && !length($died)) ? $ret : 0;
print "T_DEC=$t_dec\n";
print "T_MAIN=$t_main\n";
print "RC=$rc\n";
PERL

    for my $s (@shapes) {
        my ($label, $cmd, $expect_rc) = @$s;
        my $payload = {
            tool_name  => 'Bash',
            tool_input => { command => $cmd, description => $desc },
            session_id => $DRIVER_SID,
            cwd        => $REPO,
        };
        my $raw = JSON::PP->new->utf8->canonical->encode($payload);
        cmp_ok(length($raw), '<', 1_040_000, "AC-71 fixture sanity: $label raw payload is under 1,040,000 bytes");

        my (undef, $payload_path) = tempfile();
        open(my $pfh, '>:raw', $payload_path) or die "AC-71: cannot write $label payload fixture: $!";
        print {$pfh} $raw;
        close $pfh;

        my %env = (
            BUTLER_STATE_DIR   => $STATE_BASE,
            CLAUDE_PROJECT_DIR => $REPO,
            TMP => $TMPFIX, TEMP => $TMPFIX, TMPDIR => $TMPFIX,
            HOME => $HOMEFIX, USERPROFILE => $HOMEFIX,
            CCPRAXIS_DATA_DIR => $CCPDIR,
        );

        local %ENV = %ENV;
        for my $k (keys %env) { $ENV{$k} = $env{$k} }

        my @cmdv = ($^X, '-I', $scripts_dir, '-e', $child_code, $payload_path);
        my $pid = open(my $ph, '-|');
        die "AC-71: fork failed: $!" unless defined $pid;
        if ($pid == 0) {
            open(STDIN, '<', '/dev/null') or CORE::exit(126);
            exec(@cmdv);
            CORE::exit(127);
        }
        my $timed_out = 0;
        my $child_out;
        {
            local $SIG{ALRM} = sub { $timed_out = 1; kill('KILL', $pid); die "AC-71: 60s timeout hit\n" };
            alarm(60);
            eval { local $/; $child_out = <$ph>; };
            alarm(0);
        }
        close $ph;
        waitpid($pid, 0);

        ok(!$timed_out, "AC-71 (spec AC-3): $label child completed within the 60s timeout");

        my ($t_dec)  = ($child_out // '') =~ /^T_DEC=([\d.eE+-]+)/m;
        my ($t_main) = ($child_out // '') =~ /^T_MAIN=([\d.eE+-]+)/m;
        my ($rc)     = ($child_out // '') =~ /^RC=(-?\d+)/m;

        diag("AC-71: $label T_dec=" . ($t_dec // '<undef>') . "s T_main=" . ($t_main // '<undef>') . "s rc=" . ($rc // '<undef>'));

        my $t_dec_v  = defined $t_dec  ? $t_dec  : 999;
        my $t_main_v = defined $t_main ? $t_main : 999;
        my $cap = ($t_dec_v > 5 ? $t_dec_v : 5) + 1.0;
        cmp_ok($t_main_v, '<=', $cap,
            "AC-71 (spec AC-3): $label T_main <= max(5, T_dec) + 1.0s (today: GB-h starts its own fresh 5s AFTER the decode)")
            or diag("child output: " . ($child_out // '<undef>'));
        cmp_ok($t_main_v, '<', 12,
            "AC-71 (spec AC-3): $label T_main < 12s backstop")
            or diag("child output: " . ($child_out // '<undef>'));

        if (defined $expect_rc) {
            is($rc, $expect_rc, "AC-71 (spec AC-3): $label exits rc $expect_rc")
                or diag("child output: " . ($child_out // '<undef>'));
        }

        unlink $payload_path;
    }
}

# ===========================================================================
# AC-72 (spec AC-4, sec 3.3) -- a die matching /alarm/i (and NOT matching
# JSON::PP's own "at character offset" phrase) raised inside ANY decode
# attempt in load_payload propagates out of load_payload. A JSON::PP-shaped
# die that happens to mention "alarm" (the control) does not propagate, and
# payload_ok() stays 0 either way.
# ===========================================================================
{
    my $raw = JSON::PP->new->utf8->canonical->encode(
        { tool_name => 'Bash', tool_input => { command => 'echo hi' }, session_id => 'x' });

    {
        no warnings 'redefine';
        local *JSON::PP::decode = sub { die "alarm clock\n" };
        eval { BpHook::load_payload($raw) };
        my $died = $@;
        like($died, qr/alarm/,
            'AC-72 (spec AC-4, sec 3.3): a die matching /alarm/i inside the decode propagates out of load_payload (today: swallowed)');
    }

    {
        no warnings 'redefine';
        local *JSON::PP::decode = sub { die "garbage at character offset 3 (before \"alarm\")\n" };
        eval { BpHook::load_payload($raw) };
        my $died = $@;
        is($died, '',
            'AC-72 (spec AC-4, sec 3.3): a JSON::PP-shaped "at character offset" die, even mentioning "alarm", does NOT propagate');
        is(BpHook::payload_ok(), 0,
            'AC-72: the control die still leaves payload_ok() 0, same as any other swallowed decode failure');
    }
}

# ===========================================================================
# AC-73 (spec AC-5, sec 3.4) -- <<\WORD (a backslash-escaped delimiter) is
# recognised as a quoted-delimiter heredoc operator; its body is skipped
# like any other quoted-delimiter heredoc body.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my $cmd1 = "cat <<\\EOF > $TMPFIX/f\ncd x\nEOF";
    is(run_for($driver_main, $cmd1)->{rc}, 0,
       'AC-73 (spec AC-5, sec 3.4 row 1): cat <<\EOF with "cd x" only inside the body -> allow (today a false B-1)')
        or diag("cmd: $cmd1");

    my $cmd2 = "cat <<\\EOF\ndon't\nEOF\nrm -rf .git";
    is(run_for($driver_main, $cmd2)->{rc}, 2,
       'AC-73 (spec AC-5, sec 3.4 row 2): a REAL rm -rf .git AFTER the <<\EOF body -> deny (c) (today allowed)')
        or diag("cmd: $cmd2");
}

# ===========================================================================
# AC-74 (spec AC-6, sec 3.5) -- arithmetic spans ($(( )) anywhere, (( )) in
# command position) are recognised with a bounded look-ahead and replaced by
# a single unpredictable placeholder, so nothing inside them is lexed as a
# heredoc operator, redirect or separator; a failed look-ahead falls back to
# today's lexing exactly (no new bypass).
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my @allow_rows = (
        [ '(( i > 3 ))'                               => $OUTSIDE ],
        [ 'if (( n > 0 )); then echo y; fi'            => $OUTSIDE ],
        [ 'echo "$(( 3 > 2 ))"'                        => $OUTSIDE ],
        [ 'x=$(( y > 0 ? 1 : 0 ))'                     => $OUTSIDE ],
        [ 'for (( i=0; i<3; i++ )); do echo $i; done'  => $REPO ],
    );
    for my $r (@allow_rows) {
        my ($cmd, $cwd) = @$r;
        my $res = run_for($driver_main, $cmd, cwd => $cwd);
        is($res->{rc}, 0, "AC-74 (spec AC-6, sec 3.5): '$cmd' -> allow (today false B-2)") or diag("cmd: $cmd, err: $res->{err}");
    }

    my @deny_rows = (
        [ "(( x = 1 << y ))\nrm -rf .git" => 'arithmetic << is not a heredoc, then a real rm -rf .git' ],
        [ "echo \$((1<<n))\nrm -rf .git"   => 'arithmetic $(( 1<<n )), then a real rm -rf .git' ],
    );
    for my $r (@deny_rows) {
        my ($cmd, $label) = @$r;
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-74 (spec AC-6, sec 3.5): $label -> deny (c) (today: bypass)") or diag("cmd: $cmd");
    }

    # must-stay-denied controls (spec sec 5 E7): a $( substitution inside
    # arithmetic, and bash's own nested-subshell "((cd O) && ls)" reading,
    # both fail the look-ahead and fall back to today's lexing -- neither
    # becomes a NEW bypass relative to HEAD.
    my $ctrl1 = 'echo $(( $(rm -rf .git) + 1 ))';
    is(run_for($driver_main, $ctrl1)->{rc}, 2,
       'AC-74 control (spec AC-6): a $( substitution inside arithmetic still denies (c)') or diag("cmd: $ctrl1");

    my $ctrl2 = "((cd $OUTSIDE) && ls)";
    is(run_for($driver_main, $ctrl2)->{rc}, 2,
       'AC-74 control (spec AC-6): ((cd <O>) && ls) still denies B-1') or diag("cmd: $ctrl2");

    # New pin: the arithmetic look-ahead's failure-scan does not exempt
    # parens that appear inside ${...} PATTERN TEXT (a parameter-expansion
    # pattern-removal/substitution operator, e.g. ${x//(/}) or immediately
    # after a backslash. A crafted command can use that to make the whole
    # arithmetic span collapse into one inert ${_bp_arith} placeholder (0
    # targets) while smuggling a real command past it between the
    # placeholder and the next statement.
    my $bypass = q{(( ${x//(/} + ${y//(/} )); rm -rf .git; : ${z//))/}};
    is(run_for($driver_main, $bypass)->{rc}, 2,
       'AC-74 (spec AC-6, sec 3.5): arithmetic look-ahead smuggled past ${...} pattern-text parens -> deny (c) (today: wrongly allowed, 0 targets found)')
        or diag("cmd: $bypass");
}

# ===========================================================================
# AC-75 (spec AC-7, sec 3.6) -- a frame whose closer is ")" (opened by $(,
# <( or >() keeps its OWN paren depth; only a ")" at depth 0 closes it.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    # Row 1 is spec sec 3.6's own example: "$(" opens a frame whose closer is
    # ")", and _segments() ALREADY treats an unquoted ")" as a segment
    # boundary at the TOP level -- that is exactly why a top-level
    # `case $1 in (a) rm -rf .git;; esac` is already denied today. The bug
    # here is narrower: the frame does not yet keep its OWN paren depth, so
    # the case arm's "(a)" closes the $( frame early instead of being treated
    # as nested depth, and the real `rm -rf .git` after it is read as live
    # text inside the (still-open, from the parser's broken point of view)
    # substitution rather than as the closing boundary. The fix is the
    # one-line depth-tracking branch in sec 3.6 ("An unquoted ( increments
    # the depth ... only a ) at depth 0 closes the frame"); it does not
    # require new case-statement grammar.
    my $cmd1 = q{X="$(case $1 in (a) rm -rf .git;; esac)"};
    is(run_for($driver_main, $cmd1)->{rc}, 2,
       'AC-75 (spec AC-7, sec 3.6 row 1): case (a) inside "$( ... )" -> deny (c) (today allowed; frame paren depth missing)') or diag("cmd: $cmd1");

    my $cmd2 = q{x="$( (echo a) )"};
    is(run_for($driver_main, $cmd2)->{rc}, 0,
       'AC-75 (spec AC-7, sec 3.6 row 2): a balanced nested ( ) inside "$( ... )" -> allow') or diag("cmd: $cmd2");

    my $cmd3 = q{echo "$(printf '%s' '(')"};
    is(run_for($driver_main, $cmd3)->{rc}, 0,
       q{AC-75 (spec AC-7, sec 3.6 row 3): a literal '(' produced inside a quoted command substitution -> allow}) or diag("cmd: $cmd3");

    # New pin: the SAME missing-frame-depth bug also wrongly allows an
    # unquoted-but-still-dangerous subshell form that doesn't involve a case
    # statement at all -- a bare nested subshell "( (rm -rf .git) )" whose
    # outer "$(" frame closes early at the inner ")" , leaving the real
    # `rm -rf .git` unseen. Red-team confirmed all three variants below are
    # affected by the same bug; at minimum the first (double-quoted) is
    # required, the other two are included for the same reason.
    my $cmd4 = q{x="$( (rm -rf .git) )"};
    is(run_for($driver_main, $cmd4)->{rc}, 2,
       'AC-75 (spec AC-7, sec 3.6): x="$( (rm -rf .git) )" -> deny (c) (today allowed; frame paren depth missing)') or diag("cmd: $cmd4");

    my $cmd5 = q{x=$( (rm -rf .git) )};
    is(run_for($driver_main, $cmd5)->{rc}, 2,
       'AC-75 (spec AC-7, sec 3.6): x=$( (rm -rf .git) ) (unquoted) -> deny (c) (today allowed; frame paren depth missing)') or diag("cmd: $cmd5");

    my $cmd6 = q{echo "$( (rm -rf .git) )"};
    is(run_for($driver_main, $cmd6)->{rc}, 2,
       'AC-75 (spec AC-7, sec 3.6): echo "$( (rm -rf .git) )" -> deny (c) (today allowed; frame paren depth missing)') or diag("cmd: $cmd6");
}

# ===========================================================================
# AC-76 (spec AC-8, sec 3.8) -- _hyg_never_target also covers /dev/tcp/ and
# /dev/udp/ pseudo-devices (never a resolvable write target).
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    for my $c (
        [ 'echo x > /dev/tcp/host/80' => 'redirect to /dev/tcp' ],
        [ 'exec 3<>/dev/tcp/host/80'  => 'fd redirect to /dev/tcp' ],
        [ 'echo x > /dev/udp/host/53' => 'redirect to /dev/udp' ],
    ) {
        my ($cmd, $label) = @$c;
        is(run_for($driver_main, $cmd)->{rc}, 0, "AC-76 (spec AC-8, sec 3.8): $label -> allow (today false B-2)") or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-77 (spec AC-9, sec 3.9) -- sed's glued-code test becomes
# /^-[nrsuzE]*[ef].+/ (an "i" before the e/f is still an in-place SUFFIX,
# not code).
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my $cmd1 = "sed -i -Ee's/a/b/' $OUTSIDE/f";
    is(run_for($driver_main, $cmd1)->{rc}, 2,
       q{AC-77 (spec AC-9, sec 3.9 row 1): sed -i -Ee's/a/b/' outside -> deny B-2 (today allowed, glued code missed)})
        or diag("cmd: $cmd1");

    my $cmd2 = "sed -i -ne's/a/b/p' $OUTSIDE/f";
    is(run_for($driver_main, $cmd2)->{rc}, 2,
       q{AC-77 (spec AC-9, sec 3.9 row 2): sed -i -ne's/a/b/p' outside -> deny B-2 (today allowed, glued code missed)})
        or diag("cmd: $cmd2");

    my $cmd3 = "sed -i -Ee's/a/b/' $REPO/f";
    is(run_for($driver_main, $cmd3)->{rc}, 0,
       'AC-77 (spec AC-9, sec 3.9 row 3): same glued-code form, target inside the repo -> allow') or diag("cmd: $cmd3");

    my $cmd4 = "sed -i -ie 's/a/b/' $OUTSIDE/f";
    is(run_for($driver_main, $cmd4)->{rc}, 2,
       'AC-77 (spec AC-9, sec 3.9 row 4): sed -i -ie (an in-place SUFFIX "e", not glued code) outside -> still deny B-2 (today\'s/unchanged behaviour)')
        or diag("cmd: $cmd4");
}

# ===========================================================================
# AC-78 (spec AC-10, sec 3.10) -- _hyg_find_shellc_script's option walk stops
# at the first predictable non-option word (no -c beyond the script operand).
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    is(run_for($driver_main, 'bash x.sh -c cd')->{rc}, 0,
       'AC-78 (spec AC-10, sec 3.10 row 1): bash x.sh -c cd -> allow (-c appears AFTER the script operand, today a false B-1)');

    for my $c (
        [ q{bash -o pipefail -c 'cd x'} => '-o pipefail skips its value, then -c is found' ],
        [ q{sh -ec 'cd x'}              => 'a glued -ec cluster matching -c' ],
        [ q{bash --norc -c 'cd x'}      => '--norc is an unlisted long option, the walk continues to -c' ],
        # New pin: a CLUSTERED option word that bundles another short flag
        # with "-o" (e.g. "-eo", "-euo") is not recognised by the option
        # walk today -- only an exact "-o"/"+o"/"-O"/"+O" consumes the next
        # word. So the walk wrongly treats "pipefail" as the script operand
        # (stopping there, no -c found) instead of correctly skipping it and
        # finding "-c" with script operand "cd x".
        [ q{bash -eo pipefail -c 'cd x'}  => 'a clustered -eo option bundles -o, which must still skip its value' ],
        [ q{bash -euo pipefail -c 'cd x'} => 'a clustered -euo option bundles -o, which must still skip its value' ],
    ) {
        my ($cmd, $label) = @$c;
        is(run_for($driver_main, $cmd)->{rc}, 2, "AC-78 (spec AC-10, sec 3.10): $label -> deny B-1") or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC-79 (spec AC-11, sec 3.11) -- unlink, shred, dd, sort and curl are added
# to $HYG_TRIGGER_RE and classified by hyg_targets per the spec's table.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my @rows = (
        [ "unlink $OUTSIDE/f"                          => 2, 'unlink outside -> deny B-2' ],
        [ "unlink $REPO/f"                              => 0, 'unlink repo -> allow' ],
        [ "shred -u $OUTSIDE/f"                          => 2, 'shred -u outside -> deny B-2 (delete)' ],
        [ "shred $OUTSIDE/f"                             => 2, 'shred (no -u) outside -> deny B-2 (write)' ],
        [ "shred -u $TMPFIX/f"                           => 0, 'shred -u tmp -> allow' ],
        [ "dd if=/dev/zero of=$OUTSIDE/f bs=1 count=1"   => 2, 'dd of= outside -> deny B-2' ],
        [ "dd if=x of=$TMPFIX/f"                         => 0, 'dd of= tmp -> allow' ],
        [ "dd if=x of=/dev/null"                         => 0, 'dd of=/dev/null -> allow' ],
        # New pin (never-halt 09-gb-h-residuals, SHOULD-FIX): dd's of= value
        # is tilde-resolved before classification, the same way other
        # home-alias write targets are, so it is recognised as targeting
        # $HOME/x (outside the repo via the HOME=HOMEFIX fixture env) rather
        # than resolving relative to cwd as the literal "<R>/~/x".
        [ "dd of=~/x"                                    => 2, 'dd of=~/x (tilde-resolved to $HOME/x) -> deny B-2 (home-alias write target)' ],
        [ "sort -o $OUTSIDE/f in.txt"                    => 2, 'sort -o outside -> deny B-2' ],
        [ "sort --output=$OUTSIDE/f in.txt"              => 2, 'sort --output= outside -> deny B-2' ],
        [ "sort -o$OUTSIDE/f in.txt"                     => 2, 'sort -oGLUED outside -> deny B-2' ],
        [ "sort -ro $OUTSIDE/f in.txt"                   => 2, 'sort -ro (cluster) outside -> deny B-2' ],
        [ "sort -o $TMPFIX/f in.txt"                     => 0, 'sort -o tmp -> allow' ],
        [ "sort -k 2 in.txt"                             => 0, 'sort -k 2 (skips its value, no target) -> allow' ],
        [ "sort -t o in.txt"                             => 0, 'sort -t o (skips its value; the "o" is not -o) -> allow' ],
        [ "curl -o $OUTSIDE/f https://x"                 => 2, 'curl -o outside -> deny B-2' ],
        [ "curl -sSLo $OUTSIDE/f https://x"              => 2, 'curl -sSLo (cluster) outside -> deny B-2' ],
        [ "curl --output=$OUTSIDE/f https://x"           => 2, 'curl --output= outside -> deny B-2' ],
        [ "curl -o $TMPFIX/f https://x"                  => 0, 'curl -o tmp -> allow' ],
        [ "curl -o - https://x"                          => 0, 'curl -o - (a literal "-" target is skipped) -> allow' ],
        [ "curl -O https://x/f"                          => 0, 'curl -O (ignored, not a target flag) -> allow' ],
    );
    for my $r (@rows) {
        my ($cmd, $rc, $label) = @$r;
        is(run_for($driver_main, $cmd)->{rc}, $rc, "AC-79 (spec AC-11, sec 3.11): $label") or diag("cmd: $cmd");
    }

    is(run_for($driver_main, 'unlink .git')->{rc}, 2,
       'AC-79 (spec AC-11): unlink .git -> deny (c), default mode');
    is(run_for($driver_main, 'unlink .git', permission_mode => 'bypassPermissions')->{rc}, 2,
       'AC-79 (spec AC-11): unlink .git -> deny (c), also under bypassPermissions');
}

# ===========================================================================
# AC-80 (spec AC-12, sec 3.12) -- _gb_w_mkdir_ancestor_ok computes $ci FIRST,
# then (when true) compares lc($Dc) with lc($Rc) for both the equality and
# the prefix test (REL still taken from $Dc by length).
#
# CAVEAT (test-writer note, not a spec gap in the behaviour itself): the
# spec names this call ("It calls ... _gb_w_mkdir_ancestor_ok directly after
# _gb_w_require_writeguards()") but does not give the sub's own parameter
# order/shape -- it is an EXISTING GuardBash.pm internal (not one of this
# package's "New" subs in spec sec 2.2), and this file is blind to
# GuardBash.pm's source by design. The call below is the test-writer's
# best-effort reconstruction from spec sec 3.12's own prose ("$R = {
# packages => [ { write_set => 'src/a/x.pm' } ] }" and "root <R>", "D = ...")
# as ($D, $root, $R). CORRECTED per implementer confirmation (reading the
# real code): the actual signature is ($R, $root, $D) -- ledger-data hashref
# first, root second, directory third. Calls below use that order.
# ===========================================================================
{
    ok(BpHook::Guards::GuardBash::_gb_w_require_writeguards(),
       'AC-80 (spec AC-12, sec 3.12) setup: _gb_w_require_writeguards() loads WriteGuards');

    my $root = $REPO;
    my $R = { packages => [ { write_set => 'src/a/x.pm' } ] };

    SKIP: {
        my $is_ci = eval { BpHook::WriteGuards::_is_ci() };
        skip("AC-80 case-variant row: _is_ci() is false (not a case-insensitive host), per spec sec 3.12's stated skip condition", 1)
            unless $is_ci;
        my $D_upper = uc("$root/src");
        is(BpHook::Guards::GuardBash::_gb_w_mkdir_ancestor_ok($R, $root, $D_upper), 1,
           'AC-80 (spec AC-12, sec 3.12): an upper-cased ancestor spelling -> 1 on a case-insensitive host (today 0)');
    }

    my $D_exact = "$root/src";
    is(BpHook::Guards::GuardBash::_gb_w_mkdir_ancestor_ok($R, $root, $D_exact), 1,
       'AC-80 (spec AC-12, sec 3.12): the exact-case ancestor -> 1');

    my $D_other = "$root/other";
    is(BpHook::Guards::GuardBash::_gb_w_mkdir_ancestor_ok($R, $root, $D_other), 0,
       'AC-80 (spec AC-12, sec 3.12): a non-ancestor directory -> 0');
}

# ===========================================================================
# AC-81 (spec AC-16, pin rows) -- already-closed items. Pinned here as
# regression checks (DC1); NOT DC2 red-today tests.
# ===========================================================================
{
    my $driver_main = caller_by_name('driver-main');
    my $cmd1 = "(>$OUTSIDE/f)";
    is(run_for($driver_main, $cmd1)->{rc}, 2,
       'AC-81 (spec AC-16 pin, r2-N1): (>OUTSIDE/f) -> deny B-2 (already closed; pin, not a DC2 red test)') or diag("cmd: $cmd1");

    my $cmd2 = 'rm -rf .git # ' . ('x' x 1000);
    my $res2 = run_for($driver_main, $cmd2, env => { BP_GUARD_MAX_STRIP_BYTES => '100' });
    is($res2->{rc}, 2,
       'AC-81 (spec AC-16 pin, r2-N6): BP_GUARD_MAX_STRIP_BYTES=100, rm -rf .git # <1000 x> -> deny (c) (already closed; pin, not a DC2 red test)')
        or diag("cmd: $cmd2");
}

# ===========================================================================
# AC-82 (spec AC-17, sec 3.15) -- test-file housekeeping: this file no
# longer defines sub timed_run_for (already removed above, in this same
# change -- this is a static pin, not a DC2 red-today test).
# ===========================================================================
{
    open(my $fh, '<', __FILE__) or die "AC-82: cannot reopen self: $!";
    local $/;
    my $src = <$fh>;
    close $fh;
    my $count = () = $src =~ /^sub timed_run_for\b/mg;
    is($count, 0,
       'AC-82 (spec AC-17, sec 3.15): worker-bash-hygiene.t no longer defines sub timed_run_for');
}

done_testing();
