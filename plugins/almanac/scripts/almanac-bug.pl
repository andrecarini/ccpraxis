#!/usr/bin/env perl
# almanac-bug.pl — ccpraxis bug reports filed BY agents working in other projects.
#
# THE PROBLEM. An agent hits a ccpraxis tooling defect while working in some
# unrelated project. Today that observation dies with the session: it is prose
# in a transcript nobody re-reads. There is no path from "the tooling failed me
# here" to "ccpraxis knows about it".
#
# THE SHAPE. One file per report, written ONLY through this script, in a small
# state machine that freezes a report once ccpraxis has picked it up:
#
#   open  ->  reviewing  ->  taken  ->  resolved | declined
#
# `open` is the reporter's: they may keep editing while nobody has looked. From
# `reviewing` onward the content is FROZEN — the filer cannot rewrite history
# under a reviewer who is mid-read, and a `taken` report cannot be quietly
# reworded after the fact.
#
# THREE LAYERS OF IMMUTABILITY, because two are bypassable:
#   1. this script refuses a content change once frozen;
#   2. a PreToolUse hook denies Edit/Write against the reports directory, so the
#      script is the only sanctioned writer (same pattern as
#      guard-blueprint-write.sh);
#   3. a sha256 recorded at freeze time DETECTS an out-of-band edit anyway —
#      `verify` reports it. Layers 1 and 2 can be routed around by a determined
#      Bash call; layer 3 cannot, because it does not rely on preventing the
#      write.
#
# WHERE THINGS LIVE. Reports sit in the project they were filed from, so they
# travel with the context that produced them, and with nothing else:
#   <project>/.ccpraxis-local-data/bug-reports/<id>.md
# There is NO index — see the note above known_projects(). Cross-project
# discovery walks steward's machine-local project registry, the same one
# /steward:backup walks, so a sandboxed filer needs no access to the host.

package AlmanacBug;
use strict;
use warnings;
use JSON::PP ();
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
use Cwd ();

our @STATES = qw(open reviewing taken resolved declined);

# Closed vocabulary for `severity`. `unknown` is IN it — it is the script's own
# default (see `file`'s `$o{severity} // 'unknown'`), and an enum that rejected
# its own default would make `file` fail whenever `--severity` is omitted.
our @SEVERITIES = qw(low medium high blocker unknown);
sub valid_severity { my ($s) = @_; return scalar grep { $_ eq $s } @SEVERITIES }
our %NEXT = (
    open      => [qw(reviewing declined)],
    reviewing => [qw(taken open declined)],   # back to open = "not ready, keep editing"
    taken     => [qw(resolved declined)],
    resolved  => [],
    declined  => [],
);
# Content is editable ONLY in these states.
our %MUTABLE = (open => 1);

sub _now { time }
sub _iso { my @t = gmtime($_[0] // time);
           sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5]+1900,$t[4]+1,$t[3],$t[2],$t[1],$t[0]) }

# THERE IS NO INDEX, and the reason is worth keeping.
#
# The first design wrote an append-only index under the writer's $HOME so
# `collect` could find reports across projects. That is broken for the primary
# filer. A sandboxed agent's $HOME/.claude IS the project's own
# .ccpraxis-local-data/claude-home (bind-mounted to /root/.claude), so its index
# write lands inside that one project and never reaches the host at all — the
# machine-wide index would silently miss exactly the reports it exists to
# collect. It also wrote into ~/.claude/ccpraxis, the live install's git tree,
# which blocked a promotion pull.
#
# The report FILE in the project is the only durable state, and steward already
# solves discovery: ~/.claude/claude-code-vault/.registry-local.json maps slug ->
# absolute project path on this machine, and is deliberately gitignored inside
# the vault because those paths are machine-local. That registry is what
# /steward:backup walks, so `collect` walks it too.
sub registry_path {
    my $home = $ENV{ALMANAC_HOME} // $ENV{HOME} // $ENV{USERPROFILE} // '.';
    return "$home/.claude/claude-code-vault/.registry-local.json";
}

# known_projects() -> list of absolute project roots on THIS machine.
sub known_projects {
    my $p = registry_path();
    open my $fh, '<:raw', $p or return ();
    local $/;
    my $j = eval { JSON::PP->new->decode(<$fh>) };
    close $fh;
    return () unless ref $j eq 'HASH' && ref $j->{projects} eq 'HASH';
    my @out;
    for my $slug (sort keys %{ $j->{projects} }) {
        my $path = $j->{projects}{$slug}{path} or next;
        $path =~ s{\\}{/}g; $path =~ s{/+$}{};
        push @out, $path if length $path;
    }
    return @out;
}
sub reports_dir { my ($root) = @_; return "$root/.ccpraxis-local-data/bug-reports" }

sub _mkpath {
    my ($d) = @_;
    return 1 if -d $d;
    my $cur = ($d =~ m{^/}) ? '/' : '';
    for my $p (grep { length } split m{/}, $d) {
        $cur = ($cur eq '' || $cur eq '/') ? "$cur$p" : "$cur/$p";
        next if $cur =~ /^[A-Za-z]:$/;
        unless (-d $cur) { mkdir $cur or return 0 }
    }
    return -d $d ? 1 : 0;
}

# --- report file format: frontmatter + body -------------------------------
sub _parse {
    my ($text) = @_;
    return undef unless defined $text && $text =~ /\A---\r?\n(.*?)\r?\n---\r?\n(.*)\z/s;
    my ($fm, $body) = ($1, $2);
    my (%f, %seen, $dup);
    for my $line (split /\r?\n/, $fm) {
        next unless $line =~ /^([A-Za-z0-9_]+):\s*(.*)$/;
        my ($k, $v) = ($1, $2);
        $v =~ s/\s+$//;
        # Last-wins is UNCHANGED — every existing reader of $f->{$k} keeps its
        # current meaning. `duplicate_key` is only an additional signal that a
        # key repeated at all, surfaced (not silently swallowed) by the CLI.
        $dup //= $k if $seen{$k}++;
        $f{$k} = $v;
    }
    my %out = (fields => \%f, body => $body);
    $out{duplicate_key} = $dup if defined $dup;
    return \%out;
}
sub _render {
    my ($f, $body) = @_;
    my @order = qw(id title status severity area project created_at updated_at
                   frozen_at content_sha256 taken_at resolution);
    my %seen;
    my @lines;
    # Structural backstop: no field value may carry \r or \n, regardless of
    # whether the caller validated it. This is what closes the class for good —
    # the CLI-boundary checks (§2.2 of the spec) exist only to turn what would
    # otherwise be this die into a specific, actionable per-flag error.
    for my $k (@order) {
        next unless defined $f->{$k};
        die "almanac-bug: internal error — frontmatter field '$k' would contain a line "
          . "break or control character\n"
            if has_forbidden_bytes($f->{$k});
        push @lines, "$k: $f->{$k}"; $seen{$k}=1;
    }
    for my $k (sort keys %$f) {
        next if $seen{$k}; next unless defined $f->{$k};
        die "almanac-bug: internal error — frontmatter field '$k' would contain a line "
          . "break or control character\n"
            if has_forbidden_bytes($f->{$k});
        push @lines, "$k: $f->{$k}";
    }
    return "---\n" . join("\n", @lines) . "\n---\n" . $body;
}
sub _read_file { my ($p)=@_; open my $fh,'<:raw',$p or return undef; local $/; my $c=<$fh>; close $fh; return $c }
sub _write_atomic {
    my ($p, $bytes) = @_;
    _mkpath(dirname($p)) or return 0;
    my $tmp = "$p.tmp.$$";
    open my $fh, '>:raw', $tmp or return 0;
    print {$fh} $bytes or do { close $fh; unlink $tmp; return 0 };
    close $fh or do { unlink $tmp; return 0 };
    rename($tmp, $p) or do { unlink $tmp; return 0 };
    return 1;
}

sub load {
    my ($path) = @_;
    my $raw = _read_file($path) or return undef;
    my $p = _parse($raw) or return undef;
    $p->{path} = $path;
    $p->{raw}  = $raw;
    return $p;
}

# cas_write(): FIX 1 (fixbatch-step7, red-team HIGH) — a load-modify-write
# race defeated the freeze guarantee. Both `update` and `set-status` LOAD a
# report, then do work that can take real wall-clock time (`update`'s
# `--body -` BLOCKS on stdin), then WRITE `%f` built from that stale load.
# If a `set-status --to reviewing` landed in that window, `update`'s
# subsequent write reverted the status to `open` and erased
# content_sha256/frozen_at entirely — silently undoing the freeze the
# refusal message two lines above it promises. `verify` would then say "not
# frozen" rather than TAMPERED, so nothing would even report the problem.
#
# There is no portable, trustworthy OS-level lock to reach for here. This
# repo runs on Git-for-Windows, where flock() semantics on Windows perl
# builds are not something else in this codebase relies on (see this
# script's own header on Windows landmines, and CLAUDE.md), and mtime
# granularity is too coarse to reliably distinguish two writes inside the
# same second. So this re-reads the file's actual on-disk BYTES immediately
# before the write and compares them to the bytes `load()` captured — a
# compare-and-swap over the load-modify-write window. It cannot close the
# window entirely (there is a residual gap between this read and the
# following rename, same as any userspace CAS without a kernel-level lock),
# but it narrows "anywhere between load and write" down to "between this
# read and the next few instructions", and it turns the race from silent
# data loss into a loud, specific refusal instead of ever writing.
sub cas_write {
    my ($rep, $bytes) = @_;
    my $current = _read_file($rep->{path});
    return (0, 'the report no longer exists on disk') unless defined $current;
    return (0, 'the report changed on disk since it was loaded (a concurrent '
             . 'set-status or update landed in between)') unless $current eq $rep->{raw};
    return (0, 'write failed') unless _write_atomic($rep->{path}, $bytes);
    return (1, '');
}

# has_forbidden_bytes(): the ONE definition of "not safe in a frontmatter
# value", shared by the CLI-boundary guard (_reject_multiline, in package
# main) and the _render structural backstop below, so the two layers enforce
# literally the same rule instead of two independently-maintained
# approximations of it.
#
# Originally this was "\r or \n" -- exactly the two bytes report ee3c's
# reproduction used. A red-team probe (fixbatch-step7, 2026-08-19) showed
# --area containing U+2028 LINE SEPARATOR sailed through unrejected and
# landed verbatim in the rendered frontmatter; any consumer that treats
# U+2028 as a line break (this script's own _parse does not; some other
# reader might) sees an injected field. The class was never "CR/LF", it was
# "any line or paragraph break, and any control character" -- so that is
# what is enforced now:
#   - every C0 control character except TAB (\x00-\x08, \x0A-\x1F)
#   - DEL (\x7F)
#   - every C1 control character (\x80-\x9F), which includes NEL (U+0085)
#   - the two Unicode line/paragraph separators, U+2028 and U+2029
# TAB is deliberately still allowed: it does not break line-oriented parsing
# (_parse splits on /\r?\n/ only) and is common in pasted text.
#
# Verified on this platform (Git-for-Windows/Windows perl): argv arrives as
# raw, UN-decoded bytes, and codepoints <= 0xFF and > 0xFF do not even take
# the SAME encoding form consistently -- U+2028 (a Perl \x{...} escape whose
# value is > 0xFF) showed up as the three-byte UTF-8 sequence \xE2\x80\xA8,
# but U+0085 NEL (a \x{...} escape whose value is <= 0xFF, so Perl does not
# force the string to internal UTF-8) showed up as the single raw byte
# \x85, NOT its two-byte UTF-8 encoding \xC2\x85. Both forms had to be
# handled empirically, not assumed. Rather than chase every encoding a
# caller might produce, the C1 range (\x80-\x9F) is matched as STANDALONE
# bytes, which subsumes both "\x85 alone" and "\xC2\x85" (its second byte
# already falls in \x80-\x9F). The accepted cost: a value containing
# genuine multi-byte UTF-8 text whose CONTINUATION byte happens to land in
# \x80-\x9F (e.g. some accented Latin Extended-A characters) would also be
# rejected. That is judged safe/acceptable here -- report `area`/`title`/
# `note` values are short, ASCII-oriented labels in practice, and a false
# rejection fails LOUD (the CLI refuses with a message) rather than
# silently corrupting anything, which is the failure mode this whole fix
# exists to close.
sub has_forbidden_bytes {
    my ($val) = @_;
    return 0 unless defined $val;

    # DECODE FIRST WHEN THE BYTES ARE VALID UTF-8.
    #
    # The C1 half of the class below (\x80-\x9F) cannot be applied to
    # UNDECODED UTF-8: continuation bytes occupy \x80-\xBF, which CONTAINS the
    # whole C1 range. So every ordinary punctuation mark in this repo's own
    # report titles tripped it -- an em dash is E2 80 94, and 0x94 alone looks
    # exactly like a C1 control.
    #
    # Measured: `set-status` on 20260813-011838-82bf ("ccpraxis backpack — two
    # bugs found from a live container") died with "field 'title' would contain
    # a line break or control character" and could not be moved to any state.
    # The report was already terminal work, wedged by its own em dash. En
    # dashes, curly quotes and ellipses are all the same shape of failure.
    #
    # Decoding costs the real protection nothing. A newline is 0x0A decoded or
    # not, C0 and DEL are unchanged below 0x80, and U+2028/U+2029 are checked as
    # characters immediately after. What changes is only that legitimate
    # punctuation stops being mistaken for a control character.
    #
    # Invalid UTF-8 falls through to the byte check unchanged -- a caller that
    # hands us arbitrary bytes still gets the strict treatment, which is the
    # case the class was written for.
    my $checked = $val;
    if (!utf8::is_utf8($checked)) {
        my $decoded = eval {
            require Encode;
            Encode::decode('UTF-8', $checked, Encode::FB_CROAK());
        };
        $checked = $decoded if defined $decoded;
    }

    return 1 if $checked =~ /[\x00-\x08\x0A-\x1F\x7F-\x9F]/;   # C0 (less TAB) + DEL + C1
    return 1 if $val =~ /\xE2\x80[\xA8\xA9]/;               # UTF-8 U+2028 / U+2029
    # ...and the SAME two separators as DECODED characters. The byte form
    # above covers argv, which arrives un-decoded -- but _render is also
    # callable directly, and the whole point of the backstop is to hold for a
    # caller that bypassed the CLI. Such a caller may well hand us a decoded
    # string, where U+2028 is one character, not three bytes, and the byte
    # regex above cannot see it. Driver-verified before this line existed:
    # _render({area => "a\x{2028}b"}) was ACCEPTED while the CLI rejected the
    # same separator, so the two layers did NOT enforce the same rule despite
    # sharing this function. A byte string can never contain codepoint 2028,
    # so this costs the argv path nothing.
    return 1 if $val =~ /[\x{2028}\x{2029}]/;               # decoded U+2028 / U+2029
    return 0;
}

# The frozen digest covers the BODY only. Status/updated_at legitimately change
# after freezing; the reported content must not.
#
# This function (and the `verify` it backs) proves body-digest integrity ONLY.
# It does not detect frontmatter corruption or forged fields — a duplicate
# frontmatter key is caught separately and structurally by `_parse`, and
# reported by the `list`, `collect`, and `verify` CLI surfaces, not by this
# digest. Folding frontmatter into the digest would make `verify` scream
# TAMPERED on every legitimate `set-status` transition, since `status`,
# `updated_at`, `resolution` and `taken_at` are designed to change after
# freezing. The injection defense for those fields is the write/read guard
# (CLI-boundary validation + `_parse`'s duplicate-key detection), not this
# digest — that split is deliberate and permanent, not a gap to close later.
sub body_digest { return sha256_hex($_[0] // '') }

sub verify {
    my ($rep) = @_;
    my $f = $rep->{fields};
    return (1, 'not frozen') unless defined $f->{content_sha256} && length $f->{content_sha256};
    my $now = body_digest($rep->{body});
    return (1, 'intact') if $now eq $f->{content_sha256};
    return (0, "TAMPERED: body digest $now != recorded $f->{content_sha256}");
}

# all_report_paths(\@extra_roots) -> sorted absolute paths of every report on
# this machine. Disk is the truth; there is nothing to keep in sync.
sub all_report_paths {
    my ($extra) = @_;
    my %seen;
    my @roots = grep { !$seen{$_}++ } (@{ $extra // [] }, known_projects());
    my @paths;
    for my $r (@roots) {
        push @paths, list_reports_in($r);
    }
    my %u; return sort grep { !$u{$_}++ } @paths;
}

# opendir, NOT glob. Perl's built-in glob splits its argument on WHITESPACE, so
# "/c/Users/André/Personal Files/Job search/..." came back as three fragments
# and the real directory was never read — silently missing every report in any
# project whose path contains a space. Two of this machine's registered
# projects do. opendir has no quoting semantics at all.
sub list_reports_in {
    my ($root) = @_;
    my $dir = reports_dir($root);
    opendir(my $dh, $dir) or return ();
    my @f = sort grep { /\.md\z/ && -f "$dir/$_" } readdir($dh);
    closedir $dh;
    return map { "$dir/$_" } @f;
}

sub new_id {
    my ($now) = @_;
    my @t = gmtime($now // time);
    return sprintf('%04d%02d%02d-%02d%02d%02d-%04x',
                   $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0], ($$ & 0xffff));
}

sub can_transition {
    my ($from, $to) = @_;
    return (0, "unknown target state '$to'") unless grep { $_ eq $to } @STATES;
    return (0, "unknown current state '$from'") unless exists $NEXT{$from};
    return (0, "$from -> $to is not a legal transition (from $from you may go to: "
             . (join(', ', @{$NEXT{$from}}) || 'nowhere — it is terminal') . ')')
        unless grep { $_ eq $to } @{ $NEXT{$from} };
    return (1, '');
}

package main;
use strict;
use warnings;
use JSON::PP;

# The one invariant, enforced at every CLI argument that reaches frontmatter:
# no value may contain a line/paragraph break or control character (see
# AlmanacBug::has_forbidden_bytes for the exact class and why it is wider
# than "\r or \n"). Reject, don't escape/quote -- _parse has no quote
# handling and none is added (see spec §2.1).
#
# The message keeps the substring "must be one line" on purpose: it is the
# locked fragment every AC in 03-frontmatter-injection.t matches against,
# and it is still true (a rejected value would not stay one line if any of
# these bytes were let through) -- just no longer the WHOLE rule, which the
# rest of the sentence now says.
sub _reject_multiline {
    my ($cmd, $flag, $val) = @_;
    die "almanac-bug $cmd: --$flag must be one line, with no control characters "
      . "or Unicode line/paragraph separators\n"
        if defined $val && !ref $val && AlmanacBug::has_forbidden_bytes($val);
}

# FIX 3 (fixbatch-step7, red-team LOW): a value with leading/trailing
# whitespace was written verbatim but _parse strips trailing whitespace on
# read (and any hand-authored consumer is likely to strip both ends), so
# write != read-back. Consistent with this package's "reject, don't
# normalize silently" stance (see spec §2.1): a value that will not survive
# its own round trip is not a value the store accepts, rather than one it
# silently mangles later.
sub _reject_untrimmed {
    my ($cmd, $flag, $val) = @_;
    return unless defined $val && !ref $val;
    die "almanac-bug $cmd: --$flag must not have leading or trailing whitespace "
      . "(it would not round-trip -- the frontmatter reader strips it)\n"
        if $val =~ /^\s/ || $val =~ /\s$/;
}

# TEST SEAM ONLY (fixbatch-step7 FIX 1). When set, ALMANAC_RACE_TEST_HOOK
# names a perl script; it is run (list-form system(), no shell involved, so
# no Windows quoting to get right) right after a report is loaded and
# before `update`/`set-status` do anything else with it. That lets a test
# deterministically land a concurrent write inside the load-modify-write
# window instead of racing real threads against real wall-clock timing.
# Nothing in normal operation ever sets this env var; only
# plugins/almanac/tests/t/04-*.t does, and the hook script it points at
# never sets it itself (so there is no recursive self-invocation).
sub _race_test_hook {
    return unless defined $ENV{ALMANAC_RACE_TEST_HOOK} && length $ENV{ALMANAC_RACE_TEST_HOOK};
    system($^X, $ENV{ALMANAC_RACE_TEST_HOOK});
}

sub _slurp_arg {
    my (%o) = @_;
    return $o{body} eq '-' ? do { local $/; <STDIN> } : $o{body} if defined $o{body};
    if (defined $o{'body-file'}) {
        open my $fh, '<:raw', $o{'body-file'} or die "cannot read $o{'body-file'}: $!\n";
        local $/; my $c = <$fh>; close $fh; return $c;
    }
    return undef;
}

unless (caller) {
    my $cmd = shift @ARGV // '';
    my %o;
    while (@ARGV) {
        my $a = shift @ARGV;
        if ($a =~ /^--([a-z0-9-]+)$/) { $o{$1} = (@ARGV && $ARGV[0] !~ /^--/) ? shift @ARGV : 1 }
        else { $o{_pos} ||= []; push @{$o{_pos}}, $a }
    }
    my @pos  = @{ $o{_pos} // [] };
    my $root = $o{project} // $ENV{CLAUDE_PROJECT_DIR} // Cwd::abs_path('.') // '.';
    $root =~ s{\\}{/}g; $root =~ s{/+$}{};
    # The sixth vector: $root becomes `project:` in frontmatter, and it is
    # checked once here, uniformly, for every command -- not per-command.
    _reject_multiline($cmd || 'almanac-bug', 'project', $root);
    _reject_untrimmed($cmd || 'almanac-bug', 'project', $root);

    if ($cmd eq 'file') {
        my $title = $o{title} or die "almanac-bug file: --title is required\n";
        _reject_multiline('file', 'title', $title);
        _reject_untrimmed('file', 'title', $title);
        _reject_multiline('file', 'area', $o{area}) if defined $o{area} && !ref $o{area};
        _reject_untrimmed('file', 'area', $o{area}) if defined $o{area} && !ref $o{area};
        my $body = _slurp_arg(%o);
        die "almanac-bug file: --body or --body-file is required (a report with no body is noise)\n"
            unless defined $body && $body =~ /\S/;
        my $now = time;
        my $id  = AlmanacBug::new_id($now);
        my $dir = AlmanacBug::reports_dir($root);
        my $path = "$dir/$id.md";
        my $severity = $o{severity} // 'unknown';
        # Order matters (spec §2.3): the one-line check fires before the enum
        # check, so a multi-line payload dies "must be one line", not "must be
        # one of" -- the ee3c fixture's payload is multi-line.
        _reject_multiline('file', 'severity', $severity) unless ref $severity;
        _reject_untrimmed('file', 'severity', $severity) unless ref $severity;
        die "almanac-bug file: --severity must be one of: " . join(', ', @AlmanacBug::SEVERITIES) . "\n"
            unless !ref $severity && AlmanacBug::valid_severity($severity);
        my %f = (
            id => $id, title => $title, status => 'open',
            severity => $severity,
            area     => ($o{area} // 'unknown'),
            project  => $root,
            created_at => AlmanacBug::_iso($now), updated_at => AlmanacBug::_iso($now),
        );
        AlmanacBug::_write_atomic($path, AlmanacBug::_render(\%f, $body))
            or die "almanac-bug file: could not write $path\n";

        print "$path\n";
        exit 0;
    }

    # Locate a report by id, in this project or (for ccpraxis-side verbs) anywhere.
    my $find = sub {
        my ($id) = @_;
        my $local = AlmanacBug::reports_dir($root) . "/$id.md";
        return $local if -f $local;
        # Not here — look across the registered projects. Cheap: one glob per
        # project, and it needs no index to have been kept honest.
        for my $p (AlmanacBug::all_report_paths([$root])) {
            return $p if $p =~ m{/\Q$id\E\.md$};
        }
        return undef;
    };

    if ($cmd eq 'update') {
        my $id = $pos[0] or die "almanac-bug update: <id> required\n";
        my $path = $find->($id) or die "almanac-bug update: no report '$id'\n";
        my $rep  = AlmanacBug::load($path) or die "almanac-bug update: $path is unreadable or malformed\n";
        die "almanac-bug update: '$id' has MALFORMED: duplicate frontmatter key "
          . "'$rep->{duplicate_key}' — refusing to operate on a possibly-forged report\n"
            if $rep->{duplicate_key};
        _race_test_hook();
        my $st   = $rep->{fields}{status} // 'open';
        unless ($AlmanacBug::MUTABLE{$st}) {
            print STDERR "almanac-bug update: refused — '$id' is $st, and content is frozen from "
                       . "'reviewing' onward so a reviewer cannot have the report rewritten "
                       . "underneath them. Add a follow-up report instead.\n";
            exit 2;
        }
        my $body = _slurp_arg(%o);
        die "almanac-bug update: --body or --body-file is required\n" unless defined $body && $body =~ /\S/;
        _reject_multiline('update', 'title', $o{title}) if defined $o{title} && !ref $o{title};
        _reject_untrimmed('update', 'title', $o{title}) if defined $o{title} && !ref $o{title};
        _reject_multiline('update', 'severity', $o{severity}) if defined $o{severity} && !ref $o{severity};
        _reject_untrimmed('update', 'severity', $o{severity}) if defined $o{severity} && !ref $o{severity};
        if (defined $o{severity} && !ref $o{severity}) {
            die "almanac-bug update: --severity must be one of: " . join(', ', @AlmanacBug::SEVERITIES) . "\n"
                unless AlmanacBug::valid_severity($o{severity});
        }
        my %f = %{ $rep->{fields} };
        $f{title} = $o{title} if defined $o{title} && !ref $o{title};
        $f{severity} = $o{severity} if defined $o{severity} && !ref $o{severity};
        $f{updated_at} = AlmanacBug::_iso(time);
        my ($cas_ok, $cas_why) = AlmanacBug::cas_write($rep, AlmanacBug::_render(\%f, $body));
        unless ($cas_ok) {
            print STDERR "almanac-bug update: refused — '$id' $cas_why. "
                       . "Retry the command; do not assume it partially applied.\n";
            exit 2;
        }

        print "$path\n";
        exit 0;
    }

    if ($cmd eq 'set-status') {
        my $id = $pos[0] or die "almanac-bug set-status: <id> required\n";
        my $to = $o{to} or die "almanac-bug set-status: --to <state> required\n";
        my $path = $find->($id) or die "almanac-bug set-status: no report '$id'\n";
        my $rep  = AlmanacBug::load($path) or die "almanac-bug set-status: $path unreadable\n";
        die "almanac-bug set-status: '$id' has MALFORMED: duplicate frontmatter key "
          . "'$rep->{duplicate_key}' — refusing to operate on a possibly-forged report\n"
            if $rep->{duplicate_key};
        _race_test_hook();
        _reject_multiline('set-status', 'note', $o{note}) if defined $o{note} && !ref $o{note};
        _reject_untrimmed('set-status', 'note', $o{note}) if defined $o{note} && !ref $o{note};
        my $from = $rep->{fields}{status} // 'open';

        # A REPORT CAN BE OUTSIDE THE MACHINE, AND THEN NOTHING COULD MOVE IT.
        #
        # can_transition rejects an unknown CURRENT state, which is right for a
        # typo but leaves no way out of one. 20260825-193930-fff0 carried
        # `status: fixed` -- not one of @STATES, so it was written by hand or by
        # a version that predates this machine. set-status refused it ("unknown
        # current state 'fixed'") and guard-almanac-write.sh denies editing the
        # reports directory directly, so the report was wedged: correct by every
        # rule, and unfixable by every sanctioned path.
        #
        # --repair is that path, and it is deliberately narrow. It is honoured
        # ONLY when the current state is not in @STATES: it can rescue a report
        # that is already outside the machine, and it can never be used to skip
        # a legal-but-unwanted transition between valid states (open -> resolved
        # stays refused, with or without it). The target must still be a real
        # state.
        #
        # The status is NOT silently remapped ('fixed' -> 'resolved' would be
        # the obvious guess). A guess would hide the drift that produced it, and
        # the operator is the one who knows which state the report actually
        # reached.
        my $from_known = grep { $_ eq $from } @AlmanacBug::STATES;
        my ($ok, $why);
        if (!$from_known && $o{repair}) {
            $ok  = (grep { $_ eq $to } @AlmanacBug::STATES) ? 1 : 0;
            $why = $ok ? '' : "unknown target state '$to'";
        }
        else {
            ($ok, $why) = AlmanacBug::can_transition($from, $to);
            $why .= " -- this report is OUTSIDE the state machine, so no transition can "
                  . "reach it. Re-run with --repair to place it in a valid state."
                if !$ok && !$from_known;
        }
        unless ($ok) { print STDERR "almanac-bug set-status: $why\n"; exit 2 }

        my %f = %{ $rep->{fields} };
        my $now = AlmanacBug::_iso(time);
        $f{status} = $to;
        $f{updated_at} = $now;
        # Freeze on the way OUT of open; unfreeze if deliberately sent back.
        if ($to eq 'open') { delete $f{content_sha256}; delete $f{frozen_at} }
        else {
            $f{content_sha256} //= AlmanacBug::body_digest($rep->{body});
            $f{frozen_at}      //= $now;
        }
        $f{taken_at}   = $now       if $to eq 'taken' && !defined $f{taken_at};
        $f{resolution} = $o{note}   if defined $o{note} && !ref $o{note};
        my ($cas_ok, $cas_why) = AlmanacBug::cas_write($rep, AlmanacBug::_render(\%f, $rep->{body}));
        unless ($cas_ok) {
            print STDERR "almanac-bug set-status: refused — '$id' $cas_why. "
                       . "Retry the command; do not assume it partially applied.\n";
            exit 2;
        }

        print "$id: $from -> $to" . (($from_known ? '' : '  (repaired: previous status was outside the state machine)')) . "\n";
        exit 0;
    }

    if ($cmd eq 'list' || $cmd eq 'collect') {
        # list   = this project only (from disk, authoritative)
        # collect = every project (from the index, then re-read each file)
        my @paths;
        if ($cmd eq 'list') {
            @paths = AlmanacBug::list_reports_in($root);   # opendir, not glob — see list_reports_in
        } else {
            @paths = AlmanacBug::all_report_paths([$root]);
        }
        my @out;
        for my $p (@paths) {
            next unless -f $p;
            my $rep = AlmanacBug::load($p) or next;
            my $f = $rep->{fields};
            next if defined $o{status} && !ref $o{status} && ($f->{status}//'') ne $o{status};
            my $integrity;
            if ($rep->{duplicate_key}) {
                # A duplicate key makes the frontmatter untrustworthy -- surface
                # it, don't vanish the row, and skip the (irrelevant once this
                # is set) digest check.
                $integrity = "MALFORMED: duplicate frontmatter key '$rep->{duplicate_key}'";
            } else {
                my ($intact, $note) = AlmanacBug::verify($rep);
                $integrity = $note unless $intact;
            }
            push @out, { id=>$f->{id}, title=>$f->{title}, status=>$f->{status},
                         severity=>$f->{severity}, area=>$f->{area}, project=>$f->{project},
                         created_at=>$f->{created_at}, path=>$p,
                         (defined $integrity ? (integrity=>$integrity) : ()) };
        }
        if ($o{json}) { print JSON::PP->new->canonical->pretty->encode(\@out) }
        else {
            printf "%-22s %-10s %-9s %s\n", 'ID', 'STATUS', 'SEVERITY', 'TITLE';
            for my $r (@out) {
                printf "%-22s %-10s %-9s %s\n", $r->{id}, $r->{status}//'?',
                       $r->{severity}//'?', $r->{title}//'';
                print  "  !! $r->{integrity}\n" if $r->{integrity};
                print  "  $r->{project}\n" if $cmd eq 'collect';
            }
            print "\n" . scalar(@out) . " report(s)\n";
        }
        exit 0;
    }

    if ($cmd eq 'verify') {
        my @bad;
        my $n = 0;
        my @skipped;
        for my $p (AlmanacBug::all_report_paths([$root])) {
            my $rep = AlmanacBug::load($p);
            # A .md in this directory that has no almanac frontmatter is not a
            # report — typically a hand-written file that predates the state
            # machine, or one imported from it. Calling that "malformed" buries
            # the real signal, so it is counted separately and quietly.
            unless ($rep && defined $rep->{fields}{id}) { push @skipped, $p; next }
            $n++;
            if ($rep->{duplicate_key}) {
                push @bad, ($rep->{fields}{id} // $p)
                    . ": MALFORMED: duplicate frontmatter key '$rep->{duplicate_key}'";
                next;
            }
            my ($ok, $note) = AlmanacBug::verify($rep);
            push @bad, ($rep->{fields}{id} . ": $note") unless $ok;
        }
        printf "skipped %d non-report file(s) in bug-reports/ (no almanac frontmatter)\n",
               scalar @skipped if @skipped;
        print "checked $n report(s)\n";
        print "  $_\n" for @bad;
        exit(@bad ? 2 : 0);
    }

    print STDERR <<'USAGE';
almanac-bug.pl — ccpraxis bug reports, one file per report.

  file --title T (--body - | --body-file F) [--severity S] [--area A] [--project ROOT]
        Create a report in the current project. Prints its path.
  update <id> (--body - | --body-file F) [--title T] [--severity S]
        Revise a report. Allowed ONLY while status is `open`.
  set-status <id> --to <state> [--note N] [--repair]
        open -> reviewing -> taken -> resolved|declined  (reviewing -> open to hand back)
        --repair: ONLY for a report whose current status is not a known state
        (hand-written, or from before this machine existed). It cannot skip a
        legal transition between valid states. Put it last on the line.
        Leaving `open` FREEZES the body and records its sha256.
  list [--status S] [--json]        reports in this project
  collect [--status S] [--json]     reports across every project (via the index)
  verify                            re-check every frozen body against its digest

One report per file. Write only through this script — a PreToolUse hook denies
direct edits to the reports directory.
USAGE
    exit 3;
}
1;
