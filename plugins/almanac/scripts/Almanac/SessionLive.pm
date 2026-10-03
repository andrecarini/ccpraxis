package Almanac::SessionLive;
# Almanac::SessionLive -- the one shared liveness signal (blueprint
# where-things-go, package 03-thread-sessions, Decision 18 F5). See
# specs/03-thread-sessions-spec.md section 2.2.
#
# Core Perl only. Never dies, never writes, takes no lock, never loads a
# butler module, never reads $CLAUDE_CODE_SESSION_ID.
#
# Idle = 3600s reuses the codebase's existing answer to "how long can a
# transcript sit untouched and still be the one in use":
# BpContinuityLease::$TRANSCRIPT_LIVENESS_SECONDS and
# BpSession::transcript_files's default max_age, both 3600.
#
# Armed = 46800s (13h): F5 requires the armed threshold to "cover a usage
# pause". The longest pause an armed session holds through is
# bp-drive-next.pl::$LONG_PAUSE_HANDOFF_SECONDS = 12h. The extra hour is the
# idle window again: the time between the pause lifting and the session's
# first transcript write.
use strict;
use warnings;
use Fcntl qw(:flock);
use JSON::PP ();
use Cwd ();

our $IDLE_SECONDS  = 3600;
our $ARMED_SECONDS = 46800;

# ---------------------------------------------------------------------------
# byte/path helpers -- deliberately NOT shared with BpHook.pm (this module
# never loads butler).
# ---------------------------------------------------------------------------
sub _is_abs {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    return 1 if $p =~ m{^/};
    return 1 if $p =~ m{^[A-Za-z]:[\\/]};
    return 0;
}

sub _to_bytes {
    my ($s) = @_;
    return undef unless defined $s;
    my $v = "$s";
    if (utf8::is_utf8($v)) {
        utf8::encode($v);
    } else {
        my $probe = $v;
        my $already_utf8 = utf8::decode($probe);
        unless ($already_utf8) { utf8::encode($v) }
    }
    $v =~ tr{\\}{/};
    return $v;
}

sub _read_bytes {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# _collapse_dotdot($path) -- resolve "seg/.." pairs PURELY LEXICALLY (string
# manipulation only, never touching the filesystem). Decision 35 / S2: this
# replaces Cwd::abs_path for butler_bphook_path's canonicalisation.
# Cwd::abs_path resolves through the real filesystem, which means it FOLLOWS
# a symlink or junction standing in for a sibling plugin directory -- a
# junctioned `almanac` next to a real `butler` then resolves to the
# junction's TARGET's sibling, which can easily not exist, reading as
# "butler absent" (fail OPEN) when butler is installed right beside the
# junction. A literal ".." in a path (e.g. a test's FindBin-derived
# "$Bin/../../scripts") is a textual artifact with no symlink involved, so
# collapsing it lexically handles that case exactly like abs_path did,
# without ever resolving a link.
sub _collapse_dotdot {
    my ($path) = @_;
    return $path unless defined $path && length $path;
    my @parts = split m{/}, $path, -1;
    my @out;
    for my $part (@parts) {
        if ($part eq '.') {
            next;
        } elsif ($part eq '..' && @out && $out[-1] ne '..' && $out[-1] ne '') {
            pop @out;
        } else {
            push @out, $part;
        }
    }
    return join('/', @out);
}

# ---------------------------------------------------------------------------
# butler presence / state dir
# ---------------------------------------------------------------------------
sub butler_bphook_path {
    my $dir = __FILE__;
    $dir =~ s{\\}{/}g;
    $dir = _collapse_dotdot($dir);
    $dir =~ s{/[^/]+\z}{};   # strip SessionLive.pm -> .../Almanac
    $dir =~ s{/[^/]+\z}{};   # strip Almanac       -> .../scripts
    $dir =~ s{/[^/]+\z}{};   # strip scripts       -> .../almanac
    $dir =~ s{/[^/]+\z}{};   # strip almanac       -> .../plugins
    $dir = '.' unless length $dir;
    return "$dir/butler/scripts/BpHook.pm";
}

sub butler_present {
    return -f butler_bphook_path() ? 1 : 0;
}

sub butler_state_dir {
    my $bsd = $ENV{BUTLER_STATE_DIR};
    if (defined $bsd && length $bsd) {
        return undef unless _is_abs($bsd);
        my $v = _to_bytes($bsd);
        $v =~ s{/+$}{};
        return "$v/continuity";
    }
    for my $var (qw(HOME USERPROFILE)) {
        my $val = $ENV{$var};
        next unless defined $val && length $val && _is_abs($val);
        my $v = _to_bytes($val);
        $v =~ s{/+$}{};
        return "$v/.claude/butler-state/continuity";
    }
    return undef;
}

# arm_record($sid, %o) -> \%rec | undef. %o: butler_present => 0|1 (override).
sub arm_record {
    my ($sid, %o) = @_;
    return undef unless defined $sid && $sid =~ /\A[A-Za-z0-9_-]{1,128}\z/;
    my $present = exists $o{butler_present} ? ($o{butler_present} ? 1 : 0) : butler_present();
    return undef unless $present;
    my $bsd = butler_state_dir();
    return undef unless defined $bsd;
    my $path = "$bsd/armed/$sid";
    return undef unless -f $path;
    my $raw = _read_bytes($path);
    return {} unless defined $raw;
    my $data = eval { JSON::PP->new->utf8->decode($raw) };
    return (ref $data eq 'HASH') ? $data : {};
}

# find_transcript($sid) -> ($path|undef, $roots_visible 0|1)
sub find_transcript {
    my ($sid) = @_;
    return (undef, 0) unless defined $sid && length $sid;
    return (undef, 0) if $sid =~ /[\/\\\x00]/;

    my @roots;
    {
        my $cfg = $ENV{CLAUDE_CONFIG_DIR};
        if (defined $cfg && length $cfg && _is_abs($cfg)) {
            my $v = _to_bytes($cfg); $v =~ s{/+$}{};
            push @roots, "$v/projects";
        }
    }
    for my $var (qw(HOME USERPROFILE)) {
        my $val = $ENV{$var};
        next unless defined $val && length $val && _is_abs($val);
        my $v = _to_bytes($val); $v =~ s{/+$}{};
        push @roots, "$v/.claude/projects";
    }

    my $any_root_exists = 0;
    for my $root (@roots) {
        next unless -d $root;
        $any_root_exists = 1;
        opendir(my $dh, $root) or next;
        my @subs = sort grep { $_ ne '.' && $_ ne '..' && -d "$root/$_" } readdir($dh);
        closedir $dh;
        for my $d (@subs) {
            my $cand = "$root/$d/$sid.jsonl";
            return ($cand, 1) if -f $cand;
        }
    }
    return (undef, $any_root_exists ? 1 : 0);
}

# ---------------------------------------------------------------------------
# judge(%a) -> \%verdict
# ---------------------------------------------------------------------------
sub _since_or_unknown {
    my ($armed, $since, $now) = @_;
    if (defined $since) {
        my $idle = $now - $since;
        $idle = 0 if $idle < 0;
        my $alive = ($idle <= $ARMED_SECONDS) ? 1 : 0;
        return { state => ($alive ? 'alive' : 'dead'), basis => 'since',
                 armed => $armed, idle => $idle, transcript_path => undef };
    }
    return { state => 'unknown', basis => 'unresolved', armed => $armed, idle => undef, transcript_path => undef };
}

sub judge {
    my (%a) = @_;
    my $session = $a{session};
    my $now = defined $a{now} ? $a{now} : time();

    unless (defined $session && $session =~ /\A[A-Za-z0-9_-]{1,128}\z/) {
        return { state => 'dead', basis => 'bad-session', armed => 0, idle => undef, transcript_path => undef };
    }

    my $bp = exists $a{butler_present} ? ($a{butler_present} ? 1 : 0) : butler_present();
    my $arm = arm_record($session, butler_present => $bp);
    my $armed = defined $arm ? 1 : 0;

    my $tpath;
    if (defined $a{transcript_path} && length $a{transcript_path}) {
        $tpath = _to_bytes($a{transcript_path});
    } elsif ($armed && ref($arm) eq 'HASH' && defined $arm->{transcript_path} && length $arm->{transcript_path}) {
        $tpath = _to_bytes($arm->{transcript_path});
    } else {
        my ($found, $visible) = find_transcript($session);
        if (defined $found) {
            $tpath = _to_bytes($found);
        } else {
            if ($visible) {
                return { state => 'dead', basis => 'no-transcript', armed => $armed, idle => undef, transcript_path => undef };
            }
            return _since_or_unknown($armed, $a{since}, $now);
        }
    }

    (my $root = $tpath) =~ s{/[^/]+/[^/]+\z}{};
    unless (length($root) && -d $root) {
        return _since_or_unknown($armed, $a{since}, $now);
    }
    unless (-f $tpath) {
        return { state => 'dead', basis => 'no-transcript', armed => $armed, idle => undef, transcript_path => $tpath };
    }

    my $mtime = (stat($tpath))[9];

    # Decision 35 / S1: a session busy inside a Task/Agent dispatch does not
    # write its own <sid>.jsonl while the subagent runs -- the subagent's
    # own transcript, written under <sid>/subagents/*.jsonl beside the main
    # transcript, is what moves instead. Widen "last activity" to the newer
    # of the two so such a session is not misjudged dead mid-dispatch.
    {
        (my $tdir = $tpath) =~ s{/[^/]+\z}{};
        my $sub_dir = "$tdir/$session/subagents";
        if (-d $sub_dir && opendir(my $sdh, $sub_dir)) {
            for my $f (readdir($sdh)) {
                next unless $f =~ /\.jsonl\z/;
                my $sm = (stat("$sub_dir/$f"))[9];
                $mtime = $sm if defined $sm && $sm > $mtime;
            }
            closedir $sdh;
        }
    }

    my $idle = $now - $mtime;
    $idle = 0 if $idle < 0;

    if ($idle <= $IDLE_SECONDS) {
        return { state => 'alive', basis => 'active', armed => $armed, idle => $idle, transcript_path => $tpath };
    }
    if ($armed && $idle <= $ARMED_SECONDS) {
        return { state => 'alive', basis => 'armed', armed => $armed, idle => $idle, transcript_path => $tpath };
    }
    return { state => 'dead', basis => ($armed ? 'armed-idle' : 'idle'), armed => $armed, idle => $idle, transcript_path => $tpath };
}

sub is_alive {
    my (%a) = @_;
    my $v = judge(%a);
    return ($v->{state} ne 'dead') ? 1 : 0;
}

# orchestrator_live(root => $R, blueprint => $bp) -> 1|0
sub orchestrator_live {
    my (%a) = @_;
    my $bp = $a{blueprint};
    return 0 unless defined $bp && length($bp) <= 128
        && $bp =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/ && $bp !~ /\.\./;
    my $root = $a{root};
    return 0 unless defined $root && length $root;
    my $marker = _to_bytes($root) . "/.ccpraxis-local-data/blueprints/" . _to_bytes($bp) . "/runs/.orchestrator";
    return 0 unless -f $marker;
    open(my $fh, '<', $marker) or return 0;
    if (flock($fh, LOCK_SH | LOCK_NB)) {
        flock($fh, LOCK_UN);
        close($fh);
        return 0;
    }
    close($fh);
    return 1;
}

1;
