#!/usr/bin/env perl
# platform: any
# The sandbox image must build natively on every host architecture the
# launcher runs on, and a step that cannot do its job must say so rather than
# go green. Two defects, both found porting the sandbox to an Apple Silicon Mac
# (rootless podman machine, linux/arm64 image):
#
#   1. The Node toolchain step fetched node-*-linux-x64 unconditionally, so an
#      arm64 build died at `npm install -g pnpm` with "Exec format error".
#      (That step left the image on 2026-10-30; the check is now general.)
#   2. The jail-skeleton step chained `mknod ... && cp ... || true && ...`.
#      Shell precedence let that `|| true` swallow a mknod failure (which is
#      what a rootless build always produces) together with every command
#      before it, so the image shipped with no device nodes, no 1777 /tmp and
#      no /etc copies while the build reported success.
#
# TEXT ONLY: never builds an image or starts a container (the real build is
# exercised by the serial container tests and by hand; see the sandbox
# README). Each detector is proven able to fire against a counter-fixture
# holding the old shape, so a pass here cannot be vacuous.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $CONTAINERFILE = "$Bin/../../container/Containerfile";
open my $fh, '<:raw', $CONTAINERFILE or BAIL_OUT("cannot read $CONTAINERFILE: $!");
my $SRC = do { local $/; <$fh> };
close $fh;

# run_instructions($text) -> list of RUN instruction bodies, each one logical
# line (backslash continuations joined), comment lines dropped. A Containerfile
# comment is a whole line starting with #, so trailing text after code is code.
sub run_instructions {
    my ($text) = @_;
    my @out;
    my $cur;
    for my $line (split /\n/, $text) {
        next if $line =~ /^\s*#/;
        if (defined $cur) {
            $cur .= ' ' . $line;
        } elsif ($line =~ /^RUN\s+(.*)$/) {
            $cur = $1;
        } else {
            next;
        }
        if ($cur =~ s/\\\s*$//) { next }
        push @out, $cur;
        undef $cur;
    }
    push @out, $cur if defined $cur;
    return @out;
}

# unscoped_or_true($run) -> count of `|| true` that are NOT closed inside their
# own `{ ...; }` group. Only a brace-scoped `|| true` is harmless in an &&
# chain; anywhere else it absorbs the failure of everything chained before it.
sub unscoped_or_true {
    my ($run) = @_;
    my $n = 0;
    while ($run =~ /\|\|\s*true\b(?!\s*;\s*\})/g) { $n++ }
    return $n;
}

my @RUNS = run_instructions($SRC);
ok(scalar(@RUNS) >= 5, 'harness: found the Containerfile RUN instructions (' . scalar(@RUNS) . ')');

# ---------------------------------------------------------------------------
# 1. No step downloads an artifact for one architecture only.
#
# The Node step this section was written for left the image on 2026-10-30
# (Node now comes from the backpack recipe, whose arch handling is asserted in
# node-pnpm-toolchain.t D1b-D1d). The class of defect stays possible for the
# next prebuilt download anyone adds, so the check is now general: a RUN that
# names a linux-x64 / amd64 / x86_64 artifact must pick it from dpkg.
# ---------------------------------------------------------------------------
{
    my $arch_specific = qr/linux-x64|linux-amd64|x86_64-linux|amd64\.(?:deb|tar|zip)/;
    my @pinned = grep { $_ =~ $arch_specific && !/dpkg --print-architecture/ } @RUNS;
    is(scalar(@pinned), 0, 'no RUN step fetches a single-architecture artifact without consulting dpkg')
        or diag("offending RUN:\n  " . join("\n  ", @pinned));

    # Counter-fixture: the pre-fix Node step must trip the detector above.
    my $old = 'curl -sSL https://nodejs.org/dist/v24.18.0/node-v24.18.0-linux-x64.tar.xz -o /tmp/node.tar.xz '
            . '&& tar -xf /tmp/node.tar.xz -C /tmp && mv /tmp/node-v24.18.0-linux-x64 /opt/node24';
    ok($old =~ $arch_specific && $old !~ /dpkg --print-architecture/,
       'counter-fixture: the old x64-only Node step is caught by the detector');
    my $fixed = 'case "$(dpkg --print-architecture)" in amd64) T=x-linux-x64.tar.xz ;; esac';
    ok(!($fixed =~ $arch_specific && $fixed !~ /dpkg --print-architecture/),
       'paired negative: an arch-aware step is not flagged');
}

# ---------------------------------------------------------------------------
# 2. No `|| true` absorbs the failure of a chain it does not own.
# ---------------------------------------------------------------------------
{
    my @bad = grep { unscoped_or_true($_) } @RUNS;
    is(scalar(@bad), 0, 'every `|| true` in a RUN chain is scoped to its own { ...; } group')
        or diag("offending RUN:\n  " . join("\n  ", @bad));

    my $old = 'mkdir -p /opt/bp-jail-skel/dev && mknod -m 666 /opt/bp-jail-skel/dev/null c 1 3 '
            . '&& chmod 1777 /opt/bp-jail-skel/tmp '
            . '&& cp -a /etc/nsswitch.conf /etc/hosts /opt/bp-jail-skel/etc/ 2>/dev/null || true '
            . '&& cp -a /etc/ssl/certs /opt/bp-jail-skel/etc/ssl/ 2>/dev/null || true '
            . '&& printf x > /opt/bp-jail-skel/etc/passwd';
    is(unscoped_or_true($old), 2, 'counter-fixture: the old jail-skeleton chain is flagged (two unscoped `|| true`)');
    is(unscoped_or_true('a && { cp x y 2>/dev/null || true; } && b'), 0,
        'paired negative: a brace-scoped `|| true` is not flagged');
}

# ---------------------------------------------------------------------------
# 3. The jail skeleton: mknod failure is reported, the rest is built anyway.
# ---------------------------------------------------------------------------
{
    my ($jail) = grep { /bp-jail-skel/ } @RUNS;
    ok(defined $jail, 'the jail-skeleton step exists');
    $jail //= '';
    my $mknod_at = index($jail, 'mknod');
    my $chmod_at = index($jail, 'chmod 1777');
    my $passwd_at = index($jail, '/opt/bp-jail-skel/etc/passwd');
    ok($chmod_at >= 0 && $chmod_at < $mknod_at,
        'the 1777 /tmp skeleton is made BEFORE, and independently of, the mknod attempt');
    ok($passwd_at >= 0 && $passwd_at < $mknod_at,
        'passwd/group are written BEFORE, and independently of, the mknod attempt');
    like($jail, qr/if\s+mknod\b.*;\s*then\b.*\belse\b.*\.no-device-nodes.*\bfi\b/,
        'a failed mknod takes an explicit else branch that leaves a .no-device-nodes marker');
    like($jail, qr/WARNING:[^']*mknod/,
        'the else branch prints a WARNING naming mknod into the build log');
}

done_testing();
