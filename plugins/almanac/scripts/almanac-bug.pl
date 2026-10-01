#!/usr/bin/env perl
# almanac-bug.pl — ccpraxis bug reports filed BY agents working in other projects.
#
# THE PROBLEM. An agent hits a ccpraxis tooling defect while working in some
# unrelated project. Today that observation dies with the session: it is prose
# in a transcript nobody re-reads. There is no path from "the tooling failed me
# here" to "ccpraxis knows about it".
#
# THE SHAPE. One file per report, written ONLY through this script, in a small
# state machine that freezes a report once ccpraxis has picked it up:
#
#   open  ->  triaging  ->  taken  ->  resolved | declined
#
# `open` is the reporter's: they may keep editing while nobody has looked. From
# `triaging` onward the content is FROZEN — the filer cannot rewrite history
# under a triager who is mid-read, and a `taken` report cannot be quietly
# reworded after the fact.
#
# RENAME (package 12, 12-bug-claimant-and-triaging, Decision 31): the state
# formerly called `reviewing` is now `triaging`, and moving a report into it is
# a CLAIM — the claiming session's identity is recorded, read from a butler
# hook ticket (BpHook::take_ticket), never from a CLI argument. Only the
# claimant can move the report on or back to `open`; a claim with no
# transcript or older than 24h is stale and reported by list/collect/doctor,
# and recoverable with the `takeover` verb. A report whose on-disk status is
# still the old name `reviewing` is read, on every load, as a claimless
# `triaging` — never rewritten by a mere read; see AlmanacBug::load.
#
# THREE LAYERS OF IMMUTABILITY, because two are bypassable:
#   1. this script refuses a content change once frozen;
#   2. a PreToolUse hook denies Edit/Write against the reports directory, so the
#      script is the only sanctioned writer (same pattern as
#      guard-blueprint-write.sh);
#   3. a sha256 recorded at freeze time DETECTS an out-of-band edit anyway —
#      `verify` reports it. Layers 1 and 2 can be routed around by a determined
#      Bash call; layer 3 cannot, because it does not rely on preventing the
#      write.
#
# WHERE THINGS LIVE. Reports sit in the project they were filed from, so they
# travel with the context that produced them, and with nothing else:
#   <project>/.ccpraxis-local-data/bug-reports/<id>.md
# There is NO index — see the note above known_projects(). Cross-project
# discovery walks steward's machine-local project registry, the same one
# /steward:backup walks, so a sandboxed filer needs no access to the host.

package AlmanacBug;
use strict;
use warnings;
use JSON::PP ();
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
use Cwd ();

# Almanac::Lock sits beside this script, and it is found from THIS FILE's own
# path rather than from $0 or FindBin. Both of those are the invoking program,
# which is not the same thing: the tests load this script in-process with
# `do $A`, where $0 is the .t file and FindBin would resolve to the tests
# directory. __FILE__ is this file wherever it was loaded from, so `perl -c`
# from the repo root, `perl -c` from plugins/almanac/tests/, a CLI run and a
# `do` all resolve the same module.
BEGIN {
    my $dir = __FILE__;
    $dir =~ s{\\}{/}g;
    $dir =~ s{/[^/]+\z}{};
    $dir = '.' unless length $dir;
    unshift @INC, $dir;
}
use Almanac::Lock ();

# Set by _write_atomic on every failure, cleared at its entry. cas_write
# reports it rather than a bare "write failed", so a rename that exhausted its
# retry deadline is named as that.
our $LAST_ERROR = '';

our @STATES = qw(open triaging taken resolved declined);

# Closed vocabulary for `severity`. `unknown` is IN it — it is the script's own
# default (see `file`'s `$o{severity} // 'unknown'`), and an enum that rejected
# its own default would make `file` fail whenever `--severity` is omitted.
our @SEVERITIES = qw(low medium high blocker unknown);
sub valid_severity { my ($s) = @_; return scalar grep { $_ eq $s } @SEVERITIES }
our %NEXT = (
    open     => [qw(triaging declined)],
    triaging => [qw(taken open declined)],   # back to open = "not ready, keep editing"
    taken    => [qw(resolved declined)],
    resolved => [],
    declined => [],
);
# Content is editable ONLY in these states.
our %MUTABLE = (open => 1);
# On-disk legacy name -> current name. Applied ONLY on read (AlmanacBug::load);
# the bytes on disk are never batch-rewritten (spec sec 2.2).
our %LEGACY_STATUS = (reviewing => 'triaging');
# A triaging claim older than this (seconds) is stale (spec sec 2.6). 24h.
our $CLAIM_STALE_SECONDS = 86400;

sub _now { time }
sub _iso { my @t = gmtime($_[0] // time);
           sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5]+1900,$t[4]+1,$t[3],$t[2],$t[1],$t[0]) }

# THERE IS NO INDEX, and the reason is worth keeping.
#
# The first design wrote an append-only index under the writer's $HOME so
# `collect` could find reports across projects. That is broken for the primary
# filer. A sandboxed agent's $HOME/.claude IS the project's own
# .ccpraxis-local-data/claude-home (bind-mounted to /root/.claude), so its index
# write lands inside that one project and never reaches the host at all — the
# machine-wide index would silently miss exactly the reports it exists to
# collect. It also wrote into ~/.claude/ccpraxis, the live install's git tree,
# which blocked a promotion pull.
#
# The report FILE in the project is the only durable state, and steward already
# solves discovery: ~/.claude/claude-code-vault/.registry-local.json maps slug ->
# absolute project path on this machine, and is deliberately gitignored inside
# the vault because those paths are machine-local. That registry is what
# /steward:backup walks, so `collect` walks it too.
sub registry_path {
    my $home = $ENV{ALMANAC_HOME} // $ENV{HOME} // $ENV{USERPROFILE} // '.';
    return "$home/.claude/claude-code-vault/.registry-local.json";
}

# known_projects() -> list of absolute project roots on THIS machine.
#
# FIX (defect 2, 20260911-225720-4c57): the file is read via `<:raw>` (raw,
# UN-decoded bytes), so it MUST be decoded with `->utf8` -- that tells
# JSON::PP the input is UTF-8-encoded bytes rather than already-decoded
# characters. Without it, a registry path containing a real multi-byte
# character (job-search: "/c/Users/André/Personal Files/Job search")
# decodes to MOJIBAKE: the two raw bytes of 'é' (0xC3 0xA9) each become their
# own bogus codepoint (U+00C3, U+00A9) instead of collapsing to one (U+00E9).
# opendir() on that corrupted string then fails, silently, and a project's
# entire bug-report store vanishes from `collect` with no diagnostic --
# verified: job-search's 6 reports (all open) were invisible before this fix.
sub known_projects {
    my $p = registry_path();
    open my $fh, '<:raw', $p or return ();
    local $/;
    my $j = eval { JSON::PP->new->utf8->decode(<$fh>) };
    close $fh;
    return () unless ref $j eq 'HASH' && ref $j->{projects} eq 'HASH';
    my @out;
    for my $slug (sort keys %{ $j->{projects} }) {
        my $path = $j->{projects}{$slug}{path} or next;
        $path =~ s{\\}{/}g; $path =~ s{/+$}{};
        push @out, $path if length $path;
    }
    return @out;
}
sub reports_dir { my ($root) = @_; return "$root/.ccpraxis-local-data/bug-reports" }

# _almanac_type_dirs($almanac_root) -> @dirs -- directory DISCOVERY, not a
# type list (package 09, S2.3): every subdirectory of $almanac_root whose
# name matches the store-type grammar ^[a-z][a-z0-9-]*$. A missing root is
# silently skipped -- the container case for the global root. Never dies.
sub _almanac_type_dirs {
    my ($almanac_root) = @_;
    return () unless defined $almanac_root && -d $almanac_root;
    opendir(my $dh, $almanac_root) or return ();
    my @out;
    for my $e (readdir($dh)) {
        next unless $e =~ /\A[a-z][a-z0-9-]*\z/;
        my $full = "$almanac_root/$e";
        push @out, $full if -d $full;
    }
    closedir $dh;
    return sort @out;
}

# canonical_root(path) -> a value two SPELLINGS of one directory converge on,
# so a dedupe keyed on it treats them as the same root.
#
# FIX (defect 1, 20260911-225720-4c57): the caller's own root arrives as
# `C:/Development/ccpraxis` (from $CLAUDE_PROJECT_DIR / Cwd::abs_path), while
# the steward registry stores the POSIX spelling `/c/Development/ccpraxis`.
# `all_report_paths` used to dedupe on the RAW string, so both spellings
# survived into @roots, both got walked, and every report under that one
# directory was yielded twice -- measured: 88 reports where the project held
# 43 (43*2 + 2 from another project).
#
# Cwd::abs_path is the real answer whenever the directory exists: it
# resolves case, "..", backslashes and symlinks to one canonical form, which
# is exactly why both `C:/Development/ccpraxis` and `/c/Development/ccpraxis`
# collapse to `/c/Development/ccpraxis` on this host (verified). It returns
# undef for a path that does not currently resolve -- a registered project
# whose directory has moved or been deleted -- so this falls back to a
# lightweight textual normalisation for exactly that case (backslashes to
# forward slashes, `/x/` <-> `X:/` drive form, uppercased drive letter, no
# trailing slash). The fallback cannot resolve symlinks or on-disk case, but
# a root that fails even abs_path is already unreadable to list_reports_in,
# so it contributes nothing either way -- this only stops it being walked
# under BOTH of its spellings.
sub canonical_root {
    my ($p) = @_;
    return '' unless defined $p && length $p;
    my $abs = Cwd::abs_path($p);
    return $abs if defined $abs;
    my $norm = $p;
    $norm =~ s{\\}{/}g;
    $norm =~ s{^/([a-zA-Z])(?=/|\z)}{uc($1) . ':'}e;
    $norm =~ s{^([a-zA-Z]):}{uc($1) . ':'}e;
    $norm =~ s{/+\z}{};
    return $norm;
}

sub _mkpath {
    my ($d) = @_;
    return 1 if -d $d;
    my $cur = ($d =~ m{^/}) ? '/' : '';
    for my $p (grep { length } split m{/}, $d) {
        $cur = ($cur eq '' || $cur eq '/') ? "$cur$p" : "$cur/$p";
        next if $cur =~ /^[A-Za-z]:$/;
        unless (-d $cur) { mkdir $cur or return 0 }
    }
    return -d $d ? 1 : 0;
}

# --- report file format: frontmatter + body -------------------------------
sub _parse {
    my ($text) = @_;
    return undef unless defined $text && $text =~ /\A---\r?\n(.*?)\r?\n---\r?\n(.*)\z/s;
    my ($fm, $body) = ($1, $2);
    my (%f, %seen, $dup);
    for my $line (split /\r?\n/, $fm) {
        next unless $line =~ /^([A-Za-z0-9_]+):\s*(.*)$/;
        my ($k, $v) = ($1, $2);
        $v =~ s/\s+$//;
        # Last-wins is UNCHANGED — every existing reader of $f->{$k} keeps its
        # current meaning. `duplicate_key` is only an additional signal that a
        # key repeated at all, surfaced (not silently swallowed) by the CLI.
        $dup //= $k if $seen{$k}++;
        $f{$k} = $v;
    }
    my %out = (fields => \%f, body => $body);
    $out{duplicate_key} = $dup if defined $dup;
    return \%out;
}
sub _render {
    my ($f, $body) = @_;
    my @order = qw(id title status severity area project created_at updated_at
                   frozen_at content_sha256 claimant_session claimant_agent
                   claimant_transcript_path claimed_at
                   taken_over_from taken_over_at taken_over_reason taken_at resolution);
    my %seen;
    my @lines;
    # Structural backstop: no field value may carry \r or \n, regardless of
    # whether the caller validated it. This is what closes the class for good —
    # the CLI-boundary checks (§2.2 of the spec) exist only to turn what would
    # otherwise be this die into a specific, actionable per-flag error.
    for my $k (@order) {
        next unless defined $f->{$k};
        die "almanac-bug: internal error — frontmatter field '$k' would contain a line "
          . "break or control character\n"
            if has_forbidden_bytes($f->{$k});
        push @lines, "$k: $f->{$k}"; $seen{$k}=1;
    }
    for my $k (sort keys %$f) {
        next if $seen{$k}; next unless defined $f->{$k};
        die "almanac-bug: internal error — frontmatter field '$k' would contain a line "
          . "break or control character\n"
            if has_forbidden_bytes($f->{$k});
        push @lines, "$k: $f->{$k}";
    }
    return "---\n" . join("\n", @lines) . "\n---\n" . $body;
}
sub _read_file { my ($p)=@_; open my $fh,'<:raw',$p or return undef; local $/; my $c=<$fh>; close $fh; return $c }
# Returns 1/0 in scalar context, as three call sites depend on, and sets
# $LAST_ERROR to a specific reason on failure.
#
# THE rename IS RETRIED, against a bounded deadline. On Windows a rename over a
# path another process holds open FAILS — an on-access virus scanner, an
# editor, or Claude Code's own node process reading the file is enough — and
# reporting that as "write failed" turns a transient sharing violation into a
# lost write. Almanac::Lock::rename_with_retry polls for up to 2s against an
# allowlist of transient errnos and fails fast on anything else.
#
# The temp file stays this function's own business (Almanac::Lock removes
# nothing, ever — see its header), so the only removal in this script is of
# $tmp, and never of a lock file.
sub _write_atomic {
    my ($p, $bytes) = @_;
    $LAST_ERROR = '';
    unless (_mkpath(dirname($p))) {
        $LAST_ERROR = "could not create the directory for $p";
        return 0;
    }
    my $tmp = "$p.tmp.$$";
    my $fh;
    unless (open $fh, '>:raw', $tmp) {
        $LAST_ERROR = "could not open $tmp for writing: $!";
        return 0;
    }
    unless (print {$fh} $bytes) {
        my $why = "$!";
        close $fh;
        unlink $tmp;
        $LAST_ERROR = "could not write $tmp: $why";
        return 0;
    }
    unless (close $fh) {
        my $why = "$!";
        unlink $tmp;
        $LAST_ERROR = "could not close $tmp: $why";
        return 0;
    }
    my ($renamed, $err) = Almanac::Lock::rename_with_retry($tmp, $p);
    unless ($renamed) {
        $LAST_ERROR = $err->{message};
        unlink $tmp;
        return 0;
    }
    return 1;
}

sub load {
    my ($path) = @_;
    my $raw = _read_file($path) or return undef;
    my $p = _parse($raw) or return undef;
    $p->{path} = $path;
    $p->{raw}  = $raw;
    # MIGRATION ON READ, ONLY (spec sec 2.2): a report still saying the legacy
    # status name is read as the current name everywhere, and $p->{raw} is NOT
    # touched -- cas_write still compares the real on-disk bytes.
    my $st = $p->{fields}{status};
    if (defined $st && exists $LEGACY_STATUS{$st}) {
        $p->{legacy_status}  = $st;
        $p->{fields}{status} = $LEGACY_STATUS{$st};
    }
    return $p;
}

# _transcript_visibility($path) -> ($root_visible, $file_exists)
#
# FIX (S2 / red-team M1, package 12 fix-batch): a recorded transcript_path is
# an ABSOLUTE path captured by whichever process held the claim at claim time
# (host or sandbox). Checking it from a DIFFERENT process (a sandbox checking
# a host claim, or vice versa -- plugins/sandbox/scripts/launcher.pl's mount
# scope never gives a container the host's transcripts, and never the
# reverse) must not read "I cannot see it" as "it is gone": that is exactly
# what made a live host claim read STALE from inside a sandbox, and `takeover`
# then succeeded wrongly, stealing an active claim.
#
# The distinguishing signal is the transcript's ROOT directory (the
# "<...>/projects" directory the session file sits two levels under -- see
# BpSession::transcript_roots). A DIFFERENT mount scope means that whole root
# does not exist from here at all. A genuinely deleted transcript, checked
# from the SAME scope that wrote it, still has its root -- only the specific
# file is gone. So: root missing -> indeterminate (caller falls back to the
# age-only rule); root present but file missing -> genuinely stale.
sub _transcript_visibility {
    my ($path) = @_;
    return (0, 0) unless defined $path && length $path;
    (my $p = $path) =~ s{\\}{/}g;
    (my $root = $p) =~ s{/[^/]+/[^/]+\z}{};
    my $root_visible = length($root) && -d $root;
    my $file_exists  = -f $path;
    return ($root_visible, $file_exists);
}

# claim_state($fields, $now) -> undef | { stale => 0|1, reason => $str_or_undef }
#
# undef when the (already-migrated) status is not 'triaging'. Lives here, not
# in almanac-doctor.pl, so doctor stays within its AC21 static constraints
# (spec sec 2.6/2.9). Dies if BpSession.pm cannot be loaded for a LEGACY claim
# (one recorded before claimant_transcript_path existed) -- there is no
# age-only fallback for that case (spec sec 1.2): a claim's liveness is never
# guessed by a process that has no way to check it at all. A claim that DOES
# carry claimant_transcript_path never takes this path -- see
# _transcript_visibility above for why an invisible root is not the same
# finding as an absent file.
sub claim_state {
    my ($f, $now) = @_;
    return undef unless defined $f->{status} && $f->{status} eq 'triaging';

    my $csess = $f->{claimant_session};
    if (!defined $csess || !length $csess) {
        return { stale => 1, reason => 'no claimant recorded' };
    }

    my $tpath = $f->{claimant_transcript_path};
    if (defined $tpath && length $tpath) {
        my ($root_visible, $file_exists) = _transcript_visibility($tpath);
        if ($root_visible && !$file_exists) {
            return { stale => 1, reason => "claimant session $csess has no transcript on this machine" };
        }
        # Root not visible from here -> indeterminate: fall through to the
        # age-only rule below without consulting BpSession at all. Root
        # visible and file present -> live by transcript; also fall through,
        # so the age rule still applies on top (a transcript can be present
        # and still 25h old).
    }
    else {
        my $bpsession_path = _butler_module_path('BpSession.pm');
        unless (defined $bpsession_path && -f $bpsession_path) {
            die "cannot load butler's BpSession.pm ($bpsession_path): file not found\n";
        }
        unless (grep { m{(?:^|/)BpSession\.pm$} } keys %INC) {
            my $ok = eval { require $bpsession_path; 1 };
            die "cannot load butler's BpSession.pm ($bpsession_path): $@" unless $ok;
        }
        my $transcript = eval { BpSession::find_transcript($csess) };
        if (!defined $transcript) {
            return { stale => 1, reason => "claimant session $csess has no transcript on this machine" };
        }
    }

    my $claimed_at = $f->{claimed_at};
    my $claimed_epoch;
    if (defined $claimed_at && $claimed_at =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/) {
        $claimed_epoch = eval { require Time::Local; Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1) };
    }
    unless (defined $claimed_epoch) {
        return { stale => 1, reason => 'claimed_at missing or unreadable' };
    }

    my $age = $now - $claimed_epoch;
    if ($age > $CLAIM_STALE_SECONDS) {
        return { stale => 1, reason => 'claim is ' . int($age / 3600) . 'h old (stale after 24h)' };
    }
    return { stale => 0 };
}

# _butler_module_path($basename) -> absolute path of a butler scripts module,
# located from THIS FILE's own directory (spec sec 1.2), same technique the
# BEGIN block above already uses for Almanac::Lock.
sub _butler_module_path {
    my ($basename) = @_;
    my $dir = __FILE__;
    $dir =~ s{\\}{/}g;
    $dir =~ s{/[^/]+\z}{};
    $dir = '.' unless length $dir;
    return "$dir/../../butler/scripts/$basename";
}

# cas_write(): FIX 1 (fixbatch-step7, red-team HIGH) — a load-modify-write
# race defeated the freeze guarantee. Both `update` and `set-status` LOAD a
# report, then do work that can take real wall-clock time (`update`'s
# `--body -` BLOCKS on stdin), then WRITE `%f` built from that stale load.
# If a `set-status --to reviewing` landed in that window, `update`'s
# subsequent write reverted the status to `open` and erased
# content_sha256/frozen_at entirely — silently undoing the freeze the
# refusal message two lines above it promises. `verify` would then say "not
# frozen" rather than TAMPERED, so nothing would even report the problem.
#
# THIS IS LAYER TWO, AND THE COMMENT THAT USED TO BE HERE WAS WRONG.
#
# It claimed there was no portable OS-level lock worth reaching for on this
# platform, and built the whole design on that claim. The claim was false.
# bp-blueprint.pl:425 has taken flock(LOCK_EX) on a sidecar lock file for
# every blueprint mutation in this repo since it was written, and a direct
# measurement on 2026-09-11 — two concurrent processes, one sidecar lock
# file, both host perls — showed the waiter blocking for the holder's full
# remaining hold and then acquiring. flock works here.
#
# So the three read-modify-write verbs now take a real exclusive lock across
# the WHOLE load-modify-write (Almanac::Lock, on `<report>.md.lock`), and two
# concurrent writers QUEUE rather than collide. A refusal is not
# serialization: the requirement is that two agents editing one record both
# get their change, in some order, not that one of them is told to retry.
#
# cas_write is not deleted and not weakened — it is DEMOTED. Three layers,
# each catching what the one above it cannot:
#
#   1. the lock            — two sanctioned writers racing
#   2. this byte CAS       — a writer that BYPASSED the lock entirely
#   3. content_sha256      — an out-of-band write that routed around 1 and 2
#
# LAYER TWO is therefore about a writer that took no lock at all: it re-reads
# the file's actual on-disk BYTES immediately before the write and compares
# them to the bytes `load()` captured. It refuses instead of ever writing, so
# an unsanctioned concurrent write becomes a loud, specific refusal rather
# than silent data loss. It takes no lock and releases none — its caller
# holds one.
sub cas_write {
    my ($rep, $bytes) = @_;
    my $current = _read_file($rep->{path});
    return (0, 'the report no longer exists on disk') unless defined $current;
    return (0, 'the report changed on disk since it was loaded (a concurrent '
             . 'set-status or update landed in between)') unless $current eq $rep->{raw};
    return (0, "write failed: $LAST_ERROR") unless _write_atomic($rep->{path}, $bytes);
    return (1, '');
}

# has_forbidden_bytes(): the ONE definition of "not safe in a frontmatter
# value", shared by the CLI-boundary guard (_reject_multiline, in package
# main) and the _render structural backstop below, so the two layers enforce
# literally the same rule instead of two independently-maintained
# approximations of it.
#
# Originally this was "\r or \n" -- exactly the two bytes report ee3c's
# reproduction used. A red-team probe (fixbatch-step7, 2026-08-19) showed
# --area containing U+2028 LINE SEPARATOR sailed through unrejected and
# landed verbatim in the rendered frontmatter; any consumer that treats
# U+2028 as a line break (this script's own _parse does not; some other
# reader might) sees an injected field. The class was never "CR/LF", it was
# "any line or paragraph break, and any control character" -- so that is
# what is enforced now:
#   - every C0 control character except TAB (\x00-\x08, \x0A-\x1F)
#   - DEL (\x7F)
#   - every C1 control character (\x80-\x9F), which includes NEL (U+0085)
#   - the two Unicode line/paragraph separators, U+2028 and U+2029
# TAB is deliberately still allowed: it does not break line-oriented parsing
# (_parse splits on /\r?\n/ only) and is common in pasted text.
#
# Verified on this platform (Git-for-Windows/Windows perl): argv arrives as
# raw, UN-decoded bytes, and codepoints <= 0xFF and > 0xFF do not even take
# the SAME encoding form consistently -- U+2028 (a Perl \x{...} escape whose
# value is > 0xFF) showed up as the three-byte UTF-8 sequence \xE2\x80\xA8,
# but U+0085 NEL (a \x{...} escape whose value is <= 0xFF, so Perl does not
# force the string to internal UTF-8) showed up as the single raw byte
# \x85, NOT its two-byte UTF-8 encoding \xC2\x85. Both forms had to be
# handled empirically, not assumed. Rather than chase every encoding a
# caller might produce, the C1 range (\x80-\x9F) is matched as STANDALONE
# bytes, which subsumes both "\x85 alone" and "\xC2\x85" (its second byte
# already falls in \x80-\x9F). The accepted cost: a value containing
# genuine multi-byte UTF-8 text whose CONTINUATION byte happens to land in
# \x80-\x9F (e.g. some accented Latin Extended-A characters) would also be
# rejected. That is judged safe/acceptable here -- report `area`/`title`/
# `note` values are short, ASCII-oriented labels in practice, and a false
# rejection fails LOUD (the CLI refuses with a message) rather than
# silently corrupting anything, which is the failure mode this whole fix
# exists to close.
sub has_forbidden_bytes {
    my ($val) = @_;
    return 0 unless defined $val;

    # DECODE FIRST WHEN THE BYTES ARE VALID UTF-8.
    #
    # The C1 half of the class below (\x80-\x9F) cannot be applied to
    # UNDECODED UTF-8: continuation bytes occupy \x80-\xBF, which CONTAINS the
    # whole C1 range. So every ordinary punctuation mark in this repo's own
    # report titles tripped it -- an em dash is E2 80 94, and 0x94 alone looks
    # exactly like a C1 control.
    #
    # Measured: `set-status` on 20260813-011838-82bf ("ccpraxis backpack — two
    # bugs found from a live container") died with "field 'title' would contain
    # a line break or control character" and could not be moved to any state.
    # The report was already terminal work, wedged by its own em dash. En
    # dashes, curly quotes and ellipses are all the same shape of failure.
    #
    # Decoding costs the real protection nothing. A newline is 0x0A decoded or
    # not, C0 and DEL are unchanged below 0x80, and U+2028/U+2029 are checked as
    # characters immediately after. What changes is only that legitimate
    # punctuation stops being mistaken for a control character.
    #
    # Invalid UTF-8 falls through to the byte check unchanged -- a caller that
    # hands us arbitrary bytes still gets the strict treatment, which is the
    # case the class was written for.
    my $checked = $val;
    if (!utf8::is_utf8($checked)) {
        my $decoded = eval {
            require Encode;
            Encode::decode('UTF-8', $checked, Encode::FB_CROAK());
        };
        $checked = $decoded if defined $decoded;
    }

    return 1 if $checked =~ /[\x00-\x08\x0A-\x1F\x7F-\x9F]/;   # C0 (less TAB) + DEL + C1
    return 1 if $val =~ /\xE2\x80[\xA8\xA9]/;               # UTF-8 U+2028 / U+2029
    # ...and the SAME two separators as DECODED characters. The byte form
    # above covers argv, which arrives un-decoded -- but _render is also
    # callable directly, and the whole point of the backstop is to hold for a
    # caller that bypassed the CLI. Such a caller may well hand us a decoded
    # string, where U+2028 is one character, not three bytes, and the byte
    # regex above cannot see it. Driver-verified before this line existed:
    # _render({area => "a\x{2028}b"}) was ACCEPTED while the CLI rejected the
    # same separator, so the two layers did NOT enforce the same rule despite
    # sharing this function. A byte string can never contain codepoint 2028,
    # so this costs the argv path nothing.
    return 1 if $val =~ /[\x{2028}\x{2029}]/;               # decoded U+2028 / U+2029
    return 0;
}

# The frozen digest covers the BODY only. Status/updated_at legitimately change
# after freezing; the reported content must not.
#
# This function (and the `verify` it backs) proves body-digest integrity ONLY.
# It does not detect frontmatter corruption or forged fields — a duplicate
# frontmatter key is caught separately and structurally by `_parse`, and
# reported by the `list`, `collect`, and `verify` CLI surfaces, not by this
# digest. Folding frontmatter into the digest would make `verify` scream
# TAMPERED on every legitimate `set-status` transition, since `status`,
# `updated_at`, `resolution` and `taken_at` are designed to change after
# freezing. The injection defense for those fields is the write/read guard
# (CLI-boundary validation + `_parse`'s duplicate-key detection), not this
# digest — that split is deliberate and permanent, not a gap to close later.
sub body_digest { return sha256_hex($_[0] // '') }

sub verify {
    my ($rep) = @_;
    my $f = $rep->{fields};
    return (1, 'not frozen') unless defined $f->{content_sha256} && length $f->{content_sha256};
    my $now = body_digest($rep->{body});
    return (1, 'intact') if $now eq $f->{content_sha256};
    return (0, "TAMPERED: body digest $now != recorded $f->{content_sha256}");
}

# all_report_paths(\@extra_roots, $warn) -> sorted absolute paths of every
# report on this machine. Disk is the truth; there is nothing to keep in
# sync. $warn, if given, is a coderef called with one string for every root
# that could not be read at all (see list_reports_in) -- optional so
# internal callers (the cross-project `$find` in `main`, `verify`) that do
# not want CLI noise can omit it; `collect` passes one that prints to STDERR.
#
# Roots are deduped on canonical_root(), NOT the raw string -- see that sub's
# header for why the raw-string dedupe this replaced double-counted every
# report in a project reachable under two spellings.
sub all_report_paths {
    my ($extra, $warn) = @_;
    my %seen;
    my @roots;
    for my $r (@{ $extra // [] }, known_projects()) {
        my $c = canonical_root($r);
        next if $seen{$c}++;
        push @roots, $r;
    }
    my @paths;
    for my $r (@roots) {
        push @paths, list_reports_in($r, $warn);
    }
    my %u; return sort grep { !$u{$_}++ } @paths;
}

# opendir, NOT glob. Perl's built-in glob splits its argument on WHITESPACE, so
# "/c/Users/André/Personal Files/Job search/..." came back as three fragments
# and the real directory was never read — silently missing every report in any
# project whose path contains a space. Two of this machine's registered
# projects do. opendir has no quoting semantics at all.
#
# $warn (optional coderef) is called with one message when the ROOT ITSELF is
# not a readable directory (registered, but gone/inaccessible on this
# machine) -- NOT when the root exists but simply has no bug-reports/ yet,
# which is the overwhelmingly common and entirely normal case for a project
# that has never filed a ccpraxis bug. FIX (defect 2, 20260911-225720-4c57):
# a root that failed to open its reports dir used to vanish with no
# diagnostic at all -- that is what hid job-search's 6 open reports (a
# SEPARATE cause, since fixed: see known_projects()'s header).
sub list_reports_in {
    my ($root, $warn) = @_;
    my $dir = reports_dir($root);
    if (opendir(my $dh, $dir)) {
        my @f = sort grep { /\.md\z/ && -f "$dir/$_" } readdir($dh);
        closedir $dh;
        return map { "$dir/$_" } @f;
    }
    if ($warn && !-d $root) {
        $warn->("project root '$root' does not exist or is not a readable "
              . "directory on this machine -- skipped");
    }
    return ();
}

# PACKAGE 09 (report 20260917-040452-f500): the original new_id keyed only on
# the clock to the second plus $$ & 0xffff -- 10,000 generations inside one
# process-second yielded ONE distinct id, not "occasionally collides". That
# never bit hand-paced bug filing, but package 09 writes records
# programmatically, which removes the pacing that hid it.
#
# ID_BASE is minted once (mixing pid and a random draw, so two concurrent
# processes still diverge) and ID_SEQ increments on every call, so up to
# 65,536 ids within one process in one second are distinct. The SHAPE is
# unchanged (YYYYMMDD-HHMMSS-<4 hex>) -- 61 live reports, commit messages and
# cross-report citations already depend on it, and new ids are additive: an
# existing legacy id is never rewritten or reparsed by this function.
#
# TWO GENERATORS, DELIBERATELY (ledger item 3, parity decision). Almanac::Record
# has its own new_id with an 8-hex tail (pid4hex + seq4hex) -- a different
# shape. They are NOT unified: bug ids stay 4-hex because
# plugins/butler/tests/t/tooling-bug-filing.t:457 pins
# ^\d{8}-\d{6}-[0-9a-f]{4}$ for a report filed through almanac-bug.pl, and
# nothing reads a bug id and a store id through one shared grammar -- verify
# treats both as opaque file names, and bug reports and store records never
# share a directory. Kept as two generators, not merged into one.
our $ID_BASE = ($$ ^ int(rand(0x10000))) & 0xffff;
our $ID_SEQ  = 0;
sub new_id {
    my ($now) = @_;
    my @t = gmtime($now // time);
    my $tail = ($ID_BASE + $ID_SEQ++) & 0xffff;
    return sprintf('%04d%02d%02d-%02d%02d%02d-%04x',
                   $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0], $tail);
}

# claim_report_path($dir, $now) -> ($path, $lock) | (undef, $err)
#
# Mints a fresh id, takes its per-record lock, and confirms no file already
# sits at that path -- up to 64 attempts -- so `file` can never rename over
# an existing report. Creates $dir before the loop. The caller releases the
# returned lock once it has written the report (or on any early exit).
sub claim_report_path {
    my ($dir, $now) = @_;
    _mkpath($dir) or return (undef, { message => "could not create the directory $dir" });
    for (1 .. 64) {
        my $id   = new_id($now);
        my $path = "$dir/$id.md";
        my ($lock, $err) = Almanac::Lock->acquire($path, verb => 'file');
        return (undef, $err) unless $lock;
        if (-e $path) {
            $lock->release;
            next;
        }
        return ($path, $lock);
    }
    return (undef, { message => 'no free report id' });
}

sub can_transition {
    my ($from, $to) = @_;
    return (0, "unknown target state '$to'") unless grep { $_ eq $to } @STATES;
    return (0, "unknown current state '$from'") unless exists $NEXT{$from};
    return (0, "$from -> $to is not a legal transition (from $from you may go to: "
             . (join(', ', @{$NEXT{$from}}) || 'nowhere — it is terminal') . ')')
        unless grep { $_ eq $to } @{ $NEXT{$from} };
    return (1, '');
}

package main;
use strict;
use warnings;
use JSON::PP;

# The one invariant, enforced at every CLI argument that reaches frontmatter:
# no value may contain a line/paragraph break or control character (see
# AlmanacBug::has_forbidden_bytes for the exact class and why it is wider
# than "\r or \n"). Reject, don't escape/quote -- _parse has no quote
# handling and none is added (see spec §2.1).
#
# The message keeps the substring "must be one line" on purpose: it is the
# locked fragment every AC in 03-frontmatter-injection.t matches against,
# and it is still true (a rejected value would not stay one line if any of
# these bytes were let through) -- just no longer the WHOLE rule, which the
# rest of the sentence now says.
sub _reject_multiline {
    my ($cmd, $flag, $val) = @_;
    die "almanac-bug $cmd: --$flag must be one line, with no control characters "
      . "or Unicode line/paragraph separators\n"
        if defined $val && !ref $val && AlmanacBug::has_forbidden_bytes($val);
}

# FIX 3 (fixbatch-step7, red-team LOW): a value with leading/trailing
# whitespace was written verbatim but _parse strips trailing whitespace on
# read (and any hand-authored consumer is likely to strip both ends), so
# write != read-back. Consistent with this package's "reject, don't
# normalize silently" stance (see spec §2.1): a value that will not survive
# its own round trip is not a value the store accepts, rather than one it
# silently mangles later.
sub _reject_untrimmed {
    my ($cmd, $flag, $val) = @_;
    return unless defined $val && !ref $val;
    die "almanac-bug $cmd: --$flag must not have leading or trailing whitespace "
      . "(it would not round-trip -- the frontmatter reader strips it)\n"
        if $val =~ /^\s/ || $val =~ /\s$/;
}

# TEST SEAM ONLY (fixbatch-step7 FIX 1). When set, ALMANAC_RACE_TEST_HOOK
# names a perl script; it is run (list-form system(), no shell involved, so
# no Windows quoting to get right) right after a report is loaded and
# before `update`/`set-status` do anything else with it. That lets a test
# deterministically land a concurrent write inside the load-modify-write
# window instead of racing real threads against real wall-clock timing.
# Nothing in normal operation ever sets this env var; only
# plugins/almanac/tests/t/load-modify-write-race.t does, and the hook script it points at
# never sets it itself (so there is no recursive self-invocation).
#
# THE SEAM MUST NOW SUSPEND THE LOCK, and that is the correct semantics rather
# than a dodge. Once the lock wraps load->write, the window this hook lands in
# is closed to any writer that RESPECTS the lock — the hook's child would block
# on its own deadline and never land its write. With serialization in place the
# only writer that can still land there is one that BYPASSED the lock, and
# catching exactly that is what layer two now exists for. So the seam simulates
# such a writer: the lock is dropped for the hook's duration and re-acquired
# afterwards. This is the ONLY sanctioned caller of suspend/resume in this
# script, and a test asserts that by grep.
sub _race_test_hook {
    my ($lock) = @_;                # undef for any caller that holds no lock
    return unless defined $ENV{ALMANAC_RACE_TEST_HOOK} && length $ENV{ALMANAC_RACE_TEST_HOOK};
    $lock->suspend if $lock;
    system($^X, $ENV{ALMANAC_RACE_TEST_HOOK});
    if ($lock) {
        my ($ok, $err) = $lock->resume;
        unless ($ok) {
            print STDERR "almanac-bug: could not re-acquire the lock after the test hook: "
                       . "$err->{message}";
            exit 2;
        }
    }
    return;
}

# The three read-modify-write verbs take the lock BEFORE they load, and hold it
# across the mutation and the cas_write. This is what turns two concurrent
# writers into a queue instead of a collision. `file` deliberately does NOT
# lock: its path carries a UTC timestamp to the second plus the low 16 bits of
# the pid (new_id), so no other process is writing that path, and there is no
# read-modify-write to serialize.
sub _refuse_unlocked {
    my ($verb, $id, $err) = @_;
    print STDERR "almanac-bug $verb: refused — could not take the write lock on '$id' "
               . "within $err->{timeout_ms}ms.\n"
               . $err->{message}
               . "Retry the command; nothing was written.\n";
    exit 2;
}

# _caller_identity($verb, \@argv_raw) -> ($ok, $who_or_message)
#
#   $who = { session => $sid, agent => $aid_or_undef }
#   On failure, $message is already the full phrase (no "almanac-bug <verb>: "
#   prefix, no "refused — " prefix) -- the caller composes
#   "almanac-bug $verb: refused — $message".
#
# The ONLY identity source (spec sec 2.3): a butler hook ticket, keyed on the
# exact argv almanac-bug.pl was invoked with. No CLI flag and no environment
# variable is ever consulted here, by design.
sub _caller_identity {
    my ($verb, $argv) = @_;
    my $no_ticket_msg =
        "no hook ticket for this exact command. A claim needs the caller's session identity, "
      . "which only butler's PreToolUse hook supplies: run it from a Claude Code session with "
      . "the butler plugin enabled, with the id and every argument written literally (no "
      . "\$variables). Nothing was written.";

    my $bphook_path = AlmanacBug::_butler_module_path('BpHook.pm');
    unless (defined $bphook_path && -f $bphook_path) {
        return (0, "cannot load butler's BpHook.pm ($bphook_path): file not found. Nothing was written.");
    }
    unless (grep { m{(?:^|/)BpHook\.pm$} } keys %INC) {
        my $ok = eval { require $bphook_path; 1 };
        unless ($ok) {
            my $err = $@ || 'unknown error';
            $err =~ s/\s+\z//;
            return (0, "cannot load butler's BpHook.pm ($bphook_path): $err. Nothing was written.");
        }
    }

    my $t = eval { BpHook::take_ticket('almanac-bug', $argv) };
    return (0, $no_ticket_msg) unless defined $t;
    return (0, "two sessions issued this exact command at once, so the caller cannot be "
             . "identified. Retry. Nothing was written.")
        if !ref($t) && $t eq 'ambiguous';
    return (0, $no_ticket_msg) unless ref $t eq 'HASH';

    my $sid = $t->{session_id};
    return (0, $no_ticket_msg)
        unless defined $sid && !ref($sid) && $sid =~ /^[A-Za-z0-9_-]{1,128}$/;

    my $aid = $t->{agent_id};
    my $agent;
    if (!defined $aid || (!ref($aid) && $aid eq '')) {
        $agent = undef;
    }
    elsif (!ref($aid) && $aid =~ /^[A-Za-z0-9_-]{1,64}$/) {
        $agent = $aid;
    }
    else {
        return (0, "the hook ticket carries an unrecognised agent id; this claim cannot be "
                 . "recorded safely. Nothing was written.");
    }

    # transcript_path (S2 / red-team M1, package 12 fix-batch): recorded on
    # the claim so a LATER check of its liveness can tell "this transcript is
    # genuinely gone" apart from "this process cannot see that mount scope at
    # all" -- see claim_state's and _transcript_visibility's headers. Not
    # validated beyond "a defined, non-ref, non-empty string" -- it is never a
    # CLI value, only ever what the hook ticket itself recorded (BpHook.pm's
    # write_ticket, from the PreToolUse payload), and _render's structural
    # backstop still refuses it if it somehow carried a forbidden byte.
    my $tp = $t->{transcript_path};
    my $transcript_path = (defined $tp && !ref($tp) && length $tp) ? $tp : undef;

    return (1, { session => $sid, agent => $agent, transcript_path => $transcript_path });
}

# _is_claimant($claimant_session, $claimant_agent, $caller_session, $caller_agent) -> 1|0
#
# spec sec 2.5. A claimless report (no $claimant_session) is never matched --
# the caller treats that as its own case (behavior 8), not as a mismatch.
sub _is_claimant {
    my ($cs, $ca, $ts, $ta) = @_;
    return 0 unless defined $cs && length $cs;
    return 0 unless defined $ts && $ts eq $cs;
    return 1 unless defined $ta;                     # the session's own main thread
    return 1 if defined $ca && $ta eq $ca;
    return 0;
}

# _claimant_mismatch_message($verb, $id, $f) -- the 3.4 refusal text, for a
# triaging report that DOES carry a claimant the caller is not.
sub _claimant_mismatch_message {
    my ($verb, $id, $f) = @_;
    my $cs = $f->{claimant_session};
    my $ca = $f->{claimant_agent};
    my $agent_part = (defined $ca && length $ca) ? " (agent $ca)" : '';
    return "almanac-bug $verb: refused — '$id' is triaging and claimed by session $cs$agent_part "
         . "since $f->{claimed_at}; only the claimant may move it. If the claim is stale, "
         . "'almanac-bug.pl takeover $id' takes it over.\n";
}

# _refuse_if_tampered($verb, $id, $rep, $lock) -- spec sec 2.1. Verifies the
# body digest of an already-loaded report and, on mismatch, refuses loudly
# (naming the report and the verb) before the caller does anything else with
# it. Returns only when the report is intact or not frozen; writes nothing,
# under any path.
sub _refuse_if_tampered {
    my ($verb, $id, $rep, $lock) = @_;
    my ($intact, $note) = AlmanacBug::verify($rep);
    return if $intact;
    print STDERR "almanac-bug $verb: refused — '$id' $note. Its body changed after it was "
               . "frozen, outside this script; nothing was written. Run "
               . "'almanac-bug.pl verify' to list every tampered report.\n";
    $lock->release;
    exit 2;
}

sub _slurp_arg {
    my (%o) = @_;
    return $o{body} eq '-' ? do { local $/; <STDIN> } : $o{body} if defined $o{body};
    if (defined $o{'body-file'}) {
        open my $fh, '<:raw', $o{'body-file'} or die "cannot read $o{'body-file'}: $!\n";
        local $/; my $c = <$fh>; close $fh; return $c;
    }
    return undef;
}

unless (caller) {
    # The exact argv almanac-bug.pl was invoked with, verb first -- captured
    # BEFORE the first shift. A claim's identity comes from a butler hook
    # ticket keyed on this exact argv (spec sec 2.3); nothing else may ever
    # supply it.
    my @ARGV_RAW = @ARGV;
    my $cmd = shift @ARGV // '';
    my %o;
    while (@ARGV) {
        my $a = shift @ARGV;
        # $1 IS CAPTURED BEFORE THE LOOKAHEAD, and that is not style.
        #
        # The lookahead `$ARGV[0] !~ /^--/` is itself a match, and a SUCCESSFUL
        # match resets every capture variable. So when a boolean flag was
        # followed by another flag -- `--replace --body x` -- the lookahead
        # matched `^--`, $1 became undef, and the option was stored under the
        # empty key. The flag was silently dropped: no error, no warning beyond
        # an "uninitialized value $1" under -w, and the command ran as though it
        # had never been passed.
        #
        # Latent until 2026-08-29, because every flag in this CLI happened to be
        # written with a value after it. `--replace` and `--repair` are the
        # first booleans, and t/04 caught it immediately.
        if ($a =~ /^--([a-z0-9-]+)$/) {
            my $key = $1;
            $o{$key} = (@ARGV && $ARGV[0] !~ /^--/) ? shift @ARGV : 1;
        }
        else { $o{_pos} ||= []; push @{$o{_pos}}, $a }
    }
    my @pos  = @{ $o{_pos} // [] };
    my $root = $o{project} // $ENV{CLAUDE_PROJECT_DIR} // Cwd::abs_path('.') // '.';
    $root =~ s{\\}{/}g; $root =~ s{/+$}{};
    # The sixth vector: $root becomes `project:` in frontmatter, and it is
    # checked once here, uniformly, for every command -- not per-command.
    _reject_multiline($cmd || 'almanac-bug', 'project', $root);
    _reject_untrimmed($cmd || 'almanac-bug', 'project', $root);

    if ($cmd eq 'file') {
        my $title = $o{title} or die "almanac-bug file: --title is required\n";
        _reject_multiline('file', 'title', $title);
        _reject_untrimmed('file', 'title', $title);
        _reject_multiline('file', 'area', $o{area}) if defined $o{area} && !ref $o{area};
        _reject_untrimmed('file', 'area', $o{area}) if defined $o{area} && !ref $o{area};
        my $body = _slurp_arg(%o);
        die "almanac-bug file: --body or --body-file is required (a report with no body is noise)\n"
            unless defined $body && $body =~ /\S/;
        my $now = time;
        my $severity = $o{severity} // 'unknown';
        # Order matters (spec §2.3): the one-line check fires before the enum
        # check, so a multi-line payload dies "must be one line", not "must be
        # one of" -- the ee3c fixture's payload is multi-line.
        _reject_multiline('file', 'severity', $severity) unless ref $severity;
        _reject_untrimmed('file', 'severity', $severity) unless ref $severity;
        die "almanac-bug file: --severity must be one of: " . join(', ', @AlmanacBug::SEVERITIES) . "\n"
            unless !ref $severity && AlmanacBug::valid_severity($severity);

        my $dir = AlmanacBug::reports_dir($root);
        my ($path, $lock) = AlmanacBug::claim_report_path($dir, $now);
        unless (defined $path) {
            print STDERR "almanac-bug file: could not claim a report id: $lock->{message}\n";
            exit 2;
        }
        (my $id = $path) =~ s{.*/}{}; $id =~ s{\.md$}{};
        my %f = (
            id => $id, title => $title, status => 'open',
            severity => $severity,
            area     => ($o{area} // 'unknown'),
            project  => $root,
            created_at => AlmanacBug::_iso($now), updated_at => AlmanacBug::_iso($now),
        );
        my $wrote = AlmanacBug::_write_atomic($path, AlmanacBug::_render(\%f, $body));
        $lock->release;
        die "almanac-bug file: could not write $path\n" unless $wrote;

        print "$path\n";
        exit 0;
    }

    # Locate a report by id, in this project or (for ccpraxis-side verbs) anywhere.
    my $find = sub {
        my ($id) = @_;
        my $local = AlmanacBug::reports_dir($root) . "/$id.md";
        return $local if -f $local;
        # Not here — look across the registered projects. Cheap: one glob per
        # project, and it needs no index to have been kept honest.
        for my $p (AlmanacBug::all_report_paths([$root])) {
            return $p if $p =~ m{/\Q$id\E\.md$};
        }
        return undef;
    };

    # The read-only verbs (`list`, `collect`, `verify`) load through this one
    # reference, and take NO lock. They only read, and a reader that queued
    # behind a writer would make `list` stall on whatever record some other
    # agent happens to be holding. Keeping their loader visibly distinct from
    # the acquire-then-load path the three mutating verbs use is the point.
    my $read_only_load = \&AlmanacBug::load;

    if ($cmd eq 'update') {
        my $id = $pos[0] or die "almanac-bug update: <id> required\n";
        my $path = $find->($id) or die "almanac-bug update: no report '$id'\n";
        # LAYER ONE, and it must be taken BEFORE the load: the window this
        # closes is load-to-write, so a lock taken after the load would leave
        # exactly the gap it exists to remove. Released on every exit below,
        # refusals included.
        my ($lock, $lock_err) = Almanac::Lock->acquire($path, verb => 'update');
        _refuse_unlocked('update', $id, $lock_err) unless $lock;
        my $rep  = AlmanacBug::load($path) or die "almanac-bug update: $path is unreadable or malformed\n";
        die "almanac-bug update: '$id' has MALFORMED: duplicate frontmatter key "
          . "'$rep->{duplicate_key}' — refusing to operate on a possibly-forged report\n"
            if $rep->{duplicate_key};
        _refuse_if_tampered('update', $id, $rep, $lock);
        _race_test_hook($lock);
        my $st   = $rep->{fields}{status} // 'open';
        unless ($AlmanacBug::MUTABLE{$st}) {
            print STDERR "almanac-bug update: refused — '$id' is $st, and content is frozen from "
                       . "'triaging' onward so a reviewer cannot have the report rewritten "
                       . "underneath them. Add a follow-up report instead.\n";
            $lock->release;
            exit 2;
        }
        my $body = _slurp_arg(%o);
        die "almanac-bug update: --body or --body-file is required\n" unless defined $body && $body =~ /\S/;

        # UPDATE MUST NOT SILENTLY DESTROY THE REPORT IT IS UPDATING.
        #
        # `update` replaces the body wholesale. That is a legitimate verb, but
        # its most common use is adding progress to a report -- and the obvious
        # invocation for that (`--body-file <my new section>`) DELETES
        # everything the filer wrote, in one step, with no confirmation.
        #
        # There is no undo. Reports live under .ccpraxis-local-data/, which is
        # gitignored, so nothing recovers the previous text.
        #
        # Done exactly that on 20260828-095201-7c1e, 2026-08-29: an update
        # intended to record progress erased the original evidence -- the pid,
        # the nine-day uptime, the CPU figure, the probe source. It was
        # recoverable only because the whole report happened to still be in the
        # agent's context. Next time it will not be.
        #
        # So: if the existing body would not survive the write, refuse and name
        # both ways forward. --replace is for a caller who genuinely means to
        # rewrite; `append` is for the case that keeps being reached for by
        # mistake.
        # (the discard guard runs AFTER argument validation — see below)
        _reject_multiline('update', 'title', $o{title}) if defined $o{title} && !ref $o{title};
        _reject_untrimmed('update', 'title', $o{title}) if defined $o{title} && !ref $o{title};
        _reject_multiline('update', 'severity', $o{severity}) if defined $o{severity} && !ref $o{severity};
        _reject_untrimmed('update', 'severity', $o{severity}) if defined $o{severity} && !ref $o{severity};
        if (defined $o{severity} && !ref $o{severity}) {
            die "almanac-bug update: --severity must be one of: " . join(', ', @AlmanacBug::SEVERITIES) . "\n"
                unless AlmanacBug::valid_severity($o{severity});
        }
        # LAST, so a malformed argument is still reported as a malformed
        # argument. Placed before the validation on the first attempt, this
        # guard answered "your --title contains a newline" with "this would
        # discard the body" -- true, but not the thing the caller got wrong.
        # t/03's injection oracles caught it.
        my $old = defined $rep->{body} ? $rep->{body} : '';
        if ($old =~ /\S/ && index($body, $old) < 0 && !$o{replace}) {
            my ($ol, $nl) = (scalar(() = $old =~ /\n/g) + 1, scalar(() = $body =~ /\n/g) + 1);
            print STDERR
                "almanac-bug update: refused — this would DISCARD the existing body of '$id' "
              . "($ol lines replaced by $nl), and there is no undo: reports are gitignored.\n"
              . "  To add to the report:      almanac-bug.pl append $id --body-file <file>\n"
              . "  To genuinely rewrite it:   almanac-bug.pl update $id --body-file <file> --replace\n";
            $lock->release;
            exit 2;
        }

        my %f = %{ $rep->{fields} };
        $f{title} = $o{title} if defined $o{title} && !ref $o{title};
        $f{severity} = $o{severity} if defined $o{severity} && !ref $o{severity};
        $f{updated_at} = AlmanacBug::_iso(time);
        my ($cas_ok, $cas_why) = AlmanacBug::cas_write($rep, AlmanacBug::_render(\%f, $body));
        unless ($cas_ok) {
            print STDERR "almanac-bug update: refused — '$id' $cas_why. "
                       . "Retry the command; do not assume it partially applied.\n";
            $lock->release;
            exit 2;
        }

        $lock->release;
        print "$path\n";
        exit 0;
    }

    # append <id> (--body - | --body-file F)
    #
    # The verb `update` kept being used for. Adds to the end of the body and
    # cannot lose what is already there, so recording progress on an open report
    # is no longer one keystroke away from erasing it.
    #
    # Same freeze rule as update: allowed only while the status is mutable. A
    # frozen report's content is frozen whether you are replacing it or adding
    # to it -- a reviewer must be able to trust that what they read is what was
    # filed, and an appended paragraph changes that as surely as a rewrite.
    if ($cmd eq 'append') {
        my $id = $pos[0] or die "almanac-bug append: <id> required\n";
        my $path = $find->($id) or die "almanac-bug append: no report '$id'\n";
        # Before the load, for the same reason as `update` above.
        my ($lock, $lock_err) = Almanac::Lock->acquire($path, verb => 'append');
        _refuse_unlocked('append', $id, $lock_err) unless $lock;
        my $rep  = AlmanacBug::load($path) or die "almanac-bug append: $path is unreadable or malformed\n";
        die "almanac-bug append: '$id' has MALFORMED: duplicate frontmatter key "
          . "'$rep->{duplicate_key}' — refusing to operate on a possibly-forged report\n"
            if $rep->{duplicate_key};
        _refuse_if_tampered('append', $id, $rep, $lock);
        _race_test_hook($lock);
        my $st = $rep->{fields}{status} // 'open';
        unless ($AlmanacBug::MUTABLE{$st}) {
            print STDERR "almanac-bug append: refused — '$id' is $st, and content is frozen from "
                       . "'triaging' onward. Add a follow-up report instead.\n";
            $lock->release;
            exit 2;
        }
        my $add = _slurp_arg(%o);
        die "almanac-bug append: --body or --body-file is required\n"
            unless defined $add && $add =~ /\S/;

        my $old = defined $rep->{body} ? $rep->{body} : '';
        $old =~ s/\s+\z//;
        my $body = length($old) ? "$old\n\n$add" : $add;

        my %f = %{ $rep->{fields} };
        $f{updated_at} = AlmanacBug::_iso(time);
        my ($cas_ok, $cas_why) = AlmanacBug::cas_write($rep, AlmanacBug::_render(\%f, $body));
        unless ($cas_ok) {
            print STDERR "almanac-bug append: refused — '$id' $cas_why. "
                       . "Retry the command; do not assume it partially applied.\n";
            $lock->release;
            exit 2;
        }
        $lock->release;
        print "$path\n";
        exit 0;
    }

    if ($cmd eq 'set-status') {
        my $id = $pos[0] or die "almanac-bug set-status: <id> required\n";
        my $to = $o{to} or die "almanac-bug set-status: --to <state> required\n";

        # AC3 / behavior 10: the renamed state refuses the OLD name, with a
        # hint, BEFORE anything else -- including before the identity check,
        # so a stale SKILL.md's literal `--to reviewing` gets the rename hint
        # rather than a ticket error.
        if ($to eq 'reviewing') {
            print STDERR "almanac-bug set-status: unknown target state 'reviewing' -- it was "
                       . "renamed: use --to triaging\n";
            exit 2;
        }

        my $path = $find->($id) or die "almanac-bug set-status: no report '$id'\n";

        # Identity (spec sec 2.3): minted right after $find resolves the path
        # and BEFORE the lock, so the ±30s ticket cannot expire while the
        # process queues on the lock. Called on EVERY set-status so the
        # ticket is always consumed; its result is required only once $from
        # or $to is known to be `triaging` (checked below, after load).
        my ($id_ok, $id_who_or_msg) = _caller_identity('set-status', \@ARGV_RAW);

        # Before the load, for the same reason as `update` above.
        my ($lock, $lock_err) = Almanac::Lock->acquire($path, verb => 'set-status');
        _refuse_unlocked('set-status', $id, $lock_err) unless $lock;
        my $rep  = AlmanacBug::load($path) or die "almanac-bug set-status: $path unreadable\n";
        die "almanac-bug set-status: '$id' has MALFORMED: duplicate frontmatter key "
          . "'$rep->{duplicate_key}' — refusing to operate on a possibly-forged report\n"
            if $rep->{duplicate_key};
        _refuse_if_tampered('set-status', $id, $rep, $lock);
        _race_test_hook($lock);
        _reject_multiline('set-status', 'note', $o{note}) if defined $o{note} && !ref $o{note};
        _reject_untrimmed('set-status', 'note', $o{note}) if defined $o{note} && !ref $o{note};
        my $from = $rep->{fields}{status} // 'open';

        if ($from eq 'triaging' || $to eq 'triaging') {
            unless ($id_ok) {
                print STDERR "almanac-bug set-status: refused — $id_who_or_msg\n";
                $lock->release;
                exit 2;
            }
        }

        if ($from eq 'triaging') {
            my $f = $rep->{fields};
            my $cs = $f->{claimant_session};
            if (!defined $cs || !length $cs) {
                print STDERR "almanac-bug set-status: refused — '$id' is triaging with no "
                           . "claimant recorded (it predates claims); take it over first: "
                           . "almanac-bug.pl takeover $id\n";
                $lock->release;
                exit 2;
            }
            unless (_is_claimant($cs, $f->{claimant_agent}, $id_who_or_msg->{session}, $id_who_or_msg->{agent})) {
                print STDERR _claimant_mismatch_message('set-status', $id, $f);
                $lock->release;
                exit 2;
            }
        }

        # A REPORT CAN BE OUTSIDE THE MACHINE, AND THEN NOTHING COULD MOVE IT.
        #
        # can_transition rejects an unknown CURRENT state, which is right for a
        # typo but leaves no way out of one. 20260825-193930-fff0 carried
        # `status: fixed` -- not one of @STATES, so it was written by hand or by
        # a version that predates this machine. set-status refused it ("unknown
        # current state 'fixed'") and guard-almanac-write.sh denies editing the
        # reports directory directly, so the report was wedged: correct by every
        # rule, and unfixable by every sanctioned path.
        #
        # --repair is that path, and it is deliberately narrow. It is honoured
        # ONLY when the current state is not in @STATES: it can rescue a report
        # that is already outside the machine, and it can never be used to skip
        # a legal-but-unwanted transition between valid states (open -> resolved
        # stays refused, with or without it). The target must still be a real
        # state.
        #
        # The status is NOT silently remapped ('fixed' -> 'resolved' would be
        # the obvious guess). A guess would hide the drift that produced it, and
        # the operator is the one who knows which state the report actually
        # reached.
        my $from_known = grep { $_ eq $from } @AlmanacBug::STATES;
        my ($ok, $why);
        if (!$from_known && $o{repair}) {
            $ok  = (grep { $_ eq $to } @AlmanacBug::STATES) ? 1 : 0;
            $why = $ok ? '' : "unknown target state '$to'";
        }
        else {
            ($ok, $why) = AlmanacBug::can_transition($from, $to);
            $why .= " -- this report is OUTSIDE the state machine, so no transition can "
                  . "reach it. Re-run with --repair to place it in a valid state."
                if !$ok && !$from_known;
        }
        unless ($ok) { print STDERR "almanac-bug set-status: $why\n"; $lock->release; exit 2 }

        my %f = %{ $rep->{fields} };
        my $now = AlmanacBug::_iso(time);
        $f{status} = $to;
        $f{updated_at} = $now;
        # Freeze on the way OUT of open; unfreeze if deliberately sent back.
        if ($to eq 'open') { delete $f{content_sha256}; delete $f{frozen_at} }
        else {
            $f{content_sha256} //= AlmanacBug::body_digest($rep->{body});
            $f{frozen_at}      //= $now;
        }
        $f{taken_at}   = $now       if $to eq 'taken' && !defined $f{taken_at};
        $f{resolution} = $o{note}   if defined $o{note} && !ref $o{note};

        # Claim fields (spec sec 2.4 step 4). $id_who_or_msg is a hashref here
        # whenever $to eq 'triaging' -- the identity-required check above
        # already enforced that.
        if ($to eq 'triaging') {
            $f{claimant_session} = $id_who_or_msg->{session};
            if (defined $id_who_or_msg->{agent}) { $f{claimant_agent} = $id_who_or_msg->{agent} }
            else                                 { delete $f{claimant_agent} }
            if (defined $id_who_or_msg->{transcript_path}) { $f{claimant_transcript_path} = $id_who_or_msg->{transcript_path} }
            else                                            { delete $f{claimant_transcript_path} }
            $f{claimed_at} = $now;
            delete $f{taken_over_from};
            delete $f{taken_over_at};
            delete $f{taken_over_reason};
        }
        elsif ($to eq 'open') {
            delete $f{claimant_session};
            delete $f{claimant_agent};
            delete $f{claimant_transcript_path};
            delete $f{claimed_at};
            delete $f{taken_over_from};
            delete $f{taken_over_at};
            delete $f{taken_over_reason};
        }
        # taken/declined from triaging: claim fields are KEPT untouched.
        my ($cas_ok, $cas_why) = AlmanacBug::cas_write($rep, AlmanacBug::_render(\%f, $rep->{body}));
        unless ($cas_ok) {
            print STDERR "almanac-bug set-status: refused — '$id' $cas_why. "
                       . "Retry the command; do not assume it partially applied.\n";
            $lock->release;
            exit 2;
        }

        $lock->release;
        print "$id: $from -> $to" . (($from_known ? '' : '  (repaired: previous status was outside the state machine)')) . "\n";
        exit 0;
    }

    # takeover <id> (spec sec 2.7) -- recovers a STALE triaging claim: no
    # transcript for the recorded claimant, or claimed more than 24h ago.
    if ($cmd eq 'takeover') {
        my $id = $pos[0] or die "almanac-bug takeover: <id> required\n";
        my $path = $find->($id) or die "almanac-bug takeover: no report '$id'\n";

        # Identity is REQUIRED on every call (unlike set-status, every
        # takeover involves triaging by definition).
        my ($id_ok, $id_who_or_msg) = _caller_identity('takeover', \@ARGV_RAW);
        unless ($id_ok) {
            print STDERR "almanac-bug takeover: refused — $id_who_or_msg\n";
            exit 2;
        }

        my ($lock, $lock_err) = Almanac::Lock->acquire($path, verb => 'takeover');
        _refuse_unlocked('takeover', $id, $lock_err) unless $lock;
        my $rep = AlmanacBug::load($path) or die "almanac-bug takeover: $path unreadable\n";
        die "almanac-bug takeover: '$id' has MALFORMED: duplicate frontmatter key "
          . "'$rep->{duplicate_key}' — refusing to operate on a possibly-forged report\n"
            if $rep->{duplicate_key};
        _refuse_if_tampered('takeover', $id, $rep, $lock);
        _race_test_hook($lock);

        my $f      = $rep->{fields};
        my $status = $f->{status} // 'open';
        unless ($status eq 'triaging') {
            print STDERR "almanac-bug takeover: refused — '$id' is $status; only a triaging "
                       . "report has a claim to take over.\n";
            $lock->release;
            exit 2;
        }

        # FIX (S1, package 12 fix-batch): claim_state can die (a legacy claim
        # with no claimant_transcript_path, and butler's BpSession.pm missing
        # or unloadable) -- that used to propagate uncaught, exiting 255 with
        # no "refused" message at all. Same refusal style as every other exit
        # here (print to STDERR, release the lock, exit 2) rather than a raw
        # crash; the message names the same failure list/collect already
        # surface for this exact die (see the `list`/`collect` loader above).
        my $cstate = eval { AlmanacBug::claim_state($f, time) };
        if (!defined $cstate && $@) {
            print STDERR "almanac-bug takeover: refused — cannot check claim liveness: $@";
            $lock->release;
            exit 2;
        }
        unless ($cstate && $cstate->{stale}) {
            my $cs = $f->{claimant_session};
            my $ca = $f->{claimant_agent};
            my $agent_part = (defined $ca && length $ca) ? " (agent $ca)" : '';
            print STDERR "almanac-bug takeover: refused — '$id' is claimed by session "
                       . "$cs$agent_part since $f->{claimed_at}, and that claim is live (its "
                       . "transcript is present and it is under 24h old). Only a stale claim can "
                       . "be taken over.\n";
            $lock->release;
            exit 2;
        }

        my $now    = AlmanacBug::_iso(time);
        my $old_cs = $f->{claimant_session};
        my $old_ca = $f->{claimant_agent};
        my ($taken_over_from_field, $prev_text);
        if (defined $old_cs && length $old_cs) {
            $taken_over_from_field = (defined $old_ca && length $old_ca) ? "$old_cs/$old_ca" : $old_cs;
            $prev_text = (defined $old_ca && length $old_ca)
                       ? "session $old_cs agent $old_ca" : "session $old_cs";
        }
        else {
            $taken_over_from_field = 'none';
            $prev_text = 'nobody';
        }

        my %nf = %$f;
        $nf{status} = 'triaging';
        $nf{claimant_session} = $id_who_or_msg->{session};
        if (defined $id_who_or_msg->{agent}) { $nf{claimant_agent} = $id_who_or_msg->{agent} }
        else                                 { delete $nf{claimant_agent} }
        if (defined $id_who_or_msg->{transcript_path}) { $nf{claimant_transcript_path} = $id_who_or_msg->{transcript_path} }
        else                                            { delete $nf{claimant_transcript_path} }
        $nf{claimed_at}        = $now;
        $nf{taken_over_from}   = $taken_over_from_field;
        $nf{taken_over_at}     = $now;
        $nf{taken_over_reason} = $cstate->{reason};
        $nf{updated_at}        = $now;
        $nf{content_sha256}  //= AlmanacBug::body_digest($rep->{body});
        $nf{frozen_at}       //= $now;

        my ($cas_ok, $cas_why) = AlmanacBug::cas_write($rep, AlmanacBug::_render(\%nf, $rep->{body}));
        unless ($cas_ok) {
            print STDERR "almanac-bug takeover: refused — '$id' $cas_why. "
                       . "Retry the command; do not assume it partially applied.\n";
            $lock->release;
            exit 2;
        }

        $lock->release;
        print "$id: claim taken over from $prev_text ($cstate->{reason})\n";
        exit 0;
    }

    if ($cmd eq 'list' || $cmd eq 'collect') {
        # list   = this project only (from disk, authoritative)
        # collect = every project (from the index, then re-read each file)
        my @paths;
        if ($cmd eq 'list') {
            @paths = AlmanacBug::list_reports_in($root);   # opendir, not glob — see list_reports_in
        } else {
            # A skipped root must be LOUD (defect 2) -- silence is what hid six
            # open job-search reports with no clue anything had gone wrong.
            @paths = AlmanacBug::all_report_paths([$root], sub {
                print STDERR "almanac-bug collect: $_[0]\n";
            });
        }
        my @out;
        my @tampered;   # [ id-or-path, path ] for every tampered report LOADED,
                        # even one a --status filter would otherwise exclude
                        # (spec sec 2.3) -- the digest check runs before the filter.
        my @unreadable; # paths that look like a report (start with a frontmatter
                        # envelope) but failed to load at all (red-team M2) --
                        # distinct from a plain .md with no envelope, which is not
                        # a report and stays quietly skipped, same as `verify`.
        for my $p (@paths) {
            next unless -f $p;
            my $rep = $read_only_load->($p);
            unless ($rep) {
                my $raw = AlmanacBug::_read_file($p);
                push @unreadable, $p if defined $raw && $raw =~ /\A---\r?\n/;
                next;
            }
            my $f = $rep->{fields};
            my $integrity;
            if ($rep->{duplicate_key}) {
                # A duplicate key makes the frontmatter untrustworthy -- surface
                # it, don't vanish the row. FIX (red-team M1): this used to skip
                # the digest check and never reach @tampered, so a --status
                # filter could hide a tampered report behind the duplicate key.
                # It is now pushed into the same summary as a real digest
                # mismatch, with its own MALFORMED wording.
                $integrity = "MALFORMED: duplicate frontmatter key '$rep->{duplicate_key}'";
                push @tampered, [ $f->{id} // $p, $p ];
            } else {
                my ($intact, $note) = AlmanacBug::verify($rep);
                unless ($intact) {
                    $integrity = $note;
                    push @tampered, [ $f->{id} // $p, $p ];
                }
            }
            next if defined $o{status} && !ref $o{status} && ($f->{status}//'') ne $o{status};
            my %row = ( id=>$f->{id}, title=>$f->{title}, status=>$f->{status},
                        severity=>$f->{severity}, area=>$f->{area}, project=>$f->{project},
                        created_at=>$f->{created_at}, path=>$p,
                        (defined $integrity ? (integrity=>$integrity) : ()) );
            # Stale-claim surfacing (spec sec 2.8): claim_state is defined only
            # for a (migrated) 'triaging' row. A die (butler unreachable) is a
            # refusal, not a silently-clean report -- never report false
            # cleanliness for a check that could not actually run.
            if (($f->{status}//'') eq 'triaging') {
                $row{claimant_session} = $f->{claimant_session} if defined $f->{claimant_session};
                $row{claimant_agent}   = $f->{claimant_agent}   if defined $f->{claimant_agent};
                $row{claimed_at}       = $f->{claimed_at}       if defined $f->{claimed_at};
                my $cstate = eval { AlmanacBug::claim_state($f, time) };
                if (!defined $cstate && $@) {
                    print STDERR "almanac-bug $cmd: refused — cannot check claim liveness: $@";
                    exit 2;
                }
                if ($cstate && $cstate->{stale}) {
                    $row{stale_claim} = $cstate->{reason};
                }
            }
            push @out, \%row;
        }
        # ->utf8 ON THE ENCODE SIDE TOO, and it is not optional. known_projects
        # decodes the registry with ->utf8 (see :123), so project paths arrive
        # here as CHARACTER strings. Encoding without ->utf8 emits those
        # characters raw, and a path containing `André` goes out as a lone 0xE9
        # byte -- malformed UTF-8 that every JSON consumer rejects. Measured on
        # this machine: `collect --json` died with "malformed UTF-8 character in
        # JSON string ... before \x{e9}/.claude/ccpra...".
        #
        # Decode and encode must be symmetric. This is the same hazard the
        # user-global CLAUDE.md records for registry values ("never re-encode
        # something already decoded"), arriving from the opposite direction.
        if ($o{json}) { print JSON::PP->new->utf8->canonical->pretty->encode(\@out) }
        else {
            printf "%-22s %-10s %-9s %s\n", 'ID', 'STATUS', 'SEVERITY', 'TITLE';
            for my $r (@out) {
                printf "%-22s %-10s %-9s %s\n", $r->{id}, $r->{status}//'?',
                       $r->{severity}//'?', $r->{title}//'';
                print  "  !! $r->{integrity}\n" if $r->{integrity};
                if (($r->{status}//'') eq 'triaging') {
                    if (defined $r->{claimant_session}) {
                        my $agent_part = defined $r->{claimant_agent} ? " agent $r->{claimant_agent}" : '';
                        print "  claimed by session $r->{claimant_session}$agent_part since "
                            . ($r->{claimed_at} // '?') . "\n";
                    } else {
                        print "  no claimant recorded\n";
                    }
                    print "  !! STALE CLAIM: $r->{stale_claim} -- take it over with: "
                        . "almanac-bug.pl takeover $r->{id}\n"
                        if defined $r->{stale_claim};
                }
                print  "  $r->{project}\n" if $cmd eq 'collect';
            }
            # FIX (defect 4, 20260911-225720-4c57): `list` used to print a
            # bare "N report(s)" with no hint the answer was scoped to one
            # project. Asked to "fetch all bug reports", an agent reached for
            # `list`, got a confident total, and reported a number that was
            # never the whole picture -- and `collect` itself never said its
            # own project set comes from steward's backup registry, so an
            # unregistered project (filing a bug is unrelated to registering
            # for backup) was excluded with no indication that had happened.
            if ($cmd eq 'list') {
                print "\n" . scalar(@out) . " report(s) IN THIS PROJECT ($root) only -- "
                    . "run 'almanac-bug.pl collect' for every project on this machine.\n";
            } else {
                print "\n" . scalar(@out) . " report(s) across every project REGISTERED in "
                    . "steward's backup registry -- a project that files ccpraxis bugs but is "
                    . "not registered for backup is excluded from this count (see any "
                    . "'skipped' warnings above for a registered root that could not be read).\n";
            }
            # Column-0 summary (spec sec 2.3), after the footer, one per
            # tampered report LOADED -- including one a --status filter
            # excluded from the rows above. Read verbs exit 0 regardless
            # (B9): this is the loud flag, not a failure.
            for my $t (@tampered) {
                my ($tid, $tpath) = @$t;
                print "!! TAMPERED: $tid -- its body no longer matches the sha256 recorded "
                    . "when it was frozen ($tpath). set-status, takeover, update and append "
                    . "refuse it; run 'almanac-bug.pl verify' for detail.\n";
            }
            # FIX (red-team M2): a report whose envelope is broken (unterminated
            # '---' block, truncated/emptied file) used to vanish from every read
            # surface -- no row, no TAMPERED, no trace at all. A file that merely
            # has no frontmatter envelope is not a report and stays quietly
            # skipped (same convention as `verify`'s "skipped" tally); one that
            # DOES start with '---' but still failed to parse is surfaced here,
            # loud, the same way a digest mismatch is.
            for my $up (@unreadable) {
                print "!! UNREADABLE: $up -- this starts with a frontmatter envelope but "
                    . "could not be parsed (truncated, corrupted, or missing its closing "
                    . "'---'); treat it as tampered until reviewed.\n";
            }
        }
        exit 0;
    }

    if ($cmd eq 'verify') {
        my @bad;
        my $n = 0;
        my @skipped;
        for my $p (AlmanacBug::all_report_paths([$root])) {
            my $rep = $read_only_load->($p);
            # A .md in this directory that has no almanac frontmatter is not a
            # report — typically a hand-written file that predates the state
            # machine, or one imported from it. Calling that "malformed" buries
            # the real signal, so it is counted separately and quietly.
            unless ($rep && defined $rep->{fields}{id}) { push @skipped, $p; next }
            $n++;
            if ($rep->{duplicate_key}) {
                push @bad, ($rep->{fields}{id} // $p)
                    . ": MALFORMED: duplicate frontmatter key '$rep->{duplicate_key}'";
                next;
            }
            my ($ok, $note) = AlmanacBug::verify($rep);
            push @bad, ($rep->{fields}{id} . ": $note") unless $ok;
        }

        # Package 09 (S2.3): the same three-layer doctrine, widened to every
        # almanac record store. require()d here only -- almanac-bug.pl has no
        # other reason to load Almanac::Store, and this keeps that load out
        # of every other verb's startup cost.
        require Almanac::Store;

        # Roots: the caller's own root plus every project known_projects()
        # reports, deduped by canonical_root -- exactly all_report_paths'
        # own root set (S2.3).
        my %seen_root;
        my @project_roots;
        for my $r ($root, AlmanacBug::known_projects()) {
            my $c = AlmanacBug::canonical_root($r);
            next if $seen_root{$c}++;
            push @project_roots, $r;
        }

        my $home = $ENV{ALMANAC_HOME} // $ENV{HOME} // $ENV{USERPROFILE} // '.';
        $home =~ s{\\}{/}g; $home =~ s{/+$}{};

        my @store_dirs;
        for my $r (@project_roots) {
            (my $base = $r) =~ s{\\}{/}g; $base =~ s{/+$}{};
            push @store_dirs, AlmanacBug::_almanac_type_dirs("$base/.ccpraxis-local-data/almanac");
        }
        push @store_dirs, AlmanacBug::_almanac_type_dirs("$home/.claude/claude-code-vault/almanac");

        my %seen_record;
        my @records;
        for my $d (@store_dirs) {
            for my $rp (Almanac::Store::record_files_in($d)) {
                next if $seen_record{$rp}++;
                push @records, $rp;
            }
        }

        my $m = 0;
        my $unsealed_count = 0;
        my @almanac_bad;
        for my $rp (sort @records) {
            (my $type_dir = $rp) =~ s{/[^/]+\z}{};
            my $type = $type_dir; $type =~ s{.*/}{};
            (my $rid = $rp) =~ s{.*/}{}; $rid =~ s{\.md\z}{};

            my $result = Almanac::Store::check_seal($rp);
            my $state  = $result->{state};

            if ($state eq 'tampered' || $state eq 'unreadable') {
                # Locked re-check (S2.3, edge cases): an unlocked read can pair
                # a seal and a record from different moments. The final state
                # comes from the re-check, taken under the record's own lock.
                # Also covers a concurrent DELETE: check_seal's first pass can
                # observe the record mid-removal and report unreadable for a
                # record that is not tampered at all, just gone -- the same
                # false-positive class the re-check already exists to remove.
                my ($lock, $lock_err) = Almanac::Lock->acquire($rp, verb => 'verify', timeout_ms => 2000);
                if ($lock) {
                    $result = Almanac::Store::check_seal($rp);
                    $state  = $result->{state};
                    $lock->release;
                } else {
                    $state = 'busy';
                }
            }

            # Still unreadable after the locked re-check, and the file is
            # simply gone: a sanctioned delete landed between the directory
            # listing and this check. Not tampering -- skip it, uncounted.
            if ($state eq 'unreadable' && !-e $rp) {
                next;
            }

            $m++;
            if ($state eq 'unsealed') {
                $unsealed_count++;
            }
            elsif ($state eq 'tampered') {
                push @almanac_bad,
                    "$type/$rid: TAMPERED: digest $result->{digest} matches no sealed digest -- $rp";
            }
            elsif ($state eq 'bad_seal') {
                push @almanac_bad,
                    "$type/$rid: BAD SEAL: " . Almanac::Store::seal_path_for($rp) . " is not one or two sha256 lines -- $rp";
            }
            elsif ($state eq 'unreadable') {
                push @almanac_bad, "$type/$rid: UNREADABLE -- $rp";
            }
            elsif ($state eq 'busy') {
                push @almanac_bad,
                    "$type/$rid: UNVERIFIED: record is locked by another writer; re-run verify -- $rp";
            }
        }

        printf "skipped %d non-report file(s) in bug-reports/ (no almanac frontmatter)\n",
               scalar @skipped if @skipped;
        print "checked $n report(s)\nchecked $m almanac record(s)\n";
        if ($unsealed_count) {
            print "unsealed $unsealed_count almanac record(s) -- written before sealing existed, or their "
                . "seal was removed; not verifiable until their next sanctioned write\n";
        }
        print "  $_\n" for @bad;
        print "  $_\n" for @almanac_bad;
        exit((@bad || @almanac_bad) ? 2 : 0);
    }

    print STDERR <<'USAGE';
almanac-bug.pl — ccpraxis bug reports, one file per report.

  file --title T (--body - | --body-file F) [--severity S] [--area A] [--project ROOT]
        Create a report in the current project. Prints its path.
  append <id> (--body - | --body-file F)
        Add to the end of a report's body. Allowed ONLY while status is `open`. Use this to record progress — it cannot lose what is already there.
  update <id> (--body - | --body-file F) [--title T] [--severity S] [--replace]
        REPLACE a report's body. Allowed ONLY while status is `open`. Refuses when the existing body would be discarded unless --replace is given; there is no undo, as reports are gitignored.
  set-status <id> --to <state> [--note N] [--repair]
        open -> triaging -> taken -> resolved|declined  (triaging -> open to hand back)
        Moving to `triaging` CLAIMS the report for the calling session (and agent, for a
        subagent) -- the identity comes from a butler hook ticket, never from a flag, and is
        required: run this from a Claude Code session with the butler plugin enabled, with the
        id and every argument written literally (no $variables). Only the claimant may then move
        it on or back to `open`; see `takeover` for a stale claim.
        --repair: ONLY for a report whose current status is not a known state (hand-written, or from before this machine existed). It cannot skip a legal transition between valid states. Put it last on the line.
        Leaving `open` FREEZES the body and records its sha256.
  takeover <id>
        Recovers a STALE triaging claim (no transcript for its claimant, or claimed over 24h ago)
        and records the calling session as the new claimant. Refused on a live claim or a report
        that is not triaging. Requires a hook ticket, exactly like set-status.
  list [--status S] [--json]        reports in THIS PROJECT only; flags a stale triaging claim
  collect [--status S] [--json]     reports across every project REGISTERED in steward's backup registry -- filing a bug and registering for backup are unrelated decisions, so an unregistered project is excluded, not scanned for; flags a stale triaging claim
  verify                            re-check every frozen body against its digest

One report per file. Write only through this script — a PreToolUse hook denies direct edits to the reports directory.
USAGE
    exit 3;
}
1;
