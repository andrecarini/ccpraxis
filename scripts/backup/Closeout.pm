# Closeout.pm -- backup driver phase 05-closeout-and-report (blueprint
# backup-driver).
#
# Absorbs today's SKILL.md Steps 5.7 (registration offer for an unregistered
# cwd), 6 (missing-plugin check), 6.6 (Claude Code binary snapshots) and 7
# (the final report). See the spec for the full contract:
#   .ccpraxis-local-data/blueprints/backup-driver/specs/05-closeout-and-report-spec.md
#
# THIS PHASE MUTATES NOTHING (spec S1.3). All five wrapped interfaces
# (vault-sync.pl is-registered / detect-trackable, check-plugins.pl,
# claude-binary-backup.pl list, and the skip-marker -f probe) are reads.
# Where SKILL.md has the AGENT mutate something as the consequence of an
# answer -- "Don't ask again" creating <cwd>/.claude/backup-skip, "Yes,
# register" invoking /steward:setup-project -- this module records a
# follow-up action in the report and the WRAPPER performs it (ruling C1).
# Closeout.pm never creates the skip marker, never registers a project,
# never installs a plugin, never adds a marketplace.
#
# crash_preserves_items is DELIBERATELY NOT declared (spec S2.2): every
# unit here is read-only, cheap and idempotent, so a mid-execution kill
# simply re-runs everything -- correct and costs four read-only child
# spawns. The accepted consequence is a possible duplicate report note;
# the contract, stated once and tested (t/24 DUPNOTE), is that the LAST
# report note in notes is authoritative.
#
# This module must never depend on package 01's engine module or its
# siblings Preflight.pm/Export.pm/Vault.pm (spec S2.1): everything it needs
# arrives through $ctx, so perl -c is clean standalone and a test can copy
# this single file into a scratch BACKUP_PHASE_DIR. The helpers below
# (_run_capture, _sanitize_utf8, _widen_utf8, _ensure_utf8_bytes, _clamp,
# _clamp_text, _clamp_list, _mint_ids, _title_key, _trim_utf8_tail) are
# duplicated from the siblings DELIBERATELY -- Decision 9 makes the write
# sets disjoint, and a shared helper module is nobody's to create.
#
# The four defect classes this initiative keeps re-discovering, and how this
# module avoids each (spec S2.10 applied here):
#   1. Latin-1 JSON corruption -- this module writes no JSON file at all
#      (Run.pm is the sole writer of the run-state file); everything handed
#      to $ctx goes through _sanitize_utf8 first (raw UTF-8 bytes), because
#      backup.pl's stdout encoder (JSON::PP->new->canonical->encode) has no
#      ->utf8 and cannot carry anything else without corrupting the whole
#      stdout object.
#   2. Absent vs unreadable vs unparseable collapsed into one undef --
#      _interpret_response/_interpret_response_plugins keep "did not
#      spawn", "spawned, non-zero exit" and "spawned, exit 0, unparseable"
#      as three distinct outcomes (AC22); none is ever read as "empty" or
#      "not registered". The same discipline is applied one boundary over,
#      to cross-phase reads (spec S2.7): absent / present-wrong-shape /
#      present-and-usable are three outcomes, never one undef.
#   3. $? >> 8 reporting a signal-killed child as exit 0 -- _run_capture
#      copies the sibling reap form verbatim: (st & 127) ? 128+(st&127) :
#      st>>8. AC21 proves a signal-killed check-plugins.pl is not exit 0.
#   4. die on an environmental condition -- no environmental path here
#      dies; a missing HOME/root, an unspawnable child, a non-zero exit or
#      an unparseable response each degrades a unit to failed and the
#      phase continues to the report. die only ever fires from
#      $ctx->{decision}'s own validation of a decision record this module
#      constructed itself (a programming error, correct to abort per spec
#      S2.4).
#
# UTF-8 discipline (spec S2.8): every value freshly computed in THIS
# invocation (a child's stdout, Cwd::cwd()) is narrowed to raw UTF-8 bytes
# via _sanitize_utf8/_ensure_utf8_bytes before it reaches $ctx. Every value
# read BACK out of $ctx (get_item / get_phase_item / answers) is widened
# first (_widen_utf8) before being re-narrowed for the report or handed to
# a child's argv/a -f probe -- because Run.pm's own state read
# (JSON::PP->new->decode, no ->utf8) returns a resumed value utf8-FLAGGED
# WITHOUT TRANSCODING (the d667 defect class, one process boundary over).
# Skipping the widen step here would double-encode a non-ASCII cwd/slug on
# every resume and silently misbehave (a -f probe that never finds a real
# file; a report field that no longer matches the original bytes).
#
# Invariant worth stating because it narrows the risk (spec S2.8, tested by
# AC19): no value obtained from $ctx is EVER passed to a child process by
# this module. Every child argument is derived from the process environment
# (HOME/USERPROFILE, Cwd::cwd()) in the same invocation.

package Backup::Phase::Closeout;
use strict;
use warnings;
use JSON::PP;
use File::Temp ();
use Encode ();
use Cwd ();
use B ();

# ===========================================================================
# phase_spec / run_phase -- the contract package 01 (Run.pm) requires.
# ===========================================================================

sub phase_spec {
    return {
        name      => 'closeout',
        order     => 400,   # BINDING ruling P2: preflight=100, export=200, vault=300, closeout=400
        resumable => 1,
        title     => 'Closeout: registration offer, plugin check, snapshots, final report',
        # crash_preserves_items DELIBERATELY ABSENT -- see this file's
        # header and spec S2.2. Every unit here is read-only and idempotent;
        # opting in would buy nothing and would overload the flag's meaning
        # ("expensive, externally-verified work").
    };
}

sub run_phase {
    my ($ctx) = @_;

    # ---- B1: environment resolution. Never dies; degrades every direct-
    #      call block instead (defect class 4). ----
    my $home = $ENV{HOME};
    $home = $ENV{USERPROFILE} unless defined $home && length $home;
    my $env_error;
    my $root;
    if (!defined $home || !length $home) {
        $env_error = 'neither HOME nor USERPROFILE is set';
    }
    else {
        (my $home_n = $home) =~ s{\\}{/}g;
        $home_n =~ s{/+\z}{};
        $home_n = _ensure_utf8_bytes($home_n);
        $root = "$home_n/.claude/ccpraxis";
        $env_error = "ccpraxis install not found at $root" unless -d $root;
        $home = $home_n;
    }

    if (defined $env_error) {
        _record_failure($ctx, 'environment', $env_error);
    }
    else {
        _run_u1_registration_probe($ctx, $root);

        my $u2 = _run_u2_registration_outcome($ctx);
        return $u2 if ref($u2) eq 'HASH';

        _run_u3_plugin_check($ctx, $root, $home);

        my $u4 = _run_u4_plugin_outcome($ctx);
        return $u4 if ref($u4) eq 'HASH';

        _run_u5_snapshots($ctx, $root);
    }

    # ---- B7: U6, report -- unconditionally and last, on every path. ----
    _run_u6_report($ctx, $env_error);

    # ---- terminal status (spec S2.4) ----
    my $durable = _load_failures($ctx);
    if (%$durable) {
        my @names = sort keys %$durable;
        my $first = $durable->{$names[0]};
        return { status => 'failed', error => 'closeout: ' . join(', ', @names) . " -- $first" };
    }
    return { status => 'complete' };
}

# ===========================================================================
# unit_failures ledger -- Vault.pm's load_failures/record_failure/
# record_success pattern, as plain $ctx-taking subs (shared across the U1-U6
# helpers below, unlike Vault.pm's single-scope closures).
# ===========================================================================
sub _load_failures {
    my ($ctx) = @_;
    my $h = $ctx->{get_item}->('unit_failures');
    return (ref($h) eq 'HASH') ? { %$h } : {};
}
sub _record_failure {
    my ($ctx, $unit, $msg) = @_;
    return unless defined $msg;
    my $d = _load_failures($ctx);
    $d->{$unit} = $msg;
    $ctx->{checkpoint}->('unit_failures', $d);
}
sub _record_success {
    my ($ctx, $unit) = @_;
    my $d = _load_failures($ctx);
    return unless exists $d->{$unit};
    delete $d->{$unit};
    $ctx->{checkpoint}->('unit_failures', $d);
}

# ===========================================================================
# _gi / _gpi -- read a value back OUT of $ctx (this phase's own item, or
# another phase's item), applying the widen-then-narrow discipline (S2.8) so
# a resumed (utf8-flagged-without-transcode) value and a same-process
# (already-narrow) value land on the same bytes either way. Read-only;
# get_phase_item never autovivifies (Run.pm's own contract).
# ===========================================================================
sub _gi {
    my ($ctx, $key) = @_;
    return _sanitize_utf8(_widen_utf8($ctx->{get_item}->($key)));
}
sub _gpi {
    my ($ctx, $phase, $key) = @_;
    return _sanitize_utf8(_widen_utf8($ctx->{get_phase_item}->($phase, $key)));
}

# ===========================================================================
# U1 -- registration probe (spec B2). Resolves $cwd ONCE via Cwd::cwd() and
# pins it in the checkpoint; every later unit and the report read it back
# via _gi, never re-resolving (B10).
# ===========================================================================
sub _run_u1_registration_probe {
    my ($ctx, $root) = @_;
    return if $ctx->{is_done}->('registration_probe');

    (my $cwd = Cwd::cwd()) =~ s{\\}{/}g;
    $cwd =~ s{(?<=.)/+\z}{};   # MINOR 5 (redteam): strip trailing slashes only when
                               # something precedes them, so a POSIX '/' cwd does not
                               # collapse to '' (an unspecified-directory follow-up target)
    $cwd = _ensure_utf8_bytes($cwd);
    my $marker_path = "$cwd/.claude/backup-skip";

    my $r = _run_capture($^X, "$root/plugins/steward/scripts/vault-sync.pl", 'is-registered', '--cwd', _widen_utf8($cwd));
    my ($ok, $j, $err) = _interpret_response($r, 'vault-sync.pl is-registered');
    unless ($ok) {
        _record_failure($ctx, 'registration', $err);
        my $marker_present = (-f _widen_utf8($marker_path)) ? 1 : 0;
        $ctx->{checkpoint}->('registration_probe', {
            cwd => $cwd, registered => 0, slug => undef,
            skip_marker_present => $marker_present, skip_marker_path => $marker_path,
            trackable => [], offer_eligible => 0, error => $err,
        });
        return;
    }
    $j = _sanitize_utf8($j);
    _record_success($ctx, 'registration');

    my $registered = $j->{registered} ? 1 : 0;
    my $slug       = $j->{slug};

    if ($registered) {
        my $marker_present = (-f _widen_utf8($marker_path)) ? 1 : 0;
        $ctx->{checkpoint}->('registration_probe', {
            cwd => $cwd, registered => 1, slug => $slug,
            skip_marker_present => $marker_present, skip_marker_path => $marker_path,
            trackable => [], offer_eligible => 0, error => undef,
        });
        return;
    }

    my $marker_present = (-f _widen_utf8($marker_path)) ? 1 : 0;
    if ($marker_present) {
        # B11: mentioned, never silently honoured (SKILL.md:451-453 red-team fix).
        $ctx->{note}->('registration_skip_marker', { cwd => $cwd, path => $marker_path });
        $ctx->{checkpoint}->('registration_probe', {
            cwd => $cwd, registered => 0, slug => $slug,
            skip_marker_present => 1, skip_marker_path => $marker_path,
            trackable => [], offer_eligible => 0, error => undef,
        });
        return;
    }

    my $r2 = _run_capture($^X, "$root/plugins/steward/scripts/vault-sync.pl", 'detect-trackable', '--cwd', _widen_utf8($cwd));
    my ($ok2, $j2, $err2) = _interpret_response($r2, 'vault-sync.pl detect-trackable');
    unless ($ok2) {
        _record_failure($ctx, 'registration', $err2);
        $ctx->{checkpoint}->('registration_probe', {
            cwd => $cwd, registered => 0, slug => $slug,
            skip_marker_present => 0, skip_marker_path => $marker_path,
            trackable => [], offer_eligible => 0, error => $err2,
        });
        return;
    }
    $j2 = _sanitize_utf8($j2);
    my $trackable = (ref($j2->{trackable}) eq 'ARRAY') ? $j2->{trackable} : [];
    my $offer_eligible = @$trackable ? 1 : 0;
    $ctx->{checkpoint}->('registration_probe', {
        cwd => $cwd, registered => 0, slug => $slug,
        skip_marker_present => 0, skip_marker_path => $marker_path,
        trackable => $trackable, offer_eligible => $offer_eligible, error => undef,
    });
}

# ===========================================================================
# U2 -- registration outcome (spec B3). Returns undef to continue, or a
# needs_decision hashref to pause the phase.
# ===========================================================================
sub _run_u2_registration_outcome {
    my ($ctx) = @_;
    return undef if $ctx->{is_done}->('registration_outcome');

    my $probe = _gi($ctx, 'registration_probe');
    $probe = {} unless ref($probe) eq 'HASH';
    my $offer_eligible = $probe->{offer_eligible} ? 1 : 0;

    unless ($offer_eligible) {
        my $reason = $probe->{registered}            ? 'already registered'
                   : $probe->{skip_marker_present}    ? 'skip marker present'
                   : defined($probe->{error})         ? 'registration probe failed'
                   :                                     'nothing trackable';
        $ctx->{checkpoint}->('registration_outcome', { offered => 0, choice => undef, reason => $reason });
        return undef;
    }

    my $cwd       = defined($probe->{cwd}) ? $probe->{cwd} : '';
    my $trackable = (ref($probe->{trackable}) eq 'ARRAY') ? $probe->{trackable} : [];
    my @paths     = map { $_->{path} } grep { ref($_) eq 'HASH' } @$trackable;
    (my $basename = $cwd) =~ s{^.*/}{};
    my $n = scalar(@paths);

    my $decision_id = 'closeout.project_registration';
    my $answer = $ctx->{answers}{$decision_id};

    unless (defined $answer) {
        my $title = "register '" . _title_key($basename) . "' for vault backup? ($n trackable path(s))";
        my ($detail) = _clamp_text(join(', ', @paths));
        my @clamped_trackable = _clamp_list($trackable, 200);
        my $decision = $ctx->{decision}->(
            kind    => 'project_registration',
            id      => $decision_id,
            title   => $title,
            subject => $cwd,
            detail  => $detail,
            data    => {
                cwd => $cwd, trackable => \@clamped_trackable,
                skip_marker_path => $probe->{skip_marker_path}, setup_skill => 'steward:setup-project',
            },
            choices => [
                # NIT 2 (redteam): _title_key applied to the interpolated value --
                # unlike title, label is validated only for defined/length
                # (Run.pm:151-152), so an unclamped basename/plugin key would
                # otherwise reach the wrapper's rendering verbatim.
                { id => 'register_now',    label => "Register '" . _title_key($basename) . "' for vault backup now" },
                { id => 'not_now',         label => 'Not now' },
                { id => 'dont_ask_again',  label => "Don't ask again for this project" },
            ],
        );
        return { status => 'needs_decision', decisions => [ $decision ] };
    }

    $ctx->{checkpoint}->('registration_outcome', { offered => 1, choice => $answer });
    return undef;
}

# ===========================================================================
# U3 -- plugin check (spec B4).
# ===========================================================================
sub _run_u3_plugin_check {
    my ($ctx, $root, $home) = @_;
    return if $ctx->{is_done}->('plugin_check');

    my $settings     = "$root/global-config/settings.json";
    my $installed    = "$home/.claude/plugins/installed_plugins.json";
    my $marketplaces = "$home/.claude/plugins/known_marketplaces.json";

    my $r = _run_capture($^X, "$root/plugins/steward/scripts/check-plugins.pl",
        '--settings', _widen_utf8($settings), '--installed', _widen_utf8($installed),
        '--marketplaces', _widen_utf8($marketplaces));
    my ($ok, $j, $err) = _interpret_response_plugins($r, 'check-plugins.pl');
    if ($ok) {
        $j = _sanitize_utf8($j);
        $ctx->{checkpoint}->('plugin_check', $j);
        _record_success($ctx, 'plugins');
    }
    else {
        _record_failure($ctx, 'plugins', $err);
        $ctx->{checkpoint}->('plugin_check', {
            status => undef, error => $err,
            enabled => [], missing => [], missing_marketplaces => [], extra_installed => [],
        });
    }
}

# ===========================================================================
# U4 -- plugin outcome (spec B5). Returns undef to continue, or a
# needs_decision hashref to pause the phase.
# ===========================================================================
sub _run_u4_plugin_outcome {
    my ($ctx) = @_;
    return undef if $ctx->{is_done}->('plugin_outcome');

    my $pc = _gi($ctx, 'plugin_check');
    $pc = {} unless ref($pc) eq 'HASH';
    my $missing = (ref($pc->{missing}) eq 'ARRAY') ? $pc->{missing} : [];

    my @decisions;
    my %answer_for;
    if (@$missing) {
        # Ids are minted over the FULL missing[] list every time (Vault.pm
        # MINOR 9 lesson) -- a pure function of the plugin key list, never
        # of whichever subset is still unanswered, so a pause/resume or a
        # crash re-ask always re-derives the identical id.
        my @plugin_keys = map { (ref($_) eq 'HASH' ? $_->{plugin} : undef) // '' } @$missing;
        my @pairs = _mint_ids('closeout.plugin_install', @plugin_keys);
        for my $i (0 .. $#$missing) {
            my $entry = $missing->[$i];
            next unless ref($entry) eq 'HASH';
            my $id  = $pairs[$i][1];
            my $ans = $ctx->{answers}{$id};
            if (defined $ans) {
                $answer_for{ $entry->{plugin} // '' } = $ans;
            }
            else {
                push @decisions, _plugin_decision($ctx, $entry, $id);
            }
        }
    }

    if (@decisions) {
        return { status => 'needs_decision', decisions => \@decisions };
    }

    # All resolved (or nothing was missing). missing_marketplaces[] is
    # informational only -- SKILL.md only informs there too (a marketplace
    # must be added before its plugin can install); no decision is minted.
    my $missing_mp = (ref($pc->{missing_marketplaces}) eq 'ARRAY') ? $pc->{missing_marketplaces} : [];
    if (@$missing_mp) {
        $ctx->{note}->('plugin_missing_marketplaces', {
            count        => scalar(@$missing_mp),
            marketplaces => [ map { (ref($_) eq 'HASH' ? $_->{marketplace} : undef) } @$missing_mp ],
        });
    }

    $ctx->{checkpoint}->('plugin_outcome', {
        answers => \%answer_for,
        reason  => (@$missing ? undef : 'nothing missing'),
    });
    return undef;
}

sub _plugin_decision {
    my ($ctx, $entry, $id) = @_;
    my $plugin      = $entry->{plugin} // '';
    my $name        = $entry->{name} // '';
    my $marketplace = $entry->{marketplace} // '';
    my $command     = "/plugin install $name\@$marketplace";

    return $ctx->{decision}->(
        kind    => 'plugin_install',
        id      => $id,
        title   => "install missing plugin '" . _title_key($plugin) . "'?",
        subject => $plugin,
        detail  => $command,
        data    => { plugin => $plugin, name => $name, marketplace => $marketplace, command => $command },
        choices => [
            # NIT 2 (redteam): see the identical note at the registration decision above.
            { id => 'install', label => "Install '" . _title_key($plugin) . "'" },
            { id => 'skip',    label => "Skip '" . _title_key($plugin) . "'" },
        ],
    );
}

# ===========================================================================
# U5 -- snapshot list (spec B6).
# ===========================================================================
sub _run_u5_snapshots {
    my ($ctx, $root) = @_;
    return if $ctx->{is_done}->('snapshots');

    my $r = _run_capture($^X, "$root/plugins/steward/scripts/claude-binary-backup.pl", 'list');
    my ($ok, $j, $err) = _interpret_response($r, 'claude-binary-backup.pl list');
    unless ($ok) {
        _record_failure($ctx, 'snapshots', $err);
        $ctx->{checkpoint}->('snapshots', {
            count => undef, newest_id => undef, newest_version => undef,
            newest_captured_at_utc => undef, newest_corrupt => 0, error => $err,
        });
        return;
    }
    $j = _sanitize_utf8($j);
    _record_success($ctx, 'snapshots');

    my $snaps = (ref($j->{snapshots}) eq 'ARRAY') ? $j->{snapshots} : [];
    # MINOR 1 (redteam): derive count from the array itself -- the child's
    # own 'count' field is advisory only and is never trusted in numeric
    # context (a malformed/replaced child could return a non-numeric or
    # hashref 'count' and silently report "no snapshots, no error").
    my $count = scalar(@$snaps);

    if (!@$snaps) {
        $ctx->{checkpoint}->('snapshots', {
            count => 0, newest_id => undef, newest_version => undef,
            newest_captured_at_utc => undef, newest_corrupt => 0, error => undef,
        });
        return;
    }

    my $newest = $snaps->[0];
    $newest = {} unless ref($newest) eq 'HASH';
    my $manifest = (ref($newest->{manifest}) eq 'HASH') ? $newest->{manifest} : undef;
    $ctx->{checkpoint}->('snapshots', {
        count                  => $count + 0,
        newest_id              => $newest->{id},
        newest_version         => (defined $manifest ? $manifest->{version} : undef),
        newest_captured_at_utc => (defined $manifest ? $manifest->{captured_at_utc} : undef),
        newest_corrupt         => ($newest->{corrupt} ? 1 : 0),
        error                  => undef,
    });
}

# ===========================================================================
# U6 -- report (spec B7). Runs unconditionally and last; wraps the whole
# assembly in eval so a bug here degrades to a report with every required
# key present rather than aborting the run with no report at all.
# ===========================================================================
sub _run_u6_report {
    my ($ctx, $env_error) = @_;
    return if $ctx->{is_done}->('report');

    my $report = eval { _assemble_report($ctx, $env_error) };
    if ($@ || ref($report) ne 'HASH') {
        # MINOR 3 (redteam) / ITEM3: $@ may be a REF (Run.pm's own
        # die { code => ..., message => ... } convention) rather than a
        # string. '$err =~ s/\s+\z//' on a ref does not stringify it (it
        # only mutates on a MATCH, and a ref's default stringification never
        # has trailing whitespace) -- so a bare ref would otherwise survive
        # unchanged into FIVE report fields, where S2.5 declares each
        # <string|null>. Reduce to a plain string here, once, before it can
        # reach any of them.
        my $err;
        if (ref($@)) {
            my $e = $@;
            $err = (ref($e) eq 'HASH') ? ($e->{message} // $e->{code}) : undef;
            $err = 'error building report (' . ref($e) . ')' unless defined $err && length $err;
        }
        else {
            $err = $@;
        }
        $err = 'unknown error building report' unless defined $err && length $err;
        $err =~ s/\s+\z//;
        _record_failure($ctx, 'report', $err);
        my $durable = _load_failures($ctx);
        $report = _degraded_report($ctx, $err, $durable);
    }

    # S2.5: exactly one report note, note then checkpoint, in that order and
    # adjacent -- the checkpoint's write is what persists both.
    $ctx->{note}->('report', $report);
    $ctx->{checkpoint}->('report', { emitted => 1, report => $report });
    return;
}

sub _degraded_report {
    my ($ctx, $err, $durable) = @_;
    my %uf = (ref($durable) eq 'HASH') ? %$durable : ();
    $uf{report} = $err;
    return {
        schema_version => 1, run_id => $ctx->{run_id}, phase => 'closeout',
        sources => { preflight => 'absent', export => 'absent', vault => 'absent' },
        ccpraxis_sync => undef, marketplaces => undef,
        preferences => { applied => [], ignored => [], skip_keys => [], skip_keys_unmatched => [], saved => [] },
        vault_projects => { todos => undef, projects => [] },
        current_project_registration => {
            cwd => '', registered => JSON::PP::false, slug => undef,
            skip_marker_present => JSON::PP::false, skip_marker_path => '', offered => JSON::PP::false,
            choice => undef, trackable => [], trackable_paths => [], error => $err,
        },
        plugins => {
            status => undef, enabled => [], missing => [], missing_marketplaces => [], extra_installed => [],
            missing_names => [], answers => {}, error => $err,
        },
        snapshots => {
            count => undef, newest_id => undef, newest_version => undef, newest_captured_at_utc => undef,
            newest_corrupt => JSON::PP::false,
            revert_command => 'perl ${CLAUDE_PLUGIN_ROOT}/scripts/claude-binary-backup.pl restore --latest',
            error => $err,
        },
        follow_up_actions => [], unit_failures => \%uf, degraded => JSON::PP::true,
    };
}

# ===========================================================================
# _assemble_report -- S2.5's schema, sourced per S2.6/S2.7.
# ===========================================================================
sub _assemble_report {
    my ($ctx, $env_error) = @_;
    my @shape_failures;

    # ---- sources (S2.7 rule 1): sentinel-key presence, never autovivified. ----
    # MINOR 4 (redteam): 'settings_outcome' is preflight's LAST checkpoint
    # (U9), where export/vault use their FIRST ('file_status'/'vault_check').
    # Not reachable today (Preflight.pm's only early-return failures happen
    # before any checkpoint at all, so every unit failure is accumulated and
    # returned only after U9), but getting this sentinel wrong would discard
    # every preflight item that is actually readable on disk -- so also
    # accept 'remote_integration' (preflight's FIRST checkpoint) as present.
    my $pf_present = (defined($ctx->{get_phase_item}->('preflight', 'remote_integration'))
                    || defined($ctx->{get_phase_item}->('preflight', 'settings_outcome'))) ? 1 : 0;
    my $ex_present = defined($ctx->{get_phase_item}->('export',    'file_status'))      ? 1 : 0;
    my $va_present = defined($ctx->{get_phase_item}->('vault',     'vault_check'))      ? 1 : 0;

    my %sources = (
        preflight => $pf_present ? 'present' : 'absent',
        export    => $ex_present ? 'present' : 'absent',
        vault     => $va_present ? 'present' : 'absent',
    );

    # ---- preferences / ccpraxis_sync / marketplaces ----
    my (@pref_applied, @pref_ignored, @pref_skip_unmatched, @pref_skip_keys, @pref_saved);
    my $export_settings_merge;
    my $preflight_marketplace_outcome;

    if ($ex_present) {
        $export_settings_merge = _shape_hash(_gpi($ctx, 'export', 'settings_merge'), 'export.settings_merge', \@shape_failures);
        if ($export_settings_merge) {
            @pref_applied        = @{ _shape_array($export_settings_merge->{preferences_applied},  'export.settings_merge.preferences_applied',  \@shape_failures) };
            @pref_ignored        = @{ _shape_array($export_settings_merge->{preferences_ignored},   'export.settings_merge.preferences_ignored',   \@shape_failures) };
            @pref_skip_unmatched = @{ _shape_array($export_settings_merge->{skip_keys_unmatched},    'export.settings_merge.skip_keys_unmatched',    \@shape_failures) };
        }
    }
    if ($pf_present) {
        my $so = _shape_hash(_gpi($ctx, 'preflight', 'settings_outcome'), 'preflight.settings_outcome', \@shape_failures);
        if ($so) {
            @pref_skip_keys = @{ _shape_array($so->{skip_keys}, 'preflight.settings_outcome.skip_keys', \@shape_failures) };
            push @pref_saved, @{ _shape_array($so->{preferences_saved}, 'preflight.settings_outcome.preferences_saved', \@shape_failures) };
        }
        $preflight_marketplace_outcome = _shape_hash(_gpi($ctx, 'preflight', 'marketplace_outcome'), 'preflight.marketplace_outcome', \@shape_failures);
        if ($preflight_marketplace_outcome) {
            push @pref_saved, @{ _shape_array($preflight_marketplace_outcome->{preferences_saved}, 'preflight.marketplace_outcome.preferences_saved', \@shape_failures) };
        }
    }

    my $marketplaces = $pf_present ? $preflight_marketplace_outcome : undef;

    my $ccpraxis_sync;
    if ($pf_present || $ex_present) {
        $ccpraxis_sync = {
            present => JSON::PP::true,
            merged  => {
                status     => ($export_settings_merge ? $export_settings_merge->{status}     : undef),
                merge_rule => ($export_settings_merge ? $export_settings_merge->{merge_rule} : undef),
            },
            files     => $ex_present ? _shape_hash(_gpi($ctx, 'export', 'file_outcome'),      'export.file_outcome',      \@shape_failures) : undef,
            container => $ex_present ? _shape_hash(_gpi($ctx, 'export', 'container_outcome'), 'export.container_outcome', \@shape_failures) : undef,
            sensitive => $ex_present ? _shape_hash(_gpi($ctx, 'export', 'sensitive_scan'),     'export.sensitive_scan',    \@shape_failures) : undef,
            staged    => $ex_present ? _shape_hash(_gpi($ctx, 'export', 'staged'),             'export.staged',            \@shape_failures) : undef,
            committed => $ex_present ? _shape_hash(_gpi($ctx, 'export', 'committed'),          'export.committed',         \@shape_failures) : undef,
            pushed    => $ex_present ? _shape_hash(_gpi($ctx, 'export', 'pushed'),             'export.pushed',            \@shape_failures) : undef,
            remote_integration => $pf_present ? _shape_hash(_gpi($ctx, 'preflight', 'remote_integration'), 'preflight.remote_integration', \@shape_failures) : undef,
            clone_live         => $pf_present ? _shape_hash(_gpi($ctx, 'preflight', 'clone_live'),         'preflight.clone_live',         \@shape_failures) : undef,
        };
    }

    # ---- vault_projects (two-hop read, S2.6) ----
    my $vp_todos;
    my @vp_projects;
    if ($va_present) {
        $vp_todos = _shape_hash(_gpi($ctx, 'vault', 'todos'), 'vault.todos', \@shape_failures);
        my $list = _shape_array(_gpi($ctx, 'vault', 'project_list'), 'vault.project_list', \@shape_failures);
        for my $entry (@$list) {
            next unless ref($entry) eq 'HASH';   # Vault.pm MAJOR 4 lesson: never dereference blindly
            my $tok = $entry->{tok};
            next unless defined $tok && length $tok;
            my $slug = $entry->{slug};
            my $item = _gpi($ctx, 'vault', "project.$tok");
            my ($status, $detail);
            if (ref($item) eq 'HASH') {
                $status = $item->{status};
                $detail = { %$item };
                delete $detail->{slug};
                delete $detail->{status};
            }
            else {
                $detail = {};
            }
            $status = 'not_reached' unless defined $status && length $status;
            push @vp_projects, { slug => $slug, status => $status, class => _class_for_status($status), detail => $detail };
        }
    }

    # ---- current_project_registration (this module's own direct calls) ----
    my $probe = _gi($ctx, 'registration_probe');
    $probe = {} unless ref($probe) eq 'HASH';
    my $outcome = _gi($ctx, 'registration_outcome');
    $outcome = {} unless ref($outcome) eq 'HASH';

    my $reg_cwd = defined($probe->{cwd}) ? $probe->{cwd} : '';
    my $reg_skip_path = defined($probe->{skip_marker_path}) ? $probe->{skip_marker_path}
                       : (length($reg_cwd) ? "$reg_cwd/.claude/backup-skip" : '');
    my $reg_trackable_full = _shape_array($probe->{trackable}, 'current_project_registration.trackable', \@shape_failures);
    # Reviewer MINOR: clamp to 200, matching the decision's own data.trackable
    # (_run_u2_registration_outcome:306) -- otherwise a directory with
    # hundreds of trackable paths produces an unbounded report/state record
    # with no size guard, unlike everything else this module emits.
    my @reg_trackable_clamped = _clamp_list($reg_trackable_full, 200);
    my $reg_trackable = \@reg_trackable_clamped;
    my @reg_trackable_paths = map { $_->{path} } grep { ref($_) eq 'HASH' } @$reg_trackable;
    my $reg_error = $probe->{error};
    $reg_error = $env_error if !defined($reg_error) && defined($env_error);
    my $reg_choice = $outcome->{choice};

    my $current_project_registration = {
        cwd                 => $reg_cwd,
        registered          => ($probe->{registered} ? JSON::PP::true : JSON::PP::false),
        slug                => $probe->{slug},
        skip_marker_present => ($probe->{skip_marker_present} ? JSON::PP::true : JSON::PP::false),
        skip_marker_path    => $reg_skip_path,
        offered             => ($outcome->{offered} ? JSON::PP::true : JSON::PP::false),
        choice              => $reg_choice,
        trackable           => $reg_trackable,
        trackable_paths     => \@reg_trackable_paths,
        error               => $reg_error,
    };

    # ---- plugins (this module's own direct calls) ----
    my $pc = _gi($ctx, 'plugin_check');
    $pc = {} unless ref($pc) eq 'HASH';
    my $po = _gi($ctx, 'plugin_outcome');
    $po = {} unless ref($po) eq 'HASH';
    my $p_answers = _shape_hash($po->{answers}, 'plugins.answers', \@shape_failures) // {};
    my $p_missing = _shape_array($pc->{missing}, 'plugins.missing', \@shape_failures);
    my @p_missing_names = map { $_->{plugin} } grep { ref($_) eq 'HASH' } @$p_missing;
    my $p_missing_mp = _shape_array($pc->{missing_marketplaces}, 'plugins.missing_marketplaces', \@shape_failures);
    my $p_error = $pc->{error};
    $p_error = $env_error if !defined($p_error) && defined($env_error);

    my $plugins = {
        status               => $pc->{status},
        enabled              => _shape_array($pc->{enabled}, 'plugins.enabled', \@shape_failures),
        missing              => $p_missing,
        missing_marketplaces => $p_missing_mp,
        extra_installed      => _shape_array($pc->{extra_installed}, 'plugins.extra_installed', \@shape_failures),
        missing_names        => \@p_missing_names,
        answers              => $p_answers,
        error                => $p_error,
    };

    # ---- snapshots (this module's own direct call) ----
    my $sn = _gi($ctx, 'snapshots');
    $sn = {} unless ref($sn) eq 'HASH';
    my $sn_error = $sn->{error};
    $sn_error = $env_error if !defined($sn_error) && defined($env_error);
    my $snapshots = {
        count                  => $sn->{count},
        newest_id              => $sn->{newest_id},
        newest_version         => $sn->{newest_version},
        newest_captured_at_utc => $sn->{newest_captured_at_utc},
        newest_corrupt         => ($sn->{newest_corrupt} ? JSON::PP::true : JSON::PP::false),
        revert_command         => 'perl ${CLAUDE_PLUGIN_ROOT}/scripts/claude-binary-backup.pl restore --latest',
        error                  => $sn_error,
    };

    # ---- follow_up_actions (spec S2.11) -- what the WRAPPER performs. ----
    my @follow_ups;
    if (defined $reg_choice) {
        if ($reg_choice eq 'register_now') {
            push @follow_ups, { action => 'invoke_setup_project', cwd => $reg_cwd };
        }
        elsif ($reg_choice eq 'dont_ask_again') {
            push @follow_ups, { action => 'create_skip_marker', path => $reg_skip_path };
        }
    }
    for my $entry (@$p_missing) {
        next unless ref($entry) eq 'HASH';
        my $plugin = $entry->{plugin};
        next unless defined $plugin;
        my $choice = $p_answers->{$plugin};
        next unless defined($choice) && $choice eq 'install';
        push @follow_ups, {
            action => 'install_plugin', plugin => $plugin,
            name => $entry->{name}, marketplace => $entry->{marketplace},
            command => '/plugin install ' . ($entry->{name} // '') . '@' . ($entry->{marketplace} // ''),
        };
    }
    for my $entry (@$p_missing_mp) {
        next unless ref($entry) eq 'HASH';
        push @follow_ups, { action => 'add_marketplace', marketplace => $entry->{marketplace}, plugin => $entry->{plugin} };
    }

    # ---- unit_failures / degraded ----
    # MAJOR 4 (reviewer): a shape failure found HERE must reach the DURABLE
    # ledger (_record_failure), not just this report's own local copy --
    # otherwise run_phase's terminal check (which reads only the durable
    # ledger) never sees it, and the run exits 0/complete while its own
    # report names a problem. _record_failure BEFORE the final read below
    # so %uf reflects the write.
    _record_failure($ctx, 'report', join('; ', @shape_failures)) if @shape_failures;
    my $durable = _load_failures($ctx);
    my %uf = %$durable;

    return {
        schema_version => 1,
        run_id         => $ctx->{run_id},
        phase          => 'closeout',
        sources        => \%sources,
        ccpraxis_sync  => $ccpraxis_sync,
        marketplaces   => $marketplaces,
        preferences    => {
            applied => \@pref_applied, ignored => \@pref_ignored,
            skip_keys => \@pref_skip_keys, skip_keys_unmatched => \@pref_skip_unmatched,
            saved => \@pref_saved,
        },
        vault_projects => { todos => $vp_todos, projects => \@vp_projects },
        current_project_registration => $current_project_registration,
        plugins           => $plugins,
        snapshots         => $snapshots,
        follow_up_actions => \@follow_ups,
        unit_failures     => \%uf,
        degraded          => JSON::PP::false,
    };
}

# class mapping (S2.6, closed; fail-closed to 'errored' for anything
# unrecognised while preserving the raw status string).
my %CLASS_BY_STATUS = (
    committed_and_pushed => 'synced',
    aborted               => 'conflicted',
    resolve_failed        => 'conflicted',
    error                 => 'errored',
    drift                 => 'errored',
    session_missing       => 'errored',
    commit_failed         => 'errored',
    push_unconfirmed      => 'errored',
    rolled_back_nothing_stored     => 'errored',
    sensitive_blocked              => 'errored',
    sensitive_blocked_post_rename  => 'errored',
    stale_entry  => 'skipped',
    not_reached  => 'skipped',
);
sub _class_for_status {
    my ($status) = @_;
    return $CLASS_BY_STATUS{ $status // '' } // 'errored';
}

sub _shape_hash {
    my ($v, $label, $failures) = @_;
    return undef unless defined $v;
    return $v if ref($v) eq 'HASH';
    push @$failures, "$label has an unexpected shape";
    return undef;
}
sub _shape_array {
    my ($v, $label, $failures) = @_;
    return [] unless defined $v;
    return $v if ref($v) eq 'ARRAY';
    push @$failures, "$label has an unexpected shape";
    return [];
}

# ===========================================================================
# _interpret_response -- did-not-spawn / spawned-nonzero-exit / spawned-
# exit0-unparseable: three distinct outcomes (S2.10 point 2), none ever read
# as empty/benign. Duplicated from Vault.pm/Export.pm.
# ===========================================================================
sub _stdout_or_stderr_snippet {
    my ($r) = @_;
    # MAJOR 1 (redteam): this is the single choke point every FAILURE-path
    # $err flows through (the success path already sanitises via
    # _sanitize_utf8 at every checkpoint). A child can emit a non-UTF-8 byte
    # on stdout/stderr (a localized Windows $!, a CP1252 path fragment); left
    # unvalidated, that byte propagates into unit_failures/notes/phases[].error
    # and, since backup.pl's stdout encoder has no ->utf8 (S1.8), corrupts the
    # ENTIRE stdout object for any consumer that decodes with ->utf8 -- not
    # just this one field. Sanitise each snippet independently, same helper
    # the success path uses.
    my $out_snip = _ensure_utf8_bytes(_clamp(($r->{out} // ''), 200));
    return $out_snip if length $out_snip;
    my $err_snip = _ensure_utf8_bytes(_clamp(($r->{err} // ''), 200));
    return length($err_snip) ? "(stdout empty) stderr: $err_snip" : $out_snip;
}

sub _interpret_response {
    my ($r, $label) = @_;
    unless ($r->{spawned}) {
        return (0, undef, "$label failed to spawn");
    }
    my $j = eval { decode_json($r->{out}) };
    if ($r->{exit} != 0) {
        if (ref($j) eq 'HASH') {
            my $body_err = $j->{error};
            my $msg = "$label exited $r->{exit}";
            $msg .= ": $body_err" if defined $body_err && length "$body_err";
            return (0, $j, $msg);
        }
        return (0, undef, "$label exited $r->{exit}: " . _stdout_or_stderr_snippet($r));
    }
    unless (ref($j) eq 'HASH') {
        return (0, undef, "$label produced unparseable output: " . _stdout_or_stderr_snippet($r));
    }
    return (1, $j, undef);
}

# check-plugins.pl's own documented exit contract (spec S2.9): exit 1 means
# "missing found", not failure -- exit IN {0,1} is the parse-and-use path.
sub _interpret_response_plugins {
    my ($r, $label) = @_;
    unless ($r->{spawned}) {
        return (0, undef, "$label failed to spawn");
    }
    my $j = eval { decode_json($r->{out}) };
    my $exit = $r->{exit};
    if ($exit != 0 && $exit != 1) {
        if (ref($j) eq 'HASH') {
            my $body_err = $j->{error};
            my $msg = "$label exited $exit";
            $msg .= ": $body_err" if defined $body_err && length "$body_err";
            return (0, $j, $msg);
        }
        return (0, undef, "$label exited $exit: " . _stdout_or_stderr_snippet($r));
    }
    unless (ref($j) eq 'HASH') {
        return (0, undef, "$label produced unparseable output (exit $exit): " . _stdout_or_stderr_snippet($r));
    }
    return (1, $j, undef);
}

# ===========================================================================
# Child-spawning helper -- list form only, never a shell string; real
# File::Temp FILE for stderr (never an in-memory scalar -- Git-for-Windows
# "Bad file descriptor"). Duplicated from Export.pm/Vault.pm VERBATIM (spec
# S2.9): a bare $? >> 8 reports a signal-killed child as exit 0, the worst
# defect this initiative has found (AC21 proves it is not treated as such).
# ===========================================================================
sub _run_capture {
    my (@cmd) = @_;
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*' if $^O =~ /^(MSWin32|cygwin|msys)$/;

    my ($efh, $ename) = File::Temp::tempfile(UNLINK => 1);
    close $efh;
    my $saved_stderr;
    unless (open($saved_stderr, '>&', \*STDERR)) {
        unlink $ename;
        return { out => '', err => '', exit => -1, spawned => 0 };
    }
    unless (open(STDERR, '>', $ename)) {
        close $saved_stderr;
        unlink $ename;
        return { out => '', err => '', exit => -1, spawned => 0 };
    }

    my $out = '';
    my $exit = -1;
    my $spawned = 0;
    my $ok = open(my $fh, '-|', @cmd);
    if ($ok) {
        $spawned = 1;
        local $/;
        $out = <$fh>;
        $out = '' unless defined $out;
        close $fh;
        my $st = $?;
        $exit = ($st & 127) ? (128 + ($st & 127)) : ($st >> 8);
    }

    open(STDERR, '>&', $saved_stderr) or warn "Closeout: cannot restore STDERR: $!\n";
    close $saved_stderr;

    my $err = '';
    if (open my $rfh, '<:raw', $ename) {
        local $/;
        $err = <$rfh> // '';
        close $rfh;
    }
    unlink $ename;

    return { out => $out, err => $err, exit => $exit, spawned => $spawned };
}

# ===========================================================================
# UTF-8 discipline helpers -- duplicated from Export.pm/Vault.pm VERBATIM.
# ===========================================================================

sub _ensure_utf8_bytes {
    my ($s) = @_;
    return $s unless defined $s;
    return Encode::encode('UTF-8', $s) if utf8::is_utf8($s);
    my $probe = $s;
    return $s if eval { Encode::decode('UTF-8', $probe, Encode::FB_CROAK()); 1 };
    return Encode::encode('UTF-8', Encode::decode('ISO-8859-1', $s));
}

sub _sanitize_utf8 {
    my ($v) = @_;
    my $ref = ref($v);
    if ($ref eq 'HASH')  { return { map { _sanitize_utf8($_) => _sanitize_utf8($v->{$_}) } keys %$v }; }
    if ($ref eq 'ARRAY') { return [ map { _sanitize_utf8($_) } @$v ]; }
    if ($ref eq '')      { return _ensure_utf8_bytes($v); }
    return $v;   # JSON::PP::Boolean or any other blessed ref -- pass through
}

sub _widen_utf8 {
    my ($s) = @_;
    return $s unless defined $s;
    my $ref = ref($s);
    # MINOR 2 (redteam): widen KEYS too, matching _sanitize_utf8's own hash
    # branch. _gi/_gpi compose them as _sanitize_utf8(_widen_utf8($v));
    # skipping the widen on keys let a key resumed from the state file
    # (utf8-flagged WITHOUT transcoding -- the d667 defect class) get
    # double-encoded by _sanitize_utf8's re-narrowing.
    if ($ref eq 'HASH')  { return { map { _widen_utf8($_) => _widen_utf8($s->{$_}) } keys %$s }; }
    if ($ref eq 'ARRAY') { return [ map { _widen_utf8($_) } @$s ]; }
    return $s if $ref;
    # MAJOR 2 (redteam): a genuine JSON number must never be retyped as a
    # string here. Encode::decode always returns a PV, discarding the
    # IV/NV -- so every number read back through _gi/_gpi came back a JSON
    # string on every run (S2.5 declares 'count : <int>'; "0" is truthy in
    # JS, so a wrapper branching on a zero count took the wrong branch).
    # _json_number distinguishes a genuine number (IOK/NOK, no POK) from a
    # numeric-LOOKING string (POK) via SV flags -- identical precedent at
    # vault-sync.pl:2309-2331. Numify and return immediately: never touch
    # $s itself below, or the stringification there would retype it anyway.
    return $s + 0 if _json_number($s);
    utf8::downgrade($s, 1);   # FAIL_OK: a genuinely-wide string is a no-op here
    my $probe = $s;
    my $widened = eval { Encode::decode('UTF-8', $probe, Encode::FB_CROAK()) };
    return defined $widened ? $widened : $s;
}

sub _json_number {
    my $f = B::svref_2object(\$_[0])->FLAGS;
    return (($f & (B::SVf_IOK | B::SVf_NOK)) && !($f & B::SVf_POK)) ? 1 : 0;
}

sub _trim_utf8_tail {
    my ($t) = @_;
    $t =~ s/(?:[\xC2-\xDF]|[\xE0-\xEF][\x80-\xBF]{0,1}|[\xF0-\xF4][\x80-\xBF]{0,2})\z//;
    return $t;
}

sub _clamp {
    my ($s, $max) = @_;
    $max //= 4000;
    return $s unless defined $s && length($s) > $max;
    my $t = substr($s, 0, $max);
    return _trim_utf8_tail($t);
}

sub _clamp_text {
    my ($s) = @_;
    $s = '' unless defined $s;
    my $max = 4000;
    return ($s, 0) if length($s) <= $max;
    my $t = substr($s, 0, $max);
    $t = _trim_utf8_tail($t);
    return ($t, 1);
}

sub _clamp_list {
    my ($arr, $max) = @_;
    $max //= 200;
    return @$arr if scalar(@$arr) <= $max;
    return @{$arr}[0 .. $max - 1];
}

# id sanitisation + collision suffixing (matches Preflight.pm/Export.pm/
# Vault.pm's _mint_ids exactly).
sub _mint_ids {
    my ($prefix, @keys) = @_;
    my %used;
    my @out;
    for my $k (@keys) {
        (my $san = $k) =~ s/[^A-Za-z0-9_.:-]/_/g;
        $san = '_' unless length $san;
        my $base_id = length($prefix) ? "$prefix.$san" : $san;
        my $id = $base_id;
        my $n = 1;
        while ($used{$id}++) {
            $n++;
            $id = "$base_id.$n";
        }
        push @out, [ $k, $id ];
    }
    return @out;
}

# Display-only truncation for a title.
sub _title_key {
    my ($k) = @_;
    my $t = $k;
    $t = '' unless defined $t;
    $t =~ s/\s+/ /g;
    $t = _trim_utf8_tail(substr($t, 0, 80)) . "\xE2\x80\xA6" if length($t) > 80;   # raw UTF-8 bytes of an ellipsis
    return $t;
}

1;
