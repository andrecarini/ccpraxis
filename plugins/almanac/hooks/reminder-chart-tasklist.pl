#!/usr/bin/env perl
# reminder-chart-tasklist.pl -- fires on the 20th (40th, 60th, ...) main-
# thread PostToolUse call of a session, emitting additionalContext, while
# the session is armed (butler continuity) or attached to a live thread. It
# also
# emits a separate N5 nudge line when the session is neither armed nor owns
# one, provided the other N5 conditions hold (never-halt package 11, spec
# sec 2.5). Package 15-harness-tasks-and-reminder (blueprint
# almanac-records), round 3 per Decision 28: the ticket CLAIM itself now
# happens entirely inside the registration's own bash
# (plugins/almanac/hooks/hooks.json) -- builtins only, no perl, no
# subprocess -- and this script is exec'd from there ONLY when the claimed
# number is a multiple of 20. It is invoked as:
#
#     reminder-chart-tasklist.pl <N> <session_id>
#
# with the ORIGINAL PostToolUse payload still on STDIN (needed for cwd).
# <N> and <session_id> are bash's own findings, already validated there
# (digits only; the session id pattern) -- this script re-validates both
# defensively but never trusts bash's claim of "N is a multiple of 20"
# blindly for anything beyond deciding to run at all: it fails open on any
# malformed argument exactly like every other unexpected condition.
#
# ONE PROCESS, NEVER BLOCKS, ALWAYS EXITS 0. Almanac::Lock is never required
# directly by this file (review M-1): it is only ever loaded transitively,
# exactly once, via Almanac::Thread's own use of Almanac::Store on this
# firing call, loaded by MODULE NAME (require Almanac::Thread, not a path)
# so it keeps the %INC key 'Almanac/Thread.pm' (and 'Almanac/Lock.pm')
# whoever else loads it -- no second load under a different key and no
# "Subroutine redefined" warning on stderr. Every require of a repo file
# sits inside eval. Never system, exec, backticks, qx, fork or a piped open.
#
# TICKET MODEL (Decision 28), the half owned by this file: the bash claim
# leaves a numbered empty file in "<H>/.claude/almanac-state/chart-
# reminder/<sid>.t/" for every call, and a persisted ".watermark" (a
# write-if-greater ratchet) so that after THIS call deletes the tickets it
# just counted, the NEXT claim (bash again) still resumes from the right
# global number. This file both reads and advances that watermark; bash
# only ever reads it (see hooks.json's registration for the claim side).
use strict;
use warnings;

_run();
exit 0;

sub _run {
    my ($n_arg, $sid) = @ARGV;
    return unless defined $n_arg && $n_arg =~ /\A[0-9]+\z/;
    my $n = $n_arg + 0;
    return unless $n > 0 && $n % 20 == 0;
    return unless defined $sid && $sid =~ /\A[A-Za-z0-9_-]{1,128}\z/;

    binmode(STDIN, ':raw');
    my $raw = do { local $/; <STDIN> };

    my $home = _first_nonempty($ENV{ALMANAC_HOME}, $ENV{HOME}, $ENV{USERPROFILE});
    return unless defined $home && length $home;
    $home =~ s{\\}{/}g;
    return unless $home =~ m{\A(?:/|[A-Za-z]:/)};

    my $root = _plugin_root();
    my $tdir = "$home/.claude/almanac-state/chart-reminder/$sid.t";

    my $payload = (defined $raw && length $raw)
        ? eval { require JSON::PP; JSON::PP->new->decode($raw) }
        : undef;
    my $cwd = (ref $payload eq 'HASH') ? $payload->{cwd} : undef;
    if (defined $cwd) {
        $cwd =~ s{\\}{/}g;
        utf8::encode($cwd) if utf8::is_utf8($cwd);
    }

    my $gate_armed   = _armed($sid, $root);
    my $thread_name  = _attached_thread($sid, $cwd, $root);
    my $gate = $gate_armed || defined $thread_name;

    my $nudge = _n5_nudge($sid, $home, $root, $gate_armed);
    my $printed = 0;
    $printed = _emit($n, $root, $gate, $nudge, $thread_name) if $gate || defined $nudge;
    _record_nudge($home, $sid, $nudge) if defined $nudge && $printed;

    _advance_watermark($tdir, $n);
    _delete_range($tdir, $n - 19, $n);
    return;
}

sub _first_nonempty {
    for my $v (@_) {
        return $v if defined $v && length $v;
    }
    return undef;
}

sub _plugin_root {
    my $self = $0;
    $self =~ s{\\}{/}g;
    (my $dir = $self) =~ s{/[^/]+\z}{};
    (my $root = $dir) =~ s{/hooks\z}{};
    return $root;
}

sub _read_watermark {
    my ($dir) = @_;
    if (open(my $fh, '<:raw', "$dir/.watermark")) {
        local $/;
        my $c = <$fh>;
        close $fh;
        return $1 + 0 if defined $c && $c =~ /\A(\d+)/;
    }
    return 0;
}

# _advance_watermark($dir, $n) -- write-if-greater, so two firing calls for
# two different batches racing on the same ".watermark" land correctly
# whichever order they run in (the higher $n always wins). Best-effort: a
# lost race here costs nothing this package's tests observe (R-4 only checks
# the final ticket count and which N values fired), and adding a lock would
# reintroduce exactly the flock sidecar Decision 28 removes.
sub _advance_watermark {
    my ($dir, $n) = @_;
    return unless -d $dir;
    return if _read_watermark($dir) >= $n;
    my $tmp = "$dir/.watermark.tmp.$$";
    if (open(my $fh, '>:raw', $tmp)) {
        print {$fh} "$n\n";
        close $fh;
        rename($tmp, "$dir/.watermark") or unlink($tmp);
    }
    return;
}

sub _delete_range {
    my ($dir, $from, $to) = @_;
    for my $i ($from .. $to) {
        unlink "$dir/$i";
    }
    return;
}

sub _armed {
    my ($sid, $root) = @_;
    my $loaded = eval { require "$root/../butler/scripts/BpHook.pm"; 1 };
    return 0 unless $loaded;
    my $armed = eval { BpHook::is_armed($sid) };
    return $armed ? 1 : 0;
}

sub _attached_thread {
    my ($sid, $cwd, $root) = @_;
    return undef unless defined $cwd && length $cwd;
    my $name = eval {
        local @INC = ("$root/scripts", @INC);
        require Almanac::Thread;
        Almanac::Thread::attached_thread(session => $sid, cwd => $cwd);
    };
    return undef if $@;
    return $name;
}

sub _emit {
    my ($n, $root, $gate, $nudge, $name) = @_;
    my $text;
    if ($gate) {
        if (defined $name) {
            $text = "Tool call $n in this session: chart your thread $name. Move your current steps through doing, blocked and done; add a task only for a new step of work.\n"
                   . "  perl $root/scripts/almanac-thread.pl show $name | add $name --title '<step>' | status $name <task> doing|blocked|done";
        }
        else {
            $text = "Tool call $n in this session: chart your thread. Move your current steps through doing, blocked and done; add a task only for a new step of work.\n"
                   . "  perl $root/scripts/almanac-thread.pl list | show <thread> | add <thread> --title '<step>' | status <thread> <task> doing|blocked|done";
        }
        $text .= "\n" . $nudge->{text} if ref $nudge eq 'HASH';
    }
    elsif (ref $nudge eq 'HASH') {
        $text = $nudge->{text};
    }
    else {
        return 0;
    }
    my %out = (hookSpecificOutput => { hookEventName => 'PostToolUse', additionalContext => $text });
    my $line = eval { require JSON::PP; JSON::PP->new->encode(\%out) };
    return 0 unless defined $line;
    binmode(STDOUT, ':raw');
    print STDOUT $line, "\n";
    return 1;
}

# _n5_nudge($sid, $home, $root, $gate_armed) -> {text=>..., epoch=>...} | undef
# never-halt package 11 (Decision 43, N5): one line suggesting arming when
# the session is unarmed, outside a butler run, not turned off by the
# operator, and the last operator prompt is at least CCPRAXIS_ARM_NUDGE_MIN
# minutes old (default 30), once per operator prompt (tracked by
# "$sid.nudged" alongside the existing ticket directory).
sub _n5_nudge {
    my ($sid, $home, $root, $gate_armed) = @_;
    return undef if $gate_armed;
    return undef if defined $ENV{BP_LEDGER} && length $ENV{BP_LEDGER};
    my $loaded = eval { require "$root/../butler/scripts/BpHook.pm"; 1 };
    return undef unless $loaded;
    my $off = eval { BpHook::operator_off($sid) };
    return undef if $off;

    my $e = eval { BpHook::last_prompt_epoch($sid) };
    return undef unless defined $e;

    my $min_env = $ENV{CCPRAXIS_ARM_NUDGE_MIN};
    my $min = (defined $min_env && $min_env =~ /\A[0-9]+\z/ && $min_env >= 1 && $min_env <= 1440)
        ? $min_env + 0 : 30;

    my $age = time() - $e;
    return undef unless $age >= $min * 60;

    my $r = _read_nudged($home, $sid);
    return undef if defined $r && $r == $e;

    my $mins = int($age / 60);
    my $text = "No operator message for $mins min and work continues. If this session should keep working without the operator, arm and attach a thread: butler-continuity on --new-thread <name> (or --thread <name> to resume one)";
    return { text => $text, epoch => $e };
}

sub _read_nudged {
    my ($home, $sid) = @_;
    my $path = "$home/.claude/almanac-state/chart-reminder/$sid.nudged";
    if (open(my $fh, '<:raw', $path)) {
        local $/;
        my $c = <$fh>;
        close $fh;
        return $1 + 0 if defined $c && $c =~ /\A([0-9]{1,12})\r?\n?\z/;
    }
    return undef;
}

sub _record_nudge {
    my ($home, $sid, $nudge) = @_;
    return unless ref $nudge eq 'HASH';
    my $dir = "$home/.claude/almanac-state/chart-reminder";
    return unless -d $dir;
    my $path = "$dir/$sid.nudged";
    my $tmp = "$path.tmp.$$";
    if (open(my $fh, '>:raw', $tmp)) {
        print {$fh} "$nudge->{epoch}\n";
        close $fh;
        rename($tmp, $path) or unlink($tmp);
    }
    return;
}
