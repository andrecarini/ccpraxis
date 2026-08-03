#!/usr/bin/env perl
# b19-ledger-timestamp-integrity oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b19-ledger-timestamp-integrity-spec.md
# §2 (the checks), §3 (one implementation, both sites) and §4 (acceptance criteria C1..C9).
#
# WRITTEN BLIND TO ANY IMPLEMENTATION of the VALUE check: neither bp-ledger.pl nor
# ledger-guard.sh validates the last_updated: VALUE today (only its presence as a key,
# per b12/b13). Every C1/C3-shaped assertion below is therefore expected to fail on
# MISSING BEHAVIOUR (today: accepted-when-it-should-be-rejected), never on a perl
# exception, a missing module, or a wrong path. C2/C4/C7/C8/C9-shaped assertions are
# expected to already pass -- they assert "nothing legitimate is blocked" / "nothing
# real breaks", which is trivially true while no check exists at all.
#
# SCOPE DISCIPLINE (spec §1): this is an AUDIT-TRAIL defect, not a run-control one.
# bp-status.sh uses mtime, gate-stop.sh and the watchdog never parse last_updated:.
# Nothing here asserts run-control behaviour, staleness detection, or watchdog firing.
#
# THE VACUITY GATE (spec §4, mandatory). C1/C2 are an opposite pair over the SAME
# validator's monotonicity behaviour: "reject everything" passes C1 and fails C2;
# "accept everything" passes C2 and fails C1. C3/C4 are the same pair over skew. Every
# block below that tests one half of a pair sits immediately next to (or inside the
# same loop as) the block testing the other half, against the identical mechanism
# (same hook invocation shape, same API invocation shape), so a constant-returning
# stub cannot pass both halves of either pair.
#
# HARNESS RULES (carried over from t/64 and t/65 -- not re-derived):
#   * done_testing(), never a hand-counted plan.
#   * %CLEAN_ENV strips every ambient BP_*.
#   * The hook is invoked as `bash "$HOOK"`, never executed directly.
#   * NO LIVE LEDGER IS EVER WRITTEN. Real corpus files (C7) are opened READ-ONLY.
#   * Corpus enumeration is perl `glob` on explicit paths, never `grep -r`/ripgrep
#     (.ccpraxis-local-data/ is gitignored; a directory-scoped rg is a false clean).
#   * TWO globs: active blueprints AND `_archive/*/packages/*.md`.
#   * NO CORPUS SIZE IS PINNED (C7 asserts a LOWER BOUND only).
#   * Output captured via temp files, never by reopening STDOUT onto an in-memory
#     scalar (Git-for-Windows perl landmine; project CLAUDE.md).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
use Digest::MD5 qw(md5_hex);
use Time::Local qw(timegm);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

(my $HOOKS   = "$Bin/../../hooks")   =~ s{\\}{/}g;
(my $SCRIPTS = "$Bin/../../scripts") =~ s{\\}{/}g;
my $HOOK      = "$HOOKS/ledger-guard.sh";
my $SCRIPT    = "$SCRIPTS/bp-ledger.pl";
my $ORCH      = "$SCRIPTS/bp-orchestrator.pl";
my $T64       = "$Bin/64-ledger-guard.t";
my $T65       = "$Bin/65-ledger-api.t";

(my $PROJ = "$Bin/../../../..") =~ s{\\}{/}g;
my $BP_ROOT = "$PROJ/.ccpraxis-local-data";

my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
my $pn   = 0;
my $bpn  = 0;

my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

my $have_jq = do { my $o = `bash -c 'command -v jq' 2>/dev/null`; $o =~ /\S/ ? 1 : 0 };

diag("subject under test: $SCRIPT " . (-e $SCRIPT ? "(present)" : "(ABSENT)"));
diag("hook under test: $HOOK "      . (-e $HOOK   ? "(present)" : "(ABSENT)"));

# =====================================================================================
# Scaffolding (mirrors t/64 / t/65)
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

sub realpath_m {
    my ($p) = @_;
    local %ENV = (%CLEAN_ENV, P => $p);
    open(my $f, '-|', 'bash', '-c', 'realpath -m "$P"') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f; $o =~ s/\s+\z//; return $o;
}

sub mk_bp {
    my $n = ++$bpn;
    my $d = "$ROOT/bp$n";
    mkdir $d or die "mkdir $d: $!";
    mkdir "$d/$_" or die "mkdir $d/$_: $!" for qw(packages reports specs runs);
    my $p = "$ROOT/proj$n";
    mkdir $p or die "mkdir $p: $!";
    return (realpath_m(fwd($d)), realpath_m(fwd($p)));
}

sub env_for {
    my ($bp, $proj) = @_;
    return (BP_DIR => $bp, BP_PROJECT_ROOT => $proj,
            BP_LEDGER => "$bp/packages/fixture-pkg.md", BP_PACKAGE => 'fixture-pkg');
}

sub ledger_path { my ($bp) = @_; return "$bp/packages/fixture-pkg.md" }

# payload -> temp file -> `timeout 60 bash "$HOOK" < payload`, combined output (b12
# never writes to stdout, so a combined capture is equivalent to stderr-only here).
sub run_hook {
    my ($payload, %env) = @_;
    my $pf = write_file("$ROOT/hpayload." . (++$pn) . ".json", $payload);
    local %ENV = (%CLEAN_ENV, %env, HOOKPATH => fwd($HOOK), PFILE => fwd($pf));
    open(my $f, '-|', 'bash', '-c', 'timeout 60 bash "$HOOKPATH" < "$PFILE" 2>&1') or die "bash: $!";
    binmode $f;
    my $o = do { local $/; <$f> }; close $f;
    return ($? >> 8, defined $o ? $o : '');
}

# `bp-ledger.pl` args -> (rc, stdout, stderr), stdout/stderr captured separately (b13
# §2.1: "stdout is ALWAYS empty" is an interface, and a combined capture cannot assert it).
sub run_pl {
    my ($args, %opt) = @_;
    my $n    = ++$pn;
    my $inf  = write_file("$ROOT/in.$n",  defined $opt{stdin} ? $opt{stdin} : '');
    my $outf = write_file("$ROOT/out.$n", '');
    my $errf = write_file("$ROOT/err.$n", '');
    my %extra = %{ $opt{env} || {} };
    local %ENV = (%CLEAN_ENV, %extra, LGT_SCRIPT => fwd($SCRIPT), LGT_IN => fwd($inf),
                  LGT_OUT => fwd($outf), LGT_ERR => fwd($errf));
    my $rc = system('bash', '-c',
        'timeout 60 perl "$LGT_SCRIPT" "$@" < "$LGT_IN" > "$LGT_OUT" 2> "$LGT_ERR"',
        'bp-ledger', @$args);
    return ($rc >> 8, read_file($outf) // '', read_file($errf) // '');
}

sub jtrue  { return JSON::PP::true }
sub jfalse { return JSON::PP::false }

sub iso_of {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub epoch_of_iso {
    my ($s) = @_;
    return undef unless $s =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/;
    return eval { timegm($6, $5, $4, $3, $2 - 1, $1) };
}

# A structurally valid ledger (V1-V5-clean): required keys, a protocol status, and
# all five required section headings, parameterized on the last_updated: VALUE only.
sub ledger_text {
    my (%o) = @_;
    my $status = defined $o{status} ? $o{status} : 'running';
    my $lu     = defined $o{last_updated} ? $o{last_updated} : iso_of(time - 3600);
    return join("\n",
        '---',
        'package: fixture-pkg',
        'blueprint: sandbox-butler-overhaul',
        "status: $status",
        'write_set: plugins/butler/scripts/bp-ledger.pl:plugins/butler/hooks/ledger-guard.sh',
        "last_updated: $lu",
        '---',
        '',
        '# Package fixture-pkg -- synthesized ledger fixture for 71-ledger-timestamps.t',
        '',
        '## Next action',
        '',
        'Dispatch the implementer.',
        '',
        '## Pipeline',
        '',
        '- [x] 1. Scout',
        '- [ ] 2. Implement',
        '',
        '## Decisions & attempt log',
        '',
        '_(none)_',
        '',
        '## Outputs',
        '',
        '_(none yet)_',
        '',
        '## Escalation (when status: blocked)',
        '',
        '_(none)_',
        '',
    );
}

# --- payload builders (shared shape for hook + API `validate --payload`) -----------
sub pl_write {
    my ($path, $content) = @_;
    return $J->encode({ tool_name => 'Write', cwd => '/project',
                        tool_input => { file_path => $path, content => $content } });
}
sub pl_edit {
    my ($path, $old, $new, $replace_all) = @_;
    return $J->encode({ tool_name => 'Edit', cwd => '/project',
                        tool_input => { file_path => $path, old_string => $old, new_string => $new,
                                        replace_all => ($replace_all ? jtrue() : jfalse()) } });
}

sub count_occ {
    my ($hay, $needle) = @_;
    return 0 if !length $needle;
    my ($n, $p) = (0, 0);
    while ((my $i = index($hay, $needle, $p)) >= 0) { $n++; $p = $i + length($needle) }
    return $n;
}

diag("jq available: " . ($have_jq ? "yes" : "no (hook-driving groups will SKIP)"));

# =====================================================================================
# [G1] C5 -- the constant is NAMED, not a bare literal, and carries its justification.
# Pure source inspection: needs neither jq nor a live process.
# =====================================================================================
{
    my $ledger_src = read_file($SCRIPT) // '';
    my $hook_src   = read_file($HOOK)   // '';
    my $all_src    = $ledger_src . "\n" . $hook_src;

    like($all_src, qr/\bLEDGER_FUTURE_SKEW_S\b/,
         'C5: the identifier LEDGER_FUTURE_SKEW_S appears somewhere in the write-set sources');

    # A DECLARATION line: the constant assigned the value 300 under that exact name
    # (use constant NAME => 300, or my $NAME = 300, or equivalent), not a bare 300
    # appearing only inside a comparison expression.
    my $decl_ok = ($all_src =~ /\bLEDGER_FUTURE_SKEW_S\b\s*(?:=>|=)\s*300\b/) ? 1 : 0;
    ok($decl_ok, 'C5: LEDGER_FUTURE_SKEW_S is DECLARED (assigned 300 under that name), not a magic number');

    # Referenced at least once BEYOND its own declaration (i.e., actually used to gate
    # something, not just declared and ignored).
    my $occurrences = () = ($all_src =~ /\bLEDGER_FUTURE_SKEW_S\b/g);
    cmp_ok($occurrences, '>=', 2,
           'C5: LEDGER_FUTURE_SKEW_S is referenced at least twice (declared AND used)');

    # A nearby justification: within ~20 lines of some occurrence, prose mentioning the
    # thing this constant defends against (skew / clock), not just the bare number.
    my @lines = split /\n/, $all_src, -1;
    my $justified = 0;
    for my $i (0 .. $#lines) {
        next unless $lines[$i] =~ /\bLEDGER_FUTURE_SKEW_S\b/;
        my $lo = $i - 20 < 0 ? 0 : $i - 20;
        my $hi = $i + 20 > $#lines ? $#lines : $i + 20;
        my $window = join("\n", @lines[$lo .. $hi]);
        if ($window =~ /skew/i || $window =~ /clock/i) { $justified = 1; last }
    }
    ok($justified, 'C5: a nearby comment (within ~20 lines of an occurrence) names skew/clock as the justification');
}

# =====================================================================================
# [G2] C7 -- every REAL ledger currently passes: non-vacuous enumeration (a lower
# bound, never a pinned count -- an oracle in this suite broke this session on exactly
# that), then for each: last_updated parses, and is not future-dated beyond the
# spec's own 300s allowance (checked directly, independent of whatever the
# implementation eventually names its constant -- this is the spec's OWN verified
# claim in §0, re-checked here rather than trusted).
# =====================================================================================
{
    my @active  = glob("$BP_ROOT/blueprints/*/packages/*.md");
    my @archive = glob("$BP_ROOT/blueprints/_archive/*/packages/*.md");
    my @all     = (@active, @archive);

    cmp_ok(scalar(@active),  '>=', 1,  'C7 FIXTURE-SANITY: the active-blueprint glob is non-empty');
    cmp_ok(scalar(@all),     '>=', 10, 'C7: the real ledger corpus enumerates a NON-TRIVIAL number of files (lower bound only, never pinned)');

    my $now = time;
    my ($parsed, $future) = (0, 0);
    for my $f (@all) {
        my $bytes = read_file($f);
        next unless defined $bytes;
        next unless $bytes =~ /\A---\s*\n(.*?)\n---/s;
        my $fm = $1;
        my ($lu) = grep { /^last_updated:\s*\S/ } split /\n/, $fm, -1;
        next unless defined $lu;
        my ($val) = $lu =~ /^last_updated:\s*(.*?)\s*$/;
        my $ep = defined $val ? epoch_of_iso($val) : undef;
        next unless defined $ep;
        $parsed++;
        $future++ if ($ep - $now) > 300;
    }
    cmp_ok($parsed, '>=', 10, 'C7: at least ten real ledgers carry a parseable last_updated: value');
    is($future, 0, 'C7: NONE of the real ledgers are future-dated beyond the spec\'s own 300s allowance');

    # And: bp-ledger.pl's OWN `validate` op (unrelated to the new check) must not have
    # regressed on the real corpus either.
    SKIP: {
        skip 'bp-ledger.pl absent', 1 unless -e $SCRIPT;
        my $ok_all = 1;
        for my $f (@all[0 .. (@all > 20 ? 19 : $#all)]) {   # a sample is enough; not a global re-scan
            my ($rc) = run_pl(['validate', '--ledger', $f]);
            $ok_all = 0 if $rc != 0;
        }
        ok($ok_all, 'C7: `bp-ledger.pl validate --ledger <file>` still exits 0 on a sample of the real corpus');
    }
}

# =====================================================================================
# [G3] C8 -- the orchestrator's own writer (_set_ledger_status) is unaffected: it runs
# in a non-Claude process where hooks never apply, and must not be broken by an
# API-side check either (it never calls into bp-ledger.pl at all).
# =====================================================================================
{
    my $orch_src = read_file($ORCH) // '';
    ok(length($orch_src) > 0, 'C8 FIXTURE-SANITY: bp-orchestrator.pl is readable');
    if ($orch_src =~ /^sub _set_ledger_status\b.*?\n(.*?)\n\}/ms) {
        my $body = $1;
        unlike($body, qr/bp-ledger/,    'C8: _set_ledger_status never shells out to bp-ledger.pl');
        unlike($body, qr/ledger-guard/, 'C8: _set_ledger_status never shells out to ledger-guard.sh');
        unlike($body, qr/\bsystem\s*\(/, 'C8: _set_ledger_status performs no system() call at all (plain file I/O)');
    } else {
        fail('C8: could not locate the _set_ledger_status sub body to inspect');
    }

    # Behavioural: actually call it (bp-orchestrator.pl is requirable -- guarded by
    # `unless (caller)` around its CLI). Stage a ledger whose on-disk last_updated is
    # deliberately something the hook/API WOULD reject (far future), and confirm the
    # orchestrator's own writer still succeeds, unaffected by any such gate.
    my $req_ok = eval { require $ORCH; 1 };
    ok($req_ok, 'C8: bp-orchestrator.pl can be require()d as a module without running its CLI')
        or diag("require failed: $@");
  SKIP: {
        skip 'bp-orchestrator.pl failed to load', 4 unless $req_ok;
        my ($bp, undef) = mk_bp();
        mkdir "$bp/packages" unless -d "$bp/packages";
        my $far_future = iso_of(time + 999_999);
        my $path = write_file("$bp/packages/c8-pkg.md", ledger_text(status => 'running', last_updated => $far_future));
        my $before_now = time;
        eval { BpOrch::_set_ledger_status($bp, 'c8-pkg', 'blocked') };
        is($@, '', 'C8: _set_ledger_status runs to completion with no exception against a far-future on-disk stamp');
        my $after = read_file($path);
        like($after, qr/^status: blocked$/m, 'C8: _set_ledger_status still updated status: (no gate blocked it)');
        my ($lu) = $after =~ /^last_updated:\s*(.*?)\s*$/m;
        my $ep = defined $lu ? epoch_of_iso($lu) : undef;
        ok(defined $ep && abs($ep - $before_now) < 60,
           'C8: _set_ledger_status re-stamped last_updated: to (approximately) real now, unaffected by the API-side check');
    }
}

# =====================================================================================
# [G4] The shared corpus driving C1, C2, C3, C4 and C6 TOGETHER against BOTH surfaces:
# the hook (ledger-guard.sh, via an Edit payload) and the API's own payload-mode
# validator (`bp-ledger.pl validate --payload`, which the script's own header comment
# calls "a pure lift" of the hook's logic -- the two are meant to be kept in lockstep,
# which is exactly the agreement C6 requires).
#
# Each case supplies an OLD on-disk last_updated: and a NEW candidate value (via a
# single-line Edit old_string/new_string swap, so both surfaces reconstruct the
# identical resulting bytes). "now" is captured fresh at the point each case is built,
# not once globally, so subprocess spawn latency earlier in the file cannot smear a
# skew case across the 300s boundary.
#
# VACUITY: cases 1/2 are the monotonicity opposite pair (C1 reject / C2 accept);
# cases 4/5 are the skew opposite pair (C3 reject / C4 accept). Both halves of both
# pairs run through the IDENTICAL hook invocation and the IDENTICAL API invocation, so
# neither "reject everything" nor "accept everything" can pass a whole pair.
# =====================================================================================
# COORDINATOR-ADDED (2026-08-03): make the environment gap VISIBLE instead of silent.
#
# This block gates C6 -- hook/API agreement, the single most important criterion in this
# package, since the failure mode it guards is a sanctioned API writing something the
# guard then rejects, leaving a coordinator with NO LEGAL MOVE. A bare `skip ... unless
# $have_jq` means that on any host without jq, C6 does not run and the file still reports
# green: the criterion is absent, not satisfied.
#
# The repo's own precedent decides the treatment. ledger-guard.sh calls
# `bp_hook_require_jq` and FAILS CLOSED when jq is missing, explicitly "to avoid
# unenforced operation" -- so a jq-less host cannot run the guard at all, and a suite that
# quietly passes there is asserting nothing about it.
#
# So: assert jq's presence FIRST, which fails loudly and names what went unverified, and
# keep the skip only for the dependent block. A legitimate jq-less host still gets a
# runnable file rather than a cascade of confusing errors -- but it can never read as green.
ok($have_jq,
   'C6 PRECONDITION: jq is available, so the hook can be driven and the hook/API agreement '
 . 'check below actually runs (ledger-guard.sh itself fails closed without jq)');

SKIP: {
    skip "jq is not available on this host; the hook cannot be driven without it", 1 unless $have_jq;

    my @CASES;
    {
        my $now = time;
        push @CASES, { label => 'C1: older than on-disk (50s regression)',
                       old => $now - 100, new => $now - 150, expect => 'reject', pair => 'mono' };
        push @CASES, { label => 'C2: equal to on-disk (same-second second write)',
                       old => $now - 100, new => $now - 100, expect => 'accept', pair => 'mono' };
        push @CASES, { label => 'sanity: ordinary monotonic increase',
                       old => $now - 100, new => $now - 50, expect => 'accept', pair => 'mono' };
    }
    {
        my $now = time;
        push @CASES, { label => 'C3: future beyond the 300s allowance (+330s)',
                       old => $now - 100, new => $now + 330, expect => 'reject', pair => 'skew' };
        push @CASES, { label => 'C4: ordinary future skew tolerated (+5s)',
                       old => $now - 100, new => $now + 5, expect => 'accept', pair => 'skew' };
    }

    my $case_n = 0;
    for my $c (@CASES) {
        $case_n++;
        my ($bp, $proj) = mk_bp();
        my %env = env_for($bp, $proj);
        my $lp  = ledger_path($bp);
        my $old_iso = iso_of($c->{old});
        my $new_iso = iso_of($c->{new});
        my $old_line = "last_updated: $old_iso";
        my $new_line = "last_updated: $new_iso";
        my $on_disk  = ledger_text(status => 'running', last_updated => $old_iso);
        is(count_occ($on_disk, $old_line), 1,
           "FIXTURE-SANITY (#$case_n $c->{label}): old last_updated line occurs exactly once on disk");
        write_file($lp, $on_disk);

        my $payload = pl_edit($lp, $old_line, $new_line, 0);

        my ($hrc, $hout) = run_hook($payload, %env);
        my $hverdict = $hrc == 0 ? 'accept' : ($hrc == 2 ? 'reject' : "rc=$hrc");

        my ($arc, $aout, $aerr) = run_pl(['validate', '--payload'],
            env => { %CLEAN_ENV, LG_ABS => $lp, LG_TOOL => 'Edit' }, stdin => $payload);
        my $averdict = $arc == 0 ? 'accept' : ($arc == 2 ? 'reject' : "rc=$arc");

        is($hverdict, $c->{expect}, "HOOK   (#$case_n $c->{label}): verdict is $c->{expect}");
        is($averdict, $c->{expect}, "API    (#$case_n $c->{label}): verdict is $c->{expect}");
        is($hverdict, $averdict,
           "C6     (#$case_n $c->{label}): hook and API AGREE ($hverdict vs $averdict) on the SAME candidate write");

        if ($c->{expect} eq 'reject') {
            # C1's diagnostic must name BOTH values; C3's must state the current time.
            if ($c->{pair} eq 'mono') {
                like($hout, qr/\Q$old_iso\E/, "HOOK (#$case_n): message names the OLD (on-disk) value");
                like($hout, qr/\Q$new_iso\E/, "HOOK (#$case_n): message names the NEW (candidate) value");
                like($aerr, qr/\Q$old_iso\E/, "API  (#$case_n): message names the OLD (on-disk) value");
                like($aerr, qr/\Q$new_iso\E/, "API  (#$case_n): message names the NEW (candidate) value");
            } else {
                for my $pair (['HOOK', $hout], ['API', $aerr]) {
                    my ($who, $msg) = @$pair;
                    my ($stamp) = $msg =~ /(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)/;
                    ok(defined $stamp, "$who (#$case_n): message carries a parseable ISO timestamp (the current time)");
                    my $ep = defined $stamp ? epoch_of_iso($stamp) : undef;
                    ok(defined $ep && abs($ep - time) < 120,
                       "$who (#$case_n): the timestamp named in the message is (approximately) real current time, "
                       . "so a coordinator with a wrong clock can correct rather than guess");
                }
            }
        } else {
            is($hout, '', "HOOK (#$case_n $c->{label}): accepted with empty output");
            is($aerr, '', "API  (#$case_n $c->{label}): accepted with empty stderr");
        }
    }
}

# =====================================================================================
# [G5] C1's file-byte-identity clause via a REAL MUTATING op. `validate --payload` and
# the hook are both read-only checks (neither ever writes $ABS); byte-identity after a
# rejected write can only be demonstrated against an op that actually performs a
# rename(2) on success. `set-status` is the one op that stamps last_updated:, and it
# always stamps its OWN iso_now() (wall-clock real time) -- so staging an on-disk
# value far in the FUTURE guarantees any fresh set-status write is monotonically
# OLDER than what's on disk, deterministically, regardless of when this test runs.
# =====================================================================================
{
    my $p = "$ROOT/g5-" . (++$pn) . ".md";
    my $far_future = iso_of(time + 999_999);
    write_file($p, ledger_text(status => 'running', last_updated => $far_future));
    my $before = read_file($p);
    my $digest_before = md5_hex($before);

    my ($rc, $out, $err) = run_pl(['set-status', '--ledger', $p, '--status', 'done']);
    is($rc, 2, 'C1 (real write): set-status against a far-future on-disk last_updated: is REJECTED (exit 2)');
    is($out, '', 'C1 (real write): stdout empty');
    like($err, qr/\Q$far_future\E/, 'C1 (real write): the rejection diagnostic names the OLD (on-disk) value');

    my $after = read_file($p);
    is(md5_hex($after), $digest_before, 'C1 (real write): the file is left BYTE-IDENTICAL (digest taken before matches after)');
}

# =====================================================================================
# [G6] C2's equal-permitted clause via a REAL MUTATING op that never touches
# last_updated: at all -- `append-attempt`. Its own on-disk last_updated: is
# necessarily EQUAL before and after (the op does not rewrite that line), so this is
# a genuine, deterministic "new == old" write that MUST be permitted -- pairs with G5
# against the same op family (set-status writes; append-attempt writes) rather than
# letting "reject every write" pass by accident.
# =====================================================================================
{
    my $p  = "$ROOT/g6-" . (++$pn) . ".md";
    my $lu = iso_of(time - 3600);
    write_file($p, ledger_text(status => 'running', last_updated => $lu));
    my $before = read_file($p);

    my ($rc, $out, $err) = run_pl(['append-attempt', '--ledger', $p, '--text', 'progress note']);
    is($rc, 0, 'C2 (real write): append-attempt (which leaves last_updated: unchanged -- old==new) is PERMITTED');
    is($err, '', 'C2 (real write): stderr empty');
    my $after = read_file($p);
    my ($lu_before) = $before =~ /^last_updated:\s*(.*?)\s*$/m;
    my ($lu_after)  = $after  =~ /^last_updated:\s*(.*?)\s*$/m;
    is($lu_after, $lu_before, 'C2 (real write): last_updated: is unchanged (equal), and the write still succeeded');
}

# =====================================================================================
# [G7] C3/C4 via the STATIC `validate` surface (--stdin), independent of any on-disk
# state at all -- the future-skew check is absolute (candidate vs wall-clock now), so
# it must reject/accept purely from the buffer's own last_updated: value. Pairs C3
# against C4 against the identical `validate --stdin` invocation.
# =====================================================================================
{
    my $reject_iso = iso_of(time + 330);
    my ($rc1, $out1, $err1) = run_pl(['validate', '--stdin'], stdin => ledger_text(last_updated => $reject_iso));
    is($rc1, 2, 'C3 (static validate --stdin): a stamp 330s ahead of wall-clock now is REJECTED');
    like($err1, qr/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/, 'C3 (static validate --stdin): message carries a current-time stamp');

    my $accept_iso = iso_of(time + 5);
    my ($rc2, $out2, $err2) = run_pl(['validate', '--stdin'], stdin => ledger_text(last_updated => $accept_iso));
    is($rc2, 0, 'C4 (static validate --stdin): a stamp 5s ahead of wall-clock now is ACCEPTED (ordinary skew tolerated)');
    is($err2, '', 'C4 (static validate --stdin): stderr empty');
}

# =====================================================================================
# [G8] C9 -- the two existing oracles this package must not disturb stay green,
# UNMODIFIED. Run as child processes; judged by BOTH exit code AND a grep of
# "^not ok" (a plan-count mismatch can exit non-zero or exit 0 with zero not-ok lines
# depending on shape, so both signals are required, per this session's own incident).
# =====================================================================================
for my $t ([$T64, '64-ledger-guard.t'], [$T65, '65-ledger-api.t']) {
    my ($path, $name) = @$t;
  SKIP: {
        skip "$name not found at $path", 2 unless -e $path;
        my $out = do { local %ENV = %CLEAN_ENV; `perl "$path" 2>&1` };
        my $rc  = $? >> 8;
        my $notok = () = ($out // '') =~ /^not ok /mg;
        is($rc, 0, "C9: perl $name exits 0");
        is($notok, 0, "C9: $name emits zero \"not ok\" lines");
        diag("$name: rc=$rc not-ok-count=$notok") if $rc != 0 || $notok != 0;
    }
}

done_testing();
