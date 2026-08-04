#!/usr/bin/env perl
# bp-validate-dag.pl -- deterministic blueprint-DAG validator.
#
# Reuses butler's REAL BpOrch::parse_dag (bp-orchestrator.pl) -- never
# reimplements it. validate() is strictly READ-ONLY: it never writes,
# renames or touches blueprint.md or any packages/*.md. Fixes are RETURNED
# (fixed_dag + normalized records), never written to the author's file.
#
# See specs/b08-dag-integrity-and-deadlock-spec.md sec2.8-2.12 for the
# contract this file implements, and t/60-dag-integrity.t for the oracle.

use strict;
use warnings;

package BpValidateDag;

use File::Basename qw(dirname);
use Cwd ();

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });

# b08 step-7 FIX 1 (reviewer, should-fix): this require used to be bare, while
# every other risky call in this file is eval-wrapped. It runs inside the
# DISPATCH PREFLIGHT, so a future compile break in that shared ~3300-line file
# would crash the validator at load time and block ALL fleet dispatch — exactly
# the failure class this package exists to prevent. It is inert today only
# because bp-orchestrator.pl's sole top-level side effect is guarded by
# `unless (caller)`, which is a property of that file, not a guarantee to this
# one. Degrade into a well-formed structural finding instead: validate() must
# never die (spec §2.12, AC-17).
our $ORCH_LOAD_ERROR;
unless (eval { require "$DIR/bp-orchestrator.pl"; 1 }) {   # the REAL parser. Never reimplement it.
    $ORCH_LOAD_ERROR = $@ || $! || 'unknown error';
}

# ---------------------------------------------------------------------------
# BpOrch:: additions -- resolve_dep_token / normalize_dag / find_cycles.
#
# These belong (per the spec's ownership table) to BpOrch/bp-orchestrator.pl,
# but THIS package (Part 1 of 3) is scoped to never touch bp-orchestrator.pl
# -- a later package wires them into the runtime (_load_state/deps_met/
# dag_stall). Defining them here, in the BpOrch namespace, from this file
# gives the validator (and anything that requires this file, e.g. the AC-10
# oracle assertions on BpOrch::find_cycles) a single real implementation to
# consume without editing the orchestrator file. Guarded so a later part
# that DOES add real definitions to bp-orchestrator.pl wins without a
# clash: this file loads bp-orchestrator.pl first, so if it already defines
# these, we leave them alone.
# ---------------------------------------------------------------------------
package BpOrch;

unless (defined &BpOrch::_dag_resolve_full) {
    # Resolve ONE raw depends_on token against a full-package-name key space.
    # Returns ($how, $name, \@candidates).
    #   ('exact',      $tok,  [$tok])   -- token is already a full name
    #   ('normalized', $name, [...])    -- exactly one match after canon.
    #   ('ambiguous',  undef, [...])    -- 2+ matches; NEVER pick one
    #   ('none',       undef, [])       -- no match
    *BpOrch::_dag_resolve_full = sub {
        my ($tok, $names) = @_;
        my $t = defined $tok ? $tok : '';
        $t =~ s/^\s+//; $t =~ s/\s+$//;
        return ('none', undef, []) if $t eq '';
        return ('exact', $t, [$t]) if exists $names->{$t};
        my $lt = lc $t;
        my @ci = sort grep { lc($_) eq $lt } keys %$names;
        return ('normalized', $ci[0], \@ci) if @ci == 1;
        return ('ambiguous', undef, \@ci) if @ci > 1;
        my $pfx = $lt . '-';
        my @pf = sort grep { index(lc($_), $pfx) == 0 } keys %$names;
        return ('normalized', $pf[0], \@pf) if @pf == 1;
        return ('ambiguous', undef, \@pf) if @pf > 1;
        return ('none', undef, []);
    };
}

unless (defined &BpOrch::resolve_dep_token) {
    *BpOrch::resolve_dep_token = sub {
        my ($tok, $names) = @_;
        my ($how, $name, undef) = BpOrch::_dag_resolve_full($tok, $names);
        return ($how, $name);
    };
}

unless (defined &BpOrch::normalize_dag) {
    *BpOrch::normalize_dag = sub {
        my ($dag) = @_;
        my %out;
        for my $pkg (sort keys %$dag) {
            my @kept;
            my %seen;
            for my $tok (@{ $dag->{$pkg} || [] }) {
                my ($how, $name) = BpOrch::resolve_dep_token($tok, $dag);
                my $canon = ($how eq 'exact' || $how eq 'normalized') ? $name : $tok;
                next if $canon eq $pkg;      # self-dep is meaningless
                next if $seen{$canon}++;     # dedupe
                push @kept, $canon;
            }
            $out{$pkg} = \@kept;
        }
        return \%out;
    };
}

unless (defined &BpOrch::find_cycles) {
    *BpOrch::find_cycles = sub {
        my ($dag) = @_;
        my %color;   # pkg => 0 white | 1 grey | 2 black
        my @cycles;
        my %seen_key;
        my $visit;
        $visit = sub {
            my ($node, $path) = @_;
            $color{$node} = 1;
            push @$path, $node;
            for my $d (sort @{ $dag->{$node} || [] }) {
                next unless exists $dag->{$d};
                my $c = $color{$d} // 0;
                if ($c == 1) {
                    my @p = @$path;
                    my $idx;
                    for my $i (0 .. $#p) { if ($p[$i] eq $d) { $idx = $i; last } }
                    next unless defined $idx;
                    my @cyc = @p[$idx .. $#p];
                    my $min_i = 0;
                    for my $i (1 .. $#cyc) { $min_i = $i if $cyc[$i] lt $cyc[$min_i]; }
                    @cyc = (@cyc[$min_i .. $#cyc], @cyc[0 .. $min_i - 1]);
                    my $key = join("\0", @cyc);
                    push @cycles, \@cyc unless $seen_key{$key}++;
                } elsif ($c == 0) {
                    $visit->($d, $path);
                }
            }
            pop @$path;
            $color{$node} = 2;
        };
        for my $pkg (sort keys %$dag) {
            next if ($color{$pkg} // 0) != 0;
            $visit->($pkg, []);
        }
        return @cycles;
    };
}

# ---------------------------------------------------------------------------
package BpValidateDag;

my $PKG_ID_RE = qr/^[A-Za-z0-9][A-Za-z0-9_.-]*$/;

sub _slurp {
    my ($f) = @_;
    open my $fh, '<:raw', $f or return undef;
    local $/;
    my $r = <$fh>;
    close $fh;
    return $r;
}

sub _trim_collapse {
    my ($s) = @_;
    $s = defined $s ? $s : '';
    $s =~ s/^\s+//; $s =~ s/\s+$//;
    $s =~ s/\s+/ /g;
    return $s;
}

sub ledger_packages {
    my ($bpdir) = @_;
    my $dir = "$bpdir/packages";
    return () unless -d $dir;
    opendir(my $dh, $dir) or return ();
    my @files = grep { /\.md$/ && -f "$dir/$_" } readdir($dh);
    closedir $dh;
    my @ids = map { my $x = $_; $x =~ s/\.md$//; $x } @files;
    return sort @ids;
}

sub has_unfinished {
    my ($bpdir) = @_;
    for my $id (ledger_packages($bpdir)) {
        my $st = BpOrch::ledger_fm($bpdir, $id, 'status');
        $st = defined $st ? $st : '';
        return 1 unless $st =~ /^(?:done|dropped)$/;
    }
    return 0;
}

sub _summary {
    my ($r) = @_;
    return sprintf(
        '%d package(s), %d finding(s) (%d ambiguous, %d structural), %d auto-normalized',
        scalar(@{ $r->{packages} }), scalar(@{ $r->{findings} }),
        scalar(@{ $r->{ambiguous} }), scalar(@{ $r->{structural} }),
        scalar(@{ $r->{normalized} }),
    );
}

sub validate {
    my ($bpdir) = @_;
    $bpdir = defined $bpdir ? $bpdir : '';

    my @ledgers = eval { ledger_packages($bpdir) };
    @ledgers = () unless ref \@ledgers eq 'ARRAY';

    my $result = {
        ok         => 0,
        bpdir      => $bpdir,
        packages   => [],
        ledgers    => [ @ledgers ],
        dag        => {},
        fixed_dag  => {},
        normalized => [],
        ambiguous  => [],
        structural => [],
        findings   => [],
        summary    => '',
    };

    # b08 step-7 FIX 1: if the shared parser failed to load, report it as a
    # structural finding rather than having died at require time. Checked before
    # any BpOrch:: call, since every one of them would be undefined.
    if (defined $ORCH_LOAD_ERROR) {
        push @{ $result->{structural} }, {
            code     => 'orchestrator-unloadable',
            severity => 'structural',
            package  => undef,
            detail   => "$DIR/bp-orchestrator.pl",
            members  => [],
            message  => "bp-orchestrator.pl could not be loaded, so the DAG cannot be parsed: $ORCH_LOAD_ERROR",
        };
        $result->{findings} = [ @{ $result->{structural} } ];
        $result->{summary}  = _summary($result);
        return $result;
    }

    my $bp_file = "$bpdir/blueprint.md";
    my $md = _slurp($bp_file);
    if (!defined $md) {
        push @{ $result->{structural} }, {
            code     => 'blueprint-missing',
            severity => 'structural',
            package  => undef,
            detail   => $bp_file,
            members  => [],
            message  => "blueprint.md not found or unreadable at $bp_file",
        };
        $result->{findings} = [ @{ $result->{structural} } ];
        $result->{summary}  = _summary($result);
        return $result;
    }

    my $dag = eval { BpOrch::parse_dag($md) } || {};
    $result->{dag}      = $dag;
    $result->{packages} = [ sort keys %$dag ];

    my @lines = split /\n/, $md;
    my %dagset    = map { ($_ => 1) } keys %$dag;
    my %ledgerset = map { ($_ => 1) } @ledgers;

    my @structural;
    my @ambiguous;
    my @normalized;

    # --- cross-set diffs (C3) ------------------------------------------------
    my @pnit = sort grep { !$dagset{$_} } @ledgers;      # pkg-not-in-table
    my @pnod = sort grep { !$ledgerset{$_} } keys %$dag; # pkg-not-on-disk

    for my $id (@pnit) {
        push @structural, {
            code => 'pkg-not-in-table', severity => 'structural', package => $id,
            detail => $id, members => [],
            message => "$id: has a ledger but no table row -- invisible to the orchestrator",
        };
    }
    for my $id (@pnod) {
        push @structural, {
            code => 'pkg-not-on-disk', severity => 'structural', package => $id,
            detail => $id, members => [],
            message => "$id: has a table row but no packages/$id.md ledger on disk",
        };
    }

    # --- table-missing ---------------------------------------------------
    my $table_missing = 0;
    if (!%$dag && @ledgers) {
        $table_missing = 1;
        push @structural, {
            code => 'table-missing', severity => 'structural', package => undef,
            detail => undef, members => [],
            message => "blueprint.md has no package-status table (no depends_on column found), "
                      . 'though ' . scalar(@ledgers) . ' ledger(s) exist',
        };
    }

    # --- locate the table (parse_dag's own latch/terminator) -------------
    my @hijack_idx = grep { $lines[$_] =~ /^\s*\|/ && $lines[$_] =~ /depends_on/ } (0 .. $#lines);
    my $h = @hijack_idx ? $hijack_idx[0] : undef;
    my $hdr = defined $h ? [ BpOrch::_table_cols($lines[$h]) ] : undef;
    my $e;
    if (defined $h) {
        $e = scalar(@lines);
        for my $i ($h + 1 .. $#lines) {
            if ($lines[$i] !~ /^\s*\|/) { $e = $i; last }
        }
    }

    # --- header-hijack -----------------------------------------------------
    if (@hijack_idx >= 2 && (@pnit || $table_missing)) {
        my $detail = _trim_collapse($lines[$hijack_idx[0]]);
        push @structural, {
            code => 'header-hijack', severity => 'structural', package => undef,
            detail => $detail, members => [],
            message => sprintf(
                'a depends_on-bearing table at line %d precedes the real package-status table at line %d',
                $hijack_idx[0] + 1, $hijack_idx[1] + 1,
            ),
        };
    }

    # --- table-split ---------------------------------------------------
    if (defined $h && defined $e && $e <= $#lines) {
        my @dropped;
        for my $i ($e .. $#lines) {
            my $ln = $lines[$i];
            next unless $ln =~ /^\s*\|/;
            next if $ln =~ /^\s*\|[\s:|-]+\|?\s*$/;   # separator row
            my ($id) = BpOrch::_table_cols($ln);
            next unless defined $id && $id =~ $PKG_ID_RE;
            next unless $ledgerset{$id};
            next if $dagset{$id};
            push @dropped, $id;
        }
        if (@dropped) {
            my %u = map { ($_ => 1) } @dropped;
            my @members = sort keys %u;
            push @structural, {
                code => 'table-split', severity => 'structural', package => undef,
                detail => _trim_collapse($lines[$e]), members => [ @members ],
                message => sprintf(
                    'the package-status table is interrupted at line %d, dropping: %s',
                    $e + 1, join(', ', @members),
                ),
            };
        }
    }

    # --- cell-pipe -----------------------------------------------------
    if (defined $h && defined $e && $hdr && $e > $h + 1) {
        for my $i ($h + 1 .. $e - 1) {
            my $ln = $lines[$i];
            next if $ln =~ /^\s*\|[\s:|-]+\|?\s*$/;    # separator row
            my @c = BpOrch::_table_cols($ln);
            my $col_mismatch = (scalar(@c) != scalar(@$hdr));
            my $escaped_pipe = ($ln =~ /\\\|/);
            next unless $col_mismatch || $escaped_pipe;
            my $pkg = (defined $c[0] && $c[0] =~ $PKG_ID_RE) ? $c[0] : undef;
            push @structural, {
                code => 'cell-pipe', severity => 'structural', package => $pkg,
                detail => _trim_collapse($ln), members => [],
                message => sprintf(
                    'line %d: expected %d columns, got %d columns%s',
                    $i + 1, scalar(@$hdr), scalar(@c),
                    $escaped_pipe ? ' (escaped pipe splits the row regardless of the backslash)' : '',
                ),
            };
        }
    }

    # --- write-set-empty -------------------------------------------------
    for my $pkg (sort keys %$dag) {
        next unless -f "$bpdir/packages/$pkg.md";
        my $ws = BpOrch::ledger_fm($bpdir, $pkg, 'write_set');
        if (!defined($ws) || $ws =~ /^\s*$/) {
            push @structural, {
                code => 'write-set-empty', severity => 'structural', package => $pkg,
                detail => $pkg, members => [],
                message => "$pkg: write_set is empty or absent -- write-set serialization requires a non-empty write_set",
            };
        }
    }

    # --- dependency-token normalization / ambiguity -----------------------
    my %fixed_dag;
    for my $pkg (sort keys %$dag) {
        my @fixed_list;
        my %seen;
        for my $tok (@{ $dag->{$pkg} || [] }) {
            my ($how, $name, $cands) = BpOrch::_dag_resolve_full($tok, $dag);
            my $canon = ($how eq 'exact' || $how eq 'normalized') ? $name : $tok;

            if ($how eq 'normalized') {
                if (lc($tok) ne lc($canon)) {
                    push @normalized, {
                        code => 'dep-short-id', package => $pkg, from => $tok, to => $canon,
                        message => "$pkg: dependency token '$tok' resolved to full package name '$canon'",
                    };
                } else {
                    push @normalized, {
                        code => 'dep-case', package => $pkg, from => $tok, to => $canon,
                        message => "$pkg: dependency token '$tok' differs only in case from '$canon'",
                    };
                }
            }

            if ($canon eq $pkg) {
                push @normalized, {
                    code => 'dep-self', package => $pkg, from => $tok, to => undef,
                    message => "$pkg: depends on itself ('$tok'); self-dep dropped",
                };
                next;
            }

            if ($seen{$canon}++) {
                push @normalized, {
                    code => 'dep-duplicate', package => $pkg, from => $tok, to => undef,
                    message => "$pkg: dependency '$canon' already present; duplicate token '$tok' dropped",
                };
            } else {
                push @fixed_list, $canon;
            }

            if ($how eq 'ambiguous') {
                push @ambiguous, {
                    code => 'dep-ambiguous', severity => 'ambiguous', package => $pkg,
                    detail => $tok, members => [],
                    message => "$pkg: dependency token '$tok' is ambiguous among candidates: "
                              . join(', ', @$cands),
                };
            } elsif ($how eq 'none') {
                push @ambiguous, {
                    code => 'dep-dangling', severity => 'ambiguous', package => $pkg,
                    detail => $tok, members => [],
                    message => "$pkg: dependency token '$tok' names no package",
                };
            }
        }
        $fixed_dag{$pkg} = \@fixed_list;
    }
    $result->{fixed_dag} = \%fixed_dag;

    # --- cycles --------------------------------------------------------
    my @cycles = eval { BpOrch::find_cycles(\%fixed_dag) };
    for my $cyc (@cycles) {
        push @ambiguous, {
            code => 'dep-cycle', severity => 'ambiguous', package => $cyc->[0],
            detail => undef, members => [ @$cyc ],
            message => 'dependency cycle: ' . join(' -> ', @$cyc),
        };
    }

    $result->{normalized} = \@normalized;
    $result->{ambiguous}  = \@ambiguous;
    $result->{structural} = \@structural;
    $result->{findings}   = [ @ambiguous, @structural ];
    $result->{ok}         = (@ambiguous == 0 && @structural == 0) ? 1 : 0;
    $result->{summary}    = _summary($result);

    return $result;
}

sub report_text {
    my ($r) = @_;
    return "validate(): no result\n" unless ref $r eq 'HASH';
    my @out;
    push @out, $r->{summary};
    for my $f (@{ $r->{findings} || [] }) {
        my $pkg = defined $f->{package} ? $f->{package} : '-';
        my $sev = defined $f->{severity} ? $f->{severity} : '-';
        push @out, sprintf('[%s] %-16s %-24s %s', $sev, $f->{code} // '-', $pkg, $f->{message} // '');
    }
    return join("\n", @out) . "\n";
}

# One line (report rows are one line each). Exact format per spec-b08 sec4.4:
#   blueprint DAG is broken at <bpdir>: <A> ambiguous, <S> structural
#     -- [<code>] <message>; [<code>] <message>; ... -- fix blueprint.md /
#     packages/ then re-run dispatch-fleet
# At most the first 5 findings are inlined; beyond that, a "+K more" tail
# names this script for the full report. Whitespace in every embedded
# message is collapsed to single spaces. Stable contract callers (b08
# preflight gate) may match on: the literal prefix "blueprint DAG is broken
# at " and the bracketed code form "[<code>]".
sub fail_detail {
    my ($r) = @_;
    return 'dag integrity: unavailable' unless ref $r eq 'HASH';
    return 'dag integrity: ok' if $r->{ok};
    my @findings = @{ $r->{findings} || [] };
    my $a = scalar @{ $r->{ambiguous} || [] };
    my $s = scalar @{ $r->{structural} || [] };
    my @head = @findings[0 .. ($#findings > 4 ? 4 : $#findings)];
    my @parts = map {
        my $msg = defined $_->{message} ? $_->{message} : '';
        $msg =~ s/\s+/ /g;
        $msg =~ s/^ | $//g;
        "[" . ($_->{code} // '?') . "] $msg";
    } @head;
    my $tail = @findings > 5
        ? sprintf(' (+%d more; run: perl plugins/butler/scripts/bp-validate-dag.pl %s)',
                  @findings - 5, $r->{bpdir})
        : '';
    return "blueprint DAG is broken at $r->{bpdir}: $a ambiguous, $s structural"
         . ' — ' . join('; ', @parts) . $tail
         . ' — fix blueprint.md / packages/ then re-run dispatch-fleet';
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
unless (caller) {
    my $quiet = 0;
    my @pos;
    for my $a (@ARGV) {
        if ($a eq '--quiet') { $quiet = 1 }
        else { push @pos, $a }
    }
    my $bpdir = shift @pos;
    if (!defined $bpdir || $bpdir eq '') {
        print STDERR "usage: bp-validate-dag.pl <blueprint-dir> [--quiet]\n";
        exit 2;
    }
    my $r = validate($bpdir);
    if ($r->{ok}) {
        print report_text($r) unless $quiet;
        exit 0;
    } else {
        print report_text($r);
        exit 1;
    }
}

1;
