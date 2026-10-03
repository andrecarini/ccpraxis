#!/usr/bin/env perl
# platform: windows
# blueprint operator-ui-tweaks, package 01-statusline-counters
# (specs/01-statusline-counters-spec.md). Written BLIND to
# scripts/statusline.pl and plugins/sandbox/scripts/Theme.pm's counters
# code: every expectation below comes from the spec, so this file is an
# oracle rather than an echo of whatever the implementer eventually writes.
# Do NOT weaken an assertion to make a future implementation's life easier.
#
# Coverage: spec section 4, AC-1 .. AC-14 (AC-12 is exercised by the edited
# existing test files, not here).
#
# Conventions copied from plugins/sandbox/tests/t/statusline-rebuild.t
# (never `require`d -- this file stands alone):
#   * mk_proj/mk_home tempdirs, seed_* via the almanac modules, a
#     blueprints dir under CCPRAXIS_DATA_DIR.
#   * the tput/git shims, a scrubbed HOME, a timeout-bounded spawn.
#   * never the real ~/.claude, the vault, or .ccpraxis-local-data.
#
# spec section 4 warns that statusline-rebuild.t's counter_seg() cuts at the
# first two-space run, so it would return the blueprint glyph alone (its own
# segment ends in a two-space join by design). This file never uses
# counter_seg: fields are extracted with sep_fields()-style splitting or
# exact-substring checks instead.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir tempfile);
use JSON::PP qw(decode_json encode_json);
use Encode qw(encode decode);
use Cwd ();
use POSIX ();
use File::Path qw(make_path);

use_ok('Theme') or BAIL_OUT('Theme.pm did not load');

my $STATUSLINE   = "$Bin/../../../../scripts/statusline.pl";
my $README       = "$Bin/../../../../README.md";
my $ALMANAC_DIR  = "$Bin/../../../almanac/scripts";

# ===========================================================================
# Scaffolding
# ===========================================================================

sub slurp_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $s = <$fh>;
    close $fh;
    return defined($s) ? $s : '';
}
sub spew_raw {
    my ($path, $bytes) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print {$fh} $bytes;
    close $fh;
    return $path;
}

sub strip_sgr { my $s = shift; $s = '' unless defined $s; $s =~ s/\033\[[^m]*m//g; return $s }
sub first_line { my $s = shift; $s = '' unless defined $s; my ($l) = split /\n/, $s, 2; return defined($l) ? $l : '' }

my $SEPBAR_CP    = 0xFF5C;
my $SEPBAR_BYTES = Theme::glyph('sep.bar');
my $SEPBAR_COLS  = Theme::glyph_width('sep.bar');
my %ORACLE_COLS  = ($SEPBAR_CP => (defined($SEPBAR_COLS) ? $SEPBAR_COLS : 2));

sub col_cost {
    my ($bytes) = @_;
    my $s = strip_sgr($bytes);
    my $dec = decode('UTF-8', $s, Encode::FB_DEFAULT);
    my $cols = 0;
    $cols += ($ORACLE_COLS{ ord($_) } // 1) for split //, $dec;
    return $cols;
}
sub row_cost {
    my ($bytes) = @_;
    my $s = strip_sgr($bytes);
    my $b = length($s);
    my $c = col_cost($bytes);
    return $c > $b ? $c : $b;
}

# sep_fields($line_bytes) -> the SGR-stripped row split on the rendered
# " | " separator. Field 0 is the marker.
my $SEP_RENDERED = " " . $SEPBAR_BYTES . " ";
sub sep_fields {
    my ($line) = @_;
    my $s = strip_sgr($line);
    return split /\Q$SEP_RENDERED\E/, $s, -1;
}
sub field_at {
    my ($line, $idx) = @_;
    my @f = sep_fields($line);
    return $idx <= $#f ? $f[$idx] : undef;
}
sub _is_context_field { my $f = shift; return (defined $f && $f =~ /\d+%/ && $f =~ /\d+k|\dM/) ? 1 : 0 }
sub _is_budget_field  { my $f = shift; return (defined $f && $f =~ /\b(?:5h|7d)\b/)            ? 1 : 0 }
sub project_field {
    my ($line) = @_;
    my @f = sep_fields($line);
    for my $i (1 .. $#f) {
        next if _is_context_field($f[$i]) || _is_budget_field($f[$i]);
        return $f[$i];
    }
    return undef;
}

# --- shims (mirrors statusline-rebuild.t F-tput, F-git) ---------------------
my $SHIM_DIR = tempdir(CLEANUP => 1);
sub make_tput {
    my ($cols) = @_;
    spew_raw("$SHIM_DIR/tput", "#!/bin/sh\necho $cols\n");
    chmod 0755, "$SHIM_DIR/tput";
}
sub make_git {
    my (%opt) = @_;
    my $top    = $opt{toplevel};
    my $branch = $opt{branch};
    my $topfile = "$SHIM_DIR/toplevel.txt";
    my $brfile  = "$SHIM_DIR/branch.txt";
    unlink $topfile, $brfile;
    spew_raw($topfile, $top)    if defined($top)    && length($top);
    spew_raw($brfile,  $branch) if defined($branch) && length($branch);
    my $sh = <<'SH';
#!/bin/sh
d=$(dirname "$0")
want=""
for a in "$@"; do
  case "$a" in
    --show-toplevel) want=toplevel ;;
    --abbrev-ref)    want=branch ;;
  esac
done
case "$want" in
  toplevel) if [ -s "$d/toplevel.txt" ]; then cat "$d/toplevel.txt"; echo; exit 0; fi; exit 1 ;;
  branch)   if [ -s "$d/branch.txt" ];   then cat "$d/branch.txt";   echo; exit 0; fi; exit 1 ;;
esac
exit 1
SH
    spew_raw("$SHIM_DIR/git", $sh);
    chmod 0755, "$SHIM_DIR/git";
}

my $FAKE_ROOT = tempdir(CLEANUP => 1);
$FAKE_ROOT =~ s{\\}{/}g;
mkdir "$FAKE_ROOT/.git" or die "fixture setup: cannot mkdir $FAKE_ROOT/.git: $!";
my $WROOT = "$FAKE_ROOT/w";

my @SCRUB_ENV = qw(CLAUDE_PROJECT_DIR ALMANAC_HOME ALMANAC_SURFACE BUTLER_STATE_DIR);

my $CLEAN_HOME = tempdir(CLEANUP => 1);
my $CLEAN_DATA = tempdir(CLEANUP => 1);

sub payload_for {
    my (%opt) = @_;
    my %p = (
        model          => { display_name => 'Claude Sonnet 5', id => 'claude-sonnet-5' },
        workspace      => { current_dir  => $opt{current_dir} // "$WROOT/proj-alpha" },
        context_window => { used_percentage => 10, context_window_size => 200_000 },
    );
    $p{session_id} = $opt{session_id} if defined $opt{session_id};
    return \%p;
}

sub run_statusline {
    my ($payload, %opt) = @_;
    make_tput($opt{cols} // 80);
    make_git(toplevel => $opt{toplevel}, branch => $opt{branch});

    my ($infh, $inpath) = tempfile();
    binmode $infh, ':raw';
    print {$infh} encode_json($payload);
    close $infh;

    local %ENV = %ENV;
    $ENV{PATH} = "$SHIM_DIR:$ENV{PATH}";
    $ENV{HOME} = $opt{home} // $CLEAN_HOME;
    $ENV{USERPROFILE} = $ENV{HOME};
    delete $ENV{$_} for @SCRUB_ENV;
    $ENV{CCPRAXIS_DATA_DIR} = $opt{data} // $CLEAN_DATA;
    if ($opt{sandbox}) { $ENV{CCPRAXIS_SANDBOX} = '1' } else { delete $ENV{CCPRAXIS_SANDBOX} }
    for my $k (sort keys %{ $opt{env} || {} }) {
        if (defined $opt{env}{$k}) { $ENV{$k} = $opt{env}{$k} } else { delete $ENV{$k} }
    }
    if (defined $opt{state}) { $ENV{BUTLER_STATE_DIR} = $opt{state} }

    my $prev_cwd = Cwd::getcwd();
    chdir($opt{pcwd} // $FAKE_ROOT) or die "fixture setup: cannot chdir: $!";
    my $out = `timeout 20 perl "$STATUSLINE" < "$inpath" 2>/dev/null`;
    my $rc  = $? >> 8;
    chdir($prev_cwd) or die "fixture teardown: cannot chdir back to $prev_cwd: $!";
    return (defined($out) ? $out : '', $rc);
}

sub nslash { my ($p) = @_; $p =~ s{\\}{/}g; $p =~ s{/\z}{} if length($p) > 1; return $p }
sub mk_proj {
    my ($leaf) = @_;
    my $base = nslash(tempdir(CLEANUP => 1));
    my $d = defined($leaf) ? "$base/$leaf" : $base;
    make_path("$d/.git");
    return $d;
}
sub mk_home {
    my $h = nslash(tempdir(CLEANUP => 1));
    make_path("$h/.claude");
    return $h;
}

my $ALMANAC_OK = eval {
    require "$ALMANAC_DIR/almanac-todo.pl";
    require "$ALMANAC_DIR/almanac-note.pl";
    require "$ALMANAC_DIR/almanac-inbox.pl";
    require "$ALMANAC_DIR/Almanac/Thread.pm";   # package 12-statusline-threads: the thread counter
    1;
};
diag("almanac modules did not load: $@") unless $ALMANAC_OK;

sub with_host_policy {
    my ($code) = @_;
    no warnings 'once';
    local $Almanac::Store::SCOPE_POLICY{container} = $Almanac::Store::SCOPE_POLICY{host};
    return $code->();
}
sub _where { my ($scope, $where) = @_; return $scope eq 'project' ? (root => $where) : (home => $where) }

my $FIXTURE_ISO = '2026-09-26T00:00:00Z';
my $fixture_seq = 0;

sub seed_todos {
    my ($scope, $where, $n_open, $n_done) = @_;
    with_host_policy(sub {
        my $s = Almanac::Todo::open_store($scope, _where($scope, $where));
        for my $st (('open') x $n_open, ('done') x $n_done) {
            $s->create(fields => { title => 'todo ' . (++$fixture_seq), status => $st, created => $FIXTURE_ISO },
                       order  => [qw(title status created)]);
        }
    });
}
sub seed_notes {
    my ($scope, $where, $n) = @_;
    with_host_policy(sub {
        my $s = Almanac::Note::open_store($scope, _where($scope, $where));
        for (1 .. $n) {
            my $k = ++$fixture_seq;
            $s->create(fields => { title => "note $k", audience => 'internal',
                                   target => "notes/note-$k.md", created => $FIXTURE_ISO },
                       order  => [qw(title audience target created)]);
        }
    });
}
# seed_threads($root, $n_live, $n_handed_off, $n_archived) -- package
# 12-statusline-threads replaces the flat tasklist counter with a thread
# counter: project.thread counts records in thread/ with state live or
# handed-off (archived is never counted). Each thread is empty (no tasks);
# thread_is_done requires at least one task, so an empty thread never
# auto-archives on creation (Decision 37's landmine does not apply here).
sub seed_threads {
    my ($root, $n_live, $n_handed_off, $n_archived) = @_;
    $n_live //= 0; $n_handed_off //= 0; $n_archived //= 0;
    with_host_policy(sub {
        for (1 .. $n_live) {
            Almanac::Thread::create_thread('live-' . (++$fixture_seq), root => $root);
        }
        for (1 .. $n_handed_off) {
            my $name = 'handed-' . (++$fixture_seq);
            Almanac::Thread::create_thread($name, root => $root);
            Almanac::Thread::record_event($name, 'handed-off', root => $root, reason => 'fixture handoff');
        }
        for (1 .. $n_archived) {
            my $name = 'archived-' . (++$fixture_seq);
            Almanac::Thread::create_thread($name, root => $root);
            Almanac::Thread::archive($name, root => $root);
        }
    });
}
sub seed_decisions {
    my ($root, $n_unanswered, $n_answered) = @_;
    Almanac::Inbox::file(root => $root, title => 'decision ' . (++$fixture_seq)) for 1 .. $n_unanswered;
    for (1 .. $n_answered) {
        my $rec = Almanac::Inbox::file(root => $root, title => 'decision ' . (++$fixture_seq));
        Almanac::Inbox::answer($rec->{id}, root => $root, answer => 'yes, go ahead');
    }
}
sub seed_blueprint {
    my ($data, $name) = @_;
    $name //= 'demo';
    make_path("$data/blueprints/$name");
    spew_raw("$data/blueprints/$name/blueprint.md", "# $name\n");
}

# render(%o) -> ($stdout_bytes, $rc). o: proj (current_dir default), cwd,
# home, sandbox, sid, cols (default 200), data, state, env, pcwd, toplevel,
# branch.
sub render {
    my (%o) = @_;
    my %env = %{ $o{env} || {} };
    return run_statusline(
        payload_for(current_dir => ($o{cwd} // $o{proj} // "$WROOT/nowhere"), session_id => $o{sid}),
        cols => $o{cols} // 200, sandbox => ($o{sandbox} ? 1 : 0),
        home => $o{home} // mk_home(), data => $o{data} // $CLEAN_DATA,
        toplevel => $o{toplevel}, branch => $o{branch}, state => $o{state},
        env => \%env, (defined $o{pcwd} ? (pcwd => $o{pcwd}) : ()));
}

# --- glyphs and colours, as BYTES ------------------------------------------
my $G_BLUEPRINT = encode('UTF-8', chr(0x29C9));
my $G_TODO      = encode('UTF-8', chr(0x274F));
my $G_NOTE      = encode('UTF-8', chr(0x2630));
my $G_THREAD    = encode('UTF-8', chr(0x23E3));   # package 12-statusline-threads: replaces the retired G_TASK (0x25A3)
my $G_FLAG      = encode('UTF-8', chr(0x2691));
my $G_AGENTOFF  = encode('UTF-8', chr(0x2205));
my $G_DOT       = encode('UTF-8', chr(0x00B7));
my $G_HOLLOW    = encode('UTF-8', chr(0x25CB));

sub fg_sgr { my $rgb = Theme::roles()->{ $_[0] }{rgb}; return sprintf("\e[38;2;%d;%d;%dm", @$rgb) }
sub bg_sgr { my $rgb = Theme::roles()->{ $_[0] }{bg};  return sprintf("\e[48;2;%d;%d;%dm", @$rgb) }
my $WBG = bg_sgr('overlay.warn');
my $WFG = fg_sgr('overlay.warn');
my $MUTED = fg_sgr('text.muted');
my $PRIMARY = fg_sgr('text.primary');
my $FAINT = fg_sgr('text.faint');
my $R = "\e[0m";

my $WELL_FORMED = qr/\e(?:\[[0-9;:?]*[ -\/]*[\@-~]|[\@-_])/;
sub no_malformed_escape {
    my ($bytes) = @_;
    my $scan = $bytes;
    $scan =~ s/$WELL_FORMED//g;
    return index($scan, "\e") < 0;
}

# parse_glyph_cols($code) -> hashref { codepoint => columns } read out of the
# inline %GLYPH_COLS declaration.
sub _balanced {
    my ($s, $start, $open, $close) = @_;
    return undef unless defined $start;
    my $i = index($s, $open, $start);
    return undef if $i < 0;
    my $depth = 0;
    for (my $j = $i; $j < length($s); $j++) {
        my $c = substr($s, $j, 1);
        if ($c eq $open) { $depth++ }
        elsif ($c eq $close) { $depth--; return substr($s, $i + 1, $j - $i - 1) if $depth == 0 }
    }
    return undef;
}
sub parse_glyph_cols {
    my ($code) = @_;
    return undef unless $code =~ /%GLYPH_COLS\s*=\s*/g;
    my $body = _balanced($code, pos($code), '(', ')');
    $body = _balanced($code, pos($code), '{', '}') unless defined $body;
    return undef unless defined $body;
    my %t;
    while ($body =~ /(0x[0-9A-Fa-f]+|\d+)\s*(?:=>|,)\s*(\d+)/g) {
        my ($k, $v) = ($1, $2);
        my $cp = ($k =~ /^0x/i) ? hex($k) : 0 + $k;
        $t{$cp} = 0 + $v;
    }
    return \%t;
}
my %THEME_WIDTH_BY_CP;
{
    my $g = Theme::glyphs();
    for my $name (keys %$g) { $THEME_WIDTH_BY_CP{ $g->{$name}{cp} } = $g->{$name}{width} }
}
my %GLYPH_COLS_NOT_IN_THEME = (0x3000 => 'ideographic space, row 2 padding, not a Theme glyph');
sub glyph_cols_disagreements {
    my ($table) = @_;
    my @bad;
    for my $cp (sort { $a <=> $b } keys %{ $table || {} }) {
        if (!exists $THEME_WIDTH_BY_CP{$cp}) {
            push @bad, sprintf('U+%04X: undeclared in Theme, not excused', $cp)
                unless exists $GLYPH_COLS_NOT_IN_THEME{$cp};
            next;
        }
        push @bad, sprintf('U+%04X: table %d, Theme %d', $cp, $table->{$cp}, $THEME_WIDTH_BY_CP{$cp})
            if $table->{$cp} != $THEME_WIDTH_BY_CP{$cp};
    }
    return @bad;
}

# ===========================================================================
# Shared fixtures
# ===========================================================================
my ($P_FULL, $H_FULL) = (mk_proj(), mk_home());
my $DATA_FULL = tempdir(CLEANUP => 1);
if ($ALMANAC_OK) {
    seed_todos('project', $P_FULL, 5, 2);
    seed_notes('project', $P_FULL, 2);
    seed_threads($P_FULL, 1, 1, 1);   # 1 live + 1 handed-off count (P=2); 1 archived is excluded
    seed_decisions($P_FULL, 2, 1);
    seed_todos('global', $H_FULL, 3, 1);
    seed_notes('global', $H_FULL, 1);
    seed_blueprint($DATA_FULL, 'demo');
}

# ===========================================================================
# AC-1 (behaviour 1) -- the last field, exactly.
# ===========================================================================
SKIP: {
    skip('almanac modules did not load', 3) unless $ALMANAC_OK;
    my ($out, $rc) = render(proj => $P_FULL, home => $H_FULL, data => $DATA_FULL);
    is($rc, 0, 'AC-1 setup: a fully populated host render exits 0') or diag($out);
    my $row = first_line($out);
    my @fields = sep_fields($row);
    my $last = @fields ? $fields[-1] : '';
    my $want = "${G_FLAG} 2  ${G_BLUEPRINT} 1  ${G_THREAD} 2  ${G_TODO} 5${G_DOT}3  ${G_NOTE}2${G_DOT}1";
    is($last, $want,
        'AC-1 (behaviour 1, package 12-statusline-threads AC7): the last field is exactly the decisions/blueprints/thread/todos/notes join')
        or diag("  last field = [$last]\n  row 1 = [" . strip_sgr($row) . "]");
    unlike($last, qr/   /, 'AC-1: the counters field never contains 3+ consecutive spaces');
}

# ===========================================================================
# AC-2 (behaviour 4) -- subsets of zero counters.
# ===========================================================================
SKIP: {
    skip('almanac modules did not load', 10) unless $ALMANAC_OK;

    # {decisions, notes}: 1 unanswered decision, 0 blueprints, 0 tasks,
    # 0 todos, 1 project note (no global note).
    {
        my $P = mk_proj();
        seed_decisions($P, 1, 0);
        seed_notes('project', $P, 1);
        my ($out) = render(proj => $P, home => mk_home());
        my $last = (sep_fields(first_line($out)))[-1] // '';
        is($last, "${G_FLAG} 1  ${G_NOTE}1", 'AC-2: {decisions, notes} -> "U+2691 1  U+2630 1"');
        ok($last !~ /\A\s|\s\z/, 'AC-2: {decisions, notes} has no leading/trailing space');
        ok($last !~ /   /, 'AC-2: {decisions, notes} has no 3-space run');
    }

    # {blueprints, todos}: 0 decisions, 1 blueprint, 0 tasks, 2 todos
    # (project only), 0 notes.
    {
        my $P = mk_proj();
        seed_todos('project', $P, 2, 0);
        my $data = tempdir(CLEANUP => 1);
        seed_blueprint($data, 'bp');
        my ($out) = render(proj => $P, home => mk_home(), data => $data);
        my $last = (sep_fields(first_line($out)))[-1] // '';
        is($last, "${G_BLUEPRINT} 1  ${G_TODO} 2", 'AC-2: {blueprints, todos} -> "U+29C9 1  U+274F 2"');
        ok($last !~ /\A\s|\s\z/, 'AC-2: {blueprints, todos} has no leading/trailing space');
        ok($last !~ /   /, 'AC-2: {blueprints, todos} has no 3-space run');
    }

    # {todos only}: everything else 0.
    {
        my $P = mk_proj();
        seed_todos('project', $P, 2, 0);
        my ($out) = render(proj => $P, home => mk_home());
        my $last = (sep_fields(first_line($out)))[-1] // '';
        is($last, "${G_TODO} 2", 'AC-2: {todos only} -> "U+274F 2"');
        ok($last !~ /\A\s|\s\z/, 'AC-2: {todos only} has no leading/trailing space');
        ok($last !~ /   /, 'AC-2: {todos only} has no 3-space run');
    }
}

# ===========================================================================
# AC-3 / AC-4 -- field 0 carries no U+2691, with and without a badge.
# ===========================================================================
SKIP: {
    skip('almanac modules did not load', 6) unless $ALMANAC_OK;
    my ($out) = render(proj => $P_FULL, home => $H_FULL, data => $DATA_FULL);
    my $row = first_line($out);
    is(field_at($row, 0), "$G_HOLLOW HOST", 'AC-3: field 0 is exactly "U+25CB HOST"');
    ok(index(field_at($row, 0), $G_FLAG) < 0, 'AC-3: U+2691 is absent from field 0');

    # AC-4: raw row 1 contains the exact warn-background flag byte sequence,
    # not followed by a digit.
    my $flag_raw = "${WBG}${WFG}${G_FLAG} 2${R}";
    ok(index($row, $flag_raw) >= 0, 'AC-4: raw row 1 contains WBG.WFG."U+2691 2".R')
        or diag("  row 1 raw = [$row]");
    ok($row !~ /\Q$flag_raw\E\d/, 'AC-4: that substring is not followed by a digit');

    # AC-3 with an agent-off badge fixture.
    my $sid = 'sess-counters-badge';
    my $state = nslash(tempdir(CLEANUP => 1));
    make_path("$state/continuity/off");
    spew_raw("$state/continuity/off/$sid",
        JSON::PP->new->canonical->encode({ actor => 'agent', at => '2026-09-26T00:00:00Z',
                                            reason => 'paused for the operator', session_id => $sid }) . "\n");
    my ($out2) = render(proj => $P_FULL, home => $H_FULL, data => $DATA_FULL, sid => $sid, state => $state);
    my $row2 = first_line($out2);
    is(field_at($row2, 0), "$G_HOLLOW HOST $G_AGENTOFF", 'AC-3: with an agent-off badge, field 0 is "U+25CB HOST U+2205"');
    ok(index(field_at($row2, 0), $G_FLAG) < 0, 'AC-3: U+2691 is absent from field 0 even with a badge');
}

# ===========================================================================
# AC-5 -- 0 unanswered decisions: U+2691 nowhere in stdout.
# ===========================================================================
SKIP: {
    skip('almanac modules did not load', 2) unless $ALMANAC_OK;
    my $P_ANS = mk_proj();
    seed_decisions($P_ANS, 0, 1);
    my ($out) = render(proj => $P_ANS, home => mk_home());
    is(index($out, $G_FLAG), -1, 'AC-5: an answered-only decision store shows no U+2691 anywhere in stdout');

    my $P_NONE = mk_proj();
    my ($out2) = render(proj => $P_NONE, home => mk_home());
    is(index($out2, $G_FLAG), -1, 'AC-5: no decision store at all shows no U+2691 anywhere in stdout');
}

# ===========================================================================
# AC-6 -- blueprint counter, exactly one space.
# ===========================================================================
SKIP: {
    skip('almanac modules did not load', 3) unless $ALMANAC_OK;
    my $P = mk_proj();
    my $data = tempdir(CLEANUP => 1);
    seed_blueprint($data, 'one');
    my ($out) = render(proj => $P, home => mk_home(), data => $data);
    my $row = first_line($out);
    my $raw_seg = "${MUTED}${G_BLUEPRINT} ${R}${PRIMARY}1${R}";
    ok(index($row, $raw_seg) >= 0, 'AC-6: raw row 1 contains MUTED."U+29C9 ".R.PRIMARY."1".R (one space)')
        or diag("  row 1 raw = [$row]");
    my $vis = strip_sgr($row);
    ok(index($vis, "${G_BLUEPRINT} 1") >= 0, 'AC-6: stripped text contains "U+29C9 1" (one space)');
    ok($vis !~ /\Q$G_BLUEPRINT\E 1\d/ && $vis !~ /\Q$G_BLUEPRINT\E   /,
        'AC-6: neither "U+29C9 1" (one space, digit-adjacent) nor a 3-space run follows the glyph');
}

# ===========================================================================
# AC-7 -- notes: no space between glyph and first number.
# ===========================================================================
SKIP: {
    skip('almanac modules did not load', 3) unless $ALMANAC_OK;
    my $P = mk_proj();
    seed_notes('project', $P, 2);
    my $H = mk_home();
    seed_notes('global', $H, 1);
    my ($out) = render(proj => $P, home => $H);
    my $row = first_line($out);
    my $raw_seg = "${MUTED}${G_NOTE}${R}${PRIMARY}2${R}${FAINT}${G_DOT}${R}${MUTED}1${R}";
    ok(index($row, $raw_seg) >= 0,
        'AC-7: raw MUTED."U+2630".R.PRIMARY."2".R.FAINT."U+00B7".R.MUTED."1".R')
        or diag("  row 1 raw = [$row]");

    my $P2 = mk_proj();
    seed_notes('project', $P2, 2);
    my ($out2) = render(proj => $P2, home => mk_home());
    my $vis2 = strip_sgr(first_line($out2));
    ok(index($vis2, "${G_NOTE}2") >= 0, 'AC-7: project-only case: stripped field contains "U+2630 2" with no space');

    my $vis1 = strip_sgr($row);
    my $space_glyph = $G_NOTE . ' ';
    ok(index($vis1, $space_glyph) < 0, 'AC-7: stripped text never contains U+2630 followed by a space');
}

# ===========================================================================
# AC-8 -- the todo glyph is U+274F, declared consistently everywhere.
# ===========================================================================
SKIP: {
    skip('almanac modules did not load', 2) unless $ALMANAC_OK;
    my $P = mk_proj();
    seed_todos('project', $P, 1, 0);
    my ($out) = render(proj => $P, home => mk_home());
    ok(index($out, $G_TODO) >= 0, 'AC-8: stdout contains the U+274F bytes');
    my $old_glyph = encode('UTF-8', chr(0x22EE));
    is(index($out, $old_glyph), -1, 'AC-8: stdout contains no U+22EE bytes');
}
{
    my $g = Theme::glyphs();
    ok(exists $g->{'icon.todos'}, 'AC-8: Theme::glyphs() declares icon.todos');
  SKIP: {
        skip('icon.todos missing', 2) unless exists $g->{'icon.todos'};
        is($g->{'icon.todos'}{cp}, 0x274F, 'AC-8: Theme.pm icon.todos codepoint is U+274F');
        is($g->{'icon.todos'}{width}, 1, 'AC-8: Theme.pm icon.todos width is 1');
    }
    ok(chr(0x274F) !~ /\p{Emoji}/, 'AC-8: U+274F does not carry the Emoji property on this perl');

    my $src = slurp_raw($STATUSLINE);
    my $table = parse_glyph_cols($src);
    ok(defined($table), 'AC-8: statusline.pl declares an inline %GLYPH_COLS table')
        or diag('source did not parse a %GLYPH_COLS table');
  SKIP: {
        skip('no %GLYPH_COLS table parsed', 3) unless defined $table;
        is($table->{0x274F}, 1, 'AC-8: %GLYPH_COLS declares 0x274F => 1');
        ok(!exists $table->{0x22EE}, 'AC-8: %GLYPH_COLS no longer declares 0x22EE');
        my @drift = glyph_cols_disagreements($table);
        ok(scalar(@drift) == 0, 'AC-8: every %GLYPH_COLS entry agrees with Theme (documented U+3000 exception aside)')
            or diag('  drift: ' . join('; ', @drift));
    }
}

# ===========================================================================
# AC-9 -- zero-project dim rendering, no dot; non-zero rendering, as before.
# ===========================================================================
SKIP: {
    skip('almanac modules did not load', 2) unless $ALMANAC_OK;
    my $P_EMPTY = mk_proj();
    my $H = mk_home();
    seed_todos('global', $H, 3, 0);
    seed_notes('global', $H, 1);
    my ($out) = render(proj => $P_EMPTY, home => $H);
    my $row = first_line($out);
    my $todo_raw = "${FAINT}${G_TODO}${R} ${FAINT}3${R}";
    my $note_raw = "${FAINT}${G_NOTE}${R}${FAINT}1${R}";
    ok(index($row, $todo_raw) >= 0, 'AC-9: raw FAINT."U+274F".R." ".FAINT."3".R (zero project, dimmed, no dot)')
        or diag("  row 1 raw = [$row]");
    ok(index($row, $note_raw) >= 0, 'AC-9: raw FAINT."U+2630".R.FAINT."1".R (zero project, dimmed, no dot, no space)')
        or diag("  row 1 raw = [$row]");
    my $vis = strip_sgr($row);
    ok(index($vis, $G_DOT) < 0, 'AC-9: no U+00B7 anywhere in the zero-project render');
}
SKIP: {
    skip('almanac modules did not load', 1) unless $ALMANAC_OK;
    my $P = mk_proj();
    seed_todos('project', $P, 5, 0);
    my $H = mk_home();
    seed_todos('global', $H, 3, 0);
    my ($out) = render(proj => $P, home => $H);
    my $row = first_line($out);
    my $raw = "${MUTED}${G_TODO}${R} ${PRIMARY}5${R}${FAINT}${G_DOT}${R}${MUTED}3${R}";
    ok(index($row, $raw) >= 0, 'AC-9: non-zero project side renders MUTED."U+274F".R." ".PRIMARY."5".R.FAINT."U+00B7".R.MUTED."3".R')
        or diag("  row 1 raw = [$row]");
}

# ===========================================================================
# AC-10 -- budget: every row costs at most cols, at every tested width, host
# and sandbox, full fixture plus flag plus badge.
# ===========================================================================
SKIP: {
    skip('almanac modules did not load', 1) unless $ALMANAC_OK;
    my $sid = 'sess-counters-budget';
    my $state = nslash(tempdir(CLEANUP => 1));
    make_path("$state/continuity/off");
    spew_raw("$state/continuity/off/$sid",
        JSON::PP->new->canonical->encode({ actor => 'agent', at => '2026-09-26T00:00:00Z',
                                            reason => 'paused for the operator', session_id => $sid }) . "\n");
    for my $sb (0, 1) {
        for my $cols (40, 60, 80, 120, 200) {
            my ($out, $rc) = render(proj => $P_FULL, home => $H_FULL, data => $DATA_FULL,
                cols => $cols, sandbox => $sb, sid => $sid, state => $state,
                toplevel => "$WROOT/proj-alpha", branch => 'main');
            is($rc, 0, "AC-10 (sandbox=$sb, cols=$cols): render exits 0");
            for my $line (split /\n/, $out) {
                next unless length $line;
                # The host-only path row has no natural width and is out of
                # scope (spec 6): every OTHER row must honour the budget.
                next if !$sb && index(strip_sgr($line), '/') == 0;
                my $cost = row_cost($line);
                ok($cost <= $cols, "AC-10 (sandbox=$sb, cols=$cols): row costs $cost, within budget")
                    or diag("  row = [" . strip_sgr($line) . "]");
            }
        }
    }
}

# ===========================================================================
# AC-11 -- the flag keeps its fit-ladder priority (Decision 3(5)).
# ===========================================================================
SKIP: {
    skip('almanac modules did not load', 1) unless $ALMANAC_OK;
    # spec section 4, AC-11 says "Host, full fixture": decisions, blueprints,
    # tasklist, todos AND notes must all be present, so C => F actually
    # exercises something. P_FULL/H_FULL/DATA_FULL already carry 2 unanswered
    # decisions (matching the $literal below), plus non-zero blueprints,
    # tasks, todos and notes on both sides.
    my $literal = "$G_HOLLOW HOST $G_FLAG 2";
    my $T = row_cost($literal);

    my $violations = 0;
    my $exact_at_T = undef;
    my ($seen_C, $seen_Gt, $seen_Pj) = (0, 0, 0);
    for my $cols (8 .. 120) {
        my ($out, $rc) = render(proj => $P_FULL, home => $H_FULL, data => $DATA_FULL, cols => $cols,
            toplevel => "$WROOT/proj-alpha", branch => 'main');
        my $row = first_line($out);
        my $vis = strip_sgr($row);
        my $F  = ($vis =~ /\Q$G_FLAG\E 2(?!\d)/) ? 1 : 0;
        my $Gt = (index($vis, 'main') >= 0) ? 1 : 0;
        my $C  = (index($vis, $G_BLUEPRINT) >= 0 || index($vis, $G_THREAD) >= 0
                || index($vis, $G_TODO) >= 0 || index($vis, $G_NOTE) >= 0) ? 1 : 0;
        my $Pj = defined(project_field($row)) ? 1 : 0;

        $seen_C  ||= $C;
        $seen_Gt ||= $Gt;
        $seen_Pj ||= $Pj;

        $violations++ if $Gt && !$F;
        $violations++ if $C  && !$F;
        $violations++ if $Pj && !$F;

        my $want_F = ($cols >= $T) ? 1 : 0;
        $violations++ if $F != $want_F;

        $exact_at_T = $vis if $cols == $T;

        ok(no_malformed_escape($out), "AC-11 (cols=$cols): no malformed/split ANSI escape survives")
            or diag("  row 1 raw = [$row]");
    }
    ok($seen_C && $seen_Gt && $seen_Pj,
        'AC-11 setup: the full-fixture sweep actually exercises counters, git and project at some width -- not vacuous')
        or diag("  seen_C=$seen_C seen_Gt=$seen_Gt seen_Pj=$seen_Pj");
    is($violations, 0, 'AC-11: at every width from 8 to 120, Gt=>F, C=>F, Pj=>F, and F iff cols>=T')
        or diag("  T = $T, violations = $violations");
    is($exact_at_T, $literal, 'AC-11: at cols = T, row 1 stripped equals "U+25CB HOST U+2691 2" exactly');
}

# ===========================================================================
# behaviour 9 -- a failed blueprint scan must not take the flag with it.
# ===========================================================================
SKIP: {
    skip('almanac modules did not load', 2) unless $ALMANAC_OK;
    my $P = mk_proj();
    seed_decisions($P, 2, 0);
    my $data = tempdir(CLEANUP => 1);
    # "<data>/blueprints" is a regular file, not a directory: opendir on it
    # fails/dies inside the counters eval. Spec section 5: "$plans_str stays
    # ''. The flag, built outside the eval, still renders."
    spew_raw("$data/blueprints", "not a directory\n");
    my ($out, $rc) = render(proj => $P, home => mk_home(), data => $data);
    is($rc, 0, 'behaviour 9: exit is 0 even when the blueprints path is not a directory');
    my $vis = strip_sgr(first_line($out));
    ok($vis =~ /\Q$G_FLAG\E 2(?!\d)/,
        'behaviour 9: the pending-decisions flag still renders despite the failed blueprint scan')
        or diag("  row 1 = [$vis]");
}

# ===========================================================================
# AC-13 -- README.md line 143, byte-exact.
# ===========================================================================
{
    my @lines = split /\n/, slurp_raw($README), -1;
    my $line143 = $lines[142] // '';
    (my $line143_nocr = $line143) =~ s/\r\z//;
    $line143 = $line143_nocr;
    my $want = "\x{25CB} HOST \x{FF5C} ccpraxis \x{FF5C} \x{2325} main \x{2191}3 \x{2193}22 \x{FF5C} "
             . "\x{29C9}  2  \x{274F} 14";
    my $want_bytes = encode('UTF-8', $want);
    is($line143, $want_bytes, 'AC-13: README.md line 143 is byte-exact per spec 2.8')
        or diag("  got  = [$line143]\n  want = [$want_bytes]");
}

# ===========================================================================
# AC-14 -- source checks.
# ===========================================================================
{
    my $sl_src = slurp_raw($STATUSLINE);
    ok(index($sl_src, "\\x{22EE}") < 0, 'AC-14: statusline.pl source contains no \\x{22EE}');
    ok(index($sl_src, '0x22EE') < 0, 'AC-14: statusline.pl source contains no 0x22EE');

    my $THEME_PM = "$Bin/../../scripts/Theme.pm";
    my $theme_src = slurp_raw($THEME_PM);
    ok(index($theme_src, '0x22EE') < 0, 'AC-14: Theme.pm source contains no 0x22EE');

    my $cout = `timeout 20 perl -c "$STATUSLINE" 2>&1`;
    my $crc  = $? >> 8;
    is($crc, 0, 'AC-14: `perl -c scripts/statusline.pl` exits 0 with no -I flag')
        or diag("  $cout");
}

done_testing();
