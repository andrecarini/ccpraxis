package BackpackApproval;
# Per-item, machine-local approval memory for backpack items — the launcher's
# install gate (#21). Backpack install/verify commands run AS ROOT in the
# container, so the user approves each item before it runs. Approval is keyed by
# item identity (category:name) AND a content hash of the commands that will
# execute, so:
#   * an UNCHANGED, already-approved item is never re-prompted, and
#   * a CHANGED item (its install/verify edited) re-prompts — you approved
#     specific commands, not just a name.
# Newly added items are the only ones reviewed on a later launch.
#
# State lives machine-local under .launcher/ (like the older whole-file trust
# hash it replaces): "I trust these commands on THIS machine" is a per-machine
# security decision. backpack.json itself stays the shared, steward-synced source
# of truth — only `remove` mutates it.
#
# PURE module: no console I/O, no spawning. The launcher owns the interactive
# review and the install; this owns the identity/hash/partition/store logic so it
# can be held accountable by the test suite.

use strict;
use warnings;
use Digest::MD5 qw(md5_hex);
use JSON::PP ();

our $STORE_VERSION = 1;

# item_key($item) -> "category:name" — the stable identity used as the store key.
sub item_key {
    my ($it) = @_;
    $it ||= {};
    my $c = defined $it->{category} ? $it->{category} : '';
    my $n = defined $it->{name}     ? $it->{name}     : '';
    return "$c:$n";
}

# item_hash($item) -> a content fingerprint over ONLY the fields that actually
# EXECUTE: install + verify. Everything else is deliberately excluded:
#   * version   — REMOVED from the backpack schema (it duplicated the pin already
#                 in the install command / verify check and could drift). A
#                 legacy file may still carry one; it is never executed, so it is
#                 excluded here too — a stray version must not affect approval.
#   * rationale — prose shown to the human; editing it must not invalidate a
#                 prior command approval.
sub item_hash {
    my ($it) = @_;
    $it ||= {};
    my $blob = join("\0",
        defined $it->{install} ? $it->{install} : '',
        defined $it->{verify}  ? $it->{verify}  : '',
    );
    return md5_hex($blob);
}

# is_approved($item, \%approvals) -> 1|0. Approved iff the store holds this item's
# key AND the stored hash equals the item's CURRENT content hash (so an edited
# command falls back to pending).
sub is_approved {
    my ($it, $appr) = @_;
    return 0 unless ref $appr eq 'HASH';
    my $k = item_key($it);
    return 0 unless exists $appr->{$k};
    return (defined $appr->{$k} && $appr->{$k} eq item_hash($it)) ? 1 : 0;
}

# partition(\@items, \%approvals) -> (\@approved, \@pending), original order kept.
sub partition {
    my ($items, $appr) = @_;
    my (@ok, @pending);
    for my $it (@{ $items || [] }) {
        if (is_approved($it, $appr)) { push @ok, $it } else { push @pending, $it }
    }
    return (\@ok, \@pending);
}

# approve($item, \%approvals) — record this item's current content hash. Mutates
# the passed-in hashref and returns it.
sub approve {
    my ($it, $appr) = @_;
    $appr ||= {};
    $appr->{ item_key($it) } = item_hash($it);
    return $appr;
}

# forget($item, \%approvals) — drop an item's approval (used on remove). Mutates.
sub forget {
    my ($it, $appr) = @_;
    return $appr unless ref $appr eq 'HASH';
    delete $appr->{ item_key($it) };
    return $appr;
}

# prune(\%approvals, \@items) -> count removed. Drops approval records whose item
# no longer exists in the backpack (keeps the store from growing forever as items
# come and go). Mutates the hashref.
sub prune {
    my ($appr, $items) = @_;
    return 0 unless ref $appr eq 'HASH';
    my %live = map { item_key($_) => 1 } @{ $items || [] };
    my $n = 0;
    for my $k (keys %$appr) { delete $appr->{$k}, $n++ unless $live{$k} }
    return $n;
}

# load($path) -> \%approvals ({key=>hash}); {} when missing/unreadable/malformed
# (a corrupt store degrades to "nothing approved", i.e. re-review — fail safe).
sub load {
    my ($path) = @_;
    return {} unless defined $path && -f $path;
    open my $fh, '<:raw', $path or return {};
    local $/; my $blob = <$fh>; close $fh;
    my $d = eval { JSON::PP->new->decode($blob) };
    return (ref $d eq 'HASH' && ref $d->{approved} eq 'HASH') ? $d->{approved} : {};
}

# save($path, \%approvals) -> 1|0. Atomic-ish: write a temp sibling then rename,
# with the Windows unlink-then-rename fallback (rename won't clobber on Win32).
sub save {
    my ($path, $appr) = @_;
    return 0 unless defined $path;
    $appr ||= {};
    my $json = JSON::PP->new->canonical(1)->pretty->encode(
        { version => $STORE_VERSION, approved => $appr });
    my $tmp = "$path.tmp.$$";
    open my $fh, '>:raw', $tmp or return 0;
    print $fh $json;
    close $fh or do { unlink $tmp; return 0 };
    unless (rename $tmp, $path) {
        if (-e $path) {
            unlink $path or do { unlink $tmp; return 0 };
        }
        rename($tmp, $path) or do { unlink $tmp; return 0 };
    }
    return 1;
}

1;
