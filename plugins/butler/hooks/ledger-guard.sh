#!/usr/bin/env bash
# ledger-guard.sh — PreToolUse package-ledger write-integrity guard (b12).
#
# Validates the PROSPECTIVE RESULTING CONTENT of any coordinator write that
# lands on $BP_DIR/packages/*.md, and blocks (exit 2 + exactly one stderr line)
# when that result would be corrupt in one of five ways: a control byte, a
# broken frontmatter block, a missing required frontmatter key, an out-of-set
# status:, or a dropped required "##" section heading. See
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b12-ledger-write-integrity-spec.md
# (§2.2 control flow, §2.4 validator contract, §2.5 reconstruction, §2.6 the
# message catalogue) — this script is the implementation of that spec.
#
# FAIL-CLOSED, deliberately, and deliberately unlike b10's repeat-guard: a
# rejected ledger write costs one coordinator retry WITH a diagnostic; an
# accepted corrupt one silently degrades the orchestrator's view of the run for
# hours (ledger_fm returns undef for every key and bp-orchestrator.pl:1039 acts
# on a stale registry status). There is NO kill switch, by design. Exit is only
# ever 0 or 2; nothing is ever written to stdout. No `set -e`, and no
# `trap ... EXIT` (either would clobber the deliberate exit 2).
#
# WHY THE VALIDATOR IS PERL AND NOT BASH+JQ (spec §2.3): a bash variable cannot
# hold a NUL byte and command substitution strips NULs, so a bash-only guard
# structurally could not see the very byte from the incident that created this
# package. JSON escapes U+0000 as the six ASCII bytes \u0000, so the payload
# survives $(cat) intact; the DECODED content — which does carry the raw byte —
# is never handed back to the shell. The payload reaches perl on stdin (never
# argv/env: a whole-file Write can be hundreds of KB and would risk E2BIG).
#
# UNVERIFIED ASSUMPTION (spec §2.5, §6-E6): the MultiEdit arm applies its edits
# SEQUENTIALLY against a progressively-modified buffer. Zero MultiEdit
# PreToolUse payloads exist anywhere on disk in this project, so that semantic
# is assumed, not established. It is settled only by a captured real payload or
# current Claude Code documentation. On present evidence the arm never executes.
#
# THE HIGHEST-RISK LINE IN THE FILE is the Escalation section pattern:
# ^##\s+Escalation\b — a PREFIX, never an exact string. 30/32 live ledgers
# spell it "## Escalation (when status: blocked)"; an exact check would reject
# the entire corpus INCLUDING EVERY GRACEFUL-STOP PARK-WRITE, leaving a stopping
# coordinator with no legal move at all. Do not "tidy" it.
set -u

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"
bp_hook_gate                        # inert outside a coordinator session, at zero cost
bp_hook_require_jq                  # fail-CLOSED (lib.sh:15-21), as guard-writes.sh:20

# b19-ledger-timestamp-integrity: the last_updated: VALUE check (monotonicity +
# future-skew) lives ONCE, in bp-ledger.pl (the b13 API), and this hook `require`s it
# rather than reimplementing it — two copies would drift, and the failure mode is a
# sanctioned API write the guard then rejects, leaving a coordinator with no legal
# move at all. Resolved to an ABSOLUTE path (b43's own landmine: a relative `require`
# depends on the CALLER's cwd, not this script's location, and this hook can be
# invoked from any coordinator's cwd).
LEDGER_PL=$(realpath -m "$HOOK_DIR/../scripts/bp-ledger.pl" 2>/dev/null || printf '%s' "$HOOK_DIR/../scripts/bp-ledger.pl")

PAYLOAD=$(cat)

FILE_PATH=$(jq -r '.tool_input.file_path // empty'     <<<"$PAYLOAD" 2>/dev/null)
NB_PATH=$(jq   -r '.tool_input.notebook_path // empty' <<<"$PAYLOAD" 2>/dev/null)
FP=${FILE_PATH:-$NB_PATH}
[ -n "$FP" ] || exit 0              # no path (incl. empty/unparseable payload) -> not a ledger write

CWD=$(jq -r '.cwd // empty' <<<"$PAYLOAD" 2>/dev/null)
[ -n "$CWD" ] || CWD=$PWD
case "$FP" in /*) ABS="$FP" ;; *) ABS="$CWD/$FP" ;; esac
ABS=$(realpath -m "$ABS" 2>/dev/null || printf '%s' "$ABS")
BP_DIR_N=$(realpath -m "$BP_DIR" 2>/dev/null || printf '%s' "$BP_DIR")

# THE scope gate. Everything else leaves here, before any file I/O: reports/,
# specs/, runs/, packages/*.txt and anything outside $BP_DIR are free-form by
# design and this must never become a general-purpose markdown validator. Both
# the normalised and the raw $BP_DIR forms are matched, as gate-shutdown.sh:41,54
# does, because drive-letter/slash path forms differ under Git-Bash.
case "$ABS" in
  "$BP_DIR_N"/packages/*.md|"$BP_DIR"/packages/*.md) ;;
  *) exit 0 ;;
esac

TOOL=$(jq -r '.tool_name // empty' <<<"$PAYLOAD" 2>/dev/null)

# Belt-and-braces: a markdown ledger is not a notebook, so NotebookEdit could
# only ever corrupt it. Cheap arm, no reconstruction.
if [ "$TOOL" = NotebookEdit ]; then
  printf '%s\n' "LEDGER-GUARD: BLOCKED — NotebookEdit cannot target a package ledger ($ABS): a ledger is markdown, not a notebook. Use Edit or Write." >&2
  exit 2
fi

# Fail-CLOSED on our own missing dependency, exactly as bp_hook_require_jq does.
if ! command -v perl >/dev/null 2>&1; then
  printf '%s\n' "LEDGER-GUARD: BLOCKED — perl is required to validate ledger writes but is missing; blocking to avoid unenforced operation. Install perl in the container." >&2
  exit 2
fi

VALIDATOR=$(cat <<'LG_PERL_PROGRAM'
use strict;
use warnings;
use JSON::PP ();
use B ();

my $ABS  = defined $ENV{LG_ABS}  ? $ENV{LG_ABS}  : '';
my $TOOL = defined $ENV{LG_TOOL} ? $ENV{LG_TOOL} : '';

my @KEYS     = qw(package blueprint status write_set last_updated);
my @STATUSES = qw(pending running converging reviewing done blocked parked);

# --- message emission -------------------------------------------------------
# Exactly ONE line on stderr, ever. Nothing on stdout, ever.
sub emit {
    my ($m) = @_;
    $m =~ s/[\r\n]+/ /g;
    print STDERR $m . "\n";
}
sub deny  { emit($_[0]); exit 2 }
sub allow { exit 0 }

sub m6 {
    my ($reason) = @_;
    my $what = $TOOL ne '' ? $TOOL : 'write';
    deny("LEDGER-GUARD: BLOCKED \xe2\x80\x94 cannot reconstruct the content this $what would leave in $ABS ($reason), so it cannot be validated, and an unvalidated ledger write is not permitted. Use Write with the full file content, or Edit with a non-empty old_string, then retry.");
}
sub m7 {
    my $what = $TOOL ne '' ? $TOOL : 'write';
    deny("LEDGER-GUARD: BLOCKED \xe2\x80\x94 cannot read the current content of $ABS, so the result of this $what cannot be validated. An unvalidated ledger write is not permitted. Fix the file, or replace the ledger wholesale with Write, then retry.");
}

# --- payload helpers --------------------------------------------------------
# A JSON string, as distinct from a number, an object, an array or null. The
# distinction matters: spec §2.5 blocks a Write whose "content" is 42.
sub is_str {
    my ($v) = @_;
    return 0 unless defined $v;
    return 0 if ref $v;
    my $f = B::svref_2object(\$v)->FLAGS;
    return 0 unless $f & B::SVp_POK();
    return 0 if $f & (B::SVp_IOK() | B::SVp_NOK());
    return 1;
}

# Everything downstream is BYTE-oriented, matching ledger_fm's `<:raw` read
# (bp-orchestrator.pl:472) by construction; nothing is ever decoded, so
# arbitrary bytes cannot throw (spec E12).
sub as_bytes {
    my ($s) = @_;
    return '' unless defined $s;
    utf8::encode($s) unless utf8::downgrade($s, 1);
    return $s;
}

sub read_bytes {
    my ($path) = @_;
    m7() if -d $path;
    open(my $fh, '<', $path) or m7();
    binmode($fh);
    my ($out, $buf) = ('', '');
    while (1) {
        my $n = sysread($fh, $buf, 65536);
        if (!defined $n) { close $fh; m7() }
        last if $n == 0;
        $out .= $buf;
    }
    close $fh;
    return $out;
}

sub count_occ {
    my ($hay, $needle) = @_;
    return 0 if $needle eq '';
    my ($n, $p) = (0, 0);
    while ((my $i = index($hay, $needle, $p)) >= 0) { $n++; $p = $i + length($needle) }
    return $n;
}

# LITERAL byte splice, never a regex: old_string routinely carries . * ( [ |
sub splice_bytes {
    my ($hay, $old, $new, $all) = @_;
    my ($out, $p) = ('', 0);
    while ((my $i = index($hay, $old, $p)) >= 0) {
        $out .= substr($hay, $p, $i - $p) . $new;
        $p = $i + length($old);
        last unless $all;
    }
    return $out . substr($hay, $p);
}

sub truthy { my ($v) = @_; return $v ? 1 : 0 }

# --- b19: require the shared last_updated_check() from bp-ledger.pl --------
# FAIL CLOSED if it cannot be loaded, matching this guard's existing discipline for a
# missing perl/jq (bp_hook_require_jq, lib.sh) -- an unenforced guard is worse than a
# blocked write. $LEDGER_PL is an ABSOLUTE path computed by the surrounding bash.
# bp-ledger.pl and this embedded validator share the same (unnamed, so "main") Perl
# package; a couple of its low-level byte helpers (is_str/as_bytes/count_occ/
# splice_bytes) are also defined here (a deliberate "pure lift" the other direction,
# per bp-ledger.pl's own header), so the require would otherwise emit "Subroutine
# redefined" warnings straight to stderr and break the "exactly one line" contract --
# silenced here exactly the way GetOptionsFromArray's warnings are silenced there.
my $LEDGER_PL          = $ENV{LG_LEDGER_PL};
my $HAVE_SHARED_CHECK  = 0;
if (defined $LEDGER_PL && length($LEDGER_PL) && -e $LEDGER_PL) {
    local $SIG{__WARN__} = sub { };
    $HAVE_SHARED_CHECK = eval { require $LEDGER_PL; 1 } ? 1 : 0;
}

# --- the validator: V1 -> V5, first failing class wins ----------------------
sub validate {
    my ($B, $OLD) = @_;

    # V1 control byte. \x7F (DEL) is included, per bp-orchestrator.pl:506.
    if ($B =~ /([\x00-\x08\x0B\x0C\x0E-\x1F\x7F])/) {
        my $off  = $-[1];
        my $byte = ord($1);
        my $pre  = substr($B, 0, $off);
        my $line = 1 + ($pre =~ tr/\n//);
        deny(sprintf(
            'LEDGER-GUARD: BLOCKED ' . "\xe2\x80\x94"
            . ' the content this write would leave in %s contains a control byte 0x%02X at line %d. The ledger is machine-read: grep classifies a control-byte file as binary and suppresses ALL output, so the package reads as having no status at all. Only tab, newline and carriage return are permitted. If you meant to write ABOUT an escape sequence, spell it as text (\x00 or \u0000) rather than emitting the literal byte, then retry.',
            $ABS, $byte, $line));
    }

    # V2 frontmatter block — ledger_fm's own regex (bp-orchestrator.pl:481),
    # verbatim, so the guard agrees with the orchestrator by construction. .*?
    # is non-greedy, so a body-level "---" rule far below is harmless.
    my ($FM) = $B =~ /\A---\s*\n(.*?)\n---/s;
    unless (defined $FM) {
        deny(q{LEDGER-GUARD: BLOCKED } . "\xe2\x80\x94" . q{ the content this write would leave in } . $ABS . q{ has no parseable frontmatter block: it must begin at byte 0 with a line '---' and be closed by a later line '---' (the orchestrator's own reader is /\A---\s*\n(.*?)\n---/s, bp-orchestrator.pl:481). Broken frontmatter does not error } . "\xe2\x80\x94" . q{ ledger_fm returns undef for EVERY key and the orchestrator silently acts on a stale registry status (:1039) with an empty write_set (:1040). Restore the delimiters and retry.});
    }
    my @FML = split(/\n/, $FM, -1);

    # V3 required keys — matched only INSIDE the frontmatter block, byte-identical
    # to ledger_fm:483-484. A body line starting "package:" must not satisfy it.
    my @missing;
    for my $k (@KEYS) {
        my $found = 0;
        for my $l (@FML) { if ($l =~ /^\Q$k\E:\s*(.*?)\s*$/) { $found = 1; last } }
        push @missing, $k unless $found;
    }
    if (@missing) {
        deny('LEDGER-GUARD: BLOCKED ' . "\xe2\x80\x94" . ' the content this write would leave in ' . $ABS
             . ' is missing required frontmatter key(s): ' . join(', ', @missing)
             . '. All of ' . join(', ', @KEYS) . ' must be present inside the frontmatter block. A missing key makes ledger_fm return undef and the orchestrator falls back to a stale registry value (bp-orchestrator.pl:1039). Add the key(s) and retry.');
    }

    # V4 status value — the FIRST status: line wins, as ledger_fm does (spec E8).
    my $status;
    for my $l (@FML) { if ($l =~ /^status:\s*(.*?)\s*$/) { $status = $1; last } }
    $status = '' unless defined $status;
    unless (grep { $_ eq $status } @STATUSES) {
        deny('LEDGER-GUARD: BLOCKED ' . "\xe2\x80\x94" . ' frontmatter status: "' . $status . '" in ' . $ABS
             . ' is not a protocol status. Allowed: ' . join(', ', @STATUSES)
             . ' (coordinator-protocol/SKILL.md:28; converging is ledger-only and never appears in the blueprint table). Set one of those and retry.');
    }

    # V5 required sections. Presence only — NO uniqueness constraint anywhere
    # (s05-responsive-layout.md really carries five "## Next action" headings).
    # "## Next action" uses bp-status.sh:32's own bare awk pattern verbatim, so
    # the guard passes exactly when the reporter finds it. Escalation is a
    # PREFIX with \b: it must accept "## Escalation (when status: blocked)" and
    # reject the unrelated plural "## Escalations raised BY the spec ...".
    my @sections = (
        ['## Next action',             qr/^## Next action/m],
        ['## Decisions & attempt log', qr/^##\s+Decisions & attempt log\b/m],
        ['## Pipeline',                qr/^##\s+Pipeline\b/m],
        ['## Outputs',                 qr/^##\s+Outputs\b/m],
        ['## Escalation',              qr/^##\s+Escalation\b/m],
    );
    my @gone = map { $_->[0] } grep { $B !~ $_->[1] } @sections;
    if (@gone) {
        deny('LEDGER-GUARD: BLOCKED ' . "\xe2\x80\x94" . ' the content this write would leave in ' . $ABS
             . ' drops required section heading(s): ' . join(', ', @gone)
             . '. Every ledger must carry ## Next action, ## Decisions & attempt log, ## Pipeline, ## Outputs and ## Escalation. '
             . q{bp-status.sh:32 locates the next action with a bare awk /^## Next action/ and renders a BLANK CELL rather than an error when it is gone, so the loss is invisible, and the protocol's resumption contract ("execute ## Next action") becomes unsatisfiable. Edit the section BODY; never delete the heading. Restore it and retry.});
    }

    # b19-ledger-timestamp-integrity: last_updated: VALUE monotonicity + future-skew,
    # via the shared check. Fail CLOSED if it could not be loaded at all.
    unless ($HAVE_SHARED_CHECK && defined &main::last_updated_check) {
        deny("LEDGER-GUARD: BLOCKED \xe2\x80\x94 the shared last_updated: integrity check (bp-ledger.pl) could not be loaded, so this write to $ABS cannot be fully validated; blocking rather than allowing an unvalidated ledger write. Ensure bp-ledger.pl is present and requirable at $ENV{LG_LEDGER_PL}, then retry.");
    }
    my $lu_detail = main::last_updated_check($OLD, $B);
    if (defined $lu_detail) {
        deny('LEDGER-GUARD: BLOCKED ' . "\xe2\x80\x94" . ' the content this write would leave in ' . $ABS . ' ' . $lu_detail);
    }

    allow();
}

# --- reconstruction (spec §2.5) ---------------------------------------------
sub run {
    binmode(STDIN);
    my $raw = do { local $/; <STDIN> };
    $raw = '' unless defined $raw;
    my $payload = JSON::PP->new->decode($raw);   # a die here becomes M11
    die "payload is not a JSON object\n" unless ref($payload) eq 'HASH';
    my $ti = $payload->{tool_input};
    $ti = {} unless ref($ti) eq 'HASH';

    if ($TOOL eq 'Write') {
        # content IS the result; the on-disk state was irrelevant to V1-V5, but b19's
        # monotonicity half needs it if a prior ledger happens to exist at $ABS
        # (best-effort only -- an absent or unreadable prior file just means there is
        # nothing to compare the candidate value against).
        my $c = $ti->{content};
        m6('Write payload has no string "content" field') unless is_str($c);
        my $old;
        if (-e $ABS) {
            $old = eval {
                open(my $fh, '<:raw', $ABS) or die "open failed";
                local $/;
                my $b = <$fh>;
                close $fh;
                defined $b ? $b : '';
            };
        }
        validate(as_bytes($c), $old);
    }
    elsif ($TOOL eq 'Edit') {
        # THE FAIL-CLOSED ASYMMETRY, and a naive reading gets it backwards: where
        # the real Edit would itself error (target absent, old_string absent from
        # the file, old_string ambiguous without replace_all) ALLOW is the
        # fail-closed answer — no bytes reach disk, so there is nothing to
        # protect, while blocking is a pure false positive costing a coordinator
        # turn over a splice that can never happen. Fail-closed means "no
        # unvalidated bytes reach the ledger", not "exit 2 whenever uncertain".
        allow() unless -e $ABS;
        my $orig = read_bytes($ABS);
        my ($old, $new) = ($ti->{old_string}, $ti->{new_string});
        m6('Edit payload has no string old_string/new_string')
            unless is_str($old) && is_str($new);
        $old = as_bytes($old);
        $new = as_bytes($new);
        m6('empty old_string') if $old eq '';
        my $all = truthy($ti->{replace_all});
        my $n   = count_occ($orig, $old);
        allow() if $n == 0;
        allow() if $n > 1 && !$all;
        validate(splice_bytes($orig, $old, $new, $all), $orig);
    }
    elsif ($TOOL eq 'MultiEdit') {
        my $edits = $ti->{edits};
        my $bad   = '"edits" is missing or is not a non-empty array of {old_string,new_string} objects';
        m6($bad) unless ref($edits) eq 'ARRAY' && @$edits;
        for my $e (@$edits) {
            m6($bad) unless ref($e) eq 'HASH'
                         && is_str($e->{old_string}) && is_str($e->{new_string});
        }
        allow() unless -e $ABS;
        my $buf  = read_bytes($ABS);
        my $orig = $buf;
        for my $e (@$edits) {                      # <-- THE UNVERIFIED ASSUMPTION
            my $old = as_bytes($e->{old_string});
            my $new = as_bytes($e->{new_string});
            m6('empty old_string') if $old eq '';
            my $all = truthy($e->{replace_all});
            my $n   = count_occ($buf, $old);
            allow() if $n == 0;                    # real MultiEdit is atomic: it
            allow() if $n > 1 && !$all;            # errors, so nothing lands
            $buf = splice_bytes($buf, $old, $new, $all);
        }
        validate($buf, $orig);
    }
    elsif ($TOOL eq 'NotebookEdit') {
        deny("LEDGER-GUARD: BLOCKED \xe2\x80\x94 NotebookEdit cannot target a package ledger ($ABS): a ledger is markdown, not a notebook. Use Edit or Write.");
    }
    else {
        m6($TOOL eq '' ? 'payload has no tool_name' : qq(unrecognised tool "$TOOL"));
    }
}

# Spec E10: an internal failure blocks with M11 rather than leaking exit 1 or an
# accidental 0. allow()/deny() exit outright, so they are never caught here.
unless (eval { run(); 1 }) {
    my $e = $@ || 'unknown error';
    $e =~ s/[\r\n]+/ /g;
    $e =~ s/\s+\z//;
    emit("LEDGER-GUARD: BLOCKED \xe2\x80\x94 the ledger guard failed internally while validating this write ($e) and cannot certify the result; blocking rather than allowing an unvalidated ledger write. Record this under " . q{'## Next action'} . ".");
    exit 2;
}
exit 0;
LG_PERL_PROGRAM
)

printf '%s' "$PAYLOAD" | LG_ABS="$ABS" LG_TOOL="$TOOL" LG_LEDGER_PL="$LEDGER_PL" perl -e "$VALIDATOR"
exit $?
