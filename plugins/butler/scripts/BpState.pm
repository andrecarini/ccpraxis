package BpState;
# BpState.pm — pure reader of the two authoritative status stores: package
# ledger frontmatter ('packages/<pkg>.md''s 'status:' line) and the
# orchestrator run marker ('runs/.orchestrator') — spec
# .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/specs/
# s01-status-read-api-spec.md.
#
# Pure and total with respect to BpState's OWN code and its own inputs
# (paths, file contents, including undef): never raises a fatal exception on
# any such input, no clock (time/gmtime/localtime), no invoking other
# processes or executables, no replacing or branching this process, no
# signalling another process — process liveness is delegated entirely to a
# caller-injected $alive_fn coderef (mandatory for
# run_is_live/blueprint_lifecycle; BpState never supplies a default prober,
# which would reintroduce a signal-0 probe and its known false-negative on
# native Windows processes). Every function returns its declared type for
# every input; nothing under $bpdir is ever written.
#
# ONE DELIBERATE EXCEPTION to totality, found in the s01 fix-batch step-7
# red-team (M3): if the caller-supplied $alive_fn itself dies when called,
# that exception propagates out of run_is_live/blueprint_lifecycle
# uncaught. This is BY DESIGN, not an oversight -- do not wrap the call in
# eval to "complete" totality. Catching it would force some verdict, and
# for run_is_live the only sane fallback verdict is "not live" (0), which is
# the SETTLED direction Decision 6 forbids resolving uncertainty toward: a
# caller whose liveness probe is broken should see that loudly, not have
# BpState quietly launder it into a false "the run is dead." BpState cannot
# know why $alive_fn died, so guessing "dead" is the dangerous guess, not
# the safe one. Totality is a promise about BpState's own logic; a
# caller-supplied coderef that misbehaves is the caller's failure to
# surface, not BpState's to hide.
#
# opendir/readdir only, never glob — glob splits its argument on whitespace
# and silently drops fragments for paths containing spaces, a real landmine
# on this machine. This module never assumes an ASCII path.
#
# Nothing is exported; callers use fully-qualified names
# (BpState::package_status(...), etc.), mirroring RunState.pm's convention
# (plugins/sandbox/scripts/RunState.pm:1-37).
#
# fm_get, marker_pid, bp_meta_get and norm_bp_status below are lifted
# verbatim from bp-lifecycle.pl (see spec §1.2 for exact line citations).
# norm_pkg_status is the one deliberate variant of bp-lifecycle.pl's
# norm_status: the whitelist gains 'converging', a real mid-flight ledger
# value bp-lifecycle.pl's own vocabulary does not need but BpState's callers
# (s02-s04) do, per the spec §1/§2.1 driver ruling.

use strict;
use warnings;

# ------------------------------------------------------------------- io ------

sub _slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# --------------------------------------------------------- frontmatter I/O ---

# Lifted verbatim from bp-lifecycle.pl:155-166 (fm_get). Reads a 'key:' value
# from inside the FIRST '---'-delimited block only; text outside that block
# (including a 'status:'-looking line in prose) is never matched.
sub fm_get {
    my ($path, $key) = @_;
    my $c = _slurp($path);
    return undef unless defined $c;
    my $in = 0;
    for my $ln (split /\n/, $c) {
        if ($ln =~ /^---\s*\z/) { $in++; last if $in == 2; next }
        next unless $in == 1;
        if ($ln =~ /^\Q$key\E:\s*(.*?)\s*\z/) { return $1 }
    }
    return undef;
}

# VARIANT of bp-lifecycle.pl's norm_status (bp-lifecycle.pl:171-181): the
# whitelist gains 'converging'. Same decoration-stripping/lowercase steps.
#
# DELIBERATE FORK from bp-lifecycle.pl:177-179's norm_status, found and fixed
# in this package's fix-batch step 7 (s01 red-team M1): the original scans
# split(/\s+/) word-by-word and returns the FIRST word that matches a known
# status, so a NEGATED or compound value word-scans past its own negation --
# 'not-done' normalises to the words ('not','done') and the loop returns
# 'done'; 'not-archived-yet' returns 'archived'. That resolves an unknown or
# explicitly-negated value toward a SETTLED status, which is exactly what
# this blueprint's Decision 6 forbids ("uncertainty resolves toward LIVE,
# never toward settled") -- earned the hard way by shipping the inverse bug
# three times in one session. bp-lifecycle.pl's copy still has this bug;
# it is intentionally NOT fixed here (out of this write set, Decision 15;
# the driver is handling bp-lifecycle.pl separately). s02-s04: do NOT
# "restore parity" with bp-lifecycle.pl's norm_status by reverting this to a
# word-scan -- that would reintroduce the bug BpState was forked to avoid.
#
# The fix: match the WHOLE normalised (decoration-stripped, lowercased,
# trimmed) value against the whitelist, not its first word. A multi-word or
# negated value (e.g. 'not done', 'not-archived-yet' -> 'not archived yet')
# therefore never equals a single whitelist word and correctly falls through
# to '' (which package_status then collapses to the non-terminal 'pending'
# per spec §2.2), instead of being misread as the terminal word it merely
# contains. A genuinely single-word decorated value (e.g. '✅ done') still
# normalises to exactly 'done' and matches as before.
sub norm_pkg_status {
    my ($s) = @_;
    return '' unless defined $s;
    $s = lc $s;
    $s =~ s/[^a-z]+/ /g;
    $s =~ s/\A\s+|\s+\z//g;
    return $s =~ /\A(?:done|pending|running|reviewing|blocked|parked|dropped|converging)\z/
        ? $s
        : '';
}

# ----------------------------------------------------------- marker/pid ------

# Lifted verbatim from bp-lifecycle.pl:185-194 (marker_pid).
sub marker_pid {
    my ($path) = @_;
    return undef unless -e $path;
    my $c = _slurp($path);
    return undef unless defined $c;
    return undef if length($c) > 4096;      # a marker is a pid, not a document
    $c =~ s/\s+//g;
    return undef unless $c =~ /\A[0-9]+\z/ && $c > 0;
    return $c + 0;
}

# ------------------------------------------------------- blueprint.md API ----

# Lifted verbatim from bp-lifecycle.pl:530-541 (bp_meta_get). Reads a 'field:'
# value from blueprint.md's FENCED metadata block (a triple-backtick-delimited
# code fence), a different shape from a package ledger's '---'-delimited
# frontmatter.
sub bp_meta_get {
    my ($file, $field) = @_;
    my $c = _slurp($file);
    return undef unless defined $c;
    my $f = quotemeta $field;
    # Fence marker built via chr() rather than written literally: a triple
    # backtick character is itself a banned token in this module's own
    # source (checks:no-shell-capture), so it cannot appear as a literal.
    my $fence = chr(96) x 3;
    my $fence_q = quotemeta $fence;
    return undef unless $c =~ /^$fence_q\s*\n((?:.*\n)*?)^$fence_q\s*$/m;
    my $block = $1;
    return undef unless $block =~ /^$f:[ \t]*([^\n#]*)/m;
    my $v = $1;
    $v =~ s/\s+\z//;
    return $v;
}

# Lifted from bp-lifecycle.pl:546-556 (norm_bp_status), with the SAME
# whole-value-match deviation as norm_pkg_status above (see that comment for the
# full M1 rationale) -- the original's word-scan has the identical
# negation-inversion bug ('not-archived' -> first matching word 'archived').
# Not fixed in bp-lifecycle.pl itself (out of this write set); do not
# "restore parity" here in a later package.
sub norm_bp_status {
    my ($s) = @_;
    return '' unless defined $s;
    $s = lc $s;
    $s =~ s/#.*\z//;                       # the template keeps a trailing comment
    $s =~ s/[^a-z]+/ /g;
    $s =~ s/\A\s+|\s+\z//g;
    return $s =~ /\A(?:drafting|audited|running|done|archived)\z/
        ? $s
        : '';
}

# ------------------------------------------------------------- public API ----

# package_status($bpdir, $pkg) -> $status
# One of PKG_ALL: pending running converging reviewing done blocked parked
# dropped (eight words — spec §2.1/§1 driver ruling). Malformed/missing/
# unrecognised input collapses to 'pending' (the least-committed, non-
# terminal default), never to a crash or an "unknown" bucket — spec §2.2.
sub package_status {
    my ($bpdir, $pkg) = @_;
    return 'pending' unless defined $bpdir && defined $pkg && length $pkg;
    # $pkg is trusted caller input (a package id, not raw filesystem/user
    # input) -- no path-traversal sanitisation here. Reviewer flagged this
    # as a MINOR/NIT in the s01 fix-batch step-7 review; not a regression
    # (no such sanitisation existed before this package) and out of scope
    # to add now (Decision 15: s01 introduces no new caller-facing hardening
    # beyond the spec). Left as-is deliberately.
    my $path = "$bpdir/packages/$pkg.md";
    my $raw  = fm_get($path, 'status');
    my $word = norm_pkg_status($raw);
    return length($word) ? $word : 'pending';
}

# all_package_statuses($bpdir) -> \%pkg_to_status
# {} if packages/ is absent, unreadable, or empty. '.lock' files and
# directory entries contribute no key — lifted parity with
# bp-lifecycle.pl:206-221 (read_ledgers).
sub all_package_statuses {
    my ($bpdir) = @_;
    my %result;
    return \%result unless defined $bpdir;
    my $dir = "$bpdir/packages";
    opendir(my $dh, $dir) or return \%result;
    for my $f (sort readdir $dh) {
        # Case-insensitive extension match (s01 fix-batch step-7 M2): the
        # original case-sensitive /\.md\z/ silently dropped a 'p2.MD'
        # ledger from the result on Windows' case-insensitive filesystem --
        # driver-reproduced. A hidden 'running' package can then flip
        # blueprint_lifecycle to 'done' while real work is outstanding.
        # Same case-insensitivity applies to the .lock exclusion, or a
        # 'p.LOCK' file would newly be miscounted as a package.
        next unless $f =~ /\.md\z/i;
        next if $f =~ /\.lock\z/i;
        my $path = "$dir/$f";
        next unless -f $path;
        (my $pkg = $f) =~ s/\.md\z//i;
        $result{$pkg} = package_status($bpdir, $pkg);
    }
    closedir $dh;
    return \%result;
}

# orchestrator_pid($bpdir) -> $pid | undef
# Lifted verbatim from marker_pid, applied to runs/.orchestrator.
sub orchestrator_pid {
    my ($bpdir) = @_;
    return undef unless defined $bpdir;
    return marker_pid("$bpdir/runs/.orchestrator");
}

# run_is_live($bpdir, $alive_fn) -> 0 | 1
# $alive_fn is a mandatory coderef, sub($pid) -> truthy|falsy. If it is not a
# coderef, returns 0 and never calls it. Never falls back to a signal-0
# probe of its own — that probe is a known false-negative for a live native
# process on Windows, which is exactly why the check is caller-injected.
# If $alive_fn IS a coderef but dies when invoked, that exception propagates
# out of this function uncaught — deliberate, not swallowed; see the M3
# rationale in the module header comment (resolving a broken probe to "not
# live" would itself be a settled-direction guess this module refuses to
# make on the caller's behalf).
sub run_is_live {
    my ($bpdir, $alive_fn) = @_;
    return 0 unless defined $bpdir;
    return 0 unless -e "$bpdir/runs/.orchestrator";
    my $pid = orchestrator_pid($bpdir);
    return 0 unless defined $pid;
    return 0 unless ref($alive_fn) eq 'CODE';
    return $alive_fn->($pid) ? 1 : 0;
}

# blueprint_lifecycle($bpdir, $alive_fn) -> $lifecycle
# One of drafting|audited|running|done|archived. Precedence, first match
# wins (spec §2.4, a design decision assembled from reconcile_one's prose
# logic, not verbatim source):
#   1. a live run beats every authored value, including archived.
#   2. authored 'archived' beats the delivered computation (never
#      re-derived to done).
#   3. 'done' requires BOTH all-delivered (>=1 package, every value in
#      {done,dropped}) AND the ADVANCEABLE gate: authored in
#      {audited,running} (bp-lifecycle.pl:99-103's %ADVANCEABLE).
#   4. authored 'drafting' -> drafting; authored 'audited' -> audited.
#   5. final default 'drafting' — blueprint.md absent/unreadable, authored
#      '', or a stale/unconfirmed 'running'/'done' on disk (pre-s04) is
#      treated as ABSENT per Decision 13, never surfaced literally.
sub blueprint_lifecycle {
    my ($bpdir, $alive_fn) = @_;
    return 'drafting' unless defined $bpdir;

    return 'running' if run_is_live($bpdir, $alive_fn);

    my $authored = norm_bp_status(bp_meta_get("$bpdir/blueprint.md", 'status'));

    return 'archived' if $authored eq 'archived';

    my $statuses  = all_package_statuses($bpdir);
    my @values    = values %$statuses;
    my $all_delivered =
        (scalar(@values) > 0)
        && !(grep { $_ ne 'done' && $_ ne 'dropped' } @values);

    if ($all_delivered && ($authored eq 'audited' || $authored eq 'running')) {
        return 'done';
    }

    # The authored word survives when the work is not all delivered. Note the
    # shape of these three lines: EVERY authored value keeps itself here. The
    # running branch was missing until 2026-08-14 (s04, driver-adjudicated), so
    # running was the one authored value with no branch of its own and it fell
    # through to the catch-all below -- silently DEMOTING a blueprint the author
    # had marked running, with real work in flight, to drafting, i.e. to "not
    # started".
    #
    # Found when s04 wired this function in as the single authority and its
    # oracle asserted "an undelivered package keeps lifecycle at the authored
    # word" (t/101, observable-6). The implementer read the disagreement the
    # other way -- test wrong, code right -- and flagged it rather than editing
    # the immutable oracle, which is why it was caught. The asymmetry is the
    # tell: drafting and audited each kept themselves, running did not.
    #
    # No backticks anywhere in this file, including comments: t/98's DC1 scans
    # the whole source for them, because this module must never shell out.
    return 'drafting' if $authored eq 'drafting';
    return 'audited'  if $authored eq 'audited';
    return 'running'  if $authored eq 'running';

    # Unknown or absent authored value. Not a demotion -- there is nothing to
    # demote, because nothing legible was authored.
    return 'drafting';
}

1;
