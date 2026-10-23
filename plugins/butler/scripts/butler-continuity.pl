#!/usr/bin/env perl
# butler-continuity.pl -- the one command for Decision 1's arm and disarm
# triggers (package 04 of blueprint hook-continuity-remake).
#
#   butler-continuity on (--new-thread <name> | --thread <name>) [--role driver] --goal '<what this session is for>'
#   butler-continuity on      --role reporter [--goal '<...>']
#   butler-continuity off     [--reason '<2+ words>'] [--token <8 hex>]
#   butler-continuity off-confirm --otp <otp> --justification '<2+ words>'
#   butler-continuity emergency-stop --reason '<2+ words>' [--area <area>]
#   butler-continuity status
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 04-continuity-command-spec.md. Architecture: docs/hook-architecture.md
# ("BpHook core API", "Command binding: tickets and stop tokens").
#
# NO SESSION SELECTOR. This command never reads the caller's environment for
# a session identity; it learns its session only from a hook-written ticket
# (see BpHook::take_ticket) or, when a Stop denial minted one, a one-shot
# token passed with --token. Additive only (Decision 19): the old continuity
# CLI, the old registry and every live hook are untouched by this file.
use strict;
use warnings;
use FindBin qw($Bin);
use JSON::PP ();
use POSIX qw(strftime WNOHANG);
use Cwd ();

require "$Bin/BpHook.pm"
    unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
require "$Bin/BpContinuityLease.pm"
    unless grep { m{(?:^|/)BpContinuityLease\.pm$} } keys %INC;

my $USAGE = q{usage: butler-continuity on --new-thread <name> | on --thread <name> [--role driver] --goal '<what this session is for>' | on --role reporter [--goal '<...>'] | off [--reason '<why>'] [--token T] | off-confirm --otp <otp> --justification '<2+ words>' | emergency-stop --reason '<why>' [--area <area>] (only for a genuine defect in ccpraxis, Claude Code or another system that leaves no choice but to stop; never for finished work; files a bug report) | status};

# Shared by the blueprint Decision 9 silence refusal below and Step 2's "a coordinator
# cannot turn continuity off" check further down.
my $COORDINATOR_OFF_REFUSAL = "a coordinator cannot turn continuity off; it stops when its ledger is terminal.";

sub _bytes {
    my ($s) = @_;
    return '' unless defined $s;
    my $v = "$s";
    if (utf8::is_utf8($v)) { utf8::encode($v) }
    return $v;
}

sub out {
    my (@lines) = @_;
    binmode(STDOUT, ':raw');
    for my $l (@lines) { print STDOUT _bytes($l) }
}

sub refuse {
    my ($msg) = @_;
    binmode(STDERR, ':raw');
    print STDERR _bytes("butler-continuity: $msg") . "\n";
    exit 1;
}

sub usage_die {
    binmode(STDERR, ':raw');
    print STDERR "butler-continuity: $USAGE\n";
    exit 1;
}

sub iso_now { return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime()) }

sub word_count {
    my ($s) = @_;
    return 0 unless defined $s;
    my @w = grep { length } split /\s+/, $s;
    return scalar @w;
}

# sanitize_text($s) -- R4-L-reason (redteam LOW-2) / M1 (review). Strips C0/
# C1 control bytes, ANSI OSC/CSI escape sequences, and Unicode zero-width or
# other invisible ("format") characters; flattens any remaining newline,
# CR or tab run to a single space. Used both to validate a reason (so a
# reason that is invisible-only is refused, not silently accepted) and to
# sanitise what actually gets stored or printed, since BpHook::log_reason's
# own flatten only folds \t\r\n and status reads fields straight off disk
# (which a caller other than this command, e.g. BpHook::disarm called
# directly, can populate with anything).
sub sanitize_text {
    my ($raw) = @_;
    return '' unless defined $raw;
    my $s = $raw;
    # Decode only when $s is still raw bytes (utf8 flag off). Package 09
    # (Decision 108) also feeds this an ALREADY-decoded almanac record field
    # (a character string, flag on) -- calling utf8::decode on that would
    # flip the flag back off against the byte 0xE9 alone (not valid UTF-8 on
    # its own), corrupting it on the way to _bytes()'s encode.
    { local $@; eval { utf8::decode($s) } unless utf8::is_utf8($s) }    # best effort; raw bytes on failure
    $s =~ s/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?//g;   # OSC ... BEL|ST
    $s =~ s/\x1b\[[0-9;?]*[ -~]//g;                    # CSI ... final byte
    $s =~ s/[\r\n\t]+/ /g;
    $s =~ s/\p{Cc}//g;                                  # remaining C0/C1 controls
    $s =~ s/\p{Cf}//g;                                  # zero-width / invisible format chars
    $s =~ s/\s+/ /g;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

# visible_word_count($s) -- word count over sanitize_text($s), counting only
# runs of \p{L}/\p{N}. Stricter than word_count() above, so control/
# invisible-only reasons never pass.
sub visible_word_count {
    my ($s) = @_;
    return 0 unless defined $s;
    my $san = sanitize_text($s);
    my @w = ($san =~ /[\p{L}\p{N}]+/g);
    return scalar @w;
}

sub read_json_file {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return eval { JSON::PP->new->utf8->decode($c) };
}

# project_of($cwd) -- the parent directory of BpHook::data_dir({cwd=>$cwd}),
# or '-' when that is undef.
sub project_of {
    my ($cwd) = @_;
    return '-' unless defined $cwd && length $cwd;
    my $dd = BpHook::data_dir({ cwd => $cwd });
    return '-' unless defined $dd;
    (my $proj = $dd) =~ s{/\.ccpraxis-local-data/?$}{};
    return (defined $proj && length $proj) ? $proj : '-';
}

# plan_after_off($ldir) -- package 11: when an `off` removes the last live
# arm, restore the power plan synchronously instead of waiting up to one
# tick (60s) for the refresher, which may never come if it has already been
# signalled. Loaded lazily (this is the only verb that reaches
# BpPowerPlan), contained in an eval, and never changes stdout or the exit
# code -- only an optional single stderr warning line. Not gated on
# CCPRAXIS_NO_WAKELOCK: powercfg_argv already refuses the real binary under
# that variable, and gating here would make the call untestable through the
# subprocess seam.
sub plan_after_off {
    my ($ldir) = @_;
    my $o;
    my $ok = eval {
        require "$Bin/BpPowerPlan.pm" unless defined &BpPowerPlan::reconcile;
        $o = BpPowerPlan::reconcile($ldir, why => 'continuity-off', journal_noop => 1);
        1;
    };
    if (!$ok || (ref $o eq 'HASH' && defined $o->{outcome} && $o->{outcome} eq 'error')) {
        my $reason;
        if (ref $o eq 'HASH' && defined $o->{outcome} && $o->{outcome} eq 'error') {
            $reason = defined $o->{reason} ? $o->{reason} : 'error';
            my $detail = defined $o->{detail} ? $o->{detail} : '';
            $reason .= " $detail" if length $detail;
        }
        else {
            my $err = defined $@ && length $@ ? $@ : 'unknown error';
            $err =~ s/\r?\n.*$//s;
            $reason = $err;
        }
        binmode(STDERR, ':raw');
        print STDERR _bytes("butler-continuity: warning: power plan not restored ($reason).") . "\n";
    }
    return;
}

# thread_pl_path() -- blueprint where-things-go package 04 (spec sec 2.1): the
# <TP> used by the "on" chart-now hint, the "off" open-tasks listing and R13.
# Cwd::abs_path of almanac-thread.pl beside butler's own scripts dir,
# forward-slashed; undef when the almanac plugin is not installed beside this
# one (AC-16: a standalone copy of plugins/butler/scripts/).
sub thread_pl_path {
    my $p = Cwd::abs_path("$Bin/../../almanac/scripts/almanac-thread.pl");
    return undef unless defined $p && length $p;
    return undef unless -f $p;
    $p =~ s{\\}{/}g;
    return $p;
}

# _almanac_present() -- true iff Almanac::Thread.pm sits beside the almanac
# plugin's scripts dir, next to this one (spec sec 2.2).
sub _almanac_present {
    my $p = Cwd::abs_path("$Bin/../../almanac/scripts/Almanac/Thread.pm");
    return (defined $p && -f $p) ? 1 : 0;
}

# _load_thread() -- loads Almanac::Thread by MODULE NAME (never a path), via
# a temporary @INC entry, so %INC keeps the key 'Almanac/Thread.pm' and
# nothing is loaded twice (spec sec 2.2). Dies on failure; callers wrap it.
sub _load_thread {
    my $dir = "$Bin/../../almanac/scripts";
    local @INC = ($dir, @INC);
    require Almanac::Thread;
    return 1;
}

sub _err_first_line {
    my ($e) = @_;
    my $s = (defined $e && length("$e")) ? "$e" : 'unknown error';
    $s =~ s/\r?\n.*$//s;
    return $s;
}

sub lease_sync {
    return if $ENV{CCPRAXIS_NO_WAKELOCK};
    my $ldir = BpContinuityLease::legacy_dir();
    return unless defined $ldir;
    my $ok = eval { BpContinuityLease::converge($ldir); 1 };
    unless ($ok) {
        my $err = $@ || 'unknown error';
        $err =~ s/\r?\n.*$//s;
        binmode(STDERR, ':raw');
        print STDERR _bytes("butler-continuity: warning: wake-lock not updated ($err).") . "\n";
    }
}

# ---------------------------------------------------------------------------
# parse argv
# ---------------------------------------------------------------------------
my @argv0 = @ARGV;    # the untouched copy, ticket key material
my @args  = @ARGV;

my $verb = shift @args;

# Hard cutover (blueprint where-things-go, package 01-inbox-rename, Decision
# 2/6): a second front door onto the same store is retired, one line naming
# the replacement, before the verb whitelist, flag parsing, the coordinator
# step or the state-root step ever run -- no ticket consumed, no state dir
# touched.
my %RETIRED_VERBS = (
    ask       => 'almanac inbox file',
    questions => 'almanac inbox list',
    answer    => 'almanac inbox answer',
);
if (defined $verb && exists $RETIRED_VERBS{$verb}) {
    refuse("'butler-continuity $verb' is retired; use '$RETIRED_VERBS{$verb}' instead");
}

# Decision 9 (blueprint judged-continuity-disarm, package 05): silence is a
# second bypass of continuity's "file the question, keep working, never
# halt" guarantee, so it is removed outright, not narrowed. No flag parsing,
# no ticket or stop-token consumption, no state-dir access, no reasons.log
# line, for any argv beginning with silence -- this check runs before the
# verb whitelist, the coordinator step and the state-root step.
if (defined $verb && $verb eq 'silence') {
    refuse($COORDINATOR_OFF_REFUSAL) if defined $ENV{BP_LEDGER} && length $ENV{BP_LEDGER};
    refuse("'butler-continuity silence' is removed: an armed session does not end a turn to wait for the operator. "
        . "File the question with almanac inbox file --title '<question>' and keep working on everything that "
        . "does not depend on the answer; if nothing can proceed, turn continuity off with a reason. "
        . 'See "If you have a question for the operator" in plugins/butler/skills/continuity/SKILL.md.');
}

usage_die() unless defined $verb && $verb =~ /^(?:on|off|off-confirm|status|emergency-stop)$/;

my %allowed = (
    on           => { role => 1, 'new-thread' => 1, thread => 1, goal => 1 },
    off          => { reason => 1, token => 1 },
    'off-confirm' => { otp => 1, justification => 1 },
    status       => {},
    'emergency-stop' => { reason => 1, area => 1 },
);

my %flags;
while (@args) {
    my $a = shift @args;
    if ($a =~ /^--([A-Za-z][A-Za-z0-9_-]*)$/) {
        my $name = $1;
        usage_die() unless $allowed{$verb}{$name};
        usage_die() if exists $flags{$name};
        $flags{$name} = @args ? shift(@args) : undef;
    }
    else {
        usage_die();    # a stray positional word
    }
}

# ---------------------------------------------------------------------------
# Step 1: validation. Nothing is consumed or written.
# ---------------------------------------------------------------------------
if ($verb eq 'off' || $verb eq 'emergency-stop') {
    if (exists $flags{reason}) {
        if (!defined $flags{reason} || visible_word_count($flags{reason}) < 2) {
            refuse("--reason needs at least two words saying why.");
        }
    }
    elsif ($verb ne 'off') {   # emergency-stop requires --reason
        refuse("--reason needs at least two words saying why.");
    }
}

# NEW (off): --reason at most 200 UTF-8 bytes once sanitized (spec 2.3 step
# 1, R10), checked right after the existing two-word check. emergency-stop
# (judged-continuity-disarm pkg 06) shares the same shape.
my $EMERGENCY_STOP_AREA;
if (($verb eq 'off' || $verb eq 'emergency-stop') && exists $flags{reason} && defined $flags{reason}) {
    my $san = sanitize_text($flags{reason});
    utf8::encode($san) if utf8::is_utf8($san);
    if (length($san) > 200) {
        refuse("--reason is at most 200 bytes; it goes into the thread log.");
    }
}

# NEW (emergency-stop): --area, a short one-line area name (spec 2.2 d).
if ($verb eq 'emergency-stop' && exists $flags{area}) {
    my $a = defined $flags{area} ? sanitize_text($flags{area}) : '';
    my $a_bytes = $a;
    utf8::encode($a_bytes) if utf8::is_utf8($a_bytes);
    if (!length($a) || length($a_bytes) > 64 || $a =~ /^-/) {
        refuse("--area takes a short one-line area name, e.g. butler, sandbox or claude-code.");
    }
    $EMERGENCY_STOP_AREA = $a;
}

# NEW (off-confirm): --justification / --otp validation (spec 2.2.1).
# Nothing consumed. Order: justification word count, justification length,
# otp shape.
if ($verb eq 'off-confirm') {
    if (!exists $flags{justification} || !defined $flags{justification} || visible_word_count($flags{justification}) < 2) {
        refuse("--justification needs at least two words saying why the work is done.");
    }
    my $jsan = sanitize_text($flags{justification});
    utf8::encode($jsan) if utf8::is_utf8($jsan);
    if (length($jsan) > 200) {
        refuse("--justification is at most 200 bytes.");
    }
    if (!exists $flags{otp} || !defined $flags{otp} || $flags{otp} !~ /^[0-9a-f]{8}$/) {
        refuse("--otp takes the 8-character code printed by off.");
    }
}

if (exists $flags{token}) {
    if (!defined $flags{token} || $flags{token} !~ /^[0-9a-f]{8}$/) {
        refuse("--token takes the 8-character token from the stop message.");
    }
}

if (exists $flags{role}) {
    if (!defined $flags{role} || ($flags{role} ne 'driver' && $flags{role} ne 'reporter')) {
        refuse("--role takes driver or reporter.");
    }
}

# NEW (on): --new-thread/--thread validation that needs no session binding
# (spec 2.3 step 1, R2-R4).
if ($verb eq 'on') {
    if (exists $flags{'new-thread'} && exists $flags{thread}) {
        refuse("on takes --new-thread <name> or --thread <name>, not both.");
    }
    for my $fn (qw(new-thread thread)) {
        if (exists $flags{$fn} && !defined $flags{$fn}) {
            refuse("a thread name is 1-64 lowercase letters, digits and hyphens, starting with a letter or digit.");
        }
    }
    if (exists $flags{role} && $flags{role} eq 'reporter'
        && (exists $flags{'new-thread'} || exists $flags{thread})) {
        refuse("a reporter only reads threads; arm it with butler-continuity on --role reporter alone.");
    }
}

# ---------------------------------------------------------------------------
# Step 2: coordinator (Decision 25).
# ---------------------------------------------------------------------------
if (defined $ENV{BP_LEDGER} && length $ENV{BP_LEDGER}) {
    if ($verb eq 'off' || $verb eq 'off-confirm') {
        refuse($COORDINATOR_OFF_REFUSAL);
    }
    if ($verb eq 'on') {
        out("continuity is on by construction for a coordinator; nothing to do.\n");
        exit 0;
    }
    # status runs normally. emergency-stop (Decision 21) is deliberately NOT
    # in the refusal list above: it falls through like status, so a
    # coordinator session can still file a bug report and record it, just
    # without turning continuity off (its own verb handler below never calls
    # disarm for a coordinator).
}

# ---------------------------------------------------------------------------
# Step 2b: thread argument rule (NEW, on only; still nothing consumed).
# ---------------------------------------------------------------------------
my ($ALMANAC_PRESENT, $ON_THREAD_MODE, $ON_THREAD_NAME, $ON_ALMANAC_ABSENT_WARN) = (0, undef, undef, 0);
if ($verb eq 'on') {
    $ALMANAC_PRESENT = _almanac_present();
    my $role = $flags{role} // 'manual';
    if (exists $flags{'new-thread'}) { $ON_THREAD_MODE = 'new';    $ON_THREAD_NAME = $flags{'new-thread'} }
    elsif (exists $flags{thread})    { $ON_THREAD_MODE = 'resume'; $ON_THREAD_NAME = $flags{thread} }

    if ($ALMANAC_PRESENT) {
        my $loaded = eval { _load_thread(); 1 };
        unless ($loaded) {
            refuse("could not load the almanac thread library (" . _err_first_line($@) . ").");
        }
        if (defined $ON_THREAD_MODE && !Almanac::Thread::valid_name($ON_THREAD_NAME)) {
            refuse("a thread name is 1-64 lowercase letters, digits and hyphens, starting with a letter or digit.");
        }
        if (!defined $ON_THREAD_MODE && $role ne 'reporter') {
            refuse("on needs a thread: butler-continuity on --new-thread <name> starts one; "
                . "butler-continuity on --thread <name> resumes a handed-off one or takes over one whose owner is dead.");
        }
    }
    else {
        $ON_ALMANAC_ABSENT_WARN = 1 if defined $ON_THREAD_MODE;
    }
}

# Step 2c: --goal (on only; blueprint judged-continuity-disarm pkg 01,
# Decisions 5/17). After the coordinator exit and the thread rule; still
# nothing consumed.
my $ON_GOAL;    # sanitized goal text, or undef when no --goal was given
if ($verb eq 'on') {
    my $role = $flags{role} // 'manual';
    if (!exists $flags{goal}) {
        refuse("on needs --goal '<what this session is for>': it is stored with the arm so a later stop can be checked against it. If the operator asked for this session to be armed, paraphrase their request; if you are arming on your own initiative, state your own rationale.") if $role ne 'reporter';
    }
    else {
        if (!defined $flags{goal} || visible_word_count($flags{goal}) < 2) {
            refuse("--goal needs at least two words saying what this session is for.");
        }
        my $san = sanitize_text($flags{goal});
        my $goal_bytes = $san;
        utf8::encode($goal_bytes) if utf8::is_utf8($goal_bytes);
        if (length($goal_bytes) > 200) {
            refuse("--goal is at most 200 bytes; it goes into the arm record.");
        }
        $ON_GOAL = $san;
    }
}

# ---------------------------------------------------------------------------
# Step 3: state root.
# ---------------------------------------------------------------------------
my $ROOT = BpHook::state_dir();
unless (defined $ROOT) {
    refuse("no continuity state directory (set HOME, or an absolute BUTLER_STATE_DIR).");
}

# ---------------------------------------------------------------------------
# Step 4: binding (on, off, off-confirm, status, emergency-stop).
# ---------------------------------------------------------------------------
my ($SID, $AID, $OPERATOR_TICKET, $PROJECT, $TRANSCRIPT_PATH, $TICKET_CWD);

if ($verb eq 'on' || $verb eq 'off' || $verb eq 'off-confirm' || $verb eq 'status'
    || $verb eq 'emergency-stop') {
    my $t = BpHook::take_ticket('butler-continuity', \@argv0);

    if (ref $t eq 'HASH') {
        $SID              = $t->{session_id};
        $AID              = $t->{agent_id};
        $OPERATOR_TICKET  = (JSON::PP::is_bool($t->{operator}) && $t->{operator}) ? 1 : 0;
        $TRANSCRIPT_PATH  = $t->{transcript_path};
        $PROJECT          = project_of($t->{cwd});
        $TICKET_CWD       = (defined $t->{cwd} && length $t->{cwd}) ? $t->{cwd} : undef;

        if (exists $flags{token} && defined $flags{token}) {
            my $s2 = BpHook::take_stop_token($flags{token});    # always consumed when given
            if (defined $s2 && $s2 ne $SID) {
                refuse("the --token belongs to another session.");
            }
        }
    }
    elsif (exists $flags{token} && defined $flags{token} && $verb eq 'off') {
        my $s2 = BpHook::take_stop_token($flags{token});
        if (defined $s2) {
            $SID             = $s2;
            $AID             = undef;
            $OPERATOR_TICKET = 0;
            $PROJECT         = '-';
        }
        else {
            _refuse_binding();
        }
    }
    else {
        _refuse_binding();
    }

    if (($verb eq 'on' || $verb eq 'off' || $verb eq 'off-confirm' || $verb eq 'emergency-stop')
        && defined $AID) {
        refuse("only the main session changes continuity; a subagent may not.");
    }
}

sub _refuse_binding {
    if ($verb eq 'on') {
        refuse("no session binding for on; run it again as a plain Bash tool call.");
    }
    elsif ($verb eq 'status') {
        refuse("no session binding for status; run it again as a plain Bash tool call.");
    }
    elsif ($verb eq 'off-confirm' || $verb eq 'emergency-stop') {
        refuse("no session binding; run it again as a plain Bash tool call with arguments in single quotes.");
    }
    else {
        refuse("no session binding; use the --token from the stop message, or quote arguments in single quotes.");
    }
}

# ---------------------------------------------------------------------------
# Step 5: verbs.
# ---------------------------------------------------------------------------
my $S8 = defined $SID ? substr($SID, 0, 8) : '?';

# ---------------------------------------------------------------------------
# Thread helpers that close over $SID/$TICKET_CWD/$TRANSCRIPT_PATH/$S8/
# $ON_ALMANAC_ABSENT_WARN -- must sit after those are bound (Step 4) above.
# ---------------------------------------------------------------------------

# _thread_opts() -- every Almanac::Thread call passes cwd => $TICKET_CWD when
# defined and non-empty, else nothing (Store's own root resolution, spec
# 2.2).
sub _thread_opts {
    my %o;
    $o{cwd} = $TICKET_CWD if defined $TICKET_CWD && length $TICKET_CWD;
    return %o;
}

# _find_attached_thread(%O) -- like Almanac::Thread::attached_thread, but
# DIES on a store error instead of swallowing it into undef (Decision 38 S1).
# attached_thread() wraps its whole body in eval and always returns undef on
# any failure, so a single malformed thread record anywhere in the project
# makes it indistinguishable from "this session has no thread". list_threads()
# does not swallow: Store::list() dies on a malformed record. Mirror
# attached_thread()'s own live/session/owner filter on top of that so callers
# can tell "no thread" (clean return, possibly undef) from "could not tell"
# (die) and react differently.
sub _find_attached_thread {
    my (%O) = @_;
    my $list = Almanac::Thread::list_threads(%O, archived => 0);
    my @names;
    for my $h (@$list) {
        next unless defined($h->{state}) && $h->{state} eq 'live'
                 && defined($h->{owner_kind}) && $h->{owner_kind} eq 'session'
                 && defined($h->{owner_id}) && $h->{owner_id} eq $SID;
        push @names, $h->{name};
    }
    return undef unless @names;
    @names = sort @names;
    return $names[0];
}

# _err_paren($e) -- "<kind>[: <detail>]" for R12-shaped messages.
sub _err_paren {
    my ($e) = @_;
    my $kind   = (ref $e && defined $e->{kind}) ? $e->{kind} : 'error';
    my $detail = (ref $e && defined $e->{detail} && length $e->{detail}) ? $e->{detail} : undef;
    return defined $detail ? "$kind: $detail" : $kind;
}

sub _r8_refuse {
    my ($y) = @_;
    $y = '?' unless defined $y;
    refuse("this session is already attached to thread $y; re-arm on it with butler-continuity on --thread $y, or hand it off first with butler-continuity off --reason '<why>'");
}

# _attach_refuse($name, $e) -- translates an Almanac::Thread::attach() die
# into the matching refusal (R7, R8, R9, R11, else R12). Never returns.
sub _attach_refuse {
    my ($name, $e) = @_;
    my $kind = ref($e) ? $e->{kind} : '';
    if ($kind eq 'not_found') {
        refuse("no thread $name in this project; start it with butler-continuity on --new-thread $name");
    }
    my $detail = ref($e) ? $e->{detail} : undef;
    my $cause  = ref($e) ? $e->{cause}  : undef;
    if (defined $detail && $detail eq 'thread_archived') {
        refuse("thread $name is archived; start a new one with butler-continuity on --new-thread <name>");
    }
    if (defined $detail && $detail eq 'already_attached') {
        _r8_refuse($cause);
    }
    if (defined $detail && $detail eq 'owner_live') {
        my $c = defined $cause ? $cause : '?';
        refuse("thread $name belongs to $c, which is still live; it cannot be taken over until its owner hands it off or goes idle.");
    }
    refuse("could not attach thread $name (" . _err_paren($e) . ").");
}

# _on_new_thread($name) -- spec 2.4.1.
sub _on_new_thread {
    my ($name) = @_;
    my %O = _thread_opts();
    my $mine = eval { _find_attached_thread(%O) };
    if (my $e = $@) {
        # Decision 38 S1: the store could not be listed, so we cannot confirm
        # this session has no existing attachment. Refuse rather than risk a
        # second live attachment for the same session (the one-thread-per-
        # session invariant attached_thread()'s own swallow-to-undef broke).
        refuse("could not attach thread $name (" . _err_paren($e) . ").");
    }
    _r8_refuse($mine) if defined $mine;

    my $existing = eval { Almanac::Thread::read_thread($name, %O) };
    if (my $e = $@) {
        unless (ref($e) && $e->{kind} eq 'not_found') {
            refuse("could not attach thread $name (" . _err_paren($e) . ").");
        }
    }
    else {
        if (defined $existing->{state} && $existing->{state} eq 'archived') {
            refuse("thread $name is archived; start a new one with butler-continuity on --new-thread <name>");
        }
        refuse("thread $name already exists; resume it with butler-continuity on --thread $name");
    }

    my %cargs = (owner_kind => 'session', owner_id => $SID, actor => 'session', session => $SID, %O);
    $cargs{owner_transcript} = $TRANSCRIPT_PATH if defined $TRANSCRIPT_PATH && length $TRANSCRIPT_PATH;
    my $th = eval { Almanac::Thread::create_thread($name, %cargs) };
    if (my $e = $@) {
        if (ref($e) && $e->{kind} eq 'exists') {
            refuse("thread $name already exists; resume it with butler-continuity on --thread $name");
        }
        refuse("could not attach thread $name (" . _err_paren($e) . ").");
    }
    if ($th->{owner_kind} ne 'session' || $th->{owner_id} ne $SID) {
        my $y = Almanac::Thread::attached_thread(session => $SID, %O);
        _r8_refuse($y);
    }
    return { name => $name, mode => 'created' };
}

# _try_attach($name, %aargs) -- (1, $th, $changed) on success, (0, $e) on a
# die (the error object).
sub _try_attach {
    my ($name, %aargs) = @_;
    my ($th, $changed) = eval { Almanac::Thread::attach($name, %aargs) };
    return (1, $th, $changed) unless $@;
    return (0, $@);
}

# _on_resume_thread($name) -- spec 2.4.2.
sub _on_resume_thread {
    my ($name) = @_;
    my %O = _thread_opts();
    my %aargs = (session => $SID, actor => 'session', %O);
    $aargs{transcript} = $TRANSCRIPT_PATH if defined $TRANSCRIPT_PATH && length $TRANSCRIPT_PATH;

    my ($ok, $th, $changed) = _try_attach($name, %aargs);
    my $from;
    unless ($ok) {
        my $e = $th;
        my $detail = ref($e) ? $e->{detail} : undef;
        _attach_refuse($name, $e) unless defined $detail && $detail eq 'owner_dead';
        $from = ref($e) ? $e->{cause} : undef;

        my ($th2, $ch2) = eval { Almanac::Thread::take_over($name, %aargs, reason => 'previous owner is no longer live') };
        if (my $e2 = $@) {
            my $d2 = ref($e2) ? $e2->{detail} : undef;
            if (defined $d2 && $d2 eq 'not_owned') {
                my ($ok3, $th3) = _try_attach($name, %aargs);
                if ($ok3) {
                    ($th, $changed, $from) = ($th3, 1, undef);
                }
                else {
                    my $e3 = $th3;
                    my $d3 = ref($e3) ? $e3->{detail} : undef;
                    if (defined $d3 && $d3 eq 'owner_dead') {
                        refuse("could not attach thread $name (refused: not_owned).");
                    }
                    _attach_refuse($name, $e3);
                }
            }
            else {
                _attach_refuse($name, $e2);
            }
        }
        else {
            ($th, $changed) = ($th2, 1);
        }
    }

    refuse("thread $name is archived; start a new one with butler-continuity on --new-thread <name>")
        if defined $th->{state} && $th->{state} eq 'archived';
    my $mode = defined $from ? 'taken-over' : ($changed ? 'resumed' : 'already');
    return { name => $name, mode => $mode, from => $from };
}

sub _on_thread {
    my ($mode, $name) = @_;
    return $mode eq 'new' ? _on_new_thread($name) : _on_resume_thread($name);
}

sub _on_output {
    my ($role, $th) = @_;
    unless (defined $th) {
        out("continuity on for session $S8 (role $role).\n");
        if ($ON_ALMANAC_ABSENT_WARN) {
            binmode(STDERR, ':raw');
            print STDERR "butler-continuity: warning: almanac is not installed beside butler; armed without a thread.\n";
        }
        return;
    }
    my $name = $th->{name};
    out("continuity on for session $S8 (role $role, thread $name).\n");
    my %LINE = (
        created      => "Thread $name created and attached to this session.\n",
        resumed      => "Thread $name resumed.\n",
        already      => "Thread $name is already attached to this session.\n",
        'taken-over' => "Thread $name taken over from " . (defined $th->{from} ? $th->{from} : '?') . "; its owner is no longer live.\n",
    );
    out($LINE{ $th->{mode} });
    out("Chart thread $name now: add a task for each step still ahead and mark the current one doing.\n");
    my $TP = thread_pl_path();
    out("  perl \"$TP\" show $name | add $name --title '<step>' | status $name <id> doing|blocked|done\n") if defined $TP;
    return;
}

# _r13_title($title) -- R13's own truncation rule (spec 2.7: 60 chars).
sub _r13_title {
    my ($t) = @_;
    my $s = sanitize_text($t);
    $s = substr($s, 0, 57) . '...' if length($s) > 60;
    return $s;
}

# _off_doing_gate() -- spec 2.5 step 1. Returns ($T, $broken): $T is the
# attached thread name or undef; $broken is 0 when nothing went wrong, 1 when
# the thread library failed to load, and 2 when the library loaded but the
# thread store could not be listed (Decision 38 S1 -- a genuine store error,
# distinct from "this session has no thread"). Steps 1 and 4 are both skipped
# for either non-zero $broken; the caller prints a warning for each case.
# Refuses R13 directly (exits) when an unlinked task is doing.
# _disarm_thread() -> ($T, $broken): the attached thread and the library/store
# status, with NO doing-task check. Same ($T, $broken) contract as _off_doing_gate.
sub _disarm_thread {
    return (undef, 0) unless _almanac_present();
    return (undef, 1) unless eval { _load_thread(); 1 };
    my %O = _thread_opts();
    my $T = eval { _find_attached_thread(%O) };
    return (undef, 2) if $@;
    return ($T, 0);
}

sub _off_doing_gate {
    my ($T, $broken) = _disarm_thread();
    return ($T, $broken) if $broken || !defined $T;
    my %O = _thread_opts();
    my $list = eval { Almanac::Thread::tasks($T, %O) };
    my @tasks = (!$@ && ref $list eq 'ARRAY') ? @$list : ();
    my @doing = grep { !$_->{linked} && defined $_->{status} && $_->{status} eq 'doing' } @tasks;
    if (@doing) {
        my $TP = thread_pl_path();
        # Decision 38 M1: $TP is raw bytes from Cwd::abs_path; $names below is
        # built through _r13_title -> sanitize_text, which returns a decoded
        # (UTF8-flagged) Perl string even for pure-ASCII content. Concatenating
        # flagged text with raw high-bit bytes in one string upgrades the raw
        # bytes by reinterpreting each one as its own Latin-1 codepoint, which
        # refuse()'s final _bytes()/utf8::encode() then double-encodes -- same
        # bug class as _status_thread_line's fix above. Decode a copy of $TP so
        # the whole message stays in one (decoded) representation until the
        # _bytes() boundary.
        my $TPd = $TP;
        utf8::decode($TPd) if defined $TPd;
        my $tail = defined $TPd ? "perl \"$TPd\" status $T $doing[0]{id} done|pending|blocked"
                                 : "almanac thread status $T $doing[0]{id} done|pending|blocked";
        my $names = join('; ', map { "$_->{id} " . _r13_title($_->{title}) } @doing);
        refuse("off refused: thread $T still has a task doing: $names. Set each one done, pending or blocked first ($tail), then run off again.");
    }
    return ($T, 0);
}

# _off_open_tasks($T) -- spec 2.5 step 5 (replaces the retired
# _print_n7_off / almanac-task.pl listing).
sub _off_open_tasks {
    my ($T) = @_;
    my %O = _thread_opts();
    my $list = eval { Almanac::Thread::tasks($T, %O) };
    return if $@ || ref $list ne 'ARRAY';
    my %OPEN = (pending => 1, blocked => 1);
    my @open = grep { !$_->{linked} && defined $_->{status} && $OPEN{ $_->{status} } } @$list;
    return unless @open;
    out("Still open in thread $T; chart any that are stale now:\n");
    my $shown = 0;
    for my $t (@open) {
        last if $shown >= 10;
        my $title = sanitize_text($t->{title});
        $title = substr($title, 0, 77) . '...' if length($title) > 80;
        out("  $t->{id} $t->{status} $title\n");
        $shown++;
    }
    if (@open > 10) {
        out('  ... and ' . (scalar(@open) - 10) . " more\n");
    }
    my $TP = thread_pl_path();
    out("  perl \"$TP\" status $T <id> pending|blocked|done|obsoleted\n") if defined $TP;
    return;
}

# _off_hand_off($T, $reason) -- spec 2.5 step 4. Does nothing when $T is
# undef. A hand-off failure degrades to a warning only (exit code untouched).
sub _off_hand_off {
    my ($T, $reason) = @_;
    return unless defined $T;
    my %O = _thread_opts();
    my $th = eval {
        Almanac::Thread::record_event($T, 'handed-off', session => $SID, actor => 'session',
            reason => $reason, require_owner_session => $SID,
            # Re-checked under the thread lock: off's own doing-task refusal
            # runs unlocked, so a task set doing in between would otherwise
            # be handed off mid-work (pkg04 review S3).
            require_no_doing => 1, %O);
    };
    if (my $e = $@) {
        binmode(STDERR, ':raw');
        print STDERR _bytes("butler-continuity: warning: thread $T was not handed off (" . _err_paren($e) . ").") . "\n";
        return;
    }
    if (defined $th->{state} && $th->{state} eq 'archived') {
        out("Thread $T handed off and archived: all its tasks are done.\n");
        return;
    }
    out("Thread $T handed off; the reason is in its log.\n");
    _off_open_tasks($T);
    return;
}

# _is_doing_task($t) -- status's own "doing" predicate (spec 2.6): unlinked
# status doing, or linked status running/converging/reviewing.
sub _is_doing_task {
    my ($t) = @_;
    return 0 unless ref $t eq 'HASH';
    if ($t->{linked}) {
        return (defined $t->{status}
            && ($t->{status} eq 'running' || $t->{status} eq 'converging' || $t->{status} eq 'reviewing')) ? 1 : 0;
    }
    return (defined $t->{status} && $t->{status} eq 'doing') ? 1 : 0;
}

sub _task_label {
    my ($t) = @_;
    if ($t->{linked}) {
        return defined $t->{link} ? $t->{link} : '?';
    }
    my $s = sanitize_text($t->{title});
    $s = substr($s, 0, 37) . '...' if length($s) > 40;
    return $s;
}

# _status_thread_line() -- spec 2.6.
sub _status_thread_line {
    return 'thread: unknown' unless _almanac_present();
    my $loaded = eval { _load_thread(); 1 };
    return 'thread: unknown' unless $loaded;
    my %O = _thread_opts();
    # Decision 38 S1: attached_thread() never dies (it wraps its whole body in
    # eval and maps any store error to undef), so the die-check below used to
    # be dead code and a genuine store error printed "thread: none" instead of
    # "thread: unknown". _find_attached_thread() surfaces the die.
    my $T = eval { _find_attached_thread(%O) };
    return 'thread: unknown' if $@;
    return 'thread: none' unless defined $T;
    my $tasks = eval { Almanac::Thread::tasks($T, %O) };
    return 'thread: unknown' if $@;
    my @t = (ref $tasks eq 'ARRAY') ? @$tasks : ();
    my $n = scalar @t;
    my $d = scalar grep { Almanac::Thread::is_done_task($_) } @t;
    my $f = $n ? int($d * 10 / $n) : 0;
    my $FULL  = "\xe2\x96\xb0";
    my $EMPTY = "\xe2\x96\xb1";
    # Decode these raw UTF-8 bytes to proper (UTF8-flagged) characters before
    # interpolating them with $T/$doing_label/$next_label below -- those
    # already come back UTF8-flagged from Almanac::Thread (via Encode::decode,
    # see sanitize_text()'s comment above) even for pure-ASCII content.
    # Concatenating a flagged operand with flag-off high-bit bytes upgrades
    # the raw bytes by reinterpreting each one as its own Latin-1 codepoint,
    # which out()'s final utf8::encode() then double-encodes.
    utf8::decode($FULL);
    utf8::decode($EMPTY);
    my $bar = ($FULL x $f) . ($EMPTY x (10 - $f));
    my @doing     = grep { _is_doing_task($_) } @t;
    my @nextable  = grep { defined $_->{status} && $_->{status} eq 'pending' } @t;
    my $doing_label = @doing
        ? _task_label($doing[0]) . (@doing > 1 ? ' (+' . (scalar(@doing) - 1) . ')' : '')
        : '-';
    my $next_label = @nextable ? _task_label($nextable[0]) : '-';
    return "thread: $T $bar $d/$n  doing: $doing_label  next: $next_label";
}

if ($verb eq 'on') {
    my $role = $flags{role} // 'manual';
    my $th = ($ALMANAC_PRESENT && defined $ON_THREAD_MODE) ? _on_thread($ON_THREAD_MODE, $ON_THREAD_NAME) : undef;
    my $ok = BpHook::arm($SID, role => $role, by => 'on', transcript_path => $TRANSCRIPT_PATH, goal => $ON_GOAL);
    unless ($ok) {
        refuse("could not write continuity state (" . (BpHook::last_error() // '') . ").");
    }
    _on_output($role, $th);
    lease_sync();
    exit 0;
}

# _complete_disarm($actor, $reason, $T, $broken) -- spec 2.2.2/2.2.3: today's
# :843-876 disarm/hand-off/lease/plan logic, factored into one sub shared by
# the operator `off` path and the new `off-confirm` path, so they cannot
# drift (spec sec 2.2.3's explicit recommendation). Never returns a value the
# caller needs; callers exit 0 themselves right after calling it.
sub _complete_disarm {
    my ($actor, $reason, $T, $broken, %o) = @_;
    my $tag    = $o{tag}    // 'off';
    my $logged_text = $o{logged} // $reason;
    my $log_text = $o{log} // $logged_text;
    my $was_armed = BpHook::is_armed($SID);
    my $plan_ldir   = BpContinuityLease::legacy_dir();
    my $live_before = defined $plan_ldir ? (BpContinuityLease::any_active($plan_ldir) ? 1 : 0) : 0;
    my $ok = BpHook::disarm($SID, actor => $actor, reason => $logged_text);
    unless ($ok) {
        refuse("could not write continuity state (" . (BpHook::last_error() // '') . ").");
    }
    my $logged = BpHook::log_reason($SID, $actor, $tag, $log_text, $PROJECT);

    my $note = $was_armed ? '' : '; was not armed';
    out("continuity off for session $S8 (actor $actor$note); reason logged.\n");
    if ($broken && $broken == 1) {
        binmode(STDERR, ':raw');
        print STDERR "butler-continuity: warning: the almanac thread library did not load; no thread was handed off.\n";
    }
    elsif ($broken && $broken == 2) {
        # Decision 38 S1: the store could not be listed, so we cannot confirm
        # whether a thread is attached. Fail loud rather than silently
        # disarming with no hand-off and no signal (the never-trap design is
        # kept: the session still disarms; only the hand-off is skipped).
        binmode(STDERR, ':raw');
        print STDERR "butler-continuity: warning: the thread store could not be read; no thread was handed off.\n";
    }
    else {
        _off_hand_off($T, $reason);
    }
    unless ($logged) {
        binmode(STDERR, ':raw');
        print STDERR "butler-continuity: warning: reason log not written.\n";
    }
    lease_sync();
    plan_after_off($plan_ldir)
        if $live_before && defined $plan_ldir && !BpContinuityLease::any_active($plan_ldir);
    return;
}

# _stored_goal() -- the sanitized goal recorded at $ROOT/armed/$SID, or
# '(no goal recorded)' when absent (extracted from `off`'s old inline block,
# judged-continuity-disarm pkg 03 E2, so `off-confirm`'s judge dispatch can
# read the same goal `off` already shows the caller).
sub _stored_goal {
    my $goal = '';
    my $d = read_json_file("$ROOT/armed/$SID");
    $goal = (ref $d eq 'HASH' && defined $d->{goal} && !ref $d->{goal}) ? sanitize_text($d->{goal}) : '';
    $goal = '(no goal recorded)' unless length $goal;
    return $goal;
}

if ($verb eq 'off') {
    my $actor = $OPERATOR_TICKET ? 'operator' : 'agent';
    my $reason;
    if (exists $flags{reason}) {
        $reason = sanitize_text($flags{reason});
    }
    elsif ($actor eq 'operator') {
        $reason = '(operator)';
    }
    else {
        refuse("off needs --reason '<why>' unless the operator typed /butler:continuity off.");
    }

    my ($T, $broken) = _off_doing_gate();

    if ($actor eq 'operator') {
        # Decision 4: the operator path is unchanged -- disarms in one call,
        # never mints, never prints an OTP.
        _complete_disarm($actor, $reason, $T, $broken);
        exit 0;
    }

    # Agent actor (judged-continuity-disarm pkg 02, spec sec 2.2.2): mint a
    # single-use disarm OTP carrying the sanitized reason and the gate
    # result, and refuse. The caller runs off-confirm to actually disarm.
    my $otp = BpHook::mint_disarm_otp($SID, reason => $reason, gate_result => { thread => $T, broken => $broken });
    refuse("could not mint a disarm code (" . (BpHook::last_error() // '') . ").") unless defined $otp;

    my $goal = _stored_goal();

    binmode(STDERR, ':raw');
    print STDERR _bytes(join('',
        "butler-continuity: off not done yet: disarming takes two steps, and continuity is unchanged for session $S8.\n",
        "Disarm is right only when the goal below is met, or this session can no longer advance it (every remaining step needs the operator or is blocked) and no actionable work is left.\n",
        "It is NOT right for: waiting on an operator answer (file the question and keep working), pausing between steps, or stopping after one slice while more remains.\n",
        "goal: $goal\n",
        "reason: $reason\n",
        "To disarm, run this within 15 minutes:\n", "  butler-continuity off-confirm --otp $otp --justification '<how the goal is met, or why this session cannot advance it>'\n"));
    exit 1;
}

if ($verb eq 'off-confirm') {
    my ($rec, $code) = BpHook::take_disarm_otp($flags{otp}, $SID);
    unless ($rec) {
        my %MSG = (
            'no-live-otp'     => "no disarm code is live for this session; run butler-continuity off --reason '<why>' first.",
            'unknown'         => "that code is not live (wrong, already used, or replaced by a later off); run off again for a fresh one.",
            'superseded'      => "that code is not live (replaced by a later off); run off again for a fresh one.",
            'foreign-session' => "that code belongs to another session.",
            'expired'         => "that code expired (15 minutes); run off again for a fresh one.",
        );
        my $msg = $MSG{ defined $code ? $code : '' };
        $msg = "could not claim the code (" . (defined $code ? $code : 'unknown') . ")." unless defined $msg;
        refuse($msg);
    }

    my $actor  = 'agent';    # off-confirm has no operator path.
    my $reason = sanitize_text($rec->{reason});
    my $T      = (ref $rec->{gate_result} eq 'HASH') ? $rec->{gate_result}{thread} : undef;
    my $broken = (ref $rec->{gate_result} eq 'HASH') ? $rec->{gate_result}{broken} : 0;
    if (!$broken && defined $T) {
        # The gate was not re-run (Decision 18): load the thread lib here so
        # a library that failed to load between off and off-confirm still
        # degrades to the existing warning rather than a wrong hand-off.
        $broken = 1 unless _almanac_present() && eval { _load_thread(); 1 };
    }
    my $just = sanitize_text($flags{justification});
    my $goal = _stored_goal();
    my $v = _judge_disarm($flags{otp}, $goal, $reason, $just);    # hashref or undef
    unless ($v) {
        refuse("judge did not return a verdict; continuity is still on (details: $ROOT/disarm-judge/$flags{otp}.wrapper.log). "
             . "Run butler-continuity off --reason '<why>' again for a fresh code to retry.");
    }
    if ($v->{verdict} eq 'reject') {
        refuse("disarm rejected by the judge: " . sanitize_text($v->{reason})
             . " -- continuity is still on. The code is used up; run butler-continuity off --reason '<why>' again for a fresh one.");
    }
    _complete_disarm($actor, $reason, $T, $broken, log => _judged_log_text($reason, $goal, $just, $flags{otp}));
    exit 0;
}

# _judge_disarm($otp, $goal, $reason, $just) -- judged-continuity-disarm pkg
# 03 E4. Forks bp-judge-disarm.sh (no shell involved: exec with an argv
# array), waits for its OTP-keyed verdict file up to T+5s, hard-kills the
# wrapper itself if it overruns that bound, and returns the decoded verdict
# hashref (only when its `otp` field matches), or undef on any failure
# (missing/invalid verdict, fork failure, or deadline exceeded).
sub _judge_disarm {
    my ($otp, $goal, $reason, $just) = @_;
    return undef unless defined $otp && length $otp;

    # T (sec 2.1): same validation as the wrapper applies to its own copy of
    # this var, so the two processes always agree.
    my $traw = $ENV{CCPRAXIS_DISARM_JUDGE_TIMEOUT_SECONDS};
    my $T = 90;
    if (defined $traw && $traw =~ /^[0-9]+$/ && $traw >= 1 && $traw <= 90) {
        $T = $traw + 0;
    }

    my $dir = "$ROOT/disarm-judge";
    eval { require File::Path; File::Path::make_path($dir) };
    my $vpath = "$dir/$otp.verdict.json";
    unlink $vpath;    # clear before dispatch (DC8 stale-same-path defense).

    my $proot = ($PROJECT ne '-') ? $PROJECT
              : (defined $TICKET_CWD && length $TICKET_CWD) ? $TICKET_CWD
              : Cwd::getcwd();

    my $pid = fork();
    return undef unless defined $pid;

    if ($pid == 0) {
        open(STDIN, '<', '/dev/null') or POSIX::_exit(127);
        my $log = "$dir/$otp.wrapper.log";
        open(STDOUT, '>', $log) or POSIX::_exit(127);
        open(STDERR, '>>', $log) or POSIX::_exit(127);
        exec('bash', "$Bin/bp-judge-disarm.sh", $otp, $vpath, $proot, $goal, $reason, $just)
            or POSIX::_exit(127);
    }

    my $deadline = time() + $T + 5;
    my $wrapper_done = 0;
    while (1) {
        if (-e $vpath) { last }
        my $w = waitpid($pid, POSIX::WNOHANG());
        if (defined $w && $w == $pid) { $wrapper_done = 1; last }
        if (time() >= $deadline) {
            kill('TERM', $pid);
            select(undef, undef, undef, 0.2);
            kill('KILL', $pid);
            waitpid($pid, 0);
            $wrapper_done = 1;
            last;
        }
        select(undef, undef, undef, 0.1);
    }

    unless ($wrapper_done) {
        # The verdict file appeared before the wrapper exited: still reap it,
        # bounded, so we never leave a zombie behind.
        my $reap_deadline = time() + 2;
        while (time() < $reap_deadline) {
            my $w = waitpid($pid, POSIX::WNOHANG());
            last if defined $w && $w == $pid;
            select(undef, undef, undef, 0.1);
        }
        unless ((waitpid($pid, POSIX::WNOHANG()))[0]) {
            kill('TERM', $pid);
            select(undef, undef, undef, 0.2);
            kill('KILL', $pid);
            waitpid($pid, 0);
        }
    }

    my $d = read_json_file($vpath);
    return undef unless ref $d eq 'HASH';
    return undef unless defined $d->{otp} && $d->{otp} eq $otp;
    return undef unless defined $d->{verdict} && ($d->{verdict} eq 'approve' || $d->{verdict} eq 'reject');
    return undef unless defined $d->{reason} && !ref $d->{reason} && length $d->{reason};
    return $d;
}

# _judged_log_text($reason, $goal, $just, $otp) -- judged-continuity-disarm
# pkg 03 E5. Each of reason/goal/just is cut to at most 70 characters
# (substr(...,0,67).'...' when longer), so the combined text -- at most 280
# characters -- always fits inside BpHook::log_reason's 300-character cut
# without dropping a component (DC2). The pointer is relative to $ROOT, the
# directory reasons.log itself lives in.
sub _judged_log_text {
    my ($reason, $goal, $just, $otp) = @_;
    my $cut = sub {
        my ($s) = @_;
        $s = '' unless defined $s;
        return length($s) > 70 ? (substr($s, 0, 67) . '...') : $s;
    };
    return $cut->($reason) . '; goal: ' . $cut->($goal) . '; justification: ' . $cut->($just)
         . '; verdict: disarm-judge/' . $otp . '.verdict.json';
}

# emergency-stop (judged-continuity-disarm pkg 06, spec 2.2 j, Decisions 10,
# 15, 16, 21, 26): one unjudged call that stops a session for a genuine
# defect, filing a mechanical bug report through BpHook::file_stop_bug so
# the call is never an unaudited bypass. mint_disarm_otp is never called on
# either path. On the coordinator path, BpHook::disarm, _disarm_thread,
# _off_hand_off, lease_sync and plan_after_off are NOT called.
if ($verb eq 'emergency-stop') {
    my $coord  = (defined $ENV{BP_LEDGER} && length $ENV{BP_LEDGER}) ? 1 : 0;
    my $actor  = $coord ? 'coordinator' : ($OPERATOR_TICKET ? 'operator' : 'agent');
    my $reason = sanitize_text($flags{reason});
    my $area   = defined $EMERGENCY_STOP_AREA ? $EMERGENCY_STOP_AREA : 'butler';

    my $bug = BpHook::file_stop_bug(source => 'emergency-stop', session => $SID, actor => $actor,
                                    reason => $reason, area => $area, cwd => $TICKET_CWD);
    my $logged = "$reason; $bug->{note}";

    my $bug_line = sub {
        if (defined $bug->{id}) {
            out("emergency-stop: bug report $bug->{id} filed (severity high, area $area).\n");
        }
        else {
            binmode(STDERR, ':raw');
            print STDERR _bytes("butler-continuity: WARNING: emergency-stop could not file its bug report "
                . "($bug->{error}). Continuing without it; file the defect by hand with almanac-bug.pl file.") . "\n";
        }
    };

    if ($coord) {
        my $ok = BpHook::log_reason($SID, $actor, 'emergency-stop', $logged, $PROJECT);
        out("emergency-stop recorded for coordinator session $S8; continuity was NOT turned off. "
            . "A coordinator stops only when its ledger is terminal: set its status to blocked or "
            . "parked with a concrete '## Next action', then stop.\n");
        $bug_line->();
        unless ($ok) {
            binmode(STDERR, ':raw');
            print STDERR "butler-continuity: warning: reason log not written.\n";
        }
        exit 0;
    }

    my ($T, $broken) = _disarm_thread();               # NO doing-task check
    _complete_disarm($actor, $reason, $T, $broken, tag => 'emergency-stop', logged => $logged);
    $bug_line->();
    exit 0;
}

if ($verb eq 'status') {
    my @lines;

    if (defined $ENV{BP_LEDGER} && length $ENV{BP_LEDGER}) {
        push @lines, "session $S8: armed (coordinator)";
    }
    elsif (-e "$ROOT/armed/$SID") {
        my $d = read_json_file("$ROOT/armed/$SID");
        my $role = (ref $d eq 'HASH' && defined $d->{role} && length $d->{role}) ? sanitize_text($d->{role}) : 'unknown';
        my $at   = (ref $d eq 'HASH' && defined $d->{at}   && length $d->{at})   ? sanitize_text($d->{at})   : 'unknown';
        $role = 'unknown' unless length $role;
        $at   = 'unknown' unless length $at;
        push @lines, "session $S8: armed (role $role, since $at)";
        my $goal = (ref $d eq 'HASH' && defined $d->{goal} && !ref $d->{goal}) ? sanitize_text($d->{goal}) : '';
        $goal = '(no goal recorded)' unless length $goal;
        push @lines, "goal: $goal";
    }
    elsif (-e "$ROOT/off/$SID") {
        my $d = read_json_file("$ROOT/off/$SID");
        my $actor  = (ref $d eq 'HASH' && defined $d->{actor}  && length $d->{actor})  ? sanitize_text($d->{actor})  : 'unknown';
        my $at     = (ref $d eq 'HASH' && defined $d->{at}     && length $d->{at})     ? sanitize_text($d->{at})     : 'unknown';
        my $reason = (ref $d eq 'HASH' && defined $d->{reason} && length $d->{reason}) ? sanitize_text($d->{reason}) : 'unknown';
        $actor  = 'unknown' unless length $actor;
        $at     = 'unknown' unless length $at;
        $reason = 'unknown' unless length $reason;
        push @lines, "session $S8: off (by $actor at $at): $reason";
    }
    else {
        push @lines, "session $S8: not armed";
    }

    push @lines, _status_thread_line();

    my $h = BpHook::holder($SID);
    if (defined $h && BpHook::holder_live($SID, {})) {
        my $items = (ref $h->{items} eq 'ARRAY')
            ? sanitize_text(join(', ', @{ $h->{items} }))
            : '';
        my $ddl = BpHook::local_utc_hhmm($h->{deadline});
        $ddl = 'unknown' unless defined $ddl;
        push @lines, sprintf('holder: running until %s; still running: %s', $ddl, $items);
    }
    else {
        push @lines, 'holder: none';
    }

    my $wl;
    if ($ENV{CCPRAXIS_NO_WAKELOCK}) {
        $wl = 'disabled';
    }
    else {
        my $ldir = BpContinuityLease::legacy_dir();
        # R4-L-tasklist (review m3): status "starts no process" (spec
        # SS2.2). BpContinuityLease::state()'s default pid_alive probe runs
        # `tasklist` on Windows -- but a Windows keepawake.pid holds a
        # WINDOWS pid, which is never in the same namespace as this (MSYS)
        # process's own signal-0 liveness check (Decision 83; CLAUDE.md's
        # pid-namespace landmine), so that probe always answered false here.
        # Judge liveness by the pid file's OWN heartbeat age instead: held
        # iff its mtime is under TICK_SECONDS * stale_ticks() (300s) old. A
        # negative age (clock skew) counts as held; a missing file or failed
        # stat counts as not held. No spawn, no signalling, whatever the
        # recorded pid.
        my $stale_after = do { no warnings 'once'; $BpContinuityLease::TICK_SECONDS } * BpContinuityLease::stale_ticks();
        $wl = defined $ldir
            ? BpContinuityLease::state($ldir, pid_alive => sub {
                  my $pf = BpContinuityLease::wakelock_pid_file($ldir);
                  my @st = stat($pf);
                  return 0 unless @st;
                  my $age = time() - $st[9];
                  return 1 if $age < 0;
                  return $age < $stale_after ? 1 : 0;
              })
            : 'released';
    }
    push @lines, "wake-lock: $wl";

    out(join("\n", @lines) . "\n");
    exit 0;
}

usage_die();
