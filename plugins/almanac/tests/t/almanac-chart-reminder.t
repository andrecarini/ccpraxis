#!/usr/bin/env perl
# platform: any
# Package 15-harness-tasks-and-reminder (blueprint almanac-records). Immutable
# oracle for the chart-tasklist PostToolUse reminder: ACs R-1..R-14, per
# specs/15-harness-tasks-and-reminder-spec.md sections 2.3, 2.4, 3 and 4.
#
# reminder-chart-tasklist.pl and its hooks.json registration DO NOT EXIST YET
# at the time this file is written. Every assertion below is expected to
# fail for exactly that reason -- never a harness bug in this file.
#
# Package 05-almanac-routing-prose (blueprint tooling-fixes), Decision 5 and
# done criterion 1: the reminder sentence stops asking the agent to "record
# where the work stands" (which produced status-log entries in the
# tasklist) and instead tells it to move its current steps through doing,
# blocked and done, and to add a task only for a new step of work. The
# per-call "Tool call $n..." prefix and the almanac-task.pl command-line
# hint are UNCHANGED by Decision 5, so those two anchors are still checked
# byte-exact (see reminder_prefix/reminder_suffix); the replaced sentence
# is checked by regex on its key clauses in assert_reminder_text(), never
# pinned to an invented literal.
#
# Every subprocess gets a scrubbed environment per the spec's AC section 4:
# ALMANAC_HOME/HOME/USERPROFILE/BUTLER_STATE_DIR pinned to fresh tempdirs,
# CLAUDE_PROJECT_DIR a temp project, BP_*/CLAUDE_CODE_SESSION_ID unset,
# CCPRAXIS_NO_WAKELOCK=1. Nothing here ever points at the operator's real
# HOME or the real butler continuity state (R-14 asserts that at the end).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Spec ();
use Cwd ();
use JSON::PP ();
use Encode qw(decode_utf8);

(my $ALM    = "$Bin/../..") =~ s{\\}{/}g;                # plugins/almanac
(my $H      = "$ALM/hooks") =~ s{\\}{/}g;
(my $REPO   = Cwd::abs_path("$Bin/../../../..") // "$Bin/../../../..") =~ s{\\}{/}g;
(my $BUTLER = "$REPO/plugins/butler") =~ s{\\}{/}g;

my $HOOKS_JSON = "$H/hooks.json";

# =============================================================================
# current_R() -- the registration string LIVE from hooks.json, read fresh on
# every call (never a frozen literal). Decision 28 moves the reminder to a
# bash-only ticket counter that launches perl only on a claimed multiple of
# 20, which is a DIFFERENT bash script from the old "perl unconditionally"
# form -- pinning fire_reminder() to one fixed byte string would make that
# redesign impossible to ever pass, by construction. Returns '' (never undef)
# when hooks.json cannot be decoded or carries no matching PostToolUse entry,
# so a caller that runs it through bash sees exactly the fail-open behaviour
# of a missing hook (empty command -> exit 0, no output).
# =============================================================================
sub current_R {
    my $raw = slurp($HOOKS_JSON);
    my $cfg = defined($raw) ? eval { JSON::PP->new->decode($raw) } : undef;
    return '' unless ref $cfg eq 'HASH';
    for my $blk (@{ $cfg->{hooks}{PostToolUse} || [] }) {
        for my $hk (@{ $blk->{hooks} || [] }) {
            my $c = $hk->{command} // '';
            return $c if $c =~ /reminder-chart-tasklist\.pl/;
        }
    }
    return '';
}

# OVERRIDDEN by blueprint where-things-go, package 02-thread-store
# (specs/02-thread-store-spec.md section 2.10, behaviour 22, AC15): the
# almanac-records package 15 text above (Decision 5) is superseded by an
# EXACT two-line text the architect pinned (caller question 1), no longer
# tolerant-regex-matched -- "chart your tasklist"/"focused" become "chart
# your thread"/"owns a live thread", and the command hint now names
# almanac-thread.pl's verbs. reminder_prefix/suffix together are the WHOLE
# reminder text now (two lines, nothing else).
sub reminder_prefix { my ($n) = @_; return "Tool call $n in this session: chart your thread. Move your current steps through doing, blocked and done; add a task only for a new step of work." }
sub reminder_suffix { my ($root) = @_; return "  perl $root/scripts/almanac-thread.pl list | show <thread> | add <thread> --title '<step>' | status <thread> <task> doing|blocked|done" }

# OVERRIDDEN AGAIN by blueprint where-things-go, package 04-continuity-threads
# (specs/04-continuity-threads-spec.md section 2.8, behaviour 18): when the
# session is attached to a live thread <T> (not merely armed), the generic
# "<thread>" placeholder is replaced by the real thread name in both lines.
# "$gate" from arming ALONE (no attached thread) keeps the generic, unnamed
# text above byte-identical (reminder_prefix/reminder_suffix are untouched).
sub reminder_prefix_named { my ($n, $name) = @_; return "Tool call $n in this session: chart your thread $name. Move your current steps through doing, blocked and done; add a task only for a new step of work." }
sub reminder_suffix_named { my ($root, $name) = @_; return "  perl $root/scripts/almanac-thread.pl show $name | add $name --title '<step>' | status $name <task> doing|blocked|done" }

sub assert_reminder_text_named {
    my ($text, $n, $root, $name, $label) = @_;
    $text = '' unless defined $text;
    my $prefix = reminder_prefix_named($n, $name);
    my $suffix = reminder_suffix_named($root, $name);
    is($text, "$prefix\n$suffix", "$label: is exactly the named-thread two-line reminder for '$name'");
    return;
}

# assert_reminder_text($text, $n, $root, $label) -- AC15/behaviour 22 oracle:
# the reminder is EXACTLY the two pinned lines (prefix line, then suffix
# line), nothing more, nothing less.
sub assert_reminder_text {
    my ($text, $n, $root, $label) = @_;
    $text = '' unless defined $text;
    my $prefix = reminder_prefix($n);
    my $suffix = reminder_suffix($root);
    like($text, qr/^\Q$prefix\E/, "$label: starts with the exact 'Tool call $n...chart your thread.' line");
    like($text, qr/\Q$suffix\E\z/, "$label: ends with the exact almanac-thread.pl command-line hint");
    unlike($text, qr/chart your tasklist/i, "$label: no longer says 'chart your tasklist' (retired package-15 wording)");
    unlike($text, qr/Record where the work stands/i,
        "$label: no longer contains 'Record where the work stands'");
    return;
}

# ---------------------------------------------------------------------------
# scaffolding
# ---------------------------------------------------------------------------
sub slurp {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

my $REAL_BASH = do { my $p = `bash -c "command -v bash"`; chomp $p; length($p) ? $p : 'bash' };
my $REAL_TIMEOUT = do { my $p = `bash -c "command -v timeout" 2>/dev/null`; chomp $p; length($p) ? $p : '' };

# copy_tree($src, $dst) -- shallow recursive copy, core modules only. NEVER a
# dying opendir (an unreadable/missing source dir is silently skipped, not
# fatal): several callers deliberately copy a partial tree (pre-implementation
# state where reminder-chart-tasklist.pl does not exist yet).
sub copy_tree {
    my ($src, $dst) = @_;
    return unless -d $src;
    make_path($dst);
    my @stack = ('');
    while (@stack) {
        my $rel = pop @stack;
        my $sdir = length($rel) ? "$src/$rel" : $src;
        opendir(my $dh, $sdir) or next;
        my @entries = readdir($dh);
        closedir $dh;
        for my $e (@entries) {
            next if $e eq '.' || $e eq '..';
            my $srel = length($rel) ? "$rel/$e" : $e;
            my $sp = "$src/$srel";
            my $dp = "$dst/$srel";
            if (-d $sp) {
                make_path($dp);
                push @stack, $srel;
            } else {
                (my $ddir = $dp) =~ s{/[^/]+$}{};
                make_path($ddir) if length $ddir;
                copy($sp, $dp);
            }
        }
    }
}

# base_env(%extra) -- the scrubbed-environment contract, as a plain hashref
# suitable for overlaying onto %ENV. Every call site gets ITS OWN fresh
# tempdirs unless $extra{home}/$extra{state} are passed in (so a caller can
# share one root across several sequential fire_reminder() calls for the
# SAME session, which the counter contract requires).
sub base_env {
    my (%extra) = @_;
    my $home  = $extra{home}  // tempdir(CLEANUP => 1);
    my $state = $extra{state} // tempdir(CLEANUP => 1);
    my $proj  = $extra{proj}  // tempdir(CLEANUP => 1);
    for ($home, $state, $proj) { s{\\}{/}g }
    return {
        ALMANAC_HOME       => $home,
        HOME               => $home,
        USERPROFILE        => $home,
        BUTLER_STATE_DIR   => $state,
        CLAUDE_PROJECT_DIR => $proj,
        BP_LEDGER          => undef,
        BP_ROLE            => undef,
        CLAUDE_CODE_SESSION_ID => undef,
        CCPRAXIS_NO_WAKELOCK   => 1,
    }, $home, $state, $proj;
}

sub countfile { my ($home, $sid) = @_; return "$home/.claude/almanac-state/chart-reminder/$sid.count" }

# ticket_dir($home, $sid) -- the ticket-model's per-session state directory
# (Decision 28: the reminder becomes a bash-only ticket counter; the state is
# a directory of numbered empty ticket files, not a single counter file with
# a flock sidecar). ticket_names() lists the current numeric ticket names,
# sorted numerically, ignoring any non-numeric entry (a stray file must never
# confuse the ticket scan -- R-5's corrupt-state equivalent).
sub ticket_dir { my ($home, $sid) = @_; return "$home/.claude/almanac-state/chart-reminder/$sid.t" }
sub ticket_names {
    my ($dir) = @_;
    return () unless -d $dir;
    opendir(my $dh, $dir) or return ();
    my @names = sort { $a <=> $b } grep { /^\d+$/ } readdir($dh);
    closedir $dh;
    return @names;
}

sub armed_marker_dir { my ($state) = @_; return "$state/continuity/armed" }
sub touch_armed {
    my ($state, $sid) = @_;
    my $dir = armed_marker_dir($state);
    make_path($dir);
    open(my $fh, '>', "$dir/$sid") or die "cannot touch armed marker: $!";
    close $fh;
}

sub encode_payload {
    my ($h) = @_;
    return $h unless ref $h eq 'HASH';
    return JSON::PP->new->utf8->encode($h);
}

# fire_reminder($payload, %env_overlay) -> { rc, out, err }
# Runs the registration string read LIVE from hooks.json via current_R()
# (or $env_overlay{__r} if given, for the butler-hook cross-check in R-11)
# with CLAUDE_PLUGIN_ROOT = $env_overlay{CLAUDE_PLUGIN_ROOT} // $ALM, via a
# real bash subprocess. NEVER a frozen literal -- see current_R()'s header.
sub fire_reminder {
    my ($payload, %env) = @_;
    my $r = delete $env{__r} // current_R();
    my $root = $env{CLAUDE_PLUGIN_ROOT} // $ALM;

    my (undef, $script) = tempfile(SUFFIX => '.sh');
    open(my $sfh, '>', $script) or die "cannot write $script: $!";
    print {$sfh} "#!/usr/bin/env bash\n$r\n";
    close $sfh;

    my (undef, $in) = tempfile();
    open(my $ifh, '>:raw', $in) or die "cannot write $in: $!";
    print {$ifh} encode_payload($payload);
    close $ifh;

    my (undef, $out) = tempfile();
    my (undef, $err) = tempfile();

    local %ENV = %ENV;
    delete $ENV{$_} for grep { /^(?:BP_|CLAUDE_)/ } keys %ENV;
    $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
    $ENV{CLAUDE_PLUGIN_ROOT} = $root;
    for my $k (keys %env) {
        next if $k eq 'CLAUDE_PLUGIN_ROOT';
        if (defined $env{$k}) { $ENV{$k} = $env{$k} } else { delete $ENV{$k} }
    }

    system(qq{bash "$script" < "$in" > "$out" 2> "$err"});
    my $rc = $? >> 8;
    my $o  = slurp($out) // '';
    my $e  = slurp($err) // '';
    unlink $script, $in, $out, $err;
    return { rc => $rc, out => $o, err => $e };
}

sub mkpayload {
    my (%kv) = @_;
    my %p = (
        hook_event_name => 'PostToolUse',
        session_id      => $kv{sid},
        tool_name        => $kv{tool_name} // 'Bash',
        cwd              => $kv{cwd},
        tool_input       => {},
        tool_response    => {},
    );
    $p{agent_id} = $kv{agent_id} if defined $kv{agent_id};
    delete $p{cwd} unless defined $kv{cwd};
    delete $p{session_id} unless defined $kv{sid};
    return \%p;
}

my $sid_n = 0;
sub fresh_sid { return sprintf('rmndr-%04d-%d', ++$sid_n, time()) }

sub decode_out {
    my ($out) = @_;
    return undef unless length $out;
    my @lines = grep { length } split /\n/, $out;
    return undef unless @lines == 1;
    return eval { JSON::PP->new->decode($lines[0]) };
}

# do_focus($sid, $root) -- AC15/behaviour 22 override: "focused" (a task-
# focus record) is retired; a session now "owns a live thread" instead. This
# makes the session own one by creating a thread with that session as owner
# (Almanac::Thread::owned_by_session's definition), via almanac-thread.pl
# create --session <sid>. Kept under its old name so every existing R-xx/
# AC-xx call site below is re-expressed with "owns a live thread" by this
# one change, as AC15 requires, rather than by touching each site.
#
# EDITED for blueprint where-things-go, package 03-thread-sessions (Decision
# 18 F6): the `create` verb is hard ticket-gated. do_focus pins its own
# BUTLER_STATE_DIR (rather than depending on whatever the caller's ambient
# %ENV happens to carry) and mints a matching ticket for the exact argv it
# spawns, so this fixture keeps working once the gate lands -- pure
# migration, not new behaviour.
sub do_focus {
    my ($sid, $root) = @_;
    local %ENV = %ENV;
    delete $ENV{CLAUDE_CODE_SESSION_ID};
    my $state = tempdir(CLEANUP => 1);
    $state =~ s{\\}{/}g;
    $ENV{BUTLER_STATE_DIR} = $state;
    require "$BUTLER/scripts/BpHook.pm" unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
    our $DO_FOCUS_TICKET_SEQ;
    BpHook::write_ticket(
        { session_id => $sid, tool_use_id => 'DF' . (++$DO_FOCUS_TICKET_SEQ),
          transcript_path => undef, cwd => $root },
        'almanac-thread', ['create', 'owned-thread', '--session', $sid, '--root', $root]);
    system(qq{perl "$ALM/scripts/almanac-thread.pl" create owned-thread --session "$sid" --root "$root" > /dev/null 2>&1});
    return $? >> 8;
}

# =============================================================================
# R-1 (DC5): hooks.json has exactly one PostToolUse entry for the reminder,
# no matcher key. Decision 28 replaces the old "perl launches on every call"
# registration with a bash ticket counter that launches perl only on a
# claimed multiple of 20, so this AC asserts PROPERTIES of the command
# rather than pinning it to one fixed byte string -- pinning it would make
# that redesign impossible to ever pass, by construction. "Fails open" and
# "does not run perl unconditionally" are checked BEHAVIOURALLY, by running
# the live command, never by string-matching its bytes.
# =============================================================================
{
    my $raw = slurp($HOOKS_JSON);
    my $cfg = defined($raw) ? eval { JSON::PP->new->decode($raw) } : undef;
    ok($cfg, 'R-1: hooks.json decodes as JSON') or diag($raw ? "decode failed: $@" : 'file unreadable');

    my @entries;
    if (ref $cfg eq 'HASH') {
        for my $blk (@{ $cfg->{hooks}{PostToolUse} || [] }) {
            my @cmds = map { $_->{command} // '' } @{ $blk->{hooks} || [] };
            push @entries, $blk if grep { /reminder-chart-tasklist\.pl/ } @cmds;
        }
    }
    is(scalar(@entries), 1, 'R-1: exactly one PostToolUse entry runs reminder-chart-tasklist.pl');

    my $cmd = (@entries && $entries[0]{hooks} && $entries[0]{hooks}[0]) ? ($entries[0]{hooks}[0]{command} // '') : '';
    if (@entries) {
        ok(!exists $entries[0]{matcher}, 'R-1: it carries no matcher key (fires on all tools)');
        is(scalar(@{ $entries[0]{hooks} || [] }), 1, 'R-1: exactly one hook object');
        like($cmd, qr/^unset BASH_ENV ;/, 'R-1: the command\'s first statement is "unset BASH_ENV ;"');
        like($cmd, qr/\$\{CLAUDE_PLUGIN_ROOT\}[^"]*reminder-chart-tasklist\.pl/,
             'R-1: the command references reminder-chart-tasklist.pl via ${CLAUDE_PLUGIN_ROOT}');
    }

    # "always exits 0", behaviourally.
    {
        my ($env0) = base_env();
        my $r = fire_reminder('not json at all', %$env0);
        is($r->{rc}, 0, 'R-1: the live registration exits 0 on garbage stdin');
    }

    # "fails open when the script or plugin root is missing", behaviourally.
    {
        my $empty_root = tempdir(CLEANUP => 1); $empty_root =~ s{\\}{/}g;
        my ($env0, undef, undef, $proj0) = base_env();
        my $r = fire_reminder(mkpayload(sid => fresh_sid(), cwd => $proj0), %$env0, CLAUDE_PLUGIN_ROOT => $empty_root);
        is($r->{rc}, 0, 'R-1: the live registration fails open (exit 0) when CLAUDE_PLUGIN_ROOT has no script');
        is($r->{out}, '', 'R-1: ...and prints nothing');
    }

    # "does not run perl unconditionally", behaviourally, through a PATH
    # shim (the same technique R-12 uses for its full sweep) -- never by
    # grepping the command string for the word "perl".
    {
        my $real_perl = (File::Spec->file_name_is_absolute($^X) && -x $^X) ? $^X
                       : do { my $p = `bash -c "command -v perl"`; chomp $p; $p };
        my $shim = tempdir(CLEANUP => 1);
        open(my $pfh, '>', "$shim/perl") or die $!;
        print {$pfh} "#!/usr/bin/env bash\nprintf 'perl %s\\n' \"\$\$\" >> \"\$SHIM_LOG\"\nexec \"$real_perl\" \"\$\@\"\n";
        close $pfh;
        chmod 0755, "$shim/perl";

        my $sid = fresh_sid();
        my ($env, $home, $state, $proj) = base_env();
        touch_armed($state, $sid);
        my (undef, $log) = tempfile();
        $env->{SHIM_LOG} = $log;
        $env->{PATH} = "$shim:$ENV{PATH}";
        fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env); # call 1 -- ordinary, non-firing
        my $count = () = ((slurp($log) // '') =~ /^perl /mg);
        is($count, 0, 'R-1: an ordinary call does not launch perl unconditionally (zero launches via a PATH shim, checked behaviourally; the full sweep is R-12)');
    }
}

# =============================================================================
# R-2 (DC3): armed session, calls 1-19 silent, call 20 fires with N=20,
# calls 21-39 silent, call 40 fires with N=40. Every call exits 0.
# =============================================================================
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    touch_armed($state, $sid);

    my @fired;
    for my $i (1 .. 40) {
        my $r = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env);
        is($r->{rc}, 0, "R-2: call $i exits 0") or diag("stderr=[$r->{err}]");
        if ($i % 20 == 0) {
            my $d = decode_out($r->{out});
            ok(ref($d) eq 'HASH', "R-2: call $i (a multiple of 20) prints exactly one decodable JSON line")
                or diag("stdout=[$r->{out}]");
            if (ref($d) eq 'HASH') {
                is_deeply([sort keys %$d], ['hookSpecificOutput'], "R-2: call $i -- the only top-level key is hookSpecificOutput");
                is($d->{hookSpecificOutput}{hookEventName}, 'PostToolUse', "R-2: call $i hookEventName is PostToolUse");
                assert_reminder_text($d->{hookSpecificOutput}{additionalContext}, $i, $ALM, "R-2: call $i additionalContext");
            }
            push @fired, $i;
        } else {
            is($r->{out}, '', "R-2: call $i (not a multiple of 20) prints nothing");
        }
    }
    is_deeply(\@fired, [20, 40], 'R-2: exactly calls 20 and 40 fired');

    # =========================================================================
    # R-3 (DC3, location, ticket model per Decision 28): the session state is
    # a ticket DIRECTORY (<sid>.t/), never the old single-file counter with a
    # flock sidecar, and it never accumulates past one cycle -- after the
    # 40th (firing) call above, the tickets it counted are gone.
    # =========================================================================
    my $tdir3 = ticket_dir($home, $sid);
    ok(-d $tdir3, 'R-3: the session state is a ticket directory (<sid>.t/), not a single counter file');
    my @tickets3 = ticket_names($tdir3);
    is(scalar(@tickets3), 0, 'R-3: after the 40th (firing) call, no ticket files remain -- the firing run deleted the ones it counted');
    ok(!-f countfile($home, $sid), 'R-3: the old single-file counter (<sid>.count) is not used by the ticket model');
    ok(!-f (countfile($home, $sid) . '.lock'), 'R-3: ...nor its .count.lock sidecar');
}

# =============================================================================
# R-4 (DC3, concurrency): 40 invocations for one armed session, all started
# before any is reaped. Final count 40\n, exactly 2 invocations print, N
# values {20, 40}.
# =============================================================================
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    touch_armed($state, $sid);

    my $stdin_dir = tempdir(CLEANUP => 1); $stdin_dir =~ s{\\}{/}g;
    my $out_dir   = tempdir(CLEANUP => 1); $out_dir   =~ s{\\}{/}g;
    my $payload_json = encode_payload(mkpayload(sid => $sid, cwd => $proj));
    for my $i (1 .. 40) {
        open(my $fh, '>:raw', "$stdin_dir/$i.json") or die $!;
        print {$fh} $payload_json;
        close $fh;
    }

    my (undef, $driver) = tempfile(SUFFIX => '.sh');
    open(my $dfh, '>', $driver) or die $!;
    print {$dfh} <<'DRIVER';
#!/usr/bin/env bash
for i in $(seq 1 "$N"); do
  bash -c "$R" < "$STDIN_DIR/$i.json" > "$OUT_DIR/$i.out" 2> "$OUT_DIR/$i.err" &
done
wait
DRIVER
    close $dfh;

    local %ENV = %ENV;
    delete $ENV{$_} for grep { /^(?:BP_|CLAUDE_)/ } keys %ENV;
    for my $k (keys %$env) {
        if (defined $env->{$k}) { $ENV{$k} = $env->{$k} } else { delete $ENV{$k} }
    }
    $ENV{CLAUDE_PLUGIN_ROOT} = $ALM;
    $ENV{N} = 40;
    $ENV{R} = current_R();
    $ENV{STDIN_DIR} = $stdin_dir;
    $ENV{OUT_DIR} = $out_dir;
    $ENV{CCPRAXIS_NO_WAKELOCK} = 1;

    my $cmd = length($REAL_TIMEOUT) ? qq{"$REAL_TIMEOUT" 90 "$REAL_BASH" "$driver"} : qq{"$REAL_BASH" "$driver"};
    system($cmd);

    my $tdir4 = ticket_dir($home, $sid);
    ok(-d $tdir4, 'R-4: the ticket directory exists after 40 concurrent invocations');
    my @tickets4 = ticket_names($tdir4);
    is(scalar(@tickets4), 0, 'R-4: after 40 concurrent invocations (two full cycles), no ticket files remain -- no gaps or duplicates left dangling, and nothing accumulates past one cycle');

    my @fired_ns;
    for my $i (1 .. 40) {
        my $o = slurp("$out_dir/$i.out") // '';
        next unless length $o;
        my $d = decode_out($o);
        push @fired_ns, $d->{hookSpecificOutput}{additionalContext} =~ /Tool call (\d+)/ ? $1 : 'unparsed'
            if ref $d eq 'HASH';
    }
    is_deeply([sort { $a <=> $b } @fired_ns], [20, 40], 'R-4: exactly two invocations printed, with N in {20, 40}');
    unlink $driver;
}

# =============================================================================
# R-5 (DC3, reset, ticket model per Decision 28): a fresh sid claims ticket
# 1 (models /clear); a reused sid continues claiming the next number, never
# resetting mid-session (models --resume/--compact); a stray non-numeric
# entry in the ticket directory (this model's equivalent of a corrupt count
# file) does not confuse the ticket scan.
# =============================================================================
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    touch_armed($state, $sid);
    fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env);
    is_deeply([ticket_names(ticket_dir($home, $sid))], ['1'], "R-5: a fresh sid's first call claims ticket 1 (models /clear)");

    fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env);
    is_deeply([ticket_names(ticket_dir($home, $sid))], ['1', '2'],
       "R-5: the SAME sid's second call continues to {1,2} (models --resume/--compact), not a reset");
}
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    touch_armed($state, $sid);
    my $tdir5 = ticket_dir($home, $sid);
    make_path($tdir5);
    open(my $fh, '>', "$tdir5/garbage.txt") or die $!;
    close $fh;

    fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env);
    is_deeply([ticket_names($tdir5)], ['1'],
       'R-5 (behaviour 13 equivalent): a stray non-numeric entry in the ticket directory does not confuse the scan -- the first real call still claims ticket 1');
    ok(-f "$tdir5/garbage.txt", 'R-5: ...and the stray entry itself is left untouched, never deleted or treated as a ticket');
}

# =============================================================================
# R-6 (DC4, ticket model per Decision 28): neither armed nor focused at call
# 20 -> no output, but the ticket cycle still completes (0 tickets remain --
# the counting/deletion is unconditional on the gate; only the additional
# Context output depends on it). The judge case of behaviour 7: BP_LEDGER
# set + BP_ROLE=harvest-judge, unfocused -> no output.
# =============================================================================
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    # deliberately never armed, never focused
    my $last;
    for (1 .. 20) { $last = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env) }
    is($last->{out}, '', 'R-6: neither armed nor focused -- call 20 prints nothing');
    is(scalar(ticket_names(ticket_dir($home, $sid))), 0,
       'R-6: ...but the ticket cycle still completed (0 tickets remain) -- the count is unconditional on the gate');
}
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    $env->{BP_LEDGER} = '1';
    $env->{BP_ROLE}   = 'harvest-judge';
    my $last;
    for (1 .. 20) { $last = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env) }
    is($last->{out}, '', 'R-6: a judge environment, unfocused -- call 20 prints nothing');
}

# =============================================================================
# R-7 (DC4): the positive gate cases -- armed only, focused only, coordinator
# environment.
# =============================================================================
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    touch_armed($state, $sid);
    my $last;
    for (1 .. 20) { $last = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env) }
    isnt($last->{out}, '', 'R-7: armed only -- call 20 fires');
}
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    is(do_focus($sid, $proj), 0, 'R-7 fixture: focus succeeds');
    my $last;
    for (1 .. 20) { $last = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env) }
    isnt($last->{out}, '', 'R-7: focused only -- call 20 fires');
}
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    $env->{BP_LEDGER} = '1';
    delete $env->{BP_ROLE};
    my $last;
    for (1 .. 20) { $last = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env) }
    isnt($last->{out}, '', 'R-7: a coordinator environment (BP_LEDGER set, BP_ROLE unset) -- call 20 fires');
}

# =============================================================================
# R-8 (DC4): unreadable arm state is treated as unarmed.
# =============================================================================
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    $env->{BUTLER_STATE_DIR} = 'relative/not/absolute';
    my $last;
    for (1 .. 20) { $last = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env) }
    is($last->{out}, '', 'R-8: a relative BUTLER_STATE_DIR -- call 20 is silent (unfocused)');
}
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    my $iso = tempdir(CLEANUP => 1); $iso =~ s{\\}{/}g;
    copy_tree($ALM, "$iso/almanac");
    ok(-f "$iso/almanac/hooks/reminder-chart-tasklist.pl", 'R-8 fixture: the copy actually carries reminder-chart-tasklist.pl (copy_tree copied real content, not an empty tree)');
    ok(!-e "$iso/butler", 'R-8 fixture: the isolated copy has no sibling butler/ directory');
    $env->{CLAUDE_PLUGIN_ROOT} = "$iso/almanac";

    my $last;
    for (1 .. 20) { $last = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env) }
    is($last->{out}, '', "R-8: butler's BpHook.pm absent from the sibling path -- call 20 is silent (unfocused)");

    is(do_focus($sid, $proj), 0, 'R-8 fixture: focus succeeds mid-session');
    for (21 .. 39) { fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env) }
    my $r40 = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env);
    isnt($r40->{out}, '', 'R-8: ...but call 40 fires once focused, even with no sibling butler/');
}

# =============================================================================
# R-9: behaviours 9 and 10.
# =============================================================================
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    touch_armed($state, $sid);
    my $r = fire_reminder(mkpayload(sid => $sid, cwd => $proj, agent_id => 'sub-1'), %$env);
    is($r->{rc}, 0, 'R-9: a payload with agent_id exits 0');
    is($r->{out}, '', 'R-9: a payload with agent_id prints nothing (not counted)');
    ok(!-f countfile($home, $sid), 'R-9: ...and the count file is not created for a subagent call');
}
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    touch_armed($state, $sid);
    my $r = fire_reminder({ hook_event_name => 'PreToolUse', session_id => $sid, cwd => $proj }, %$env);
    is($r->{rc}, 0, 'R-9: hook_event_name != PostToolUse exits 0');
    is($r->{out}, '', 'R-9: ...prints nothing');
    ok(!-f countfile($home, $sid), 'R-9: ...and creates no count file');
}
{
    my ($env, $home, $state, $proj) = base_env();
    touch_armed($state, 'irrelevant-does-not-matter-here');
    my $r = fire_reminder({ hook_event_name => 'PostToolUse', cwd => $proj }, %$env); # missing session_id
    is($r->{rc}, 0, 'R-9: a missing session_id exits 0');
    is($r->{out}, '', 'R-9: ...prints nothing');
}
{
    my ($env, $home, $state, $proj) = base_env();
    my $r = fire_reminder('not json at all', %$env);
    is($r->{rc}, 0, 'R-9: non-JSON stdin exits 0');
    is($r->{out}, '', 'R-9: ...prints nothing');
}

# =============================================================================
# R-10 (DC5): every run above exits 0 with empty stderr (spot-check a few of
# the results already captured is impractical retroactively, so this block
# re-runs a representative sample plus the two dedicated edge cases).
# =============================================================================
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    touch_armed($state, $sid);
    for my $i (1 .. 20) {
        my $r = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env);
        is($r->{err}, '', "R-10: call $i has empty stderr");
    }
}
# M-1 (review): every firing call that reaches _focused() loads
# almanac-task.pl, which reloads Almanac/Lock.pm under a different %INC key
# and re-compiles it, producing "Subroutine ... redefined" warnings on
# stderr. That path is reached only when _armed() is false (|| short-
# circuits otherwise), so an ARMED-only sweep like the one just above can
# never see it. Check stderr explicitly in the other two gate states, at
# call 20 specifically (the one call that evaluates the gate at all).
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    is(do_focus($sid, $proj), 0, 'R-10 fixture: focus succeeds (focused-only case)');
    my $last;
    for (1 .. 20) { $last = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env) }
    is($last->{err}, '', 'R-10: call 20 of a focused-only (unarmed) session has empty stderr (catches the Lock.pm redefinition noise, review M-1)');
}
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    # deliberately neither armed nor focused
    my $last;
    for (1 .. 20) { $last = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env) }
    is($last->{err}, '', 'R-10: call 20 of a session that is neither armed nor focused has empty stderr (same Lock.pm redefinition path)');
}
{
    my $empty_root = tempdir(CLEANUP => 1); $empty_root =~ s{\\}{/}g;
    my ($env, $home, $state, $proj) = base_env();
    my $r = fire_reminder(mkpayload(sid => fresh_sid(), cwd => $proj), %$env, CLAUDE_PLUGIN_ROOT => $empty_root);
    is($r->{rc}, 0, 'R-10: CLAUDE_PLUGIN_ROOT at an empty tempdir exits 0');
    is($r->{out}, '', 'R-10: ...silently (no stdout)');
    is($r->{err}, '', 'R-10: ...and no stderr');
}
{
    my $broken = tempdir(CLEANUP => 1); $broken =~ s{\\}{/}g;
    copy_tree($ALM, "$broken/almanac");
    make_path("$broken/almanac/hooks");
    open(my $fh, '>', "$broken/almanac/hooks/reminder-chart-tasklist.pl") or die $!;
    print {$fh} "this is not valid perl {{{ \x{0}\n";
    close $fh;
    my ($env, $home, $state, $proj) = base_env();
    touch_armed($state, fresh_sid());
    my $r = fire_reminder(mkpayload(sid => fresh_sid(), cwd => $proj), %$env, CLAUDE_PLUGIN_ROOT => "$broken/almanac");
    is($r->{rc}, 0, 'R-10: a syntax-error copy of the script exits 0');
    is($r->{out}, '', 'R-10: ...with empty stdout');
}

# =============================================================================
# R-11 (DC6): PostToolUse coexistence with butler's track-dispatch.sh and
# context-ceiling.sh -- neither consumes the other's stdin, and R's own
# output is unaffected by their presence.
# =============================================================================
{
    my $braw = slurp("$BUTLER/hooks/hooks.json");
    my $bcfg = defined($braw) ? eval { JSON::PP->new->decode($braw) } : undef;
    my @butler_cmds;
    if (ref $bcfg eq 'HASH') {
        for my $blk (@{ $bcfg->{hooks}{PostToolUse} || [] }) {
            for my $hk (@{ $blk->{hooks} || [] }) {
                my $c = $hk->{command} // '';
                push @butler_cmds, $c if $c =~ /track-dispatch\.sh|context-ceiling\.sh/;
            }
        }
    }
    ok(scalar(@butler_cmds) == 2, 'R-11 fixture: butler\'s hooks.json carries exactly track-dispatch.sh and context-ceiling.sh on PostToolUse')
        or diag('found: ' . join(', ', @butler_cmds));

    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    touch_armed($state, $sid);

    my $r20_alone;
    for my $i (1 .. 20) {
        my $payload = mkpayload(sid => $sid, cwd => $proj, tool_name => 'Bash');
        for my $bc (@butler_cmds) {
            my $br = fire_reminder($payload, %$env, __r => $bc, CLAUDE_PLUGIN_ROOT => $BUTLER);
            is($br->{rc}, 0, "R-11: call $i -- butler hook exits 0") if $i == 20;
            is($br->{out}, '', "R-11: call $i -- butler hook has empty stdout") if $i == 20;
        }
        $r20_alone = fire_reminder($payload, %$env) if $i == 20;
    }

    my $sid2 = fresh_sid();
    my ($env2, $home2, $state2, $proj2) = base_env();
    touch_armed($state2, $sid2);
    my $r20_isolated;
    for my $i (1 .. 20) {
        my $payload = mkpayload(sid => $sid2, cwd => $proj2, tool_name => 'Bash');
        $r20_isolated = fire_reminder($payload, %$env2) if $i == 20;
    }
    is($r20_alone->{out}, $r20_isolated->{out}, "R-11: R's 20th-call output is identical with or without the butler hooks present");

    my $src = slurp("$H/reminder-chart-tasklist.pl");
    if (defined $src) {
        my $stdin_reads = () = ($src =~ /<STDIN>/g);
        is($stdin_reads, 1, 'R-11: a static scan finds exactly one read of STDIN (the <STDIN> diamond)');
    } else {
        fail('R-11: cannot scan reminder-chart-tasklist.pl for its STDIN reads -- file does not exist yet');
    }
}

# =============================================================================
# R-12 (cost, structural, ticket model per Decision 28): no system/exec/
# backtick/qx/fork/alarm/piped open in reminder-chart-tasklist.pl; perl is
# launched ONLY on the claimed 20th call and ZERO times on an ordinary call
# (the bash ticket counter handles every other call without ever starting
# perl), and the 20th call must actually have fired.
# =============================================================================
{
    my $src = slurp("$H/reminder-chart-tasklist.pl");
    ok(defined $src, 'R-12: reminder-chart-tasklist.pl is readable for the static scan')
        or diag('cannot scan a file that does not exist yet');
    if (defined $src) {
        unlike($src, qr/\bsystem\s*\(/, 'R-12: no system(...)');
        unlike($src, qr/\bexec\s*\(/,   'R-12: no exec(...)');
        unlike($src, qr/`/,             'R-12: no backticks');
        unlike($src, qr/\bqx[\/{(\[]/,  'R-12: no qx(...)');
        unlike($src, qr/\bfork\s*\(/,   'R-12: no fork()');
        unlike($src, qr/\balarm\s*\(/,  'R-12: no alarm()');
        unlike($src, qr/open\s*\([^)]*\|\s*["']?\)/, 'R-12: no piped open(...)');
    }

    my $real_perl = (File::Spec->file_name_is_absolute($^X) && -x $^X) ? $^X
                   : do { my $p = `bash -c "command -v perl"`; chomp $p; $p };
    my $shim = tempdir(CLEANUP => 1);
    open(my $pfh, '>', "$shim/perl") or die $!;
    print {$pfh} "#!/usr/bin/env bash\nprintf 'perl %s\\n' \"\$\$\" >> \"\$SHIM_LOG\"\nexec \"$real_perl\" \"\$\@\"\n";
    close $pfh;
    chmod 0755, "$shim/perl";

    # One shared session, calls 1..20 -- so call 20 really is the 20th call
    # and really fires. The shim log is RESET before every single call (not
    # once for the whole loop): checking a shared, never-reset log across 20
    # calls would just show "20 launches across 20 calls" and mask the real
    # per-invocation contract this AC means to check. Under the ticket model
    # (Decision 28), an ORDINARY call never starts perl at all (the bash
    # ticket counter handles it alone) -- only the claimed 20th call does,
    # exactly once, and that call must actually fire (m-2, review).
    {
        my $sid = fresh_sid();
        my ($env, $home, $state, $proj) = base_env();
        touch_armed($state, $sid);
        my (undef, $log) = tempfile();
        $env->{SHIM_LOG} = $log;
        $env->{PATH} = "$shim:$ENV{PATH}";

        for my $i (1 .. 20) {
            unlink $log;
            my $r = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env);
            my $logtext = slurp($log) // '';
            my $count = () = ($logtext =~ /^perl /mg);
            if ($i == 20) {
                is($count, 1, 'R-12: the firing call (20) launches perl exactly once');
                isnt($r->{out}, '', 'R-12: ...and call 20 actually fired (non-empty stdout), so the launch count is not passing on a silently-failed gate');
            } elsif ($i == 1 || $i == 19) {
                is($count, 0, "R-12: an ordinary call ($i) launches perl ZERO times -- the bash ticket counter alone handles it");
            }
        }
    }
}

# =============================================================================
# R-13: non-ASCII plugin root -- the emitted stdout is valid UTF-8 JSON (not
# just a Latin-1 byte that happens to string-compare equal), and the
# decoded additionalContext contains the non-ASCII root byte-identical
# once BOTH sides are UTF-8-decoded (review m-1).
# =============================================================================
{
    my $base = tempdir(CLEANUP => 1); $base =~ s{\\}{/}g;
    my $name = "plugin-\xc3\xa9"; # plugin + the UTF-8 BYTE SEQUENCE for e-acute
                                  # (0xC3 0xA9), never "\x{e9}" (a single
                                  # Latin-1 codepoint) -- the latter passes a
                                  # byte-for-byte Latin-1 comparison but is
                                  # not valid UTF-8, so it proves nothing
                                  # about the "valid UTF-8 JSON" contract a
                                  # real JSON consumer depends on.
    my $niso = "$base/$name";
    copy_tree($ALM, $niso);
    ok(-d $niso, 'R-13 fixture: the non-ASCII plugin copy directory exists');
    ok(-f "$niso/hooks/reminder-chart-tasklist.pl", 'R-13 fixture: the copy actually carries reminder-chart-tasklist.pl (copy_tree copied real content, not an empty tree)');

    # armed() requires "<root>/../butler/scripts/BpHook.pm" (spec sec 2.3).
    # $niso's parent ($base) needs a real "butler" sibling or armed(sid)
    # can never load BpHook.pm regardless of the plugin root's name -- this
    # bit R-13 identically for an ASCII root, so it is a fixture gap, not an
    # encoding bug. Copy butler alongside, keeping the non-ASCII component
    # in the almanac root path itself (the thing this AC actually tests).
    copy_tree($BUTLER, "$base/butler");
    ok(-f "$base/butler/scripts/BpHook.pm", 'R-13 fixture: a sibling butler/scripts/BpHook.pm exists next to the non-ASCII root, so armed() can actually load it');

    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    touch_armed($state, $sid);
    $env->{CLAUDE_PLUGIN_ROOT} = $niso;

    my $last;
    for (1 .. 20) { $last = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env) }

    my $line = $last->{out};
    $line =~ s/\n\z//;
    my @lines = grep { length } split /\n/, $line;
    is(scalar(@lines), 1, 'R-13: the 20th armed call under a non-ASCII root prints exactly one line')
        or diag("stdout=[$last->{out}]");

    my $d = @lines == 1 ? eval { JSON::PP->new->utf8->decode($lines[0]) } : undef;
    ok(defined $d, 'R-13: that line is valid UTF-8 JSON (JSON::PP->utf8->decode does not reject it)')
        or diag($@ // 'decode returned undef');
    if (defined $d) {
        assert_reminder_text($d->{hookSpecificOutput}{additionalContext}, 20, decode_utf8($niso),
           'R-13: the decoded additionalContext, non-ASCII root UTF-8-decoded on both sides');
    }
}

# =============================================================================
# R-14 (real state): the harness never touches the operator's REAL HOME
# almanac-state, or the real butler continuity armed directory, for any sid
# used in this whole file.
# =============================================================================
{
    my $real_home = $ENV{HOME};
    $real_home = $ENV{USERPROFILE} unless defined $real_home && length $real_home;
    my $probe_sid = fresh_sid() . '-real-state-probe';
    if (defined $real_home && length $real_home) {
        (my $rh = $real_home) =~ s{\\}{/}g;
        ok(!-e "$rh/.claude/almanac-state/chart-reminder/$probe_sid.count",
           'R-14: no real-HOME count file exists for a sid this suite never armed there');
    }
    my $real_state = $ENV{BUTLER_STATE_DIR};
    unless (defined $real_state && length $real_state) {
        $real_state = (defined $real_home ? "$real_home/.claude/butler-state" : undef);
    }
    if (defined $real_state && length $real_state) {
        (my $rs = $real_state) =~ s{\\}{/}g;
        ok(!-e "$rs/continuity/armed/$probe_sid",
           'R-14: no real butler-state armed marker exists for that sid either');
    }
}

# =============================================================================
# never-halt package 11-arming-nudges, N5 (DC3): AC-18..AC-25 of
# .ccpraxis-local-data/blueprints/never-halt/specs/11-arming-nudges-spec.md
# section 4. reminder-chart-tasklist.pl's N5 addition DOES NOT EXIST YET at
# the time this block is written -- every assertion below is expected to
# fail for exactly that reason, never a harness bug in this file.
#
# This block never relies on fire_reminder()'s own BP_*/CLAUDE_* scrub for
# CCPRAXIS_ARM_NUDGE_MIN (fire_reminder only deletes BP_*/CLAUDE_* keys):
# every case below explicitly deletes/sets CCPRAXIS_ARM_NUDGE_MIN itself.
# =============================================================================

# off_path/write_off/write_marker/nudged_path -- the N5 state-file formulas
# from spec sec 1.3/2.5, built directly (not through BpHook, which this file
# never requires) so these helpers work whether or not BpHook.pm has grown
# its never-halt-11 additions yet.
sub off_path   { my ($state, $sid) = @_; return "$state/continuity/off/$sid" }
sub write_off {
    my ($state, $sid, $actor) = @_;
    make_path("$state/continuity/off");
    open(my $fh, '>', off_path($state, $sid)) or die $!;
    print {$fh} JSON::PP->new->encode({ actor => $actor });
    close $fh;
}
sub write_marker {
    my ($state, $sid, $epoch) = @_;
    make_path("$state/continuity/prompted");
    open(my $fh, '>', "$state/continuity/prompted/$sid") or die $!;
    print {$fh} "$epoch\n";
    close $fh;
}
sub nudged_path { my ($home, $sid) = @_; return "$home/.claude/almanac-state/chart-reminder/$sid.nudged" }

# OVERRIDDEN by blueprint where-things-go, package 04-continuity-threads
# (specs/04-continuity-threads-spec.md section 2.8): the N5 nudge now says
# "arm and attach a thread" and names both CLI forms.
sub n5_text { my ($n) = @_; return "No operator message for $n min and work continues. If this session should keep working without the operator, arm and attach a thread: butler-continuity on --new-thread <name> (or --thread <name> to resume one)" }
sub n5_regex {
    my (@ns) = @_;
    my $alt = join('|', map { quotemeta(n5_text($_)) } @ns);
    return qr/\A(?:$alt)\z/;
}

# scrub_arm_nudge_min($env) -- explicit CCPRAXIS_ARM_NUDGE_MIN deletion,
# per this package's test-writer note: fire_reminder() only scrubs
# BP_*/CLAUDE_*, so an ambient CCPRAXIS_ARM_NUDGE_MIN would otherwise leak
# into every baseline case below.
sub scrub_arm_nudge_min { my ($env) = @_; $env->{CCPRAXIS_ARM_NUDGE_MIN} = undef; return $env }

# =============================================================================
# AC-18 + AC-19 (B12, B13, B14): first fire at call 20, quiet through call
# 40 (marker unchanged), fires again at call 60 once the marker is rewritten
# stale again.
# =============================================================================
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    scrub_arm_nudge_min($env);
    my $marker_epoch = time() - 31 * 60;
    write_marker($state, $sid, $marker_epoch);

    my $last;
    for my $i (1 .. 20) {
        $last = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env);
        is($last->{out}, '', "AC-18: call $i prints nothing") if $i < 20;
    }
    my $d = decode_out($last->{out});
    ok(ref($d) eq 'HASH', 'AC-18: call 20 prints exactly one decodable JSON line')
        or diag("stdout=[$last->{out}]");
    if (ref($d) eq 'HASH') {
        is($d->{hookSpecificOutput}{hookEventName}, 'PostToolUse', 'AC-18: call 20 hookEventName is PostToolUse');
        like($d->{hookSpecificOutput}{additionalContext}, n5_regex(31, 32),
            'AC-18: call 20 additionalContext matches the N5 text with N 31 or 32');
    }
    is($last->{err}, '', 'AC-18: call 20 stderr is empty');
    is(slurp(nudged_path($home, $sid)), "$marker_epoch\n", 'AC-18: the .nudged file holds the marker epoch');

    # AC-19: calls 21-39 quiet (marker unchanged), call 40 quiet too.
    for my $i (21 .. 40) {
        my $r = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env);
        is($r->{out}, '', "AC-19: call $i prints nothing (marker unchanged)");
    }

    # a new, later marker epoch -> fires again at the next 20th call (60).
    my $marker_epoch2 = time() - 45 * 60;
    write_marker($state, $sid, $marker_epoch2);
    my $last60;
    for my $i (41 .. 60) {
        $last60 = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env);
        is($last60->{out}, '', "AC-19: call $i prints nothing") if $i < 60;
    }
    my $d60 = decode_out($last60->{out});
    ok(ref($d60) eq 'HASH', 'AC-19: call 60 prints exactly one decodable JSON line')
        or diag("stdout=[$last60->{out}]");
    if (ref($d60) eq 'HASH') {
        like($d60->{hookSpecificOutput}{additionalContext}, n5_regex(45, 46),
            'AC-19: call 60 additionalContext matches the N5 text with N 45 or 46 (a new operator prompt nudges again)');
    }
}

# =============================================================================
# AC-20 (B15): quiet cases -- armed, judge, operator off, fresh marker,
# missing marker, garbage marker. An agent off does NOT suppress it. Every
# run: rc 0, stderr empty, 0 tickets left after call 20.
# =============================================================================
{
    my %cases = (
        armed => sub {
            my ($env, $home, $state, $sid) = @_;
            touch_armed($state, $sid);
            write_marker($state, $sid, time() - 31 * 60);
        },
        judge => sub {
            my ($env, $home, $state, $sid) = @_;
            $env->{BP_LEDGER} = '1';
            $env->{BP_ROLE}   = 'harvest-judge';
            write_marker($state, $sid, time() - 31 * 60);
        },
        'operator off' => sub {
            my ($env, $home, $state, $sid) = @_;
            write_off($state, $sid, 'operator');
            write_marker($state, $sid, time() - 31 * 60);
        },
        'fresh marker' => sub {
            my ($env, $home, $state, $sid) = @_;
            write_marker($state, $sid, time() - 5 * 60);
        },
        'absent marker' => sub {
            my ($env, $home, $state, $sid) = @_;
            # no marker written at all
        },
        'garbage marker' => sub {
            my ($env, $home, $state, $sid) = @_;
            make_path("$state/continuity/prompted");
            open(my $fh, '>', "$state/continuity/prompted/$sid") or die $!;
            print {$fh} "garbage\n";
            close $fh;
        },
    );
    for my $label (sort keys %cases) {
        my $sid = fresh_sid();
        my ($env, $home, $state, $proj) = base_env();
        scrub_arm_nudge_min($env);
        $cases{$label}->($env, $home, $state, $sid);
        my $last;
        for (1 .. 20) { $last = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env) }
        if ($label eq 'armed') {
            isnt($last->{out}, '', "AC-20 [$label]: call 20 fires (armed makes gate true)");
        } else {
            is($last->{out}, '', "AC-20 [$label]: call 20 prints nothing");
        }
        is($last->{rc}, 0, "AC-20 [$label]: call 20 exits 0");
        is($last->{err}, '', "AC-20 [$label]: call 20 stderr is empty");
        is(scalar(ticket_names(ticket_dir($home, $sid))), 0, "AC-20 [$label]: 0 tickets remain after call 20");
    }

    # positive: an agent off does NOT suppress the nudge.
    {
        my $sid = fresh_sid();
        my ($env, $home, $state, $proj) = base_env();
        scrub_arm_nudge_min($env);
        write_off($state, $sid, 'agent');
        write_marker($state, $sid, time() - 31 * 60);
        my $last;
        for (1 .. 20) { $last = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env) }
        is($last->{rc}, 0, 'AC-20 [agent off]: call 20 exits 0');
        is($last->{err}, '', 'AC-20 [agent off]: call 20 stderr is empty');
        isnt($last->{out}, '', 'AC-20 [agent off]: call 20 prints the N5 line (agent off does not suppress it)');
        is(scalar(ticket_names(ticket_dir($home, $sid))), 0, 'AC-20 [agent off]: 0 tickets remain after call 20');
    }
}

# =============================================================================
# AC-21 (B16): CCPRAXIS_ARM_NUDGE_MIN override. 5 with a 6-min marker fires
# with N 6 or 7; 0/abc/1441/'' with a 6-min marker fall back to 30 (so a
# 6-minute-old marker stays quiet).
# =============================================================================
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    $env->{CCPRAXIS_ARM_NUDGE_MIN} = 5;
    write_marker($state, $sid, time() - 6 * 60);
    my $last;
    for (1 .. 20) { $last = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env) }
    my $d = decode_out($last->{out});
    ok(ref($d) eq 'HASH', 'AC-21: CCPRAXIS_ARM_NUDGE_MIN=5 with a 6-min marker fires at call 20')
        or diag("stdout=[$last->{out}]");
    like($d->{hookSpecificOutput}{additionalContext}, n5_regex(6, 7),
        'AC-21: N is 6 or 7') if ref($d) eq 'HASH';

    for my $bad (0, 'abc', 1441, '') {
        my $sid2 = fresh_sid();
        my ($env2, $home2, $state2, $proj2) = base_env();
        $env2->{CCPRAXIS_ARM_NUDGE_MIN} = $bad;
        write_marker($state2, $sid2, time() - 6 * 60);
        my $last2;
        for (1 .. 20) { $last2 = fire_reminder(mkpayload(sid => $sid2, cwd => $proj2), %$env2) }
        is($last2->{out}, '', "AC-21: CCPRAXIS_ARM_NUDGE_MIN='$bad' falls back to 30 -- a 6-min marker stays quiet");
    }
}

# =============================================================================
# AC-22 (B17): focused and unarmed with a stale marker -> one line, X (the
# unchanged reminder text) + "\n" + the N5 line.
# =============================================================================
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    scrub_arm_nudge_min($env);
    is(do_focus($sid, $proj), 0, 'AC-22 fixture: focus succeeds');
    write_marker($state, $sid, time() - 31 * 60);
    my $last;
    for (1 .. 20) { $last = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env) }
    my $d = decode_out($last->{out});
    ok(ref($d) eq 'HASH', 'AC-22: call 20 (focused, unarmed, stale marker) prints exactly one decodable JSON line')
        or diag("stdout=[$last->{out}]");
    if (ref($d) eq 'HASH') {
        # The existing reminder text (X) already carries its own embedded
        # "\n" (prefix sentence, then the almanac-task.pl hint line), so the
        # N5 line -- always a single line with no embedded "\n" -- is
        # recovered from the END of $ctx, not by splitting on the FIRST
        # "\n".
        my $ctx = $d->{hookSpecificOutput}{additionalContext} // '';
        my ($x, $rest) = $ctx =~ /\A(.*)\n([^\n]*)\z/s;
        # package 04-continuity-threads (behaviour 18): do_focus() attaches
        # the session to thread "owned-thread" (Almanac::Thread::create with
        # --session), so the reminder half now names that thread.
        assert_reminder_text_named($x // $ctx, 20, $ALM, 'owned-thread', 'AC-22: the reminder half (X)');
        like($rest // '', n5_regex(31, 32), 'AC-22: the N5 half follows one "\n"');
    }
}

# =============================================================================
# AC-23 (B18): a stale marker, R-12-style perl shim -- calls 1 and 19 launch
# zero perl, call 20 launches exactly one, and call 20 printed the N5 line.
# =============================================================================
{
    my $real_perl = (File::Spec->file_name_is_absolute($^X) && -x $^X) ? $^X
                   : do { my $p = `bash -c "command -v perl"`; chomp $p; $p };
    my $shim = tempdir(CLEANUP => 1);
    open(my $pfh, '>', "$shim/perl") or die $!;
    print {$pfh} "#!/usr/bin/env bash\nprintf 'perl %s\\n' \"\$\$\" >> \"\$SHIM_LOG\"\nexec \"$real_perl\" \"\$\@\"\n";
    close $pfh;
    chmod 0755, "$shim/perl";

    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    scrub_arm_nudge_min($env);
    write_marker($state, $sid, time() - 31 * 60);
    my (undef, $log) = tempfile();
    $env->{SHIM_LOG} = $log;
    $env->{PATH} = "$shim:$ENV{PATH}";

    my $last;
    for my $i (1 .. 20) {
        unlink $log;
        $last = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env);
        my $count = () = ((slurp($log) // '') =~ /^perl /mg);
        if ($i == 20) {
            is($count, 1, 'AC-23: the firing call (20, stale marker) launches perl exactly once');
            isnt($last->{out}, '', 'AC-23: ...and call 20 actually printed the N5 line');
        } elsif ($i == 1 || $i == 19) {
            is($count, 0, "AC-23: an ordinary call ($i) launches perl ZERO times");
        }
    }
}

# =============================================================================
# AC-24 (B19): a stale marker, 19 main calls, then one subagent call (never
# counted, never prints), then the 20th main call prints the N5 line.
# =============================================================================
{
    my $sid = fresh_sid();
    my ($env, $home, $state, $proj) = base_env();
    scrub_arm_nudge_min($env);
    write_marker($state, $sid, time() - 31 * 60);
    for (1 .. 19) { fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env) }

    my $sub_r = fire_reminder(mkpayload(sid => $sid, cwd => $proj, agent_id => 'sub-1'), %$env);
    is($sub_r->{out}, '', 'AC-24: a subagent call prints nothing (not counted)');

    my $r20 = fire_reminder(mkpayload(sid => $sid, cwd => $proj), %$env);
    isnt($r20->{out}, '', 'AC-24: the next main call (the true 20th) prints the N5 line');
}

# =============================================================================
# AC-25: static scan for R-12 (no spawn/fork/alarm) and R-11 (one <STDIN>)
# is already asserted above, byte-identically, in the R-11 and R-12 blocks
# of this same file -- no further assertion is needed here; this comment
# exists only for traceability from the spec's AC numbering.
# =============================================================================

done_testing();
