# MachineLocalSettings -- the settings.json values that cannot be shared.
#
# global-config/settings.json is ONE payload for every machine that promotes
# from, or backs up to, this repo (the Windows host and a Mac today). Two kinds
# of value in it are true on one machine only, and both used to leak:
#
# 1. LIVE-ROOT PATHS. The ccpraxis-local marketplace is a `directory` source
#    whose path is the live install's own plugins dir -- an absolute path that
#    differs per machine (C:/Users/<name>/.claude/ccpraxis/plugins on Windows,
#    /Users/<name>/.claude/ccpraxis/plugins on a Mac). The payload carried the
#    Windows one literally, so a Mac promote installed a path that cannot
#    resolve, and a Mac backup would have exported the Mac path and broken the
#    Windows host in turn.
#
#    The payload now stores such a path relative to LIVE_ROOT_TOKEN:
#
#        "path" : "${CCPRAXIS_LIVE}/plugins"
#
#    ${CCPRAXIS_LIVE} stands for "the root of the live install this settings
#    file belongs to" -- the --live directory promote.pl merges into, which is
#    ~/.claude/ccpraxis unless overridden. It is deliberately NOT a path Claude
#    Code can resolve on its own: a payload copied without promote fails
#    loudly instead of pointing at some other machine's directory. The token
#    is only honoured as the whole value or as a leading "${CCPRAXIS_LIVE}/"
#    prefix, and only in extraKnownMarketplaces.<name>.source.path where
#    source.source is "directory" -- the one place a live-install path is
#    legitimately machine-specific.
#
#    Direction of travel:
#      payload -> live   promote.pl calls expand_live_root(): the token
#                        becomes the live root in forward-slash form (C:/...
#                        on Windows, so the Windows value is byte-identical to
#                        what the payload used to carry).
#      live -> payload   settings-export-merge calls collapse_live_root(): a
#                        live value under THIS machine's live root becomes the
#                        token again, so no machine exports its own path.
#      live vs payload   json-diff.pl --host-live expands the payload side, so
#                        an in-sync machine shows no difference and a "use the
#                        repo value" answer writes a real path, never the token.
#
# 2. PLATFORM-ONLY KEYS (%PLATFORM_ONLY_KEYS below). A key that only means
#    something on one platform is outside the sync entirely on every other
#    host: promote never adds, changes or removes it there; export from such a
#    host never adds, changes or deletes it in the payload; and the live-vs-
#    payload diff does not report it. env.CLAUDE_CODE_USE_POWERSHELL_TOOL is
#    the case that motivated this: Claude Code checks it for truthiness on
#    every platform, so promoting the Windows "1" onto a Mac would offer a
#    PowerShell tool with no pwsh behind it, and a Mac backup (where the key
#    is absent, or pinned "0") must not take it away from the Windows host.
#
# 3. PLATFORM-ONLY HOOKS (%PLATFORM_ONLY_HOOKS below). A hook registration
#    whose script only guards against one platform's failure is a cost and
#    nothing else on the others: block-nul-redirect.pl (a `> NUL` from Git
#    Bash creates an undeletable file on Windows) and block-nonascii-ps1.pl
#    (PowerShell 5.1 misreads a BOM-less non-ASCII .ps1) each started a perl
#    process on every Bash or Edit/Write call on a Mac to guard against
#    nothing there. Such a registration gets the platform-only-key treatment:
#    stripped from both sides before a comparison, and put back afterwards
#    from the side that owns it on this host (live for promote, the payload
#    for export). A hook group is platform-only when every hook in it runs a
#    listed script; a group mixing a listed script with anything else is
#    left alone. What strip removes is remembered by event and position, so
#    a restore puts each group back where it was and an export never
#    reorders the payload.
#
# Keys are named in the one-level dotted form the rest of the settings sync
# uses (json-diff.pl, filter-diff.pl, .backup-preferences.json): "top" or
# "top.sub".
#
# Core modules only; no state. Callers: scripts/promote.pl,
# plugins/steward/scripts/ccpraxis-helpers.pl (settings-export-merge),
# plugins/steward/scripts/json-diff.pl (--host-live).
package MachineLocalSettings;
use strict;
use warnings;
use Cwd ();
use Encode ();
use File::Spec;
use Exporter 'import';

our @EXPORT_OK = qw(
    LIVE_ROOT_TOKEN %PLATFORM_ONLY_KEYS %PLATFORM_ONLY_HOOKS
    is_windows_host host_platform live_root_spellings
    expand_live_root collapse_live_root
    foreign_platform_keys strip_foreign_platform_keys restore_foreign_platform_keys
);

use constant LIVE_ROOT_TOKEN => '${CCPRAXIS_LIVE}';

# dotted key name => the one platform it applies to ('windows' | 'darwin' |
# 'linux', as host_platform() spells them).
our %PLATFORM_ONLY_KEYS = (
    'env.CLAUDE_CODE_USE_POWERSHELL_TOOL' => 'windows',
);

# script path (as it appears in a hook command, forward slashes) => the one
# platform it applies to.
our %PLATFORM_ONLY_HOOKS = (
    'scripts/hooks/block-nul-redirect.pl'  => 'windows',
    'scripts/hooks/block-nonascii-ps1.pl'  => 'windows',
);

# Prefix of the %saved entries that carry stripped hook groups, so they can
# never collide with a dotted key name.
use constant HOOK_SAVE_PREFIX => "\0hooks:";

# Git-for-Windows perl reports cygwin/msys, Strawberry/ActivePerl MSWin32.
sub is_windows_host { return ($^O eq 'MSWin32' || $^O eq 'cygwin' || $^O eq 'msys') ? 1 : 0 }

sub host_platform {
    return 'windows' if is_windows_host();
    return 'darwin'  if $^O eq 'darwin';
    return 'linux';
}

# Byte string (argv/env/abs_path) -> character string, the form decode_json
# hands back for every settings value. UTF-8 first; a CP1252 fallback for the
# Windows "Andr\xE9" case, mirroring _decode_strings_recursive elsewhere.
sub _to_chars {
    my ($s) = @_;
    return $s if utf8::is_utf8($s);
    my $copy = $s;
    my $d = eval { Encode::decode('UTF-8', $copy, Encode::FB_CROAK) };
    return defined $d ? $d : Encode::decode('cp1252', $s, Encode::FB_DEFAULT);
}

# One spelling of a path, in the form settings.json uses: forward slashes, no
# trailing slash, and on Windows the C:/ form (MSYS's /c/... translated, the
# drive letter upper-cased) -- the same form promote.pl's git_path() emits.
sub _spell {
    my ($p) = @_;
    $p =~ s{\\}{/}g;
    if (is_windows_host()) {
        $p =~ s{^/([a-zA-Z])(?=/|\z)}{uc($1) . ':'}e;
        $p =~ s{^([a-z]):}{uc($1) . ':'}e;
    }
    $p =~ s{(?<=.)/+\z}{};
    return _to_chars($p);
}

# Every spelling of $live_root a settings value may carry: as given (made
# absolute), then fully resolved through symlinks when that differs (on a Mac
# a scratch root under /var is /private/var once resolved). The FIRST element
# is the canonical one expand_live_root() writes. Empty list for no root.
sub live_root_spellings {
    my ($live_root) = @_;
    return () unless defined $live_root && length $live_root;
    my $abs = (File::Spec->file_name_is_absolute($live_root) || $live_root =~ m{^[A-Za-z]:[\\/]})
        ? $live_root
        : File::Spec->rel2abs($live_root);
    my @out = (_spell($abs));
    my $real = Cwd::abs_path($abs);
    push @out, _spell($real) if defined $real;
    my %seen;
    return grep { !$seen{$_}++ } @out;
}

# The source hashes whose `path` may carry a live-root path.
sub _directory_sources {
    my ($settings) = @_;
    return () unless ref($settings) eq 'HASH';
    my $ekm = $settings->{extraKnownMarketplaces};
    return () unless ref($ekm) eq 'HASH';
    my @out;
    for my $name (sort keys %$ekm) {
        my $entry = $ekm->{$name};
        next unless ref($entry) eq 'HASH' && ref($entry->{source}) eq 'HASH';
        my $src = $entry->{source};
        next unless defined $src->{source} && !ref($src->{source}) && $src->{source} eq 'directory';
        next unless defined $src->{path} && !ref($src->{path});
        push @out, $src;
    }
    return @out;
}

# payload -> live: replace the token with $live_root's canonical spelling, in
# place. Returns the number of values rewritten.
sub expand_live_root {
    my ($settings, $live_root) = @_;
    my ($spelling) = live_root_spellings($live_root);
    return 0 unless defined $spelling;
    my $tok = LIVE_ROOT_TOKEN;
    my $n = 0;
    for my $src (_directory_sources($settings)) {
        my $p = $src->{path};
        next unless $p eq $tok || index($p, "$tok/") == 0;
        $src->{path} = $spelling . substr($p, length $tok);
        $n++;
    }
    return $n;
}

# live -> payload: a value equal to, or under, any spelling of $live_root
# becomes token-relative again, in place. Case-insensitive where the
# filesystem is (Windows, and macOS's default APFS). Returns the count.
sub collapse_live_root {
    my ($settings, $live_root) = @_;
    my @spellings = live_root_spellings($live_root);
    return 0 unless @spellings;
    my $fold = (is_windows_host() || $^O eq 'darwin') ? 1 : 0;
    my $n = 0;
    for my $src (_directory_sources($settings)) {
        (my $p = $src->{path}) =~ s{\\}{/}g;
        $p =~ s{(?<=.)/+\z}{};
        for my $sp (@spellings) {
            my ($a, $b) = $fold ? (lc $p, lc $sp) : ($p, $sp);
            next unless $a eq $b || index($a, "$b/") == 0;
            $src->{path} = LIVE_ROOT_TOKEN . substr($p, length $sp);
            $n++;
            last;
        }
    }
    return $n;
}

# The platform-only keys that do NOT apply on this host.
sub foreign_platform_keys {
    my $plat = host_platform();
    return sort grep { $PLATFORM_ONLY_KEYS{$_} ne $plat } keys %PLATFORM_ONLY_KEYS;
}

sub _split_key { my ($name) = @_; return split /\./, $name, 2; }

sub _get_key {
    my ($obj, $name) = @_;
    my ($top, $sub) = _split_key($name);
    return (0, undef) unless ref($obj) eq 'HASH' && exists $obj->{$top};
    return (1, $obj->{$top}) unless defined $sub;
    my $h = $obj->{$top};
    return (0, undef) unless ref($h) eq 'HASH' && exists $h->{$sub};
    return (1, $h->{$sub});
}

sub _set_key {
    my ($obj, $name, $val) = @_;
    my ($top, $sub) = _split_key($name);
    if (!defined $sub) { $obj->{$top} = $val; return; }
    $obj->{$top} = {} unless ref($obj->{$top}) eq 'HASH';
    $obj->{$top}{$sub} = $val;
    return;
}

sub _delete_key {
    my ($obj, $name) = @_;
    my ($top, $sub) = _split_key($name);
    if (!defined $sub) { delete $obj->{$top}; return; }
    delete $obj->{$top}{$sub} if ref($obj->{$top}) eq 'HASH';
    return;
}

# True when every hook in $group runs a script that applies only to a
# platform other than this host's.
sub _is_foreign_hook_group {
    my ($group) = @_;
    return 0 unless ref($group) eq 'HASH' && ref($group->{hooks}) eq 'ARRAY' && @{ $group->{hooks} };
    my $plat = host_platform();
    for my $h (@{ $group->{hooks} }) {
        my $cmd = (ref($h) eq 'HASH' && defined $h->{command} && !ref $h->{command}) ? $h->{command} : '';
        (my $norm = $cmd) =~ s{\\}{/}g;
        my $foreign = 0;
        for my $script (keys %PLATFORM_ONLY_HOOKS) {
            next if $PLATFORM_ONLY_HOOKS{$script} eq $plat;
            if (index($norm, $script) >= 0) { $foreign = 1; last; }
        }
        return 0 unless $foreign;
    }
    return 1;
}

# Remove this host's foreign platform-only keys and hook groups from $obj,
# in place. Returns { name => value } for what was present, so a caller can
# put it back: dotted key names for keys, HOOK_SAVE_PREFIX.<event> =>
# [ [index, group], ... ] (original positions, ascending) for hook groups.
sub strip_foreign_platform_keys {
    my ($obj) = @_;
    my %saved;
    return \%saved unless ref($obj) eq 'HASH';
    for my $k (foreign_platform_keys()) {
        my ($found, $val) = _get_key($obj, $k);
        next unless $found;
        $saved{$k} = $val;
        _delete_key($obj, $k);
    }
    if (ref($obj->{hooks}) eq 'HASH') {
        for my $event (sort keys %{ $obj->{hooks} }) {
            my $groups = $obj->{hooks}{$event};
            next unless ref($groups) eq 'ARRAY';
            my (@kept, @gone);
            for my $i (0 .. $#$groups) {
                if (_is_foreign_hook_group($groups->[$i])) { push @gone, [ $i, $groups->[$i] ]; }
                else                                       { push @kept, $groups->[$i]; }
            }
            next unless @gone;
            $saved{ HOOK_SAVE_PREFIX . $event } = \@gone;
            if (@kept) { $obj->{hooks}{$event} = \@kept; }
            else       { delete $obj->{hooks}{$event}; }
        }
        delete $obj->{hooks} unless %{ $obj->{hooks} };
    }
    return \%saved;
}

# Make $obj carry exactly $saved's foreign platform-only keys and hook
# groups: set what $saved has, delete what it lacks. Used after a merge so
# the side that owns them on this host (live for promote, the payload for
# export) wins whatever the merge did. Hook groups go back at the positions
# they were stripped from (clamped to the array's end), so a strip followed
# by a restore is the identity.
sub restore_foreign_platform_keys {
    my ($obj, $saved) = @_;
    return unless ref($obj) eq 'HASH';
    $saved = {} unless ref($saved) eq 'HASH';
    for my $k (foreign_platform_keys()) {
        if (exists $saved->{$k}) { _set_key($obj, $k, $saved->{$k}); }
        else                     { _delete_key($obj, $k); }
    }
    # Drop whatever foreign groups the merge left (a strip of a hash holding
    # only the hooks has no keys to remove), then re-insert the saved ones.
    if (ref($obj->{hooks}) eq 'HASH') {
        my %only = (hooks => $obj->{hooks});
        strip_foreign_platform_keys(\%only);
        if (exists $only{hooks}) { $obj->{hooks} = $only{hooks}; }
        else                     { delete $obj->{hooks}; }
    }
    my $pfx = HOOK_SAVE_PREFIX;
    for my $sk (sort grep { index($_, $pfx) == 0 } keys %$saved) {
        my $event = substr($sk, length $pfx);
        my $entries = $saved->{$sk};
        next unless ref($entries) eq 'ARRAY' && @$entries;
        $obj->{hooks} = {} unless ref($obj->{hooks}) eq 'HASH';
        $obj->{hooks}{$event} = [] unless ref($obj->{hooks}{$event}) eq 'ARRAY';
        my $arr = $obj->{hooks}{$event};
        for my $e (sort { $a->[0] <=> $b->[0] } @$entries) {
            my ($i, $group) = @$e;
            $i = scalar(@$arr) if $i > scalar(@$arr);
            splice @$arr, $i, 0, $group;
        }
    }
    return;
}

1;
