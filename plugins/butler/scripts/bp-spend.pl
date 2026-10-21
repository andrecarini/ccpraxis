#!/usr/bin/env perl
# bp-spend.pl — Claude spend: the account snapshot the dashboard renders, and
# the token/cost derivations over transcripts.
#
# TWO HALVES, deliberately in one file:
#
#   package BpSpend          the ACCOUNT snapshot. `snapshot` asks
#                            bp-usage-gate.pl for the Claude plan utilizations
#                            and persists them as spend.json, which
#                            launcher.pl's _gather_spend reads. A reading that
#                            cannot be taken is `unknown` with a diagnostic —
#                            never a default, never a zero, never a guess.
#   package BpSpend::Derive  the TRANSCRIPT derivations (derive-package,
#                            derive-blueprint, derive-session, report-session):
#                            token counts per type and an API-equivalent cost
#                            from published prices. No credential, no account.
#
# The snapshot once also carried OpenCode Go/Zen figures scraped from an
# authenticated billing page. That reader went when ccpraxis became Claude Code
# only. The field whitelist in write_snapshot outlived it and still decides what
# may reach the persisted file.
#
# mandated_means: bp-log.pl — timestamps go through the real BpLog. Never a
# reimplementation.

package BpSpend;
use strict;
use warnings;
use JSON::PP;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use Fcntl ();

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; abs_path($f) // $f });
require "$DIR/bp-log.pl";   # mandated_means — loaded unconditionally, no HTTP inside it.

# ---------------------------------------------------------------------------
# Cadence floor for the snapshot verb. NAMED constant -- referenced by variable
# at every call site below, never re-typed as a bare literal seconds figure.
# ---------------------------------------------------------------------------
our $CADENCE_TTL_SECONDS = 900;   # 15 minutes: an account meter, not a live gauge.

# ---------------------------------------------------------------------------
# write_snapshot(%opts) -> persists the composed spend snapshot so the TUI
# (launcher.pl's _gather_spend) can render without fetching (b36-reopen §2).
#
#   opts: path       => PATH (final destination, e.g. "<global dir>/spend.json"),
#         results    => \@results (each shaped like claude_from_gate()'s return),
#         now        => epoch (defaults to time).
#
# ⚠ REDACTION IS THE BINDING CONSTRAINT (spec §2.1). This sub NEVER serialises
# a raw result hash -- it builds each snapshot row from an explicit FIELD
# WHITELIST (provider/status/five_hour/seven_day/diagnostic). Anything else on a
# result -- a stray token, a `_debug` sub-hash carrying request headers,
# whatever a careless composer bolted on -- is dropped on the floor, not merely
# "not forwarded" but never even looked at for the write. This is what makes the
# redaction structural rather than a matter of remembering not to pass a
# credential in.
#
# Atomic: write to a temp file in the SAME directory as $path, then rename()
# over the final path -- a reader can never observe a half-written file. That
# half is true on every platform.
#
# THE MODE IS A POSIX-ONLY BEST EFFORT, NOT A GUARANTEE. sysopen asks for 0600
# at creation and is never chmod'd after, which POSIX honours -- but Windows
# does not implement the group/other bits that mode describes, and the file
# measurably lands 0644 on the Git-for-Windows host. almanac 20260823-204738-ee90.
#
# THE ACTUAL GUARANTEE IS THE FIELD WHITELIST, a few lines below. Every persisted
# row is built from an explicit list, so a secret cannot reach this file by being
# added to a struct upstream -- the Claude OAuth token bp-usage-gate.pl handles
# never appears here. That is what is doing the work the mode used to get credit
# for.
#
# This distinction is stated at length ON PURPOSE. The header previously read
# "Mode 0600 from creation", full stop, and a future reader deciding whether some
# new field is safe to persist would weigh that as a second line of defence. On
# this platform there is none. A comment that overstates a security property is
# worse than one that omits it, because it is load-bearing for a decision nobody
# has made yet -- which is precisely the decision this paragraph exists to inform.
#
# Deliberately NOT fixed by enforcing an ACL on Windows: that trades a documented
# limitation for platform-specific permission code in a script whose whole point
# is running everywhere perl does, and it would not change what is safe to put in
# the file. The whitelist is the invariant to protect; see t/171 AC7, which
# asserts the honest property (the global destination is no more permissive than
# the run-dir one) rather than an absolute mode that cannot hold here.
# ---------------------------------------------------------------------------
my @SNAPSHOT_RESULT_FIELDS = qw(provider status five_hour seven_day diagnostic);

# The nested sub-fields a whitelisted window may carry: claude's `utilization`
# (t02, blueprint Decision 12).
#
# STILL A WHITELIST, and that is the point: a credential must provably never
# reach a persisted file. So the field is NAMED, never `%$v` -- a stray key
# smuggled inside a whitelisted nested field is dropped like any other.
# spend-global-and-claude.t's AC13 asserts that directly, at top level and nested.
my @SNAPSHOT_NESTED_FIELDS = qw(utilization);

sub _whitelist_result {
    my ($r) = @_;
    return {} unless ref($r) eq 'HASH';
    my %out;
    for my $f (@SNAPSHOT_RESULT_FIELDS) {
        next unless exists $r->{$f};
        my $v = $r->{$f};
        if (ref($v) eq 'HASH') {
            # five_hour/seven_day are the only nested shapes
            # this file ever produces -- whitelist their sub-fields only, so an
            # unexpected nested key (e.g. a smuggled credential) can never ride
            # along even inside a field that IS on the list.
            my %sub;
            for my $sf (@SNAPSHOT_NESTED_FIELDS) {
                $sub{$sf} = $v->{$sf} if exists $v->{$sf};
            }
            $out{$f} = \%sub;
        } else {
            $out{$f} = $v;
        }
    }
    return \%out;
}

sub write_snapshot {
    my (%opts) = @_;
    my $path    = $opts{path};
    my $results = ref($opts{results}) eq 'ARRAY' ? $opts{results} : [];
    my $now     = defined $opts{now} ? $opts{now} : time;

    die "write_snapshot: path is required\n" unless defined $path && length $path;

    my @clean = map { _whitelist_result($_) } @$results;
    my $snapshot = { generated_at => BpLog::_iso_now($now), results => \@clean };
    my $json = JSON::PP->new->canonical->encode($snapshot);

    (my $dir = $path) =~ s{[/\\][^/\\]+$}{};
    $dir = '.' unless length $dir;
    if (length $dir && !-d $dir) { require File::Path; File::Path::make_path($dir); }

    my $tmp_path = "$path.tmp.$$." . int(rand(1_000_000));
    # 0600 is asked for at creation and KEPT -- it is honoured on POSIX and
    # ignored on Windows (lands 0644 there). Requesting it costs nothing and is
    # right wherever it works; what must not happen is anyone reading this line
    # as a guarantee. See the header: the field whitelist is the invariant.
    sysopen(my $fh, $tmp_path, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_TRUNC(), 0600)
        or die "write_snapshot: sysopen $tmp_path: $!";
    print {$fh} $json or die "write_snapshot: write $tmp_path: $!";
    close $fh or die "write_snapshot: close $tmp_path: $!";

    rename($tmp_path, $path) or die "write_snapshot: rename $tmp_path -> $path: $!";
    return $path;
}

# ---------------------------------------------------------------------------
# claude_from_gate($line, $exit) -> a result hash for the `claude` provider.
#
# PURE. The subprocess is run by the caller; this only interprets its output,
# so the mapping is testable without credentials, without a network, and
# without a fork.
#
# WHY A SUBPROCESS AND NOT A REIMPLEMENTATION (blueprint Decision 12).
# bp-usage-gate.pl already reads ~/.claude/.credentials.json, enforces a
# token-life floor, and polls api.anthropic.com/api/oauth/usage with the right
# oauth beta header. Duplicating that here would fork the handling of the
# broadest secret in the system -- the same constraint write_snapshot's field
# whitelist exists to honour. So we call it and parse its one line.
#
# Its documented single-line contract (see that script's --help):
#   OK          five=<u5> seven=<u7> token_life_h=<h>                exit 0
#   PAUSE       window=... five=<u5> seven=<u7> ...                  exit 10
#   RELOGIN / UNAVAILABLE / CREDS  detail=...                        exit 40/20/30
#
# A PAUSE IS A READING, and a high one. Mapping it to `unknown` would discard
# the figures at exactly the moment they matter most -- the operator is near a
# limit and that is what the panel is for. So exit 10 yields status `ok` with
# both utilizations, and the fact that it is a pause verdict is the governor's
# business, not the panel's.
#
# Anything else -- including a ZERO exit with an unparseable line -- is
# `unknown` with a diagnostic. `unknown` is never `absent` and never zero: a
# provider configured enough to have failed is reported as having failed.
sub claude_from_gate {
    my ($line, $exit) = @_;
    $line = '' unless defined $line && !ref $line;
    $exit = -1 unless defined $exit && $exit =~ /^-?\d+$/;

    # THE FIRST LINE THAT LOOKS LIKE THE CONTRACT, not simply the first line.
    #
    # The caller captures stderr as well as stdout, deliberately -- a gate that
    # fails while saying why is more useful than one that fails silently. But
    # that means a warning printed before the result would become "the first
    # line", and a healthy poll would be reported as `unknown`. So the verb
    # prefix is what selects the line.
    #
    # Still strict about WHERE the figures may come from: only a line that
    # opens with one of the five documented verbs is eligible, so a stray
    # diagnostic that happens to contain `five=` cannot supply a reading.
    my $first = '';
    for my $l (split(/\r?\n/, $line)) {
        next unless $l =~ /^(?:OK|PAUSE|RELOGIN|UNAVAILABLE|CREDS)\b/;
        $first = $l;
        last;
    }

    if ($exit == 0 || $exit == 10) {
        my ($u5) = $first =~ /\bfive=(-?\d+(?:\.\d+)?)\b/;
        my ($u7) = $first =~ /\bseven=(-?\d+(?:\.\d+)?)\b/;
        if (defined $u5 && defined $u7) {
            return { provider   => 'claude', status => 'ok',
                     five_hour  => { utilization => $u5 + 0 },
                     seven_day  => { utilization => $u7 + 0 } };
        }
        return { provider => 'claude', status => 'unknown',
                 diagnostic => _gate_diagnostic($first, $exit,
                     'gate exited 0 without parseable five= and seven= figures') };
    }

    return { provider => 'claude', status => 'unknown',
             diagnostic => _gate_diagnostic($first, $exit, 'gate reported no figures') };
}

# _gate_diagnostic($line, $exit, $fallback) -> a short, SAFE one-line string.
#
# The gate's own `detail=` is preferred because it names the actual cause
# (telemetry-unreachable, no-oauth-block, oauth-token-under-floor-...), which
# is the difference between a panel that says "something went wrong" and one
# that says what to do about it.
#
# SANITISED, and not as a formality. This value is server-influenced (the gate
# forwards an upstream ISO string into its own line, and its redteam already
# stripped control characters there for the same reason), it is written into a
# JSON file, and it is then rendered into a terminal. Control bytes are removed
# so nothing can forge a line break or smuggle an escape sequence into the TUI,
# and the length is capped so a pathological reply cannot push a panel row into
# unbounded wrapping. PRIVATE.
sub _gate_diagnostic {
    my ($line, $exit, $fallback) = @_;
    my $d;
    if (defined $line && $line =~ /\bdetail=(\S+)/) { $d = $1 }
    elsif (defined $line && $line =~ /^([A-Z]+)\b/) { $d = lc($1) }
    $d = $fallback unless defined $d && length $d;
    $d =~ tr/\x00-\x1f\x7f//d;
    $d = substr($d, 0, 120) if length($d) > 120;
    return length($d) ? "$d (gate exit $exit)" : "gate exit $exit";
}

package BpSpend::Derive;
# ===========================================================================
# BpSpend::Derive -- derive-from-transcripts mode (blueprint
# fleet-cost-accounting, package 01-spend-is-recorded). Reads a package's
# EXISTING runs/<pkg>.jsonl coordinator transcript directly -- no external
# provider, no network, no credential -- and produces a token/cost figure
# split coordinator-vs-subagent, plus a named cache-write anomaly report.
# Spec: .ccpraxis-local-data/blueprints/fleet-cost-accounting/specs/
# 01-spend-is-recorded-spec.md. Pure functions; the CLI verbs at the bottom
# of this file are the only I/O-performing callers.
#
# NO CONSUMER YET (fix-batch, reviewer should-fix #1). Nothing reads the
# runs/spend-derived.json this package writes -- not launcher.pl's
# _gather_spend, not SpendPanel.pm, not the reporter/harvest log. Both files
# are outside this package's write set (spec §4's explicit gap flag); wiring
# either of them up is a separate, not-yet-scheduled package.
# ===========================================================================
use strict;
use warnings;
use JSON::PP;
use Fcntl ();
use Time::Local ();

# ---------------------------------------------------------------------------
# _empty_package_result($pkg) -> the zero-valued shape every derive_package()
# call starts from and, for 'no-file'/'empty' status, returns unmodified.
# ---------------------------------------------------------------------------
sub _empty_package_result {
    my ($pkg) = @_;
    return {
        pkg    => $pkg,
        status => 'ok',
        tokens => {
            coordinator => { input => 0, output => 0, cache_creation => 0, cache_read => 0,
                              cache_write_5m_tokens => 0, cache_write_1h_tokens => 0, cache_write_unsplit_tokens => 0 },
            subagent    => { input => 0, output => 0, cache_creation => 0, cache_read => 0,
                              cache_write_5m_tokens => 0, cache_write_1h_tokens => 0, cache_write_unsplit_tokens => 0 },
        },
        by_model      => {},
        record_counts => {
            assistant_total         => 0,
            coordinator             => 0,
            subagent                => 0,
            skipped_unparseable     => 0,
            result_usage_seen       => 0,
            system_usage_seen       => 0,
            malformed_usage_field   => 0,
            # Added for the per-request dedup fix (bug report 20260922-214918-aa8c):
            # requests_total counts logical API responses (one per message.id /
            # requestId), NOT raw assistant records -- assistant_total above stays
            # a record-level diagnostic. request_usage_mismatch counts requests
            # whose repeated records disagreed on input/cache (never observed in
            # the measured fleet transcripts, but surfaced rather than silently
            # picking a value, same spirit as malformed_usage_field).
            requests_total          => 0,
            request_usage_mismatch  => 0,
        },
        anomaly => {
            name         => 'consecutive-same-size-cache-write',
            count        => 0,
            total_tokens => 0,
            pairs        => [],
        },
        cross_check => {
            seen               => 0,
            total_cost_usd     => undef,
            model_usage        => {},
            output_tokens_total => undef,
            cost_source        => 'claude-code-self-reported-headless',
        },
        derived => 1,
        # Package 02 (spend-token-report, Decisions 25/26a/27.1) -- a fresh
        # stamped api_equivalent_cost_usd sibling of cross_check, computed
        # below from the SAME dedup requests via _session_price_request.
        # These three defaults cover the early-return (no-file/empty) paths;
        # the normal path overwrites them once pricing is computed.
        api_equivalent_cost_usd => undef,
        unpriced_tokens         => 0,
        unpriced_reasons        => [],
    };
}

# ---------------------------------------------------------------------------
# _safe_usage_num($val, \%record_counts) -> a non-negative number, NEVER a
# silent corruption of the total (fix-batch M3). A usage sub-field that is
# undef is legitimately absent and becomes 0 with no diagnostic (spec's own
# "missing sub-field" edge case). Anything else that is not a bare
# non-negative integer -- a negative figure, a string, a boolean, a hashref --
# is NOT summed in (a negative value would silently REDUCE the reported total,
# which is the one failure mode this package exists to avoid being fooled by)
# and is instead counted in record_counts.malformed_usage_field so a caller
# has a real signal that some input was suspect, mirroring how a JSON-decode
# failure is counted in skipped_unparseable rather than silently ignored.
# ---------------------------------------------------------------------------
sub _safe_usage_num {
    my ($val, $counts) = @_;
    return 0 unless defined $val;
    if (!ref($val) && $val =~ /^\d+\z/) {
        my $n = $val + 0;
        # A ~300+-digit token count overflows a Perl NV to Inf (fix-batch
        # redteam M1) -- that would otherwise pass through int()/rounding
        # unrounded and land in the JSON output as an invalid `Infinity`
        # token, breaking every consumer that decodes it. Reject non-finite
        # results the same way any other malformed field is rejected.
        return $n if $n == $n && $n != 9**9**9 && $n != -9**9**9;
    }
    $counts->{malformed_usage_field}++;
    return 0;
}

# ---------------------------------------------------------------------------
# derive_package(%opts) -> \%package_result. See spec §2.1-2.4.
#   opts: jsonl_path => PATH (required), pkg => STR (required),
#         pricing => $p (optional -- spec 02 §2.1/§2.2; BpPricing::offline()
#         when absent. NEVER calls BpPricing::acquire itself -- see DF9/B5.)
# A missing file is status=>'no-file'. A file with zero assistant/usage
# records is status=>'empty'. A line that fails JSON decode is SKIPPED, not
# fatal, and counted in record_counts.skipped_unparseable.
# ---------------------------------------------------------------------------
sub derive_package {
    my (%opts) = @_;
    my $jsonl_path = $opts{jsonl_path};
    my $pkg        = $opts{pkg};
    my $pricing        = $opts{pricing} // BpPricing::offline();
    my $pricing_not_ok = $pricing->{status} ne 'ok';

    my $result = _empty_package_result($pkg);
    # T == 0 here (no-file/empty early returns below): the null rule (spec 02
    # §2.2) gives cost 0 under ok pricing, null otherwise -- never a guess.
    $result->{api_equivalent_cost_usd} = $pricing_not_ok ? undef : 0;

    unless (defined $jsonl_path && -f $jsonl_path) {
        $result->{status} = 'no-file';
        return $result;
    }

    open(my $fh, '<:raw', $jsonl_path) or do {
        $result->{status} = 'no-file';
        return $result;
    };
    my @lines = <$fh>;
    close $fh;

    my $saw_assistant = 0;
    my %prev_by_session;   # session_id => { role => { size => N, uuid => STR } }
    my @pairs;

    # ---------------------------------------------------------------------
    # Bug report 20260922-214918-aa8c: a fleet (stream-json) transcript
    # writes ONE API response as SEVERAL `assistant` records, one per
    # content block, and every one of those records repeats that same
    # response's input/cache figures. Summing every record (the old
    # behaviour) therefore multiplied input/cache by the average block
    # count -- measured 1.3-2.5x on real archived runs. Fix: dedup per
    # logical API response, keyed the same way the SESSION path already
    # does (usage-telemetry Decision 6) -- `requestId` when present, else
    # `message.id`, else a synthetic always-unique key so an unkeyed
    # record is never folded into another one's total. Within one key:
    # input/cache_creation/cache_read are taken from the record (last
    # write wins, mirroring _session_read_agent_file), and `output` is the
    # MAX seen across that key's records.
    #
    # output_tokens is NOT thereby made accurate for this shape. Measured
    # fact (usage-telemetry blueprint Constraint H1, reconfirmed against
    # b01/b05 above): stream-json's per-record output_tokens is a
    # stream-START stub -- identical across every block of one response,
    # never growing -- so max-across-records recovers nothing; it only
    # stops the stub being multiplied by the block count the way
    # input/cache were. tokens.{role}.output therefore remains a
    # documented LOWER BOUND for this transcript shape. The only
    # authoritative output figure available is the transcript's own
    # `result` record(s) -- surfaced below as cross_check.output_tokens_total,
    # summed across every `result` record in the file (a package can hold
    # several coordinator launches), never blended into tokens/by_model
    # because it is not split coordinator-vs-subagent.
    # ---------------------------------------------------------------------
    my @order;       # request keys, first-appearance order
    my %requests;    # key => { role, model, input, output, cache_creation, cache_read }
    my $unkeyed_n  = 0;
    my $output_authoritative_total = 0;
    my $output_authoritative_seen  = 0;

    for my $line (@lines) {
        $line =~ s/\r?\n\z//;
        next unless length $line;

        my $rec = eval { JSON::PP->new->decode($line) };
        if ($@ || ref($rec) ne 'HASH') {
            $result->{record_counts}{skipped_unparseable}++;
            next;
        }

        my $type = defined($rec->{type}) ? $rec->{type} : '';

        if ($type eq 'assistant'
            && ref($rec->{message}) eq 'HASH'
            && ref($rec->{message}{usage}) eq 'HASH') {

            $saw_assistant = 1;
            my $role  = defined($rec->{parent_tool_use_id}) ? 'subagent' : 'coordinator';
            my $model = defined($rec->{message}{model}) && length($rec->{message}{model})
                      ? $rec->{message}{model} : 'unknown';
            my $u = $rec->{message}{usage};
            my $input  = _safe_usage_num($u->{input_tokens},                $result->{record_counts});
            my $output = _safe_usage_num($u->{output_tokens},               $result->{record_counts});
            my $cc     = _safe_usage_num($u->{cache_creation_input_tokens}, $result->{record_counts});
            my $cr     = _safe_usage_num($u->{cache_read_input_tokens},     $result->{record_counts});
            # Spec Sec2.7 (Decision 20): read the 5m/1h cache-write split the
            # same way _session_read_agent_file does. use_split means the
            # ephemeral_{5m,1h} hash is present AND its sum is > 0; otherwise
            # the whole cache_creation figure is unsplit.
            my ($cc_5m, $cc_1h) = (0, 0);
            my $has_split_hash = ref($u->{cache_creation}) eq 'HASH';
            if ($has_split_hash) {
                $cc_5m = _safe_usage_num($u->{cache_creation}{ephemeral_5m_input_tokens}, $result->{record_counts});
                $cc_1h = _safe_usage_num($u->{cache_creation}{ephemeral_1h_input_tokens}, $result->{record_counts});
            }
            my $use_split = $has_split_hash && ($cc_5m + $cc_1h > 0);
            my $cc_unsplit = $use_split ? 0 : $cc;
            $cc_5m = 0 unless $use_split;
            $cc_1h = 0 unless $use_split;
            # Package 02 spec Sec2.2: speed, from message.usage.speed, taking
            # the last record like model does (fed into _session_price_request
            # below via the same rate rules the session path uses).
            my $speed = $u->{speed};

            $result->{record_counts}{assistant_total}++;
            $result->{record_counts}{$role}++;

            my $key;
            if (defined($rec->{requestId}) && !ref($rec->{requestId}) && length($rec->{requestId})) {
                $key = "id:$rec->{requestId}";
            }
            elsif (defined($rec->{message}{id}) && !ref($rec->{message}{id}) && length($rec->{message}{id})) {
                $key = "mid:$rec->{message}{id}";
            }
            else {
                $key = "u:" . (++$unkeyed_n);
            }

            my $req = $requests{$key};
            if (!$req) {
                $req = $requests{$key} = {
                    role => $role, model => $model,
                    input => $input, output => $output,
                    cache_creation => $cc, cache_read => $cr,
                    cache_write_5m_tokens => $cc_5m, cache_write_1h_tokens => $cc_1h,
                    cache_write_unsplit_tokens => $cc_unsplit,
                    speed => $speed,
                    session_id => $rec->{session_id},
                    mismatched => 0,
                };
                push @order, $key;
                $result->{record_counts}{requests_total}++;

                # Decision 5 -- consecutive same-size (>0) cache-write
                # anomaly, per (session_id, role), in file order. Run ONCE
                # per logical response (here, at first sight of its key),
                # not once per raw record -- a real response split into N
                # content-block records shares one identical cache_creation
                # figure across all N, and comparing every raw record would
                # report N-1 spurious "duplicate" pairs for a single write.
                # A 0-size write is skipped: it participates as neither
                # half of a pair and never resets the tracked previous
                # value (spec §2.4).
                #
                # SCOPED BY ROLE TOO, not session_id alone (fix-batch M2 --
                # red-team headline finding). Subagent (Task-tool) turns
                # share the coordinator's session_id and interleave with it
                # in file order as NORMAL operation, not an edge case.
                # Tracking "previous" per session_id alone lets an
                # interleaved subagent write both hide a real same-role
                # duplicate (the subagent's differently-sized write
                # overwrites the tracked pointer between two identical
                # coordinator writes, so the real dup is never compared)
                # and false-positive across roles (an unrelated
                # coordinator/subagent pair that coincidentally share a
                # cache-write size gets reported as a duplicate). Keying by
                # (session_id, role) means only writes from the SAME
                # branch of the conversation are ever compared.
                my $session = $rec->{session_id};
                if (defined $session && $cc > 0) {
                    my $uuid = defined($rec->{uuid}) ? $rec->{uuid} : '';
                    my $prev = $prev_by_session{$session}{$role};
                    if (defined $prev && $prev->{size} == $cc) {
                        push @pairs, {
                            session_id  => $session,
                            role        => $role,
                            size        => $cc,
                            first_uuid  => $prev->{uuid},
                            second_uuid => $uuid,
                        };
                    }
                    $prev_by_session{$session}{$role} = { size => $cc, uuid => $uuid };
                }
            }
            else {
                $req->{output} = $output if $output > $req->{output};
                if (!$req->{mismatched}
                    && (   $input != $req->{input}
                        || $cc    != $req->{cache_creation}
                        || $cr    != $req->{cache_read})) {
                    $req->{mismatched} = 1;
                    $result->{record_counts}{request_usage_mismatch}++;
                }
                $req->{input}          = $input;
                $req->{cache_creation} = $cc;
                $req->{cache_read}     = $cr;
                $req->{cache_write_5m_tokens}      = $cc_5m;
                $req->{cache_write_1h_tokens}      = $cc_1h;
                $req->{cache_write_unsplit_tokens} = $cc_unsplit;
                $req->{model}          = $model;
                $req->{speed}          = $speed;
            }
        }
        elsif ($type eq 'system'
            && (ref($rec->{usage}) eq 'HASH'
                || (defined($rec->{subtype}) && $rec->{subtype} eq 'task_progress'))) {
            # A cumulative running counter -- counted, never summed in.
            $result->{record_counts}{system_usage_seen}++;
        }
        elsif ($type eq 'result') {
            # A whole-session summary -- captured verbatim into cross_check
            # for audit only, never blended into tokens/by_model.
            $result->{record_counts}{result_usage_seen}++;
            $result->{cross_check}{seen} = 1;
            $result->{cross_check}{total_cost_usd} = $rec->{total_cost_usd}
                if defined $rec->{total_cost_usd};
            if (ref($rec->{usage}) eq 'HASH' && ref($rec->{usage}{modelUsage}) eq 'HASH') {
                for my $m (keys %{ $rec->{usage}{modelUsage} }) {
                    my $mu = $rec->{usage}{modelUsage}{$m};
                    next unless ref($mu) eq 'HASH';
                    $result->{cross_check}{model_usage}{$m} = {
                        input_tokens                => $mu->{inputTokens}               // 0,
                        output_tokens               => $mu->{outputTokens}              // 0,
                        cache_read_input_tokens     => $mu->{cacheReadInputTokens}      // 0,
                        cache_creation_input_tokens => $mu->{cacheCreationInputTokens}  // 0,
                        cost_usd                    => $mu->{costUSD}                   // 0,
                    };
                    # Package files hold one `result` per coordinator
                    # launch (a killed coordinator never writes one at
                    # all), so the authoritative output total is a SUM
                    # across every result record's modelUsage, across every
                    # model -- never split by role, unlike tokens/by_model.
                    $output_authoritative_total += ($mu->{outputTokens} // 0);
                    $output_authoritative_seen = 1;
                }
            }
        }
        # else: system/init, user, or any other record type -- ignored, no
        # usage to account for (spec §2.2, last bullet).
    }

    # Second pass: fold each logical (deduplicated) request into
    # tokens/by_model exactly once, in first-appearance order.
    for my $key (@order) {
        my $req   = $requests{$key};
        my $role  = $req->{role};
        my $model = $req->{model};

        $result->{tokens}{$role}{input}          += $req->{input};
        $result->{tokens}{$role}{output}         += $req->{output};
        $result->{tokens}{$role}{cache_creation} += $req->{cache_creation};
        $result->{tokens}{$role}{cache_read}     += $req->{cache_read};
        $result->{tokens}{$role}{cache_write_5m_tokens}      += $req->{cache_write_5m_tokens};
        $result->{tokens}{$role}{cache_write_1h_tokens}      += $req->{cache_write_1h_tokens};
        $result->{tokens}{$role}{cache_write_unsplit_tokens} += $req->{cache_write_unsplit_tokens};

        my $bm = ($result->{by_model}{$model} //= {
            role => $role, input => 0, output => 0, cache_creation => 0, cache_read => 0,
            cache_write_5m_tokens => 0, cache_write_1h_tokens => 0, cache_write_unsplit_tokens => 0,
        });
        $bm->{role} = 'mixed' if $bm->{role} ne $role;
        $bm->{input}          += $req->{input};
        $bm->{output}         += $req->{output};
        $bm->{cache_creation} += $req->{cache_creation};
        $bm->{cache_read}     += $req->{cache_read};
        $bm->{cache_write_5m_tokens}      += $req->{cache_write_5m_tokens};
        $bm->{cache_write_1h_tokens}      += $req->{cache_write_1h_tokens};
        $bm->{cache_write_unsplit_tokens} += $req->{cache_write_unsplit_tokens};
    }

    $result->{cross_check}{output_tokens_total} = $output_authoritative_seen
        ? $output_authoritative_total : undef;

    $result->{anomaly}{pairs} = \@pairs;
    $result->{anomaly}{count} = scalar(@pairs);
    my $total = 0;
    $total += $_->{size} for @pairs;
    $result->{anomaly}{total_tokens} = $total;

    # ------------------------------------------------------------------
    # Package 02 (spend-token-report, Decisions 25/26a/27.1/27.2): price
    # every deduplicated request through the SAME _session_price_request
    # used by the session path (Sec2.2), on an adapter hash. T is the
    # package's token total -- the sum, over its deduplicated requests, of
    # input+output+cache_read+cache_write_5m+cache_write_1h+
    # cache_write_unsplit -- which is exactly the sum of the six
    # tokens.{coordinator,subagent} fields just accumulated above, so it
    # is read back from there rather than re-summed a second way.
    # ------------------------------------------------------------------
    my $unrounded_cost = 0;
    my $unpriced_sum   = 0;
    my %unpriced_reasons;
    for my $key (@order) {
        my $req = $requests{$key};
        my $use_split_req = ($req->{cache_write_5m_tokens} + $req->{cache_write_1h_tokens}) > 0;
        my $adapter = {
            model      => $req->{model},
            effort     => undef,
            input      => $req->{input},
            output     => $req->{output},
            cache_read => $req->{cache_read},
            use_split  => $use_split_req,
            cc_5m      => $req->{cache_write_5m_tokens},
            cc_1h      => $req->{cache_write_1h_tokens},
            cc_unsplit => $req->{cache_write_unsplit_tokens},
            speed      => $req->{speed},
        };
        my $cells = _session_price_request($adapter, $req->{role}, $pricing);
        for my $c (@$cells) {
            $unrounded_cost += $c->{cost_usd};
            $unpriced_sum   += $c->{unpriced_tokens};
            $unpriced_reasons{ $c->{reason} } += $c->{tokens} if defined $c->{reason};
        }
    }
    my $T = 0;
    for my $role (qw(coordinator subagent)) {
        for my $f (qw(input output cache_read cache_write_5m_tokens cache_write_1h_tokens cache_write_unsplit_tokens)) {
            $T += $result->{tokens}{$role}{$f};
        }
    }
    my $fully_unpriced = $pricing_not_ok || ($T > 0 && $unpriced_sum == $T);
    # The unrounded cost is PRIVATE -- it never goes into $result (DF11/DF13:
    # no private key may reach the JSON, and that includes a direct library
    # call to derive_package(), not only the packages[] pushed by
    # derive_blueprint below). A caller that needs the unrounded figure --
    # only derive_blueprint does, to sum the blueprint's own top-level cost
    # from UNROUNDED figures rather than re-deriving it from already-rounded
    # package values (spec Sec2.2) -- passes unrounded_cost_ref, a scalar
    # ref this sub fills in as a side channel instead.
    ${ $opts{unrounded_cost_ref} } = $unrounded_cost if ref($opts{unrounded_cost_ref}) eq 'SCALAR';
    $result->{api_equivalent_cost_usd} = $fully_unpriced ? undef : 0 + sprintf('%.6f', $unrounded_cost);
    $result->{unpriced_tokens}  = int($unpriced_sum);
    $result->{unpriced_reasons} = _session_unpriced_reasons_array(\%unpriced_reasons);

    $result->{status} = $saw_assistant ? 'ok' : 'empty';
    return $result;
}

# ---------------------------------------------------------------------------
# derive_blueprint(%opts) -> \%blueprint_result. See spec §2.1.
#   opts: runs_dir => PATH (required), pkgs => \@ARRAY (optional -- if
#         omitted, scans runs_dir for *.jsonl files, basename minus .jsonl is
#         the pkg id, excluding spend.json/spend-derived.json/non-.jsonl and
#         a file literally named spend.jsonl).
# Sums each independently-derived package result additively -- never by
# re-scanning a combined stream.
# ---------------------------------------------------------------------------
sub derive_blueprint {
    my (%opts) = @_;
    my $runs_dir = $opts{runs_dir};
    my $pricing        = $opts{pricing} // BpPricing::offline();
    my $pricing_not_ok = $pricing->{status} ne 'ok';

    my @pkgs;
    if (ref($opts{pkgs}) eq 'ARRAY') {
        @pkgs = @{ $opts{pkgs} };
    }
    elsif (defined $runs_dir && -d $runs_dir) {
        opendir(my $dh, $runs_dir) or @pkgs = ();
        if ($dh) {
            for my $f (sort readdir($dh)) {
                next unless $f =~ /\.jsonl\z/;
                next if $f eq 'spend.jsonl';   # reserved (§4)
                (my $pkg = $f) =~ s/\.jsonl\z//;
                push @pkgs, $pkg;
            }
            closedir $dh;
        }
    }

    my $result = {
        status => 'ok',
        tokens => {
            coordinator => { input => 0, output => 0, cache_creation => 0, cache_read => 0,
                              cache_write_5m_tokens => 0, cache_write_1h_tokens => 0, cache_write_unsplit_tokens => 0 },
            subagent    => { input => 0, output => 0, cache_creation => 0, cache_read => 0,
                              cache_write_5m_tokens => 0, cache_write_1h_tokens => 0, cache_write_unsplit_tokens => 0 },
        },
        by_model => {},
        packages => [],
        anomaly  => {
            name         => 'consecutive-same-size-cache-write',
            count        => 0,
            total_tokens => 0,
            by_package   => {},
        },
        derived => 1,
    };

    my $unrounded_cost_sum = 0;
    my $blueprint_unpriced_tokens = 0;
    my %blueprint_unpriced_reasons;

    for my $pkg (@pkgs) {
        my $jsonl_path = defined($runs_dir) ? "$runs_dir/$pkg.jsonl" : undef;
        my $unrounded_cost;
        my $pr = derive_package(jsonl_path => $jsonl_path, pkg => $pkg, pricing => $pricing,
            unrounded_cost_ref => \$unrounded_cost);

        # $pr never carries a private key (spec 02 Sec2.2/DF11/DF13) --
        # derive_package hands the unrounded figure back through the side
        # channel above instead of stamping it into the result hash.
        $unrounded_cost_sum += $unrounded_cost // 0;
        $blueprint_unpriced_tokens += $pr->{unpriced_tokens};
        for my $r (@{ $pr->{unpriced_reasons} // [] }) {
            $blueprint_unpriced_reasons{ $r->{reason} } += $r->{tokens};
        }

        push @{ $result->{packages} }, $pr;

        for my $role (qw(coordinator subagent)) {
            for my $f (qw(input output cache_creation cache_read
                          cache_write_5m_tokens cache_write_1h_tokens cache_write_unsplit_tokens)) {
                $result->{tokens}{$role}{$f} += $pr->{tokens}{$role}{$f};
            }
        }

        for my $model (keys %{ $pr->{by_model} }) {
            my $src = $pr->{by_model}{$model};
            my $bm = ($result->{by_model}{$model} //= {
                role => $src->{role}, input => 0, output => 0, cache_creation => 0, cache_read => 0,
                cache_write_5m_tokens => 0, cache_write_1h_tokens => 0, cache_write_unsplit_tokens => 0,
            });
            $bm->{role} = 'mixed' if $bm->{role} ne $src->{role};
            for my $f (qw(input output cache_creation cache_read
                          cache_write_5m_tokens cache_write_1h_tokens cache_write_unsplit_tokens)) {
                $bm->{$f} += $src->{$f};
            }
        }

        if ($pr->{anomaly}{count} > 0) {
            $result->{anomaly}{count}        += $pr->{anomaly}{count};
            $result->{anomaly}{total_tokens} += $pr->{anomaly}{total_tokens};
            $result->{anomaly}{by_package}{$pkg} = {
                count        => $pr->{anomaly}{count},
                total_tokens => $pr->{anomaly}{total_tokens},
            };
        }
    }

    # Blueprint-wide T (spec 02 Sec2.2's null rule applied to the blueprint
    # totals) is read back from the SAME tokens.{coordinator,subagent} fields
    # just summed above -- never re-derived a second way.
    my $T = 0;
    for my $role (qw(coordinator subagent)) {
        for my $f (qw(input output cache_read cache_write_5m_tokens cache_write_1h_tokens cache_write_unsplit_tokens)) {
            $T += $result->{tokens}{$role}{$f};
        }
    }
    my $fully_unpriced = $pricing_not_ok || ($T > 0 && $blueprint_unpriced_tokens == $T);

    $result->{price_source}     = $pricing->{source};
    $result->{price_fetched_at} = $pricing->{fetched_at};
    $result->{pricing_status}   = BpPricing::status_string($pricing);
    $result->{price_fetch_override} = JSON::PP::true if $pricing->{price_fetch_override};
    $result->{api_equivalent_cost_usd} = $fully_unpriced ? undef : 0 + sprintf('%.6f', $unrounded_cost_sum);
    $result->{unpriced_tokens}  = int($blueprint_unpriced_tokens);
    $result->{unpriced_reasons} = _session_unpriced_reasons_array(\%blueprint_unpriced_reasons);

    return $result;
}

# ===========================================================================
# derive_session(%opts) -- blueprint usage-telemetry, package
# 01-drive-solo-input-and-pricing. Reads a DRIVE-SOLO session's own
# transcripts directly: a `<uuid>.jsonl` main transcript plus a sibling
# `<uuid>/subagents/agent-<id>.jsonl` per subagent and its `.meta.json`
# sidecar. This shape has no `result` record (no self-reported cost) and no
# `parent_tool_use_id` (role must come from the sidecar, not the record), and
# one API request is spread over several `assistant` records that repeat
# their input/cache figures while `output_tokens` grows -- hence the
# per-request dedup below. Spec: .ccpraxis-local-data/blueprints/
# usage-telemetry/specs/01-drive-solo-input-and-pricing-spec.md. Pure,
# read-only: opens files '<:raw', writes nothing, creates nothing (Decision
# 7). Deliberately does NOT reuse derive_package's (session_id, role)
# anomaly key -- see the per-agent-file rationale at _agent_anomaly() below.
# ===========================================================================

# ---------------------------------------------------------------------------
# Pricing (spec Sec2.4, blueprint spend-token-report). Prices are acquired
# fresh per report run through BpPricing::acquire() -- never pinned in code.
# See BpPricing.pm. Loading it has no side effects (no network/spawn/I-O).
# ---------------------------------------------------------------------------
require "$DIR/BpPricing.pm";

# ---------------------------------------------------------------------------
# _norm_scalar_or_unknown($v) -> $v when it is a defined, non-ref, non-empty
# scalar; else the literal string 'unknown' (B5). Never a default such as
# 'medium'.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# _session_truncate_for_error($s) -> $s, or its first 200 chars + '...' when
# longer (fix-batch redteam L10) -- keeps a pathologically long --session
# value from being echoed verbatim (and unbounded) into a diagnostic.
# ---------------------------------------------------------------------------
sub _session_truncate_for_error {
    my ($s) = @_;
    return '' unless defined $s;
    return $s if !ref($s) && length($s) <= 200;
    return ref($s) ? "$s" : substr($s, 0, 200) . '...';
}

sub _norm_scalar_or_unknown {
    my ($v) = @_;
    return (defined($v) && !ref($v) && length($v)) ? $v : 'unknown';
}

# ---------------------------------------------------------------------------
# _session_parse_ts($str) -> epoch seconds, or undef when $str is not one of
# the accepted forms (B12): YYYY-MM-DDTHH:MM:SS, an optional fractional part
# (truncated), and either Z or +-HH:MM.
# ---------------------------------------------------------------------------
sub _session_parse_ts {
    my ($str) = @_;
    return undef unless defined($str) && !ref($str);
    return undef unless $str =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:\d{2})$/;
    my ($y, $mo, $d, $h, $mi, $s, $off) = ($1, $2, $3, $4, $5, $6, $7);
    my $epoch = eval { Time::Local::timegm($s, $mi, $h, $d, $mo - 1, $y) };
    return undef unless defined $epoch;
    if ($off ne 'Z') {
        my ($sign, $oh, $om) = $off =~ /^([+-])(\d{2}):(\d{2})$/;
        my $off_secs = ($oh * 3600 + $om * 60);
        $off_secs = -$off_secs if $sign eq '-';
        $epoch -= $off_secs;
    }
    return $epoch;
}

# ---------------------------------------------------------------------------
# _session_iso_epoch($epoch) -> 'YYYY-MM-DDTHH:MM:SSZ' (UTC). Package 02's own
# formatter for window bounds/headers -- deliberately not BpPricing::_iso
# (private to that package), same shape.
# ---------------------------------------------------------------------------
sub _session_iso_epoch {
    my ($e) = @_;
    my @g = gmtime($e);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1], $g[0]);
}

# ---------------------------------------------------------------------------
# _session_hour_label($epoch) -> 'YYYY-MM-DDTHH:00Z' (UTC), the --by hour
# bucket label (spec 02 Sec2.5). Carries the date so multi-day windows never
# merge two different days' same hour (N3).
# ---------------------------------------------------------------------------
sub _session_hour_label {
    my ($e) = @_;
    my @g = gmtime($e);
    return sprintf('%04d-%02d-%02dT%02d:00Z', $g[5] + 1900, $g[4] + 1, $g[3], $g[2]);
}

# ---------------------------------------------------------------------------
# _window_is_leap($y) -> 1|0.
# ---------------------------------------------------------------------------
sub _window_is_leap {
    my ($y) = @_;
    return ($y % 4 == 0 && ($y % 100 != 0 || $y % 400 == 0)) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# _window_parse_bound($raw, $now) -> epoch seconds, or undef when $raw is
# neither form (spec 02 Sec2.7's time grammar):
#   absolute: YYYY-MM-DDTHH:MM[:SS]Z, uppercase T/Z only, no fractional
#             seconds, no numeric offset, every field range-checked;
#   relative: Nh|Nm|Nd (N is 1-6 digits, no sign, no decimal), resolved as
#             $now - N*unit. Deliberately a STRICTER grammar than
#             _session_parse_ts (which accepts offsets/fractions for
#             TRANSCRIPT timestamps) -- this one judges CLI --since/--until
#             values instead.
# ---------------------------------------------------------------------------
sub _window_parse_bound {
    my ($raw, $now) = @_;
    my $v = defined($raw) ? $raw : '';

    if ($v =~ /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?Z\z/) {
        my ($y, $mo, $d, $h, $mi, $s) = ($1 + 0, $2 + 0, $3 + 0, $4 + 0, $5 + 0, defined($6) ? $6 + 0 : 0);
        # A year below 1000 is rejected outright, rather than handed to
        # Time::Local::timegm -- which reinterprets any year under 1000 via
        # its 2/3-digit-year convention (e.g. 0150 -> 2050, 0000 -> 2000),
        # silently resolving to a wildly different absolute time (S3).
        return undef if $y < 1000;
        return undef if $mo < 1 || $mo > 12;
        return undef if $h > 23 || $mi > 59 || $s > 59;
        my @dim = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
        $dim[1] = 29 if _window_is_leap($y);
        return undef if $d < 1 || $d > $dim[$mo - 1];
        my $epoch = eval { Time::Local::timegm($s, $mi, $h, $d, $mo - 1, $y) };
        return (!$@ && defined $epoch) ? $epoch : undef;
    }
    if ($v =~ /\A(\d{1,6})([hmd])\z/) {
        my ($n, $unit) = ($1 + 0, $2);
        my %secs = (h => 3600, m => 60, d => 86400);
        return $now - $n * $secs{$unit};
    }
    return undef;
}

# ---------------------------------------------------------------------------
# _session_read_sidecar($path) -> \%hashref, or undef when the file is
# absent, unreadable, not valid JSON, or not a JSON object. Never fatal.
# ---------------------------------------------------------------------------
sub _session_read_sidecar {
    my ($path) = @_;
    return undef unless -f $path;
    open(my $fh, '<:raw', $path) or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $data = eval { JSON::PP->new->utf8->decode($raw) };
    return undef if $@ || ref($data) ne 'HASH';
    return $data;
}

# ---------------------------------------------------------------------------
# _session_slashify($path) -> $path with every backslash replaced by a
# forward slash, so emitted path strings are byte-identical on Windows and
# POSIX (spec §2.3).
# ---------------------------------------------------------------------------
sub _session_slashify {
    my ($path) = @_;
    (my $out = $path) =~ s{\\}{/}g;
    return $out;
}

# ---------------------------------------------------------------------------
# FAST LINE READER. A session is ~130 MB of JSONL for a day of drive-solo
# work, and JSON::PP -- the only JSON decoder core Perl ships -- decodes it at
# about 1 MB/s: `derive-session` measured 154s on one real session. Almost
# all of those bytes are tool output, file contents and thinking text that
# nothing here reads.
#
# So a line is not decoded whole. A strict JSON grammar, written as a
# recursive regex (it runs in the regex engine, in C), validates the line and
# splits objects into members; only the handful of fields
# _session_read_agent_file reads are decoded, into a THIN record with exactly
# the shape JSON::PP would have given them. Same session: 12s.
#
# The result must equal a JSON::PP decode exactly. Any line the grammar
# cannot vouch for returns undef and takes the full JSON::PP decode instead,
# so malformed lines are still judged by JSON::PP alone
# (record_counts.skipped_unparseable is unchanged). The grammar follows
# RFC 8259 exactly as JSON::PP enforces it (no raw control characters in
# strings, no unknown escapes, no leading zeros); the three things JSON::PP
# also rejects that a regex does not see -- invalid UTF-8, unpaired
# surrogate escapes, nesting deeper than 512 -- send the line to JSON::PP.
# Scalars take JSON::PP too unless they are plain printable ASCII strings or
# integers of at most 15 digits, because _safe_usage_num judges the DECODED
# value and JSON::PP decodes a long integer to its exact digit string, where
# `0 + $raw` would give a rounded float (25 digits: the string passes
# _safe_usage_num's /^\d+\z/, the float's "1.23e+24" does not).
# Measured before landing: all 32,290 lines of a real session gave
# field-for-field the same record through both paths;
# spend-session-fast-reader.t pins the edge cases.
# ---------------------------------------------------------------------------
our $SESSION_JSON_GRAMMAR = qr{
    (?(DEFINE)
        (?<str> " [^"\\\x00-\x1f]*+ (?: \\ (?: ["\\/bfnrt] | u[0-9a-fA-F]{4} ) [^"\\\x00-\x1f]*+ )*+ " )
        (?<num> -?+ (?: 0 | [1-9][0-9]*+ ) (?: \.[0-9]++ )?+ (?: [eE][-+]?+[0-9]++ )?+ )
        (?<ws>  [\x20\x09\x0a\x0d]*+ )
        (?<val> (?&str) | (?&num) | (?&obj) | (?&arr) | true | false | null )
        (?<obj> \{ (?&ws) (?: (?&str) (?&ws) : (?&ws) (?&val) (?&ws)
                              (?: , (?&ws) (?&str) (?&ws) : (?&ws) (?&val) (?&ws) )*+ )?+ \} )
        (?<arr> \[ (?&ws) (?: (?&val) (?&ws) (?: , (?&ws) (?&val) (?&ws) )*+ )?+ \] )
    )
}x;
my $SESSION_MEMBER_RE = qr{ \G (?&ws) ( (?&str) ) (?&ws) : (?&ws) ( (?&val) ) (?&ws) ( [,\}] ) $SESSION_JSON_GRAMMAR }x;
my $SESSION_ELEM_RE   = qr{ \G (?&ws) (?&val) (?&ws) ( [,\]] ) $SESSION_JSON_GRAMMAR }x;
my $SESSION_JSON_ONE  = JSON::PP->new->utf8->allow_nonref;
my $SESSION_JSON_LINE = JSON::PP->new->utf8;

# _session_json_members($text) -> [ [key, raw-value-text], ... ] in document
# order for a text that is exactly one JSON object, else undef.
sub _session_json_members {
    my ($t) = @_;
    pos($t) = 0;
    $t =~ /\G[\x20\x09\x0a\x0d]*\{[\x20\x09\x0a\x0d]*/gc or return undef;
    my @members;
    unless ($t =~ /\G\}/gc) {
        while (1) {
            $t =~ /$SESSION_MEMBER_RE/gc or return undef;
            my ($k, $v, $sep) = ($1, $2, $3);
            push @members, [ _session_json_scalar($k), $v ];
            last if $sep eq '}';
        }
    }
    return ($t =~ /\G[\x20\x09\x0a\x0d]*\z/gc) ? \@members : undef;
}

# _session_json_array_len($text) -> element count of a text that is exactly
# one JSON array, else undef.
sub _session_json_array_len {
    my ($t) = @_;
    pos($t) = 0;
    $t =~ /\G[\x20\x09\x0a\x0d]*\[[\x20\x09\x0a\x0d]*/gc or return undef;
    my $n = 0;
    unless ($t =~ /\G\]/gc) {
        while (1) {
            $t =~ /$SESSION_ELEM_RE/gc or return undef;
            $n++;
            last if $1 eq ']';
        }
    }
    return ($t =~ /\G[\x20\x09\x0a\x0d]*\z/gc) ? $n : undef;
}

# _session_json_scalar($raw) -> exactly what JSON::PP (utf8, allow_nonref)
# returns for one grammar-valid JSON value.
sub _session_json_scalar {
    my ($raw) = @_;
    return substr($raw, 1, -1) if $raw =~ /\A"[\x20\x21\x23-\x5b\x5d-\x7e]*"\z/;
    return 0 + $raw            if $raw =~ /\A(?:0|[1-9][0-9]{0,14})\z/;
    return $SESSION_JSON_ONE->decode($raw);
}

# _session_json_pick($raw, \%scalars, \%nested) -> for a raw OBJECT value, a
# hashref holding only the keys named in %scalars (decoded as scalars) and
# %nested (key => coderef applied to the raw sub-value); any other raw value
# decodes as-is. Duplicate keys: last wins, as in JSON::PP.
sub _session_json_pick {
    my ($raw, $scalars, $nested) = @_;
    return _session_json_scalar($raw) unless $raw =~ /\A\{/;
    my $members = _session_json_members($raw) or return _session_json_scalar($raw);
    my %h;
    for my $m (@$members) {
        my ($k, $v) = @$m;
        if    ($scalars->{$k})         { $h{$k} = _session_json_scalar($v) }
        elsif ($nested && $nested->{$k}) { $h{$k} = $nested->{$k}->($v) }
    }
    return \%h;
}

my %SESSION_THIN_TOP   = map { $_ => 1 } qw(type timestamp requestId effort uuid session_id);
my %SESSION_THIN_MSG   = map { $_ => 1 } qw(model id);
my %SESSION_THIN_USAGE = map { $_ => 1 } qw(input_tokens output_tokens cache_read_input_tokens
                                            cache_creation_input_tokens speed);
my %SESSION_THIN_CC    = map { $_ => 1 } qw(ephemeral_5m_input_tokens ephemeral_1h_input_tokens);

my %SESSION_THIN_USAGE_NESTED = (
    cache_creation => sub { _session_json_pick($_[0], \%SESSION_THIN_CC) },
    # Only the element count is ever read (multi_iteration), so the array is
    # counted, not decoded: a list of that many placeholders.
    iterations     => sub {
        my $n = ($_[0] =~ /\A\[/) ? _session_json_array_len($_[0]) : undef;
        return defined($n) ? [ (undef) x $n ] : _session_json_scalar($_[0]);
    },
);
my %SESSION_THIN_MSG_NESTED = (
    usage => sub { _session_json_pick($_[0], \%SESSION_THIN_USAGE, \%SESSION_THIN_USAGE_NESTED) },
);

# _session_thin_record($line) -> thin record (see the block comment above),
# or undef when the line must take the full JSON::PP decode.
sub _session_thin_record {
    my ($line) = @_;
    return undef if $line =~ /[\x80-\xff]/ && !do { my $c = $line; utf8::decode($c) };
    return undef if $line =~ /\\u[dD][89abAB]/;
    # Only a line holding 512+ brackets can nest past JSON::PP's limit, so
    # only such a line pays for counting the brackets outside strings.
    if (($line =~ tr/{[//) > 512) {
        (my $s = $line) =~ s/"[^"\\]*+(?:\\.[^"\\]*+)*+"//g;
        return undef if ($s =~ tr/{[//) > 512;
    }
    my $top = _session_json_members($line) or return undef;
    my %rec;
    for my $m (@$top) {
        my ($k, $v) = @$m;
        if ($SESSION_THIN_TOP{$k}) {
            $rec{$k} = _session_json_scalar($v);
        }
        elsif ($k eq 'message') {
            $rec{message} = _session_json_pick($v, \%SESSION_THIN_MSG, \%SESSION_THIN_MSG_NESTED);
        }
    }
    return \%rec;
}

# ---------------------------------------------------------------------------
# _session_read_agent_file($path, \%record_counts) -> ( \@order, \%requests,
# $first_ts ). Reads one agent transcript, deduplicates its assistant records
# into per-request entries keyed per B1, and returns them in
# first-appearance file order (@order holds the keys). Every usage figure is
# read through the shared _safe_usage_num($val, \%record_counts) so
# malformed fields tally centrally (spec §2.1).
# ---------------------------------------------------------------------------
sub _session_read_agent_file {
    my ($path, $counts) = @_;

    my @order;
    my %requests;
    my $first_ts;
    my $unkeyed_n = 0;

    open(my $fh, '<:raw', $path) or return (\@order, \%requests, undef);

    while (defined(my $line = <$fh>)) {
        $line =~ s/\r?\n\z//;
        next unless length $line;

        my $rec = _session_thin_record($line)
            // eval { $SESSION_JSON_LINE->decode($line) };
        if (ref($rec) ne 'HASH') {
            $counts->{skipped_unparseable}++;
            next;
        }

        my $rec_ts;
        if (defined $rec->{timestamp} && !ref($rec->{timestamp})) {
            $rec_ts = _session_parse_ts($rec->{timestamp});
            if (defined $rec_ts && (!defined($first_ts) || $rec_ts < $first_ts)) {
                $first_ts = $rec_ts;
            }
        }

        next unless defined($rec->{type}) && $rec->{type} eq 'assistant'
            && ref($rec->{message}) eq 'HASH'
            && ref($rec->{message}{usage}) eq 'HASH';

        $counts->{assistant_records}++;
        my $usage = $rec->{message}{usage};

        if (ref($usage->{iterations}) eq 'ARRAY' && scalar(@{ $usage->{iterations} }) > 1) {
            $counts->{multi_iteration}++;
        }
        $counts->{speed_absent}++ unless defined $usage->{speed};

        my $key;
        if (defined($rec->{requestId}) && !ref($rec->{requestId}) && length($rec->{requestId})) {
            $key = "id:$rec->{requestId}";
        }
        elsif (defined($rec->{message}{id}) && !ref($rec->{message}{id}) && length($rec->{message}{id})) {
            $key = "mid:$rec->{message}{id}";
        }
        else {
            $key = "u:" . (++$unkeyed_n);
            $counts->{unkeyed}++;
        }

        my $input      = _safe_usage_num($usage->{input_tokens}, $counts);
        my $output     = _safe_usage_num($usage->{output_tokens}, $counts);
        my $cache_read = _safe_usage_num($usage->{cache_read_input_tokens}, $counts);
        my $cc_unsplit = _safe_usage_num($usage->{cache_creation_input_tokens}, $counts);
        my ($cc_5m, $cc_1h) = (0, 0);
        my $has_split_hash = ref($usage->{cache_creation}) eq 'HASH';
        if ($has_split_hash) {
            $cc_5m = _safe_usage_num($usage->{cache_creation}{ephemeral_5m_input_tokens}, $counts);
            $cc_1h = _safe_usage_num($usage->{cache_creation}{ephemeral_1h_input_tokens}, $counts);
        }
        my $use_split = $has_split_hash && ($cc_5m + $cc_1h > 0);

        my $uuid       = (defined($rec->{uuid}) && !ref($rec->{uuid})) ? $rec->{uuid} : '';
        my $session_id = (defined($rec->{session_id}) && !ref($rec->{session_id})) ? $rec->{session_id} : '';

        my $req = $requests{$key};
        if (!$req) {
            $req = $requests{$key} = {
                output          => $output,
                input           => $input,
                cache_read      => $cache_read,
                cc_unsplit      => $cc_unsplit,
                cc_5m           => $cc_5m,
                cc_1h           => $cc_1h,
                use_split       => $use_split,
                model           => $rec->{message}{model},
                effort          => $rec->{effort},
                speed           => $usage->{speed},
                first_uuid      => $uuid,
                first_session_id => $session_id,
                mismatched      => 0,
                # Package 02 spec Sec2.4 -- the placement timestamp is that
                # of the FIRST record, in file order, that dedup assigns to
                # this request. Never overwritten by a later record, even
                # when this first one had no/an unparseable timestamp (the
                # request is then timestamp-less, spec's own term).
                place_ts        => $rec_ts,
            };
            push @order, $key;
        }
        else {
            $req->{output} = $output if $output > $req->{output};
            if (!$req->{mismatched}
                && (   $input      != $req->{input}
                    || $cache_read != $req->{cache_read}
                    || $cc_unsplit != $req->{cc_unsplit}
                    || $cc_5m      != $req->{cc_5m}
                    || $cc_1h      != $req->{cc_1h})) {
                $req->{mismatched} = 1;
                $counts->{request_usage_mismatch}++;
            }
            $req->{input}      = $input;
            $req->{cache_read} = $cache_read;
            $req->{cc_unsplit} = $cc_unsplit;
            $req->{cc_5m}      = $cc_5m;
            $req->{cc_1h}      = $cc_1h;
            $req->{use_split}  = $use_split;
            $req->{model}      = $rec->{message}{model};
            $req->{effort}     = $rec->{effort};
            $req->{speed}      = $usage->{speed};
        }
    }
    close $fh;

    $counts->{requests} += scalar(@order);
    return (\@order, \%requests, $first_ts);
}

# ---------------------------------------------------------------------------
# _session_price_request($req, $role) -> ( \@cells, \%unpriced_deltas ).
# Prices one deduplicated request's non-zero token-type amounts per the
# precedence of spec Sec2.7 -- exactly one reason applies to any unpriced
# amount:
#   1. a whole-request reason (from BpPricing::rates_for_request)
#   2. else token type is cache_write_unsplit -> cache-write-unsplit
#   3. else the tier's rate for this type is undef -> rate-missing
#   4. else priced: cost = tokens / 1_000_000 * rate
# ---------------------------------------------------------------------------
sub _session_price_request {
    my ($req, $role, $p) = @_;

    my $model  = _norm_scalar_or_unknown($req->{model});
    my $effort = _norm_scalar_or_unknown($req->{effort});

    my %amounts;
    $amounts{input}               = $req->{input};
    $amounts{output}              = $req->{output};
    $amounts{cache_read}          = $req->{cache_read};
    if ($req->{use_split}) {
        $amounts{cache_write_5m}       = $req->{cc_5m};
        $amounts{cache_write_1h}       = $req->{cc_1h};
        $amounts{cache_write_unsplit}  = 0;
    }
    else {
        $amounts{cache_write_5m}       = 0;
        $amounts{cache_write_1h}       = 0;
        $amounts{cache_write_unsplit}  = $req->{cc_unsplit};
    }

    my $input_total = $req->{input} + $req->{cache_read}
        + ($req->{use_split} ? ($req->{cc_5m} + $req->{cc_1h}) : $req->{cc_unsplit});

    my $outcome = BpPricing::rates_for_request(
        $p, model => $req->{model}, speed => $req->{speed}, input_total => $input_total,
    );

    my @cells;
    for my $type (qw(input output cache_write_5m cache_write_1h cache_read cache_write_unsplit)) {
        my $tokens = $amounts{$type};
        next unless $tokens > 0;

        my $reason;
        my $cost = 0;
        if (defined $outcome->{reason}) {
            $reason = $outcome->{reason};
        }
        elsif ($type eq 'cache_write_unsplit') {
            $reason = 'cache-write-unsplit';
        }
        elsif (!defined $outcome->{rates}{$type}) {
            $reason = 'rate-missing';
        }
        else {
            $cost = $tokens / 1_000_000 * $outcome->{rates}{$type};
        }

        my $unpriced_tokens = defined($reason) ? $tokens : 0;

        push @cells, {
            role => $role, model => $model, effort => $effort, token_type => $type,
            tokens => $tokens, cost_usd => $cost, unpriced_tokens => $unpriced_tokens,
            reason => $reason,
        };
    }

    return \@cells;
}

# ---------------------------------------------------------------------------
# _session_agent_anomaly(\@order, \%requests, $role) -> \%anomaly. Mirrors
# bp-spend.pl's consecutive-same-size-cache-write anomaly (:757-770), but
# DELIBERATELY keyed by the agent FILE alone, not (session_id, role): within
# one file every request is the same conversation branch, and session_id is
# shared across every file of a drive-solo session, so keying by it here
# would compare unrelated branches (spec B11).
# ---------------------------------------------------------------------------
sub _session_agent_anomaly {
    my ($order, $requests, $role) = @_;

    my @pairs;
    my $prev;
    for my $key (@$order) {
        my $req  = $requests->{$key};
        my $size = $req->{cc_unsplit};
        next if $size == 0;
        if (defined($prev) && $prev->{size} == $size) {
            push @pairs, {
                session_id  => $req->{first_session_id},
                role        => $role,
                size        => $size,
                first_uuid  => $prev->{first_uuid},
                second_uuid => $req->{first_uuid},
            };
        }
        $prev = { size => $size, first_uuid => $req->{first_uuid} };
    }

    my $total = 0;
    $total += $_->{size} for @pairs;
    return {
        name         => 'consecutive-same-size-cache-write',
        count        => scalar(@pairs),
        total_tokens => $total,
        pairs        => \@pairs,
    };
}

# ---------------------------------------------------------------------------
# _session_cell_key($cell) -> the (role, model, effort, token_type, hour)
# string key used to merge cells emitted by different requests/agents into
# one. `hour` is left undef on every cell (folded to '' by the join below)
# unless derive_session's by_hour flag is set (spec 02 Sec2.5), so it is a
# no-op appended field otherwise.
# ---------------------------------------------------------------------------
sub _session_cell_key {
    my ($c) = @_;
    # \x1e-escape each field before joining (fix-batch redteam L4): without
    # this, a field containing a literal \x1e could collide two genuinely
    # distinct cells into one.
    return join("\x1e", map { (my $x = defined($_) ? $_ : ''); $x =~ s/\x1e/\x1e\x1e/g; $x }
        ($c->{role}, $c->{model}, $c->{effort}, $c->{token_type}, $c->{hour}));
}

# ---------------------------------------------------------------------------
# _session_merge_cells(\%acc, \@cells) -> merges @cells into %acc in place,
# keyed by _session_cell_key.
# ---------------------------------------------------------------------------
sub _session_merge_cells {
    my ($acc, $cells) = @_;
    for my $c (@$cells) {
        my $k = _session_cell_key($c);
        my $entry = ($acc->{$k} //= {
            role => $c->{role}, model => $c->{model}, effort => $c->{effort},
            token_type => $c->{token_type}, hour => $c->{hour}, tokens => 0, cost_usd => 0, unpriced_tokens => 0,
            reasons => {},
        });
        $entry->{tokens}          += $c->{tokens};
        $entry->{cost_usd}        += $c->{cost_usd};
        $entry->{unpriced_tokens} += $c->{unpriced_tokens};
        $entry->{reasons}{ $c->{reason} } += $c->{tokens} if defined $c->{reason};
    }
    return;
}

# ---------------------------------------------------------------------------
# _session_merge_by_type(\%acc, \@cells) -> merges @cells into %acc keyed by
# token_type ALONE (role/model/effort collapsed) -- feeds derive_session's
# totals.<type> figures from the same unrounded per-request contributions
# %session_cell_acc gets, so a type total is never built by re-summing
# already-rounded per-cell figures (Decision 18, spec Sec2.7 rounding note).
# ---------------------------------------------------------------------------
sub _session_merge_by_type {
    my ($acc, $cells) = @_;
    for my $c (@$cells) {
        my $entry = ($acc->{ $c->{token_type} } //= { tokens => 0, cost_usd => 0, unpriced_tokens => 0, reasons => {} });
        $entry->{tokens}          += $c->{tokens};
        $entry->{cost_usd}        += $c->{cost_usd};
        $entry->{unpriced_tokens} += $c->{unpriced_tokens};
        $entry->{reasons}{ $c->{reason} } += $c->{tokens} if defined $c->{reason};
    }
    return;
}

# ---------------------------------------------------------------------------
# _session_unpriced_reasons_array(\%reasons) -> \@[{reason,tokens}], sorted
# ascending by reason (cmp), tokens>0 only (spec Sec2.7's unpriced_reasons).
# ---------------------------------------------------------------------------
sub _session_unpriced_reasons_array {
    my ($reasons) = @_;
    return [
        map { { reason => $_, tokens => int($reasons->{$_}) } }
        sort grep { $reasons->{$_} > 0 } keys %$reasons
    ];
}

# ---------------------------------------------------------------------------
# _session_sorted_cells(\%acc, $pricing_not_ok, $by_hour) -> \@cells, rounded
# once at emission, sorted ascending by role, then model, then effort, then
# token_type, then (iff $by_hour) hour (cmp on each), zero-tokens cells
# dropped. api_equivalent_cost_usd is undef (JSON null) when every token in
# the cell is unpriced (spec Sec2.7/Decision 18). $by_hour false/absent: no
# `hour` key at all, byte-identical to package 01 (spec 02 Sec2.5).
# ---------------------------------------------------------------------------
sub _session_sorted_cells {
    my ($acc, $pricing_not_ok, $by_hour) = @_;
    my @cells =
        grep { $_->{tokens} > 0 }
        map  {
            my $c = $acc->{$_};
            # S1 (fix-batch review): null iff pricing_status ne 'ok' OR the
            # cell is fully unpriced -- not only the latter, which by itself
            # left an offline/unavailable cell showing a dollar zero whenever
            # its unpriced_tokens happened not to equal tokens (defensive;
            # in practice rates_for_request already marks every token of an
            # offline/unavailable request unpriced).
            my $fully_unpriced = $pricing_not_ok || ($c->{tokens} > 0 && $c->{unpriced_tokens} == $c->{tokens});
            {
                role => $c->{role}, model => $c->{model}, effort => $c->{effort},
                token_type => $c->{token_type},
                ($by_hour ? (hour => $c->{hour}) : ()),
                tokens => int($c->{tokens}),
                api_equivalent_cost_usd => $fully_unpriced ? undef : 0 + sprintf('%.6f', $c->{cost_usd}),
                unpriced_tokens => int($c->{unpriced_tokens}),
                unpriced_reasons => _session_unpriced_reasons_array($c->{reasons}),
            };
        }
        keys %$acc;
    @cells = sort {
           $a->{role} cmp $b->{role}
        || $a->{model} cmp $b->{model}
        || $a->{effort} cmp $b->{effort}
        || $a->{token_type} cmp $b->{token_type}
        || ($by_hour ? ($a->{hour} cmp $b->{hour}) : 0)
    } @cells;
    return \@cells;
}

# ---------------------------------------------------------------------------
# derive_session(%opts) -> \%session_result. See spec §2.1-2.5.
#   opts: session => PATH (required)
# Dies (never returns a partial doc) when the session's main transcript
# cannot be resolved or opened.
# ---------------------------------------------------------------------------
sub derive_session {
    my (%opts) = @_;
    my $session = $opts{session};
    my $pricing = $opts{pricing} // BpPricing::offline();
    my $pricing_not_ok = $pricing->{status} ne 'ok';
    my $by_hour = $opts{by_hour} ? 1 : 0;

    # Package 02 spec Sec2.1/Sec2.4 -- a window is GIVEN iff %w was passed
    # and at least one bound is defined. With no window, every behaviour and
    # every output byte is exactly as package 01 (B9/TW8).
    my $win          = $opts{window};
    my $since        = (ref($win) eq 'HASH') ? $win->{since} : undef;
    my $until        = (ref($win) eq 'HASH') ? $win->{until} : undef;
    my $window_given = ref($win) eq 'HASH' && (defined($since) || defined($until));

    my $req_in_window      = 0;
    my $req_outside_window = 0;
    my $req_no_timestamp   = 0;

    my $sp = defined($session) ? $session : '';
    $sp =~ s{[/\\]+\z}{};

    my ($main, $dir);
    if ($sp =~ /\.jsonl\z/) {
        $main = $sp;
        ($dir = $sp) =~ s/\.jsonl\z//;
    }
    else {
        $dir  = $sp;
        $main = "$sp.jsonl";
    }
    my $subdir = "$dir/subagents";

    unless (length($main) && -f $main) {
        die "derive_session: no such session transcript: " . _session_truncate_for_error($session) . "\n";
    }
    # An existing-but-unopenable main transcript (permissions, a Windows
    # sharing lock, etc.) must not silently report an all-zero document as if
    # the session were genuinely empty (fix-batch redteam M4/review L1) --
    # only the MAIN transcript is fatal here; subagent files stay non-fatal
    # on open failure via _session_read_agent_file.
    unless (open(my $main_probe_fh, '<:raw', $main)) {
        die "derive_session: no such session transcript: " . _session_truncate_for_error($session) . "\n";
    }
    else {
        close $main_probe_fh;
    }

    my @agent_files;   # { path => STR, kind => 'driver'|'subagent', name => STR }
    push @agent_files, { path => $main, kind => 'driver' };
    if (-d $subdir) {
        my $dh;
        opendir($dh, $subdir);
        if ($dh) {
            my @names = sort grep { /^agent-.*\.jsonl\z/ && -f "$subdir/$_" } readdir($dh);
            closedir $dh;
            for my $n (@names) {
                push @agent_files, { path => "$subdir/$n", kind => 'subagent', name => $n };
            }
        }
    }

    my $record_counts = {
        assistant_records       => 0,
        requests                => 0,
        unkeyed                 => 0,
        request_usage_mismatch  => 0,
        multi_iteration         => 0,
        speed_absent            => 0,
        skipped_unparseable     => 0,
        malformed_usage_field   => 0,
    };

    my %session_cell_acc;
    my %type_acc;   # token_type => {tokens,cost_usd,unpriced_tokens,reasons=>{}}
    my @agents;
    my @session_pairs;

    for my $af (@agent_files) {
        my ($role, $spawn_depth, $description);
        if ($af->{kind} eq 'driver') {
            $role = 'driver';
            $spawn_depth = 0;
            $description = undef;
        }
        else {
            (my $base = $af->{name}) =~ s/\.jsonl\z//;
            my $meta = _session_read_sidecar("$subdir/$base.meta.json");
            if (ref($meta) eq 'HASH' && defined($meta->{agentType}) && !ref($meta->{agentType}) && length($meta->{agentType})) {
                $role = $meta->{agentType};
            }
            else {
                $role = 'unknown-agent';
            }
            if (ref($meta) eq 'HASH' && defined($meta->{spawnDepth}) && !ref($meta->{spawnDepth})
                && $meta->{spawnDepth} =~ /^\d+\z/) {
                $spawn_depth = $meta->{spawnDepth} + 0;
            }
            else {
                $spawn_depth = undef;
            }
            if (ref($meta) eq 'HASH' && defined($meta->{description}) && !ref($meta->{description})
                && length($meta->{description})) {
                $description = $meta->{description};
            }
            else {
                $description = undef;
            }
        }

        my ($order, $requests, $first_ts) = _session_read_agent_file($af->{path}, $record_counts);

        # Package 02 spec Sec2.4 -- membership is decided PER DEDUPLICATED
        # REQUEST, by its placement timestamp, once. With no window, every
        # request is kept (byte-identical to package 01). @kept_keys
        # preserves @order's file order, which is what the anomaly and the
        # hour-bucketed cells both need.
        my @kept_keys;
        my $agent_in_window = 0;
        for my $key (@$order) {
            my $req = $requests->{$key};
            my $pts = $req->{place_ts};
            if ($window_given) {
                my $member = defined($pts)
                    && (!defined($since) || $pts >= $since)
                    && (!defined($until) || $pts <  $until);
                if ($member) {
                    $agent_in_window++;
                    $req_in_window++;
                    push @kept_keys, $key;
                }
                else {
                    $req_outside_window++;
                    $req_no_timestamp++ unless defined $pts;
                }
            }
            else {
                push @kept_keys, $key;
            }
        }

        my %agent_cell_acc;
        for my $key (@kept_keys) {
            my $req = $requests->{$key};
            my $cells = _session_price_request($req, $role, $pricing);
            if ($by_hour) {
                my $pts = $req->{place_ts};
                my $label = defined($pts) ? _session_hour_label($pts) : '(no-timestamp)';
                $_->{hour} = $label for @$cells;
            }
            _session_merge_cells(\%agent_cell_acc, $cells);
            _session_merge_cells(\%session_cell_acc, $cells);
            _session_merge_by_type(\%type_acc, $cells);
        }

        # The anomaly (Decision 5) runs over the IN-WINDOW requests only, in
        # file order (spec Sec2.4's "effects when a window is given").
        my $anomaly = _session_agent_anomaly(\@kept_keys, $requests, $role);
        push @session_pairs, @{ $anomaly->{pairs} };

        push @agents, {
            path        => _session_slashify($af->{path}),
            role        => $role,
            spawn_depth => $spawn_depth,
            description => $description,
            first_ts    => $first_ts,
            cells       => _session_sorted_cells(\%agent_cell_acc, $pricing_not_ok, $by_hour),
            anomaly     => $anomaly,
            ($window_given ? (in_window_requests => $agent_in_window) : ()),
        };
    }

    my $session_cells = _session_sorted_cells(\%session_cell_acc, $pricing_not_ok, $by_hour);

    # Accumulated from the UNROUNDED %type_acc (fed by the same per-request
    # cells as %session_cell_acc), never by re-summing $session_cells'
    # already-rounded per-cell figures (fix-batch review M1/redteam L8/n2 --
    # a double-round). Rounding happens exactly once, below, at emission.
    my %totals;
    for my $type (qw(input output cache_write_5m cache_write_1h cache_read cache_write_unsplit)) {
        my $e = $type_acc{$type} // { tokens => 0, cost_usd => 0, unpriced_tokens => 0, reasons => {} };
        # S1 (fix-batch review): null iff pricing_status ne 'ok' OR fully
        # unpriced -- a zero-token type in an offline/unavailable document
        # must never show a dollar zero.
        my $fully_unpriced = $pricing_not_ok || ($e->{tokens} > 0 && $e->{unpriced_tokens} == $e->{tokens});
        $totals{$type} = {
            tokens => int($e->{tokens}),
            api_equivalent_cost_usd => $fully_unpriced ? undef : 0 + sprintf('%.6f', $e->{cost_usd}),
            unpriced_tokens => int($e->{unpriced_tokens}),
            unpriced_reasons => _session_unpriced_reasons_array($e->{reasons}),
        };
    }

    my %unpriced = do { no warnings 'once'; map { $_ => 0 } @BpPricing::UNPRICED_REASONS };
    for my $type (keys %type_acc) {
        for my $reason (keys %{ $type_acc{$type}{reasons} }) {
            $unpriced{$reason} += $type_acc{$type}{reasons}{$reason};
        }
    }

    my $session_anomaly_total = 0;
    $session_anomaly_total += $_->{size} for @session_pairs;

    return {
        cost_basis        => 'fetched',
        price_source      => $pricing->{source},
        price_fetched_at  => $pricing->{fetched_at},
        pricing_status    => BpPricing::status_string($pricing),
        ($pricing->{price_fetch_override} ? (price_fetch_override => JSON::PP::true) : ()),
        cells        => $session_cells,
        totals       => \%totals,
        unpriced     => \%unpriced,
        anomaly      => {
            name         => 'consecutive-same-size-cache-write',
            count        => scalar(@session_pairs),
            total_tokens => $session_anomaly_total,
            pairs        => \@session_pairs,
        },
        record_counts => $record_counts,
        agents        => \@agents,
        # Package 02 spec Sec2.4 -- present ONLY when a window was given
        # (B9/TW8: with no window, neither this key nor agents[].in_window_
        # requests exists, so output is byte-for-byte package 01).
        ($window_given ? (window => {
            since                    => defined($since) ? _session_iso_epoch($since) : undef,
            until                    => defined($until) ? _session_iso_epoch($until) : undef,
            requests_in_window       => $req_in_window,
            requests_outside_window  => $req_outside_window,
            requests_no_timestamp    => $req_no_timestamp,
        }) : ()),
    };
}

# ---------------------------------------------------------------------------
# _totals_grand(\%totals) -> ($tokens, $cost_usd, $unpriced_tokens, \@reasons)
# -- sums derive_session's six totals.<type> entries into one grand figure,
# for the text-mode TOTAL line (shared by derive-session and report-session).
# ---------------------------------------------------------------------------
sub _totals_grand {
    my ($totals) = @_;
    my ($tokens, $cost, $unpriced) = (0, 0, 0);
    my %reasons;
    for my $type (qw(input output cache_write_5m cache_write_1h cache_read cache_write_unsplit)) {
        my $t = $totals->{$type};
        $tokens   += $t->{tokens};
        $cost     += ($t->{api_equivalent_cost_usd} // 0);
        $unpriced += $t->{unpriced_tokens};
        for my $r (@{ $t->{unpriced_reasons} }) { $reasons{ $r->{reason} } += $r->{tokens}; }
    }
    return ($tokens, $cost, $unpriced, _session_unpriced_reasons_array(\%reasons));
}

# ---------------------------------------------------------------------------
# _fmt_tok_segment(\%type_to_tokens) -> "input=N cache_write_5m=N ..." (spec
# Sec3.2's fixed TOK segment, always all six in this order).
# ---------------------------------------------------------------------------
sub _fmt_tok_segment {
    my ($tok) = @_;
    return join(' ', map { "$_=$tok->{$_}" } qw(input cache_write_5m cache_write_1h cache_write_unsplit cache_read output));
}

# ---------------------------------------------------------------------------
# _fmt_pricing_header($doc) -> the "pricing: <P>" line's <P> (spec Sec3.2).
# ---------------------------------------------------------------------------
sub _fmt_pricing_header {
    my ($doc, $long_context_note) = @_;
    my $st = $doc->{pricing_status};
    # S4 (fix-batch review): a leftover CCPRAXIS_SPEND_FETCH_CMD looks exactly
    # like a real fetch otherwise, so a report run under the override always
    # says so.
    my $override_note = $doc->{price_fetch_override} ? ", fetched via override command" : '';
    if ($st eq 'ok') {
        my $line = "ok, source $doc->{price_source}, fetched-at $doc->{price_fetched_at}$override_note";
        $line .= ", $long_context_note" if defined $long_context_note;
        return $line;
    }
    return "offline (no fetch: --offline or CCPRAXIS_SPEND_NO_FETCH)" if $st eq 'offline';
    my $line = $st;
    $line .= ", source $doc->{price_source}" if defined $doc->{price_source};
    $line .= $override_note;
    return $line;
}

# ---------------------------------------------------------------------------
# _fmt_window_header(\%window) -> the "window: ..." line (spec 02 Sec2.7),
# for both derive-session and report-session text mode. `-` marks an
# unbounded side.
# ---------------------------------------------------------------------------
sub _fmt_window_header {
    my ($w) = @_;
    my $s = defined($w->{since}) ? $w->{since} : '-';
    my $u = defined($w->{until}) ? $w->{until} : '-';
    return "window: [$s, $u) UTC, requests in-window $w->{requests_in_window}, "
         . "outside-window $w->{requests_outside_window} (no timestamp $w->{requests_no_timestamp})";
}

# ---------------------------------------------------------------------------
# _fmt_cost_cell($pricing_status, $cost_usd, $unpriced_tokens, $tokens, \@reasons)
# -> the COST grammar (spec Sec3.2).
# ---------------------------------------------------------------------------
sub _fmt_cost_cell {
    my ($status, $cost, $unpriced, $tokens, $reasons) = @_;
    return 'unavailable: offline' if $status eq 'offline';
    return $status if $status =~ /^unavailable:/;
    my $rtext = join(', ', map { "$_->{reason} $_->{tokens}" } @$reasons);
    return sprintf('$%.6f', $cost // 0) if $unpriced == 0;
    return sprintf('$%.6f + unpriced %d tokens (%s)', $cost // 0, $unpriced, $rtext) if $unpriced > 0 && $unpriced < $tokens;
    return sprintf('unpriced %d tokens (%s)', $unpriced, $rtext);
}

# ===========================================================================
# Package 02 -- attribution and report (blueprint usage-telemetry, package
# 02-attribution-and-report). Attributes each derive_session() agent entry to
# a blueprint/package via bp-dispatch-log.pl's dispatch records and the
# on-disk blueprint ledgers, then pivots package 01's agents[].cells by any
# ordered subset of role/blueprint/package/model/effort/token_type. Pure
# functions except for the filesystem reads named in their own docs; the CLI
# verb at the bottom of this file is the only writer-adjacent caller (and it
# never writes -- read-only, spec §2.7 B12).
# Spec: .ccpraxis-local-data/blueprints/usage-telemetry/specs/
# 02-attribution-and-report-spec.md
# ===========================================================================
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# Mirrors bp-spend.pl:51-52's require idiom exactly (spec §2.1) -- re-derives
# its own $DISPATCH_DIR rather than reaching across packages for BpSpend's
# file-scoped $DIR. bp-dispatch-log.pl guards its own CLI with `unless
# (caller)` and ends `1;`, so this require is side-effect-free. The ONLY
# symbol used from it is $BpDispatchLog::DEFAULT_BUDGET_SECONDS --
# list_records/read_record/log_dir take the repo root, not the data root, and
# are never called (out of scope, spec §6).
my $DISPATCH_DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; abs_path($f) // $f });
# Soft require: the launcher's spend sampler and the session reports
# load bp-spend.pl at their own load time, so a compile failure in
# bp-dispatch-log.pl must not take them down too. $DISPATCH_DEFAULT_BUDGET_FALLBACK
# below covers the anomaly path where this failed or the upstream constant is
# missing/renamed; the NORMAL path still reads
# $BpDispatchLog::DEFAULT_BUDGET_SECONDS by its fully-qualified name (spec §2.1).
eval { require "$DISPATCH_DIR/bp-dispatch-log.pl"; 1 };

# Anomaly-path-only fallback -- used ONLY if the require above failed or
# $BpDispatchLog::DEFAULT_BUDGET_SECONDS is missing/renamed upstream. Never
# read in the normal path (spec §2.1 forbids re-typing 1800 as the
# normal-path value, not as an anomaly fallback).
our $DISPATCH_DEFAULT_BUDGET_FALLBACK = 1800;

our @REPORT_DIMENSIONS        = qw(role blueprint package model effort token_type hour);
our @REPORT_DEFAULT_BY        = qw(role model);
our @ATTRIBUTION_REASONS      = qw(unknown-agent ambiguous id-unresolved no-dispatch-record outside-window);
our $DRIVER_LABEL             = '(driver)';
our $UNATTRIBUTED_LABEL       = 'unattributed';
our $ATTRIBUTION_LEAD_SECONDS = 120;

our @REPORT_TOKEN_TYPES = qw(input output cache_write_5m cache_write_1h cache_read cache_write_unsplit);

# ---------------------------------------------------------------------------
# resolve_data_root($explicit, $session) -> ( slashified data-root path,
# source ). In order:
#   1. --data-root, verbatim                             -> 'explicit'
#   2. the nearest .ccpraxis-local-data at or above the
#      `cwd` the SESSION recorded                        -> 'session-cwd'
#   3. $CLAUDE_PROJECT_DIR/.ccpraxis-local-data          -> 'CLAUDE_PROJECT_DIR'
#   4. <this script>/../../../.ccpraxis-local-data       -> 'script-location'
# Step 2 is first among the defaults because the question is "which project
# did THIS session run in", and the session says so itself. Steps 3-4 were
# the whole default before it, and step 4 is wrong in exactly the normal
# case: run from the live install, it names the live install's own data dir,
# so on 2026-09-23 report-session read 21 stray records there instead of the
# project's 552 and attributed 0 of 605M subagent tokens. Only step 2 checks
# the filesystem; steps 1, 3 and 4 never do (spec §2.3).
# ---------------------------------------------------------------------------
sub resolve_data_root {
    my ($explicit, $session) = @_;
    if (defined $explicit && length $explicit) {
        (my $r = $explicit) =~ s{\\}{/}g;
        $r =~ s{/+\z}{};
        return wantarray ? ($r, 'explicit') : $r;
    }
    my ($root, $source);
    if (defined(my $cwd = _session_recorded_cwd($session))) {
        # Decision 22: _session_recorded_cwd returns exactly what
        # JSON::PP->new->utf8->decode gives for `cwd` -- a Perl CHARACTER
        # string (utf8 flag on) whenever the recorded cwd holds a non-ASCII
        # byte. Every path this file compares or returns uses the
        # filesystem's own representation, raw UTF-8 BYTES on this perl.
        # This is the ONE boundary where the decoded JSON string enters path
        # logic (the bounded walk-up just below), so it is normalised here,
        # once, rather than by weakening any comparison downstream.
        utf8::encode($cwd) if utf8::is_utf8($cwd);
        # bounded walk-up (package 03, Decision 3): never ascend out of temp,
        # and never adopt home unless the start IS home. Soft require: a
        # missing/broken BpProjectRoot.pm must not take down this file's
        # loaders -- resolution simply falls through to the next step.
        eval {
            require "$DIR/BpProjectRoot.pm" unless grep { m{(?:^|/)BpProjectRoot\.pm$} } keys %INC;
            my $found = BpProjectRoot::bounded_walkup($cwd);
            ($root, $source) = ($found, 'session-cwd') if defined $found;
        };
    }
    if (!defined $root && defined $ENV{CLAUDE_PROJECT_DIR} && length $ENV{CLAUDE_PROJECT_DIR}) {
        ($root, $source) = ($ENV{CLAUDE_PROJECT_DIR}, 'CLAUDE_PROJECT_DIR');
    }
    if (!defined $root) {
        ($root, $source) = (Cwd::abs_path("$DISPATCH_DIR/../../..") // '.', 'script-location');
    }
    (my $r = $root) =~ s{\\}{/}g;
    $r =~ s{/+\z}{};
    $r .= '/.ccpraxis-local-data';
    return wantarray ? ($r, $source) : $r;
}

# ---------------------------------------------------------------------------
# _session_recorded_cwd($session) -> the slashified `cwd` the session's main
# transcript records, or undef. Claude Code stamps `cwd` on its records from
# the first line on, so this reads at most the first 200 lines and skips any
# line over 1 MiB rather than parsing a large one to find a small field.
# ---------------------------------------------------------------------------
sub _session_recorded_cwd {
    my ($session) = @_;
    return undef unless defined $session && length $session;
    (my $main = $session) =~ s{[/\\]+\z}{};
    $main .= '.jsonl' unless $main =~ /\.jsonl\z/;
    open(my $fh, '<:raw', $main) or return undef;
    my $cwd;
    my $n = 0;
    while (defined(my $line = <$fh>)) {
        last if ++$n > 200;
        next if length($line) > 1_048_576;
        $line =~ s/\r?\n\z//;
        my $members = _session_json_members($line) or next;
        for my $m (@$members) {
            next unless $m->[0] eq 'cwd';
            my $v = eval { _session_json_scalar($m->[1]) };
            $cwd = $v if defined($v) && !ref($v) && length($v);
        }
        last if defined $cwd;
    }
    close $fh;
    return undef unless defined $cwd;
    $cwd =~ s{\\}{/}g;
    $cwd =~ s{/+\z}{} unless $cwd eq '/';
    return $cwd;
}

# ---------------------------------------------------------------------------
# load_dispatch_records($data_root) -> \@records (never dies). Spec §2.4.
# ---------------------------------------------------------------------------
sub load_dispatch_records {
    my ($data_root) = @_;
    my $dir = "$data_root/.dispatch-log";
    my @records;
    my $dh;
    return [] unless opendir($dh, $dir);
    my @names = sort readdir($dh);
    closedir $dh;
    for my $name (@names) {
        next unless $name =~ /\.json\z/;
        my $path = "$dir/$name";
        next unless -f $path;
        (my $base = $name) =~ s/\.json\z//;
        next if $base =~ /\Ahk-/;
        open(my $fh, '<:raw', $path) or next;
        my $raw = do { local $/; <$fh> };
        close $fh;
        my $rec = eval { JSON::PP->new->utf8->decode($raw) };
        next unless ref($rec) eq 'HASH';
        my $id = (defined $rec->{id} && !ref($rec->{id}) && length($rec->{id})) ? $rec->{id} : $base;
        # SANITISED: $id/worker_type/blueprint/package are record-sourced and
        # can reach a text report or a JSON row key. Control bytes are
        # stripped and length capped so a hostile record can neither inject a
        # line break/ANSI escape into the report nor collide two distinct
        # blueprint/package names into the same \x1f-joined row key via an
        # embedded \x1f byte. Same precedent as _gate_diagnostic above.
        $id =~ tr/\x00-\x1f\x7f//d;
        $id = substr($id, 0, 120) if length($id) > 120;
        next if $id =~ /\Ahk-/;
        next unless defined $rec->{worker_type} && !ref($rec->{worker_type}) && length($rec->{worker_type});
        next unless defined $rec->{started_at} && !ref($rec->{started_at}) && $rec->{started_at} =~ /\A\d+(?:\.\d+)?\z/;
        my $started_at = $rec->{started_at} + 0;

        my $ended_at;
        if (defined $rec->{ended_at} && !ref($rec->{ended_at}) && $rec->{ended_at} =~ /\A\d+(?:\.\d+)?\z/) {
            my $e = $rec->{ended_at} + 0;
            $ended_at = $e if $e >= $started_at;
        }

        my $budget;
        if (defined $rec->{budget_seconds} && !ref($rec->{budget_seconds})
            && $rec->{budget_seconds} =~ /\A\d+(?:\.\d+)?\z/ && $rec->{budget_seconds} + 0 > 0) {
            $budget = $rec->{budget_seconds} + 0;
        }
        else {
            # Still the only code reference to this fully-qualified package
            # variable in this file (the require above is soft, so it can
            # legitimately never populate it) -- scoped no warnings 'once',
            # not a file-wide blanket.
            no warnings 'once';
            $budget = $BpDispatchLog::DEFAULT_BUDGET_SECONDS // $DISPATCH_DEFAULT_BUDGET_FALLBACK;
        }

        my $worker_type = $rec->{worker_type};
        $worker_type =~ tr/\x00-\x1f\x7f//d;
        $worker_type = substr($worker_type, 0, 120) if length($worker_type) > 120;

        my $blueprint = (defined $rec->{blueprint} && !ref($rec->{blueprint}) && length($rec->{blueprint}))
            ? $rec->{blueprint} : undef;
        if (defined $blueprint) {
            $blueprint =~ tr/\x00-\x1f\x7f//d;
            $blueprint = substr($blueprint, 0, 120) if length($blueprint) > 120;
        }
        my $package = (defined $rec->{package} && !ref($rec->{package}) && length($rec->{package}))
            ? $rec->{package} : undef;
        if (defined $package) {
            $package =~ tr/\x00-\x1f\x7f//d;
            $package = substr($package, 0, 120) if length($package) > 120;
        }

        push @records, {
            id => $id, worker_type => $worker_type, started_at => $started_at,
            ended_at => $ended_at, budget => $budget, blueprint => $blueprint, package => $package,
        };
    }
    return \@records;
}

# ---------------------------------------------------------------------------
# load_dispatch_attribution($data_root) -> { <tool_use_id> => { blueprint,
# package, source } } (never dies), from the append-only records
# hooks/track-dispatch.sh writes at dispatch time:
# <data_root>/.dispatch-log/attribution.jsonl, plus its one rolled-over
# predecessor attribution.jsonl.1. A tool_use_id recorded twice with
# DIFFERENT packages maps to { conflict => 1 } and attributes nothing -- two
# claims about one dispatch are not resolved by picking one. Names are held to
# the hook's own rule ([A-Za-z0-9._-], no leading dot, no '..'), so a
# hand-edited line cannot smuggle a control byte into a report row.
# ---------------------------------------------------------------------------
sub _load_attribution_files {
    my (@files) = @_;
    my %map;
    my $name_ok = sub {
        my ($v) = @_;
        return defined($v) && !ref($v) && $v =~ /\A[A-Za-z0-9._-]{1,120}\z/
            && $v !~ /\A\./ && $v !~ /\.\./;
    };
    for my $file (@files) {
        open(my $fh, '<:raw', $file) or next;
        while (defined(my $line = <$fh>)) {
            next if length($line) > 4096;
            $line =~ s/\r?\n\z//;
            my $members = _session_json_members($line) or next;
            my %f;
            for my $m (@$members) {
                my $v = eval { _session_json_scalar($m->[1]) };
                $f{ $m->[0] } = $v unless ref $v;
            }
            my $tuid = $f{tool_use_id};
            next unless defined($tuid) && $tuid =~ /\A[A-Za-z0-9_-]{1,128}\z/;
            next unless $name_ok->($f{blueprint}) && $name_ok->($f{package});
            my $source = (defined($f{source}) && $f{source} =~ /\A[a-z-]{1,32}\z/) ? $f{source} : 'unknown';
            my $prev = $map{$tuid};
            if ($prev && ($prev->{conflict}
                          || $prev->{blueprint} ne $f{blueprint} || $prev->{package} ne $f{package})) {
                $map{$tuid} = { conflict => 1 };
                next;
            }
            $map{$tuid} = { blueprint => $f{blueprint}, package => $f{package}, source => $source };
        }
        close $fh;
    }
    return \%map;
}

# package 12-dispatch-binding: bp-spend now reads TWO append-only stores with
# the one line parser/rule set above -- store A (hooks/record-dispatch-
# package.sh, pre-existing) and store B (hooks/next/bind-dispatch.sh's
# .drive-solo/bindings.jsonl(.1), package 12). Within one store the existing
# conflict rule applies unchanged; across stores, a tool_use_id present in
# store B's map (a valid entry OR a {conflict=>1} marker) replaces store A's
# entry for that id. An id only in A keeps A's entry untouched.
sub load_dispatch_attribution {
    my ($data_root) = @_;
    my $map_a = _load_attribution_files(
        "$data_root/.dispatch-log/attribution.jsonl.1",
        "$data_root/.dispatch-log/attribution.jsonl",
    );
    my $map_b = _load_attribution_files(
        "$data_root/.drive-solo/bindings.jsonl.1",
        "$data_root/.drive-solo/bindings.jsonl",
    );
    my %merged = %$map_a;
    $merged{$_} = $map_b->{$_} for keys %$map_b;
    return \%merged;
}

# ---------------------------------------------------------------------------
# _session_agent_tool_use_id($agent_path) -> the `toolUseId` in the agent
# file's `.meta.json` sidecar, or undef. Claude Code writes the id of the
# Agent tool call that spawned the subagent there; it is the same id a
# PreToolUse hook sees as `tool_use_id` (verified 2026-09-23: every sidecar
# sampled matched a tool_use block `id` in its parent transcript).
# ---------------------------------------------------------------------------
sub _session_agent_tool_use_id {
    my ($agent_path) = @_;
    return undef unless defined($agent_path) && $agent_path =~ /\.jsonl\z/;
    (my $meta_path = $agent_path) =~ s/\.jsonl\z/.meta.json/;
    my $meta = _session_read_sidecar($meta_path);
    return undef unless ref($meta) eq 'HASH';
    my $id = $meta->{toolUseId};
    return (defined($id) && !ref($id) && $id =~ /\A[A-Za-z0-9_-]{1,128}\z/) ? $id : undef;
}

# ---------------------------------------------------------------------------
# _blueprint_packages($bp_dir) -> { <int> => [ <ledger-id>, ... ] }, built
# from $bp_dir/packages/*.md. Private, used only by blueprint_index below.
# ---------------------------------------------------------------------------
sub _blueprint_packages {
    my ($bp_dir) = @_;
    my %packages;
    my $pkg_dir = "$bp_dir/packages";
    my $dh;
    return {} unless opendir($dh, $pkg_dir);
    my @names = sort readdir($dh);
    closedir $dh;
    for my $name (@names) {
        next unless $name =~ /\.md\z/;
        my $path = "$pkg_dir/$name";
        next unless -f $path;
        (my $ledger_id = $name) =~ s/\.md\z//;
        next unless $ledger_id =~ /\A(\d+)/;
        my $n = $1 + 0;
        push @{ $packages{$n} //= [] }, $ledger_id;
    }
    return \%packages;
}

# ---------------------------------------------------------------------------
# blueprint_index($data_root) -> { <name> => { archived => 0|1, packages =>
# {...} } }. Spec §2.5. A name present under both blueprints/ and
# blueprints/_archive/ resolves to the active one; the archived entry is
# discarded outright.
# ---------------------------------------------------------------------------
sub blueprint_index {
    my ($data_root) = @_;
    my %index;

    my $active_dir = "$data_root/blueprints";
    if (opendir(my $dh, $active_dir)) {
        my @names = sort readdir($dh);
        closedir $dh;
        for my $name (@names) {
            next if $name eq '.' || $name eq '..' || $name eq '_archive';
            next unless -d "$active_dir/$name";
            $index{$name} = { archived => 0, packages => _blueprint_packages("$active_dir/$name") };
        }
    }

    my $archive_dir = "$data_root/blueprints/_archive";
    if (opendir(my $dh2, $archive_dir)) {
        my @names = sort readdir($dh2);
        closedir $dh2;
        for my $name (@names) {
            next if $name eq '.' || $name eq '..';
            next unless -d "$archive_dir/$name";
            next if exists $index{$name};   # active-over-archive
            $index{$name} = { archived => 1, packages => _blueprint_packages("$archive_dir/$name") };
        }
    }

    return \%index;
}

# ---------------------------------------------------------------------------
# _resolve_bp_pkg($record, $index) -> ($blueprint, $package, $source) |
# (undef, undef). Spec §2.6/B3. $record is already-normalised (load_dispatch_
# records shape, or an equivalent plain hash passed directly by a caller).
# ---------------------------------------------------------------------------
sub _resolve_bp_pkg {
    my ($rec, $index) = @_;

    if (defined $rec->{blueprint} && !ref($rec->{blueprint}) && length($rec->{blueprint})
        && defined $rec->{package} && !ref($rec->{package}) && length($rec->{package})) {
        return ($rec->{blueprint}, $rec->{package}, 'record-fields');
    }

    my $id = defined $rec->{id} ? $rec->{id} : '';
    my $best_name;
    for my $name (keys %$index) {
        next unless $id =~ /\A\Q$name\E-/;
        $best_name = $name if !defined($best_name) || length($name) > length($best_name);
    }
    return (undef, undef) unless defined $best_name;

    my $rest  = substr($id, length($best_name) + 1);
    my $token = ($rest =~ /\A([^-]*)/) ? $1 : $rest;
    return (undef, undef) unless $token =~ /\A\d+\z/;
    my $n = $token + 0;

    my $bucket = $index->{$best_name}{packages}{$n};
    return (undef, undef) unless $bucket && @$bucket == 1;
    return ($best_name, $bucket->[0], 'record-id');
}

# ---------------------------------------------------------------------------
# attribute_session(doc => \%session_doc, records => \@records,
# index => \%blueprint_index, dispatch_hook => \%tool_use_id_map,
# tool_use_ids => \@ids) -> \@attributions (spec §2.6). Pure function:
# reads no file, no wall-clock. Entry 0 is always the driver (B6).
#
# An agent whose sidecar toolUseId ($tool_use_ids[$i]) has a
# track-dispatch.sh record is attributed from that record, source
# `dispatch-hook`: an exact key recorded when the dispatch happened, so it
# goes before every inference below. The dispatch-log time-window match and
# the description heuristic (B4) remain for sessions older than the hook,
# and for dispatches it did not see. dispatch_hook and tool_use_ids are
# optional; without them this is the spec §2.6 function unchanged.
# ---------------------------------------------------------------------------
sub attribute_session {
    my (%opts) = @_;
    my $doc     = $opts{doc}     // {};
    my $records = $opts{records} // [];
    my $index   = $opts{index}   // {};
    my $hook    = $opts{dispatch_hook} // {};
    my $tuids   = $opts{tool_use_ids}  // [];

    my @agents = @{ $doc->{agents} // [] };
    my @attrs;

    for my $i (0 .. $#agents) {
        my $agent = $agents[$i];
        if ($i == 0) {
            push @attrs, {
                path => $agent->{path}, role => $agent->{role}, kind => 'driver',
                blueprint => $DRIVER_LABEL, package => $DRIVER_LABEL,
                reason => undef, source => 'driver',
            };
            next;
        }

        # Package 02 spec Sec2.6 -- an agent with a window and ZERO in-window
        # requests is emitted here, BEFORE any other rule (including the
        # dispatch-hook exact match), as unattributed/outside-window. The
        # description-heuristic second pass below explicitly skips this
        # reason, so it can never be promoted to attributed.
        if (defined($agent->{in_window_requests}) && $agent->{in_window_requests} == 0) {
            push @attrs, {
                path => $agent->{path}, role => $agent->{role}, kind => 'unattributed',
                blueprint => $UNATTRIBUTED_LABEL, package => $UNATTRIBUTED_LABEL,
                reason => 'outside-window', source => 'none',
            };
            next;
        }

        my $role = $agent->{role};

        my $tuid = $tuids->[$i];
        my $hk   = defined($tuid) ? $hook->{$tuid} : undef;
        if ($hk && !$hk->{conflict}) {
            push @attrs, {
                path => $agent->{path}, role => $role, kind => 'attributed',
                blueprint => $hk->{blueprint}, package => $hk->{package},
                reason => undef, source => 'dispatch-hook',
            };
            next;
        }
        if (defined $role && $role eq 'unknown-agent') {
            push @attrs, {
                path => $agent->{path}, role => $role, kind => 'unattributed',
                blueprint => $UNATTRIBUTED_LABEL, package => $UNATTRIBUTED_LABEL,
                reason => 'unknown-agent', source => 'none',
            };
            next;
        }

        (my $wt = defined $role ? $role : '') =~ s/\A[^:]*://;
        my $t0 = $agent->{first_ts};
        my @candidates = grep { defined($_->{worker_type}) && $_->{worker_type} eq $wt } @$records;
        my @matches;
        if (defined $t0) {
            for my $r (@candidates) {
                my $end = defined($r->{ended_at}) ? $r->{ended_at} : $r->{started_at} + 4 * $r->{budget};
                push @matches, $r if ($r->{started_at} - $ATTRIBUTION_LEAD_SECONDS) <= $t0 && $t0 <= $end;
            }
        }

        if (@matches == 1) {
            my ($bp, $pkg, $src) = _resolve_bp_pkg($matches[0], $index);
            if (defined $bp && defined $pkg) {
                push @attrs, {
                    path => $agent->{path}, role => $role, kind => 'attributed',
                    blueprint => $bp, package => $pkg, reason => undef, source => $src,
                };
            }
            else {
                push @attrs, {
                    path => $agent->{path}, role => $role, kind => 'unattributed',
                    blueprint => $UNATTRIBUTED_LABEL, package => $UNATTRIBUTED_LABEL,
                    reason => 'id-unresolved', source => 'none',
                };
            }
        }
        elsif (@matches >= 2) {
            push @attrs, {
                path => $agent->{path}, role => $role, kind => 'unattributed',
                blueprint => $UNATTRIBUTED_LABEL, package => $UNATTRIBUTED_LABEL,
                reason => 'ambiguous', source => 'none',
            };
        }
        else {
            my $reason = @candidates ? 'outside-window' : 'no-dispatch-record';
            push @attrs, {
                path => $agent->{path}, role => $role, kind => 'unattributed',
                blueprint => $UNATTRIBUTED_LABEL, package => $UNATTRIBUTED_LABEL,
                reason => $reason, source => 'none',
            };
        }
    }

    # Description heuristic, second pass (B4). S is computed once from the
    # primary pass ONLY -- heuristic successes never enlarge it.
    my %S;
    for my $a (@attrs) {
        $S{ $a->{blueprint} } = 1
            if $a->{kind} eq 'attributed'
            && ($a->{source} eq 'record-fields' || $a->{source} eq 'record-id' || $a->{source} eq 'dispatch-hook');
    }
    if (%S) {
        for my $i (0 .. $#attrs) {
            next unless $attrs[$i]{kind} eq 'unattributed';
            # Package 02 spec Sec2.6 -- the heuristic never promotes an
            # outside-window agent (its zero in-window requests contribute
            # no tokens either way, so a description match would be noise).
            next if defined($attrs[$i]{reason}) && $attrs[$i]{reason} eq 'outside-window';
            my $desc = $agents[$i]{description};
            next unless defined $desc && !ref($desc);
            next unless $desc =~ /\b(?:package|pkg)\s+(\d{1,3})\b/i;
            my $n = $1 + 0;
            my @found;
            for my $bp_name (keys %S) {
                my $bucket = $index->{$bp_name} && $index->{$bp_name}{packages}{$n};
                next unless $bucket;
                push @found, [$bp_name, $_] for @$bucket;
            }
            next unless @found == 1;
            $attrs[$i] = {
                path => $attrs[$i]{path}, role => $attrs[$i]{role}, kind => 'attributed',
                blueprint => $found[0][0], package => $found[0][1],
                reason => undef, source => 'description-heuristic',
            };
        }
    }

    return \@attrs;
}

# ---------------------------------------------------------------------------
# _valid_by_list(\@dims) -> 1|0. Shared predicate for --by validation, used
# by both report_session (below) and the CLI's own --by parsing, so the two
# call sites can never drift on what counts as a valid dimension list.
# PRIVATE.
# ---------------------------------------------------------------------------
sub _valid_by_list {
    my ($dims) = @_;
    return 0 unless ref($dims) eq 'ARRAY';
    return 0 unless @$dims >= 1 && @$dims <= scalar(@REPORT_DIMENSIONS);
    my %valid = map { $_ => 1 } @REPORT_DIMENSIONS;
    my %seen;
    for my $d (@$dims) { return 0 if !$valid{$d} || $seen{$d}++ }
    return 1;
}

# ---------------------------------------------------------------------------
# report_session(session => PATH, data_root => DIR|undef, by => \@dims|undef)
# -> \%report_doc. Spec §2.7. The ONLY source of tokens/costs is
# derive_session(); this aggregates agents[].cells and nothing else.
# ---------------------------------------------------------------------------
sub report_session {
    my (%opts) = @_;
    my $pricing = $opts{pricing} // BpPricing::offline();
    my $pricing_not_ok = $pricing->{status} ne 'ok';

    my $by = $opts{by};
    $by = [@REPORT_DEFAULT_BY] unless defined $by;
    die "report_session: invalid --by dimension list\n" unless _valid_by_list($by);
    my $type_in_by = grep { $_ eq 'token_type' } @$by;
    # Package 02 spec Sec2.1 -- by_hour passed to derive_session iff 'hour'
    # is in --by.
    my $hour_in_by = grep { $_ eq 'hour' } @$by;

    my $doc = derive_session(
        session => $opts{session}, pricing => $pricing,
        (defined($opts{window}) ? (window => $opts{window}) : ()),
        by_hour => $hour_in_by ? 1 : 0,
    );

    my ($data_root, $data_root_source) = resolve_data_root($opts{data_root}, $opts{session});
    my $records   = load_dispatch_records($data_root);
    my $index     = blueprint_index($data_root);
    my @agents    = @{ $doc->{agents} };
    my @tuids     = map { $_ == 0 ? undef : _session_agent_tool_use_id($agents[$_]{path}) } 0 .. $#agents;
    my $attrs     = attribute_session(
        doc => $doc, records => $records, index => $index,
        dispatch_hook => load_dispatch_attribution($data_root), tool_use_ids => \@tuids,
    );

    my %rows;
    for my $i (0 .. $#agents) {
        my $agent = $agents[$i];
        my $attr  = $attrs->[$i];
        for my $c (@{ $agent->{cells} }) {
            next unless $c->{tokens} > 0;
            my %dimval = (
                role => $c->{role}, model => $c->{model}, effort => $c->{effort},
                token_type => $c->{token_type}, blueprint => $attr->{blueprint}, package => $attr->{package},
                hour => $c->{hour},
            );
            my @vals = map { $dimval{$_} } @$by;
            my $key = join("\x1f", @vals);
            my $row = $rows{$key};
            unless ($row) {
                $row = {};
                for my $idx (0 .. $#$by) { $row->{ $by->[$idx] } = $vals[$idx]; }
                $row->{tokens} = 0; $row->{cost_usd} = 0; $row->{unpriced_tokens} = 0;
                $row->{reasons} = {};
                $row->{by_type} = { map { $_ => 0 } @REPORT_TOKEN_TYPES };
                $rows{$key} = $row;
            }
            $row->{tokens}          += $c->{tokens};
            $row->{cost_usd}        += ($c->{api_equivalent_cost_usd} // 0);
            $row->{unpriced_tokens} += $c->{unpriced_tokens};
            $row->{by_type}{ $c->{token_type} } += $c->{tokens};
            for my $r (@{ $c->{unpriced_reasons} }) { $row->{reasons}{ $r->{reason} } += $r->{tokens}; }
        }
    }

    my @rows = values %rows;
    for my $row (@rows) {
        my $by_type = delete $row->{by_type};
        unless ($type_in_by) {
            $row->{input_tokens}              = $by_type->{input};
            $row->{cache_write_5m_tokens}     = $by_type->{cache_write_5m};
            $row->{cache_write_1h_tokens}     = $by_type->{cache_write_1h};
            $row->{cache_write_unsplit_tokens} = $by_type->{cache_write_unsplit};
            $row->{cache_read_tokens}         = $by_type->{cache_read};
            $row->{output_tokens}             = $by_type->{output};
        }
        my $fully_unpriced = $pricing_not_ok || ($row->{tokens} > 0 && $row->{unpriced_tokens} == $row->{tokens});
        $row->{tokens}                  = int($row->{tokens});
        $row->{unpriced_tokens}         = int($row->{unpriced_tokens});
        $row->{api_equivalent_cost_usd} = $fully_unpriced ? undef : 0 + sprintf('%.6f', $row->{cost_usd});
        $row->{unpriced_reasons}        = _session_unpriced_reasons_array(delete $row->{reasons});
        delete $row->{cost_usd};
    }
    @rows = sort {
        my $cmp = 0;
        for my $d (@$by) {
            $cmp = $a->{$d} cmp $b->{$d};
            last if $cmp;
        }
        $cmp;
    } @rows;

    my %driver       = map { $_ => 0 } @REPORT_TOKEN_TYPES;
    my %attributed   = map { $_ => 0 } @REPORT_TOKEN_TYPES;
    my %unattributed = map { $_ => 0 } @REPORT_TOKEN_TYPES;
    my %reasons;
    for my $reason (@ATTRIBUTION_REASONS) {
        $reasons{$reason} = { map { $_ => 0 } @REPORT_TOKEN_TYPES };
    }

    for my $i (0 .. $#agents) {
        my $agent = $agents[$i];
        my $attr  = $attrs->[$i];
        for my $c (@{ $agent->{cells} }) {
            next unless $c->{tokens} > 0;
            my $t   = $c->{token_type};
            my $tok = $c->{tokens};
            if ($attr->{kind} eq 'driver')          { $driver{$t}     += $tok; }
            elsif ($attr->{kind} eq 'attributed')   { $attributed{$t} += $tok; }
            else {
                $unattributed{$t} += $tok;
                $reasons{ $attr->{reason} }{$t} += $tok;
            }
        }
    }

    return {
        cost_basis        => 'fetched',
        price_source      => $pricing->{source},
        price_fetched_at  => $pricing->{fetched_at},
        pricing_status    => BpPricing::status_string($pricing),
        ($pricing->{price_fetch_override} ? (price_fetch_override => JSON::PP::true) : ()),
        by           => [@$by],
        data_root    => $data_root,
        data_root_source => $data_root_source,
        rows         => \@rows,
        totals       => $doc->{totals},
        attribution  => {
            driver       => \%driver,
            attributed   => \%attributed,
            unattributed => \%unattributed,
            reasons      => \%reasons,
            agents       => $attrs,
        },
        # Package 02 spec Sec2.7 -- copied from the derive doc, present ONLY
        # when a window was given.
        ($doc->{window} ? (window => $doc->{window}) : ()),
    };
}

# ---------------------------------------------------------------------------
# write_derived(%opts) -> writes the spend-derived.json shape (spec §4)
# atomically (temp file in the same directory + rename()), mirroring
# BpSpend::write_snapshot's pattern without calling it -- the two files'
# shapes are unrelated and this must never touch spend.json (AC8).
#   opts: path => PATH, doc => \%hashref (already shaped -- see CLI below)
# ---------------------------------------------------------------------------
sub write_derived {
    my (%opts) = @_;
    my $path = $opts{path};
    my $doc  = $opts{doc};

    die "write_derived: path is required\n" unless defined $path && length $path;

    my $json = JSON::PP->new->canonical->encode($doc);

    (my $dir = $path) =~ s{[/\\][^/\\]+$}{};
    $dir = '.' unless length $dir;
    if (length $dir && !-d $dir) { require File::Path; File::Path::make_path($dir); }

    my $tmp_path = "$path.tmp.$$." . int(rand(1_000_000));
    sysopen(my $fh, $tmp_path, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_TRUNC(), 0600)
        or die "write_derived: sysopen $tmp_path: $!";
    print {$fh} $json or die "write_derived: write $tmp_path: $!";
    close $fh or die "write_derived: close $tmp_path: $!";

    rename($tmp_path, $path) or die "write_derived: rename $tmp_path -> $path: $!";
    return $path;
}

package main;

# Same allow-list bp-blueprint.pl enforces on --pkg before using it to build a
# path ($PKG_ID_RE there, bp-blueprint.pl:73) -- reused here rather than
# re-derived, so the two files' notion of "a valid package id" cannot drift
# apart. Applied below (fix-batch M1) before --pkg is used to build
# $jsonl_path: an unsanitized value could otherwise traverse (`../`) outside
# the intended blueprint's runs/ directory and pull another blueprint's
# transcript into this one's derived figure.
my $PKG_ID_RE = qr/^[A-Za-z0-9][A-Za-z0-9_.-]*$/;

# ===========================================================================
# CLI (b47). THIS BLOCK'S ABSENCE WAS THE DEFECT.
#
# bp-spend.pl previously ended `package main; 1;` with no `unless (caller)`
# block, so nothing outside a `require` could ever invoke it. Combined with
# write_snapshot having no production caller, the Spend panel could never
# render on any real fleet -- and the reader's `-f` guard plus its swallowing
# `eval` made that permanent breakage look exactly like "no data yet".
#
#   bp-spend.pl snapshot [--run-dir DIR] [--global-dir DIR] [--offline] [--now EPOCH]
#
# Writes <DIR>/spend.json for each DIR given -- launcher.pl's _gather_spend reads
# the global copy.
# Exit 0 wrote (or served a still-fresh snapshot) - 2 usage - 4 I/O.
#
# CADENCE ACROSS PROCESSES. A CLI that exits keeps no cache, so this derives
# the floor from the EXISTING snapshot's mtime. That makes the verb safe to call on any tick: inside
# $CADENCE_TTL_SECONDS it is a stat plus a read and makes no network call at
# all. Without this, wiring it to a frequent loop would poll the usage endpoint
# on every tick.
#
# --offline performs no fetch and records claude as `absent`. It exists
# so the write path can be exercised deterministically (no credentials, no
# network) -- the check that would have caught the original defect.
# ===========================================================================
unless (caller) {
    my $verb = shift(@ARGV) // '';
    my %opt;
    while (@ARGV) {
        my $a = shift @ARGV;
        if    ($a =~ /^--run-dir=(.*)$/)    { $opt{run_dir}    = $1 }
        elsif ($a eq '--run-dir')           { $opt{run_dir}    = shift @ARGV }
        elsif ($a =~ /^--global-dir=(.*)$/) { $opt{global_dir} = $1 }
        elsif ($a eq '--global-dir')        { $opt{global_dir} = shift @ARGV }
        elsif ($a =~ /^--now=(.*)$/)        { $opt{now}        = $1 }
        elsif ($a eq '--now')               { $opt{now}        = shift @ARGV }
        elsif ($a =~ /^--gate-cmd=(.*)$/)   { $opt{gate_cmd}   = $1 }
        elsif ($a eq '--gate-cmd')          { $opt{gate_cmd}   = shift @ARGV }
        elsif ($a =~ /^--pkg=(.*)$/)        { $opt{pkg}        = $1 }
        elsif ($a eq '--pkg')               { $opt{pkg}        = shift @ARGV }
        elsif ($a eq '--offline')           { $opt{offline}    = 1 }
        elsif ($a eq '--force')             { $opt{force}      = 1 }
        elsif ($a =~ /^--session=(.*)$/)    { $opt{session}    = $1 }
        elsif ($a eq '--session')           { $opt{session}    = shift @ARGV }
        elsif ($a eq '--json')              { $opt{json}       = 1 }
        elsif ($a =~ /^--data-root=(.*)$/)  { $opt{data_root}  = $1 }
        elsif ($a eq '--data-root')         { $opt{data_root}  = shift @ARGV }
        elsif ($a =~ /^--by=(.*)$/)         { $opt{by}         = $1 }
        elsif ($a eq '--by')                { $opt{by}         = shift @ARGV }
        elsif ($a =~ /^--since=(.*)$/)      { $opt{since}      = $1 }
        elsif ($a eq '--since')             { $opt{since}      = shift @ARGV }
        elsif ($a =~ /^--until=(.*)$/)      { $opt{until}      = $1 }
        elsif ($a eq '--until')             { $opt{until}      = shift @ARGV }
        else { print STDERR "bp-spend: unrecognised argument '$a'\n"; exit 2 }
    }

    # --session/--json/--data-root/--by living in the shared option loop
    # above means a verb that never asked for them (snapshot, derive-package,
    # derive-blueprint) now parses them instead of hitting the old
    # unrecognised-argument hard error (fix-batch redteam M3) -- restore that
    # safety net explicitly for every verb that does not ask for a given flag.
    my %SESSION_VERBS = (('derive-session') => 1, ('report-session') => 1);
    if (!$SESSION_VERBS{$verb} && (exists $opt{session} || $opt{json})) {
        print STDERR "bp-spend: --session/--json only apply to derive-session or report-session\n";
        exit 2;
    }
    if ($verb ne 'report-session' && (exists $opt{data_root} || exists $opt{by})) {
        print STDERR "bp-spend: --data-root/--by only apply to report-session\n";
        exit 2;
    }
    # Package 02 spec Sec2.7's last error text -- sits beside the two guards
    # above, before any verb-specific handling (so a fleet verb given a
    # window flag never reaches BpPricing::acquire).
    if (!$SESSION_VERBS{$verb} && (exists $opt{since} || exists $opt{until})) {
        print STDERR "bp-spend: --since/--until only apply to derive-session or report-session\n";
        exit 2;
    }

    # ---------------------------------------------------------------------
    # Package 02 spec Sec2.7 -- for the session verbs, the verb's own
    # required/shape checks (--session for both; --data-root/--by for
    # report-session only) run BEFORE --now/--since/--until validation, so
    # e.g. `report-session --since yesterday` with no --session prints the
    # "requires --session" error rather than a window-parse error.
    # ---------------------------------------------------------------------
    my @by_dims;
    if ($SESSION_VERBS{$verb}) {
        unless (defined $opt{session} && length $opt{session}) {
            print STDERR "bp-spend: $verb requires --session PATH\n";
            exit 2;
        }
        if ($verb eq 'report-session') {
            if (exists $opt{data_root} && !(defined $opt{data_root} && length $opt{data_root})) {
                print STDERR "bp-spend: --data-root requires a directory\n";
                exit 2;
            }
            if (exists $opt{by}) {
                unless (defined $opt{by}) {
                    print STDERR "bp-spend: --by requires a dimension list\n";
                    exit 2;
                }
                @by_dims = split(/,/, $opt{by}, -1);
                unless (BpSpend::Derive::_valid_by_list(\@by_dims)) {
                    print STDERR "bp-spend: --by '$opt{by}' is not a valid dimension list (allowed: "
                        . join(',', @BpSpend::Derive::REPORT_DIMENSIONS) . "; each at most once)\n";
                    exit 2;
                }
            }
        }
    }

    # ---------------------------------------------------------------------
    # --now/--since/--until validation for the session verbs, IN THIS
    # ORDER, all before BpPricing::acquire is ever called, so an
    # invalid/inverted window never fetches (TW11/DF-parity).
    # $opt{_now_epoch}/{_since_epoch}/{_until_epoch} feed derive_session/
    # report_session below; $opt{_window_given} tracks whether either flag
    # was actually passed (a window is "given" iff at least one bound was).
    # ---------------------------------------------------------------------
    if ($SESSION_VERBS{$verb}) {
        my $now_epoch;
        if (exists $opt{now}) {
            my $raw = defined($opt{now}) ? $opt{now} : '';
            if ($raw =~ /\A\d+\z/) { $now_epoch = $raw + 0; }
            else {
                print STDERR "bp-spend: --now '$raw' is not a whole-second epoch\n";
                exit 2;
            }
        }
        else { $now_epoch = time; }
        $opt{_now_epoch} = $now_epoch;

        my ($since_epoch, $until_epoch, $window_given) = (undef, undef, 0);
        if (exists $opt{since}) {
            my $raw = defined($opt{since}) ? $opt{since} : '';
            $since_epoch = BpSpend::Derive::_window_parse_bound($raw, $now_epoch);
            unless (defined $since_epoch) {
                print STDERR "bp-spend: --since '$raw' is not a valid time (use YYYY-MM-DDTHH:MM[:SS]Z in UTC, or Nh, Nm or Nd)\n";
                exit 2;
            }
            $window_given = 1;
        }
        if (exists $opt{until}) {
            my $raw = defined($opt{until}) ? $opt{until} : '';
            $until_epoch = BpSpend::Derive::_window_parse_bound($raw, $now_epoch);
            unless (defined $until_epoch) {
                print STDERR "bp-spend: --until '$raw' is not a valid time (use YYYY-MM-DDTHH:MM[:SS]Z in UTC, or Nh, Nm or Nd)\n";
                exit 2;
            }
            $window_given = 1;
        }
        if (defined($since_epoch) && defined($until_epoch) && $since_epoch >= $until_epoch) {
            print STDERR "bp-spend: empty or inverted window: --since "
                . BpSpend::Derive::_session_iso_epoch($since_epoch) . " is not before --until "
                . BpSpend::Derive::_session_iso_epoch($until_epoch) . "\n";
            exit 2;
        }
        $opt{_since_epoch}  = $since_epoch;
        $opt{_until_epoch}  = $until_epoch;
        $opt{_window_given} = $window_given;
    }

    # ---------------------------------------------------------------------
    # derive-package / derive-blueprint (blueprint fleet-cost-accounting,
    # package 01-spend-is-recorded). No external provider, no network, no
    # credential -- reads runs/<pkg>.jsonl directly. See spec §2.6.
    # ---------------------------------------------------------------------
    if ($verb eq 'derive-package' || $verb eq 'derive-blueprint') {
        my $run_dir = $opt{run_dir};
        unless (defined $run_dir && length $run_dir) {
            print STDERR "bp-spend: $verb requires --run-dir DIR\n";
            exit 2;
        }
        if ($verb eq 'derive-package' && !(defined $opt{pkg} && length $opt{pkg})) {
            print STDERR "bp-spend: derive-package requires --pkg PKG\n";
            exit 2;
        }
        # M1 (fix-batch): reject a --pkg that cannot form a bare filename
        # component BEFORE it is used to build $jsonl_path below -- an
        # unvalidated value (e.g. containing `../`) could otherwise read a
        # transcript outside this blueprint's own runs/ directory, silently
        # contaminating the derived figure with another blueprint's spend.
        if ($verb eq 'derive-package' && $opt{pkg} !~ $PKG_ID_RE) {
            print STDERR "bp-spend: --pkg '$opt{pkg}' is not a valid package id (must match $PKG_ID_RE)\n";
            exit 2;
        }

        my $now      = defined $opt{now} && $opt{now} =~ /^\d+$/ ? $opt{now} + 0 : time;
        my $runs_dir = "$run_dir/runs";
        my $out_path = "$runs_dir/spend-derived.json";

        # A specifically-requested missing package is a CALLER ERROR (spec
        # §2.6): exit 4, write nothing, NEVER FETCH -- an existing
        # spend-derived.json from a prior successful call is untouched. This
        # check runs BEFORE BpPricing::acquire (spec 02 Sec2.3 step order).
        if ($verb eq 'derive-package') {
            my $jsonl_path = "$runs_dir/$opt{pkg}.jsonl";
            unless (-f $jsonl_path) {
                print STDERR "bp-spend: no such file $jsonl_path\n";
                exit 4;
            }
        }

        # Package 02 spec Sec2.3 step 3 -- the ONLY acquisition for either
        # verb, exactly once per invocation (including a derive-blueprint
        # over zero or many packages). --offline means Decision 16's offline
        # rung; these verbs print no cost.
        my $pricing = BpPricing::acquire(offline => $opt{offline} ? 1 : 0);

        my $bp_result;
        if ($verb eq 'derive-package') {
            $bp_result = BpSpend::Derive::derive_blueprint(
                runs_dir => $runs_dir, pkgs => [ $opt{pkg} ], pricing => $pricing,
            );
        }
        else {
            $bp_result = BpSpend::Derive::derive_blueprint(runs_dir => $runs_dir, pricing => $pricing);
        }

        my $doc = {
            generated_at            => BpLog::_iso_now($now),
            derived                 => 1,
            tokens                  => $bp_result->{tokens},
            by_model                => $bp_result->{by_model},
            anomaly                 => $bp_result->{anomaly},
            packages                => $bp_result->{packages},
            price_source            => $bp_result->{price_source},
            price_fetched_at        => $bp_result->{price_fetched_at},
            pricing_status          => $bp_result->{pricing_status},
            api_equivalent_cost_usd => $bp_result->{api_equivalent_cost_usd},
            unpriced_tokens         => $bp_result->{unpriced_tokens},
            unpriced_reasons        => $bp_result->{unpriced_reasons},
            ($bp_result->{price_fetch_override} ? (price_fetch_override => $bp_result->{price_fetch_override}) : ()),
        };

        eval { BpSpend::Derive::write_derived(path => $out_path, doc => $doc) };
        if ($@) {
            print STDERR "bp-spend: could not write $out_path: $@";
            exit 4;
        }
        print "$out_path\n";
        exit 0;
    }

    # ---------------------------------------------------------------------
    # derive-session (blueprint usage-telemetry, package
    # 01-drive-solo-input-and-pricing). Read-only: never calls write_derived,
    # prints to stdout only. See spec §2.6.
    # ---------------------------------------------------------------------
    if ($verb eq 'derive-session') {
        # --session presence is already validated above, before the
        # --now/--since/--until window checks (spec Sec2.7 ordering).

        my $pricing = BpPricing::acquire(offline => $opt{offline} ? 1 : 0);
        my $doc = eval {
            BpSpend::Derive::derive_session(
                session => $opt{session}, pricing => $pricing,
                ($opt{_window_given} ? (window => { since => $opt{_since_epoch}, until => $opt{_until_epoch} }) : ()),
            );
        };
        if ($@) {
            my $err = $@;
            # Match on the die message's CONTENT, not merely "any die happened"
            # (fix-batch redteam L6/review L4) -- necessary now that an
            # unopenable main transcript (M4 above) is a second possible die
            # path here, and an unrelated internal failure must not be
            # misreported as a missing-transcript edge case.
            if ($err =~ /^derive_session: no such/) {
                print STDERR "bp-spend: no such session transcript: "
                    . BpSpend::Derive::_session_truncate_for_error($opt{session}) . "\n";
                exit 4;
            }
            print STDERR "bp-spend: $err";
            exit 1;
        }

        if ($opt{json}) {
            print JSON::PP->new->canonical->utf8->encode($doc), "\n";
            exit 0;
        }

        my @type_order = qw(input output cache_write_5m cache_write_1h cache_read cache_write_unsplit);
        print "derive-session: token counts by type; API equivalent cost from Anthropic's published prices, not an actual charge\n";
        print "session: $doc->{agents}[0]{path}\n";
        print "pricing: " . BpSpend::Derive::_fmt_pricing_header($doc, $pricing->{long_context}{note}) . "\n";
        print BpSpend::Derive::_fmt_window_header($doc->{window}) . "\n" if $doc->{window};
        print "requests: $doc->{record_counts}{requests}  assistant-records: $doc->{record_counts}{assistant_records}  agents: "
            . scalar(@{ $doc->{agents} }) . "\n";
        for my $type (@type_order) {
            my $t = $doc->{totals}{$type};
            my $ct = BpSpend::Derive::_fmt_cost_cell($doc->{pricing_status}, $t->{api_equivalent_cost_usd},
                $t->{unpriced_tokens}, $t->{tokens}, $t->{unpriced_reasons});
            print "total $type: $t->{tokens} tokens, api_equivalent_cost=$ct\n";
        }
        my ($gt, $gc, $gu, $gr) = BpSpend::Derive::_totals_grand($doc->{totals});
        my $gtok = { map { $_ => $doc->{totals}{$_}{tokens} } qw(input cache_write_5m cache_write_1h cache_write_unsplit cache_read output) };
        my $gct = BpSpend::Derive::_fmt_cost_cell($doc->{pricing_status}, $gc, $gu, $gt, $gr);
        print "TOTAL: $gt tokens, " . BpSpend::Derive::_fmt_tok_segment($gtok) . ", api_equivalent_cost=$gct\n";
        print "unpriced: " . join(', ', map { "$_ $doc->{unpriced}{$_}" }
            qw(unknown-model cache-write-unsplit non-standard-speed rate-missing offline pricing-unavailable)) . "\n";
        print "anomaly consecutive-same-size-cache-write: count $doc->{anomaly}{count}, total_tokens $doc->{anomaly}{total_tokens}\n";

        # Surface the six diagnostic counters in text mode too (fix-batch
        # redteam M2) -- previously only --json exposed them, so a text-mode
        # run could silently degrade (skipped lines, malformed fields, a
        # dropped mismatch, etc.) with no visible sign at all.
        my $rc = $doc->{record_counts};
        my @warn_parts;
        push @warn_parts, "skipped-unparseable $rc->{skipped_unparseable}"     if $rc->{skipped_unparseable};
        push @warn_parts, "malformed-usage-field $rc->{malformed_usage_field}" if $rc->{malformed_usage_field};
        push @warn_parts, "request-usage-mismatch $rc->{request_usage_mismatch}" if $rc->{request_usage_mismatch};
        push @warn_parts, "unkeyed $rc->{unkeyed}"                             if $rc->{unkeyed};
        push @warn_parts, "multi-iteration $rc->{multi_iteration}"            if $rc->{multi_iteration};
        push @warn_parts, "speed-absent $rc->{speed_absent}"                  if $rc->{speed_absent};
        print "warnings: " . join(', ', @warn_parts) . "\n" if @warn_parts;

        exit 0;
    }

    # ---------------------------------------------------------------------
    # report-session (blueprint usage-telemetry, package
    # 02-attribution-and-report). Read-only: never calls write_derived,
    # prints to stdout only. See spec §2.7-2.8.
    # ---------------------------------------------------------------------
    if ($verb eq 'report-session') {
        # --session/--data-root/--by are already validated above (into
        # @by_dims), before the --now/--since/--until window checks (spec
        # Sec2.7 ordering).

        my $pricing = BpPricing::acquire(offline => $opt{offline} ? 1 : 0);
        my $doc = eval {
            BpSpend::Derive::report_session(
                session   => $opt{session},
                data_root => $opt{data_root},
                pricing   => $pricing,
                (@by_dims ? (by => \@by_dims) : ()),
                ($opt{_window_given} ? (window => { since => $opt{_since_epoch}, until => $opt{_until_epoch} }) : ()),
            );
        };
        if ($@) {
            my $err = $@;
            if ($err =~ /^derive_session: no such/) {
                print STDERR "bp-spend: no such session transcript: "
                    . BpSpend::Derive::_session_truncate_for_error($opt{session}) . "\n";
                exit 4;
            }
            print STDERR "bp-spend: $err";
            exit 1;
        }

        if ($opt{json}) {
            # Decision 24 item 3 (review S2): $doc->{data_root} is a byte
            # string (every resolve_data_root() source is bytes, including
            # the Decision 22 boundary encode). JSON::PP's ->utf8 layer
            # expects CHARACTERS and encodes them to UTF-8 bytes -- handed
            # bytes already, it re-encodes each one as Latin-1, double-
            # encoding a non-ASCII data_root. Encode from a shallow copy with
            # data_root decoded back to characters, so ->utf8->encode emits a
            # single layer; the text branch below prints the original byte
            # string unchanged, which already displays correctly with no
            # layer on STDOUT.
            my %json_doc = %$doc;
            if (defined $json_doc{data_root}) {
                utf8::decode($json_doc{data_root});
            }
            print JSON::PP->new->canonical->utf8->encode(\%json_doc), "\n";
            exit 0;
        }

        print "report-session: token counts by type; API equivalent cost from Anthropic's published prices, not an actual charge\n";
        print "session: $doc->{attribution}{agents}[0]{path}\n";
        print "data-root: $doc->{data_root} (from $doc->{data_root_source})\n";
        print "pricing: " . BpSpend::Derive::_fmt_pricing_header($doc, $pricing->{long_context}{note}) . "\n";
        print BpSpend::Derive::_fmt_window_header($doc->{window}) . "\n" if $doc->{window};
        print "by: " . join(',', @{ $doc->{by} }) . "\n";

        my $type_in_by = grep { $_ eq 'token_type' } @{ $doc->{by} };
        for my $row (@{ $doc->{rows} }) {
            my @parts = map { "$_=$row->{$_}" } @{ $doc->{by} };
            my %tok;
            if ($type_in_by) {
                %tok = map { $_ => 0 } qw(input cache_write_5m cache_write_1h cache_write_unsplit cache_read output);
                $tok{ $row->{token_type} } = $row->{tokens};
            }
            else {
                %tok = (
                    input => $row->{input_tokens}, cache_write_5m => $row->{cache_write_5m_tokens},
                    cache_write_1h => $row->{cache_write_1h_tokens}, cache_write_unsplit => $row->{cache_write_unsplit_tokens},
                    cache_read => $row->{cache_read_tokens}, output => $row->{output_tokens},
                );
            }
            my $ct = BpSpend::Derive::_fmt_cost_cell($doc->{pricing_status}, $row->{api_equivalent_cost_usd},
                $row->{unpriced_tokens}, $row->{tokens}, $row->{unpriced_reasons});
            printf "row: %s | %s tokens, %s, api_equivalent_cost=%s\n",
                join(' ', @parts), $row->{tokens}, BpSpend::Derive::_fmt_tok_segment(\%tok), $ct;
        }
        my ($gt, $gc, $gu, $gr) = BpSpend::Derive::_totals_grand($doc->{totals});
        my $gtok = { map { $_ => $doc->{totals}{$_}{tokens} } qw(input cache_write_5m cache_write_1h cache_write_unsplit cache_read output) };
        my $gct = BpSpend::Derive::_fmt_cost_cell($doc->{pricing_status}, $gc, $gu, $gt, $gr);
        print "TOTAL: $gt tokens, " . BpSpend::Derive::_fmt_tok_segment($gtok) . ", api_equivalent_cost=$gct\n";

        my $sum_types = sub {
            my ($map) = @_;
            my $s = 0;
            $s += $map->{$_} for @BpSpend::Derive::REPORT_TOKEN_TYPES;
            return $s;
        };
        printf "attribution: driver %s tokens, attributed %s tokens, unattributed %s tokens\n",
            $sum_types->($doc->{attribution}{driver}),
            $sum_types->($doc->{attribution}{attributed}),
            $sum_types->($doc->{attribution}{unattributed});
        for my $reason (@BpSpend::Derive::ATTRIBUTION_REASONS) {
            printf "attribution-reason %s: %s tokens\n", $reason, $sum_types->($doc->{attribution}{reasons}{$reason});
        }

        exit 0;
    }

    if ($verb ne 'snapshot') {
        print STDERR "usage: bp-spend.pl snapshot [--run-dir DIR] [--global-dir DIR] [--offline]\n"
                   . "                            [--force] [--now EPOCH]\n"
                   . "       bp-spend.pl derive-package --run-dir DIR --pkg PKG [--offline] [--now EPOCH]\n"
                   . "       bp-spend.pl derive-blueprint --run-dir DIR [--offline] [--now EPOCH]\n"
                   . "       bp-spend.pl derive-session --session PATH [--since T] [--until T] [--now EPOCH] [--json]\n"
                   . "       bp-spend.pl report-session --session PATH [--data-root DIR] [--by dims] [--since T] [--until T] [--now EPOCH] [--json]\n";
        exit 2;
    }

    # AT LEAST ONE DESTINATION, not specifically --run-dir. Blueprint Decision
    # 11: every figure in this snapshot -- claude's plan utilizations --
    # describes the ACCOUNT, not the run that happened
    # to poll for it. Requiring a run directory scoped an account fact to a run
    # and made it unreadable in exactly the state the operator is normally in:
    # no fleet run active. The run copy keeps being written when asked for, so
    # no existing fleet behaviour changes.
    my @dirs = grep { defined && length } ($opt{run_dir}, $opt{global_dir});
    unless (@dirs) {
        print STDERR "bp-spend: at least one of --run-dir or --global-dir is required\n";
        exit 2;
    }

    my $now   = defined $opt{now} && $opt{now} =~ /^\d+$/ ? $opt{now} + 0 : time;
    my @paths = map { "$_/spend.json" } @dirs;

    # Cross-process cadence floor -- see the header note. Evaluated across
    # EVERY destination, not just one: with two paths, a floor that only
    # consulted the run copy would fetch on every call whenever the global copy
    # was the stale one, which is the opposite of what a floor is for.
    my $fresh_path;
    if (!$opt{force}) {
        for my $p (@paths) {
            next unless -f $p;
            my $fresh = eval {
                open my $fh, '<:raw', $p or die "read\n";
                my $raw = do { local $/; <$fh> };
                close $fh;
                my $prev = JSON::PP->new->decode($raw);
                die "shape\n" unless ref $prev eq 'HASH';
                # generated_at is ISO; compare via mtime, which is what we control.
                my @st = stat($p);
                (@st && ($now - $st[9]) < $BpSpend::CADENCE_TTL_SECONDS) ? 1 : 0;
            };
            if ($fresh) { $fresh_path = $p; last }
        }
    }

    my @results;
    my $reused = 0;
    if (defined $fresh_path) {
        # SERVE THE FRESH CONTENT TO EVERY DESTINATION rather than exiting
        # here. A cadence floor exists to suppress a FETCH; letting it also
        # suppress the WRITE would mean a destination that does not yet exist
        # never appears, and the panel stays empty for as long as some other
        # copy keeps being refreshed -- a floor turned into a permanent
        # absence. So: no network call, but the file still lands.
        $reused = 1;
        my $prev = eval {
            open my $fh, '<:raw', $fresh_path or die "read\n";
            my $raw = do { local $/; <$fh> };
            close $fh;
            JSON::PP->new->decode($raw);
        };
        # Only claude rows are carried forward. A snapshot written before the
        # OpenCode providers were removed may still hold go/zen rows, and
        # copying it to a new destination would keep them alive for no reader.
        @results = grep { ref($_) eq 'HASH' && ($_->{provider} // '') eq 'claude' }
                   ((ref($prev) eq 'HASH' && ref($prev->{results}) eq 'ARRAY')
                    ? @{ $prev->{results} } : ());
    }
    elsif ($opt{offline}) {
        # --offline spawns nothing and records claude as absent (blueprint
        # Decision 12: claude is always present in the snapshot, so the panel's
        # "no snapshot" means no file, never a missing provider).
        @results = ({ provider => 'claude', status => 'absent' });
    }
    else {
        push @results, _fetch_claude($opt{gate_cmd});
    }

    my @written;
    for my $path (@paths) {
        # Already fresh AND already present -- nothing to do for this one.
        next if $reused && -f $path;
        my $w = eval { BpSpend::write_snapshot(path => $path, results => \@results, now => $now) };
        if ($@ || !defined $w) {
            print STDERR "bp-spend: could not write $path: " . ($@ || "unknown error\n");
            exit 4;
        }
        push @written, $w;
    }
    push @written, $fresh_path if $reused && !@written;

    print "$_\n" for @written;
    exit 0;
}

# _fetch_claude($gate_cmd) -> a claude result hash. Runs bp-usage-gate.pl (or
# an injected substitute) and hands its output to the pure mapper.
#
# --gate-cmd EXISTS FOR THE TEST SUITE AND FOR NOTHING ELSE IN PRODUCTION. It
# is the seam that makes the credential path exercisable without owning
# credentials and without reaching api.anthropic.com -- a test that polled the
# operator's real account on every run would be both non-deterministic and
# rude. The default is the real script, resolved next to this one.
sub _fetch_claude {
    my ($gate_cmd) = @_;

    my $cmd = (defined $gate_cmd && length $gate_cmd)
            ? $gate_cmd
            : do { my $d = $0; $d =~ s{[/\\][^/\\]+$}{}; $d = '.' unless length $d;
                   qq("$^X" "$d/bp-usage-gate.pl") };

    my $out = eval {
        local $SIG{__WARN__} = sub {};
        `$cmd 2>&1`;
    };
    # A gate that cannot be RUN at all is still `unknown`, never `absent`: the
    # distinction is about the provider, not about our ability to ask.
    return BpSpend::claude_from_gate(defined $out ? $out : '', defined $out ? ($? >> 8) : -1);
}

1;
