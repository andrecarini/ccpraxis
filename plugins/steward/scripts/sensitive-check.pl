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

# Full-line FALSE-POSITIVE exclusions (applied to "path:lineno:content"). These
# are TRACKED files/lines that legitimately contain pattern-shaped text — the
# scanners' own source (which lists the patterns), docs, and credential-helper
# code where the "secret" is a placeholder/identifier, not a value. They are
# dropped regardless of git status.
my @exclude = (
    qr/\.gitignore/,
    qr/sensitive-check\.(?:pl|sh)/,   # the scanner itself (its source lists the patterns)
    qr/README\.md/,
    qr/\{accessToken\}/,
    qr/credentials_json.*secrets\./,
    qr{/vault-sync\.pl:},             # vault-sync.pl also defines secret patterns
    qr/username=x-access-token/,       # launcher.pl git-credential-helper printf: `password=%s` is a format placeholder filled from ~/.claude/git-pat at runtime, not a literal secret
    qr/ensure_credentials_json_host_file/,  # launcher.pl function name, not a `credentials_json` secret key
);

# Non-public trees — used ONLY as a FALLBACK when $dir is not a git repo (or git
# can't be consulted). In the normal case ($dir = the git repo) we instead skip
# exactly the files git itself ignores (see %git_ignored below). Grounding the
# skip in real gitignore status means the scanner cannot develop a blind spot if
# one of these trees is ever NOT actually gitignored — a deleted inner `*`
# .gitignore, a data dir relocated via $CCPRAXIS_DATA_DIR, or a dir created by a
# path that skipped the self-gitignore. (A path-pattern assumption could.)
my @exclude_tree_fallback = (
    qr{/\.claude-plans/},
    qr{/\.ccpraxis-local-data/},
    qr{/\.claude/backup-cache/},
);

# Drive-letter form for native git's -C arg when MSYS arg-conversion is off
# (mirrors git_path in vault-sync.pl / todo-sync.pl). No-op on POSIX/Linux paths.
sub git_path { my $p = shift; return $p unless defined $p; $p =~ s{^/([a-zA-Z])/}{uc($1) . ":/"}e; return $p; }

# Files git would NOT commit, as {abs_path => 1}. One batched `git check-ignore`
# call: candidate paths are fed as repo-relative pathspecs over STDIN (a temp
# file → not argv, so MSYS never mangles them), and -C uses git_path so native
# git resolves the repo under conversion-off. Returns undef if git errors (the
# caller then falls back to @exclude_tree_fallback) so a git hiccup never turns
# into a silent miss.
sub git_ignored_files {
    my ($dir, $files) = @_;
    (my $prefix = $dir) =~ s{/+$}{};
    my %rel_of;
    for my $f (@$files) {
        $rel_of{$f} = (index($f, "$prefix/") == 0) ? substr($f, length($prefix) + 1) : $f;
    }
    require File::Temp;
    my ($tfh, $tpath) = File::Temp::tempfile('senscheck-XXXXXX', TMPDIR => 1, UNLINK => 1);
    binmode $tfh;
    print $tfh join("\0", values %rel_of);
    close $tfh;
    my $gp  = git_path($prefix);
    my $out = `git -C "$gp" check-ignore -z --stdin < "$tpath" 2>/dev/null`;
    my $exit = $? >> 8;
    return undef if $exit > 1;   # 0 = some ignored, 1 = none ignored, >1 = git error
    my %ignored_rel = map { $_ => 1 } (defined $out ? grep { length } split /\0/, $out : ());
    my %ignored;
    for my $f (@$files) { $ignored{$f} = 1 if $ignored_rel{ $rel_of{$f} }; }
    return \%ignored;
}

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

# Determine the skip-set from real git status when $dir is a repo (the normal
# case). $ignored_ref defined => use it; undef => fall back to path patterns.
my $ignored_ref = (-e "$dir/.git" && @files) ? git_ignored_files($dir, \@files) : undef;

# pattern label => arrayref of matching "path:lineno:content" lines (insertion order)
my %hits;
for my $file (sort @files) {
    # Skip files that won't reach the public repo: git-ignored (authoritative)
    # when we have git status, else the hardcoded non-public-tree fallback.
    if (defined $ignored_ref) { next if $ignored_ref->{$file}; }
    else { next if grep { $file =~ $_ } @exclude_tree_fallback; }
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
