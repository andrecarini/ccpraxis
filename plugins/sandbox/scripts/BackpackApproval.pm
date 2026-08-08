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
#
# The join is INJECTIVE: a literal ':' or '\' inside either component is escaped
# first, so distinct items can never collide on one key. Without that,
# {category => 'npm-global', name => 'a:b'} and {category => 'npm-global:a',
# name => 'b'} both rendered as 'npm-global:a:b'. backpack.pl de-duplicates on
# "$category\0$name" and only WARNS about an unknown category, so both survive
# validation and reach the store together.
#
# Found by the package 08 red-team on 2026-08-08, which drove the collision to a
# wrong-item deletion in the launch-time triage screen. That call site is now
# keyed by position, so the destructive path is closed there — but the store
# ITSELF was still collapsing the two, and `forget` on one silently deleted the
# other's approval. That direction is fail-safe (the item returns to pending and
# is re-reviewed) rather than destructive, which is why it is a correctness fix
# rather than an emergency.
#
# Escaping rather than switching the delimiter to "\0" is deliberate. This string
# is the on-disk key in backpack-approvals.json, so changing the rendering of
# ORDINARY items would invalidate every stored approval and silently re-prompt
# the operator for commands they had already reviewed. Escaping leaves every key
# without a ':' or '\' in its components byte-identical — which is all of them in
# practice — and changes only the pathological ones that were broken anyway.
sub item_key {
    my ($it) = @_;
    $it ||= {};
    my $c = defined $it->{category} ? $it->{category} : '';
    my $n = defined $it->{name}     ? $it->{name}     : '';
    for ($c, $n) { s/\\/\\\\/g; s/:/\\:/g; }
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

# load($path, \%err) -> \%approvals ({key=>hash}); {} when missing/unreadable/malformed
# (a corrupt store degrades to "nothing approved", i.e. re-review — fail safe).
#
# \%err is an OPTIONAL second argument, backward compatible: existing one-argument
# callers (t/26-backpack-approval.t, BackpackReview.pm) are unaffected. When
# supplied as a hashref it is cleared at entry and, on failure, filled in with
# { op, broken, errno, path, message } so the caller can tell *absent* (broken=>0)
# from *broken* (broken=>1) — the distinction criterion 5 needs.
sub load {
    my ($path, $err) = @_;
    $err = {} unless ref $err eq 'HASH';
    %$err = ();
    unless (defined $path && -f $path) {
        %$err = (
            op => 'absent', broken => 0, errno => '',
            path => (defined $path ? $path : ''),
            message => 'absent',
        );
        return {};
    }
    open my $fh, '<:raw', $path or do {
        my $errno = $!;
        %$err = (
            op => 'open', broken => 1, errno => "$errno", path => $path,
            message => "open failed: $errno",
        );
        return {};
    };
    local $/; my $blob = <$fh>; close $fh;
    my $d = eval { JSON::PP->new->decode($blob) };
    if ($@) {
        my $msg = $@; $msg =~ s/\n.*//s;
        %$err = (op => 'decode', broken => 1, errno => '', path => $path, message => $msg);
        return {};
    }
    return $d->{approved} if ref $d eq 'HASH' && ref $d->{approved} eq 'HASH';
    %$err = (op => 'schema', broken => 1, errno => '', path => $path, message => 'unexpected schema');
    return {};
}

# save($path, \%approvals, \%err) -> 1|0. Atomic-ish: write a temp sibling then
# rename, with the Windows unlink-then-rename fallback (rename won't clobber on
# Win32).
#
# \%err is an OPTIONAL third argument, backward compatible for the same reason as
# load()'s. On failure it is filled with { op, broken, errno, path, message }; on
# success it is left empty. `errno` is captured from $! IMMEDIATELY at the failing
# call, before any cleanup unlink can overwrite it.
sub save {
    my ($path, $appr, $err) = @_;
    $err = {} unless ref $err eq 'HASH';
    %$err = ();
    unless (defined $path) {
        %$err = (op => 'no-path', broken => 0, errno => '', path => '', message => 'no path given');
        return 0;
    }
    $appr ||= {};
    my $json = eval {
        JSON::PP->new->canonical(1)->pretty->encode(
            { version => $STORE_VERSION, approved => $appr });
    };
    if ($@) {
        my $msg = $@; $msg =~ s/\n.*//s;
        %$err = (op => 'encode', broken => 1, errno => '', path => $path, message => $msg);
        return 0;
    }
    my $tmp = "$path.tmp.$$";
    open my $fh, '>:raw', $tmp or do {
        my $errno = $!;
        %$err = (
            op => 'open', broken => 1, errno => "$errno", path => $tmp,
            message => "open failed: $errno",
        );
        return 0;
    };
    print $fh $json;
    unless (close $fh) {
        my $errno = $!;
        %$err = (
            op => 'close', broken => 1, errno => "$errno", path => $tmp,
            message => "close failed: $errno",
        );
        unlink $tmp;
        return 0;
    }
    unless (rename $tmp, $path) {
        if (-e $path) {
            unless (unlink $path) {
                my $errno = $!;
                %$err = (
                    op => 'unlink', broken => 1, errno => "$errno", path => $path,
                    message => "unlink failed: $errno",
                );
                unlink $tmp;
                return 0;
            }
        }
        unless (rename $tmp, $path) {
            my $errno = $!;
            %$err = (
                op => 'rename', broken => 1, errno => "$errno", path => $path,
                message => "rename failed: $errno",
            );
            unlink $tmp;
            return 0;
        }
    }
    return 1;
}

1;
