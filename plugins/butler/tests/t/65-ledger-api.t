#!/usr/bin/env perl
# b13-deterministic-ledger-api oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b13-deterministic-ledger-api-spec.md
# §2 (contracts, V1-V5, the five ops), §3 (behaviours B1..B62), §4 (AC-1..AC-63), §6 (edge cases).
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. plugins/butler/scripts/bp-ledger.pl does not exist at the
# time this file was authored. Every AC assertion below must therefore fail on MISSING BEHAVIOUR,
# never on a bug in this file. Assertions labelled FIXTURE-SANITY: / HARNESS: are deliberate
# self-checks and are expected to pass with the script absent -- they are the evidence that the red
# is attributable to the missing implementation and not to broken scaffolding.
#
# WHY EVERY exit-2 EXPECTATION ALSO ASSERTS THE STDERR SHAPE: with bp-ledger.pl absent,
# `perl <missing>` itself exits 2 with a MULTI-line "Can't open perl script" on stderr. An
# exit-code-only assertion would therefore FALSELY PASS. Each rejection block asserts exit 2 AND
# exactly one stderr line AND the spec's framing prefix (§2.2), so the missing script cannot fake it.
#
# HARNESS RULES (from spec §2.9 and the coordinator's measured terrain; not re-derived):
#   * done_testing(), NEVER a hand-counted plan.
#   * %CLEAN_ENV strips every ambient BP_*: this suite is run BY coordinator sessions that export
#     BP_LEDGER/BP_DIR/BP_PROJECT_ROOT, and an inherited value turns the env-gate tests into false
#     passes.
#   * The hook is invoked as `bash "$HOOK"`, never executed directly: a missing exec bit must not
#     masquerade as a deny.
#   * NO LIVE LEDGER IS EVER WRITTEN. Corpus files are COPIED into a temp dir and every mutating op
#     runs on the copy. AC-41 digests every enumerated corpus file before and after the whole run.
#   * Corpus enumeration is perl `glob` on explicit paths -- NEVER `grep -r`/ripgrep on a directory:
#     .ccpraxis-local-data/ is gitignored, so a directory-scoped rg searches ZERO files and reports a
#     FALSE CLEAN. AC-43 proves this test's own method is the non-vacuous one.
#   * TWO globs, not one: `blueprints/*/packages/*.md` (active) PLUS
#     `blueprints/_archive/*/packages/*.md` (archived, one level deeper). A single `*` silently omits
#     every archive file -- the bug that hid two rejects for three corpus counts running.
#   * NO CORPUS SIZE IS EVER ASSERTED (AC-38). The corpus has grown 32 -> 49 -> 51 -> 115; pinning a
#     tally guarantees future spurious red. Non-vacuity and shape only.
#   * Durability assertions run in a temp dir created INSIDE $BP_DIR (v9fs), never /tmp (overlayfs).
#     A rename/flock assertion on overlayfs proves nothing about the filesystem ledgers live on.
#   * Output is captured via temp files, never by reopening STDOUT onto an in-memory scalar
#     (Git-for-Windows perl fails there with "Bad file descriptor"; project CLAUDE.md landmine).
#
# NO `use utf8` HERE, DELIBERATELY. The em dash in the append-attempt entry format is written as the
# raw bytes \xE2\x80\x94, because §2.4 is byte-oriented throughout and nothing is ever decoded.
#
# SYN-23: no assertion, fixture or comment in this file cites a line number in bp-orchestrator.pl.
# Everything about that file is located by grep pattern. AC-58 asserts it against this file itself.
#
# OUT-OF-FILE ACs (recorded here rather than asserted weakly):
#   * AC-54 -- `perl plugins/butler/tests/t/64-ledger-guard.t` exits 0. t/64 is the delegation's
#     byte-behaviour oracle and is NEVER read, edited or imported by this file (§2.9). Coordinator-
#     verified by running it.
#   * AC-55 -- "this file exits 0 with zero not ok" is self-referential. Coordinator-judged.
#   * AC-56 -- no new red in plugins/butler/tests/t/ attributable to b13; needs a before/after
#     baseline across the whole suite. Coordinator-verified.
#   * AC-57 -- `git diff --name-only` equals exactly the four write-set files. Coordinator-verified
#     (a test asserting it would fail on every unrelated in-flight edit in the working tree).

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use File::Basename qw(basename);
use Cwd qw(abs_path);
use Fcntl qw(:flock);
use JSON::PP;
use Digest::MD5 qw(md5_hex);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $TESTS   = fwd("$Bin");
my $BUTLER  = fwd(abs_path("$Bin/../..") // "$Bin/../..");
my $PROJ    = fwd(abs_path("$Bin/../../../..") // "$Bin/../../../..");
my $SCRIPT  = "$BUTLER/scripts/bp-ledger.pl";
my $HOOK    = "$BUTLER/hooks/ledger-guard.sh";
my $HOOKSJS = "$BUTLER/hooks/hooks.json";
my $SKILL   = "$BUTLER/skills/coordinator-protocol/SKILL.md";
my $SELF    = "$TESTS/65-ledger-api.t";

my $BP_ROOT = "$PROJ/.ccpraxis-local-data";
my $BP_DIR  = "$BP_ROOT/blueprints/sandbox-butler-overhaul";

my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
my $pn   = 0;

# A test of a hook/script must control its environment COMPLETELY.
my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

diag("subject under test: $SCRIPT "
     . (-e $SCRIPT
        ? "(present)"
        : "(ABSENT -- every AC assertion below is expected to fail on MISSING BEHAVIOUR)"));
diag("hook under test: $HOOK " . (-e $HOOK ? "(present)" : "(ABSENT)"));

# =====================================================================================
# Scaffolding
# =====================================================================================

sub write_file {
    my ($path, $bytes) = @_;
    open my $w, '>', $path or die "write $path: $!";
    binmode $w;
    print $w $bytes;
    close $w or die "close $path: $!";
    return $path;
}

sub read_file {
    my ($path) = @_;
    open my $r, '<', $path or return undef;
    binmode $r;
    my $c = do { local $/; <$r> };
    close $r;
    return defined $c ? $c : '';
}

# ---- process runners ---------------------------------------------------------------
# stdout and stderr are captured SEPARATELY: §2.2 makes "stdout is ALWAYS empty" an interface, and a
# combined capture cannot assert it.
sub run_pl {
    my ($args, %opt) = @_;
    my $n    = ++$pn;
    my $inf  = "$ROOT/in.$n";
    my $outf = "$ROOT/out.$n";
    my $errf = "$ROOT/err.$n";
    write_file($inf, defined $opt{stdin} ? $opt{stdin} : '');
    write_file($outf, '');
    write_file($errf, '');
    my %extra = %{ $opt{env} || {} };
    local %ENV = (%CLEAN_ENV, %extra,
                  LGT_SCRIPT => fwd($SCRIPT), LGT_IN => fwd($inf),
                  LGT_OUT    => fwd($outf),   LGT_ERR => fwd($errf));
    my $rc = system('bash', '-c',
        'timeout 60 perl "$LGT_SCRIPT" "$@" < "$LGT_IN" > "$LGT_OUT" 2> "$LGT_ERR"',
        'bp-ledger', @$args);
    return ($rc >> 8, read_file($outf) // '', read_file($errf) // '');
}

# payload -> temp file -> `timeout 60 bash "$HOOK" < payload`. Invoked via bash (never executed
# directly) so a missing exec bit cannot produce a false deny. stderr captured separately.
sub run_hook {
    my ($payload, %env) = @_;
    my $n    = ++$pn;
    my $pf   = write_file("$ROOT/payload.$n.json", $payload);
    my $outf = write_file("$ROOT/hout.$n", '');
    my $errf = write_file("$ROOT/herr.$n", '');
    local %ENV = (%CLEAN_ENV, %env,
                  LGT_HOOK => fwd($HOOK), LGT_IN => fwd($pf),
                  LGT_OUT  => fwd($outf), LGT_ERR => fwd($errf));
    my $rc = system('bash', '-c',
        'timeout 60 bash "$LGT_HOOK" < "$LGT_IN" > "$LGT_OUT" 2> "$LGT_ERR"');
    return ($rc >> 8, read_file($outf) // '', read_file($errf) // '');
}

sub have_cmd {
    my ($c) = @_;
    local %ENV = (%CLEAN_ENV, LGT_C => $c);
    my $rc = system('bash', '-c', 'command -v "$LGT_C" >/dev/null 2>&1');
    return ($rc >> 8) == 0 ? 1 : 0;
}

# ---- byte-level diff primitives (strict, implementation-blind) ----------------------
# Exactly one contiguous insertion: returns the inserted bytes, or undef if the change is not one
# contiguous insertion. This IS AC-7's `prefix . suffix eq ORIG`.
sub contiguous_insertion {
    my ($orig, $new) = @_;
    return undef if length($new) <= length($orig);
    my $p = 0;
    $p++ while $p < length($orig) && substr($orig, $p, 1) eq substr($new, $p, 1);
    my $s = 0;
    while ($s < length($orig) - $p
           && substr($orig, length($orig) - 1 - $s, 1) eq substr($new, length($new) - 1 - $s, 1)) {
        $s++;
    }
    return undef unless $p + $s == length($orig);
    return substr($new, $p, length($new) - length($orig));
}

# Byte offsets at which two EQUAL-LENGTH strings differ.
sub differing_offsets {
    my ($a, $b) = @_;
    return (-1) if length($a) != length($b);
    my @off;
    for my $i (0 .. length($a) - 1) {
        push @off, $i if substr($a, $i, 1) ne substr($b, $i, 1);
    }
    return @off;
}

# Multiset line diff: (\@removed, \@added).
sub line_diff {
    my ($a, $b) = @_;
    my %c;
    $c{$_}++ for split /\n/, $a, -1;
    $c{$_}-- for split /\n/, $b, -1;
    my (@rm, @add);
    for my $l (sort keys %c) {
        push @rm,  ($l) x $c{$l}  if $c{$l} > 0;
        push @add, ($l) x -$c{$l} if $c{$l} < 0;
    }
    return (\@rm, \@add);
}

sub subst_first_line {
    my ($s, $re, $repl) = @_;
    my @l = split /\n/, $s, -1;
    for my $i (0 .. $#l) {
        if ($l[$i] =~ $re) { $l[$i] = $repl; return join("\n", @l) }
    }
    return undef;
}

sub first_line_matching {
    my ($s, $re) = @_;
    for my $l (split /\n/, $s, -1) { return $l if $l =~ $re }
    return undef;
}

sub count_re {
    my ($s, $re) = @_;
    my $n = 0;
    $n++ while $s =~ /$re/g;
    return $n;
}

sub ticked_count { return count_re($_[0], qr/^[ \t]*-[ \t]*\[[xX]\]/m) }

# Extract a `## <name>` section INCLUDING its heading line, up to (not incl.) the next `##` line.
# Fence-naive on purpose: only ever used on synthetic fixtures with no fences in the target section.
sub section_of {
    my ($s, $head_re) = @_;
    my @l = split /\n/, $s, -1;
    my @out;
    my $in = 0;
    for my $l (@l) {
        if (!$in) { if ($l =~ $head_re) { $in = 1; push @out, $l } next }
        last if $l =~ /^##\s/;
        push @out, $l;
    }
    return $in ? join("\n", @out) : undef;
}

sub errline_ok {
    my ($err, $label) = @_;
    my @l = split /\n/, $err, -1;
    pop @l if @l && $l[-1] eq '';
    return (scalar(@l) == 1 && $err =~ /\n\z/) ? 1 : 0;
}

sub one_stderr_line {
    my ($err) = @_;
    my @l = split /\n/, $err, -1;
    pop @l if @l && $l[-1] eq '';
    return scalar(@l);
}

sub glob_tmp {
    my ($dir, $pat) = @_;
    my @f = glob("$dir/$pat");
    return @f;
}

sub dirname_of { (my $d = $_[0]) =~ s{/[^/]+\z}{}; return $d }

# ---- fence primitives (§2.11) ------------------------------------------------------
# A fence toggles on any line whose leading-whitespace-stripped form starts with >=3 backticks or
# >=3 tildes. Returns the list of lines that are INSIDE a fence (fence delimiters excluded).
# CORRECTED 2026-08-03 (coordinator, b13 step 4). These helpers were naive —
#   if ($l =~ /^[ \t]*(?:`{3,}|~{3,})/) { $in = !$in; next }
# — which is self-defeating on this suite's own b09 fixture. b09:625 is prose
# containing an inline ``` `## Next action` ``` aside; the only real fence pair is
# 925/928. Naive counting sees 3 fence lines (odd), so b09 reads as having an
# unterminated fence, and spec §2.11 then REQUIRES append-attempt to exit 5 —
# contradicting AC-8's own "append-attempt on b09 exits 0". Measured: under the
# naive rule AC-8 fails assertions 125/126/128; no implementation can satisfy it.
# Corrected to the CommonMark rule the implementation uses (a backtick fence's info
# string may not itself contain a backtick), so oracle and parser agree on what a
# fence IS — an agreement the fence-scoped MEANS-DEVIATION guard depends on.
sub is_fence_delim {
    my ($l) = @_;
    if ($l =~ /^[ \t]*(`{3,})(.*)$/s) { return index($2, '`') >= 0 ? 0 : 1 }
    return 1 if $l =~ /^[ \t]*~{3,}/;
    return 0;
}

sub fenced_lines {
    my ($s) = @_;
    my ($in, @out) = (0);
    for my $l (split /\n/, $s, -1) {
        if (is_fence_delim($l)) { $in = !$in; next }
        push @out, $l if $in;
    }
    return @out;
}

# Is byte offset $off inside a fenced code block?
sub offset_in_fence {
    my ($s, $off) = @_;
    my $pre = substr($s, 0, $off);
    my @l   = split /\n/, $pre, -1;
    pop @l;                                # the (partial) line containing $off is not yet closed
    my $in = 0;
    for my $l (@l) { $in = !$in if is_fence_delim($l) }
    return $in ? 1 : 0;
}

# Every line beginning with whitespace then a non-space (a wrapped continuation line).
sub indented_lines {
    my ($s) = @_;
    return grep { /^[ \t]+\S/ } split /\n/, $s, -1;
}

sub count_occ {
    my ($hay, $needle) = @_;
    return 0 if !length $needle;
    my ($n, $pos) = (0, 0);
    while ((my $i = index($hay, $needle, $pos)) >= 0) { $n++; $pos = $i + length($needle) }
    return $n;
}

# ---- fixture dirs ------------------------------------------------------------------
my $dn = 0;
sub fresh_dir {
    my $d = "$ROOT/w" . (++$dn);
    mkdir $d or die "mkdir $d: $!";
    return $d;
}

# Copy bytes into a fresh dir under the temp root and return the copy's path.
sub stage_bytes {
    my ($bytes, $name) = @_;
    $name = 'fixture-pkg.md' unless defined $name;
    my $d = fresh_dir();
    return write_file("$d/$name", $bytes);
}

# Copy a REAL corpus file into a fresh temp dir. The real file is never opened for writing.
sub stage_corpus {
    my ($src) = @_;
    my $d = fresh_dir();
    my $dst = "$d/" . basename($src);
    my $bytes = read_file($src);
    die "stage_corpus: cannot read $src" unless defined $bytes;
    write_file($dst, $bytes);
    return $dst;
}

# =====================================================================================
# Synthetic fixtures (§2.8)
# =====================================================================================

my $EMDASH = "\xE2\x80\x94";

# A structurally valid ledger satisfying V1-V5. Every section the ops target is present, plus a
# `## Dispatch log (auto)` (AC-29) and one-off headings the API must leave alone (§2.3).
sub clean_ledger {
    my (%o) = @_;
    my $status  = defined $o{status}  ? $o{status}  : 'running';
    my $attempt = exists $o{attempt}  ? $o{attempt} : "- 2026-07-29T10:00:00Z $EMDASH earlier note";
    my $outputs = exists $o{outputs}  ? $o{outputs} : "- ran something: exit 0";
    my $nextact = defined $o{next}    ? $o{next}    : "Do the first thing.";
    my $pipe    = defined $o{pipeline} ? $o{pipeline} : join("\n",
        '- [ ] 1. first step',
        '- [ ] 2. second step',
        '      wrapped continuation for step 2',
        '- [ ] 3. third step',
        '- [ ] 11. eleventh step');
    return join("\n",
        '---',
        'package: fixture-pkg',
        'blueprint: fixture-bp',
        "status: $status",
        'write_set:',
        '  - plugins/butler/scripts/bp-ledger.pl',
        'mandated_means: none',
        'last_updated: 2026-07-01T00:00:00Z',
        '---',
        '',
        '# fixture-pkg',
        '',
        '## Scope',
        '',
        'Prose section no op may touch.',
        '',
        '## Next action',
        '',
        $nextact,
        '',
        '## Pipeline',
        '',
        $pipe,
        '',
        '## Decisions & attempt log',
        '',
        $attempt,
        '',
        '## Outputs',
        '',
        $outputs,
        '',
        '## Escalation (when status: blocked)',
        '',
        '_(none)_',
        '',
        '## Dispatch log (auto)',
        '',
        '- 2026-07-01T00:00:00Z dispatched worker bp-implementer',
        '',
    );
}

# Placeholder-bodied variant: `_(none)_` in the attempt log, `_(none yet)_` in Outputs (AC-12, AC-27).
sub placeholder_ledger { return clean_ledger(attempt => '_(none)_', outputs => '_(none yet)_') }

# `## Pipeline` carrying a FENCED `- [ ] 2.` lookalike before the real one (AC-20).
sub fenced_pipeline_ledger {
    return clean_ledger(pipeline => join("\n",
        '```text',
        '- [ ] 2. fenced lookalike that must never flip',
        '## Fenced heading that must not terminate the section',
        '```',
        '- [ ] 1. first step',
        '- [ ] 2. the REAL second step',
    ));
}

# `## Decisions & attempt log` ending inside an UNTERMINATED fence (AC-13, exit 5).
sub unterminated_fence_ledger {
    my $l = clean_ledger();
    $l =~ s/\Q- 2026-07-29T10:00:00Z $EMDASH earlier note\E/"```text\nopened and never closed"/e;
    return $l;
}

sub bom_ledger      { return "\xEF\xBB\xBF" . clean_ledger() }
sub crlf_ledger     { my $l = clean_ledger(); $l =~ s/\n/\r\n/g; return $l }
sub lone_cr_ledger  { my $l = clean_ledger(); $l =~ s/Do the first thing\./Do the\rfirst thing./; return $l }
sub nonascii_ledger { my $l = clean_ledger(); $l =~ s/earlier note/earlier note by Andr\xC3\xA9/; return $l }

# Synthetic control-byte fixture: the live corpus has ZERO control bytes (the q01 NUL was cleaned),
# so this MUST be synthetic or every V1 assertion is vacuous (§2.8, R6).
sub ctrl_ledger {
    my ($byte) = @_;
    my $l = clean_ledger();
    $l =~ s/Do the first thing\./"Do the first" . $byte . " thing."/e;
    return $l;
}

# The line number V1 must report for ctrl_ledger(): 1 + (newlines before the byte).
sub ctrl_lineno {
    my ($bytes, $byte) = @_;
    my $i = index($bytes, $byte);
    return -1 if $i < 0;
    my $pre = substr($bytes, 0, $i);
    return 1 + ($pre =~ tr/\n//);
}

sub drop_line_matching {
    my ($s, $re) = @_;
    my @l = split /\n/, $s, -1;
    for my $i (0 .. $#l) {
        if ($l[$i] =~ $re) { splice(@l, $i, 1); return join("\n", @l) }
    }
    die "drop_line_matching: nothing matched $re";
}

# ---- payload builders (hook / --payload seam) --------------------------------------
sub pl_write {
    my ($path, $content) = @_;
    return $J->encode({ tool_name => 'Write', cwd => $PROJ,
                        tool_input => { file_path => $path, content => $content } });
}
sub pl_write_number {   # content is the JSON NUMBER 42 -- the is_str SV-flag case (AC-31)
    my ($path) = @_;
    return $J->encode({ tool_name => 'Write', cwd => $PROJ,
                        tool_input => { file_path => $path, content => 42 } });
}
# ---- AC-64: the Edit-payload uniqueness interlock -----------------------------------
# MEASURED TRAP, not a hypothetical. ledger-guard's fail-closed allow trio (§2.5, AC-36) allows an
# Edit whose `old_string` occurs 0 times, or >1 times with replace_all=false, because the real Edit
# tool would itself error. A deny-path payload built on a NON-UNIQUE old_string therefore returns
# rc=0 and the deny assertion PASSES WHILE TESTING THE OPPOSITE OF WHAT IT CLAIMS.
#
# So this helper is the interlock, not the call sites: it reads the target's on-disk bytes, ASSERTS
# the occurrence count, and REFUSES (dies) to build a replace_all=false payload whose old_string is
# not unique. The fail-closed-trio cases opt in explicitly with expect_occ => 0 | 2.
my $edit_n = 0;
sub pl_edit {
    my ($path, $old, $new, %o) = @_;
    my $all  = $o{replace_all} ? 1 : 0;
    my $want = exists $o{expect_occ} ? $o{expect_occ} : 1;
    my $bytes = read_file($path);
    my $occ   = defined $bytes ? count_occ($bytes, $old) : -1;   # -1 == target absent
    my $n     = ++$edit_n;
    is($occ, $want,
       "AC-64: Edit payload #$n -- old_string occurs exactly $want time(s) in the target's on-disk "
       . "bytes (the uniqueness precondition without which the deny path is vacuous)")
        unless $o{selftest};
    if (!$all && $want == 1 && $occ != 1) {
        die "AC-64 VIOLATION: refusing to build an Edit payload whose old_string occurs "
          . "$occ time(s) in $path with replace_all=false. Such a payload takes ledger-guard's "
          . "documented 'would-error-anyway => allow' path (rc=0), so any denial asserted from it "
          . "would be VACUOUS.\n";
    }
    return $J->encode({ tool_name => 'Edit', cwd => $PROJ,
                        tool_input => { file_path => $path, old_string => $old,
                                        new_string => $new,
                                        replace_all => ($all ? JSON::PP::true : JSON::PP::false) } });
}

# HARNESS: prove the AC-64 interlock actually fires. Without this, the interlock could itself be
# vacuous -- the same class of bug it exists to prevent.
{
    my $dup = stage_bytes("---\nstatus: running\n---\ndup\ndup\n", 'dup-fixture.md');
    my $e = do { local $@; eval { pl_edit($dup, "dup\n", "other\n", selftest => 1) }; $@ };
    like($e, qr/AC-64 VIOLATION/,
         "HARNESS/AC-64: the Edit-payload builder REFUSES a non-unique old_string with replace_all=false");
    my $ok = do { local $@; eval { pl_edit($dup, "status: running", "status: bogus", selftest => 1) }; $@ };
    is($ok, '', "HARNESS/AC-64: ...and accepts a unique old_string");
    my $trio = do { local $@; eval { pl_edit($dup, "dup\n", "other\n", selftest => 1, expect_occ => 2) }; $@ };
    is($trio, '', "HARNESS/AC-64: ...and permits the fail-closed-trio cases via an explicit expect_occ");
}

# =====================================================================================
# Corpus enumeration -- TWO globs, explicit paths, no counts asserted (§2.7, AC-38)
# =====================================================================================

my @ACTIVE  = sort glob("$BP_ROOT/blueprints/*/packages/*.md");
my @ARCHIVE = sort glob("$BP_ROOT/blueprints/_archive/*/packages/*.md");
my @ALL     = (@ACTIVE, @ARCHIVE);

sub corpus_by_suffix {
    my ($suffix) = @_;
    my @m = grep { index($_, $suffix) >= 0 && substr($_, -length($suffix)) eq $suffix } @ALL;
    return $m[0];
}

my $FX_S05     = corpus_by_suffix('/packages/s05-responsive-layout.md');
my $FX_B09     = corpus_by_suffix('/packages/b09-judge-starvation-and-verdict-archive.md');
my $FX_B28     = corpus_by_suffix('/packages/b28-contract-idle-window.md');
my $FX_B13     = corpus_by_suffix('/packages/b13-deterministic-ledger-api.md');
my $FX_LEGACY  = corpus_by_suffix('/_archive/audit-remediation/packages/11-sandbox-rework-finalization.md');

# AC-41 pre-image: digest EVERY enumerated corpus file before anything runs.
my %CORPUS_DIGEST_BEFORE = map { $_ => md5_hex(read_file($_) // '') } @ALL;

# =====================================================================================
# TODO groups -- filled in below, one Edit per group
# =====================================================================================

# =====================================================================================
# [G0] Harness self-checks + fixture sanity.
# These are expected to PASS with bp-ledger.pl absent. They are the evidence that the red below is
# missing behaviour, not broken scaffolding.
# =====================================================================================

ok(scalar(@ACTIVE)  >= 1, "FIXTURE-SANITY: active glob blueprints/*/packages/*.md is non-empty");
ok(scalar(@ARCHIVE) >= 1, "FIXTURE-SANITY: archive glob blueprints/_archive/*/packages/*.md is non-empty");
for my $pair (['s05', $FX_S05], ['b09', $FX_B09], ['b28', $FX_B28],
              ['b13', $FX_B13], ['legacy 11-sandbox-rework-finalization', $FX_LEGACY]) {
    ok(defined $pair->[1] && -r $pair->[1],
       "FIXTURE-SANITY: mandatory corpus fixture located: $pair->[0]");
}
{
    my $s05 = defined $FX_S05 ? read_file($FX_S05) : '';
    ok(count_re($s05, qr/^## Next action/m) >= 2,
       "FIXTURE-SANITY: s05 carries more than one '## Next action' heading");
    my $b09 = defined $FX_B09 ? read_file($FX_B09) : '';
    ok(count_re($b09, qr/^[ \t]*(?:```|~~~)/m) >= 2,
       "FIXTURE-SANITY: b09 carries fenced code blocks");
    my $b13 = defined $FX_B13 ? read_file($FX_B13) : '';
    ok($b13 =~ /^[ \t]*-[ \t]*\[[ xX]\][ \t]*\d+\..*\n[ \t]+\S/m,
       "FIXTURE-SANITY: b13's own ledger has a WRAPPED pipeline checkbox (continuation line)");
}
{
    my $c = clean_ledger();
    ok($c =~ /\A---\s*\n(.*?)\n---/s,      "FIXTURE-SANITY: synthetic clean ledger satisfies V2");
    ok($c !~ /([\x00-\x08\x0B\x0C\x0E-\x1F\x7F])/, "FIXTURE-SANITY: synthetic clean ledger satisfies V1");
    for my $h ('^## Next action', '^##\s+Decisions & attempt log\b', '^##\s+Pipeline\b',
               '^##\s+Outputs\b', '^##\s+Escalation\b') {
        ok($c =~ /$h/m, "FIXTURE-SANITY: synthetic clean ledger satisfies V5 ($h)");
    }
    is(substr($c, -1), "\n", "FIXTURE-SANITY: synthetic clean ledger ends with exactly one newline");
    ok($c !~ /\n\n\z/,       "FIXTURE-SANITY: ...and not two");
    my $nul = ctrl_ledger("\x00");
    ok(index($nul, "\x00") >= 0, "FIXTURE-SANITY: synthetic NUL fixture actually contains 0x00");
    ok(ctrl_lineno($nul, "\x00") > 1, "FIXTURE-SANITY: NUL fixture's expected V1 line number is computable");
    ok(unterminated_fence_ledger() =~ /```text\nopened and never closed/,
       "FIXTURE-SANITY: unterminated-fence fixture built");
    ok(count_re(fenced_pipeline_ledger(), qr/^- \[ \] 2\./m) == 2,
       "FIXTURE-SANITY: fenced-pipeline fixture has a fenced AND a real '- [ ] 2.'");
    ok(placeholder_ledger() =~ /^_\(none\)_$/m && placeholder_ledger() =~ /^_\(none yet\)_$/m,
       "FIXTURE-SANITY: placeholder fixture carries both italic placeholders");
}
{   # HARNESS: contiguous_insertion / differing_offsets are the strictness of half this file.
    is(contiguous_insertion("ab\ncd\n", "ab\nXX\ncd\n"), "XX\n", "HARNESS: contiguous_insertion finds the insert");
    is(contiguous_insertion("ab\ncd\n", "ab\ncX\n"), undef,      "HARNESS: contiguous_insertion rejects a non-insertion");
    is_deeply([differing_offsets("- [ ] 3.", "- [x] 3.")], [3], "HARNESS: differing_offsets pinpoints one byte");
}

# =====================================================================================
# [G1] set-status -- AC-1..AC-6, AC-9
# =====================================================================================

my $ISO_RE = qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

{   # ---- AC-1 (B1): exit 0, status set, fresh ISO stamp, EXACTLY two changed lines, both in FM.
    my $p    = stage_bytes(clean_ledger(status => 'running'));
    my $orig = read_file($p);
    my ($rc, $out, $err) = run_pl(['set-status', '--ledger', $p, '--status', 'done']);
    is($rc, 0, "AC-1: set-status --status done exits 0");
    is($out, '', "AC-1: stdout is empty");
    is($err, '', "AC-1: stderr is empty on success");
    my $new = read_file($p);
    like($new, qr/^status: done$/m, "AC-1: frontmatter status: is now done");
    my $lu = first_line_matching($new, qr/^last_updated:/);
    $lu = '' unless defined $lu;
    my ($luv) = $lu =~ /^last_updated:\s*(.*?)\s*$/;
    like(defined $luv ? $luv : '', $ISO_RE, "AC-1: last_updated: is a fresh YYYY-MM-DDThh:mm:ssZ");
    isnt($lu, first_line_matching($orig, qr/^last_updated:/),
         "AC-1: ...and it actually changed (not the stale value already on disk)");
    my ($rm, $add) = line_diff($orig, $new);
    is(scalar(@$rm),  2, "AC-1: exactly two lines removed");
    is(scalar(@$add), 2, "AC-1: exactly two lines added");
    my $fm_end = index($new, "\n---", 3);
    my $ok_fm  = (scalar(@$add) == 2) ? 1 : 0;
    for my $l (@$add) { $ok_fm = 0 unless $l =~ /^(status|last_updated):/ && index($new, "$l\n") < $fm_end }
    ok($ok_fm, "AC-1: both changed lines are status:/last_updated: INSIDE the frontmatter block");
    # Exact: substituting the two original lines back reproduces ORIG byte-for-byte.
    my $back = subst_first_line($new, qr/^status:/, first_line_matching($orig, qr/^status:/) // '');
    $back = defined $back
        ? subst_first_line($back, qr/^last_updated:/, first_line_matching($orig, qr/^last_updated:/) // '')
        : undef;
    is(($new eq $orig ? '(FILE WAS NOT MUTATED AT ALL)' : (defined $back ? $back : '(undef)')), $orig,
       "AC-1: restoring only those two lines reproduces ORIG byte-for-byte (body untouched)");
}

{   # ---- AC-2 (B1): each of the seven protocol statuses is accepted.
    for my $s (qw(pending running converging reviewing done blocked parked)) {
        my $p    = stage_bytes(clean_ledger(status => 'pending'));
        my $orig = read_file($p);
        my ($rc, $out, $err) = run_pl(['set-status', '--ledger', $p, '--status', $s]);
        is($rc, 0, "AC-2: --status $s accepted (exit 0)");
        my $new = read_file($p);
        like($new, qr/^status: \Q$s\E$/m, "AC-2: --status $s written to frontmatter");
        isnt(first_line_matching($new, qr/^last_updated:/),
             first_line_matching($orig, qr/^last_updated:/),
             "AC-2: --status $s re-stamped last_updated: in the same operation");
    }
}

{   # ---- AC-3 (B3): a value outside the seven -> exit 3, one line naming offered + all seven.
    for my $bad ('Done', 'finished', '') {
        my $p    = stage_bytes(clean_ledger());
        my $orig = read_file($p);
        my ($rc, $out, $err) = run_pl(['set-status', '--ledger', $p, '--status', $bad]);
        is($rc, 3, "AC-3: --status '$bad' exits 3 (argument fault, nothing read)");
        is($out, '', "AC-3: --status '$bad' stdout empty");
        is(one_stderr_line($err), 1, "AC-3: --status '$bad' emits EXACTLY one stderr line");
        my $names = 0;
        $names++ for grep { index($err, $_) >= 0 } qw(pending running converging reviewing done blocked parked);
        is($names, 7, "AC-3: --status '$bad' stderr names all seven allowed values");
        ok(length($bad) == 0 || index($err, $bad) >= 0,
           "AC-3: --status '$bad' stderr names the offered value");
        is(read_file($p), $orig, "AC-3: --status '$bad' leaves the file byte-identical");
    }
}

{   # ---- AC-4 (B2): IDEMPOTENT PARK CASE. Discharges R1: no sixth `stamp` op is needed.
    my $p    = stage_bytes(clean_ledger(status => 'running'));
    my $orig = read_file($p);
    my ($rc, $out, $err) = run_pl(['set-status', '--ledger', $p, '--status', 'running']);
    is($rc, 0, "AC-4: --status equal to the value on disk is SUCCESS, not an error");
    is($err, '', "AC-4: stderr empty");
    my $new = read_file($p);
    is(first_line_matching($new, qr/^status:/), 'status: running', "AC-4: status: unchanged");
    isnt(first_line_matching($new, qr/^last_updated:/),
         first_line_matching($orig, qr/^last_updated:/),
         "AC-4: last_updated: WAS re-stamped (this is the usage-pause park path)");
    my ($rm, $add) = line_diff($orig, $new);
    is(scalar(@$rm), 1, "AC-4: exactly one line removed (the old stamp)");
    is(scalar(@$add), 1, "AC-4: exactly one line added (the new stamp)");
    like($add->[0] // '', qr/^last_updated: /, "AC-4: the only changed line is last_updated:");
}

{   # ---- AC-5 (B5): non-separability by surface. No --no-stamp, no --last-updated, no `stamp` op.
    my $p = stage_bytes(clean_ledger());
    my @cases = (
        [['set-status', '--ledger', $p, '--status', 'done', '--no-stamp'],      '--no-stamp'],
        [['set-status', '--ledger', $p, '--status', 'done', '--last-updated', '2026-01-01T00:00:00Z'],
                                                                                '--last-updated'],
        [['stamp', '--ledger', $p],                                             'stamp subcommand'],
    );
    for my $c (@cases) {
        my $orig = read_file($p);
        my ($rc, $out, $err) = run_pl($c->[0]);
        is($rc, 3, "AC-5: $c->[1] is rejected with exit 3");
        is($out, '', "AC-5: $c->[1] stdout empty");
        is(one_stderr_line($err), 1, "AC-5: $c->[1] emits exactly one stderr line");
        is(read_file($p), $orig, "AC-5: $c->[1] leaves the file byte-identical");
    }
}

{   # ---- AC-6 (B4): FM lacking last_updated: -> exit 2 with the V3 detail. NO key appended.
    my $p    = stage_bytes(drop_line_matching(clean_ledger(), qr/^last_updated:/));
    my $orig = read_file($p);
    my ($rc, $out, $err) = run_pl(['set-status', '--ledger', $p, '--status', 'done']);
    is($rc, 2, "AC-6: missing last_updated: -> exit 2 (validation rejection on READ)");
    is($out, '', "AC-6: stdout empty");
    is(one_stderr_line($err), 1, "AC-6: exactly one stderr line");
    like($err, qr/^bp-ledger: set-status: \Q$p\E: /,
         "AC-6: stderr uses the `bp-ledger: <subcommand>: <path>: <detail>` framing (\xC2\xA72.2)");
    like($err, qr/last_updated/, "AC-6: the V3 detail names the missing key");
    is(read_file($p), $orig, "AC-6: file byte-identical -- no key silently appended");
    unlike(read_file($p), qr/^last_updated:/m, "AC-6: last_updated: was NOT appended");
}

{   # ---- AC-9 (B6): output stays parseable by gate-stop.sh's awk, which is STRICTER than perl's.
    my $p    = stage_bytes(clean_ledger());
    my $orig = read_file($p);
    my ($rc) = run_pl(['set-status', '--ledger', $p, '--status', 'blocked']);
    is($rc, 0, "AC-9: set-status exits 0");
    my $new = read_file($p);
    my @on  = split /\n/, $orig, -1;
    my @nn  = split /\n/, $new,  -1;
    is($nn[0], $on[0], "AC-9: opening --- delimiter line byte-identical to ORIG");
    my ($oi) = grep { $on[$_] eq '---' && $_ > 0 } 1 .. $#on;
    my ($ni) = grep { $nn[$_] eq '---' && $_ > 0 } 1 .. $#nn;
    is($ni, $oi, "AC-9: closing --- delimiter at the same line index");
    is(defined $ni ? $nn[$ni] : '(none)', '---', "AC-9: closing --- delimiter line byte-identical");
    like($new, qr/^status: blocked$/m,        "AC-9: status: sits at column 0 (no leading whitespace)");
    like($new, qr/^last_updated: \S+$/m,      "AC-9: last_updated: sits at column 0");
    unlike($new, qr/^[ \t]+(status|last_updated):/m, "AC-9: neither key gained leading whitespace");
}

# [G2]  AC-7, AC-8, AC-10..AC-13   append-attempt
# =====================================================================================
# [G2] append-attempt -- AC-7, AC-8, AC-10, AC-11, AC-12, AC-13
# =====================================================================================

# /m CORRECTED 2026-08-03 (coordinator, b13 step 4). A qr// carries its OWN flags:
# interpolating a non-/m qr into an outer /m pattern does NOT give the inner `^`
# multiline semantics, so `$new =~ /$ENTRY_RE...$/m` anchored at STRING start and
# could only have matched if the entry were the first line of the file — impossible.
# It went unnoticed because the other use is a per-line grep, where each element is a
# single line and `^` at string start is correct either way. Adding /m fixes the
# whole-document match and is a no-op for the grep (verified: still finds both lines).
my $ENTRY_RE = qr/^- \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \Q$EMDASH\E /m;

{   # ---- AC-7 (B7, B8): ONE contiguous insertion, inside the section, before the next `##`.
    my $p    = stage_bytes(clean_ledger());
    my $orig = read_file($p);
    my ($rc, $out, $err) = run_pl(['append-attempt', '--ledger', $p, '--text', 'did X']);
    is($rc, 0, "AC-7: append-attempt --text 'did X' exits 0");
    is($out, '', "AC-7: stdout empty");
    is($err, '', "AC-7: stderr empty on success");
    my $new = read_file($p);
    my $ins = contiguous_insertion($orig, $new);
    ok(defined $ins, "AC-7: the change is EXACTLY one contiguous insertion (prefix . suffix eq ORIG)");
    is(defined $ins ? scalar(split /\n/, $ins, -1) - 1 : -1, 1,
       "AC-7: the insertion is exactly one newline-terminated line");
    like(defined $ins ? $ins : '', $ENTRY_RE, "AC-7: entry format is `- <ISO> \x{2014} <text>`");
    like(defined $ins ? $ins : '', qr/did X\n\z/,  "AC-7: entry carries the text and ends with one \\n");
    # AC-7/B8: the insertion offset lies inside `## Decisions & attempt log`, before the next `##`.
    my $sec_start = index($new, "## Decisions & attempt log");
    my $off       = defined $ins ? index($new, $ins) : -1;
    my $next_hd   = $sec_start >= 0 ? index($new, "\n## ", $sec_start + 1) : -1;
    ok($sec_start >= 0 && $off > $sec_start && ($next_hd < 0 || $off < $next_hd),
       "AC-7/B8: insertion point is inside '## Decisions & attempt log', before the next `##` heading");
    # Nothing else moved: every other section is byte-identical.
    for my $h (qr/^## Next action/, qr/^##\s+Pipeline\b/, qr/^##\s+Outputs\b/, qr/^##\s+Escalation\b/) {
        is(section_of($new, $h), section_of($orig, $h), "AC-7: section $h byte-identical after append-attempt");
    }
}

{   # ---- AC-8 (B9): b09 -- 4 fence-embedded lookalikes stay byte-identical; entry not in a fence.
  SKIP: {
        skip("b09 fixture not locatable in the corpus", 4) unless defined $FX_B09;
        my $p    = stage_corpus($FX_B09);
        my $orig = read_file($p);
        my @orig_fenced = fenced_lines($orig);
        my ($rc, $out, $err) = run_pl(['append-attempt', '--ledger', $p, '--text', 'b09 fence probe']);
        is($rc, 0, "AC-8: append-attempt on b09 (fence-embedded lookalikes) exits 0");
        my $new = read_file($p);
        my $ins = contiguous_insertion($orig, $new);
        ok(defined $ins, "AC-8: one contiguous insertion on b09");
        is_deeply([fenced_lines($new)], [@orig_fenced],
                  "AC-8: all fence-embedded ##/status:/- [x] lookalike lines byte-identical afterwards");
        my $off = defined $ins ? index($new, $ins) : -1;
        ok($off >= 0 && !offset_in_fence($new, $off),
           "AC-8: the inserted entry is NOT inside any fenced code block");
    }
}

{   # ---- AC-10 (B10): multi-line --text collapses to exactly ONE inserted line.
    my $p    = stage_bytes(clean_ledger());
    my $orig = read_file($p);
    my ($rc) = run_pl(['append-attempt', '--ledger', $p, '--text', "line one\nline two\r\nline three"]);
    is($rc, 0, "AC-10: multi-line --text exits 0");
    my $new = read_file($p);
    my $ins = contiguous_insertion($orig, $new);
    ok(defined $ins, "AC-10: still one contiguous insertion");
    is(defined $ins ? scalar(split /\n/, $ins, -1) - 1 : -1, 1,
       "AC-10: exactly one inserted line (\\r\\n+ collapsed to a single space)");
    like(defined $ins ? $ins : '', qr/line one line two line three\n\z/,
         "AC-10: newlines collapsed to single spaces, text otherwise intact");
}

{   # ---- AC-11 (B11): `- [x]` in --text cannot forge the orchestrator's progress signal.
    my $p    = stage_bytes(clean_ledger());
    my $orig = read_file($p);
    my $before = ticked_count($orig);
    my ($rc) = run_pl(['append-attempt', '--ledger', $p, '--text', '- [x] step 9 done']);
    is($rc, 0, "AC-11: append-attempt --text '- [x] step 9 done' exits 0 (not an argument fault)");
    my $new = read_file($p);
    is(ticked_count($new), $before,
       "AC-11: the body's /^\\s*-\\s*\\[[xX]\\]/ count is UNCHANGED -- no forged ticked checkbox");
    my $ins = contiguous_insertion($orig, $new);
    like(defined $ins ? $ins : '', qr/\Q$EMDASH\E - \[x\] step 9 done\n\z/,
         "AC-11: the rendered line is `- <ISO> \x{2014} - [x] step 9 done`");
    ok(defined $ins && $ins !~ /^[ \t]*-[ \t]*\[[xX]\]/,
       "AC-11: ...which does not itself match the ticked-checkbox pattern");
}

{   # ---- AC-12 (B13): a lone `_(none)_` placeholder is REPLACED, not appended after.
    my $p    = stage_bytes(placeholder_ledger());
    my $orig = read_file($p);
    my ($rc) = run_pl(['append-attempt', '--ledger', $p, '--text', 'first real entry']);
    is($rc, 0, "AC-12: append-attempt onto a `_(none)_` placeholder body exits 0");
    my $new = read_file($p);
    my $sec = section_of($new, qr/^##\s+Decisions & attempt log\b/);
    ok(defined $sec && $sec !~ /^_\(none\)_$/m,
       "AC-12: the italic placeholder line is GONE from the attempt-log section");
    like(defined $sec ? $sec : '', qr/^- \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \Q$EMDASH\E first real entry$/m,
         "AC-12: the entry took its place");
    my ($rm, $add) = line_diff($orig, $new);
    is_deeply($rm, ['_(none)_'],
              "AC-12: exactly the placeholder line was removed (replaced, not appended after)");
    is(scalar(@$add), 1, "AC-12: exactly one line added");
}

{   # ---- AC-13 (B14): section ends inside an UNTERMINATED fence -> exit 5, byte-identical.
    my $p    = stage_bytes(unterminated_fence_ledger());
    my $orig = read_file($p);
    my ($rc, $out, $err) = run_pl(['append-attempt', '--ledger', $p, '--text', 'must not land in a fence']);
    is($rc, 5, "AC-13: unterminated fence in the target section -> exit 5 (region not found)");
    is($out, '', "AC-13: stdout empty");
    is(one_stderr_line($err), 1, "AC-13: exactly one stderr line");
    like($err, qr/^bp-ledger: append-attempt: \Q$p\E: /, "AC-13: `bp-ledger:` framing");
    is(read_file($p), $orig, "AC-13: file byte-identical -- never inserted into a fence");
    is(scalar(glob_tmp(dirname_of($p), '*.tmp.*')), 0, "AC-13: no temp file left behind");
}

# =====================================================================================
# [G3] tick-step -- AC-14..AC-21
# =====================================================================================

{   # ---- AC-14 (B15): exactly ONE bracket byte flips; ticked count +1; one changed line.
    my $p    = stage_bytes(clean_ledger());
    my $orig = read_file($p);
    my ($rc, $out, $err) = run_pl(['tick-step', '--ledger', $p, '--step', '3']);
    is($rc, 0, "AC-14: tick-step --step 3 exits 0");
    is($out, '', "AC-14: stdout empty");
    is($err, '', "AC-14: stderr empty on success");
    my $new = read_file($p);
    is(length($new), length($orig), "AC-14: file length unchanged (single-byte bracket replacement)");
    my @off = differing_offsets($orig, $new);
    is(scalar(@off), 1, "AC-14: EXACTLY one byte differs from ORIG");
    is((@off == 1 ? substr($orig, $off[0], 1) : '?'), ' ', "AC-14: the byte that changed was a space");
    is((@off == 1 ? substr($new,  $off[0], 1) : '?'), 'x', "AC-14: ...and it became 'x'");
    is(ticked_count($new), ticked_count($orig) + 1, "AC-14: ticked-checkbox count rises by exactly 1");
    my ($rm, $add) = line_diff($orig, $new);
    is(scalar(@$rm), 1, "AC-14: exactly one line removed in the diff");
    is($add->[0] // '', '- [x] 3. third step', "AC-14: ...and replaced by the same line with [x]");
}

{   # ---- AC-15 (B16): SHARED-PREFIX DIGITS. `--step 1` must not match `- [ ] 11.`.
    my $p1 = stage_bytes(clean_ledger());
    my $o1 = read_file($p1);
    my ($rc1) = run_pl(['tick-step', '--ledger', $p1, '--step', '1']);
    is($rc1, 0, "AC-15: --step 1 exits 0");
    my $n1 = read_file($p1);
    like($n1, qr/^- \[x\] 1\. first step$/m,      "AC-15: `- [ ] 1.` flipped");
    like($n1, qr/^- \[ \] 11\. eleventh step$/m,  "AC-15: `- [ ] 11.` left UNTOUCHED by --step 1");
    is(scalar(differing_offsets($o1, $n1)), 1,    "AC-15: exactly one byte changed for --step 1");

    my $p2 = stage_bytes(clean_ledger());
    my $o2 = read_file($p2);
    my ($rc2) = run_pl(['tick-step', '--ledger', $p2, '--step', '11']);
    is($rc2, 0, "AC-15: --step 11 exits 0");
    my $n2 = read_file($p2);
    like($n2, qr/^- \[x\] 11\. eleventh step$/m, "AC-15: `- [ ] 11.` flipped");
    like($n2, qr/^- \[ \] 1\. first step$/m,     "AC-15: `- [ ] 1.` left UNTOUCHED by --step 11");
    is(scalar(differing_offsets($o2, $n2)), 1,   "AC-15: exactly one byte changed for --step 11");
}

{   # ---- AC-16 (B17): b13's OWN ledger has a wrapped step; continuation lines must be byte-identical.
  SKIP: {
        skip("b13 fixture not locatable in the corpus", 4) unless defined $FX_B13;
        my $p    = stage_corpus($FX_B13);
        my $orig = read_file($p);
        # Locate a wrapped, UNticked step by pattern -- never by line number.
        my ($step) = $orig =~ /^[ \t]*-[ \t]*\[[ ]\][ \t]*(\d+)\..*\n[ \t]+\S/m;
        skip("b13's ledger currently has no wrapped UNticked pipeline step", 4) unless defined $step;
        my ($rc) = run_pl(['tick-step', '--ledger', $p, '--step', $step]);
        is($rc, 0, "AC-16: tick-step --step $step on b13's own (wrapped) ledger exits 0");
        my $new = read_file($p);
        is(length($new), length($orig), "AC-16: length unchanged -- no reflow of the wrapped entry");
        my @off = differing_offsets($orig, $new);
        is(scalar(@off), 1, "AC-16: exactly one byte differs (the bracket)");
        is_deeply([indented_lines($new)], [indented_lines($orig)],
                  "AC-16: EVERY indented continuation line is byte-identical");
    }
}

{   # ---- AC-17 (B18): already `[x]` -> exit 0, byte-identical, NO temp file, mtime unchanged.
    my $p = stage_bytes(clean_ledger(pipeline => "- [x] 3. third step"));
    my $orig  = read_file($p);
    my @st0   = stat($p);
    my ($rc, $out, $err) = run_pl(['tick-step', '--ledger', $p, '--step', '3']);
    is($rc, 0, "AC-17: tick-step on an already-[x] step is idempotent SUCCESS");
    is($err, '', "AC-17: stderr empty");
    is(read_file($p), $orig, "AC-17: file byte-identical");
    my @st1 = stat($p);
    is($st1[9], $st0[9], "AC-17: mtime UNCHANGED (step 7: no temp file, no rename)");
    is(scalar(glob_tmp(dirname_of($p), '*.tmp.*')), 0, "AC-17: no temp file was created");
}

{   # ---- AC-18 (B19): already `[X]` -> exit 0, NOT normalised to lowercase.
    my $p = stage_bytes(clean_ledger(pipeline => "- [X] 3. third step"));
    my $orig = read_file($p);
    my ($rc) = run_pl(['tick-step', '--ledger', $p, '--step', '3']);
    is($rc, 0, "AC-18: tick-step on an already-[X] step exits 0");
    my $new = read_file($p);
    is($new, $orig, "AC-18: file byte-identical");
    like($new, qr/^- \[X\] 3\. third step$/m, "AC-18: [X] is NOT normalised to [x] (byte-identity wins)");
}

{   # ---- AC-19 (B20): absent step -> exit 5, byte-identical.
    my $p    = stage_bytes(clean_ledger());
    my $orig = read_file($p);
    my ($rc, $out, $err) = run_pl(['tick-step', '--ledger', $p, '--step', '9']);
    is($rc, 5, "AC-19: --step 9 with no such step -> exit 5 (region not found, NOT a validation failure)");
    is($out, '', "AC-19: stdout empty");
    is(one_stderr_line($err), 1, "AC-19: exactly one stderr line");
    like($err, qr/^bp-ledger: tick-step: \Q$p\E: /, "AC-19: `bp-ledger:` framing");
    is(read_file($p), $orig, "AC-19: file byte-identical");
}

{   # ---- AC-20 (B21): a FENCED `- [ ] 2.` inside `## Pipeline` is skipped; the real one flips.
    my $p    = stage_bytes(fenced_pipeline_ledger());
    my $orig = read_file($p);
    my ($rc) = run_pl(['tick-step', '--ledger', $p, '--step', '2']);
    is($rc, 0, "AC-20: tick-step --step 2 with a fenced lookalike present exits 0");
    my $new = read_file($p);
    my @off = differing_offsets($orig, $new);
    is(scalar(@off), 1, "AC-20: exactly one byte changed");
    like($new, qr/^- \[ \] 2\. fenced lookalike that must never flip$/m,
         "AC-20: the FENCED `- [ ] 2.` is byte-identical");
    like($new, qr/^- \[x\] 2\. the REAL second step$/m, "AC-20: the REAL `- [ ] 2.` flipped");
    ok(@off == 1 && !offset_in_fence($new, $off[0]), "AC-20: the changed byte is outside every fence");
}

{   # ---- AC-21 (B22): bad / missing --step -> exit 3.
    for my $case (['0'], ['x'], ['01'], []) {
        my $p    = stage_bytes(clean_ledger());
        my $orig = read_file($p);
        my @args = ('tick-step', '--ledger', $p, (@$case ? ('--step', $case->[0]) : ()));
        my $lbl  = @$case ? "--step '$case->[0]'" : "missing --step";
        my ($rc, $out, $err) = run_pl(\@args);
        is($rc, 3, "AC-21: $lbl -> exit 3");
        is($out, '', "AC-21: $lbl stdout empty");
        is(one_stderr_line($err), 1, "AC-21: $lbl exactly one stderr line");
        is(read_file($p), $orig, "AC-21: $lbl file byte-identical");
    }
}

# [G4]  AC-22..AC-27          set-next-action / add-output
# =====================================================================================
# [G4] set-next-action / add-output -- AC-22..AC-27
# =====================================================================================

# The `## Next action` heading pattern is the BARE one (one literal space, no \s+, no \b) that
# ledger-guard.sh and bp-status.sh (find via /^## Next action/) both use -- §2.3, §2.4 V5.
my $NA_RE = qr/^## Next action/;

# Split a buffer into (heading, body) pairs for EVERY `^## Next action` heading, body running to the
# next `^##` line (fence-aware) or EOF.
sub next_action_sections {
    my ($s) = @_;
    my @l = split /\n/, $s, -1;
    my (@sec, $cur, $in_fence);
    for my $l (@l) {
        if (defined $cur) {
            $in_fence = !$in_fence if $l =~ /^[ \t]*(?:`{3,}|~{3,})/;
            if (!$in_fence && $l =~ /^##\s/ && $l !~ $NA_RE) { push @sec, $cur; undef $cur }
            elsif (!$in_fence && $l =~ $NA_RE) { push @sec, $cur; $cur = { head => $l, body => [] } }
            else { push @{ $cur->{body} }, $l; next }
        }
        if (!defined $cur && $l =~ $NA_RE) { $in_fence = 0; $cur = { head => $l, body => [] } }
    }
    push @sec, $cur if defined $cur;
    return map { { head => $_->{head}, body => join("\n", @{ $_->{body} }) } } @sec;
}

{   # ---- AC-22 (B23): s05 has FIVE `## Next action`. ONLY the first section's body may change.
  SKIP: {
        skip("s05 fixture not locatable in the corpus", 6) unless defined $FX_S05;
        my $p    = stage_corpus($FX_S05);
        my $orig = read_file($p);
        my @o    = next_action_sections($orig);
        ok(scalar(@o) >= 2, "AC-22: FIXTURE-SANITY s05 really has more than one `## Next action` section");
        my ($rc, $out, $err) = run_pl(['set-next-action', '--ledger', $p, '--body', 'Do Y']);
        is($rc, 0, "AC-22: set-next-action on s05 exits 0");
        my $new = read_file($p);
        my @n   = next_action_sections($new);
        is(scalar(@n), scalar(@o), "AC-22: the number of `## Next action` headings is unchanged");
        is($n[0]{head}, $o[0]{head}, "AC-22: the FIRST heading line is byte-identical");
        like($n[0]{body} // '', qr/Do Y/, "AC-22: the first section's body was replaced");
        my $others_identical = 1;
        for my $i (1 .. $#o) {
            $others_identical = 0
                if !defined $n[$i] || $n[$i]{head} ne $o[$i]{head} || $n[$i]{body} ne $o[$i]{body};
        }
        ok($others_identical,
           "AC-22: every LATER `## Next action` heading AND body is byte-identical (no s///g)");
    }
}

{   # ---- AC-23 (B24): framing exact -- one blank line either side; exactly one trailing \n at EOF.
    my $p = stage_bytes(clean_ledger());
    my ($rc) = run_pl(['set-next-action', '--ledger', $p, '--body', 'Do Y']);
    is($rc, 0, "AC-23: set-next-action exits 0 (section followed by another heading)");
    my $new = read_file($p);
    like($new, qr/^## Next action\n\nDo Y\n\n## /m,
         "AC-23: renders `## Next action\\n\\nDo Y\\n\\n## <next>` -- exactly one blank line either side");

    # Same op where `## Next action` is the LAST section in the file.
    my $tail = "---\npackage: p\nblueprint: b\nstatus: running\nwrite_set:\n  - x\n"
             . "last_updated: 2026-07-01T00:00:00Z\n---\n\n"
             . "## Pipeline\n\n- [ ] 1. a\n\n## Decisions & attempt log\n\n_(none)_\n\n"
             . "## Outputs\n\n_(none yet)_\n\n## Escalation (when status: blocked)\n\n_(none)_\n\n"
             . "## Next action\n\nold tail body\n";
    my $p2 = stage_bytes($tail);
    my ($rc2) = run_pl(['set-next-action', '--ledger', $p2, '--body', 'Do Z']);
    is($rc2, 0, "AC-23: set-next-action exits 0 when the section is last in the file");
    my $n2 = read_file($p2);
    like($n2, qr/## Next action\n\nDo Z\n\z/,
         "AC-23: at EOF renders `## Next action\\n\\nDo Z\\n` with exactly one trailing \\n");
    unlike($n2, qr/\n\n\z/, "AC-23: ...and NOT two trailing newlines (the invariant all 115 files satisfy)");
}

{   # ---- AC-24 (B25): blank or `#`-leading first body line -> exit 3, message cites the disagreement.
    for my $body ("\nreal text after a blank line", "# a heading-looking first line") {
        my $p    = stage_bytes(clean_ledger());
        my $orig = read_file($p);
        my $lbl  = $body =~ /^\n/ ? "blank first line" : "'#'-leading first line";
        my ($rc, $out, $err) = run_pl(['set-next-action', '--ledger', $p, '--body', $body]);
        is($rc, 3, "AC-24: $lbl -> exit 3 (argument check, not a validation rule)");
        is($out, '', "AC-24: $lbl stdout empty");
        is(one_stderr_line($err), 1, "AC-24: $lbl exactly one stderr line");
        ok(index($err, 'bp-status.sh') >= 0 && index($err, 'gate-stop.sh') >= 0,
           "AC-24: $lbl message cites the bp-status.sh / gate-stop.sh reader disagreement");
        is(read_file($p), $orig, "AC-24: $lbl file byte-identical");
    }
}

{   # ---- AC-25 (B26): a `- [x]` line in --body would forge snapshot_progressed -> exit 3.
    my $p    = stage_bytes(clean_ledger());
    my $orig = read_file($p);
    my ($rc, $out, $err) = run_pl(['set-next-action', '--ledger', $p,
                                   '--body', "Do Y\n- [x] forged progress"]);
    is($rc, 3, "AC-25: --body containing a `- [x]` line -> exit 3");
    is($out, '', "AC-25: stdout empty");
    is(one_stderr_line($err), 1, "AC-25: exactly one stderr line");
    is(read_file($p), $orig, "AC-25: file byte-identical");

    # AC-27 (B27-adjacent): empty / whitespace-only --body -> exit 3.
    for my $b ('', "   \n\t ") {
        my $q    = stage_bytes(clean_ledger());
        my $qo   = read_file($q);
        my ($r2, $o2, $e2) = run_pl(['set-next-action', '--ledger', $q, '--body', $b]);
        is($r2, 3, "AC-25/B27: empty-or-whitespace --body -> exit 3");
        is(read_file($q), $qo, "AC-25/B27: file byte-identical");
    }
}

{   # ---- AC-26 (B28): bp-status.sh's awk one-liner still reads what set-next-action wrote.
    my $p = stage_bytes(clean_ledger());
    my ($rc) = run_pl(['set-next-action', '--ledger', $p, '--body', "Dispatch the implementer next"]);
    is($rc, 0, "AC-26: set-next-action exits 0");
  SKIP: {
        skip("awk not available", 1) unless have_cmd('awk');
        local %ENV = (%CLEAN_ENV, LGT_F => fwd($p));
        open(my $f, '-|', 'bash', '-c',
             q{awk '/^## Next action/{getline; while ($0 ~ /^[[:space:]]*$/) getline; print; exit}' "$LGT_F"})
            or die "bash: $!";
        my $got = do { local $/; <$f> }; close $f;
        $got = '' unless defined $got;
        $got =~ s/\n\z//;
        is($got, 'Dispatch the implementer next',
           "AC-26: bp-status.sh's awk one-liner yields the body's first line verbatim");
    }
}

{   # ---- AC-27 (B29, B30, B31): add-output.
    my $p    = stage_bytes(clean_ledger());
    my $orig = read_file($p);
    my ($rc, $out, $err) = run_pl(['add-output', '--ledger', $p, '--text', 'ran t/65: exit 0']);
    is($rc, 0, "AC-27: add-output exits 0");
    is($out, '', "AC-27: stdout empty");
    is($err, '', "AC-27: stderr empty on success");
    my $new = read_file($p);
    my $ins = contiguous_insertion($orig, $new);
    is(defined $ins ? $ins : '(not a single contiguous insertion)', "- ran t/65: exit 0\n",
       "AC-27: one contiguous `- <text>\\n` insertion, NO timestamp (Outputs is an inventory)");
    my $sec_start = index($new, '## Outputs');
    my $off       = defined $ins ? index($new, $ins) : -1;
    my $next_hd   = $sec_start >= 0 ? index($new, "\n## ", $sec_start + 1) : -1;
    ok($sec_start >= 0 && $off > $sec_start && ($next_hd < 0 || $off < $next_hd),
       "AC-27: the insertion is inside `## Outputs`, before the next `##`");

    # B30: `_(none yet)_` placeholder is replaced.
    my $q  = stage_bytes(placeholder_ledger());
    my $qo = read_file($q);
    my ($rq) = run_pl(['add-output', '--ledger', $q, '--text', 'first artifact']);
    is($rq, 0, "AC-27/B30: add-output onto a `_(none yet)_` placeholder exits 0");
    my ($rm) = line_diff($qo, read_file($q));
    is_deeply($rm, ['_(none yet)_'], "AC-27/B30: the `_(none yet)_` line was REPLACED, not appended after");

    # B31: `- [x]` text -> exit 3.
    my $r    = stage_bytes(clean_ledger());
    my $ro   = read_file($r);
    my ($rr, $or2, $er2) = run_pl(['add-output', '--ledger', $r, '--text', '- [x] forged']);
    is($rr, 3, "AC-27/B31: add-output --text '- [x] forged' -> exit 3");
    is(one_stderr_line($er2), 1, "AC-27/B31: exactly one stderr line");
    is(read_file($r), $ro, "AC-27/B31: file byte-identical");
}

# =====================================================================================
# [G5] Round-trip, no-touch invariants, framing parity -- AC-28, AC-29, AC-30
# =====================================================================================

{   # ---- AC-28: FIVE-OP ROUND-TRIP VERIFIED BY DIFF, NOT INSPECTION.
    my $p    = stage_bytes(clean_ledger(status => 'pending'));
    my $orig = read_file($p);
    my @rcs;
    push @rcs, (run_pl(['set-status',      '--ledger', $p, '--status', 'running']))[0];
    push @rcs, (run_pl(['tick-step',       '--ledger', $p, '--step', '3']))[0];
    push @rcs, (run_pl(['append-attempt',  '--ledger', $p, '--text', 'round-trip attempt']))[0];
    push @rcs, (run_pl(['set-next-action', '--ledger', $p, '--body', 'Round-trip next action']))[0];
    push @rcs, (run_pl(['add-output',      '--ledger', $p, '--text', 'round-trip output']))[0];
    is_deeply(\@rcs, [0, 0, 0, 0, 0], "AC-28: all five ops in sequence exit 0");
    my $new = read_file($p);
    my ($rm, $add) = line_diff($orig, $new);

    # Every REMOVED line must be one of: the old status line, the old stamp, the old `- [ ] 3.`
    # line, or a line of the old `## Next action` body. NOTHING else may disappear.
    my $old_na = (next_action_sections($orig))[0];
    my %old_na_lines = map { $_ => 1 } split /\n/, ($old_na ? $old_na->{body} : ''), -1;
    my @unexpected_rm = grep {
        !( /^status: / || /^last_updated: / || $_ eq '- [ ] 3. third step' || $old_na_lines{$_} )
    } @$rm;
    is_deeply(\@unexpected_rm, [], "AC-28: the diff removes NOTHING beyond the two FM lines, the "
                                . "ticked step line and the old `## Next action` body");

    # Every ADDED line must be one of: the new status line, the new stamp, the flipped step line, the
    # attempt entry, the Outputs entry, or a line of the new `## Next action` body.
    my @unexpected_add = grep {
        !( /^status: running$/ || /^last_updated: \d{4}-/ || $_ eq '- [x] 3. third step'
           || /$ENTRY_RE/ || $_ eq '- round-trip output' || $_ eq 'Round-trip next action' || $_ eq '' )
    } @$add;
    is_deeply(\@unexpected_add, [], "AC-28: the diff adds NOTHING beyond those six regions");
    like($new, qr/^status: running$/m,                       "AC-28: status: set");
    like($new, qr/^- \[x\] 3\. third step$/m,                "AC-28: step 3 ticked");
    like($new, qr/$ENTRY_RE\Qround-trip attempt\E$/m,        "AC-28: attempt entry present");
    like($new, qr/^Round-trip next action$/m,                "AC-28: next action body present");
    like($new, qr/^- round-trip output$/m,                   "AC-28: output entry present");
    is(ticked_count($new), ticked_count($orig) + 1,
       "AC-28: exactly ONE new ticked checkbox across the whole round-trip");
    is(substr($new, -1), "\n", "AC-28: still ends with exactly one newline");
    ok($new !~ /\n\n\z/,       "AC-28: ...and not two");

    # ---- AC-29 (B32): `## Dispatch log (auto)` is byte-identical after the round-trip.
    is(section_of($new, qr/^##\s+Dispatch log \(auto\)/),
       section_of($orig, qr/^##\s+Dispatch log \(auto\)/),
       "AC-29: `## Dispatch log (auto)` byte-identical after the five-op round-trip");
    # ...and so is every prose section no op owns.
    is(section_of($new, qr/^##\s+Scope\b/), section_of($orig, qr/^##\s+Scope\b/),
       "AC-29: an unknown one-off heading (`## Scope`) is byte-identical too");
    is(section_of($new, qr/^##\s+Escalation\b/), section_of($orig, qr/^##\s+Escalation\b/),
       "AC-29: `## Escalation` byte-identical (no set-escalation op exists -- R1)");
    like($new, qr/^mandated_means: none$/m, "AC-29: `mandated_means:` byte-identical (never an op)");
}

{   # ---- AC-30 (B44): the V-rule DETAIL FRAGMENT is byte-identical across the two framings (§2.2).
    # This is the strongest anti-drift guarantee available inside the write set.
    my $bad_v5 = drop_line_matching(clean_ledger(), qr/^## Next action/);
    my $bad_v1 = ctrl_ledger("\x1B");
    for my $case ([$bad_v5, 'V5 dropped `## Next action`', qr/\Q## Next action\E/],
                  [$bad_v1, 'V1 control byte 0x1B',       qr/0x1B/]) {
        my ($bytes, $lbl, $token) = @$case;
        my $p = stage_bytes($bytes);
        my ($rc_a, $out_a, $err_a) = run_pl(['validate', '--ledger', $p]);
        my ($rc_b, $out_b, $err_b) = run_pl(['validate', '--payload'],
                                            stdin => pl_write($p, $bytes),
                                            env   => { LG_ABS => $p, LG_TOOL => 'Write' });
        is($rc_a, 2, "AC-30: $lbl -- validate --ledger exits 2");
        is($rc_b, 2, "AC-30: $lbl -- validate --payload exits 2");
        is(one_stderr_line($err_a), 1, "AC-30: $lbl -- --ledger emits exactly one stderr line");
        is(one_stderr_line($err_b), 1, "AC-30: $lbl -- --payload emits exactly one stderr line");
        like($err_a, $token, "AC-30: $lbl -- the --ledger line carries the rule-specific token");
        like($err_b, $token, "AC-30: $lbl -- the --payload line carries the rule-specific token");
        # Strip each framing prefix per §2.2 and compare the remainders byte-for-byte.
        (my $frag_a = $err_a) =~ s/^bp-ledger: validate: \Q$p\E: //;
        (my $frag_b = $err_b) =~ s/^LEDGER-GUARD: BLOCKED \Q$EMDASH\E the content this write would leave in \Q$p\E //;
        isnt($frag_a, $err_a, "AC-30: $lbl -- the --ledger line really carries the `bp-ledger:` framing");
        isnt($frag_b, $err_b, "AC-30: $lbl -- the --payload line really carries the frozen b12 framing");
        is($frag_a, $frag_b,
           "AC-30: $lbl -- the detail fragment is BYTE-IDENTICAL across both framings");
    }
}

# [G6]  AC-31..AC-37, AC-42   validate / delegation / parity
# [G6]  AC-31..AC-37, AC-42   validate / delegation / parity
# [G7]  AC-38..AC-41, AC-43   corpus + vacuity traps
# [G8]  AC-44..AC-49          durability & concurrency
# [G9]  AC-50..AC-53          SKILL.md prose
# [G10] AC-58                 SYN-23 line-number prohibition
# [G11] AC-59..AC-63          reject on write

# =====================================================================================
# AC-41 (post-image) -- must be the LAST thing to run
# =====================================================================================

sub assert_corpus_untouched {
    my $bad = 0;
    for my $f (@ALL) {
        my $now = md5_hex(read_file($f) // '');
        $bad++ if $now ne ($CORPUS_DIGEST_BEFORE{$f} // '');
    }
    is($bad, 0, "AC-41: no live corpus file was written -- digest unchanged for every enumerated file");
}

assert_corpus_untouched();

done_testing();
