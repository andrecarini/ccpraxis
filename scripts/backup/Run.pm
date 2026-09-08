# Run.pm -- the backup driver engine (blueprint backup-driver, package
# 01-driver-skeleton).
#
# This module owns all three shared contracts that packages 02-06 depend on
# and may not reinvent (spec S1, Decision 10):
#   Contract A -- the decision record and the closed decision-kind enum
#   Contract B -- the resume-token grammar
#   Contract C -- the run-state file (location, format, durability rule)
# plus phase discovery (S2.4) and the state machine that drives a run
# (execute()).
#
# DELIBERATE SEAM: execute() computes an outcome and RETURNS it. It never
# prints and never calls exit. scripts/backup.pl is the only place that
# turns a return value into stdout JSON / stderr text / a process exit code
# (spec S2.7). This is what lets 06 (or any future test) drive the engine
# in-process without capturing stdout, and it is the one deliberate
# improvement over bp-drive-next.pl's _cmd_* subs, which print directly.
#
# MSYS2_ARG_CONV_EXCL: this module spawns NO native binary and sets no such
# env var. Package 01 performs no git operation of any kind. A later phase
# module (02-05) that DOES spawn a native Windows binary with ':'-bearing
# args must set that guard itself, paired with hand-translated paths (see
# vault-sync.pl's git_path) -- see CLAUDE.md's MSYS2 landmine writeup. It
# must not be set here, because doing so process-wide would silently change
# the environment every later phase module inherits.

package Backup::Run;
use strict;
use warnings;
use Exporter 'import';
use JSON::PP;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Temp ();
use Cwd qw(abs_path);

our @EXPORT_OK = qw(
    DECISION_KINDS is_decision_kind validate_decision
    mint_token parse_token
    run_state_path read_run_state write_run_state
    discover_phases
    execute
);

# ===========================================================================
# CONTRACT A -- the decision record and the KIND ENUM (spec S2.1)
#
# One definition. Nothing else in this initiative may hard-code a kind
# string -- AC3 greps scripts/backup.pl for every value below and asserts
# absence. The array itself (@Backup::Run::DECISION_KINDS) is read directly
# by package 06's "every kind has a documented presentation" check, not a
# copy in prose.
# ===========================================================================
our @DECISION_KINDS = qw(
    dirty_worktree
    remote_merge_conflict
    clone_live_divergence
    readme_drift
    settings_key
    marketplace_key
    file_conflict
    container_settings_key
    sensitive_finding
    push_confirmation
    vault_conflict
    project_registration
    plugin_install
    step_failure
);

our $STATE_FORMAT = 1;

sub DECISION_KINDS { return @DECISION_KINDS; }

sub is_decision_kind {
    my ($k) = @_;
    return 0 unless defined $k && length $k;
    for my $known (@DECISION_KINDS) {
        return 1 if $known eq $k;
    }
    return 0;
}

# validate_decision($href) -> (1) | (0, $reason)
#
# $reason always names the offending field, so a caller (or a diag()) can
# report *what* was wrong without re-deriving it.
#
# NOTE on the id grammar: the spec's prose (S2.1) gives
# ^[A-Za-z0-9][A-Za-z0-9._:-]* which omits '_'. The oracle test (AC20)
# constructs ids like "stub.dirty_worktree.check" for every kind, several of
# which contain '_' themselves -- so the grammar actually enforced here
# additionally allows '_' in continuation characters. Flagged in the
# implementer report as a spec/test discrepancy; the test is the oracle and
# wins per the dispatch instructions.
sub validate_decision {
    my ($d) = @_;
    return (0, 'decision record must be a hashref') unless ref($d) eq 'HASH';

    my $kind = $d->{kind};
    return (0, "kind is missing or is not a recognized decision kind"
             . (defined $kind ? " ('$kind')" : ''))
        unless defined $kind && is_decision_kind($kind);

    my $title = $d->{title};
    return (0, 'title is required and must be a non-empty single-line string of <= 200 chars')
        unless defined $title && length $title && $title !~ /\n/ && length($title) <= 200;

    my $id = $d->{id};
    return (0, "id is required and must match ^[A-Za-z0-9][A-Za-z0-9_.:-]*\$")
        unless defined $id && $id =~ /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/;

    my $phase = $d->{phase};
    return (0, 'phase is required to validate the id prefix')
        unless defined $phase && length $phase;
    return (0, "id '$id' must begin with its phase prefix '$phase.'")
        unless $id =~ /^\Q$phase\E\./;

    my $choices = $d->{choices};
    return (0, 'choices must be an arrayref with at least 2 entries')
        unless ref($choices) eq 'ARRAY' && scalar(@$choices) >= 2;

    my %seen_choice;
    for my $c (@$choices) {
        return (0, 'each entry in choices must be a hashref with id and label')
            unless ref($c) eq 'HASH';
        my $cid = $c->{id};
        return (0, "each choice id must match ^[a-z0-9][a-z0-9_-]*\$")
            unless defined $cid && $cid =~ /^[a-z0-9][a-z0-9_-]*$/;
        return (0, "duplicate choice id '$cid'") if $seen_choice{$cid}++;
        return (0, "choice '$cid' must have a non-empty label")
            unless defined $c->{label} && length $c->{label};
    }

    return (1);
}

# ===========================================================================
# CONTRACT B -- the resume token (spec S2.2)
#   token := "bkp1" "." run_id "." seq
#   run_id := [0-9a-f]{16}
#   seq    := [1-9][0-9]{0,8}
# No secret, no signature -- the run-state file is the authority; a forged
# token names a run that does not exist and is refused as unknown.
# ===========================================================================
sub mint_token {
    my ($run_id, $seq) = @_;
    return "bkp1.$run_id.$seq";
}

sub parse_token {
    my ($tok) = @_;
    return () unless defined $tok;
    if ($tok =~ /^bkp1\.([0-9a-f]{16})\.([1-9][0-9]{0,8})$/) {
        return ($1, $2 + 0);
    }
    return ();
}

# ===========================================================================
# CONTRACT C -- the run-state file (spec S2.3)
# ===========================================================================

# run_state_path() -> absolute path to the state FILE.
#
# Resolution order: $ENV{BACKUP_RUN_STATE} (if set and non-empty, used
# verbatim -- the test-harness override) else
# <home>/.claude/.backup-driver/run.json, where <home> is
# $ENV{HOME} // $ENV{USERPROFILE}. Refuses (dies) rather than guessing when
# neither is set.
#
# The path is treated as an OPAQUE STRING throughout this module: it may
# contain non-ASCII (C:\Users\Andr\x{e9}) or the MSYS /c/... form, is opened
# only by perl, and is never handed to a native binary -- so it is never
# "winified" here.
sub run_state_path {
    my $override = $ENV{BACKUP_RUN_STATE};
    return $override if defined $override && length $override;

    my $home = $ENV{HOME};
    $home = $ENV{USERPROFILE} unless defined $home && length $home;
    die { code => 'internal',
          message => 'cannot determine the run-state location: neither HOME nor USERPROFILE is set' }
        unless defined $home && length $home;

    (my $norm = $home) =~ s{\\}{/}g;
    $norm =~ s{/+$}{};
    return "$norm/.claude/.backup-driver/run.json";
}

sub _dirname_of {
    my ($path) = @_;
    (my $p = $path) =~ s{\\}{/}g;
    $p =~ s{/[^/]+$}{};
    return length($p) ? $p : '.';
}

# read_run_state($path) -> $href | undef (file absent -- a fresh run)
#
# An unparseable file, a missing run_id, or format != $STATE_FORMAT is NEVER
# treated as absent -- that would silently restart the run from the top,
# exactly what Contract C's durability rule forbids from a different
# direction. It dies with a structured { code => 'state_corrupt', ... }
# instead, and the file is left untouched on disk (--restart is the only way
# past it).
sub read_run_state {
    my ($path) = @_;
    return undef unless -f $path;

    open my $fh, '<:raw', $path or die "Backup::Run: cannot read $path: $!\n";
    local $/;
    my $raw = <$fh>;
    close $fh;

    my $data = eval { JSON::PP->new->decode($raw) };
    if ($@ || ref($data) ne 'HASH' || !defined $data->{run_id}
        || !defined $data->{format} || $data->{format} != $STATE_FORMAT) {
        die { code => 'state_corrupt',
              message => "run-state file is corrupt or unrecognized: $path (re-run with --restart to discard it)" };
    }

    # R3 (coordinator ruling, closes a MAJOR): phase_index is read off disk
    # and used as a raw array index -- it is untrusted input, not a value
    # this module authored. A negative value ran the LAST phase first (Perl
    # negative-index semantics), and an out-of-range value skipped the loop
    # entirely while still reporting success. Every field read from the
    # state file gets the same scrutiny; this is the one that is actually
    # used as an index.
    my $phase_order = ref($data->{phase_order}) eq 'ARRAY' ? $data->{phase_order} : [];
    my $max_index   = scalar(@$phase_order);
    my $idx         = $data->{phase_index};
    if (!defined $idx || ref($idx) ne ''
        || "$idx" !~ /^-?\d+$/ || $idx < 0 || $idx > $max_index) {
        die { code => 'state_corrupt',
              message => "run-state file has an invalid phase_index: $path (re-run with --restart to discard it)" };
    }

    return $data;
}

# write_run_state($path, $data) -- atomic temp+rename, JSON::PP canonical+pretty.
# A reader must never see a torn file.
sub write_run_state {
    my ($path, $data) = @_;
    my $dir = _dirname_of($path);
    make_path($dir) unless -d $dir;

    my $json = JSON::PP->new->canonical->pretty->encode($data);
    my $tmp  = "$path.tmp.$$";
    open my $fh, '>:raw', $tmp or die "Backup::Run: cannot write $tmp: $!\n";
    print {$fh} $json;
    # Best-effort durability past a hard kill (redteam m3): temp+rename gives
    # atomicity (a reader never sees a torn file) but not crash durability by
    # itself. IO::Handle::sync is not guaranteed on every Perl, so this is
    # opportunistic -- never fatal if unsupported on the host.
    eval { $fh->flush; $fh->sync; };
    close $fh;
    rename $tmp, $path or do { unlink $tmp; die "Backup::Run: cannot rename $tmp -> $path: $!\n"; };
    return 1;
}

# ===========================================================================
# Phase discovery (spec S2.4) -- discovery, not registration lists.
# ===========================================================================

sub _resolve_phase_dir {
    my $override = $ENV{BACKUP_PHASE_DIR};
    return $override if defined $override && length $override;
    return dirname(abs_path(__FILE__));
}

# discover_phases($dir?) -> list of { name, order, resumable, title, pkg }
# sorted by ascending order, ties broken by ascending name.
#
# Skips a file literally named Run.pm -- it lives in this same directory in
# production, and must never be mistaken for a phase module.
sub discover_phases {
    my ($dir) = @_;
    $dir = _resolve_phase_dir() unless defined $dir && length $dir;

    opendir(my $dh, $dir)
        or die { code => 'phase_load_failed', message => "cannot open phase directory: $dir ($!)" };
    my @files = sort grep { /\.pm$/ && $_ ne 'Run.pm' } readdir($dh);
    closedir $dh;

    my @phases;
    my %seen_name;
    for my $f (@files) {
        my ($base) = $f =~ /^(.+)\.pm$/;
        # m2 (redteam MINOR): require() by ABSOLUTE path always, per spec
        # S2.4. A relative BACKUP_PHASE_DIR enumerated the right directory
        # here but let require() resolve the joined path through @INC
        # instead -- which either fails closed (the common case) or, worse,
        # silently loads a DIFFERENT file of the same relative name sitting
        # under an @INC entry.
        my $path = abs_path("$dir/$f") // "$dir/$f";
        $path =~ s{\\}{/}g;
        my $pkg = "Backup::Phase::$base";

        {
            local $@;
            my $ok = eval { require $path; 1 };
            unless ($ok) {
                my $why = $@ || 'unknown error';
                die { code => 'phase_load_failed', message => "failed to load phase module '$f': $why" };
            }
        }
        # Fetch these as CODEREFS and invoke them as plain functions -- NOT
        # as indirect method calls ($pkg->phase_spec / $pkg->run_phase).
        # Every phase module (spec S2.8) defines run_phase as a plain sub
        # `sub run_phase { my ($ctx) = @_; ... }` that expects to be called
        # with exactly one argument. An indirect method call implicitly
        # prepends the invocant (the class-name string) to @_, which shifts
        # $ctx into that string and everything downstream that dereferences
        # $ctx dies with "Can't use string ... as a HASH ref". Calling the
        # coderef directly avoids that implicit invocant entirely.
        my $spec_fn = $pkg->can('phase_spec');
        my $run_fn  = $pkg->can('run_phase');
        unless ($spec_fn && $run_fn) {
            die { code => 'phase_load_failed',
                  message => "phase module '$f' does not implement phase_spec/run_phase (expected package $pkg)" };
        }

        my $spec = eval { $spec_fn->() };
        unless (ref($spec) eq 'HASH'
            && defined $spec->{name} && $spec->{name} =~ /^[a-z][a-z0-9_]*$/
            && defined $spec->{order} && $spec->{order} =~ /^-?\d+$/
            && defined $spec->{resumable}) {
            die { code => 'phase_load_failed', message => "phase module '$f' returned an invalid phase_spec" };
        }
        if ($seen_name{ $spec->{name} }++) {
            die { code => 'phase_load_failed', message => "duplicate phase name '$spec->{name}' (from '$f')" };
        }

        push @phases, {
            name      => $spec->{name},
            order     => $spec->{order} + 0,
            resumable => $spec->{resumable} ? 1 : 0,
            title     => $spec->{title},
            pkg       => $pkg,
            run_fn    => $run_fn,
        };
    }

    @phases = sort { $a->{order} <=> $b->{order} || $a->{name} cmp $b->{name} } @phases;
    return @phases;
}

# ===========================================================================
# Internal helpers
# ===========================================================================

sub _new_run_id {
    my @hex = ('0' .. '9', 'a' .. 'f');
    return join('', map { $hex[int(rand(16))] } 1 .. 16);
}

# _discard_existing_state_file($path, $now_fn) -> $discarded_path | undef
#
# R7 (coordinator ruling, closes a MAJOR): --restart used to destroy a
# paused run with no copy left behind -- and both the state_phase_drift and
# state_corrupt refusals recommend --restart BY NAME, so this tool routinely
# steered the operator into the destructive command. Decision 5 exists
# because a 90-minute vault sync was lost unrecoverably; this must not
# reproduce that. Renames (never deletes) so the discarded state is
# recoverable; returns undef when there is nothing on disk to discard.
sub _discard_existing_state_file {
    my ($path, $now_fn) = @_;
    return undef unless -f $path;
    my $discarded = "$path.discarded-" . $now_fn->();
    rename $path, $discarded
        or die { code => 'internal', message => "cannot rename $path -> $discarded: $!" };
    return $discarded;
}

sub _err_result {
    my ($run_id, $code, $message, $detail) = @_;
    my $r = { status => 'error', run_id => $run_id, error => { code => $code, message => $message } };
    $r->{error}{detail} = $detail if defined $detail;
    return $r;
}

# _parse_run_args(@argv) -> hashref | dies with { code => 'usage', message }
sub _parse_run_args {
    my (@argv) = @_;
    my ($restart, $resume_token) = (0, undef);
    my @answer_pairs;

    while (@argv) {
        my $a = shift @argv;
        if ($a eq '--json') {
            # accepted, documented as the wrapper's calling convention; output
            # is always JSON regardless (spec S2.5) so this flag is a no-op here.
        }
        elsif ($a eq '--restart') {
            $restart = 1;
        }
        elsif ($a eq '--resume') {
            # NIT (redteam): a bare "--resume" followed by another flag
            # (e.g. "--resume --answer x=y") must not silently swallow that
            # flag as if it were the token -- reject anything that looks
            # like an option instead of a value.
            die { code => 'usage', message => '--resume requires a token argument' }
                unless @argv && $argv[0] !~ /^--/;
            $resume_token = shift @argv;
        }
        elsif ($a eq '--answer') {
            die { code => 'usage', message => '--answer requires an id=choice argument' } unless @argv;
            my $val = shift @argv;
            my $eq = index($val, '=');
            die { code => 'usage', message => "malformed --answer value '$val' (expected id=choice)" }
                if $eq < 1;
            my $id     = substr($val, 0, $eq);
            my $choice = substr($val, $eq + 1);
            push @answer_pairs, [ $id, $choice ];
        }
        else {
            die { code => 'usage', message => "unrecognized option '$a'" };
        }
    }

    die { code => 'usage', message => '--answer requires --resume' }
        if @answer_pairs && !defined $resume_token;
    die { code => 'usage', message => '--restart cannot be combined with --resume' }
        if $restart && defined $resume_token;

    return { restart => $restart, resume_token => $resume_token, answer_pairs => \@answer_pairs };
}

sub _as_struct_error {
    my ($err) = @_;
    return ref($err) eq 'HASH' ? $err : { code => 'internal', message => "$err" };
}

# ===========================================================================
# execute($opts) -> ($exit_code, $result_href)
#
# $opts: argv (arrayref of the post-'run' arguments), state_path, phase_dir,
# now (coderef, defaults to sub { time }). Prints nothing, never exits.
#
# R4 (coordinator ruling, closes a MAJOR): this is a thin wrapper around
# _execute_impl() whose only job is to guarantee the output contract holds
# even when something dies that no inner eval caught -- previously an
# uncaught die (a full disk, an AV/indexer lock during rename, a permission
# change mid-run -- all real on this host) produced exit 255 and ZERO bytes
# on stdout, breaking "exactly one JSON object per invocation" at exactly
# the moment a caller most needs to know what happened. Every internal eval
# inside _execute_impl still returns its own precise error code; this outer
# net only catches what escapes those.
# ===========================================================================
sub execute {
    my ($opts) = @_;
    my ($exit_code, $result);
    {
        local $@;
        my @ret = eval { _execute_impl($opts) };
        if ($@) {
            my $e = _as_struct_error($@);
            return (1, _err_result(undef, 'internal', "unhandled internal error: $e->{message}"));
        }
        ($exit_code, $result) = @ret;
    }
    return ($exit_code, $result);
}

sub _execute_impl {
    my ($opts) = @_;
    $opts //= {};
    my @argv   = @{ $opts->{argv} // [] };
    my $now_fn = $opts->{now} // sub { time };

    # ---- 1. parse flags (no I/O yet) ----
    my $parsed;
    {
        local $@;
        $parsed = eval { _parse_run_args(@argv) };
        if ($@) {
            my $e = _as_struct_error($@);
            return (2, _err_result(undef, $e->{code}, $e->{message}));
        }
    }
    my $restart      = $parsed->{restart};
    my $resume_token = $parsed->{resume_token};
    my @answer_pairs = @{ $parsed->{answer_pairs} };

    # ---- 2. resolve the state path ----
    my $state_path;
    {
        local $@;
        $state_path = eval { $opts->{state_path} // run_state_path() };
        if ($@) {
            my $e = _as_struct_error($@);
            return (1, _err_result(undef, $e->{code}, $e->{message}));
        }
    }

    # ---- 3. discover phases ----
    my @discovered;
    {
        local $@;
        @discovered = eval { discover_phases($opts->{phase_dir}) };
        if ($@) {
            my $e = _as_struct_error($@);
            return (1, _err_result(undef, $e->{code}, $e->{message}));
        }
    }
    my @discovered_names = map { $_->{name} } @discovered;

    # ---- 4. load existing state (unless --restart discards it outright --
    #         this is the escape hatch past a corrupt file: --restart never
    #         even attempts to parse what is on disk) ----
    my $existing_state;
    my $discarded_state_path;
    if ($restart) {
        # R7: rename (never delete) whatever is on disk before starting
        # fresh -- see _discard_existing_state_file's header for why.
        local $@;
        eval { $discarded_state_path = _discard_existing_state_file($state_path, $now_fn) };
        if ($@) {
            my $e = _as_struct_error($@);
            return (1, _err_result(undef, $e->{code} // 'internal', $e->{message}));
        }
    }
    else {
        local $@;
        $existing_state = eval { read_run_state($state_path) };
        if ($@) {
            my $e = _as_struct_error($@);
            return (1, _err_result(undef, $e->{code}, $e->{message}));
        }
    }

    # ---- 4.5. R1 (coordinator ruling, closes the BLOCKER): a bare `run`
    # (no --resume, no --restart) against a run whose status is TERMINAL
    # (complete / complete_with_failures) starts a FRESH run -- exactly as
    # --restart does, without requiring the flag. Before this ruling, a
    # second bare invocation against a finished run was a silent no-op that
    # re-reported the OLD result with the OLD run_id and exit 0: once
    # phases exist, that is a backup tool that stops backing up while
    # reporting success. A run that is merely PAUSED is untouched by this --
    # AC8's "never silently restarts from the top" guarantee is about an
    # UNFINISHED run, and must not regress.
    if (!$restart && !defined($resume_token) && defined $existing_state) {
        my $prior_status = $existing_state->{status} // '';
        if ($prior_status eq 'complete' || $prior_status eq 'complete_with_failures') {
            local $@;
            eval { $discarded_state_path = _discard_existing_state_file($state_path, $now_fn) };
            if ($@) {
                my $e = _as_struct_error($@);
                return (1, _err_result($existing_state->{run_id}, $e->{code} // 'internal', $e->{message}));
            }
            $existing_state = undef;   # proceed exactly as if no state existed
        }
    }

    # ---- 5. phase-set drift check ----
    if (defined $existing_state) {
        my $stored = $existing_state->{phase_order} // [];
        if (join("\x00", @$stored) ne join("\x00", @discovered_names)) {
            return (1, _err_result($existing_state->{run_id}, 'state_phase_drift',
                'the discovered phase set no longer matches this run\'s frozen phase_order; use --restart'));
        }
    }

    # ---- 6. resume-token handling ----
    if (defined $resume_token) {
        my ($tok_run_id, $tok_seq) = parse_token($resume_token);
        unless (defined $tok_run_id) {
            return (3, _err_result(defined $existing_state ? $existing_state->{run_id} : undef,
                'token_malformed', "resume token '$resume_token' does not match the bkp1.<run_id>.<seq> grammar"));
        }
        unless (defined $existing_state && ($existing_state->{run_id} // '') eq $tok_run_id) {
            return (3, _err_result(defined $existing_state ? $existing_state->{run_id} : undef,
                'token_unknown', 'resume token names a run that does not exist'));
        }

        my $consumed_seq = $existing_state->{consumed_seq} // 0;
        my $token_seq    = $existing_state->{token_seq} // 0;

        # A replayed token is checked ahead of the paused/not-paused check
        # deliberately: replaying the token from a resume that already
        # succeeded must report token_replayed even though the run's status
        # has since moved on to complete (behavior 4 / AC7).
        if ($tok_seq <= $consumed_seq) {
            return (3, _err_result($existing_state->{run_id}, 'token_replayed',
                'resume token has already been consumed'));
        }

        unless (($existing_state->{status} // '') eq 'paused') {
            return (3, _err_result($existing_state->{run_id}, 'token_unknown',
                'no run is currently paused (no token is outstanding)'));
        }

        if ($tok_seq != $token_seq && $tok_seq < $token_seq) {
            return (3, _err_result($existing_state->{run_id}, 'token_replayed',
                'resume token has already been superseded'));
        }
        if ($tok_seq > $token_seq) {
            return (3, _err_result($existing_state->{run_id}, 'token_unknown',
                'resume token names a pause that never happened'));
        }

        # ---- answer validation -- refuses without mutating state ----
        my %pending_by_id = map { $_->{id} => $_ } @{ $existing_state->{pending}{decisions} // [] };

        for my $pair (@answer_pairs) {
            my ($id) = @$pair;
            unless (exists $pending_by_id{$id}) {
                my @valid = sort keys %pending_by_id;
                return (4, _err_result($existing_state->{run_id}, 'answer_unknown_id',
                    "answer references unknown decision id '$id'; valid pending id(s): " . join(', ', @valid)));
            }
        }
        my %seen_answer;
        for my $pair (@answer_pairs) {
            my ($id) = @$pair;
            if ($seen_answer{$id}++) {
                return (4, _err_result($existing_state->{run_id}, 'answer_duplicate',
                    "decision id '$id' was answered more than once"));
            }
        }
        my %choice_for;
        for my $pair (@answer_pairs) {
            my ($id, $choice) = @$pair;
            my $dec = $pending_by_id{$id};
            my %valid_choice = map { $_->{id} => 1 } @{ $dec->{choices} // [] };
            unless ($valid_choice{$choice}) {
                my @valid = map { $_->{id} } @{ $dec->{choices} // [] };
                return (4, _err_result($existing_state->{run_id}, 'answer_unknown_choice',
                    "decision '$id': choice '$choice' is not valid; valid choices: " . join(', ', @valid)));
            }
            $choice_for{$id} = $choice;
        }
        for my $pid (sort keys %pending_by_id) {
            unless (exists $choice_for{$pid}) {
                return (4, _err_result($existing_state->{run_id}, 'answer_missing',
                    "pending decision '$pid' was not answered"));
            }
        }

        # All answers accepted -- consume the token BEFORE any phase body
        # runs (durability point 5). This is what makes replay detection
        # real: consumed_seq is on disk before we ever call run_phase again.
        $existing_state->{answers} //= {};
        $existing_state->{answers}{$_} = $choice_for{$_} for keys %choice_for;
        $existing_state->{consumed_seq} = $tok_seq;
        $existing_state->{pending}      = undef;
        $existing_state->{status}       = 'running';
        $existing_state->{updated_at}   = $now_fn->();
        eval { write_run_state($state_path, $existing_state) };
        if ($@) {
            return (1, _err_result($existing_state->{run_id}, 'internal', "failed to persist consumed state: $@"));
        }
    }
    else {
        # No token given. A paused run may never continue silently: that
        # would drop the pending decisions on the floor (spec S2.2).
        if (defined $existing_state && (($existing_state->{status} // '') eq 'paused')) {
            return (3, _err_result($existing_state->{run_id}, 'token_missing',
                'this run is paused awaiting a decision; re-invoke with --resume and --answer'));
        }
    }

    # ---- 7. build (fresh/--restart) or reuse (continuing) run state ----
    my $state;
    if (defined $existing_state) {
        $state = $existing_state;
    }
    else {
        my $run_id = _new_run_id();
        my $now    = $now_fn->();
        my %phases_init = map {
            $_ => { status => 'pending', started_at => undef, completed_at => undef,
                    error => undef, items => {}, scratch => {} }
        } @discovered_names;

        $state = {
            format       => $STATE_FORMAT,
            run_id       => $run_id,
            started_at   => $now,
            updated_at   => $now,
            status       => 'running',
            phase_order  => [ @discovered_names ],
            phase_index  => 0,
            phases       => \%phases_init,
            token_seq    => 0,
            consumed_seq => 0,
            pending      => undef,
            answers      => {},
            notes        => [],
        };
        eval { write_run_state($state_path, $state) };   # durability point 1
        if ($@) {
            return (1, _err_result($run_id, 'internal', "failed to persist initial state: $@"));
        }
    }

    # ---- 8. phase execution loop ----
    for (my $i = $state->{phase_index}; $i < scalar(@discovered); $i++) {
        my $ph   = $discovered[$i];
        my $name = $ph->{name};
        $state->{phase_index} = $i;
        my $pstate = $state->{phases}{$name} //= { status => 'pending', items => {}, scratch => {} };
        my $prior_pstatus = $pstate->{status} // '';

        # R6 (coordinator ruling, closes a MAJOR): an answer authorises ONE
        # attempt, not a phase forever. Re-entering a phase whose PRIOR
        # status was "running" means it died mid-execution -- what it did
        # is unknown -- so its items/scratch AND any of its own answers are
        # cleared, regardless of the resumable flag: a stale "yes" consent
        # must never be silently replayed after a mid-execution kill.
        # Re-entering after "paused" PRESERVES answers (that is the whole
        # point of the pause/answer cycle, AC13/AC32 depend on it); for a
        # non-resumable phase it still clears items/scratch on that path,
        # unchanged from before this ruling.
        if ($prior_pstatus eq 'running') {
            $pstate->{items}   = {};
            $pstate->{scratch} = {};
            if (ref($state->{answers}) eq 'HASH') {
                my $prefix = "$name.";
                for my $aid (keys %{ $state->{answers} }) {
                    delete $state->{answers}{$aid} if index($aid, $prefix) == 0;
                }
            }
        }
        elsif ($prior_pstatus eq 'paused' && !$ph->{resumable}) {
            $pstate->{items}   = {};
            $pstate->{scratch} = {};
        }
        $pstate->{status}     = 'running';
        $pstate->{started_at} = $now_fn->() unless defined $pstate->{started_at};
        $pstate->{items}   //= {};
        $pstate->{scratch} //= {};

        # Persist the "running" flip BEFORE invoking the phase body -- this
        # is what makes the R6 "running" re-entry above observable at all: a
        # phase that dies mid-execution without ever calling checkpoint must
        # still leave "running" (not "paused") on disk for the next
        # invocation to detect.
        $state->{updated_at} = $now_fn->();
        {
            local $@;
            eval { write_run_state($state_path, $state) };
            if ($@) {
                my $e = _as_struct_error($@);
                return (1, _err_result($state->{run_id}, 'internal',
                    "failed to persist phase-start state for '$name': $e->{message}"));
            }
        }

        my $answers_snapshot = { %{ $state->{answers} // {} } };

        # -----------------------------------------------------------------
        # THE $ctx CONTRACT -- every key a phase module's run_phase() may
        # rely on. This is the whole surface; a phase must not reach past
        # it into $state directly.
        #
        #   run_id, phase, state_path, answers -- read-only identity/inputs.
        #   is_done / get_item / checkpoint / scratch -- PHASE-SCOPED: all
        #     four read or write only $state->{phases}{$name} (THIS phase's
        #     own slice, bound above as $pstate). Preflight.pm (package 02)
        #     depends on that scoping and must keep it -- do not change it.
        #   note / decision -- write helpers with no read counterpart.
        #   get_phase_item -- the ONE cross-phase key, and it is READ-ONLY
        #     (no cross-phase write exists, and none should: Decision 10
        #     makes this module the sole owner of the state file, and a
        #     write surface for other phases' slices would let a later
        #     phase corrupt an earlier phase's already-persisted record).
        #     It exists because package 03 (settings-export-merge) needs to
        #     read the `skip_keys` package 02's Preflight phase checkpoints
        #     under its OWN name, and get_item cannot do that -- it is
        #     bound to $pstate, i.e. always the CURRENTLY EXECUTING phase.
        #     Without a cross-phase reader, package 03 would silently get
        #     undef, pass no --skip-key, and discard the operator's
        #     explicit "skip this key" decision: the merge would still push
        #     an only_left key into the repo, or overwrite a diverged one
        #     with the live value, with nothing failing to flag it (see
        #     SKILL.md). Returns undef -- never dies -- for an unknown
        #     phase, an unknown key, or a phase that has not yet
        #     checkpointed that key, and it must NOT autovivify
        #     $state->{phases}{$phase} as a side effect of asking: a phase
        #     that has genuinely never run must still be ABSENT from the
        #     phases hash afterward, or this read would corrupt the very
        #     phase-status bookkeeping read_run_state()/the resume loop
        #     depend on.
        # -----------------------------------------------------------------
        my $ctx = {
            run_id     => $state->{run_id},
            phase      => $name,
            state_path => $state_path,
            answers    => $answers_snapshot,
            is_done    => sub { my ($key) = @_; return exists $pstate->{items}{$key} ? 1 : 0; },
            get_item   => sub {
                my ($key) = @_;
                return undef unless exists $pstate->{items}{$key};
                return $pstate->{items}{$key}{data};
            },
            checkpoint => sub {
                my ($key, $data) = @_;
                $pstate->{items}{$key} = { at => $now_fn->(), data => $data };
                $state->{updated_at} = $now_fn->();
                write_run_state($state_path, $state);   # durability point 3
                return 1;
            },
            scratch => $pstate->{scratch},
            note    => sub {
                my ($key, $value) = @_;
                push @{ $state->{notes} }, { phase => $name, key => $key, value => $value };
                return 1;
            },
            decision => sub {
                my (%fields) = @_;
                $fields{phase} = $name;
                my ($ok, $reason) = validate_decision(\%fields);
                die "Backup::Run: invalid decision constructed by phase '$name': $reason\n" unless $ok;
                return { %fields };
            },
            get_phase_item => sub {
                my ($other_phase, $key) = @_;
                return undef unless defined $other_phase && length $other_phase;
                return undef unless defined $key;
                # Deliberately a PLAIN hash read, not a chained dereference:
                # $state->{phases} already exists (built at run-state
                # construction time), so reading a possibly-absent key off
                # it here does not autovivify anything. Only if that read
                # yields a real hashref do we go one level further.
                my $other_pstate = $state->{phases}{$other_phase};
                return undef unless ref($other_pstate) eq 'HASH';
                my $other_items = $other_pstate->{items};
                return undef unless ref($other_items) eq 'HASH';
                return undef unless exists $other_items->{$key};
                return $other_items->{$key}{data};
            },
        };

        # R5 (coordinator ruling, closes a MAJOR): isolate STDOUT for the
        # phase body. Packages 02-05 spawn native children (git and
        # friends); anything that writes to the real STDOUT here -- the
        # phase itself, or an unredirected child it spawns -- corrupts the
        # one-JSON-object-per-invocation contract (spec S2.6). Real file
        # descriptors ONLY: reopening STDOUT onto an in-memory scalar fails
        # with "Bad file descriptor" on Git-for-Windows perl (CLAUDE.md
        # landmine) -- so this uses a real File::Temp file that is simply
        # discarded.
        my ($phase_stdout_fh, $phase_stdout_name) = File::Temp::tempfile(UNLINK => 1);
        open(my $saved_stdout, '>&', \*STDOUT)
            or die "Backup::Run: cannot save STDOUT before running phase '$name': $!\n";
        open(STDOUT, '>&', $phase_stdout_fh)
            or die "Backup::Run: cannot redirect STDOUT for phase '$name': $!\n";

        my $result = eval { $ph->{run_fn}->($ctx) };
        my $run_died = $@;

        open(STDOUT, '>&', $saved_stdout)
            or warn "Backup::Run: cannot restore STDOUT after phase '$name': $!\n";
        close $saved_stdout;
        close $phase_stdout_fh;

        if (my $died = $run_died) {
            $died =~ s/\s+\z//;
            $pstate->{status}       = 'failed';
            $pstate->{error}        = "$died";
            $pstate->{completed_at} = $now_fn->();
            $state->{updated_at}    = $now_fn->();
            eval { write_run_state($state_path, $state) };
            return (1, _err_result($state->{run_id}, 'phase_died', "phase '$name' died: $died"));
        }

        unless (ref($result) eq 'HASH' && defined $result->{status}) {
            return (1, _err_result($state->{run_id}, 'phase_contract', "phase '$name' returned an invalid result"));
        }

        my $rstatus = $result->{status};
        if ($rstatus eq 'complete' || $rstatus eq 'skipped') {
            $pstate->{status}       = $rstatus;
            $pstate->{completed_at} = $now_fn->();
            $pstate->{error}        = undef;
            $pstate->{reason}       = $result->{reason} if $rstatus eq 'skipped';
            $state->{phase_index}   = $i + 1;
            $state->{updated_at}    = $now_fn->();
            # R4: this write (not just the phase-body eval above) can die on
            # its own -- e.g. a phase that sabotages its own state directory
            # as its last action before returning "complete" (AC30b). Guard
            # it explicitly rather than letting it escape uncaught.
            {
                local $@;
                eval { write_run_state($state_path, $state) };
                if ($@) {
                    my $e = _as_struct_error($@);
                    return (1, _err_result($state->{run_id}, 'internal',
                        "failed to persist phase-completion state for '$name': $e->{message}"));
                }
            }
            next;
        }
        elsif ($rstatus eq 'failed') {
            # A returned 'failed' degrades the run; it does not abort it
            # (contrast with a die, above). This asymmetry is deliberate
            # (spec S2.4, AC22 vs AC23): a die means the phase's own
            # invariants are unknown, a returned failure is controlled.
            $pstate->{status}       = 'failed';
            $pstate->{error}        = $result->{error} // 'phase failed';
            $pstate->{completed_at} = $now_fn->();
            $state->{phase_index}   = $i + 1;
            $state->{updated_at}    = $now_fn->();
            {
                local $@;
                eval { write_run_state($state_path, $state) };
                if ($@) {
                    my $e = _as_struct_error($@);
                    return (1, _err_result($state->{run_id}, 'internal',
                        "failed to persist phase-completion state for '$name': $e->{message}"));
                }
            }
            next;
        }
        elsif ($rstatus eq 'needs_decision') {
            my $decisions = $result->{decisions};
            unless (ref($decisions) eq 'ARRAY' && @$decisions) {
                return (1, _err_result($state->{run_id}, 'phase_contract',
                    "phase '$name' returned needs_decision with no decisions"));
            }
            for my $d (@$decisions) {
                $d->{phase} = $name;   # engine-set, overwrites any phase-supplied value
                my ($ok, $reason) = validate_decision($d);
                unless ($ok) {
                    return (1, _err_result($state->{run_id}, 'decision_invalid',
                        "phase '$name' emitted an invalid decision (kind='" . ($d->{kind} // '') . "'): $reason"));
                }
            }
            $pstate->{status}     = 'paused';
            $state->{token_seq}   = ($state->{token_seq} // 0) + 1;
            $state->{pending}     = { phase => $name, decisions => $decisions };
            $state->{status}      = 'paused';
            $state->{phase_index} = $i;
            $state->{updated_at}  = $now_fn->();
            {
                local $@;
                eval { write_run_state($state_path, $state) };   # durability point 4
                if ($@) {
                    my $e = _as_struct_error($@);
                    return (1, _err_result($state->{run_id}, 'internal',
                        "failed to persist pause state for '$name': $e->{message}"));
                }
            }
            my $token = mint_token($state->{run_id}, $state->{token_seq});
            my $out = {
                status       => 'needs_decision',
                run_id       => $state->{run_id},
                phase        => $name,
                decisions    => $decisions,
                resume_token => $token,
            };
            # R7: name the discarded path in the output too, so an operator
            # (or wrapper) reading THIS invocation's result -- not just the
            # next one -- can see that a --restart/R1 discard just happened
            # and where the old state went.
            $out->{discarded_state_path} = $discarded_state_path if defined $discarded_state_path;
            return (10, $out);
        }
        else {
            return (1, _err_result($state->{run_id}, 'phase_contract',
                "phase '$name' returned an unrecognized status '$rstatus'"));
        }
    }

    # ---- 9. every phase reached a terminal, non-pausing status ----
    # R2 (coordinator ruling, closes a MAJOR): `complete` must be EARNED,
    # never assumed. Declaring completion without checking that every phase
    # actually reached a terminal status let a run with a still-"pending" or
    # still-"running" phase exit 0 -- e.g. from a hand-crafted or
    # tampered-with phase_index. A phase in either state here is an
    # internal inconsistency, not a success; refuse rather than ever report
    # exit 0 over unfinished work.
    my $has_failure = 0;
    for my $n (@discovered_names) {
        my $st = $state->{phases}{$n}{status} // '';
        unless ($st eq 'complete' || $st eq 'skipped' || $st eq 'failed') {
            return (1, _err_result($state->{run_id}, 'internal',
                "phase '$n' has status '$st' but the run loop has already finished; refusing to report completion"));
        }
        $has_failure = 1 if $st eq 'failed';
    }
    $state->{status}      = $has_failure ? 'complete_with_failures' : 'complete';
    $state->{phase_index} = scalar(@discovered);
    $state->{updated_at}  = $now_fn->();
    {
        local $@;
        eval { write_run_state($state_path, $state) };
        if ($@) {
            my $e = _as_struct_error($@);
            return (1, _err_result($state->{run_id}, 'internal',
                "failed to persist final state: $e->{message}"));
        }
    }

    my @phases_out;
    for my $n (@discovered_names) {
        my $ps = $state->{phases}{$n};
        my $entry = { name => $n, status => $ps->{status} };
        $entry->{error} = $ps->{error} if defined $ps->{error};
        push @phases_out, $entry;
    }

    my $out = {
        status => $state->{status},
        run_id => $state->{run_id},
        phases => \@phases_out,
        notes  => $state->{notes} // [],
    };
    $out->{discarded_state_path} = $discarded_state_path if defined $discarded_state_path;
    return ($has_failure ? 20 : 0, $out);
}

1;
