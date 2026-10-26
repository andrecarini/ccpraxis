# BpHook::WriteGuards -- write-guards apply the package of the subagent
# making the edit (package 13 of blueprint hook-continuity-remake). Two
# activation paths (coordinator, armed driver/its subagents) share this one
# module; contract: specs/13-guards-per-subagent-spec.md. Additive only
# (Decision 19): nothing here is registered until package 16.
#
# NOT RE-EXPRESSED (spec sec 4.1, verbatim, Decision 26 exemptions; codes
# per package 14's spec sec 4.2 -- OVR/LIB/SRC/D3/OTHER):
#
# the retired driver-guard-reach coverage
#   assertion                                                          | status
#   ------------------------------------------------------------------ | ------
#   the old shared bash guard library is present                       | LIB
#   guard-writes.sh is present, ledger-guard.sh is present              | re-expressed: AC-20
#   guard-blueprint-write.sh is present                                | OTHER (guards-remake-blueprint-write.t, SH-1)
#   bp-drive-next.pl is present                                        | OTHER (director; drive-next.t)
#   AC-7 (rc0, BP_DATA_DIR, BP_PROJECT_ROOT, BP_BLUEPRINT, BP_DIR,      | re-expressed: AC-8
#     BP_PACKAGE, write_set, test_paths byte-identical, non-empty)     |
#   AC-31/B14 (BP_LEDGER unset afterwards; child sees BP_DIR etc unset) | re-expressed: AC-16
#   AC-8 (empty write_set -> rc1, guard-writes exits 0)                | re-expressed: AC-15 F6
#   AC-10 body shape of bp_hook_gate (3 unlike, exactly three checks)  | LIB
#   AC-10 behaviour (all three unset -> exit 0, exits the script)      | re-expressed: AC-12, W4
#   AC-1/B1(5), AC-2/B2(2), AC-3/B3(3), AC-5/B5(2)                     | re-expressed: AC-8
#   AC-4/B4(2: under <data>/ and under /tmp/)                          | re-expressed: AC-8; %TEMP% forms: AC-25, AC-26
#   AC-6/B9(3)                                                        | re-expressed: AC-17
#   AC-9/B8 (guard-bash, driver git commit)                            | OTHER (guards-remake-bash.t)
#   AC-11/B7(3)                                                       | re-expressed: AC-12
#   AC-12/B11 F1,F2,F3,F4,F5,F6,F7,F8,F11,F11b (rc/no stderr, 20)      | re-expressed: AC-15
#   AC-12/B11 F9(2), F12(4), F13(2)                                    | re-expressed: AC-15
#   AC-12/B11 F14(2)                                                   | re-expressed: AC-15 F1 (same mechanism)
#   AC-13 F1,F2,F5,F9 (4)                                              | re-expressed: AC-19
#   AC-14 (bp_driver_context defined once, in the old shared bash lib) | LIB
#   AC-15 per guard: exactly one bp_driver_context call; regex count;  | LIB
#     bp_drive_any_active present                                     |
#   AC-15 per guard: no bp_drive_active_dir/.drive-solo-active/        | re-expressed: AC-20
#     current.json re-derivation                                      |
#   AC-16, AC-17 (hook table and control)                              | SRC (also listed by package 14)
#   AC-18, AC-19 (blueprint.md denied regardless of driver state)      | OTHER (guards-remake-blueprint-write.t, BW-6)
#   AC-20 (guard-blueprint-write source pin)                           | SRC
#   AC-21,22,23,24,26 (hatch file/env, TTL, advert)                    | OVR (.driver-guards-off,
#                                                                      |   CCPRAXIS_DRIVER_GUARDS_OFF(_TTL_MIN); Decision 68)
#   AC-25 (hatch present, blueprint guard still denies)                | OVR (same hatch; Decision 68)
#   AC-32 (test-writer/implementer solo marker, 4)                     | re-expressed: AC-7
#   AC-32 (stale marker gives driver rules, 2)                         | re-expressed: AC-8
#   AC-27,28,29,30 (director current.json pointer, --help, STATE)      | OTHER (bp-drive-next.pl; package 16 retires it)
#   RT-1 (write to the hatch file denied)                              | re-expressed: AC-10
#   RT-2, RT-3 (V6 widen and blank)                                    | re-expressed: AC-18
#   RT-4 (write to current.json denied)                                | re-expressed: AC-10
#   RT-5 (ambient BP_DRIVER_SESSION on the worker path; no crash)      | re-expressed: AC-12
#   RT-6 (future-dated hatch)                                          | OVR (hatch; Decision 68)
#   RT-7 (empty-scope done removes current.json)                      | OTHER (director; Decision 68)
#
# the retired driver-context-session-scope coverage
#   assertion                                                          | status
#   ------------------------------------------------------------------ | ------
#   both guards exist                                                  | re-expressed: AC-20
#   driver, inside the write set: allowed                              | re-expressed: AC-8
#   driver or its subagent, outside the write set: blocked             | re-expressed: AC-8, AC-5
#   another session in the same project: not held                     | re-expressed: AC-11
#   a payload with no session_id keeps any-drive-active (blocked)     | D3 (Decision 3: unattributable payload is
#                                                                      |   never guarded; AC-11 asserts the opposite)
#   the driver may not write a test file, and is told why             | re-expressed: AC-8
#   a bp-test-writer subagent may write its test file                 | re-expressed: AC-7
#   a read-only role gains nothing from agent_type                    | re-expressed: AC-7 (bp-reviewer)
#   drive-letter root form (setup, inside allowed, outside blocked)    | re-expressed: AC-14
#   ledger-guard: driver writing a corrupt ledger is blocked          | re-expressed: AC-17
#   ledger-guard: another session is not affected                    | re-expressed: AC-11
#
# It never calls exit, never spawns a process (no system/exec/backtick/qx/
# fork/piped open), never re-parses the payload, never writes a file, never
# sets or deletes an %ENV key, and prints only through BpHook::deny.
package BpHook::WriteGuards;
use strict;
use warnings;
use JSON::PP ();
use B ();
use Cwd ();
use File::Basename ();

my $SELF_DIR;
{
    my $f = __FILE__;
    $f = Cwd::abs_path($f) // $f;
    $SELF_DIR = File::Basename::dirname($f);
}
require "$SELF_DIR/../BpHook.pm"
    unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
require "$SELF_DIR/BindDispatch.pm"
    unless grep { m{(?:^|/)BindDispatch\.pm$} } keys %INC;
require "$SELF_DIR/Guards/Common.pm"
    unless grep { m{(?:^|/)Common\.pm$} } keys %INC;

my $MAX_LISTED = 4;

# ---------------------------------------------------------------------------
# Decision 69 A2 (addendum AC-29): $CASE_INSENSITIVE controls whether every
# path comparison this module makes folds ASCII A-Z/a-z before comparing.
# undef (the default) means "auto-detect from $^O" (true on msys, MSWin32,
# cygwin, darwin; false elsewhere). Tests set it directly to make their
# verdicts host-independent.
# ---------------------------------------------------------------------------
our $CASE_INSENSITIVE;

sub _is_ci {
    return $CASE_INSENSITIVE ? 1 : 0 if defined $CASE_INSENSITIVE;
    return ($^O =~ /\A(?:msys|MSWin32|cygwin|darwin)\z/) ? 1 : 0;
}

# fold ASCII A-Z only; non-ASCII bytes/chars compare as they are.
sub _foldc {
    my ($s) = @_;
    return $s unless defined $s;
    my $t = $s;
    $t =~ tr/A-Z/a-z/;
    return $t;
}

# ---------------------------------------------------------------------------
# Decision 69 A2 (addendum AC-29): a Windows short (8.3) name anywhere below
# the project root or the data dir is denied unconditionally (independent of
# $CASE_INSENSITIVE, on every host, since resolving it would need disk or
# Win32 calls this module does not make).
# ---------------------------------------------------------------------------
sub _8dot3_re { return qr/^[^~\/]{1,6}~[0-9]+(?:\.[^.\/]{0,3})?$/ }

sub _has_8dot3 {
    my ($rel) = @_;
    return 0 unless defined $rel && length $rel;
    my $re = _8dot3_re();
    for my $seg (split m{/}, $rel) {
        return 1 if $seg =~ $re;
    }
    return 0;
}

# _deny_8dot3_lines is the pure form (package 02, spec sec 2.1): the line
# list only, already _cfit'd, never printed. _deny_8dot3 stays the printing
# wrapper _ledger uses, so ledger mode's bytes do not move.
sub _deny_8dot3_lines {
    my ($ABS) = @_;
    return [ _cfit(sprintf(
        'BLOCKED: %s uses a Windows short (8.3) name; write it by its long name.', _cpathecho($ABS))) ];
}

sub _deny_8dot3 {
    my ($ABS) = @_;
    return BpHook::deny(@{ _deny_8dot3_lines($ABS) });
}

# ---------------------------------------------------------------------------
# Decision 70 (fix-batch.md sec D A10, AC-35): among packages/*.md in a
# blueprint dir, a bound (or sole) subagent may write only its OWN package's
# ledger -- writing a sibling package's ledger file is denied unconditionally
# (regardless of the content of the write), in both writes mode and ledger
# mode, with a message naming both packages. Driver mode is untouched here:
# the driver's own V6 scope-freeze (in _validate) already covers every
# in-flight member's ledger.
# ---------------------------------------------------------------------------
sub _sibling_ledger_name {
    my ($ABS_c, $P) = @_;
    my $ci = _is_ci();
    my $pref = _ccanon($P->{bpdir} . '/packages') . '/';
    my ($a, $b) = $ci ? (_foldc($ABS_c), _foldc($pref)) : ($ABS_c, $pref);
    return undef unless index($a, $b) == 0;
    my $rel = substr($ABS_c, length($pref));
    my $name;
    if ($ci) { return undef unless $rel =~ /\A([^\/]+)\.md\z/i; $name = $1 }
    else     { return undef unless $rel =~ /\A([^\/]+)\.md\z/;  $name = $1 }
    my $eq = $ci ? (_foldc($name) eq _foldc($P->{package})) : ($name eq $P->{package});
    return undef if $eq;
    return undef unless _member_ok($name);
    return $name;
}

# _sibling_ledger_deny_lines is may_write's pure form of the 'ledger' branch
# below: the line list only, already _cfit'd.
sub _sibling_ledger_deny_lines {
    my ($ABS_c, $R) = @_;
    return undef unless defined($R->{mode}) && $R->{mode} eq 'subagent';
    for my $P (@{ $R->{packages} || [] }) {
        my $sib = _sibling_ledger_name($ABS_c, $P);
        next unless defined $sib;
        return [ _cfit(sprintf(
            "BLOCKED: this subagent is bound to package %s and may not write the ledger of sibling package %s; each subagent may only write its own package ledger.",
            $P->{package}, $sib)) ];
    }
    return undef;
}

# _maybe_deny_sibling_ledger -- ledger mode's only remaining caller
# (_ledger, below); _writes now goes through may_write ->
# _sibling_ledger_deny_lines directly, so there is no other shape to keep.
sub _maybe_deny_sibling_ledger {
    my ($ABS, $ABS_c, $R) = @_;
    return undef unless defined($R->{mode}) && $R->{mode} eq 'subagent';
    for my $P (@{ $R->{packages} || [] }) {
        my $sib = _sibling_ledger_name($ABS_c, $P);
        next unless defined $sib;
        return _ledger_deny(sprintf(
            "this subagent is bound to package %s and may not write sibling package %s's ledger; each subagent may only write its own package ledger",
            $P->{package}, $sib), $ABS);
    }
    return undef;
}

# _maybe_deny_8dot3_lines is may_write's pure form: the line list only.
sub _maybe_deny_8dot3_lines {
    my ($ABS, $ABS_c, $R) = @_;
    my @roots;
    push @roots, $R->{root} if defined($R->{root}) && length($R->{root});
    push @roots, $R->{data} if defined($R->{data}) && length($R->{data});
    for my $r (@roots) {
        next unless _in($ABS_c, $r);
        my $rc = _ccanon($r);
        my $rel = substr($ABS_c, length($rc) + 1);
        return _deny_8dot3_lines($ABS) if _has_8dot3($rel);
    }
    return undef;
}

sub _maybe_deny_8dot3 {
    my ($ABS, $ABS_c, $R) = @_;
    my $lines = _maybe_deny_8dot3_lines($ABS, $ABS_c, $R);
    return defined($lines) ? BpHook::deny(@$lines) : undef;
}

# ---------------------------------------------------------------------------
# small local wrappers over BpHook::Guards::Common, kept short for legibility
# at every call site below.
# ---------------------------------------------------------------------------
sub _ccanon      { return BpHook::Guards::Common::canon(@_) }
sub _cfit        { return BpHook::Guards::Common::fit(@_) }
sub _cpathecho   { return BpHook::Guards::Common::path_echo(@_) }
sub _cresolvepath{ return BpHook::Guards::Common::resolve_path(@_) }
sub _ciswriter   { return BpHook::Guards::Common::is_writer(@_) }

# ---------------------------------------------------------------------------
# _in($abs_canon, $dir) -- canon($abs_canon) [already canon'd by caller]
# starts with canon($dir) . '/'. $dir need not be pre-canon'd. Decision 69
# A2: folds ASCII case when _is_ci() is true.
# ---------------------------------------------------------------------------
sub _in {
    my ($abs_c, $dir) = @_;
    return 0 unless defined $abs_c && defined $dir && length $dir;
    my $dc = _ccanon($dir);
    return 0 unless defined $dc && length $dc;
    if (_is_ci()) {
        return (index(_foldc($abs_c), _foldc($dc) . '/') == 0) ? 1 : 0;
    }
    return (index($abs_c, "$dc/") == 0) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# _under_any_reports($abs_c, $data) -- Decision 100: true iff $abs_c lies
# under "<data>/blueprints/<any bp>/reports/", for ANY blueprint name
# (including one with no in-flight package at all). $abs_c is already
# lexically collapsed and canon()-ed by the caller (_abs_of), so a literal
# ".." segment can never reach this far -- no separate traversal check is
# needed here.
# ---------------------------------------------------------------------------
sub _under_any_reports {
    my ($abs_c, $data) = @_;
    return 0 unless defined $abs_c && defined $data && length $data;
    my $dc = _ccanon($data);
    return 0 unless defined $dc && length $dc;
    my ($a, $d) = _is_ci() ? (_foldc($abs_c), _foldc($dc)) : ($abs_c, $dc);
    return ($a =~ m{\A\Q$d\E/blueprints/[^/]+/reports/}) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# _target_path($p) -- tool_input.file_path, else tool_input.notebook_path,
# when a non-empty plain string; else undef.
# ---------------------------------------------------------------------------
sub _target_path {
    my ($p) = @_;
    return undef unless ref $p eq 'HASH';
    my $ti = (ref $p->{tool_input} eq 'HASH') ? $p->{tool_input} : {};
    for my $k (qw(file_path notebook_path)) {
        my $v = $ti->{$k};
        return $v if defined $v && !ref($v) && length $v;
    }
    return undef;
}

sub _abs_of {
    my ($p) = @_;
    my $fp = _target_path($p);
    return (undef, undef) unless defined $fp;
    my $cwd = (ref $p eq 'HASH') ? $p->{cwd} : undef;
    my $fp_b  = BpHook::_to_bytes($fp);
    my $cwd_b = (defined $cwd && !ref($cwd) && length $cwd) ? BpHook::_to_bytes($cwd) : undef;
    my $ABS = _cresolvepath($fp_b, $cwd_b);
    return (undef, undef) unless defined $ABS;
    return ($ABS, _ccanon($ABS));
}

# ---------------------------------------------------------------------------
# 2.6.5 temp allowance -- private to this module, no subprocess, no cygpath.
# ---------------------------------------------------------------------------
sub _collapse_lexical {
    my ($v) = @_;
    my $prefix = '';
    if ($v =~ s{^([A-Za-z]:)/}{}) { $prefix = "$1/" }
    elsif ($v =~ s{^/}{}) { $prefix = '/' }
    my @in = split m{/}, $v;
    my @out;
    for my $seg (@in) {
        next if $seg eq '' || $seg eq '.';
        if ($seg eq '..') {
            if (@out && $out[-1] ne '..') { pop @out }
            else { push @out, $seg }
            next;
        }
        push @out, $seg;
    }
    return $prefix . join('/', @out);
}

sub _is_abs_form {
    my ($v) = @_;
    return 0 unless defined $v && length $v;
    return 1 if $v =~ m{\A/};
    return 1 if $v =~ m{\A[A-Za-z]:/};
    return 0;
}

sub _temp_candidates {
    my @raw;
    for my $var (qw(TMPDIR TEMP TMP)) {
        my $v = $ENV{$var};
        push @raw, $v if defined $v && length $v;
    }
    my $la = $ENV{LOCALAPPDATA};
    if (defined $la && length $la) {
        my $lab = BpHook::_to_bytes($la);
        $lab =~ tr{\\}{/};
        if (_is_abs_form($lab)) {
            push @raw, "$lab/Temp";
        }
    }
    my @valid;
    for my $cand (@raw) {
        my $v = BpHook::_to_bytes($cand);
        $v =~ tr{\\}{/};
        next unless _is_abs_form($v);
        $v = _collapse_lexical($v);
        next if $v eq '/';
        my $c = _ccanon($v);
        next unless defined $c && length $c;
        next if $c =~ m{\A[a-z]:/?\z};
        push @valid, $v;
    }
    return @valid;
}

# ---------------------------------------------------------------------------
# spec 31 sec 2.2: _seg_eq_base -- segment equality for the temp-base prefix
# only, tolerant of one side being a Windows 8.3 short name.
# ---------------------------------------------------------------------------
sub _seg_eq_base {
    my ($a, $b) = @_;
    $a = '' unless defined $a;
    $b = '' unless defined $b;
    return 1 if (_is_ci() ? _foldc($a) eq _foldc($b) : $a eq $b);
    return 0 unless _is_ci();
    my $re = _8dot3_re();
    my $sa = ($a =~ $re) ? 1 : 0;
    my $sb = ($b =~ $re) ? 1 : 0;
    return 0 unless $sa xor $sb;
    my ($short, $long) = $sa ? ($a, $b) : ($b, $a);
    (my $stem = $short) =~ s/~.*\z//s;
    my $stem_f = _foldc($stem);
    $stem_f =~ s/[^a-z0-9]//g;
    my $basis_f = _foldc($long);
    $basis_f =~ s/[^a-z0-9]//g;
    my $want = (length($basis_f) >= 6) ? substr($basis_f, 0, 6) : $basis_f;
    return (length($stem_f) > 0 && $stem_f eq $want) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# spec 31 sec 2.1: _own_scratchpad -- driver-only allowance for a write
# strictly below THIS session's scratchpad dir. No filesystem access.
# ---------------------------------------------------------------------------
sub _own_scratchpad {
    my ($p, $ABS_c, $R) = @_;
    return 0 unless defined($R->{mode}) && $R->{mode} eq 'driver';

    my $sid = BpHook::session_id($p);
    return 0 unless defined $sid;

    my $tp = (ref $p eq 'HASH') ? $p->{transcript_path} : undef;
    return 0 unless defined $tp && !ref($tp) && length $tp;
    my $T = _collapse_lexical(BpHook::_to_bytes($tp));
    return 0 unless $T =~ m{/([^/]+)/([^/]+)\z};
    my ($slug, $base) = ($1, $2);
    my $ci = _is_ci();
    my $base_ok = $ci ? (_foldc($base) eq _foldc("$sid.jsonl")) : ($base eq "$sid.jsonl");
    return 0 unless $base_ok;
    return 0 unless $slug =~ /\A[A-Za-z0-9-]{1,255}\z/;

    return 0 if _in($ABS_c, $R->{root});
    return 0 if defined($R->{data}) && length($R->{data}) && _in($ABS_c, $R->{data});

    for my $B (_temp_candidates()) {
        my $Bc = _ccanon($B);
        next unless defined $Bc && length $Bc;
        my @b = split m{/}, $Bc;
        my @a = split m{/}, $ABS_c;
        next unless @a >= @b + 5;
        my $ok = 1;
        for my $i (0 .. $#b) {
            unless (_seg_eq_base($a[$i], $b[$i])) { $ok = 0; last }
        }
        next unless $ok;
        my @tail = @a[scalar(@b) .. scalar(@b) + 3];
        my @want = ('claude', $slug, $sid, 'scratchpad');
        my $tail_ok = 1;
        for my $i (0 .. 3) {
            my ($x, $y) = ($tail[$i], $want[$i]);
            unless ($ci ? (_foldc($x) eq _foldc($y)) : ($x eq $y)) { $tail_ok = 0; last }
        }
        return 1 if $tail_ok;
    }
    return 0;
}

sub _is_temp {
    my ($abs_c, $root, $data) = @_;
    return 0 if defined($root) && length($root) && _in($abs_c, $root);
    return 0 if defined($data) && length($data) && _in($abs_c, $data);
    return 1 if $abs_c =~ m{\A/tmp/};
    for my $cand (_temp_candidates()) {
        return 1 if _in($abs_c, $cand);
    }
    return 0;
}

# ---------------------------------------------------------------------------
# member-name rule (spec sec 2.3 point 1) -- BindDispatch's own rule, reused
# fully qualified (dispatch-binding.t already does the same for
# _append_history).
# ---------------------------------------------------------------------------
sub _member_ok { return BpHook::BindDispatch::member_ok(@_) }

# ---------------------------------------------------------------------------
# _read_frontmatter($path) -- sec 2.3 point 3: line 1 must be exactly '---'
# (a trailing \r tolerated); scanning stops at the next '---' line or after
# 200 further lines. First occurrence of a "key:" line wins, value trimmed.
# undef only when the file cannot be opened or line 1 is not '---'.
# ---------------------------------------------------------------------------
sub _read_frontmatter {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    my @lines;
    while (my $l = <$fh>) {
        push @lines, $l;
        last if scalar(@lines) >= 201;
    }
    close $fh;
    return undef unless @lines;
    (my $first = $lines[0]) =~ s/\r?\n\z//;
    # Decision 69 A3 (red-team H4): agree with the ledger-mode V2 check
    # (_fm_block's leading \s*\n), which accepts '---' followed by trailing
    # [ \t\r]. Accepted by both, or by neither.
    $first =~ s/[ \t\r]+\z//;
    return undef unless $first eq '---';
    my %fm;
    for my $i (1 .. $#lines) {
        (my $l = $lines[$i]) =~ s/\r?\n\z//;
        last if $l eq '---';
        if ($l =~ /^([A-Za-z_][A-Za-z0-9_]*):\s*(.*?)\s*$/) {
            my ($k, $v) = ($1, $2);
            $fm{$k} = $v unless exists $fm{$k};
        }
    }
    return \%fm;
}

# ---------------------------------------------------------------------------
# usable($data, $bp, $pkg) -- sec 2.3.
# ---------------------------------------------------------------------------
sub _usable {
    my ($data, $bp, $pkg) = @_;
    return undef unless _member_ok($bp) && _member_ok($pkg);
    my $bpdir = "$data/blueprints/$bp";
    return undef unless -d $bpdir;
    my $ledger = "$bpdir/packages/$pkg.md";
    return undef unless -f $ledger;
    my $fm = _read_frontmatter($ledger);
    return undef unless defined $fm;
    my $status = $fm->{status};
    return undef unless defined $status;
    return undef if grep { $status eq $_ } qw(done blocked parked dropped);
    my $ws = $fm->{write_set};
    return undef unless defined $ws && length $ws;
    my $tp = defined($fm->{test_paths}) ? $fm->{test_paths} : '';
    return {
        blueprint  => $bp,
        package    => $pkg,
        bpdir      => $bpdir,
        ledger     => $ledger,
        write_set  => $ws,
        test_paths => $tp,
    };
}

# ---------------------------------------------------------------------------
# meta.json / binding lookup, sec 2.5.
# ---------------------------------------------------------------------------
sub _meta_tool_use_id {
    my ($p) = @_;
    my $aid = BpHook::agent_id($p);
    return undef unless defined $aid && $aid ne '?';
    my $sid = BpHook::session_id($p);
    return undef unless defined $sid;
    my $tp = (ref $p eq 'HASH') ? $p->{transcript_path} : undef;
    return undef unless defined $tp && !ref($tp) && length $tp;
    my $T = BpHook::_to_bytes($tp);
    my $S;
    if ($T =~ m{/\Q$sid\E/subagents/[^/]+\.jsonl\z}) {
        ($S = $T) =~ s{/[^/]*\z}{};
    }
    else {
        (my $dir = $T) =~ s{/[^/]*\z}{};
        $S = "$dir/$sid/subagents";
    }
    my $path = "$S/agent-$aid.meta.json";
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return undef unless defined $raw;
    my $data = eval { JSON::PP->new->utf8->decode($raw) };
    return undef unless ref $data eq 'HASH';
    my $tuid = $data->{toolUseId};
    return undef unless defined $tuid && !ref($tuid) && $tuid =~ /^[A-Za-z0-9_-]{1,128}$/;
    return $tuid;
}

sub _binding {
    my ($data, $tuid) = @_;
    return undef unless defined $tuid && $tuid =~ /^[A-Za-z0-9_-]{1,128}$/;
    my $path = "$data/.drive-solo/bindings/$tuid.json";
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return undef unless defined $raw;
    my $rec = eval { JSON::PP->new->utf8->decode($raw) };
    return undef unless ref $rec eq 'HASH';
    my ($bp, $pkg) = ($rec->{blueprint}, $rec->{package});
    return undef unless _member_ok($bp) && _member_ok($pkg);
    return { blueprint => $bp, package => $pkg };
}

# ---------------------------------------------------------------------------
# _worker_subagent_type($data, $tuid) -- Decision 100: the subagent_type
# named by BpHook::Guards::TrackDispatch's own worker record at
# "<data>/.drive-solo/workers/<tuid>" (no ".json" suffix, unlike bindings/).
# undef on any read/shape failure -- never used to widen anything by itself.
# ---------------------------------------------------------------------------
sub _worker_subagent_type {
    my ($data, $tuid, $caller_sid) = @_;
    return undef unless defined $tuid && $tuid =~ /^[A-Za-z0-9_-]{1,128}$/;
    my $path = "$data/.drive-solo/workers/$tuid";
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return undef unless defined $raw;
    my $rec = eval { JSON::PP->new->utf8->decode($raw) };
    return undef unless ref $rec eq 'HASH';
    # Decision 101 minor: a record for a DIFFERENT session grants nothing --
    # without this, a forged/stale record naming another session's tuid
    # could be read back as this caller's own.
    return undef unless defined $caller_sid && defined $rec->{session_id}
        && !ref($rec->{session_id}) && $rec->{session_id} eq $caller_sid;
    my $t = $rec->{subagent_type};
    return (defined $t && !ref($t) && length $t) ? $t : undef;
}

sub _agent_type_of {
    my ($p) = @_;
    my $v = (ref $p eq 'HASH') ? $p->{agent_type} : undef;
    return '' unless defined $v && !ref($v) && length $v;
    my @parts = split /:/, $v;
    my $last = $parts[-1];
    return defined($last) ? $last : '';
}

# ---------------------------------------------------------------------------
# coordinator worker marker -- sec 2.4 / Decision 69 A1 (review B1, red-team
# H1). The marker lives at "$BP_DIR/runs/<pkg>.active-worker" --
# BpHook::Guards::TrackDispatch.pm:463 is the production writer/reader.
# NEVER at "<data>/runs/" (BP_DIR is, in general, a strict
# subdirectory of the data dir, and the two must not be confused).
# ---------------------------------------------------------------------------
sub _coordinator_worker {
    my ($bp_dir_b) = @_;
    return '' unless defined $bp_dir_b && length $bp_dir_b;
    (my $d = $bp_dir_b) =~ s{/+\z}{};
    my $pkg = $ENV{BP_PACKAGE};
    $pkg = (defined $pkg && length $pkg) ? $pkg : 'pkg';
    my $path = "$d/runs/$pkg.active-worker";
    open(my $fh, '<:raw', $path) or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return '' unless defined $c;
    my $w = _ciswriter($c);
    return defined($w) ? $w : '';
}

# _union_paths($a, $b) -> the ':'-joined union of two ':'-separated path
# lists, $a's entries first, order kept, duplicates and empties dropped.
sub _union_paths {
    my ($a, $b) = @_;
    my (@out, %seen);
    for my $s ($a, $b) {
        next unless defined $s && !ref $s && length $s;
        for my $e (split /:/, $s) {
            next unless length $e;
            push @out, $e unless $seen{$e}++;
        }
    }
    return join(':', @out);
}

# ---------------------------------------------------------------------------
# resolve($p) -- sec 2.4. Exposed for tests.
# ---------------------------------------------------------------------------
sub resolve {
    my ($p) = @_;

    my $ledger_env = $ENV{BP_LEDGER};
    if (defined $ledger_env && length $ledger_env) {
        my $bp_dir    = $ENV{BP_DIR};
        my $proj_root = $ENV{BP_PROJECT_ROOT};
        return undef unless defined $bp_dir    && length $bp_dir;
        return undef unless defined $proj_root && length $proj_root;
        my $bp_dir_b    = BpHook::_to_bytes($bp_dir);
        my $proj_root_b = BpHook::_to_bytes($proj_root);
        my $ledger_b    = BpHook::_to_bytes($ledger_env);
        my $pkg = $ENV{BP_PACKAGE};
        $pkg = (defined $pkg && length $pkg) ? $pkg : 'pkg';
        my $ws = defined($ENV{BP_WRITE_SET})  ? $ENV{BP_WRITE_SET}  : '';
        my $tp = defined($ENV{BP_TEST_PATHS}) ? $ENV{BP_TEST_PATHS} : '';
        # The env pair is a snapshot from bp-launch.sh. A widening recorded
        # mid-session through bp-ledger.pl widen-write-set / set-test-paths
        # (which require a blueprint Decision naming the path) never reached
        # it, so the coordinator was refused its own sanctioned paths and had
        # to park for a relaunch that only re-reads this same ledger
        # (judged-continuity-disarm/02 at 16:01Z and /03 at 02:11Z,
        # 2026-10-22/23). The ledger's current fields are now unioned in:
        # nothing a relaunch would not grant, and a narrowing still waits for
        # one, exactly as before.
        if (-f $ledger_b) {
            my $fm = _read_frontmatter($ledger_b);
            if (ref $fm eq 'HASH') {
                $ws = _union_paths($ws, $fm->{write_set});
                $tp = _union_paths($tp, $fm->{test_paths});
            }
        }
        my $worker = _coordinator_worker($bp_dir_b);
        return {
            mode       => 'coordinator',
            kind       => 'env',
            root       => $proj_root_b,
            data       => undef,
            allow_dirs => [ $bp_dir_b ],
            deny_dirs  => [],
            packages   => [ {
                package    => $pkg,
                blueprint  => undef,
                bpdir      => $bp_dir_b,
                ledger     => $ledger_b,
                write_set  => $ws,
                test_paths => $tp,
            } ],
            worker     => $worker,
            actor      => 'coordinator',
            agent_type => '',
            inflight   => undef,
        };
    }

    my $role = eval { BpHook::role($p) };
    return undef unless defined $role && $role eq 'driver';

    my $data = BpHook::BindDispatch::resolve_data_dir($p);
    return undef unless defined $data && length $data;
    # Decision 69 A9 (red-team M2): strip a trailing '/' before deriving
    # anything from $data -- otherwise the root-derivation regex below strips
    # only the trailing empty segment, leaving $droot equal to $data itself.
    $data =~ tr{\\}{/};
    $data =~ s{/+\z}{};
    (my $droot = $data) =~ s{/[^/]*\z}{};

    my @members = BpHook::BindDispatch::inflight_members($data);
    my @U;
    for my $m (@members) {
        my $u = _usable($data, $m->{bp}, $m->{pkg});
        push @U, $u if defined $u;
    }
    my $n_inflight = scalar @U;

    my $aid = BpHook::agent_id($p);
    if (defined $aid) {
        my $tuid = _meta_tool_use_id($p);
        my $b = defined($tuid) ? _binding($data, $tuid) : undef;
        my $P = defined($b) ? _usable($data, $b->{blueprint}, $b->{package}) : undef;
        my $sid = BpHook::session_id($p);
        my ($kind, @packages);
        if (defined $P) {
            $kind = 'bound';
            @packages = ($P);
        }
        elsif (defined $b) {
            # Decision 69 A3 (red-team H4): the binding FILE exists but names
            # a package that is not usable now (no ledger, or a terminal/
            # parked status). Refused unconditionally -- never falls back to
            # another in-flight package's scope ("sole"), and never to no
            # guard at all (undef), regardless of how many other packages
            # are in flight. Only a subagent with NO binding at all (the
            # elsif branches below) takes that fallback.
            $kind = 'refused_bound';
            @packages = ();
        }
        else {
            # Decision 100/101 M2: an unbound subagent whose OWN worker
            # record (session_id-matched) names a subagent_type BindDispatch
            # exempts from the one-ledger rule (Decision 98) is ALWAYS
            # reports-only -- checked here, before n_inflight, so it can
            # never fall into 'sole' and inherit a package's full write_set
            # (the review's M2 finding).
            my $stype = defined($tuid) ? _worker_subagent_type($data, $tuid, $sid) : undef;
            my $exempt = (defined $stype
                && eval { BpHook::BindDispatch::is_exempt_type($stype) }) ? 1 : 0;
            if ($exempt) {
                $kind = 'exempt_reports';
                @packages = ();
            }
            elsif ($n_inflight == 0) {
                return undef;
            }
            elsif ($n_inflight == 1) {
                $kind = 'sole';
                @packages = @U;
            }
            else {
                $kind = 'refused';
                @packages = @U;
            }
        }
        my @allow_dirs = ($kind eq 'refused' || $kind eq 'refused_bound' || $kind eq 'exempt_reports')
            ? () : (map { $_->{bpdir} } @packages);

        my $agent_type = _agent_type_of($p);
        my $w = _ciswriter($agent_type);
        return {
            mode       => 'subagent',
            kind       => $kind,
            root       => $droot,
            data       => $data,
            allow_dirs => \@allow_dirs,
            deny_dirs  => [],
            packages   => \@packages,
            worker     => defined($w) ? $w : '',
            actor      => 'subagent',
            agent_type => $agent_type,
            inflight   => $n_inflight,
            bound      => $b,
        };
    }
    else {
        return undef if $n_inflight == 0;
        my $kind = ($n_inflight == 1) ? 'single' : 'union';
        return {
            mode       => 'driver',
            kind       => $kind,
            root       => $droot,
            data       => $data,
            allow_dirs => [ $data ],
            # Decision 69 A5 (red-team M4): the driver's data-dir allowance
            # excludes these top-level entries, case-folded per A2.
            deny_dirs  => [ "$data/.drive-solo", "$data/.subagent-guard",
                            "$data/claude-home", "$data/bug-reports" ],
            packages   => \@U,
            worker     => '',
            actor      => 'driver',
            agent_type => '',
            inflight   => $n_inflight,
        };
    }
}

# ---------------------------------------------------------------------------
# 2.7 write-set matching, carried unchanged from guard-writes.sh's old
# shared match_any.
# ---------------------------------------------------------------------------
sub _glob_to_regex {
    my ($pat) = @_;
    my $re = '';
    my $i = 0;
    my $n = length($pat);
    while ($i < $n) {
        my $c = substr($pat, $i, 1);
        if ($c eq '\\' && $i + 1 < $n) {
            $re .= quotemeta(substr($pat, $i + 1, 1));
            $i += 2;
            next;
        }
        if ($c eq '*') { $re .= '.*'; $i++; next }
        if ($c eq '?') { $re .= '.'; $i++; next }
        if ($c eq '[') {
            my $j = $i + 1;
            my $neg = 0;
            if ($j < $n && (substr($pat, $j, 1) eq '!' || substr($pat, $j, 1) eq '^')) { $neg = 1; $j++ }
            my $start = $j;
            if ($j < $n && substr($pat, $j, 1) eq ']') { $j++ }
            while ($j < $n && substr($pat, $j, 1) ne ']') { $j++ }
            if ($j >= $n) {
                $re .= quotemeta($c);
                $i++;
                next;
            }
            my $body = substr($pat, $start, $j - $start);
            $body =~ s/\\/\\\\/g;
            $re .= '[' . ($neg ? '^' : '') . $body . ']';
            $i = $j + 1;
            next;
        }
        $re .= quotemeta($c);
        $i++;
    }
    # Decision 69 A4 (red-team M1): a malformed bracket expression (e.g.
    # "[z-a]", an unclosed "[") must never make the guard die -- it matches
    # nothing, exactly as bash's [[ == ]] does.
    my $qr = eval { qr/\A$re\z/s };
    return $qr if defined $qr;
    return qr/(?!)/;
}

sub _longest {
    my ($rel, $patstr) = @_;
    return (-1, '') unless defined $patstr && length $patstr;
    my @elems = split /:/, $patstr, -1;
    my ($best_len, $best_pat) = (-1, '');
    my $ci = _is_ci();
    my $rel_m = $ci ? _foldc($rel) : $rel;
    for my $pat (@elems) {
        next if $pat eq '';
        my $pat_m = $ci ? _foldc($pat) : $pat;
        my $hit = 0;
        if ($pat_m =~ m{/\z}) {
            $hit = 1 if index($rel_m, $pat_m) == 0 || "$rel_m/" eq $pat_m;
        }
        else {
            my $re = _glob_to_regex($pat_m);
            $hit = ($rel_m =~ $re) ? 1 : 0;
        }
        if ($hit && length($pat) > $best_len) {
            $best_len = length($pat);
            $best_pat = $pat;
        }
    }
    return ($best_len, $best_pat);
}

# _is_test_shape($rel) -> 1 when the path LOOKS like a test file. Consulted
# only for a path a test_paths pattern already covers: there it makes the
# file a test even when a write_set pattern is the longer match, so a
# write_set glob can never take a real test file away from bp-test-writer.
#
# ccpraxis's own tests/t/*.t was the only shape until bug 20260825-175738-5a8d:
# a downstream package with test_paths functions/test/llm/ and a write_set
# glob functions/test/llm/gemini* (27 chars against 20) had its test-writer
# blocked from writing functions/test/llm/gemini-verbete-citations.test.ts.
# The shapes are matched on the basename and are the common conventions:
# foo.test.ts / foo.spec.tsx (JS/TS), x_test.go / x_test.py / x_spec.rb,
# test_x.py. Java-style FooTest.java is left out on purpose: case-folded on a
# case-insensitive host it reads *test.java and would claim latest.java.
# A non-test file in a test directory (a fixture, a helper) keeps its
# write_set ownership. A test-shaped file stays a test even when the
# write_set names it literally, the rule MAJOR-2/MINOR-8 already set for .t.
sub _is_test_shape {
    my ($rel) = @_;
    my $rel_m = _is_ci() ? _foldc($rel) : $rel;
    for my $pat ('*/tests/t/*.t', 'tests/t/*.t') {
        my $re = _glob_to_regex($pat);
        return 1 if $rel_m =~ $re;
    }
    (my $base = $rel_m) =~ s{\A.*/}{};
    return 1 if $base =~ /\A[^.]+(?:\.[^.]+)*\.(?:test|spec)\.[A-Za-z0-9]+\z/;
    return 1 if $base =~ /\A.+_(?:test|spec)\.[A-Za-z0-9]+\z/;
    return 1 if $base =~ /\Atest_.+\.py\z/;
    return 0;
}

# ---------------------------------------------------------------------------
# 2.8 roles / WHO.
# ---------------------------------------------------------------------------
sub _who {
    my ($R, $worker, $actor) = @_;
    return 'bp-implementer' if $worker eq 'bp-implementer';
    return 'the driver' if $actor eq 'driver';
    if ($actor eq 'subagent') {
        my $at = defined($R->{agent_type}) ? $R->{agent_type} : '';
        return length($at) ? "a $at subagent" : 'a subagent';
    }
    return 'the coordinator' if $actor eq 'coordinator';
    return 'the driver';
}

# ---------------------------------------------------------------------------
# writes-mode deny builders, sec 3.2/3.8.
# ---------------------------------------------------------------------------
sub _deny_test_modify {
    my ($R, $TPent, $REL, $worker, $actor) = @_;
    my $who = _who($R, $worker, $actor);
    my $pkg = $TPent->{P}{package};
    my $pat = $TPent->{tpat};
    my @lines = (
        sprintf("BLOCKED: %s may not modify test files (%s; matched test_paths pattern '%s') in package %s.",
            $who, $REL, $pat, $pkg),
        'Tests are the immutable oracle; if a test is wrong, report the test, why it contradicts the spec, and your evidence.',
    );
    # Package 02: returns the line list rather than printing -- may_write is
    # pure, and _writes prints on its behalf.
    return [ map { _cfit($_) } @lines ];
}

sub _deny_writer_scope {
    my ($R, $role, $REL) = @_;
    my $tp = $R->{packages}[0]{test_paths};
    $tp = defined($tp) ? $tp : '';
    my $line2 = ($role eq 'bp-test-writer')
        ? 'If implementation scaffolding is genuinely required, report it back instead of writing it.'
        : 'Prober artifacts come from test runs, not Edit/Write; report anything else that must change.';
    my @lines = (
        sprintf("BLOCKED: %s may only write under the package's test paths (%s), not %s.", $role, $tp, $REL),
        $line2,
    );
    return [ map { _cfit($_) } @lines ];
}

# _write_set_pattern_lines($ws) -> (COUNT, @LINES). Report 20260916-175013-34af:
# a corrupt write_set: field (prose or a colon-bearing annotation splices into
# extra patterns) must be surfaced pattern-by-pattern, not as one raw
# colon-joined string, or the refusal reads as a scope dispute when the real
# defect is serialization. Each returned line is ALREADY the full display
# line (indented), one per split pattern -- never re-joined -- so a corrupt
# element lands on its own line and a coordinator can see the split without
# counting colons by eye.
sub _write_set_pattern_lines {
    my ($ws) = @_;
    $ws = '' unless defined $ws;
    my @elems = length($ws) ? split(/:/, $ws, -1) : ('');
    my $n = scalar @elems;
    my @lines;
    for my $e (@elems) {
        if ($e eq '') {
            push @lines, '    (empty)';
        }
        elsif ($e =~ /\s/) {
            push @lines, qq(    "$e" <-- contains whitespace: not a path (report 20260916-175013-34af));
        }
        else {
            push @lines, "    $e";
        }
    }
    return ($n, @lines);
}

# _test_paths_display($tp) -> single display string, '(empty)' when unset or
# empty, else the raw value (test_paths is not the corruption this report is
# about; it only needs to render without dying on the empty case, AC8).
sub _test_paths_display {
    my ($tp) = @_;
    return '(empty)' unless defined $tp && length $tp;
    return $tp;
}

# _deny_write_set returns its line list (package 02) rather than printing;
# every caller is inside may_write/_writes_step7, never ledger mode.
sub _deny_write_set {
    my ($R, $REL) = @_;
    my @packages = @{ $R->{packages} };
    if (@packages == 1) {
        my $P = $packages[0];
        # Report 20260916-175013-34af's rich, self-diagnosing form (pattern-
        # per-line, the parsed count, a corrupt element citing the report, and
        # the serialization-vs-scope-dispute guidance) applies ONLY in
        # coordinator "env" mode (guard-writes.sh's BP_LEDGER/BP_WRITE_SET/
        # BP_TEST_PATHS env-var path, write-set-refusal-diagnoses-itself.t) --
        # the one path where write_set is a raw, env-serialized string that
        # can actually BE corrupted this way. The driver/subagent path
        # (guards-per-subagent.t AC-1, package 13, kind ne 'env') resolves
        # write_set from inflight.json + the ledger's own parsed field, which
        # cannot suffer this corruption, and that oracle pins the message at
        # <=3 lines -- so it keeps the original short form unconditionally.
        if (defined $R->{kind} && $R->{kind} eq 'env') {
            my ($n, @pat_lines) = _write_set_pattern_lines($P->{write_set});
            my @lines = (
                sprintf("BLOCKED: %s is outside this package's write set (package %s).", $REL, $P->{package}),
                sprintf('  write_set, as %d pattern(s) after splitting on ":":', $n),
                @pat_lines,
                sprintf('  test_paths: %s', _test_paths_display($P->{test_paths})),
                'This may be serialized wrong and the scope is already correct, rather than a real '
              . 'scope dispute.',
                'The ledger is re-read on every write: widen it with bp-ledger.pl widen-write-set '
              . '(or set-test-paths) and retry; no relaunch is needed.',
                'Record the scope problem under Next action and escalate; the orchestrator re-scopes packages.',
            );
            return [ map { _cfit($_) } @lines ];
        }
        my @lines = (
            sprintf("BLOCKED: %s is outside this package's write set (package %s).", $REL, $P->{package}),
            sprintf('  write_set: %s', (defined $P->{write_set} && length $P->{write_set}) ? $P->{write_set} : '(empty)'),
            'Record the scope problem under Next action and escalate; the orchestrator re-scopes packages.',
        );
        return [ map { _cfit($_) } @lines ];
    }
    else {
        # Decision 69 A7 (review M2): spec sec 3.2's T5, verbatim -- two
        # lines, the member list inline and capped, never the T4
        # single-package phrasing, never one line per package.
        my $n = scalar @packages;
        my $shown = $n > $MAX_LISTED ? $MAX_LISTED : $n;
        my @names = map { sprintf('%s/%s', $_->{blueprint}, $_->{package}) } @packages[0 .. $shown - 1];
        my $list = join(', ', @names);
        $list .= ', ...and ' . ($n - $MAX_LISTED) . ' more' if $n > $MAX_LISTED;
        my @lines = (
            sprintf('BLOCKED: %s is outside the write set of every package in flight: %s.', $REL, $list),
            "The driver's own edits must fall inside one in-flight package's write set.",
        );
        return [ map { _cfit($_) } @lines ];
    }
}

# ---------------------------------------------------------------------------
# writes mode -- sec 3.2.
# ---------------------------------------------------------------------------
sub _writes_step7 {
    my ($REL, $R, $classified) = @_;
    my $worker = defined($R->{worker}) ? $R->{worker} : '';
    my $actor  = defined($R->{actor})  ? $R->{actor}  : '';
    my ($TPent) = grep { $_->{kind} eq 'TEST' } @$classified;
    if (defined $TPent) {
        my $coord_no_worker = ($actor eq 'coordinator' && $worker eq '') ? 1 : 0;
        if ($worker ne 'bp-test-writer' && $worker ne 'bp-ui-prober' && !$coord_no_worker) {
            return _deny_test_modify($R, $TPent, $REL, $worker, $actor);
        }
        return 0;
    }
    if ($worker eq 'bp-test-writer') { return _deny_writer_scope($R, 'bp-test-writer', $REL) }
    if ($worker eq 'bp-ui-prober')   { return _deny_writer_scope($R, 'bp-ui-prober', $REL) }
    my ($WPent) = grep { $_->{kind} eq 'WRITE' } @$classified;
    return 0 if defined $WPent;
    return _deny_write_set($R, $REL);
}

# ---------------------------------------------------------------------------
# may_write($R, $abs, $p) -- package 02, spec sec 2.1. The pure Edit verdict:
# never prints, never calls BpHook::deny, never exits. Returns
# { allow => 1 } or { allow => 0, lines => [ ..already _cfit'd.. ] }. $R is
# resolve()'s return, unmodified; $abs is an already-canon-shaped absolute
# path (Common::resolve_path's/`_abs_of`'s form); $p is used only by
# _own_scratchpad ({} is fine, and yields no scratchpad allowance). This is
# the seam GB-h's _gb_w calls, and the only place writes-mode decision logic
# lives -- _writes below is a thin printer over it.
# ---------------------------------------------------------------------------
sub may_write {
    my ($R, $abs, $p) = @_;
    $p = {} unless ref $p eq 'HASH';
    # AC-19 (done criterion 6): the caller normally already passes an
    # _abs_of()-shaped, lexically-collapsed path, but may_write must not
    # DEPEND on that -- re-collapsing here (idempotent when it's already
    # collapsed) is what keeps a caller-supplied ".." segment judged
    # identically to Edit's own re-derived ABS, which always runs it through
    # this same resolve_path.
    my $ABS   = _cresolvepath($abs, undef);
    $ABS      = $abs unless defined $ABS;
    my $ABS_c = _ccanon($ABS);

    if (my $lines = _maybe_deny_8dot3_lines($ABS, $ABS_c, $R)) { return { allow => 0, lines => $lines } }
    if (my $lines = _sibling_ledger_deny_lines($ABS_c, $R))    { return { allow => 0, lines => $lines } }

    return { allow => 1 } if _own_scratchpad($p, $ABS_c, $R);
    return { allow => 1 } if _is_temp($ABS_c, $R->{root}, $R->{data});

    my $in_deny = 0;
    for my $d (@{ $R->{deny_dirs} || [] }) {
        if (_in($ABS_c, $d)) { $in_deny = 1; last }
    }
    unless ($in_deny) {
        for my $d (@{ $R->{allow_dirs} || [] }) {
            return { allow => 1 } if _in($ABS_c, $d);
        }
    }

    if ($R->{kind} eq 'exempt_reports') {
        # Decision 100/101 M2: an exempt-but-unbound subagent (its own,
        # session_id-matched worker record names a BindDispatch-allowlisted
        # subagent_type) may write ONLY under
        # <data>/blueprints/<any bp>/reports/ -- regardless of how many
        # packages are in flight, and never any package's write_set/
        # test_paths, even when it is the sole package in flight.
        return { allow => 1 } if _under_any_reports($ABS_c, $R->{data});
        return { allow => 0, lines => [ _cfit(
            'BLOCKED: this subagent is exempt from package binding and may write only under blueprints/<bp>/reports/.') ] };
    }
    if ($R->{kind} eq 'refused') {
        my $n = defined($R->{inflight}) ? $R->{inflight} : 0;
        return { allow => 0, lines => [ _cfit(sprintf(
            'No package binding for this subagent; with %d packages in flight its edits are refused.', $n)) ] };
    }
    if ($R->{kind} eq 'refused_bound') {
        # Decision 69 A3 (red-team H4): distinct from the generic no-binding
        # refusal above -- names the bound package, and is refused
        # regardless of how many other packages are in flight.
        my $bd  = $R->{bound} || {};
        my $bp  = defined($bd->{blueprint}) ? $bd->{blueprint} : '?';
        my $pkg = defined($bd->{package})   ? $bd->{package}   : '?';
        return { allow => 0, lines => [ _cfit(sprintf(
            'BLOCKED: this subagent is bound to package %s/%s, which is not usable now (no ledger, or a terminal/parked status); its edits are refused.',
            $bp, $pkg)) ] };
    }

    unless (_in($ABS_c, $R->{root})) {
        return { allow => 0, lines => [ _cfit(sprintf(
            'BLOCKED: %s is outside the project root (%s); writes must stay in the project, the blueprint dir or /tmp.',
            _cpathecho($ABS), _cpathecho($R->{root}))) ] };
    }
    my $root_c = _ccanon($R->{root});
    my $REL = substr($ABS_c, length($root_c) + 1);

    my @classified;
    for my $P (@{ $R->{packages} }) {
        my ($t, $tpat) = _longest($REL, $P->{test_paths});
        my ($w, $wpat) = _longest($REL, $P->{write_set});
        my $shape = _is_test_shape($REL);
        my $kind2 = 'NONE';
        if ($t >= 0 && ($t >= $w || $shape)) { $kind2 = 'TEST' }
        elsif ($w >= 0) { $kind2 = 'WRITE' }
        push @classified, { P => $P, kind => $kind2, tpat => $tpat, wpat => $wpat };
    }

    my $lines = _writes_step7($REL, $R, \@classified);
    return $lines ? { allow => 0, lines => $lines } : { allow => 1 };
}

sub _writes {
    my ($p, $R) = @_;
    my $tool = (ref $p eq 'HASH') ? $p->{tool_name} : undef;
    return 0 unless defined $tool && !ref($tool) && grep { $tool eq $_ } qw(Write Edit MultiEdit NotebookEdit);

    my ($ABS, $ABS_c) = _abs_of($p);
    return 0 unless defined $ABS;

    my $v = may_write($R, $ABS, $p);
    return 0 if $v->{allow};
    return BpHook::deny(@{ $v->{lines} });
}

# ---------------------------------------------------------------------------
# ledger mode -- sec 3.3.
# ---------------------------------------------------------------------------
sub _is_str {
    my ($v) = @_;
    return 0 unless defined $v;
    return 0 if ref $v;
    my $f = B::svref_2object(\$v)->FLAGS;
    return 0 unless $f & B::SVp_POK();
    return 0 if $f & (B::SVp_IOK() | B::SVp_NOK());
    return 1;
}

sub _as_bytes {
    my ($s) = @_;
    return '' unless defined $s;
    # Decision 69 A6 (review M1, red-team L2): the payload is always
    # character-decoded (BpHook decodes JSON with ->utf8), so this must
    # always encode to UTF-8 bytes -- never Latin-1-downgrade, which turns a
    # character like e-acute (U+00E9) into the single byte 0xE9 that never
    # occurs in the file's real UTF-8 bytes (0xC3 0xA9), silently skipping
    # every validator on any payload string containing one.
    my $v = $s;
    utf8::encode($v);
    return $v;
}

sub _read_target {
    my ($path) = @_;
    return undef if -d $path;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined($c) ? $c : '';
}

sub _best_effort_read {
    my ($path) = @_;
    return undef unless -e $path;
    return undef if -d $path;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub _count_occ {
    my ($hay, $needle) = @_;
    return 0 if $needle eq '';
    my ($n, $p) = (0, 0);
    while ((my $i = index($hay, $needle, $p)) >= 0) {
        $n++;
        $p = $i + length($needle);
    }
    return $n;
}

sub _splice_bytes {
    my ($hay, $old, $new, $all) = @_;
    my ($out, $p) = ('', 0);
    while ((my $i = index($hay, $old, $p)) >= 0) {
        $out .= substr($hay, $p, $i - $p) . $new;
        $p = $i + length($old);
        last unless $all;
    }
    return $out . substr($hay, $p);
}

sub _ledger_deny {
    my ($classtext, $abs) = @_;
    my $line = 'LEDGER-GUARD: BLOCKED ' . "\xe2\x80\x94" . ' ' . $classtext . ': ' . _cpathecho($abs);
    return BpHook::deny(_cfit($line));
}

sub _ledger_pl_path {
    return "$SELF_DIR/../bp-ledger.pl";
}

# bp-ledger.pl is `require`d directly into THIS package's own namespace
# (Perl compiles a required .pl into the calling package), with
# "Subroutine redefined" warnings silenced. Fix-batch section C: accepted
# for this package (no collision today; a future collision would silently
# redefine one of this module's own subs). Carried, not fixed here.
sub _require_ledger_pl {
    my $path = _ledger_pl_path();
    return 1 if exists $INC{$path};
    return 0 unless -e $path;
    my $ok = eval {
        local $SIG{__WARN__} = sub { };
        require $path;
        1;
    };
    return $ok ? 1 : 0;
}

sub _fm_block {
    my ($s) = @_;
    my ($fm) = $s =~ /\A---\s*\n(.*?)\n---/s;
    return $fm;
}

sub _validate {
    my ($B, $OLD, $ABS, $R) = @_;

    if ($B =~ /([\x00-\x08\x0B\x0C\x0E-\x1F\x7F])/) {
        my $off  = $-[1];
        my $byte = ord($1);
        my $pre  = substr($B, 0, $off);
        my $line = 1 + ($pre =~ tr/\n//);
        return _ledger_deny(sprintf('control byte 0x%02X at line %d; only tab, newline and CR are allowed', $byte, $line), $ABS);
    }

    my $FM = _fm_block($B);
    unless (defined $FM) {
        return _ledger_deny('no parseable frontmatter block (--- at byte 0, closed by a later ---)', $ABS);
    }
    my @FML = split /\n/, $FM, -1;

    my @KEYS = qw(package blueprint status write_set last_updated);
    my @missing;
    for my $k (@KEYS) {
        my $found = 0;
        for my $l (@FML) { if ($l =~ /^\Q$k\E:\s*(.*?)\s*$/) { $found = 1; last } }
        push @missing, $k unless $found;
    }
    if (@missing) {
        return _ledger_deny('missing required frontmatter key(s): ' . join(', ', @missing), $ABS);
    }

    my @STATUSES = qw(pending running converging reviewing done blocked parked dropped);
    my $status;
    for my $l (@FML) { if ($l =~ /^status:\s*(.*?)\s*$/) { $status = $1; last } }
    $status = '' unless defined $status;
    unless (grep { $_ eq $status } @STATUSES) {
        my $shown = substr($status, 0, 20);
        return _ledger_deny(sprintf('status "%s" is not one of %s', $shown, join(', ', @STATUSES)), $ABS);
    }

    my @sections = (
        ['## Next action',             qr/^## Next action/m],
        ['## Decisions & attempt log', qr/^##\s+Decisions & attempt log\b/m],
        ['## Pipeline',                qr/^##\s+Pipeline\b/m],
        ['## Outputs',                 qr/^##\s+Outputs\b/m],
        ['## Escalation',              qr/^##\s+Escalation\b/m],
    );
    my @gone = map { $_->[0] } grep { $B !~ $_->[1] } @sections;
    if (@gone) {
        return _ledger_deny('drops required section heading(s): ' . join(', ', @gone) . '; edit section bodies, never headings', $ABS);
    }

    if ($R->{mode} ne 'coordinator' && defined $OLD && length $OLD) {
        my $ABS_c = _ccanon($ABS);
        for my $P (@{ $R->{packages} }) {
            my $pl = _ccanon($P->{ledger});
            # Decision 69 A2: fold ASCII case so a case-alias path (e.g.
            # P1-A.md) is still recognised as the package's own ledger.
            my $match = _is_ci() ? (_foldc($pl) eq _foldc($ABS_c)) : ($pl eq $ABS_c);
            next unless $match;
            my $OFM = _fm_block($OLD);
            last unless defined $OFM;
            my @OFML = split /\n/, $OFM, -1;
            for my $k (qw(write_set test_paths)) {
                my ($ov) = map { /^\Q$k\E:\s*(.*?)\s*$/ ? $1 : () } @OFML;
                my ($nv) = map { /^\Q$k\E:\s*(.*?)\s*$/ ? $1 : () } @FML;
                $ov = '' unless defined $ov;
                $nv = '' unless defined $nv;
                if ($ov ne $nv) {
                    return _ledger_deny("changes $k of the package this session is executing; its scope is fixed while it runs", $ABS);
                }
            }
            last;
        }
    }

    unless (_require_ledger_pl() && defined &BpHook::WriteGuards::last_updated_check) {
        return _ledger_deny('the shared last_updated check (bp-ledger.pl) could not be loaded', $ABS);
    }
    # Decision 69 A8 (review minor): no inner eval here -- a die propagates
    # to run()'s outer eval, which DENIES on the coordinator path (fail
    # closed) and allows on the driver/subagent path (architecture), exactly
    # like every other exception in this module.
    my $detail = BpHook::WriteGuards::last_updated_check($OLD, $B);
    if (defined $detail) {
        $detail =~ s/\s+/ /g;
        return _ledger_deny($detail, $ABS);
    }

    return 0;
}

# Decision 69 A2 (red-team H3): a case (or 8.3) alias of a package's ledger
# path may not resolve through this host's own filesystem layer, even
# though the payload's ABS_c already identifies it (folded) as that
# package's own ledger. Read the OLD content from the CANONICAL ledger path
# in that case, rather than depend on the OS resolving the alias.
sub _old_content_for_ledger {
    my ($ABS, $ABS_c, $R) = @_;
    my $c = _best_effort_read($ABS);
    return $c if defined $c;
    return undef unless _is_ci();
    for my $P (@{ $R->{packages} }) {
        my $pl = _ccanon($P->{ledger});
        next unless _foldc($pl) eq _foldc($ABS_c);
        return _best_effort_read($P->{ledger});
    }
    return undef;
}

sub _ledger {
    my ($p, $R) = @_;

    my ($ABS, $ABS_c) = _abs_of($p);
    return 0 unless defined $ABS;

    if (my $d = _maybe_deny_8dot3($ABS, $ABS_c, $R)) { return $d }
    if (my $d = _maybe_deny_sibling_ledger($ABS, $ABS_c, $R)) { return $d }

    my $ci = _is_ci();
    my $in_scope = 0;
    for my $P (@{ $R->{packages} }) {
        my $pref = _ccanon($P->{bpdir} . '/packages') . '/';
        my ($a, $b) = $ci ? (_foldc($ABS_c), _foldc($pref)) : ($ABS_c, $pref);
        my $ext_ok = $ci ? ($ABS_c =~ /\.md\z/i) : ($ABS_c =~ /\.md\z/);
        if (index($a, $b) == 0 && $ext_ok) { $in_scope = 1; last }
    }
    return 0 unless $in_scope;

    my $tool = (ref $p eq 'HASH') ? $p->{tool_name} : undef;
    $tool = '' unless defined $tool && !ref($tool);

    if ($tool eq 'NotebookEdit') {
        return _ledger_deny('NotebookEdit cannot target a package ledger; use Edit or Write', $ABS);
    }
    unless ($tool eq 'Write' || $tool eq 'Edit' || $tool eq 'MultiEdit') {
        my $reason = length($tool) ? qq(unrecognised tool "$tool") : 'payload has no tool_name';
        return _ledger_deny("cannot reconstruct the content this write would leave ($reason)", $ABS);
    }

    my $ti = (ref $p->{tool_input} eq 'HASH') ? $p->{tool_input} : {};
    my ($B, $OLD);

    if ($tool eq 'Write') {
        my $c = $ti->{content};
        unless (_is_str($c)) {
            return _ledger_deny('cannot reconstruct the content this write would leave (Write payload has no string "content" field)', $ABS);
        }
        $OLD = _old_content_for_ledger($ABS, $ABS_c, $R);
        $B = _as_bytes($c);
    }
    elsif ($tool eq 'Edit') {
        return 0 unless -e $ABS;
        my $orig = _read_target($ABS);
        return _ledger_deny('cannot read the current content, so this Edit cannot be validated', $ABS) unless defined $orig;
        my ($old, $new) = ($ti->{old_string}, $ti->{new_string});
        unless (_is_str($old) && _is_str($new)) {
            return _ledger_deny('cannot reconstruct the content this Edit would leave (Edit payload has no string old_string/new_string)', $ABS);
        }
        $old = _as_bytes($old);
        $new = _as_bytes($new);
        if ($old eq '') {
            return _ledger_deny('cannot reconstruct the content this Edit would leave (empty old_string)', $ABS);
        }
        my $all = $ti->{replace_all} ? 1 : 0;
        my $n = _count_occ($orig, $old);
        return 0 if $n == 0;
        return 0 if $n > 1 && !$all;
        $B = _splice_bytes($orig, $old, $new, $all);
        $OLD = $orig;
    }
    elsif ($tool eq 'MultiEdit') {
        my $edits = $ti->{edits};
        my $bad = (ref($edits) eq 'ARRAY' && @$edits) ? 0 : 1;
        unless ($bad) {
            for my $e (@$edits) {
                unless (ref($e) eq 'HASH' && _is_str($e->{old_string}) && _is_str($e->{new_string})) { $bad = 1; last }
            }
        }
        if ($bad) {
            return _ledger_deny('cannot reconstruct the content this MultiEdit would leave ("edits" is missing or is not a non-empty array of {old_string,new_string} objects)', $ABS);
        }
        return 0 unless -e $ABS;
        my $orig = _read_target($ABS);
        return _ledger_deny('cannot read the current content, so this MultiEdit cannot be validated', $ABS) unless defined $orig;
        my $buf = $orig;
        for my $e (@$edits) {
            my $old = _as_bytes($e->{old_string});
            my $new = _as_bytes($e->{new_string});
            if ($old eq '') {
                return _ledger_deny('cannot reconstruct the content this MultiEdit would leave (empty old_string)', $ABS);
            }
            my $all = $e->{replace_all} ? 1 : 0;
            my $n = _count_occ($buf, $old);
            return 0 if $n == 0;
            return 0 if $n > 1 && !$all;
            $buf = _splice_bytes($buf, $old, $new, $all);
        }
        $B = $buf;
        $OLD = $orig;
    }

    return _validate($B, $OLD, $ABS, $R);
}

# ---------------------------------------------------------------------------
# run($p, $mode, @rest) -> 0 | 2.
# ---------------------------------------------------------------------------
sub _run_inner {
    my ($p, $mode, $is_coordinator) = @_;
    return 0 unless defined $mode && ($mode eq 'writes' || $mode eq 'ledger');
    if (ref $p eq 'HASH' && exists $p->{hook_event_name}) {
        my $ev = $p->{hook_event_name};
        return 0 unless defined $ev && !ref($ev) && $ev eq 'PreToolUse';
    }
    my $payload_ok = eval { BpHook::payload_ok() } ? 1 : 0;
    unless ($payload_ok) {
        if ($is_coordinator) {
            if ($mode eq 'ledger') {
                return BpHook::deny('LEDGER-GUARD: BLOCKED ' . "\xe2\x80\x94" . ' the payload could not be read, so this ledger write cannot be validated.');
            }
            return BpHook::deny("BLOCKED: guard-writes cannot read this tool call's payload, so the write cannot be checked.");
        }
        return 0;
    }
    my $R = resolve($p);
    return 0 unless defined $R;
    return ($mode eq 'writes') ? _writes($p, $R) : _ledger($p, $R);
}

sub run {
    my ($p, $mode, @rest) = @_;
    my $is_coordinator = (defined $ENV{BP_LEDGER} && length $ENV{BP_LEDGER}) ? 1 : 0;
    my $result = eval { _run_inner($p, $mode, $is_coordinator) };
    if (!defined $result) {
        if ($is_coordinator) {
            my $err = defined($@) ? $@ : 'unknown error';
            $err =~ s/[\r\n].*//s;
            $err = substr($err, 0, 60);
            if (defined($mode) && $mode eq 'ledger') {
                return BpHook::deny(_cfit('LEDGER-GUARD: BLOCKED ' . "\xe2\x80\x94" . " the ledger guard failed internally ($err) and cannot certify this write."));
            }
            return BpHook::deny(_cfit("BLOCKED: guard-writes failed internally ($err) and cannot check this write."));
        }
        return 0;
    }
    return ($result == 2) ? 2 : 0;
}

1;
