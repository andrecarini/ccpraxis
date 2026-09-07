#!/usr/bin/env perl
# 16-no-nul-and-marketplace-noise.t — two defects found by using the tools, not
# by reading them. Both had shipped, and both were invisible in normal output.
#
# 1. `2>NUL` INSIDE PERL BACKTICKS. claude-binary-backup.pl ended two backtick
#    commands with `2>NUL`. Git-for-Windows perl runs backticks through sh,
#    where NUL is not a device but a FILENAME — so every invocation dropped a
#    literal `NUL` file into the working directory, which Explorer cannot
#    delete. This repo documents that landmine in CLAUDE.md, warns about it in
#    bp-keepawake.pl, and enforces it against Bash commands with a PreToolUse
#    hook — and still shipped it in its own perl. The hook only sees what the
#    agent types; it cannot see inside a perl backtick.
#
#    `2>/dev/null` is NOT the correct fix: it would be wrong the moment
#    backticks go through cmd.exe on a native-Windows perl. The suppression
#    belongs inside PowerShell (-ErrorAction SilentlyContinue), where it is
#    portable. That is bp-keepawake.pl:229's documented reasoning, applied.
#
# 2. A REFRESH TIMESTAMP READ AS A CONFLICT. marketplace-diff stripped
#    installLocation before comparing but not lastUpdated, so a marketplace
#    that had merely been re-fetched reported as "diverged" with byte-identical
#    `source`. The backup skill's diverged branch is written for "the source URL
#    changed" and prompts the user — meaning a routine refresh surfaced as a
#    conflict on every single backup.
#
# AC1  no perl backtick in the steward scripts redirects to NUL
# AC2  running the binary-backup script leaves no NUL file behind (behavioural)
# AC3  marketplace-diff ignores volatile fields, so equal sources read identical
# AC4  ...and still reports a REAL divergence (the counter-check)
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use StewardTest qw(ok is like unlike done_testing diag);

my $SCRIPTS = "$Bin/../../scripts";
my $BACKUP  = "$SCRIPTS/claude-binary-backup.pl";
my $HELPERS = "$SCRIPTS/ccpraxis-helpers.pl";

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# ---------------------------------------------------------------------------
# AC1 — structural: no NUL redirect anywhere in steward's perl.
#
# Scanned across every script, not just the two that were fixed, because the
# mistake is a habit rather than a typo: the same line shape is what a person
# writes when they are thinking in cmd.exe.
# ---------------------------------------------------------------------------
{
    # REPO-WIDE, not just steward. The mistake is a habit, not a typo -- it is
    # the line shape a person writes while thinking in cmd.exe -- so scoping the
    # scan to the plugin that happened to have it would let the next one ship
    # the same thing. The PreToolUse hook cannot help: it inspects Bash commands
    # the agent types and has no view inside a perl backtick.
    my $repo = "$Bin/../../../..";
    my @dirs = ("$repo/scripts", glob("$repo/plugins/*/scripts"), glob("$repo/plugins/*/hooks"));

    my @files;
    for my $d (@dirs) {
        next unless -d $d;
        opendir(my $dh, $d) or next;
        push @files, map { "$d/$_" } grep { /\.p[lm]$/ } readdir $dh;
        closedir $dh;
    }

    cmp_ok_ge(scalar @files, 15, 'AC1 liveness: found scripts across the repo to scan')
        or diag('  a scan over too few files passes for the wrong reason; got '
              . scalar(@files));

    my @bad;
    for my $f (sort @files) {
        my $src = slurp($f) // next;
        my $short = $f;
        $short =~ s{^\Q$repo\E/}{};
        my $n = 0;
        for my $line (split /\n/, $src) {
            $n++;
            # Comments explaining the landmine are fine -- several files
            # deliberately document it. Redirects are not.
            next if $line =~ /^\s*#/;
            push @bad, "$short:$n" if $line =~ /\d?>>?\s*NUL\b/;
        }
    }
    is(scalar @bad, 0, 'AC1 no script in the repo redirects to NUL')
        or diag('  offending: ' . join(', ', @bad)
              . "\n  under sh, NUL is a filename -- this creates an undeletable file");
}

sub cmp_ok_ge { my ($got, $want, $name) = @_; ok(($got // 0) >= $want, $name) }

# ---------------------------------------------------------------------------
# AC1b — the DETECTOR itself is correct.
#
# AC1 passing means "no file matched". That is equally true of a regex that
# matches nothing at all, so the pattern is exercised against known-bad and
# known-good lines here.
#
# These fixtures live in the test file on purpose. The PreToolUse hook inspects
# Bash command TEXT, so any attempt to check these shapes from a shell command
# is blocked before it runs -- correctly, but it means the only place this can
# be verified is inside a file the hook never reads. (This directory is outside
# AC1's scan set, so the fixtures cannot trip the scan they define.)
# ---------------------------------------------------------------------------
{
    my $re = qr/\d?>>?\s*NUL\b/;

    my @should_match = (
        'my $o = `cmd 2' . '>NUL`;',
        'system("x ' . '>NUL");',
        '`y 2' . '>> NUL`;',
        'my $c = "ps ... 2' . '> NUL";',
    );
    my @should_not = (
        'my $n = "/dev/null";',
        'print "NULL\n";',
        'my $x = $NULVAR;',
        'my $s = "NULprefix";',
    );

    my $missed = grep { $_ !~ $re } @should_match;
    is($missed, 0, 'AC1b the detector matches every NUL-redirect shape')
        or diag('  a pattern that matches nothing makes AC1 pass vacuously');

    my $false = grep { $_ =~ $re } @should_not;
    is($false, 0, 'AC1b and does not fire on NUL appearing in other contexts')
        or diag('  over-matching would make AC1 unfixable noise');
}

# ---------------------------------------------------------------------------
# AC2 — behavioural. The structural check above can be satisfied while some
# other call still does it, so the script is actually RUN in a clean directory
# and the directory inspected afterwards. This is how the defect was found.
# ---------------------------------------------------------------------------
SKIP_AC2: {
    ok(-f $BACKUP, 'AC2 claude-binary-backup.pl exists') or last SKIP_AC2;

    my $dir = tempdir(CLEANUP => 0);   # cleaned by hand below; a NUL file can defeat rmtree
    my $out = do {
        # `detect` is read-only: it locates the binary, hashes it and reports.
        # It touches nothing, which is what makes it safe to run here and still
        # exercise both of the PowerShell calls that carried the redirect.
        my $cmd = "cd \"$dir\" && \"$^X\" \"$BACKUP\" detect";
        `$cmd 2>&1`;
    };

    my $nul = "$dir/NUL";
    ok(!-e $nul, 'AC2 running the script leaves no NUL file in the working directory')
        or diag("  a literal NUL was created at $nul");

    # Liveness: if the script did not actually run, the absence above proves
    # nothing. Its JSON must have come back.
    like(($out // ''), qr/"binary_path"/,
         'AC2 liveness: the script really ran (its JSON came back)')
        or diag("  got: " . substr(($out // ''), 0, 200));

    unlink $nul if -e $nul;
    rmdir $dir;
}

# ---------------------------------------------------------------------------
# AC3 / AC4 — marketplace-diff ignores volatile fields but not real ones.
# ---------------------------------------------------------------------------
{
    ok(-f $HELPERS, 'AC3 ccpraxis-helpers.pl exists');

    my $src = slurp($HELPERS) // '';
    like($src, qr/lastUpdated/,
         'AC3 the differ names lastUpdated as volatile')
        or diag('  a refresh timestamp differing is not a conflict');

    # Behavioural, through the real subcommand, on fixtures rather than the
    # operator's own files.
    my $dir = tempdir(CLEANUP => 1);
    my $enc = JSON::PP->new->canonical(1);

    my $write = sub {
        my ($p, $obj) = @_;
        open my $fh, '>:raw', $p or die "write $p: $!";
        print {$fh} $enc->encode($obj);
        close $fh;
    };

    # Same source, different timestamp and install path: NOT a conflict.
    $write->("$dir/live.json", {
        'official' => { source => { source => 'github', repo => 'anthropics/x' },
                        lastUpdated => '2026-09-06T13:17:46.869Z',
                        installLocation => '/c/live/path' },
    });
    $write->("$dir/repo.json", {
        'official' => { source => { source => 'github', repo => 'anthropics/x' },
                        lastUpdated => '2026-08-28T20:53:10.784Z',
                        installLocation => '/c/other/path' },
    });

    my $j = run_diff($dir);
    is(scalar @{ $j->{diverged} || [] }, 0,
       'AC3 identical sources with different timestamps do not diverge')
        or diag('  ' . $enc->encode($j->{diverged}));
    is(scalar @{ $j->{identical} || [] }, 1,
       'AC3 they are reported as identical');

    # AC4 counter-check: a REAL source difference must still surface, or the
    # fix above would be indistinguishable from ignoring the file entirely.
    $write->("$dir/repo.json", {
        'official' => { source => { source => 'github', repo => 'someone-else/x' },
                        lastUpdated => '2026-08-28T20:53:10.784Z' },
    });
    my $j2 = run_diff($dir);
    is(scalar @{ $j2->{diverged} || [] }, 1,
       'AC4 counter-check: a genuinely different source still reports diverged')
        or diag('  ' . $enc->encode($j2));
}

sub run_diff {
    my ($dir) = @_;
    my $raw = `"$^X" "$HELPERS" marketplace-diff --live "$dir/live.json" --repo "$dir/repo.json" 2>&1`;
    my $j = eval { JSON::PP->new->decode($raw) };
    return ref $j eq 'HASH' ? $j : { _raw => $raw };
}

done_testing();
