#!/usr/bin/env perl
# platform: any
# ORACLE for package 04-awake-intent (blueprint wake-and-pause-consolidation), DC(1) and DC(2) of
# .ccpraxis-local-data/blueprints/wake-and-pause-consolidation/specs/04-awake-intent-spec.md.
#
# BpAwakeIntent::want_awake(\%state) is the one pure decision that the orchestrator's
# pause_holds_awake/should_touch_busy and drive-solo's pause_keepawake_phase/pause_is_long must
# all reduce to. This file drives every row of spec sec 3.2 (fleet), 3.3 (solo) and the
# should_touch_busy cases (AC-1..AC-6), then greps bp-orchestrator.pl and bp-drive-next.pl to
# prove the four call sites actually route through it rather than comparing a horizon or a
# resume time directly (AC-7). AC-7's checker subs are themselves proven against synthetic
# snippets lifted from TODAY's offending lines ("Bite"), so a checker that always returns clean
# cannot hide behind a tautology.
#
# Written BLIND to the implementation: BpAwakeIntent.pm does not exist yet when this file is
# written, and every regex/expected value below is taken from the spec, not from reading
# BpAwakeIntent.pm, bp-orchestrator.pl's or bp-drive-next.pl's post-package-04 bodies.
#
# Never BAIL_OUT: a missing BpAwakeIntent.pm must not hide the AC-7 grep failures, which are
# their own, independent proof of DC(2) (house pattern, awake-constants-single-source.t).
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use FindBin qw($Bin);
use Test::More;
use JSON::PP ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    return <$fh>;
}

# --------------------------------------------------------------------------------------------
# Loading. BpAwakeConst.pm already shipped (package 01); load it directly for the two horizon
# constants so the AC-1..AC-6 table does not need BpAwakeIntent.pm to exist just to compute its
# own fixtures. BpAwakeIntent.pm is loaded separately, by path, and its absence is reported once
# but does not stop the file -- the AC-7 grep checks below do not depend on it at all.
# --------------------------------------------------------------------------------------------
my $AC_LOADED = do { local $@; eval { require "$S/BpAwakeConst.pm"; 1 } };
ok($AC_LOADED, 'precondition: BpAwakeConst.pm loads (package 01)') or diag($@);

my $NOW = 1_793_531_812;
my $HF  = $AC_LOADED ? BpAwakeConst::FLEET_PAUSE_HORIZON() : 32 * 3600;
my $HS  = $AC_LOADED ? BpAwakeConst::SOLO_PAUSE_HORIZON()  : 12 * 3600;

my @WARNINGS;
local $SIG{__WARN__} = sub { push @WARNINGS, $_[0] };

my $AI_LOADED = do { local $@; eval { require "$S/BpAwakeIntent.pm"; 1 } };
ok($AI_LOADED, 'BpAwakeIntent.pm loads (want_awake)')
    or diag("BpAwakeIntent.pm failed to load: $@ -- every row below will now fail for that reason, which is correct");

# want_row(\%state) -> always a hashref (never dies the test file itself); a load/die failure
# collapses to {} so every field-level is() below fails for a real, visible reason rather than
# aborting the run.
sub want_row {
    my ($state) = @_;
    local $@;
    my $got = eval { BpAwakeIntent::want_awake($state) };
    return (ref($got) eq 'HASH') ? $got : {};
}

sub mk { my ($awake, $reason, $until, $handoff) = @_; return { awake => $awake, reason => $reason, until => $until, handoff => $handoff } }

my @RESULTS; # every actual {awake,reason} produced, for the AC-5 closed-set / awake<->reason checks
sub check_row {
    my ($state, $exp, $desc) = @_;
    my $got = want_row($state);
    is($got->{awake},   $exp->{awake},   "$desc: awake");
    is($got->{reason},  $exp->{reason},  "$desc: reason");
    is($got->{until},   $exp->{until},   "$desc: until");
    is($got->{handoff}, $exp->{handoff}, "$desc: handoff");
    push @RESULTS, { awake => $got->{awake}, reason => $got->{reason} };
    return $got;
}

# ==============================================================================================
# AC-1 (DC 1): fleet table, both horizons.
# ==============================================================================================
for my $hz ([$HF, 'HF'], [$HS, 'HS']) {
    my ($H, $hl) = @$hz;

    check_row({ scope => 'fleet', now => $NOW, horizon => $H, paused => undef },
        mk(0, 'idle', undef, 0), "AC-1 fleet/$hl paused undef -> idle");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H, paused => 'yes' },
        mk(0, 'idle', undef, 0), "AC-1 fleet/$hl paused non-hash string -> idle");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H,
                 paused => { reason => 'auth', manual => 1, relaunch_at => $NOW + 60 } },
        mk(0, 'pause-manual', undef, 0), "AC-1 fleet/$hl manual pause releases");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H,
                 paused => { reason => 'telemetry', manual => 0 } },
        mk(1, 'pause-pending', undef, 0), "AC-1 fleet/$hl telemetry pause with no relaunch_at holds");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', relaunch_at => $NOW + 3600 } },
        mk(1, 'pause-pending', $NOW + 3600, 0), "AC-1 fleet/$hl usage pause 1h out holds");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', relaunch_at => $NOW + $H } },
        mk(1, 'pause-pending', $NOW + $H, 0), "AC-1 fleet/$hl boundary second (now+H) holds");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', relaunch_at => $NOW + $H + 1 } },
        mk(0, 'pause-beyond-horizon', undef, 1), "AC-1 fleet/$hl first released second (now+H+1)");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', relaunch_at => $NOW + 88 * 3600 } },
        mk(0, 'pause-beyond-horizon', undef, 1), "AC-1 fleet/$hl 88h out releases");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', relaunch_at => $NOW - 60 } },
        mk(1, 'pause-pending', $NOW - 60, 0), "AC-1 fleet/$hl overdue relaunch holds");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', relaunch_at => 'soon' } },
        mk(1, 'pause-pending', undef, 0), "AC-1 fleet/$hl unparseable relaunch_at 'soon' holds");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', relaunch_at => '-5' } },
        mk(1, 'pause-pending', undef, 0), "AC-1 fleet/$hl unparseable relaunch_at '-5' holds");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H,
                 paused => { reason => 'token-refresh', relaunch_at => $NOW + 60 } },
        mk(1, 'pause-pending', $NOW + 60, 0), "AC-1 fleet/$hl fleet ignores reason (token-refresh)");
}

# ==============================================================================================
# AC-2 (DC 1): fleet horizon fallback.
# ==============================================================================================
for my $badh ('junk', undef, '1.5', -1, []) {
    my $label = !defined($badh) ? 'undef' : (ref($badh) ? 'arrayref' : "'$badh'");
    check_row({ scope => 'fleet', now => $NOW, horizon => $badh,
                 paused => { reason => 'usage', relaunch_at => $NOW + 40 * 3600 } },
        mk(0, 'pause-beyond-horizon', undef, 1), "AC-2 fleet bad horizon ($label): 40h out releases (fallback 32h)");
    check_row({ scope => 'fleet', now => $NOW, horizon => $badh,
                 paused => { reason => 'usage', relaunch_at => $NOW + 31 * 3600 } },
        mk(1, 'pause-pending', $NOW + 31 * 3600, 0), "AC-2 fleet bad horizon ($label): 31h out holds (fallback 32h)");
}

# ==============================================================================================
# AC-3 (DC 1): should_touch_busy cases, both horizons, fleet scope.
# ==============================================================================================
for my $hz ([$HF, 'HF'], [$HS, 'HS']) {
    my ($H, $hl) = @$hz;

    check_row({ scope => 'fleet', now => $NOW, horizon => $H, running => 1 },
        mk(1, 'running', undef, 0), "AC-3 fleet/$hl running");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H, outstanding => 1 },
        mk(1, 'outstanding', undef, 0), "AC-3 fleet/$hl outstanding");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', relaunch_at => $NOW + 3600 } },
        mk(1, 'pause-pending', $NOW + 3600, 0), "AC-3 fleet/$hl resume pending (timed)");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H, paused => {} },
        mk(1, 'pause-pending', undef, 0), "AC-3 fleet/$hl resume pending (no relaunch_at, F-c)");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', relaunch_at => $NOW + $H + 1 } },
        mk(0, 'pause-beyond-horizon', undef, 1), "AC-3 fleet/$hl paused-tick lease stops beyond the horizon");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H, running => 1, shutdown => 1 },
        mk(0, 'shutdown', undef, 0), "AC-3 fleet/$hl shutdown overrides running");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H, outstanding => 1, shutdown => 1,
                 paused => { reason => 'usage', relaunch_at => $NOW + 60 } },
        mk(0, 'shutdown', undef, 0), "AC-3 fleet/$hl shutdown overrides outstanding+paused");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H, shutdown => 1,
                 paused => { reason => 'usage', relaunch_at => $NOW + $H + 1 } },
        mk(0, 'shutdown', undef, 0), "AC-3 fleet/$hl shutdown overrides a beyond-horizon pause");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H, shutdown => 1,
                 paused => { reason => 'usage', relaunch_at => $NOW + 60 } },
        mk(0, 'shutdown', undef, 0), "AC-3 fleet/$hl shutdown overrides a near pause (paused-tick during shutdown)");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H },
        mk(0, 'idle', undef, 0), "AC-3 fleet/$hl nothing -> idle");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H, running => 1,
                 paused => { reason => 'usage', relaunch_at => $NOW + $H + 1 } },
        mk(1, 'running', undef, 0), "AC-3 fleet/$hl running overrides a beyond-horizon pause");
    check_row({ scope => 'fleet', now => $NOW, horizon => $H, outstanding => 1,
                 paused => { manual => 1 } },
        mk(1, 'outstanding', undef, 0), "AC-3 fleet/$hl outstanding overrides a manual pause");
}

# ==============================================================================================
# AC-4 (DC 1): solo table, both horizons.
# ==============================================================================================
for my $hz ([$HS, 'HS'], [$HF, 'HF']) {
    my ($H, $hl) = @$hz;

    check_row({ scope => 'solo', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', relaunch_at => $NOW + 60 } },
        mk(1, 'pause-pending', $NOW + 60, 0), "AC-4 solo/$hl usage 60s out holds");
    check_row({ scope => 'solo', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', relaunch_at => $NOW + 5 * 3600 } },
        mk(1, 'pause-pending', $NOW + 5 * 3600, 0), "AC-4 solo/$hl usage 5h out holds");
    check_row({ scope => 'solo', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', relaunch_at => $NOW + $H } },
        mk(1, 'pause-pending', $NOW + $H, 0), "AC-4 solo/$hl boundary (now+H) holds");
    check_row({ scope => 'solo', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', relaunch_at => $NOW + $H + 1 } },
        mk(0, 'pause-beyond-horizon', undef, 1), "AC-4 solo/$hl one second past releases, with handoff");
    check_row({ scope => 'solo', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', relaunch_at => $NOW + 88 * 3600 } },
        mk(0, 'pause-beyond-horizon', undef, 1), "AC-4 solo/$hl 88h out releases, with handoff");
    check_row({ scope => 'solo', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', relaunch_at => undef } },
        mk(1, 'pause-pending', undef, 0), "AC-4 solo/$hl undef relaunch_at holds (old behaviour)");
    check_row({ scope => 'solo', now => $NOW, horizon => $H,
                 paused => { reason => 'token-refresh', relaunch_at => $NOW + 60 } },
        mk(0, 'pause-manual', undef, 0), "AC-4 solo/$hl non-usage reason releases");
    check_row({ scope => 'solo', now => $NOW, horizon => $H,
                 paused => { reason => undef, relaunch_at => $NOW + 60 } },
        mk(0, 'pause-manual', undef, 0), "AC-4 solo/$hl undef reason releases");
    check_row({ scope => 'solo', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', relaunch_at => $NOW - 3600 } },
        mk(1, 'pause-pending', $NOW - 3600, 0), "AC-4 solo/$hl overdue holds");
    check_row({ scope => 'solo', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', relaunch_at => 'soon' } },
        mk(1, 'pause-pending', undef, 0), "AC-4 solo/$hl non-numeric 'soon' numifies small, holds");
    check_row({ scope => 'solo', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', relaunch_at => 67768036191676799 } },
        mk(0, 'pause-beyond-horizon', undef, 0), "AC-4 solo/$hl huge relaunch_at: gmtime fails, handoff 0");
    check_row({ scope => 'solo', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', relaunch_at => '1e20' } },
        mk(0, 'pause-beyond-horizon', undef, 0), "AC-4 solo/$hl '1e20': regex fails, handoff 0");
    check_row({ scope => 'solo', now => $NOW, horizon => $H,
                 paused => { reason => 'usage', manual => 1, relaunch_at => $NOW + 60 } },
        mk(1, 'pause-pending', $NOW + 60, 0), "AC-4 solo/$hl manual flag ignored by solo");
}
# horizon undef (fallback to SOLO_PAUSE_HORIZON, $HS) -- not reachable from any real call site,
# but the spec pins it anyway.
check_row({ scope => 'solo', now => $NOW, horizon => undef,
             paused => { reason => 'usage', relaunch_at => $NOW + $HS } },
    mk(1, 'pause-pending', $NOW + $HS, 0), "AC-4 solo horizon undef: boundary of fallback HS holds");
check_row({ scope => 'solo', now => $NOW, horizon => undef,
             paused => { reason => 'usage', relaunch_at => $NOW + $HS + 1 } },
    mk(0, 'pause-beyond-horizon', undef, 1), "AC-4 solo horizon undef: one past fallback HS releases, with handoff");

# ==============================================================================================
# AC-5 (DC 1): contract.
# ==============================================================================================
{
    my $sample = want_row({ scope => 'fleet', now => $NOW, horizon => $HF,
                             paused => { reason => 'usage', relaunch_at => $NOW + 60 } });
    is_deeply([ sort keys %$sample ], [ sort qw(awake reason until handoff) ],
        'AC-5: output has exactly the keys awake reason until handoff');
}

my %CLOSED_REASONS = map { $_ => 1 } qw(shutdown running outstanding pause-pending pause-manual pause-beyond-horizon idle);
my %AWAKE_REASONS  = map { $_ => 1 } qw(running outstanding pause-pending);
for my $r (@RESULTS) {
    next unless defined $r->{reason};
    ok(exists $CLOSED_REASONS{$r->{reason}}, "AC-5: produced reason '$r->{reason}' is in the closed set");
    is($r->{awake} ? 1 : 0, (exists $AWAKE_REASONS{$r->{reason}} ? 1 : 0),
        "AC-5: awake=1 iff reason in {running,outstanding,pause-pending} (saw '$r->{reason}', awake=" . ($r->{awake} // 'undef') . ")");
}

{
    my $e1 = eval { BpAwakeIntent::want_awake('x') };
    like($@, qr/state must be a hash reference/, "AC-5: want_awake('x') dies with the state-must-be-hashref message");
    my $e2 = eval { BpAwakeIntent::want_awake([]) };
    like($@, qr/state must be a hash reference/, 'AC-5: want_awake([]) dies with the state-must-be-hashref message');
    for my $bad_scope (undef, 'Fleet', 'other') {
        my $label = defined($bad_scope) ? "'$bad_scope'" : 'undef';
        eval { BpAwakeIntent::want_awake({ scope => $bad_scope }) };
        like($@, qr/scope must be 'fleet' or 'solo'/, "AC-5: scope => $label dies with the scope message");
    }
}

{
    my $state = { scope => 'fleet', now => $NOW, horizon => $HF,
                   paused => { reason => 'usage', relaunch_at => $NOW + 60 },
                   running => 0, outstanding => 0, shutdown => 0 };
    my $j = JSON::PP->new->canonical;
    my $before = $j->encode($state);
    my $r1 = want_row($state);
    my $after = $j->encode($state);
    is($after, $before, 'AC-5: the input state is unchanged (deep) before and after a call');
    my $r2 = want_row($state);
    is_deeply($r1, $r2, 'AC-5: two calls on the same state return deep-equal results');
}

# ==============================================================================================
# AC-6 (DC 1): purity by source.
# ==============================================================================================

# code_lines($src): drop everything from __END__/__DATA__ on; drop POD (^=[a-zA-Z] through
# ^=cut); drop comment-only lines; cut trailing comments. Shared with AC-7 below (spec sec 4).
sub code_lines {
    my ($src) = @_;
    return '' unless defined $src;
    my @lines = split /\n/, $src;
    my @out;
    my $in_pod = 0;
    for my $line (@lines) {
        last if $line =~ /^__(?:END|DATA)__\s*$/;
        if (!$in_pod && $line =~ /^=[a-zA-Z]/) { $in_pod = 1; next }
        if ($in_pod) { $in_pod = 0 if $line =~ /^=cut\b/; next }
        next if $line =~ /^\s*#/;
        (my $l = $line) =~ s/\s#(?:\s|$).*$//;
        push @out, $l;
    }
    return join("\n", @out);
}

{
    my $ai_src = slurp("$S/BpAwakeIntent.pm");
    if (!defined $ai_src) {
        fail('AC-6: could not read BpAwakeIntent.pm for the purity check (file absent)');
    } else {
        my $code = code_lines($ai_src);
        unlike($code, qr/\b(?:open|opendir|sysopen|system|exec|time|sleep|print|printf|unlink|mkdir|rename|qx)\b/,
            'AC-6: BpAwakeIntent.pm has no I/O-ish builtin call in its code lines');
        unlike($code, qr/`/, 'AC-6: BpAwakeIntent.pm has no backtick in its code lines');
        unlike($code, qr/\$ENV\{/, 'AC-6: BpAwakeIntent.pm has no $ENV{ in its code lines');
    }
}

# ==============================================================================================
# AC-7 (DC 2): source-grep gate over bp-orchestrator.pl and bp-drive-next.pl, plus the "Bite"
# self-proof that each checker actually catches today's offending lines.
# ==============================================================================================

sub find_H_violations {
    my ($code) = @_;
    my @bad;
    for my $line (split /\n/, $code) {
        next unless $line =~ /pause_horizon|PAUSE_HORIZON_SECONDS|FLEET_PAUSE_HORIZON|SOLO_PAUSE_HORIZON|\$horizon\b/;
        (my $stripped = $line) =~ s/=>|->|=~|!~//g;
        push @bad, $line if $stripped =~ /[<>]/ || $stripped =~ /\b(?:lt|gt|le|ge)\b/;
    }
    return @bad;
}

sub find_T_violations {
    my ($code) = @_;
    return grep { /-\s*\$now\b\s*\)?\s*(?:[<>]|\b(?:lt|gt|le|ge)\b)/ } split /\n/, $code;
}

# statement_containing($code, qr/marker/): for every match of marker, the text running from the
# start of its physical line to the first ';' following the match (spec: "a statement (text/text
# up to its first ;)" for O1/O2).
sub statement_containing {
    my ($code, $marker) = @_;
    my @out;
    while ($code =~ /$marker/g) {
        my $mstart = $-[0];
        my $line_start = rindex($code, "\n", $mstart);
        $line_start = ($line_start == -1) ? 0 : $line_start + 1;
        my $semi = index($code, ';', $mstart);
        next if $semi == -1;
        push @out, substr($code, $line_start, $semi - $line_start + 1);
    }
    return @out;
}

sub sub_body {
    my ($code, $name) = @_;
    my ($body) = $code =~ /(sub \Q$name\E \{.*?\n\})/s;
    return $body;
}

my $orch_src  = slurp("$S/bp-orchestrator.pl");
my $drive_src = slurp("$S/bp-drive-next.pl");
ok(defined $orch_src,  'AC-7: bp-orchestrator.pl is readable');
ok(defined $drive_src, 'AC-7: bp-drive-next.pl is readable');
my $orch_code  = code_lines($orch_src  // '');
my $drive_code = code_lines($drive_src // '');

# --- H, T: both files -------------------------------------------------------------------------
for my $f ([ 'bp-orchestrator.pl', $orch_code ], [ 'bp-drive-next.pl', $drive_code ]) {
    my ($name, $code) = @$f;
    my @hbad = find_H_violations($code);
    is(scalar(@hbad), 0, "H: no code line compares against a horizon in $name")
        or diag("offending line(s):\n" . join("\n", @hbad));
    my @tbad = find_T_violations($code);
    is(scalar(@tbad), 0, "T: no code line compares a resume time against \$now in $name")
        or diag("offending line(s):\n" . join("\n", @tbad));
}

# --- O1: exactly one `my $ka_phase =` statement, routed through want_awake ---------------------
{
    my @st = statement_containing($orch_code, qr/my \$ka_phase\s*=/);
    is(scalar(@st), 1, 'O1: bp-orchestrator.pl has exactly one `my $ka_phase =` statement');
    if (@st) {
        like($st[0], qr/BpAwakeIntent::want_awake\(/, 'O1: the ka_phase statement calls BpAwakeIntent::want_awake(');
        unlike($st[0], qr/\{manual\}/, 'O1: the ka_phase statement does not read {manual}');
        unlike($st[0], qr/pause_holds_awake\(/, 'O1: the ka_phase statement no longer calls pause_holds_awake(');
    }
}

# --- O2: every touch_busy( call site, at least 2, each gated by want_awake(. Package 05 is
# mandated to rework touch_busy's call sites (05-intent-in-busy-lease.md), so this pins the
# property that matters -- no touch_busy is decided outside BpAwakeIntent -- without pinning an
# exact call-site count that 05 is free to change (reviewer-step6.md MAJOR-1).
{
    my @st = statement_containing($orch_code, qr/\btouch_busy\(/);
    cmp_ok(scalar(@st), '>=', 2, 'O2: bp-orchestrator.pl has at least 2 touch_busy( call-site statements');
    for my $i (0 .. $#st) {
        like($st[$i], qr/BpAwakeIntent::want_awake\(/, "O2: touch_busy( statement $i calls BpAwakeIntent::want_awake(");
        unlike($st[$i], qr/\{manual\}/, "O2: touch_busy( statement $i does not read {manual}");
        unlike($st[$i], qr/\$resume_pending\b/, "O2: touch_busy( statement $i does not read \$resume_pending");
        unlike($st[$i], qr/should_touch_busy\(/, "O2: touch_busy( statement $i no longer calls should_touch_busy(");
        unlike($st[$i], qr/pause_holds_awake\(/, "O2: touch_busy( statement $i no longer calls pause_holds_awake(");
    }
}

# --- O3: pause_holds_awake / should_touch_busy bodies ------------------------------------------
for my $name (qw(pause_holds_awake should_touch_busy)) {
    my $body = sub_body($orch_code, $name);
    ok(defined $body, "O3: sub $name is extractable from bp-orchestrator.pl");
    if (defined $body) {
        like($body, qr/BpAwakeIntent::want_awake\(/, "O3: sub $name calls BpAwakeIntent::want_awake(");
        unlike($body, qr/\{manual\}/, "O3: sub $name does not read {manual}");
    }
}

# --- D1: pause_keepawake_phase / pause_is_long bodies ------------------------------------------
for my $name (qw(pause_keepawake_phase pause_is_long)) {
    my $body = sub_body($drive_code, $name);
    ok(defined $body, "D1: sub $name is extractable from bp-drive-next.pl");
    if (defined $body) {
        like($body, qr/BpAwakeIntent::want_awake\(/, "D1: sub $name calls BpAwakeIntent::want_awake(");
        unlike($body, qr/['"]usage['"]/, "D1: sub $name does not compare against 'usage'/\"usage\"");
    }
}

# --- D2: no eq/ne 'usage' comparison anywhere in bp-drive-next.pl's code lines ------------------
{
    my @bad = grep { /\b(?:eq|ne)\s*['"]usage['"]/ } split /\n/, $drive_code;
    is(scalar(@bad), 0, 'D2: no code line of bp-drive-next.pl compares eq/ne against \'usage\'')
        or diag("offending line(s):\n" . join("\n", @bad));
}

# --- D3: the pause branch region ----------------------------------------------------------------
{
    my $start_marker = q{$mapped->{action} eq 'pause'};
    my $end_marker   = q{action => 'pause', reason};
    my $start_idx = index($drive_code, $start_marker);
    my $end_idx   = $start_idx >= 0 ? index($drive_code, $end_marker, $start_idx) : -1;
    ok($start_idx >= 0, 'D3: the pause-branch start marker is present in bp-drive-next.pl');
    ok($end_idx >= 0,   'D3: the pause-branch end marker is present in bp-drive-next.pl');
    if ($start_idx >= 0 && $end_idx >= 0) {
        my $line_end = index($drive_code, "\n", $end_idx);
        $line_end = length($drive_code) if $line_end < 0;
        my $region = substr($drive_code, $start_idx, $line_end - $start_idx);
        like($region, qr/BpAwakeIntent::want_awake\(/, 'D3: the pause-branch region calls BpAwakeIntent::want_awake(');
        like($region, qr/\$intent->\{handoff\}/, 'D3: the pause-branch region reads $intent->{handoff}');
        like($region, qr/\$intent->\{awake\}\s*\?\s*'pause-pending'\s*:\s*'settled'/,
            "D3: the pause-branch region maps \$intent->{awake} to 'pause-pending'/'settled'");
        unlike($region, qr/pause_is_long\(/, 'D3: the pause-branch region no longer calls pause_is_long(');
        unlike($region, qr/pause_keepawake_phase\(/, 'D3: the pause-branch region no longer calls pause_keepawake_phase(');
    }
}

# ------------------------------------------------------------------------------------------------
# Bite: the checker subs above, applied to synthetic snippets of TODAY's code, must flag each.
# This is a self-proof of the checkers, independent of whatever bp-orchestrator.pl/bp-drive-next.pl
# say by the time this test runs -- it can never be satisfied by a checker that is vacuously clean.
# ------------------------------------------------------------------------------------------------
{
    my $line = 'return ($at - $now <= $horizon) ? 1 : 0;';
    ok(scalar(find_H_violations($line)), "Bite H: flags '$line'");
    ok(scalar(find_T_violations($line)), "Bite T: flags '$line'");
}
{
    my $line = q{return (($until - $now) > $PAUSE_HORIZON_SECONDS) ? 'settled' : 'pause-pending';};
    ok(scalar(find_H_violations($line)), "Bite H: flags the PAUSE_HORIZON_SECONDS comparison line");
    ok(scalar(find_T_violations($line)), "Bite T: flags the PAUSE_HORIZON_SECONDS comparison line");
}
{
    my $code = q{my $ka_phase = !$paused ? 'active' : pause_holds_awake($paused, $now, $t->{pause_horizon}) ? 'pause-pending' : 'settled';};
    my @st = statement_containing($code, qr/my \$ka_phase\s*=/);
    is(scalar(@st), 1, 'Bite O1: finds the synthetic ka_phase statement');
    if (@st) {
        unlike($st[0], qr/BpAwakeIntent::want_awake\(/, 'Bite O1: the synthetic snippet lacks want_awake, so O1 would flag it');
        like($st[0], qr/pause_holds_awake\(/, 'Bite O1: the synthetic snippet still calls pause_holds_awake(, so O1 would flag it');
    }
}
{
    my $code = q{touch_busy($t->{busy_path}) if should_touch_busy({ resume_pending => $resume_pending });};
    my @st = statement_containing($code, qr/\btouch_busy\(/);
    is(scalar(@st), 1, 'Bite O2: finds the synthetic touch_busy statement');
    if (@st) {
        like($st[0], qr/\$resume_pending\b/, 'Bite O2: the synthetic snippet carries $resume_pending, so O2 would flag it');
        like($st[0], qr/should_touch_busy\(/, 'Bite O2: the synthetic snippet still calls should_touch_busy(, so O2 would flag it');
    }
}
{
    my $code = "sub pause_holds_awake {\n    return 0 if \$paused->{manual};\n}\n";
    my $body = sub_body($code, 'pause_holds_awake');
    ok(defined $body, 'Bite O3: the synthetic sub body is extractable');
    like($body // '', qr/\{manual\}/, 'Bite O3: the synthetic body reads {manual}, so O3 would flag it') if defined $body;
}
{
    my $line = q{return 'settled' unless defined $reason && $reason eq 'usage';};
    my @bad = grep { /\b(?:eq|ne)\s*['"]usage['"]/ } ($line);
    ok(scalar(@bad), "Bite D2: flags \"$line\"");
}

done_testing();
