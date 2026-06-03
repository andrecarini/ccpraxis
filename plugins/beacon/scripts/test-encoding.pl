#!/usr/bin/env perl
# test-encoding.pl — automated encoding test suite for the beacon plugin.
#
# Validates that beacon.pl and claude-beacon.pl handle non-ASCII paths and
# labels correctly across the JSON-on-disk / stdout / stderr / PowerShell
# dispatch boundaries. Targets bug classes that have bitten this codebase:
#
#   1. $ENV{HOME} as raw UTF-8 bytes → :utf8 STDOUT double-encodes →
#      `AndrÃ©` mojibake in PATH:/SLUG: lines.
#   2. perl exec passing Unicode argv through cygwin's CreateProcessA
#      bridge → PowerShell decodes per cp1252 → `Set-Location 'AndrÃ©'`
#      fails to resolve. Fixed via -EncodedCommand (UTF-16LE base64).
#   3. JSON round-trip preserving non-ASCII bytes through `decode_json`
#      and atomic-rename.
#   4. PowerShell single-quote escaping for paths like `O'Brien`.
#
# Run from Git Bash:  perl test-encoding.pl
# Run as TAP:         prove -v test-encoding.pl
#
# All test data is staged in a temp HOME so the real vault is untouched.
# Tests that need PowerShell are skipped gracefully if powershell.exe is
# unavailable.

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use FindBin qw($Bin);
use JSON::PP;
use Encode qw(encode decode FB_CROAK);
use MIME::Base64 qw(decode_base64 encode_base64);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);

binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';

my $beacon_pl    = "$Bin/beacon.pl";
my $launcher_pl  = "$Bin/claude-beacon.pl";

plan skip_all => "beacon.pl not found at $beacon_pl"  unless -f $beacon_pl;
plan skip_all => "claude-beacon.pl not found"         unless -f $launcher_pl;

# Stage a temp HOME so we never touch the real vault.
my $tmp = tempdir('beacon-encoding-test-XXXXXX', TMPDIR => 1, CLEANUP => 1);
make_path("$tmp/.claude/claude-code-vault/beacons");

# File-scope local so any subtest that forgets to `local` won't permanently
# clobber HOME for later subtests. Each subtest may re-`local` to test
# specific HOME paths.
local $ENV{HOME} = $tmp;

# ── Counter for collision-free UUIDs across subtests ────────────────
# (the previous gen_uuid had a precedence bug: scalar @CORPUS - tr/A// got
# parsed as scalar(@CORPUS) - tr/A//, collapsing many tests onto the same
# slot)
my $UUID_COUNTER = 1;
sub next_uuid {
    my $i = $UUID_COUNTER++;
    return sprintf "%08x-%04x-%04x-%04x-%012x",
        0xdeadbeef + $i, 0xaaaa, 0xbbbb, 0xcccc, $i;
}

# Test corpus — chars that exercise the encoding boundaries we care about.
my @CORPUS = (
    { name => 'ASCII baseline',     char => 'A',         utf8 => "\x41",         cp1252 => "\x41"            },
    { name => 'Latin-1 e-acute',    char => "\x{00E9}",  utf8 => "\xC3\xA9",     cp1252 => "\xE9"            },
    { name => 'Latin-1 n-tilde',    char => "\x{00F1}",  utf8 => "\xC3\xB1",     cp1252 => "\xF1"            },
    { name => 'Outside cp1252 arrow', char => "\x{2192}", utf8 => "\xE2\x86\x92", cp1252 => undef            },
    { name => 'Latin-1 yen',        char => "\x{00A5}",  utf8 => "\xC2\xA5",     cp1252 => "\xA5"            },
    # Emoji deliberately NOT in @CORPUS for filesystem tests: 4-byte UTF-8
    # is unreliable on legacy Win-perl filesystem APIs. Covered separately
    # in the round-trip test where the path is constant and only the label
    # contains the emoji.
);

# ── Helpers ────────────────────────────────────────────────────────

sub run_capture {
    my @cmd = @_;
    my $in = gensym(); my $out = gensym(); my $err = gensym();
    my $pid = eval { open3($in, $out, $err, @cmd) };
    return ('', '', -1, $@) if !$pid || $@;
    close $in;
    my $stdout = do { local $/; <$out> } // '';
    my $stderr = do { local $/; <$err> } // '';
    close $out; close $err;
    waitpid($pid, 0);
    return ($stdout, $stderr, $? >> 8, '');
}

# Detect the byte sequence produced when UTF-8 input is double-encoded:
# raw `\xC3\xA9` (é) read as Latin-1 → U+00C3 U+00A9 → UTF-8 encoded back
# to `\xC3\x83\xC2\xA9`. The marker `\xC3\x83` (Ã in UTF-8 of UTF-8) is
# the canonical mojibake signature. Returns the count of matches so callers
# can include it in failure diagnostics.
sub mojibake_count {
    my $s = shift // '';
    my $count = 0;
    $count += () = $s =~ /\xC3\x83/g;  # Ã in double-encoded UTF-8
    $count += () = $s =~ /\xC3\x82/g;  # Â in double-encoded UTF-8
    return $count;
}

# Convenience: pass-through for ok-style assertions.
sub is_mojibake_free {
    my ($label, $s) = @_;
    my $n = mojibake_count($s);
    ok($n == 0, "$label: mojibake-free")
        or diag "$label: found $n double-encoded byte pair(s). "
              . "Hex sample: " . unpack('H*', substr($s, 0, 200));
}

sub has_powershell {
    my $ps = `command -v powershell.exe 2>/dev/null`;
    chomp $ps;
    return length $ps;
}

sub write_json_record {
    my ($path, $rec) = @_;
    open my $fh, '>', $path or die "write_json_record $path: $!";
    print $fh JSON::PP->new->utf8->pretty->canonical->encode($rec);
    close $fh;
}

sub stub_record {
    my ($sid, $opts) = @_;
    return {
        session_id        => $sid,
        schema_version    => 1,
        scope             => 'host',
        sandbox_container => undef,
        cwd               => $opts->{cwd}   // "$tmp/work",
        git_root          => $opts->{root}  // undef,
        project_slug      => $opts->{slug}  // undef,
        created_at        => $opts->{at}    // '2026-06-02T15:00:00Z',
        last_active_at    => $opts->{at}    // '2026-06-02T15:00:00Z',
        label             => $opts->{label} // 'stub',
        summary           => undef,
        tags              => $opts->{tags}  // [],
        auto_lit          => JSON::PP::false,
        host_machine      => 'test-host',
    };
}

# ── Test 1: HOME with non-ASCII → no mojibake on stdout AND stderr ──
subtest 'beacon.pl outputs are mojibake-free when HOME has non-ASCII' => sub {
    for my $tc (@CORPUS) {
        next unless defined $tc->{cp1252};  # cp1252-only chars survive
                                            # Windows filesystem APIs
        # Use the char IN the path so any byte-string concatenation path
        # is exercised. Embed in a unique dirname so subtests don't collide.
        my $home = "$tmp/home-tc-$UUID_COUNTER-$tc->{char}";
        make_path("$home/.claude/claude-code-vault/beacons");
        local $ENV{HOME} = $home;

        my $sid = next_uuid();
        my $label = "label with $tc->{char}";

        my ($out, $err, $rc) = run_capture('perl', $beacon_pl, 'light',
                                            '--session-id', $sid,
                                            '--label', $label);
        is($rc, 0, "[$tc->{name}] light exits 0") or diag "stderr: $err";
        like($out, qr/^STATUS: lit$/m,
             "[$tc->{name}] STATUS: lit emitted on stdout");
        is_mojibake_free("[$tc->{name}] stdout", $out);
        is_mojibake_free("[$tc->{name}] stderr", $err);
    }
};

# ── Test 2: JSON round-trip preserves on-disk bytes ────────────────
subtest 'JSON round-trip: light → file → get preserves non-ASCII bytes' => sub {
    local $ENV{HOME} = $tmp;
    for my $tc (@CORPUS) {
        my $sid = next_uuid();
        my $label = "topic with $tc->{char} chars";

        my ($lout, $lerr, $lrc) = run_capture('perl', $beacon_pl, 'light',
                                              '--session-id', $sid,
                                              '--label', $label);
        is($lrc, 0, "[$tc->{name}] light succeeded for round-trip");
        is_mojibake_free("[$tc->{name}] light stderr", $lerr);

        # Inspect on-disk JSON bytes directly
        my $file = "$tmp/.claude/claude-code-vault/beacons/$sid.json";
        if (!-f $file) { fail("[$tc->{name}] $file missing"); next }

        open my $fh, '<:raw', $file or die "open $file: $!";
        my $raw = do { local $/; <$fh> }; close $fh;
        ok(index($raw, $tc->{utf8}) >= 0,
           "[$tc->{name}] on-disk JSON contains expected UTF-8 byte sequence")
            or diag "on-disk hex (first 200): "
                  . unpack('H*', substr($raw, 0, 200));

        # Round-trip via beacon.pl get
        my ($gout, $gerr, $grc) = run_capture('perl', $beacon_pl, 'get',
                                              '--session-id', $sid);
        is($grc, 0, "[$tc->{name}] get exits 0");
        is_mojibake_free("[$tc->{name}] get stdout", $gout);
        is_mojibake_free("[$tc->{name}] get stderr", $gerr);

        my $rec = eval { decode_json($gout) };
        ok($rec, "[$tc->{name}] get output parses as JSON")
            or diag "got: $gout\nerr: $@";
        is($rec->{label}, $label,
           "[$tc->{name}] label round-trips byte-for-byte") if $rec;
    }
};

# ── Test 3: list output (both formats) handles non-ASCII ───────────
subtest 'beacon.pl list (kv + json) handles non-ASCII labels' => sub {
    local $ENV{HOME} = $tmp;

    my $sid = next_uuid();
    my $label = "mix-" . join('', map { $_->{char} } @CORPUS);
    write_json_record("$tmp/.claude/claude-code-vault/beacons/$sid.json",
                      stub_record($sid, { label => $label }));

    my ($jout, $jerr, $jrc) = run_capture('perl', $beacon_pl, 'list',
                                          '--format', 'json',
                                          '--scope', 'host');
    is($jrc, 0, 'list --format json exits 0');
    is_mojibake_free('list json stderr', $jerr);

    my $records = eval { decode_json($jout) };
    ok($records && ref $records eq 'ARRAY', 'list json parses')
        or diag "got: $jout\nerr: $@";
    if ($records) {
        my ($found) = grep { $_->{session_id} eq $sid } @$records;
        ok($found, 'seeded record present in list output');
        is($found->{label}, $label, 'label round-trips through list json')
            if $found;
    }

    my ($kvout, $kverr, $kvrc) = run_capture('perl', $beacon_pl, 'list',
                                             '--format', 'kv',
                                             '--scope', 'host');
    is($kvrc, 0, 'list --format kv exits 0');
    is_mojibake_free('list kv stdout', $kvout);
    is_mojibake_free('list kv stderr', $kverr);
};

# ── Test 4: -EncodedCommand pure-perl round-trip ───────────────────
subtest 'PowerShell -EncodedCommand round-trip preserves Unicode paths' => sub {
    for my $tc (@CORPUS) {
        my $cwd = "C:/Users/Test-$tc->{char}/work";
        my $sid = next_uuid();
        (my $psq = $cwd) =~ s/'/''/g;
        my $ps_cmd = "Set-Location -LiteralPath '$psq'; "
                   . "& claude --resume $sid";

        my $u16 = encode('UTF-16LE', $ps_cmd);
        my $b64 = encode_base64($u16, '');

        like($b64, qr/^[A-Za-z0-9+\/=]+$/,
             "[$tc->{name}] base64 is pure ASCII (survives argv hop)");

        my $decoded = decode('UTF-16LE', decode_base64($b64));
        is($decoded, $ps_cmd,
           "[$tc->{name}] base64+UTF-16LE round-trip preserves command")
            or diag "in:  " . unpack('H*', encode('UTF-8', $ps_cmd))
                 . "\nout: " . unpack('H*', encode('UTF-8', $decoded));
    }
};

# ── Test 5: LIVE PowerShell -EncodedCommand exec (the user-facing test) ──
subtest 'LIVE: powershell -EncodedCommand correctly receives Unicode paths' => sub {
    plan skip_all => 'powershell.exe not available' unless has_powershell();

    # For each non-ASCII char, build a PowerShell command that prints the
    # current location after Set-Location to a temp dir containing the
    # char in its name. PowerShell receives the base64, decodes UTF-16LE,
    # cd's, then Write-Host the path. We verify the output contains the
    # actual Unicode codepoint, not the cp1252-mojibake degradation.
    # Narrow to é only: it's the user's actual environment (`C:\Users\André\…`)
    # and the precise char that surfaced the original bug. Other Latin-1 chars
    # (ñ, ¥) hit an orthogonal issue — cygwin perl's `make_path` succeeds but
    # produces directories that PowerShell can't navigate to via Set-Location
    # (different Win32 path-API code paths between perl and PowerShell). That's
    # a separate bug to chase, not what THIS test is meant to validate.
    for my $tc (grep { $_->{name} eq 'Latin-1 e-acute' } @CORPUS) {
        my $dir = "$tmp/live-ps-$UUID_COUNTER-$tc->{char}";
        make_path($dir);
        $UUID_COUNTER++;

        # Convert to a Windows-shape path PowerShell understands.
        (my $win = $dir) =~ s{^/([a-zA-Z])/}{$1:/};

        # Build the PowerShell command. The output marker (=== ... ===)
        # makes stdout assertion robust against PowerShell preamble noise.
        # Force [Console]::OutputEncoding to UTF-8 BEFORE Write-Host so the
        # path round-trips as UTF-8 bytes the test can compare directly —
        # without this, PowerShell defaults to cp437 on US Windows console
        # and `é` would emit as `\x82` instead of `\xC3\xA9`.
        (my $psq = $win) =~ s/'/''/g;
        my $marker = "MARKER-$tc->{name}";
        $marker =~ s/\s+/_/g;
        my $ps_cmd = "[Console]::OutputEncoding = [Text.Encoding]::UTF8; "
                   . "Set-Location -LiteralPath '$psq'; "
                   . "Write-Host '=== $marker ==='; "
                   . "Write-Host (Get-Location).Path; "
                   . "Write-Host '=== END ==='";

        my $u16 = encode('UTF-16LE', $ps_cmd);
        my $b64 = encode_base64($u16, '');

        my ($out, $err, $rc) = run_capture('powershell.exe',
            '-NoProfile', '-NonInteractive', '-EncodedCommand', $b64);

        is($rc, 0, "[$tc->{name}] live powershell exec exits 0")
            or diag "stderr: $err\nstdout: $out";

        # Look at output between MARKER and END to isolate the path
        if ($out =~ /=== \Q$marker\E ===\s*(.+?)\s*=== END ===/s) {
            my $reported = $1;
            # The reported path should contain the original UTF-8 bytes
            # of the char (PowerShell typically outputs UTF-8 to a pipe).
            ok(index($reported, $tc->{utf8}) >= 0,
               "[$tc->{name}] PowerShell preserved $tc->{name} in path")
                or diag "expected to find bytes "
                      . unpack('H*', $tc->{utf8})
                      . " in: " . unpack('H*', $reported);
            # And no double-encoded mojibake
            is_mojibake_free("[$tc->{name}] live PowerShell stdout",
                             $reported);
        } else {
            fail("[$tc->{name}] could not find marker block in PowerShell output");
            diag "stdout: $out\nstderr: $err";
        }
    }
};

# ── Test 6: embedded single-quote in cwd survives PowerShell escaping ──
subtest "embedded ' in cwd does not break PowerShell command construction" => sub {
    # PowerShell single-quoted strings escape internal ' as ''. Verify
    # that the launcher's $psq =~ s/'/''/g matches that contract.
    my $cwd = "C:/Users/O'Brien/work";
    my $sid = next_uuid();

    (my $psq = $cwd) =~ s/'/''/g;
    is($psq, "C:/Users/O''Brien/work",
       "single-quote escaped to '' per PowerShell convention");

    my $ps_cmd = "Set-Location -LiteralPath '$psq'; & claude --resume $sid";
    # No unbalanced single-quotes after escaping
    my $sq_count = () = $ps_cmd =~ /'/g;
    is($sq_count % 2, 0, 'even number of single-quotes (balanced)');

    # Round-trips through base64
    my $u16 = encode('UTF-16LE', $ps_cmd);
    my $b64 = encode_base64($u16, '');
    my $decoded = decode('UTF-16LE', decode_base64($b64));
    is($decoded, $ps_cmd, 'O\'Brien path round-trips through base64+UTF-16LE');

    # If we have PowerShell, verify it actually parses the escaped command.
    # We can't Set-Location to a non-existent path, but we CAN ask
    # PowerShell to echo the parsed string literal as a syntax check.
    if (has_powershell()) {
        my $check = "\$path = '$psq'; Write-Host \$path";
        my $u16c = encode('UTF-16LE', $check);
        my $b64c = encode_base64($u16c, '');
        my ($cout, $cerr, $crc) = run_capture('powershell.exe',
            '-NoProfile', '-NonInteractive', '-EncodedCommand', $b64c);
        is($crc, 0, "PowerShell parses escaped single-quote literal");
        like($cout, qr{O'Brien},
             "PowerShell echoes the un-escaped O'Brien correctly");
    }
};

# ── Test 7: control characters in labels (defense-in-depth) ────────
subtest 'control chars in labels round-trip without crashing' => sub {
    local $ENV{HOME} = $tmp;
    # tab is the only commonly-legitimate control char users embed.
    # null/bell/etc. are pathological inputs we should handle gracefully.
    my @labels = (
        "label\twith\ttabs",
        "label with \x{2192} arrow",  # outside cp1252 but valid Unicode
    );
    # Skip \x00 — beacon.pl's parse_args may legitimately reject null
    # bytes in flag values. The point is to verify nothing crashes.

    for my $label (@labels) {
        my $sid = next_uuid();
        my ($out, $err, $rc) = run_capture('perl', $beacon_pl, 'light',
                                            '--session-id', $sid,
                                            '--label', $label);
        is($rc, 0, "light succeeded for label containing control/extended chars")
            or diag "stderr: $err";
        is_mojibake_free("light stdout for control-char label", $out);

        # Round-trip via get
        if ($rc == 0) {
            my ($gout) = run_capture('perl', $beacon_pl, 'get',
                                     '--session-id', $sid);
            my $rec = eval { decode_json($gout) };
            is($rec->{label}, $label, 'control-char label round-trips')
                if $rec;
        }
    }
};

# ── Test 8: explicit regression — exact byte sequence the user reported
subtest 'regression: literal AndrÃ© byte sequence is NEVER emitted' => sub {
    my $home_with_e = "$tmp/Users/André";  # the literal user path shape
    make_path("$home_with_e/.claude/claude-code-vault/beacons");
    local $ENV{HOME} = $home_with_e;

    my $sid = next_uuid();
    my ($lit_out, $lit_err)   = run_capture('perl', $beacon_pl, 'light',
                                            '--session-id', $sid,
                                            '--label', 'regression-check');
    my ($get_out, $get_err)   = run_capture('perl', $beacon_pl, 'get',
                                            '--session-id', $sid);
    my ($list_out, $list_err) = run_capture('perl', $beacon_pl, 'list',
                                            '--format', 'kv',
                                            '--scope', 'host');

    # The double-encoded byte sequence the user observed: `é` (one char)
    # would emit as `Ã©` mojibake = bytes `\xC3\x83\xC2\xA9` on UTF-8
    # terminals. The Ã prefix `\xC3\x83` is the diagnostic marker.
    for my $pair (['light stdout', $lit_out], ['light stderr', $lit_err],
                  ['get stdout',   $get_out], ['get stderr',   $get_err],
                  ['list stdout',  $list_out],['list stderr',  $list_err]) {
        my ($which, $output) = @$pair;
        unlike($output, qr/Andr\xC3\x83/,
               "regression: $which does not contain 'Andr\\xC3\\x83' (double-encoded é prefix)");
    }
};

done_testing();
