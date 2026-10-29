#!/usr/bin/env perl
# platform: any
# The blueprint plugin's skills and auditor agent run butler's scripts
# (bp-blueprint.pl, bp-lifecycle.pl, bp-checks.pl, bp-model-check.pl). They
# used to say `perl plugins/butler/scripts/...`, a path relative to the
# session's cwd, which resolves only when that cwd is a ccpraxis checkout.
# /blueprint:create and /blueprint:manage run in ANY project, so every such
# call failed there with "Can't open perl script". The calls now go through
# ${CLAUDE_PLUGIN_ROOT}/../butler/scripts/ -- the sibling plugin in the same
# tree, the layout bp-lib.sh and bp-keepawake.pl already rely on.
#
# Also pinned: create's Objective body is never staged at a fixed
# /tmp/objective.md, which two sessions authoring at once would share.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Find ();

(my $BLUEPRINT = "$Bin/../../../blueprint") =~ s{\\}{/}g;
ok(-d $BLUEPRINT, "the blueprint plugin is at $BLUEPRINT") or BAIL_OUT('no blueprint plugin');

my @docs;
File::Find::find(sub { push @docs, $File::Find::name if /\.md\z/ }, "$BLUEPRINT/skills", "$BLUEPRINT/agents");
ok(scalar(@docs) >= 3, 'found the blueprint skill and agent docs to scan');

my (@relative, @resolved, @missing);
for my $doc (sort @docs) {
    open my $fh, '<:raw', $doc or die "read $doc: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    (my $short = $doc) =~ s{^\Q$BLUEPRINT\E/}{};
    while ($text =~ m{perl\s+(?!")plugins/butler/scripts/(\S+)}g) {
        push @relative, "$short: plugins/butler/scripts/$1";
    }
    # Either quoting works: the whole path ("${...}/../butler/scripts/x.pl") or
    # just the variable ("${...}"/../butler/scripts/x.pl, which keeps the script
    # name and its arguments contiguous for docs that pin that literal).
    while ($text =~ m{perl\s+"\$\{CLAUDE_PLUGIN_ROOT\}"?/\.\./butler/scripts/([^"\s]+)}g) {
        my $script = $1;
        push @resolved, "$short: $script";
        push @missing, "$short: $script" unless -f "$BLUEPRINT/../butler/scripts/$script";
    }
    like($text, qr/\A(?!.*\/tmp\/objective\.md)/s, "$short: no fixed /tmp/objective.md staging path");
}

is_deeply(\@relative, [], 'no blueprint skill/agent runs a butler script by a cwd-relative plugins/butler/ path')
    or diag(join("\n", @relative));
cmp_ok(scalar(@resolved), '>=', 8,
    'the butler calls (create: init/set-section/add-decision/add-package; manage: 3x reconcile; auditor: 2) '
  . 'go through ${CLAUDE_PLUGIN_ROOT}/../butler/scripts/')
    or diag(join("\n", @resolved));
is_deeply(\@missing, [], 'every script named that way exists where the sibling-plugin path resolves')
    or diag(join("\n", @missing));

done_testing();
