#!/usr/bin/env perl
# almanac-migrate-todos.pl -- one-shot host-side migration of legacy vault
# todos (the retired todo plugin's todos/ directory) into global almanac todo
# records (blueprint almanac-records, package 11-migrate-todos). See
# specs/11-migrate-todos-spec.md for the full contract; this file implements
# it and adds nothing beyond it. Runs in-process through Almanac::Store --
# never through almanac-todo.pl's CLI (see the spec's "why the CLI is not
# used for writes").
#
# CORE PERL ONLY. No exit() before the `unless (caller)` guard below, no
# alarm(), never unlinks a `.lock` path, never sets/mentions
# MSYS2_ARG_CONV_EXCL (AC-22). Git is always spawned in LIST form, with each
# argument downgraded to raw UTF-8 bytes first (a decoded, utf8-flagged path
# containing non-ASCII handed to a native binary's list-form exec is
# misread on this host, even though the identical string works fine for
# Perl's own -f/-d/open against the same path) and with the vault path
# hand-translated from POSIX ("/x/...") to Windows drive form ("X:/...")
# before the call -- never by disabling MSYS2's own conversion.
use strict;
use warnings;
use Cwd ();

# Almanac/ sits beside THIS FILE (not $0, not FindBin) -- see
# almanac-todo.pl's identical BEGIN block for the reasoning. This file was
# never hit by bug 75fe's doubled-join defect -- it only unshifts $dir onto
# @INC and loads siblings via bareword `use Module ();`, which resolves
# through perl's own @INC search rather than a manual string-concatenated
# require path, so a relative $dir already worked. __FILE__ is still
# resolved through Cwd::abs_path here, defensively and for consistency with
# the scripts that did have the defect (almanac-doctor.pl, almanac-inbox.pl),
# not because this file needed the fix.
BEGIN {
    my $dir = Cwd::abs_path(__FILE__);
    $dir =~ s{\\}{/}g;
    $dir =~ s{/[^/]+\z}{};
    $dir = '.' unless length $dir;
    unshift @INC, $dir;
}
use Almanac::Store ();
use Almanac::Record ();
use Encode ();
use Digest::SHA ();

our $VERSION = '1.0';

# =============================================================================
# Almanac::MigrateTodos::Error -- this script's own die payload, shaped
# exactly per spec S2.7's stderr contract: one prose line, then a
# two-space-indented machine block with kind/path/line/detail in that fixed
# order. An Almanac::Store::Error / Almanac::Record::Error is never wrapped
# in this class -- it is re-raised through Almanac::Record::fatal() as-is,
# so its own (differently-shaped) block passes through unchanged. Stringifies
# via overload so Almanac::Record::fatal() -- the single sanctioned exit()
# path, used uniformly for both this class and a passed-through Store/Record
# error -- can print it without special-casing the class.
# =============================================================================
package Almanac::MigrateTodos::Error;

use overload '""' => sub { $_[0]->{message} }, fallback => 1;

sub _tok {
    my ($v) = @_;
    return '-' unless defined $v && length("$v");
    (my $s = "$v") =~ s/[\s\x00-\x1f\x7f]+/_/g;
    return $s;
}

sub new {
    my ($class, %a) = @_;
    my $kind = $a{kind};
    my $block = "almanac-error:\n"
              . "  kind: "   . _tok($kind)      . "\n"
              . "  path: "   . _tok($a{path})   . "\n"
              . "  line: "   . _tok($a{line})   . "\n"
              . "  detail: " . _tok($a{detail}) . "\n";
    my $prose   = "almanac-migrate-todos: $kind\n";
    my $message = $prose . $block;
    return bless { %a, kind => $kind, message => $message, exit_code => 2 }, $class;
}

package main;

sub _fail {
    my ($kind, %a) = @_;
    die Almanac::MigrateTodos::Error->new(kind => $kind, %a);
}

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

# _decode_maybe($s) -> decoded character string -- see almanac-todo.pl's
# identical helper for why: Cwd::abs_path (reached indirectly via
# Almanac::Store) returns raw UTF-8 BYTES with no utf8 flag on this
# platform; printing that through STDOUT's single ':encoding(UTF-8)' layer
# unchanged would encode it a SECOND time (AC20's mojibake guard).
sub _decode_maybe {
    my ($s) = @_;
    return $s unless defined $s;
    return $s if utf8::is_utf8($s);
    my $d = eval { Encode::decode('UTF-8', $s, Encode::FB_CROAK()) };
    return defined $d ? $d : $s;
}

# _native_arg($s) -> a byte-string COPY suitable for a native Win32 argv
# slot. Downgrades a copy only, never the caller's own scalar (S2.5 of the
# oracle's own header applies equally to product code).
sub _native_arg {
    my ($s) = @_;
    return $s unless defined $s;
    my $copy = "$s";
    utf8::encode($copy) if utf8::is_utf8($copy);
    return $copy;
}

# _git_windows_path($p) -- POSIX mount spelling "/x/..." folded to drive
# form "X:/...", the one form git.exe resolves correctly regardless of
# whatever MSYS conversion state happens to be in effect (spec S2.5,
# "the git_path pattern, todo-sync.pl:386").
sub _git_windows_path {
    my ($p) = @_;
    return $p unless defined $p;
    (my $q = $p) =~ s{\\}{/}g;
    $q =~ s{^/([a-zA-Z])(?=/|\z)}{uc($1) . ':'}e;
    return $q;
}

# _git_rc(@args) -> ($rc, $stdout) -- list-form spawn, no shell. 127 (with
# empty output) when git itself cannot be started at all. A signal-killed
# git (exit status portion 0, but $? itself nonzero -- e.g. a SIGKILL/
# SIGTERM'd child) must never read as success: any nonzero $? maps to a
# nonzero rc, falling back to 1 when the exit-code byte itself is 0.
sub _git_rc {
    my (@args) = @_;
    my @native = map { _native_arg($_) } @args;
    my $ok = open(my $fh, '-|', 'git', @native);
    return (127, '') unless $ok;
    binmode($fh, ':raw');
    my $out = do { local $/; <$fh> };
    close $fh;
    my $raw = $?;
    my $rc  = ($raw == 0) ? 0 : (($raw >> 8) || 1);
    return ($rc, defined $out ? $out : '');
}

# _valid_id_grammar($id) -> 1 | 0 -- restates Almanac::Store's own id
# grammar (Store.pm _validate_id / :435) so a bad stem is diagnosed as this
# script's own `bad_id` kind before ever reaching Store->create.
sub _valid_id_grammar {
    my ($id) = @_;
    return 0 unless defined $id
        && length($id) <= 128
        && $id =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
        && $id !~ /\.\./
        && $id !~ /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\z/i;
    return 1;
}

sub _read_source_bytes {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or _fail('io', path => $path, detail => "$!");
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return defined $bytes ? $bytes : '';
}

# ---------------------------------------------------------------------------
# 2.2 -- source enumeration.
# ---------------------------------------------------------------------------
sub _enumerate {
    my ($vault) = @_;
    my @out;
    my $live_dir = "$vault/todos";
    if (-d $live_dir) {
        opendir(my $dh, $live_dir) or _fail('io', path => $live_dir, detail => "$!");
        my @entries = readdir($dh);
        closedir $dh;
        my @names = sort grep {
            /\A(.+)\.md\z/ && $_ ne 'README.md' && -f "$live_dir/$_"
        } @entries;
        for my $n (@names) {
            (my $stem = $n) =~ s/\.md\z//;
            push @out, { name => $stem, archived => 0, path => "$live_dir/$n", legacy_path => "todos/$n" };
        }
    }
    my $arch_dir = "$live_dir/archive";
    if (-d $arch_dir) {
        opendir(my $dh, $arch_dir) or _fail('io', path => $arch_dir, detail => "$!");
        my @entries = readdir($dh);
        closedir $dh;
        my @names = sort grep { /\A(.+)\.md\z/ && -f "$arch_dir/$_" } @entries;
        for my $n (@names) {
            (my $stem = $n) =~ s/\.md\z//;
            push @out, { name => $stem, archived => 1, path => "$arch_dir/$n", legacy_path => "todos/archive/$n" };
        }
    }
    return \@out;
}

# ---------------------------------------------------------------------------
# 2.3 / 2.4 -- strict legacy parse and mapping to the expected target record.
# ---------------------------------------------------------------------------
my %RESERVED_LEGACY_KEY = map { $_ => 1 } qw(id rank writer title archived legacy_path completed_at);

sub _parse_and_map_source {
    my ($src) = @_;
    my $path = $src->{path};
    my $bytes = _read_source_bytes($path);

    # rule 1: valid UTF-8, else bad_source at the line of the first invalid byte.
    my $tail = $bytes;
    my $text = eval { Encode::decode('UTF-8', $tail, Encode::FB_QUIET()) };
    if (!defined $text || length $tail) {
        my $offset = length($bytes) - length($tail);
        my $line = 1 + (substr($bytes, 0, $offset) =~ tr/\n//);
        _fail('bad_source', path => $path, line => $line, detail => 'not_utf8');
    }

    my @l = split /\n/, $text, -1;
    @l = ('') unless @l;

    # rule 2: line 1 must be a delimiter; frontmatter closes at the next one.
    _fail('bad_source', path => $path, line => 1, detail => 'no_frontmatter')
        unless $l[0] =~ /\A---\r?\z/;

    my $closing;
    for my $i (1 .. $#l) {
        if ($l[$i] =~ /\A---\r?\z/) { $closing = $i; last }
    }
    _fail('bad_source', path => $path, line => 1, detail => 'unterminated_frontmatter')
        unless defined $closing;

    # rule 3: field lines.
    my (%raw, @raw_order, %keyline, %seen);
    for my $i (1 .. $closing - 1) {
        my $line_no = $i + 1;
        my $line = $l[$i];
        if ($line =~ /\A([A-Za-z0-9_]+):[ \t]*(.*?)[ \t\r]*\z/) {
            my ($k, $v) = ($1, $2);
            if ($seen{$k}++) {
                _fail('bad_source', path => $path, line => $line_no, detail => 'duplicate_key');
            }
            if (Almanac::Record::has_forbidden_bytes($v)) {
                _fail('bad_source', path => $path, line => $line_no, detail => 'forbidden_bytes');
            }
            $raw{$k} = $v;
            push @raw_order, $k;
            $keyline{$k} = $line_no;
        } else {
            _fail('bad_source', path => $path, line => $line_no, detail => 'bad_field_line');
        }
    }

    # rule 4: body.
    my $body = ($closing == $#l) ? '' : join("\n", @l[$closing + 1 .. $#l]);

    # rule 5: title.
    my $title;
    for my $bline (split /\n/, $body) {
        if ($bline =~ /\A#[ \t]+(.+?)[ \t\r]*\z/) { $title = $1; last }
    }
    if (!defined $title) {
        (my $t = $src->{name}) =~ s/-/ /g;
        $title = ucfirst($t);
    }
    (my $title_trimmed = $title) =~ s/\A\s+//;
    $title_trimmed =~ s/\s+\z//;
    _fail('bad_source', path => $path, line => undef, detail => 'bad_title')
        if $title_trimmed eq '' || Almanac::Record::has_forbidden_bytes($title_trimmed);
    $title = $title_trimmed;

    # 2.4 mapping.
    my $id = $src->{name};
    _fail('bad_id', path => $path, line => undef, detail => $id)
        unless _valid_id_grammar($id);

    my $status = $raw{status};
    _fail('unsupported_status', path => $path, line => $keyline{status},
          detail => (defined $status ? $status : 'missing'))
        unless defined $status && ($status eq 'open' || $status eq 'done');

    my $created = $raw{created};
    _fail('missing_created', path => $path, line => $keyline{created}, detail => 'missing')
        unless defined $created && length $created;

    my %fields = (title => $title, status => $status, created => $created);

    if (exists $raw{tags}) {
        my $v = $raw{tags};
        if ($v =~ /\A\[(.*)\]\z/) {
            my $inner = $1;
            my @tok = grep { length } map {
                (my $s = $_) =~ s/\A\s+//; $s =~ s/\s+\z//; $s
            } split /,/, $inner;
            $fields{tags} = join(',', @tok) if @tok;
        } else {
            _fail('bad_source', path => $path, line => $keyline{tags}, detail => 'bad_tags');
        }
    }

    $fields{archived}    = $src->{archived} ? 'yes' : 'no';
    $fields{legacy_path}  = $src->{legacy_path};

    my @extra_order;
    for my $k (@raw_order) {
        next if $k eq 'status' || $k eq 'created' || $k eq 'tags';
        if ($RESERVED_LEGACY_KEY{$k}) {
            _fail('reserved_legacy_key', path => $path, line => $keyline{$k}, detail => $k);
        }
        $fields{$k} = $raw{$k};
        push @extra_order, $k;
    }

    my @order = (qw(title status created tags archived legacy_path), @extra_order);

    return {
        id     => $id,
        fields => \%fields,
        order  => \@order,
        body   => $body,
        sha    => Digest::SHA::sha256_hex($bytes),
    };
}

# ---------------------------------------------------------------------------
# 2.4 -- content comparison (never a count stand-in).
# ---------------------------------------------------------------------------
sub _record_matches {
    my ($target, $expected) = @_;
    my %t = %{ $target->{fields} };
    delete @t{qw(id writer rank)};
    my %e = %{ $expected->{fields} };

    return 0 unless scalar(keys %t) == scalar(keys %e);
    for my $k (keys %e) {
        return 0 unless exists $t{$k};
        my ($tv, $ev) = ($t{$k}, $e{$k});
        return 0 if (defined $tv) != (defined $ev);
        return 0 if defined($tv) && $tv ne $ev;
    }

    my $tb = defined($target->{body})   ? $target->{body}   : '';
    my $eb = defined($expected->{body}) ? $expected->{body} : '';
    return 0 unless $tb eq $eb;
    return 1;
}

# ---------------------------------------------------------------------------
# 2.5 -- git preconditions (only with --remove-sources and sources present).
# ---------------------------------------------------------------------------
sub _check_git_preconditions {
    my ($vault, $sources) = @_;
    my $vault_git = _git_windows_path($vault);

    my ($rc0) = _git_rc('-C', $vault_git, 'rev-parse', '--is-inside-work-tree');
    _fail('not_recoverable', path => $vault, detail => 'not_a_repo') if $rc0 != 0;

    for my $s (@$sources) {
        my ($rc1) = _git_rc('-C', $vault_git, 'ls-files', '--error-unmatch', '--', $s->{legacy_path});
        _fail('not_recoverable', path => $s->{legacy_path}, detail => 'untracked') if $rc1 != 0;
        my ($rc2) = _git_rc('-C', $vault_git, 'diff', '--quiet', 'HEAD', '--', $s->{legacy_path});
        _fail('not_recoverable', path => $s->{legacy_path}, detail => 'modified') if $rc2 != 0;

        # Review M1: `ls-files`/`diff --quiet` only prove the file is tracked
        # and clean AFTER git's own eol normalisation -- neither proves that
        # `git checkout <rev> -- todos` (the printed recover_cmd) would write
        # back the exact bytes this run parsed. `cat-file --filters` returns
        # precisely the bytes a checkout would produce (smudge filters, eol
        # conversion, everything), so hashing that output and comparing to
        # the parse-time sha is the one check that actually proves DC4's
        # recoverability claim.
        my ($rc4, $checkout_bytes) = _git_rc('-C', $vault_git, 'cat-file', '--filters', "HEAD:./$s->{legacy_path}");
        _fail('not_recoverable', path => $s->{legacy_path}, detail => 'checkout_not_byte_exact') if $rc4 != 0;
        _fail('not_recoverable', path => $s->{legacy_path}, detail => 'checkout_not_byte_exact')
            unless Digest::SHA::sha256_hex($checkout_bytes) eq $s->{expected}{sha};
    }

    my ($rc3, $out) = _git_rc('-C', $vault_git, 'rev-parse', 'HEAD');
    _fail('not_recoverable', path => $vault, detail => 'no_head') if $rc3 != 0;
    chomp $out;
    _fail('not_recoverable', path => $vault, detail => 'bad_sha') unless $out =~ /\A[0-9a-f]{40}\z/;
    return $out;
}

# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------
sub _print_header {
    my ($vault, $store, $mode) = @_;
    print "source_dir: " . _decode_maybe("$vault/todos") . "\n";
    print "target_dir: " . _decode_maybe($store->dir) . "\n";
    print "mode: $mode\n";
}

sub _print_todo_line {
    my ($s, $action) = @_;
    print "todo: $s->{expected}{id} $action $s->{legacy_path}\n";
}

sub _print_summary {
    my (%a) = @_;
    print "sources: $a{sources}\n";
    print "created: $a{created}\n";
    print "already: $a{already}\n";
    print "removed: $a{removed}\n";
    print "status: $a{status}\n";
    print "changed: $a{changed}\n";
    if (defined $a{recover_rev}) {
        print "recover_rev: $a{recover_rev}\n";
        print "recover_cmd: $a{recover_cmd}\n";
    }
}

# ---------------------------------------------------------------------------
# 2.1 -- argv grammar.
# ---------------------------------------------------------------------------
sub _parse_args {
    my (@argv) = @_;
    my %o;
    my @pos;
    while (@argv) {
        my $a = shift @argv;
        if ($a eq '--home' || $a eq '--vault') {
            my $has_val = @argv && $argv[0] !~ /^--/;
            _fail('usage', detail => 'missing_flag_value') unless $has_val;
            my $val = shift @argv;
            # Review minor #1 (M4 companion): an EMPTY value must never
            # silently fall through to ALMANAC_HOME/HOME/USERPROFILE (the
            # real vault on an operator's own machine) -- refuse outright.
            _fail('usage', detail => 'empty_flag_value') unless length($val);
            $o{ substr($a, 2) } = $val;
        } elsif ($a eq '--dry-run' || $a eq '--remove-sources') {
            $o{ substr($a, 2) } = 1;
        } elsif ($a =~ /^--/) {
            _fail('usage', detail => 'unknown_flag');
        } else {
            push @pos, $a;
        }
    }
    _fail('usage', detail => 'positional_argument') if @pos;
    return \%o;
}

# ---------------------------------------------------------------------------
# 2.8 -- the algorithm.
# ---------------------------------------------------------------------------
sub _run {
    my (@argv) = @_;
    my $o = _parse_args(@argv);

    my $store = Almanac::Store->open(scope => 'global', type => 'todo', home => $o->{home});

    (my $default_vault = $store->root) =~ s{/almanac\z}{};
    my $vault = defined($o->{vault}) ? $o->{vault} : $default_vault;
    $vault =~ s{\\}{/}g;
    $vault =~ s{/\z}{} if length($vault) > 1;

    my $mode = $o->{'dry-run'} ? 'dry-run' : 'run';

    my $sources = _enumerate($vault);
    for my $s (@$sources) {
        $s->{expected} = _parse_and_map_source($s);
    }

    # id collision, case-insensitive.
    my %seen_id;
    for my $s (@$sources) {
        my $key = lc($s->{expected}{id});
        _fail('id_collision', path => '-', detail => $s->{expected}{id}) if $seen_id{$key};
        $seen_id{$key} = 1;
    }

    my $recover_rev;
    if ($o->{'remove-sources'} && @$sources) {
        $recover_rev = _check_git_preconditions($vault, $sources);
    }

    # classify.
    for my $s (@$sources) {
        my $exp = $s->{expected};
        if (!$store->exists($exp->{id})) {
            $s->{action} = 'create';
        } else {
            my $target = $store->read($exp->{id});
            $s->{action} = _record_matches($target, $exp) ? 'already' : 'conflict';
        }
    }

    if (grep { $_->{action} eq 'conflict' } @$sources) {
        _print_header($vault, $store, $mode);
        my %LABEL = (create => 'would-create', already => 'already-migrated', conflict => 'conflict');
        _print_todo_line($_, $LABEL{ $_->{action} }) for @$sources;
        my ($first) = grep { $_->{action} eq 'conflict' } @$sources;
        _fail('conflict', path => $first->{path}, detail => $first->{expected}{id});
    }

    if (!@$sources) {
        # Minor (review): $store->list() runs recover() first, which rolls
        # back a pending .reorder-journal.json -- a WRITE, even under
        # --dry-run. This probe only needs to know whether any record
        # carries legacy_path, so ids()+read() (never list()) keeps this
        # branch write-free in every mode.
        my $any_legacy = 0;
        for my $id (@{ $store->ids }) {
            my $rec = $store->read($id);
            if (defined $rec->{fields}{legacy_path}) { $any_legacy = 1; last }
        }
        _print_header($vault, $store, $mode);
        if ($any_legacy) {
            _print_summary(sources => 0, created => 0, already => 0, removed => 0,
                            status => 'already-migrated', changed => 'no');
            return;
        }
        _fail('no_sources', path => $vault, detail => 'empty');
    }

    if ($o->{'dry-run'}) {
        _print_header($vault, $store, $mode);
        my %LABEL = (create => 'would-create', already => 'already-migrated');
        _print_todo_line($_, $LABEL{ $_->{action} }) for @$sources;
        if ($o->{'remove-sources'}) {
            print "would-remove: $_->{legacy_path}\n" for @$sources;
        }
        my $already = scalar(grep { $_->{action} eq 'already' } @$sources);
        my %sum = (sources => scalar(@$sources), created => 0, already => $already,
                   removed => 0, status => 'dry-run', changed => 'no');
        if (defined $recover_rev) {
            (my $decoded_vault = _decode_maybe($vault));
            $sum{recover_rev} = $recover_rev;
            $sum{recover_cmd} = "git -C $decoded_vault checkout $recover_rev -- todos";
        }
        _print_summary(%sum);
        return;
    }

    # real run: create the absent ones.
    my ($created_count, $already_count) = (0, 0);
    for my $s (@$sources) {
        my $exp = $s->{expected};
        if ($s->{action} eq 'create') {
            my $ok = eval {
                $store->create(id => $exp->{id}, fields => $exp->{fields}, order => $exp->{order}, body => $exp->{body});
                1;
            };
            if (!$ok) {
                my $err = $@;
                if (ref($err) eq 'Almanac::Store::Error' && $err->{kind} eq 'exists') {
                    my $target = $store->read($exp->{id});
                    if (_record_matches($target, $exp)) {
                        $s->{final_action} = 'already-migrated';
                        $already_count++;
                    } else {
                        _print_header($vault, $store, $mode);
                        my %LABEL = (create => 'would-create', already => 'already-migrated', conflict => 'conflict');
                        for my $t (@$sources) {
                            my $lbl = defined($t->{final_action}) ? $t->{final_action}
                                    : ($t == $s ? 'conflict' : $LABEL{ $t->{action} });
                            _print_todo_line($t, $lbl);
                        }
                        _fail('conflict', path => $s->{path}, detail => $exp->{id});
                    }
                } else {
                    die $err;
                }
            } else {
                $s->{final_action} = 'created';
                $created_count++;
            }
        } else {
            $s->{final_action} = 'already-migrated';
            $already_count++;
        }
    }

    # verify every source's target, by content -- never by count.
    for my $s (@$sources) {
        my $exp = $s->{expected};
        my $target = $store->read($exp->{id});
        _fail('verify_failed', path => $target->{path}, detail => $exp->{id})
            unless _record_matches($target, $exp);
    }

    # Review M3: everything the operator needs to recover -- the full
    # source list (every todo: line) and recover_rev/recover_cmd -- must
    # already be on stdout BEFORE the first unlink is even attempted. A
    # failure (or a kill) mid-removal-loop must not lose the recovery
    # record for files already removed, or for files never reached. This
    # deliberately departs from spec S2.6's line order (accepted as a
    # spec-note-worthy deviation, per the review).
    _print_header($vault, $store, $mode);
    for my $s (@$sources) {
        _print_todo_line($s, $s->{final_action});
    }
    my $decoded_vault;
    if (defined $recover_rev) {
        $decoded_vault = _decode_maybe($vault);
        print "recover_rev: $recover_rev\n";
        print "recover_cmd: git -C $decoded_vault checkout $recover_rev -- todos\n";
    }

    # remove, only after verification, only what is still unchanged. Each
    # removed: line is printed immediately after its own unlink, never
    # batched, so a mid-loop failure still leaves every already-successful
    # removal's line (and the recovery info above) on stdout.
    my $removed_count = 0;
    if ($o->{'remove-sources'}) {
        for my $s (@$sources) {
            my $bytes = _read_source_bytes($s->{path});
            my $sha = Digest::SHA::sha256_hex($bytes);
            if ($sha eq $s->{expected}{sha}) {
                unlink($s->{path}) or _fail('io', path => $s->{path}, detail => "$!");
                print "removed: $s->{legacy_path}\n";
                $removed_count++;
            } else {
                _fail('source_changed', path => $s->{path}, detail => 'changed');
            }
        }
    }

    my $status  = ($created_count > 0 || $removed_count > 0) ? 'migrated' : 'already-migrated';
    my $changed = ($created_count > 0 || $removed_count > 0) ? 'yes' : 'no';
    _print_summary(sources => scalar(@$sources), created => $created_count, already => $already_count,
                    removed => $removed_count, status => $status, changed => $changed);
    return;
}

# ---------------------------------------------------------------------------
# CLI entry point.
# ---------------------------------------------------------------------------
unless (caller) {
    binmode(STDOUT, ':encoding(UTF-8)');
    # Review M3: every print must actually reach the pipe/file before a
    # later failure or kill, never sit in a buffer -- autoflush, not a
    # one-off flush() call, so this holds for every print() in _run().
    $| = 1;
    my $ok = eval {
        _run(@ARGV);
        1;
    };
    unless ($ok) {
        Almanac::Record::fatal($@);
    }
    exit 0;
}

1;
