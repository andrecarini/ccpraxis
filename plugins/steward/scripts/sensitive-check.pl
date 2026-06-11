#!/usr/bin/env perl
# sensitive-check.pl — scan files for sensitive-data patterns. Exits non-zero if any found.
# Used by /steward:backup (Step 4) before committing the PUBLIC ccpraxis repo, to
# prevent accidental secret leaks. (The private vault is intentionally NOT scanned —
# see vault-sync.pl's scan_files_for_secrets, disabled by policy.)
#
# Perl port of the former sensitive-check.sh (internal helpers are Perl per the
# shell-script policy in references/extending-ccpraxis.md). Behaviour is preserved:
# same patterns, same exclusions, same grouped output, same exit codes.
#
# Usage: perl sensitive-check.pl [DIR]      (DIR defaults to ".")
# Exit:  0 = clean, 1 = sensitive data found, 2 = usage/IO error
use strict;
use warnings;
use File::Find;

# Files come off the filesystem as raw UTF-8 bytes; read and print bytes throughout
# (no :encoding layer) so non-ASCII paths like "André" round-trip correctly.
my $dir = @ARGV ? $ARGV[0] : '.';
unless (-d $dir) {
    print STDERR "sensitive-check.pl: not a directory: $dir\n";
    exit 2;
}

# [ label (shown in output), compiled regex ] — patterns that suggest sensitive data.
my @patterns = (
    [ 'sk-ant-',                                   qr/sk-ant-/ ],
    [ 'sk-[a-zA-Z0-9]{20,}',                       qr/sk-[a-zA-Z0-9]{20,}/ ],
    [ 'AIza[a-zA-Z0-9_-]',                         qr/AIza[a-zA-Z0-9_-]/ ],
    [ 'Bearer [a-zA-Z0-9_-]',                      qr/Bearer [a-zA-Z0-9_-]/ ],
    [ 'accessToken',                               qr/accessToken/ ],
    [ 'PRIVATE KEY',                               qr/PRIVATE KEY/ ],
    [ '[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]\s*[:=]',  qr/[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]\s*[:=]/ ],
    [ '[Ss][Ee][Cc][Rr][Ee][Tt]\s*[:=]',          qr/[Ss][Ee][Cc][Rr][Ee][Tt]\s*[:=]/ ],
    [ 'dsn.*sentry',                               qr/dsn.*sentry/ ],
    [ 'https://[^"]*@[^"]*\.ingest\.',             qr{https://[^"]*@[^"]*\.ingest\.} ],
    [ 'credentials_json',                          qr/credentials_json/ ],
);

# Full-line exclusions (applied to "path:lineno:content", matching the old
# `grep -v` chain). A line matching any of these is dropped — false positives,
# the scanner's own pattern lists, docs, and non-public trees.
my @exclude = (
    qr/\.gitignore/,
    qr/sensitive-check\.(?:pl|sh)/,   # the scanner itself (its source lists the patterns)
    qr/README\.md/,
    qr/\{accessToken\}/,
    qr/credentials_json.*secrets\./,
    qr{/vault-sync\.pl:},             # vault-sync.pl also defines secret patterns
    qr{/\.claude-plans/},
    qr{/\.claude/backup-cache/},
);

# Collect candidate files: *.pl *.sh *.md *.json (mirrors grep --include). Prune
# .git for speed — it holds no files with those extensions, so results are identical.
my @files;
find({
    no_chdir => 1,
    wanted   => sub {
        if (-d $_ && /(?:^|\/)\.git$/) { $File::Find::prune = 1; return; }
        return unless -f $_;
        return unless /\.(?:pl|sh|md|json)$/;
        push @files, $_;
    },
}, $dir);

# pattern label => arrayref of matching "path:lineno:content" lines (insertion order)
my %hits;
for my $file (sort @files) {
    open my $fh, '<:raw', $file or next;
    my $ln = 0;
    while (my $line = <$fh>) {
        $ln++;
        chomp(my $content = $line);
        my $record = "$file:$ln:$content";
        next if grep { $record =~ $_ } @exclude;
        for my $p (@patterns) {
            my ($label, $re) = @$p;
            push @{ $hits{$label} }, $record if $content =~ $re;
        }
    }
    close $fh;
}

my $found = 0;
for my $p (@patterns) {
    my $label = $p->[0];
    my $lines = $hits{$label} or next;
    if (!$found) {
        print "SENSITIVE DATA DETECTED — do NOT push until resolved:\n\n";
        $found = 1;
    }
    print "  Pattern: $label\n";
    print "    $_\n" for @$lines;
    print "\n";
}

print "No sensitive data found.\n" unless $found;
exit($found ? 1 : 0);
