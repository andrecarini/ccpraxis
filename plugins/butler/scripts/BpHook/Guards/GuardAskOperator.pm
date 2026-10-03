# BpHook::Guards::GuardAskOperator -- an unattended (armed) session must
# not stop to ask the operator a question; AskUserQuestion is denied and
# the question is queued in the legacy question queue instead (Decision 22,
# package 14 of blueprint hook-continuity-remake), successor to
# guard-ask-operator.sh.
#
# Contract: .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 14-guards-remake-spec.md sec 3.4. Architecture:
# plugins/butler/docs/hook-architecture.md ("guard-ask-operator" successor
# row). Bug 20260922-210421-0468: session facts come ONLY from
# BpHook::is_armed($sid) for THIS payload's session -- no run-state.json,
# no legacy .continuity-active/ registry, no other session's arm file is
# ever consulted (Decision 3).
#
# run($p, @args) never calls exit, never dies on purpose, never spawns a
# process (no system/exec/backtick/qx/pipe-open). Prints only through
# BpHook::deny(@lines).
package BpHook::Guards::GuardAskOperator;
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd ();

my $SELF_DIR;
{
    my $f = __FILE__;
    $f = Cwd::abs_path($f) // $f;
    $SELF_DIR = dirname($f);
}
require "$SELF_DIR/../../BpHook.pm"
    unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
require "$SELF_DIR/Common.pm"
    unless grep { m{(?:^|/)Guards/Common\.pm$} } keys %INC;

my $PLACEHOLDER = '(question text not recoverable from the payload)';

# ---------------------------------------------------------------------------
# _iso_now() -- UTC, "YYYY-MM-DDTHH:MM:SSZ".
# ---------------------------------------------------------------------------
sub _iso_now {
    my @t = gmtime(time());
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# ---------------------------------------------------------------------------
# _question_text($p) -> TEXT per spec sec 3.4: the "question" of each
# tool_input.questions[i] (i < 16) that is a non-empty string, in order,
# stopping at the first gap, joined with " | "; a 17th present appends the
# truncation marker; none -> the placeholder. Every run of CR/LF becomes
# one space.
# ---------------------------------------------------------------------------
sub _question_text {
    my ($p) = @_;
    my $ti = (ref $p eq 'HASH' && ref $p->{tool_input} eq 'HASH') ? $p->{tool_input} : {};
    my $qs = (ref $ti->{questions} eq 'ARRAY') ? $ti->{questions} : [];

    my @collected;
    for my $i (0 .. 15) {
        my $q = $qs->[$i];
        my $qt = (ref $q eq 'HASH') ? $q->{question} : undef;
        last unless defined $qt && !ref($qt) && length $qt;
        push @collected, $qt;
    }

    my $text;
    if (@collected) {
        $text = join(' | ', @collected);
        if (scalar(@collected) == 16) {
            my $q17 = $qs->[16];
            my $qt17 = (ref $q17 eq 'HASH') ? $q17->{question} : undef;
            if (defined $qt17 && !ref($qt17) && length $qt17) {
                $text .= ' | (+more, truncated at 16)';
            }
        }
    }
    else {
        $text = $PLACEHOLDER;
    }
    $text =~ s/[\r\n]+/ /g;
    $text =~ s/[\t\x{2028}\x{2029}]+/ /g;
    $text =~ s/\p{Cc}//g;
    return $text;
}

# ---------------------------------------------------------------------------
# file_question($p, $text) -> $id|undef. Files $text as an almanac inbox
# item (Almanac::Inbox::file), never falling back to the process cwd
# (Hooks, and GuardHarness::run_module in-process, can have the repo as
# their cwd -- a fallback there would write real state). Package 09 re-
# point (Decision 108, spec sec 2.5; renamed by blueprint where-things-go,
# package 01-inbox-rename); one call site so a future change edits one
# place.
# ---------------------------------------------------------------------------
sub file_question {
    my ($p, $text) = @_;

    my $start;
    if (ref $p eq 'HASH' && defined $p->{cwd} && length $p->{cwd} && -d $p->{cwd}) {
        $start = $p->{cwd};
    }
    elsif (defined $ENV{CLAUDE_PROJECT_DIR} && length $ENV{CLAUDE_PROJECT_DIR} && -d $ENV{CLAUDE_PROJECT_DIR}) {
        $start = $ENV{CLAUDE_PROJECT_DIR};
    }
    else {
        return undef;
    }

    my $inbox_pl = "$SELF_DIR/../../../../almanac/scripts/almanac-inbox.pl";
    unless (grep { m{(?:^|/)almanac-inbox\.pl$} } keys %INC) {
        local $@;
        return undef unless eval { require $inbox_pl; 1 };
    }

    my $rec = eval { Almanac::Inbox::file(title => $text, cwd => $start) };
    return (ref $rec eq 'HASH' && defined $rec->{id}) ? $rec->{id} : undef;
}

# ---------------------------------------------------------------------------
# run($p, @args) -> 0 | 2.
# ---------------------------------------------------------------------------
sub run {
    my ($p, @args) = @_;
    $p = {} unless ref $p eq 'HASH';
    return 0 unless BpHook::payload_ok();

    my $tool = $p->{tool_name};
    return 0 unless defined $tool && !ref($tool) && $tool eq 'AskUserQuestion';

    my $sid = BpHook::session_id($p);
    return 0 unless BpHook::is_armed($sid);

    my $text = _question_text($p);
    my $id = file_question($p, $text);

    my $ledger = $ENV{BP_LEDGER};
    my $why = (defined $ledger && length $ledger)
        ? 'this is a headless coordinator session'
        : 'continuity is ARMED for this session';

    my @lines;
    push @lines, "BLOCKED: $why, so asking the operator would stop unattended work for an answer nobody is there to give.";
    if (defined $id) {
        push @lines, "The question is filed as inbox item $id.";
    }
    else {
        push @lines, 'The question could not be filed; note it in your report instead.';
    }
    push @lines, 'Decide it yourself unless it is a product decision (.ccpraxis-local-data/guidance/escalate-product-decisions-only.md).';
    push @lines, 'Carry on with the work that does not depend on the answer; queued questions are surfaced when the run reports.';

    return BpHook::deny(map { BpHook::Guards::Common::fit($_) } @lines);
}

1;
