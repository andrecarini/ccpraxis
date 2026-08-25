package SpendPanel;
# Turns b36's (BpSpend) per-provider spend structs -- plus a third, Claude,
# meter this panel shows even though b36 does not produce it (spec S2) -- into
# a render-ready struct for the TUI panel and the statusline
# (b37-spend-surfaces).
#
# PURE module, following TokenInfo.pm's contract exactly (spec S1): no file
# I/O (no open/stat/-e), no time()/localtime/gmtime anywhere in this file --
# "now" is always an argument, even though this module happens not to need it
# today (every input field here is an already-computed snapshot, not
# something whose age this module derives). Never dies on any input (total
# function). Loaded by launcher.pl only; Dashboard.pm does NOT load it
# (Dashboard renders the already-computed struct via Dashboard::_spend_lines,
# never talking to SpendPanel directly -- exactly the TokenInfo/_token_lines
# split).
#
# See specs/b37-spend-surfaces-spec.md S0/S0.1/S1 for the binding contract.
#
# CONTRACT (invented here, minimal and TokenInfo.pm-shaped, per
# t/54-spend-panel.t's own header):
#
#   SpendPanel::status(\%spend, $now) -> \%info
#
#   \%spend (composed by launcher.pl from BpSpend::fetch() for go/zen, and
#   from bp-usage-gate.pl's own $parsed for claude):
#     claude => { status => 'ok'|'unknown',
#                 five_hour => { utilization => 0..1 } | undef,
#                 seven_day => { utilization => 0..1 } | undef,
#                 diagnostic => $str | undef }
#     go     => { status => 'ok'|'unknown'|'absent',
#                 five_hour|weekly|monthly => { used => N, limit => N } | undef,
#                 diagnostic => $str | undef }
#     zen    => { status => 'ok'|'unknown'|'absent',
#                 balance => N | undef, budget => N | undef,
#                 diagnostic => $str | undef }
#     zen_enabled => 0 | 1   -- operator toggle, independent of zen.status
#
#   \%info (render-ready, NOT yet spans):
#     claude => { state => 'ok'|'unreadable',
#                 windows => [ { name=>'five_hour'|'seven_day', fraction=>N, text=>STR }, ... ],
#                 diagnostic => $str | undef }
#     go     => { state => 'absent'|'unreadable'|'exhausted'|'ok',
#                 windows => [ { name=>'five_hour'|'weekly'|'monthly', used=>N, limit=>N,
#                                fraction=>N, text=>'$N.NN / $N.NN' }, ... ],
#                 diagnostic => $str | undef }
#     zen    => { state => 'disabled'|'absent'|'unreadable'|'exhausted'|'ok',
#                 balance_text => STR|undef, budget_text => STR|undef,
#                 fraction => N|undef, diagnostic => $str|undef }
#     priority => [ { provider=>'claude'|'go'|'zen', window=>NAME, fraction=>N }, ... ]
#                 -- every window with a defined fraction whose PROVIDER state
#                 is 'ok' (never 'exhausted'/'absent'/'unreadable'/'disabled'),
#                 stable-sorted by fraction DESCENDING (nearest exhaustion
#                 first); ties keep NATURAL declared order: claude/five_hour,
#                 claude/seven_day, go/five_hour, go/weekly, go/monthly,
#                 zen/balance.
#
#   'exhausted' is DERIVED here (spec S0.1): status eq 'ok' AND some window's
#   fraction >= 1.0. Never a b36 status. Criterion 4's "unmeasurable" state
#   does not exist (spec S0.1's recorded substitution): it collapses into
#   unreadable, since a configured-but-silent provider now means "failed to
#   read", not "permanently has nothing to show".
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

# _money($n) -> a two-decimal dollar string ("$1.00"). PRIVATE.
sub _money {
    my ($n) = @_;
    return sprintf('$%.2f', $n);
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
        # 100. So a real 25% rendered as "2500%".
        #
        # The display was the visible half. The worse half was silent: every
        # other provider's `fraction` is a true 0..1 ratio (go divides used by
        # limit), and _priority ranks "nearest exhaustion" by sorting on it
        # descending. A claude window carrying 25 instead of 0.25 outranked
        # every possible go or zen value by two orders of magnitude, so claude
        # was ALWAYS reported as nearest regardless of the actual numbers.
        my $f = $u / 100;
        push @out, { name => $name, fraction => $f, text => _pct($f) };
    }
    return \@out;
}

# _claude_info(\%claude) -> { state, windows, diagnostic }. Claude has only
# two states in this contract (ok/unreadable) -- it is a third meter b37
# shows even though b36 does not produce it (spec S2), and unlike Go/Zen it
# has no "not configured" concept here (the sandbox host is always the one
# talking to Claude). PRIVATE.
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

# _go_windows(\%go) -> \@windows, one entry per readable window (five_hour,
# weekly, monthly, in that declared order). Both used and limit must be
# readable numbers for a window to appear; a limit of 0 yields an undef
# fraction rather than a division. PRIVATE.
sub _go_windows {
    my ($go) = @_;
    my @out;
    for my $name (qw(five_hour weekly monthly)) {
        my $w     = _hash($go->{$name});
        my $used  = _num($w->{used});
        my $limit = _num($w->{limit});
        next unless defined $used && defined $limit;
        my $fraction = ($limit > 0) ? ($used / $limit) : undef;
        push @out, {
            name     => $name,
            used     => $used,
            limit    => $limit,
            fraction => $fraction,
            text     => sprintf('%s / %s', _money($used), _money($limit)),
        };
    }
    return \@out;
}

# _go_info(\%go) -> { state, windows, diagnostic }. Four states (spec S0.1):
# absent (unconfigured), unreadable (unknown / failed scrape), exhausted
# (ok AND some window at/over its limit, derived HERE), ok. An unrecognized
# status string degrades to 'absent' -- the safe direction, since it never
# claims a number that was never actually read. PRIVATE.
sub _go_info {
    my ($go_raw) = @_;
    my $go     = _hash($go_raw);
    my $status = _str($go->{status}) // '';
    my $diag   = _str($go->{diagnostic});

    return { state => 'absent', windows => [], diagnostic => $diag }
        if $status eq 'absent';
    return { state => 'unreadable', windows => [], diagnostic => $diag }
        if $status eq 'unknown';

    if ($status eq 'ok') {
        my $windows = _go_windows($go);
        my $exhausted = grep { defined($_->{fraction}) && $_->{fraction} >= 1 } @$windows;
        return { state => ($exhausted ? 'exhausted' : 'ok'), windows => $windows, diagnostic => $diag };
    }

    return { state => 'absent', windows => [], diagnostic => $diag };
}

# _zen_info(\%zen, $enabled) -> { state, balance_text, budget_text, fraction,
# diagnostic }. Zen is disabled by default (spec S2/C5): $enabled false wins
# over everything else and renders as 'disabled', never as zero or an error.
# When enabled, mirrors Go's absent/unreadable/exhausted/ok states, with
# 'fraction' meaning "consumed fraction of budget" (balance/budget). PRIVATE.
sub _zen_info {
    my ($zen_raw, $enabled) = @_;

    unless ($enabled) {
        return { state => 'disabled', balance_text => undef, budget_text => undef,
                 fraction => undef, diagnostic => undef };
    }

    my $zen    = _hash($zen_raw);
    my $status = _str($zen->{status}) // '';
    my $diag   = _str($zen->{diagnostic});

    return { state => 'absent', balance_text => undef, budget_text => undef,
             fraction => undef, diagnostic => $diag }
        if $status eq 'absent';
    return { state => 'unreadable', balance_text => undef, budget_text => undef,
             fraction => undef, diagnostic => $diag }
        if $status eq 'unknown';

    if ($status eq 'ok') {
        my $balance = _num($zen->{balance});
        my $budget  = _num($zen->{budget});
        my $balance_text = defined $balance ? _money($balance) : undef;
        my $budget_text  = defined $budget  ? _money($budget)  : undef;
        my $fraction;
        $fraction = $balance / $budget if defined $balance && defined $budget && $budget > 0;
        my $state = (defined $fraction && $fraction >= 1) ? 'exhausted' : 'ok';
        return { state => $state, balance_text => $balance_text, budget_text => $budget_text,
                 fraction => $fraction, diagnostic => $diag };
    }

    return { state => 'absent', balance_text => undef, budget_text => undef,
             fraction => undef, diagnostic => $diag };
}

# _priority(\%claude_info, \%go_info, \%zen_info) -> \@priority (spec: the
# window nearest exhaustion first; the panel and b36's gate must not disagree
# about which window matters, so this mirrors b36's "tightest headroom"
# framing). Only windows belonging to a provider whose OWN state is 'ok' are
# eligible -- an already-exhausted/unreadable/absent/disabled provider is not
# a "which window is tightest" candidate, it is already the worst case and
# rendered as its own distinct state. Stable sort (Perl sort is a stable
# mergesort) preserves the natural declared order on ties. PRIVATE.
sub _priority {
    my ($claude_info, $go_info, $zen_info) = @_;
    my @candidates;

    # b37 FIX: admit 'exhausted' as well as 'ok'. Gating on 'ok' alone dropped a
    # provider from the nearest-exhaustion ranking AT THE MOMENT IT BECAME
    # EXHAUSTED -- exactly backwards, since criterion 6 exists to surface the
    # window closest to its limit and a window AT its limit is the closest
    # possible. Only states with no real figures (unreadable, absent, disabled)
    # stay excluded, and they carry no fraction to rank anyway.
    if ($claude_info->{state} eq 'ok' || $claude_info->{state} eq 'exhausted') {
        for my $w (@{ $claude_info->{windows} || [] }) {
            push @candidates, { provider => 'claude', window => $w->{name}, fraction => $w->{fraction} }
                if defined $w->{fraction};
        }
    }
    if ($go_info->{state} eq 'ok' || $go_info->{state} eq 'exhausted') {
        for my $w (@{ $go_info->{windows} || [] }) {
            push @candidates, { provider => 'go', window => $w->{name}, fraction => $w->{fraction} }
                if defined $w->{fraction};
        }
    }
    if (($zen_info->{state} eq 'ok' || $zen_info->{state} eq 'exhausted') && defined $zen_info->{fraction}) {
        push @candidates, { provider => 'zen', window => 'balance', fraction => $zen_info->{fraction} };
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

    my $zen_enabled = $spend->{zen_enabled} ? 1 : 0;

    my $claude_info = _claude_info($spend->{claude});
    my $go_info     = _go_info($spend->{go});
    my $zen_info    = _zen_info($spend->{zen}, $zen_enabled);

    return {
        claude   => $claude_info,
        go       => $go_info,
        zen      => $zen_info,
        priority => _priority($claude_info, $go_info, $zen_info),
    };
}

# ---------------------------------------------------------------------------
# SpendPanel::from_snapshot(\%persisted) -> \%spend. PUBLIC, pure, total.
#
# THE TRANSLATION THIS MODULE'S OWN HEADER ALREADY NAMED AND NOBODY BUILT.
# Read that header: \%spend is described as "composed by launcher.pl from
# BpSpend::fetch() for go/zen, and from bp-usage-gate.pl's own $parsed for
# claude". That composition step was designed for an in-process caller. When
# persistence was wired in later, launcher.pl's _gather_spend was pointed at
# the FILE and handed the decoded bytes straight to status() -- and the file is
# not in that shape.
#
#   what write_snapshot persists:  { generated_at => ISO,
#                                    results => [ { provider => 'go', ... }, ... ] }
#   what status() indexes:         { go => {...}, zen => {...}, claude => {...},
#                                    zen_enabled => 0|1 }
#
# An ARRAY keyed by a provider FIELD, versus a hash keyed by provider NAME. So
# $spend->{go} was always undef and every provider degraded -- go to 'absent',
# zen to 'disabled', claude to 'unreadable' -- no matter what had actually been
# fetched. Measured, not inferred: a snapshot in the writer's format carrying
# go five_hour 42/100 and zen balance 12.34 rendered absent/disabled; the same
# figures in this function's output render ok/ok.
#
# BOTH SHAPES ARE JUSTIFIED WHERE THEY ARE, which is why this is an adapter and
# not a change to either side. The writer's array form is what makes its field
# whitelist structural (_whitelist_result runs per result). The reader's keyed
# form is what an in-process composer naturally produces. The missing piece was
# always the bridge.
#
# Rules, each of which is a distinction status() can actually see:
#   * a result whose provider is not one of claude/go/zen is DROPPED, never
#     guessed at -- a newer bp-spend.pl must not be able to inject a key here;
#   * a provider absent from `results` is ABSENT from the output, never
#     materialised as {} -- status() reads a missing key as "we never looked"
#     and a present-but-empty hash as "we looked and found nothing";
#   * zen_enabled is DERIVED, because it never appears in the persisted format
#     and defaulting it to 0 renders a successfully-fetched zen as `disabled`
#     -- the wrong word for "we have figures";
#   * generated_at is deliberately not forwarded: status() takes no age and
#     derives none (see its own comment), so passing it would be inert.
# ---------------------------------------------------------------------------
my %KNOWN_PROVIDER = map { $_ => 1 } qw(claude go zen);

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

    $spend{zen_enabled} = (ref($spend{zen}) eq 'HASH'
                           && defined $spend{zen}{status}
                           && $spend{zen}{status} ne 'absent') ? 1 : 0;

    return \%spend;
}

1;
