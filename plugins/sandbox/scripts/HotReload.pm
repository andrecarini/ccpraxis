package HotReload;
# HotReload.pm -- decide WHICH modules may be hot-reloaded and WHICH have
# changed. Package t11-tui-hot-reload, blueprint tui-operator-feedback.
#
# Operator: "Could we make source code changes on the TUI be hot-reloaded? I
# assume there is a high chance that a running TUI could break anyways if the
# running source code doesn't get reloaded but separate modules probably will".
#
# That assumption is right, and the boundary is sharper than module-vs-launcher.
# It is: IS THIS SUB CURRENTLY ON THE CALL STACK?
#
#   * launcher.pl is the running process -- signal handlers, terminal raw mode,
#     child pids, open log handles, the _gather_* functions. It is also, and
#     usefully, NOT IN %INC at all: perl records only require'd/use'd files, and
#     the main program is neither. So excluding it is not a rule anyone has to
#     remember, it is a fact about how perl works.
#   * Dashboard::run is the event loop and is ON THE STACK for the whole
#     session. Reloading Dashboard.pm installs a new run(), but the ACTIVE call
#     keeps executing the old body until it returns. Loop structure, key
#     dispatch and tick cadence therefore need a relaunch.
#   * Everything the loop calls BY NAME resolves through the symbol table at
#     call time, so it goes live immediately. That is the whole render path.
#
# WHY THIS WORKS AT ALL, and it is worth writing down because it was luck rather
# than design: launcher.pl loads every one of these with `use X ()` -- an EMPTY
# import list. Nothing is exported, so nothing is inlined into a caller, so no
# constant or sub is frozen into another file's compiled form. Every call is
# fully qualified and late-bound. If any module here ever starts exporting, the
# importer's copy stops tracking and hot-reload silently half-works.
#
# PURE, in this tree's established sense: no file I/O, no spawning, no writes,
# no clock read, nothing mutated outside its arguments. It decides; the caller
# (launcher.pl, where every other spawn in this tree lives) acts. Total: every
# public sub returns its declared type for any input, including undef, refs
# where scalars are expected, and hostile keys.
use strict;
use warnings;

# ---------------------------------------------------------------------------
# THE ALLOWLIST -- named, not derived.
#
# The tempting derivation is "everything in %INC under the scripts directory",
# and it is nearly right: it structurally cannot pick up launcher.pl. But it
# WOULD pick up KeepAwake (a lifecycle holder around a live child process),
# SandboxLock (holds an flock), LaunchLog (holds an open filehandle) and every
# other module that owns something the process cannot re-acquire by being
# recompiled. Reloading those buys nothing for TUI iteration and risks the run.
#
# So the list is written out. It is exactly the render path plus the pure
# structs that feed it, and the rule for adding to it is one question: does
# reloading this file discard anything the process cannot rebuild from its
# arguments? If yes, it does not belong here.
# ---------------------------------------------------------------------------
my @RELOADABLE = qw(
    Theme
    tui::Layout
    tui::Frame
    tui::Meter
    tui::Screen
    tui::DashboardScreen
    tui::BackpackScreen
    tui::LaunchScreens
    Dashboard
    SpendPanel
    TokenInfo
    Resources
    RunState
);

# The modules whose file-scope state is a MEMO rather than a fact -- reloading
# them deliberately drops a cache, which is the point (a Theme edit must
# invalidate the glyph table that memoised the old one). Recorded so the
# discarding is a documented consequence and not a surprise.
my %MEMO_ONLY_STATE = map { $_ => 1 } qw(Theme tui::Frame tui::Layout Dashboard);

sub reloadable_modules { return @RELOADABLE }
sub is_reloadable {
    my ($name) = @_;
    return 0 unless defined $name && !ref $name;
    return (grep { $_ eq $name } @RELOADABLE) ? 1 : 0;
}
sub discards_memo {
    my ($name) = @_;
    return 0 unless defined $name && !ref $name;
    return $MEMO_ONLY_STATE{$name} ? 1 : 0;
}

# inc_key($module) -> the %INC key for a module name, or undef.
# 'tui::DashboardScreen' -> 'tui/DashboardScreen.pm'. Refuses anything that is
# not a plain module name, so a caller cannot build a path out of hostile input.
sub inc_key {
    my ($name) = @_;
    return undef unless defined $name && !ref $name && length $name;
    return undef unless $name =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*\z/;
    (my $path = $name) =~ s{::}{/}g;
    return "$path.pm";
}

# loaded(\%inc) -> \@names, the allowlisted modules actually present in %INC.
#
# A module in the list but absent from %INC was never loaded by this process
# (tui::BackpackScreen is required lazily, only when [b] is first pressed), and
# reloading something that was never loaded would run its file-scope body for
# the first time at an arbitrary moment. Skip it; it will load normally.
sub loaded {
    my ($inc) = @_;
    return [] unless ref($inc) eq 'HASH';
    my @out;
    for my $name (@RELOADABLE) {
        my $key = inc_key($name);
        next unless defined $key;
        my $path = $inc->{$key};
        next unless defined $path && !ref $path && length $path;
        push @out, { name => $name, key => $key, path => $path };
    }
    return \@out;
}

# changed(\@loaded, \%baseline, \%now) -> \@names whose mtime moved.
#
# A module with NO baseline entry counts as changed. That is deliberate and it
# is the conservative direction here: the alternative -- treating "I have never
# seen this before" as "unchanged" -- would silently skip a module on the first
# check after it was added to the list, which is exactly when someone is most
# likely to be testing that it works.
#
# An UNREADABLE mtime (undef in %now) counts as UNCHANGED, and that is the
# conservative direction for the opposite reason: a file we cannot stat is one
# we certainly cannot validate, and proposing to reload it would turn a
# transient read failure into a reload attempt.
sub changed {
    my ($loaded, $baseline, $now) = @_;
    return [] unless ref($loaded) eq 'ARRAY';
    $baseline = {} unless ref($baseline) eq 'HASH';
    $now      = {} unless ref($now)      eq 'HASH';
    my @out;
    for my $m (@$loaded) {
        next unless ref($m) eq 'HASH' && defined $m->{name};
        my $n = $now->{ $m->{name} };
        next unless defined $n && !ref $n && $n =~ /\A-?\d+(?:\.\d+)?\z/;
        my $b = $baseline->{ $m->{name} };
        push @out, $m if !defined($b) || $b ne $n;
    }
    return \@out;
}

# summarise(\%r) -> \%summary for the renderer: { ok, headline, notes => [...] }
#
# $r: { reloaded => [names], skipped => [{name,why}], rolled_back => [{name,why}] }
#
# THE `notes` ALWAYS CARRY THE LAUNCHER CAVEAT, on success as much as on
# failure, and that is the single most important thing this module does.
#
# Most real changes to this TUI touch a render module AND launcher.pl together:
# package t01 added sampler_wait_spans to tui::DashboardScreen *and* threaded
# `resources_sampler` into the state hash launcher.pl builds. Hot-reloading the
# module alone feeds NEW render code from the OLD state hash -- and because
# every function on this path is written to be total (degrade on missing input
# rather than die), the result is a clean, plausible, WRONG render of the
# fallback case. The change looks broken when it is merely half-applied.
#
# A hot-reload that stays silent about that is worse than no hot-reload,
# because it converts "my change did not take effect" from something you can
# reason about into something you cannot.
sub summarise {
    my ($r) = @_;
    $r = {} unless ref($r) eq 'HASH';
    my @rel  = _names($r->{reloaded});
    my @skip = _pairs($r->{skipped});
    my @back = _pairs($r->{rolled_back});

    my $headline;
    if (@back) {
        $headline = 'reload FAILED for ' . _count(scalar @back, 'module')
                  . ' and ' . (@back == 1 ? 'it was' : 'they were') . ' rolled back';
    } elsif (@skip && !@rel) {
        $headline = 'nothing reloaded - ' . _count(scalar @skip, 'module') . ' would not compile';
    } elsif (@rel) {
        $headline = 'reloaded ' . _count(scalar @rel, 'module');
        $headline .= ', skipped ' . _count(scalar @skip, 'module') if @skip;
    } else {
        $headline = 'no module changed on disk';
    }

    my @notes;
    push @notes, "$_->{name} - $_->{why}" for @back, @skip;

    # THE launcher.pl CAVEAT IS NO LONGER UNCONDITIONAL.
    #
    # It used to fire on EVERY successful reload, because launcher.pl genuinely
    # could not be picked up at all: a change touching both a render module and
    # launcher.pl was half-applied, and since every function here is total, the
    # new render code would quietly render its fallback from the old state --
    # a correct change LOOKING broken. Warning unconditionally was right then.
    #
    # It is not right now. _relaunch_self() re-execs the launcher when
    # launcher.pl has changed, so by the time this runs one of two things is
    # true: launcher.pl did NOT change, and the caveat is simply false; or it
    # DID and the re-exec was refused, in which case it is already in @skip
    # above with its own specific reason and this adds nothing. Either way the
    # operator is being told something they cannot act on, on every single
    # reload -- and a banner that always appears is a banner that stops being
    # read, which costs the ones that matter.
    #
    # So it fires only when launcher.pl is actually implicated.
    my $launcher_implicated = grep { ($_->{name} // '') =~ /launcher\.pl/ } @back, @skip;
    push @notes, 'launcher.pl changed but was not re-exec\'d, so this reload is only '
               . 'half-applied; quit and re-run claude-sandbox to pick it up'
        if @rel && $launcher_implicated;

    return { ok => (@back ? 0 : 1), headline => $headline,
             reloaded => \@rel, notes => \@notes };
}

sub _names {
    my ($v) = @_;
    return () unless ref($v) eq 'ARRAY';
    return grep { defined && !ref && length } @$v;
}
sub _pairs {
    my ($v) = @_;
    return () unless ref($v) eq 'ARRAY';
    my @out;
    for my $e (@$v) {
        next unless ref($e) eq 'HASH';
        my $n = defined $e->{name} && !ref $e->{name} ? $e->{name} : '?';
        my $w = defined $e->{why}  && !ref $e->{why}  ? $e->{why}  : 'no reason recorded';
        push @out, { name => $n, why => $w };
    }
    return @out;
}
sub _count {
    my ($n, $noun) = @_;
    return "$n $noun" . ($n == 1 ? '' : 's');
}

1;
