package SpendPanel;
# Turns the persisted Claude spend snapshot (bp-spend.pl's write_snapshot) into
# a render-ready struct for the TUI's Claude Code panel and the statusline
# (b37-spend-surfaces).
#
# PURE module, following TokenInfo.pm's contract exactly (spec S1): no file
# I/O (no open/stat/-e), no time()/localtime/gmtime anywhere in this file --
# "now" is always an argument, even though this module happens not to need it
# today (every input field here is an already-computed snapshot, not
# something whose age this module derives). Never dies on any input (total
# function). Loaded by launcher.pl; Dashboard.pm does NOT load it.
#
# See specs/b37-spend-surfaces-spec.md S0/S0.1/S1 for the binding contract.
# It also covered OpenCode Go and Zen; those providers were removed when
# ccpraxis became Claude Code only, and claude is all that remains of it.
#
# CONTRACT:
#
#   SpendPanel::status(\%spend, $now) -> \%info
#
#   \%spend (SpendPanel::from_snapshot's output):
#     claude => { status => 'ok'|'unknown',
#                 five_hour => { utilization => 0..100 } | undef,
#                 seven_day => { utilization => 0..100 } | undef,
#                 diagnostic => $str | undef }
#
#   \%info (render-ready, NOT yet spans):
#     claude   => { state => 'ok'|'unreadable',
#                   windows => [ { name=>'five_hour'|'seven_day', fraction=>N, text=>STR }, ... ],
#                   diagnostic => $str | undef }
#     priority => [ { provider=>'claude', window=>NAME, fraction=>N }, ... ]
#                 -- every window with a defined fraction, stable-sorted by
#                 fraction DESCENDING (nearest exhaustion first); ties keep the
#                 declared order five_hour, seven_day. The statusline's
#                 headline reads priority->[0].
use strict;
use warnings;

# _hash($v) -> $v if it is a plain (unblessed) HASH ref, else {} -- total,
# never dereferences anything that isn't actually a hash. PRIVATE.
sub _hash {
    my ($v) = @_;
    return (ref($v) eq 'HASH') ? $v : {};
}

# _num($v) -> $v (numified) if it looks like a plain signed/fractional
# number, else undef. PRIVATE. Mirrors TokenInfo::_num's discipline: never
# trust "does it just work in arithmetic".
sub _num {
    my ($v) = @_;
    return undef if !defined $v || ref $v;
    return undef unless $v =~ /^-?\d+(?:\.\d+)?$/;
    return $v + 0;
}

# _str($v) -> $v as a plain string if it is defined, non-ref and non-empty,
# else undef. PRIVATE.
sub _str {
    my ($v) = @_;
    return (defined $v && !ref $v && length $v) ? "$v" : undef;
}

# _pct($fraction) -> an integer-percent display string ("42%"), rounding to
# the nearest whole percent. PRIVATE.
sub _pct {
    my ($f) = @_;
    return sprintf('%d%%', int($f * 100 + 0.5));
}

# _claude_windows(\%claude) -> \@windows, one entry per readable window
# (five_hour, seven_day, in that declared order). A missing/wrong-typed
# window is simply skipped -- never fabricated, never a crash. PRIVATE.
sub _claude_windows {
    my ($claude) = @_;
    my @out;
    for my $name (qw(five_hour seven_day)) {
        my $w = _hash($claude->{$name});
        my $u = _num($w->{utilization});
        next unless defined $u;
        # utilization IS ALREADY A PERCENT, 0..100. The oauth usage contract
        # says so twice over -- bp-contract.pl documents the field as
        # "utilization:int%" and rejects anything outside 0..100 -- but this
        # stored it as `fraction` and ran it through _pct, which multiplies by
        # 100. So a real 25% rendered as "2500%". `fraction` is a true 0..1
        # ratio, which is what _priority sorts on.
        my $f = $u / 100;
        push @out, { name => $name, fraction => $f, text => _pct($f) };
    }
    return \@out;
}

# _claude_info(\%claude) -> { state, windows, diagnostic }. Two states
# (ok/unreadable): there is no "not configured" concept here, since the
# sandbox host is always the one talking to Claude. PRIVATE.
sub _claude_info {
    my ($claude_raw) = @_;
    my $claude = _hash($claude_raw);
    my $status = _str($claude->{status}) // '';
    my $diag   = _str($claude->{diagnostic});

    if ($status eq 'ok') {
        return { state => 'ok', windows => _claude_windows($claude), diagnostic => $diag };
    }
    # 'unknown', or any unrecognized/missing status -> unreadable, never a
    # fabricated 'ok' with no data (spec: nothing renders as $0/blank-ok).
    return { state => 'unreadable', windows => [], diagnostic => $diag };
}

# _priority(\%claude_info) -> \@priority, the window nearest exhaustion first.
# Only an 'ok' reading has windows to rank. Stable sort (Perl sort is a stable
# mergesort) preserves the declared order on ties. PRIVATE.
sub _priority {
    my ($claude_info) = @_;
    my @candidates;
    if ($claude_info->{state} eq 'ok') {
        for my $w (@{ $claude_info->{windows} || [] }) {
            push @candidates, { provider => 'claude', window => $w->{name}, fraction => $w->{fraction} }
                if defined $w->{fraction};
        }
    }
    my @sorted = sort { $b->{fraction} <=> $a->{fraction} } @candidates;
    return \@sorted;
}

# SpendPanel::status(\%spend, $now) -> \%info. PUBLIC, pure, total (C2): every
# helper above degrades on bad input rather than dereferencing it raw, so no
# input shape (undef, arrayref, coderef, blessed ref, deeply nested garbage,
# wrong-typed windows) can reach a die. $now is accepted per the TokenInfo.pm
# contract shape but unused -- every field here is an already-computed
# snapshot, not something this module derives an age from.
sub status {
    my ($spend_raw, $now) = @_;
    my $spend = _hash($spend_raw);
    my $claude_info = _claude_info($spend->{claude});
    return {
        claude   => $claude_info,
        priority => _priority($claude_info),
    };
}

# ---------------------------------------------------------------------------
# SpendPanel::from_snapshot(\%persisted) -> \%spend. PUBLIC, pure, total.
#
# The bridge between the two shapes:
#
#   what write_snapshot persists:  { generated_at => ISO,
#                                    results => [ { provider => 'claude', ... }, ... ] }
#   what status() indexes:         { claude => {...} }
#
# An ARRAY keyed by a provider FIELD, versus a hash keyed by provider NAME.
# Before this existed, launcher.pl's _gather_spend handed the decoded file
# straight to status(), so every provider degraded no matter what had actually
# been fetched -- measured, not inferred.
#
# BOTH SHAPES ARE JUSTIFIED WHERE THEY ARE, which is why this is an adapter and
# not a change to either side. The writer's array form is what makes its field
# whitelist structural (_whitelist_result runs per result). The reader's keyed
# form is what status() naturally indexes.
#
# Rules, each of which is a distinction status() can actually see:
#   * a result whose provider is not claude is DROPPED, never guessed at -- a
#     snapshot written before the OpenCode providers were removed still
#     carries go/zen rows, and nothing here reads them;
#   * claude absent from `results` is ABSENT from the output, never
#     materialised as {} -- status() reads a missing key as "we never looked"
#     and a present-but-empty hash as "we looked and found nothing";
#   * generated_at is deliberately not forwarded: status() takes no age and
#     derives none (see its own comment), so passing it would be inert.
# ---------------------------------------------------------------------------
my %KNOWN_PROVIDER = map { $_ => 1 } qw(claude);

sub from_snapshot {
    my ($persisted) = @_;
    my $p = _hash($persisted);
    my $results = (ref($p->{results}) eq 'ARRAY') ? $p->{results} : [];

    my %spend;
    for my $r (@$results) {
        next unless ref($r) eq 'HASH';
        my $name = _str($r->{provider});
        next unless defined $name && $KNOWN_PROVIDER{$name};
        # Last wins, deliberately: a duplicated provider in a snapshot is
        # malformed, and the later entry is the one a sequential writer wrote
        # most recently. Neither is a reason to die.
        $spend{$name} = $r;
    }

    return \%spend;
}

1;
