#!/usr/bin/env perl
# bp-worker-models.pl — worker model preference resolution + fallback ladder.
#
# Implements plugins/butler/tests/../specs/b35-worker-model-preference-spec.md.
# Resolves a `worker_models:` ladder for a role (package ledger -> blueprint ->
# built-in, most-specific-wins, §2) and, on `dispatch`, walks the ladder
# (§3) bounding every attempt with a timeout (§3.1, the MEASURED hazard),
# classifying failures into the §4 reason taxonomy (SHARED with b34's
# bp-worker.pl `reason:` vocabulary), logging every rung transition via the
# MANDATED bp-log.pl (§5), and parking the package (§3 step 4 / F7) rather
# than looping when the ladder is exhausted.
#
# Does NOT touch `model:` (the coordinator's Claude model, read by
# bp-launch.sh via fm_get) or `worker_backend:`'s b32 two-level resolution —
# this package only WIDENS the config surface (spec §2, criterion 3).
#
# Core modules only (no CPAN) beyond bp-log.pl's own JSON::PP dependency.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Path qw(make_path);
use File::Basename qw(basename dirname);
use POSIX ();

require "$Bin/bp-log.pl";   # mandated means (spec §5) -- never reimplement logging/redaction.

my $BUILTIN_MODEL = 'opencode/big-pickle';

# ---------------------------------------------------------------------------
# Usage / arg parsing.
# ---------------------------------------------------------------------------
sub usage_text {
    return <<'USAGE';
usage: bp-worker-models.pl resolve  --role <bp-name> --package-ledger <path> --blueprint <path>
       bp-worker-models.pl dispatch --role <bp-name> --package-ledger <path> --blueprint <path> \
                                    --backend-bin <path> --prompt-file <path> --log <path> \
                                    --rung-timeout <seconds> \
                                    [--zen-enabled] [--zen-cmd <path>] [--zen-cap <n>]
USAGE
}

sub usage_error {
    my ($msg) = @_;
    print STDERR "bp-worker-models.pl: $msg\n";
    exit 2;
}

my @argv = @ARGV;
my $cmd = shift @argv;
if (!defined $cmd || $cmd eq '--help' || $cmd eq '-h') {
    print usage_text();
    exit(defined $cmd ? 0 : 2);
}
usage_error("unrecognised subcommand '$cmd' (expected resolve|dispatch)")
    unless $cmd eq 'resolve' || $cmd eq 'dispatch';

my %opt = (zen_enabled => 0);
while (@argv) {
    my $a = shift @argv;
    if    ($a eq '--role')           { usage_error('--role requires a value') unless @argv; $opt{role} = shift @argv; }
    elsif ($a eq '--package-ledger') { usage_error('--package-ledger requires a value') unless @argv; $opt{pkg} = shift @argv; }
    elsif ($a eq '--blueprint')      { usage_error('--blueprint requires a value') unless @argv; $opt{bp} = shift @argv; }
    elsif ($a eq '--backend-bin')    { usage_error('--backend-bin requires a value') unless @argv; $opt{backend_bin} = shift @argv; }
    elsif ($a eq '--prompt-file')    { usage_error('--prompt-file requires a value') unless @argv; $opt{prompt_file} = shift @argv; }
    elsif ($a eq '--log')            { usage_error('--log requires a value') unless @argv; $opt{log} = shift @argv; }
    elsif ($a eq '--rung-timeout')   { usage_error('--rung-timeout requires a value') unless @argv; $opt{rung_timeout} = shift @argv; }
    elsif ($a eq '--zen-enabled')    { $opt{zen_enabled} = 1; }
    elsif ($a eq '--zen-cmd')        { usage_error('--zen-cmd requires a value') unless @argv; $opt{zen_cmd} = shift @argv; }
    elsif ($a eq '--zen-cap')        { usage_error('--zen-cap requires a value') unless @argv; $opt{zen_cap} = shift @argv; }
    else                             { usage_error("unrecognised argument: $a"); }
}
usage_error('--role is required')            unless defined $opt{role};
usage_error('--package-ledger is required')  unless defined $opt{pkg};
usage_error('--blueprint is required')       unless defined $opt{bp};

# ---------------------------------------------------------------------------
# §2 resolution: parse a `worker_models:` block out of a ledger/blueprint
# file. Returns a hashref { role_or_'default' => [ model, model, ... ] }.
# Present-but-empty and absent both yield an empty hashref -- callers fall
# through to the next cascade level either way (spec F2).
# ---------------------------------------------------------------------------
sub parse_worker_models {
    my ($file) = @_;
    my %out;
    return \%out unless defined $file && -r $file;
    open(my $fh, '<', $file) or return \%out;
    my @lines = <$fh>;
    close $fh;
    chomp @lines;

    my $i;
    for my $idx (0 .. $#lines) {
        if ($lines[$idx] =~ /^worker_models:\s*$/) { $i = $idx; last; }
    }
    return \%out unless defined $i;

    for my $idx ($i + 1 .. $#lines) {
        my $line = $lines[$idx];
        last unless $line =~ /^\s+(\S+):\s*\[(.*?)\]\s*$/;
        my ($key, $rest) = ($1, $2);
        my @items = map { s/^\s+|\s+$//gr } split /,/, $rest;
        @items = grep { length } @items;
        $out{$key} = \@items if @items;
    }
    return \%out;
}

# Most-specific-wins cascade (spec §2): package-role -> package-default ->
# blueprint-role -> blueprint-default -> built-in.
sub resolve_ladder {
    my ($role, $pkg_ledger, $blueprint) = @_;
    my $pkg_wm = parse_worker_models($pkg_ledger);
    my $bp_wm  = parse_worker_models($blueprint);

    if (exists $pkg_wm->{$role})     { return ($pkg_wm->{$role},     'package-role'); }
    if (exists $pkg_wm->{'default'}) { return ($pkg_wm->{'default'}, 'package-default'); }
    if (exists $bp_wm->{$role})      { return ($bp_wm->{$role},      'blueprint-role'); }
    if (exists $bp_wm->{'default'})  { return ($bp_wm->{'default'},  'blueprint-default'); }
    return ([$BUILTIN_MODEL], 'built-in');
}

# ===========================================================================
# resolve
# ===========================================================================
if ($cmd eq 'resolve') {
    my ($ladder, $source) = resolve_ladder($opt{role}, $opt{pkg}, $opt{bp});
    print "model: $ladder->[0]\n";
    print "source: $source\n";
    exit 0;
}

# ===========================================================================
# dispatch (§3 ladder, §3.1 timeout hazard, §4 taxonomy, §5 logging, F7 park)
# ===========================================================================
usage_error('--backend-bin is required for dispatch')  unless defined $opt{backend_bin};
usage_error('--prompt-file is required for dispatch')   unless defined $opt{prompt_file};
usage_error('--log is required for dispatch')           unless defined $opt{log};
usage_error('--rung-timeout is required for dispatch')  unless defined $opt{rung_timeout};

my $rung_timeout = $opt{rung_timeout};
$rung_timeout = 30 unless $rung_timeout =~ /^\d+$/;

sub log_event {
    my (%fields) = @_;
    BpLog::event($opt{log}, 'worker_model_rung', \%fields);
}

# Run one rung attempt bounded by the external `timeout` coreutil (already a
# hard dependency of this test suite's own harness). Returns
# ($exit_code, $combined_output, $timed_out).
sub run_rung {
    my ($backend_bin, $model, $prompt_file, $timeout) = @_;
    my $outfile = "$opt{log}.rung-out.$$." . time() . '.' . int(rand(100000));
    my $pid = fork();
    die "bp-worker-models.pl: fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDOUT, '>', $outfile) or POSIX::_exit(126);
        open(STDERR, '>&', \*STDOUT) or POSIX::_exit(126);
        exec { 'timeout' } ('timeout', $timeout, $backend_bin, '--model', $model,
                             '--prompt-file', $prompt_file)
            or POSIX::_exit(127);
    }
    waitpid($pid, 0);
    my $status = $?;
    my $rc = ($status == -1) ? 255 : ($status >> 8);
    my $text = '';
    if (open(my $fh, '<', $outfile)) {
        local $/;
        $text = <$fh> // '';
        close $fh;
    }
    unlink($outfile);
    my $timed_out = ($rc == 124);
    return ($rc, $text, $timed_out);
}

# §4 reason taxonomy -- each cause its OWN branch (F8: model-unavailable and
# rate-limit must not share a code path).
sub classify_reason {
    my ($text) = @_;
    return 'window-limit'      if $text =~ /usage window|quota (?:exhausted|window)|resets in \s*\d+\s*h/i;
    return 'model-unavailable' if $text =~ /model not found|unknown model|no such model|unrecognised model/i;
    return 'rate-limit'        if $text =~ /\b429\b|rate.?limit|too many requests|throttle/i;
    return 'auth'              if $text =~ /\b401\b|unauthoriz|invalid or missing credentials|not logged in|re-?auth/i;
    return 'provider-error';
}

my ($ladder, $ladder_source) = resolve_ladder($opt{role}, $opt{pkg}, $opt{bp});
my @ladder = @$ladder;

my $rung = 0;
my $succeeded;
my $success_model;

# --- Rung 1: the role's configured ladder, in order. ------------------------
for my $model (@ladder) {
    $rung++;
    my ($rc, $text, $timed_out) = run_rung($opt{backend_bin}, $model, $opt{prompt_file}, $rung_timeout);
    if ($rc == 0) {
        log_event(role => $opt{role}, model => $model, rung => $rung, reason => 'ok');
        $succeeded = 1;
        $success_model = $model;
        last;
    }
    my $reason = $timed_out ? 'timeout' : classify_reason($text);
    log_event(role => $opt{role}, model => $model, rung => $rung, reason => $reason);
}

# --- Rung 2: OpenCode free models, best-effort, discovered at runtime -------
# (spec §3.1: never hardcode a `-free` suffix). Only attempted when the
# configured backend genuinely IS opencode -- a fake/test backend never
# reaches this branch, so it costs nothing under test and never invokes the
# real CLI from anywhere else in this file (spec §5a, §6 harness rule).
if (!$succeeded && basename($opt{backend_bin} // '') eq 'opencode') {
    $rung++;
    my ($rc, $text, $timed_out) = run_rung($opt{backend_bin}, 'models', $opt{prompt_file}, $rung_timeout);
    my @candidates;
    if (!$timed_out && $rc == 0) {
        for my $line (split /\n/, $text) {
            push @candidates, $1 if $line =~ /^(\S+).*\bfree\b/i;
        }
    }
    my $found;
    for my $cand (@candidates) {
        my ($crc, $ctext, $ctimed) = run_rung($opt{backend_bin}, $cand, $opt{prompt_file}, $rung_timeout);
        if ($crc == 0) {
            log_event(role => $opt{role}, model => $cand, rung => $rung, reason => 'ok');
            $succeeded = 1;
            $success_model = $cand;
            $found = 1;
            last;
        }
        my $reason = $ctimed ? 'timeout' : classify_reason($ctext);
        log_event(role => $opt{role}, model => $cand, rung => $rung, reason => $reason);
    }
    log_event(role => $opt{role}, model => '(free-discovery)', rung => $rung, reason => 'model-unavailable')
        unless @candidates || $found;
}

# --- Rung 3: Zen pay-as-you-go, ONLY if --zen-enabled (spec §3 item 3, F4). -
if (!$succeeded && $opt{zen_enabled}) {
    $rung++;
    my $cap_exhausted = defined $opt{zen_cap} && $opt{zen_cap} =~ /^\d+$/ && $opt{zen_cap} <= 0;
    if ($cap_exhausted) {
        log_event(role => $opt{role}, model => 'zen', rung => $rung, reason => 'spend-cap');
    }
    elsif (defined $opt{zen_cmd}) {
        my ($rc, $text, $timed_out) = run_rung($opt{zen_cmd}, 'zen', $opt{prompt_file}, $rung_timeout);
        if ($rc == 0) {
            log_event(role => $opt{role}, model => 'zen', rung => $rung, reason => 'ok');
            $succeeded = 1;
            $success_model = 'zen';
        }
        else {
            my $reason = $timed_out ? 'timeout' : classify_reason($text);
            log_event(role => $opt{role}, model => 'zen', rung => $rung, reason => $reason);
        }
    }
}

# --- Rung 4: park. -----------------------------------------------------------
if ($succeeded) {
    print "model: $success_model\n";
    print "result: ok\n";
    exit 0;
}

{
    my $existing = '';
    if (open(my $fh, '<', $opt{pkg})) {
        local $/;
        $existing = <$fh> // '';
        close $fh;
    }
    my $ts = POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', gmtime);
    my $park_note = "\n## Next action\n\n"
        . "Parked: worker-models-exhausted ($ts). Role '$opt{role}' exhausted its resolved ladder"
        . " (source: $ladder_source; models: " . join(', ', @ladder) . ") with no free-model or Zen"
        . " rung able to serve. Adjust worker_models: for this role/package, or re-enable/raise the"
        . " Zen cap, then retry.\n";
    if (open(my $fh, '>>', $opt{pkg})) {
        print $fh $park_note;
        close $fh;
    }
}
print "result: parked\n";
print "reason: worker-models-exhausted\n";
exit 9;
