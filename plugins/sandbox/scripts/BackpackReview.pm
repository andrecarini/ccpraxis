package BackpackReview;
# Interactive per-item backpack approval walk (#21) — I/O-seam-injected so the
# decision dispatch is unit-testable, mirroring how Dashboard.pm/BackpackApproval.pm
# keep their logic out of the launcher's untestable top-level.
#
# A backpack's install/verify commands run AS ROOT inside the sandbox container,
# so the user approves each item ONCE; decisions are remembered by content-hash
# (BackpackApproval.pm), so an unchanged, already-approved item is NEVER
# re-prompted — only NEW or CHANGED items are walked. The pure
# identity/hash/partition/store logic lives in BackpackApproval.pm; this owns the
# presentation + the approve / remove / quit-defer dispatch, and returns the
# approved install subset (in backpack-file order) plus the count left undecided.
#
# review(%args) -> (\@approved_items, $deferred_count)
#   file         backpack.json path (parsed for items; the `remove` cb mutates it)
#   approvals    approvals-store path (BackpackApproval::load / save)
#   legacy_trust optional path to the legacy whole-file trust-hash (one-time
#                migrated: if it still matches file_hash, seed-approve every
#                current item — the user already approved this exact content —
#                then unlink it; a mismatch just unlinks it)
#   file_hash    md5 of `file` (for the legacy-trust match)
#   in           input  filehandle (default \*STDIN)
#   out          output filehandle (default \*STDOUT)
#   use_color    truthy -> ANSI SGR on `out`
#   remove       coderef->($item) returning a system()-style rc (0 = removed).
#                Default: runs `$^X $pl remove $file --category C --name N`.
#   pl           backpack.pl path (only used by the default `remove`)
#   tx           optional coderef->($text): plain-text transcript sink (no color)
use strict;
use warnings;
use BackpackApproval ();
use JSON::PP ();

sub _sgr { my ($on, $code, $s) = @_; $on ? "\e[${code}m$s\e[0m" : $s }

# _safe($field) — strip C0 control chars (incl. ESC 0x1b, BS, CR, LF, VT, FF) and
# DEL from any attacker-controlled backpack field BEFORE it reaches the terminal
# or the transcript. Without this, a hostile install/verify/rationale/name could
# embed cursor-movement / line-clear sequences to forge a benign-looking command
# (and approval prompt) while the user actually approves the real, malicious one
# — a command-spoofing bypass of this AS-ROOT install gate (#21 red-team HIGH).
# Tab (0x09) is kept; high-bit / UTF-8 bytes pass through untouched. The launcher
# also rejects these chars at `backpack.pl validate` time (defense in depth), but
# this module must self-defend since it parses the file independently.
sub _safe {
    my $s = shift;
    return '' unless defined $s;
    $s =~ s/[\x00-\x08\x0a-\x1f\x7f]/?/g;   # all C0 except \t, plus DEL
    return $s;
}

# ---------------------------------------------------------------------------
# plan(%args) -> \%plan — the MODEL half of review(): parse + load +
# legacy-trust migration + prune + partition, and nothing else. No console,
# no prompting, no save. The code moved here out of review(); the behaviour
# did not.
#
#   %args: file, approvals, legacy_trust, file_hash
#   \%plan = { items, ok, pending, approvals, migrated, broken, error }
#
# BROKEN IS NOT EMPTY. An unreadable or unparseable backpack sets broken => 1
# with a non-empty error and leaves items/pending empty, so a caller (and a
# screen) can tell "nothing to review" apart from "the file cannot be read".
# Collapsing the two is how an unreadable approval gate silently becomes a
# clean one.
#
# Each surviving item is stamped with `_approval_key`, the exact
# BackpackApproval::item_key byte string, so a screen can carry item identity
# without recomputing it (and without decoding on one side and encoding on
# the other). The stamp is INTERNAL: every item this module hands back to a
# caller is a copy with the stamp removed, so it never rides into the
# install-set file.
# ---------------------------------------------------------------------------
sub plan {
    my %a = @_;

    my $raw = _slurp($a{file});
    my $bp  = eval { JSON::PP->new->decode(defined $raw ? $raw : '') };
    unless (ref $bp eq 'HASH' && ref $bp->{items} eq 'ARRAY') {
        my $why = !defined $raw ? 'backpack file is missing or unreadable'
                :                 'backpack file could not be parsed';
        return { items => [], ok => [], pending => [], approvals => {},
                 migrated => 0, broken => 1, error => $why };
    }

    my @items = grep { ref $_ eq 'HASH' && defined $_->{category} && defined $_->{name} }
                @{ $bp->{items} };
    # The per-item 'version' was removed from the schema; drop a stray one so it
    # never rides into the install-set (mirrors backpack.pl's read-side strip).
    delete $_->{version} for @items;
    $_->{_approval_key} = BackpackApproval::item_key($_) for @items;

    my $appr = BackpackApproval::load($a{approvals});

    # One-time migration off the legacy whole-file trust hash.
    my $migrated = 0;
    if (defined $a{legacy_trust} && -f $a{legacy_trust}) {
        my $th = _slurp($a{legacy_trust});
        $th =~ s/\s+$// if defined $th;
        if (defined $th && length $th && defined $a{file_hash} && $th eq $a{file_hash}) {
            BackpackApproval::approve($_, $appr) for @items;
            $migrated = 1;
        }
        unlink $a{legacy_trust};
    }

    BackpackApproval::prune($appr, \@items);
    my ($ok, $pending) = BackpackApproval::partition(\@items, $appr);

    return { items => \@items, ok => $ok, pending => $pending, approvals => $appr,
             migrated => $migrated, broken => 0, error => undef };
}

# _unstamped(\@items) -> shallow copies without the internal identity stamp.
sub _unstamped {
    my ($items) = @_;
    return [ map { my %c = %$_; delete $c{_approval_key}; \%c } @{ $items || [] } ];
}

# ---------------------------------------------------------------------------
# commit(%args) -> (\@approved, $deferred) — the PERSIST half of review().
#
#   %args: plan, approvals (path), decisions { item_key => approve|remove|defer },
#          decisions_by_index { <pending index> => approve|remove|defer } —
#                   the SAME answer keyed by POSITION rather than by name, and
#                   it wins wherever both are present. item_key() joins
#                   category and name with ':', so two genuinely distinct
#                   items can collide on one key ({npm-global, "a:b"} and
#                   {"npm-global:a", b}); a name-keyed map then applies one
#                   row's decision to the other, which for 'remove' means a
#                   confirmed, non-undoable deletion landing on the wrong
#                   item. A pending position cannot collide. The name-keyed
#                   map stays for review()'s own use and for existing callers.
#          remove   coderef->(\%item) -> a system()-style rc (0 = removed),
#          on_error coderef->($detail) for a failed save,
#          applied  optional { item_key => 1 } — keys the CALLER already
#                   applied itself. review()'s prompt loop must act on each
#                   answer the moment it is given (it reports the outcome of
#                   every remove inline), so it decides as it walks and then
#                   asks commit only to save and to compute the return value.
#                   An applied key is never re-applied — re-running a remove
#                   would spawn a second, real deletion.
#
# A FAILED remove leaves the item in place AND still pending — it is neither
# forgotten nor approved. That is today's behaviour and it is the safe one:
# reporting success for a destructive action that removed nothing is the
# failure mode this arm exists to avoid.
# ---------------------------------------------------------------------------
sub commit {
    my %a = @_;
    my $plan      = ref $a{plan} eq 'HASH' ? $a{plan} : {};
    my $appr      = ref $plan->{approvals} eq 'HASH' ? $plan->{approvals} : {};
    my $items     = ref $plan->{items}   eq 'ARRAY' ? $plan->{items}   : [];
    my $pending   = ref $plan->{pending} eq 'ARRAY' ? $plan->{pending} : [];
    my $decisions = ref $a{decisions} eq 'HASH' ? $a{decisions} : {};
    my $by_index  = ref $a{decisions_by_index} eq 'HASH' ? $a{decisions_by_index} : {};
    my $remove    = ref $a{remove}   eq 'CODE' ? $a{remove}   : sub { 1 };
    my $on_error  = ref $a{on_error} eq 'CODE' ? $a{on_error} : sub { };

    # Decided-ness is tracked BY POSITION. Two pending entries that share one
    # item_key are still two entries: marking one decided must not silently
    # mark the other, or a duplicate key turns into a wrong deferred count and
    # a skipped decision. `applied` arrives keyed by name (review()'s walk owns
    # that map), so it is projected onto positions here.
    my $applied = ref $a{applied} eq 'HASH' ? $a{applied} : {};
    my @decided;
    for my $i (0 .. $#$pending) {
        $decided[$i] = $applied->{ BackpackApproval::item_key($pending->[$i]) } ? 1 : 0;
    }

    for my $i (0 .. $#$pending) {
        my $it  = $pending->[$i];
        next if $decided[$i];
        my $key = BackpackApproval::item_key($it);
        my $d   = defined $by_index->{$i}    ? $by_index->{$i}
                : defined $decisions->{$key} ? $decisions->{$key}
                :                              'defer';
        if ($d eq 'approve') {
            BackpackApproval::approve($it, $appr);
            $decided[$i] = 1;
        }
        elsif ($d eq 'remove') {
            my $rc = $remove->($it);
            if (defined $rc && $rc == 0) {
                BackpackApproval::forget($it, $appr);
                $decided[$i] = 1;
            }
        }
    }

    {
        my %e;
        BackpackApproval::save($a{approvals}, $appr, \%e)
            or $on_error->($e{message} // $e{errno} // 'no detail');
    }

    my @approved = grep { BackpackApproval::is_approved($_, $appr) } @$items;
    my $deferred = scalar grep { !$decided[$_] } (0 .. $#$pending);
    return (_unstamped(\@approved), $deferred);
}

sub review {
    my %a = @_;
    my $file       = $a{file};
    my $approvals  = $a{approvals};
    my $in         = $a{in}  || \*STDIN;
    my $out        = $a{out} || \*STDOUT;
    my $col        = $a{use_color} ? 1 : 0;
    my $tx         = $a{tx}  || sub {};
    my $remove     = $a{remove} || sub {
        my ($it) = @_;
        return system($^X, $a{pl}, 'remove', $file,
            '--category', $it->{category}, '--name', $it->{name});
    };

    # Flush each prompt before its matching read (the out handle may be buffered).
    { my $o = select($out); $| = 1; select($o); }
    my $C = sub { _sgr($col, @_) };
    my $p = sub { print {$out} @_ };

    my $plan = plan(%a);
    if ($plan->{broken}) {
        # Validated upstream; belt-and-suspenders only.
        $p->("WARNING: could not parse backpack for review — skipping install.\n");
        return ([], 0);
    }
    my @items    = @{ $plan->{items} };
    my $appr     = $plan->{approvals};
    my $migrated = $plan->{migrated};
    my ($ok, $pending) = ($plan->{ok}, $plan->{pending});
    my $save_error = sub { $p->("WARNING: could not save approvals: $_[0]\n") };

    # Summary of ALL items (approved dimmed, pending flagged) for context.
    my $n = scalar @items;
    my $hdr = sprintf("Backpack for this project — %d item%s (%d approved, %d to review)%s",
        $n, ($n == 1 ? '' : 's'), scalar(@$ok), scalar(@$pending),
        ($migrated ? ' [migrated a prior whole-file approval]' : ''));
    $p->($C->('1;36', $hdr), ":\n");
    $tx->("\n--- backpack review ---\n$hdr:\n");
    for my $it (@items) {
        my $skey = _safe(BackpackApproval::item_key($it));
        if (BackpackApproval::is_approved($it, $appr)) {
            $p->($C->('2', "  [approved] $skey"), "\n");
            $tx->("  [approved] $skey\n");
        } else {
            $p->($C->('1;33', "  [review]   $skey"), "\n");
            $tx->("  [review]   $skey\n");
        }
    }
    $p->("\n");

    # Nothing new to decide → install everything already approved, no prompts.
    # Persist the store regardless: a migration may have seeded it, and prune may
    # have dropped vanished entries — both must survive to the next launch.
    unless (@$pending) {
        return commit(plan => $plan, approvals => $approvals, decisions => {},
                      remove => $remove, on_error => $save_error);
    }

    $p->($C->('1;37;41',
        "  These install/verify commands run AS ROOT in the container — review each.  "), "\n\n");

    my %decided;   # keys approved or removed this pass; the rest stay deferred
    ITEM: for my $it (@$pending) {
        my $key  = BackpackApproval::item_key($it);   # real key — logic/identity
        my $skey = _safe($key);                       # sanitized — display/transcript
        my $rationale = (defined $it->{rationale} && $it->{rationale} ne '')
            ? _safe($it->{rationale}) : '(none given)';
        my $s_install = _safe($it->{install});
        my $s_verify  = _safe($it->{verify});
        $p->($C->('1;33', "→ $skey"), "\n");
        $p->($C->('36', "    install:   "), $s_install, "\n");
        $p->($C->('36', "    verify:    "), $s_verify,  "\n");
        $p->($C->('36', "    rationale: "), $rationale, "\n");
        $tx->("REVIEW $skey\n    install:   $s_install\n    verify:    $s_verify\n    rationale: $rationale\n");

        DECIDE: while (1) {
            $p->($C->('1', "    [a]pprove  [r]emove  [q]uit (defer the rest) > "));
            my $line = <$in>;
            unless (defined $line) { $p->("\n"); last ITEM; }   # EOF → defer the rest
            $line =~ s/^\s+//; $line =~ s/\s+$//;
            my $k = lc(substr($line, 0, 1) // '');
            if ($k eq 'a') {
                BackpackApproval::approve($it, $appr);
                $decided{$key} = 1;
                $p->($C->('32', "    approved"), "\n\n");
                $tx->("DECISION $skey -> approved\n");
                last DECIDE;
            }
            elsif ($k eq 'r') {
                $p->($C->('1', "    Remove $skey from backpack.json (permanent)? [y/N] > "));
                my $c = <$in>;
                unless (defined $c) { $p->("\n"); last ITEM; }   # EOF → defer the rest
                if (lc(substr($c, 0, 1) // '') eq 'y') {
                    my $rc = $remove->($it);
                    if (defined $rc && $rc == 0) {
                        BackpackApproval::forget($it, $appr);
                        $decided{$key} = 1;
                        $p->($C->('33', "    removed from backpack"), "\n\n");
                        $tx->("DECISION $skey -> removed\n");
                    } else {
                        my $code = (defined $rc ? ($rc >> 8) : '?');
                        $p->($C->('31', "    remove failed (exit $code) — left in place, still pending"), "\n\n");
                        $tx->("DECISION $skey -> remove-failed\n");
                    }
                    last DECIDE;
                }
                $p->("\n");   # cancelled removal → re-prompt this item
            }
            elsif ($k eq 'q') { $p->("\n"); last ITEM; }   # defer the rest
            else { $p->($C->('31', "    please answer a, r, or q"), "\n"); }
        }
    }

    # Approved set, in backpack-file order: pre-approved (still present) + newly
    # approved. Removed items are gone from the file and never approved here, so
    # is_approved() excludes them. Deferred = walked-but-undecided items.
    # The walk above already applied every decision to %$appr in place, so the
    # commit below is asked only to SAVE and to compute the return value: its
    # decisions map is the walk's own %decided, replayed as no-ops.
    return commit(plan => $plan, approvals => $approvals, decisions => {},
                  applied => \%decided,
                  remove => $remove, on_error => $save_error);
}

sub _slurp {
    my ($path) = @_;
    return undef unless defined $path;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

1;
