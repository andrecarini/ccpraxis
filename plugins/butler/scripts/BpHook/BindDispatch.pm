# BpHook::BindDispatch -- binds every Task/Agent dispatch to one package by
# tool_use_id (package 12 of blueprint hook-continuity-remake), and applies
# Decision 16's one-ledger rule in an armed driver session with 2+ packages
# in flight. Contract: specs/12-dispatch-binding-spec.md; architecture:
# plugins/butler/docs/hook-architecture.md ("Concurrency binding store and
# switch", "Guard message budgets and early exits").
#
# Additive only (Decision 19): nothing here is registered; package 16 wires
# this into hooks.json. Loads BpHook.pm the way BpHook::Guards::TrackDispatch
# does -- require by __FILE__-relative path unless already in %INC -- so the
# director (bp-drive-next.pl) can require this module standalone for
# bound_since() without going through the wrapper at all.
#
# run($p, @args) never calls exit, never spawns a process, never re-parses
# the payload. Prints only through BpHook::deny(). A write failure at any
# step degrades to allow with no output; it never denies (spec sec 3, B10).
package BpHook::BindDispatch;
use strict;
use warnings;
use JSON::PP ();
use Fcntl qw(O_WRONLY O_APPEND O_CREAT LOCK_EX LOCK_UN);
use File::Basename qw(dirname);
use Cwd ();

my $SELF_DIR;
{
    my $f = __FILE__;
    $f = Cwd::abs_path($f) // $f;
    $SELF_DIR = dirname($f);
}
require "$SELF_DIR/../BpHook.pm"
    unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;

# ---------------------------------------------------------------------------
# Constants, exposed as package variables so tests can read them (spec sec
# 2.2).
# ---------------------------------------------------------------------------
our $HISTORY_ROLL_BYTES = 8388608;
our $LOOKUP_MAX_AGE     = 7 * 86400;
our $MAX_LISTED         = 4;
our $GC_INTERVAL        = 3600; # red-team M2: rate-limit the GC sweep

my $NAME_RE = qr/\A[A-Za-z0-9._-]{1,120}\z/;
my $TUID_RE = qr/\A[A-Za-z0-9_-]{1,128}\z/;
my $TYPE_RE = qr/\A[A-Za-z0-9:._-]{1,64}\z/;

# ---------------------------------------------------------------------------
# Decision 69 A2 / package 16 spec sec 2.5: $CASE_INSENSITIVE controls
# whether canon() folds ASCII case before comparing. undef (the default)
# means "auto-detect from $^O" -- true on msys, MSWin32, cygwin, darwin
# (WriteGuards' own rule, duplicated here per the spec's minimal-duplication
# note).
# ---------------------------------------------------------------------------
our $CASE_INSENSITIVE;

sub _is_ci {
    return $CASE_INSENSITIVE ? 1 : 0 if defined $CASE_INSENSITIVE;
    return ($^O =~ /\A(?:msys|MSWin32|cygwin|darwin)\z/) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# small local helpers.
# ---------------------------------------------------------------------------
sub _is_abs {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    return 1 if $p =~ m{^/};
    return 1 if $p =~ m{^[A-Za-z]:[\\/]};
    return 0;
}

# NAME_OK (spec sec 2.2): the shared name rule, equal to bp-spend's
# $name_ok -- the base regex, no leading '.', no '..' substring anywhere.
sub _name_ok {
    my ($v) = @_;
    return 0 unless defined $v && !ref($v) && $v =~ $NAME_RE;
    return 0 if substr($v, 0, 1) eq '.';
    return 0 if index($v, '..') >= 0;
    return 1;
}

# An in-flight member additionally requires its first character be
# alphanumeric (the director's _valid_name intersected with NAME_OK).
sub _member_ok {
    my ($v) = @_;
    return 0 unless _name_ok($v);
    return ($v =~ /\A[A-Za-z0-9]/) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Decision 98: a fixed, exact-match allowlist of authoring/reviewing agent
# types that are never subject to the one-ledger rule -- allowed with no
# Ledger line, and no binding written, regardless of how many packages are
# in flight or what the prompt contains. Case-sensitive, exact string match
# only (no near-miss widening -- see the oracle's "pinned" assertions).
# ---------------------------------------------------------------------------
my %EXEMPT_TYPE = map { ($_ => 1) }
    ('blueprint:bp-auditor', 'butler:bp-feedback-verifier', 'Explore', 'claude-code-guide');

sub _subagent_type_of {
    my ($p) = @_;
    my $ti = (ref $p->{tool_input} eq 'HASH') ? $p->{tool_input} : {};
    my $t = $ti->{subagent_type};
    return (defined $t && !ref($t)) ? $t : undef;
}

sub _is_exempt_type {
    my ($v) = @_;
    return 0 unless defined $v;
    return $EXEMPT_TYPE{$v} ? 1 : 0;
}

sub _tuid_of {
    my ($p) = @_;
    return undef unless ref $p eq 'HASH';
    my $t = $p->{tool_use_id};
    return (defined $t && !ref($t) && $t =~ $TUID_RE) ? $t : undef;
}

sub _read_json_file {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return undef unless defined $raw;
    return eval { JSON::PP->new->utf8->decode($raw) };
}

sub _write_bytes_atomic {
    my ($path, $bytes) = @_;
    my $dir = $path;
    $dir =~ s{/[^/]*\z}{};
    unless (-d $dir) { eval { require File::Path; File::Path::make_path($dir) } }
    return 0 unless -d $dir;
    my $tmp = "$path.tmp.$$";
    open(my $fh, '>:raw', $tmp) or return 0;
    my $ok = print {$fh} $bytes;
    $ok &&= close($fh);
    unless ($ok) { unlink $tmp; return 0 }
    return 1 if rename($tmp, $path);
    unlink $tmp;
    return 0;
}

# ---------------------------------------------------------------------------
# _resolve_data_dir($p) -- spec sec 2.4. Fix-batch LOW: BP_PROJECT_ROOT is
# honoured regardless of BP_LEDGER, so the driver-path hook (_handle_driver)
# and the ledger-path hook (_handle_ledger) resolve the SAME data dir the
# director does when only BP_PROJECT_ROOT is set (red-team L2).
# ---------------------------------------------------------------------------
sub _resolve_data_dir {
    my ($p) = @_;
    my $root = $ENV{BP_PROJECT_ROOT};
    if (defined $root && length $root && _is_abs($root)) {
        (my $r = $root) =~ tr{\\}{/};
        $r =~ s{/+\z}{};
        my $dd = "$r/.ccpraxis-local-data";
        return $dd if -d $dd;
    }
    return BpHook::data_dir($p);
}

# ---------------------------------------------------------------------------
# _inflight_members($data) -- spec sec 2.5. Returns a list of { bp, pkg },
# in file order, deduplicated (first of any duplicate pair wins).
# ---------------------------------------------------------------------------
sub _inflight_members {
    my ($data) = @_;
    (my $d = $data) =~ tr{\\}{/};
    $d =~ s{/+\z}{};

    my $inflight = _read_json_file("$d/.drive-solo/inflight.json");
    if (ref $inflight eq 'HASH' && ref $inflight->{packages} eq 'ARRAY') {
        my @members;
        my %seen;
        for my $e (@{ $inflight->{packages} }) {
            next unless ref $e eq 'HASH';
            my $bp  = $e->{blueprint};
            my $pkg = $e->{package};
            next unless _member_ok($bp) && _member_ok($pkg);
            my $key = "$bp\0$pkg";
            next if $seen{$key}++;
            push @members, { bp => $bp, pkg => $pkg };
        }
        return @members;
    }

    # Batch C (spec 16-cutover, sec 2.5): the current.json fallback is
    # deleted -- no inflight.json (or one that does not parse) means zero
    # members, never a seed from the retired pointer file.
    return ();
}

# ---------------------------------------------------------------------------
# _member_stale($data, $m) -> 1 | 0 -- bug 20261104-164548-2d3a. 1 iff this
# inflight.json member names a package whose ledger is gone or terminal, or
# whose blueprint is gone or parked: BpState::inflight_unbindable, the
# package-level subset of the rule bp-drive-next.pl's _prune_inflight uses.
# Fails toward 0 (not stale: the pre-fix behaviour) if BpState cannot be
# loaded, so a broken install never loosens anything by itself.
# ---------------------------------------------------------------------------
sub _member_stale {
    my ($data, $m) = @_;
    my $r = eval {
        require "$SELF_DIR/../BpState.pm"
            unless defined &BpState::inflight_unbindable;
        (my $d = $data) =~ tr{\\}{/};
        $d =~ s{/+\z}{};
        BpState::inflight_unbindable($d, $m->{bp}, $m->{pkg});
    };
    return (defined $r && $r ne '') ? 1 : 0;
}
sub member_stale { return _member_stale(@_) }

# ---------------------------------------------------------------------------
# _ledger_line($data, $bp, $pkg) -- spec sec 2.5: <L>/blueprints/<bp>/
# packages/<pkg>.md, where <L> is the basename of <data> after turning '\'
# into '/' and dropping trailing slashes.
# ---------------------------------------------------------------------------
sub _ledger_line {
    my ($data, $bp, $pkg) = @_;
    (my $b = $data) =~ tr{\\}{/};
    $b =~ s{/+\z}{};
    (my $L = $b) =~ s{.*/}{};
    return "$L/blueprints/$bp/packages/$pkg.md";
}

# ---------------------------------------------------------------------------
# _ledger_abs($data, $bp, $pkg) -- package 16 spec sec 2.5: the ABSOLUTE
# form "$data/blueprints/$bp/packages/$pkg.md" (never shown, only compared
# through canon()).
# ---------------------------------------------------------------------------
sub _ledger_abs {
    my ($data, $bp, $pkg) = @_;
    (my $b = $data) =~ tr{\\}{/};
    $b =~ s{/+\z}{};
    return "$b/blueprints/$bp/packages/$pkg.md";
}

# ---------------------------------------------------------------------------
# canon($s) -- package 16 spec sec 2.5: '\' -> '/'; a leading "/<letter>/"
# form ("/c/x") becomes "<letter>:/x"; ASCII case folded when _is_ci() is
# true. Both sides of an absolute-Ledger-line comparison are canon()-ed as
# UTF-8 byte strings (BpHook::_to_bytes). Nothing else is normalised.
# ---------------------------------------------------------------------------
sub canon {
    my ($s) = @_;
    return undef unless defined $s;
    my $v = BpHook::_to_bytes($s);
    $v =~ tr{\\}{/};
    $v =~ s{^/([A-Za-z])/}{$1:/};
    $v =~ tr/A-Z/a-z/ if _is_ci();
    return $v;
}

# ---------------------------------------------------------------------------
# _prompt_of($p) -- tool_input.prompt if a plain string, else '', with '\'
# folded to '/' (spec sec 3, B6).
# ---------------------------------------------------------------------------
sub _prompt_of {
    my ($p) = @_;
    my $ti = (ref $p->{tool_input} eq 'HASH') ? $p->{tool_input} : {};
    my $pr = $ti->{prompt};
    $pr = (defined $pr && !ref($pr)) ? $pr : '';
    $pr =~ tr{\\}{/};
    return $pr;
}

# ---------------------------------------------------------------------------
# _names_member($prompt, $bp, $pkg) -- spec sec 3, B6's exact match rule.
# ---------------------------------------------------------------------------
sub _names_member {
    my ($prompt, $bp, $pkg) = @_;
    my $pat = qr/(?<![A-Za-z0-9_.-])blueprints\/\Q$bp\E\/packages\/\Q$pkg\E\.md(?![A-Za-z0-9_-])/;
    return ($prompt =~ $pat) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# _fit_line($line) -- spec sec 3, B8: at most 160 characters; a longer line
# is cut to 157 characters plus '...'.
# ---------------------------------------------------------------------------
sub _fit_line {
    my ($l) = @_;
    return $l if length($l) <= 160;
    return substr($l, 0, 157) . '...';
}

# ---------------------------------------------------------------------------
# _deny($data, $members) -- spec sec 3, B8.
# ---------------------------------------------------------------------------
sub _deny {
    my ($data, $members) = @_;
    my $n = scalar @$members;
    my @lines = ("With $n packages in flight a dispatch prompt must name exactly one ledger path:");
    my $shown = $n > $MAX_LISTED ? $MAX_LISTED : $n;
    for my $i (0 .. $shown - 1) {
        push @lines, '  ' . _ledger_line($data, $members->[$i]{bp}, $members->[$i]{pkg});
    }
    push @lines, '  ...and ' . ($n - $MAX_LISTED) . ' more' if $n > $MAX_LISTED;
    @lines = map { _fit_line($_) } @lines;
    return BpHook::deny(@lines);
}

# ---------------------------------------------------------------------------
# Decision 67: the one-ledger rule reads ONLY an explicit labelled
# "Ledger: <path>" line -- never a bare mention anywhere else in the prompt
# (inputs, dependencies, quoted text). _has_ledger_signal is a cheap gate
# (red-team M1's fix is scoped to prompts that actually try to declare a
# ledger); _decl_lines extracts each candidate line's remainder, which must
# equal a member's ledger path EXACTLY (spec's own _ledger_line format) to
# count -- a ".md.lock"/".md~" suffix, or any other trailing text, is not an
# exact match and so never counts (closes red-team L5's false-name class).
# ---------------------------------------------------------------------------
sub _has_ledger_signal {
    my ($prompt) = @_;
    return (defined $prompt && $prompt =~ /ledger/i) ? 1 : 0;
}

sub _decl_lines {
    my ($prompt) = @_;
    my @out;
    # F7 (red-team L3): a CRLF prompt leaves a trailing "\r" inside the
    # captured remainder unless it is stripped alongside the plain
    # trailing whitespace here.
    while ($prompt =~ /^[ \t]*Ledger:[ \t]*(.*?)[ \t\r]*$/mgi) {
        push @out, $1;
    }
    return @out;
}

# _deny_labelled($data, $members, $kind) -- $kind is 'none' or 'many'; the
# two texts are worded distinctly (Decision 67) so a driver can tell which
# mistake it made.
sub _deny_labelled {
    my ($data, $members, $kind) = @_;
    my $n = scalar @$members;
    my $reason = ($kind eq 'many')
        ? 'too many Ledger: <path> lines were found'
        : 'no Ledger: <path> line names an in-flight package (none found)';
    my @lines = ("With $n packages in flight, $reason; add exactly one line \"Ledger: <path>\" naming:");
    my $shown = $n > $MAX_LISTED ? $MAX_LISTED : $n;
    for my $i (0 .. $shown - 1) {
        push @lines, '  ' . _ledger_line($data, $members->[$i]{bp}, $members->[$i]{pkg});
    }
    push @lines, '  ...and ' . ($n - $MAX_LISTED) . ' more' if $n > $MAX_LISTED;
    @lines = map { _fit_line($_) } @lines;
    return BpHook::deny(@lines);
}

# ---------------------------------------------------------------------------
# _gc_bindings($bdir) -- spec sec 2.3: every lookup file whose mtime is more
# than $LOOKUP_MAX_AGE in the past is unlinked. Red-team M2: the sweep itself
# is rate-limited through a $bdir/.gc-stamp file -- it runs at most once per
# $GC_INTERVAL, and only a bind that actually triggers a run touches the
# stamp. It also collects crash leftovers ("<tuid>.json.tmp.<pid>" from a
# write killed between open and rename), not just "*.json".
# ---------------------------------------------------------------------------
sub _gc_bindings {
    my ($bdir) = @_;
    return unless -d $bdir;
    my $now   = time();
    my $stamp = "$bdir/.gc-stamp";
    my @sst   = stat($stamp);
    if (@sst && defined $sst[9] && ($now - $sst[9]) < $GC_INTERVAL) {
        return; # rate-limited: a sweep already ran within the window
    }
    opendir(my $dh, $bdir) or return;
    for my $e (readdir $dh) {
        next unless $e =~ /\.json(?:\.tmp\.\d+)?\z/;
        my $full = "$bdir/$e";
        my @st = stat($full);
        next unless @st;
        my $mtime = $st[9];
        next unless defined $mtime;
        unlink $full if ($now - $mtime) > $LOOKUP_MAX_AGE;
    }
    closedir $dh;
    open(my $sfh, '>>', $stamp) or return;
    close $sfh;
    utime($now, $now, $stamp);
    return;
}

# ---------------------------------------------------------------------------
# _append_history($dsdir, $line) -- spec sec 2.3: roll bindings.jsonl to
# bindings.jsonl.1 (replacing any previous roll) when its size exceeds
# $HISTORY_ROLL_BYTES, THEN append this line under O_APPEND. Red-team L1: the
# stat-then-rename-then-append sequence is serialized behind an flock on
# $dsdir/bindings.lock, so two concurrent binders can never both observe
# "over threshold" and each roll a file the other already rolled (which
# would drop the just-rolled 8 MiB on the floor).
# ---------------------------------------------------------------------------
sub _append_history {
    my ($dsdir, $line) = @_;
    unless (-d $dsdir) { eval { require File::Path; File::Path::make_path($dsdir) } }
    return unless -d $dsdir;

    my $lockfile = "$dsdir/bindings.lock";
    open(my $lockfh, '>>', $lockfile) or return;
    unless (flock($lockfh, LOCK_EX)) { close $lockfh; return }

    my $file = "$dsdir/bindings.jsonl";
    my $sz = (-f $file) ? (-s $file) : 0;
    $sz = 0 unless defined $sz;
    if ($sz > $HISTORY_ROLL_BYTES) {
        # DRIVER RULING (fix-batch): .1 holds exactly the previous
        # generation, bounded -- rename REPLACES it, never appends. The
        # flock above (held for the whole stat-then-rename-then-append
        # sequence) is what prevents the race's losses: two concurrent
        # binders can never both observe "over threshold" and each roll a
        # file the other already rolled.
        my $prev = "$dsdir/bindings.jsonl.1";
        unlink $prev if -e $prev;
        rename($file, $prev);
    }
    my $ok = sysopen(my $fh, $file, O_WRONLY | O_APPEND | O_CREAT);
    if ($ok) {
        binmode($fh, ':raw');
        syswrite($fh, $line);
        close $fh;
    }

    flock($lockfh, LOCK_UN);
    close $lockfh;
    return;
}

# ---------------------------------------------------------------------------
# _bind($data, $bp, $pkg, $p, $tuid) -- spec sec 2.3: write the lookup file
# atomically, append the history line, GC old lookup files. Never dies.
# ---------------------------------------------------------------------------
sub _bind {
    my ($data, $bp, $pkg, $p, $tuid) = @_;
    return unless defined $data && length $data;
    (my $d = $data) =~ tr{\\}{/};
    $d =~ s{/+\z}{};
    my $dsdir = "$d/.drive-solo";
    my $bdir  = "$dsdir/bindings";
    unless (-d $bdir) { eval { require File::Path; File::Path::make_path($bdir) } }
    return unless -d $bdir;

    my $stype = '';
    my $ti = (ref $p->{tool_input} eq 'HASH') ? $p->{tool_input} : {};
    if (defined $ti->{subagent_type} && !ref($ti->{subagent_type}) && $ti->{subagent_type} =~ $TYPE_RE) {
        $stype = $ti->{subagent_type};
    }
    my $sid = eval { BpHook::session_id($p) };
    $sid = (defined $sid) ? $sid : '';

    my $rec = {
        tool_use_id   => $tuid,
        blueprint     => $bp,
        package       => $pkg,
        subagent_type => $stype,
        session_id    => $sid,
        source        => 'bind-dispatch',
        at            => time(),
    };
    my $json = eval { JSON::PP->new->utf8->canonical->encode($rec) };
    return unless defined $json;
    my $line = $json . "\n";

    _write_bytes_atomic("$bdir/$tuid.json", $line);
    _append_history($dsdir, $line);
    _gc_bindings($bdir);
    return;
}

# ---------------------------------------------------------------------------
# bound_since($data, $bp, $pkg, $since) -> 1 | 0 -- spec sec 3.5, a pure
# reader for the director. Fails toward 1 ("driven") when a history file
# exists but cannot be opened.
#
# Review M1 / red-team M3: a full JSON::PP decode of every line, while the
# director holds inflight.lock, costs ~16s at full history size (measured).
# Fixed here with: (a) an index() prefilter on the two field values before
# ever decoding -- both fields are written canonically (BindDispatch's own
# _bind()), so the substring form is stable; (b) one JSON::PP decoder
# instance reused across every candidate line, instead of a fresh
# ->new->utf8 per line; (c) bindings.jsonl (the more likely place for a
# recent match) is read before bindings.jsonl.1; (d) each file's lines are
# walked newest-first (a plain reverse of an append-ordered file), so once a
# candidate line's `at` is < $since, every remaining (older, because
# append-ordered) line in that file is too -- last() out of that file
# immediately rather than decoding the rest.
# ---------------------------------------------------------------------------
sub bound_since {
    my ($data, $bp, $pkg, $since) = @_;
    return 0 unless defined $data && defined $bp && defined $pkg;
    return 0 unless defined $since && $since =~ /\A-?\d+\z/;
    (my $d = $data) =~ tr{\\}{/};
    $d =~ s{/+\z}{};
    my $dsdir = "$d/.drive-solo";
    my $json        = JSON::PP->new->utf8;
    my $pkg_needle  = qq("package":"$pkg");
    my $bp_needle   = qq("blueprint":"$bp");
    for my $file ("$dsdir/bindings.jsonl", "$dsdir/bindings.jsonl.1") {
        next unless -e $file;
        open(my $fh, '<:raw', $file) or return 1;
        my @lines = <$fh>;
        close $fh;
        for my $line (reverse @lines) {
            next if length($line) > 4096;
            next unless index($line, $pkg_needle) >= 0;
            next unless index($line, $bp_needle) >= 0;
            (my $l = $line) =~ s/\r?\n\z//;
            my $rec = eval { $json->decode($l) };
            next unless ref $rec eq 'HASH';
            next unless defined $rec->{blueprint} && !ref($rec->{blueprint}) && $rec->{blueprint} eq $bp;
            next unless defined $rec->{package} && !ref($rec->{package}) && $rec->{package} eq $pkg;
            next unless defined $rec->{at} && !ref($rec->{at}) && $rec->{at} =~ /\A-?\d+\z/;
            return 1 if ($rec->{at} + 0) >= $since;
            last; # append-ordered: earlier lines in THIS file are only older
        }
    }
    return 0;
}

# ---------------------------------------------------------------------------
# _handle_ledger($p) -- spec sec 3, B2.
# ---------------------------------------------------------------------------
sub _handle_ledger {
    my ($p) = @_;
    my $bp  = $ENV{BP_BLUEPRINT};
    my $pkg = $ENV{BP_PACKAGE};
    return 0 unless _name_ok($bp) && _name_ok($pkg);
    my $tuid = _tuid_of($p);
    return 0 unless defined $tuid;
    my $data = _resolve_data_dir($p);
    return 0 unless defined $data && length $data;
    _bind($data, $bp, $pkg, $p, $tuid);
    return 0;
}

# ---------------------------------------------------------------------------
# _decide_driver($p) -- F1 (review B1, blocker): the decision half of
# _handle_driver, factored out as a PURE function -- no writes (never calls
# _bind), no prints (never calls _deny/_deny_labelled). Same inputs, same
# verdict, spec sec 3 B3-B8 plus Decision 67 and the fix-batch LOWs.
#
# Returns a hashref:
#   { verdict => 'allow' }                                  -- nothing to bind
#   { verdict => 'allow', data => $d, bp => $b, pkg => $p }  -- bind this one
#   { verdict => 'deny', kind => 'none'|'many'|'named', data => $d,
#     members => \@members }
#
# TrackDispatch's _driver_pre calls this (via would_deny(), below) with the
# SAME payload bind-dispatch itself sees, to learn whether bind-dispatch
# would deny this dispatch -- without performing any of bind-dispatch's own
# side effects itself.
# ---------------------------------------------------------------------------
sub _decide_driver {
    my ($p) = @_;

    # Decision 98: an exempt subagent_type is allowed outright -- no bind,
    # no ledger check, before any of the data-dir/inflight machinery below.
    return { verdict => 'allow' } if _is_exempt_type(_subagent_type_of($p));

    my $data = _resolve_data_dir($p); # LOW: same resolution as the director

    return { verdict => 'allow' } unless defined $data && length $data;

    # Bug 20261104-164548-2d3a: an inflight.json entry that is stale (ledger
    # terminal or gone, blueprint parked or gone: BpState::inflight_unbindable,
    # shared with the director's prune) is never auto-bound. The set used to
    # keep such an entry after the run finished, and every later dispatch
    # was bound to it; the binding record outlives the set, so those
    # subagents stayed refused (WriteGuards' refused_bound) even after the
    # set was emptied. Stale entries drop out of the auto-bind count.
    #
    # The one exception keeps Decision 69 A3: a dispatch whose labelled
    # "Ledger:" line names a stale member explicitly is decided over the
    # UNFILTERED set, exactly as before this fix, so it is still bound to
    # that package and its edits are still refused.
    my @all_members = _inflight_members($data);
    my (@members, @stale);
    for my $m (@all_members) {
        if (_member_stale($data, $m)) { push @stale, $m } else { push @members, $m }
    }
    if (@stale) {
        my $prompt0 = _prompt_of($p);
        if (_has_ledger_signal($prompt0)) {
            my $names_stale = 0;
            for my $decl (_decl_lines($prompt0)) {
                for my $m (@stale) {
                    if ($decl eq _ledger_line($data, $m->{bp}, $m->{pkg})
                        || canon($decl) eq canon(_ledger_abs($data, $m->{bp}, $m->{pkg}))) {
                        $names_stale = 1;
                        last;
                    }
                }
                last if $names_stale;
            }
            @members = @all_members if $names_stale;
        }
    }
    my $n = scalar @members;
    return { verdict => 'allow' } if $n == 0;

    if ($n == 1) {
        my $tuid = _tuid_of($p);
        return { verdict => 'allow' } unless defined $tuid;
        return { verdict => 'allow', data => $data, bp => $members[0]{bp}, pkg => $members[0]{pkg} };
    }

    # Batch C (spec 16-cutover, sec 2.5): the switch is gone. With two or
    # more members, an ambiguous or no-match prompt is always denied -- the
    # "bind the first member instead of denying" fallback no longer exists.
    my $prompt = _prompt_of($p);

    # Decision 67: once the prompt tries to declare a ledger at all, ONLY a
    # labelled "Ledger: <path>" line (exact match) counts -- a bare mention
    # elsewhere in the prompt is ignored, closing red-team M1's
    # wrong-package-bound-then-reclaimed reproduction.
    if (_has_ledger_signal($prompt)) {
        my @decls = _decl_lines($prompt);
        my @valid;
        my %seen_valid;
        for my $decl (@decls) {
            for my $m (@members) {
                if ($decl eq _ledger_line($data, $m->{bp}, $m->{pkg})
                    || canon($decl) eq canon(_ledger_abs($data, $m->{bp}, $m->{pkg}))) {
                    # F7 (red-team L2): the SAME member named twice (its
                    # relative and absolute forms) counts as ONE, not two.
                    push @valid, $m unless $seen_valid{"$m->{bp}\0$m->{pkg}"}++;
                    last;
                }
            }
        }
        if (@valid == 1) {
            my $tuid = _tuid_of($p);
            return { verdict => 'allow' } unless defined $tuid;
            return { verdict => 'allow', data => $data, bp => $valid[0]{bp}, pkg => $valid[0]{pkg} };
        }
        return { verdict => 'deny', kind => (@valid == 0 ? 'none' : 'many'), data => $data, members => \@members };
    }

    my @named = grep { _names_member($prompt, $_->{bp}, $_->{pkg}) } @members;
    if (@named == 1) {
        my $tuid = _tuid_of($p);
        return { verdict => 'allow' } unless defined $tuid;
        return { verdict => 'allow', data => $data, bp => $named[0]{bp}, pkg => $named[0]{pkg} };
    }

    return { verdict => 'deny', kind => 'named', data => $data, members => \@members };
}

# ---------------------------------------------------------------------------
# _handle_driver($p) -- runs _decide_driver's verdict: binds on allow,
# denies (prints) on deny.
# ---------------------------------------------------------------------------
sub _handle_driver {
    my ($p) = @_;
    my $d = _decide_driver($p);

    if ($d->{verdict} eq 'deny') {
        return $d->{kind} eq 'named'
            ? _deny($d->{data}, $d->{members})
            : _deny_labelled($d->{data}, $d->{members}, $d->{kind});
    }

    if (defined $d->{data} && defined $d->{bp} && defined $d->{pkg}) {
        my $tuid = _tuid_of($p);
        _bind($d->{data}, $d->{bp}, $d->{pkg}, $p, $tuid) if defined $tuid;
    }
    return 0;
}

# ---------------------------------------------------------------------------
# would_deny($p) -- F1 public accessor: 1 iff a driver-role Task/Agent
# dispatch with this exact payload would be denied by bind-dispatch's own
# run(), 0 otherwise (including every "not applicable" case -- not a
# driver session, BP_LEDGER set, not Task/Agent, etc). Pure: no writes, no
# prints. Wrapped in eval so any unforeseen exception fails toward 0
# (never deny something bind-dispatch itself would have allowed).
# ---------------------------------------------------------------------------
sub would_deny {
    my ($p) = @_;
    my $ok = eval {
        return 0 unless BpHook::payload_ok();
        return 0 unless ref $p eq 'HASH';
        my $tool = $p->{tool_name};
        return 0 unless defined $tool && !ref($tool) && ($tool eq 'Task' || $tool eq 'Agent');
        my $ledger = $ENV{BP_LEDGER};
        return 0 if defined $ledger && length $ledger; # ledger path never denies
        my $role = eval { BpHook::role($p) };
        return 0 unless defined $role && $role eq 'driver';
        my $d = _decide_driver($p);
        return ($d->{verdict} eq 'deny') ? 1 : 0;
    };
    return (defined $ok && $ok) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# run($p, @args) -> 0 | 2. Never calls exit; wrapped in eval so any
# unforeseen exception fails open (spec sec 3, B10).
# ---------------------------------------------------------------------------
sub run {
    my ($p, @args) = @_;
    my $ret = eval { _run($p, @args) };
    return (defined $ret && $ret == 2) ? 2 : 0;
}

sub _run {
    my ($p, @args) = @_;

    return 0 unless BpHook::payload_ok();
    return 0 unless ref $p eq 'HASH';

    my $tool = $p->{tool_name};
    return 0 unless defined $tool && !ref($tool) && ($tool eq 'Task' || $tool eq 'Agent');

    if (exists $p->{hook_event_name}) {
        my $ev = $p->{hook_event_name};
        my $is_pre = defined $ev && !ref($ev) && $ev eq 'PreToolUse';
        return 0 unless $is_pre;
    }

    my $ledger = $ENV{BP_LEDGER};
    if (defined $ledger && length $ledger) {
        return _handle_ledger($p);
    }

    my $role = eval { BpHook::role($p) };
    return 0 unless defined $role && $role eq 'driver';

    return _handle_driver($p);
}

# ---------------------------------------------------------------------------
# Public accessors (package 16 spec sec 2.5) -- same behaviour as the
# private subs they wrap; the private names stay, so WriteGuards.pm calls
# only these.
# ---------------------------------------------------------------------------
sub member_ok        { return _member_ok(@_) }
sub is_exempt_type    { return _is_exempt_type(@_) }
# exempt_types() -- Decision 101 M1: the WHOLE allowlist, enumerable, so a
# new entry added to %EXEMPT_TYPE breaks a test on purpose instead of
# staying invisible behind is_exempt_type()'s one-string-at-a-time answer.
sub exempt_types      { return sort keys %EXEMPT_TYPE }
sub resolve_data_dir { return _resolve_data_dir(@_) }
sub inflight_members { return _inflight_members(@_) }
# would_deny is defined above, next to _decide_driver, so it shares the
# same "pure, no writes, no prints" contract documentation.

1;
